//! Kanji encoding support (JIS X 0208 / Shift-JIS to 13-bit QR Kanji mode).
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT):
//!     java/src/main/java/io/nayuki/qrcodegen/QrSegmentAdvanced.java
//!   - ISO/IEC 18004:2015 Section 7.4.6 (Kanji mode)

const std = @import("std");
const kanji_table = @import("kanji_table.zig");

/// Converts a Unicode codepoint to its 13-bit QR Kanji mode value.
/// Returns null if the codepoint is not in JIS X 0208.
/// Source: nayuki/QR-Code-generator, QrSegmentAdvanced.java, UNICODE_TO_QR_KANJI.
pub fn toQrKanji(cp: u21) ?u13 {
    // Quick rejection: min and max JIS X 0208 Unicode codepoints
    if (cp < 0x005C or cp > 0xFFE5) return null;

    var left: usize = 0;
    var right: usize = kanji_table.ENTRY_COUNT;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const entry = kanji_table.unicode_to_qr_kanji[mid];
        const mid_cp = kanji_table.getUnicode(entry);
        if (mid_cp == cp) {
            return kanji_table.getQrKanji(entry);
        } else if (mid_cp < cp) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return null;
}

/// Checks if all characters in the UTF-8 encoded text can be represented in QR Kanji mode.
/// Returns false if text is empty, contains invalid UTF-8, or contains codepoints outside JIS X 0208.
/// Source: nayuki/QR-Code-generator, QrSegmentAdvanced.java, isEncodableAsKanji.
pub fn isKanji(text: []const u8) bool {
    if (text.len == 0) return false;
    var iter = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (toQrKanji(cp) == null) return false;
    }
    return true;
}

/// Counts the number of Kanji characters in `text`.
/// Returns error.InvalidUtf8 if `text` is not valid UTF-8,
/// or error.InvalidCharacter if any character cannot be represented in Kanji mode.
pub fn countKanji(text: []const u8) !usize {
    var iter = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();
    var count: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        if (toQrKanji(cp) == null) return error.InvalidCharacter;
        count += 1;
    }
    return count;
}

const testing = std.testing;

test "toQrKanji lookups" {
    // Check known characters from Madoka
    try testing.expectEqual(@as(?u13, 0x0035), toQrKanji(0x300C)); // 「
    try testing.expectEqual(@as(?u13, 0x1002), toQrKanji(0x9B54)); // 魔
    try testing.expectEqual(@as(?u13, 0x0FC0), toQrKanji(0x6CD5)); // 法
    try testing.expectEqual(@as(?u13, 0x0AED), toQrKanji(0x5C11)); // 少
    try testing.expectEqual(@as(?u13, 0x0AD7), toQrKanji(0x5973)); // 女
    try testing.expectEqual(@as(?u13, 0x0000), toQrKanji(0x3000)); // 　 (ideographic space)
    try testing.expectEqual(@as(?u13, 0x0240), toQrKanji(0x0410)); // А (Cyrillic A)
    try testing.expectEqual(@as(?u13, 0x0008), toQrKanji(0xFF1F)); // ？

    // Non-Kanji ASCII
    try testing.expectEqual(@as(?u13, null), toQrKanji('A'));
    try testing.expectEqual(@as(?u13, null), toQrKanji('0'));
    try testing.expectEqual(@as(?u13, null), toQrKanji(' '));

    // Emoji / outside JIS X 0208
    try testing.expectEqual(@as(?u13, null), toQrKanji(0x1F389)); // Party popper 🎉
}

test "isKanji validation" {
    // Empty
    try testing.expect(!isKanji(""));

    // Pure ASCII
    try testing.expect(!isKanji("HELLO"));
    try testing.expect(!isKanji("12345"));

    // Madoka UTF-8
    const madoka = "\xE3\x80\x8C\xE9\xAD\x94\xE6\xB3\x95\xE5\xB0\x91\xE5\xA5\xB3\xE3\x81\xBE\xE3\x81\xA9\xE3\x81\x8B\xE2\x98\x86\xE3\x83\x9E\xE3\x82\xAE\xE3\x82\xAB\xE3\x80\x8D\xE3\x81\xA3\xE3\x81\xA6\xE3\x80\x81\xE3\x80\x80\xD0\x98\xD0\x90\xD0\x98\xE3\x80\x80\xEF\xBD\x84\xEF\xBD\x85\xEF\xBD\x93\xEF\xBD\x95\xE3\x80\x80\xCE\xBA\xCE\xB1\xEF\xBC\x9F";
    try testing.expect(isKanji(madoka));
    try testing.expectEqual(@as(usize, 29), try countKanji(madoka));

    // Mixed
    try testing.expect(!isKanji("HELLO まどか"));

    // Outside JIS X 0208
    try testing.expect(!isKanji("まどか🎉"));
}
