//! Dynamic programming mode optimizer for QR Code Model 2.
//! Finds the globally optimal multi-segment mode assignment
//! (Numeric, Alphanumeric, Byte, Kanji) to minimize total bit length.
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT):
//!     java/src/main/java/io/nayuki/qrcodegen/QrSegmentAdvanced.java
//!     (functions computeCharacterModes, makeSegmentsOptimally, splitIntoSegments)
//!   - ISO/IEC 18004:2015 Section 7.4 (Encoding modes)

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");
const segment = @import("segment.zig");
const kanji = @import("kanji.zig");
const BitBuffer = @import("BitBuffer.zig").BitBuffer;

const Mode = types.Mode;
const Segment = segment.Segment;

/// Returns the maximum possible characters encodable in QR Model 2 for a given max_version.
/// This corresponds to Version X-L in pure Numeric mode:
///   - Version 6-L: 136 data codewords * 8 = 1088 bits - 14 bit header = 1074 bits -> 322 digits.
///   - Version 10-L: 274 data codewords * 8 = 2192 bits - 16 bit header = 2176 bits -> 652 digits.
///   - Version 40-L: 2956 data codewords * 8 = 23648 bits - 18 bit header = 23630 bits -> 7089 digits.
pub fn maxCharsForTier(comptime max_version: u8) usize {
    if (max_version <= 6) return 322;
    if (max_version <= 10) return 652;
    return 7089;
}

/// The 4 standard encoding modes in order of the DP state index:
/// 0: Byte, 1: Alphanumeric, 2: Numeric, 3: Kanji.
pub const mode_types = [4]Mode{ .byte, .alphanumeric, .numeric, .kanji };

pub const INFINITY_COST: u32 = 0x3FFF_FFFF;

/// Computes the optimal mode per character using forward dynamic programming with costs in 1/6 bits.
/// Backtracking is stored in `bt_buf` (1 byte per codepoint, packing 4 2-bit predecessors).
/// Returns the number of codepoints, and writes the optimal mode for codepoint `i` into `bt_buf[i]`.
pub fn computeCharacterModes(
    text: []const u8,
    version: u8,
    enable_kanji: bool,
    bt_buf: []u8,
) !usize {
    var iter = (std.unicode.Utf8View.init(text) catch return error.InvalidUtf8).iterator();

    // Count codepoints and verify capacity
    var count: usize = 0;
    while (iter.nextCodepoint()) |_| {
        count += 1;
    }
    if (count == 0) return 0;
    if (count > bt_buf.len) return error.DataTooLong;

    // Segment header costs in 1/6 bits: (4 + numCharCountBits) * 6
    var head_costs: [4]u32 = undefined;
    inline for (0..4) |j| {
        head_costs[j] = (@as(u32, 4) + segment.numCharCountBits(mode_types[j], version)) * 6;
    }

    // prev_costs[j] holds minimum 1/6 bits to encode prefix and end in mode_types[j]
    var prev_costs: [4]u32 = head_costs;
    if (!enable_kanji) {
        prev_costs[3] = INFINITY_COST;
    }

    iter = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    var i: usize = 0;
    while (iter.nextCodepoint()) |cp| : (i += 1) {
        var cur_costs: [4]u32 = @splat(INFINITY_COST);
        var cm: [4]u2 = [_]u2{ 0, 1, 2, 3 };

        // 0: Byte mode extension
        const utf8_len = std.unicode.utf8CodepointSequenceLength(cp) catch return error.InvalidUtf8;
        if (prev_costs[0] != INFINITY_COST) {
            cur_costs[0] = prev_costs[0] + @as(u32, utf8_len) * 8 * 6;
            cm[0] = 0;
        }

        // 1: Alphanumeric mode extension
        if (cp <= 0x7F and std.mem.indexOfScalar(u8, segment.ALPHANUMERIC_CHARSET, @intCast(cp)) != null) {
            if (prev_costs[1] != INFINITY_COST) {
                cur_costs[1] = prev_costs[1] + 33; // 5.5 bits * 6
                cm[1] = 1;
            }
        }

        // 2: Numeric mode extension
        if (cp >= '0' and cp <= '9') {
            if (prev_costs[2] != INFINITY_COST) {
                cur_costs[2] = prev_costs[2] + 20; // 3.333 bits * 6
                cm[2] = 2;
            }
        }

        // 3: Kanji mode extension
        if (enable_kanji and kanji.toQrKanji(cp) != null) {
            if (prev_costs[3] != INFINITY_COST) {
                cur_costs[3] = prev_costs[3] + 78; // 13 bits * 6
                cm[3] = 3;
            }
        }

        // Start new segment / switch mode at end of character i
        const active_modes: usize = if (enable_kanji) 4 else 3;
        var j: usize = 0;
        while (j < active_modes) : (j += 1) {
            var k: usize = 0;
            while (k < active_modes) : (k += 1) {
                if (cur_costs[k] != INFINITY_COST) {
                    const new_cost = ((cur_costs[k] + 5) / 6) * 6 + head_costs[j];
                    if (new_cost < cur_costs[j]) {
                        cur_costs[j] = new_cost;
                        cm[j] = @intCast(k);
                    }
                }
            }
        }

        // Pack the 4 2-bit predecessors into 1 byte of bt_buf[i]
        bt_buf[i] = @as(u8, cm[0]) | (@as(u8, cm[1]) << 2) | (@as(u8, cm[2]) << 4) | (@as(u8, cm[3]) << 6);
        prev_costs = cur_costs;
    }

    // Find optimal ending mode
    const active_modes: usize = if (enable_kanji) 4 else 3;
    var min_cost: u32 = INFINITY_COST;
    var cur_mode: u2 = 0;
    for (0..active_modes) |j| {
        if (prev_costs[j] < min_cost) {
            min_cost = prev_costs[j];
            cur_mode = @intCast(j);
        }
    }
    if (min_cost == INFINITY_COST) return error.DataTooLong;

    // Trace backwards and write final mode directly into bt_buf[idx]
    var idx: usize = count;
    while (idx > 0) {
        idx -= 1;
        const packed_byte = bt_buf[idx];
        const prev_mode: u2 = @truncate((packed_byte >> (@as(u3, cur_mode) * 2)) & 0x3);
        cur_mode = prev_mode;
        bt_buf[idx] = cur_mode;
    }

    return count;
}

