local _, ns = ...
local issecret = ns.issecret

-- The quest journal. Each quest keeps its story: the text the giver told you, the objective,
-- the objectives' progress, the rewards on offer (and which one you took), the words said at
-- hand-in, and where you stood when you took it up and handed it in.

local function Clean(text)
    if type(text) ~= "string" or issecret(text) or text == "" then return nil end
    return text
end

local offered = {} -- questID -> { text, objective } from the quest window, until accepted
local completing   -- the reward window's contents, until the quest is handed in

------------------------------------------------------------------------------
-- Reading a quest
------------------------------------------------------------------------------

-- The log's own copy of the text, for quests accepted without a quest window (auto-accepted,
-- shared, picked up from an item). Selecting a quest is how the log API reads it; the
-- previous selection is put back.
local function LogText(questID)
    local index = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
    if not index or not GetQuestLogQuestText or not C_QuestLog.SetSelectedQuest then return end
    local prev = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    C_QuestLog.SetSelectedQuest(questID)
    local text, objective = GetQuestLogQuestText(index)
    if prev and prev ~= 0 and prev ~= questID then C_QuestLog.SetSelectedQuest(prev) end
    return Clean(text), Clean(objective)
end

local function Objectives(questID)
    if not C_QuestLog.GetQuestObjectives then return end
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
    if not ok or type(objs) ~= "table" then return end
    local function num(v)
        if type(v) == "number" and not issecret(v) then return v end
    end
    local list = {}
    for _, o in ipairs(objs) do
        local text = Clean(o.text)
        if text then
            local done = o.finished
            if issecret(done) then done = nil end
            list[#list + 1] = {
                text = text, done = done and true or false,
                type = Clean(o.type), -- "monster", "item", "object", "event", ...
                have = num(o.numFulfilled), need = num(o.numRequired),
            }
        end
    end
    return #list > 0 and list or nil
end

-- A kill objective that ticked up just as something died: that creature counts for it. This
-- catches objectives that don't name their creature ("Kobolds slain").
local function Credit(q, old, new, at)
    if not old then return end
    for i, o in ipairs(new) do
        local before = old[i]
        if o.type == "monster" and before and o.have and before.have and o.have > before.have then
            local id = ns.KillAround(at)
            if id then
                q.foes = q.foes or {}
                local f = q.foes[id] or { n = 0 }
                f.obj, f.n = i, f.n + (o.have - before.have)
                q.foes[id] = f
            end
        end
    end
end

-- Level, tag ("Elite", "Dungeon", "Group") and kind (world quest, bonus objective).
local function Describe(q, questID)
    local ok, level = pcall(C_QuestLog.GetQuestDifficultyLevel, questID)
    if ok and type(level) == "number" and not issecret(level) and level > 0 then q.questLevel = level end
    local ok2, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
    if ok2 and type(tag) == "table" and Clean(tag.tagName) then q.tag = tag.tagName end
    local ok3, world = pcall(C_QuestLog.IsWorldQuest, questID)
    local ok4, task = pcall(C_QuestLog.IsQuestTask, questID)
    if ok3 and world == true then
        q.kind = "world"
    elseif ok4 and task == true then
        q.kind = "bonus"
    end
end

------------------------------------------------------------------------------
-- Taking up a quest
------------------------------------------------------------------------------

local RewardList -- below

ns.On("QUEST_DETAIL", function()
    local id = GetQuestID and GetQuestID()
    if issecret(id) or not id or id == 0 then return end
    local o = {
        text = Clean(GetQuestText and GetQuestText()),
        objective = Clean(GetObjectiveText and GetObjectiveText()),
        money = GetRewardMoney and GetRewardMoney(),
        xp = GetRewardXP and GetRewardXP(),
    }
    -- What's on offer, so a quest in progress shows its rewards too.
    local ok, items = pcall(RewardList, "reward", GetNumQuestRewards and GetNumQuestRewards())
    o.items = ok and #items > 0 and items or nil
    local ok2, choices = pcall(RewardList, "choice", GetNumQuestChoices and GetNumQuestChoices())
    o.choices = ok2 and #choices > 0 and choices or nil
    offered[id] = o
end)

