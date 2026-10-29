//! Reed-Solomon Error Correction Code decoder for QR Code Model 2.
//!
//! Implementation ported from quirc (MIT License):
//!   quirc/lib/decode.c:
//!     - gf256_exp, gf256_log
//!     - poly_add
//!     - poly_eval
//!     - berlekamp_massey
//!     - block_syndromes
//!     - eloc_poly
//!     - correct_block
//!
//! Copyright (C) 2010-2012 Daniel Beer <dlbeer@gmail.com>

const std = @import("std");

pub const MAX_POLY: usize = 64;

/// GF(2^8) exponential table for generator polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D),
/// base element alpha = 0x02.
/// Source: quirc/lib/decode.c, table gf256_exp.
pub const gf256_exp = [256]u8{
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x1d, 0x3a, 0x74, 0xe8, 0xcd, 0x87, 0x13, 0x26,
    0x4c, 0x98, 0x2d, 0x5a, 0xb4, 0x75, 0xea, 0xc9,
    0x8f, 0x03, 0x06, 0x0c, 0x18, 0x30, 0x60, 0xc0,
    0x9d, 0x27, 0x4e, 0x9c, 0x25, 0x4a, 0x94, 0x35,
    0x6a, 0xd4, 0xb5, 0x77, 0xee, 0xc1, 0x9f, 0x23,
    0x46, 0x8c, 0x05, 0x0a, 0x14, 0x28, 0x50, 0xa0,
    0x5d, 0xba, 0x69, 0xd2, 0xb9, 0x6f, 0xde, 0xa1,
    0x5f, 0xbe, 0x61, 0xc2, 0x99, 0x2f, 0x5e, 0xbc,
    0x65, 0xca, 0x89, 0x0f, 0x1e, 0x3c, 0x78, 0xf0,
    0xfd, 0xe7, 0xd3, 0xbb, 0x6b, 0xd6, 0xb1, 0x7f,
    0xfe, 0xe1, 0xdf, 0xa3, 0x5b, 0xb6, 0x71, 0xe2,
    0xd9, 0xaf, 0x43, 0x86, 0x11, 0x22, 0x44, 0x88,
    0x0d, 0x1a, 0x34, 0x68, 0xd0, 0xbd, 0x67, 0xce,
    0x81, 0x1f, 0x3e, 0x7c, 0xf8, 0xed, 0xc7, 0x93,
    0x3b, 0x76, 0xec, 0xc5, 0x97, 0x33, 0x66, 0xcc,
    0x85, 0x17, 0x2e, 0x5c, 0xb8, 0x6d, 0xda, 0xa9,
    0x4f, 0x9e, 0x21, 0x42, 0x84, 0x15, 0x2a, 0x54,
    0xa8, 0x4d, 0x9a, 0x29, 0x52, 0xa4, 0x55, 0xaa,
    0x49, 0x92, 0x39, 0x72, 0xe4, 0xd5, 0xb7, 0x73,
    0xe6, 0xd1, 0xbf, 0x63, 0xc6, 0x91, 0x3f, 0x7e,
    0xfc, 0xe5, 0xd7, 0xb3, 0x7b, 0xf6, 0xf1, 0xff,
    0xe3, 0xdb, 0xab, 0x4b, 0x96, 0x31, 0x62, 0xc4,
    0x95, 0x37, 0x6e, 0xdc, 0xa5, 0x57, 0xae, 0x41,
    0x82, 0x19, 0x32, 0x64, 0xc8, 0x8d, 0x07, 0x0e,
    0x1c, 0x38, 0x70, 0xe0, 0xdd, 0xa7, 0x53, 0xa6,
    0x51, 0xa2, 0x59, 0xb2, 0x79, 0xf2, 0xf9, 0xef,
    0xc3, 0x9b, 0x2b, 0x56, 0xac, 0x45, 0x8a, 0x09,
    0x12, 0x24, 0x48, 0x90, 0x3d, 0x7a, 0xf4, 0xf5,
    0xf7, 0xf3, 0xfb, 0xeb, 0xcb, 0x8b, 0x0b, 0x16,
    0x2c, 0x58, 0xb0, 0x7d, 0xfa, 0xe9, 0xcf, 0x83,
    0x1b, 0x36, 0x6c, 0xd8, 0xad, 0x47, 0x8e, 0x01,
};

