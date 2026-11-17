local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Quests"], color = { 0.16, 0.26, 0.48 }, order = 3 }
ns.Pages.quests = Page

local FILTERS = {
    { "all", L["All quests"] },
    { "open", L["In progress"] },
    { "done", L["Completed"] },
    { "abandoned", L["Abandoned"] },
}
local KIND = { world = L["World quest"], bonus = L["Bonus objective"] }

local function Status(quest)
    if quest.completed then return "done" end
    if quest.abandoned then return "abandoned" end
    return "open"
end

local function Title(id, quest)
    return quest.title or L["Quest #%s"]:format(id)
end

local function NpcName(npcID)
    local npc = npcID and ns.db.npcs[npcID]
    return npc and npc.name
end

-- Title, zone, giver, or anything in the quest's own text.
local function Matches(id, quest, query)
    if query == "" then return true end
    for _, text in ipairs({ Title(id, quest), quest.acceptZone, quest.zone, NpcName(quest.giver),
        NpcName(quest.turnInNpc), quest.text, quest.objective }) do
        if text and text:lower():find(query, 1, true) then return true end
    end
    return false
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.filter, self.query = "all", ""
    self.subtitle = ns.Book:Header(left, L["Quest Journal"])

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    local filter = UI.Dropdown(left, 170, FILTERS, function() return self.filter end, function(status)
        self.filter = status
        self:Render()
    end)
    filter:SetPoint("TOPRIGHT", 0, -60)
    self.search, self.filterDropdown = search, filter

    self.list = UI.List(left, width, height - 94)
    self.list.scroll:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
end

function Page:Render()
    local quests = ns.db.quests
    local groups = { open = {}, done = {}, abandoned = {} }
    local xp, done, open = 0, 0, 0
    for id, quest in pairs(quests) do
        local status = Status(quest)
        if status == "done" then
            xp, done = xp + (quest.xp or 0), done + 1
        elseif status == "open" then
            open = open + 1
        end
        if (self.filter == "all" or self.filter == status) and Matches(id, quest, self.query) then
            table.insert(groups[status], id)
        end
    end
    -- In progress first, then completed, then abandoned; newest first in each.
    table.sort(groups.open, function(first, second) return (quests[first].accepted or 0) > (quests[second].accepted or 0) end)
    table.sort(groups.done, function(first, second) return quests[first].completed > quests[second].completed end)
    table.sort(groups.abandoned, function(first, second) return quests[first].abandoned > quests[second].abandoned end)
    self.subtitle:SetText(string.format(L["%d completed  ·  %d in progress  ·  %s xp earned"], done, open, ns.Number(xp)))

    local items = {}
    for _, id in ipairs(groups.open) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = L["in progress"], color = UI.ACCENT }
    end
    for _, id in ipairs(groups.done) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = ns.Date(quests[id].completed) }
    end
    for _, id in ipairs(groups.abandoned) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = L["abandoned"], color = UI.FADED }
    end
    if not self.selected or not quests[self.selected] then self.selected = items[1] and items[1].key end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)
    self:RenderQuest(self.selected)
end

