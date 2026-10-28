//! Zero-dependency SVG renderer for QrMatrix.
//!
//! Generates clean, scalable SVG documents using an optimized single-path
//! representation with horizontal run combining.

const std = @import("std");
const types = @import("types.zig");
const QrMatrix = types.QrMatrix;

pub const RenderOptions = struct {
    quiet_zone: u8 = 4,
    scale: u8 = 8,
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

/// Buffer-based SVG renderer. Writes to `buf` and returns number of bytes written.
/// Returns error.BufferTooSmall if `buf` is insufficient.
pub fn renderSvgBuffer(matrix: QrMatrix, opts: RenderOptions, buf: []u8) !usize {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const dim: usize = (@as(usize, matrix.size) + 2 * qz) * scale;

    var fg_buf: [10]u8 = undefined;
    var bg_buf: [10]u8 = undefined;
    const fg_str = formatColor(opts.foreground, &fg_buf);
    const bg_str = formatColor(opts.background, &bg_buf);

    var offset: usize = 0;
    var tmp: [256]u8 = undefined;

    const header = std.fmt.bufPrint(&tmp, "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" stroke=\"none\">\n<rect width=\"100%\" height=\"100%\" fill=\"{s}\"/>\n<path fill=\"{s}\" d=\"", .{
        dim, dim, dim, dim, bg_str, fg_str,
    }) catch return error.BufferTooSmall;
    try writeAppend(buf, &offset, header);

    const size: usize = matrix.size;
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) {
            if (matrix.modules[y * size + x] == 1) {
                const start_x = x;
                while (x < size and matrix.modules[y * size + x] == 1) : (x += 1) {}
                const run_len = x - start_x;

                const px_x = (start_x + qz) * scale;
                const px_y = (y + qz) * scale;
                const px_w = run_len * scale;
                const px_h = scale;

                const cmd = std.fmt.bufPrint(&tmp, "M{d},{d}h{d}v{d}h-{d}z ", .{ px_x, px_y, px_w, px_h, px_w }) catch return error.BufferTooSmall;
                try writeAppend(buf, &offset, cmd);
            } else {
                x += 1;
            }
        }
    }

    try writeAppend(buf, &offset, "\"/>\n</svg>\n");
    return offset;
}

/// Computes the exact length in bytes of the SVG document without allocating.
pub fn calcSvgLen(matrix: QrMatrix, opts: RenderOptions) usize {
    const qz: usize = opts.quiet_zone;
    const scale: usize = if (opts.scale == 0) 1 else opts.scale;
    const dim: usize = (@as(usize, matrix.size) + 2 * qz) * scale;

    var fg_buf: [10]u8 = undefined;
    var bg_buf: [10]u8 = undefined;
    const fg_str = formatColor(opts.foreground, &fg_buf);
    const bg_str = formatColor(opts.background, &bg_buf);

    var len: usize = 0;
    var tmp: [256]u8 = undefined;

    const header = std.fmt.bufPrint(&tmp, "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" viewBox=\"0 0 {d} {d}\" width=\"{d}\" height=\"{d}\" stroke=\"none\">\n<rect width=\"100%\" height=\"100%\" fill=\"{s}\"/>\n<path fill=\"{s}\" d=\"", .{
        dim, dim, dim, dim, bg_str, fg_str,
    }) catch unreachable;
    len += header.len;

    const size: usize = matrix.size;
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) {
            if (matrix.modules[y * size + x] == 1) {
                const start_x = x;
                while (x < size and matrix.modules[y * size + x] == 1) : (x += 1) {}
                const run_len = x - start_x;

                const px_x = (start_x + qz) * scale;
                const px_y = (y + qz) * scale;
                const px_w = run_len * scale;
                const px_h = scale;

                const cmd = std.fmt.bufPrint(&tmp, "M{d},{d}h{d}v{d}h-{d}z ", .{ px_x, px_y, px_w, px_h, px_w }) catch unreachable;
                len += cmd.len;
            } else {
                x += 1;
            }
        }
    }

    len += "\"/>\n</svg>\n".len;
    return len;
}

/// Renders a QrMatrix into an allocated SVG document string.
/// Caller owns the returned slice.
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

test "renderSvg basic document structure and quiet zone" {
    // 1x1 dummy matrix: 1 dark module
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
    // Dark module at (4*10, 4*10) = (40, 40) with width 10, height 10
    try testing.expect(std.mem.indexOf(u8, svg, "M40,40h10v10h-10z") != null);
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>\n"));
}

test "renderSvgBuffer dry run and overflow check" {
    const mods = [_]u8{ 1, 0, 0, 1 };
    const m = QrMatrix{
        .version = 1,
        .size = 2,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = &mods,
    };
    const opts = RenderOptions{ .quiet_zone = 2, .scale = 4 };
    const needed = calcSvgLen(m, opts);
    try testing.expect(needed > 50);

    var small_buf: [20]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, renderSvgBuffer(m, opts, &small_buf));

    var exact_buf: [1024]u8 = undefined;
    const written = try renderSvgBuffer(m, opts, exact_buf[0..needed]);
    try testing.expectEqual(needed, written);
}

test "renderSvg Version 40 (177x177) scale and viewBox validation" {
    // Version 40 has size 177 modules.
    const v40_modules = try testing.allocator.alloc(u8, 177 * 177);
    defer testing.allocator.free(v40_modules);
    @memset(v40_modules, 0);
    // Set a few modules to 1
    v40_modules[0] = 1;
    v40_modules[177 * 177 - 1] = 1;

    const m = QrMatrix{
        .version = 40,
        .size = 177,
        .ecc = .low,
        .mask = 0,
        .mode = .byte,
        .modules = v40_modules,
    };

    const opts = RenderOptions{ .quiet_zone = 4, .scale = 8 };
    const needed = calcSvgLen(m, opts);

    const out_buf = try testing.allocator.alloc(u8, needed);
    defer testing.allocator.free(out_buf);

    const written = try renderSvgBuffer(m, opts, out_buf);
    try testing.expectEqual(needed, written);

    // dim = (177 + 2*4) * 8 = 185 * 8 = 1480
    try testing.expect(std.mem.indexOf(u8, out_buf, "viewBox=\"0 0 1480 1480\"") != null);
    try testing.expect(std.mem.endsWith(u8, out_buf, "</svg>\n"));
}
