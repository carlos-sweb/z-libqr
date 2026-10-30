//! End-to-End Vision Decoder Integration Tests.
//!
//! Validates the complete pipeline:
//!   Grayscale pixels -> Bradley-Roth adaptive thresholding -> Finder detection & canonical orientation
//!   -> Alignment pattern detection & Heckbert homography -> Module grid sampling
//!   -> BCH format/version decode -> Zigzag extraction -> RS deinterleave/correction -> Segment parsing.

const std = @import("std");
const root = @import("../../root.zig");
const Transform = @import("transform.zig").Transform;

fn rasterizeClean(
    allocator: std.mem.Allocator,
    modules: []const u8,
    size: usize,
    scale: usize,
    quiet_zone: usize,
) !struct { pixels: []u8, width: usize, height: usize } {
    const dim = (size + 2 * quiet_zone) * scale;
    const pixels = try allocator.alloc(u8, dim * dim);
    @memset(pixels, 255); // White background

    for (0..size) |r| {
        for (0..size) |c| {
            if (modules[r * size + c] == 1) {
                const py = (quiet_zone + r) * scale;
                const px = (quiet_zone + c) * scale;
                for (0..scale) |dy| {
                    for (0..scale) |dx| {
                        pixels[(py + dy) * dim + (px + dx)] = 0; // Black
                    }
                }
            }
        }
    }

    return .{ .pixels = pixels, .width = dim, .height = dim };
}

fn rasterizeProjective(
    allocator: std.mem.Allocator,
    modules: []const u8,
    size: usize,
    quiet_zone: usize,
    width: usize,
    height: usize,
    forward_transform: Transform,
) ![]u8 {
    const pixels = try allocator.alloc(u8, width * height);
    @memset(pixels, 255); // White background

    const inv = forward_transform.invert() orelse return error.DegenerateTransform;
    const qz: f64 = @floatFromInt(quiet_zone);
    const s_float: f64 = @floatFromInt(size);

    for (0..height) |y| {
        const fy = @as(f64, @floatFromInt(y)) + 0.5;
        const row_offset = y * width;
        for (0..width) |x| {
            const fx = @as(f64, @floatFromInt(x)) + 0.5;
            const pt = inv.map(fx, fy);

            const u = pt.x - qz;
            const v = pt.y - qz;

            if (u >= 0.0 and u < s_float and v >= 0.0 and v < s_float) {
                const c: usize = @intFromFloat(u);
                const r: usize = @intFromFloat(v);
                if (c < size and r < size) {
                    if (modules[r * size + c] == 1) {
                        pixels[row_offset + x] = 0; // Black
                    }
                }
            }
        }
    }

    return pixels;
}

test "E2E: V1-L Numeric mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, "0123456789012345", .{
        .ecc = .low,
        .min_version = 1,
    });
    try testing.expectEqual(@as(u8, 1), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings("0123456789012345", res.data);
    try testing.expectEqual(@as(u8, 1), res.metadata.version);
    try testing.expectEqual(root.Ecc.low, res.metadata.ecc);
}

test "E2E: V2-M Alphanumeric mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, "HELLO 123 WORLD", .{
        .ecc = .medium,
        .min_version = 2,
    });
    try testing.expectEqual(@as(u8, 2), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings("HELLO 123 WORLD", res.data);
    try testing.expectEqual(@as(u8, 2), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: V3-Q Byte mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "Binary \x01\x02\x03\x04\xff Payload";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .quartile,
        .min_version = 3,
    });
    try testing.expectEqual(@as(u8, 3), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 3), res.metadata.version);
    try testing.expectEqual(root.Ecc.quartile, res.metadata.ecc);
}

test "E2E: V6-H Kanji mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "日本語";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .high,
        .min_version = 6,
        .kanji = true,
    });
    try testing.expectEqual(@as(u8, 6), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    // Kanji mode outputs reconstructed 2-byte Shift-JIS characters per ISO 18004 §7.4.6
    const expected_sjis = "\x93\xfa\x96\x7b\x8c\xea";
    try testing.expectEqualStrings(expected_sjis, res.data);
    try testing.expectEqual(@as(u8, 6), res.metadata.version);
    try testing.expectEqual(root.Ecc.high, res.metadata.ecc);
    try testing.expect((res.metadata.modes_used & 0x08) != 0);
}

