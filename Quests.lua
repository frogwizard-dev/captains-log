local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- The quest journal. Each quest keeps its story: the text the giver told you, the objective,
-- the objectives' progress, the rewards on offer (and which one you took), the words said at
-- hand-in, and where you stood when you took it up and handed it in.

local Clean, PlainNumber = ns.PlainText, ns.PlainNumber

local offered = {} -- questID -> { text, objective } from the quest window, until accepted
local completing   -- the reward window's contents, until the quest is handed in

------------------------------------------------------------------------------
-- Reading a quest
------------------------------------------------------------------------------

-- The log's text, for quests taken without a quest window (auto-accepted, shared, from an item).
-- The log API reads the selected quest, so it's selected and the previous one put back.
local function LogText(questID)
    local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if not index or not GetQuestLogQuestText or not C_QuestLog.SetSelectedQuest then return end
    local previous = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    C_QuestLog.SetSelectedQuest(questID)
    local text, objective = GetQuestLogQuestText(index)
    if previous and previous ~= 0 and previous ~= questID then C_QuestLog.SetSelectedQuest(previous) end
    return Clean(text), Clean(objective)
end

local function Objectives(questID)
    if not C_QuestLog.GetQuestObjectives then return end
    local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
    if not ok or type(objectives) ~= "table" then return end
    local list = {}
    for _, objective in ipairs(objectives) do
        local text = Clean(objective.text)
        if text then
            local done = objective.finished
            if issecret(done) then done = nil end
            list[#list + 1] = {
                text = text, done = done and true or false,
                type = Clean(objective.type), -- "monster", "item", "object", "event", ...
                have = PlainNumber(objective.numFulfilled), need = PlainNumber(objective.numRequired),
            }
        end
    end
    return #list > 0 and list or nil
end

-- A kill objective that ticked up as something died: that creature counts for it. This catches
-- objectives that don't name their creature ("Kobolds slain").
local function Credit(quest, oldList, newList, at)
    if not oldList then return end
    for i, objective in ipairs(newList) do
        local was = oldList[i]
        if objective.type == "monster" and was and objective.have and was.have and objective.have > was.have then
            local id = ns.KillAround(at)
            if id then
                quest.foes = quest.foes or {}
                local foe = quest.foes[id] or { n = 0 }
                foe.obj, foe.n = i, foe.n + (objective.have - was.have)
                quest.foes[id] = foe
            end
        end
    end
end

-- Level, tag ("Elite", "Dungeon", "Group") and kind (world quest, bonus objective).
local function Describe(quest, questID)
    local ok, level = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
    if ok and type(level) == "number" and not issecret(level) and level > 0 then quest.questLevel = level end
    local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
    if okTag and type(tag) == "table" and Clean(tag.tagName) then quest.tag = tag.tagName end
    local okWorld, world = pcall(C_QuestLog.IsWorldQuest, questID)
    local okTask, task = pcall(C_QuestLog.IsQuestTask, questID)
    if okWorld and world == true then
        quest.kind = "world"
    elseif okTask and task == true then
        quest.kind = "bonus"
    end
end

