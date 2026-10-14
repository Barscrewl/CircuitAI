#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../settings/shared/scout_raid.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/math/scout_raid_math.as"

// D-296: non-spam land scouts raid the enemy backline - extractors,
// construction turrets and wind - and wrap around armed enemies.
//
// Policy only. Native mechanism: aiBattle.GroundHazard (observed armed ground
// coverage, lazy per 1 s publication), aiBattle.GetUnitRaidRoute (dry unit
// route with that coverage as a soft per-cell penalty), CRouteTask
// SetLandTarget (BAR priority target, no ATTACK chase) and the ground
// contact kind flags. One CRouteTask per raider.
//
// Cost (16 AIs): Tick once per second per AI, O(G*R + R*3) with G observed
// ground contacts and R <= MaxRaiders; no per-unit scans of our army. Route
// solves are synchronous and capped at MaxRoutesPerSecond per AI (a latency
// budget for this new behaviour only; replans are event-driven: target lost,
// hazard ahead, stuck). Commands: one compacted shift-MOVE batch plus at most
// one SET_TARGET per replan. No cross-AI messages.
namespace ScoutRaid {
    final class Raider {
        int id = -1;
        CRouteTask@ task;
        int target = -1;            // enemy unit id, -1 = travelling to a fallback goal
        AIFloat3 targetPos;
        int excluded = -1;          // target given up after repeated hazard replans
        array<AIFloat3> route;      // the compacted route last issued
        uint cursor = 0;            // first route point not yet reached
        AIFloat3 lastPos;
        int lastMove = 0;
        int nextReplan = 0;
        int hazardSince = -1;
        int hazardReplans = 0;
        bool queued = false;
    }

    array<Raider@> raiders;
    array<int> natives;             // scout ids deliberately left to native CScoutTask
    array<int> replanQueue;         // raider ids, FIFO
    int lastTick = -100000;
    bool configRead = false, jsonEnabled = false;
    dictionary unitSet;
    bool unitsReady = false;

    bool Active()
    {
        if (!configRead) {
            // Configuration is fixed for this AI instance.
            // Native CSetupManager::CloseConfig keeps the "scout_raid" section
            // readable after init (D-296); other sections are gone by now.
            jsonEnabled = aiSetupMgr.ConfigBool("scout_raid/enabled", false);
            configRead = true;
            string units;
            for (uint i = 0; i < Global::ScoutRaid::Units.length(); ++i) units += (i > 0 ? "," : "") + Global::ScoutRaid::Units[i];
            GenericHelpers::LogUtil("[ScoutRaid] enabled=" + (Global::ScoutRaid::Enabled && jsonEnabled) + " json=" + jsonEnabled
                + " units=" + units + " max=" + Global::ScoutRaid::MaxRaiders + " keepNative=" + Global::ScoutRaid::KeepNativeScouts, 1);
        }
        return Global::ScoutRaid::Enabled && jsonEnabled;
    }

    bool IsRaidDef(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (!unitsReady) {
            for (uint i = 0; i < Global::ScoutRaid::Units.length(); ++i) unitSet.set(Global::ScoutRaid::Units[i], true);
            unitsReady = true;
        }
        return unitSet.exists(d.GetName()) && !Spam::IsSpamDef(d);
    }

    Raider@ Find(int id)
    {
        for (uint i = 0; i < raiders.length(); ++i) if (raiders[i].id == id) return raiders[i];
        return null;
    }

    float KindWeight(int kind)
    {
        float w = 0.0f;
        if ((kind & 4) != 0) w = AiMax(w, Global::ScoutRaid::NanoWeight);   // CBattleAnalysis::K_NANO
        if ((kind & 1) != 0) w = AiMax(w, Global::ScoutRaid::MexWeight);    // K_MEX
        if ((kind & 2) != 0) w = AiMax(w, Global::ScoutRaid::WindWeight);   // K_WIND
        if ((kind & 8) != 0) w = AiMax(w, Global::ScoutRaid::OtherEconomyWeight); // K_OTHER_ECO
        return w;
    }

    bool IsRaidKind(int kind) { return KindWeight(kind) > 0.0f; }

    float Range(const CCircuitDef@ d)
    {
        return AiMax(48.0f, d.GetMaxRange() * Global::ScoutRaid::StandoffFraction);
    }

    AIFloat3 Standoff(const AIFloat3& in from, const AIFloat3& in target, float range)
    {
        const float distance = from.distance2D(target);
        if (distance <= range) return from;
        AIFloat3 p = target + (from - target) * (range / distance);
        p.y = aiBattle.Height(p);
        return p;
    }

