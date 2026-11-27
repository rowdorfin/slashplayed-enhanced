#include "spbcastc.h"
#include "spbclayout.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
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

static void decodeASTC(const uint8_t block[16], uint8_t rgba[64], bool srgb) {
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
            unsigned sum = endpoints[c][0] * (64 - w) + endpoints[c][1] * w;
            sum = srgb && c < 3 ? 256 * sum + 64 * 128 : 257 * sum;
            rgba[i * 4 + c] = (uint8_t)(((sum + 32) / 64) >> 8);
        }
    }
}

static uint32_t state = UINT32_C(0x18092001);

static uint32_t randomWord(void) {
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
        decodeASTC(target, result, false);
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
    assert(maxOpaque <= 1 && maxVisible <= 1);
}

static void measureAlphaBlocks(SPBCKind kind, bool srgb) {
    unsigned maxRGB = 0, maxAlpha = 0;
    uint64_t sumRGB = 0, sumAlpha = 0;
    enum { Blocks = 10000 };
    state = UINT32_C(0x18092001);
    for (unsigned n = 0; n < Blocks; n++) {
        uint8_t source[16], target[16], ref[64], result[64];
        for (unsigned i = 0; i < sizeof source; i++) source[i] = (uint8_t)randomWord();
        switch (kind) {
            case SPBC1:
                if (source[1] > source[3] || (source[1] == source[3] && source[0] > source[2])) {
                    for (unsigned i = 0; i < 2; i++) {
                        uint8_t temp = source[i];
                        source[i] = source[i + 2];
                        source[i + 2] = temp;
                    }
                }
                source[4] |= 3;
                SPBC1ToASTC(source, target);
                break;
            case SPBC2: SPBC2ToASTC(source, target); break;
            case SPBC3: SPBC3ToASTC(source, target); break;
            default: assert(false);
        }
        SPBCDecodeBlock(kind, source, ref, 16);
        decodeASTC(target, result, srgb);
        for (unsigned i = 0; i < 64; i++) {
            unsigned err = ref[i] > result[i] ? ref[i] - result[i] : result[i] - ref[i];
            if (i % 4 == 3) {
                sumAlpha += err;
                if (err > maxAlpha) maxAlpha = err;
            } else {
                sumRGB += err;
                if (err > maxRGB) maxRGB = err;
            }
        }
    }
    assert(kind == SPBC1 ? maxAlpha == 0 : maxAlpha <= 65 && maxRGB <= 46);
    printf("BC%d -> ASTC %-6s max/MAE RGB %u/%.3f alpha %u/%.3f\n",
           kind, srgb ? "sRGB" : "linear", maxRGB, sumRGB / (48.0 * Blocks),
           maxAlpha, sumAlpha / (16.0 * Blocks));
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

static void testEligibility(void) {
    for (unsigned format = 129; format <= 153; format++)
        for (unsigned type = 0; type <= 10; type++)
            for (unsigned usage = 0; usage <= 0x20; usage++)
                for (unsigned storage = 0; storage <= 4; storage++) {
                    bool expected = (format == 130 || format == 131) &&
                                    (type == 2 || type == 3 || type == 5 || type == 6) &&
                                    (usage == 0 || usage == 1 || usage == 16 || usage == 17) &&
                                    storage < 3;
                    assert(SPBC1CompactEligible(format, type, usage, storage, true, true) == expected);
                }
    // IOSurface, buffer, and heap factories are all non-standalone.
    assert(!SPBC1CompactEligible(130, 2, 1, 2, false, true));
    assert(!SPBC1CompactEligible(130, 2, 1, 2, true, false));
    assert(!SPBC1CompactEligible(130, 2, 0x10001, 2, true, true));
}

static void makeBlock(uint8_t block[8], size_t n) {
    for (unsigned i = 0; i < 8; i++) block[i] = (uint8_t)randomWord();
    unsigned a = block[0] | (unsigned)block[1] << 8;
    unsigned b = block[2] | (unsigned)block[3] << 8;
    bool four = n % 3 == 0;
    if (four && a == b) a ^= 1;
    if ((four && a < b) || (!four && a > b)) {
        unsigned temp = a;
        a = b;
        b = temp;
    }
    block[0] = (uint8_t)a;
    block[1] = (uint8_t)(a >> 8);
    block[2] = (uint8_t)b;
    block[3] = (uint8_t)(b >> 8);
    if (n % 3 == 1) memset(block + 4, 0xa4, 4); // three colors without index 3
    if (n % 3 == 2) block[4] |= 3;              // force punch-through
}

static void checkBC1(const uint8_t *source, const uint8_t *astc, bool srgb, unsigned *transparentMax) {
    uint8_t ref[64], rgba[64];
    SPBCDecodeBlock(SPBC1, source, ref, 16);
    decodeASTC(astc, rgba, srgb);
    for (unsigned i = 0; i < sizeof rgba; i += 4) {
        assert(ref[i + 3] == rgba[i + 3]);
        for (unsigned ch = 0; ch < 3; ch++) {
            if (ref[i + 3]) {
                assert(abs((int)ref[i + ch] - rgba[i + ch]) <= 1);
                if (srgb && astc[0] == 0x42) assert(ref[i + ch] == rgba[i + ch]);
            } else {
                assert(ref[i + ch] == 0);
                if (rgba[i + ch] > *transparentMax) *transparentMax = rgba[i + ch];
            }
        }
    }
}

static void testCompactRegion(SPBCSize mip, SPBCOrigin origin, SPBCSize requested, unsigned *transparentMax) {
    size_t cols = SPBCBlockCount(requested.width), rows = SPBCBlockCount(requested.height);
    size_t sourceRow = cols * 8 + 13;
    SPBCLayout layout;
    assert(SPBCMakeLayout(SPBC1, mip, origin, requested, 19, sourceRow, 0, &layout));
    uint8_t *source = calloc(layout.end, 1);
    assert(source);
    for (size_t y = 0; y < rows; y++)
        for (size_t x = 0; x < cols; x++)
            makeBlock(source + layout.offset + y * sourceRow + x * 8, y * cols + x);
    enum { TileLimit = 1008 }; // force horizontal and vertical seams in different mips
    uint8_t staging[TileLimit];
    SPBCOrigin cursor = {0};
    SPBCTile tile;
    size_t blocks = 0, punch = 0;
    while (SPBCNextASTCTile(layout.size, TileLimit, &cursor, &tile)) {
        const uint8_t *start = source + layout.offset + tile.origin.y / 4 * sourceRow + tile.origin.x / 4 * 8;
        assert(tile.bytes <= sizeof staging && tile.row % 16 == 0);
        assert(tile.origin.x % 4 == 0 && tile.origin.y % 4 == 0);
        assert(tile.size.width % 4 == 0 || tile.origin.x + tile.size.width == layout.size.width);
        assert(tile.size.height % 4 == 0 || tile.origin.y + tile.size.height == layout.size.height);
        size_t tilePunch;
        assert(SPBC1RectToASTCCounted(start, sourceRow, tile.size.width, tile.size.height,
                                    staging, tile.row, &tilePunch));
        punch += tilePunch;
        for (size_t y = 0; y < SPBCBlockCount(tile.size.height); y++) {
            for (size_t x = 0; x < SPBCBlockCount(tile.size.width); x++) {
                const uint8_t *bc = start + y * sourceRow + 8 * x;
                const uint8_t *astc = staging + y * tile.row + 16 * x;
                uint8_t expected[16];
                SPBC1ToASTC(bc, expected);
                assert(memcmp(astc, expected, sizeof expected) == 0);
                checkBC1(bc, astc, false, &transparentMax[0]);
                checkBC1(bc, astc, true, &transparentMax[1]);
                blocks++;
            }
        }
    }
    assert(blocks == cols * rows && punch == blocks / 3);
    free(source);
}

static void testCompactLayouts(void) {
    unsigned transparentMax[2] = {0};
    const SPBCSize base = {512, 512, 1};
    assert(SPBCTextureBytes(SPBC1, base, 2, 2, 1, 1) == 1310720);
    assert(SPBCASTCTextureBytes(base, 2, 2, 1) == 327680);
    assert(SPBCASTCTextureBytes(base, 2, 10, 1) == 349552);
    assert(SPBCASTCTextureBytes(base, 3, 2, 3) == 3 * 327680);
    assert(SPBCASTCTextureBytes(base, 5, 2, 1) == 6 * 327680);
    assert(SPBCASTCTextureBytes(base, 6, 2, 2) == 12 * 327680);
    assert(SPBCASTCTextureBytes((SPBCSize){1, 2, 1}, 2, 2, 1) == 32);
    assert(SPBCASTCTextureBytes((SPBCSize){SIZE_MAX, SIZE_MAX, 1}, 2, 1, 1) == 0);
    SPBCOrigin cursor = {0};
    SPBCTile rgbaTile, astcTile;
    assert(SPBCNextTile(SPBC1, base, 4, 4 * 1024 * 1024, &cursor, &rgbaTile));
    cursor = (SPBCOrigin){0};
    assert(SPBCNextASTCTile(base, 4 * 1024 * 1024, &cursor, &astcTile));
    assert(rgbaTile.bytes == 4 * astcTile.bytes);
    for (size_t edge = 512, levels = 10; edge >= 128; edge /= 2, levels--) {
        const size_t chains[] = {2, levels};
        for (unsigned i = 0; i < sizeof chains / sizeof *chains; i++) {
            size_t chain = chains[i];
            for (size_t level = 0; level < chain; level++) {
                SPBCSize mip = SPBCMipSize((SPBCSize){edge, edge, 1}, level);
                testCompactRegion(mip, (SPBCOrigin){0}, mip, transparentMax);
            }
        }
    }
    for (size_t edge = 1; edge <= 3; edge++) {
        testCompactRegion((SPBCSize){8 + edge, 8 + edge, 1}, (SPBCOrigin){4, 4, 0},
                          (SPBCSize){8, 8, 1}, transparentMax); // block-rounded clip
        testCompactRegion((SPBCSize){8 + edge, 8 + edge, 1}, (SPBCOrigin){4, 4, 0},
                          (SPBCSize){4, 4, 1}, transparentMax); // interior partial update
    }
    const unsigned types[] = {3, 5, 6};
    const size_t arrays[] = {3, 1, 2};
    const size_t slices[] = {3, 6, 12};
    for (unsigned i = 0; i < sizeof types / sizeof *types; i++) {
        for (size_t slice = 0; slice < slices[i]; slice++) {
            assert(SPBCValidSlice(types[i], arrays[i], slice));
            testCompactRegion((SPBCSize){7, 7, 1}, (SPBCOrigin){4, 4, 0},
                              (SPBCSize){3, 3, 1}, transparentMax);
        }
        assert(!SPBCValidSlice(types[i], arrays[i], slices[i]));
    }
    assert(transparentMax[0] && transparentMax[1]);
    const uint8_t punch[] = {0x00, 0x04, 0x00, 0xf8, 0x03, 0, 0, 0};
    uint8_t astc[16], rgba[64];
    SPBC1ToASTC(punch, astc);
    for (unsigned srgb = 0; srgb < 2; srgb++) {
        decodeASTC(astc, rgba, srgb);
        assert(rgba[0] == 0 && rgba[1] == 131 && rgba[2] == 0 && rgba[3] == 0);
    }
    printf("BC1 compact transparent RGB sample (0,0,0) -> (%u,%u,%u), max channel linear=%u sRGB=%u\n",
           (unsigned)rgba[0], (unsigned)rgba[1], (unsigned)rgba[2],
           transparentMax[0], transparentMax[1]);
}

int main(void) {
    testBlocks();
    testMipsAndEdges();
    testEligibility();
    testCompactLayouts();
    for (SPBCKind kind = SPBC1; kind <= SPBC3; kind++) {
        measureAlphaBlocks(kind, false);
        measureAlphaBlocks(kind, true);
    }
    puts("BC1 to ASTC: bounded opaque error, exact punch-through alpha, mip and partial block pitches: PASS");
}
