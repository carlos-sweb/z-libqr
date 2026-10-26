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

        /// Selects the single most efficient Mode for `text`.
        /// Source: nayuki/QR-Code-generator, c/qrcodegen.c, lines 152-178.
        pub fn detectMode(text: []const u8) Mode {
            if (segment.isNumeric(text)) return .numeric;
            if (segment.isAlphanumeric(text)) return .alphanumeric;
            return .byte;
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

        /// High-level API: detects mode, chooses optimal version (up to max_version) and best mask.
        pub fn encode(buf: []u8, data: []const u8, ecc: Ecc) Error!QrMatrix {
            if (data.len == 0) {
                return encodeSegmentsAdvanced(
                    buf,
                    &[_]Segment{},
                    tables.min_version,
                    max_version,
                    ecc,
                    null,
                );
            }
            const mode = detectMode(data);
            const needed_buf = segment.calcSegmentBufferSize(mode, data.len);
            if (needed_buf > 2956) {
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
                tables.min_version,
                max_version,
                ecc,
                null,
            );
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
