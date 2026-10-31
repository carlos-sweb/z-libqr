#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "zqr.h"

int main(void) {
    printf("=== Running z-libqr C ABI Integration Test ===\n");

    // 1. Verify Header Definitions
    assert(ZQR_VERSION_MAJOR == 1);
    assert(ZQR_VERSION_MINOR == 6);
    assert(ZQR_VERSION_PATCH == 4);
    assert(ZQR_OK == 0);
    assert(ZQR_ERR_DATA_TOO_LONG == -1);
    assert(ZQR_ERR_VERSION_EXCEEDS_TIER == -2);
    assert(ZQR_ERR_INVALID_VERSION == -3);
    assert(ZQR_ERR_INVALID_ECC == -4);
    assert(ZQR_ERR_INVALID_MASK == -5);
    assert(ZQR_ERR_BUFFER_TOO_SMALL == -6);
    assert(ZQR_ERR_NULL_POINTER == -7);
    assert(ZQR_ERR_INVALID_SEGMENT_ORDER == -8);
    assert(ZQR_ERR_UNSUPPORTED == -9);

    // 2. Multi-tier Simultaneous Linkage and Symbol Isolation
    // Calling functions from libzqr_t1.a, libzqr_t2.a, and libzqr_t3.a linked in the same binary.
    assert(zqr_t1_max_version() == 6);
    assert(zqr_t2_max_version() == 10);
    assert(zqr_t3_max_version() == 40);

    assert(zqr_t1_buffer_len(0) == 41 * 41);
    assert(zqr_t2_buffer_len(0) == 57 * 57);
    assert(zqr_t3_buffer_len(0) == 177 * 177);

    assert(zqr_t1_buffer_len(1) == 21 * 21);
    assert(zqr_t1_buffer_len(6) == 41 * 41);
    assert(zqr_t1_buffer_len(7) == 0); // Out of tier for t1

    assert(strcmp(zqr_t1_strerror(ZQR_OK), "ok") == 0);
    assert(strcmp(zqr_t1_strerror(ZQR_ERR_VERSION_EXCEEDS_TIER), "version exceeds the maximum supported by this library tier") == 0);
    assert(strcmp(zqr_t3_strerror(ZQR_ERR_DATA_TOO_LONG), "data too long for the requested version and error correction level") == 0);

    // 3. Tier 1 Encoding and Validation
    uint8_t buf_t1[41 * 41];
    zqr_matrix m1;
    const char *hello = "HELLO WORLD";
    int rc = zqr_t1_encode((const uint8_t *)hello, strlen(hello), ZQR_ECC_MEDIUM, buf_t1, sizeof(buf_t1), &m1);
    assert(rc == ZQR_OK);
    assert(m1.version == 1);
    assert(m1.size == 21);
    assert(m1.ecc == ZQR_ECC_MEDIUM);
    assert(m1.mask == 0);
    assert(m1.modules != NULL);
    assert(m1.modules[0] == 1); // Top-left finder pattern corner

    // 4. Tier Boundary Testing across T1, T2, T3
    // 300 digits requires Version 7 (Medium capacity in v6 is 112 bytes ~268 digits).
    // - T1 (max v6) must reject with ZQR_ERR_VERSION_EXCEEDS_TIER (-2)
    // - T2 (max v10) must accept (Version 7 <= 10)
    // - T3 (max v40) must accept (Version 7 <= 40)
    char digits_300[301];
    for (int i = 0; i < 300; i++) digits_300[i] = '0' + (i % 10);
    digits_300[300] = '\0';

    // Tier 1 test
    rc = zqr_t1_encode((const uint8_t *)digits_300, 300, ZQR_ECC_MEDIUM, buf_t1, sizeof(buf_t1), &m1);
    assert(rc == ZQR_ERR_VERSION_EXCEEDS_TIER);

    // Tier 2 test
    uint8_t buf_t2[57 * 57];
    zqr_matrix m2;
    rc = zqr_t2_encode((const uint8_t *)digits_300, 300, ZQR_ECC_MEDIUM, buf_t2, sizeof(buf_t2), &m2);
    assert(rc == ZQR_OK);
    assert(m2.version == 8);
    assert(m2.size == 49);

    // Tier 3 test
    uint8_t buf_t3[177 * 177];
    zqr_matrix m3;
    rc = zqr_t3_encode((const uint8_t *)digits_300, 300, ZQR_ECC_MEDIUM, buf_t3, sizeof(buf_t3), &m3);
    assert(rc == ZQR_OK);
    assert(m3.version == 8);
    assert(m3.size == 49);

    // 5. Tier 3 encode_with_version (forced version and mask)
    rc = zqr_t3_encode_with_version((const uint8_t *)"HELLO", 5, 5, ZQR_ECC_MEDIUM, 6, buf_t3, sizeof(buf_t3), &m3);
    assert(rc == ZQR_OK);
    assert(m3.version == 5);
    assert(m3.size == 37);
    assert(m3.mask == 6);

    // 6. Argument and error handling via C ABI
    assert(zqr_t1_encode(NULL, 5, ZQR_ECC_MEDIUM, buf_t1, sizeof(buf_t1), &m1) == ZQR_ERR_NULL_POINTER);
    assert(zqr_t1_encode((const uint8_t *)"HELLO", 5, ZQR_ECC_MEDIUM, NULL, sizeof(buf_t1), &m1) == ZQR_ERR_NULL_POINTER);
    assert(zqr_t1_encode((const uint8_t *)"HELLO", 5, ZQR_ECC_MEDIUM, buf_t1, sizeof(buf_t1), NULL) == ZQR_ERR_NULL_POINTER);
    assert(zqr_t1_encode((const uint8_t *)"HELLO", 5, 99, buf_t1, sizeof(buf_t1), &m1) == ZQR_ERR_INVALID_ECC);
    assert(zqr_t1_encode((const uint8_t *)"HELLO", 5, ZQR_ECC_MEDIUM, buf_t1, 10, &m1) == ZQR_ERR_BUFFER_TOO_SMALL);

    // 7. Advanced encoding with multi-mode DP mixing
    zqr_options opts = {
        .min_version = 1,
        .max_version = 6,
        .ecc = ZQR_ECC_LOW,
        .mask = -1,
        .kanji = 1,
        .optimize = 1,
    };
    const char *mixed = "ABC123日本語";
    rc = zqr_t1_encode_advanced((const uint8_t *)mixed, strlen(mixed), &opts, buf_t1, sizeof(buf_t1), &m1);
    assert(rc == ZQR_OK);
    assert(m1.version >= 1 && m1.version <= 6);
    assert(m1.size > 0);

    // 8. FNC1 first position (GS1 QR Code)
    zqr_options gs1_opts = {
        .min_version = 1,
        .max_version = 6,
        .ecc = ZQR_ECC_LOW,
        .mask = -1,
        .kanji = 0,
        .optimize = 1,
        .fnc1 = ZQR_FNC1_FIRST,
    };
    const char *gs1_data = "0101234567890128\x1D" "10BATCH1";
    rc = zqr_t1_encode_advanced((const uint8_t *)gs1_data, strlen(gs1_data), &gs1_opts, buf_t1, sizeof(buf_t1), &m1);
    assert(rc == ZQR_OK);
    assert(m1.version >= 1 && m1.version <= 6);

    // 9. FNC1 second position (AIM Application Indicator)
    zqr_options fnc1_2_opts = {
        .min_version = 1,
        .max_version = 6,
        .ecc = ZQR_ECC_LOW,
        .mask = -1,
        .kanji = 0,
        .optimize = 1,
        .fnc1 = ZQR_FNC1_SECOND,
        .fnc1_app_indicator = 'A' + 100, // 165 per ISO/IEC 18004
    };
    const char *app_data = "SERIAL12345";
    rc = zqr_t1_encode_advanced((const uint8_t *)app_data, strlen(app_data), &fnc1_2_opts, buf_t1, sizeof(buf_t1), &m1);
    assert(rc == ZQR_OK);
    assert(m1.version >= 1 && m1.version <= 6);

    // 10. Structured Append Sequence via C ABI (Increment 15)
    zqr_sequence_options seq_opts = {
        .min_version = 1,
        .max_version = 6,
        .ecc = ZQR_ECC_LOW,
        .mask = -1,
        .kanji = 0,
        .optimize = 1,
        .fnc1 = ZQR_FNC1_NONE,
        .symbol_count = 3,
    };
    const char *seq_data = "HELLO WORLD SEQUENCE SPLIT TEST ACROSS MULTIPLE QR CODES 12345";
    size_t out_count = 0;
    uint8_t out_parity = 0;

    // Dry-run call with NULL buf and NULL out to query count and parity
    rc = zqr_t1_encode_sequence((const uint8_t *)seq_data, strlen(seq_data), &seq_opts, NULL, 0, NULL, 0, &out_count, &out_parity);
    assert(rc == ZQR_OK);
    assert(out_count == 3);
    assert(out_parity != 0);

    // Buffer too small check on out_capacity
    zqr_matrix seq_matrices[3];
    uint8_t seq_storage[3 * 41 * 41];
    rc = zqr_t1_encode_sequence((const uint8_t *)seq_data, strlen(seq_data), &seq_opts, seq_storage, sizeof(seq_storage), seq_matrices, 2, &out_count, &out_parity);
    assert(rc == ZQR_ERR_BUFFER_TOO_SMALL);

    // Full successful sequence encoding
    rc = zqr_t1_encode_sequence((const uint8_t *)seq_data, strlen(seq_data), &seq_opts, seq_storage, sizeof(seq_storage), seq_matrices, 3, &out_count, &out_parity);
    assert(rc == ZQR_OK);
    assert(out_count == 3);
    for (size_t i = 0; i < 3; i++) {
        assert(seq_matrices[i].version >= 1 && seq_matrices[i].version <= 6);
        assert(seq_matrices[i].size > 0);
        assert(seq_matrices[i].modules != NULL);
    }

    // 6. SVG Rendering Validation
    zqr_render_options ropts = {
        .quiet_zone = 4,
        .scale = 8,
        .foreground = 0x000000FF,
        .background = 0xFFFFFFFF,
    };
    size_t svg_len = 0;
    rc = zqr_t1_render_svg(&m1, &ropts, NULL, 0, &svg_len);
    assert(rc == ZQR_OK);
    assert(svg_len > 100);

    char small_svg_buf[32];
    size_t written_len = 0;
    rc = zqr_t1_render_svg(&m1, &ropts, small_svg_buf, sizeof(small_svg_buf), &written_len);
    assert(rc == ZQR_ERR_BUFFER_TOO_SMALL);

    char *svg_buf = (char *)malloc(svg_len);
    assert(svg_buf != NULL);
    rc = zqr_t1_render_svg(&m1, &ropts, svg_buf, svg_len, &written_len);
    assert(rc == ZQR_OK);
    assert(written_len == svg_len);
    assert(strncmp(svg_buf, "<svg", 4) == 0);
    assert(strstr(svg_buf, "</svg>") != NULL);
    free(svg_buf);

    // 7. PNG Rendering Validation
    size_t png_bound = 0;
    rc = zqr_t1_render_png(&m1, &ropts, NULL, 0, &png_bound);
    assert(rc == ZQR_OK);
    assert(png_bound > 500);

    uint8_t small_png_buf[16];
    rc = zqr_t1_render_png(&m1, &ropts, small_png_buf, sizeof(small_png_buf), &written_len);
    assert(rc == ZQR_ERR_BUFFER_TOO_SMALL);

    uint8_t *png_buf = (uint8_t *)malloc(png_bound);
    assert(png_buf != NULL);
    rc = zqr_t1_render_png(&m1, &ropts, png_buf, png_bound, &written_len);
    assert(rc == ZQR_OK);
    assert(written_len > 64);
    // Verify 8-byte PNG signature: 0x89 'P' 'N' 'G' '\r' '\n' 0x1A '\n'
    const uint8_t expected_sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
    assert(memcmp(png_buf, expected_sig, 8) == 0);
    free(png_buf);

    // 7.1 Extended Rendering Options Validation (_ex vs non-_ex)
    zqr_render_options ex_opts = {
        .quiet_zone = 4,
        .scale = 8,
        .dot_shape = ZQR_SHAPE_ROUNDED,
        .eye_shape = ZQR_SHAPE_ROUNDED,
        .foreground = 0x123456FF,
        .background = 0xFEDCBAFF,
    };
    size_t ex_svg_len = 0;
    rc = zqr_t1_render_svg_ex(&m1, &ex_opts, NULL, 0, &ex_svg_len);
    assert(rc == ZQR_OK);
    char *ex_svg_buf = (char *)malloc(ex_svg_len);
    assert(ex_svg_buf != NULL);
    rc = zqr_t1_render_svg_ex(&m1, &ex_opts, ex_svg_buf, ex_svg_len, &written_len);
    assert(rc == ZQR_OK);
    assert(strstr(ex_svg_buf, "<circle") != NULL); // Eye shape rounded uses <circle
    assert(strstr(ex_svg_buf, "<filter") == NULL); // Pure vector: zero filters!
    assert(strstr(ex_svg_buf, "stroke-width") == NULL); // Zero strokes!
    assert(strstr(ex_svg_buf, "stroke-linejoin") == NULL);
    assert(strstr(ex_svg_buf, " C") != NULL); // Cubic Bézier fillets on corners
    assert(strstr(ex_svg_buf, "#123456") != NULL); // Custom foreground
    assert(strstr(ex_svg_buf, "#FEDCBA") != NULL); // Custom background
    free(ex_svg_buf);

    // Legacy non-_ex must ignore dot_shape/eye_shape and NOT emit <circle
    size_t legacy_svg_len = 0;
    rc = zqr_t1_render_svg(&m1, &ex_opts, NULL, 0, &legacy_svg_len);
    assert(rc == ZQR_OK);
    char *legacy_svg_buf = (char *)malloc(legacy_svg_len);
    assert(legacy_svg_buf != NULL);
    rc = zqr_t1_render_svg(&m1, &ex_opts, legacy_svg_buf, legacy_svg_len, &written_len);
    assert(rc == ZQR_OK);
    assert(strstr(legacy_svg_buf, "<circle") == NULL);
    free(legacy_svg_buf);

    // Extended PNG rendering
    size_t ex_png_bound = 0;
    rc = zqr_t1_render_png_ex(&m1, &ex_opts, NULL, 0, &ex_png_bound);
    assert(rc == ZQR_OK);
    uint8_t *ex_png_buf = (uint8_t *)malloc(ex_png_bound);
    assert(ex_png_buf != NULL);
    rc = zqr_t1_render_png_ex(&m1, &ex_opts, ex_png_buf, ex_png_bound, &written_len);
    assert(rc == ZQR_OK);
    assert(memcmp(ex_png_buf, expected_sig, 8) == 0);
    free(ex_png_buf);

    // 8. Decoder C ABI Integration and Multi-tier Decoding
    assert(sizeof(zqr_decode_result) == 28);
    assert(ZQR_DECODE_OK == 0);
    assert(ZQR_ERR_DECODE_INVALID_SIZE == -20);
    assert(ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER == -21);
    assert(ZQR_ERR_DECODE_FORMAT_UNCORRECTABLE == -22);
    assert(ZQR_ERR_DECODE_VERSION_UNCORRECTABLE == -23);
    assert(ZQR_ERR_DECODE_RS_UNCORRECTABLE == -24);
    assert(ZQR_ERR_DECODE_INVALID_MODE == -25);
    assert(ZQR_ERR_DECODE_INVALID_PAYLOAD == -26);
    assert(ZQR_ERR_DECODE_UNEXPECTED_EOF == -27);
    assert(ZQR_ERR_DECODE_BUFFER_TOO_SMALL == -28);
    assert(ZQR_ERR_DECODE_NULL_POINTER == -29);
    assert(ZQR_ERR_DECODE_IMAGE_TOO_LARGE == -30);
    assert(ZQR_ERR_DECODE_NO_FINDERS == -31);
    assert(ZQR_ERR_DECODE_INVALID_IMAGE == -32);

    assert(strcmp(zqr_t1_decode_strerror(ZQR_DECODE_OK), "ok") == 0);
    assert(strcmp(zqr_t1_decode_strerror(ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER), "matrix version exceeds maximum supported by this library tier") == 0);
    assert(strcmp(zqr_t3_decode_strerror(ZQR_ERR_DECODE_RS_UNCORRECTABLE), "reed-solomon error correction failed (too many damaged codewords)") == 0);
    assert(strcmp(zqr_t1_decode_strerror(ZQR_ERR_DECODE_IMAGE_TOO_LARGE), "image dimensions exceed maximum supported pixel count (16.8 MP)") == 0);
    assert(strcmp(zqr_t1_decode_image_strerror(ZQR_ERR_DECODE_NO_FINDERS), "no valid QR finder pattern triad detected in image") == 0);
    assert(strcmp(zqr_t1_decode_image_strerror(ZQR_ERR_DECODE_INVALID_IMAGE), "degenerate geometry or invalid transformation while sampling image") == 0);

    assert(zqr_t1_decode_buffer_len(1, ZQR_ECC_LOW) == 19 * 3);
    assert(zqr_t1_decode_buffer_len(7, ZQR_ECC_LOW) == 0); // Out of tier for t1
    assert(zqr_t2_decode_buffer_len(10, ZQR_ECC_HIGH) == 122 * 3);
    assert(zqr_t3_decode_buffer_len(40, ZQR_ECC_LOW) == 2956 * 3);

    // End-to-end decode of fresh "HELLO WORLD" symbol
    uint8_t hello_buf[21 * 21];
    zqr_matrix hello_m;
    rc = zqr_t1_encode((const uint8_t *)"HELLO WORLD", 11, ZQR_ECC_MEDIUM, hello_buf, sizeof(hello_buf), &hello_m);
    assert(rc == ZQR_OK);

    uint8_t dec_out[512];
    zqr_decode_result dres;
    memset(&dres, 0, sizeof(dres));
    rc = zqr_t1_decode(hello_m.modules, hello_m.size, dec_out, sizeof(dec_out), &dres);
    assert(rc == ZQR_DECODE_OK);
    assert(dres.bytes_written == 11);
    assert(memcmp(dec_out, "HELLO WORLD", 11) == 0);
    assert(dres.version == 1);
    assert(dres.ecc == ZQR_ECC_MEDIUM);
    assert(dres.mask == hello_m.mask);
    assert((dres.modes_used & 0x02) != 0); // Alphanumeric
    assert(dres.errors_corrected_format == 0);
    assert(dres.errors_corrected_data == 0);

    // Tier boundary in decoder:
    // m2 is version 8 (encoded with 300 digits).
    // - T1 (max v6) must reject with ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER (-21)
    // - T2 (max v10) must decode successfully
    rc = zqr_t1_decode(m2.modules, m2.size, dec_out, sizeof(dec_out), &dres);
    assert(rc == ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER);

    rc = zqr_t2_decode(m2.modules, m2.size, dec_out, sizeof(dec_out), &dres);
    assert(rc == ZQR_DECODE_OK);
    assert(dres.version == 8);
    assert(dres.bytes_written == 300);
    assert(memcmp(dec_out, digits_300, 300) == 0);
    assert((dres.modes_used & 0x01) != 0); // Numeric

    // Decoder error handling
    assert(zqr_t1_decode(NULL, m1.size, dec_out, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_NULL_POINTER);
    assert(zqr_t1_decode(m1.modules, m1.size, NULL, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_NULL_POINTER);
    assert(zqr_t1_decode(m1.modules, m1.size, dec_out, sizeof(dec_out), NULL) == ZQR_ERR_DECODE_NULL_POINTER);
    assert(zqr_t1_decode(m1.modules, 22, dec_out, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_INVALID_SIZE);
    assert(zqr_t1_decode(m1.modules, m1.size, dec_out, 5, &dres) == ZQR_ERR_DECODE_BUFFER_TOO_SMALL);

    // 9. Image Decoder C ABI Integration (Increment B6)
    // Helper lambda / block to rasterize and decode across tiers

    // A. Tier 1 Image Decode (V1-M "HELLO WORLD")
    {
        size_t scale = 4;
        size_t qz = 4;
        size_t dim = (hello_m.size + 2 * qz) * scale;
        uint8_t *px = (uint8_t *)malloc(dim * dim);
        assert(px != NULL);
        memset(px, 255, dim * dim);
        for (size_t r = 0; r < hello_m.size; r++) {
            for (size_t c = 0; c < hello_m.size; c++) {
                if (hello_m.modules[r * hello_m.size + c] == 1) {
                    size_t py = (qz + r) * scale;
                    size_t px_c = (qz + c) * scale;
                    for (size_t dy = 0; dy < scale; dy++) {
                        for (size_t dx = 0; dx < scale; dx++) {
                            px[(py + dy) * dim + (px_c + dx)] = 0;
                        }
                    }
                }
            }
        }

        size_t req_scratch = zqr_t1_image_buffer_len(dim, dim);
        assert(req_scratch == dim * dim * 5 + 3);
        uint8_t *scratch = (uint8_t *)malloc(req_scratch);
        assert(scratch != NULL);

        memset(&dres, 0, sizeof(dres));
        rc = zqr_t1_decode_image(px, dim, dim, scratch, req_scratch, dec_out, sizeof(dec_out), &dres);
        assert(rc == ZQR_DECODE_OK);
        assert(dres.version == 1);
        assert(dres.bytes_written == 11);
        assert(memcmp(dec_out, "HELLO WORLD", 11) == 0);

        // Null pointer checks
        assert(zqr_t1_decode_image(NULL, dim, dim, scratch, req_scratch, dec_out, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_NULL_POINTER);
        assert(zqr_t1_decode_image(px, dim, dim, NULL, req_scratch, dec_out, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_NULL_POINTER);
        assert(zqr_t1_decode_image(px, dim, dim, scratch, req_scratch, NULL, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_NULL_POINTER);

        // ImageTooLarge check
        assert(zqr_t1_decode_image(px, 5000, 4000, scratch, req_scratch, dec_out, sizeof(dec_out), &dres) == ZQR_ERR_DECODE_IMAGE_TOO_LARGE);

        free(scratch);
        free(px);
    }

    // B. Tier 2 Image Decode (V8-M with 300 numeric digits)
    {
        size_t scale = 3;
        size_t qz = 4;
        size_t dim = (m2.size + 2 * qz) * scale;
        uint8_t *px = (uint8_t *)malloc(dim * dim);
        assert(px != NULL);
        memset(px, 255, dim * dim);
        for (size_t r = 0; r < m2.size; r++) {
            for (size_t c = 0; c < m2.size; c++) {
                if (m2.modules[r * m2.size + c] == 1) {
                    size_t py = (qz + r) * scale;
                    size_t px_c = (qz + c) * scale;
                    for (size_t dy = 0; dy < scale; dy++) {
                        for (size_t dx = 0; dx < scale; dx++) {
                            px[(py + dy) * dim + (px_c + dx)] = 0;
                        }
                    }
                }
            }
        }

        size_t req_scratch = zqr_t2_image_buffer_len(dim, dim);
        uint8_t *scratch = (uint8_t *)malloc(req_scratch);
        assert(scratch != NULL);

        // T1 must reject version 8 with ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER (-21)
        rc = zqr_t1_decode_image(px, dim, dim, scratch, req_scratch, dec_out, sizeof(dec_out), &dres);
        assert(rc == ZQR_ERR_DECODE_VERSION_EXCEEDS_TIER);

        // T2 must decode successfully
        memset(&dres, 0, sizeof(dres));
        rc = zqr_t2_decode_image(px, dim, dim, scratch, req_scratch, dec_out, sizeof(dec_out), &dres);
        assert(rc == ZQR_DECODE_OK);
        assert(dres.version == 8);
        assert(dres.bytes_written == 300);
        assert(memcmp(dec_out, digits_300, 300) == 0);

        free(scratch);
        free(px);
    }

    // C. Tier 3 Image Decode (V40-M with forced version)
    {
        uint8_t buf_v40[177 * 177];
        zqr_matrix m40;
        const char *v40_text = "ZQR TIER 3 VERSION 40 C ABI IMAGE DECODER TEST";
        rc = zqr_t3_encode_with_version((const uint8_t *)v40_text, strlen(v40_text), 40, ZQR_ECC_MEDIUM, 0, buf_v40, sizeof(buf_v40), &m40);
        assert(rc == ZQR_OK);
        assert(m40.version == 40);

        size_t scale = 2;
        size_t qz = 4;
        size_t dim = (m40.size + 2 * qz) * scale; // (177 + 8) * 2 = 370
        uint8_t *px = (uint8_t *)malloc(dim * dim);
        assert(px != NULL);
        memset(px, 255, dim * dim);
        for (size_t r = 0; r < m40.size; r++) {
            for (size_t c = 0; c < m40.size; c++) {
                if (m40.modules[r * m40.size + c] == 1) {
                    size_t py = (qz + r) * scale;
                    size_t px_c = (qz + c) * scale;
                    for (size_t dy = 0; dy < scale; dy++) {
                        for (size_t dx = 0; dx < scale; dx++) {
                            px[(py + dy) * dim + (px_c + dx)] = 0;
                        }
                    }
                }
            }
        }

        size_t req_scratch = zqr_t3_image_buffer_len(dim, dim);
        uint8_t *scratch = (uint8_t *)malloc(req_scratch);
        assert(scratch != NULL);

        uint8_t v40_out[1024];
        memset(&dres, 0, sizeof(dres));
        rc = zqr_t3_decode_image(px, dim, dim, scratch, req_scratch, v40_out, sizeof(v40_out), &dres);
        assert(rc == ZQR_DECODE_OK);
        assert(dres.version == 40);
        assert(dres.bytes_written == strlen(v40_text));
        assert(memcmp(v40_out, v40_text, strlen(v40_text)) == 0);

        // Verification of image_buffer_len overflow protection (> 16.8 MP returns 0)
        assert(zqr_t1_image_buffer_len(5000, 5000) == 0);
        assert(zqr_t2_image_buffer_len(5000, 5000) == 0);
        assert(zqr_t3_image_buffer_len(5000, 5000) == 0);

        // Verification of strerror coverage (-20..-32 unified)
        assert(strcmp(zqr_t1_decode_strerror(-21), zqr_t1_decode_image_strerror(-21)) == 0);
        assert(strcmp(zqr_t1_decode_strerror(-30), "image dimensions exceed maximum supported pixel count (16.8 MP)") == 0);
        assert(strcmp(zqr_t1_decode_image_strerror(-31), "no valid QR finder pattern triad detected in image") == 0);
        assert(strcmp(zqr_t1_decode_image_strerror(-32), "degenerate geometry or invalid transformation while sampling image") == 0);

        free(scratch);
        free(px);
    }

    printf("All C ABI integration assertions passed successfully.\n");
    return 0;
}
