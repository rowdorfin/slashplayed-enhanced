// derived from Tolkara (MIT), Copyright (c) 2026 Vasilii Kharitonov and the Tolkara contributors
// SPDX-License-Identifier: MIT

#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <stdatomic.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <os/proc.h>
#include <stddef.h>
#include <stdlib.h>
#import <ptrauth.h>
#import "spbclayout.h"

#define RETAINED __attribute__((ns_returns_retained))

// The host layout tests use the public enum values without importing Metal.
_Static_assert(MTLTextureType2D == 2 && MTLTextureType2DArray == 3 && MTLTextureTypeCube == 5 &&
               MTLTextureTypeCubeArray == 6 && MTLTextureType3D == 7, "Metal texture types changed");
#define SPBC_CHECK_FORMAT(name) _Static_assert((unsigned long)MTLPixelFormat##name == (unsigned long)SPPixelFormat##name, "Metal format changed")
SPBC_CHECK_FORMAT(BC1_RGBA);
SPBC_CHECK_FORMAT(BC1_RGBA_sRGB);
SPBC_CHECK_FORMAT(BC2_RGBA);
SPBC_CHECK_FORMAT(BC2_RGBA_sRGB);
SPBC_CHECK_FORMAT(BC3_RGBA);
SPBC_CHECK_FORMAT(BC3_RGBA_sRGB);
SPBC_CHECK_FORMAT(BC4_RUnorm);
SPBC_CHECK_FORMAT(BC4_RSnorm);
SPBC_CHECK_FORMAT(BC5_RGUnorm);
SPBC_CHECK_FORMAT(BC5_RGSnorm);
SPBC_CHECK_FORMAT(BC6H_RGBFloat);
SPBC_CHECK_FORMAT(BC6H_RGBUfloat);
SPBC_CHECK_FORMAT(BC7_RGBAUnorm);
SPBC_CHECK_FORMAT(BC7_RGBAUnorm_sRGB);
SPBC_CHECK_FORMAT(R8Unorm);
SPBC_CHECK_FORMAT(R8Snorm);
SPBC_CHECK_FORMAT(RG8Unorm);
SPBC_CHECK_FORMAT(RG8Snorm);
SPBC_CHECK_FORMAT(RGBA8Unorm);
SPBC_CHECK_FORMAT(RGBA8Unorm_sRGB);
SPBC_CHECK_FORMAT(RGBA16Float);
#undef SPBC_CHECK_FORMAT

// Provided by the generated shim so BC events share the T002 writer and rotation.
static void spBCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

typedef enum {
    SPBCSurface, SPBCBufferTexture, SPBCReplace, SPBCReplaceSlice, SPBCPrivateReplace,
    SPBCPrivateReplaceSlice, SPBCRead,
    SPBCReadSlice, SPBCView, SPBCViewRange, SPBCViewSwizzle, SPBCViewDescriptor,
    SPBCBufferCopy, SPBCBufferCopyOptions, SPBCPrivateSource, SPBCPrivateSourceOptions,
    SPBCReadBlit, SPBCReadBlitOptions, SPBCTextureCopy, SPBCTextureRegion,
    SPBCTextureLevels, SPBCUnsupportedCount
} SPBCUnsupported;

static _Atomic unsigned long long spBCUnsupported[SPBCUnsupportedCount];
static _Atomic unsigned long long spBCFormats[24], spBCCompressed, spBCDecoded;
static _Atomic unsigned long long spBCStagingReserved, spBCReservedPeak, spBCDecodeTicks, spBCMaxTicks;
static _Atomic unsigned long long spBCStagingLive, spBCStagingPeak;
static _Atomic unsigned long long spBCStagingFailures, spBCTextureFailures;
static NSHashTable<id<MTLHeap>> *spBCHeaps;
static _Atomic unsigned long long spBCSizingQueries;

static void spBCMax(_Atomic unsigned long long *maximum, unsigned long long value) {
    unsigned long long previous = atomic_load(maximum);
    while (previous < value && !atomic_compare_exchange_weak(maximum, &previous, value)) {}
}

// The existing texture metadata doubles as a lifetime sentinel. It owns no
// Metal objects. Views count as objects, with their backing charged to the root.
@interface SPBCTextureInfo : NSObject
@property (nonatomic) MTLPixelFormat requested;
@property (nonatomic) SPBCKind kind;
@property (nonatomic) size_t trackedBytes;
@end

typedef struct {
    unsigned long long allocated, freed, liveBytes;
} SPBCTextureStats;
static SPBCTextureStats spBCTextureStats;

@implementation SPBCTextureInfo
- (void)dealloc {
    @synchronized ([SPBCTextureInfo class]) {
        spBCTextureStats.freed++;
        spBCTextureStats.liveBytes -= _trackedBytes;
    }
}
@end

static void spBCSummary(id<MTLDevice> device) {
    SPBCTextureStats textures;
    @synchronized ([SPBCTextureInfo class]) { textures = spBCTextureStats; }
    // Take a short-lived snapshot, then query Metal without the registry lock.
    NSArray<id<MTLHeap>> *heaps;
    @synchronized (spBCHeaps) { heaps = spBCHeaps.allObjects; }
    unsigned long long heapBytes = 0, heapAllocated = 0, heapUsed = 0;
    NSUInteger allocatedSamples = 0, usedSamples = 0;
    for (id<MTLHeap> heap in heaps) {
        heapBytes += heap.size;
        if ([heap respondsToSelector:@selector(currentAllocatedSize)]) {
            heapAllocated += heap.currentAllocatedSize;
            allocatedSamples++;
        }
        if ([heap respondsToSelector:@selector(usedSize)]) {
            heapUsed += heap.usedSize;
            usedSamples++;
        }
    }

    task_vm_info_data_t vm = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    bool haveFootprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS &&
        count * sizeof(natural_t) >= offsetof(task_vm_info_data_t, phys_footprint) + sizeof(vm.phys_footprint);
    bool haveDeviceSize = [device respondsToSelector:@selector(currentAllocatedSize)];
    NSMutableString *formats = [NSMutableString string];
    NSMutableString *unsupported = [NSMutableString string];
    for (unsigned i = 0; i < sizeof spBCFormats / sizeof *spBCFormats; i++) {
        unsigned long long n = atomic_load(&spBCFormats[i]);
        if (n) [formats appendFormat:@"%u=%llu,", i + 130, n];
    }
    for (unsigned i = 0; i < SPBCUnsupportedCount; i++) {
        unsigned long long n = atomic_load(&spBCUnsupported[i]);
        if (n) [unsupported appendFormat:@"%u=%llu,", i, n];
    }
    spBCLog(@"SP_BC_FALLBACK summary textures=%llu textureFrees=%llu textureLive=%llu textureLiveBytes=%llu "
            @"sizingQueries=%llu formats=%@ compressed=%llu decoded=%llu stagingLiveBytes=%llu stagingPeakBytes=%llu "
            @"stagingReserved=%llu stagingReservedPeak=%llu decodeTicks=%llu maxDecodeTicks=%llu unsupported=%@ "
            @"stagingFailures=%llu textureFailures=%llu heaps=%lu heapBytes=%llu "
            @"heapCurrentAllocatedSize=%llu heapAllocatedSamples=%lu heapUsedSize=%llu heapUsedSamples=%lu "
            @"deviceCurrentAllocatedSize=%@ phys_footprint=%@ os_proc_available_memory=%zu",
            textures.allocated, textures.freed, textures.allocated - textures.freed, textures.liveBytes,
            atomic_load(&spBCSizingQueries), formats, atomic_load(&spBCCompressed), atomic_load(&spBCDecoded),
            atomic_load(&spBCStagingLive),
            atomic_load(&spBCStagingPeak), atomic_load(&spBCStagingReserved), atomic_load(&spBCReservedPeak),
            atomic_load(&spBCDecodeTicks), atomic_load(&spBCMaxTicks), unsupported,
            atomic_load(&spBCStagingFailures), atomic_load(&spBCTextureFailures), (unsigned long)heaps.count,
            heapBytes, heapAllocated, (unsigned long)allocatedSamples, heapUsed, (unsigned long)usedSamples,
            haveDeviceSize ? @(device.currentAllocatedSize) : @"n/a",
            haveFootprint ? @(vm.phys_footprint) : @"n/a", os_proc_available_memory());
}

