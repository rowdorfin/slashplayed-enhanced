#!/usr/bin/env python3
"""Phase 1: generate skeleton shim dylibs from bucket.py's imports.json.

Usage: gen_stubs.py <recon-dir> <shim-dir> <thin-arm64-binary>...

<recon-dir> holds imports.json (bucket.py's, merged over every flavor's client by
scripts/recon/regen.sh) and the SDK index. The binaries are the flavors' thinned clients; their load
commands are merged (they load the same libraries). For every library they load that visionOS lacks,
or that is missing some imported symbols, writes <shim-dir>/libsp<Name>.m with a logging stub per
missing symbol, plus:
  <shim-dir>/build.sh         `build.sh <xros|ios> <out-dir>` builds every shim for that platform
  <shim-dir>/rewrite-map.txt  original install name -> visionOS install name, per load command
The output is committed (shims/generated/), so nothing in it may depend on this machine: #includes
of hand-written sources are relative to <shim-dir>, and the platform is build.sh's argument. Only
the buckets come from SP_PLATFORM's SDK; regen.sh checks that both platforms agree.

A shim re-exports the real visionOS library when one exists, so it only adds what's missing.
Symbols visionOS exports from a different library are re-exported from that library.
Libraries in HANDWRITTEN get no generated source; build.sh runs their own build script instead.
"""
import ctypes
import json
import os
import pickle
import re
import subprocess
import sys
from collections import defaultdict

# Public visionOS libraries to link when re-exporting a symbol whose provider is private.
PUBLIC_PARENT = {
    "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore": "UIKit",
    "/System/Library/PrivateFrameworks/UIFoundation.framework/UIFoundation": "UIKit",
}

# Typed data stubs where a zeroed blob would be wrong. Name -> C definition (use NAME for the symbol).
DATA_OVERRIDES = {
    # macOS 14 AppKit; the game may gate features on it.
    "_NSAppKitVersionNumber": "const double NAME = 2487.3;",
    # Set by the AppKit shim's NSApplication once it exists.
    "_NSApp": "id NAME = nil;",
}

# Function stubs with real bodies: symbol -> C definition (NAME = the asm-labelled identifier).
# SP_CALLER is the caller's offset in the main executable, so hits from one call site can be told apart.
STATUS_STRING = """const char *NAME(int32_t err) {
    static atomic_int n;
    if (atomic_fetch_add(&n, 1) < 50) {
        char buf[96];
        snprintf(buf, sizeof buf, "FUNC(%d) from +0x%lx", err, SP_CALLER);
        sp_stub_log(buf);
    }
    return "";
}"""
FUNC_OVERRIDES = {
    # The client formats OSStatus errors with these; log each one (the value says what failed).
    "_GetMacOSStatusCommentString": STATUS_STRING.replace("FUNC", "GetMacOSStatusCommentString"),
    "_GetMacOSStatusErrorString": STATUS_STRING.replace("FUNC", "GetMacOSStatusErrorString"),
}

