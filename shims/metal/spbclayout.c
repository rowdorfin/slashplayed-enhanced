#include "spbclayout.h"
#include "spbcastc.h"
#include <limits.h>

static size_t spBCMin(size_t a, size_t b) { return a < b ? a : b; }

size_t SPBCBlockCount(size_t texels) { return texels / 4 + (texels % 4 != 0); }

SPBCDescriptor SPBCPhysicalDescriptor(SPBCDescriptor descriptor) {
    unsigned long physical = SPBCDecodedPixelFormat(descriptor.format);
    if (physical) descriptor.format = physical;
    return descriptor;
}

static size_t spBCMipDimension(size_t base, size_t level) {
    size_t shifted = level < sizeof base * CHAR_BIT ? base >> level : 0;
    return shifted ? shifted : 1;
}

SPBCSize SPBCMipSize(SPBCSize base, size_t level) {
    return (SPBCSize){spBCMipDimension(base.width, level), spBCMipDimension(base.height, level),
                      spBCMipDimension(base.depth, level)};
}

static size_t spBCTextureBytes(size_t unitBytes, bool compressed, SPBCSize base, unsigned long type,
                               size_t levels, size_t arrayLength, size_t samples) {
    if (!unitBytes || !base.width || !base.height || !base.depth || !levels ||
        levels > sizeof(size_t) * CHAR_BIT || !arrayLength || !samples) return 0;
    size_t layers = 1;
    switch (type) {
        case 1: case 3: case 8: layers = arrayLength; break;  // array types
        case 5: layers = 6; break;
        case 6:
            if (arrayLength > SIZE_MAX / 6) return 0;
            layers = arrayLength * 6;
            break;
    }
    size_t total = 0;
    for (size_t level = 0; level < levels; level++) {
        SPBCSize mip = SPBCMipSize(base, level);
        size_t width = compressed ? SPBCBlockCount(mip.width) : mip.width;
        size_t height = compressed ? SPBCBlockCount(mip.height) : mip.height;
        if (width > SIZE_MAX / height) return 0;
        size_t area = width * height;
        if (area > (SIZE_MAX - total) / mip.depth) return 0;
        total += area * mip.depth;
    }
    if (total > SIZE_MAX / unitBytes / layers / samples) return 0;
    return total * unitBytes * layers * samples;
}

size_t SPBCTextureBytes(SPBCKind kind, SPBCSize base, unsigned long type,
                        size_t levels, size_t arrayLength, size_t samples) {
    return spBCTextureBytes(SPBCTexelBytes(kind), false, base, type, levels, arrayLength, samples);
}

size_t SPBCASTCTextureBytes(SPBCSize base, unsigned long type, size_t levels, size_t arrayLength) {
    return spBCTextureBytes(SPBCASTCBlockBytes, true, base, type, levels, arrayLength, 1);
}

bool SPBCValidSlice(unsigned long type, size_t arrayLength, size_t slice) {
    switch (type) {
        case 1: case 3: return slice < arrayLength;  // 1D/2D array
        case 5: return slice < 6;                     // cube
        case 6: return slice / 6 < arrayLength;       // flattened Metal cube-array slice
        default: return slice == 0;                  // includes 3D, whose planes are regions in z
    }
}

static bool spBCClipAxis(size_t mip, size_t origin, size_t requested, size_t *clipped) {
    if (!requested || origin >= mip || origin % 4) return false;
    size_t available = mip - origin;
    if (requested >= available) {
        if (SPBCBlockCount(requested) != SPBCBlockCount(available)) return false;
        *clipped = available;
        return true;
    }
    if (requested % 4) return false;
    *clipped = requested;
    return true;
}

bool SPBCMakeLayout(SPBCKind kind, SPBCSize mip, SPBCOrigin origin, SPBCSize requested,
                    size_t offset, size_t row, size_t image, SPBCLayout *layout) {
    SPBCSize size;
    size_t block = SPBCBlockBytes(kind);
    if (!block || !spBCClipAxis(mip.width, origin.x, requested.width, &size.width) ||
        !spBCClipAxis(mip.height, origin.y, requested.height, &size.height) ||
        origin.z >= mip.depth || !requested.depth || requested.depth > mip.depth - origin.z ||
        size.width > UINT32_MAX || size.height > UINT32_MAX) return false;
    size.depth = requested.depth;
    size_t wide = SPBCBlockCount(size.width), high = SPBCBlockCount(size.height);
    if (wide > SIZE_MAX / block) return false;
    size_t packed = wide * block;
    if (row < packed || high - 1 > (SIZE_MAX - packed) / row) return false;
    size_t plane = (high - 1) * row + packed;
    if (size.depth > 1 && (image < plane || size.depth - 1 > (SIZE_MAX - plane) / image)) return false;
    size_t length = (size.depth - 1) * image + plane;
    if (offset > SIZE_MAX - length) return false;
    *layout = (SPBCLayout){size, row, image, offset, offset + length};
    return true;
}

static void spBCAdvanceTile(SPBCOrigin *cursor, SPBCSize size, size_t width, size_t height) {
    cursor->x += width;
    if (cursor->x == size.width) {
        cursor->x = 0;
        cursor->y += height;
        if (cursor->y == size.height) {
            cursor->y = 0;
            cursor->z++;
        }
    }
}

bool SPBCNextTile(SPBCKind kind, SPBCSize size, size_t alignment, size_t limit,
                  SPBCOrigin *cursor, SPBCTile *tile) {
    size_t texel = SPBCTexelBytes(kind);
    if (!texel || !alignment || cursor->x >= size.width || cursor->y >= size.height || cursor->z >= size.depth) return false;
    size_t maxRow = (limit / 4) / alignment * alignment;
    if (maxRow / texel < 4) return false;
    size_t maxWidth = maxRow / texel / 4 * 4;
    size_t fullWidth = spBCMin(size.width, maxWidth);
    size_t fullRow = (fullWidth * texel + alignment - 1) / alignment * alignment;
    size_t rows = limit / fullRow / 4 * 4;
    size_t width = spBCMin(size.width - cursor->x, fullWidth);
    size_t height = spBCMin(size.height - cursor->y, rows);
    size_t row = (width * texel + alignment - 1) / alignment * alignment;
    *tile = (SPBCTile){*cursor, {width, height, 1}, row, row * height};
    spBCAdvanceTile(cursor, size, width, height);
    return true;
}

bool SPBCNextASTCTile(SPBCSize size, size_t limit, SPBCOrigin *cursor, SPBCTile *tile) {
    size_t maxBlocks = limit / SPBCASTCBlockBytes;
    if (!maxBlocks || cursor->x >= size.width || cursor->y >= size.height || cursor->z >= size.depth)
        return false;
    // A strip keeps the same height across all of its tiles, including the
    // right edge. Buffer offsets and pitches stay multiples of a full block.
    size_t stripBlocks = spBCMin(SPBCBlockCount(size.width), maxBlocks);
    size_t width = spBCMin(size.width - cursor->x, stripBlocks * 4);
    size_t height = spBCMin(size.height - cursor->y, maxBlocks / stripBlocks * 4);
    size_t row = SPBCBlockCount(width) * SPBCASTCBlockBytes;
    *tile = (SPBCTile){*cursor, {width, height, 1}, row, row * SPBCBlockCount(height)};
    spBCAdvanceTile(cursor, size, width, height);
    return true;
}
