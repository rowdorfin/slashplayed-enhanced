// Synthetic single-thread decode throughput. Build with -O3.
#define _POSIX_C_SOURCE 200809L
#include "spbcdecode.h"

#include <stdio.h>
#include <time.h>

enum { Side = 1024, Repeats = 160 };
static uint8_t source[Side * Side], decoded[Side * Side * 8];

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
    const SPBCKind kinds[] = {SPBC1, SPBC2, SPBC3, SPBC4, SPBC4S, SPBC5, SPBC5S, SPBC6H, SPBC6HS, SPBC7};
    const char *names[] = {"1", "2", "3", "4", "4S", "5", "5S", "6H", "6HS", "7"};
    for (size_t i = 0; i < sizeof kinds / sizeof *kinds; i++) {
        SPBCKind kind = kinds[i];
        size_t row = Side * SPBCTexelBytes(kind);
        unsigned checksum = 0;
        double start = seconds();
        for (unsigned n = 0; n < Repeats; n++) {
            if (!SPBCDecodeRect(kind, source, Side / 4 * SPBCBlockBytes(kind), Side, Side, decoded, row))
                return 1;
            checksum += decoded[n * 1337];
        }
        double elapsed = seconds() - start;
        printf("BC%s %.1f MPix/s checksum=%u\n", names[i], Repeats * (Side * Side / 1e6) / elapsed, checksum);
    }
}
