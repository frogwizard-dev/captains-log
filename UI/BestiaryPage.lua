local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Bestiary"], color = { 0.20, 0.36, 0.16 }, order = 2 }
ns.Pages.bestiary = Page

local CLASSIFICATION = { rare = L["Rare"], rareelite = L["Rare Elite"], elite = L["Elite"], worldboss = L["Boss"] }
local CLASS_COLOR = {
    rare = { 0.15, 0.25, 0.55 }, rareelite = { 0.15, 0.25, 0.55 },
    elite = { 0.55, 0.35, 0.02 }, worldboss = { 0.55, 0.08, 0.05 },
}
local SORTS = {
    { "name", L["Name"] },
    { "kills", L["Most slain"] },
    { "recent", L["Recently slain"] },
    { "first", L["Recently met"] },
}

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sort, self.query = "name", ""
    self.sub = ns.Book:Header(left, L["Bestiary"])

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    self.search = search
    local sort = UI.Dropdown(left, 170, SORTS, function() return self.sort end, function(v)
        self.sort = v
        self:Render()
    end)
    sort:SetPoint("TOPRIGHT", 0, -60)

    self.list = UI.List(left, W, H - 94)
    self.list.sf:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
end

local function Sorter(key)
    return function(a, b)
        local ma, mb = a.mob, b.mob
        if key == "kills" and ma.kills ~= mb.kills then return ma.kills > mb.kills end
        if key == "recent" and (ma.lastKill or 0) ~= (mb.lastKill or 0) then return (ma.lastKill or 0) > (mb.lastKill or 0) end
        if key == "first" and (ma.firstSeen or 0) ~= (mb.firstSeen or 0) then return (ma.firstSeen or 0) > (mb.firstSeen or 0) end
        return (ma.name or "") < (mb.name or "")
    end
end

function Page:Render()
    ns.FillNames()
    local entries, total = {}, 0
    for id, m in pairs(ns.db.mobs) do
        total = total + 1
        local name = m.name or L["Unknown creature #%s"]:format(tostring(id))
        if self.query == "" or name:lower():find(self.query, 1, true) then
            entries[#entries + 1] = { id = id, mob = m, name = name }
        end
    end
    table.sort(entries, Sorter(self.sort))
    self.sub:SetText(L["%s creatures recorded"]:format(total))

    if not self.selected or not ns.db.mobs[self.selected] then
        self.selected = entries[1] and entries[1].id
    end

    local items = {}
    for _, e in ipairs(entries) do
        items[#items + 1] = {
            key = e.id,
            left = e.name,
            right = e.mob.kills > 0 and ("x" .. ns.Number(e.mob.kills)) or L["met"],
            color = CLASS_COLOR[e.mob.classification],
        }
    end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)

    self:RenderMob(self.selected)
end

local function LevelText(m)
    if not m.minLevel then return "" end
    if m.minLevel == m.maxLevel then return L["Level %s"]:format(m.minLevel) end
    return L["Level %s-%s"]:format(m.minLevel, m.maxLevel)
end

