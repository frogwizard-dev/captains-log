local _, ns = ...
local UI = ns.UI

local Page = { label = "Lands", color = { 0.55, 0.40, 0.10 }, order = 4 }
ns.Pages.zones = Page

local SORTS = {
    { "recent", "Recently visited" },
    { "first", "First visited" },
    { "time", "Most time spent" },
    { "name", "Name" },
}
local NOTABLE = { rare = "Rare", rareelite = "Rare Elite", elite = "Elite", worldboss = "Boss" }
local INSTANCE_KIND = { party = "Dungeon", raid = "Raid", scenario = "Scenario", pvp = "Battleground", arena = "Arena" }
local LIST_MAX = 15

local function Sorter(key, zones)
    return function(a, b)
        local za, zb = zones[a], zones[b]
        if key == "recent" then
            local ta, tb = za.last or za.first, zb.last or zb.first
            if ta ~= tb then return ta > tb end
        elseif key == "first" then
            if za.first ~= zb.first then return za.first > zb.first end
        elseif key == "time" then
            if za.seconds ~= zb.seconds then return za.seconds > zb.seconds end
        end
        return a < b
    end
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sort, self.query = "recent", ""
    self.sub = ns.Book:Header(left, "Lands Visited")

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    local sort = UI.Dropdown(left, 170, SORTS, function() return self.sort end, function(v)
        self.sort = v
        self:Render()
    end)
    sort:SetPoint("TOPRIGHT", 0, -60)
    self.search = search

    self.list = UI.List(left, W, H - 94)
    self.list.sf:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
end

-- A land matches on its own name or any place discovered in it.
local function Matches(name, z, query)
    if query == "" or name:lower():find(query, 1, true) then return true end
    for place in pairs(z.places or {}) do
        if place:lower():find(query, 1, true) then return true end
    end
    return false
end

-- The land's map: recorded on arrival, or borrowed from anything else pinned there.
local function ZoneMapID(name, z)
    if z.mapID then return z.mapID end
    for _, p in pairs(z.places or {}) do
        if p.mapID then return p.mapID end
    end
    for _, d in ipairs(ns.db.deaths) do
        if d.zone == name and d.mapID then return d.mapID end
    end
    for _, n in pairs(ns.db.npcs) do
        if n.zone == name and n.mapID then return n.mapID end
    end
end

