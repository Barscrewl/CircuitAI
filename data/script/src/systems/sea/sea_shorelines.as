// SEA terrain intelligence shared by patrol and submarine station selection.
// Bounded work per census, no per-boat terrain searches. The rotating survey
// refreshes terrain feasibility rather than caching it forever after deformation.
namespace SeaShorelines {
    array<int> shoreline;
    array<AIFloat3> starts;
    array<CCircuitDef@> commanders, constructors, yards;
    int cursor=0, nextCycle=0;
    bool ready=false;
    bool landReady=false;
    array<int> landCells, interiorCells;
    // Reuse the public connected-land map: one O(map cells) pass, no engine
    // callbacks or flood fills per boat. IDs share StrategicSites::land's
    // immutable lifetime. Live threat and movement checks remain mandatory.
    bool PrepareLand() {
        if (landReady) return true;
        // Do not depend on lane generation/overlay being enabled. Analyse the
        // shared water map first: Islands also reads its shore affiliation.
        if (!StrategicSites::mapped) {
            const array<AIFloat3> allies=Lanes::AllyStarts(), enemies=Lanes::EnemyStarts();
            WaterTheatres::Analyse(allies,enemies);
            StrategicSites::Islands(allies,enemies);
        }
        if (StrategicSites::land.length()==0) return false;
        const int width=WaterTheatres::width;
        for (uint index=0;index<StrategicSites::land.length();++index) {
            const int component=StrategicSites::land[index];
            if (component<0) continue;
            if (component>=int(landCells.length())) {
                landCells.resize(component+1); interiorCells.resize(component+1);
            }
            ++landCells[component];
            const int column=int(index)%width;
            if (column>0 && column<width-1 && int(index)>=width && int(index)+width<int(StrategicSites::land.length())
                && StrategicSites::land[index-1]==component && StrategicSites::land[index+1]==component
                && StrategicSites::land[index-width]==component && StrategicSites::land[index+width]==component)
                ++interiorCells[component];
        }
        landReady=true; return true;
    }
    bool Guardable(const AIFloat3 &in position) {
        if (!landReady) return false;
        const int component=StrategicSites::LandAt(position);
        return component>=0 && component<int(landCells.length())
            && SeaMath::GuardableLand(landCells[component],interiorCells[component],
                Global::RoleSettings::Sea::ShoreMinimumLandCells,Global::RoleSettings::Sea::ShoreMinimumInteriorCells);
    }
    bool MeaningfulShore(SeaPatrol::Sector@ sector) {
        for (int direction=0;direction<Directions;++direction) {
            const float angle=direction*AngleStep;
            for (int sample=1;sample<=EdgeSamples;++sample) {
                const float distance=SeaPatrol::cell*float(sample)/EdgeSamples;
                if (Guardable(AIFloat3(sector.pos.x+cos(angle)*distance,0,sector.pos.z+sin(angle)*distance))) return true;
            }
        }
        return false;
    }
    const int Directions=8;
    const int EdgeSamples=8;
    const float AngleStep=0.785398163f;
    const float MinimumDepth=-20.0f;
    const int RefreshSeconds=300;
    const float OpeningYardRadius=1200.0f;
    void Init() {
        if (ready || !PrepareLand()) return;
        ready=true; starts=Lanes::EnemyStarts();
        const array<string> commanderNames={"armcom","corcom","legcom"};
        const array<string> constructorNames={"armck","corck","legck","armcv","corcv","legcv"};
        const array<string> yardNames={"armsy","corsy","legsy"};
        for (uint i=0;i<commanderNames.length();++i) commanders.insertLast(ai.GetCircuitDef(commanderNames[i]));
        for (uint i=0;i<constructorNames.length();++i) constructors.insertLast(ai.GetCircuitDef(constructorNames[i]));
        for (uint i=0;i<yardNames.length();++i) yards.insertLast(ai.GetCircuitDef(yardNames[i]));
        for (uint i=0;i<SeaPatrol::sectors.length();++i) {
            SeaPatrol::Sector@ sector=SeaPatrol::sectors[i];
            sector.enemyDistance=WaterTheatres::Distance(sector.pos,starts);
            // Public water starts also permit an opening commander shipyard
            // away from land. Cover that disk, not only the adjacent beaches.
            sector.shore=MeaningfulShore(sector);
            sector.priority=sector.enemyDistance<=OpeningYardRadius ? 2 : sector.shore ? 1 : 0;
            if (sector.shore) shoreline.insertLast(int(i));
        }
        GenericHelpers::LogUtil("[SEA][ShoreClassification] components="+landCells.length()
            +" meaningfulSectors="+shoreline.length()+" waterSectors="+SeaPatrol::sectors.length(),1);
    }
    bool Reachable(CCircuitDef@ definition,const AIFloat3 &in position) {
        if (definition is null) return false;
        for (uint i=0;i<starts.length();++i)
            if (aiTerrainMgr.CanTraverse(definition,starts[i],position)) return true;
        return false;
    }
    bool YardFits(const AIFloat3 &in water) {
        for (uint i=0;i<yards.length();++i) if (yards[i] !is null)
            for (int facing=0;facing<4;++facing)
                if (aiTerrainMgr.BuildableFraction(yards[i],water,0,0,facing)>=1.0f) return true;
        return false;
    }
    bool ConstructionAccess(SeaPatrol::Sector@ sector) {
        for (int direction=0;direction<Directions;++direction) {
            const float angle=direction*AngleStep;
            const AIFloat3 land=Spam::_Clamp(AIFloat3(sector.pos.x+cos(angle)*SeaPatrol::cell,0,
                sector.pos.z+sin(angle)*SeaPatrol::cell));
            if (!Guardable(land) || aiBattle.Height(land)<0) continue;
            // Sample the water side of the coast, not just the centre of a
            // coarse water cell that may be beyond a constructor's build range.
            for (int sample=1;sample<=EdgeSamples;++sample) {
                const float fraction=float(sample)/EdgeSamples;
                const AIFloat3 water=land+(sector.pos-land)*fraction;
                if (aiBattle.Height(water)>MinimumDepth || !YardFits(water)) continue;
                for (uint i=0;i<commanders.length();++i)
                    if (Reachable(commanders[i],water)) return true;
                const float height=aiBattle.Height(land)-aiBattle.Height(water);
                const float distance=MapHelpers::SqDist(land,water)+height*height;
                for (uint i=0;i<constructors.length();++i) {
                    CCircuitDef@ builder=constructors[i];
                    if (builder !is null && distance<=builder.GetBuildDistance()*builder.GetBuildDistance()
                        && Reachable(builder,land)) return true;
                }
                // Further samples only move away from this dry build position.
                break;
            }
        }
        return false;
    }
    void Tick() {
        Init();
        if (ai.frame<nextCycle || shoreline.length()==0) return;
        const int budget=AiMin(int(shoreline.length()),AiMax(1,Global::RoleSettings::Sea::ShoreAccessCandidatesPerTick));
        for (int work=0;work<budget;++work) {
            SeaPatrol::Sector@ sector=SeaPatrol::sectors[shoreline[cursor]];
            sector.priority=sector.enemyDistance<=OpeningYardRadius || ConstructionAccess(sector) ? 2 : 1;
            sector.enemyDistance=WaterTheatres::Distance(sector.pos,starts);
            if (++cursor>=int(shoreline.length())) { cursor=0; nextCycle=ai.frame+RefreshSeconds*SECOND; break; }
        }
    }
    int Interval(SeaPatrol::Sector@ sector) {
        return AiMax(1,sector.priority==2 ? Global::RoleSettings::Sea::ConstructorShoreRevisitSeconds
            : sector.shore ? Global::RoleSettings::Sea::OtherShoreRevisitSeconds
            : Global::RoleSettings::Sea::InteriorRevisitSeconds)*SECOND;
    }
}

