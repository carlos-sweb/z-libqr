const std = @import("std");
const zqr = @import("zqr");

pub fn main() !void {
    std.debug.print("=== zqr Zig Consumer Example ===\n", .{});

    // 1. Encode "HELLO WORLD" with Tier 1 (v1..6)
    var buf_t1: [zqr.Tier1.max_buffer_len]u8 = undefined;
    const qr1 = try zqr.Tier1.encode(&buf_t1, "HELLO WORLD", .medium);
    std.debug.print("Encoded 'HELLO WORLD' -> Version {d}, Size {d}x{d}, Mask {d}\n", .{
        qr1.version,
        qr1.size,
        qr1.size,
        qr1.mask,
    });

    // Print ASCII preview
    var y: usize = 0;
    while (y < qr1.size) : (y += 1) {
        var x: usize = 0;
        while (x < qr1.size) : (x += 1) {
            const is_dark = qr1.modules[y * qr1.size + x] == 1;
            std.debug.print("{s}", .{if (is_dark) "##" else "  "});
        }
        std.debug.print("\n", .{});
    }

    // 2. Encode with Tier 3 (v1..40) and explicit version/mask
    var buf_t3: [zqr.Tier3.max_buffer_len]u8 = undefined;
    const qr3 = try zqr.Tier3.encodeWithVersion(&buf_t3, "Z-LIBQR V1.0.0", 3, .high, 2);
    std.debug.print("\nEncoded 'Z-LIBQR V1.0.0' in forced v3-H mask 2 -> Size {d}x{d}\n", .{
        qr3.size,
        qr3.size,
    });
}
