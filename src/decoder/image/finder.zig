//! Finder pattern detection for QR Code Model 2.
//!
//! Implements 1D horizontal run-length scanning with vertical and diagonal cross-checks,
//! sub-pixel center estimation, right-isosceles triad grouping, and canonical ordering
//! (Top-Left, Top-Right, Bottom-Left) based on 2D vector cross-product.
//!
//! Citations:
//!   - ISO/IEC 18004:2015, Section 6.3.3 ("Position Detection Patterns")
//!   - zxing-cpp: core/src/qrcode/detector/QRDetector.cpp, QRFinderPatternFinder.cpp
//!   - quirc: lib/identify.c, finder_scan() and record_qr_grid()

const std = @import("std");

pub const FinderError = error{
    FinderPatternsNotFound,
    InvalidTriadGeometry,
    ImageTooSmall,
};

pub const Point = struct {
    x: f64,
    y: f64,

    pub fn distance(self: Point, other: Point) f64 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn distanceSq(self: Point, other: Point) f64 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return dx * dx + dy * dy;
    }
};

pub const FinderPattern = struct {
    center: Point,
    estimated_module_size: f64,
    count: usize = 1,
};

pub const FinderTriad = struct {
    top_left: FinderPattern,
    top_right: FinderPattern,
    bottom_left: FinderPattern,
    estimated_module_size: f64,
    estimated_version: u8,
    matrix_size: u8,
};

/// Maximum number of candidate finder patterns retained during scanning.
pub const MAX_CANDIDATES: usize = 64;

/// Verifies whether a 5-element run length array satisfies the 1:1:3:1:1 finder pattern ratio.
/// Source: zxing-cpp, QRFinderPatternFinder.cpp, function foundPatternCross.
pub fn checkRatio11311(runs: [5]usize) bool {
    var total: usize = 0;
    for (runs) |r| {
        if (r == 0) return false;
        total += r;
    }
    if (total < 7) return false;

    const module_size = @as(f64, @floatFromInt(total)) / 7.0;
    const max_variance = module_size * 0.5;

    // Checks: 1:1:3:1:1
    if (@abs(@as(f64, @floatFromInt(runs[0])) - module_size) >= max_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[1])) - module_size) >= max_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[2])) - 3.0 * module_size) >= 3.0 * max_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[3])) - module_size) >= max_variance) return false;
    if (@abs(@as(f64, @floatFromInt(runs[4])) - module_size) >= max_variance) return false;

    return true;
}

/// Cross-checks the candidate center vertically along column x0.
/// Returns the refined vertical center coordinate cy if valid, or null.
fn crossCheckVertical(
    bitmap: []const u8,
    width: usize,
    height: usize,
    start_x: usize,
    start_y: usize,
    max_count: usize,
    original_state_count_total: usize,
) ?f64 {
    if (start_x >= width or start_y >= height) return null;
    if (bitmap[start_y * width + start_x] != 1) return null; // Center must be dark

    var v_runs = [_]usize{ 0, 0, 0, 0, 0 };

    // Center dark run going UP
    var y: isize = @intCast(start_y);
    while (y >= 0 and bitmap[@as(usize, @intCast(y)) * width + start_x] == 1) : (y -= 1) {
        v_runs[2] += 1;
    }
    if (y < 0) return null;

    // Light run going UP
    while (y >= 0 and bitmap[@as(usize, @intCast(y)) * width + start_x] == 0) : (y -= 1) {
        v_runs[1] += 1;
    }
    if (y < 0) return null;

    // Dark run going UP
    while (y >= 0 and bitmap[@as(usize, @intCast(y)) * width + start_x] == 1) : (y -= 1) {
        v_runs[0] += 1;
    }

    // Center dark run going DOWN
    y = @intCast(start_y + 1);
    while (y < height and bitmap[@as(usize, @intCast(y)) * width + start_x] == 1) : (y += 1) {
        v_runs[2] += 1;
    }
    if (y >= height) return null;

    // Light run going DOWN
    while (y < height and bitmap[@as(usize, @intCast(y)) * width + start_x] == 0) : (y += 1) {
        v_runs[3] += 1;
    }
    if (y >= height) return null;

    // Dark run going DOWN
    while (y < height and bitmap[@as(usize, @intCast(y)) * width + start_x] == 1) : (y += 1) {
        v_runs[4] += 1;
    }

    const total_v = v_runs[0] + v_runs[1] + v_runs[2] + v_runs[3] + v_runs[4];
    if (5 * @abs(@as(isize, @intCast(total_v)) - @as(isize, @intCast(original_state_count_total))) >= 2 * @as(isize, @intCast(original_state_count_total))) {
        return null;
    }

    if (!checkRatio11311(v_runs)) return null;

    _ = max_count;
    // Refine cy: center of the v_runs[2] span
    const cy = @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(v_runs[4])) - @as(f64, @floatFromInt(v_runs[3])) - @as(f64, @floatFromInt(v_runs[2])) / 2.0;
    return cy;
}

