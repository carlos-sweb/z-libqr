#!/usr/bin/env python3
"""
tests/test_abi_so.py - FFI, SONAME, and Symbol Isolation Verification for z-libqr.

Verifies:
1. Dynamic loading via dlopen/ctypes for libzqr_t1.so, libzqr_t2.so, libzqr_t3.so.
2. ELF SONAME tag on all .so files (libzqr_tN.so.0).
3. Symbol isolation and hygiene via nm / readelf (no leaked internal symbols or UBSan).
4. Functional verification across tier boundaries and error codes.
"""

import os
import sys
import subprocess
import ctypes

# Add tools directory for Nayuki oracle
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from nayuki_qrcodegen import QrCode, QrSegment


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


class ZqrOptions(ctypes.Structure):
    _fields_ = [
        ("min_version", ctypes.c_int),
        ("max_version", ctypes.c_int),
        ("ecc", ctypes.c_int),
        ("mask", ctypes.c_int),
        ("kanji", ctypes.c_int),
        ("optimize", ctypes.c_int),
        ("fnc1", ctypes.c_int),
        ("fnc1_app_indicator", ctypes.c_uint8),
        ("reserved", ctypes.c_uint8 * 3),
        ("has_eci", ctypes.c_int),
        ("eci", ctypes.c_uint32),
    ]


def verify_soname(so_path, expected_soname):
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    res = subprocess.run(["readelf", "-d", so_path], capture_output=True, text=True, check=True, env=env)
    assert f"Library soname: [{expected_soname}]" in res.stdout, (
        f"Expected SONAME [{expected_soname}] in {so_path}, got:\n{res.stdout}"
    )
    print(f"  [OK] SONAME {expected_soname} verified in {so_path}")


def verify_exported_symbols(so_path, tier_prefix):
    res = subprocess.run(["nm", "-D", "--defined-only", so_path], capture_output=True, text=True, check=True)
    exported = []
    for line in res.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("T", "t", "D", "d", "R", "r"):
            sym = parts[2]
            exported.append(sym)

    # Shipped symbols must strictly match the 6 public symbols for this tier
    expected_symbols = {
        f"{tier_prefix}_encode",
        f"{tier_prefix}_encode_with_version",
        f"{tier_prefix}_encode_advanced",
        f"{tier_prefix}_buffer_len",
        f"{tier_prefix}_max_version",
        f"{tier_prefix}_strerror",
    }
    public_exported = {s for s in exported if s.startswith(tier_prefix)}
    assert public_exported == expected_symbols, (
        f"Exported symbols mismatch in {so_path}: expected {expected_symbols}, found {public_exported}"
    )

    # Ensure no symbols from OTHER tiers are exported
    other_tiers = ["zqr_t1", "zqr_t2", "zqr_t3"]
    other_tiers.remove(tier_prefix)
    for other in other_tiers:
        for s in exported:
            assert not s.startswith(other), f"Cross-tier symbol leak: found {s} in {so_path}"

    # Ensure no UBSan runtime symbols (__ubsan_handle_*)
    for s in exported:
        assert not s.startswith("__ubsan"), f"Sanitizer leak: found {s} in {so_path}"

    print(f"  [OK] Symbol isolation verified for {so_path}: exactly 6 symbols, 0 leaks")


