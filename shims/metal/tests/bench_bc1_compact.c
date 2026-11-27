#define _POSIX_C_SOURCE 200809L
#include "spbcastc.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double seconds(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static void bench(bool punchThrough, uint8_t *source, uint8_t *target) {
    enum { Edge = 1024, Blocks = Edge * Edge / 16, Iterations = 24 };
    uint32_t state = 42;
    for (size_t i = 0; i < Blocks; i++) {
        uint8_t *block = source + i * 8;
        block[0] = (uint8_t)i;
        block[1] = punchThrough ? 0x20 : 0xc0;
        block[2] = (uint8_t)(i >> 8);
        block[3] = punchThrough ? 0xc0 : 0x20;
        state = state * UINT32_C(1664525) + UINT32_C(1013904223);
        for (unsigned j = 0; j < 4; j++) block[4 + j] = (uint8_t)(state >> (8 * j));
        if (punchThrough) block[4] |= 3;
    }
    double start = seconds();
    for (unsigned i = 0; i < Iterations; i++) {
        size_t punch;
        assert(SPBC1RectToASTCCounted(source, Edge / 4 * 8, Edge, Edge, target, Edge / 4 * 16, &punch));
        assert(punch == (punchThrough ? Blocks : 0));
    }
    double elapsed = seconds() - start;
    printf("BC1 compact %-13s %.1f MPix/s (%.2f ms per 1024²)\n",
           punchThrough ? "punch-through" : "opaque",
           (double)Edge * Edge * Iterations / (elapsed * 1e6), elapsed * 1000 / Iterations);
}

int main(void) {
    uint8_t *source = malloc(512 * 1024), *target = malloc(1024 * 1024);
    assert(source && target);
    bench(false, source, target);
    bench(true, source, target);
    free(target);
    free(source);
}
