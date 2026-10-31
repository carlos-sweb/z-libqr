//! Adaptive Image Binarization.
//!
//! Implements local adaptive thresholding based on an integral image (Summed-Area Table),
//! following the algorithm described in:
//!   - Derek Bradley and Gerhard Roth, "Adaptive Thresholding Using the Integral Image",
//!     Journal of Graphics Tools, 12(2):13-21, 2007.
//!   - Pierre D. Wellner, "Adaptive Thresholding for the DigitalDesk",
//!     Technical Report EPC-1993-110, Xerox Research Centre Europe, 1993.
//!
//! In this algorithm:
//! 1. An integral image I_sum(x, y) = sum_{i<=x, j<=y} I(i, j) is computed in a single pass.
//! 2. For each pixel (x, y), the average intensity of an S x S window centered at (x, y)
//!    is computed in O(1) time, where S = max(width, height) / window_div (typically 1/8).
//! 3. A pixel is classified as dark (1) if:
//!      pixel * count <= sum * (100 - percentage) / 100
//!    where percentage = 15 corresponds to the pixel being at least 15% darker than its local
//!    neighborhood. Otherwise, it is classified as light (0).
//!
//! Output convention:
//!   - 1 = Dark module / foreground (black)
//!   - 0 = Light module / background (white)
//! This matches z-libqr's internal representation for QR modules throughout the codebase.

const std = @import("std");

pub const BinarizeOptions = struct {
    /// Window size divisor: S = max(width, height) / window_div.
    /// Default is 8, as established by Wellner (1993) and Bradley & Roth (2007).
    window_div: usize = 8,

    /// Percentage threshold below local mean to consider a pixel dark.
    /// Range 1..99. Default is 15 (i.e. pixel <= mean * 0.85).
    percentage: u8 = 15,
};

pub const max_pixel_count: usize = 16_843_008;

pub const BinarizeError = error{
    ImageTooLarge,
    BufferTooSmall,
};

/// Returns `width * height` if the product fits in `usize` and is ≤ `max_pixel_count`.
/// Overflow-safe: uses `std.math.mul` so ReleaseFast cannot wrap past the limit check.
pub fn checkedPixelCount(width: usize, height: usize) BinarizeError!usize {
    const total = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
    if (total > max_pixel_count) return error.ImageTooLarge;
    return total;
}

/// Computes the integral image (Summed-Area Table) for 8-bit grayscale pixels.
/// `out_integral` must have length at least `width * height`.
/// Maximum supported image size is 16,843,008 pixels (e.g. ~4104x4104) to prevent
/// 32-bit unsigned overflow (since 16,843,008 * 255 = 4,294,967,040 <= u32_max).
pub fn computeIntegralImage(pixels: []const u8, width: usize, height: usize, out_integral: []u32) BinarizeError!void {
    const total = try checkedPixelCount(width, height);
    if (pixels.len < total or out_integral.len < total) return error.BufferTooSmall;
    if (width == 0 or height == 0) return;

    // First row
    var row_sum: u32 = 0;
    for (0..width) |x| {
        row_sum += pixels[x];
        out_integral[x] = row_sum;
    }

    // Remaining rows
    for (1..height) |y| {
        const row_start = y * width;
        const prev_row_start = (y - 1) * width;
        row_sum = 0;

        for (0..width) |x| {
            row_sum += pixels[row_start + x];
            out_integral[row_start + x] = out_integral[prev_row_start + x] + row_sum;
        }
    }
}

/// Applies adaptive thresholding to 8-bit grayscale `pixels`, writing a binary bitmap
/// (1 for dark, 0 for light) into `out_bitmap`.
/// Uses caller-provided `integral_buf` to avoid heap allocations.
pub fn binarizeWithBuffer(
    pixels: []const u8,
    width: usize,
    height: usize,
    out_bitmap: []u8,
    integral_buf: []u32,
    options: BinarizeOptions,
) BinarizeError!void {
    const total = try checkedPixelCount(width, height);
    if (pixels.len < total or out_bitmap.len < total or integral_buf.len < total) return error.BufferTooSmall;
    if (width == 0 or height == 0) return;

    try computeIntegralImage(pixels, width, height, integral_buf);

    const div = if (options.window_div == 0) 8 else options.window_div;
    const max_dim = @max(width, height);
    const s = @max(3, max_dim / div);
    const s2 = s / 2;

    const pct: u64 = if (options.percentage >= 100) 99 else @max(1, options.percentage);
    const factor: u64 = 100 - pct;

    for (0..height) |y| {
        const y1 = if (y > s2) y - s2 else 0;
        const y2 = @min(y + s2, height - 1);
        const row_offset = y * width;

        for (0..width) |x| {
            const x1 = if (x > s2) x - s2 else 0;
            const x2 = @min(x + s2, width - 1);

            const count: u64 = @as(u64, x2 - x1 + 1) * @as(u64, y2 - y1 + 1);

            // Sum of S x S rectangle using 4 corners of the integral image
            const d: u64 = integral_buf[y2 * width + x2];
            const b: u64 = if (y1 > 0) integral_buf[(y1 - 1) * width + x2] else 0;
            const c: u64 = if (x1 > 0) integral_buf[y2 * width + (x1 - 1)] else 0;
            const a: u64 = if (x1 > 0 and y1 > 0) integral_buf[(y1 - 1) * width + (x1 - 1)] else 0;

            const sum: u64 = (d + a) - (b + c);
            const pixel_val: u64 = pixels[row_offset + x];

            // Formula: pixel * count <= sum * (100 - t) / 100
            // Rearranged to avoid division: pixel * count * 100 <= sum * factor
            if (pixel_val * count * 100 <= sum * factor) {
                out_bitmap[row_offset + x] = 1; // Dark
            } else {
                out_bitmap[row_offset + x] = 0; // Light
            }
        }
    }
}

