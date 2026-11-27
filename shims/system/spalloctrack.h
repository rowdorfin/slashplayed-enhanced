#ifndef SP_ALLOC_TRACK_H
#define SP_ALLOC_TRACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { SP_ALLOC_FRAMES = 12, SP_ALLOC_BLOCKS = 65536, SP_ALLOC_SITES = 8192 };
enum sp_alloc_kind { SP_HEAP = 1, SP_VM };

struct sp_alloc_site {
    uintptr_t pc[SP_ALLOC_FRAMES];
    uint64_t live, blocks, peak, peak_blocks, total, allocs, frees, growth, grows;
    uint64_t lifetime, previous, first_thread, last_thread;
};

struct sp_alloc_block {
    uintptr_t address;
    uint64_t size, usable, started, generation;
    unsigned site;
    enum sp_alloc_kind kind;
    bool resizing;
};

// Callers serialize access. Zero-filled storage is ready for use.
struct sp_alloc_tracker {
    struct sp_alloc_block blocks[SP_ALLOC_BLOCKS];
    struct sp_alloc_site sites[SP_ALLOC_SITES];
    uint64_t live, vm_live, dropped, phantom, generation;
    unsigned used, vm_blocks;
};

uint64_t sp_alloc_stack_hash(const uintptr_t *pc, unsigned frames);
char *sp_alloc_literal(char *out, const char *s);
char *sp_alloc_number(char *out, uint64_t n, unsigned base);

struct sp_mem_vm_rate {
    uint64_t calls, last_ns;
    bool emitted;
};

// Serialize access externally. Only complete samples consume the rate limit.
bool sp_mem_vm_due(struct sp_mem_vm_rate *, uint64_t now_ns, bool complete);

struct sp_mem_vm_sample {
    uint64_t calls, page_size, available, guest_offset;
    bool has_available, guest, has_external, has_internal;
    uint32_t words, free, active, inactive, speculative, wired, purgeable, compressor, external, internal;
};

enum { SP_MEM_VM_LINE = 384 };
size_t sp_mem_vm_format(char line[SP_MEM_VM_LINE], const struct sp_mem_vm_sample *);
struct sp_alloc_block sp_alloc_find(const struct sp_alloc_tracker *, uintptr_t);
struct sp_alloc_block sp_alloc_realloc_begin(struct sp_alloc_tracker *, uintptr_t);
void sp_alloc_realloc_end(struct sp_alloc_tracker *, struct sp_alloc_block, bool success, uint64_t now);
void sp_alloc_add(struct sp_alloc_tracker *, uintptr_t, uint64_t size, uint64_t usable,
                  enum sp_alloc_kind, const uintptr_t pc[SP_ALLOC_FRAMES], uint64_t thread,
                  uint64_t now, uint64_t old_size, bool reallocating);
void sp_alloc_remove(struct sp_alloc_tracker *, struct sp_alloc_block, uint64_t now, bool phantom);
void sp_alloc_unmap(struct sp_alloc_tracker *, uintptr_t, uint64_t, uint64_t now, uint64_t generation);
bool sp_alloc_rate(uint64_t previous, uint64_t live, uint64_t elapsed_ns, uint64_t bytes_per_second);
void sp_alloc_rank(struct sp_alloc_site *, size_t count, unsigned live[16], unsigned growth[8]);

enum { SP_ALLOC_SITE5_TOP = 8, SP_ALLOC_SITE5_BUCKETS = 2 * SP_ALLOC_SITES };
struct sp_alloc_site5 {
    uint64_t hash, live, blocks, total, allocs, frees;
    unsigned sub_sites;
};

// Scratch storage for the dump thread, separate from the allocation tracker.
struct sp_alloc_site5_scratch {
    uint16_t buckets[SP_ALLOC_SITE5_BUCKETS];
    struct sp_alloc_site5 groups[SP_ALLOC_SITES];
};

void sp_alloc_rank_site5(const struct sp_alloc_site snapshot[SP_ALLOC_SITES],
                         struct sp_alloc_site5_scratch *, struct sp_alloc_site5 top[SP_ALLOC_SITE5_TOP]);
#endif