/// GF(2^8) logarithm table for generator polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D).
/// Source: quirc/lib/decode.c, table gf256_log.
pub const gf256_log = [256]u8{
    0x00, 0xff, 0x01, 0x19, 0x02, 0x32, 0x1a, 0xc6,
    0x03, 0xdf, 0x33, 0xee, 0x1b, 0x68, 0xc7, 0x4b,
    0x04, 0x64, 0xe0, 0x0e, 0x34, 0x8d, 0xef, 0x81,
    0x1c, 0xc1, 0x69, 0xf8, 0xc8, 0x08, 0x4c, 0x71,
    0x05, 0x8a, 0x65, 0x2f, 0xe1, 0x24, 0x0f, 0x21,
    0x35, 0x93, 0x8e, 0xda, 0xf0, 0x12, 0x82, 0x45,
    0x1d, 0xb5, 0xc2, 0x7d, 0x6a, 0x27, 0xf9, 0xb9,
    0xc9, 0x9a, 0x09, 0x78, 0x4d, 0xe4, 0x72, 0xa6,
    0x06, 0xbf, 0x8b, 0x62, 0x66, 0xdd, 0x30, 0xfd,
    0xe2, 0x98, 0x25, 0xb3, 0x10, 0x91, 0x22, 0x88,
    0x36, 0xd0, 0x94, 0xce, 0x8f, 0x96, 0xdb, 0xbd,
    0xf1, 0xd2, 0x13, 0x5c, 0x83, 0x38, 0x46, 0x40,
    0x1e, 0x42, 0xb6, 0xa3, 0xc3, 0x48, 0x7e, 0x6e,
    0x6b, 0x3a, 0x28, 0x54, 0xfa, 0x85, 0xba, 0x3d,
    0xca, 0x5e, 0x9b, 0x9f, 0x0a, 0x15, 0x79, 0x2b,
    0x4e, 0xd4, 0xe5, 0xac, 0x73, 0xf3, 0xa7, 0x57,
    0x07, 0x70, 0xc0, 0xf7, 0x8c, 0x80, 0x63, 0x0d,
    0x67, 0x4a, 0xde, 0xed, 0x31, 0xc5, 0xfe, 0x18,
    0xe3, 0xa5, 0x99, 0x77, 0x26, 0xb8, 0xb4, 0x7c,
    0x11, 0x44, 0x92, 0xd9, 0x23, 0x20, 0x89, 0x2e,
    0x37, 0x3f, 0xd1, 0x5b, 0x95, 0xbc, 0xcf, 0xcd,
    0x90, 0x87, 0x97, 0xb2, 0xdc, 0xfc, 0xbe, 0x61,
    0xf2, 0x56, 0xd3, 0xab, 0x14, 0x2a, 0x5d, 0x9e,
    0x84, 0x3c, 0x39, 0x53, 0x47, 0x6d, 0x41, 0xa2,
    0x1f, 0x2d, 0x43, 0xd8, 0xb7, 0x7b, 0xa4, 0x76,
    0xc4, 0x17, 0x49, 0xec, 0x7f, 0x0c, 0x6f, 0xf6,
    0x6c, 0xa1, 0x3b, 0x52, 0x29, 0x9d, 0x55, 0xaa,
    0xfb, 0x60, 0x86, 0xb1, 0xbb, 0xcc, 0x3e, 0x5a,
    0xcb, 0x59, 0x5f, 0xb0, 0x9c, 0xa9, 0xa0, 0x51,
    0x0b, 0xf5, 0x16, 0xeb, 0x7a, 0x75, 0x2c, 0xd7,
    0x4f, 0xae, 0xd5, 0xe9, 0xe6, 0xe7, 0xad, 0xe8,
    0x74, 0xd6, 0xf4, 0xea, 0xa8, 0x50, 0x58, 0xaf,
};

/// Multiplies polynomial `src` by scalar `c`, shifts by `shift`, and adds (XORs) into `dst`.
/// Source: quirc/lib/decode.c, function poly_add.
pub fn polyAdd(dst: *[MAX_POLY]u8, src: *const [MAX_POLY]u8, c: u8, shift: isize) void {
    if (c == 0) return;
    const log_c = gf256_log[c];

    for (0..MAX_POLY) |i| {
        const p = @as(isize, @intCast(i)) + shift;
        const v = src[i];

        if (p < 0 or p >= @as(isize, MAX_POLY)) continue;
        if (v == 0) continue;

        const idx: usize = @intCast(p);
        const exp_idx = (@as(usize, gf256_log[v]) + log_c) % 255;
        dst[idx] ^= gf256_exp[exp_idx];
    }
}

