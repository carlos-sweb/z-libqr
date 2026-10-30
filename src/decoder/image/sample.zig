//! Module grid sampling for QR Code Model 2.
//!
//! Maps each canonical module coordinate (c + 0.5, r + 0.5) through the computed
//! 3x3 projective homography to sample pixels from the binary bitmap into an
//! S x S module array (0 or 1, byte-per-module, row-major, without quiet zone).
//!
//! Citations:
//!   - ISO/IEC 18004:2015, Section 6.3 ("QR Code Model 2 Symbol Structure")
//!   - zxing-cpp: core/src/GridSampler.cpp
//!   - quirc: lib/identify.c, read_cell()

const std = @import("std");
const tables = @import("../../tables.zig");
const Point = @import("finder.zig").Point;
const FinderTriad = @import("finder.zig").FinderTriad;
const Transform = @import("transform.zig").Transform;
const findBottomRightAlignment = @import("alignment.zig").findBottomRightAlignment;

pub const SampleError = error{
    DegenerateTransform,
    BufferTooSmall,
    InvalidMatrixSize,
};

/// Computes the optimal 4-point homography and samples an S x S matrix from the bitmap.
/// `out_matrix` must have length at least `size * size`.
pub fn sampleMatrix(
    bitmap: []const u8,
    width: usize,
    height: usize,
    triad: FinderTriad,
    out_matrix: []u8,
) SampleError!Transform {
    const s: usize = triad.matrix_size;
    if (out_matrix.len < s * s) return error.BufferTooSmall;
    if (s < 21 or s > 177 or ((s - 17) % 4 != 0)) return error.InvalidMatrixSize;

    const s_float: f64 = @floatFromInt(s);
    const tl = triad.top_left.center;
    const tr = triad.top_right.center;
    const bl = triad.bottom_left.center;

    // Initial 4th corner estimate via parallelogram completion: BR = TR + BL - TL
    const br_est = Point{
        .x = tr.x + bl.x - tl.x,
        .y = tr.y + bl.y - tl.y,
    };

    // Initial transform assuming parallelogram
    const initial_trans = Transform.quadrilateralToQuadrilateral(
        3.5,
        3.5,
        s_float - 3.5,
        3.5,
        s_float - 3.5,
        s_float - 3.5,
        3.5,
        s_float - 3.5,
        tl.x,
        tl.y,
        tr.x,
        tr.y,
        br_est.x,
        br_est.y,
        bl.x,
        bl.y,
    ) orelse return error.DegenerateTransform;

    // Try to refine bottom-right corner using Alignment Pattern if version >= 2
    var dst_u2: f64 = s_float - 3.5;
    var v2: f64 = s_float - 3.5;
    var x2: f64 = br_est.x;
    var y2: f64 = br_est.y;

    if (triad.estimated_version >= 2) {
        if (findBottomRightAlignment(bitmap, width, height, triad.estimated_version, initial_trans, triad.estimated_module_size)) |align_pt| {
            const positions_struct = tables.getAlignmentPatternPositions(triad.estimated_version);
            const positions = positions_struct.slice();
            if (positions.len > 0) {
                const align_mod: f64 = @floatFromInt(positions[positions.len - 1]);
                dst_u2 = align_mod + 0.5;
                v2 = align_mod + 0.5;
                x2 = align_pt.x;
                y2 = align_pt.y;
            }
        }
    }

    // Final refined projective transformation
    const trans = Transform.quadrilateralToQuadrilateral(
        3.5,
        3.5,
        s_float - 3.5,
        3.5,
        dst_u2,
        v2,
        3.5,
        s_float - 3.5,
        tl.x,
        tl.y,
        tr.x,
        tr.y,
        x2,
        y2,
        bl.x,
        bl.y,
    ) orelse return error.DegenerateTransform;

    // Sample each module at its center (c + 0.5, r + 0.5)
    for (0..s) |r| {
        const v = @as(f64, @floatFromInt(r)) + 0.5;
        const row_offset = r * s;

        for (0..s) |c| {
            const u = @as(f64, @floatFromInt(c)) + 0.5;
            const pt = trans.map(u, v);

            const px: isize = @intFromFloat(@round(pt.x));
            const py: isize = @intFromFloat(@round(pt.y));

            if (px >= 0 and px < width and py >= 0 and py < height) {
                out_matrix[row_offset + c] = bitmap[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))];
            } else {
                out_matrix[row_offset + c] = 0; // Default to light if out of bounds
            }
        }
    }

    return trans;
}

