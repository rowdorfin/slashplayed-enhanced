// Included in spsystem.c for the guest __TEXT range. The real libSystem handle
// resolves its own reexports before any guest code or diagnostic threads run.
#include "spalloctrack.h"
#include <mach/mach_time.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <ptrauth.h>

#define SP_REAL(name) static __typeof__(&name) sp_lib_##name
#define SP_EXPORT(ret, name, params) \
    ret sp_##name params __asm__("_" #name); \
    ret sp_##name params

SP_REAL(malloc);
SP_REAL(calloc);
SP_REAL(realloc);
SP_REAL(free);
SP_REAL(posix_memalign);
SP_REAL(aligned_alloc);
SP_REAL(valloc);
SP_REAL(malloc_zone_malloc);
SP_REAL(malloc_zone_calloc);
SP_REAL(malloc_zone_realloc);
SP_REAL(malloc_zone_free);
SP_REAL(malloc_zone_memalign);
SP_REAL(mmap);
SP_REAL(write);
SP_REAL(task_threads);
SP_REAL(sysctl);
SP_REAL(sysctlbyname);
SP_REAL(munmap);
SP_REAL(vm_allocate);
SP_REAL(vm_deallocate);
// Some iOS SDKs hide the mach_vm MIG declarations. The arm64 ABI uses
// mach_vm_address_t/mach_vm_size_t even when the headers only declare vm_*.
static kern_return_t (*sp_lib_mach_vm_allocate)(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
static kern_return_t (*sp_lib_mach_vm_deallocate)(vm_map_t, mach_vm_address_t, mach_vm_size_t);

static atomic_bool sp_alloc_enabled;
static os_unfair_lock sp_alloc_lock = OS_UNFAIR_LOCK_INIT;
static struct sp_alloc_tracker *sp_alloc_tracker;
static size_t sp_alloc_min, sp_alloc_page_mask;
static uint64_t sp_alloc_start, sp_alloc_limit;
static mach_timebase_info_data_t sp_alloc_timebase;
static uint64_t sp_alloc_large, sp_alloc_zone;
static bool sp_alloc_coverage;
static atomic_uint_fast64_t sp_alloc_warning;
static struct sp_alloc_site sp_alloc_snapshot[SP_ALLOC_SITES];
static struct sp_alloc_site5_scratch sp_alloc_site5_scratch;

extern kern_return_t sp_host_task_info(task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t *);
extern size_t sp_host_available_memory(void);
static void sp_threadpool_dump(void);
extern void sp_mem_init(void *system);
extern void sp_mem_enable(void);
extern void sp_mem_dump(bool warning);
extern void sp_mem_sysctl(const char *name, int status, const void *value, size_t size);

static inline bool sp_alloc_on(void) {
    return atomic_load_explicit(&sp_alloc_enabled, memory_order_acquire);
}

__attribute__((visibility("hidden"))) bool sp_alloc_observing(void) {
    return sp_alloc_on();
}

static kern_return_t sp_alloc_mach_allocate_fallback(vm_map_t target, mach_vm_address_t *address,
                                                     mach_vm_size_t size, int flags) {
    if (!address) return sp_lib_vm_allocate(target, NULL, size, flags);
    vm_address_t narrow = (vm_address_t)*address;
    kern_return_t result = sp_lib_vm_allocate(target, &narrow, size, flags);
    if (result == KERN_SUCCESS) *address = narrow;
    return result;
}

static kern_return_t sp_alloc_mach_deallocate_fallback(vm_map_t target, mach_vm_address_t address,
                                                       mach_vm_size_t size) {
    return sp_lib_vm_deallocate(target, address, size);
}

static void sp_alloc_resolve(void) {
    void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOLOAD | RTLD_LAZY);
    if (!system) __builtin_trap();
#define SP_RESOLVE(name) do { \
    sp_lib_##name = sp_real_dlsym(system, #name); \
    if (!sp_lib_##name) __builtin_trap(); \
} while (0)
    SP_RESOLVE(malloc);
    SP_RESOLVE(calloc);
    SP_RESOLVE(realloc);
    SP_RESOLVE(free);
    SP_RESOLVE(posix_memalign);
    SP_RESOLVE(aligned_alloc);
    SP_RESOLVE(valloc);
    SP_RESOLVE(malloc_zone_malloc);
    SP_RESOLVE(malloc_zone_calloc);
    SP_RESOLVE(malloc_zone_realloc);
    SP_RESOLVE(malloc_zone_free);
    SP_RESOLVE(malloc_zone_memalign);
    SP_RESOLVE(mmap);
    SP_RESOLVE(write);
    SP_RESOLVE(task_threads);
    SP_RESOLVE(sysctl);
    SP_RESOLVE(sysctlbyname);
    SP_RESOLVE(munmap);
    SP_RESOLVE(vm_allocate);
    SP_RESOLVE(vm_deallocate);
    sp_lib_mach_vm_allocate = sp_real_dlsym(system, "mach_vm_allocate");
    sp_lib_mach_vm_deallocate = sp_real_dlsym(system, "mach_vm_deallocate");
    // arm64 vm_* takes the same pointer and size widths. Use the SDK's
    // supported entry point if its libSystem hides the mach_vm spelling.
    if (!sp_lib_mach_vm_allocate) sp_lib_mach_vm_allocate = sp_alloc_mach_allocate_fallback;
    if (!sp_lib_mach_vm_deallocate) sp_lib_mach_vm_deallocate = sp_alloc_mach_deallocate_fallback;
#undef SP_RESOLVE
    sp_mem_init(system);
}