/// Evaluates polynomial `s` at element `x` over GF(256).
/// Source: quirc/lib/decode.c, function poly_eval.
pub fn polyEval(s: *const [MAX_POLY]u8, x: u8) u8 {
    if (x == 0) return s[0];
    const log_x = gf256_log[x];
    var sum: u8 = 0;

    for (0..MAX_POLY) |i| {
        const c = s[i];
        if (c == 0) continue;

        const exp_idx = (@as(usize, gf256_log[c]) + @as(usize, log_x) * i) % 255;
        sum ^= gf256_exp[exp_idx];
    }

    return sum;
}

/// Berlekamp-Massey algorithm for finding the error locator polynomial sigma(x).
/// Source: quirc/lib/decode.c, function berlekamp_massey.
pub fn berlekampMassey(s: []const u8, N: usize, sigma: *[MAX_POLY]u8) void {
    var C: [MAX_POLY]u8 = @splat(0);
    var B: [MAX_POLY]u8 = @splat(0);
    var L: usize = 0;
    var m: usize = 1;
    var b: u8 = 1;

    B[0] = 1;
    C[0] = 1;

    for (0..N) |n| {
        var d = s[n];
        for (1..L + 1) |i| {
            if (C[i] != 0 and s[n - i] != 0) {
                const exp_idx = (@as(usize, gf256_log[C[i]]) + @as(usize, gf256_log[s[n - i]])) % 255;
                d ^= gf256_exp[exp_idx];
            }
        }

        const mult = gf256_exp[(255 - @as(usize, gf256_log[b]) + @as(usize, gf256_log[d])) % 255];

        if (d == 0) {
            m += 1;
        } else if (L * 2 <= n) {
            const T = C;
            polyAdd(&C, &B, mult, @intCast(m));
            B = T;
            L = n + 1 - L;
            b = d;
            m = 1;
        } else {
            polyAdd(&C, &B, mult, @intCast(m));
            m += 1;
        }
    }

    sigma.* = C;
}

/// Computes the syndrome vector for a block of `bs` bytes with `npar` parity bytes.
/// Returns true if any syndrome is non-zero (indicating errors present).
/// Source: quirc/lib/decode.c, function block_syndromes.
pub fn blockSyndromes(data: []const u8, bs: usize, npar: usize, s: *[MAX_POLY]u8) bool {
    var nonzero = false;
    @memset(s, 0);

    for (0..npar) |i| {
        for (0..bs) |j| {
            const c = data[bs - j - 1];
            if (c == 0) continue;

            const exp_idx = (@as(usize, gf256_log[c]) + i * j) % 255;
            s[i] ^= gf256_exp[exp_idx];
        }

        if (s[i] != 0) {
            nonzero = true;
        }
    }

    return nonzero;
}

/// Computes the error evaluator polynomial omega(x) from syndromes `s` and locator `sigma`.
/// Source: quirc/lib/decode.c, function eloc_poly.
pub fn elocPoly(omega: *[MAX_POLY]u8, s: []const u8, sigma: *const [MAX_POLY]u8, npar: usize) void {
    @memset(omega, 0);

    for (0..npar) |i| {
        const a = sigma[i];
        if (a == 0) continue;
        const log_a = gf256_log[a];

        var j: usize = 0;
        while (j + 1 < MAX_POLY) : (j += 1) {
            if (i + j >= npar) break;
            const b = s[j + 1];
            if (b == 0) continue;

            const exp_idx = (@as(usize, log_a) + @as(usize, gf256_log[b])) % 255;
            omega[i + j] ^= gf256_exp[exp_idx];
        }
    }
}

/// Error type returned when a block contains more errors than Reed-Solomon capacity floor(npar / 2).
pub const RsError = error{
    ReedSolomonUncorrectable,
};

