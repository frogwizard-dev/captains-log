local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["People"], color = { 0.13, 0.40, 0.42 }, order = 2.5 }
ns.Pages.people = Page

local FILTERS = {
    { "all", L["Everyone"] },
    { "quest", L["Quest givers"] },
    { "vendor", L["Vendors"] },
    { "repair", L["Repairs"] },
    { "trainer", L["Trainers"] },
    { "flight", L["Flight masters"] },
    { "banker", L["Bankers"] },
}
local ROLE_NAMES = {
    quest = L["Quest giver"], vendor = L["Vendor"], repair = L["Repairs"], trainer = L["Trainer"],
    flight = L["Flight master"], banker = L["Banker"],
}
local ROLE_ORDER = { "quest", "vendor", "repair", "trainer", "flight", "banker" }

-- "Quest giver  ·  Vendor", also used by the Lands page.
function ns.RoleText(npc)
    local roles = {}
    for _, role in ipairs(ROLE_ORDER) do
        if npc.roles[role] then roles[#roles + 1] = ROLE_NAMES[role] end
    end
    return table.concat(roles, "  ·  ")
end

local function ItemName(ware)
    return ware.link and ware.link:match("%[(.-)%]")
end

-- Text without its colour codes, cut to `max` characters (and never mid-letter) for the list.
local function Short(text, max)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if #text <= max then return text end
    return (text:sub(1, max - 2):gsub("[\192-\255][\128-\191]*$", "")) .. ".."
end

-- The whole word (or words) around a match in someone's words, as they wrote it.
local function Quote(text, from, to)
    while from > 1 and text:sub(from - 1, from - 1):find("[%w']") do from = from - 1 end
    while to < #text and text:sub(to + 1, to + 1):find("[%w']") do to = to + 1 end
    return Short(text:sub(from, to), 22)
end

-- Where `query` is found in `text` (start, end), ignoring case; nothing when it isn't.
local function Has(text, query)
    if text then return text:lower():find(query, 1, true) end
end

-- Name, title, anything they sell, anything they teach, or anything said in their gossip window
-- (their words or a reply). The second return says which ware, lesson or words matched.
local function Matches(npc, query)
    if query == "" then return true end
    if Has(npc.name, query) or Has(npc.title, query) or Has(npc.trade, query) then return true end
    for _, ware in pairs(npc.sells) do
        local item = ItemName(ware)
        if Has(item, query) then return true, L["sells %s"]:format(item) end
    end
    for _, lesson in ipairs(npc.teaches or {}) do
        if Has(lesson.name, query) then return true, L["teaches %s"]:format(lesson.name) end
    end
    for _, page in ipairs(npc.gossip or {}) do
        for _, version in ipairs(page.says) do
            local from, to = Has(version[1], query)
            if from then return true, L["said \"%s\""]:format(Quote(version[1], from, to)) end
        end
        for _, reply in ipairs(page.opts) do
            local from, to = Has(reply.name, query)
            if from then
                local name = Short(reply.name, 99)
                return true, L["reply \"%s\""]:format(#name <= 22 and name or Quote(reply.name, from, to))
            end
        end
    end
    return false
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.filter, self.query = "all", ""
    self.subtitle = ns.Book:Header(left, L["People"])

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    local filter = UI.Dropdown(left, 170, FILTERS, function() return self.filter end, function(role)
        self.filter = role
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
    local entries, total = {}, 0
    for id, npc in pairs(ns.db.npcs) do
        total = total + 1
        local ok, match = Matches(npc, self.query)
        if ok and (self.filter == "all" or npc.roles[self.filter]) then
            entries[#entries + 1] = { id = id, npc = npc, match = match }
        end
    end
    table.sort(entries, function(first, second) return (first.npc.name or "") < (second.npc.name or "") end)
    self.subtitle:SetText((total == 1 and L["%s person met"] or L["%s people met"]):format(total)
        .. "  ·  " .. L["search names, wares, lessons or words"])

    if not self.selected or not ns.db.npcs[self.selected] then
        self.selected = entries[1] and entries[1].id
    end
    local items = {}
    for _, entry in ipairs(entries) do
        items[#items + 1] = {
            key = entry.id,
            left = entry.npc.name or L["Unknown #%s"]:format(entry.id),
            -- When the match was on something they sell or teach, say what.
            right = entry.match or (entry.npc.title or ""),
        }
    end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)
    self:RenderNPC(self.selected)
end

local function QuestTitle(questID)
    local quest = ns.db.quests[questID]
    return quest and quest.title or L["Quest #%s"]:format(questID)
end

function Page:RenderNPC(id)
    local doc = self.doc
    doc:Clear("npc:" .. tostring(id))
    ns.Book:BackLink(doc)
    local npc = id and ns.db.npcs[id]
    if not npc then
        self.title = nil
        doc:Title(L["Nobody yet"])
        doc:Faded(L["Friendly folk appear here once you mouse over, target or talk to them."])
        doc:Finish()
        return
    end

    self.title = npc.name or L["Unknown #%s"]:format(id)
    doc:Title(self.title)
    if npc.title then doc:Faded(npc.title) end
    doc:Gap(4)
    doc:Line(string.format(L["First met on %s%s."], ns.Date(npc.firstSeen), npc.zone and L[" in %s"]:format(UI.ZoneLink(npc.zone)) or ""))
    if npc.visits and npc.visits > 0 then
        doc:Line(string.format(L["Spoken with %d %s, last %s."], npc.visits, npc.visits == 1 and L["time"] or L["times"],
            ns.Ago(npc.lastVisit)))
    end
    local roles = ns.RoleText(npc)
    if roles ~= "" then doc:Line(roles) end
    if npc.trade then doc:Line(L["Teaches %s"]:format(npc.trade)) end

    if npc.mapID then
        local map = C_Map.GetMapInfo(npc.mapID)
        doc:Heading(map and map.name and L["Where to find them: %s"]:format(map.name) or L["Where to find them"],
            UI.MapActions(function() ns.MapPins.Show("npc", id, npc.mapID) end, npc.mapID, npc.x, npc.y,
                L["Pins them to the game's map."]))
        doc:Gap(2)
        doc:Map(npc.mapID, { { npc.x, npc.y, kind = "npc", label = npc.name } }, { "npc", id })
    end

    local given = {}
    for questID in pairs(npc.quests) do given[#given + 1] = questID end
    if #given > 0 then
        table.sort(given, function(first, second) return npc.quests[first] < npc.quests[second] end)
        doc:Heading(L["Quests they gave you (%d)"]:format(#given))
        for _, questID in ipairs(given) do
            local quest = ns.db.quests[questID]
            local status = quest and (quest.completed and L["done %s"]:format(ns.Date(quest.completed))
                or (quest.abandoned and L["abandoned"])) or L["in progress"]
            doc:Line(UI.QuestLink(questID, QuestTitle(questID)) .. "  |cff6b5d4f" .. status .. "|r")
        end
    end

    local handed = {}
    for questID in pairs(npc.turnIns) do handed[#handed + 1] = questID end
    if #handed > 0 then
        table.sort(handed, function(first, second) return npc.turnIns[first] < npc.turnIns[second] end)
        doc:Heading(L["Quests you handed in here (%d)"]:format(#handed))
        for _, questID in ipairs(handed) do doc:Line(UI.QuestLink(questID, QuestTitle(questID))) end
    end

    self:RenderTalk(id, npc)

    local wares = {}
    for itemID, ware in pairs(npc.sells) do wares[#wares + 1] = { itemID = itemID, ware = ware } end
    if #wares > 0 then
        table.sort(wares, function(first, second) return (ItemName(first.ware) or "") < (ItemName(second.ware) or "") end)
        doc:Heading(string.format(L["Wares (%d, as of %s)"], #wares, ns.Date(npc.scanned)))
        doc:Gap(2)
        local cells = {}
        for _, entry in ipairs(wares) do
            local ware = entry.ware
            local price = (ware.price and ware.price > 0) and ns.Money(ware.price) or L["special cost"]
            if ware.stack and ware.stack > 1 then price = L["%s for %s"]:format(price, ware.stack) end
            if ware.limited then price = L["%s, limited"]:format(price) end
            cells[#cells + 1] = {
                link = ware.link or select(2, C_Item.GetItemInfo(entry.itemID)),
                icon = C_Item.GetItemIconByID(entry.itemID),
                note = price,
            }
        end
        doc:Grid(cells, 2)
    elseif npc.roles.vendor then
        doc:Heading(L["Wares"])
        doc:Faded(L["Open their shop again to record what they sell."])
    end

    self:RenderLessons(npc)
    doc:Finish()
end

-- What a trainer teaches, grouped under the trainer's own headings ("Apprentice", "Journeyman").
-- Each lesson notes its cost and what it needs; ones you already knew are faded.
local STATUS = { used = L["known"], available = L["can learn"] }

local function LessonNote(lesson)
    local parts = {}
    if STATUS[lesson.kind] then
        parts[#parts + 1] = STATUS[lesson.kind]
    end
    if lesson.kind ~= "used" then
        if lesson.cost and lesson.cost > 0 then parts[#parts + 1] = ns.Money(lesson.cost) end
        if lesson.skill and lesson.rank and lesson.rank > 0 then
            parts[#parts + 1] = lesson.skill .. " " .. lesson.rank
        elseif lesson.level then
            parts[#parts + 1] = L["level %s"]:format(lesson.level)
        end
    end
    return table.concat(parts, ", ")
end

function Page:RenderLessons(npc)
    local doc = self.doc
    if not npc.teaches then
        if npc.roles.trainer then
            doc:Heading(L["Lessons"])
            doc:Faded(L["Open their training window again to record what they teach."])
        end
        return
    end
    local known = 0
    for _, lesson in ipairs(npc.teaches) do
        if lesson.kind == "used" then known = known + 1 end
    end
    doc:Heading(string.format(L["Lessons (%d, as of %s)"], #npc.teaches, ns.Date(npc.trainScanned)))
    doc:Faded(string.format(L["You knew %d of them then. Hover one for details."], known))

    local group, cells = false, {}
    local function Flush()
        if #cells == 0 then return end
        if group then doc:Faded(group) end
        doc:Gap(2)
        doc:Grid(cells, 2)
        cells = {}
    end
    for _, lesson in ipairs(npc.teaches) do
        if lesson.group ~= group then
            Flush()
            group = lesson.group
        end
        cells[#cells + 1] = {
            link = lesson.link, name = lesson.name, icon = lesson.icon,
            note = LessonNote(lesson), dim = lesson.kind == "used",
            tipTitle = lesson.name, tipText = lesson.desc,
        }
    end
    Flush()
end

------------------------------------------------------------------------------
-- What they say (Gossip.lua): the greeting, the replies it offers, and under each reply you've
-- chosen the page it led to, indented, as far as you've followed the conversation.
------------------------------------------------------------------------------

local INDENT = 16
local MAX_INDENT = 6 -- deeper pages line up with the sixth step instead of running off the page
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t"
local OPENS = { shop = L["opens their shop"], training = L["opens their training"], flight = L["opens the flight map"],
    bank = L["opens your bank"] }

-- Earlier versions of a page's words, shown on request: ["npcID:page"] = true.
Page.earlier = {}

UI.RegisterLink("talkold", function(id, index)
    local key = id .. ":" .. index
    Page.earlier[key] = not Page.earlier[key] or nil
    Page:Render()
end, function(id, index)
    if Page.earlier[id .. ":" .. index] then return L["Earlier words"], L["Click to hide them again."] end
    return L["Earlier words"], L["What they said here before, with when you heard it."]
end)

local function Plural(count, one, many)
    return count == 1 and one or many
end

-- A page's words, newest first: { { text, first, last } }.
local function Versions(page)
    local list = {}
    for _, version in ipairs(page.says) do list[#list + 1] = version end
    table.sort(list, function(first, second) return first[3] > second[3] end)
    return list
end

-- "Fear the Wailing Caverns...", short, for a reply that leads back to an earlier page.
local function Gist(page)
    local latest = Versions(page)[1]
    if not latest then return L["a page with no words"] end
    local text = latest[1]:gsub("%s+", " ")
    if #text > 48 then text = text:sub(1, 46):gsub("[\192-\255][\128-\191]*$", "") .. "..." end
    return "\"" .. text .. "\""
end

function Page:RenderTalkPage(id, pages, index, depth, done)
    local doc = self.doc
    local page = pages[index]
    done[index] = true
    local x = 8 + math.min(depth, MAX_INDENT) * INDENT

    local versions = Versions(page)
    if versions[1] then
        local since = #versions > 1 and "  |cff6b5d4f" .. L["(since %s)"]:format(ns.Date(versions[1][2])) .. "|r" or ""
        doc:Text("\"" .. versions[1][1] .. "\"" .. since, 12, UI.INK, nil, x)
    elseif depth == 0 then
        doc:Text(L["They said nothing, only offered a choice."], 11, UI.FADED, nil, x)
    end
    if #versions > 1 then
        local key = id .. ":" .. index
        local open = self.earlier[key]
        local label = open and L["Hide earlier words"] or string.format(L["Earlier words (%d)"], #versions - 1)
        doc:Text(UI.Link(label, "talkold", id, index), 11, nil, nil, x)
        if open then
            for i = 2, #versions do
                local version = versions[i]
                local when = ns.Date(version[2]) == ns.Date(version[3]) and ns.Date(version[2])
                    or L["%s to %s"]:format(ns.Date(version[2]), ns.Date(version[3]))
                doc:Text("\"" .. version[1] .. "\"  |cff6b5d4f(" .. when .. ")|r", 11, UI.FADED, nil, x + 10)
            end
        end
    end

    -- Quests listed on the page; ones in your quest journal open there.
    if page.quests and next(page.quests) then
        local list = {}
        for questID, title in pairs(page.quests) do
            local quest = ns.db.quests[questID]
            local name = (quest and quest.title) or (type(title) == "string" and title) or L["Quest #%s"]:format(questID)
            list[#list + 1] = { name = name, text = quest and UI.QuestLink(questID, name) or name }
        end
        table.sort(list, function(first, second) return first.name < second.name end)
        local texts = {}
        for _, entry in ipairs(list) do texts[#texts + 1] = entry.text end
        doc:Text(L["Quests: %s"]:format(table.concat(texts, ", ")), 11, UI.FADED, nil, x)
    end

    local replies = {}
    for _, reply in ipairs(page.opts) do replies[#replies + 1] = reply end
    table.sort(replies, function(first, second)
        if (first.order or 0) ~= (second.order or 0) then return (first.order or 0) < (second.order or 0) end
        return (first.first or 0) < (second.first or 0)
    end)
    for _, reply in ipairs(replies) do
        local notes = {}
        if (reply.picks or 0) > 0 then
            notes[#notes + 1] = TICK .. " " .. (reply.picks == 1 and L["chosen once"] or L["chosen %d times"]:format(reply.picks))
        end
        if reply.opens and OPENS[reply.opens] then notes[#notes + 1] = OPENS[reply.opens] end
        if (reply.n or 0) < (page.n or 0) then
            notes[#notes + 1] = string.format(L["offered %d of %d %s"], reply.n or 0, page.n, Plural(page.n, L["time"], L["times"]))
        end
        local icon = reply.icon and ("|T" .. reply.icon .. ":14:14:0:0|t ") or ""
        local note = #notes > 0 and ("  |cff6b5d4f" .. table.concat(notes, ", ") .. "|r") or ""
        doc:Text(icon .. reply.name .. note, 12, (reply.picks or 0) > 0 and UI.INK or UI.FADED, nil, x)

        local led = reply.to and pages[reply.to]
        if led then
            local inner = 8 + math.min(depth + 1, MAX_INDENT) * INDENT
            if done[reply.to] then
                local where = reply.to == 1 and L["the greeting"] or Gist(led)
                doc:Text(L["» back to %s"]:format(where), 11, UI.FADED, nil, inner)
            else
                self:RenderTalkPage(id, pages, reply.to, depth + 1, done)
            end
        end
    end
end

function Page:RenderTalk(id, npc)
    local pages = npc.gossip
    if not (pages and pages[1]) then return end
    local greeting = pages[1]
    local heard = (greeting.n or 0) > 0
        and string.format(L[" (heard %d %s)"], greeting.n, Plural(greeting.n, L["time"], L["times"])) or ""
    self.doc:Heading(L["What they say"] .. heard)
    self:RenderTalkPage(id, pages, 1, 0, {})
end
