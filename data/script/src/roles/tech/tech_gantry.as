#include "../../helpers/math/gantry_math.as"
#include "../../helpers/math/heavy_rush_math.as"

// TECH-only policy over the existing factory reservations and native recovery.
// No private factory registry, army scan, command loop or random draw.
namespace TechGantry {
    GantryMath::IncomeWindow metalWindow;
    int earlyStartFrame = -1;
    bool earlyDeferred = false;
    int nextLogFrame = 0;

    bool RecoveryEnabled() {
        return Global::AISettings::Role == AiRole::TECH
            && Global::RoleSettings::Tech::ExperimentalBuild
            && Global::RoleSettings::Tech::LayoutEnabled
            && Global::RoleSettings::Tech::GantryClusterRecoveryEnabled;
    }
    bool EarlyEnabled() {
        return RecoveryEnabled() && Global::RoleSettings::Tech::EarlyGantryEnabled
            && TechPlan::plan == "t3rush";
    }
    void SampleIncome() {
        if (!EarlyEnabled() || EarlyComplete()) return;
        metalWindow.Push(ai.frame, aiEconomyMgr.metal.income,
            Global::RoleSettings::Tech::EarlyGantryIncomeWindowSeconds * SECOND,
            Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND);
    }
    CCircuitDef@ OpeningUnit() {
        // Preserve the current signature production choice. Do not introduce
        // the other branch's ten-unit composition or override amphibious policy.
        return ai.GetCircuitDef(UnitHelpers::GetGantrySignatureUnitForSide(Global::AISettings::Side));
    }
    bool Funded(CCircuitDef@ factory, bool includeOpeningUnit) {
        if (factory is null) return false;
        float metalCost = factory.costM, energyCost = factory.costE;
        if (includeOpeningUnit) {
            CCircuitDef@ opening = OpeningUnit();
            if (opening is null || !factory.CanBuild(opening)) return false;
            metalCost += opening.costM; energyCost += opening.costE;
        }
        const float metalIncome = AiMax(0.0f, Economy::GetMinMetalIncomeLast10s()
            - TeamEconomy::OwnMetal(TeamEconomy::USAGE));
        const float availableEnergy = HeavyRushMath::AvailableEnergy(
            Economy::GetMinEnergyIncomeLast10s(), TeamEconomy::OwnEnergy(TeamEconomy::USAGE),
            ai.GetTeamRulesParam("mmUse", 0.0f), Global::RoleSettings::Tech::GantryEnergyReserve);
        return HeavyRushMath::CanFund(metalCost, energyCost, metalIncome, availableEnergy,
            aiEconomyMgr.metal.current, aiEconomyMgr.energy.current,
            Global::RoleSettings::Tech::GantryFundingSeconds,
            Global::RoleSettings::Tech::GantryFundingShare, 0.0f);
    }
    bool Ready(CCircuitDef@ factory, CCircuitUnit@ builder) {
        if (builder is null || factory is null || !builder.circuitDef.CanBuild(factory)) return false;
        CCircuitDef@ reactor = ai.GetCircuitDef(TechChain::DefFor("afus"));
        const bool economy = reactor !is null && reactor.count > aiBuilderMgr.GetUnfinishedCount(reactor);
        const float power = builder is null ? 0.0f : builder.circuitDef.GetBuildSpeed();
        return GantryMath::CanStart(economy,
            metalWindow.Ready(ai.frame, Global::RoleSettings::Tech::EarlyGantryMaximumSampleGapSeconds * SECOND),
            metalWindow.Mean(), Global::RoleSettings::Tech::EarlyGantryMetalIncome,
            TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0,
            TechHeavyRush::Pending(), Funded(factory, true), power,
            Global::RoleSettings::Tech::GantryMinimumBuilderPower);
    }
    bool ReachableBattlefield(const AIFloat3& in position, int facing) {
        CCircuitDef@ opening = OpeningUnit();
        if (opening is null) return false;
        const AIFloat3 exit = position + Layout::Fwd(facing) * Global::RoleSettings::Tech::GantryExitProbeDistance;
        // Connected movement-area lookup, not Dijkstra per placement candidate.
        // Existing Fits/IsExitClear still validate factory footprint and exit.
        return aiTerrainMgr.CanTraverse(opening, exit, Lanes::Front());
    }
    bool SafeWorker(CCircuitUnit@ builder, const AIFloat3& in position) {
        return builder !is null && aiBattle.SurfThreat(position) <= Global::RoleSettings::Tech::GantryMaximumSurfaceThreat
            && aiTerrainMgr.CanReachAtSafe(builder, position, builder.circuitDef.GetBuildDistance());
    }
    void Waiting(const string& in reason) {
        if (ai.frame < nextLogFrame) return;
        nextLogFrame = ai.frame + Global::RoleSettings::Tech::GantryLogIntervalSeconds * SECOND;
        GenericHelpers::LogUtil("[TECH][Gantry] " + reason, 1);
    }
    bool EarlyComplete() {
        if (!EarlyEnabled() || earlyDeferred) return true;
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        return definition !is null && definition.count > aiBuilderMgr.GetUnfinishedCount(definition);
    }
    IUnitTask@ EarlyWork(CCircuitUnit@ builder) {
        if (EarlyComplete()) return null;
        if (earlyStartFrame < 0) earlyStartFrame = ai.frame;
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        if (definition is null) return null;
        // Once the cluster is committed, its own progress/recovery owns the
        // task. Funding fluctuations never abandon a real construction frame.
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry(definition.GetName());
        bool committed = false;
        int progressFrame = earlyStartFrame;
        if (cluster !is null) {
            CCircuitUnit@ factory = TechFactories::LabAt(cluster);
            committed = factory !is null || (cluster.labTask !is null && !cluster.labTask.IsDead());
            IBuilderTask@ support = cast<IBuilderTask>(cluster.gantrySupportTask);
            if (support !is null && !support.IsDead())
                committed = committed || support.target !is null || support.GetUnits().length() > 0;
            progressFrame = AiMax(progressFrame, cluster.gantryProgressFrame);
        }
        if (!committed && ai.frame - progressFrame >= Global::RoleSettings::Tech::EarlyGantryAttemptSeconds * SECOND) {
            earlyDeferred = true;
            Waiting("early admission expired; continuing normal air/economy sequence");
            return null;
        }
        if (cluster !is null) return Work(TechFactories::ReadyCluster(cluster), definition, builder);
        if (!Ready(definition, builder)) { Waiting("waiting for AFUS, income, funding or prior commitments"); return null; }
        @cluster = TechFactories::ReadyCluster(TechFactories::OpenCluster(definition, TechFactories::MayPlan(definition), true));
        if (cluster is null) { Waiting("waiting for a safe reachable cluster/cap/cooldown"); return null; }
        return Work(cluster, definition, builder);
    }