-- Experience and coin on one line, then the items as an icon grid like a merchant's wares.
-- Once handed in, the choice you took is marked and the ones you passed over fade.
function Page:RenderRewards(quest)
    local doc = self.doc
    local xp, money = quest.xp or quest.offerXP, quest.money or quest.offerMoney
    local any = (xp and xp > 0) or (money and money > 0) or quest.items or quest.choices
    if not any then return end
    doc:Heading(quest.completed and L["Rewards"] or L["Rewards on offer"])
    local parts = {}
    if xp and xp > 0 then parts[#parts + 1] = L["%s experience"]:format(ns.Number(xp)) end
    if money and money > 0 then parts[#parts + 1] = ns.Money(money) end
    if #parts > 0 then doc:Line(table.concat(parts, "     ")) end

    local function Cell(item, note, dim)
        if item.qty > 1 then note = "x" .. item.qty .. (note and ("  ·  " .. note) or "") end
        return { link = item.link, note = note, dim = dim }
    end
    if quest.items then
        local cells = {}
        for _, item in ipairs(quest.items) do cells[#cells + 1] = Cell(item, quest.completed and L["received"] or nil) end
        doc:Gap(2)
        doc:Grid(cells, 2)
    end
    if quest.choices then
        local chosen = quest.completed and quest.chose
        doc:Faded(chosen and L["You chose:"] or L["Choose one:"])
        local cells = {}
        for i, item in ipairs(quest.choices) do
            local mine = chosen == i
            cells[#cells + 1] = Cell(item, mine and L["your choice"] or nil, chosen and not mine)
        end
        doc:Grid(cells, 2)
    end
end

------------------------------------------------------------------------------
-- The quest on the game's world map (MapPins.lua), from its Map buttons
------------------------------------------------------------------------------

-- The map where you've slain most of this quest's creatures.
local function FoeMap(quest)
    local counts, best, most = {}, nil, 0
    local seen = {}
    for i in ipairs(quest.objectives or {}) do
        for _, foe in ipairs(ns.ObjectiveFoes(quest, i)) do
            if not seen[foe.id] then
                seen[foe.id] = true
                for mapID, spots in pairs(foe.mob.spots or {}) do
                    counts[mapID] = (counts[mapID] or 0) + #spots
                    if counts[mapID] > most then best, most = mapID, counts[mapID] end
                end
            end
        end
    end
    return best
end

local function ShowQuestMap(id, which)
    local quest = ns.db.quests[tonumber(id)]
    if not quest then return end
    local mapID
    if which == "start" then
        mapID = ns.QuestStart(quest)
    elseif which == "finish" then
        mapID = ns.QuestFinish(quest)
    else
        mapID = FoeMap(quest)
    end
    -- Each button pins only what it sits beside: the people, or the creatures.
    ns.MapPins.Show(which == "foes" and "questfoes" or "questgiver", tonumber(id), mapID)
end

local MAP_TIP = {
    start = L["Pins the quest giver (and, once it's done, where you handed it in) to the game's map."],
    finish = L["Pins where you handed it in (and the quest giver) to the game's map."],
    foes = L["Pins every spot you've slain this quest's creatures to the game's map."],
}
local function MapTip(which)
    return MAP_TIP[which] or L["Pins the quest to the game's map."]
end

UI.RegisterLink("qmap", ShowQuestMap, function(_, which) return L["Show on map"], MapTip(which) end)

------------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------------

-- One stop on the quest, on two lines with its buttons at the right:
--   Quest giver: Novice Elreth                    [Map] [Waypoint]
--   Tirisfal Glades
function Page:PlaceRow(id, label, npcID, zone, which, mapID, x, y)
    local npc = npcID and ns.db.npcs[npcID]
    local who = (npc and npc.name) and UI.NpcLink(npcID) or "|cff6b5d4f" .. L["not recorded"] .. "|r"
    zone = (npc and npc.zone) or zone
    local text = L["|cff6b5d4f%s:|r  %s"]:format(label, who)
    if zone then text = text .. "\n|cff6b5d4fin|r " .. UI.ZoneLink(zone) end
    local actions = UI.MapActions(mapID and function() ShowQuestMap(id, which) end, mapID, x, y, MapTip(which))
    self.doc:Row(text, actions)
    self.doc:Gap(2)
end

-- Under each objective, the creatures it's about, each opening its bestiary page.
function Page:ObjectiveFoes(quest, index)
    local foes = ns.ObjectiveFoes(quest, index)
    if #foes == 0 then return false end
    local slay, drop = {}, {}
    for _, foe in ipairs(foes) do
        local link = UI.MobLink(foe.id, foe.mob.name)
        if foe.how == "drops" then
            if #drop < 4 then drop[#drop + 1] = link .. string.format(" (%d%%)", math.floor(foe.rate * 100 + 0.5)) end
        elseif #slay < 4 then
            slay[#slay + 1] = link
        end
    end
    if #slay > 0 then self.doc:Text(L["Creatures: %s"]:format(table.concat(slay, ",  ")), 11, UI.FADED, nil, 30) end
    if #drop > 0 then self.doc:Text(L["Dropped by: %s"]:format(table.concat(drop, ",  ")), 11, UI.FADED, nil, 30) end
    return true
end

function Page:RenderQuest(id)
    local doc = self.doc
    doc:Clear("quest:" .. tostring(id))
    ns.Book:BackLink(doc)
    local quest = id and ns.db.quests[id]
    if not quest then
        self.title = nil
        doc:Title(next(ns.db.quests) and L["Nothing matches"] or L["No quests yet"])
        doc:Faded(L["Quests appear here as you accept and complete them."])
        doc:Finish()
        return
    end
    self.title = Title(id, quest)
    doc:Title(self.title)

    local meta = {}
    if quest.questLevel then meta[#meta + 1] = L["Level %s"]:format(quest.questLevel) end
    if quest.tag then meta[#meta + 1] = quest.tag end
    if KIND[quest.kind] and quest.tag ~= KIND[quest.kind] then meta[#meta + 1] = KIND[quest.kind] end
    if #meta > 0 then doc:Faded(table.concat(meta, "  ·  ")) end
    doc:Gap(4)

    -- Where it stands: the state in its colour, then when and at what level.
    if quest.completed then
        doc:Line(string.format(L["|cff2f6b1fCompleted|r  %s, at level %d%s"], ns.Date(quest.completed), quest.level or 0,
            quest.accepted and string.format(L["  |cff6b5d4f(took %s)|r"], ns.Duration(quest.completed - quest.accepted)) or ""))
    elseif quest.abandoned then
        doc:Line(string.format(L["|cff7a1f0dAbandoned|r  %s"], ns.Date(quest.abandoned)))
    elseif quest.accepted then
        doc:Line(string.format(L["|cff1d4f8cIn progress|r  accepted %s, at level %d"], ns.Ago(quest.accepted), quest.acceptLevel or 0))
    end
    if (quest.timesDone or 0) > 1 then doc:Faded(string.format(L["Completed %d times in all."], quest.timesDone)) end

    -- Who to see and where, each with the book's map and the game's waypoint as buttons.
    local startMap, startX, startY = ns.QuestStart(quest)
    local finishMap, finishX, finishY = ns.QuestFinish(quest)
    local hasStart = quest.giver or quest.acceptZone or startMap
    local hasFinish = quest.completed and (quest.turnInNpc or quest.zone or finishMap)
    if hasStart or hasFinish then
        doc:Heading(L["Where"])
        doc:Gap(2)
        if hasStart then
            self:PlaceRow(id, L["Quest giver"], quest.giver, quest.acceptZone, "start", startMap, startX, startY)
        end
        if hasFinish then
            self:PlaceRow(id, L["Handed in to"], quest.turnInNpc, quest.zone, "finish", finishMap, finishX, finishY)
        end
    end

    if quest.objective or quest.objectives then
        -- The map of this quest's creatures sits on the heading, beside what it's about.
        local foeMap = FoeMap(quest)
        doc:Heading(L["Objectives"], foeMap and UI.MapActions(function() ShowQuestMap(id, "foes") end,
            nil, nil, nil, MapTip("foes")) or nil)
        if quest.objective then doc:Line(quest.objective) end
        if quest.objectives then
            doc:Gap(2)
            for i, objective in ipairs(quest.objectives) do
                -- Ticked when done; still to do shows the waiting mark, abandoned a cross.
                local mark = objective.done or nil
                if not objective.done and quest.abandoned then mark = false end
                doc:Check(objective.text, mark)
                self:ObjectiveFoes(quest, i)
            end
        end
    end

    self:RenderRewards(quest)

    if quest.text then
        doc:Heading(L["The tale"])
        doc:Line(quest.text)
    end

    if quest.finishText then
        doc:Heading(L["On handing in"])
        doc:Line(quest.finishText)
    end

    if not quest.text and not quest.objective then
        doc:Gap(6)
        doc:Faded(L["The quest's own words weren't written down; quests taken up from now on keep them."])
    end
    doc:Finish()
end
