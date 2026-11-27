// Offline T009-J experiment. Reuse the independent ASTC decoder without
// changing the BC1 regression suite or linking it into the shim.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wreturn-type"
#define main spTestASTCMain
#include "test_bc_astc.c"
#undef main
#pragma GCC diagnostic pop

#include <math.h>
#include <time.h>

enum { Side = 1024, Blocks = Side * Side / 16, Repeats = 16 };
enum Fixture { Gradient, Noise, Leaves, AlphaRamp, UI, Random };
enum Codec { RGBA8, ASTC, ABGR4, A1BGR5, B5G6R5 };

static unsigned quantize(unsigned value, unsigned limit) {
    return (value * limit + 127) / 255;
}

static unsigned expand(unsigned value, unsigned limit) {
    return (value * 255 + limit / 2) / limit;
}

static unsigned rgb565(const unsigned rgb[3]) {
    return quantize(rgb[0], 31) << 11 | quantize(rgb[1], 63) << 5 | quantize(rgb[2], 31);
}

static unsigned nearestAlpha(const uint8_t palette[64], unsigned value, unsigned count) {
    unsigned best = 0;
    for (unsigned i = 1; i < count; i++)
        if (abs((int)palette[4 * i + 3] - (int)value) < abs((int)palette[4 * best + 3] - (int)value))
            best = i;
    return best;
}

static void setField(uint8_t *bytes, unsigned offset, unsigned width, unsigned value) {
    unsigned shift = offset % 8;
    bytes[offset / 8] |= value << shift;
    if (shift + width > 8) bytes[offset / 8 + 1] |= value >> (8 - shift);
}

static void fixtureBlock(SPBCKind kind, enum Fixture fixture, unsigned block, uint8_t out[16]) {
    if (fixture == Random) {
        for (unsigned i = 0; i < 16; i++) out[i] = randomWord();
        return;
    }

    unsigned bx = block % (Side / 4) * 4, by = block / (Side / 4) * 4;
    unsigned texels[16][4], low[] = {255, 255, 255, 255}, high[4] = {0};
    for (unsigned i = 0; i < 16; i++) {
        unsigned x = bx + i % 4, y = by + i / 4;
        int grain = (int)(randomWord() % 49) - 24;
        unsigned u = x % 32, v = y % 32;
        int dx = (int)u - 16, dy = (int)v - 16;
        unsigned *p = texels[i];
        switch (fixture) {
            case Gradient:
                p[0] = x / 4; p[1] = (x + y) / 8; p[2] = y / 4; p[3] = 255;
                break;
            case Noise:
                p[0] = 52 + x / 11 + grain; p[1] = 45 + y / 12 + grain;
                p[2] = 30 + (x + y) / 50 + grain; p[3] = 255;
                break;
            case Leaves:
                p[0] = 46 + grain; p[1] = 114 + x / 16 + grain; p[2] = 51 + grain;
                p[3] = 255 * (dx * dx + 3 * dy * dy < 205 + (int)(x / 32 % 7));
                break;
            case AlphaRamp:
                p[0] = 82 + x / 8; p[1] = 123 + y / 10; p[2] = 204;
                // Broad gradient plus narrow fades, with four alpha levels in a row.
                p[3] = (y < Side / 2) ? x / 4 : (x % 32) * 255 / 31;
                break;
            case UI: {
                // Repeated stem and bowl with antialiasing and two ink colors.
                int stem = abs((int)u - 7);
                int bowl = abs(dx * dx + dy * dy - 100);
                p[0] = u < 16 ? 235 : 110; p[1] = 225; p[2] = u < 16 ? 155 : 245;
                p[3] = (stem <= 1 && v >= 5 && v < 27) || bowl < 24 ? 255 :
                       (stem == 2 && v >= 4 && v < 28) || bowl < 48 ? 170 :
                       (stem == 3 && v >= 4 && v < 28) || bowl < 72 ? 85 : 0;
                break;
            }
            default: abort();
        }
        for (unsigned c = 0; c < 4; c++) {
            if (p[c] < low[c]) low[c] = p[c];
            if (p[c] > high[c]) high[c] = p[c];
        }
    }

    memset(out, 0, 16);
    unsigned c0 = rgb565(high), c1 = rgb565(low);
    out[8] = c0; out[9] = c0 >> 8;
    out[10] = c1; out[11] = c1 >> 8;

    // Ask the reference decoder for its palettes using selector i at texel i.
    uint8_t selectors[16], palette[64];
    memcpy(selectors, out, sizeof selectors);
    selectors[12] = 0xe4;
    if (kind == SPBC3) {
        selectors[0] = out[0] = high[3];
        selectors[1] = out[1] = low[3];
        for (unsigned i = 0; i < 8; i++) setField(selectors + 2, i * 3, 3, i);
    }
    SPBCDecodeBlock(kind, selectors, palette, 16);
    for (unsigned i = 0; i < 16; i++) {
        unsigned best = 0, bestError = UINT32_MAX;
        for (unsigned j = 0; j < 4; j++) {
            unsigned error = 0;
            for (unsigned c = 0; c < 3; c++) {
                int delta = (int)texels[i][c] - palette[4 * j + c];
                error += delta * delta;
            }
            if (error < bestError) {
                bestError = error;
                best = j;
            }
        }
        setField(out + 12, i * 2, 2, best);
        if (kind == SPBC2) setField(out, i * 4, 4, quantize(texels[i][3], 15));
        else setField(out + 2, i * 3, 3, nearestAlpha(palette, texels[i][3], 8));
    }
}

