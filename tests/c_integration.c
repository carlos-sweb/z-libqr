#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "zqr.h"

int main(void) {
    printf("=== Running z-libqr C ABI Integration Test ===\n");

    // 1. Verify Header Definitions
    assert(ZQR_VERSION_MAJOR == 1);
    assert(ZQR_VERSION_MINOR == 1);
    assert(ZQR_VERSION_PATCH == 0);
    assert(ZQR_OK == 0);
    assert(ZQR_ERR_DATA_TOO_LONG == -1);
    assert(ZQR_ERR_VERSION_EXCEEDS_TIER == -2);
    assert(ZQR_ERR_INVALID_VERSION == -3);
    assert(ZQR_ERR_INVALID_ECC == -4);
    assert(ZQR_ERR_INVALID_MASK == -5);
    assert(ZQR_ERR_BUFFER_TOO_SMALL == -6);
    assert(ZQR_ERR_NULL_POINTER == -7);
    assert(ZQR_ERR_INVALID_SEGMENT_ORDER == -8);

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

    printf("All C ABI integration assertions passed successfully.\n");
    return 0;
}
