//! zqr: a zero-dependency QR Code Model 2 encoder.
//!
//! Output is only the module matrix (one byte per module, 0/1, no quiet
//! zone). The core never allocates: callers provide the module buffer.
//!
//! Algorithms and tables are ported from nayuki/QR-Code-generator (MIT),
//! https://www.nayuki.io/page/qr-code-generator-library

const types = @import("types.zig");
const tables = @import("tables.zig");
const gf256 = @import("gf256.zig");
const BitBuffer = @import("BitBuffer.zig").BitBuffer;
const segment = @import("segment.zig");
const matrix = @import("matrix.zig");
const interleave = @import("interleave.zig");
const mask = @import("mask.zig");
const encoder = @import("encoder.zig");

pub const Ecc = types.Ecc;
pub const Mode = types.Mode;
pub const Fnc1Mode = types.Fnc1Mode;
pub const Fnc1 = types.Fnc1;
pub const StructuredAppend = types.StructuredAppend;
pub const Error = types.Error;
pub const QrMatrix = types.QrMatrix;

pub const Encoder = encoder.Encoder;

pub const min_version = tables.min_version;
pub const max_version = tables.max_version;
pub const symbolSize = tables.symbolSize;

pub const Segment = segment.Segment;
pub const makeNumeric = segment.makeNumeric;
pub const makeAlphanumeric = segment.makeAlphanumeric;
pub const makeBytes = segment.makeBytes;
pub const makeKanji = segment.makeKanji;
pub const makeEci = segment.makeEci;
pub const makeFnc1First = segment.makeFnc1First;
pub const makeFnc1Second = segment.makeFnc1Second;
pub const makeStructuredAppend = segment.makeStructuredAppend;
pub const computeParity = segment.computeParity;
pub const appIndicatorFromChar = segment.appIndicatorFromChar;
pub const appIndicatorFromDigits = segment.appIndicatorFromDigits;

pub const kanji = @import("kanji.zig");
pub const isKanji = kanji.isKanji;
pub const toQrKanji = kanji.toQrKanji;

pub const optimizer = @import("optimizer.zig");
pub const render = @import("render.zig");
pub const decoder = @import("decoder/mod.zig");

/// Predefined tiers, matching the distributed C libraries.
pub const Tier1 = Encoder(6);
pub const Tier2 = Encoder(10);
pub const Tier3 = Encoder(40);

pub const Decoder = decoder.Decoder;
pub const DecoderTier1 = decoder.Tier1;
pub const DecoderTier2 = decoder.Tier2;
pub const DecoderTier3 = decoder.Tier3;
pub const DecodeMetadata = decoder.DecodeMetadata;
pub const DecodeResult = decoder.DecodeResult;
pub const decodeBufferLen = decoder.decodeBufferLen;
pub const imageBufferLen = decoder.imageBufferLen;
pub const ImageDecodeError = decoder.ImageDecodeError;

test {
    _ = types;
    _ = tables;
    _ = gf256;
    _ = BitBuffer;
    _ = segment;
    _ = kanji;
    _ = @import("kanji_table.zig");
    _ = optimizer;
    _ = matrix;
    _ = interleave;
    _ = mask;
    _ = encoder;
    _ = render;
    _ = decoder;
}

test "README consumer example compiles and runs" {
    const zqr = @This();
    var buf: [zqr.Tier1.max_buffer_len]u8 = undefined;
    const qr = try zqr.Tier1.encode(&buf, "HELLO WORLD", .medium);
    const is_dark = qr.modules[10 * qr.size + 10] == 1;
    _ = is_dark;

    const qr_adv = try zqr.Tier1.encodeAdvanced(&buf, "ABC123日本語", .{
        .ecc = .low,
        .kanji = true,
        .optimize = true,
    });
    _ = qr_adv;

    var seq_buf: [zqr.Tier1.max_sequence_buffer_len]u8 = undefined;
    const seq = try zqr.Tier1.encodeSequence(&seq_buf, "LONG PAYLOAD TO BE SPLIT ACROSS SYMBOLS", .{
        .ecc = .low,
        .symbol_count = null,
    });
    try @import("std").testing.expect(seq.count >= 1);
    try @import("std").testing.expect(seq.parity != 0);
}