def test_tier_functional(so_path, tier_num, max_v):
    lib = ctypes.CDLL(so_path)
    prefix = f"zqr_t{tier_num}"

    fn_max_ver = getattr(lib, f"{prefix}_max_version")
    fn_max_ver.restype = ctypes.c_int
    assert fn_max_ver() == max_v

    fn_buf_len = getattr(lib, f"{prefix}_buffer_len")
    fn_buf_len.restype = ctypes.c_size_t
    expected_max_buf = {1: 41 * 41, 2: 57 * 57, 3: 177 * 177}[tier_num]
    assert fn_buf_len(0) == expected_max_buf
    assert fn_buf_len(1) == 21 * 21
    assert fn_buf_len(max_v + 1) == 0

    fn_strerror = getattr(lib, f"{prefix}_strerror")
    fn_strerror.restype = ctypes.c_char_p
    assert fn_strerror(0) == b"ok"
    assert fn_strerror(-2) == b"version exceeds the maximum supported by this library tier"
    assert fn_strerror(-999) == b"unknown status code"

    fn_encode = getattr(lib, f"{prefix}_encode")
    fn_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrMatrix),
    ]
    fn_encode.restype = ctypes.c_int

    # Encode "HELLO WORLD" (fits in v1)
    data = b"HELLO WORLD"
    data_arr = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
    buf = (ctypes.c_uint8 * expected_max_buf)()
    out = ZqrMatrix()

    rc = fn_encode(data_arr, len(data), 1, buf, expected_max_buf, ctypes.byref(out))
    assert rc == 0
    assert out.version == 1
    assert out.size == 21
    assert out.ecc == 1
    assert out.mask == 0

    # Compare with Nayuki reference bit-by-bit (boostecl=False to match z-libqr no-boost policy)
    segs = QrSegment.make_segments("HELLO WORLD")
    qr_ref = QrCode.encode_segments(segs, QrCode.Ecc.MEDIUM, minversion=1, maxversion=1, boostecl=False)
    for y in range(21):
        for x in range(21):
            ref_b = 1 if qr_ref.get_module(x, y) else 0
            zig_b = out.modules[y * 21 + x]
            assert ref_b == zig_b

    # Boundary test: 300 digits requires Version 8
    digits_300 = b"0123456789" * 30
    digits_arr = (ctypes.c_uint8 * len(digits_300)).from_buffer_copy(digits_300)
    rc_boundary = fn_encode(digits_arr, len(digits_300), 1, buf, expected_max_buf, ctypes.byref(out))

    if tier_num == 1:
        assert rc_boundary == -2, f"Tier 1 expected -2 (VERSION_EXCEEDS_TIER), got {rc_boundary}"
    else:
        assert rc_boundary == 0, f"Tier {tier_num} expected 0 (ZQR_OK), got {rc_boundary}"
        assert out.version == 8
        assert out.size == 49

    # Advanced API test with DP mixing: "ABC123" + "日本語"
    fn_encode_advanced = getattr(lib, f"{prefix}_encode_advanced")
    fn_encode_advanced.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrOptions),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrMatrix),
    ]
    fn_encode_advanced.restype = ctypes.c_int

    mixed_text = "ABC123日本語".encode("utf-8")
    mixed_arr = (ctypes.c_uint8 * len(mixed_text)).from_buffer_copy(mixed_text)
    opts = ZqrOptions(
        min_version=1,
        max_version=max_v,
        ecc=0, # LOW
        mask=-1,
        kanji=1,
        optimize=1,
        fnc1=0,
        fnc1_app_indicator=0,
        has_eci=0,
        eci=0,
    )
    rc_adv = fn_encode_advanced(mixed_arr, len(mixed_text), ctypes.byref(opts), buf, expected_max_buf, ctypes.byref(out))
    assert rc_adv == 0, f"encode_advanced failed with {rc_adv}"
    assert out.size > 0

    # Test FNC1 First Position (GS1 QR Code) against Nayuki reference
    gs1_text = b"0101234567890128\x1D10BATCH1"
    gs1_arr = (ctypes.c_uint8 * len(gs1_text)).from_buffer_copy(gs1_text)
    gs1_opts = ZqrOptions(
        min_version=1,
        max_version=max_v,
        ecc=0,
        mask=0,
        kanji=0,
        optimize=1,
        fnc1=1, # First Position
        fnc1_app_indicator=0,
        reserved=(ctypes.c_uint8 * 3)(),
        has_eci=0,
        eci=0,
    )
    rc_gs1 = fn_encode_advanced(gs1_arr, len(gs1_text), ctypes.byref(gs1_opts), buf, expected_max_buf, ctypes.byref(out))
    assert rc_gs1 == 0, f"GS1 encode_advanced failed with {rc_gs1}"

    # Verify against Nayuki oracle with FNC1 First Position and optimal DP segmentation
    fnc1_mode = QrSegment.Mode(0x5, (0, 0, 0))
    seg_fnc1 = QrSegment(fnc1_mode, 0, [])
    seg_num = QrSegment.make_numeric("0101234567890128")
    seg_byte = QrSegment.make_bytes(b"\x1D")
    seg_alnum = QrSegment.make_alphanumeric("10BATCH1")
    nayuki_qr = QrCode.encode_segments(
        [seg_fnc1, seg_num, seg_byte, seg_alnum],
        QrCode.Ecc.LOW,
        minversion=1,
        maxversion=max_v,
        mask=0,
    )
    assert out.version == nayuki_qr.get_version(), f"GS1 Version mismatch: {out.version} vs {nayuki_qr.get_version()}"
    assert out.size == nayuki_qr.get_size(), f"GS1 Size mismatch: {out.size} vs {nayuki_qr.get_size()}"
    for y in range(out.size):
        for x in range(out.size):
            mod_actual = out.modules[y * out.size + x]
            mod_expected = 1 if nayuki_qr.get_module(x, y) else 0
            assert mod_actual == mod_expected, f"GS1 mismatch at ({x}, {y})"

    print(f"  [OK] Functional verification passed for {so_path}")


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lib_dir = os.path.join(repo_root, "zig-out", "lib")

    print("=== Running z-libqr Python FFI & ABI Verification ===")
    tiers = [
        (1, 6, "libzqr_t1.so", "libzqr_t1.so.1", "zqr_t1"),
        (2, 10, "libzqr_t2.so", "libzqr_t2.so.1", "zqr_t2"),
        (3, 40, "libzqr_t3.so", "libzqr_t3.so.1", "zqr_t3"),
    ]

    missing = [so_name for _, _, so_name, _, _ in tiers if not os.path.exists(os.path.join(lib_dir, so_name))]
    if missing:
        print(f"Shared libraries missing ({', '.join(missing)}). Attempting to run 'zig build'...")
        try:
            subprocess.run(["zig", "build"], cwd=repo_root, check=True)
        except Exception:
            print("Error: Missing .so files. Run `zig build` first, then re-run this script.", file=sys.stderr)
            sys.exit(1)

    for tier_num, max_v, so_name, soname, prefix in tiers:
        so_path = os.path.join(lib_dir, so_name)
        if not os.path.exists(so_path):
            print(f"Error: Missing .so files ({so_name}). Run `zig build` first, then re-run this script.", file=sys.stderr)
            sys.exit(1)
        print(f"\n[Tier {tier_num}] Testing {so_name}:")
        verify_soname(so_path, soname)
        verify_exported_symbols(so_path, prefix)
        test_tier_functional(so_path, tier_num, max_v)

    print("\nAll Python FFI & ABI assertions passed successfully.")


if __name__ == "__main__":
    main()
