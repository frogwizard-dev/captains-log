local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Ledger"], color = { 0.55, 0.42, 0.10 }, order = 1.6 }
ns.Pages.ledger = Page

-- Coin in and out, by what it came from and went on (Ledger.lua), for all time, this week and
-- each day; and the lifetime tallies (Stats.lua) with where your experience came from.

local INCOME = { "sell", "loot", "quest", "auction", "mail", "trade", "other" }
local EXPENSE = { "buy", "repair", "training", "flights", "auction", "mail", "trade", "quest", "other" }
local INC_NAMES = {
    sell = L["Selling to merchants"], loot = L["Loot"], quest = L["Quest rewards"], auction = L["Auction house"],
    mail = L["Mail"], trade = L["Trades"], other = L["Other"],
}
local EXP_NAMES = {
    buy = L["Buying from merchants"], repair = L["Repairs"], training = L["Training"], flights = L["Flights"],
    auction = L["Auction house"], mail = L["Postage and mail"], trade = L["Trades"], quest = L["Quests"], other = L["Other"],
}
local IN_COLOR = { 0.30, 0.55, 0.20 }
local OUT_COLOR = { 0.50, 0.12, 0.05 }
local VIEWS = { life = true, week = true, stats = true } -- the lines above the days

local STATS = {
    { "kills", "Interface\\Icons\\INV_Sword_04" },
    { "quests", "Interface\\Icons\\INV_Misc_Note_01" },
    { "deaths", "Interface\\Icons\\Ability_Rogue_FeignDeath" },
    { "looted", "Interface\\Icons\\INV_Misc_Bag_10" },
    { "crafted", "Interface\\Icons\\Trade_BlackSmithing" },
    { "fish", "Interface\\Icons\\Trade_Fishing" },
    { "flights", "Interface\\Icons\\Spell_Nature_Swiftness" },
    { "hearths", "Interface\\Icons\\INV_Misc_Rune_01" },
    { "dungeons", "Interface\\Icons\\INV_Misc_Key_03" },
    { "bosses", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    { "duelsWon", "Interface\\Icons\\Ability_Warrior_Challange" },
    { "duelsLost", "Interface\\Icons\\Ability_Warrior_Challange" },
    { "jumps", "Interface\\Icons\\Ability_Rogue_Sprint" },
    { "herbs", "Interface\\Icons\\INV_Misc_Herb_07" },
    { "ore", "Interface\\Icons\\INV_Ore_Copper_01" },
    { "skins", "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
}
local XP = { "xpKill", "xpQuest", "xpExplore", "xpRested" }

local function Sum(totals)
    local sum = 0
    for _, amount in pairs(totals or {}) do sum = sum + amount end
    return sum
end

-- A day's coin in and out: from its ledger, or (days before the ledger) its plain totals.
local function DayInOut(day)
    if day.ledger then return Sum(day.ledger.inc), Sum(day.ledger.exp) end
    return day.moneyIn or 0, day.moneyOut or 0
end

local function Net(amount)
    if amount >= 0 then return "|cff2f6b1a+" .. ns.Money(amount) .. "|r" end
    return "|cff7a1f0d-" .. ns.Money(-amount) .. "|r"
end

-- Adds ledgers together: { inc = {}, exp = {} }.
local function Merge(into, ledger)
    for _, side in ipairs({ "inc", "exp" }) do
        into[side] = into[side] or {}
        for category, amount in pairs(ledger and ledger[side] or {}) do
            into[side][category] = (into[side][category] or 0) + amount
        end
    end
    return into
end

local function RecentKeys(days)
    local list = {}
    for i = 0, days - 1 do list[#list + 1] = date("%Y-%m-%d", time() - i * 86400) end
    return list
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.subtitle = ns.Book:Header(left, L["Ledger"])
    self.list = UI.List(left, width, height - 70)
    self.list.scroll:SetPoint("TOPLEFT", 0, -70)
    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
    self.selected = "life"
end

function Page:Render()
    local coinIn, coinOut = Sum(ns.db.ledger.inc), Sum(ns.db.ledger.exp)
    self.subtitle:SetText(L["In %s  ·  out %s"]:format(ns.Money(coinIn), ns.Money(coinOut)))

    local items = {
        { key = "life", left = L["All told"] },
        { key = "week", left = L["The last seven days"] },
        { key = "stats", left = L["Tallies"] },
    }
    local keys = {}
    for key, day in pairs(ns.db.days) do
        local dayIn, dayOut = DayInOut(day)
        if dayIn > 0 or dayOut > 0 then keys[#keys + 1] = key end
    end
    table.sort(keys, function(first, second) return first > second end)
    if #keys > 0 then items[#items + 1] = { header = true, left = L["Days"] } end
    for _, key in ipairs(keys) do
        local dayIn, dayOut = DayInOut(ns.db.days[key])
        items[#items + 1] = { key = key, left = date(L["%a %d %b %Y"], ns.DayTime(key)), right = Net(dayIn - dayOut) }
    end
    if not VIEWS[self.selected] and not ns.db.days[self.selected] then
        self.selected = "life"
    end
    self.list:SetItems(items, self.selected, function(key)
        self.selected = key
        self:Render()
    end)

    local doc = self.doc
    doc:Clear("ledger:" .. self.selected)
    ns.Book:BackLink(doc)
    if self.selected == "week" then
        self:RenderWeek(doc)
    elseif self.selected == "stats" then
        self:RenderStats(doc)
    elseif self.selected == "life" then
        self:RenderLife(doc)
    else
        self:RenderDay(doc, self.selected)
    end
    doc:Finish()
    self.title = L["Ledger"]
end

-- One side of the ledger as bars, against `most`, the biggest single line on either side.
local function Side(doc, heading, totals, order, names, color, most)
    doc:Heading(heading)
    local any = false
    for _, category in ipairs(order) do
        if (totals[category] or 0) > 0 then
            doc:Bar(names[category], totals[category], most, ns.Money(totals[category]), color)
            any = true
        end
    end
    if not any then doc:Faded(L["None."]) end
end

-- Income and spending by category as bars, all against the biggest single line.
local function Breakdown(doc, ledger)
    local income, expense = ledger.inc or {}, ledger.exp or {}
    local most = 0
    for _, amount in pairs(income) do most = math.max(most, amount) end
    for _, amount in pairs(expense) do most = math.max(most, amount) end
    local totalIn, totalOut = Sum(income), Sum(expense)
    Side(doc, L["Coin in: %s"]:format(ns.Money(totalIn)), income, INCOME, INC_NAMES, IN_COLOR, most)
    Side(doc, L["Coin out: %s"]:format(ns.Money(totalOut)), expense, EXPENSE, EXP_NAMES, OUT_COLOR, most)
    doc:Gap(4)
    doc:Text(L["Net: %s"]:format(Net(totalIn - totalOut)), 13, nil, nil, 8)
end

function Page:RenderLife(doc)
    doc:Title(L["All told"])
    Breakdown(doc, ns.db.ledger)
    local today = ns.db.days[ns.Today()]
    if today then
        local dayIn, dayOut = DayInOut(today)
        doc:Heading(L["Today"])
        doc:Line(L["In %s, out %s"]:format(ns.Money(dayIn), ns.Money(dayOut)))
        doc:Line(L["Net: %s"]:format(Net(dayIn - dayOut)))
    end
    doc:Gap(8)
    doc:Faded(L["Coin is put down to what was open at the time: a merchant, the mailbox, a trade, the auction house, a flight master, a corpse being looted."])
end

function Page:RenderWeek(doc)
    doc:Title(L["The last seven days"])
    local week, weekIn, weekOut = {}, 0, 0
    doc:Heading(L["Day by day"])
    for _, key in ipairs(RecentKeys(7)) do
        local day = ns.db.days[key]
        local dayIn, dayOut = 0, 0
        if day then
            dayIn, dayOut = DayInOut(day)
            Merge(week, day.ledger)
        end
        weekIn, weekOut = weekIn + dayIn, weekOut + dayOut
        local label = date(L["%a %d %b"], ns.DayTime(key))
        if dayIn > 0 or dayOut > 0 then
            doc:Line(L["%s: in %s, out %s, %s"]:format(label, ns.Money(dayIn), ns.Money(dayOut), Net(dayIn - dayOut)))
        else
            doc:Text(L["%s: nothing"]:format(label), 12, UI.FADED, nil, 8)
        end
    end
    doc:Gap(2)
    doc:Text(L["In %s, out %s"]:format(ns.Money(weekIn), ns.Money(weekOut)), 12, nil, nil, 8)
    Breakdown(doc, week)
end

function Page:RenderDay(doc, key)
    local day = ns.db.days[key]
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    if day.ledger then
        Breakdown(doc, day.ledger)
    else
        local dayIn, dayOut = DayInOut(day)
        doc:Line(L["In %s, out %s"]:format(ns.Money(dayIn), ns.Money(dayOut)))
        doc:Line(L["Net: %s"]:format(Net(dayIn - dayOut)))
        doc:Faded(L["From before the ledger sorted coin by what it was for."])
    end
end

function Page:RenderStats(doc)
    doc:Title(L["Tallies"])
    local stats = ns.db.stats
    local cells = {}
    for _, stat in ipairs(STATS) do
        local key, icon = stat[1], stat[2]
        cells[#cells + 1] = { name = ns.StatName(key), icon = icon, note = ns.Number(stats[key] or 0),
            tipTitle = ns.StatName(key), dim = (stats[key] or 0) == 0 }
    end
    doc:Grid(cells, 2)

    local total = 0
    for _, key in ipairs(XP) do total = total + (stats[key] or 0) end
    doc:Heading(L["Experience by source"])
    if total == 0 then
        doc:Faded(L["Nothing counted yet."])
    else
        doc:Line(L["In all: %s xp"]:format(ns.Number(total)))
        for _, key in ipairs(XP) do
            local xp = stats[key] or 0
            doc:Bar(ns.StatName(key), xp, total, L["%s  (%d%%)"]:format(ns.Number(xp), math.floor(xp / total * 100 + 0.5)))
        end
    end
    doc:Gap(8)
    doc:Faded(L["Counting started when this version of the book was installed; kills, quests and deaths include what it knew before."])
end
