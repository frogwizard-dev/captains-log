local _, ns = ...
local issecret = ns.issecret

-- The smaller moments of a day, for the journey map: every kill, fight and experience gain (kept as
-- compact strings, like the path), and log entries for gathering, travel (flights, hearthstone,
-- boats and zeppelins, your first mount), close calls, inns, vendors, trainers and mailboxes, and
-- rested experience running out.

local Moments = {}
ns.Moments = Moments

local MAX_CHARS = 40000 -- per store per day; past this a day stops adding to it

local Call, Num, Str, Truthy = ns.Call, ns.PlainNumber, ns.PlainText, ns.Truthy

-- A name with the stores' separators taken out.
local function NoSeparators(text) return (text:gsub("[,;]", " ")) end

function Moments.Base(key)
    return ns.DayTime(key) - 43200
end

-- day.kl kills "sec,pi,py,px,ref" (ref = npcID or "n" .. name), day.fl fights "sec0,sec1,low%,name", day.xl
-- experience "sec,amount,source,pi,py,px" (k, q, e, o); sec from Moments.Base, positions empty if hidden.
local function Add(field, ...)
    local day = ns.Day()
    local store = day[field]
    if store and #store > MAX_CHARS then return end
    local parts = { ... }
    for i = 1, select("#", ...) do
        local value = parts[i]
        parts[i] = value == nil and "" or tostring(value)
    end
    local token = table.concat(parts, ",", 1, select("#", ...))
    day[field] = store and (store .. ";" .. token) or token
end

local function Here()
    return ns.Journey.Here(true)
end

-- A day's store as a list of field lists (strings; times turned back into epochs on field 1, and
-- 2 for fights). `key` is the day's "YYYY-MM-DD".
function Moments.Read(key, field)
    local day = ns.db.days[key]
    local store = day and day[field]
    local entries = {}
    if type(store) ~= "string" or store == "" then return entries end
    local base = Moments.Base(key)
    for token in store:gmatch("[^;]+") do
        local fields = {}
        for value in (token .. ","):gmatch("([^,]*),") do fields[#fields + 1] = value end
        fields[1] = (tonumber(fields[1]) or 0) + base
        if field == "fl" then fields[2] = (tonumber(fields[2]) or 0) + base end
        entries[#entries + 1] = fields
    end
    return entries
end

------------------------------------------------------------------------------
-- Every kill (Tracker.lua calls this for each kill it counts)
------------------------------------------------------------------------------

function Moments.Kill(id, name)
    local instance, north, west = Here()
    local ref = type(id) == "number" and id or (name and ("n" .. NoSeparators(name))) or ""
    Add("kl", time() - Moments.Base(ns.Today()), instance, north, west, ref)
end

------------------------------------------------------------------------------
-- Experience gains (Tracker.lua's gain, Stats.lua's hint of where it came from)
------------------------------------------------------------------------------

local hints = {} -- { src, at }

function Moments.XPSource(source)
    hints[#hints + 1] = { src = source, at = GetTime() }
    if #hints > 8 then table.remove(hints, 1) end
end

function Moments.XP(gain)
    if type(gain) ~= "number" or gain <= 0 then return end
    local at, now = GetTime(), time()
    local instance, north, west = Here()
    -- The chat line naming the source can come just before or just after the gain.
    C_Timer.After(0.5, function()
        local source = "o"
        for i = #hints, 1, -1 do
            if math.abs(hints[i].at - at) <= 2 then
                source = hints[i].src
                table.remove(hints, i)
                break
            end
        end
        Add("xl", now - Moments.Base(ns.Today()), gain, source, instance, north, west)
    end)
end

-- Rested experience running out.
local lastRested
local function CheckRested()
    local rested = Call(GetXPExhaustion)
    if issecret(rested) then return end
    local maxLevel = (GetMaxPlayerLevel and Call(GetMaxPlayerLevel)) or 60
    local level = Num(UnitLevel("player")) or 0
    if lastRested and lastRested > 0 and not rested and level < maxLevel then
        ns.Log("restedgone", {})
    end
    lastRested = rested or 0
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
    local name = Call(C_Spell and C_Spell.GetSpellName, id)
    if not Str(name) then name = Call(GetSpellInfo, id) end
    return Str(name)
end

local function GatherKind(spellID)
    if not gatherNames then
        gatherNames = {}
        for what, id in pairs(GATHER_SPELLS) do
            local name = SpellName(id)
            if name then gatherNames[name] = what end
        end
    end
    local name = SpellName(spellID)
    return name and gatherNames[name]
end

-- Several of the same thing in a row share one line.
local GATHER_TALLY = { herb = "herbs", ore = "ore", skin = "skins" }
local function LogGather(what, id, count)
    if GATHER_TALLY[what] and ns.Count then ns.Count(GATHER_TALLY[what]) end
    local events = ns.Day().events
    for i = #events, math.max(1, #events - 10), -1 do
        local line = events[i]
        if line.k == "gather" and line.id == id and line.what == what and time() - (line.last or line.t) < 120 then
            line.n = line.n + count
            line.last = time()
            ns.Refresh()
            return
        end
    end
    ns.Log("gather", { what = what, id = id, n = count })
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
local lastInstance, lastInstanceAt, lastZone

local function CheckTransport(instance)
    local now = GetTime()
    if instance then
        if lastInstance and instance ~= lastInstance and now - lastInstanceAt < 180 and now - lastHearth > 90
            and now - lastCastAt > 25 and not taxiStart and not Truthy(UnitIsDeadOrGhost, "player") then
            ns.Log("transport", { from = lastZone, to = ns.Zone() })
        end
        lastInstance, lastInstanceAt, lastZone = instance, now, ns.Zone() or lastZone
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
        local flight = taxiStart
        taxiStart = nil
        ns.Log("taxi", { from = flight.from, to = flight.to or ns.Zone(), s = time() - flight.t })
    end
end

------------------------------------------------------------------------------
-- Combat: each fight, and close calls
------------------------------------------------------------------------------

local fight -- { t0, name, low }

local function SampleHealth()
    if not fight then return end
    local health, maxHealth = UnitHealth("player"), UnitHealthMax("player")
    if issecret(health) or issecret(maxHealth) or type(health) ~= "number" or type(maxHealth) ~= "number"
        or maxHealth <= 0 then return end
    local percent = math.floor(health / maxHealth * 100 + 0.5)
    if not fight.low or percent < fight.low then fight.low = percent end
end

ns.On("PLAYER_REGEN_DISABLED", function()
    local name
    if UnitExists("target") then
        local attackable = UnitCanAttack("player", "target")
        if not issecret(attackable) and attackable then name = Str(UnitName("target")) end
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
    local ended = fight
    fight = nil
    local base = Moments.Base(ns.Today())
    Add("fl", ended.t0 - base, time() - base, ended.low, ended.name and NoSeparators(ended.name) or nil)
    if ended.low and ended.low < 20 and not Truthy(UnitIsDeadOrGhost, "player") then
        ns.Log("closecall", { pct = ended.low, vs = ended.name })
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
    local subzone = GetSubZoneText and Str(GetSubZoneText())
    return subzone or ns.Zone()
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
    pcall(CheckTransport, (Here()))
end

ns.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function()
        pcall(CheckRested)
        C_Timer.NewTicker(1, Tick)
    end)
end)
