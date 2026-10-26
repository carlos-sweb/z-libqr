//! Codeword interleaving with Reed-Solomon Error Correction and zigzag matrix placement.
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT), c/qrcodegen.c:
//!     addEccAndInterleave, drawCodewords.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const gf256 = @import("gf256.zig");
const matrix = @import("matrix.zig");

pub const Ecc = types.Ecc;

/// Appends Reed-Solomon error correction bytes to each block of `data` and interleaves
/// both data bytes and ECC bytes into `result`.
///
/// Preconditions:
///   - `data.len == tables.getNumDataCodewords(version, ecl)`
///   - `result.len == tables.getNumRawDataModules(version) / 8`
///
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function addEccAndInterleave.
pub fn addEccAndInterleave(data: []const u8, version: u8, ecl: Ecc, result: []u8) void {
    const raw_codewords: usize = tables.getNumRawDataModules(version) / 8;
    const data_len: usize = tables.getNumDataCodewords(version, ecl);
    std.debug.assert(data.len == data_len);
    std.debug.assert(result.len == raw_codewords);

    const e: usize = @intCast(@backingInt(ecl));
    const v: usize = version;
    const num_blocks: usize = tables.num_error_correction_blocks[e][v];
    const block_ecc_len: usize = tables.ecc_codewords_per_block[e][v];
    const num_short_blocks: usize = num_blocks - (raw_codewords % num_blocks);
    const short_block_data_len: usize = raw_codewords / num_blocks - block_ecc_len;

    // Compute RS generator divisor polynomial for block_ecc_len
    var rs_div: [gf256.max_degree]u8 = undefined;
    gf256.computeDivisor(rs_div[0..block_ecc_len]);

    var dat_offset: usize = 0;
    var i: usize = 0;
    while (i < num_blocks) : (i += 1) {
        const dat_len = short_block_data_len + if (i < num_short_blocks) @as(usize, 0) else @as(usize, 1);
        const dat_slice = data[dat_offset .. dat_offset + dat_len];
        var ecc: [gf256.max_degree]u8 = undefined;
        gf256.computeRemainder(dat_slice, rs_div[0..block_ecc_len], ecc[0..block_ecc_len]);

        // Copy data codewords interleaved
        var j: usize = 0;
        var k: usize = i;
        while (j < dat_len) : (j += 1) {
            if (j == short_block_data_len) {
                k -= num_short_blocks;
            }
            result[k] = dat_slice[j];
            k += num_blocks;
        }

        // Copy ECC codewords interleaved
        j = 0;
        k = data_len + i;
        while (j < block_ecc_len) : (j += 1) {
            result[k] = ecc[j];
            k += num_blocks;
        }

        dat_offset += dat_len;
    }
    std.debug.assert(dat_offset == data_len);
}

/// Draws raw codewords (interleaved data and ECC) onto the matrix in the 2-column zigzag scan pattern.
/// Only writes into non-function modules (modules where FUNCTION_FLAG is 0).
/// Leaves any remainder bits (0 to 7) as light (0).
///
/// Precondition: `modules.len >= size * size` and `data.len == tables.getNumRawDataModules(version) / 8`.
///
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawCodewords.
pub fn drawCodewords(modules: []u8, version: u8, data: []const u8) void {
    const size = tables.symbolSize(version);
    const total_bits: usize = data.len * 8;
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

                if (!matrix.isFunction(modules, size, x, y) and bit_idx < total_bits) {
                    const byte_val = data[bit_idx >> 3];
                    const bit = ((byte_val >> @intCast(7 - (bit_idx & 7))) & 1) != 0;
                    if (bit) {
                        modules[@as(usize, y) * size + x] |= 0x01;
                    } else {
                        modules[@as(usize, y) * size + x] &= ~@as(u8, 0x01);
                    }
                    bit_idx += 1;
                }
            }
        }
    }
    std.debug.assert(bit_idx == total_bits);
}

// ---- Unit Tests ----

const testing = std.testing;

test "addEccAndInterleave matches v1-M HELLO WORLD exact codewords" {
    // For Version 1, Level M: 16 data codewords, 10 ECC codewords (total 26)
    // 16 data codewords produced by "HELLO WORLD" in alphanumeric mode:
    const data_cw = [_]u8{
        0x20, 0x5b, 0x0b, 0x78, 0xd1, 0x72, 0xdc, 0x4d,
        0x43, 0x40, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
    };
    const expected_ecc = [_]u8{
        0xc4, 0x23, 0x27, 0x77, 0xeb, 0xd7, 0xe7, 0xe2, 0x5d, 0x17,
    };

    var result: [26]u8 = undefined;
    addEccAndInterleave(&data_cw, 1, .medium, &result);

    try testing.expectEqualSlices(u8, &data_cw, result[0..16]);
    try testing.expectEqualSlices(u8, &expected_ecc, result[16..26]);
}