test "E2E: V7-M ECI mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "ECI 26 UTF-8 Test String";
    var mat_buf: [root.Tier2.max_buffer_len]u8 = undefined;
    const qr = try root.Tier2.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 7,
        .eci = 26,
    });
    try testing.expectEqual(@as(u8, 7), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier2.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier2.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 7), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
    try testing.expectEqual(@as(?u32, 26), res.metadata.eci);
}

test "E2E: V10-L Byte mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "V10 Test: The quick brown fox jumps over the lazy dog 1234567890! Repeating to fill capacity safely.";
    var mat_buf: [root.Tier2.max_buffer_len]u8 = undefined;
    const qr = try root.Tier2.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .low,
        .min_version = 10,
    });
    try testing.expectEqual(@as(u8, 10), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 3, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier2.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier2.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 10), res.metadata.version);
    try testing.expectEqual(root.Ecc.low, res.metadata.ecc);
}

test "E2E: V20-M Alphanumeric mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "VERSION 20 ALPHANUMERIC QR CODE TEST WITH PERSPECTIVE HOMOGRAPHY AND ALIGNMENT PATTERNS";
    var mat_buf: [root.Tier3.max_buffer_len]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 20,
    });
    try testing.expectEqual(@as(u8, 20), qr.version);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 3, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier3.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier3.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 20), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: V40-H Byte mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "V40 HIGHEST LEVEL TEST: Maximum version QR symbol with high error correction level.";
    var mat_buf: [root.Tier3.max_buffer_len]u8 = undefined;
    const qr = try root.Tier3.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .high,
        .min_version = 40,
    });
    try testing.expectEqual(@as(u8, 40), qr.version);

    // Scale 2 with quiet zone 4 => (177 + 8) * 2 = 370x370
    const img = try rasterizeClean(allocator, qr.modules, qr.size, 2, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier3.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier3.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 40), res.metadata.version);
    try testing.expectEqual(root.Ecc.high, res.metadata.ecc);
}

test "E2E: V2 under realistic 20-degree perspective tilt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "PERSPECTIVE V2 20 DEG";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 33.0

    // Canvas size
    const w: usize = 160;
    const h: usize = 160;

    // Simulate 20-degree tilt by compressing the top edge (cos 20 deg ~ 0.94)
    // and shifting corners to form a perspective trapezoid:
    // Top-left: (22, 18)
    // Top-right: (138, 18)
    // Bottom-right: (148, 146)
    // Bottom-left: (12, 146)
    const forward_trans = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        total_mods,
        0,
        total_mods,
        total_mods,
        0,
        total_mods,
        22,
        18,
        138,
        18,
        148,
        146,
        12,
        146,
    ).?;

    const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, forward_trans);
    defer allocator.free(pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 2), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: V7 under realistic 20-degree perspective tilt (6 alignments + BCH version blocks)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "PERSPECTIVE V7 20 DEG TILT";
    var mat_buf: [root.Tier2.max_buffer_len]u8 = undefined;
    const qr = try root.Tier2.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 7,
    });
    const size = qr.size; // 45
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 53.0

    // Canvas size
    const w: usize = 240;
    const h: usize = 240;

    // Simulate 20-degree tilt on V7 (53x53 modules)
    // Top-left: (36, 26)
    // Top-right: (204, 26)
    // Bottom-right: (220, 220)
    // Bottom-left: (20, 220)
    const forward_trans = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        total_mods,
        0,
        total_mods,
        total_mods,
        0,
        total_mods,
        36,
        26,
        204,
        26,
        220,
        220,
        20,
        220,
    ).?;

    const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, forward_trans);
    defer allocator.free(pixels);

    var out_buf: [root.DecoderTier2.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier2.decodeImageAlloc(allocator, pixels, w, h, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 7), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: Caller-provided scratch buffer API (no heap allocations)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "CALLER SCRATCH TEST";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encode(&mat_buf, payload, .medium);

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    // Query scratch length and allocate scratch manually
    const scratch_len = root.imageBufferLen(img.width, img.height);
    const scratch = try allocator.alloc(u8, scratch_len);
    defer allocator.free(scratch);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImage(img.pixels, img.width, img.height, scratch, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
}

test "E2E: Error handling and bounds checking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 1. All-white image -> NoFinderPatterns
    const white_pixels = try allocator.alloc(u8, 100 * 100);
    defer allocator.free(white_pixels);
    @memset(white_pixels, 255);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    try testing.expectError(error.NoFinderPatterns, root.DecoderTier1.decodeImageAlloc(allocator, white_pixels, 100, 100, &out_buf));

    // 2. Version exceeds tier: Version 7 decoded with Tier 1 (max_version 6)
    var mat_buf: [root.Tier2.max_buffer_len]u8 = undefined;
    const qr_v7 = try root.Tier2.encodeAdvanced(&mat_buf, "V7 EXCEEDS TIER 1", .{
        .ecc = .medium,
        .min_version = 7,
    });
    const img_v7 = try rasterizeClean(allocator, qr_v7.modules, qr_v7.size, 4, 4);
    defer allocator.free(img_v7.pixels);

    try testing.expectError(error.VersionExceedsTier, root.DecoderTier1.decodeImageAlloc(allocator, img_v7.pixels, img_v7.width, img_v7.height, &out_buf));

    // 3. Out buffer too small
    var small_out: [2]u8 = undefined;
    var mat_v1: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr_v1 = try root.Tier1.encode(&mat_v1, "LONG PAYLOAD TO OVERFLOW SMALL BUFFER", .medium);
    const img_v1 = try rasterizeClean(allocator, qr_v1.modules, qr_v1.size, 4, 4);
    defer allocator.free(img_v1.pixels);

    try testing.expectError(error.BufferTooSmall, root.DecoderTier1.decodeImageAlloc(allocator, img_v1.pixels, img_v1.width, img_v1.height, &small_out));

    // 4. Image dimensions exceeding max_pixel_count (16,843,008 pixels) -> ImageTooLarge
    var dummy: [1]u8 = undefined;
    try testing.expectError(error.ImageTooLarge, root.DecoderTier1.decodeImageAlloc(allocator, &dummy, 5000, 4000, &out_buf));
}

