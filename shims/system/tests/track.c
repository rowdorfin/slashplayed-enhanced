#define _GNU_SOURCE
#include "../spalloctrack.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static struct sp_alloc_tracker tracker;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool done;

static void replace(uintptr_t old, uintptr_t new, size_t n, bool succeeded) {
    uintptr_t pc[SP_ALLOC_FRAMES] = {2, 3};
    struct sp_alloc_block b = sp_alloc_realloc_begin(&tracker, old);
    sp_alloc_realloc_end(&tracker, b, succeeded, 5);
    if (!succeeded) return;
    if (n >= 262144) sp_alloc_add(&tracker, new, n, n, SP_HEAP, pc, 6, 5, b.size, old != 0);
}

static void stack_cases(void) {
    _Static_assert(SP_ALLOC_FRAMES == 12, "capture twelve frames");
    uintptr_t first[SP_ALLOC_FRAMES] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    uintptr_t second[SP_ALLOC_FRAMES];
    memcpy(second, first, sizeof second);
    second[11] = 13;
    assert(sp_alloc_stack_hash(first, 4) == UINT64_C(0xb33d5ccef66d2093));
    assert(sp_alloc_stack_hash(first, 4) == sp_alloc_stack_hash(second, 4));
    assert(sp_alloc_stack_hash(first, 5) == sp_alloc_stack_hash(second, 5));
    assert(sp_alloc_stack_hash(first, SP_ALLOC_FRAMES) != sp_alloc_stack_hash(second, SP_ALLOC_FRAMES));
    sp_alloc_add(&tracker, 1, 1, 1, SP_HEAP, first, 1, 0, 0, false);
    sp_alloc_add(&tracker, 2, 1, 1, SP_HEAP, second, 1, 0, 0, false);
    struct sp_alloc_block a = sp_alloc_find(&tracker, 1), b = sp_alloc_find(&tracker, 2);
    assert(a.site != b.site && tracker.sites[a.site].pc[11] == 12 && tracker.sites[b.site].pc[11] == 13);
    sp_alloc_remove(&tracker, a, 0, false);
    sp_alloc_remove(&tracker, b, 0, false);
}

static void vmstat_cases(void) {
    struct sp_mem_vm_rate rate = {0};
    assert(!sp_mem_vm_due(&rate, 0, false));
    assert(sp_mem_vm_due(&rate, 0, true));
    assert(!sp_mem_vm_due(&rate, 0, true));
    assert(!sp_mem_vm_due(&rate, 999999999, true));
    assert(!sp_mem_vm_due(&rate, 1000000000, false));
    assert(sp_mem_vm_due(&rate, 1000000000, true));
    assert(!sp_mem_vm_due(&rate, 1999999999, true));
    assert(rate.calls == 7);

    struct sp_mem_vm_sample sample = {
        .calls = rate.calls, .words = 38, .page_size = 16384, .free = 1, .active = 2,
        .inactive = 3, .speculative = 4, .wired = 5, .purgeable = 6, .compressor = 7,
        .external = 8, .internal = 9, .available = 10, .guest_offset = 0xabc,
        .has_external = true, .has_internal = true, .has_available = true, .guest = true
    };
    char line[SP_MEM_VM_LINE];
    assert(sp_mem_vm_format(line, &sample) == strlen("SP_MEM_VMSTAT calls=7 words=38 pageSize=16384 "
           "free=1 active=2 inactive=3 speculative=4 wired=5 purgeable=6 compressor=7 external=8 internal=9 "
           "available=10 caller=guest+0xabc\n"));
    assert(!strcmp(line, "SP_MEM_VMSTAT calls=7 words=38 pageSize=16384 "
           "free=1 active=2 inactive=3 speculative=4 wired=5 purgeable=6 compressor=7 external=8 internal=9 "
           "available=10 caller=guest+0xabc\n"));

    sample.has_internal = sample.has_available = sample.guest = false;
    sp_mem_vm_format(line, &sample);
    assert(strstr(line, " external=8 available=n/a caller=outside_guest\n"));
    sample.has_external = false;
    sp_mem_vm_format(line, &sample);
    assert(strstr(line, " compressor=7 available=n/a caller=outside_guest\n"));
    sample = (struct sp_mem_vm_sample){
        .calls = UINT64_MAX, .page_size = UINT64_MAX, .available = UINT64_MAX, .guest_offset = UINT64_MAX,
        .words = UINT32_MAX, .free = UINT32_MAX, .active = UINT32_MAX, .inactive = UINT32_MAX,
        .speculative = UINT32_MAX, .wired = UINT32_MAX, .purgeable = UINT32_MAX, .compressor = UINT32_MAX,
        .external = UINT32_MAX, .internal = UINT32_MAX,
        .has_external = true, .has_internal = true, .has_available = true, .guest = true
    };
    size_t length = sp_mem_vm_format(line, &sample);
    assert(length < sizeof line && strlen(line) == length && strchr(line, '\n') == line + length - 1);
    assert(strstr(line, " caller=guest+0x" "ffffffffffffffff\n"));
}

