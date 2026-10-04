local _, ns = ...
local UI = {}
ns.UI = UI

-- Ink on parchment.
UI.INK = { 0.22, 0.13, 0.05 }
UI.FADED = { 0.46, 0.36, 0.22 }
UI.ACCENT = { 0.50, 0.12, 0.05 }
UI.HEADING_FONT = "Fonts\\MORPHEUS.TTF"
UI.BODY_FONT = "Fonts\\FRIZQT__.TTF"
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- White (common) and grey (poor) item names vanish on parchment; re-ink them. Links come as
-- either "|cffRRGGBB" or the newer "|cnIQ<quality>:" colour codes.
function UI.Ink(link)
    if not link then return "?" end
    link = link:gsub("|cnIQ1:", "|cff2e1d0c"):gsub("|cffffffff", "|cff2e1d0c")
    link = link:gsub("|cnIQ0:", "|cff6b5d4f"):gsub("|cff9d9d9d", "|cff6b5d4f")
    return link
end

function UI.Text(parent, size, color, font)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(font or UI.BODY_FONT, size or 12, "")
    local c = color or UI.INK
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetJustifyH("LEFT")
    fs:SetShadowOffset(0, 0)
    return fs
end

-- A parchment page: warm base colour with the quest-log parchment grain over it.
function UI.Page(parent)
    local p = CreateFrame("Frame", nil, parent)
    local base = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    base:SetAllPoints()
    base:SetColorTexture(0.90, 0.82, 0.64)
    local grain = p:CreateTexture(nil, "BACKGROUND", nil, -7)
    grain:SetAllPoints()
    grain:SetTexture("Interface\\QuestFrame\\QuestBG")
    -- The parchment art only fills the top-left ~58% x 65% of the file, torn edges included;
    -- crop inside those edges so the grain covers the whole page.
    grain:SetTexCoord(0.03, 0.54, 0.03, 0.62)
    grain:SetAlpha(0.55)
    return p
end

-- Soft shadow along one edge (the book's spine).
function UI.Shade(page, side, width)
    local t = page:CreateTexture(nil, "BACKGROUND", nil, -6)
    t:SetTexture(WHITE)
    t:SetWidth(width or 28)
    t:SetPoint("TOP")
    t:SetPoint("BOTTOM")
    t:SetPoint(side)
    local dark, clear = CreateColor(0.2, 0.1, 0.02, 0.35), CreateColor(0.2, 0.1, 0.02, 0)
    if side == "RIGHT" then
        t:SetGradient("HORIZONTAL", clear, dark)
    else
        t:SetGradient("HORIZONTAL", dark, clear)
    end
end

local function Wheel(sf, step)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, self:GetScrollChild():GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * step)))
    end)
end

-- A slim ink scroll bar just right of a scroll frame, in the page's margin: drag the thumb or
-- click the track. Hidden when everything fits. Returns its update function.
local function ScrollBar(sf)
    local bar = CreateFrame("Frame", nil, sf)
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 8, 0)
    bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 8, 0)
    bar:SetWidth(6)
    bar:EnableMouse(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.10)
    local thumb = CreateFrame("Button", nil, bar)
    thumb:SetWidth(6)
    local tex = thumb:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.45)
    local hl = thumb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.35)

    local function range() return math.max(0, sf:GetScrollChild():GetHeight() - sf:GetHeight()) end
    local function update()
        local r = range()
        if r <= 1 then
            bar:Hide()
            return
        end
        bar:Show()
        local h = bar:GetHeight()
        local th = math.max(24, h * sf:GetHeight() / sf:GetScrollChild():GetHeight())
        thumb:SetHeight(th)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", 0, -(h - th) * math.min(1, sf:GetVerticalScroll() / r))
    end
    local function cursorY()
        local _, y = GetCursorPosition()
        return y / bar:GetEffectiveScale()
    end
    local dragFrom, scrollFrom
    thumb:SetScript("OnMouseDown", function()
        dragFrom, scrollFrom = cursorY(), sf:GetVerticalScroll()
    end)
    thumb:SetScript("OnMouseUp", function() dragFrom = nil end)
    thumb:SetScript("OnUpdate", function()
        if not dragFrom then return end
        local h, th = bar:GetHeight(), thumb:GetHeight()
        if h - th <= 0 then return end
        local scroll = scrollFrom + (dragFrom - cursorY()) * range() / (h - th)
        sf:SetVerticalScroll(math.max(0, math.min(range(), scroll)))
    end)
    -- Clicking the track jumps there.
    bar:SetScript("OnMouseDown", function(self)
        local share = (self:GetTop() - cursorY()) / self:GetHeight()
        sf:SetVerticalScroll(math.max(0, math.min(range(), share * range())))
    end)
    return update
end

------------------------------------------------------------------------------
-- List: clickable rows with left/right text and a selection mark.
------------------------------------------------------------------------------

local List = {}
List.__index = List

function UI.List(parent, width, height)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetSize(width, height)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(width, 1)
    sf:SetScrollChild(child)
    Wheel(sf, 40)
    local bar = ScrollBar(sf)
    sf:SetScript("OnVerticalScroll", bar)
    sf:SetScript("OnScrollRangeChanged", bar)
    return setmetatable({ sf = sf, child = child, rows = {}, width = width, rowHeight = 20, bar = bar }, List)
end