test "E2E: 90, 180, and 270 degree rotations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "ROTATION TEST 90 180 270";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 33.0

    const w: usize = 140;
    const h: usize = 140;
    const s: f64 = 4.0; // scale 4
    const offset = 4.0;

    // 1. 90 degrees clockwise rotation:
    {
        const trans_90 = Transform.quadrilateralToQuadrilateral(
            0,
            0,
            total_mods,
            0,
            total_mods,
            total_mods,
            0,
            total_mods,
            offset + total_mods * s,
            offset,
            offset + total_mods * s,
            offset + total_mods * s,
            offset,
            offset + total_mods * s,
            offset,
            offset,
        ).?;

        const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_90);
        defer allocator.free(pixels);

        var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
        const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);
        try testing.expectEqualStrings(payload, res.data);
    }

    // 2. 180 degrees rotation:
    {
        const trans_180 = Transform.quadrilateralToQuadrilateral(
            0,
            0,
            total_mods,
            0,
            total_mods,
            total_mods,
            0,
            total_mods,
            offset + total_mods * s,
            offset + total_mods * s,
            offset,
            offset + total_mods * s,
            offset,
            offset,
            offset + total_mods * s,
            offset,
        ).?;

        const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_180);
        defer allocator.free(pixels);

        var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
        const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);
        try testing.expectEqualStrings(payload, res.data);
    }

    // 3. 270 degrees rotation (90 counter-clockwise):
    {
        const trans_270 = Transform.quadrilateralToQuadrilateral(
            0,
            0,
            total_mods,
            0,
            total_mods,
            total_mods,
            0,
            total_mods,
            offset,
            offset + total_mods * s,
            offset,
            offset,
            offset + total_mods * s,
            offset,
            offset + total_mods * s,
            offset + total_mods * s,
        ).?;

        const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_270);
        defer allocator.free(pixels);

        var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
        const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);
        try testing.expectEqualStrings(payload, res.data);
    }
}