/// Convenience function that allocates the temporary integral image on the heap.
pub fn binarizeAlloc(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: usize,
    height: usize,
    out_bitmap: []u8,
    options: BinarizeOptions,
) !void {
    const total = try checkedPixelCount(width, height);
    const integral = try allocator.alloc(u32, total);
    defer allocator.free(integral);

    try binarizeWithBuffer(pixels, width, height, out_bitmap, integral, options);
}

/// Optional 3x3 separable box filter [1, 1, 1] for pre-smoothing noisy camera frames.
pub fn smooth3x3(pixels: []const u8, width: usize, height: usize, out_smoothed: []u8) void {
    std.debug.assert(pixels.len >= width * height);
    std.debug.assert(out_smoothed.len >= width * height);
    if (width < 3 or height < 3) {
        @memcpy(out_smoothed[0 .. width * height], pixels[0 .. width * height]);
        return;
    }

    for (0..height) |y| {
        const ym1 = if (y > 0) y - 1 else 0;
        const yp1 = if (y + 1 < height) y + 1 else height - 1;

        for (0..width) |x| {
            const xm1 = if (x > 0) x - 1 else 0;
            const xp1 = if (x + 1 < width) x + 1 else width - 1;

            var sum: u32 = 0;
            sum += @as(u32, pixels[ym1 * width + xm1]) + @as(u32, pixels[ym1 * width + x]) + @as(u32, pixels[ym1 * width + xp1]);
            sum += @as(u32, pixels[y * width + xm1]) + @as(u32, pixels[y * width + x]) + @as(u32, pixels[y * width + xp1]);
            sum += @as(u32, pixels[yp1 * width + xm1]) + @as(u32, pixels[yp1 * width + x]) + @as(u32, pixels[yp1 * width + xp1]);

            out_smoothed[y * width + x] = @intCast(sum / 9);
        }
    }
}

test "computeIntegralImage on known small 3x3 matrix" {
    const testing = std.testing;

    // [ 1, 2, 3 ]
    // [ 4, 5, 6 ]
    // [ 7, 8, 9 ]
    const p = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var sat: [9]u32 = undefined;

    try computeIntegralImage(&p, 3, 3, &sat);

    // Row 0: [ 1, 3, 6 ]
    try testing.expectEqual(@as(u32, 1), sat[0]);
    try testing.expectEqual(@as(u32, 3), sat[1]);
    try testing.expectEqual(@as(u32, 6), sat[2]);

    // Row 1: [ 5, 12, 21 ]
    try testing.expectEqual(@as(u32, 5), sat[3]);
    try testing.expectEqual(@as(u32, 12), sat[4]);
    try testing.expectEqual(@as(u32, 21), sat[5]);

    // Row 2: [ 12, 27, 45 ]
    try testing.expectEqual(@as(u32, 12), sat[6]);
    try testing.expectEqual(@as(u32, 27), sat[7]);
    try testing.expectEqual(@as(u32, 45), sat[8]);
}

test "adaptive binarization on high-contrast black square on white background" {
    const testing = std.testing;
    const w: usize = 32;
    const h: usize = 32;
    var pixels: [w * h]u8 = @splat(255); // White background

    // Center 8x8 black square (intensity 0)
    for (12..20) |y| {
        for (12..20) |x| {
            pixels[y * w + x] = 0;
        }
    }

    var bitmap: [w * h]u8 = undefined;
    var sat: [w * h]u32 = undefined;
    try binarizeWithBuffer(&pixels, w, h, &bitmap, &sat, .{});

    // Verify center is detected as dark (1)
    for (13..19) |y| {
        for (13..19) |x| {
            try testing.expectEqual(@as(u8, 1), bitmap[y * w + x]);
        }
    }

    // Verify corners remain light (0)
    try testing.expectEqual(@as(u8, 0), bitmap[0]);
    try testing.expectEqual(@as(u8, 0), bitmap[w - 1]);
    try testing.expectEqual(@as(u8, 0), bitmap[(h - 1) * w]);
    try testing.expectEqual(@as(u8, 0), bitmap[w * h - 1]);
}

