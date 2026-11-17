local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Lands"], color = { 0.55, 0.40, 0.10 }, order = 4 }
ns.Pages.zones = Page

local SORTS = {
    { "recent", L["Recently visited"] },
    { "first", L["First visited"] },
    { "time", L["Most time spent"] },
    { "name", L["Name"] },
}
local NOTABLE = { rare = L["Rare"], rareelite = L["Rare Elite"], elite = L["Elite"], worldboss = L["Boss"] }
local INSTANCE_KIND = { party = L["Dungeon"], raid = L["Raid"], scenario = L["Scenario"], pvp = L["Battleground"], arena = L["Arena"] }
local LIST_MAX = 15

-- What each sort puts first, from a land's record; then by name.
local SORT_VALUE = {
    recent = function(record) return record.last or record.first end,
    first = function(record) return record.first end,
    time = function(record) return record.seconds end,
}

local function Sorter(sortKey, zones)
    local Value = SORT_VALUE[sortKey]
    return function(first, second)
        if Value then
            local firstValue, secondValue = Value(zones[first]), Value(zones[second])
            if firstValue ~= secondValue then return firstValue > secondValue end
        end
        return first < second
    end
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sort, self.query = "recent", ""
    self.subtitle = ns.Book:Header(left, L["Lands Visited"])

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    local sort = UI.Dropdown(left, 170, SORTS, function() return self.sort end, function(sortKey)
        self.sort = sortKey
        self:Render()
    end)
    sort:SetPoint("TOPRIGHT", 0, -60)
    self.search = search

    self.list = UI.List(left, width, height - 94)
    self.list.scroll:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
end

-- A land matches on its own name or any place discovered in it.
local function Matches(name, record, query)
    if query == "" or name:lower():find(query, 1, true) then return true end
    for place in pairs(record.places or {}) do
        if place:lower():find(query, 1, true) then return true end
    end
    return false
end

-- The land's map: recorded on arrival, or borrowed from anything else pinned there.
local function ZoneMapID(name, record)
    if record.mapID then return record.mapID end
    for _, found in pairs(record.places or {}) do
        if found.mapID then return found.mapID end
    end
    for _, death in ipairs(ns.db.deaths) do
        if death.zone == name and death.mapID then return death.mapID end
    end
    for _, npc in pairs(ns.db.npcs) do
        if npc.zone == name and npc.mapID then return npc.mapID end
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
local function IsInstance(name, record)
    return record.instance ~= nil or #Runs(name) > 0
end

local INSTANCES = L["Dungeons & raids"]
local ELSEWHERE = L["Elsewhere"]

-- Which heading a land is listed under: its continent, or the dungeons.
local function LandGroup(name, record)
    if IsInstance(name, record) then return INSTANCES end
    local mapID = ZoneMapID(name, record)
    return record.continent or (mapID and ns.Continent(mapID)) or ELSEWHERE
end

-- Continents in alphabetical order, then the dungeons, then anything without a map.
local GROUP_RANK = { [INSTANCES] = 1, [ELSEWHERE] = 2 }
local function GroupOrder(first, second)
    local firstRank, secondRank = GROUP_RANK[first] or 0, GROUP_RANK[second] or 0
    if firstRank ~= secondRank then return firstRank < secondRank end
    return first < second
end