    // Best economy target by ScoutRaidMath::Score whose standoff point lies
    // outside observed armed coverage. O(G). radius < 0 means anywhere.
    int Choose(const AIFloat3& in from, const AIFloat3& in near, float radius, int exclude,
        const array<AIFloat3>& in starts, const AIFloat3& in front, float range, AIFloat3& out pos)
    {
        int best = -1;
        float bestScore = 0.0f;
        pos = from;
        const int n = aiBattle.GetGroundContactCount();
        for (int i = 0; i < n; ++i) {
            const int kind = aiBattle.GetGroundContactKind(i);
            const float weight = KindWeight(kind);
            if (weight <= 0.0f) continue;
            const int id = aiBattle.GetGroundContactId(i);
            if (id == exclude) continue;
            const AIFloat3 p = aiBattle.GetGroundContactPos(i);
            if (radius >= 0.0f && MapHelpers::SqDist(p, near) > radius * radius) continue;
            float toStart = -1.0f;
            for (uint s = 0; s < starts.length(); ++s) {
                const float d = p.distance2D(starts[s]);
                if (toStart < 0.0f || d < toStart) toStart = d;
            }
            const float fromFront = front.x < 0.0f ? -1.0f : p.distance2D(front);
            float score = ScoutRaidMath::Score(weight, aiBattle.GetGroundContactCost(i),
                ScoutRaidMath::Rear(toStart, fromFront), from.distance2D(p));
            // Spread raiders: a target another raider already holds is worth less.
            for (uint r = 0; r < raiders.length(); ++r) if (raiders[r].target == id) { score *= 0.5f; break; }
            if (score <= bestScore) continue;
            // A defended target (standoff inside coverage) is skipped, not fought.
            if (aiBattle.GroundHazard(Standoff(from, p, range), Global::ScoutRaid::HazardMargin) > 0.0f) continue;
            best = id; bestScore = score; pos = p;
        }
        return best;
    }

    AIFloat3 FallbackGoal(const AIFloat3& in from, const array<AIFloat3>& in starts)
    {
        AIFloat3 goal(-1.0f, 0.0f, -1.0f);
        float nearest = 1e30f;
        for (uint i = 0; i < starts.length(); ++i) {
            const float d = MapHelpers::SqDist(from, starts[i]);
            if (d < nearest) { nearest = d; goal = starts[i]; }
        }
        return goal;
    }

    // Compact a 64-elmo grid route: turns, reversals and every WaypointSpacing.
    array<AIFloat3>@ Compact(const array<AIFloat3>& in points)
    {
        array<AIFloat3> result;
        if (points.length() == 0) return result;
        result.reserve(points.length() / 3 + 2);
        result.insertLast(points[0]);
        float since = 0.0f;
        for (uint i = 1; i + 1 < points.length(); ++i) {
            const AIFloat3 a = points[i - 1], b = points[i], c = points[i + 1];
            since += a.distance2D(b);
            if (ScoutRaidMath::Keep(b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z, since, Global::ScoutRaid::WaypointSpacing)) {
                result.insertLast(b); since = 0.0f;
            }
        }
        if (points.length() > 1) result.insertLast(points[points.length() - 1]);
        return result;
    }

    CRouteTask@ NewRoute()
    {
        IUnitTask@ task = aiMilitaryMgr.Enqueue(TaskF::Route());
        CRouteTask@ route = cast<CRouteTask>(cast<IFighterTask>(task));
        if (route is null) return null;
        route.SetTraversal(true, 48.0f, false);
        route.SetHoldPosition(true);   // never chase: wrap-around is the route's job
        route.SetLanes(1, 0, 0);
        return route;
    }

