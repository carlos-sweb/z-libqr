//! Segment representations, mode detection, character counts and segment payload encoding.
//!
//! Supported modes in Increment 3: Numeric, Alphanumeric, Byte, ECI.
//! (Kanji is implemented in Increment 9).
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT), c/qrcodegen.c:
//!     numCharCountBits, calcSegmentBitLength, qrcodegen_makeNumeric,
//!     qrcodegen_makeAlphanumeric, qrcodegen_makeBytes, qrcodegen_makeEci, getTotalBits.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const BitBuffer = @import("BitBuffer.zig").BitBuffer;
pub const kanji = @import("kanji.zig");
pub const isKanji = kanji.isKanji;
pub const toQrKanji = kanji.toQrKanji;

pub const Mode = types.Mode;

/// Alphanumeric character set defined by QR Code Model 2.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, constant ALPHANUMERIC_CHARSET.
pub const ALPHANUMERIC_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

/// Sentinel value indicating overflow in bit length or character count calculations.
pub const LENGTH_OVERFLOW: usize = std.math.maxInt(usize);

/// A QR Code data segment holding mode, character count, raw payload and precalculated bit length.
pub const Segment = struct {
    mode: Mode,
    num_chars: usize,
    data: []const u8,
    bit_length: usize,
};

/// Returns the bit width of the character count field for a segment in `mode`
/// at QR version `version` (1..40).
///
/// NOTE on version-dependent widths:
///   - Versions 1-9:   Numeric=10, Alphanumeric=9,  Byte=8,  Kanji=8,  ECI=0
///   - Versions 10-26: Numeric=12, Alphanumeric=11, Byte=16, Kanji=10, ECI=0
///   - Versions 27-40: Numeric=14, Alphanumeric=13, Byte=16, Kanji=12, ECI=0
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function numCharCountBits.
pub fn numCharCountBits(mode: Mode, version: u8) u8 {
    std.debug.assert(version >= tables.min_version and version <= tables.max_version);
    const i: usize = (version + 7) / 17;
    return switch (mode) {
        .numeric => switch (i) {
            0 => 10,
            1 => 12,
            else => 14,
        },
        .alphanumeric => switch (i) {
            0 => 9,
            1 => 11,
            else => 13,
        },
        .byte => switch (i) {
            0 => 8,
            else => 16,
        },
        .kanji => switch (i) {
            0 => 8,
            1 => 10,
            else => 12,
        },
        .eci, .fnc1_first, .fnc1_second => 0,
    };
}

/// Returns the number of data bits needed to encode a segment payload of `num_chars` characters
/// in `mode` (excluding the 4-bit mode indicator and the character count field).
/// Returns LENGTH_OVERFLOW if `num_chars` exceeds 32767 (INT16_MAX in ISO/IEC 18004 spec limits).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function calcSegmentBitLength.
pub fn calcSegmentBitLength(mode: Mode, num_chars: usize) usize {
    if (num_chars > 32767) return LENGTH_OVERFLOW;
    var result: usize = num_chars;
    switch (mode) {
        .numeric => {
            // ceil(10/3 * n) = (n * 10 + 2) / 3
            result = (result * 10 + 2) / 3;
        },
        .alphanumeric => {
            // ceil(11/2 * n) = (n * 11 + 1) / 2
            result = (result * 11 + 1) / 2;
        },
        .byte => {
            result *= 8;
        },
        .kanji => {
            result *= 13;
        },
        .eci => {
            if (num_chars != 0) return LENGTH_OVERFLOW;
            result = 3 * 8; // Worst case buffer size calculation in Nayuki
        },
        .fnc1_first => {
            if (num_chars != 0) return LENGTH_OVERFLOW;
            return 0;
        },
        .fnc1_second => {
            if (num_chars != 0) return LENGTH_OVERFLOW;
            return 8; // Exactly 8 bits for Application Indicator
        },
    }
    if (result > 32767) return LENGTH_OVERFLOW;
    return result;
}

/// Returns the minimum buffer size in bytes required to store the packed segment payload.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_calcSegmentBufferSize.
pub fn calcSegmentBufferSize(mode: Mode, num_chars: usize) usize {
    const bit_len = calcSegmentBitLength(mode, num_chars);
    if (bit_len == LENGTH_OVERFLOW) return std.math.maxInt(usize);
    return (bit_len + 7) / 8;
}

