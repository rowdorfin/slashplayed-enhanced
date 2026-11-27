#include "spbcastc.h"
#include "spbclayout.h"

#include <string.h>

bool SPBC1CompactEligible(unsigned long format, unsigned long type, unsigned long usage,
                          unsigned long storage, bool standalone, bool supportsASTC) {
    // Metal values: 2D, 2DArray, Cube, CubeArray; ShaderRead | PixelFormatView;
    // Shared, Managed, Private. The ObjC integration checks these constants.
    return standalone && supportsASTC && (format == SPPixelFormatBC1_RGBA || format == SPPixelFormatBC1_RGBA_sRGB) &&
           (type == 2 || type == 3 || type == 5 || type == 6) &&
           !(usage & ~0x11ul) && storage <= 2;
}

// Khronos Data Format, ASTC: single partition, 4x4 grid (one weight per
// texel). The weight stream starts at bit 127 and runs toward bit zero.
enum {
    SPBCASTCFourWeights = 0x042,
    SPBCASTCThreeWeights = 0x051,
    SPBCASTCDualPlane = 0x400,
    SPBCASTCRGBDirect = 8,
    SPBCASTCRGBADirect = 12
};

static void spASTCWrite(uint8_t *out, unsigned offset, unsigned bits, unsigned value) {
    unsigned shift = offset % 8;
    unsigned byte = offset / 8;
    out[byte] |= (uint8_t)(value << shift);
    if (shift + bits > 8) out[byte + 1] |= (uint8_t)(value >> (8 - shift));
}

static void spASTCWeightBits(uint8_t *out, unsigned offset, unsigned bits, unsigned value) {
    for (unsigned i = 0; i < bits; i++) {
        unsigned bit = 127 - offset - i;
        out[bit / 8] |= (uint8_t)((value >> i & 1) << (bit % 8));
    }
}

// Canonical inverse of the spec's C and T bit manipulations for five
// trits. The last group zero-fills unused trits before truncating to size.
static unsigned spASTCPackTrits(const uint8_t t[5]) {
    unsigned c;
    if (t[2] < 2) c = t[0] | t[1] << 2 | t[2] << 4;
    else if (t[1] < 2) c = 3 | t[0] << 2 | t[1] << 4;
    else c = 12 | t[0];

    if (t[4] < 2) return c | t[3] << 5 | t[4] << 7;
    if (t[3] < 2) return c | 0x60 | t[3] << 7;
    return 0x1c | (c & 3) | ((c & 28) << 3);
}

static void spASTCEndpoint(unsigned rgb565, uint8_t rgb[3]) {
    unsigned r = rgb565 >> 11, g = rgb565 >> 5 & 63, b = rgb565 & 31;
    rgb[0] = (uint8_t)(r << 3 | r >> 2);
    rgb[1] = (uint8_t)(g << 2 | g >> 4);
    rgb[2] = (uint8_t)(b << 3 | b >> 2);
}

static unsigned spASTCSum(const uint8_t rgb[3], bool sevenBits) {
    unsigned sum = (unsigned)rgb[0] + rgb[1] + rgb[2];
    if (sevenBits) sum = 2 * sum + (rgb[0] >> 6) + (rgb[1] >> 6) + (rgb[2] >> 6);
    return sum;
}

