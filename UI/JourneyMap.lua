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
    taxi = "Interface\\Minimap\\Tracking\\FlightMaster",
    hearth = "Interface\\Icons\\INV_Misc_Rune_01",
    mount = "Interface\\Icons\\Ability_Mount_RidingHorse",
    transport = "Interface\\Icons\\INV_Misc_Spyglass_02",
    closecall = "Interface\\Icons\\Spell_Holy_AshesToAshes",
    rest = "Interface\\Minimap\\Tracking\\Innkeeper",
    visit = function(ev)
        if ev.kind == "mail" then return "Interface\\Minimap\\Tracking\\Mailbox" end
        if ev.kind == "trainer" then return "Interface\\GossipFrame\\TrainerGossipIcon" end
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
local MAX_NOTES = 4
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
for _, g in ipairs(GROUPS) do
    for k in pairs(g.kinds or {}) do GROUP_OF[k] = g.key end
    if g.off then DEFAULT_OFF[g.key] = true end
end

-- journeyHide[group]: true hidden, false shown, nil its default (most show; "XP" doesn't).
local function Hidden(group)
    local h = ns.db.settings.journeyHide
    local v = h and h[group]
    if v == nil then return DEFAULT_OFF[group] or false end
    return v
end

-- An entry's kind is shown (and has an icon at all).
local function Visible(ev)
    local g = GROUP_OF[ev.k]
    return g ~= nil and not Hidden(g)
end

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
    dots = {},        -- { t, pi, py, px, kind, group, id/name/amt/src } every kill and XP gain
    fights = {},      -- { t0, t1 } by time
    xp = {},          -- { t, amt } experience gains, for the time bar's hover numbers
    active = {},      -- every moment something happened (sorted), for squeezing quiet stretches
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
    local dots, fights, xps = {}, {}, {}
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
        if ns.Moments then
            for _, f in ipairs(ns.Moments.Read(key, "kl")) do
                local ref = f[5] or ""
                dots[#dots + 1] = { t = f[1], pi = tonumber(f[2]), py = tonumber(f[3]), px = tonumber(f[4]),
                    kind = "kill", group = "allkills", id = tonumber(ref), name = ref:match("^n(.+)$") }
            end
            for _, f in ipairs(ns.Moments.Read(key, "xl")) do
                local amt = tonumber(f[2]) or 0
                dots[#dots + 1] = { t = f[1], pi = tonumber(f[4]), py = tonumber(f[5]), px = tonumber(f[6]),
                    kind = "xp", group = "xp", amt = amt, src = f[3] }
                xps[#xps + 1] = { t = f[1], amt = amt }
            end
            for _, f in ipairs(ns.Moments.Read(key, "fl")) do
                fights[#fights + 1] = { t0 = f[1], t1 = f[2] }
            end
        end
    end
    table.sort(dots, function(a, b) return a.t < b.t end)
    table.sort(fights, function(a, b) return a.t0 < b.t0 end)
    table.sort(xps, function(a, b) return a.t < b.t end)
    S.dots, S.fights, S.xp = dots, fights, xps
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
    -- What you wore when: each level's snapshot, then every upgrade logged since (all days, so a
    -- snapshot from days before still leads up to now).
    local snaps, equips = {}, {}
    for _, rec in pairs(ns.db.levels or {}) do
        if type(rec) == "table" and rec.snap and rec.snap.gear then
            snaps[#snaps + 1] = { t = rec.snap.t or rec.time or 0, gear = rec.snap.gear }
        end
    end
    for _, day in pairs(ns.db.days or {}) do
        for _, ev in ipairs(day.events or {}) do
            if ev.k == "equip" and ev.slot and ev.id and ev.t then equips[#equips + 1] = ev end
        end
    end
    table.sort(snaps, function(a, b) return a.t < b.t end)
    table.sort(equips, function(a, b) return a.t < b.t end)
    S.snaps, S.equips = snaps, equips
    local t0, t1 = pts[1] and pts[1].t, pts[#pts] and pts[#pts].t
    if events[1] then
        t0 = math.min(t0 or events[1].ev.t, events[1].ev.t)
        t1 = math.max(t1 or events[#events].ev.t, events[#events].ev.t)
    end
    S.t0, S.t1 = t0 or 0, t1 or 0
    if S.t1 <= S.t0 then S.t1 = S.t0 + 1 end
    -- Every moment something happened: route movement, entries, kills, experience.
    local active = {}
    for _, t in ipairs(times) do active[#active + 1] = t end
    for _, e in ipairs(events) do active[#active + 1] = e.ev.t end
    for _, d in ipairs(dots) do
        if d.t >= S.t0 and d.t <= S.t1 then active[#active + 1] = d.t end
    end
    for _, f in ipairs(fights) do
        if f.t0 >= S.t0 and f.t1 <= S.t1 then
            active[#active + 1] = f.t0
            active[#active + 1] = f.t1
        end
    end
    table.sort(active)
    S.active = active
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

-- Whether moment t falls in a fight.
local function InFight(t)
    local f = S.fights
    local lo, hi = 1, #f
    if hi == 0 or t < f[1].t0 then return false end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if f[mid].t0 <= t then lo = mid else hi = mid - 1 end
    end
    return t <= f[lo].t1 + 2
end

------------------------------------------------------------------------------
-- The time bar's scale: time <-> x, with quiet stretches squeezed
------------------------------------------------------------------------------

-- Knots of a piecewise-linear mapping (KT times, KX pixels from the track's left), and the
-- squeezed gaps { t0, t1, x0, x1 }. Rebuilt with the range or the bar's width.
local KT, KX, GAPS = {}, {}, {}

local function BuildScale(w)
    KT, KX, GAPS = {}, {}, {}
    local span = S.t1 - S.t0
    if ns.db.settings.journeyCompress ~= false and w > 0 and span > 0 then
        local a = S.active
        local gaps, quiet = {}, 0
        for i = 2, #a do
            local d = a[i] - a[i - 1]
            if d > COMPRESS_GAP then
                gaps[#gaps + 1] = { t0 = a[i - 1], t1 = a[i] }
                quiet = quiet + d
            end
        end
        local free, busy = w - #gaps * GAP_W, span - quiet
        if #gaps > 0 and free > w * 0.25 and busy > 0 then
            local k = free / busy
            local x = 0
            KT[1], KX[1] = S.t0, 0
            for _, g in ipairs(gaps) do
                x = x + (g.t0 - KT[#KT]) * k
                KT[#KT + 1], KX[#KX + 1] = g.t0, x
                g.x0 = x
                x = x + GAP_W
                KT[#KT + 1], KX[#KX + 1] = g.t1, x
                g.x1 = x
            end
            KT[#KT + 1], KX[#KX + 1] = S.t1, w
            GAPS = gaps
        end
    end
    if #KT == 0 then KT, KX = { S.t0, S.t1 }, { 0, w } end
end

local function Interp(from, to, v)
    local n = #from
    if n < 2 then return 0 end
    if v <= from[1] then return to[1] end
    if v >= from[n] then return to[n] end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if from[mid] <= v then lo = mid else hi = mid - 1 end
    end
    local a, b = from[lo], from[lo + 1]
    if not b or b == a then return to[lo] end
    return to[lo] + (to[lo + 1] - to[lo]) * (v - a) / (b - a)
end

-- Every time <-> x conversion on the time bar goes through these two.
local function TimeToX(t) return Interp(KT, KX, t) end
local function XToTime(x) return Interp(KX, KT, x) end

------------------------------------------------------------------------------
-- Drawing on the map's canvas
------------------------------------------------------------------------------

local hero -- the portrait of you while it plays
local bar, toggle -- the control bar, and the map's button that opens it
local holder, marker
local lines, head = {}, nil
local L_END = {}      -- per line: the index of the point it ends at
local U, V = {}, {}   -- per point: where it falls on the map shown (0-1), or nil
local icons = {}      -- per placed entry on this map: { frame, t }
local dotFrames = {}  -- per placed dot (every kill, XP, gathering)
local FIGHTY = {}     -- per line: drawn red (a fight)
local nLines, nIcons, nDots = 0, 0, 0
local canvasScale = 1
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

-- Where a world position falls on a map (0-1), or nil if it isn't on it. A little leeway past
-- the edges so a line leaving the map isn't cut short.
local function ToMap(inst, north, west, mapID)
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, inst, CreateVector2D(north, west), mapID)
    if ok and pos then return pos:GetXY() end
end

local function OnMap(inst, north, west, mapID)
    if not inst then return end
    local u, v = ToMap(inst, north, west, mapID)
    if u and v and u > -0.25 and u < 1.25 and v > -0.25 and v < 1.25 then return u, v end
end

local function Strip(text)
    -- Parchment inks read badly on a dark tooltip.
    for _, ink in ipairs({ "7a1f0d", "6b5d4f", "2e1d0c", "1d4f8c", "8a6d4a" }) do
        text = text:gsub("|cff" .. ink, "|cffffd100")
    end
    return text
end

local function ShowEntry(e, owner, anchor)
    GameTooltip:SetOwner(owner, anchor)
    GameTooltip:SetText(date(S.index == 0 and L["%d %b %Y, %H:%M"] or "%H:%M", e.ev.t))
    local line = ns.LogLine and ns.LogLine(e.ev, e.key)
    if line then GameTooltip:AddLine(Strip(line), 1, 1, 1, true) end
    GameTooltip:AddLine(L["Captain's Log: journey map"], 0.85, 0.75, 0.55)
    GameTooltip:Show()
end

local function DotTip(d, owner)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(date(S.index == 0 and L["%d %b %Y, %H:%M"] or "%H:%M", d.t))
    if d.kind == "kill" then
        local m = d.id and ns.db.mobs[d.id]
        local name = (m and m.name) or d.name or (d.id and ns.CreatureName(d.id)) or L["an unknown creature"]
        GameTooltip:AddLine(L["Killed %s."]:format(name), 1, 1, 1, true)
    else
        local fmt = ({ k = L["+%s experience from a kill."], q = L["+%s experience from a quest."],
            e = L["+%s experience from exploring."] })[d.src] or L["+%s experience."]
        GameTooltip:AddLine(fmt:format(ns.Number(d.amt or 0)), 1, 1, 1, true)
    end
    GameTooltip:AddLine(L["Captain's Log: journey map"], 0.85, 0.75, 0.55)
    GameTooltip:Show()
end

local function IconEnter(f)
    f.hover = true
    f:SetAlpha(1)
    if f.entry then ShowEntry(f.entry, f, "ANCHOR_RIGHT")
    elseif f.dot then DotTip(f.dot, f) end
end

local function IconLeave(f)
    f.hover = nil
    if not f.anim then f:SetAlpha(f.settle or 1) end
    GameTooltip_Hide()
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
        f:SetScript("OnLeave", IconLeave)
        f.settle = SETTLED
        icons[i] = f
    end
    return f
end

local function TakeDot(i)
    local f = dotFrames[i]
    if not f then
        f = CreateFrame("Frame", nil, holder)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        f.tex:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        pcall(f.SetMouseMotionEnabled, f, true)
        pcall(f.SetMouseClickEnabled, f, false)
        f:SetScript("OnEnter", IconEnter)
        f:SetScript("OnLeave", IconLeave)
        f.settle, f.isDot = 0.85, true
        dotFrames[i] = f
    end
    return f
end

------------------------------------------------------------------------------
-- Things happening: icons pop in as the marker reaches them, with a short note
------------------------------------------------------------------------------

local anims = {} -- { f, start, dot }
local notes = {} -- active notes, oldest first: { frame, start, slot }
local notePool = {}

local function Plain(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", "")
    s = s:gsub("[%.!]$", "")
    if #s > 64 then
        s = s:sub(1, 62):gsub("[\192-\255][\128-\191]*$", "") .. "..."
    end
    return s
end

-- A few words for what an entry is: "Quest done: The Hills Have Eyes", "Level 11".
local function NoteText(e)
    local ev = e.ev
    if ev.k == "quest" and ev.title then return Plain(L["Quest done: %s"]:format(ev.title)) end
    if ev.k == "accept" and ev.title then return Plain(L["Quest taken: %s"]:format(ev.title)) end
    if ev.k == "level" then return L["Level %d"]:format(ev.level or 0) end
    if ev.k == "death" then
        return ev.killer and Plain(L["Died to %s"]:format(ev.killer)) or L["Died"]
    end
    if ev.k == "kill" then
        local m = ns.db.mobs[ev.id]
        local name = ev.name or (m and m.name) or L["an unknown creature"]
        if (ev.n or 1) > 1 then return Plain(L["Slew %s x%d"]:format(name, ev.n)) end
        return Plain(L["Slew %s"]:format(name))
    end
    local line = ns.LogLine and ns.LogLine(ev, e.key)
    return line and Plain(line) or nil
end

local function ReleaseNote(n)
    n.frame:Hide()
    n.frame:ClearAllPoints()
    notePool[#notePool + 1] = n.frame
end

-- The notes are a list in the map's corner (under your portrait when it's shown), each with the
-- thing's icon, newest at the bottom: beside their icons they ran into each other. The big moments
-- hold the playback a moment so there's time to read them.
local NOTE_TIME = 4
local BIG = { level = true, quest = true, death = true, boss = true, firstitem = true, closecall = true,
    dungeon = true, milestone = true }
local feed

local function PlaceNotes()
    if not feed then return end
    feed:ClearAllPoints()
    local below = hero and hero:IsShown()
    feed:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "TOPLEFT", 10, below and -226 or -10)
    for i, n in ipairs(notes) do
        n.frame:ClearAllPoints()
        n.frame:SetPoint("TOPLEFT", feed, "TOPLEFT", 0, -(i - 1) * 21)
    end
end

local function ShowNote(f, text)
    if not text or text == "" or not bar then return end
    if not feed then
        feed = CreateFrame("Frame", nil, bar)
        feed:SetSize(1, 1)
    end
    if #notes >= MAX_NOTES then ReleaseNote(table.remove(notes, 1)) end
    local fr = table.remove(notePool)
    if not fr then
        fr = CreateFrame("Frame", nil, feed)
        fr.bg = fr:CreateTexture(nil, "BACKGROUND")
        fr.bg:SetAllPoints()
        fr.bg:SetColorTexture(0, 0, 0, 0.7)
        fr.icon = fr:CreateTexture(nil, "ARTWORK")
        fr.icon:SetSize(16, 16)
        fr.icon:SetPoint("LEFT", 3, 0)
        fr.text = fr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fr.text:SetPoint("LEFT", fr.icon, "RIGHT", 5, 0)
        local font, size = fr.text:GetFont()
        if font then fr.text:SetFont(font, (size or 10) + 1, "OUTLINE") end
        pcall(fr.EnableMouse, fr, false)
    end
    fr:SetFrameStrata("HIGH")
    local tex = f.tex and f.tex:GetTexture()
    if tex then
        fr.icon:SetTexture(tex)
        fr.icon:SetTexCoord(f.tex:GetTexCoord())
        fr.icon:Show()
    else
        fr.icon:Hide()
    end
    fr.text:SetText(text)
    fr:SetSize(fr.text:GetStringWidth() + 30, 20)
    fr:SetAlpha(0)
    fr:Show()
    notes[#notes + 1] = { frame = fr, start = GetTime() }
    PlaceNotes()
    local k = f.entry and f.entry.ev and f.entry.ev.k
    if k and BIG[k] and S.playing and ns.db.settings.journeyHold ~= false then
        S.holdUntil = GetTime() + 1.8
    end
end

local function Pop(f, isDot)
    if not f.anim then
        f.anim = true
        anims[#anims + 1] = { f = f, start = GetTime(), dot = isDot }
    end
end

local function EndAnim(f)
    f.anim = nil
    f:SetSize(f.base or ICON, f.base or ICON)
    f:SetAlpha(f.hover and 1 or f.settle)
end

local function StopAll()
    for _, a in ipairs(anims) do EndAnim(a.f) end
    wipe(anims)
    for _, n in ipairs(notes) do ReleaseNote(n) end
    wipe(notes)
end
JM.StopAnimations = StopAll

-- Every frame while the bar is open (cheap: only what's moving).
local function Animate()
    if #anims == 0 and #notes == 0 then return end
    local now = GetTime()
    for i = #anims, 1, -1 do
        local a = anims[i]
        local f, el = a.f, now - a.start
        local s, alpha, done
        if a.dot then
            s = el < 0.15 and 0.4 + 0.9 * el / 0.15 or (el < 0.25 and 1.3 - 0.3 * (el - 0.15) / 0.1 or 1)
            alpha = el < 0.15 and el / 0.15 or 1
            done = el >= 0.25
        else
            s = el < 0.2 and 0.4 + 0.75 * el / 0.2 or (el < 0.3 and 1.15 - 0.15 * (el - 0.2) / 0.1 or 1)
            if el < 0.15 then alpha = el / 0.15
            elseif el < 2.8 then alpha = 1
            else alpha = 1 - (1 - SETTLED) * math.min(1, (el - 2.8) / 0.5) end
            done = el >= 3.3
        end
        if done then
            EndAnim(f)
            table.remove(anims, i)
        else
            local b = (f.base or ICON) * s
            f:SetSize(b, b)
            f:SetAlpha(f.hover and 1 or alpha)
        end
    end
    for i = #notes, 1, -1 do
        local n = notes[i]
        local el = now - n.start
        if el >= NOTE_TIME + 0.4 then
            ReleaseNote(n)
            table.remove(notes, i)
            PlaceNotes()
        else
            n.frame:SetAlpha(el < 0.15 and el / 0.15 or (el < NOTE_TIME and 1 or 1 - (el - NOTE_TIME) / 0.4))
        end
    end
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
    canvasScale = scale
    StopAll()
    local pts = S.pts
    local fightsShown = not Hidden("combat")
    wipe(U)
    wipe(V)
    -- Each point placed by asking the game where it falls on this map (nothing where it isn't on
    -- it). Not by comparing instances: the map's own instance can't be worked out for every map
    -- (Forever's new zones), and a point's continent decides it anyway.
    if W > 0 and mapID and not Hidden("route") then
        local placed = {}
        for i, p in ipairs(pts) do
            local u, v = OnMap(p.inst, p.y, p.x, mapID, placed)
            if u then U[i], V[i] = u, v end
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
            FIGHTY[n] = fightsShown and InFight(pts[i + 1].t) or nil
        end
    end
    for i = n + 1, #lines do lines[i]:Hide() end
    nLines = n
    head:SetThickness(WIDTH / scale)

    -- Entries that say where they happened, on this continent.
    local m, nd = 0, 0
    local dotSize = DOT / scale
    local function PlaceDot(u, v, t, c)
        nd = nd + 1
        local f = TakeDot(nd)
        f.t, f.on, f.base = t, nil, dotSize
        f.tex:SetVertexColor(c[1], c[2], c[3], 1)
        f:SetSize(dotSize, dotSize)
        f:ClearAllPoints()
        f:SetPoint("CENTER", canvas, "TOPLEFT", u * W, -v * H)
        f:SetFrameLevel(holder:GetFrameLevel() + 6)
        return f
    end
    if W > 0 and mapID then
        for _, e in ipairs(S.events) do
            local ev = e.ev
            if DOT_KINDS[ev.k] then
                if ev.pi and ev.py and ev.px and nd < MAX_DOTS and Visible(ev) then
                    local u, v = OnMap(ev.pi, ev.py, ev.px, mapID)
                    if u then
                        local f = PlaceDot(u, v, ev.t, DOT_COLORS[ev.what] or DOT_COLORS.herb)
                        f.entry, f.dot = e, nil
                    end
                end
            elseif ev.pi and ev.py and ev.px and ICONS[ev.k] and Visible(ev) then
                local u, v = OnMap(ev.pi, ev.py, ev.px, mapID)
                if u then
                    m = m + 1
                    local f = TakeIcon(m)
                    f.entry, f.t, f.on, f.base = e, ev.t, nil, ICON / scale
                    SetIconTexture(f.tex, ev)
                    f:SetSize(ICON / scale, ICON / scale)
                    f:ClearAllPoints()
                    f:SetPoint("CENTER", canvas, "TOPLEFT", u * W, -v * H)
                    f:SetFrameLevel(holder:GetFrameLevel() + 10)
                end
            end
        end
    end
    -- Every kill and experience gain, as dots.
    if W > 0 and mapID then
        for _, d in ipairs(S.dots) do
            if nd >= MAX_DOTS then break end
            if d.pi and d.py and d.px and not Hidden(d.group) then
                local u, v = OnMap(d.pi, d.py, d.px, mapID)
                if u then
                    local f = PlaceDot(u, v, d.t, DOT_COLORS[d.kind])
                    f.entry, f.dot = nil, d
                end
            end
        end
    end
    for i = m + 1, #icons do
        icons[i]:Hide()
        icons[i].entry = nil
    end
    for i = nd + 1, #dotFrames do
        dotFrames[i]:Hide()
        dotFrames[i].entry, dotFrames[i].dot = nil, nil
    end
    nIcons, nDots = m, nd
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

-- Following the route across maps: while it plays or you scrub, a moment the open map doesn't
-- show (Zephras Isle, then Mulgore, then the Barrens) brings up the zone map you were in then. A
-- map that already shows it (a continent) is left alone. Not in combat (changing the map then
-- isn't safe), and each map is only tried once in a row so one that won't open isn't hammered.
local lastFollow
local function Follow()
    if ns.db.settings.journeyFollow == false or not (S.playing or S.dragging) then return end
    if InCombatLockdown() then return end
    local idx = Find(S.cur)
    local p = S.pts[math.max(1, idx)]
    if not p or not p.map then return end
    if U[math.max(1, idx)] then lastFollow = nil return end -- on the map shown: nothing to do
    if p.map == lastFollow or p.map == WorldMapFrame:GetMapID() then return end
    lastFollow = p.map
    pcall(WorldMapFrame.SetMapID, WorldMapFrame, p.map)
end

-- Your gear at time t: the latest snapshot before it (or the first one there is), with the
-- upgrades equipped between then and t on top. Returns the gear and a signature of it.
local function GearAt(t)
    local base
    for _, sn in ipairs(S.snaps or {}) do
        if sn.t <= t or not base then base = sn else break end
    end
    if not base then return nil end
    local gear = {}
    for slot, id in pairs(base.gear) do gear[slot] = id end
    for _, ev in ipairs(S.equips or {}) do
        if ev.t > t then break end
        if ev.t > base.t then gear[ev.slot] = ev.id end
    end
    local sig = {}
    for slot = 1, 19 do sig[#sig + 1] = tostring(gear[slot] or 0) end
    return gear, table.concat(sig, ",")
end

-- You, in a portrait in the map's top corner while the journey plays: in the gear you had on at
-- that moment, with your level under it. Passing a level up (playing forward) plays the level-up
-- sound and the golden burst around you, as the game does, and changes into that level's gear.
local LEVEL_SOUND = 888    -- the game's level-up fanfare
local lastCur

local function LevelAt(t)
    local best
    for lvl, rec in pairs(ns.db.levels or {}) do
        if type(rec) == "table" and rec.time and rec.time <= t and (not best or lvl > best) then best = lvl end
    end
    return best
end

local function EnsurePortrait()
    if hero or not bar then return hero end
    local box = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    box:SetSize(150, 210)
    box:SetPoint("TOPLEFT", WorldMapFrame.ScrollContainer, "TOPLEFT", 10, -10)
    box:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    box:SetBackdropColor(0.06, 0.05, 0.04, 0.85)
    box:SetBackdropBorderColor(0.75, 0.62, 0.38, 1)
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, box)
    if not ok or not m then return nil end
    m:SetPoint("TOPLEFT", 6, -6)
    m:SetPoint("BOTTOMRIGHT", -6, 22)
    m:SetScript("OnModelLoaded", function(self)
        pcall(self.SetFacing, self, 0.35)
        box.gearSig = nil -- dressed again once it's there
    end)
    box.model = m
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
    local ag = box.glow:CreateAnimationGroup()
    if ag.SetToFinalAlpha then ag:SetToFinalAlpha(true) end
    local a1 = ag:CreateAnimation("Alpha")
    a1:SetFromAlpha(0) a1:SetToAlpha(0.22) a1:SetDuration(0.25) a1:SetOrder(1)
    local a2 = ag:CreateAnimation("Alpha")
    a2:SetFromAlpha(0.22) a2:SetToAlpha(0) a2:SetDuration(1.4) a2:SetOrder(2)
    ag:SetScript("OnFinished", function() box.glow:SetAlpha(0) end)
    box.flash = ag
    -- The level-up glow: a soft gold sparkle behind you that swells and fades (the game's own
    -- effect can't be given to a model). It ends hidden, whatever happens to the animation.
    local glow = box:CreateTexture(nil, "BACKGROUND", nil, 3)
    glow:SetPoint("CENTER", m, "CENTER", 0, -10)
    glow:SetSize(150, 150)
    glow:SetTexture("Interface\\Cooldown\\star4")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.78, 0.25)
    glow:SetAlpha(0)
    local gg = glow:CreateAnimationGroup()
    if gg.SetToFinalAlpha then gg:SetToFinalAlpha(true) end
    local g1 = gg:CreateAnimation("Alpha") g1:SetFromAlpha(0) g1:SetToAlpha(0.9) g1:SetDuration(0.35) g1:SetOrder(1)
    local g2 = gg:CreateAnimation("Scale") g2:SetScaleFrom(0.5, 0.5) g2:SetScaleTo(1.4, 1.4) g2:SetDuration(1.8)
    g2:SetOrder(1)
    local g3 = gg:CreateAnimation("Alpha") g3:SetFromAlpha(0.9) g3:SetToAlpha(0) g3:SetDuration(1.2) g3:SetOrder(2)
    gg:SetScript("OnFinished", function() glow:SetAlpha(0) end)
    box.burst = gg
    box:Hide()
    hero = box
    return box
end

local function Celebrate(box)
    pcall(PlaySound, LEVEL_SOUND, "Master")
    for _, ag in ipairs({ box.flash, box.burst }) do
        ag:Stop()
        ag:Play()
    end
end

local function Hero()
    local box = EnsurePortrait()
    if not box then return end
    if Hidden("hero") or S.whole or #S.pts == 0 and #S.events == 0 then
        box:Hide()
        lastCur = nil
        return
    end
    if not box:IsShown() then
        box:Show()
        pcall(box.model.SetUnit, box.model, "player")
        box.gearSig = nil
    end
    local gear, sig = GearAt(S.cur)
    if gear and sig ~= box.gearSig then
        box.gearSig = sig
        pcall(box.model.Undress, box.model)
        for slot, id in pairs(gear) do
            if slot ~= 0 and type(id) == "number" then pcall(box.model.TryOn, box.model, "item:" .. id) end
        end
    end
    local lvl = LevelAt(S.cur)
    box.label:SetText(lvl and L["Level %d"]:format(lvl) or "")
    -- A level up passed while playing forward.
    if S.playing and lastCur and S.cur > lastCur then
        for _, e in ipairs(S.events) do
            if e.ev.k == "level" and e.ev.t > lastCur and e.ev.t <= S.cur then
                Celebrate(box)
                break
            end
        end
    end
    lastCur = S.cur
end

local prevCur -- the moment shown at the last draw
local function Draw()
    dirty = false
    Follow()
    if not holder then return end
    local canvas = Canvas()
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    local idx = Find(S.cur)
    local k = S.whole and nLines or LinesUpTo(idx)
    -- Only the pieces whose side of "now" changed are recoloured.
    local function Col(i, past)
        if FIGHTY[i] then return past and FIGHT_PAST or FIGHT_FUTURE end
        return past and PAST or FUTURE
    end
    if not lastK then
        for i = 1, nLines do Paint(lines[i], Col(i, i <= k)) end
    elseif k > lastK then
        for i = lastK + 1, k do Paint(lines[i], Col(i, true)) end
    elseif k < lastK then
        for i = k + 1, lastK do Paint(lines[i], Col(i, false)) end
    end
    lastK = k

    local u, v, nxt, at = Position(S.cur)
    if S.whole or Hidden("route") then u = nil end
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

    -- Only things crossing "now" going forward, while playing or scrubbing, have their moment;
    -- jumps, going back and the whole route show everything settled.
    local forward = not S.whole and (S.playing or S.dragging) and prevCur and S.cur > prevCur
        and S.cur - prevCur <= JUMP_T
    if prevCur and (S.cur < prevCur or S.whole) then StopAll() end
    local withNotes = forward and ns.db.settings.journeyNotes ~= false
    local function Turn(f, isDot)
        local on = S.whole or f.t <= S.cur
        if on == f.on then return end
        f.on = on
        if on and forward and f.t > prevCur then
            f:SetAlpha(0)
            Pop(f, isDot)
            if not isDot and withNotes and f.entry then ShowNote(f, NoteText(f.entry)) end
        else
            if f.anim then EndAnim(f) end
            f:SetAlpha(f.hover and 1 or f.settle)
        end
        f:SetShown(on)
    end
    for i = 1, nIcons do Turn(icons[i], false) end
    for i = 1, nDots do Turn(dotFrames[i], true) end
    prevCur = S.cur
    Hero()
end

------------------------------------------------------------------------------
-- The control bar
------------------------------------------------------------------------------


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
    local shown = {}
    for _, e in ipairs(events) do
        if Visible(e.ev) then shown[#shown + 1] = e end
    end
    events = shown
    BuildScale(w)
    local hit = track:GetParent()
    local step = math.max(1, math.ceil(#events / MAX_TICKS))
    local span = S.t1 - S.t0
    local nl = 0
    local labels = bar.levelLabels
    if w > 0 and span > 0 then
        for i = 1, #events do
            local ev = events[i].ev
            local isLevel = ev.k == "level"
            -- Level ups always get their mark; the rest are thinned to MAX_TICKS.
            if isLevel or (i - 1) % step == 0 then
                n = n + 1
                local t = ticks[n]
                if not t then
                    t = hit:CreateTexture(nil, "ARTWORK", nil, 2) -- on the track's frame (a texture can't hold textures)
                    ticks[n] = t
                end
                local c = TICK[ev.k] or { 0.9, 0.82, 0.62 }
                local big = TICK[ev.k] ~= nil
                local x = TimeToX(ev.t)
                t:SetColorTexture(c[1], c[2], c[3], big and 1 or 0.55)
                t:SetWidth(isLevel and 2 or 1)
                t:SetHeight(isLevel and 20 or (big and 14 or 8))
                t:ClearAllPoints()
                t:SetPoint("CENTER", track, "LEFT", x, 0)
                t:Show()
                if isLevel then
                    nl = nl + 1
                    local fs = labels[nl]
                    if not fs then
                        fs = hit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        local font, size = fs:GetFont()
                        if font then fs:SetFont(font, 9, "OUTLINE") end
                        fs:SetTextColor(1, 0.82, 0.25)
                        labels[nl] = fs
                    end
                    fs:SetText(ev.level or "")
                    fs:ClearAllPoints()
                    fs:SetPoint("BOTTOM", track, "LEFT", x, 10)
                    fs:Show()
                end
            end
        end
    end
    for i = n + 1, #ticks do ticks[i]:Hide() end
    for i = nl + 1, #labels do labels[i]:Hide() end

    -- Squeezed quiet stretches: the track broken, with two slanted strokes.
    local breaks = bar.breaks
    for i, g in ipairs(GAPS) do
        local b = breaks[i]
        if not b then
            b = { mask = hit:CreateTexture(nil, "ARTWORK", nil, 3),
                a = hit:CreateLine(nil, "OVERLAY"), b = hit:CreateLine(nil, "OVERLAY") }
            b.mask:SetColorTexture(0.10, 0.06, 0.03, 1)
            for _, l in ipairs({ b.a, b.b }) do
                l:SetColorTexture(0.9, 0.82, 0.62, 0.9)
                l:SetThickness(1)
            end
            breaks[i] = b
        end
        b.mask:ClearAllPoints()
        b.mask:SetPoint("LEFT", track, "LEFT", g.x0 + 1, 0)
        b.mask:SetSize(math.max(1, g.x1 - g.x0 - 2), 8)
        b.a:SetStartPoint("LEFT", track, g.x0, -5)
        b.a:SetEndPoint("LEFT", track, g.x0 + 2, 5)
        b.b:SetStartPoint("LEFT", track, g.x1 - 2, -5)
        b.b:SetEndPoint("LEFT", track, g.x1, 5)
        b.mask:Show() b.a:Show() b.b:Show()
    end
    for i = #GAPS + 1, #breaks do
        breaks[i].mask:Hide() breaks[i].a:Hide() breaks[i].b:Hide()
    end

    -- The activity strip: how much happened along the bar.
    local counts, top = {}, 0
    if w > 0 then
        local function Add(t)
            local b = math.floor(TimeToX(t) / w * BUCKETS) + 1
            b = math.max(1, math.min(BUCKETS, b))
            counts[b] = (counts[b] or 0) + 1
            if counts[b] > top then top = counts[b] end
        end
        for _, e in ipairs(S.events) do Add(e.ev.t) end
        for _, d in ipairs(S.dots) do
            if d.t >= S.t0 and d.t <= S.t1 then Add(d.t) end
        end
    end
    local strip = bar.strip
    for i = 1, BUCKETS do
        local s = strip[i]
        if not s then
            s = hit:CreateTexture(nil, "ARTWORK")
            strip[i] = s
        end
        local c = counts[i] or 0
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", track, "BOTTOMLEFT", (i - 1) / BUCKETS * w, -2)
        s:SetSize(math.max(1, w / BUCKETS), 3)
        s:SetColorTexture(1, 0.75, 0.3, top > 0 and (0.06 + 0.8 * c / top) or 0.06)
        s:SetShown(w > 0)
    end
end

local function UpdateBar()
    if not bar then return end
    bar.day:SetText(DayLabel())
    bar.play:SetText(S.playing and L["Pause"] or L["Play"])
    bar.speed:SetText(SPEEDS[S.speed][2])
    bar.whole:SetEnabled(not S.whole or S.playing)
    local w = bar.track:GetWidth()
    local x = math.max(0, math.min(w, TimeToX(S.cur)))
    bar.fill:SetWidth(math.max(0.01, x))
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("CENTER", bar.track, "LEFT", x, 0)
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
    lastFollow = nil
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

-- Hovering the time bar: the event nearest the cursor (within a few pixels) in a tooltip, the
-- same as its icon on the map. The ticks are textures, so this is worked out from the cursor.
local hoverEntry
local function HoverTicks()
    local hit = bar.track:GetParent()
    if S.dragging or not hit:IsMouseOver() or S.t1 <= S.t0 then
        if hoverEntry then hoverEntry = nil; GameTooltip_Hide() end
        if bar.xpShown then
            for _, fs in ipairs(bar.xpLabels) do fs:Hide() end
            bar.xpShown, bar.xpAt = false, nil
        end
        return
    end
    local x = GetCursorPosition() / bar.track:GetEffectiveScale()
    local left, w = bar.track:GetLeft(), bar.track:GetWidth()
    if not left or w <= 0 then return end
    -- Experience gains near the cursor, as small numbers above the bar (hover only).
    local cx = math.floor(x - left + 0.5)
    if cx ~= bar.xpAt then
        bar.xpAt = cx
        local n = 0
        for _, g in ipairs(S.xp) do
            local gx = TimeToX(g.t)
            if math.abs(gx - cx) <= 30 and n < 10 then
                n = n + 1
                local fs = bar.xpLabels[n]
                if not fs then
                    fs = hit:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    local font = fs:GetFont()
                    if font then fs:SetFont(font, 8, "OUTLINE") end
                    fs:SetTextColor(0.75, 0.6, 1)
                    bar.xpLabels[n] = fs
                end
                fs:SetText("+" .. g.amt)
                fs:ClearAllPoints()
                fs:SetPoint("BOTTOM", bar.track, "LEFT", gx, 10 + (n % 2) * 8)
                fs:Show()
            end
        end
        for i = n + 1, #bar.xpLabels do bar.xpLabels[i]:Hide() end
        bar.xpShown = n > 0
    end
    local best, bestD
    for _, e in ipairs(S.events) do
        local d = not Visible(e.ev) and math.huge or math.abs(left + TimeToX(e.ev.t) - x)
        if d <= 5 and (not bestD or d < bestD) then best, bestD = e, d end
    end
    if best == hoverEntry then return end
    hoverEntry = best
    if not best then GameTooltip_Hide() return end
    ShowEntry(best, hit, "ANCHOR_CURSOR")
end

local elapsed, sinceLive = 0, 0
local function OnUpdate(_, dt)
    -- Let go anywhere (even off the bar, where it may not hear the mouse come up): the drag ends.
    if S.dragging and not IsMouseButtonDown("LeftButton") then S.dragging = false end
    HoverTicks()
    Animate()
    if S.dragging then
        local x = GetCursorPosition() / bar.track:GetEffectiveScale()
        local left, w = bar.track:GetLeft(), bar.track:GetWidth()
        if left and w > 0 then
            -- A click that landed on a level up stays on it until the mouse moves away.
            if S.snap and math.abs(x - S.snap.x) < 4 then
                SetCur(S.snap.t)
            else
                S.snap = nil
                SetCur(XToTime(x - left))
            end
        end
    elseif S.playing and S.holdUntil and GetTime() < S.holdUntil then
        -- Holding on a big moment so its note can be read.
    elseif S.playing then
        S.holdUntil = nil
        local t = S.cur + dt * SPEEDS[S.speed][1]
        -- Long gaps (logged off, a loading screen) are jumped over.
        local idx = Find(t)
        local times = S.times
        if idx == 0 and times[1] and t < times[1] then
            t = times[1]
        elseif idx > 0 and times[idx + 1] and times[idx + 1] - times[idx] > GAP then
            t = times[idx + 1]
        end
        -- So are the stretches squeezed on the time bar.
        for _, g in ipairs(GAPS) do
            if t > g.t0 and t < g.t1 then t = g.t1 end
        end
        if t >= S.t1 then
            t = S.t1
            S.playing = false
        end
        SetCur(t)
    end
    -- Today's route grows as you go: picked up again every few seconds while it's shown (and
    -- followed, if you were watching its end).
    sinceLive = sinceLive + dt
    if sinceLive >= 5 and not S.dragging and not S.playing and S.days[S.index] == date("%Y-%m-%d") then
        sinceLive = 0
        local atEnd, cur = S.cur >= S.t1, S.cur
        local whole = S.whole
        Load()
        if not atEnd then S.cur = math.min(cur, S.t1) end
        S.whole = whole
        layoutDirty, dirty = true, true
        UpdateTicks()
        UpdateBar()
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
    bar:SetHeight(66)
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

    -- "Show": a checklist of what's drawn (kept between sessions).
    bar.show = SmallButton(bar, L["Show"], 64)
    bar.show:SetPoint("LEFT", bar.whole, "RIGHT", 4, 0)
    Tip(bar.show, L["Show"], L["Choose what the journey map draws: your route, and each kind of entry."])
    local menu = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    menu:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    menu:SetBackdropColor(0.08, 0.06, 0.04, 0.95)
    menu:SetPoint("BOTTOMLEFT", bar.show, "TOPLEFT", 0, 4)
    menu:SetFrameStrata("DIALOG")
    menu:EnableMouse(true)
    menu:Hide()
    local function Changed()
        layoutDirty, dirty, lastK = true, true, nil
        UpdateTicks()
        UpdateBar()
    end
    local rows = {}
    local function Row(i, label, get, set)
        local c = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
        c:SetSize(22, 22)
        c:SetPoint("TOPLEFT", 8, -6 - (i - 1) * 22)
        local text = c.Text or c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if not c.Text then text:SetPoint("LEFT", c, "RIGHT", 2, 0) end
        text:SetText(label)
        c:SetScript("OnShow", function(self) self:SetChecked(get()) end)
        c:SetScript("OnClick", function(self)
            set(self:GetChecked() and true or false)
            Changed()
            for _, r in ipairs(rows) do r:SetChecked(r.get()) end
        end)
        c.get = get
        rows[#rows + 1] = c
        return c
    end
    local function SetAll(on)
        local s = ns.db.settings
        s.journeyHide = s.journeyHide or {}
        for _, g in ipairs(GROUPS) do s.journeyHide[g.key] = not on end
    end
    Row(1, L["Everything"], function()
        for _, g in ipairs(GROUPS) do if Hidden(g.key) then return false end end
        return true
    end, SetAll)
    for i, g in ipairs(GROUPS) do
        Row(i + 1, g.label, function() return not Hidden(g.key) end, function(on)
            local st = ns.db.settings
            st.journeyHide = st.journeyHide or {}
            st.journeyHide[g.key] = not on
        end)
    end
    Row(#GROUPS + 3, L["You, in your gear at the time"], function()
        return not Hidden("hero")
    end, function(on)
        local st = ns.db.settings
        st.journeyHide = st.journeyHide or {}
        st.journeyHide.hero = (not on) or nil
    end)
    Row(#GROUPS + 2, L["Follow your route across maps"], function()
        return ns.db.settings.journeyFollow ~= false
    end, function(on) ns.db.settings.journeyFollow = on end)
    Row(#GROUPS + 4, L["Squeeze quiet stretches"], function()
        return ns.db.settings.journeyCompress ~= false
    end, function(on) ns.db.settings.journeyCompress = on end)
    Row(#GROUPS + 6, L["Pause a moment on the big ones"], function()
        return ns.db.settings.journeyHold ~= false
    end, function(on) ns.db.settings.journeyHold = on end)
    Row(#GROUPS + 5, L["Notes as things happen"], function()
        return ns.db.settings.journeyNotes ~= false
    end, function(on)
        ns.db.settings.journeyNotes = on
        if not on then StopAll() end
    end)
    menu:SetSize(260, 12 + (#GROUPS + 6) * 22)
    bar.show:SetScript("OnClick", function() menu:SetShown(not menu:IsShown()) end)
    bar.menu = menu

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
        S.snap = nil
        local x = GetCursorPosition() / track:GetEffectiveScale()
        local left = track:GetLeft()
        if left then
            local bestD
            for _, e in ipairs(S.events) do
                if e.ev.k == "level" and Visible(e.ev) then
                    local d = math.abs(left + TimeToX(e.ev.t) - x)
                    if d <= 6 and (not bestD or d < bestD) then
                        bestD, S.snap = d, { x = x, t = e.ev.t }
                    end
                end
            end
        end
        if S.snap then SetCur(S.snap.t) end
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
        StopAll()
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
        sinceLive = 5 -- the route as it is now, straight away
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


-- /log journey: what the journey map sees, to tell a route that wasn't recorded from one that
-- doesn't draw.
function ns.JourneyReport()
    local P = ns.Print
    local inst, north, west, here = ns.Journey.Here()
    P(("here: instance %s, %s / %s, map %s"):format(tostring(inst), tostring(north), tostring(west), tostring(here)))
    local key = date("%Y-%m-%d")
    local flat = ns.Journey.Decode(key)
    P(("today: %d route points"):format(#flat))
    local mapID = WorldMapFrame and WorldMapFrame:GetMapID()
    P(("world map: %s (its instance: %s)"):format(tostring(mapID), tostring(MapInstance(mapID))))
    local p = flat[#flat]
    if p and mapID then
        local u, v = ToMap(p.inst, p.y, p.x, mapID)
        P(("last point (instance %s) on that map: %s, %s"):format(tostring(p.inst), tostring(u), tostring(v)))
    end
    local placed = 0
    for _, e in ipairs(ns.db.days[key] and ns.db.days[key].events or {}) do
        if e.pi then placed = placed + 1 end
    end
    P(("today's log entries with a place: %d"):format(placed))
end