/// Returns true if all characters in `text` are ASCII digits '0'..'9'.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_isNumeric.
pub fn isNumeric(text: []const u8) bool {
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Returns true if all characters in `text` exist in the QR alphanumeric charset.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_isAlphanumeric.
pub fn isAlphanumeric(text: []const u8) bool {
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, ALPHANUMERIC_CHARSET, c) == null) return false;
    }
    return true;
}

/// Creates a Byte mode segment from raw binary data.
/// Precondition: `buf.len >= data.len`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_makeBytes.
pub fn makeBytes(data: []const u8, buf: []u8) Segment {
    const bit_len = calcSegmentBitLength(.byte, data.len);
    std.debug.assert(bit_len != LENGTH_OVERFLOW);
    std.debug.assert(buf.len >= data.len);
    @memcpy(buf[0..data.len], data);
    return .{
        .mode = .byte,
        .num_chars = data.len,
        .data = buf[0..data.len],
        .bit_length = bit_len,
    };
}

/// Encodes numeric text ('0'..'9') into groups of 3 digits (10 bits), 2 digits (7 bits), or 1 digit (4 bits).
/// Precondition: `isNumeric(digits)` is true, and `buf.len >= calcSegmentBufferSize(.numeric, digits.len)`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_makeNumeric.
pub fn makeNumeric(digits: []const u8, buf: []u8) Segment {
    const bit_len = calcSegmentBitLength(.numeric, digits.len);
    std.debug.assert(bit_len != LENGTH_OVERFLOW);
    const byte_len = (bit_len + 7) / 8;
    std.debug.assert(buf.len >= byte_len);

    if (byte_len > 0) {
        @memset(buf[0..byte_len], 0);
    }
    var bb = BitBuffer.init(buf[0..byte_len]);

    var accum_data: u32 = 0;
    var accum_count: usize = 0;
    for (digits) |c| {
        std.debug.assert(c >= '0' and c <= '9');
        accum_data = accum_data * 10 + (c - '0');
        accum_count += 1;
        if (accum_count == 3) {
            bb.appendBits(accum_data, 10);
            accum_data = 0;
            accum_count = 0;
        }
    }
    if (accum_count > 0) {
        const bits: u8 = @intCast(accum_count * 3 + 1);
        bb.appendBits(accum_data, bits);
    }
    std.debug.assert(bb.bit_length == bit_len);

    return .{
        .mode = .numeric,
        .num_chars = digits.len,
        .data = buf[0..byte_len],
        .bit_length = bit_len,
    };
}

/// Encodes alphanumeric text into pairs of characters (11 bits) or single remaining character (6 bits).
/// Precondition: `isAlphanumeric(text)` is true, and `buf.len >= calcSegmentBufferSize(.alphanumeric, text.len)`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_makeAlphanumeric.
pub fn makeAlphanumeric(text: []const u8, buf: []u8) Segment {
    const bit_len = calcSegmentBitLength(.alphanumeric, text.len);
    std.debug.assert(bit_len != LENGTH_OVERFLOW);
    const byte_len = (bit_len + 7) / 8;
    std.debug.assert(buf.len >= byte_len);

    if (byte_len > 0) {
        @memset(buf[0..byte_len], 0);
    }
    var bb = BitBuffer.init(buf[0..byte_len]);

    var accum_data: u32 = 0;
    var accum_count: usize = 0;
    for (text) |c| {
        const idx = std.mem.indexOfScalar(u8, ALPHANUMERIC_CHARSET, c).?;
        accum_data = accum_data * 45 + @as(u32, @intCast(idx));
        accum_count += 1;
        if (accum_count == 2) {
            bb.appendBits(accum_data, 11);
            accum_data = 0;
            accum_count = 0;
        }
    }
    if (accum_count > 0) {
        bb.appendBits(accum_data, 6);
    }
    std.debug.assert(bb.bit_length == bit_len);

    return .{
        .mode = .alphanumeric,
        .num_chars = text.len,
        .data = buf[0..byte_len],
        .bit_length = bit_len,
    };
}

