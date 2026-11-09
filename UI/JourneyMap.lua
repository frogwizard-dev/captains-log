local _, ns = ...
local L = ns.L
local UI = ns.UI

-- The journey map: a day's route (Journey.lua) played back on the game's world map, with a
-- control bar along the map's foot: the day, play/pause and speed, "whole path", and a time bar
-- to click or drag through the day. The route so far is drawn solid, the rest faintly; a marker
-- sits where you were at that moment, and things from the log that happened by then show as
-- small icons where they happened (hover one for its line in the book).
--
-- Drawn the way FrogLib.Lines draws (lines on the map's canvas, from world positions), but by
-- hand: each piece of the route keeps its own line, placed once whenever the map or its zoom
-- changes, so scrubbing only shows, hides or recolours the pieces that changed instead of
-- placing every line again. Redraws are held to about 20 a second, and nothing runs while the
-- bar is closed or the map is shut.
--
-- Nothing here touches the map's protected parts: the lines and icons are plain frames on its
-- canvas (not map pins, which can be blocked in combat), and the map is only opened or moved to
-- another zone out of combat.

local JM = {}
ns.JourneyMap = JM

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SPEEDS = { { 60, "1x" }, { 300, "5x" }, { 1200, "20x" }, { 6000, "100x" } } -- game seconds per second
local GAP = 300          -- seconds without a point: playback jumps straight over it
local MAX_POINTS = 8000  -- "All days" is thinned to about this many points
local MAX_TICKS = 400
local FRAME = 0.05       -- seconds between redraws (20 a second)
local PAST = { 0.85, 0.15, 0.08, 0.95 }
local FUTURE = { 0.85, 0.15, 0.08, 0.22 }
local WIDTH = 3          -- line width on screen, in pixels
local ICON = 16          -- event icon size on screen

-- Each kind of log entry's icon on the map: a file, an atlas, or a function of the entry.
local function ItemIcon(ev) return UI.ItemIcon(ev.id) end
local function SpellIcon(ev)
    if not ev.id then return "Interface\\Icons\\INV_Misc_Book_09" end
    local fn = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
    local ok, tex = false, nil
    if fn then ok, tex = pcall(fn, ev.id) end
    return (ok and tex) or "Interface\\Icons\\INV_Misc_Book_09"
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
}
-- Tick colours on the time bar.
local TICK = {
    level = { 0.95, 0.75, 0.20 }, death = { 0.10, 0.10, 0.10 }, boss = { 0.85, 0.15, 0.08 },
    quest = { 0.95, 0.85, 0.30 }, firstitem = { 0.40, 0.65, 1.00 }, milestone = { 0.95, 0.75, 0.20 },
}

local function HasAtlas(name)
    return name and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------

local S = {
    days = {},        -- day keys with a route or placed entries, oldest first
    index = 0,        -- which of them (0 = all days)
    pts = {},         -- flat points { t, x = west, y = north, inst, map, seg }
    times = {},       -- pts[i].t, for the binary search
    events = {},      -- { ev, key } entries of the range, by time
    t0 = 0, t1 = 0,   -- the range's span
    cur = 0,          -- the moment shown
    playing = false,
    speed = 1,
    whole = true,     -- the whole route drawn (no playback)
}
JM.state = S

