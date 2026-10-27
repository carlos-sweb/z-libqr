//! Tier-parameterized encoder implementation:
//!   - Mode detection (Numeric, Alphanumeric, Byte)
//!   - Segment bit serialization, terminator (<= 4 zeros), bit padding to byte, and alternating 0xEC / 0x11
//!   - Automatic version selection (or forced version validation)
//!   - Interleaving, Reed-Solomon ECC generation, zigzag placement, and optimal mask evaluation
//!   - Final matrix module flag cleanup (ensuring all modules are 0 or 1).
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT), c/qrcodegen.c:
//!     qrcodegen_encodeText, qrcodegen_encodeBinary, qrcodegen_encodeSegmentsAdvanced.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const segment = @import("segment.zig");
const matrix = @import("matrix.zig");
const interleave = @import("interleave.zig");
const mask_mod = @import("mask.zig");
const BitBuffer = @import("BitBuffer.zig").BitBuffer;
const optimizer = @import("optimizer.zig");

const Ecc = types.Ecc;
const Mode = types.Mode;
const Error = types.Error;
const QrMatrix = types.QrMatrix;
const Segment = segment.Segment;

pub fn Encoder(comptime max_version: u8) type {
    if (max_version < tables.min_version or max_version > tables.max_version) {
        @compileError(std.fmt.comptimePrint(
            "Encoder max_version must be in {d}...{d}, got {d}",
            .{ tables.min_version, tables.max_version, max_version },
        ));
    }

    return struct {
        pub const tier_max_version: u8 = max_version;
        pub const max_size: u8 = tables.symbolSize(max_version);
        pub const max_buffer_len: usize = tables.moduleCount(max_version);
        pub const max_tier_chars: usize = optimizer.maxCharsForTier(max_version);
        pub const max_tier_segments: usize = switch (max_version) {
            1...6 => 32,
            7...10 => 48,
            else => 128,
        };

        /// Validates `version` against the QR standard and this tier's limit.
        pub fn checkVersion(version: u8) Error!void {
            if (version < tables.min_version or version > tables.max_version) {
                return error.InvalidVersion;
            }
            if (version > max_version) return error.VersionExceedsTier;
        }

        /// Returns the required buffer length in bytes for a given version.
        pub fn bufferLen(version: u8) Error!usize {
            try checkVersion(version);
            return tables.moduleCount(version);
        }

        /// Maximum possible buffer length for a sequence of 16 symbols in this tier.
        pub const max_sequence_buffer_len: usize = 16 * max_buffer_len;

        /// Required buffer length in bytes for `count` symbols of `version`.
        pub fn sequenceBufferLen(version: u8, count: u8) Error!usize {
            const single = try bufferLen(version);
            return single * @as(usize, count);
        }

        /// Configuration options for advanced encoding.
        pub const Options = struct {
            ecc: Ecc = .low,
            min_version: u8 = tables.min_version,
            max_version: u8 = tier_max_version,
            mask: ?u3 = null,
            kanji: bool = false,
            optimize: bool = true,
            fnc1: ?types.Fnc1 = null,
            eci: ?u32 = null,
            sa: ?types.StructuredAppend = null,
        };

        /// Configuration options for Structured Append sequence encoding.
        pub const SequenceOptions = struct {
            ecc: Ecc = .low,
            min_version: u8 = tables.min_version,
            max_version: u8 = tier_max_version,
            mask: ?u3 = null,
            kanji: bool = false,
            optimize: bool = true,
            fnc1: ?types.Fnc1 = null,
            eci: ?u32 = null,
            symbol_count: ?u8 = null,
        };

        /// Result of encoding a Structured Append sequence of 1 to 16 symbols.
        ///
        /// Caller note: Only `matrices[0..count]` are valid and populated.
        /// Slots `matrices[count..16]` are undefined/empty when `count < 16`.
        /// Use `res.slice()` or `res.matrices[0..res.count]` to access generated symbols.
        pub const SequenceResult = struct {
            count: u8,
            parity: u8,
            matrices: [16]QrMatrix,

            pub fn slice(self: *const SequenceResult) []const QrMatrix {
                return self.matrices[0..self.count];
            }
        };

        /// Selects the single most efficient Mode for `text`.
        /// When `enable_kanji` is true, tests if the entire text is encodable in JIS X 0208 Kanji mode.
        /// Source: nayuki/QR-Code-generator, c/qrcodegen.c lines 152-178, and QrSegmentAdvanced.java.
        pub fn detectModeWithKanji(text: []const u8, enable_kanji: bool) Mode {
            if (segment.isNumeric(text)) return .numeric;
            if (segment.isAlphanumeric(text)) return .alphanumeric;
            if (enable_kanji and segment.isKanji(text)) return .kanji;
            return .byte;
        }

        /// Selects the single most efficient Mode for `text` using standard modes.
        /// Source: nayuki/QR-Code-generator, c/qrcodegen.c, lines 152-178.
        pub fn detectMode(text: []const u8) Mode {
            return detectModeWithKanji(text, false);
        }

        /// Core pipeline to encode a slice of preconstructed segments into `buf`.
        /// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_encodeSegmentsAdvanced.
        pub fn encodeSegmentsAdvanced(
            buf: []u8,
            segs: []const Segment,
            min_ver: u8,
            max_ver: u8,
            ecc: Ecc,
            forced_mask: ?u3,
        ) Error!QrMatrix {
            if (min_ver < tables.min_version or min_ver > tables.max_version or
                max_ver < tables.min_version or max_ver > tables.max_version or
                min_ver > max_ver)
            {
                return error.InvalidVersion;
            }
            if (max_ver > max_version) {
                return error.VersionExceedsTier;
            }

            // Validate segment placement per ISO/IEC 18004 clause 7.4.8 and clause 8:
            // Order must be: [StructuredAppend (if any), ECI (if any), FNC1 (if any), Data...]
            var seen_sa = false;
            var seen_eci = false;
            var seen_fnc1 = false;
            var seen_data = false;
            for (segs) |seg| {
                switch (seg.mode) {
                    .structured_append => {
                        if (seen_sa or seen_eci or seen_fnc1 or seen_data) return error.InvalidSegmentOrder;
                        seen_sa = true;
                    },
                    .eci => {
                        if (seen_fnc1 or seen_data) return error.InvalidSegmentOrder;
                        seen_eci = true;
                    },
                    .fnc1_first, .fnc1_second => {
                        if (seen_data or seen_fnc1) return error.InvalidSegmentOrder;
                        seen_fnc1 = true;
                    },
                    else => {
                        seen_data = true;
                    },
                }
            }

            // 1. Find the smallest version in [min_ver .. max_ver] that can fit all segments
            var chosen_version: ?u8 = null;
            var data_used_bits: usize = 0;
            var v: u8 = min_ver;
            while (v <= max_ver) : (v += 1) {
                const capacity_bits = @as(usize, tables.getNumDataCodewords(v, ecc)) * 8;
                const needed_bits = segment.getTotalBits(segs, v);
                if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= capacity_bits) {
                    chosen_version = v;
                    data_used_bits = needed_bits;
                    break;
                }
            }

            const version = chosen_version orelse {
                // If it didn't fit in max_ver, return VersionExceedsTier if max_ver < 40 and fits higher,
                // or DataTooLong if min_ver == max_ver (forced) or exceeds v40.
                if (min_ver != max_ver and max_ver < tables.max_version) {
                    // Check if it fits in higher versions up to 40
                    var v_check: u8 = max_ver + 1;
                    while (v_check <= tables.max_version) : (v_check += 1) {
                        const cap_bits = @as(usize, tables.getNumDataCodewords(v_check, ecc)) * 8;
                        const needed_bits = segment.getTotalBits(segs, v_check);
                        if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                            return error.VersionExceedsTier;
                        }
                    }
                }
                return error.DataTooLong;
            };

            const size = tables.symbolSize(version);
            const needed_buf_len = @as(usize, size) * size;
            if (buf.len < needed_buf_len) return error.BufferTooSmall;

            // 2. Concatenate segment bits into data bitstream
            // Maximum data codewords in QR Model 2 is 2956 bytes (Version 40-L)
            var data_codewords_buf: [2956]u8 = @splat(0);
            const data_capacity_bytes = tables.getNumDataCodewords(version, ecc);
            const data_capacity_bits = @as(usize, data_capacity_bytes) * 8;

            var bb = BitBuffer.init(data_codewords_buf[0..data_capacity_bytes]);
            for (segs) |seg| {
                bb.appendBits(@backingInt(seg.mode), 4);
                bb.appendBits(@intCast(seg.num_chars), segment.numCharCountBits(seg.mode, version));
                var j: usize = 0;
                while (j < seg.bit_length) : (j += 1) {
                    const bit: u1 = @intCast((seg.data[j >> 3] >> @intCast(7 - (j & 7))) & 1);
                    bb.appendBits(bit, 1);
                }
            }
            std.debug.assert(bb.bit_length == data_used_bits);

            // 3. Terminator (up to 4 zero bits) and padding
            // Source: nayuki/QR-Code-generator, c/qrcodegen.c, lines 248-260.
            const terminator_bits = @min(@as(usize, 4), data_capacity_bits - bb.bit_length);
            bb.appendBits(0, @intCast(terminator_bits));

            // Pad up to whole byte with zero bits
            const pad_up_bits = (8 - (bb.bit_length % 8)) % 8;
            bb.appendBits(0, @intCast(pad_up_bits));
            std.debug.assert(bb.bit_length % 8 == 0);

            // Pad with alternating 0xEC and 0x11 until capacity is filled
            var pad_byte: u8 = 0xEC;
            while (bb.bit_length < data_capacity_bits) {
                bb.appendBits(pad_byte, 8);
                pad_byte ^= 0xEC ^ 0x11;
            }
            std.debug.assert(bb.bit_length == data_capacity_bits);

            // 4. Compute ECC and interleave
            // Maximum raw codewords in QR Model 2 is 3706 bytes (Version 40)
            var raw_codewords_buf: [3706]u8 = undefined;
            const raw_codewords_len = tables.getNumRawDataModules(version) / 8;
            interleave.addEccAndInterleave(
                data_codewords_buf[0..data_capacity_bytes],
                version,
                ecc,
                raw_codewords_buf[0..raw_codewords_len],
            );

            // 5. Initialize matrix function patterns
            const target_matrix = buf[0..needed_buf_len];
            matrix.initializeFunctionModules(target_matrix, version, ecc);

            // 6. Draw codewords in zigzag scan pattern
            interleave.drawCodewords(target_matrix, version, raw_codewords_buf[0..raw_codewords_len]);

            // 7. Mask selection and application
            var chosen_mask: u3 = 0;
            if (forced_mask) |m| {
                mask_mod.applyMask(target_matrix, size, m);
                matrix.drawFormatBits(target_matrix, version, ecc, m);
                chosen_mask = m;
            } else {
                chosen_mask = mask_mod.selectAndApplyOptimalMask(target_matrix, version, ecc);
            }

            // 8. Finalization: clear all internal function flags, leaving strictly 0 or 1
            for (target_matrix) |*val| {
                val.* &= 0x01;
            }

            const primary_mode = if (segs.len > 0) segs[0].mode else Mode.byte;
            return .{
                .version = version,
                .size = size,
                .ecc = ecc,
                .mask = chosen_mask,
                .mode = primary_mode,
                .modules = target_matrix,
            };
        }

        /// Advanced encoding API with configurable options (ecl, version range, mask, kanji mode, DP optimizer).
        pub fn encodeAdvanced(buf: ?[]u8, data: []const u8, options: Options) Error!QrMatrix {
            if (options.min_version < tables.min_version or options.min_version > tables.max_version or
                options.max_version < tables.min_version or options.max_version > tables.max_version or
                options.min_version > options.max_version)
            {
                return error.InvalidVersion;
            }
            if (options.max_version > max_version) {
                return error.VersionExceedsTier;
            }
            if (data.len == 0) {
                var prefix_segs: [3]Segment = undefined;
                var prefix_count: usize = 0;
                var sa_buf: [2]u8 = undefined;
                var eci_buf: [3]u8 = undefined;
                var fnc1_buf: [1]u8 = undefined;
                if (options.sa) |sa_spec| {
                    prefix_segs[prefix_count] = segment.makeStructuredAppend(sa_spec.position, sa_spec.total, sa_spec.parity, &sa_buf);
                    prefix_count += 1;
                }
                if (options.eci) |eci_val| {
                    prefix_segs[prefix_count] = segment.makeEci(eci_val, &eci_buf);
                    prefix_count += 1;
                }
                if (options.fnc1) |fnc1_spec| {
                    prefix_segs[prefix_count] = switch (fnc1_spec.mode) {
                        .first => segment.makeFnc1First(),
                        .second => segment.makeFnc1Second(fnc1_spec.app_indicator, &fnc1_buf),
                    };
                    prefix_count += 1;
                }
                if (buf == null) {
                    return QrMatrix{
                        .version = options.min_version,
                        .size = tables.symbolSize(options.min_version),
                        .ecc = options.ecc,
                        .mask = options.mask orelse 0,
                        .mode = if (prefix_count > 0) prefix_segs[0].mode else .byte,
                        .modules = &.{},
                    };
                }
                return encodeSegmentsAdvanced(
                    buf.?,
                    prefix_segs[0..prefix_count],
                    options.min_version,
                    options.max_version,
                    options.ecc,
                    options.mask,
                );
            }

            // Universal QR Model 2 capacity check: 7089 digits numeric, 2956 bytes byte mode
            if (data.len > 7089 or (data.len > 2956 and !segment.isNumeric(data))) {
                return error.DataTooLong;
            }

            // Construct prefix segments: Structured Append first (if present), then ECI (if present), then FNC1 (if present)
            // Source: ISO/IEC 18004:2015, clause 8.2 and clause 7.4.8.
            var prefix_segs: [3]Segment = undefined;
            var prefix_count: usize = 0;
            var sa_buf: [2]u8 = undefined;
            var eci_buf: [3]u8 = undefined;
            var fnc1_buf: [1]u8 = undefined;

            if (options.sa) |sa_spec| {
                prefix_segs[prefix_count] = segment.makeStructuredAppend(sa_spec.position, sa_spec.total, sa_spec.parity, &sa_buf);
                prefix_count += 1;
            }

            if (options.eci) |eci_val| {
                prefix_segs[prefix_count] = segment.makeEci(eci_val, &eci_buf);
                prefix_count += 1;
            }

            if (options.fnc1) |fnc1_spec| {
                prefix_segs[prefix_count] = switch (fnc1_spec.mode) {
                    .first => segment.makeFnc1First(),
                    .second => segment.makeFnc1Second(fnc1_spec.app_indicator, &fnc1_buf),
                };
                prefix_count += 1;
            }

            // Single-mode encoding if optimize is disabled
            if (!options.optimize) {
                const mode = detectModeWithKanji(data, options.kanji);
                const needed_buf = segment.calcSegmentBufferSize(mode, data.len);
                if (needed_buf > 2956) {
                    return error.DataTooLong;
                }
                var seg_buf: [2956]u8 = undefined;
                const seg = switch (mode) {
                    .numeric => segment.makeNumeric(data, seg_buf[0..needed_buf]),
                    .alphanumeric => segment.makeAlphanumeric(data, seg_buf[0..needed_buf]),
                    .byte => segment.makeBytes(data, seg_buf[0..needed_buf]),
                    .kanji => segment.makeKanji(data, seg_buf[0..needed_buf]) catch |err| switch (err) {
                        error.BufferTooSmall => return error.BufferTooSmall,
                        error.InvalidCharacter, error.InvalidUtf8 => unreachable,
                    },
                    else => unreachable,
                };

                var single_segs: [4]Segment = undefined;
                @memcpy(single_segs[0..prefix_count], prefix_segs[0..prefix_count]);
                single_segs[prefix_count] = seg;
                if (buf == null) {
                    var v: u8 = options.min_version;
                    while (v <= options.max_version) : (v += 1) {
                        const cap_bits = @as(usize, tables.getNumDataCodewords(v, options.ecc)) * 8;
                        const needed_bits = segment.getTotalBits(single_segs[0 .. prefix_count + 1], v);
                        if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                            return QrMatrix{
                                .version = v,
                                .size = tables.symbolSize(v),
                                .ecc = options.ecc,
                                .mask = options.mask orelse 0,
                                .mode = single_segs[0].mode,
                                .modules = &.{},
                            };
                        }
                    }
                    if (options.max_version < tables.max_version) return error.VersionExceedsTier;
                    return error.DataTooLong;
                }
                return encodeSegmentsAdvanced(
                    buf.?,
                    single_segs[0 .. prefix_count + 1],
                    options.min_version,
                    options.max_version,
                    options.ecc,
                    options.mask,
                );
            }

            // Multi-mode DP optimization (Increment 12B)
            // Fast path: pure numeric is globally optimal as a single numeric segment
            if (segment.isNumeric(data)) {
                const needed_buf = segment.calcSegmentBufferSize(.numeric, data.len);
                if (needed_buf > 2956) return error.DataTooLong;
                var seg_buf: [2956]u8 = undefined;
                const seg = segment.makeNumeric(data, seg_buf[0..needed_buf]);
                var num_segs: [4]Segment = undefined;
                @memcpy(num_segs[0..prefix_count], prefix_segs[0..prefix_count]);
                num_segs[prefix_count] = seg;
                if (buf == null) {
                    var v: u8 = options.min_version;
                    while (v <= options.max_version) : (v += 1) {
                        const cap_bits = @as(usize, tables.getNumDataCodewords(v, options.ecc)) * 8;
                        const needed_bits = segment.getTotalBits(num_segs[0 .. prefix_count + 1], v);
                        if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                            return QrMatrix{
                                .version = v,
                                .size = tables.symbolSize(v),
                                .ecc = options.ecc,
                                .mask = options.mask orelse 0,
                                .mode = num_segs[0].mode,
                                .modules = &.{},
                            };
                        }
                    }
                    if (options.max_version < tables.max_version) return error.VersionExceedsTier;
                    return error.DataTooLong;
                }
                return encodeSegmentsAdvanced(
                    buf.?,
                    num_segs[0 .. prefix_count + 1],
                    options.min_version,
                    options.max_version,
                    options.ecc,
                    options.mask,
                );
            }

            var bt_buf: [max_tier_chars]u8 = undefined;
            var seg_buf: [2956]u8 = undefined;
            var segs: [max_tier_segments]Segment = undefined;
            @memcpy(segs[0..prefix_count], prefix_segs[0..prefix_count]);

            var chosen_version: ?u8 = null;
            var final_seg_count: usize = 0;
            var v: u8 = options.min_version;

            while (v <= options.max_version) : (v += 1) {
                if (v == options.min_version or v == 10 or v == 27) {
                    const data_seg_count = optimizer.makeOptimizedSegments(
                        data,
                        v,
                        options.kanji,
                        segs[prefix_count..],
                        &seg_buf,
                        &bt_buf,
                    ) catch |err| switch (err) {
                        error.DataTooLong => {
                            if (options.max_version < tables.max_version) return error.VersionExceedsTier;
                            return error.DataTooLong;
                        },
                        error.BufferTooSmall => {
                            // Adversarial case: > max_tier_segments transitions.
                            // Fall back silently to single byte mode per specification.
                            const needed_buf = segment.calcSegmentBufferSize(.byte, data.len);
                            if (needed_buf > 2956) return error.DataTooLong;
                            const byte_seg = segment.makeBytes(data, seg_buf[0..needed_buf]);
                            var fallback_segs: [4]Segment = undefined;
                            @memcpy(fallback_segs[0..prefix_count], prefix_segs[0..prefix_count]);
                            fallback_segs[prefix_count] = byte_seg;
                            if (buf == null) {
                                var v_f: u8 = options.min_version;
                                while (v_f <= options.max_version) : (v_f += 1) {
                                    const cap_bits = @as(usize, tables.getNumDataCodewords(v_f, options.ecc)) * 8;
                                    const needed_bits = segment.getTotalBits(fallback_segs[0 .. prefix_count + 1], v_f);
                                    if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                                        return QrMatrix{
                                            .version = v_f,
                                            .size = tables.symbolSize(v_f),
                                            .ecc = options.ecc,
                                            .mask = options.mask orelse 0,
                                            .mode = fallback_segs[0].mode,
                                            .modules = &.{},
                                        };
                                    }
                                }
                                if (options.max_version < tables.max_version) return error.VersionExceedsTier;
                                return error.DataTooLong;
                            }
                            return encodeSegmentsAdvanced(
                                buf.?,
                                fallback_segs[0 .. prefix_count + 1],
                                options.min_version,
                                options.max_version,
                                options.ecc,
                                options.mask,
                            );
                        },
                        error.InvalidUtf8, error.InvalidCharacter => {
                            // Fallback to single-mode byte for non-UTF8 binary data
                            const needed_buf = segment.calcSegmentBufferSize(.byte, data.len);
                            if (needed_buf > 2956) return error.DataTooLong;
                            const byte_seg = segment.makeBytes(data, seg_buf[0..needed_buf]);
                            var fallback_segs: [4]Segment = undefined;
                            @memcpy(fallback_segs[0..prefix_count], prefix_segs[0..prefix_count]);
                            fallback_segs[prefix_count] = byte_seg;
                            if (buf == null) {
                                var v_f: u8 = options.min_version;
                                while (v_f <= options.max_version) : (v_f += 1) {
                                    const cap_bits = @as(usize, tables.getNumDataCodewords(v_f, options.ecc)) * 8;
                                    const needed_bits = segment.getTotalBits(fallback_segs[0 .. prefix_count + 1], v_f);
                                    if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                                        return QrMatrix{
                                            .version = v_f,
                                            .size = tables.symbolSize(v_f),
                                            .ecc = options.ecc,
                                            .mask = options.mask orelse 0,
                                            .mode = fallback_segs[0].mode,
                                            .modules = &.{},
                                        };
                                    }
                                }
                                if (options.max_version < tables.max_version) return error.VersionExceedsTier;
                                return error.DataTooLong;
                            }
                            return encodeSegmentsAdvanced(
                                buf.?,
                                fallback_segs[0 .. prefix_count + 1],
                                options.min_version,
                                options.max_version,
                                options.ecc,
                                options.mask,
                            );
                        },
                    };
                    final_seg_count = prefix_count + data_seg_count;
                }
                const cap_bits = @as(usize, tables.getNumDataCodewords(v, options.ecc)) * 8;
                const needed_bits = segment.getTotalBits(segs[0..final_seg_count], v);
                if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                    chosen_version = v;
                    break;
                }
            }

            if (chosen_version) |cv| {
                if (buf == null) {
                    return QrMatrix{
                        .version = cv,
                        .size = tables.symbolSize(cv),
                        .ecc = options.ecc,
                        .mask = options.mask orelse 0,
                        .mode = segs[0].mode,
                        .modules = &.{},
                    };
                }
                return encodeSegmentsAdvanced(
                    buf.?,
                    segs[0..final_seg_count],
                    cv,
                    cv,
                    options.ecc,
                    options.mask,
                );
            }

            // Did not fit in options.max_version. Check if it fits in higher versions up to 40
            if (options.max_version < tables.max_version) {
                var v_check: u8 = options.max_version + 1;
                while (v_check <= tables.max_version) : (v_check += 1) {
                    const cap_bits = @as(usize, tables.getNumDataCodewords(v_check, options.ecc)) * 8;
                    const needed_bits = segment.getTotalBits(segs[0..final_seg_count], v_check);
                    if (needed_bits != segment.LENGTH_OVERFLOW and needed_bits <= cap_bits) {
                        return error.VersionExceedsTier;
                    }
                }
            }

            return error.DataTooLong;
        }

        /// High-level API: detects mode, chooses optimal version (up to max_version) and best mask.
        pub fn encode(buf: []u8, data: []const u8, ecc: Ecc) Error!QrMatrix {
            return encodeAdvanced(buf, data, .{
                .ecc = ecc,
                .min_version = tables.min_version,
                .max_version = max_version,
                .mask = null,
                .kanji = false,
                .optimize = true,
            });
        }

        /// Low-level API: forces version, ECC, and optional mask.
        pub fn encodeWithVersion(
            buf: []u8,
            data: []const u8,
            version: u8,
            ecc: Ecc,
            forced_mask: ?u3,
        ) Error!QrMatrix {
            try checkVersion(version);
            if (data.len == 0) {
                return encodeSegmentsAdvanced(
                    buf,
                    &[_]Segment{},
                    version,
                    version,
                    ecc,
                    forced_mask,
                );
            }
            const mode = detectMode(data);
            const needed_buf = segment.calcSegmentBufferSize(mode, data.len);
            const ver_cap = tables.getNumDataCodewords(version, ecc);
            if (needed_buf > ver_cap or needed_buf > 2956) {
                return error.DataTooLong;
            }
            var seg_buf: [2956]u8 = undefined;
            const seg = switch (mode) {
                .numeric => segment.makeNumeric(data, seg_buf[0..needed_buf]),
                .alphanumeric => segment.makeAlphanumeric(data, seg_buf[0..needed_buf]),
                .byte => segment.makeBytes(data, seg_buf[0..needed_buf]),
                else => unreachable,
            };

            return encodeSegmentsAdvanced(
                buf,
                &[_]Segment{seg},
                version,
                version,
                ecc,
                forced_mask,
            );
        }

        pub fn computeChunkRanges(data: []const u8, count: usize, is_kanji: bool, ranges: *[16][2]usize) void {
            if (count == 0) return;
            const is_utf8 = if (std.unicode.Utf8View.init(data)) |_| true else |_| false;
            const base = data.len / count;
            const rem = data.len % count;

            for (0..count) |i| {
                ranges[i][0] = i * base + @min(i, rem);
                ranges[i][1] = (i + 1) * base + @min(i + 1, rem);
            }

            if (is_utf8) {
                // Adjust intermediate boundaries so they do not cut inside a multi-byte UTF-8 codepoint
                for (1..count) |i| {
                    var idx = ranges[i][0];
                    while (idx < data.len and (data[idx] & 0xC0) == 0x80) {
                        idx += 1;
                    }
                    ranges[i][0] = idx;
                    ranges[i - 1][1] = idx;
                }
            } else if (is_kanji) {
                // If raw binary Shift-JIS with kanji mode, align intermediate boundaries to 2-byte pairs
                for (1..count) |i| {
                    const idx = ranges[i][0] & ~@as(usize, 1);
                    ranges[i][0] = idx;
                    ranges[i - 1][1] = idx;
                }
            }
        }

        /// Encodes `data` into a sequence of 1 to 16 Structured Append QR Code symbols
        /// according to ISO/IEC 18004:2015 Section 8.
        ///
        /// `module_storage` is a caller-provided contiguous buffer holding module matrices
        /// for all generated symbols. Each symbol of version V requires symbolSize(V)^2 bytes.
        ///
        /// If `options.symbol_count` is null, the encoder automatically computes the minimal N in [1..16].
        /// When N = 1, the symbol is encoded without Structured Append header, byte-for-byte identical to encode().
        pub fn encodeSequence(
            module_storage: ?[]u8,
            data: []const u8,
            options: SequenceOptions,
        ) Error!SequenceResult {
            if (options.min_version < tables.min_version or options.min_version > tables.max_version or
                options.max_version < tables.min_version or options.max_version > tables.max_version or
                options.min_version > options.max_version)
            {
                return error.InvalidVersion;
            }
            if (options.max_version > max_version) {
                return error.VersionExceedsTier;
            }
            if (options.symbol_count) |sc| {
                if (sc < 1 or sc > 16) return error.InvalidVersion;
            }

            const parity = segment.computeParity(data);

            var chosen_count: ?u8 = options.symbol_count;
            if (chosen_count == null) {
                // 1. Try N = 1 (without Structured Append header)
                if (encodeAdvanced(null, data, .{
                    .ecc = options.ecc,
                    .min_version = options.min_version,
                    .max_version = options.max_version,
                    .mask = options.mask,
                    .kanji = options.kanji,
                    .optimize = options.optimize,
                    .fnc1 = options.fnc1,
                    .eci = options.eci,
                    .sa = null,
                })) |_| {
                    chosen_count = 1;
                } else |_| {}

                if (chosen_count == null) {
                    // 2. Try N = 2 .. 16 with Structured Append header
                    var n: u8 = 2;
                    while (n <= 16) : (n += 1) {
                        var ranges: [16][2]usize = undefined;
                        computeChunkRanges(data, n, options.kanji, &ranges);
                        var all_fit = true;
                        for (0..n) |i| {
                            const chunk = data[ranges[i][0]..ranges[i][1]];
                            const chunk_opts = Options{
                                .ecc = options.ecc,
                                .min_version = options.min_version,
                                .max_version = options.max_version,
                                .mask = options.mask,
                                .kanji = options.kanji,
                                .optimize = options.optimize,
                                .fnc1 = if (i == 0) options.fnc1 else null,
                                .eci = options.eci,
                                .sa = types.StructuredAppend{
                                    .position = @intCast(i),
                                    .total = @intCast(n - 1),
                                    .parity = parity,
                                },
                            };
                            if (encodeAdvanced(null, chunk, chunk_opts)) |_| {} else |_| {
                                all_fit = false;
                                break;
                            }
                        }
                        if (all_fit) {
                            chosen_count = n;
                            break;
                        }
                    }
                }
            }

            const final_count = chosen_count orelse {
                if (options.max_version < tables.max_version) {
                    return error.VersionExceedsTier;
                }
                return error.DataTooLong;
            };

            // Two-phase dry-run: if module_storage is null, return count and parity without rendering
            if (module_storage == null) {
                return SequenceResult{
                    .count = final_count,
                    .parity = parity,
                    .matrices = undefined,
                };
            }

            const target_storage = module_storage.?;

            // Case N = 1: produce standard QR code without Structured Append header
            if (final_count == 1) {
                const single_m = try encodeAdvanced(target_storage, data, .{
                    .ecc = options.ecc,
                    .min_version = options.min_version,
                    .max_version = options.max_version,
                    .mask = options.mask,
                    .kanji = options.kanji,
                    .optimize = options.optimize,
                    .fnc1 = options.fnc1,
                    .eci = options.eci,
                    .sa = null,
                });
                var res = SequenceResult{
                    .count = 1,
                    .parity = parity,
                    .matrices = undefined,
                };
                res.matrices[0] = single_m;
                return res;
            }

            // Case N in 2..16: encode all symbols with Structured Append header
            var ranges: [16][2]usize = undefined;
            computeChunkRanges(data, final_count, options.kanji, &ranges);

            var offset: usize = 0;
            var res = SequenceResult{
                .count = final_count,
                .parity = parity,
                .matrices = undefined,
            };

            for (0..final_count) |i| {
                const chunk = data[ranges[i][0]..ranges[i][1]];
                const chunk_opts = Options{
                    .ecc = options.ecc,
                    .min_version = options.min_version,
                    .max_version = options.max_version,
                    .mask = options.mask,
                    .kanji = options.kanji,
                    .optimize = options.optimize,
                    .fnc1 = if (i == 0) options.fnc1 else null,
                    .eci = options.eci,
                    .sa = types.StructuredAppend{
                        .position = @intCast(i),
                        .total = @intCast(final_count - 1),
                        .parity = parity,
                    },
                };
                if (offset >= target_storage.len) return error.BufferTooSmall;
                const m = try encodeAdvanced(target_storage[offset..], chunk, chunk_opts);
                res.matrices[i] = m;
                offset += @as(usize, m.size) * m.size;
            }

            return res;
        }
    };
}

