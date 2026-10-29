//! BCH code decoder for QR Code Model 2 Format Information and Version Information.
//!
//! Implementation based on bounded-distance nearest Hamming distance (t <= 3),
//! matching zxing-cpp (core/src/qrcode/decoder/QRFormatInformation.cpp and QRVersion.cpp).
//!
//! All lookup tables are derived at comptime directly from matrix.computeFormatBits
//! and matrix.computeVersionBits to ensure a single source of truth with the encoder.

const std = @import("std");
const types = @import("../types.zig");
const tables = @import("../tables.zig");
const matrix = @import("../matrix.zig");

pub const Ecc = types.Ecc;

pub const FormatResult = struct {
    ecc: Ecc,
    mask: u3,
    errors_corrected: u8,
    copy_used: u8, // 1 or 2
};

pub const VersionResult = struct {
    version: u8,
    errors_corrected: u8,
    copy_used: u8, // 1 or 2
};

pub const BchError = error{
    FormatBitsUncorrectable,
    VersionBitsUncorrectable,
    InvalidMatrixSize,
};

pub const FormatEntry = struct {
    bits: u15,
    ecc: Ecc,
    mask: u3,
};

pub const VersionEntry = struct {
    bits: u18,
    version: u8,
};

/// 32 valid 15-bit format information codewords derived at comptime from matrix.computeFormatBits.
/// Source: ISO/IEC 18004:2015 Section 7.4.9.
pub const FORMAT_TABLE: [32]FormatEntry = blk: {
    var entries: [32]FormatEntry = undefined;
    var idx: usize = 0;
    const ecc_levels = [_]Ecc{ .low, .medium, .quartile, .high };
    for (ecc_levels) |ecl| {
        var m: u3 = 0;
        while (true) : (m += 1) {
            entries[idx] = .{
                .bits = matrix.computeFormatBits(ecl, m),
                .ecc = ecl,
                .mask = m,
            };
            idx += 1;
            if (m == 7) break;
        }
    }
    break :blk entries;
};

/// 34 valid 18-bit version information codewords (versions 7..40) derived at comptime from matrix.computeVersionBits.
/// Source: ISO/IEC 18004:2015 Section 7.4.10 and Annex D.
pub const VERSION_TABLE: [34]VersionEntry = blk: {
    var entries: [34]VersionEntry = undefined;
    var v: u8 = 7;
    while (v <= 40) : (v += 1) {
        entries[v - 7] = .{
            .bits = matrix.computeVersionBits(v),
            .version = v,
        };
    }
    break :blk entries;
};

/// Decodes a raw 15-bit format codeword by finding the nearest valid codeword within Hamming distance t <= 3.
/// Source: zxing-cpp, QRFormatInformation.cpp, DecodeFormatInformation.
pub fn decodeFormatBits(raw15: u15) BchError!struct { ecc: Ecc, mask: u3, errors: u8 } {
    var best_dist: u8 = 255;
    var best_idx: ?usize = null;

    for (FORMAT_TABLE, 0..) |entry, i| {
        const dist: u8 = @intCast(@popCount(raw15 ^ entry.bits));
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = i;
            if (dist == 0) break;
        }
    }

    if (best_dist <= 3 and best_idx != null) {
        const winner = FORMAT_TABLE[best_idx.?];
        return .{
            .ecc = winner.ecc,
            .mask = winner.mask,
            .errors = best_dist,
        };
    }

    return error.FormatBitsUncorrectable;
}

/// Decodes a raw 18-bit version codeword by finding the nearest valid codeword within Hamming distance t <= 3.
/// Source: zxing-cpp, QRVersion.cpp, DecodeVersionInformation.
pub fn decodeVersionBits(raw18: u18) BchError!struct { version: u8, errors: u8 } {
    var best_dist: u8 = 255;
    var best_idx: ?usize = null;

    for (VERSION_TABLE, 0..) |entry, i| {
        const dist: u8 = @intCast(@popCount(raw18 ^ entry.bits));
        if (dist < best_dist) {
            best_dist = dist;
            best_idx = i;
            if (dist == 0) break;
        }
    }

    if (best_dist <= 3 and best_idx != null) {
        const winner = VERSION_TABLE[best_idx.?];
        return .{
            .version = winner.version,
            .errors = best_dist,
        };
    }

    return error.VersionBitsUncorrectable;
}

