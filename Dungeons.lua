local _, ns = ...
local issecret = ns.issecret

-- One record per dungeon or raid run. Leaving and coming back to the same instance within
-- RETURN_WINDOW (a corpse run, a quick trip out to repair) continues the same run.
-- Bosses come from ENCOUNTER_START/END, which the game sends to addons even without a
-- combat log, so they work in content where other data is restricted.

local RETURN_WINDOW = 1800
local INSTANCE_TYPES = { party = true, raid = true, scenario = true }

local function Current()
    local i = ns.db.activeRun
    return i and ns.db.runs[i]
end

-- Only while you're actually inside it.
function ns.ActiveRun()
    local run = Current()
    if run and not run.leftAt then return run end
end

local function Finish(run)
    run.finish = run.leftAt or time()
    ns.db.activeRun = nil
end

-- The Encounter Journal's ID for the instance you're in, if it knows it.
local function JournalID()
    if not EJ_GetInstanceForMap then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or issecret(mapID) or not mapID then return nil end
    local ok2, journalID = pcall(EJ_GetInstanceForMap, mapID)
    if not ok2 or not journalID or journalID == 0 then return nil end
    return journalID
end

-- The bosses the Encounter Journal lists for an instance, in order. Nil if it doesn't know it.
function ns.JournalBosses(journalID)
    if not journalID or not EJ_GetEncounterInfoByIndex then return nil end
    local names = {}
    while true do
        local ok, name = pcall(EJ_GetEncounterInfoByIndex, #names + 1, journalID)
        if not ok or not name then break end
        names[#names + 1] = name
    end
    return #names > 0 and names or nil
end

local function CountBosses(run)
    run.journalID = run.journalID or JournalID()
    local names = ns.JournalBosses(run.journalID)
    return names and #names
end

local function Role(unit)
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
    if not issecret(role) and role and role ~= "NONE" then return role end
end

local function AddGroup(run)
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, GetNumGroupMembers() do
        local unit = prefix .. i
        if UnitExists(unit) and not FrogLib.Safe(UnitIsUnit(unit, "player")) then
            local name = GetUnitName(unit, true)
            local _, class = UnitClass(unit)
            class = FrogLib.Safe(class) -- saved: never a value the game hides
            if not issecret(name) and name then
                local known
                for _, member in ipairs(run.group) do
                    if member.name == name then known = member break end
                end
                if known then
                    known.role = known.role or Role(unit)
                else
                    table.insert(run.group, { name = name, class = class, role = Role(unit) })
                end
            end
        end
    end
    run.role = run.role or Role("player")
end

local function GroupNames(run)
    local names = {}
    for _, member in ipairs(run.group) do names[#names + 1] = (strsplit("-", member.name)) end
    return names
end

local function OnZone()
    local run = Current()
    if run and run.leftAt and time() - run.leftAt >= RETURN_WINDOW then
        Finish(run)
        run = nil
    end

    local name, itype, _, difficulty, maxPlayers, _, _, instanceID = GetInstanceInfo()
    if INSTANCE_TYPES[itype] and not issecret(name) and name then
        if run and run.instanceID == instanceID then
            if run.leftAt then
                run.leftAt = nil
                ns.Log("dungeon", { name = name, returning = true })
            end
        else
            if run then Finish(run) end
            run = {
                name = name, instanceID = instanceID, difficulty = difficulty, type = itype, size = maxPlayers,
                start = time(), level = UnitLevel("player"), group = {}, bosses = {}, wipes = 0, wipesOn = {},
                deaths = 0, kills = 0, loot = {}, mobs = {}, xp = 0, money = 0,
            }
            run.totalBosses = CountBosses(run)
            table.insert(ns.db.runs, run)
            ns.db.activeRun = #ns.db.runs
            AddGroup(run)
            ns.Log("dungeon", { name = name, difficulty = difficulty, group = GroupNames(run) })
        end
        run.totalBosses = run.totalBosses or CountBosses(run)
    elseif run and not run.leftAt then
        run.leftAt = time()
        ns.Log("dungeonLeave", {
            name = run.name, duration = run.leftAt - run.start, bosses = #run.bosses, total = run.totalBosses,
        })
    end
    ns.Refresh()
end

ns.On("PLAYER_ENTERING_WORLD", OnZone)
ns.On("ZONE_CHANGED_NEW_AREA", OnZone)

ns.On("GROUP_ROSTER_UPDATE", function()
    local run = ns.ActiveRun()
    if run then AddGroup(run) end
end)

ns.On("PLAYER_DEAD", function()
    local run = ns.ActiveRun()
    if run then run.deaths = run.deaths + 1 end
end)

ns.On("ENCOUNTER_START", function()
    local run = ns.ActiveRun()
    if run then run.pullAt = time() end
end)

ns.On("ENCOUNTER_END", function(encounterID, encounterName, _, _, success)
    local run = ns.ActiveRun()
    if not run or issecret(success) then return end
    if issecret(encounterName) or not encounterName then encounterName = "a boss" end
    if issecret(encounterID) then encounterID = encounterName end
    local duration = run.pullAt and (time() - run.pullAt)
    run.pullAt = nil
    if success == 1 then
        local boss = { name = encounterName, t = time(), duration = duration, wipes = run.wipesOn[encounterID] or 0 }
        table.insert(run.bosses, boss)
        ns.Log("boss", { name = encounterName, duration = duration, wipes = boss.wipes })
    else
        run.wipes = run.wipes + 1
        run.wipesOn[encounterID] = (run.wipesOn[encounterID] or 0) + 1
        ns.Log("wipe", { name = encounterName })
    end
    ns.Refresh()
end)

-- Wraps up a run you left long ago (e.g. logged out after a dungeon, back the next day).
ns.On("PLAYER_LOGIN", function()
    C_Timer.NewTicker(60, function()
        local run = Current()
        if run and run.leftAt and time() - run.leftAt >= RETURN_WINDOW then
            Finish(run)
            ns.Refresh()
        end
    end)
end)

function ns.RunDuration(run)
    return (run.finish or run.leftAt or time()) - run.start
end
