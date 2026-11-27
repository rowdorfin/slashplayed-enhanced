// Play-session stats for triage. #included in the generated libspAppKit.m (gen_stubs.py
// EXTRA_INCLUDES), before sphover.m, whose present hooks call sp_stats_frame.
//
// Every 30 s one line: frames presented and the worst gap between two, how many gaps ran over 50 ms,
// the footprint jetsam counts (and its peak), what's left before the app's limit, and the thermal
// state. Lifecycle changes (scene activation, background, memory warnings, thermal and low-power
// changes) are logged as they happen. With SP_HOVER_OFF=1 the presents aren't hooked and fps reads 0.
// For the heat: CPU (the process's threads, summed, and the busiest three by name) and GPU (the time
// occupied time from the union of completed command-buffer intervals).
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <mach/vm_region.h>
#include <mach/vm_statistics.h>
#include <malloc/malloc.h>
#include <os/lock.h>
#include <objc/runtime.h>
#include "../metal/spmetalmeter.h"
#include "../metal/spmemorymeter.h"
#include <time.h>
#include <stddef.h>
#include <stdatomic.h>

extern size_t os_proc_available_memory(void);

// Its own lines, "[sp:AppKit] stats: …" and "[sp:AppKit] lifecycle: …", as sploading.m's: not through
// sp_stub_log, whose "stub hit:" is for the client's calls into stubs, which these aren't.
static void sp_stats_say(const char *s) {
    os_log(OS_LOG_DEFAULT, "[sp:AppKit] %{public}s", s);
    fprintf(stderr, "[sp:AppKit] %s\n", s);
}

static os_unfair_lock sp_stats_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t sp_stats_frames, sp_stats_last_ns, sp_stats_window_start;
static SPFrameHistogram sp_stats_histogram;
static SPGPUUnion sp_stats_gpu;
static uint64_t sp_stats_gpu_sum, sp_stats_cbs, sp_stats_bc_cbs, sp_stats_bc_sum, sp_stats_gpu_clipped;
static void (*sp_stats_commit_orig)(id, SEL);
static const void *sp_stats_bc_key;

static atomic_bool sp_stats_native;
static _Atomic uint64_t sp_stats_native_frames, sp_stats_native_last, sp_stats_native_slow, sp_stats_native_worst;
static _Atomic uint64_t sp_stats_native_gpu, sp_stats_native_cbs;

static void sp_stats_lock_profile(void) {
    const char *profile = getenv("SP_HW_PROFILE");
    atomic_store_explicit(&sp_stats_native, profile && !strcmp(profile, "native"), memory_order_relaxed);
}

static bool sp_stats_is_native(void) {
    return atomic_load_explicit(&sp_stats_native, memory_order_relaxed);
}

static void sp_stats_frame(void) {
    if (sp_stats_is_native()) {
        sp_stats_native_frames++;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t last = atomic_exchange(&sp_stats_native_last, now);
        if (!last) return;
        uint64_t gap = now - last;
        if (gap > 50000000) sp_stats_native_slow++;
        uint64_t worst = sp_stats_native_worst;
        while (gap > worst && !atomic_compare_exchange_weak(&sp_stats_native_worst, &worst, gap)) {}
        return;
    }
    os_unfair_lock_lock(&sp_stats_lock);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    sp_stats_frames++;
    if (sp_stats_last_ns) SPFrameAdd(&sp_stats_histogram, now - sp_stats_last_ns);
    sp_stats_last_ns = now;
    os_unfair_lock_unlock(&sp_stats_lock);
}

static void sp_stats_commit(id<MTLCommandBuffer> cb, SEL _cmd) {
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        CFTimeInterval startTime = done.GPUStartTime, endTime = done.GPUEndTime;
        bool hasBC = objc_getAssociatedObject(done, sp_stats_bc_key) != nil;
        os_unfair_lock_lock(&sp_stats_lock);
        sp_stats_cbs++;
        sp_stats_bc_cbs += hasBC;
        if (startTime > 0 && endTime > startTime && endTime < 1.8e10) {  // seconds that fit in uint64_t ns
            uint64_t start = (uint64_t)(startTime * 1e9), end = (uint64_t)(endTime * 1e9);
            if (end - start < 10000000000ULL) {
                sp_stats_gpu_sum += end - start;
                if (hasBC) sp_stats_bc_sum += end - start;
            }
            // Work whose callback missed an earlier window is reported as clipped.
            if (start < sp_stats_window_start) {
                start = sp_stats_window_start;
                sp_stats_gpu_clipped++;
            }
            SPGPUAdd(&sp_stats_gpu, start, end);
        }
        os_unfair_lock_unlock(&sp_stats_lock);
    }];
    sp_stats_commit_orig(cb, _cmd);
}

