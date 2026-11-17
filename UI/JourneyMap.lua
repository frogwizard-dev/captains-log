local _, ns = ...
local L = ns.L
local UI = ns.UI

-- The Journey window: a day's route (Journey.lua) played back on a map of our own, drawn from the zone's
-- art tiles on a canvas scaled to zoom and moved to pan, with a time bar to play, click or drag through
-- the day and the log's entries as icons where they happened. Redraws are held to 30 a second, nothing
-- runs while it's shut, and Blizzard's world map is never touched (driving it tainted its quest pins).

local JourneyMap = {}
ns.JourneyMap = JourneyMap

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SPEEDS = { { 60, "1x" }, { 300, "5x" }, { 1200, "20x" }, { 6000, "100x" } } -- game seconds per second
local GAP = 300          -- seconds without a point: playback jumps straight over it
local MAX_POINTS = 8000  -- "All days" is thinned to about this many points
local MAX_TICKS = 400
local FRAME = 1 / 30     -- seconds between redraws (30 a second)
local FOLLOW_ZOOM = 2.5  -- how far in the camera starts while following
local MAX_ZOOM = 12
local PORTRAIT_W, PORTRAIT_H = 220, 300
local PAST = { 0.85, 0.15, 0.08, 0.95 }
local FUTURE = { 0.85, 0.15, 0.08, 0.22 }
local WIDTH = 3          -- line width on screen, in pixels
local ICON = 16          -- event icon size on screen

-- Each kind of log entry's icon on the map: a file, an atlas, or a function of the entry.
local function ItemIcon(line) return UI.ItemIcon(line.id) end
local function SpellIcon(line)
    if not line.id then return "Interface\\Icons\\INV_Misc_Book_09" end
    local GetTexture = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
    local ok, texture = false, nil
    if GetTexture then ok, texture = pcall(GetTexture, line.id) end
    return (ok and texture) or "Interface\\Icons\\INV_Misc_Book_09"
end
local ICONS = {
    kill = "Interface\\Icons\\INV_Sword_04",
    death = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    level = "Interface\\Icons\\Spell_Holy_HolyBolt",
    zone = "Interface\\Icons\\INV_Misc_Map_01",
    place = "Interface\\Icons\\INV_Misc_Map_01",
    photo = "Interface\\Icons\\INV_Misc_Spyglass_03",
    quest = { atlas = "QuestTurnin", file = "Interface\\GossipFrame\\ActiveQuestIcon" },
    accept = { atlas = "QuestNormal", file = "Interface\\GossipFrame\\AvailableQuestIcon" },
    firstitem = ItemIcon,
    equip = ItemIcon,
    spell = SpellIcon,
    milestone = "Interface\\Icons\\Ability_Warrior_BattleShout",
    fish = "Interface\\Icons\\Trade_Fishing",
    fishskill = "Interface\\Icons\\Trade_Fishing",
    dungeon = "Interface\\Icons\\INV_Misc_Key_03",
    boss = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    rep = "Interface\\Icons\\INV_Scroll_03",
    skill = "Interface\\Icons\\INV_Misc_Book_11",
    guild = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
    duel = "Interface\\Icons\\Ability_Warrior_Challange",
    npc = "Interface\\GossipFrame\\GossipGossipIcon",
    taxi = "Interface\\Minimap\\Tracking\\FlightMaster",
    hearth = "Interface\\Icons\\INV_Misc_Rune_01",
    mount = "Interface\\Icons\\Ability_Mount_RidingHorse",
    transport = "Interface\\Icons\\INV_Misc_Spyglass_02",
    closecall = "Interface\\Icons\\Spell_Holy_AshesToAshes",
    rest = "Interface\\Minimap\\Tracking\\Innkeeper",
    visit = function(line)
        if line.kind == "mail" then return "Interface\\Minimap\\Tracking\\Mailbox" end
        if line.kind == "trainer" then return "Interface\\GossipFrame\\TrainerGossipIcon" end
        return "Interface\\GossipFrame\\VendorGossipIcon"
    end,
    restedgone = "Interface\\Icons\\Spell_Nature_Sleep",
}
-- Kinds drawn as small dots instead of icons, with their colours.
local DOT_COLORS = {
    kill = { 0.90, 0.22, 0.15 }, xp = { 0.65, 0.45, 1.00 },
    herb = { 0.35, 0.85, 0.30 }, ore = { 0.75, 0.75, 0.80 }, skin = { 0.75, 0.50, 0.25 }, fish = { 0.30, 0.60, 1.00 },
}
local DOT_KINDS = { gather = true }
local DOT = 7             -- dot size on screen
local MAX_DOTS = 2500
local COMPRESS_GAP = 180  -- seconds with nothing happening: squeezed on the time bar...
local GAP_W = 6           -- ...to this many pixels
local BUCKETS = 100       -- the activity strip's divisions
local SETTLED = 0.38      -- an icon's alpha once it has had its moment
local JUMP_T = 900        -- a step forward bigger than this (seconds) is a jump: no animation
local FIGHT_PAST = { 1.00, 0.10, 0.10, 1.00 }
local FIGHT_FUTURE = { 1.00, 0.10, 0.10, 0.30 }
-- Tick colours on the time bar.
local TICK = {
    level = { 0.95, 0.75, 0.20 }, death = { 0.10, 0.10, 0.10 }, boss = { 0.85, 0.15, 0.08 },
    quest = { 0.95, 0.85, 0.30 }, firstitem = { 0.40, 0.65, 1.00 }, milestone = { 0.95, 0.75, 0.20 },
}

-- What can be shown, as the "Show" menu lists it: the route, and the kinds of entries in groups.
-- db.settings.journeyHide[group] = true hides one (everything shows to start with).
local GROUPS = {
    { key = "route", label = L["Your route"] },
    { key = "quests", label = L["Quests"], kinds = { quest = true, accept = true } },
    { key = "loot", label = L["Loot and gear"], kinds = { firstitem = true, equip = true } },
    { key = "kills", label = L["Kills and bosses"], kinds = { kill = true, boss = true, dungeon = true } },
    { key = "deaths", label = L["Deaths"], kinds = { death = true } },
    { key = "progress", label = L["Levels and milestones"],
        kinds = { level = true, milestone = true, spell = true, skill = true, rep = true, guild = true, duel = true } },
    { key = "places", label = L["Places"], kinds = { zone = true, place = true } },
    { key = "people", label = L["People"], kinds = { npc = true } },
    { key = "fishing", label = L["Fishing"], kinds = { fish = true, fishskill = true } },
    { key = "photos", label = L["Pictures"], kinds = { photo = true } },
    { key = "allkills", label = L["Every kill"] },
    { key = "gather", label = L["Gathering"], kinds = { gather = true } },
    { key = "travel", label = L["Travel"], kinds = { taxi = true, hearth = true, mount = true, transport = true } },
    { key = "combat", label = L["Combat"], kinds = { closecall = true } },
    { key = "stops", label = L["Stops"], kinds = { rest = true, visit = true } },
    { key = "xp", label = L["XP"], kinds = { restedgone = true }, off = true },
}
local GROUP_OF, DEFAULT_OFF = {}, {}
for _, group in ipairs(GROUPS) do
    for kind in pairs(group.kinds or {}) do GROUP_OF[kind] = group.key end
    if group.off then DEFAULT_OFF[group.key] = true end
end