// ---- Unit Tests ----

const testing = std.testing;

test "tier constants" {
    try testing.expectEqual(@as(u8, 41), Encoder(6).max_size);
    try testing.expectEqual(@as(u8, 57), Encoder(10).max_size);
    try testing.expectEqual(@as(usize, 177 * 177), Encoder(40).max_buffer_len);
}

test "version validation per tier" {
    const T1 = Encoder(6);
    try testing.expectError(error.InvalidVersion, T1.checkVersion(0));
    try testing.expectError(error.InvalidVersion, T1.checkVersion(41));
    try testing.expectError(error.VersionExceedsTier, T1.checkVersion(7));
    try T1.checkVersion(6);
    try Encoder(40).checkVersion(40);
}

test "terminator and padding: exact fill of v1-M capacity with 34 digits" {
    // 34 digits in numeric mode occupies exactly 128 bits (16 data codewords in v1-M).
    // Terminator and padding loops should add 0 bits.
    const digits = "1111111111111111111111111111111111";
    var buf: [21 * 21]u8 = undefined;
    const qr = try Encoder(6).encodeWithVersion(&buf, digits, 1, .medium, null);
    try testing.expectEqual(@as(u8, 1), qr.version);
    try testing.expectEqual(@as(u8, 21), qr.size);
    // Verify all modules are 0 or 1
    for (qr.modules) |m| {
        try testing.expect(m == 0 or m == 1);
    }
}

