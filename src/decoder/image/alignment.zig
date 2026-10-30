//! Alignment pattern detection for QR Code Model 2 (Versions 2..40).
//!
//! An alignment pattern consists of a 5x5 module structure with a 1:1:1 (Dark-Light-Dark)
//! ratio horizontally and vertically, surrounding a single central dark module.
//!
//! Citations:
//!   - ISO/IEC 18004:2015, Section 6.3.5 ("Alignment Patterns")
//!   - zxing-cpp: core/src/qrcode/detector/QRAlignmentPatternFinder.cpp
//!   - quirc: lib/identify.c, find_alignment_pattern()

const std = @import("std");
const tables = @import("../../tables.zig");
const Point = @import("finder.zig").Point;
const Transform = @import("transform.zig").Transform;

pub const AlignmentPattern = struct {
    center: Point,
    estimated_module_size: f64,
};

/// Verifies whether 3 run lengths satisfy the 1:1:1 ratio with tolerance.
pub fn checkRatio111(runs: [3]usize, expected_module_size: f64) bool {
    var total: usize = 0;
    for (runs) |r| {
        if (r == 0) return false;
        total += r;
    }
    const module_size = @as(f64, @floatFromInt(total)) / 3.0;
    const max_ratio_variance = module_size * 0.5;

    // Checks: 1:1:1 ratio within the candidate pattern
    if (@abs(@as(f64, @floatFromInt(runs[0])) - module_size) >= max_ratio_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[1])) - module_size) >= max_ratio_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[2])) - module_size) >= max_ratio_variance) return false;

    // Must also be compatible with expected module size (allowing for perspective scaling)
    const max_scale_variance = expected_module_size * 0.75;
    if (@abs(module_size - expected_module_size) >= max_scale_variance) return false;

    return true;
}

/// Finds the primary bottom-right alignment pattern for version >= 2.
/// If version == 1, returns null (Version 1 has no alignment patterns).
pub fn findBottomRightAlignment(
    bitmap: []const u8,
    width: usize,
    height: usize,
    version: u8,
    initial_transform: Transform,
    module_size: f64,
) ?Point {
    if (version < 2 or version > 40) return null;

    const positions_struct = tables.getAlignmentPatternPositions(version);
    const positions = positions_struct.slice();
    if (positions.len == 0) return null;

    // The primary alignment pattern in the bottom-right quadrant is at (pos[last], pos[last])
    const align_mod: f64 = @floatFromInt(positions[positions.len - 1]);

    // Project nominal module center to image coordinates
    const est_pt = initial_transform.map(align_mod + 0.5, align_mod + 0.5);

    const est_x: isize = @intFromFloat(est_pt.x);
    const est_y: isize = @intFromFloat(est_pt.y);

    // Search window grows with version due to accumulated perspective displacement
    // from the initial parallelogram estimate: radius in modules = 4.0 + version * 0.8
    const search_modules: f64 = 4.0 + @as(f64, @floatFromInt(version)) * 0.8;
    const search_radius: isize = @max(4, @as(isize, @intFromFloat(module_size * search_modules)));
    const min_x = @max(0, est_x - search_radius);
    const max_x = @min(@as(isize, @intCast(width - 1)), est_x + search_radius);
    const min_y = @max(0, est_y - search_radius);
    const max_y = @min(@as(isize, @intCast(height - 1)), est_y + search_radius);

    var best_pt: ?Point = null;
    var best_dist: f64 = std.math.inf(f64);

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const uy: usize = @intCast(y);
        var state_count = [_]usize{ 0, 0, 0 };
        var current_state: usize = 0;

        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const ux: usize = @intCast(x);
            const is_dark = bitmap[uy * width + ux] == 1;

            if (!is_dark) {
                // Light pixel
                if (current_state == 1) {
                    current_state = 2;
                }
                state_count[current_state] += 1;
            } else {
                // Dark pixel
                if (current_state == 0) {
                    if (state_count[0] > 0) current_state = 1;
                } else if (current_state == 2) {
                    // Transition Light -> Dark: candidate 1:1:1 found (Light - Dark - Light)
                    if (checkRatio111(state_count, module_size)) {
                        const cx = @as(f64, @floatFromInt(ux)) - @as(f64, @floatFromInt(state_count[2])) - @as(f64, @floatFromInt(state_count[1])) / 2.0;
                        const icx: usize = @intFromFloat(cx);

                        // Vertical check around icx
                        if (icx < width) {
                            if (crossCheckAlignmentVertical(bitmap, width, height, icx, uy, module_size)) |cy| {
                                const dx = cx - est_pt.x;
                                const dy = cy - est_pt.y;
                                const dist = dx * dx + dy * dy;
                                if (dist < best_dist) {
                                    best_dist = dist;
                                    best_pt = Point{ .x = cx, .y = cy };
                                }
                            }
                        }
                    }

                    state_count[0] = state_count[2];
                    state_count[1] = 1;
                    state_count[2] = 0;
                    current_state = 1;
                } else {
                    state_count[current_state] += 1;
                }
            }
        }
    }

    return best_pt;
}

