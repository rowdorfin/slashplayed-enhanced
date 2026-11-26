#pragma once
#include "spbcdecode.h"

typedef struct { size_t width, height, depth; } SPBCSize;
typedef struct { size_t x, y, z; } SPBCOrigin;
typedef struct {
    unsigned long format, type, storage, cache, hazard, options, usage, compression;
    SPBCSize size;
    size_t levels, arrayLength, samples;
    bool optimized;
    unsigned swizzle[4];
} SPBCDescriptor;

typedef struct {
    SPBCSize size;
    size_t row, image, offset, end;
} SPBCLayout;

typedef struct {
    SPBCOrigin origin;
    SPBCSize size;
    size_t row, bytes;
} SPBCTile;

SPBCDescriptor SPBCPhysicalDescriptor(SPBCDescriptor descriptor);
SPBCSize SPBCMipSize(SPBCSize base, size_t level);
bool SPBCValidSlice(unsigned long type, size_t arrayLength, size_t slice);
bool SPBCMakeLayout(SPBCKind kind, SPBCSize mip, SPBCOrigin origin, SPBCSize requested,
                    size_t offset, size_t row, size_t image, SPBCLayout *layout);
// Cursor begins at {0,0,0}. Each tile is one depth plane with block-aligned
// starts, and a padded output row for Metal buffer copies.
bool SPBCNextTile(SPBCKind kind, SPBCSize size, size_t alignment, size_t limit,
                  SPBCOrigin *cursor, SPBCTile *tile);
size_t SPBCBlockCount(size_t texels);
