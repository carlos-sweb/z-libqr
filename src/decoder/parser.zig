//! Segment parser for QR Code Model 2.
//!
//! Parses data streams conforming to ISO/IEC 18004:2015 into decoded strings and metadata.
//! Uses segment.numCharCountBits and segment.ALPHANUMERIC_CHARSET as single sources of truth.

const std = @import("std");
const types = @import("../types.zig");
const segment = @import("../segment.zig");
const bit_reader = @import("bit_reader.zig");

pub const BitReader = bit_reader.BitReader;

pub const ParseError = error{
    UnexpectedEndOfStream,
    InvalidMode,
    InvalidNumericValue,
    InvalidAlphanumericValue,
    InvalidKanjiValue,
    InvalidEciAssignment,
    BufferTooSmall,
};

/// Metadata extracted during segment parsing (separate from decoded payload string).
pub const DecodeMetadata = struct {
    /// Bitfield of modes present:
    ///   - 0x01: Numeric
    ///   - 0x02: Alphanumeric
    ///   - 0x04: Byte
    ///   - 0x08: Kanji
    ///   - 0x10: ECI
    ///   - 0x20: FNC1
    ///   - 0x40: Structured Append
    modes_used: u8 = 0,

    /// ECI assignment value (0..999999), if present.
    eci: ?u32 = null,

    /// FNC1 operating mode (.first or .second), if present.
    fnc1_mode: ?types.Fnc1Mode = null,

    /// FNC1 Application Indicator byte (0..255), if fnc1_mode == .second.
    fnc1_app_indicator: ?u8 = null,

    /// Structured Append fragment header, if present.
    sa: ?types.StructuredAppend = null,
};

pub const ParseResult = struct {
    data: []const u8,
    metadata: DecodeMetadata,
};

/// Parses segments from `data_codewords` for QR version `version` (1..40) into `out_buffer`.
/// Stops when the terminator (0000) is reached or when fewer than 4 bits remain in the bitstream.
pub fn parseSegments(
    data_codewords: []const u8,
    version: u8,
    out_buffer: []u8,
) ParseError!ParseResult {
    var reader = BitReader.init(data_codewords);
    var out_idx: usize = 0;
    var meta = DecodeMetadata{};

    while (reader.bitsRemaining() >= 4) {
        const mode_bits = try reader.readBits(u4, 4);
        if (mode_bits == 0) {
            // Mode 0000 = Terminator (ISO/IEC 18004:2015 §7.4.9)
            break;
        }

        switch (mode_bits) {
            0x1 => { // Numeric
                meta.modes_used |= 0x01;
                const cc_bits = segment.numCharCountBits(.numeric, version);
                const count = try reader.readBits(usize, cc_bits);
                var rem = count;
                while (rem >= 3) {
                    const val = try reader.readBits(u16, 10);
                    if (val >= 1000) return error.InvalidNumericValue;
                    if (out_idx + 3 > out_buffer.len) return error.BufferTooSmall;
                    out_buffer[out_idx] = @intCast('0' + (val / 100));
                    out_buffer[out_idx + 1] = @intCast('0' + ((val / 10) % 10));
                    out_buffer[out_idx + 2] = @intCast('0' + (val % 10));
                    out_idx += 3;
                    rem -= 3;
                }
                if (rem == 2) {
                    const val = try reader.readBits(u8, 7);
                    if (val >= 100) return error.InvalidNumericValue;
                    if (out_idx + 2 > out_buffer.len) return error.BufferTooSmall;
                    out_buffer[out_idx] = @intCast('0' + (val / 10));
                    out_buffer[out_idx + 1] = @intCast('0' + (val % 10));
                    out_idx += 2;
                    rem = 0;
                } else if (rem == 1) {
                    const val = try reader.readBits(u8, 4);
                    if (val >= 10) return error.InvalidNumericValue;
                    if (out_idx + 1 > out_buffer.len) return error.BufferTooSmall;
                    out_buffer[out_idx] = @intCast('0' + val);
                    out_idx += 1;
                    rem = 0;
                }
            },
            0x2 => { // Alphanumeric
                meta.modes_used |= 0x02;
                const cc_bits = segment.numCharCountBits(.alphanumeric, version);
                const count = try reader.readBits(usize, cc_bits);
                var rem = count;
                while (rem >= 2) {
                    const val = try reader.readBits(u16, 11);
                    if (val >= 45 * 45) return error.InvalidAlphanumericValue;
                    if (out_idx + 2 > out_buffer.len) return error.BufferTooSmall;
                    const c1 = val / 45;
                    const c2 = val % 45;
                    out_buffer[out_idx] = segment.ALPHANUMERIC_CHARSET[c1];
                    out_buffer[out_idx + 1] = segment.ALPHANUMERIC_CHARSET[c2];
                    out_idx += 2;
                    rem -= 2;
                }
                if (rem == 1) {
                    const val = try reader.readBits(u8, 6);
                    if (val >= 45) return error.InvalidAlphanumericValue;
                    if (out_idx + 1 > out_buffer.len) return error.BufferTooSmall;
                    out_buffer[out_idx] = segment.ALPHANUMERIC_CHARSET[val];
                    out_idx += 1;
                    rem = 0;
                }
            },
            0x4 => { // Byte
                meta.modes_used |= 0x04;
                const cc_bits = segment.numCharCountBits(.byte, version);
                const count = try reader.readBits(usize, cc_bits);
                if (out_idx + count > out_buffer.len) return error.BufferTooSmall;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    out_buffer[out_idx + i] = try reader.readBits(u8, 8);
                }
                out_idx += count;
            },
            0x8 => { // Kanji (emits pre-encoded Shift-JIS as 2 bytes per character)
                meta.modes_used |= 0x08;
                const cc_bits = segment.numCharCountBits(.kanji, version);
                const count = try reader.readBits(usize, cc_bits);
                if (out_idx + count * 2 > out_buffer.len) return error.BufferTooSmall;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const qr_val = try reader.readBits(u13, 13);
                    const high = qr_val / 0xC0;
                    const low = qr_val % 0xC0;
                    const diff: u16 = (@as(u16, high) << 8) | low;
                    const sjis: u16 = if (high <= 0x1E)
                        diff +% 0x8140
                    else if (high <= 0x2A)
                        diff +% 0xC140
                    else
                        return error.InvalidKanjiValue;

                    out_buffer[out_idx] = @truncate(sjis >> 8);
                    out_buffer[out_idx + 1] = @truncate(sjis);
                    out_idx += 2;
                }
            },
            0x7 => { // ECI Assignment
                meta.modes_used |= 0x10;
                const b0 = try reader.readBits(u1, 1);
                var eci_val: u32 = 0;
                if (b0 == 0) {
                    eci_val = try reader.readBits(u32, 7);
                } else {
                    const b1 = try reader.readBits(u1, 1);
                    if (b1 == 0) {
                        eci_val = try reader.readBits(u32, 14);
                    } else {
                        const b2 = try reader.readBits(u1, 1);
                        if (b2 == 0) {
                            eci_val = try reader.readBits(u32, 21);
                        } else {
                            return error.InvalidEciAssignment;
                        }
                    }
                }
                meta.eci = eci_val;
            },
            0x5 => { // FNC1 First Position
                meta.modes_used |= 0x20;
                meta.fnc1_mode = .first;
            },
            0x9 => { // FNC1 Second Position
                meta.modes_used |= 0x20;
                meta.fnc1_mode = .second;
                meta.fnc1_app_indicator = try reader.readBits(u8, 8);
            },
            0x3 => { // Structured Append
                meta.modes_used |= 0x40;
                const pos = try reader.readBits(u4, 4);
                const tot = try reader.readBits(u4, 4);
                const parity = try reader.readBits(u8, 8);
                meta.sa = .{
                    .position = pos,
                    .total = tot,
                    .parity = parity,
                };
            },
            else => return error.InvalidMode,
        }
    }

    return .{
        .data = out_buffer[0..out_idx],
        .metadata = meta,
    };
}