/// Makes optimal segments by running the DP mode optimizer and serializing
/// each segment's payload into `seg_buf`.
/// Writes the produced `Segment` structs into `segs_out` and returns the segment count.
pub fn makeOptimizedSegments(
    text: []const u8,
    version: u8,
    enable_kanji: bool,
    segs_out: []Segment,
    seg_buf: []u8,
    bt_buf: []u8,
) !usize {
    const num_cps = try computeCharacterModes(text, version, enable_kanji, bt_buf);
    if (num_cps == 0) return 0;

    var seg_count: usize = 0;
    var buf_offset: usize = 0;

    var iter = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    var cur_mode: Mode = mode_types[bt_buf[0]];
    var seg_start_byte: usize = 0;
    var seg_char_count: usize = 0;
    var text_byte_pos: usize = 0;

    var i: usize = 0;
    while (iter.nextCodepointSlice()) |slice| : (i += 1) {
        const char_mode = mode_types[bt_buf[i]];
        if (char_mode != cur_mode) {
            // Flush current segment
            if (seg_count >= segs_out.len) return error.BufferTooSmall;
            const seg_text = text[seg_start_byte..text_byte_pos];
            const needed = segment.calcSegmentBufferSize(cur_mode, seg_char_count);
            if (buf_offset + needed > seg_buf.len) return error.DataTooLong;

            segs_out[seg_count] = try makeSegmentForMode(cur_mode, seg_text, seg_buf[buf_offset..]);
            buf_offset += (segs_out[seg_count].bit_length + 7) / 8;
            seg_count += 1;

            // Start new segment
            cur_mode = char_mode;
            seg_start_byte = text_byte_pos;
            seg_char_count = 0;
        }
        seg_char_count += 1;
        text_byte_pos += slice.len;
    }

    // Flush final segment
    if (seg_count >= segs_out.len) return error.BufferTooSmall;
    const final_text = text[seg_start_byte..text_byte_pos];
    const needed = segment.calcSegmentBufferSize(cur_mode, seg_char_count);
    if (buf_offset + needed > seg_buf.len) return error.DataTooLong;

    segs_out[seg_count] = try makeSegmentForMode(cur_mode, final_text, seg_buf[buf_offset..]);
    seg_count += 1;

    return seg_count;
}

fn makeSegmentForMode(mode: Mode, text: []const u8, buf: []u8) !Segment {
    return switch (mode) {
        .numeric => segment.makeNumeric(text, buf),
        .alphanumeric => segment.makeAlphanumeric(text, buf),
        .byte => segment.makeBytes(text, buf),
        .kanji => try segment.makeKanji(text, buf),
        else => unreachable,
    };
}

const testing = std.testing;

test "optimal segmentation for ABC123日本語 against Nayuki" {
    const text = "ABC123日本語";
    var bt_buf: [322]u8 = undefined;
    var segs: [16]Segment = undefined;
    var seg_buf: [1000]u8 = undefined;

    const count = try makeOptimizedSegments(text, 1, true, &segs, &seg_buf, &bt_buf);
    try testing.expectEqual(@as(usize, 2), count);

    // Segment 0: Alphanumeric "ABC123" (len = 6)
    try testing.expectEqual(Mode.alphanumeric, segs[0].mode);
    try testing.expectEqual(@as(usize, 6), segs[0].num_chars);

    // Segment 1: Kanji "日本語" (len = 3)
    try testing.expectEqual(Mode.kanji, segs[1].mode);
    try testing.expectEqual(@as(usize, 3), segs[1].num_chars);
}

test "optimal segmentation with long numbers ABC123456789012日本語" {
    const text = "ABC123456789012日本語";
    var bt_buf: [322]u8 = undefined;
    var segs: [16]Segment = undefined;
    var seg_buf: [1000]u8 = undefined;

    const count = try makeOptimizedSegments(text, 1, true, &segs, &seg_buf, &bt_buf);
    try testing.expectEqual(@as(usize, 3), count);

    try testing.expectEqual(Mode.alphanumeric, segs[0].mode);
    try testing.expectEqual(@as(usize, 3), segs[0].num_chars);

    try testing.expectEqual(Mode.numeric, segs[1].mode);
    try testing.expectEqual(@as(usize, 12), segs[1].num_chars);

    try testing.expectEqual(Mode.kanji, segs[2].mode);
    try testing.expectEqual(@as(usize, 3), segs[2].num_chars);
}
