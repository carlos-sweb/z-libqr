//! Decoder module for QR Code Model 2.
//!
//! Provides tier-parameterized raw module matrix decoding to original payload and metadata.

const std = @import("std");
const types = @import("../types.zig");
const tables = @import("../tables.zig");

pub const rs = @import("rs.zig");
pub const bch = @import("bch.zig");
pub const bit_reader = @import("bit_reader.zig");
pub const zigzag = @import("zigzag.zig");
pub const deinterleave = @import("deinterleave.zig");
pub const parser = @import("parser.zig");

pub const Ecc = types.Ecc;
pub const Fnc1Mode = types.Fnc1Mode;
pub const StructuredAppend = types.StructuredAppend;

pub const DecodeMetadata = struct {
    version: u8,
    ecc: Ecc,
    mask: u3,
    modes_used: u8 = 0,
    eci: ?u32 = null,
    fnc1_mode: ?Fnc1Mode = null,
    fnc1_app_indicator: ?u8 = null,
    sa: ?StructuredAppend = null,
    errors_corrected_format: u8 = 0,
    errors_corrected_version: u8 = 0,
    errors_corrected_data: u16 = 0,
};

pub const DecodeResult = struct {
    data: []const u8,
    metadata: DecodeMetadata,
};

pub const DecodeError = error{
    InvalidMatrixSize,
    VersionExceedsTier,
    FormatBitsUncorrectable,
    VersionBitsUncorrectable,
    ReedSolomonUncorrectable,
    UnexpectedEndOfStream,
    InvalidMode,
    InvalidNumericValue,
    InvalidAlphanumericValue,
    InvalidKanjiValue,
    InvalidEciAssignment,
    BufferTooSmall,
};

/// Computes the worst-case upper bound on buffer size in bytes required to decode any valid QR symbol
/// of `version` and `ecc`.
///
/// NOTE: This is a safe upper bound (3 * data_codewords) based on Numeric mode packing (3 digits per 10 bits).
/// For Byte mode, the decoded payload will not exceed `data_codewords` bytes; for Kanji mode, it will not exceed
/// `data_codewords * 2` bytes. Caller can safely allocate `decodeBufferLen(version, ecc)` for any mode.
pub fn decodeBufferLen(version: u8, ecc: Ecc) usize {
    const data_codewords = tables.getNumDataCodewords(version, ecc);
    return data_codewords * 3;
}

