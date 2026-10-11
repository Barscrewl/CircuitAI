// SEA-only submarine objectives. Terrain is public; threat queries use the
// existing observed snapshot, never hidden enemy positions. Sector leases
// spread cohorts along different shores without per-unit target searches.
namespace SeaSubmarines {
    array<int> shorelineSectors;
    dictionary owners, expiry;
    bool ready=false;
    const int UnknownContactMask=16;
    const int FactoryContactMask=32;
    const int StaticContactMask=8;
    const int DirectionCount=8;
    const float FullCircle=6.283185307f;
    const float MinimumWaterDepth=-20.0f;
    class Focus { int target=-1, body=-1; AIFloat3 position; }
    dictionary focusCells;
    string FocusCell(int body,int x,int z) { return ""+body+":"+x+":"+z; }
    void BeginDecisions() { focusCells.deleteAll(); }
    void MergeSettled() {
        dictionary cells;
        const float radius=AiMax(1.0f,Global::RoleSettings::Sea::FleetCohortRadius);
        for (uint i=0;i<SeaOperations::groups.length();++i) {
            SeaOperations::Cohort@ group=SeaOperations::groups[i];
            if (group.ids.length()==0 || !Handles(ai.GetCircuitDef(group.defId)) || group.target>=0
                || group.target==-7 || !group.released || group.route is null || group.route.IsDead()
                || !group.route.IsAtEnd(ai.GetTeamUnit(group.ids[0]))) continue;
            const int x=int(group.centre.x/radius), z=int(group.centre.z/radius);
            SeaOperations::Cohort@ leader=null;
            for (int dz=-1;dz<=1 && leader is null;++dz) for (int dx=-1;dx<=1 && leader is null;++dx) {
                array<int>@ bucket;
                const string key=SeaOperations::Cell(group.body,group.defId,x+dx,z+dz);
                if (!cells.get(key,@bucket) || bucket is null) continue;
                for (uint candidate=0;candidate<bucket.length();++candidate) {
                    SeaOperations::Cohort@ other=SeaOperations::groups[bucket[candidate]];
                    if (other.ids.length()+group.ids.length()<=uint(AiMax(1,Global::RoleSettings::Sea::SubmarinePerimeterGroupSize))
                        && MapHelpers::SqDist(other.centre,group.centre)<radius*radius) { @leader=other; break; }
                }
            }
            if (leader !is null) {
                // Merge settled reinforcements only. Active combat ownership
                // remains stable; the normal census transfers new members once.
                for (uint member=0;member<group.ids.length();++member) {
                    leader.ids.insertLast(group.ids[member]);
                    SeaOperations::memberGroup.set(""+group.ids[member],leader.key);
                }
                group.ids.resize(0); leader.coastSearch=0;
            } else {
                const string key=SeaOperations::Cell(group.body,group.defId,x,z);
                array<int>@ bucket;
                if (!cells.get(key,@bucket) || bucket is null) { @bucket=array<int>(); cells.set(key,@bucket); }
                bucket.insertLast(int(i));
            }
        }
    }
    int Preferred(SeaOperations::Cohort@ group) {
        const float radius=AiMax(1.0f,Global::RoleSettings::Sea::SubmarineFocusRadius);
        const int x=int(group.centre.x/radius), z=int(group.centre.z/radius);
        int target=-1; float nearest=radius*radius;
        for (int dz=-1;dz<=1;++dz) for (int dx=-1;dx<=1;++dx) {
            Focus@ focus;
            if (!focusCells.get(FocusCell(group.body,x+dx,z+dz),@focus) || focus is null) continue;
            const float distance=MapHelpers::SqDist(group.centre,focus.position);
            if (distance<nearest) { nearest=distance; target=focus.target; }
        }
        return target;
    }
    void Publish(SeaOperations::Cohort@ group,int target) {
        const float radius=AiMax(1.0f,Global::RoleSettings::Sea::SubmarineFocusRadius);
        const string key=FocusCell(group.body,int(group.centre.x/radius),int(group.centre.z/radius));
        if (focusCells.exists(key)) return;
        Focus@ focus=Focus(); focus.target=target; focus.body=group.body; focus.position=group.centre;
        focusCells.set(key,@focus);
    }

