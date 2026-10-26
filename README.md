# z-libqr (libzqr)

A complete, zero-dependency QR Code Model 2 encoder in Zig 0.17.
Generates compliant QR codes from version 1 up to 40, error correction levels L, M, Q, H, and standard encoding modes according to ISO/IEC 18004.

Output is strictly the module matrix (0 = light, 1 = dark), without quiet zone or image rendering.

## Feature Status

| Category | Feature | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Core QR** | Model 2 Versions 1–40 | **Implemented** | Full geometric and capacity support |
| | ECC Levels (L, M, Q, H) | **Implemented** | Exact ISO/IEC 18004 Reed-Solomon generation |
| | 8 Mask Patterns (0–7) | **Implemented** | ISO penalty evaluation (N1–N4) + tie-break |
| | No ECL Boost | **Implemented** | Respects caller-requested error correction level |
| **Modes** | Numeric Mode | **Implemented** | Groups of 3 digits (10 bits), 2 (7b), 1 (4b) |
| | Alphanumeric Mode | **Implemented** | 45-character standard charset (11 bits / pair) |
| | Byte Mode | **Implemented** | Arbitrary binary data and UTF-8 bytes |
| | ECI Mode | **Implemented** | Extended Channel Interpretation headers |
| | Multi-Segment Input | **Implemented** | Manual heterogeneous segment composition |
| | Kanji Mode | *Optional / Deferred* | Pre-encoded Shift-JIS works via Byte mode |
| | Optimal Mode Optimizer | *Optional / Deferred* | Auto-segmentation using dynamic programming |
| | Structured Append / FNC1 | *Out of Scope* | Not in v1 specification |
| **Architecture**| Zero-Allocation Core | **Implemented** | Caller provides output module buffer |
| | Embedded Stack Budget | **Implemented** | Peak stack usage ~6.6 KB in core pipeline |
| | Symbol Isolation | **Implemented** | Multi-tier static linking without symbol collisions |
| | C ABI Export | **Implemented** | 5 stable symbols per tier, negative error codes |
| | Shared Libraries (.so) | **Implemented** | Valid ELF SONAME (`libzqr_tN.so.0`), zero UBSan leaks |

## Compatibility

- **Native Zig**: Tested with Zig 0.17.0 via `build.zig.zon` and `@import("zqr")`.
- **Cross-Compilation**: Cross-compiles out of the box to Windows (`-Dtarget=x86_64-windows-gnu`, produces DLL and `.lib`) and macOS (`-Dtarget=aarch64-macos`, produces `.dylib`).
- **Cross-Version Zig / C / Rust**: Fully compatible with Zig 0.15+, C (C99+), C++, and Rust by linking the static archives (`libzqr_tN.a`).
- **FFI / Dynamic Languages**: Loadable via `dlopen`/ctypes/Node FFI (`libzqr_tN.so` / `.dylib` / `.dll`).

## Distribution Paths

`z-libqr` is distributed in three ways:

1. **Path 1 — Zig Module**: For Zig 0.17 projects. Add via `build.zig.zon` and use `@import("zqr")`.
2. **Path 2 — Static C Libraries**: `libzqr_t1.a`, `libzqr_t2.a`, `libzqr_t3.a`. Stable C ABI linkable by any toolchain.
3. **Path 3 — Dynamic Libraries**: `libzqr_t1.so`, `libzqr_t2.so`, `libzqr_t3.so` (version 1.0.0, SONAME `libzqr_tN.so.1`).

### Tiers

To optimize binary size and memory footprint for constrained environments, `z-libqr` is partitioned into three tiers:

- **Tier 1 (`_t1`)**: QR versions 1 to 6. Max size 41×41 modules.
- **Tier 2 (`_t2`)**: QR versions 1 to 10. Max size 57×57 modules.
- **Tier 3 (`_t3`)**: Full QR versions 1 to 40. Max size 177×177 modules.

> **Linking Rule:** All three tiers use distinct symbol prefixes (`zqr_t1_`, `zqr_t2_`, `zqr_t3_`), allowing multiple tiers to be linked into the same binary without symbol collisions.

## Memory Model

The core encoder requires no memory allocator. Callers provide a module buffer sized for the symbol.
Peak stack usage is **~6.6 KB** in the core pipeline (fixed stack buffers for data codewords and Reed-Solomon interleaving), making it suitable for bare-metal, RTOS, and embedded environments.

Any input payload that would exceed buffer capacity or QR Model 2 limits is rejected with `ZQR_ERR_DATA_TOO_LONG` before any buffer operations take place.

## Usage Examples

### Path 1: Zig Module

```zig
const zqr = @import("zqr");

// Encode using Tier 1 (v1..6)
var buf: [zqr.Tier1.max_buffer_len]u8 = undefined;
const qr = try zqr.Tier1.encode(&buf, "HELLO WORLD", .medium);

// Access output matrix (size * size bytes, values 0 or 1)
const is_dark = qr.modules[y * qr.size + x] == 1;
```

### Path 2: C API

```c
#include "zqr.h"

uint8_t buf[ZQR_T1_MAX_BUFFER_LEN];
zqr_matrix qr;
int rc = zqr_t1_encode((const uint8_t *)"HELLO WORLD", 11, ZQR_ECC_MEDIUM, buf, sizeof(buf), &qr);
if (rc == ZQR_OK) {
    // qr.version, qr.size, qr.modules
}
```

### Path 3: Python ctypes (FFI)

```python
import ctypes

lib = ctypes.CDLL("libzqr_t3.so")
buf_len = lib.zqr_t3_buffer_len(0)
buf = (ctypes.c_uint8 * buf_len)()

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

out = ZqrMatrix()
data = b"HELLO WORLD"
rc = lib.zqr_t3_encode(data, len(data), 1, buf, buf_len, ctypes.byref(out))
assert rc == 0
```

## Verification & Testing

Recommended verification order:

```bash
zig build                      # Generates .a and .so libraries in zig-out/lib
zig build test                 # Runs unit tests, golden fixtures, and C integration
python3 tests/test_abi_so.py   # Validates FFI loading, SONAME tags, and symbol isolation
```

Additional testing commands:
- `zig build test-c-integration`: Compiles and runs the native C ABI integration suite standalone (linking all 3 `.a` archives simultaneously).
- `python3 tools/gen_vectors.py --exhaustive`: Verifies all 1280 possible (version × ECC × mask) combinations bit-by-bit against Project Nayuki's reference implementation.

## License

MIT License. See [LICENSE](LICENSE) for details (dual attribution with Project Nayuki).