static void pack16(SPBCKind kind, const uint8_t *block, uint16_t *packed, enum Codec codec) {
    uint8_t rgba[64];
    SPBCDecodeBlock(kind, block, rgba, 16);
    for (unsigned i = 0; i < 16; i++) {
        const uint8_t *p = rgba + 4 * i;
        switch (codec) {
            case ABGR4:
                packed[i] = quantize(p[0], 15) | quantize(p[1], 15) << 4 |
                            quantize(p[2], 15) << 8 | quantize(p[3], 15) << 12;
                break;
            case A1BGR5:
                packed[i] = quantize(p[0], 31) | quantize(p[1], 31) << 5 |
                            quantize(p[2], 31) << 10 | quantize(p[3], 1) << 15;
                break;
            case B5G6R5:
                packed[i] = quantize(p[0], 31) | quantize(p[1], 63) << 5 | quantize(p[2], 31) << 11;
                break;
            default: abort();
        }
    }
}

static void unpack16(const uint16_t *packed, uint8_t *rgba, enum Codec codec) {
    for (unsigned i = 0; i < 16; i++) {
        unsigned v = packed[i];
        uint8_t *p = rgba + 4 * i;
        switch (codec) {
            case ABGR4:
                for (unsigned c = 0; c < 4; c++) p[c] = expand(v >> (4 * c) & 15, 15);
                break;
            case A1BGR5:
                p[0] = expand(v & 31, 31); p[1] = expand(v >> 5 & 31, 31);
                p[2] = expand(v >> 10 & 31, 31); p[3] = expand(v >> 15, 1);
                break;
            case B5G6R5:
                p[0] = expand(v & 31, 31); p[1] = expand(v >> 5 & 63, 63);
                p[2] = expand(v >> 11, 31); p[3] = 255;
                break;
            default: abort();
        }
    }
}

struct Stats {
    uint64_t rgb, alpha;
    unsigned maxRGB, maxAlpha, maxMask, badBlocks;
};

static unsigned measure(struct Stats *s, const uint8_t *ref, const uint8_t *rgba, unsigned alphaLimit) {
    unsigned rgb = 0, alpha = 0, mask = 0, squaredRGB = 0;
    for (unsigned i = 0; i < 64; i++) {
        unsigned err = abs((int)rgba[i] - ref[i]);
        if (i % 4 == 3) {
            s->alpha += err * err;
            if (err > alpha) alpha = err;
            if ((ref[i] == 0 || ref[i] == 255) && err > mask) mask = err;
        } else {
            squaredRGB += err * err;
            if (err > rgb) rgb = err;
        }
    }
    if (rgb > s->maxRGB) s->maxRGB = rgb;
    if (alpha > s->maxAlpha) s->maxAlpha = alpha;
    if (mask > s->maxMask) s->maxMask = mask;
    s->badBlocks += rgb > 16 || alpha > alphaLimit || mask != 0;
    s->rgb += squaredRGB;
    return squaredRGB;
}

