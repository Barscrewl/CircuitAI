void test_full_metal_releases_reactor_even_with_full_energy_and_pending_conversion() {
    Check(EcoPlanner::DecideConversion(true,true,1,2,true,true,true,true,false) == EcoPlanner::METAL_FULL);
}
void test_saturated_installed_capacity_releases_first_reactor_without_air_worker() {
    Check(EcoPlanner::DecideConversion(false,true,0,2,false,true,true,true,false) == EcoPlanner::CAPACITY);
}
void test_pending_converter_retains_its_supply_commitment() {
    Check(EcoPlanner::DecideConversion(false,true,1,2,false,true,true,true,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,2,2,true,true,true,true,false) == EcoPlanner::PENDING);
}
void test_failed_placement_releases_reactor_but_success_remains_eligible() {
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,true,true) == EcoPlanner::PLACEMENT);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,true,false) == EcoPlanner::READY);
}
void test_missing_capped_unbuildable_and_income_gated_conversion_cannot_hold_reactor() {
    Check(EcoPlanner::DecideConversion(false,false,0,2,true,true,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,false,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,false,true,false) == EcoPlanner::UNBUILDABLE);
    Check(EcoPlanner::DecideConversion(false,true,0,2,true,true,true,false,false) == EcoPlanner::INCOME);
}

void test_disabled_parallelism_is_not_a_phantom_pending_task() {
    Check(EcoPlanner::DecideConversion(false,true,0,0,true,true,true,true,false) == EcoPlanner::UNAVAILABLE);
    Check(EcoPlanner::DecideConversion(false,true,1,0,true,true,true,true,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,1,2,true,true,true,false,false) == EcoPlanner::PENDING);
    Check(EcoPlanner::DecideConversion(false,true,1,2,true,true,true,true,false) == EcoPlanner::READY);
}
