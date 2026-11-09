local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Character"], color = { 0.42, 0.30, 0.12 }, order = 1.5 }
ns.Pages.character = Page

-- You, as the book knows you: time played and how long each level took, where your time goes,
-- how far you've travelled, your other characters, and a snapshot of yourself at every level
-- (Played.lua, Journey.lua). Pick a line on the left; it's written out on the right.

local STATE_NAMES = {
    online = L["Online"], afk = L["Away"], combat = L["Fighting"], taxi = L["Flying"],
    dead = L["Dead or a ghost"], grouped = L["In a group"], resting = L["Resting"],
    mounted = L["Mounted"], swimming = L["Swimming"],
}
local MODE_NAMES = {
    foot = L["On foot"], mount = L["Mounted"], swim = L["Swimming"], taxi = L["By flight"], ghost = L["As a ghost"],
}
local MODE_COLOR = {
    foot = { 0.45, 0.32, 0.15 }, mount = { 0.50, 0.12, 0.05 }, swim = { 0.16, 0.40, 0.78 },
    taxi = { 0.30, 0.55, 0.20 }, ghost = { 0.45, 0.45, 0.55 },
}
local SLOTS = {
    "HEADSLOT", "NECKSLOT", "SHOULDERSLOT", "SHIRTSLOT", "CHESTSLOT", "WAISTSLOT", "LEGSSLOT", "FEETSLOT",
    "WRISTSLOT", "HANDSSLOT", "FINGER0SLOT", "FINGER1SLOT", "TRINKET0SLOT", "TRINKET1SLOT", "BACKSLOT",
    "MAINHANDSLOT", "SECONDARYHANDSLOT", "RANGEDSLOT", "TABARDSLOT",
}
local POWER = { [0] = "MANA", [1] = "RAGE", [2] = "FOCUS", [3] = "ENERGY" }

local function SlotName(slot)
    return (SLOTS[slot] and _G[SLOTS[slot]]) or L["Slot %d"]:format(slot)
end

local function StatName(i)
    return _G["SPELL_STAT" .. i .. "_NAME"] or ({ L["Strength"], L["Agility"], L["Stamina"], L["Intellect"], L["Spirit"] })[i]
end

-- /played now: the last reading plus the time since.
local function Played()
    local p = ns.db.played
    if not p or not p.total then return end
    local since = math.max(0, time() - (p.at or time()))
    return p.total + since, p.level and (p.level + since)
end

-- Levels the book has a record for, lowest first.
local function Levels()
    local list = {}
    for lvl, rec in pairs(ns.db.levels) do
        if type(lvl) == "number" and type(rec) == "table" then list[#list + 1] = lvl end
    end
    table.sort(list)
    return list
end

local function AveragePerLevel()
    local sum, n = 0, 0
    for _, rec in pairs(ns.db.levels) do
        if type(rec) == "table" and rec.spent then
            sum, n = sum + rec.spent, n + 1
        end
    end
    if n > 0 then return sum / n, n end
end

-- The clickable level in the book's text opens its snapshot here.
UI.RegisterLink("level", function(lvl)
    ns.Book:Goto("character", tonumber(lvl), true)
end, function(lvl)
    return L["Level %s"]:format(lvl), L["Click to see your gear, stats, talents and skills when you reached it."]
end)

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sub = ns.Book:Header(left, ns.FullName("player") or L["Character"])
    self.info = UI.Text(left, 12)
    self.info:SetPoint("TOPLEFT", 2, -62)
    self.info:SetWidth(W)
    self.info:SetSpacing(2)

    self.list = UI.List(left, W, H - 112)
    self.list.sf:SetPoint("TOPLEFT", 0, -112)

    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
    self.selected = "overview"
    self.model = self:BuildModel(self.doc.child, W)
end

-- You at a level, in the gear you had on then: a model of your character, undressed and dressed
-- in the snapshot's items, in the top corner of the page (it scrolls with it). Drag to turn it.
function Page:BuildModel(parent, W)
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, parent)
    if not ok or not m then return nil end
    m:SetSize(170, 270)
    m:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -36)
    m:EnableMouse(true)
    m:Hide()
    local facing = 0.35
    m:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
    m:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    m:SetScript("OnUpdate", function(self)
        if not self.dragX then return end
        local x = GetCursorPosition()
        facing = facing + (x - self.dragX) * 0.012
        self.dragX = x
        pcall(self.SetFacing, self, facing)
    end)
    m:SetScript("OnModelLoaded", function(self)
        pcall(self.SetFacing, self, facing)
        self:Dress()
    end)
    function m:Dress()
        local gear = self.gear
        if not gear then return end
        pcall(self.Undress, self)
        for slot, id in pairs(gear) do
            if slot ~= 0 and type(id) == "number" then pcall(self.TryOn, self, "item:" .. id) end
        end
    end
    function m:ShowGear(gear)
        self.gear = gear
        self:Show()
        if pcall(self.SetUnit, self, "player") then self:Dress() end
    end
    return m
