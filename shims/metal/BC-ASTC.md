# BC to ASTC 4×4 proof of concept

This experiment stays in the host tests. The current Metal allocator has to pick
a format before it sees the first upload. BC1 RGBA descriptors give no
opacity guarantee, and choosing ASTC after seeing only the first upload would
miss punch-through blocks in later mips or partial updates. The direct
punch-through mode preserves alpha but changes transparent black, which can
affect unpremultiplied sampling and bilinear filtering. BC1 with an external
opacity guarantee is a candidate for a future device experiment. Keep other
textures on RGBA8 until a quality policy and a way to classify the whole
texture are available.

## Block budget and measurements

[ASTC specification, Khronos Data Format 1.4](https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.pdf)

- BC1 four-color blocks use one partition, RGB direct (CEM 8), and 32 bits
  of weights (0, 21, 43, 64). The 17-bit header leaves 79 endpoint bits,
  enough for six 8-bit components. Three-color blocks without any transparent
  index instead use the 0, 32, 64 weight grid with 26 bits.
- BC1 punch-through uses RGBA direct (CEM 12) and two planes with 32
  three-level weights in 52 bits. The 17-bit header and two-bit plane
  selector leave 57 bits, enough for eight seven-bit endpoints. Alpha uses
  only the extremes. Arbitrary masks need the independent alpha plane.
  Transparent RGB can only be chosen along the opaque RGB endpoints in this
  mode, and the PoC chooses the darker endpoint.
- BC2's 16 independent alpha steps and BC3's eight indices would require
  four and three bits per texel respectively for an unrestricted alpha
  grid. With two RGB weight bits, separate grids would use 96 and 80 bits
  for weights. ASTC uses the same weight range on both planes. For BC2 that
  would require 128 bits for weights alone. BC3 would require 96, leaving
  13 endpoint bits after the header and selector, below CEM 12's minimum
  of 21. BC3's six-step mode also has explicit 0 and 255 entries outside
  its interpolated endpoint ramp. Fewer weights, smaller grids, or heuristic
  partitions can approximate these formats. The measured generic encoder
  results favor keeping RGBA8 for arbitrary blocks in this experiment.

Results on a Ryzen 5 4600G, one thread, GCC -O3, seeded synthetic 1024×1024
images with random blocks and forced BC1 modes. PSNR is in dB on byte
values before the sRGB transfer, followed by maximum byte error. Generic
times include BC decode and exclude ASTC context construction. Arm astcenc
5.3.0 verified every direct block and independently decoded both profiles.

| Input | Codec | ms | MPix/s | RGB | Alpha |
| --- | --- | ---: | ---: | ---: | ---: |
| BC1 opaque | Direct linear | 0.89 | 1182.77 | 58.64 / 1 | ∞ / 0 |
| BC1 opaque | Direct sRGB | 0.89 | 1182.77 | ∞ / 0 | ∞ / 0 |
| BC1 opaque | astcenc fastest | 68.16 | 15.38 | 58.38 / 3 | ∞ / 0 |
| BC1 opaque | astcenc fast | 72.90 | 14.38 | 58.40 / 3 | ∞ / 0 |
| BC1 punch-through | Direct linear | 8.63 | 121.46 | 11.45 / 255 | ∞ / 0 |
| BC1 punch-through | Direct sRGB | 8.63 | 121.46 | 11.45 / 255 | ∞ / 0 |
| BC1 punch-through | astcenc fastest | 853.15 | 1.23 | 24.88 / 222 | 30.60 / 235 |
| BC1 punch-through | astcenc fast | 1548.45 | 0.68 | 28.44 / 203 | 36.36 / 206 |
| BC2 | astcenc fastest | 921.96 | 1.14 | 31.59 / 78 | 25.41 / 131 |
| BC2 | astcenc fast | 1877.06 | 0.56 | 31.19 / 166 | 24.77 / 167 |
| BC3 | astcenc fastest | 837.57 | 1.25 | 32.35 / 144 | 27.77 / 165 |
| BC3 | astcenc fast | 1587.36 | 0.66 | 32.57 / 119 | 25.95 / 210 |