/// Corrects errors in a codeword block of `bs` total bytes with `npar` ECC parity bytes in-place.
/// Returns the number of errors corrected (0 if no errors existed).
/// Fails with `error.ReedSolomonUncorrectable` if the block contains more than floor(npar / 2) errors.
///
/// Source: quirc/lib/decode.c, function correct_block.
pub fn correctBlock(data: []u8, bs: usize, npar: usize) RsError!usize {
    std.debug.assert(bs <= 255);
    std.debug.assert(npar <= MAX_POLY);
    std.debug.assert(data.len >= bs);

    var s: [MAX_POLY]u8 = undefined;
    var sigma: [MAX_POLY]u8 = undefined;
    var sigma_deriv: [MAX_POLY]u8 = undefined;
    var omega: [MAX_POLY]u8 = undefined;

    // 1. Compute syndrome vector. If all zero, block has no errors.
    if (!blockSyndromes(data, bs, npar, &s)) {
        return 0;
    }

    // 2. Synthesize error locator polynomial sigma(x) via Berlekamp-Massey
    berlekampMassey(&s, npar, &sigma);

    // 3. Compute formal derivative sigma'(x).
    // In GF(2^m), even powers vanish: d/dx(x^k) = k * x^(k-1), so only odd k survive with coefficient 1.
    @memset(&sigma_deriv, 0);
    var idx: usize = 0;
    while (idx + 1 < MAX_POLY) : (idx += 2) {
        sigma_deriv[idx] = sigma[idx + 1];
    }

    // 4. Compute error evaluator polynomial omega(x)
    elocPoly(&omega, &s, &sigma, if (npar > 0) npar - 1 else 0);

    // 5. Chien search and Forney algorithm:
    // Evaluate sigma(alpha^-i). If 0, location i is an error.
    var errors_corrected: usize = 0;
    for (0..bs) |i| {
        const xinv = gf256_exp[(255 - i) % 255];

        if (polyEval(&sigma, xinv) == 0) {
            const sd_x = polyEval(&sigma_deriv, xinv);
            const omega_x = polyEval(&omega, xinv);

            if (sd_x == 0) {
                // Derivative cannot be 0 at a simple root of sigma(x)
                return error.ReedSolomonUncorrectable;
            }

            const err_exp = (255 - @as(usize, gf256_log[sd_x]) + @as(usize, gf256_log[omega_x])) % 255;
            const err_val = gf256_exp[err_exp];

            data[bs - i - 1] ^= err_val;
            errors_corrected += 1;
        }
    }

    // 6. Post-correction syndrome verification:
    // If syndromes are still non-zero, errors exceeded correction capacity.
    if (blockSyndromes(data, bs, npar, &s)) {
        return error.ReedSolomonUncorrectable;
    }

    return errors_corrected;
}

// ============================================================================
// Tests
// ============================================================================

const gf256_enc = @import("../gf256.zig");

test "blockSyndromes: zero for clean encoded block, non-zero on corruption" {
    const testing = std.testing;

    // Generate a valid RS block using the encoder
    const data_len: usize = 16;
    const ecc_len: usize = 10;
    const bs: usize = data_len + ecc_len;

    var block: [32]u8 = undefined;
    const raw_data = "HELLO WORLD 1234";
    @memcpy(block[0..data_len], raw_data);

    var divisor: [30]u8 = undefined;
    gf256_enc.computeDivisor(divisor[0..ecc_len]);
    gf256_enc.computeRemainder(block[0..data_len], divisor[0..ecc_len], block[data_len..bs]);

    // Clean block must produce all zero syndromes
    var s: [MAX_POLY]u8 = undefined;
    try testing.expect(!blockSyndromes(block[0..bs], bs, ecc_len, &s));

    // Corrupt one byte -> syndromes must be non-zero
    block[3] ^= 0x55;
    try testing.expect(blockSyndromes(block[0..bs], bs, ecc_len, &s));
}