    void Plan(Raider@ r, CCircuitUnit@ u)
    {
        const AIFloat3 pos = u.GetPos(ai.frame);
        const array<AIFloat3> starts = Lanes::EnemyStarts();
        const AIFloat3 front = aiMilitaryMgr.GetCombatFocusPos();
        const float range = Range(u.circuitDef);
        int target = r.target;
        AIFloat3 targetPos = r.targetPos;
        if (target >= 0 && r.hazardReplans >= 2) {
            // The only approach to this target stays covered: give it up.
            r.excluded = target; target = -1; r.hazardReplans = 0;
        }
        if (target < 0 || !ContactAlive(target, targetPos)) {
            const AIFloat3 last = r.target >= 0 ? r.targetPos : pos;
            target = Choose(pos, last, Global::ScoutRaid::ChainRadius, r.excluded, starts, front, range, targetPos);
            if (target < 0) target = Choose(pos, pos, -1.0f, r.excluded, starts, front, range, targetPos);
        }
        const AIFloat3 goal = target >= 0 ? Standoff(pos, targetPos, range) : FallbackGoal(pos, starts);
        r.nextReplan = ai.frame + Global::ScoutRaid::ReplanCooldownSeconds * SECOND;
        r.queued = false;
        r.hazardSince = -1;
        r.lastMove = ai.frame; r.lastPos = pos;
        if (goal.x < 0.0f) return;
        array<AIFloat3>@ path = aiBattle.GetUnitRaidRoute(u.circuitDef, pos, goal,
            Global::ScoutRaid::HazardMargin, Global::ScoutRaid::HazardWeight);
        if (path is null || path.length() < 2) {
            if (target >= 0) r.excluded = target;   // unreachable: try another next time
            GenericHelpers::LogUtil("[ScoutRaid] no route unit=" + r.id + " target=" + target, 2);
            return;
        }
        r.route = Compact(path);
        r.cursor = 0;
        r.task.SetRoute(r.route);
        // A contact the engine will not accept as a priority target still
        // gets the route; the held priority is then cleared (INV-211).
        if (!r.task.SetLandTarget(target)) r.task.SetLandTarget(-1);
        if (target != r.target) r.hazardReplans = 0;
        r.target = target; r.targetPos = targetPos;
        GenericHelpers::LogUtil("[ScoutRaid] route unit=" + r.id + " target=" + target + " points=" + r.route.length()
            + " goal=(" + int(goal.x) + "," + int(goal.z) + ")", 1);
    }

    // Current observed ground contact of this id? O(G); only on replans.
    bool ContactAlive(int id, AIFloat3& out pos)
    {
        pos = AIFloat3(-1.0f, 0.0f, -1.0f);
        if (id < 0) return false;
        const int n = aiBattle.GetGroundContactCount();
        for (int i = 0; i < n; ++i) {
            if (aiBattle.GetGroundContactId(i) != id) continue;
            pos = aiBattle.GetGroundContactPos(i);
            return true;
        }
        return false;
    }

    void Queue(Raider@ r)
    {
        if (r.queued) return;
        r.queued = true;
        replanQueue.insertLast(r.id);
    }

    void Drop(uint index)
    {
        Raider@ r = raiders[index];
        const int q = replanQueue.find(r.id);
        if (q >= 0) replanQueue.removeAt(uint(q));
        CRouteTask@ task = r.task;
        raiders.removeAt(index);
        if (task !is null && !task.IsDead()) task.Abort();
    }

    void PruneNatives()
    {
        for (int i = int(natives.length()) - 1; i >= 0; --i)
            if (ai.GetTeamUnit(natives[i]) is null) natives.removeAt(uint(i));
    }

