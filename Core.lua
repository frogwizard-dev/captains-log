local ADDON, ns = ...

ns.defaults = {
    settings = {
        tooltip = true,     -- kill counts on unit tooltips
        announce = false,   -- chat line for each new bestiary entry
        debug = false,      -- chat line for each counted kill and which signal caught it
        lootQuality = 2,    -- lowest item quality kept in the daily log (2 = uncommon)
        photosAll = true,   -- every screenshot becomes a photo card, not just "Take a picture"
        photoClean = true,  -- "Take a picture" hides the interface for the shot (out of combat)
        photosShow = false, -- show the screenshots themselves (after "Set up pictures.bat")
        photoView = "list", -- the Pictures page: "list" (cards one under another) or "grid"
        fishing = true,     -- keep the fishing journal (what you catch, where, your skill)
        fishPins = false,   -- show the spots you've fished from on the world map
        gossip = true,      -- write down what people say to you and the replies you choose
    },
    mobs = {},    -- [npcID] = bestiary entry; "n:Name" keys hold kills not yet matched to an ID
    quests = {},  -- [questID] = { title, accepted, completed, ... }
    zones = {},   -- [zone name] = { first, level, seconds, kills, quests, deaths }
    days = {},    -- ["YYYY-MM-DD"] = daily log
    levels = {},  -- [level] = { time, zone }
    deaths = {},  -- list of { time, zone, level, killer, killerID }
    runs = {},    -- dungeon/raid runs, oldest first; db.activeRun indexes the current one
    npcs = {},    -- [npcID] = friendly NPC: title, location, roles, quests, what they sell
    mapLayers = {}, -- entries pinned to the world map: { kind = "quest"|"mob"|"npc"|"zone", id }
    photoRemoved = {}, -- [screenshot file] = true for pictures taken out, so they're never re-added
    fishing = { items = {}, spots = {}, milestones = {} }, -- the fishing journal (Fishing.lua)
}

-- Midnight hides some values from addons ("secret values"); they can't be compared or stored.
ns.issecret = FrogLib.issecret

ns.Print = FrogLib.Util.Printer("Captain's Log", "d8b56a")

function ns.Debug(msg)
    if ns.db and ns.db.settings.debug then
        print("|cffd8b56aCaptain's Log|r |cff999999" .. msg .. "|r")
    end
end

local CopyDefaults = FrogLib.Util.CopyDefaults

-- Event bus: modules subscribe with ns.On; handlers only run once saved data is loaded.
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        pcall(frame.RegisterEvent, frame, event) -- tolerate events this client doesn't have
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= ADDON then return end
        CaptainsLogDB = CaptainsLogDB or {}
        CopyDefaults(ns.defaults, CaptainsLogDB)
        ns.db = CaptainsLogDB
    end
    if not ns.db then return end
    for _, fn in ipairs(handlers[event]) do
        fn(...)
    end
end)
ns.On("ADDON_LOADED", function() end)

------------------------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------------------------

function ns.Today()
    return date("%Y-%m-%d")
end

function ns.Day(key)
    key = key or ns.Today()
    local d = ns.db.days[key]
    if not d then
        d = {
            played = 0, kills = 0, xp = 0, moneyIn = 0, moneyOut = 0, discovered = 0,
            startLevel = UnitLevel("player"),
            levels = {}, zones = {}, quests = {}, notable = {}, loot = {}, deaths = {}, note = "",
            events = {}, -- the timeline: { k = kind, t = time, ... }
        }
        ns.db.days[key] = d
    end
    d.events = d.events or {} -- days logged before the timeline existed
    return d
end

function ns.DayTime(key)
    local y, m, d = key:match("(%d+)-(%d+)-(%d+)")
    return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

function ns.Zone()
    local zone = GetRealZoneText()
    if ns.issecret(zone) or not zone or zone == "" then return nil end
    return zone
end

