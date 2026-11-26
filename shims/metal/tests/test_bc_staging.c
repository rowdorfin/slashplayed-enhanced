#include "spbcstaging.h"

#include <assert.h>
#include <stdio.h>

static void pendingPressure(void) {
    SPBCStaging staging = {0};
    SPBCStagingReservation first = {0}, second = {0}, abandoned = {0};
    SPBCStagingReserve(&staging, &first, SPBCStagingLimit);
    assert(!SPBCStagingFits(&staging, 1));
    assert(!SPBCStagingCanWait(&staging, 1));

    SPBCStagingReserve(&staging, &second, 4096);
    assert(staging.pending.uploads == 2 && staging.pending.bytes == SPBCStagingLimit + 4096);
    assert(staging.overLimit == 1 && staging.overLimitBytes == 4096);
    assert(!SPBCStagingFits(&staging, 1));

    SPBCStagingReserve(&staging, &abandoned, 8192);
    SPBCStagingRelease(&staging, &abandoned);
    assert(staging.pending.uploads == 2 && staging.overLimit == 2);
    assert(staging.reservedPeak == SPBCStagingLimit + 4096 + 8192);

    SPBCStagingSubmit(&staging, &second);
    assert(!SPBCStagingCanWait(&staging, 1)); // The pending upload alone fills the budget.
    SPBCStagingRelease(&staging, &first);
    SPBCStagingRelease(&staging, &second);
    assert(!SPBCStagingReserved(&staging));
}

static void submittedPressure(void) {
    SPBCStaging staging = {0};
    SPBCStagingReservation submitted = {0}, next = {0}, timedOut = {0};
    SPBCStagingReserve(&staging, &submitted, SPBCStagingLimit);
    SPBCStagingSubmit(&staging, &submitted);
    assert(!staging.pending.uploads && !staging.pending.bytes);
    assert(staging.inFlight.uploads == 1 && staging.inFlight.bytes == SPBCStagingLimit);
    assert(!SPBCStagingFits(&staging, 4096) && SPBCStagingCanWait(&staging, 4096));
    assert(!SPBCStagingCanWait(&staging, SPBCStagingLimit + 1));

    SPBCStagingReserve(&staging, &timedOut, 4096);
    assert(staging.overLimit == 1 && staging.overLimitBytes == 4096);
    SPBCStagingRelease(&staging, &submitted);
    assert(!staging.inFlight.uploads && !staging.inFlight.bytes);
    assert(SPBCStagingFits(&staging, 4096));

    SPBCStagingReserve(&staging, &next, 4096);
    assert(staging.overLimit == 1);
    SPBCStagingRelease(&staging, &next);
    SPBCStagingSubmit(&staging, &next); // Completion beat the submitting thread.
    SPBCStagingRelease(&staging, &next); // Cleanup is idempotent.
    assert(!staging.inFlight.uploads && !staging.inFlight.bytes);
    SPBCStagingRelease(&staging, &timedOut);
    assert(!SPBCStagingReserved(&staging));
}

static void synchronousScratch(void) {
    SPBCStaging staging = {0};
    SPBCStagingReservation pending = {0};
    SPBCStagingAddScratch(&staging, 4096);
    assert(SPBCStagingFits(&staging, SPBCStagingLimit));
    SPBCStagingReserve(&staging, &pending, SPBCStagingLimit);
    assert(staging.scratchBytes == 4096 && staging.overLimit == 0);
    assert(staging.reservedPeak == SPBCStagingLimit + 4096);
    SPBCStagingReleaseScratch(&staging, 4096);
    assert(SPBCStagingReserved(&staging) == SPBCStagingLimit);
    SPBCStagingRelease(&staging, &pending);
    assert(!SPBCStagingReserved(&staging));
}

int main(void) {
    pendingPressure();
    submittedPressure();
    synchronousScratch();
    puts("BC staging tests passed");
}
