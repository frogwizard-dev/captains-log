local _, ns = ...
local issecret = ns.issecret

-- The money ledger: each change in your coin is put down to what was going on (a merchant open, a
-- flight just taken, a corpse being looted...), as income (sell, mail, trade, auction, loot, quest,
-- other) or expense (buy, repair, training, flights, mail, trade, auction, quest, other), per day
-- (day.ledger) and for all time (db.ledger). Tracker.lua keeps the plain day.moneyIn/moneyOut.

local GRACE = 3 -- seconds a window's context lasts after it closes (trade money lands late)

local open = {}    -- [context] = true while its window is open
local closed = {}  -- [context] = GetTime() it closed
local repairCost, repairAt

local function Active(context)
    if open[context] then return true end
    return closed[context] and GetTime() - closed[context] <= GRACE
end

local function Window(context, showEvent, closeEvent)
    ns.On(showEvent, function() open[context], closed[context] = true, nil end)
    ns.On(closeEvent, function()
        if open[context] then closed[context] = GetTime() end
        open[context] = nil
    end)
end

Window("merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED")
Window("trainer", "TRAINER_SHOW", "TRAINER_CLOSED")
Window("taxi", "TAXIMAP_OPENED", "TAXIMAP_CLOSED")
Window("mail", "MAIL_SHOW", "MAIL_CLOSED")
Window("trade", "TRADE_SHOW", "TRADE_CLOSED")
Window("auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED")
Window("loot", "LOOT_OPENED", "LOOT_CLOSED")
Window("quest", "QUEST_COMPLETE", "QUEST_FINISHED")

ns.On("CHAT_MSG_MONEY", function() closed.loot = GetTime() end)
ns.On("QUEST_TURNED_IN", function() closed.quest = GetTime() end)

-- A flight just taken (TakeTaxiNode): its fare comes a moment later. Also counted (Stats.lua).
if hooksecurefunc and TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function()
        closed.flight = GetTime()
        if ns.Count then ns.Count("flights") end
    end)
end

if hooksecurefunc and RepairAllItems then
    hooksecurefunc("RepairAllItems", function()
        local ok, cost = pcall(GetRepairAllCost)
        if ok and not issecret(cost) and type(cost) == "number" and cost > 0 then
            repairCost, repairAt = cost, GetTime()
        end
    end)
end

local function InRepair()
    local ok, on = pcall(InRepairMode)
    return ok and not issecret(on) and on
end

local function Category(income, change)
    if not income and repairAt and GetTime() - repairAt <= GRACE and (change == repairCost or Active("merchant")) then
        repairAt = nil
        return "repair"
    end
    if Active("merchant") then
        if income then return "sell" end
        return (InRepairMode and InRepair()) and "repair" or "buy"
    end
    if not income and Active("trainer") then return "training" end
    if not income and (Active("taxi") or Active("flight")) then return "flights" end
    if Active("auction") then return "auction" end
    if Active("mail") then return "mail" end
    if Active("trade") then return "trade" end
    if Active("quest") then return "quest" end
    if income and Active("loot") then return "loot" end
    return "other"
end

local function Add(ledger, side, category, amount)
    local totals = ns.Sub(ledger, side)
    totals[category] = (totals[category] or 0) + amount
end

local lastMoney
ns.On("PLAYER_MONEY", function()
    local money = GetMoney()
    if issecret(money) or type(money) ~= "number" then return end
    if lastMoney and money ~= lastMoney then
        local income = money > lastMoney
        local amount = math.abs(money - lastMoney)
        local category = Category(income, amount)
        local side = income and "inc" or "exp"
        Add(ns.db.ledger, side, category, amount)
        Add(ns.Sub(ns.Day(), "ledger"), side, category, amount)
    end
    lastMoney = money
end)
ns.On("PLAYER_LOGIN", function()
    local money = GetMoney()
    if not issecret(money) then lastMoney = money end
end)
