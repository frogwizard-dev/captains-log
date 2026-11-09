local _, ns = ...
local issecret = ns.issecret

-- The smaller moments of a day, for the journey map: every kill, each fight, each experience
-- gain (kept compactly, as strings like the path), and log entries for gathering, travel (flights,
-- hearthstone, boats and zeppelins, your first mount), close calls, inns, vendors, trainers and
-- mailboxes, and rested experience running out.
--
-- Compact stores, per day, each a string of ";"-separated tokens of ","-separated fields, with
-- times in seconds from the day's start (ns.Moments.Base):
--   day.kl  kills:       "sec,pi,py,px,ref"        ref = npcID, or "n" .. name
--   day.fl  fights:      "sec0,sec1,low,name"      low = lowest health % ("" if unknown)
--   day.xl  experience:  "sec,amount,src,pi,py,px" src = k (kill), q (quest), e (exploring), o (other)
-- Positions are empty where they're hidden. Read them with ns.Moments.Read.

local M = {}
ns.Moments = M

local MAX_CHARS = 40000 -- per store per day; past this a day stops adding to it

local function Pass(ok, ...)
    if ok then return ... end
end
local function Call(fn, ...)
    if not fn then return end
    return Pass(pcall(fn, ...))
end
local function Num(v)
    if issecret(v) or type(v) ~= "number" then return nil end
    return v
end
local function Str(v)
    if issecret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end
local function Truthy(fn, ...)
    local v = Call(fn, ...)
    if issecret(v) then return false end
    return v and true or false
end
local function Clean(s) return (s:gsub("[,;]", " ")) end

function M.Base(key)
    return ns.DayTime(key) - 43200
end

local function Add(field, ...)
    local day = ns.Day()
    local s = day[field]
    if s and #s > MAX_CHARS then return end
    local parts = { ... }
    for i = 1, select("#", ...) do
        local v = parts[i]
        parts[i] = v == nil and "" or tostring(v)
    end
    local tok = table.concat(parts, ",", 1, select("#", ...))
    day[field] = s and (s .. ";" .. tok) or tok
end

local function Here()
    if not (ns.Journey and ns.Journey.Here) then return end
    return ns.Journey.Here(true)
end

