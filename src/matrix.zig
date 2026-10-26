//! Matrix representation and drawing of function patterns (finder, timing,
//! alignment, version blocks, format bits).
//!
//! Function module representation during construction:
//!   - Bit 0 (0x01): module color (0 = light / false, 1 = dark / true).
//!   - Bit 1 (0x02): function module flag (1 = is function module, 0 = data/codeword module).
//!
//! This in-place representation avoids needing any secondary allocation or boolean matrix.
//! In the finalization step (after masking), all bytes are masked with 0x01.
//!
//! Sources:
//!   - nayuki/QR-Code-generator (MIT), c/qrcodegen.c:
//!     initializeFunctionModules, drawLightFunctionModules, drawFormatBits,
//!     fillRectangle, getAlignmentPatternPositions.

const std = @import("std");
const types = @import("types.zig");
const tables = @import("tables.zig");

pub const Ecc = types.Ecc;

/// Generator polynomial constant for 15-bit format information BCH code (0x537).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawFormatBits.
pub const FORMAT_BCH_GENERATOR: u32 = 0x537;

/// Format mask XOR constant (0x5412) defined by QR Code Model 2 specification.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawFormatBits.
pub const FORMAT_MASK_PATTERN: u32 = 0x5412;

/// Generator polynomial constant for 18-bit version information BCH code (0x1F25).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawLightFunctionModules.
pub const VERSION_BCH_GENERATOR: u32 = 0x1F25;

/// Bit flag indicating that a module is a function pattern (not data).
pub const FUNCTION_FLAG: u8 = 0x02;

/// Sets a rectangle [left .. left+width) x [top .. top+height) as dark function modules.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function fillRectangle.
pub fn fillFunctionRectangle(modules: []u8, size: u8, left: u8, top: u8, width: u8, height: u8) void {
    var dy: u8 = 0;
    while (dy < height) : (dy += 1) {
        var dx: u8 = 0;
        while (dx < width) : (dx += 1) {
            const x = left + dx;
            const y = top + dy;
            std.debug.assert(x < size and y < size);
            modules[@as(usize, y) * size + x] = FUNCTION_FLAG | 0x01; // Marked as dark function module
        }
    }
}

/// Sets module at (x, y) if in bounds. If `is_dark` is true, sets color bit; otherwise clears it.
/// Preserves the FUNCTION_FLAG (bit 1).
pub fn setModuleColor(modules: []u8, size: u8, x: u8, y: u8, is_dark: bool) void {
    if (x >= size or y >= size) return;
    const idx = @as(usize, y) * size + x;
    if (is_dark) {
        modules[idx] |= 0x01;
    } else {
        modules[idx] &= ~@as(u8, 0x01);
    }
}

/// Sets module at (x, y) if in bounds as a function module with the given color.
/// Guarantees that FUNCTION_FLAG (bit 1) is set along with the color bit.
pub fn setFunctionModule(modules: []u8, size: u8, x: u8, y: u8, is_dark: bool) void {
    if (x >= size or y >= size) return;
    const idx = @as(usize, y) * size + x;
    modules[idx] = FUNCTION_FLAG | if (is_dark) @as(u8, 0x01) else @as(u8, 0x00);
}

/// Returns true if module at (x, y) is marked as a function module.
pub fn isFunction(modules: []const u8, size: u8, x: u8, y: u8) bool {
    std.debug.assert(x < size and y < size);
    return (modules[@as(usize, y) * size + x] & FUNCTION_FLAG) != 0;
}