const testing = std.testing;
const tables = @import("../tables.zig");
const BitBuffer = @import("../BitBuffer.zig").BitBuffer;

test "parseSegments: exact capacity without terminator" {
    // Construct a byte stream that fills 16 data codewords exactly without terminator
    // Version 1-M has 16 data codewords = 128 bits.
    // In Byte mode: 4 (mode) + 8 (cc) + 14 * 8 = 124 bits + 4 bits terminator = 128 bits.
    // But with 14 bytes + 0-bit padding, it exactly occupies 124 bits, leaving 4 bits for 0000.
    // What if we encode 15 characters in Alphanumeric mode?
    // Mode = 4 bits, count = 9 bits. 14 chars in 7 pairs = 7 * 11 = 77 bits. 1 char = 6 bits. Total = 4 + 9 + 77 + 6 = 96 bits = exactly 12 bytes!
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    var bb = BitBuffer.init(&buf);
    bb.appendBits(0x2, 4); // Alphanumeric
    bb.appendBits(15, 9); // 15 characters
    // "0123456789ABCDE"
    // Pairs: (0,1), (2,3), (4,5), (6,7), (8,9), (A,B), (C,D), single E
    const pairs = [_]struct { c1: u8, c2: u8 }{
        .{ .c1 = '0', .c2 = '1' },
        .{ .c1 = '2', .c2 = '3' },
        .{ .c1 = '4', .c2 = '5' },
        .{ .c1 = '6', .c2 = '7' },
        .{ .c1 = '8', .c2 = '9' },
        .{ .c1 = 'A', .c2 = 'B' },
        .{ .c1 = 'C', .c2 = 'D' },
    };
    for (pairs) |p| {
        const idx1 = std.mem.indexOfScalar(u8, segment.ALPHANUMERIC_CHARSET, p.c1).?;
        const idx2 = std.mem.indexOfScalar(u8, segment.ALPHANUMERIC_CHARSET, p.c2).?;
        bb.appendBits(@as(u32, @intCast(idx1 * 45 + idx2)), 11);
    }
    const ie = std.mem.indexOfScalar(u8, segment.ALPHANUMERIC_CHARSET, 'E').?;
    bb.appendBits(@as(u32, @intCast(ie)), 6);

    try testing.expectEqual(@as(usize, 96), bb.bit_length);

    // Test slice containing exactly 96 bits (12 bytes) with 0 bits left
    var out: [32]u8 = undefined;
    const res = try parseSegments(buf[0..12], 1, &out);
    try testing.expectEqualStrings("0123456789ABCDE", res.data);
    try testing.expectEqual(@as(u8, 0x02), res.metadata.modes_used);
}