# Hand-written code appended to a generated shim: library -> Objective-C source. A function defined
# here (or in an EXTRA_INCLUDES file) with __asm__("_symbol") replaces that symbol's generated stub.
EXTRA_CODE = {
    # AppKit's NSBundle(NSNibLoading) category doesn't exist on visionOS; the client loads a nib at
    # startup and its uncaught-exception handler exits(1) on the unrecognized selector. There's no
    # nib: report success with no top-level objects.
    "AppKit": """
@implementation NSBundle (SPNibLoading)
- (BOOL)loadNibNamed:(NSString *)name owner:(id)owner topLevelObjects:(NSArray **)objects {
    sp_stub_log([NSString stringWithFormat:@"-[NSBundle loadNibNamed:%@ owner:<%s>] (no nib)", name,
                 object_getClassName(owner)].UTF8String);
    if (objects) *objects = @[];
    return YES;
}
@end
""",
    # Text Input Sources: the client reads the current keyboard layout at startup and hands what it
    # gets to CoreFoundation, so NULL crashes it. One input source, the US layout, with real CF
    # property values. Its uchr data is a zeroed placeholder: UCKeyTranslate (CoreServices shim)
    # doesn't read it.
    "Carbon": """
static NSDictionary *sp_input_source(void) {
    static NSDictionary *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = @{
            sp_kTISPropertyInputSourceID: @"com.apple.keylayout.US",
            sp_kTISPropertyLocalizedName: @"U.S.",
            sp_kTISPropertyInputSourceCategory: sp_kTISCategoryKeyboardInputSource,
            sp_kTISPropertyInputSourceIsEnabled: @YES,
            sp_kTISPropertyInputSourceIsSelected: @YES,
            sp_kTISPropertyInputSourceIsSelectCapable: @YES,
            sp_kTISPropertyInputSourceLanguages: @[ @"en" ],
            sp_kTISPropertyUnicodeKeyLayoutData: [NSMutableData dataWithLength:4096],
        };
    });
    return source;
}

CFTypeRef sp_TISCopyCurrentKeyboardInputSource(void) __asm__("_TISCopyCurrentKeyboardInputSource");
CFTypeRef sp_TISCopyCurrentKeyboardInputSource(void) { SP_LOG_ONCE("TISCopyCurrentKeyboardInputSource"); return CFBridgingRetain(sp_input_source()); }
CFTypeRef sp_TISCopyCurrentKeyboardLayoutInputSource(void) __asm__("_TISCopyCurrentKeyboardLayoutInputSource");
CFTypeRef sp_TISCopyCurrentKeyboardLayoutInputSource(void) { SP_LOG_ONCE("TISCopyCurrentKeyboardLayoutInputSource"); return CFBridgingRetain(sp_input_source()); }
CFTypeRef sp_TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) __asm__("_TISCopyCurrentASCIICapableKeyboardLayoutInputSource");
CFTypeRef sp_TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { SP_LOG_ONCE("TISCopyCurrentASCIICapableKeyboardLayoutInputSource"); return CFBridgingRetain(sp_input_source()); }

CFArrayRef sp_TISCreateInputSourceList(CFDictionaryRef props, Boolean all) __asm__("_TISCreateInputSourceList");
CFArrayRef sp_TISCreateInputSourceList(CFDictionaryRef props, Boolean all) {
    SP_LOG_ONCE("TISCreateInputSourceList");
    return CFBridgingRetain(@[ sp_input_source() ]);
}

void *sp_TISGetInputSourceProperty(CFTypeRef source, CFStringRef key) __asm__("_TISGetInputSourceProperty");
void *sp_TISGetInputSourceProperty(CFTypeRef source, CFStringRef key) {
    id value = source && key ? ((__bridge NSDictionary *)source)[(__bridge NSString *)key] : nil;
    if (!value) sp_stub_log([NSString stringWithFormat:@"TISGetInputSourceProperty(%@) = NULL",
                             (__bridge NSString *)key].UTF8String);
    return (__bridge void *)value;
}

int32_t sp_TISSelectInputSource(CFTypeRef source) __asm__("_TISSelectInputSource");
int32_t sp_TISSelectInputSource(CFTypeRef source) { SP_LOG_ONCE("TISSelectInputSource"); return 0; }
// The client indexes the result (macOS 26 returns 229 entries, one per symbolic hotkey id). No macOS
// system hotkeys reach an app here, so every entry is a disabled one.
int32_t sp_CopySymbolicHotKeys(CFArrayRef *out) __asm__("_CopySymbolicHotKeys");
int32_t sp_CopySymbolicHotKeys(CFArrayRef *out) {
    SP_LOG_ONCE("CopySymbolicHotKeys (256 disabled)");
    if (!out) return -50;  // paramErr
    NSDictionary *off = @{@"kHISymbolicHotKeyCode": @0xFFFF, @"kHISymbolicHotKeyModifiers": @0,
                          @"kHISymbolicHotKeyEnabled": @NO};
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:256];
    for (int i = 0; i < 256; i++) [a addObject:off];
    *out = CFBridgingRetain([a copy]);
    return 0;
}

// An ANSI keyboard: kbd type 40, layout kKeyboardANSI.
uint8_t sp_LMGetKbdType(void) __asm__("_LMGetKbdType");
uint8_t sp_LMGetKbdType(void) { return 40; }
uint32_t sp_KBGetLayoutType(int16_t kbdType) __asm__("_KBGetLayoutType");
uint32_t sp_KBGetLayoutType(int16_t kbdType) { return 'ANSI'; }
""",
    # Device observers are macOS-only; visionOS has one GPU and it doesn't come or go. Without a
    # device here the client logs "No suitable gpu found" and quits.
    "Metal": """
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "../metal/spa16profile.h"
#include "../../apps/client/sphwprofile.h"
#include <stdlib.h>
#include <string.h>

#ifndef SP_A16_BUILD_SHA
#define SP_A16_BUILD_SHA "unknown"
#endif

static bool spNativeHardwareProfile(void) {
    const char *profile = getenv("SP_HW_PROFILE");
    return profile && strcmp(profile, "native") == 0;
}

static bool spA16Profile(void) {
    static dispatch_once_t once;
    static bool active;
    dispatch_once(&once, ^{
        const char *value = getenv("SP_A16_PROFILE");
        active = !spNativeHardwareProfile() && value && strcmp(value, "1") == 0;
    });
    return active;
}

static char spA16SessionDeviceKey;
static bool spA16GuestCaller(void *returnAddress);
static void spBCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#import <objc/message.h>
#include <errno.h>
#include <stdarg.h>

#ifndef SP_METAL_DIAG
#define SP_METAL_DIAG 1
#endif
#if SP_METAL_DIAG
#include <fcntl.h>
#include <os/lock.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

CFArrayRef sp_MTLCopyAllDevicesWithObserver(void **observer, id handler) __asm__("_MTLCopyAllDevicesWithObserver");
// MTLDevice properties that only macOS has, added to the device's class with the values of a
// built-in, always-on GPU. Each logs its first use.
#define SP_DEVICE_PROP(name, type, value) \\
    static type sp_dev_##name(id self, SEL _cmd) { \\
        SP_LOG_ONCE("-[MTLDevice " #name "] (macOS-only, " #value ")"); \\
        return value; \\
    }
SP_DEVICE_PROP(isLowPower, BOOL, NO)
SP_DEVICE_PROP(isHeadless, BOOL, NO)
SP_DEVICE_PROP(isRemovable, BOOL, NO)
SP_DEVICE_PROP(location, NSUInteger, 0)  // MTLDeviceLocationBuiltIn
SP_DEVICE_PROP(locationNumber, NSUInteger, 0)
SP_DEVICE_PROP(maxTransferRate, uint64_t, 0)
SP_DEVICE_PROP(peerGroupID, uint64_t, 0)
SP_DEVICE_PROP(peerIndex, uint32_t, 0)
SP_DEVICE_PROP(peerCount, uint32_t, 1)
SP_DEVICE_PROP(isDepth24Stencil8PixelFormatSupported, BOOL, NO)

// visionOS refuses metallib containers older than v2.6 (no platform field) when the header's macOS
// flag is set, with MTLLibraryErrorDomain Code=1. The client's embedded libraries are all v2.2. Clearing
// the flag (bit 15 of the target field) in a copy is all it takes (research/metaltest).
// The client's buffer is never written.
static id (*sp_newLibraryWithData_orig)(id, SEL, dispatch_data_t, NSError **);
static id sp_newLibraryWithData(id self, SEL _cmd, dispatch_data_t data, NSError **error) {
    const void *p;
    size_t n;
    // b points into map, which must outlive the failure log below.
    __attribute__((objc_precise_lifetime)) dispatch_data_t map = dispatch_data_create_map(data, &p, &n);
    const uint8_t *b = p;
    if (n >= 16 && !memcmp(b, "MTLB", 4) && (b[5] & 0x80) && b[6] == 2 && b[7] == 0 && b[8] < 6 && b[9] == 0) {
        static int retagged;
        if (retagged++ == 0)
            sp_stub_log([NSString stringWithFormat:@"newLibraryWithData: clearing macOS flag of v2.%d metallib (%zu bytes)", b[8], n].UTF8String);
        uint8_t *copy = malloc(n);
        memcpy(copy, b, n);
        copy[5] &= 0x7f;
        data = dispatch_data_create(copy, n, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    }
    NSError *err = nil;
    id lib = sp_newLibraryWithData_orig(self, _cmd, data, &err);
    if (!lib)
        sp_stub_log([NSString stringWithFormat:@"newLibraryWithData: failed (%zu bytes, header %@): %@",
                     n, [NSData dataWithBytes:b length:n < 16 ? n : 16], err].UTF8String);
    if (error) *error = err;
    return lib;
}

// Frame counter: logs the first drawable (with the layer's geometry), every 600th, and any whose
// size changed, so a run shows whether the client is presenting at all and how it handles resizes.
static id (*sp_nextDrawable_orig)(id, SEL);
static _Atomic bool sp_drawable_trace;
static id sp_traceDrawable(id self, id d) {
    static _Atomic uint64_t frames;
    uint64_t n = ++frames;
    CGSize size = ((CAMetalLayer *)self).drawableSize;
    static _Atomic unsigned long long lastLayerSize;
    unsigned long long layerSize = ((unsigned long long)size.width << 32) | (unsigned long long)size.height;
    unsigned long long previous = atomic_exchange(&lastLayerSize, layerSize);
    BOOL changed = n > 1 && previous != layerSize;
    if (n == 1 || n % 600 == 0 || changed) {
        sp_stub_log([NSString stringWithFormat:@"-[CAMetalLayer nextDrawable] #%llu %gx%g -> %s",
                     (unsigned long long)n, size.width, size.height, d ? "ok" : "nil"].UTF8String);
        if (n == 1 || changed)
            sp_stub_log([NSString stringWithFormat:@"  layer frame %@ scale %@ gravity %@ superlayer bounds %@",
                         [self valueForKey:@"frame"], [self valueForKey:@"contentsScale"],
                         [self valueForKey:@"contentsGravity"], [self valueForKeyPath:@"superlayer.bounds"]].UTF8String);
    }
    return d;
}

static id sp_nextDrawableNative(id self, SEL _cmd) {
    return sp_traceDrawable(self, sp_nextDrawable_orig(self, _cmd));
}

static id sp_nextDrawable(id self, SEL _cmd) {
    static _Atomic unsigned long long lastPixels;
    static _Atomic bool reportedSize;
    id d = sp_nextDrawable_orig(self, _cmd);
    if (d && spA16GuestCaller(__builtin_return_address(0)) &&
        objc_getAssociatedObject(((CAMetalLayer *)self).device, &spA16SessionDeviceKey)) {
        id<MTLTexture> texture = [(id<CAMetalDrawable>)d texture];
        unsigned long long pixels = ((unsigned long long)texture.width << 32) | texture.height;
        if (pixels && atomic_exchange(&lastPixels, pixels) != pixels) {
            const char *phase = atomic_exchange(&reportedSize, true) ? "resize" : "session";
            NSString *line = [NSString stringWithFormat:
                @"SP_A16_PROFILE %s build=%s real=drawable:%lux%lu",
                phase, SP_A16_BUILD_SHA, (unsigned long)texture.width, (unsigned long)texture.height];
            spBCLog(@"%@", line);
        }
    }
    return atomic_load(&sp_drawable_trace) ? sp_traceDrawable(self, d) : d;
}

static void spBCInstall(id<MTLDevice> device, Class cls);
static void spA16Session(id<MTLDevice> device, bool native);
static bool spBCActive(id device);
static bool spBCVerbose;
static MTLSizeAndAlign spBCHeapSize(id device, SEL selector, MTLTextureDescriptor *descriptor,
                                  MTLSizeAndAlign (*real)(id, SEL, MTLTextureDescriptor *),
                                  MTLPixelFormat *physicalFormat);

#if SP_METAL_DIAG
enum { SP_METAL_DIAG_LIMIT = 1024 * 1024 };
static int sp_metal_diag_fds[2] = {-1, -1};
static unsigned sp_metal_diag_slot;
static size_t sp_metal_diag_bytes;
static char sp_metal_diag_device[384];
static os_unfair_lock sp_metal_diag_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t sp_metal_diag_sequence;

// The caller holds the rotation lock. Roll back a short write before appending another line.
static BOOL sp_metal_diag_append(int fd, const char *line, size_t len) {
    ssize_t written;
    do { written = write(fd, line, len); } while (written < 0 && errno == EINTR);
    if (written == (ssize_t)len) {
        sp_metal_diag_bytes += len;
        return YES;
    }
    if (written > 0 && ftruncate(fd, (off_t)sp_metal_diag_bytes) != 0)
        sp_metal_diag_bytes = SP_METAL_DIAG_LIMIT;  // force rotation after a partial line
    return NO;
}

static void sp_metal_diag_record(const char *line, bool mirrorToStderr) {
    size_t len = strlen(line);
    if (!len || line[len - 1] != '\\n') return;
    os_unfair_lock_lock(&sp_metal_diag_lock);
    int fd = sp_metal_diag_fds[sp_metal_diag_slot];
    if (sp_metal_diag_bytes + len > SP_METAL_DIAG_LIMIT) {
        unsigned next = sp_metal_diag_slot ^ 1;
        int next_fd = sp_metal_diag_fds[next];
        if (next_fd >= 0 && ftruncate(next_fd, 0) == 0) {
            fd = next_fd;
            sp_metal_diag_slot = next;
            sp_metal_diag_bytes = 0;
            sp_metal_diag_append(fd, sp_metal_diag_device, strlen(sp_metal_diag_device));
        }
    }
    // Each complete record reaches the kernel before Metal can abort this thread.
    BOOL saved = fd >= 0 && sp_metal_diag_bytes + len <= SP_METAL_DIAG_LIMIT
        && sp_metal_diag_append(fd, line, len);
    os_unfair_lock_unlock(&sp_metal_diag_lock);
    if (!saved) SP_LOG_ONCE("Metal diagnostic file write failed; see stderr/os_log");
    os_log(OS_LOG_DEFAULT, "[sp:Metal diag] %{public}s", line);
    if (mirrorToStderr) (void)write(STDERR_FILENO, line, len);
}

static void sp_metal_diag_write(const char *line) {
    sp_metal_diag_record(line, true);
}

static const char *sp_metal_diag_format(MTLPixelFormat format) {
#define SP_FORMAT(name) case MTLPixelFormat##name: return #name
    switch (format) {
        SP_FORMAT(Invalid);
        SP_FORMAT(R8Unorm);
        SP_FORMAT(R8Snorm);
        SP_FORMAT(RG8Unorm);
        SP_FORMAT(RG8Snorm);
        SP_FORMAT(RGBA8Unorm);
        SP_FORMAT(RGBA8Unorm_sRGB);
        SP_FORMAT(BGRA8Unorm);
        SP_FORMAT(BGRA8Unorm_sRGB);
        SP_FORMAT(RGBA16Float);
        SP_FORMAT(Depth32Float);
        case 255: return "Depth24Unorm_Stencil8";  // macOS-only enum name
        SP_FORMAT(Depth32Float_Stencil8);
        SP_FORMAT(BC1_RGBA);
        SP_FORMAT(BC1_RGBA_sRGB);
        SP_FORMAT(BC2_RGBA);
        SP_FORMAT(BC2_RGBA_sRGB);
        SP_FORMAT(BC3_RGBA);
        SP_FORMAT(BC3_RGBA_sRGB);
        SP_FORMAT(BC4_RUnorm);
        SP_FORMAT(BC4_RSnorm);
        SP_FORMAT(BC5_RGUnorm);
        SP_FORMAT(BC5_RGSnorm);
        SP_FORMAT(BC6H_RGBFloat);
        SP_FORMAT(BC6H_RGBUfloat);
        SP_FORMAT(BC7_RGBAUnorm);
        SP_FORMAT(BC7_RGBAUnorm_sRGB);
        default: return "unknown";
    }
#undef SP_FORMAT
}

static uint64_t sp_metal_diag_begin(SEL sel, MTLTextureDescriptor *d) {
    uint64_t seq = atomic_fetch_add_explicit(&sp_metal_diag_sequence, 1, memory_order_relaxed) + 1;
    uint64_t tid = 0;
    char thread[64] = "";
    pthread_threadid_np(NULL, &tid);
    pthread_getname_np(pthread_self(), thread, sizeof thread);
    thread[strcspn(thread, "\\r\\n")] = '\\0';
    struct timespec now = {0};
    clock_gettime(CLOCK_REALTIME, &now);
    char line[896];
    int prefix = snprintf(line, sizeof line,
                          "seq=%llu phase=before time=%lld.%09ld op=%s tid=%llu thread=\\"%s\\"",
                          (unsigned long long)seq, (long long)now.tv_sec, now.tv_nsec,
                          sel_getName(sel), (unsigned long long)tid, thread);
    if (prefix < 0 || (size_t)prefix >= sizeof line) return seq;
    if (d) {
        MTLPixelFormat format = d.pixelFormat;
        MTLTextureSwizzleChannels swizzle = d.swizzle;
        char compression[24] = "n/a";
        if ([d respondsToSelector:@selector(compressionType)])
            snprintf(compression, sizeof compression, "%lu", (unsigned long)d.compressionType);
        snprintf(line + prefix, sizeof line - (size_t)prefix,
                 " pixelFormat=%lu(%s) textureType=%lu width=%lu height=%lu depth=%lu"
                 " mipmapLevelCount=%lu arrayLength=%lu sampleCount=%lu storageMode=%lu"
                 " cpuCacheMode=%lu hazardTrackingMode=%lu resourceOptions=0x%lx usage=0x%lx"
                 " allowGPUOptimizedContents=%d compressionType=%s swizzle=%u,%u,%u,%u\\n",
                 (unsigned long)format, sp_metal_diag_format(format), (unsigned long)d.textureType,
                 d.width, d.height, d.depth, d.mipmapLevelCount, d.arrayLength, d.sampleCount,
                 (unsigned long)d.storageMode, (unsigned long)d.cpuCacheMode,
                 (unsigned long)d.hazardTrackingMode, (unsigned long)d.resourceOptions,
                 (unsigned long)d.usage, d.allowGPUOptimizedContents, compression,
                 (unsigned)swizzle.red, (unsigned)swizzle.green,
                 (unsigned)swizzle.blue, (unsigned)swizzle.alpha);
    } else {
        snprintf(line + prefix, sizeof line - (size_t)prefix, " descriptor=nil\\n");
    }
    sp_metal_diag_write(line);
    return seq;
}

static void sp_open_metal_diag(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents) {
        NSArray<NSString *> *names = @[@"sp-metal-diag.log", @"sp-metal-diag.1.log"];
        NSArray<NSString *> *previous = @[@"sp-metal-diag.prev.log", @"sp-metal-diag.prev.1.log"];
        for (unsigned i = 0; i < 2; ++i) {
            NSString *path = [documents stringByAppendingPathComponent:names[i]];
            NSString *backup = [documents stringByAppendingPathComponent:previous[i]];
            if (rename(path.fileSystemRepresentation, backup.fileSystemRepresentation) != 0 && errno != ENOENT) {
                SP_LOG_ONCE("Metal diagnostic log could not be archived; preserving the existing file");
                continue;
            }
            sp_metal_diag_fds[i] = open(path.fileSystemRepresentation,
                                      O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0600);
        }
    }

    if (sp_metal_diag_fds[0] < 0) sp_metal_diag_slot = 1;
}

// Called once before handing out the device on an instrumented entry point.
static void sp_install_metal_diag(id<MTLDevice> dev, Class cls, bool installSizing) {
    SEL selector = @selector(heapTextureSizeAndAlignWithDescriptor:);
    Method method = class_getInstanceMethod(cls, selector);
    const char *bc = "n/a";
    if ([dev respondsToSelector:@selector(supportsBCTextureCompression)])
        bc = dev.supportsBCTextureCompression ? "yes" : "no";
    NSString *name = dev.name;
    char header[sizeof sp_metal_diag_device] = {0};
    snprintf(header, sizeof header,
             "SP_METAL_DIAG=1 device=\\"%.96s\\" class=%.96s Apple7=%d Apple8=%d Apple9=%d Mac2=%d"
             " supportsBCTextureCompression=%s selector=%s hook=%s\\n",
             name.UTF8String ?: "n/a", class_getName(cls),
             [dev supportsFamily:MTLGPUFamilyApple7], [dev supportsFamily:MTLGPUFamilyApple8],
             [dev supportsFamily:MTLGPUFamilyApple9], [dev supportsFamily:MTLGPUFamilyMac2], bc,
             sel_getName(selector), !installSizing ? "capabilities-only" : method ? "installed" : "missing");
    os_unfair_lock_lock(&sp_metal_diag_lock);
    memcpy(sp_metal_diag_device, header, sizeof header);
    os_unfair_lock_unlock(&sp_metal_diag_lock);
    sp_metal_diag_write(header);
    if (!installSizing || !method) return;

    // Install on the concrete class even when the original method is inherited.
    MTLSizeAndAlign (*original)(id, SEL, MTLTextureDescriptor *) =
        (MTLSizeAndAlign (*)(id, SEL, MTLTextureDescriptor *))method_getImplementation(method);
    IMP hook = imp_implementationWithBlock(^MTLSizeAndAlign(id self, MTLTextureDescriptor *descriptor) {
        int saved_errno = errno;
        BOOL fallback = spBCActive(self);
        // The fallback summary counts these queries. Keep full before/after
        // records available for replaying a Metal validation failure.
        BOOL trace = !fallback || spBCVerbose;
        uint64_t seq = trace ? sp_metal_diag_begin(selector, descriptor) : 0;
        MTLPixelFormat physical = MTLPixelFormatInvalid;
        errno = saved_errno;
        MTLSizeAndAlign result = fallback ? spBCHeapSize(self, selector, descriptor, original, &physical)
                                          : original(self, selector, descriptor);
        if (!trace) return result;
        saved_errno = errno;
        char line[192];
        if (fallback)
            snprintf(line, sizeof line, "seq=%llu phase=after size=%lu align=%lu physicalFormat=%lu(%s)\\n",
                     (unsigned long long)seq, result.size, result.align, (unsigned long)physical,
                     sp_metal_diag_format(physical));
        else
            snprintf(line, sizeof line, "seq=%llu phase=after size=%lu align=%lu\\n",
                     (unsigned long long)seq, result.size, result.align);
        sp_metal_diag_write(line);
        errno = saved_errno;
        return result;
    });
    class_replaceMethod(cls, selector, hook, method_getTypeEncoding(method));
}
#endif

static void spBCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void spBCLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
#if SP_METAL_DIAG
    sp_metal_diag_write([[line stringByAppendingString:@"\\n"] UTF8String]);
#else
    sp_stub_log(line.UTF8String);
#endif
}

static void sp_prepare_metal_device(id<MTLDevice> device, bool observer) {
    if (!device) return;
    Class cls = object_getClass(device);
    if (spNativeHardwareProfile()) {
        static dispatch_once_t native_once;
        dispatch_once(&native_once, ^{
#if SP_METAL_DIAG
            sp_open_metal_diag();
            sp_install_metal_diag(device, cls, false);
#endif
            spA16Session(device, true);
        });
        return;
    }
    bool sizing = observer || spA16Profile() ||
        ([device respondsToSelector:@selector(supportsBCTextureCompression)] && !device.supportsBCTextureCompression);
#if SP_METAL_DIAG
    static dispatch_once_t open_once, capabilities_once, sizing_once;
    dispatch_once(&open_once, ^{ sp_open_metal_diag(); });
    if (sizing) {
        dispatch_once(&sizing_once, ^{ sp_install_metal_diag(device, cls, true); });
    } else {
        dispatch_once(&capabilities_once, ^{ sp_install_metal_diag(device, cls, false); });
    }
#else
    (void)sizing;
#endif
    static dispatch_once_t bc_once;
    dispatch_once(&bc_once, ^{
        spA16Session(device, false);
        spBCInstall(device, cls);
        Method drawable = class_getInstanceMethod(NSClassFromString(@"CAMetalLayer"), @selector(nextDrawable));
        if (drawable) {
            sp_nextDrawable_orig = (void *)method_getImplementation(drawable);
            method_setImplementation(drawable, (IMP)sp_nextDrawable);
        }
    });
}

// The re-export remains the provider of the real device. The direct factory
// and the macOS observer compatibility entry point both prepare it.
id<MTLDevice> sp_MTLCreateSystemDefaultDevice(void) __asm__("_MTLCreateSystemDefaultDevice") NS_RETURNS_RETAINED;
id<MTLDevice> sp_MTLCreateSystemDefaultDevice(void) {
    typedef id<MTLDevice> (*Factory)(void) NS_RETURNS_RETAINED;
    static Factory real;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        real = (Factory)dlsym(RTLD_NEXT, "MTLCreateSystemDefaultDevice");
        if (!real || real == sp_MTLCreateSystemDefaultDevice) {
            void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY | RTLD_NOLOAD);
            real = metal ? (Factory)dlsym(metal, "MTLCreateSystemDefaultDevice") : NULL;
            if (metal) dlclose(metal);
            if (real == sp_MTLCreateSystemDefaultDevice) real = NULL;
        }
    });
    id<MTLDevice> device = real ? real() : nil;
    int saved_errno = errno;
    sp_prepare_metal_device(device, false);
    errno = saved_errno;
    return device;
}

static void sp_add_device_props(id dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (spNativeHardwareProfile()) {
            Method drawable = class_getInstanceMethod(NSClassFromString(@"CAMetalLayer"), @selector(nextDrawable));
            if (drawable) {
                sp_nextDrawable_orig = (void *)method_getImplementation(drawable);
                method_setImplementation(drawable, (IMP)sp_nextDrawableNative);
            }
        } else {
            atomic_store(&sp_drawable_trace, true);
        }
        Class c = object_getClass(dev);
        Method m = class_getInstanceMethod(c, @selector(newLibraryWithData:error:));
        sp_newLibraryWithData_orig = (void *)method_setImplementation(m, (IMP)sp_newLibraryWithData);
        struct { const char *sel, *types; IMP imp; } props[] = {
            {"isLowPower", "c@:", (IMP)sp_dev_isLowPower},
            {"isHeadless", "c@:", (IMP)sp_dev_isHeadless},
            {"isRemovable", "c@:", (IMP)sp_dev_isRemovable},
            {"location", "Q@:", (IMP)sp_dev_location},
            {"locationNumber", "Q@:", (IMP)sp_dev_locationNumber},
            {"maxTransferRate", "Q@:", (IMP)sp_dev_maxTransferRate},
            {"peerGroupID", "Q@:", (IMP)sp_dev_peerGroupID},
            {"peerIndex", "I@:", (IMP)sp_dev_peerIndex},
            {"peerCount", "I@:", (IMP)sp_dev_peerCount},
            {"isDepth24Stencil8PixelFormatSupported", "c@:", (IMP)sp_dev_isDepth24Stencil8PixelFormatSupported},
        };
        for (size_t i = 0; i < sizeof props / sizeof *props; i++)
            if (![dev respondsToSelector:sel_registerName(props[i].sel)])
                class_addMethod(c, sel_registerName(props[i].sel), props[i].imp, props[i].types);
    });
}

// The observer comes back +1, as Metal's __strong out parameter does: the client releases it after
// MTLRemoveDeviceObserver. (As id * under ARC it was autoreleased, and quitting crashed on the
// over-release.)
CFArrayRef sp_MTLCopyAllDevicesWithObserver(void **observer, id handler) {
    id<MTLDevice> dev = sp_MTLCreateSystemDefaultDevice();
    if (dev) {
        if (!spNativeHardwareProfile()) sp_prepare_metal_device(dev, true);
        sp_add_device_props(dev);
    }
    sp_stub_log([NSString stringWithFormat:@"MTLCopyAllDevicesWithObserver: %@", dev.name].UTF8String);
    if (observer) *observer = (void *)CFBridgingRetain([NSObject new]);
    return CFBridgingRetain(dev ? @[ dev ] : @[]);
}

void sp_MTLRemoveDeviceObserver(id observer) __asm__("_MTLRemoveDeviceObserver");
void sp_MTLRemoveDeviceObserver(id observer) {}
""",
    # UCKeyTranslate for the US layout, from a table instead of the uchr data (see Carbon above).
    # Shift and caps lock apply; dead keys and option/control layers don't exist here.
    "CoreServices": """
// Virtual key code -> (unshifted, shifted) character, for the US ANSI layout.
static const uint16_t sp_us_keys[128][2] = {
    [0x00] = {'a', 'A'}, [0x01] = {'s', 'S'}, [0x02] = {'d', 'D'}, [0x03] = {'f', 'F'},
    [0x04] = {'h', 'H'}, [0x05] = {'g', 'G'}, [0x06] = {'z', 'Z'}, [0x07] = {'x', 'X'},
    [0x08] = {'c', 'C'}, [0x09] = {'v', 'V'}, [0x0A] = {0xA7, 0xB1}, [0x0B] = {'b', 'B'},
    [0x0C] = {'q', 'Q'}, [0x0D] = {'w', 'W'}, [0x0E] = {'e', 'E'}, [0x0F] = {'r', 'R'},
    [0x10] = {'y', 'Y'}, [0x11] = {'t', 'T'}, [0x12] = {'1', '!'}, [0x13] = {'2', '@'},
    [0x14] = {'3', '#'}, [0x15] = {'4', '$'}, [0x16] = {'6', '^'}, [0x17] = {'5', '%'},
    [0x18] = {'=', '+'}, [0x19] = {'9', '('}, [0x1A] = {'7', '&'}, [0x1B] = {'-', '_'},
    [0x1C] = {'8', '*'}, [0x1D] = {'0', ')'}, [0x1E] = {']', '}'}, [0x1F] = {'o', 'O'},
    [0x20] = {'u', 'U'}, [0x21] = {'[', '{'}, [0x22] = {'i', 'I'}, [0x23] = {'p', 'P'},
    [0x24] = {'\\r', '\\r'}, [0x25] = {'l', 'L'}, [0x26] = {'j', 'J'}, [0x27] = {'\\'', '"'},
    [0x28] = {'k', 'K'}, [0x29] = {';', ':'}, [0x2A] = {'\\\\', '|'}, [0x2B] = {',', '<'},
    [0x2C] = {'/', '?'}, [0x2D] = {'n', 'N'}, [0x2E] = {'m', 'M'}, [0x2F] = {'.', '>'},
    [0x30] = {'\\t', '\\t'}, [0x31] = {' ', ' '}, [0x32] = {'`', '~'}, [0x33] = {0x08, 0x08},
    [0x35] = {0x1B, 0x1B}, [0x41] = {'.', '.'}, [0x43] = {'*', '*'}, [0x45] = {'+', '+'},
    [0x47] = {0x1B, 0x1B}, [0x4B] = {'/', '/'}, [0x4C] = {0x03, 0x03}, [0x4E] = {'-', '-'},
    [0x51] = {'=', '='}, [0x52] = {'0', '0'}, [0x53] = {'1', '1'}, [0x54] = {'2', '2'},
    [0x55] = {'3', '3'}, [0x56] = {'4', '4'}, [0x57] = {'5', '5'}, [0x58] = {'6', '6'},
    [0x59] = {'7', '7'}, [0x5B] = {'8', '8'}, [0x5C] = {'9', '9'},
    // function keys
    [0x60] = {0x10, 0x10}, [0x61] = {0x10, 0x10}, [0x62] = {0x10, 0x10}, [0x63] = {0x10, 0x10},
    [0x64] = {0x10, 0x10}, [0x65] = {0x10, 0x10}, [0x67] = {0x10, 0x10}, [0x6D] = {0x10, 0x10},
    [0x6F] = {0x10, 0x10}, [0x76] = {0x10, 0x10}, [0x78] = {0x10, 0x10}, [0x7A] = {0x10, 0x10},
    // home, page up, forward delete, end, page down, arrows
    [0x73] = {0x01, 0x01}, [0x74] = {0x0B, 0x0B}, [0x75] = {0x7F, 0x7F}, [0x77] = {0x04, 0x04},
    [0x79] = {0x0C, 0x0C}, [0x7B] = {0x1C, 0x1C}, [0x7C] = {0x1D, 0x1D}, [0x7D] = {0x1F, 0x1F},
    [0x7E] = {0x1E, 0x1E},
};

int32_t sp_UCKeyTranslate(const void *layout, uint16_t key, uint16_t action, uint32_t modifiers,
                          uint32_t kbdType, uint32_t options, uint32_t *deadKeyState,
                          unsigned long maxLen, unsigned long *actualLen, uint16_t *chars)
    __asm__("_UCKeyTranslate");
int32_t sp_UCKeyTranslate(const void *layout, uint16_t key, uint16_t action, uint32_t modifiers,
                          uint32_t kbdType, uint32_t options, uint32_t *deadKeyState,
                          unsigned long maxLen, unsigned long *actualLen, uint16_t *chars) {
    SP_LOG_ONCE("UCKeyTranslate");
    if (deadKeyState) *deadKeyState = 0;
    uint16_t c = key < 128 ? sp_us_keys[key][(modifiers & 0x02) != 0] : 0;  // shiftKey >> 8
    if ((modifiers & 0x04) && c >= 'a' && c <= 'z') c -= 'a' - 'A';           // alphaLock >> 8
    unsigned long n = c && maxLen ? 1 : 0;
    if (n) chars[0] = c;
    if (actualLen) *actualLen = n;
    return 0;
}
""",
}

