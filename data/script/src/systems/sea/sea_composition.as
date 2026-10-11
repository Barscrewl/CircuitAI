// Count baseline is separate from emergency coverage. Native pending counts
// own frame/task lifecycle; never maintain a second speculative hull counter.
namespace SeaComposition {
    CCircuitDef@ Select(CCircuitUnit@ yard,const dictionary &in localCounts) {
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        const bool advanced=UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName());
        array<string> names;
        if (advanced) names=side=="armada" ? Global::RoleSettings::Sea::ArmadaTierTwoComposition
            : side=="cortex" ? Global::RoleSettings::Sea::CortexTierTwoComposition : Global::RoleSettings::Sea::LegionTierTwoComposition;
        else names=side=="armada" ? Global::RoleSettings::Sea::ArmadaTierOneComposition
            : side=="cortex" ? Global::RoleSettings::Sea::CortexTierOneComposition : Global::RoleSettings::Sea::LegionTierOneComposition;
        const array<float> ratios={Global::RoleSettings::Sea::SubmarineCompositionRatio,
            Global::RoleSettings::Sea::FrigateCompositionRatio,Global::RoleSettings::Sea::DestroyerCompositionRatio};
        if (names.length()!=ratios.length()) {
            Invariants::Violation("INV-185",side,"SEA composition must define submarine, screen and heavy hull");
            return null;
        }
        CCircuitDef@ selected=null; float best=-1e30f; int frigates=0;
        for (uint i=0;i<names.length() && i<ratios.length();++i) {
            CCircuitDef@ definition=ai.GetCircuitDef(names[i]);
            if (definition is null) continue;
            const int count=DictIntOr(localCounts,""+definition.id)+aiFactoryMgr.GetPendingRecruitCount(definition);
            if (i==1) frigates=count;
            if (!definition.IsAvailable(ai.frame) || !yard.circuitDef.CanBuild(definition)) continue;
            const float score=SeaMath::CompositionDeficit(count,ratios[i]);
            if (score>best) { best=score; @selected=definition; }
        }
        const string antiAirName=advanced ? (side=="armada" ? "armaas" : side=="cortex" ? "corarch" : "leganavyaaship")
            : (side=="armada" ? "armpt" : side=="cortex" ? "corpt" : "legnavyaaship");
        CCircuitDef@ antiAir=ai.GetCircuitDef(antiAirName);
        const int perShip=AiMax(1,Global::RoleSettings::Sea::FrigatesPerAntiAirShip);
        if (advanced) {
            CCircuitDef@ frigate=ai.GetCircuitDef(side=="armada" ? "armpship" : side=="cortex" ? "corpship" : "legnavyfrigate");
            if (frigate !is null) frigates+=DictIntOr(localCounts,""+frigate.id)+aiFactoryMgr.GetPendingRecruitCount(frigate);
        }
        if (antiAir !is null && antiAir.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(antiAir)
            && DictIntOr(localCounts,""+antiAir.id)+aiFactoryMgr.GetPendingRecruitCount(antiAir)<(frigates+perShip-1)/perShip)
            return antiAir;
        return selected;
    }
    class Batch { int yard=-1; array<IUnitTask@> tasks; }
    array<Batch@> batches;
    void CancelUnstarted(Batch@ batch) {
        for (uint i=0;i<batch.tasks.length();++i) {
            IUnitTask@ task=batch.tasks[i];
            if (task is null || task.IsDead()) continue;
            IBuilderTask@ build=cast<IBuilderTask>(task);
            if (build !is null && build.target is null && task.GetUnits().length()==0) task.Abort();
        }
    }
    void Prune() {
        // O(number of yards * bounded batch size) once per SEA census. Tasks
        // retain safe ref-counted handles; units are reacquired by ID.
        for (int i=int(batches.length())-1;i>=0;--i) {
            Batch@ batch=batches[i];
            CCircuitUnit@ yard=ai.GetTeamUnit(batch.yard);
            if (yard is null || !SeaCombat::Active() || SeaFactories::Hold(yard)) CancelUnstarted(batch);
            for (int j=int(batch.tasks.length())-1;j>=0;--j)
                if (batch.tasks[j] is null || batch.tasks[j].IsDead()) batch.tasks.removeAt(j);
            if (batch.tasks.length()==0) batches.removeAt(i);
        }
    }
    IUnitTask@ Pending(CCircuitUnit@ yard,bool cancel=false) {
        for (uint i=0;i<batches.length();++i) if (batches[i].yard==yard.id) {
            if (cancel) { CancelUnstarted(batches[i]); return null; }
            for (uint j=0;j<batches[i].tasks.length();++j) {
                IUnitTask@ task=batches[i].tasks[j];
                if (task !is null && !task.IsDead()) return task;
            }
        }
        return null;
    }
    IUnitTask@ Enqueue(CCircuitUnit@ yard,CCircuitDef@ definition) {
        Batch@ batch=Batch(); batch.yard=yard.id;
        const int count=AiMax(1,AiMin(12,Global::RoleSettings::Sea::FleetRecruitBatch));
        for (int i=0;i<count;++i) {
            IUnitTask@ task=SeaFactories::Recruit(yard,definition,Task::RecruitType::FIREPOWER);
            if (task is null) break;
            batch.tasks.insertLast(task);
        }
        if (batch.tasks.length()==0) return null;
        batches.insertLast(batch);
        GenericHelpers::LogUtil("[SEA][Batch] yard="+yard.id+" unit="+definition.GetName()+" count="+batch.tasks.length(),1);
        return batch.tasks[0];
    }
}
