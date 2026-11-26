#include "spmemorymeter.h"

#include <assert.h>
#include <stdio.h>

static SPMemoryHistogram histogram;

int main(void) {
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