    // Military::AiMakeTask, after Spam and before the ranged controller.
    IUnitTask@ MilitaryMakeTask(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null || !Active() || !IsRaidDef(u.circuitDef)) return null;
        PruneNatives();
        if (natives.find(u.id) >= 0) return null;   // a recon scout stays native
        // A raider asking again lost its task (abort, stuck recovery): release it.
        for (int i = int(raiders.length()) - 1; i >= 0; --i) if (raiders[i].id == u.id) Drop(uint(i));
        if (int(natives.length()) < Global::ScoutRaid::KeepNativeScouts) {
            natives.insertLast(u.id);
            return null;
        }
        if (int(raiders.length()) >= Global::ScoutRaid::MaxRaiders) return null;
        CRouteTask@ task = NewRoute();
        if (task is null) return null;
        Raider@ r = Raider();
        r.id = u.id; @r.task = task;
        r.lastPos = u.GetPos(ai.frame); r.lastMove = ai.frame;
        array<AIFloat3> hold = {r.lastPos};
        task.SetRoute(hold);
        raiders.insertLast(r);
        Queue(r);
        GenericHelpers::LogUtil("[ScoutRaid] admit unit=" + u.id + " def=" + u.circuitDef.GetName()
            + " raiders=" + raiders.length(), 1);
        return task;
    }

    void TaskRemoved(IUnitTask@ task)
    {
        for (uint i = 0; i < raiders.length(); ++i) if (raiders[i].task is task) @raiders[i].task = null;
    }

    void UnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        for (int i = int(raiders.length()) - 1; i >= 0; --i) if (raiders[i].id == unit.id) Drop(uint(i));
        const int n = natives.find(unit.id);
        if (n >= 0) natives.removeAt(uint(n));
    }

    void Reset()
    {
        array<Raider@> old = raiders;
        raiders.resize(0); replanQueue.resize(0); natives.resize(0);
        for (uint i = 0; i < old.length(); ++i)
            if (old[i].task !is null && !old[i].task.IsDead()) old[i].task.Abort();
    }

    // Main::AiUpdate (every 30 frames); self-limited to once per second.
    void Tick()
    {
        if (ai.frame < lastTick + SECOND) return;
        lastTick = ai.frame;
        if (!Active()) { if (raiders.length() > 0) Reset(); return; }
        if (raiders.length() == 0) return;
        const float margin = Global::ScoutRaid::HazardMargin;
        const int cooldown = Global::ScoutRaid::ReplanCooldownSeconds * SECOND;
        for (int i = int(raiders.length()) - 1; i >= 0; --i) {
            Raider@ r = raiders[i];
            CCircuitUnit@ u = ai.GetTeamUnit(r.id);
            if (u is null || r.task is null || r.task.IsDead() || u.task !is r.task) { Drop(uint(i)); continue; }
            const AIFloat3 pos = u.GetPos(ai.frame);
            // INV-211: the raider's priority target is its chosen economy target.
            const int held = r.task.GetPriorityTarget();
            if (held >= 0 && held != r.target)
                Invariants::Violation("INV-211", "" + r.id, "scout raider " + r.id + " holds target " + held
                    + " not chosen by ScoutRaid (" + r.target + ")");
            bool targetLost = r.target >= 0;
            if (r.target >= 0) {
                const int n = aiBattle.GetGroundContactCount();
                for (int c = 0; c < n; ++c) {
                    if (aiBattle.GetGroundContactId(c) != r.target) continue;
                    targetLost = false;
                    if (!IsRaidKind(aiBattle.GetGroundContactKind(c)))
                        Invariants::Violation("INV-211", "" + r.id, "scout raider " + r.id + " targets non-economy contact " + r.target);
                    break;
                }
            }
            // Progress along the issued route; stuck detection.
            while (r.cursor < r.route.length() && MapHelpers::SqDist(pos, r.route[r.cursor]) < 128.0f * 128.0f) ++r.cursor;
            if (MapHelpers::SqDist(pos, r.lastPos) > 64.0f * 64.0f) { r.lastPos = pos; r.lastMove = ai.frame; }
            const bool atEnd = r.task.IsAtEnd(u);
            const bool stuck = !atEnd && ai.frame - r.lastMove > Global::ScoutRaid::StuckSeconds * SECOND;
            // Wrap-around trigger: a contact now covers one of the next 3 waypoints.
            bool hazardAhead = false;
            for (uint k = r.cursor; k < r.route.length() && k < r.cursor + 3; ++k)
                if (aiBattle.GroundHazard(r.route[k], margin) > 0.0f) { hazardAhead = true; break; }
            if (hazardAhead) { if (r.hazardSince < 0) r.hazardSince = ai.frame; }
            else r.hazardSince = -1;
            const bool idleAtEnd = atEnd && r.target < 0;
            if ((targetLost || hazardAhead || stuck || idleAtEnd) && ai.frame >= r.nextReplan) {
                if (hazardAhead && !targetLost) ++r.hazardReplans;
                if (targetLost && LOG_LEVEL >= 1)
                    GenericHelpers::LogUtil("[ScoutRaid] target gone unit=" + r.id + " target=" + r.target, 1);
                Queue(r);
            }
            // INV-212: covered waypoints ahead get a queued replan in time.
            if (ScoutRaidMath::HazardOverdue(r.hazardSince, ai.frame, cooldown, 2 * SECOND, r.queued))
                Invariants::Violation("INV-212", "" + r.id, "scout raider " + r.id + " keeps a covered route without a replan");
        }
        // Serve replans FIFO within the per-second route budget.
        int budget = Global::ScoutRaid::MaxRoutesPerSecond;
        while (budget > 0 && replanQueue.length() > 0) {
            const int id = replanQueue[0];
            replanQueue.removeAt(0);
            Raider@ r = Find(id);
            if (r is null) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null || r.task is null) { r.queued = false; continue; }
            Plan(r, u);
            --budget;
        }
        // INV-213: raider count bound and spam exclusion.
        if (int(raiders.length()) > Global::ScoutRaid::MaxRaiders)
            Invariants::Violation("INV-213", "count", "scout raiders " + raiders.length() + " exceed " + Global::ScoutRaid::MaxRaiders);
        for (uint i = 0; i < raiders.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(raiders[i].id);
            if (u !is null && Spam::IsSpamDef(u.circuitDef))
                Invariants::Violation("INV-213", "" + raiders[i].id, "spam unit " + raiders[i].id + " is a scout raider");
        }
    }
}
