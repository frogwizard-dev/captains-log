local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- Time played, a snapshot of the character at each level (gear, stats, talents, skills), and the
-- account-wide roster of your characters (CaptainsLogAccount).

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
    local r = roster[key] or {}
    roster[key] = r
    local _, class = Call(UnitClass, "player")
    local _, race = Call(UnitRace, "player")
    r.class = Str(class) or r.class
    r.race = Str(race) or r.race
    r.level = Num(Call(UnitLevel, "player")) or r.level
    r.played = ns.db.played and ns.db.played.total or r.played
    r.money = Num(Call(GetMoney)) or r.money
    r.zone = ns.Zone() or r.zone
    r.last = time()
end
ns.UpdateRoster = UpdateRoster

------------------------------------------------------------------------------
-- Time played
------------------------------------------------------------------------------

-- Requests the addon makes itself don't print "Total time played" to chat: the chat frames stop
-- listening for the one reply. The player's own /played prints as usual.
local muted = {}
local function Unmute()
    for cf in pairs(muted) do pcall(cf.RegisterEvent, cf, "TIME_PLAYED_MSG") end
    wipe(muted)
end

local lastAsk = 0
local function RequestPlayed()
    if not RequestTimePlayed or GetTime() - lastAsk < 10 then return end
    lastAsk = GetTime()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf and cf.IsEventRegistered and cf:IsEventRegistered("TIME_PLAYED_MSG") then
            cf:UnregisterEvent("TIME_PLAYED_MSG")
            muted[cf] = true
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
    local lvl = Num(UnitLevel("player"))
    if dingLevel and (not lvl or dingLevel > lvl) then lvl = dingLevel end
    dingLevel = nil
    if lvl and thisLevel then
        local rec = ns.Sub(ns.db.levels, lvl)
        -- The total when this level was reached; kept from the first reading.
        rec.played = rec.played or (total - thisLevel)
        local prev = ns.db.levels[lvl - 1]
        if prev and prev.played and not prev.spent and rec.played >= prev.played then
            prev.spent = rec.played - prev.played
        end
    end
    UpdateRoster()
    ns.Refresh()
end)

------------------------------------------------------------------------------
-- Snapshots
------------------------------------------------------------------------------

local function Gear()
    local gear, ench = {}, {}
    for slot = 1, 19 do
        local link = Str(Call(GetInventoryItemLink, "player", slot))
        local id, e = link and link:match("item:(%d+):(%d*)")
        if id then
            gear[slot] = tonumber(id)
            e = tonumber(e)
            if e and e > 0 then ench[slot] = e end
        end
    end
    return gear, ench
end

-- Talent tabs: { {name, points}, ... } and per-tab rank strings joined by "-" ("0532-00-1").
-- Nil while the talents haven't loaded.
local function Talents()
    local tabs = Num(Call(GetNumTalentTabs))
    if not tabs or tabs == 0 or not GetTalentTabInfo then return end
    local out, ranks = {}, {}
    for tab = 1, tabs do
        local r = { pcall(GetTalentTabInfo, tab) }
        if not r[1] then return end
        local name, points
        if type(r[2]) == "number" then -- id, name, description, icon, pointsSpent, ...
            name, points = Str(r[3]), Num(r[6])
        else                           -- name, icon, pointsSpent, ...
            name, points = Str(r[2]), Num(r[4])
        end
        out[tab] = { name = name, points = points or 0 }
        local n = Num(Call(GetNumTalents, tab)) or 0
        if n == 0 then return end
        local s = {}
        for i = 1, n do
            local _, _, _, _, rank = Call(GetTalentInfo, tab, i)
            rank = Num(rank) or 0
            s[i] = rank < 10 and tostring(rank) or "9"
        end
        ranks[tab] = table.concat(s)
    end
    return out, table.concat(ranks, "-")
end

local function Skills()
    if not (GetNumSkillLines and GetSkillLineInfo) then return end
    local n = Num(Call(GetNumSkillLines)) or 0
    local out = {}
    for i = 1, n do
        local name, header, _, rank, _, _, maxRank = Call(GetSkillLineInfo, i)
        name, rank = Str(name), Num(rank)
        if name and not header and rank then
            out[name] = { rank, Num(maxRank) or 0 }
        end
    end
    return out
end

local function Snapshot(lvl)
    local snap = { t = time(), level = lvl }
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
        local t, r = Talents()
        if t then
            snap.talents, snap.ranks = t, r
        else
            FillTalents(snap, tries - 1)
        end
    end)
end

local function TakeSnapshot(lvl)
    lvl = lvl or Num(UnitLevel("player"))
    if not lvl then return end
    local ok, snap = pcall(Snapshot, lvl)
    if not ok then
        ns.Debug("Snapshot: " .. tostring(snap))
        return
    end
    ns.Sub(ns.db.levels, lvl).snap = snap
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
        for _, rec in pairs(ns.db.levels) do
            if type(rec) == "table" and rec.snap then return end
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
        local prev = level and ns.db.levels[level - 1]
        if prev and prev.spent then
            ns.Print(L["Level %d took %s of play."]:format(level - 1, ns.Duration(prev.spent)))
        end
    end)
end)

ns.On("PLAYER_LOGOUT", function() pcall(UpdateRoster) end)
