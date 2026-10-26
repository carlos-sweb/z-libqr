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

comptime {
    // Layout is part of the ABI: 8 bytes of header, then the pointer.
    std.debug.assert(@offsetOf(Matrix, "modules") == 8);
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

    pub fn code(self: Status) c_int {
        return @backingInt(self);
    }

    pub fn fromError(err: zqr.Error) Status {
        return switch (err) {
            error.DataTooLong => .data_too_long,
            error.VersionExceedsTier => .version_exceeds_tier,
            error.InvalidVersion => .invalid_version,
            error.BufferTooSmall => .buffer_too_small,
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

        comptime {
            @export(&encode, .{ .name = prefix ++ "_encode" });
            @export(&encodeWithVersion, .{ .name = prefix ++ "_encode_with_version" });
            @export(&bufferLen, .{ .name = prefix ++ "_buffer_len" });
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
}

test "query helpers" {
    try testing.expectEqual(@as(c_int, 10), TestApi.maxVersion());
    try testing.expectEqual(@as(usize, 57 * 57), TestApi.bufferLen(0));
    try testing.expectEqual(@as(usize, 21 * 21), TestApi.bufferLen(1));
    try testing.expectEqual(@as(usize, 0), TestApi.bufferLen(11));
    try testing.expectEqual(@as(usize, 0), TestApi.bufferLen(-3));
    try testing.expectEqualStrings("ok", std.mem.span(TestApi.strerror(0)));
    try testing.expectEqualStrings("unknown status code", std.mem.span(TestApi.strerror(-1000)));
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
}
