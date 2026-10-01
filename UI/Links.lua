local _, ns = ...
local UI = ns.UI

-- The link kinds every page can write: a creature, quest, person or land opens its own page
-- (with a way back); a waypoint puts the game's map pin down. UI.Link(text, kind, args...).

local function MobName(id)
    local m = ns.db.mobs[id]
    return m and m.name or ("Unknown creature #" .. tostring(id))
end

UI.RegisterLink("mob", function(id)
    ns.Book:Goto("bestiary", tonumber(id), true)
end, function(id)
    return MobName(tonumber(id)), "Click to open in the bestiary."
end)

UI.RegisterLink("quest", function(id)
    ns.Book:Goto("quests", tonumber(id), true)
end, function(id)
    local q = ns.db.quests[tonumber(id)]
    return q and q.title or ("Quest #" .. id), "Click to open in the quest journal."
end)

UI.RegisterLink("npc", function(id)
    ns.Book:Goto("people", tonumber(id), true)
end, function(id)
    local n = ns.db.npcs[tonumber(id)]
    if not n then return end
    return n.name, (n.title and (n.title .. "\n") or "") .. "Click to open in People."
end)

UI.RegisterLink("zone", function(name)
    if ns.db.zones[name] then ns.Book:Goto("zones", name, true) end
end, function(name)
    if ns.db.zones[name] then return name, "Click to open in Lands." end
end)

UI.RegisterLink("photos", function(day)
    ns.Book:Goto("log", "photos:" .. day, true)
end, function()
    return "Pictures", "Click to see that day's pictures."
end)

UI.RegisterLink("dungeon", function(key)
    ns.Book:Goto("dungeons", key, true)
end, function()
    return "Dungeons", "Click to open its page in Dungeons: every run, your record against each boss, and the loot."
end)

UI.RegisterLink("back", function()
    ns.Book:GoBack()
end, function()
    return "Back", "Return to the page you came from."
end)

UI.RegisterLink("wp", function(mapID, x, y)
    UI.Waypoint(mapID, x, y)
end, function()
    return "Waypoint", "Puts a pin on your world map, with the arrow on screen to lead you there. "
        .. "It replaces any pin you placed yourself."
end)

-- Writers, so pages don't repeat the formatting.

function UI.MobLink(id, text)
    if type(id) ~= "number" then return text or MobName(id) end -- "n:Name" entries can't be keyed
    return UI.Link(text or MobName(id), "mob", id)
end

function UI.QuestLink(id, text)
    local q = ns.db.quests[id]
    return UI.Link(text or (q and q.title) or ("Quest #" .. id), "quest", id)
end

function UI.NpcLink(id, text)
    local n = ns.db.npcs[id]
    return UI.Link(text or (n and n.name) or ("Unknown #" .. id), "npc", id)
end

-- A land's name, as a link when it has a Lands page (names with ":" can't be link args).
function UI.ZoneLink(name)
    if not name then return "" end
    if not ns.db.zones[name] or name:find("[:|]") then return name end
    return UI.Link(name, "zone", name)
end

function UI.WaypointLink(mapID, x, y, text)
    if not (mapID and x and y) then return "" end
    return UI.Link(text or "Waypoint", "wp", mapID, x, y)
end
