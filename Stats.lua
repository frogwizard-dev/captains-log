local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- Lifetime counters (db.stats) and their milestones, and the newer timeline entries: equip,
-- spell, rep, skill, guild, duel, firstitem. Chat lines are matched with patterns built from the
-- game's own strings, so they work in any language.

local function Num(v)
    if issecret(v) or type(v) ~= "number" then return nil end
    return v
end

local function Str(v)
    if issecret(v) or type(v) ~= "string" or v == "" then return nil end
    return v
end

local function Pass(ok, ...)
    if ok then return ... end
end

local function Call(fn, ...)
    if not fn then return end
    return Pass(pcall(fn, ...))
end

-- A game format string ("%s dies, you gain %d experience.", also "%2$s") as a Lua pattern, and
-- for each capture which of the format's arguments it is.
local function Pattern(fmt)
    if type(fmt) ~= "string" then return end
    local order, n = {}, 0
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%(%d*)%%?%$?([sd])", function(pos, kind)
        n = n + 1
        order[#order + 1] = tonumber(pos) or n
        return kind == "d" and "(%d+)" or "(.-)"
    end)
    return { pat = "^" .. p .. "$", order = order, len = #fmt }
end

-- Matches `msg` against a pattern from Pattern(); returns the format's arguments in order.
local function Match(pt, msg)
    if not pt then return end
    local caps = { msg:match(pt.pat) }
    if #caps == 0 then return end
    local args = {}
    for i, v in ipairs(caps) do args[pt.order[i]] = v end
    return args
end

local function Patterns(names)
    local list = {}
    for _, name in ipairs(names) do
        local pt = Pattern(_G[name])
        if pt then
            pt.name = name
            list[#list + 1] = pt
        end
    end
    table.sort(list, function(a, b) return a.len > b.len end) -- the most specific first
    return list
end

local function MatchAny(list, msg)
    for _, pt in ipairs(list) do
        local args = Match(pt, msg)
        if args then return args, pt end
    end
end

------------------------------------------------------------------------------
-- Counters and milestones
------------------------------------------------------------------------------

-- 1, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000 ...
local THRESHOLDS = { 1 }
do
    local base = 10
    while base <= 1e9 do
        THRESHOLDS[#THRESHOLDS + 1] = base
        THRESHOLDS[#THRESHOLDS + 1] = base * 2.5
        THRESHOLDS[#THRESHOLDS + 1] = base * 5
        base = base * 10
    end
end

-- Counters whose amounts are experience points: no milestones for them.
local QUIET = { xpKill = true, xpQuest = true, xpExplore = true, xpRested = true }

ns.STAT_NAMES = {
    kills = L["Creatures slain"], deaths = L["Deaths"], quests = L["Quests completed"],
    xpKill = L["Experience from kills"], xpQuest = L["Experience from quests"],
    xpExplore = L["Experience from exploring"], xpRested = L["Rested bonus experience"],
    looted = L["Items looted"], crafted = L["Items made"], flights = L["Flights taken"],
    hearths = L["Hearthstones used"], fish = L["Fish caught"], dungeons = L["Dungeons entered"],
    bosses = L["Bosses defeated"], duelsWon = L["Duels won"], duelsLost = L["Duels lost"],
}

function ns.StatName(stat)
    return ns.STAT_NAMES[stat] or stat
end

function ns.Count(stat, n)
    n = n or 1
    if type(n) ~= "number" or n <= 0 then return end
    local stats = ns.db.stats
    local old = stats[stat] or 0
    local new = old + n
    stats[stat] = new
    if QUIET[stat] then return end
    for _, th in ipairs(THRESHOLDS) do
        if th > new then break end
        if old < th then
            ns.Log("milestone", { stat = stat, n = th })
            if th >= 100 then
                ns.Print(L["Milestone: %s, %s."]:format(ns.StatName(stat), ns.Number(th)))
            end
        end
    end
end

-- Counters start from what the book already knows, so an old character's first kill after the
-- update isn't hailed as their first.
local function Seed()
    if ns.db.statsSeeded then return end
    ns.db.statsSeeded = true
    local s = ns.db.stats
    local kills = 0
    for _, m in pairs(ns.db.mobs) do kills = kills + (m.kills or 0) end
    local quests = 0
    for _, q in pairs(ns.db.quests) do
        if q.completed then quests = quests + (q.timesDone or 1) end
    end
    local bosses = 0
    for _, run in ipairs(ns.db.runs) do bosses = bosses + #(run.bosses or {}) end
    s.kills = math.max(s.kills or 0, kills)
    s.quests = math.max(s.quests or 0, quests)
    s.deaths = math.max(s.deaths or 0, #ns.db.deaths)
    s.dungeons = math.max(s.dungeons or 0, #ns.db.runs)
    s.bosses = math.max(s.bosses or 0, bosses)
    s.fish = math.max(s.fish or 0, (ns.db.fishing and ns.db.fishing.n) or 0)
end

-- Dungeons entered (Dungeons.lua logs each new run).
do
    local Log = ns.Log
    ns.Log = function(kind, data)
        local ev = Log(kind, data)
        if kind == "dungeon" and not data.returning then ns.Count("dungeons") end
        return ev
    end
end

ns.On("ENCOUNTER_END", function(_, _, _, _, success)
    if not issecret(success) and success == 1 and ns.ActiveRun() then ns.Count("bosses") end
end)
ns.On("PLAYER_DEAD", function() ns.Count("deaths") end)
ns.On("QUEST_TURNED_IN", function(_, xp)
    ns.Count("quests")
    xp = Num(xp)
    if xp and xp > 0 then ns.Count("xpQuest", xp) end
end)

local HEARTHSTONE = { [8690] = true }
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" or issecret(spellID) then return end
    if HEARTHSTONE[spellID] then ns.Count("hearths") end
end)

------------------------------------------------------------------------------
-- Experience by source
------------------------------------------------------------------------------

-- Kills: arg 1 the creature, 2 the experience, 3 the rested bonus ("+50"), 4 its kind.
local XP_KILL = Patterns({
    "COMBATLOG_XPGAIN_EXHAUSTION1", "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION1_RAID",
    "COMBATLOG_XPGAIN_EXHAUSTION2", "COMBATLOG_XPGAIN_EXHAUSTION2_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION2_RAID",
    "COMBATLOG_XPGAIN_EXHAUSTION4", "COMBATLOG_XPGAIN_EXHAUSTION4_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION4_RAID",
    "COMBATLOG_XPGAIN_EXHAUSTION5", "COMBATLOG_XPGAIN_EXHAUSTION5_GROUP", "COMBATLOG_XPGAIN_EXHAUSTION5_RAID",
    "COMBATLOG_XPGAIN_FIRSTPERSON", "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", "COMBATLOG_XPGAIN_FIRSTPERSON_RAID",
})
local BONUS = { -- exhaustion strings that are a rested bonus (4 and 5 are a penalty)
    COMBATLOG_XPGAIN_EXHAUSTION1 = true, COMBATLOG_XPGAIN_EXHAUSTION1_GROUP = true, COMBATLOG_XPGAIN_EXHAUSTION1_RAID = true,
    COMBATLOG_XPGAIN_EXHAUSTION2 = true, COMBATLOG_XPGAIN_EXHAUSTION2_GROUP = true, COMBATLOG_XPGAIN_EXHAUSTION2_RAID = true,
}
-- Exploring: arg 1 the place, 2 the experience.
local XP_EXPLORE = Patterns({ "ERR_ZONE_EXPLORED_XP" })

-- The same discovery can reach both the XP and the system channel: counted once.
local lastExplore, lastExploreAt
local function Explored(args)
    local xp = args and tonumber(args[2])
    if not xp then return end
    if lastExplore == args[1] and GetTime() - lastExploreAt < 5 then return end
    lastExplore, lastExploreAt = args[1], GetTime()
    ns.Count("xpExplore", xp)
end

local function OnXP(msg)
    if issecret(msg) or type(msg) ~= "string" then return end
    local args, pt = MatchAny(XP_KILL, msg)
    if args then
        local xp = tonumber(args[2])
        if not xp then return end
        local bonus = BONUS[pt.name] and tonumber((tostring(args[3] or "")):match("(%d+)")) or 0
        if bonus > xp then bonus = 0 end
        ns.Count("xpKill", xp - bonus)
        if bonus > 0 then ns.Count("xpRested", bonus) end
        return
    end
    Explored(MatchAny(XP_EXPLORE, msg))
end
ns.On("CHAT_MSG_COMBAT_XP_GAIN", OnXP)

------------------------------------------------------------------------------
-- Items: looted, made, and the first of each
------------------------------------------------------------------------------

local LOOTED = Patterns({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF" })
local CREATED = Patterns({ "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF" })
local RECEIVED = Patterns({ "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF" })

local function ItemQuality(link, id)
    local q = C_Item and C_Item.GetItemQualityByID and Num(Call(C_Item.GetItemQualityByID, id))
    if q then return q end
    local _, _, quality = Call(GetItemInfo, id)
    if Num(quality) then return quality end
    -- Not cached yet: read the link's colour.
    local hex = link:match("|c(%x%x%x%x%x%x%x%x)")
    if hex and ITEM_QUALITY_COLORS then
        hex = hex:lower()
        for i = 0, 8 do
            local c = ITEM_QUALITY_COLORS[i]
            if c and c.hex and c.hex:lower():find(hex, 1, true) then return i end
        end
    end
end

local function FirstItem(link, id)
    local seen = ns.db.seenItems
    if seen[id] then return end
    local q = ItemQuality(link, id)
    if not q then return end
    if q < 2 then return end -- uncommon or better only, to keep the book small
    seen[id] = true
    ns.Log("firstitem", { id = id, q = q })
end
ns.FirstItem = FirstItem

ns.On("CHAT_MSG_LOOT", function(msg)
    if issecret(msg) or type(msg) ~= "string" then return end
    local kind, args
    args = MatchAny(CREATED, msg)
    if args then kind = "crafted" else
        args = MatchAny(LOOTED, msg)
        if args then kind = "looted" else
            args = MatchAny(RECEIVED, msg)
            kind = args and "received"
        end
    end
    if not args then return end
    local link = args[1]
    local id = link and tonumber(link:match("item:(%d+)"))
    if not id then return end
    local qty = tonumber(args[2]) or 1
    if kind ~= "received" then ns.Count(kind, qty) end
    FirstItem(link, id)
end)

-- What you already own isn't new: items equipped, in your bags and dropped by creatures in the
-- bestiary are marked seen the first time this runs.
local function SeedItems()
    if ns.db.seenSeeded then return end
    ns.db.seenSeeded = true
    local seen = ns.db.seenItems
    for slot = 1, 19 do
        local id = Num(Call(GetInventoryItemID, "player", slot))
        if id then seen[id] = true end
    end
    local GetSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local GetID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if GetSlots and GetID then
        for bag = 0, 4 do
            for slot = 1, Num(Call(GetSlots, bag)) or 0 do
                local id = Num(Call(GetID, bag, slot))
                if id then seen[id] = true end
            end
        end
    end
    for _, m in pairs(ns.db.mobs) do
        for id in pairs(m.drops or {}) do
            if type(id) == "number" then seen[id] = true end
        end
    end
end

------------------------------------------------------------------------------
-- Equipment upgrades
------------------------------------------------------------------------------

local SWAP = 10 -- seconds: changing back within this isn't an upgrade
local equipped     -- [slot] = itemID, from the last reading
local pending = {} -- [slot] = { orig, token } a change waiting out SWAP

local function ItemLevel(id)
    local _, _, quality, ilvl = Call(GetItemInfo, id)
    return Num(ilvl), Num(quality)
end

local function IsUpgrade(new, old)
    if not old then return true end
    local nl, nq = ItemLevel(new)
    local ol, oq = ItemLevel(old)
    if nl and ol and nl ~= ol then return nl > ol end
    if nq and oq then return nq > oq end
    return false
end

ns.On("PLAYER_EQUIPMENT_CHANGED", function(slot)
    slot = Num(slot)
    if not equipped or not slot or slot < 1 or slot > 19 then return end
    local new = Num(Call(GetInventoryItemID, "player", slot))
    local p = pending[slot] or { orig = equipped[slot] }
    pending[slot] = p
    equipped[slot] = new
    local token = {}
    p.token = token
    C_Timer.After(SWAP, function()
        if pending[slot] ~= p or p.token ~= token then return end
        pending[slot] = nil
        local now = Num(Call(GetInventoryItemID, "player", slot))
        if now and now ~= p.orig and IsUpgrade(now, p.orig) then
            ns.Log("equip", { slot = slot, id = now, old = p.orig })
        end
    end)
end)

local function ReadEquipped()
    equipped = {}
    for slot = 1, 19 do equipped[slot] = Num(Call(GetInventoryItemID, "player", slot)) end
end

------------------------------------------------------------------------------
-- Spells
------------------------------------------------------------------------------

local ready = false -- a few seconds after login: the game re-announces things while loading
local lastSpellAt = 0
local LEARN = Patterns({ "ERR_LEARN_SPELL_S", "ERR_LEARN_ABILITY_S" })

ns.On("LEARNED_SPELL_IN_TAB", function(spellID)
    if not ready then return end
    spellID = Num(spellID)
    if not spellID then return end
    lastSpellAt = GetTime()
    ns.Log("spell", { id = spellID })
end)

------------------------------------------------------------------------------
-- Duels and the system channel
------------------------------------------------------------------------------

-- Arg 1 the winner, 2 the loser (DUEL_WINNER_RETREAT has the loser fleeing the winner).
local DUELS = Patterns({ "DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT", "DUEL_WINNER" })

local function MyName()
    return Str(Call(UnitName, "player"))
end

ns.On("CHAT_MSG_SYSTEM", function(msg)
    if issecret(msg) or type(msg) ~= "string" then return end
    local args = MatchAny(DUELS, msg)
    if args then
        local me = MyName()
        if me and args[1] == me and args[2] then
            ns.Count("duelsWon")
            ns.Log("duel", { won = true, vs = args[2] })
        elseif me and args[2] == me and args[1] then
            ns.Count("duelsLost")
            ns.Log("duel", { won = false, vs = args[1] })
        end
        return
    end
    args = MatchAny(LEARN, msg)
    if args and ready and GetTime() - lastSpellAt > 2 and args[1] then
        local name = args[1]:match("%[(.-)%]") or args[1]
        local id = tonumber(args[1]:match("spell:(%d+)"))
        ns.Log("spell", { id = id, name = id and nil or name })
        return
    end
    Explored(MatchAny(XP_EXPLORE, msg))
end)

------------------------------------------------------------------------------
-- Reputation
------------------------------------------------------------------------------

local function Factions()
    local out = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
        for i = 1, Num(Call(C_Reputation.GetNumFactions)) or 0 do
            local f = Call(C_Reputation.GetFactionDataByIndex, i)
            if f and not f.isHeader or (f and f.isHeaderWithRep) then
                local name, standing = Str(f.name), Num(f.reaction)
                if name and standing then out[name] = { standing, Num(f.factionID) } end
            end
        end
    elseif GetNumFactions and GetFactionInfo then
        for i = 1, Num(Call(GetNumFactions)) or 0 do
            local name, _, standing, _, _, _, _, _, isHeader, _, hasRep, _, _, factionID = Call(GetFactionInfo, i)
            name, standing = Str(name), Num(standing)
            if name and standing and (not isHeader or hasRep) then out[name] = { standing, Num(factionID) } end
        end
    end
    return out
end

local function ScanFactions()
    local known = ns.db.factions
    for name, f in pairs(Factions()) do
        local old = known[name]
        if old and old ~= f[1] then
            ns.Log("rep", { name = name, id = f[2], standing = f[1], old = old })
        end
        known[name] = f[1]
    end
end
ns.On("UPDATE_FACTION", function() if ready then pcall(ScanFactions) end end)

------------------------------------------------------------------------------
-- Professions
------------------------------------------------------------------------------

local PROFESSIONS = {
    [164] = true, [165] = true, [171] = true, [182] = true, [186] = true, [197] = true,
    [202] = true, [333] = true, [393] = true, [129] = true, [185] = true, [356] = true,
}
local FISHING = 356
local SKILL_STEPS = { 75, 150, 225, 300 }

-- [name] = { rank, skillID or nil }
local function Professions()
    local out = {}
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        for i = 1, Num(Call(C_SkillInfo.GetNumSkillLines)) or 0 do
            local s = Call(C_SkillInfo.GetSkillLineInfo, i)
            local id = s and Num(s.skillID)
            if id and PROFESSIONS[id] then
                local name, rank = Str(s.skillName or s.name), Num(s.rank or s.skillRank)
                if name and rank then out[name] = { rank, id } end
            end
        end
        if next(out) then return out end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        local trade = { [(TRADE_SKILLS or ""):gsub(":$", "")] = true, [(SECONDARY_SKILLS or ""):gsub(":$", "")] = true }
        local inTrade = false
        for i = 1, Num(Call(GetNumSkillLines)) or 0 do
            local name, header, _, rank = Call(GetSkillLineInfo, i)
            name = Str(name)
            if header then
                inTrade = name and trade[name] or false
            elseif inTrade and name and Num(rank) then
                out[name] = { rank }
            end
        end
    end
    return out
end

local function ScanSkills()
    local known = ns.db.skills
    local first = next(known) == nil and not ns.db.skillsSeeded
    ns.db.skillsSeeded = true
    for name, s in pairs(Professions()) do
        local old, rank, id = known[name], s[1], s[2]
        if not first then
            if not old then
                ns.Log("skill", { name = name, id = id, new = true })
            elseif rank > old and id ~= FISHING then -- fishing has its own entries (fishskill)
                for _, step in ipairs(SKILL_STEPS) do
                    if old < step and rank >= step then ns.Log("skill", { name = name, id = id, rank = step }) end
                end
            end
        end
        known[name] = rank
    end
end
ns.On("SKILL_LINES_CHANGED", function() if ready then pcall(ScanSkills) end end)

------------------------------------------------------------------------------
-- Guild
------------------------------------------------------------------------------

local function ScanGuild()
    local name, rank, rankIndex = Call(GetGuildInfo, "player")
    name, rank, rankIndex = Str(name), Str(rank), Num(rankIndex)
    local inGuild = Call(IsInGuild)
    if issecret(inGuild) then return end
    if not name and inGuild then return end -- not loaded yet
    local g = ns.db.guild
    if not ns.db.guildKnown then
        ns.db.guildKnown = true
        ns.db.guild = name and { name = name, rank = rank, rankIndex = rankIndex } or nil
        return
    end
    if name and (not g or g.name ~= name) then
        ns.Log("guild", { action = "join", name = name, rank = rank })
    elseif not name and g then
        ns.Log("guild", { action = "leave", name = g.name })
    elseif name and g and rankIndex and g.rankIndex and rankIndex ~= g.rankIndex then
        ns.Log("guild", { action = "rank", name = name, rank = rank, old = g.rank, up = rankIndex < g.rankIndex })
    else
        if g and rank then g.rank, g.rankIndex = rank, rankIndex or g.rankIndex end
        return
    end
    ns.db.guild = name and { name = name, rank = rank, rankIndex = rankIndex } or nil
end
ns.On("PLAYER_GUILD_UPDATE", function() if ready then pcall(ScanGuild) end end)
ns.On("GUILD_ROSTER_UPDATE", function() if ready then pcall(ScanGuild) end end)

------------------------------------------------------------------------------
-- Login
------------------------------------------------------------------------------

ns.On("PLAYER_LOGIN", function()
    pcall(Seed)
    C_Timer.After(10, function()
        pcall(SeedItems)
        pcall(ReadEquipped)
        pcall(ScanFactions)
        pcall(ScanSkills)
        pcall(ScanGuild)
        ready = true
    end)
end)