For direct punch-through, visible RGB measures 51.42 dB linear and 51.51 dB
sRGB, both max error 1. The direct rectangle path uses no heap or intermediate
RGBA. GCC reports 112 B for the rectangle frame and 96 B for its block callee.
The packed output is 1 MiB for 1024×1024. The generic full-image path needs
a 4 MiB decoded input at that size plus codec workspace; decoding and
encoding smaller tiles could lower that requirement. The offline sanitizer
suite checks mip chains, block-aligned subregions, padded pitches, and
partial edge blocks.

To reproduce the optional independent test and benchmark from the repo root
on x86-64 with AVX2, use a temporary directory:

```sh
bench=$(mktemp -d)
curl -fL https://codeload.github.com/ARM-software/astc-encoder/tar.gz/refs/tags/5.3.0 -o "$bench/arm.tar.gz"
tar -xzf "$bench/arm.tar.gz" -C "$bench"
arm="$bench/astc-encoder-5.3.0"
cmake -S "$arm" -B "$bench/build" -DASTCENC_ISA_AVX2=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$bench/build" -j
for module in spbcdecode spbclayout spbcastc; do
    cc -O3 -std=c11 -fstack-usage -Ishims/metal -c "shims/metal/$module.c" -o "$bench/$module.o"
done
c++ -O3 -std=c++17 -Ishims/metal -I"$arm/Source" shims/metal/tests/bench_bc_astc.cpp \
    "$bench"/spbc*.o "$bench/build/Source/libastcenc-avx2-static.a" -pthread -o "$bench/bench"
"$bench/bench"
```

## Metal integration constraints

- [Descriptor and heap sizing](spbcfallback.m#L629) must agree on the
  physical format before allocation. The current fallback substitutes the
  decoded format. ASTC would require changing both and using ASTC only for
  supported types and usages.
- [Views](spbcfallback.m#L453) currently translate same-kind variants into
  physical RGBA views. ASTC 4×4 sRGB and linear forms can share bits within
  their own format family. BC and ASTC are different view classes, as are
  RGBA8 and ASTC. [Metal format compatibility](https://developer.apple.com/documentation/metal/mtltexture/maketextureview%28pixelformat%3A%29)
- [GPU copies](spbcfallback.m#L1031) compare decoded formats today. Compare
  actual physical formats for an ASTC path and explicitly reject mixed
  layouts. [Readbacks](spbcfallback.m#L425) already reject BC readback
  through the shim. ASTC bytes returned by native readback could not stand
  in for BC, and RGBA readback would require a conversion.
- Upload existing mips with byte pitches per row of 4×4 blocks, including a
  whole block at partial edges. The same ASTC bitstream supports linear and
  sRGB sampling. The current [GPU mip generation](spbcfallback.m#L1098)
  forwards to Metal and would need an explicit policy for ASTC because it
  requires a color-renderable format. [Compressed updates](https://developer.apple.com/documentation/metal/mtltexture/replace%28region%3Amipmaplevel%3Awithbytes%3Abytesperrow%3A%29) · [Mip generation](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/generatemipmaps%28for%3A%29) · [Feature tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- Skip a persistent per-block cache for this PoC. Hash, lookup, disk, and
  index overhead could cost more than the direct conversion. If repeated
  generic encoding justifies a cache, key by source BC format and block
  bytes or a verified hash, destination block format, and codec version and
  options. Discard old entries when any of those decoding or encoding
  semantics change.
- The launcher loads the game in-process with `dlopen`
  ([launcher.m](../../apps/client/launcher.m#L885)). For a future shim
  that recognizes the flag, `DEVICECTL_CHILD_SP_BC_ASTC=1 apps/client/run.sh`
  uses the existing debug launch mechanism, which passes the staged child
  environment via `xcrun devicectl`
  ([run.sh](../../apps/client/run.sh#L58)). The current code has no ASTC flag.
  An iPad run would still need to validate the Metal calls, texture views,
  filtering, GPU timings, and change in actual allocated memory.
