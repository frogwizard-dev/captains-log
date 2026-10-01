local _, ns = ...
local UI = ns.UI

local Book = {}
ns.Book = Book
ns.Pages = {} -- key -> page module { label, color, order, Build(self, left, right), Render(self) }

local W, H = 920, 600
local PAGE_W, PAGE_H = (W - 44) / 2, H - 40
Book.CONTENT_W, Book.CONTENT_H = PAGE_W - 48, PAGE_H - 44

local WHITE = "Interface\\Buttons\\WHITE8X8"

function Book:Create()
    local f = CreateFrame("Frame", "CaptainsLogBook", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    -- Clicking the book (its cover) while it sits behind the world map brings it back up.
    f:SetScript("OnMouseDown", function(self)
        self:SetFrameStrata("HIGH")
        self:Raise()
    end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- Leather cover with a gilt edge.
    f:SetBackdrop({
        bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.27, 0.15, 0.07, 1)
    f:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
    tinsert(UISpecialFrames, "CaptainsLogBook")
    f:Hide()
    self.frame = f

    self.leftPage = UI.Page(f)
    self.leftPage:SetSize(PAGE_W, PAGE_H)
    self.leftPage:SetPoint("TOPLEFT", 20, -20)
    UI.Shade(self.leftPage, "RIGHT", 34)

    self.rightPage = UI.Page(f)
    self.rightPage:SetSize(PAGE_W, PAGE_H)
    self.rightPage:SetPoint("TOPRIGHT", -20, -20)
    UI.Shade(self.rightPage, "LEFT", 34)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    self.contents = {}
    self:CreateBookmarks()
end

-- Ribbon bookmarks down the right edge of the book; the open one sticks out further.
function Book:CreateBookmarks()
    local keys = {}
    for key in pairs(ns.Pages) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return ns.Pages[a].order < ns.Pages[b].order end)

    self.marks = {}
    for i, key in ipairs(keys) do
        local page = ns.Pages[key]
        local b = CreateFrame("Button", nil, self.frame)
        b:SetSize(104, 30)
        b:SetFrameLevel(self.frame:GetFrameLevel() - 1)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(page.color[1], page.color[2], page.color[3], 1)
        local edge = b:CreateTexture(nil, "BORDER")
        edge:SetPoint("TOPLEFT")
        edge:SetPoint("BOTTOMLEFT")
        edge:SetWidth(18)
        edge:SetColorTexture(0, 0, 0, 0.25)
        local text = UI.Text(b, 13, { 0.98, 0.93, 0.8 }, UI.HEADING_FONT)
        text:SetPoint("LEFT", 26, 0)
        text:SetText(page.label)
        b.y = -40 - (i - 1) * 38
        b:SetScript("OnClick", function()
            self.back = nil -- a bookmark starts afresh; "Back to" is only for followed links
            self:Open(key)
        end)
        self.marks[key] = b
    end
end

function Book:LayoutBookmarks()
    for key, b in pairs(self.marks) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", key == self.current and -4 or -20, b.y)
    end
end

-- Each page module gets its own container on each page, built the first time it opens.
function Book:Content(key)
    local c = self.contents[key]
    if not c then
        c = {}
        for side, page in pairs({ left = self.leftPage, right = self.rightPage }) do
            local area = CreateFrame("Frame", nil, page)
            area:SetPoint("TOPLEFT", 24, -22)
            area:SetPoint("BOTTOMRIGHT", -24, 22)
            c[side] = area
        end
        self.contents[key] = c
        ns.Pages[key]:Build(c.left, c.right)
    end
    return c
end

function Book:Open(key)
    if not self.frame then self:Create() end
    self.current = key
    for k in pairs(ns.Pages) do
        local c = self.contents[k]
        if c then
            c.left:SetShown(k == key)
            c.right:SetShown(k == key)
        end
    end
    local c = self:Content(key)
    c.left:Show()
    c.right:Show()
    self:LayoutBookmarks()
    self.frame:Show()
    -- Back in front (of the world map too, when a page is opened from one of its pins).
    self.frame:SetFrameStrata("HIGH")
    self.frame:Raise()
    ns.Pages[key]:Render()
end

-- Following a link: open a page on one entry. Its search and filter are cleared so the entry
-- is sure to be listed, and the list scrolls to it. `remember` keeps where you came from for
-- the "Back to" link.
function Book:Goto(key, sel, remember)
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
        if page.filterDropdown and page.filterDropdown.GenerateMenu then pcall(page.filterDropdown.GenerateMenu, page.filterDropdown) end
    end
    -- A page with more than one view (Dungeons) picks the view that shows `sel` itself.
    if page.Reveal then
        page:Reveal(sel)
    else
        page.selected = sel
        if page.list then page.list.revealKey = sel end
    end
    self:Open(key)
end

function Book:GoBack()
    local b = self.back
    self.back = nil
    if b then self:Goto(b.key, b.sel) end
end

-- "< Back to Kobold Camp Cleanup" at the top of a page reached by a link.
function Book:BackLink(doc)
    local b = self.back
    if not b then return end
    local label = b.label or (ns.Pages[b.key] and ns.Pages[b.key].label) or "previous page"
    doc:Text(UI.Link("« Back to " .. label, "back"), 11)
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
    local t = UI.Text(parent, 26, UI.ACCENT, UI.HEADING_FONT)
    t:SetPoint("TOPLEFT")
    t:SetText(title)
    local sub = UI.Text(parent, 12, UI.FADED)
    sub:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 2, -2)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.4)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -2, -6)
    rule:SetPoint("RIGHT", parent, "RIGHT")
    return sub
end
