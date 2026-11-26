#include "spbclayout.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_descriptor(unsigned long format, size_t width, size_t levels,
                            const size_t *compressed, const size_t *decoded) {
    const SPBCDescriptor logical = {
        .format = format, .type = 2, .storage = 2, .options = 0x20, .usage = 1,
        .size = {width, width, 1}, .levels = levels, .arrayLength = 1, .samples = 1,
        .optimized = true, .swizzle = {2, 3, 4, 5},
    };
    const SPBCDescriptor sizing = SPBCPhysicalDescriptor(logical);
    const SPBCDescriptor allocation = SPBCPhysicalDescriptor(logical);
    assert(sizing.format == 70 && allocation.format == sizing.format && logical.format == format);
    assert(sizing.type == logical.type && sizing.storage == logical.storage);
    assert(sizing.cache == logical.cache && sizing.hazard == logical.hazard);
    assert(sizing.options == logical.options && sizing.usage == logical.usage);
    assert(sizing.levels == logical.levels && sizing.arrayLength == logical.arrayLength);
    assert(sizing.samples == logical.samples && sizing.compression == logical.compression);
    assert(sizing.optimized == logical.optimized && !memcmp(sizing.swizzle, logical.swizzle, sizeof sizing.swizzle));
    SPBCKind kind = SPBCKindOfPixelFormat(format);
    for (size_t level = 0; level < levels; level++) {
        SPBCSize mip = SPBCMipSize(sizing.size, level);
        assert(mip.width == (width >> level) && mip.height == mip.width && mip.depth == 1);
        assert(mip.width == allocation.size.width >> level);
        size_t blocks = width >> (level + 2);
        assert(SPBCBlockCount(mip.width) == blocks);
        SPBCLayout layout;
        assert(SPBCMakeLayout(kind, mip, (SPBCOrigin){0}, mip, 0, blocks * SPBCBlockBytes(kind), 0, &layout));
        assert(layout.end == compressed[level]);
        assert(mip.width * mip.height * SPBCTexelBytes(kind) == decoded[level]);
    }
}

static void test_volume_and_tiles(void) {
    const SPBCSize mip = {63, 17, 3};
    SPBCLayout layout;
    assert(SPBCMakeLayout(SPBC1, mip, (SPBCOrigin){0, 0, 1}, (SPBCSize){64, 20, 2},
                          19, 144, 800, &layout));
    assert(layout.offset == 19 && layout.size.width == 63 && layout.size.height == 17);
    assert(layout.size.depth == 2 && layout.end == 19 + 800 + 4 * 144 + 128);
    uint8_t source[1600] = {0};
    source[19 + 800 + 4 * 144 + 15 * 8 + 1] = 0xf8; // red endpoint in the last block of plane 1
    uint8_t last[4];
    assert(SPBCDecodeRect(SPBC1, source + 19 + 800 + 4 * 144 + 15 * 8, 144, 1, 1, last, 4));
    assert(last[0] == 255 && last[1] == 0 && last[2] == 0 && last[3] == 255);
    uint8_t decoded[17][63][4];
    assert(SPBCDecodeRect(SPBC1, source + layout.offset + layout.image, layout.row,
                          63, 17, &decoded[0][0][0], sizeof decoded[0]));
    assert(!memcmp(decoded[16][62], last, sizeof last));
    assert(decoded[16][59][0] == 0 && decoded[15][62][0] == 0);
    assert(!SPBCMakeLayout(SPBC1, mip, (SPBCOrigin){2, 0, 0}, mip, 0, 144, 800, &layout));
    assert(!SPBCMakeLayout(SPBC1, mip, (SPBCOrigin){0}, (SPBCSize){5, 4, 1}, 0, 144, 0, &layout));
    assert(!SPBCMakeLayout(SPBC1, mip, (SPBCOrigin){0}, mip, SIZE_MAX, 144, 800, &layout));
    assert(!SPBCMakeLayout(SPBC1, mip, (SPBCOrigin){0}, mip, 0, 144, 200, &layout));
    assert(SPBCValidSlice(3, 2, 1) && !SPBCValidSlice(3, 2, 2));
    assert(SPBCValidSlice(5, 1, 5) && !SPBCValidSlice(5, 1, 6));
    assert(SPBCValidSlice(6, 2, 11) && !SPBCValidSlice(6, 2, 12));
    assert(!SPBCValidSlice(7, 3, 1));

    SPBCOrigin cursor = {0};
    SPBCTile tile;
    unsigned char coverage[3][17][63] = {0};
    unsigned tiles = 0;
    while (SPBCNextTile(SPBC6H, mip, 256, 1024, &cursor, &tile)) {
        tiles++;
        assert(tile.bytes <= 1024 && tile.row % 256 == 0);
        assert(tile.origin.x % 4 == 0 && tile.origin.y % 4 == 0);
        for (size_t y = 0; y < tile.size.height; y++)
            for (size_t x = 0; x < tile.size.width; x++)
                coverage[tile.origin.z][tile.origin.y + y][tile.origin.x + x]++;
    }
    assert(tiles == 30);
    for (size_t z = 0; z < 3; z++)
        for (size_t y = 0; y < 17; y++)
            for (size_t x = 0; x < 63; x++) assert(coverage[z][y][x] == 1);
}