/// Encodes a UTF-8 string consisting entirely of JIS X 0208 characters in Kanji mode.
/// Requires `buf.len >= calcSegmentBufferSize(.kanji, num_chars)`.
/// Returns error.InvalidUtf8 if `text` is not valid UTF-8.
/// Returns error.InvalidCharacter if any character is not in JIS X 0208.
/// Returns error.BufferTooSmall if `buf.len` is insufficient.
/// Source: nayuki/QR-Code-generator, QrSegmentAdvanced.java, makeKanji.
pub fn makeKanji(text: []const u8, buf: []u8) !Segment {
    const num_chars = try kanji.countKanji(text);
    const bit_len = num_chars * 13;
    const byte_len = (bit_len + 7) / 8;
    if (buf.len < byte_len) return error.BufferTooSmall;

    if (byte_len > 0) {
        @memset(buf[0..byte_len], 0);
    }
    var bb = BitBuffer.init(buf[0..byte_len]);

    var iter = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    while (iter.nextCodepoint()) |cp| {
        const qr_val = kanji.toQrKanji(cp) orelse return error.InvalidCharacter;
        bb.appendBits(qr_val, 13);
    }
    std.debug.assert(bb.bit_length == bit_len);

    return .{
        .mode = .kanji,
        .num_chars = num_chars,
        .data = buf[0..byte_len],
        .bit_length = bit_len,
    };
}

/// Encodes an Extended Channel Interpretation (ECI) assignment value (0..999999).
/// Precondition: `assign_val <= 999999` and `buf.len >= 3`.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function qrcodegen_makeEci.
pub fn makeEci(assign_val: u32, buf: []u8) Segment {
    std.debug.assert(assign_val < 1000000);
    var byte_len: usize = 0;
    if (assign_val < (1 << 7)) {
        byte_len = 1;
    } else if (assign_val < (1 << 14)) {
        byte_len = 2;
    } else {
        byte_len = 3;
    }
    std.debug.assert(buf.len >= byte_len);
    @memset(buf[0..byte_len], 0);
    var bb = BitBuffer.init(buf[0..byte_len]);

    if (assign_val < (1 << 7)) {
        bb.appendBits(assign_val, 8);
    } else if (assign_val < (1 << 14)) {
        bb.appendBits(2, 2);
        bb.appendBits(assign_val, 14);
    } else {
        bb.appendBits(6, 3);
        bb.appendBits(assign_val >> 10, 11);
        bb.appendBits(assign_val & 0x3FF, 10);
    }

    return .{
        .mode = .eci,
        .num_chars = 0,
        .data = buf[0..byte_len],
        .bit_length = byte_len * 8,
    };
}

/// Creates an FNC1 in First Position segment (GS1 QR Code).
/// Mode indicator is 0101 (0x5). Character count is 0 bits. Payload length is 0 bits.
/// Source: ISO/IEC 18004:2015, section 7.4.8.2.
pub fn makeFnc1First() Segment {
    return .{
        .mode = .fnc1_first,
        .num_chars = 0,
        .bit_length = 0,
        .data = &.{},
    };
}

/// Creates an FNC1 in Second Position segment (AIM Application-Specific).
/// Mode indicator is 1001 (0x9). Character count is 0 bits. Payload is 8 bits (Application Indicator).
/// Source: ISO/IEC 18004:2015, section 7.4.8.3.
pub fn makeFnc1Second(app_indicator: u8, buf: []u8) Segment {
    std.debug.assert(buf.len >= 1);
    buf[0] = app_indicator;
    return .{
        .mode = .fnc1_second,
        .num_chars = 0,
        .bit_length = 8,
        .data = buf[0..1],
    };
}

/// Converts a Latin alphabetic character ('a'..'z', 'A'..'Z') into an 8-bit Application Indicator
/// per ISO/IEC 18004:2015 clause 7.4.8.3: value = ASCII value + 100.
pub fn appIndicatorFromChar(c: u8) error{InvalidApplicationIndicator}!u8 {
    return switch (c) {
        'a'...'z', 'A'...'Z' => c + 100,
        else => error.InvalidApplicationIndicator,
    };
}

/// Converts a 2-digit ASCII string ("00".."99") into an 8-bit Application Indicator
/// per ISO/IEC 18004:2015 clause 7.4.8.3: 2-digit number is encoded as 8-bit binary value (0..99).
pub fn appIndicatorFromDigits(digits: *const [2]u8) error{InvalidApplicationIndicator}!u8 {
    if (digits[0] < '0' or digits[0] > '9' or digits[1] < '0' or digits[1] > '9') {
        return error.InvalidApplicationIndicator;
    }
    return (digits[0] - '0') * 10 + (digits[1] - '0');
}

