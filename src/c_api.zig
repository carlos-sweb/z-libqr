//! C ABI layer. `cWrapper(max_version, prefix)` exports a family of
//! `callconv(.c)` functions named `<prefix>_*` that only use C types.
//! Each tier root (src/c_t1.zig, c_t2.zig, c_t3.zig) instantiates it once.
//!
//! The declarations here must stay in sync with include/zqr.h.

const std = @import("std");
const zqr = @import("zqr");

/// Mirror of `zqr_matrix` in include/zqr.h.
pub const Matrix = extern struct {
    version: u8,
    size: u8,
    /// One of the ZQR_ECC_* values.
    ecc: u8,
    mask: u8,
    /// One of the ZQR_MODE_* values (4-bit mode indicator).
    mode: u8,
    reserved: [3]u8,
    /// Points into the caller's buffer; `size * size` bytes, 0 or 1.
    modules: ?[*]const u8,
};

/// Mirror of `zqr_options` in include/zqr.h.
pub const Options = extern struct {
    min_version: c_int,
    max_version: c_int,
    ecc: c_int,
    mask: c_int,
    kanji: c_int,
    optimize: c_int,
    fnc1: c_int,
    fnc1_app_indicator: u8,
    reserved: [3]u8,
    has_eci: c_int,
    eci: u32,
};

/// Mirror of `zqr_sequence_options` in include/zqr.h.
pub const SequenceOptions = extern struct {
    min_version: c_int,
    max_version: c_int,
    ecc: c_int,
    mask: c_int,
    kanji: c_int,
    optimize: c_int,
    fnc1: c_int,
    fnc1_app_indicator: u8,
    reserved: [3]u8,
    has_eci: c_int,
    eci: u32,
    symbol_count: c_int,
};

/// Mirror of `zqr_render_options` in include/zqr.h.
pub const RenderOptions = extern struct {
    quiet_zone: u8,
    scale: u8,
    reserved: [2]u8,
    foreground: u32,
    background: u32,
};

/// Mirror of `zqr_decode_result` in include/zqr.h.
pub const DecodeResultC = extern struct {
    bytes_written: u32,
    version: u8,
    ecc: u8,
    mask: u8,
    modes_used: u8,
    errors_corrected_format: u8,
    errors_corrected_version: u8,
    errors_corrected_data: u16,
    has_sa: u8,
    sa_position: u8,
    sa_total: u8,
    sa_parity: u8,
    has_eci: u8,
    _pad1: [3]u8 = [_]u8{ 0, 0, 0 },
    eci: u32,
    has_fnc1: u8,
    fnc1_mode: u8,
    fnc1_app_indicator: u8,
    _pad2: [1]u8 = [_]u8{0},
};

comptime {
    // Layout is part of the ABI: 8 bytes of header, then the pointer.
    std.debug.assert(@offsetOf(Matrix, "modules") == 8);
    std.debug.assert(@sizeOf(RenderOptions) == 12);
    std.debug.assert(@sizeOf(DecodeResultC) == 28);
    std.debug.assert(@offsetOf(DecodeResultC, "bytes_written") == 0);
    std.debug.assert(@offsetOf(DecodeResultC, "version") == 4);
    std.debug.assert(@offsetOf(DecodeResultC, "errors_corrected_data") == 10);
    std.debug.assert(@offsetOf(DecodeResultC, "has_sa") == 12);
    std.debug.assert(@offsetOf(DecodeResultC, "eci") == 20);
    std.debug.assert(@offsetOf(DecodeResultC, "has_fnc1") == 24);
}

