local _, ns = ...
local issecret = ns.issecret

-- Combat notes for the bestiary, pieced together from what this client still tells addons:
--   UNIT_COMBAT        hits, misses, immunities and resists on you, your target and nameplates
--   UNIT_SPELLCAST_*   that a mob cast something, and when it finished (the spell is secret)
--   UNIT_AURA          debuffs landing on you and who cast them, where those aren't secret
-- A hit on you doesn't say who dealt it. A spell school is credited to the mob whose cast
-- finished just before it; otherwise a hit only counts when every mob attacking you is the same
-- kind, and melee range and swing speed only when exactly one is.

local CAST_WINDOW = 1.5              -- a spell hit this soon after a mob's cast is that cast's
local YOUR_WINDOW = 1.0              -- an immunity this soon after your cast is to that spell
local SWING_MIN, SWING_MAX = 0.8, 6  -- gaps outside this aren't one mob's swing timer
local AVOIDED = { MISS = true, DODGE = true, PARRY = true, BLOCK = true }
local SCHOOLS = {
    { 1, "Physical" }, { 2, "Holy" }, { 4, "Fire" }, { 8, "Nature" },
    { 16, "Frost" }, { 32, "Shadow" }, { 64, "Arcane" },
}

local function Safe(v)
    if issecret(v) then return nil end
    return v
end

function ns.SchoolName(mask)
    local names = {}
    for _, s in ipairs(SCHOOLS) do
        if bit.band(mask, s[1]) ~= 0 then names[#names + 1] = s[2] end
    end
    return #names > 0 and table.concat(names, "/") or "unknown"
end

local function Bump(t, key)
    t[key] = (t[key] or 0) + 1
    return t[key] == 1 -- true the first time: something new to show
end

-- The NPC behind a unit token, if it's one we can attack: id, guid.
local function EnemyNPC(unit)
    local guid = Safe(UnitGUID(unit))
    local id = ns.NpcID(guid)
    if not id or not Safe(UnitCanAttack("player", unit)) then return end
    return id, guid
end

-- Combat events arrive once per token a unit has, so your target's also come as its nameplate;
-- only target and nameplates are read, and a repeat within the same frame is dropped.
local seen, seenAt = {}, 0
local function Repeat(...)
    local now = GetTime()
    if now ~= seenAt then
        wipe(seen)
        seenAt = now
    end
    local sig = strjoin("|", tostringall(...))
    if seen[sig] then return true end
    seen[sig] = true
    return false
end

local function Watched(unit)
    return unit == "target" or unit:match("^nameplate%d+$")
end

-- guid: only take the unit's name if the token still points at that mob (nameplate tokens
-- get reused as plates come and go).
local function Notes(id, unit, guid)
    local name
    if not guid or Safe(UnitGUID(unit)) == guid then name = Safe(UnitName(unit)) end
    local m = ns.Mob(id, name)
    m.combat = m.combat or {}
    return m.combat
end

------------------------------------------------------------------------------
-- Who's attacking you
------------------------------------------------------------------------------

