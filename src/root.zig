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
pub const makeEci = segment.makeEci;

/// Predefined tiers, matching the distributed C libraries.
pub const Tier1 = Encoder(6);
pub const Tier2 = Encoder(10);
pub const Tier3 = Encoder(40);

test {
    _ = types;
    _ = tables;
    _ = gf256;
    _ = BitBuffer;
    _ = segment;
    _ = matrix;
    _ = interleave;
    _ = mask;
    _ = encoder;
}