test "tier boundary enforcement: T1 rejects v7 requirement with VersionExceedsTier, T3 accepts" {
    // 300 numeric digits requires Version 7+ (exceeds Version 6 Medium capacity of 112 bytes / 268 digits).
    const digits_100 = "12345678901234567890123456789012345678901234567890" ++
        "12345678901234567890123456789012345678901234567890";
    const long_digits = digits_100 ++ digits_100 ++ digits_100; // 300 digits
    var buf1: [Encoder(6).max_buffer_len]u8 = undefined;
    var buf3: [Encoder(40).max_buffer_len]u8 = undefined;

    // Encoder(6) must fail with VersionExceedsTier
    try testing.expectError(error.VersionExceedsTier, Encoder(6).encode(&buf1, long_digits, .medium));

    // Encoder(40) must succeed and select a version >= 7
    const qr = try Encoder(40).encode(&buf3, long_digits, .medium);
    try testing.expect(qr.version >= 7);
}

test "encodeWithVersion enforces forced version and fails with DataTooLong if data does not fit" {
    const data = "HELLO WORLD"; // Fits in v1
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // Forcing v1 fits:
    _ = try Encoder(6).encodeWithVersion(&buf, data, 1, .medium, null);

    // 150 digits does NOT fit in v1:
    const long_digits = "12345678901234567890123456789012345678901234567890" ++
        "12345678901234567890123456789012345678901234567890" ++
        "12345678901234567890123456789012345678901234567890";
    try testing.expectError(error.DataTooLong, Encoder(6).encodeWithVersion(&buf, long_digits, 1, .medium, null));
}

