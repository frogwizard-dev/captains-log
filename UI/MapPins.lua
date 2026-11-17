local _, ns = ...
local L = ns.L
local UI = ns.UI

-- Captain's Log on the game's world map: a Map button pins an entry (db.mapLayers { kind, id }:
-- questgiver, questfoes, mob, npc, zone, photo, fish, fishspot), rebuilt from the journal each time
-- the map draws, until you right-click it away; your fishing spots come from a setting instead. The
-- plumbing follows HereBeDragons-Pins: our own pin pool and a data provider the map asks for pins.

local TEMPLATE = "CaptainsLogMapPinTemplate"
local MapPins = {}
ns.MapPins = MapPins

------------------------------------------------------------------------------
-- What each kind of entry puts on the map: title, the book page it opens, and pins
-- { mapID, x, y, kind, label }. Icon pins come last so they draw over the dots.
------------------------------------------------------------------------------

local builders = {}

local function NpcName(id)
    local npc = id and ns.db.npcs[id]
    return npc and npc.name
end

local function AddSpots(pins, mob, label)
    for mapID, spots in pairs(mob.spots or {}) do
        for _, spot in ipairs(spots) do pins[#pins + 1] = { mapID, spot[1], spot[2], "kill", label } end
    end
end

-- A quest goes on the map in two separate sets, each from its own Map button: who to see
-- (giver and hand-in) and what to hunt (its creatures' kill spots).
local function QuestFoePins(quest, pins)
    local seen = {}
    for i in ipairs(quest.objectives or {}) do
        for _, foe in ipairs(ns.ObjectiveFoes(quest, i)) do
            if not seen[foe.id] then
                seen[foe.id] = true
                local name = foe.mob.name or "?"
                AddSpots(pins, foe.mob, foe.item and L["%s, drops %s"]:format(name, foe.item) or name)
            end
        end
    end
end

local function QuestPeoplePins(quest, pins)
    local mapID, x, y = ns.QuestStart(quest)
    if mapID then
        local giver = NpcName(quest.giver)
        pins[#pins + 1] = { mapID, x, y, "start", giver and L["Quest giver: %s"]:format(giver) or L["Quest giver"] }
    end
    mapID, x, y = ns.QuestFinish(quest)
    if mapID then
        local taker = NpcName(quest.turnInNpc)
        pins[#pins + 1] = { mapID, x, y, "finish", taker and L["Handed in to %s"]:format(taker) or L["Handed in"] }
    end
end

builders.questgiver = function(id)
    local quest = ns.db.quests[id]
    if not quest then return end
    local pins = {}
    QuestPeoplePins(quest, pins)
    return L["%s (quest giver)"]:format(quest.title or L["Quest #%s"]:format(id)), "quests", pins
end

builders.questfoes = function(id)
    local quest = ns.db.quests[id]
    if not quest then return end
    local pins = {}
    QuestFoePins(quest, pins)
    return L["%s (creatures)"]:format(quest.title or L["Quest #%s"]:format(id)), "quests", pins
end

-- Both at once: how 0.4.0 pinned quests, kept so those saved pins still show (and remove).
builders.quest = function(id)
    local quest = ns.db.quests[id]
    if not quest then return end
    local pins = {}
    QuestFoePins(quest, pins)
    QuestPeoplePins(quest, pins)
    return quest.title or L["Quest #%s"]:format(id), "quests", pins
end

builders.mob = function(id)
    local mob = ns.db.mobs[id]
    if not mob then return end
    local pins = {}
    AddSpots(pins, mob, mob.name or "?")
    return mob.name or L["Unknown creature"], "bestiary", pins
end

local function NpcLabel(npc)
    return npc.title and L["%s, %s"]:format(npc.name or "?", npc.title) or (npc.name or "?")
end

builders.npc = function(id)
    local npc = ns.db.npcs[id]
    if not npc or not npc.mapID then return end
    return npc.name or L["Someone"], "people", { { npc.mapID, npc.x, npc.y, "npc", NpcLabel(npc) } }
end

-- A picture's wedge on its own map: from the spot, the way you faced, as wide as the camera, as long
-- as the book's close-up (UI.CONE_SHARE of the width); the map's size in yards keeps angles true.
local function ConePoints(photo)
    local ok, worldWidth, worldHeight = pcall(C_Map.GetMapWorldSize, photo.mapID)
    if not ok or not worldWidth or worldWidth <= 0 or not worldHeight or worldHeight <= 0 then
        worldWidth, worldHeight = 1.5, 1
    end
    local half = math.rad(math.max(25, math.min(60, (photo.fov or 90) / 2)))
    local reachX, reachY = UI.CONE_SHARE, UI.CONE_SHARE * worldWidth / worldHeight
    local points = { { photo.x, photo.y } }
    for step = 0, 6 do
        local angle = photo.facing - half + 2 * half * step / 6
        points[#points + 1] = { photo.x - math.sin(angle) * reachX, photo.y - math.cos(angle) * reachY }
    end
    return points
end

-- One picture (by its time): a pin where it was taken, and its view cone. Clicking opens its day.
builders.photo = function(when)
    local photo, day = ns.FindPhoto(when)
    if not photo or not photo.mapID or not photo.x then return end
    local where = (photo.place and photo.zone and photo.place ~= photo.zone)
        and L["%s, %s"]:format(photo.place, photo.zone) or photo.place or photo.zone or L["a picture"]
    local title = photo.caption or L["Picture at %s"]:format(where)
    local pins = {}
    if photo.facing then
        pins[#pins + 1] = { photo.mapID, photo.x, photo.y, "cone", title, points = ConePoints(photo) }
    end
    pins[#pins + 1] = { photo.mapID, photo.x, photo.y, "place", L["%s, %s"]:format(title, date(L["%d %b, %H:%M"], photo.t)) }
    return title, "log", pins, "photos:" .. day
end

builders.zone = function(name)
    local record = ns.db.zones[name]
    if not record then return end
    local pins = {}
    for _, npc in pairs(ns.db.npcs) do
        if npc.zone == name and npc.mapID and next(npc.roles) then
            pins[#pins + 1] = { npc.mapID, npc.x, npc.y, "npc", NpcLabel(npc) }
        end
    end
    for _, death in ipairs(ns.db.deaths) do
        if death.zone == name and death.mapID then
            local how = death.killer and L["Slain by %s"]:format(death.killer) or L["Died"]
            pins[#pins + 1] = { death.mapID, death.x, death.y, "death", L["%s, %s"]:format(how, ns.Date(death.time)) }
        end
    end
    for place, found in pairs(record.places or {}) do
        if found.mapID then
            pins[#pins + 1] = { found.mapID, found.x, found.y, "place", L["%s, found %s"]:format(place, ns.Date(found.t)) }
        end
    end
    return name, "zones", pins
end

-- Fishing (Fishing.lua): the points you cast from, each counting the casts made near it, in a
-- pool's colour where most of them were into pools. A click opens the spot (or `selected`).
local function FishPins(pins, zone, place, spot, label, selected)
    if not spot.mapID then return end
    for _, point in ipairs(spot.pts or {}) do
        local casts, pooled = point[3] or 1, point[4] or 0
        pins[#pins + 1] = { spot.mapID, point[1], point[2], pooled * 2 > casts and "pool" or "fish", label,
            note = string.format(L["Fished here %d %s%s"], casts, casts == 1 and L["time"] or L["times"],
                pooled > 0 and string.format(L[", %d into a pool"], pooled) or ""),
            sel = selected or ns.FishSpotKey(zone, place) }
    end
end

-- One catch: everywhere you've caught it.
builders.fish = function(id)
    local journal = ns.FishingJournal()
    local catch = journal.items[id]
    if not catch then return end
    local pins = {}
    for zone, places in pairs(journal.spots) do
        for place, spot in pairs(places) do
            local tally = spot.items[id]
            if tally then
                FishPins(pins, zone, place, spot,
                    string.format(L["%s: %d at %s"], catch.name or "?", tally.n, ns.FishSpotName(zone, place)))
            end
        end
    end
    return catch.name or L["A catch"], "fishing", pins, id
end

-- One fishing spot (by its key).
builders.fishspot = function(key)
    local spot, zone, place = ns.FishSpot(key)
    if not spot then return end
    local pins = {}
    FishPins(pins, zone, place, spot, ns.FishSpotName(zone, place))
    return L["%s (fishing)"]:format(ns.FishSpotName(zone, place)), "fishing", pins, key
end

-- Every spot you've fished from: shown by a setting rather than a Map button (FISH_LAYER).
builders.fishing = function()
    local pins = {}
    for zone, places in pairs(ns.FishingJournal().spots) do
        for place, spot in pairs(places) do
            FishPins(pins, zone, place, spot, ns.FishSpotName(zone, place))
        end
    end
    return L["Fishing spots"], "fishing", pins
end
local FISH_LAYER = { kind = "fishing", id = "all" }

------------------------------------------------------------------------------
-- Placing a pin on the map being viewed
------------------------------------------------------------------------------

local ancestry = {}
local function Ancestors(mapID)
    local set = ancestry[mapID]
    if set then return set end
    set = {}
    local id = mapID
    for _ = 1, 10 do
        if not id or id == 0 or set[id] then break end
        set[id] = true
        local map = C_Map.GetMapInfo(id)
        id = map and map.parentMapID
    end
    ancestry[mapID] = set
    return set
end

-- Where a spot on map `from` falls on map `to`: only its own map, those above it and those inside
-- it (zone rectangles overlap, so a plain conversion would put Elwynn's pins along Westfall's edge).
local function Place(from, x, y, to)
    if not (from and x and y) then return end
    if from == to then return x, y end
    if not (Ancestors(from)[to] or Ancestors(to)[from]) then return end
    local map = C_Map.GetMapInfo(to)
    if not map or (map.mapType or 0) < 2 then return end -- not on the world or cosmic maps
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, from, CreateVector2D(x, y))
    if not ok or not continent or not world then return end
    local okPosition, _, position = pcall(C_Map.GetMapPosFromWorldPos, continent, world, to)
    if not okPosition or not position then return end
    local placedX, placedY = position:GetXY()
    if not placedX or placedX < 0 or placedX > 1 or placedY < 0 or placedY > 1 then return end
    return placedX, placedY
end

------------------------------------------------------------------------------
-- Pins
------------------------------------------------------------------------------

local pinMixin = CreateFromMixins(MapCanvasPinMixin)
-- MapCanvasPinMixin calls this, and it's blocked in combat for addon pins (HereBeDragons does
-- the same).
pinMixin.SetPassThroughButtons = function() end

-- The map wires up a pin's mouse scripts itself (and asserts the pin set none), then calls
-- these methods: OnMouseEnter, OnMouseLeave, and OnMouseUp(button, upInside).
function pinMixin:OnMouseEnter()
    local pin = self.data
    if not pin then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(pin.label)
    if pin.note then GameTooltip:AddLine(pin.note, 1, 1, 1) end
    GameTooltip:AddLine(L["Captain's Log: %s"]:format(pin.title), 0.85, 0.75, 0.55)
    -- Hunting areas let left-clicks through to the map, so only the dots open the book.
    if not pin.area then GameTooltip:AddLine(L["Click to open it in the book"], 0.6, 0.6, 0.6) end
    GameTooltip:AddLine(L["Right-click to remove these pins"], 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L["Shift-right-click to remove all of the book's pins"], 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function pinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

-- upInside is false when the button was released off the pin; older maps don't pass it.
function pinMixin:OnMouseUp(button, upInside)
    local pin = self.data
    if not pin or upInside == false then return end
    GameTooltip:Hide()
    if button == "RightButton" then
        if IsShiftKeyDown() then MapPins.Clear() else MapPins.Remove(pin.layer.kind, pin.layer.id) end
    elseif button == "LeftButton" then
        ns.Book:Goto(pin.page, pin.sel or pin.layer.id)
    end
end

function pinMixin:OnClick() end -- handled in OnMouseUp; the map may call both

local function CreatePin()
    local pin = Mixin(CreateFrame("Frame", nil, WorldMapFrame:GetCanvas()), pinMixin)
    pin:SetSize(10, 10)
    pin.rim = pin:CreateTexture(nil, "OVERLAY", nil, 1)
    pin.rim:SetAllPoints()
    pin.rim:SetColorTexture(0.15, 0.05, 0.02, 1)
    pin.fill = pin:CreateTexture(nil, "OVERLAY", nil, 2)
    pin.fill:SetPoint("TOPLEFT", 1, -1)
    pin.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    pin.icon = pin:CreateTexture(nil, "OVERLAY", nil, 3)
    pin.icon:SetAllPoints()
    pin:EnableMouse(true) -- the map then routes the mouse to the pin methods above
    pcall(pin.SetScalingLimits, pin, 1, 1.0, 1.2)
    return pin
end

function pinMixin:OnAcquired(pin, x, y)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetPosition(x, y)
    self.data = pin
    local atlas = UI.PIN_ATLAS[pin.kind]
    local iconic = atlas and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
    if iconic then self.icon:SetAtlas(atlas) end
    self.icon:SetShown(iconic)
    self.rim:SetShown(not iconic)
    self.fill:SetShown(not iconic)
    local color = UI.PIN[pin.kind] or UI.PIN.kill
    self.fill:SetColorTexture(color[1], color[2], color[3], 1)
    self:SetSize(iconic and 24 or 10, iconic and 24 or 10)
    self:Show()
end

function pinMixin:OnReleased()
    self.data = nil
end

------------------------------------------------------------------------------
-- Hunting areas: a creature slain often on one map is drawn as the ground you hunted it on, each
-- cluster of kills as a padded shape around them that zooms with the map and lets left-clicks through.
------------------------------------------------------------------------------

local AREA_TEMPLATE = "CaptainsLogMapAreaTemplate"
local AREA_MIN = 15     -- more kills than this on the map being viewed, and it's drawn as areas
local AREA_LINK = 0.06  -- kills closer than this (share of map width) share a hunting ground
local AREA_PAD = 0.012  -- how far the shape reaches past its outermost kills
local PAD_STEPS = 8     -- points around each kill when padding: an octagon, near enough round

local areaMixin = CreateFromMixins(pinMixin)

local FrameMethods = getmetatable(CreateFrame("Frame")).__index

local function CreateAreaPin()
    local pin = Mixin(CreateFrame("Frame", nil, WorldMapFrame:GetCanvas()), areaMixin)
    pin.tris, pin.lines = {}, {}
    pin:EnableMouse(true)
    -- The real method (the mixin's is a stub for the map's own call); it can't be changed in
    -- combat, so an area made mid-fight keeps left-clicks.
    if not InCombatLockdown() then pcall(FrameMethods.SetPassThroughButtons, pin, "LeftButton") end
    return pin
end

local function Triangle(pin, index, ax, ay, bx, by, cx, cy, r, g, b, a)
    local texture = pin.tris[index]
    if not texture then
        texture = pin:CreateTexture(nil, "ARTWORK")
        pin.tris[index] = texture
    end
    texture:SetColorTexture(r, g, b, a)
    UI.DrawTriangle(texture, pin, ax, ay, bx, by, cx, cy)
end

local function Edge(pin, index, ax, ay, bx, by, r, g, b, a)
    local line = pin.lines[index]
    if not line then
        line = pin:CreateLine(nil, "OVERLAY")
        pin.lines[index] = line
    end
    line:SetThickness(1.5)
    line:SetColorTexture(r, g, b, a)
    line:SetStartPoint("TOPLEFT", pin, ax, -ay)
    line:SetEndPoint("TOPLEFT", pin, bx, -by)
    line:Show()
end

function areaMixin:OnAcquired(area, x, y)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    -- No scaling limits: the area keeps its size on the map, not on screen.
    self.scaleFactor, self.startScale, self.endScale = nil, nil, nil
    if self.SetIgnoreGlobalPinScale then self:SetIgnoreGlobalPinScale(true) end
    self:SetPosition(x, y)
    self:SetSize(area.w, area.h)
    self.data = area

    -- A fan of triangles from the middle fills the (convex) shape; lines trace its edge.
    local hull, corners = area.hull, #area.hull
    local middleX, middleY = 0, 0
    for _, corner in ipairs(hull) do middleX, middleY = middleX + corner[1], middleY + corner[2] end
    middleX, middleY = middleX / corners, middleY / corners
    local color = area.color or UI.PIN.kill
    for i = 1, corners do
        local corner, nextCorner = hull[i], hull[i % corners + 1]
        Triangle(self, i, middleX, middleY, corner[1], corner[2], nextCorner[1], nextCorner[2],
            color[1], color[2], color[3], area.alpha)
        Edge(self, i, corner[1], corner[2], nextCorner[1], nextCorner[2],
            color[1] * 0.7, color[2] * 0.7, color[3] * 0.7, 0.85)
    end
    for i = corners + 1, #self.tris do self.tris[i]:Hide() end
    for i = corners + 1, #self.lines do self.lines[i]:Hide() end
    self:Show()
end

-- One step below the dots and icons, so a quest giver's "!" stays on top of a hunting area.
function areaMixin:ApplyFrameLevel()
    if MapCanvasPinMixin.ApplyFrameLevel then MapCanvasPinMixin.ApplyFrameLevel(self) end
    self:SetFrameLevel(math.max(1, self:GetFrameLevel() - 1))
end

function areaMixin:OnMouseUp(button, upInside)
    if button == "RightButton" then pinMixin.OnMouseUp(self, button, upInside) end
end

-- Groups kills that are within AREA_LINK of each other (directly or through other kills).
local function Clusters(spots, width, height)
    local link = (AREA_LINK * width) ^ 2
    local parent = {}
    for i = 1, #spots do parent[i] = i end
    local function Root(index)
        while parent[index] ~= index do
            parent[index] = parent[parent[index]]
            index = parent[index]
        end
        return index
    end
    for i = 1, #spots do
        for other = i + 1, #spots do
            local dx, dy = (spots[i][1] - spots[other][1]) * width, (spots[i][2] - spots[other][2]) * height
            if dx * dx + dy * dy <= link then parent[Root(i)] = Root(other) end
        end
    end
    local groups, list = {}, {}
    for i, spot in ipairs(spots) do
        local root = Root(i)
        if not groups[root] then
            groups[root] = {}
            list[#list + 1] = groups[root]
        end
        table.insert(groups[root], spot)
    end
    return list
end

-- The convex hull of points { x, y } (monotone chain), counter-clockwise.
local function Hull(points)
    table.sort(points, function(first, second)
        return first[1] < second[1] or (first[1] == second[1] and first[2] < second[2])
    end)
    if #points < 3 then return points end
    local function Cross(origin, first, second)
        return (first[1] - origin[1]) * (second[2] - origin[2]) - (first[2] - origin[2]) * (second[1] - origin[1])
    end
    local lower, upper = {}, {}
    for _, point in ipairs(points) do
        while #lower >= 2 and Cross(lower[#lower - 1], lower[#lower], point) <= 0 do table.remove(lower) end
        lower[#lower + 1] = point
    end
    for i = #points, 1, -1 do
        local point = points[i]
        while #upper >= 2 and Cross(upper[#upper - 1], upper[#upper], point) <= 0 do table.remove(upper) end
        upper[#upper + 1] = point
    end
    table.remove(lower)
    table.remove(upper)
    for _, point in ipairs(upper) do lower[#lower + 1] = point end
    return lower
end

-- A hull moved to start at 0, 0, with its box: shape, minX, maxX, minY, maxY.
local function Shape(hull)
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, point in ipairs(hull) do
        minX, maxX = math.min(minX, point[1]), math.max(maxX, point[1])
        minY, maxY = math.min(minY, point[2]), math.max(maxY, point[2])
    end
    local shape = {}
    for i, point in ipairs(hull) do shape[i] = { point[1] - minX, point[2] - minY } end
    return shape, minX, maxX, minY, maxY
end

-- Draws one creature's kills (already on this map) as hunting areas.
local function AddAreas(map, spots, base)
    local width, height = map:GetCanvas():GetSize()
    if not width or width == 0 or not height or height == 0 then return false end
    local groups = Clusters(spots, width, height)
    local most = 0
    for _, group in ipairs(groups) do most = math.max(most, #group) end
    local pad = AREA_PAD * width
    for _, group in ipairs(groups) do
        -- Work in canvas units so the padding is round on screen, not stretched.
        local points = {}
        for _, spot in ipairs(group) do
            for step = 0, PAD_STEPS - 1 do
                local angle = step * 2 * math.pi / PAD_STEPS
                points[#points + 1] = { spot[1] * width + pad * math.cos(angle), spot[2] * height + pad * math.sin(angle) }
            end
        end
        local shape, minX, maxX, minY, maxY = Shape(Hull(points))
        map:AcquirePin(AREA_TEMPLATE, {
            area = true, label = base.label, title = base.title, page = base.page, layer = base.layer,
            sel = base.sel, note = (#group == 1 and L["%d slain here"] or L["%d slain in this area"]):format(#group),
            alpha = 0.16 + 0.22 * (#group / most),
            hull = shape, w = maxX - minX, h = maxY - minY,
        }, (minX + maxX) / 2 / width, (minY + maxY) / 2 / height)
    end
    return true
end

-- A picture's view cone: the wedge from where it was taken (pin.points, on the picture's map),
-- drawn as a gold area on the map being viewed. Points off this map are dropped.
local function AddCone(map, mapID, pin, base)
    local width, height = map:GetCanvas():GetSize()
    if not width or width == 0 or not height or height == 0 then return end
    local points = {}
    for _, point in ipairs(pin.points or {}) do
        local x, y = Place(pin[1], point[1], point[2], mapID)
        if x then points[#points + 1] = { x * width, y * height } end
    end
    if #points < 3 then return end
    local shape, minX, maxX, minY, maxY = Shape(Hull(points))
    map:AcquirePin(AREA_TEMPLATE, {
        area = true, label = base.label, title = base.title, page = base.page, layer = base.layer, sel = base.sel,
        note = L["What the picture looked at"], alpha = 0.3, color = UI.PIN.place,
        hull = shape, w = math.max(1, maxX - minX), h = math.max(1, maxY - minY),
    }, (minX + maxX) / 2 / width, (minY + maxY) / 2 / height)
end

------------------------------------------------------------------------------
-- The data provider: the map calls RefreshAllData whenever it changes map
------------------------------------------------------------------------------

local provider = CreateFromMixins(MapCanvasDataProviderMixin)

function provider:RemoveAllData()
    self:GetMap():RemoveAllPinsByTemplate(TEMPLATE)
    self:GetMap():RemoveAllPinsByTemplate(AREA_TEMPLATE)
end

-- Per pinned entry: kill spots grouped by creature (dots, or areas when there are many),
-- then the icons last so they draw on top.
function provider:RefreshAllData()
    self:RemoveAllData()
    if not ns.db then return end
    local map = self:GetMap()
    local mapID = map:GetMapID()
    if not mapID then return end
    local layers = {}
    for i, layer in ipairs(ns.db.mapLayers) do layers[i] = layer end
    if ns.db.settings.fishPins then layers[#layers + 1] = FISH_LAYER end
    for _, layer in ipairs(layers) do
        local Build = builders[layer.kind]
        local ok, title, page, pins, selected = false, nil, nil, nil, nil
        if Build then ok, title, page, pins, selected = pcall(Build, layer.id) end
        if ok and pins then
            -- What a pin's click opens in the book: the entry itself unless the builder says.
            selected = selected or layer.id
            local kills, order, others = {}, {}, {}
            for _, pin in ipairs(pins) do
                if pin[4] == "cone" then
                    AddCone(map, mapID, pin, { label = pin[5], title = title, page = page, layer = layer, sel = selected })
                else
                    local x, y = Place(pin[1], pin[2], pin[3], mapID)
                    if x then
                        if pin[4] == "kill" then
                            if not kills[pin[5]] then
                                kills[pin[5]] = {}
                                order[#order + 1] = pin[5]
                            end
                            table.insert(kills[pin[5]], { x, y })
                        else
                            others[#others + 1] = { pin, x, y }
                        end
                    end
                end
            end
            for _, label in ipairs(order) do
                local spots = kills[label]
                local base = { label = label, title = title, page = page, layer = layer, sel = selected }
                if not (#spots > AREA_MIN and AddAreas(map, spots, base)) then
                    for _, spot in ipairs(spots) do
                        map:AcquirePin(TEMPLATE, { kind = "kill", label = label, note = L["Slain here"],
                            title = title, page = page, layer = layer, sel = selected }, spot[1], spot[2])
                    end
                end
            end
            -- A pin may carry its own note and its own entry to open (a fishing spot).
            for _, other in ipairs(others) do
                local pin = other[1]
                map:AcquirePin(TEMPLATE, { kind = pin[4], label = pin[5], note = pin.note, title = title,
                    page = page, layer = layer, sel = pin.sel or selected }, other[2], other[3])
            end
        end
    end
end

local function Refresh()
    if MapPins.ready and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end
MapPins.Refresh = Refresh

------------------------------------------------------------------------------
-- Pinning and unpinning
------------------------------------------------------------------------------

-- The book stays open beside the map: it drops one layer down so the map sits on top, and
-- comes back up when the map closes (or when a pin opens a page in it, see Book:Open).
local function BookBehind()
    local book = ns.Book.frame
    if book and book:IsShown() then
        book:SetFrameStrata("MEDIUM")
        book:Lower()
    end
end

local function BookInFront()
    local book = ns.Book.frame
    if book then book:SetFrameStrata("HIGH") end
end

local function Find(kind, id)
    for i, layer in ipairs(ns.db.mapLayers) do
        if layer.kind == kind and layer.id == id then return i end
    end
end

function MapPins.Has(kind, id)
    return Find(kind, id) ~= nil
end

-- Opens the world map on mapID, with the book left open behind it.
function MapPins.Open(mapID)
    if InCombatLockdown() or not WorldMapFrame then return false end
    BookBehind()
    if not (OpenWorldMap and pcall(OpenWorldMap, mapID)) then
        pcall(ShowUIPanel, WorldMapFrame)
        if mapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
    end
    Refresh()
    return true
end

-- Pins an entry and opens the world map on mapID (where the pins you asked to see are).
function MapPins.Show(kind, id, mapID)
    if not MapPins.ready then
        ns.Print(L["The world map isn't available to the book right now."])
        return
    end
    if not Find(kind, id) then table.insert(ns.db.mapLayers, { kind = kind, id = id }) end
    if not MapPins.Open(mapID) then
        ns.Print(L["Pinned to your map; open it once the fight is over."])
    end
end

function MapPins.Remove(kind, id)
    -- Your fishing spots come from a setting, so removing them switches it off.
    if kind == FISH_LAYER.kind then
        ns.db.settings.fishPins = false
        ns.Print(L["Took your fishing spots off your map (Settings can show them again)."])
        Refresh()
        return
    end
    local index = Find(kind, id)
    if not index then return end
    local ok, title = false, nil
    if builders[kind] then ok, title = pcall(builders[kind], id) end
    table.remove(ns.db.mapLayers, index)
    ns.Print(L["Took %s off your map."]:format((ok and title) or L["those pins"]))
    Refresh()
end

function MapPins.Clear()
    wipe(ns.db.mapLayers)
    ns.db.settings.fishPins = false
    ns.Print(L["Took all of the book's pins off your map."])
    Refresh()
end

------------------------------------------------------------------------------
-- Joining the world map
------------------------------------------------------------------------------

local function RegisterPool(template, Create)
    local pool = CreateUnsecuredRegionPoolInstance and CreateUnsecuredRegionPoolInstance(template)
        or CreateFramePool("FRAME")
    pool.parent = WorldMapFrame:GetCanvas()
    pool.createFunc = Create
    pool.resetFunc = function(_, pin)
        pin:Hide()
        pin:ClearAllPoints()
        pin:OnReleased()
        pin.pinTemplate = nil
        pin.owningMap = nil
    end
    pool.creationFunc, pool.resetterFunc = pool.createFunc, pool.resetFunc -- older names
    WorldMapFrame.pinPools[template] = pool
end

local function Setup()
    if MapPins.ready or not WorldMapFrame then return end
    RegisterPool(TEMPLATE, CreatePin)
    RegisterPool(AREA_TEMPLATE, CreateAreaPin)
    WorldMapFrame:AddDataProvider(provider)
    WorldMapFrame:HookScript("OnHide", BookInFront)
    MapPins.ready = true
end

local function TrySetup()
    local ok, err = pcall(Setup)
    if not ok then ns.Debug("World map pins unavailable: " .. tostring(err)) end
end

if WorldMapFrame then
    TrySetup()
else
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("ADDON_LOADED")
    waiter:SetScript("OnEvent", function(self, _, name)
        if name == "Blizzard_WorldMap" then
            self:UnregisterAllEvents()
            TrySetup()
        end
    end)
end