/// Marks all function module locations (timing, finder, separators, alignment, version, format).
/// Initially marks all function locations with FUNCTION_FLAG | 0x01 (dark).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function initializeFunctionModules.
pub fn markFunctionModules(modules: []u8, version: u8) void {
    const size = tables.symbolSize(version);
    std.debug.assert(modules.len >= @as(usize, size) * size);
    @memset(modules[0 .. @as(usize, size) * size], 0);

    // 1. Horizontal and vertical timing patterns (at row 6 and col 6)
    fillFunctionRectangle(modules, size, 6, 0, 1, size);
    fillFunctionRectangle(modules, size, 0, 6, size, 1);

    // 2. Three finder patterns and format bits areas:
    // Top-left (including separator and format space: 9x9)
    fillFunctionRectangle(modules, size, 0, 0, 9, 9);
    // Top-right (separator and finder: 8x9)
    fillFunctionRectangle(modules, size, size - 8, 0, 8, 9);
    // Bottom-left (separator and finder: 9x8)
    fillFunctionRectangle(modules, size, 0, size - 8, 9, 8);

    // 3. Alignment patterns
    const align_pos = tables.getAlignmentPatternPositions(version);
    const num_align = align_pos.len;
    for (align_pos.slice(), 0..) |pos_i, i| {
        for (align_pos.slice(), 0..) |pos_j, j| {
            // Don't draw on the 3 finder corners
            if ((i == 0 and j == 0) or
                (i == 0 and j == num_align - 1) or
                (i == num_align - 1 and j == 0))
            {
                continue;
            }
            fillFunctionRectangle(modules, size, pos_i - 2, pos_j - 2, 5, 5);
        }
    }

    // 4. Version information blocks (only for version >= 7)
    if (version >= 7) {
        fillFunctionRectangle(modules, size, size - 11, 0, 3, 6);
        fillFunctionRectangle(modules, size, 0, size - 11, 6, 3);
    }
}

/// Draws light modules and pattern colors for timing, finder, alignment, and version info.
/// Does NOT draw format bits (format bits depend on ECL and mask).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawLightFunctionModules.
pub fn drawLightFunctionModules(modules: []u8, version: u8) void {
    const size = tables.symbolSize(version);

    // 1. Timing patterns: alternating dark/light (even coordinates are dark, odd are light)
    // Between finder separators: 7 .. size - 8
    var i: u8 = 7;
    while (i < size - 7) : (i += 2) {
        setModuleColor(modules, size, 6, i, false);
        setModuleColor(modules, size, i, 6, false);
    }

    // 2. Three finder patterns with separators (9x9 area centered at distance 3, 3 from corners)
    // Concentric rings at dist 2 (light) and dist 4 (light separator border)
    const finder_centers = [_][2]i32{
        .{ 3, 3 },
        .{ @as(i32, size) - 4, 3 },
        .{ 3, @as(i32, size) - 4 },
    };
    for (finder_centers) |center| {
        var dy: i32 = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: i32 = -4;
            while (dx <= 4) : (dx += 1) {
                const dist = @max(@abs(dx), @abs(dy));
                if (dist == 2 or dist == 4) {
                    const x = center[0] + dx;
                    const y = center[1] + dy;
                    if (x >= 0 and x < size and y >= 0 and y < size) {
                        setModuleColor(modules, size, @intCast(x), @intCast(y), false);
                    }
                }
            }
        }
    }

    // 3. Alignment patterns (5x5 grid with center 1x1 dark, surrounded by 3x3 light ring)
    const align_pos = tables.getAlignmentPatternPositions(version);
    const num_align = align_pos.len;
    for (align_pos.slice(), 0..) |pos_i, ai| {
        for (align_pos.slice(), 0..) |pos_j, aj| {
            if ((ai == 0 and aj == 0) or
                (ai == 0 and aj == num_align - 1) or
                (ai == num_align - 1 and aj == 0))
            {
                continue;
            }
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const is_dark = (dx == 0 and dy == 0);
                    const x: u8 = @intCast(@as(i32, pos_i) + dx);
                    const y: u8 = @intCast(@as(i32, pos_j) + dy);
                    setModuleColor(modules, size, x, y, is_dark);
                }
            }
        }
    }

    // 4. Version info blocks (18-bit BCH code: 6-bit version + 12-bit error correction)
    // Only present for version >= 7.
    // Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawLightFunctionModules.
    if (version >= 7) {
        var rem: u32 = version;
        var step: usize = 0;
        while (step < 12) : (step += 1) {
            rem = (rem << 1) ^ ((rem >> 11) * VERSION_BCH_GENERATOR);
        }
        var bits: u32 = (@as(u32, version) << 12) | rem;
        std.debug.assert((bits >> 18) == 0);

        var row: u8 = 0;
        while (row < 6) : (row += 1) {
            var col: u8 = 0;
            while (col < 3) : (col += 1) {
                const is_dark = (bits & 1) != 0;
                const k: u8 = size - 11 + col;
                // Top-right version block (columns k, rows row)
                setFunctionModule(modules, size, k, row, is_dark);
                // Bottom-left version block (columns row, rows k)
                setFunctionModule(modules, size, row, k, is_dark);
                bits >>= 1;
            }
        }
    }
}