function Page:RenderMob(id)
    local doc = self.doc
    doc:Clear("mob:" .. tostring(id))
    ns.Book:BackLink(doc)
    local m = id and ns.db.mobs[id]
    if not m then
        self.title = nil
        doc:Title(L["An empty bestiary"])
        doc:Faded(L["Creatures appear here the first time you meet them."])
        doc:Finish()
        return
    end

    self.title = m.name or L["Unknown creature #%s"]:format(tostring(id))
    doc:Title(self.title)
    local kind = strtrim(string.format("%s %s %s", LevelText(m),
        CLASSIFICATION[m.classification] or "", m.creatureType or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Gap(4)

    if m.firstSeen then
        doc:Line(string.format(L["First met on %s%s, when you were level %d."], ns.Date(m.firstSeen),
            m.firstZone and L[" in %s"]:format(UI.ZoneLink(m.firstZone)) or "", m.firstLevel or 0))
    end
    if m.kills > 0 then
        doc:Line(string.format(L["Slain %s %s, most recently %s."], ns.Number(m.kills),
            m.kills == 1 and L["time"] or L["times"], ns.Ago(m.lastKill)))
    else
        doc:Line(L["Never slain."])
    end
    if m.killedMe > 0 then
        doc:Line(string.format(L["Has killed you %d %s."], m.killedMe, m.killedMe == 1 and L["time"] or L["times"]), UI.ACCENT)
    end

    -- Quests that want this creature dead (or something it carries). Those in progress sit up
    -- here; finished and abandoned ones are kept as a faded record at the very bottom.
    local active, past = {}, {}
    for _, w in ipairs(ns.MobQuests(id)) do
        table.insert((w.q.completed or w.q.abandoned) and past or active, w)
    end
    if #active > 0 then
        doc:Heading(L["Wanted for"])
        for _, w in ipairs(active) do
            doc:Check(UI.QuestLink(w.questID) .. (w.item and ("  |cff6b5d4f" .. L["for its %s"]:format(w.item) .. "|r") or ""), nil, UI.INK)
        end
    end

    local battle = ns.CombatLines(m)
    if #battle > 0 then
        doc:Heading(L["In battle"])
        for _, line in ipairs(battle) do doc:Line(line) end
    end

    local zones = {}
    for zone, n in pairs(m.zones) do zones[#zones + 1] = { zone = zone, n = n } end
    if #zones > 0 then
        table.sort(zones, function(a, b) return a.n > b.n end)
        doc:Heading(L["Hunting grounds"])
        for _, z in ipairs(zones) do doc:Line(string.format("%s  x%d", UI.ZoneLink(z.zone), z.n)) end
    end

    -- Map of the zone where you've killed it most, a dot per kill (latest 60).
    local bestMap, bestSpots
    for mapID, spots in pairs(m.spots or {}) do
        if not bestSpots or #spots > #bestSpots then bestMap, bestSpots = mapID, spots end
    end
    if bestMap then
        local info = C_Map.GetMapInfo(bestMap)
        local zone = info and info.name
        doc:Heading(zone and L["Where you've slain it - %s"]:format(zone) or L["Where you've slain it"],
            UI.MapActions(function() ns.MapPins.Show("mob", id, bestMap) end, nil, nil, nil,
                L["Pins every spot you've slain it to the game's map."]))
        doc:Gap(2)
        doc:Map(bestMap, bestSpots, { "mob", id })
    end

    local drops = {}
    for itemID, d in pairs(m.drops) do drops[#drops + 1] = { itemID = itemID, d = d } end
    if #drops > 0 then
        table.sort(drops, function(a, b) return a.d.times > b.d.times end)
        doc:Heading(string.format(L["Spoils (from %d %s looted)"], m.looted, m.looted == 1 and L["corpse"] or L["corpses"]))
        for _, e in ipairs(drops) do
            -- "x3  (66%, 2/3)": total taken, then how many corpses it dropped from.
            local rate = m.looted > 0 and math.floor(e.d.times / m.looted * 100) or 0
            local link = e.d.link or select(2, C_Item.GetItemInfo(e.itemID))
            doc:Item(link, string.format("x%d  (%d%%, %d/%d)", e.d.qty, rate, e.d.times, m.looted),
                C_Item.GetItemIconByID(e.itemID))
        end
    elseif m.looted > 0 then
        doc:Heading(L["Spoils"])
        doc:Faded(string.format(L["Looted %d %s; nothing but coin so far."], m.looted, m.looted == 1 and L["time"] or L["times"]))
    end

    if #past > 0 then
        doc:Heading(L["Once wanted for"])
        for _, w in ipairs(past) do
            local status = w.q.completed and L["done %s"]:format(ns.Date(w.q.completed)) or L["abandoned"]
            doc:Text(UI.QuestLink(w.questID) .. "  |cff6b5d4f" .. status .. "|r", 11, UI.FADED, nil, 8)
        end
    end
    doc:Finish()
end