-- The enemy NPCs targeting you, from nameplates. Nil if a hostile player is among them (their
-- hits can't be told apart). With nameplates off, falls back to a target that's on you.
local function Attackers()
    local list, anyPlate = {}, false
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) then
            anyPlate = true
            if Safe(UnitIsUnit(u .. "target", "player")) and Safe(UnitCanAttack("player", u)) then
                if Safe(UnitIsPlayer(u)) ~= false then return nil end
                local id, guid = EnemyNPC(u)
                if not id then return nil end
                list[#list + 1] = { id = id, guid = guid, unit = u }
            end
        end
    end
    if not anyPlate and UnitExists("target") and Safe(UnitIsUnit("targettarget", "player")) then
        local id, guid = EnemyNPC("target")
        if id then list[1] = { id = id, guid = guid, unit = "target" } end
    end
    return list
end

-- The one kind of mob attacking you, or nil if there's none or a mix.
local function OneKind(list)
    if not list or #list == 0 then return end
    for i = 2, #list do
        if list[i].id ~= list[1].id then return end
    end
    return list[1]
end

------------------------------------------------------------------------------
-- Casts: yours (to name immunities) and mobs' (to credit spell schools)
------------------------------------------------------------------------------

local lastMine          -- { name, t } your latest cast
local recentCasts = {}  -- { id, guid, unit, t } mob casts finished in the last CAST_WINDOW

local function OnCast(event, unit, castGUID, spellID)
    if unit == "player" then
        local name
        if not issecret(spellID) and C_Spell and C_Spell.GetSpellName then
            name = Safe(C_Spell.GetSpellName(spellID))
        end
        lastMine = name and { name = name, t = GetTime() } or nil
        return
    end
    if not Watched(unit) then return end
    local id, guid = EnemyNPC(unit)
    if not id or Repeat(event, guid, Safe(castGUID) or "") then return end
    local c = Notes(id, unit)
    if not c.casts then ns.Refresh() end
    c.casts = (c.casts or 0) + 1
    table.insert(recentCasts, { id = id, guid = guid, unit = unit, t = GetTime() })
end

-- The single kind of mob that finished a cast just now, if there is exactly one.
local function RecentCaster(now)
    for i = #recentCasts, 1, -1 do
        if now - recentCasts[i].t > CAST_WINDOW then table.remove(recentCasts, i) end
    end
    return OneKind(recentCasts)
end

------------------------------------------------------------------------------
-- Hits on mobs: immunities, resists, reflects, and how often they avoid melee
------------------------------------------------------------------------------

local function OnMobHit(unit, action, flag, amount, school)
    if not Watched(unit) then return end
    local id, guid = EnemyNPC(unit)
    if not id or Repeat("hit", guid, action, flag, amount, school) then return end
    local c = Notes(id, unit)
    local new = false

    if action == "IMMUNE" then
        c.immune = c.immune or {}
        new = Bump(c.immune, school)
        if lastMine and GetTime() - lastMine.t <= YOUR_WINDOW then
            c.immuneTo = c.immuneTo or {}
            new = Bump(c.immuneTo, lastMine.name) or new
        end
    elseif action == "RESIST" then
        c.resist = c.resist or {}
        c.resist[school] = c.resist[school] or { full = 0, partial = 0 }
        new = c.resist[school].full + c.resist[school].partial == 0
        c.resist[school].full = c.resist[school].full + 1
    elseif action == "WOUND" and flag and flag:find("RESIST") then
        c.resist = c.resist or {}
        c.resist[school] = c.resist[school] or { full = 0, partial = 0 }
        new = c.resist[school].full + c.resist[school].partial == 0
        c.resist[school].partial = c.resist[school].partial + 1
    elseif action == "REFLECT" then
        c.reflect = c.reflect or {}
        new = Bump(c.reflect, school)
    end

    -- Its defence: out of the physical swings at it, how many it dodged, parried or blocked.
    if school == 1 and (action == "WOUND" or AVOIDED[action]) then
        c.defence = c.defence or { swings = 0 }
        local d = c.defence
        d.swings = d.swings + 1
        if action == "DODGE" or action == "PARRY" or action == "BLOCK" then
            local key = action:lower()
            d[key] = (d[key] or 0) + 1
        end
    end
    if new then ns.Refresh() end
end

------------------------------------------------------------------------------
-- Hits on you: damage schools, melee range and swing speed
------------------------------------------------------------------------------

local lastSwing = {} -- guid -> time of its last melee swing at you (while it was alone on you)

local function OnYourHit(action, flag, amount, school)
    if action ~= "WOUND" and not AVOIDED[action] and action ~= "RESIST" and action ~= "IMMUNE" then return end
    local now = GetTime()
    local attackers = Attackers()
    -- Spells: whoever just finished casting. Melee never goes by casts: another mob's swing
    -- can land in the same moment.
    local src = school ~= 1 and RecentCaster(now) or nil
    local byCast = src ~= nil
    src = src or OneKind(attackers)
    if not src then return end

    local c = Notes(src.id, src.unit, src.guid)
    c.attacks = c.attacks or {}
    local new = Bump(c.attacks, school)

    if school == 1 and not byCast and attackers and #attackers == 1 then
        c.melee = c.melee or { gaps = 0, gapTime = 0 }
        local m = c.melee
        if action == "WOUND" and amount and amount > 0 and (not flag or flag == "") then
            m.min = math.min(m.min or amount, amount)
            m.max = math.max(m.max or amount, amount)
        end
        local last = lastSwing[src.guid]
        if last and now - last >= SWING_MIN and now - last <= SWING_MAX then
            m.gaps = m.gaps + 1
            m.gapTime = m.gapTime + (now - last)
        end
        lastSwing[src.guid] = now
    else
        wipe(lastSwing) -- someone else joined in; swing gaps would mix
    end
    if new then ns.Refresh() end
end

------------------------------------------------------------------------------
-- Debuffs mobs put on you, by name, when the client allows it
------------------------------------------------------------------------------

local function OnAura(info)
    if not info or Safe(info.isFullUpdate) or not info.addedAuras then return end
    for _, aura in ipairs(info.addedAuras) do
        local harmful, name, src = Safe(aura.isHarmful), Safe(aura.name), Safe(aura.sourceUnit)
        if harmful and name and src then
            local id = EnemyNPC(src)
            if id then
                local c = Notes(id, src)
                c.inflicts = c.inflicts or {}
                local e = c.inflicts[name]
                if not e then
                    e = { n = 0, spell = Safe(aura.spellId), icon = Safe(aura.icon) }
                    c.inflicts[name] = e
                    ns.Refresh()
                end
                e.n = e.n + 1
            end
        end
    end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_COMBAT")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, unit, ...)
    if not ns.db or issecret(unit) then return end
    if event == "UNIT_COMBAT" then
        local action, flag, amount, school = ...
        action, flag, amount, school = Safe(action), Safe(flag), Safe(amount), Safe(school)
        if not action or not school then return end
        if unit == "player" then
            OnYourHit(action, flag, amount, school)
        else
            OnMobHit(unit, action, flag, amount, school)
        end
    elseif event == "UNIT_AURA" then
        -- Aura data can be locked down in some content; skip rather than error.
        pcall(OnAura, ...)
    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(lastSwing)
        wipe(recentCasts)
    else
        OnCast(event, unit, ...)
    end
end)

