local ADDON, ns = ...

-- Temporary test: "/log probe" records what this client tells addons about hits, misses and casts,
-- for you, your target, your pet and every nameplate, to find out whether immunities, resists and
-- attack schools can be learned per mob in a multi-mob pull. Everything is saved to
-- CaptainsLogDB.probe (last 1500 lines) for reading after a /reload; chat only shows the unusual
-- lines so a big pull doesn't bury it.

local MAX_LINES = 1500
local SCHOOLS = {
    { 1, "Physical" }, { 2, "Holy" }, { 4, "Fire" }, { 8, "Nature" },
    { 16, "Frost" }, { 32, "Shadow" }, { 64, "Arcane" },
}
-- Outcomes that happen every swing; saved but not printed.
local ROUTINE = { WOUND = true, MISS = true, DODGE = true, PARRY = true, BLOCK = true, HEAL = true }

local on = false
local skipped = {} -- [unit token kind] = events ignored (party/raid members etc.)
local frame = CreateFrame("Frame")

-- Anything printable, with secret values marked instead of touched.
local function Show(v)
    if ns.issecret(v) then return "<secret>" end
    if v == nil then return "nil" end
    local ok, s = pcall(tostring, v)
    return ok and s or "<error>"
end

-- A yes/no API answer: true, false or nil when it's secret or errors.
local function Ask(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok or ns.issecret(v) then return nil end
    return v
end

local function School(mask)
    if ns.issecret(mask) or type(mask) ~= "number" then return Show(mask) end
    local names = {}
    for _, s in ipairs(SCHOOLS) do
        if bit.band(mask, s[1]) ~= 0 then names[#names + 1] = s[2] end
    end
    if #names == 0 then return tostring(mask) end
    return mask .. " " .. table.concat(names, "/")
end

local function Who(unit)
    if not UnitExists(unit) then return "none" end
    local guid = UnitGUID(unit)
    local id = ns.issecret(guid) and "<secret>" or ns.NpcID(guid) or "-"
    local s = Show(UnitName(unit)) .. " #" .. id
    if unit ~= "target" and unit ~= "player" and Ask(UnitIsUnit, unit, "target") then
        s = s .. ", =target"
    end
    if unit ~= "player" then
        local onYou = Ask(UnitIsUnit, unit .. "target", "player")
        if onYou == nil then s = s .. ", on you?" elseif onYou then s = s .. ", on you" end
    end
    return s
end

-- How many enemy nameplates are targeting you right now ("3", or "2+?" if some answers were secret).
local function EnemiesOnYou()
    local count, unknown = 0, false
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) then
            local enemy = Ask(UnitCanAttack, "player", u)
            local onYou = Ask(UnitIsUnit, u .. "target", "player")
            if enemy == nil or onYou == nil then
                unknown = true
            elseif enemy and onYou then
                count = count + 1
            end
        end
    end
    return count .. (unknown and "+?" or "")
end

local function SpellName(spellID)
    if ns.issecret(spellID) then return "<secret>" end
    local name
    if C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, spellID)
        if ok then name = n end
    end
    return Show(name) .. " (" .. Show(spellID) .. ")"
end

local function Record(line, quiet)
    if not quiet then print("|cffd8b56aProbe|r " .. line) end
    local log = ns.db.probe
    log[#log + 1] = date("%H:%M:%S ") .. line
    while #log > MAX_LINES do table.remove(log, 1) end
end

-- Only you, your target/focus/pet and nameplates; party and raid members are counted and dropped.
local function Wanted(unit)
    if ns.issecret(unit) then return true end
    if unit == "player" or unit == "target" or unit == "focus" or unit == "pet"
        or unit:match("^nameplate%d+$") then
        return true
    end
    local kind = unit:match("^(%a+)") or unit
    skipped[kind] = (skipped[kind] or 0) + 1
    return false
end

local handlers = {}

handlers.UNIT_COMBAT = function(unit, action, flag, amount, school)
    if not Wanted(unit) then return end
    local who
    if unit == "player" then
        who = ("you; %s on you; target %s"):format(EnemiesOnYou(), Who("target"))
    else
        who = Who(unit)
    end
    local quiet = not ns.issecret(action) and ROUTINE[action]
    Record(("UNIT_COMBAT %s [%s] action=%s flag=%s amount=%s school=%s"):format(
        Show(unit), who, Show(action), Show(flag), Show(amount), School(school)), quiet)
end

local function Cast(kind)
    return function(unit, _, spellID)
        if not Wanted(unit) then return end
        local who = unit == "player" and "you" or (Show(unit) .. " [" .. Who(unit) .. "]")
        Record(("%s %s: %s"):format(kind, who, SpellName(spellID)), unit == "player")
    end
end
handlers.UNIT_SPELLCAST_START = Cast("cast start")
handlers.UNIT_SPELLCAST_CHANNEL_START = Cast("channel")
handlers.UNIT_SPELLCAST_SUCCEEDED = Cast("cast done")

handlers.UI_ERROR_MESSAGE = function(errorType, message)
    Record(("UI_ERROR %s: %s"):format(Show(errorType), Show(message)))
end

handlers.PLAYER_TARGET_CHANGED = function()
    Record("target is now " .. Who("target"), true)
end

-- No COMBAT_LOG_EVENT_UNFILTERED: registering it is a protected action on this client
-- (ADDON_ACTION_FORBIDDEN, which pcall doesn't suppress).

frame:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)

local function Register(event)
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    if not ok then Record(("can't register %s: %s"):format(event, Show(err))) end
end

function ns.Probe(arg)
    ns.db.probe = ns.db.probe or {}
    if arg == "clear" then
        wipe(ns.db.probe)
        ns.Print("probe lines cleared")
        return
    end
    on = not on
    if not on then
        frame:UnregisterAllEvents()
        local parts = {}
        for kind, n in pairs(skipped) do parts[#parts + 1] = kind .. "=" .. n end
        Record("probe off; skipped " .. (#parts > 0 and table.concat(parts, " ") or "nothing"))
        return
    end
    wipe(skipped)
    local _, build, _, toc = GetBuildInfo()
    Record(("probe v2 on (build %s, interface %s); target %s; %s on you"):format(
        Show(build), Show(toc), Who("target"), EnemiesOnYou()))
    for _, event in ipairs({
        "UNIT_COMBAT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START",
        "UNIT_SPELLCAST_SUCCEEDED", "UI_ERROR_MESSAGE", "PLAYER_TARGET_CHANGED",
    }) do
        Register(event)
    end
end