test "addEccAndInterleave multi-block (v3-H: 2 short blocks + 2 long blocks)" {
    // Version 3, High: 26 data codewords, 70 raw codewords, 4 blocks.
    // Verified against Nayuki's reference implementation output.
    const data_cw = [_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13,
        14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    };
    const expected_interleaved = [_]u8{
        0x1,  0xe,  0x2,  0xf,  0x3,  0x10, 0x4,  0x11, 0x5,  0x12, 0x6,  0x13, 0x7,  0x14,
        0x8,  0x15, 0x9,  0x16, 0xa,  0x17, 0xb,  0x18, 0xc,  0x19, 0xd,  0x1a, 0x6c, 0x3d,
        0xc6, 0xf6, 0xa9, 0x22, 0x85, 0x3f, 0x6b, 0x12, 0x7a, 0x3,  0x17, 0x25, 0x3d, 0x8b,
        0xaa, 0x8c, 0x4,  0x28, 0xf0, 0x15, 0x89, 0xa8, 0x24, 0x2c, 0xda, 0xc3, 0xa7, 0x86,
        0x49, 0x26, 0x4b, 0xb5, 0xf3, 0xa7, 0x8c, 0x61, 0x7,  0x68, 0x66, 0xda, 0x2e, 0xe4,
    };

    var result: [70]u8 = undefined;
    addEccAndInterleave(&data_cw, 3, .high, &result);
    try testing.expectEqualSlices(u8, &expected_interleaved, &result);
}

test "drawCodewords handles version with remainder bits (v2 has 7 remainder bits)" {
    // Version 2: size = 25. getNumRawDataModules(2) = 359 bits.
    // 359 = 44 bytes * 8 + 7 remainder bits.
    // Raw codewords: 44 bytes.
    const size = tables.symbolSize(2);
    var modules: [25 * 25]u8 = undefined;
    matrix.initializeFunctionModules(&modules, 2, .medium);

    var raw_codewords: [44]u8 = undefined;
    @memset(&raw_codewords, 0xFF); // All data bits set to 1

    drawCodewords(&modules, 2, &raw_codewords);

    // Verify exactly 352 data bits were written, and the 7 remainder bits remain 0
    var data_bits_count: usize = 0;
    var remainder_bits_count: usize = 0;
    for (0..size) |y| {
        for (0..size) |x| {
            if (!matrix.isFunction(&modules, size, @intCast(x), @intCast(y))) {
                if ((modules[y * size + x] & 0x01) != 0) {
                    data_bits_count += 1;
                } else {
                    remainder_bits_count += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 352), data_bits_count);
    try testing.expectEqual(@as(usize, 7), remainder_bits_count);
}

test "golden vector v1-M HELLO WORLD mask 0" {
    // 1. Prepare data codewords for HELLO WORLD in v1-M
    const data_cw = [_]u8{
        0x20, 0x5b, 0x0b, 0x78, 0xd1, 0x72, 0xdc, 0x4d,
        0x43, 0x40, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
    };
    var raw_codewords: [26]u8 = undefined;
    addEccAndInterleave(&data_cw, 1, .medium, &raw_codewords);

    // 2. Initialize matrix function modules for v1-M with mask 0
    const size = tables.symbolSize(1); // 21
    var modules: [21 * 21]u8 = undefined;
    matrix.initializeFunctionModules(&modules, 1, .medium);

    // 3. Draw codewords via zigzag scan
    drawCodewords(&modules, 1, &raw_codewords);

    // 4. Apply mask 0: (x + y) % 2 == 0
    // Invert codeword modules where mask condition is true
    for (0..size) |y| {
        for (0..size) |x| {
            if (!matrix.isFunction(&modules, size, @intCast(x), @intCast(y))) {
                if ((x + y) % 2 == 0) {
                    modules[y * size + x] ^= 0x01;
                }
            }
        }
    }

    // 5. Clean function flags: mask every byte to 0 or 1
    for (&modules) |*m| {
        m.* &= 0x01;
    }

    // 6. Verify bit-by-bit against Nayuki's reference output
    const expected_golden = [_]u8{
        1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0,
        0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0, 0,
        1, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 0,
        0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 0,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 0, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
        1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0,
        1, 0, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 1, 0, 0, 1,
        1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 1, 0, 0, 0, 0, 1,
    };

    try testing.expectEqualSlices(u8, &expected_golden, &modules);

    // Verify all bytes are strictly 0 or 1
    for (modules) |m| {
        try testing.expect(m == 0 or m == 1);
    }
}
