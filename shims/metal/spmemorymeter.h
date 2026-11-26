#pragma once

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    unsigned width, height, format, usage, storage, original;
} SPMemoryClass;

static inline unsigned SPMemoryEdgeClass(size_t edge) {
    if (edge <= 128) return 128;
    if (edge <= 256) return 256;
    if (edge <= 512) return 512;
    if (edge <= 1024) return 1024;
    return edge <= 2048 ? 2048 : 4096;
}

static inline unsigned SPMemoryMipClass(size_t edge, size_t levels) {
    if (levels <= 1) return 1;
    unsigned fullLevels = 1;
    while (edge >>= 1) fullLevels++;
    return levels == fullLevels ? 3 : 2;
}

// Width and height are exact for render targets, and encode edge and mip
// classes for converted BC roots. Zero is reserved for the overflow row.
static inline uint64_t SPMemoryKey(SPMemoryClass c) {
    if (c.width >= 32768 || c.height >= 32768 || c.format >= 2048 ||
        c.usage >= 4096 || c.storage >= 4 || c.original >= 256) return 0;
    return (uint64_t)c.width | (uint64_t)c.height << 15 | (uint64_t)c.format << 30 |
           (uint64_t)c.usage << 41 | (uint64_t)c.storage << 53 | (uint64_t)c.original << 55;
}

static inline SPMemoryClass SPMemoryClassOf(uint64_t key) {
    return (SPMemoryClass){key & 32767, key >> 15 & 32767, key >> 30 & 2047,
                           key >> 41 & 4095, key >> 53 & 3, key >> 55 & 255};
}

typedef struct {
    _Atomic uint64_t key;
    atomic_ullong created, freed, logical, allocated;
} SPMemoryBin;

enum { SPMemoryCapacity = 4096, SPMemoryProbeLimit = 32 };
typedef struct {
    SPMemoryBin bins[SPMemoryCapacity], overflow;
} SPMemoryHistogram;

typedef struct {
    unsigned long long created, freed, live, logical, allocated;
} SPMemorySample;

static inline SPMemoryBin *SPMemoryFind(SPMemoryHistogram *histogram, uint64_t key) {
    if (!key) return &histogram->overflow;
    uint64_t hash = key;
    hash ^= hash >> 30;
    hash *= UINT64_C(0xbf58476d1ce4e5b9);
    hash ^= hash >> 27;
    hash *= UINT64_C(0x94d049bb133111eb);
    hash ^= hash >> 31;
    for (unsigned i = 0; i < SPMemoryProbeLimit; i++) {
        SPMemoryBin *bin = &histogram->bins[(hash + i) % SPMemoryCapacity];
        uint64_t found = atomic_load_explicit(&bin->key, memory_order_relaxed);
        if (found == key) return bin;
        if (!found && (atomic_compare_exchange_strong_explicit(&bin->key, &found, key,
                                                               memory_order_relaxed, memory_order_relaxed) ||
                       found == key)) return bin;
    }
    return &histogram->overflow;
}

static inline void SPMemoryCreate(SPMemoryBin *bin, size_t logical, size_t allocated) {
    atomic_fetch_add_explicit(&bin->logical, logical, memory_order_relaxed);
    atomic_fetch_add_explicit(&bin->allocated, allocated, memory_order_relaxed);
    atomic_fetch_add_explicit(&bin->created, 1, memory_order_release);
}

static inline void SPMemoryFree(SPMemoryBin *bin, size_t logical, size_t allocated) {
    atomic_fetch_sub_explicit(&bin->logical, logical, memory_order_relaxed);
    atomic_fetch_sub_explicit(&bin->allocated, allocated, memory_order_relaxed);
    atomic_fetch_add_explicit(&bin->freed, 1, memory_order_release);
}

static inline SPMemorySample SPMemoryRead(const SPMemoryBin *bin) {
    // The counters are sampled independently. Load frees first so that the
    // acquire also sees the creations preceding those frees.
    unsigned long long freed = atomic_load_explicit(&bin->freed, memory_order_acquire);
    unsigned long long created = atomic_load_explicit(&bin->created, memory_order_acquire);
    return (SPMemorySample){created, freed, created - freed,
                            atomic_load_explicit(&bin->logical, memory_order_relaxed),
                            atomic_load_explicit(&bin->allocated, memory_order_relaxed)};
}