/// Computes the 15-bit format information code (2 bits ECL + 3 bits mask + 10 bits BCH ECC, XORed with 0x5412).
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawFormatBits.
pub fn computeFormatBits(ecl: Ecc, mask: u3) u15 {
    // Format bits mapping for ECL: Low=1, Medium=0, Quartile=3, High=2
    const ecl_format_table = [_]u2{ 1, 0, 3, 2 };
    const ecl_bits: u2 = ecl_format_table[@backingInt(ecl)];
    const data: u32 = (@as(u32, ecl_bits) << 3) | @as(u32, mask);
    var rem: u32 = data;
    var step: usize = 0;
    while (step < 10) : (step += 1) {
        rem = (rem << 1) ^ ((rem >> 9) * FORMAT_BCH_GENERATOR);
    }
    const bits: u32 = ((data << 10) | rem) ^ FORMAT_MASK_PATTERN;
    std.debug.assert((bits >> 15) == 0);
    return @intCast(bits);
}

/// Draws the two copies of the 15-bit format information code.
/// Ensures all format modules have FUNCTION_FLAG (bit 1) preserved/set.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.c, function drawFormatBits.
pub fn drawFormatBits(modules: []u8, version: u8, ecl: Ecc, mask: u3) void {
    const size = tables.symbolSize(version);
    const bits: u32 = computeFormatBits(ecl, mask);

    // Draw first copy (around top-left finder pattern)
    var bit_idx: u5 = 0;
    while (bit_idx <= 5) : (bit_idx += 1) {
        setFunctionModule(modules, size, 8, bit_idx, ((bits >> bit_idx) & 1) != 0);
    }
    setFunctionModule(modules, size, 8, 7, ((bits >> 6) & 1) != 0);
    setFunctionModule(modules, size, 8, 8, ((bits >> 7) & 1) != 0);
    setFunctionModule(modules, size, 7, 8, ((bits >> 8) & 1) != 0);
    bit_idx = 9;
    while (bit_idx < 15) : (bit_idx += 1) {
        setFunctionModule(modules, size, 14 - bit_idx, 8, ((bits >> bit_idx) & 1) != 0);
    }

    // Draw second copy (along top-right and bottom-left finder patterns)
    bit_idx = 0;
    while (bit_idx < 8) : (bit_idx += 1) {
        setFunctionModule(modules, size, size - 1 - bit_idx, 8, ((bits >> bit_idx) & 1) != 0);
    }
    bit_idx = 8;
    while (bit_idx < 15) : (bit_idx += 1) {
        setFunctionModule(modules, size, 8, size - 15 + bit_idx, ((bits >> bit_idx) & 1) != 0);
    }
    // Always dark module at (8, size - 8)
    setFunctionModule(modules, size, 8, size - 8, true);
}

/// Clears function modules with FUNCTION_FLAG, draws timing, finder, alignment,
/// and placeholder format bits (using mask 0).
pub fn initializeFunctionModules(modules: []u8, version: u8, ecl: Ecc) void {
    markFunctionModules(modules, version);
    drawLightFunctionModules(modules, version);
    drawFormatBits(modules, version, ecl, 0);
}

// ---- Unit Tests ----

const testing = std.testing;

// Ported from nayuki/QR-Code-generator, c/qrcodegen-test.c, function testInitializeFunctionModulesEtc.
test "initializeFunctionModules across all versions 1..40" {
    var v: u8 = tables.min_version;
    while (v <= tables.max_version) : (v += 1) {
        const size = tables.symbolSize(v);
        var buf: [tables.moduleCount(tables.max_version)]u8 = undefined;
        initializeFunctionModules(buf[0..tables.moduleCount(v)], v, .medium);

        var has_light = false;
        var has_dark = false;
        var y: u8 = 0;
        while (y < size) : (y += 1) {
            var x: u8 = 0;
            while (x < size) : (x += 1) {
                const val = buf[@as(usize, y) * size + x];
                if ((val & 0x01) != 0) {
                    has_dark = true;
                } else {
                    has_light = true;
                }
            }
        }
        try testing.expect(has_light and has_dark);
    }
}

