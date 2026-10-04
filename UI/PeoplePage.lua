local _, ns = ...
local UI = ns.UI

local Page = { label = "People", color = { 0.13, 0.40, 0.42 }, order = 2.5 }
ns.Pages.people = Page

local FILTERS = {
    { "all", "Everyone" },
    { "quest", "Quest givers" },
    { "vendor", "Vendors" },
    { "repair", "Repairs" },
    { "trainer", "Trainers" },
    { "flight", "Flight masters" },
    { "banker", "Bankers" },
}
local ROLE_NAMES = {
    quest = "Quest giver", vendor = "Vendor", repair = "Repairs", trainer = "Trainer",
    flight = "Flight master", banker = "Banker",
}
local ROLE_ORDER = { "quest", "vendor", "repair", "trainer", "flight", "banker" }

-- "Quest giver  ·  Vendor", also used by the Lands page.
function ns.RoleText(n)
    local roles = {}
    for _, r in ipairs(ROLE_ORDER) do
        if n.roles[r] then roles[#roles + 1] = ROLE_NAMES[r] end
    end
    return table.concat(roles, "  ·  ")
end

local function ItemName(entry)
    return entry.link and entry.link:match("%[(.-)%]")
end

-- Text without its colour codes, cut to `max` characters (and never mid-letter) for the list.
local function Short(text, max)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if #text <= max then return text end
    return (text:sub(1, max - 2):gsub("[\192-\255][\128-\191]*$", "")) .. ".."
end

-- The whole word (or words) around a match in someone's words, as they wrote it.
local function Quote(text, a, b)
    while a > 1 and text:sub(a - 1, a - 1):find("[%w']") do a = a - 1 end
    while b < #text and text:sub(b + 1, b + 1):find("[%w']") do b = b + 1 end
    return Short(text:sub(a, b), 22)
end

-- Name, title, anything they sell, anything they teach, or anything said in their gossip window
-- (their words or a reply). The second return says which ware, lesson or words matched.
local function Matches(n, query)
    if query == "" then return true end
    if n.name and n.name:lower():find(query, 1, true) then return true end
    if n.title and n.title:lower():find(query, 1, true) then return true end
    if n.trade and n.trade:lower():find(query, 1, true) then return true end
    for _, entry in pairs(n.sells) do
        local item = ItemName(entry)
        if item and item:lower():find(query, 1, true) then return true, "sells " .. item end
    end
    for _, s in ipairs(n.teaches or {}) do
        if s.name:lower():find(query, 1, true) then return true, "teaches " .. s.name end
    end
    for _, page in ipairs(n.gossip or {}) do
        for _, said in ipairs(page.says) do
            local a, b = said[1]:lower():find(query, 1, true)
            if a then return true, "said \"" .. Quote(said[1], a, b) .. "\"" end
        end
        for _, o in ipairs(page.opts) do
            local a, b = o.name:lower():find(query, 1, true)
            if a then
                local name = Short(o.name, 99)
                return true, "reply \"" .. (#name <= 22 and name or Quote(o.name, a, b)) .. "\""
            end
        end
    end
    return false
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.filter, self.query = "all", ""
    self.sub = ns.Book:Header(left, "People")

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
    local entries, total = {}, 0
    for id, n in pairs(ns.db.npcs) do
        total = total + 1
        local ok, match = Matches(n, self.query)
        if ok and (self.filter == "all" or n.roles[self.filter]) then
            entries[#entries + 1] = { id = id, n = n, match = match }
        end
    end
    table.sort(entries, function(a, b) return (a.n.name or "") < (b.n.name or "") end)
    self.sub:SetText(total .. (total == 1 and " person met" or " people met") .. "  ·  search names, wares, lessons or words")

    if not self.selected or not ns.db.npcs[self.selected] then
        self.selected = entries[1] and entries[1].id
    end
    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = {
            key = e.id,
            left = e.n.name or ("Unknown #" .. e.id),
            -- When the match was on something they sell or teach, say what.
            right = e.match or (e.n.title or ""),
        }
    end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)
    self:RenderNPC(self.selected)
end

local function QuestTitle(questID)
    local q = ns.db.quests[questID]
    return q and q.title or ("Quest #" .. questID)
end

function Page:RenderNPC(id)
    local doc = self.doc
    doc:Clear("npc:" .. tostring(id))
    ns.Book:BackLink(doc)
    local n = id and ns.db.npcs[id]
    if not n then
        self.title = nil
        doc:Title("Nobody yet")
        doc:Faded("Friendly folk appear here once you mouse over, target or talk to them.")
        doc:Finish()
        return
    end

    self.title = n.name or ("Unknown #" .. id)
    doc:Title(self.title)
    if n.title then doc:Faded(n.title) end
    doc:Gap(4)
    doc:Line(string.format("First met on %s%s.", ns.Date(n.firstSeen), n.zone and (" in " .. UI.ZoneLink(n.zone)) or ""))
    if n.visits and n.visits > 0 then
        doc:Line(string.format("Spoken with %d %s, last %s.", n.visits, n.visits == 1 and "time" or "times",
            ns.Ago(n.lastVisit)))
    end
    local roles = ns.RoleText(n)
    if roles ~= "" then doc:Line(roles) end
    if n.trade then doc:Line("Teaches " .. n.trade) end

    if n.mapID then
        local info = C_Map.GetMapInfo(n.mapID)
        doc:Heading("Where to find them" .. (info and info.name and (" - " .. info.name) or ""),
            UI.MapActions(function() ns.MapPins.Show("npc", id, n.mapID) end, n.mapID, n.x, n.y,
                "Pins them to the game's map."))
        doc:Gap(2)
        doc:Map(n.mapID, { { n.x, n.y, kind = "npc", label = n.name } }, { "npc", id })
    end

    local given = {}
    for questID in pairs(n.quests) do given[#given + 1] = questID end
    if #given > 0 then
        table.sort(given, function(a, b) return n.quests[a] < n.quests[b] end)
        doc:Heading("Quests they gave you (" .. #given .. ")")
        for _, questID in ipairs(given) do
            local q = ns.db.quests[questID]
            local status = q and (q.completed and ("done " .. ns.Date(q.completed)) or (q.abandoned and "abandoned"))
                or "in progress"
            doc:Line(UI.QuestLink(questID, QuestTitle(questID)) .. "  |cff6b5d4f" .. status .. "|r")
        end
    end

    local handed = {}
    for questID in pairs(n.turnIns) do handed[#handed + 1] = questID end
    if #handed > 0 then
        table.sort(handed, function(a, b) return n.turnIns[a] < n.turnIns[b] end)
        doc:Heading("Quests you handed in here (" .. #handed .. ")")
        for _, questID in ipairs(handed) do doc:Line(UI.QuestLink(questID, QuestTitle(questID))) end
    end

    self:RenderTalk(id, n)

    local wares = {}
    for itemID, entry in pairs(n.sells) do wares[#wares + 1] = { itemID = itemID, entry = entry } end
    if #wares > 0 then
        table.sort(wares, function(a, b) return (ItemName(a.entry) or "") < (ItemName(b.entry) or "") end)
        doc:Heading(string.format("Wares (%d, as of %s)", #wares, ns.Date(n.scanned)))
        doc:Gap(2)
        local cells = {}
        for _, w in ipairs(wares) do
            local e = w.entry
            local price = (e.price and e.price > 0) and ns.Money(e.price) or "special cost"
            if e.stack and e.stack > 1 then price = price .. " for " .. e.stack end
            if e.limited then price = price .. ", limited" end
            cells[#cells + 1] = {
                link = e.link or select(2, C_Item.GetItemInfo(w.itemID)),
                icon = C_Item.GetItemIconByID(w.itemID),
                note = price,
            }
        end
        doc:Grid(cells, 2)
    elseif n.roles.vendor then
        doc:Heading("Wares")
        doc:Faded("Open their shop again to record what they sell.")
    end

    self:RenderLessons(n)
    doc:Finish()
end

-- What a trainer teaches, grouped under the trainer's own headings ("Apprentice", "Journeyman").
-- Each lesson notes its cost and what it needs; ones you already knew are faded.
local STATUS = { used = "known", available = "can learn" }

local function LessonNote(s)
    local parts = {}
    if STATUS[s.kind] then
        parts[#parts + 1] = STATUS[s.kind]
    end
    if s.kind ~= "used" then
        if s.cost and s.cost > 0 then parts[#parts + 1] = ns.Money(s.cost) end
        if s.skill and s.rank and s.rank > 0 then
            parts[#parts + 1] = s.skill .. " " .. s.rank
        elseif s.level then
            parts[#parts + 1] = "level " .. s.level
        end
    end
    return table.concat(parts, ", ")
end

function Page:RenderLessons(n)
    local doc = self.doc
    if not n.teaches then
        if n.roles.trainer then
            doc:Heading("Lessons")
            doc:Faded("Open their training window again to record what they teach.")
        end
        return
    end
    local known = 0
    for _, s in ipairs(n.teaches) do
        if s.kind == "used" then known = known + 1 end
    end
    doc:Heading(string.format("Lessons (%d, as of %s)", #n.teaches, ns.Date(n.trainScanned)))
    doc:Faded(string.format("You knew %d of them then. Hover one for details.", known))

    local group, cells = false, {}
    local function flush()
        if #cells == 0 then return end
        if group then doc:Faded(group) end
        doc:Gap(2)
        doc:Grid(cells, 2)
        cells = {}
    end
    for _, s in ipairs(n.teaches) do
        if s.group ~= group then
            flush()
            group = s.group
        end
        cells[#cells + 1] = {
            link = s.link, name = s.name, icon = s.icon,
            note = LessonNote(s), dim = s.kind == "used",
            tipTitle = s.name, tipText = s.desc,
        }
    end
    flush()
end

------------------------------------------------------------------------------
-- What they say (Gossip.lua): the greeting, the replies it offers, and under each reply you've
-- chosen the page it led to, indented, as far as you've followed the conversation.
------------------------------------------------------------------------------

local INDENT = 16
local MAX_INDENT = 6 -- deeper pages line up with the sixth step instead of running off the page
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t"
local OPENS = { shop = "opens their shop", training = "opens their training", flight = "opens the flight map",
    bank = "opens your bank" }

-- Earlier versions of a page's words, shown on request: ["npcID:page"] = true.
Page.earlier = {}

UI.RegisterLink("talkold", function(id, index)
    local key = id .. ":" .. index
    Page.earlier[key] = not Page.earlier[key] or nil
    Page:Render()
end, function(id, index)
    if Page.earlier[id .. ":" .. index] then return "Earlier words", "Click to hide them again." end
    return "Earlier words", "What they said here before, with when you heard it."
end)

local function Plural(n, one, many)
    return n == 1 and one or many
end

-- A page's words, newest first: { { text, first, last } }.
local function Versions(page)
    local list = {}
    for _, s in ipairs(page.says) do list[#list + 1] = s end
    table.sort(list, function(a, b) return a[3] > b[3] end)
    return list
end

-- "Fear the Wailing Caverns...", short, for a reply that leads back to an earlier page.
local function Gist(page)
    local s = Versions(page)[1]
    if not s then return "a page with no words" end
    local text = s[1]:gsub("%s+", " ")
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
        local since = #versions > 1 and string.format("  |cff6b5d4f(since %s)|r", ns.Date(versions[1][2])) or ""
        doc:Text("\"" .. versions[1][1] .. "\"" .. since, 12, UI.INK, nil, x)
    elseif depth == 0 then
        doc:Text("They said nothing, only offered a choice.", 11, UI.FADED, nil, x)
    end
    if #versions > 1 then
        local key = id .. ":" .. index
        local open = self.earlier[key]
        local label = open and "Hide earlier words" or string.format("Earlier words (%d)", #versions - 1)
        doc:Text(UI.Link(label, "talkold", id, index), 11, nil, nil, x)
        if open then
            for i = 2, #versions do
                local s = versions[i]
                local when = ns.Date(s[2]) == ns.Date(s[3]) and ns.Date(s[2])
                    or (ns.Date(s[2]) .. " to " .. ns.Date(s[3]))
                doc:Text("\"" .. s[1] .. "\"  |cff6b5d4f(" .. when .. ")|r", 11, UI.FADED, nil, x + 10)
            end
        end
    end

    -- Quests listed on the page; ones in your quest journal open there.
    if page.quests and next(page.quests) then
        local list = {}
        for questID, title in pairs(page.quests) do
            local q = ns.db.quests[questID]
            local name = (q and q.title) or (type(title) == "string" and title) or ("Quest #" .. questID)
            list[#list + 1] = { name = name, text = q and UI.QuestLink(questID, name) or name }
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local texts = {}
        for _, e in ipairs(list) do texts[#texts + 1] = e.text end
        doc:Text("Quests: " .. table.concat(texts, ", "), 11, UI.FADED, nil, x)
    end

    local opts = {}
    for _, o in ipairs(page.opts) do opts[#opts + 1] = o end
    table.sort(opts, function(a, b)
        if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
        return (a.first or 0) < (b.first or 0)
    end)
    for _, o in ipairs(opts) do
        local notes = {}
        if (o.picks or 0) > 0 then
            notes[#notes + 1] = TICK .. " chosen " .. (o.picks == 1 and "once" or (o.picks .. " times"))
        end
        if o.opens and OPENS[o.opens] then notes[#notes + 1] = OPENS[o.opens] end
        if (o.n or 0) < (page.n or 0) then
            notes[#notes + 1] = string.format("offered %d of %d %s", o.n or 0, page.n, Plural(page.n, "time", "times"))
        end
        local icon = o.icon and ("|T" .. o.icon .. ":14:14:0:0|t ") or ""
        local note = #notes > 0 and ("  |cff6b5d4f" .. table.concat(notes, ", ") .. "|r") or ""
        doc:Text(icon .. o.name .. note, 12, (o.picks or 0) > 0 and UI.INK or UI.FADED, nil, x)

        local to = o.to and pages[o.to]
        if to then
            local inner = 8 + math.min(depth + 1, MAX_INDENT) * INDENT
            if done[o.to] then
                local where = o.to == 1 and "the greeting" or Gist(to)
                doc:Text("» back to " .. where, 11, UI.FADED, nil, inner)
            else
                self:RenderTalkPage(id, pages, o.to, depth + 1, done)
            end
        end
    end
end

function Page:RenderTalk(id, n)
    local pages = n.gossip
    if not (pages and pages[1]) then return end
    local root = pages[1]
    local heard = (root.n or 0) > 0 and string.format(" (heard %d %s)", root.n, Plural(root.n, "time", "times")) or ""
    self.doc:Heading("What they say" .. heard)
    self:RenderTalkPage(id, pages, 1, 0, {})
end
