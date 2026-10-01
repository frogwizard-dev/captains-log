local _, ns = ...
local UI = ns.UI

local Page = { label = "Settings", color = { 0.32, 0.28, 0.24 }, order = 6 }
ns.Pages.settings = Page

local QUALITIES = {
    { 0, "Poor and better" },
    { 1, "Common and better" },
    { 2, "Uncommon and better" },
    { 3, "Rare and better" },
    { 4, "Epic and better" },
}

function Page:Build(left, right)
    local s = ns.db.settings
    local sub = ns.Book:Header(left, "Settings")
    sub:SetText("How the log keeps its records")

    local y = -70
    local function place(w, h, x)
        w:SetPoint("TOPLEFT", x or 0, y)
        y = y - h
    end
    place(UI.Checkbox(left, "Show kill counts on creature tooltips",
        function() return s.tooltip end, function(v) s.tooltip = v end), 28)
    place(UI.Checkbox(left, "Announce new bestiary entries in chat",
        function() return s.announce end, function(v) s.announce = v end), 28)
    place(UI.Checkbox(left, "Kill debug messages (which signal counted it)",
        function() return s.debug end, function(v) s.debug = v end), 28)
    place(UI.Checkbox(left, "Add every screenshot to the journal",
        function() return s.photosAll end, function(v) s.photosAll = v end), 28)
    place(UI.Checkbox(left, "Hide the interface when taking a picture",
        function() return s.photoClean end, function(v) s.photoClean = v end), 28)
    place(UI.Checkbox(left, "Show my screenshots (after \"Set up pictures\")",
        function() return s.photosShow end, function(v)
            s.photosShow = v
            ns.Refresh()
        end), 30)
    local setup = UI.Button(left, "Set up pictures...", 220)
    place(setup, 40, 4)
    setup:SetScript("OnClick", function() ns.ShowPictureSetup() end)

    local label = UI.Text(left, 12)
    label:SetText("Treasures kept in the daily log:")
    place(label, 22, 4)
    place(UI.Dropdown(left, 220, QUALITIES, function() return s.lootQuality end,
        function(v) s.lootQuality = v end), 44, 4)

    -- Everything the Map buttons put on the game's world map, gone in one click.
    local unpin = UI.Button(left, "Remove the book's map pins", 220)
    place(unpin, 34, 4)
    unpin:SetScript("OnClick", function() ns.MapPins.Clear() end)

    -- Two clicks to wipe, so a stray click can't erase the journal.
    local reset = UI.Button(left, "Erase this character's log", 220)
    place(reset, 30, 4)
    local armed = false
    reset:SetScript("OnClick", function(b)
        if not armed then
            armed = true
            b:SetText("Click again to erase")
            C_Timer.After(4, function()
                armed = false
                b:SetText("Erase this character's log")
            end)
            return
        end
        for key in pairs(ns.defaults) do
            if key ~= "settings" then wipe(ns.db[key]) end
        end
        ns.db.activeRun = nil
        armed = false
        b:SetText("Erase this character's log")
        ns.Print("Log erased.")
        ns.Refresh()
    end)

    self.doc = UI.Doc(right, ns.Book.CONTENT_W, ns.Book.CONTENT_H)
    self.doc.sf:SetPoint("TOPLEFT")
end

------------------------------------------------------------------------------
-- How to set up pictures. Addons can't run programs or open folders, so this is the next best
-- thing: the steps, the folder in a box to copy from, and a button to say it's done.
------------------------------------------------------------------------------

local FOLDER = "Interface\\AddOns\\CaptainsLog"
local setupWindow