test "adaptive binarization overcomes severe lighting gradient where global threshold fails" {
    const testing = std.testing;
    const w: usize = 64;
    const h: usize = 32;
    var pixels: [w * h]u8 = undefined;

    // Create a severe horizontal brightness gradient from left (0) to right (200).
    // Place dark bars on both left and right sides:
    // - On left: background is ~30, bar is 5.
    // - On right: background is ~230, bar is 150.
    // Notice that 150 (dark bar on right) is much brighter than 30 (light background on left)!
    // A global threshold cannot separate both simultaneously.
    for (0..h) |y| {
        for (0..w) |x| {
            const bg_val = @as(u32, @intCast(x)) * 200 / @as(u32, @intCast(w)) + 30; // 30..230
            const is_bar = (x >= 4 and x <= 8) or (x >= 54 and x <= 58);
            if (is_bar) {
                // Bar is 40% darker than local background
                pixels[y * w + x] = @intCast(bg_val * 60 / 100);
            } else {
                pixels[y * w + x] = @intCast(bg_val);
            }
        }
    }

    // Verify that NO single global threshold can separate both bars:
    // Left background is ~35, right dark bar is ~135.
    // Any global threshold T > 35 classifies left background as dark.
    // Any global threshold T < 135 classifies right bar as light.
    const left_bg = pixels[16 * w + 12];
    const right_bar = pixels[16 * w + 56];
    try testing.expect(right_bar > left_bg); // Proof that global threshold is impossible

    // Now run adaptive binarization
    var bitmap: [w * h]u8 = undefined;
    var sat: [w * h]u32 = undefined;
    try binarizeWithBuffer(&pixels, w, h, &bitmap, &sat, .{ .window_div = 8, .percentage = 15 });

    // Both the left bar AND the right bar must be correctly resolved as dark (1)
    for (10..22) |y| {
        try testing.expectEqual(@as(u8, 1), bitmap[y * w + 6]); // Left bar
        try testing.expectEqual(@as(u8, 1), bitmap[y * w + 56]); // Right bar

        // Backgrounds must be light (0)
        try testing.expectEqual(@as(u8, 0), bitmap[y * w + 12]); // Left background
        try testing.expectEqual(@as(u8, 0), bitmap[y * w + 45]); // Right background
    }
}

test "adaptive binarization under diagonal shadow" {
    const testing = std.testing;
    const w: usize = 40;
    const h: usize = 40;
    var pixels: [w * h]u8 = undefined;

    // Pattern: 4 dark spots at (10, 10), (30, 10), (10, 30), (30, 30)
    // Shadow across top-left diagonal (x + y < 40 reduces brightness by 60%)
    for (0..h) |y| {
        for (0..w) |x| {
            var val: u32 = 220; // Default light background

            // 4 dark spots (5x5 pixels)
            const in_spot = (x >= 8 and x <= 12 and y >= 8 and y <= 12) or
                (x >= 28 and x <= 32 and y >= 8 and y <= 12) or
                (x >= 8 and x <= 12 and y >= 28 and y <= 32) or
                (x >= 28 and x <= 32 and y >= 28 and y <= 32);

            if (in_spot) {
                val = 40;
            }

            // Apply diagonal shadow
            if (x + y < 35) {
                val = val * 40 / 100; // Strong shadow
            }

            pixels[y * w + x] = @intCast(val);
        }
    }

    var bitmap: [w * h]u8 = undefined;
    var sat: [w * h]u32 = undefined;
    try binarizeWithBuffer(&pixels, w, h, &bitmap, &sat, .{ .window_div = 6, .percentage = 15 });

    // Top-left spot is completely under shadow, bottom-right spot is in full light.
    // Both must be detected as dark (1).
    try testing.expectEqual(@as(u8, 1), bitmap[10 * w + 10]); // Under shadow
    try testing.expectEqual(@as(u8, 1), bitmap[30 * w + 30]); // In light
    try testing.expectEqual(@as(u8, 1), bitmap[10 * w + 30]);
    try testing.expectEqual(@as(u8, 1), bitmap[30 * w + 10]);

    // Surrounding background must be light (0)
    try testing.expectEqual(@as(u8, 0), bitmap[2 * w + 2]); // Shadowed background
    try testing.expectEqual(@as(u8, 0), bitmap[38 * w + 38]); // Lit background
}

test "smooth3x3 attenuates high-frequency noise" {
    const testing = std.testing;
    const w: usize = 16;
    const h: usize = 16;
    var pixels: [w * h]u8 = @splat(100);

    // Single isolated noisy pixel (salt noise)
    pixels[8 * w + 8] = 255;

    var smoothed: [w * h]u8 = undefined;
    smooth3x3(&pixels, w, h, &smoothed);

    // The isolated spike of 255 should be averaged over 9 pixels:
    // (8 * 100 + 255) / 9 = 1055 / 9 = 117
    try testing.expect(smoothed[8 * w + 8] < 125);
    try testing.expect(smoothed[8 * w + 8] > 110);
}

test "computeIntegralImage returns ImageTooLarge on excessive dimensions" {
    const testing = std.testing;
    const dummy = [_]u8{0};
    var sat: [1]u32 = undefined;
    // 5000 x 5000 = 25,000,000 > 16,843,008
    try testing.expectError(error.ImageTooLarge, computeIntegralImage(&dummy, 5000, 5000, &sat));
}