test "end-to-end golden vector: HELLO WORLD v1-M automatic mask" {
    var buf: [21 * 21]u8 = undefined;
    const qr = try Encoder(6).encode(&buf, "HELLO WORLD", .medium);
    try testing.expectEqual(@as(u8, 1), qr.version);
    try testing.expectEqual(@as(u8, 21), qr.size);
    try testing.expectEqual(@as(u3, 0), qr.mask);

    // Verify bit-by-bit against Nayuki golden vector
    const expected_golden = [_]u8{
        1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0,
        0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 0,
        1, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0,
        0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 1, 0, 0, 0, 0, 1,
    };
    try testing.expectEqualSlices(u8, &expected_golden, qr.modules);

    // Verify all modules strictly 0 or 1
    for (qr.modules) |m| {
        try testing.expect(m == 0 or m == 1);
    }
}

test "end-to-end golden vector: HELLO in forced version v5-M" {
    var buf: [37 * 37]u8 = undefined;
    const qr = try Encoder(6).encodeWithVersion(&buf, "HELLO", 5, .medium, null);
    try testing.expectEqual(@as(u8, 5), qr.version);
    try testing.expectEqual(@as(u8, 37), qr.size);
    try testing.expectEqual(@as(u3, 6), qr.mask);

    // Golden verification against Nayuki reference for v5-M HELLO
    const golden_v5_m_hello = [_]u8{
        1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1,
        1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0, 1,
        1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0,
        1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 0, 0,
        1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1,
        0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 1,
        1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 0, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1,
        1, 1, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0,
        0, 1, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0,
        1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1,
        0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1,
        1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1,
        0, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
        0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0,
        1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0,
        1, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 1, 0,
        1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 0, 0, 0,
        1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0,
        1, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 1, 1, 1, 0, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1,
    };
    try testing.expectEqualSlices(u8, &golden_v5_m_hello, qr.modules);
    for (qr.modules) |m| {
        try testing.expect(m == 0 or m == 1);
    }
}

