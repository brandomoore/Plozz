#import "disc_region.h"
#include <string.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)p[0] << 8 | p[1]; }
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static const uint8_t *object(NSData *data, unsigned number, unsigned *count, unsigned *flags) {
    if (data.length < 50 || data.length > 2 * 1024 * 1024) return NULL;
    const uint8_t *bytes = data.bytes;
    if (memcmp(bytes, "MOBJ0200", 8) && memcmp(bytes, "MOBJ0100", 8)) return NULL;
    uint32_t length = u32(bytes + 40);
    if (length < 6 || length > data.length - 44 || number >= u16(bytes + 48)) return NULL;
    size_t cursor = 50, end = 44 + length;
    for (unsigned i = 0; i <= number; i++) {
        if (cursor > end || end - cursor < 4) return NULL;
        unsigned commands = u16(bytes + cursor + 2);
        if (commands > (end - cursor - 4) / 12) return NULL;
        if (i == number) {
            *count = commands; *flags = u16(bytes + cursor);
            return bytes + cursor + 4;
        }
        cursor += 4 + 12 * commands;
    }
    return NULL;
}

unsigned HDMVPreferredRegion(NSData *index, NSData *objects) {
    if (index.length < 40 || index.length > 2 * 1024 * 1024) return 0;
    const uint8_t *bytes = index.bytes;
    if (memcmp(bytes, "INDX0200", 8) && memcmp(bytes, "INDX0100", 8)) return 0;
    uint32_t offset = u32(bytes + 8);
    if (offset < 40 || offset > index.length || index.length - offset < 30) return 0;
    const uint8_t *table = bytes + offset;
    uint32_t length = u32(table);
    unsigned titles = u16(table + 28);
    if (length < 26 || length > index.length - offset - 4 ||
        titles > (length - 26) / 12 || table[4] >> 6 != 1 || table[16] >> 6 != 1) return 0;
    unsigned count = 0, flags = 0;
    const uint8_t *commands = object(objects, u16(table + 10), &count, &flags);
    if (!commands || count > 256) return 0;
    BOOL regionRegisters[4096] = {0};
    for (unsigned i = 0; i < count; i++) {
        const uint8_t *command = commands + 12 * i;
        uint32_t operation = u32(command), destination = u32(command + 4), source = u32(command + 8);
        if (operation == 0x50000001 && destination < 4096) {
            regionRegisters[destination] = source == 0x80000014 ||
                (source < 4096 && regionRegisters[source]);
        } else if (operation == 0x50400001 && destination < 4096) {
            regionRegisters[destination] = NO;
        } else if (operation == 0x50400009 && destination < 4096 && (source & 7) == 7) {
            // Masking reserved bits preserves the A/B/C register value.
        } else if (operation == 0x48400300 && destination < 4096 && regionRegisters[destination] &&
                   (source == 1 || source == 2 || source == 4) && i + 3 < count) {
            const uint8_t *branch = command + 12;
            unsigned title = u32(branch + 4);
            if (u32(branch) != 0x21810000 || !title || title > titles) return 0;
            const uint8_t *target = table + 30 + 12 * (title - 1);
            if (target[0] >> 6 != 1) return 0;
            unsigned rejectedCount = 0, rejectedFlags = 0;
            const uint8_t *rejected = object(objects, u16(target + 6), &rejectedCount, &rejectedFlags);
            // Only recognize an isolated, masked warning loop, followed on the
            // matching path by ordinary first-play and a return to the top menu.
            if (!rejected || rejectedCount != 2 || (rejectedFlags & 0x6000) != 0x6000 ||
                u32(rejected) != 0x22800000 || u32(rejected + 12) != 0x20810000 ||
                u32(rejected + 16) != 0) return 0;
            unsigned cursor = i + 2;
            while (cursor < count && u32(commands + 12 * cursor) == 0x50400001 &&
                   u32(commands + 12 * cursor + 4) < 4096) cursor++;
            if (cursor + 2 != count || u32(commands + 12 * cursor) != 0x22800000 ||
                u32(commands + 12 * (cursor + 1)) != 0x21810000 ||
                u32(commands + 12 * (cursor + 1) + 4) != 0) return 0;
            return source;
        } else {
            return 0;
        }
    }
    return 0;
}