# Hand-written source files #included at the end of a generated shim: library -> paths in the repo.
EXTRA_INCLUDES = {
    "Metal": ["shims/metal/spbcfallback.m"],
    # UIKit app and scene, sharing the main thread with the client's loop; window geometry over it;
    # bitmap/image/cursor objects for the client's cursor images; input events from UIKit; play-session
    # stats; the loading screen until the client's first frame; look highlights.
    "AppKit": ["shims/appkit/spuikit.m", "shims/appkit/spwindow.m", "shims/appkit/spimage.m",
               "shims/appkit/spevent.m", "shims/appkit/spstats.m", "shims/appkit/sploading.m",
               "shims/appkit/sphover.m"],
    # Audio: the client's HAL and AudioUnit calls, logged on their way to the real libraries.
    "CoreAudio": ["shims/audio/spcoreaudio.m"],
    "AudioToolbox": ["shims/audio/spaudiotoolbox.m"],
    # One display, the size of the scene window, so the client's drawable isn't capped at 1920x1080.
    # Cursor calls (mouselook freeze, warp) go to the AppKit shim.
    "CoreGraphics": ["shims/coregraphics/spdisplay.m"],
    # TLS for the Battle.net login (Secure Transport, SecTrust), logged on its way to Security; the
    # CSSM calls the client makes (a macOS-only API visionOS lacks) over CommonCrypto.
    "Security": ["shims/security/spssl.m", "shims/security/spcssm.m"],
    # IOKit registry and matching calls, logged (what the client reads about the machine).
    "IOKit": ["shims/ident/spiokit.c"],
    # CoreFoundation and Foundation calls about the environment (locale, time zone, OS version, prefs,
    # bundle info), logged with SP_SYSTEM_TRACE. CFUserNotification (the client's data setup dialog),
    # which has no alert server on the device.
    "CoreFoundation": ["shims/ident/spcf.c", "shims/appkit/spnotice.m"],
    "Foundation": ["shims/ident/spfoundation.m"],
}

