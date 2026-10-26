//! Public value types shared by the Zig API and the C ABI layer.

/// Error correction level.
/// Ordinal values follow nayuki/QR-Code-generator, c/qrcodegen.h,
/// enum qrcodegen_Ecc (LOW = 0, MEDIUM, QUARTILE, HIGH). These are NOT the
/// 2-bit values written into the format information; that mapping is
/// handled separately where the format bits are drawn.
pub const Ecc = enum(u2) {
    low = 0,
    medium = 1,
    quartile = 2,
    high = 3,
};

/// Segment encoding mode. Values are the 4-bit mode indicators.
/// Source: nayuki/QR-Code-generator, c/qrcodegen.h, enum qrcodegen_Mode.
pub const Mode = enum(u4) {
    numeric = 0x1,
    alphanumeric = 0x2,
    byte = 0x4,
    kanji = 0x8,
    eci = 0x7,
};

/// Errors returned by the encoder.
pub const Error = error{
    /// The data does not fit in the requested (or largest allowed) version
    /// at the requested error correction level.
    DataTooLong,
    /// The requested version is valid (1...40) but larger than the maximum
    /// version supported by this encoder tier.
    VersionExceedsTier,
    /// The requested version is outside 1...40.
    InvalidVersion,
    /// The caller-provided module buffer is smaller than size * size.
    BufferTooSmall,
};

/// An encoded QR symbol.
///
/// `modules` borrows the caller-provided buffer passed to the encoder; it is
/// valid for as long as that buffer is. Layout is row-major, without quiet
/// zone: the module at column `x`, row `y` is `modules[y * size + x]`, with
/// (0, 0) at the top-left corner. Each byte is 0 (light) or 1 (dark).
pub const QrMatrix = struct {
    /// Version number, 1...40.
    version: u8,
    /// Side length in modules: 21 + 4 * (version - 1).
    size: u8,
    ecc: Ecc,
    /// Mask pattern applied, 0...7.
    mask: u3,
    /// Encoding mode used for the data.
    mode: Mode,
    /// `size * size` bytes, values 0 or 1.
    modules: []const u8,

    /// Returns true if the module at column `x`, row `y` is dark.
    /// Asserts that both coordinates are less than `size`.
    pub fn get(self: QrMatrix, x: u8, y: u8) bool {
        @import("std").debug.assert(x < self.size and y < self.size);
        return self.modules[@as(usize, y) * self.size + x] != 0;
    }
};
