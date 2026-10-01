local _, ns = ...
local issecret = ns.issecret

-- There's no combat log on this client, so kills are pieced together from three signals:
--   death: a mob you or your group tagged is seen dying (target, focus, mouseover, nameplates)
--   xp:    "X dies, you gain N experience." in chat
--   loot:  opening a corpse (also records what it dropped)
-- Each kill is counted once: a death and its XP message pair up within WINDOW seconds, and a
-- kill counted from XP alone pairs up with its corpse if you loot it within LOOT_WINDOW.

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
local guidEvents = {}   -- guid -> its timeline kill entry, so loot can be attached to it

local function Push(tbl, name, now)
    tbl[name] = tbl[name] or {}
    table.insert(tbl[name], now)
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

local function Log(kind, data)
    local events = ns.Day().events
    if #events >= MAX_EVENTS then return end
    data.k, data.t = kind, time()
    table.insert(events, data)
    ns.Refresh()
    return data
end
ns.Log = Log

-- Repeat kills of the same creature within two minutes share one line ("x4").
local function LogKill(id, name, classification, guid)
    local events = ns.Day().events
    local last = events[#events]
    local ev
    if last and last.k == "kill" and last.id == id and time() - last.last < 120 then
        last.n = last.n + 1
        last.last = time()
        ev = last
        ns.Refresh()
    else
        ev = Log("kill", { id = id, name = name, classification = classification, n = 1, last = time() })
    end
    if guid and ev then guidEvents[guid] = ev end
end

-- Puts a corpse's loot on the kill line it came from (or the latest kill of that creature).
local function AttachLoot(guid, id, items)
    if #items == 0 then return end
    local ev = guidEvents[guid]
    if not ev then
        local events = ns.Day().events
        for i = #events, math.max(1, #events - 30), -1 do
            if events[i].k == "kill" and events[i].id == id then
                ev = events[i]
                break
            end
        end
    end
    if not ev then return end
    ev.loot = ev.loot or {}
    for _, item in ipairs(items) do
        local merged = false
        for _, l in ipairs(ev.loot) do
            if l.itemID == item.itemID then
                l.qty = l.qty + item.qty
                merged = true
                break
            end
        end
        if not merged then
            table.insert(ev.loot, { itemID = item.itemID, link = item.link, qty = item.qty })
        end
    end
    ns.Refresh()
end

-- Several first meetings in quick succession (a pack coming into view) share one line.
local function LogMeet(name)
    local events = ns.Day().events
    local last = events[#events]
    if last and last.k == "meet" and time() - last.t < 60 then
        table.insert(last.names, name)
        ns.Refresh()
    else
        Log("meet", { names = { name } })
    end
end

-- Where you stood at the kill, per map, for the bestiary's hunting map.
local MAX_SPOTS = 60
local function RecordSpot(m)
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID or issecret(mapID) then return end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok2 or not pos then return end
    local x, y = pos:GetXY()
    if not x or issecret(x) or issecret(y) then return end
    m.spots = m.spots or {}
    local list = m.spots[mapID] or {}
    m.spots[mapID] = list
    local spot = { math.floor(x * 1000 + 0.5) / 1000, math.floor(y * 1000 + 0.5) / 1000 }
    if #list < MAX_SPOTS then
        table.insert(list, spot)
    else
        list[math.random(MAX_SPOTS)] = spot
    end
end

------------------------------------------------------------------------------
-- Records
------------------------------------------------------------------------------

local function ZoneRecord(name)
    local z = ns.db.zones[name]
    if not z then
        z = { first = time(), level = UnitLevel("player"), seconds = 0, kills = 0, quests = 0, deaths = 0 }
        ns.db.zones[name] = z
        table.insert(ns.Day().zones, name)
        ns.Refresh()
    end
    return z
end
ns.ZoneRecord = ZoneRecord

-- A name for an NPC ID from the client's creature cache, read off a unit-hyperlink tooltip.
-- Dungeons hide enemy names from addons, so mobs met there are first recorded by ID (from their
-- loot) and named this way. Nil if the client hasn't cached that creature yet.
function ns.CreatureName(id)
    if type(id) ~= "number" or not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return end
    local ok, name = pcall(function()
        local data = C_TooltipInfo.GetHyperlink(("unit:Creature-0-0-0-0-%d-0000000000"):format(id))
        return data and data.lines and data.lines[1] and data.lines[1].leftText
    end)
    if not ok or not name or issecret(name) or name == "" then return end
    return name
end

local function Mob(id, name)
    local m = ns.db.mobs[id]
    if not m then
        name = name or ns.CreatureName(id)
        m = {
            name = name, kills = 0, killedMe = 0, looted = 0, drops = {}, zones = {},
            firstSeen = time(), firstZone = ns.Zone(), firstLevel = UnitLevel("player"),
        }
        ns.db.mobs[id] = m
        local day = ns.Day()
        day.discovered = day.discovered + 1
        if ns.db.settings.announce and name then
            ns.Print("New bestiary entry: " .. name)
        end
        if name and type(id) == "number" then LogMeet(name) end
        ns.Refresh()
    end
    if name and not m.name then m.name = name end
    return m
end
ns.Mob = Mob

-- A kill counted from its XP message before the mob's ID was known lives under "n:Name";
-- fold it into the real entry once we learn the ID.
local function MergeNamed(name, id)
    local key = "n:" .. name
    local old = ns.db.mobs[key]
    if not old then return end
    local m = Mob(id, name)
    m.kills = m.kills + old.kills
    m.lastKill = math.max(m.lastKill or 0, old.lastKill or 0)
    for zone, n in pairs(old.zones) do
        m.zones[zone] = (m.zones[zone] or 0) + n
    end
    for mapID, spots in pairs(old.spots or {}) do
        m.spots = m.spots or {}
        m.spots[mapID] = m.spots[mapID] or {}
        for _, spot in ipairs(spots) do table.insert(m.spots[mapID], spot) end
    end
    ns.db.mobs[key] = nil
end

-- Names the bestiary entries recorded without one, where the creature cache now knows them.
-- Returns true if any were named.
function ns.FillNames()
    local named = false
    for id, m in pairs(ns.db.mobs) do
        if not m.name and type(id) == "number" then
            local name = ns.CreatureName(id)
            if name then
                m.name = name
                if not nameToID[name] then MergeNamed(name, id) end
                nameToID[name] = id
                named = true
            end
        end
    end
    return named
end

local function Record(id, name, source, guid)
    local m = Mob(id, name)
    m.kills = m.kills + 1
    m.lastKill = time()
    RecordSpot(m)
    LogKill(id, m.name or name, m.classification, guid)

    local zone = ns.Zone()
    if zone then
        m.zones[zone] = (m.zones[zone] or 0) + 1
        local z = ZoneRecord(zone)
        z.kills = z.kills + 1
    end

    local day = ns.Day()
    day.kills = day.kills + 1
    local run = ns.ActiveRun()
    if run then
        run.kills = run.kills + 1
        run.mobs = run.mobs or {}
        run.mobs[id] = (run.mobs[id] or 0) + 1
    end
    if m.classification and NOTABLE[m.classification] then
        local n = day.notable[id]
        if not n then
            n = { name = m.name, classification = m.classification, count = 0, first = time() }
            day.notable[id] = n
        end
        n.count = n.count + 1
    end

    ns.Debug(string.format("Kill: %s (%s) - %d total", m.name or "?", source, m.kills))
    ns.Refresh()
end

------------------------------------------------------------------------------
-- Discovery and the death signal
------------------------------------------------------------------------------

-- Creates or updates the bestiary entry for an attackable NPC. Returns guid, id, name.
local function Discover(unit)
    if not UnitExists(unit) or UnitIsPlayer(unit) or ns.IsControlled(unit) then return end
    local guid = UnitGUID(unit)
    local id = ns.NpcID(guid)
    if not id then return end
    local attackable = UnitCanAttack("player", unit)
    if issecret(attackable) or not attackable then return end

    local name = UnitName(unit)
    if issecret(name) then name = nil end
    local m = Mob(id, name)
    if name then
        if not nameToID[name] then MergeNamed(name, id) end
        nameToID[name] = id
    end

    local level = UnitLevel(unit)
    if not issecret(level) and level and level > 0 then
        m.minLevel = math.min(m.minLevel or level, level)
        m.maxLevel = math.max(m.maxLevel or level, level)
    end
    local cls = UnitClassification(unit)
    if cls and not issecret(cls) then m.classification = cls end
    local ctype = UnitCreatureType(unit)
    if ctype and not issecret(ctype) then m.creatureType = ctype end
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
    for _, k in ipairs(recentKills) do
        if k.t >= at - 3 and k.t <= at + 1.5 then
            if id and id ~= k.id then return nil end
            id = k.id
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
        -- Only mobs that had you on their threat list: an untagged mob killed by a guard or
        -- another player's pet is in combat, but not with you. Group kills you didn't touch
        -- still count through their XP message.
        local threat = UnitThreatSituation("player", unit)
        if threat ~= nil and not issecret(threat) then seenAlive[guid] = true end
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

local function FormatToPattern(fmt)
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.-)")
    p = p:gsub("%%%%d", "(%%d+)")
    return "^" .. p
end

local XP_PATTERN = COMBATLOG_XPGAIN_FIRSTPERSON and FormatToPattern(COMBATLOG_XPGAIN_FIRSTPERSON)

ns.On("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    if not XP_PATTERN or not msg or issecret(msg) then return end
    local name = msg:match(XP_PATTERN)
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
local lastXP, lastMax, lastLevel
local function TrackXP()
    local xp, max, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if issecret(xp) or issecret(max) then return end
    if lastXP then
        local gain = (level > lastLevel) and (lastMax - lastXP + xp) or (xp - lastXP)
        if gain > 0 then
            local day = ns.Day()
            day.xp = day.xp + gain
            local run = ns.ActiveRun()
            if run then run.xp = (run.xp or 0) + gain end
        end
    end
    lastXP, lastMax, lastLevel = xp, max, level
end
ns.On("PLAYER_XP_UPDATE", TrackXP)

------------------------------------------------------------------------------
-- Loot signal and drops
------------------------------------------------------------------------------

local function LootSignal(guid, id)
    if counted[guid] then return end
    counted[guid] = true
    local m = ns.db.mobs[id]
    local name = m and m.name
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
        local m = Mob(corpse.id)
        m.looted = m.looted + 1
        for _, item in ipairs(corpse.items) do
            local d = m.drops[item.itemID]
            if not d then
                d = { times = 0, qty = 0 }
                m.drops[item.itemID] = d
            end
            d.times = d.times + 1
            d.qty = d.qty + item.qty
            d.link = item.link
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
for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE }) do
    if fmt then table.insert(LOOT_PATTERNS, FormatToPattern(fmt)) end
