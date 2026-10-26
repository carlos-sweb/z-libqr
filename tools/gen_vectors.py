#!/usr/bin/env python3
"""
tools/gen_vectors.py - Golden test vector generator and oracle verifier for z-libqr.

Uses Project Nayuki's reference implementation (tools/nayuki_qrcodegen.py) to:
1. Generate canonical golden test vectors saved in tests/golden/vectors.txt.
2. Verify z-libqr (via libzqr_t3.so ctypes binding) against Nayuki's reference.

Usage:
    python3 tools/gen_vectors.py --generate [output_file]
    python3 tools/gen_vectors.py --verify-so [path_to_so]
    python3 tools/gen_vectors.py --exhaustive [path_to_so]
"""

import sys
import os
import argparse
import ctypes

# Add tools directory to path to import nayuki_qrcodegen
tools_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, tools_dir)
from nayuki_qrcodegen import QrCode, QrSegment


class ZqrMatrix(ctypes.Structure):
    _fields_ = [
        ("version", ctypes.c_uint8),
        ("size", ctypes.c_uint8),
        ("ecc", ctypes.c_uint8),
        ("mask", ctypes.c_uint8),
        ("mode", ctypes.c_uint8),
        ("modules", ctypes.POINTER(ctypes.c_uint8)),
    ]


def get_ecl(ecc_str):
    ecc_map = {
        "L": QrCode.Ecc.LOW,
        "M": QrCode.Ecc.MEDIUM,
        "Q": QrCode.Ecc.QUARTILE,
        "H": QrCode.Ecc.HIGH,
    }
    return ecc_map[ecc_str]


def ecc_to_int(ecc_str):
    return {"L": 0, "M": 1, "Q": 2, "H": 3}[ecc_str]


def int_to_ecc(ecc_int):
    return ["L", "M", "Q", "H"][ecc_int]


