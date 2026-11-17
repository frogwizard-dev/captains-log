local _, ns = ...
local L = ns.L
local UI = ns.UI

local Book = {}
ns.Book = Book
ns.Pages = {} -- key -> page module { label, color, order, Build(self, left, right), Render(self) }

local BOOK_W, BOOK_H = 920, 600
local PAGE_W, PAGE_H = (BOOK_W - 44) / 2, BOOK_H - 40
Book.CONTENT_W, Book.CONTENT_H = PAGE_W - 48, PAGE_H - 44

local WHITE = "Interface\\Buttons\\WHITE8X8"

function Book:Create()
    local frame = CreateFrame("Frame", "CaptainsLogBook", UIParent, "BackdropTemplate")
    frame:SetSize(BOOK_W, BOOK_H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    -- Clicking the book (its cover) while it sits behind the world map brings it back up.
    frame:SetScript("OnMouseDown", function(self)
        self:SetFrameStrata("HIGH")
        self:Raise()
    end)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    -- Leather cover with a gilt edge.
    frame:SetBackdrop({
        bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.27, 0.15, 0.07, 1)
    frame:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    tinsert(UISpecialFrames, "CaptainsLogBook")
    frame:Hide()
    self.frame = frame

    self.leftPage = UI.Page(frame)
    self.leftPage:SetSize(PAGE_W, PAGE_H)
    self.leftPage:SetPoint("TOPLEFT", 20, -20)
    UI.Shade(self.leftPage, "RIGHT", 34)

    self.rightPage = UI.Page(frame)
    self.rightPage:SetSize(PAGE_W, PAGE_H)
    self.rightPage:SetPoint("TOPRIGHT", -20, -20)
    UI.Shade(self.rightPage, "LEFT", 34)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    self.contents = {}
    self:CreateBookmarks()
end

-- Ribbon bookmarks down the right edge of the book; the open one sticks out further.
function Book:CreateBookmarks()
    local keys = {}
    for key in pairs(ns.Pages) do keys[#keys + 1] = key end
    table.sort(keys, function(first, second) return ns.Pages[first].order < ns.Pages[second].order end)

    self.marks = {}
    for i, key in ipairs(keys) do
        local page = ns.Pages[key]
        local mark = CreateFrame("Button", nil, self.frame)
        mark:SetSize(104, 30)
        mark:SetFrameLevel(self.frame:GetFrameLevel() - 1)
        local ribbon = mark:CreateTexture(nil, "BACKGROUND")
        ribbon:SetAllPoints()
        ribbon:SetColorTexture(page.color[1], page.color[2], page.color[3], 1)
        local edge = mark:CreateTexture(nil, "BORDER")
        edge:SetPoint("TOPLEFT")
        edge:SetPoint("BOTTOMLEFT")
        edge:SetWidth(18)
        edge:SetColorTexture(0, 0, 0, 0.25)
        local text = UI.Text(mark, 13, { 0.98, 0.93, 0.8 }, UI.HEADING_FONT)
        text:SetPoint("LEFT", 26, 0)
        text:SetText(page.label)
        mark.y = -40 - (i - 1) * 38
        mark:SetScript("OnClick", function()
            self.back = nil -- a bookmark starts afresh; "Back to" is only for followed links
            self:Open(key)
        end)
        self.marks[key] = mark
    end
end

function Book:LayoutBookmarks()
    for key, mark in pairs(self.marks) do
        mark:ClearAllPoints()
        mark:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", key == self.current and -4 or -20, mark.y)
    end
end

-- Each page module gets its own container on each page, built the first time it opens.
function Book:Content(key)
    local content = self.contents[key]
    if not content then
        content = {}
        for side, page in pairs({ left = self.leftPage, right = self.rightPage }) do
            local area = CreateFrame("Frame", nil, page)
            area:SetPoint("TOPLEFT", 24, -22)
            area:SetPoint("BOTTOMRIGHT", -24, 22)
            content[side] = area
        end
        self.contents[key] = content
        ns.Pages[key]:Build(content.left, content.right)
    end
    return content
end

function Book:Open(key)
    if not self.frame then self:Create() end
    self.current = key
    for other in pairs(ns.Pages) do
        local content = self.contents[other]
        if content then
            content.left:SetShown(other == key)
            content.right:SetShown(other == key)
        end
    end
    local content = self:Content(key)
    content.left:Show()
    content.right:Show()
    self:LayoutBookmarks()
    self.frame:Show()
    -- Back in front (of the world map too, when a page is opened from one of its pins).
    self.frame:SetFrameStrata("HIGH")
    self.frame:Raise()
    ns.Pages[key]:Render()
end

-- Following a link: open a page on one entry, its search and filter cleared so the entry is listed,
-- the list scrolled to it. `remember` keeps where you came from for the "Back to" link.
function Book:Goto(key, selected, remember)
    local page = ns.Pages[key]
    if not page then return end
    if remember and self.current then
        local from = ns.Pages[self.current]
        self.back = { key = self.current, sel = from.selected, label = from.title }
    end
    if not self.frame then self:Create() end
    self:Content(key)
    if page.search and page.search:GetText() ~= "" then page.search:SetText("") end
    if page.query then page.query = "" end
    if page.filter then
        page.filter = "all"
        if page.filterDropdown and page.filterDropdown.GenerateMenu then
            pcall(page.filterDropdown.GenerateMenu, page.filterDropdown)
        end
    end
    -- A page with more than one view (Dungeons) picks the view that shows `selected` itself.
    if page.Reveal then
        page:Reveal(selected)
    else
        page.selected = selected
        if page.list then page.list.revealKey = selected end
    end
    self:Open(key)
end

function Book:GoBack()
    local back = self.back
    self.back = nil
    if back then self:Goto(back.key, back.sel) end
end

-- "< Back to Kobold Camp Cleanup" at the top of a page reached by a link.
function Book:BackLink(doc)
    local back = self.back
    if not back then return end
    local label = back.label or (ns.Pages[back.key] and ns.Pages[back.key].label) or L["previous page"]
    doc:Text(UI.Link(L["« Back to %s"]:format(label), "back"), 11)
    doc:Gap(2)
end

function Book:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Open(self.current or "log")
    end
end

function Book:Rerender()
    if self.frame and self.frame:IsShown() and self.current then
        ns.Pages[self.current]:Render()
    end
end

-- Title block used at the top of each left page.
function Book:Header(parent, title)
    local heading = UI.Text(parent, 26, UI.ACCENT, UI.HEADING_FONT)
    heading:SetPoint("TOPLEFT")
    heading:SetText(title)
    local subtitle = UI.Text(parent, 12, UI.FADED)
    subtitle:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 2, -2)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.4)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -6)
    rule:SetPoint("RIGHT", parent, "RIGHT")
    return subtitle
end