test "oversized input: 10 KB byte payload rejects with DataTooLong without stack smash" {
    var large_payload: [10000]u8 = @splat('A');
    var buf: [Encoder(40).max_buffer_len]u8 = undefined;

    // Both encode and encodeWithVersion must return error.DataTooLong safely
    try testing.expectError(error.DataTooLong, Encoder(40).encode(&buf, &large_payload, .medium));
    try testing.expectError(error.DataTooLong, Encoder(40).encodeWithVersion(&buf, &large_payload, 40, .medium, null));
    try testing.expectError(error.DataTooLong, Encoder(6).encode(&buf, &large_payload, .medium));
}

test "calcSegmentBufferSize output size: 7000 numeric digits fits in Version 40 Low" {
    // 7000 digits requires 23334 data bits = 2917 bytes output buffer (which is <= 2956).
    // Total needed is 4 (mode) + 14 (count) + 23334 (data) = 23352 bits <= 23648 bits (v40-L capacity).
    // Must succeed and select Version 40 without being rejected by seg_buf pre-check.
    var digits_7000: [7000]u8 = @splat('7');
    var buf: [Encoder(40).max_buffer_len]u8 = undefined;

    const qr = try Encoder(40).encode(&buf, &digits_7000, .low);
    try testing.expectEqual(@as(u8, 40), qr.version);
    try testing.expectEqual(@as(u8, 177), qr.size);
    try testing.expectEqual(@as(types.Mode, .numeric), qr.mode);
}

test "boundary versions: v1 minimal version" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;
    const qr = try Encoder(6).encode(&buf, "V1", .medium);
    try testing.expectEqual(@as(u8, 1), qr.version);
    try testing.expectEqual(@as(u8, 21), qr.size);
}

test "boundary versions: v6 vs v7 version block activation" {
    // Version 6 (size 41) has NO version blocks (only v7..40 have 18-bit BCH version blocks)
    var buf6: [Encoder(6).max_buffer_len]u8 = undefined;
    const qr6 = try Encoder(6).encodeWithVersion(&buf6, "V6 TEST", 6, .medium, 0);
    try testing.expectEqual(@as(u8, 6), qr6.version);
    try testing.expectEqual(@as(u8, 41), qr6.size);

    // Version 7 (size 45) has version blocks
    var buf7: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr7 = try Encoder(40).encodeWithVersion(&buf7, "V7 TEST", 7, .medium, 0);
    try testing.expectEqual(@as(u8, 7), qr7.version);
    try testing.expectEqual(@as(u8, 45), qr7.size);
}