function Page:Render()
    local zones = ns.db.zones
    local groups, total = {}, 0
    for name, record in pairs(zones) do
        total = total + 1
        if Matches(name, record, self.query) then
            local group = LandGroup(name, record)
            groups[group] = groups[group] or {}
            table.insert(groups[group], name)
        end
    end
    local order = {}
    for group in pairs(groups) do order[#order + 1] = group end
    table.sort(order, GroupOrder)
    self.subtitle:SetText((total == 1 and L["%d land  ·  search lands or places in them"]
        or L["%d lands  ·  search lands or places in them"]):format(total))

    -- Each landmass as a heading, its lands beneath in the chosen order.
    local items, first = {}, nil
    for _, group in ipairs(order) do
        local names = groups[group]
        table.sort(names, Sorter(self.sort, zones))
        items[#items + 1] = { key = "group:" .. group, left = group, right = #names, header = true }
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
        doc:Faded(string.format(L["...and %d more%s."], total - shown, where and L[" (see %s)"]:format(where) or ""))
    end
end

function Page:RenderMap(name, record, people, deaths)
    local doc = self.doc
    local mapID = ZoneMapID(name, record)
    if not mapID then return end
    local spots, kinds = {}, {}
    local function Add(x, y, kind, label)
        if not x or not y then return end
        spots[#spots + 1] = { x, y, kind = kind, label = label }
        kinds[kind] = true
    end
    for place, found in pairs(record.places or {}) do
        if found.mapID == mapID then Add(found.x, found.y, "place", L["%s\nFound %s"]:format(place, ns.Date(found.t))) end
    end
    for _, npc in ipairs(people) do
        if npc.mapID == mapID then Add(npc.x, npc.y, "npc", npc.name .. (npc.title and ("\n" .. npc.title) or "")) end
    end
    for _, death in ipairs(deaths) do
        if death.mapID == mapID then
            Add(death.x, death.y, "death",
                (death.killer and L["Slain by %s"]:format(death.killer) or L["Died"]) .. "\n" .. ns.Date(death.time))
        end
    end

    local map = C_Map.GetMapInfo(mapID)
    doc:Heading((map and map.name and map.name ~= name) and L["The map: %s"]:format(map.name) or L["The map"],
        UI.MapActions(function() ns.MapPins.Show("zone", name, mapID) end, nil, nil, nil,
            L["Pins this land's places, deaths and the folk who serve you (vendors, trainers...) to the game's map."]))
    local legend = {}
    if kinds.place then legend[#legend + 1] = UI.Swatch("place", L["places"]) end
    if kinds.npc then legend[#legend + 1] = UI.Swatch("npc", L["people"]) end
    if kinds.death then legend[#legend + 1] = UI.Swatch("death", L["deaths"]) end
    if #legend > 0 then doc:Faded(L["%s     (hover a pin)"]:format(table.concat(legend, "     "))) end
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
            local duration = ns.RunDuration(run)
            if not fastest or duration < fastest then fastest = duration end
        end
    end
    doc:Heading(L["Your runs"])
    doc:Line(string.format(#runs == 1 and L["Run %d time, last on %s."] or L["Run %d times, last on %s."], #runs,
        ns.Date(runs[#runs].start)))
    if clears > 0 then
        doc:Line(string.format(L["Full clears: %d, fastest %s."], clears, ns.Duration(fastest)))
    end
    doc:Text(UI.Link(L["See every run, boss records and loot"], "dungeon", ns.InstanceKey(runs[#runs])), 11, nil, nil, 8)

    if journalID and EJ_GetInstanceInfo then
        local ok, _, _, _, _, _, _, areaMapID = pcall(EJ_GetInstanceInfo, journalID)
        if ok and type(areaMapID) == "number" and areaMapID > 0 then
            doc:Heading(L["The map"])
            doc:Map(areaMapID, {})
        end
    end
end

function Page:RenderZone(name)
    local doc = self.doc
    doc:Clear("zone:" .. tostring(name))
    ns.Book:BackLink(doc)
    local record = name and ns.db.zones[name]
    if not record then
        self.title = nil
        doc:Title(next(ns.db.zones) and L["Nothing matches"] or L["Uncharted"])
        doc:Faded(L["Lands appear here as you travel."])
        doc:Finish()
        return
    end
    self.title = name
    doc:Title(name)
    local instance = IsInstance(name, record)
    local runs = Runs(name)
    if instance then
        local kind = INSTANCE_KIND[record.instance] or INSTANCE_KIND[runs[1] and runs[1].type] or L["Dungeon"]
        doc:Faded(kind)
    else
        local mapID = ZoneMapID(name, record)
        local map = mapID and C_Map.GetMapInfo(mapID)
        local parent = map and map.parentMapID and map.parentMapID > 0 and C_Map.GetMapInfo(map.parentMapID)
        if parent and parent.name then doc:Faded(parent.name) end
    end
    doc:Gap(4)

    doc:Line(string.format(L["First arrived %s at level %d."], ns.Date(record.first), record.level or 0))
    if record.visits and record.visits > 1 then
        doc:Line(string.format(L["Visited %d times, last %s."], record.visits, ns.Ago(record.last or record.first)))
    end
    if record.maxLevel and record.level and record.maxLevel > record.level then
        doc:Line(string.format(L["You were level %d to %d while here."], record.level, record.maxLevel))
    end
    doc:Line(L["Time spent: %s"]:format(ns.Duration(record.seconds)))
    if record.kills > 0 then doc:Line(L["Creatures slain: %s"]:format(ns.Number(record.kills))) end
    if record.quests > 0 then doc:Line(L["Quests completed: %s"]:format(record.quests)) end
    local journal = ns.FishingJournal()
    local fish = 0
    for _, spot in pairs(journal.spots[name] or {}) do fish = fish + spot.n end
    if fish > 0 then doc:Line(L["Fish caught: %s"]:format(ns.Number(fish))) end
    if record.deaths > 0 then doc:Line(L["Deaths: %s"]:format(record.deaths), UI.ACCENT) end

    -- Everything below is gathered from the other sections of the book.
    local people, npcID = {}, {}
    for id, npc in pairs(ns.db.npcs) do
        if npc.zone == name and npc.name then
            people[#people + 1] = npc
            npcID[npc] = id
        end
    end
    table.sort(people, function(first, second)
        local firstServes, secondServes = next(first.roles) ~= nil, next(second.roles) ~= nil
        if firstServes ~= secondServes then return firstServes end
        return first.name < second.name
    end)
    local deaths = {}
    for _, death in ipairs(ns.db.deaths) do
        if death.zone == name then deaths[#deaths + 1] = death end
    end

    if instance then
        self:RenderDungeon(runs)
    else
        self:RenderMap(name, record, people, deaths)
    end

    local places = {}
    for place, found in pairs(record.places or {}) do places[#places + 1] = { name = place, found = found } end
    if #places > 0 then
        table.sort(places, function(first, second) return first.found.t < second.found.t end)
        doc:Heading(L["Places discovered (%d)"]:format(#places))
        for _, place in ipairs(places) do
            doc:Line(string.format(L["%s  |cff6b5d4f%s, level %d|r"], place.name, ns.Date(place.found.t), place.found.level or 0))
        end
    end

    -- Where you've fished here, each opening its spot in Fishing.
    local fished = ns.FishingSpotsIn(name)
    if #fished > 0 then
        doc:Heading(L["Fishing here"])
        for i = 1, math.min(#fished, LIST_MAX) do
            local entry = fished[i]
            local top = ns.FishTopCatch(entry.spot)
            local topName = top and journal.items[top] and journal.items[top].name
            doc:Line(string.format("%s  x%d%s", UI.FishSpotLink(name, entry.place), entry.spot.n,
                topName and L["  |cff6b5d4fmostly %s|r"]:format(topName) or ""))
        end
        More(doc, LIST_MAX, #fished, L["Fishing"])
    end

    -- Pictures taken in this land, each opening its day's pictures.
    local photos = ns.AllPhotos(name)
    if #photos > 0 then
        doc:Heading(L["Pictures taken here (%d)"]:format(#photos))
        for i = #photos, math.max(1, #photos - LIST_MAX + 1), -1 do
            local entry = photos[i]
            local photo = entry.photo
            doc:Line(UI.Link(photo.caption or (photo.place or name), "photos", entry.day)
                .. "  |cff6b5d4f" .. date(L["%d %b %Y, %H:%M"], photo.t) .. "|r")
        end
        More(doc, LIST_MAX, #photos)
    end

    if #people > 0 then
        doc:Heading(L["Folk met here (%d)"]:format(#people))
        for i = 1, math.min(#people, LIST_MAX) do
            local npc = people[i]
            local roles = ns.RoleText(npc)
            doc:Line(UI.NpcLink(npcID[npc]) .. (npc.title and (", " .. npc.title) or "")
                .. (roles ~= "" and ("  |cff6b5d4f" .. roles .. "|r") or ""))
        end
        More(doc, LIST_MAX, #people, L["People"])
    end

    local quests = ns.db.quests
    local done, open = {}, {}
    for id, quest in pairs(quests) do
        if quest.completed and quest.zone == name then
            done[#done + 1] = id
        elseif not quest.completed and not quest.abandoned and quest.acceptZone == name then
            open[#open + 1] = id
        end
    end
    if #open > 0 then
        table.sort(open, function(first, second) return (quests[first].accepted or 0) > (quests[second].accepted or 0) end)
        doc:Heading(L["Quests still open from here (%d)"]:format(#open))
        for i = 1, math.min(#open, LIST_MAX) do
            doc:Line(UI.QuestLink(open[i]))
        end
        More(doc, LIST_MAX, #open, L["Quests"])
    end
    if #done > 0 then
        table.sort(done, function(first, second) return quests[first].completed > quests[second].completed end)
        doc:Heading(L["Quests completed here (%d)"]:format(#done))
        for i = 1, math.min(#done, LIST_MAX) do
            doc:Line(UI.QuestLink(done[i]))
        end
        More(doc, LIST_MAX, #done, L["Quests"])
    end

    -- Rares and elites met or slain here; then everything you've hunted here, most first.
    local notable, mobs = {}, {}
    for id, mob in pairs(ns.db.mobs) do
        local kills = mob.zones[name]
        if kills then mobs[#mobs + 1] = { id = id, name = mob.name or "?", n = kills } end
        if NOTABLE[mob.classification] and (kills or mob.firstZone == name) then
            notable[#notable + 1] = { id = id, mob = mob, n = kills or 0 }
        end
    end
    if #notable > 0 then
        table.sort(notable, function(first, second) return (first.mob.name or "") < (second.mob.name or "") end)
        doc:Heading(L["Notable foes"])
        for _, foe in ipairs(notable) do
            doc:Line(string.format("%s  |cff6b5d4f%s, %s|r", UI.MobLink(foe.id, foe.mob.name), NOTABLE[foe.mob.classification],
                foe.n > 0 and L["slain x%d"]:format(foe.n) or L["not slain"]))
        end
    end
    if #mobs > 0 then
        table.sort(mobs, function(first, second) return first.n > second.n end)
        doc:Heading(L["Most hunted here"])
        for i = 1, math.min(#mobs, 12) do
            doc:Line(string.format("%s  x%d", UI.MobLink(mobs[i].id, mobs[i].name), mobs[i].n))
        end
    end

    if #deaths > 0 then
        doc:Heading(L["Fallen here"])
        for _, death in ipairs(deaths) do
            doc:Line(string.format(L["%s at level %d, %s"], death.killer and L["Slain by %s"]:format(death.killer) or L["Died"],
                death.level or 0, ns.Date(death.time)), UI.ACCENT)
        end
    end
    doc:Finish()
end
