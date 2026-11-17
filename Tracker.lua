local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- There's no combat log on this client, so kills are pieced together from three signals: a tagged
-- mob seen dying (target, focus, mouseover, nameplates), "X dies, you gain N experience." in chat,
-- and opening its corpse (which also records the drops). Each kill counts once: a death and its XP
-- message pair up within WINDOW seconds, an XP-only kill and its corpse within LOOT_WINDOW.

local WINDOW = 3
local LOOT_WINDOW = 180
local NOTABLE = { rare = true, rareelite = true, elite = true, worldboss = true }

local counted = {}      -- guid -> true once its kill is recorded (this session)
local lootedGuids = {}  -- guid -> true once its loot is recorded
local seenAlive = {}    -- guid -> true when seen alive, in combat and tagged by you/your group
local deathsByName = {} -- name -> times of kills counted from a death, awaiting their XP message
local xpPending = {}    -- name -> times of XP messages awaiting a death
local xpOnly = {}       -- name -> times of kills counted from XP alone, awaiting a corpse
local nameToID = {}     -- name -> npcID, to resolve XP messages
local killLines = {}    -- guid -> its timeline kill line, so loot can be attached to it

local function Push(timesByName, name, now)
    timesByName[name] = timesByName[name] or {}
    table.insert(timesByName[name], now)
end

-- Removes the oldest entry still inside the window; true if there was one.
local function Take(list, now, window)
    if not list then return false end
    for i = #list, 1, -1 do
        if now - list[i] > window then table.remove(list, i) end
    end
    if #list > 0 then
        table.remove(list, 1)
        return true
    end
    return false
end

------------------------------------------------------------------------------
-- Timeline
------------------------------------------------------------------------------

local MAX_EVENTS = 1000

local function Log(kind, line)
    local events = ns.Day().events
    if #events >= MAX_EVENTS then return end
    line.k, line.t = kind, time()
    -- Where it happened, in the journey's coordinates (Journey.lua): pi instance, py north,
    -- px west (yards), pm the zone's map. Left out where positions are hidden.
    if ns.Journey and ns.Journey.Here and line.pi == nil then
        local instance, north, west, map = ns.Journey.Here()
        if instance then line.pi, line.py, line.px, line.pm = instance, north, west, map end
    end
    table.insert(events, line)
    ns.Refresh()
    return line
end
ns.Log = Log