test "version blocks presence: absent in v6, present in v7" {
    // Version 6 (size 41)
    {
        const size6 = tables.symbolSize(6);
        var buf6: [tables.moduleCount(6)]u8 = undefined;
        initializeFunctionModules(&buf6, 6, .medium);

        // Version block area in top-right is cols [size-11 .. size-9], rows [0..5]
        var row: u8 = 0;
        while (row < 6) : (row += 1) {
            var col: u8 = size6 - 11;
            while (col < size6 - 8) : (col += 1) {
                // Must NOT be a function module in version 6
                try testing.expect(!isFunction(&buf6, size6, col, row));
            }
        }
    }

    // Version 7 (size 45)
    {
        const size7 = tables.symbolSize(7);
        var buf7: [tables.moduleCount(7)]u8 = undefined;
        initializeFunctionModules(&buf7, 7, .medium);

        // Version block area in top-right must BE function modules in version 7
        var row: u8 = 0;
        while (row < 6) : (row += 1) {
            var col: u8 = size7 - 11;
            while (col < size7 - 8) : (col += 1) {
                try testing.expect(isFunction(&buf7, size7, col, row));
            }
        }
    }
}

test "format bits computation against reference values" {
    // Format bits for ECL Medium (0), Mask 0:
    // data = (0 << 3) | 0 = 0.
    // rem = 0.
    // bits = (0 ^ 0x5412) = 0x5412.
    try testing.expectEqual(@as(u15, 0x5412), computeFormatBits(.medium, 0));

    // ECL Low (1), Mask 0: data = 8.
    // rem = 0x537 ^ ...
    const low_mask0 = computeFormatBits(.low, 0);
    try testing.expect(low_mask0 != 0);

    // Format bits must always fit in 15 bits
    for ([_]Ecc{ .low, .medium, .quartile, .high }) |ecl| {
        var m: u3 = 0;
        while (true) : (m += 1) {
            const fb = computeFormatBits(ecl, m);
            try testing.expect((@as(u32, fb) >> 15) == 0);
            if (m == 7) break;
        }
    }
}

test "timing pattern coordinates and alternating color" {
    var buf: [tables.moduleCount(1)]u8 = undefined;
    initializeFunctionModules(&buf, 1, .medium);
    const size = tables.symbolSize(1); // 21

    // Timing pattern runs between finder separators: indices 8..12
    var i: u8 = 8;
    while (i <= 12) : (i += 1) {
        const is_even = (i % 2 == 0);
        // Horizontal timing at (i, 6)
        try testing.expect(isFunction(&buf, size, i, 6));
        try testing.expectEqual(is_even, (buf[@as(usize, 6) * size + i] & 0x01) != 0);

        // Vertical timing at (6, i)
        try testing.expect(isFunction(&buf, size, 6, i));
        try testing.expectEqual(is_even, (buf[@as(usize, i) * size + 6] & 0x01) != 0);
    }
}

test "all format and version positions preserve FUNCTION_FLAG after initialize" {
    // Check version 1 format positions
    {
        var buf1: [tables.moduleCount(1)]u8 = undefined;
        initializeFunctionModules(&buf1, 1, .medium);
        const size1 = tables.symbolSize(1); // 21

        // Check format bits coordinates
        var bit_idx: u8 = 0;
        while (bit_idx <= 5) : (bit_idx += 1) {
            try testing.expect(isFunction(&buf1, size1, 8, bit_idx));
        }
        try testing.expect(isFunction(&buf1, size1, 8, 7));
        try testing.expect(isFunction(&buf1, size1, 8, 8));
        try testing.expect(isFunction(&buf1, size1, 7, 8));
        bit_idx = 9;
        while (bit_idx < 15) : (bit_idx += 1) {
            try testing.expect(isFunction(&buf1, size1, 14 - bit_idx, 8));
        }
        bit_idx = 0;
        while (bit_idx < 8) : (bit_idx += 1) {
            try testing.expect(isFunction(&buf1, size1, size1 - 1 - bit_idx, 8));
        }
        bit_idx = 8;
        while (bit_idx < 15) : (bit_idx += 1) {
            try testing.expect(isFunction(&buf1, size1, 8, size1 - 15 + bit_idx));
        }
        try testing.expect(isFunction(&buf1, size1, 8, size1 - 8));
    }

    // Check version 7 version blocks positions
    {
        var buf7: [tables.moduleCount(7)]u8 = undefined;
        initializeFunctionModules(&buf7, 7, .medium);
        const size7 = tables.symbolSize(7); // 45

        var row: u8 = 0;
        while (row < 6) : (row += 1) {
            var col: u8 = 0;
            while (col < 3) : (col += 1) {
                const k = size7 - 11 + col;
                // Top-right version block (k, row)
                try testing.expect(isFunction(&buf7, size7, k, row));
                // Bottom-left version block (row, k)
                try testing.expect(isFunction(&buf7, size7, row, k));
            }
        }
    }
}