static void test_texture_bytes(void) {
    const SPBCSize image = {7, 5, 1};
    const SPBCSize volume = {7, 5, 3};
    const SPBCSize cube = {8, 8, 1};
    assert(SPBCTextureBytes(SPBC1, image, 2, 3, 1, 1) == 4 * (35 + 6 + 1));
    assert(SPBCTextureBytes(SPBC3, image, 3, 3, 2, 1) == 8 * (35 + 6 + 1));
    assert(SPBCTextureBytes(SPBC4S, volume, 7, 3, 1, 1) == 105 + 6 + 1);
    assert(SPBCTextureBytes(SPBC5, cube, 5, 4, 1, 1) == 2 * 6 * (64 + 16 + 4 + 1));
    assert(SPBCTextureBytes(SPBC5S, cube, 6, 4, 3, 1) == 2 * 18 * (64 + 16 + 4 + 1));
    assert(SPBCTextureBytes(SPBC6H, image, 8, 1, 2, 4) == 35 * 8 * 2 * 4);
    assert(!SPBCTextureBytes(SPBCNone, image, 2, 1, 1, 1));
    assert(!SPBCTextureBytes(SPBC1, image, 2, 0, 1, 1));
    assert(!SPBCTextureBytes(SPBC1, (SPBCSize){SIZE_MAX, 2, 1}, 2, 1, 1, 1));
    assert(!SPBCTextureBytes(SPBC1, (SPBCSize){SIZE_MAX, 1, 1}, 2, 2, 1, 1));
    assert(!SPBCTextureBytes(SPBC1, (SPBCSize){SIZE_MAX, 1, 1}, 2, 1, 1, 1));
    assert(!SPBCTextureBytes(SPBC1, cube, 6, 1, SIZE_MAX, 1));
    puts("BC texture bytes: packed formats, mip chains, arrays, cubes, volumes, and overflow: PASS");
}

int main(void) {
    test_descriptor(130, 64, 5, (size_t[]){2048, 512, 128, 32, 8},
                    (size_t[]){16384, 4096, 1024, 256, 64});
    test_descriptor(132, 32, 1, (size_t[]){1024}, (size_t[]){4096});
    assert(SPBCPhysicalDescriptor((SPBCDescriptor){.format = 131}).format == 71);
    assert(SPBCMipSize((SPBCSize){5, 3, 9}, 1000).depth == 1);
    test_volume_and_tiles();
    test_texture_bytes();
    puts("BC layout: A/B descriptors, mip sizes, source offset and pitches, clipping, slices, and bounded tiles: PASS");
}
