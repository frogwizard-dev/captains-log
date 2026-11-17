local ADDON, ns = ...
local L = ns.L

ns.defaults = {
    settings = {
        tooltip = true,     -- kill counts on unit tooltips
        announce = false,   -- chat line for each new bestiary entry
        debug = false,      -- chat line for each counted kill and which signal caught it
        lootQuality = 2,    -- lowest item quality kept in the daily log (2 = uncommon)
        photosAll = true,   -- every screenshot becomes a photo card, not only "Take a picture"
        photoClean = true,  -- "Take a picture" hides the interface for the shot (out of combat)
        photosShow = false, -- show the screenshots themselves (after "Set up pictures.bat")
        photoView = "list", -- the Pictures page: "list" (cards one under another) or "grid"
        fishing = true,     -- keep the fishing journal (what you catch, where, your skill)
        fishPins = false,   -- show the spots you've fished from on the world map
        gossip = true,      -- write down what people say to you and the replies you choose
        pathKeepDays = 0,   -- days of full-detail journey paths; older ones are thinned (0 = keep all)
        journeyButton = true, -- the journey map's button on the world map (UI\JourneyMap.lua)
        journeyCompress = true, -- the journey map's time bar squeezes quiet stretches
        journeyNotes = true,  -- the journey map labels things as they happen during playback
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
    travel = {},    -- [mode] = yards moved: foot, mount, swim, taxi, ghost (Journey.lua)
    time = {},      -- [state] = seconds, lifetime (Journey.lua)
    ledger = { inc = {}, exp = {} }, -- [category] = copper, lifetime (Ledger.lua)
    stats = {},     -- [counter] = lifetime count (Stats.lua)
    seenItems = {}, -- [itemID] = true for every uncommon+ item ever acquired (Stats.lua)
    factions = {},  -- [faction name] = standing tier last seen (Stats.lua)
    skills = {},    -- [skill name] = rank last seen (Stats.lua)
}

-- Midnight hides some values from addons ("secret values"); they can't be compared or stored.
ns.issecret = FrogLib.issecret

ns.Print = FrogLib.Util.Printer(L["Captain's Log"], "d8b56a")

function ns.Debug(text)
    if ns.db and ns.db.settings.debug then
        print("|cffd8b56aCaptain's Log|r |cff999999" .. text .. "|r")
    end
end

-- Event bus: modules subscribe with ns.On; handlers only run once saved data is loaded.
local frame = CreateFrame("Frame")
local handlers = { ADDON_LOADED = {} }
frame:RegisterEvent("ADDON_LOADED")

function ns.On(event, handler)
    if not handlers[event] then
        handlers[event] = {}
        pcall(frame.RegisterEvent, frame, event) -- tolerate events this client doesn't have
    end
    table.insert(handlers[event], handler)
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        CaptainsLogDB = CaptainsLogDB or {}
        CaptainsLogDB.probe = nil -- the old /log probe test's lines
        FrogLib.Util.CopyDefaults(ns.defaults, CaptainsLogDB)
        ns.db = CaptainsLogDB
    end
    if not ns.db then return end
    for _, handler in ipairs(handlers[event]) do
        handler(...)
    end
end)

------------------------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------------------------

-- A unit's whole name. On Forever, UnitName's second return is the character's surname (on
-- other clients it's the realm, so it's left off there): "Feral Streep", not "Feral".
local BUILD = select(4, GetBuildInfo())
local FOREVER = BUILD > 16000 and BUILD < 20000
function ns.FullName(unit)
    local name, surname = UnitName(unit or "player")
    if ns.issecret(name) or not name or name == "" then return nil end
    if FOREVER and type(surname) == "string" and surname ~= "" and not ns.issecret(surname) then
        return name .. " " .. surname
    end
    return name
end

-- A string the game showed, or nil when it's hidden, empty or not a string.
function ns.PlainText(value)
    if type(value) ~= "string" or ns.issecret(value) or value == "" then return nil end
    return value
end

function ns.PlainNumber(value)
    if type(value) == "number" and not ns.issecret(value) then return value end
end

