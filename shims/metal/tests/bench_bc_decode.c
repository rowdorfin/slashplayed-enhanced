// Synthetic single-thread decode throughput. Build with -O3.
#define _POSIX_C_SOURCE 200809L
#include "spbcdecode.h"

#include <stdio.h>
#include <time.h>

enum { Side = 1024, Repeats = 160 };
static uint8_t source[Side * Side], rgba[Side * Side * 4];

static double seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(void) {
    uint32_t state = UINT32_C(0x19081823);
    for (size_t i = 0; i < sizeof source; i++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        source[i] = (uint8_t)state;
    }
    const SPBCKind kinds[] = {SPBC1, SPBC2, SPBC3, SPBC7};
    const unsigned numbers[] = {1, 2, 3, 7};
    for (size_t i = 0; i < sizeof kinds / sizeof *kinds; i++) {
        SPBCKind kind = kinds[i];
        unsigned checksum = 0;
        double start = seconds();
        for (unsigned n = 0; n < Repeats; n++) {
            if (!SPBCDecodeRect(kind, source, Side / 4 * SPBCBlockBytes(kind), Side, Side, rgba, Side * 4))
                return 1;
            checksum += rgba[n * 1337];
        }
        double elapsed = seconds() - start;
        printf("BC%u %.1f MPix/s checksum=%u\n", numbers[i], Repeats * (Side * Side / 1e6) / elapsed, checksum);
    }
}