------------------------------------------------------------------------------
-- The bestiary's "In battle" lines
------------------------------------------------------------------------------

local function ByCount(t)
    local list = {}
    for k, n in pairs(t or {}) do list[#list + 1] = { key = k, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    return list
end

local function Join(list)
    if #list <= 1 then return list[1] or "" end
    return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

local function Pct(n, total)
    return math.floor((n or 0) / total * 100 + 0.5) .. "%"
end

-- Plain sentences for a mob's combat notes, most telling first; empty if nothing's known.
function ns.CombatLines(m)
    local c, lines = m.combat, {}
    if not c then return lines end

    local spells = {}
    for _, e in ipairs(ByCount(c.immuneTo)) do spells[#spells + 1] = e.key end
    if #spells > 0 then lines[#lines + 1] = "Immune to " .. Join(spells) .. "." end
    local schools = {}
    for _, e in ipairs(ByCount(c.immune)) do schools[#schools + 1] = ns.SchoolName(e.key) end
    if #schools > 0 and #spells == 0 then
        lines[#lines + 1] = "Shrugs off some " .. Join(schools) .. " attacks (immune)."
    end

    for school, r in pairs(c.resist or {}) do
        local parts = {}
        if r.full > 0 then parts[#parts + 1] = r.full .. " fully" end
        if r.partial > 0 then parts[#parts + 1] = r.partial .. " partly" end
        lines[#lines + 1] = string.format("Resists %s: %s.", ns.SchoolName(school), Join(parts))
    end
    for _, e in ipairs(ByCount(c.reflect)) do
        lines[#lines + 1] = string.format("Reflects %s spells (x%d).", ns.SchoolName(e.key), e.n)
    end

    local deals = {}
    for _, e in ipairs(ByCount(c.attacks)) do deals[#deals + 1] = ns.SchoolName(e.key) end
    if #deals > 0 then lines[#lines + 1] = "Deals " .. Join(deals) .. " damage." end

    local mel = c.melee
    if mel and (mel.min or mel.gaps >= 3) then
        local s = "Melee"
        if mel.min then
            s = s .. (mel.min == mel.max and (" hits for " .. mel.min) or string.format(" hits for %d-%d", mel.min, mel.max))
        end
        if mel.gaps >= 3 then s = s .. string.format(", about every %.1fs", mel.gapTime / mel.gaps) end
        lines[#lines + 1] = s .. "."
    end

    if c.casts then
        lines[#lines + 1] = string.format("Casts spells (seen %d %s).", c.casts, c.casts == 1 and "time" or "times")
    end
    local inflicts = {}
    for name in pairs(c.inflicts or {}) do inflicts[#inflicts + 1] = name end
    if #inflicts > 0 then
        table.sort(inflicts)
        lines[#lines + 1] = "Has afflicted you with " .. Join(inflicts) .. "."
    end

    local d = c.defence
    if d and d.swings >= 20 then
        local parts = {}
        if (d.dodge or 0) > 0 then parts[#parts + 1] = "dodges " .. Pct(d.dodge, d.swings) end
        if (d.parry or 0) > 0 then parts[#parts + 1] = "parries " .. Pct(d.parry, d.swings) end
        if (d.block or 0) > 0 then parts[#parts + 1] = "blocks " .. Pct(d.block, d.swings) end
        if #parts > 0 then
            lines[#lines + 1] = string.format("Against melee it %s (of %d swings).", Join(parts), d.swings)
        else
            lines[#lines + 1] = string.format("Hasn't dodged, parried or blocked in %d swings.", d.swings)
        end
    end
    return lines
end
