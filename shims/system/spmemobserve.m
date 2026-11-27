// Allocation wrappers never enter this file. These are guest API observations
// and warning-time snapshots, so Foundation and dispatch are safe here.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <notify.h>
#include <os/lock.h>
#include <TargetConditionals.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

extern void *sp_real_dlsym(void *, const char *);
extern bool sp_client_contains_pc(uintptr_t);
extern bool sp_alloc_observing(void);

#define EXPORT(ret, name, params) \
    ret sp_observe_##name params __asm__("_" #name); \
    ret sp_observe_##name params
#define REAL(name) static __typeof__(&name) real_##name
REAL(task_info);
REAL(host_statistics64);
#if !TARGET_OS_OSX
static size_t (*real_os_proc_available_memory)(void);
#endif
REAL(getrlimit);
static dispatch_source_type_t vm_source_type;
typedef dispatch_source_t (*sp_dispatch_create_fn)(dispatch_source_type_t, uintptr_t, uintptr_t,
                                                    dispatch_queue_t) NS_RETURNS_RETAINED;
static sp_dispatch_create_fn real_dispatch_source_create;
REAL(dispatch_source_get_data);
REAL(notify_register_check);
REAL(notify_register_dispatch);
REAL(notify_register_mach_port);
REAL(notify_register_file_descriptor);
REAL(notify_register_signal);

enum { QUERY_CAP = 128, SOURCE_CAP = 32 };
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static struct query { char name[96], value[160]; unsigned long long count; } queries[QUERY_CAP];
static unsigned long long queries_dropped, sources_seen;
static unsigned sources_tracked;
static __weak dispatch_source_t sources[SOURCE_CAP];
static struct source_info {
    bool vm;
    unsigned long mask;
    uintptr_t queue;
    unsigned long long serial, reads;
    unsigned long observed;
} source_info[SOURCE_CAP];

void sp_mem_query(const char *name, const char *value) {
    char key[sizeof queries[0].name], result[sizeof queries[0].value];
    strlcpy(key, name, sizeof key);
    strlcpy(result, value, sizeof result);
    os_unfair_lock_lock(&lock);
    unsigned i = 0;
    for (; i < QUERY_CAP && queries[i].count; i++)
        if (!strcmp(queries[i].name, key) && !strcmp(queries[i].value, result)) break;
    if (i == QUERY_CAP) queries_dropped++;
    else if (!queries[i].count) {
        strlcpy(queries[i].name, key, sizeof queries[i].name);
        strlcpy(queries[i].value, result, sizeof queries[i].value);
        queries[i].count = 1;
    } else queries[i].count++;
    os_unfair_lock_unlock(&lock);
}

void sp_mem_sysctl(const char *name, int status, const void *value, size_t size) {
    if (!name || (strcmp(name, "hw.memsize") && strcmp(name, "hw.physmem") && strcmp(name, "hw.usermem") &&
                  strncmp(name, "vm.", 3) && strncmp(name, "kern.memorystatus", 17))) return;
    char decoded[160];
    if (status) snprintf(decoded, sizeof decoded, "error:%d", errno);
    else if (!value) snprintf(decoded, sizeof decoded, "size:%zu", size);
    else if (size == 4 || size == 8) {
        uint64_t n = 0;
        memcpy(&n, value, size);
        snprintf(decoded, sizeof decoded, "%llu", (unsigned long long)n);
    } else {
        uint32_t hash = 2166136261u;
        const unsigned char *bytes = value;
        for (size_t i = 0; i < size && i < 4096; i++) hash = (hash ^ bytes[i]) * 16777619u;
        snprintf(decoded, sizeof decoded, "bytes:%zu hash%s:%08x", size, size > 4096 ? "First4KiB" : "", hash);
    }
    sp_mem_query(name, decoded);
}

#define NUMBER(key, v) do { \
    char value[32]; \
    snprintf(value, sizeof value, "%llu", (unsigned long long)(v)); \
    sp_mem_query(key, value); \
} while (0)

