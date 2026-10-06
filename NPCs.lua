local _, ns = ...
local issecret = ns.issecret

-- The People directory: friendly NPCs you've met. Mousing over or targeting one records its
-- name, title and rough location; talking to it adds its roles, the quests it gave you or took
-- back, and (at a merchant) everything it sells.

local RECENT = 120 -- seconds a conversation counts as "who you were talking to"

-- The subtitle under an NPC's name ("Innkeeper", "Weapon Merchant") is the tooltip's second
-- line; a level line ("Level 30") is skipped.
local function Title(unit)
    if not C_TooltipInfo then return nil end
    local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
    local line = ok and data and data.lines and data.lines[2]
    local text = line and line.leftText
    if not issecret(text) and text and text ~= "" and not text:find("%d") then return text end
end

local function Position()
    return ns.Position(true)
end

function ns.NPC(id, name)
    local n = ns.db.npcs[id]
    if not n then
        n = { name = name, firstSeen = time(), zone = ns.Zone(), quests = {}, turnIns = {}, sells = {}, roles = {} }
        ns.db.npcs[id] = n
        ns.Refresh()
    end
    if name then n.name = name end
    return n
end

-- Records a friendly NPC, or any you talk to. `talking` = you're interacting with it now (gossip,
-- quests, a shop...); `talked` = and it's a new visit (a precise location, a visit counted).
local function Meet(unit, talked, talking)
    if not UnitExists(unit) then return end
    local player = UnitIsPlayer(unit) -- hidden in some content: then left alone
    if issecret(player) or player or ns.IsControlled(unit) then return end
    local id = ns.NpcID(UnitGUID(unit))
    if not id then return end
    -- Enemies belong to the bestiary. But anyone you talk to (gossip, quests, a shop, a flight
    -- master...) is a person, even one you could attack: neutral goblins in Ratchet and Booty Bay.
    if not talking then
        local attackable = UnitCanAttack("player", unit)
        if issecret(attackable) or attackable then return end
    end

    local name = UnitName(unit)
    if issecret(name) then name = nil end
    local n = ns.NPC(id, name)
    n.title = Title(unit) or n.title
    if talked or not n.mapID then
        local mapID, x, y = Position()
        if mapID then
            n.mapID, n.x, n.y = mapID, x, y
            n.zone = ns.Zone() or n.zone
        end
    end
    if talked then
        n.visits = (n.visits or 0) + 1
        n.lastVisit = time()
        if n.visits == 1 and n.name then
            ns.Log("npc", { name = n.name, title = n.title })
        end
    end
    return id, n
end

-- Clears out other players' totems, pets and companions recorded before they were skipped:
-- their title says whose they are ("Smokehorn Blackhoof's Totem").
local OWNED = { "'s Totem$", "'s Pet$", "'s Guardian$", "'s Minion$", "'s Companion$" }
ns.On("PLAYER_LOGIN", function()
    for id, n in pairs(ns.db.npcs) do
        for _, pattern in ipairs(OWNED) do
            if n.title and n.title:find(pattern) and not next(n.roles) then
                ns.db.npcs[id] = nil
                break
            end
        end
    end
end)

ns.On("UPDATE_MOUSEOVER_UNIT", function() Meet("mouseover") end)
ns.On("PLAYER_TARGET_CHANGED", function() Meet("target") end)

------------------------------------------------------------------------------
-- Conversations and roles
------------------------------------------------------------------------------

local talking -- { id, time } of the NPC whose window is open

local function Talk(role)
    -- One conversation fires several of these events (a greeting, then the quest text...);
    -- only the first one within a minute counts as a visit.
    local current = ns.NpcID(UnitGUID("npc"))
    local sameVisit = talking and talking.id == current and GetTime() - talking.time < 60
    local id, n = Meet("npc", not sameVisit, true)
    if not id then return end
    talking = { id = id, time = GetTime() }
    if role then n.roles[role] = true end
    ns.Refresh()
    return id, n
end

local function Recent()
    if talking and GetTime() - talking.time < RECENT then return talking.id end
end

ns.On("GOSSIP_SHOW", function() Talk() end)
ns.On("QUEST_GREETING", function() Talk("quest") end)
ns.On("QUEST_DETAIL", function() Talk("quest") end)
ns.On("QUEST_PROGRESS", function() Talk("quest") end)
ns.On("QUEST_COMPLETE", function() Talk("quest") end)
ns.On("TAXIMAP_OPENED", function() Talk("flight") end)
ns.On("BANKFRAME_OPENED", function() Talk("banker") end)

