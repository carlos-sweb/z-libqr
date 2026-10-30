/*
 * zqr.h - C interface to the z-libqr QR Code Model 2 encoder and decoder.
 *
 * Distributed across three tiers:
 *   - libzqr_t1: versions 1..6   (symbols prefixed zqr_t1_)
 *   - libzqr_t2: versions 1..10  (symbols prefixed zqr_t2_)
 *   - libzqr_t3: versions 1..40  (symbols prefixed zqr_t3_)
 *
 * Each tier exports exactly 16 public symbols. Link exactly one of
 * libzqr_t1, libzqr_t2, libzqr_t3 unless you need to dispatch across tiers
 * at runtime. The .a and .so of the same tier export identical symbols.
 *
 * Canonical documentation is on the zqr_t3_* prototypes below.
 * zqr_t1_* and zqr_t2_* match those signatures; see the zqr_t3_* docs.
 */

#ifndef ZQR_H
#define ZQR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Library version (matches build.zig.zon package version) */
#define ZQR_VERSION_MAJOR 1
#define ZQR_VERSION_MINOR 5
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

/* Decoder status / error codes (distinct from encoder range -1..-9) */
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

/* Image decoder status / error codes (range -30..-39) */
#define ZQR_ERR_DECODE_IMAGE_TOO_LARGE       -30
#define ZQR_ERR_DECODE_NO_FINDERS            -31
#define ZQR_ERR_DECODE_INVALID_IMAGE         -32

/*
 * QR Symbol output description.
 * `modules` points into the caller-provided buffer passed to the encode function.
 * It contains `size * size` bytes where 0 is light and 1 is dark (no quiet zone).
 * Module at row y, col x is modules[y * size + x].
 * Invariant: size == 21 + 4 * (version - 1).
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
 * Advanced encoding options.
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
 * Structured Append sequence options.
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
 * Render options for SVG and PNG rendering.
 */
typedef struct zqr_render_options {
    uint8_t quiet_zone;   /* Standard QR quiet zone is 4 modules */
    uint8_t scale;        /* Pixels per module (default 8) */
    uint8_t reserved[2];  /* Explicit padding */
    uint32_t foreground;  /* RGBA (e.g. 0x000000FF = opaque black) */
    uint32_t background;  /* RGBA (e.g. 0xFFFFFFFF = opaque white) */
} zqr_render_options;

/*
 * Decode result written by zqr_tN_decode / zqr_tN_decode_image.
 *
 * ABI contract (stable since v1.4.0):
 *   - sizeof(zqr_decode_result) == 28 on both 32-bit and 64-bit hosts.
 *   - Field offsets (bytes): bytes_written=0, version=4, ecc=5, mask=6,
 *     modes_used=7, errors_corrected_format=8, errors_corrected_version=9,
 *     errors_corrected_data=10, has_sa=12, sa_position=13, sa_total=14,
 *     sa_parity=15, has_eci=16, _pad1=17..19, eci=20, has_fnc1=24,
 *     fnc1_mode=25, fnc1_app_indicator=26, _pad2=27.
 *
 * Preconditions:
 *   - The caller owns and zeros or ignores unused optional fields.
 *   - Payload bytes are written to the separate `out` buffer passed to
 *     decode / decode_image; this struct only reports metadata and length.
 *
 * Structured Append note:
 *   When has_sa != 0, sa_position is 0-indexed (0..15) and sa_total is the
 *   ISO 0-indexed total (1..15 meaning 2..16 symbols). The library does NOT
 *   reassemble multi-symbol sequences; the caller joins fragments.
 */