EXPORT(kern_return_t, task_info, (task_name_t task, task_flavor_t flavor, task_info_t out,
                                  mach_msg_type_number_t *count)) {
    kern_return_t status = real_task_info(task, flavor, out, count);
    if (sp_alloc_observing() && flavor == TASK_VM_INFO) {
        int saved = errno;
        if (status == KERN_SUCCESS && *count >= TASK_VM_INFO_REV1_COUNT) {
            task_vm_info_data_t *vm = (void *)out;
            char value[160];
            snprintf(value, sizeof value, "footprint:%llu resident:%llu virtual:%llu compressed:%llu",
                     vm->phys_footprint, vm->resident_size, vm->virtual_size, vm->compressed);
            sp_mem_query("task_info(TASK_VM_INFO)", value);
        } else NUMBER("task_info(TASK_VM_INFO).status", status);
        errno = saved;
    }
    return status;
}

EXPORT(kern_return_t, host_statistics64, (host_t host, host_flavor_t flavor, host_info64_t out,
                                          mach_msg_type_number_t *count)) {
    kern_return_t status = real_host_statistics64(host, flavor, out, count);
    if (sp_alloc_observing()) {
        int saved = errno;
        char key[64], value[160];
        snprintf(key, sizeof key, "host_statistics64(%d)", flavor);
        if (status == KERN_SUCCESS && flavor == HOST_VM_INFO64 && *count >= HOST_VM_INFO64_COUNT) {
            vm_statistics64_data_t *vm = (void *)out;
            snprintf(value, sizeof value, "free:%u active:%u inactive:%u wired:%u compressor:%u",
                     vm->free_count, vm->active_count, vm->inactive_count, vm->wire_count, vm->compressor_page_count);
            sp_mem_query(key, value);
        } else {
            snprintf(value, sizeof value, "status:%d words:%u", status, status == KERN_SUCCESS ? *count : 0);
            sp_mem_query(key, value);
        }
        errno = saved;
    }
    return status;
}

#if !TARGET_OS_OSX
__attribute__((visibility("hidden"))) size_t sp_host_available_memory(void) {
    return real_os_proc_available_memory();
}

EXPORT(size_t, os_proc_available_memory, (void)) {
    size_t result = real_os_proc_available_memory();
    if (sp_alloc_observing()) {
        int saved = errno;
        NUMBER("os_proc_available_memory", result);
        errno = saved;
    }
    return result;
}

#endif

EXPORT(int, getrlimit, (int resource, struct rlimit *limit)) {
    int status = real_getrlimit(resource, limit);
    if (sp_alloc_observing()) {
        int saved = errno;
        char key[48], value[72];
        snprintf(key, sizeof key, "getrlimit(%d)", resource);
        if (!status) snprintf(value, sizeof value, "soft:%llu hard:%llu",
                              (unsigned long long)limit->rlim_cur, (unsigned long long)limit->rlim_max);
        else snprintf(value, sizeof value, "error:%d", saved);
        sp_mem_query(key, value);
        errno = saved;
    }
    return status;
}

static bool memory_name(const char *name) {
    return name && (strcasestr(name, "memorystatus") || strcasestr(name, "lowmemory") ||
                    strcasestr(name, "memorypressure") || strcasestr(name, "memorywarning") ||
                    strcasestr(name, "memory.pressure") || strcasestr(name, "memory.warning") ||
                    strcasestr(name, "memory_pressure") || strcasestr(name, "memory_warning"));
}

