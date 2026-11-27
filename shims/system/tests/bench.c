#define _GNU_SOURCE
#include "../spalloctrack.h"
#include <assert.h>
#include <malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static atomic_bool enabled;
static struct sp_alloc_tracker tracker;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static size_t page_mask;

void *__real_malloc(size_t);
void __real_free(void *);

static void record(void *p, size_t n, uintptr_t caller) {
    uintptr_t pc[SP_ALLOC_FRAMES] = {caller};
    size_t usable = malloc_usable_size(p);
    pthread_mutex_lock(&mutex);
    sp_alloc_add(&tracker, (uintptr_t)p, n, usable, SP_HEAP, pc, 1, 0, 0, false);
    pthread_mutex_unlock(&mutex);
}

void *__wrap_malloc(size_t n) {
    void *p = __real_malloc(n);
    if (atomic_load_explicit(&enabled, memory_order_relaxed) && p && n >= 262144)
        record(p, n, (uintptr_t)__builtin_return_address(0));
    return p;
}

void __wrap_free(void *p) {
    // glibc's large allocations aren't necessarily page-aligned, so the
    // enabled benchmark also looks up unaligned large pointers on Linux.
    if (atomic_load_explicit(&enabled, memory_order_relaxed) && p &&
        (!((uintptr_t)p & page_mask) || malloc_usable_size(p) >= 262144)) {
        pthread_mutex_lock(&mutex);
        sp_alloc_remove(&tracker, sp_alloc_find(&tracker, (uintptr_t)p), 1, false);
        pthread_mutex_unlock(&mutex);
    }
    __real_free(p);
}

static uint64_t now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static double bench(size_t n, void *(*alloc)(size_t), void (*release)(void *)) {
    unsigned loops = 1000000;
    uint64_t start = now();
    for (unsigned i = 0; i < loops; i++) {
        void *p = alloc(n);
        if (!p) abort();
        *(volatile unsigned char *)p = 1;
        release(p);
    }
    return (double)(now() - start) / loops;
}

int main(void) {
    page_mask = (size_t)sysconf(_SC_PAGESIZE) - 1;
    for (size_t n = 64; n <= 1048576; n *= 16384) {
        double plain[5], off[5], on[5];
        for (unsigned i = 0; i < 5; i++) {
            atomic_store(&enabled, false);
            plain[i] = bench(n, __real_malloc, __real_free);
            off[i] = bench(n, malloc, free);
            atomic_store(&enabled, true);
            on[i] = bench(n, malloc, free);
        }
        double *samples[] = {plain, off, on};
        for (unsigned k = 0; k < 3; k++) {
            for (unsigned i = 0; i < 5; i++) {
                for (unsigned j = i + 1; j < 5; j++) {
                    if (samples[k][j] >= samples[k][i]) continue;
                    double swap = samples[k][j];
                    samples[k][j] = samples[k][i];
                    samples[k][i] = swap;
                }
            }
        }
        printf("%zu B malloc+free ns/op median of 5: native %.2f off %.2f on %.2f\n",
               n, plain[2], off[2], on[2]);
    }
    assert(!tracker.live && tracker.generation == 5000000);
}