/// Stable status codes. Values never change once released; new codes get
/// new numbers. Mirrors the ZQR_OK / ZQR_ERR_* macros in include/zqr.h.
pub const Status = enum(c_int) {
    ok = 0,
    data_too_long = -1,
    version_exceeds_tier = -2,
    invalid_version = -3,
    invalid_ecc = -4,
    invalid_mask = -5,
    buffer_too_small = -6,
    null_pointer = -7,
    invalid_segment_order = -8,
    unsupported = -9,

    pub fn code(self: Status) c_int {
        return @backingInt(self);
    }

    pub fn fromError(err: zqr.Error) Status {
        return switch (err) {
            error.DataTooLong => .data_too_long,
            error.VersionExceedsTier => .version_exceeds_tier,
            error.InvalidVersion => .invalid_version,
            error.BufferTooSmall => .buffer_too_small,
            error.InvalidSegmentOrder => .invalid_segment_order,
            error.Unsupported => .unsupported,
        };
    }

    pub fn message(self: Status) [:0]const u8 {
        return switch (self) {
            .ok => "ok",
            .data_too_long => "data too long for the requested version and error correction level",
            .version_exceeds_tier => "version exceeds the maximum supported by this library tier",
            .invalid_version => "version must be in 1...40",
            .invalid_ecc => "error correction level must be ZQR_ECC_LOW...ZQR_ECC_HIGH",
            .invalid_mask => "mask must be -1 (automatic) or 0...7",
            .buffer_too_small => "module buffer is smaller than size * size bytes",
            .null_pointer => "a required pointer argument is NULL",
            .invalid_segment_order => "segment ordering violates ISO/IEC 18004 specification",
            .unsupported => "requested feature or format is not supported or was disabled at build time",
        };
    }
};

/// Stable decoder status codes.
/// Mirrors the ZQR_DECODE_OK / ZQR_ERR_DECODE_* macros in include/zqr.h.
pub const DecodeStatus = enum(c_int) {
    ok = 0,
    invalid_size = -20,
    version_exceeds_tier = -21,
    format_uncorrectable = -22,
    version_uncorrectable = -23,
    rs_uncorrectable = -24,
    invalid_mode = -25,
    invalid_payload = -26,
    unexpected_eof = -27,
    buffer_too_small = -28,
    null_pointer = -29,

    pub fn code(self: DecodeStatus) c_int {
        return @backingInt(self);
    }

    pub fn fromError(err: zqr.decoder.DecodeError) DecodeStatus {
        return switch (err) {
            error.InvalidMatrixSize => .invalid_size,
            error.VersionExceedsTier => .version_exceeds_tier,
            error.FormatBitsUncorrectable => .format_uncorrectable,
            error.VersionBitsUncorrectable => .version_uncorrectable,
            error.ReedSolomonUncorrectable => .rs_uncorrectable,
            error.InvalidMode => .invalid_mode,
            error.InvalidNumericValue, error.InvalidAlphanumericValue, error.InvalidKanjiValue, error.InvalidEciAssignment => .invalid_payload,
            error.UnexpectedEndOfStream => .unexpected_eof,
            error.BufferTooSmall => .buffer_too_small,
        };
    }

    pub fn message(self: DecodeStatus) [:0]const u8 {
        return switch (self) {
            .ok => "ok",
            .invalid_size => "matrix size is not a valid QR Model 2 size",
            .version_exceeds_tier => "matrix version exceeds maximum supported by this library tier",
            .format_uncorrectable => "format information corrupted with >3 bit errors",
            .version_uncorrectable => "version information corrupted or inconsistent with matrix size",
            .rs_uncorrectable => "reed-solomon error correction failed (too many damaged codewords)",
            .invalid_mode => "invalid or reserved QR segment mode indicator",
            .invalid_payload => "invalid character or value in segment payload",
            .unexpected_eof => "unexpected end of stream while parsing segment",
            .buffer_too_small => "output buffer too small for decoded payload",
            .null_pointer => "a required pointer argument is NULL",
        };
    }
};

fn parseEcc(ecc: c_int) ?zqr.Ecc {
    if (ecc < 0 or ecc > 3) return null;
    const raw: u2 = @intCast(ecc);
    return @fromBackingInt(raw);
}

fn parseMask(mask: c_int) error{InvalidMask}!?u3 {
    if (mask == -1) return null;
    if (mask < 0 or mask > 7) return error.InvalidMask;
    const m: u3 = @intCast(mask);
    return m;
}

/// Converts a C (pointer, length) pair into a slice. A NULL pointer is only
/// accepted together with a zero length.
fn constSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| return p[0..len];
    if (len == 0) return &.{};
    return null;
}