#define NOTIFY(name, params, args) \
    EXPORT(uint32_t, name, params) { \
        uint32_t status = real_##name args; \
        if (sp_alloc_observing() && memory_name(topic)) { \
            int saved = errno; \
            char key[96]; \
            snprintf(key, sizeof key, #name "(%.62s)", topic); \
            NUMBER(key, status); \
            errno = saved; \
        } \
        return status; \
    }

NOTIFY(notify_register_check, (const char *topic, int *token), (topic, token))
NOTIFY(notify_register_dispatch, (const char *topic, int *token, dispatch_queue_t queue, notify_handler_t handler),
       (topic, token, queue, handler))
NOTIFY(notify_register_mach_port, (const char *topic, mach_port_t *port, int flags, int *token),
       (topic, port, flags, token))
NOTIFY(notify_register_file_descriptor, (const char *topic, int *fd, int flags, int *token),
       (topic, fd, flags, token))
NOTIFY(notify_register_signal, (const char *topic, int signal, int *token), (topic, signal, token))

dispatch_source_t sp_observe_dispatch_source_create(dispatch_source_type_t, uintptr_t, uintptr_t,
                                                   dispatch_queue_t) __asm__("_dispatch_source_create") NS_RETURNS_RETAINED;
dispatch_source_t sp_observe_dispatch_source_create(dispatch_source_type_t type, uintptr_t handle,
                                                   uintptr_t mask, dispatch_queue_t queue) {
    dispatch_source_t result = real_dispatch_source_create(type, handle, mask, queue);
    if (!sp_alloc_observing() || !result ||
        (type != DISPATCH_SOURCE_TYPE_MEMORYPRESSURE && type != vm_source_type)) return result;
    int saved = errno;
    os_unfair_lock_lock(&lock);
    unsigned long long serial = ++sources_seen;
    bool tracked = sources_tracked < SOURCE_CAP;
    if (tracked) {
        unsigned i = sources_tracked++;
        // Weak references preserve ownership and clear on deallocation.
        sources[i] = result;
        source_info[i] = (struct source_info){type == vm_source_type, mask,
                                              (uintptr_t)(__bridge void *)queue, serial, 0, 0};
    }
    os_unfair_lock_unlock(&lock);
    char line[256];
    int n = snprintf(line, sizeof line, "SP_MEM_SOURCE event=create type=%s mask=0x%lx queue=%p count=%llu tracked=%d\n",
                     type == vm_source_type ? "vm" : "memorypressure", (unsigned long)mask,
                     (__bridge void *)queue, serial, tracked);
    if (n > 0 && (size_t)n < sizeof line) write(2, line, n);
    errno = saved;
    return result;
}

EXPORT(unsigned long, dispatch_source_get_data, (dispatch_source_t source)) {
    unsigned long data = real_dispatch_source_get_data(source);
    if (sp_alloc_observing()) {
        int saved = errno;
        os_unfair_lock_lock(&lock);
        unsigned count = sources_tracked;
        os_unfair_lock_unlock(&lock);
        for (unsigned i = 0; i < count; i++) {
            os_unfair_lock_lock(&lock);
            __attribute__((objc_precise_lifetime)) dispatch_source_t held = sources[i];
            bool match = held == source;
            if (match) {
                source_info[i].reads++;
                source_info[i].observed |= data;
            }
            os_unfair_lock_unlock(&lock);
            if (match) break;
        }
        errno = saved;
    }
    return data;
}

static unsigned long long (*physical_memory)(id, SEL);
static void (*add_observer)(id, SEL, id, SEL, NSNotificationName, id);
static id (*add_observer_block)(id, SEL, NSNotificationName, id, NSOperationQueue *, void (^)(NSNotification *));
#define FROM_GUEST sp_client_contains_pc((uintptr_t)__builtin_return_address(0))

static unsigned long long observe_physical_memory(id self, SEL sel) {
    bool guest = sp_alloc_observing() && FROM_GUEST;
    unsigned long long result = physical_memory(self, sel);
    if (guest) {
        int saved = errno;
        NUMBER("NSProcessInfo.physicalMemory", result);
        errno = saved;
    }
    return result;
}

static void observe_notification(bool guest, NSNotificationName name) {
    if (!guest || !memory_name(name.UTF8String)) return;
    char key[96];
    snprintf(key, sizeof key, "NSNotificationCenter(%.68s)", name.UTF8String);
    sp_mem_query(key, "registered");
}

static void observe_add(id self, SEL sel, id observer, SEL callback, NSNotificationName name, id object) {
    bool guest = sp_alloc_observing() && FROM_GUEST;
    add_observer(self, sel, observer, callback, name, object);
    int saved = errno;
    observe_notification(guest, name);
    errno = saved;
}

static id observe_add_block(id self, SEL sel, NSNotificationName name, id object,
                            NSOperationQueue *queue, void (^block)(NSNotification *)) {
    bool guest = sp_alloc_observing() && FROM_GUEST;
    id result = add_observer_block(self, sel, name, object, queue, block);
    int saved = errno;
    observe_notification(guest, name);
    errno = saved;
    return result;
}

void sp_mem_enable(void) {
    Class process = object_getClass(NSProcessInfo.processInfo);
    SEL sel = @selector(physicalMemory);
    Method method = class_getInstanceMethod(process, sel);
    if (method) {
        physical_memory = (__typeof__(physical_memory))method_getImplementation(method);
        class_replaceMethod(process, sel, (IMP)observe_physical_memory, method_getTypeEncoding(method));
    }
    Class center = object_getClass(NSNotificationCenter.defaultCenter);
    sel = @selector(addObserver:selector:name:object:);
    method = class_getInstanceMethod(center, sel);
    if (method) {
        add_observer = (__typeof__(add_observer))method_getImplementation(method);
        class_replaceMethod(center, sel, (IMP)observe_add, method_getTypeEncoding(method));
    }
    sel = @selector(addObserverForName:object:queue:usingBlock:);
    method = class_getInstanceMethod(center, sel);
    if (method) {
        add_observer_block = (__typeof__(add_observer_block))method_getImplementation(method);
        class_replaceMethod(center, sel, (IMP)observe_add_block, method_getTypeEncoding(method));
    }
}

void sp_mem_init(void *system) {
#define RESOLVE(name) do { real_##name = sp_real_dlsym(system, #name); if (!real_##name) __builtin_trap(); } while (0)
    RESOLVE(task_info);
    RESOLVE(host_statistics64);
    RESOLVE(getrlimit);
    RESOLVE(dispatch_source_create);
    // The legacy data symbol can exist even when the SDK hides the VM constant.
    vm_source_type = sp_real_dlsym(system, "_dispatch_source_type_vm");
    RESOLVE(dispatch_source_get_data);
    RESOLVE(notify_register_check);
    RESOLVE(notify_register_dispatch);
    RESOLVE(notify_register_mach_port);
    RESOLVE(notify_register_file_descriptor);
    RESOLVE(notify_register_signal);
#if !TARGET_OS_OSX
    RESOLVE(os_proc_available_memory);
#endif
#undef RESOLVE
}

void sp_mem_dump(bool warning) {
    @autoreleasepool {
        static unsigned long long reported[QUERY_CAP], reported_dropped;
        for (unsigned i = 0; i < QUERY_CAP; i++) {
            os_unfair_lock_lock(&lock);
            struct query q = queries[i];
            os_unfair_lock_unlock(&lock);
            if (!q.count) break;
            if (q.count == reported[i]) continue;
            reported[i] = q.count;
            dprintf(2, "SP_MEM_QUERIES name=%s value=%s count=%llu\n", q.name, q.value, q.count);
        }
        os_unfair_lock_lock(&lock);
        unsigned long long dropped = queries_dropped, seen = sources_seen;
        unsigned tracked = sources_tracked;
        os_unfair_lock_unlock(&lock);
        if (dropped != reported_dropped) {
            reported_dropped = dropped;
            dprintf(2, "SP_MEM_QUERIES dropped=%llu\n", dropped);
        }
        if (!warning) return;
        dprintf(2, "SP_MEM_SOURCE event=warning count=%llu dropped=%llu legacyAvailable=%d\n",
                seen, seen - tracked, vm_source_type != NULL);
        for (unsigned i = 0; i < tracked; i++) {
            os_unfair_lock_lock(&lock);
            dispatch_source_t source = sources[i];
            struct source_info sample = source_info[i];
            os_unfair_lock_unlock(&lock);
            if (!source) continue;
            dprintf(2, "SP_MEM_SOURCE event=sample id=%llu type=%s mask=0x%lx queue=%p data=0x%lx "
                       "guestReads=%llu guestDataOr=0x%lx\n",
                    sample.serial, sample.vm ? "vm" : "memorypressure", sample.mask, (void *)sample.queue,
                    real_dispatch_source_get_data(source), sample.reads, sample.observed);
        }
    }
}

__attribute__((visibility("hidden")))
kern_return_t sp_host_task_info(task_name_t task, task_flavor_t flavor, task_info_t out,
                               mach_msg_type_number_t *count) {
    return real_task_info(task, flavor, out, count);
}