-- The dungeon or raid runs made in a land (an instance is recorded as a land too).
local function Runs(name)
    local list = {}
    for _, run in ipairs(ns.db.runs) do
        if run.name == name then list[#list + 1] = run end
    end
    return list
end

-- Instances are noted on arrival; older entries are known by having a run of the same name.
local function IsInstance(name, z)
    return z.instance ~= nil or #Runs(name) > 0
end

local INSTANCES = "Dungeons & raids"
local ELSEWHERE = "Elsewhere"

-- Which heading a land is listed under: its continent, or the dungeons.
local function LandGroup(name, z)
    if IsInstance(name, z) then return INSTANCES end
    local mapID = ZoneMapID(name, z)
    return z.continent or (mapID and ns.Continent(mapID)) or ELSEWHERE
end

-- Continents in alphabetical order, then the dungeons, then anything without a map.
local function GroupOrder(a, b)
    local ra = (a == INSTANCES and 1) or (a == ELSEWHERE and 2) or 0
    local rb = (b == INSTANCES and 1) or (b == ELSEWHERE and 2) or 0
    if ra ~= rb then return ra < rb end
    return a < b
end

function Page:Render()
    local zones = ns.db.zones
    local groups, total = {}, 0
    for name, z in pairs(zones) do
        total = total + 1
        if Matches(name, z, self.query) then
            local g = LandGroup(name, z)
            groups[g] = groups[g] or {}
            table.insert(groups[g], name)
        end
    end
    local order = {}
    for g in pairs(groups) do order[#order + 1] = g end
    table.sort(order, GroupOrder)
    self.sub:SetText(total .. (total == 1 and " land" or " lands") .. "  ·  search lands or places in them")

    -- Each landmass as a heading, its lands beneath in the chosen order.
    local items, first = {}, nil
    for _, g in ipairs(order) do
        local names = groups[g]
        table.sort(names, Sorter(self.sort, zones))
        items[#items + 1] = { key = "group:" .. g, left = g, right = #names, header = true }
        for _, name in ipairs(names) do
            first = first or name
            items[#items + 1] = { key = name, left = name, right = ns.Duration(zones[name].seconds), indent = 12 }
        end
    end
    if not self.selected or not zones[self.selected] then self.selected = first end
    self.list:SetItems(items, self.selected, function(name)
        self.selected = name
        self:Render()
    end)
    self:RenderZone(self.selected)
end

local function More(doc, shown, total, where)
    if total > shown then
        doc:Faded(string.format("...and %d more%s.", total - shown, where and (" (see " .. where .. ")") or ""))
    end
end

function Page:RenderMap(name, z, people, deaths)
    local doc = self.doc
    local mapID = ZoneMapID(name, z)
    if not mapID then return end
    local spots, kinds = {}, {}
    local function add(x, y, kind, label)
        if not x or not y then return end
        spots[#spots + 1] = { x, y, kind = kind, label = label }
        kinds[kind] = true
    end
    for place, p in pairs(z.places or {}) do
        if p.mapID == mapID then add(p.x, p.y, "place", place .. "\nFound " .. ns.Date(p.t)) end
    end
    for _, n in ipairs(people) do
        if n.mapID == mapID then add(n.x, n.y, "npc", n.name .. (n.title and ("\n" .. n.title) or "")) end
    end
    for _, d in ipairs(deaths) do
        if d.mapID == mapID then
            add(d.x, d.y, "death", (d.killer and ("Slain by " .. d.killer) or "Died") .. "\n" .. ns.Date(d.time))
        end
    end

    local info = C_Map.GetMapInfo(mapID)
    doc:Heading("The map" .. (info and info.name and info.name ~= name and (" - " .. info.name) or ""),
        UI.MapActions(function() ns.MapPins.Show("zone", name, mapID) end, nil, nil, nil,
            "Pins this land's places, deaths and the folk who serve you (vendors, trainers...) to the game's map."))
    local legend = {}
    if kinds.place then legend[#legend + 1] = UI.Swatch("place", "places") end
    if kinds.npc then legend[#legend + 1] = UI.Swatch("npc", "people") end
    if kinds.death then legend[#legend + 1] = UI.Swatch("death", "deaths") end
    if #legend > 0 then doc:Faded(table.concat(legend, "     ") .. "     (hover a pin)") end
    doc:Map(mapID, spots, { "zone", name })
end

-- An instance's page: your runs in short, a link to its full record on the Dungeons page,
-- and the dungeon's own map from the Encounter Journal (positions inside aren't recorded).
function Page:RenderDungeon(runs)
    local doc = self.doc
    if #runs == 0 then return end
    local clears, fastest, journalID = 0, nil, nil
    for _, run in ipairs(runs) do
        journalID = run.journalID or journalID
        if run.totalBosses and #run.bosses >= run.totalBosses then
            clears = clears + 1
            local d = ns.RunDuration(run)
            if not fastest or d < fastest then fastest = d end
        end
    end
    doc:Heading("Your runs")
    doc:Line(string.format("Run %d %s, last on %s.", #runs, #runs == 1 and "time" or "times", ns.Date(runs[#runs].start)))
    if clears > 0 then
        doc:Line(string.format("Full clears: %d, fastest %s.", clears, ns.Duration(fastest)))
    end
    doc:Text(UI.Link("See every run, boss records and loot", "dungeon", ns.InstanceKey(runs[#runs])), 11, nil, nil, 8)

    if journalID and EJ_GetInstanceInfo then
        local ok, _, _, _, _, _, _, areaMapID = pcall(EJ_GetInstanceInfo, journalID)
        if ok and type(areaMapID) == "number" and areaMapID > 0 then
            doc:Heading("The map")
            doc:Map(areaMapID, {})
        end
    end
end

function Page:RenderZone(name)
    local doc = self.doc
    doc:Clear("zone:" .. tostring(name))
    ns.Book:BackLink(doc)
    local z = name and ns.db.zones[name]
    if not z then
        self.title = nil
        doc:Title(next(ns.db.zones) and "Nothing matches" or "Uncharted")
        doc:Faded("Lands appear here as you travel.")
        doc:Finish()
        return
    end
    self.title = name
    doc:Title(name)
    local instance = IsInstance(name, z)
    local runs = Runs(name)
    if instance then
        local kind = INSTANCE_KIND[z.instance] or INSTANCE_KIND[runs[1] and runs[1].type] or "Dungeon"
        doc:Faded(kind)
    else
        local mapID = ZoneMapID(name, z)
        local info = mapID and C_Map.GetMapInfo(mapID)
        local parent = info and info.parentMapID and info.parentMapID > 0 and C_Map.GetMapInfo(info.parentMapID)
        if parent and parent.name then doc:Faded(parent.name) end
    end
    doc:Gap(4)

    doc:Line(string.format("First arrived %s at level %d.", ns.Date(z.first), z.level or 0))
    if z.visits and z.visits > 1 then
        doc:Line(string.format("Visited %d times, last %s.", z.visits, ns.Ago(z.last or z.first)))
    end
    if z.maxLevel and z.level and z.maxLevel > z.level then
        doc:Line(string.format("You were level %d to %d while here.", z.level, z.maxLevel))
    end
    doc:Line("Time spent: " .. ns.Duration(z.seconds))
    if z.kills > 0 then doc:Line("Creatures slain: " .. ns.Number(z.kills)) end
    if z.quests > 0 then doc:Line("Quests completed: " .. z.quests) end
    if z.deaths > 0 then doc:Line("Deaths: " .. z.deaths, UI.ACCENT) end

    -- Everything below is gathered from the other sections of the book.
    local people, npcID = {}, {}
    for id, n in pairs(ns.db.npcs) do
        if n.zone == name and n.name then
            people[#people + 1] = n
            npcID[n] = id
        end
    end
    table.sort(people, function(a, b)
        local ra, rb = next(a.roles) ~= nil, next(b.roles) ~= nil
        if ra ~= rb then return ra end
        return a.name < b.name
    end)
    local deaths = {}
    for _, d in ipairs(ns.db.deaths) do
        if d.zone == name then deaths[#deaths + 1] = d end
    end

    if instance then
        self:RenderDungeon(runs)
    else
        self:RenderMap(name, z, people, deaths)
    end

    local places = {}
    for place, p in pairs(z.places or {}) do places[#places + 1] = { name = place, p = p } end
    if #places > 0 then
        table.sort(places, function(a, b) return a.p.t < b.p.t end)
        doc:Heading("Places discovered (" .. #places .. ")")
        for _, e in ipairs(places) do
            doc:Line(string.format("%s  |cff6b5d4f%s, level %d|r", e.name, ns.Date(e.p.t), e.p.level or 0))
        end
    end

    -- Pictures taken in this land, each opening its day's pictures.
    local photos = ns.AllPhotos(name)
    if #photos > 0 then
        doc:Heading("Pictures taken here (" .. #photos .. ")")
        for i = #photos, math.max(1, #photos - LIST_MAX + 1), -1 do
            local e = photos[i]
            local p = e.photo
            doc:Line(UI.Link(p.caption or (p.place or name), "photos", e.day)
                .. "  |cff6b5d4f" .. date("%d %b %Y, %H:%M", p.t) .. "|r")
        end
        More(doc, LIST_MAX, #photos)
    end

    if #people > 0 then
        doc:Heading("Folk met here (" .. #people .. ")")
        for i = 1, math.min(#people, LIST_MAX) do
            local n = people[i]
            local roles = ns.RoleText(n)
            doc:Line(UI.NpcLink(npcID[n]) .. (n.title and (", " .. n.title) or "")
                .. (roles ~= "" and ("  |cff6b5d4f" .. roles .. "|r") or ""))
        end
        More(doc, LIST_MAX, #people, "People")
    end

    local done, open = {}, {}
    for id, q in pairs(ns.db.quests) do
        if q.completed and q.zone == name then
            done[#done + 1] = id
        elseif not q.completed and not q.abandoned and q.acceptZone == name then
            open[#open + 1] = id
        end
    end
    local quests = ns.db.quests
    if #open > 0 then
        table.sort(open, function(a, b) return (quests[a].accepted or 0) > (quests[b].accepted or 0) end)
        doc:Heading("Quests still open from here (" .. #open .. ")")
        for i = 1, math.min(#open, LIST_MAX) do
            doc:Line(UI.QuestLink(open[i]))
        end
        More(doc, LIST_MAX, #open, "Quests")
    end
    if #done > 0 then
        table.sort(done, function(a, b) return quests[a].completed > quests[b].completed end)
        doc:Heading("Quests completed here (" .. #done .. ")")
        for i = 1, math.min(#done, LIST_MAX) do
            doc:Line(UI.QuestLink(done[i]))
        end
        More(doc, LIST_MAX, #done, "Quests")
    end

    -- Rares and elites met or slain here; then everything you've hunted here, most first.
    local notable, mobs = {}, {}
    for id, m in pairs(ns.db.mobs) do
        local n = m.zones[name]
        if n then mobs[#mobs + 1] = { id = id, name = m.name or "?", n = n } end
        if NOTABLE[m.classification] and (n or m.firstZone == name) then
            notable[#notable + 1] = { id = id, m = m, n = n or 0 }
        end
    end
    if #notable > 0 then
        table.sort(notable, function(a, b) return (a.m.name or "") < (b.m.name or "") end)
        doc:Heading("Notable foes")
        for _, e in ipairs(notable) do
            doc:Line(string.format("%s  |cff6b5d4f%s, %s|r", UI.MobLink(e.id, e.m.name), NOTABLE[e.m.classification],
                e.n > 0 and ("slain x" .. e.n) or "not slain"))
        end
    end
    if #mobs > 0 then
        table.sort(mobs, function(a, b) return a.n > b.n end)
        doc:Heading("Most hunted here")
        for i = 1, math.min(#mobs, 12) do
            doc:Line(string.format("%s  x%d", UI.MobLink(mobs[i].id, mobs[i].name), mobs[i].n))
        end
    end

    if #deaths > 0 then
        doc:Heading("Fallen here")
        for _, d in ipairs(deaths) do
            doc:Line(string.format("%s at level %d, %s", d.killer and ("Slain by " .. d.killer) or "Died",
                d.level or 0, ns.Date(d.time)), UI.ACCENT)
        end
    end
    doc:Finish()
end
