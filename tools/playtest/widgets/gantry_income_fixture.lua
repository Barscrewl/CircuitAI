function widget:GetInfo()
    return {name="Gantry income fixture",desc="D-287/D-288: injected ~500 then ~1000 metal/s for team 0, then half of the second phase removed",author="CircuitAI",layer=121,enabled=true}
end
-- Fixture evidence only: the economy is injected (cheat give), so a run with
-- this widget is "injected economy (not natural evidence)". The assertions in
-- tech/economy/gantry-scale-fixture.json and late-heavy-*.json are about the
-- AI's decisions on top of that income, never about the supplied assets.
-- One phase = 12 advanced fusions (3000 E/s each) + 50 advanced converters
-- (600 E/s -> ~10.3 M/s each) = ~515 M/s, plus storage so conversion runs.
local FPS=30
local PHASE1=900                -- 0.5 min
local PHASE2=14*60*FPS          -- 14 min
local PHASE3=24*60*FPS          -- 24 min: self-destruct half of phase 2's converters (hysteresis)
local NAMES={
    arm={afus="armafus",conv="armmmkr",estor="armestor",mstor="armmstor",gantry="armshltx"},
    cor={afus="corafus",conv="cormmkr",estor="corestor",mstor="cormstor",gantry="corgant"},
    leg={afus="legafus",conv="legadveconv",estor="legestor",mstor="legmstor",gantry="leggant"},
}
local queue={}
local side=nil
local phase2Converters={}
local gantries=0
local function echo(s) Spring.Echo("[GantryIncomeFixture] "..s) end
local function clamp(v,lo,hi) if v<lo then return lo elseif v>hi then return hi end return v end
local function spot(dx,dz)
    local x,_,z=Spring.GetTeamStartPosition(0)
    -- toward the map centre, so the assets stay on the map and behind no enemy
    local sx=(x < Game.mapSizeX/2) and 1 or -1
    local sz=(z < Game.mapSizeZ/2) and 1 or -1
    x=clamp(x+sx*dx,256,Game.mapSizeX-256); z=clamp(z+sz*dz,256,Game.mapSizeZ-256)
    return x,z
end
local function give(name,count,dx,dz)
    local x,z=spot(dx,dz)
    queue[#queue+1]="give "..tostring(count).." "..name.." 0 @"..math.floor(x)..","..math.floor(Spring.GetGroundHeight(x,z))..","..math.floor(z)
end
local function detectSide()
    local units=Spring.GetTeamUnits(0) or {}
    for i=1,#units do
        local def=UnitDefs[Spring.GetUnitDefID(units[i]) or -1]
        if def then
            local p=string.sub(def.name,1,3)
            if NAMES[p] then return p end
        end
    end
    return "cor"
end
local function phase(label,offset)
    local n=NAMES[side]
    give(n.afus,12,1400+offset,300)
    give(n.conv,50,1400+offset,900)
    give(n.estor,6,900+offset,300)
    give(n.mstor,2,900+offset,700)
    echo("phase "..label..": side="..side.." 12 "..n.afus.." + 50 "..n.conv.." (~515 M/s injected)")
end
function widget:Initialize()
    echo("controlled economy; injected assets are not natural-game evidence")
end
function widget:GameFrame(f)
    if f==300 then Spring.SendCommands("cheat 1"); side=detectSide() end
    if f==PHASE1 then phase("1",0) end
    if f==PHASE2 then phase("2",700) end
    if f==PHASE3 then Spring.SendCommands("team 0") end
    if f==PHASE3+30 then
        local half={}
        for i=1,math.floor(#phase2Converters/2) do half[#half+1]=phase2Converters[i] end
        Spring.GiveOrderToUnitArray(half,CMD.SELFD,{},0)
        echo("phase 3: self-destruct "..#half.." of "..#phase2Converters.." phase-2 converters (hysteresis)")
    end
    if f==PHASE3+60 then Spring.SendCommands("spectator") end
    if #queue>0 and f%30==0 then Spring.SendCommands(table.remove(queue,1)) end
end
function widget:UnitCreated(id,def,team,builder)
    if team~=0 or builder or not side then return end
    local f=Spring.GetGameFrame()
    if f>=PHASE2 and f<PHASE3 and UnitDefs[def].name==NAMES[side].conv then phase2Converters[#phase2Converters+1]=id end
end
function widget:UnitFinished(id,def,team)
    if team~=0 or not side then return end
    if UnitDefs[def].name==NAMES[side].gantry then
        gantries=gantries+1
        local _,_,_,income=Spring.GetTeamResources(0,"metal")
        echo("land gantry finished n="..gantries.." frame="..Spring.GetGameFrame().." income="..math.floor(income or 0))
    end
end