typedef struct zqr_decode_result {
    uint32_t bytes_written;           /* Bytes written into caller's out buffer */
    uint8_t version;                  /* QR version (1..40) */
    uint8_t ecc;                      /* ZQR_ECC_* (0..3) */
    uint8_t mask;                     /* Mask pattern (0..7) */
    uint8_t modes_used;               /* Bitfield: 0x1 num, 0x2 alnum, 0x4 byte, 0x8 kanji, 0x10 eci, 0x20 fnc1, 0x40 sa */
    uint8_t errors_corrected_format;  /* Format BCH bit flips corrected (0..3) */
    uint8_t errors_corrected_version; /* Version BCH bit flips corrected (0..3) */
    uint16_t errors_corrected_data;   /* Total Reed-Solomon symbol errors corrected */
    uint8_t has_sa;                   /* 1 if Structured Append header present */
    uint8_t sa_position;              /* 0-indexed position (0..15) */
    uint8_t sa_total;                 /* 0-indexed total (1..15 => 2..16 symbols) */
    uint8_t sa_parity;                /* XOR parity of unencoded input bytes */
    uint8_t has_eci;                  /* 1 if ECI segment present */
    uint8_t _pad1[3];                 /* Alignment padding before uint32_t eci */
    uint32_t eci;                     /* ECI assignment value (0..999999) */
    uint8_t has_fnc1;                 /* 1 if FNC1 present */
    uint8_t fnc1_mode;                /* ZQR_FNC1_FIRST (1) or ZQR_FNC1_SECOND (2) */
    uint8_t fnc1_app_indicator;       /* Application Indicator if fnc1_mode == 2 */
    uint8_t _pad2[1];                 /* Trailing alignment padding */
} zqr_decode_result;

/* -------------------------------------------------------------------------- */
/* Tier 3 (versions 1..40) — canonical documented API                         */
/* -------------------------------------------------------------------------- */

/*
 * Encode data into a single QR symbol.
 *
 * Preconditions:
 *   - data, buf, and out must be non-NULL.
 *   - buf_len must be at least size*size for the chosen version
 *     (use zqr_t3_buffer_len(0) for the tier maximum).
 *   - ecc must be ZQR_ECC_LOW..ZQR_ECC_HIGH.
 *
 * On success: returns ZQR_OK; out->modules points into buf (size*size bytes,
 * 0=light, 1=dark, no quiet zone).
 * On failure: returns a ZQR_ERR_* code (-1..-9).
 */
int zqr_t3_encode(
    const uint8_t *data, size_t len, int ecc,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);

/*
 * Encode with a forced version and optional forced mask.
 * mask: -1 = automatic ISO penalty evaluation; 0..7 = forced pattern.
 * Returns ZQR_OK or ZQR_ERR_* (-1..-9).
 */
int zqr_t3_encode_with_version(
    const uint8_t *data, size_t len, int version,
    int ecc, int mask /* -1 = auto, 0..7 = forced */,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);

/*
 * Encode with advanced options (Kanji, DP optimizer, FNC1, ECI, version range).
 * opts must be non-NULL. Returns ZQR_OK or ZQR_ERR_* (-1..-9).
 */
int zqr_t3_encode_advanced(
    const uint8_t *data, size_t len, const zqr_options *opts,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);

/*
 * Encode a Structured Append sequence (1..16 symbols).
 *
 * Two-phase dry-run: if buf == NULL or out == NULL, computes *out_count and
 * *out_parity without writing matrices and returns ZQR_OK.
 *
 * Preconditions (non-dry-run):
 *   - opts non-NULL; buf_len >= zqr_t3_sequence_buffer_len(version, count);
 *   - out_capacity >= resulting symbol count.
 *
 * Returns ZQR_OK or ZQR_ERR_* (-1..-9).
 */
int zqr_t3_encode_sequence(
    const uint8_t *data, size_t len, const zqr_sequence_options *opts,
    uint8_t *buf, size_t buf_len,
    zqr_matrix *out, size_t out_capacity,
    size_t *out_count, uint8_t *out_parity);

/*
 * Render matrix as an SVG document into buf.
 * Dry-run: buf == NULL returns ZQR_OK and sets *out_len to the required length.
 * matrix and out_len must be non-NULL; matrix->modules must be non-NULL.
 * Returns ZQR_OK or ZQR_ERR_BUFFER_TOO_SMALL / ZQR_ERR_NULL_POINTER.
 */
int zqr_t3_render_svg(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    char *buf, size_t buf_len, size_t *out_len);

/*
 * Render matrix as a PNG image into buf (requires -Denable-png=true).
 * Dry-run: buf == NULL returns ZQR_OK and sets *out_len to an upper bound.
 * If built with -Denable-png=false, returns ZQR_ERR_UNSUPPORTED (-9).
 */
int zqr_t3_render_png(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    uint8_t *buf, size_t buf_len, size_t *out_len);