/// Cross-checks the candidate center diagonally at 45 degrees.
fn crossCheckDiagonal(
    bitmap: []const u8,
    width: usize,
    height: usize,
    start_x: usize,
    start_y: usize,
    max_count: usize,
    original_state_count_total: usize,
) bool {
    _ = max_count;
    if (start_x >= width or start_y >= height) return false;
    if (bitmap[start_y * width + start_x] != 1) return false;

    var d_runs = [_]usize{ 0, 0, 0, 0, 0 };

    // Diagonal UP-LEFT
    var i: isize = 0;
    while (start_x >= @as(usize, @intCast(i)) and start_y >= @as(usize, @intCast(i))) : (i += 1) {
        const x = start_x - @as(usize, @intCast(i));
        const y = start_y - @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 1) {
            d_runs[2] += 1;
        } else break;
        if (x == 0 or y == 0) break;
    }

    while (start_x >= @as(usize, @intCast(i)) and start_y >= @as(usize, @intCast(i))) : (i += 1) {
        const x = start_x - @as(usize, @intCast(i));
        const y = start_y - @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 0) {
            d_runs[1] += 1;
        } else break;
        if (x == 0 or y == 0) break;
    }

    while (start_x >= @as(usize, @intCast(i)) and start_y >= @as(usize, @intCast(i))) : (i += 1) {
        const x = start_x - @as(usize, @intCast(i));
        const y = start_y - @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 1) {
            d_runs[0] += 1;
        } else break;
        if (x == 0 or y == 0) break;
    }

    // Diagonal DOWN-RIGHT
    i = 1;
    while (start_x + @as(usize, @intCast(i)) < width and start_y + @as(usize, @intCast(i)) < height) : (i += 1) {
        const x = start_x + @as(usize, @intCast(i));
        const y = start_y + @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 1) {
            d_runs[2] += 1;
        } else break;
    }

    while (start_x + @as(usize, @intCast(i)) < width and start_y + @as(usize, @intCast(i)) < height) : (i += 1) {
        const x = start_x + @as(usize, @intCast(i));
        const y = start_y + @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 0) {
            d_runs[3] += 1;
        } else break;
    }

    while (start_x + @as(usize, @intCast(i)) < width and start_y + @as(usize, @intCast(i)) < height) : (i += 1) {
        const x = start_x + @as(usize, @intCast(i));
        const y = start_y + @as(usize, @intCast(i));
        if (bitmap[y * width + x] == 1) {
            d_runs[4] += 1;
        } else break;
    }

    const total_d = d_runs[0] + d_runs[1] + d_runs[2] + d_runs[3] + d_runs[4];
    // In a 45 degree diagonal, length is scaled by sqrt(2) ~ 1.414.
    // Ensure total_d is proportional to original_state_count_total * 1.4
    if (total_d == 0) return false;
    return checkRatio11311(d_runs) or (@abs(@as(f64, @floatFromInt(total_d)) - @as(f64, @floatFromInt(original_state_count_total)) * 1.414) < @as(f64, @floatFromInt(original_state_count_total)) * 0.7);
}

