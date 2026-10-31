//! PNG renderer for QrMatrix using libpng.
//!
//! Invokes the isolated C wrapper zqr_png_write to safely generate valid PNG
//! images without exposing setjmp / longjmp to the Zig runtime.
//! Supports classic square rendering and smooth blob dots + concentric circle finders with 2x2 supersampling AA.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const QrMatrix = types.QrMatrix;
const render_svg = @import("render_svg.zig");
pub const RenderOptions = render_svg.RenderOptions;
pub const Shape = render_svg.Shape;
const isFinderModule = render_svg.isFinderModule;

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

/// Evaluates if sub-pixel coordinate (sub_x, sub_y) in image space is dark.
fn isSubpixelDark(
    sub_x: f64,
    sub_y: f64,
    qz: usize,
    scale: usize,
    size: usize,
    modules: []const u8,
    opts: RenderOptions,
) bool {
    const f_scale: f64 = @floatFromInt(scale);
    const qz_px: f64 = @as(f64, @floatFromInt(qz)) * f_scale;
    const qr_dim_px: f64 = @as(f64, @floatFromInt(size)) * f_scale;

    // Check if subpixel is within QR code area
    if (sub_x < qz_px or sub_x >= qz_px + qr_dim_px or sub_y < qz_px or sub_y >= qz_px + qr_dim_px) {
        return false;
    }

    const mod_xf = (sub_x - qz_px) / f_scale;
    const mod_yf = (sub_y - qz_px) / f_scale;
    const mod_x: usize = @intFromFloat(mod_xf);
    const mod_y: usize = @intFromFloat(mod_yf);

    if (mod_x >= size or mod_y >= size) return false;

    // Check if inside one of the 3 corner finders
    const in_finder = isFinderModule(mod_y, mod_x, size);
    if (opts.eye_shape == .rounded and in_finder) {
        // Evaluate distance to the center of the relevant finder
        var fcx: f64 = 0;
        var fcy: f64 = 0;
        if (mod_y < 7 and mod_x < 7) {
            // Top-Left
            fcx = qz_px + 3.5 * f_scale;
            fcy = qz_px + 3.5 * f_scale;
        } else if (mod_y < 7 and mod_x + 7 >= size) {
            // Top-Right
            fcx = qz_px + (@as(f64, @floatFromInt(size)) - 3.5) * f_scale;
            fcy = qz_px + 3.5 * f_scale;
        } else {
            // Bottom-Left
            fcx = qz_px + 3.5 * f_scale;
            fcy = qz_px + (@as(f64, @floatFromInt(size)) - 3.5) * f_scale;
        }

        const dx = sub_x - fcx;
        const dy = sub_y - fcy;
        const dist = @sqrt(dx * dx + dy * dy);

        // 1:1:3:1:1 concentric circles
        // Center: dist <= 1.5 * f_scale -> dark
        // White gap: 1.5 * f_scale < dist <= 2.5 * f_scale -> light
        // Outer ring: 2.5 * f_scale < dist <= 3.5 * f_scale -> dark
        if (dist <= 1.5 * f_scale) return true;
        if (dist <= 2.5 * f_scale) return false;
        if (dist <= 3.5 * f_scale) return true;
        return false;
    }

    // If module itself is not dark, then in classic mode it's false.
    // In blob mode, dark modules expand outward with a rounded margin.
    if (opts.dot_shape != .rounded) {
        return modules[mod_y * size + mod_x] == 1;
    }

    // Blob mode:
    // Every module dark has center (mcx, mcy) and radius.
    // We check if distance to any adjacent dark module segment or center is within blob radius.
    // Specifically, for each dark module, its expanded stroke-rounded shape:
    const is_dark = modules[mod_y * size + mod_x] == 1;
    if (is_dark) {
        // Distance within module:
        // Center of this module:
        const mcx = qz_px + (@as(f64, @floatFromInt(mod_x)) + 0.5) * f_scale;
        const mcy = qz_px + (@as(f64, @floatFromInt(mod_y)) + 0.5) * f_scale;

        // Check if adjacent neighbors are dark (to allow orthogonal fusion)
        const left_dark = (mod_x > 0 and modules[mod_y * size + (mod_x - 1)] == 1 and !(opts.eye_shape == .rounded and isFinderModule(mod_y, mod_x - 1, size)));
        const right_dark = (mod_x + 1 < size and modules[mod_y * size + (mod_x + 1)] == 1 and !(opts.eye_shape == .rounded and isFinderModule(mod_y, mod_x + 1, size)));
        const up_dark = (mod_y > 0 and modules[(mod_y - 1) * size + mod_x] == 1 and !(opts.eye_shape == .rounded and isFinderModule(mod_y - 1, mod_x, size)));
        const down_dark = (mod_y + 1 < size and modules[(mod_y + 1) * size + mod_x] == 1 and !(opts.eye_shape == .rounded and isFinderModule(mod_y + 1, mod_x, size)));

        const rel_x = sub_x - mcx;
        const rel_y = sub_y - mcy;
        const half_s = 0.5 * f_scale;
        const r_corner = 0.40 * f_scale;
        const core_s = half_s - r_corner;

        // Corner tests:
        // Top-Left corner of this module
        if (rel_x < -core_s and rel_y < -core_s and !left_dark and !up_dark) {
            const cdx = rel_x + core_s;
            const cdy = rel_y + core_s;
            if (cdx * cdx + cdy * cdy > r_corner * r_corner) return false;
        }
        // Top-Right corner
        if (rel_x > core_s and rel_y < -core_s and !right_dark and !up_dark) {
            const cdx = rel_x - core_s;
            const cdy = rel_y + core_s;
            if (cdx * cdx + cdy * cdy > r_corner * r_corner) return false;
        }
        // Bottom-Left corner
        if (rel_x < -core_s and rel_y > core_s and !left_dark and !down_dark) {
            const cdx = rel_x + core_s;
            const cdy = rel_y - core_s;
            if (cdx * cdx + cdy * cdy > r_corner * r_corner) return false;
        }
        // Bottom-Right corner
        if (rel_x > core_s and rel_y > core_s and !right_dark and !down_dark) {
            const cdx = rel_x - core_s;
            const cdy = rel_y - core_s;
            if (cdx * cdx + cdy * cdy > r_corner * r_corner) return false;
        }

        return true;
    }

    return false;
}

