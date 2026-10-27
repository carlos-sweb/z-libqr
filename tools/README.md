# Development and Verification Tools

This directory contains scripts used during development, verification, and code generation for `z-libqr`:

- `extract_kanji_table.py`: Generates `src/kanji_table.zig` by extracting the packed JIS X 0208 Shift-JIS to 13-bit QR Kanji table from Project Nayuki's `QrSegmentAdvanced.java`.
  - **Prerequisite:** Requires a clone of `nayuki/QR-Code-generator` (MIT) at `../QR-Code-generator`, or provide `--source <path/to/QrSegmentAdvanced.java>`.
  - **Usage:**
    ```bash
    python3 tools/extract_kanji_table.py
    ```
- `nayuki_qrcodegen.py`: Project Nayuki's reference Python implementation (MIT license), used by test suites as an authoritative oracle.
- `gen_vectors.py`: Script to generate comprehensive test vector fixtures across all 40 QR versions and ECL modes against the Python reference.