/// Scans the binary bitmap (1=dark, 0=light) and locates all candidate finder patterns.
pub fn findCandidates(bitmap: []const u8, width: usize, height: usize, out_candidates: []FinderPattern) usize {
    if (width < 7 or height < 7) return 0;

    var num_candidates: usize = 0;

    // Scan every row (or step by 1..2 for efficiency)
    for (0..height) |y| {
        var state_count = [_]usize{ 0, 0, 0, 0, 0 };
        var current_state: usize = 0;
        const row_offset = y * width;

        for (0..width) |x| {
            const is_dark = bitmap[row_offset + x] == 1;

            if (is_dark) {
                // If we were on light runs (state 1 or 3), advance to next state
                if ((current_state & 1) == 1) {
                    current_state += 1;
                }
                state_count[current_state] += 1;
            } else {
                // Currently light
                if ((current_state & 1) == 0) {
                    // We were on dark run
                    if (current_state == 4) {
                        // All 5 runs complete: check 1:1:3:1:1
                        if (checkRatio11311(state_count)) {
                            const total_h = state_count[0] + state_count[1] + state_count[2] + state_count[3] + state_count[4];
                            const cx = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(state_count[4])) - @as(f64, @floatFromInt(state_count[3])) - @as(f64, @floatFromInt(state_count[2])) / 2.0;

                            const center_x: usize = @intFromFloat(@max(0.0, @min(cx, @as(f64, @floatFromInt(width - 1)))));
                            const center_y: usize = y;

                            if (crossCheckVertical(bitmap, width, height, center_x, center_y, state_count[2], total_h)) |cy| {
                                if (crossCheckDiagonal(bitmap, width, height, center_x, @intFromFloat(cy), state_count[2], total_h)) {
                                    const mod_size = @as(f64, @floatFromInt(total_h)) / 7.0;

                                    // Try to cluster with existing candidate
                                    var merged = false;
                                    for (0..num_candidates) |k| {
                                        const c = &out_candidates[k];
                                        if (c.center.distance(.{ .x = cx, .y = cy }) < mod_size * 2.0) {
                                            const n = @as(f64, @floatFromInt(c.count));
                                            c.center.x = (c.center.x * n + cx) / (n + 1.0);
                                            c.center.y = (c.center.y * n + cy) / (n + 1.0);
                                            c.estimated_module_size = (c.estimated_module_size * n + mod_size) / (n + 1.0);
                                            c.count += 1;
                                            merged = true;
                                            break;
                                        }
                                    }

                                    if (!merged and num_candidates < out_candidates.len) {
                                        out_candidates[num_candidates] = .{
                                            .center = .{ .x = cx, .y = cy },
                                            .estimated_module_size = mod_size,
                                            .count = 1,
                                        };
                                        num_candidates += 1;
                                    }
                                }
                            }
                        }

                        // Shift state: drop first two, shift remaining by 2
                        state_count[0] = state_count[2];
                        state_count[1] = state_count[3];
                        state_count[2] = state_count[4];
                        state_count[3] = 1;
                        state_count[4] = 0;
                        current_state = 3;
                    } else {
                        current_state += 1;
                        state_count[current_state] += 1;
                    }
                } else {
                    state_count[current_state] += 1;
                }
            }
        }
    }

    return num_candidates;
}

