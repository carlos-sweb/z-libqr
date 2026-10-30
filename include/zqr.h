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
#define ZQR_VERSION_MINOR 3
#define ZQR_VERSION_PATCH 0

/* Error correction levels (matches enum qrcodegen_Ecc in nayuki/QR-Code-generator) */
#define ZQR_ECC_LOW      0
#define ZQR_ECC_MEDIUM   1
#define ZQR_ECC_QUARTILE 2
#define ZQR_ECC_HIGH     3

/* Encoding modes (4-bit mode indicators) */
#define ZQR_MODE_NUMERIC           0x1
#define ZQR_MODE_ALPHANUMERIC      0x2
#define ZQR_MODE_BYTE              0x4
#define ZQR_MODE_KANJI             0x8
#define ZQR_MODE_ECI               0x7
#define ZQR_MODE_FNC1_FIRST        0x5
#define ZQR_MODE_FNC1_SECOND       0x9
#define ZQR_MODE_STRUCTURED_APPEND 0x3

/* FNC1 Operating Modes (ISO/IEC 18004 clause 7.4.8) */
#define ZQR_FNC1_NONE   0
#define ZQR_FNC1_FIRST  1
#define ZQR_FNC1_SECOND 2

/* Status / error codes */
#define ZQR_OK                    0
#define ZQR_ERR_DATA_TOO_LONG    -1
#define ZQR_ERR_VERSION_EXCEEDS_TIER -2
#define ZQR_ERR_INVALID_VERSION  -3
#define ZQR_ERR_INVALID_ECC      -4
#define ZQR_ERR_INVALID_MASK     -5
#define ZQR_ERR_BUFFER_TOO_SMALL -6
#define ZQR_ERR_NULL_POINTER     -7
#define ZQR_ERR_INVALID_SEGMENT_ORDER -8
#define ZQR_ERR_UNSUPPORTED      -9 /* Feature disabled at compile-time (e.g. render_png with -Denable-png=false) */

/* Decoder status / error codes (Increment A5, distinct from encoder range -1..-9) */
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

/* Image decoder status / error codes (Increment B6, range -30..-39) */
#define ZQR_ERR_DECODE_IMAGE_TOO_LARGE       -30
#define ZQR_ERR_DECODE_NO_FINDERS            -31
#define ZQR_ERR_DECODE_INVALID_IMAGE         -32

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

/*
 * Advanced encoding options (additive in Increment 12 and 13).
 */
typedef struct zqr_options {
    int min_version; /* 0 = tables.min_version (1) */
    int max_version; /* 0 = tier max_version */
    int ecc;         /* ZQR_ECC_* */
    int mask;        /* -1 = auto, 0..7 = forced */
    int kanji;       /* 0 = off, 1 = enable pure Kanji mode */
    int optimize;    /* 0 = single mode, 1 = optimal multi-mode DP */
    int fnc1;        /* ZQR_FNC1_NONE, ZQR_FNC1_FIRST, ZQR_FNC1_SECOND */
    uint8_t fnc1_app_indicator; /* Application Indicator (0..255) if fnc1 == ZQR_FNC1_SECOND */
    uint8_t reserved[3];        /* Explicit ABI padding */
    int has_eci;     /* 0 = no ECI, 1 = use eci field */
    uint32_t eci;    /* ECI assignment value (0..999999) */
} zqr_options;

/*
 * Structured Append sequence options (additive in Increment 15).
 */
typedef struct zqr_sequence_options {
    int min_version; /* 0 = tables.min_version (1) */
    int max_version; /* 0 = tier max_version */
    int ecc;         /* ZQR_ECC_* */
    int mask;        /* -1 = auto, 0..7 = forced */
    int kanji;       /* 0 = off, 1 = enable pure Kanji mode */
    int optimize;    /* 0 = single mode, 1 = optimal multi-mode DP */
    int fnc1;        /* ZQR_FNC1_NONE, ZQR_FNC1_FIRST, ZQR_FNC1_SECOND */
    uint8_t fnc1_app_indicator; /* Application Indicator (0..255) if fnc1 == ZQR_FNC1_SECOND */
    uint8_t reserved[3];        /* Explicit ABI padding */
    int has_eci;     /* 0 = no ECI, 1 = use eci field */
    uint32_t eci;    /* ECI assignment value (0..999999) */
    int symbol_count; /* 0 = auto (1..16), 1..16 = forced symbol count */
} zqr_sequence_options;

/*
 * Render options for SVG and PNG rendering (Increment 17).
 */
