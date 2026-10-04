local _, ns = ...
local UI = ns.UI

local Page = { label = "Fishing", color = { 0.16, 0.42, 0.56 }, order = 5.5 }
ns.Pages.fishing = Page

-- What you've fished up (Fishing.lua), two ways: each kind of catch, or each spot you've
-- fished from. Your skill sits along the foot of the left page; click it for the milestones.

local STRIP_H = 52
local LIST_MAX = 15
local TIERS = { { 75, "Apprentice" }, { 150, "Journeyman" }, { 225, "Expert" }, { 300, "Artisan" } }
local ICON = "|T%s:16:16:0:0:64:64:5:59:5:59|t "

-- A catch's name in its quality's colour, re-inked where white and grey vanish on parchment.
local function Colored(name, quality)
    if quality == 0 then return "|cff6b5d4f" .. name .. "|r" end
    if not quality or quality == 1 then return "|cff2e1d0c" .. name .. "|r" end
    local fn = C_Item.GetItemQualityColor or GetItemQualityColor
    local r, g, b
    if fn then r, g, b = fn(quality) end
    if not r then return name end
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
end

local function CatchName(id, e)
    return (e and e.name) or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("Item #" .. id)
end

-- The item link, for its tooltip; made by hand when the item isn't cached.
local function CatchLink(id, e)
    return (e and e.link) or select(2, C_Item.GetItemInfo(id))
        or string.format("|cff2e1d0c|Hitem:%d|h[%s]|h|r", id, CatchName(id, e))
end

-- "a" or "an" before a name.
local function Article(name)
    return name:match("^[AEIOUaeiou]") and "an " or "a "
end

-- "Auberdine, Darkshore": the spot as a link to its page here, the land to its page in Lands.
local function SpotWhere(zone, place)
    if place == zone then return UI.FishSpotLink(zone, place) end
    return UI.FishSpotLink(zone, place) .. ", " .. UI.ZoneLink(zone)
end

local function Plural(n, one, many)
    return n == 1 and one or many
end

local function Tier(maxRank)
    for _, t in ipairs(TIERS) do
        if maxRank and maxRank <= t[1] then return t[2] end
    end
end

-- "8 from pools, 4 in open water" (whichever are known), or nil.
local function PoolText(p, w)
    local parts = {}
    if (p or 0) > 0 then parts[#parts + 1] = p .. " from " .. Plural(p, "a pool", "pools") end
    if (w or 0) > 0 then parts[#parts + 1] = w .. " in open water" end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.view, self.query = "catches", ""
    self.sub = ns.Book:Header(left, "Fishing")

    -- Each kind of catch, or each spot fished from.
    self.viewButtons = {}
    for i, v in ipairs({ { "catches", "Catches" }, { "spots", "Spots" } }) do
        local b = UI.Button(left, v[2], 90)
        b:SetPoint("TOPLEFT", (i - 1) * 96, -62)
        b:SetScript("OnClick", function()
            if self.view ~= v[1] then
                self.view = v[1]
                if self.selected ~= "skill" then self.selected = nil end
            end
            self:Render()
        end)
        self.viewButtons[v[1]] = b
    end
    local search = UI.SearchBox(left, 180, function(text)
        self.query = text:lower()
        self:Render()
    end)
    search:SetPoint("TOPRIGHT", -2, -63)
    self.search = search

    self.list = UI.List(left, W, H - 94 - STRIP_H)
    self.list.sf:SetPoint("TOPLEFT", 0, -94)
    self:BuildSkillStrip(left, W)

    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
end

-- Your skill along the foot of the left page: a line of text and a bar to 300, with a mark
-- where your training stops. Clicking it opens the skill and its milestones.
function Page:BuildSkillStrip(left, W)
    local strip = CreateFrame("Button", nil, left)
    strip:SetPoint("BOTTOMLEFT")
    strip:SetPoint("BOTTOMRIGHT")
    strip:SetHeight(STRIP_H - 6)
    local rule = strip:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.4)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("TOPRIGHT")
    local hl = strip:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
    strip:SetHighlightTexture(hl)
    strip.sel = strip:CreateTexture(nil, "BACKGROUND")
    strip.sel:SetAllPoints()
    strip.sel:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.15)

    strip.label = UI.Text(strip, 14, UI.ACCENT, UI.HEADING_FONT)
    strip.label:SetPoint("TOPLEFT", 4, -7)
    strip.more = UI.Text(strip, 11, { 0.11, 0.31, 0.55 })
    strip.more:SetPoint("TOPRIGHT", -4, -9)
    strip.more:SetText("Milestones")

    strip.barW = W - 8
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
        strip.label:SetText("Fishing not yet learned")
        strip.fill:Hide()
        strip.cap:Hide()
        return
    end
    local bonus = (modifier and modifier > 0) and ("  |cff6b5d4f(+" .. modifier .. ")|r") or ""
    strip.label:SetText(string.format("Fishing skill %d / %d%s", rank, maxRank or 300, bonus))
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
function Page:Reveal(sel)
    if type(sel) == "number" then
        self.view = "catches"
    elseif sel ~= "skill" then
        self.view = "spots"
    end
    self.selected = sel
    if self.list then self.list.revealKey = sel end
