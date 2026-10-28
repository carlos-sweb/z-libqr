//! PNG renderer for QrMatrix using libpng.
//!
//! Invokes the isolated C wrapper zqr_png_write to safely generate valid PNG
//! images without exposing setjmp / longjmp to the Zig runtime.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const QrMatrix = types.QrMatrix;
const RenderOptions = @import("render_svg.zig").RenderOptions;

extern "c" fn zqr_png_write(
    rgba_pixels: [*]const u8,
    width: c_int,
    height: c_int,
    out_buf: [*]u8,
    out_len: usize,
    out_written: *usize,
) c_int;

/// Calculates an absolute upper-bound byte size for the compressed PNG file.
pub fn calcPngMaxBound(matrix_size: usize, opts: RenderOptions) usize {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const dim: usize = (matrix_size + 2 * qz) * scale;
    // In worst-case uncompressed raw RGBA Deflate: dim * (dim * 4 + 1) + IHDR + IDAT + IEND + overhead
    return dim * (dim * 4 + 1) + 4096;
}

pub const RenderError = error{
    BufferTooSmall,
    InvalidDimensions,
    NullPointer,
    PngEncodeFailed,
    Unsupported,
    OutOfMemory,
};

/// Populates an RGBA pixel buffer of dimensions (dim x dim) from QrMatrix.
pub fn rasterizeRgba(matrix: QrMatrix, opts: RenderOptions, out_rgba: []u8) void {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const size: usize = matrix.size;
    const dim: usize = (size + 2 * qz) * scale;

    std.debug.assert(out_rgba.len >= dim * dim * 4);

    const fg_r: u8 = @truncate(opts.foreground >> 24);
    const fg_g: u8 = @truncate(opts.foreground >> 16);
    const fg_b: u8 = @truncate(opts.foreground >> 8);
    const fg_a: u8 = @truncate(opts.foreground);

    const bg_r: u8 = @truncate(opts.background >> 24);
    const bg_g: u8 = @truncate(opts.background >> 16);
    const bg_b: u8 = @truncate(opts.background >> 8);
    const bg_a: u8 = @truncate(opts.background);

    var y: usize = 0;
    while (y < dim) : (y += 1) {
        const in_qr_y = (y >= qz * scale) and (y < (qz + size) * scale);
        const mod_y = if (in_qr_y) (y - qz * scale) / scale else 0;

        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const in_qr_x = (x >= qz * scale) and (x < (qz + size) * scale);
            const is_dark = if (in_qr_y and in_qr_x) blk: {
                const mod_x = (x - qz * scale) / scale;
                break :blk matrix.modules[mod_y * size + mod_x] == 1;
            } else false;

            const px_offset = (y * dim + x) * 4;
            if (is_dark) {
                out_rgba[px_offset + 0] = fg_r;
                out_rgba[px_offset + 1] = fg_g;
                out_rgba[px_offset + 2] = fg_b;
                out_rgba[px_offset + 3] = fg_a;
            } else {
                out_rgba[px_offset + 0] = bg_r;
                out_rgba[px_offset + 1] = bg_g;
                out_rgba[px_offset + 2] = bg_b;
                out_rgba[px_offset + 3] = bg_a;
            }
        }
    }
}

/// Renders a QrMatrix into an allocated PNG file buffer.
/// Caller owns the returned slice.
pub fn renderPng(allocator: std.mem.Allocator, matrix: QrMatrix, opts: RenderOptions) RenderError![]u8 {
    if (!build_options.enable_png) return error.Unsupported;

    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const dim: usize = (@as(usize, matrix.size) + 2 * qz) * scale;
    if (dim == 0 or dim > 32767) return error.InvalidDimensions;

    const raw_len = dim * dim * 4;
    const rgba = try allocator.alloc(u8, raw_len);
    defer allocator.free(rgba);

    rasterizeRgba(matrix, opts, rgba);

    const max_png = calcPngMaxBound(matrix.size, opts);
    var out_buf = try allocator.alloc(u8, max_png);
    errdefer allocator.free(out_buf);

    var written: usize = 0;
    const rc = zqr_png_write(
        rgba.ptr,
        @intCast(dim),
        @intCast(dim),
        out_buf.ptr,
        out_buf.len,
        &written,
    );

    if (rc == -6) return error.BufferTooSmall;
    if (rc != 0) return error.PngEncodeFailed;

    // Shrink slice to exact written size
    if (allocator.realloc(out_buf, written)) |shrunk| {
        return shrunk;
    } else |_| {
        return out_buf[0..written];
    }
}

