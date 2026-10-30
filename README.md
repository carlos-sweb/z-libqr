# z-libqr (libzqr)

A complete QR Code Model 2 **encoder and decoder** in Zig 0.17.
Encodes strictly compliant QR Code Model 2 matrices from Version 1 (21×21) to 40 (177×177), with error correction levels L, M, Q, H, dynamic programming multi-mode optimization, Kanji, FNC1, ECI, Structured Append, and rendering to SVG and PNG.
Decodes raw module matrices (Phase A) and grayscale images (Phase B: perspective, rotation, mirror, and dark-mode polarity).

- **Core encode / decode**: 100% zero-dependency, zero heap allocations, no `@cImport`.
- **SVG Rendering**: 100% zero-dependency, scalable SVG with horizontal run combining.
- **PNG Rendering**: Optional via `libpng` (`-Denable-png`, default true). Disabled builds return `ZQR_ERR_UNSUPPORTED` from `render_png`.

Encoder algorithms are a from-scratch Zig port of [Project Nayuki's QR Code generator](https://www.nayuki.io/page/qr-code-generator-library) (MIT).
Decoder Reed-Solomon and related vision/sampling logic are ported from [quirc](https://github.com/dlbeer/quirc) (ISC).

---

## Table of Contents

- [Requirements](#requirements)
- [Specification Coverage](#specification-coverage)
- [Tiered Architecture & Distribution](#tiered-architecture--distribution)
- [Memory Model & Stack Budget](#memory-model--stack-budget)
- [Core Features](#core-features)
- [Image Rendering (SVG & PNG)](#image-rendering-svg--png)
- [Zig API Reference](#zig-api-reference)
- [C ABI Reference](#c-abi-reference)
- [Usage Examples](#usage-examples)
- [Integrating as a Zig Dependency](#integrating-as-a-zig-dependency)
- [Known Limitations](#known-limitations)
- [Design Notes](#design-notes)
- [Version History](#version-history)
- [Quality, Testing & Verification](#quality-testing--verification)
- [License](#license)

---

## Requirements

- **Zig 0.17.0** (see `minimum_zig_version` in `build.zig.zon`).
- Verify your toolchain: `zig version`
- This package is **not** published to a Zig package registry. Consumers depend on it by **URL + content hash** in their `build.zig.zon` (see [Integrating as a Zig Dependency](#integrating-as-a-zig-dependency)).
- Optional: system `libpng` when building with `-Denable-png=true` (the default).

---

## Specification Coverage

`z-libqr` implements QR Code Model 2 according to **ISO/IEC 18004:2015**:

| Scope Area | Feature / Capability | Status | Details |
| :--- | :--- | :--- | :--- |
| **Model 2 Core** | Versions 1 to 40 | **Complete** | Geometries from 21×21 to 177×177 modules |
| | ECC Levels (L, M, Q, H) | **Complete** | Exact Reed-Solomon generation; no automatic boost |
| | Mask Patterns 0–7 | **Complete** | Full ISO penalty evaluation (N1–N4) + tie-breaking |
| **Encoding Modes** | Numeric / Alphanumeric / Byte | **Complete** | Standard ISO packing |
| | ECI Mode | **Complete** | Assignment numbers 0..999999 |
| | Kanji Mode | **Complete** | JIS X 0208 UTF-8 mapping to 13-bit codewords |
| | Mode Mixing (Optimizer) | **Complete** | Dynamic programming cost optimization in 1/6 bit |
| | FNC1 First / Second | **Complete** | GS1 and AIM application indicator |
| | Structured Append | **Complete** | Encode 1..16 linked symbols; decode reports SA metadata |
| **Decoder** | Matrix decode (Phase A) | **Complete** | Raw modules → payload + metadata |
| | Image decode (Phase B) | **Complete** | Grayscale pixels; perspective / rotation / mirror / dark mode |
| **Rendering** | SVG Document | **Complete** | Zero-dependency path combining |
| | PNG Image | **Complete** | Optional `libpng` (RGBA rasterization) |
| **Explicitly Out of Scope** | Micro QR (M1–M4) | *Out of Scope* | Model 2 only |
| | QR Code Model 1 | *Out of Scope* | Obsolete |
| | Multi-QR iteration in one image | *Out of Scope* | Best single triad only |
| | SA sequence reassembly | *Out of Scope* | Metadata reported; caller joins fragments |
| | GS1 AI Syntax Validation | *Out of Scope* | FNC1 headers only |

---

## Tiered Architecture & Distribution

To minimize binary footprint and stack memory in embedded environments, `z-libqr` is partitioned into three compile-time tiers:

- **Tier 1 (`_t1`)**: QR Versions 1 to 6. Max size 41×41 modules.
- **Tier 2 (`_t2`)**: QR Versions 1 to 10. Max size 57×57 modules.
- **Tier 3 (`_t3`)**: Full QR Versions 1 to 40. Max size 177×177 modules.

> **Linking Rule:** All tiers use unique public symbol prefixes (`zqr_t1_`, `zqr_t2_`, `zqr_t3_`), so different tiers can be linked into one binary without symbol collision.

### Distribution Formats

1. **Zig Package**: `build.zig.zon` + `@import("zqr")`. Exposes `zqr.Tier1`/`Tier2`/`Tier3` (`Encoder`) and `zqr.DecoderTier1`/`DecoderTier2`/`DecoderTier3` (`Decoder`).
2. **Static C Libraries**: `libzqr_t1.a`, `libzqr_t2.a`, `libzqr_t3.a`.
3. **Dynamic Shared Libraries**: `libzqr_t1.so`, `libzqr_t2.so`, `libzqr_t3.so` (package version 1.5.0, ELF SONAME `libzqr_tN.so.1`).

Build artifacts:

```bash
zig build                      # .a + .so for all tiers in zig-out/lib, header in zig-out/include
zig build -Denable-png=false   # standalone: no libpng / no libc for the core libraries
```

---

## Memory Model & Stack Budget

`z-libqr` enforces a **zero-allocation core** for encode and decode:

- No heap allocations on encode / matrix-decode / image-decode paths (`decodeImage` uses a caller scratch buffer).
- Convenience helper `decodeImageAlloc` is the only Zig decode path that allocates (scratch only).
- Module and payload output storage is always provided by the caller.

### Measured Stack Budgets

| Execution Path | Tier 1 (v1–6) | Tier 2 (v1–10) | Tier 3 (v1–40) |
| :--- | :--- | :--- | :--- |
| **Standard Pipeline (`optimize: false`)** | ~1.2 KB | ~1.8 KB | **~6.6 KB** |
| **DP Optimizer (`optimize: true`, worst-case)** | ~1.8 KB | ~3.2 KB | **~12.9 KB** |
| **Structured Append (`encodeSequence`, frame + DP)** | ~2.5 KB | ~4.1 KB | **~15.3 KB** |

> [!WARNING]
> For a maximum sequence of N=16 symbols of Version 40, the output `module_storage` buffer requires ~490 KB (`16 × 177²` bytes).
> Allocate that buffer on the heap. Use `sequenceBufferLen(0, N)` / `zqr_tN_sequence_buffer_len(0, N)`.

### Module matrix invariant

Encoded (and matrix-decoded) modules are:

- One byte per module, values `0` (light) or `1` (dark)
- Row-major, **no quiet zone**
- `size == 21 + 4 * (version - 1)`; buffer length `size * size`

---

## Core Features

### Kanji Mode (JIS X 0208)

- Converts UTF-8 strings of JIS X 0208 characters into 13-bit QR Kanji codewords.
- Static lookup table of 6,879 sorted entries (27.5 KiB `.rodata`), binary search.
- Opt-in via `kanji: true` in `Options` / `SequenceOptions`.

### Optimal Multi-Mode Optimizer (DP Mixing)

- Dynamic programming across Numeric, Alphanumeric, Byte, and Kanji (1/6-bit cost units, Nayuki algorithm).
- Segment budget fallback: if adversarial input exceeds the tier segment budget (32 / 48 / 128), falls back to single Byte mode.

### FNC1 & GS1 QR Codes

- **First Position**: GS1 QR Code identification.
- **Second Position**: AIM application indicator (0..99 digits, or `c + 100` for letters).
- Segment order when both ECI and FNC1 are set: `[ECI, FNC1, Data...]`.
- Caller places `0x1D` (GS) separators; the library does not validate GS1 AI syntax.

### Structured Append Sequences

- Encodes large payloads across 1 to 16 linked symbols.
- Auto or forced symbol count; N=1 is identical to a normal single-symbol encode.
- Automatic XOR parity; FNC1 only on symbol 0; ECI repeated on every symbol.
- Two-phase dry-run with `module_storage: null` (Zig) or `buf == NULL || out == NULL` (C).
- **Decode** reports `has_sa` / position / total / parity and does **not** reassemble the sequence.

---

## Image Rendering (SVG & PNG)

```zig
pub const Shape = enum(u8) {
    square = 0,
    rounded = 1,
};

pub const RenderOptions = struct {
    quiet_zone: u8 = 4,
    scale: u8 = 8,
    dot_shape: Shape = .square,
    eye_shape: Shape = .square,
    foreground: u32 = 0x000000FF,
    background: u32 = 0xFFFFFFFF,
};
```

### Rendering Options Reference

| Option | Values | Default | Description |
| :--- | :--- | :--- | :--- |
| `quiet_zone` | `0..255` | `4` | Quiet zone margin around symbol (in modules). |
| `scale` | `1..255` | `8` | Pixels per module. |
| `dot_shape` | `square`, `rounded` | `square` | Data modules shape. `rounded` renders smooth connected blobs with rounded corners. |
| `eye_shape` | `square`, `rounded` | `square` | 3 corner finder patterns shape. `rounded` renders 1:1:3:1:1 concentric circles. |
| `foreground` | `#RRGGBB[AA]` / `u32` | `0x000000FF` | Foreground color (RGBA). |
| `background` | `#RRGGBB[AA]` / `u32` | `0xFFFFFFFF` | Background color (RGBA). |

> [!NOTE]
> Alignment patterns (for Version $\ge 2$) remain square and are not affected by `eye_shape` (only the 3 corner finders are changed).

### SVG (zero-dependency)

- `calcSvgLen` / `renderSvgBuffer` / `renderSvg` via `zqr.render`.
- Produces clean vector paths with subpath consolidation.
- When `dot_shape = .rounded`, uses continuous smooth path outlines with rounded corners; when `eye_shape = .rounded`, generates concentric circles with exact 1:1:3:1:1 proportions.

### PNG (optional libpng)

- Requires host `libpng` when `-Denable-png=true`:
  - Fedora / RHEL: `sudo dnf install libpng-devel`
  - Debian / Ubuntu: `sudo apt install libpng-dev`
  - macOS: `brew install libpng`
- With `-Denable-png=false`, `render_png` returns `-9` (`ZQR_ERR_UNSUPPORTED`).
- Smooth blob shapes and circular finder patterns use $2 \times 2$ supersampling anti-aliasing with alpha blending against background color.
- Implemented via an isolated C wrapper (`c/zqr_png_wrapper.c`) and `extern "c" fn zqr_png_write` — the Zig sources never use `@cImport`.

---

## Zig API Reference

Types are parameterized by maximum version:

```zig
pub fn Encoder(comptime max_version: u8) type { ... }
pub fn Decoder(comptime max_version: u8) type { ... }

pub const Tier1 = Encoder(6);   // also Tier2=10, Tier3=40
pub const DecoderTier1 = Decoder(6);
pub const DecoderTier2 = Decoder(10);
pub const DecoderTier3 = Decoder(40);
```

### Encoder (on `TierN` / `Encoder(N)`)

```zig
pub fn encode(buf: []u8, data: []const u8, ecc: Ecc) Error!QrMatrix;
pub fn encodeWithVersion(buf: []u8, data: []const u8, version: u8, ecc: Ecc, forced_mask: ?u3) Error!QrMatrix;
pub fn encodeAdvanced(buf: ?[]u8, data: []const u8, options: Options) Error!QrMatrix;
pub fn encodeSequence(module_storage: ?[]u8, data: []const u8, options: SequenceOptions) Error!SequenceResult;
pub fn bufferLen(version: u8) Error!usize;
pub fn sequenceBufferLen(version: u8, count: u8) Error!usize;
```

### Decoder (on `DecoderTierN` / `Decoder(N)`)

```zig
pub fn decode(modules: []const u8, size: u8, out_buf: []u8) DecodeError!DecodeResult;
pub fn decodeImage(pixels: []const u8, width: usize, height: usize, scratch_buf: []u8, out_buf: []u8) ImageDecodeError!DecodeResult;
pub fn bufferLen(version: u8, ecc: Ecc) DecodeError!usize;
pub fn imageBufferLen(width: usize, height: usize) usize; // also at package root
```

Package-root helpers: `zqr.decodeBufferLen`, `zqr.imageBufferLen`.

### Key result types

```zig
pub const QrMatrix = struct {
    version: u8,
    size: u8,       // 21 + 4*(version-1)
    ecc: Ecc,
    mask: u3,
    mode: Mode,
    modules: []const u8, // borrows caller buffer; 0/1, no quiet zone
};

pub const DecodeResult = struct {
    data: []const u8,       // slice of caller out_buf
    metadata: DecodeMetadata,
};

pub const DecodeMetadata = struct {
    version: u8,
    ecc: Ecc,
    mask: u3,
    modes_used: u8 = 0,
    eci: ?u32 = null,
    fnc1_mode: ?Fnc1Mode = null,
    fnc1_app_indicator: ?u8 = null,
    sa: ?StructuredAppend = null,
    errors_corrected_format: u8 = 0,
    errors_corrected_version: u8 = 0,
    errors_corrected_data: u16 = 0,
};
```

**Caller-buffer contract:** the library never owns output memory. Undersized buffers return `error.BufferTooSmall` / `ZQR_ERR_*_BUFFER_TOO_SMALL`. Image decode also requires a scratch buffer of length `imageBufferLen(w, h)`.

---

## C ABI Reference

Each tier exports **exactly 16** public symbols:

| Symbol Pattern | Purpose |
| :--- | :--- |
| `zqr_tN_encode` | Standard single-symbol encode |
| `zqr_tN_encode_with_version` | Forced version and mask |
| `zqr_tN_encode_advanced` | Kanji, DP optimizer, FNC1, ECI |
| `zqr_tN_encode_sequence` | Structured Append (1–16 symbols) |
| `zqr_tN_render_svg` | SVG string (dry-run with `buf == NULL`) |
| `zqr_tN_render_png` | PNG bytes (dry-run with `buf == NULL`) |
| `zqr_tN_decode` | Matrix decode |
| `zqr_tN_decode_image` | Image decode from raw grayscale pixels |
| `zqr_tN_decode_buffer_len` | Payload buffer upper bound |
| `zqr_tN_image_buffer_len` | Scratch buffer size for image decode |
| `zqr_tN_decode_strerror` | Decoder error string |
| `zqr_tN_decode_image_strerror` | Image decoder error string |
| `zqr_tN_buffer_len` | Module buffer length for one symbol |
| `zqr_tN_sequence_buffer_len` | Module buffer length for a sequence |
| `zqr_tN_max_version` | 6, 10, or 40 |
| `zqr_tN_strerror` | Encoder/render error string |

`zqr_decode_result` is a fixed **28-byte** ABI struct (stable since v1.4.0) on 32-bit and 64-bit hosts. See `include/zqr.h` for field offsets and semantics.

### Encoder / render return codes

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
#define ZQR_ERR_UNSUPPORTED             -9
```

### Decoder return codes

```c
#define ZQR_DECODE_OK                          0
#define ZQR_ERR_DECODE_INVALID_SIZE          -20
#define ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER  -21
#define ZQR_ERR_DECODE_FORMAT_UNCORRECTABLE  -22
#define ZQR_ERR_DECODE_VERSION_UNCORRECTABLE -23
#define ZQR_ERR_DECODE_RS_UNCORRECTABLE      -24
#define ZQR_ERR_DECODE_INVALID_MODE          -25
#define ZQR_ERR_DECODE_INVALID_PAYLOAD       -26
#define ZQR_ERR_DECODE_UNEXPECTED_EOF        -27
#define ZQR_ERR_DECODE_BUFFER_TOO_SMALL      -28
#define ZQR_ERR_DECODE_NULL_POINTER          -29
#define ZQR_ERR_DECODE_IMAGE_TOO_LARGE       -30
#define ZQR_ERR_DECODE_NO_FINDERS            -31
#define ZQR_ERR_DECODE_INVALID_IMAGE         -32
```

Full prototypes and preconditions: [`include/zqr.h`](include/zqr.h) (canonical docs on `zqr_t3_*`).

---

## Usage Examples

### Zig — encode

```zig
const std = @import("std");
const zqr = @import("zqr");

pub fn main() !void {
    var buf: [zqr.Tier1.max_buffer_len]u8 = undefined;
    const qr = try zqr.Tier1.encode(&buf, "HELLO WORLD", .medium);
    const is_dark = qr.modules[10 * qr.size + 10] == 1;
    _ = is_dark;
}
```

### Zig — decode matrix (round-trip)

```zig
const zqr = @import("zqr");

pub fn main() !void {
    var mat_buf: [zqr.Tier1.max_buffer_len]u8 = undefined;
    const qr = try zqr.Tier1.encode(&mat_buf, "HELLO WORLD", .medium);

    var out_buf: [256]u8 = undefined;
    const decoded = try zqr.DecoderTier1.decode(qr.modules, qr.size, &out_buf);
    // decoded.data == "HELLO WORLD"
    _ = decoded;
}
```

### Zig — decode image (caller-provided grayscale + scratch)

```zig
const zqr = @import("zqr");

pub fn main() !void {
    // Caller loads a file (PNG/JPEG/…) into 8-bit grayscale: 0=dark, 255=light.
    // Below: placeholder dimensions; replace pixels with real image data.
    const width: usize = 200;
    const height: usize = 200;
    var pixels: [width * height]u8 = undefined; // fill from your loader
    @memset(&pixels, 255);

    // scratch length must be >= zqr.imageBufferLen(width, height)
    var scratch: [width * height * 5 + 3]u8 = undefined;
    var out_buf: [zqr.DecoderTier3.max_decoded_len]u8 = undefined;

    const decoded = try zqr.DecoderTier3.decodeImage(
        pixels[0..],
        width,
        height,
        scratch[0..],
        &out_buf,
    );
    _ = decoded.data;
}
```

### C — static library (`.a`)

```bash
zig build -Doptimize=ReleaseFast
gcc main.c -Izig-out/include -Lzig-out/lib -l:libzqr_t3.a -lpng -lm -o main
# With -Denable-png=false, omit -lpng.
# Prefer -l:libzqr_t3.a over -lzqr_t3 when both .a and .so share the same -L path.
```

```c
#include "zqr.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    uint8_t mat[41 * 41];
    zqr_matrix qr;
    int rc = zqr_t1_encode((const uint8_t *)"HELLO WORLD", 11,
                           ZQR_ECC_MEDIUM, mat, sizeof(mat), &qr);
    if (rc != ZQR_OK) return 1;

    uint8_t out[256];
    zqr_decode_result result;
    rc = zqr_t1_decode(qr.modules, qr.size, out, sizeof(out), &result);
    if (rc != ZQR_DECODE_OK) return 1;
    fwrite(out, 1, result.bytes_written, stdout);
    putchar('\n');
    return 0;
}
```

### C — dynamic library (`dlopen`)

```c
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include "zqr.h"

typedef int (*encode_fn)(const uint8_t *, size_t, int, uint8_t *, size_t, zqr_matrix *);
typedef int (*decode_fn)(const uint8_t *, uint8_t, uint8_t *, size_t, zqr_decode_result *);

int main(void) {
    void *h = dlopen("libzqr_t3.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }

    encode_fn encode = (encode_fn)dlsym(h, "zqr_t3_encode");
    decode_fn decode = (decode_fn)dlsym(h, "zqr_t3_decode");
    if (!encode || !decode) return 1;

    uint8_t mat[177 * 177];
    zqr_matrix qr;
    if (encode((const uint8_t *)"HELLO", 5, ZQR_ECC_MEDIUM, mat, sizeof(mat), &qr) != ZQR_OK)
        return 1;

    uint8_t out[256];
    zqr_decode_result result;
    if (decode(qr.modules, qr.size, out, sizeof(out), &result) != ZQR_DECODE_OK)
        return 1;

    fwrite(out, 1, result.bytes_written, stdout);
    putchar('\n');
    dlclose(h);
    return 0;
}
```

```bash
# Ensure the loader finds the .so, e.g.:
#   LD_LIBRARY_PATH=zig-out/lib ./main_dl
# or install with a proper rpath/SONAME layout.
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

## Integrating as a Zig Dependency

Add to your consumer `build.zig.zon` (URL + hash; not a registry package):

```zig
.dependencies = .{
    .zqr = .{
        .url = "git+https://github.com/carlos-sweb/z-libqr?ref=v1.5.0#314991e55d53b97f04712d6f443e74daa16e886e",
        .hash = "z_libqr-1.5.0-P-K0qtdcCACgsLzEb3-aR1Ne2XDR9wrrIVeQ41ZD1Y7g",
    },
},
```

In `build.zig`:

```zig
const zqr_dep = b.dependency("zqr", .{
    .target = target,
    .optimize = optimize,
    .@"enable-png" = enable_png, // optional; default true
});
exe_mod.addImport("zqr", zqr_dep.module("zqr"));
```

Then `@import("zqr")` in application code. A path-based local example lives in [`examples/zig-consumer/`](examples/zig-consumer/).

---

## Known Limitations

- **One QR per image:** `decodeImage` selects the single best right-isosceles finder triad by geometric score. It does not iterate remaining triads or return multiple payloads.
- **Structured Append:** encode produces linked symbols; decode reports `has_sa` / `sa_position` / `sa_total` / `sa_parity` (and Zig `metadata.sa`) but does **not** concatenate the full sequence.
- **ImageTooLarge:** images with `width * height > 16_843_008` are rejected (`error.ImageTooLarge` / `ZQR_ERR_DECODE_IMAGE_TOO_LARGE`).
- **ABI size:** `sizeof(zqr_decode_result) == 28` on 32-bit and 64-bit (asserted in `src/c_api.zig`).
- **No `@cImport`:** Zig sources stay free of `@cImport`. Optional PNG uses a small C wrapper + `extern "c"`.
- **PNG is opt-in in this library** (`-Denable-png`), separate from any CLI that may also use libpng to *load* images for decode.

---

## Design Notes

- **Three tiers:** embedded and size-sensitive consumers can ship v1–6 or v1–10 without paying Version 40 stack and `.rodata` cost.
- **Tier prefixes on C symbols:** `zqr_t1_` / `zqr_t2_` / `zqr_t3_` never collide, so multiple `.a`/`.so` tiers can coexist in one process.
- **Fixed 28-byte decode result:** stable cross-platform C ABI without pointers inside the struct; payload lives in the caller `out` buffer.
- **Caller-provided buffers:** keeps the library free of Zig allocator ABI churn and makes the C API trivial (`malloc` on the caller side).
- **GF(256) divergence:** the encoder multiplies with Russian peasant (no tables, rare path relative to decode); the decoder uses exp/log tables from quirc (hot Reed-Solomon path). Intentional.
- **Raw pixels for image decode:** the library stays format-agnostic and keeps libpng out of the decode core. Callers decode PNG/JPEG/… themselves (or use a CLI helper).

---

## Version History

- **v1.0.0:** initial release.
- **v1.1.0:** Kanji, DP optimizer, FNC1/GS1.
- **v1.2.0:** Structured Append (`encodeSequence`).
- **v1.3.0:** SVG (zero-dep) and PNG (`libpng` wrapper) rendering.
- **v1.4.0:** Model 2 matrix decoder (Phase A) and C decode ABI; `zqr_decode_result` 28 B.
- **v1.5.0:** Image decoder (Phase B); `decode_image` / `image_buffer_len` C symbols (16 per tier).

Semver: `v1.x` is backward-compatible for documented APIs; majors may break.

---

## Quality, Testing & Verification

- **Test Suite:** **149/149** Zig unit tests pass (`zig build test --summary all`), plus a C ABI integration executable that links all three static tiers.
- **Commands:**
  ```bash
  zig build                      # .a and .so in zig-out/lib
  zig build test                 # unit tests, golden fixtures, C integration
  zig fmt --check build.zig build.zig.zon src tests
  python3 tests/test_abi_so.py   # FFI load, SONAME, 16-symbol isolation per tier
  ```
- **ABI hygiene:** each tier `.so` exports exactly **16** `zqr_tN_*` symbols (verified by `nm` / `test_abi_so.py`).
- **Reference oracles:** Nayuki bit-exact encode vectors; sequence checks against reference tooling where applicable.
- **CI:** not yet configured; suites run locally.

---

## License

MIT License for z-libqr and the Nayuki-derived encoder portions. See [LICENSE](LICENSE).

Decoder portions derived from **quirc** are under the **ISC License** (Copyright (C) 2010-2012 Daniel Beer). The full ISC notice is included in [LICENSE](LICENSE).

- Nayuki: https://www.nayuki.io/page/qr-code-generator-library
- quirc: https://github.com/dlbeer/quirc
