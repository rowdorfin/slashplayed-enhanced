#include "spbcstaging.h"

#include <assert.h>

unsigned long long SPBCStagingReserved(const SPBCStaging *staging) {
    return staging->pending.bytes + staging->inFlight.bytes + staging->scratchBytes;
}

static bool spBCFits(unsigned long long used, size_t bytes) {
    return used <= SPBCStagingLimit && bytes <= SPBCStagingLimit - used;
}

bool SPBCStagingFits(const SPBCStaging *staging, size_t bytes) {
    return spBCFits(staging->pending.bytes + staging->inFlight.bytes, bytes);
}

bool SPBCStagingCanWait(const SPBCStaging *staging, size_t bytes) {
    return staging->inFlight.bytes && spBCFits(staging->pending.bytes, bytes);
}

static void spBCUpdatePeak(SPBCStaging *staging) {
    unsigned long long reserved = SPBCStagingReserved(staging);
    if (reserved > staging->reservedPeak) {
        staging->reservedPeak = reserved;
        staging->pendingAtPeak = staging->pending.bytes;
        staging->inFlightAtPeak = staging->inFlight.bytes;
        staging->scratchAtPeak = staging->scratchBytes;
    }
}

static void spBCRemoveUsage(SPBCStagingUsage *usage, size_t bytes) {
    assert(usage->uploads && usage->bytes >= bytes);
    usage->uploads--;
    usage->bytes -= bytes;
}

void SPBCStagingReserve(SPBCStaging *staging, SPBCStagingReservation *reservation, size_t bytes) {
    assert(reservation->phase == SPBCStagingReleased && bytes);
    if (!SPBCStagingFits(staging, bytes)) {
        staging->overLimit++;
        staging->overLimitBytes += bytes;
    }
    *reservation = (SPBCStagingReservation){SPBCStagingPending, bytes};
    staging->pending.uploads++;
    staging->pending.bytes += bytes;
    if (staging->pending.bytes > staging->pendingPeak) staging->pendingPeak = staging->pending.bytes;
    spBCUpdatePeak(staging);
}

void SPBCStagingSubmit(SPBCStaging *staging, SPBCStagingReservation *reservation) {
    // A fast completion can release the reservation before commit returns.
    if (reservation->phase != SPBCStagingPending) return;
    spBCRemoveUsage(&staging->pending, reservation->bytes);
    staging->inFlight.uploads++;
    staging->inFlight.bytes += reservation->bytes;
    reservation->phase = SPBCStagingInFlight;
}

void SPBCStagingRelease(SPBCStaging *staging, SPBCStagingReservation *reservation) {
    if (reservation->phase == SPBCStagingReleased) return;
    SPBCStagingUsage *usage = reservation->phase == SPBCStagingPending ? &staging->pending : &staging->inFlight;
    spBCRemoveUsage(usage, reservation->bytes);
    reservation->phase = SPBCStagingReleased;
}

void SPBCStagingRecordBatch(SPBCStaging *staging, unsigned long long bytes, unsigned long long uploads) {
    staging->batchBytes += bytes;
    staging->batchUploads += uploads;
    if (bytes > staging->maxBatchBytes ||
        (bytes == staging->maxBatchBytes && uploads > staging->uploadsAtMaxBatch)) {
        staging->maxBatchBytes = bytes;
        staging->uploadsAtMaxBatch = uploads;
    }
}

void SPBCStagingAddScratch(SPBCStaging *staging, size_t bytes) {
    staging->scratchBytes += bytes;
    spBCUpdatePeak(staging);
}

void SPBCStagingReleaseScratch(SPBCStaging *staging, size_t bytes) {
    assert(staging->scratchBytes >= bytes);
    staging->scratchBytes -= bytes;
}
