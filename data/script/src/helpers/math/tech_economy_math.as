// Pure decision table shared by conversion admission and its actual-VM tests.
namespace EcoPlanner {
    enum ConversionReason { READY, PENDING, CAPACITY, METAL_FULL, UNAVAILABLE, UNBUILDABLE, INCOME, PLACEMENT, NO_OPTION }
    ConversionReason DecideConversion(bool metalFull, bool defined, int pending, int parallel,
        bool supplied, bool available, bool buildable, bool income, bool placementRejected) {
        if (metalFull) return METAL_FULL;
        if (!defined) return UNAVAILABLE;
        if (pending > 0 && pending >= parallel) return PENDING;
        if (parallel <= 0) return UNAVAILABLE;
        if (!supplied) return pending > 0 ? PENDING : CAPACITY;
        if (!available) return pending > 0 ? PENDING : UNAVAILABLE;
        if (!buildable) return pending > 0 ? PENDING : UNBUILDABLE;
        if (!income) return pending > 0 ? PENDING : INCOME;
        if (placementRejected) return pending > 0 ? PENDING : PLACEMENT;
        return READY;
    }
}
