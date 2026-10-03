#ifndef PLOZZ_ASS_BLEND_H
#define PLOZZ_ASS_BLEND_H

#include <stddef.h>
#include <stdint.h>

void plozz_ass_blend_bitmap(uint8_t *output, size_t output_stride,
                           const uint8_t *mask, size_t mask_stride,
                           size_t width, size_t height, uint32_t color);

#endif
