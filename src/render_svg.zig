//! Zero-dependency SVG renderer for QrMatrix.
//!
//! Supports classic square modules as well as modern rounded dots / connected blobs
//! and rounded circular finder patterns ("smooth/blob QR" style).

const std = @import("std");
const types = @import("types.zig");
const QrMatrix = types.QrMatrix;

pub const Shape = enum(u8) {
    square = 0,
    rounded = 1,
};

pub const RenderOptions = struct {
    quiet_zone: u8 = 4,
    scale: u8 = 8,
    dot_shape: Shape = .square,
    eye_shape: Shape = .square,
    foreground: u32 = 0x000000FF, // RGBA black
    background: u32 = 0xFFFFFFFF, // RGBA white
};

pub fn formatColor(color: u32, buf: *[10]u8) []const u8 {
    const r: u8 = @truncate(color >> 24);
    const g: u8 = @truncate(color >> 16);
    const b: u8 = @truncate(color >> 8);
    const a: u8 = @truncate(color);
    if (a == 255) {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch unreachable;
    } else {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a }) catch unreachable;
    }
}

fn writeAppend(dest: []u8, offset: *usize, src: []const u8) !void {
    if (offset.* + src.len > dest.len) return error.BufferTooSmall;
    @memcpy(dest[offset.* .. offset.* + src.len], src);
    offset.* += src.len;
}

/// Checks if module at (r, c) is part of any of the 3 corner finder patterns (7x7).
pub fn isFinderModule(r: usize, c: usize, size: usize) bool {
    // Top-Left (0..6, 0..6)
    if (r < 7 and c < 7) return true;
    // Top-Right (0..6, size-7..size-1)
    if (r < 7 and c + 7 >= size) return true;
    // Bottom-Left (size-7..size-1, 0..6)
    if (r + 7 >= size and c < 7) return true;
    return false;
}

/// Renders a single corner finder pattern using concentric circles with ratio 1:1:3:1:1:
/// - Outer black circle: r = 3.5 * scale
/// - Intermediate white circle: r = 2.5 * scale
/// - Center black circle: r = 1.5 * scale
fn renderRoundedFinder(
    buf: ?[]u8,
    offset: *usize,
    center_x: f64,
    center_y: f64,
    scale: f64,
    fg_str: []const u8,
    bg_str: []const u8,
) !void {
    var tmp: [256]u8 = undefined;

    // Outer circle
    const r_outer = 3.5 * scale;
    const s_outer = std.fmt.bufPrint(&tmp, "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"{s}\"/>\n", .{
        center_x, center_y, r_outer, fg_str,
    }) catch return error.BufferTooSmall;
    if (buf) |b| try writeAppend(b, offset, s_outer) else offset.* += s_outer.len;

    // White gap
    const r_white = 2.5 * scale;
    const s_white = std.fmt.bufPrint(&tmp, "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"{s}\"/>\n", .{
        center_x, center_y, r_white, bg_str,
    }) catch return error.BufferTooSmall;
    if (buf) |b| try writeAppend(b, offset, s_white) else offset.* += s_white.len;

    // Center dot
    const r_inner = 1.5 * scale;
    const s_inner = std.fmt.bufPrint(&tmp, "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"{s}\"/>\n", .{
        center_x, center_y, r_inner, fg_str,
    }) catch return error.BufferTooSmall;
    if (buf) |b| try writeAppend(b, offset, s_inner) else offset.* += s_inner.len;
}

