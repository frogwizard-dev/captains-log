local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Fishing"], color = { 0.16, 0.42, 0.56 }, order = 5.5 }
ns.Pages.fishing = Page

-- What you've fished up (Fishing.lua), two ways: each kind of catch, or each spot you've
-- fished from. Your skill sits along the foot of the left page; click it for the milestones.

local STRIP_H = 52
local LIST_MAX = 15
local TIERS = { { 75, L["Apprentice"] }, { 150, L["Journeyman"] }, { 225, L["Expert"] }, { 300, L["Artisan"] } }
local ICON = "|T%s:16:16:0:0:64:64:5:59:5:59|t "

-- A catch's name in its quality's colour, re-inked where white and grey vanish on parchment.
local function Colored(name, quality)
    if quality == 0 then return "|cff6b5d4f" .. name .. "|r" end
    if not quality or quality == 1 then return "|cff2e1d0c" .. name .. "|r" end
    local QualityColor = C_Item.GetItemQualityColor or GetItemQualityColor
    local r, g, b
    if QualityColor then r, g, b = QualityColor(quality) end
    if not r then return name end
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
end

local function CatchName(id, catch)
    return (catch and catch.name) or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or L["Item #%s"]:format(id)
end

-- The item link, for its tooltip; made by hand when the item isn't cached.
local function CatchLink(id, catch)
    return (catch and catch.link) or select(2, C_Item.GetItemInfo(id))
        or string.format("|cff2e1d0c|Hitem:%d|h[%s]|h|r", id, CatchName(id, catch))
end

-- "a" or "an" before a name.
local function Article(name)
    return name:match("^[AEIOUaeiou]") and L["an "] or L["a "]
end

-- "Auberdine, Darkshore": the spot as a link to its page here, the land to its page in Lands.
local function SpotWhere(zone, place)
    if place == zone then return UI.FishSpotLink(zone, place) end
    return UI.FishSpotLink(zone, place) .. ", " .. UI.ZoneLink(zone)
end

local function Plural(count, one, many)
    return count == 1 and one or many
end

local function Tier(maxRank)
    for _, tier in ipairs(TIERS) do
        if maxRank and maxRank <= tier[1] then return tier[2] end
    end
end

-- "8 from pools, 4 in open water" (whichever are known), or nil.
local function PoolText(pools, water)
    local parts = {}
    if (pools or 0) > 0 then parts[#parts + 1] = string.format(Plural(pools, L["%d from a pool"], L["%d from pools"]), pools) end
    if (water or 0) > 0 then parts[#parts + 1] = L["%d in open water"]:format(water) end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.view, self.query = "catches", ""
    self.subtitle = ns.Book:Header(left, L["Fishing"])

    -- Each kind of catch, or each spot fished from.
    self.viewButtons = {}
    for i, view in ipairs({ { "catches", L["Catches"] }, { "spots", L["Spots"] } }) do
        local button = UI.Button(left, view[2], 90)
        button:SetPoint("TOPLEFT", (i - 1) * 96, -62)
        button:SetScript("OnClick", function()
            if self.view ~= view[1] then
                self.view = view[1]
                if self.selected ~= "skill" then self.selected = nil end
            end
            self:Render()
        end)
        self.viewButtons[view[1]] = button
    end
    local search = UI.SearchBox(left, 180, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPRIGHT", -2, -63)
    self.search = search

    self.list = UI.List(left, width, height - 94 - STRIP_H)
    self.list.scroll:SetPoint("TOPLEFT", 0, -94)
    self:BuildSkillStrip(left, width)

    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
end

-- Your skill along the foot of the left page: a line of text and a bar to 300, with a mark
-- where your training stops. Clicking it opens the skill and its milestones.
function Page:BuildSkillStrip(left, width)
    local strip = CreateFrame("Button", nil, left)
    strip:SetPoint("BOTTOMLEFT")
    strip:SetPoint("BOTTOMRIGHT")
    strip:SetHeight(STRIP_H - 6)
    local rule = strip:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.4)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("TOPRIGHT")
    local highlight = strip:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
    strip:SetHighlightTexture(highlight)
    strip.sel = strip:CreateTexture(nil, "BACKGROUND")
    strip.sel:SetAllPoints()
    strip.sel:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.15)

    strip.label = UI.Text(strip, 14, UI.ACCENT, UI.HEADING_FONT)
    strip.label:SetPoint("TOPLEFT", 4, -7)
    strip.more = UI.Text(strip, 11, UI.LINK_BLUE)
    strip.more:SetPoint("TOPRIGHT", -4, -9)
    strip.more:SetText(L["Milestones"])

    strip.barW = width - 8
    strip.track = strip:CreateTexture(nil, "ARTWORK")
    strip.track:SetPoint("BOTTOMLEFT", 4, 8)
    strip.track:SetSize(strip.barW, 6)
    strip.track:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.12)
    strip.fill = strip:CreateTexture(nil, "ARTWORK", nil, 1)
    strip.fill:SetPoint("TOPLEFT", strip.track)
    strip.fill:SetHeight(6)
    strip.fill:SetColorTexture(0.16, 0.42, 0.56, 0.85)
    strip.cap = strip:CreateTexture(nil, "ARTWORK", nil, 2)
    strip.cap:SetSize(2, 10)
    strip.cap:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.9)

    strip:SetScript("OnClick", function()
        self.selected = "skill"
        self:Render()
    end)
    self.strip = strip
