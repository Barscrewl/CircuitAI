// Publish optional native withdrawal waypoints, never take over RETREAT tasks.
// One local bucket index per SEA census: O(groups + ships + local candidates),
// with dense-bucket worst case explicit. Native code revalidates anchor/expiry.
namespace SeaRetreat {
    const float BehindLine=192.0f;
    const float WithdrawalSpacing=48.0f;
    const int WithdrawalSlots=9;
    const int WaypointSeconds=45;
    string Cell(int body,int x,int z) { return ""+body+":"+x+":"+z; }
    void Publish() {
        dictionary cells;
        const float radius=AiMax(1.0f,Global::RoleSettings::Sea::SubmarineRetreatRadius);
        for (uint i=0;i<SeaOperations::groups.length();++i) {
            SeaOperations::Cohort@ group=SeaOperations::groups[i];
            if (group.ids.length()==0 || !SeaSubmarines::Handles(ai.GetCircuitDef(group.defId))) continue;
            const string key=Cell(group.body,int(group.centre.x/radius),int(group.centre.z/radius));
            array<int>@ bucket;
            if (!cells.get(key,@bucket) || bucket is null) { @bucket=array<int>(); cells.set(key,@bucket); }
            bucket.insertLast(int(i));
        }
        for (uint i=0;i<SeaCombat::owned.length();++i) {
            CCircuitUnit@ ship=ai.GetTeamUnit(SeaCombat::owned[i]);
            if (ship is null || !ship.circuitDef.IsMobile() || ship.circuitDef.IsAbleToFly()
                || ship.circuitDef.GetBuildSpeed()>0 || SeaSubmarines::Handles(ship.circuitDef)) continue;
            // Explicit fixed-size naval roster avoids changing amphibious land
            // invasion retreats merely because those units entered water.
            bool naval=false;
            for (uint hull=0;hull<SeaCombat::roster.length();++hull)
                if (SeaCombat::roster[hull].def is ship.circuitDef) { naval=true; break; }
            if (!naval) continue;
            if (ship.task !is null && (ship.task.GetType()==int(Task::Type::RETREAT)
                || ship.task.GetType()==int(Task::Type::PLAYER) || ship.task.IsExternalControlled())) continue;
            const AIFloat3 position=ship.GetPos(ai.frame);
            const int body=aiBattle.WaterBody(position,false);
            if (body<0) continue;
            const int x=int(position.x/radius), z=int(position.z/radius);
            int anchor=-1; AIFloat3 goal; float nearest=radius*radius;
            const float currentThreat=aiBattle.SurfThreat(position);
            for (int dz=-1;dz<=1;++dz) for (int dx=-1;dx<=1;++dx) {
                array<int>@ bucket;
                if (!cells.get(Cell(body,x+dx,z+dz),@bucket) || bucket is null) continue;
                for (uint candidate=0;candidate<bucket.length();++candidate) {
                    SeaOperations::Cohort@ group=SeaOperations::groups[bucket[candidate]];
                    // Cohorts have a bounded membership. Select a real nearby
                    // anchor so wide lines do not fail the native drift check.
                    CCircuitUnit@ closest=null; float anchorDistance=radius*radius;
                    for (uint member=0;member<group.ids.length();++member) {
                        CCircuitUnit@ submarine=ai.GetTeamUnit(group.ids[member]);
                        if (submarine is null) continue;
                        const float separation=MapHelpers::SqDist(position,submarine.GetPos(ai.frame));
                        if (separation<anchorDistance) { anchorDistance=separation; @closest=submarine; }
                    }
                    if (closest is null) continue;
                    const AIFloat3 anchorPosition=closest.GetPos(ai.frame);
                    AIFloat3 direction=Global::Map::StartPos-anchorPosition;
                    const float length=AiMax(1.0f,sqrt(direction.x*direction.x+direction.z*direction.z));
                    const AIFloat3 tangent(-direction.z/length,0,direction.x/length);
                    const float offset=float(ship.id%WithdrawalSlots-WithdrawalSlots/2)*WithdrawalSpacing;
                    const AIFloat3 point=anchorPosition+direction*(BehindLine/length)+tangent*offset;
                    // WaterBody clamps its cell lookup to the map; it cannot
                    // validate a world position. Offset edge anchors may leave
                    // the map, whereas CanReachAt requires a valid sector.
                    // Reject before terrain/threat callbacks (O(1), no query or
                    // allocation); retain normal retreat when no valid hint fits.
                    if (!ProductionMath::Inside(point.x,point.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) continue;
                    const float distance=MapHelpers::SqDist(position,point);
                    // Withdraw toward friendly depth, not a more forward sub.
                    if (distance>=nearest || MapHelpers::SqDist(point,Global::Map::StartPos)>=MapHelpers::SqDist(position,Global::Map::StartPos)
                        || aiBattle.SurfThreat(point)>currentThreat || aiBattle.WaterBody(point,false)!=body) continue;
                    nearest=distance; goal=point; anchor=closest.id;
                }
            }
            if (anchor>=0 && !ProductionMath::Inside(goal.x,goal.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) {
                Invariants::Violation("INV-188","SEA","retreat waypoint outside map");
                anchor=-1;
            }
            if (anchor>=0 && !aiTerrainMgr.CanReachAt(ship,goal,128)) anchor=-1;
            ship.SetRetreatWaypoint(goal,anchor,ai.frame+WaypointSeconds*SECOND);
        }
    }
}