    IUnitTask@ Work(TechFactories::Cluster@ cluster, CCircuitDef@ definition, CCircuitUnit@ builder) {
        if (cluster is null || definition is null || builder is null) return null;
        CCircuitUnit@ factory = TechFactories::LabAt(cluster);
        // Adopt a late frame before inspecting timeouts or pending task state.
        if (factory !is null) {
            if (factory.GetBuildProgress() < 1.0f && SafeWorker(builder, cluster.pos))
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, factory,
                    Global::RoleSettings::Tech::GantryAssistSeconds * SECOND));
            return null;
        }
        if (!SafeWorker(builder, cluster.pos)) return null;
        if (cluster.gantryProgressFrame < 0) cluster.gantryProgressFrame = ai.frame;
        const int completed = TechFactories::FinishedTurrets(cluster);
        if (completed > cluster.gantryCompletedTurrets) {
            cluster.gantryCompletedTurrets = completed; cluster.gantryProgressFrame = ai.frame;
        }
        CCircuitDef@ turret = TechFactories::Nano();
        if (turret is null) return null;
        const int required = TechFactories::TurretsBeforeLab(cluster);
        // One explicit bootstrap assignment at a time. Native owns command
        // retry/reassignment and its pinned reservation; travel/frame ownership
        // suppresses fallback without falsifying the progress clock. GetUnits
        // snapshots only assigned task workers: O(task workers + reserved
        // turret slots), not an army scan or a constant-time whole decision.
        IBuilderTask@ support = cast<IBuilderTask>(cluster.gantrySupportTask);
        bool supportFrame = false, supportWorker = false;
        if (support !is null && !support.IsDead()) {
            supportFrame = support.target !is null;
            supportWorker = support.GetUnits().length() > 0;
            if (builder.circuitDef.CanBuild(turret) && !supportWorker
                && SafeWorker(builder, support.GetBuildPos())) return support;
        } else { @cluster.gantrySupportTask = null; }
        // Only this cluster's recorded slots count: a neighbour's progressing
        // turret must not hold our zero-turret recovery indefinitely.
        CCircuitUnit@ frame = null;
        for (uint index = 0; index < cluster.turretPos.length(); ++index) {
            CCircuitUnit@ candidate = TechFactories::TurretAt(cluster.turretPos[index]);
            if (candidate !is null && candidate.GetBuildProgress() < 1.0f) { @frame = candidate; break; }
        }
        if (frame !is null) supportFrame = true;
        bool fallback = false;
        if (completed < required) {
            if (frame !is null && SafeWorker(builder, frame.GetPos(ai.frame)))
                return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame,
                    Global::RoleSettings::Tech::GantryAssistSeconds * SECOND));
            if (builder.circuitDef.CanBuild(turret) && cluster.gantrySupportTask is null) {
                // An existing but unsafe/unreachable frame belongs to recovery;
                // neither override SafeWorker nor create a duplicate turret.
                if (frame !is null) return null;
                const int slot = aiTerrainMgr.NextSlotAny(cluster.nanoGroup, builder.GetPos(ai.frame));
                if (slot >= 0 && SafeWorker(builder, aiTerrainMgr.GetReservationPos(slot))) {
                    IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::NANO, turret, slot, "gantry support turret");
                    if (task !is null) {
                        const AIFloat3 position = aiTerrainMgr.GetReservationPos(slot);
                        bool known = false;
                        for (uint index = 0; index < cluster.turretPos.length(); ++index)
                            if (MapHelpers::SqDist(position, cluster.turretPos[index]) < SQUARE_SIZE * SQUARE_SIZE) known = true;
                        if (!known) cluster.turretPos.insertLast(position);
                        cluster.turretFrame = ai.frame; cluster.started = true;
                        aiTerrainMgr.SetLayoutInt("tech.cluster." + cluster.labRes + ".started", 1);
                        @cluster.gantrySupportTask = task;
                        return task;
                    }
                }
            }
            fallback = GantryMath::CanFallback(ai.frame, cluster.gantryProgressFrame,
                Global::RoleSettings::Tech::GantryTurretWaitSeconds * SECOND, supportFrame, supportWorker,
                Funded(definition, false), builder.circuitDef.CanBuild(definition)
                    && builder.circuitDef.GetBuildSpeed() >= Global::RoleSettings::Tech::GantryMinimumBuilderPower);
            if (!fallback) return null;
        }
        if (!builder.circuitDef.CanBuild(definition)) return null;
        if (cluster.labTask !is null && !cluster.labTask.IsDead()) {
            if (cluster.labTask.GetUnits().length() < uint(AiMax(1, Global::RoleSettings::Tech::GantryMaximumTaskBuilders))) return cluster.labTask;
            return null;
        }
        @cluster.labTask = null;
        if (cluster.built) {
            cluster.labRes = aiTerrainMgr.ReserveBuilding(definition, cluster.pos, cluster.facing);
            if (cluster.labRes < 0) return null;
            cluster.built = false; cluster.labSeen = false;
        }
        if (!definition.IsAvailable(ai.frame)) return null;
        // The early phase rechecks funding at the actual order; support work
        // can have consumed the initial budget since cluster activation.
        if (cluster.earlyGantry && (!Funded(definition, true)
            || !ReachableBattlefield(cluster.pos, cluster.facing)
            || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending())) return null;
        IUnitTask@ task = TechFactories::OrderPinned(builder, Task::BuildType::FACTORY, definition,
            cluster.labRes, fallback ? "gantry (funded missing-turret-builder fallback)" : "gantry (supported cluster)");
        if (task !is null) {
            @cluster.labTask = task; cluster.orderedFrame = ai.frame;
            cluster.gantryFallback = fallback;
        }
        return task;
    }
    // A budgeted gantry bootstrap is an explicit exception to discretionary
    // forward-builder recall. Match the live task/target, never a unit type or
    // an entire region. Used by both periodic and callback recall paths.
    bool OwnsWork(CCircuitUnit@ builder) {
        if (!RecoveryEnabled() || builder is null || builder.task is null) return false;
        IBuilderTask@ task = cast<IBuilderTask>(builder.task);
        if (task is null || task.IsDead()) return false;
        for (uint index = 0; index < TechFactories::clusters.length(); ++index) {
            TechFactories::Cluster@ cluster = TechFactories::clusters[index];
            if (cluster.ahead || cluster.tier < 3 || cluster.labRes < 0) continue;
            if (task is cluster.gantrySupportTask || task is cluster.labTask) return true;
            if (task.target !is null && task.target.GetBuildProgress() < 1.0f) {
                if (task.target.id == cluster.labId) return true;
                for (uint slot = 0; slot < cluster.turretPos.length(); ++slot)
                    if (MapHelpers::SqDist(task.target.GetPos(ai.frame), cluster.turretPos[slot])
                        < SQUARE_SIZE * SQUARE_SIZE) return true;
            }
        }
        return false;
    }
    // Event-time diagnostic provenance, O(clusters), no per-frame census.
    // The early phase deliberately permits this factory's existing production
    // before the ordinary +500 gate. Gifts and unrelated/rebuilt producers
    // cannot inherit its admission just by sharing a unit definition.
    bool IsAdmittedProduction(CCircuitUnit@ product) {
        if (!EarlyEnabled() || product is null || product.GetProducerId() < 0) return false;
        for (uint index = 0; index < TechFactories::clusters.length(); ++index) {
            TechFactories::Cluster@ cluster = TechFactories::clusters[index];
            if (GantryMath::AdmittedProduct(true, cluster.earlyGantry && cluster.tier >= 3,
                product.GetProducerId(), cluster.labId, product.GetProductionFrame(), cluster.orderedFrame)) return true;
        }
        return false;
    }
    IUnitTask@ SupportWork(CCircuitUnit@ builder) {
        if (!RecoveryEnabled() || TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0 || TechHeavyRush::Pending()) return null;
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry();
        if (cluster is null) return null;
        return Work(cluster, ai.GetCircuitDef(cluster.defName), builder);
    }
}
