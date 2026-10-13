function widget:GetInfo() return {name="Ranged combat arena",layer=125,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/ranged_arena.lua")
local tracked,queue,pending,seen,orders,lastReload={}, {}, nil, {}, {}, {}
local priorDamage,damageHook,priorCommand,commandHook
local camera,photos=nil,{}
local commandTypes,unitCommands={},{}
local factorySamples,factoryIds={},{}
local function log(s) Spring.Echo("[RangedArena] frame="..Spring.GetGameFrame().." "..s) end
-- Opt-in census fixtures (D-294/D-295/D-296). Observation only, no orders.
-- caseUnits: cfg.units (list) or cfg.unit. Tallies are logged as one summary
-- line every 10 s so checks can match thresholds with a regex.
local caseUnits={}
local shotTally={scouts=0,other=0}
local killTally={econ=0,armed=0,losses=0,static_losses=0}
local econTargets={}
local function isScout(def)
    local c=UnitDefs[def] and UnitDefs[def].modCategories
    return c and c["groundscout"] and true or false
end
local occupied={}
local function site(g,x,z)
    local def=UnitDefNames[g.unit]
    if not def then log("ERROR missing_unit="..g.unit);return end
    -- BAR factories expose canMove for their command queue, but are immobile.
    -- A movement test always rejects them; validate their building footprint.
    local mobile=UnitDefs[def.id].canMove and not UnitDefs[def.id].isFactory and (UnitDefs[def.id].speed or 0)>0
    local reference=Spring.GetGroundHeight(g.position[1],g.position[2])
    -- Supplied units must not begin on isolated mountain tops. Validate the
    -- loaded movement footprint and same-height approach before spawning;
    -- record adjusted coordinates so baseline/candidate inputs are auditable.
    for ring=0,8 do
        for direction=0,(ring==0 and 0 or 15) do
            local angle=direction*math.pi/8
            local px,pz=x+math.cos(angle)*ring*64,z+math.sin(angle)*ring*64
            local y=Spring.GetGroundHeight(px,pz)
            local free=y>=0 and math.abs(y-reference)<=64
            if free and mobile and not UnitDefs[def.id].canFly then free=Spring.TestMoveOrder(def.id,px,y,pz,0,0,0,true,true,false) end
            if free and not mobile then free=Spring.TestBuildOrder(def.id,px,y,pz,0)>0 end
            for _,p in ipairs(occupied) do if (px-p[1])^2+(pz-p[2])^2<(cfg.min_spawn_spacing or 96)^2 then free=false;break end end
            if free then occupied[#occupied+1]={px,pz};return px,y+(UnitDefs[def.id].canFly and 160 or 0),pz end
        end
    end
    log("ERROR unbuildable_spawn="..g.unit.." x="..x.." z="..z)
end
local function child(id)
    if not id or tracked[id] then return end
    local host=Spring.GetUnitRulesParam(id,"carrier_host_unit_id")
    if host and tracked[host] then
        local def,team=Spring.GetUnitDefID(id),Spring.GetUnitTeam(id)
        if def and team then tracked[id]={def=def,team=team,child=true};log("child id="..id.." team="..team.." unit="..UnitDefs[def].name.." host="..host) end
    end
end
local function damage(id,def,team,amount,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
    child(id);child(attacker)
    -- Opt-in supplied siege acceptance: observing fire is insufficient if the
    -- artillery walked into a scouted turret first. No orders or extra polling.
    if cfg.no_static_damage and team==0 and UnitDefs[def].name==cfg.unit
        and attackerTeam==1 and UnitDefs[attackerDef or -1]
        and (UnitDefs[attackerDef].speed or 0)==0 and amount>0 then
        log("ERROR artillery_hit_by_static id="..id.." attacker="..UnitDefs[attackerDef].name)
    end
    if cfg.natural and tracked[attacker] and team~=0 and not tracked[id] then
        local x,_,z=Spring.GetUnitPosition(id)
        tracked[id]={team=team,def=def}
        log("spawn id="..id.." team="..team.." unit="..UnitDefs[def].name.." x="..math.floor(x or 0).." z="..math.floor(z or 0))
    end
    if tracked[id] or tracked[attacker] then
        log("damage id="..id.." team="..team.." amount="..math.floor(amount).." attacker="..tostring(attacker).." attackerTeam="..tostring(attackerTeam).." weapon="..tostring(weapon).." weaponName="..tostring(WeaponDefs[weapon or -1] and WeaponDefs[weapon].name or "unknown"))
    end
end
local function command(id,def,team,cmd,params,options,tag,player,fromSynced,fromLua)
    if cfg.factory_throughput and team==0 and UnitDefs[def].isFactory and cmd<0 then
        log("factory_order id="..id.." product="..(-cmd).." source="..tostring(fromLua))
    end
    if cfg.drone_ownership and team==0 and UnitDefs[def].customParams
        and tostring(UnitDefs[def].customParams.drone)=="1" then
        -- Correctness fixture only: distinguish attached gadget ownership from
        -- independent/released AI control at the actual command instant.
        local host=Spring.GetUnitRulesParam(id,"carrier_host_unit_id") or -1
        log("drone_order id="..id.." host="..host.." command="..cmd.." source="
            ..(fromLua==true and "lua" or fromLua==false and "nonlua" or "unknown"))
    end
    if not tracked[id] then return end
    local count=orders[team] or {all=0,lua=0,nonlua=0};orders[team]=count
    count.all=count.all+1
    if fromLua==true then count.lua=count.lua+1 elseif fromLua==false then count.nonlua=count.nonlua+1 end
    if team==0 and fromLua==false then
        commandTypes[cmd]=(commandTypes[cmd] or 0)+1
        local key=UnitDefs[def].name..":"..cmd;unitCommands[key]=(unitCommands[key] or 0)+1
    end
    if team==0 and cmd==34923 and cfg.trace_orders~=false then
        local x,_,z=Spring.GetUnitPosition(id)
        log("priority id="..id.." unit="..UnitDefs[def].name.." target="..tostring(params[1]).." x="..math.floor(x).." z="..math.floor(z))
    end
end
function widget:Initialize()
    priorDamage=widgetHandler.UnitDamaged
    damageHook=function(self,...) damage(...);if priorDamage then return priorDamage(self,...) end end
    widgetHandler.UnitDamaged=damageHook;widgetHandler:UpdateCallIn("UnitDamaged")
    priorCommand=widgetHandler.UnitCommand
    commandHook=function(self,...) command(...);if priorCommand then return priorCommand(self,...) end end
    widgetHandler.UnitCommand=commandHook;widgetHandler:UpdateCallIn("UnitCommand")
    for _,name in ipairs(cfg.units or {cfg.unit}) do caseUnits[name]=true end
    for _,name in ipairs(cfg.econ_targets or {}) do econTargets[name]=true end
    log("loaded case="..cfg.name.." variant="..cfg.variant)
end
function widget:UnitCreated(id,def,team,builder)
    if cfg.factory_throughput and team==0 and UnitDefs[def].isFactory then factoryIds[id]=true end
    if cfg.natural and team==0 and UnitDefs[def].name==cfg.unit then
        local x,_,z=Spring.GetUnitPosition(id)
        tracked[id]={team=team,def=def}
        log("spawn id="..id.." team="..team.." unit="..UnitDefs[def].name.." x="..math.floor(x).." z="..math.floor(z))
        return
    end
    if pending and team==pending.g.team and UnitDefs[def].name==pending.g.unit then
        tracked[id]={team=team,def=def};log("spawn id="..id.." team="..team.." unit="..UnitDefs[def].name.." x="..math.floor(pending.x).." z="..math.floor(pending.z));pending=nil
    elseif builder and (tracked[builder] or (cfg.builders and team==0)) then
        tracked[id]={team=team,def=def,child=true,parent=builder};log("child id="..id.." parent="..builder.." unit="..UnitDefs[def].name)
    end
end
function widget:UnitDestroyed(id,def,team,attacker,attackerDef,attackerTeam)
    factoryIds[id]=nil
    if cfg.kill_census and tracked[id] then
        local by=attackerDef and UnitDefs[attackerDef] and UnitDefs[attackerDef].name or "none"
        log("killed def="..UnitDefs[def].name.." team="..team.." by="..by.." byTeam="..tostring(attackerTeam))
        if team==1 and caseUnits[by] then
            if econTargets[UnitDefs[def].name] then killTally.econ=killTally.econ+1
            elseif UnitDefs[def].weapons and #UnitDefs[def].weapons>0 then killTally.armed=killTally.armed+1 end
        elseif team==0 and caseUnits[UnitDefs[def].name] then
            killTally.losses=killTally.losses+1
            if attackerDef and UnitDefs[attackerDef] and (UnitDefs[attackerDef].speed or 0)==0 then killTally.static_losses=killTally.static_losses+1 end
        end
    end
    if tracked[id] then log("death id="..id.." team="..team.." unit="..UnitDefs[def].name.." cost="..UnitDefs[def].metalCost);tracked[id]=nil end
end
function widget:UnitFinished(id,def,team)
    if (cfg.production or cfg.natural) and tracked[id] then
        log("finished id="..id.." team="..team.." unit="..UnitDefs[def].name.." cost="..UnitDefs[def].metalCost)
    end
end
function widget:GameFrame(f)
    if f==150 then
        if not cfg.natural then Spring.SendCommands("cheat 1") end
        log("ready")
    end
    if f<300 then return end
    if cfg.rush_loss_steps then
        if not cfg.original_front and f>=cfg.rush_capture_seconds*30 then
            cfg.original_front={}
            for id,u in pairs(tracked) do
                if u.team==0 and UnitDefs[u.def].name==(cfg.rush_front_unit or "corthud") then cfg.original_front[#cfg.original_front+1]=id end
            end
            table.sort(cfg.original_front)
            log("rush_original count="..#cfg.original_front)
        end
        for _,step in ipairs(cfg.rush_loss_steps) do
            if not step.done and f>=step.seconds*30 then
                step.done=true
                local live={}
                for _,id in ipairs(cfg.original_front or {}) do if tracked[id] then live[#live+1]=id end end
                local remove={}
                for i=step.remaining+1,#live do remove[#remove+1]=live[i] end
                Spring.SelectUnitArray(remove,false); Spring.SendCommands("destroy"); Spring.SelectUnitArray({},false)
                log("rush_loss_step remaining="..step.remaining.." removed="..#remove)
            end
        end
    end
    -- Correctness observer only, O(supplied factories) per frame. Distinguish
    -- an empty engine build queue from physical launch/collision/energy time.
    -- Never issue orders or infer network/FPS gains from these counters.
    if cfg.factory_throughput and f>=90*30 then
        local metal=Spring.GetTeamResources(0,"metal") or 0
        local energy=Spring.GetTeamResources(0,"energy") or 0
        for id in pairs(factoryIds) do
                local s=factorySamples[id] or {samples=0,empty=0,building=0,fundedEmpty=0}
                factorySamples[id]=s;s.samples=s.samples+1
                local commands=Spring.GetFactoryCommands(id,-1) or {}
                local builds=0;for _,c in ipairs(commands) do if c.id<0 then builds=builds+1 end end
                if builds==0 then s.empty=s.empty+1;if metal>0 and energy>200 then s.fundedEmpty=s.fundedEmpty+1 end end
                if Spring.GetUnitIsBuilding(id) then s.building=s.building+1 end
                if f%900==0 then
                    log("throughput id="..id.." samples="..s.samples.." empty="..s.empty.." fundedEmpty="..s.fundedEmpty.." building="..s.building.." metal="..math.floor(metal).." energy="..math.floor(energy))
                end
        end
    end
    -- Optional lifecycle fixture: remove an entire screen after pairing. This
    -- is explicit supplied-force intervention, never enabled in natural games.
    if cfg.remove_units_after_seconds and not cfg.fixture_units_removed and f>=cfg.remove_units_after_seconds*30 then
        cfg.fixture_units_removed=true
        local ids={}
        for id,u in pairs(tracked) do
            if u.team==0 and UnitDefs[u.def].name==cfg.remove_unit_name then ids[#ids+1]=id end
        end
        Spring.SelectUnitArray(ids,false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        log("fixture_units_removed unit="..cfg.remove_unit_name.." count="..#ids)
    end
    if cfg.drop_energy_after_seconds and not cfg.energy_dropped and f>=cfg.drop_energy_after_seconds*30 then
        cfg.energy_dropped=true
        local ids={}
        for id,u in pairs(tracked) do
            if u.team==0 and (UnitDefs[u.def].name=="armafus" or UnitDefs[u.def].name=="armmmkr") then ids[#ids+1]=id end
        end
        Spring.SelectUnitArray(ids,false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        log("fixture_energy_removed count="..#ids)
    end
    for _,g in ipairs(cfg.groups) do
        if not g.queued and f>=(g.after_seconds or 10)*30 then
            g.queued=true
            for i=1,g.count do
                local columns=g.columns or 4;local spacing=g.spacing or 120
                local x=g.position[1]+((i-1)%columns)*spacing
                local z=g.position[2]+math.floor((i-1)/columns)*spacing
                local px,y,pz=site(g,x,z)
                if px then queue[#queue+1]={g=g,x=px,y=y,z=pz} end
            end
        end
    end
    if f%3==0 and not pending and #queue>0 then
        pending=table.remove(queue,1);pending.sent=f
        Spring.SendCommands(string.format("give 1 %s %d @%d,%d,%d",pending.g.unit,pending.g.team,pending.x,pending.y,pending.z))
    end
    if pending and f-pending.sent>300 then log("ERROR spawn_timeout="..pending.g.unit);pending=nil end
    if f%30==0 then
        for id,u in pairs(tracked) do
            local d=UnitDefs[u.def]
            if u.team==1 and not seen[id] then
                local visibility=Spring.GetUnitLosState(id,0,false)
                if visibility and (visibility.los or visibility.radar) then seen[id]=f;log("detected id="..id.." unit="..d.name) end
            end
            if cfg.trace_spam and u.team==0 and d.isFactory then
                local states=Spring.GetUnitStates(id) or {}
                local commands=Spring.GetFactoryCommands(id,-1) or {}
                local builds=0
                for _,c in ipairs(commands) do if c.id<0 then builds=builds+1 end end
                log("factory id="..id.." unit="..d.name.." repeat="..tostring(states["repeat"] or false).." builds="..builds.." building="..tostring(Spring.GetUnitIsBuilding(id) or -1))
            end
            if u.team==0 and d.canMove and (not u.child or cfg.observe_children) then
                for index,w in ipairs(d.weapons or {}) do
                    local reload=Spring.GetUnitWeaponState(id,index,"reloadFrame")
                    local key=id..":"..index
                    if reload and lastReload[key] and reload>lastReload[key] and reload>f then
                        local kind,_,target=Spring.GetUnitWeaponTarget(id,index)
                        local distance=-1
                        if kind==1 and target then
                            local x,_,z=Spring.GetUnitPosition(id);local tx,_,tz=Spring.GetUnitPosition(target)
                            if tx then distance=math.floor(math.sqrt((x-tx)^2+(z-tz)^2)) end
                        end
                        log("shot id="..id.." unit="..d.name.." weapon="..index.." target="..tostring(kind==1 and target or -1).." distance="..distance.." intent="..tostring(Spring.GetUnitRulesParam(id,"unitTargetID") or -1))
                        if cfg.shot_census and caseUnits[d.name] and kind==1 and target then
                            local targetDef=Spring.GetUnitDefID(target)
                            if targetDef then
                                local scout=isScout(targetDef)
                                if scout then shotTally.scouts=shotTally.scouts+1 else shotTally.other=shotTally.other+1 end
                                log("shot_census unit="..id.." shooter="..d.name.." target="..UnitDefs[targetDef].name.." category="..(scout and "GROUNDSCOUT" or "other"))
                            end
                        end
                    end
                    lastReload[key]=reload
                end
                if f%(cfg.formation_observation and 30 or 150)==0 then
                    local x,_,z=Spring.GetUnitPosition(id)
                    local health=Spring.GetUnitHealth(id)
                    local host=Spring.GetUnitRulesParam(id,"carrier_host_unit_id") or -1
                    log("unit id="..id.." unit="..d.name.." x="..math.floor(x).." z="..math.floor(z).." hp="..math.floor(health).." cloak="..tostring(Spring.GetUnitIsCloaked(id) or false).." target="..tostring(Spring.GetUnitRulesParam(id,"unitTargetID") or -1).." command="..tostring(Spring.GetUnitCurrentCommand(id) or -1).." host="..host)
                    if cfg.trace_spam and u.parent then
                        local commands=Spring.GetUnitCommands(id,-1) or {}
                        local last=commands[#commands]
                        log("lane id="..id.." parent="..u.parent.." count="..#commands.." endcmd="..tostring(last and last.id or -1).." endx="..tostring(last and last.params[1] or -1).." endz="..tostring(last and last.params[3] or -1))
                    end
                end
            end
        end
    end
    if f%300==0 then
        if cfg.trace_spam then
            local m,ms,mp,mi,me=Spring.GetTeamResources(0,"metal")
            local e,es,ep,ei,ee=Spring.GetTeamResources(0,"energy")
            log(string.format("economy metal=%.1f storage=%.1f income=%.1f expense=%.1f energy=%.1f eincome=%.1f eexpense=%.1f",m,ms,mi,me,e,ei,ee))
        end
        for team,c in pairs(orders) do log("orders team="..team.." total="..c.all.." nonlua="..c.nonlua.." lua="..c.lua) end
        if cfg.shot_census then log("shots scouts="..shotTally.scouts.." other="..shotTally.other) end
        if cfg.kill_census then log("kill_census econ="..killTally.econ.." armed="..killTally.armed.." losses="..killTally.losses.." static_losses="..killTally.static_losses) end
        if cfg.command_breakdown then
            for cmd,count in pairs(commandTypes) do log("command_type command="..cmd.." count="..count) end
            for key,count in pairs(unitCommands) do log("unit_command key="..key.." count="..count) end
        end
        log("render fps="..Spring.GetFPS())
    end
    -- D-295/D-296 progress observers, O(tracked) every 2/5 s.
    if cfg.centroid_distance and f%60==0 then
        local cx,cz,n=0,0,0
        for id,u in pairs(tracked) do
            if u.team==1 and not u.child then
                local x,_,z=Spring.GetUnitPosition(id)
                if x and (UnitDefs[u.def].speed or 0)>0 then cx,cz,n=cx+x,cz+z,n+1 end
            end
        end
        if n>0 then
            cx,cz=cx/n,cz/n
            local sum,m=0,0
            for id,u in pairs(tracked) do
                if u.team==0 and caseUnits[UnitDefs[u.def].name] then
                    local x,_,z=Spring.GetUnitPosition(id)
                    if x then sum,m=sum+math.sqrt((x-cx)^2+(z-cz)^2),m+1 end
                end
            end
            if m>0 then log("centroid_distance mean="..math.floor(sum/m).." units="..m.." enemies="..n) end
        end
    end
    if cfg.depth_units and f%150==0 then
        local best,alive=-1,0
        for id,u in pairs(tracked) do
            if u.team==0 and caseUnits[UnitDefs[u.def].name] then
                local _,_,z=Spring.GetUnitPosition(id)
                if z then alive=alive+1;best=math.max(best,math.floor(z)) end
            end
        end
        log("scout_depth max_z="..best.." alive="..alive)
    end
    if not cfg.headless then
        for _,second in ipairs(cfg.photos or {45,120,210}) do
            if f>=second*30 and not photos[second] and not camera then
                photos[second]=true
                local p=cfg.camera or {4000,5000,2600}
                Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
                local state={mode=1,px=p[1],py=math.max(0,Spring.GetGroundHeight(p[1],p[2])),pz=p[2],height=p[3],angle=cfg.camera_angle or .9}
                Spring.SetCameraState(state,0)
                local ids={};for id,u in pairs(tracked) do if u.team==0 and caseUnits[UnitDefs[u.def].name] then ids[#ids+1]=id end end
                Spring.SelectUnitArray(ids,false)
                camera={frame=f,draws=0,time=Spring.GetTimer(),state=state}
            end
        end
    end
end
function widget:DrawScreen()
    if not camera then return end
    Spring.SetCameraState(camera.state,0)
    camera.draws=camera.draws+1
    if camera.draws>6 and Spring.DiffTimers(Spring.GetTimer(),camera.time)>.5 then
        Spring.SendCommands("screenshot png")
        log("screenshot")
        Spring.SendCommands({"setmaxspeed "..cfg.speed,"setminspeed "..cfg.speed,"setmaxspeed "..cfg.speed})
        camera=nil
    end
end
function widget:Shutdown()
    if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged") end
    if widgetHandler.UnitCommand==commandHook then widgetHandler.UnitCommand=priorCommand;widgetHandler:UpdateCallIn("UnitCommand") end
end