end

function Page:Render()
    local f = ns.FishingData()
    local kinds = 0
    for _ in pairs(f.items) do kinds = kinds + 1 end
    local sub = (f.n or 0) > 0
        and string.format("%s fish caught  ·  %d %s", ns.Number(f.n), kinds, Plural(kinds, "kind", "kinds"))
        or "Nothing caught yet"
    if not ns.db.settings.fishing then sub = sub .. "  ·  not recording (see Settings)" end
    self.sub:SetText(sub)
    for view, b in pairs(self.viewButtons) do
        if view == self.view then b:LockHighlight() else b:UnlockHighlight() end
    end

    if self.view == "spots" then self:RenderSpotList() else self:RenderCatchList() end
    self:RenderSkillStrip()

    local sel = self.selected
    if sel == "skill" then
        self:RenderSkill()
    elseif type(sel) == "number" then
        self:RenderCatch(sel)
    elseif sel then
        self:RenderSpot(sel)
    else
        self:RenderEmpty()
    end
end

------------------------------------------------------------------------------
-- The lists
------------------------------------------------------------------------------

function Page:RenderCatchList()
    local items = ns.FishingData().items
    local entries = {}
    for id, e in pairs(items) do
        local name = CatchName(id, e)
        if self.query == "" or name:lower():find(self.query, 1, true) then
            entries[#entries + 1] = { id = id, e = e, name = name }
        end
    end
    -- Most caught first.
    table.sort(entries, function(a, b)
        if a.e.n ~= b.e.n then return a.e.n > b.e.n end
        return a.name < b.name
    end)
    if self.selected ~= "skill" and not (type(self.selected) == "number" and items[self.selected]) then
        self.selected = entries[1] and entries[1].id
    end
    local rows = {}
    for _, en in ipairs(entries) do
        rows[#rows + 1] = {
            key = en.id,
            left = (en.e.icon and ICON:format(en.e.icon) or "") .. Colored(en.name, en.e.quality),
            right = "x" .. ns.Number(en.e.n),
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
    local items = ns.FishingData().items
    for id in pairs(spot.items) do
        if CatchName(id, items[id]):lower():find(query, 1, true) then return true end
    end
    return false
end

-- Lands in alphabetical order as headings, their spots beneath, most fished first.
function Page:RenderSpotList()
    local zones = {}
    for zone, places in pairs(ns.FishingData().spots) do
        local list, total = {}, 0
        for place, spot in pairs(places) do
            if SpotMatches(zone, place, spot, self.query) then
                list[#list + 1] = { place = place, spot = spot }
                total = total + spot.n
            end
        end
        if #list > 0 then
            table.sort(list, function(a, b) return a.spot.n > b.spot.n end)
            zones[#zones + 1] = { zone = zone, list = list, total = total }
        end
    end
    table.sort(zones, function(a, b) return a.zone < b.zone end)

    local rows, first = {}, nil
    for _, z in ipairs(zones) do
        rows[#rows + 1] = { key = "land:" .. z.zone, left = z.zone, right = "x" .. ns.Number(z.total), header = true }
        for _, e in ipairs(z.list) do
            local key = ns.FishSpotKey(z.zone, e.place)
            first = first or key
            rows[#rows + 1] = {
                key = key, indent = 12,
                left = e.place == z.zone and "Elsewhere" or e.place,
                right = "x" .. ns.Number(e.spot.n),
            }
        end
    end
    if self.selected ~= "skill" and not ns.FishSpot(self.selected) then self.selected = first end
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
    if next(ns.FishingData().items) then
        doc:Title("Nothing matches")
        doc:Faded("Clear the search to see all you've caught.")
    else
        doc:Title("An empty creel")
        doc:Faded("Whatever you fish up is written here: what it was, where, and whether from a pool.")
        if not ns.db.settings.fishing then
            doc:Line("The fishing journal is switched off in Settings.", UI.ACCENT)
        end
    end
    doc:Finish()
end

-- Map dots for a spot's casting points (those on mapID), each saying how often you cast there.
local function SpotDots(spot, label, dots)
    for _, p in ipairs(spot.pts or {}) do
        local casts, pooled = p[3] or 1, p[4] or 0
        dots[#dots + 1] = { p[1], p[2], kind = pooled * 2 > casts and "pool" or "fish",
            label = string.format("%s\nFished here %d %s%s", label, casts, Plural(casts, "time", "times"),
                pooled > 0 and (", " .. pooled .. " into a pool") or "") }
    end
    return dots
end

local function Legend(dots)
    local kinds = {}
    for _, d in ipairs(dots) do kinds[d.kind] = true end
    local legend = {}
    if kinds.fish then legend[#legend + 1] = UI.Swatch("fish", "where you fished") end
    if kinds.pool then legend[#legend + 1] = UI.Swatch("pool", "mostly into pools") end
    return table.concat(legend, "     ") .. "     (hover a spot)"
end

function Page:RenderCatch(id)
    local doc = self.doc
    doc:Clear("catch:" .. id)
    ns.Book:BackLink(doc)
    local f = ns.FishingData()
    local e = f.items[id]
    if not e then return self:RenderEmpty() end
    local name = CatchName(id, e)
    self.title = name
    doc:Title(name)
    local quality = e.quality and _G["ITEM_QUALITY" .. e.quality .. "_DESC"]
    local _, itemType = C_Item.GetItemInfoInstant(id)
    local kind = strtrim((quality or "") .. ((quality and itemType) and ", " or "") .. (itemType or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Item(CatchLink(id, e), nil, e.icon)
    doc:Gap(2)

    doc:Line(string.format("Caught %s in all, in %s %s; most recently %s.", ns.Number(e.n), ns.Number(e.times),
        Plural(e.times, "catch", "catches"), ns.Ago(e.last or e.first.t)))
    local first = e.first
    if first then
        local how = first.pool and ", from a pool" or (first.pool == false and ", in open water" or "")
        doc:Line(string.format("First caught on %s at %s%s%s.", ns.Date(first.t), SpotWhere(first.zone, first.place),
            how, first.skill and (", at fishing skill " .. first.skill) or ""))
    end

    -- Every spot it's come from, most first.
    local places, pools, water = {}, 0, 0
    for zone, list in pairs(f.spots) do
        for place, spot in pairs(list) do
            local s = spot.items[id]
            if s then
                places[#places + 1] = { zone = zone, place = place, spot = spot, s = s }
                pools, water = pools + (s.p or 0), water + (s.w or 0)
            end
        end
    end
    local pt = PoolText(pools, water)
    if pt then doc:Line(string.format("Of those, %s.", pt)) end

    if #places > 0 then
        table.sort(places, function(a, b) return a.s.n > b.s.n end)
        doc:Heading("Where you've caught it")
        for i = 1, math.min(#places, LIST_MAX) do
            local p = places[i]
            local share = p.spot.n > 0 and math.floor(p.s.n / p.spot.n * 100 + 0.5) or 0
            local note = PoolText(p.s.p, p.s.w)
            doc:Line(string.format("%s  x%d  |cff6b5d4f%d%% of your catch there%s|r", SpotWhere(p.zone, p.place),
                p.s.n, share, note and ("; " .. note) or ""))
        end
        if #places > LIST_MAX then doc:Faded(string.format("...and %d more.", #places - LIST_MAX)) end

        -- The map with the most casts for it: every point on it you caught it from.
        local byMap = {}
        for _, p in ipairs(places) do
            if p.spot.mapID then byMap[p.spot.mapID] = (byMap[p.spot.mapID] or 0) + p.s.n end
        end
        local bestMap
        for mapID, n in pairs(byMap) do
            if not bestMap or n > byMap[bestMap] then bestMap = mapID end
        end
        if bestMap then
            local dots = {}
            for _, p in ipairs(places) do
                if p.spot.mapID == bestMap then SpotDots(p.spot, ns.FishSpotName(p.zone, p.place), dots) end
            end
            local info = C_Map.GetMapInfo(bestMap)
            doc:Heading("Where you've fished it up" .. (info and info.name and (" - " .. info.name) or ""),
                UI.MapActions(function() ns.MapPins.Show("fish", id, bestMap) end, nil, nil, nil,
                    "Pins every spot you've caught it to the game's map."))
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
        doc:Text("in " .. UI.ZoneLink(zone), 11, UI.FADED, nil, 8)
    else
        doc:Faded("Away from any named place")
    end
    doc:Gap(4)

    doc:Line(string.format("Fished here %d %s since %s, most recently %s.", spot.casts, Plural(spot.casts, "time", "times"),
        ns.Date(spot.first), ns.Ago(spot.last or spot.first)))
    doc:Line(string.format("Caught %s in all.", ns.Number(spot.n)))
    if (spot.pool or 0) > 0 or (spot.water or 0) > 0 then
        doc:Line(string.format("Cast into a pool %d %s, into open water %d.", spot.pool or 0,
            Plural(spot.pool or 0, "time", "times"), spot.water or 0))
    end

    -- What it gives, most first, with each catch's share of the haul.
    local items = ns.FishingData().items
    local catch = {}
    for id, s in pairs(spot.items) do catch[#catch + 1] = { id = id, s = s } end
    table.sort(catch, function(a, b) return a.s.n > b.s.n end)
    if #catch > 0 then
        doc:Heading("Your catch here (" .. #catch .. Plural(#catch, " kind)", " kinds)"))
        for _, c in ipairs(catch) do
            local share = spot.n > 0 and math.floor(c.s.n / spot.n * 100 + 0.5) or 0
            local e = items[c.id]
            doc:Item(CatchLink(c.id, e), string.format("x%d  (%d%%)", c.s.n, share),
                (e and e.icon) or C_Item.GetItemIconByID(c.id))
        end
    end

    if spot.mapID and spot.pts and #spot.pts > 0 then
        -- The waypoint goes to where you cast from most.
        local best
        for _, p in ipairs(spot.pts) do
            if not best or (p[3] or 1) > (best[3] or 1) then best = p end
        end
        local dots = SpotDots(spot, self.title, {})
        doc:Heading("Where you cast from", UI.MapActions(function() ns.MapPins.Show("fishspot", key, spot.mapID) end,
            spot.mapID, best[1], best[2], "Pins the points you've cast from here to the game's map."))
        doc:Faded(Legend(dots))
        doc:Map(spot.mapID, dots, { "fishspot", key })
    end

    -- The other places you've fished in this land.
    local others = {}
    for _, e in ipairs(ns.FishingSpotsIn(zone)) do
        if e.place ~= place then others[#others + 1] = e end
    end
    if #others > 0 then
        doc:Heading("Elsewhere in " .. zone)
        for i = 1, math.min(#others, LIST_MAX) do
            local e = others[i]
            doc:Line(string.format("%s  x%d", UI.FishSpotLink(zone, e.place, e.place == zone and "Away from any named place" or e.place), e.spot.n))
        end
    end
    doc:Finish()
end

function Page:RenderSkill()
    local doc = self.doc
    doc:Clear("skill")
    ns.Book:BackLink(doc)
    self.title = "Fishing skill"
    doc:Title("Fishing skill")
    local f = ns.FishingData()
    local rank, maxRank, modifier = ns.FishingSkill()
    if rank then
        local tier = Tier(maxRank)
        if tier then doc:Faded(tier .. " fisherman") end
        doc:Gap(4)
        doc:Line(string.format("Your skill is %d of %d%s.", rank, maxRank or 300,
            (modifier and modifier > 0) and string.format(" (%d with your lure or gear)", rank + modifier) or ""))
        if maxRank and rank >= maxRank and maxRank < 300 then
            doc:Line("That's as far as your training goes: learn the next rank of Fishing to keep improving.", UI.ACCENT)
        elseif rank < 300 then
            local nextM = (math.floor(rank / 25) + 1) * 25
            doc:Line(string.format("Next milestone: %d (%d to go).", nextM, nextM - rank))
        end
    else
        doc:Gap(4)
        doc:Line("You haven't learned Fishing yet. A fishing trainer will teach you; then cast a line wherever there's water.")
    end
    if (f.n or 0) > 0 then
        doc:Line(string.format("Fish caught: %s, in %s %s.", ns.Number(f.n), ns.Number(f.casts or 0),
            Plural(f.casts or 0, "catch", "catches")))
    end
    if f.since then
        doc:Faded(string.format("The book has watched your skill since %s, when it was %d.", ns.Date(f.since.t), f.since.skill))
    end

    -- Each 25 points: when, where, and the catch that did it.
    doc:Heading("Milestones")
    local any = false
    for m = 25, 300, 25 do
        local ms = f.milestones[m]
        if ms then
            any = true
            local where = ms.zone and (" in " .. UI.ZoneLink(ms.zone)) or ""
            local with = ""
            if ms.item then
                local name = CatchName(ms.item, f.items[ms.item])
                with = ", landing " .. Article(name) .. UI.FishLink(ms.item, name)
            end
            local tier = (m % 75 == 0) and ("  |cff6b5d4fthe top of " .. TIERS[m / 75][2] .. "|r") or ""
            doc:Line(string.format("|cff7a1f0d%d|r  %s%s%s%s", m, ns.Date(ms.t), where, with, tier))
        end
    end
    if not any then
        doc:Faded("Each 25 points you gain from here on is written down: when, where, and the catch that did it.")
    end

    -- Your best waters.
    local spots = {}
    for zone, places in pairs(f.spots) do
        for place, spot in pairs(places) do spots[#spots + 1] = { zone = zone, place = place, spot = spot } end
    end
    if #spots > 0 then
        table.sort(spots, function(a, b) return a.spot.n > b.spot.n end)
        doc:Heading("Your best waters")
        for i = 1, math.min(#spots, 5) do
            local s = spots[i]
            doc:Line(string.format("%s  x%d", SpotWhere(s.zone, s.place), s.spot.n))
        end
    end
    doc:Finish()
end
