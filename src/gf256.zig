//! Galois Field GF(2^8/0x11D) arithmetic and Reed-Solomon Error Correction Code generation.
//!
//! Every numeric value and algorithm in this file cites its source.
//! The primary reference is nayuki/QR-Code-generator (MIT), C port:
//! c/qrcodegen.c (functions reedSolomonMultiply, reedSolomonComputeDivisor,
//! reedSolomonComputeRemainder) and tests from c/qrcodegen-test.c.

const std = @import("std");

/// Maximum Reed-Solomon polynomial degree across all QR Code Model 2 versions and levels.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, macro qrcodegen_REED_SOLOMON_DEGREE_MAX.
pub const max_degree: usize = 30;

/// Multiplication of two field elements in GF(2^8 / 0x11D) using Russian peasant multiplication.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function reedSolomonMultiply.
pub fn multiply(x: u8, y: u8) u8 {
    var z: u8 = 0;
    var i: i32 = 7;
    while (i >= 0) : (i -= 1) {
        const top_bit = (z >> 7);
        // z << 1 intentionally discards bit 7; the top_bit *% 0x1D term restores the irreducible poly mod.
        z = (z << 1) ^ (top_bit *% 0x1D); // (top_bit * 0x11D) & 0xFF == top_bit * 0x1D
        const y_bit = ((y >> @intCast(i)) & 1);
        z ^= y_bit *% x;
    }
    return z;
}

/// Computes a Reed-Solomon ECC generator polynomial of degree `degree`.
/// The leading coefficient (x^degree) is implicitly 1 and omitted.
/// Precondition: `result.len` must equal `degree`, where `1 <= result.len <= max_degree` (30).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function reedSolomonComputeDivisor.
pub fn computeDivisor(result: []u8) void {
    const degree = result.len;
    std.debug.assert(degree >= 1 and degree <= max_degree);

    @memset(result, 0);
    result[degree - 1] = 1; // Start with monomial x^0

    var root: u8 = 1;
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = 0;
        while (j < degree) : (j += 1) {
            result[j] = multiply(result[j], root);
            if (j + 1 < degree) {
                result[j] ^= result[j + 1];
            }
        }
        root = multiply(root, 0x02);
    }
}

/// Computes the Reed-Solomon error correction remainder (syndromes/checksum) for `data`
/// using the generator polynomial `generator` of degree `generator.len`.
/// Preconditions: `1 <= generator.len <= max_degree` (30) and `result.len == generator.len`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function reedSolomonComputeRemainder.
pub fn computeRemainder(data: []const u8, generator: []const u8, result: []u8) void {
    const degree = generator.len;
    std.debug.assert(degree >= 1 and degree <= max_degree);
    std.debug.assert(result.len == degree);

    @memset(result, 0);
    for (data) |b| {
        const factor = b ^ result[0];
        // Shift remainder polynomial left by 1 term
        if (degree > 1) {
            std.mem.copyForwards(u8, result[0 .. degree - 1], result[1..degree]);
        }
        result[degree - 1] = 0;
        // Add generator multiplied by factor
        for (generator, 0..) |g, j| {
            result[j] ^= multiply(g, factor);
        }
    }
}

// ---- Unit Tests ----

const testing = std.testing;

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testReedSolomonMultiply.
test "reedSolomonMultiply against reference cases" {
    const Case = struct { x: u8, y: u8, expected: u8 };
    const cases = [_]Case{
        .{ .x = 0x00, .y = 0x00, .expected = 0x00 },
        .{ .x = 0x01, .y = 0x01, .expected = 0x01 },
        .{ .x = 0x02, .y = 0x02, .expected = 0x04 },
        .{ .x = 0x00, .y = 0x6E, .expected = 0x00 },
        .{ .x = 0xB2, .y = 0xDD, .expected = 0xE6 },
        .{ .x = 0x41, .y = 0x11, .expected = 0x25 },
        .{ .x = 0xB0, .y = 0x1F, .expected = 0x11 },
        .{ .x = 0x05, .y = 0x75, .expected = 0xBC },
        .{ .x = 0x52, .y = 0xB5, .expected = 0xAE },
        .{ .x = 0xA8, .y = 0x20, .expected = 0xA4 },
        .{ .x = 0x0E, .y = 0x44, .expected = 0x9F },
        .{ .x = 0xD4, .y = 0x13, .expected = 0xA0 },
        .{ .x = 0x31, .y = 0x10, .expected = 0x37 },
        .{ .x = 0x6C, .y = 0x58, .expected = 0xCB },
        .{ .x = 0xB6, .y = 0x75, .expected = 0x3E },
        .{ .x = 0xFF, .y = 0xFF, .expected = 0xE2 },
    };

    for (cases) |c| {
        try testing.expectEqual(c.expected, multiply(c.x, c.y));
    }
}