-- Quest givers and takers: whoever you were talking to when you accepted or handed it in.
ns.On("QUEST_ACCEPTED", function(a, b)
    local questID = b or a
    local id = Recent()
    if type(questID) ~= "number" or not id then return end
    local n = ns.db.npcs[id]
    if not n then return end
    n.quests[questID] = time()
    ns.db.quests[questID] = ns.db.quests[questID] or {}
    ns.db.quests[questID].giver = id
    ns.Refresh()
end)

ns.On("QUEST_TURNED_IN", function(questID)
    local id = Recent()
    if not id then return end
    local n = ns.db.npcs[id]
    if not n then return end
    n.turnIns[questID] = time()
    ns.db.quests[questID] = ns.db.quests[questID] or {}
    ns.db.quests[questID].turnInNpc = id
    ns.Refresh()
end)

------------------------------------------------------------------------------
-- Merchants
------------------------------------------------------------------------------

local function ItemPrice(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if info then return info.price, info.stackCount, info.numAvailable end
    elseif GetMerchantItemInfo then
        local _, _, price, stack, available = GetMerchantItemInfo(i)
        return price, stack, available
    end
end

local function ScanMerchant()
    local id = Recent()
    local n = id and ns.db.npcs[id]
    if not n then return end
    for i = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(i)
        if itemID then
            local price, stack, available = ItemPrice(i)
            local entry = n.sells[itemID] or {}
            entry.link = GetMerchantItemLink(i) or entry.link -- links can arrive a moment later
            entry.price, entry.stack = price, stack
            entry.limited = available and available > 0 or nil
            n.sells[itemID] = entry
        end
    end
    n.scanned = time()
    ns.Refresh()
end

ns.On("MERCHANT_SHOW", function()
    local _, n = Talk("vendor")
    if n and CanMerchantRepair and CanMerchantRepair() then n.roles.repair = true end
    pcall(ScanMerchant)
end)
ns.On("MERCHANT_UPDATE", function() pcall(ScanMerchant) end)

------------------------------------------------------------------------------
-- Trainers
------------------------------------------------------------------------------

-- The trainer window only lists what its filters allow (known skills are often hidden), so the
-- scan turns every filter on, reads the list, then puts your filters back. Changing a filter
-- fires TRAINER_UPDATE, so updates straight after our own scan are ignored.
local FILTERS = { "available", "unavailable", "used" }
local scannedAt = 0

local function ReadServices()
    local list, group = {}, nil
    local skills = {}
    for i = 1, GetNumTrainerServices() do
        local name, kind, icon, reqLevel = GetTrainerServiceInfo(i)
        if kind == "header" then
            group = name
        elseif not issecret(name) and name then
            local cost = GetTrainerServiceCost and GetTrainerServiceCost(i)
            local skill, rank = nil, nil
            if GetTrainerServiceSkillReq then
                local s, r = GetTrainerServiceSkillReq(i)
                if s and s ~= "" then skill, rank = s, r end
            end
            if GetTrainerServiceLevelReq then reqLevel = GetTrainerServiceLevelReq(i) or reqLevel end
            local line = GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)
            if line and line ~= "" then skills[line] = (skills[line] or 0) + 1 end
            list[#list + 1] = {
                name = name, kind = kind, icon = icon, group = group,
                cost = cost, level = (reqLevel and reqLevel > 1) and reqLevel or nil,
                skill = skill, rank = rank,
                link = GetTrainerServiceItemLink and GetTrainerServiceItemLink(i) or nil,
                desc = GetTrainerServiceDescription and GetTrainerServiceDescription(i) or nil,
            }
        end
    end
    -- The trade they teach: the skill line most of their lessons belong to.
    local best, most = nil, 0
    for line, n in pairs(skills) do
        if n > most then best, most = line, n end
    end
    return list, best
end

local function ScanTrainer()
    local id = Recent()
    local n = id and ns.db.npcs[id]
    if not n or not GetNumTrainerServices then return end
    scannedAt = GetTime()
    local saved = {}
    if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
        for _, f in ipairs(FILTERS) do
            saved[f] = GetTrainerServiceTypeFilter(f) and true or false
            if not saved[f] then SetTrainerServiceTypeFilter(f, 1) end
        end
    end
    local ok, list, trade = pcall(ReadServices)
    for f, on in pairs(saved) do
        if not on then SetTrainerServiceTypeFilter(f, 0) end
    end
    if not ok or #list == 0 then return end
    n.teaches = list
    n.trade = trade or n.trade
    n.trainScanned = time()
    ns.Refresh()
end

ns.On("TRAINER_SHOW", function()
    Talk("trainer")
    pcall(ScanTrainer)
end)
ns.On("TRAINER_UPDATE", function()
    if GetTime() - scannedAt > 1 then pcall(ScanTrainer) end
end)