fn writeOut(out: *Matrix, m: zqr.QrMatrix) void {
    out.* = .{
        .version = m.version,
        .size = m.size,
        .ecc = @backingInt(m.ecc),
        .mask = m.mask,
        .mode = @backingInt(m.mode),
        .reserved = @splat(0),
        .modules = m.modules.ptr,
    };
}

pub fn cWrapper(comptime max_version: u8, comptime prefix: []const u8) type {
    const E = zqr.Encoder(max_version);

    return struct {
        pub fn encode(
            data: ?[*]const u8,
            data_len: usize,
            ecc: c_int,
            buf: ?[*]u8,
            buf_len: usize,
            out: ?*Matrix,
        ) callconv(.c) c_int {
            const out_ptr = out orelse return Status.null_pointer.code();
            const bytes = constSlice(data, data_len) orelse return Status.null_pointer.code();
            const buf_ptr = buf orelse return Status.null_pointer.code();
            const level = parseEcc(ecc) orelse return Status.invalid_ecc.code();

            const m = E.encode(buf_ptr[0..buf_len], bytes, level) catch |err|
                return Status.fromError(err).code();
            writeOut(out_ptr, m);
            return Status.ok.code();
        }

        pub fn encodeWithVersion(
            data: ?[*]const u8,
            data_len: usize,
            version: c_int,
            ecc: c_int,
            mask: c_int,
            buf: ?[*]u8,
            buf_len: usize,
            out: ?*Matrix,
        ) callconv(.c) c_int {
            const out_ptr = out orelse return Status.null_pointer.code();
            const bytes = constSlice(data, data_len) orelse return Status.null_pointer.code();
            const buf_ptr = buf orelse return Status.null_pointer.code();
            if (version < 1 or version > 40) return Status.invalid_version.code();
            const level = parseEcc(ecc) orelse return Status.invalid_ecc.code();
            const mask_opt = parseMask(mask) catch return Status.invalid_mask.code();

            const m = E.encodeWithVersion(buf_ptr[0..buf_len], bytes, @intCast(version), level, mask_opt) catch |err|
                return Status.fromError(err).code();
            writeOut(out_ptr, m);
            return Status.ok.code();
        }

        pub fn encodeAdvanced(
            data: ?[*]const u8,
            data_len: usize,
            opts: ?*const Options,
            buf: ?[*]u8,
            buf_len: usize,
            out: ?*Matrix,
        ) callconv(.c) c_int {
            const out_ptr = out orelse return Status.null_pointer.code();
            const bytes = constSlice(data, data_len) orelse return Status.null_pointer.code();
            const buf_ptr = buf orelse return Status.null_pointer.code();
            const o = opts orelse return Status.null_pointer.code();

            const level = parseEcc(o.ecc) orelse return Status.invalid_ecc.code();
            const mask_val = parseMask(o.mask) catch return Status.invalid_mask.code();

            const min_v: u8 = if (o.min_version <= 0) zqr.min_version else blk: {
                if (o.min_version < zqr.min_version or o.min_version > zqr.max_version)
                    return Status.invalid_version.code();
                break :blk @intCast(o.min_version);
            };

            const max_v: u8 = if (o.max_version <= 0) max_version else blk: {
                if (o.max_version < zqr.min_version or o.max_version > zqr.max_version)
                    return Status.invalid_version.code();
                if (o.max_version > max_version)
                    return Status.version_exceeds_tier.code();
                break :blk @intCast(o.max_version);
            };

            const fnc1_opt: ?zqr.Fnc1 = switch (o.fnc1) {
                1 => .{ .mode = .first },
                2 => .{ .mode = .second, .app_indicator = o.fnc1_app_indicator },
                else => null,
            };

            const eci_opt: ?u32 = if (o.has_eci != 0) o.eci else null;

            const m = E.encodeAdvanced(buf_ptr[0..buf_len], bytes, .{
                .ecc = level,
                .min_version = min_v,
                .max_version = max_v,
                .mask = mask_val,
                .kanji = o.kanji != 0,
                .optimize = o.optimize != 0,
                .fnc1 = fnc1_opt,
                .eci = eci_opt,
            }) catch |err| return Status.fromError(err).code();

            writeOut(out_ptr, m);
            return Status.ok.code();
        }

        pub fn sequenceBufferLen(version: c_int, count: c_int) callconv(.c) usize {
            const v: u8 = if (version <= 0) max_version else blk: {
                if (version < 1 or version > 40 or version > max_version) return 0;
                break :blk @intCast(version);
            };
            const c: u8 = if (count <= 0) 16 else blk: {
                if (count < 1 or count > 16) return 0;
                break :blk @intCast(count);
            };
            return E.sequenceBufferLen(v, c) catch 0;
        }

        pub fn encodeSequence(
            data: ?[*]const u8,
            data_len: usize,
            opts: ?*const SequenceOptions,
            buf: ?[*]u8,
            buf_len: usize,
            out: ?[*]Matrix,
            out_capacity: usize,
            out_count: ?*usize,
            out_parity: ?*u8,
        ) callconv(.c) c_int {
            const bytes = constSlice(data, data_len) orelse return Status.null_pointer.code();
            const o = opts orelse return Status.null_pointer.code();

            const level = parseEcc(o.ecc) orelse return Status.invalid_ecc.code();
            const mask_val = parseMask(o.mask) catch return Status.invalid_mask.code();

            const min_v: u8 = if (o.min_version <= 0) zqr.min_version else blk: {
                if (o.min_version < zqr.min_version or o.min_version > zqr.max_version)
                    return Status.invalid_version.code();
                break :blk @intCast(o.min_version);
            };

            const max_v: u8 = if (o.max_version <= 0) max_version else blk: {
                if (o.max_version < zqr.min_version or o.max_version > zqr.max_version)
                    return Status.invalid_version.code();
                if (o.max_version > max_version)
                    return Status.version_exceeds_tier.code();
                break :blk @intCast(o.max_version);
            };

            const fnc1_opt: ?zqr.Fnc1 = switch (o.fnc1) {
                1 => .{ .mode = .first },
                2 => .{ .mode = .second, .app_indicator = o.fnc1_app_indicator },
                else => null,
            };
            const eci_opt: ?u32 = if (o.has_eci != 0) o.eci else null;

            const sym_count_opt: ?u8 = if (o.symbol_count <= 0) null else blk: {
                if (o.symbol_count < 1 or o.symbol_count > 16) return Status.invalid_version.code();
                break :blk @intCast(o.symbol_count);
            };

            // Two-phase dry-run: if buf == null or out == null, compute sequence size only
            const is_dry_run = (buf == null or out == null);
            const target_storage: ?[]u8 = if (is_dry_run) null else buf.?[0..buf_len];

            const seq_res = E.encodeSequence(target_storage, bytes, .{
                .ecc = level,
                .min_version = min_v,
                .max_version = max_v,
                .mask = mask_val,
                .kanji = o.kanji != 0,
                .optimize = o.optimize != 0,
                .fnc1 = fnc1_opt,
                .eci = eci_opt,
                .symbol_count = sym_count_opt,
            }) catch |err| return Status.fromError(err).code();

            if (out_count) |oc| oc.* = seq_res.count;
            if (out_parity) |op| op.* = seq_res.parity;

            if (is_dry_run) return Status.ok.code();

            if (out_capacity < seq_res.count) {
                return Status.buffer_too_small.code();
            }

            const out_slice = out.?[0..out_capacity];
            for (0..seq_res.count) |i| {
                writeOut(&out_slice[i], seq_res.matrices[i]);
            }

            return Status.ok.code();
        }

        /// Renders matrix as an SVG document string.
        /// If `buf` is null, returns ZQR_OK and sets `*out_len` to the required buffer length (dry-run).
        /// If `buf` is non-null but `buf_len` is too small, returns ZQR_ERR_BUFFER_TOO_SMALL.
        pub fn renderSvg(
            matrix: ?*const Matrix,
            opts: ?*const RenderOptions,
            buf: ?[*]u8,
            buf_len: usize,
            out_len: ?*usize,
        ) callconv(.c) c_int {
            if (matrix == null or out_len == null) return Status.null_pointer.code();
            const m = matrix.?;
            if (m.modules == null or m.size == 0) return Status.null_pointer.code();

            const ropts: zqr.render.RenderOptions = if (opts) |o| .{
                .quiet_zone = o.quiet_zone,
                .scale = o.scale,
                .foreground = o.foreground,
                .background = o.background,
            } else .{};

            const qr_m = zqr.QrMatrix{
                .version = m.version,
                .size = m.size,
                .ecc = @fromBackingInt(@intCast(m.ecc)),
                .mask = @truncate(m.mask),
                .mode = @fromBackingInt(@intCast(m.mode)),
                .modules = m.modules.?[0 .. @as(usize, m.size) * m.size],
            };

            const needed = zqr.render.calcSvgLen(qr_m, ropts);
            if (buf == null) {
                out_len.?.* = needed;
                return Status.ok.code();
            }

            if (buf_len < needed) {
                return Status.buffer_too_small.code();
            }

            const written = zqr.render.renderSvgBuffer(qr_m, ropts, buf.?[0..buf_len]) catch {
                return Status.buffer_too_small.code();
            };

            out_len.?.* = written;
            return Status.ok.code();
        }

        /// Renders matrix as a PNG image file.
        /// If `buf` is null, returns ZQR_OK and sets `*out_len` to the upper-bound buffer length.
        /// If `buf` is non-null but `buf_len` is too small, returns ZQR_ERR_BUFFER_TOO_SMALL.
        pub fn renderPng(
            matrix: ?*const Matrix,
            opts: ?*const RenderOptions,
            buf: ?[*]u8,
            buf_len: usize,
            out_len: ?*usize,
        ) callconv(.c) c_int {
            const build_options = @import("build_options");
            if (!build_options.enable_png) {
                return Status.unsupported.code();
            }

            if (matrix == null or out_len == null) return Status.null_pointer.code();
            const m = matrix.?;
            if (m.modules == null or m.size == 0) return Status.null_pointer.code();

            const ropts: zqr.render.RenderOptions = if (opts) |o| .{
                .quiet_zone = o.quiet_zone,
                .scale = o.scale,
                .foreground = o.foreground,
                .background = o.background,
            } else .{};

            const qr_m = zqr.QrMatrix{
                .version = m.version,
                .size = m.size,
                .ecc = @fromBackingInt(@intCast(m.ecc)),
                .mask = @truncate(m.mask),
                .mode = @fromBackingInt(@intCast(m.mode)),
                .modules = m.modules.?[0 .. @as(usize, m.size) * m.size],
            };

            const max_bound = zqr.render.calcPngMaxBound(qr_m.size, ropts);
            if (buf == null) {
                out_len.?.* = max_bound;
                return Status.ok.code();
            }

            const written = zqr.render.renderPngBuffer(std.heap.c_allocator, qr_m, ropts, buf.?[0..buf_len]) catch |err| {
                return switch (err) {
                    error.BufferTooSmall => Status.buffer_too_small.code(),
                    error.NullPointer => Status.null_pointer.code(),
                    error.Unsupported => Status.unsupported.code(),
                    else => Status.data_too_long.code(),
                };
            };

            out_len.?.* = written;
            return Status.ok.code();
        }

        /// Required buffer length for `version`; 0 means "largest version of
        /// this tier". Returns 0 if `version` is invalid or above the tier.
        pub fn bufferLen(version: c_int) callconv(.c) usize {
            if (version == 0) return E.max_buffer_len;
            if (version < 1 or version > 40) return 0;
            return E.bufferLen(@intCast(version)) catch 0;
        }

        pub fn maxVersion() callconv(.c) c_int {
            return max_version;
        }

        /// Static, NUL-terminated description of a status code.
        pub fn strerror(code: c_int) callconv(.c) [*:0]const u8 {
            inline for (@typeInfo(Status).@"enum".field_values, @typeInfo(Status).@"enum".field_names) |val, name| {
                if (code == val) return @field(Status, name).message().ptr;
            }
            return "unknown status code";
        }

        pub fn decode(
            matrix_ptr: ?[*]const u8,
            size: u8,
            out_ptr: ?[*]u8,
            out_len: usize,
            result_ptr: ?*DecodeResultC,
        ) callconv(.c) c_int {
            if (matrix_ptr == null or out_ptr == null or result_ptr == null) {
                return DecodeStatus.null_pointer.code();
            }
            const total_mods = @as(usize, size) * size;
            const matrix_slice = matrix_ptr.?[0..total_mods];
            const out_slice = out_ptr.?[0..out_len];

            const Dec = zqr.Decoder(max_version);
            const res = Dec.decode(matrix_slice, size, out_slice) catch |err| {
                return DecodeStatus.fromError(err).code();
            };

            result_ptr.?.* = .{
                .bytes_written = @intCast(res.data.len),
                .version = res.metadata.version,
                .ecc = @backingInt(res.metadata.ecc),
                .mask = res.metadata.mask,
                .modes_used = res.metadata.modes_used,
                .errors_corrected_format = res.metadata.errors_corrected_format,
                .errors_corrected_version = res.metadata.errors_corrected_version,
                .errors_corrected_data = res.metadata.errors_corrected_data,
                .has_sa = if (res.metadata.sa != null) 1 else 0,
                .sa_position = if (res.metadata.sa) |sa| sa.position else 0,
                .sa_total = if (res.metadata.sa) |sa| sa.total else 0,
                .sa_parity = if (res.metadata.sa) |sa| sa.parity else 0,
                .has_eci = if (res.metadata.eci != null) 1 else 0,
                ._pad1 = [_]u8{ 0, 0, 0 },
                .eci = res.metadata.eci orelse 0,
                .has_fnc1 = if (res.metadata.fnc1_mode != null) 1 else 0,
                .fnc1_mode = if (res.metadata.fnc1_mode) |m| @backingInt(m) else 0,
                .fnc1_app_indicator = res.metadata.fnc1_app_indicator orelse 0,
                ._pad2 = [_]u8{0},
            };

            return DecodeStatus.ok.code();
        }

        pub fn decodeBufferLen(version: c_int, ecc: c_int) callconv(.c) usize {
            if (version < 1 or version > max_version) return 0;
            if (ecc < 0 or ecc > 3) return 0;
            const v: u8 = @intCast(version);
            const e: zqr.Ecc = @fromBackingInt(@as(u2, @intCast(ecc)));
            return zqr.decoder.decodeBufferLen(v, e);
        }

        pub fn decodeStrerror(code: c_int) callconv(.c) [*:0]const u8 {
            inline for (@typeInfo(DecodeStatus).@"enum".field_values, @typeInfo(DecodeStatus).@"enum".field_names) |val, name| {
                if (code == val) return @field(DecodeStatus, name).message().ptr;
            }
            return "unknown decoder status code";
        }

        comptime {
            @export(&encode, .{ .name = prefix ++ "_encode" });
            @export(&encodeWithVersion, .{ .name = prefix ++ "_encode_with_version" });
            @export(&encodeAdvanced, .{ .name = prefix ++ "_encode_advanced" });
            @export(&encodeSequence, .{ .name = prefix ++ "_encode_sequence" });
            @export(&renderSvg, .{ .name = prefix ++ "_render_svg" });
            @export(&renderPng, .{ .name = prefix ++ "_render_png" });
            @export(&decode, .{ .name = prefix ++ "_decode" });
            @export(&decodeBufferLen, .{ .name = prefix ++ "_decode_buffer_len" });
            @export(&decodeStrerror, .{ .name = prefix ++ "_decode_strerror" });
            @export(&bufferLen, .{ .name = prefix ++ "_buffer_len" });
            @export(&sequenceBufferLen, .{ .name = prefix ++ "_sequence_buffer_len" });
            @export(&maxVersion, .{ .name = prefix ++ "_max_version" });
            @export(&strerror, .{ .name = prefix ++ "_strerror" });
        }
    };
}

