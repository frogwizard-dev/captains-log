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
    local ok, tooltip = pcall(C_TooltipInfo.GetUnit, unit)
    local line = ok and tooltip and tooltip.lines and tooltip.lines[2]
    local text = line and line.leftText
    if not issecret(text) and text and text ~= "" and not text:find("%d") then return text end
end

function ns.NPC(id, name)
    local npc = ns.db.npcs[id]
    if not npc then
        npc = { name = name, firstSeen = time(), zone = ns.Zone(), quests = {}, turnIns = {}, sells = {}, roles = {} }
        ns.db.npcs[id] = npc
        ns.Refresh()
    end
    if name then npc.name = name end
    return npc
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
    local npc = ns.NPC(id, name)
    npc.title = Title(unit) or npc.title
    if talked or not npc.mapID then
        local mapID, x, y = ns.Position(true)
        if mapID then
            npc.mapID, npc.x, npc.y = mapID, x, y
            npc.zone = ns.Zone() or npc.zone
        end
    end
    if talked then
        npc.visits = (npc.visits or 0) + 1
        npc.lastVisit = time()
        if npc.visits == 1 and npc.name then
            ns.Log("npc", { name = npc.name, title = npc.title })
        end
    end
    return id, npc
end

-- Clears out other players' totems, pets and companions recorded before they were skipped:
-- their title says whose they are ("Smokehorn Blackhoof's Totem").
local OWNED = { "'s Totem$", "'s Pet$", "'s Guardian$", "'s Minion$", "'s Companion$" }
ns.On("PLAYER_LOGIN", function()
    for id, npc in pairs(ns.db.npcs) do
        for _, pattern in ipairs(OWNED) do
            if npc.title and npc.title:find(pattern) and not next(npc.roles) then
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
    local npcID = ns.NpcID(UnitGUID("npc"))
    local sameVisit = talking and talking.id == npcID and GetTime() - talking.time < 60
    local id, npc = Meet("npc", not sameVisit, true)
    if not id then return end
    talking = { id = id, time = GetTime() }
    if role then npc.roles[role] = true end
    ns.Refresh()
    return id, npc
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
ns.On("QUEST_ACCEPTED", function(first, second)
    local questID = second or first -- older clients pass (logIndex, questID)
    local id = Recent()
    if type(questID) ~= "number" or not id then return end
    local npc = ns.db.npcs[id]
    if not npc then return end
    npc.quests[questID] = time()
    ns.db.quests[questID] = ns.db.quests[questID] or {}
    ns.db.quests[questID].giver = id
    ns.Refresh()
end)

ns.On("QUEST_TURNED_IN", function(questID)
    local id = Recent()
    if not id then return end
    local npc = ns.db.npcs[id]
    if not npc then return end
    npc.turnIns[questID] = time()
    ns.db.quests[questID] = ns.db.quests[questID] or {}
    ns.db.quests[questID].turnInNpc = id
    ns.Refresh()
end)

------------------------------------------------------------------------------
-- Merchants
------------------------------------------------------------------------------

local function ItemPrice(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local item = C_MerchantFrame.GetItemInfo(index)
        if item then return item.price, item.stackCount, item.numAvailable end
    elseif GetMerchantItemInfo then
        local _, _, price, stack, available = GetMerchantItemInfo(index)
        return price, stack, available
    end
end

local function ScanMerchant()
    local id = Recent()
    local npc = id and ns.db.npcs[id]
    if not npc then return end
    for i = 1, GetMerchantNumItems() do
        local itemID = GetMerchantItemID(i)
        if itemID then
            local price, stack, available = ItemPrice(i)
            local entry = npc.sells[itemID] or {}
            entry.link = GetMerchantItemLink(i) or entry.link -- links can arrive a moment later
            entry.price, entry.stack = price, stack
            entry.limited = available and available > 0 or nil
            npc.sells[itemID] = entry
        end
    end
    npc.scanned = time()
    ns.Refresh()
end

ns.On("MERCHANT_SHOW", function()
    local _, npc = Talk("vendor")
    if npc and CanMerchantRepair and CanMerchantRepair() then npc.roles.repair = true end
    pcall(ScanMerchant)
end)
ns.On("MERCHANT_UPDATE", function() pcall(ScanMerchant) end)

------------------------------------------------------------------------------
-- Trainers
------------------------------------------------------------------------------

-- The trainer window lists only what its filters allow, so the scan turns them all on and puts
-- yours back; the TRAINER_UPDATE those changes fire straight after is ignored.
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
                local skillName, skillRank = GetTrainerServiceSkillReq(i)
                if skillName and skillName ~= "" then skill, rank = skillName, skillRank end
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
    for line, lessons in pairs(skills) do
        if lessons > most then best, most = line, lessons end
    end
    return list, best
end

local function ScanTrainer()
    local id = Recent()
    local npc = id and ns.db.npcs[id]
    if not npc or not GetNumTrainerServices then return end
    scannedAt = GetTime()
    local saved = {}
    if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
        for _, filter in ipairs(FILTERS) do
            saved[filter] = GetTrainerServiceTypeFilter(filter) and true or false
            if not saved[filter] then SetTrainerServiceTypeFilter(filter, 1) end
        end
    end
    local ok, list, trade = pcall(ReadServices)
    for filter, on in pairs(saved) do
        if not on then SetTrainerServiceTypeFilter(filter, 0) end
    end
    if not ok or #list == 0 then return end
    npc.teaches = list
    npc.trade = trade or npc.trade
    npc.trainScanned = time()
    ns.Refresh()
end

ns.On("TRAINER_SHOW", function()
    Talk("trainer")
    pcall(ScanTrainer)
end)
ns.On("TRAINER_UPDATE", function()
    if GetTime() - scannedAt > 1 then pcall(ScanTrainer) end
end)
