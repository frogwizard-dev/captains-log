local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Log"], color = { 0.55, 0.12, 0.08 }, order = 1 }
ns.Pages.log = Page

local CLASSIFICATION = { rare = L["rare"], rareelite = L["rare elite"], elite = L["elite"], worldboss = L["boss"] }

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sub = ns.Book:Header(left, L["Captain's Log"])
    self.view = "timeline"

    -- Summary (the day in numbers), Timeline (the day line by line) or its Pictures.
    self.viewButtons = {}
    for i, v in ipairs({ { "summary", L["Summary"] }, { "timeline", L["Timeline"] }, { "photos", L["Pictures"] } }) do
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

    self.doc = UI.Doc(right, W, H - 110)
    self.doc.sf:SetPoint("TOPLEFT")

    -- Your own words for the day, saved as you type.
    local label = UI.Text(right, 14, UI.ACCENT, UI.HEADING_FONT)
    label:SetPoint("BOTTOMLEFT", 0, 84)
    label:SetText(L["Your notes"])
    local box = CreateFrame("Frame", nil, right, "BackdropTemplate")
    box:SetPoint("BOTTOMLEFT")
    box:SetPoint("BOTTOMRIGHT")
    box:SetHeight(80)
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    box:SetBackdropColor(1, 1, 1, 0.18)
    box:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.3)
    local note = CreateFrame("EditBox", nil, box)
    note:SetMultiLine(true)
    note:SetAutoFocus(false)
    note:SetFont(UI.BODY_FONT, 12, "")
    note:SetTextColor(UI.INK[1], UI.INK[2], UI.INK[3])
    note:SetPoint("TOPLEFT", 6, -6)
    note:SetPoint("BOTTOMRIGHT", -6, 6)
    note:SetMaxLetters(2000)
    note:SetScript("OnEscapePressed", note.ClearFocus)
    note:SetScript("OnTextChanged", function(eb, userInput)
        if userInput and self.selected then
            ns.Day(self.selected).note = eb:GetText()
        end
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() note:SetFocus() end)
    self.note = note

    -- A picture for today's page (the book steps out of shot); see Photos.lua.
    local camera = UI.Button(right, L["Take a picture"], 120, 20)
    camera:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, 3)
    camera:SetScript("OnClick", function()
        self.view = "photos"
        self.selected = ns.Today()
        ns.TakePicture()
    end)
end

-- Arriving by a link: "photos:<day>" opens that day's pictures; a day opens its timeline.
function Page:Reveal(sel)
    local day = type(sel) == "string" and sel:match("^photos:(.+)$")
    if day then
        self.view, self.selected = "photos", day
    else
        self.selected = sel
    end
    if self.list then self.list.revealKey = self.selected end
end

local function DayTotals()
    local n, played = 0, 0
    for _, d in pairs(ns.db.days) do
        n = n + 1
        played = played + d.played
    end
    return n, played
end

function Page:Render()
    local keys = {}
    for key in pairs(ns.db.days) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return a > b end)
    if not self.selected or not ns.db.days[self.selected] then
        self.selected = keys[1] or ns.Today()
    end

    local days, played = DayTotals()
    self.sub:SetText(string.format(L["%s, level %d %s  ·  %d %s, %s played"],
        ns.FullName("player"), UnitLevel("player"), UnitClass("player"), days, days == 1 and L["day"] or L["days"],
        ns.Duration(played)))

    local items = {}
    for _, key in ipairs(keys) do
        local d = ns.db.days[key]
        items[#items + 1] = {
            key = key,
            left = date(L["%a %d %b %Y"], ns.DayTime(key)),
            right = string.format(L["%s  ·  %d kills"], ns.Duration(d.played), d.kills),
        }
    end
    self.list:SetItems(items, self.selected, function(key)
        self.selected = key
        self:Render()
    end)

    for view, b in pairs(self.viewButtons) do
        if view == self.view then b:LockHighlight() else b:UnlockHighlight() end
    end
    if self.view == "timeline" then
        self:RenderTimeline(self.selected)
    elseif self.view == "photos" then
        self:RenderPhotos(self.selected)
    else
        self:RenderDay(self.selected)
    end
    if not self.note:HasFocus() then
        self.note:SetText(ns.Day(self.selected).note or "")
    end