const testing = std.testing;

// Test-only instantiation; its symbols use a prefix that no shipped
// library exports.
const TestApi = cWrapper(10, "zqr_test");

test "status codes are stable" {
    try testing.expectEqual(@as(c_int, 0), Status.ok.code());
    try testing.expectEqual(@as(c_int, -1), Status.data_too_long.code());
    try testing.expectEqual(@as(c_int, -2), Status.version_exceeds_tier.code());
    try testing.expectEqual(@as(c_int, -3), Status.invalid_version.code());
    try testing.expectEqual(@as(c_int, -4), Status.invalid_ecc.code());
    try testing.expectEqual(@as(c_int, -5), Status.invalid_mask.code());
    try testing.expectEqual(@as(c_int, -6), Status.buffer_too_small.code());
    try testing.expectEqual(@as(c_int, -7), Status.null_pointer.code());

    // Decoder status codes
    try testing.expectEqual(@as(c_int, 0), DecodeStatus.ok.code());
    try testing.expectEqual(@as(c_int, -20), DecodeStatus.invalid_size.code());
    try testing.expectEqual(@as(c_int, -21), DecodeStatus.version_exceeds_tier.code());
    try testing.expectEqual(@as(c_int, -22), DecodeStatus.format_uncorrectable.code());
    try testing.expectEqual(@as(c_int, -23), DecodeStatus.version_uncorrectable.code());
    try testing.expectEqual(@as(c_int, -24), DecodeStatus.rs_uncorrectable.code());
    try testing.expectEqual(@as(c_int, -25), DecodeStatus.invalid_mode.code());
    try testing.expectEqual(@as(c_int, -26), DecodeStatus.invalid_payload.code());
    try testing.expectEqual(@as(c_int, -27), DecodeStatus.unexpected_eof.code());
    try testing.expectEqual(@as(c_int, -28), DecodeStatus.buffer_too_small.code());
    try testing.expectEqual(@as(c_int, -29), DecodeStatus.null_pointer.code());
}

