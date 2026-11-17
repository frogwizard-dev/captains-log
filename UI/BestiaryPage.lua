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
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sort, self.query = "name", ""
    self.subtitle = ns.Book:Header(left, L["Bestiary"])

    local search = UI.SearchBox(left, 190, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPLEFT", 6, -62)
    self.search = search
    local sort = UI.Dropdown(left, 170, SORTS, function() return self.sort end, function(sortKey)
        self.sort = sortKey
        self:Render()
    end)
    sort:SetPoint("TOPRIGHT", 0, -60)

    self.list = UI.List(left, width, height - 94)
    self.list.scroll:SetPoint("TOPLEFT", 0, -92)
    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
end

-- The field each sort looks at first, newest or most first; then by name.
local SORT_FIELDS = { kills = "kills", recent = "lastKill", first = "firstSeen" }

local function Sorter(sortKey)
    local field = SORT_FIELDS[sortKey]
    return function(first, second)
        local firstMob, secondMob = first.mob, second.mob
        if field and (firstMob[field] or 0) ~= (secondMob[field] or 0) then
            return (firstMob[field] or 0) > (secondMob[field] or 0)
        end
        return (firstMob.name or "") < (secondMob.name or "")
    end
end

function Page:Render()
    ns.FillNames()
    local entries, total = {}, 0
    for id, mob in pairs(ns.db.mobs) do
        total = total + 1
        local name = mob.name or L["Unknown creature #%s"]:format(tostring(id))
        if self.query == "" or name:lower():find(self.query, 1, true) then
            entries[#entries + 1] = { id = id, mob = mob, name = name }
        end
    end
    table.sort(entries, Sorter(self.sort))
    self.subtitle:SetText(L["%s creatures recorded"]:format(total))

    if not self.selected or not ns.db.mobs[self.selected] then
        self.selected = entries[1] and entries[1].id
    end

    local items = {}
    for _, entry in ipairs(entries) do
        items[#items + 1] = {
            key = entry.id,
            left = entry.name,
            right = entry.mob.kills > 0 and ("x" .. ns.Number(entry.mob.kills)) or L["met"],
            color = CLASS_COLOR[entry.mob.classification],
        }
    end
    self.list:SetItems(items, self.selected, function(id)
        self.selected = id
        self:Render()
    end)

    self:RenderMob(self.selected)
end

local function LevelText(mob)
    if not mob.minLevel then return "" end
    if mob.minLevel == mob.maxLevel then return L["Level %s"]:format(mob.minLevel) end
    return L["Level %s-%s"]:format(mob.minLevel, mob.maxLevel)
end

function Page:RenderMob(id)
    local doc = self.doc
    doc:Clear("mob:" .. tostring(id))
    ns.Book:BackLink(doc)
    local mob = id and ns.db.mobs[id]
    if not mob then
        self.title = nil
        doc:Title(L["An empty bestiary"])
        doc:Faded(L["Creatures appear here the first time you meet them."])
        doc:Finish()
        return
    end

    self.title = mob.name or L["Unknown creature #%s"]:format(tostring(id))
    doc:Title(self.title)
    local kind = strtrim(string.format("%s %s %s", LevelText(mob),
        CLASSIFICATION[mob.classification] or "", mob.creatureType or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Gap(4)

    if mob.firstSeen then
        doc:Line(string.format(L["First met on %s%s, when you were level %d."], ns.Date(mob.firstSeen),
            mob.firstZone and L[" in %s"]:format(UI.ZoneLink(mob.firstZone)) or "", mob.firstLevel or 0))
    end
    if mob.kills > 0 then
        doc:Line(string.format(L["Slain %s %s, most recently %s."], ns.Number(mob.kills),
            mob.kills == 1 and L["time"] or L["times"], ns.Ago(mob.lastKill)))
    else
        doc:Line(L["Never slain."])
    end
    if mob.killedMe > 0 then
        doc:Line(string.format(L["Has killed you %d %s."], mob.killedMe, mob.killedMe == 1 and L["time"] or L["times"]), UI.ACCENT)
    end

    -- Quests that want this creature dead (or something it carries). Those in progress sit up
    -- here; finished and abandoned ones are kept as a faded record at the very bottom.
    local active, past = {}, {}
    for _, wanted in ipairs(ns.MobQuests(id)) do
        table.insert((wanted.q.completed or wanted.q.abandoned) and past or active, wanted)
    end
    if #active > 0 then
        doc:Heading(L["Wanted for"])
        for _, wanted in ipairs(active) do
            local forItem = wanted.item and ("  |cff6b5d4f" .. L["for its %s"]:format(wanted.item) .. "|r") or ""
            doc:Check(UI.QuestLink(wanted.questID) .. forItem, nil, UI.INK)
        end
    end

    local battle = ns.CombatLines(mob)
    if #battle > 0 then
        doc:Heading(L["In battle"])
        for _, line in ipairs(battle) do doc:Line(line) end
    end

    local zones = {}
    for zone, kills in pairs(mob.zones) do zones[#zones + 1] = { zone = zone, n = kills } end
    if #zones > 0 then
        table.sort(zones, function(first, second) return first.n > second.n end)
        doc:Heading(L["Hunting grounds"])
        for _, ground in ipairs(zones) do doc:Line(string.format("%s  x%d", UI.ZoneLink(ground.zone), ground.n)) end
    end

    -- Map of the zone where you've killed it most, a dot per kill (latest 60).
    local bestMap, bestSpots
    for mapID, spots in pairs(mob.spots or {}) do
        if not bestSpots or #spots > #bestSpots then bestMap, bestSpots = mapID, spots end
    end
    if bestMap then
        local map = C_Map.GetMapInfo(bestMap)
        local zone = map and map.name
        doc:Heading(zone and L["Where you've slain it: %s"]:format(zone) or L["Where you've slain it"],
            UI.MapActions(function() ns.MapPins.Show("mob", id, bestMap) end, nil, nil, nil,
                L["Pins every spot you've slain it to the game's map."]))
        doc:Gap(2)
        doc:Map(bestMap, bestSpots, { "mob", id })
    end

    local drops = {}
    for itemID, drop in pairs(mob.drops) do drops[#drops + 1] = { itemID = itemID, drop = drop } end
    if #drops > 0 then
        table.sort(drops, function(first, second) return first.drop.times > second.drop.times end)
        doc:Heading(string.format(L["Spoils (from %d %s looted)"], mob.looted, mob.looted == 1 and L["corpse"] or L["corpses"]))
        for _, entry in ipairs(drops) do
            -- "x3  (66%, 2/3)": total taken, then how many corpses it dropped from.
            local drop = entry.drop
            local rate = mob.looted > 0 and math.floor(drop.times / mob.looted * 100) or 0
            local link = drop.link or select(2, C_Item.GetItemInfo(entry.itemID))
            doc:Item(link, string.format("x%d  (%d%%, %d/%d)", drop.qty, rate, drop.times, mob.looted),
                C_Item.GetItemIconByID(entry.itemID))
        end
    elseif mob.looted > 0 then
        doc:Heading(L["Spoils"])
        doc:Faded(string.format(L["Looted %d %s; nothing but coin so far."], mob.looted, mob.looted == 1 and L["time"] or L["times"]))
    end

    if #past > 0 then
        doc:Heading(L["Once wanted for"])
        for _, wanted in ipairs(past) do
            local status = wanted.q.completed and L["done %s"]:format(ns.Date(wanted.q.completed)) or L["abandoned"]
            doc:Text(UI.QuestLink(wanted.questID) .. "  |cff6b5d4f" .. status .. "|r", 11, UI.FADED, nil, 8)
        end
    end
    doc:Finish()
end
