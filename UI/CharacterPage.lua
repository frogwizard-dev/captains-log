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
local VIEWS = { overview = true, time = true, travel = true, roster = true } -- the lines above the levels

local function SlotName(slot)
    return (SLOTS[slot] and _G[SLOTS[slot]]) or L["Slot %d"]:format(slot)
end

local function StatName(index)
    return _G["SPELL_STAT" .. index .. "_NAME"]
        or ({ L["Strength"], L["Agility"], L["Stamina"], L["Intellect"], L["Spirit"] })[index]
end

-- /played now: the last reading plus the time since.
local function Played()
    local played = ns.db.played
    if not played or not played.total then return end
    local since = math.max(0, time() - (played.at or time()))
    return played.total + since, played.level and (played.level + since)
end

-- Levels the book has a record for, lowest first.
local function Levels()
    local list = {}
    for level, record in pairs(ns.db.levels) do
        if type(level) == "number" and type(record) == "table" then list[#list + 1] = level end
    end
    table.sort(list)
    return list
end

local function AveragePerLevel()
    local sum, count = 0, 0
    for _, record in pairs(ns.db.levels) do
        if type(record) == "table" and record.spent then
            sum, count = sum + record.spent, count + 1
        end
    end
    if count > 0 then return sum / count, count end
end

-- The clickable level in the book's text opens its snapshot here.
UI.RegisterLink("level", function(level)
    ns.Book:Goto("character", tonumber(level), true)
end, function(level)
    return L["Level %s"]:format(level), L["Click to see your gear, stats, talents and skills when you reached it."]
end)

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.subtitle = ns.Book:Header(left, ns.FullName("player") or L["Character"])
    self.played = UI.Text(left, 12)
    self.played:SetPoint("TOPLEFT", 2, -62)
    self.played:SetWidth(width)
    self.played:SetSpacing(2)

    self.list = UI.List(left, width, height - 112)
    self.list.scroll:SetPoint("TOPLEFT", 0, -112)

    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
    self.selected = "overview"
    self.model = self:BuildModel(self.doc.child)
end

-- You at a level, in the gear you had on then: a model of your character, undressed and dressed
-- in the snapshot's items, in the top corner of the page (it scrolls with it). Drag to turn it.
function Page:BuildModel(parent)
    local ok, model = pcall(CreateFrame, "DressUpModel", nil, parent)
    if not ok or not model then return nil end
    model:SetSize(170, 270)
    model:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -36)
    model:EnableMouse(true)
    model:Hide()
    local facing = 0.35
    model:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
    model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    model:SetScript("OnUpdate", function(self)
        if not self.dragX then return end
        local x = GetCursorPosition()
        facing = facing + (x - self.dragX) * 0.012
        self.dragX = x
        pcall(self.SetFacing, self, facing)
    end)
    model:SetScript("OnModelLoaded", function(self)
        pcall(self.SetFacing, self, facing)
        self:Dress()
    end)
    function model:Dress()
        local gear = self.gear
        if not gear then return end
        pcall(self.Undress, self)
        for slot, id in pairs(gear) do
            if slot ~= 0 and type(id) == "number" then pcall(self.TryOn, self, "item:" .. id) end
        end
    end
    function model:ShowGear(gear)
        self.gear = gear
        self:Show()
        if pcall(self.SetUnit, self, "player") then self:Dress() end
    end
    return model
end

