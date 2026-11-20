#include "include/PlozzASSBlend.h"
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static inline unsigned divide255(unsigned value) {
    value += 128;
    return (value + (value >> 8)) >> 8;
}

#if defined(__aarch64__)
// (sum + ((sum + 128) >> 8) + 128) >> 8, identical to the scalar tail.
static inline uint8x8_t rounded255(uint16x8_t sum) {
    return vraddhn_u16(sum, vrshrq_n_u16(sum, 8));
}

static inline uint8x8_t over(uint8x8_t dst, uint8x8_t inverse, uint8x8_t alpha, uint8_t src) {
    return rounded255(vmlal_u8(vmull_u8(dst, inverse), alpha, vdup_n_u8(src)));
}
#endif

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
        size_t x = 0;
#if defined(__aarch64__)
        for (; width - x >= 8; x += 8) {
            uint8x8_t a = vld1_u8(coverage + x);
            // Transparent padding and blur margins do not need a destination read or write.
            if (!vget_lane_u64(vreinterpret_u64_u8(a), 0)) continue;
            if (opacity != 255) a = rounded255(vmull_u8(a, vdup_n_u8(opacity)));
            uint8x8_t inv = vmvn_u8(a);
            uint8x8x4_t dst = vld4_u8(pixel + 4*x);
            dst.val[0] = over(dst.val[0], inv, a, red);
            dst.val[1] = over(dst.val[1], inv, a, green);
            dst.val[2] = over(dst.val[2], inv, a, blue);
            dst.val[3] = vadd_u8(a, rounded255(vmull_u8(dst.val[3], inv)));
            vst4_u8(pixel + 4*x, dst);
        }
#endif
        for (; x < width; x++) {
            const unsigned alpha = divide255(coverage[x] * opacity);
            const unsigned inverse = 255 - alpha;
            pixel[4*x] = divide255(red * alpha + pixel[4*x] * inverse);
            pixel[4*x+1] = divide255(green * alpha + pixel[4*x+1] * inverse);
            pixel[4*x+2] = divide255(blue * alpha + pixel[4*x+2] * inverse);
            pixel[4*x+3] = alpha + divide255(pixel[4*x+3] * inverse);
        }
    }
}