end

------------------------------------------------------------------------------
-- Timeline: each event written as a sentence
------------------------------------------------------------------------------

local UNIQUE = { rare = true, rareelite = true, worldboss = true }

-- "a Cursed Darkhound", "an Ogre", but "Hogger" for rares and bosses (they're named).
local function Called(name, classification)
    if not name then return L["an unknown creature"] end
    if UNIQUE[classification] then return name end
    return (name:match("^[AEIOUaeiou]") and L["an %s"] or L["a %s"]):format(name)
end

local function JoinList(parts)
    if #parts <= 1 then return parts[1] or "" end
    return L["%s and %s"]:format(table.concat(parts, ", ", 1, #parts - 1), parts[#parts])
end

local function LootText(loot)
    local parts = {}
    for _, l in ipairs(loot) do
        local link = l.link or select(2, C_Item.GetItemInfo(l.itemID)) or L["item %s"]:format(l.itemID)
        parts[#parts + 1] = l.qty .. " " .. UI.Ink(link)
    end
    return JoinList(parts)
end

-- A catch's name from the fishing journal (or the item cache, if the journal was erased).
local function CatchName(id)
    local e = ns.FishingData().items[id]
    return (e and e.name) or C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or L["item %s"]:format(id)
end

-- "Caught 12 fish at Auberdine, Darkshore (9 Raw Brilliant Smallfish, 2 ... and 1 ...), among
-- them your first Firefin Snapper." The three commonest catches are named.
local function FishText(ev)
    local places = {}
    for _, p in ipairs(ev.places or {}) do
        if p ~= ev.zone then places[#places + 1] = p end
    end
    local where = #places > 0 and L["at %s, %s"]:format(JoinList(places), ev.zone) or L["in %s"]:format(ev.zone)
    local catch = {}
    for _, c in ipairs(ev.catch or {}) do catch[#catch + 1] = c end
    table.sort(catch, function(a, b) return a[2] > b[2] end)
    local firsts = ev.firsts or {}
    if #catch == 1 and ev.n == 1 then
        -- A single catch: "Caught a Firefin Snapper at ..., your first."
        local id = catch[1][1]
        local name = CatchName(id)
        local vowel = name:match("^[AEIOUaeiou]")
        if firsts[1] == id then
            return (vowel and L["Caught an %s %s, your first."] or L["Caught a %s %s, your first."]):format(UI.FishLink(id, name), where)
        end
        return (vowel and L["Caught an %s %s."] or L["Caught a %s %s."]):format(name, where)
    end
    local parts = {}
    for i = 1, math.min(3, #catch) do parts[i] = catch[i][2] .. " " .. CatchName(catch[i][1]) end
    if #catch > 3 then parts[#parts + 1] = (#catch == 4 and L["%d other kind"] or L["%d other kinds"]):format(#catch - 3) end
    local s = string.format(L["Caught %d fish %s (%s)"], ev.n, where, JoinList(parts))
    if #firsts > 0 then
        -- Up to four named; a first day at the water would otherwise list everything twice.
        local links = {}
        for i = 1, math.min(4, #firsts) do links[i] = UI.FishLink(firsts[i], CatchName(firsts[i])) end
        if #firsts > 4 then links[#links + 1] = L["%d more"]:format(#firsts - 4) end
        s = L["%s, among them your first %s"]:format(s, JoinList(links))
    end
    return s .. "."
end

-- A learned spell: its link (or name) from the game, or the name written down at the time.
local function Try(fn, ...)
    if not fn then return end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end

local function SpellText(ev)
    if ev.id then
        local link = Try(C_Spell and C_Spell.GetSpellLink, ev.id) or Try(GetSpellLink, ev.id)
        if type(link) == "string" and not ns.issecret(link) then return UI.Ink(link) end
        local name = Try(C_Spell and C_Spell.GetSpellName, ev.id) or Try(GetSpellInfo, ev.id)
        if type(name) == "string" and not ns.issecret(name) then return name end
    end
    return ev.name or L["a new spell"]
end

-- "Honored", "Friendly": the game's own words for a reputation tier (1-8).
local function Standing(n)
    return (n and _G["FACTION_STANDING_LABEL" .. n]) or L["standing %s"]:format(tostring(n or "?"))
end

-- "1st", "1,000th" on English clients; other languages put the number in their own sentence.
local function Ordinal(n)
    n = n or 0
    if ns.locale ~= "enUS" and ns.locale ~= "enGB" then return ns.Number(n) end
    if n == 1 then return L["first"] end
    local suffix = "th"
    local last2, last = n % 100, n % 10
    if last2 < 11 or last2 > 13 then
        suffix = ({ [1] = "st", [2] = "nd", [3] = "rd" })[last] or "th"
    end
    return ns.Number(n) .. suffix
end

-- Milestones, one sentence per tally ("Your 1,000th kill!").
local MILESTONES = {
    kills = L["Your %s kill!"], deaths = L["Your %s death."], quests = L["Your %s quest done!"],
    looted = L["Your %s item looted!"], crafted = L["Your %s item made!"], flights = L["Your %s flight!"],
    hearths = L["Your %s trip home by hearthstone."], fish = L["Your %s fish caught!"],
    dungeons = L["Your %s dungeon!"], bosses = L["Your %s boss defeated!"],
    duelsWon = L["Your %s duel won!"], duelsLost = L["Your %s duel lost."],
}

local WRITERS = {
    kill = function(ev)
        local tag = UNIQUE[ev.classification] and L[" (rare)"] or (ev.classification == "elite" and L[" (elite)"] or "")
        -- Kills in dungeons are logged before the creature has a name; the bestiary fills it in later.
        local mob = ns.db.mobs[ev.id]
        local name = ev.name or (mob and mob.name)
        local s
        if ev.n == 1 then
            s = L["Slew %s%s"]:format(Called(name, ev.classification), tag)
            if ev.loot then s = L["%s and took %s from it"]:format(s, LootText(ev.loot)) end
        else
            s = string.format(L["Slew %s x%d%s"], name or L["unknown creatures"], ev.n, tag)
            if ev.loot then s = L["%s, taking %s"]:format(s, LootText(ev.loot)) end
        end
        return s .. "."
    end,
    meet = function(ev)
        return L["Encountered %s for the first time."]:format(JoinList(ev.names))
    end,
    zone = function(ev)
        if ev.new then return L["Set foot in %s for the first time."]:format(ev.zone) end
        return L["Travelled to %s."]:format(ev.zone)
    end,
    place = function(ev)
        return L["Came upon %s in %s."]:format(JoinList(ev.places), ev.zone)
    end,
    accept = function(ev)
        return string.format(L['Accepted "%s".'], ev.title or L["quest #%s"]:format(ev.questID))
    end,
    abandon = function(ev)
        return string.format(L['Abandoned "%s".'], ev.title or L["quest #%s"]:format(ev.questID))
    end,
    quest = function(ev)
        local rewards = {}
        if ev.xp and ev.xp > 0 then rewards[#rewards + 1] = L["+%s xp"]:format(ns.Number(ev.xp)) end
        if ev.money and ev.money > 0 then rewards[#rewards + 1] = ns.Money(ev.money) end
        local s = string.format(L['Completed "%s"'], ev.title or L["quest #%s"]:format(ev.questID))
        if #rewards > 0 then s = s .. " (" .. table.concat(rewards, ", ") .. ")" end
        return s .. "."
    end,
    -- "Reached level 12! 1d 3h played; level 11 took 2h 14m. See yourself then"
    level = function(ev)
        local s = "|cff7a1f0d" .. L["Reached level %s!"]:format(ev.level) .. "|r"
        local rec = ns.db.levels[ev.level]
        local prev = ns.db.levels[ev.level - 1]
        local parts = {}
        if rec and rec.played then parts[#parts + 1] = L["%s played"]:format(UI.LongDuration(rec.played)) end
        if prev and prev.spent then parts[#parts + 1] = L["level %d took %s"]:format(ev.level - 1, ns.Duration(prev.spent)) end
        if #parts > 0 then s = s .. " |cff6b5d4f" .. table.concat(parts, "; ") .. ".|r" end
        if rec and rec.snap then s = s .. " " .. UI.Link(L["See yourself then"], "level", ev.level) end
        return s
    end,
    equip = function(ev)
        if ev.old then
            return L["Equipped %s, replacing %s."]:format(UI.ItemLink(ev.id), UI.ItemLink(ev.old))
        end
        return L["Equipped %s."]:format(UI.ItemLink(ev.id))
    end,
    spell = function(ev)
        return L["Learned %s."]:format(SpellText(ev))
    end,
    rep = function(ev)
        local standing = Standing(ev.standing)
        if ev.old and ev.standing and ev.standing < ev.old then
            return L["Fell to %s with %s."]:format(standing, ev.name or "?")
        end
        return "|cff7a1f0d" .. L["Now %s with %s."]:format(standing, ev.name or "?") .. "|r"
    end,
    skill = function(ev)
        if ev.new then return L["Took up %s."]:format(ev.name or "?") end
        return L["Reached %s in %s."]:format(ev.rank or "?", ev.name or "?")
    end,
    guild = function(ev)
        local g = "<" .. (ev.name or "?") .. ">"
        if ev.action == "join" then return "|cff7a1f0d" .. L["Joined the guild %s."]:format(g) .. "|r" end
        if ev.action == "leave" then return L["Left the guild %s."]:format(g) end
        if not ev.rank then return L["Your rank changed in %s."]:format(g) end
        return (ev.up and L["Promoted to %s in %s."] or L["Demoted to %s in %s."]):format(ev.rank, g)
    end,
    duel = function(ev)
        if ev.won then return L["Won a duel against %s."]:format(ev.vs or "?") end
        return L["Lost a duel to %s."]:format(ev.vs or "?")
    end,
    firstitem = function(ev)
        return L["Your first %s."]:format(UI.ItemLink(ev.id, ev.q))
    end,
    milestone = function(ev)
        local fmt = MILESTONES[ev.stat]
        if fmt then return "|cff7a1f0d" .. fmt:format(Ordinal(ev.n)) .. "|r" end
        return "|cff7a1f0d" .. L["Milestone: %s, %s."]:format(ns.StatName(ev.stat), ns.Number(ev.n or 0)) .. "|r"
    end,
    death = function(ev)
        if ev.killer then return "|cff7a1f0d" .. L["Was slain by %s."]:format(Called(ev.killer, ev.classification)) .. "|r" end
        return "|cff7a1f0d" .. L["Died."] .. "|r"
    end,
    dungeon = function(ev)
        if ev.returning then return L["Returned to %s."]:format(ev.name) end
        local s = L["Entered %s"]:format(ev.name)
        if ev.difficulty and ev.difficulty ~= "" then s = s .. " (" .. ev.difficulty .. ")" end
        if ev.group and #ev.group > 0 then s = L["%s with %s"]:format(s, JoinList(ev.group)) end
        return s .. "."
    end,
    dungeonLeave = function(ev)
        local bosses = ev.total and string.format(L["%d/%d bosses"], ev.bosses, ev.total)
            or (ev.bosses == 1 and L["%d boss"] or L["%d bosses"]):format(ev.bosses)
        return string.format(L["Left %s after %s, %s down."], ev.name, ns.Duration(ev.duration), bosses)
    end,
    boss = function(ev)
        local s = "|cff7a1f0d" .. L["Defeated %s"]:format(ev.name) .. "|r"
        if ev.duration then s = L["%s in %s"]:format(s, ns.Short(ev.duration)) end
        if ev.wipes and ev.wipes > 0 then
            s = s .. string.format(L[" after %d %s"], ev.wipes, ev.wipes == 1 and L["wipe"] or L["wipes"])
        end
        return s .. "!"
    end,
    wipe = function(ev)
        return L["The group wiped on %s."]:format(ev.name)
    end,
    npc = function(ev)
        return ev.title and L["Met %s, %s."]:format(ev.name, ev.title) or L["Met %s."]:format(ev.name)
    end,
    fish = FishText,
    fishskill = function(ev)
        return "|cff7a1f0d" .. L["Your fishing skill reached %s!"]:format(ev.rank) .. "|r"
    end,
    photo = function(ev, key)
        local p = ns.FindPhoto(ev.photoT)
        if not p then return nil end -- removed from the journal
        local where = ev.place or ev.zone
        local link = UI.Link(L["a picture"], "photos", key)
        local s = where and L["Took %s at %s"]:format(link, where) or L["Took %s"]:format(link)
        if p.caption then s = s .. ': "' .. p.caption .. '"' end
        return s .. "."
    end,
    gather = function(ev)
        local what = (ev.n or 1) .. " " .. UI.ItemLink(ev.id)
        local fmt = ({ herb = L["Picked %s."], ore = L["Mined %s."], skin = L["Skinned %s."], fish = L["Fished up %s."] })[ev.what]
        return (fmt or L["Gathered %s."]):format(what)
    end,
    taxi = function(ev)
        local took = ns.Duration(ev.s or 0)
        if ev.from then return L["Flew from %s to %s in %s."]:format(ev.from, ev.to or "?", took) end
        return L["Flew to %s in %s."]:format(ev.to or "?", took)
    end,
    hearth = function(ev)
        if ev.from and ev.to then return L["Hearthed from %s home to %s."]:format(ev.from, ev.to) end
        return L["Hearthed home to %s."]:format(ev.to or "?")
    end,
    mount = function()
        return "|cff7a1f0d" .. L["Rode a mount for the first time!"] .. "|r"
    end,
    transport = function(ev)
        return L["Crossed by boat or zeppelin from %s to %s."]:format(ev.from or "?", ev.to or "?")
    end,
    closecall = function(ev)
        if ev.vs then return "|cff7a1f0d" .. L["A close call against %s: down to %d%% health."]:format(ev.vs, ev.pct or 0) .. "|r" end
        return "|cff7a1f0d" .. L["A close call: down to %d%% health."]:format(ev.pct or 0) .. "|r"
    end,
    rest = function(ev)
        return L["Rested at the inn in %s."]:format(ev.place or "?")
    end,
    visit = function(ev)
        if ev.kind == "mail" then
            return ev.place and L["Checked the mail in %s."]:format(ev.place) or L["Checked the mail."]
        end
        if ev.kind == "trainer" then return L["Trained with %s."]:format(ev.name or "?") end
        return L["Traded with %s."]:format(ev.name or "?")
    end,
    restedgone = function()
        return L["Your rested experience ran out."]
    end,
}

-- The sentence for one timeline entry (or nil), for the journey map's tooltips too.
function ns.LogLine(ev, key)
    local write = WRITERS[ev.k]
    if not write then return end
    local ok, line = pcall(write, ev, key)
    if ok then return line end
end

function Page:RenderTimeline(key)
    local d = ns.Day(key)
    local doc = self.doc
    doc:Clear("timeline:" .. key)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    if #d.events == 0 then
        doc:Faded(L["Nothing written for this day yet."])
    end
    if d.path and #d.path > 0 and ns.JourneyMap then
        doc:Row("|cff6b5d4f" .. L["Your route this day is on the journey map."] .. "|r", {
            { L["Show on map"], icon = "Interface\\Icons\\INV_Misc_Map_01",
                tip = { L["Journey map"], L["Plays this day back on your world map: your route, and where each thing in the log happened."] },
                onClick = function() ns.JourneyMap.Show(key) end },
        })
    end
    for _, ev in ipairs(d.events) do
        local line = ns.LogLine(ev, key)
        if line then
            doc:Text("|cff8a6d4a" .. date("%H:%M", ev.t) .. "|r   " .. line, 12)
        end
    end
    doc:Finish()
    if key == ns.Today() then doc:ScrollToEnd() end
end

function Page:RenderDay(key)
    local d = ns.Day(key)
    local doc = self.doc
    doc:Clear("summary:" .. key)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))

    doc:Line(L["Played %s"]:format(ns.Duration(d.played)))
    if d.xp > 0 then doc:Line(L["Experience gained: %s"]:format(ns.Number(d.xp))) end
    if d.kills > 0 then doc:Line(L["Creatures slain: %s"]:format(ns.Number(d.kills))) end
    if d.discovered > 0 then doc:Line(L["New bestiary entries: %s"]:format(d.discovered)) end
    if (d.fish or 0) > 0 then doc:Line(L["Fish caught: %s"]:format(ns.Number(d.fish))) end
    if d.moneyIn > 0 then doc:Line(L["Coin earned: %s"]:format(ns.Money(d.moneyIn))) end
    if d.moneyOut > 0 then doc:Line(L["Coin spent: %s"]:format(ns.Money(d.moneyOut))) end

    if #d.levels > 0 then
        doc:Heading(L["Milestones"])
        for _, level in ipairs(d.levels) do
            local info = ns.db.levels[level]
            doc:Line(info and info.zone and L["Reached level %s in %s"]:format(level, info.zone) or L["Reached level %s"]:format(level))
        end
    end

    local runs = {}
    for _, run in ipairs(ns.db.runs) do
        if date("%Y-%m-%d", run.start) == key then runs[#runs + 1] = run end
    end
    if #runs > 0 then
        doc:Heading(L["Dungeons & raids"])
        for _, run in ipairs(runs) do
            doc:Line(string.format("%s: %s, %s", run.name, ns.Duration(ns.RunDuration(run)), ns.RunBossText(run)))
        end
    end

    if #d.zones > 0 then
        doc:Heading(L["New lands"])
        for _, zone in ipairs(d.zones) do doc:Line(zone) end
    end

    if #d.quests > 0 then
        doc:Heading(L["Quests completed (%d)"]:format(#d.quests))
        for _, questID in ipairs(d.quests) do
            local q = ns.db.quests[questID]
            doc:Line(q and q.title or L["Quest #%s"]:format(questID))
        end
    end

    local notable = {}
    for _, n in pairs(d.notable) do notable[#notable + 1] = n end
    if #notable > 0 then
        table.sort(notable, function(a, b) return a.first < b.first end)
        doc:Heading(L["Notable foes"])
        for _, n in ipairs(notable) do
            local what = CLASSIFICATION[n.classification] or n.classification
            doc:Line(string.format("%s (%s)%s", n.name or "?", what, n.count > 1 and ("  x" .. n.count) or ""))
        end
    end

    if #d.loot > 0 then
        doc:Heading(L["Treasures"])
        for _, item in ipairs(d.loot) do doc:Item(item.link) end
    end

    if #d.deaths > 0 then
        doc:Heading(L["Deaths"])
        for _, death in ipairs(d.deaths) do
            doc:Line(string.format(L["%s at level %d%s"], death.killer and L["Slain by %s"]:format(death.killer) or L["Died"],
                death.level or 0, death.zone and L[" in %s"]:format(death.zone) or ""), UI.ACCENT)
        end
    end

    if d.played < 60 and d.kills == 0 and #d.quests == 0 then
        doc:Gap()
        doc:Faded(L["A quiet day. The pages are still blank."])
    end
    doc:Finish()
end

------------------------------------------------------------------------------
-- Pictures: the day's photo cards (Photos.lua)
------------------------------------------------------------------------------

local function EditBoxOf(dialog)
    return (dialog.GetEditBox and dialog:GetEditBox()) or dialog.editBox or dialog.EditBox
end

StaticPopupDialogs.CAPTAINSLOG_CAPTION = {
    text = L["A caption for this picture:"],
    button1 = ACCEPT, button2 = CANCEL,
    hasEditBox = true, maxLetters = 140, enterClicksFirstButton = true,
    OnShow = function(dialog, photo)
        local eb = EditBoxOf(dialog)
        if eb then
            eb:SetText(photo and photo.caption or "")
            eb:HighlightText()
        end
    end,
    OnAccept = function(dialog, photo)
        local eb = EditBoxOf(dialog)
        local text = eb and strtrim(eb:GetText() or "") or ""
        photo.caption = text ~= "" and text or nil
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

StaticPopupDialogs.CAPTAINSLOG_REMOVE_PHOTO = {
    text = L["Take this picture out of the journal?\nThe screenshot file itself stays where it is."],
    button1 = REMOVE or L["Remove"], button2 = CANCEL,
    OnAccept = function(_, photo)
        local _, key, i = ns.FindPhoto(photo.t)
        if key then table.remove(ns.db.days[key].photos, i) end
        if photo.file then ns.db.photoRemoved[photo.file] = true end -- not brought back by an import
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function Where(p)
    if p.place and p.zone and p.place ~= p.zone then return L["%s, %s"]:format(p.place, p.zone) end
    return p.place or p.zone or L["somewhere"]
end

-- The spot a picture was taken, for its close-up map: the pin and, if known, the view cone.
local function Spot(p)
    return { p.x, p.y, kind = "place", label = Where(p), facing = p.facing, fov = p.fov }
end

-- What fills a picture's frame: the picture, or the close-up map when "Where" is pressed (or
-- when there's no picture to show). Draws it at x, y, w wide.
function Page:PhotoFrame(p, x, y, w)
    local path = ns.PhotoTexture(p)
    -- Taken since the interface loaded: the game can't show it until a /reload.
    if path and ns.PhotoPending(p) then path = nil end
    local hasMap = p.mapID and p.x
    if hasMap and (self.mapOpen[p.t] or not path) then
        -- Clicking it marks the spot (and the way you faced) on the world map.
        self.doc:PlaceSpotMap(p.mapID, Spot(p), x, y, w, function() ns.MapPins.Show("photo", p.t, p.mapID) end)
        return true
    elseif path then
        self.doc:PlacePicture(path, (p.caption or Where(p)) .. "  -  " .. date(L["%d %b %Y, %H:%M"], p.t),
            ns.PhotoAspect(p), x, y, w)
        return true
    end
    return false
end

-- One picture in the list: its frame (picture or map, swapped in place by "Where"), its
-- caption with buttons, and what was going on.
function Page:PhotoCard(p)
    local doc = self.doc
    local where = Where(p)
    local path = ns.PhotoTexture(p)
    local pending = path and ns.PhotoPending(p)
    if pending then path = nil end
    local hasMap = p.mapID and p.x
    local w = doc.width - 8
    if self:PhotoFrame(p, 8, doc.y, w) then doc:Gap(w / 2 + 6) end
    local actions = {
        { L["Caption"], icon = "Interface\\Icons\\INV_Inscription_Pigment_Bug01", tip = { L["Caption"], L["Write a line about this picture."] },
            onClick = function() StaticPopup_Show("CAPTAINSLOG_CAPTION", nil, nil, p) end },
    }
    if pending then
        table.insert(actions, { L["Reload"], icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
            tip = { L["Reload"], L["The game only notices new pictures when the interface loads; this reloads it (/reload)."] },
            onClick = ReloadUI })
    end
    -- Only worth a button when there's a picture to swap with.
    if hasMap and path then
        table.insert(actions, { self.mapOpen[p.t] and L["Picture"] or L["Where"], icon = "Interface\\Icons\\INV_Misc_Map_01",
            tip = self.mapOpen[p.t] and { L["Picture"], L["Back to the picture."] }
                or { L["Where it was taken"], L["Shows a close-up map in place of the picture, with a cone for the way you were facing."] },
            onClick = function()
                self.mapOpen[p.t] = not self.mapOpen[p.t]
                self:Render()
            end })
    end
    table.insert(actions, { L["Remove"], icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
        tip = { L["Remove"], L["Take this picture out of the journal (the screenshot file stays)."] },
        onClick = function() StaticPopup_Show("CAPTAINSLOG_REMOVE_PHOTO", nil, nil, p) end })
    doc:Row(p.caption and ('"' .. p.caption .. '"') or "|cff6b5d4f" .. L["No caption yet"] .. "|r", actions)

    if pending then doc:Text(L["New picture: it shows after a /reload."], 11, UI.ACCENT, nil, 8) end
    if p.imported then
        doc:Faded(L["%s, from your Screenshots folder (taken before the book kept cards)"]:format(date("%H:%M", p.t)))
    else
        doc:Faded(string.format(L["%s, %s, at level %d"], date("%H:%M", p.t), where, p.level or 0))
        if p.group then doc:Faded(L["With %s"]:format(table.concat(p.group, ", "))) end
        if p.target then doc:Faded(L["Looking at %s"]:format(p.target)) end
    end
    doc:Faded(L["File: Screenshots\\%s"]:format(p.file))
end

-- The day's pictures two to a row, each with its time and caption beneath; click one to see
-- it whole (a map cell opens the world map). Details and buttons are in the list view.
local GRID_GAP = 8
function Page:PhotoGrid(photos)
    local doc = self.doc
    local w = (doc.width - 8 - GRID_GAP) / 2
    local cellH = w / 2 + 18
    local col = 0
    for i = #photos, 1, -1 do
        local p = photos[i]
        local x = 8 + col * (w + GRID_GAP)
        if self:PhotoFrame(p, x, doc.y, w) then
            local new = ns.db.settings.photosShow and ns.PhotoPending(p)
            doc:Label(date("%H:%M", p.t) .. (new and ("  " .. L["new: /reload to see it"]) or (p.caption and ("  " .. p.caption) or "")),
                x, doc.y + w / 2 + 3, w, new and UI.ACCENT or nil)
            col = col + 1
            if col == 2 then
                col = 0
                doc:Gap(cellH)
            end
        end
    end
    if col == 1 then doc:Gap(cellH) end
end

-- Until pictures are set up: what the one step is, and a button to say it's done.
function Page:PhotoSetup()
    local doc = self.doc
    doc:Heading(L["See the pictures themselves"], {
        { L["How?"], icon = "Interface\\Icons\\INV_Misc_Note_01", tip = { L["How to set up pictures"],
            L["The steps, and the folder to open, in a small window."] },
            onClick = function() ns.ShowPictureSetup() end },
        { L["It's set up"], icon = "Interface\\RaidFrame\\ReadyCheck-Ready", tip = { L["Show the pictures"],
            L["Once you've run the setup, this shows your screenshots in the book. (Also in Settings.)"] },
            onClick = function()
                ns.db.settings.photosShow = true
                ns.Refresh()
            end },
    })
    doc:Line(L["The book can show your screenshots, but the game only reads files inside its own folders. One step, once ever, links your Screenshots folder in:"])
    doc:Faded(L["1. Press \"How?\" for the link to download \"Set up pictures.bat\"."])
    doc:Faded(L["2. Put it in the game's Interface\\AddOns\\CaptainsLog folder and double-click it."])
    doc:Faded(L["3. Press \"It's set up\". New pictures then show after a /reload."])
end

function Page:RenderPhotos(key)
    local d = ns.Day(key)
    local doc = self.doc
    doc:Clear("photos:" .. key)
    ns.Book:BackLink(doc)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    local photos = d.photos or {}
    self.mapOpen = self.mapOpen or {}
    if not ns.db.settings.photosShow then self:PhotoSetup() end
    local grid = ns.db.settings.photoView == "grid"
    local new = 0
    if ns.db.settings.photosShow then
        for _, p in ipairs(photos) do
            if ns.PhotoPending(p) then new = new + 1 end
        end
    end
    local actions = {}
    if new > 0 then
        actions[#actions + 1] = { L["Reload"], icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
            tip = { L["Reload"], L["The game only notices new pictures when the interface loads; this reloads it (/reload)."] },
            onClick = ReloadUI }
    end
    if #photos > 0 then
        actions[#actions + 1] = { grid and L["List"] or L["Grid"], icon = grid and "Interface\\Icons\\INV_Misc_Note_02" or "Interface\\Icons\\INV_Misc_Map_01",
            tip = grid and { L["List"], L["One picture under another, with its details and buttons."] }
                or { L["Grid"], L["Two pictures to a row, to see more at once."] },
            onClick = function()
                ns.db.settings.photoView = grid and "list" or "grid"
                self:Render()
            end }
    end
    doc:Heading(L["Pictures (%d)"]:format(#photos), actions)
    if new > 0 then
        doc:Text((new == 1 and L["%d new picture since the interface loaded: /reload (or press Reload) to see it."]
            or L["%d new pictures since the interface loaded: /reload (or press Reload) to see them."]):format(new), 11, UI.ACCENT, nil, 8)
    end
    if #photos == 0 then
        doc:Faded(L["No pictures this day. Press \"Take a picture\" below, or your screenshot key: every screenshot is added."])
    end
    -- Newest first.
    if grid then
        doc:Gap(4)
        self:PhotoGrid(photos)
    else
        for i = #photos, 1, -1 do
            doc:Gap(4)
            self:PhotoCard(photos[i])
        end
    end
    if ns.db.settings.photosShow then
        doc:Gap(8)
        doc:Faded(L["Missing older screenshots? Double-click \"Set up pictures.bat\" in the add-on's folder again (Settings > Set up pictures... has the download), then /reload: it brings in any the book doesn't have."])
    end
    doc:Finish()
end