function Page:Render()
    local class = UnitClass("player")
    local race = UnitRace("player")
    local guild = GetGuildInfo and GetGuildInfo("player")
    if ns.issecret(guild) then guild = nil end
    local who = L["Level %d %s %s"]:format(UnitLevel("player"), race or "", class or "")
    self.subtitle:SetText(guild and L["%s  ·  <%s>"]:format(who, guild) or who)

    local total, thisLevel = Played()
    local average = AveragePerLevel()
    local lines = {}
    lines[#lines + 1] = total and L["Played %s, %s of it at this level."]:format(UI.LongDuration(total), ns.Duration(thisLevel or 0))
        or L["Time played isn't known yet."]
    if average then lines[#lines + 1] = L["A level takes you %s on average."]:format(ns.Duration(average)) end
    self.played:SetText(table.concat(lines, "\n"))

    local items = {
        { key = "overview", left = L["Your journey"] },
        { key = "time", left = L["Where your time goes"] },
        { key = "travel", left = L["Travel"] },
        { key = "roster", left = L["Your characters"] },
    }
    local levels = Levels()
    if #levels > 0 then items[#items + 1] = { header = true, left = L["Levels"] } end
    for i = #levels, 1, -1 do
        local level = levels[i]
        local record = ns.db.levels[level]
        local when = record.time and date(L["%d %b %Y"], record.time) or ""
        local right = record.spent and ns.Duration(record.spent) or (level == UnitLevel("player") and L["now"] or "")
        items[#items + 1] = {
            key = level,
            left = L["Level %d"]:format(level) .. "  |cff6b5d4f" .. when .. "|r",
            right = right,
        }
    end
    if not VIEWS[self.selected] and not ns.db.levels[self.selected] then
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
    local average, count = AveragePerLevel()
    if average then doc:Line(L["Average per level: %s (over %d levels)"]:format(ns.Duration(average), count)) end
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
        local level = levels[i]
        local record = ns.db.levels[level]
        local parts = {}
        if record.time then parts[#parts + 1] = date(L["%d %b %Y"], record.time) end
        if record.spent then parts[#parts + 1] = L["took %s"]:format(ns.Duration(record.spent)) end
        if record.zone then parts[#parts + 1] = record.zone end
        local name = UI.Link(L["Level %d"]:format(level), "level", level)
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
        local seconds = buckets[state] or 0
        if state ~= "online" and seconds > 0 then rows[#rows + 1] = { state, seconds } end
    end
    table.sort(rows, function(first, second) return first[2] > second[2] end)
    for _, row in ipairs(rows) do
        doc:Bar(STATE_NAMES[row[1]] or row[1], row[2], online,
            L["%s  (%d%%)"]:format(ns.Duration(row[2]), math.floor(row[2] / online * 100 + 0.5)))
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
    local levelRecord = ns.LevelRecord and ns.LevelRecord()
    if levelRecord and levelRecord.tb then
        doc:Heading(L["This level"])
        TimeBars(doc, levelRecord.tb)
    end
end

------------------------------------------------------------------------------
-- Travel
------------------------------------------------------------------------------

local function TravelBars(doc, buckets)
    local total, most = 0, 0
    for _, mode in ipairs(ns.Journey.MODES) do
        local yards = buckets and buckets[mode] or 0
        total = total + yards
        most = math.max(most, yards)
    end
    if total <= 0 then
        doc:Faded(L["Nowhere yet."])
        return
    end
    doc:Line(L["In all: %s"]:format(UI.Distance(total)))
    for _, mode in ipairs(ns.Journey.MODES) do
        local yards = buckets[mode] or 0
        if yards > 0 then doc:Bar(MODE_NAMES[mode] or mode, yards, most, UI.Distance(yards), MODE_COLOR[mode]) end
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
        local record = ns.db.levels[levels[i]]
        if record.travel then
            local total = 0
            for _, yards in pairs(record.travel) do total = total + yards end
            if total > 0 then
                if not any then
                    doc:Heading(L["By level"])
                    any = true
                end
                local parts = {}
                for _, mode in ipairs(ns.Journey.MODES) do
                    local yards = record.travel[mode]
                    if yards and yards > 0 then parts[#parts + 1] = L["%s %s"]:format(MODE_NAMES[mode]:lower(), UI.Distance(yards)) end
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
    for key, character in pairs(roster or {}) do
        if type(character) == "table" then list[#list + 1] = { key = key, character = character } end
    end
    table.sort(list, function(first, second) return (first.character.last or 0) > (second.character.last or 0) end)
    if #list == 0 then
        doc:Faded(L["Each character you log in with is added here."])
        return
    end
    local money = 0
    for _, entry in ipairs(list) do
        local character = entry.character
        money = money + (character.money or 0)
        local realm, name = entry.key:match("^(.-)%-([^%-]+)$")
        local className = character.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[character.class]
            or character.class or ""
        doc:Gap(2)
        doc:Text(UI.ClassInk(character.class) .. (character.name or name or entry.key) .. "|r  |cff6b5d4f" .. (realm or "") .. "|r",
            13, nil, nil, 8)
        doc:Line(L["Level %s %s"]:format(character.level or "?", className))
        local parts = {}
        if character.played then parts[#parts + 1] = L["%s played"]:format(UI.LongDuration(character.played)) end
        if character.money then parts[#parts + 1] = ns.Money(character.money) end
        if character.zone then parts[#parts + 1] = character.zone end
        if character.last then parts[#parts + 1] = L["last seen %s"]:format(ns.Ago(character.last)) end
        doc:Faded(table.concat(parts, "  ·  "))
    end
    doc:Gap(6)
    doc:Line(L["Coin across them all: %s"]:format(ns.Money(money)))
end

------------------------------------------------------------------------------
-- A level's snapshot
------------------------------------------------------------------------------

function Page:RenderLevel(doc, level)
    local record = ns.db.levels[level]
    doc:Title(L["Level %d"]:format(level))
    local parts = {}
    if record.time then parts[#parts + 1] = L["Reached %s"]:format(date(L["%d %b %Y, %H:%M"], record.time)) end
    if record.zone then parts[#parts + 1] = L["in %s"]:format(UI.ZoneLink(record.zone)) end
    if #parts > 0 then doc:Line(table.concat(parts, " ")) end
    if record.played then doc:Line(L["After %s of play."]:format(UI.LongDuration(record.played))) end
    if record.spent then
        doc:Line(L["This level took %s."]:format(ns.Duration(record.spent)))
    elseif level == UnitLevel("player") then
        local _, thisLevel = Played()
        if thisLevel then doc:Line(L["You've been this level for %s so far."]:format(ns.Duration(thisLevel))) end
    end

    local snap = record.snap
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
        local powerName = POWER[snap.powerType] and _G[POWER[snap.powerType]] or L["Power"]
        doc:Line(L["%s: %s"]:format(powerName, ns.Number(snap.power)))
    end
    for i = 1, 5 do
        local value = snap.stats and snap.stats[i]
        if value then doc:Line(L["%s: %s"]:format(StatName(i), ns.Number(value))) end
    end
    if snap.armor then doc:Line(L["%s: %s"]:format(ARMOR or L["Armor"], ns.Number(snap.armor))) end

    if snap.talents and #snap.talents > 0 then
        local points = {}
        for i, tab in ipairs(snap.talents) do points[i] = tostring(tab.points or 0) end
        doc:Heading(L["Talents (%s)"]:format(table.concat(points, "/")))
        for _, tab in ipairs(snap.talents) do
            doc:Line(L["%s: %d"]:format(tab.name or "?", tab.points or 0))
        end
    end

    if snap.gear and next(snap.gear) then
        doc:Heading(L["Gear"])
        for slot = 1, 19 do
            local id = snap.gear[slot]
            if id then
                local link = UI.ItemLink(id)
                local button = doc:Item(link, SlotName(slot), UI.ItemIcon(id))
                button.link = link:match("|H(item:[^|]+)|h") or link
            end
        end
    end

    if snap.skills and next(snap.skills) then
        doc:Heading(L["Skills"])
        local names = {}
        for name in pairs(snap.skills) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local skill = snap.skills[name]
            local rank, maxRank = skill[1], skill[2]
            doc:Line((maxRank and maxRank > 1) and L["%s: %d / %d"]:format(name, rank or 0, maxRank) or name)
        end
    end
end

-- Arriving by a link: a level number opens its snapshot.
function Page:Reveal(selected)
    self.selected = selected or "overview"
    if self.list then self.list.revealKey = self.selected end
end
