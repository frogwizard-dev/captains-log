local _, ns = ...
local L = ns.L

-- Time played, a snapshot of the character at each level (gear, stats, talents, skills), and the
-- account-wide roster of your characters (CaptainsLogAccount).

local Num, Str, Call = ns.PlainNumber, ns.PlainText, ns.Call

------------------------------------------------------------------------------
-- Roster
------------------------------------------------------------------------------

local function UpdateRoster()
    CaptainsLogAccount = CaptainsLogAccount or {}
    ns.account = CaptainsLogAccount
    local roster = ns.Sub(CaptainsLogAccount, "roster")
    local name, realm = Str(Call(UnitName, "player")), Str(Call(GetRealmName))
    if not name or not realm then return end
    local key = realm .. "-" .. name
    local character = roster[key] or {}
    roster[key] = character
    local _, class = Call(UnitClass, "player")
    local _, race = Call(UnitRace, "player")
    character.name = ns.FullName("player") or character.name -- with the surname, on Forever
    character.class = Str(class) or character.class
    character.race = Str(race) or character.race
    character.level = Num(Call(UnitLevel, "player")) or character.level
    character.played = ns.db.played and ns.db.played.total or character.played
    character.money = Num(Call(GetMoney)) or character.money
    character.zone = ns.Zone() or character.zone
    character.last = time()
end
ns.UpdateRoster = UpdateRoster

------------------------------------------------------------------------------
-- Time played
------------------------------------------------------------------------------

-- Requests the addon makes itself don't print "Total time played" to chat: the chat frames stop
-- listening for the one reply. The player's own /played prints as usual.
local muted = {}
local function Unmute()
    for chatFrame in pairs(muted) do pcall(chatFrame.RegisterEvent, chatFrame, "TIME_PLAYED_MSG") end
    wipe(muted)
end

local lastAsk = 0
local function RequestPlayed()
    if not RequestTimePlayed or GetTime() - lastAsk < 10 then return end
    lastAsk = GetTime()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame.IsEventRegistered and chatFrame:IsEventRegistered("TIME_PLAYED_MSG") then
            chatFrame:UnregisterEvent("TIME_PLAYED_MSG")
            muted[chatFrame] = true
        end
    end
    if not pcall(RequestTimePlayed) then Unmute() return end
    C_Timer.After(10, Unmute) -- if no reply comes
end
ns.RequestPlayed = RequestPlayed

local dingLevel -- the level just reached, until its played time arrives

ns.On("TIME_PLAYED_MSG", function(total, thisLevel)
    C_Timer.After(0, Unmute) -- after this reply has gone past the chat frames
    total, thisLevel = Num(total), Num(thisLevel)
    if not total then return end
    ns.db.played = { total = total, level = thisLevel, at = time() }
    local level = Num(UnitLevel("player"))
    if dingLevel and (not level or dingLevel > level) then level = dingLevel end
    dingLevel = nil
    if level and thisLevel then
        local record = ns.Sub(ns.db.levels, level)
        -- The total when this level was reached; kept from the first reading.
        record.played = record.played or (total - thisLevel)
        local previous = ns.db.levels[level - 1]
        if previous and previous.played and not previous.spent and record.played >= previous.played then
            previous.spent = record.played - previous.played
        end
    end
    UpdateRoster()
    ns.Refresh()
end)

------------------------------------------------------------------------------
-- Snapshots
------------------------------------------------------------------------------

local function Gear()
    local gear, enchants = {}, {}
    for slot = 1, 19 do
        local link = Str(Call(GetInventoryItemLink, "player", slot))
        local id, enchant = link and link:match("item:(%d+):(%d*)")
        if id then
            gear[slot] = tonumber(id)
            enchant = tonumber(enchant)
            if enchant and enchant > 0 then enchants[slot] = enchant end
        end
    end
    return gear, enchants
end