-- items: { { key, left, right, color } }; onClick(key)
function List:SetItems(items, selected, onClick)
    for i, item in ipairs(items) do
        local r = self.rows[i]
        if not r then
            r = CreateFrame("Button", nil, self.child)
            r:SetSize(self.width, self.rowHeight)
            r:SetPoint("TOPLEFT", 0, -(i - 1) * self.rowHeight)
            local hl = r:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
            r:SetHighlightTexture(hl)
            r.sel = r:CreateTexture(nil, "BACKGROUND")
            r.sel:SetAllPoints()
            r.sel:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.15)
            r.left = UI.Text(r, 12)
            r.left:SetPoint("LEFT", 4, 0)
            r.left:SetWordWrap(false)
            r.right = UI.Text(r, 11, UI.FADED)
            r.right:SetPoint("RIGHT", -4, 0)
            r.right:SetJustifyH("RIGHT")
            r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
            self.rows[i] = r
        end
        -- Header rows ({ header = true }) title a group: heading ink, not clickable.
        local header = item.header
        local c = item.color or (header and UI.ACCENT) or UI.INK
        r.left:SetFont(header and UI.HEADING_FONT or UI.BODY_FONT, header and 14 or 12, "")
        r.left:SetPoint("LEFT", header and 2 or (item.indent or 4), 0)
        r.left:SetText(item.left)
        r.left:SetTextColor(c[1], c[2], c[3])
        r.right:SetText(item.right or "")
        r.sel:SetShown(not header and item.key == selected)
        r:EnableMouse(not header)
        r:SetScript("OnClick", function() onClick(item.key) end)
        r:Show()
    end
    for i = #items + 1, #self.rows do
        self.rows[i]:Hide()
    end
    self.child:SetHeight(math.max(1, #items * self.rowHeight))
    self.bar()
    local max = math.max(0, self.child:GetHeight() - self.sf:GetHeight())
    if self.sf:GetVerticalScroll() > max then self.sf:SetVerticalScroll(max) end
    -- Arriving by a link: scroll the chosen row into the middle of the list.
    if self.revealKey ~= nil then
        for i, item in ipairs(items) do
            if item.key == self.revealKey then
                local target = (i - 1) * self.rowHeight - (self.sf:GetHeight() - self.rowHeight) / 2
                self.sf:SetVerticalScroll(math.max(0, math.min(max, target)))
                break
            end
        end
        self.revealKey = nil
    end
end

------------------------------------------------------------------------------
-- Book links: clickable words inside a page, written "|Hclog:kind:arg:arg|h text |h". Each
-- kind registers what a click does and what its tooltip says (UI.RegisterLink).
------------------------------------------------------------------------------

UI.LINK = "|cff1d4f8c" -- a dark blue ink that reads as clickable on parchment
local linkKinds = {}

-- click(...) gets the link's args as strings; tip(...) returns a tooltip title and line.
function UI.RegisterLink(kind, click, tip)
    linkKinds[kind] = { click = click, tip = tip }
end

-- Args must not contain ":" or "|".
function UI.Link(text, kind, ...)
    local parts = { kind }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return string.format("%s|Hclog:%s|h%s|h|r", UI.LINK, table.concat(parts, ":"), text)
end

local function LinkKind(link)
    local body = link:match("^clog:(.*)$")
    if not body then return end
    local parts = { strsplit(":", body) }
    return linkKinds[parts[1]], unpack(parts, 2)
end

local function HyperlinkEnter(self, link)
    if link:match("^clog:") then
        local kind = LinkKind(link)
        if not (kind and kind.tip) then return end
        local title, text = kind.tip(select(2, LinkKind(link)))
        if not title then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetText(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

local function HyperlinkClick(_, link, text)
    if link:match("^clog:") then
        local kind = LinkKind(link)
        if kind then
            GameTooltip:Hide()
            kind.click(select(2, LinkKind(link)))
        end
    elseif IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
        ChatEdit_InsertLink(text) -- shift-click an item into chat, as anywhere else
    end
end

------------------------------------------------------------------------------
-- Doc: a scrolling page of headings, lines and item rows, rebuilt on each render.
------------------------------------------------------------------------------

local Doc = {}
Doc.__index = Doc

function UI.Doc(parent, width, height)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetSize(width, height)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(width, 1)
    sf:SetScrollChild(child)
    Wheel(sf, 40)
    -- Item links written into lines show their tooltip on hover; book links act on click.
    child:SetHyperlinksEnabled(true)
    child:SetScript("OnHyperlinkEnter", HyperlinkEnter)
    child:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    child:SetScript("OnHyperlinkClick", HyperlinkClick)

    -- The page scrolls with the mouse wheel or its scroll bar.
    local update = ScrollBar(sf)
    sf:SetScript("OnVerticalScroll", update)
    sf:SetScript("OnScrollRangeChanged", update)
    return setmetatable({ sf = sf, child = child, width = width, texts = {}, items = {}, cells = {}, maps = {},
        y = 0, nt = 0, ni = 0, nc = 0, nm = 0, updateFade = update }, Doc)
end

-- Starts the page afresh. `subject` names what's being shown (a creature's ID, a day...): when
-- it's the same as last time (a button pressed, new data), the reader's scroll position is
-- kept; a different subject starts at the top.
function Doc:Clear(subject)
    self.keepScroll = subject ~= nil and subject == self.subject and self.sf:GetVerticalScroll() or nil
    self.subject = subject
    for _, fs in ipairs(self.texts) do fs:Hide() end
    for _, b in ipairs(self.items) do b:Hide() end
    self.cells = self.cells or {}
    for _, c in ipairs(self.cells) do c:Hide() end
    self.nc = 0
    self.maps = self.maps or {}
    for _, m in ipairs(self.maps) do m:Hide() end
    self.nm = 0
    self.chips = self.chips or {}
    for _, c in ipairs(self.chips) do c:Hide() end
    self.nch = 0
    self.pictures = self.pictures or {}
    for _, p in ipairs(self.pictures) do p:Hide() end
    self.np = 0
    self.spotMaps = self.spotMaps or {}
    for _, m in ipairs(self.spotMaps) do m:Hide() end
    self.nsm = 0
    self.nt, self.ni, self.y = 0, 0, 0
    if not self.keepScroll then self.sf:SetVerticalScroll(0) end
end

-- `reserve` keeps that many pixels free at the right end, for action buttons (Doc:Row).
function Doc:Text(text, size, color, font, indent, reserve)
    self.nt = self.nt + 1
    local fs = self.texts[self.nt]
    if not fs then
        fs = self.child:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetShadowOffset(0, 0)
        self.texts[self.nt] = fs
    end
    indent = indent or 0
    fs:SetFont(font or UI.BODY_FONT, size or 12, "")
    local c = color or UI.INK
    fs:SetTextColor(c[1], c[2], c[3])
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", indent, -self.y)
    fs:SetWidth(self.width - indent - (reserve or 0))
    fs:SetWordWrap(true) -- a grid caption (Doc:Label) may have used this line before
    fs:SetText(text)
    fs:Show()
    self.y = self.y + fs:GetStringHeight() + 4
    return fs
end

function Doc:Title(text)
    self:Text(text, 22, UI.ACCENT, UI.HEADING_FONT)
    self.y = self.y + 2
end

------------------------------------------------------------------------------
-- Action buttons: small labelled buttons ("Map", "Waypoint") at the right end of a line, so
-- actions line up down the page instead of wrapping into the text.
-- An action is { label, icon = file or atlas = name, tip = { title, text }, onClick = fn }.
------------------------------------------------------------------------------

local CHIP_H, CHIP_GAP = 18, 4

local function SetIcon(tex, a)
    if a.atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(a.atlas) then
        tex:SetAtlas(a.atlas)
        tex:SetTexCoord(0, 1, 0, 1)
    else
        tex:SetTexture(a.icon or "Interface\\Icons\\INV_Misc_Map_01")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

function Doc:Chip(a)
    self.nch = self.nch + 1
    local c = self.chips[self.nch]
    if not c then
        c = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        c:SetHeight(CHIP_H)
        c:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        c:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
        c:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.45)
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetPoint("TOPLEFT", 1, -1)
        hl:SetPoint("BOTTOMRIGHT", -1, 1)
        hl:SetColorTexture(0.11, 0.31, 0.55, 0.15)
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(13, 13)
        c.icon:SetPoint("LEFT", 4, 0)
        c.text = UI.Text(c, 11, { 0.11, 0.31, 0.55 })
        c.text:SetPoint("LEFT", c.icon, "RIGHT", 3, 0)
        c:SetScript("OnEnter", function(b)
            if not b.tip then return end
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText(b.tip[1])
            if b.tip[2] then GameTooltip:AddLine(b.tip[2], 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", GameTooltip_Hide)
        self.chips[self.nch] = c
    end
    SetIcon(c.icon, a)
    c.text:SetText(a[1])
    c.tip = a.tip
    c:SetScript("OnClick", function()
        GameTooltip:Hide()
        a.onClick()
    end)
    c:SetWidth(math.ceil(c.text:GetStringWidth()) + 26)
    return c
end

-- Places action buttons right-aligned with their top at y; returns the width they take.
function Doc:PlaceChips(actions, y)
    local x = 0
    for i = #actions, 1, -1 do
        local c = self:Chip(actions[i])
        c:ClearAllPoints()
        c:SetPoint("TOPRIGHT", self.child, "TOPLEFT", self.width - x, -y)
        c:Show()
        x = x + c:GetWidth() + CHIP_GAP
    end
    return x
end

-- A line of text with action buttons at its right end.
function Doc:Row(text, actions, color, size)
    local top = self.y
    local reserve = (actions and #actions > 0) and (self:PlaceChips(actions, top - 2) + 4) or 0
    self:Text(text, size or 12, color, nil, 8, reserve)
    self.y = math.max(self.y, top + CHIP_H + 4)
end

function Doc:Heading(text, actions)
    self.y = self.y + 8
    local reserve = (actions and #actions > 0) and (self:PlaceChips(actions, self.y) + 4) or nil
    self:Text(text, 15, UI.ACCENT, UI.HEADING_FONT, nil, reserve)
end

-- The two map actions as buttons: pin to the world map (onMap) and the game's waypoint.
function UI.MapActions(onMap, mapID, x, y, mapTip)
    local actions = {}
    if onMap then
        actions[#actions + 1] = { "Map", icon = "Interface\\Icons\\INV_Misc_Map_01", onClick = onMap,
            tip = { "Show on your world map", (mapTip or "Pins this to the game's map.")
                .. " Right-click a pin there to remove it." } }
    end
    if mapID and x and y then
        actions[#actions + 1] = { "Waypoint", atlas = "Waypoint-MapPin-ChatIcon", icon = "Interface\\Icons\\INV_Misc_Map02",
            onClick = function() UI.Waypoint(mapID, x, y) end,
            tip = { "Set a waypoint", "Puts a pin on your world map with the arrow on screen to lead you there. "
                .. "It replaces any pin you placed yourself." } }
    end
    return actions
end

function Doc:Line(text, color)
    self:Text(text, 12, color, nil, 8)
end

function Doc:Faded(text)
    self:Text(text, 11, UI.FADED, nil, 8)
end

function Doc:Gap(h)
    self.y = self.y + (h or 8)
end

-- A checklist line: a tick when done, a cross when not (or a waiting mark when `done` is nil).
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-%s:14:14:0:0|t "
function Doc:Check(text, done, color)
    local mark = done and "Ready" or (done == false and "NotReady" or "Waiting")
    self:Text(CHECK:format(mark) .. text, 12, color or (done and UI.FADED or nil), nil, 8)
end

-- An item with its icon; hover shows the item tooltip.
function Doc:Item(link, suffix, icon)
    self.ni = self.ni + 1
    local b = self.items[self.ni]
    if not b then
        b = CreateFrame("Button", nil, self.child)
        b:SetSize(self.width - 8, 20)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT")
        b.text = UI.Text(b, 12)
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.text:SetPoint("RIGHT")
        b.text:SetWordWrap(false)
        b:SetScript("OnEnter", function(self)
            if self.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        self.items[self.ni] = b
    end
    b.link = link
    b.icon:SetTexture(icon or (link and C_Item.GetItemIconByID(link)) or 134400)
    b.text:SetText(UI.Ink(link) .. (suffix and ("  |cff5c4630" .. suffix .. "|r") or ""))
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", 8, -self.y)
    b:Show()
    self.y = self.y + 22
end

-- Items as a merchant-style grid: icon, name (up to two lines) and a note such as the price.
-- entries = { { link, icon, note } }
local CELL_H = 44
function Doc:Grid(entries, cols)
    cols = cols or 2
    local gap = 8
    local cellW = (self.width - 8 - gap * (cols - 1)) / cols
    for i, e in ipairs(entries) do
        self.nc = self.nc + 1
        local c = self.cells[self.nc]
        if not c then
            c = CreateFrame("Button", nil, self.child)
            c.bg = c:CreateTexture(nil, "BACKGROUND")
            c.bg:SetAllPoints()
            c.bg:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.07)
            local hl = c:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
            c.rim = c:CreateTexture(nil, "ARTWORK")
            c.rim:SetSize(38, 38)
            c.rim:SetPoint("LEFT", 3, 0)
            c.rim:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
            c.icon = c:CreateTexture(nil, "ARTWORK", nil, 1)
            c.icon:SetPoint("TOPLEFT", c.rim, 1, -1)
            c.icon:SetPoint("BOTTOMRIGHT", c.rim, -1, 1)
            c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            c.name = UI.Text(c, 11)
            c.name:SetPoint("TOPLEFT", c.rim, "TOPRIGHT", 6, 0)
            c.name:SetPoint("RIGHT", -4, 0)
            c.name:SetMaxLines(2)
            c.note = UI.Text(c, 11, UI.FADED)
            c.note:SetPoint("BOTTOMLEFT", c.rim, "BOTTOMRIGHT", 6, 0)
            c.note:SetPoint("RIGHT", -4, 0)
            c.note:SetWordWrap(false)
            c:SetScript("OnEnter", function(self)
                if self.link then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(self.link)
                    GameTooltip:Show()
                elseif self.tipTitle then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(self.tipTitle)
                    if self.tipText then GameTooltip:AddLine(self.tipText, 1, 1, 1, true) end
                    GameTooltip:Show()
                end
            end)
            c:SetScript("OnLeave", GameTooltip_Hide)
            self.cells[self.nc] = c
        end
        c.link, c.tipTitle, c.tipText = e.link, e.tipTitle, e.tipText
        c:SetSize(cellW, CELL_H)
        c.icon:SetTexture(e.icon or (e.link and C_Item.GetItemIconByID(e.link)) or 134400)
        -- Brackets dropped: a grid of "[Item]" reads busier than the merchant window.
        -- Entries without an item link (a trainer's spells) give a plain `name` instead.
        local name = e.link and UI.Ink(e.link) or e.name or "?"
        c.name:SetText((name:gsub("%[", ""):gsub("%]", "")))
        c.note:SetText(e.note or "")
        c:SetAlpha(e.dim and 0.5 or 1)
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", 8 + col * (cellW + gap), -(self.y + row * (CELL_H + 4)))
        c:Show()
    end
    self.y = self.y + math.ceil(#entries / cols) * (CELL_H + 4)
end

-- The base map art is the unexplored parchment; the areas you've explored are separate
-- overlay pieces, cut into 256px tiles. Same layout maths as Blizzard's world map.
local TILE = 256
local function TileSize(i, count, total)
    if i < count then return TILE, TILE end
    local pixels = total % TILE
    if pixels == 0 then pixels = TILE end
    local file = 16
    while file < pixels do file = file * 2 end
    return pixels, file
end

local function DrawExplored(m, mapID, s)
    m.overlays = m.overlays or {}
    for _, t in ipairs(m.overlays) do t:Hide() end
    local ok, infos = pcall(C_MapExplorationInfo.GetExploredMapTextures, mapID)
    if not ok or not infos then return end
    local n = 0
    for _, info in ipairs(infos) do
        if not info.isShownByMouseOver then
            local wide = math.ceil(info.textureWidth / TILE)
            local tall = math.ceil(info.textureHeight / TILE)
            for j = 1, tall do
                local pixelH, fileH = TileSize(j, tall, info.textureHeight)
                for k = 1, wide do
                    local pixelW, fileW = TileSize(k, wide, info.textureWidth)
                    n = n + 1
                    local t = m.overlays[n]
                    if not t then
                        t = m:CreateTexture(nil, "ARTWORK", nil, 1)
                        m.overlays[n] = t
                    end
                    t:SetTexture(info.fileDataIDs[(j - 1) * wide + k], nil, nil, "TRILINEAR")
                    t:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                    t:SetSize(pixelW * s, pixelH * s)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", (info.offsetX + TILE * (k - 1)) * s, -(info.offsetY + TILE * (j - 1)) * s)
                    t:SetVertexColor(1, 0.93, 0.8)
                    t:Show()
                end
            end
        end
    end
end

-- Map pin colours by kind. A spot is { x, y, kind = ..., label = ... }; kills have no kind.
UI.PIN = {
    kill = { 0.85, 0.15, 0.08 },
    death = { 0.12, 0.10, 0.10 },
    place = { 0.95, 0.75, 0.20 },
    npc = { 0.15, 0.62, 0.62 },
    start = { 0.30, 0.70, 0.20 },
    finish = { 0.95, 0.75, 0.20 },
    fish = { 0.16, 0.40, 0.78 }, -- where you fished in open water
    pool = { 0.45, 0.85, 0.95 }, -- where you fished mostly from pools
}
-- Kinds drawn as the game's own map icons (the quest giver's "!" and hand-in "?"), larger
-- than a dot; the colour above stands in if this client lacks the atlas.
UI.PIN_ATLAS = { start = "QuestNormal", finish = "QuestTurnin" }

local function HasAtlas(name)
    return name and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- "■ label" in a pin's colour (or its icon), for map legends.
function UI.Swatch(kind, label)
    local atlas = UI.PIN_ATLAS[kind]
    if HasAtlas(atlas) then return string.format("|A:%s:14:14|a %s", atlas, label) end
    local c = UI.PIN[kind] or UI.PIN.kill
    return string.format("|T%s:9:9:0:0:8:8:0:8:0:8:%d:%d:%d|t %s", WHITE,
        math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), label)
end

local function PinEnter(d)
    GameTooltip:SetOwner(d, "ANCHOR_RIGHT")
    GameTooltip:SetText(d.label)
    GameTooltip:Show()
end

-- Paints a zone map at width w onto `canvas` (base art, your explored areas, a dot per spot
-- {x, y} from 0-1) and returns its height. Used by the page thumbnails.
local function PaintMap(canvas, mapID, spots, w, dotSize)
    canvas.tiles, canvas.dots = canvas.tiles or {}, canvas.dots or {}
    for _, t in ipairs(canvas.tiles) do t:Hide() end
    for _, d in ipairs(canvas.dots) do d:Hide() end

    local h = w * 2 / 3
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local layer = ok and layers and layers[1]
    local ok2, textures = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if layer and ok2 and textures and #textures > 0 then
        local s = w / layer.layerWidth
        h = layer.layerHeight * s
        local cols = math.ceil(layer.layerWidth / layer.tileWidth)
        for i, fileID in ipairs(textures) do
            local t = canvas.tiles[i]
            if not t then
                t = canvas:CreateTexture(nil, "ARTWORK")
                canvas.tiles[i] = t
            end
            t:SetTexture(fileID)
            t:SetSize(layer.tileWidth * s, layer.tileHeight * s)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", ((i - 1) % cols) * layer.tileWidth * s, -math.floor((i - 1) / cols) * layer.tileHeight * s)
            t:SetVertexColor(1, 0.93, 0.8) -- a little sepia to sit on the parchment
            t:Show()
        end
        DrawExplored(canvas, mapID, s)
    end
    -- Sized before anything is drawn on it: the view cone's triangles are shaped by moving
    -- texture corners (SetVertexOffset), which does nothing on a canvas with no size yet.
    canvas:SetSize(w, h)

    for i, spot in ipairs(spots) do
        local d = canvas.dots[i]
        if not d then
            d = CreateFrame("Frame", nil, canvas)
            d.rim = d:CreateTexture(nil, "OVERLAY", nil, 1)
            d.rim:SetAllPoints()
            d.rim:SetColorTexture(0.15, 0.05, 0.02, 1)
            d.fill = d:CreateTexture(nil, "OVERLAY", nil, 2)
            d.fill:SetPoint("TOPLEFT", 1, -1)
            d.fill:SetPoint("BOTTOMRIGHT", -1, 1)
            d.icon = d:CreateTexture(nil, "OVERLAY", nil, 3)
            d.icon:SetAllPoints()
            d:SetScript("OnEnter", PinEnter)
            d:SetScript("OnLeave", GameTooltip_Hide)
            canvas.dots[i] = d
        end
        local atlas = UI.PIN_ATLAS[spot.kind]
        local iconic = HasAtlas(atlas)
        if iconic then d.icon:SetAtlas(atlas) end
        d.icon:SetShown(iconic)
        d.rim:SetShown(not iconic)
        d.fill:SetShown(not iconic)
        local c = UI.PIN[spot.kind] or UI.PIN.kill
        d.fill:SetColorTexture(c[1], c[2], c[3], 1)
        -- Icon pins sit above the dots so a quest giver isn't buried under kill spots.
        d:SetFrameLevel(canvas:GetFrameLevel() + (iconic and 4 or 2))
        -- Labelled pins answer hover with their label; clicks still reach the map underneath
        -- (to put it on the world map).
        d.label = spot.label
        d:SetMouseMotionEnabled(spot.label ~= nil)
        d:SetMouseClickEnabled(false)
        local size = iconic and math.floor(dotSize * 2.4) or dotSize
        d:SetSize(size, size)
        d:ClearAllPoints()
        d:SetPoint("CENTER", canvas, "TOPLEFT", spot[1] * w, -spot[2] * h)
        d:Show()
    end

    -- View cones for spots that say which way they faced (pictures).
    canvas.cones = canvas.cones or {}
    for _, cone in ipairs(canvas.cones) do
        for _, l in ipairs(cone.fill) do l:Hide() end
        for _, l in ipairs(cone.lines) do l:Hide() end
    end
    local n = 0
    for _, spot in ipairs(spots) do
        if spot.facing then
            n = n + 1
            canvas.cones[n] = canvas.cones[n] or { fill = {}, lines = {} }
            UI.DrawCone(canvas, canvas.cones[n], spot[1] * w, spot[2] * h, spot.facing, spot.fov, w * UI.CONE_SHARE)
        end
    end
    return h
end

-- A filled triangle in `frame`'s coordinates (x right, y down from its top-left): a plain
-- texture over the triangle's bounding box with its corners moved onto the three points (the
-- fourth folded onto the third).
local UL, LL, UR, LR = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2, UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4
function UI.DrawTriangle(t, frame, ax, ay, bx, by, cx, cy)
    local minX, maxX = math.min(ax, bx, cx), math.max(ax, bx, cx)
    local minY, maxY = math.min(ay, by, cy), math.max(ay, by, cy)
    maxX, maxY = math.max(maxX, minX + 0.01), math.max(maxY, minY + 0.01)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", frame, "TOPLEFT", minX, -minY)
    t:SetSize(maxX - minX, maxY - minY)
    -- Offsets are from each corner's own place, with y pointing up.
    t:SetVertexOffset(UL, ax - minX, -(ay - minY))
    t:SetVertexOffset(LL, bx - minX, -(by - maxY))
    t:SetVertexOffset(UR, cx - maxX, -(cy - minY))
    t:SetVertexOffset(LR, cx - maxX, -(cy - maxY))
    t:Show()
end

-- What a picture captured: a gold wedge from where you stood, the way you faced, as wide as
-- the camera sees. facing: radians, 0 = north, anticlockwise (as GetPlayerFacing gives it).
-- Drawn with lines only (texture-corner triangles drew as rectangles here): the fill is rings
-- of short curved bands, one inside the next, so they barely overlap and the colour is even;
-- the outline is the two edges and the curved far end.
-- reach: how far the cone extends, in the canvas's own units.
local RINGS, SEGMENT = 8, 10 -- bands from the spot outward; roughly how long each piece of a band is
UI.CONE_SHARE = 0.08 -- the cone's reach as a share of its map's width, here and on the world map
function UI.DrawCone(canvas, cone, x, y, facing, fov, reach)
    local half = math.rad(math.max(25, math.min(60, (fov or 90) / 2)))
    local function point(r, a) return x - math.sin(a) * r, y - math.cos(a) * r end
    local c = UI.PIN.place
    local function line(pool, i, layer, thick, r, g, b, a, x1, y1, x2, y2)
        local l = pool[i]
        if not l then
            l = canvas:CreateLine(nil, "ARTWORK", nil, layer)
            pool[i] = l
        end
        l:SetThickness(thick)
        l:SetColorTexture(r, g, b, a)
        l:SetStartPoint("TOPLEFT", canvas, x1, -y1)
        l:SetEndPoint("TOPLEFT", canvas, x2, -y2)
        l:Show()
    end
    -- The fill: each ring a chain of short pieces along its arc, as thick as the ring is wide.
    local dr, n = reach / RINGS, 0
    for ring = 1, RINGS do
        local r = (ring - 0.5) * dr
        local pieces = math.max(1, math.ceil(2 * half * r / SEGMENT))
        for k = 0, pieces - 1 do
            local a1 = facing - half + 2 * half * k / pieces
            local a2 = facing - half + 2 * half * (k + 1) / pieces
            local x1, y1 = point(r, a1)
            local x2, y2 = point(r, a2)
            n = n + 1
            line(cone.fill, n, 2, dr, c[1], c[2], c[3], 0.3, x1, y1, x2, y2)
        end
    end
    for i = n + 1, #cone.fill do cone.fill[i]:Hide() end
    -- The outline: both edges, then the far end as a curve, so it reads over bright map art.
    local er, eg, eb = c[1] * 0.6, c[2] * 0.6, c[3] * 0.4
    local m = 0
    for _, a in ipairs({ facing - half, facing + half }) do
        local ex, ey = point(reach, a)
        m = m + 1
        line(cone.lines, m, 3, 1.5, er, eg, eb, 0.9, x, y, ex, ey)
    end
    local pieces = math.max(2, math.ceil(2 * half * reach / SEGMENT))
    for k = 0, pieces - 1 do
        local x1, y1 = point(reach, facing - half + 2 * half * k / pieces)
        local x2, y2 = point(reach, facing - half + 2 * half * (k + 1) / pieces)
        m = m + 1
        line(cone.lines, m, 3, 1.5, er, eg, eb, 0.9, x1, y1, x2, y2)
    end
    for i = m + 1, #cone.lines do cone.lines[i]:Hide() end
end

-- Puts the game's own waypoint pin on the world map (with the on-screen arrow) and opens the
-- map there. There's only one such pin, so this replaces any you placed yourself.
function UI.Waypoint(mapID, x, y, label)
    mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
    if not (mapID and x and y and C_Map.SetUserWaypoint and UiMapPoint) then return end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
        ns.Print("The game doesn't allow a waypoint on that map.")
        return
    end
    local ok = pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
    end)
    if not ok then
        ns.Print("Couldn't place a waypoint there.")
        return
    end
    ns.Print(string.format("Waypoint set%s (%.1f, %.1f).", label and (" for " .. label) or "", x * 100, y * 100))
    ns.MapPins.Open(mapID)
end

-- The page thumbnail. Clicking it pins `layer` ({ kind, id }, see MapPins.lua) to the game's
-- world map and opens it there. A page can hold several.
function Doc:Map(mapID, spots, layer)
    self.nm = self.nm + 1
    local m = self.maps[self.nm]
    if not m then
        m = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        m:SetClipsChildren(true)
        m:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        m:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
        m:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.5)
        m:SetScript("OnClick", function(b)
            if b.layer then ns.MapPins.Show(b.layer[1], b.layer[2], b.mapID) else ns.MapPins.Open(b.mapID) end
        end)
        m:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_CURSOR")
            GameTooltip:SetText("Show on your world map")
            GameTooltip:AddLine("Pins these to the game's map. Right-click a pin there to remove it.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        m:SetScript("OnLeave", GameTooltip_Hide)
        self.maps[self.nm] = m
    end
    m.mapID, m.spots, m.layer = mapID, spots, layer

    local w = self.width - 8
    local h = PaintMap(m, mapID, spots, w, 6)
    m:SetSize(w, h)
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", 8, -self.y)
    m:Show()
    self.y = self.y + h + 4
    self:Faded(layer and "Click the map to show these on your world map." or "Click the map to open it on your world map.")
end

------------------------------------------------------------------------------
-- Photographs (see Photos.lua): a developed picture on the page, and a larger viewer
------------------------------------------------------------------------------

local viewer

-- Crops a texture of the given shape (width / height) to fill a frame of another, evenly.
local function CropTo(tex, aspect, frameAspect)
    if aspect > frameAspect then
        local cut = (1 - frameAspect / aspect) / 2
        tex:SetTexCoord(cut, 1 - cut, 0, 1)
    else
        local cut = (1 - aspect / frameAspect) / 2
        tex:SetTexCoord(0, 1, cut, 1 - cut)
    end
end

-- The whole picture, as large as fits, over everything; Esc or a click closes it.
function UI.ShowPhoto(path, title, aspect)
    if not viewer then
        viewer = CreateFrame("Button", "CaptainsLogPhoto", UIParent, "BackdropTemplate")
        viewer:SetFrameStrata("DIALOG")
        viewer:SetBackdrop({
            bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        viewer:SetBackdropColor(0.27, 0.15, 0.07, 1)
        viewer:SetBackdropBorderColor(0.78, 0.62, 0.32, 1)
        viewer:SetPoint("CENTER")
        viewer.image = viewer:CreateTexture(nil, "ARTWORK")
        viewer.image:SetPoint("TOPLEFT", 14, -40)
        viewer.image:SetPoint("BOTTOMRIGHT", -14, 14)
        viewer.title = UI.Text(viewer, 16, { 0.98, 0.9, 0.7 }, UI.HEADING_FONT)
        viewer.title:SetPoint("TOPLEFT", 16, -14)
        viewer.title:SetPoint("RIGHT", -40, 0)
        viewer.title:SetWordWrap(false)
        local close = CreateFrame("Button", nil, viewer, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        viewer:SetScript("OnClick", viewer.Hide)
        tinsert(UISpecialFrames, "CaptainsLogPhoto")
    end
    -- Uncropped, in its own shape, within 85% of the screen either way.
    aspect = aspect or 2
    local w = math.min(1400, UIParent:GetWidth() * 0.85)
    local h = w / aspect
    local maxH = UIParent:GetHeight() * 0.85 - 54
    if h > maxH then h, w = maxH, maxH * aspect end
    viewer:SetSize(w + 28, h + 54)
    viewer.image:SetTexture(path)
    viewer.image:SetTexCoord(0, 1, 0, 1)
    viewer.title:SetText(title or "")
    viewer:Show()
    viewer:Raise()
end

-- A picture in a 2:1 frame at x, y (from the page's top-left), w wide, cropped evenly to fill
-- it (aspect = the picture's own width / height); click it to see the whole picture.
function Doc:PlacePicture(path, title, aspect, x, y, w)
    self.np = self.np + 1
    local b = self.pictures[self.np]
    if not b then
        b = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        b:SetBackdropColor(0, 0, 0, 0.6)
        b:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
        b.image = b:CreateTexture(nil, "ARTWORK")
        b.image:SetPoint("TOPLEFT", 1, -1)
        b.image:SetPoint("BOTTOMRIGHT", -1, 1)
        b:SetScript("OnClick", function(f) UI.ShowPhoto(f.path, f.title, f.aspect) end)
        b:SetScript("OnEnter", function(f)
            GameTooltip:SetOwner(f, "ANCHOR_CURSOR")
            GameTooltip:SetText("Click to see it whole")
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        self.pictures[self.np] = b
    end
    b.image:SetTexture(path)
    b.path, b.title, b.aspect = path, title, aspect or 2
    CropTo(b.image, b.aspect, 2)
    b:SetSize(w, w / 2)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", x, -y)
    b:Show()
end

-- A close-up of the map around one spot, in a 2:1 frame at x, y, w wide: the map drawn zoomed
-- in and moved so the spot sits in the middle (or as near as the map's edge allows), with its
-- pin and view cone. A click runs onClick (marking it on the world map), or opens that map.
local SPOT_ZOOM = 3
function Doc:PlaceSpotMap(mapID, spot, x, y, w, onClick)
    self.nsm = (self.nsm or 0) + 1
    self.spotMaps = self.spotMaps or {}
    local f = self.spotMaps[self.nsm]
    if not f then
        f = CreateFrame("Button", nil, self.child, "BackdropTemplate")
        f:SetClipsChildren(true)
        f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
        f:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.15)
        f:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
        f.canvas = CreateFrame("Frame", nil, f)
        f:SetScript("OnClick", function(b)
            if b.onClick then b.onClick() else ns.MapPins.Open(b.mapID) end
        end)
        f:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_CURSOR")
            GameTooltip:SetText(b.label or "Where it was taken")
            GameTooltip:AddLine(b.onClick and "Click to mark it on your world map" or "Click to open it on your world map", 1, 1, 1)
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", GameTooltip_Hide)
        self.spotMaps[self.nsm] = f
    end
    local h = w / 2
    f.mapID, f.label, f.onClick = mapID, spot.label, onClick
    f:SetSize(w, h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", x, -y)
    local cw = w * SPOT_ZOOM
    local ch = PaintMap(f.canvas, mapID, { spot }, cw, 8)
    f.canvas:SetSize(cw, ch)
    -- How far the canvas shifts left and up (both <= 0), keeping the frame covered.
    local left = math.max(w - cw, math.min(0, w / 2 - spot[1] * cw))
    local up = math.max(h - ch, math.min(0, h / 2 - spot[2] * ch))
    f.canvas:ClearAllPoints()
    f.canvas:SetPoint("TOPLEFT", left, -up)
    f:Show()
end

-- Full-width versions, written at the current line.
function Doc:Picture(path, title, aspect)
    local w = self.width - 8
    self:PlacePicture(path, title, aspect, 8, self.y, w)
    self.y = self.y + w / 2 + 6
    return true
end

function Doc:SpotMap(mapID, spot)
    local w = self.width - 8
    self:PlaceSpotMap(mapID, spot, 8, self.y, w)
    self.y = self.y + w / 2 + 6
end

-- One line of small text at x, y, cut to w wide (grid captions); doesn't move the page on.
function Doc:Label(text, x, y, w, color)
    self.nt = self.nt + 1
    local fs = self.texts[self.nt]
    if not fs then
        fs = self.child:CreateFontString(nil, "OVERLAY")
        fs:SetShadowOffset(0, 0)
        self.texts[self.nt] = fs
    end
    fs:SetFont(UI.BODY_FONT, 11, "")
    local c = color or UI.FADED
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetJustifyH("LEFT")
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", x, -y)
    fs:SetWidth(w)
    fs:SetWordWrap(false)
    fs:SetText(text)
    fs:Show()
end

function Doc:Finish()
    self.child:SetHeight(math.max(1, self.y))
    if self.keepScroll then
        local max = math.max(0, self.y - self.sf:GetHeight())
        self.sf:SetVerticalScroll(math.min(self.keepScroll, max))
        self.keepScroll = nil
    end
    self.updateFade()
end

function Doc:ScrollToEnd()
    C_Timer.After(0, function()
        self.sf:SetVerticalScroll(math.max(0, self.child:GetHeight() - self.sf:GetHeight()))
    end)
end

------------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------------

function UI.Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

function UI.Checkbox(parent, text, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local label = UI.Text(cb, 12)
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(text)
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
    cb:SetChecked(get())
    return cb
end

function UI.SearchBox(parent, width, onChange)
    local eb = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    eb:SetSize(width, 20)
    eb:HookScript("OnTextChanged", function(self) onChange(self:GetText()) end)
    return eb
end

-- Blizzard's modern dropdown over a fixed list of { value, label } options.
function UI.Dropdown(parent, width, options, get, set)
    local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dd:SetWidth(width)
    dd:SetupMenu(function(_, root)
        for _, opt in ipairs(options) do
            root:CreateRadio(opt[2], function() return get() == opt[1] end, function() set(opt[1]) end)
        end
    end)
    return dd
end
