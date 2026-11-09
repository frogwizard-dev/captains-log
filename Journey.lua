local _, ns = ...
local issecret = ns.issecret

-- The journey: where your time goes (afk, combat, flying...), how far you travel and how, and the
-- path you walk each day for the journey map. One ticker, once a second.
--
-- Coordinates are the game's world coordinates (UnitPosition): yards, per instance (continent).
-- "north" is UnitPosition's first value, "west" its second, which is the order FrogLib.Lines
-- takes. They don't depend on which map is open, so a day's path draws on any map of that
-- continent. Hidden in instances: nothing is recorded there.
--
-- day.path = list of segments { i = instanceID, m = uiMapID at the start, t = epoch of the first
-- point, d = "tok;tok;..." }. Each token is "dt,dn,dw" (seconds since the previous point, yards
-- north, yards west since the previous point; the first point's dn, dw are absolute and its dt is
-- 0), optionally prefixed "m<uiMapID>|" where the zone's map changed. Read it with
-- ns.Journey.Decode / Segments / Lines rather than by hand.

local Journey = {}
ns.Journey = Journey

local floor, sqrt = math.floor, math.sqrt

local function Sub(t, k)
    local v = t[k]
    if type(v) ~= "table" then
        v = {}
        t[k] = v
    end
    return v
end
ns.Sub = Sub

local function Truthy(fn, ...)
    if not fn then return false end
    local ok, v = pcall(fn, ...)
    if not ok or issecret(v) then return false end
    return v and true or false
end

-- Where you stand: instance, north, west (whole yards) and the zone's map (nil if `noMap`).
-- Nil where positions are hidden or secret.
function Journey.Here(noMap)
    if not UnitPosition then return end
    local ok, north, west, _, inst = pcall(UnitPosition, "player")
    if not ok or issecret(north) or issecret(west) or issecret(inst) then return end
    if type(north) ~= "number" or type(west) ~= "number" or type(inst) ~= "number" then return end
    return inst, floor(north + 0.5), floor(west + 0.5), (not noMap) and ns.ZoneMap() or nil
end

-- World position to a map's 0-1 coordinates (best effort; nil if the map can't place it).
function Journey.ToMap(inst, north, west, uiMapID)
    if not (C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) or not uiMapID then return end
    local ok, mapID, pos = pcall(C_Map.GetMapPosFromWorldPos, inst, CreateVector2D(north, west), uiMapID)
    if not ok or not pos then return end
    local x, y = pos:GetXY()
    if not x then return end
    return x, y, mapID
end

-- The record for the level you are now (created if needed).
function ns.LevelRecord()
    local lvl = UnitLevel("player")
    if issecret(lvl) or type(lvl) ~= "number" or lvl < 1 then return end
    return Sub(ns.db.levels, lvl)
end

------------------------------------------------------------------------------
-- Time breakdown
------------------------------------------------------------------------------

local STATES = {
    afk = function() return Truthy(UnitIsAFK, "player") end,
    combat = function() return Truthy(UnitAffectingCombat, "player") end,
    taxi = function() return Truthy(UnitOnTaxi, "player") end,
    dead = function() return Truthy(UnitIsDeadOrGhost, "player") end,
    grouped = function() return Truthy(IsInGroup) end,
    resting = function() return Truthy(IsResting) end,
    mounted = function() return Truthy(IsMounted) end,
    swimming = function() return Truthy(IsSwimming) end,
}
Journey.STATES = { "online", "afk", "combat", "taxi", "dead", "grouped", "resting", "mounted", "swimming" }

local carry = {} -- fractions of a second not yet written, per state

local function AddTime(state, dt, buckets)
    local c = (carry[state] or 0) + dt
    local whole = floor(c)
    carry[state] = c - whole
    if whole <= 0 then return end
    for _, b in ipairs(buckets) do b[state] = (b[state] or 0) + whole end
end

