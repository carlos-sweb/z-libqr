/*
 * zqr.h - C interface to the z-libqr QR Code encoder.
 *
 * Distributed across three tiers:
 *   - libzqr_t1: versions 1..6   (symbols prefixed zqr_t1_)
 *   - libzqr_t2: versions 1..10  (symbols prefixed zqr_t2_)
 *   - libzqr_t3: versions 1..40  (symbols prefixed zqr_t3_)
 *
 * Link exactly one of libzqr_t1, libzqr_t2, libzqr_t3 unless you need to
 * dispatch across tiers at runtime. The .a and .so of the same tier export
 * identical symbols.
 */

#ifndef ZQR_H
#define ZQR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version */
#define ZQR_VERSION_MAJOR 1
#define ZQR_VERSION_MINOR 0
#define ZQR_VERSION_PATCH 0

/* Error correction levels (matches enum qrcodegen_Ecc in nayuki/QR-Code-generator) */
#define ZQR_ECC_LOW      0
#define ZQR_ECC_MEDIUM   1
#define ZQR_ECC_QUARTILE 2
#define ZQR_ECC_HIGH     3

/* Encoding modes (4-bit mode indicators) */
#define ZQR_MODE_NUMERIC      0x1
#define ZQR_MODE_ALPHANUMERIC 0x2
#define ZQR_MODE_BYTE         0x4
#define ZQR_MODE_KANJI        0x8
#define ZQR_MODE_ECI          0x7

/* Status / error codes */
#define ZQR_OK                    0
#define ZQR_ERR_DATA_TOO_LONG    -1
#define ZQR_ERR_VERSION_EXCEEDS_TIER -2
#define ZQR_ERR_INVALID_VERSION  -3
#define ZQR_ERR_INVALID_ECC      -4
#define ZQR_ERR_INVALID_MASK     -5
#define ZQR_ERR_BUFFER_TOO_SMALL -6
#define ZQR_ERR_NULL_POINTER     -7

/*
 * QR Symbol output description.
 * `modules` points into the caller-provided buffer passed to the encode function.
 * It contains `size * size` bytes where 0 is light and 1 is dark (no quiet zone).
 * Module at row y, col x is modules[y * size + x].
 */
typedef struct zqr_matrix {
    uint8_t version;
    uint8_t size;
    uint8_t ecc;
    uint8_t mask;
    uint8_t mode;
    uint8_t reserved[3];
    const uint8_t *modules;
} zqr_matrix;

/* Macro to declare prototypes for a given tier prefix */
#define ZQR_DECLARE_TIER_PROTOTYPES(prefix) \
    int prefix##_encode( \
        const uint8_t *data, size_t len, int ecc, \
        uint8_t *buf, size_t buf_len, zqr_matrix *out); \
    int prefix##_encode_with_version( \
        const uint8_t *data, size_t len, int version, \
        int ecc, int mask /* -1 = auto, 0..7 = forced */, \
        uint8_t *buf, size_t buf_len, zqr_matrix *out); \
    size_t prefix##_buffer_len(int version /* 0 = max for tier */); \
    int prefix##_max_version(void); \
    const char *prefix##_strerror(int code);

ZQR_DECLARE_TIER_PROTOTYPES(zqr_t1)
ZQR_DECLARE_TIER_PROTOTYPES(zqr_t2)
ZQR_DECLARE_TIER_PROTOTYPES(zqr_t3)

#undef ZQR_DECLARE_TIER_PROTOTYPES

#ifdef __cplusplus
}
#endif

#endif /* ZQR_H */