end

function Page:RenderSkillStrip()
    local strip = self.strip
    local rank, maxRank, modifier = ns.FishingSkill()
    strip.sel:SetShown(self.selected == "skill")
    if not rank then
        strip.label:SetText(L["Fishing not yet learned"])
        strip.fill:Hide()
        strip.cap:Hide()
        return
    end
    local bonus = (modifier and modifier > 0) and L["  |cff6b5d4f(+%d)|r"]:format(modifier) or ""
    strip.label:SetText(string.format(L["Fishing skill %d / %d%s"], rank, maxRank or 300, bonus))
    strip.fill:SetWidth(math.max(1, strip.barW * math.min(rank, 300) / 300))
    strip.fill:Show()
    if maxRank and maxRank < 300 then
        strip.cap:ClearAllPoints()
        strip.cap:SetPoint("CENTER", strip.track, "LEFT", strip.barW * maxRank / 300, 0)
        strip.cap:Show()
    else
        strip.cap:Hide()
    end
end

-- Arriving by a link or a map pin: an item ID opens its catch, "skill" the skill, and a spot's
-- key that spot.
function Page:Reveal(selected)
    if type(selected) == "number" then
        self.view = "catches"
    elseif selected ~= "skill" then
        self.view = "spots"
    end
    self.selected = selected
    if self.list then self.list.revealKey = selected end
end

function Page:Render()
    local journal = ns.FishingJournal()
    local kinds = 0
    for _ in pairs(journal.items) do kinds = kinds + 1 end
    local summary = (journal.n or 0) > 0
        and string.format(Plural(kinds, L["%s fish caught  ·  %d kind"], L["%s fish caught  ·  %d kinds"]), ns.Number(journal.n), kinds)
        or L["Nothing caught yet"]
    if not ns.db.settings.fishing then summary = summary .. L["  ·  not recording (see Settings)"] end
    self.subtitle:SetText(summary)
    for view, button in pairs(self.viewButtons) do
        if view == self.view then button:LockHighlight() else button:UnlockHighlight() end
    end

    if self.view == "spots" then self:RenderSpotList() else self:RenderCatchList() end
    self:RenderSkillStrip()

    local selected = self.selected
    if selected == "skill" then
        self:RenderSkill()
    elseif type(selected) == "number" then
        self:RenderCatch(selected)
    elseif selected then
        self:RenderSpot(selected)
    else
        self:RenderEmpty()
    end
end

------------------------------------------------------------------------------
-- The lists
------------------------------------------------------------------------------