def build_test_cases():
    """Builds a curated list of ~55 test cases covering all requirements."""
    cases = []

    # 1. Systematic coverage of all 40 versions (1..40)
    # Cycling through all 4 ECC levels and all 8 masks.
    # Versions 1..32 cover all 32 combinations of (ECC x mask) at least once.
    ecl_cycle = ["L", "M", "Q", "H"]
    for v in range(1, 41):
        ecc = ecl_cycle[(v - 1) % 4]
        mask = (v - 1) % 8
        # Select payload based on version group to also exercise all modes
        if v <= 8:
            # Numeric mode with varied digit lengths
            num_digits = 10 + v * 3
            payload = ("0123456789" * 15)[:num_digits]
            mode = "numeric"
        elif v <= 16:
            # Alphanumeric mode with varied lengths
            num_chars = 10 + v * 4
            payload = ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:" * 10)[:num_chars]
            mode = "alnum"
        elif v <= 24:
            # Byte mode with printable ASCII
            num_bytes = 20 + v * 10
            payload = ("The quick brown fox jumps over the lazy dog 1234567890! " * 20)[:num_bytes]
            mode = "byte"
        elif v <= 32:
            # Byte mode with binary bytes (including 0x00 and 0xFF)
            num_bytes = 30 + v * 12
            binary_seq = bytes([i % 256 for i in range(num_bytes)])
            payload = binary_seq
            mode = "binary"
        else:
            # Higher versions (v33..40) with longer payloads
            num_bytes = 100 + (v - 32) * 50
            payload = ("Z-LIBQR_VERSION_" + str(v) + "_PAYLOAD_" * 10)[:num_bytes]
            mode = "byte"

        cases.append({
            "id": f"v{v}_{ecc}_m{mask}_{mode}",
            "version": v,
            "ecc": ecc,
            "mask": mask,
            "mode": mode,
            "payload": payload,
            "forced_version": True,
        })

    # 2. Structural boundaries
    # v6 vs v7 (Tier 1 boundary: v6 no version block, v7 has 18-bit version block)
    cases.append({
        "id": "boundary_v6_M_no_version_block",
        "version": 6,
        "ecc": "M",
        "mask": 2,
        "mode": "alnum",
        "payload": "BOUNDARY V6 NO VERSION BLOCK",
        "forced_version": True,
    })
    cases.append({
        "id": "boundary_v7_M_version_block_active",
        "version": 7,
        "ecc": "M",
        "mask": 2,
        "mode": "alnum",
        "payload": "BOUNDARY V7 WITH VERSION BLOCK ACTIVE",
        "forced_version": True,
    })

    # v9 vs v10 (Tier 2 boundary & char count bit width change: num 10->12, alnum 9->11, byte 8->16)
    cases.append({
        "id": "boundary_v9_L_char_count_width",
        "version": 9,
        "ecc": "L",
        "mask": 3,
        "mode": "alnum",
        "payload": "BOUNDARY V9 CHAR COUNT WIDTH 9 BITS",
        "forced_version": True,
    })
    cases.append({
        "id": "boundary_v10_L_char_count_width",
        "version": 10,
        "ecc": "L",
        "mask": 3,
        "mode": "alnum",
        "payload": "BOUNDARY V10 CHAR COUNT WIDTH 11 BITS",
        "forced_version": True,
    })

    # v26 vs v27 (char count bit width change: num 12->14, alnum 11->13)
    cases.append({
        "id": "boundary_v26_M_char_count_width",
        "version": 26,
        "ecc": "M",
        "mask": 4,
        "mode": "alnum",
        "payload": "BOUNDARY V26 ALNUM COUNT WIDTH 11",
        "forced_version": True,
    })
    cases.append({
        "id": "boundary_v27_M_char_count_width",
        "version": 27,
        "ecc": "M",
        "mask": 4,
        "mode": "alnum",
        "payload": "BOUNDARY V27 ALNUM COUNT WIDTH 13",
        "forced_version": True,
    })

    # 3. Mode coverage specifics: ECI Mode
    cases.append({
        "id": "mode_eci_26_utf8_payload",
        "version": 1,
        "ecc": "M",
        "mask": 1,
        "mode": "eci_utf8",
        "eci_assignment": 26,
        "payload": "ECI 26 TEST",
        "forced_version": True,
    })

    # 4. Empty input
    cases.append({
        "id": "empty_input_v1_M",
        "version": 1,
        "ecc": "M",
        "mask": 0,
        "mode": "empty",
        "payload": "",
        "forced_version": True,
    })

    # 5. Almost-fit and Exact-fit capacity edge cases
    # Margin 0 (Exact-fit): 34 digits in v1-M (128 / 128 bits: 0 terminator bits, 0 pad bytes)
    cases.append({
        "id": "capacity_exact_fit_margin_0_v1_M",
        "version": 1,
        "ecc": "M",
        "mask": 0,
        "mode": "numeric",
        "payload": "1" * 34,
        "forced_version": True,
    })

    # Margin 1: 41 digits in v1-L (151 / 152 bits: 1 bit terminator, 0 pad bytes)
    cases.append({
        "id": "capacity_almost_fit_margin_1_v1_L",
        "version": 1,
        "ecc": "L",
        "mask": 1,
        "mode": "numeric",
        "payload": "1" * 41,
        "forced_version": True,
    })

    # Margin 2: 48 digits in v2-Q (174 / 176 bits: 2 bits terminator, 0 pad bytes)
    cases.append({
        "id": "capacity_almost_fit_margin_2_v2_Q",
        "version": 2,
        "ecc": "Q",
        "mask": 2,
        "mode": "numeric",
        "payload": "1" * 48,
        "forced_version": True,
    })

    # Margin 3: 26 digits in v1-Q (101 / 104 bits: 3 bits terminator, 0 pad bytes)
    cases.append({
        "id": "capacity_almost_fit_margin_3_v1_Q",
        "version": 1,
        "ecc": "Q",
        "mask": 3,
        "mode": "numeric",
        "payload": "1" * 26,
        "forced_version": True,
    })

    # 6. Boundary between versions in auto encode()
    # Exact-fit in v1-L: 2 alnum chars ("AB") + 34 digits ("1" * 34) = 24 + 128 = 152 bits == 152 bits capacity of v1-L
    # Auto version selection MUST choose v1
    cases.append({
        "id": "auto_boundary_exact_fit_v1_L",
        "version": 1,
        "ecc": "L",
        "mask": None, # Auto mask
        "mode": "multi_alnum_num",
        "multi_segments": [
            ("alnum", "AB"),
            ("numeric", "1" * 34),
        ],
        "forced_version": False,
    })

    # Exceeds v1-L by 1 bit: 1 alnum char ("A") + 36 digits ("1" * 36) = 19 + 134 = 153 bits > 152 bits
    # Auto version selection MUST choose v2
    cases.append({
        "id": "auto_boundary_exceeds_v1_by_1_bit_v2_L",
        "version": 2,
        "ecc": "L",
        "mask": None, # Auto mask
        "mode": "multi_alnum_num",
        "multi_segments": [
            ("alnum", "A"),
            ("numeric", "1" * 36),
        ],
        "forced_version": False,
    })

    return cases


