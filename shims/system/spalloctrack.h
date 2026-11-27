#ifndef SP_ALLOC_TRACK_H
#define SP_ALLOC_TRACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { SP_ALLOC_FRAMES = 5, SP_ALLOC_BLOCKS = 65536, SP_ALLOC_SITES = 8192 };
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

uint64_t sp_alloc_stack_hash(const uintptr_t pc[SP_ALLOC_FRAMES]);
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
#endif
