#include <assert.h>
#include "../sphwprofile.h"
#include "../spmemory.h"

int main(void) {
    SPHardwareCapabilities phone = {.hasBC = true, .bc = true, .apple2 = true, .apple9 = true};
    SPHardwareCapabilities pad = {.hasBC = true, .apple2 = true, .apple7 = true};
    SPHardwareCapabilities unknown = {.apple9 = true, .mac2 = true};
    SPHardwareSelection automatic = sp_hw_select(0, phone);
    SPHardwareSelection native = sp_hw_select(1, phone);
    SPHardwareSelection compat = sp_hw_select(2, phone);
    assert(automatic.requested == SP_HW_AUTOMATIC && automatic.effective == SP_HW_NATIVE);
    assert(!strcmp(automatic.reason, "native-bc"));
    assert(native.effective == SP_HW_NATIVE && !strcmp(native.reason, "manual-native"));
    assert(compat.effective == SP_HW_A16 && sp_hw_force_a16(compat, phone));
    assert(!sp_hw_force_a16(compat, pad) && !sp_hw_force_a16(compat, unknown));
    assert(!sp_hw_force_a16(automatic, phone));
    assert(sp_hw_select(0, pad).effective == SP_HW_A16);
    assert(sp_hw_select(2, pad).effective == SP_HW_A16);
    SPHardwareSelection refused = sp_hw_select(1, pad);
    assert(refused.requested == SP_HW_NATIVE && refused.effective == SP_HW_A16);
    assert(!strcmp(refused.reason, "no-native-bc"));
    refused = sp_hw_select(1, unknown);
    assert(refused.effective == SP_HW_A16 && !strcmp(refused.reason, "bc-property-unavailable"));
    assert(sp_hw_select(-1, phone).requested == SP_HW_AUTOMATIC);
    assert(!strcmp(sp_hw_backend(false, phone, true), "bc-native"));
    assert(!strcmp(sp_hw_backend(false, pad, false), "bc-fallback-rgba8"));
    assert(!strcmp(sp_hw_backend(true, phone, true), "bc-fallback-rgba8+astc-bc1"));

    const char *baseline = "SET RenderScale \"0.8\"\nSET maxFPS \"60\"\nSET graphicsTextureResolution \"2\"\n";
    char *legacyBackup = sp_graphics_backup(baseline, SP_GRAPHICS_LEGACY_COUNT);
    assert(legacyBackup);
    char *backup = sp_graphics_expand_backup(legacyBackup, baseline);
    free(legacyBackup);
    assert(backup);
    for (enum SPGraphicsPreset saved = SP_GRAPHICS_A16; saved <= SP_GRAPHICS_A16_LOW_MEMORY; saved++) {
        size_t applied, unchanged;
        char *a16 = sp_graphics_edit(baseline, backup, saved, false, false, &applied, &unchanged);
        assert(a16 && strcmp(a16, baseline));
        assert(!sp_graphics_restore_on_native_keep(false, SP_GRAPHICS_KEEP, saved, true));
        assert(!sp_graphics_restore_on_native_keep(true, SP_GRAPHICS_KEEP, saved, false));
        assert(!sp_graphics_restore_on_native_keep(true, SP_GRAPHICS_BALANCED, saved, true));
        assert(sp_graphics_restore_on_native_keep(true, SP_GRAPHICS_KEEP, saved, true));
        char *restored = sp_graphics_edit(a16, backup, SP_GRAPHICS_KEEP, false, false, &applied, &unchanged);
        assert(restored && !strcmp(restored, baseline));
        char *again = sp_graphics_edit(restored, backup, saved, false, false, &applied, &unchanged);
        assert(again && !strcmp(again, a16));
        free(again);
        free(restored);
        free(a16);
    }
    free(backup);
    for (enum SPGraphicsPreset applied = SP_GRAPHICS_PERFORMANCE; applied <= SP_GRAPHICS_QUALITY; applied++)
        assert(!sp_graphics_restore_on_native_keep(true, SP_GRAPHICS_KEEP, applied, true));

    const char *memory = "SET ThreadPoolLimitLP \"4\"\n";
    const char *choices[SP_MEMORY_COUNT];
    sp_memory_choices(choices, 0, 1, 0, 0);
    char *override, *memoryBackup;
    assert(sp_memory_edit(memory, SP_MEMORY_LOW_PRIORITY, choices[SP_MEMORY_LOW_PRIORITY],
                          NULL, &override, &memoryBackup));
    assert(override && memoryBackup);
    sp_memory_choices(choices, 0, 0, 0, 0);
    for (size_t i = 0; i < SP_MEMORY_COUNT; ++i) assert(!choices[i]);
    char *restored, *snapshot;
    assert(sp_memory_edit(override, SP_MEMORY_LOW_PRIORITY, choices[SP_MEMORY_LOW_PRIORITY],
                          memoryBackup, &restored, &snapshot));
    assert(restored && !strcmp(restored, memory) && !snapshot);
    free(restored);
    free(memoryBackup);
    free(override);
    puts("hardware profile: selection, forced compatibility, graphics round trips and CVar restore passed");
}