test "E2E: Inverted polarity (Dark Mode / Negative QR: white modules on black background)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "DARK MODE NEGATIVE QR";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });

    // Rasterize normal image
    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    // Invert the pixels to create true negative QR (black background 0, white modules 255)
    for (img.pixels) |*p| {
        p.* = 255 - p.*;
    }

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 2), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: Mirrored QR (Horizontal reflection)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "MIRRORED QR HORIZONTAL FLIP";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 33.0

    const w: usize = 140;
    const h: usize = 140;
    const s: f64 = 4.0;
    const offset = 4.0;

    // Horizontally mirrored transform:
    const trans_mirror = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        total_mods,
        0,
        total_mods,
        total_mods,
        0,
        total_mods,
        offset + total_mods * s,
        offset,
        offset,
        offset,
        offset,
        offset + total_mods * s,
        offset + total_mods * s,
        offset + total_mods * s,
    ).?;

    const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_mirror);
    defer allocator.free(pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
}

test "E2E: Structured Append (SA) end-to-end via image" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Encode symbol 1 of 2
    var seq_buf: [root.Tier1.max_sequence_buffer_len]u8 = undefined;
    const seq = try root.Tier1.encodeSequence(&seq_buf, "SPLIT MESSAGE PART 1 AND PART 2", .{
        .ecc = .medium,
        .symbol_count = 2,
    });
    try testing.expectEqual(@as(usize, 2), seq.count);

    const sym0 = seq.matrices[0];
    const img = try rasterizeClean(allocator, sym0.modules, sym0.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expect(res.metadata.sa != null);
    try testing.expectEqual(@as(u4, 0), res.metadata.sa.?.position);
    // ISO/IEC 18004 clause 8: total field is encoded as total_symbols - 1 (2 - 1 = 1)
    try testing.expectEqual(@as(u4, 1), res.metadata.sa.?.total);
    try testing.expectEqualStrings("SPLIT MESSAGE PA", res.data);
}

test "E2E: FNC1 First / GS1 mode end-to-end via image" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "0101234567890128";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .fnc1 = .{ .mode = .first },
    });

    const img = try rasterizeClean(allocator, qr.modules, qr.size, 4, 4);
    defer allocator.free(img.pixels);

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, img.pixels, img.width, img.height, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(root.Fnc1Mode.first, res.metadata.fnc1_mode.?);
}

test "E2E: Combined - Rotated 90 degrees + Dark Mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "ROTATED 90 DEG AND DARK MODE";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 33.0

    const w: usize = 140;
    const h: usize = 140;
    const s: f64 = 4.0;
    const offset = 4.0;

    const trans_90 = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        total_mods,
        0,
        total_mods,
        total_mods,
        0,
        total_mods,
        offset + total_mods * s,
        offset,
        offset + total_mods * s,
        offset + total_mods * s,
        offset,
        offset + total_mods * s,
        offset,
        offset,
    ).?;

    const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_90);
    defer allocator.free(pixels);

    // Invert to dark mode (black background 0, white modules 255)
    for (pixels) |*p| {
        p.* = 255 - p.*;
    }

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 2), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}

test "E2E: Combined - Mirrored + Dark Mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "MIRRORED AND DARK MODE";
    var mat_buf: [root.Tier1.max_buffer_len]u8 = undefined;
    const qr = try root.Tier1.encodeAdvanced(&mat_buf, payload, .{
        .ecc = .medium,
        .min_version = 2,
    });
    const size = qr.size; // 25
    const qz = 4;
    const total_mods: f64 = @floatFromInt(size + 2 * qz); // 33.0

    const w: usize = 140;
    const h: usize = 140;
    const s: f64 = 4.0;
    const offset = 4.0;

    const trans_mirror = Transform.quadrilateralToQuadrilateral(
        0,
        0,
        total_mods,
        0,
        total_mods,
        total_mods,
        0,
        total_mods,
        offset + total_mods * s,
        offset,
        offset,
        offset,
        offset,
        offset + total_mods * s,
        offset + total_mods * s,
        offset + total_mods * s,
    ).?;

    const pixels = try rasterizeProjective(allocator, qr.modules, size, qz, w, h, trans_mirror);
    defer allocator.free(pixels);

    // Invert to dark mode
    for (pixels) |*p| {
        p.* = 255 - p.*;
    }

    var out_buf: [root.DecoderTier1.max_decoded_len]u8 = undefined;
    const res = try root.DecoderTier1.decodeImageAlloc(allocator, pixels, w, h, &out_buf);

    try testing.expectEqualStrings(payload, res.data);
    try testing.expectEqual(@as(u8, 2), res.metadata.version);
    try testing.expectEqual(root.Ecc.medium, res.metadata.ecc);
}
