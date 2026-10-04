local _, ns = ...
local issecret = ns.issecret

-- The fishing journal. Every loot window the game marks as fishing loot (IsFishingLoot) is one
-- catch: each item in it is added to that item's entry and to the spot you fished from (the
-- land and the named place in it). Nothing is kept per cast, only running totals, plus a note of
-- when and where each kind of catch first came up and of the catch that took your skill past
-- each 25 points.
--
-- Pools: the game hands out a pool's fish from the pool itself, so the loot's source is the
-- pool (a game object); fish from open water come from your own bobber. Where the client names
-- no source, the catch is counted but called neither.
--
-- Saved in db.fishing:
--   items[itemID] = { name, icon, quality, link, n = how many, times = catches it was in, last,
--                     first = { t, zone, place, skill, level, pool } }
--   spots[zone][place] = { first, last, casts, n, pool, water, mapID,
--                          items = { [itemID] = { n, p = from pools, w = from open water } },
--                          pts = { { x, y, casts, fromPools } } }
--   n, casts = everything caught and the catches it came in
--   skill, maxRank, since = { t, skill }, milestones[25, 50...] = { t, zone, place, item }

local FISHING_SKILL = 356         -- the Fishing skill line
local BOBBER = { [35591] = true } -- the Fishing Bobber object; any other object is a pool
local MAX_POINTS = 16             -- spots on the map kept per place
local NEAR = 0.006                -- casts closer than this (share of the map) share one spot
local LOG_GAP = 900               -- a catch this soon after the last one adds to its log line
local MILESTONE = 25
local UNKNOWN = "Unknown waters"

-- The journal's tables, made whole again after "Erase this character's log" (which empties
-- the top-level table).
local function Data()
    local f = ns.db.fishing
    if not f then
        f = {}
        ns.db.fishing = f
    end
    f.items = f.items or {}
    f.spots = f.spots or {}
    f.milestones = f.milestones or {}
    return f
end
ns.FishingData = Data

-- A spot is known to the pages by one key: its land and place.
function ns.FishSpotKey(zone, place)
    return zone .. "\n" .. place
end

-- The spot for a key, with its land and place; nil if there's no such spot.
function ns.FishSpot(key)
    if type(key) ~= "string" then return end
    local zone, place = key:match("^(.-)\n(.*)$")
    local spots = zone and Data().spots[zone]
    local spot = spots and spots[place]
    if spot then return spot, zone, place end
end

-- "Auberdine, Darkshore", or just "Darkshore" where you fished outside any named place.
function ns.FishSpotName(zone, place)
    if place == zone then return zone end
    return place .. ", " .. zone
end

