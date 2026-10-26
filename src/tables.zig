//! Fundamental QR Code Model 2 constants, lookup tables, and per-version geometry.
//!
//! Every numeric value and algorithm in this file cites its source.
//! The primary reference is nayuki/QR-Code-generator (MIT), C port:
//! c/qrcodegen.h, c/qrcodegen.c, and tests from c/qrcodegen-test.c.

const std = @import("std");
const types = @import("types.zig");
const Ecc = types.Ecc;

/// Smallest and largest version numbers of QR Code Model 2.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.h,
/// macros qrcodegen_VERSION_MIN and qrcodegen_VERSION_MAX.
pub const min_version: u8 = 1;
pub const max_version: u8 = 40;

/// Side length in modules of a symbol of the given version (no quiet zone).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.h, macro
/// qrcodegen_BUFFER_LEN_FOR_VERSION, which uses `n * 4 + 17` as the size.
pub fn symbolSize(version: u8) u8 {
    return version * 4 + 17;
}

/// Number of bytes needed to hold the module matrix of the given version,
/// one byte per module.
pub fn moduleCount(version: u8) usize {
    const size: usize = symbolSize(version);
    return size * size;
}

/// Number of error correction codewords per block for each error correction level and version.
/// Indexed by [ecc_level][version], where version is 1..40 (index 0 is unused padding, set to 0).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, table ECC_CODEWORDS_PER_BLOCK.
pub const ecc_codewords_per_block: [4][41]u8 = [4][41]u8{
    // Low
    [_]u8{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    // Medium
    [_]u8{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    // Quartile
    [_]u8{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    // High
    [_]u8{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// Number of error correction blocks for each error correction level and version.
/// Indexed by [ecc_level][version], where version is 1..40 (index 0 is unused padding, set to 0).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, table NUM_ERROR_CORRECTION_BLOCKS.
pub const num_error_correction_blocks: [4][41]u8 = [4][41]u8{
    // Low
    [_]u8{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    // Medium
    [_]u8{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    // Quartile
    [_]u8{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    // High
    [_]u8{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// Returns the number of raw data modules (bits) for a given QR version after excluding
/// all function modules (finder patterns, timing patterns, alignment patterns, version blocks).
/// Range: [208, 29648].
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function getNumRawDataModules.
pub fn getNumRawDataModules(version: u8) u16 {
    std.debug.assert(version >= min_version and version <= max_version);
    const ver: u32 = version;
    var result: u32 = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
        const num_align: u32 = ver / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (ver >= 7) {
            result -= 36;
        }
    }
    std.debug.assert(result >= 208 and result <= 29648);
    return @intCast(result);
}

/// Returns the number of 8-bit codewords available for data (excluding ECC codewords).
/// Range: [9, 2956].
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function getNumDataCodewords.
pub fn getNumDataCodewords(version: u8, ecl: Ecc) u16 {
    std.debug.assert(version >= min_version and version <= max_version);
    const e: usize = @intCast(@backingInt(ecl));
    const v: usize = version;
    const raw_codewords: u16 = getNumRawDataModules(version) / 8;
    const ecc_per_block: u16 = ecc_codewords_per_block[e][v];
    const num_blocks: u16 = num_error_correction_blocks[e][v];
    const total_ecc_codewords: u16 = ecc_per_block * num_blocks;
    std.debug.assert(raw_codewords >= total_ecc_codewords);
    return raw_codewords - total_ecc_codewords;
}

/// Alignment pattern coordinates result slice / array. Maximum 7 alignment coordinates.
pub const AlignmentPositions = struct {
    coords: [7]u8,
    len: u8,

    pub fn slice(self: *const AlignmentPositions) []const u8 {
        return self.coords[0..self.len];
    }
};

/// Calculates the center coordinates for the alignment patterns of the given version.
/// Returns an AlignmentPositions struct with the coordinates and count (0 for version 1, up to 7 for version 40).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function getAlignmentPatternPositions.
pub fn getAlignmentPatternPositions(version: u8) AlignmentPositions {
    std.debug.assert(version >= min_version and version <= max_version);
    var res: AlignmentPositions = .{
        .coords = @splat(0),
        .len = 0,
    };
    if (version == 1) return res;

    const num_align: u8 = version / 7 + 2;
    res.len = num_align;
    const v: u32 = version;
    const na: u32 = num_align;
    const step: u32 = (v * 8 + na * 3 + 5) / (na * 4 - 4) * 2;

    var pos: i32 = @intCast(v * 4 + 10);
    var i: usize = num_align - 1;
    while (i >= 1) : (i -= 1) {
        res.coords[i] = @intCast(pos);
        pos -= @intCast(step);
    }
    res.coords[0] = 6;
    return res;
}

// ---- Unit Tests ----

const testing = std.testing;

test "symbolSize matches size == 21 + 4 * (version - 1)" {
    var v: u8 = min_version;
    while (v <= max_version) : (v += 1) {
        try testing.expectEqual(@as(u8, 21) + 4 * (v - 1), symbolSize(v));
    }
    try testing.expectEqual(@as(u8, 21), symbolSize(1));
    try testing.expectEqual(@as(u8, 177), symbolSize(40));
}

test "moduleCount" {
    try testing.expectEqual(@as(usize, 441), moduleCount(1));
    try testing.expectEqual(@as(usize, 31329), moduleCount(40));
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testGetNumRawDataModules.
test "getNumRawDataModules against reference cases" {
    const Case = struct { version: u8, expected: u16 };
    const cases = [_]Case{
        .{ .version = 1, .expected = 208 },
        .{ .version = 2, .expected = 359 },
        .{ .version = 3, .expected = 567 },
        .{ .version = 6, .expected = 1383 },
        .{ .version = 7, .expected = 1568 },
        .{ .version = 12, .expected = 3728 },
        .{ .version = 15, .expected = 5243 },
        .{ .version = 18, .expected = 7211 },
        .{ .version = 22, .expected = 10068 },
        .{ .version = 26, .expected = 13652 },
        .{ .version = 32, .expected = 19723 },
        .{ .version = 37, .expected = 25568 },
        .{ .version = 40, .expected = 29648 },
    };

    for (cases) |c| {
        try testing.expectEqual(c.expected, getNumRawDataModules(c.version));
    }
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testGetNumDataCodewords.
test "getNumDataCodewords against reference cases" {
    const Case = struct { version: u8, ecl: Ecc, expected: u16 };
    const cases = [_]Case{
        .{ .version = 3, .ecl = .medium, .expected = 44 },
        .{ .version = 3, .ecl = .quartile, .expected = 34 },
        .{ .version = 3, .ecl = .high, .expected = 26 },
        .{ .version = 6, .ecl = .low, .expected = 136 },
        .{ .version = 7, .ecl = .low, .expected = 156 },
        .{ .version = 9, .ecl = .low, .expected = 232 },
        .{ .version = 9, .ecl = .medium, .expected = 182 },
        .{ .version = 12, .ecl = .high, .expected = 158 },
        .{ .version = 15, .ecl = .low, .expected = 523 },
        .{ .version = 16, .ecl = .quartile, .expected = 325 },
        .{ .version = 19, .ecl = .high, .expected = 341 },
        .{ .version = 21, .ecl = .low, .expected = 932 },
        .{ .version = 22, .ecl = .low, .expected = 1006 },
        .{ .version = 22, .ecl = .medium, .expected = 782 },
        .{ .version = 22, .ecl = .high, .expected = 442 },
        .{ .version = 24, .ecl = .low, .expected = 1174 },
        .{ .version = 24, .ecl = .high, .expected = 514 },
        .{ .version = 28, .ecl = .low, .expected = 1531 },
        .{ .version = 30, .ecl = .high, .expected = 745 },
        .{ .version = 32, .ecl = .high, .expected = 845 },
        .{ .version = 33, .ecl = .low, .expected = 2071 },
        .{ .version = 33, .ecl = .high, .expected = 901 },
        .{ .version = 35, .ecl = .low, .expected = 2306 },
        .{ .version = 35, .ecl = .medium, .expected = 1812 },
        .{ .version = 35, .ecl = .quartile, .expected = 1286 },
        .{ .version = 36, .ecl = .high, .expected = 1054 },
        .{ .version = 37, .ecl = .high, .expected = 1096 },
        .{ .version = 39, .ecl = .medium, .expected = 2216 },
        .{ .version = 40, .ecl = .medium, .expected = 2334 },
    };

    for (cases) |c| {
        try testing.expectEqual(c.expected, getNumDataCodewords(c.version, c.ecl));
    }
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testGetAlignmentPatternPositions.
test "getAlignmentPatternPositions against reference cases" {
    const Case = struct {
        version: u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .version = 1, .expected = &[_]u8{} },
        .{ .version = 2, .expected = &[_]u8{ 6, 18 } },
        .{ .version = 3, .expected = &[_]u8{ 6, 22 } },
        .{ .version = 6, .expected = &[_]u8{ 6, 34 } },
        .{ .version = 7, .expected = &[_]u8{ 6, 22, 38 } },
        .{ .version = 8, .expected = &[_]u8{ 6, 24, 42 } },
        .{ .version = 16, .expected = &[_]u8{ 6, 26, 50, 74 } },
        .{ .version = 25, .expected = &[_]u8{ 6, 32, 58, 84, 110 } },
        .{ .version = 32, .expected = &[_]u8{ 6, 34, 60, 86, 112, 138 } },
        .{ .version = 33, .expected = &[_]u8{ 6, 30, 58, 86, 114, 142 } },
        .{ .version = 39, .expected = &[_]u8{ 6, 26, 54, 82, 110, 138, 166 } },
        .{ .version = 40, .expected = &[_]u8{ 6, 30, 58, 86, 114, 142, 170 } },
    };

    for (cases) |c| {
        const align_pos = getAlignmentPatternPositions(c.version);
        try testing.expectEqualSlices(u8, c.expected, align_pos.slice());
    }
}

test "exhaustive invariant verification across all 40 versions and 4 ECC levels" {
    // 1. Invariants across all versions for ECC tables
    var v: u8 = min_version;
    while (v <= max_version) : (v += 1) {
        // Raw data modules is strictly increasing with version
        if (v > min_version) {
            try testing.expect(getNumRawDataModules(v) > getNumRawDataModules(v - 1));
        }

        // Alignment positions: count is 0 for v=1, and monotonically non-decreasing with v
        const align_pos = getAlignmentPatternPositions(v);
        if (v == 1) {
            try testing.expectEqual(@as(u8, 0), align_pos.len);
        } else {
            const prev_align = getAlignmentPatternPositions(v - 1);
            try testing.expect(align_pos.len >= prev_align.len);
            // Alignment coordinates must be strictly increasing and within symbol bounds
            const size = symbolSize(v);
            var prev_coord: u8 = 0;
            for (align_pos.slice()) |coord| {
                try testing.expect(coord > prev_coord);
                try testing.expect(coord < size);
                prev_coord = coord;
            }
        }

        // ECC codewords per block and num blocks must be strictly positive for all 4 ECC levels
        for ([_]Ecc{ .low, .medium, .quartile, .high }) |ecl| {
            const e: usize = @intCast(@backingInt(ecl));
            try testing.expect(ecc_codewords_per_block[e][v] > 0);
            try testing.expect(num_error_correction_blocks[e][v] > 0);
        }

        // Data codewords: Low error correction always allows >= High error correction codewords
        try testing.expect(getNumDataCodewords(v, .low) >= getNumDataCodewords(v, .medium));
        try testing.expect(getNumDataCodewords(v, .medium) >= getNumDataCodewords(v, .quartile));
        try testing.expect(getNumDataCodewords(v, .quartile) >= getNumDataCodewords(v, .high));

        // Data codewords must be strictly positive and strictly less than total raw codewords
        const raw_cw = getNumRawDataModules(v) / 8;
        try testing.expect(getNumDataCodewords(v, .high) > 0);
        try testing.expect(getNumDataCodewords(v, .low) < raw_cw);
    }

    // 2. Data codewords strictly increasing with version for each fixed ECC level
    for ([_]Ecc{ .low, .medium, .quartile, .high }) |ecl| {
        var prev_cw: u16 = 0;
        v = min_version;
        while (v <= max_version) : (v += 1) {
            const cw = getNumDataCodewords(v, ecl);
            try testing.expect(cw > prev_cw);
            prev_cw = cw;
        }
    }
}