// Called from sp_hover_attach with the device's command buffer class, the same one the client's are.
static void sp_stats_commit_native(id<MTLCommandBuffer> cb, SEL _cmd) {
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        CFTimeInterval seconds = done.GPUEndTime - done.GPUStartTime;
        if (seconds > 0 && seconds < 10) sp_stats_native_gpu += (uint64_t)(seconds * 1e9);
        sp_stats_native_cbs++;
    }];
    sp_stats_commit_orig(cb, _cmd);
}

static void sp_stats_hook_gpu(Class c) {
    static BOOL done;
    Method m = done ? NULL : class_getInstanceMethod(c, @selector(commit));
    if (!m) return;
    done = YES;
    bool native = sp_stats_is_native();
    if (!native) sp_stats_bc_key = sel_registerName(SP_BC_UPLOAD_CB_KEY);
    sp_stats_commit_orig = (void *)method_setImplementation(m, native ? (IMP)sp_stats_commit_native : (IMP)sp_stats_commit);
}

// CPU use of the process (100 = one core), and its busiest three threads, from the scheduler's
// decaying per-thread usage.
static NSString *sp_stats_cpu(void) {
    thread_act_array_t threads;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return @"cpu ?";
    struct { int usage; char name[64]; } top[3] = {{0}};
    int total = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_extended_info_data_t info;
        mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) {
            total += info.pth_cpu_usage;
            for (int k = 0; k < 3; k++) {
                if (info.pth_cpu_usage <= top[k].usage) continue;
                memmove(&top[k + 1], &top[k], sizeof top[0] * (2 - k));
                top[k].usage = info.pth_cpu_usage;
                snprintf(top[k].name, sizeof top[k].name, "%s", info.pth_name[0] ? info.pth_name : "?");
                break;
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    NSMutableString *out = [NSMutableString stringWithFormat:@"cpu %d%% (%u threads:", total * 100 / TH_USAGE_SCALE, n];
    for (int k = 0; k < 3 && top[k].usage; k++)
        [out appendFormat:@"%s %s %d%%", k ? "," : "", top[k].name, top[k].usage * 100 / TH_USAGE_SCALE];
    [out appendString:@")"];
    return out;
}

static const char *sp_stats_thermal(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
    case NSProcessInfoThermalStateNominal: return "nominal";
    case NSProcessInfoThermalStateFair: return "fair";
    case NSProcessInfoThermalStateSerious: return "SERIOUS";
    case NSProcessInfoThermalStateCritical: return "CRITICAL";
    }
    return "?";
}

// Footprint (and its peak), what's left before the limit, thermal state.
static NSString *sp_stats_state(void) {
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) memset(&vm, 0, sizeof vm);
    return [NSString stringWithFormat:@"footprint %llu MB (peak %llu), %zu MB left | thermal %s%s | vmResident=%llu vmInternal=%llu vmCompressed=%llu",
        vm.phys_footprint >> 20, vm.ledger_phys_footprint_peak >> 20, os_proc_available_memory() >> 20,
        sp_stats_thermal(), NSProcessInfo.processInfo.lowPowerModeEnabled ? ", low power" : "",
        vm.resident_size, vm.internal, vm.compressed];
}