static uint64_t sp_alloc_ns(uint64_t ticks) {
    return (uint64_t)((__uint128_t)ticks * sp_alloc_timebase.numer / sp_alloc_timebase.denom);
}

static uintptr_t sp_alloc_pc(uintptr_t pc) {
    return (uintptr_t)ptrauth_strip((void *)pc, ptrauth_key_return_address);
}

static void sp_alloc_stack(uintptr_t pc[SP_ALLOC_FRAMES], uintptr_t caller, uintptr_t frame) {
    pc[0] = sp_alloc_pc(caller);
    pthread_t self = pthread_self();
    uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(self);
    size_t size = pthread_get_stacksize_np(self);
    if (size > high || size < 2 * sizeof(uintptr_t)) return;
    uintptr_t low = high - size;
    for (unsigned i = 0; i < SP_ALLOC_FRAMES; i++) {
        if ((frame & 15) || frame < low || frame > high - 2 * sizeof(uintptr_t)) break;
        const uintptr_t *fp = (const uintptr_t *)frame;
        if (i) pc[i] = sp_alloc_pc(fp[1]);
        if (fp[0] <= frame) break;
        frame = fp[0];
    }
}

static char *sp_alloc_site_ids(char *out, const uintptr_t *pc) {
    out = sp_alloc_number(sp_alloc_literal(out, " site="), sp_alloc_stack_hash(pc, SP_ALLOC_FRAMES), 16);
    out = sp_alloc_number(sp_alloc_literal(out, " site4="), sp_alloc_stack_hash(pc, 4), 16);
    return sp_alloc_number(sp_alloc_literal(out, " site5="), sp_alloc_stack_hash(pc, 5), 16);
}