static void spBCStartSummary(id<MTLDevice> device) {
    // One default device is installed by the generated shim. Keep the timer for
    // the process lifetime so an idle period still reports releases.
    static dispatch_source_t timer;
    __weak id<MTLDevice> weakDevice = device;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    uint64_t interval = 5 * NSEC_PER_SEC;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, interval), interval, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool { spBCSummary(weakDevice); }
    });
    dispatch_resume(timer);
}

static void spBCReject(SPBCUnsupported operation, SEL selector, MTLPixelFormat format, const char *reason) {
    if (atomic_fetch_add(&spBCUnsupported[operation], 1) == 0)
        spBCLog(@"SP_BC_FALLBACK unsupported op=%u selector=%s format=%lu reason=%s",
                (unsigned)operation, sel_getName(selector), (unsigned long)format, reason);
}

static void spBCRecordDecode(SPBCKind kind, SPBCTile tile, uint64_t ticks) {
    atomic_fetch_add(&spBCCompressed, SPBCBlockCount(tile.size.width) *
                     SPBCBlockCount(tile.size.height) * SPBCBlockBytes(kind));
    atomic_fetch_add(&spBCDecoded, tile.size.width * tile.size.height * SPBCTexelBytes(kind));
    atomic_fetch_add(&spBCDecodeTicks, ticks);
    spBCMax(&spBCMaxTicks, ticks);
}

// --- Callers inside the shared cache are the system's own code ---------------

static uintptr_t cacheStart = UINTPTR_MAX, cacheEnd;
static void findSharedCache(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || !(header->flags & MH_DYLIB_IN_CACHE)) continue;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
            if (command->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_TEXT)) continue;
            uintptr_t start = (uintptr_t)header, end = start + (uintptr_t)segment->vmsize;
            if (start < cacheStart) cacheStart = start;
            if (end > cacheEnd) cacheEnd = end;
        }
    }
}
static bool calledBySystem(void *returnAddress) {
    uintptr_t address = (uintptr_t)ptrauth_strip(returnAddress, ptrauth_key_return_address);
    return address >= cacheStart && address < cacheEnd;
}

// --- Which textures are converted --------------------------------------------

static char infoKey;
enum { MaxSubclasses = 32 };
// Entries are immutable after publication via subclassCount.
static Class subclasses[MaxSubclasses];
static atomic_uint subclassCount;


static SPBCTextureInfo *infoOf(id texture) {
    if (!texture) return nil;
    Class cls = object_getClass(texture);
    unsigned count = atomic_load(&subclassCount);
    for (unsigned i = 0; i < count; i++)
        if (subclasses[i] == cls) return objc_getAssociatedObject(texture, &infoKey);
    return nil;
}
// The real class's implementation of a selector we override in the subclass.
static IMP superIMP(id self, SEL selector) {
    return class_getMethodImplementation(class_getSuperclass(object_getClass(self)), selector);
}
// Our overrides call the real implementation; anything it sends back to the
// texture is the system's business and passes straight through.
static _Thread_local unsigned insideTexture;

static MTLPixelFormat texturePixelFormat(id self, SEL selector) {
    MTLPixelFormat (*real)(id, SEL) = (MTLPixelFormat (*)(id, SEL))superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector);
    SPBCTextureInfo *info = objc_getAssociatedObject(self, &infoKey);
    return info ? info.requested : real(self, selector);
}
static Class textureClass(id self, SEL selector) {   // as KVO does: hide the subclass
    (void)selector;
    return class_getSuperclass(object_getClass(self));
}

typedef void (*ReplaceRegion)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger);
static SEL replaceSlice(void) { return @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:); }

static SPBCSize spBCSize(MTLSize size) {
    return (SPBCSize){size.width, size.height, size.depth};
}
static SPBCOrigin spBCOrigin(MTLOrigin origin) {
    return (SPBCOrigin){origin.x, origin.y, origin.z};
}
static MTLRegion spBCPart(MTLOrigin origin, SPBCTile tile) {
    return MTLRegionMake3D(origin.x + tile.origin.x, origin.y + tile.origin.y, origin.z + tile.origin.z,
                           tile.size.width, tile.size.height, 1);
}

static bool spBCRegion(id<MTLTexture> texture, NSUInteger level, NSUInteger slice, SPBCSize *mip) {
    if (level >= texture.mipmapLevelCount || !SPBCValidSlice(texture.textureType, texture.arrayLength, slice))
        return false;
    *mip = SPBCMipSize((SPBCSize){texture.width, texture.height, texture.depth}, level);
    return true;
}

enum { SPBCTileLimit = 4 * 1024 * 1024, SPBCStagingLimit = 128 * 1024 * 1024 };

static bool spBCReserve(size_t bytes) {
    unsigned long long live = atomic_load(&spBCStagingReserved);
    do {
        if (bytes > SPBCStagingLimit - live) return false;
    } while (!atomic_compare_exchange_weak(&spBCStagingReserved, &live, live + bytes));
    spBCMax(&spBCReservedPeak, live + bytes);
    return true;
}

static void spBCStagingFailure(void) {
    unsigned long long count = atomic_fetch_add(&spBCStagingFailures, 1) + 1;
    if (!(count & (count - 1)))
        spBCLog(@"SP_BC_FALLBACK staging allocation or reservation failed count=%llu", count);
}

