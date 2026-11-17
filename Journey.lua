local _, ns = ...
local issecret = ns.issecret

-- The journey: where your time goes (afk, combat, flying...), how far you travel and how, and the
-- path you walk each day, from one ticker a second. Positions are world coordinates (UnitPosition:
-- yards per continent, north then west, as FrogLib.Lines takes them), so a path draws on any map of
-- its continent. They're hidden in instances, so nothing is recorded there.

local Journey = {}
ns.Journey = Journey

local floor, sqrt = math.floor, math.sqrt

local function Sub(parent, key)
    local child = parent[key]
    if type(child) ~= "table" then
        child = {}
        parent[key] = child
    end
    return child
end
ns.Sub = Sub

local Truthy = ns.Truthy

-- Where you stand: instance, north, west (whole yards) and the zone's map (nil if `noMap`).
-- Nil where positions are hidden or secret.
function Journey.Here(noMap)
    if not UnitPosition then return end
    local ok, north, west, _, instance = pcall(UnitPosition, "player")
    if not ok or issecret(north) or issecret(west) or issecret(instance) then return end
    if type(north) ~= "number" or type(west) ~= "number" or type(instance) ~= "number" then return end
    return instance, floor(north + 0.5), floor(west + 0.5), (not noMap) and ns.ZoneMap() or nil
end

-- World position to a map's 0-1 coordinates (best effort; nil if the map can't place it).
function Journey.ToMap(instance, north, west, uiMapID)
    if not (C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) or not uiMapID then return end
    local ok, mapID, position = pcall(C_Map.GetMapPosFromWorldPos, instance, CreateVector2D(north, west), uiMapID)
    if not ok or not position then return end
    local x, y = position:GetXY()
    if not x then return end
    return x, y, mapID
end

-- The record for the level you are now (created if needed).
function ns.LevelRecord()
    local level = UnitLevel("player")
    if issecret(level) or type(level) ~= "number" or level < 1 then return end
    return Sub(ns.db.levels, level)
end

-- Adds `amount` to `key` in each bucket in whole units, carrying the fraction over to next time.
local function AddWhole(carried, key, amount, buckets)
    local total = (carried[key] or 0) + amount
    local whole = floor(total)
    carried[key] = total - whole
    if whole <= 0 then return end
    for _, bucket in ipairs(buckets) do bucket[key] = (bucket[key] or 0) + whole end
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

local secondsCarried = {} -- fractions of a second not yet written, per state

