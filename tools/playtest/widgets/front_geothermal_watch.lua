-- Engine completion events only: no gameplay commands or AI information feed.
function widget:GetInfo() return {name="FRONT geothermal evidence",layer=10,enabled=true} end
function widget:GameFrame(frame)
    if frame~=30 then return end
    for _,id in ipairs(Spring.GetAllFeatures()) do
        local definition=FeatureDefs[Spring.GetFeatureDefID(id)]
        if definition and definition.geoThermal then
            local x,_,z=Spring.GetFeaturePosition(id)
            Spring.Echo("[FrontGeoEvidence] vent="..math.floor(x)..","..math.floor(z))
        end
    end
end
function widget:UnitDestroyed(id,definition,team)
    local name=UnitDefs[definition].name
    if name:match("geo$") then Spring.Echo("[FrontGeoEvidence] destroyed="..name.." team="..team.." frame="..Spring.GetGameFrame()) end
end
function widget:UnitCreated(id,definition,team,builder)
    local name=UnitDefs[definition].name
    if name:match("geo$") then
        local x,_,z=Spring.GetUnitPosition(id)
        Spring.Echo("[FrontGeoEvidence] created="..name.." team="..team.." frame="..Spring.GetGameFrame()
            .." builder="..tostring(builder).." site="..math.floor(x)..","..math.floor(z))
    end
end
function widget:UnitFinished(id,definition,team)
    local name=UnitDefs[definition].name
    if name:match("geo$") then
        Spring.Echo("[FrontGeoEvidence] finished="..name.." team="..team.." frame="..Spring.GetGameFrame())
    end
end
