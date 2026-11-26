#ifndef SPBCSTAGING_H
#define SPBCSTAGING_H

#include <stdbool.h>
#include <stddef.h>

static inline bool SPBCStagingPackTiles(size_t bytes, size_t tiles, size_t tileLimit) {
    return tiles > 1 && bytes <= tileLimit;
}

enum { SPBCStagingLimit = 128 * 1024 * 1024 };

typedef struct {
    unsigned long long uploads, bytes;
} SPBCStagingUsage;

typedef struct {
    SPBCStagingUsage pending, inFlight;
    unsigned long long pendingAtPeak, inFlightAtPeak, scratchAtPeak, pendingLimitHits;
    unsigned long long scratchBytes, reservedPeak, limitHits, overLimit, overLimitBytes;
} SPBCStaging;

typedef enum {
    SPBCStagingReleased, SPBCStagingPending, SPBCStagingInFlight
} SPBCStagingPhase;

typedef struct {
    SPBCStagingPhase phase;
    size_t bytes;
} SPBCStagingReservation;

// Callers serialize access, including reads for diagnostics.
unsigned long long SPBCStagingReserved(const SPBCStaging *staging);
bool SPBCStagingFits(const SPBCStaging *staging, size_t bytes);
bool SPBCStagingCanWait(const SPBCStaging *staging, size_t bytes);
void SPBCStagingReserve(SPBCStaging *staging, SPBCStagingReservation *reservation, size_t bytes);
void SPBCStagingSubmit(SPBCStaging *staging, SPBCStagingReservation *reservation);
void SPBCStagingRelease(SPBCStaging *staging, SPBCStagingReservation *reservation);
void SPBCStagingAddScratch(SPBCStaging *staging, size_t bytes);
void SPBCStagingReleaseScratch(SPBCStaging *staging, size_t bytes);

#endif
