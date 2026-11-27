#include "spalloctrack.h"
#include <string.h>

static uint64_t mix(uint64_t x) {
    x ^= x >> 33;
    x *= UINT64_C(0xff51afd7ed558ccd);
    return x ^ (x >> 33);
}

uint64_t sp_alloc_stack_hash(const uintptr_t *pc, unsigned frames) {
    uint64_t hash = 0;
    for (unsigned i = 0; i < frames; i++) hash = mix(hash ^ pc[i]);
    return hash;
}

static unsigned bucket(uintptr_t address) {
    return mix(address) & (SP_ALLOC_BLOCKS - 1);
}

static unsigned slot(const struct sp_alloc_tracker *t, uintptr_t address) {
    unsigned i = bucket(address);
    for (unsigned n = 0; n < SP_ALLOC_BLOCKS; n++, i = (i + 1) & (SP_ALLOC_BLOCKS - 1))
        if (!t->blocks[i].address || t->blocks[i].address == address) return i;
    return SP_ALLOC_BLOCKS;
}

struct sp_alloc_block sp_alloc_find(const struct sp_alloc_tracker *t, uintptr_t address) {
    if (!address) return (struct sp_alloc_block){0};
    unsigned i = slot(t, address);
    return i == SP_ALLOC_BLOCKS ? (struct sp_alloc_block){0} : t->blocks[i];
}

struct sp_alloc_block sp_alloc_realloc_begin(struct sp_alloc_tracker *t, uintptr_t address) {
    if (address) {
        unsigned i = slot(t, address);
        if (i < SP_ALLOC_BLOCKS && t->blocks[i].kind == SP_HEAP) {
            t->blocks[i].resizing = true;
            return t->blocks[i];
        }
    }
    return (struct sp_alloc_block){0};
}

void sp_alloc_realloc_end(struct sp_alloc_tracker *t, struct sp_alloc_block b, bool success, uint64_t now) {
    if (!b.generation) return;
    if (success) sp_alloc_remove(t, b, now, false);
    else {
        unsigned i = slot(t, b.address);
        if (i < SP_ALLOC_BLOCKS && t->blocks[i].generation == b.generation)
            t->blocks[i].resizing = false;
    }
}

// Backshift deletion avoids tombstones accumulating during long sessions.
void sp_alloc_remove(struct sp_alloc_tracker *t, struct sp_alloc_block b, uint64_t now, bool phantom) {
    if (!b.generation) return;
    unsigned hole = slot(t, b.address);
    if (hole == SP_ALLOC_BLOCKS || t->blocks[hole].generation != b.generation ||
        (phantom && t->blocks[hole].resizing)) return;
    struct sp_alloc_site *s = &t->sites[b.site];
    s->live -= b.size;
    s->blocks--;
    t->live -= b.size;
    t->used--;
    if (b.kind == SP_VM) {
        t->vm_blocks--;
        t->vm_live -= b.size;
    }
    if (phantom) t->phantom++;
    else {
        s->frees++;
        s->lifetime += now - b.started;
    }
    unsigned mask = SP_ALLOC_BLOCKS - 1;
    t->blocks[hole] = (struct sp_alloc_block){0};
    for (unsigned i = (hole + 1) & mask; t->blocks[i].address; i = (i + 1) & mask) {
        unsigned home = bucket(t->blocks[i].address);
        if (((hole - home) & mask) < ((i - home) & mask)) {
            t->blocks[hole] = t->blocks[i];
            hole = i;
            t->blocks[hole] = (struct sp_alloc_block){0};
        }
    }
}