end

function Page:Render()
    local cls = UnitClass("player")
    local race = UnitRace("player")
    local guild = GetGuildInfo and GetGuildInfo("player")
    if ns.issecret(guild) then guild = nil end
    local who = L["Level %d %s %s"]:format(UnitLevel("player"), race or "", cls or "")
    self.sub:SetText(guild and L["%s  ·  <%s>"]:format(who, guild) or who)

    local total, thisLevel = Played()
    local avg = AveragePerLevel()
    local lines = {}
    lines[#lines + 1] = total and L["Played %s, %s of it at this level."]:format(UI.LongDuration(total), ns.Duration(thisLevel or 0))
        or L["Time played isn't known yet."]
    if avg then lines[#lines + 1] = L["A level takes you %s on average."]:format(ns.Duration(avg)) end
    self.info:SetText(table.concat(lines, "\n"))

    local items = {
        { key = "overview", left = L["Your journey"] },
        { key = "time", left = L["Where your time goes"] },
        { key = "travel", left = L["Travel"] },
        { key = "roster", left = L["Your characters"] },
    }
    local levels = Levels()
    if #levels > 0 then items[#items + 1] = { header = true, left = L["Levels"] } end
    for i = #levels, 1, -1 do
        local lvl = levels[i]
        local rec = ns.db.levels[lvl]
        local when = rec.time and date(L["%d %b %Y"], rec.time) or ""
        local right = rec.spent and ns.Duration(rec.spent) or (lvl == UnitLevel("player") and L["now"] or "")
        items[#items + 1] = {
            key = lvl,
            left = L["Level %d"]:format(lvl) .. "  |cff6b5d4f" .. when .. "|r",
            right = right,
        }
    end
    if self.selected ~= "overview" and self.selected ~= "time" and self.selected ~= "travel" and self.selected ~= "roster"
        and not ns.db.levels[self.selected] then
        self.selected = "overview"
    end
    self.list:SetItems(items, self.selected, function(key)
        self.selected = key
        self:Render()
    end)

    local doc = self.doc
    doc:Clear("character:" .. tostring(self.selected))
    if self.model then self.model:Hide() end
    ns.Book:BackLink(doc)
    if self.selected == "time" then
        self:RenderTime(doc)
    elseif self.selected == "travel" then
        self:RenderTravel(doc)
    elseif self.selected == "roster" then
        self:RenderRoster(doc)
    elseif type(self.selected) == "number" then
        self:RenderLevel(doc, self.selected)
    else
        self:RenderOverview(doc, levels)
    end
    doc:Finish()
    self.title = type(self.selected) == "number" and L["Level %d"]:format(self.selected) or L["Character"]
end

------------------------------------------------------------------------------
-- Overview: played, the levels table, and the way to the journey map
------------------------------------------------------------------------------

function Page:RenderOverview(doc, levels)
    doc:Title(L["Your journey"])
    local total, thisLevel = Played()
    if total then
        doc:Line(L["Time played: %s"]:format(UI.LongDuration(total)))
        doc:Line(L["At this level: %s"]:format(ns.Duration(thisLevel or 0)))
    end
    local avg, n = AveragePerLevel()
    if avg then doc:Line(L["Average per level: %s (over %d levels)"]:format(ns.Duration(avg), n)) end
    local jumps = ns.db.stats and ns.db.stats.jumps
    if jumps and jumps > 0 then doc:Line(L["Jumps: %s"]:format(ns.Number(jumps))) end
    local online = ns.db.time and ns.db.time.online
    if online and online > 0 then doc:Faded(L["The book has watched %s of it."]:format(UI.LongDuration(online))) end

    doc:Heading(L["Journey map"], {
        { L["Play your journey"], icon = "Interface\\Icons\\INV_Misc_Map_01",
            tip = { L["Journey"], L["Plays your route back in a window of its own, day by day, with a time bar to scrub through it."] },
            onClick = function() if ns.JourneyMap then ns.JourneyMap.Show(ns.Today()) end end },
    })
    doc:Faded(L["Every day's route can be played back on a map, with where each thing in the log happened."])

    doc:Heading(L["Levels"])
    if #levels == 0 then
        doc:Faded(L["No levels written down yet."])
        return
    end
    for i = #levels, 1, -1 do
        local lvl = levels[i]
        local rec = ns.db.levels[lvl]
        local parts = {}
        if rec.time then parts[#parts + 1] = date(L["%d %b %Y"], rec.time) end
        if rec.spent then parts[#parts + 1] = L["took %s"]:format(ns.Duration(rec.spent)) end
        if rec.zone then parts[#parts + 1] = rec.zone end
        local name = UI.Link(L["Level %d"]:format(lvl), "level", lvl)
        doc:Line(name .. (#parts > 0 and ("  |cff6b5d4f" .. table.concat(parts, "  ·  ") .. "|r") or ""))
    end
end

------------------------------------------------------------------------------
-- Where your time goes
------------------------------------------------------------------------------

local function TimeBars(doc, buckets)
    local online = buckets and buckets.online or 0
    if online <= 0 then
        doc:Faded(L["Nothing counted yet."])
        return
    end
    doc:Line(L["Online: %s"]:format(UI.LongDuration(online)))
    local rows = {}
    for _, state in ipairs(ns.Journey.STATES) do
        local s = buckets[state] or 0
        if state ~= "online" and s > 0 then rows[#rows + 1] = { state, s } end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    for _, r in ipairs(rows) do
        doc:Bar(STATE_NAMES[r[1]] or r[1], r[2], online,
            L["%s  (%d%%)"]:format(ns.Duration(r[2]), math.floor(r[2] / online * 100 + 0.5)))
    end
end

function Page:RenderTime(doc)
    doc:Title(L["Where your time goes"])
    doc:Faded(L["Share of your time online. They overlap: flying while in a group counts for both."])
    doc:Heading(L["All told"])
    TimeBars(doc, ns.db.time)
    local today = ns.db.days[ns.Today()]
    doc:Heading(L["Today"])
    TimeBars(doc, today and today.time)
    local lv = ns.LevelRecord and ns.LevelRecord()
    if lv and lv.tb then
        doc:Heading(L["This level"])
        TimeBars(doc, lv.tb)
    end
end

------------------------------------------------------------------------------
-- Travel
------------------------------------------------------------------------------

local function TravelBars(doc, buckets)
    local total, most = 0, 0
    for _, mode in ipairs(ns.Journey.MODES) do
        local y = buckets and buckets[mode] or 0
        total = total + y
        most = math.max(most, y)
    end
    if total <= 0 then
        doc:Faded(L["Nowhere yet."])
        return
    end
    doc:Line(L["In all: %s"]:format(UI.Distance(total)))
    for _, mode in ipairs(ns.Journey.MODES) do
        local y = buckets[mode] or 0
        if y > 0 then doc:Bar(MODE_NAMES[mode] or mode, y, most, UI.Distance(y), MODE_COLOR[mode]) end
    end
end

function Page:RenderTravel(doc)
    doc:Title(L["Travel"])
    doc:Heading(L["All told"])
    TravelBars(doc, ns.db.travel)
    local today = ns.db.days[ns.Today()]
    doc:Heading(L["Today"])
    TravelBars(doc, today and today.travel)
    -- Per level, newest first.
    local levels = Levels()
    local any = false
    for i = #levels, 1, -1 do
        local rec = ns.db.levels[levels[i]]
        if rec.travel then
            local total = 0
            for _, y in pairs(rec.travel) do total = total + y end
            if total > 0 then
                if not any then
                    doc:Heading(L["By level"])
                    any = true
                end
                local parts = {}
                for _, mode in ipairs(ns.Journey.MODES) do
                    local y = rec.travel[mode]
                    if y and y > 0 then parts[#parts + 1] = L["%s %s"]:format(MODE_NAMES[mode]:lower(), UI.Distance(y)) end
                end
                doc:Line(L["Level %d: %s"]:format(levels[i], UI.Distance(total)) .. "  |cff6b5d4f" .. table.concat(parts, ", ") .. "|r")
            end
        end
    end
end

------------------------------------------------------------------------------
-- Your characters (CaptainsLogAccount.roster)
------------------------------------------------------------------------------

function Page:RenderRoster(doc)
    doc:Title(L["Your characters"])
    local roster = CaptainsLogAccount and CaptainsLogAccount.roster
    local list = {}
    for key, r in pairs(roster or {}) do
        if type(r) == "table" then list[#list + 1] = { key = key, r = r } end
    end
    table.sort(list, function(a, b) return (a.r.last or 0) > (b.r.last or 0) end)
    if #list == 0 then
        doc:Faded(L["Each character you log in with is added here."])
        return
    end
    local money = 0
    for _, e in ipairs(list) do
        local r = e.r
        money = money + (r.money or 0)
        local realm, name = e.key:match("^(.-)%-([^%-]+)$")
        local className = r.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.class] or r.class or ""
        doc:Gap(2)
        doc:Text(UI.ClassInk(r.class) .. (r.name or name or e.key) .. "|r  |cff6b5d4f" .. (realm or "") .. "|r", 13, nil, nil, 8)
        doc:Line(L["Level %s %s"]:format(r.level or "?", className))
        local parts = {}
        if r.played then parts[#parts + 1] = L["%s played"]:format(UI.LongDuration(r.played)) end
        if r.money then parts[#parts + 1] = ns.Money(r.money) end
        if r.zone then parts[#parts + 1] = r.zone end
        if r.last then parts[#parts + 1] = L["last seen %s"]:format(ns.Ago(r.last)) end
        doc:Faded(table.concat(parts, "  ·  "))
    end
    doc:Gap(6)
    doc:Line(L["Coin across them all: %s"]:format(ns.Money(money)))
end

------------------------------------------------------------------------------
-- A level's snapshot
------------------------------------------------------------------------------

function Page:RenderLevel(doc, lvl)
    local rec = ns.db.levels[lvl]
    doc:Title(L["Level %d"]:format(lvl))
    local parts = {}
    if rec.time then parts[#parts + 1] = L["Reached %s"]:format(date(L["%d %b %Y, %H:%M"], rec.time)) end
    if rec.zone then parts[#parts + 1] = L["in %s"]:format(UI.ZoneLink(rec.zone)) end
    if #parts > 0 then doc:Line(table.concat(parts, " ")) end
    if rec.played then doc:Line(L["After %s of play."]:format(UI.LongDuration(rec.played))) end
    if rec.spent then
        doc:Line(L["This level took %s."]:format(ns.Duration(rec.spent)))
    elseif lvl == UnitLevel("player") then
        local _, thisLevel = Played()
        if thisLevel then doc:Line(L["You've been this level for %s so far."]:format(ns.Duration(thisLevel))) end
    end

    local snap = rec.snap
    if snap and snap.gear and self.model then self.model:ShowGear(snap.gear) end
    if not snap then
        doc:Gap()
        doc:Faded(L["No snapshot of you at this level: they're taken as you reach each level from now on."])
        return
    end

    if snap.money or snap.rested or snap.guild then
        doc:Heading(L["In your pocket"])
        if snap.money then doc:Line(L["Coin: %s"]:format(ns.Money(snap.money))) end
        if snap.rested and snap.rested > 0 then doc:Line(L["Rested: %s xp"]:format(ns.Number(snap.rested))) end
        if snap.guild then
            doc:Line(snap.guildRank and L["%s of <%s>"]:format(snap.guildRank, snap.guild) or ("<" .. snap.guild .. ">"))
        end
    end

    doc:Heading(L["Attributes"])
    if snap.hp then doc:Line(L["%s: %s"]:format(HEALTH or L["Health"], ns.Number(snap.hp))) end
    if snap.power and snap.power > 0 then
        local pname = POWER[snap.powerType] and _G[POWER[snap.powerType]] or L["Power"]
        doc:Line(L["%s: %s"]:format(pname, ns.Number(snap.power)))
    end
    for i = 1, 5 do
        local v = snap.stats and snap.stats[i]
        if v then doc:Line(L["%s: %s"]:format(StatName(i), ns.Number(v))) end
    end
    if snap.armor then doc:Line(L["%s: %s"]:format(ARMOR or L["Armor"], ns.Number(snap.armor))) end

    if snap.talents and #snap.talents > 0 then
        local points = {}
        for i, t in ipairs(snap.talents) do points[i] = tostring(t.points or 0) end
        doc:Heading(L["Talents (%s)"]:format(table.concat(points, "/")))
        for _, t in ipairs(snap.talents) do
            doc:Line(L["%s: %d"]:format(t.name or "?", t.points or 0))
        end
    end

    if snap.gear and next(snap.gear) then
        doc:Heading(L["Gear"])
        for slot = 1, 19 do
            local id = snap.gear[slot]
            if id then
                local link = UI.ItemLink(id)
                doc:Item(link, SlotName(slot), UI.ItemIcon(id))
                doc.items[doc.ni].link = link:match("|H(item:[^|]+)|h") or link
            end
        end
    end

    if snap.skills and next(snap.skills) then
        doc:Heading(L["Skills"])
        local names = {}
        for name in pairs(snap.skills) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local s = snap.skills[name]
            local rank, max = s[1], s[2]
            doc:Line((max and max > 1) and L["%s: %d / %d"]:format(name, rank or 0, max) or name)
        end
    end
end

-- Arriving by a link: a level number opens its snapshot.
function Page:Reveal(sel)
    self.selected = sel or "overview"
    if self.list then self.list.revealKey = self.selected end
end