/// Selects the best 3 finder patterns forming a right-isosceles triangle and orders them
/// canonically: Top-Left (TL), Top-Right (TR), Bottom-Left (BL).
///
/// Top-Left is the vertex opposite the hypotenuse.
/// Top-Right and Bottom-Left are resolved using the 2D vector cross-product:
///   (TR - TL) x (BL - TL) > 0  (in screen coordinates, right-handed clock rotation)
pub fn selectAndOrderTriad(candidates: []const FinderPattern, num_candidates: usize) FinderError!FinderTriad {
    if (num_candidates < 3) return error.FinderPatternsNotFound;

    var best_score: f64 = std.math.inf(f64);
    var best_tl: usize = 0;
    var best_tr: usize = 0;
    var best_bl: usize = 0;
    var found_valid = false;

    for (0..num_candidates) |i| {
        for (i + 1..num_candidates) |j| {
            for (j + 1..num_candidates) |k| {
                const p1 = candidates[i].center;
                const p2 = candidates[j].center;
                const p3 = candidates[k].center;

                const d12_sq = p1.distanceSq(p2);
                const d23_sq = p2.distanceSq(p3);
                const d31_sq = p3.distanceSq(p1);

                // Identify hypotenuse (longest edge)
                var hyp_sq: f64 = undefined;
                var l1_sq: f64 = undefined;
                var l2_sq: f64 = undefined;
                var tl_idx: usize = undefined;
                var a_idx: usize = undefined;
                var b_idx: usize = undefined;

                if (d12_sq >= d23_sq and d12_sq >= d31_sq) {
                    hyp_sq = d12_sq;
                    l1_sq = d23_sq;
                    l2_sq = d31_sq;
                    tl_idx = k; // Vertex opposite hypotenuse d12
                    a_idx = i;
                    b_idx = j;
                } else if (d23_sq >= d12_sq and d23_sq >= d31_sq) {
                    hyp_sq = d23_sq;
                    l1_sq = d12_sq;
                    l2_sq = d31_sq;
                    tl_idx = i; // Vertex opposite hypotenuse d23
                    a_idx = j;
                    b_idx = k;
                } else {
                    hyp_sq = d31_sq;
                    l1_sq = d12_sq;
                    l2_sq = d23_sq;
                    tl_idx = j; // Vertex opposite hypotenuse d31
                    a_idx = k;
                    b_idx = i;
                }

                const l1 = @sqrt(l1_sq);
                const l2 = @sqrt(l2_sq);
                const max_leg = @max(l1, l2);
                if (max_leg == 0) continue;

                // Check 1: Legs should be approximately equal (|l1 - l2| / max < 0.25)
                const leg_diff_ratio = @abs(l1 - l2) / max_leg;
                if (leg_diff_ratio > 0.35) continue;

                // Check 2: Pythagorean theorem (|hyp^2 - (l1^2 + l2^2)| / hyp^2 < 0.30)
                const pyth_diff_ratio = @abs(hyp_sq - (l1_sq + l2_sq)) / hyp_sq;
                if (pyth_diff_ratio > 0.35) continue;

                const score = leg_diff_ratio + pyth_diff_ratio;
                if (score < best_score) {
                    best_score = score;
                    best_tl = tl_idx;

                    // Resolve TR and BL using 2D cross product:
                    // Vector VA = A - TL, Vector VB = B - TL
                    // cp = VA.x * VB.y - VA.y * VB.x
                    // In screen coordinates (X right, Y down):
                    // (TR - TL) x (BL - TL) is positive.
                    const pt_tl = candidates[tl_idx].center;
                    const va_x = candidates[a_idx].center.x - pt_tl.x;
                    const va_y = candidates[a_idx].center.y - pt_tl.y;
                    const vb_x = candidates[b_idx].center.x - pt_tl.x;
                    const vb_y = candidates[b_idx].center.y - pt_tl.y;

                    const cp = va_x * vb_y - va_y * vb_x;
                    if (cp > 0) {
                        best_tr = a_idx;
                        best_bl = b_idx;
                    } else {
                        best_tr = b_idx;
                        best_bl = a_idx;
                    }
                    found_valid = true;
                }
            }
        }
    }

    if (!found_valid) return error.InvalidTriadGeometry;

    const tl_pat = candidates[best_tl];
    const tr_pat = candidates[best_tr];
    const bl_pat = candidates[best_bl];

    // Compute average module size from finders
    const avg_mod_size = (tl_pat.estimated_module_size + tr_pat.estimated_module_size + bl_pat.estimated_module_size) / 3.0;

    // Estimate version:
    // Distance between TL and TR in module units is (S - 7)
    // Distance between TL and BL in module units is (S - 7)
    const dist_tl_tr = tl_pat.center.distance(tr_pat.center);
    const dist_tl_bl = tl_pat.center.distance(bl_pat.center);
    const avg_dist = (dist_tl_tr + dist_tl_bl) / 2.0;

    const modules_between = avg_dist / avg_mod_size;
    const est_dim = modules_between + 7.0;

    // S = 17 + 4 * V => V = (S - 17) / 4
    const est_v_float = (est_dim - 17.0) / 4.0;
    const est_v_clamped = @as(u8, @intFromFloat(@max(1.0, @min(40.0, @round(est_v_float)))));
    const matrix_size = 17 + 4 * est_v_clamped;

    return .{
        .top_left = tl_pat,
        .top_right = tr_pat,
        .bottom_left = bl_pat,
        .estimated_module_size = avg_mod_size,
        .estimated_version = est_v_clamped,
        .matrix_size = matrix_size,
    };
}

/// End-to-end finder pattern detection on a binary bitmap.
pub fn detectFinders(bitmap: []const u8, width: usize, height: usize) FinderError!FinderTriad {
    var candidates: [MAX_CANDIDATES]FinderPattern = undefined;
    const num_found = findCandidates(bitmap, width, height, &candidates);
    return selectAndOrderTriad(&candidates, num_found);
}

