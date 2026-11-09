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
}
local XP = { "xpKill", "xpQuest", "xpExplore", "xpRested" }

local function Sum(t)
    local n = 0
    for _, v in pairs(t or {}) do n = n + v end
    return n
end

-- A day's coin in and out: from its ledger, or (days before the ledger) its plain totals.
local function DayInOut(d)
    if d.ledger then return Sum(d.ledger.inc), Sum(d.ledger.exp) end
    return d.moneyIn or 0, d.moneyOut or 0
end

local function Net(n)
    if n >= 0 then return "|cff2f6b1a+" .. ns.Money(n) .. "|r" end
    return "|cff7a1f0d-" .. ns.Money(-n) .. "|r"
end

-- Adds ledgers together: { inc = {}, exp = {} }.
local function Merge(into, ledger)
    for _, side in ipairs({ "inc", "exp" }) do
        into[side] = into[side] or {}
        for cat, v in pairs(ledger and ledger[side] or {}) do into[side][cat] = (into[side][cat] or 0) + v end
    end
    return into
end

local function RecentKeys(n)
    local list = {}
    for i = 0, n - 1 do list[#list + 1] = date("%Y-%m-%d", time() - i * 86400) end
    return list
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sub = ns.Book:Header(left, L["Ledger"])
    self.list = UI.List(left, W, H - 70)
    self.list.sf:SetPoint("TOPLEFT", 0, -70)
    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
    self.selected = "life"
end

function Page:Render()
    local inc, exp = Sum(ns.db.ledger.inc), Sum(ns.db.ledger.exp)
    self.sub:SetText(L["In %s  ·  out %s"]:format(ns.Money(inc), ns.Money(exp)))

    local items = {
        { key = "life", left = L["All told"] },
        { key = "week", left = L["The last seven days"] },
        { key = "stats", left = L["Tallies"] },
    }
    local keys = {}
    for key, d in pairs(ns.db.days) do
        local i, o = DayInOut(d)
        if i > 0 or o > 0 then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return a > b end)
    if #keys > 0 then items[#items + 1] = { header = true, left = L["Days"] } end
    for _, key in ipairs(keys) do
        local i, o = DayInOut(ns.db.days[key])
        items[#items + 1] = { key = key, left = date(L["%a %d %b %Y"], ns.DayTime(key)), right = Net(i - o) }
    end
    if self.selected ~= "life" and self.selected ~= "week" and self.selected ~= "stats" and not ns.db.days[self.selected] then
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

-- Income and spending by category as bars, all against the biggest single line.
local function Breakdown(doc, ledger)
    local inc, exp = ledger.inc or {}, ledger.exp or {}
    local most = 0
    for _, v in pairs(inc) do most = math.max(most, v) end
    for _, v in pairs(exp) do most = math.max(most, v) end
    local tin, tout = Sum(inc), Sum(exp)
    doc:Heading(L["Coin in: %s"]:format(ns.Money(tin)))
    local any = false
    for _, cat in ipairs(INCOME) do
        if (inc[cat] or 0) > 0 then
            doc:Bar(INC_NAMES[cat], inc[cat], most, ns.Money(inc[cat]), IN_COLOR)
            any = true
        end
    end
    if not any then doc:Faded(L["None."]) end
    doc:Heading(L["Coin out: %s"]:format(ns.Money(tout)))
    any = false
    for _, cat in ipairs(EXPENSE) do
        if (exp[cat] or 0) > 0 then
            doc:Bar(EXP_NAMES[cat], exp[cat], most, ns.Money(exp[cat]), OUT_COLOR)
            any = true
        end
    end
    if not any then doc:Faded(L["None."]) end
    doc:Gap(4)
    doc:Text(L["Net: %s"]:format(Net(tin - tout)), 13, nil, nil, 8)
end

function Page:RenderLife(doc)
    doc:Title(L["All told"])
    Breakdown(doc, ns.db.ledger)
    local today = ns.db.days[ns.Today()]
    if today then
        local i, o = DayInOut(today)
        doc:Heading(L["Today"])
        doc:Line(L["In %s, out %s"]:format(ns.Money(i), ns.Money(o)))
        doc:Line(L["Net: %s"]:format(Net(i - o)))
    end
    doc:Gap(8)
    doc:Faded(L["Coin is put down to what was open at the time: a merchant, the mailbox, a trade, the auction house, a flight master, a corpse being looted."])
end

function Page:RenderWeek(doc)
    doc:Title(L["The last seven days"])
    local week, ti, to = {}, 0, 0
    doc:Heading(L["Day by day"])
    for _, key in ipairs(RecentKeys(7)) do
        local d = ns.db.days[key]
        local i, o = 0, 0
        if d then
            i, o = DayInOut(d)
            Merge(week, d.ledger)
        end
        ti, to = ti + i, to + o
        local label = date(L["%a %d %b"], ns.DayTime(key))
        if i > 0 or o > 0 then
            doc:Line(L["%s: in %s, out %s, %s"]:format(label, ns.Money(i), ns.Money(o), Net(i - o)))
        else
            doc:Text(L["%s: nothing"]:format(label), 12, UI.FADED, nil, 8)
        end
    end
    doc:Gap(2)
    doc:Text(L["In %s, out %s"]:format(ns.Money(ti), ns.Money(to)), 12, nil, nil, 8)
    Breakdown(doc, week)
end

function Page:RenderDay(doc, key)
    local d = ns.db.days[key]
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    if d.ledger then
        Breakdown(doc, d.ledger)
    else
        local i, o = DayInOut(d)
        doc:Line(L["In %s, out %s"]:format(ns.Money(i), ns.Money(o)))
        doc:Line(L["Net: %s"]:format(Net(i - o)))
        doc:Faded(L["From before the ledger sorted coin by what it was for."])
    end
end

function Page:RenderStats(doc)
    doc:Title(L["Tallies"])
    local s = ns.db.stats
    local cells = {}
    for _, e in ipairs(STATS) do
        cells[#cells + 1] = { name = ns.StatName(e[1]), icon = e[2], note = ns.Number(s[e[1]] or 0),
            tipTitle = ns.StatName(e[1]), dim = (s[e[1]] or 0) == 0 }
    end
    doc:Grid(cells, 2)

    local total = 0
    for _, k in ipairs(XP) do total = total + (s[k] or 0) end
    doc:Heading(L["Experience by source"])
    if total == 0 then
        doc:Faded(L["Nothing counted yet."])
    else
        doc:Line(L["In all: %s xp"]:format(ns.Number(total)))
        for _, k in ipairs(XP) do
            local v = s[k] or 0
            doc:Bar(ns.StatName(k), v, total, L["%s  (%d%%)"]:format(ns.Number(v), math.floor(v / total * 100 + 0.5)))
        end
    end
    doc:Gap(8)
    doc:Faded(L["Counting started when this version of the book was installed; kills, quests and deaths include what it knew before."])
end