-- A day's store as a list of field lists (strings; times turned back into epochs on field 1, and
-- 2 for fights). `key` is the day's "YYYY-MM-DD".
function M.Read(key, field)
    local day = ns.db.days[key]
    local s = day and day[field]
    local out = {}
    if type(s) ~= "string" or s == "" then return out end
    local base = M.Base(key)
    for tok in s:gmatch("[^;]+") do
        local f = {}
        for v in (tok .. ","):gmatch("([^,]*),") do f[#f + 1] = v end
        f[1] = (tonumber(f[1]) or 0) + base
        if field == "fl" then f[2] = (tonumber(f[2]) or 0) + base end
        out[#out + 1] = f
    end
    return out
end

------------------------------------------------------------------------------
-- Every kill (Tracker.lua calls this for each kill it counts)
------------------------------------------------------------------------------

function M.Kill(id, name)
    local inst, n, w = Here()
    local ref = type(id) == "number" and id or (name and ("n" .. Clean(name))) or ""
    Add("kl", time() - M.Base(ns.Today()), inst, n, w, ref)
end

------------------------------------------------------------------------------
-- Experience gains (Tracker.lua's gain, Stats.lua's hint of where it came from)
------------------------------------------------------------------------------

local hints = {} -- { src, at }

function M.XPSource(src)
    hints[#hints + 1] = { src = src, at = GetTime() }
    if #hints > 8 then table.remove(hints, 1) end
end

function M.XP(gain)
    if type(gain) ~= "number" or gain <= 0 then return end
    local at, t = GetTime(), time()
    local inst, n, w = Here()
    -- The chat line naming the source can come just before or just after the gain.
    C_Timer.After(0.5, function()
        local src = "o"
        for i = #hints, 1, -1 do
            if math.abs(hints[i].at - at) <= 2 then
                src = hints[i].src
                table.remove(hints, i)
                break
            end
        end
        Add("xl", t - M.Base(ns.Today()), gain, src, inst, n, w)
    end)
end

-- Rested experience running out.
local lastRested
local function CheckRested()
    local ex = Call(GetXPExhaustion)
    if issecret(ex) then return end
    local maxLevel = (GetMaxPlayerLevel and Call(GetMaxPlayerLevel)) or 60
    local lvl = Num(UnitLevel("player")) or 0
    if lastRested and lastRested > 0 and not ex and lvl < maxLevel then
        ns.Log("restedgone", {})
    end
    lastRested = ex or 0
end
ns.On("PLAYER_XP_UPDATE", function() pcall(CheckRested) end)
ns.On("UPDATE_EXHAUSTION", function() pcall(CheckRested) end)

------------------------------------------------------------------------------
-- Gathering: loot opened just after a gathering cast
------------------------------------------------------------------------------

local GATHER_SPELLS = { herb = 2366, ore = 2575, skin = 8613 }
local gatherNames -- [localized spell name] = what
local lastGather   -- { what, at }
local lastCastAt = 0

local function SpellName(id)
    local n = Call(C_Spell and C_Spell.GetSpellName, id)
    if not Str(n) then n = Call(GetSpellInfo, id) end
    return Str(n)
end

local function GatherKind(spellID)
    if not gatherNames then
        gatherNames = {}
        for what, id in pairs(GATHER_SPELLS) do
            local n = SpellName(id)
            if n then gatherNames[n] = what end
        end
    end
    local n = SpellName(spellID)
    return n and gatherNames[n]
end

-- Several of the same thing in a row share one line.
local function LogGather(what, id, n)
    local events = ns.Day().events
    for i = #events, math.max(1, #events - 10), -1 do
        local e = events[i]
        if e.k == "gather" and e.id == id and e.what == what and time() - (e.last or e.t) < 120 then
            e.n = e.n + n
            e.last = time()
            ns.Refresh()
            return
        end
    end
    ns.Log("gather", { what = what, id = id, n = n })
end

local gatherReadAt
local function ReadGather()
    if not lastGather or GetTime() - lastGather.at > 6 then return end
    if IsFishingLoot and Truthy(IsFishingLoot) then return end -- the fishing journal has it
    local found = false
    for slot = 1, GetNumLootItems() do
        local link = Str(GetLootSlotLink(slot))
        local itemID = link and C_Item.GetItemInfoInstant(link)
        if itemID then
            local _, _, qty = GetLootSlotInfo(slot)
            qty = Num(qty)
            LogGather(lastGather.what, itemID, (qty and qty > 0) and qty or 1)
            found = true
        end
    end
    if found then
        lastGather = nil
        gatherReadAt = GetTime()
    end
end
local function OnLoot()
    if gatherReadAt and GetTime() - gatherReadAt < 2 then return end
    local ok, err = pcall(ReadGather)
    if not ok then ns.Debug("Gathering: " .. tostring(err)) end
end
ns.On("LOOT_READY", OnLoot)
ns.On("LOOT_OPENED", OnLoot)

------------------------------------------------------------------------------
-- Travel
------------------------------------------------------------------------------

local HEARTHSTONE = 8690
local lastHearth = 0
local taxiPlan    -- { from, to } from the flight master's map
local taxiStart   -- { t, from, to } while flying
local CAPITALS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }

if hooksecurefunc and TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function(index)
        local plan = { to = Str(Call(TaxiNodeName, index)) }
        for i = 1, Num(Call(NumTaxiNodes)) or 0 do
            if Call(TaxiNodeGetType, i) == "CURRENT" then plan.from = Str(Call(TaxiNodeName, i)) end
        end
        taxiPlan = plan
    end)
end

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" or issecret(spellID) or type(spellID) ~= "number" then return end
    lastCastAt = GetTime()
    if spellID == HEARTHSTONE then
        lastHearth = GetTime()
        ns.Log("hearth", { from = ns.Zone(), to = Str(Call(GetBindLocation)) })
        return
    end
    local what = GatherKind(spellID)
    if what then lastGather = { what = what, at = GetTime() } end
end)

-- Boats and zeppelins: crossing to another continent without a flight, a hearthstone, a spell
-- cast just before (a portal or teleport) or dying. A best guess: a summons looks the same.
local lastInst, lastInstAt, lastZone
local lastPlace

