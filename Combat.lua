local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- Combat notes for the bestiary, from what this client still tells addons: UNIT_COMBAT (hits,
-- misses, immunities, resists), UNIT_SPELLCAST_* (a mob cast something; the spell is secret) and
-- UNIT_AURA (debuffs on you and who cast them). A hit on you doesn't say who dealt it: its school goes
-- to the mob whose cast just finished, else only when every attacker is one kind (melee: exactly one).
-- How hard a hit lands is secret since Forever 1.60.1.70938: melee ranges already saved stay.

local CAST_WINDOW = 1.5              -- a spell hit this soon after a mob's cast is that cast's
local YOUR_WINDOW = 1.0              -- an immunity this soon after your cast is to that spell
local SWING_MIN, SWING_MAX = 0.8, 6  -- gaps outside this aren't one mob's swing timer
local AVOIDED = { MISS = true, DODGE = true, PARRY = true, BLOCK = true }
local SCHOOLS = {
    { 1, L["Physical"] }, { 2, L["Holy"] }, { 4, L["Fire"] }, { 8, L["Nature"] },
    { 16, L["Frost"] }, { 32, L["Shadow"] }, { 64, L["Arcane"] },
}

local Safe = FrogLib.Safe

function ns.SchoolName(mask)
    local names = {}
    for _, school in ipairs(SCHOOLS) do
        if bit.band(mask, school[1]) ~= 0 then names[#names + 1] = school[2] end
    end
    return #names > 0 and table.concat(names, "/") or L["unknown"]
end

local function Bump(counts, key)
    counts[key] = (counts[key] or 0) + 1
    return counts[key] == 1 -- true the first time: something new to show
end

-- The NPC behind a unit token, if it's one we can attack: id, guid.
local function EnemyNPC(unit)
    local guid = Safe(UnitGUID(unit))
    local id = ns.NpcID(guid)
    if not id or not Safe(UnitCanAttack("player", unit)) then return end
    return id, guid
end

-- Combat events arrive once per token a unit has, so your target's also come as its nameplate;
-- only target and nameplates are read, and a repeat from another token in the same frame is
-- dropped. The same token twice in one frame is a second hit (with sizes secret, two look alike).
local seen, seenAt = {}, 0
local function Repeat(unit, ...)
    local now = GetTime()
    if now ~= seenAt then
        wipe(seen)
        seenAt = now
    end
    local signature = strjoin("|", tostringall(...))
    local mine = signature .. "|" .. unit
    local times = (seen[mine] or 0) + 1
    seen[mine] = times
    if times <= (seen[signature] or 0) then return true end
    seen[signature] = times
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
    local mob = ns.Mob(id, name)
    mob.combat = mob.combat or {}
    return mob.combat
end

------------------------------------------------------------------------------
-- Who's attacking you
------------------------------------------------------------------------------

-- The enemy NPCs targeting you, from nameplates. Nil if a hostile player is among them (their
-- hits can't be told apart). With nameplates off, falls back to a target that's on you.
local function Attackers()
    local list, anyPlate = {}, false
    for i = 1, 40 do
        local plate = "nameplate" .. i
        if UnitExists(plate) then
            anyPlate = true
            if Safe(UnitIsUnit(plate .. "target", "player")) and Safe(UnitCanAttack("player", plate)) then
                if Safe(UnitIsPlayer(plate)) ~= false then return nil end
                local id, guid = EnemyNPC(plate)
                if not id then return nil end
                list[#list + 1] = { id = id, guid = guid, unit = plate }
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
    if not id or Repeat(unit, event, guid, Safe(castGUID) or "") then return end
    local notes = Notes(id, unit)
    if not notes.casts then ns.Refresh() end
    notes.casts = (notes.casts or 0) + 1
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

local function OnMobHit(unit, action, flag, school)
    if not Watched(unit) then return end
    local id, guid = EnemyNPC(unit)
    if not id or Repeat(unit, "hit", guid, action, flag, school) then return end
    local notes = Notes(id, unit)
    local firstSeen = false

    if action == "IMMUNE" then
        notes.immune = notes.immune or {}
        firstSeen = Bump(notes.immune, school)
        if lastMine and GetTime() - lastMine.t <= YOUR_WINDOW then
            notes.immuneTo = notes.immuneTo or {}
            firstSeen = Bump(notes.immuneTo, lastMine.name) or firstSeen
        end
    elseif action == "RESIST" or (action == "WOUND" and flag and flag:find("RESIST")) then
        notes.resist = notes.resist or {}
        local resists = notes.resist[school] or { full = 0, partial = 0 }
        notes.resist[school] = resists
        firstSeen = resists.full + resists.partial == 0
        local how = action == "RESIST" and "full" or "partial"
        resists[how] = resists[how] + 1
    elseif action == "REFLECT" then
        notes.reflect = notes.reflect or {}
        firstSeen = Bump(notes.reflect, school)
    end

    -- Its defence: out of the physical swings at it, how many it dodged, parried or blocked.
    if school == 1 and (action == "WOUND" or AVOIDED[action]) then
        notes.defence = notes.defence or { swings = 0 }
        local defence = notes.defence
        defence.swings = defence.swings + 1
        if action == "DODGE" or action == "PARRY" or action == "BLOCK" then
            local key = action:lower()
            defence[key] = (defence[key] or 0) + 1
        end
    end
    if firstSeen then ns.Refresh() end
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
    local source = school ~= 1 and RecentCaster(now) or nil
    local byCast = source ~= nil
    source = source or OneKind(attackers)
    if not source then return end

    local notes = Notes(source.id, source.unit, source.guid)
    notes.attacks = notes.attacks or {}
    local firstSeen = Bump(notes.attacks, school)

    if school == 1 and not byCast and attackers and #attackers == 1 then
        notes.melee = notes.melee or { gaps = 0, gapTime = 0 }
        local melee = notes.melee
        -- amount is nil while the game keeps it secret; ranges pick up again if it stops.
        if action == "WOUND" and amount and amount > 0 and (not flag or flag == "") then
            melee.min = math.min(melee.min or amount, amount)
            melee.max = math.max(melee.max or amount, amount)
        end
        local last = lastSwing[source.guid]
        if last and now - last >= SWING_MIN and now - last <= SWING_MAX then
            melee.gaps = melee.gaps + 1
            melee.gapTime = melee.gapTime + (now - last)
        end
        lastSwing[source.guid] = now
    else
        wipe(lastSwing) -- someone else joined in; swing gaps would mix
    end
    if firstSeen then ns.Refresh() end
end

------------------------------------------------------------------------------
-- Debuffs mobs put on you, by name, when the client allows it
------------------------------------------------------------------------------

local function OnAura(changes)
    if not changes or Safe(changes.isFullUpdate) or not changes.addedAuras then return end
    for _, aura in ipairs(changes.addedAuras) do
        local harmful, name, caster = Safe(aura.isHarmful), Safe(aura.name), Safe(aura.sourceUnit)
        if harmful and name and caster then
            local id = EnemyNPC(caster)
            if id then
                local notes = Notes(id, caster)
                notes.inflicts = notes.inflicts or {}
                local debuff = notes.inflicts[name]
                if not debuff then
                    debuff = { n = 0, spell = Safe(aura.spellId), icon = Safe(aura.icon) }
                    notes.inflicts[name] = debuff
                    ns.Refresh()
                end
                debuff.n = debuff.n + 1
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
            OnMobHit(unit, action, flag, school)
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

-- A count table's keys, most counted first; Name turns each key into words.
local function KeysByCount(counts, Name)
    local list = {}
    for key, count in pairs(counts or {}) do list[#list + 1] = { key = key, n = count } end
    table.sort(list, function(first, second) return first.n > second.n end)
    local names = {}
    for _, entry in ipairs(list) do names[#names + 1] = Name and Name(entry.key) or entry.key end
    return names, list
end

local function Join(list)
    if #list <= 1 then return list[1] or "" end
    return table.concat(list, ", ", 1, #list - 1) .. L[" and "] .. list[#list]
end

local function Percent(count, total)
    return math.floor((count or 0) / total * 100 + 0.5) .. "%"
end

local DEFENCES = { { "dodge", L["dodges %s"] }, { "parry", L["parries %s"] }, { "block", L["blocks %s"] } }

-- Plain sentences for a mob's combat notes, most telling first; empty if nothing's known.
function ns.CombatLines(mob)
    local notes, lines = mob.combat, {}
    if not notes then return lines end

    local spells = KeysByCount(notes.immuneTo)
    if #spells > 0 then lines[#lines + 1] = L["Immune to %s."]:format(Join(spells)) end
    local schools = KeysByCount(notes.immune, ns.SchoolName)
    if #schools > 0 and #spells == 0 then
        lines[#lines + 1] = L["Shrugs off some %s attacks (immune)."]:format(Join(schools))
    end

    for school, resists in pairs(notes.resist or {}) do
        local parts = {}
        if resists.full > 0 then parts[#parts + 1] = L["%d fully"]:format(resists.full) end
        if resists.partial > 0 then parts[#parts + 1] = L["%d partly"]:format(resists.partial) end
        lines[#lines + 1] = string.format(L["Resists %s: %s."], ns.SchoolName(school), Join(parts))
    end
    local _, reflects = KeysByCount(notes.reflect)
    for _, entry in ipairs(reflects) do
        lines[#lines + 1] = string.format(L["Reflects %s spells (x%d)."], ns.SchoolName(entry.key), entry.n)
    end

    local deals = KeysByCount(notes.attacks, ns.SchoolName)
    if #deals > 0 then lines[#lines + 1] = L["Deals %s damage."]:format(Join(deals)) end

    local melee = notes.melee
    if melee and (melee.min or melee.gaps >= 3) then
        local hits = melee.min
            and (melee.min == melee.max and tostring(melee.min) or string.format("%d-%d", melee.min, melee.max))
        local every = melee.gaps >= 3 and melee.gapTime / melee.gaps
        if hits and every then
            lines[#lines + 1] = string.format(L["Melee hits for %s, about every %.1fs."], hits, every)
        elseif hits then
            lines[#lines + 1] = string.format(L["Melee hits for %s."], hits)
        else
            lines[#lines + 1] = string.format(L["Melee, about every %.1fs."], every)
        end
    end

    if notes.casts then
        local template = notes.casts == 1 and L["Casts spells (seen %d time)."] or L["Casts spells (seen %d times)."]
        lines[#lines + 1] = string.format(template, notes.casts)
    end
    local inflicts = {}
    for name in pairs(notes.inflicts or {}) do inflicts[#inflicts + 1] = name end
    if #inflicts > 0 then
        table.sort(inflicts)
        lines[#lines + 1] = L["Has afflicted you with %s."]:format(Join(inflicts))
    end

    local defence = notes.defence
    if defence and defence.swings >= 20 then
        local parts = {}
        for _, kind in ipairs(DEFENCES) do
            local count = defence[kind[1]] or 0
            if count > 0 then parts[#parts + 1] = kind[2]:format(Percent(count, defence.swings)) end
        end
        if #parts > 0 then
            lines[#lines + 1] = string.format(L["Against melee it %s (of %d swings)."], Join(parts), defence.swings)
        else
            lines[#lines + 1] = string.format(L["Hasn't dodged, parried or blocked in %d swings."], defence.swings)
        end
    end
    return lines
end