static void sp_stats_line(void) {
    os_unfair_lock_lock(&sp_stats_lock);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double secs = (now - sp_stats_window_start) / 1e9;
    sp_stats_window_start = now;
    if (sp_stats_is_native()) {
        os_unfair_lock_unlock(&sp_stats_lock);
        uint64_t frames = atomic_exchange(&sp_stats_native_frames, 0);
        uint64_t slow = atomic_exchange(&sp_stats_native_slow, 0);
        uint64_t worst = atomic_exchange(&sp_stats_native_worst, 0);
        uint64_t gpu = atomic_exchange(&sp_stats_native_gpu, 0);
        uint64_t cbs = atomic_exchange(&sp_stats_native_cbs, 0);
        sp_stats_say([NSString stringWithFormat:@"stats: %.1f fps, worst %llu ms, %llu over 50 ms | gpu %.0f%% (%.1f ms/frame, "
                     "%llu buffers) | %@ | %@", frames / secs, worst / 1000000, slow, gpu / (secs * 1e7),
                     frames ? gpu / 1e6 / frames : 0.0, cbs, sp_stats_cpu(), sp_stats_state()].UTF8String);
        return;
    }
    uint64_t frames = sp_stats_frames, gpu = sp_stats_gpu.busy, cbs = sp_stats_cbs;
    uint64_t sum = sp_stats_gpu_sum, evicted = sp_stats_gpu.evicted, clipped = sp_stats_gpu_clipped;
    uint64_t bcCbs = sp_stats_bc_cbs, bcSum = sp_stats_bc_sum;
    SPFrameHistogram h = sp_stats_histogram;
    sp_stats_frames = sp_stats_gpu_sum = sp_stats_cbs = sp_stats_bc_cbs = sp_stats_bc_sum = sp_stats_gpu_clipped = 0;
    sp_stats_gpu.count = sp_stats_gpu.busy = sp_stats_gpu.evicted = sp_stats_gpu.sealedThrough = 0;
    sp_stats_histogram = (SPFrameHistogram){0};
    os_unfair_lock_unlock(&sp_stats_lock);

    sp_stats_say([NSString stringWithFormat:@"stats: %.1f fps, worst %llu ms, %llu over 50 ms | gpu %.0f%% (%.1f ms/frame, "
                 "%llu buffers) | %@ | %@ | p50Ms=%u p95Ms=%u p99Ms=%u over33Ms=%llu "
                 "gpuSum=%.1f%% bcUploadBuffers=%llu bcUploadBufferSumMs=%.1f gpuEvictedRanges=%llu gpuClippedBuffers=%llu",
                 frames / secs, h.worst / 1000000, h.over50, gpu / (secs * 1e7),
                 frames ? gpu / 1e6 / frames : 0.0, cbs, sp_stats_cpu(), sp_stats_state(),
                 SPFramePercentile(&h, 50), SPFramePercentile(&h, 95), SPFramePercentile(&h, 99),
                 h.over33, sum / (secs * 1e7), bcCbs, bcSum / 1e6, evicted, clipped].UTF8String);
}

// Every scene, its state, and its windows (hidden, alpha, frame), for app and scene events: once the
// window vanished after the headset was off a while, though the scene reported active.
static NSString *sp_stats_scenes(void) {
    static const char *states[] = {"foreground active", "foreground inactive", "background"};
    NSMutableString *out = [NSMutableString string];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        long st = scene.activationState;
        [out appendFormat:@"\n    scene %p %s, session %@", scene, st >= 0 && st <= 2 ? states[st] : "unattached",
                          [scene.session.persistentIdentifier substringToIndex:8]];
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            [out appendFormat:@"\n      window %p%s%s alpha %.2f frame %@ layer sublayers %lu", w,
                              w.hidden ? " HIDDEN" : "", w.isKeyWindow ? " key" : "", w.alpha,
                              NSStringFromCGRect(w.frame), (unsigned long)w.rootViewController.view.layer.sublayers.count];
    }
    return out.length ? out : @"\n    no connected scenes";
}

static const char *sp_stats_vm_tag(unsigned tag) {
    switch (tag) {
    case 0: return "untagged";
    case SPVMTagMappedFile: return "mapped-file";
    case SPVMTagLedger: return "VM-ledger";
    case VM_MEMORY_MALLOC: return "MALLOC";
    case VM_MEMORY_MALLOC_SMALL: return "MALLOC_SMALL";
    case VM_MEMORY_MALLOC_TINY: return "MALLOC_TINY";
    case VM_MEMORY_MALLOC_LARGE: return "MALLOC_LARGE";
    case VM_MEMORY_MALLOC_HUGE: return "MALLOC_HUGE";
    case VM_MEMORY_MALLOC_LARGE_REUSABLE: return "MALLOC_LARGE_REUSABLE";
    case VM_MEMORY_MALLOC_LARGE_REUSED: return "MALLOC_LARGE_REUSED";
    case VM_MEMORY_MALLOC_NANO: return "MALLOC_NANO";
    case VM_MEMORY_MALLOC_MEDIUM: return "MALLOC_MEDIUM";
    case VM_MEMORY_IOKIT: return "IOKit";
    case VM_MEMORY_IOACCELERATOR: return "IOAccelerator";
    case VM_MEMORY_FOUNDATION: return "Foundation";
    case VM_MEMORY_COREGRAPHICS: return "CoreGraphics";
    case VM_MEMORY_COREGRAPHICS_DATA: return "CoreGraphics-data";
    case VM_MEMORY_COREGRAPHICS_SHARED: return "CoreGraphics-shared";
    case VM_MEMORY_COREGRAPHICS_FRAMEBUFFERS: return "CoreGraphics-framebuffers";
    case VM_MEMORY_COREGRAPHICS_BACKINGSTORES: return "CoreGraphics-backingstores";
    case VM_MEMORY_COREGRAPHICS_XALLOC: return "CoreGraphics-xalloc";
    case VM_MEMORY_JAVASCRIPT_JIT_EXECUTABLE_ALLOCATOR: return "JavaScript-JIT-executable";
    case VM_MEMORY_JAVASCRIPT_JIT_REGISTER_FILE: return "JavaScript-JIT-register";
    case VM_MEMORY_DYLIB: return "dylib";
    case VM_MEMORY_STACK: return "stack";
    default: return "unknown";
    }
}