test "sampleMatrix reproduces exact clean matrix for Version 1" {
    const testing = std.testing;
    const detectFinders = @import("finder.zig").detectFinders;
    const root = @import("../../root.zig");

    // 1. Encode "HELLO WORLD" to a clean QrMatrix
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, "HELLO WORLD", .{ .ecc = .medium });
    const size = qr.size; // 21 for V1

    // 2. Rasterize to synthetic bitmap (scale 4, quiet zone 4)
    const scale: usize = 4;
    const qz: usize = 4;
    const dim = (size + 2 * qz) * scale;
    var bitmap: [116 * 116]u8 = @splat(0); // White

    for (0..size) |r| {
        for (0..size) |c| {
            const is_dark = qr.modules[r * size + c] == 1;
            if (is_dark) {
                const py = (qz + r) * scale;
                const px = (qz + c) * scale;
                for (0..scale) |dy| {
                    for (0..scale) |dx| {
                        bitmap[(py + dy) * dim + (px + dx)] = 1;
                    }
                }
            }
        }
    }

    // 3. Detect finders
    const triad = try detectFinders(&bitmap, dim, dim);
    try testing.expectEqual(@as(u8, 1), triad.estimated_version);
    try testing.expectEqual(@as(u8, 21), triad.matrix_size);

    // 4. Sample matrix
    var sampled: [21 * 21]u8 = undefined;
    _ = try sampleMatrix(&bitmap, dim, dim, triad, &sampled);

    // 5. Verify byte-for-byte exact equality between original and sampled matrix
    try testing.expectEqualStrings(qr.modules, &sampled);
}

test "sampleMatrix reproduces exact clean matrix for Version 2 with alignment pattern" {
    const testing = std.testing;
    const detectFinders = @import("finder.zig").detectFinders;
    const root = @import("../../root.zig");

    // 1. Encode into Version 2
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, "TESTING V2 WITH ALIGNMENT PATTERN", .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25 for V2

    // 2. Rasterize (scale 4, quiet zone 4) => (25 + 8) * 4 = 132x132
    const scale: usize = 4;
    const qz: usize = 4;
    const dim = (size + 2 * qz) * scale;
    var bitmap: [132 * 132]u8 = @splat(0);

    for (0..size) |r| {
        for (0..size) |c| {
            const is_dark = qr.modules[r * size + c] == 1;
            if (is_dark) {
                const py = (qz + r) * scale;
                const px = (qz + c) * scale;
                for (0..scale) |dy| {
                    for (0..scale) |dx| {
                        bitmap[(py + dy) * dim + (px + dx)] = 1;
                    }
                }
            }
        }
    }

    // 3. Detect finders
    const triad = try detectFinders(&bitmap, dim, dim);
    try testing.expectEqual(@as(u8, 2), triad.estimated_version);
    try testing.expectEqual(@as(u8, 25), triad.matrix_size);

    // 4. Sample matrix
    var sampled: [25 * 25]u8 = undefined;
    _ = try sampleMatrix(&bitmap, dim, dim, triad, &sampled);

    // 5. Exact match
    try testing.expectEqualStrings(qr.modules, &sampled);
}

test "sampleMatrix reproduces exact clean matrix and decodes for Version 7 (V >= 7 with BCH version blocks)" {
    const testing = std.testing;
    const detectFinders = @import("finder.zig").detectFinders;
    const root = @import("../../root.zig");

    // 1. Encode "X" into Version 7 (medium ECC)
    var mat_buf: [root.Tier2.max_buffer_len]u8 = undefined;
    const qr = try root.Tier2.encodeAdvanced(&mat_buf, "X", .{
        .ecc = .medium,
        .min_version = 7,
    });
    const size = qr.size; // 45 for V7
    try testing.expectEqual(@as(u8, 7), qr.version);
    try testing.expectEqual(@as(u8, 45), size);

    // 2. Rasterize (scale 4, quiet zone 4) => (45 + 8) * 4 = 212x212
    const scale: usize = 4;
    const qz: usize = 4;
    const dim = (size + 2 * qz) * scale;
    var bitmap: [212 * 212]u8 = @splat(0);

    for (0..size) |r| {
        for (0..size) |c| {
            const is_dark = qr.modules[r * size + c] == 1;
            if (is_dark) {
                const py = (qz + r) * scale;
                const px = (qz + c) * scale;
                for (0..scale) |dy| {
                    for (0..scale) |dx| {
                        bitmap[(py + dy) * dim + (px + dx)] = 1;
                    }
                }
            }
        }
    }

    // 3. Detect finders
    const triad = try detectFinders(&bitmap, dim, dim);
    try testing.expectEqual(@as(u8, 7), triad.estimated_version);
    try testing.expectEqual(@as(u8, 45), triad.matrix_size);

    // 4. Sample matrix
    var sampled: [45 * 45]u8 = undefined;
    _ = try sampleMatrix(&bitmap, dim, dim, triad, &sampled);

    // 5. Verify byte-for-byte exact equality between original and sampled matrix
    try testing.expectEqualStrings(qr.modules, &sampled);

    // 6. Decode sampled matrix with Tier 2 matrix decoder
    var out_buf: [root.DecoderTier2.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier2.decode(&sampled, size, &out_buf);
    try testing.expectEqualStrings("X", res.data);
    try testing.expectEqual(@as(u8, 7), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}
