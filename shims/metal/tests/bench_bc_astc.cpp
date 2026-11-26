// Optional local benchmark. Build against Arm astcenc 5.3.0 (see BC-ASTC.md).
#include <astcenc.h>
extern "C" {
#include "spbcastc.h"
#include "spbcdecode.h"
}

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using Clock = std::chrono::steady_clock;

static void check(astcenc_error status) {
    if (status != ASTCENC_SUCCESS) {
        std::fprintf(stderr, "%s\n", astcenc_get_error_string(status));
        std::exit(1);
    }
}

static void report(const char *name, double seconds, unsigned repeats,
                   const std::vector<uint8_t>& reference, const std::vector<uint8_t>& image) {
    uint64_t rgb = 0, alpha = 0, visible = 0, visibleSamples = 0;
    int maxRGB = 0, maxAlpha = 0, maxVisible = 0;
    for (size_t i = 0; i < image.size(); i++) {
        int error = std::abs(int(image[i]) - int(reference[i]));
        if (i % 4 == 3) {
            alpha += error * error;
            maxAlpha = std::max(maxAlpha, error);
        } else {
            rgb += error * error;
            maxRGB = std::max(maxRGB, error);
            if (reference[i | 3]) {
                visible += error * error;
                maxVisible = std::max(maxVisible, error);
                visibleSamples++;
            }
        }
    }
    double pixels = image.size() / 4;
    auto psnr = [](double sum, double n) { return 10 * std::log10(255.0 * 255 * n / sum); };
    std::printf("%-18s %8.2f ms %8.2f MPix/s  RGB %.2f/%d  alpha %.2f/%d  visible %.2f/%d\n",
                name, seconds * 1000 / repeats, repeats * pixels / (seconds * 1e6),
                psnr(rgb, pixels * 3), maxRGB, psnr(alpha, pixels), maxAlpha,
                psnr(visible, visibleSamples), maxVisible);
}

static void benchmark(SPBCKind kind, bool punch) {
    constexpr unsigned side = 1024;
    constexpr size_t pixels = side * side;
    size_t blockBytes = SPBCBlockBytes(kind);
    std::vector<uint8_t> blocks(pixels / 16 * blockBytes), packed(pixels), reference(pixels * 4), decoded(pixels * 4);
    uint32_t seed = 0x18092001;
    for (auto& b : blocks) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        b = static_cast<uint8_t>(seed);
    }
    if (kind == SPBC1) {
        for (size_t i = 0; i < blocks.size(); i += 8) {
            unsigned c0 = blocks[i] | unsigned(blocks[i + 1]) << 8;
            unsigned c1 = blocks[i + 2] | unsigned(blocks[i + 3]) << 8;
            if ((c0 > c1) == punch) {
                std::swap(blocks[i], blocks[i + 2]);
                std::swap(blocks[i + 1], blocks[i + 3]);
            }
            if (c0 == c1 && !punch) {
                blocks[i] = blocks[i + 1] = 255;
                blocks[i + 2] = blocks[i + 3] = 0;
            }
            if (punch) blocks[i + 4] |= 3; // at least one transparent texel per block
        }
    }
    std::printf("BC%d%s\n", int(kind), kind == SPBC1 ? (punch ? " alpha" : " opaque") : "");
    auto start = Clock::now();
    bool ok = SPBCDecodeRect(kind, blocks.data(), side / 4 * blockBytes, side, side, reference.data(), side * 4);
    double decodeSeconds = std::chrono::duration<double>(Clock::now() - start).count();
    if (!ok) std::abort();
    void *inputSlice = reference.data(), *outputSlice = decoded.data();
    astcenc_image input = {side, side, 1, ASTCENC_TYPE_U8, &inputSlice};
    astcenc_image output = {side, side, 1, ASTCENC_TYPE_U8, &outputSlice};
    astcenc_swizzle channels = {ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A};
    if (kind == SPBC1) {
        constexpr unsigned repeats = 64;
        start = Clock::now();
        for (unsigned n = 0; n < repeats; n++)
            if (!SPBC1RectToASTC(blocks.data(), side / 4 * 8, side, side, packed.data(), side / 4 * 16))
                std::abort();
        double elapsed = std::chrono::duration<double>(Clock::now() - start).count();
        for (auto profile : {ASTCENC_PRF_LDR, ASTCENC_PRF_LDR_SRGB}) {
            astcenc_config config;
            astcenc_context *ctx;
            check(astcenc_config_init(profile, 4, 4, 1, ASTCENC_PRE_FASTEST,
                                      ASTCENC_FLG_DECOMPRESS_ONLY | ASTCENC_FLG_USE_DECODE_UNORM8, &config));
            check(astcenc_context_alloc(&config, 1, &ctx));
            for (size_t b = 0; b < packed.size(); b += 16) {
                astcenc_block_info info;
                check(astcenc_get_block_info(ctx, packed.data() + b, &info));
                assert(!info.is_error_block);
            }
            check(astcenc_decompress_image(ctx, packed.data(), packed.size(), &output, &channels, 0));
            for (size_t i = 3; i < decoded.size(); i += 4) assert(decoded[i] == reference[i]);
            report(profile == ASTCENC_PRF_LDR ? "direct linear" : "direct sRGB", elapsed, repeats, reference, decoded);
            astcenc_context_free(ctx);
        }
    }
    for (float preset : {ASTCENC_PRE_FASTEST, ASTCENC_PRE_FAST}) {
        astcenc_config config;
        astcenc_context *ctx;
        check(astcenc_config_init(ASTCENC_PRF_LDR, 4, 4, 1, preset, ASTCENC_FLG_USE_DECODE_UNORM8, &config));
        check(astcenc_context_alloc(&config, 1, &ctx));
        start = Clock::now();
        check(astcenc_compress_image(ctx, &input, &channels, packed.data(), packed.size(), 0));
        double elapsed = std::chrono::duration<double>(Clock::now() - start).count() + decodeSeconds;
        check(astcenc_decompress_image(ctx, packed.data(), packed.size(), &output, &channels, 0));
        report(preset == ASTCENC_PRE_FASTEST ? "astcenc -fastest" : "astcenc -fast", elapsed, 1, reference, decoded);
        astcenc_context_free(ctx);
    }
}

int main() {
    std::puts("1024x1024 synthetic images, 1 thread. Quality is PSNR dB / max byte error.");
    benchmark(SPBC1, false);
    benchmark(SPBC1, true);
    benchmark(SPBC2, false);
    benchmark(SPBC3, false);
}