-- The places you've fished in one land, most fished first: { { place, spot, key } }.
function ns.FishingSpotsIn(zone)
    local list = {}
    for place, spot in pairs(Data().spots[zone] or {}) do
        list[#list + 1] = { place = place, spot = spot, key = ns.FishSpotKey(zone, place) }
    end
    table.sort(list, function(a, b) return a.spot.n > b.spot.n end)
    return list
end

-- The item caught most at a spot, or nil.
function ns.FishTopCatch(spot)
    local best, most
    for id, s in pairs(spot.items) do
        if not most or s.n > most then best, most = id, s.n end
    end
    return best
end

------------------------------------------------------------------------------
-- Skill
------------------------------------------------------------------------------

local function Clean(v)
    if v == nil or issecret(v) then return nil end
    return v
end

-- Your Fishing skill: rank, the most your training allows, and any bonus (a lure, a pole).
-- Nil if you haven't learned it or the client won't say.
function ns.FishingSkill()
    local info
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
        local ok, i = pcall(C_SkillInfo.GetSkillLineInfoByID, FISHING_SKILL)
        if ok then info = i end
    end
    if not info and C_SkillInfo and C_SkillInfo.GetNumSkillLines then
        local ok, n = pcall(C_SkillInfo.GetNumSkillLines)
        for i = 1, (ok and n) or 0 do
            local ok2, s = pcall(C_SkillInfo.GetSkillLineInfo, i)
            if ok2 and s and s.skillID == FISHING_SKILL then
                info = s
                break
            end
        end
    end
    local rank = info and Clean(info.rank)
    if type(rank) == "number" and rank > 0 then
        return rank, Clean(info.maxRank), Clean(info.modifier)
    end
    -- The newer clients' profession list, where the skill lines above aren't kept.
    if GetProfessions and GetProfessionInfo then
        local ok, _, _, _, fish = pcall(GetProfessions)
        if ok and fish then
            local ok2, _, _, r, maxRank, _, _, _, modifier = pcall(GetProfessionInfo, fish)
            r = ok2 and Clean(r)
            if type(r) == "number" and r > 0 then return r, Clean(maxRank), Clean(modifier) end
        end
    end
end

-- A skill-up comes within a moment of the catch that earned it, before or after its loot
-- window. Each side waits CREDIT seconds (GetTime) for the other.
local CREDIT = 3
local lastCatch -- { at, item } the latest catch
local waiting   -- { at, list } milestones just reached, before their catch was seen

-- Notes the skill and, as it climbs, each 25 points passed: when, where and with what catch.
-- The first reading only sets the starting point; what came before the book isn't known.
-- `quiet` (the journal switched off in Settings) keeps up with the skill but writes nothing.
local function CheckSkill(quiet)
    local rank, maxRank = ns.FishingSkill()
    if not rank then return end
    local f = Data()
    f.maxRank = maxRank or f.maxRank
    if not f.skill then
        f.skill, f.since = rank, { t = time(), skill = rank }
        return
    end
    if rank > f.skill and not quiet then
        local recent = lastCatch and GetTime() - lastCatch.at <= CREDIT and lastCatch.item or nil
        for m = (math.floor(f.skill / MILESTONE) + 1) * MILESTONE, rank, MILESTONE do
            if not f.milestones[m] then
                local place = GetSubZoneText and Clean(GetSubZoneText())
                local ms = { t = time(), zone = ns.Zone(), place = place ~= "" and place or nil, item = recent }
                f.milestones[m] = ms
                if not recent then
                    waiting = waiting and GetTime() - waiting.at <= CREDIT and waiting or { at = GetTime(), list = {} }
                    table.insert(waiting.list, ms)
                end
                ns.Log("fishskill", { rank = m })
            end
        end
    end
    f.skill = rank
    ns.Refresh()
end
ns.CheckFishingSkill = CheckSkill

------------------------------------------------------------------------------
-- Recording a catch
------------------------------------------------------------------------------

-- Where you stood, for the map: casts close together share a point, which counts them. Once a
-- place has its fill of points, a cast counts towards the nearest one.
local function AddPoint(spot, c)
    if not (c.mapID and c.x and c.y) then return end
    if spot.mapID and spot.mapID ~= c.mapID then return end
    spot.mapID = c.mapID
    spot.pts = spot.pts or {}
    local nearest, best
    for _, p in ipairs(spot.pts) do
        local d = math.max(math.abs(p[1] - c.x), math.abs(p[2] - c.y))
        if not best or d < best then nearest, best = p, d end
    end
    if not nearest or (best >= NEAR and #spot.pts < MAX_POINTS) then
        nearest = { c.x, c.y, 0 }
        table.insert(spot.pts, nearest)
    end
    nearest[3] = (nearest[3] or 0) + 1
    if c.pool then nearest[4] = (nearest[4] or 0) + 1 end
end

-- One line in the day's log per spell of fishing in a land: a catch within LOG_GAP of the last
-- adds to it, even with other lines (a fight, a new place) written in between.
local function LogFish(zone, place, items, firsts, total)
    local events = ns.Day().events
    local now = time()
    local ev
    for i = #events, math.max(1, #events - 30), -1 do
        local e = events[i]
        if e.k == "fish" then
            if e.zone == zone and now - (e.last or e.t) < LOG_GAP then ev = e end
            break -- only the latest fishing line can grow
        end
    end
    if not ev then
        ev = ns.Log("fish", { zone = zone, places = {}, n = 0, catch = {}, firsts = {} })
        if not ev then return end -- the day's log is full
    end
    ev.last = now
    ev.n = ev.n + total
    local known = false
    for _, p in ipairs(ev.places) do known = known or p == place end
    if not known then table.insert(ev.places, place) end
    for _, it in ipairs(items) do
        local merged = false
        for _, c in ipairs(ev.catch) do
            if c[1] == it.itemID then
                c[2] = c[2] + it.qty
                merged = true
                break
            end
        end
        if not merged then table.insert(ev.catch, { it.itemID, it.qty }) end
    end
    for _, id in ipairs(firsts) do table.insert(ev.firsts, id) end
    ns.Refresh()
end

-- Adds one catch (a loot window's worth) to the journal and returns the item IDs caught for the
-- first time. c = { items = { { itemID, name, icon, quality, link, qty } }, zone, place, mapID,
-- x, y, pool (true, false, or nil when unknown), skill, level }.
function ns.RecordCatch(c)
    local f = Data()
    local now = time()
    local zone = c.zone or UNKNOWN
    local place = c.place or zone
    f.spots[zone] = f.spots[zone] or {}
    local spot = f.spots[zone][place]
    if not spot then
        spot = { first = now, casts = 0, n = 0, items = {} }
        f.spots[zone][place] = spot
    end
    spot.casts = spot.casts + 1
    spot.last = now
    if c.pool then
        spot.pool = (spot.pool or 0) + 1
    elseif c.pool == false then
        spot.water = (spot.water or 0) + 1
    end

    local firsts, total = {}, 0
    for _, it in ipairs(c.items) do
        local e = f.items[it.itemID]
        if not e then
            e = { n = 0, times = 0, first = { t = now, zone = zone, place = place, skill = c.skill, level = c.level, pool = c.pool } }
            f.items[it.itemID] = e
            firsts[#firsts + 1] = it.itemID
        end
        e.name = it.name or e.name
        e.icon = it.icon or e.icon
        e.quality = it.quality or e.quality
        e.link = it.link or e.link
        e.n = e.n + it.qty
        e.times = e.times + 1
        e.last = now

        local s = spot.items[it.itemID]
        if not s then
            s = { n = 0 }
            spot.items[it.itemID] = s
        end
        s.n = s.n + it.qty
        if c.pool then
            s.p = (s.p or 0) + it.qty
        elseif c.pool == false then
            s.w = (s.w or 0) + it.qty
        end
        spot.n = spot.n + it.qty
        total = total + it.qty
    end
    f.casts = (f.casts or 0) + 1
    f.n = (f.n or 0) + total
    AddPoint(spot, c)

    local day = ns.Day()
    day.fish = (day.fish or 0) + total
    LogFish(zone, place, c.items, firsts, total)

    -- Milestones reached a moment ago, before this catch was seen, are its doing.
    if c.items[1] then
        lastCatch = { at = GetTime(), item = c.items[1].itemID }
        if waiting and GetTime() - waiting.at <= CREDIT then
            for _, ms in ipairs(waiting.list) do ms.item = ms.item or lastCatch.item end
        end
        waiting = nil
    end
    ns.Refresh()
    return firsts
end

------------------------------------------------------------------------------
-- Reading the loot window
------------------------------------------------------------------------------

-- Whether a loot slot came from a pool: true (a pool), false (your bobber, so open water) or
-- nil when the client doesn't say. Also returns the object's ID, for /log debug.
local function FromPool(slot)
    if not GetLootSourceInfo then return nil end
    local guid = GetLootSourceInfo(slot)
    if not guid or issecret(guid) then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if kind ~= "GameObject" or not id then return nil end
    return not BOBBER[id], id
end

local function ReadCatch()
    if not (IsFishingLoot and Clean(IsFishingLoot())) then return false end
    local items, pool, sourceID = {}, nil, nil
    for slot = 1, GetNumLootItems() do
        local link = Clean(GetLootSlotLink(slot))
        local itemID = link and C_Item.GetItemInfoInstant(link)
        if itemID then
            local icon, name, qty, _, quality = GetLootSlotInfo(slot)
            qty = Clean(qty)
            items[#items + 1] = {
                itemID = itemID, link = link, name = Clean(name), icon = Clean(icon), quality = Clean(quality),
                qty = (type(qty) == "number" and qty > 0) and qty or 1,
            }
            local p, id = FromPool(slot)
            if p ~= nil then pool, sourceID = p, id end
        end
    end
    if #items == 0 then return false end -- nothing to read yet; the window's next event may have it

    local zone = ns.Zone()
    local place = GetSubZoneText and Clean(GetSubZoneText())
    if place == "" then place = nil end
    local mapID, x, y = ns.Position()
    local skill = ns.FishingSkill()
    local firsts = ns.RecordCatch({
        items = items, zone = zone, place = place, mapID = mapID, x = x, y = y,
        pool = pool, skill = skill, level = UnitLevel("player"),
    })
    ns.Debug(string.format("Fishing: %d %s from %s (object %s)", #items, #items == 1 and "item" or "items",
        pool == nil and "an unknown source" or (pool and "a pool" or "open water"), tostring(sourceID)))
    if ns.db.settings.announce then
        for _, id in ipairs(firsts) do
            local e = Data().items[id]
            ns.Print("New catch: " .. (e.link or e.name or ("item " .. id)))
        end
    end
    return true
end

-- LOOT_READY and LOOT_OPENED both come with each loot window; the first to find the catch
-- records it and the window is done until it closes. (The time limit is only a safety net in
-- case a close goes unseen.)
local readAt

local function OnLoot()
    if not ns.db.settings.fishing then return end
    if readAt and GetTime() - readAt < 60 then return end
    local ok, result = pcall(ReadCatch)
    if not ok then
        ns.Debug("Couldn't read the catch: " .. tostring(result))
    elseif result then
        readAt = GetTime()
    end
end
ns.On("LOOT_READY", OnLoot)
ns.On("LOOT_OPENED", OnLoot)
ns.On("LOOT_CLOSED", function() readAt = nil end)

-- Skill-ups come as the skill lines change; the first reading after login sets where you stand.
ns.On("SKILL_LINES_CHANGED", function()
    CheckSkill(not ns.db.settings.fishing)
end)
ns.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function() CheckSkill(not ns.db.settings.fishing) end)
end)