/// Calculates the total number of bits required to encode the given slice of segments
/// into a QR Code of the given `version`.
/// Includes the 4-bit mode indicator, the character count field (whose bit-width depends on `version`),
/// and the segment payload bits.
/// Returns LENGTH_OVERFLOW if any segment length overflows its character count field,
/// or if total bits exceeds 32767.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function getTotalBits.
pub fn getTotalBits(segs: []const Segment, version: u8) usize {
    var result: usize = 0;
    for (segs) |seg| {
        const ccbits = numCharCountBits(seg.mode, version);
        if (ccbits < 32 and seg.num_chars >= (@as(usize, 1) << @intCast(ccbits))) {
            return LENGTH_OVERFLOW;
        }
        result += 4 + ccbits + seg.bit_length;
        if (result > 32767) return LENGTH_OVERFLOW;
    }
    return result;
}

// ---- Unit Tests ----

const testing = std.testing;

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testNumCharCountBits.
test "numCharCountBits across modes and version groups" {
    // Versions 1..9
    try testing.expectEqual(@as(u8, 10), numCharCountBits(.numeric, 1));
    try testing.expectEqual(@as(u8, 9), numCharCountBits(.alphanumeric, 5));
    try testing.expectEqual(@as(u8, 8), numCharCountBits(.byte, 9));
    try testing.expectEqual(@as(u8, 8), numCharCountBits(.kanji, 9));
    try testing.expectEqual(@as(u8, 0), numCharCountBits(.eci, 9));

    // Versions 10..26
    try testing.expectEqual(@as(u8, 12), numCharCountBits(.numeric, 10));
    try testing.expectEqual(@as(u8, 11), numCharCountBits(.alphanumeric, 20));
    try testing.expectEqual(@as(u8, 16), numCharCountBits(.byte, 26));
    try testing.expectEqual(@as(u8, 10), numCharCountBits(.kanji, 10));
    try testing.expectEqual(@as(u8, 0), numCharCountBits(.eci, 26));

    // Versions 27..40
    try testing.expectEqual(@as(u8, 14), numCharCountBits(.numeric, 27));
    try testing.expectEqual(@as(u8, 13), numCharCountBits(.alphanumeric, 35));
    try testing.expectEqual(@as(u8, 16), numCharCountBits(.byte, 40));
    try testing.expectEqual(@as(u8, 12), numCharCountBits(.kanji, 40));
    try testing.expectEqual(@as(u8, 0), numCharCountBits(.eci, 40));
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testCalcSegmentBufferSize.
test "calcSegmentBufferSize against reference cases" {
    // Numeric
    try testing.expectEqual(@as(usize, 0), calcSegmentBufferSize(.numeric, 0));
    try testing.expectEqual(@as(usize, 1), calcSegmentBufferSize(.numeric, 1));
    try testing.expectEqual(@as(usize, 1), calcSegmentBufferSize(.numeric, 2));
    try testing.expectEqual(@as(usize, 2), calcSegmentBufferSize(.numeric, 3));
    try testing.expectEqual(@as(usize, 614), calcSegmentBufferSize(.numeric, 1472));
    try testing.expectEqual(@as(usize, 4096), calcSegmentBufferSize(.numeric, 9830));
    try testing.expectEqual(LENGTH_OVERFLOW, calcSegmentBitLength(.numeric, 9831));

    // Alphanumeric
    try testing.expectEqual(@as(usize, 0), calcSegmentBufferSize(.alphanumeric, 0));
    try testing.expectEqual(@as(usize, 1), calcSegmentBufferSize(.alphanumeric, 1));
    try testing.expectEqual(@as(usize, 2), calcSegmentBufferSize(.alphanumeric, 2));
    try testing.expectEqual(@as(usize, 1012), calcSegmentBufferSize(.alphanumeric, 1472));
    try testing.expectEqual(@as(usize, 4096), calcSegmentBufferSize(.alphanumeric, 5957));
    try testing.expectEqual(LENGTH_OVERFLOW, calcSegmentBitLength(.alphanumeric, 5958));

    // Byte
    try testing.expectEqual(@as(usize, 0), calcSegmentBufferSize(.byte, 0));
    try testing.expectEqual(@as(usize, 1), calcSegmentBufferSize(.byte, 1));
    try testing.expectEqual(@as(usize, 1472), calcSegmentBufferSize(.byte, 1472));
    try testing.expectEqual(@as(usize, 4095), calcSegmentBufferSize(.byte, 4095));
    try testing.expectEqual(LENGTH_OVERFLOW, calcSegmentBitLength(.byte, 4096));

    // ECI
    try testing.expectEqual(@as(usize, 3), calcSegmentBufferSize(.eci, 0));
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testMakeBytes.
test "makeBytes against reference cases" {
    var buf: [3]u8 = undefined;

    const seg0 = makeBytes("", &buf);
    try testing.expectEqual(Mode.byte, seg0.mode);
    try testing.expectEqual(@as(usize, 0), seg0.num_chars);
    try testing.expectEqual(@as(usize, 0), seg0.bit_length);

    const data1 = [_]u8{0x00};
    const seg1 = makeBytes(&data1, &buf);
    try testing.expectEqual(@as(usize, 1), seg1.num_chars);
    try testing.expectEqual(@as(usize, 8), seg1.bit_length);
    try testing.expectEqual(@as(u8, 0x00), seg1.data[0]);

    const data3 = [_]u8{ 0xEF, 0xBB, 0xBF };
    const seg3 = makeBytes(&data3, &buf);
    try testing.expectEqual(@as(usize, 3), seg3.num_chars);
    try testing.expectEqual(@as(usize, 24), seg3.bit_length);
    try testing.expectEqualSlices(u8, &data3, seg3.data);
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testMakeNumeric.
test "makeNumeric against reference cases" {
    var buf: [5]u8 = undefined;

    const seg0 = makeNumeric("", &buf);
    try testing.expectEqual(Mode.numeric, seg0.mode);
    try testing.expectEqual(@as(usize, 0), seg0.num_chars);
    try testing.expectEqual(@as(usize, 0), seg0.bit_length);

    const seg1 = makeNumeric("9", &buf);
    try testing.expectEqual(@as(usize, 1), seg1.num_chars);
    try testing.expectEqual(@as(usize, 4), seg1.bit_length);
    try testing.expectEqual(@as(u8, 0x90), seg1.data[0]);

    const seg2 = makeNumeric("81", &buf);
    try testing.expectEqual(@as(usize, 2), seg2.num_chars);
    try testing.expectEqual(@as(usize, 7), seg2.bit_length);
    try testing.expectEqual(@as(u8, 0xA2), seg2.data[0]);

    const seg3 = makeNumeric("673", &buf);
    try testing.expectEqual(@as(usize, 3), seg3.num_chars);
    try testing.expectEqual(@as(usize, 10), seg3.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xA8, 0x40 }, seg3.data);

    const seg10 = makeNumeric("3141592653", &buf);
    try testing.expectEqual(@as(usize, 10), seg10.num_chars);
    try testing.expectEqual(@as(usize, 34), seg10.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x4E, 0x89, 0xF4, 0x24, 0xC0 }, seg10.data);
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testMakeAlphanumeric.
test "makeAlphanumeric against reference cases" {
    var buf: [3]u8 = undefined;

    const seg0 = makeAlphanumeric("", &buf);
    try testing.expectEqual(Mode.alphanumeric, seg0.mode);
    try testing.expectEqual(@as(usize, 0), seg0.num_chars);
    try testing.expectEqual(@as(usize, 0), seg0.bit_length);

    const seg1 = makeAlphanumeric("A", &buf);
    try testing.expectEqual(@as(usize, 1), seg1.num_chars);
    try testing.expectEqual(@as(usize, 6), seg1.bit_length);
    try testing.expectEqual(@as(u8, 0x28), seg1.data[0]);

    const seg2 = makeAlphanumeric("%:", &buf);
    try testing.expectEqual(@as(usize, 2), seg2.num_chars);
    try testing.expectEqual(@as(usize, 11), seg2.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDB, 0x40 }, seg2.data);

    const seg3 = makeAlphanumeric("Q R", &buf);
    try testing.expectEqual(@as(usize, 3), seg3.num_chars);
    try testing.expectEqual(@as(usize, 17), seg3.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x96, 0xCD, 0x80 }, seg3.data);
}