/*
 * Decode a raw module matrix (row-major, 0/1 per module, no quiet zone).
 *
 * Preconditions:
 *   - matrix, out, and result must be non-NULL.
 *   - matrix holds at least size*size bytes; size must be a valid Model 2
 *     side length (21 + 4*(version-1)).
 *   - out_len must be large enough for the decoded payload
 *     (use zqr_t3_decode_buffer_len(version, ecc) as a safe upper bound).
 *
 * On success: returns ZQR_DECODE_OK (0); writes payload to out and fills result.
 * On failure: returns ZQR_ERR_DECODE_* (-20..-29).
 */
int zqr_t3_decode(
    const uint8_t *matrix, uint8_t size,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);

/*
 * Decode a QR symbol from raw 8-bit grayscale pixels (0=dark, 255=light).
 * Format-agnostic: the caller loads PNG/JPEG/etc. and supplies pixels.
 *
 * Preconditions:
 *   - pixels, scratch, and out must be non-NULL (result may be NULL).
 *   - pixels length >= width*height.
 *   - scratch_len >= zqr_t3_image_buffer_len(width, height).
 *   - width*height must not exceed 16,843,008 (else ZQR_ERR_DECODE_IMAGE_TOO_LARGE).
 *
 * Selects a single best finder triad (does not iterate multiple QR codes).
 * Returns ZQR_DECODE_OK or ZQR_ERR_DECODE_* (-20..-32).
 */
int zqr_t3_decode_image(
    const uint8_t *pixels, size_t width, size_t height,
    uint8_t *scratch, size_t scratch_len,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);

/*
 * Worst-case payload buffer length for decoding a symbol of the given
 * version and ecc. Returns 0 if version/ecc are invalid for this tier.
 */
size_t zqr_t3_decode_buffer_len(int version, int ecc);

/*
 * Scratch buffer length required by zqr_t3_decode_image for width*height.
 * Returns 0 if width*height exceeds the ImageTooLarge limit.
 */
size_t zqr_t3_image_buffer_len(size_t width, size_t height);

/* Human-readable string for a decoder status code (-20..-32 or 0). */
const char *zqr_t3_decode_strerror(int code);

/* Same messages as zqr_t3_decode_strerror (covers image codes too). */
const char *zqr_t3_decode_image_strerror(int code);

/*
 * Module buffer length for a single symbol.
 * version == 0 means the largest version of this tier.
 * Returns 0 if version is invalid or above the tier.
 */
size_t zqr_t3_buffer_len(int version /* 0 = max for tier */);

/*
 * Module buffer length for a Structured Append sequence.
 * version == 0 => tier max; count == 0 => 16.
 * Returns 0 on invalid arguments.
 */
size_t zqr_t3_sequence_buffer_len(int version /* 0 = max for tier */, int count /* 0 = 16 */);

/* Maximum QR version supported by this tier (40 for t3). */
int zqr_t3_max_version(void);

/* Human-readable string for an encoder/render status code (-1..-9 or 0). */
const char *zqr_t3_strerror(int code);

/* -------------------------------------------------------------------------- */
/* Tier 1 (versions 1..6) — same signatures as zqr_t3_*; see its docs.        */
/* -------------------------------------------------------------------------- */