ns.On("QUEST_ACCEPTED", function(a, b)
    local questID = b or a -- older clients pass (logIndex, questID)
    if type(questID) ~= "number" then return end
    local q = ns.db.quests[questID] or {}
    ns.db.quests[questID] = q
    q.title = C_QuestLog.GetTitleForQuestID(questID) or q.title

    -- Taken up again after abandoning it, or a repeatable quest coming round once more.
    if q.abandoned or q.completed then
        q.abandoned, q.completed, q.accepted, q.acceptMap = nil, nil, nil, nil
        q.acceptZone, q.acceptLevel = nil, nil
        q.retries = (q.retries or 0) + 1
    end
    q.accepted = q.accepted or time()
    q.acceptZone = q.acceptZone or ns.Zone()
    q.acceptLevel = q.acceptLevel or UnitLevel("player")
    if not q.acceptMap then q.acceptMap, q.acceptX, q.acceptY = ns.Position() end

    local o = offered[questID]
    offered[questID] = nil
    if o then
        q.text = o.text or q.text
        q.objective = o.objective or q.objective
        q.items, q.choices, q.chose = o.items, o.choices, nil
        q.offerMoney = (not issecret(o.money) and o.money and o.money > 0) and o.money or nil
        q.offerXP = (not issecret(o.xp) and o.xp and o.xp > 0) and o.xp or nil
    end
    Describe(q, questID)
    q.objectives = Objectives(questID) or q.objectives
    ns.Log("accept", { questID = questID, title = q.title })

    -- The log fills in a moment after accepting.
    C_Timer.After(1, function()
        if not q.text or not q.objective then
            local ok, text, objective = pcall(LogText, questID)
            if ok then
                q.text = q.text or text
                q.objective = q.objective or objective
            end
        end
        q.title = q.title or C_QuestLog.GetTitleForQuestID(questID)
        q.objectives = Objectives(questID) or q.objectives
        ns.Refresh()
    end)
end)

