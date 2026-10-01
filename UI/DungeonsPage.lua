local _, ns = ...
local UI = ns.UI

local Page = { label = "Dungeons", color = { 0.36, 0.18, 0.42 }, order = 5 }
ns.Pages.dungeons = Page

local ROLE = { TANK = "tank", HEALER = "healer", DAMAGER = "damage dealer" }
local ROLE_SHORT = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }

-- Class colours darkened so light ones (priest white, rogue yellow) stay readable on parchment.
local function ClassInk(class)
    local c = class and RAID_CLASS_COLORS[class]
    if not c then return "|cff2e1d0c" end
    return string.format("|cff%02x%02x%02x", c.r * 150, c.g * 150, c.b * 150)
end

local function BossText(run)
    if run.totalBosses then return string.format("%d/%d bosses", #run.bosses, run.totalBosses) end
    return #run.bosses .. (#run.bosses == 1 and " boss" or " bosses")
end
ns.RunBossText = BossText

local function FullClear(run)
    return run.totalBosses and #run.bosses >= run.totalBosses
end

-- Runs of the same instance share a key (older runs without an ID go by name).
local function InstanceKey(run)
    return tostring(run.instanceID or run.name)
end
ns.InstanceKey = InstanceKey

-- Arriving by a link: an instance key (a string) opens "By dungeon" on it; a run's index opens
-- that run.
function Page:Reveal(sel)
    if type(sel) == "string" then
        self.view, self.selectedInstance = "instances", sel
    else
        self.view, self.selected = "runs", sel
    end
    if self.list then self.list.revealKey = sel end
end

local function MobName(id)
    local m = ns.db.mobs[id]
    return (m and m.name) or ns.CreatureName(id) or ("Unknown creature #" .. tostring(id))
end

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sub = ns.Book:Header(left, "Dungeons & Raids")
    self.view = "runs"

    -- Every run, newest first, or one entry per dungeon with its records across runs.
    self.viewButtons = {}
    for i, v in ipairs({ { "runs", "Every run" }, { "instances", "By dungeon" } }) do
        local b = UI.Button(left, v[2], 110)
        b:SetPoint("TOPLEFT", (i - 1) * 116, -62)
        b:SetScript("OnClick", function()
            self.view = v[1]
            self:Render()
        end)
        self.viewButtons[v[1]] = b
    end

    self.list = UI.List(left, W, H - 94)
    self.list.sf:SetPoint("TOPLEFT", 0, -94)
    self.doc = UI.Doc(right, W, H)
    self.doc.sf:SetPoint("TOPLEFT")
end

function Page:Render()
    local runs = ns.db.runs
    local bosses = 0
    for _, run in ipairs(runs) do bosses = bosses + #run.bosses end
    self.sub:SetText(string.format("%d %s  ·  %d bosses defeated", #runs, #runs == 1 and "run" or "runs", bosses))
    for view, b in pairs(self.viewButtons) do
        if view == self.view then b:LockHighlight() else b:UnlockHighlight() end
    end
    if self.view == "instances" then
        self:RenderInstanceList()
    else
        self:RenderRunList()
    end
end

------------------------------------------------------------------------------
-- Every run
------------------------------------------------------------------------------

function Page:RenderRunList()
    local runs = ns.db.runs
    if not self.selected or not runs[self.selected] then self.selected = #runs > 0 and #runs or nil end
    local items = {}
    for i = #runs, 1, -1 do
        local run = runs[i]
        local active = ns.ActiveRun() == run
        items[#items + 1] = {
            key = i,
            left = run.name,
            right = active and "in progress" or (date("%d %b", run.start) .. "  ·  " .. ns.Duration(ns.RunDuration(run))),
            color = active and UI.ACCENT or nil,
        }
    end
    self.list:SetItems(items, self.selected, function(i)
        self.selected = i
        self:Render()
    end)
    self:RenderRun(self.selected)
end

-- The boss you'd most recently beaten when an item arrived (within two minutes of the kill).
local function LootSource(run, t)
    local source
    for _, boss in ipairs(run.bosses) do
        if boss.t <= t and t - boss.t < 120 then source = boss.name end
    end
    return source
end

-- Each boss the Encounter Journal lists, ticked when beaten; bosses it doesn't list follow.
function Page:RenderBosses(run, active)
    local doc = self.doc
    local journal = ns.JournalBosses(run.journalID)
    if not journal and #run.bosses == 0 then return end
    doc:Heading("Bosses")
    local byName, listed = {}, {}
    for _, boss in ipairs(run.bosses) do byName[boss.name] = boss end

    local function write(name, boss)
        if not boss then
            -- Not yet beaten: still to come while you're inside, missed once you've left.
            doc:Check(name, (not active) and false or nil, UI.FADED)
            return
        end
        local extra = { date("%H:%M", boss.t) }
        if boss.duration then extra[#extra + 1] = ns.Short(boss.duration) end
        if boss.wipes > 0 then extra[#extra + 1] = boss.wipes .. (boss.wipes == 1 and " wipe first" or " wipes first") end
        doc:Check(name .. "  |cff6b5d4f(" .. table.concat(extra, ", ") .. ")|r", true, UI.INK)
    end
    for _, name in ipairs(journal or {}) do
        listed[name] = true
        write(name, byName[name])
    end
    for _, boss in ipairs(run.bosses) do
        if not listed[boss.name] then write(boss.name, boss) end
    end
end

function Page:RenderRun(i)
    local doc = self.doc
    doc:Clear("run:" .. tostring(i))
    ns.Book:BackLink(doc)
    local run = i and ns.db.runs[i]
    if not run then
        doc:Title("No runs yet")
        doc:Faded("Each time you enter a dungeon or raid, the run is written down here.")
        doc:Finish()
        return
    end

    doc:Title(run.name)
    local kind = strtrim(string.format("%s  %s", run.difficulty or "", run.size and run.size > 0 and ("· " .. run.size .. "-player") or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Gap(4)

    local active = ns.ActiveRun() == run
    local ended = run.finish or run.leftAt
    doc:Line(string.format("Entered %s at %s, at level %d%s.", ns.Date(run.start), date("%H:%M", run.start),
        run.level or 0, ROLE[run.role] and (", as the " .. ROLE[run.role]) or ""))
    if active then
        doc:Line("In progress: " .. ns.Duration(ns.RunDuration(run)) .. " so far.")
    elseif ended then
        doc:Line(string.format("Left at %s, after %s.", date("%H:%M", ended), ns.Duration(ns.RunDuration(run))))
    end
    doc:Line(BossText(run) .. " defeated" .. (run.wipes > 0 and string.format(", %d %s", run.wipes, run.wipes == 1 and "wipe" or "wipes") or "") .. ".")
    if FullClear(run) then doc:Line("A full clear.", UI.ACCENT) end
    if run.kills > 0 then doc:Line("Creatures slain: " .. ns.Number(run.kills)) end
    if (run.xp or 0) > 0 then doc:Line("Experience gained: " .. ns.Number(run.xp)) end
    if (run.money or 0) > 0 then doc:Line("Coin gathered: " .. ns.Money(run.money)) end
    if run.deaths > 0 then doc:Line("Your deaths: " .. run.deaths, UI.ACCENT) end

    self:RenderBosses(run, active)

    if #run.group > 0 then
        doc:Heading("Companions")
        for _, member in ipairs(run.group) do
            doc:Line(ClassInk(member.class) .. member.name .. "|r"
                .. (ROLE_SHORT[member.role] and ("  |cff6b5d4f" .. ROLE_SHORT[member.role] .. "|r") or ""))
        end
    end

    local mobs = {}
    for id, n in pairs(run.mobs or {}) do mobs[#mobs + 1] = { id = id, n = n } end
    if #mobs > 0 then
        table.sort(mobs, function(a, b) return a.n > b.n end)
        doc:Heading("Creatures slain inside")
        for k = 1, math.min(#mobs, 12) do
            doc:Line(string.format("%s  x%d", UI.MobLink(mobs[k].id, MobName(mobs[k].id)), mobs[k].n))
        end
    end

    if #run.loot > 0 then
        doc:Heading("Treasures")
        for _, item in ipairs(run.loot) do
            local source = item.time and LootSource(run, item.time)
            doc:Item(item.link, source and ("from " .. source) or nil)
        end
    end

    -- Every run of this same instance, for comparison.
    local count, fastest = 0, nil
    for _, other in ipairs(ns.db.runs) do
        if InstanceKey(other) == InstanceKey(run) and other.difficulty == run.difficulty then
            count = count + 1
            if FullClear(other) then
                local d = ns.RunDuration(other)
                if not fastest or d < fastest then fastest = d end
            end
        end
    end
    if count > 1 then
        doc:Gap(6)
        doc:Faded(string.format("You've run %s %d times%s. See \"By dungeon\" for its records.", run.name, count,
            fastest and (", fastest full clear " .. ns.Duration(fastest)) or ""))
    end
    doc:Finish()
end

------------------------------------------------------------------------------
-- By dungeon
------------------------------------------------------------------------------

-- Runs grouped by instance, most recently entered first.
local function Instances()
    local byKey, list = {}, {}
    for _, run in ipairs(ns.db.runs) do
        local key = InstanceKey(run)
        local inst = byKey[key]
        if not inst then
            inst = { key = key, name = run.name, runs = {} }
            byKey[key] = inst
            list[#list + 1] = inst
        end
        table.insert(inst.runs, run)
    end
    table.sort(list, function(a, b) return a.runs[#a.runs].start > b.runs[#b.runs].start end)
    return list, byKey
end

function Page:RenderInstanceList()
    local list, byKey = Instances()
    if not self.selectedInstance or not byKey[self.selectedInstance] then
        self.selectedInstance = list[1] and list[1].key
    end
    local items = {}
    for _, inst in ipairs(list) do
        local clears = 0
        for _, run in ipairs(inst.runs) do
            if FullClear(run) then clears = clears + 1 end
        end
        items[#items + 1] = {
            key = inst.key,
            left = inst.name,
            right = string.format("%d %s%s", #inst.runs, #inst.runs == 1 and "run" or "runs",
                clears > 0 and string.format("  ·  %d %s", clears, clears == 1 and "clear" or "clears") or ""),
        }
    end
    self.list:SetItems(items, self.selectedInstance, function(key)
        self.selectedInstance = key
        self:Render()
    end)
    self:RenderInstance(byKey[self.selectedInstance])
end

local function TopCounts(counts, limit)
    local list = {}
    for k, n in pairs(counts) do list[#list + 1] = { k = k, n = n } end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return tostring(a.k) < tostring(b.k)
    end)
    for i = #list, limit + 1, -1 do list[i] = nil end
    return list
end

function Page:RenderInstance(inst)
    local doc = self.doc
    doc:Clear("instance:" .. tostring(inst and inst.key))
    ns.Book:BackLink(doc)
    if not inst then
        doc:Title("No dungeons yet")
        doc:Faded("Every dungeon and raid you enter gets its own page of records here.")
        doc:Finish()
        return
    end
    local runs = inst.runs
    doc:Title(inst.name)

    local diffs, diffOrder = {}, {}
    local clears, fastest, clearTime = 0, nil, 0
    local inside, bosses, wipes, deaths, kills, xp, money = 0, 0, 0, 0, 0, 0, 0
    local journalID
    local bossStats, bossOrder = {}, {}
    local friends, mobs, loot, lootOrder = {}, {}, {}, {}
    local friendClass = {}

    local function Boss(name)
        local b = bossStats[name]
        if not b then
            b = { kills = 0, wipes = 0 }
            bossStats[name] = b
            bossOrder[#bossOrder + 1] = name
        end
        return b
    end

    for _, run in ipairs(runs) do
        local d = run.difficulty and run.difficulty ~= "" and run.difficulty or "Normal"
        if not diffs[d] then diffOrder[#diffOrder + 1] = d end
        diffs[d] = (diffs[d] or 0) + 1
        local duration = ns.RunDuration(run)
        inside = inside + duration
        if FullClear(run) then
            clears = clears + 1
            clearTime = clearTime + duration
            if not fastest or duration < fastest then fastest = duration end
        end
        bosses, wipes, deaths, kills = bosses + #run.bosses, wipes + run.wipes, deaths + run.deaths, kills + run.kills
        xp, money = xp + (run.xp or 0), money + (run.money or 0)
        journalID = run.journalID or journalID
        for _, boss in ipairs(run.bosses) do
            local b = Boss(boss.name)
            b.kills = b.kills + 1
            b.wipes = b.wipes + (boss.wipes or 0)
            if boss.duration and (not b.fastest or boss.duration < b.fastest) then b.fastest = boss.duration end
        end
        for _, member in ipairs(run.group) do
            friends[member.name] = (friends[member.name] or 0) + 1
            friendClass[member.name] = member.class
        end
        for id, n in pairs(run.mobs or {}) do mobs[id] = (mobs[id] or 0) + n end
        for _, item in ipairs(run.loot) do
            if not loot[item.link] then lootOrder[#lootOrder + 1] = item.link end
            loot[item.link] = (loot[item.link] or 0) + 1
        end
    end

    local d = {}
    for _, name in ipairs(diffOrder) do d[#d + 1] = name .. (diffs[name] > 1 and (" x" .. diffs[name]) or "") end
    doc:Faded(table.concat(d, "  ·  "))
    doc:Gap(4)

    doc:Line(string.format("Run %d %s: first %s, last %s.", #runs, #runs == 1 and "time" or "times",
        ns.Date(runs[1].start), ns.Date(runs[#runs].start)))
    if clears > 0 then
        doc:Line(string.format("Full clears: %d, fastest %s, average %s.", clears, ns.Duration(fastest),
            ns.Duration(clearTime / clears)))
    end
    doc:Line("Time spent inside: " .. ns.Duration(inside))
    doc:Line(string.format("Bosses defeated: %d%s", bosses,
        wipes > 0 and string.format(", with %d %s", wipes, wipes == 1 and "wipe" or "wipes") or ""))
    if kills > 0 then doc:Line("Creatures slain: " .. ns.Number(kills)) end
    if xp > 0 then doc:Line("Experience gained: " .. ns.Number(xp)) end
    if money > 0 then doc:Line("Coin gathered: " .. ns.Money(money)) end
    if deaths > 0 then doc:Line("Your deaths: " .. deaths, UI.ACCENT) end

    -- Every boss in journal order (then any it doesn't list), with your record against each.
    local journal = ns.JournalBosses(journalID)
    local names, listed = {}, {}
    for _, name in ipairs(journal or {}) do
        names[#names + 1] = name
        listed[name] = true
    end
    for _, name in ipairs(bossOrder) do
        if not listed[name] then names[#names + 1] = name end
    end
    if #names > 0 then
        doc:Heading("Bosses")
        for _, name in ipairs(names) do
            local b = bossStats[name]
            if b then
                local extra = { "slain x" .. b.kills }
                if b.fastest then extra[#extra + 1] = "fastest " .. ns.Short(b.fastest) end
                if b.wipes > 0 then extra[#extra + 1] = b.wipes .. (b.wipes == 1 and " wipe" or " wipes") end
                doc:Check(name .. "  |cff6b5d4f(" .. table.concat(extra, ", ") .. ")|r", true, UI.INK)
            else
                doc:Check(name .. "  |cff6b5d4f(never beaten)|r", false, UI.FADED)
            end
        end
    end

    local regulars = TopCounts(friends, 8)
    if #regulars > 0 then
        doc:Heading("Companions")
        for _, e in ipairs(regulars) do
            doc:Line(ClassInk(friendClass[e.k]) .. e.k .. "|r"
                .. (e.n > 1 and string.format("  |cff6b5d4fx%d runs|r", e.n) or ""))
        end
    end

    local slain = TopCounts(mobs, 12)
    if #slain > 0 then
        doc:Heading("Creatures slain inside")
        for _, e in ipairs(slain) do doc:Line(string.format("%s  x%d", UI.MobLink(e.k, MobName(e.k)), e.n)) end
    end

    if #lootOrder > 0 then
        doc:Heading("Treasures (" .. #lootOrder .. ")")
        for k = #lootOrder, math.max(1, #lootOrder - 24), -1 do
            local link = lootOrder[k]
            doc:Item(link, loot[link] > 1 and ("x" .. loot[link]) or nil)
        end
        if #lootOrder > 25 then doc:Faded("...and older finds; see each run.") end
    end

    doc:Heading("Runs")
    for k = #runs, 1, -1 do
        local run = runs[k]
        doc:Line(string.format("%s  |cff6b5d4f%s  ·  %s  ·  %s|r", date("%d %b %Y", run.start),
            run.difficulty or "", ns.Duration(ns.RunDuration(run)), BossText(run)))
    end
    doc:Finish()
end
