#pragma once
#include <stdint.h>
#include <string.h>

enum { SPGPURangeCapacity = 8192, SPFrameOverflow = 251 };
typedef struct { uint64_t start, end; } SPGPURange;
typedef struct {
    SPGPURange ranges[SPGPURangeCapacity];
    unsigned count;
    uint64_t busy, evicted, sealedThrough;
} SPGPUUnion;

// Keep sorted disjoint ranges. Ordered, nonoverlapping arrivals append
// in constant time. An enclosing or late arrival can fill earlier holes.
static inline void SPGPUAdd(SPGPUUnion *u, uint64_t start, uint64_t end) {
    // The frozen prefix remains in busy. Ignore late coverage there,
    // since its holes are no longer distinguishable from occupied time.
    if (start < u->sealedThrough) start = u->sealedThrough;
    if (end <= start) return;
    unsigned first = u->count;
    while (first && u->ranges[first - 1].end >= start) first--;
    unsigned last = first;
    while (last < u->count && u->ranges[last].start <= end) {
        SPGPURange range = u->ranges[last++];
        if (range.start < start) start = range.start;
        if (range.end > end) end = range.end;
        u->busy -= range.end - range.start;
    }
    if (first == last && u->count == SPGPURangeCapacity) {
        unsigned evict = SPGPURangeCapacity / 2;
        u->sealedThrough = u->ranges[evict - 1].end;
        memmove(u->ranges, u->ranges + evict, (u->count - evict) * sizeof(*u->ranges));
        u->count -= evict;
        u->evicted += evict;
        if (first < evict) {
            // This disjoint interval is already inside the frozen prefix.
            u->busy += end - start;
            u->evicted++;
            return;
        }
        first -= evict;
        last -= evict;
    }
    if (last < u->count && first + 1 != last)
        memmove(u->ranges + first + 1, u->ranges + last, (u->count - last) * sizeof(*u->ranges));
    u->ranges[first] = (SPGPURange){start, end};
    u->count += first + 1 - last;
    u->busy += end - start;
}

typedef struct {
    uint64_t count, over33, over50, worst;
    uint64_t buckets[SPFrameOverflow + 1];
} SPFrameHistogram;

static inline void SPFrameAdd(SPFrameHistogram *h, uint64_t ns) {
    uint64_t ms = ns / 1000000 + (ns % 1000000 != 0);
    h->buckets[ms < SPFrameOverflow ? ms : SPFrameOverflow]++;
    h->count++;
    h->over33 += ns > 33000000;
    h->over50 += ns > 50000000;
    if (ns > h->worst) h->worst = ns;
}

// Nearest rank, returning the bucket's upper bound (251 denotes >250 ms).
static inline unsigned SPFramePercentile(const SPFrameHistogram *h, unsigned percentile) {
    uint64_t rank = (h->count * percentile + 99) / 100;
    if (!rank) return 0;
    for (unsigned i = 0; i <= SPFrameOverflow; i++) {
        if (rank <= h->buckets[i]) return i;
        rank -= h->buckets[i];
    }
    return SPFrameOverflow;
}

// A process-wide token shared by the Metal and AppKit dylibs.
#define SP_BC_UPLOAD_CB_KEY "sp_bcFallbackUploadCommandBuffer"