-- Days worth showing: a route, or entries that say where they happened.
local function CollectDays()
    local list = {}
    for key, d in pairs(ns.db.days) do
        local any = d.path and #d.path > 0
        if not any then
            for _, ev in ipairs(d.events or {}) do
                if ev.pi then
                    any = true
                    break
                end
            end
        end
        if any then list[#list + 1] = key end
    end
    table.sort(list)
    S.days = list
end

-- The points of one day (or all of them), with segment numbers unique across days.
local function Load()
    local keys = {}
    if S.index == 0 then
        for _, k in ipairs(S.days) do keys[#keys + 1] = k end
    elseif S.days[S.index] then
        keys[1] = S.days[S.index]
    end
    local pts, events, offset = {}, {}, 0
    for _, key in ipairs(keys) do
        local day = ns.db.days[key]
        local flat = ns.Journey.Decode(key)
        local top = 0
        for _, p in ipairs(flat) do
            top = math.max(top, p.seg)
            p.seg = p.seg + offset
            pts[#pts + 1] = p
        end
        offset = offset + top
        for _, ev in ipairs(day and day.events or {}) do
            if ev.t then events[#events + 1] = { ev = ev, key = key } end
        end
    end
    -- A long range is thinned: a point is kept once it's far enough from the last one kept.
    if #pts > MAX_POINTS then
        local step = 20
        local kept
        repeat
            kept = {}
            local last
            for i, p in ipairs(pts) do
                if not last or p.seg ~= last.seg or i == #pts
                    or (p.x - last.x) ^ 2 + (p.y - last.y) ^ 2 >= step * step then
                    kept[#kept + 1] = p
                    last = p
                end
            end
            step = step * 2
        until #kept <= MAX_POINTS or step > 5000
        pts = kept
    end
    table.sort(events, function(a, b) return a.ev.t < b.ev.t end)
    local times = {}
    for i, p in ipairs(pts) do times[i] = p.t end
    S.pts, S.times, S.events = pts, times, events
    local t0, t1 = pts[1] and pts[1].t, pts[#pts] and pts[#pts].t
    if events[1] then
        t0 = math.min(t0 or events[1].ev.t, events[1].ev.t)
        t1 = math.max(t1 or events[#events].ev.t, events[#events].ev.t)
    end
    S.t0, S.t1 = t0 or 0, t1 or 0
    if S.t1 <= S.t0 then S.t1 = S.t0 + 1 end
    S.cur = S.t1
    S.playing, S.whole = false, true
end

-- The last point at or before t (0 if none): a binary search.
local function Find(t)
    local times = S.times
    local lo, hi = 1, #times
    if hi == 0 or t < times[1] then return 0 end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if times[mid] <= t then lo = mid else hi = mid - 1 end
    end
    return lo
end

------------------------------------------------------------------------------
-- Drawing on the map's canvas
------------------------------------------------------------------------------

local holder, marker
local lines, head = {}, nil
local L_END = {}      -- per line: the index of the point it ends at
local U, V = {}, {}   -- per point: where it falls on the map shown (0-1), or nil
local icons = {}      -- per placed entry on this map: { frame, t }
local nLines, nIcons = 0, 0
local lastK            -- lines drawn as "past" last time
local mapInst, layoutDirty, dirty = nil, true, true

local instCache = {}
-- The instance (continent) a map shows, by asking where its middle lies in the world.
local function MapInstance(mapID)
    if not mapID then return end
    local v = instCache[mapID]
    if v ~= nil then return v or nil end
    v = false
    if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local ok, inst = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0.5, 0.5))
        if ok and type(inst) == "number" and not ns.issecret(inst) then v = inst end
    end
    instCache[mapID] = v
    return v or nil
end

local function ToMap(inst, north, west, mapID)
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, inst, CreateVector2D(north, west), mapID)
    if ok and pos then return pos:GetXY() end
end

local function Strip(text)
    -- Parchment inks read badly on a dark tooltip.
    for _, ink in ipairs({ "7a1f0d", "6b5d4f", "2e1d0c", "1d4f8c", "8a6d4a" }) do
        text = text:gsub("|cff" .. ink, "|cffffd100")
    end
    return text
end

local function IconEnter(f)
    local e = f.entry
    if not e then return end
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    GameTooltip:SetText(date(S.index == 0 and L["%d %b %Y, %H:%M"] or "%H:%M", e.ev.t))
    local line = ns.LogLine and ns.LogLine(e.ev, e.key)
    if line then GameTooltip:AddLine(Strip(line), 1, 1, 1, true) end
    GameTooltip:AddLine(L["Captain's Log: journey map"], 0.85, 0.75, 0.55)
    GameTooltip:Show()
end

local function SetIconTexture(tex, ev)
    local spec = ICONS[ev.k]
    tex:SetTexCoord(0, 1, 0, 1)
    if type(spec) == "function" then
        tex:SetTexture(spec(ev))
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif type(spec) == "table" then
        if HasAtlas(spec.atlas) then tex:SetAtlas(spec.atlas) else tex:SetTexture(spec.file) end
    else
        tex:SetTexture(spec)
        if spec and spec:find("Icons") then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    end
end

local function EnsureHolder(canvas)
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

local function TakeLine(i)
    local l = lines[i]
    if not l then
        l = holder:CreateLine(nil, "OVERLAY", nil, 1)
        l:SetTexture(WHITE)
        lines[i] = l
    end
    return l
end

local function TakeIcon(i)
    local f = icons[i]
    if not f then
        f = CreateFrame("Frame", nil, holder)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        -- Hover only: clicks and drags go through to the map.
        pcall(f.SetMouseMotionEnabled, f, true)
        pcall(f.SetMouseClickEnabled, f, false)
        f:SetScript("OnEnter", IconEnter)
        f:SetScript("OnLeave", GameTooltip_Hide)
        icons[i] = f
    end
    return f
end

-- Places every piece of the route and every entry on the map being shown. Runs when the map,
-- its zoom or the range changes.
local function Layout()
    layoutDirty = false
    lastK = nil
    local canvas = Canvas()
    if not canvas then return end
    EnsureHolder(canvas)
    holder:SetFrameLevel(canvas:GetFrameLevel() + 2100)
    marker:SetFrameLevel(holder:GetFrameLevel() + 20)
    local mapID = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local inst = MapInstance(mapID)
    mapInst = inst
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    local sc = WorldMapFrame.ScrollContainer
    local scale = (sc.GetCanvasScale and sc:GetCanvasScale()) or 1
    if scale <= 0 then scale = 1 end
    local pts = S.pts
    wipe(U)
    wipe(V)
    if inst and W > 0 then
        for i, p in ipairs(pts) do
            if p.inst == inst then U[i], V[i] = ToMap(inst, p.y, p.x, mapID) end
        end
    end
    local n = 0
    for i = 1, #pts - 1 do
        if U[i] and U[i + 1] and pts[i].seg == pts[i + 1].seg then
            n = n + 1
            local l = TakeLine(n)
            l:SetThickness(WIDTH / scale)
            l:SetStartPoint("TOPLEFT", canvas, U[i] * W, -V[i] * H)
            l:SetEndPoint("TOPLEFT", canvas, U[i + 1] * W, -V[i + 1] * H)
            l:Show()
            L_END[n] = i + 1
        end
    end
    for i = n + 1, #lines do lines[i]:Hide() end
    nLines = n
    head:SetThickness(WIDTH / scale)

    -- Entries that say where they happened, on this continent.
    local m = 0
    if inst and W > 0 then
        for _, e in ipairs(S.events) do
            local ev = e.ev
            if ev.pi == inst and ev.py and ev.px and ICONS[ev.k] then
                local u, v = ToMap(inst, ev.py, ev.px, mapID)
                if u then
                    m = m + 1
                    local f = TakeIcon(m)
                    f.entry, f.t, f.on = e, ev.t, nil
                    SetIconTexture(f.tex, ev)
                    f:SetSize(ICON / scale, ICON / scale)
                    f:ClearAllPoints()
                    f:SetPoint("CENTER", canvas, "TOPLEFT", u * W, -v * H)
                    f:SetFrameLevel(holder:GetFrameLevel() + 10)
                end
            end
        end
    end
    for i = m + 1, #icons do
        icons[i]:Hide()
        icons[i].entry = nil
    end
    nIcons = m
    marker:SetSize(22 / scale, 22 / scale)
    dirty = true
end

-- The number of route pieces that end at or before point `idx`.
local function LinesUpTo(idx)
    local lo, hi = 0, nLines
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if L_END[mid] <= idx then lo = mid else hi = mid - 1 end
    end
    return lo
end

local function Paint(l, c) l:SetVertexColor(c[1], c[2], c[3], c[4]) end

-- Where you were at time t on the map shown: u, v, and the way you were heading (or nil).
local function Position(t)
    local idx = Find(t)
    local pts = S.pts
    if idx == 0 then
        if U[1] then return U[1], V[1], nil, 0 end
        return nil, nil, nil, 0
    end
    if not U[idx] then return nil, nil, nil, idx end
    local nxt = idx + 1
    if pts[nxt] and U[nxt] and pts[nxt].seg == pts[idx].seg and pts[nxt].t > pts[idx].t then
        local f = math.max(0, math.min(1, (t - pts[idx].t) / (pts[nxt].t - pts[idx].t)))
        return U[idx] + (U[nxt] - U[idx]) * f, V[idx] + (V[nxt] - V[idx]) * f, nxt, idx
    end
    return U[idx], V[idx], nil, idx
end

local function Draw()
    dirty = false
    if not holder then return end
    local canvas = Canvas()
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    local idx = Find(S.cur)
    local k = S.whole and nLines or LinesUpTo(idx)
    -- Only the pieces whose side of "now" changed are recoloured.
    if not lastK then
        for i = 1, nLines do Paint(lines[i], i <= k and PAST or FUTURE) end
    elseif k > lastK then
        for i = lastK + 1, k do Paint(lines[i], PAST) end
    elseif k < lastK then
        for i = k + 1, lastK do Paint(lines[i], FUTURE) end
    end
    lastK = k

    local u, v, nxt, at = Position(S.cur)
    if S.whole then u = nil end
    if u then
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", canvas, "TOPLEFT", u * W, -v * H)
        marker:Show()
        -- The piece being walked, drawn up to the marker.
        if nxt and U[at] then
            head:SetStartPoint("TOPLEFT", canvas, U[at] * W, -V[at] * H)
            head:SetEndPoint("TOPLEFT", canvas, u * W, -v * H)
            Paint(head, PAST)
            head:Show()
            local dx, dy = (U[nxt] - U[at]) * W, (V[nxt] - V[at]) * H
            if dx ~= 0 or dy ~= 0 then marker.tex:SetRotation(-math.atan2(dx, -dy)) end
        else
            head:Hide()
        end
    else
        marker:Hide()
        head:Hide()
    end

    for i = 1, nIcons do
        local f = icons[i]
        local on = S.whole or f.t <= S.cur
        if on ~= f.on then
            f:SetShown(on)
            f.on = on
        end
    end
end

------------------------------------------------------------------------------
-- The control bar
------------------------------------------------------------------------------

local bar, toggle

local function SpanText(t)
    if S.index == 0 then return date(L["%d %b, %H:%M"], t) end
    return date("%H:%M", t)
end

local function DayLabel()
    if S.index == 0 then return L["All days"] end
    local key = S.days[S.index]
    return key and date(L["%a %d %b %Y"], ns.DayTime(key)) or ""
end

local function UpdateTicks()
    local track = bar.track
    local w = track:GetWidth()
    local ticks = bar.ticks
    local n = 0
    local events = S.events
    local step = math.max(1, math.ceil(#events / MAX_TICKS))
    local span = S.t1 - S.t0
    if w > 0 and span > 0 then
        for i = 1, #events, step do
            local ev = events[i].ev
            n = n + 1
            local t = ticks[n]
            if not t then
                t = track:CreateTexture(nil, "ARTWORK", nil, 2)
                t:SetWidth(1)
                ticks[n] = t
            end
            local c = TICK[ev.k] or { 0.9, 0.82, 0.62 }
            local big = TICK[ev.k] ~= nil
            t:SetColorTexture(c[1], c[2], c[3], big and 1 or 0.55)
            t:SetHeight(big and 14 or 8)
            t:ClearAllPoints()
            t:SetPoint("CENTER", track, "LEFT", (ev.t - S.t0) / span * w, 0)
            t:Show()
        end
    end
    for i = n + 1, #ticks do ticks[i]:Hide() end
end

local function UpdateBar()
    if not bar then return end
    bar.day:SetText(DayLabel())
    bar.play:SetText(S.playing and L["Pause"] or L["Play"])
    bar.speed:SetText(SPEEDS[S.speed][2])
    bar.whole:SetEnabled(not S.whole or S.playing)
    local w = bar.track:GetWidth()
    local f = (S.cur - S.t0) / (S.t1 - S.t0)
    f = math.max(0, math.min(1, f))
    bar.fill:SetWidth(math.max(0.01, w * f))
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("CENTER", bar.track, "LEFT", w * f, 0)
    if #S.pts == 0 and #S.events == 0 then
        bar.time:SetText(L["Nothing"])
    else
        bar.time:SetText(SpanText(S.cur))
    end
end

local function SetCur(t)
    S.cur = math.max(S.t0, math.min(S.t1, t))
    dirty = true
    UpdateBar()
end

-- Moves the map to where the range starts if the map shown doesn't hold any of it (out of
-- combat only).
local function FitMap()
    if InCombatLockdown() or not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
    local inst = MapInstance(WorldMapFrame:GetMapID())
    local first
    for _, p in ipairs(S.pts) do
        if p.inst == inst then return end
        first = first or p
    end
    if first and first.map then pcall(WorldMapFrame.SetMapID, WorldMapFrame, first.map) end
end

local function SelectDay(index)
    S.index = index
    Load()
    layoutDirty = true
    FitMap()
    if bar then
        UpdateTicks()
        UpdateBar()
    end
end

local function Step(delta)
    local n = #S.days
    local i = S.index + delta
    if i < 0 then i = n end
    if i > n then i = 0 end
    SelectDay(i)
end

local elapsed = 0
local function OnUpdate(_, dt)
    if S.dragging then
        local x = GetCursorPosition() / bar.track:GetEffectiveScale()
        local left, w = bar.track:GetLeft(), bar.track:GetWidth()
        if left and w > 0 then SetCur(S.t0 + (x - left) / w * (S.t1 - S.t0)) end
    elseif S.playing then
        local t = S.cur + dt * SPEEDS[S.speed][1]
        -- Long gaps (logged off, a loading screen) are jumped over.
        local idx = Find(t)
        local times = S.times
        if idx == 0 and times[1] and t < times[1] then
            t = times[1]
        elseif idx > 0 and times[idx + 1] and times[idx + 1] - times[idx] > GAP then
            t = times[idx + 1]
        end
        if t >= S.t1 then
            t = S.t1
            S.playing = false
        end
        SetCur(t)
    end
    elapsed = elapsed + dt
    if elapsed < FRAME then return end
    elapsed = 0
    if layoutDirty then pcall(Layout) end
    if dirty then pcall(Draw) end
end

local function SmallButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 20)
    b:SetText(text)
    return b
end

local function Tip(b, title, text)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
end

local function ArrowButton(parent, dir)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-"
    b:SetNormalTexture(base .. "Up")
    b:SetPushedTexture(base .. "Down")
    b:SetDisabledTexture(base .. "Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return b
end

local function BuildBar()
    local sc = WorldMapFrame.ScrollContainer
    bar = CreateFrame("Frame", "CaptainsLogJourneyBar", WorldMapFrame, "BackdropTemplate")
    bar:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", 8, 8)
    bar:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", -8, 8)
    bar:SetHeight(58)
    bar:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    bar:SetBackdropColor(0.10, 0.06, 0.03, 0.88)
    bar:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    bar:EnableMouse(true)
    bar:Hide()

    local prev = ArrowButton(bar, "Prev")
    prev:SetPoint("TOPLEFT", 8, -6)
    prev:SetScript("OnClick", function() Step(-1) end)
    Tip(prev, L["Previous day"])
    bar.day = UI.Text(bar, 12, { 0.98, 0.9, 0.7 })
    bar.day:SetWidth(130)
    bar.day:SetJustifyH("CENTER")
    bar.day:SetPoint("LEFT", prev, "RIGHT", 2, 0)
    local nxt = ArrowButton(bar, "Next")
    nxt:SetPoint("LEFT", bar.day, "RIGHT", 2, 0)
    nxt:SetScript("OnClick", function() Step(1) end)
    Tip(nxt, L["Next day"], L["Past the last day comes \"All days\"."])

    bar.play = SmallButton(bar, L["Play"], 64)
    bar.play:SetPoint("LEFT", nxt, "RIGHT", 10, 0)
    bar.play:SetScript("OnClick", function()
        if S.playing then
            S.playing = false
        else
            if S.whole or S.cur >= S.t1 then SetCur(S.t0) end
            S.whole, S.playing = false, true
            dirty = true
        end
        UpdateBar()
    end)
    bar.speed = SmallButton(bar, "1x", 48)
    bar.speed:SetPoint("LEFT", bar.play, "RIGHT", 4, 0)
    bar.speed:SetScript("OnClick", function()
        S.speed = S.speed % #SPEEDS + 1
        UpdateBar()
    end)
    Tip(bar.speed, L["Speed"], L["1x plays a minute of the day each second; click for 5x, 20x and 100x."])
    bar.whole = SmallButton(bar, L["Whole route"], 100)
    bar.whole:SetPoint("LEFT", bar.speed, "RIGHT", 4, 0)
    bar.whole:SetScript("OnClick", function()
        S.whole, S.playing = true, false
        SetCur(S.t1)
    end)
    Tip(bar.whole, L["Whole route"], L["Stops playing and draws the whole route, with everything that happened along it."])

    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() JM.Close() end)

    local title = UI.Text(bar, 11, { 0.85, 0.75, 0.55 }, UI.HEADING_FONT)
    title:SetPoint("RIGHT", close, "LEFT", -4, 0)
    title:SetText(L["Journey map"])

    -- The time bar: click to jump, drag to scrub.
    bar.time = UI.Text(bar, 12, { 0.98, 0.9, 0.7 })
    bar.time:SetPoint("BOTTOMRIGHT", -10, 9)
    bar.time:SetWidth(90)
    bar.time:SetJustifyH("RIGHT")
    local hit = CreateFrame("Frame", nil, bar)
    hit:SetPoint("BOTTOMLEFT", 10, 4)
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
    bar.ticks = {}
    hit:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        S.dragging, S.playing, S.whole = true, false, false
        lastK = nil
        UpdateBar()
    end)
    hit:SetScript("OnMouseUp", function() S.dragging = false end)
    hit:SetScript("OnHide", function() S.dragging = false end)
    hit:SetScript("OnSizeChanged", function()
        UpdateTicks()
        UpdateBar()
    end)
    Tip(hit, L["Time bar"], L["Click to jump to a moment, or drag to go back and forth. The marks are things written in the log."])

    bar:SetScript("OnUpdate", OnUpdate)
    bar:SetScript("OnShow", function()
        layoutDirty = true
        if holder then holder:Show() end
    end)
    bar:SetScript("OnHide", function()
        S.playing, S.dragging = false, false
    end)
end

local function BuildToggle()
    toggle = CreateFrame("Button", "CaptainsLogJourneyToggle", WorldMapFrame)
    toggle:SetSize(28, 28)
    toggle:SetPoint("BOTTOMRIGHT", WorldMapFrame.ScrollContainer, "BOTTOMRIGHT", -8, 8)
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
    toggle:SetScript("OnClick", function() JM.Open() end)
    Tip(toggle, L["Journey map"], L["Captain's Log: play back your route on this map, day by day."])
end

local function UpdateToggle()
    if not toggle then return end
    local level = Canvas() and Canvas():GetFrameLevel() + 2200
    if level then toggle:SetFrameLevel(level) end
    local wanted = not (ns.db and ns.db.settings.journeyButton == false)
    toggle:SetShown(wanted and not (bar and bar:IsShown()))
end
JM.UpdateToggle = UpdateToggle

------------------------------------------------------------------------------
-- Opening and closing
------------------------------------------------------------------------------

local ready = false

local function Setup()
    if ready or not (WorldMapFrame and WorldMapFrame.ScrollContainer) then return end
    ready = true
    BuildBar()
    BuildToggle()
    local function relayout()
        if bar and bar:IsShown() then layoutDirty = true end
    end
    hooksecurefunc(WorldMapFrame, "OnMapChanged", relayout)
    if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", relayout) end
    WorldMapFrame.ScrollContainer:HookScript("OnSizeChanged", relayout)
    WorldMapFrame:HookScript("OnShow", function()
        relayout()
        UpdateToggle()
    end)
    UpdateToggle()
end

-- Opens the bar on the map (already open) at `key` (a day; default the latest).
function JM.Open(key)
    if not ready then pcall(Setup) end
    if not bar then return end
    CollectDays()
    local index = #S.days
    if key then
        for i, k in ipairs(S.days) do
            if k == key then index = i end
        end
    end
    bar:Show()
    UpdateToggle()
    bar:SetFrameLevel((Canvas() and Canvas():GetFrameLevel() or 0) + 2300)
    if holder then holder:Show() end
    SelectDay(index)
end

-- From the book: opens the world map (out of combat) and the bar on day `key`.
function JM.Show(key)
    if not WorldMapFrame then return end
    if not WorldMapFrame:IsShown() then
        if InCombatLockdown() or not (ns.MapPins and ns.MapPins.Open) then
            ns.Print(L["The journey map opens once the fight is over."])
            return
        end
        CollectDays()
        local day = key and ns.db.days[key]
        local mapID
        for _, s in ipairs(day and day.path or {}) do
            mapID = mapID or s.m
        end
        ns.MapPins.Open(mapID)
    end
    JM.Open(key)
end

function JM.Close()
    S.playing, S.dragging = false, false
    if bar then bar:Hide() end
    if holder then holder:Hide() end
    UpdateToggle()
end

if WorldMapFrame then
    pcall(Setup)
else
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, _, name)
        if name == "Blizzard_WorldMap" then
            self:UnregisterAllEvents()
            pcall(Setup)
        end
    end)
end