/// Populates an RGBA pixel buffer of dimensions (dim x dim) from QrMatrix.
pub fn rasterizeRgba(matrix: QrMatrix, opts: RenderOptions, out_rgba: []u8) void {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const size: usize = matrix.size;
    const dim: usize = (size + 2 * qz) * scale;

    std.debug.assert(out_rgba.len >= dim * dim * 4);

    const fg_r: u32 = @as(u8, @truncate(opts.foreground >> 24));
    const fg_g: u32 = @as(u8, @truncate(opts.foreground >> 16));
    const fg_b: u32 = @as(u8, @truncate(opts.foreground >> 8));
    const fg_a: u32 = @as(u8, @truncate(opts.foreground));

    const bg_r: u32 = @as(u8, @truncate(opts.background >> 24));
    const bg_g: u32 = @as(u8, @truncate(opts.background >> 16));
    const bg_b: u32 = @as(u8, @truncate(opts.background >> 8));
    const bg_a: u32 = @as(u8, @truncate(opts.background));

    // Fast path: classic square modules and square eyes require no anti-aliasing
    if (opts.dot_shape == .square and opts.eye_shape == .square) {
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
                    out_rgba[px_offset + 0] = @intCast(fg_r);
                    out_rgba[px_offset + 1] = @intCast(fg_g);
                    out_rgba[px_offset + 2] = @intCast(fg_b);
                    out_rgba[px_offset + 3] = @intCast(fg_a);
                } else {
                    out_rgba[px_offset + 0] = @intCast(bg_r);
                    out_rgba[px_offset + 1] = @intCast(bg_g);
                    out_rgba[px_offset + 2] = @intCast(bg_b);
                    out_rgba[px_offset + 3] = @intCast(bg_a);
                }
            }
        }
        return;
    }

    // Rounded / blob path: 2x2 supersampling for smooth anti-aliased edges
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const px_f: f64 = @floatFromInt(x);
            const py_f: f64 = @floatFromInt(y);

            // 4 sub-samples per pixel
            var dark_count: u32 = 0;
            if (isSubpixelDark(px_f + 0.25, py_f + 0.25, qz, scale, size, matrix.modules, opts)) dark_count += 1;
            if (isSubpixelDark(px_f + 0.75, py_f + 0.25, qz, scale, size, matrix.modules, opts)) dark_count += 1;
            if (isSubpixelDark(px_f + 0.25, py_f + 0.75, qz, scale, size, matrix.modules, opts)) dark_count += 1;
            if (isSubpixelDark(px_f + 0.75, py_f + 0.75, qz, scale, size, matrix.modules, opts)) dark_count += 1;

            const px_offset = (y * dim + x) * 4;
            if (dark_count == 4) {
                out_rgba[px_offset + 0] = @intCast(fg_r);
                out_rgba[px_offset + 1] = @intCast(fg_g);
                out_rgba[px_offset + 2] = @intCast(fg_b);
                out_rgba[px_offset + 3] = @intCast(fg_a);
            } else if (dark_count == 0) {
                out_rgba[px_offset + 0] = @intCast(bg_r);
                out_rgba[px_offset + 1] = @intCast(bg_g);
                out_rgba[px_offset + 2] = @intCast(bg_b);
                out_rgba[px_offset + 3] = @intCast(bg_a);
            } else {
                // Alpha-blend between fg and bg
                const weight_fg = dark_count;
                const weight_bg = 4 - dark_count;
                out_rgba[px_offset + 0] = @intCast((fg_r * weight_fg + bg_r * weight_bg) / 4);
                out_rgba[px_offset + 1] = @intCast((fg_g * weight_fg + bg_g * weight_bg) / 4);
                out_rgba[px_offset + 2] = @intCast((fg_b * weight_fg + bg_b * weight_bg) / 4);
                out_rgba[px_offset + 3] = @intCast((fg_a * weight_fg + bg_a * weight_bg) / 4);
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

    const max_bound = calcPngMaxBound(matrix.size, opts);
    const png_buf = try allocator.alloc(u8, max_bound);
    errdefer allocator.free(png_buf);

    var written: usize = 0;
    const rc = zqr_png_write(
        rgba.ptr,
        @intCast(dim),
        @intCast(dim),
        png_buf.ptr,
        max_bound,
        &written,
    );

    if (rc != 0) {
        // errdefer frees png_buf; do not free explicitly (would double-free).
        return switch (rc) {
            -6 => error.BufferTooSmall,
            -7 => error.NullPointer,
            else => error.PngEncodeFailed,
        };
    }

    if (written < png_buf.len) {
        return allocator.realloc(png_buf, written) catch png_buf[0..written];
    }
    return png_buf;
}