// Field arithmetic properties test
test "GF(256) basic algebraic properties" {
    // 0 * x = 0, 1 * x = x
    var a: u16 = 0;
    while (a <= 255) : (a += 1) {
        const x: u8 = @intCast(a);
        try testing.expectEqual(@as(u8, 0), multiply(0, x));
        try testing.expectEqual(x, multiply(1, x));
        try testing.expectEqual(multiply(x, 2), multiply(2, x)); // Commutativity
    }
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testReedSolomonComputeDivisor.
test "reedSolomonComputeDivisor against reference cases" {
    var gen30: [30]u8 = undefined;

    computeDivisor(gen30[0..1]);
    try testing.expectEqual(@as(u8, 0x01), gen30[0]);

    computeDivisor(gen30[0..2]);
    try testing.expectEqual(@as(u8, 0x03), gen30[0]);
    try testing.expectEqual(@as(u8, 0x02), gen30[1]);

    computeDivisor(gen30[0..5]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1F, 0xC6, 0x3F, 0x93, 0x74 }, gen30[0..5]);

    computeDivisor(gen30[0..30]);
    try testing.expectEqual(@as(u8, 0xD4), gen30[0]);
    try testing.expectEqual(@as(u8, 0xF6), gen30[1]);
    try testing.expectEqual(@as(u8, 0xC0), gen30[5]);
    try testing.expectEqual(@as(u8, 0x16), gen30[12]);
    try testing.expectEqual(@as(u8, 0xD9), gen30[13]);
    try testing.expectEqual(@as(u8, 0x12), gen30[20]);
    try testing.expectEqual(@as(u8, 0x6A), gen30[27]);
    try testing.expectEqual(@as(u8, 0x96), gen30[29]);
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testReedSolomonComputeRemainder.
test "reedSolomonComputeRemainder against reference cases" {
    // Case 1: empty data
    {
        var gen: [3]u8 = undefined;
        computeDivisor(&gen);
        var rem: [3]u8 = undefined;
        computeRemainder(&[_]u8{}, &gen, &rem);
        try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, &rem);
    }

    // Case 2: data = {0, 1}
    {
        const data = [_]u8{ 0, 1 };
        var gen: [4]u8 = undefined;
        computeDivisor(&gen);
        var rem: [4]u8 = undefined;
        computeRemainder(&data, &gen, &rem);
        try testing.expectEqualSlices(u8, &gen, &rem);
    }

    // Case 3: 5 data bytes with degree 5 generator
    {
        const data = [_]u8{ 0x03, 0x3A, 0x60, 0x12, 0xC7 };
        var gen: [5]u8 = undefined;
        computeDivisor(&gen);
        var rem: [5]u8 = undefined;
        computeRemainder(&data, &gen, &rem);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xCB, 0x36, 0x16, 0xFA, 0x9D }, &rem);
    }

    // Case 4: 43 data bytes with degree 30 generator
    {
        const data = [_]u8{
            0x38, 0x71, 0xDB, 0xF9, 0xD7, 0x28, 0xF6, 0x8E, 0xFE, 0x5E,
            0xE6, 0x7D, 0x7D, 0xB2, 0xA5, 0x58, 0xBC, 0x28, 0x23, 0x53,
            0x14, 0xD5, 0x61, 0xC0, 0x20, 0x6C, 0xDE, 0xDE, 0xFC, 0x79,
            0xB0, 0x8B, 0x78, 0x6B, 0x49, 0xD0, 0x1A, 0xAD, 0xF3, 0xEF,
            0x52, 0x7D, 0x9A,
        };
        var gen: [30]u8 = undefined;
        computeDivisor(&gen);
        var rem: [30]u8 = undefined;
        computeRemainder(&data, &gen, &rem);
        try testing.expectEqual(@as(u8, 0xCE), rem[0]);
        try testing.expectEqual(@as(u8, 0xF0), rem[1]);
        try testing.expectEqual(@as(u8, 0x31), rem[2]);
        try testing.expectEqual(@as(u8, 0xDE), rem[3]);
        try testing.expectEqual(@as(u8, 0xE1), rem[8]);
        try testing.expectEqual(@as(u8, 0xCA), rem[12]);
        try testing.expectEqual(@as(u8, 0xE3), rem[17]);
        try testing.expectEqual(@as(u8, 0x85), rem[19]);
        try testing.expectEqual(@as(u8, 0x50), rem[20]);
        try testing.expectEqual(@as(u8, 0xBE), rem[24]);
        try testing.expectEqual(@as(u8, 0xB3), rem[29]);
    }
}
