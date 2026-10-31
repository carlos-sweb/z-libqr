#!/usr/bin/env python3
"""
tests/test_abi_so.py - FFI, SONAME, and Symbol Isolation Verification for z-libqr.

Verifies:
1. Dynamic loading via dlopen/ctypes for libzqr_t1.so, libzqr_t2.so, libzqr_t3.so.
2. ELF SONAME tag on all .so files (libzqr_tN.so.1).
3. Symbol isolation and hygiene via nm / readelf (exactly 18 zqr_tN_* symbols per tier; no UBSan leaks).
4. Functional verification across tier boundaries and error codes.
"""

import os
import sys
import subprocess
import ctypes
import io
from PIL import Image

# Add tools directory for Nayuki oracle and local segno package
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
sys.path.insert(0, "/home/sweb/.gemini/antigravity-cli/brain/c3d125df-aac2-4820-846d-82cc562a7c29/scratch/py_pkg")
from nayuki_qrcodegen import QrCode, QrSegment
import segno
import segno.encoder


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


class ZqrSequenceOptions(ctypes.Structure):
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
        ("symbol_count", ctypes.c_int),
    ]


class ZqrRenderOptions(ctypes.Structure):
    _fields_ = [
        ("quiet_zone", ctypes.c_uint8),
        ("scale", ctypes.c_uint8),
        ("reserved", ctypes.c_uint8 * 2),
        ("foreground", ctypes.c_uint32),
        ("background", ctypes.c_uint32),
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

    # Shipped symbols must strictly match the 18 public tier symbols (v1.6.x ABI).
    # Non-tier exports such as zqr_png_write (PNG wrapper) are ignored by the prefix filter.
    expected_symbols = {
        f"{tier_prefix}_encode",
        f"{tier_prefix}_encode_with_version",
        f"{tier_prefix}_encode_advanced",
        f"{tier_prefix}_encode_sequence",
        f"{tier_prefix}_render_svg",
        f"{tier_prefix}_render_svg_ex",
        f"{tier_prefix}_render_png",
        f"{tier_prefix}_render_png_ex",
        f"{tier_prefix}_decode",
        f"{tier_prefix}_decode_image",
        f"{tier_prefix}_decode_buffer_len",
        f"{tier_prefix}_image_buffer_len",
        f"{tier_prefix}_decode_strerror",
        f"{tier_prefix}_decode_image_strerror",
        f"{tier_prefix}_buffer_len",
        f"{tier_prefix}_sequence_buffer_len",
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

    print(f"  [OK] Symbol isolation verified for {so_path}: exactly 18 symbols, 0 leaks")


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

    # --- Structured Append Verification (Increment 15) ---
    fn_seq_buf_len = getattr(lib, f"{prefix}_sequence_buffer_len")
    fn_seq_buf_len.restype = ctypes.c_size_t
    assert fn_seq_buf_len(0, 0) == 16 * expected_max_buf
    assert fn_seq_buf_len(1, 3) == 3 * (21 * 21)
    assert fn_seq_buf_len(max_v + 1, 1) == 0
    assert fn_seq_buf_len(1, 17) == 0

    fn_encode_seq = getattr(lib, f"{prefix}_encode_sequence")
    fn_encode_seq.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrSequenceOptions),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrMatrix),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.POINTER(ctypes.c_uint8),
    ]
    fn_encode_seq.restype = ctypes.c_int

    sa_text = b"hello world 123 foo! structured append test bar! final piece xyz."
    sa_arr = (ctypes.c_uint8 * len(sa_text)).from_buffer_copy(sa_text)
    seq_opts = ZqrSequenceOptions(
        min_version=2,
        max_version=max_v,
        ecc=0, # LOW
        mask=0,
        kanji=0,
        optimize=0, # single mode to align with standard byte encoder
        fnc1=0,
        fnc1_app_indicator=0,
        reserved=(ctypes.c_uint8 * 3)(),
        has_eci=0,
        eci=0,
        symbol_count=3,
    )

    # 1. Dry-run query: NULL buffer returns required count and parity without writing
    out_count_query = ctypes.c_size_t(0)
    out_parity_query = ctypes.c_uint8(0)
    rc_query = fn_encode_seq(
        sa_arr, len(sa_text), ctypes.byref(seq_opts),
        None, 0, None, 0,
        ctypes.byref(out_count_query), ctypes.byref(out_parity_query)
    )
    assert rc_query == 0, f"Dry-run query failed: {rc_query}"
    assert out_count_query.value == 3
    expected_parity = segno.encoder.calc_structured_append_parity(sa_text.decode("latin1"))
    assert out_parity_query.value == expected_parity, f"Parity mismatch: {out_parity_query.value} vs {expected_parity}"

    # 2. Buffer too small failure semantics: atomic all-or-nothing
    seq_buf_needed = 3 * expected_max_buf
    seq_buf = (ctypes.c_uint8 * seq_buf_needed)()
    small_matrices = (ZqrMatrix * 2)() # capacity 2 < 3
    rc_small = fn_encode_seq(
        sa_arr, len(sa_text), ctypes.byref(seq_opts),
        seq_buf, seq_buf_needed, small_matrices, 2,
        ctypes.byref(out_count_query), None
    )
    assert rc_small == -6, f"Expected ZQR_ERR_BUFFER_TOO_SMALL (-6), got {rc_small}"
    assert out_count_query.value == 3

    # 3. Test A: Deterministic module-for-module comparison against segno canonical reference
    seq_matrices = (ZqrMatrix * 3)()
    rc_full = fn_encode_seq(
        sa_arr, len(sa_text), ctypes.byref(seq_opts),
        seq_buf, seq_buf_needed, seq_matrices, 3,
        ctypes.byref(out_count_query), ctypes.byref(out_parity_query)
    )
    assert rc_full == 0, f"Full sequence encode failed: {rc_full}"
    assert out_count_query.value == 3

    segno_seq = segno.make_sequence(sa_text.decode("latin1"), symbol_count=3, error="l", mask=0, boost_error=False)
    assert len(segno_seq) == 3

    for s_idx in range(3):
        s_segno = segno_seq[s_idx]
        m_zig = seq_matrices[s_idx]
        assert m_zig.version == s_segno.version, f"Version mismatch at symbol {s_idx}"
        assert m_zig.size == len(s_segno.matrix), f"Size mismatch at symbol {s_idx}"
        for y in range(m_zig.size):
            for x in range(m_zig.size):
                zig_m = m_zig.modules[y * m_zig.size + x]
                segno_m = s_segno.matrix[y][x]
                assert zig_m == segno_m, f"Symbol {s_idx} module mismatch at ({x}, {y}): zig={zig_m}, segno={segno_m}"

    # 4. Test B: Dynamic parity and count verification across multiple payloads
    dynamic_payloads = [
        b"A",
        b"0123456789",
        b"Structured Append parity test with multiple symbols 1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    ]
    for dyn in dynamic_payloads:
        dyn_arr = (ctypes.c_uint8 * len(dyn)).from_buffer_copy(dyn)
        dyn_opts = ZqrSequenceOptions(
            min_version=1,
            max_version=max_v,
            ecc=0,
            mask=0,
            kanji=0,
            optimize=1,
            fnc1=0,
            fnc1_app_indicator=0,
            reserved=(ctypes.c_uint8 * 3)(),
            has_eci=0,
            eci=0,
            symbol_count=0, # auto
        )
        p_val = ctypes.c_uint8(0)
        c_val = ctypes.c_size_t(0)
        rc_dyn = fn_encode_seq(
            dyn_arr, len(dyn), ctypes.byref(dyn_opts),
            None, 0, None, 0,
            ctypes.byref(c_val), ctypes.byref(p_val)
        )
        assert rc_dyn == 0
        expected_p = segno.encoder.calc_structured_append_parity(dyn.decode("latin1"))
        assert p_val.value == expected_p, f"Dynamic parity mismatch for payload {dyn}: got {p_val.value}, expected {expected_p}"

    # 5. Extreme Structured Append test: N=16 symbols in Tier 3
    if tier_num == 3:
        ext_text = b"EXTREME-N16-TEST-" * 60  # 1020 bytes
        ext_arr = (ctypes.c_uint8 * len(ext_text)).from_buffer_copy(ext_text)
        ext_opts = ZqrSequenceOptions(
            min_version=1,
            max_version=40,
            ecc=3,  # HIGH
            mask=0,
            kanji=0,
            optimize=0,
            fnc1=0,
            fnc1_app_indicator=0,
            reserved=(ctypes.c_uint8 * 3)(),
            has_eci=0,
            eci=0,
            symbol_count=16,
        )
        ext_c = ctypes.c_size_t(0)
        ext_p = ctypes.c_uint8(0)
        rc_ext = fn_encode_seq(
            ext_arr, len(ext_text), ctypes.byref(ext_opts),
            None, 0, None, 0,
            ctypes.byref(ext_c), ctypes.byref(ext_p),
        )
        assert rc_ext == 0, f"N=16 dry-run failed with code {rc_ext}"
        assert ext_c.value == 16, f"Expected count 16, got {ext_c.value}"
        expected_ext_p = segno.encoder.calc_structured_append_parity(ext_text.decode("latin1"))
        assert ext_p.value == expected_ext_p, f"Parity mismatch for N=16: {ext_p.value} vs {expected_ext_p}"

    # --- SVG and PNG Rendering Verification (Increment 17) ---
    fn_render_svg = getattr(lib, f"{prefix}_render_svg")
    fn_render_svg.argtypes = [
        ctypes.POINTER(ZqrMatrix),
        ctypes.POINTER(ZqrRenderOptions),
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    fn_render_svg.restype = ctypes.c_int

    fn_render_png = getattr(lib, f"{prefix}_render_png")
    fn_render_png.argtypes = [
        ctypes.POINTER(ZqrMatrix),
        ctypes.POINTER(ZqrRenderOptions),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    fn_render_png.restype = ctypes.c_int

    ropts = ZqrRenderOptions(
        quiet_zone=4,
        scale=8,
        reserved=(ctypes.c_uint8 * 2)(),
        foreground=0x000000FF,
        background=0xFFFFFFFF,
    )

    # 1. SVG Rendering Tests
    # 1.1 Dry-run
    svg_len = ctypes.c_size_t(0)
    rc_svg_dry = fn_render_svg(ctypes.byref(out), ctypes.byref(ropts), None, 0, ctypes.byref(svg_len))
    assert rc_svg_dry == 0, f"SVG dry run failed: {rc_svg_dry}"
    assert svg_len.value > 100

    # 1.2 Buffer too small
    small_svg = (ctypes.c_char * 16)()
    written_len = ctypes.c_size_t(0)
    rc_svg_small = fn_render_svg(ctypes.byref(out), ctypes.byref(ropts), small_svg, 16, ctypes.byref(written_len))
    assert rc_svg_small == -6, f"Expected -6 for SVG small buffer, got {rc_svg_small}"

    # 1.3 Full SVG generation
    svg_buf = (ctypes.c_char * svg_len.value)()
    rc_svg_full = fn_render_svg(ctypes.byref(out), ctypes.byref(ropts), svg_buf, svg_len.value, ctypes.byref(written_len))
    assert rc_svg_full == 0, f"Full SVG render failed: {rc_svg_full}"
    assert written_len.value == svg_len.value
    svg_text = svg_buf.raw.decode("utf-8")
    assert svg_text.startswith("<svg")
    assert "</svg>" in svg_text
    expected_dim = (out.size + 2 * ropts.quiet_zone) * ropts.scale
    assert f'viewBox="0 0 {expected_dim} {expected_dim}"' in svg_text

    # 2. PNG Rendering Tests
    # 2.1 Dry-run
    png_bound = ctypes.c_size_t(0)
    rc_png_dry = fn_render_png(ctypes.byref(out), ctypes.byref(ropts), None, 0, ctypes.byref(png_bound))
    assert rc_png_dry == 0, f"PNG dry run failed: {rc_png_dry}"
    assert png_bound.value > 500

    # 2.2 Buffer too small
    small_png = (ctypes.c_uint8 * 16)()
    rc_png_small = fn_render_png(ctypes.byref(out), ctypes.byref(ropts), small_png, 16, ctypes.byref(written_len))
    assert rc_png_small == -6, f"Expected -6 for PNG small buffer, got {rc_png_small}"

    # 2.3 Full PNG generation
    png_buf = (ctypes.c_uint8 * png_bound.value)()
    rc_png_full = fn_render_png(ctypes.byref(out), ctypes.byref(ropts), png_buf, png_bound.value, ctypes.byref(written_len))
    assert rc_png_full == 0, f"Full PNG render failed: {rc_png_full}"
    assert written_len.value > 64

    # 2.4 Verify PNG structure and PIL decode (v1: 21x21 modules, QZ 4, scale 8 = 232x232 px)
    assert expected_dim == 232, f"Expected Version 1 dim 232, got {expected_dim}"
    png_bytes = bytes(png_buf)[:written_len.value]
    assert png_bytes.startswith(b"\x89PNG\r\n\x1a\n"), "PNG header signature mismatch"

    img = Image.open(io.BytesIO(png_bytes))
    assert img.format == "PNG", f"Expected PNG format, got {img.format}"
    assert img.size == (232, 232), f"Expected Version 1 image size 232x232, got {img.size}"

    # 2.5 Large QR Code (v40) PNG & SVG tests for Tier 3 (~1480x1480 px, 185x185 modules with QZ 4)
    if tier_num == 3:
        v40_text = b"V40-LARGE-QR-CODE-PNG-TEST-" * 40
        v40_arr = (ctypes.c_uint8 * len(v40_text)).from_buffer_copy(v40_text)
        v40_opts = ZqrOptions(
            min_version=40,
            max_version=40,
            ecc=0,
            mask=0,
            kanji=0,
            optimize=0,
            fnc1=0,
            fnc1_app_indicator=0,
            reserved=(ctypes.c_uint8 * 3)(),
            has_eci=0,
            eci=0,
        )
        v40_out = ZqrMatrix()
        rc_v40 = fn_encode_advanced(v40_arr, len(v40_text), ctypes.byref(v40_opts), buf, expected_max_buf, ctypes.byref(v40_out))
        assert rc_v40 == 0
        assert v40_out.version == 40
        assert v40_out.size == 177

        v40_expected_dim = (177 + 2 * ropts.quiet_zone) * ropts.scale  # (177 + 8) * 8 = 185 * 8 = 1480 px
        assert v40_expected_dim == 1480

        # v40 SVG Test
        v40_svg_len = ctypes.c_size_t(0)
        rc_v40_svg_dry = fn_render_svg(ctypes.byref(v40_out), ctypes.byref(ropts), None, 0, ctypes.byref(v40_svg_len))
        assert rc_v40_svg_dry == 0
        assert v40_svg_len.value > 1000

        v40_svg_buf = (ctypes.c_char * v40_svg_len.value)()
        v40_svg_written = ctypes.c_size_t(0)
        rc_v40_svg = fn_render_svg(ctypes.byref(v40_out), ctypes.byref(ropts), v40_svg_buf, v40_svg_len.value, ctypes.byref(v40_svg_written))
        assert rc_v40_svg == 0
        assert v40_svg_written.value == v40_svg_len.value
        v40_svg_text = v40_svg_buf.raw.decode("utf-8")
        assert f'viewBox="0 0 {v40_expected_dim} {v40_expected_dim}"' in v40_svg_text
        assert v40_svg_text.endswith("</svg>\n")

        # v40 PNG Test
        v40_bound = ctypes.c_size_t(0)
        rc_v40_dry = fn_render_png(ctypes.byref(v40_out), ctypes.byref(ropts), None, 0, ctypes.byref(v40_bound))
        assert rc_v40_dry == 0

        v40_png_buf = (ctypes.c_uint8 * v40_bound.value)()
        v40_written = ctypes.c_size_t(0)
        rc_v40_png = fn_render_png(ctypes.byref(v40_out), ctypes.byref(ropts), v40_png_buf, v40_bound.value, ctypes.byref(v40_written))
        assert rc_v40_png == 0

        v40_bytes = bytes(v40_png_buf)[:v40_written.value]
        v40_img = Image.open(io.BytesIO(v40_bytes))
        assert v40_img.size == (v40_expected_dim, v40_expected_dim), f"v40 PNG size mismatch: {v40_img.size} vs {v40_expected_dim}x{v40_expected_dim}"

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