-- Objective progress, re-read at most every two seconds while the log is changing.
local function ObjectiveKey(list)
    if not list then return "" end
    local parts = {}
    for _, o in ipairs(list) do parts[#parts + 1] = o.text .. (o.done and "+" or "-") end
    return table.concat(parts, "|")
end

-- Re-read shortly after the first update of a burst; kills are matched against the time of
-- that first update, which is when the objective actually ticked.
local queued, updateAt = false, 0
ns.On("QUEST_LOG_UPDATE", function()
    if queued then return end
    queued, updateAt = true, GetTime()
    C_Timer.After(1.5, function()
        queued = false
        local changed = false
        for id, q in pairs(ns.db.quests) do
            if q.accepted and not q.completed and not q.abandoned then
                local list = Objectives(id)
                if list and ObjectiveKey(list) ~= ObjectiveKey(q.objectives) then
                    Credit(q, q.objectives, list, updateAt)
                    q.objectives = list
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

function RewardList(kind, count)
    local list = {}
    for i = 1, count or 0 do
        local link = GetQuestItemLink(kind, i)
        local _, _, qty = GetQuestItemInfo(kind, i)
        if link then list[#list + 1] = { link = link, qty = qty or 1 } end
    end
    return list
end

ns.On("QUEST_COMPLETE", function()
    local id = GetQuestID and GetQuestID()
    if issecret(id) then id = nil end
    completing = {
        id = id,
        title = Clean(GetTitleText and GetTitleText()),
        text = Clean(GetRewardText and GetRewardText()),
    }
    local ok, items = pcall(RewardList, "reward", GetNumQuestRewards and GetNumQuestRewards())
    completing.items = ok and items or {}
    local ok2, choices = pcall(RewardList, "choice", GetNumQuestChoices and GetNumQuestChoices())
    completing.choices = ok2 and choices or {}
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
    local q = ns.db.quests[questID] or {}
    ns.db.quests[questID] = q
    local c = completing
    if c and not (c.id == questID or (c.title and c.title == q.title)) then c = nil end
    completing = nil

    q.title = q.title or C_QuestLog.GetTitleForQuestID(questID) or (c and c.title) or ("Quest #" .. questID)
    q.completed = time()
    q.zone = ns.Zone()
    q.level = UnitLevel("player")
    q.xp, q.money = xp, money
    q.timesDone = (q.timesDone or 0) + 1
    q.doneMap, q.doneX, q.doneY = ns.Position()
    if c then
        q.finishText = c.text or q.finishText
        if #c.items > 0 then q.items = c.items end
        if #c.choices > 0 then q.choices = c.choices end
        q.chose = c.chosen
    end
    if q.objectives then
        for _, o in ipairs(q.objectives) do o.done = true end
    end

    table.insert(ns.Day().quests, questID)
    if q.zone then
        local z = ns.ZoneRecord(q.zone)
        z.quests = z.quests + 1
    end
    ns.Log("quest", { questID = questID, title = q.title, xp = xp, money = money })
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

local function DropName(d, itemID)
    local name = d.link and d.link:match("%[(.-)%]")
    return name or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID))
end

-- The creatures behind one objective, best first: { id, mob, how, item, rate }.
--   how = "seen": it ticked the objective up as it died (recorded, so certain)
--   how = "named": the objective names it
--   how = "drops": it drops the item the objective asks for (rate = share of its corpses)
function ns.ObjectiveFoes(q, index)
    local o = q.objectives and q.objectives[index]
    if not o then return {} end
    local subject = Subject(o.text)
    local found, list = {}, {}
    local function add(id, m, how, item, rate)
        if found[id] then return end
        found[id] = { id = id, mob = m, how = how, item = item, rate = rate }
        list[#list + 1] = found[id]
    end
    for id, f in pairs(q.foes or {}) do
        if f.obj == index and ns.db.mobs[id] then add(id, ns.db.mobs[id], "seen") end
    end
    -- Objectives recorded before types were kept could be either kind; try both.
    local wantsMob, wantsItem = o.type ~= "item", o.type == "item" or o.type == nil
    for id, m in pairs(ns.db.mobs) do
        if wantsMob and m.name and #m.name >= 3 and subject:find(m.name:lower(), 1, true) then
            add(id, m, "named")
        elseif wantsItem and m.looted > 0 then
            for itemID, d in pairs(m.drops) do
                local item = DropName(d, itemID)
                if item and #item >= 3 and subject:find(item:lower(), 1, true) then
                    add(id, m, "drops", item, d.times / m.looted)
                    break
                end
            end
        end
    end

    -- "Wolf" also matches "Timber Wolf slain"; keep only the longest name that matched, and
    -- likewise for items ("Linen Cloth" inside "Bolt of Linen Cloth").
    local function key(e) return (e.how == "drops" and e.item or e.mob.name or ""):lower() end
    local keep = {}
    for _, e in ipairs(list) do
        local shadowed = false
        if e.how ~= "seen" then
            for _, other in ipairs(list) do
                if other ~= e and other.how == e.how and #key(other) > #key(e) and key(other):find(key(e), 1, true) then
                    shadowed = true
                    break
                end
            end
        end
        if not shadowed then keep[#keep + 1] = e end
    end
    table.sort(keep, function(a, b)
        if (a.rate or 0) ~= (b.rate or 0) then return (a.rate or 0) > (b.rate or 0) end
        return a.mob.kills > b.mob.kills
    end)
    return keep
end

-- The quests a creature is wanted for: { questID, q, item } (item when it's wanted for a drop).
-- In progress first, then the most recently completed.
function ns.MobQuests(id)
    local m = ns.db.mobs[id]
    if not m then return {} end
    local name = m.name and #m.name >= 3 and m.name:lower()
    local items = {}
    for itemID, d in pairs(m.drops) do
        local item = DropName(d, itemID)
        if item and #item >= 3 then items[#items + 1] = item:lower() end
    end

    local out = {}
    for questID, q in pairs(ns.db.quests) do
        for i, o in ipairs(q.objectives or {}) do
            -- A cheap look first; the full match (with its longest-name rule) only on a hit.
            local subject = Subject(o.text)
            local hit = (q.foes and q.foes[id] and q.foes[id].obj == i) or (name and subject:find(name, 1, true))
            if not hit then
                for _, item in ipairs(items) do
                    if subject:find(item, 1, true) then hit = true break end
                end
            end
            local match
            if hit then
                for _, f in ipairs(ns.ObjectiveFoes(q, i)) do
                    if f.id == id then match = f break end
                end
            end
            if match then
                out[#out + 1] = { questID = questID, q = q, item = match.item }
                break
            end
        end
    end
    table.sort(out, function(a, b)
        local oa, ob = not a.q.completed, not b.q.completed
        if oa ~= ob then return oa end
        return (a.q.completed or a.q.accepted or 0) > (b.q.completed or b.q.accepted or 0)
    end)
    return out
end

-- Where a quest begins and ends: the giver's or taker's own spot when known (most precise),
-- otherwise where you stood. mapID, x, y.
function ns.QuestStart(q)
    local n = q.giver and ns.db.npcs[q.giver]
    if n and n.mapID and n.x then return n.mapID, n.x, n.y end
    if q.acceptMap and q.acceptX then return q.acceptMap, q.acceptX, q.acceptY end
end

function ns.QuestFinish(q)
    local n = q.turnInNpc and ns.db.npcs[q.turnInNpc]
    if n and n.mapID and n.x then return n.mapID, n.x, n.y end
    if q.doneMap and q.doneX then return q.doneMap, q.doneX, q.doneY end
end

------------------------------------------------------------------------------
-- Abandoning
------------------------------------------------------------------------------

-- World quests and bonus objectives drop out of the log when you leave their area; one that
-- leaves without being handed in counts as abandoned (quietly, as you never chose to).
ns.On("QUEST_REMOVED", function(questID)
    local q = type(questID) == "number" and ns.db.quests[questID]
    if not q or not q.kind then return end
    C_Timer.After(2, function()
        if not q.completed and not q.abandoned and q.accepted then
            q.abandoned = time()
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
        local q = id and ns.db.quests[id]
        if not q or q.completed then return end
        q.abandoned = time()
        ns.Log("abandon", { questID = id, title = q.title })
    end)
end