test "query helpers" {
    try testing.expectEqual(@as(c_int, 10), TestApi.maxVersion());
    try testing.expectEqual(@as(usize, 57 * 57), TestApi.bufferLen(0));
    try testing.expectEqual(@as(usize, 21 * 21), TestApi.bufferLen(1));
    try testing.expectEqual(@as(usize, 0), TestApi.bufferLen(11));
    try testing.expectEqual(@as(usize, 0), TestApi.bufferLen(-3));
    try testing.expectEqualStrings("ok", std.mem.span(TestApi.strerror(0)));
    try testing.expectEqualStrings("unknown status code", std.mem.span(TestApi.strerror(-1000)));

    // Decoder query helpers
    try testing.expectEqual(@as(usize, 19 * 3), TestApi.decodeBufferLen(1, 0));
    try testing.expectEqual(@as(usize, 0), TestApi.decodeBufferLen(11, 0));
    try testing.expectEqual(@as(usize, 0), TestApi.decodeBufferLen(1, 4));
    try testing.expectEqualStrings("ok", std.mem.span(TestApi.decodeStrerror(0)));
    try testing.expectEqualStrings("matrix version exceeds maximum supported by this library tier", std.mem.span(TestApi.decodeStrerror(-21)));
    try testing.expectEqualStrings("unknown decoder status code", std.mem.span(TestApi.decodeStrerror(-999)));
}