-- The day's latest timeline line, if it's of this kind and its `field` time (t) is recent.
local function Recent(kind, seconds, field)
    local events = ns.Day().events
    local last = events[#events]
    if last and last.k == kind and time() - last[field or "t"] < seconds then return last end
end

-- Repeat kills of the same creature within two minutes share one line ("x4").
local function LogKill(id, name, classification, guid)
    local line = Recent("kill", 120, "last")
    if line and line.id == id then
        line.n = line.n + 1
        line.last = time()
        ns.Refresh()
    else
        line = Log("kill", { id = id, name = name, classification = classification, n = 1, last = time() })
    end
    if ns.Count then ns.Count("kills") end
    if guid and line then killLines[guid] = line end
end

-- Puts a corpse's loot on the kill line it came from (or the latest kill of that creature).
local function AttachLoot(guid, id, items)
    if #items == 0 then return end
    local line = killLines[guid]
    if not line then
        local events = ns.Day().events
        for i = #events, math.max(1, #events - 30), -1 do
            if events[i].k == "kill" and events[i].id == id then
                line = events[i]
                break
            end
        end
    end
    if not line then return end
    line.loot = line.loot or {}
    for _, item in ipairs(items) do
        local merged = false
        for _, held in ipairs(line.loot) do
            if held.itemID == item.itemID then
                held.qty = held.qty + item.qty
                merged = true
                break
            end
        end
        if not merged then
            table.insert(line.loot, { itemID = item.itemID, link = item.link, qty = item.qty })
        end
    end
    ns.Refresh()
end

-- Several first meetings in quick succession (a pack coming into view) share one line.
local function LogMeet(name)
    local line = Recent("meet", 60)
    if line then
        table.insert(line.names, name)
        ns.Refresh()
    else
        Log("meet", { names = { name } })
    end
end

-- Where you stood at the kill, per map, for the bestiary's hunting map.
local MAX_SPOTS = 60
local function RecordSpot(mob)
    local mapID, x, y = ns.Position(true)
    if not mapID then return end
    mob.spots = mob.spots or {}
    local list = mob.spots[mapID] or {}
    mob.spots[mapID] = list
    if #list < MAX_SPOTS then
        table.insert(list, { x, y })
    else
        list[math.random(MAX_SPOTS)] = { x, y }
    end
end

------------------------------------------------------------------------------
-- Records
------------------------------------------------------------------------------

local function ZoneRecord(name)
    local record = ns.db.zones[name]
    if not record then
        record = { first = time(), level = UnitLevel("player"), seconds = 0, kills = 0, quests = 0, deaths = 0 }
        ns.db.zones[name] = record
        table.insert(ns.Day().zones, name)
        ns.Refresh()
    end
    return record
end
ns.ZoneRecord = ZoneRecord

-- An NPC ID's name from the creature cache, off a unit-link tooltip: dungeons hide enemy names, so
-- mobs met there are recorded by ID (from their loot) and named this way. Nil until it's cached.
function ns.CreatureName(id)
    if type(id) ~= "number" or not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return end
    local ok, name = pcall(function()
        local tooltip = C_TooltipInfo.GetHyperlink(("unit:Creature-0-0-0-0-%d-0000000000"):format(id))
        return tooltip and tooltip.lines and tooltip.lines[1] and tooltip.lines[1].leftText
    end)
    if not ok or issecret(name) or not name or name == "" then return end
    return name
end

local function Mob(id, name)
    local mob = ns.db.mobs[id]
    if not mob then
        name = name or ns.CreatureName(id)
        mob = {
            name = name, kills = 0, killedMe = 0, looted = 0, drops = {}, zones = {},
            firstSeen = time(), firstZone = ns.Zone(), firstLevel = UnitLevel("player"),
        }
        ns.db.mobs[id] = mob
        local day = ns.Day()
        day.discovered = day.discovered + 1
        if ns.db.settings.announce and name then
            ns.Print(L["New bestiary entry: %s"]:format(name))
        end
        if name and type(id) == "number" then LogMeet(name) end
        ns.Refresh()
    end
    if name and not mob.name then mob.name = name end
    return mob
end
ns.Mob = Mob

-- A kill counted from its XP message before the mob's ID was known (dungeons hide it) lives under
-- "n:Name", in the bestiary and the run's tally, until the ID turns up and it joins the real entry.
local function MergeRuns(key, id)
    for _, run in ipairs(ns.db.runs or {}) do
        local kills = run.mobs and run.mobs[key]
        if kills then
            run.mobs[id] = (run.mobs[id] or 0) + kills
            run.mobs[key] = nil
        end
    end
end

local function MergeNamed(name, id)
    local key = "n:" .. name
    MergeRuns(key, id)
    local old = ns.db.mobs[key]
    if not old then return end
    local mob = Mob(id, name)
    mob.kills = mob.kills + old.kills
    mob.lastKill = math.max(mob.lastKill or 0, old.lastKill or 0)
    for zone, kills in pairs(old.zones) do
        mob.zones[zone] = (mob.zones[zone] or 0) + kills
    end
    for mapID, spots in pairs(old.spots or {}) do
        mob.spots = mob.spots or {}
        mob.spots[mapID] = mob.spots[mapID] or {}
        for _, spot in ipairs(spots) do table.insert(mob.spots[mapID], spot) end
    end
    ns.db.mobs[key] = nil
end

-- Names the bestiary entries recorded without one, where the creature cache now knows them.
-- Returns true if any were named.
function ns.FillNames()
    local named = false
    for id, mob in pairs(ns.db.mobs) do
        if not mob.name and type(id) == "number" then
            local name = ns.CreatureName(id)
            if name then
                mob.name = name
                if not nameToID[name] then MergeNamed(name, id) end
                nameToID[name] = id
                named = true
            end
        end
    end
    return named
end

local function Record(id, name, source, guid)
    local mob = Mob(id, name)
    mob.kills = mob.kills + 1
    mob.lastKill = time()
    RecordSpot(mob)
    if ns.Moments then pcall(ns.Moments.Kill, id, mob.name or name) end
    LogKill(id, mob.name or name, mob.classification, guid)

    local zone = ns.Zone()
    if zone then
        mob.zones[zone] = (mob.zones[zone] or 0) + 1
        local record = ZoneRecord(zone)
        record.kills = record.kills + 1
    end

    local day = ns.Day()
    day.kills = day.kills + 1
    local run = ns.ActiveRun()
    if run then
        run.kills = run.kills + 1
        run.mobs = run.mobs or {}
        run.mobs[id] = (run.mobs[id] or 0) + 1
    end
    if mob.classification and NOTABLE[mob.classification] then
        local notable = day.notable[id]
        if not notable then
            notable = { name = mob.name, classification = mob.classification, count = 0, first = time() }
            day.notable[id] = notable
        end
        notable.count = notable.count + 1
    end

    ns.Debug(string.format("Kill: %s (%s) - %d total", mob.name or "?", source, mob.kills))
    ns.Refresh()
end

------------------------------------------------------------------------------
-- Discovery and the death signal
------------------------------------------------------------------------------

-- Creates or updates the bestiary entry for an attackable NPC. Returns guid, id, name.
local function Discover(unit)
    if not UnitExists(unit) then return end
    local player = UnitIsPlayer(unit) -- hidden in some content: then left alone
    if issecret(player) or player or ns.IsControlled(unit) then return end
    local guid = UnitGUID(unit)
    local id = ns.NpcID(guid)
    if not id then return end
    local attackable = UnitCanAttack("player", unit)
    if issecret(attackable) or not attackable then return end

    local name = UnitName(unit)
    if issecret(name) then name = nil end
    local mob = Mob(id, name)
    if name then
        if not nameToID[name] then MergeNamed(name, id) end
        nameToID[name] = id
    end

    local level = UnitLevel(unit)
    if not issecret(level) and level and level > 0 then
        mob.minLevel = math.min(mob.minLevel or level, level)
        mob.maxLevel = math.max(mob.maxLevel or level, level)
    end
    local classification = UnitClassification(unit)
    if not issecret(classification) and classification then mob.classification = classification end
    local creatureType = UnitCreatureType(unit)
    if not issecret(creatureType) and creatureType then mob.creatureType = creatureType end
    return guid, id, name
end

-- The moments creatures died, for the quest log to match against objectives that tick up
-- (Quests.lua). Noted as the death or XP message arrives, not when the kill is counted.
local recentKills = {}

local function NoteKill(id)
    if type(id) ~= "number" then return end
    table.insert(recentKills, { id = id, t = GetTime() })
    if #recentKills > 12 then table.remove(recentKills, 1) end
end

-- The creature killed around time `at`, if every kill then was the same kind; nil when there
-- were none or the kills were mixed (no way to tell which one the objective counted).
function ns.KillAround(at)
    local id
    for _, kill in ipairs(recentKills) do
        if kill.t >= at - 3 and kill.t <= at + 1.5 then
            if id and id ~= kill.id then return nil end
            id = kill.id
        end
    end
    return id
end

local function DeathSignal(guid, id, name)
    if counted[guid] then return end
    counted[guid] = true
    NoteKill(id)
    local now = GetTime()
    if name and not Take(xpPending[name], now, WINDOW) then
        Push(deathsByName, name, now)
    end
    Record(id, name, "death", guid)
end

local function Watch(unit)
    local guid, id, name = Discover(unit)
    if not guid then return end
    local dead, denied = UnitIsDead(unit), UnitIsTapDenied(unit)
    if issecret(dead) or issecret(denied) or denied then return end
    if not dead then
        -- Only mobs with you on their threat list: one a guard or another player's pet killed was
        -- in combat, but not with you. Group kills you didn't touch count through their XP message.
        local threat = UnitThreatSituation("player", unit)
        if not issecret(threat) and threat ~= nil then seenAlive[guid] = true end
    elseif seenAlive[guid] then
        seenAlive[guid] = nil
        DeathSignal(guid, id, name)
    end
end

local WATCHED = { target = true, focus = true, mouseover = true, softenemy = true }
local function IsWatched(unit)
    return unit and (WATCHED[unit] or unit:match("^nameplate%d+$"))
end

ns.On("UNIT_HEALTH", function(unit)
    if IsWatched(unit) then Watch(unit) end
end)
ns.On("UNIT_FLAGS", function(unit)
    if IsWatched(unit) then Watch(unit) end
end)
ns.On("NAME_PLATE_UNIT_ADDED", Watch)
ns.On("PLAYER_TARGET_CHANGED", function() Watch("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Watch("mouseover") end)

------------------------------------------------------------------------------
-- XP signal
------------------------------------------------------------------------------

local function FormatToPattern(template)
    local pattern = template:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%%%s", "(.-)")
    pattern = pattern:gsub("%%%%d", "(%%d+)")
    return "^" .. pattern
end

local XP_PATTERN = COMBATLOG_XPGAIN_FIRSTPERSON and FormatToPattern(COMBATLOG_XPGAIN_FIRSTPERSON)

ns.On("CHAT_MSG_COMBAT_XP_GAIN", function(message)
    if not XP_PATTERN or issecret(message) or not message then return end
    local name = message:match(XP_PATTERN)
    if not name or name == "" then return end
    local now = GetTime()
    NoteKill(nameToID[name])
    if Take(deathsByName[name], now, WINDOW) then return end -- already counted from its death
    Push(xpPending, name, now)
    C_Timer.After(WINDOW, function()
        if Take(xpPending[name], GetTime(), WINDOW + 1) then
            Push(xpOnly, name, GetTime())
            Record(nameToID[name] or ("n:" .. name), name, "xp")
        end
    end)
end)

-- Experience earned per day, from any source.
local lastXP, lastXPMax, lastLevel
local function TrackXP()
    local xp, xpMax, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if issecret(xp) or issecret(xpMax) then return end
    if lastXP then
        local gain = (level > lastLevel) and (lastXPMax - lastXP + xp) or (xp - lastXP)
        if gain > 0 then
            local day = ns.Day()
            day.xp = day.xp + gain
            local run = ns.ActiveRun()
            if run then run.xp = (run.xp or 0) + gain end
            if ns.Moments then pcall(ns.Moments.XP, gain) end
        end
    end
    lastXP, lastXPMax, lastLevel = xp, xpMax, level
end
ns.On("PLAYER_XP_UPDATE", TrackXP)

------------------------------------------------------------------------------
-- Loot signal and drops
------------------------------------------------------------------------------

local function LootSignal(guid, id)
    if counted[guid] then return end
    counted[guid] = true
    local mob = ns.db.mobs[id]
    local name = mob and mob.name
    if name and Take(xpOnly[name], GetTime(), LOOT_WINDOW) then return end -- counted from XP
    Record(id, name, "loot", guid)
end

local function ReadLoot()
    local corpses = {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local itemID = link and C_Item.GetItemInfoInstant(link)
        local sources = { GetLootSourceInfo(slot) }
        for i = 1, #sources, 2 do
            local guid, qty = sources[i], sources[i + 1]
            local id = ns.NpcID(guid)
            if id and not lootedGuids[guid] then
                corpses[guid] = corpses[guid] or { id = id, items = {} }
                if itemID then
                    table.insert(corpses[guid].items, { itemID = itemID, qty = qty or 1, link = link })
                end
            end
        end
    end
    for guid, corpse in pairs(corpses) do
        lootedGuids[guid] = true
        LootSignal(guid, corpse.id)
        AttachLoot(guid, corpse.id, corpse.items)
        local mob = Mob(corpse.id)
        mob.looted = mob.looted + 1
        for _, item in ipairs(corpse.items) do
            local drop = mob.drops[item.itemID]
            if not drop then
                drop = { times = 0, qty = 0 }
                mob.drops[item.itemID] = drop
            end
            drop.times = drop.times + 1
            drop.qty = drop.qty + item.qty
            drop.link = item.link
        end
    end
end

local function OnLoot()
    -- Loot data can be restricted in some content; skip rather than error.
    local ok, err = pcall(ReadLoot)
    if not ok then ns.Debug("Couldn't read loot: " .. tostring(err)) end
end
ns.On("LOOT_READY", OnLoot)
ns.On("LOOT_OPENED", OnLoot)

-- Items you receive, for the daily log.
local LOOT_PATTERNS = {}
for _, template in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE }) do
    if template then table.insert(LOOT_PATTERNS, FormatToPattern(template)) end
end

ns.On("CHAT_MSG_LOOT", function(message)
    if issecret(message) or not message then return end
    for _, pattern in ipairs(LOOT_PATTERNS) do
        local link = message:match(pattern)
        if link then
            local quality = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(link)
            if quality and quality >= ns.db.settings.lootQuality then
                local day = ns.Day()
                if #day.loot < 40 then
                    table.insert(day.loot, { link = link, quality = quality, time = time() })
                    ns.Refresh()
                end
                local run = ns.ActiveRun()
                if run and #run.loot < 60 then
                    table.insert(run.loot, { link = link, quality = quality, time = time() })
                end
            end
            return
        end
    end
end)

------------------------------------------------------------------------------
-- Zones and time played
------------------------------------------------------------------------------

local currentZone, since

local function Tick()
    local now = GetTime()
    if since then
        local elapsed = now - since
        local day = ns.Day()
        day.played = day.played + elapsed
        if currentZone then
            local record = ZoneRecord(currentZone)
            record.seconds = record.seconds + elapsed
            record.maxLevel = math.max(record.maxLevel or 0, UnitLevel("player"))
        end
    end
    since = now
end

-- Named areas inside a land ("Goldshire", "Jerod's Landing"), each written down the first time
-- you walk into it, with where you were standing. Several in a row share one timeline line.
local function OnSubZone()
    local zone = ns.Zone()
    local place = GetSubZoneText and GetSubZoneText()
    if issecret(place) or not zone or not place or place == "" or place == zone then return end
    local record = ZoneRecord(zone)
    record.places = record.places or {}
    if record.places[place] then return end
    local mapID, x, y = ns.Position()
    record.places[place] = { t = time(), level = UnitLevel("player"), mapID = mapID, x = x, y = y }
    local line = Recent("place", 300)
    if line and line.zone == zone then
        table.insert(line.places, place)
        ns.Refresh()
    else
        Log("place", { zone = zone, places = { place } })
    end
end

local function OnZone()
    Tick()
    local zone = ns.Zone()
    if not zone then return end
    currentZone = zone
    local isNew = not ns.db.zones[zone]
    local record = ZoneRecord(zone)
    record.mapID = ns.ZoneMap() or record.mapID
    record.continent = (record.mapID and ns.Continent(record.mapID)) or record.continent
    -- Dungeons, raids and the like are written down as lands too; the Lands page lists them apart.
    local _, instanceType = GetInstanceInfo()
    if not issecret(instanceType) and instanceType and instanceType ~= "none" then record.instance = instanceType end
    record.maxLevel = math.max(record.maxLevel or 0, UnitLevel("player"))
    -- Remembered per day so a /reload doesn't write "Travelled to" again (or count a visit).
    local day = ns.Day()
    if day.lastZone ~= zone then
        day.lastZone = zone
        record.visits = (record.visits or 0) + 1
        record.last = time()
        Log("zone", { zone = zone, new = isNew })
    end
    OnSubZone()
end

ns.On("PLAYER_ENTERING_WORLD", function()
    OnZone()
    TrackXP()
    -- Leaving a dungeon: name what was met inside. The cache can take a moment to answer.
    for _, delay in ipairs({ 3, 15 }) do
        C_Timer.After(delay, function()
            if ns.FillNames() then ns.Refresh() end
        end)
    end
end)
ns.On("ZONE_CHANGED_NEW_AREA", OnZone)
ns.On("ZONE_CHANGED", OnSubZone)
ns.On("ZONE_CHANGED_INDOORS", OnSubZone)
-- Newly explored map areas uncover on the bestiary's hunting maps straight away.
ns.On("MAP_EXPLORATION_UPDATED", ns.Refresh)
ns.On("PLAYER_LOGOUT", Tick)

-- "n:Name" -> "Name", for tallies kept by name before the creature's ID was known.
local function NamedKey(key)
    return type(key) == "string" and key:match("^n:(.+)$")
end

ns.On("PLAYER_LOGIN", function()
    for id, mob in pairs(ns.db.mobs) do
        if type(id) == "number" and mob.name then nameToID[mob.name] = id end
    end
    -- Tallies still under "n:Name" (from before runs were merged too) join the creature's entry.
    local named = {}
    for _, run in ipairs(ns.db.runs or {}) do
        for key in pairs(run.mobs or {}) do
            local name = NamedKey(key)
            if name and nameToID[name] then named[name] = true end
        end
    end
    for key in pairs(ns.db.mobs) do
        local name = NamedKey(key)
        if name and nameToID[name] then named[name] = true end
    end
    for name in pairs(named) do MergeNamed(name, nameToID[name]) end
    C_Timer.NewTicker(30, Tick)
end)

------------------------------------------------------------------------------
-- Levels, deaths, money
------------------------------------------------------------------------------

ns.On("PLAYER_LEVEL_UP", function(level)
    -- Merged: Journey.lua and Played.lua keep more on each level's record.
    local record = ns.db.levels[level] or {}
    ns.db.levels[level] = record
    record.time, record.zone = time(), ns.Zone()
    table.insert(ns.Day().levels, level)
    Log("level", { level = level })
end)

-- No combat log means no "killed by" event; the best guess is the hostile mob you were
-- fighting: your target if it had you on its threat list, otherwise the first nameplate that did.
local function LikelyKiller()
    local units = { "target" }
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local threat = UnitThreatSituation("player", unit)
            if not issecret(threat) and threat ~= nil then
                local _, id, name = Discover(unit)
                if id then return id, name end
            end
        end
    end
end

ns.On("PLAYER_DEAD", function()
    local id, name = LikelyKiller()
    local zone = ns.Zone()
    local mapID, x, y = ns.Position()
    local death = { time = time(), zone = zone, level = UnitLevel("player"), killer = name, killerID = id,
        mapID = mapID, x = x, y = y }
    table.insert(ns.db.deaths, death)
    table.insert(ns.Day().deaths, death)
    local killer = id and Mob(id, name)
    if killer then killer.killedMe = killer.killedMe + 1 end
    if zone then
        local record = ZoneRecord(zone)
        record.deaths = record.deaths + 1
    end
    Log("death", { killer = name, classification = killer and killer.classification })
end)

local lastMoney
ns.On("PLAYER_MONEY", function()
    local money = GetMoney()
    if lastMoney then
        local day = ns.Day()
        if money > lastMoney then
            day.moneyIn = day.moneyIn + (money - lastMoney)
            local run = ns.ActiveRun()
            if run then run.money = (run.money or 0) + (money - lastMoney) end
        else
            day.moneyOut = day.moneyOut + (lastMoney - money)
        end
    end
    lastMoney = money
end)
ns.On("PLAYER_LOGIN", function() lastMoney = GetMoney() end)