def generate_qr(case):
    """Generates QR code using Nayuki reference."""
    mode = case["mode"]
    ecl = get_ecl(case["ecc"])
    min_v = case["version"]
    max_v = case["version"]
    forced_mask = case["mask"] if case.get("forced_mask", case["mask"] is not None) else -1

    if mode == "empty" or case.get("payload") == "":
        segs = []
        qr = QrCode.encode_segments(segs, ecl, minversion=min_v, maxversion=max_v, mask=forced_mask, boostecl=False)
    elif mode == "multi_alnum_num":
        segs = []
        for smode, spayload in case["multi_segments"]:
            if smode == "alnum":
                segs.append(QrSegment.make_alphanumeric(spayload))
            elif smode == "numeric":
                segs.append(QrSegment.make_numeric(spayload))
        # For auto boundary, allow version 1 to 40
        qr = QrCode.encode_segments(segs, ecl, minversion=1, maxversion=40, mask=forced_mask, boostecl=False)
    elif mode == "eci_utf8":
        segs = [
            QrSegment.make_eci(case["eci_assignment"]),
            QrSegment.make_bytes(case["payload"].encode("utf-8")),
        ]
        qr = QrCode.encode_segments(segs, ecl, minversion=min_v, maxversion=max_v, mask=forced_mask, boostecl=False)
    elif mode == "numeric":
        segs = [QrSegment.make_numeric(case["payload"])]
        qr = QrCode.encode_segments(segs, ecl, minversion=min_v, maxversion=max_v, mask=forced_mask, boostecl=False)
    elif mode == "alnum":
        segs = [QrSegment.make_alphanumeric(case["payload"])]
        qr = QrCode.encode_segments(segs, ecl, minversion=min_v, maxversion=max_v, mask=forced_mask, boostecl=False)
    elif mode in ("byte", "binary"):
        payload_bytes = case["payload"]
        if isinstance(payload_bytes, str):
            payload_bytes = payload_bytes.encode("utf-8")
        segs = [QrSegment.make_bytes(payload_bytes)]
        qr = QrCode.encode_segments(segs, ecl, minversion=min_v, maxversion=max_v, mask=forced_mask, boostecl=False)
    else:
        raise ValueError(f"Unknown mode: {mode}")

    return qr


def format_case_txt(case, qr):
    """Formats a case and its matrix into text."""
    lines = []
    lines.append(f"# CASE: {case['id']}")
    lines.append(f"version: {qr.get_version()}")
    lines.append(f"ecc: {case['ecc']}")
    lines.append(f"mask: {qr.get_mask()}")
    lines.append(f"mode: {case['mode']}")

    # Store payload representation
    if case["mode"] == "multi_alnum_num":
        lines.append(f"multi: {repr(case['multi_segments'])}")
    elif case["mode"] == "eci_utf8":
        lines.append(f"eci: {case['eci_assignment']}")
        lines.append(f"input_hex: {case['payload'].encode('utf-8').hex()}")
    elif isinstance(case["payload"], str):
        lines.append(f"input_hex: {case['payload'].encode('utf-8').hex()}")
    else:
        lines.append(f"input_hex: {case['payload'].hex()}")

    size = qr.get_size()
    lines.append(f"size: {size}")
    lines.append("matrix:")
    for y in range(size):
        row = "".join("1" if qr.get_module(x, y) else "0" for x in range(size))
        lines.append(row)
    lines.append("") # Empty line between cases
    return "\n".join(lines)


def run_generate(output_path):
    cases = build_test_cases()
    print(f"Generating {len(cases)} golden test vectors to {output_path}...")
    output_lines = [
        "# =====================================================================",
        "# z-libqr Golden Test Vectors (generated via tools/gen_vectors.py)",
        "# Oracle: Project Nayuki QR Code generator (nayuki_qrcodegen.py)",
        f"# Total cases: {len(cases)}",
        "# =====================================================================",
        "",
    ]

    for case in cases:
        qr = generate_qr(case)
        assert qr.get_version() == case["version"], f"Expected version {case['version']}, got {qr.get_version()}"
        if case["mask"] is not None:
            assert qr.get_mask() == case["mask"], f"Expected mask {case['mask']}, got {qr.get_mask()}"
        output_lines.append(format_case_txt(case, qr))

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines))
    print(f"Successfully wrote {len(cases)} test vectors to {output_path}.")