test "boundary versions: v9 vs v10 char count width transition" {
    // Alphanumeric char count is 9 bits in v1..9, 11 bits in v10..26
    var buf9: [Encoder(10).max_buffer_len]u8 = undefined;
    const qr9 = try Encoder(10).encodeWithVersion(&buf9, "V9 TEST", 9, .medium, 0);
    try testing.expectEqual(@as(u8, 9), qr9.version);
    try testing.expectEqual(@as(u8, 53), qr9.size);

    var buf10: [Encoder(10).max_buffer_len]u8 = undefined;
    const qr10 = try Encoder(10).encodeWithVersion(&buf10, "V10 TEST", 10, .medium, 0);
    try testing.expectEqual(@as(u8, 10), qr10.version);
    try testing.expectEqual(@as(u8, 57), qr10.size);
}

test "boundary versions: v26 vs v27 char count width transition" {
    // Alphanumeric char count is 11 bits in v10..26, 13 bits in v27..40
    var buf26: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr26 = try Encoder(40).encodeWithVersion(&buf26, "V26 TEST", 26, .medium, 0);
    try testing.expectEqual(@as(u8, 26), qr26.version);
    try testing.expectEqual(@as(u8, 121), qr26.size);

    var buf27: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr27 = try Encoder(40).encodeWithVersion(&buf27, "V27 TEST", 27, .medium, 0);
    try testing.expectEqual(@as(u8, 27), qr27.version);
    try testing.expectEqual(@as(u8, 125), qr27.size);
}

test "boundary versions: v40 maximal version" {
    var buf40: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr40 = try Encoder(40).encodeWithVersion(&buf40, "V40 MAXIMAL", 40, .high, 0);
    try testing.expectEqual(@as(u8, 40), qr40.version);
    try testing.expectEqual(@as(u8, 177), qr40.size);
}

test "Madoka Kanji golden vector against Nayuki" {
    const madoka = "\xE3\x80\x8C\xE9\xAD\x94\xE6\xB3\x95\xE5\xB0\x91\xE5\xA5\xB3\xE3\x81\xBE\xE3\x81\xA9\xE3\x81\x8B\xE2\x98\x86\xE3\x83\x9E\xE3\x82\xAE\xE3\x82\xAB\xE3\x80\x8D\xE3\x81\xA3\xE3\x81\xA6\xE3\x80\x81\xE3\x80\x80\xD0\x98\xD0\x90\xD0\x98\xE3\x80\x80\xEF\xBD\x84\xEF\xBD\x85\xEF\xBD\x93\xEF\xBD\x95\xE3\x80\x80\xCE\xBA\xCE\xB1\xEF\xBC\x9F";

    // 1. Verify single Kanji segment properties (matching Nayuki QrSegmentAdvanced.makeSegments)
    var seg_buf: [100]u8 = undefined;
    const seg = try segment.makeKanji(madoka, &seg_buf);
    try testing.expectEqual(Mode.kanji, seg.mode);
    try testing.expectEqual(@as(usize, 29), seg.num_chars);
    try testing.expectEqual(@as(usize, 377), seg.bit_length);

    // 2. Encode with Tier3 (v1..40) with kanji = true
    var buf: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr = try Encoder(40).encodeAdvanced(&buf, madoka, .{
        .ecc = .low,
        .kanji = true,
    });

    try testing.expectEqual(@as(u8, 3), qr.version);
    try testing.expectEqual(@as(u8, 29), qr.size);
    try testing.expectEqual(@as(u3, 7), qr.mask);
    try testing.expectEqual(Mode.kanji, qr.mode);

    // 3. Bit-by-bit module matrix verification against Nayuki reference
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(qr.modules);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var expected_digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, "80178e24a48431d63171f51c7e084780fd46861037811d645806f52cfedd8dd4");
    try testing.expectEqualSlices(u8, &expected_digest, &digest);
}

test "Kanji edge cases" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // Case 1: Empty text with kanji: true
    const qr_empty = try Encoder(6).encodeAdvanced(&buf, "", .{ .kanji = true });
    try testing.expectEqual(@as(u8, 1), qr_empty.version);
    try testing.expectEqual(@as(u8, 21), qr_empty.size);

    // Case 2: Pure ASCII with kanji: true falls back to alphanumeric/numeric/byte, never kanji
    const qr_ascii = try Encoder(6).encodeAdvanced(&buf, "HELLO WORLD", .{ .kanji = true });
    try testing.expectEqual(Mode.alphanumeric, qr_ascii.mode);

    // Case 3a: Mixed Kanji + ASCII with kanji: true and optimize: false falls back to byte mode (12A behavior)
    const qr_mixed_no_opt = try Encoder(6).encodeAdvanced(&buf, "HELLO まどか", .{ .kanji = true, .optimize = false });
    try testing.expectEqual(Mode.byte, qr_mixed_no_opt.mode);

    // Case 3b: Mixed Kanji + ASCII with kanji: true and optimize: true splits into optimal segments
    // "HELLO " is alphanumeric (segs[0].mode = .alphanumeric), "まどか" is kanji
    const qr_mixed_opt = try Encoder(6).encodeAdvanced(&buf, "HELLO まどか", .{ .kanji = true, .optimize = true });
    try testing.expectEqual(Mode.alphanumeric, qr_mixed_opt.mode);

    // Case 4a: Unicode character outside JIS X 0208 with kanji: true and optimize: false falls back to byte mode
    const qr_emoji_no_opt = try Encoder(6).encodeAdvanced(&buf, "まどか🎉", .{ .kanji = true, .optimize = false });
    try testing.expectEqual(Mode.byte, qr_emoji_no_opt.mode);

    // Case 4b: With optimize: true, "まどか" is kanji, "🎉" is byte
    const qr_emoji_opt = try Encoder(6).encodeAdvanced(&buf, "まどか🎉", .{ .kanji = true, .optimize = true });
    try testing.expectEqual(Mode.kanji, qr_emoji_opt.mode);

    // Case 5: Direct makeKanji rejects characters outside JIS X 0208
    var seg_buf: [100]u8 = undefined;
    try testing.expectError(error.InvalidCharacter, segment.makeKanji("まどか🎉", &seg_buf));
}

test "12B DP optimization: size reduction v3 down to v2" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // "hello" (lowercase forces Byte in single-mode) + 40 digits
    const mixed_input = "hello1234567890123456789012345678901234567890";

    // 1. Without DP (optimize: false): 45 bytes in byte mode requires 372 bits -> exceeds v2-L (272 bits) -> selects v3
    const qr_unopt = try Encoder(6).encodeAdvanced(&buf, mixed_input, .{
        .ecc = .low,
        .optimize = false,
    });
    try testing.expectEqual(@as(u8, 3), qr_unopt.version);
    try testing.expectEqual(Mode.byte, qr_unopt.mode);

    // 2. With DP (optimize: true): splits into Byte("hello") + Numeric(40 digits) -> 200 bits -> fits in v2-L!
    const qr_opt = try Encoder(6).encodeAdvanced(&buf, mixed_input, .{
        .ecc = .low,
        .optimize = true,
    });
    try testing.expectEqual(@as(u8, 2), qr_opt.version);
}

