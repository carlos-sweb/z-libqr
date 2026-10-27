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
    fnc1_first = 0x5,
    fnc1_second = 0x9,
    structured_append = 0x3,
};

/// Structured Append metadata defined in ISO/IEC 18004 clause 8.
pub const StructuredAppend = struct {
    /// 0-indexed sequence position of the symbol: 0..15 (representing symbol 1..16).
    position: u4,
    /// 0-indexed total symbol count in sequence: 1..15 (representing total 2..16 symbols).
    total: u4,
    /// 8-bit parity checksum (cumulative XOR of all unencoded input bytes).
    parity: u8,
};

/// FNC1 operating mode defined in ISO/IEC 18004.
pub const Fnc1Mode = enum(u2) {
    /// FNC1 in first position: designates a GS1 QR Code symbol.
    first = 1,
    /// FNC1 in second position: designates an AIM application-specific format.
    second = 2,
};

/// Configuration for FNC1 mode indicator.
pub const Fnc1 = struct {
    mode: Fnc1Mode,
    /// 8-bit Application Indicator (0..255).
    /// Used only when `mode == .second`. Ignored when `mode == .first`.
    app_indicator: u8 = 0,
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
    /// Segment order violates ISO/IEC 18004 (e.g. FNC1 after data, or ECI after FNC1).
    InvalidSegmentOrder,
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