static void site5_cases(void) {
    static struct sp_alloc_site snapshot[SP_ALLOC_SITES];
    static struct sp_alloc_site5_scratch scratch;
    struct sp_alloc_site5 groups[SP_ALLOC_SITE5_TOP];
    // Eighteen live sub-sites fall below the full-stack top 16. One more
    // sub-site has been freed and still contributes to the cumulative sums.
    for (unsigned i = 0; i < 19; i++)
        snapshot[i] = (struct sp_alloc_site){.pc = {0, 0, 0, 0, 0, i + 1},
            .live = i < 18 ? 10 : 0, .blocks = i < 18, .total = 20, .allocs = 2,
            .frees = i < 18 ? 1 : 2};
    for (unsigned i = 19; i < 35; i++)
        snapshot[i] = (struct sp_alloc_site){.pc = {i}, .live = i, .blocks = 1, .total = i, .allocs = 1};
    unsigned top[16], growth[8];
    sp_alloc_rank(snapshot, SP_ALLOC_SITES, top, growth);
    for (unsigned i = 0; i < 16; i++) assert(top[i] >= 19 && top[i] < 35);
    sp_alloc_rank_site5(snapshot, &scratch, groups);
    const struct sp_alloc_site5 *family = &groups[0];
    assert(family->hash == 0 && family->sub_sites == 19 && family->live == 180 && family->blocks == 18);
    assert(family->total == 380 && family->allocs == 38 && family->frees == 20);
    for (unsigned i = 1; i < SP_ALLOC_SITE5_TOP; i++)
        assert(groups[i].sub_sites == 1 && groups[i].live == 35 - i);

    memset(snapshot, 0, sizeof snapshot);
    sp_alloc_rank_site5(snapshot, &scratch, groups);
    for (unsigned i = 0; i < SP_ALLOC_SITE5_TOP; i++) assert(!groups[i].sub_sites);
}

static void site_capacity_cases(void) {
    for (unsigned i = 1; i <= SP_ALLOC_SITES; i++) {
        uintptr_t pc[SP_ALLOC_FRAMES] = {i};
        sp_alloc_add(&tracker, i, 1, 1, SP_HEAP, pc, 1, 0, 0, false);
    }
    assert(tracker.used == SP_ALLOC_SITES && tracker.live == SP_ALLOC_SITES && !tracker.dropped);
    // Freeing a block doesn't reclaim the historical site or its counters.
    sp_alloc_remove(&tracker, sp_alloc_find(&tracker, 1), 1, false);
    uintptr_t unseen[SP_ALLOC_FRAMES] = {SP_ALLOC_SITES + 1};
    sp_alloc_add(&tracker, 1, 1, 1, SP_HEAP, unseen, 1, 1, 0, false);
    assert(tracker.dropped == 1 && tracker.live == SP_ALLOC_SITES - 1);
    assert(!sp_alloc_find(&tracker, 1).generation);
    uintptr_t known[SP_ALLOC_FRAMES] = {1};
    sp_alloc_add(&tracker, 1, 1, 1, SP_HEAP, known, 1, 1, 0, false);
    assert(tracker.dropped == 1 && tracker.live == SP_ALLOC_SITES);
    assert(sp_alloc_find(&tracker, 1).generation);
    memset(&tracker, 0, sizeof tracker);
}