local function RewardList(kind, count)
    local list = {}
    for i = 1, count or 0 do
        local link = GetQuestItemLink(kind, i)
        local _, _, qty = GetQuestItemInfo(kind, i)
        if link then list[#list + 1] = { link = link, qty = qty or 1 } end
    end
    return list
end

-- The quest window's rewards: the items you get, and those you choose from ({} where hidden).
local function Rewards()
    local okItems, items = pcall(RewardList, "reward", GetNumQuestRewards and GetNumQuestRewards())
    local okChoices, choices = pcall(RewardList, "choice", GetNumQuestChoices and GetNumQuestChoices())
    return okItems and items or {}, okChoices and choices or {}
end

local function NilIfEmpty(list)
    return #list > 0 and list or nil
end

------------------------------------------------------------------------------
-- Taking up a quest
------------------------------------------------------------------------------

ns.On("QUEST_DETAIL", function()
    local id = GetQuestID and GetQuestID()
    if issecret(id) or not id or id == 0 then return end
    local items, choices = Rewards() -- so a quest in progress shows its rewards too
    offered[id] = {
        text = Clean(GetQuestText and GetQuestText()),
        objective = Clean(GetObjectiveText and GetObjectiveText()),
        money = GetRewardMoney and GetRewardMoney(),
        xp = GetRewardXP and GetRewardXP(),
        items = NilIfEmpty(items),
        choices = NilIfEmpty(choices),
    }
end)

ns.On("QUEST_ACCEPTED", function(first, second)
    local questID = second or first -- older clients pass (logIndex, questID)
    if type(questID) ~= "number" then return end
    local quest = ns.db.quests[questID] or {}
    ns.db.quests[questID] = quest
    quest.title = C_QuestLog.GetTitleForQuestID(questID) or quest.title

    -- Taken up again after abandoning it, or a repeatable quest coming round once more.
    if quest.abandoned or quest.completed then
        quest.abandoned, quest.completed, quest.accepted, quest.acceptMap = nil, nil, nil, nil
        quest.acceptZone, quest.acceptLevel = nil, nil
        quest.retries = (quest.retries or 0) + 1
    end
    quest.accepted = quest.accepted or time()
    quest.acceptZone = quest.acceptZone or ns.Zone()
    quest.acceptLevel = quest.acceptLevel or UnitLevel("player")
    if not quest.acceptMap then quest.acceptMap, quest.acceptX, quest.acceptY = ns.Position() end

    local offer = offered[questID]
    offered[questID] = nil
    if offer then
        quest.text = offer.text or quest.text
        quest.objective = offer.objective or quest.objective
        quest.items, quest.choices, quest.chose = offer.items, offer.choices, nil
        quest.offerMoney = (not issecret(offer.money) and offer.money and offer.money > 0) and offer.money or nil
        quest.offerXP = (not issecret(offer.xp) and offer.xp and offer.xp > 0) and offer.xp or nil
    end
    Describe(quest, questID)
    quest.objectives = Objectives(questID) or quest.objectives
    ns.Log("accept", { questID = questID, title = quest.title })

    -- The log fills in a moment after accepting.
    C_Timer.After(1, function()
        if not quest.text or not quest.objective then
            local ok, text, objective = pcall(LogText, questID)
            if ok then
                quest.text = quest.text or text
                quest.objective = quest.objective or objective
            end
        end
        quest.title = quest.title or C_QuestLog.GetTitleForQuestID(questID)
        quest.objectives = Objectives(questID) or quest.objectives
        ns.Refresh()
    end)
end)

-- Objective progress, re-read at most every two seconds while the log is changing.
local function ObjectiveKey(list)
    if not list then return "" end
    local parts = {}
    for _, objective in ipairs(list) do parts[#parts + 1] = objective.text .. (objective.done and "+" or "-") end
    return table.concat(parts, "|")
end

-- Re-read shortly after the first update of a burst; kills are matched against the time of
-- that first update, which is when the objective ticked.
local queued, updateAt = false, 0
ns.On("QUEST_LOG_UPDATE", function()
    if queued then return end
    queued, updateAt = true, GetTime()
    C_Timer.After(1.5, function()
        queued = false
        local changed = false
        for id, quest in pairs(ns.db.quests) do
            if quest.accepted and not quest.completed and not quest.abandoned then
                local list = Objectives(id)
                if list and ObjectiveKey(list) ~= ObjectiveKey(quest.objectives) then
                    Credit(quest, quest.objectives, list, updateAt)
                    quest.objectives = list
                    changed = true
                end
            end
        end
        if changed then ns.Refresh() end
    end)
end)

------------------------------------------------------------------------------
-- Handing it in
------------------------------------------------------------------------------

ns.On("QUEST_COMPLETE", function()
    local id = GetQuestID and GetQuestID()
    if issecret(id) then id = nil end
    local items, choices = Rewards()
    completing = {
        id = id,
        title = Clean(GetTitleText and GetTitleText()),
        text = Clean(GetRewardText and GetRewardText()),
        items = items,
        choices = choices,
    }
end)

-- Which reward you picked: the quest frame passes your choice to GetQuestReward.
if GetQuestReward then
    hooksecurefunc("GetQuestReward", function(choice)
        if completing and type(choice) == "number" and completing.choices[choice] then
            completing.chosen = choice
        end
    end)
end

ns.On("QUEST_TURNED_IN", function(questID, xp, money)
    local quest = ns.db.quests[questID] or {}
    ns.db.quests[questID] = quest
    local window = completing
    if window and not (window.id == questID or (window.title and window.title == quest.title)) then window = nil end
    completing = nil

    quest.title = quest.title or C_QuestLog.GetTitleForQuestID(questID) or (window and window.title)
        or L["Quest #%d"]:format(questID)
    quest.completed = time()
    quest.zone = ns.Zone()
    quest.level = UnitLevel("player")
    quest.xp, quest.money = xp, money
    quest.timesDone = (quest.timesDone or 0) + 1
    quest.doneMap, quest.doneX, quest.doneY = ns.Position()
    if window then
        quest.finishText = window.text or quest.finishText
        if #window.items > 0 then quest.items = window.items end
        if #window.choices > 0 then quest.choices = window.choices end
        quest.chose = window.chosen
    end
    for _, objective in ipairs(quest.objectives or {}) do objective.done = true end

    table.insert(ns.Day().quests, questID)
    if quest.zone then
        local record = ns.ZoneRecord(quest.zone)
        record.quests = record.quests + 1
    end
    ns.Log("quest", { questID = questID, title = quest.title, xp = xp, money = money })
end)

------------------------------------------------------------------------------
-- Quests and the bestiary
------------------------------------------------------------------------------

-- What an objective is about, without its count: "Kobold Vermin slain: 3/8" and
-- "3/8 Kobold Vermin slain" both give "kobold vermin slain".
local function Subject(text)
    text = text:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    return text:lower()
end

local function DropName(drop, itemID)
    local name = drop.link and drop.link:match("%[(.-)%]")
    return name or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID))