end

ns.On("CHAT_MSG_LOOT", function(msg)
    if not msg or issecret(msg) then return end
    for _, pattern in ipairs(LOOT_PATTERNS) do
        local link = msg:match(pattern)
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
        local dt = now - since
        local day = ns.Day()
        day.played = day.played + dt
        if currentZone then
            local z = ZoneRecord(currentZone)
            z.seconds = z.seconds + dt
            z.maxLevel = math.max(z.maxLevel or 0, UnitLevel("player"))
        end
    end
    since = now
end

-- Named areas inside a land ("Goldshire", "Jerod's Landing"), each written down the first time
-- you walk into it, with where you were standing. Several in a row share one timeline line.
local function OnSubZone()
    local zone = ns.Zone()
    local place = GetSubZoneText and GetSubZoneText()
    if not zone or not place or place == "" or issecret(place) or place == zone then return end
    local z = ZoneRecord(zone)
    z.places = z.places or {}
    if z.places[place] then return end
    local mapID, x, y = ns.Position()
    z.places[place] = { t = time(), level = UnitLevel("player"), mapID = mapID, x = x, y = y }
    local events = ns.Day().events
    local last = events[#events]
    if last and last.k == "place" and last.zone == zone and time() - last.t < 300 then
        table.insert(last.places, place)
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
    local z = ZoneRecord(zone)
    z.mapID = ns.ZoneMap() or z.mapID
    z.continent = (z.mapID and ns.Continent(z.mapID)) or z.continent
    -- Dungeons, raids and the like are written down as lands too; the Lands page lists them apart.
    local _, itype = GetInstanceInfo()
    if itype and not issecret(itype) and itype ~= "none" then z.instance = itype end
    z.maxLevel = math.max(z.maxLevel or 0, UnitLevel("player"))
    -- Remembered per day so a /reload doesn't write "Travelled to" again (or count a visit).
    local day = ns.Day()
    if day.lastZone ~= zone then
        day.lastZone = zone
        z.visits = (z.visits or 0) + 1
        z.last = time()
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
ns.On("PLAYER_LOGIN", function()
    for id, m in pairs(ns.db.mobs) do
        if type(id) == "number" and m.name then nameToID[m.name] = id end
    end
    C_Timer.NewTicker(30, Tick)
end)

------------------------------------------------------------------------------
-- Levels, deaths, money
------------------------------------------------------------------------------

ns.On("PLAYER_LEVEL_UP", function(level)
    ns.db.levels[level] = { time = time(), zone = ns.Zone() }
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
            if threat ~= nil and not issecret(threat) then
                local guid, id, name = Discover(unit)
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
    if id then
        local m = Mob(id, name)
        m.killedMe = m.killedMe + 1
    end
    if zone then
        local z = ZoneRecord(zone)
        z.deaths = z.deaths + 1
    end
    local m = id and ns.db.mobs[id]
    Log("death", { killer = name, classification = m and m.classification })
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
