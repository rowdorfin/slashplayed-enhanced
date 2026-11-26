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
#include <os/lock.h>
#include <objc/runtime.h>
#include "../metal/spmetalmeter.h"
#include <time.h>

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

static void sp_stats_frame(void) {
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
        if (startTime > 0 && endTime > startTime && endTime < 1.8e10)  // seconds that still fit in uint64_t nanoseconds {
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
static void sp_stats_hook_gpu(Class c) {
    static BOOL done;
    Method m = done ? NULL : class_getInstanceMethod(c, @selector(commit));
    if (!m) return;
    done = YES;
    sp_stats_bc_key = sel_registerName(SP_BC_UPLOAD_CB_KEY);
    sp_stats_commit_orig = (void *)method_setImplementation(m, (IMP)sp_stats_commit);
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
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) memset(&vm, 0, sizeof vm);
    return [NSString stringWithFormat:@"footprint %llu MB (peak %llu), %zu MB left | thermal %s%s",
        vm.phys_footprint >> 20, vm.ledger_phys_footprint_peak >> 20, os_proc_available_memory() >> 20,
        sp_stats_thermal(), NSProcessInfo.processInfo.lowPowerModeEnabled ? ", low power" : ""];
}

static void sp_stats_line(void) {
    os_unfair_lock_lock(&sp_stats_lock);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double secs = (now - sp_stats_window_start) / 1e9;
    sp_stats_window_start = now;
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

static void *sp_stats_watch(void *unused) {
    (void)unused;
    for (;;) {
        sleep(30);
        @autoreleasepool { sp_stats_line(); }
    }
    return NULL;
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
            sp_stats_say([NSString stringWithFormat:@"lifecycle: %@ | %@%@", what, sp_stats_state(),
                         [thermal containsObject:name] ? @"" : sp_stats_scenes()].UTF8String);
        }];
    }
}