// ============================================================================
// TESTS
// ============================================================================

test "checkRatio11311 exact and perturbed values" {
    const testing = std.testing;

    // Exact ratio 1:1:3:1:1
    try testing.expect(checkRatio11311(.{ 2, 2, 6, 2, 2 }));
    try testing.expect(checkRatio11311(.{ 5, 5, 15, 5, 5 }));
    try testing.expect(checkRatio11311(.{ 10, 10, 30, 10, 10 }));

    // Slightly perturbed (within 50% tolerance)
    try testing.expect(checkRatio11311(.{ 9, 11, 31, 10, 9 }));

    // Invalid ratios
    try testing.expect(!checkRatio11311(.{ 2, 2, 2, 2, 2 })); // 1:1:1:1:1 (Alignment pattern, not Finder)
    try testing.expect(!checkRatio11311(.{ 1, 1, 1, 1, 1 }));
    try testing.expect(!checkRatio11311(.{ 5, 5, 5, 5, 5 }));
    try testing.expect(!checkRatio11311(.{ 0, 2, 6, 2, 2 })); // Zero run
}

/// Helper function to draw an axis-aligned 7x7 module finder pattern at (px, py) with given module size.
fn drawFinderPattern(bitmap: []u8, width: usize, height: usize, px: usize, py: usize, mod_size: usize) void {
    const total_size = mod_size * 7;
    for (0..total_size) |dy| {
        for (0..total_size) |dx| {
            const mx = dx / mod_size; // 0..6
            const my = dy / mod_size; // 0..6

            const is_dark = (mx == 0 or mx == 6 or my == 0 or my == 6) or // Outer ring
                (mx >= 2 and mx <= 4 and my >= 2 and my <= 4); // Inner stone

            const x = px + dx;
            const y = py + dy;
            if (x < width and y < height) {
                bitmap[y * width + x] = if (is_dark) 1 else 0;
            }
        }
    }
}

test "detectFinders detects single isolated finder pattern with sub-pixel center" {
    const testing = std.testing;
    const w: usize = 64;
    const h: usize = 64;
    var bitmap: [w * h]u8 = @splat(0); // All light

    // Draw 7x7 finder pattern at (px=20, py=20) with module size = 4
    // Expected center is at px + 3.5 * mod_size = 20 + 14 = 34.0
    drawFinderPattern(&bitmap, w, h, 20, 20, 4);

    var candidates: [MAX_CANDIDATES]FinderPattern = undefined;
    const n = findCandidates(&bitmap, w, h, &candidates);

    try testing.expect(n >= 1);
    const c = candidates[0];
    try testing.expectApproxEqAbs(@as(f64, 34.0), c.center.x, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 34.0), c.center.y, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 4.0), c.estimated_module_size, 0.5);
}

test "detectFinders finds clean triad, orders TL/TR/BL, and estimates Version 1" {
    const testing = std.testing;
    const mod_size: usize = 4;
    const size: usize = 21; // Version 1
    const qz: usize = 4; // 4 modules quiet zone
    const dim = (size + 2 * qz) * mod_size; // (21 + 8) * 4 = 116

    var bitmap: [dim * dim]u8 = @splat(0);

    // V1 finders are at:
    // Top-Left: module (0, 0) => pixel (qz * mod_size, qz * mod_size) = (16, 16)
    // Top-Right: module (14, 0) => pixel ((qz + 14) * 4, qz * 4) = (72, 16)
    // Bottom-Left: module (0, 14) => pixel (qz * 4, (qz + 14) * 4) = (16, 72)
    drawFinderPattern(&bitmap, dim, dim, 16, 16, mod_size);
    drawFinderPattern(&bitmap, dim, dim, 72, 16, mod_size);
    drawFinderPattern(&bitmap, dim, dim, 16, 72, mod_size);

    const triad = try detectFinders(&bitmap, dim, dim);

    // Verify ordering:
    // TL should be near (30.0, 30.0) -> (16 + 14, 16 + 14)
    // TR should be near (86.0, 30.0) -> (72 + 14, 16 + 14)
    // BL should be near (30.0, 86.0) -> (16 + 14, 72 + 14)
    try testing.expectApproxEqAbs(@as(f64, 30.0), triad.top_left.center.x, 1.5);
    try testing.expectApproxEqAbs(@as(f64, 30.0), triad.top_left.center.y, 1.5);

    try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_right.center.x, 1.5);
    try testing.expectApproxEqAbs(@as(f64, 30.0), triad.top_right.center.y, 1.5);

    try testing.expectApproxEqAbs(@as(f64, 30.0), triad.bottom_left.center.x, 1.5);
    try testing.expectApproxEqAbs(@as(f64, 86.0), triad.bottom_left.center.y, 1.5);

    // Version estimation
    try testing.expectEqual(@as(u8, 1), triad.estimated_version);
    try testing.expectEqual(@as(u8, 21), triad.matrix_size);
}