static void spASTCOpaque(uint8_t out[16], uint8_t rgb[2][3], uint32_t indices, bool fourColors) {
    // Both modes leave enough endpoint space for six 8-bit values.
    out[0] = fourColors ? SPBCASTCFourWeights : SPBCASTCThreeWeights;
    spASTCWrite(out, 13, 4, SPBCASTCRGBDirect);
    bool swap = spASTCSum(rgb[0], false) > spASTCSum(rgb[1], false);
    for (unsigned c = 0; c < 3; c++) {
        spASTCWrite(out, 17 + c * 16, 8, rgb[swap][c]);
        spASTCWrite(out, 25 + c * 16, 8, rgb[!swap][c]);
    }
    if (fourColors) {
        // BC order is {0,1,1/3,2/3}; ASTC order is ascending. Reverse
        // each two-bit field so its LSB is nearest the top of the block.
        static const uint8_t reversed[] = {0, 3, 2, 1};
        unsigned flip = swap ? 3 : 0;
        for (unsigned i = 0; i < 4; i++) {
            unsigned v = indices >> (8 * i) & 255;
            out[15 - i] = (uint8_t)((reversed[v & 3] << 6 | reversed[v >> 2 & 3] << 4 |
                                    reversed[v >> 4 & 3] << 2 | reversed[v >> 6]) ^ (flip * 85));
        }
    } else {
        static const uint8_t weights[] = {0, 2, 1};
        for (unsigned i = 0; i < 16; i += 5) {
            unsigned count = i == 15 ? 1 : 5;
            uint8_t trits[5] = {0};
            for (unsigned j = 0; j < count; j++) {
                unsigned w = weights[indices >> (2 * (i + j)) & 3];
                trits[j] = (uint8_t)(swap ? 2 - w : w);
            }
            spASTCWeightBits(out, i / 5 * 8, count == 5 ? 8 : 2, spASTCPackTrits(trits));
        }
    }
}

static unsigned spASTCQuantize7(unsigned value) {
    return (value * 127u + 127u) / 255u;
}

static void spASTCDualPlaneRGBA(uint8_t out[16], uint8_t rgb[2][3], uint32_t indices,
                               const uint8_t colors[4], const uint8_t alphaWeights[16],
                               unsigned alphaMin, unsigned alphaMax) {
    // 52 weight bits + 17 header + 2 plane selector leaves 57 bits.
    // Eight direct endpoints use 56 bits (7-bit values).
    for (unsigned e = 0; e < 2; e++)
        for (unsigned c = 0; c < 3; c++)
            rgb[e][c] = (uint8_t)spASTCQuantize7(rgb[e][c]);
    bool swap = spASTCSum(rgb[0], true) > spASTCSum(rgb[1], true);

    unsigned mode = SPBCASTCThreeWeights | SPBCASTCDualPlane;
    out[0] = (uint8_t)mode;
    out[1] = (uint8_t)(mode >> 8);
    spASTCWrite(out, 13, 4, SPBCASTCRGBADirect);
    for (unsigned c = 0; c < 3; c++) {
        spASTCWrite(out, 17 + c * 14, 7, rgb[swap][c]);
        spASTCWrite(out, 24 + c * 14, 7, rgb[!swap][c]);
    }
    spASTCWrite(out, 59, 7, spASTCQuantize7(alphaMin));
    spASTCWrite(out, 66, 7, spASTCQuantize7(alphaMax));
    spASTCWrite(out, 74, 2, 3);  // second plane controls alpha

    for (unsigned i = 0; i < 32; i += 5) {
        unsigned count = i == 30 ? 2 : 5;
        uint8_t trits[5] = {0};
        for (unsigned j = 0; j < count; j++) {
            unsigned at = i + j;
            if (at % 2) trits[j] = alphaWeights[at / 2];
            else {
                unsigned w = colors[indices >> at & 3];
                trits[j] = w == 3 ? 0 : (uint8_t)(swap ? 2 - w : w);
            }
        }
        spASTCWeightBits(out, i / 5 * 8, count == 5 ? 8 : 4, spASTCPackTrits(trits));
    }
}

static void spASTCPunchThrough(uint8_t out[16], uint8_t rgb[2][3], uint32_t indices) {
    if (indices == UINT32_MAX) memset(rgb, 0, 6);
    // Transparent black generally isn't on the opaque RGB segment. Weight 3
    // selects the darker endpoint while the second plane preserves alpha.
    static const uint8_t colors[] = {0, 2, 1, 3};
    uint8_t alpha[16];
    for (unsigned i = 0; i < 16; i++) alpha[i] = (indices >> (2 * i) & 3) == 3 ? 0 : 2;
    spASTCDualPlaneRGBA(out, rgb, indices, colors, alpha, 0, 255);
}