# Libraries that get a shim even though visionOS has every symbol the client imports from them, so
# EXTRA_CODE/EXTRA_INCLUDES can wrap those symbols (the shim's own definitions win over its re-export).
FORCE_SHIM = {"CoreAudio", "AudioToolbox", "CoreFoundation"}

# Shims written by hand: library -> directory (relative to the repo) whose build.sh takes
# `<platform> <out-dir>`. libSystem's services the client's startup code rewrite through an alias
# mapping (debugger-prepared pages); it also builds libspdl.dylib, which has to be bundled next to it.
HANDWRITTEN = {
    "libSystem": "shims/system",
}
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))

# Data symbols that are NSString/CFString constants: give them a distinct non-nil value,
# because nil notification names and dictionary keys change meaning (e.g. observe everything).
STRING_CONSTANT = re.compile(
    r"(Notification|Key|Type|Mode|Name|Prompt|Arguments|ColorSpace|Aqua)$|^_kTIS|^_kSecOID|^_kDADisk|^_kAX"
)

HEADER = """// Generated by scripts/recon/gen_stubs.py. Edit the generator, not this file.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdio.h>

// To os_log and stderr (devicectl --console shows stderr; the device's os_log is hard to reach).
static void sp_stub_log(const char *what) {{
    os_log(OS_LOG_DEFAULT, "[sp:{lib}] stub hit: %{{public}}s", what);
    fprintf(stderr, "[sp:{lib}] stub hit: %s\\n", what);
}}

// The client's load address: libspSystem knows it (under the flavor launcher the client isn't image 0).
static unsigned long sp_client_base(void) {{
    static unsigned long (*f)(void);
    if (!f) f = (unsigned long (*)(void))dlsym(RTLD_DEFAULT, "sp_client_text");
    unsigned long base = f ? f() : 0;
    return base ? base : (unsigned long)_dyld_get_image_header(0);
}}

#define SP_CALLER ((unsigned long)__builtin_return_address(0) - sp_client_base())

#define SP_LOG_ONCE(what) do {{ \\
    static atomic_flag once = ATOMIC_FLAG_INIT; \\
    if (!atomic_flag_test_and_set(&once)) sp_stub_log(what); \\
}} while (0)

// Catch-all for stubbed classes: log every selector once (per class), then return zero/nil.
#define SP_STUB_CLASS_BODY \\
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {{ \\
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; \\
}} \\
+ (void)forwardInvocation:(NSInvocation *)inv {{ sp_log_selector(self, inv, YES); }} \\
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {{ \\
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; \\
}} \\
- (void)forwardInvocation:(NSInvocation *)inv {{ sp_log_selector([self class], inv, NO); }}

static void sp_log_selector(Class cls, NSInvocation *inv, BOOL isClass) {{
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{{ seen = [NSMutableSet set]; }});
    NSString *key = [NSString stringWithFormat:@"%c[%s %s]", isClass ? '+' : '-',
                     class_getName(cls), sel_getName(inv.selector)];
    BOOL first;
    @synchronized (seen) {{
        first = ![seen containsObject:key];
        [seen addObject:key];
    }}
    if (first) sp_stub_log(key.UTF8String);
    char zero[64] = {{0}};
    if (inv.methodSignature.methodReturnLength <= sizeof zero) [inv setReturnValue:zero];
}}
"""