test "makeKanji with Madoka vector" {
    const madoka = "\xE3\x80\x8C\xE9\xAD\x94\xE6\xB3\x95\xE5\xB0\x91\xE5\xA5\xB3\xE3\x81\xBE\xE3\x81\xA9\xE3\x81\x8B\xE2\x98\x86\xE3\x83\x9E\xE3\x82\xAE\xE3\x82\xAB\xE3\x80\x8D\xE3\x81\xA3\xE3\x81\xA6\xE3\x80\x81\xE3\x80\x80\xD0\x98\xD0\x90\xD0\x98\xE3\x80\x80\xEF\xBD\x84\xEF\xBD\x85\xEF\xBD\x93\xEF\xBD\x95\xE3\x80\x80\xCE\xBA\xCE\xB1\xEF\xBC\x9F";
    var buf: [48]u8 = undefined;
    const seg = try makeKanji(madoka, &buf);

    try testing.expectEqual(Mode.kanji, seg.mode);
    try testing.expectEqual(@as(usize, 29), seg.num_chars);
    try testing.expectEqual(@as(usize, 377), seg.bit_length);

    const expected_bytes = [_]u8{
        0x01, 0xAC, 0x00, 0x9F, 0x80, 0xAE, 0xD5, 0x6B, 0x85, 0x70, 0x28, 0xE1,
        0x29, 0x02, 0xC8, 0x6F, 0x43, 0x1A, 0x18, 0xA0, 0x1B, 0x05, 0x04, 0x28,
        0x80, 0x01, 0x00, 0x00, 0x92, 0x44, 0x80, 0x24, 0x90, 0x00, 0x04, 0x10,
        0x20, 0xA1, 0x13, 0x08, 0xA8, 0x00, 0x04, 0x10, 0x1F, 0xF0, 0x04, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected_bytes, seg.data);

    // Buffer too small test
    var small_buf: [47]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, makeKanji(madoka, &small_buf));

    // Invalid character test (mixed)
    try testing.expectError(error.InvalidCharacter, makeKanji("まどかA", &buf));
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testMakeEci.
test "makeEci against reference cases" {
    var buf: [3]u8 = undefined;

    const seg1 = makeEci(127, &buf);
    try testing.expectEqual(Mode.eci, seg1.mode);
    try testing.expectEqual(@as(usize, 0), seg1.num_chars);
    try testing.expectEqual(@as(usize, 8), seg1.bit_length);
    try testing.expectEqual(@as(u8, 0x7F), seg1.data[0]);

    const seg2 = makeEci(10345, &buf);
    try testing.expectEqual(@as(usize, 16), seg2.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xA8, 0x69 }, seg2.data);

    const seg3 = makeEci(999999, &buf);
    try testing.expectEqual(@as(usize, 24), seg3.bit_length);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xCF, 0x42, 0x3F }, seg3.data);
}

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testGetTotalBits.
test "getTotalBits against reference cases" {
    try testing.expectEqual(@as(usize, 0), getTotalBits(&[_]Segment{}, 1));
    try testing.expectEqual(@as(usize, 0), getTotalBits(&[_]Segment{}, 40));

    // Single Byte segment: 3 bytes payload = 24 bits.
    // Overhead = 4 (mode) + charCountBits.
    // v2: ccbits=8 -> 4 + 8 + 24 = 36.
    // v10: ccbits=16 -> 4 + 16 + 24 = 44.
    // v39: ccbits=16 -> 4 + 16 + 24 = 44.
    const byte_seg = [_]Segment{
        .{ .mode = .byte, .num_chars = 3, .data = &.{}, .bit_length = 24 },
    };
    try testing.expectEqual(@as(usize, 36), getTotalBits(&byte_seg, 2));
    try testing.expectEqual(@as(usize, 44), getTotalBits(&byte_seg, 10));
    try testing.expectEqual(@as(usize, 44), getTotalBits(&byte_seg, 39));

    // Mixed segments: ECI, Numeric(7), Alphanumeric(1), Kanji(4)
    // Payloads: ECI=8, Num=24, Alnum=6, Kanji=52 -> total payload = 90
    // v9 (v1-9):   ECI: 4+0, Num: 4+10, Alnum: 4+9,  Kanji: 4+8  -> overhead=43 -> total=133
    // v21 (v10-26): ECI: 4+0, Num: 4+12, Alnum: 4+11, Kanji: 4+10 -> overhead=49 -> total=139
    // v27 (v27-40): ECI: 4+0, Num: 4+14, Alnum: 4+13, Kanji: 4+12 -> overhead=55 -> total=145
    const mixed_segs = [_]Segment{
        .{ .mode = .eci, .num_chars = 0, .data = &.{}, .bit_length = 8 },
        .{ .mode = .numeric, .num_chars = 7, .data = &.{}, .bit_length = 24 },
        .{ .mode = .alphanumeric, .num_chars = 1, .data = &.{}, .bit_length = 6 },
        .{ .mode = .kanji, .num_chars = 4, .data = &.{}, .bit_length = 52 },
    };
    try testing.expectEqual(@as(usize, 133), getTotalBits(&mixed_segs, 9));
    try testing.expectEqual(@as(usize, 139), getTotalBits(&mixed_segs, 21));
    try testing.expectEqual(@as(usize, 145), getTotalBits(&mixed_segs, 27));

    // Overflow when character count does not fit in ccbits (e.g., 300 chars in Byte mode at v1 where ccbits=8)
    const overflow_seg = [_]Segment{
        .{ .mode = .byte, .num_chars = 300, .data = &.{}, .bit_length = 2400 },
    };
    try testing.expectEqual(LENGTH_OVERFLOW, getTotalBits(&overflow_seg, 1));
    // At v10, ccbits=16 so 300 chars fits:
    try testing.expect(getTotalBits(&overflow_seg, 10) != LENGTH_OVERFLOW);
}

