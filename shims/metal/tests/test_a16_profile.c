#include "spa16profile.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const struct {
        uint64_t footprint;
        const char *state;
        bool failed;
    } budgets[] = {
        {0, "ok", false},
        {3072 * SP_A16_MIB, "ok", false},
        {3072 * SP_A16_MIB + 1, "target-exceeded", false},
        {3584 * SP_A16_MIB - 1, "target-exceeded", false},
        {3584 * SP_A16_MIB, "warning", false},
        {SP_A16_BUDGET - 1, "warning", false},
        {SP_A16_BUDGET, "critical", false},
        {SP_A16_BUDGET + 1, "critical", true},
    };
    const struct {
        unsigned long family;
        bool real;
        bool effective;
    } families[] = {
        {1007, true, true},
        {1008, true, true},
        {1008, false, false},
        {1009, true, false},
        {1010, true, false},
        {1011, true, false},
        {2001, true, true},
        {2002, true, false},
        {3003, true, true},
    };
    for (size_t i = 0; i < sizeof budgets / sizeof *budgets; i++) {
        assert(strcmp(spA16BudgetState(budgets[i].footprint), budgets[i].state) == 0);
        assert(spA16BudgetFailed(budgets[i].footprint) == budgets[i].failed);
    }
    for (size_t i = 0; i < sizeof families / sizeof *families; i++) {
        assert(spA16EffectiveFamily(false, families[i].family, families[i].real) == families[i].real);
        assert(spA16EffectiveFamily(true, families[i].family, families[i].real) == families[i].effective);
    }
    assert(spA16EffectiveBC(false, true));
    assert(!spA16EffectiveBC(false, false));
    assert(!spA16EffectiveBC(true, true));
    assert(!spA16EffectiveBC(true, false));
    SPA16MemoryQuery query = {0};
    assert(spA16RecordMemoryQuery(&query, 0));
    assert(!spA16RecordMemoryQuery(&query, 0));
    assert(spA16RecordMemoryQuery(&query, 4096));
    assert(spA16RecordMemoryQuery(&query, 0));
    assert(query.count == 4 && query.lastValue == 0);
    puts("A16 memory query: zero, duplicate, and value changes passed");
    printf("A16 profile: %zu budget cases, %zu family cases, 4 BC cases passed\n",
           sizeof budgets / sizeof *budgets, sizeof families / sizeof *families);
}
