#ifndef SPBCASTC_H
#define SPBCASTC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { SPBCASTCBlockBytes = 16 };

// Standalone describes the factory, excluding IOSurfaces, buffer aliases, and heaps.
bool SPBC1CompactEligible(unsigned long format, unsigned long type, unsigned long usage,
                          unsigned long storage, bool standalone, bool supportsASTC);

// Experimental ASTC 4x4 LDR. Punch-through alpha is exact, but the RGB
// of transparent texels can change. The block bits are also valid for sRGB.
void SPBC1ToASTC(const uint8_t source[8], uint8_t target[SPBCASTCBlockBytes]);

// Experimental lossy quantization to three weights per plane.
void SPBC2ToASTC(const uint8_t source[16], uint8_t target[SPBCASTCBlockBytes]);
void SPBC3ToASTC(const uint8_t source[16], uint8_t target[SPBCASTCBlockBytes]);

// Transcode the blocks covering a nonempty texel rectangle. Origins are
// supplied by the caller via the pointers and must be block aligned. Partial
// mip edges still consume one full block. Strides are per row of blocks.
// The buffers must be distinct and large enough for all addressed rows.
bool SPBC1RectToASTC(const uint8_t *source, size_t sourceRow, size_t width, size_t height,
                    uint8_t *target, size_t targetRow);
bool SPBC1RectToASTCCounted(const uint8_t *source, size_t sourceRow, size_t width, size_t height,
                           uint8_t *target, size_t targetRow, size_t *punchThrough);

#endif