static void cases(void) {
    uintptr_t pc[SP_ALLOC_FRAMES] = {1, 4};
    sp_alloc_add(&tracker, 4096, 262144, 262160, SP_HEAP, pc, 3, 1, 0, false);
    struct sp_alloc_block b = sp_alloc_find(&tracker, 4096);
    assert(b.usable == 262160);
    struct sp_alloc_block busy = sp_alloc_realloc_begin(&tracker, 4096);
    sp_alloc_remove(&tracker, b, 4, true);
    assert(busy.resizing && tracker.live == 262144 && !tracker.phantom);
    sp_alloc_realloc_end(&tracker, busy, false, 4);
    assert(!sp_alloc_find(&tracker, 4096).resizing);
    replace(4096, 0, 524288, false);
    assert(sp_alloc_find(&tracker, 4096).generation == b.generation);
    replace(4096, 8192, 524288, true);
    assert(!sp_alloc_find(&tracker, 4096).generation && tracker.live == 524288);
    assert(tracker.sites[b.site].lifetime == 4);
    b = sp_alloc_find(&tracker, 8192);
    assert(tracker.sites[b.site].growth == 262144 && tracker.sites[b.site].grows == 1);
    replace(8192, 8192, 786432, true);
    sp_alloc_remove(&tracker, b, 6, true);
    assert(tracker.phantom == 0 && tracker.live == 786432);
    sp_alloc_remove(&tracker, sp_alloc_find(&tracker, 8192), 6, true);
    assert(tracker.phantom == 1 && tracker.live == 0);
    replace(16384, 16384, 262144, true);
    assert(tracker.live == 262144);
    replace(16384, 16384, 64, true);
    assert(tracker.live == 0);
    sp_alloc_add(&tracker, 0x100000, 262144, 0, SP_VM, pc, 3, 1, 0, false);
    sp_alloc_unmap(&tracker, 0x101000, 4096, 7, tracker.generation);
    assert(tracker.live == 0 && tracker.dropped == 1);
    sp_alloc_add(&tracker, 0x100000, 262144, 0, SP_VM, pc, 3, 1, 0, false);
    sp_alloc_unmap(&tracker, 0x100000, 262144, 7, tracker.generation);
    assert(tracker.live == 0 && tracker.dropped == 1);
    uint64_t before = tracker.generation;
    sp_alloc_add(&tracker, 0x100000, 262144, 0, SP_VM, pc, 3, 1, 0, false);
    sp_alloc_unmap(&tracker, 0x100000, 262144, 7, before);
    assert(tracker.vm_live == 262144);
    sp_alloc_unmap(&tracker, 0x100000, 262144, 7, tracker.generation);
    assert(tracker.vm_live == 0);
    assert(!sp_alloc_rate(10, 138, 1000000000, 128));
    assert(sp_alloc_rate(10, 139, 1000000000, 128));
    assert(!sp_alloc_rate(139, 10, 1000000000, 128));
    assert(!sp_alloc_rate(10, 139, 1100000000, 128));
    for (unsigned i = 1; i <= SP_ALLOC_BLOCKS; i++)
        sp_alloc_add(&tracker, i * 4096UL, 1, 1, SP_HEAP, pc, 2, 9, 0, false);
    uint64_t full = tracker.live, dropped = tracker.dropped;
    assert(full && full + dropped == SP_ALLOC_BLOCKS + 1);
    sp_alloc_add(&tracker, (SP_ALLOC_BLOCKS + 1UL) * 4096, 1, 1, SP_HEAP, pc, 2, 9, 0, false);
    assert(tracker.live == full && tracker.dropped == dropped + 1);
    for (unsigned i = 1; i <= SP_ALLOC_BLOCKS; i++)
        sp_alloc_remove(&tracker, sp_alloc_find(&tracker, i * 4096UL), 10, false);
    assert(!tracker.live);

    struct sp_alloc_site sites[4] = {{.live = 5, .previous = 1}, {.live = 9, .previous = 10},
                                     {.live = 4}, {.live = 8, .previous = 1}};
    unsigned top[16], growth[8];
    sp_alloc_rank(sites, 4, top, growth);
    assert(top[0] == 1 && top[1] == 3 && top[2] == 0 && top[3] == 2 && top[4] == SP_ALLOC_SITES);
    assert(growth[0] == 3 && growth[1] == 0 && growth[2] == 2 && growth[3] == SP_ALLOC_SITES);
}