local function TrackTime(seconds)
    local buckets = { ns.db.time, Sub(ns.Day(), "time") }
    local zone = ns.Zone()
    if zone then buckets[#buckets + 1] = Sub(ns.ZoneRecord(zone), "time") end
    local levelRecord = ns.LevelRecord()
    if levelRecord then buckets[#buckets + 1] = Sub(levelRecord, "tb") end
    AddWhole(secondsCarried, "online", seconds, buckets)
    for state, IsIn in pairs(STATES) do
        if IsIn() then AddWhole(secondsCarried, state, seconds, buckets) end
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

local lastSpot      -- { instance, north, west } the previous second's position
local jumped        -- a teleport since the path last looked: start a new segment
local yardsCarried = {}

local function TrackTravel()
    local instance, north, west = Journey.Here(true)
    if not instance then
        lastSpot = nil
        return
    end
    if lastSpot and lastSpot.instance == instance then
        local distance = sqrt((north - lastSpot.north) ^ 2 + (west - lastSpot.west) ^ 2)
        if distance > JUMP then
            jumped = true
        elseif distance > 0 then
            local buckets = { ns.db.travel, Sub(ns.Day(), "travel") }
            local levelRecord = ns.LevelRecord()
            if levelRecord then buckets[#buckets + 1] = Sub(levelRecord, "travel") end
            AddWhole(yardsCarried, Mode(), distance, buckets)
        end
    elseif lastSpot then
        jumped = true -- another instance
    end
    lastSpot = { instance = instance, north = north, west = west }
end

------------------------------------------------------------------------------
-- Path
------------------------------------------------------------------------------

local MIN_MOVE = 10     -- yards from the last recorded point before another is recorded
local STRAIGHT = 3      -- a point this close to the line through its neighbours is dropped...
local STRAIGHT_T = 60   -- ...unless that would leave a longer gap in time than this
local MAX_CHARS = 60000 -- one segment's string; a longer journey continues in a new segment

-- day.path = { { i = instanceID, m = map at its start, t = its first point's time, d = "token;token" } };
-- a token is "seconds,north,west" since the last point (the first: absolute), "m<map>|" first if the map changed.
local function Token(seconds, north, west, newMap)
    local token = ("%d,%d,%d"):format(seconds, north, west)
    if newMap then token = "m" .. newMap .. "|" .. token end
    return token
end

local segment -- the one being written: { ref, dayKey, instance, map, t, n, w (last written), pending }

local function Commit(point)
    local ref = segment.ref
    local token
    if segment.t == nil then
        token = Token(0, point.n, point.w)
        segment.map = point.map
        ref.d = token
    else
        token = Token(point.t - segment.t, point.n - segment.n, point.w - segment.w,
            point.map ~= segment.map and point.map)
        if point.map then segment.map = point.map end
        ref.d = ref.d .. ";" .. token
    end
    segment.t, segment.n, segment.w = point.t, point.n, point.w
end

local function Flush()
    if segment and segment.pending then
        Commit(segment.pending)
        segment.pending = nil
    end
end

local function EndSegment()
    Flush()
    segment = nil
end
Journey.EndSegment = EndSegment

-- How far `point` lies off the line from `from` to `to`.
local function OffLine(from, point, to)
    local dn, dw = to.n - from.n, to.w - from.w
    local length = sqrt(dn * dn + dw * dw)
    if length == 0 then return sqrt((point.n - from.n) ^ 2 + (point.w - from.w) ^ 2) end
    return math.abs((point.n - from.n) * dw - (point.w - from.w) * dn) / length
end

local function SamplePath()
    if jumped then
        jumped = false
        EndSegment()
    end
    local instance, north, west, map = Journey.Here()
    if not instance then
        EndSegment() -- hidden: pause; a new segment starts when it's back
        return
    end
    local today = ns.Today()
    if segment and (segment.dayKey ~= today or segment.instance ~= instance or #segment.ref.d > MAX_CHARS) then
        EndSegment()
    end
    local point = { t = time(), n = north, w = west, map = map }
    if not segment then
        local path = Sub(ns.Day(), "path")
        local ref = { i = instance, m = map, t = point.t, d = "" }
        path[#path + 1] = ref
        segment = { ref = ref, dayKey = today, instance = instance }
        Commit(point)
        return
    end
    local previous = segment.pending or { n = segment.n, w = segment.w, map = segment.map }
    local moved = sqrt((north - previous.n) ^ 2 + (west - previous.w) ^ 2)
    local mapChanged = map and previous.map and map ~= previous.map
    if moved <= MIN_MOVE and not mapChanged then return end
    local pending = segment.pending
    if pending and not mapChanged and pending.map == segment.map and point.t - segment.t <= STRAIGHT_T
        and OffLine({ n = segment.n, w = segment.w }, pending, point) < STRAIGHT then
        segment.pending = point -- still going straight: move the end of the line instead of adding a point
    else
        if pending then Commit(pending) end
        segment.pending = point
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
local function DecodeSegment(ref, points)
    points = points or {}
    local at, north, west, map = ref.t or 0, 0, 0, ref.m
    local first = true
    for token in (ref.d or ""):gmatch("[^;]+") do
        local newMap, rest = token:match("^m(%d+)|(.*)$")
        if newMap then
            map = tonumber(newMap)
            token = rest
        end
        local seconds, dn, dw = token:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        if seconds then
            if first then
                north, west = tonumber(dn), tonumber(dw)
                first = false
            else
                at, north, west = at + tonumber(seconds), north + tonumber(dn), west + tonumber(dw)
            end
            points[#points + 1] = { t = at, y = north, x = west, inst = ref.i, map = map }
        end
    end
    return points
end

-- The pending (not yet written) end of today's current segment, if `ref` is it.
local function WithPending(ref, points)
    if segment and segment.ref == ref and segment.pending then
        local pending = segment.pending
        points[#points + 1] = { t = pending.t, y = pending.n, x = pending.w, inst = ref.i,
            map = pending.map or segment.map }
    end
    return points
end

-- A day's path as segments: list of { inst, map, points = { {t, x, y, inst, map}, ... } }.
-- `day` is a day table or a "YYYY-MM-DD" key.
function Journey.Segments(day)
    day = DayTable(day)
    local segments = {}
    for _, ref in ipairs(day and day.path or {}) do
        local points = WithPending(ref, DecodeSegment(ref))
        if #points > 0 then segments[#segments + 1] = { inst = ref.i, map = ref.m, points = points } end
    end
    return segments
end

-- A day's path as one flat array of { t, x, y, inst, map, seg } (seg = segment index; a new
-- segment means don't join it to the point before).
function Journey.Decode(day)
    local flat = {}
    for i, each in ipairs(Journey.Segments(day)) do
        for _, point in ipairs(each.points) do
            point.seg = i
            flat[#flat + 1] = point
        end
    end
    return flat
end

-- A day's path ready for FrogLib.Lines (layer:Set(lines)); `style` = { r, g, b, a, width,
-- minimap } is copied onto each line. Only segments on `inst` if given.
function Journey.Lines(day, style, inst)
    local lines = {}
    for _, each in ipairs(Journey.Segments(day)) do
        if #each.points >= 2 and (not inst or each.inst == inst) then
            local coords = {}
            for _, point in ipairs(each.points) do
                coords[#coords + 1] = point.y
                coords[#coords + 1] = point.x
            end
            local line = { inst = each.inst, points = coords }
            for key, value in pairs(style or {}) do line[key] = value end
            lines[#lines + 1] = line
        end
    end
    return lines
end

------------------------------------------------------------------------------
-- Thinning old paths
------------------------------------------------------------------------------

local THIN = 100 -- yards between the points kept on a thinned day

local function Encode(points, instance, map)
    local tokens, last = {}, nil
    local lastMap = map
    for _, point in ipairs(points) do
        if not last then
            tokens[#tokens + 1] = Token(0, point.y, point.x)
        else
            tokens[#tokens + 1] = Token(point.t - last.t, point.y - last.y, point.x - last.x,
                point.map and point.map ~= lastMap and point.map)
        end
        last, lastMap = point, point.map or lastMap
    end
    return { i = instance, m = map, t = points[1] and points[1].t, d = table.concat(tokens, ";") }
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
            for _, ref in ipairs(day.path) do
                local points = DecodeSegment(ref)
                local thinned, last = {}, nil
                for index, point in ipairs(points) do
                    if not last or index == #points or point.map ~= last.map
                        or sqrt((point.x - last.x) ^ 2 + (point.y - last.y) ^ 2) >= THIN then
                        thinned[#thinned + 1] = point
                        last = point
                    end
                end
                if #thinned > 0 then kept[#kept + 1] = Encode(thinned, ref.i, ref.m) end
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
    local elapsed = lastTick and math.min(now - lastTick, 5) or 0
    lastTick = now
    ticks = (ticks or 0) + 1
    if elapsed > 0 then pcall(TrackTime, elapsed) end
    pcall(TrackTravel)
    if ticks % 2 == 0 then
        local ok, err = pcall(SamplePath)
        if not ok then
            segment = nil
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
    lastSpot = nil
    jumped = true
end)
ns.On("PLAYER_LOGOUT", function() pcall(Flush) end)