/// Extracts a single bit (0 or 1) from the module matrix at (x, y).
inline fn getModuleBit(modules: []const u8, size: usize, x: usize, y: usize) u1 {
    return @intCast(modules[y * size + x] & 1);
}

/// Reads the 15-bit format information Copy 1 from around the top-left finder pattern.
/// Coordinates match matrix.drawFormatBits and quirc/lib/decode.c function read_format(code, data, 0).
pub fn readFormatCopy1(modules: []const u8, size: u8) u15 {
    const s: usize = size;
    var bits: u15 = 0;

    // bit 0..5: (8, 0..5)
    var bit_idx: u4 = 0;
    while (bit_idx <= 5) : (bit_idx += 1) {
        bits |= @as(u15, getModuleBit(modules, s, 8, bit_idx)) << bit_idx;
    }
    // bit 6: (8, 7)
    bits |= @as(u15, getModuleBit(modules, s, 8, 7)) << 6;
    // bit 7: (8, 8)
    bits |= @as(u15, getModuleBit(modules, s, 8, 8)) << 7;
    // bit 8: (7, 8)
    bits |= @as(u15, getModuleBit(modules, s, 7, 8)) << 8;
    // bit 9..14: (14 - bit_idx, 8)
    bit_idx = 9;
    while (bit_idx < 15) : (bit_idx += 1) {
        const x = 14 - @as(usize, bit_idx);
        bits |= @as(u15, getModuleBit(modules, s, x, 8)) << bit_idx;
    }

    return bits;
}

/// Reads the 15-bit format information Copy 2 from bottom-left and top-right finder patterns.
/// Coordinates match matrix.drawFormatBits and quirc/lib/decode.c function read_format(code, data, 1).
pub fn readFormatCopy2(modules: []const u8, size: u8) u15 {
    const s: usize = size;
    var bits: u15 = 0;

    // bit 0..7: (size - 1 - bit_idx, 8)
    var bit_idx: u4 = 0;
    while (bit_idx < 8) : (bit_idx += 1) {
        const x = s - 1 - @as(usize, bit_idx);
        bits |= @as(u15, getModuleBit(modules, s, x, 8)) << bit_idx;
    }
    // bit 8..14: (8, size - 15 + bit_idx)
    bit_idx = 8;
    while (bit_idx < 15) : (bit_idx += 1) {
        const y = s - 15 + @as(usize, bit_idx);
        bits |= @as(u15, getModuleBit(modules, s, 8, y)) << bit_idx;
    }

    return bits;
}

/// Reads format information from the matrix, testing both redundant copies.
/// Tie-breaking:
///   1. Lower Hamming distance wins.
///   2. If tied in distance and both <= 3, Copy 1 wins (primary ISO 18004 position).
///   3. If neither <= 3, returns error.FormatBitsUncorrectable.
pub fn readFormat(modules: []const u8, size: u8) BchError!FormatResult {
    const raw1 = readFormatCopy1(modules, size);
    const raw2 = readFormatCopy2(modules, size);

    const c1 = decodeFormatBits(raw1) catch null;
    const c2 = decodeFormatBits(raw2) catch null;

    if (c1) |val1| {
        if (c2) |val2| {
            if (val2.errors < val1.errors) {
                return .{ .ecc = val2.ecc, .mask = val2.mask, .errors_corrected = val2.errors, .copy_used = 2 };
            }
            return .{ .ecc = val1.ecc, .mask = val1.mask, .errors_corrected = val1.errors, .copy_used = 1 };
        } else {
            return .{ .ecc = val1.ecc, .mask = val1.mask, .errors_corrected = val1.errors, .copy_used = 1 };
        }
    } else {
        if (c2) |val2| {
            return .{ .ecc = val2.ecc, .mask = val2.mask, .errors_corrected = val2.errors, .copy_used = 2 };
        }
    }

    return error.FormatBitsUncorrectable;
}