static uint64_t sp_stats_vm_tags(const char *phase, unsigned long long warning) {
    SPVMTagPages tags[SPVMTagSlots] = {0};
    vm_address_t address = 0;
    natural_t depth = 0;
    unsigned regions = 0;
    kern_return_t status;
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        // The iOS SDK publishes the Mach VM recurse operation as vm_region_recurse_64.
        status = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
                                     (vm_region_recurse_info_t)&info, &count);
        if (status != KERN_SUCCESS) break;
        if (count < VM_REGION_SUBMAP_INFO_V0_COUNT_64 || !size || size > UINTPTR_MAX - address) {
            status = KERN_FAILURE;
            break;
        }
        if (info.is_submap) {
            depth++;
            continue;
        }
        SPVMTagAdd(tags, info.user_tag, info.external_pager, info.pages_dirtied, info.pages_swapped_out);
        regions++;
        address += size;
    }

    uint64_t mallocLarge = SPVMTagTotal(tags[VM_MEMORY_MALLOC_LARGE]) * vm_page_size;
    SPVMTagSample top[SPVMTagTopCount];
    unsigned topCount = SPVMTagTop(tags, top);
    double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6;
    NSMutableString *line = [NSMutableString stringWithFormat:
        @"SP_VM_TAGS phase=%s warning=%llu ms=%.2f regions=%u complete=%d kr=%d MiB(total/dirty/swapped)",
        phase, warning, ms, regions, status == KERN_INVALID_ADDRESS || status == KERN_NO_SPACE, status];
    double pageMiB = vm_page_size / 1048576.0;
    for (unsigned i = 0; i < topCount; i++) {
        unsigned tag = top[i].tag;
        SPVMTagPages pages = top[i].pages;
        [line appendFormat:@" %s(%u)=%.2f/%.2f/%.2f", sp_stats_vm_tag(tag), tag,
                           SPVMTagTotal(pages) * pageMiB, pages.dirty * pageMiB, pages.swapped * pageMiB];
    }
    sp_stats_say(line.UTF8String);
    return mallocLarge;
}

static uint64_t sp_stats_malloc_zones(const char *phase, unsigned long long warning) {
    uint64_t defaultInUse = 0;
    vm_address_t *addresses = NULL;
    unsigned count = 0;
    kern_return_t status = malloc_get_all_zones(mach_task_self(), NULL, &addresses, &count);
    NSMutableString *line = [NSMutableString stringWithFormat:
        @"SP_MALLOC_ZONES phase=%s warning=%llu kr=%d", phase, warning, status];
    if (status == KERN_SUCCESS) {
        [line appendFormat:@" zones=%u (inUse/allocated/blocks)", count];
        for (unsigned i = 0; i < count; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)addresses[i];
            if (!zone || !zone->introspect || !zone->introspect->statistics) continue;
            malloc_statistics_t stats = {0};
            malloc_zone_statistics(zone, &stats);
            const char *name = malloc_get_zone_name(zone);
            if (name && !strcmp(name, "DefaultMallocZone")) defaultInUse = stats.size_in_use;
            [line appendFormat:@" #%u(%s)=%zu/%zu/%u", i, name ?: "unnamed",
                               stats.size_in_use, stats.size_allocated, stats.blocks_in_use];
        }
    }
    sp_stats_say(line.UTF8String);
    return defaultInUse;
}

static void sp_stats_memory_sample(const char *phase, unsigned long long warning) {
    if (sp_stats_is_native()) return;
    uint64_t mallocLarge = sp_stats_vm_tags(phase, warning);
    uint64_t zoneInUse = sp_stats_malloc_zones(phase, warning);
    void (*sample)(uint64_t, uint64_t, bool) = dlsym(RTLD_DEFAULT, "sp_alloc_sample");
    if (sample) sample(mallocLarge, zoneInUse, !strcmp(phase, "warning"));
}

