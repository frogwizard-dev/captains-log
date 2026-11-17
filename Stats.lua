local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- Lifetime counters (db.stats) and their milestones, and the newer timeline entries: equip,
-- spell, rep, skill, guild, duel, firstitem. Chat lines are matched with patterns built from the
-- game's own strings, so they work in any language.

local Num, Str, Call = ns.PlainNumber, ns.PlainText, ns.Call

-- A game format string ("%s dies, you gain %d experience.", also "%2$s") as a Lua pattern, and
-- for each capture which of the format's arguments it is.
local function Pattern(template)
    if type(template) ~= "string" then return end
    local order, count = {}, 0
    local pattern = template:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%(%d*)%%?%$?([sd])", function(position, kind)
        count = count + 1
        order[#order + 1] = tonumber(position) or count
        return kind == "d" and "(%d+)" or "(.-)"
    end)
    return { pat = "^" .. pattern .. "$", order = order, len = #template }
end

-- Matches `text` against a pattern from Pattern(); returns the format's arguments in order.
local function Match(matcher, text)
    if not matcher then return end
    local captures = { text:match(matcher.pat) }
    if #captures == 0 then return end
    local args = {}
    for i, capture in ipairs(captures) do args[matcher.order[i]] = capture end
    return args
end

local function Patterns(names)
    local list = {}
    for _, name in ipairs(names) do
        local matcher = Pattern(_G[name])
        if matcher then
            matcher.name = name
            list[#list + 1] = matcher
        end
    end
    table.sort(list, function(first, second) return first.len > second.len end) -- the most specific first
    return list
end

local function MatchAny(list, text)
    for _, matcher in ipairs(list) do
        local args = Match(matcher, text)
        if args then return args, matcher end
    end
end

------------------------------------------------------------------------------
-- Counters and milestones
------------------------------------------------------------------------------

-- 1, 10, 50, then every 100 to 1000, every 250 to 10,000, every 500 to 50,000 and every 1000
-- after that. Worked out as it goes rather than listed.
local function NextMilestone(after)
    if after < 1 then return 1 end
    if after < 10 then return 10 end
    if after < 50 then return 50 end
    local step = after < 1000 and 100 or (after < 10000 and 250 or (after < 50000 and 500 or 1000))
    return (math.floor(after / step) + 1) * step
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
    jumps = L["Jumps"], herbs = L["Herbs picked"], ore = L["Ore mined"], skins = L["Hides skinned"],
}

-- Milestones in the words you'd use: "You've jumped 200 times!", and the first on its own
-- ("Your first jump!").
local MILESTONE_WORDS = {
    kills = L["You've slain %s creatures!"], deaths = L["You've died %s times."],
    quests = L["You've completed %s quests!"], looted = L["You've looted %s items!"],
    crafted = L["You've made %s items!"], flights = L["You've taken %s flights!"],
    hearths = L["You've hearthed home %s times!"], fish = L["You've caught %s fish!"],
    dungeons = L["You've been into %s dungeons!"], bosses = L["You've defeated %s bosses!"],
    duelsWon = L["You've won %s duels!"], duelsLost = L["You've lost %s duels."],
    jumps = L["You've jumped %s times!"], herbs = L["You've picked %s herbs!"],
    ore = L["You've mined %s ore!"], skins = L["You've skinned %s hides!"],
}
local FIRST_WORDS = {
    kills = L["Your first kill!"], deaths = L["Your first death."], quests = L["Your first quest done!"],
    looted = L["Your first item looted!"], crafted = L["Your first item made!"],
    flights = L["Your first flight!"], hearths = L["Your first trip home by hearthstone!"],
    fish = L["Your first fish!"], dungeons = L["Your first dungeon!"], bosses = L["Your first boss defeated!"],
    duelsWon = L["Your first duel won!"], duelsLost = L["Your first duel lost."],
    jumps = L["Your first jump!"], herbs = L["Your first herb picked!"], ore = L["Your first ore mined!"],
    skins = L["Your first hide skinned!"],
}

function ns.MilestoneSaying(stat, count)
    if count == 1 and FIRST_WORDS[stat] then return FIRST_WORDS[stat] end
    if MILESTONE_WORDS[stat] then return MILESTONE_WORDS[stat]:format(ns.Number(count)) end
    return L["%s, %s."]:format(ns.StatName(stat), ns.Number(count))
end

-- Jumps: the jump key, on the ground (not mid-air, swimming, flying or on a flight), counted for
-- life and for the day. A post-hook, so the jump itself is untouched.
local lastJump = 0
if JumpOrAscendStart then
    hooksecurefunc("JumpOrAscendStart", function()
        if not ns.db then return end
        local now = GetTime()
        if now - lastJump < 0.3 then return end
        if (IsFalling and IsFalling()) or (IsSwimming and IsSwimming()) or (IsFlying and IsFlying())
            or (UnitOnTaxi and UnitOnTaxi("player")) then return end
        lastJump = now
        ns.Count("jumps")
        local day = ns.Day()
        day.jumps = (day.jumps or 0) + 1
        ns.Refresh() -- the count on an open page goes up as you jump
    end)
end

function ns.StatName(stat)
    return ns.STAT_NAMES[stat] or stat
end

function ns.Count(stat, amount)
    amount = amount or 1
    if type(amount) ~= "number" or amount <= 0 then return end
    local stats = ns.db.stats
    local before = stats[stat] or 0
    local after = before + amount
    stats[stat] = after
    if QUIET[stat] then return end
    local milestone = NextMilestone(before)
    while milestone <= after do
        ns.Log("milestone", { stat = stat, n = milestone })
        -- Said in chat, every one, so it isn't missed: an icon, a gold "You've reached a
        -- milestone!" and what it is, said plainly ("You've jumped 200 times!").
        local line = "|TInterface\\Icons\\Ability_Warrior_BattleShout:16:16:0:0|t |cffffd100"
            .. L["You've reached a milestone!"] .. "|r |cffffffff" .. ns.MilestoneSaying(stat, milestone) .. "|r"
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(line) else ns.Print(line) end
        milestone = NextMilestone(milestone)
    end
end

-- Counters start from what the book already knows, so an old character's first kill after the
-- update isn't hailed as their first.
local function Seed()
    if ns.db.statsSeeded then return end
    ns.db.statsSeeded = true
    local stats = ns.db.stats
    local kills = 0
    for _, mob in pairs(ns.db.mobs) do kills = kills + (mob.kills or 0) end
    local quests = 0
    for _, quest in pairs(ns.db.quests) do
        if quest.completed then quests = quests + (quest.timesDone or 1) end
    end
    local bosses = 0
    for _, run in ipairs(ns.db.runs) do bosses = bosses + #(run.bosses or {}) end
    stats.kills = math.max(stats.kills or 0, kills)
    stats.quests = math.max(stats.quests or 0, quests)
    stats.deaths = math.max(stats.deaths or 0, #ns.db.deaths)
    stats.dungeons = math.max(stats.dungeons or 0, #ns.db.runs)
    stats.bosses = math.max(stats.bosses or 0, bosses)
    stats.fish = math.max(stats.fish or 0, (ns.db.fishing and ns.db.fishing.n) or 0)
end

-- Dungeons entered (Dungeons.lua logs each new run).
do
    local Log = ns.Log
    ns.Log = function(kind, line)
        local logged = Log(kind, line)
        if kind == "dungeon" and not line.returning then ns.Count("dungeons") end
        return logged
    end
end

ns.On("ENCOUNTER_END", function(_, _, _, _, success)
    if not issecret(success) and success == 1 and ns.ActiveRun() then ns.Count("bosses") end
end)
ns.On("PLAYER_DEAD", function() ns.Count("deaths") end)
ns.On("QUEST_TURNED_IN", function(_, xp)
    ns.Count("quests")
    if ns.Moments then ns.Moments.XPSource("q") end
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
    if ns.Moments then ns.Moments.XPSource("e") end
    ns.Count("xpExplore", xp)
end

local function OnXP(text)
    if issecret(text) or type(text) ~= "string" then return end
    local args, matcher = MatchAny(XP_KILL, text)
    if args then
        local xp = tonumber(args[2])
        if not xp then return end
        local bonus = BONUS[matcher.name] and tonumber((tostring(args[3] or "")):match("(%d+)")) or 0
        if bonus > xp then bonus = 0 end
        if ns.Moments then ns.Moments.XPSource("k") end
        ns.Count("xpKill", xp - bonus)
        if bonus > 0 then ns.Count("xpRested", bonus) end
        return
    end
    Explored(MatchAny(XP_EXPLORE, text))
end
ns.On("CHAT_MSG_COMBAT_XP_GAIN", OnXP)

------------------------------------------------------------------------------
-- Items: looted, made, and the first of each
------------------------------------------------------------------------------

local LOOTED = Patterns({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF" })
local CREATED = Patterns({ "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF" })
local RECEIVED = Patterns({ "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF" })

local function ItemQuality(link, id)
    local quality = C_Item and C_Item.GetItemQualityByID and Num(Call(C_Item.GetItemQualityByID, id))
    if quality then return quality end
    local _, _, infoQuality = Call(GetItemInfo, id)
    if Num(infoQuality) then return infoQuality end
    -- Not cached yet: read the link's colour.
    local hex = link:match("|c(%x%x%x%x%x%x%x%x)")
    if hex and ITEM_QUALITY_COLORS then
        hex = hex:lower()
        for i = 0, 8 do
            local color = ITEM_QUALITY_COLORS[i]
            if color and color.hex and color.hex:lower():find(hex, 1, true) then return i end
        end
    end
end

local function FirstItem(link, id)
    local seen = ns.db.seenItems
    if seen[id] then return end
    local quality = ItemQuality(link, id)
    if not quality or quality < 2 then return end -- uncommon or better only, to keep the book small
    seen[id] = true
    ns.Log("firstitem", { id = id, q = quality })
end
ns.FirstItem = FirstItem

ns.On("CHAT_MSG_LOOT", function(text)
    if issecret(text) or type(text) ~= "string" then return end
    local kind, args = "crafted", MatchAny(CREATED, text)
    if not args then kind, args = "looted", MatchAny(LOOTED, text) end
    if not args then kind, args = "received", MatchAny(RECEIVED, text) end
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
    for _, mob in pairs(ns.db.mobs) do
        for id in pairs(mob.drops or {}) do
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
    local _, _, quality, itemLevel = Call(GetItemInfo, id)
    return Num(itemLevel), Num(quality)
end

local function IsUpgrade(newID, oldID)
    if not oldID then return true end
    local newLevel, newQuality = ItemLevel(newID)
    local oldLevel, oldQuality = ItemLevel(oldID)
    if newLevel and oldLevel and newLevel ~= oldLevel then return newLevel > oldLevel end
    if newQuality and oldQuality then return newQuality > oldQuality end
    return false
end

ns.On("PLAYER_EQUIPMENT_CHANGED", function(slot)
    slot = Num(slot)
    if not equipped or not slot or slot < 1 or slot > 19 then return end
    local change = pending[slot] or { orig = equipped[slot] }
    pending[slot] = change
    equipped[slot] = Num(Call(GetInventoryItemID, "player", slot))
    local token = {}
    change.token = token
    C_Timer.After(SWAP, function()
        if pending[slot] ~= change or change.token ~= token then return end
        pending[slot] = nil
        local current = Num(Call(GetInventoryItemID, "player", slot))
        if current ~= change.orig then
            -- Every change that held, for the journey map's portrait (day.gc: "t,slot,id;..."
            -- with id 0 for a slot emptied). The log only tells of upgrades.
            local day = ns.Day()
            local entry = ("%d,%d,%d"):format(time(), slot, current or 0)
            if #(day.gc or "") < 20000 then day.gc = day.gc and (day.gc .. ";" .. entry) or entry end
        end
        if current and current ~= change.orig and IsUpgrade(current, change.orig) then
            ns.Log("equip", { slot = slot, id = current, old = change.orig })
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

ns.On("CHAT_MSG_SYSTEM", function(text)
    if issecret(text) or type(text) ~= "string" then return end
    local args = MatchAny(DUELS, text)
    if args then
        local me = Str(Call(UnitName, "player"))
        if me and args[1] == me and args[2] then
            ns.Count("duelsWon")
            ns.Log("duel", { won = true, vs = args[2] })
        elseif me and args[2] == me and args[1] then
            ns.Count("duelsLost")
            ns.Log("duel", { won = false, vs = args[1] })
        end
        return
    end
    args = MatchAny(LEARN, text)
    if args and ready and GetTime() - lastSpellAt > 2 and args[1] then
        local name = args[1]:match("%[(.-)%]") or args[1]
        local id = tonumber(args[1]:match("spell:(%d+)"))
        ns.Log("spell", { id = id, name = id and nil or name })
        return
    end
    Explored(MatchAny(XP_EXPLORE, text))
end)

------------------------------------------------------------------------------
-- Reputation
------------------------------------------------------------------------------

-- [name] = { standing, factionID or nil }
local function Factions()
    local factions = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
        for i = 1, Num(Call(C_Reputation.GetNumFactions)) or 0 do
            local faction = Call(C_Reputation.GetFactionDataByIndex, i)
            if faction and not faction.isHeader or (faction and faction.isHeaderWithRep) then
                local name, standing = Str(faction.name), Num(faction.reaction)
                if name and standing then factions[name] = { standing, Num(faction.factionID) } end
            end
        end
    elseif GetNumFactions and GetFactionInfo then
        for i = 1, Num(Call(GetNumFactions)) or 0 do
            local name, _, standing, _, _, _, _, _, isHeader, _, hasRep, _, _, factionID = Call(GetFactionInfo, i)
            name, standing = Str(name), Num(standing)
            if name and standing and (not isHeader or hasRep) then factions[name] = { standing, Num(factionID) } end
        end
    end
    return factions
end

local function ScanFactions()
    local known = ns.db.factions
    for name, faction in pairs(Factions()) do
        local old = known[name]
        if old and old ~= faction[1] then
            ns.Log("rep", { name = name, id = faction[2], standing = faction[1], old = old })
        end
        known[name] = faction[1]
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
    local professions = {}
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines and C_SkillInfo.GetSkillLineInfo then
        for i = 1, Num(Call(C_SkillInfo.GetNumSkillLines)) or 0 do
            local line = Call(C_SkillInfo.GetSkillLineInfo, i)
            local id = line and Num(line.skillID)
            if id and PROFESSIONS[id] then
                local name, rank = Str(line.skillName or line.name), Num(line.rank or line.skillRank)
                if name and rank then professions[name] = { rank, id } end
            end
        end
        if next(professions) then return professions end
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
                professions[name] = { rank }
            end
        end
    end
    return professions
end

local function ScanSkills()
    local known = ns.db.skills
    local first = next(known) == nil and not ns.db.skillsSeeded
    ns.db.skillsSeeded = true
    for name, profession in pairs(Professions()) do
        local old, rank, id = known[name], profession[1], profession[2]
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
    local guild = ns.db.guild
    if not ns.db.guildKnown then
        ns.db.guildKnown = true
        ns.db.guild = name and { name = name, rank = rank, rankIndex = rankIndex } or nil
        return
    end
    if name and (not guild or guild.name ~= name) then
        ns.Log("guild", { action = "join", name = name, rank = rank })
    elseif not name and guild then
        ns.Log("guild", { action = "leave", name = guild.name })
    elseif name and guild and rankIndex and guild.rankIndex and rankIndex ~= guild.rankIndex then
        ns.Log("guild", { action = "rank", name = name, rank = rank, old = guild.rank, up = rankIndex < guild.rankIndex })
    else
        if guild and rank then guild.rank, guild.rankIndex = rank, rankIndex or guild.rankIndex end
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