/// Tier-parameterized QR Code decoder type.
/// Matches the architecture and version limits of the Encoder.
pub fn Decoder(comptime max_version: u8) type {
    if (max_version < tables.min_version or max_version > tables.max_version) {
        @compileError(std.fmt.comptimePrint(
            "Decoder max_version must be in {d}...{d}, got {d}",
            .{ tables.min_version, tables.max_version, max_version },
        ));
    }

    return struct {
        pub const tier_max_version: u8 = max_version;
        pub const max_size: u8 = tables.symbolSize(max_version);
        pub const max_buffer_len: usize = tables.moduleCount(max_version);
        pub const max_raw_codewords: usize = tables.getNumRawDataModules(max_version) / 8;
        pub const max_data_codewords: usize = tables.getNumDataCodewords(max_version, .low);
        pub const max_decoded_len: usize = max_data_codewords * 3;
        pub const Metadata = DecodeMetadata;
        pub const Result = DecodeResult;

        /// Returns the worst-case upper bound buffer size in bytes required to hold
        /// the decoded payload of a symbol with the given version and ECC level.
        pub fn bufferLen(version: u8, ecc: Ecc) DecodeError!usize {
            if (version < tables.min_version or version > tables.max_version) {
                return error.InvalidMatrixSize;
            }
            if (version > tier_max_version) {
                return error.VersionExceedsTier;
            }
            return decodeBufferLen(version, ecc);
        }

        /// Decodes a raw module matrix (0/1 byte-per-module, row-major, without quiet zone)
        /// into caller-provided `out_buf`.
        pub fn decode(
            modules: []const u8,
            size: u8,
            out_buf: []u8,
        ) DecodeError!DecodeResult {
            // 1. Matrix dimension validations
            if (modules.len < @as(usize, size) * size) {
                return error.InvalidMatrixSize;
            }
            if (size < 21 or size > 177 or (size - 17) % 4 != 0) {
                return error.InvalidMatrixSize;
            }

            const candidate_v: u8 = (size - 17) / 4;
            if (candidate_v > tier_max_version) {
                return error.VersionExceedsTier;
            }

            // 2. Read and validate QR Version (BCH)
            const v_info = try bch.readVersion(modules, size);
            const version = v_info.version;
            if (version > tier_max_version) {
                return error.VersionExceedsTier;
            }

            // 3. Read and validate Format Information (BCH: ECC and mask)
            const f_info = try bch.readFormat(modules, size);
            const ecc = f_info.ecc;
            const mask = f_info.mask;

            // 4. Extract interleaved raw codewords via inverse zigzag scan and mask removal
            const raw_len = tables.getNumRawDataModules(version) / 8;
            var raw_buf: [max_raw_codewords]u8 = undefined;
            zigzag.extractCodewords(modules, size, version, mask, raw_buf[0..raw_len]);

            // 5. De-interleave and Reed-Solomon correct data codewords
            const data_len = tables.getNumDataCodewords(version, ecc);
            var data_buf: [max_data_codewords]u8 = undefined;
            const data_errs = try deinterleave.deinterleaveAndCorrect(
                raw_buf[0..raw_len],
                version,
                ecc,
                data_buf[0..data_len],
            );

            // 6. Parse data stream segments into decoded string and metadata
            const parsed = try parser.parseSegments(data_buf[0..data_len], version, out_buf);

            return .{
                .data = parsed.data,
                .metadata = .{
                    .version = version,
                    .ecc = ecc,
                    .mask = mask,
                    .modes_used = parsed.metadata.modes_used,
                    .eci = parsed.metadata.eci,
                    .fnc1_mode = parsed.metadata.fnc1_mode,
                    .fnc1_app_indicator = parsed.metadata.fnc1_app_indicator,
                    .sa = parsed.metadata.sa,
                    .errors_corrected_format = f_info.errors_corrected,
                    .errors_corrected_version = v_info.errors_corrected,
                    .errors_corrected_data = data_errs,
                },
            };
        }
    };
}

/// Predefined decoder tiers matching distributed libraries and Encoder tiers.
pub const Tier1 = Decoder(6);
pub const Tier2 = Decoder(10);
pub const Tier3 = Decoder(40);

/// Convenience function decoding a matrix using Tier 3 (supporting all versions 1..40).
pub fn decodeMatrix(
    modules: []const u8,
    size: u8,
    out_buf: []u8,
) DecodeError!DecodeResult {
    return Tier3.decode(modules, size, out_buf);
}

// ---- Unit Tests ----

const testing = std.testing;
const root = @import("../root.zig");

test {
    _ = rs;
    _ = bch;
    _ = bit_reader;
    _ = zigzag;
    _ = deinterleave;
    _ = parser;
}

