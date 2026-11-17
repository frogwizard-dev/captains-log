local _, ns = ...
local L = ns.L
local UI = ns.UI

local Page = { label = L["Log"], color = { 0.55, 0.12, 0.08 }, order = 1 }
ns.Pages.log = Page

local CLASSIFICATION = { rare = L["rare"], rareelite = L["rare elite"], elite = L["elite"], worldboss = L["boss"] }

function Page:Build(left, right)
    local width, height = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.subtitle = ns.Book:Header(left, L["Captain's Log"])
    self.view = "timeline"

    -- Summary (the day in numbers), Timeline (the day line by line) or its Pictures.
    self.viewButtons = {}
    for i, view in ipairs({ { "summary", L["Summary"] }, { "timeline", L["Timeline"] }, { "photos", L["Pictures"] } }) do
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

    self.doc = UI.Doc(right, width, height - 110)
    self.doc.scroll:SetPoint("TOPLEFT")

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
    note:SetScript("OnTextChanged", function(editBox, userInput)
        if userInput and self.selected then
            ns.Day(self.selected).note = editBox:GetText()
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
function Page:Reveal(selected)
    local day = type(selected) == "string" and selected:match("^photos:(.+)$")
    if day then
        self.view, self.selected = "photos", day
    else
        self.selected = selected
    end
    if self.list then self.list.revealKey = self.selected end
end

local function DayTotals()
    local count, played = 0, 0
    for _, day in pairs(ns.db.days) do
        count = count + 1
        played = played + day.played
    end
    return count, played
end

function Page:Render()
    local keys = {}
    for key in pairs(ns.db.days) do keys[#keys + 1] = key end
    table.sort(keys, function(first, second) return first > second end)
    if not self.selected or not ns.db.days[self.selected] then
        self.selected = keys[1] or ns.Today()
    end

    local days, played = DayTotals()
    self.subtitle:SetText(string.format(L["%s, level %d %s  ·  %d %s, %s played"],
        ns.FullName("player"), UnitLevel("player"), UnitClass("player"), days, days == 1 and L["day"] or L["days"],
        ns.Duration(played)))

    local items = {}
    for _, key in ipairs(keys) do
        local day = ns.db.days[key]
        items[#items + 1] = {
            key = key,
            left = date(L["%a %d %b %Y"], ns.DayTime(key)),
            right = string.format(L["%s  ·  %d kills"], ns.Duration(day.played), day.kills),
        }
    end
    self.list:SetItems(items, self.selected, function(key)
        self.selected = key
        self:Render()
    end)

    for view, button in pairs(self.viewButtons) do
        if view == self.view then button:LockHighlight() else button:UnlockHighlight() end
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
    for _, drop in ipairs(loot) do
        local link = drop.link or select(2, C_Item.GetItemInfo(drop.itemID)) or L["item %s"]:format(drop.itemID)
        parts[#parts + 1] = drop.qty .. " " .. UI.Ink(link)
    end
    return JoinList(parts)
end

-- A catch's name from the fishing journal (or the item cache, if the journal was erased).
local function CatchName(id)
    local catch = ns.FishingJournal().items[id]
    return (catch and catch.name) or C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or L["item %s"]:format(id)
end

-- "Caught 12 fish at Auberdine, Darkshore (9 Raw Brilliant Smallfish, 2 ... and 1 ...), among
-- them your first Firefin Snapper." The three commonest catches are named.
local function FishText(entry)
    local places = {}
    for _, place in ipairs(entry.places or {}) do
        if place ~= entry.zone then places[#places + 1] = place end
    end
    local where = #places > 0 and L["at %s, %s"]:format(JoinList(places), entry.zone) or L["in %s"]:format(entry.zone)
    local catch = {}
    for _, caught in ipairs(entry.catch or {}) do catch[#catch + 1] = caught end
    table.sort(catch, function(first, second) return first[2] > second[2] end)
    local firsts = entry.firsts or {}
    if #catch == 1 and entry.n == 1 then
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
    local sentence = string.format(L["Caught %d fish %s (%s)"], entry.n, where, JoinList(parts))
    if #firsts > 0 then
        -- Up to four named; a first day at the water would otherwise list everything twice.
        local links = {}
        for i = 1, math.min(4, #firsts) do links[i] = UI.FishLink(firsts[i], CatchName(firsts[i])) end
        if #firsts > 4 then links[#links + 1] = L["%d more"]:format(#firsts - 4) end
        sentence = L["%s, among them your first %s"]:format(sentence, JoinList(links))
    end
    return sentence .. "."
end

-- A learned spell: its link (or name) from the game, or the name written down at the time.
local function SpellText(entry)
    if entry.id then
        local link = ns.Call(C_Spell and C_Spell.GetSpellLink, entry.id) or ns.Call(GetSpellLink, entry.id)
        if type(link) == "string" and not ns.issecret(link) then return UI.Ink(link) end
        local name = ns.Call(C_Spell and C_Spell.GetSpellName, entry.id) or ns.Call(GetSpellInfo, entry.id)
        if type(name) == "string" and not ns.issecret(name) then return name end
    end
    return entry.name or L["a new spell"]
end

-- "Honored", "Friendly": the game's own words for a reputation tier (1-8).
local function Standing(tier)
    return (tier and _G["FACTION_STANDING_LABEL" .. tier]) or L["standing %s"]:format(tostring(tier or "?"))
end

local GATHERED = { herb = L["Picked %s."], ore = L["Mined %s."], skin = L["Skinned %s."], fish = L["Fished up %s."] }

local WRITERS = {
    kill = function(entry)
        local tag = UNIQUE[entry.classification] and L[" (rare)"] or (entry.classification == "elite" and L[" (elite)"] or "")
        -- Kills in dungeons are logged before the creature has a name; the bestiary fills it in later.
        local mob = ns.db.mobs[entry.id]
        local name = entry.name or (mob and mob.name)
        local sentence
        if entry.n == 1 then
            sentence = L["Slew %s%s"]:format(Called(name, entry.classification), tag)
            if entry.loot then sentence = L["%s and took %s from it"]:format(sentence, LootText(entry.loot)) end
        else
            sentence = string.format(L["Slew %s x%d%s"], name or L["unknown creatures"], entry.n, tag)
            if entry.loot then sentence = L["%s, taking %s"]:format(sentence, LootText(entry.loot)) end
        end
        return sentence .. "."
    end,
    meet = function(entry)
        return L["Encountered %s for the first time."]:format(JoinList(entry.names))
    end,
    zone = function(entry)
        if entry.new then return L["Set foot in %s for the first time."]:format(entry.zone) end
        return L["Travelled to %s."]:format(entry.zone)
    end,
    place = function(entry)
        return L["Came upon %s in %s."]:format(JoinList(entry.places), entry.zone)
    end,
    accept = function(entry)
        return string.format(L['Accepted "%s".'], entry.title or L["quest #%s"]:format(entry.questID))
    end,
    abandon = function(entry)
        return string.format(L['Abandoned "%s".'], entry.title or L["quest #%s"]:format(entry.questID))
    end,
    quest = function(entry)
        local rewards = {}
        if entry.xp and entry.xp > 0 then rewards[#rewards + 1] = L["+%s xp"]:format(ns.Number(entry.xp)) end
        if entry.money and entry.money > 0 then rewards[#rewards + 1] = ns.Money(entry.money) end
        local sentence = string.format(L['Completed "%s"'], entry.title or L["quest #%s"]:format(entry.questID))
        if #rewards > 0 then sentence = sentence .. " (" .. table.concat(rewards, ", ") .. ")" end
        return sentence .. "."
    end,
    -- "Reached level 12! 1d 3h played; level 11 took 2h 14m. See yourself then"
    level = function(entry)
        local sentence = "|cff7a1f0d" .. L["Reached level %s!"]:format(entry.level) .. "|r"
        local record = ns.db.levels[entry.level]
        local previous = ns.db.levels[entry.level - 1]
        local parts = {}
        if record and record.played then parts[#parts + 1] = L["%s played"]:format(UI.LongDuration(record.played)) end
        if previous and previous.spent then
            parts[#parts + 1] = L["level %d took %s"]:format(entry.level - 1, ns.Duration(previous.spent))
        end
        if #parts > 0 then sentence = sentence .. " |cff6b5d4f" .. table.concat(parts, "; ") .. ".|r" end
        if record and record.snap then sentence = sentence .. " " .. UI.Link(L["See yourself then"], "level", entry.level) end
        return sentence
    end,
    equip = function(entry)
        if entry.old then
            return L["Equipped %s, replacing %s."]:format(UI.ItemLink(entry.id), UI.ItemLink(entry.old))
        end
        return L["Equipped %s."]:format(UI.ItemLink(entry.id))
    end,
    spell = function(entry)
        return L["Learned %s."]:format(SpellText(entry))
    end,
    rep = function(entry)
        local standing = Standing(entry.standing)
        if entry.old and entry.standing and entry.standing < entry.old then
            return L["Fell to %s with %s."]:format(standing, entry.name or "?")
        end
        return "|cff7a1f0d" .. L["Now %s with %s."]:format(standing, entry.name or "?") .. "|r"
    end,
    skill = function(entry)
        if entry.new then return L["Took up %s."]:format(entry.name or "?") end
        return L["Reached %s in %s."]:format(entry.rank or "?", entry.name or "?")
    end,
    guild = function(entry)
        local guild = "<" .. (entry.name or "?") .. ">"
        if entry.action == "join" then return "|cff7a1f0d" .. L["Joined the guild %s."]:format(guild) .. "|r" end
        if entry.action == "leave" then return L["Left the guild %s."]:format(guild) end
        if not entry.rank then return L["Your rank changed in %s."]:format(guild) end
        return (entry.up and L["Promoted to %s in %s."] or L["Demoted to %s in %s."]):format(entry.rank, guild)
    end,
    duel = function(entry)
        if entry.won then return L["Won a duel against %s."]:format(entry.vs or "?") end
        return L["Lost a duel to %s."]:format(entry.vs or "?")
    end,
    firstitem = function(entry)
        return L["Your first %s."]:format(UI.ItemLink(entry.id, entry.q))
    end,
    milestone = function(entry)
        local words = ns.MilestoneSaying and ns.MilestoneSaying(entry.stat, entry.n) or tostring(entry.n)
        return "|cff7a1f0d" .. words .. "|r"
    end,
    death = function(entry)
        if entry.killer then
            return "|cff7a1f0d" .. L["Was slain by %s."]:format(Called(entry.killer, entry.classification)) .. "|r"
        end
        return "|cff7a1f0d" .. L["Died."] .. "|r"
    end,
    dungeon = function(entry)
        if entry.returning then return L["Returned to %s."]:format(entry.name) end
        local sentence = L["Entered %s"]:format(entry.name)
        if entry.difficulty and entry.difficulty ~= "" then sentence = sentence .. " (" .. entry.difficulty .. ")" end
        if entry.group and #entry.group > 0 then sentence = L["%s with %s"]:format(sentence, JoinList(entry.group)) end
        return sentence .. "."
    end,
    dungeonLeave = function(entry)
        local bosses = entry.total and string.format(L["%d/%d bosses"], entry.bosses, entry.total)
            or (entry.bosses == 1 and L["%d boss"] or L["%d bosses"]):format(entry.bosses)
        return string.format(L["Left %s after %s, %s down."], entry.name, ns.Duration(entry.duration), bosses)
    end,
    boss = function(entry)
        local sentence = "|cff7a1f0d" .. L["Defeated %s"]:format(entry.name) .. "|r"
        if entry.duration then sentence = L["%s in %s"]:format(sentence, ns.Short(entry.duration)) end
        if entry.wipes and entry.wipes > 0 then
            sentence = sentence .. string.format(L[" after %d %s"], entry.wipes, entry.wipes == 1 and L["wipe"] or L["wipes"])
        end
        return sentence .. "!"
    end,
    wipe = function(entry)
        return L["The group wiped on %s."]:format(entry.name)
    end,
    npc = function(entry)
        return entry.title and L["Met %s, %s."]:format(entry.name, entry.title) or L["Met %s."]:format(entry.name)
    end,
    fish = FishText,
    fishskill = function(entry)
        return "|cff7a1f0d" .. L["Your fishing skill reached %s!"]:format(entry.rank) .. "|r"
    end,
    photo = function(entry, key)
        local photo = ns.FindPhoto(entry.photoT)
        if not photo then return nil end -- removed from the journal
        local where = entry.place or entry.zone
        local link = UI.Link(L["a picture"], "photos", key)
        local sentence = where and L["Took %s at %s"]:format(link, where) or L["Took %s"]:format(link)
        if photo.caption then sentence = sentence .. ': "' .. photo.caption .. '"' end
        return sentence .. "."
    end,
    gather = function(entry)
        local what = (entry.n or 1) .. " " .. UI.ItemLink(entry.id)
        return (GATHERED[entry.what] or L["Gathered %s."]):format(what)
    end,
    taxi = function(entry)
        local took = ns.Duration(entry.s or 0)
        if entry.from then return L["Flew from %s to %s in %s."]:format(entry.from, entry.to or "?", took) end
        return L["Flew to %s in %s."]:format(entry.to or "?", took)
    end,
    hearth = function(entry)
        if entry.from and entry.to then return L["Hearthed from %s home to %s."]:format(entry.from, entry.to) end
        return L["Hearthed home to %s."]:format(entry.to or "?")
    end,
    mount = function()
        return "|cff7a1f0d" .. L["Rode a mount for the first time!"] .. "|r"
    end,
    transport = function(entry)
        return L["Crossed by boat or zeppelin from %s to %s."]:format(entry.from or "?", entry.to or "?")
    end,
    closecall = function(entry)
        if entry.vs then
            return "|cff7a1f0d" .. L["A close call against %s: down to %d%% health."]:format(entry.vs, entry.pct or 0) .. "|r"
        end
        return "|cff7a1f0d" .. L["A close call: down to %d%% health."]:format(entry.pct or 0) .. "|r"
    end,
    rest = function(entry)
        return L["Rested at the inn in %s."]:format(entry.place or "?")
    end,
    visit = function(entry)
        if entry.kind == "mail" then
            return entry.place and L["Checked the mail in %s."]:format(entry.place) or L["Checked the mail."]
        end
        if entry.kind == "trainer" then return L["Trained with %s."]:format(entry.name or "?") end
        return L["Traded with %s."]:format(entry.name or "?")
    end,
    restedgone = function()
        return L["Your rested experience ran out."]
    end,
}

-- The sentence for one timeline entry (or nil), for the journey map's tooltips too.
function ns.LogLine(entry, key)
    local Write = WRITERS[entry.k]
    if not Write then return end
    local ok, line = pcall(Write, entry, key)
    if ok then return line end
end

function Page:RenderTimeline(key)
    local day = ns.Day(key)
    local doc = self.doc
    doc:Clear("timeline:" .. key)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    if #day.events == 0 then
        doc:Faded(L["Nothing written for this day yet."])
    end
    if day.path and #day.path > 0 and ns.JourneyMap then
        doc:Row("|cff6b5d4f" .. L["Your route this day can be played back."] .. "|r", {
            { L["Play your journey"], icon = "Interface\\Icons\\INV_Misc_Map_01",
                tip = { L["Journey"], L["Plays this day back in the Journey window: your route, and where each thing in the log happened."] },
                onClick = function() ns.JourneyMap.Show(key) end },
        })
    end
    for _, entry in ipairs(day.events) do
        local line = ns.LogLine(entry, key)
        if line then
            doc:Text("|cff8a6d4a" .. date("%H:%M", entry.t) .. "|r   " .. line, 12)
        end
    end
    doc:Finish()
    if key == ns.Today() then doc:ScrollToEnd() end
end

function Page:RenderDay(key)
    local day = ns.Day(key)
    local doc = self.doc
    doc:Clear("summary:" .. key)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))

    doc:Line(L["Played %s"]:format(ns.Duration(day.played)))
    if day.xp > 0 then doc:Line(L["Experience gained: %s"]:format(ns.Number(day.xp))) end
    if day.kills > 0 then doc:Line(L["Creatures slain: %s"]:format(ns.Number(day.kills))) end
    if day.discovered > 0 then doc:Line(L["New bestiary entries: %s"]:format(day.discovered)) end
    if (day.fish or 0) > 0 then doc:Line(L["Fish caught: %s"]:format(ns.Number(day.fish))) end
    if (day.jumps or 0) > 0 then
        local total = ns.db.stats and ns.db.stats.jumps
        doc:Line(total and L["Jumps: %s (%s in all)"]:format(ns.Number(day.jumps), ns.Number(total))
            or L["Jumps: %s"]:format(ns.Number(day.jumps)))
    end
    if day.moneyIn > 0 then doc:Line(L["Coin earned: %s"]:format(ns.Money(day.moneyIn))) end
    if day.moneyOut > 0 then doc:Line(L["Coin spent: %s"]:format(ns.Money(day.moneyOut))) end

    if #day.levels > 0 then
        doc:Heading(L["Milestones"])
        for _, level in ipairs(day.levels) do
            local record = ns.db.levels[level]
            doc:Line(record and record.zone and L["Reached level %s in %s"]:format(level, record.zone)
                or L["Reached level %s"]:format(level))
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

    if #day.zones > 0 then
        doc:Heading(L["New lands"])
        for _, zone in ipairs(day.zones) do doc:Line(zone) end
    end

    if #day.quests > 0 then
        doc:Heading(L["Quests completed (%d)"]:format(#day.quests))
        for _, questID in ipairs(day.quests) do
            local quest = ns.db.quests[questID]
            doc:Line(quest and quest.title or L["Quest #%s"]:format(questID))
        end
    end

    local notable = {}
    for _, foe in pairs(day.notable) do notable[#notable + 1] = foe end
    if #notable > 0 then
        table.sort(notable, function(first, second) return first.first < second.first end)
        doc:Heading(L["Notable foes"])
        for _, foe in ipairs(notable) do
            local what = CLASSIFICATION[foe.classification] or foe.classification
            doc:Line(string.format("%s (%s)%s", foe.name or "?", what, foe.count > 1 and ("  x" .. foe.count) or ""))
        end
    end

    if #day.loot > 0 then
        doc:Heading(L["Treasures"])
        for _, item in ipairs(day.loot) do doc:Item(item.link) end
    end

    if #day.deaths > 0 then
        doc:Heading(L["Deaths"])
        for _, death in ipairs(day.deaths) do
            doc:Line(string.format(L["%s at level %d%s"], death.killer and L["Slain by %s"]:format(death.killer) or L["Died"],
                death.level or 0, death.zone and L[" in %s"]:format(death.zone) or ""), UI.ACCENT)
        end
    end

    if day.played < 60 and day.kills == 0 and #day.quests == 0 then
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
        local box = EditBoxOf(dialog)
        if box then
            box:SetText(photo and photo.caption or "")
            box:HighlightText()
        end
    end,
    OnAccept = function(dialog, photo)
        local box = EditBoxOf(dialog)
        local text = box and strtrim(box:GetText() or "") or ""
        photo.caption = text ~= "" and text or nil
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

StaticPopupDialogs.CAPTAINSLOG_REMOVE_PHOTO = {
    text = L["Take this picture out of the journal?\nThe screenshot file itself stays where it is."],
    button1 = REMOVE or L["Remove"], button2 = CANCEL,
    OnAccept = function(_, photo)
        local _, key, index = ns.FindPhoto(photo.t)
        if key then table.remove(ns.db.days[key].photos, index) end
        if photo.file then ns.db.photoRemoved[photo.file] = true end -- not brought back by an import
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function Where(photo)
    if photo.place and photo.zone and photo.place ~= photo.zone then return L["%s, %s"]:format(photo.place, photo.zone) end
    return photo.place or photo.zone or L["somewhere"]
end

-- The spot a picture was taken, for its close-up map: the pin and, if known, the view cone.
local function Spot(photo)
    return { photo.x, photo.y, kind = "place", label = Where(photo), facing = photo.facing, fov = photo.fov }
end

-- What fills a picture's frame: the picture, or the close-up map when "Where" is pressed (or
-- when there's no picture to show). Draws it at x, y, `width` wide.
function Page:PhotoFrame(photo, x, y, width)
    local path = ns.PhotoTexture(photo)
    -- Taken since the interface loaded: the game can't show it until a /reload.
    if path and ns.PhotoPending(photo) then path = nil end
    local hasMap = photo.mapID and photo.x
    if hasMap and (self.mapOpen[photo.t] or not path) then
        -- Clicking it marks the spot (and the way you faced) on the world map.
        self.doc:PlaceSpotMap(photo.mapID, Spot(photo), x, y, width,
            function() ns.MapPins.Show("photo", photo.t, photo.mapID) end)
        return true
    elseif path then
        self.doc:PlacePicture(path, (photo.caption or Where(photo)) .. "  ·  " .. date(L["%d %b %Y, %H:%M"], photo.t),
            ns.PhotoAspect(photo), x, y, width)
        return true
    end
    return false
end

local RELOAD_ACTION = { L["Reload"], icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
    tip = { L["Reload"], L["The game only notices new pictures when the interface loads; this reloads it (/reload)."] },
    onClick = ReloadUI }

-- One picture in the list: its frame (picture or map, swapped in place by "Where"), its
-- caption with buttons, and what was going on.
function Page:PhotoCard(photo)
    local doc = self.doc
    local where = Where(photo)
    local path = ns.PhotoTexture(photo)
    local pending = path and ns.PhotoPending(photo)
    if pending then path = nil end
    local hasMap = photo.mapID and photo.x
    local width = doc.width - 8
    if self:PhotoFrame(photo, 8, doc.y, width) then doc:Gap(width / 2 + 6) end
    local actions = {
        { L["Caption"], icon = "Interface\\Icons\\INV_Inscription_Pigment_Bug01",
            tip = { L["Caption"], L["Write a line about this picture."] },
            onClick = function() StaticPopup_Show("CAPTAINSLOG_CAPTION", nil, nil, photo) end },
    }
    if pending then table.insert(actions, RELOAD_ACTION) end
    -- Only worth a button when there's a picture to swap with.
    if hasMap and path then
        local open = self.mapOpen[photo.t]
        table.insert(actions, { open and L["Picture"] or L["Where"], icon = "Interface\\Icons\\INV_Misc_Map_01",
            tip = open and { L["Picture"], L["Back to the picture."] }
                or { L["Where it was taken"], L["Shows a close-up map in place of the picture, with a cone for the way you were facing."] },
            onClick = function()
                self.mapOpen[photo.t] = not self.mapOpen[photo.t]
                self:Render()
            end })
    end
    table.insert(actions, { L["Remove"], icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
        tip = { L["Remove"], L["Take this picture out of the journal (the screenshot file stays)."] },
        onClick = function() StaticPopup_Show("CAPTAINSLOG_REMOVE_PHOTO", nil, nil, photo) end })
    doc:Row(photo.caption and ('"' .. photo.caption .. '"') or "|cff6b5d4f" .. L["No caption yet"] .. "|r", actions)

    if pending then doc:Text(L["New picture: it shows after a /reload."], 11, UI.ACCENT, nil, 8) end
    if photo.imported then
        doc:Faded(L["%s, from your Screenshots folder (taken before the book kept cards)"]:format(date("%H:%M", photo.t)))
    else
        doc:Faded(string.format(L["%s, %s, at level %d"], date("%H:%M", photo.t), where, photo.level or 0))
        if photo.group then doc:Faded(L["With %s"]:format(table.concat(photo.group, ", "))) end
        if photo.target then doc:Faded(L["Looking at %s"]:format(photo.target)) end
    end
    doc:Faded(L["File: Screenshots\\%s"]:format(photo.file))
end

-- The day's pictures two to a row, each with its time and caption beneath; click one to see
-- it whole (a map cell opens the world map). Details and buttons are in the list view.
local GRID_GAP = 8
function Page:PhotoGrid(photos)
    local doc = self.doc
    local width = (doc.width - 8 - GRID_GAP) / 2
    local cellHeight = width / 2 + 18
    local column = 0
    for i = #photos, 1, -1 do
        local photo = photos[i]
        local x = 8 + column * (width + GRID_GAP)
        if self:PhotoFrame(photo, x, doc.y, width) then
            local new = ns.db.settings.photosShow and ns.PhotoPending(photo)
            local caption = new and ("  " .. L["new: /reload to see it"]) or (photo.caption and ("  " .. photo.caption) or "")
            doc:Label(date("%H:%M", photo.t) .. caption, x, doc.y + width / 2 + 3, width, new and UI.ACCENT or nil)
            column = column + 1
            if column == 2 then
                column = 0
                doc:Gap(cellHeight)
            end
        end
    end
    if column == 1 then doc:Gap(cellHeight) end
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
    local day = ns.Day(key)
    local doc = self.doc
    doc:Clear("photos:" .. key)
    ns.Book:BackLink(doc)
    doc:Title(date(L["%A, %d %B %Y"], ns.DayTime(key)))
    local photos = day.photos or {}
    self.mapOpen = self.mapOpen or {}
    if not ns.db.settings.photosShow then self:PhotoSetup() end
    local grid = ns.db.settings.photoView == "grid"
    local new = 0
    if ns.db.settings.photosShow then
        for _, photo in ipairs(photos) do
            if ns.PhotoPending(photo) then new = new + 1 end
        end
    end
    local actions = {}
    if new > 0 then actions[#actions + 1] = RELOAD_ACTION end
    if #photos > 0 then
        actions[#actions + 1] = { grid and L["List"] or L["Grid"],
            icon = grid and "Interface\\Icons\\INV_Misc_Note_02" or "Interface\\Icons\\INV_Misc_Map_01",
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
