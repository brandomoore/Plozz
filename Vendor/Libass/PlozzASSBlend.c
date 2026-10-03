#include "include/PlozzASSBlend.h"

static inline unsigned divide255(unsigned value) {
    value += 128;
    return (value + (value >> 8)) >> 8;
}

// libass supplies top-down coverage masks and inverted RGBA opacity.
// Compose directly into premultiplied RGBA instead of allocating a CGImage and
// graphics-state clip for every glyph/shadow layer.
void plozz_ass_blend_bitmap(uint8_t *output, size_t output_stride,
                           const uint8_t *mask, size_t mask_stride,
                           size_t width, size_t height, uint32_t color) {
    const unsigned red = color >> 24;
    const unsigned green = (color >> 16) & 255;
    const unsigned blue = (color >> 8) & 255;
    const unsigned opacity = 255 - (color & 255);
    if (!opacity) return;
    for (size_t y = 0; y < height; y++) {
        uint8_t *pixel = output + y * output_stride;
        const uint8_t *coverage = mask + y * mask_stride;
        for (size_t x = 0; x < width; x++) {
            const unsigned alpha = divide255(coverage[x] * opacity);
            const unsigned inverse = 255 - alpha;
            pixel[4*x] = divide255(red * alpha + pixel[4*x] * inverse);
            pixel[4*x+1] = divide255(green * alpha + pixel[4*x+1] * inverse);
            pixel[4*x+2] = divide255(blue * alpha + pixel[4*x+2] * inverse);
            pixel[4*x+3] = alpha + divide255(pixel[4*x+3] * inverse);
        }
    }
}