-- journeyHide[group]: true hidden, false shown, nil its default (most show; "XP" doesn't).
local function Hidden(group)
    local hide = ns.db.settings.journeyHide
    local hidden = hide and hide[group]
    if hidden == nil then return DEFAULT_OFF[group] or false end
    return hidden
end

local function SetHidden(group, hidden)
    local settings = ns.db.settings
    settings.journeyHide = settings.journeyHide or {}
    settings.journeyHide[group] = hidden
end

-- An entry's kind is shown (and has an icon at all).
local function Visible(line)
    local group = GROUP_OF[line.k]
    return group ~= nil and not Hidden(group)
end

local function HasAtlas(name)
    return name and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- The window, the map view in it (clips), and the canvas on the view: map art and everything
-- drawn sit on the canvas, in the map art's own pixels; it is scaled to zoom and moved to pan.
local window, view, canvas

------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------

local state = {
    days = {},        -- day keys with a route or placed entries, oldest first
    index = 0,        -- which of them (0 = all days)
    points = {},      -- flat points { t, x = west, y = north, inst, map, seg }
    times = {},       -- points[i].t, for the binary search
    events = {},      -- { line, key } entries of the range, by time
    t0 = 0, t1 = 0,   -- the range's span
    moment = 0,       -- the moment shown
    playing = false,
    speed = 1,
    whole = true,     -- the whole route drawn (no playback)
    dots = {},        -- { t, pi, py, px, kind, group, id/name/amt/src } every kill and XP gain
    fights = {},      -- { t0, t1 } by time
    xp = {},          -- { t, amt } experience gains, for the time bar's hover numbers
    active = {},      -- every moment something happened (sorted), for squeezing quiet stretches
}
JourneyMap.state = state

-- Days worth showing: a route, or entries that say where they happened.
local function CollectDays()
    local list = {}
    for key, day in pairs(ns.db.days) do
        local any = day.path and #day.path > 0
        if not any then
            for _, line in ipairs(day.events or {}) do
                if line.pi then
                    any = true
                    break
                end
            end
        end
        if any then list[#list + 1] = key end
    end
    table.sort(list)
    state.days = list
end

-- The points of one day (or all of them), with segment numbers unique across days.
local function Load()
    local keys = {}
    if state.index == 0 then
        for _, key in ipairs(state.days) do keys[#keys + 1] = key end
    elseif state.days[state.index] then
        keys[1] = state.days[state.index]
    end
    local points, events, offset = {}, {}, 0
    local dots, fights, gains = {}, {}, {}
    for _, key in ipairs(keys) do
        local day = ns.db.days[key]
        local flat = ns.Journey.Decode(key)
        local top = 0
        for _, point in ipairs(flat) do
            top = math.max(top, point.seg)
            point.seg = point.seg + offset
            points[#points + 1] = point
        end
        offset = offset + top
        for _, line in ipairs(day and day.events or {}) do
            if line.t then events[#events + 1] = { line = line, key = key } end
        end
        if ns.Moments then
            for _, fields in ipairs(ns.Moments.Read(key, "kl")) do
                local ref = fields[5] or ""
                dots[#dots + 1] = { t = fields[1], pi = tonumber(fields[2]), py = tonumber(fields[3]), px = tonumber(fields[4]),
                    kind = "kill", group = "allkills", id = tonumber(ref), name = ref:match("^n(.+)$") }
            end
            for _, fields in ipairs(ns.Moments.Read(key, "xl")) do
                local amount = tonumber(fields[2]) or 0
                dots[#dots + 1] = { t = fields[1], pi = tonumber(fields[4]), py = tonumber(fields[5]), px = tonumber(fields[6]),
                    kind = "xp", group = "xp", amt = amount, src = fields[3] }
                gains[#gains + 1] = { t = fields[1], amt = amount }
            end
            for _, fields in ipairs(ns.Moments.Read(key, "fl")) do
                fights[#fights + 1] = { t0 = fields[1], t1 = fields[2] }
            end
        end
    end
    table.sort(dots, function(first, second) return first.t < second.t end)
    table.sort(fights, function(first, second) return first.t0 < second.t0 end)
    table.sort(gains, function(first, second) return first.t < second.t end)
    state.dots, state.fights, state.xp = dots, fights, gains
    -- A long range is thinned: a point is kept once it's far enough from the last one kept.
    if #points > MAX_POINTS then
        local step = 20
        local kept
        repeat
            kept = {}
            local last
            for i, point in ipairs(points) do
                if not last or point.seg ~= last.seg or i == #points
                    or (point.x - last.x) ^ 2 + (point.y - last.y) ^ 2 >= step * step then
                    kept[#kept + 1] = point
                    last = point
                end
            end
            step = step * 2
        until #kept <= MAX_POINTS or step > 5000
        points = kept
    end
    table.sort(events, function(first, second) return first.line.t < second.line.t end)
    local times = {}
    for i, point in ipairs(points) do times[i] = point.t end
    state.points, state.times, state.events = points, times, events
    -- What you wore when: each level's snapshot, then every change of gear since (day.gc; the log's
    -- upgrades for days before it was kept), all days, so an older snapshot still leads up to now.
    local snaps, equips = {}, {}
    for _, record in pairs(ns.db.levels or {}) do
        if type(record) == "table" and record.snap and record.snap.gear then
            snaps[#snaps + 1] = { t = record.snap.t or record.time or 0, gear = record.snap.gear }
        end
    end
    for _, day in pairs(ns.db.days or {}) do
        if day.gc then
            for when, slot, id in day.gc:gmatch("(%d+),(%d+),(%d+)") do
                equips[#equips + 1] = { t = tonumber(when), slot = tonumber(slot), id = tonumber(id) }
            end
        else
            for _, line in ipairs(day.events or {}) do
                if line.k == "equip" and line.slot and line.id and line.t then equips[#equips + 1] = line end
            end
        end
    end
    table.sort(snaps, function(first, second) return first.t < second.t end)
    table.sort(equips, function(first, second) return first.t < second.t end)
    state.snaps, state.equips = snaps, equips
    local t0, t1 = points[1] and points[1].t, points[#points] and points[#points].t
    if events[1] then
        t0 = math.min(t0 or events[1].line.t, events[1].line.t)
        t1 = math.max(t1 or events[#events].line.t, events[#events].line.t)
    end
    state.t0, state.t1 = t0 or 0, t1 or 0
    if state.t1 <= state.t0 then state.t1 = state.t0 + 1 end
    -- Every moment something happened: route movement, entries, kills, experience.
    local active = {}
    for _, when in ipairs(times) do active[#active + 1] = when end
    for _, logged in ipairs(events) do active[#active + 1] = logged.line.t end
    for _, dot in ipairs(dots) do
        if dot.t >= state.t0 and dot.t <= state.t1 then active[#active + 1] = dot.t end
    end
    for _, fight in ipairs(fights) do
        if fight.t0 >= state.t0 and fight.t1 <= state.t1 then
            active[#active + 1] = fight.t0
            active[#active + 1] = fight.t1
        end
    end
    table.sort(active)
    state.active = active
    state.moment = state.t1
    state.playing, state.whole = false, true
end

-- The last point at or before `when` (0 if none): a binary search.
local function Find(when)
    local times = state.times
    local low, high = 1, #times
    if high == 0 or when < times[1] then return 0 end
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if times[middle] <= when then low = middle else high = middle - 1 end
    end
    return low
end

-- Whether moment `when` falls in a fight.
local function InFight(when)
    local fights = state.fights
    local low, high = 1, #fights
    if high == 0 or when < fights[1].t0 then return false end
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if fights[middle].t0 <= when then low = middle else high = middle - 1 end
    end
    return when <= fights[low].t1 + 2
end

------------------------------------------------------------------------------
-- The time bar's scale: time <-> x, with quiet stretches squeezed
------------------------------------------------------------------------------

-- Knots of a piecewise-linear mapping (times, and pixels from the track's left), and the
-- squeezed stretches { t0, t1, x0, x1 }. Rebuilt with the range or the bar's width.
local knotTimes, knotX, squeezed = {}, {}, {}

local function BuildScale(width)
    knotTimes, knotX, squeezed = {}, {}, {}
    local span = state.t1 - state.t0
    if ns.db.settings.journeyCompress ~= false and width > 0 and span > 0 then
        local active = state.active
        local gaps, quiet = {}, 0
        for i = 2, #active do
            local gap = active[i] - active[i - 1]
            if gap > COMPRESS_GAP then
                gaps[#gaps + 1] = { t0 = active[i - 1], t1 = active[i] }
                quiet = quiet + gap
            end
        end
        local free, busy = width - #gaps * GAP_W, span - quiet
        if #gaps > 0 and free > width * 0.25 and busy > 0 then
            local pixelsPerSecond = free / busy
            local x = 0
            knotTimes[1], knotX[1] = state.t0, 0
            for _, gap in ipairs(gaps) do
                x = x + (gap.t0 - knotTimes[#knotTimes]) * pixelsPerSecond
                knotTimes[#knotTimes + 1], knotX[#knotX + 1] = gap.t0, x
                gap.x0 = x
                x = x + GAP_W
                knotTimes[#knotTimes + 1], knotX[#knotX + 1] = gap.t1, x
                gap.x1 = x
            end
            knotTimes[#knotTimes + 1], knotX[#knotX + 1] = state.t1, width
            squeezed = gaps
        end
    end
    if #knotTimes == 0 then knotTimes, knotX = { state.t0, state.t1 }, { 0, width } end
end

local function Interpolate(from, to, value)
    local count = #from
    if count < 2 then return 0 end
    if value <= from[1] then return to[1] end
    if value >= from[count] then return to[count] end
    local low, high = 1, count
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if from[middle] <= value then low = middle else high = middle - 1 end
    end
    local before, after = from[low], from[low + 1]
    if not after or after == before then return to[low] end
    return to[low] + (to[low + 1] - to[low]) * (value - before) / (after - before)
end

-- Every time <-> x conversion on the time bar goes through these two.
local function TimeToX(when) return Interpolate(knotTimes, knotX, when) end
local function XToTime(x) return Interpolate(knotX, knotTimes, x) end

------------------------------------------------------------------------------
-- Drawing on the map's canvas
------------------------------------------------------------------------------

local portrait -- you, while it plays
local bar, toggle -- the control bar, and the world map's button that opens the window
local holder, marker
local lines, head = {}, nil
local lineEnds = {}    -- per line: the index of the point it ends at
local pointU, pointV = {}, {} -- per point: where it falls on the map shown (0-1), or nil
local icons = {}       -- per placed entry on this map: { frame, t }
local dotFrames = {}   -- per placed dot (every kill, XP, gathering)
local fightLines = {}  -- per line: drawn red (a fight)
local lineCount, iconCount, dotCount = 0, 0, 0
local pastLines        -- lines drawn as "past" last time
local layoutDirty, dirty, scaleDirty = true, true, true

------------------------------------------------------------------------------
-- The map view: zone art, the camera (zoom, pan, follow)
------------------------------------------------------------------------------

-- The camera: the canvas point at the view's middle (canvas pixels), and the zoom (1 = the
-- whole map fits the view). follow: centring on the marker as it moves.
local camera = { x = 0, y = 0, zoom = 1, follow = true }
local mapW, mapH = 1002, 668  -- the shown map's art size (canvas pixels)
local mapID                   -- the map shown
local continent = false       -- showing the parent map (the continent) instead of the zone
local tiles, overlays = {}, {}
local markerU, markerV        -- where the marker was last drawn (0-1), for the camera

local SafeNumber = ns.PlainNumber

local function MapName(id)
    local ok, map = pcall(C_Map.GetMapInfo, id)
    local name = ok and map and map.name
    if type(name) == "string" and not ns.issecret(name) then return name end
    return ""
end

-- The map to show for a point's zone: the zone, or its parent while "Continent" is on.
local function MapFor(id)
    if not id then return end
    if continent then
        local ok, map = pcall(C_Map.GetMapInfo, id)
        local parent = ok and map and SafeNumber(map.parentMapID)
        if parent and parent > 0 then return parent end
    end
    return id
end

local function TakeTexture(pool, index)
    local texture = pool[index]
    if not texture then
        texture = canvas:CreateTexture(nil, "BACKGROUND")
        pool[index] = texture
    end
    return texture
end

-- The art layers of the map shown (C_Map.GetMapArtLayers), and the one whose tiles are laid.
local artLayers, tileLayer

-- The art layer for a zoom: the smallest one at least about as wide as the map is on screen
-- (maps with more than one layer have sharper ones for zooming in, as MapCanvas switches to).
local function PickLayer(scale)
    if not artLayers or #artLayers < 2 then return 1 end
    local onScreen = mapW * scale
    for i, layer in ipairs(artLayers) do
        local layerWidth = SafeNumber(layer.layerWidth)
        if layerWidth and layerWidth >= onScreen * 0.9 then return i end
    end
    return #artLayers
end

-- The tiles of art layer `layerIndex`, stretched over the canvas (which is the first layer's size).
local function LayoutBase(layerIndex)
    local tileCount = 0
    tileLayer = layerIndex
    local layer = artLayers and artLayers[layerIndex]
    local tileW, tileH = layer and SafeNumber(layer.tileWidth), layer and SafeNumber(layer.tileHeight)
    local layerW, layerH = layer and SafeNumber(layer.layerWidth), layer and SafeNumber(layer.layerHeight)
    if tileW and tileH and layerW and layerH and tileW > 0 and tileH > 0 and layerW > 0 and layerH > 0 then
        local stretchX, stretchY = mapW / layerW, mapH / layerH
        local okFiles, files = pcall(C_Map.GetMapArtLayerTextures, mapID, layerIndex)
        if okFiles and type(files) == "table" then
            local columns, rows = math.ceil(layerW / tileW), math.ceil(layerH / tileH)
            for row = 1, rows do
                for column = 1, columns do
                    local file = files[(row - 1) * columns + column]
                    if file then
                        tileCount = tileCount + 1
                        local tile = TakeTexture(tiles, tileCount)
                        tile:SetDrawLayer("BACKGROUND", -7)
                        tile:SetTexture(file, nil, nil, "TRILINEAR")
                        tile:SetTexCoord(0, 1, 0, 1)
                        tile:SetSize(tileW * stretchX, tileH * stretchY)
                        tile:ClearAllPoints()
                        tile:SetPoint("TOPLEFT", canvas, "TOPLEFT", (column - 1) * tileW * stretchX, -(row - 1) * tileH * stretchY)
                        tile:Show()
                    end
                end
            end
        end
    end
    for i = tileCount + 1, #tiles do tiles[i]:Hide() end
    canvas.empty:SetShown(tileCount == 0)
end

-- The map's art: an art layer's tiles in rows (as MapCanvasDetailLayer does), then the explored
-- areas on top (as MapExplorationDataProvider does, minus the mouse-over ones).
local function LayoutTiles()
    local overlayCount = 0
    local width, height = 1002, 668
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    artLayers = ok and type(layers) == "table" and layers or nil
    local layer = artLayers and artLayers[1]
    local tileW, tileH = layer and SafeNumber(layer.tileWidth), layer and SafeNumber(layer.tileHeight)
    if layer and SafeNumber(layer.layerWidth) and layer.layerWidth > 0 and tileW and tileH and tileW > 0 and tileH > 0 then
        width, height = layer.layerWidth, layer.layerHeight
        local okExplored, explored = false, nil
        if C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures then
            okExplored, explored = pcall(C_MapExplorationInfo.GetExploredMapTextures, mapID)
        end
        for _, piece in ipairs(okExplored and type(explored) == "table" and explored or {}) do
            if not piece.isShownByMouseOver and piece.fileDataIDs then
                local wide, tall = math.ceil(piece.textureWidth / tileW), math.ceil(piece.textureHeight / tileH)
                for row = 1, tall do
                    local pixelH, fileH = tileH, tileH
                    if row == tall then
                        pixelH = piece.textureHeight % tileH
                        if pixelH == 0 then pixelH = tileH end
                        fileH = 16
                        while fileH < pixelH do fileH = fileH * 2 end
                    end
                    for column = 1, wide do
                        local pixelW, fileW = tileW, tileW
                        if column == wide then
                            pixelW = piece.textureWidth % tileW
                            if pixelW == 0 then pixelW = tileW end
                            fileW = 16
                            while fileW < pixelW do fileW = fileW * 2 end
                        end
                        local file = piece.fileDataIDs[(row - 1) * wide + column]
                        if file then
                            overlayCount = overlayCount + 1
                            local overlay = TakeTexture(overlays, overlayCount)
                            overlay:SetDrawLayer("BACKGROUND", piece.isDrawOnTopLayer and -5 or -6)
                            overlay:SetTexture(file, nil, nil, "TRILINEAR")
                            overlay:SetSize(pixelW, pixelH)
                            overlay:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                            overlay:ClearAllPoints()
                            overlay:SetPoint("TOPLEFT", canvas, "TOPLEFT", piece.offsetX + tileW * (column - 1),
                                -(piece.offsetY + tileH * (row - 1)))
                            overlay:Show()
                        end
                    end
                end
            end
        end
    end
    for i = overlayCount + 1, #overlays do overlays[i]:Hide() end
    mapW, mapH = width, height
    canvas:SetSize(width, height)
    local viewW, viewH = view:GetWidth(), view:GetHeight()
    local scale = (viewW > 0 and viewH > 0) and math.min(viewW / width, viewH / height) * camera.zoom or 1
    LayoutBase(PickLayer(scale))
end

-- The zoom at which the whole map fits the view, times the camera's zoom.
local function CameraScale()
    local viewW, viewH = view:GetWidth(), view:GetHeight()
    if viewW <= 0 or viewH <= 0 then return 1 end
    return math.max(0.05, math.min(viewW / mapW, viewH / mapH) * camera.zoom)
end

-- Puts the canvas where the camera says (kept inside the map). Cheap: one scale, one anchor.
local function PlaceCanvas()
    if not canvas then return end
    local viewW, viewH = view:GetWidth(), view:GetHeight()
    if viewW <= 0 or viewH <= 0 then return end
    local scale = CameraScale()
    if math.abs(scale - (canvas.s or 0)) > 1e-6 then
        canvas:SetScale(scale)
        canvas.s = scale
        scaleDirty = true
        local layerIndex = PickLayer(scale)
        if layerIndex ~= tileLayer then LayoutBase(layerIndex) end
    end
    local halfW, halfH = viewW / (2 * scale), viewH / (2 * scale)
    if mapW <= 2 * halfW then camera.x = mapW / 2 else camera.x = math.max(halfW, math.min(mapW - halfW, camera.x)) end
    if mapH <= 2 * halfH then camera.y = mapH / 2 else camera.y = math.max(halfH, math.min(mapH - halfH, camera.y)) end
    -- Anchor offsets are in the canvas's own (scaled) units.
    canvas:ClearAllPoints()
    canvas:SetPoint("TOPLEFT", view, "TOPLEFT", halfW - camera.x, -(halfH - camera.y))
end

local UpdateMapButtons -- set once the view's buttons exist

-- Shows another map in the view (nothing happens if it's already shown).
local function SetMap(id)
    if not id or id == mapID or not canvas then return end
    mapID = id
    LayoutTiles()
    layoutDirty = true
    if view.zone then view.zone:SetText(MapName(id)) end
    if UpdateMapButtons then UpdateMapButtons() end
    PlaceCanvas()
end

-- Where a world position falls on a map (0-1), or nil if it isn't on it. A little leeway past
-- the edges so a line leaving the map isn't cut short.
local function ToMap(instance, north, west, onMapID)
    local ok, _, position = pcall(C_Map.GetMapPosFromWorldPos, instance, CreateVector2D(north, west), onMapID)
    if ok and position then return position:GetXY() end
end

local function OnMap(instance, north, west, onMapID)
    if not instance then return end
    local u, v = ToMap(instance, north, west, onMapID)
    if u and v and u > -0.25 and u < 1.25 and v > -0.25 and v < 1.25 then return u, v end
end

local function Strip(text)
    -- Parchment inks read badly on a dark tooltip.
    for _, ink in ipairs({ "7a1f0d", "6b5d4f", "2e1d0c", "1d4f8c", "8a6d4a" }) do
        text = text:gsub("|cff" .. ink, "|cffffd100")
    end
    return text
end

local function TimeLabel(when)
    return date(state.index == 0 and L["%d %b %Y, %H:%M"] or "%H:%M", when)
end

local function ShowEntry(logged, owner, anchor)
    GameTooltip:SetOwner(owner, anchor)
    GameTooltip:SetText(TimeLabel(logged.line.t))
    local line = ns.LogLine and ns.LogLine(logged.line, logged.key)
    if line then GameTooltip:AddLine(Strip(line), 1, 1, 1, true) end
    GameTooltip:AddLine(L["Captain's Log: journey map"], 0.85, 0.75, 0.55)
    GameTooltip:Show()
end

local XP_WORDS = { k = L["+%s experience from a kill."], q = L["+%s experience from a quest."],
    e = L["+%s experience from exploring."] }

local function DotTip(dot, owner)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(TimeLabel(dot.t))
    if dot.kind == "kill" then
        local mob = dot.id and ns.db.mobs[dot.id]
        local name = (mob and mob.name) or dot.name or (dot.id and ns.CreatureName(dot.id)) or L["an unknown creature"]
        GameTooltip:AddLine(L["Killed %s."]:format(name), 1, 1, 1, true)
    else
        local template = XP_WORDS[dot.src] or L["+%s experience."]
        GameTooltip:AddLine(template:format(ns.Number(dot.amt or 0)), 1, 1, 1, true)
    end
    GameTooltip:AddLine(L["Captain's Log: journey map"], 0.85, 0.75, 0.55)
    GameTooltip:Show()
end

local function IconEnter(frame)
    frame.hover = true
    frame:SetAlpha(1)
    if frame.logged then ShowEntry(frame.logged, frame, "ANCHOR_RIGHT")
    elseif frame.dot then DotTip(frame.dot, frame) end
end

local function IconLeave(frame)
    frame.hover = nil
    if not frame.anim then frame:SetAlpha(frame.settle or 1) end
    GameTooltip_Hide()
end

local function SetIconTexture(texture, line)
    local spec = ICONS[line.k]
    texture:SetTexCoord(0, 1, 0, 1)
    if type(spec) == "function" then
        texture:SetTexture(spec(line))
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif type(spec) == "table" then
        if HasAtlas(spec.atlas) then texture:SetAtlas(spec.atlas) else texture:SetTexture(spec.file) end
    else
        texture:SetTexture(spec)
        if spec and spec:find("Icons") then texture:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    end
end

local function EnsureHolder()
    if holder then return end
    holder = CreateFrame("Frame", nil, canvas)
    holder:SetAllPoints()
    head = holder:CreateLine(nil, "OVERLAY", nil, 2)
    head:SetTexture(WHITE)
    marker = CreateFrame("Frame", nil, holder)
    marker.tex = marker:CreateTexture(nil, "OVERLAY", nil, 7)
    marker.tex:SetAllPoints()
    marker.tex:SetTexture("Interface\\Minimap\\MinimapArrow")
end

local function TakeLine(index)
    local line = lines[index]
    if not line then
        line = holder:CreateLine(nil, "OVERLAY", nil, 1)
        line:SetTexture(WHITE)
        lines[index] = line
    end
    return line
end

-- A hover-only marker on the map (clicks and drags go through to the view).
local function MapMarker()
    local frame = CreateFrame("Frame", nil, holder)
    frame.tex = frame:CreateTexture(nil, "OVERLAY")
    frame.tex:SetAllPoints()
    pcall(frame.SetMouseMotionEnabled, frame, true)
    pcall(frame.SetMouseClickEnabled, frame, false)
    frame:SetScript("OnEnter", IconEnter)
    frame:SetScript("OnLeave", IconLeave)
    return frame
end

local function TakeIcon(index)
    local frame = icons[index]
    if not frame then
        frame = MapMarker()
        frame.settle = SETTLED
        icons[index] = frame
    end
    return frame
end

local function TakeDot(index)
    local frame = dotFrames[index]
    if not frame then
        frame = MapMarker()
        frame.tex:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        frame.settle, frame.isDot = 0.85, true
        dotFrames[index] = frame
    end
    return frame
end

------------------------------------------------------------------------------
-- Things happening: icons pop in as the marker reaches them, and the log down the side
------------------------------------------------------------------------------

local anims = {} -- { frame, start, dot }

local function Plain(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", "")
    text = text:gsub("[%.!]$", "")
    if #text > 110 then
        text = text:sub(1, 108):gsub("[\192-\255][\128-\191]*$", "") .. "..."
    end
    return text
end

-- A few words for what an entry is: "Quest done: The Hills Have Eyes", "Level 11".
local function NoteText(logged)
    local line = logged.line
    if line.k == "quest" and line.title then return Plain(L["Quest done: %s"]:format(line.title)) end
    if line.k == "accept" and line.title then return Plain(L["Quest taken: %s"]:format(line.title)) end
    if line.k == "level" then return L["Level %d"]:format(line.level or 0) end
    if line.k == "death" then
        return line.killer and Plain(L["Died to %s"]:format(line.killer)) or L["Died"]
    end
    if line.k == "kill" then
        local mob = ns.db.mobs[line.id]
        local name = line.name or (mob and mob.name) or L["an unknown creature"]
        if (line.n or 1) > 1 then return Plain(L["Slew %s x%d"]:format(name, line.n)) end
        return Plain(L["Slew %s"]:format(name))
    end
    local sentence = ns.LogLine and ns.LogLine(line, logged.key)
    return sentence and Plain(sentence) or nil
end

-- The big moments hold the playback a moment so there's time to read them.
local BIG = { level = true, quest = true, death = true, boss = true, firstitem = true, closecall = true,
    dungeon = true, milestone = true }

-- The log down the side: every shown entry up to the moment shown, oldest at the top, at most MAX_ROWS.
-- Rows are pooled and chained; only the end changes as the moment moves, and a jump builds it again.
local MAX_ROWS = 250
local ROW_GAP = 2
local side, logScroll, logChild         -- the column, its scroll frame and the scrolled content
local logList = {}                      -- the entries the log can show (in the Show menu), by time
local logRows, rowPool = {}, {}         -- rows shown, in order; spare rows
local logFirst, logLast = 1, 0          -- the logList indexes shown
local logHeight = 0                     -- the content's height
local logStick = true                   -- following the bottom (not scrolled up by hand)
local logDirty = true
local JumpTo                            -- set further down: clicking a row jumps there

local function LogOn() return ns.db.settings.journeyNotes ~= false end

local function LogMax()
    return math.max(0, logHeight - logScroll:GetHeight())
end

local function LogToBottom()
    if logStick then logScroll:SetVerticalScroll(LogMax()) end
end

local function RowEnter(row)
    row.highlight:Show()
    if row.logged then ShowEntry(row.logged, row, "ANCHOR_RIGHT") end
end

local function RowLeave(row)
    row.highlight:Hide()
    GameTooltip_Hide()
end

local function RowClick(row)
    if row.logged and JumpTo then JumpTo(row.logged.line.t) end
end

-- A fade in to `peak` and back out, on `region`'s alpha.
local function Flash(region, peak, rise, fall)
    local group = region:CreateAnimationGroup()
    if group.SetToFinalAlpha then group:SetToFinalAlpha(true) end
    local up = group:CreateAnimation("Alpha")
    up:SetFromAlpha(0) up:SetToAlpha(peak) up:SetDuration(rise) up:SetOrder(1)
    local down = group:CreateAnimation("Alpha")
    down:SetFromAlpha(peak) down:SetToAlpha(0) down:SetDuration(fall) down:SetOrder(2)
    group:SetScript("OnFinished", function() region:SetAlpha(0) end)
    return group
end

local function NewRow()
    local row = table.remove(rowPool)
    if row then return row end
    row = CreateFrame("Button", nil, logChild)
    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local font = row.time:GetFont()
    if font then row.time:SetFont(font, 9, "") end
    row.time:SetTextColor(0.75, 0.68, 0.55, 0.7)
    row.time:SetPoint("TOPLEFT", 2, -3)
    row.time:SetWidth(30)
    row.time:SetJustifyH("LEFT")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("TOPLEFT", 34, -1)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 4, -1)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    if row.text.SetMaxLines then row.text:SetMaxLines(2) end
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 0.85, 0.5, 0.12)
    row.highlight:Hide()
    -- The newest line's flash.
    row.flash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.flash:SetAllPoints()
    row.flash:SetColorTexture(1, 0.8, 0.3, 1)
    row.flash:SetAlpha(0)
    row.flashAnim = Flash(row.flash, 0.35, 0.15, 1.2)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", RowLeave)
    row:SetScript("OnClick", RowClick)
    return row
end

local function FreeRow(row)
    row:Hide()
    row:ClearAllPoints()
    row.logged = nil
    row.flashAnim:Stop()
    row.flash:SetAlpha(0)
    rowPool[#rowPool + 1] = row
end

local function AnchorFirst()
    local row = logRows[1]
    if row then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", logChild, "TOPLEFT", 0, 0)
        row:SetPoint("RIGHT", logChild, "RIGHT")
    end
end

local function SetLogHeight()
    logChild:SetHeight(math.max(1, logHeight))
end

-- Adds logList[index] at the bottom.
local function PushRow(index, flash)
    local logged = logList[index]
    local row = NewRow()
    row.logged = logged
    row.time:SetText(date("%H:%M", logged.line.t))
    row.text:SetWidth(math.max(60, logChild:GetWidth() - 58))
    SetIconTexture(row.icon, logged.line)
    row.text:SetText(NoteText(logged) or "")
    local height = math.max(18, math.ceil(row.text:GetStringHeight() or 12) + 4)
    row:SetHeight(height)
    row.h = height
    row:ClearAllPoints()
    local previous = logRows[#logRows]
    if previous then
        row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -ROW_GAP)
        row:SetPoint("RIGHT", logChild, "RIGHT")
    end
    logRows[#logRows + 1] = row
    if not previous then AnchorFirst() end
    row:Show()
    logHeight = logHeight + height + (previous and ROW_GAP or 0)
    logLast = index
    if #logRows > MAX_ROWS then
        local first = table.remove(logRows, 1)
        logHeight = logHeight - first.h - ROW_GAP
        FreeRow(first)
        logFirst = logFirst + 1
        AnchorFirst()
    end
    if flash then
        row.flashAnim:Stop()
        row.flashAnim:Play()
    end
end

local function PopRow()
    local row = table.remove(logRows)
    if not row then return end
    logHeight = logHeight - row.h - (#logRows > 0 and ROW_GAP or 0)
    FreeRow(row)
    logLast = logLast - 1
end

local function ClearLog()
    for i = #logRows, 1, -1 do FreeRow(logRows[i]) end
    wipe(logRows)
    logHeight, logFirst, logLast = 0, 1, 0
end

-- How many logList entries happened at or before `when`.
local function LogCount(when)
    local low, high = 0, #logList
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if logList[middle].line.t <= when then low = middle else high = middle - 1 end
    end
    return low
end

-- Brings the log up to the moment shown. forward: playing (or dragging) on; the newest lines then
-- flash, and a big one holds the playback.
local function SyncLog(forward)
    if not logChild or not LogOn() then return end
    if logDirty then
        logDirty = false
        wipe(logList)
        for _, logged in ipairs(state.events) do
            -- Kills stay on the map but not in the list (there are too many of them to read).
            local line = logged.line
            if ICONS[line.k] and Visible(line) and line.k ~= "kill" then logList[#logList + 1] = logged end
        end
        ClearLog()
    end
    local want = state.whole and #logList or LogCount(state.moment)
    if want == logLast then return end
    if want < logLast and want >= logFirst then
        while logLast > want do PopRow() end
    elseif want > logLast and want - logLast <= 20 and logLast >= logFirst - 1 then
        for i = logLast + 1, want do
            PushRow(i, forward and i == want)
            local kind = logList[i].line.k
            if forward and BIG[kind] and state.playing and ns.db.settings.journeyHold ~= false then
                state.holdUntil = GetTime() + 1.8
            end
        end
    else
        -- A jump: built again from the moment shown.
        ClearLog()
        local from = math.max(1, want - MAX_ROWS + 1)
        logFirst, logLast = from, from - 1
        for i = from, want do PushRow(i, false) end
    end
    SetLogHeight()
    LogToBottom()
end

-- The column: shown with "Log down the side" on; your portrait at its top while it shows.
local function PlaceSide()
    if not side then return end
    local on = LogOn()
    side:SetShown(on)
    view:ClearAllPoints()
    view:SetPoint("BOTTOMRIGHT", -12, 82)
    if on then
        view:SetPoint("TOPLEFT", side, "TOPRIGHT", 6, 0)
    else
        view:SetPoint("TOPLEFT", 12, -34)
    end
    local portraitShown = portrait and portrait:IsShown()
    if portrait then
        portrait:ClearAllPoints()
        if on then
            portrait:SetPoint("TOPLEFT", side, "TOPLEFT", 0, 0)
        else
            portrait:SetPoint("TOPLEFT", view, "TOPLEFT", 8, -8)
        end
    end
    logScroll:ClearAllPoints()
    logScroll:SetPoint("TOPLEFT", side, "TOPLEFT", 4, (on and portraitShown) and -(PORTRAIT_H + 8) or -4)
    logScroll:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -4, 4)
end

local function BuildSide()
    side = CreateFrame("Frame", nil, window)
    side:SetPoint("TOPLEFT", 12, -34)
    side:SetPoint("BOTTOMLEFT", 12, 82)
    side:SetWidth(PORTRAIT_W)
    local background = side:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.06, 0.05, 0.04, 0.9)
    logScroll = CreateFrame("ScrollFrame", nil, side)
    logScroll:EnableMouseWheel(true)
    logChild = CreateFrame("Frame", nil, logScroll)
    logChild:SetSize(PORTRAIT_W - 8, 1)
    logScroll:SetScrollChild(logChild)
    logScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = LogMax()
        local position = math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * 40))
        self:SetVerticalScroll(position)
        logStick = position >= maxScroll - 2 -- back at the bottom: following it again
    end)
    logScroll:SetScript("OnSizeChanged", function(_, width)
        if width and width > 0 then logChild:SetWidth(width) end
        LogToBottom()
    end)
end

local function Pop(frame, isDot)
    if not frame.anim then
        frame.anim = true
        anims[#anims + 1] = { frame = frame, start = GetTime(), dot = isDot }
    end
end

local function EndAnim(frame)
    frame.anim = nil
    frame:SetSize(frame.base or ICON, frame.base or ICON)
    frame:SetAlpha(frame.hover and 1 or frame.settle)
end

local function StopAll()
    for _, anim in ipairs(anims) do EndAnim(anim.frame) end
    wipe(anims)
end
JourneyMap.StopAnimations = StopAll

-- Every frame while the window is open (cheap: only what's moving).
local function Animate()
    if #anims == 0 then return end
    local now = GetTime()
    for i = #anims, 1, -1 do
        local anim = anims[i]
        local frame, age = anim.frame, now - anim.start
        local grow, alpha, done
        if anim.dot then
            grow = age < 0.15 and 0.4 + 0.9 * age / 0.15 or (age < 0.25 and 1.3 - 0.3 * (age - 0.15) / 0.1 or 1)
            alpha = age < 0.15 and age / 0.15 or 1
            done = age >= 0.25
        else
            grow = age < 0.2 and 0.4 + 0.75 * age / 0.2 or (age < 0.3 and 1.15 - 0.15 * (age - 0.2) / 0.1 or 1)
            if age < 0.15 then alpha = age / 0.15
            elseif age < 2.8 then alpha = 1
            else alpha = 1 - (1 - SETTLED) * math.min(1, (age - 2.8) / 0.5) end
            done = age >= 3.3
        end
        if done then
            EndAnim(frame)
            table.remove(anims, i)
        else
            local size = (frame.base or ICON) * grow
            frame:SetSize(size, size)
            frame:SetAlpha(frame.hover and 1 or alpha)
        end
    end
end

-- Sizes that stay the same on screen whatever the zoom: line widths, icons, dots, the marker.
-- Runs when the zoom changes; nothing moves.
local function ApplyScale()
    scaleDirty = false
    if not holder then return end
    local scale = canvas.s or 1
    if scale <= 0 then scale = 1 end
    for i = 1, lineCount do lines[i]:SetThickness(WIDTH / scale) end
    head:SetThickness(WIDTH / scale)
    for i = 1, iconCount do
        local frame = icons[i]
        frame.base = ICON / scale
        if not frame.anim then frame:SetSize(frame.base, frame.base) end
    end
    for i = 1, dotCount do
        local frame = dotFrames[i]
        frame.base = DOT / scale
        if not frame.anim then frame:SetSize(frame.base, frame.base) end
    end
    marker:SetSize(22 / scale, 22 / scale)
end

-- Places every piece of the route and every entry on the map being shown. Runs when the map or
-- the range changes (positions are in the canvas's own pixels, so zooming doesn't need it).
local function Layout()
    layoutDirty = false
    pastLines = nil
    if not canvas then return end
    EnsureHolder()
    holder:SetFrameLevel(canvas:GetFrameLevel() + 2)
    marker:SetFrameLevel(holder:GetFrameLevel() + 20)
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local scale = canvas.s or 1
    if scale <= 0 then scale = 1 end
    StopAll()
    local points = state.points
    local fightsShown = not Hidden("combat")
    wipe(pointU)
    wipe(pointV)
    -- Each point placed by asking the game where it falls on this map: a map's own instance can't be
    -- worked out for every map (Forever's new zones), and a point's continent decides it anyway.
    if width > 0 and mapID and not Hidden("route") then
        for i, point in ipairs(points) do
            local u, v = OnMap(point.inst, point.y, point.x, mapID)
            if u then pointU[i], pointV[i] = u, v end
        end
    end
    local placedLines = 0
    for i = 1, #points - 1 do
        if pointU[i] and pointU[i + 1] and points[i].seg == points[i + 1].seg then
            placedLines = placedLines + 1
            local line = TakeLine(placedLines)
            line:SetThickness(WIDTH / scale)
            line:SetStartPoint("TOPLEFT", canvas, pointU[i] * width, -pointV[i] * height)
            line:SetEndPoint("TOPLEFT", canvas, pointU[i + 1] * width, -pointV[i + 1] * height)
            line:Show()
            lineEnds[placedLines] = i + 1
            fightLines[placedLines] = fightsShown and InFight(points[i + 1].t) or nil
        end
    end
    for i = placedLines + 1, #lines do lines[i]:Hide() end
    lineCount = placedLines
    head:SetThickness(WIDTH / scale)

    -- Entries that say where they happened, on this continent.
    local placedIcons, placedDots = 0, 0
    local dotSize = DOT / scale
    local function PlaceDot(u, v, when, color)
        placedDots = placedDots + 1
        local frame = TakeDot(placedDots)
        frame.t, frame.on, frame.base = when, nil, dotSize
        frame.tex:SetVertexColor(color[1], color[2], color[3], 1)
        frame:SetSize(dotSize, dotSize)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", canvas, "TOPLEFT", u * width, -v * height)
        frame:SetFrameLevel(holder:GetFrameLevel() + 6)
        return frame
    end
    if width > 0 and mapID then
        for _, logged in ipairs(state.events) do
            local line = logged.line
            if DOT_KINDS[line.k] then
                if line.pi and line.py and line.px and placedDots < MAX_DOTS and Visible(line) then
                    local u, v = OnMap(line.pi, line.py, line.px, mapID)
                    if u then
                        local frame = PlaceDot(u, v, line.t, DOT_COLORS[line.what] or DOT_COLORS.herb)
                        frame.logged, frame.dot = logged, nil
                    end
                end
            elseif line.pi and line.py and line.px and ICONS[line.k] and Visible(line) then
                local u, v = OnMap(line.pi, line.py, line.px, mapID)
                if u then
                    placedIcons = placedIcons + 1
                    local frame = TakeIcon(placedIcons)
                    frame.logged, frame.t, frame.on, frame.base = logged, line.t, nil, ICON / scale
                    SetIconTexture(frame.tex, line)
                    frame:SetSize(ICON / scale, ICON / scale)
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", canvas, "TOPLEFT", u * width, -v * height)
                    frame:SetFrameLevel(holder:GetFrameLevel() + 10)
                end
            end
        end
    end
    -- Every kill and experience gain, as dots.
    if width > 0 and mapID then
        for _, dot in ipairs(state.dots) do
            if placedDots >= MAX_DOTS then break end
            if dot.pi and dot.py and dot.px and not Hidden(dot.group) then
                local u, v = OnMap(dot.pi, dot.py, dot.px, mapID)
                if u then
                    local frame = PlaceDot(u, v, dot.t, DOT_COLORS[dot.kind])
                    frame.logged, frame.dot = nil, dot
                end
            end
        end
    end
    for i = placedIcons + 1, #icons do
        icons[i]:Hide()
        icons[i].logged = nil
    end
    for i = placedDots + 1, #dotFrames do
        dotFrames[i]:Hide()
        dotFrames[i].logged, dotFrames[i].dot = nil, nil
    end
    iconCount, dotCount = placedIcons, placedDots
    marker:SetSize(22 / scale, 22 / scale)
    dirty = true
end

-- The number of route pieces that end at or before point `index`.
local function LinesUpTo(index)
    local low, high = 0, lineCount
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if lineEnds[middle] <= index then low = middle else high = middle - 1 end
    end
    return low
end

local function Paint(line, color) line:SetVertexColor(color[1], color[2], color[3], color[4]) end

-- Where you were at `when` on the map shown: u, v, the next point (heading) or nil, and the point.
local function Position(when)
    local index = Find(when)
    local points = state.points
    if index == 0 then
        if pointU[1] then return pointU[1], pointV[1], nil, 0 end
        return nil, nil, nil, 0
    end
    if not pointU[index] then return nil, nil, nil, index end
    local nextIndex = index + 1
    if points[nextIndex] and pointU[nextIndex] and points[nextIndex].seg == points[index].seg
        and points[nextIndex].t > points[index].t then
        local share = math.max(0, math.min(1, (when - points[index].t) / (points[nextIndex].t - points[index].t)))
        return pointU[index] + (pointU[nextIndex] - pointU[index]) * share,
            pointV[index] + (pointV[nextIndex] - pointV[index]) * share, nextIndex, index
    end
    return pointU[index], pointV[index], nil, index
end

-- Following: the view shows the zone map of the moment shown, so the camera goes with you from
-- zone to zone (or continent to continent, with "Continent" on). Only while following.
local function Follow()
    if not camera.follow then return end
    local point = state.points[math.max(1, Find(state.moment))]
    if not point or not point.map then return end
    local want = MapFor(point.map)
    if want and want ~= mapID then
        SetMap(want)
        camera.snap = true -- straight to the marker on the new map, no glide across it
    end
end

-- The camera glides after the marker while following.
local function MoveCamera(seconds)
    if not camera.follow or not markerU then return end
    local targetX, targetY = markerU * mapW, markerV * mapH
    if camera.snap then
        camera.x, camera.y, camera.snap = targetX, targetY, nil
    else
        local glide = math.min(1, seconds * 5)
        camera.x, camera.y = camera.x + (targetX - camera.x) * glide, camera.y + (targetY - camera.y) * glide
    end
    PlaceCanvas()
end

-- Your gear at `when`: the latest snapshot before it (or the first one there is), with the
-- upgrades equipped between then and `when` on top. Returns the gear and a signature of it.
local function GearAt(when)
    local base
    for _, snap in ipairs(state.snaps or {}) do
        if snap.t <= when or not base then base = snap else break end
    end
    if not base then return nil end
    local gear = {}
    for slot, id in pairs(base.gear) do gear[slot] = id end
    for _, change in ipairs(state.equips or {}) do
        if change.t > when then break end
        if change.t > base.t then gear[change.slot] = change.id ~= 0 and change.id or nil end
    end
    local signature = {}
    for slot = 1, 19 do signature[#signature + 1] = tostring(gear[slot] or 0) end
    return gear, table.concat(signature, ",")
end

-- You, in a portrait while the journey plays, in the gear you had on then, your level under it; a
-- level up passed playing forward plays the fanfare and a golden burst, and changes into its gear.
local LEVEL_SOUND = 888    -- the game's level-up fanfare
local lastMoment

local function LevelAt(when)
    local best
    for level, record in pairs(ns.db.levels or {}) do
        if type(record) == "table" and record.time and record.time <= when and (not best or level > best) then best = level end
    end
    return best
end

local function EnsurePortrait()
    if portrait or not bar then return portrait end
    local box = CreateFrame("Frame", nil, window, "BackdropTemplate")
    box:SetSize(PORTRAIT_W, PORTRAIT_H)
    box:SetPoint("TOPLEFT", view, "TOPLEFT", 8, -8) -- PlaceSide moves it into the column
    box:SetFrameLevel(view:GetFrameLevel() + 50)
    box:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    box:SetBackdropColor(0.06, 0.05, 0.04, 0.85)
    box:SetBackdropBorderColor(0.75, 0.62, 0.38, 1)
    local ok, model = pcall(CreateFrame, "DressUpModel", nil, box)
    if not ok or not model then return nil end
    model:SetPoint("TOPLEFT", 6, -6)
    model:SetPoint("BOTTOMRIGHT", -6, 22)
    model:SetScript("OnModelLoaded", function(self)
        pcall(self.SetFacing, self, 0.35)
        box.gearSig = nil -- dressed again once it's there
    end)
    box.model = model
    box.label = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.label:SetPoint("BOTTOM", 0, 7)
    -- The gold flash on a level up.
    box.glow = box:CreateTexture(nil, "OVERLAY")
    box.glow:SetPoint("TOPLEFT", 4, -4)
    box.glow:SetPoint("BOTTOMRIGHT", -4, 4)
    box.glow:SetTexture(WHITE)
    box.glow:SetBlendMode("ADD")
    box.glow:SetVertexColor(1, 0.8, 0.3)
    box.glow:SetAlpha(0)
    box.flash = Flash(box.glow, 0.22, 0.25, 1.4)
    -- The level-up glow: a soft gold sparkle behind you that swells and fades (the game's own
    -- effect can't be given to a model). It ends hidden, whatever happens to the animation.
    local sparkle = box:CreateTexture(nil, "BACKGROUND", nil, 3)
    sparkle:SetPoint("CENTER", model, "CENTER", 0, -10)
    sparkle:SetSize(150, 150)
    sparkle:SetTexture("Interface\\Cooldown\\star4")
    sparkle:SetBlendMode("ADD")
    sparkle:SetVertexColor(1, 0.78, 0.25)
    sparkle:SetAlpha(0)
    local burst = Flash(sparkle, 0.9, 0.35, 1.2)
    local swell = burst:CreateAnimation("Scale")
    swell:SetScaleFrom(0.5, 0.5) swell:SetScaleTo(1.4, 1.4) swell:SetDuration(1.8) swell:SetOrder(1)
    box.burst = burst
    box:Hide()
    portrait = box
    return box
end

local function Celebrate(box)
    pcall(PlaySound, LEVEL_SOUND, "Master")
    for _, animation in ipairs({ box.flash, box.burst }) do
        animation:Stop()
        animation:Play()
    end
end

local function UpdatePortrait()
    local box = EnsurePortrait()
    if not box then return end
    if Hidden("hero") or state.whole or #state.points == 0 and #state.events == 0 then
        if box:IsShown() then
            box:Hide()
            PlaceSide()
        end
        lastMoment = nil
        return
    end
    if not box:IsShown() then
        box:Show()
        PlaceSide()
        pcall(box.model.SetUnit, box.model, "player")
        box.gearSig = nil
    end
    local gear, signature = GearAt(state.moment)
    if gear and signature ~= box.gearSig then
        box.gearSig = signature
        pcall(box.model.Undress, box.model)
        for slot, id in pairs(gear) do
            if slot ~= 0 and type(id) == "number" then pcall(box.model.TryOn, box.model, "item:" .. id) end
        end
    end
    local level = LevelAt(state.moment)
    box.label:SetText(level and L["Level %d"]:format(level) or "")
    -- A level up passed while playing forward.
    if state.playing and lastMoment and state.moment > lastMoment then
        for _, logged in ipairs(state.events) do
            local line = logged.line
            if line.k == "level" and line.t > lastMoment and line.t <= state.moment then
                Celebrate(box)
                break
            end
        end
    end
    lastMoment = state.moment
end

local previousMoment -- the moment shown at the last draw
local function Draw()
    dirty = false
    Follow()
    if layoutDirty then Layout() end
    if not holder then return end
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    local index = Find(state.moment)
    local past = state.whole and lineCount or LinesUpTo(index)
    -- Only the pieces whose side of "now" changed are recoloured.
    local function ColorOf(line, isPast)
        if fightLines[line] then return isPast and FIGHT_PAST or FIGHT_FUTURE end
        return isPast and PAST or FUTURE
    end
    if not pastLines then
        for i = 1, lineCount do Paint(lines[i], ColorOf(i, i <= past)) end
    elseif past > pastLines then
        for i = pastLines + 1, past do Paint(lines[i], ColorOf(i, true)) end
    elseif past < pastLines then
        for i = past + 1, pastLines do Paint(lines[i], ColorOf(i, false)) end
    end
    pastLines = past

    local u, v, nextIndex, at = Position(state.moment)
    if state.whole or Hidden("route") then u = nil end
    markerU, markerV = u, v
    if u then
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", canvas, "TOPLEFT", u * width, -v * height)
        marker:Show()
        -- The piece being walked, drawn up to the marker.
        if nextIndex and pointU[at] then
            head:SetStartPoint("TOPLEFT", canvas, pointU[at] * width, -pointV[at] * height)
            head:SetEndPoint("TOPLEFT", canvas, u * width, -v * height)
            Paint(head, PAST)
            head:Show()
            local dx, dy = (pointU[nextIndex] - pointU[at]) * width, (pointV[nextIndex] - pointV[at]) * height
            if dx ~= 0 or dy ~= 0 then marker.tex:SetRotation(-math.atan2(dx, -dy)) end
        else
            head:Hide()
        end
    else
        marker:Hide()
        head:Hide()
    end

    -- Only things crossing "now" going forward, while playing or scrubbing, have their moment;
    -- jumps, going back and the whole route show everything settled.
    local forward = not state.whole and (state.playing or state.dragging) and previousMoment
        and state.moment > previousMoment and state.moment - previousMoment <= JUMP_T
    if previousMoment and (state.moment < previousMoment or state.whole) then StopAll() end
    local function Turn(frame, isDot)
        local on = state.whole or frame.t <= state.moment
        if on == frame.on then return end
        frame.on = on
        if on and forward and frame.t > previousMoment then
            frame:SetAlpha(0)
            Pop(frame, isDot)
        else
            if frame.anim then EndAnim(frame) end
            frame:SetAlpha(frame.hover and 1 or frame.settle)
        end
        frame:SetShown(on)
    end
    for i = 1, iconCount do Turn(icons[i], false) end
    for i = 1, dotCount do Turn(dotFrames[i], true) end
    previousMoment = state.moment
    UpdatePortrait()
    SyncLog(forward)
end

------------------------------------------------------------------------------
-- The control bar
------------------------------------------------------------------------------

local function SpanText(when)
    if state.index == 0 then return date(L["%d %b, %H:%M"], when) end
    return date("%H:%M", when)
end

local function DayLabel()
    if state.index == 0 then return L["All days"] end
    local key = state.days[state.index]
    return key and date(L["%a %d %b %Y"], ns.DayTime(key)) or ""
end

local function UpdateTicks()
    local track = bar.track
    local width = track:GetWidth()
    local ticks = bar.ticks
    local tickCount = 0
    local shown = {}
    for _, logged in ipairs(state.events) do
        if Visible(logged.line) then shown[#shown + 1] = logged end
    end
    BuildScale(width)
    local hit = track:GetParent()
    local step = math.max(1, math.ceil(#shown / MAX_TICKS))
    local span = state.t1 - state.t0
    local labelCount = 0
    local labels = bar.levelLabels
    if width > 0 and span > 0 then
        for i = 1, #shown do
            local line = shown[i].line
            local isLevel = line.k == "level"
            -- Level ups always get their mark; the rest are thinned to MAX_TICKS.
            if isLevel or (i - 1) % step == 0 then
                tickCount = tickCount + 1
                local tick = ticks[tickCount]
                if not tick then
                    tick = hit:CreateTexture(nil, "ARTWORK", nil, 2) -- on the track's frame (a texture can't hold textures)
                    ticks[tickCount] = tick
                end
                local color = TICK[line.k] or { 0.9, 0.82, 0.62 }
                local big = TICK[line.k] ~= nil
                local x = TimeToX(line.t)
                tick:SetColorTexture(color[1], color[2], color[3], big and 1 or 0.55)
                tick:SetWidth(isLevel and 2 or 1)
                tick:SetHeight(isLevel and 20 or (big and 14 or 8))
                tick:ClearAllPoints()
                tick:SetPoint("CENTER", track, "LEFT", x, 0)
                tick:Show()
                if isLevel then
                    labelCount = labelCount + 1
                    local label = labels[labelCount]
                    if not label then
                        label = hit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        local font = label:GetFont()
                        if font then label:SetFont(font, 9, "OUTLINE") end
                        label:SetTextColor(1, 0.82, 0.25)
                        labels[labelCount] = label
                    end
                    label:SetText(line.level or "")
                    label:ClearAllPoints()
                    label:SetPoint("BOTTOM", track, "LEFT", x, 10)
                    label:Show()
                end
            end
        end
    end
    for i = tickCount + 1, #ticks do ticks[i]:Hide() end
    for i = labelCount + 1, #labels do labels[i]:Hide() end

    -- Squeezed quiet stretches: the track broken, with two slanted strokes.
    local breaks = bar.breaks
    for i, gap in ipairs(squeezed) do
        local mark = breaks[i]
        if not mark then
            mark = { mask = hit:CreateTexture(nil, "ARTWORK", nil, 3),
                left = hit:CreateLine(nil, "OVERLAY"), right = hit:CreateLine(nil, "OVERLAY") }
            mark.mask:SetColorTexture(0.10, 0.06, 0.03, 1)
            for _, stroke in ipairs({ mark.left, mark.right }) do
                stroke:SetColorTexture(0.9, 0.82, 0.62, 0.9)
                stroke:SetThickness(1)
            end
            breaks[i] = mark
        end
        mark.mask:ClearAllPoints()
        mark.mask:SetPoint("LEFT", track, "LEFT", gap.x0 + 1, 0)
        mark.mask:SetSize(math.max(1, gap.x1 - gap.x0 - 2), 8)
        mark.left:SetStartPoint("LEFT", track, gap.x0, -5)
        mark.left:SetEndPoint("LEFT", track, gap.x0 + 2, 5)
        mark.right:SetStartPoint("LEFT", track, gap.x1 - 2, -5)
        mark.right:SetEndPoint("LEFT", track, gap.x1, 5)
        mark.mask:Show() mark.left:Show() mark.right:Show()
    end
    for i = #squeezed + 1, #breaks do
        breaks[i].mask:Hide() breaks[i].left:Hide() breaks[i].right:Hide()
    end

    -- The activity strip: how much happened along the bar.
    local counts, top = {}, 0
    if width > 0 then
        local function Add(when)
            local bucket = math.floor(TimeToX(when) / width * BUCKETS) + 1
            bucket = math.max(1, math.min(BUCKETS, bucket))
            counts[bucket] = (counts[bucket] or 0) + 1
            if counts[bucket] > top then top = counts[bucket] end
        end
        for _, logged in ipairs(state.events) do Add(logged.line.t) end
        for _, dot in ipairs(state.dots) do
            if dot.t >= state.t0 and dot.t <= state.t1 then Add(dot.t) end
        end
    end
    local strip = bar.strip
    for i = 1, BUCKETS do
        local piece = strip[i]
        if not piece then
            piece = hit:CreateTexture(nil, "ARTWORK")
            strip[i] = piece
        end
        local count = counts[i] or 0
        piece:ClearAllPoints()
        piece:SetPoint("TOPLEFT", track, "BOTTOMLEFT", (i - 1) / BUCKETS * width, -2)
        piece:SetSize(math.max(1, width / BUCKETS), 3)
        piece:SetColorTexture(1, 0.75, 0.3, top > 0 and (0.06 + 0.8 * count / top) or 0.06)
        piece:SetShown(width > 0)
    end
end

local function UpdateBar()
    if not bar then return end
    bar.day:SetText(DayLabel())
    bar.play:SetText(state.playing and L["Pause"] or L["Play"])
    bar.speed:SetText(SPEEDS[state.speed][2])
    bar.whole:SetEnabled(not state.whole or state.playing)
    local width = bar.track:GetWidth()
    local x = math.max(0, math.min(width, TimeToX(state.moment)))
    bar.fill:SetWidth(math.max(0.01, x))
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("CENTER", bar.track, "LEFT", x, 0)
    if #state.points == 0 and #state.events == 0 then
        bar.time:SetText(L["Nothing"])
    else
        bar.time:SetText(SpanText(state.moment))
    end
end

local function SetMoment(when)
    state.moment = math.max(state.t0, math.min(state.t1, when))
    dirty = true
    UpdateBar()
end

-- The whole route: the camera stops following and shows all of the map where the range ends.
local function Overview()
    camera.follow, camera.zoom = false, 1
    local point = state.points[#state.points]
    if point and point.map then
        SetMap(MapFor(point.map))
    elseif not mapID then
        local ok, here = pcall(C_Map.GetBestMapForUnit, "player")
        SetMap(ok and SafeNumber(here) or 1415)
    end
    PlaceCanvas()
    if UpdateMapButtons then UpdateMapButtons() end
end

-- Following: zoomed in on the marker (as far as last time), which the camera then keeps centred.
local function StartFollow()
    camera.follow, camera.snap = true, true
    camera.zoom = ns.db.settings.journeyZoom or FOLLOW_ZOOM
    Follow()
    PlaceCanvas()
    dirty = true
    if UpdateMapButtons then UpdateMapButtons() end
end

-- Clicking a line in the log: that moment, followed.
JumpTo = function(when)
    state.whole = false
    pastLines = nil
    SetMoment(when)
    StartFollow()
end

local function SelectDay(index)
    state.index = index
    Load()
    layoutDirty, logDirty = true, true
    Overview()
    if bar then
        UpdateTicks()
        UpdateBar()
    end
end

local function Step(delta)
    local days = #state.days
    local index = state.index + delta
    if index < 0 then index = days end
    if index > days then index = 0 end
    SelectDay(index)
end

-- Hovering the time bar: the event nearest the cursor (within a few pixels) in a tooltip, the
-- same as its icon on the map. The ticks are textures, so this is worked out from the cursor.
local hoverEntry
local function HoverTicks()
    local hit = bar.track:GetParent()
    if state.dragging or not hit:IsMouseOver() or state.t1 <= state.t0 then
        if hoverEntry then hoverEntry = nil; GameTooltip_Hide() end
        if bar.xpShown then
            for _, label in ipairs(bar.xpLabels) do label:Hide() end
            bar.xpShown, bar.xpAt = false, nil
        end
        return
    end
    local x = GetCursorPosition() / bar.track:GetEffectiveScale()
    local left, width = bar.track:GetLeft(), bar.track:GetWidth()
    if not left or width <= 0 then return end
    -- Experience gains near the cursor, as small numbers above the bar (hover only).
    local cursorX = math.floor(x - left + 0.5)
    if cursorX ~= bar.xpAt then
        bar.xpAt = cursorX
        local labelCount = 0
        for _, gain in ipairs(state.xp) do
            local gainX = TimeToX(gain.t)
            if math.abs(gainX - cursorX) <= 30 and labelCount < 10 then
                labelCount = labelCount + 1
                local label = bar.xpLabels[labelCount]
                if not label then
                    label = hit:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    local font = label:GetFont()
                    if font then label:SetFont(font, 8, "OUTLINE") end
                    label:SetTextColor(0.75, 0.6, 1)
                    bar.xpLabels[labelCount] = label
                end
                label:SetText("+" .. gain.amt)
                label:ClearAllPoints()
                label:SetPoint("BOTTOM", bar.track, "LEFT", gainX, 10 + (labelCount % 2) * 8)
                label:Show()
            end
        end
        for i = labelCount + 1, #bar.xpLabels do bar.xpLabels[i]:Hide() end
        bar.xpShown = labelCount > 0
    end
    local best, bestDistance
    for _, logged in ipairs(state.events) do
        local distance = not Visible(logged.line) and math.huge or math.abs(left + TimeToX(logged.line.t) - x)
        if distance <= 5 and (not bestDistance or distance < bestDistance) then best, bestDistance = logged, distance end
    end
    if best == hoverEntry then return end
    hoverEntry = best
    if not best then GameTooltip_Hide() return end
    ShowEntry(best, hit, "ANCHOR_CURSOR")
end

local sinceDraw, sinceLive = 0, 0
local function OnUpdate(_, elapsed)
    -- Let go anywhere (even off the bar, where it may not hear the mouse come up): the drag ends.
    if state.dragging and not IsMouseButtonDown("LeftButton") then state.dragging = false end
    HoverTicks()
    Animate()
    if state.dragging then
        local x = GetCursorPosition() / bar.track:GetEffectiveScale()
        local left, width = bar.track:GetLeft(), bar.track:GetWidth()
        if left and width > 0 then
            -- A click that landed on a level up stays on it until the mouse moves away.
            if state.snap and math.abs(x - state.snap.x) < 4 then
                SetMoment(state.snap.t)
            else
                state.snap = nil
                SetMoment(XToTime(x - left))
            end
        end
    elseif state.playing and state.holdUntil and GetTime() < state.holdUntil then
        -- Holding on a big moment so its note can be read.
    elseif state.playing then
        state.holdUntil = nil
        local when = state.moment + elapsed * SPEEDS[state.speed][1]
        -- Long gaps (logged off, a loading screen) are jumped over.
        local index = Find(when)
        local times = state.times
        if index == 0 and times[1] and when < times[1] then
            when = times[1]
        elseif index > 0 and times[index + 1] and times[index + 1] - times[index] > GAP then
            when = times[index + 1]
        end
        -- So are the stretches squeezed on the time bar.
        for _, gap in ipairs(squeezed) do
            if when > gap.t0 and when < gap.t1 then when = gap.t1 end
        end
        if when >= state.t1 then
            when = state.t1
            state.playing = false
        end
        SetMoment(when)
    end
    -- Today's route grows as you go: picked up again every few seconds while it's shown (and
    -- followed, if you were watching its end).
    sinceLive = sinceLive + elapsed
    if sinceLive >= 5 and not state.dragging and not state.playing and state.days[state.index] == date("%Y-%m-%d") then
        sinceLive = 0
        local atEnd, moment = state.moment >= state.t1, state.moment
        local whole = state.whole
        Load()
        if not atEnd then state.moment = math.min(moment, state.t1) end
        state.whole = whole
        layoutDirty, dirty, logDirty = true, true, true
        UpdateTicks()
        UpdateBar()
    end
    sinceDraw = sinceDraw + elapsed
    if sinceDraw < FRAME then return end
    local step = sinceDraw
    sinceDraw = 0
    -- Dragging the map: the camera goes with the cursor.
    local pan = state.pan
    if pan then
        if not IsMouseButtonDown("LeftButton") then
            state.pan = nil
        else
            local x, y = GetCursorPosition()
            local effectiveScale, scale = view:GetEffectiveScale(), canvas.s or 1
            local dx, dy = x / effectiveScale - pan.x, y / effectiveScale - pan.y
            -- A real drag (more than a click) stops following.
            if not pan.moved and dx * dx + dy * dy > 16 then
                pan.moved = true
                if camera.follow then
                    camera.follow = false
                    if UpdateMapButtons then UpdateMapButtons() end
                end
            end
            if pan.moved then
                camera.x = pan.camX - dx / scale
                camera.y = pan.camY + dy / scale
                PlaceCanvas()
            end
        end
    end
    if layoutDirty then pcall(Layout) end
    if dirty then pcall(Draw) end
    MoveCamera(step)
    if scaleDirty then pcall(ApplyScale) end
end

local function Tip(button, title, text)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
end

local function ArrowButton(parent, direction)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(22, 22)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
    button:SetNormalTexture(base .. "Up")
    button:SetPushedTexture(base .. "Down")
    button:SetDisabledTexture(base .. "Disabled")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return button
end

local function BuildBar()
    bar = CreateFrame("Frame", "CaptainsLogJourneyBar", window, "BackdropTemplate")
    bar:SetPoint("BOTTOMLEFT", 10, 10)
    bar:SetPoint("BOTTOMRIGHT", -10, 10)
    bar:SetHeight(66)
    bar:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    bar:SetBackdropColor(0.10, 0.06, 0.03, 0.88)
    bar:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    bar:EnableMouse(true)

    local previous = ArrowButton(bar, "Prev")
    previous:SetPoint("TOPLEFT", 8, -6)
    previous:SetScript("OnClick", function() Step(-1) end)
    Tip(previous, L["Previous day"])
    bar.day = UI.Text(bar, 12, { 0.98, 0.9, 0.7 })
    bar.day:SetWidth(130)
    bar.day:SetJustifyH("CENTER")
    bar.day:SetPoint("LEFT", previous, "RIGHT", 2, 0)
    local nextDay = ArrowButton(bar, "Next")
    nextDay:SetPoint("LEFT", bar.day, "RIGHT", 2, 0)
    nextDay:SetScript("OnClick", function() Step(1) end)
    Tip(nextDay, L["Next day"], L["Past the last day comes \"All days\"."])

    bar.play = UI.Button(bar, L["Play"], 64, 20)
    bar.play:SetPoint("LEFT", nextDay, "RIGHT", 10, 0)
    bar.play:SetScript("OnClick", function()
        if state.playing then
            state.playing = false
        else
            if state.whole or state.moment >= state.t1 then SetMoment(state.t0) end
            state.whole, state.playing = false, true
            StartFollow()
        end
        UpdateBar()
    end)
    bar.speed = UI.Button(bar, "1x", 48, 20)
    bar.speed:SetPoint("LEFT", bar.play, "RIGHT", 4, 0)
    bar.speed:SetScript("OnClick", function()
        state.speed = state.speed % #SPEEDS + 1
        UpdateBar()
    end)
    Tip(bar.speed, L["Speed"], L["1x plays a minute of the day each second; click for 5x, 20x and 100x."])
    bar.whole = UI.Button(bar, L["Whole route"], 100, 20)
    bar.whole:SetPoint("LEFT", bar.speed, "RIGHT", 4, 0)
    bar.whole:SetScript("OnClick", function()
        state.whole, state.playing = true, false
        SetMoment(state.t1)
        Overview()
    end)
    Tip(bar.whole, L["Whole route"], L["Stops playing and draws the whole route, with everything that happened along it."])

    -- "Show": a checklist of what's drawn (kept between sessions).
    bar.show = UI.Button(bar, L["Show"], 64, 20)
    bar.show:SetPoint("LEFT", bar.whole, "RIGHT", 4, 0)
    Tip(bar.show, L["Show"], L["Choose what the journey map draws: your route, and each kind of entry."])
    local menu = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    menu:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    menu:SetBackdropColor(0.08, 0.06, 0.04, 0.95)
    menu:SetPoint("BOTTOMLEFT", bar.show, "TOPLEFT", 0, 4)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu:Hide()
    local function Changed()
        layoutDirty, dirty, pastLines, logDirty = true, true, nil, true
        UpdateTicks()
        UpdateBar()
    end
    local rows = {}
    local function Row(index, label, get, set)
        local check = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 8, -6 - (index - 1) * 22)
        local text = check.Text or check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if not check.Text then text:SetPoint("LEFT", check, "RIGHT", 2, 0) end
        text:SetText(label)
        check:SetScript("OnShow", function(self) self:SetChecked(get()) end)
        check:SetScript("OnClick", function(self)
            set(self:GetChecked() and true or false)
            Changed()
            for _, row in ipairs(rows) do row:SetChecked(row.get()) end
        end)
        check.get = get
        rows[#rows + 1] = check
        return check
    end
    Row(1, L["Everything"], function()
        for _, group in ipairs(GROUPS) do if Hidden(group.key) then return false end end
        return true
    end, function(on)
        for _, group in ipairs(GROUPS) do SetHidden(group.key, not on) end
    end)
    for i, group in ipairs(GROUPS) do
        Row(i + 1, group.label, function() return not Hidden(group.key) end,
            function(on) SetHidden(group.key, not on) end)
    end
    Row(#GROUPS + 2, L["You, in your gear at the time"], function()
        return not Hidden("hero")
    end, function(on)
        SetHidden("hero", (not on) or nil)
    end)
    Row(#GROUPS + 3, L["Squeeze quiet stretches"], function()
        return ns.db.settings.journeyCompress ~= false
    end, function(on) ns.db.settings.journeyCompress = on end)
    Row(#GROUPS + 5, L["Pause a moment on the big ones"], function()
        return ns.db.settings.journeyHold ~= false
    end, function(on) ns.db.settings.journeyHold = on end)
    Row(#GROUPS + 4, L["Log down the side"], function()
        return ns.db.settings.journeyNotes ~= false
    end, function(on)
        ns.db.settings.journeyNotes = on
        PlaceSide()
    end)
    menu:SetSize(260, 12 + (#GROUPS + 5) * 22)
    bar.show:SetScript("OnClick", function() menu:SetShown(not menu:IsShown()) end)
    bar.menu = menu

    -- The time bar: click to jump, drag to scrub.
    bar.time = UI.Text(bar, 12, { 0.98, 0.9, 0.7 })
    bar.time:SetPoint("BOTTOMRIGHT", -10, 9)
    bar.time:SetWidth(90)
    bar.time:SetJustifyH("RIGHT")
    local hit = CreateFrame("Frame", nil, bar)
    hit:SetPoint("BOTTOMLEFT", 10, 6)
    hit:SetPoint("RIGHT", bar.time, "LEFT", -8, 0)
    hit:SetHeight(22)
    hit:EnableMouse(true)
    local track = hit:CreateTexture(nil, "ARTWORK")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(6)
    track:SetColorTexture(0.9, 0.82, 0.62, 0.25)
    bar.track = track
    bar.fill = hit:CreateTexture(nil, "ARTWORK", nil, 1)
    bar.fill:SetPoint("LEFT", track, "LEFT")
    bar.fill:SetHeight(6)
    bar.fill:SetColorTexture(PAST[1], PAST[2], PAST[3], 0.8)
    bar.thumb = hit:CreateTexture(nil, "OVERLAY")
    bar.thumb:SetSize(4, 18)
    bar.thumb:SetColorTexture(1, 0.85, 0.4, 1)
    bar.ticks, bar.levelLabels, bar.breaks, bar.strip, bar.xpLabels = {}, {}, {}, {}, {}
    hit:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        -- Clicking near a level up's mark jumps right to it.
        state.snap = nil
        local x = GetCursorPosition() / track:GetEffectiveScale()
        local left = track:GetLeft()
        if left then
            local bestDistance
            for _, logged in ipairs(state.events) do
                local line = logged.line
                if line.k == "level" and Visible(line) then
                    local distance = math.abs(left + TimeToX(line.t) - x)
                    if distance <= 6 and (not bestDistance or distance < bestDistance) then
                        bestDistance, state.snap = distance, { x = x, t = line.t }
                    end
                end
            end
        end
        if state.snap then SetMoment(state.snap.t) end
        local wasWhole = state.whole
        state.dragging, state.playing, state.whole = true, false, false
        if wasWhole then StartFollow() end
        pastLines = nil
        UpdateBar()
    end)
    hit:SetScript("OnMouseUp", function() state.dragging = false end)
    hit:SetScript("OnHide", function() state.dragging = false end)
    hit:SetScript("OnSizeChanged", function()
        UpdateTicks()
        UpdateBar()
    end)
    Tip(hit, L["Time bar"], L["Click to jump to a moment, or drag to go back and forth. The marks are things written in the log."])
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

local function SaveWindow()
    local point, _, relativePoint, x, y = window:GetPoint(1)
    ns.db.settings.journeyWindow = { w = math.floor(window:GetWidth() + 0.5), h = math.floor(window:GetHeight() + 0.5),
        point = point, rel = relativePoint, x = x, y = y }
end

-- Zone or continent: the map the moment shown is on, as the toggle asks.
local function ShowZoneOrContinent()
    local point = state.points[math.max(1, Find(state.moment))]
    if not (point and point.map) then return end
    SetMap(MapFor(point.map))
    if camera.follow then
        camera.snap = true
    else
        camera.zoom = 1
        PlaceCanvas()
    end
end

local function BuildView()
    view = CreateFrame("Frame", nil, window)
    view:SetPoint("TOPLEFT", 12, -34)
    view:SetPoint("BOTTOMRIGHT", -12, 82)
    view:SetClipsChildren(true)
    view:EnableMouse(true)
    view:EnableMouseWheel(true)
    local background = view:CreateTexture(nil, "BACKGROUND", nil, -8)
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.04, 0.03, 1)

    canvas = CreateFrame("Frame", nil, view)
    canvas:SetSize(mapW, mapH)
    canvas:SetPoint("TOPLEFT")
    canvas:SetClipsChildren(true) -- the art's last tiles run past its edge

    -- Things over the map: the zone's name, Follow, Zone / Continent.
    local over = CreateFrame("Frame", nil, window)
    over:SetAllPoints(view)
    over:SetFrameLevel(view:GetFrameLevel() + 40)
    canvas.empty = UI.Text(over, 13, { 0.85, 0.75, 0.55 })
    canvas.empty:SetPoint("CENTER")
    canvas.empty:SetText(L["There's no map of this place."])
    canvas.empty:Hide()
    local zone = UI.Text(over, 16, { 0.98, 0.9, 0.7 }, UI.HEADING_FONT)
    zone:SetPoint("TOPRIGHT", -10, -8)
    zone:SetShadowOffset(1, -1)
    view.zone = zone

    local follow = UI.Button(over, L["Follow"], 80, 20)
    follow:SetPoint("TOPRIGHT", zone, "BOTTOMRIGHT", 0, -6)
    follow:SetScript("OnClick", function()
        if camera.follow then
            camera.follow = false
            UpdateMapButtons()
        else
            if state.whole then
                state.whole = false
                pastLines = nil
            end
            StartFollow()
            UpdateBar()
        end
    end)
    Tip(follow, L["Follow"], L["Keeps you in the middle of the map, from zone to zone. Dragging the map stops it; click to follow again."])
    local zoneOrContinent = UI.Button(over, "", 80, 20)
    zoneOrContinent:SetPoint("RIGHT", follow, "LEFT", -4, 0)
    zoneOrContinent:SetScript("OnClick", function()
        continent = not continent
        ShowZoneOrContinent()
        UpdateMapButtons()
    end)
    Tip(zoneOrContinent, L["Zone / Continent"], L["Shows the zone you were in, or the whole continent around it."])
    UpdateMapButtons = function()
        if camera.follow then follow:LockHighlight() else follow:UnlockHighlight() end
        zoneOrContinent:SetText(continent and L["Zone"] or L["Continent"])
    end
    UpdateMapButtons()

    -- Mouse wheel zooms (on the cursor; on you while following), dragging pans.
    view:SetScript("OnMouseWheel", function(_, delta)
        local oldScale = canvas.s or CameraScale()
        local zoom = math.max(1, math.min(MAX_ZOOM, camera.zoom * (delta > 0 and 1.25 or 0.8)))
        if zoom == camera.zoom then return end
        camera.zoom = zoom
        if camera.follow then
            ns.db.settings.journeyZoom = zoom
        else
            local x, y = GetCursorPosition()
            local effectiveScale = view:GetEffectiveScale()
            local viewW, viewH = view:GetWidth(), view:GetHeight()
            local offsetX = x / effectiveScale - view:GetLeft() - viewW / 2
            local offsetY = view:GetTop() - y / effectiveScale - viewH / 2
            local pointX, pointY = camera.x + offsetX / oldScale, camera.y + offsetY / oldScale
            local scale = CameraScale()
            camera.x, camera.y = pointX - offsetX / scale, pointY - offsetY / scale
        end
        PlaceCanvas()
    end)
    view:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local x, y = GetCursorPosition()
        local effectiveScale = view:GetEffectiveScale()
        state.pan = { x = x / effectiveScale, y = y / effectiveScale, camX = camera.x, camY = camera.y }
    end)
    view:SetScript("OnMouseUp", function() state.pan = nil end)
    view:SetScript("OnSizeChanged", function() PlaceCanvas() end)
end

local function BuildWindow()
    window = CreateFrame("Frame", "CaptainsLogJourney", UIParent, "BackdropTemplate")
    local saved = ns.db.settings.journeyWindow
    window:SetSize(saved and saved.w or 900, saved and saved.h or 620)
    if saved and saved.point then
        window:SetPoint(saved.point, UIParent, saved.rel or saved.point, saved.x or 0, saved.y or 0)
    else
        window:SetPoint("CENTER")
    end
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:SetResizable(true)
    if window.SetResizeBounds then
        window:SetResizeBounds(700, 480)
    elseif window.SetMinResize then
        window:SetMinResize(700, 480)
    end
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveWindow()
    end)
    -- The book's leather cover with a gilt edge.
    window:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    window:SetBackdropColor(0.27, 0.15, 0.07, 1)
    window:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    tinsert(UISpecialFrames, "CaptainsLogJourney")
    window:Hide()

    local title = UI.Text(window, 16, { 0.98, 0.9, 0.7 }, UI.HEADING_FONT)
    title:SetPoint("TOP", 0, -10)
    title:SetText(L["Journey"])
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    BuildView()
    BuildSide()
    PlaceSide()
    BuildBar()

    local grip = CreateFrame("Button", nil, window)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(bar:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() window:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        window:StopMovingOrSizing()
        SaveWindow()
    end)

    window:SetScript("OnUpdate", OnUpdate)
    window:SetScript("OnShow", function()
        sinceLive = 5 -- the route as it is now, straight away
        layoutDirty = true
    end)
    window:SetScript("OnHide", function()
        state.playing, state.dragging, state.pan = false, false, nil
        StopAll()
        if bar.menu then bar.menu:Hide() end
        UpdateBar()
    end)
end

------------------------------------------------------------------------------
-- The world map's button (a plain frame of ours; the map itself is left alone)
------------------------------------------------------------------------------

local function UpdateToggle()
    if not toggle then return end
    local wanted = not (ns.db and ns.db.settings.journeyButton == false)
    toggle:SetShown(wanted)
end
JourneyMap.UpdateToggle = UpdateToggle

local function BuildToggle()
    if toggle or not (WorldMapFrame and WorldMapFrame.ScrollContainer) then return end
    toggle = CreateFrame("Button", "CaptainsLogJourneyToggle", WorldMapFrame)
    toggle:SetSize(28, 28)
    toggle:SetPoint("BOTTOMRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", -8, 8)
    local child = WorldMapFrame.ScrollContainer.Child
    toggle:SetFrameLevel((child and child:GetFrameLevel() or WorldMapFrame:GetFrameLevel()) + 2200)
    local icon = toggle:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = toggle:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    toggle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    toggle:SetScript("OnClick", function() JourneyMap.Show() end)
    Tip(toggle, L["Journey"], L["Captain's Log: play back your journey, day by day."])
    UpdateToggle()
end

------------------------------------------------------------------------------
-- Opening and closing
------------------------------------------------------------------------------

-- Opens the window on day `key` (default the latest). Fine in combat: it's all ours.
function JourneyMap.Show(key)
    if not window then BuildWindow() end
    CollectDays()
    local index = #state.days
    if key then
        for i, day in ipairs(state.days) do
            if day == key then index = i end
        end
    end
    window:Show()
    window:Raise()
    SelectDay(index)
end
JourneyMap.Open = JourneyMap.Show

function JourneyMap.Close()
    if window then window:Hide() end
end

if WorldMapFrame then
    pcall(BuildToggle)
else
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("ADDON_LOADED")
    waiter:SetScript("OnEvent", function(self, _, name)
        if name == "Blizzard_WorldMap" then
            self:UnregisterAllEvents()
            pcall(BuildToggle)
        end
    end)
end

-- /log journey: what the journey window sees, to tell a route that wasn't recorded from one that
-- doesn't draw.
function ns.JourneyReport()
    local Print = ns.Print
    local instance, north, west, here = ns.Journey.Here()
    Print(("here: instance %s, %s / %s, map %s"):format(tostring(instance), tostring(north), tostring(west), tostring(here)))
    local key = date("%Y-%m-%d")
    local flat = ns.Journey.Decode(key)
    Print(("today: %d route points"):format(#flat))
    local shown = mapID or here
    Print(("journey window map: %s"):format(tostring(shown)))
    local last = flat[#flat]
    if last and shown then
        local u, v = ToMap(last.inst, last.y, last.x, shown)
        Print(("last point (instance %s) on that map: %s, %s"):format(tostring(last.inst), tostring(u), tostring(v)))
    end
    local placed = 0
    for _, line in ipairs(ns.db.days[key] and ns.db.days[key].events or {}) do
        if line.pi then placed = placed + 1 end
    end
    Print(("today's log entries with a place: %d"):format(placed))
end