static bool spBCDecodeTile(SPBCKind kind, const uint8_t *source, SPBCLayout layout,
                            SPBCTile tile, uint8_t *target) {
    size_t offset = layout.offset + tile.origin.z * layout.image +
                    (tile.origin.y / 4) * layout.row + (tile.origin.x / 4) * SPBCBlockBytes(kind);
    uint64_t start = mach_absolute_time();
    bool ok = SPBCDecodeRect(kind, source + offset, layout.row, (uint32_t)tile.size.width,
                             (uint32_t)tile.size.height, target, tile.row);
    if (ok) spBCRecordDecode(kind, tile, mach_absolute_time() - start);
    return ok;
}

static void uploadDecoded(id<MTLTexture> texture, SEL selector, SPBCTextureInfo *info, MTLRegion region,
                          NSUInteger level, NSUInteger slice, const void *source,
                          NSUInteger row, NSUInteger image, bool implicitImage) {
    if (texture.storageMode == MTLStorageModePrivate) {
        spBCReject(implicitImage ? SPBCPrivateReplace : SPBCPrivateReplaceSlice, selector, info.requested,
                   "Private texture requires a blit upload");
        return;
    }
    size_t rows = SPBCBlockCount(region.size.height);
    if (implicitImage && (!rows || row > SIZE_MAX / rows)) {
        spBCReject(SPBCReplace, selector, info.requested, "invalid implicit image pitch");
        return;
    }
    if (implicitImage) image = row * rows;
    SPBCSize mip;
    SPBCLayout layout;
    if (!source || !spBCRegion(texture, level, slice, &mip) ||
        !SPBCMakeLayout(info.kind, mip, spBCOrigin(region.origin), spBCSize(region.size), 0, row, image, &layout)) {
        spBCReject(implicitImage ? SPBCReplace : SPBCReplaceSlice, selector, info.requested, "invalid region or pitch");
        return;
    }
    SPBCOrigin cursor = {0};
    SPBCTile tile;
    if (!SPBCNextTile(info.kind, layout.size, 1, SPBCTileLimit, &cursor, &tile)) return;
    size_t capacity = tile.bytes;
    if (!spBCReserve(capacity)) { spBCStagingFailure(); return; }
    uint8_t *decoded = malloc(capacity);
    if (!decoded) {
        atomic_fetch_sub(&spBCStagingReserved, capacity);
        spBCStagingFailure();
        return;
    }
    ReplaceRegion real = (ReplaceRegion)superIMP(texture, replaceSlice());
    do {
        if (!spBCDecodeTile(info.kind, source, layout, tile, decoded)) break;
        MTLRegion part = spBCPart(region.origin, tile);
        insideTexture++;
        real(texture, replaceSlice(), part, level, slice, decoded, tile.row,
             texture.textureType == MTLTextureType3D ? tile.bytes : 0);
        insideTexture--;
    } while (SPBCNextTile(info.kind, layout.size, 1, SPBCTileLimit, &cursor, &tile));
    free(decoded);
    atomic_fetch_sub(&spBCStagingReserved, capacity);
}

static void textureReplaceSlice(id self, SEL selector, MTLRegion region, NSUInteger level, NSUInteger slice,
                                const void *bytes, NSUInteger row, NSUInteger image) {
    if (insideTexture || calledBySystem(__builtin_return_address(0))) {
        ((ReplaceRegion)superIMP(self, selector))(self, selector, region, level, slice, bytes, row, image);
        return;
    }
    @autoreleasepool {
        uploadDecoded(self, selector, infoOf(self), region, level, slice, bytes, row, image, false);
    }
}
static void textureReplace(id self, SEL selector, MTLRegion region, NSUInteger level, const void *bytes, NSUInteger row) {
    if (insideTexture || calledBySystem(__builtin_return_address(0))) {
        ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))superIMP(self, selector))
            (self, selector, region, level, bytes, row);
        return;
    }
    @autoreleasepool {
        uploadDecoded(self, selector, infoOf(self), region, level, 0, bytes, row, 0, true);
    }
}

static void textureGetSlice(id self, SEL selector, void *bytes, NSUInteger row, NSUInteger image,
                            MTLRegion region, NSUInteger level, NSUInteger slice) {
    if (insideTexture || calledBySystem(__builtin_return_address(0))) {
        ((void (*)(id, SEL, void *, NSUInteger, NSUInteger, MTLRegion, NSUInteger, NSUInteger))superIMP(self, selector))
            (self, selector, bytes, row, image, region, level, slice);
        return;
    }
    spBCReject(SPBCReadSlice, selector, infoOf(self).requested, "BC readback needs an encoder");
}
static void textureGet(id self, SEL selector, void *bytes, NSUInteger row, MTLRegion region, NSUInteger level) {
    if (insideTexture || calledBySystem(__builtin_return_address(0))) {
        ((void (*)(id, SEL, void *, NSUInteger, MTLRegion, NSUInteger))superIMP(self, selector))
            (self, selector, bytes, row, region, level);
        return;
    }
    spBCReject(SPBCRead, selector, infoOf(self).requested, "BC readback needs an encoder");
}

static id converted(id<MTLTexture> texture, MTLPixelFormat requested, bool view);
typedef id (*ViewFormat)(id, SEL, MTLPixelFormat) RETAINED;
typedef id (*ViewRange)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange) RETAINED;
typedef id (*ViewSwizzle)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels) RETAINED;
typedef id (*CreateWith)(id, SEL, id) RETAINED;
typedef id (*CreateAtOffset)(id, SEL, id, NSUInteger) RETAINED;
typedef id (*SPBCSurfaceFactory)(id, SEL, id, IOSurfaceRef, NSUInteger) RETAINED;
typedef id (*SPBCBufferTextureFactory)(id, SEL, id, NSUInteger, NSUInteger) RETAINED;

// sRGB and linear variants of the same block encoding can alias the same texels.
static bool spBCViewAllowed(id texture, SEL selector, MTLPixelFormat format, SPBCUnsupported operation) {
    SPBCTextureInfo *info = infoOf(texture);
    if (SPBCKindOfPixelFormat(format) == info.kind) return true;
    spBCReject(operation, selector, format, "view would reinterpret BC storage");
    return false;
}