typedef void (*SPThreadpoolDump)(void);
static _Atomic(SPThreadpoolDump) sp_stats_threadpool_dump;
static atomic_bool sp_stats_threadpool_warned;

__attribute__((visibility("default")))
void sp_stats_schedule_threadpool(SPThreadpoolDump dump) {
    atomic_store_explicit(&sp_stats_threadpool_dump, dump, memory_order_release);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ dump(); });
}

static void *sp_stats_watch(void *unused) {
    (void)unused;
    for (;;) {
        sleep(30);
        @autoreleasepool {
            sp_stats_line();
            sp_stats_memory_sample("periodic", 0);
        }
    }
    return NULL;
}

static atomic_ullong sp_stats_memory_warnings;

static void sp_stats_memory_warning(void) {
    unsigned long long warnings = atomic_fetch_add_explicit(&sp_stats_memory_warnings, 1, memory_order_relaxed) + 1;
    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    bool measured = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS &&
        count * sizeof(natural_t) >= offsetof(task_vm_info_data_t, phys_footprint) + sizeof(vm.phys_footprint);
    sp_stats_say([NSString stringWithFormat:@"SP_MEM_PRESSURE source=UIKit level=warn warnings=%llu phys_footprint=%@",
                  warnings, measured ? @(vm.phys_footprint) : @"n/a"].UTF8String);
    // UIKit delivery and the Metal shim's dispatch-pressure trim are independent.
    // Match these samples to the timestamped SP_MEM_TRIM line when reading the log.
    dispatch_time_t followup = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
    SPThreadpoolDump dump = atomic_load_explicit(&sp_stats_threadpool_dump, memory_order_acquire);
    if (dump && !atomic_exchange_explicit(&sp_stats_threadpool_warned, true, memory_order_relaxed))
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ dump(); });
    sp_stats_memory_sample("warning", warnings);
    dispatch_after(followup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool { sp_stats_memory_sample("warning+2s", warnings); }
    });
}

static void sp_stats_start(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    os_unfair_lock_lock(&sp_stats_lock);
    sp_stats_window_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    sp_stats_gpu.count = sp_stats_gpu.busy = sp_stats_gpu.evicted = sp_stats_gpu.sealedThrough = 0;
    sp_stats_gpu_sum = sp_stats_cbs = sp_stats_bc_cbs = sp_stats_bc_sum = sp_stats_gpu_clipped = 0;
    sp_stats_frames = sp_stats_last_ns = 0;
    sp_stats_histogram = (SPFrameHistogram){0};
    os_unfair_lock_unlock(&sp_stats_lock);
    pthread_t t;
    pthread_create(&t, NULL, sp_stats_watch, NULL);
    pthread_detach(t);
    NSSet *thermal = [NSSet setWithObjects:NSProcessInfoThermalStateDidChangeNotification,
                                           NSProcessInfoPowerStateDidChangeNotification, nil];
    NSDictionary<NSNotificationName, NSString *> *events = @{
        UIApplicationWillResignActiveNotification: @"app will resign active",
        UIApplicationDidBecomeActiveNotification: @"app did become active",
        UIApplicationDidEnterBackgroundNotification: @"app entered background",
        UIApplicationWillEnterForegroundNotification: @"app will enter foreground",
        UIApplicationDidReceiveMemoryWarningNotification: @"MEMORY WARNING",
        UIApplicationWillTerminateNotification: @"app will terminate",
        UISceneWillConnectNotification: @"scene will connect",
        UISceneDidDisconnectNotification: @"scene disconnected",
        UISceneDidActivateNotification: @"scene activated",
        UISceneWillDeactivateNotification: @"scene will deactivate",
        UISceneDidEnterBackgroundNotification: @"scene entered background",
        UISceneWillEnterForegroundNotification: @"scene will enter foreground",
        NSProcessInfoThermalStateDidChangeNotification: @"thermal state changed",
        NSProcessInfoPowerStateDidChangeNotification: @"low power mode changed",
    };
    for (NSNotificationName name in events) {
        NSString *what = events[name];
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            if ([name isEqualToString:UIApplicationDidReceiveMemoryWarningNotification] && !sp_stats_is_native())
                sp_stats_memory_warning();
            sp_stats_say([NSString stringWithFormat:@"lifecycle: %@ | %@%@", what, sp_stats_state(),
                         [thermal containsObject:name] ? @"" : sp_stats_scenes()].UTF8String);
        }];
    }
}