    bool Handles(const CCircuitDef@ definition) {
        return definition !is null && Global::RoleSettings::Sea::CombatSubmarineDefinitions.find(definition.GetName())>=0;
    }
    int TargetRank(const CCircuitDef@ definition, int flags) {
        return SeaMath::SubmarineTargetRank(definition !is null && SeaProtection::Flagship(definition),
            (flags&StaticContactMask)!=0,(flags&UnknownContactMask)!=0,(flags&FactoryContactMask)!=0,
            (flags&4)!=0);
    }
    void Reset() { ready=false; shorelineSectors.resize(0); owners.deleteAll(); expiry.deleteAll(); }
    void Init() {
        if (ready) return;
        SeaPatrol::Grid(); SeaShorelines::Init();
        if (!SeaShorelines::ready) return;
        ready=true;
        for (uint index=0;index<SeaPatrol::sectors.length();++index)
            if (SeaPatrol::sectors[index].shore) shorelineSectors.insertLast(int(index));
    }
    bool Safe(const AIFloat3 &in position, int body, float clearance) {
        if (position.x<clearance || position.z<clearance
            || position.x>AiTerrainWidth()-clearance || position.z>AiTerrainHeight()-clearance
            || aiBattle.WaterBody(position,false)!=body
            || aiBattle.AmphThreat(position)>Global::RoleSettings::Sea::SubmarinePerimeterMaximumThreat) return false;
        // Eight bounded probes prevent the offset pointing into the opposite
        // bank of a channel. Native routing still owns hull movement legality.
        for (int direction=0;direction<DirectionCount;++direction) {
            const float angle=float(direction)*FullCircle/float(DirectionCount);
            const AIFloat3 probe(position.x+cos(angle)*clearance,0,position.z+sin(angle)*clearance);
            if (aiBattle.Height(probe)>=MinimumWaterDepth) return false;
        }
        return true;
    }
    bool OutsideStaticTorpedoes(const AIFloat3 &in position, float formationRadius=0) {
        // Same published contact sets and strict radius test; native indexes
        // static weapon envelopes once per publication instead of per cohort.
        return aiBattle.OutsideStaticWaterWeapons(position,
            Global::RoleSettings::Sea::SubmarineShoreSafetyMargin, formationRadius);
    }
    bool ShoreLine(SeaOperations::Cohort@ group,const AIFloat3 &in shore,float distance) {
        if (group.route is null || group.perimeterAdvancing) return true;
        AIFloat3 away=group.goal-shore;
        const float length=AiMax(1.0f,sqrt(away.x*away.x+away.z*away.z)); away=away/length;
        const AIFloat3 tangent(-away.z,0,away.x);
        array<AIFloat3> destinations; destinations.reserve(group.ids.length());
        // Project each slot onto a safe offshore contour. Bounds are cohort
        // size * eight offsets * eight coast probes, only on a new station.
        // Plan all destinations before issuing any override: partial lines
        // must not leave some members advancing after admission fails.
        for (uint i=0;i<group.ids.length();++i) {
            CCircuitUnit@ unit=ai.GetTeamUnit(group.ids[i]); if (unit is null) return false;
            const float lateral=(float(i)-float(group.ids.length()-1)*.5f)*Global::RoleSettings::Sea::SubmarineLineSpacing;
            AIFloat3 point=group.goal+tangent*lateral; bool found=false;
            for (int shift=0;shift<DirectionCount;++shift) {
                const AIFloat3 candidate=point+away*(float(shift)*Global::RoleSettings::Sea::SubmarineLineSpacing);
                if (!Safe(candidate,group.body,distance) || !OutsideStaticTorpedoes(candidate)
                    || !aiTerrainMgr.CanMoveTo(unit,candidate)) continue;
                // Direct override is allowed only along a fully surveyed safe
                // water segment. Keep the existing routed transit otherwise.
                const AIFloat3 origin=unit.GetPos(ai.frame);
                const int samples=AiMax(1,int(sqrt(MapHelpers::SqDist(origin,candidate))/96.0f)+1);
                bool clear=true;
                for (int sample=1;sample<=samples;++sample) {
                    const AIFloat3 probe=origin+(candidate-origin)*(float(sample)/samples);
                    if (aiBattle.Height(probe)>MinimumWaterDepth || !aiTerrainMgr.CanMoveTo(unit,probe)
                        || !OutsideStaticTorpedoes(probe)) { clear=false; break; }
                }
                if (clear) { point=candidate; found=true; break; }
            }
            if (!found) return false;
            destinations.insertLast(point);
        }
        for (uint i=0;i<group.ids.length();++i) {
            CCircuitUnit@ unit=ai.GetTeamUnit(group.ids[i]);
            array<AIFloat3> route={destinations[i]};
            if (!group.route.SetUnitRoute(unit,route,48)) return false;
        }
        return true;
    }
    bool Perimeter(SeaOperations::Cohort@ group, const CCircuitDef@ definition) {
        Init();
        // An empty shoreline index falls through to the same owned hold as
        // an unsafe station; never release submarines to generic land search.
        const float distance=AiMax(Global::RoleSettings::Sea::SubmarineShoreMinimumDistance,
            definition.GetMaxRange(2)*Global::RoleSettings::Sea::SubmarineShoreRangeFraction);
        // Bound every native lane/row offset, not just the cohort centre.
        // Idle membership is capped by the census; use actual occupied offsets,
        // not a fictitious full combat line when testing torpedo envelopes.
        const int columns=AiMin(SeaOperations::FormationColumns(definition),AiMax(1,int(group.ids.length())));
        const float across=float(columns/2)*(Global::RoleSettings::Sea::CoordinatedFleet
            ? Global::RoleSettings::Sea::SubmarineLineSpacing : Global::RoleSettings::Sea::FleetLaneSpacing);
        const float behind=float((int(group.ids.length())-1)/columns)*Global::RoleSettings::Sea::FleetRowSpacing;
        const float formationRadius=sqrt(across*across+behind*behind);
        const float shoreDistance=Global::RoleSettings::Sea::CoordinatedFleet ? distance : distance+formationRadius;
        const float clearance=shoreDistance+Global::RoleSettings::Sea::SubmarineShoreSafetyMargin;
        if (group.perimeterAdvancing && group.coastTarget>=0 && group.coastTarget<int(SeaPatrol::sectors.length())
            && group.route !is null && !group.route.IsDead() && group.route.IsAtEnd(ai.GetTeamUnit(group.ids[0]))) {
            // Keep the assigned shore until arrival. Idle coverage uses the
            // full native water route, not repeated cautious combat advances.
            if (OutsideStaticTorpedoes(group.coastGoal)
                && SeaOperations::Route(group,group.coastGoal,false,true,true,true,false)) {
                group.perimeterAdvancing=MapHelpers::SqDist(group.goal,group.coastGoal)>128.0f*128.0f
                    || MapHelpers::SqDist(group.centre,group.coastGoal)>Global::RoleSettings::Sea::SubmarineAdvanceStep*Global::RoleSettings::Sea::SubmarineAdvanceStep;
                if (ShoreLine(group,SeaPatrol::sectors[group.coastTarget].pos,distance)) return true;
            }
            group.perimeterAdvancing=false;
        }
        if (group.target==-7 && group.route !is null && !group.route.IsDead()
            && ai.frame<group.coastSearch
            && (!group.perimeterAdvancing || !group.route.IsAtEnd(ai.GetTeamUnit(group.ids[0])))
            && (group.perimeterAdvancing ? aiBattle.AmphThreat(group.goal)<=Global::RoleSettings::Sea::SubmarinePerimeterMaximumThreat : Safe(group.goal,group.body,shoreDistance))
            && OutsideStaticTorpedoes(group.goal,group.perimeterAdvancing ? formationRadius : 0)) return true;
        CCircuitUnit@ lead=ai.GetTeamUnit(group.ids[0]);
        const int candidates=AiMin(int(shorelineSectors.length()),Global::RoleSettings::Sea::SubmarinePerimeterCandidates);
        int selected=-1; float nearest=1e30f; AIFloat3 selectedGoal;
        for (int attempt=0;attempt<candidates;++attempt) {
            const int sectorIndex=shorelineSectors[uint(group.search++ + group.serial)%shorelineSectors.length()];
            SeaPatrol::Sector@ sector=SeaPatrol::sectors[sectorIndex];
            if (sector.body!=group.body) continue;
            const string key=""+sectorIndex;
            int owner=-1, until=-1; owners.get(key,owner); expiry.get(key,until);
            if (until>ai.frame && owner!=group.serial) continue;
            for (int direction=0;direction<DirectionCount;++direction) {
                const float angle=float(direction)*FullCircle/float(DirectionCount);
                const AIFloat3 goal(sector.pos.x+cos(angle)*clearance,0,sector.pos.z+sin(angle)*clearance);
                if (!Safe(goal,group.body,shoreDistance) || !aiTerrainMgr.CanReachAt(lead,goal,64)) continue;
                // Prefer viable enemy-facing construction shores, while still
                // charging for transit. Geometry/threat rejection precedes score.
                const float actualTravel=MapHelpers::SqDist(group.centre,goal);
                const float travel=Global::RoleSettings::Sea::CoordinatedFleet
                    ? sqrt(actualTravel)+sector.enemyDistance-float(sector.priority)*Global::RoleSettings::Sea::ShoreTravelScoreScale
                    : actualTravel;
                if (travel<nearest) { nearest=travel; selected=sectorIndex; selectedGoal=goal; }
            }
        }
        if (selected>=0) {
            // One path search after bounded scoring, not one for every cove.
            if (OutsideStaticTorpedoes(selectedGoal,Global::RoleSettings::Sea::CoordinatedFleet ? 0 : formationRadius)
                && SeaOperations::Route(group,selectedGoal,false,true,true,true,false)) {
                group.target=-7; group.route.SetNavalTarget(-1);
                group.coastGoal=selectedGoal; group.coastTarget=selected;
                group.perimeterAdvancing=MapHelpers::SqDist(group.goal,selectedGoal)>128.0f*128.0f
                    || MapHelpers::SqDist(group.centre,selectedGoal)>Global::RoleSettings::Sea::SubmarineAdvanceStep*Global::RoleSettings::Sea::SubmarineAdvanceStep;
                if (Global::RoleSettings::Sea::CoordinatedFleet && !ShoreLine(group,SeaPatrol::sectors[selected].pos,distance)) {
                    // No unsafe partial formation. The next survey can select
                    // another station; hold under SEA ownership meanwhile.
                    SeaOperations::Route(group,group.centre,true,true,true);
                    owners.set(""+selected,-2); expiry.set(""+selected,ai.frame+Global::RoleSettings::Sea::FleetSearchSeconds*SECOND);
                    group.coastSearch=ai.frame+Global::RoleSettings::Sea::FleetSearchSeconds*SECOND;
                    group.retry=group.coastSearch;
                    return true;
                }
                group.coastSearch=ai.frame+(Global::RoleSettings::Sea::SubmarinePerimeterSeconds
                    +int(sqrt(MapHelpers::SqDist(group.centre,selectedGoal))/AiMax(1.0f,definition.GetSpeed())))*SECOND;
                owners.set(""+selected,group.serial); expiry.set(""+selected,group.coastSearch);
                GenericHelpers::LogUtil("[SEA][SubPerimeter] cohort="+group.serial+" sector="+selected
                    +" range="+definition.GetMaxRange(2)+" clearance="+distance+" goal="+int(selectedGoal.x)+","+int(selectedGoal.z),1);
                return true;
            }
            // Fall through to a hold if the selected route is blocked. Keeping
            // the previous advance alive would defeat the safety rejection.
        }
        // No safe site is permission to wait/reconsider, not to hug a beach.
        group.retry=ai.frame+Global::RoleSettings::Sea::FleetSearchSeconds*SECOND;
        // Keep SEA ownership while waiting. Aborting to native assault here
        // would immediately recreate the shoreline search we just rejected.
        if (SeaOperations::Route(group,group.centre,true,true,true)) {
            group.target=-7; group.route.SetNavalTarget(-1);
        }
        return true;
    }
}