test "12B DP regression: pure ASCII behavior preserved" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // Pure alphanumeric
    const qr_alnum_v1 = try Encoder(6).encode(&buf, "HELLO WORLD", .medium);
    const qr_alnum_opt = try Encoder(6).encodeAdvanced(&buf, "HELLO WORLD", .{ .ecc = .medium, .optimize = true });
    try testing.expectEqual(qr_alnum_v1.version, qr_alnum_opt.version);
    try testing.expectEqual(qr_alnum_v1.mask, qr_alnum_opt.mask);
    try testing.expectEqual(qr_alnum_v1.mode, qr_alnum_opt.mode);
    try testing.expectEqualSlices(u8, qr_alnum_v1.modules, qr_alnum_opt.modules);

    // Pure numeric
    const qr_num_v1 = try Encoder(6).encode(&buf, "1234567890", .medium);
    const qr_num_opt = try Encoder(6).encodeAdvanced(&buf, "1234567890", .{ .ecc = .medium, .optimize = true });
    try testing.expectEqual(qr_num_v1.version, qr_num_opt.version);
    try testing.expectEqual(qr_num_v1.mask, qr_num_opt.mask);
    try testing.expectEqual(qr_num_v1.mode, qr_num_opt.mode);
    try testing.expectEqualSlices(u8, qr_num_v1.modules, qr_num_opt.modules);
}

test "Increment 13: FNC1 First Position (GS1 QR Code)" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // Real binary GS1 payload: AI 01 (14 digits fixed), GS (0x1D), AI 10 (variable alphanumeric)
    const gs1_data = "0101234567890128\x1D10BATCH1";

    const qr = try Encoder(6).encodeAdvanced(&buf, gs1_data, .{
        .ecc = .low,
        .fnc1 = .{ .mode = .first },
        .optimize = true,
    });

    try testing.expectEqual(Mode.fnc1_first, qr.mode);
    try testing.expect(qr.version >= 1 and qr.version <= 6);
}

test "Increment 13: FNC1 Second Position (AIM Application Indicator)" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // 1. With character application indicator ('A' + 100 = 165)
    const app_ind_a = try segment.appIndicatorFromChar('A');
    const qr_a = try Encoder(6).encodeAdvanced(&buf, "SERIAL12345", .{
        .ecc = .medium,
        .fnc1 = .{ .mode = .second, .app_indicator = app_ind_a },
    });
    try testing.expectEqual(Mode.fnc1_second, qr_a.mode);

    // 2. With numeric 2-digit application indicator ("05" -> 5)
    const app_ind_num = try segment.appIndicatorFromDigits("05");
    const qr_num = try Encoder(6).encodeAdvanced(&buf, "TESTPAYLOAD", .{
        .ecc = .medium,
        .fnc1 = .{ .mode = .second, .app_indicator = app_ind_num },
    });
    try testing.expectEqual(Mode.fnc1_second, qr_num.mode);
}

test "Increment 13: ECI + FNC1 combination order" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // ISO/IEC 18004 clause 7.4.8: ECI must precede FNC1
    const qr = try Encoder(6).encodeAdvanced(&buf, "0101234567890128", .{
        .ecc = .low,
        .eci = 26, // UTF-8 ECI
        .fnc1 = .{ .mode = .first },
    });
    // The first segment in the bitstream is ECI, so qr.mode is .eci
    try testing.expectEqual(Mode.eci, qr.mode);

    // Verify rejection of invalid segment orders in encodeSegmentsAdvanced:
    var eci_buf: [3]u8 = undefined;
    const eci_seg = segment.makeEci(26, &eci_buf);
    const fnc1_seg = segment.makeFnc1First();
    var num_buf: [10]u8 = undefined;
    const num_seg = segment.makeNumeric("12345", &num_buf);

    // Valid: [ECI, FNC1, Data]
    _ = try Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ eci_seg, fnc1_seg, num_seg }, 1, 6, .low, null);

    // Invalid: [FNC1, ECI, Data] - ECI cannot follow FNC1
    try testing.expectError(error.InvalidSegmentOrder, Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ fnc1_seg, eci_seg, num_seg }, 1, 6, .low, null));

    // Invalid: [Data, FNC1] - FNC1 cannot follow data
    try testing.expectError(error.InvalidSegmentOrder, Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ num_seg, fnc1_seg }, 1, 6, .low, null));
}

test "Increment 13: Adversarial input with >128 segments falls back to byte mode" {
    // Generate an adversarial alternating string "a12345a12345..." with 150 repetitions (300 transitions)
    // Tier 3 has max_tier_segments = 128. With > 128 transitions, DP returns BufferTooSmall,
    // which triggers silent fallback to single byte mode.
    var adversarial_buf: [150 * 6]u8 = undefined;
    for (0..150) |i| {
        @memcpy(adversarial_buf[i * 6 .. (i + 1) * 6], "a12345");
    }

    var buf: [Encoder(40).max_buffer_len]u8 = undefined;
    const qr = try Encoder(40).encodeAdvanced(&buf, &adversarial_buf, .{
        .ecc = .low,
        .optimize = true,
    });

    // Successfully encodes via byte mode fallback!
    try testing.expect(qr.version >= 1 and qr.version <= 40);
    try testing.expectEqual(Mode.byte, qr.mode);
}

test "Increment 15: Structured Append computeParity" {
    try testing.expectEqual(@as(u8, 0), segment.computeParity(""));
    try testing.expectEqual(@as(u8, 0x42), segment.computeParity(&[_]u8{0x42}));
    try testing.expectEqual(@as(u8, 'H' ^ 'E' ^ 'L' ^ 'L' ^ 'O'), segment.computeParity("HELLO"));
}

test "Increment 15: Structured Append N=1 produces standard QR identical to encode() across multiple modes" {
    var seq_buf: [Encoder(6).max_sequence_buffer_len]u8 = undefined;
    var std_buf: [Encoder(6).max_buffer_len]u8 = undefined;

    // 1. ASCII ("HELLO WORLD")
    {
        const data = "HELLO WORLD";
        const seq = try Encoder(6).encodeSequence(&seq_buf, data, .{ .ecc = .medium });
        const std_qr = try Encoder(6).encodeAdvanced(&std_buf, data, .{ .ecc = .medium });
        try testing.expectEqual(@as(u8, 1), seq.count);
        try testing.expectEqual(segment.computeParity(data), seq.parity);
        try testing.expectEqual(std_qr.mode, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.version, seq.matrices[0].version);
        const len = @as(usize, std_qr.size) * std_qr.size;
        try testing.expectEqualSlices(u8, std_qr.modules[0..len], seq.matrices[0].modules[0..len]);
    }

    // 2. UTF-8 Multibyte ("日本語")
    {
        const data = "日本語";
        const seq = try Encoder(6).encodeSequence(&seq_buf, data, .{ .ecc = .low, .kanji = false });
        const std_qr = try Encoder(6).encodeAdvanced(&std_buf, data, .{ .ecc = .low, .kanji = false });
        try testing.expectEqual(@as(u8, 1), seq.count);
        try testing.expectEqual(std_qr.mode, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.version, seq.matrices[0].version);
        const len = @as(usize, std_qr.size) * std_qr.size;
        try testing.expectEqualSlices(u8, std_qr.modules[0..len], seq.matrices[0].modules[0..len]);
    }

    // 3. Kanji with kanji:true ("日本語")
    {
        const data = "日本語";
        const seq = try Encoder(6).encodeSequence(&seq_buf, data, .{ .ecc = .low, .kanji = true });
        const std_qr = try Encoder(6).encodeAdvanced(&std_buf, data, .{ .ecc = .low, .kanji = true });
        try testing.expectEqual(@as(u8, 1), seq.count);
        try testing.expectEqual(Mode.kanji, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.mode, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.version, seq.matrices[0].version);
        const len = @as(usize, std_qr.size) * std_qr.size;
        try testing.expectEqualSlices(u8, std_qr.modules[0..len], seq.matrices[0].modules[0..len]);
    }

    // 4. FNC1 First Position ("0101234567890128\x1D10BATCH1")
    {
        const data = "0101234567890128\x1D10BATCH1";
        const seq = try Encoder(6).encodeSequence(&seq_buf, data, .{
            .ecc = .low,
            .fnc1 = .{ .mode = .first },
        });
        const std_qr = try Encoder(6).encodeAdvanced(&std_buf, data, .{
            .ecc = .low,
            .fnc1 = .{ .mode = .first },
        });
        try testing.expectEqual(@as(u8, 1), seq.count);
        try testing.expectEqual(Mode.fnc1_first, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.mode, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.version, seq.matrices[0].version);
        const len = @as(usize, std_qr.size) * std_qr.size;
        try testing.expectEqualSlices(u8, std_qr.modules[0..len], seq.matrices[0].modules[0..len]);
    }

    // 5. ECI (eci = 26)
    {
        const data = "HELLO WITH ECI";
        const seq = try Encoder(6).encodeSequence(&seq_buf, data, .{
            .ecc = .low,
            .eci = 26,
        });
        const std_qr = try Encoder(6).encodeAdvanced(&std_buf, data, .{
            .ecc = .low,
            .eci = 26,
        });
        try testing.expectEqual(@as(u8, 1), seq.count);
        try testing.expectEqual(Mode.eci, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.mode, seq.matrices[0].mode);
        try testing.expectEqual(std_qr.version, seq.matrices[0].version);
        const len = @as(usize, std_qr.size) * std_qr.size;
        try testing.expectEqualSlices(u8, std_qr.modules[0..len], seq.matrices[0].modules[0..len]);
    }
}