typedef struct zqr_render_options {
    uint8_t quiet_zone;   /* Standard QR quiet zone is 4 modules */
    uint8_t scale;        /* Pixels per module (default 8) */
    uint8_t reserved[2];  /* Explicit padding */
    uint32_t foreground;  /* RGBA (e.g. 0x000000FF = opaque black) */
    uint32_t background;  /* RGBA (e.g. 0xFFFFFFFF = opaque white) */
} zqr_render_options;

/*
 * QR Symbol decode result (Increment A5).
 * Contains the length of decoded payload, symbol parameters, error correction metrics,
 * and optional metadata (Structured Append, ECI, FNC1).
 * Total size: exactly 28 bytes on both 32-bit and 64-bit systems (all fields naturally aligned).
 */
typedef struct zqr_decode_result {
    uint32_t bytes_written;           /* Number of bytes written into caller's out buffer */
    uint8_t version;                  /* QR version (1..40) */
    uint8_t ecc;                      /* ZQR_ECC_* (0..3) */
    uint8_t mask;                     /* Mask pattern (0..7) */
    uint8_t modes_used;               /* Bitfield: 0x1 num, 0x2 alnum, 0x4 byte, 0x8 kanji, 0x10 eci, 0x20 fnc1, 0x40 sa */
    uint8_t errors_corrected_format;  /* Number of format BCH bit flips corrected (0..3) */
    uint8_t errors_corrected_version; /* Number of version BCH bit flips corrected (0..3) */
    uint16_t errors_corrected_data;   /* Total symbol errors corrected by Reed-Solomon */
    uint8_t has_sa;                   /* 1 if Structured Append header present, 0 otherwise */
    uint8_t sa_position;              /* 0-indexed position (0..15) */
    uint8_t sa_total;                 /* 0-indexed total (1..15) */
    uint8_t sa_parity;                /* Parity checksum */
    uint8_t has_eci;                  /* 1 if ECI segment present, 0 otherwise */
    uint8_t _pad1[3];                 /* Alignment padding for uint32_t eci */
    uint32_t eci;                     /* ECI assignment value (0..999999) */
    uint8_t has_fnc1;                 /* 1 if FNC1 present, 0 otherwise */
    uint8_t fnc1_mode;                /* ZQR_FNC1_FIRST (1) or ZQR_FNC1_SECOND (2) */
    uint8_t fnc1_app_indicator;       /* Application Indicator (0..255) if fnc1_mode == 2 */
    uint8_t _pad2[1];                 /* Trailing alignment padding */
} zqr_decode_result;

/* Macro to declare prototypes for a given tier prefix */
#define ZQR_DECLARE_TIER_PROTOTYPES(prefix) \
    int prefix##_encode( \
        const uint8_t *data, size_t len, int ecc, \
        uint8_t *buf, size_t buf_len, zqr_matrix *out); \
    int prefix##_encode_with_version( \
        const uint8_t *data, size_t len, int version, \
        int ecc, int mask /* -1 = auto, 0..7 = forced */, \
        uint8_t *buf, size_t buf_len, zqr_matrix *out); \
    int prefix##_encode_advanced( \
        const uint8_t *data, size_t len, const zqr_options *opts, \
        uint8_t *buf, size_t buf_len, zqr_matrix *out); \
    int prefix##_encode_sequence( \
        const uint8_t *data, size_t len, const zqr_sequence_options *opts, \
        uint8_t *buf, size_t buf_len, \
        zqr_matrix *out, size_t out_capacity, \
        size_t *out_count, uint8_t *out_parity); \
    int prefix##_render_svg( \
        const zqr_matrix *matrix, \
        const zqr_render_options *options, \
        char *buf, size_t buf_len, size_t *out_len); \
    int prefix##_render_png( \
        const zqr_matrix *matrix, \
        const zqr_render_options *options, \
        uint8_t *buf, size_t buf_len, size_t *out_len); \
    int prefix##_decode( \
        const uint8_t *matrix, uint8_t size, \
        uint8_t *out, size_t out_len, \
        zqr_decode_result *result); \
    int prefix##_decode_image( \
        const uint8_t *pixels, size_t width, size_t height, \
        uint8_t *scratch, size_t scratch_len, \
        uint8_t *out, size_t out_len, \
        zqr_decode_result *result); \
    size_t prefix##_decode_buffer_len(int version, int ecc); \
    size_t prefix##_image_buffer_len(size_t width, size_t height); \
    const char *prefix##_decode_strerror(int code); \
    const char *prefix##_decode_image_strerror(int code); \
    size_t prefix##_buffer_len(int version /* 0 = max for tier */); \
    size_t prefix##_sequence_buffer_len(int version /* 0 = max for tier */, int count /* 0 = 16 */); \
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
