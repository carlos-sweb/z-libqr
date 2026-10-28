#include "zqr_png_wrapper.h"
#include <png.h>
#include <setjmp.h>
#include <string.h>

struct png_mem_sink {
    uint8_t *buf;
    size_t size;
    size_t capacity;
    int overflow;
};

static void png_mem_write(png_structp png_ptr, png_bytep data, png_size_t length) {
    struct png_mem_sink *sink = (struct png_mem_sink *)png_get_io_ptr(png_ptr);
    if (!sink->buf || sink->size + length > sink->capacity) {
        sink->overflow = 1;
        png_error(png_ptr, "buffer overflow");
    }
    memcpy(sink->buf + sink->size, data, length);
    sink->size += length;
}

static void png_mem_flush(png_structp png_ptr) {
    (void)png_ptr;
}

static void png_silent_error(png_structp png_ptr, png_const_charp error_msg) {
    (void)error_msg;
    longjmp(png_jmpbuf(png_ptr), 1);
}

static void png_silent_warning(png_structp png_ptr, png_const_charp warning_msg) {
    (void)png_ptr;
    (void)warning_msg;
}

int zqr_png_write(
    const uint8_t *rgba_pixels,
    int width,
    int height,
    uint8_t *out_buf,
    size_t out_len,
    size_t *out_written
) {
    if (!rgba_pixels || width <= 0 || height <= 0 || !out_written) {
        return -7; // ZQR_ERR_NULL_POINTER
    }

    struct png_mem_sink sink = {
        .buf = out_buf,
        .size = 0,
        .capacity = out_len,
        .overflow = 0,
    };

    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, png_silent_error, png_silent_warning);
    if (!png_ptr) return -1;

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, NULL);
        return -1;
    }

    // Set error handling via setjmp; any png_error jumps here
    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        return sink.overflow ? -6 : -1; // -6 = ZQR_ERR_BUFFER_TOO_SMALL
    }

    png_set_write_fn(png_ptr, &sink, png_mem_write, png_mem_flush);

    png_set_IHDR(
        png_ptr,
        info_ptr,
        (png_uint_32)width,
        (png_uint_32)height,
        8, // bit depth per channel
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    );

    png_write_info(png_ptr, info_ptr);

    size_t stride = (size_t)width * 4;
    for (int y = 0; y < height; y++) {
        png_bytep row = (png_bytep)(rgba_pixels + (size_t)y * stride);
        png_write_row(png_ptr, row);
    }

    png_write_end(png_ptr, NULL);
    png_destroy_write_struct(&png_ptr, &info_ptr);

    *out_written = sink.size;
    return 0; // ZQR_OK
}
