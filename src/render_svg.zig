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
    if (size < 21) return false;
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
        // Geometric Bézier Blob mode (pure vector, zero filters, zero stroke):
        // 1. Detect connected components of dark modules (4-connectivity).
        // 2. Isolated modules (component size == 1) render as <circle>.
        // 3. Multi-module blobs render as <path fill="{fg}" fill-rule="evenodd" d="..."> with Bézier fillets on convex and concave corners.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const is_dark = try allocator.alloc(bool, size * size);
        for (0..size) |r| {
            for (0..size) |c| {
                const in_finder = isFinderModule(r, c, size);
                is_dark[r * size + c] = (matrix.modules[r * size + c] == 1 and !in_finder);
            }
        }

        const visited = try allocator.alloc(bool, size * size);
        @memset(visited, false);

        const Point = struct { x: i32, y: i32 };
        var components: std.ArrayList(std.ArrayList(Point)) = .empty;
        var queue: std.ArrayList(Point) = .empty;

        for (0..size) |r| {
            for (0..size) |c| {
                const idx = r * size + c;
                if (is_dark[idx] and !visited[idx]) {
                    visited[idx] = true;
                    var comp: std.ArrayList(Point) = .empty;
                    try comp.append(allocator, .{ .x = @intCast(c), .y = @intCast(r) });
                    queue.clearRetainingCapacity();
                    try queue.append(allocator, .{ .x = @intCast(c), .y = @intCast(r) });

                    while (queue.items.len > 0) {
                        const curr = queue.orderedRemove(0);
                        const dirs = [_]struct { dx: i32, dy: i32 }{
                            .{ .dx = 1, .dy = 0 },
                            .{ .dx = -1, .dy = 0 },
                            .{ .dx = 0, .dy = 1 },
                            .{ .dx = 0, .dy = -1 },
                        };
                        for (dirs) |d| {
                            const nx = curr.x + d.dx;
                            const ny = curr.y + d.dy;
                            if (nx >= 0 and nx < size and ny >= 0 and ny < size) {
                                const nidx = @as(usize, @intCast(ny)) * size + @as(usize, @intCast(nx));
                                if (is_dark[nidx] and !visited[nidx]) {
                                    visited[nidx] = true;
                                    try comp.append(allocator, .{ .x = nx, .y = ny });
                                    try queue.append(allocator, .{ .x = nx, .y = ny });
                                }
                            }
                        }
                    }
                    try components.append(allocator, comp);
                }
            }
        }

        const stride = size + 1;
        const total_edges = (stride * stride) * 4;
        const edge_exists = try allocator.alloc(bool, total_edges);
        @memset(edge_exists, false);
        const edge_visited = try allocator.alloc(bool, total_edges);
        @memset(edge_visited, false);
        const in_comp = try allocator.alloc(bool, size * size);
        @memset(in_comp, false);

        const r_fillet = f_scale * 0.40;
        const kappa: f64 = 0.55228475;
        const dir_dx = [_]i32{ 1, 0, -1, 0 };
        const dir_dy = [_]i32{ 0, 1, 0, -1 };

        for (components.items) |comp| {
            if (comp.items.len == 1) {
                // Isolated module: <circle>
                const p = comp.items[0];
                const cx = (@as(f64, @floatFromInt(p.x + @as(i32, @intCast(qz)))) + 0.5) * f_scale;
                const cy = (@as(f64, @floatFromInt(p.y + @as(i32, @intCast(qz)))) + 0.5) * f_scale;
                const r_circ = f_scale * 0.45;
                const cmd = std.fmt.bufPrint(&tmp, "<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"{s}\"/>\n", .{
                    cx, cy, r_circ, fg_str,
                }) catch return error.BufferTooSmall;
                if (buf) |b| try writeAppend(b, &offset, cmd) else offset += cmd.len;
            } else {
                for (comp.items) |p| {
                    in_comp[@as(usize, @intCast(p.y)) * size + @as(usize, @intCast(p.x))] = true;
                }

                const CompEdge = struct { x: i32, y: i32, d: usize };
                var comp_edges: std.ArrayList(CompEdge) = .empty;
                for (comp.items) |p| {
                    const cx = p.x;
                    const cy = p.y;
                    // Top: d=0
                    if (cy == 0 or !in_comp[@as(usize, @intCast(cy - 1)) * size + @as(usize, @intCast(cx))]) {
                        const eid = (@as(usize, @intCast(cy)) * stride + @as(usize, @intCast(cx))) * 4 + 0;
                        edge_exists[eid] = true;
                        edge_visited[eid] = false;
                        try comp_edges.append(allocator, .{ .x = cx, .y = cy, .d = 0 });
                    }
                    // Right: d=1
                    if (cx + 1 == size or !in_comp[@as(usize, @intCast(cy)) * size + @as(usize, @intCast(cx + 1))]) {
                        const eid = (@as(usize, @intCast(cy)) * stride + @as(usize, @intCast(cx + 1))) * 4 + 1;
                        edge_exists[eid] = true;
                        edge_visited[eid] = false;
                        try comp_edges.append(allocator, .{ .x = cx + 1, .y = cy, .d = 1 });
                    }
                    // Bottom: d=2
                    if (cy + 1 == size or !in_comp[@as(usize, @intCast(cy + 1)) * size + @as(usize, @intCast(cx))]) {
                        const eid = (@as(usize, @intCast(cy + 1)) * stride + @as(usize, @intCast(cx + 1))) * 4 + 2;
                        edge_exists[eid] = true;
                        edge_visited[eid] = false;
                        try comp_edges.append(allocator, .{ .x = cx + 1, .y = cy + 1, .d = 2 });
                    }
                    // Left: d=3
                    if (cx == 0 or !in_comp[@as(usize, @intCast(cy)) * size + @as(usize, @intCast(cx - 1))]) {
                        const eid = (@as(usize, @intCast(cy + 1)) * stride + @as(usize, @intCast(cx))) * 4 + 3;
                        edge_exists[eid] = true;
                        edge_visited[eid] = false;
                        try comp_edges.append(allocator, .{ .x = cx, .y = cy + 1, .d = 3 });
                    }
                }

                const path_open = std.fmt.bufPrint(&tmp, "<path fill=\"{s}\" fill-rule=\"evenodd\" d=\"", .{fg_str}) catch return error.BufferTooSmall;
                if (buf) |b| try writeAppend(b, &offset, path_open) else offset += path_open.len;

                for (comp_edges.items) |start_edge| {
                    const seid = (@as(usize, @intCast(start_edge.y)) * stride + @as(usize, @intCast(start_edge.x))) * 4 + start_edge.d;
                    if (edge_visited[seid]) continue;

                    var raw_loop: std.ArrayList(Point) = .empty;
                    try raw_loop.append(allocator, .{ .x = start_edge.x, .y = start_edge.y });

                    var curr_x = start_edge.x + dir_dx[start_edge.d];
                    var curr_y = start_edge.y + dir_dy[start_edge.d];
                    var prev_d = start_edge.d;
                    edge_visited[seid] = true;

                    while (curr_x != start_edge.x or curr_y != start_edge.y) {
                        try raw_loop.append(allocator, .{ .x = curr_x, .y = curr_y });

                        const d_right = (prev_d + 1) % 4;
                        const d_straight = prev_d;
                        const d_left = (prev_d + 3) % 4;

                        var chosen_d: ?usize = null;
                        const cand_dirs = [_]usize{ d_right, d_straight, d_left };
                        for (cand_dirs) |d| {
                            const eid = (@as(usize, @intCast(curr_y)) * stride + @as(usize, @intCast(curr_x))) * 4 + d;
                            if (edge_exists[eid] and !edge_visited[eid]) {
                                chosen_d = d;
                                edge_visited[eid] = true;
                                break;
                            }
                        }

                        if (chosen_d) |cd| {
                            prev_d = cd;
                            curr_x += dir_dx[cd];
                            curr_y += dir_dy[cd];
                        } else {
                            break;
                        }
                    }

                    const lk = raw_loop.items.len;
                    if (lk >= 4) {
                        var corners: std.ArrayList(Point) = .empty;
                        for (0..lk) |i| {
                            const p_prev = raw_loop.items[(i + lk - 1) % lk];
                            const p_curr = raw_loop.items[i];
                            const p_next = raw_loop.items[(i + 1) % lk];
                            const d1x = p_curr.x - p_prev.x;
                            const d1y = p_curr.y - p_prev.y;
                            const d2x = p_next.x - p_curr.x;
                            const d2y = p_next.y - p_curr.y;
                            if (d1x != d2x or d1y != d2y) {
                                try corners.append(allocator, p_curr);
                            }
                        }

                        const ck = corners.items.len;
                        if (ck >= 4) {
                            for (0..ck) |i| {
                                const prev_c = corners.items[(i + ck - 1) % ck];
                                const curr_c = corners.items[i];
                                const next_c = corners.items[(i + 1) % ck];

                                const vin_x = curr_c.x - prev_c.x;
                                const vin_y = curr_c.y - prev_c.y;
                                const lin: f64 = @floatFromInt(@max(@abs(vin_x), @abs(vin_y)));
                                const uin_x = @as(f64, @floatFromInt(vin_x)) / lin;
                                const uin_y = @as(f64, @floatFromInt(vin_y)) / lin;

                                const vout_x = next_c.x - curr_c.x;
                                const vout_y = next_c.y - curr_c.y;
                                const lout: f64 = @floatFromInt(@max(@abs(vout_x), @abs(vout_y)));
                                const uout_x = @as(f64, @floatFromInt(vout_x)) / lout;
                                const uout_y = @as(f64, @floatFromInt(vout_y)) / lout;

                                const vpx_x = (@as(f64, @floatFromInt(curr_c.x + @as(i32, @intCast(qz))))) * f_scale;
                                const vpx_y = (@as(f64, @floatFromInt(curr_c.y + @as(i32, @intCast(qz))))) * f_scale;

                                const ax = vpx_x - r_fillet * uin_x;
                                const ay = vpx_y - r_fillet * uin_y;
                                const bx = vpx_x + r_fillet * uout_x;
                                const by = vpx_y + r_fillet * uout_y;

                                const cp1x = ax + kappa * r_fillet * uin_x;
                                const cp1y = ay + kappa * r_fillet * uin_y;
                                const cp2x = bx - kappa * r_fillet * uout_x;
                                const cp2y = by - kappa * r_fillet * uout_y;

                                if (i == 0) {
                                    const cmd_m = std.fmt.bufPrint(&tmp, "M{d:.2},{d:.2} ", .{ ax, ay }) catch return error.BufferTooSmall;
                                    if (buf) |b| try writeAppend(b, &offset, cmd_m) else offset += cmd_m.len;
                                } else {
                                    const cmd_l = std.fmt.bufPrint(&tmp, "L{d:.2},{d:.2} ", .{ ax, ay }) catch return error.BufferTooSmall;
                                    if (buf) |b| try writeAppend(b, &offset, cmd_l) else offset += cmd_l.len;
                                }

                                const cmd_c = std.fmt.bufPrint(&tmp, "C{d:.2},{d:.2} {d:.2},{d:.2} {d:.2},{d:.2} ", .{
                                    cp1x, cp1y, cp2x, cp2y, bx, by,
                                }) catch return error.BufferTooSmall;
                                if (buf) |b| try writeAppend(b, &offset, cmd_c) else offset += cmd_c.len;
                            }
                            const cmd_z = "Z ";
                            if (buf) |b| try writeAppend(b, &offset, cmd_z) else offset += cmd_z.len;
                        }
                    }
                }

                const path_close = "\"/>\n";
                if (buf) |b| try writeAppend(b, &offset, path_close) else offset += path_close.len;

                for (comp.items) |p| {
                    in_comp[@as(usize, @intCast(p.y)) * size + @as(usize, @intCast(p.x))] = false;
                }
                for (comp_edges.items) |e| {
                    const eid = (@as(usize, @intCast(e.y)) * stride + @as(usize, @intCast(e.x))) * 4 + e.d;
                    edge_exists[eid] = false;
                }
            }
        }

        // If eyes are square, render finder patterns outside the blob path with crisp geometry
        if (!is_rounded_eye) {
            const finder_path_open = std.fmt.bufPrint(&tmp, "<path fill=\"{s}\" d=\"", .{fg_str}) catch return error.BufferTooSmall;
            if (buf) |b| try writeAppend(b, &offset, finder_path_open) else offset += finder_path_open.len;

            var y: usize = 0;
            while (y < size) : (y += 1) {
                var x: usize = 0;
                while (x < size) {
                    const in_finder = isFinderModule(y, x, size);
                    if (matrix.modules[y * size + x] == 1 and in_finder) {
                        const start_x = x;
                        while (x < size and matrix.modules[y * size + x] == 1 and isFinderModule(y, x, size)) : (x += 1) {}
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

            const finder_path_close = "\"/>\n";
            if (buf) |b| try writeAppend(b, &offset, finder_path_close) else offset += finder_path_close.len;
        }
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

test "renderSvg dot_shape = .rounded uses geometric Bézier contours" {
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

    // Pure vector geometry: NO filter, NO stroke!
    try testing.expect(std.mem.indexOf(u8, svg, "<filter") == null);
    try testing.expect(std.mem.indexOf(u8, svg, "stroke-width") == null);
    try testing.expect(std.mem.indexOf(u8, svg, "stroke-linejoin") == null);
    // Multi-module L-shape has Cubic Bézier curves 'C'
    try testing.expect(std.mem.indexOf(u8, svg, "fill-rule=\"evenodd\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "C") != null);
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
