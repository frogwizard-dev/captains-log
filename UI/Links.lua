local _, ns = ...
local L = ns.L
local UI = ns.UI

-- The link kinds every page can write: a creature, quest, person or land opens its own page
-- (with a way back); a waypoint puts the game's map pin down. UI.Link(text, kind, args...).

local function MobName(id)
    local mob = ns.db.mobs[id]
    return mob and mob.name or L["Unknown creature #%s"]:format(tostring(id))
end

UI.RegisterLink("mob", function(id)
    ns.Book:Goto("bestiary", tonumber(id), true)
end, function(id)
    return MobName(tonumber(id)), L["Click to open in the bestiary."]
end)

UI.RegisterLink("quest", function(id)
    ns.Book:Goto("quests", tonumber(id), true)
end, function(id)
    local quest = ns.db.quests[tonumber(id)]
    return quest and quest.title or L["Quest #%s"]:format(id), L["Click to open in the quest journal."]
end)

UI.RegisterLink("npc", function(id)
    ns.Book:Goto("people", tonumber(id), true)
end, function(id)
    local npc = ns.db.npcs[tonumber(id)]
    if not npc then return end
    return npc.name, (npc.title and (npc.title .. "\n") or "") .. L["Click to open in People."]
end)

UI.RegisterLink("zone", function(name)
    if ns.db.zones[name] then ns.Book:Goto("zones", name, true) end
end, function(name)
    if ns.db.zones[name] then return name, L["Click to open in Lands."] end
end)

UI.RegisterLink("photos", function(day)
    ns.Book:Goto("log", "photos:" .. day, true)
end, function()
    return L["Pictures"], L["Click to see that day's pictures."]
end)

UI.RegisterLink("dungeon", function(key)
    ns.Book:Goto("dungeons", key, true)
end, function()
    return L["Dungeons"], L["Click to open its page in Dungeons: every run, your record against each boss, and the loot."]
end)

UI.RegisterLink("fish", function(id)
    ns.Book:Goto("fishing", tonumber(id), true)
end, function(id)
    local catch = ns.FishingJournal().items[tonumber(id)]
    return catch and catch.name or L["Item #%s"]:format(id), L["Click to open in Fishing."]
end)

UI.RegisterLink("fishspot", function(zone, place)
    local key = ns.FishSpotKey(zone, place)
    if ns.FishSpot(key) then ns.Book:Goto("fishing", key, true) end
end, function(zone, place)
    if ns.FishSpot(ns.FishSpotKey(zone, place)) then
        return ns.FishSpotName(zone, place), L["Click to open this fishing spot in Fishing."]
    end
end)

UI.RegisterLink("back", function()
    ns.Book:GoBack()
end, function()
    return L["Back"], L["Return to the page you came from."]
end)

UI.RegisterLink("wp", function(mapID, x, y)
    UI.Waypoint(mapID, x, y)
end, function()
    return L["Waypoint"], L["Says the spot in chat with a map pin link: click it and the game puts its waypoint there and opens your map on it (click that pin to track it). It replaces any waypoint you placed yourself."]
end)

-- Writers, so pages don't repeat the formatting.

function UI.MobLink(id, text)
    if type(id) ~= "number" then return text or MobName(id) end -- "n:Name" entries can't be keyed
    return UI.Link(text or MobName(id), "mob", id)
end

function UI.QuestLink(id, text)
    local quest = ns.db.quests[id]
    return UI.Link(text or (quest and quest.title) or L["Quest #%s"]:format(id), "quest", id)
end

function UI.NpcLink(id, text)
    local npc = ns.db.npcs[id]
    return UI.Link(text or (npc and npc.name) or L["Unknown #%s"]:format(id), "npc", id)
end

-- A land's name, as a link when it has a Lands page (names with ":" can't be link args).
function UI.ZoneLink(name)
    if not name then return "" end
    if not ns.db.zones[name] or name:find("[:|]") then return name end
    return UI.Link(name, "zone", name)
end

-- A catch, opening its page in Fishing.
function UI.FishLink(id, text)
    local catch = ns.FishingJournal().items[id]
    return UI.Link(text or (catch and catch.name) or L["Item #%s"]:format(id), "fish", id)
end

-- A fishing spot (a place in a land), as a link to its page in Fishing where its names allow.
function UI.FishSpotLink(zone, place, text)
    text = text or place
    if (zone .. place):find("[:|]") then return text end
    return UI.Link(text, "fishspot", zone, place)
end

function UI.WaypointLink(mapID, x, y, text)
    if not (mapID and x and y) then return "" end
    return UI.Link(text or L["Waypoint"], "wp", mapID, x, y)
end