test "argument validation" {
    var buf: [57 * 57]u8 = undefined;
    var out: Matrix = undefined;
    const data = "HELLO";
    try testing.expectEqual(Status.null_pointer.code(), TestApi.encode(data, data.len, 0, &buf, buf.len, null));
    try testing.expectEqual(Status.null_pointer.code(), TestApi.encode(null, 3, 0, &buf, buf.len, &out));
    try testing.expectEqual(Status.invalid_ecc.code(), TestApi.encode(data, data.len, 4, &buf, buf.len, &out));
    try testing.expectEqual(Status.invalid_version.code(), TestApi.encodeWithVersion(data, data.len, 0, 0, -1, &buf, buf.len, &out));
    try testing.expectEqual(Status.version_exceeds_tier.code(), TestApi.encodeWithVersion(data, data.len, 11, 0, -1, &buf, buf.len, &out));
    try testing.expectEqual(Status.invalid_mask.code(), TestApi.encodeWithVersion(data, data.len, 1, 0, 8, &buf, buf.len, &out));
    try testing.expectEqual(Status.buffer_too_small.code(), TestApi.encodeWithVersion(data, data.len, 2, 0, -1, &buf, 21 * 21, &out));
    // Decode argument validation
    var out_dec: [256]u8 = undefined;
    var res_dec: DecodeResultC = undefined;
    const dummy_mod: [21 * 21]u8 = @splat(0);
    try testing.expectEqual(DecodeStatus.null_pointer.code(), TestApi.decode(null, 21, &out_dec, out_dec.len, &res_dec));
    try testing.expectEqual(DecodeStatus.null_pointer.code(), TestApi.decode(&dummy_mod, 21, null, out_dec.len, &res_dec));
    try testing.expectEqual(DecodeStatus.null_pointer.code(), TestApi.decode(&dummy_mod, 21, &out_dec, out_dec.len, null));
    try testing.expectEqual(DecodeStatus.invalid_size.code(), TestApi.decode(&dummy_mod, 22, &out_dec, out_dec.len, &res_dec));
}