static id textureView(id self, SEL selector, MTLPixelFormat format) RETAINED;
static id textureView(id self, SEL selector, MTLPixelFormat format) {
    ViewFormat real = (ViewFormat)superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector, format);
    if (!spBCViewAllowed(self, selector, format, SPBCView)) return nil;
    MTLPixelFormat stored = (MTLPixelFormat)SPBCDecodedPixelFormat(format);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored); insideTexture--;
    return converted(view, format, true);
}
static id textureViewRange(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) RETAINED;
static id textureViewRange(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) {
    ViewRange real = (ViewRange)superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector, format, type, levels, slices);
    if (!spBCViewAllowed(self, selector, format, SPBCViewRange)) return nil;
    MTLPixelFormat stored = (MTLPixelFormat)SPBCDecodedPixelFormat(format);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored, type, levels, slices); insideTexture--;
    return converted(view, format, true);
}
static id textureViewSwizzle(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices,
                             MTLTextureSwizzleChannels swizzle) RETAINED;
static id textureViewSwizzle(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices,
                             MTLTextureSwizzleChannels swizzle) {
    ViewSwizzle real = (ViewSwizzle)superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector, format, type, levels, slices, swizzle);
    if (!spBCViewAllowed(self, selector, format, SPBCViewSwizzle)) return nil;
    MTLPixelFormat stored = (MTLPixelFormat)SPBCDecodedPixelFormat(format);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored, type, levels, slices, swizzle); insideTexture--;
    return converted(view, format, true);
}
static id textureViewDescriptor(id self, SEL selector, id descriptor) RETAINED;
static id textureViewDescriptor(id self, SEL selector, id descriptor) {
    CreateWith real = (CreateWith)superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector, descriptor);
    if (!descriptor) return real(self, selector, descriptor);
    // Use the runtime selector so older SDKs do not need the descriptor declaration.
    MTLPixelFormat (*getFormat)(id, SEL) = (void *)objc_msgSend;
    void (*setFormat)(id, SEL, MTLPixelFormat) = (void *)objc_msgSend;
    MTLPixelFormat format = getFormat(descriptor, @selector(pixelFormat));
    if (format == MTLPixelFormatInvalid) format = infoOf(self).requested;
    if (!spBCViewAllowed(self, selector, format, SPBCViewDescriptor)) return nil;
    id copy = [descriptor copy];
    setFormat(copy, @selector(setPixelFormat:), (MTLPixelFormat)SPBCDecodedPixelFormat(format));
    insideTexture++;
    id result = real(self, selector, copy);
    insideTexture--;
    return converted(result, format, true);
}

static Class subclassFor(Class base) {
    unsigned count = atomic_load(&subclassCount);
    for (unsigned i = 0; i < count; i++) if (subclasses[i] == base) return base;   // already ours
    for (unsigned i = 0; i < count; i++) if (class_getSuperclass(subclasses[i]) == base) return subclasses[i];
    @synchronized ([SPBCTextureInfo class]) {
        count = atomic_load(&subclassCount);
        for (unsigned i = 0; i < count; i++) if (class_getSuperclass(subclasses[i]) == base) return subclasses[i];
        if (count == MaxSubclasses) return Nil;
        NSString *name = [NSString stringWithFormat:@"SPBCTexture_%s", class_getName(base)];
        Class cls = objc_allocateClassPair(base, name.UTF8String, 0);
        if (!cls) return Nil;
        struct { SEL selector; IMP implementation; } methods[] = {
            { @selector(pixelFormat), (IMP)texturePixelFormat },
            { @selector(class), (IMP)textureClass },
            { @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), (IMP)textureReplace },
            { replaceSlice(), (IMP)textureReplaceSlice },
            { @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:), (IMP)textureGet },
            { @selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:), (IMP)textureGetSlice },
            { @selector(newTextureViewWithPixelFormat:), (IMP)textureView },
            { @selector(newTextureViewWithPixelFormat:textureType:levels:slices:), (IMP)textureViewRange },
            { @selector(newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:), (IMP)textureViewSwizzle },
            { NSSelectorFromString(@"newTextureViewWithDescriptor:"), (IMP)textureViewDescriptor },
        };
        for (size_t i = 0; i < sizeof methods / sizeof *methods; i++) {
            Method method = class_getInstanceMethod(base, methods[i].selector);
            if (method) class_addMethod(cls, methods[i].selector, methods[i].implementation, method_getTypeEncoding(method));
        }
        objc_registerClassPair(cls);
        subclasses[count] = cls;
        atomic_store(&subclassCount, count + 1);
        return cls;
    }
}

static id converted(id<MTLTexture> texture, MTLPixelFormat requested, bool view) {
    Class cls = texture ? subclassFor(object_getClass(texture)) : Nil;
    if (!cls) {
        unsigned long long count = atomic_fetch_add(&spBCTextureFailures, 1) + 1;
        if (!(count & (count - 1)))
            spBCLog(@"SP_BC_FALLBACK texture failed format=%lu view=%d metalReturnedNil=%d count=%llu",
                    (unsigned long)requested, view, texture == nil, count);
        return nil;
    }
    if (infoOf(texture)) return texture;
    SPBCTextureInfo *info = [SPBCTextureInfo new];
    info.requested = requested;
    info.kind = SPBCKindOfPixelFormat(requested);
    if (!view)
        info.trackedBytes = SPBCTextureBytes(info.kind, (SPBCSize){texture.width, texture.height, texture.depth},
                                             texture.textureType, texture.mipmapLevelCount, texture.arrayLength,
                                             texture.sampleCount);
    @synchronized ([SPBCTextureInfo class]) {
        spBCTextureStats.allocated++;
        spBCTextureStats.liveBytes += info.trackedBytes;
    }
    // Immutable after publication. Avoid the atomic association getter's
    // autorelease, which could keep the sentinel alive past the texture.
    objc_setAssociatedObject(texture, &infoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(texture, cls);
    atomic_fetch_add(&spBCFormats[requested - 130], 1);
    if (spBCVerbose)
        spBCLog(@"SP_BC_FALLBACK texture format=%lu view=%d size=%lux%lux%lu mips=%lu bytes=%zu",
                (unsigned long)requested, view, (unsigned long)texture.width, (unsigned long)texture.height,
                (unsigned long)texture.depth, (unsigned long)texture.mipmapLevelCount, info.trackedBytes);
    return texture;
}

// --- Hooks on classes found at run time ----------------------------------------

// The implementation each hooked class had before us, so classes whose methods
// we replace (devices, heaps, command buffers, blit encoders) chain correctly.
typedef struct { Class cls; SEL selector; IMP original; } Hook;
enum { MaxHooks = 256 };
static Hook hooks[MaxHooks];
static atomic_uint hookCount;
static IMP original(id self, SEL selector) {
    unsigned count = atomic_load(&hookCount);
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls))
        for (unsigned i = 0; i < count; i++)
            if (hooks[i].cls == cls && hooks[i].selector == selector) return hooks[i].original;
    return NULL;
}
static void hook(Class cls, SEL selector, IMP replacement) {
    Method existing = class_getInstanceMethod(cls, selector);
    if (!existing || method_getImplementation(existing) == replacement) return;
    @synchronized ([SPBCTextureInfo class]) {
        unsigned count = atomic_load(&hookCount);
        for (unsigned i = 0; i < count; i++) if (hooks[i].cls == cls && hooks[i].selector == selector) return;
        Method method = class_getInstanceMethod(cls, selector);
        // A subclass of a class already hooked inherits our replacement: keep it,
        // or its "original" would be ourselves.
        if (!method || method_getImplementation(method) == replacement) return;
        if (count == MaxHooks) {
            static atomic_flag full = ATOMIC_FLAG_INIT;
            if (!atomic_flag_test_and_set(&full))
                spBCLog(@"SP_BC_FALLBACK hook capacity exceeded class=%s selector=%s",
                        class_getName(cls), sel_getName(selector));
            return;
        }
        hooks[count] = (Hook){ cls, selector, method_getImplementation(method) };
        atomic_store(&hookCount, count + 1);
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }
}

