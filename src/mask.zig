//! QR Code mask patterns, penalty scoring (N1, N2, N3, N4) and automatic mask selection.
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT), c/qrcodegen.c:
//!     PENALTY_N1, PENALTY_N2, PENALTY_N3, PENALTY_N4,
//!     applyMask, getPenaltyScore, finderPenaltyCountPatterns,
//!     finderPenaltyTerminateAndCount, finderPenaltyAddHistory.

const std = @import("std");
const tables = @import("tables.zig");
const types = @import("types.zig");
const matrix = @import("matrix.zig");

pub const Ecc = types.Ecc;

/// Penalty scores defined by QR Code Model 2 (ISO/IEC 18004).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, lines 122-125.
pub const PENALTY_N1: i32 = 3;
pub const PENALTY_N2: i32 = 3;
pub const PENALTY_N3: i32 = 40;
pub const PENALTY_N4: i32 = 10;

/// Returns true if module at (x, y) should be inverted for mask pattern `mask`.
/// Precondition: `0 <= mask <= 7`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function applyMask.
pub fn isMaskInverted(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => (((x + y) % 2) + (x * y) % 3) % 2 == 0,
    };
}

/// Applies (or undoes) `mask` onto `modules` by inverting every non-function module
/// where `isMaskInverted(mask, x, y)` is true.
/// Calling `applyMask` a second time with the same mask value restores the original state (XOR symmetry).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function applyMask.
pub fn applyMask(modules: []u8, size: u8, mask: u3) void {
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) : (x += 1) {
            if (!matrix.isFunction(modules, size, @intCast(x), @intCast(y))) {
                if (isMaskInverted(mask, x, y)) {
                    modules[y * size + x] ^= 0x01;
                }
            }
        }
    }
}

// Helpers for penalty score calculation
// Source: nayuki/QR-Code-generator, c/qrcodegen.c.

fn finderPenaltyAddHistory(current_run_length: i32, run_history: *[7]i32, qrsize: i32) void {
    var run_len = current_run_length;
    if (run_history[0] == 0) {
        run_len += qrsize; // Add light border to initial run
    }
    std.mem.copyBackwards(i32, run_history[1..7], run_history[0..6]);
    run_history[0] = run_len;
}

fn finderPenaltyCountPatterns(run_history: *const [7]i32, qrsize: i32) i32 {
    const n = run_history[1];
    std.debug.assert(n <= qrsize * 3);
    const core = n > 0 and
        run_history[2] == n and
        run_history[3] == n * 3 and
        run_history[4] == n and
        run_history[5] == n;

    var count: i32 = 0;
    if (core and run_history[0] >= n * 4 and run_history[6] >= n) count += 1;
    if (core and run_history[6] >= n * 4 and run_history[0] >= n) count += 1;
    return count;
}

fn finderPenaltyTerminateAndCount(
    current_run_color: bool,
    current_run_length: i32,
    run_history: *[7]i32,
    qrsize: i32,
) i32 {
    var run_len = current_run_length;
    if (current_run_color) {
        finderPenaltyAddHistory(run_len, run_history, qrsize);
        run_len = 0;
    }
    run_len += qrsize;
    finderPenaltyAddHistory(run_len, run_history, qrsize);
    return finderPenaltyCountPatterns(run_history, qrsize);
}

/// Calculates the penalty score for the current matrix according to the four QR spec rules:
///   - N1: 5 or more adjacent modules of the same color in row/column
///   - N2: 2x2 blocks of the same color
///   - N3: finder-like patterns (1:1:3:1:1) in row/column
///   - N4: proportion of dark modules vs light modules
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function getPenaltyScore.
pub fn getPenaltyScore(modules: []const u8, size: u8) i64 {
    const qrsize: i32 = size;
    var result: i64 = 0;

    // Rule 1 & 3 in rows: Adjacent modules of same color + finder-like patterns
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var run_color = false;
        var run_x: i32 = 0;
        var run_history: [7]i32 = @splat(0);
        var x: usize = 0;
        while (x < size) : (x += 1) {
            const is_dark = (modules[y * size + x] & 0x01) != 0;
            if (is_dark == run_color) {
                run_x += 1;
                if (run_x == 5) {
                    result += PENALTY_N1;
                } else if (run_x > 5) {
                    result += 1;
                }
            } else {
                finderPenaltyAddHistory(run_x, &run_history, qrsize);
                if (!run_color) {
                    result += @as(i64, finderPenaltyCountPatterns(&run_history, qrsize)) * PENALTY_N3;
                }
                run_color = is_dark;
                run_x = 1;
            }
        }
        result += @as(i64, finderPenaltyTerminateAndCount(run_color, run_x, &run_history, qrsize)) * PENALTY_N3;
    }

    // Rule 1 & 3 in columns: Adjacent modules of same color + finder-like patterns
    var x: usize = 0;
    while (x < size) : (x += 1) {
        var run_color = false;
        var run_y: i32 = 0;
        var run_history: [7]i32 = @splat(0);
        var y_idx: usize = 0;
        while (y_idx < size) : (y_idx += 1) {
            const is_dark = (modules[y_idx * size + x] & 0x01) != 0;
            if (is_dark == run_color) {
                run_y += 1;
                if (run_y == 5) {
                    result += PENALTY_N1;
                } else if (run_y > 5) {
                    result += 1;
                }
            } else {
                finderPenaltyAddHistory(run_y, &run_history, qrsize);
                if (!run_color) {
                    result += @as(i64, finderPenaltyCountPatterns(&run_history, qrsize)) * PENALTY_N3;
                }
                run_color = is_dark;
                run_y = 1;
            }
        }
        result += @as(i64, finderPenaltyTerminateAndCount(run_color, run_y, &run_history, qrsize)) * PENALTY_N3;
    }

    // Rule 2: 2x2 blocks of modules having the same color
    y = 0;
    while (y < size - 1) : (y += 1) {
        x = 0;
        while (x < size - 1) : (x += 1) {
            const color = (modules[y * size + x] & 0x01);
            if (color == (modules[y * size + x + 1] & 0x01) and
                color == (modules[(y + 1) * size + x] & 0x01) and
                color == (modules[(y + 1) * size + x + 1] & 0x01))
            {
                result += PENALTY_N2;
            }
        }
    }

    // Rule 4: Balance of dark and light modules
    var dark: i32 = 0;
    for (modules[0 .. @as(usize, size) * size]) |m| {
        if ((m & 0x01) != 0) dark += 1;
    }
    const total: i32 = qrsize * qrsize;
    // Smallest integer k >= 0 such that (45-5k)% <= dark/total <= (55+5k)%
    const diff = @abs(dark * 20 - total * 10);
    const k: i32 = @as(i32, @intCast((diff + @as(u32, @intCast(total)) - 1) / @as(u32, @intCast(total)))) - 1;
    std.debug.assert(k >= 0 and k <= 9);
    result += @as(i64, k) * PENALTY_N4;

    return result;
}