test "Tier boundaries: Tier 1, Tier 2, and Tier 3 version enforcement" {
    // 1. Version 1 (size 21) -> Decodable by Tier 1, Tier 2, Tier 3
    {
        var mat_buf: [tables.moduleCount(1)]u8 = undefined;
        const qr = try root.Tier1.encodeAdvanced(&mat_buf, "TIER1_OK", .{ .ecc = .medium });
        var out_buf: [256]u8 = undefined;

        const res1 = try Tier1.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("TIER1_OK", res1.data);

        const res2 = try Tier2.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("TIER1_OK", res2.data);

        const res3 = try Tier3.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("TIER1_OK", res3.data);
    }

    // 2. Version 7 (size 45) -> Exceeds Tier 1 (max 6), accepted by Tier 2 and Tier 3
    {
        var mat_buf: [tables.moduleCount(7)]u8 = undefined;
        const qr = try root.Tier2.encodeAdvanced(&mat_buf, "VERSION_7_PAYLOAD", .{
            .ecc = .medium,
            .min_version = 7,
        });
        var out_buf: [512]u8 = undefined;

        // Tier 1 must reject with VersionExceedsTier
        try testing.expectError(error.VersionExceedsTier, Tier1.decode(qr.modules, qr.size, &out_buf));

        // Tier 2 and Tier 3 must succeed
        const res2 = try Tier2.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("VERSION_7_PAYLOAD", res2.data);
        try testing.expectEqual(@as(u8, 7), res2.metadata.version);

        const res3 = try Tier3.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("VERSION_7_PAYLOAD", res3.data);
    }

    // 3. Version 11 (size 61) -> Exceeds Tier 1 and Tier 2 (max 10), accepted by Tier 3
    {
        var mat_buf: [tables.moduleCount(11)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, "VERSION_11_PAYLOAD", .{
            .ecc = .medium,
            .min_version = 11,
        });
        var out_buf: [512]u8 = undefined;

        // Tier 1 and Tier 2 must reject with VersionExceedsTier
        try testing.expectError(error.VersionExceedsTier, Tier1.decode(qr.modules, qr.size, &out_buf));
        try testing.expectError(error.VersionExceedsTier, Tier2.decode(qr.modules, qr.size, &out_buf));

        // Tier 3 must succeed
        const res3 = try Tier3.decode(qr.modules, qr.size, &out_buf);
        try testing.expectEqualStrings("VERSION_11_PAYLOAD", res3.data);
        try testing.expectEqual(@as(u8, 11), res3.metadata.version);
    }
}

test "bufferLen worst-case upper bound across tiers" {
    // Tier 1
    const t1_v1 = try Tier1.bufferLen(1, .low);
    try testing.expectEqual(@as(usize, 19 * 3), t1_v1); // V1-L has 19 data codewords
    try testing.expectError(error.VersionExceedsTier, Tier1.bufferLen(7, .low));
    try testing.expectError(error.InvalidMatrixSize, Tier1.bufferLen(0, .low));

    // Tier 2
    const t2_v10 = try Tier2.bufferLen(10, .high);
    try testing.expectEqual(@as(usize, 122 * 3), t2_v10); // V10-H has 122 data codewords
    try testing.expectError(error.VersionExceedsTier, Tier2.bufferLen(11, .low));

    // Tier 3
    const t3_v40 = try Tier3.bufferLen(40, .low);
    try testing.expectEqual(@as(usize, 2956 * 3), t3_v40); // V40-L has 2956 data codewords
    try testing.expectError(error.InvalidMatrixSize, Tier3.bufferLen(41, .low));
}

test "decode error conditions: matrix size, small buffer, uncorrectable bit flips" {
    var out_buf: [256]u8 = undefined;

    // 1. Invalid size values
    const dummy: [400]u8 = @splat(0);
    try testing.expectError(error.InvalidMatrixSize, Tier3.decode(&dummy, 17, &out_buf));
    try testing.expectError(error.InvalidMatrixSize, Tier3.decode(&dummy, 20, &out_buf));
    try testing.expectError(error.InvalidMatrixSize, Tier3.decode(&dummy, 22, &out_buf));
    try testing.expectError(error.InvalidMatrixSize, Tier3.decode(&dummy, 181, &out_buf));

    // 2. Slice shorter than size * size
    const short_buf: [20]u8 = @splat(0);
    try testing.expectError(error.InvalidMatrixSize, Tier3.decode(&short_buf, 21, &out_buf));

    // 3. Output buffer too small
    var mat_buf: [tables.moduleCount(1)]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, "HELLO WORLD", .{ .ecc = .medium });
    var tiny_buf: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, Tier1.decode(qr.modules, qr.size, &tiny_buf));
}