static char spBCActiveKey;

static bool spBCActive(id device) {
    return objc_getAssociatedObject(device, &spBCActiveKey) != nil;
}

static MTLTextureDescriptor *spBCStoredDescriptor(MTLTextureDescriptor *descriptor) {
    MTLPixelFormat format = descriptor.pixelFormat;
    SPBCDescriptor physical = SPBCPhysicalDescriptor((SPBCDescriptor){.format = format});
    if (physical.format == format) return nil;
    // Metal copies the entire descriptor, including fields newer than this shim.
    MTLTextureDescriptor *copy = [descriptor copy];
    copy.pixelFormat = (MTLPixelFormat)physical.format;
    return copy;
}

static MTLSizeAndAlign spBCHeapSize(id device, SEL selector, MTLTextureDescriptor *descriptor,
                                  MTLSizeAndAlign (*real)(id, SEL, MTLTextureDescriptor *),
                                  MTLPixelFormat *physicalFormat) {
    @autoreleasepool {
        bool active = spBCActive(device);
        if (active) atomic_fetch_add(&spBCSizingQueries, 1);
        MTLTextureDescriptor *stored = active ? spBCStoredDescriptor(descriptor) : nil;
        if (physicalFormat) *physicalFormat = (stored ?: descriptor).pixelFormat;
        return real(device, selector, stored ?: descriptor);
    }
}

#if !SP_METAL_DIAG
static MTLSizeAndAlign spBCHeapSizeHook(id device, SEL selector, MTLTextureDescriptor *descriptor) {
    return spBCHeapSize(device, selector, descriptor,
                        (MTLSizeAndAlign (*)(id, SEL, MTLTextureDescriptor *))original(device, selector), NULL);
}

#endif

static _Thread_local unsigned spBCCreating;
static id newTexture(id owner, SEL selector, MTLTextureDescriptor *descriptor) RETAINED;
static id newTexture(id owner, SEL selector, MTLTextureDescriptor *descriptor) {
    CreateWith real = (CreateWith)original(owner, selector);
    if (spBCCreating || !SPBCKindOfPixelFormat(descriptor.pixelFormat)) return real(owner, selector, descriptor);
    // This selector is shared by MTLDevice and MTLHeap.
    if (!spBCActive(owner) && !([owner respondsToSelector:@selector(device)] &&
                                spBCActive([(id<MTLHeap>)owner device])))
        return real(owner, selector, descriptor);
    @autoreleasepool {
        MTLTextureDescriptor *stored = spBCStoredDescriptor(descriptor);
        spBCCreating++;
        id texture = real(owner, selector, stored);
        spBCCreating--;
        return converted(texture, descriptor.pixelFormat, false);
    }
}

static id newTextureAtOffset(id<MTLHeap> heap, SEL selector, MTLTextureDescriptor *descriptor,
                             NSUInteger offset) RETAINED;
static id newTextureAtOffset(id<MTLHeap> heap, SEL selector, MTLTextureDescriptor *descriptor, NSUInteger offset) {
    CreateAtOffset real = (CreateAtOffset)original(heap, selector);
    if (spBCCreating || !SPBCKindOfPixelFormat(descriptor.pixelFormat) || !spBCActive(heap.device))
        return real(heap, selector, descriptor, offset);
    @autoreleasepool {
        MTLTextureDescriptor *stored = spBCStoredDescriptor(descriptor);
        spBCCreating++;
        id texture = real(heap, selector, stored, offset);
        spBCCreating--;
        return converted(texture, descriptor.pixelFormat, false);
    }
}

static id spBCSurfaceTexture(id device, SEL selector, MTLTextureDescriptor *descriptor,
                             IOSurfaceRef surface, NSUInteger plane) RETAINED;
static id spBCSurfaceTexture(id device, SEL selector, MTLTextureDescriptor *descriptor,
                             IOSurfaceRef surface, NSUInteger plane) {
    if (SPBCKindOfPixelFormat(descriptor.pixelFormat) && spBCActive(device)) {
        spBCReject(SPBCSurface, selector, descriptor.pixelFormat, "IOSurface layout cannot be transcoded");
        return nil;
    }
    return ((SPBCSurfaceFactory)original(device, selector))
        (device, selector, descriptor, surface, plane);
}

static NSUInteger spBCLinearAlignment(id device, SEL selector, MTLPixelFormat format) {
    NSUInteger (*real)(id, SEL, MTLPixelFormat) = (void *)original(device, selector);
    unsigned long decoded = SPBCDecodedPixelFormat(format);
    return real(device, selector, decoded && spBCActive(device) ? (MTLPixelFormat)decoded : format);
}

static id spBCBufferTexture(id<MTLBuffer> buffer, SEL selector, MTLTextureDescriptor *descriptor,
                            NSUInteger offset, NSUInteger row) RETAINED;
static id spBCBufferTexture(id<MTLBuffer> buffer, SEL selector, MTLTextureDescriptor *descriptor,
                            NSUInteger offset, NSUInteger row) {
    if (SPBCKindOfPixelFormat(descriptor.pixelFormat) && spBCActive(buffer.device))
        spBCReject(SPBCBufferTexture, selector, descriptor.pixelFormat, "pass original BC alias to Metal validation");
    // Linear textures must alias the caller's bytes. A physical descriptor
    // would silently reinterpret those bytes even when the physical pitch fits.
    return ((SPBCBufferTextureFactory)original(buffer, selector))
        (buffer, selector, descriptor, offset, row);
}

static id spBCHookBuffer(id buffer) {
    if (buffer) hook(object_getClass(buffer), @selector(newTextureWithDescriptor:offset:bytesPerRow:), (IMP)spBCBufferTexture);
    return buffer;
}