/// Buffer-based PNG renderer for C ABI and fixed-buffer environments.
/// Returns number of bytes written to `buf`.
pub fn renderPngBuffer(
    allocator: std.mem.Allocator,
    matrix: QrMatrix,
    opts: RenderOptions,
    buf: []u8,
) RenderError!usize {
    if (!build_options.enable_png) return error.Unsupported;

    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const dim: usize = (@as(usize, matrix.size) + 2 * qz) * scale;
    if (dim == 0 or dim > 32767) return error.InvalidDimensions;

    const raw_len = dim * dim * 4;
    const rgba = try allocator.alloc(u8, raw_len);
    defer allocator.free(rgba);

    rasterizeRgba(matrix, opts, rgba);

    var written: usize = 0;
    const rc = zqr_png_write(
        rgba.ptr,
        @intCast(dim),
        @intCast(dim),
        buf.ptr,
        buf.len,
        &written,
    );

    if (rc == -6) return error.BufferTooSmall;
    if (rc == -7) return error.NullPointer;
    if (rc != 0) return error.PngEncodeFailed;

    return written;
}

// ---- Unit Tests ----
const testing = std.testing;

test "renderPng signature and IHDR chunk validation" {
    if (!build_options.enable_png) return;

    const mods = [_]u8{1};
    const m = QrMatrix{
        .version = 1,
        .size = 1,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    const png = try renderPng(testing.allocator, m, .{
        .quiet_zone = 2,
        .scale = 4,
        .foreground = 0x000000FF,
        .background = 0xFFFFFFFF,
    });
    defer testing.allocator.free(png);

    // 1. Check 8-byte PNG signature
    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    try testing.expect(png.len >= 8 + 25);
    try testing.expectEqualSlices(u8, &png_sig, png[0..8]);

    // 2. Check IHDR chunk
    // Offset 8: 4 bytes length (13 = 0x0000000D)
    // Offset 12: chunk type "IHDR"
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);

    // Offset 16: width (big endian 32-bit), height (big endian 32-bit)
    // dim = (1 + 2*2) * 4 = 5 * 4 = 20 px
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    try testing.expectEqual(@as(u32, 20), w);
    try testing.expectEqual(@as(u32, 20), h);

    // Offset 24: bit depth (8)
    try testing.expectEqual(@as(u8, 8), png[24]);
    // Offset 25: color type (6 = RGBA)
    try testing.expectEqual(@as(u8, 6), png[25]);
}

test "renderPngBuffer overflow error code" {
    if (!build_options.enable_png) return;
    const mods = [_]u8{ 1, 0, 0, 1 };
    const m = QrMatrix{
        .version = 1,
        .size = 2,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    var tiny_buf: [16]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, renderPngBuffer(testing.allocator, m, .{}, &tiny_buf));
}

test "renderPng Version 1 (21x21 modules, QZ 4, scale 8 = 232x232 px)" {
    if (!build_options.enable_png) return;

    const v1_modules = try testing.allocator.alloc(u8, 21 * 21);
    defer testing.allocator.free(v1_modules);
    @memset(v1_modules, 0);
    v1_modules[0] = 1;

    const m = QrMatrix{
        .version = 1,
        .size = 21,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = v1_modules,
    };

    const png = try renderPng(testing.allocator, m, .{
        .quiet_zone = 4,
        .scale = 8,
        .foreground = 0x000000FF,
        .background = 0xFFFFFFFF,
    });
    defer testing.allocator.free(png);

    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    try testing.expect(png.len >= 8 + 25);
    try testing.expectEqualSlices(u8, &png_sig, png[0..8]);

    // dim = (21 + 2*4) * 8 = 29 * 8 = 232 px
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    try testing.expectEqual(@as(u32, 232), w);
    try testing.expectEqual(@as(u32, 232), h);
}