static void *worker(void *arg) {
    uintptr_t id = (uintptr_t)arg, pc[SP_ALLOC_FRAMES] = {id + 8, 9};
    for (unsigned i = 0; i < 500; i++) {
        size_t n = 262144 + 4096 * (i % 8);
        void *small = malloc(64), *large = malloc(n);
        assert(small && large);
        uintptr_t key = (uintptr_t)large;
        pthread_mutex_lock(&lock);
        sp_alloc_add(&tracker, key, n, n, SP_HEAP, pc, id, i, 0, false);
        struct sp_alloc_block b = sp_alloc_realloc_begin(&tracker, key);
        pthread_mutex_unlock(&lock);
        large = realloc(large, n * 2);
        assert(large);
        pthread_mutex_lock(&lock);
        sp_alloc_realloc_end(&tracker, b, true, i + 1);
        sp_alloc_add(&tracker, (uintptr_t)large, n * 2, n * 2, SP_HEAP, pc, id, i + 1, n, true);
        pthread_mutex_unlock(&lock);
        *(volatile char *)small = 42;
        *(volatile char *)large = 11;
        pthread_mutex_lock(&lock);
        sp_alloc_remove(&tracker, sp_alloc_find(&tracker, (uintptr_t)large), i + 2, false);
        pthread_mutex_unlock(&lock);
        free(large);
        free(small);
    }
    return NULL;
}

static void *dump(void *unused) {
    (void)unused;
    static struct sp_alloc_site snapshot[SP_ALLOC_SITES];
    do {
        pthread_mutex_lock(&lock);
        uint64_t live = tracker.live, sum = 0;
        for (unsigned i = 0; i < SP_ALLOC_SITES; i++) {
            snapshot[i] = tracker.sites[i];
            tracker.sites[i].previous = snapshot[i].live;
            sum += snapshot[i].live;
        }
        pthread_mutex_unlock(&lock);
        assert(live == sum);
        unsigned top[16], growth[8];
        sp_alloc_rank(snapshot, SP_ALLOC_SITES, top, growth);
        assert((top[0] != SP_ALLOC_SITES) == (live != 0));
    } while (!atomic_load(&done));
    return NULL;
}

int main(void) {
    site5_cases();
    site_capacity_cases();
    cases();
    stack_cases();
    vmstat_cases();
    pthread_t workers[4], reader;
    assert(!pthread_create(&reader, NULL, dump, NULL));
    for (uintptr_t i = 0; i < 4; i++) assert(!pthread_create(&workers[i], NULL, worker, (void *)i));
    for (unsigned i = 0; i < 4; i++) assert(!pthread_join(workers[i], NULL));
    atomic_store(&done, true);
    assert(!pthread_join(reader, NULL));
    assert(!tracker.live);
}
