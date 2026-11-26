#ifndef SPA16PROFILE_H
#define SPA16PROFILE_H

#include <stdbool.h>
#include <stdint.h>

#define SP_A16_MIB (UINT64_C(1024) * 1024)
#define SP_A16_BUDGET (4096 * SP_A16_MIB)

static inline const char *spA16BudgetState(uint64_t footprint) {
    if (footprint >= SP_A16_BUDGET) return "critical";
    if (footprint >= 3584 * SP_A16_MIB) return "warning";
    if (footprint > 3072 * SP_A16_MIB) return "target-exceeded";
    return "ok";
}

static inline bool spA16BudgetFailed(uint64_t footprint) {
    return footprint > SP_A16_BUDGET;
}

static inline bool spA16EffectiveBC(bool profile, bool real) {
    return real && !profile;
}

static inline bool spA16EffectiveFamily(bool profile, unsigned long family, bool real) {
    // The Apple family range ends where the Mac family range starts.
    return real && !(profile && ((family >= 1009 && family < 2000) || family == 2002));
}

#endif