test "FNC1 first and second position segment construction" {
    // 1. FNC1 in first position
    const seg_fnc1_1 = makeFnc1First();
    try testing.expectEqual(Mode.fnc1_first, seg_fnc1_1.mode);
    try testing.expectEqual(@as(usize, 0), seg_fnc1_1.num_chars);
    try testing.expectEqual(@as(usize, 0), seg_fnc1_1.bit_length);
    // Overhead = 4 (mode) + 0 (ccbits) + 0 (payload) = 4 bits
    try testing.expectEqual(@as(usize, 4), getTotalBits(&[_]Segment{seg_fnc1_1}, 1));
    try testing.expectEqual(@as(usize, 4), getTotalBits(&[_]Segment{seg_fnc1_1}, 20));
    try testing.expectEqual(@as(usize, 4), getTotalBits(&[_]Segment{seg_fnc1_1}, 40));

    // 2. FNC1 in second position
    var buf_fnc1: [1]u8 = undefined;
    const app_ind_a = try appIndicatorFromChar('A');
    try testing.expectEqual(@as(u8, 165), app_ind_a); // 'A' = 65 + 100 = 165
    const seg_fnc1_2 = makeFnc1Second(app_ind_a, &buf_fnc1);
    try testing.expectEqual(Mode.fnc1_second, seg_fnc1_2.mode);
    try testing.expectEqual(@as(usize, 0), seg_fnc1_2.num_chars);
    try testing.expectEqual(@as(usize, 8), seg_fnc1_2.bit_length);
    try testing.expectEqual(@as(u8, 165), seg_fnc1_2.data[0]);
    // Overhead = 4 (mode) + 0 (ccbits) + 8 (app indicator payload) = 12 bits
    try testing.expectEqual(@as(usize, 12), getTotalBits(&[_]Segment{seg_fnc1_2}, 1));
    try testing.expectEqual(@as(usize, 12), getTotalBits(&[_]Segment{seg_fnc1_2}, 20));
    try testing.expectEqual(@as(usize, 12), getTotalBits(&[_]Segment{seg_fnc1_2}, 40));

    // 3. Application indicator helpers
    const app_ind_num = try appIndicatorFromDigits("05");
    try testing.expectEqual(@as(u8, 5), app_ind_num);
    const app_ind_num99 = try appIndicatorFromDigits("99");
    try testing.expectEqual(@as(u8, 99), app_ind_num99);
    try testing.expectError(error.InvalidApplicationIndicator, appIndicatorFromDigits("9a"));

    const app_ind_z = try appIndicatorFromChar('z');
    try testing.expectEqual(@as(u8, 222), app_ind_z); // 'z' = 122 + 100 = 222
    try testing.expectError(error.InvalidApplicationIndicator, appIndicatorFromChar('1'));
    try testing.expectError(error.InvalidApplicationIndicator, appIndicatorFromChar('@'));
}