def macos_superclass_chains(class_names, dylibs):
    """class -> [superclass, ..., root] as seen on the running macOS."""
    for path in dylibs:
        ctypes.CDLL(path)
    objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.class_getSuperclass.restype = ctypes.c_void_p
    objc.class_getSuperclass.argtypes = [ctypes.c_void_p]
    objc.class_getName.restype = ctypes.c_char_p
    objc.class_getName.argtypes = [ctypes.c_void_p]
    chains = {}
    for name in class_names:
        cls = objc.objc_getClass(name.encode())
        if not cls:
            raise SystemExit(f"class {name} not found on this Mac")
        chain = []
        cls = objc.class_getSuperclass(cls)
        while cls:
            chain.append(objc.class_getName(cls).decode())
            cls = objc.class_getSuperclass(cls)
        chains[name] = chain
    return chains


def c_ident(sym):
    return "sp_" + re.sub(r"\W", "_", sym.lstrip("_"))


def gen_shim(lib, records, chains, xros_classes, shim_dir):
    """Objective-C source for one shim."""
    out = [HEADER.format(lib=lib)]
    notes = sorted({r["note"] for r in records if r["stub"] and r.get("note")})
    out += [f"// Known difference, implement for real: {n}\n" for n in notes]
    funcs = [r for r in records if r["stub"] and r["kind"] == "function"]
    data = [r for r in records if r["stub"] and r["kind"] == "data"]
    classes = sorted({r["symbol"].split("$_", 1)[1] for r in records
                      if r["stub"] and r["kind"] in ("objc-class", "objc-metaclass")})
    other = [r for r in records if r["stub"] and r["kind"] not in
             ("function", "data", "objc-class", "objc-metaclass")]
    if other:
        raise SystemExit(f"{lib}: no stub strategy for {[(r['symbol'], r['kind']) for r in other]}")

    included = "".join(open(os.path.join(REPO, p)).read() for p in EXTRA_INCLUDES.get(lib, []))
    if funcs:
        out.append("// ---- functions: log once, return 0 in x0 (d0 and struct returns are undefined)\n")
        for r in sorted(funcs, key=lambda r: r["symbol"]):
            sym = r["symbol"]
            if f'__asm__("{sym}")' in EXTRA_CODE.get(lib, "") + included:
                continue  # implemented there
            if sym in FUNC_OVERRIDES:
                defn = FUNC_OVERRIDES[sym].replace("NAME", c_ident(sym))
                out.append(f'{defn.partition("{")[0].strip()} __asm__("{sym}");\n{defn}\n')
                continue
            out.append(f'void *{c_ident(sym)}(void) __asm__("{sym}");\n'
                       f'void *{c_ident(sym)}(void) {{ SP_LOG_ONCE("{sym[1:]}"); return 0; }}\n')
    if data:
        out.append("\n// ---- data\n")
        for r in sorted(data, key=lambda r: r["symbol"]):
            sym = r["symbol"]
            decl = c_ident(sym)
            if sym in DATA_OVERRIDES:
                defn = DATA_OVERRIDES[sym].replace("NAME", decl)
            elif STRING_CONSTANT.search(sym):
                defn = f'NSString *const {decl} = @"{sym[1:]}";'
            else:
                defn = f"const void *{decl}[8] = {{0}};  // unknown type: zeroed"
            # Re-declare with an asm label so the exported name is exactly the macOS symbol.
            head, _, init = defn.partition(" = ")
            out.append(f'extern {head} __asm__("{sym}");\n{defn}\n')

    # Ancestors missing on visionOS must be defined too, before their subclasses.
    to_define = {}  # class -> superclass, in definition order
    for name in classes:
        lineage = [name] + chains[name]
        for i in reversed(range(len(lineage) - 1)):
            if lineage[i] not in xros_classes:
                to_define.setdefault(lineage[i], lineage[i + 1])
    if to_define:
        out.append("\n// ---- classes (superclasses as on macOS)\n")
        for name, sup in to_define.items():
            out.append(f"@interface {name} : {sup}\n@end\n@implementation {name}\nSP_STUB_CLASS_BODY\n@end\n")
    if lib in EXTRA_CODE:
        out.append("\n// ---- hand-written (EXTRA_CODE)" + EXTRA_CODE[lib])
    for path in EXTRA_INCLUDES.get(lib, []):
        out.append(f'\n#include "{os.path.relpath(os.path.join(REPO, path), shim_dir)}"\n')
    return "".join(out)