/// Core internal generator that calculates length (if buf is null) or writes output.
fn renderSvgInternal(matrix: QrMatrix, opts: RenderOptions, buf: ?[]u8) !usize {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const size: usize = matrix.size;
    const dim: usize = (size + 2 * qz) * scale;
    const f_scale: f64 = @floatFromInt(scale);

    var fg_buf: [10]u8 = undefined;
    var bg_buf: [10]u8 = undefined;
    const fg_str = formatColor(opts.foreground, &fg_buf);
    const bg_str = formatColor(opts.background, &bg_buf);

    var offset: usize = 0;
    var tmp: [512]u8 = undefined;

    const header = std.fmt.bufPrint(&tmp, "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" stroke=\"none\">\n<rect width=\"100%\" height=\"100%\" fill=\"{s}\"/>\n", .{
        dim, dim, dim, dim, bg_str,
    }) catch return error.BufferTooSmall;
    if (buf) |b| try writeAppend(b, &offset, header) else offset += header.len;

    const is_blob_mode = (opts.dot_shape == .rounded);
    const is_rounded_eye = (opts.eye_shape == .rounded);

    // 1. Render data modules (and classic finders if eye_shape == .square)
    if (!is_blob_mode) {
        // Classic square runs
        const path_open = std.fmt.bufPrint(&tmp, "<path fill=\"{s}\" d=\"", .{fg_str}) catch return error.BufferTooSmall;
        if (buf) |b| try writeAppend(b, &offset, path_open) else offset += path_open.len;

        var y: usize = 0;
        while (y < size) : (y += 1) {
            var x: usize = 0;
            while (x < size) {
                const in_finder = is_rounded_eye and isFinderModule(y, x, size);
                if (matrix.modules[y * size + x] == 1 and !in_finder) {
                    const start_x = x;
                    while (x < size and matrix.modules[y * size + x] == 1 and !(is_rounded_eye and isFinderModule(y, x, size))) : (x += 1) {}
                    const run_len = x - start_x;

                    const px_x = (start_x + qz) * scale;
                    const px_y = (y + qz) * scale;
                    const px_w = run_len * scale;
                    const px_h = scale;

                    const cmd = std.fmt.bufPrint(&tmp, "M{d},{d}h{d}v{d}h-{d}z ", .{ px_x, px_y, px_w, px_h, px_w }) catch return error.BufferTooSmall;
                    if (buf) |b| try writeAppend(b, &offset, cmd) else offset += cmd.len;
                } else {
                    x += 1;
                }
            }
        }

        const path_close = "\"/>\n";
        if (buf) |b| try writeAppend(b, &offset, path_close) else offset += path_close.len;
    } else {
        // Blob / smooth QR mode:
        // Use an inner core with stroke="fg" stroke-width="2*radius" stroke-linejoin="round" stroke-linecap="round"
        // Radius r = scale * 0.40 leaves a smooth rounded connection for adjacent modules and circular dots for single modules.
        const r_inset = f_scale * 0.40;
        const stroke_w = r_inset * 2.0;

        const blob_open = std.fmt.bufPrint(&tmp, "<path fill=\"{s}\" stroke=\"{s}\" stroke-width=\"{d:.2}\" stroke-linejoin=\"round\" stroke-linecap=\"round\" d=\"", .{
            fg_str, fg_str, stroke_w,
        }) catch return error.BufferTooSmall;
        if (buf) |b| try writeAppend(b, &offset, blob_open) else offset += blob_open.len;

        var y: usize = 0;
        while (y < size) : (y += 1) {
            var x: usize = 0;
            while (x < size) {
                const in_finder = is_rounded_eye and isFinderModule(y, x, size);
                if (matrix.modules[y * size + x] == 1 and !in_finder) {
                    const start_x = x;
                    while (x < size and matrix.modules[y * size + x] == 1 and !(is_rounded_eye and isFinderModule(y, x, size))) : (x += 1) {}
                    const run_len = x - start_x;

                    const px_x = @as(f64, @floatFromInt((start_x + qz) * scale)) + r_inset;
                    const px_y = @as(f64, @floatFromInt((y + qz) * scale)) + r_inset;
                    const px_w = @as(f64, @floatFromInt(run_len * scale)) - 2.0 * r_inset;
                    const px_h = f_scale - 2.0 * r_inset;

                    // If run_len == 1, draw a zero-length horizontal segment so round linecap creates a perfect circle!
                    if (run_len == 1) {
                        const cx = px_x + px_w * 0.5;
                        const cy = px_y + px_h * 0.5;
                        const cmd = std.fmt.bufPrint(&tmp, "M{d:.2},{d:.2}h0 ", .{ cx, cy }) catch return error.BufferTooSmall;
                        if (buf) |b| try writeAppend(b, &offset, cmd) else offset += cmd.len;
                    } else {
                        // Multi-module run: horizontal rectangle inset by r_inset, puffed out by round stroke
                        const cmd = std.fmt.bufPrint(&tmp, "M{d:.2},{d:.2}h{d:.2}v{d:.2}h-{d:.2}z ", .{ px_x, px_y, px_w, px_h, px_w }) catch return error.BufferTooSmall;
                        if (buf) |b| try writeAppend(b, &offset, cmd) else offset += cmd.len;
                    }
                } else {
                    x += 1;
                }
            }
        }

        const blob_close = "\"/>\n";
        if (buf) |b| try writeAppend(b, &offset, blob_close) else offset += blob_close.len;
    }

    // 2. Render rounded finders if requested
    if (is_rounded_eye) {
        // Finders centers are at (3.5 modules, 3.5 modules) from their respective 7x7 corner:
        // Top-Left: (qz + 3.5, qz + 3.5)
        const tl_cx = (@as(f64, @floatFromInt(qz)) + 3.5) * f_scale;
        const tl_cy = (@as(f64, @floatFromInt(qz)) + 3.5) * f_scale;
        try renderRoundedFinder(buf, &offset, tl_cx, tl_cy, f_scale, fg_str, bg_str);

        // Top-Right: (qz + size - 3.5, qz + 3.5)
        const tr_cx = (@as(f64, @floatFromInt(qz + size)) - 3.5) * f_scale;
        const tr_cy = (@as(f64, @floatFromInt(qz)) + 3.5) * f_scale;
        try renderRoundedFinder(buf, &offset, tr_cx, tr_cy, f_scale, fg_str, bg_str);

        // Bottom-Left: (qz + 3.5, qz + size - 3.5)
        const bl_cx = (@as(f64, @floatFromInt(qz)) + 3.5) * f_scale;
        const bl_cy = (@as(f64, @floatFromInt(qz + size)) - 3.5) * f_scale;
        try renderRoundedFinder(buf, &offset, bl_cx, bl_cy, f_scale, fg_str, bg_str);
    }

    const footer = "</svg>\n";
    if (buf) |b| try writeAppend(b, &offset, footer) else offset += footer.len;

    return offset;
}