test "correctBlock: recover 1, 2, ..., floor(ecc/2) deterministic errors" {
    const testing = std.testing;

    // Test with ecc_len = 10 (t = 5 errors max) and data_len = 16 (bs = 26)
    const data_len: usize = 16;
    const ecc_len: usize = 10;
    const bs: usize = data_len + ecc_len;
    const t_max = ecc_len / 2; // 5

    var clean_block: [26]u8 = undefined;
    @memcpy(clean_block[0..data_len], "HELLO RS TEST!!!");

    var divisor: [30]u8 = undefined;
    gf256_enc.computeDivisor(divisor[0..ecc_len]);
    gf256_enc.computeRemainder(clean_block[0..data_len], divisor[0..ecc_len], clean_block[data_len..bs]);

    // Test 0 errors
    var test_block = clean_block;
    var corrected = try correctBlock(&test_block, bs, ecc_len);
    try testing.expectEqual(@as(usize, 0), corrected);
    try testing.expectEqualSlices(u8, &clean_block, &test_block);

    // Test k errors for k in 1..t_max
    var k: usize = 1;
    while (k <= t_max) : (k += 1) {
        test_block = clean_block;

        // Deterministic error patterns: corrupt k fixed positions with fixed non-zero values
        const error_positions = [_]usize{ 0, 4, 11, 18, 25 };
        const error_masks = [_]u8{ 0x01, 0x42, 0xAA, 0x55, 0xFF };

        for (0..k) |e_idx| {
            test_block[error_positions[e_idx]] ^= error_masks[e_idx];
        }

        corrected = try correctBlock(&test_block, bs, ecc_len);
        try testing.expectEqual(k, corrected);
        try testing.expectEqualSlices(u8, &clean_block, &test_block);
    }
}

test "correctBlock: fails with ReedSolomonUncorrectable when errors exceed floor(ecc/2)" {
    const testing = std.testing;

    // ecc_len = 10 -> capacity t = 5. Corrupt 6 bytes (t + 1).
    const data_len: usize = 16;
    const ecc_len: usize = 10;
    const bs: usize = data_len + ecc_len;

    var clean_block: [26]u8 = undefined;
    @memcpy(clean_block[0..data_len], "EXCEED CAPACITY!");

    var divisor: [30]u8 = undefined;
    gf256_enc.computeDivisor(divisor[0..ecc_len]);
    gf256_enc.computeRemainder(clean_block[0..data_len], divisor[0..ecc_len], clean_block[data_len..bs]);

    var test_block = clean_block;
    const error_positions = [_]usize{ 1, 3, 7, 12, 17, 22 };
    for (error_positions) |pos| {
        test_block[pos] ^= 0x7E;
    }

    try testing.expectError(error.ReedSolomonUncorrectable, correctBlock(&test_block, bs, ecc_len));
}

test "correctBlock: various real QR Code ECC configurations (7, 18, 22, 30 bytes)" {
    const testing = std.testing;

    const Config = struct {
        data_len: usize,
        ecc_len: usize,
        t: usize,
    };

    const configs = [_]Config{
        .{ .data_len = 19, .ecc_len = 7, .t = 3 }, // V1-L
        .{ .data_len = 13, .ecc_len = 13, .t = 6 }, // V3-Q
        .{ .data_len = 9, .ecc_len = 17, .t = 8 }, // V3-H
        .{ .data_len = 34, .ecc_len = 22, .t = 11 }, // V6-M
        .{ .data_len = 15, .ecc_len = 30, .t = 15 }, // V10-H
    };

    for (configs) |cfg| {
        const bs = cfg.data_len + cfg.ecc_len;
        var clean_block: [64]u8 = undefined;

        // Fill data with a deterministic sequence
        for (0..cfg.data_len) |i| {
            clean_block[i] = @intCast((i * 17 + 5) & 0xFF);
        }

        var divisor: [30]u8 = undefined;
        gf256_enc.computeDivisor(divisor[0..cfg.ecc_len]);
        gf256_enc.computeRemainder(clean_block[0..cfg.data_len], divisor[0..cfg.ecc_len], clean_block[cfg.data_len..bs]);

        // Corrupt exactly t bytes
        var corrupted_block: [64]u8 = undefined;
        @memcpy(corrupted_block[0..bs], clean_block[0..bs]);

        for (0..cfg.t) |err_idx| {
            // Pick evenly spaced deterministic positions
            const pos = (err_idx * (bs - 1)) / cfg.t;
            corrupted_block[pos] ^= @intCast((err_idx * 31 + 0x5A) & 0xFF);
        }

        const fixed = try correctBlock(corrupted_block[0..bs], bs, cfg.ecc_len);
        try testing.expectEqual(cfg.t, fixed);
        try testing.expectEqualSlices(u8, clean_block[0..bs], corrupted_block[0..bs]);
    }
}
