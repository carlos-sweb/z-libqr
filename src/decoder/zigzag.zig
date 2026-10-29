//! Inverse zigzag matrix scan and mask removal.
//!
//! Extracts interleaved data and error correction codewords from the module matrix.
//! Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawCodewords.

const std = @import("std");
const tables = @import("../tables.zig");
const matrix = @import("../matrix.zig");
const mask_mod = @import("../mask.zig");

/// Extracts raw interleaved codewords from the module matrix by unmasking and reading
/// all non-function data modules along the 2-column zigzag traversal path.
///
/// Preconditions:
///   - `modules.len >= size * size`
///   - `out_codewords.len == tables.getNumRawDataModules(version) / 8`
pub fn extractCodewords(
    modules: []const u8,
    size: u8,
    version: u8,
    mask: u3,
    out_codewords: []u8,
) void {
    const total_bits: usize = out_codewords.len * 8;
    std.debug.assert(out_codewords.len == tables.getNumRawDataModules(version) / 8);
    @memset(out_codewords, 0);

    // Build temporary function module mask to identify non-data modules
    var func_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
    matrix.markFunctionModules(func_buf[0..tables.moduleCount(version)], version);

    var bit_idx: usize = 0;

    // Zigzag scan: pairs of columns from right (size-1) down to 1
    var right: i32 = @as(i32, size) - 1;
    while (right >= 1) : (right -= 2) {
        // Column 6 is skipped because it contains the vertical timing pattern
        if (right == 6) right = 5;

        var vert: i32 = 0;
        while (vert < size) : (vert += 1) {
            var j: i32 = 0;
            while (j < 2) : (j += 1) {
                const x: u8 = @intCast(right - j);
                const upward: bool = (((right + 1) & 2) == 0);
                const y: u8 = @intCast(if (upward) (@as(i32, size) - 1 - vert) else vert);

                const is_func = (func_buf[@as(usize, y) * size + x] & matrix.FUNCTION_FLAG) != 0;
                if (!is_func and bit_idx < total_bits) {
                    var bit: u1 = @intCast(modules[@as(usize, y) * size + x] & 1);
                    if (mask_mod.isMaskInverted(mask, x, y)) {
                        bit ^= 1;
                    }
                    if (bit != 0) {
                        out_codewords[bit_idx >> 3] |= @as(u8, 1) << @intCast(7 - (bit_idx & 7));
                    }
                    bit_idx += 1;
                }
            }
        }
    }

    std.debug.assert(bit_idx == total_bits);
}

const testing = std.testing;
const interleave = @import("../interleave.zig");

test "zigzag extraction roundtrip with drawCodewords across versions and masks" {
    const versions = [_]u8{ 1, 3, 7, 10, 40 };
    const masks = [_]u3{ 0, 1, 4, 7 };

    for (versions) |v| {
        const size = tables.symbolSize(v);
        const raw_len = tables.getNumRawDataModules(v) / 8;

        var input_codewords: [tables.max_raw_codewords]u8 = undefined;
        var output_codewords: [tables.max_raw_codewords]u8 = undefined;

        // Populate pseudo-random test pattern
        for (input_codewords[0..raw_len], 0..) |*b, i| {
            b.* = @truncate(i * 37 + 13);
        }

        for (masks) |m| {
            var modules: [tables.moduleCount(tables.max_version)]u8 = undefined;
            const matrix_slice = modules[0..tables.moduleCount(v)];

            // Draw clean function modules and codewords
            matrix.initializeFunctionModules(matrix_slice, v, .medium);
            interleave.drawCodewords(matrix_slice, v, input_codewords[0..raw_len]);
            mask_mod.applyMask(matrix_slice, size, m);

            // Strip FUNCTION_FLAG to simulate real module matrix (only 0 or 1)
            for (matrix_slice) |*mod| {
                mod.* &= 0x01;
            }

            // Extract codewords back
            extractCodewords(matrix_slice, size, v, m, output_codewords[0..raw_len]);

            try testing.expectEqualSlices(u8, input_codewords[0..raw_len], output_codewords[0..raw_len]);
        }
    }
}