/// Evaluates all 8 mask patterns, chooses the mask with the lowest penalty score,
/// and applies it permanently along with the final format bits.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, lines 269-286.
pub fn selectAndApplyOptimalMask(modules: []u8, version: u8, ecl: Ecc) u3 {
    const size = tables.symbolSize(version);
    var min_penalty: i64 = std.math.maxInt(i64);
    var best_mask: u3 = 0;

    var m: u3 = 0;
    while (true) : (m += 1) {
        applyMask(modules, size, m);
        matrix.drawFormatBits(modules, version, ecl, m);
        const penalty = getPenaltyScore(modules, size);
        if (penalty < min_penalty) {
            min_penalty = penalty;
            best_mask = m;
        }
        applyMask(modules, size, m); // Undo mask via XOR
        if (m == 7) break;
    }

    // Apply the winning mask and draw its final format bits
    applyMask(modules, size, best_mask);
    matrix.drawFormatBits(modules, version, ecl, best_mask);
    return best_mask;
}

// ---- Unit Tests ----

const testing = std.testing;
const interleave = @import("interleave.zig");

test "penalty scores and optimal mask match Nayuki for HELLO WORLD v1-M" {
    const size = tables.symbolSize(1);
    var modules: [21 * 21]u8 = undefined;
    matrix.initializeFunctionModules(&modules, 1, .medium);

    const data_cw = [_]u8{
        0x20, 0x5b, 0x0b, 0x78, 0xd1, 0x72, 0xdc, 0x4d,
        0x43, 0x40, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
    };
    var raw_codewords: [26]u8 = undefined;
    interleave.addEccAndInterleave(&data_cw, 1, .medium, &raw_codewords);
    interleave.drawCodewords(&modules, 1, &raw_codewords);

    // Expected penalties verified from Nayuki reference
    const expected_penalties = [_]i64{ 1071, 1166, 1202, 1143, 1127, 1288, 1155, 1165 };

    var m: u3 = 0;
    while (true) : (m += 1) {
        applyMask(&modules, size, m);
        matrix.drawFormatBits(&modules, 1, .medium, m);
        const pen = getPenaltyScore(&modules, size);
        try testing.expectEqual(expected_penalties[m], pen);
        applyMask(&modules, size, m); // Undo
        if (m == 7) break;
    }

    const chosen = selectAndApplyOptimalMask(&modules, 1, .medium);
    try testing.expectEqual(@as(u3, 0), chosen);
}

test "golden vector with non-zero optimal mask: HELLO v1-L selects Mask 2" {
    // Exact data codewords for alphanumeric "HELLO" in v1-L (19 codewords):
    const data_cw = [_]u8{
        0x20, 0x2b, 0x0b, 0x78, 0xcc, 0x00, 0xec, 0x11,
        0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
        0xec, 0x11, 0xec,
    };

    var raw_codewords: [26]u8 = undefined;
    interleave.addEccAndInterleave(&data_cw, 1, .low, &raw_codewords);

    var modules: [21 * 21]u8 = undefined;
    matrix.initializeFunctionModules(&modules, 1, .low);
    interleave.drawCodewords(&modules, 1, &raw_codewords);

    const best_mask = selectAndApplyOptimalMask(&modules, 1, .low);
    try testing.expectEqual(@as(u3, 2), best_mask);

    // Clean function flags to 0/1
    for (&modules) |*val| {
        val.* &= 0x01;
    }

    // Golden verification against Nayuki reference for v1-L mask 2
    const golden_v1_l_hello = [_]u8{
        1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0,
        1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1,
        0, 1, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0,
        0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 1, 0, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 0, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0,
    };

    try testing.expectEqualSlices(u8, &golden_v1_l_hello, &modules);

    // Verify all bytes are strictly 0 or 1
    for (modules) |val| {
        try testing.expect(val == 0 or val == 1);
    }
}
