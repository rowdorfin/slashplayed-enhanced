#include "spmemorymeter.h"

#include <assert.h>
#include <stdio.h>

static SPMemoryHistogram histogram;

int main(void) {
    const uint64_t gib = UINT64_C(1) << 30;
    assert(SPMemoryWorkingSet(4 * gib, 0) == 4 * gib);
    assert(SPMemoryWorkingSet(4 * gib, 2 * gib) == 2 * gib);
    assert(SPMemoryWorkingSet(4 * gib, 3 * gib / 2) == 3 * gib / 2);
    assert(SPMemoryWorkingSet(4 * gib, gib) == gib);
    assert(SPMemoryWorkingSet(gib, 2 * gib) == gib);
    assert(SPMemoryWorkingSet(0, gib) == 0);

    SPVMTagPages tags[SPVMTagSlots] = {0};
    SPVMTagSample top[SPVMTagTopCount];
    assert(SPVMTagTop(tags, top) == 0);
    for (unsigned tag = 1; tag <= 9; tag++) SPVMTagAdd(tags, tag, 0, 1, 0);
    SPVMTagAdd(tags, 2, 1, 2, 3);
    SPVMTagAdd(tags, 0, 1, 3, 0);
    SPVMTagAdd(tags, SPVMTagSlots, 0, 0, 2);
    SPVMTagAdd(tags, UINT32_MAX, 0, 0, 1);
    assert(tags[SPVMTagLedger].swapped == 1);
    assert(SPVMTagTop(tags, top) == SPVMTagTopCount);
    assert(top[0].tag == 2 && top[0].pages.dirty == 3 && top[0].pages.swapped == 3);
    assert(top[1].tag == SPVMTagMappedFile && SPVMTagTotal(top[1].pages) == 3);
    assert(top[2].tag == 0 && SPVMTagTotal(top[2].pages) == 2);
    assert(top[3].tag == 1 && top[4].tag == 3 && top[7].tag == 6);

    const unsigned edges[] = {128, 256, 512, 1024, 2048};
    for (unsigned i = 0; i < sizeof edges / sizeof *edges; i++) {
        assert(SPMemoryEdgeClass(edges[i]) == edges[i]);
        assert(SPMemoryEdgeClass(edges[i] + 1) == 2 * edges[i]);
    }
    assert(SPMemoryEdgeClass(8192) == 4096);
    assert(SPMemoryMipClass(1, 1) == 1);
    assert(SPMemoryMipClass(129, 1) == 1);
    assert(SPMemoryMipClass(129, 7) == 2);
    assert(SPMemoryMipClass(129, 8) == 3);
    assert(SPMemoryMipClass(4096, 13) == 3);

    SPMemoryClass c = {512, 3, 72, 0x15, 2, 153};
    uint64_t key = SPMemoryKey(c);
    SPMemoryClass decoded = SPMemoryClassOf(key);
    assert(decoded.width == c.width && decoded.height == c.height && decoded.format == c.format);
    assert(decoded.usage == c.usage && decoded.storage == c.storage && decoded.original == c.original);
    SPMemoryBin *bin = SPMemoryFind(&histogram, key);
    assert(bin != &histogram.overflow && bin == SPMemoryFind(&histogram, key));
    c.usage++;
    assert(SPMemoryFind(&histogram, SPMemoryKey(c)) != bin);
    c = (SPMemoryClass){4096, 4096, 252, 5, 2, 0};
    decoded = SPMemoryClassOf(SPMemoryKey(c));
    assert(decoded.width == 4096 && decoded.height == 4096 && decoded.format == 252);
    assert(SPMemoryFind(&histogram, SPMemoryKey(c)) != bin);
    c.width = 32768;
    assert(SPMemoryFind(&histogram, SPMemoryKey(c)) == &histogram.overflow);

    SPMemoryCreate(bin, 128, 4096);
    SPMemoryCreate(bin, 256, 8192);
    SPMemoryFree(bin, 128, 4096);
    SPMemorySample sample = SPMemoryRead(bin);
    assert(sample.created == 2 && sample.freed == 1 && sample.live == 1);
    assert(sample.logical == 256 && sample.allocated == 8192);
    SPMemoryFree(bin, 256, 8192);
    sample = SPMemoryRead(bin);
    assert(sample.freed == 2 && !sample.live && !sample.logical && !sample.allocated);

    for (unsigned i = 0; i < SPMemoryCapacity; i++) atomic_store(&histogram.bins[i].key, key);
    assert(SPMemoryFind(&histogram, key + 1) == &histogram.overflow);
    SPMemoryCreate(&histogram.overflow, 1, 4096);
    assert(SPMemoryRead(&histogram.overflow).allocated == 4096);
    SPMemoryFree(&histogram.overflow, 1, 4096);
    puts("memory histogram and accounting checks passed");
}