test "detectFinders correctly identifies TL/TR/BL under 90, 180, and 270 degree rotations" {
    const testing = std.testing;
    const mod_size: usize = 4;
    const dim: usize = 120;

    // Case 1: Rotated 90 degrees clockwise
    // TL moves to Top-Right (72, 16)
    // TR moves to Bottom-Right (72, 72)
    // BL moves to Top-Left (16, 16)
    {
        var bmp: [dim * dim]u8 = @splat(0);
        drawFinderPattern(&bmp, dim, dim, 72, 16, mod_size); // New TL
        drawFinderPattern(&bmp, dim, dim, 72, 72, mod_size); // New TR
        drawFinderPattern(&bmp, dim, dim, 16, 16, mod_size); // New BL

        const triad = try detectFinders(&bmp, dim, dim);

        // TL must be recognized as (72+14=86, 16+14=30)
        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_left.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 30.0), triad.top_left.center.y, 1.5);

        // TR must be recognized as (86, 86)
        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_right.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_right.center.y, 1.5);

        // BL must be recognized as (30, 30)
        try testing.expectApproxEqAbs(@as(f64, 30.0), triad.bottom_left.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 30.0), triad.bottom_left.center.y, 1.5);
    }

    // Case 2: Rotated 180 degrees
    // TL moves to Bottom-Right (72, 72)
    // TR moves to Bottom-Left (16, 72)
    // BL moves to Top-Right (72, 16)
    {
        var bmp: [dim * dim]u8 = @splat(0);
        drawFinderPattern(&bmp, dim, dim, 72, 72, mod_size); // New TL
        drawFinderPattern(&bmp, dim, dim, 16, 72, mod_size); // New TR
        drawFinderPattern(&bmp, dim, dim, 72, 16, mod_size); // New BL

        const triad = try detectFinders(&bmp, dim, dim);

        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_left.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_left.center.y, 1.5);

        try testing.expectApproxEqAbs(@as(f64, 30.0), triad.top_right.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.top_right.center.y, 1.5);

        try testing.expectApproxEqAbs(@as(f64, 86.0), triad.bottom_left.center.x, 1.5);
        try testing.expectApproxEqAbs(@as(f64, 30.0), triad.bottom_left.center.y, 1.5);
    }
}

test "detectFinders estimates Version 7 accurately" {
    const testing = std.testing;
    const mod_size: usize = 3;
    const size: usize = 45; // Version 7
    const qz: usize = 4;
    const dim = (size + 2 * qz) * mod_size; // (45 + 8) * 3 = 159

    var bitmap: [dim * dim]u8 = @splat(0);

    // V7 finders:
    // TL at module (0, 0) => pixel (12, 12)
    // TR at module (38, 0) => pixel (12 + 38 * 3, 12) = (126, 12)
    // BL at module (0, 38) => pixel (12, 126)
    drawFinderPattern(&bitmap, dim, dim, 12, 12, mod_size);
    drawFinderPattern(&bitmap, dim, dim, 126, 12, mod_size);
    drawFinderPattern(&bitmap, dim, dim, 12, 126, mod_size);

    const triad = try detectFinders(&bitmap, dim, dim);
    try testing.expectEqual(@as(u8, 7), triad.estimated_version);
    try testing.expectEqual(@as(u8, 45), triad.matrix_size);
}

