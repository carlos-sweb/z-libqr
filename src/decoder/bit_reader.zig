//! MSB-first bit stream reader for QR Code segment decoding.
//!
//! Matches the bit-packing order of BitBuffer.zig and ISO/IEC 18004.
//! When bits are exhausted, methods return error.UnexpectedEndOfStream rather than reading garbage.

const std = @import("std");

pub const BitReader = struct {
    bytes: []const u8,
    bit_offset: usize,

    pub fn init(bytes: []const u8) BitReader {
        return .{
            .bytes = bytes,
            .bit_offset = 0,
        };
    }

    /// Returns the number of bits remaining in the stream.
    pub inline fn bitsRemaining(self: *const BitReader) usize {
        const total_bits = self.bytes.len * 8;
        if (self.bit_offset >= total_bits) return 0;
        return total_bits - self.bit_offset;
    }

    /// Reads `count` bits MSB-first and advances the bit offset.
    /// Returns error.UnexpectedEndOfStream if fewer than `count` bits remain.
    pub fn readBits(self: *BitReader, comptime T: type, count: u8) error{UnexpectedEndOfStream}!T {
        std.debug.assert(count <= @bitSizeOf(T));
        if (count == 0) return 0;

        if (self.bitsRemaining() < count) {
            return error.UnexpectedEndOfStream;
        }

        var accum: u64 = 0;
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const byte_idx = self.bit_offset >> 3;
            const bit_idx: u3 = @intCast(7 - (self.bit_offset & 7));
            const bit: u1 = @intCast((self.bytes[byte_idx] >> bit_idx) & 1);
            accum = (accum << 1) | bit;
            self.bit_offset += 1;
        }
        return @truncate(accum);
    }

    /// Peeks `count` bits MSB-first without advancing the bit offset.
    pub fn peekBits(self: *const BitReader, comptime T: type, count: u8) error{UnexpectedEndOfStream}!T {
        var copy = self.*;
        return copy.readBits(T, count);
    }

    /// Skips `count` bits forward.
    pub fn skipBits(self: *BitReader, count: usize) error{UnexpectedEndOfStream}!void {
        if (self.bitsRemaining() < count) {
            return error.UnexpectedEndOfStream;
        }
        self.bit_offset += count;
    }
};

const testing = std.testing;

test "BitReader: sequential reads and exhaustion" {
    const data = [_]u8{ 0xAB, 0xCD }; // 10101011 11001101
    var reader = BitReader.init(&data);

    try testing.expectEqual(@as(usize, 16), reader.bitsRemaining());

    // 0xAB = 1010 1011
    const b4 = try reader.readBits(u4, 4); // 1010 = 10 (0xA)
    try testing.expectEqual(@as(u4, 0xA), b4);
    try testing.expectEqual(@as(usize, 12), reader.bitsRemaining());

    // Next 4 bits = 1011 = 11 (0xB)
    const peeked = try reader.peekBits(u4, 4);
    try testing.expectEqual(@as(u4, 0xB), peeked);
    try testing.expectEqual(@as(usize, 12), reader.bitsRemaining());

    const b4_2 = try reader.readBits(u4, 4);
    try testing.expectEqual(@as(u4, 0xB), b4_2);
    try testing.expectEqual(@as(usize, 8), reader.bitsRemaining());

    // 0xCD = 11001101 -> read 8 bits
    const b8 = try reader.readBits(u8, 8);
    try testing.expectEqual(@as(u8, 0xCD), b8);
    try testing.expectEqual(@as(usize, 0), reader.bitsRemaining());

    // Exhausted
    try testing.expectError(error.UnexpectedEndOfStream, reader.readBits(u1, 1));
}