local function TrackTime(dt)
    local buckets = { ns.db.time, Sub(ns.Day(), "time") }
    local zone = ns.Zone()
    if zone then buckets[#buckets + 1] = Sub(ns.ZoneRecord(zone), "time") end
    local lv = ns.LevelRecord()
    if lv then buckets[#buckets + 1] = Sub(lv, "tb") end
    AddTime("online", dt, buckets)
    for state, test in pairs(STATES) do
        if test() then AddTime(state, dt, buckets) end
    end
end

------------------------------------------------------------------------------
-- Travel
------------------------------------------------------------------------------

local JUMP = 200 -- yards in one second: a teleport or loading screen, not travel
Journey.MODES = { "foot", "mount", "swim", "taxi", "ghost" }

local function Mode()
    if Truthy(UnitOnTaxi, "player") then return "taxi" end
    if Truthy(UnitIsGhost, "player") then return "ghost" end
    if Truthy(IsSwimming) then return "swim" end
    if Truthy(IsMounted) then return "mount" end
    return "foot"
end

local last         -- { inst, n, w } the previous second's position
local jumped       -- a teleport since the path last looked: start a new segment
local yardCarry = {}

local function TrackTravel()
    local inst, n, w = Journey.Here(true)
    if not inst then
        last = nil
        return
    end
    if last and last.inst == inst then
        local d = sqrt((n - last.n) ^ 2 + (w - last.w) ^ 2)
        if d > JUMP then
            jumped = true
        elseif d > 0 then
            local mode = Mode()
            local c = (yardCarry[mode] or 0) + d
            local whole = floor(c)
            yardCarry[mode] = c - whole
            if whole > 0 then
                local buckets = { ns.db.travel, Sub(ns.Day(), "travel") }
                local lv = ns.LevelRecord()
                if lv then buckets[#buckets + 1] = Sub(lv, "travel") end
                for _, b in ipairs(buckets) do b[mode] = (b[mode] or 0) + whole end
            end
        end
    elseif last then
        jumped = true -- another instance
    end
    last = last or {}
    last.inst, last.n, last.w = inst, n, w
end

------------------------------------------------------------------------------
-- Path
------------------------------------------------------------------------------

local MIN_MOVE = 10     -- yards from the last recorded point before another is recorded
local STRAIGHT = 3      -- a point this close to the line through its neighbours is dropped...
local STRAIGHT_T = 60   -- ...unless that would leave a longer gap in time than this
local MAX_CHARS = 60000 -- one segment's string; a longer journey continues in a new segment

local seg -- the segment being written: { ref, dayKey, inst, map, t, n, w (last committed), pend }

local function Token(p, prevT, prevN, prevW, mapChanged)
    local tok = ("%d,%d,%d"):format(p.t - prevT, p.n - prevN, p.w - prevW)
    if mapChanged and p.map then tok = "m" .. p.map .. "|" .. tok end
    return tok
end

local function Commit(p)
    local ref = seg.ref
    local first = seg.t == nil
    local tok
    if first then
        tok = Token(p, p.t, 0, 0, false)
        seg.map = p.map
    else
        tok = Token(p, seg.t, seg.n, seg.w, p.map ~= seg.map)
        if p.map then seg.map = p.map end
    end
    ref.d = first and tok or (ref.d .. ";" .. tok)
    seg.t, seg.n, seg.w = p.t, p.n, p.w
end

local function Flush()
    if seg and seg.pend then
        Commit(seg.pend)
        seg.pend = nil
    end
end

local function EndSegment()
    Flush()
    seg = nil
end
Journey.EndSegment = EndSegment

-- Distance of point b from the line a-c.
local function OffLine(a, b, c)
    local dx, dy = c.n - a.n, c.w - a.w
    local len = sqrt(dx * dx + dy * dy)
    if len == 0 then return sqrt((b.n - a.n) ^ 2 + (b.w - a.w) ^ 2) end
    return math.abs((b.n - a.n) * dy - (b.w - a.w) * dx) / len
end

local function SamplePath()
    if jumped then
        jumped = false
        EndSegment()
    end
    local inst, n, w, map = Journey.Here()
    if not inst then
        EndSegment() -- hidden: pause; a new segment starts when it's back
        return
    end
    local today = ns.Today()
    if seg and (seg.dayKey ~= today or seg.inst ~= inst or #seg.ref.d > MAX_CHARS) then EndSegment() end
    local p = { t = time(), n = n, w = w, map = map }
    if not seg then
        local day = ns.Day()
        local path = Sub(day, "path")
        local ref = { i = inst, m = map, t = p.t, d = "" }
        path[#path + 1] = ref
        seg = { ref = ref, dayKey = today, inst = inst }
        Commit(p)
        return
    end
    local lastP = seg.pend or { n = seg.n, w = seg.w, map = seg.map }
    local moved = sqrt((n - lastP.n) ^ 2 + (w - lastP.w) ^ 2)
    local mapChanged = map and lastP.map and map ~= lastP.map
    if moved <= MIN_MOVE and not mapChanged then return end
    local pend = seg.pend
    if pend and not mapChanged and pend.map == seg.map and p.t - seg.t <= STRAIGHT_T
        and OffLine({ n = seg.n, w = seg.w }, pend, p) < STRAIGHT then
        seg.pend = p -- still going straight: move the end of the line instead of adding a point
    else
        if pend then Commit(pend) end
        seg.pend = p
    end
end

------------------------------------------------------------------------------
-- Reading paths
------------------------------------------------------------------------------

local function DayTable(day)
    if type(day) == "string" then return ns.db.days[day] end
    return day
end

-- A segment's points: list of { t = epoch, y = north, x = west, inst = instanceID, map = uiMapID }.
local function DecodeSegment(s, out)
    out = out or {}
    local t, n, w, map = s.t or 0, 0, 0, s.m
    local first = true
    for tok in (s.d or ""):gmatch("[^;]+") do
        local m, rest = tok:match("^m(%d+)|(.*)$")
        if m then
            map = tonumber(m)
            tok = rest
        end
        local dt, dn, dw = tok:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        if dt then
            if first then
                n, w = tonumber(dn), tonumber(dw)
                first = false
            else
                t, n, w = t + tonumber(dt), n + tonumber(dn), w + tonumber(dw)
            end
            out[#out + 1] = { t = t, y = n, x = w, inst = s.i, map = map }
        end
    end
    return out
end

-- The pending (not yet written) end of today's current segment, if `s` is it.
local function WithPending(s, points)
    if seg and seg.ref == s and seg.pend then
        local p = seg.pend
        points[#points + 1] = { t = p.t, y = p.n, x = p.w, inst = s.i, map = p.map or seg.map }
    end
    return points
end

-- A day's path as segments: list of { inst, map, points = { {t, x, y, inst, map}, ... } }.
-- `day` is a day table or a "YYYY-MM-DD" key.
function Journey.Segments(day)
    day = DayTable(day)
    local out = {}
    for _, s in ipairs(day and day.path or {}) do
        local points = WithPending(s, DecodeSegment(s))
        if #points > 0 then out[#out + 1] = { inst = s.i, map = s.m, points = points } end
    end
    return out
end

-- A day's path as one flat array of { t, x, y, inst, map, seg } (seg = segment index; a new
-- segment means don't join it to the point before).
function Journey.Decode(day)
    local flat = {}
    for i, s in ipairs(Journey.Segments(day)) do
        for _, p in ipairs(s.points) do
            p.seg = i
            flat[#flat + 1] = p
        end
    end
    return flat
end

-- A day's path ready for FrogLib.Lines (layer:Set(lines)); `style` = { r, g, b, a, width,
-- minimap } is copied onto each line. Only segments on `inst` if given.
function Journey.Lines(day, style, inst)
    local lines = {}
    for _, s in ipairs(Journey.Segments(day)) do
        if #s.points >= 2 and (not inst or s.inst == inst) then
            local pts = {}
            for _, p in ipairs(s.points) do
                pts[#pts + 1] = p.y
                pts[#pts + 1] = p.x
            end
            local line = { inst = s.inst, points = pts }
            for k, v in pairs(style or {}) do line[k] = v end
            lines[#lines + 1] = line
        end
    end
    return lines
end

------------------------------------------------------------------------------
-- Thinning old paths
------------------------------------------------------------------------------

local THIN = 100 -- yards between the points kept on a thinned day

local function Encode(points, i, m)
    local parts, pt, pn, pw, pm = {}, nil, 0, 0, m
    for _, p in ipairs(points) do
        if not pt then
            parts[#parts + 1] = ("0,%d,%d"):format(p.y, p.x)
        else
            local tok = ("%d,%d,%d"):format(p.t - pt, p.y - pn, p.x - pw)
            if p.map and p.map ~= pm then tok = "m" .. p.map .. "|" .. tok end
            parts[#parts + 1] = tok
        end
        pt, pn, pw, pm = p.t, p.y, p.x, p.map or pm
    end
    return { i = i, m = m, t = points[1] and points[1].t, d = table.concat(parts, ";") }
end

-- Thins the paths of days older than `keepDays` (default: the pathKeepDays setting; 0 = keep
-- everything) to a point every THIN yards. Each day is thinned once (day.pathThin = true).
function Journey.Prune(keepDays)
    keepDays = keepDays or ns.db.settings.pathKeepDays or 0
    if keepDays <= 0 then return end
    local cutoff = date("%Y-%m-%d", time() - keepDays * 86400)
    for key, day in pairs(ns.db.days) do
        if key < cutoff and day.path and not day.pathThin then
            local kept = {}
            for _, s in ipairs(day.path) do
                local points = DecodeSegment(s)
                local out, lastP = {}, nil
                for j, p in ipairs(points) do
                    if not lastP or j == #points or p.map ~= lastP.map
                        or sqrt((p.x - lastP.x) ^ 2 + (p.y - lastP.y) ^ 2) >= THIN then
                        out[#out + 1] = p
                        lastP = p
                    end
                end
                if #out > 0 then kept[#kept + 1] = Encode(out, s.i, s.m) end
            end
            day.path = kept
            day.pathThin = true
        end
    end
end

------------------------------------------------------------------------------
-- The ticker
------------------------------------------------------------------------------

local lastTick, ticks

local function Tick()
    local now = GetTime()
    local dt = lastTick and math.min(now - lastTick, 5) or 0
    lastTick = now
    ticks = (ticks or 0) + 1
    if dt > 0 then pcall(TrackTime, dt) end
    pcall(TrackTravel)
    if ticks % 2 == 0 then
        local ok, err = pcall(SamplePath)
        if not ok then
            seg = nil
            ns.Debug("Path: " .. tostring(err))
        end
    end
end

ns.On("PLAYER_LOGIN", function()
    pcall(Journey.Prune)
    C_Timer.NewTicker(1, Tick)
end)
-- A loading screen: the next position starts a new segment and isn't counted as travel.
ns.On("PLAYER_ENTERING_WORLD", function()
    last = nil
    jumped = true
end)
ns.On("PLAYER_LOGOUT", function() pcall(Flush) end)