static void sp_alloc_big(size_t size, enum sp_alloc_kind kind, const uintptr_t *pc, uint64_t tid, uint64_t now) {
    char line[512], *out = sp_alloc_literal(line, "SP_ALLOC_BIG bytes=");
    _Static_assert(sizeof line >= 200 + SP_ALLOC_FRAMES * 25, "SP_ALLOC_BIG line capacity");
    out = sp_alloc_number(out, size, 10);
    out = sp_alloc_literal(out, " tid=");
    out = sp_alloc_number(out, tid, 10);
    out = sp_alloc_literal(out, " elapsedMs=");
    out = sp_alloc_number(out, sp_alloc_ns(now - sp_alloc_start) / 1000000, 10);
    out = sp_alloc_literal(out, kind == SP_HEAP ? " kind=heap" : " kind=vm");
    out = sp_alloc_site_ids(out, pc);
    out = sp_alloc_literal(out, " stack=");
    for (unsigned i = 0; i < SP_ALLOC_FRAMES && pc[i]; i++) {
        if (i) *out++ = ',';
        uintptr_t base = sp_diagnostic_guest_base(pc[i]);
        if (base) {
            out = sp_alloc_literal(out, "guest+0x");
            out = sp_alloc_number(out, pc[i] - base, 16);
        } else {
            // SP_ALLOC_TOP resolves this PC to its image and offset.
            out = sp_alloc_literal(out, "0x");
            out = sp_alloc_number(out, pc[i], 16);
        }
    }
    *out++ = '\n';
    sp_lib_write(STDERR_FILENO, line, out - line);
}

static struct sp_alloc_block sp_alloc_begin_realloc(uintptr_t address) {
    struct sp_alloc_block b = {0};
    if (!address || (address & sp_alloc_page_mask)) return b;
    os_unfair_lock_lock(&sp_alloc_lock);
    b = sp_alloc_realloc_begin(sp_alloc_tracker, address);
    os_unfair_lock_unlock(&sp_alloc_lock);
    return b;
}

static void sp_alloc_record(void *p, size_t size, enum sp_alloc_kind kind,
                            uintptr_t caller, uintptr_t frame, struct sp_alloc_block old,
                            size_t old_size, bool reallocating) {
    int saved = errno;
    uintptr_t pc[SP_ALLOC_FRAMES] = {0};
    uint64_t tid = 0, now = mach_absolute_time();
    bool report = p && size >= sp_alloc_min;
    size_t usable = 0;
    if (report) {
        sp_alloc_stack(pc, caller, frame);
        pthread_threadid_np(NULL, &tid);
        if (kind == SP_HEAP) usable = malloc_size(p);
    }
    os_unfair_lock_lock(&sp_alloc_lock);
    sp_alloc_realloc_end(sp_alloc_tracker, old, p != NULL, now);
    if (report)
        sp_alloc_add(sp_alloc_tracker, (uintptr_t)p, size, usable, kind, pc, tid, now, old_size, reallocating);
    os_unfair_lock_unlock(&sp_alloc_lock);
    if (report && size >= 32 * 1048576) sp_alloc_big(size, kind, pc, tid, now);
    errno = saved;
}

#define SP_STACK (uintptr_t)__builtin_return_address(0), (uintptr_t)__builtin_frame_address(0)
#define SP_ADD(p, size, kind) sp_alloc_record(p, size, kind, SP_STACK, (struct sp_alloc_block){0}, 0, false)
#define SP_HEAP_WRAPPER(name, params, args, bytes) \
    SP_EXPORT(void *, name, params) { \
        void *p = sp_lib_##name args; \
        if (sp_alloc_on() && p && (bytes) >= sp_alloc_min) SP_ADD(p, bytes, SP_HEAP); \
        return p; \
    }

SP_HEAP_WRAPPER(malloc, (size_t n), (n), n)
SP_HEAP_WRAPPER(calloc, (size_t n, size_t size), (n, size), n * size)
SP_HEAP_WRAPPER(aligned_alloc, (size_t align, size_t n), (align, n), n)
SP_HEAP_WRAPPER(valloc, (size_t n), (n), n)
SP_HEAP_WRAPPER(malloc_zone_malloc, (malloc_zone_t *z, size_t n), (z, n), n)
SP_HEAP_WRAPPER(malloc_zone_calloc, (malloc_zone_t *z, size_t n, size_t size), (z, n, size), n * size)
SP_HEAP_WRAPPER(malloc_zone_memalign, (malloc_zone_t *z, size_t align, size_t n), (z, align, n), n)