local function CheckTransport(inst)
    local now = GetTime()
    if inst then
        if lastInst and inst ~= lastInst and now - lastInstAt < 180 and now - lastHearth > 90
            and now - lastCastAt > 25 and not taxiStart and not Truthy(UnitIsDeadOrGhost, "player") then
            ns.Log("transport", { from = lastZone, to = ns.Zone() })
        end
        lastInst, lastInstAt, lastZone = inst, now, ns.Zone() or lastZone
    end
end

local function CheckMount()
    if ns.db.firstMount or not Truthy(IsMounted) then return end
    ns.db.firstMount = true
    -- Someone who has ridden a good way already isn't on their first mount.
    if (ns.db.travel and ns.db.travel.mount or 0) > 2000 then return end
    ns.Log("mount", {})
end

local function CheckTaxi()
    local onTaxi = Truthy(UnitOnTaxi, "player")
    if onTaxi and not taxiStart then
        local plan = taxiPlan or {}
        taxiStart = { t = time(), from = plan.from or ns.Zone(), to = plan.to }
        taxiPlan = nil
    elseif not onTaxi and taxiStart then
        local s = taxiStart
        taxiStart = nil
        ns.Log("taxi", { from = s.from, to = s.to or ns.Zone(), s = time() - s.t })
    end
end

------------------------------------------------------------------------------
-- Combat: each fight, and close calls
------------------------------------------------------------------------------

local fight -- { t0, name, low }

local function SampleHealth()
    if not fight then return end
    local hp, max = UnitHealth("player"), UnitHealthMax("player")
    if issecret(hp) or issecret(max) or type(hp) ~= "number" or type(max) ~= "number" or max <= 0 then return end
    local pct = math.floor(hp / max * 100 + 0.5)
    if not fight.low or pct < fight.low then fight.low = pct end
end

ns.On("PLAYER_REGEN_DISABLED", function()
    local name
    if UnitExists("target") then
        local can = UnitCanAttack("player", "target")
        if not issecret(can) and can then name = Str(UnitName("target")) end
    end
    fight = { t0 = time(), name = name }
    pcall(SampleHealth)
end)

ns.On("UNIT_HEALTH", function(unit)
    if unit == "player" and fight then pcall(SampleHealth) end
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    if not fight then return end
    pcall(SampleHealth)
    local f = fight
    fight = nil
    local base = M.Base(ns.Today())
    Add("fl", f.t0 - base, time() - base, f.low, f.name and Clean(f.name) or nil)
    if f.low and f.low < 20 and not Truthy(UnitIsDeadOrGhost, "player") then
        ns.Log("closecall", { pct = f.low, vs = f.name })
    end
end)

------------------------------------------------------------------------------
-- Stops: inns, vendors, trainers, mailboxes
------------------------------------------------------------------------------

local function Once(day, key)
    day.seen = day.seen or {}
    if day.seen[key] then return false end
    day.seen[key] = true
    return true
end

local function Place()
    local sub = GetSubZoneText and Str(GetSubZoneText())
    return sub or ns.Zone()
end

ns.On("PLAYER_UPDATE_RESTING", function()
    if not Truthy(IsResting) then return end
    if CAPITALS[ns.ZoneMap() or 0] then return end
    local place = Place()
    if not place or not Once(ns.Day(), "rest:" .. place) then return end
    ns.Log("rest", { place = place, zone = ns.Zone() })
end)

local function Visit(kind)
    return function()
        local name = kind ~= "mail" and Str(UnitName("npc")) or nil
        local where = Place()
        local key = kind .. ":" .. (name or where or "?")
        if not Once(ns.Day(), key) then return end
        ns.Log("visit", { kind = kind, name = name, place = where })
    end
end
ns.On("MERCHANT_SHOW", Visit("merchant"))
ns.On("TRAINER_SHOW", Visit("trainer"))
ns.On("MAIL_SHOW", Visit("mail"))

------------------------------------------------------------------------------
-- The ticker
------------------------------------------------------------------------------

local function Tick()
    pcall(CheckTaxi)
    pcall(CheckMount)
    pcall(SampleHealth)
    local inst = Here()
    pcall(CheckTransport, inst)
end

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function()
        pcall(CheckRested)
        C_Timer.NewTicker(1, Tick)
    end)
end)
