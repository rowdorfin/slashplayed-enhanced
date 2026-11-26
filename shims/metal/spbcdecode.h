// derived from Tolkara (MIT), Copyright (c) 2026 Vasilii Kharitonov and the Tolkara contributors
// SPDX-License-Identifier: MIT

// Block-compressed (BC1-BC7, "DXT"/"BPTC") texture decoding on the CPU, for
// GPUs without BC sampling (iPhones before the A17 Pro and other devices whose
// -[MTLDevice supportsBCTextureCompression] is NO). Every Mac GPU samples BC,
// so macOS applications upload BC data unconditionally; spbcfallback.m stores
// such textures uncompressed and decodes each upload here. Plain C with no
// Metal dependency, so it can be tested on a host (tests/test_bc_decode.c).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    SPBCNone = 0,
    SPBC1,      // RGBA8: 4-colour, or 3-colour with punch-through alpha
    SPBC2,      // RGBA8: BC1 colour (always 4-colour) and explicit 4-bit alpha
    SPBC3,      // RGBA8: BC1 colour (always 4-colour) and interpolated alpha
    SPBC4,      // R8 unorm
    SPBC4S,     // R8 snorm
    SPBC5,      // RG8 unorm
    SPBC5S,     // RG8 snorm
    SPBC6H,     // RGBA16 float from unsigned BC6H; alpha 1.0
    SPBC6HS,    // RGBA16 float from signed BC6H; alpha 1.0
    SPBC7,      // RGBA8
} SPBCKind;

// MTLPixelFormat numbers, kept here so this file needs no Metal header
// (spbcfallback.m checks them against Metal's own constants).
enum {
    SPPixelFormatR8Unorm = 10, SPPixelFormatR8Snorm = 12,
    SPPixelFormatRG8Unorm = 30, SPPixelFormatRG8Snorm = 32,
    SPPixelFormatRGBA8Unorm = 70, SPPixelFormatRGBA8Unorm_sRGB = 71,
    SPPixelFormatRGBA16Float = 115,
    SPPixelFormatBC1_RGBA = 130, SPPixelFormatBC1_RGBA_sRGB = 131,
    SPPixelFormatBC2_RGBA = 132, SPPixelFormatBC2_RGBA_sRGB = 133,
    SPPixelFormatBC3_RGBA = 134, SPPixelFormatBC3_RGBA_sRGB = 135,
    SPPixelFormatBC4_RUnorm = 140, SPPixelFormatBC4_RSnorm = 141,
    SPPixelFormatBC5_RGUnorm = 142, SPPixelFormatBC5_RGSnorm = 143,
    SPPixelFormatBC6H_RGBFloat = 150, SPPixelFormatBC6H_RGBUfloat = 151,
    SPPixelFormatBC7_RGBAUnorm = 152, SPPixelFormatBC7_RGBAUnorm_sRGB = 153,
};

// The kind of a BC MTLPixelFormat, or SPBCNone for any other format.
SPBCKind SPBCKindOfPixelFormat(unsigned long format);
// The uncompressed MTLPixelFormat that stores a BC format's decoded texels
// (sRGB stays sRGB), or 0 for a format that is not BC.
unsigned long SPBCDecodedPixelFormat(unsigned long format);
// Bytes per 4x4 block (8 for BC1 and BC4, 16 otherwise) and bytes per decoded
// texel; both 0 for SPBCNone.
size_t SPBCBlockBytes(SPBCKind kind);
size_t SPBCTexelBytes(SPBCKind kind);

// Decodes one block into a 4x4 texel tile, rowBytes apart.
void SPBCDecodeBlock(SPBCKind kind, const uint8_t *block, uint8_t *texels, size_t rowBytes);

// Decodes the blocks covering a width x height texel rectangle. `blocks` holds
// rows of ceil(width/4) blocks, blockRowBytes apart (Metal's bytesPerRow for a
// compressed format is per row of blocks). Partial edge blocks are clipped:
// exactly width x height texels are written to `texels`, texelRowBytes apart.
// Returns false (and writes nothing) for SPBCNone, a zero size, or row strides
// too small for the rectangle.
bool SPBCDecodeRect(SPBCKind kind, const uint8_t *blocks, size_t blockRowBytes,
                    uint32_t width, uint32_t height, uint8_t *texels, size_t texelRowBytes);