local function BuildSetup()
    local f = CreateFrame("Frame", "CaptainsLogPictureSetup", UIParent, "BackdropTemplate")
    f:SetSize(460, 330)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.27, 0.15, 0.07, 1)
    f:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    tinsert(UISpecialFrames, "CaptainsLogPictureSetup")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local page = UI.Page(f)
    page:SetPoint("TOPLEFT", 12, -12)
    page:SetPoint("BOTTOMRIGHT", -12, 12)

    local title = UI.Text(page, 20, UI.ACCENT, UI.HEADING_FONT)
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("Set up pictures")
    f.status = UI.Text(page, 11, UI.FADED)
    f.status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 2, -2)

    local body = UI.Text(page, 12)
    body:SetPoint("TOPLEFT", f.status, "BOTTOMLEFT", 0, -10)
    body:SetWidth(400)
    body:SetSpacing(3)
    body:SetText("The book can show your screenshots, but the game only reads files inside its own "
        .. "folders, and addons can't run anything on your PC. So there's one step outside the game, once:\n\n"
        .. "1.  Minimise the game and open your game folder (the one the game runs from).\n"
        .. "2.  Go into the folder below and double-click |cff7a1f0dSet up pictures.bat|r.\n"
        .. "3.  Come back and press |cff7a1f0dIt's set up|r. (Type /reload to bring in older screenshots.)")

    -- The folder, selectable for Ctrl+C; typing doesn't change it.
    local box = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    box:SetSize(300, 22)
    box:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 6, -12)
    box:SetAutoFocus(false)
    box:SetText(FOLDER)
    box:SetCursorPosition(0)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnTextChanged", function(self, user)
        if user then
            self:SetText(FOLDER)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    local hint = UI.Text(page, 11, UI.FADED)
    hint:SetPoint("LEFT", box, "RIGHT", 8, 0)
    hint:SetText("Ctrl+C to copy")

    local note = UI.Text(page, 11, UI.FADED)
    note:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -10)
    note:SetWidth(400)
    note:SetText("It links your Screenshots folder into the game's AddOns folder; nothing is copied or "
        .. "moved. Windows only.")

    local done = UI.Button(page, "It's set up", 140, 24)
    done:SetPoint("BOTTOMRIGHT", -16, 14)
    done:SetScript("OnClick", function()
        ns.db.settings.photosShow = true
        f:Hide()
        ns.Refresh()
    end)
    local later = UI.Button(page, "Not now", 100, 24)
    later:SetPoint("RIGHT", done, "LEFT", -8, 0)
    later:SetScript("OnClick", function() f:Hide() end)
    return f
end

function ns.ShowPictureSetup()
    setupWindow = setupWindow or BuildSetup()
    setupWindow.status:SetText(ns.db.settings.photosShow and "Pictures are on. Run it again any time to bring in older screenshots."
        or "Pictures aren't set up yet.")
    setupWindow:Show()
    setupWindow:Raise()
end

function Page:Render()
    local db = ns.db
    local days, played, kills = 0, 0, 0
    for _, d in pairs(db.days) do
        days = days + 1
        played = played + d.played
        kills = kills + d.kills
    end
    local mobs, quests, zones = 0, 0, 0
    for _ in pairs(db.mobs) do mobs = mobs + 1 end
    for _, q in pairs(db.quests) do if q.completed then quests = quests + 1 end end
    for _ in pairs(db.zones) do zones = zones + 1 end

    local doc = self.doc
    doc:Clear("settings")
    doc:Title("The story so far")
    doc:Line("Days in the log: " .. days)
    doc:Line("Time played: " .. ns.Duration(played))
    doc:Line("Creatures slain: " .. ns.Number(kills))
    doc:Line("Bestiary entries: " .. mobs)
    doc:Line("Quests completed: " .. quests)
    doc:Line("Lands visited: " .. zones)
    doc:Line("Deaths: " .. #db.deaths)
    doc:Gap(12)
    doc:Faded("Counting only starts once the addon is installed; earlier adventures aren't known to it.")
    doc:Faded("Type /log to open the book, or /log debug to toggle kill messages.")
    doc:Finish()
end

-- Its entry in the game's Options > AddOns list (Options.lua): opens the book at Settings.
ns.AddOptionsPanel({
    button = "Open Captain's Log",
    open = function()
        ns.Book.back = nil
        ns.Book:Open("settings")
    end,
    commands = {
        { "/log", "open or close the book" },
        { "/log debug", "say in chat which signal counted each kill" },
        { "/log picture", "take a picture for today's page (or set a key under Key Bindings > AddOns)" },
    },
})