void sp_alloc_add(struct sp_alloc_tracker *t, uintptr_t address, uint64_t size, uint64_t usable,
                  enum sp_alloc_kind kind, const uintptr_t pc[SP_ALLOC_FRAMES], uint64_t thread,
                  uint64_t now, uint64_t old_size, bool reallocating) {
    struct sp_alloc_block old = sp_alloc_find(t, address);
    if (old.generation) sp_alloc_remove(t, old, now, !old.resizing);
    unsigned i = slot(t, address);
    unsigned s = sp_alloc_stack_hash(pc, SP_ALLOC_FRAMES) & (SP_ALLOC_SITES - 1);
    for (unsigned n = 0; n < SP_ALLOC_SITES; n++, s = (s + 1) & (SP_ALLOC_SITES - 1)) {
        struct sp_alloc_site *site = &t->sites[s];
        if (site->allocs && memcmp(site->pc, pc, sizeof site->pc)) continue;
        if (!site->allocs) {
            memcpy(site->pc, pc, sizeof site->pc);
            site->first_thread = thread;
        }
        site->last_thread = thread;
        site->total += size;
        site->allocs++;
        if (reallocating && size > old_size) {
            site->growth += size - old_size;
            site->grows++;
        }
        if (t->used >= SP_ALLOC_BLOCKS * 3 / 4 || !address) break;
        t->blocks[i] = (struct sp_alloc_block){address, size, usable, now, ++t->generation, s, kind, false};
        t->live += size;
        t->used++;
        if (kind == SP_VM) {
            t->vm_blocks++;
            t->vm_live += size;
        }
        site->live += size;
        site->blocks++;
        if (site->live > site->peak) site->peak = site->live;
        if (site->blocks > site->peak_blocks) site->peak_blocks = site->blocks;
        return;
    }
    // Covers both a new stack with no free site slot and an untracked block.
    t->dropped++;
}

// A partial unmap invalidates the original allocation as a unit. Count it as
// dropped coverage instead of crediting the surviving pages to a stale range.
void sp_alloc_unmap(struct sp_alloc_tracker *t, uintptr_t address, uint64_t size, uint64_t now, uint64_t generation) {
    if (!t->vm_blocks) return;
    struct sp_alloc_block exact = sp_alloc_find(t, address);
    if (exact.kind == SP_VM && exact.size == size && exact.generation <= generation) {
        sp_alloc_remove(t, exact, now, false);
        return;
    }
    for (unsigned i = 0; i < SP_ALLOC_BLOCKS;) {
        struct sp_alloc_block b = t->blocks[i];
        bool overlaps = b.address >= address ? b.address - address < size : address - b.address < b.size;
        if (b.kind != SP_VM || !overlaps || b.generation > generation) {
            i++;
            continue;
        }
        if (b.address < address || b.size > size - (b.address - address)) t->dropped++;
        sp_alloc_remove(t, b, now, false);
    }
}

bool sp_alloc_rate(uint64_t previous, uint64_t live, uint64_t elapsed_ns, uint64_t bytes_per_second) {
    return elapsed_ns && live > previous &&
           (double)(live - previous) * 1e9 > (double)elapsed_ns * bytes_per_second;
}

static void rank(unsigned *out, unsigned count, const uint64_t *scores, unsigned candidate) {
    for (unsigned i = 0; i < count; i++) {
        if (out[i] == SP_ALLOC_SITES || scores[candidate] > scores[out[i]]) {
            memmove(out + i + 1, out + i, (count - i - 1) * sizeof *out);
            out[i] = candidate;
            return;
        }
    }
}

void sp_alloc_rank(struct sp_alloc_site *sites, size_t count, unsigned live[16], unsigned growth[8]) {
    uint64_t scores[SP_ALLOC_SITES];
    for (unsigned i = 0; i < 16; i++) live[i] = SP_ALLOC_SITES;
    for (unsigned i = 0; i < 8; i++) growth[i] = SP_ALLOC_SITES;
    for (unsigned i = 0; i < count; i++) {
        scores[i] = sites[i].live;
        if (scores[i]) rank(live, 16, scores, i);
    }
    for (unsigned i = 0; i < count; i++) {
        scores[i] = sites[i].live > sites[i].previous ? sites[i].live - sites[i].previous : 0;
        if (scores[i]) rank(growth, 8, scores, i);
    }
}