end

-- The creatures behind one objective, best first: { id, mob, how, item, rate }; how is "seen" (it
-- ticked the objective as it died), "named" (named by it) or "drops" (drops its item, at rate).
function ns.ObjectiveFoes(quest, index)
    local objective = quest.objectives and quest.objectives[index]
    if not objective then return {} end
    local subject = Subject(objective.text)
    local found, list = {}, {}
    local function Add(id, mob, how, item, rate)
        if found[id] then return end
        found[id] = { id = id, mob = mob, how = how, item = item, rate = rate }
        list[#list + 1] = found[id]
    end
    for id, foe in pairs(quest.foes or {}) do
        if foe.obj == index and ns.db.mobs[id] then Add(id, ns.db.mobs[id], "seen") end
    end
    -- Objectives recorded before types were kept could be either kind; try both.
    local wantsMob, wantsItem = objective.type ~= "item", objective.type == "item" or objective.type == nil
    for id, mob in pairs(ns.db.mobs) do
        if wantsMob and mob.name and #mob.name >= 3 and subject:find(mob.name:lower(), 1, true) then
            Add(id, mob, "named")
        elseif wantsItem and mob.looted > 0 then
            for itemID, drop in pairs(mob.drops) do
                local item = DropName(drop, itemID)
                if item and #item >= 3 and subject:find(item:lower(), 1, true) then
                    Add(id, mob, "drops", item, drop.times / mob.looted)
                    break
                end
            end
        end
    end

    -- "Wolf" also matches "Timber Wolf slain"; keep only the longest name that matched, and
    -- likewise for items ("Linen Cloth" inside "Bolt of Linen Cloth").
    local function MatchedName(foe) return (foe.how == "drops" and foe.item or foe.mob.name or ""):lower() end
    local keep = {}
    for _, foe in ipairs(list) do
        local shadowed = false
        if foe.how ~= "seen" then
            local name = MatchedName(foe)
            for _, other in ipairs(list) do
                local otherName = MatchedName(other)
                if other ~= foe and other.how == foe.how and #otherName > #name and otherName:find(name, 1, true) then
                    shadowed = true
                    break
                end
            end
        end
        if not shadowed then keep[#keep + 1] = foe end
    end
    table.sort(keep, function(first, second)
        if (first.rate or 0) ~= (second.rate or 0) then return (first.rate or 0) > (second.rate or 0) end
        return first.mob.kills > second.mob.kills
    end)
    return keep
end

-- The quests a creature is wanted for: { questID, q, item } (item when it's wanted for a drop).
-- In progress first, then the most recently completed.
function ns.MobQuests(id)
    local mob = ns.db.mobs[id]
    if not mob then return {} end
    local name = mob.name and #mob.name >= 3 and mob.name:lower()
    local items = {}
    for itemID, drop in pairs(mob.drops) do
        local item = DropName(drop, itemID)
        if item and #item >= 3 then items[#items + 1] = item:lower() end
    end

    local wanted = {}
    for questID, quest in pairs(ns.db.quests) do
        for i, objective in ipairs(quest.objectives or {}) do
            -- A cheap look first; the full match (with its longest-name rule) only on a hit.
            local subject = Subject(objective.text)
            local hit = (quest.foes and quest.foes[id] and quest.foes[id].obj == i)
                or (name and subject:find(name, 1, true))
            if not hit then
                for _, item in ipairs(items) do
                    if subject:find(item, 1, true) then hit = true break end
                end
            end
            local match
            if hit then
                for _, foe in ipairs(ns.ObjectiveFoes(quest, i)) do
                    if foe.id == id then match = foe break end
                end
            end
            if match then
                wanted[#wanted + 1] = { questID = questID, q = quest, item = match.item }
                break
            end
        end
    end
    table.sort(wanted, function(first, second)
        local firstOpen, secondOpen = not first.q.completed, not second.q.completed
        if firstOpen ~= secondOpen then return firstOpen end
        return (first.q.completed or first.q.accepted or 0) > (second.q.completed or second.q.accepted or 0)
    end)
    return wanted
end

-- Where a quest begins and ends: the giver's or taker's own spot when known (most precise),
-- otherwise where you stood. mapID, x, y.
local function NpcOrOwnSpot(npcID, mapID, x, y)
    local npc = npcID and ns.db.npcs[npcID]
    if npc and npc.mapID and npc.x then return npc.mapID, npc.x, npc.y end
    if mapID and x then return mapID, x, y end
end

function ns.QuestStart(quest)
    return NpcOrOwnSpot(quest.giver, quest.acceptMap, quest.acceptX, quest.acceptY)
end

function ns.QuestFinish(quest)
    return NpcOrOwnSpot(quest.turnInNpc, quest.doneMap, quest.doneX, quest.doneY)
end

------------------------------------------------------------------------------
-- Abandoning
------------------------------------------------------------------------------

-- World quests and bonus objectives drop out of the log when you leave their area; one that
-- leaves without being handed in counts as abandoned (quietly, as you never chose to).
ns.On("QUEST_REMOVED", function(questID)
    local quest = type(questID) == "number" and ns.db.quests[questID]
    if not quest or not quest.kind then return end
    C_Timer.After(2, function()
        if not quest.completed and not quest.abandoned and quest.accepted then
            quest.abandoned = time()
            ns.Refresh()
        end
    end)
end)

-- The abandon dialog names its quest with SetAbandonQuest; AbandonQuest then drops it.
local abandoning
if C_QuestLog.SetAbandonQuest then
    hooksecurefunc(C_QuestLog, "SetAbandonQuest", function()
        abandoning = C_QuestLog.GetAbandonQuest and C_QuestLog.GetAbandonQuest()
    end)
end
if C_QuestLog.AbandonQuest then
    hooksecurefunc(C_QuestLog, "AbandonQuest", function()
        local id = C_QuestLog.GetAbandonQuest and C_QuestLog.GetAbandonQuest()
        if not id or id == 0 then id = abandoning end
        abandoning = nil
        local quest = id and ns.db.quests[id]
        if not quest or quest.completed then return end
        quest.abandoned = time()
        ns.Log("abandon", { questID = id, title = quest.title })
    end)
end