test "C ABI integration: tier boundary and valid matrix output" {
    const ApiT1 = cWrapper(6, "test_t1");
    const ApiT3 = cWrapper(40, "test_t3");

    // 300 numeric digits requires version >= 7 (fails in T1, succeeds in T3)
    const digits_100 = "12345678901234567890123456789012345678901234567890" ++
        "12345678901234567890123456789012345678901234567890";
    const long_digits = digits_100 ++ digits_100 ++ digits_100; // 300 digits
    var buf_t1: [41 * 41]u8 = undefined;
    var out_t1: Matrix = undefined;
    var buf_t3: [177 * 177]u8 = undefined;
    var out_t3: Matrix = undefined;

    // T1 must return ZQR_ERR_VERSION_EXCEEDS_TIER (-2)
    const res_t1 = ApiT1.encode(long_digits, long_digits.len, 1, &buf_t1, buf_t1.len, &out_t1);
    try testing.expectEqual(Status.version_exceeds_tier.code(), res_t1);

    // T3 must return ZQR_OK (0) and produce a valid matrix struct
    const res_t3 = ApiT3.encode(long_digits, long_digits.len, 1, &buf_t3, buf_t3.len, &out_t3);
    try testing.expectEqual(Status.ok.code(), res_t3);
    try testing.expect(out_t3.version >= 7);
    try testing.expectEqual(out_t3.version * 4 + 17, out_t3.size);
    try testing.expectEqual(@as(u8, 1), out_t3.ecc); // Medium
    try testing.expect(out_t3.modules != null);

    // Verify modules contain only 0 or 1
    const total_mods = @as(usize, out_t3.size) * out_t3.size;
    const mods_slice = out_t3.modules.?[0..total_mods];
    for (mods_slice) |m| {
        try testing.expect(m == 0 or m == 1);
    }

    // Decode roundtrip via C ABI
    var decoded_buf: [1024]u8 = undefined;
    var dec_res: DecodeResultC = undefined;

    // T1 decode of version >= 7 matrix must reject with ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER (-21)
    const dec_t1_res = ApiT1.decode(out_t3.modules, out_t3.size, &decoded_buf, decoded_buf.len, &dec_res);
    try testing.expectEqual(DecodeStatus.version_exceeds_tier.code(), dec_t1_res);

    // T3 decode must succeed
    const dec_t3_res = ApiT3.decode(out_t3.modules, out_t3.size, &decoded_buf, decoded_buf.len, &dec_res);
    try testing.expectEqual(DecodeStatus.ok.code(), dec_t3_res);
    try testing.expectEqual(long_digits.len, dec_res.bytes_written);
    try testing.expectEqualStrings(long_digits, decoded_buf[0..dec_res.bytes_written]);
    try testing.expectEqual(out_t3.version, dec_res.version);
    try testing.expectEqual(out_t3.ecc, dec_res.ecc);
    try testing.expectEqual(out_t3.mask, dec_res.mask);
    try testing.expectEqual(@as(u8, 0x01), dec_res.modes_used); // Numeric
}
