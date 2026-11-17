local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- The fishing journal. Each loot window the game marks as fishing loot is one catch, added to its
-- items' entries and to the spot you fished from (the land and the named place in it), as running
-- totals with the first time each catch came up. A pool hands out its fish itself, so the loot's
-- source is the pool; open-water fish come from your bobber; with no source named, it's neither.

local FISHING_SKILL = 356         -- the Fishing skill line
local BOBBER = { [35591] = true } -- the Fishing Bobber object; any other object is a pool
local MAX_POINTS = 16             -- spots on the map kept per place
local NEAR = 0.006                -- casts closer than this (share of the map) share one spot
local LOG_GAP = 900               -- a catch this soon after the last one adds to its log line
local MILESTONE = 25
local UNKNOWN = L["Unknown waters"]

-- db.fishing = { items[itemID] = { name, icon, quality, link, n, times, last, first = { t, zone, place, skill,
-- level, pool } }, spots[zone][place] = { first, last, casts, n, pool, water, mapID, items, pts }, n, casts,
-- skill, maxRank, since, milestones }, made whole again after "Erase this character's log" empties it.
local function Journal()
    local journal = ns.db.fishing
    if not journal then
        journal = {}
        ns.db.fishing = journal
    end
    journal.items = journal.items or {}
    journal.spots = journal.spots or {}
    journal.milestones = journal.milestones or {}
    return journal
end
ns.FishingJournal = Journal

-- A spot is known to the pages by one key: its land and place.
function ns.FishSpotKey(zone, place)
    return zone .. "\n" .. place
end

-- The spot for a key, with its land and place; nil if there's no such spot.
function ns.FishSpot(key)
    if type(key) ~= "string" then return end
    local zone, place = key:match("^(.-)\n(.*)$")
    local spots = zone and Journal().spots[zone]
    local spot = spots and spots[place]
    if spot then return spot, zone, place end
end

-- "Auberdine, Darkshore", or "Darkshore" alone where you fished outside any named place.
function ns.FishSpotName(zone, place)
    if place == zone then return zone end
    return place .. ", " .. zone
end