function Page:RenderCatchList()
    local items = ns.FishingJournal().items
    local entries = {}
    for id, catch in pairs(items) do
        local name = CatchName(id, catch)
        if self.query == "" or name:lower():find(self.query, 1, true) then
            entries[#entries + 1] = { id = id, catch = catch, name = name }
        end
    end
    -- Most caught first.
    table.sort(entries, function(first, second)
        if first.catch.n ~= second.catch.n then return first.catch.n > second.catch.n end
        return first.name < second.name
    end)
    if self.selected ~= "skill" and not (type(self.selected) == "number" and items[self.selected]) then
        self.selected = entries[1] and entries[1].id
    end
    local rows = {}
    for _, entry in ipairs(entries) do
        rows[#rows + 1] = {
            key = entry.id,
            left = (entry.catch.icon and ICON:format(entry.catch.icon) or "") .. Colored(entry.name, entry.catch.quality),
            right = "x" .. ns.Number(entry.catch.n),
        }
    end
    self.list:SetItems(rows, self.selected, function(id)
        self.selected = id
        self:Render()
    end)
end

-- A spot matches on its land, its place, or anything caught there.
local function SpotMatches(zone, place, spot, query)
    if query == "" or zone:lower():find(query, 1, true) or place:lower():find(query, 1, true) then return true end
    local items = ns.FishingJournal().items
    for id in pairs(spot.items) do
        if CatchName(id, items[id]):lower():find(query, 1, true) then return true end
    end
    return false
end

-- Lands in alphabetical order as headings, their spots beneath, most fished first.
function Page:RenderSpotList()
    local lands = {}
    for zone, places in pairs(ns.FishingJournal().spots) do
        local list, total = {}, 0
        for place, spot in pairs(places) do
            if SpotMatches(zone, place, spot, self.query) then
                list[#list + 1] = { place = place, spot = spot }
                total = total + spot.n
            end
        end
        if #list > 0 then
            table.sort(list, function(first, second) return first.spot.n > second.spot.n end)
            lands[#lands + 1] = { zone = zone, list = list, total = total }
        end
    end
    table.sort(lands, function(first, second) return first.zone < second.zone end)

    local rows, firstKey = {}, nil
    for _, land in ipairs(lands) do
        rows[#rows + 1] = { key = "land:" .. land.zone, left = land.zone, right = "x" .. ns.Number(land.total), header = true }
        for _, entry in ipairs(land.list) do
            local key = ns.FishSpotKey(land.zone, entry.place)
            firstKey = firstKey or key
            rows[#rows + 1] = {
                key = key, indent = 12,
                left = entry.place == land.zone and L["Elsewhere"] or entry.place,
                right = "x" .. ns.Number(entry.spot.n),
            }
        end
    end
    if self.selected ~= "skill" and not ns.FishSpot(self.selected) then self.selected = firstKey end
    self.list:SetItems(rows, self.selected, function(key)
        self.selected = key
        self:Render()
    end)
end

------------------------------------------------------------------------------
-- The right-hand page
------------------------------------------------------------------------------

function Page:RenderEmpty()
    local doc = self.doc
    doc:Clear("empty")
    ns.Book:BackLink(doc)
    self.title = nil
    if next(ns.FishingJournal().items) then
        doc:Title(L["Nothing matches"])
        doc:Faded(L["Clear the search to see all you've caught."])
    else
        doc:Title(L["An empty creel"])
        doc:Faded(L["Whatever you fish up is written here: what it was, where, and whether from a pool."])
        if not ns.db.settings.fishing then
            doc:Line(L["The fishing journal is switched off in Settings."], UI.ACCENT)
        end
    end
    doc:Finish()
end

-- Map dots for a spot's casting points (those on mapID), each saying how often you cast there.
local function SpotDots(spot, label, dots)
    for _, point in ipairs(spot.pts or {}) do
        local casts, pooled = point[3] or 1, point[4] or 0
        dots[#dots + 1] = { point[1], point[2], kind = pooled * 2 > casts and "pool" or "fish",
            label = string.format(Plural(casts, L["%s\nFished here %d time%s"], L["%s\nFished here %d times%s"]), label, casts,
                pooled > 0 and L[", %d into a pool"]:format(pooled) or "") }
    end
    return dots
end

local function Legend(dots)
    local kinds = {}
    for _, dot in ipairs(dots) do kinds[dot.kind] = true end
    local legend = {}
    if kinds.fish then legend[#legend + 1] = UI.Swatch("fish", L["where you fished"]) end
    if kinds.pool then legend[#legend + 1] = UI.Swatch("pool", L["mostly into pools"]) end
    return L["%s     (hover a spot)"]:format(table.concat(legend, "     "))
end

function Page:RenderCatch(id)
    local doc = self.doc
    doc:Clear("catch:" .. id)
    ns.Book:BackLink(doc)
    local journal = ns.FishingJournal()
    local catch = journal.items[id]
    if not catch then return self:RenderEmpty() end
    local name = CatchName(id, catch)
    self.title = name
    doc:Title(name)
    local quality = catch.quality and _G["ITEM_QUALITY" .. catch.quality .. "_DESC"]
    local _, itemType = C_Item.GetItemInfoInstant(id)
    local kind = strtrim((quality or "") .. ((quality and itemType) and ", " or "") .. (itemType or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Item(CatchLink(id, catch), nil, catch.icon)
    doc:Gap(2)

    doc:Line(string.format(Plural(catch.times, L["Caught %s in all, in %s catch; most recently %s."],
        L["Caught %s in all, in %s catches; most recently %s."]), ns.Number(catch.n), ns.Number(catch.times),
        ns.Ago(catch.last or catch.first.t)))
    local first = catch.first
    if first then
        local how = first.pool and L[", from a pool"] or (first.pool == false and L[", in open water"] or "")
        doc:Line(string.format(L["First caught on %s at %s%s%s."], ns.Date(first.t), SpotWhere(first.zone, first.place),
            how, first.skill and L[", at fishing skill %d"]:format(first.skill) or ""))
    end

    -- Every spot it's come from, most first.
    local places, pools, water = {}, 0, 0
    for zone, list in pairs(journal.spots) do
        for place, spot in pairs(list) do
            local tally = spot.items[id]
            if tally then
                places[#places + 1] = { zone = zone, place = place, spot = spot, tally = tally }
                pools, water = pools + (tally.p or 0), water + (tally.w or 0)
            end
        end
    end
    local poolText = PoolText(pools, water)
    if poolText then doc:Line(string.format(L["Of those, %s."], poolText)) end

    if #places > 0 then
        table.sort(places, function(first, second) return first.tally.n > second.tally.n end)
        doc:Heading(L["Where you've caught it"])
        for i = 1, math.min(#places, LIST_MAX) do
            local where = places[i]
            local share = where.spot.n > 0 and math.floor(where.tally.n / where.spot.n * 100 + 0.5) or 0
            local note = PoolText(where.tally.p, where.tally.w)
            doc:Line(string.format(L["%s  x%d  |cff6b5d4f%d%% of your catch there%s|r"], SpotWhere(where.zone, where.place),
                where.tally.n, share, note and ("; " .. note) or ""))
        end
        if #places > LIST_MAX then doc:Faded(string.format(L["...and %d more."], #places - LIST_MAX)) end

        -- The map with the most casts for it: every point on it you caught it from.
        local byMap = {}
        for _, where in ipairs(places) do
            if where.spot.mapID then byMap[where.spot.mapID] = (byMap[where.spot.mapID] or 0) + where.tally.n end
        end
        local bestMap
        for mapID, caught in pairs(byMap) do
            if not bestMap or caught > byMap[bestMap] then bestMap = mapID end
        end
        if bestMap then
            local dots = {}
            for _, where in ipairs(places) do
                if where.spot.mapID == bestMap then SpotDots(where.spot, ns.FishSpotName(where.zone, where.place), dots) end
            end
            local map = C_Map.GetMapInfo(bestMap)
            doc:Heading((map and map.name) and L["Where you've fished it up: %s"]:format(map.name) or L["Where you've fished it up"],
                UI.MapActions(function() ns.MapPins.Show("fish", id, bestMap) end, nil, nil, nil,
                    L["Pins every spot you've caught it to the game's map."]))
            doc:Faded(Legend(dots))
            doc:Map(bestMap, dots, { "fish", id })
        end
    end
    doc:Finish()
end

function Page:RenderSpot(key)
    local doc = self.doc
    doc:Clear("spot:" .. key)
    ns.Book:BackLink(doc)
    local spot, zone, place = ns.FishSpot(key)
    if not spot then return self:RenderEmpty() end
    self.title = ns.FishSpotName(zone, place)
    doc:Title(place)
    if place ~= zone then
        doc:Text(L["in %s"]:format(UI.ZoneLink(zone)), 11, UI.FADED, nil, 8)
    else
        doc:Faded(L["Away from any named place"])
    end
    doc:Gap(4)

    doc:Line(string.format(Plural(spot.casts, L["Fished here %d time since %s, most recently %s."],
        L["Fished here %d times since %s, most recently %s."]), spot.casts,
        ns.Date(spot.first), ns.Ago(spot.last or spot.first)))
    doc:Line(string.format(L["Caught %s in all."], ns.Number(spot.n)))
    if (spot.pool or 0) > 0 or (spot.water or 0) > 0 then
        doc:Line(string.format(Plural(spot.pool or 0, L["Cast into a pool %d time, into open water %d."],
            L["Cast into a pool %d times, into open water %d."]), spot.pool or 0, spot.water or 0))
    end

    -- What it gives, most first, with each catch's share of the haul.
    local items = ns.FishingJournal().items
    local catch = {}
    for id, tally in pairs(spot.items) do catch[#catch + 1] = { id = id, tally = tally } end
    table.sort(catch, function(first, second) return first.tally.n > second.tally.n end)
    if #catch > 0 then
        doc:Heading(Plural(#catch, L["Your catch here (%d kind)"], L["Your catch here (%d kinds)"]):format(#catch))
        for _, caught in ipairs(catch) do
            local share = spot.n > 0 and math.floor(caught.tally.n / spot.n * 100 + 0.5) or 0
            local entry = items[caught.id]
            doc:Item(CatchLink(caught.id, entry), string.format("x%d  (%d%%)", caught.tally.n, share),
                (entry and entry.icon) or C_Item.GetItemIconByID(caught.id))
        end
    end

    if spot.mapID and spot.pts and #spot.pts > 0 then
        -- The waypoint goes to where you cast from most.
        local best
        for _, point in ipairs(spot.pts) do
            if not best or (point[3] or 1) > (best[3] or 1) then best = point end
        end
        local dots = SpotDots(spot, self.title, {})
        doc:Heading(L["Where you cast from"], UI.MapActions(function() ns.MapPins.Show("fishspot", key, spot.mapID) end,
            spot.mapID, best[1], best[2], L["Pins the points you've cast from here to the game's map."]))
        doc:Faded(Legend(dots))
        doc:Map(spot.mapID, dots, { "fishspot", key })
    end

    -- The other places you've fished in this land.
    local others = {}
    for _, entry in ipairs(ns.FishingSpotsIn(zone)) do
        if entry.place ~= place then others[#others + 1] = entry end
    end
    if #others > 0 then
        doc:Heading(L["Elsewhere in %s"]:format(zone))
        for i = 1, math.min(#others, LIST_MAX) do
            local entry = others[i]
            local label = entry.place == zone and L["Away from any named place"] or entry.place
            doc:Line(string.format("%s  x%d", UI.FishSpotLink(zone, entry.place, label), entry.spot.n))
        end
    end
    doc:Finish()
end

function Page:RenderSkill()
    local doc = self.doc
    doc:Clear("skill")
    ns.Book:BackLink(doc)
    self.title = L["Fishing skill"]
    doc:Title(L["Fishing skill"])
    local journal = ns.FishingJournal()
    local rank, maxRank, modifier = ns.FishingSkill()
    if rank then
        local tier = Tier(maxRank)
        if tier then doc:Faded(L["%s fisherman"]:format(tier)) end
        doc:Gap(4)
        doc:Line(string.format(L["Your skill is %d of %d%s."], rank, maxRank or 300,
            (modifier and modifier > 0) and string.format(L[" (%d with your lure or gear)"], rank + modifier) or ""))
        if maxRank and rank >= maxRank and maxRank < 300 then
            doc:Line(L["That's as far as your training goes: learn the next rank of Fishing to keep improving."], UI.ACCENT)
        elseif rank < 300 then
            local nextMilestone = (math.floor(rank / 25) + 1) * 25
            doc:Line(string.format(L["Next milestone: %d (%d to go)."], nextMilestone, nextMilestone - rank))
        end
    else
        doc:Gap(4)
        doc:Line(L["You haven't learned Fishing yet. A fishing trainer will teach you; then cast a line wherever there's water."])
    end
    if (journal.n or 0) > 0 then
        doc:Line(string.format(Plural(journal.casts or 0, L["Fish caught: %s, in %s catch."], L["Fish caught: %s, in %s catches."]),
            ns.Number(journal.n), ns.Number(journal.casts or 0)))
    end
    if journal.since then
        doc:Faded(string.format(L["The book has watched your skill since %s, when it was %d."],
            ns.Date(journal.since.t), journal.since.skill))
    end

    -- Each 25 points: when, where, and the catch that did it.
    doc:Heading(L["Milestones"])
    local any = false
    for points = 25, 300, 25 do
        local milestone = journal.milestones[points]
        if milestone then
            any = true
            local where = milestone.zone and L[" in %s"]:format(UI.ZoneLink(milestone.zone)) or ""
            local with = ""
            if milestone.item then
                local name = CatchName(milestone.item, journal.items[milestone.item])
                with = L[", landing %s%s"]:format(Article(name), UI.FishLink(milestone.item, name))
            end
            local tier = (points % 75 == 0) and L["  |cff6b5d4fthe top of %s|r"]:format(TIERS[points / 75][2]) or ""
            doc:Line(string.format("|cff7a1f0d%d|r  %s%s%s%s", points, ns.Date(milestone.t), where, with, tier))
        end
    end
    if not any then
        doc:Faded(L["Each 25 points you gain from here on is written down: when, where, and the catch that did it."])
    end

    -- Your best waters.
    local spots = {}
    for zone, places in pairs(journal.spots) do
        for place, spot in pairs(places) do spots[#spots + 1] = { zone = zone, place = place, spot = spot } end
    end
    if #spots > 0 then
        table.sort(spots, function(first, second) return first.spot.n > second.spot.n end)
        doc:Heading(L["Your best waters"])
        for i = 1, math.min(#spots, 5) do
            local water = spots[i]
            doc:Line(string.format("%s  x%d", SpotWhere(water.zone, water.place), water.spot.n))
        end
    end
    doc:Finish()
end
