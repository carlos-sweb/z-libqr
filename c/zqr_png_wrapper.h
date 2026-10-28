#ifndef ZQR_PNG_WRAPPER_H
#define ZQR_PNG_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Low-level memory PNG encoder wrapping libpng.
 * Safely isolates setjmp / longjmp within C boundaries.
 *
 * Return codes match zqr.h:
 *    0: ZQR_OK
 *   -1: ZQR_ERR_DATA_TOO_LONG (internal libpng initialization / write failure)
 *   -6: ZQR_ERR_BUFFER_TOO_SMALL (output buffer capacity exceeded)
 *   -7: ZQR_ERR_NULL_POINTER (null pointer or invalid dimensions)
 */
int zqr_png_write(
    const uint8_t *rgba_pixels,
    int width,
    int height,
    uint8_t *out_buf,
    size_t out_len,
    size_t *out_written
);

#ifdef __cplusplus
}
#endif

#endif /* ZQR_PNG_WRAPPER_H */