/// Buffer-based SVG renderer. Writes to `buf` and returns number of bytes written.
/// Returns error.BufferTooSmall if `buf` is insufficient.
pub fn renderSvgBuffer(matrix: QrMatrix, opts: RenderOptions, buf: []u8) !usize {
    return renderSvgInternal(matrix, opts, buf);
}

/// Computes the exact length in bytes of the SVG document without allocating.
pub fn calcSvgLen(matrix: QrMatrix, opts: RenderOptions) usize {
    return renderSvgInternal(matrix, opts, null) catch unreachable;
}

/// Renders a QrMatrix into an allocated SVG string. Caller owns the returned slice.
pub fn renderSvg(allocator: std.mem.Allocator, matrix: QrMatrix, opts: RenderOptions) ![]u8 {
    const needed = calcSvgLen(matrix, opts);
    const buf = try allocator.alloc(u8, needed);
    errdefer allocator.free(buf);

    const written = try renderSvgBuffer(matrix, opts, buf);
    std.debug.assert(written == needed);
    return buf;
}

// ---- Unit Tests ----
const testing = std.testing;

test "renderSvg default square matches golden pattern" {
    const mods = [_]u8{1};
    const m = QrMatrix{
        .version = 1,
        .size = 1,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    const svg = try renderSvg(testing.allocator, m, .{
        .quiet_zone = 4,
        .scale = 10,
        .foreground = 0x000000FF,
        .background = 0xFFFFFFFF,
    });
    defer testing.allocator.free(svg);

    // Total dim = (1 + 8) * 10 = 90
    try testing.expect(std.mem.startsWith(u8, svg, "<svg xmlns="));
    try testing.expect(std.mem.indexOf(u8, svg, "viewBox=\"0 0 90 90\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"#FFFFFF\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"#000000\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "M40,40h10v10h-10z") != null);
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>\n"));
}

test "renderSvg dot_shape = .rounded uses smooth blob stroke and rounded caps" {
    const mods = [_]u8{ 1, 1, 0, 1 };
    const m = QrMatrix{
        .version = 1,
        .size = 2,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    const svg = try renderSvg(testing.allocator, m, .{
        .scale = 10,
        .dot_shape = .rounded,
    });
    defer testing.allocator.free(svg);

    try testing.expect(std.mem.indexOf(u8, svg, "stroke-linejoin=\"round\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "stroke-linecap=\"round\"") != null);
}

test "renderSvg eye_shape = .rounded uses 3 concentric circles per finder" {
    var mods: [21 * 21]u8 = undefined;
    @memset(&mods, 0);
    // Draw top-left finder in matrix
    for (0..7) |r| {
        for (0..7) |c| {
            if (r == 0 or r == 6 or c == 0 or c == 6 or (r >= 2 and r <= 4 and c >= 2 and c <= 4)) {
                mods[r * 21 + c] = 1;
            }
        }
    }

    const m = QrMatrix{
        .version = 1,
        .size = 21,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    const svg = try renderSvg(testing.allocator, m, .{
        .scale = 8,
        .eye_shape = .rounded,
    });
    defer testing.allocator.free(svg);

    // Must contain <circle elements with r="28.00" (3.5*8), r="20.00" (2.5*8), r="12.00" (1.5*8)
    try testing.expect(std.mem.indexOf(u8, svg, "<circle ") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "r=\"28.00\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "r=\"20.00\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "r=\"12.00\"") != null);
}

test "renderSvg determinism check" {
    const mods = [_]u8{ 1, 0, 1, 1 };
    const m = QrMatrix{
        .version = 1,
        .size = 2,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };

    const opts = RenderOptions{
        .dot_shape = .rounded,
        .eye_shape = .rounded,
        .foreground = 0x112233FF,
        .background = 0xEFEFEFFF,
    };

    const svg1 = try renderSvg(testing.allocator, m, opts);
    defer testing.allocator.free(svg1);

    const svg2 = try renderSvg(testing.allocator, m, opts);
    defer testing.allocator.free(svg2);

    try testing.expectEqualStrings(svg1, svg2);
}