typedef id (*SPBCNewBuffer)(id, SEL, NSUInteger, MTLResourceOptions) RETAINED;
typedef id (*SPBCNewBufferAt)(id, SEL, NSUInteger, MTLResourceOptions, NSUInteger) RETAINED;
typedef id (*SPBCNewBufferBytes)(id, SEL, const void *, NSUInteger, MTLResourceOptions) RETAINED;
typedef id (*SPBCNewBufferNoCopy)(id, SEL, void *, NSUInteger, MTLResourceOptions, void (^)(void *, NSUInteger)) RETAINED;

static id spBCNewBuffer(id owner, SEL selector, NSUInteger length, MTLResourceOptions options) RETAINED;
static id spBCNewBuffer(id owner, SEL selector, NSUInteger length, MTLResourceOptions options) {
    return spBCHookBuffer(((SPBCNewBuffer)original(owner, selector))(owner, selector, length, options));
}
static id spBCNewBufferAt(id owner, SEL selector, NSUInteger length, MTLResourceOptions options, NSUInteger offset) RETAINED;
static id spBCNewBufferAt(id owner, SEL selector, NSUInteger length, MTLResourceOptions options, NSUInteger offset) {
    return spBCHookBuffer(((SPBCNewBufferAt)original(owner, selector))(owner, selector, length, options, offset));
}
static id spBCNewBufferBytes(id owner, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions options) RETAINED;
static id spBCNewBufferBytes(id owner, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions options) {
    return spBCHookBuffer(((SPBCNewBufferBytes)original(owner, selector))(owner, selector, bytes, length, options));
}
static id spBCNewBufferNoCopy(id owner, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions options,
                              void (^deallocator)(void *, NSUInteger)) RETAINED;
static id spBCNewBufferNoCopy(id owner, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions options,
                              void (^deallocator)(void *, NSUInteger)) {
    return spBCHookBuffer(((SPBCNewBufferNoCopy)original(owner, selector))(owner, selector, bytes, length, options, deallocator));
}

static id newHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) RETAINED;
static id newHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) {
    id heap = ((CreateWith)original(device, selector))(device, selector, descriptor);
    if (heap && spBCActive(device)) {
        @synchronized (spBCHeaps) { [spBCHeaps addObject:heap]; }
        Class cls = object_getClass(heap);
        hook(cls, @selector(newTextureWithDescriptor:), (IMP)newTexture);
        hook(cls, @selector(newTextureWithDescriptor:offset:), (IMP)newTextureAtOffset);
        hook(cls, @selector(newBufferWithLength:options:), (IMP)spBCNewBuffer);
        hook(cls, @selector(newBufferWithLength:options:offset:), (IMP)spBCNewBufferAt);
    }
    return heap;
}

// Count the buffer until Metal releases it too. The reservation separately
// follows the shim upload and still governs the existing scratch/staging cap.
static char spBCStagingKey;
@interface SPBCStagingInfo : NSObject {
@public
    size_t bytes;
}
@end
@implementation SPBCStagingInfo
- (void)dealloc { atomic_fetch_sub(&spBCStagingLive, bytes); }
@end