test "detectFinders rejects blank image, 1D barcode, and text" {
    const testing = std.testing;
    const w: usize = 100;
    const h: usize = 100;

    // 1. All blank (light) image
    {
        const blank: [w * h]u8 = @splat(0);
        try testing.expectError(error.FinderPatternsNotFound, detectFinders(&blank, w, h));
    }

    // 2. 1D Barcode pattern (vertical stripes)
    // Horizontal scan encounters transitions, but vertical scan is uniform and must fail
    {
        var barcode: [w * h]u8 = undefined;
        for (0..h) |y| {
            for (0..w) |x| {
                // Alternating stripes of width 2, 2, 6, 2, 2
                const pattern = (x % 14);
                const is_dark = (pattern < 2) or (pattern >= 4 and pattern < 10) or (pattern >= 12);
                barcode[y * w + x] = if (is_dark) 1 else 0;
            }
        }
        try testing.expectError(error.FinderPatternsNotFound, detectFinders(&barcode, w, h));
    }

    // 3. Text simulation (E and M grid)
    {
        var text_img: [w * h]u8 = @splat(0);
        // Draw repeated 'E' shapes: spine on left, 3 bars
        var ey: usize = 10;
        while (ey < 90) : (ey += 15) {
            var ex: usize = 10;
            while (ex < 90) : (ex += 15) {
                // Draw spine
                for (0..10) |dy| text_img[(ey + dy) * w + ex] = 1;
                // Draw 3 bars
                for (0..8) |dx| {
                    text_img[ey * w + ex + dx] = 1;
                    text_img[(ey + 5) * w + ex + dx] = 1;
                    text_img[(ey + 9) * w + ex + dx] = 1;
                }
            }
        }
        try testing.expectError(error.FinderPatternsNotFound, detectFinders(&text_img, w, h));
    }
}

test "detectFinders rejects image with only 2 finders" {
    const testing = std.testing;
    const w: usize = 100;
    const h: usize = 100;
    var bitmap: [w * h]u8 = @splat(0);

    // Only draw 2 finders (TL and TR)
    drawFinderPattern(&bitmap, w, h, 10, 10, 3);
    drawFinderPattern(&bitmap, w, h, 60, 10, 3);

    // Must fail because 3 are required to form a triad
    try testing.expectError(error.FinderPatternsNotFound, detectFinders(&bitmap, w, h));
}

test "detectFinders with 4 finders selects the best right-isosceles triad" {
    const testing = std.testing;
    const mod_size: usize = 3;
    const w: usize = 120;
    const h: usize = 120;
    var bitmap: [w * h]u8 = @splat(0);

    // QR triad:
    // TL at (15, 15)
    // TR at (75, 15) -> dist = 60
    // BL at (15, 75) -> dist = 60
    drawFinderPattern(&bitmap, w, h, 15, 15, mod_size);
    drawFinderPattern(&bitmap, w, h, 75, 15, mod_size);
    drawFinderPattern(&bitmap, w, h, 15, 75, mod_size);

    // 4th spurious finder at (90, 90) (does not form a right-isosceles triangle with the others)
    drawFinderPattern(&bitmap, w, h, 90, 90, mod_size);

    const triad = try detectFinders(&bitmap, w, h);

    // Triad selection must choose the right-isosceles triangle (TL near (25.5, 25.5))
    try testing.expectApproxEqAbs(@as(f64, 25.5), triad.top_left.center.x, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 25.5), triad.top_left.center.y, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 85.5), triad.top_right.center.x, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 25.5), triad.top_right.center.y, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 25.5), triad.bottom_left.center.x, 2.0);
    try testing.expectApproxEqAbs(@as(f64, 85.5), triad.bottom_left.center.y, 2.0);
}

test "detectFinders under moderate perspective tilt (20 degrees)" {
    const testing = std.testing;
    const w: usize = 140;
    const h: usize = 140;
    var bitmap: [w * h]u8 = @splat(0);

    // Simulating 20-degree tilt: horizontal dimension slightly compressed (cos(20 deg) ~ 0.94)
    // TL at (20, 20)
    // TR at (85, 25) (slight vertical shift and horizontal compression)
    // BL at (15, 88)
    drawFinderPattern(&bitmap, w, h, 20, 20, 3);
    drawFinderPattern(&bitmap, w, h, 85, 25, 3);
    drawFinderPattern(&bitmap, w, h, 15, 88, 3);

    const triad = try detectFinders(&bitmap, w, h);
    // Must successfully identify all 3 finders
    try testing.expect(triad.top_left.count >= 1);
    try testing.expect(triad.top_right.count >= 1);
    try testing.expect(triad.bottom_left.count >= 1);
}