# Compile the portable C sources directly, with the same sources as the host tests.
EXTRA_SOURCES = {"libspMetal": ("shims/metal/spbcdecode.c", "shims/metal/spbclayout.c",
                              "shims/metal/spbcstaging.c", "shims/metal/spbcastc.c")}


def shim_build_line(name, link, shim_dir):
    sources = [name + ".m"]
    sources += [os.path.relpath(os.path.join(REPO, path), shim_dir)
                for path in EXTRA_SOURCES.get(name, ())]
    build_sha = r' "-DSP_A16_BUILD_SHA=\"${SP_A16_BUILD_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}\""' if name == "libspMetal" else ""
    return (f'$CC -fobjc-arc -dynamiclib -O1 -Wno-objc-root-class{build_sha} {" ".join(sources)} -o "$OUT/{name}.dylib" '
            f"-install_name @rpath/{name}.dylib -framework Foundation {' '.join(link)}\n")


def main():
    import bucket

    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    out_dir, shim_dir, binaries = sys.argv[1], sys.argv[2], sys.argv[3:]
    records = json.load(open(os.path.join(out_dir, "imports.json")))
    sys.modules["__main__"].TbdIndex = bucket.TbdIndex  # for unpickling
    xros = bucket.load_xros_index(out_dir)
    os.makedirs(shim_dir, exist_ok=True)

    xros_classes = set()
    for syms in xros.exports.values():
        xros_classes.update(s[len("_OBJC_CLASS_$_"):] for s in syms if s.startswith("_OBJC_CLASS_$_"))

    dylibs = {}
    for binary in binaries:
        for lib, install in bucket.read_dylibs(binary).items():
            if dylibs.setdefault(lib, install) != install:
                raise SystemExit(f"{lib}: {binary} loads {install}, another client {dylibs[lib]}")
    by_lib = defaultdict(list)
    for r in records:
        by_lib[r["from"]].append(r)

    missing_classes = {r["symbol"].split("$_", 1)[1] for r in records
                       if r["stub"] and r["kind"].startswith("objc-")}
    chains = macos_superclass_chains(sorted(missing_classes), dylibs.values())

    rewrite, builds = [], []
    for lib, install in sorted(dylibs.items()):
        recs = by_lib.get(lib, [])
        real = xros.install_name_for(lib)
        needs_shim = real is None or lib in FORCE_SHIM or any(r["bucket"] != "available" for r in recs)
        if not needs_shim:
            rewrite.append((install, real))
            continue
        name = f"libsp{lib.removeprefix('lib')}"
        rewrite.append((install, f"@rpath/{name}.dylib"))
        if lib in HANDWRITTEN:
            builds.append((name, os.path.join(REPO, HANDWRITTEN[lib])))
            continue
        with open(os.path.join(shim_dir, name + ".m"), "w") as fh:
            fh.write(gen_shim(lib, recs, chains, xros_classes, shim_dir))

        link = []
        if real:
            if real.startswith("/usr/lib/"):
                # /usr/lib/libSystem.B.dylib -> -reexport-lSystem.B (resolves to the SDK's .tbd)
                link.append("-Wl,-reexport-l" + os.path.basename(real).removeprefix("lib").removesuffix(".dylib"))
            else:
                link.append(f"-Wl,-reexport_framework,{lib}")
        reexp = [r for r in recs if r["bucket"] == "different" and r["where"]]
        if reexp:
            with open(os.path.join(shim_dir, name + ".reexports"), "w") as fh:
                fh.write("".join(r["symbol"] + "\n" for r in reexp))
            link.append(f"-Wl,-reexported_symbols_list,{name}.reexports")
            for prov in sorted({r["where"] for r in reexp}):
                parent = PUBLIC_PARENT.get(prov)
                if parent:
                    link.append(f"-framework {parent}")
                elif "/usr/lib/system/" in prov:
                    pass  # libSystem is always linked
                else:
                    link.append(f"-framework {bucket.short_name(prov)}")
        builds.append((name, link))

    with open(os.path.join(shim_dir, "rewrite-map.txt"), "w") as fh:
        fh.write("".join(f"{a} -> {b}\n" for a, b in rewrite))
    with open(os.path.join(shim_dir, "build.sh"), "w") as fh:
        cases = "".join(f'  {p}) CC="xcrun --sdk {sdk} clang -target {target}" ;;\n'
                        for p, (sdk, target) in bucket.PLATFORMS.items())
        fh.write("#!/bin/sh\n# Generated by scripts/recon/gen_stubs.py. Builds every shim: ./build.sh <platform> <out-dir>\n"
                 "set -e\nPLATFORM=$1\n[ -n \"$2\" ] || { echo \"usage: $0 <platform> <out-dir>\" >&2; exit 1; }\n"
                 "mkdir -p \"$2\"\nOUT=$(cd \"$2\" && pwd)\ncd \"$(dirname \"$0\")\"\n"
                 f"case $PLATFORM in\n{cases}"
                 "  *) echo \"$0: unknown platform '$PLATFORM'\" >&2; exit 1 ;;\nesac\n")
        for name, link in builds:
            if isinstance(link, str):  # HANDWRITTEN: its directory
                fh.write(f'"{os.path.relpath(link, shim_dir)}/build.sh" "$PLATFORM" "$OUT"\n')
                continue
            fh.write(shim_build_line(name, link, shim_dir))
    os.chmod(os.path.join(shim_dir, "build.sh"), 0o755)
    print(f"{len(builds)} shims, {len(rewrite)} load commands mapped")


if __name__ == "__main__":
    main()
