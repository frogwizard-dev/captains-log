local _, ns = ...
local UI = ns.UI

local Page = { label = "Log", color = { 0.55, 0.12, 0.08 }, order = 1 }
ns.Pages.log = Page

local CLASSIFICATION = { rare = "rare", rareelite = "rare elite", elite = "elite", worldboss = "boss" }

function Page:Build(left, right)
    local W, H = ns.Book.CONTENT_W, ns.Book.CONTENT_H
    self.sub = ns.Book:Header(left, "Captain's Log")
    self.view = "timeline"

    -- Summary (the day in numbers), Timeline (the day line by line) or its Pictures.
    self.viewButtons = {}
    for i, v in ipairs({ { "summary", "Summary" }, { "timeline", "Timeline" }, { "photos", "Pictures" } }) do
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
    label:SetText("Your notes")
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
    local camera = UI.Button(right, "Take a picture", 120, 20)
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
    self.sub:SetText(string.format("%s, level %d %s  ·  %d %s, %s played",
        UnitName("player"), UnitLevel("player"), UnitClass("player"), days, days == 1 and "day" or "days",
        ns.Duration(played)))

    local items = {}
    for _, key in ipairs(keys) do
        local d = ns.db.days[key]
        items[#items + 1] = {
            key = key,
            left = date("%a %d %b %Y", ns.DayTime(key)),
            right = string.format("%s  ·  %d kills", ns.Duration(d.played), d.kills),
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
    if not name then return "an unknown creature" end
    if UNIQUE[classification] then return name end
    return (name:match("^[AEIOUaeiou]") and "an " or "a ") .. name
end

local function JoinList(parts)
    if #parts <= 1 then return parts[1] or "" end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

local function LootText(loot)
    local parts = {}
    for _, l in ipairs(loot) do
        local link = l.link or select(2, C_Item.GetItemInfo(l.itemID)) or ("item " .. l.itemID)
        parts[#parts + 1] = l.qty .. " " .. UI.Ink(link)
    end
    return JoinList(parts)
end

local WRITERS = {
    kill = function(ev)
        local tag = UNIQUE[ev.classification] and " (rare)" or (ev.classification == "elite" and " (elite)" or "")
        -- Kills in dungeons are logged before the creature has a name; the bestiary fills it in later.
        local mob = ns.db.mobs[ev.id]
        local name = ev.name or (mob and mob.name)
        local s
        if ev.n == 1 then
            s = "Slew " .. Called(name, ev.classification) .. tag
            if ev.loot then s = s .. " and took " .. LootText(ev.loot) .. " from it" end
        else
            s = string.format("Slew %s x%d%s", name or "unknown creatures", ev.n, tag)
            if ev.loot then s = s .. ", taking " .. LootText(ev.loot) end
        end
        return s .. "."
    end,
    meet = function(ev)
        return "Encountered " .. JoinList(ev.names) .. " for the first time."
    end,
    zone = function(ev)
        if ev.new then return "Set foot in " .. ev.zone .. " for the first time." end
        return "Travelled to " .. ev.zone .. "."
    end,
    place = function(ev)
        return "Came upon " .. JoinList(ev.places) .. " in " .. ev.zone .. "."
    end,
    accept = function(ev)
        return string.format('Accepted "%s".', ev.title or ("quest #" .. ev.questID))
    end,
    abandon = function(ev)
        return string.format('Abandoned "%s".', ev.title or ("quest #" .. ev.questID))
    end,
    quest = function(ev)
        local rewards = {}
        if ev.xp and ev.xp > 0 then rewards[#rewards + 1] = "+" .. ns.Number(ev.xp) .. " xp" end
        if ev.money and ev.money > 0 then rewards[#rewards + 1] = ns.Money(ev.money) end
        local s = string.format('Completed "%s"', ev.title or ("quest #" .. ev.questID))
        if #rewards > 0 then s = s .. " (" .. table.concat(rewards, ", ") .. ")" end
        return s .. "."
    end,
    level = function(ev)
        return "|cff7a1f0dReached level " .. ev.level .. "!|r"
    end,
    death = function(ev)
        if ev.killer then return "|cff7a1f0dWas slain by " .. Called(ev.killer, ev.classification) .. ".|r" end
        return "|cff7a1f0dDied.|r"
    end,
    dungeon = function(ev)
        if ev.returning then return "Returned to " .. ev.name .. "." end
        local s = "Entered " .. ev.name
        if ev.difficulty and ev.difficulty ~= "" then s = s .. " (" .. ev.difficulty .. ")" end
        if ev.group and #ev.group > 0 then s = s .. " with " .. JoinList(ev.group) end
        return s .. "."
    end,
    dungeonLeave = function(ev)
        local bosses = ev.total and string.format("%d/%d bosses", ev.bosses, ev.total)
            or (ev.bosses .. (ev.bosses == 1 and " boss" or " bosses"))
        return string.format("Left %s after %s, %s down.", ev.name, ns.Duration(ev.duration), bosses)
    end,
    boss = function(ev)
        local s = "|cff7a1f0dDefeated " .. ev.name .. "|r"
        if ev.duration then s = s .. " in " .. ns.Short(ev.duration) end
        if ev.wipes and ev.wipes > 0 then
            s = s .. string.format(" after %d %s", ev.wipes, ev.wipes == 1 and "wipe" or "wipes")
        end
        return s .. "!"
    end,
    wipe = function(ev)
        return "The group wiped on " .. ev.name .. "."
    end,
    npc = function(ev)
        return "Met " .. ev.name .. (ev.title and (", " .. ev.title) or "") .. "."
    end,
    photo = function(ev, key)
        local p = ns.FindPhoto(ev.photoT)
        if not p then return nil end -- removed from the journal
        local where = ev.place or ev.zone
        local s = "Took " .. UI.Link("a picture", "photos", key) .. (where and (" at " .. where) or "")
        if p.caption then s = s .. ': "' .. p.caption .. '"' end
        return s .. "."
    end,
}

function Page:RenderTimeline(key)
    local d = ns.Day(key)
    local doc = self.doc
    doc:Clear("timeline:" .. key)
    doc:Title(date("%A, %d %B %Y", ns.DayTime(key)))
    if #d.events == 0 then
        doc:Faded("Nothing written for this day yet.")
    end
    for _, ev in ipairs(d.events) do
        local write = WRITERS[ev.k]
        local line = write and write(ev, key)
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
    doc:Title(date("%A, %d %B %Y", ns.DayTime(key)))

    doc:Line("Played " .. ns.Duration(d.played))
    if d.xp > 0 then doc:Line("Experience gained: " .. ns.Number(d.xp)) end
    if d.kills > 0 then doc:Line("Creatures slain: " .. ns.Number(d.kills)) end
    if d.discovered > 0 then doc:Line("New bestiary entries: " .. d.discovered) end
    if d.moneyIn > 0 then doc:Line("Coin earned: " .. ns.Money(d.moneyIn)) end
    if d.moneyOut > 0 then doc:Line("Coin spent: " .. ns.Money(d.moneyOut)) end

    if #d.levels > 0 then
        doc:Heading("Milestones")
        for _, level in ipairs(d.levels) do
            local info = ns.db.levels[level]
            doc:Line("Reached level " .. level .. (info and info.zone and (" in " .. info.zone) or ""))
        end
    end

    local runs = {}
    for _, run in ipairs(ns.db.runs) do
        if date("%Y-%m-%d", run.start) == key then runs[#runs + 1] = run end
    end
    if #runs > 0 then
        doc:Heading("Dungeons & raids")
        for _, run in ipairs(runs) do
            doc:Line(string.format("%s: %s, %s", run.name, ns.Duration(ns.RunDuration(run)), ns.RunBossText(run)))
        end
    end

    if #d.zones > 0 then
        doc:Heading("New lands")
        for _, zone in ipairs(d.zones) do doc:Line(zone) end
    end

    if #d.quests > 0 then
        doc:Heading("Quests completed (" .. #d.quests .. ")")
        for _, questID in ipairs(d.quests) do
            local q = ns.db.quests[questID]
            doc:Line(q and q.title or ("Quest #" .. questID))
        end
    end

    local notable = {}
    for _, n in pairs(d.notable) do notable[#notable + 1] = n end
    if #notable > 0 then
        table.sort(notable, function(a, b) return a.first < b.first end)
        doc:Heading("Notable foes")
        for _, n in ipairs(notable) do
            local what = CLASSIFICATION[n.classification] or n.classification
            doc:Line(string.format("%s (%s)%s", n.name or "?", what, n.count > 1 and ("  x" .. n.count) or ""))
        end
    end

    if #d.loot > 0 then
        doc:Heading("Treasures")
        for _, item in ipairs(d.loot) do doc:Item(item.link) end
    end

    if #d.deaths > 0 then
        doc:Heading("Deaths")
        for _, death in ipairs(d.deaths) do
            doc:Line(string.format("%s at level %d%s", death.killer and ("Slain by " .. death.killer) or "Died",
                death.level or 0, death.zone and (" in " .. death.zone) or ""), UI.ACCENT)
        end
    end

    if d.played < 60 and d.kills == 0 and #d.quests == 0 then
        doc:Gap()
        doc:Faded("A quiet day. The pages are still blank.")
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
    text = "A caption for this picture:",
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
    text = "Take this picture out of the journal?\nThe screenshot file itself stays where it is.",
    button1 = REMOVE or "Remove", button2 = CANCEL,
    OnAccept = function(_, photo)
        local _, key, i = ns.FindPhoto(photo.t)
        if key then table.remove(ns.db.days[key].photos, i) end
        if photo.file then ns.db.photoRemoved[photo.file] = true end -- not brought back by an import
        ns.Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

local function Where(p)
    if p.place and p.zone and p.place ~= p.zone then return p.place .. ", " .. p.zone end
    return p.place or p.zone or "somewhere"
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
        self.doc:PlacePicture(path, (p.caption or Where(p)) .. "  -  " .. date("%d %b %Y, %H:%M", p.t),
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
        { "Caption", icon = "Interface\\Icons\\INV_Inscription_Pigment_Bug01", tip = { "Caption", "Write a line about this picture." },
            onClick = function() StaticPopup_Show("CAPTAINSLOG_CAPTION", nil, nil, p) end },
    }
    if pending then
        table.insert(actions, { "Reload", icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
            tip = { "Reload", "The game only notices new pictures when the interface loads; this reloads it (/reload)." },
            onClick = ReloadUI })
    end
    -- Only worth a button when there's a picture to swap with.
    if hasMap and path then
        table.insert(actions, { self.mapOpen[p.t] and "Picture" or "Where", icon = "Interface\\Icons\\INV_Misc_Map_01",
            tip = self.mapOpen[p.t] and { "Picture", "Back to the picture." }
                or { "Where it was taken", "Shows a close-up map in place of the picture, with a cone for the way you were facing." },
            onClick = function()
                self.mapOpen[p.t] = not self.mapOpen[p.t]
                self:Render()
            end })
    end
    table.insert(actions, { "Remove", icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
        tip = { "Remove", "Take this picture out of the journal (the screenshot file stays)." },
        onClick = function() StaticPopup_Show("CAPTAINSLOG_REMOVE_PHOTO", nil, nil, p) end })
    doc:Row(p.caption and ('"' .. p.caption .. '"') or "|cff6b5d4fNo caption yet|r", actions)

    if pending then doc:Text("New picture: it shows after a /reload.", 11, UI.ACCENT, nil, 8) end
    if p.imported then
        doc:Faded(date("%H:%M", p.t) .. ", from your Screenshots folder (taken before the book kept cards)")
    else
        doc:Faded(string.format("%s, %s, at level %d", date("%H:%M", p.t), where, p.level or 0))
        if p.group then doc:Faded("With " .. table.concat(p.group, ", ")) end
        if p.target then doc:Faded("Looking at " .. p.target) end
    end
    doc:Faded("File: Screenshots\\" .. p.file)
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
            doc:Label(date("%H:%M", p.t) .. (new and "  new: /reload to see it" or (p.caption and ("  " .. p.caption) or "")),
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
    doc:Heading("See the pictures themselves", {
        { "How?", icon = "Interface\\Icons\\INV_Misc_Note_01", tip = { "How to set up pictures",
            "The steps, and the folder to open, in a small window." },
            onClick = function() ns.ShowPictureSetup() end },
        { "It's set up", icon = "Interface\\RaidFrame\\ReadyCheck-Ready", tip = { "Show the pictures",
            "Once you've run the setup, this shows your screenshots in the book. (Also in Settings.)" },
            onClick = function()
                ns.db.settings.photosShow = true
                ns.Refresh()
            end },
    })
    doc:Line("The book can show your screenshots, but the game only reads files inside its own "
        .. "folders. One step, once ever, links your Screenshots folder in:")
    doc:Faded("1. Open the game's folder, then Interface\\AddOns\\CaptainsLog.")
    doc:Faded("2. Double-click \"Set up pictures.bat\".")
    doc:Faded("3. Press \"It's set up\". New pictures then show after a /reload.")
end

function Page:RenderPhotos(key)
    local d = ns.Day(key)
    local doc = self.doc
    doc:Clear("photos:" .. key)
    ns.Book:BackLink(doc)
    doc:Title(date("%A, %d %B %Y", ns.DayTime(key)))
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
        actions[#actions + 1] = { "Reload", icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
            tip = { "Reload", "The game only notices new pictures when the interface loads; this reloads it (/reload)." },
            onClick = ReloadUI }
    end
    if #photos > 0 then
        actions[#actions + 1] = { grid and "List" or "Grid", icon = grid and "Interface\\Icons\\INV_Misc_Note_02" or "Interface\\Icons\\INV_Misc_Map_01",
            tip = grid and { "List", "One picture under another, with its details and buttons." }
                or { "Grid", "Two pictures to a row, to see more at once." },
            onClick = function()
                ns.db.settings.photoView = grid and "list" or "grid"
                self:Render()
            end }
    end
    doc:Heading("Pictures (" .. #photos .. ")", actions)
    if new > 0 then
        doc:Text(("%d new picture%s since the interface loaded: /reload (or press Reload) to see %s.")
            :format(new, new == 1 and "" or "s", new == 1 and "it" or "them"), 11, UI.ACCENT, nil, 8)
    end
    if #photos == 0 then
        doc:Faded("No pictures this day. Press \"Take a picture\" below, or your screenshot key: every screenshot is added.")
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
        doc:Faded("Missing older screenshots? Double-click \"Set up pictures.bat\" in the add-on's folder "
            .. "again, then /reload: it brings in any the book doesn't have.")
    end
    doc:Finish()
end