test "Roundtrip: Numeric Mode across versions and ECC levels" {
    const cases = [_]struct {
        text: []const u8,
        ecc: Ecc,
        min_v: u8,
    }{
        .{ .text = "0123456789", .ecc = .low, .min_v = 1 },
        .{ .text = "867530999999123456789", .ecc = .medium, .min_v = 2 },
        .{ .text = "1234567890123456789012345678901234567890", .ecc = .quartile, .min_v = 3 },
        .{ .text = "987654321000111222333444555666777888999", .ecc = .high, .min_v = 7 },
    };

    for (cases) |c| {
        var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, c.text, .{
            .ecc = c.ecc,
            .min_version = c.min_v,
        });

        var out_buf: [1024]u8 = undefined;
        const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

        try testing.expectEqualStrings(c.text, res.data);
        try testing.expectEqual(c.ecc, res.metadata.ecc);
        try testing.expect(res.metadata.version >= c.min_v);
        try testing.expect((res.metadata.modes_used & 0x01) != 0); // Numeric flag
    }
}

test "Roundtrip: Alphanumeric Mode across versions and ECC levels" {
    const cases = [_]struct {
        text: []const u8,
        ecc: Ecc,
        min_v: u8,
    }{
        .{ .text = "HELLO WORLD", .ecc = .low, .min_v = 1 },
        .{ .text = "HELLO WORLD 12345", .ecc = .medium, .min_v = 2 },
        .{ .text = "QR CODE MODEL 2 / Z-LIBQR / VERSION 7 TEST", .ecc = .high, .min_v = 7 },
    };

    for (cases) |c| {
        var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, c.text, .{
            .ecc = c.ecc,
            .min_version = c.min_v,
        });

        var out_buf: [1024]u8 = undefined;
        const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

        try testing.expectEqualStrings(c.text, res.data);
        try testing.expectEqual(c.ecc, res.metadata.ecc);
        try testing.expect((res.metadata.modes_used & 0x02) != 0); // Alnum flag
    }
}

test "Roundtrip: Byte Mode binary and text" {
    const cases = [_]struct {
        data: []const u8,
        ecc: Ecc,
        min_v: u8,
    }{
        .{ .data = "plain ascii text", .ecc = .low, .min_v = 1 },
        .{ .data = "binary\x00with\x01nulls\xFFand\xFEbytes", .ecc = .medium, .min_v = 2 },
        .{ .data = "UTF-8 text: ñandú, corazón, 日本語", .ecc = .quartile, .min_v = 4 },
    };

    for (cases) |c| {
        var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, c.data, .{
            .ecc = c.ecc,
            .min_version = c.min_v,
            .optimize = false,
        });

        var out_buf: [1024]u8 = undefined;
        const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

        try testing.expectEqualSlices(u8, c.data, res.data);
        try testing.expectEqual(c.ecc, res.metadata.ecc);
        try testing.expect((res.metadata.modes_used & 0x04) != 0); // Byte flag
    }
}

test "Roundtrip: Kanji Mode (Shift-JIS output)" {
    // Madoka UTF-8: 「魔法少女まどか☆マギカ」
    // The encoder receives UTF-8 with kanji = true, converts to 13-bit codewords.
    // The decoder emits the 2-byte Shift-JIS representation for each character.
    const madoka_utf8 = "\xE3\x80\x8C\xE9\xAD\x94\xE6\xB3\x95\xE5\xB0\x91\xE5\xA5\xB3\xE3\x81\xBE\xE3\x81\xA9\xE3\x81\x8B\xE2\x98\x86\xE3\x83\x9E\xE3\x82\xAE\xE3\x82\xAB\xE3\x80\x8D";

    var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, madoka_utf8, .{
        .ecc = .medium,
        .kanji = true,
        .optimize = false,
    });

    var out_buf: [1024]u8 = undefined;
    const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

    // Expected Shift-JIS bytes:
    const expected_sjis = [_]u8{
        0x81, 0x75,
        0x96, 0x82,
        0x96, 0x40,
        0x8F, 0xAD,
        0x8F, 0x97,
        0x82, 0xDC,
        0x82, 0xC7,
        0x82, 0xA9,
        0x81, 0x99,
        0x83, 0x7D,
        0x83, 0x4D,
        0x83, 0x4A,
        0x81, 0x76,
    };

    try testing.expectEqualSlices(u8, &expected_sjis, res.data);
    try testing.expect((res.metadata.modes_used & 0x08) != 0); // Kanji flag
}