fn crossCheckAlignmentVertical(
    bitmap: []const u8,
    width: usize,
    height: usize,
    x: usize,
    center_y: usize,
    expected_module_size: f64,
) ?f64 {
    if (bitmap[center_y * width + x] != 1) return null;

    var v_runs = [_]usize{ 0, 0, 0 };

    // Center dark run going UP
    var y: isize = @intCast(center_y);
    while (y >= 0 and bitmap[@as(usize, @intCast(y)) * width + x] == 1) : (y -= 1) {
        v_runs[1] += 1;
    }
    if (y < 0) return null;

    // Light run going UP
    while (y >= 0 and bitmap[@as(usize, @intCast(y)) * width + x] == 0) : (y -= 1) {
        v_runs[0] += 1;
    }

    // Center dark run going DOWN
    y = @intCast(center_y + 1);
    while (y < height and bitmap[@as(usize, @intCast(y)) * width + x] == 1) : (y += 1) {
        v_runs[1] += 1;
    }
    if (y >= height) return null;

    // Light run going DOWN
    while (y < height and bitmap[@as(usize, @intCast(y)) * width + x] == 0) : (y += 1) {
        v_runs[2] += 1;
    }

    if (!checkRatio111(v_runs, expected_module_size)) return null;

    const cy = @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(v_runs[2])) - @as(f64, @floatFromInt(v_runs[1])) / 2.0;
    return cy;
}

test "Alignment: checkRatio111 and findBottomRightAlignment for Version 2" {
    const testing = std.testing;

    // Check ratio
    try testing.expect(checkRatio111(.{ 4, 4, 4 }, 4.0));
    try testing.expect(checkRatio111(.{ 3, 4, 5 }, 4.0));
    try testing.expect(!checkRatio111(.{ 1, 4, 1 }, 4.0));

    // V2 synthetic test
    const mod_size: usize = 4;
    const w: usize = 120;
    const h: usize = 120;
    var bitmap: [w * h]u8 = @splat(0);

    // In V2, alignment pattern is centered at module 18 (spanning modules 16..20).
    // With scale 4, module 16 starts at pixel 64. Center of module 18 is at 18.5 * 4 = 74.
    // Outer dark 5x5, inner light 3x3, center dark 1x1.
    for (0..20) |dy| {
        for (0..20) |dx| {
            const mx = dx / mod_size;
            const my = dy / mod_size;
            const is_dark = (mx == 0 or mx == 4 or my == 0 or my == 4) or (mx == 2 and my == 2);
            bitmap[(64 + dy) * w + (64 + dx)] = if (is_dark) 1 else 0;
        }
    }

    // Mapping module coordinates [0..25] to pixels [0..100] (scale 4)
    const trans = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        25,
        0,
        25,
        25,
        0,
        25,
        0,
        0,
        100,
        0,
        100,
        100,
        0,
        100,
    ).?;
    const pt = findBottomRightAlignment(&bitmap, w, h, 2, trans, 4.0);

    // Should detect center near (64 + 10 = 74, 64 + 10 = 74)
    try testing.expect(pt != null);
    try testing.expectApproxEqAbs(@as(f64, 74.0), pt.?.x, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 74.0), pt.?.y, 2.0);
}