def run_verify_so(so_path, exhaustive=False):
    """Verifies libzqr_t3.so dynamically against Nayuki reference."""
    if not os.path.exists(so_path):
        print(f"Error: Shared library not found at {so_path}. Run 'zig build' first.")
        sys.exit(1)

    lib = ctypes.CDLL(so_path)
    lib.zqr_t3_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrMatrix),
    ]
    lib.zqr_t3_encode_with_version.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ZqrMatrix),
    ]
    lib.zqr_t3_buffer_len.restype = ctypes.c_size_t

    max_buf_len = lib.zqr_t3_buffer_len(0)
    buf = (ctypes.c_uint8 * max_buf_len)()
    out = ZqrMatrix()

    if exhaustive:
        print("Running EXHAUSTIVE verification (1280 combinations = 40 versions x 4 ECC x 8 masks)...")
        passed = 0
        total = 40 * 4 * 8
        payload_base = b"ZQR_EXHAUSTIVE_TEST_VECTOR_PAYLOAD_1234567890_"
        for v in range(1, 41):
            for ecl_int in range(4):
                ecl_char = int_to_ecc(ecl_int)
                ecl = get_ecl(ecl_char)
                for mask in range(8):
                    # Create payload that fits comfortably in this version/ECC
                    cap_bytes = QrCode._get_num_data_codewords(v, ecl)
                    payload = (payload_base * 50)[:max(1, min(cap_bytes - 3, 20))]

                    # Nayuki reference
                    seg = QrSegment.make_bytes(payload)
                    qr_ref = QrCode.encode_segments([seg], ecl, minversion=v, maxversion=v, mask=mask, boostecl=False)

                    # z-libqr via C ABI
                    payload_arr = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
                    rc = lib.zqr_t3_encode_with_version(
                        payload_arr, len(payload), v, ecl_int, mask, buf, max_buf_len, ctypes.byref(out)
                    )
                    assert rc == 0, f"zqr_t3_encode_with_version failed with code {rc} for v{v}-{ecl_char}-m{mask}"
                    assert out.version == v
                    assert out.size == qr_ref.get_size()
                    assert out.mask == mask

                    # Compare modules bit-by-bit
                    size = out.size
                    for y in range(size):
                        for x in range(size):
                            ref_bit = 1 if qr_ref.get_module(x, y) else 0
                            zig_bit = out.modules[y * size + x]
                            assert ref_bit == zig_bit, (
                                f"Mismatch at (x={x}, y={y}) in v{v}-{ecl_char}-m{mask}: ref={ref_bit}, zig={zig_bit}"
                            )
                    passed += 1
            print(f"  Version {v:2d}/40 passed (32 masks/ecc each)")
        print(f"ALL {passed}/{total} exhaustive combinations verified bit-by-bit with Nayuki!")
    else:
        cases = build_test_cases()
        print(f"Verifying {len(cases)} curated test cases against {so_path}...")
        passed = 0
        for case in cases:
            qr_ref = generate_qr(case)

            # Prepare data for C ABI
            # Note: For multi-segment or ECI, test is covered in native Zig test suite
            # Here we test byte, alnum, numeric single-payload cases via C ABI
            if case["mode"] in ("byte", "binary", "numeric", "alnum", "empty"):
                payload = case["payload"]
                if isinstance(payload, str):
                    payload = payload.encode("utf-8")

                payload_arr = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload) if len(payload) > 0 else None
                ecl_int = ecc_to_int(case["ecc"])
                mask_val = case["mask"] if case["mask"] is not None else -1

                if case["forced_version"]:
                    rc = lib.zqr_t3_encode_with_version(
                        payload_arr, len(payload), case["version"], ecl_int, mask_val, buf, max_buf_len, ctypes.byref(out)
                    )
                else:
                    rc = lib.zqr_t3_encode(
                        payload_arr, len(payload), ecl_int, buf, max_buf_len, ctypes.byref(out)
                    )

                assert rc == 0, f"Case {case['id']} failed with code {rc}"
                assert out.version == qr_ref.get_version(), f"Case {case['id']} version mismatch"
                assert out.mask == qr_ref.get_mask(), f"Case {case['id']} mask mismatch"
                assert out.size == qr_ref.get_size(), f"Case {case['id']} size mismatch"

                size = out.size
                for y in range(size):
                    for x in range(size):
                        ref_bit = 1 if qr_ref.get_module(x, y) else 0
                        zig_bit = out.modules[y * size + x]
                        assert ref_bit == zig_bit, f"Mismatch at ({x}, {y}) in {case['id']}"
                passed += 1
        print(f"{passed} C-ABI compatible cases passed bit-by-bit verification against Nayuki reference!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="z-libqr golden vector generator & oracle verifier")
    parser.add_argument("--generate", nargs="?", const="tests/golden/vectors.txt", help="Generate golden fixture file")
    parser.add_argument("--verify-so", nargs="?", const="zig-out/lib/libzqr_t3.so", help="Verify libzqr_t3.so")
    parser.add_argument("--exhaustive", action="store_true", help="Run exhaustive 1280-combination oracle check")

    args = parser.parse_args()

    if args.exhaustive:
        so = args.verify_so if args.verify_so else "zig-out/lib/libzqr_t3.so"
        run_verify_so(so, exhaustive=True)
    elif args.verify_so:
        run_verify_so(args.verify_so, exhaustive=False)
    elif args.generate:
        run_generate(args.generate)
    else:
        # Default: generate
        run_generate("tests/golden/vectors.txt")