SP_EXPORT(int, posix_memalign, (void **out, size_t alignment, size_t size)) {
    int status = sp_lib_posix_memalign(out, alignment, size);
    if (sp_alloc_on() && !status && size >= sp_alloc_min) SP_ADD(*out, size, SP_HEAP);
    return status;
}

static void sp_alloc_free(void *p) {
    int saved = errno;
    uint64_t now = mach_absolute_time();
    os_unfair_lock_lock(&sp_alloc_lock);
    struct sp_alloc_block b = sp_alloc_find(sp_alloc_tracker, (uintptr_t)p);
    if (b.kind == SP_HEAP) sp_alloc_remove(sp_alloc_tracker, b, now, false);
    os_unfair_lock_unlock(&sp_alloc_lock);
    errno = saved;
}

SP_EXPORT(void, free, (void *p)) {
    if (sp_alloc_on() && p && !((uintptr_t)p & sp_alloc_page_mask)) sp_alloc_free(p);
    sp_lib_free(p);
}

SP_EXPORT(void, malloc_zone_free, (malloc_zone_t *z, void *p)) {
    if (sp_alloc_on() && p && !((uintptr_t)p & sp_alloc_page_mask)) sp_alloc_free(p);
    sp_lib_malloc_zone_free(z, p);
}

#define SP_REALLOC(name, params, args) \
    SP_EXPORT(void *, name, params) { \
        if (!sp_alloc_on()) return sp_lib_##name args; \
        int saved = errno; \
        struct sp_alloc_block old = sp_alloc_begin_realloc((uintptr_t)p); \
        size_t old_size = old.kind == SP_HEAP ? old.size : p && n >= sp_alloc_min ? malloc_size(p) : 0; \
        bool reallocating = p != NULL; \
        errno = saved; \
        void *result = sp_lib_##name args; \
        if (old.kind == SP_HEAP || (result && n >= sp_alloc_min)) \
            sp_alloc_record(result, n, SP_HEAP, SP_STACK, old, old_size, reallocating); \
        return result; \
    }

SP_REALLOC(realloc, (void *p, size_t n), (p, n))
SP_REALLOC(malloc_zone_realloc, (malloc_zone_t *z, void *p, size_t n), (z, p, n))

static bool sp_alloc_self(mach_port_t task) {
    return task == mach_task_self();
}

static uint64_t sp_alloc_vm_generation(void) {
    os_unfair_lock_lock(&sp_alloc_lock);
    uint64_t generation = sp_alloc_tracker->generation;
    os_unfair_lock_unlock(&sp_alloc_lock);
    return generation;
}

static void sp_alloc_vm_remove(uintptr_t address, size_t size, uint64_t generation) {
    int saved = errno;
    uintptr_t start = address & ~sp_alloc_page_mask;
    size_t shift = address - start;
    if (size && size <= SIZE_MAX - shift - sp_alloc_page_mask) {
        size_t rounded = (size + shift + sp_alloc_page_mask) & ~sp_alloc_page_mask;
        uint64_t now = mach_absolute_time();
        os_unfair_lock_lock(&sp_alloc_lock);
        sp_alloc_unmap(sp_alloc_tracker, start, rounded, now, generation);
        os_unfair_lock_unlock(&sp_alloc_lock);
    }
    errno = saved;
}

#define SP_VM_ALLOC(name, addrtype, sizetype) \
    SP_EXPORT(kern_return_t, name, (vm_map_t target, addrtype *address, sizetype size, int flags)) { \
        bool trace = sp_alloc_on() && sp_alloc_self(target); \
        uint64_t before = trace && (flags & VM_FLAGS_OVERWRITE) ? sp_alloc_vm_generation() : 0; \
        kern_return_t status = sp_lib_##name(target, address, size, flags); \
        if (trace && status == KERN_SUCCESS) { \
            if (flags & VM_FLAGS_OVERWRITE) sp_alloc_vm_remove(*address, size, before); \
            if (size >= sp_alloc_min && size <= SIZE_MAX - sp_alloc_page_mask) \
                SP_ADD((void *)(uintptr_t)*address, (size + sp_alloc_page_mask) & ~sp_alloc_page_mask, SP_VM); \
        } \
        return status; \
    }

