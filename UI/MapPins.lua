local _, ns = ...
local UI = ns.UI

-- Captain's Log on the game's own world map. A Map button "projects" an entry (a quest, a
-- creature, a person, a land) onto it as pins, which stay until you right-click them away.
-- Pinned entries are saved in db.mapLayers as { kind, id } (kinds: questgiver, questfoes, mob,
-- npc, zone); their pins are rebuilt from the
-- journal each time the map draws, so they keep up with new kills.
--
-- The world map plumbing follows HereBeDragons-Pins: our own pin pool registered with the map
-- (no XML template needed) and a data provider the map asks for pins whenever it changes.

local TEMPLATE = "CaptainsLogMapPinTemplate"
local MapPins = {}
ns.MapPins = MapPins

------------------------------------------------------------------------------
-- What each kind of entry puts on the map: title, the book page it opens, and pins
-- { mapID, x, y, kind, label }. Icon pins come last so they draw over the dots.
------------------------------------------------------------------------------

local builders = {}

local function NpcName(id)
    local n = id and ns.db.npcs[id]
    return n and n.name
end

local function AddSpots(pins, m, label)
    for mapID, spots in pairs(m.spots or {}) do
        for _, s in ipairs(spots) do pins[#pins + 1] = { mapID, s[1], s[2], "kill", label } end
    end
end

-- A quest goes on the map in two separate sets, each from its own Map button: who to see
-- (giver and hand-in) and what to hunt (its creatures' kill spots).
local function QuestFoePins(q, pins)
    local seen = {}
    for i in ipairs(q.objectives or {}) do
        for _, f in ipairs(ns.ObjectiveFoes(q, i)) do
            if not seen[f.id] then
                seen[f.id] = true
                AddSpots(pins, f.mob, (f.mob.name or "?") .. (f.item and (", drops " .. f.item) or ""))
            end
        end
    end
end

local function QuestPeoplePins(q, pins)
    local m, x, y = ns.QuestStart(q)
    if m then pins[#pins + 1] = { m, x, y, "start", "Quest giver" .. (NpcName(q.giver) and (": " .. NpcName(q.giver)) or "") } end
    m, x, y = ns.QuestFinish(q)
    if m then pins[#pins + 1] = { m, x, y, "finish", "Handed in" .. (NpcName(q.turnInNpc) and (" to " .. NpcName(q.turnInNpc)) or "") } end
end

builders.questgiver = function(id)
    local q = ns.db.quests[id]
    if not q then return end
    local pins = {}
    QuestPeoplePins(q, pins)
    return (q.title or ("Quest #" .. id)) .. " (quest giver)", "quests", pins
end

builders.questfoes = function(id)
    local q = ns.db.quests[id]
    if not q then return end
    local pins = {}
    QuestFoePins(q, pins)
    return (q.title or ("Quest #" .. id)) .. " (creatures)", "quests", pins
end

-- Both at once: how 0.4.0 pinned quests, kept so those saved pins still show (and remove).
builders.quest = function(id)
    local q = ns.db.quests[id]
    if not q then return end
    local pins = {}
    QuestFoePins(q, pins)
    QuestPeoplePins(q, pins)
    return q.title or ("Quest #" .. id), "quests", pins
end

builders.mob = function(id)
    local m = ns.db.mobs[id]
    if not m then return end
    local pins = {}
    AddSpots(pins, m, m.name or "?")
    return m.name or "Unknown creature", "bestiary", pins
end

builders.npc = function(id)
    local n = ns.db.npcs[id]
    if not n or not n.mapID then return end
    return n.name or "Someone", "people",
        { { n.mapID, n.x, n.y, "npc", (n.name or "?") .. (n.title and (", " .. n.title) or "") } }
end

-- The wedge a picture looked across, on its own map: from the spot, the way you faced, as wide
-- as the camera sees, reaching the same share of the map's width as the book's close-up
-- (UI.CONE_SHARE). The map's size in yards keeps the angles true to the ground.
local function ConePoints(p)
    local ok, ww, wh = pcall(C_Map.GetMapWorldSize, p.mapID)
    if not ok or not ww or ww <= 0 or not wh or wh <= 0 then ww, wh = 1.5, 1 end
    local half = math.rad(math.max(25, math.min(60, (p.fov or 90) / 2)))
    local rx, ry = UI.CONE_SHARE, UI.CONE_SHARE * ww / wh
    local pts = { { p.x, p.y } }
    for k = 0, 6 do
        local a = p.facing - half + 2 * half * k / 6
        pts[#pts + 1] = { p.x - math.sin(a) * rx, p.y - math.cos(a) * ry }
    end
    return pts
end

-- One picture (by its time): a pin where it was taken, and its view cone. Clicking opens its day.
builders.photo = function(t)
    local p, day = ns.FindPhoto(t)
    if not p or not p.mapID or not p.x then return end
    local where = (p.place and p.zone and p.place ~= p.zone) and (p.place .. ", " .. p.zone) or p.place or p.zone or "a picture"
    local title = p.caption or ("Picture at " .. where)
    local pins = {}
    if p.facing then pins[#pins + 1] = { p.mapID, p.x, p.y, "cone", title, points = ConePoints(p) } end
    pins[#pins + 1] = { p.mapID, p.x, p.y, "place", title .. ", " .. date("%d %b, %H:%M", p.t) }
    return title, "log", pins, "photos:" .. day
end

builders.zone = function(name)
    local z = ns.db.zones[name]
    if not z then return end
    local pins = {}
    for _, n in pairs(ns.db.npcs) do
        if n.zone == name and n.mapID and next(n.roles) then
            pins[#pins + 1] = { n.mapID, n.x, n.y, "npc", (n.name or "?") .. (n.title and (", " .. n.title) or "") }
        end
    end
    for _, d in ipairs(ns.db.deaths) do
        if d.zone == name and d.mapID then
            pins[#pins + 1] = { d.mapID, d.x, d.y, "death", (d.killer and ("Slain by " .. d.killer) or "Died") .. ", " .. ns.Date(d.time) }
        end
    end
    for place, p in pairs(z.places or {}) do
        if p.mapID then pins[#pins + 1] = { p.mapID, p.x, p.y, "place", place .. ", found " .. ns.Date(p.t) } end
    end
    return name, "zones", pins
end

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
        local info = C_Map.GetMapInfo(id)
        id = info and info.parentMapID
    end
    ancestry[mapID] = set
    return set
end

-- Where a spot recorded on map `from` falls on map `to`, or nil. Only on its own map, the maps
-- above it (zone, continent) and the maps inside it (a cave): zone rectangles overlap, so a
-- plain conversion would also put Elwynn's pins along the edge of Westfall.
local function Place(from, x, y, to)
    if not (from and x and y) then return end
    if from == to then return x, y end
    if not (Ancestors(from)[to] or Ancestors(to)[from]) then return end
    local info = C_Map.GetMapInfo(to)
    if not info or (info.mapType or 0) < 2 then return end -- not on the world or cosmic maps
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, from, CreateVector2D(x, y))
    if not ok or not continent or not world then return end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, world, to)
    if not ok2 or not pos then return end
    local px, py = pos:GetXY()
    if not px or px < 0 or px > 1 or py < 0 or py > 1 then return end
    return px, py
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
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(d.label)
    if d.note then GameTooltip:AddLine(d.note, 1, 1, 1) end
    GameTooltip:AddLine("Captain's Log: " .. d.title, 0.85, 0.75, 0.55)
    -- Hunting areas let left-clicks through to the map, so only the dots open the book.
    if not d.area then GameTooltip:AddLine("Click to open it in the book", 0.6, 0.6, 0.6) end
    GameTooltip:AddLine("Right-click to remove these pins", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Shift-right-click to remove all of the book's pins", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function pinMixin:OnMouseLeave()
    GameTooltip:Hide()
end

-- upInside is false when the button was released off the pin; older maps don't pass it.
function pinMixin:OnMouseUp(button, upInside)
    local d = self.data
    if not d or upInside == false then return end
    GameTooltip:Hide()
    if button == "RightButton" then
        if IsShiftKeyDown() then MapPins.Clear() else MapPins.Remove(d.layer.kind, d.layer.id) end
    elseif button == "LeftButton" then
        ns.Book:Goto(d.page, d.sel or d.layer.id)
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

function pinMixin:OnAcquired(data, x, y)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    self:SetPosition(x, y)
    self.data = data
    local atlas = UI.PIN_ATLAS[data.kind]
    local iconic = atlas and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
    if iconic then self.icon:SetAtlas(atlas) end
    self.icon:SetShown(iconic)
    self.rim:SetShown(not iconic)
    self.fill:SetShown(not iconic)
    local c = UI.PIN[data.kind] or UI.PIN.kill
    self.fill:SetColorTexture(c[1], c[2], c[3], 1)
    self:SetSize(iconic and 24 or 10, iconic and 24 or 10)
    self:Show()
end

function pinMixin:OnReleased()
    self.data = nil
end

------------------------------------------------------------------------------
-- Hunting areas: a creature slain often on one map is drawn as the ground you hunted it on.
-- Kills close together form a cluster; each cluster becomes the shape around its points
-- (padded, so a lone kill is a small patch), filled and outlined. The shapes are part of the
-- map, so they zoom with it, and they let left-clicks through so the map can still be dragged
-- and clicked beneath them; hover and right-click still reach them.
------------------------------------------------------------------------------

local AREA_TEMPLATE = "CaptainsLogMapAreaTemplate"
local AREA_MIN = 15     -- more kills than this on the map being viewed, and it's drawn as areas
local AREA_LINK = 0.06  -- kills closer than this (share of map width) share a hunting ground
local AREA_PAD = 0.012  -- how far the shape reaches past its outermost kills
local PAD_STEPS = 8     -- points around each kill when padding: an octagon, near enough round

-- Texture corners, for drawing triangles by moving them (Texture:SetVertexOffset).
local UL, LL, UR, LR = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2, UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4

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

-- A filled triangle in the pin's own coordinates (x right, y down from its top-left): a plain
-- texture over the triangle's bounding box, with its corners moved onto the three points
-- (the fourth folded onto the third).
local function Triangle(pin, i, ax, ay, bx, by, cx, cy, r, g, b, a)
    local t = pin.tris[i]
    if not t then
        t = pin:CreateTexture(nil, "ARTWORK")
        pin.tris[i] = t
    end
    local minX, maxX = math.min(ax, bx, cx), math.max(ax, bx, cx)
    local minY, maxY = math.min(ay, by, cy), math.max(ay, by, cy)
    maxX, maxY = math.max(maxX, minX + 0.01), math.max(maxY, minY + 0.01)
    t:SetColorTexture(r, g, b, a)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", pin, "TOPLEFT", minX, -minY)
    t:SetSize(maxX - minX, maxY - minY)
    -- Offsets are from each corner's own place, with y pointing up.
    t:SetVertexOffset(UL, ax - minX, -(ay - minY))
    t:SetVertexOffset(LL, bx - minX, -(by - maxY))
    t:SetVertexOffset(UR, cx - maxX, -(cy - minY))
    t:SetVertexOffset(LR, cx - maxX, -(cy - maxY))
    t:Show()
end

local function Edge(pin, i, ax, ay, bx, by, r, g, b, a)
    local l = pin.lines[i]
    if not l then
        l = pin:CreateLine(nil, "OVERLAY")
        pin.lines[i] = l
    end
    l:SetThickness(1.5)
    l:SetColorTexture(r, g, b, a)
    l:SetStartPoint("TOPLEFT", pin, ax, -ay)
    l:SetEndPoint("TOPLEFT", pin, bx, -by)
    l:Show()
end

function areaMixin:OnAcquired(data, x, y)
    self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
    -- No scaling limits: the area keeps its size on the map, not on screen.
    self.scaleFactor, self.startScale, self.endScale = nil, nil, nil
    if self.SetIgnoreGlobalPinScale then self:SetIgnoreGlobalPinScale(true) end
    self:SetPosition(x, y)
    self:SetSize(data.w, data.h)
    self.data = data

    -- A fan of triangles from the middle fills the (convex) shape; lines trace its edge.
    local hull, n = data.hull, #data.hull
    local mx, my = 0, 0
    for _, p in ipairs(hull) do mx, my = mx + p[1], my + p[2] end
    mx, my = mx / n, my / n
    local c = data.color or UI.PIN.kill
    for i = 1, n do
        local p, q = hull[i], hull[i % n + 1]
        Triangle(self, i, mx, my, p[1], p[2], q[1], q[2], c[1], c[2], c[3], data.alpha)
        Edge(self, i, p[1], p[2], q[1], q[2], c[1] * 0.7, c[2] * 0.7, c[3] * 0.7, 0.85)
    end
    for i = n + 1, #self.tris do self.tris[i]:Hide() end
    for i = n + 1, #self.lines do self.lines[i]:Hide() end
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
local function Clusters(spots, W, H)
    local link = (AREA_LINK * W) ^ 2
    local parent = {}
    for i = 1, #spots do parent[i] = i end
    local function root(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    for i = 1, #spots do
        for j = i + 1, #spots do
            local dx, dy = (spots[i][1] - spots[j][1]) * W, (spots[i][2] - spots[j][2]) * H
            if dx * dx + dy * dy <= link then parent[root(i)] = root(j) end
        end
    end
    local groups, list = {}, {}
    for i, s in ipairs(spots) do
        local r = root(i)
        if not groups[r] then
            groups[r] = {}
            list[#list + 1] = groups[r]
        end
        table.insert(groups[r], s)
    end
    return list
end

-- The convex hull of points { x, y } (monotone chain), counter-clockwise.
local function Hull(points)
    table.sort(points, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    if #points < 3 then return points end
    local function cross(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
    local lower, upper = {}, {}
    for _, p in ipairs(points) do
        while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do table.remove(lower) end
        lower[#lower + 1] = p
    end
    for i = #points, 1, -1 do
        local p = points[i]
        while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do table.remove(upper) end
        upper[#upper + 1] = p
    end
    table.remove(lower)
    table.remove(upper)
    for _, p in ipairs(upper) do lower[#lower + 1] = p end
    return lower
end

-- Draws one creature's kills (already on this map) as hunting areas.
local function AddAreas(map, spots, base)
    local W, H = map:GetCanvas():GetSize()
    if not W or W == 0 or not H or H == 0 then return false end
    local groups = Clusters(spots, W, H)
    local most = 0
    for _, g in ipairs(groups) do most = math.max(most, #g) end
    local pad = AREA_PAD * W
    for _, g in ipairs(groups) do
        -- Work in canvas units so the padding is round on screen, not stretched.
        local points = {}
        for _, s in ipairs(g) do
            for k = 0, PAD_STEPS - 1 do
                local angle = k * 2 * math.pi / PAD_STEPS
                points[#points + 1] = { s[1] * W + pad * math.cos(angle), s[2] * H + pad * math.sin(angle) }
            end
        end
        local hull = Hull(points)
        local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
        for _, p in ipairs(hull) do
            minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
            minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
        end
        local shape = {}
        for i, p in ipairs(hull) do shape[i] = { p[1] - minX, p[2] - minY } end
        map:AcquirePin(AREA_TEMPLATE, {
            area = true, label = base.label, title = base.title, page = base.page, layer = base.layer,
            sel = base.sel, note = #g .. (#g == 1 and " slain here" or " slain in this area"),
            alpha = 0.16 + 0.22 * (#g / most),
            hull = shape, w = maxX - minX, h = maxY - minY,
        }, (minX + maxX) / 2 / W, (minY + maxY) / 2 / H)
    end
    return true
end

-- A picture's view cone: the wedge from where it was taken (p.points, on the picture's map),
-- drawn as a gold area on the map being viewed. Points off this map are dropped.
local function AddCone(map, mapID, p, base)
    local W, H = map:GetCanvas():GetSize()
    if not W or W == 0 or not H or H == 0 then return end
    local pts = {}
    for _, q in ipairs(p.points or {}) do
        local x, y = Place(p[1], q[1], q[2], mapID)
        if x then pts[#pts + 1] = { x * W, y * H } end
    end
    if #pts < 3 then return end
    local hull = Hull(pts)
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, q in ipairs(hull) do
        minX, maxX = math.min(minX, q[1]), math.max(maxX, q[1])
        minY, maxY = math.min(minY, q[2]), math.max(maxY, q[2])
    end
    local shape = {}
    for i, q in ipairs(hull) do shape[i] = { q[1] - minX, q[2] - minY } end
    map:AcquirePin(AREA_TEMPLATE, {
        area = true, label = base.label, title = base.title, page = base.page, layer = base.layer, sel = base.sel,
        note = "What the picture looked at", alpha = 0.3, color = UI.PIN.place,
        hull = shape, w = math.max(1, maxX - minX), h = math.max(1, maxY - minY),
    }, (minX + maxX) / 2 / W, (minY + maxY) / 2 / H)
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
    for _, layer in ipairs(ns.db.mapLayers) do
        local build = builders[layer.kind]
        local ok, title, page, pins, sel = false, nil, nil, nil, nil
        if build then ok, title, page, pins, sel = pcall(build, layer.id) end
        if ok and pins then
            -- sel: what a pin's click opens in the book (the entry itself unless the builder says).
            sel = sel or layer.id
            local kills, order, others = {}, {}, {}
            for _, p in ipairs(pins) do
                if p[4] == "cone" then
                    AddCone(map, mapID, p, { label = p[5], title = title, page = page, layer = layer, sel = sel })
                else
                    local x, y = Place(p[1], p[2], p[3], mapID)
                    if x then
                        if p[4] == "kill" then
                            if not kills[p[5]] then
                                kills[p[5]] = {}
                                order[#order + 1] = p[5]
                            end
                            table.insert(kills[p[5]], { x, y })
                        else
                            others[#others + 1] = { p, x, y }
                        end
                    end
                end
            end
            for _, label in ipairs(order) do
                local spots = kills[label]
                local base = { label = label, title = title, page = page, layer = layer, sel = sel }
                if not (#spots > AREA_MIN and AddAreas(map, spots, base)) then
                    for _, s in ipairs(spots) do
                        map:AcquirePin(TEMPLATE, { kind = "kill", label = label, note = "Slain here",
                            title = title, page = page, layer = layer, sel = sel }, s[1], s[2])
                    end
                end
            end
            for _, o in ipairs(others) do
                map:AcquirePin(TEMPLATE, { kind = o[1][4], label = o[1][5], title = title, page = page,
                    layer = layer, sel = sel }, o[2], o[3])
            end
        end
    end
end

local function Refresh()
    if MapPins.ready and WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

------------------------------------------------------------------------------
-- Pinning and unpinning
------------------------------------------------------------------------------

-- The book stays open beside the map: it drops one layer down so the map sits on top, and
-- comes back up when the map closes (or when a pin opens a page in it, see Book:Open).
local function BookBehind()
    local f = ns.Book.frame
    if f and f:IsShown() then
        f:SetFrameStrata("MEDIUM")
        f:Lower()
    end
end

local function BookInFront()
    local f = ns.Book.frame
    if f then f:SetFrameStrata("HIGH") end
end

local function Find(kind, id)
    for i, l in ipairs(ns.db.mapLayers) do
        if l.kind == kind and l.id == id then return i end
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
        ns.Print("The world map isn't available to the book right now.")
        return
    end
    if not Find(kind, id) then table.insert(ns.db.mapLayers, { kind = kind, id = id }) end
    if not MapPins.Open(mapID) then
        ns.Print("Pinned to your map; open it once the fight is over.")
    end
end

function MapPins.Remove(kind, id)
    local i = Find(kind, id)
    if not i then return end
    local ok, title = false, nil
    if builders[kind] then ok, title = pcall(builders[kind], id) end
    table.remove(ns.db.mapLayers, i)
    ns.Print("Took " .. ((ok and title) or "those pins") .. " off your map.")
    Refresh()
end

function MapPins.Clear()
    wipe(ns.db.mapLayers)
    ns.Print("Took all of the book's pins off your map.")
    Refresh()
end

------------------------------------------------------------------------------
-- Joining the world map
------------------------------------------------------------------------------

local function RegisterPool(template, create)
    local pool = CreateUnsecuredRegionPoolInstance and CreateUnsecuredRegionPoolInstance(template)
        or CreateFramePool("FRAME")
    pool.parent = WorldMapFrame:GetCanvas()
    pool.createFunc = create
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
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, _, name)
        if name == "Blizzard_WorldMap" then
            self:UnregisterAllEvents()
            TrySetup()
        end
    end)
end