/** Same as zqr_t3_encode; see its docs. */
int zqr_t1_encode(
    const uint8_t *data, size_t len, int ecc,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_with_version; see its docs. */
int zqr_t1_encode_with_version(
    const uint8_t *data, size_t len, int version,
    int ecc, int mask /* -1 = auto, 0..7 = forced */,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_advanced; see its docs. */
int zqr_t1_encode_advanced(
    const uint8_t *data, size_t len, const zqr_options *opts,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_sequence; see its docs. */
int zqr_t1_encode_sequence(
    const uint8_t *data, size_t len, const zqr_sequence_options *opts,
    uint8_t *buf, size_t buf_len,
    zqr_matrix *out, size_t out_capacity,
    size_t *out_count, uint8_t *out_parity);
/** Same as zqr_t3_render_svg; see its docs. */
int zqr_t1_render_svg(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    char *buf, size_t buf_len, size_t *out_len);
/** Same as zqr_t3_render_png; see its docs. */
int zqr_t1_render_png(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    uint8_t *buf, size_t buf_len, size_t *out_len);
/** Same as zqr_t3_decode; see its docs. */
int zqr_t1_decode(
    const uint8_t *matrix, uint8_t size,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);
/** Same as zqr_t3_decode_image; see its docs. */
int zqr_t1_decode_image(
    const uint8_t *pixels, size_t width, size_t height,
    uint8_t *scratch, size_t scratch_len,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);
/** Same as zqr_t3_decode_buffer_len; see its docs. */
size_t zqr_t1_decode_buffer_len(int version, int ecc);
/** Same as zqr_t3_image_buffer_len; see its docs. */
size_t zqr_t1_image_buffer_len(size_t width, size_t height);
/** Same as zqr_t3_decode_strerror; see its docs. */
const char *zqr_t1_decode_strerror(int code);
/** Same as zqr_t3_decode_image_strerror; see its docs. */
const char *zqr_t1_decode_image_strerror(int code);
/** Same as zqr_t3_buffer_len; see its docs. */
size_t zqr_t1_buffer_len(int version /* 0 = max for tier */);
/** Same as zqr_t3_sequence_buffer_len; see its docs. */
size_t zqr_t1_sequence_buffer_len(int version /* 0 = max for tier */, int count /* 0 = 16 */);
/** Same as zqr_t3_max_version; see its docs. Returns 6. */
int zqr_t1_max_version(void);
/** Same as zqr_t3_strerror; see its docs. */
const char *zqr_t1_strerror(int code);

/* -------------------------------------------------------------------------- */
/* Tier 2 (versions 1..10) — same signatures as zqr_t3_*; see its docs.       */
/* -------------------------------------------------------------------------- */

/** Same as zqr_t3_encode; see its docs. */
int zqr_t2_encode(
    const uint8_t *data, size_t len, int ecc,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_with_version; see its docs. */
int zqr_t2_encode_with_version(
    const uint8_t *data, size_t len, int version,
    int ecc, int mask /* -1 = auto, 0..7 = forced */,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_advanced; see its docs. */
int zqr_t2_encode_advanced(
    const uint8_t *data, size_t len, const zqr_options *opts,
    uint8_t *buf, size_t buf_len, zqr_matrix *out);
/** Same as zqr_t3_encode_sequence; see its docs. */
int zqr_t2_encode_sequence(
    const uint8_t *data, size_t len, const zqr_sequence_options *opts,
    uint8_t *buf, size_t buf_len,
    zqr_matrix *out, size_t out_capacity,
    size_t *out_count, uint8_t *out_parity);
/** Same as zqr_t3_render_svg; see its docs. */
int zqr_t2_render_svg(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    char *buf, size_t buf_len, size_t *out_len);
/** Same as zqr_t3_render_png; see its docs. */
int zqr_t2_render_png(
    const zqr_matrix *matrix,
    const zqr_render_options *options,
    uint8_t *buf, size_t buf_len, size_t *out_len);
/** Same as zqr_t3_decode; see its docs. */
int zqr_t2_decode(
    const uint8_t *matrix, uint8_t size,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);
/** Same as zqr_t3_decode_image; see its docs. */
int zqr_t2_decode_image(
    const uint8_t *pixels, size_t width, size_t height,
    uint8_t *scratch, size_t scratch_len,
    uint8_t *out, size_t out_len,
    zqr_decode_result *result);
/** Same as zqr_t3_decode_buffer_len; see its docs. */
size_t zqr_t2_decode_buffer_len(int version, int ecc);
/** Same as zqr_t3_image_buffer_len; see its docs. */
size_t zqr_t2_image_buffer_len(size_t width, size_t height);
/** Same as zqr_t3_decode_strerror; see its docs. */
const char *zqr_t2_decode_strerror(int code);
/** Same as zqr_t3_decode_image_strerror; see its docs. */
const char *zqr_t2_decode_image_strerror(int code);
/** Same as zqr_t3_buffer_len; see its docs. */
size_t zqr_t2_buffer_len(int version /* 0 = max for tier */);
/** Same as zqr_t3_sequence_buffer_len; see its docs. */
size_t zqr_t2_sequence_buffer_len(int version /* 0 = max for tier */, int count /* 0 = 16 */);
/** Same as zqr_t3_max_version; see its docs. Returns 10. */
int zqr_t2_max_version(void);
/** Same as zqr_t3_strerror; see its docs. */
const char *zqr_t2_strerror(int code);

#ifdef __cplusplus
}
#endif

#endif /* ZQR_H */