static bool spASTCBC1(const uint8_t source[8], uint8_t target[16]) {
    unsigned c0 = source[0] | (unsigned)source[1] << 8;
    unsigned c1 = source[2] | (unsigned)source[3] << 8;
    uint32_t indices = source[4] | (uint32_t)source[5] << 8 | (uint32_t)source[6] << 16 |
                       (uint32_t)source[7] << 24;
    uint8_t rgb[2][3];
    spASTCEndpoint(c0, rgb[0]);
    spASTCEndpoint(c1, rgb[1]);
    memset(target, 0, 16);
    bool fourColors = c0 > c1;
    bool punch = !fourColors && (indices & (indices >> 1) & UINT32_C(0x55555555));
    if (punch)
        spASTCPunchThrough(target, rgb, indices);
    else
        spASTCOpaque(target, rgb, indices, fourColors);
    return punch;
}

void SPBC1ToASTC(const uint8_t source[8], uint8_t target[16]) {
    spASTCBC1(source, target);
}

static void spASTCInterpolatedAlpha(SPBCKind kind, const uint8_t source[16], uint8_t target[16]) {
    uint8_t rgba[64], rgb[2][3], alpha[16];
    SPBCDecodeBlock(kind, source, rgba, 16);
    unsigned low = 255, high = 0;
    for (unsigned i = 0; i < 16; i++) {
        unsigned value = rgba[4 * i + 3];
        if (value < low) low = value;
        if (value > high) high = value;
    }
    for (unsigned i = 0; i < 16; i++) {
        unsigned relative = 4 * (rgba[4 * i + 3] - low);
        alpha[i] = relative <= high - low ? 0 : relative >= 3 * (high - low) ? 2 : 1;
    }
    spASTCEndpoint(source[8] | (unsigned)source[9] << 8, rgb[0]);
    spASTCEndpoint(source[10] | (unsigned)source[11] << 8, rgb[1]);
    uint32_t indices = source[12] | (uint32_t)source[13] << 8 |
                       (uint32_t)source[14] << 16 | (uint32_t)source[15] << 24;
    static const uint8_t colors[] = {0, 2, 1, 1};
    memset(target, 0, SPBCASTCBlockBytes);
    spASTCDualPlaneRGBA(target, rgb, indices, colors, alpha, low, high);
}

void SPBC2ToASTC(const uint8_t source[16], uint8_t target[16]) {
    spASTCInterpolatedAlpha(SPBC2, source, target);
}

void SPBC3ToASTC(const uint8_t source[16], uint8_t target[16]) {
    spASTCInterpolatedAlpha(SPBC3, source, target);
}

bool SPBC1RectToASTCCounted(const uint8_t *source, size_t sourceRow, size_t width, size_t height,
                           uint8_t *target, size_t targetRow, size_t *punchThrough) {
    size_t cols = SPBCBlockCount(width), rows = SPBCBlockCount(height);
    if (!source || !target || !cols || !rows || cols > SIZE_MAX / SPBCASTCBlockBytes) return false;
    size_t srcBytes = cols * 8, dstBytes = cols * SPBCASTCBlockBytes;
    if (sourceRow < srcBytes || targetRow < dstBytes ||
        rows - 1 > (SIZE_MAX - srcBytes) / sourceRow ||
        rows - 1 > (SIZE_MAX - dstBytes) / targetRow) return false;
    size_t punch = 0;
    for (size_t y = 0; y < rows; y++)
        for (size_t x = 0; x < cols; x++)
            punch += spASTCBC1(source + y * sourceRow + x * 8, target + y * targetRow + x * SPBCASTCBlockBytes);
    if (punchThrough) *punchThrough = punch;
    return true;
}

bool SPBC1RectToASTC(const uint8_t *source, size_t sourceRow, size_t width, size_t height,
                    uint8_t *target, size_t targetRow) {
    return SPBC1RectToASTCCounted(source, sourceRow, width, height, target, targetRow, NULL);
}