#define SP_VM_FREE(name, addrtype, sizetype) \
    SP_EXPORT(kern_return_t, name, (vm_map_t target, addrtype address, sizetype size)) { \
        bool trace = sp_alloc_on() && sp_alloc_self(target); \
        uint64_t before = trace ? sp_alloc_vm_generation() : 0; \
        kern_return_t status = sp_lib_##name(target, address, size); \
        if (trace && status == KERN_SUCCESS) sp_alloc_vm_remove(address, size, before); \
        return status; \
    }

SP_VM_ALLOC(vm_allocate, vm_address_t, vm_size_t)
SP_VM_ALLOC(mach_vm_allocate, mach_vm_address_t, mach_vm_size_t)
SP_VM_FREE(vm_deallocate, vm_address_t, vm_size_t)
SP_VM_FREE(mach_vm_deallocate, mach_vm_address_t, mach_vm_size_t)

SP_EXPORT(int, munmap, (void *address, size_t size)) {
    bool trace = sp_alloc_on();
    uint64_t before = trace ? sp_alloc_vm_generation() : 0;
    int status = sp_lib_munmap(address, size);
    if (trace && !status) sp_alloc_vm_remove((uintptr_t)address, size, before);
    return status;
}

static char *sp_alloc_field(char *out, const char *label, uint64_t value) {
    return sp_alloc_number(sp_alloc_literal(out, label), value, 10);
}

static char *sp_alloc_bounded(char *out, const char *s, size_t limit) {
    for (size_t i = 0; i < limit && s[i]; i++)
        *out++ = (s[i] == '\n' || s[i] == '\r' || s[i] == '"') ? '?' : s[i];
    return out;
}

struct sp_alloc_thread_sample {
    uint64_t id;
    char name[64];
};