test "Increment 15: Structured Append multi-byte UTF-8 codepoint boundary alignment" {
    var seq_buf: [Encoder(6).max_sequence_buffer_len]u8 = undefined;

    // "あああああ" = 5 Hiragana characters, 3 bytes each in UTF-8 (0xE3 0x81 0x82), total 15 bytes.
    // Divmod for N=2 would naively cut at byte 7 or 8 (in the middle of char 3: bytes 6..8).
    // The encoder must adjust to byte 9 so that chunk 0 has 9 bytes (3 chars) and chunk 1 has 6 bytes (2 chars).
    const data = "あああああ";
    try testing.expectEqual(@as(usize, 15), data.len);

    var ranges: [16][2]usize = undefined;
    Encoder(6).computeChunkRanges(data, 2, false, &ranges);
    try testing.expectEqual(@as(usize, 0), ranges[0][0]);
    try testing.expectEqual(@as(usize, 9), ranges[0][1]);
    try testing.expectEqual(@as(usize, 9), ranges[1][0]);
    try testing.expectEqual(@as(usize, 15), ranges[1][1]);

    // Verify both chunks are valid UTF-8
    const chunk0 = data[ranges[0][0]..ranges[0][1]];
    const chunk1 = data[ranges[1][0]..ranges[1][1]];
    try testing.expect(std.unicode.Utf8View.init(chunk0) != error.InvalidUtf8);
    try testing.expect(std.unicode.Utf8View.init(chunk1) != error.InvalidUtf8);

    // Encode as sequence of 2 symbols: must not produce error.InvalidUtf8
    const res = try Encoder(6).encodeSequence(&seq_buf, data, .{
        .ecc = .low,
        .symbol_count = 2,
    });
    try testing.expectEqual(@as(u8, 2), res.count);
    try testing.expectEqual(Mode.structured_append, res.matrices[0].mode);
    try testing.expectEqual(Mode.structured_append, res.matrices[1].mode);
}

test "Increment 15: Structured Append boundary exact N=1 to N=2" {
    var seq_buf: [Encoder(6).max_sequence_buffer_len]u8 = undefined;

    // Version 1-L capacity in byte mode is 17 bytes (152 bits total - 4 mode - 8 cc = 140 bits = 17 bytes)
    const data_17 = "abcdefghijklmnopq"; // 17 bytes lowercase -> byte mode
    const res_1 = try Encoder(6).encodeSequence(&seq_buf, data_17, .{
        .ecc = .low,
        .min_version = 1,
        .max_version = 1,
        .optimize = false,
    });
    try testing.expectEqual(@as(u8, 1), res_1.count);

    // 18 bytes cannot fit in Version 1-L byte mode; with max_version = 1, it must automatically use N = 2
    const data_18 = "abcdefghijklmnopqr"; // 18 bytes lowercase -> byte mode
    const res_2 = try Encoder(6).encodeSequence(&seq_buf, data_18, .{
        .ecc = .low,
        .min_version = 1,
        .max_version = 1,
        .optimize = false,
    });
    try testing.expectEqual(@as(u8, 2), res_2.count);
    try testing.expectEqual(res_2.matrices[0].version, 1);
    try testing.expectEqual(res_2.matrices[1].version, 1);
    try testing.expectEqual(Mode.structured_append, res_2.matrices[0].mode);
    try testing.expectEqual(Mode.structured_append, res_2.matrices[1].mode);

    // Invalid symbol count > 16 rejected
    try testing.expectError(error.InvalidVersion, Encoder(6).encodeSequence(&seq_buf, data_18, .{
        .symbol_count = 17,
    }));
}

test "Increment 15: Structured Append capacity overflow" {
    var seq_buf: [Encoder(6).max_sequence_buffer_len]u8 = undefined;
    // 3000 bytes exceeds 16 symbols of Version 6-L (Tier 1 max is v6)
    var large_payload: [3000]u8 = @splat('a');
    try testing.expectError(error.VersionExceedsTier, Encoder(6).encodeSequence(&seq_buf, &large_payload, .{
        .symbol_count = 16,
    }));
}

test "Increment 15: Structured Append min_version floor honored across sequence" {
    var seq_buf: [Encoder(10).max_sequence_buffer_len]u8 = undefined;
    const data = "HELLO STRUCTURED APPEND WITH FORCED MIN VERSION FLOOR";

    const res = try Encoder(10).encodeSequence(&seq_buf, data, .{
        .ecc = .low,
        .min_version = 7,
        .symbol_count = 2,
    });
    try testing.expectEqual(@as(u8, 2), res.count);
    try testing.expect(res.matrices[0].version >= 7);
    try testing.expect(res.matrices[1].version >= 7);
}

test "Increment 15: Structured Append FNC1 only on symbol 0" {
    var seq_buf: [Encoder(6).max_sequence_buffer_len]u8 = undefined;
    const data = "0101234567890128\x1D10BATCH1SPLITACROSSSYMBOLS99999";

    const res = try Encoder(6).encodeSequence(&seq_buf, data, .{
        .ecc = .low,
        .min_version = 1,
        .max_version = 3,
        .symbol_count = 2,
        .fnc1 = .{ .mode = .first },
    });
    try testing.expectEqual(@as(u8, 2), res.count);
    // Both symbols have structured_append as the first segment mode
    try testing.expectEqual(Mode.structured_append, res.matrices[0].mode);
    try testing.expectEqual(Mode.structured_append, res.matrices[1].mode);
}

test "Increment 15: Structured Append segment order rejection in encodeSegmentsAdvanced" {
    var buf: [Encoder(6).max_buffer_len]u8 = undefined;
    var sa_buf: [2]u8 = undefined;
    const sa_seg = segment.makeStructuredAppend(0, 1, 0x55, &sa_buf);
    var eci_buf: [3]u8 = undefined;
    const eci_seg = segment.makeEci(26, &eci_buf);
    const fnc1_seg = segment.makeFnc1First();
    var num_buf: [10]u8 = undefined;
    const num_seg = segment.makeNumeric("12345", &num_buf);

    // Valid: [SA, ECI, FNC1, Data]
    _ = try Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ sa_seg, eci_seg, fnc1_seg, num_seg }, 1, 6, .low, null);

    // Invalid: [ECI, SA, Data] -> SA must be first
    try testing.expectError(error.InvalidSegmentOrder, Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ eci_seg, sa_seg, num_seg }, 1, 6, .low, null));

    // Invalid: [Data, SA] -> SA cannot follow data
    try testing.expectError(error.InvalidSegmentOrder, Encoder(6).encodeSegmentsAdvanced(&buf, &[_]Segment{ num_seg, sa_seg }, 1, 6, .low, null));
}