void sp_alloc_rank_site5(const struct sp_alloc_site snapshot[SP_ALLOC_SITES],
                         struct sp_alloc_site5_scratch *scratch, struct sp_alloc_site5 top[SP_ALLOC_SITE5_TOP]) {
    memset(scratch->buckets, 0, sizeof scratch->buckets);
    memset(top, 0, sizeof *top * SP_ALLOC_SITE5_TOP);
    unsigned count = 0;
    for (unsigned i = 0; i < SP_ALLOC_SITES; i++) {
        const struct sp_alloc_site *site = &snapshot[i];
        if (!site->allocs) continue;
        uint64_t hash = sp_alloc_stack_hash(site->pc, 5);
        const unsigned mask = SP_ALLOC_SITE5_BUCKETS - 1;
        unsigned bucket = hash & mask;
        // Store one-based group indices so even a zero hash can be grouped.
        while (scratch->buckets[bucket] && scratch->groups[scratch->buckets[bucket] - 1].hash != hash)
            bucket = (bucket + 1) & mask;
        if (!scratch->buckets[bucket]) {
            scratch->groups[count] = (struct sp_alloc_site5){.hash = hash};
            scratch->buckets[bucket] = ++count;
        }
        struct sp_alloc_site5 *group = &scratch->groups[scratch->buckets[bucket] - 1];
        group->live += site->live;
        group->blocks += site->blocks;
        group->total += site->total;
        group->allocs += site->allocs;
        group->frees += site->frees;
        group->sub_sites++;
    }
    for (unsigned i = 0; i < count; i++) {
        const struct sp_alloc_site5 *group = &scratch->groups[i];
        for (unsigned j = 0; j < SP_ALLOC_SITE5_TOP; j++) {
            if (group->live <= top[j].live) continue;
            memmove(top + j + 1, top + j, (SP_ALLOC_SITE5_TOP - j - 1) * sizeof *top);
            top[j] = *group;
            break;
        }
    }
}

char *sp_alloc_literal(char *out, const char *s) {
    while (*s) *out++ = *s++;
    return out;
}

char *sp_alloc_number(char *out, uint64_t n, unsigned base) {
    char digits[24];
    unsigned count = 0;
    do {
        digits[count++] = "0123456789abcdef"[n % base];
    } while ((n /= base));
    while (count) *out++ = digits[--count];
    return out;
}

bool sp_mem_vm_due(struct sp_mem_vm_rate *rate, uint64_t now_ns, bool complete) {
    rate->calls++;
    if (!complete || (rate->emitted && now_ns - rate->last_ns < UINT64_C(1000000000))) return false;
    rate->last_ns = now_ns;
    rate->emitted = true;
    return true;
}

size_t sp_mem_vm_format(char line[SP_MEM_VM_LINE], const struct sp_mem_vm_sample *vm) {
    // Worst case is under 330 bytes: four wider fields and ten uint32 values,
    // including labels, newline, and terminator.
    char *out = sp_alloc_literal(line, "SP_MEM_VMSTAT");
#define FIELD(name, value) out = sp_alloc_number(sp_alloc_literal(out, " " name "="), value, 10)
    FIELD("calls", vm->calls);
    FIELD("words", vm->words);
    FIELD("pageSize", vm->page_size);
    FIELD("free", vm->free);
    FIELD("active", vm->active);
    FIELD("inactive", vm->inactive);
    FIELD("speculative", vm->speculative);
    FIELD("wired", vm->wired);
    FIELD("purgeable", vm->purgeable);
    FIELD("compressor", vm->compressor);
    if (vm->has_external) { FIELD("external", vm->external); }
    if (vm->has_internal) { FIELD("internal", vm->internal); }
    if (vm->has_available) { FIELD("available", vm->available); }
    else out = sp_alloc_literal(out, " available=n/a");
#undef FIELD
    out = sp_alloc_literal(out, vm->guest ? " caller=guest+0x" : " caller=outside_guest");
    if (vm->guest) out = sp_alloc_number(out, vm->guest_offset, 16);
    *out++ = '\n';
    *out = 0;
    return out - line;
}