static int descending(const void *left, const void *right) {
    unsigned a = *(const unsigned *)left, b = *(const unsigned *)right;
    return (a < b) - (a > b);
}

// Even a perfect fallback cannot achieve 40 dB by replacing fewer blocks.
static double minRGBFallback(uint64_t squaredRGB, unsigned blockError[Blocks]) {
    const uint64_t budget = UINT64_C(255) * 255 * Side * Side * 3 / 10000;
    if (squaredRGB <= budget) return 0;
    qsort(blockError, Blocks, sizeof *blockError, descending);
    unsigned n = 0;
    while (squaredRGB > budget)
        squaredRGB -= blockError[n++];
    return 100.0 * n / Blocks;
}

static double psnr(uint64_t error, unsigned channels) {
    return error ? 10 * log10(255.0 * 255 * Side * Side * channels / error) : INFINITY;
}

int main(void) {
    static uint8_t source[Blocks][16];
    static unsigned blockError[Blocks];
    static union {
        uint8_t rgba[Blocks][64];
        uint8_t astc[Blocks][16];
        uint16_t packed[Blocks][16];
    } output;
    const char *fixtures[] = {"gradient", "noise", "leaves", "alpha-ramp", "ui", "random"};
    const char *codecs[] = {"RGBA8", "ASTC", "ABGR4", "A1BGR5", "B5G6R5"};
    puts("BC fixture codec profile MPix/s RGB-dB/max alpha-dB/max mask-max bad-block-% min-RGB-fallback-%");
    for (SPBCKind kind = SPBC2; kind <= SPBC3; kind++) {
        for (enum Fixture fixture = Gradient; fixture <= Random; fixture++) {
            state = UINT32_C(0x18092001);
            for (unsigned b = 0; b < Blocks; b++) fixtureBlock(kind, fixture, b, source[b]);
            for (enum Codec codec = RGBA8; codec <= B5G6R5; codec++) {
                clock_t start = clock();
                for (unsigned n = 0; n < Repeats; n++) {
                    for (unsigned b = 0; b < Blocks; b++) {
                        switch (codec) {
                            case RGBA8: SPBCDecodeBlock(kind, source[b], output.rgba[b], 16); break;
                            case ASTC:
                                if (kind == SPBC2) SPBC2ToASTC(source[b], output.astc[b]);
                                else SPBC3ToASTC(source[b], output.astc[b]);
                                break;
                            default: pack16(kind, source[b], output.packed[b], codec); break;
                        }
                    }
                }
                double rate = (double)Side * Side * Repeats * CLOCKS_PER_SEC /
                              (1e6 * (clock() - start));
                for (unsigned srgb = 0; srgb <= (codec == ASTC); srgb++) {
                    struct Stats s = {0};
                    for (unsigned b = 0; b < Blocks; b++) {
                        uint8_t ref[64], rgba[64];
                        SPBCDecodeBlock(kind, source[b], ref, 16);
                        switch (codec) {
                            case RGBA8: memcpy(rgba, output.rgba[b], sizeof rgba); break;
                            case ASTC: decodeASTC(output.astc[b], rgba, srgb); break;
                            default: unpack16(output.packed[b], rgba, codec); break;
                        }
                        blockError[b] = measure(&s, ref, rgba, kind == SPBC2 ? 4 : 8);
                    }
                    printf("BC%d %-10s %-7s %-4s %7.2f %5.2f/%-3u %5.2f/%-3u %3u %6.2f %6.2f\n",
                           kind, fixtures[fixture], codecs[codec], srgb ? "sRGB" : "lin", rate,
                           psnr(s.rgb, 3), s.maxRGB, psnr(s.alpha, 1), s.maxAlpha, s.maxMask,
                           100.0 * s.badBlocks / Blocks, minRGBFallback(s.rgb, blockError));
                }
            }
        }
    }
}