/// Reads the 18-bit version information Copy 1 from the top-right block (rows 0..5, columns size - 11 .. size - 9).
/// Matches quirc/lib/decode.c function read_version(code, data, 0).
pub fn readVersionCopy1(modules: []const u8, size: u8) u18 {
    const s: usize = size;
    var bits: u18 = 0;
    var bit_idx: u5 = 0;

    var row: usize = 0;
    while (row < 6) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const x = s - 11 + col;
            const b = getModuleBit(modules, s, x, row);
            bits |= @as(u18, b) << bit_idx;
            bit_idx += 1;
        }
    }

    return bits;
}

/// Reads the 18-bit version information Copy 2 from the bottom-left block (columns 0..5, rows size - 11 .. size - 9).
/// Matches quirc/lib/decode.c function read_version(code, data, 1).
pub fn readVersionCopy2(modules: []const u8, size: u8) u18 {
    const s: usize = size;
    var bits: u18 = 0;
    var bit_idx: u5 = 0;

    var row: usize = 0;
    while (row < 6) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const y = s - 11 + col;
            const b = getModuleBit(modules, s, row, y);
            bits |= @as(u18, b) << bit_idx;
            bit_idx += 1;
        }
    }

    return bits;
}

/// Validates matrix size and recovers the QR Code version.
/// - If size corresponds to version 1..6 (21..41), version is computed directly as (size - 17) / 4.
/// - If size corresponds to version 7..40 (45..177), reads both 18-bit BCH blocks and validates consistency.
pub fn readVersion(modules: []const u8, size: u8) BchError!VersionResult {
    // 1. Check size bounds: must be (17 + 4*V) for V in 1..40 -> 21 <= size <= 177 and (size - 17) % 4 == 0.
    if (size < 21 or size > 177 or (size - 17) % 4 != 0) {
        return error.InvalidMatrixSize;
    }
    const computed_v: u8 = (size - 17) / 4;

    // Versions 1..6 do not have version information blocks
    if (computed_v < 7) {
        return .{
            .version = computed_v,
            .errors_corrected = 0,
            .copy_used = 1,
        };
    }

    // Versions 7..40: read both redundant 18-bit blocks
    const raw1 = readVersionCopy1(modules, size);
    const raw2 = readVersionCopy2(modules, size);

    const c1 = decodeVersionBits(raw1) catch null;
    const c2 = decodeVersionBits(raw2) catch null;

    var chosen_v: u8 = 0;
    var chosen_errs: u8 = 0;
    var chosen_copy: u8 = 1;

    if (c1) |val1| {
        if (c2) |val2| {
            if (val2.errors < val1.errors) {
                chosen_v = val2.version;
                chosen_errs = val2.errors;
                chosen_copy = 2;
            } else {
                chosen_v = val1.version;
                chosen_errs = val1.errors;
                chosen_copy = 1;
            }
        } else {
            chosen_v = val1.version;
            chosen_errs = val1.errors;
            chosen_copy = 1;
        }
    } else {
        if (c2) |val2| {
            chosen_v = val2.version;
            chosen_errs = val2.errors;
            chosen_copy = 2;
        } else {
            return error.VersionBitsUncorrectable;
        }
    }

    // Decoded version must match the matrix size
    if (chosen_v != computed_v) {
        return error.VersionBitsUncorrectable;
    }

    return .{
        .version = chosen_v,
        .errors_corrected = chosen_errs,
        .copy_used = chosen_copy,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "BCH: format table derived at comptime from matrix.computeFormatBits" {
    // Verify that every entry in FORMAT_TABLE matches matrix.computeFormatBits
    try testing.expectEqual(@as(usize, 32), FORMAT_TABLE.len);

    for (FORMAT_TABLE) |entry| {
        const expected = matrix.computeFormatBits(entry.ecc, entry.mask);
        try testing.expectEqual(expected, entry.bits);
    }
}

test "BCH: version table derived at comptime from matrix.computeVersionBits" {
    try testing.expectEqual(@as(usize, 34), VERSION_TABLE.len);

    for (VERSION_TABLE) |entry| {
        const expected = matrix.computeVersionBits(entry.version);
        try testing.expectEqual(expected, entry.bits);
    }
}

test "decodeFormatBits: clean codewords and 1, 2, 3 deterministic bit flips" {
    for (FORMAT_TABLE) |entry| {
        // 0 errors
        const r0 = try decodeFormatBits(entry.bits);
        try testing.expectEqual(entry.ecc, r0.ecc);
        try testing.expectEqual(entry.mask, r0.mask);
        try testing.expectEqual(@as(u8, 0), r0.errors);

        // 1 bit flip (flip bit 3)
        const r1 = try decodeFormatBits(entry.bits ^ (1 << 3));
        try testing.expectEqual(entry.ecc, r1.ecc);
        try testing.expectEqual(entry.mask, r1.mask);
        try testing.expectEqual(@as(u8, 1), r1.errors);

        // 2 bit flips (flip bits 1 and 10)
        const r2 = try decodeFormatBits(entry.bits ^ (1 << 1) ^ (1 << 10));
        try testing.expectEqual(entry.ecc, r2.ecc);
        try testing.expectEqual(entry.mask, r2.mask);
        try testing.expectEqual(@as(u8, 2), r2.errors);

        // 3 bit flips (flip bits 0, 7, 14)
        const r3 = try decodeFormatBits(entry.bits ^ (1 << 0) ^ (1 << 7) ^ (1 << 14));
        try testing.expectEqual(entry.ecc, r3.ecc);
        try testing.expectEqual(entry.mask, r3.mask);
        try testing.expectEqual(@as(u8, 3), r3.errors);
    }
}

test "decodeFormatBits: fails with FormatBitsUncorrectable on 4 bit flips" {
    // Fixed pattern: 4 bit flips on codeword 0
    const clean = FORMAT_TABLE[0].bits;
    const corrupted_4 = clean ^ (1 << 0) ^ (1 << 2) ^ (1 << 4) ^ (1 << 6);
    try testing.expectError(error.FormatBitsUncorrectable, decodeFormatBits(corrupted_4));
}

test "decodeVersionBits: clean and 1, 2, 3 deterministic bit flips" {
    for (VERSION_TABLE) |entry| {
        // 0 errors
        const r0 = try decodeVersionBits(entry.bits);
        try testing.expectEqual(entry.version, r0.version);
        try testing.expectEqual(@as(u8, 0), r0.errors);

        // 1 bit flip
        const r1 = try decodeVersionBits(entry.bits ^ (1 << 5));
        try testing.expectEqual(entry.version, r1.version);
        try testing.expectEqual(@as(u8, 1), r1.errors);

        // 2 bit flips
        const r2 = try decodeVersionBits(entry.bits ^ (1 << 2) ^ (1 << 12));
        try testing.expectEqual(entry.version, r2.version);
        try testing.expectEqual(@as(u8, 2), r2.errors);

        // 3 bit flips
        const r3 = try decodeVersionBits(entry.bits ^ (1 << 0) ^ (1 << 8) ^ (1 << 17));
        try testing.expectEqual(entry.version, r3.version);
        try testing.expectEqual(@as(u8, 3), r3.errors);
    }
}

test "decodeVersionBits: fails with VersionBitsUncorrectable on 4 bit flips" {
    const clean = VERSION_TABLE[0].bits;
    const corrupted_4 = clean ^ (1 << 1) ^ (1 << 3) ^ (1 << 5) ^ (1 << 7);
    try testing.expectError(error.VersionBitsUncorrectable, decodeVersionBits(corrupted_4));
}

test "readFormat: matrix bit corruption and fallback between copies" {
    const v: u8 = 1;
    const size = tables.symbolSize(v);
    var modules: [tables.moduleCount(tables.max_version)]u8 = undefined;

    // Draw clean function modules with High ECC and mask 5
    matrix.initializeFunctionModules(&modules, v, .high);
    matrix.drawFormatBits(&modules, v, .high, 5);

    // 1. Clean matrix
    var res = try readFormat(&modules, size);
    try testing.expectEqual(Ecc.high, res.ecc);
    try testing.expectEqual(@as(u3, 5), res.mask);
    try testing.expectEqual(@as(u8, 0), res.errors_corrected);
    try testing.expectEqual(@as(u8, 1), res.copy_used);

    // 2. Corrupt Copy 1 with 2 bit flips at (8, 0) and (8, 1)
    const s: usize = size;
    modules[0 * s + 8] ^= 1;
    modules[1 * s + 8] ^= 1;

    // Copy 2 is still clean -> Copy 2 should win with 0 errors
    res = try readFormat(&modules, size);
    try testing.expectEqual(Ecc.high, res.ecc);
    try testing.expectEqual(@as(u3, 5), res.mask);
    try testing.expectEqual(@as(u8, 0), res.errors_corrected);
    try testing.expectEqual(@as(u8, 2), res.copy_used);

    // 3. Destroy Copy 2 with 5 bit flips at (size - 1 .. size - 5, 8)
    for (0..5) |i| {
        modules[8 * s + (s - 1 - i)] ^= 1;
    }

    // Now Copy 1 has 2 errors, Copy 2 is destroyed (>3 errors) -> Copy 1 should recover
    res = try readFormat(&modules, size);
    try testing.expectEqual(Ecc.high, res.ecc);
    try testing.expectEqual(@as(u3, 5), res.mask);
    try testing.expectEqual(@as(u8, 2), res.errors_corrected);
    try testing.expectEqual(@as(u8, 1), res.copy_used);

    // 4. Destroy Copy 1 as well (add 3 more errors to Copy 1 -> total 5)
    modules[2 * s + 8] ^= 1;
    modules[3 * s + 8] ^= 1;
    modules[4 * s + 8] ^= 1;

    // Both copies destroyed -> must fail
    try testing.expectError(error.FormatBitsUncorrectable, readFormat(&modules, size));
}

test "readVersion: matrix bit corruption, sizes, and fallback" {
    // 1. Invalid sizes
    try testing.expectError(error.InvalidMatrixSize, readVersion(&[_]u8{}, 20));
    try testing.expectError(error.InvalidMatrixSize, readVersion(&[_]u8{}, 22));
    try testing.expectError(error.InvalidMatrixSize, readVersion(&[_]u8{}, 178));

    // 2. Version 1 (size 21) -> returns version 1 with 0 errors
    const v1_res = try readVersion(&[_]u8{}, 21);
    try testing.expectEqual(@as(u8, 1), v1_res.version);
    try testing.expectEqual(@as(u8, 0), v1_res.errors_corrected);

    // 3. Version 7 (size 45) -> has version blocks
    const v: u8 = 7;
    const size = tables.symbolSize(v);
    var modules: [tables.moduleCount(tables.max_version)]u8 = undefined;

    matrix.initializeFunctionModules(&modules, v, .medium);

    var res = try readVersion(&modules, size);
    try testing.expectEqual(@as(u8, 7), res.version);
    try testing.expectEqual(@as(u8, 0), res.errors_corrected);
    try testing.expectEqual(@as(u8, 1), res.copy_used);

    // Corrupt Copy 1 with 2 bit flips in top-right block (x = size - 11, y = 0 and y = 1)
    const s: usize = size;
    modules[0 * s + (s - 11)] ^= 1;
    modules[1 * s + (s - 11)] ^= 1;

    // Copy 2 (bottom-left) is clean -> Copy 2 wins
    res = try readVersion(&modules, size);
    try testing.expectEqual(@as(u8, 7), res.version);
    try testing.expectEqual(@as(u8, 0), res.errors_corrected);
    try testing.expectEqual(@as(u8, 2), res.copy_used);

    // Destroy Copy 2 with 5 bit flips (y = size - 11, x = 0..4)
    for (0..5) |i| {
        modules[(s - 11) * s + i] ^= 1;
    }

    // Now Copy 1 has 2 errors, Copy 2 is destroyed -> Copy 1 recovers
    res = try readVersion(&modules, size);
    try testing.expectEqual(@as(u8, 7), res.version);
    try testing.expectEqual(@as(u8, 2), res.errors_corrected);
    try testing.expectEqual(@as(u8, 1), res.copy_used);

    // Corrupt Copy 1 with 3 more flips -> both copies destroyed
    modules[2 * s + (s - 11)] ^= 1;
    modules[3 * s + (s - 11)] ^= 1;
    modules[4 * s + (s - 11)] ^= 1;

    try testing.expectError(error.VersionBitsUncorrectable, readVersion(&modules, size));
}