/// Renders a QrMatrix into a caller-supplied buffer `out_buf`.
/// Returns the number of bytes written.
pub fn renderPngBuffer(
    allocator: std.mem.Allocator,
    matrix: QrMatrix,
    opts: RenderOptions,
    out_buf: []u8,
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
        out_buf.ptr,
        out_buf.len,
        &written,
    );

    if (rc != 0) {
        return switch (rc) {
            -6 => error.BufferTooSmall,
            -7 => error.NullPointer,
            else => error.PngEncodeFailed,
        };
    }

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

    const png_sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    try testing.expect(png.len >= 8 + 25);
    try testing.expectEqualSlices(u8, &png_sig, png[0..8]);
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    try testing.expectEqual(@as(u32, 20), w);
    try testing.expectEqual(@as(u32, 20), h);
}

test "renderPng dot_shape = .rounded and eye_shape = .rounded anti-aliasing sampling" {
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

    const scale: usize = 10;
    const qz: usize = 1;
    const dim = (2 + 2 * qz) * scale;
    const rgba = try testing.allocator.alloc(u8, dim * dim * 4);
    defer testing.allocator.free(rgba);

    rasterizeRgba(m, .{
        .quiet_zone = @intCast(qz),
        .scale = @intCast(scale),
        .dot_shape = .rounded,
        .foreground = 0x000000FF,
        .background = 0xFFFFFFFF,
    }, rgba);

    // Module 0,0 center is at (15, 15) -> must be solid black (0, 0, 0, 255)
    const center_idx = (15 * dim + 15) * 4;
    try testing.expectEqual(@as(u8, 0), rgba[center_idx + 0]);
    try testing.expectEqual(@as(u8, 255), rgba[center_idx + 3]);

    // Module 0,0 extreme outer corner (10, 10) must be white (255, 255, 255, 255) because of corner rounding
    const corner_idx = (10 * dim + 10) * 4;
    try testing.expectEqual(@as(u8, 255), rgba[corner_idx + 0]);
    try testing.expectEqual(@as(u8, 255), rgba[corner_idx + 1]);
}
