#include "spmetalmeter.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    SPGPUUnion u = {0};
    SPGPUAdd(&u, 10, 20);
    SPGPUAdd(&u, 30, 40);
    SPGPUAdd(&u, 15, 50);
    assert(u.count == 1 && u.busy == 40);
    SPGPUAdd(&u, 51, 55);
    SPGPUAdd(&u, 5, 7);
    SPGPUAdd(&u, 8, 9);
    SPGPUAdd(&u, 10, 45);
    SPGPUAdd(&u, 70, 50);
    assert(u.count == 4 && u.busy == 47);
    SPGPUAdd(&u, 7, 51);
    assert(u.count == 1 && u.busy == 50);
    u = (SPGPUUnion){0};
    for (unsigned i = 0; i < 40000; i++) SPGPUAdd(&u, 2 * i, 2 * i + 1);
    assert(u.busy == 40000 && u.evicted > 0 && u.count + u.evicted == 40000);

    u = (SPGPUUnion){0};
    for (unsigned i = 0; i <= SPGPURangeCapacity; i++) SPGPUAdd(&u, 2 * i, 2 * i + 1);
    const unsigned half = SPGPURangeCapacity / 2;
    assert(u.evicted == half && u.sealedThrough == 2 * half - 1);
    SPGPUAdd(&u, 0, 2 * half - 1);  // entirely sealed
    assert(u.busy == SPGPURangeCapacity + 1);
    SPGPUAdd(&u, 2 * half - 4, 2 * half + 3);  // crosses the frontier, fills two gaps
    assert(u.busy == SPGPURangeCapacity + 3);
    SPGPUAdd(&u, 2 * half + 3, 2 * half + 4);  // fills a retained gap
    assert(u.busy == SPGPURangeCapacity + 4);

    u = (SPGPUUnion){0};
    for (unsigned i = 0; i < SPGPURangeCapacity; i++) SPGPUAdd(&u, 4 * i, 4 * i + 1);
    SPGPUAdd(&u, 2, 3);  // disjoint late interval triggers consolidation
    assert(u.busy == SPGPURangeCapacity + 1 && u.evicted == half + 1);

    // Cross-check arbitrary callback ordering against a per-tick oracle.
    uint32_t seed = 157;
    for (unsigned n = 0; n < 40; n++) {
        unsigned char occupied[128] = {0};
        u.count = u.busy = u.evicted = u.sealedThrough = 0;
        for (unsigned i = 0; i < 60; i++) {
            seed = 1664525u * seed + 1013904223u;
            unsigned start = seed >> 25;
            unsigned end = start + (seed >> 16 & 7);
            if (end > sizeof occupied) end = sizeof occupied;
            SPGPUAdd(&u, start, end);
            for (unsigned j = start; j < end; j++) occupied[j] = 1;
            unsigned expected = 0;
            for (unsigned j = 0; j < sizeof occupied; j++) expected += occupied[j];
            assert(u.busy == expected);
        }
    }

    SPFrameHistogram h = {0};
    assert(SPFramePercentile(&h, 99) == 0);
    for (unsigned i = 0; i < 50; i++) SPFrameAdd(&h, 1000000);
    for (unsigned i = 0; i < 44; i++) SPFrameAdd(&h, 33000000);
    SPFrameAdd(&h, 33000001);
    SPFrameAdd(&h, 50000000);
    SPFrameAdd(&h, 50000001);
    SPFrameAdd(&h, 250000000);
    SPFrameAdd(&h, 250000001);
    SPFrameAdd(&h, 813000000);
    assert(h.count == 100 && h.over33 == 6 && h.over50 == 4 && h.worst == 813000000);
    assert(SPFramePercentile(&h, 50) == 1);
    assert(SPFramePercentile(&h, 95) == 34);
    assert(SPFramePercentile(&h, 98) == 250);
    assert(SPFramePercentile(&h, 99) == SPFrameOverflow);
    puts("Metal metering: union, late/nested intervals, 40000 disjoint ranges, eviction and frame percentiles: PASS");
}
