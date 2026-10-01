local _, ns = ...
local UI = ns.UI

local Page = { label = "Quests", color = { 0.16, 0.26, 0.48 }, order = 3 }
ns.Pages.quests = Page

local FILTERS = {
    { "all", "All quests" },
    { "open", "In progress" },
    { "done", "Completed" },
    { "abandoned", "Abandoned" },
}
local KIND = { world = "World quest", bonus = "Bonus objective" }

local function Status(q)
    if q.completed then return "done" end
    if q.abandoned then return "abandoned" end
    return "open"
end

local function Title(id, q)
    return q.title or ("Quest #" .. id)
end

local function NpcName(npcID)
    local n = npcID and ns.db.npcs[npcID]
    return n and n.name
end

-- Title, zone, giver, or anything in the quest's own text.
local function Matches(id, q, query)
    if query == "" then return true end
    for _, s in ipairs({ Title(id, q), q.acceptZone, q.zone, NpcName(q.giver), NpcName(q.turnInNpc), q.text, q.objective }) do
        if s and s:lower():find(query, 1, true) then return true end
    end
    return false
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.filter, self.query = "all", ""
    self.sub = ns.Book:Header(left, "Quest Journal")

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    local filter = UI.Dropdown(left, 170, FILTERS, function() return self.filter end, function(v)
        self.filter = v
        self:Render()
    end)
    filter:SetPoint("TOPRIGHT", 0, -60)
    self.search, self.filterDropdown = search, filter

    self.list = UI.List(left, W, H - 94)
    self.list.sf:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
end

function Page:Render()
    local quests = ns.db.quests
    local groups = { open = {}, done = {}, abandoned = {} }
    local xp, money = 0, 0
    for id, q in pairs(quests) do
        local status = Status(q)
        if status == "done" then
            xp, money = xp + (q.xp or 0), money + (q.money or 0)
        end
        if (self.filter == "all" or self.filter == status) and Matches(id, q, self.query) then
            table.insert(groups[status], id)
        end
    end
    -- In progress first, then completed, then abandoned; newest first in each.
    table.sort(groups.open, function(a, b) return (quests[a].accepted or 0) > (quests[b].accepted or 0) end)
    table.sort(groups.done, function(a, b) return quests[a].completed > quests[b].completed end)
    table.sort(groups.abandoned, function(a, b) return quests[a].abandoned > quests[b].abandoned end)

    local done, open = 0, 0
    for _, q in pairs(quests) do
        if q.completed then done = done + 1 elseif not q.abandoned then open = open + 1 end
    end
    self.sub:SetText(string.format("%d completed  ·  %d in progress  ·  %s xp earned", done, open, ns.Number(xp)))

    local items, first = {}, nil
    for _, id in ipairs(groups.open) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = "in progress", color = UI.ACCENT }
    end
    for _, id in ipairs(groups.done) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = ns.Date(quests[id].completed) }
    end
    for _, id in ipairs(groups.abandoned) do
        items[#items + 1] = { key = id, left = Title(id, quests[id]), right = "abandoned", color = UI.FADED }
    end
    first = items[1] and items[1].key
    if not self.selected or not quests[self.selected] then self.selected = first end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)
    self:RenderQuest(self.selected)
end