static void spBCTrackStaging(id<MTLBuffer> buffer) {
    SPBCStagingInfo *info = [SPBCStagingInfo new];
    info->bytes = buffer.length;
    unsigned long long live = atomic_fetch_add(&spBCStagingLive, info->bytes) + info->bytes;
    spBCMax(&spBCStagingPeak, live);
    objc_setAssociatedObject(buffer, &spBCStagingKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface SPBCUpload : NSObject {
@public
    id<MTLBuffer> source, staging;
    id<MTLTexture> destination;
    SPBCLayout layout;
    SPBCTile tile;
    SPBCKind kind;
}
- (void)decode;
@end

@implementation SPBCUpload
- (void)decode {
    spBCDecodeTile(kind, source.contents, layout, tile, staging.contents);
    source = nil;  // The GPU reads staging; the source is only needed through commit.
}
- (void)dealloc {
    size_t bytes = tile.bytes;
    staging = nil;
    if (bytes) atomic_fetch_sub(&spBCStagingReserved, bytes);
}
@end

static char uploadsKey, ownerKey;
@interface SPBCOwner : NSObject
@property (nonatomic, weak) id<MTLCommandBuffer> commandBuffer;
@end
@implementation SPBCOwner @end

static void hookBlitEncoderClass(Class cls);
static id spBCBindEncoder(id encoder, id<MTLCommandBuffer> commandBuffer) {
    if (encoder && spBCActive(commandBuffer.device)) {
        hookBlitEncoderClass(object_getClass(encoder));
        SPBCOwner *owner = [SPBCOwner new];
        owner.commandBuffer = commandBuffer;
        objc_setAssociatedObject(encoder, &ownerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}
static id blitEncoder(id commandBuffer, SEL selector) {
    return spBCBindEncoder(((id (*)(id, SEL))original(commandBuffer, selector))(commandBuffer, selector), commandBuffer);
}
static id blitEncoderWithDescriptor(id commandBuffer, SEL selector, id descriptor) {
    return spBCBindEncoder(((id (*)(id, SEL, id))original(commandBuffer, selector))(commandBuffer, selector, descriptor),
                           commandBuffer);
}
static void commitCommandBuffer(id<MTLCommandBuffer> commandBuffer, SEL selector) {
    NSArray<SPBCUpload *> *pending;
    @synchronized (commandBuffer) {
        pending = objc_getAssociatedObject(commandBuffer, &uploadsKey);
        if (pending) objc_setAssociatedObject(commandBuffer, &uploadsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (pending.count) {
        for (SPBCUpload *upload in pending) [upload decode];
        // Drop staging at completion even if the command buffer outlives the handler.
        __block NSArray<SPBCUpload *> *retained = pending;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done;
            (void)retained;
            retained = nil;
        }];
    }
    ((void (*)(id, SEL))original(commandBuffer, selector))(commandBuffer, selector);
}

typedef void (*BufferToTexture)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
typedef void (*BufferToTextureOptions)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id,
                                       NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption);

static void stageUpload(id encoder, SEL selector, id<MTLBuffer> source, NSUInteger offset, NSUInteger row,
                        NSUInteger image, MTLSize size, id<MTLTexture> texture, NSUInteger slice, NSUInteger level,
                        MTLOrigin origin, MTLBlitOption options, bool withOptions, SPBCTextureInfo *info) {
    if (source.storageMode == MTLStorageModePrivate || !source.contents) {
        spBCReject(withOptions ? SPBCPrivateSourceOptions : SPBCPrivateSource, selector, info.requested,
                   "source buffer is not CPU visible");
        return;
    }
    SPBCOwner *owner = objc_getAssociatedObject(encoder, &ownerKey);
    id<MTLCommandBuffer> commandBuffer = owner.commandBuffer;
    SPBCSize mip;
    SPBCLayout layout;
    if (!commandBuffer || options || !spBCRegion(texture, level, slice, &mip) ||
        !SPBCMakeLayout(info.kind, mip, spBCOrigin(origin), spBCSize(size), offset, row, image, &layout) ||
        layout.end > source.length) {
        spBCReject(withOptions ? SPBCBufferCopyOptions : SPBCBufferCopy, selector, info.requested,
                   "invalid command buffer, region, pitch, source range, or blit options");
        return;
    }

    // Allocate the entire batch before encoding its first tile. A failed
    // reservation or allocation drops the operation without leaving a partial copy.
    NSMutableArray<SPBCUpload *> *batch = [NSMutableArray new];
    SPBCOrigin cursor = {0};
    SPBCTile tile;
    while (SPBCNextTile(info.kind, layout.size, 256, SPBCTileLimit, &cursor, &tile)) {
        if (!spBCReserve(tile.bytes)) { spBCStagingFailure(); return; }
        SPBCUpload *upload = [SPBCUpload new];
        upload->tile = tile;
        upload->staging = [texture.device newBufferWithLength:tile.bytes options:MTLResourceStorageModeShared];
        if (!upload->staging) { spBCStagingFailure(); return; }
        spBCTrackStaging(upload->staging);
        upload->source = source;
        upload->destination = texture;
        upload->layout = layout;
        upload->kind = info.kind;
        [batch addObject:upload];
    }
    @synchronized (commandBuffer) {
        NSMutableArray *pending = objc_getAssociatedObject(commandBuffer, &uploadsKey);
        if (!pending) {
            pending = [NSMutableArray new];
            objc_setAssociatedObject(commandBuffer, &uploadsKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [pending addObjectsFromArray:batch];
    }
    IMP real = original(encoder, selector);
    insideTexture++;
    for (SPBCUpload *upload in batch) {
        MTLRegion part = spBCPart(origin, upload->tile);
        if (withOptions)
            ((BufferToTextureOptions)real)(encoder, selector, upload->staging, 0, upload->tile.row, upload->tile.bytes,
                                           part.size, texture, slice, level, part.origin, options);
        else
            ((BufferToTexture)real)(encoder, selector, upload->staging, 0, upload->tile.row, upload->tile.bytes,
                                    part.size, texture, slice, level, part.origin);
    }
    insideTexture--;
}

static void copyBufferToTexture(id encoder, SEL selector, id<MTLBuffer> source, NSUInteger offset, NSUInteger row,
                                NSUInteger image, MTLSize size, id<MTLTexture> texture, NSUInteger slice,
                                NSUInteger level, MTLOrigin origin) {
    SPBCTextureInfo *info = insideTexture ? nil : infoOf(texture);
    if (info) {
        @autoreleasepool {
            stageUpload(encoder, selector, source, offset, row, image, size, texture, slice, level, origin, 0, false, info);
        }
    } else ((BufferToTexture)original(encoder, selector))(encoder, selector, source, offset, row, image, size,
                                                         texture, slice, level, origin);
}
static void copyBufferToTextureOptions(id encoder, SEL selector, id<MTLBuffer> source, NSUInteger offset, NSUInteger row,
                                       NSUInteger image, MTLSize size, id<MTLTexture> texture, NSUInteger slice,
                                       NSUInteger level, MTLOrigin origin, MTLBlitOption options) {
    SPBCTextureInfo *info = insideTexture ? nil : infoOf(texture);
    if (info) {
        @autoreleasepool {
            stageUpload(encoder, selector, source, offset, row, image, size, texture, slice, level, origin, options, true, info);
        }
    } else ((BufferToTextureOptions)original(encoder, selector))(encoder, selector, source, offset, row, image, size,
                                                                texture, slice, level, origin, options);
}

static bool spBCCopyAllowed(SPBCTextureInfo *source, SPBCTextureInfo *destination, SEL selector, SPBCUnsupported operation) {
    if ((!source && !destination) || (source && destination &&
        SPBCDecodedPixelFormat(source.requested) == SPBCDecodedPixelFormat(destination.requested))) return true;
    spBCReject(operation, selector, (source ?: destination).requested, "copy requires matching physical BC textures");
    return false;
}

static bool spBCCopyLayout(id<MTLTexture> texture, NSUInteger slice, NSUInteger level, MTLOrigin origin,
                           MTLSize size, SPBCKind kind, SPBCLayout *layout) {
    SPBCSize mip;
    if (!spBCRegion(texture, level, slice, &mip)) return false;
    size_t row = SPBCBlockCount(MIN(size.width, mip.width)) * SPBCBlockBytes(kind);
    size_t image = row * SPBCBlockCount(MIN(size.height, mip.height));
    return SPBCMakeLayout(kind, mip, spBCOrigin(origin), spBCSize(size), 0, row, image, layout);
}

static void copyTextureRegion(id encoder, SEL selector, id<MTLTexture> source, NSUInteger sourceSlice, NSUInteger sourceLevel,
                              MTLOrigin sourceOrigin, MTLSize size, id<MTLTexture> destination, NSUInteger destinationSlice,
                              NSUInteger destinationLevel, MTLOrigin destinationOrigin) {
    SPBCTextureInfo *from = insideTexture ? nil : infoOf(source), *to = insideTexture ? nil : infoOf(destination);
    if (!spBCCopyAllowed(from, to, selector, SPBCTextureRegion)) return;
    if (from) {
        SPBCLayout input, output;
        if (!spBCCopyLayout(source, sourceSlice, sourceLevel, sourceOrigin, size, from.kind, &input) ||
            !spBCCopyLayout(destination, destinationSlice, destinationLevel, destinationOrigin, size, to.kind, &output) ||
            input.size.width != output.size.width || input.size.height != output.size.height) {
            spBCReject(SPBCTextureRegion, selector, from.requested, "incompatible region or mip edges");
            return;
        }
        size = MTLSizeMake(input.size.width, input.size.height, input.size.depth);
    }
    insideTexture++;
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))
        original(encoder, selector))(encoder, selector, source, sourceSlice, sourceLevel, sourceOrigin,
                                      size, destination, destinationSlice, destinationLevel, destinationOrigin);
    insideTexture--;
}
static void copyTextureLevels(id encoder, SEL selector, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, id destination,
                              NSUInteger destinationSlice, NSUInteger destinationLevel, NSUInteger sliceCount, NSUInteger levelCount) {
    if (!insideTexture && !spBCCopyAllowed(infoOf(source), infoOf(destination), selector, SPBCTextureLevels)) return;
    insideTexture++;
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger, NSUInteger, NSUInteger))original(encoder, selector))
        (encoder, selector, source, sourceSlice, sourceLevel, destination, destinationSlice, destinationLevel, sliceCount, levelCount);
    insideTexture--;
}
static void copyTexture(id encoder, SEL selector, id source, id destination) {
    if (!insideTexture && !spBCCopyAllowed(infoOf(source), infoOf(destination), selector, SPBCTextureCopy)) return;
    insideTexture++;
    ((void (*)(id, SEL, id, id))original(encoder, selector))(encoder, selector, source, destination);
    insideTexture--;
}

