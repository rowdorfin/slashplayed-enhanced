#include "spbcastc.h"
#include "spbclayout.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned getBits(const uint8_t *block, unsigned at, unsigned count, bool reverse) {
    unsigned result = 0;
    for (unsigned i = 0; i < count; i++) {
        unsigned bit = reverse ? 127 - at - i : at + i;
        result |= (unsigned)(block[bit / 8] >> (bit % 8) & 1) << i;
    }
    return result;
}

// Decoder for the three emitted modes, using the forward BISE procedure
// in Khronos Data Format. Independent of the encoder's packing helpers.
static void decodeTrits(unsigned t, unsigned out[5]) {
    unsigned c = t & 31;
    if ((t & 28) == 28) {
        c = (t >> 5) * 4 + (t & 3);
        out[3] = out[4] = 2;
    } else if ((t & 96) == 96) {
        out[3] = t >> 7;
        out[4] = 2;
    } else {
        out[3] = t >> 5 & 3;
        out[4] = t >> 7;
    }
    if ((c & 3) == 3) {
        out[0] = (c & 8) ? 2 : (c >> 2 & 1);
        out[1] = c >> 4;
        out[2] = 2;
    } else if ((c & 12) == 12) {
        out[0] = c & 3;
        out[1] = out[2] = 2;
    } else {
        out[0] = (c & 2) ? 2 : (c & 1);
        out[1] = c >> 2 & 3;
        out[2] = c >> 4;
    }
}

static void decodeASTC(const uint8_t block[16], uint8_t rgba[64]) {
    unsigned mode = getBits(block, 0, 11, false);
    bool dual = mode == 0x451;
    assert(mode == 0x42 || mode == 0x51 || dual);
    assert(!getBits(block, 11, 2, false));
    assert(getBits(block, 13, 4, false) == (dual ? 12u : 8u));
    if (dual) assert(getBits(block, 74, 2, false) == 3);

    unsigned endpoints[4][2] = {{0}, {0}, {0}, {255, 255}};
    unsigned bits = dual ? 7 : 8;
    for (unsigned c = 0; c < (dual ? 4u : 3u); c++) {
        for (unsigned e = 0; e < 2; e++) {
            unsigned v = getBits(block, 17 + (2 * c + e) * bits, bits, false);
            endpoints[c][e] = dual ? (v << 1 | v >> 6) : v;
        }
    }
    assert(endpoints[0][0] + endpoints[1][0] + endpoints[2][0] <=
           endpoints[0][1] + endpoints[1][1] + endpoints[2][1]);
    unsigned weights[35];
    if (mode == 0x42) {
        const unsigned table[] = {0, 21, 43, 64};
        for (unsigned i = 0; i < 16; i++) weights[i] = table[getBits(block, i * 2, 2, true)];
    } else {
        unsigned total = dual ? 32 : 16;
        for (unsigned i = 0; i < total; i += 5) {
            unsigned remaining = total - i;
            unsigned trits[5];
            decodeTrits(getBits(block, i / 5 * 8, remaining >= 5 ? 8 : remaining * 2, true), trits);
            for (unsigned j = 0; j < 5; j++) weights[i + j] = trits[j] * 32;
        }
    }
    for (unsigned i = 0; i < 16; i++) {
        for (unsigned c = 0; c < 4; c++) {
            unsigned w = weights[dual ? 2 * i + (c == 3) : i];
            unsigned sum = 257 * (endpoints[c][0] * (64 - w) + endpoints[c][1] * w);
            rgba[i * 4 + c] = (uint8_t)(((sum + 32) / 64) >> 8);
        }
    }
}

static uint32_t randomWord(void) {
    static uint32_t state = UINT32_C(0x18092001);
    state ^= state << 13;
    state ^= state >> 17;
    return state ^= state << 5;
}

static void testBlocks(void) {
    unsigned maxOpaque = 0, maxVisible = 0;
    for (unsigned n = 0; n < 10000; n++) {
        uint8_t source[8], target[16], ref[64], result[64];
        for (unsigned i = 0; i < 8; i++) source[i] = (uint8_t)randomWord();
        if (n % 4 == 0) source[4] = source[5] = source[6] = source[7] = 0xa4; // no index 3
        if (n % 4 == 1) source[4] = source[5] = source[6] = source[7] = 0xff;
        SPBC1ToASTC(source, target);
        SPBCDecodeBlock(SPBC1, source, ref, 16);
        decodeASTC(target, result);
        for (unsigned i = 0; i < 16; i++) {
            assert(ref[4 * i + 3] == result[4 * i + 3]);
            if (!ref[4 * i + 3]) {
                if (n % 4 == 1) assert(!memcmp(ref + 4 * i, result + 4 * i, 4));
                continue;
            }
            for (unsigned c = 0; c < 3; c++) {
                int diff = ref[4 * i + c] - result[4 * i + c];
                unsigned err = (unsigned)(diff < 0 ? -diff : diff);
                unsigned *max = (target[1] & 4) ? &maxVisible : &maxOpaque;
                if (err > *max) *max = err;
            }
        }
    }
    assert(maxOpaque <= 1 && maxVisible <= 2);
}

static void testMipsAndEdges(void) {
    const SPBCSize base = {13, 11, 1};
    uint8_t bc[128], astc[256], expected[16];
    for (size_t level = 0; level < 5; level++) {
        SPBCSize mip = SPBCMipSize(base, level);
        SPBCOrigin origin = {mip.width > 4 ? 4u : 0u, mip.height > 4 ? 4u : 0u, 0};
        SPBCSize size = {mip.width - origin.x, mip.height - origin.y, 1};
        SPBCLayout layout;
        assert(SPBCMakeLayout(SPBC1, mip, origin, size, 8, 32, 0, &layout));
        memset(astc, 0x5a, sizeof astc);
        for (size_t i = 0; i < sizeof bc; i++) bc[i] = (uint8_t)randomWord();
        assert(SPBC1RectToASTC(bc + layout.offset, layout.row, size.width, size.height, astc, 64));
        for (size_t y = 0; y < SPBCBlockCount(size.height); y++) {
            size_t cols = SPBCBlockCount(size.width);
            for (size_t x = 0; x < cols; x++) {
                SPBC1ToASTC(bc + layout.offset + y * layout.row + x * 8, expected);
                assert(!memcmp(expected, astc + y * 64 + x * 16, 16));
            }
            for (size_t x = cols * 16; x < 64; x++) assert(astc[y * 64 + x] == 0x5a);
        }
        assert(astc[SPBCBlockCount(size.height) * 64] == 0x5a);
    }
    SPBCLayout layout;
    assert(!SPBCMakeLayout(SPBC1, base, (SPBCOrigin){1, 0, 0}, (SPBCSize){4, 4, 1}, 0, 8, 0, &layout));
    assert(!SPBC1RectToASTC(bc, 7, 4, 4, astc, 16));
    assert(!SPBC1RectToASTC(bc, 8, 4, 4, astc, 15));
    assert(!SPBC1RectToASTC(bc, 8, 4, 8, astc, SIZE_MAX));
}

int main(void) {
    testBlocks();
    testMipsAndEdges();
    puts("BC1 to ASTC: bounded opaque error, exact punch-through alpha, mip and partial block pitches: PASS");
}