-- Talent tabs: { {name, points}, ... } and per-tab rank strings joined by "-" ("0532-00-1").
-- Nil while the talents haven't loaded.
local function Talents()
    local tabCount = Num(Call(GetNumTalentTabs))
    if not tabCount or tabCount == 0 or not GetTalentTabInfo then return end
    local tabs, ranks = {}, {}
    for tab = 1, tabCount do
        local returned = { pcall(GetTalentTabInfo, tab) }
        if not returned[1] then return end
        local name, points
        if type(returned[2]) == "number" then -- id, name, description, icon, pointsSpent, ...
            name, points = Str(returned[3]), Num(returned[6])
        else                                  -- name, icon, pointsSpent, ...
            name, points = Str(returned[2]), Num(returned[4])
        end
        tabs[tab] = { name = name, points = points or 0 }
        local talentCount = Num(Call(GetNumTalents, tab)) or 0
        if talentCount == 0 then return end
        local digits = {}
        for i = 1, talentCount do
            local _, _, _, _, rank = Call(GetTalentInfo, tab, i)
            rank = Num(rank) or 0
            digits[i] = rank < 10 and tostring(rank) or "9"
        end
        ranks[tab] = table.concat(digits)
    end
    return tabs, table.concat(ranks, "-")
end

local function Skills()
    if not (GetNumSkillLines and GetSkillLineInfo) then return end
    local skills = {}
    for i = 1, Num(Call(GetNumSkillLines)) or 0 do
        local name, header, _, rank, _, _, maxRank = Call(GetSkillLineInfo, i)
        name, rank = Str(name), Num(rank)
        if name and not header and rank then
            skills[name] = { rank, Num(maxRank) or 0 }
        end
    end
    return skills
end

local function Snapshot(level)
    local snap = { t = time(), level = level }
    snap.gear, snap.ench = Gear()
    snap.stats = {}
    for i = 1, 5 do
        local _, effective = Call(UnitStat, "player", i)
        snap.stats[i] = Num(effective)
    end
    snap.hp = Num(Call(UnitHealthMax, "player"))
    snap.power = Num(Call(UnitPowerMax, "player"))
    snap.powerType = Num(Call(UnitPowerType, "player"))
    local _, armor = Call(UnitArmor, "player")
    snap.armor = Num(armor)
    snap.talents, snap.ranks = Talents()
    snap.skills = Skills()
    snap.money = Num(Call(GetMoney))
    local guild, rank = Call(GetGuildInfo, "player")
    snap.guild, snap.guildRank = Str(guild), Str(rank)
    snap.rested = Num(Call(GetXPExhaustion))
    snap.zone = ns.Zone()
    return snap
end

-- Talents load late after logging in: fill them in when they arrive (every 5 s, up to a minute).
local function FillTalents(snap, tries)
    if snap.talents or tries <= 0 then return end
    C_Timer.After(5, function()
        local tabs, ranks = Talents()
        if tabs then
            snap.talents, snap.ranks = tabs, ranks
        else
            FillTalents(snap, tries - 1)
        end
    end)
end

local function TakeSnapshot(level)
    level = level or Num(UnitLevel("player"))
    if not level then return end
    local ok, snap = pcall(Snapshot, level)
    if not ok then
        ns.Debug("Snapshot: " .. tostring(snap))
        return
    end
    ns.Sub(ns.db.levels, level).snap = snap
    FillTalents(snap, 12)
    return snap
end
ns.TakeSnapshot = TakeSnapshot

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

ns.On("PLAYER_LOGIN", function()
    UpdateRoster()
    RequestPlayed()
    C_Timer.After(8, function()
        for _, record in pairs(ns.db.levels) do
            if type(record) == "table" and record.snap then return end
        end
        TakeSnapshot()
    end)
end)

local entered = false
ns.On("PLAYER_ENTERING_WORLD", function()
    if entered then return end
    entered = true
    C_Timer.After(4, function()
        lastAsk = 0
        RequestPlayed()
    end)
end)

ns.On("PLAYER_LEVEL_UP", function(level)
    level = Num(level)
    dingLevel = level
    lastAsk = 0
    RequestPlayed()
    -- A moment later, once the new level's stats are in.
    C_Timer.After(2, function()
        TakeSnapshot(level)
        UpdateRoster()
        local previous = level and ns.db.levels[level - 1]
        if previous and previous.spent then
            ns.Print(L["Level %d took %s of play."]:format(level - 1, ns.Duration(previous.spent)))
        end
    end)
end)

ns.On("PLAYER_LOGOUT", function() pcall(UpdateRoster) end)