local function Returned(ok, ...)
    if ok then return ... end
end

-- Calls an API that may be missing or may fail; nothing comes back then.
function ns.Call(Function, ...)
    if not Function then return end
    return Returned(pcall(Function, ...))
end

-- A yes/no API answer, false when it's missing, fails or is hidden.
function ns.Truthy(Query, ...)
    local answer = ns.Call(Query, ...)
    if ns.issecret(answer) then return false end
    return answer and true or false
end

function ns.Today()
    return date("%Y-%m-%d")
end

function ns.Day(key)
    key = key or ns.Today()
    local day = ns.db.days[key]
    if not day then
        day = {
            played = 0, kills = 0, xp = 0, moneyIn = 0, moneyOut = 0, discovered = 0,
            startLevel = UnitLevel("player"),
            levels = {}, zones = {}, quests = {}, notable = {}, loot = {}, deaths = {}, note = "",
            events = {}, -- the timeline: { k = kind, t = time, ... }
        }
        ns.db.days[key] = day
    end
    day.events = day.events or {} -- days logged before the timeline existed
    return day
end

function ns.DayTime(key)
    local year, month, day = key:match("(%d+)-(%d+)-(%d+)")
    return time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
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
        local map = C_Map.GetMapInfo(mapID)
        -- 5 = micro (a cave, a building), 6 = orphan
        if not map or (map.mapType or 0) < 5 or not map.parentMapID or map.parentMapID == 0 then break end
        mapID = map.parentMapID
    end
    return mapID
end

-- The continent a map lies on ("Eastern Kingdoms"), or nil.
function ns.Continent(mapID)
    for _ = 1, 10 do
        local map = mapID and C_Map.GetMapInfo(mapID)
        if not map then return nil end
        if map.mapType == 2 then return map.name end -- 2 = continent
        mapID = map.parentMapID
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
        local ok, bestID = pcall(C_Map.GetBestMapForUnit, "player")
        mapID = ok and FrogLib.Safe(bestID) or nil
    else
        mapID = ns.ZoneMap()
    end
    if ns.issecret(mapID) or not mapID then return end
    local ok, position = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or not position then return end
    local x, y = position:GetXY()
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
    local hours, minutes = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if hours > 0 then return string.format(L["%dh %dm"], hours, minutes) end
    if minutes > 0 then return string.format(L["%dm"], minutes) end
    return L["under a minute"]
end

function ns.Ago(when)
    local seconds = time() - when
    if seconds < 60 then return L["just now"] end
    if seconds < 3600 then return L["%dm ago"]:format(math.floor(seconds / 60)) end
    if seconds < 86400 then return L["%dh ago"]:format(math.floor(seconds / 3600)) end
    return L["%dd ago"]:format(math.floor(seconds / 86400))
end

-- The dungeon run you're in right now, if any (Dungeons.lua fills this in).
function ns.ActiveRun() end

-- Fight lengths: "1m 12s", "45s".
function ns.Short(seconds)
    seconds = math.floor(seconds or 0)
    if seconds >= 60 then return string.format(L["%dm %02ds"], math.floor(seconds / 60), seconds % 60) end
    return L["%ds"]:format(seconds)
end

function ns.Date(when)
    return date("%d %b %Y", when)
end

ns.Money = FrogLib.Text.Coins -- "4g 50s 20c" with coin icons

function ns.Number(count)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(count) or tostring(count)
end

-- One "data changed" signal for many, so an open book redraws at most a few times a second.
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
SlashCmdList.CAPTAINSLOG = function(input)
    local command = strtrim(input or ""):lower()
    if command == "debug" then
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print(L["kill debug messages %s"]:format(ns.db.settings.debug and L["on"] or L["off"]))
    elseif command == "journey" then
        if ns.JourneyReport then ns.JourneyReport() end
    elseif command == "journey play" then
        if ns.JourneyMap then ns.JourneyMap.Show() end
    elseif command == "picture" or command == "photo" then
        ns.TakePicture()
    else
        ns.Book:Toggle()
    end
end

function CaptainsLog_OnCompartmentClick()
    ns.Book:Toggle()
end