static void sp_alloc_thread_names(struct sp_alloc_thread_sample *names, unsigned count) {
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    if (sp_lib_task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) return;
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        thread_identifier_info_data_t info;
        mach_msg_type_number_t words = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &words) == KERN_SUCCESS) {
            for (unsigned j = 0; j < count; j++) {
                if (names[j].id != info.thread_id) continue;
                pthread_t thread = pthread_from_mach_thread_np(threads[i]);
                if (thread) pthread_getname_np(thread, names[j].name, sizeof names[j].name);
                break;
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    sp_lib_vm_deallocate(mach_task_self(), (vm_address_t)threads, thread_count * sizeof *threads);
}

static const char *sp_alloc_thread_name(const struct sp_alloc_thread_sample *names, unsigned count, uint64_t id) {
    for (unsigned i = 0; i < count; i++)
        if (names[i].id == id && names[i].name[0]) return names[i].name;
    return "-";
}

static void sp_alloc_add_thread(struct sp_alloc_thread_sample *names, unsigned *count, uint64_t id) {
    for (unsigned i = 0; i < *count; i++)
        if (names[i].id == id) return;
    names[(*count)++].id = id;
}

static void sp_alloc_print_site(const char *reason, const char *rank, unsigned index,
                                const struct sp_alloc_thread_sample *names, unsigned count) {
    const struct sp_alloc_site *s = &sp_alloc_snapshot[index];
    char line[2048];
    // At most 90 image bytes, "+0x", 16 hex digits, and a comma per frame.
    _Static_assert(sizeof line >= 640 + SP_ALLOC_FRAMES * 110, "SP_ALLOC_TOP line capacity");
    char *out = sp_alloc_literal(line, "SP_ALLOC_TOP reason=");
    out = sp_alloc_literal(out, reason);
    out = sp_alloc_literal(sp_alloc_literal(out, " rank="), rank);
    out = sp_alloc_site_ids(out, s->pc);
    out = sp_alloc_literal(out, " stack=");
    for (unsigned i = 0; i < SP_ALLOC_FRAMES && s->pc[i]; i++) {
        uintptr_t pc = s->pc[i], base = sp_diagnostic_guest_base(pc);
        const char *image = "unknown";
        Dl_info info;
        if (base) image = "guest";
        else if (dladdr((void *)pc, &info) && info.dli_fname) {
            const char *slash = strrchr(info.dli_fname, '/');
            image = slash ? slash + 1 : info.dli_fname;
            base = (uintptr_t)info.dli_fbase;
        }
        if (i) *out++ = ',';
        out = sp_alloc_bounded(out, image, 90);
        out = sp_alloc_number(sp_alloc_literal(out, "+0x"), pc - base, 16);
    }
    out = sp_alloc_field(out, " live=", s->live);
    out = sp_alloc_field(out, " blocks=", s->blocks);
    out = sp_alloc_field(out, " peak=", s->peak);
    out = sp_alloc_field(out, " peakBlocks=", s->peak_blocks);
    out = sp_alloc_field(out, " total=", s->total);
    out = sp_alloc_field(out, " allocs=", s->allocs);
    out = sp_alloc_field(out, " frees=", s->frees);
    out = sp_alloc_field(out, " reallocBytes=", s->growth);
    out = sp_alloc_field(out, " reallocs=", s->grows);
    out = sp_alloc_field(out, " meanLifetimeUs=", s->frees ? sp_alloc_ns(s->lifetime / s->frees) / 1000 : 0);
    out = sp_alloc_field(out, " firstTid=", s->first_thread);
    out = sp_alloc_bounded(sp_alloc_literal(out, " firstName=\""),
                           sp_alloc_thread_name(names, count, s->first_thread), 63);
    out = sp_alloc_field(out, "\" lastTid=", s->last_thread);
    out = sp_alloc_bounded(sp_alloc_literal(out, " lastName=\""),
                           sp_alloc_thread_name(names, count, s->last_thread), 63);
    out = sp_alloc_literal(out, "\" delta=");
    if (s->live < s->previous) {
        *out++ = '-';
        out = sp_alloc_number(out, s->previous - s->live, 10);
    } else out = sp_alloc_number(out, s->live - s->previous, 10);
    *out++ = '\n';
    sp_lib_write(STDERR_FILENO, line, out - line);
}

static void sp_alloc_print_site5(const char *reason, const struct sp_alloc_site5 *group) {
    char line[320], *out = sp_alloc_literal(line, "SP_ALLOC_TOP reason=");
    out = sp_alloc_literal(out, reason);
    out = sp_alloc_number(sp_alloc_literal(out, " rank=site5 site5="), group->hash, 16);
    out = sp_alloc_field(out, " live=", group->live);
    out = sp_alloc_field(out, " blocks=", group->blocks);
    out = sp_alloc_field(out, " total=", group->total);
    out = sp_alloc_field(out, " allocs=", group->allocs);
    out = sp_alloc_field(out, " frees=", group->frees);
    out = sp_alloc_field(out, " subSites=", group->sub_sites);
    *out++ = '\n';
    sp_lib_write(STDERR_FILENO, line, out - line);
}

static void sp_alloc_dump(const char *reason, bool warning) {
    // Walk outside the allocator and never hold our lock during malloc_size.
    // A generation check makes a stale observation harmless after reuse.
    uint64_t now = mach_absolute_time();
    for (unsigned i = 0; i < SP_ALLOC_BLOCKS; i++) {
        os_unfair_lock_lock(&sp_alloc_lock);
        struct sp_alloc_block b = sp_alloc_tracker->blocks[i];
        os_unfair_lock_unlock(&sp_alloc_lock);
        if (b.kind != SP_HEAP || b.resizing) continue;
        size_t current = malloc_size((void *)b.address);
        if (current && current == b.usable) continue;
        os_unfair_lock_lock(&sp_alloc_lock);
        sp_alloc_remove(sp_alloc_tracker, b, now, true);
        os_unfair_lock_unlock(&sp_alloc_lock);
    }
    os_unfair_lock_lock(&sp_alloc_lock);
    memcpy(sp_alloc_snapshot, sp_alloc_tracker->sites, sizeof sp_alloc_snapshot);
    for (unsigned i = 0; i < SP_ALLOC_SITES; i++) sp_alloc_tracker->sites[i].previous = sp_alloc_snapshot[i].live;
    uint64_t live = sp_alloc_tracker->live, vm = sp_alloc_tracker->vm_live;
    uint64_t dropped = sp_alloc_tracker->dropped, phantom = sp_alloc_tracker->phantom;
    uint64_t large = sp_alloc_large, zone = sp_alloc_zone;
    bool sampled = sp_alloc_coverage;
    os_unfair_lock_unlock(&sp_alloc_lock);
    unsigned top[16], growth[8];
    sp_alloc_rank(sp_alloc_snapshot, SP_ALLOC_SITES, top, growth);
    char line[320];
    char *out = sp_alloc_literal(sp_alloc_literal(line, "SP_ALLOC_COVER reason="), reason);
    out = sp_alloc_field(out, " tracked=", live);
    out = sp_alloc_field(out, " trackedHeap=", live - vm);
    out = sp_alloc_field(out, " trackedVM=", vm);
    out = sp_alloc_field(out, " mallocLarge=", large);
    out = sp_alloc_field(out, " zoneInUse=", zone);
    out = sp_alloc_field(out, " sampled=", sampled);
    out = sp_alloc_field(out, " dropped=", dropped);
    out = sp_alloc_field(out, " phantom=", phantom);
    *out++ = '\n';
    sp_lib_write(STDERR_FILENO, line, out - line);
    struct sp_alloc_thread_sample names[2 * (16 + 8)] = {0};
    unsigned count = 0;
    for (unsigned i = 0; i < 24; i++) {
        unsigned index = i < 16 ? top[i] : growth[i - 16];
        if (index == SP_ALLOC_SITES) continue;
        sp_alloc_add_thread(names, &count, sp_alloc_snapshot[index].first_thread);
        sp_alloc_add_thread(names, &count, sp_alloc_snapshot[index].last_thread);
    }
    if (count) sp_alloc_thread_names(names, count);
    for (unsigned i = 0; i < 16 && top[i] != SP_ALLOC_SITES; i++)
        sp_alloc_print_site(reason, "live", top[i], names, count);
    for (unsigned i = 0; i < 8 && growth[i] != SP_ALLOC_SITES; i++)
        sp_alloc_print_site(reason, "growth", growth[i], names, count);
    struct sp_alloc_site5 site5[SP_ALLOC_SITE5_TOP];
    sp_alloc_rank_site5(sp_alloc_snapshot, &sp_alloc_site5_scratch, site5);
    for (unsigned i = 0; i < SP_ALLOC_SITE5_TOP && site5[i].live; i++)
        sp_alloc_print_site5(reason, &site5[i]);
    sp_mem_dump(warning);
}

void sp_alloc_sample(uint64_t large, uint64_t zone, bool warning) {
    if (!sp_alloc_on()) return;
    os_unfair_lock_lock(&sp_alloc_lock);
    sp_alloc_large = large;
    sp_alloc_zone = zone;
    sp_alloc_coverage = true;
    os_unfair_lock_unlock(&sp_alloc_lock);
    if (warning) atomic_store(&sp_alloc_warning, mach_absolute_time());
}

static void *sp_alloc_watch(void *unused) {
    (void)unused;
    uint64_t previous = 0, last_rate = sp_alloc_start, last_periodic = sp_alloc_start, last_warning = 0;
    uint64_t last_burst = 0;
    uint64_t burst_until = 0;
    for (;;) {
        struct timespec delay = {0, 100000000};
        nanosleep(&delay, NULL);
        uint64_t now = mach_absolute_time(), warning = atomic_load(&sp_alloc_warning);
        if (warning != last_warning) {
            last_warning = warning;
            burst_until = warning + ((__uint128_t)10000000000ULL * sp_alloc_timebase.denom / sp_alloc_timebase.numer);
            sp_alloc_dump("warning", true);
            last_burst = now;
        } else if (now < burst_until && sp_alloc_ns(now - last_burst) >= 500000000) {
            sp_alloc_dump("warning-burst", false);
            last_burst = now;
        }
        uint64_t elapsed = sp_alloc_ns(now - last_rate);
        if (elapsed < 1000000000) continue;
        os_unfair_lock_lock(&sp_alloc_lock);
        uint64_t live = sp_alloc_tracker->live;
        os_unfair_lock_unlock(&sp_alloc_lock);
        bool rate = sp_alloc_rate(previous, live, elapsed, sp_alloc_limit);
        previous = live;
        last_rate = now;
        bool periodic = sp_alloc_ns(now - last_periodic) >= 30000000000ULL;
        if (periodic) last_periodic = now;
        if ((rate || periodic) && last_burst != now)
            sp_alloc_dump(rate ? "rate" : "periodic", false);
    }
    return NULL;
}

static unsigned long sp_alloc_env(const char *name, unsigned long fallback, unsigned long max) {
    const char *value = getenv(name);
    if (!value || *value < '0' || *value > '9') return fallback;
    char *end;
    unsigned long parsed = strtoul(value, &end, 10);
    return *end || !parsed || parsed > max ? fallback : parsed;
}

static void sp_alloc_child(void) {
    atomic_store_explicit(&sp_alloc_enabled, false, memory_order_relaxed);
}

void sp_alloc_configure(void) {
    const char *mode = getenv("SP_ALLOC_TRACE");
    if (!mode || (strcmp(mode, "1") && strcmp(mode, "2")) || sp_alloc_on()) return;
    sp_alloc_min = sp_alloc_env("SP_ALLOC_TRACE_MIN_KIB", 256, SIZE_MAX / 1024) * 1024;
    sp_alloc_limit = sp_alloc_env("SP_ALLOC_TRACE_RATE_MIB", 128, SIZE_MAX / 1048576) * 1048576;
    sp_alloc_page_mask = (size_t)getpagesize() - 1;
    mach_timebase_info(&sp_alloc_timebase);
    sp_alloc_start = mach_absolute_time();
    void *storage = sp_lib_mmap(NULL, sizeof *sp_alloc_tracker, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANON, -1, 0);
    if (storage == MAP_FAILED) {
        static const char message[] = "SP_ALLOC_TRACE disabled=mmap_failed\n";
        sp_lib_write(STDERR_FILENO, message, sizeof message - 1);
        return;
    }
    sp_alloc_tracker = storage;
    pthread_t watch;
    if (pthread_atfork(NULL, NULL, sp_alloc_child) || pthread_create(&watch, NULL, sp_alloc_watch, NULL)) {
        static const char message[] = "SP_ALLOC_TRACE disabled=watch_init_failed\n";
        sp_lib_write(STDERR_FILENO, message, sizeof message - 1);
        sp_lib_munmap(storage, sizeof *sp_alloc_tracker);
        return;
    }
    pthread_detach(watch);
    if (!strcmp(mode, "2")) {
        static const char message[] = "SP_ALLOC_TRACE requested=2 effective=1 malloc_logger=unsupported\n";
        sp_lib_write(STDERR_FILENO, message, sizeof message - 1);
    }
    static const char imports[] = "SP_ALLOC_IMPORTS status=unavailable reason=guest-bind-stream-not-inspected\n";
    sp_lib_write(STDERR_FILENO, imports, sizeof imports - 1);
    sp_mem_enable();
    atomic_store_explicit(&sp_alloc_enabled, true, memory_order_release);
    // UIKit can start before flavor selection. Schedule from trace setup so the
    // timer follows game launch even if the launcher spent time on its menus.
    void (*schedule)(void (*)(void)) = sp_real_dlsym(RTLD_DEFAULT, "sp_stats_schedule_threadpool");
    if (schedule) schedule(sp_threadpool_dump);
}