static void copyTextureToBuffer(id encoder, SEL selector, id source, NSUInteger slice, NSUInteger level, MTLOrigin origin,
                                MTLSize size, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image) {
    SPBCTextureInfo *info = insideTexture ? nil : infoOf(source);
    if (info) { spBCReject(SPBCReadBlit, selector, info.requested, "BC readback needs an encoder"); return; }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger))original(encoder, selector))
        (encoder, selector, source, slice, level, origin, size, buffer, offset, row, image);
}
static void copyTextureToBufferOptions(id encoder, SEL selector, id source, NSUInteger slice, NSUInteger level, MTLOrigin origin,
                                       MTLSize size, id buffer, NSUInteger offset, NSUInteger row, NSUInteger image, MTLBlitOption options) {
    SPBCTextureInfo *info = insideTexture ? nil : infoOf(source);
    if (info) { spBCReject(SPBCReadBlitOptions, selector, info.requested, "BC readback needs an encoder"); return; }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger, MTLBlitOption))
        original(encoder, selector))(encoder, selector, source, slice, level, origin, size, buffer, offset, row, image, options);
}

static void spBCGenerateMipmaps(id encoder, SEL selector, id texture) {
    insideTexture++;
    ((void (*)(id, SEL, id))original(encoder, selector))(encoder, selector, texture);
    insideTexture--;
}

static void hookBlitEncoderClass(Class cls) {
    hook(cls, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)copyBufferToTexture);
    hook(cls, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:), (IMP)copyBufferToTextureOptions);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)copyTextureRegion);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:), (IMP)copyTextureLevels);
    hook(cls, @selector(copyFromTexture:toTexture:), (IMP)copyTexture);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:), (IMP)copyTextureToBuffer);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:options:), (IMP)copyTextureToBufferOptions);
    hook(cls, @selector(generateMipmapsForTexture:), (IMP)spBCGenerateMipmaps);
}

static id spBCHookCommandBuffer(id<MTLCommandBuffer> buffer, id<MTLCommandQueue> queue) {
    if (buffer && spBCActive(queue.device)) {
        Class cls = object_getClass(buffer);
        hook(cls, @selector(blitCommandEncoder), (IMP)blitEncoder);
        hook(cls, @selector(blitCommandEncoderWithDescriptor:), (IMP)blitEncoderWithDescriptor);
        hook(cls, @selector(commit), (IMP)commitCommandBuffer);
    }
    return buffer;
}

static id spBCCommandBuffer(id queue, SEL selector) {
    return spBCHookCommandBuffer(((id (*)(id, SEL))original(queue, selector))(queue, selector), queue);
}
static id spBCCommandBufferDescriptor(id queue, SEL selector, id descriptor) {
    return spBCHookCommandBuffer(((id (*)(id, SEL, id))original(queue, selector))(queue, selector, descriptor), queue);
}
static id spBCHookQueue(id queue, id device) {
    if (queue && spBCActive(device)) {
        Class cls = object_getClass(queue);
        hook(cls, @selector(commandBuffer), (IMP)spBCCommandBuffer);
        hook(cls, @selector(commandBufferWithUnretainedReferences), (IMP)spBCCommandBuffer);
        hook(cls, @selector(commandBufferWithDescriptor:), (IMP)spBCCommandBufferDescriptor);
    }
    return queue;
}
typedef id (*SPBCNewQueue)(id, SEL) RETAINED;
typedef id (*SPBCNewQueueCount)(id, SEL, NSUInteger) RETAINED;
static id spBCNewQueue(id device, SEL selector) RETAINED;
static id spBCNewQueue(id device, SEL selector) {
    return spBCHookQueue(((SPBCNewQueue)original(device, selector))(device, selector), device);
}
static id spBCNewQueueCount(id device, SEL selector, NSUInteger count) RETAINED;
static id spBCNewQueueCount(id device, SEL selector, NSUInteger count) {
    return spBCHookQueue(((SPBCNewQueueCount)original(device, selector))(device, selector, count), device);
}
static id spBCNewQueueDescriptor(id device, SEL selector, id descriptor) RETAINED;
static id spBCNewQueueDescriptor(id device, SEL selector, id descriptor) {
    return spBCHookQueue(((CreateWith)original(device, selector))(device, selector, descriptor), device);
}

static void spBCInstall(id<MTLDevice> device, Class cls) {
    bool haveProperty = [device respondsToSelector:@selector(supportsBCTextureCompression)];
    bool enabled = haveProperty && !device.supportsBCTextureCompression;
    spBCLog(@"SP_BC_FALLBACK %s device=%@ reason=%s", enabled ? "enabled" : "disabled", device.name,
            enabled ? "no-native-BC" : haveProperty ? "native-BC" : "capability-unavailable");
    if (!enabled) return;
    findSharedCache();
    const char *verbose = getenv("SP_BC_VERBOSE");
    spBCVerbose = verbose && strcmp(verbose, "1") == 0;
    spBCHeaps = [[NSHashTable alloc] initWithOptions:NSPointerFunctionsWeakMemory |
                                                    NSPointerFunctionsObjectPointerPersonality capacity:0];
    objc_setAssociatedObject(device, &spBCActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if !SP_METAL_DIAG
    hook(cls, @selector(heapTextureSizeAndAlignWithDescriptor:), (IMP)spBCHeapSizeHook);
#endif
    hook(cls, @selector(newTextureWithDescriptor:), (IMP)newTexture);
    hook(cls, @selector(newTextureWithDescriptor:iosurface:plane:), (IMP)spBCSurfaceTexture);
    hook(cls, @selector(newHeapWithDescriptor:), (IMP)newHeap);
    hook(cls, @selector(minimumLinearTextureAlignmentForPixelFormat:), (IMP)spBCLinearAlignment);
    hook(cls, @selector(newBufferWithLength:options:), (IMP)spBCNewBuffer);
    hook(cls, @selector(newBufferWithBytes:length:options:), (IMP)spBCNewBufferBytes);
    hook(cls, @selector(newBufferWithBytesNoCopy:length:options:deallocator:), (IMP)spBCNewBufferNoCopy);
    hook(cls, @selector(newCommandQueue), (IMP)spBCNewQueue);
    hook(cls, @selector(newCommandQueueWithMaxCommandBufferCount:), (IMP)spBCNewQueueCount);
    hook(cls, sel_registerName("newCommandQueueWithDescriptor:"), (IMP)spBCNewQueueDescriptor);
    spBCStartSummary(device);
}
