# z-libqr (libzqr)

A complete, zero-dependency QR Code Model 2 encoder in Zig 0.17.
Generates strictly compliant QR Code Model 2 matrices from Version 1 (21×21) to 40 (177×177), with error correction levels L, M, Q, H, dynamic programming multi-mode optimization, Kanji, FNC1, and Structured Append.

Output is strictly the module matrix (0 = light, 1 = dark), without quiet zone padding or image rendering.

This library is a from-scratch Zig port of the algorithm described in Project Nayuki's QR Code generator (MIT).

---

## Table of Contents

- [Specification Coverage](#specification-coverage)
- [Tiered Architecture & Distribution](#tiered-architecture--distribution)
- [Memory Model & Stack Budget](#memory-model--stack-budget)
- [Core Features](#core-features)
  - [Kanji Mode (JIS X 0208)](#kanji-mode-jis-x-0208)
  - [Optimal Multi-Mode Optimizer (DP Mixing)](#optimal-multi-mode-optimizer-dp-mixing)
  - [FNC1 & GS1 QR Codes](#fnc1--gs1-qr-codes)
  - [Structured Append Sequences](#structured-append-sequences)
- [Zig API Reference](#zig-api-reference)
- [C ABI Reference](#c-abi-reference)
- [Usage Examples](#usage-examples)
  - [Zig Consumer](#zig-consumer)
  - [C99 / C++ Consumer](#c99--c-consumer)
  - [Python FFI (ctypes)](#python-ffi-ctypes)
- [Quality, Testing & Verification](#quality-testing--verification)
- [License](#license)

---

## Specification Coverage

`z-libqr` provides complete Model 2 implementation according to **ISO/IEC 18004:2015**:

| Scope Area | Feature / Capability | Status | Details |
| :--- | :--- | :--- | :--- |
| **Model 2 Core** | Versions 1 to 40 | **Complete** | Geometries from 21×21 to 177×177 modules |
| | ECC Levels (L, M, Q, H) | **Complete** | Exact Reed-Solomon generation; no automatic boost |
| | Mask Patterns 0–7 | **Complete** | Full ISO penalty evaluation (N1–N4) + tie-breaking |
| **Encoding Modes** | Numeric Mode | **Complete** | 3 digits / 10 bits, 2 / 7b, 1 / 4b |
| | Alphanumeric Mode | **Complete** | 45-character standard charset (11 bits / pair) |
| | Byte Mode | **Complete** | Arbitrary binary data and UTF-8 bytes |
| | ECI Mode | **Complete** | Extended Channel Interpretation headers (0..999999) |
| | Kanji Mode | **Complete** | JIS X 0208 UTF-8 mapping to 13-bit codewords |
| | Mode Mixing (Optimizer) | **Complete** | Dynamic programming cost optimization in 1/6 bit |
| | FNC1 First Position | **Complete** | GS1 QR Code identification (`0101`) |
| | FNC1 Second Position | **Complete** | AIM application indicator (`1001`) |
| | Structured Append | **Complete** | 1 to 16 linked symbols, automatic parity checksum |
| **Explicitly Out of Scope** | Micro QR (M1–M4) | *Out of Scope* | Standard QR Model 2 only |
| | QR Code Model 1 | *Out of Scope* | Obsolete legacy specification |
| | Decoder / Reader | *Out of Scope* | Encoder only; no scanning or decoding logic |
| | Image Rendering | *Out of Scope* | Generates raw module matrices; no PNG/SVG or quiet zones |
| | GS1 AI Syntax Validation | *Out of Scope* | Inserts FNC1 headers; semantic AI parsing is caller responsibility |

---

## Tiered Architecture & Distribution

To minimize binary footprint and stack memory in resource-constrained or embedded environments, `z-libqr` is partitioned into three compile-time tiers:

- **Tier 1 (`_t1`)**: QR Versions 1 to 6. Max size 41×41 modules.
- **Tier 2 (`_t2`)**: QR Versions 1 to 10. Max size 57×57 modules.
- **Tier 3 (`_t3`)**: Full QR Versions 1 to 40. Max size 177×177 modules.

> **Linking Rule:** All tiers use unique public symbol prefixes (`zqr_t1_`, `zqr_t2_`, `zqr_t3_`), allowing different tiers to be linked simultaneously into a single binary without symbol collision.

### Distribution Formats

1. **Zig Package**: Import via `build.zig.zon` and `@import("zqr")`. Exposes `zqr.Tier1`, `zqr.Tier2`, and `zqr.Tier3`.
2. **Static C Libraries**: `libzqr_t1.a`, `libzqr_t2.a`, `libzqr_t3.a` linkable by any C99+, C++, or Rust toolchain.
3. **Dynamic Shared Libraries**: `libzqr_t1.so`, `libzqr_t2.so`, `libzqr_t3.so` (version 1.2.0, ELF SONAME `libzqr_tN.so.1`).

---

## Memory Model & Stack Budget

`z-libqr` strictly enforces a **Zero-Allocation Core**:
- **0 heap allocations** across all encoding paths (no `malloc`, no `std.mem.Allocator`).
- All internal buffers are statically sized and allocated on the execution stack.
- Module matrix output storage is provided by the caller.

### Measured Stack Budgets

| Execution Path | Tier 1 (v1–6) | Tier 2 (v1–10) | Tier 3 (v1–40) |
| :--- | :--- | :--- | :--- |
| **Standard Pipeline (`optimize: false`)** | ~1.2 KB | ~1.8 KB | **~6.6 KB** |
| **DP Optimizer (`optimize: true`, worst-case)** | ~1.8 KB | ~3.2 KB | **~12.9 KB** |
| **Structured Append (`encodeSequence`, frame + DP)** | ~2.5 KB | ~4.1 KB | **~15.3 KB** |

- **Stack Slot Coloring**: The compiler reuses overlapping lifetimes between the DP backtracking table and Reed-Solomon interleaving buffers, bounding worst-case single-symbol stack to ~12.9 KB.
- **Structured Append Sequential Encoding**: Each chunk is encoded sequentially, reusing the single-symbol pipeline buffers. In C ABI, `zqr_tN_encode_sequence` reserves a frame of ~2.4 KB (`sub $0x960, %rsp`), giving a peak stack usage of ~15.3 KB in Tier 3.

> [!WARNING]
> For a maximum sequence of $N=16$ symbols of Version 40, the output `module_storage` buffer requires ~490 KB ($16 \times 177^2$ bytes).
> **Allocate `module_storage` on the heap, never on the stack.**
> Use `sequenceBufferLen(0, N)` (or `zqr_tN_sequence_buffer_len(0, N)`) to query the exact worst-case buffer size.

---

## Core Features

### Kanji Mode (JIS X 0208)

- Converts UTF-8 strings consisting of JIS X 0208 characters directly into 13-bit QR Kanji codewords.
- Embeds a static lookup table of 6,879 sorted entries (27.5 KiB in `.rodata`).
- Lookup executes via $O(\log N)$ binary search without runtime initialization.
- Opt-in via `kanji: true` in `Options` and `SequenceOptions`.

### Optimal Multi-Mode Optimizer (DP Mixing)

- Computes optimal mode switching points across Numeric, Alphanumeric, Byte, and Kanji segments using dynamic programming.
- Mode transition costs are evaluated in exact 1/6 bit units (following Project Nayuki's algorithm).
- Backtracking buffer is statically sized per tier: 322 B (T1), 652 B (T2), 7089 B (T3).
- **Adversarial Fallback**: If an adversarial input generates more than the tier's segment budget (32 for T1, 48 for T2, 128 for T3), the optimizer falls back silently to single Byte mode. The resulting QR code remains strictly valid and compliant.

### FNC1 & GS1 QR Codes

- **First Position (`0101`)**: Identifies standard **GS1 QR Code** payloads.
- **Second Position (`1001`)**: Identifies AIM application-specific symbols with an 8-bit Application Indicator (0..99 for numeric prefixes, or `c + 100` for ASCII letters `'A'..'Z'` / `'a'..'z'`).
- **Segment Ordering**: When both ECI and FNC1 are configured, `z-libqr` automatically orders segments as `[ECI, FNC1, Data...]` per ISO/IEC 18004 clause 7.4.8.
- *Notice*: The caller is responsible for placing `0x1D` (ASCII GS) field separators between variable-length Application Identifiers; the library does not perform semantic GS1 AI validation.

### Structured Append Sequences

- Encodes large payloads across 1 to 16 linked symbols per ISO/IEC 18004 Section 8.
- **Automatic Minimal Symbol Count**: If `symbol_count` is omitted (or 0), the encoder automatically chooses the minimal $N \in [1..16]$ that fits the payload.
- **Forced Symbol Count**: Callers can force an exact sequence count in $[1..16]$.
- **$N = 1$ Identity**: When $N = 1$, the encoder produces a standard QR code without Structured Append header, byte-for-byte identical to standard `encode()`.
- **Automatic Parity**: Computes cumulative XOR parity across all unencoded input bytes before chunking.
- **FNC1 Placement**: FNC1 mode indicator is placed *only* on the first symbol (symbol 0).
- **ECI Repetition Trade-off**: ECI headers are repeated across *every* symbol in the sequence (12 bits overhead per symbol) to ensure decodability regardless of scan order.
- **Balanced UTF-8 Chunking**: Payload is divided evenly via `divmod`, with automatic boundary alignment to multi-byte UTF-8 codepoints and Shift-JIS 2-byte pairs.
- **Two-Phase Dry-Run**: Calling with `module_storage: null` in Zig (or `buf == NULL || out == NULL` in C) calculates the required symbol count and parity with zero matrix allocations.

---

## Zig API Reference

Available through `zqr.Tier1`, `zqr.Tier2`, or `zqr.Tier3`:

```zig
// 1. High-level single-symbol encode (v1.0.0)
pub fn encode(buf: []u8, data: []const u8, ecc: Ecc) Error!QrMatrix;

// 2. Low-level forced version and mask (v1.0.0)
pub fn encodeWithVersion(buf: []u8, data: []const u8, version: u8, ecc: Ecc, forced_mask: ?u3) Error!QrMatrix;

// 3. Advanced multi-feature single-symbol encode (v1.1.0)
pub fn encodeAdvanced(buf: ?[]u8, data: []const u8, options: Options) Error!QrMatrix;

// 4. Structured Append sequence encode (v1.2.0)
pub fn encodeSequence(module_storage: ?[]u8, data: []const u8, options: SequenceOptions) Error!SequenceResult;

// Buffer length queries
pub fn bufferLen(version: u8) Error!usize;
pub fn sequenceBufferLen(version: u8, count: u8) Error!usize;
```

### Key Structs

```zig
pub const Options = struct {
    ecc: Ecc = .low,
    min_version: u8 = 1,
    max_version: u8 = tier_max_version,
    mask: ?u3 = null,       // null = auto evaluation
    kanji: bool = false,     // enable JIS X 0208
    optimize: bool = true,   // enable multi-mode DP optimizer
    fnc1: ?Fnc1 = null,
    eci: ?u32 = null,
};

pub const SequenceOptions = struct {
    ecc: Ecc = .low,
    min_version: u8 = 1,
    max_version: u8 = tier_max_version,
    mask: ?u3 = null,
    kanji: bool = false,
    optimize: bool = true,
    fnc1: ?Fnc1 = null,
    eci: ?u32 = null,
    symbol_count: ?u8 = null, // null = auto (1..16), 1..16 = forced
};

pub const SequenceResult = struct {
    count: u8,
    parity: u8,
    matrices: [16]QrMatrix, // only matrices[0..count] are populated

    pub fn slice(self: *const SequenceResult) []const QrMatrix {
        return self.matrices[0..self.count];
    }
};
```

---

## C ABI Reference

Each tier exports exactly 8 public symbols (24 symbols across all tiers):

| Symbol Pattern | Purpose |
| :--- | :--- |
| `zqr_tN_encode` | Standard single-symbol encoding |
| `zqr_tN_encode_with_version` | Low-level encode with forced version and mask |
| `zqr_tN_encode_advanced` | Advanced options (Kanji, DP optimizer, FNC1, ECI) |
| `zqr_tN_encode_sequence` | Structured Append sequence encoding (1–16 symbols) |
| `zqr_tN_buffer_len` | Required module buffer length for a single symbol |
| `zqr_tN_sequence_buffer_len` | Required module buffer length for a sequence of symbols |
| `zqr_tN_max_version` | Returns maximum version supported by this tier (6, 10, or 40) |
| `zqr_tN_strerror` | Human-readable string for negative status codes |

### Return Codes

```c
#define ZQR_OK                           0
#define ZQR_ERR_DATA_TOO_LONG           -1
#define ZQR_ERR_VERSION_EXCEEDS_TIER    -2
#define ZQR_ERR_INVALID_VERSION         -3
#define ZQR_ERR_INVALID_ECC             -4
#define ZQR_ERR_INVALID_MASK            -5
#define ZQR_ERR_BUFFER_TOO_SMALL        -6
#define ZQR_ERR_NULL_POINTER            -7
#define ZQR_ERR_INVALID_SEGMENT_ORDER   -8
```

---

## Usage Examples

### Zig Consumer

```zig
const std = @import("std");
const zqr = @import("zqr");

pub fn main() !void {
    // 1. Standard single-symbol encode (Tier 1: v1..6)
    var buf: [zqr.Tier1.max_buffer_len]u8 = undefined;
    const qr = try zqr.Tier1.encode(&buf, "HELLO WORLD", .medium);
    const is_dark = qr.modules[10 * qr.size + 10] == 1;
    _ = is_dark;

    // 2. Advanced encode with DP mixing and Kanji
    const qr_adv = try zqr.Tier1.encodeAdvanced(&buf, "ABC123日本語", .{
        .ecc = .low,
        .kanji = true,
        .optimize = true,
    });
    _ = qr_adv;

    // 3. Structured Append sequence (Tier 1)
    var seq_buf: [zqr.Tier1.max_sequence_buffer_len]u8 = undefined;
    const seq = try zqr.Tier1.encodeSequence(&seq_buf, "LONG PAYLOAD TO BE SPLIT ACROSS SYMBOLS", .{
        .ecc = .low,
        .symbol_count = null, // auto-select minimal symbols
    });
    std.debug.print("Sequence: {d} symbols, parity: 0x{X:0>2}\n", .{ seq.count, seq.parity });
}
```

### C99 / C++ Consumer

```c
#include "zqr.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    // 1. Standard Single Symbol (Tier 1: max buffer 41x41 = 1681 bytes)
    uint8_t buf[41 * 41];
    zqr_matrix qr;
    int rc = zqr_t1_encode((const uint8_t *)"HELLO WORLD", 11, ZQR_ECC_MEDIUM, buf, sizeof(buf), &qr);
    if (rc != ZQR_OK) return 1;

    // 2. Structured Append Sequence
    const char *data = "LARGE PAYLOAD REQUIRING MULTIPLE QR CODES...";
    zqr_sequence_options opts = {
        .min_version = 1,
        .max_version = 6,
        .ecc = ZQR_ECC_LOW,
        .mask = -1,
        .symbol_count = 0, // auto minimal count
    };

    // Phase 1: Query required symbol count and parity
    size_t count = 0;
    uint8_t parity = 0;
    rc = zqr_t1_encode_sequence((const uint8_t *)data, strlen(data), &opts,
                                NULL, 0, NULL, 0, &count, &parity);
    if (rc != ZQR_OK) return 1;

    // Phase 2: Allocate buffers on heap and encode sequence atomically
    size_t needed_bytes = zqr_t1_sequence_buffer_len(0, count);
    uint8_t *module_buf = (uint8_t *)malloc(needed_bytes);
    zqr_matrix *matrices = (zqr_matrix *)malloc(count * sizeof(zqr_matrix));

    rc = zqr_t1_encode_sequence((const uint8_t *)data, strlen(data), &opts,
                                module_buf, needed_bytes, matrices, count,
                                &count, &parity);
    if (rc == ZQR_OK) {
        printf("Encoded sequence of %zu symbols (version %u)\n", count, matrices[0].version);
    }

    free(matrices);
    free(module_buf);
    return 0;
}
```

### Python FFI (ctypes)

```python
import ctypes

lib = ctypes.CDLL("libzqr_t3.so")

class ZqrMatrix(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint8),
        ("size", ctypes.c_uint8),
        ("ecc", ctypes.c_uint8),
        ("mask", ctypes.c_uint8),
        ("mode", ctypes.c_uint8),
        ("reserved", ctypes.c_uint8 * 3),
        ("modules", ctypes.POINTER(ctypes.c_uint8)),
    ]

buf_len = lib.zqr_t3_buffer_len(0)
buf = (ctypes.c_uint8 * buf_len)()
out = ZqrMatrix()

data = b"HELLO WORLD"
rc = lib.zqr_t3_encode(data, len(data), 1, buf, buf_len, ctypes.byref(out))
assert rc == 0
print(f"Generated Version {out.version} QR ({out.size}x{out.size})")
```

---

## Quality, Testing & Verification

- **Test Suite**: **73/73 tests** pass locally across Zig unit tests, C integration tests, and Python FFI verification.
- **Verification Commands**:
  ```bash
  zig build                      # Generates .a and .so libraries in zig-out/lib
  zig build test                 # Runs unit tests, golden fixtures, and C integration
  python3 tests/test_abi_so.py   # Validates FFI loading, SONAME tags, and symbol isolation
  ```
- **ABI & Symbol Hygiene**: Every `.so` shared object is audited via `nm -D --defined-only` to guarantee exactly 8 public symbols per tier, zero cross-tier leaks, and zero sanitizer/UBSan symbols.
- **Reference Oracle Cross-Checks**:
  - Deterministic module-by-module parity verification against Project Nayuki across all 1280 (version × ECC × mask) combinations.
  - Multi-symbol bit-by-bit sequence comparison against canonical reference (Segno) with 0 module mismatches.
- **CI / Build Automation**: Continuous Integration (CI) is **not yet configured**; test suites are executed locally.
- **Benchmarks**: Official performance benchmarks are **not yet published**.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
Copyright (c) 2026 carlos-sweb. Portions copyright (c) Project Nayuki.