-- The places you've fished in one land, most fished first: { { place, spot, key } }.
function ns.FishingSpotsIn(zone)
    local list = {}
    for place, spot in pairs(Journal().spots[zone] or {}) do
        list[#list + 1] = { place = place, spot = spot, key = ns.FishSpotKey(zone, place) }
    end
    table.sort(list, function(first, second) return first.spot.n > second.spot.n end)
    return list
end

-- The item caught most at a spot, or nil.
function ns.FishTopCatch(spot)
    local best, most
    for id, tally in pairs(spot.items) do
        if not most or tally.n > most then best, most = id, tally.n end
    end
    return best
end

------------------------------------------------------------------------------
-- Skill
------------------------------------------------------------------------------

local Clean = FrogLib.Safe -- nil for a value the game hides

-- Your Fishing skill: rank, the most your training allows, and any bonus (a lure, a pole).
-- Nil if you haven't learned it or the client won't say.
function ns.FishingSkill()
    local line
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfoByID then
        local ok, found = pcall(C_SkillInfo.GetSkillLineInfoByID, FISHING_SKILL)
        if ok then line = found end
    end
    if not line and C_SkillInfo and C_SkillInfo.GetNumSkillLines then
        local ok, count = pcall(C_SkillInfo.GetNumSkillLines)
        for i = 1, (ok and count) or 0 do
            local okLine, each = pcall(C_SkillInfo.GetSkillLineInfo, i)
            if okLine and each and each.skillID == FISHING_SKILL then
                line = each
                break
            end
        end
    end
    local rank = line and Clean(line.rank)
    if type(rank) == "number" and rank > 0 then
        return rank, Clean(line.maxRank), Clean(line.modifier)
    end
    -- The newer clients' profession list, where the skill lines above aren't kept.
    if GetProfessions and GetProfessionInfo then
        local ok, _, _, _, fishing = pcall(GetProfessions)
        if ok and fishing then
            local okInfo, _, _, professionRank, maxRank, _, _, _, modifier = pcall(GetProfessionInfo, fishing)
            professionRank = okInfo and Clean(professionRank)
            if type(professionRank) == "number" and professionRank > 0 then
                return professionRank, Clean(maxRank), Clean(modifier)
            end
        end
    end
end

-- A skill-up comes within a moment of the catch that earned it, before or after its loot
-- window. Each side waits CREDIT seconds (GetTime) for the other.
local CREDIT = 3
local lastCatch -- { at, item } the latest catch
local waiting   -- { at, list } milestones just reached, before their catch was seen

-- Notes the skill and each 25 points passed (when, where, with what catch); the first reading
-- only sets the start. `quiet` (the journal off in Settings) keeps up but writes nothing.
local function CheckSkill(quiet)
    local rank, maxRank = ns.FishingSkill()
    if not rank then return end
    local journal = Journal()
    journal.maxRank = maxRank or journal.maxRank
    if not journal.skill then
        journal.skill, journal.since = rank, { t = time(), skill = rank }
        return
    end
    if rank > journal.skill and not quiet then
        local recent = lastCatch and GetTime() - lastCatch.at <= CREDIT and lastCatch.item or nil
        for passed = (math.floor(journal.skill / MILESTONE) + 1) * MILESTONE, rank, MILESTONE do
            if not journal.milestones[passed] then
                local place = GetSubZoneText and Clean(GetSubZoneText())
                local milestone = { t = time(), zone = ns.Zone(), place = place ~= "" and place or nil, item = recent }
                journal.milestones[passed] = milestone
                if not recent then
                    waiting = waiting and GetTime() - waiting.at <= CREDIT and waiting or { at = GetTime(), list = {} }
                    table.insert(waiting.list, milestone)
                end
                ns.Log("fishskill", { rank = passed })
            end
        end
    end
    journal.skill = rank
    ns.Refresh()
end
ns.CheckFishingSkill = CheckSkill

------------------------------------------------------------------------------
-- Recording a catch
------------------------------------------------------------------------------

-- Where you stood, for the map: casts close together share a point, which counts them. Once a
-- place has its fill of points, a cast counts towards the nearest one.
local function AddPoint(spot, catch)
    if not (catch.mapID and catch.x and catch.y) then return end
    if spot.mapID and spot.mapID ~= catch.mapID then return end
    spot.mapID = catch.mapID
    spot.pts = spot.pts or {}
    local nearest, best
    for _, point in ipairs(spot.pts) do
        local distance = math.max(math.abs(point[1] - catch.x), math.abs(point[2] - catch.y))
        if not best or distance < best then nearest, best = point, distance end
    end
    if not nearest or (best >= NEAR and #spot.pts < MAX_POINTS) then
        nearest = { catch.x, catch.y, 0 }
        table.insert(spot.pts, nearest)
    end
    nearest[3] = (nearest[3] or 0) + 1
    if catch.pool then nearest[4] = (nearest[4] or 0) + 1 end
end

-- One line in the day's log per spell of fishing in a land: a catch within LOG_GAP of the last
-- adds to it, even with other lines (a fight, a new place) written in between.
local function LogFish(zone, place, items, firsts, total)
    local events = ns.Day().events
    local now = time()
    local line
    for i = #events, math.max(1, #events - 30), -1 do
        local event = events[i]
        if event.k == "fish" then
            if event.zone == zone and now - (event.last or event.t) < LOG_GAP then line = event end
            break -- only the latest fishing line can grow
        end
    end
    if not line then
        line = ns.Log("fish", { zone = zone, places = {}, n = 0, catch = {}, firsts = {} })
        if not line then return end -- the day's log is full
    end
    line.last = now
    line.n = line.n + total
    if not tContains(line.places, place) then table.insert(line.places, place) end
    for _, item in ipairs(items) do
        local merged = false
        for _, caught in ipairs(line.catch) do
            if caught[1] == item.itemID then
                caught[2] = caught[2] + item.qty
                merged = true
                break
            end
        end
        if not merged then table.insert(line.catch, { item.itemID, item.qty }) end
    end
    for _, id in ipairs(firsts) do table.insert(line.firsts, id) end
    ns.Refresh()
end

-- Adds one catch (a loot window's worth) and returns the item IDs caught for the first time.
-- catch = { items = { { itemID, name, icon, quality, link, qty } }, zone, place, mapID, x, y, pool, skill, level }.
function ns.RecordCatch(catch)
    local journal = Journal()
    local now = time()
    local zone = catch.zone or UNKNOWN
    local place = catch.place or zone
    journal.spots[zone] = journal.spots[zone] or {}
    local spot = journal.spots[zone][place]
    if not spot then
        spot = { first = now, casts = 0, n = 0, items = {} }
        journal.spots[zone][place] = spot
    end
    spot.casts = spot.casts + 1
    spot.last = now
    if catch.pool then
        spot.pool = (spot.pool or 0) + 1
    elseif catch.pool == false then
        spot.water = (spot.water or 0) + 1
    end

    local firsts, total = {}, 0
    for _, item in ipairs(catch.items) do
        local entry = journal.items[item.itemID]
        if not entry then
            entry = { n = 0, times = 0,
                first = { t = now, zone = zone, place = place, skill = catch.skill, level = catch.level, pool = catch.pool } }
            journal.items[item.itemID] = entry
            firsts[#firsts + 1] = item.itemID
        end
        entry.name = item.name or entry.name
        entry.icon = item.icon or entry.icon
        entry.quality = item.quality or entry.quality
        entry.link = item.link or entry.link
        entry.n = entry.n + item.qty
        entry.times = entry.times + 1
        entry.last = now

        local tally = spot.items[item.itemID]
        if not tally then
            tally = { n = 0 }
            spot.items[item.itemID] = tally
        end
        tally.n = tally.n + item.qty
        if catch.pool then
            tally.p = (tally.p or 0) + item.qty
        elseif catch.pool == false then
            tally.w = (tally.w or 0) + item.qty
        end
        spot.n = spot.n + item.qty
        total = total + item.qty
    end
    journal.casts = (journal.casts or 0) + 1
    journal.n = (journal.n or 0) + total
    AddPoint(spot, catch)

    local day = ns.Day()
    day.fish = (day.fish or 0) + total
    if ns.Count and total > 0 then ns.Count("fish", total) end
    LogFish(zone, place, catch.items, firsts, total)

    -- Milestones reached a moment ago, before this catch was seen, are its doing.
    if catch.items[1] then
        lastCatch = { at = GetTime(), item = catch.items[1].itemID }
        if waiting and GetTime() - waiting.at <= CREDIT then
            for _, milestone in ipairs(waiting.list) do milestone.item = milestone.item or lastCatch.item end
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
    if issecret(guid) or not guid then return nil end
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
            local fromPool, objectID = FromPool(slot)
            if fromPool ~= nil then pool, sourceID = fromPool, objectID end
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
            local entry = Journal().items[id]
            ns.Print(L["New catch: %s"]:format(entry.link or entry.name or L["item %s"]:format(id)))
        end
    end
    return true
end

-- LOOT_READY and LOOT_OPENED both come with each loot window; the first to find the catch
-- records it, and the window is done until it closes (or a minute passes, if the close is missed).
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