-- The map of the land you're in: the best map, lifted out of caves and other micro maps so
-- every spot recorded in one zone shares one map. Nil where the map is hidden.
function ns.ZoneMap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or ns.issecret(mapID) or not mapID then return nil end
    for _ = 1, 5 do
        local info = C_Map.GetMapInfo(mapID)
        -- 5 = micro (a cave, a building), 6 = orphan
        if not info or (info.mapType or 0) < 5 or not info.parentMapID or info.parentMapID == 0 then break end
        mapID = info.parentMapID
    end
    return mapID
end

-- The continent a map lies on ("Eastern Kingdoms"), or nil.
function ns.Continent(mapID)
    for _ = 1, 10 do
        local info = mapID and C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == 2 then return info.name end -- 2 = continent
        mapID = info.parentMapID
    end
end

-- A unit someone controls: a totem, pet, guardian or companion. They're neither folk nor foes.
function ns.IsControlled(unit)
    local controlled = UnitPlayerControlled(unit)
    -- Hidden in some content; then assume not, rather than stop recording creatures there.
    if not ns.issecret(controlled) and controlled then return true end
    if UnitIsBattlePetCompanion and UnitIsBattlePetCompanion(unit) then return true end
    return false
end

-- Where you stand: mapID, x, y (0-1, rounded). On the zone's map unless `best` asks for the
-- most detailed one. Nil where positions are hidden (most instances).
function ns.Position(best)
    local mapID
    if best then
        local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
        mapID = ok and FrogLib.Safe(id) or nil
    else
        mapID = ns.ZoneMap()
    end
    if ns.issecret(mapID) or not mapID then return end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or not pos then return end
    local x, y = pos:GetXY()
    if ns.issecret(x) or ns.issecret(y) or not x then return end
    return mapID, math.floor(x * 1000 + 0.5) / 1000, math.floor(y * 1000 + 0.5) / 1000
end

-- "Creature-0-1234-0-12-448-000012AB34" -> 448. Nil for players, pets, objects and secrets.
function ns.NpcID(guid)
    if ns.issecret(guid) or not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then
        return tonumber(id)
    end
end

function ns.Duration(seconds)
    seconds = math.floor(seconds or 0)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return "under a minute"
end

function ns.Ago(t)
    local s = time() - t
    if s < 60 then return "just now" end
    if s < 3600 then return math.floor(s / 60) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

-- The dungeon run you're in right now, if any (Dungeons.lua fills this in).
function ns.ActiveRun() end

-- Fight lengths: "1m 12s", "45s".
function ns.Short(seconds)
    seconds = math.floor(seconds or 0)
    if seconds >= 60 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
    return seconds .. "s"
end

function ns.Date(t)
    return date("%d %b %Y", t)
end

-- "4g 50s 20c" with coin icons. GetCoinTextureString moved to C_CurrencyInfo and isn't a
-- global on this client, so fall back through the known homes, then build it ourselves.
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:1:0|t"
function ns.Money(copper)
    copper = copper or 0
    local fn = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    if fn then
        local ok, text = pcall(fn, copper)
        if ok and text then return text end
    end
    local g, s, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. COIN:format("Gold") end
    if s > 0 then parts[#parts + 1] = s .. COIN:format("Silver") end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COIN:format("Copper") end
    return table.concat(parts, " ")
end

function ns.Number(n)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

-- Coalesced "data changed" signal so an open book re-renders at most a few times a second.
local refreshQueued = false
function ns.Refresh()
    if refreshQueued or not ns.Book then return end
    refreshQueued = true
    C_Timer.After(0.3, function()
        refreshQueued = false
        ns.Book:Rerender()
    end)
end

SLASH_CAPTAINSLOG1 = "/log"
SLASH_CAPTAINSLOG2 = "/captainslog"
SlashCmdList.CAPTAINSLOG = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "debug" then
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print("kill debug messages " .. (ns.db.settings.debug and "on" or "off"))
    elseif msg == "picture" or msg == "photo" then
        ns.TakePicture()
    elseif msg == "probe" or msg:match("^probe ") then
        ns.Probe(msg:match("^probe%s+(%S+)"))
    else
        ns.Book:Toggle()
    end
end

function CaptainsLog_OnCompartmentClick()
    ns.Book:Toggle()
end
