#ifndef SP_HW_PROFILE_H
#define SP_HW_PROFILE_H

#include <stdbool.h>

enum SPHardwareProfile { SP_HW_AUTOMATIC, SP_HW_NATIVE, SP_HW_A16 };

typedef struct {
    bool hasBC, bc;
    bool apple7, apple8, apple9, mac2, apple2;
} SPHardwareCapabilities;

typedef struct {
    enum SPHardwareProfile requested, effective;
    const char *reason;
} SPHardwareSelection;

static inline SPHardwareSelection sp_hw_select(long requested, SPHardwareCapabilities caps) {
    if (requested == SP_HW_A16)
        return (SPHardwareSelection){SP_HW_A16, SP_HW_A16, "manual-a16"};
    enum SPHardwareProfile choice = requested == SP_HW_NATIVE ? SP_HW_NATIVE : SP_HW_AUTOMATIC;
    if (!caps.hasBC || !caps.bc)
        return (SPHardwareSelection){choice, SP_HW_A16, caps.hasBC ? "no-native-bc" : "bc-property-unavailable"};
    return (SPHardwareSelection){choice, SP_HW_NATIVE, choice == SP_HW_NATIVE ? "manual-native" : "native-bc"};
}

static inline const char *sp_hw_name(enum SPHardwareProfile profile) {
    return profile == SP_HW_NATIVE ? "native" : profile == SP_HW_A16 ? "a16" : "automatic";
}

static inline bool sp_hw_force_a16(SPHardwareSelection selection, SPHardwareCapabilities caps) {
    return selection.requested == SP_HW_A16 && caps.hasBC && caps.bc;
}

static inline const char *sp_hw_backend(bool simulateA16, SPHardwareCapabilities caps, bool compact) {
    if (!simulateA16 && (!caps.hasBC || caps.bc)) return "bc-native";
    return compact && caps.apple2 ? "bc-fallback-rgba8+astc-bc1" : "bc-fallback-rgba8";
}

#endif
