local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Dungeons"], color = { 0.36, 0.18, 0.42 }, order = 5 }
ns.Pages.dungeons = Page

local ROLE = { TANK = L["tank"], HEALER = L["healer"], DAMAGER = L["damage dealer"] }
local ROLE_SHORT = { TANK = L["Tank"], HEALER = L["Healer"], DAMAGER = L["DPS"] }

local function BossText(run)
    if run.totalBosses then return string.format(L["%d/%d bosses"], #run.bosses, run.totalBosses) end
    return (#run.bosses == 1 and L["%d boss"] or L["%d bosses"]):format(#run.bosses)
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
function Page:Reveal(selected)
    if type(selected) == "string" then
        self.view, self.selectedInstance = "instances", selected
    else
        self.view, self.selected = "runs", selected
    end
    if self.list then self.list.revealKey = selected end
end

local function MobName(id)
    local mob = ns.db.mobs[id]
    if mob and mob.name then return mob.name end
    -- Counted by name alone (the game hid its ID): the key is "n:Name".
    local named = type(id) == "string" and id:match("^n:(.+)$")
    if named then return named end
    return (type(id) == "number" and ns.CreatureName(id)) or L["Unknown creature #%s"]:format(tostring(id))
end

-- A creature as a link to its bestiary entry, or its plain name if it has none yet.
local function Slain(id)
    if type(id) == "number" then return UI.MobLink(id, MobName(id)) end
    return MobName(id)
end

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.subtitle = ns.Book:Header(left, L["Dungeons & Raids"])
    self.view = "runs"

    -- Every run, newest first, or one entry per dungeon with its records across runs.
    self.viewButtons = {}
    for i, view in ipairs({ { "runs", L["Every run"] }, { "instances", L["By dungeon"] } }) do
        local button = UI.Button(left, view[2], 110)
        button:SetPoint("TOPLEFT", (i - 1) * 116, -62)
        button:SetScript("OnClick", function()
            self.view = view[1]
            self:Render()
        end)
        self.viewButtons[view[1]] = button
    end

    self.list = UI.List(left, width, height - 94)
    self.list.scroll:SetPoint("TOPLEFT", 0, -94)
    self.doc = UI.Doc(right, width, height)
    self.doc.scroll:SetPoint("TOPLEFT")
end

function Page:Render()
    local runs = ns.db.runs
    local bosses = 0
    for _, run in ipairs(runs) do bosses = bosses + #run.bosses end
    self.subtitle:SetText(string.format(#runs == 1 and L["%d run  ·  %d bosses defeated"] or L["%d runs  ·  %d bosses defeated"],
        #runs, bosses))
    for view, button in pairs(self.viewButtons) do
        if view == self.view then button:LockHighlight() else button:UnlockHighlight() end
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
            right = active and L["in progress"] or (date(L["%d %b"], run.start) .. "  ·  " .. ns.Duration(ns.RunDuration(run))),
            color = active and UI.ACCENT or nil,
        }
    end
    self.list:SetItems(items, self.selected, function(index)
        self.selected = index
        self:Render()
    end)
    self:RenderRun(self.selected)
end

-- The boss you'd most recently beaten when an item arrived (within two minutes of the kill).
local function LootSource(run, when)
    local source
    for _, boss in ipairs(run.bosses) do
        if boss.t <= when and when - boss.t < 120 then source = boss.name end
    end
    return source
end

-- Each boss the Encounter Journal lists, ticked when beaten; bosses it doesn't list follow.
function Page:RenderBosses(run, active)
    local doc = self.doc
    local journal = ns.JournalBosses(run.journalID)
    if not journal and #run.bosses == 0 then return end
    doc:Heading(L["Bosses"])
    local byName, listed = {}, {}
    for _, boss in ipairs(run.bosses) do byName[boss.name] = boss end

    local function Write(name, boss)
        if not boss then
            -- Not yet beaten: still to come while you're inside, missed once you've left.
            doc:Check(name, (not active) and false or nil, UI.FADED)
            return
        end
        local extra = { date("%H:%M", boss.t) }
        if boss.duration then extra[#extra + 1] = ns.Short(boss.duration) end
        if boss.wipes > 0 then extra[#extra + 1] = (boss.wipes == 1 and L["%d wipe first"] or L["%d wipes first"]):format(boss.wipes) end
        doc:Check(name .. "  |cff6b5d4f(" .. table.concat(extra, ", ") .. ")|r", true, UI.INK)
    end
    for _, name in ipairs(journal or {}) do
        listed[name] = true
        Write(name, byName[name])
    end
    for _, boss in ipairs(run.bosses) do
        if not listed[boss.name] then Write(boss.name, boss) end
    end
end

function Page:RenderRun(index)
    local doc = self.doc
    doc:Clear("run:" .. tostring(index))
    ns.Book:BackLink(doc)
    local run = index and ns.db.runs[index]
    if not run then
        doc:Title(L["No runs yet"])
        doc:Faded(L["Each time you enter a dungeon or raid, the run is written down here."])
        doc:Finish()
        return
    end

    doc:Title(run.name)
    local kind = strtrim(string.format("%s  %s", run.difficulty or "",
        run.size and run.size > 0 and L["· %d-player"]:format(run.size) or ""))
    if kind ~= "" then doc:Faded(kind) end
    doc:Gap(4)

    local active = ns.ActiveRun() == run
    local ended = run.finish or run.leftAt
    doc:Line(string.format(L["Entered %s at %s, at level %d%s."], ns.Date(run.start), date("%H:%M", run.start),
        run.level or 0, ROLE[run.role] and L[", as the %s"]:format(ROLE[run.role]) or ""))
    if active then
        doc:Line(L["In progress: %s so far."]:format(ns.Duration(ns.RunDuration(run))))
    elseif ended then
        doc:Line(string.format(L["Left at %s, after %s."], date("%H:%M", ended), ns.Duration(ns.RunDuration(run))))
    end
    local wipes = run.wipes > 0 and string.format(run.wipes == 1 and L[", %d wipe"] or L[", %d wipes"], run.wipes) or ""
    doc:Line(L["%s defeated%s."]:format(BossText(run), wipes))
    if FullClear(run) then doc:Line(L["A full clear."], UI.ACCENT) end
    if run.kills > 0 then doc:Line(L["Creatures slain: %s"]:format(ns.Number(run.kills))) end
    if (run.xp or 0) > 0 then doc:Line(L["Experience gained: %s"]:format(ns.Number(run.xp))) end
    if (run.money or 0) > 0 then doc:Line(L["Coin gathered: %s"]:format(ns.Money(run.money))) end
    if run.deaths > 0 then doc:Line(L["Your deaths: %s"]:format(run.deaths), UI.ACCENT) end

    self:RenderBosses(run, active)

    if #run.group > 0 then
        doc:Heading(L["Companions"])
        for _, member in ipairs(run.group) do
            doc:Line(UI.ClassInk(member.class) .. member.name .. "|r"
                .. (ROLE_SHORT[member.role] and ("  |cff6b5d4f" .. ROLE_SHORT[member.role] .. "|r") or ""))
        end
    end

    local mobs = {}
    for id, kills in pairs(run.mobs or {}) do mobs[#mobs + 1] = { id = id, n = kills } end
    if #mobs > 0 then
        table.sort(mobs, function(first, second) return first.n > second.n end)
        doc:Heading(L["Creatures slain inside"])
        for i = 1, math.min(#mobs, 12) do
            doc:Line(string.format("%s  x%d", Slain(mobs[i].id), mobs[i].n))
        end
    end

    if #run.loot > 0 then
        doc:Heading(L["Treasures"])
        for _, item in ipairs(run.loot) do
            local source = item.time and LootSource(run, item.time)
            doc:Item(item.link, source and L["from %s"]:format(source) or nil)
        end
    end

    -- Every run of this same instance, for comparison.
    local count, fastest = 0, nil
    for _, other in ipairs(ns.db.runs) do
        if InstanceKey(other) == InstanceKey(run) and other.difficulty == run.difficulty then
            count = count + 1
            if FullClear(other) then
                local duration = ns.RunDuration(other)
                if not fastest or duration < fastest then fastest = duration end
            end
        end
    end
    if count > 1 then
        doc:Gap(6)
        doc:Faded(string.format(L["You've run %s %d times%s. See \"By dungeon\" for its records."], run.name, count,
            fastest and L[", fastest full clear %s"]:format(ns.Duration(fastest)) or ""))
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
        local instance = byKey[key]
        if not instance then
            instance = { key = key, name = run.name, runs = {} }
            byKey[key] = instance
            list[#list + 1] = instance
        end
        table.insert(instance.runs, run)
    end
    table.sort(list, function(first, second) return first.runs[#first.runs].start > second.runs[#second.runs].start end)
    return list, byKey
end

function Page:RenderInstanceList()
    local list, byKey = Instances()
    if not self.selectedInstance or not byKey[self.selectedInstance] then
        self.selectedInstance = list[1] and list[1].key
    end
    local items = {}
    for _, instance in ipairs(list) do
        local clears = 0
        for _, run in ipairs(instance.runs) do
            if FullClear(run) then clears = clears + 1 end
        end
        items[#items + 1] = {
            key = instance.key,
            left = instance.name,
            right = string.format(#instance.runs == 1 and L["%d run%s"] or L["%d runs%s"], #instance.runs,
                clears > 0 and string.format(clears == 1 and L["  ·  %d clear"] or L["  ·  %d clears"], clears) or ""),
        }
    end
    self.list:SetItems(items, self.selectedInstance, function(key)
        self.selectedInstance = key
        self:Render()
    end)
    self:RenderInstance(byKey[self.selectedInstance])
end

-- The most counted keys, most first (ties by name), at most `limit`: { { key, count } }.
local function TopCounts(counts, limit)
    local list = {}
    for key, count in pairs(counts) do list[#list + 1] = { key = key, count = count } end
    table.sort(list, function(first, second)
        if first.count ~= second.count then return first.count > second.count end
        return tostring(first.key) < tostring(second.key)
    end)
    for i = #list, limit + 1, -1 do list[i] = nil end
    return list
end

function Page:RenderInstance(instance)
    local doc = self.doc
    doc:Clear("instance:" .. tostring(instance and instance.key))
    ns.Book:BackLink(doc)
    if not instance then
        doc:Title(L["No dungeons yet"])
        doc:Faded(L["Every dungeon and raid you enter gets its own page of records here."])
        doc:Finish()
        return
    end
    local runs = instance.runs
    doc:Title(instance.name)

    local difficulties, difficultyOrder = {}, {}
    local clears, fastest, clearTime = 0, nil, 0
    local inside, bosses, wipes, deaths, kills, xp, money = 0, 0, 0, 0, 0, 0, 0
    local journalID
    local bossStats, bossOrder = {}, {}
    local friends, mobs, loot, lootOrder = {}, {}, {}, {}
    local friendClass = {}

    local function Boss(name)
        local stats = bossStats[name]
        if not stats then
            stats = { kills = 0, wipes = 0 }
            bossStats[name] = stats
            bossOrder[#bossOrder + 1] = name
        end
        return stats
    end

    for _, run in ipairs(runs) do
        local difficulty = run.difficulty and run.difficulty ~= "" and run.difficulty or L["Normal"]
        if not difficulties[difficulty] then difficultyOrder[#difficultyOrder + 1] = difficulty end
        difficulties[difficulty] = (difficulties[difficulty] or 0) + 1
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
            local stats = Boss(boss.name)
            stats.kills = stats.kills + 1
            stats.wipes = stats.wipes + (boss.wipes or 0)
            if boss.duration and (not stats.fastest or boss.duration < stats.fastest) then stats.fastest = boss.duration end
        end
        for _, member in ipairs(run.group) do
            friends[member.name] = (friends[member.name] or 0) + 1
            friendClass[member.name] = member.class
        end
        for id, slain in pairs(run.mobs or {}) do mobs[id] = (mobs[id] or 0) + slain end
        for _, item in ipairs(run.loot) do
            if not loot[item.link] then lootOrder[#lootOrder + 1] = item.link end
            loot[item.link] = (loot[item.link] or 0) + 1
        end
    end

    local difficultyText = {}
    for _, name in ipairs(difficultyOrder) do
        difficultyText[#difficultyText + 1] = name .. (difficulties[name] > 1 and (" x" .. difficulties[name]) or "")
    end
    doc:Faded(table.concat(difficultyText, "  ·  "))
    doc:Gap(4)

    doc:Line(string.format(#runs == 1 and L["Run %d time: first %s, last %s."] or L["Run %d times: first %s, last %s."], #runs,
        ns.Date(runs[1].start), ns.Date(runs[#runs].start)))
    if clears > 0 then
        doc:Line(string.format(L["Full clears: %d, fastest %s, average %s."], clears, ns.Duration(fastest),
            ns.Duration(clearTime / clears)))
    end
    doc:Line(L["Time spent inside: %s"]:format(ns.Duration(inside)))
    doc:Line(string.format(L["Bosses defeated: %d%s"], bosses,
        wipes > 0 and string.format(wipes == 1 and L[", with %d wipe"] or L[", with %d wipes"], wipes) or ""))
    if kills > 0 then doc:Line(L["Creatures slain: %s"]:format(ns.Number(kills))) end
    if xp > 0 then doc:Line(L["Experience gained: %s"]:format(ns.Number(xp))) end
    if money > 0 then doc:Line(L["Coin gathered: %s"]:format(ns.Money(money))) end
    if deaths > 0 then doc:Line(L["Your deaths: %s"]:format(deaths), UI.ACCENT) end

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
        doc:Heading(L["Bosses"])
        for _, name in ipairs(names) do
            local stats = bossStats[name]
            if stats then
                local extra = { L["slain x%d"]:format(stats.kills) }
                if stats.fastest then extra[#extra + 1] = L["fastest %s"]:format(ns.Short(stats.fastest)) end
                if stats.wipes > 0 then extra[#extra + 1] = (stats.wipes == 1 and L["%d wipe"] or L["%d wipes"]):format(stats.wipes) end
                doc:Check(name .. "  |cff6b5d4f(" .. table.concat(extra, ", ") .. ")|r", true, UI.INK)
            else
                doc:Check(name .. L["  |cff6b5d4f(never beaten)|r"], false, UI.FADED)
            end
        end
    end

    local regulars = TopCounts(friends, 8)
    if #regulars > 0 then
        doc:Heading(L["Companions"])
        for _, friend in ipairs(regulars) do
            doc:Line(UI.ClassInk(friendClass[friend.key]) .. friend.key .. "|r"
                .. (friend.count > 1 and string.format(L["  |cff6b5d4fx%d runs|r"], friend.count) or ""))
        end
    end

    local slain = TopCounts(mobs, 12)
    if #slain > 0 then
        doc:Heading(L["Creatures slain inside"])
        for _, mob in ipairs(slain) do doc:Line(string.format("%s  x%d", Slain(mob.key), mob.count)) end
    end

    if #lootOrder > 0 then
        doc:Heading(L["Treasures (%d)"]:format(#lootOrder))
        for i = #lootOrder, math.max(1, #lootOrder - 24), -1 do
            local link = lootOrder[i]
            doc:Item(link, loot[link] > 1 and ("x" .. loot[link]) or nil)
        end
        if #lootOrder > 25 then doc:Faded(L["...and older finds; see each run."]) end
    end

    doc:Heading(L["Runs"])
    for i = #runs, 1, -1 do
        local run = runs[i]
        doc:Line(string.format("%s  |cff6b5d4f%s  ·  %s  ·  %s|r", date(L["%d %b %Y"], run.start),
            run.difficulty or "", ns.Duration(ns.RunDuration(run)), BossText(run)))
    end
    doc:Finish()
end