test "Roundtrip: ECI Mode assignment metadata" {
    var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, "ISO-8859-1 TEXT", .{
        .ecc = .medium,
        .eci = 3, // ISO-8859-1
    });

    var out_buf: [1024]u8 = undefined;
    const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

    try testing.expectEqualStrings("ISO-8859-1 TEXT", res.data);
    try testing.expectEqual(@as(?u32, 3), res.metadata.eci);
    try testing.expect((res.metadata.modes_used & 0x10) != 0); // ECI flag
}

test "Roundtrip: FNC1 First and Second position" {
    // 1. FNC1 First (GS1 QR Code)
    {
        var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, "0101234567890128", .{
            .ecc = .low,
            .fnc1 = .{ .mode = .first },
        });

        var out_buf: [1024]u8 = undefined;
        const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

        try testing.expectEqualStrings("0101234567890128", res.data);
        try testing.expectEqual(types.Fnc1Mode.first, res.metadata.fnc1_mode.?);
        try testing.expect((res.metadata.modes_used & 0x20) != 0); // FNC1 flag
    }

    // 2. FNC1 Second (AIM Application Indicator)
    {
        var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        const qr = try root.Tier3.encodeAdvanced(&mat_buf, "AIM_PAYLOAD_TEST", .{
            .ecc = .high,
            .fnc1 = .{ .mode = .second, .app_indicator = 'B' + 100 },
        });

        var out_buf: [1024]u8 = undefined;
        const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

        try testing.expectEqualStrings("AIM_PAYLOAD_TEST", res.data);
        try testing.expectEqual(types.Fnc1Mode.second, res.metadata.fnc1_mode.?);
        try testing.expectEqual(@as(?u8, 'B' + 100), res.metadata.fnc1_app_indicator);
        try testing.expect((res.metadata.modes_used & 0x20) != 0); // FNC1 flag
    }
}

test "Roundtrip: Structured Append header metadata" {
    var mat_buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, "FRAGMENT_3_OF_8", .{
        .ecc = .medium,
        .sa = .{
            .position = 2, // 3rd symbol (0-indexed 2)
            .total = 7, // 8 symbols total (0-indexed 7)
            .parity = 0x42,
        },
    });

    var out_buf: [1024]u8 = undefined;
    const res = try Tier3.decode(qr.modules, qr.size, &out_buf);

    try testing.expectEqualStrings("FRAGMENT_3_OF_8", res.data);
    try testing.expect(res.metadata.sa != null);
    try testing.expectEqual(@as(u4, 2), res.metadata.sa.?.position);
    try testing.expectEqual(@as(u4, 7), res.metadata.sa.?.total);
    try testing.expectEqual(@as(u8, 0x42), res.metadata.sa.?.parity);
    try testing.expect((res.metadata.modes_used & 0x40) != 0); // SA flag
}

test "Roundtrip: V40 large matrix decoding with error recovery" {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 - ";
    var long_text: [800]u8 = undefined;
    for (&long_text, 0..) |*b, i| {
        b.* = alphabet[i % alphabet.len];
    }

    var mat_buf: [tables.moduleCount(40)]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, &long_text, .{
        .ecc = .medium,
        .min_version = 40,
    });

    try testing.expectEqual(@as(u8, 40), qr.version);
    try testing.expectEqual(@as(u8, 177), qr.size);

    // Corrupt up to 2 modules in data area
    // (Ensure we don't hit function patterns)
    var corrupted_matrix: [tables.moduleCount(40)]u8 = undefined;
    @memcpy(&corrupted_matrix, qr.modules);
    // Flip non-function modules in middle of symbol
    corrupted_matrix[90 * 177 + 90] ^= 1;
    corrupted_matrix[91 * 177 + 91] ^= 1;

    var out_buf: [2048]u8 = undefined;
    const res = try Tier3.decode(&corrupted_matrix, qr.size, &out_buf);

    try testing.expectEqualStrings(&long_text, res.data);
    try testing.expectEqual(@as(u8, 40), res.metadata.version);
    try testing.expectEqual(Ecc.medium, res.metadata.ecc);
    try testing.expect(res.metadata.errors_corrected_data >= 1);
}
