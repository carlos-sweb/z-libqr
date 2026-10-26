//! BitBuffer for bit-level appending into a caller-provided byte slice.
//!
//! Source: nayuki/QR-Code-generator (MIT), c/qrcodegen.c, function appendBitsToBuffer.

const std = @import("std");

pub const BitBuffer = struct {
    buffer: []u8,
    bit_length: usize,

    pub fn init(buffer: []u8) BitBuffer {
        return .{
            .buffer = buffer,
            .bit_length = 0,
        };
    }

    /// Appends the lowest `num_bits` of `val` to `buffer`, big-endian.
    /// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function appendBitsToBuffer.
    pub fn appendBits(self: *BitBuffer, val: u32, num_bits: u8) void {
        std.debug.assert(num_bits <= 32);
        if (num_bits < 32) {
            std.debug.assert((val >> @intCast(num_bits)) == 0);
        }

        var i: i32 = @as(i32, num_bits) - 1;
        while (i >= 0) : (i -= 1) {
            const byte_idx = self.bit_length >> 3;
            std.debug.assert(byte_idx < self.buffer.len);
            const bit = ((val >> @intCast(i)) & 1);
            const shift: u3 = @intCast(7 - (self.bit_length & 7));
            self.buffer[byte_idx] |= @as(u8, @intCast(bit)) << shift;
            self.bit_length += 1;
        }
    }
};

const testing = std.testing;

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testAppendBitsToBuffer.
test "appendBitsToBuffer against reference cases" {
    // Case 1
    {
        var buf: [1]u8 = @splat(0);
        var bb = BitBuffer.init(&buf);

        bb.appendBits(0, 0);
        try testing.expectEqual(@as(usize, 0), bb.bit_length);
        try testing.expectEqual(@as(u8, 0), buf[0]);

        bb.appendBits(1, 1);
        try testing.expectEqual(@as(usize, 1), bb.bit_length);
        try testing.expectEqual(@as(u8, 0x80), buf[0]);

        bb.appendBits(0, 1);
        try testing.expectEqual(@as(usize, 2), bb.bit_length);
        try testing.expectEqual(@as(u8, 0x80), buf[0]);

        bb.appendBits(5, 3);
        try testing.expectEqual(@as(usize, 5), bb.bit_length);
        try testing.expectEqual(@as(u8, 0xA8), buf[0]);

        bb.appendBits(6, 3);
        try testing.expectEqual(@as(usize, 8), bb.bit_length);
        try testing.expectEqual(@as(u8, 0xAE), buf[0]);
    }

    // Case 2
    {
        var buf: [6]u8 = @splat(0);
        var bb = BitBuffer.init(&buf);

        bb.appendBits(16942, 16);
        try testing.expectEqual(@as(usize, 16), bb.bit_length);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x2E, 0x00, 0x00, 0x00, 0x00 }, &buf);

        bb.appendBits(10, 7);
        try testing.expectEqual(@as(usize, 23), bb.bit_length);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x2E, 0x14, 0x00, 0x00, 0x00 }, &buf);

        bb.appendBits(15, 4);
        try testing.expectEqual(@as(usize, 27), bb.bit_length);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x2E, 0x15, 0xE0, 0x00, 0x00 }, &buf);

        bb.appendBits(26664, 15);
        try testing.expectEqual(@as(usize, 42), bb.bit_length);
        try testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x2E, 0x15, 0xFA, 0x0A, 0x00 }, &buf);
    }
}
