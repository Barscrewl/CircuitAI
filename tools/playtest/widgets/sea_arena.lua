function widget:GetInfo() return {name="SEA combat arena",layer=125,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/sea_arena.lua")
local queue,pending,tracked,seen={},nil,{},{}
local carrierOwners={}
local expectedRemoved={}
local counts,last={},{}
local camera,photos=nil,{}
local priorDamage,damageHook,priorCommand,commandHook
local function log(s) Spring.Echo("[SeaArena] frame="..Spring.GetGameFrame().." "..s) end
local function child(id)
    if not id or tracked[id] then return end
    local host=Spring.GetUnitRulesParam(id,"carrier_host_unit_id")
    if host and host>=0 and tracked[host] then
        local def,team=Spring.GetUnitDefID(id),Spring.GetUnitTeam(id)
        if def and team then
            tracked[id]={team=team,def=def,child=true}
            log("child id="..id.." team="..team.." unit="..UnitDefs[def].name.." host="..host)
        end
    end
end
local function pos(g,i)
    local columns=g.columns or 4
    local spacing=g.spacing or 120
    local x=g.position[1]+((i-1)%columns)*spacing
    local z=g.position[2]+math.floor((i-1)/columns)*spacing
    local d=UnitDefNames[g.unit]
    if not d then log("ERROR missing_unit="..g.unit);return end
    local y=Spring.GetGroundHeight(x,z)
    if UnitDefs[d.id].canFly then return x,math.max(0,y)+160,z end
    if g.land then
        if y<0 then log("ERROR wet_land_site="..g.unit.." x="..x.." z="..z);return end
        return x,y,z
    end
    if y>=-20 then log("ERROR dry_site="..g.unit.." x="..x.." z="..z);return end
    return x,y,z
end
local function damage(id,def,team,amount,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
    child(id);child(attacker)
    if not attacker or team==attackerTeam or not tracked[id] or not tracked[attacker] then return end
    if amount>0 and not paralyzer then
        log("damage victim="..id.." attacker="..attacker.." team="..attackerTeam.." amount="..string.format("%.1f",amount)
            .." attackerUnit="..UnitDefs[tracked[attacker].def].name.." victimUnit="..UnitDefs[tracked[id].def].name
            .." produced="..tostring(tracked[attacker].produced==true))
        tracked[id].attackerTeam=attackerTeam
    end
end
local function command(id,def,team,cmd,params,options,tag,player,fromSynced,fromLua)
    child(id)
    local d=UnitDefs[def];if not d then return end
    local c=counts[team] or {all=0,repeatCount=0,commands={},defs={},sources={}};counts[team]=c;c.all=c.all+1
    local source=fromLua==true and "lua" or fromLua==false and "nonlua" or "unknown"
    c.sources[source]=(c.sources[source] or 0)+1
    local key=d.name.."_"..source;c.sources[key]=(c.sources[key] or 0)+1
    c.commands[cmd]=(c.commands[cmd] or 0)+1;c.defs[d.name]=(c.defs[d.name] or 0)+1
    local sig=tostring(cmd);for _,p in ipairs(params or {}) do sig=sig..":"..tostring(p) end
    if last[id]==sig then c.repeatCount=c.repeatCount+1 end;last[id]=sig
    if cfg.retreat_observer and cmd==CMD.MOVE and params and #params>=3 and tracked[id] then
        log("move id="..id.." x="..params[1].." z="..params[3])
    end
    if cmd==CMD.ATTACK and params and #params==1 and tracked[id] then
        log("attack id="..id.." target="..params[1].." def="..d.name)
        local target=tracked[params[1]]
        if target then
            local categories=UnitDefs[target.def].springCategories or {}
            local compatible=false
            for _,w in ipairs(d.weapons or {}) do
                if not w.onlyTargets then compatible=true;break end
                for category in pairs(w.onlyTargets) do if categories[category] then compatible=true;break end end
                if compatible then break end
            end
            if not compatible then log("category_mismatch id="..id.." unit="..d.name.." target="..UnitDefs[target.def].name) end
        end
    end
end
function widget:Initialize()
    priorDamage=widgetHandler.UnitDamaged
    damageHook=function(self,...) damage(...);if priorDamage then return priorDamage(self,...) end end
    widgetHandler.UnitDamaged=damageHook;widgetHandler:UpdateCallIn("UnitDamaged")
    priorCommand=widgetHandler.UnitCommand
    commandHook=function(self,...) command(...);if priorCommand then return priorCommand(self,...) end end
    widgetHandler.UnitCommand=commandHook;widgetHandler:UpdateCallIn("UnitCommand")
    log("loaded case="..cfg.name.." control="..tostring(cfg.control))
end
function widget:UnitCreated(id,def,team,builder)
    if pending and team==pending.g.team and UnitDefs[def].name==pending.g.unit then
        tracked[id]={team=team,def=def};log("spawn id="..id.." team="..team.." unit="..UnitDefs[def].name);pending=nil
    elseif builder and tracked[builder] then
        tracked[id]={team=team,def=def,produced=true};log("produced id="..id.." team="..team.." unit="..UnitDefs[def].name)
    end
end
function widget:UnitDestroyed(id,def,team)
    if tracked[id] then log("death id="..id.." team="..team.." cost="..UnitDefs[def].metalCost.." attackerTeam="..tostring(tracked[id].attackerTeam).." unit="..UnitDefs[def].name);tracked[id]=nil end
    last[id]=nil
end
function widget:UnitFinished(id,def,team)
    if tracked[id] then log("finished id="..id.." team="..team.." unit="..UnitDefs[def].name) end
end
function widget:GameFrame(f)
    if f==150 then Spring.SendCommands("cheat 1");log("ready") end
    if f<300 then return end
    for _,g in ipairs(cfg.groups) do
        if not g.queued and f>=(g.after_seconds or 10)*30 then
            g.queued=true
            for i=1,g.count do local x,y,z=pos(g,i);if x then queue[#queue+1]={g=g,x=x,y=y,z=z} end end
        end
    end
    if f%3==0 and not pending and #queue>0 then
        pending=table.remove(queue,1);pending.sent=f
        Spring.SendCommands(string.format("give 1 %s %d @%d,%d,%d",pending.g.unit,pending.g.team,pending.x,pending.y,pending.z))
    end
    if pending and f-pending.sent>300 then log("ERROR spawn_timeout="..pending.g.unit);pending=nil end
    -- Optional investigation fixture: remove named supplied assets at an exact
    -- frame (e.g. forward radar loss). This never commands friendly combat
    -- ships. Existing cases omit the list and retain their original behavior.
    for _,event in ipairs(cfg.remove_units or {}) do
        if not event.done and f>=event.second*30 then
            event.done=true
            local ids={}
            for id,u in pairs(tracked) do
                if u.team==event.team and UnitDefs[u.def].name==event.unit then ids[#ids+1]=id end
            end
            table.sort(ids)
            Spring.SelectUnitArray(ids,false)
            Spring.SendCommands("destroy")
            Spring.SelectUnitArray({},false)
            log("fixture_removed team="..event.team.." unit="..event.unit.." count="..#ids)
        end
    end
    if cfg.objective_observer and f%150==0 then
        -- Spectator truth is measurement only; none of it is sent to the AI.
        -- Record lost vision as well as initial detection so a surviving yard
        -- cannot be mistaken for a destroyed target when its contact vanishes.
        for id,u in pairs(tracked) do
            if u.team==1 and UnitDefs[u.def].isImmobile then
                local state=Spring.GetUnitLosState(id,0,false) or {}
                local health,_,_,_,progress=Spring.GetUnitHealth(id)
                if health then
                    log("objective id="..id.." unit="..UnitDefs[u.def].name
                        .." los="..tostring(state.los==true).." radar="..tostring(state.radar==true)
                        .." health="..math.floor(health).." progress="..tostring(progress))
                end
            end
        end
    end
    if f%30==0 then
        for id,u in pairs(tracked) do
            local host=Spring.GetUnitRulesParam(id,"carrier_host_unit_id") or -1
            if host>=0 or carrierOwners[id] then
                if carrierOwners[id]~=host then log("carrier_owner id="..id.." host="..host);carrierOwners[id]=host end
            end
        end
        for id,u in pairs(tracked) do if u.team==1 and not seen[id] then
            local v=Spring.GetUnitLosState(id,0,false)
            if v and (v.los or v.radar) then seen[id]=f;log("detected id="..id.." unit="..UnitDefs[u.def].name) end
        end end
    end
    if cfg.patrol_observer and f%150==0 then
        -- Observe physical positions and engine queues, not AI decision logs.
        local positions={}
        for id,u in pairs(tracked) do
            if u.team==0 and UnitDefs[u.def].canMove and not UnitDefs[u.def].canFly then
                local x,_,z=Spring.GetUnitPosition(id)
                if x then
                    positions[#positions+1]={id=id,x=x,z=z}
                    local patrol=false
                    for _,cmd in ipairs(Spring.GetUnitCommands(id,12) or {}) do if cmd.id==CMD.PATROL then patrol=true end end
                    local health,maximum=Spring.GetUnitHealth(id)
                    if cfg.protection_observer then
                        local stockpile,queued=Spring.GetUnitStockpile(id)
                        if stockpile then log("protection id="..id.." unit="..UnitDefs[u.def].name.." stockpile="..stockpile.." queued="..tostring(queued)) end
                    end
                    log("boat id="..id.." unit="..UnitDefs[u.def].name.." x="..math.floor(x).." z="..math.floor(z)
                        .." health="..math.floor(health or 0).." maxhealth="..math.floor(maximum or 0).." patrol="..tostring(patrol)
                        .." target="..tostring(Spring.GetUnitRulesParam(id,"unitTargetID") or -1)
                        .." queue="..tostring(Spring.GetUnitCommandCount(id) or 0))
                end
            end
        end
        local nearest=1000000
        for i=1,#positions do for j=1,i-1 do
            local a,b=positions[i],positions[j]
            nearest=math.min(nearest,math.sqrt((a.x-b.x)^2+(a.z-b.z)^2))
        end end
        log("separation n="..#positions.." min="..math.floor(nearest))
        for _,second in ipairs(cfg.follow_shots or {}) do
            if f>=second*30 and not photos[second] and not camera and #positions>0 then
                photos[second]=true
                local x0,z0,x1,z1=math.huge,math.huge,-math.huge,-math.huge
                local ids={}
                for _,p in ipairs(positions) do ids[#ids+1]=p.id;x0=math.min(x0,p.x);x1=math.max(x1,p.x);z0=math.min(z0,p.z);z1=math.max(z1,p.z) end
                Spring.SelectUnitArray(ids,false)
                local state={mode=1,px=(x0+x1)/2,py=0,pz=(z0+z1)/2,height=math.max(2200,math.max((x1-x0)/1.6,z1-z0)*1.8+1200),angle=0.9}
                Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
                Spring.SetCameraState(state,0)
                camera={state=state,at=Spring.GetTimer(),draws=0,second=second}
            end
        end
    end
    if cfg.remove_air_at and f>=cfg.remove_air_at*30 and not cfg.air_removed then
        cfg.air_removed=true
        local ids={}
        for id,u in pairs(tracked) do if u.team==1 and UnitDefs[u.def].canFly then ids[#ids+1]=id;expectedRemoved[id]=f end end
        Spring.SelectUnitArray(ids,false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        log("fixture_air_removed n="..#ids)
    end
    if cfg.production and f%300==0 then
        for id,u in pairs(tracked) do
            if u.team==0 and UnitDefs[u.def].isFactory and not Spring.GetUnitIsBuilding(id) then
                local cmd=Spring.GetUnitCurrentCommand(id)
                if cmd and cmd<0 then
                    local x,_,z=Spring.GetUnitPosition(id);local nearby={}
                    for other,v in pairs(tracked) do
                        if v.team==0 and other~=id and UnitDefs[v.def].canMove then
                            local ox,_,oz=Spring.GetUnitPosition(other)
                            if ox and (ox-x)^2+(oz-z)^2<300^2 then
                                nearby[#nearby+1]=other..":"..UnitDefs[v.def].name..":"..math.floor(math.sqrt((ox-x)^2+(oz-z)^2))..":"..tostring(Spring.GetUnitCurrentCommand(other))
                            end
                        end
                    end
                    table.sort(nearby)
                    log("yard_wait id="..id.." command="..cmd.." nearby="..table.concat(nearby,","))
                end
            end
        end
    end
    if cfg.release_carriers_at and f>=cfg.release_carriers_at*30 and not cfg.released then
        cfg.released=true
        local ids={}
        for id,u in pairs(tracked) do if UnitDefs[u.def].name==cfg.carrier_unit then ids[#ids+1]=id end end
        table.sort(ids)
        -- The engine's unsynced destroy action uses the selected units; its
        -- text arguments are ignored. Verify physical removal below.
        for _,id in ipairs(ids) do expectedRemoved[id]=f end
        Spring.SelectUnitArray(ids,false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        log("fixture_release hosts="..#ids)
    end
    for id,sent in pairs(expectedRemoved) do
        if not Spring.ValidUnitID(id) or Spring.GetUnitIsDead(id) then
            log("fixture_removed id="..id);expectedRemoved[id]=nil
        elseif f>sent+300 then
            log("ERROR carrier_not_removed="..id);expectedRemoved[id]=nil
        end
    end
    if f%1800==0 then
        if widgetHandler.UnitDamaged~=damageHook or widgetHandler.UnitCommand~=commandHook then log("ERROR observer_replaced") end
        for team,c in pairs(counts) do
            log("orders team="..team.." apm="..c.all.." repeated="..c.repeatCount)
            local commands,defs,sources={},{},{}
            for id,n in pairs(c.commands) do commands[#commands+1]=id..":"..n end
            for name,n in pairs(c.defs) do defs[#defs+1]=name..":"..n end
            for name,n in pairs(c.sources) do sources[#sources+1]=name..":"..n end
            table.sort(commands);table.sort(defs);table.sort(sources)
            log("order_types team="..team.." commands="..table.concat(commands,",").." units="..table.concat(defs,","))
            log("order_sources team="..team.." sources="..table.concat(sources,","))
        end
        counts={}
        local metal={0,0};for id,u in pairs(tracked) do metal[u.team+1]=metal[u.team+1]+UnitDefs[u.def].metalCost end
        log("sample live0="..metal[1].." live1="..metal[2])
    end
end
function widget:DrawScreen()
    if not camera then return end
    Spring.SetCameraState(camera.state,0);camera.draws=camera.draws+1
    if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
        Spring.SendCommands("screenshot png");log("follow_screenshot second="..camera.second)
        Spring.SendCommands({"setmaxspeed "..cfg.speed,"setminspeed "..cfg.speed,"setmaxspeed "..cfg.speed})
        camera=nil;Spring.SelectUnitArray({},false)
    end
end
function widget:Shutdown()
    if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged") end
    if widgetHandler.UnitCommand==commandHook then widgetHandler.UnitCommand=priorCommand;widgetHandler:UpdateCallIn("UnitCommand") end
end