-- Experience and coin on one line, then the items as an icon grid like a merchant's wares.
-- Once handed in, the choice you took is marked and the ones you passed over fade.
function Page:RenderRewards(q)
    local doc = self.doc
    local xp, money = q.xp or q.offerXP, q.money or q.offerMoney
    local any = (xp and xp > 0) or (money and money > 0) or q.items or q.choices
    if not any then return end
    doc:Heading(q.completed and "Rewards" or "Rewards on offer")
    local parts = {}
    if xp and xp > 0 then parts[#parts + 1] = ns.Number(xp) .. " experience" end
    if money and money > 0 then parts[#parts + 1] = ns.Money(money) end
    if #parts > 0 then doc:Line(table.concat(parts, "     ")) end

    local function Cell(item, note, dim)
        if item.qty > 1 then note = "x" .. item.qty .. (note and ("  ·  " .. note) or "") end
        return { link = item.link, note = note, dim = dim }
    end
    if q.items then
        local cells = {}
        for _, item in ipairs(q.items) do cells[#cells + 1] = Cell(item, q.completed and "received" or nil) end
        doc:Gap(2)
        doc:Grid(cells, 2)
    end
    if q.choices then
        local chosen = q.completed and q.chose
        doc:Faded(chosen and "You chose:" or "Choose one:")
        local cells = {}
        for i, item in ipairs(q.choices) do
            local mine = chosen == i
            cells[#cells + 1] = Cell(item, mine and "your choice" or nil, chosen and not mine)
        end
        doc:Grid(cells, 2)
    end
end

------------------------------------------------------------------------------
-- The quest on the game's world map (MapPins.lua), from its Map buttons
------------------------------------------------------------------------------

-- The map where you've slain most of this quest's creatures.
local function FoeMap(q)
    local counts, best, most = {}, nil, 0
    local seen = {}
    for i in ipairs(q.objectives or {}) do
        for _, f in ipairs(ns.ObjectiveFoes(q, i)) do
            if not seen[f.id] then
                seen[f.id] = true
                for mapID, spots in pairs(f.mob.spots or {}) do
                    counts[mapID] = (counts[mapID] or 0) + #spots
                    if counts[mapID] > most then best, most = mapID, counts[mapID] end
                end
            end
        end
    end
    return best
end

local function ShowQuestMap(id, which)
    local q = ns.db.quests[tonumber(id)]
    if not q then return end
    local mapID
    if which == "start" then
        mapID = ns.QuestStart(q)
    elseif which == "finish" then
        mapID = ns.QuestFinish(q)
    else
        mapID = FoeMap(q)
    end
    -- Each button pins only what it sits beside: the people, or the creatures.
    ns.MapPins.Show(which == "foes" and "questfoes" or "questgiver", tonumber(id), mapID)
end

local MAP_TIP = {
    start = "Pins the quest giver (and, once it's done, where you handed it in) to the game's map.",
    finish = "Pins where you handed it in (and the quest giver) to the game's map.",
    foes = "Pins every spot you've slain this quest's creatures to the game's map.",
}
local function MapTip(which)
    return MAP_TIP[which] or "Pins the quest to the game's map."
end

UI.RegisterLink("qmap", ShowQuestMap, function(_, which) return "Show on map", MapTip(which) end)

------------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------------

-- One stop on the quest, on two lines with its buttons at the right:
--   Quest giver: Novice Elreth                    [Map] [Waypoint]
--   Tirisfal Glades
function Page:PlaceRow(id, label, npcID, zone, which, mapID, x, y)
    local n = npcID and ns.db.npcs[npcID]
    local who = (n and n.name) and UI.NpcLink(npcID) or "|cff6b5d4fnot recorded|r"
    zone = (n and n.zone) or zone
    local text = "|cff6b5d4f" .. label .. ":|r  " .. who
    if zone then text = text .. "\n|cff6b5d4fin|r " .. UI.ZoneLink(zone) end
    local actions = UI.MapActions(mapID and function() ShowQuestMap(id, which) end, mapID, x, y, MapTip(which))
    self.doc:Row(text, actions)
    self.doc:Gap(2)
end

-- Under each objective, the creatures it's about, each opening its bestiary page.
function Page:ObjectiveFoes(q, index)
    local foes = ns.ObjectiveFoes(q, index)
    if #foes == 0 then return false end
    local slay, drop = {}, {}
    for _, f in ipairs(foes) do
        local link = UI.MobLink(f.id, f.mob.name)
        if f.how == "drops" then
            if #drop < 4 then drop[#drop + 1] = link .. string.format(" (%d%%)", math.floor(f.rate * 100 + 0.5)) end
        elseif #slay < 4 then
            slay[#slay + 1] = link
        end
    end
    if #slay > 0 then self.doc:Text("Creatures: " .. table.concat(slay, ",  "), 11, UI.FADED, nil, 30) end
    if #drop > 0 then self.doc:Text("Dropped by: " .. table.concat(drop, ",  "), 11, UI.FADED, nil, 30) end
    return true
end

function Page:RenderQuest(id)
    local doc = self.doc
    doc:Clear("quest:" .. tostring(id))
    ns.Book:BackLink(doc)
    local q = id and ns.db.quests[id]
    if not q then
        self.title = nil
        doc:Title(next(ns.db.quests) and "Nothing matches" or "No quests yet")
        doc:Faded("Quests appear here as you accept and complete them.")
        doc:Finish()
        return
    end
    self.title = Title(id, q)
    doc:Title(self.title)

    local meta = {}
    if q.questLevel then meta[#meta + 1] = "Level " .. q.questLevel end
    if q.tag then meta[#meta + 1] = q.tag end
    if KIND[q.kind] and q.tag ~= KIND[q.kind] then meta[#meta + 1] = KIND[q.kind] end
    if #meta > 0 then doc:Faded(table.concat(meta, "  ·  ")) end
    doc:Gap(4)

    -- Where it stands: the state in its colour, then when and at what level.
    if q.completed then
        doc:Line(string.format("|cff2f6b1fCompleted|r  %s, at level %d%s", ns.Date(q.completed), q.level or 0,
            q.accepted and string.format("  |cff6b5d4f(took %s)|r", ns.Duration(q.completed - q.accepted)) or ""))
    elseif q.abandoned then
        doc:Line(string.format("|cff7a1f0dAbandoned|r  %s", ns.Date(q.abandoned)))
    elseif q.accepted then
        doc:Line(string.format("|cff1d4f8cIn progress|r  accepted %s, at level %d", ns.Ago(q.accepted), q.acceptLevel or 0))
    end
    if (q.timesDone or 0) > 1 then doc:Faded(string.format("Completed %d times in all.", q.timesDone)) end

    -- Who to see and where, each with the book's map and the game's waypoint as buttons.
    local sm, sx, sy = ns.QuestStart(q)
    local fm, fx, fy = ns.QuestFinish(q)
    local hasStart = q.giver or q.acceptZone or sm
    local hasFinish = q.completed and (q.turnInNpc or q.zone or fm)
    if hasStart or hasFinish then
        doc:Heading("Where")
        doc:Gap(2)
        if hasStart then
            self:PlaceRow(id, "Quest giver", q.giver, q.acceptZone, "start", sm, sx, sy)
        end
        if hasFinish then
            self:PlaceRow(id, "Handed in to", q.turnInNpc, q.zone, "finish", fm, fx, fy)
        end
    end

    if q.objective or q.objectives then
        -- The map of this quest's creatures sits on the heading, beside what it's about.
        local foeMap = FoeMap(q)
        doc:Heading("Objectives", foeMap and UI.MapActions(function() ShowQuestMap(id, "foes") end,
            nil, nil, nil, MapTip("foes")) or nil)
        if q.objective then doc:Line(q.objective) end
        if q.objectives then
            doc:Gap(2)
            for i, o in ipairs(q.objectives) do
                -- Ticked when done; still to do shows the waiting mark, abandoned a cross.
                local mark = o.done or nil
                if not o.done and q.abandoned then mark = false end
                doc:Check(o.text, mark)
                self:ObjectiveFoes(q, i)
            end
        end
    end

    self:RenderRewards(q)

    if q.text then
        doc:Heading("The tale")
        doc:Line(q.text)
    end

    if q.finishText then
        doc:Heading("On handing in")
        doc:Line(q.finishText)
    end

    if not q.text and not q.objective then
        doc:Gap(6)
        doc:Faded("The quest's own words weren't written down; quests taken up from now on keep them.")
    end
    doc:Finish()
end

