//! Codeword de-interleaving and Reed-Solomon error correction for QR Code Model 2.
//!
//! Symmetrical reverse of interleave.zig addEccAndInterleave.
//! Source: nayuki/QR-Code-generator, c/qrcodegen.c, function addEccAndInterleave.

const std = @import("std");
const types = @import("../types.zig");
const tables = @import("../tables.zig");
const rs = @import("rs.zig");

pub const Ecc = types.Ecc;

/// De-interleaves data and ECC blocks from `interleaved`, applies Reed-Solomon error correction
/// to each block, and writes the concatenated clean data codewords to `out_data`.
///
/// Returns the total number of symbol errors corrected across all blocks.
/// Returns error.UncorrectableErrors if any block has errors exceeding its correction capability.
///
/// Preconditions:
///   - `interleaved.len == tables.getNumRawDataModules(version) / 8`
///   - `out_data.len == tables.getNumDataCodewords(version, ecl)`
pub fn deinterleaveAndCorrect(
    interleaved: []const u8,
    version: u8,
    ecl: Ecc,
    out_data: []u8,
) rs.RsError!u16 {
    const raw_codewords: usize = tables.getNumRawDataModules(version) / 8;
    const data_len: usize = tables.getNumDataCodewords(version, ecl);
    std.debug.assert(interleaved.len == raw_codewords);
    std.debug.assert(out_data.len == data_len);

    const e: usize = @intCast(@backingInt(ecl));
    const v: usize = version;
    const num_blocks: usize = tables.num_error_correction_blocks[e][v];
    const block_ecc_len: usize = tables.ecc_codewords_per_block[e][v];
    const num_short_blocks: usize = num_blocks - (raw_codewords % num_blocks);
    const short_block_data_len: usize = raw_codewords / num_blocks - block_ecc_len;

    var total_errors_corrected: u16 = 0;
    var dat_offset: usize = 0;

    var i: usize = 0;
    while (i < num_blocks) : (i += 1) {
        const dat_len = short_block_data_len + if (i < num_short_blocks) @as(usize, 0) else @as(usize, 1);
        const block_len = dat_len + block_ecc_len;

        var block_buf: [255]u8 = undefined;

        // 1. De-interleave data codewords of block i
        var j: usize = 0;
        var k: usize = i;
        while (j < dat_len) : (j += 1) {
            if (j == short_block_data_len) {
                k -= num_short_blocks;
            }
            block_buf[j] = interleaved[k];
            k += num_blocks;
        }

        // 2. De-interleave ECC codewords of block i
        j = 0;
        k = data_len + i;
        while (j < block_ecc_len) : (j += 1) {
            block_buf[dat_len + j] = interleaved[k];
            k += num_blocks;
        }

        // 3. Reed-Solomon error correction for block i
        const errs = try rs.correctBlock(block_buf[0..block_len], block_len, block_ecc_len);
        total_errors_corrected += @intCast(errs);

        // 4. Copy corrected data codewords to output buffer
        @memcpy(out_data[dat_offset .. dat_offset + dat_len], block_buf[0..dat_len]);
        dat_offset += dat_len;
    }

    std.debug.assert(dat_offset == data_len);
    return total_errors_corrected;
}

const testing = std.testing;
const interleave = @import("../interleave.zig");

test "deinterleaveAndCorrect roundtrip with clean data and error corruption" {
    const test_configs = [_]struct { v: u8, ecl: Ecc }{
        .{ .v = 1, .ecl = .low },
        .{ .v = 1, .ecl = .medium },
        .{ .v = 3, .ecl = .quartile },
        .{ .v = 6, .ecl = .high },
        .{ .v = 10, .ecl = .medium },
        .{ .v = 40, .ecl = .high },
    };

    for (test_configs) |cfg| {
        const raw_len = tables.getNumRawDataModules(cfg.v) / 8;
        const data_len = tables.getNumDataCodewords(cfg.v, cfg.ecl);

        var original_data: [tables.max_data_codewords]u8 = undefined;
        var interleaved: [tables.max_raw_codewords]u8 = undefined;
        var decoded_data: [tables.max_data_codewords]u8 = undefined;

        for (original_data[0..data_len], 0..) |*b, i| {
            b.* = @truncate(i * 17 + 5);
        }

        // Encode
        interleave.addEccAndInterleave(original_data[0..data_len], cfg.v, cfg.ecl, interleaved[0..raw_len]);

        // Decode clean
        var errs = try deinterleaveAndCorrect(interleaved[0..raw_len], cfg.v, cfg.ecl, decoded_data[0..data_len]);
        try testing.expectEqual(@as(u16, 0), errs);
        try testing.expectEqualSlices(u8, original_data[0..data_len], decoded_data[0..data_len]);

        // Inject 1 error in byte 0
        interleaved[0] ^= 0x55;
        errs = try deinterleaveAndCorrect(interleaved[0..raw_len], cfg.v, cfg.ecl, decoded_data[0..data_len]);
        try testing.expect(errs >= 1);
        try testing.expectEqualSlices(u8, original_data[0..data_len], decoded_data[0..data_len]);
    }
}
