// FRONT duty is offered before default economy can enqueue a base job.
// Only task offers mutate native structure ownership; combat can preempt them.
namespace CommanderFront {
    bool wasReady=false;
    const array<string> nanos={"armnanotc","cornanotc","legnanotc","armnanotcplat","cornanotcplat","legnanotcplat"};
    bool Ready() {
        if(Global::AISettings::Role!=AiRole::FRONT || aiFactoryMgr.GetFactoryCount()<1) return false;
        for(uint i=0;i<nanos.length();++i) {
            CCircuitDef@ def=ai.GetCircuitDef(nanos[i]);
            if(def !is null && def.count-aiBuilderMgr.GetUnfinishedCount(def)>=1) return true;
        }
        return false;
    }
    void Update() {
        const bool ready=Ready();
        aiBuilderMgr.SetCommanderCombatOption("front_ready",ready?1.f:0.f);
        if(ready!=wasReady) {
            wasReady=ready;
            GenericHelpers::LogUtil("[CommanderFront] ready="+(ready?1:0),1);
        }
    }
    IUnitTask@ Work(CCircuitUnit@ unit) {
        if(!Ready()) return null;
        // Roles choose the order, definitions and spacing. Native chooses a
        // reachable, locally safe anchor and reuses existing build claims.
        const string side=UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName());
        IUnitTask@ task=aiBuilderMgr.CommanderFrontWork(unit,0,null,Global::Commander::FrontRadius);
        if(task !is null) return task;
        @task=aiBuilderMgr.CommanderFrontWork(unit,1,null,Global::Commander::FrontRadius);
        if(task !is null) return task;
        CCircuitDef@ radar=ai.GetCircuitDef(UnitHelpers::GetStaticRadarNameForSide(side));
        @task=aiBuilderMgr.CommanderFrontWork(unit,2,radar,Global::Commander::FrontRadarSpacing);
        if(task !is null) return task;
        CCircuitDef@ laser=ai.GetCircuitDef(UnitHelpers::GetStaticLLTNameForSide(side));
        @task=aiBuilderMgr.CommanderFrontWork(unit,3,laser,Global::Commander::FrontLaserSpacing);
        if(task !is null) return task;
        return aiBuilderMgr.CommanderFrontWork(unit,4,null,Global::Commander::FrontRadius);
    }
}
