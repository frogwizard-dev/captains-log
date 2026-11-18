local _, ns = ...
local L = ns.L
local UI = {}
ns.UI = UI

-- Ink on parchment.
UI.INK = { 0.22, 0.13, 0.05 }
UI.FADED = { 0.46, 0.36, 0.22 }
UI.ACCENT = { 0.50, 0.12, 0.05 }
-- Their Cyrillic versions on a Russian client, the game's own font on a Korean or Chinese one.
UI.HEADING_FONT = FrogLib.Media.ForClient("Fonts\\MORPHEUS.TTF")
UI.BODY_FONT = FrogLib.Media.ForClient("Fonts\\FRIZQT__.TTF")
UI.LINK_BLUE = { 0.11, 0.31, 0.55 } -- clickable words and buttons
local WHITE = "Interface\\Buttons\\WHITE8X8"
local LINK_BLUE = UI.LINK_BLUE

-- White (common) and grey (poor) item names vanish on parchment; re-ink them. Links come as
-- either "|cffRRGGBB" or the newer "|cnIQ<quality>:" colour codes.
function UI.Ink(link)
    if not link then return "?" end
    link = link:gsub("|cnIQ1:", "|cff2e1d0c"):gsub("|cffffffff", "|cff2e1d0c")
    link = link:gsub("|cnIQ0:", "|cff6b5d4f"):gsub("|cff9d9d9d", "|cff6b5d4f")
    return link
end

-- Items by ID for the newer log entries and the level snapshots. The game may not have an item
-- cached yet: then it's asked for, and the book redraws when it arrives (once per item).
local asked = {}
local function AskItem(id)
    if asked[id] or not (Item and Item.CreateFromItemID) then return end
    asked[id] = true
    pcall(function()
        local item = Item:CreateFromItemID(id)
        if item:IsItemEmpty() then return end
        item:ContinueOnItemLoad(function() ns.Refresh() end)
    end)
end

local function ItemInfo(id)
    local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not GetInfo then return end
    local ok, name, link, quality = pcall(GetInfo, id)
    if ok and name then return name, link, quality end
end

-- An item's link, re-inked for parchment; while it isn't cached, a stand-in in the colour of
-- `knownQuality` (if given) that still shows the item's tooltip on hover.
function UI.ItemLink(id, knownQuality)
    if type(id) ~= "number" then return L["an unknown item"] end
    local name, link, quality = ItemInfo(id)
    if link then return UI.Ink(link) end
    AskItem(id)
    local hex = "2e1d0c"
    quality = quality or knownQuality
    if quality and quality >= 2 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        and ITEM_QUALITY_COLORS[quality].hex then
        hex = ITEM_QUALITY_COLORS[quality].hex:gsub("|c%x%x", "")
    end
    return string.format("|cff%s|Hitem:%d|h[%s]|h|r", hex, id, name or L["item %s"]:format(id))
end

function UI.ItemIcon(id)
    if type(id) ~= "number" then return 134400 end
    local ok, icon = pcall(C_Item.GetItemIconByID, id)
    if ok and icon then return icon end
    AskItem(id)
    return 134400
end

-- Class colours darkened so light ones (priest white, rogue yellow) stay readable on parchment.
function UI.ClassInk(class)
    local r, g, b = FrogLib.Color.Class(class)
    if not r then return "|cff2e1d0c" end
    return string.format("|cff%02x%02x%02x", r * 150, g * 150, b * 150)
end

-- Long stretches of play: "3d 4h", "5h 12m".
function UI.LongDuration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds >= 86400 then
        return L["%dd %dh"]:format(math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
    end
    return ns.Duration(seconds)
end

-- Yards as a distance a reader feels: miles on English clients, kilometres elsewhere.
local IMPERIAL = { enUS = true, enGB = true }
function UI.Distance(yards)
    yards = yards or 0
    if IMPERIAL[ns.locale] then
        if yards < 880 then return L["%s yards"]:format(ns.Number(math.floor(yards))) end
        return L["%.1f miles"]:format(yards / 1760)
    end
    local metres = yards * 0.9144
    if metres < 1000 then return L["%s m"]:format(ns.Number(math.floor(metres))) end
    return L["%.1f km"]:format(metres / 1000)
end

local function SetInk(fontString, size, color, font)
    fontString:SetFont(font or UI.BODY_FONT, size or 12, "")
    local ink = color or UI.INK
    fontString:SetTextColor(ink[1], ink[2], ink[3])
end

function UI.Text(parent, size, color, font)
    local fontString = parent:CreateFontString(nil, "OVERLAY")
    SetInk(fontString, size, color, font)
    fontString:SetJustifyH("LEFT")
    fontString:SetShadowOffset(0, 0)
    return fontString
end

-- A tooltip with a title and an optional wrapped line.
local function ShowTip(owner, anchor, title, text)
    GameTooltip:SetOwner(owner, anchor)
    GameTooltip:SetText(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function ShowLinkTip(owner, anchor, link)
    GameTooltip:SetOwner(owner, anchor)
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

-- A parchment page: warm base colour with the quest-log parchment grain over it.
function UI.Page(parent)
    local page = CreateFrame("Frame", nil, parent)
    local base = page:CreateTexture(nil, "BACKGROUND", nil, -8)
    base:SetAllPoints()
    base:SetColorTexture(0.90, 0.82, 0.64)
    local grain = page:CreateTexture(nil, "BACKGROUND", nil, -7)
    grain:SetAllPoints()
    grain:SetTexture("Interface\\QuestFrame\\QuestBG")
    -- The parchment art only fills the top-left ~58% x 65% of the file, torn edges included;
    -- crop inside those edges so the grain covers the whole page.
    grain:SetTexCoord(0.03, 0.54, 0.03, 0.62)
    grain:SetAlpha(0.55)
    return page
end

-- Soft shadow along one edge (the book's spine).
function UI.Shade(page, side, width)
    local shade = page:CreateTexture(nil, "BACKGROUND", nil, -6)
    shade:SetTexture(WHITE)
    shade:SetWidth(width or 28)
    shade:SetPoint("TOP")
    shade:SetPoint("BOTTOM")
    shade:SetPoint(side)
    local dark, clear = CreateColor(0.2, 0.1, 0.02, 0.35), CreateColor(0.2, 0.1, 0.02, 0)
    if side == "RIGHT" then
        shade:SetGradient("HORIZONTAL", clear, dark)
    else
        shade:SetGradient("HORIZONTAL", dark, clear)
    end
end

local function Wheel(scroll, step)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, self:GetScrollChild():GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * step)))
    end)
end

-- A slim ink scroll bar beside a scroll frame, in the page's margin: drag the thumb or
-- click the track. Hidden when everything fits. Returns its update function.
local function ScrollBar(scroll)
    local bar = CreateFrame("Frame", nil, scroll)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 0)
    bar:SetWidth(6)
    bar:EnableMouse(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.10)
    local thumb = CreateFrame("Button", nil, bar)
    thumb:SetWidth(6)
    local thumbInk = thumb:CreateTexture(nil, "ARTWORK")
    thumbInk:SetAllPoints()
    thumbInk:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.45)
    local highlight = thumb:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.35)

    local function Range() return math.max(0, scroll:GetScrollChild():GetHeight() - scroll:GetHeight()) end
    local function Update()
        local range = Range()
        if range <= 1 then
            bar:Hide()
            return
        end
        bar:Show()
        local barHeight = bar:GetHeight()
        local thumbHeight = math.max(24, barHeight * scroll:GetHeight() / scroll:GetScrollChild():GetHeight())
        thumb:SetHeight(thumbHeight)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", 0, -(barHeight - thumbHeight) * math.min(1, scroll:GetVerticalScroll() / range))
    end
    local function CursorY()
        local _, y = GetCursorPosition()
        return y / bar:GetEffectiveScale()
    end
    local dragFrom, scrollFrom
    thumb:SetScript("OnMouseDown", function()
        dragFrom, scrollFrom = CursorY(), scroll:GetVerticalScroll()
    end)
    thumb:SetScript("OnMouseUp", function() dragFrom = nil end)
    thumb:SetScript("OnUpdate", function()
        if not dragFrom then return end
        local travel = bar:GetHeight() - thumb:GetHeight()
        if travel <= 0 then return end
        local position = scrollFrom + (dragFrom - CursorY()) * Range() / travel
        scroll:SetVerticalScroll(math.max(0, math.min(Range(), position)))
    end)
    -- Clicking the track jumps there.
    bar:SetScript("OnMouseDown", function(self)
        local share = (self:GetTop() - CursorY()) / self:GetHeight()
        scroll:SetVerticalScroll(math.max(0, math.min(Range(), share * Range())))
    end)
    return Update
end

-- A scroll frame with the mouse wheel and an ink scroll bar: the frame, its child, the bar's update.
local function ScrollArea(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetSize(width, height)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, 1)
    scroll:SetScrollChild(child)
    Wheel(scroll, 40)
    local updateBar = ScrollBar(scroll)
    scroll:SetScript("OnVerticalScroll", updateBar)
    scroll:SetScript("OnScrollRangeChanged", updateBar)
    return scroll, child, updateBar
end

------------------------------------------------------------------------------
-- List: clickable rows with left/right text and a selection mark.
------------------------------------------------------------------------------

local List = {}
List.__index = List

function UI.List(parent, width, height)
    local scroll, child, updateBar = ScrollArea(parent, width, height)
    return setmetatable({ scroll = scroll, child = child, rows = {}, width = width, rowHeight = 20,
        updateBar = updateBar }, List)
end

-- items: { { key, left, right, color } }; onClick(key)
function List:SetItems(items, selected, onClick)
    for i, item in ipairs(items) do
        local row = self.rows[i]
        if not row then
            row = CreateFrame("Button", nil, self.child)
            row:SetSize(self.width, self.rowHeight)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * self.rowHeight)
            local highlight = row:CreateTexture(nil, "BACKGROUND")
            highlight:SetAllPoints()
            highlight:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
            row:SetHighlightTexture(highlight)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:SetColorTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.15)
            row.left = UI.Text(row, 12)
            row.left:SetPoint("LEFT", 4, 0)
            row.left:SetWordWrap(false)
            row.right = UI.Text(row, 11, UI.FADED)
            row.right:SetPoint("RIGHT", -4, 0)
            row.right:SetJustifyH("RIGHT")
            row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
            self.rows[i] = row
        end
        -- Header rows ({ header = true }) title a group: heading ink, not clickable.
        local header = item.header
        local ink = item.color or (header and UI.ACCENT) or UI.INK
        row.left:SetFont(header and UI.HEADING_FONT or UI.BODY_FONT, header and 14 or 12, "")
        row.left:SetPoint("LEFT", header and 2 or (item.indent or 4), 0)
        row.left:SetText(item.left)
        row.left:SetTextColor(ink[1], ink[2], ink[3])
        row.right:SetText(item.right or "")
        row.sel:SetShown(not header and item.key == selected)
        row:EnableMouse(not header)
        row:SetScript("OnClick", function() onClick(item.key) end)
        row:Show()
    end
    for i = #items + 1, #self.rows do
        self.rows[i]:Hide()
    end
    self.child:SetHeight(math.max(1, #items * self.rowHeight))
    self.updateBar()
    local maxScroll = math.max(0, self.child:GetHeight() - self.scroll:GetHeight())
    if self.scroll:GetVerticalScroll() > maxScroll then self.scroll:SetVerticalScroll(maxScroll) end
    -- Arriving by a link: scroll the chosen row into the middle of the list.
    if self.revealKey ~= nil then
        for i, item in ipairs(items) do
            if item.key == self.revealKey then
                local target = (i - 1) * self.rowHeight - (self.scroll:GetHeight() - self.rowHeight) / 2
                self.scroll:SetVerticalScroll(math.max(0, math.min(maxScroll, target)))
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

-- A book link's registered kind and its args (a list), or nil for any other link.
local function LinkKind(link)
    local body = link:match("^clog:(.*)$")
    if not body then return end
    local parts = { strsplit(":", body) }
    return linkKinds[parts[1]], { unpack(parts, 2) }
end

local function HyperlinkEnter(self, link)
    if link:match("^clog:") then
        local kind, args = LinkKind(link)
        if not (kind and kind.tip) then return end
        local title, text = kind.tip(unpack(args))
        if title then ShowTip(self, "ANCHOR_CURSOR", title, text) end
        return
    end
    ShowLinkTip(self, "ANCHOR_CURSOR", link)
end

local function HyperlinkClick(_, link)
    if link:match("^clog:") then
        local kind, args = LinkKind(link)
        if kind then
            GameTooltip:Hide()
            kind.click(unpack(args))
        end
    end
    -- No shift-click into chat: text an add-on puts in the chat box makes that message refused while chat is
    -- restricted, and opening or focusing the box from here taints its state (EllesmereUI found both).
end

------------------------------------------------------------------------------
-- Doc: a scrolling page of headings, lines and item rows, rebuilt on each render.
------------------------------------------------------------------------------

local Doc = {}
Doc.__index = Doc

-- The widgets a page reuses from one render to the next, by kind (Doc:Take).
local POOLS = { "texts", "items", "cells", "maps", "chips", "pictures", "spotMaps", "bars" }

function UI.Doc(parent, width, height)
    local scroll, child, updateBar = ScrollArea(parent, width, height)
    -- Item links written into lines show their tooltip on hover; book links act on click.
    child:SetHyperlinksEnabled(true)
    child:SetScript("OnHyperlinkEnter", HyperlinkEnter)
    child:SetScript("OnHyperlinkLeave", GameTooltip_Hide)
    child:SetScript("OnHyperlinkClick", HyperlinkClick)
    local doc = setmetatable({ scroll = scroll, child = child, width = width, y = 0, updateBar = updateBar,
        pools = {}, used = {} }, Doc)
    for _, kind in ipairs(POOLS) do doc.pools[kind], doc.used[kind] = {}, 0 end
    return doc
end

-- The next widget of a kind for this render, made by Make(doc) the first time one is needed.
function Doc:Take(kind, Make)
    local index = self.used[kind] + 1
    self.used[kind] = index
    local pool = self.pools[kind]
    pool[index] = pool[index] or Make(self)
    return pool[index]
end

-- Starts the page afresh. `subject` names what's shown (a creature's ID, a day...): the same as
-- last time (a button pressed, new data) keeps the reader's scroll; a new one starts at the top.
function Doc:Clear(subject)
    self.keepScroll = subject ~= nil and subject == self.subject and self.scroll:GetVerticalScroll() or nil
    self.subject = subject
    for _, kind in ipairs(POOLS) do
        for _, widget in ipairs(self.pools[kind]) do widget:Hide() end
        self.used[kind] = 0
    end
    self.y = 0
    if not self.keepScroll then self.scroll:SetVerticalScroll(0) end
end

local function MakeText(doc)
    local fontString = doc.child:CreateFontString(nil, "OVERLAY")
    fontString:SetJustifyH("LEFT")
    fontString:SetShadowOffset(0, 0)
    return fontString
end

-- `reserve` keeps that many pixels free at the right end, for action buttons (Doc:Row).
function Doc:Text(text, size, color, font, indent, reserve)
    local fontString = self:Take("texts", MakeText)
    indent = indent or 0
    SetInk(fontString, size, color, font)
    fontString:ClearAllPoints()
    fontString:SetPoint("TOPLEFT", indent, -self.y)
    fontString:SetWidth(self.width - indent - (reserve or 0))
    fontString:SetWordWrap(true) -- a grid caption (Doc:Label) may have used this line before
    fontString:SetText(text)
    fontString:Show()
    self.y = self.y + fontString:GetStringHeight() + 4
    return fontString
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

local function SetIcon(texture, action)
    if action.atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(action.atlas) then
        texture:SetAtlas(action.atlas)
        texture:SetTexCoord(0, 1, 0, 1)
    else
        texture:SetTexture(action.icon or "Interface\\Icons\\INV_Misc_Map_01")
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function MakeChip(doc)
    local chip = CreateFrame("Button", nil, doc.child, "BackdropTemplate")
    chip:SetHeight(CHIP_H)
    chip:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    chip:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
    chip:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.45)
    local highlight = chip:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    highlight:SetColorTexture(LINK_BLUE[1], LINK_BLUE[2], LINK_BLUE[3], 0.15)
    chip.icon = chip:CreateTexture(nil, "ARTWORK")
    chip.icon:SetSize(13, 13)
    chip.icon:SetPoint("LEFT", 4, 0)
    chip.text = UI.Text(chip, 11, LINK_BLUE)
    chip.text:SetPoint("LEFT", chip.icon, "RIGHT", 3, 0)
    chip:SetScript("OnEnter", function(self)
        if self.tip then ShowTip(self, "ANCHOR_TOP", self.tip[1], self.tip[2]) end
    end)
    chip:SetScript("OnLeave", GameTooltip_Hide)
    return chip
end

function Doc:Chip(action)
    local chip = self:Take("chips", MakeChip)
    SetIcon(chip.icon, action)
    chip.text:SetText(action[1])
    chip.tip = action.tip
    chip:SetScript("OnClick", function()
        GameTooltip:Hide()
        action.onClick()
    end)
    chip:SetWidth(math.ceil(chip.text:GetStringWidth()) + 26)
    return chip
end

-- Places action buttons right-aligned with their top at y; returns the width they take.
function Doc:PlaceChips(actions, y)
    local x = 0
    for i = #actions, 1, -1 do
        local chip = self:Chip(actions[i])
        chip:ClearAllPoints()
        chip:SetPoint("TOPRIGHT", self.child, "TOPLEFT", self.width - x, -y)
        chip:Show()
        x = x + chip:GetWidth() + CHIP_GAP
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
        actions[#actions + 1] = { L["Map"], icon = "Interface\\Icons\\INV_Misc_Map_01", onClick = onMap,
            tip = { L["Show on your world map"],
                L["%s Right-click a pin there to remove it."]:format(mapTip or L["Pins this to the game's map."]) } }
    end
    if mapID and x and y then
        actions[#actions + 1] = { L["Waypoint"], atlas = "Waypoint-MapPin-ChatIcon", icon = "Interface\\Icons\\INV_Misc_Map02",
            onClick = function() UI.Waypoint(mapID, x, y) end,
            tip = { L["Waypoint"], L["Says the spot in chat with a map pin link: click it and the game puts its waypoint there and opens your map on it (click that pin to track it). It replaces any waypoint you placed yourself."] } }
    end
    return actions
end

function Doc:Line(text, color)
    self:Text(text, 12, color, nil, 8)
end

function Doc:Faded(text)
    self:Text(text, 11, UI.FADED, nil, 8)
end

function Doc:Gap(pixels)
    self.y = self.y + (pixels or 8)
end

-- A checklist line: a tick when done, a cross when not (or a waiting mark when `done` is nil).
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-%s:14:14:0:0|t "
function Doc:Check(text, done, color)
    local mark = done and "Ready" or (done == false and "NotReady" or "Waiting")
    self:Text(CHECK:format(mark) .. text, 12, color or (done and UI.FADED or nil), nil, 8)
end

local function MakeItem(doc)
    local button = CreateFrame("Button", nil, doc.child)
    button:SetSize(doc.width - 8, 20)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("LEFT")
    button.text = UI.Text(button, 12)
    button.text:SetPoint("LEFT", button.icon, "RIGHT", 6, 0)
    button.text:SetPoint("RIGHT")
    button.text:SetWordWrap(false)
    button:SetScript("OnEnter", function(self)
        if self.link then ShowLinkTip(self, "ANCHOR_RIGHT", self.link) end
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

-- An item with its icon; hover shows the item tooltip. Returns its button.
function Doc:Item(link, suffix, icon)
    local button = self:Take("items", MakeItem)
    button.link = link
    button.icon:SetTexture(icon or (link and C_Item.GetItemIconByID(link)) or 134400)
    button.text:SetText(UI.Ink(link) .. (suffix and ("  |cff5c4630" .. suffix .. "|r") or ""))
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", 8, -self.y)
    button:Show()
    self.y = self.y + 22
    return button
end

local CELL_H = 44

local function MakeCell(doc)
    local cell = CreateFrame("Button", nil, doc.child)
    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints()
    cell.bg:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.07)
    local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
    cell.rim = cell:CreateTexture(nil, "ARTWORK")
    cell.rim:SetSize(38, 38)
    cell.rim:SetPoint("LEFT", 3, 0)
    cell.rim:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
    cell.icon = cell:CreateTexture(nil, "ARTWORK", nil, 1)
    cell.icon:SetPoint("TOPLEFT", cell.rim, 1, -1)
    cell.icon:SetPoint("BOTTOMRIGHT", cell.rim, -1, 1)
    cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cell.name = UI.Text(cell, 11)
    cell.name:SetPoint("TOPLEFT", cell.rim, "TOPRIGHT", 6, 0)
    cell.name:SetPoint("RIGHT", -4, 0)
    cell.name:SetMaxLines(2)
    cell.note = UI.Text(cell, 11, UI.FADED)
    cell.note:SetPoint("BOTTOMLEFT", cell.rim, "BOTTOMRIGHT", 6, 0)
    cell.note:SetPoint("RIGHT", -4, 0)
    cell.note:SetWordWrap(false)
    cell:SetScript("OnEnter", function(self)
        if self.link then
            ShowLinkTip(self, "ANCHOR_RIGHT", self.link)
        elseif self.tipTitle then
            ShowTip(self, "ANCHOR_RIGHT", self.tipTitle, self.tipText)
        end
    end)
    cell:SetScript("OnLeave", GameTooltip_Hide)
    return cell
end

-- Items as a merchant-style grid: icon, name (up to two lines) and a note such as the price.
-- entries = { { link, icon, note } }
function Doc:Grid(entries, columns)
    columns = columns or 2
    local gap = 8
    local cellWidth = (self.width - 8 - gap * (columns - 1)) / columns
    for i, entry in ipairs(entries) do
        local cell = self:Take("cells", MakeCell)
        cell.link, cell.tipTitle, cell.tipText = entry.link, entry.tipTitle, entry.tipText
        cell:SetSize(cellWidth, CELL_H)
        cell.icon:SetTexture(entry.icon or (entry.link and C_Item.GetItemIconByID(entry.link)) or 134400)
        -- Brackets dropped: a grid of "[Item]" reads busier than the merchant window.
        -- Entries without an item link (a trainer's spells) give a plain `name` instead.
        local name = entry.link and UI.Ink(entry.link) or entry.name or "?"
        cell.name:SetText((name:gsub("%[", ""):gsub("%]", "")))
        cell.note:SetText(entry.note or "")
        cell:SetAlpha(entry.dim and 0.5 or 1)
        local column, row = (i - 1) % columns, math.floor((i - 1) / columns)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", 8 + column * (cellWidth + gap), -(self.y + row * (CELL_H + 4)))
        cell:Show()
    end
    self.y = self.y + math.ceil(#entries / columns) * (CELL_H + 4)
end

-- The base map art is the unexplored parchment; the areas you've explored are separate
-- overlay pieces, cut into 256px tiles. Same layout maths as Blizzard's world map.
local TILE = 256
local function TileSize(index, count, total)
    if index < count then return TILE, TILE end
    local pixels = total % TILE
    if pixels == 0 then pixels = TILE end
    local file = 16
    while file < pixels do file = file * 2 end
    return pixels, file
end

local function DrawExplored(canvas, mapID, scale)
    canvas.overlays = canvas.overlays or {}
    for _, tile in ipairs(canvas.overlays) do tile:Hide() end
    local ok, explored = pcall(C_MapExplorationInfo.GetExploredMapTextures, mapID)
    if not ok or not explored then return end
    local count = 0
    for _, piece in ipairs(explored) do
        if not piece.isShownByMouseOver then
            local wide = math.ceil(piece.textureWidth / TILE)
            local tall = math.ceil(piece.textureHeight / TILE)
            for row = 1, tall do
                local pixelH, fileH = TileSize(row, tall, piece.textureHeight)
                for column = 1, wide do
                    local pixelW, fileW = TileSize(column, wide, piece.textureWidth)
                    count = count + 1
                    local tile = canvas.overlays[count]
                    if not tile then
                        tile = canvas:CreateTexture(nil, "ARTWORK", nil, 1)
                        canvas.overlays[count] = tile
                    end
                    tile:SetTexture(piece.fileDataIDs[(row - 1) * wide + column], nil, nil, "TRILINEAR")
                    tile:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
                    tile:SetSize(pixelW * scale, pixelH * scale)
                    tile:ClearAllPoints()
                    tile:SetPoint("TOPLEFT", (piece.offsetX + TILE * (column - 1)) * scale,
                        -(piece.offsetY + TILE * (row - 1)) * scale)
                    tile:SetVertexColor(1, 0.93, 0.8)
                    tile:Show()
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
    local color = UI.PIN[kind] or UI.PIN.kill
    return string.format("|T%s:9:9:0:0:8:8:0:8:0:8:%d:%d:%d|t %s", WHITE,
        math.floor(color[1] * 255), math.floor(color[2] * 255), math.floor(color[3] * 255), label)
end

local function PinEnter(pin)
    ShowTip(pin, "ANCHOR_RIGHT", pin.label)
end

-- Paints a zone map `width` wide onto `canvas` (base art, your explored areas, a dot per spot
-- {x, y} from 0-1) and returns its height. Used by the page thumbnails.
local function PaintMap(canvas, mapID, spots, width, dotSize)
    canvas.tiles, canvas.dots = canvas.tiles or {}, canvas.dots or {}
    for _, tile in ipairs(canvas.tiles) do tile:Hide() end
    for _, pin in ipairs(canvas.dots) do pin:Hide() end

    local height = width * 2 / 3
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local layer = ok and layers and layers[1]
    local okTextures, textures = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if layer and okTextures and textures and #textures > 0 then
        local scale = width / layer.layerWidth
        height = layer.layerHeight * scale
        local columns = math.ceil(layer.layerWidth / layer.tileWidth)
        for i, fileID in ipairs(textures) do
            local tile = canvas.tiles[i]
            if not tile then
                tile = canvas:CreateTexture(nil, "ARTWORK")
                canvas.tiles[i] = tile
            end
            tile:SetTexture(fileID)
            tile:SetSize(layer.tileWidth * scale, layer.tileHeight * scale)
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", ((i - 1) % columns) * layer.tileWidth * scale,
                -math.floor((i - 1) / columns) * layer.tileHeight * scale)
            tile:SetVertexColor(1, 0.93, 0.8) -- a little sepia to sit on the parchment
            tile:Show()
        end
        DrawExplored(canvas, mapID, scale)
    end
    -- Sized before anything is drawn on it: the view cone's triangles are shaped by moving
    -- texture corners (SetVertexOffset), which does nothing on a canvas with no size yet.
    canvas:SetSize(width, height)

    for i, spot in ipairs(spots) do
        local pin = canvas.dots[i]
        if not pin then
            pin = CreateFrame("Frame", nil, canvas)
            pin.rim = pin:CreateTexture(nil, "OVERLAY", nil, 1)
            pin.rim:SetAllPoints()
            pin.rim:SetColorTexture(0.15, 0.05, 0.02, 1)
            pin.fill = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            pin.fill:SetPoint("TOPLEFT", 1, -1)
            pin.fill:SetPoint("BOTTOMRIGHT", -1, 1)
            pin.icon = pin:CreateTexture(nil, "OVERLAY", nil, 3)
            pin.icon:SetAllPoints()
            pin:SetScript("OnEnter", PinEnter)
            pin:SetScript("OnLeave", GameTooltip_Hide)
            canvas.dots[i] = pin
        end
        local atlas = UI.PIN_ATLAS[spot.kind]
        local iconic = HasAtlas(atlas)
        if iconic then pin.icon:SetAtlas(atlas) end
        pin.icon:SetShown(iconic)
        pin.rim:SetShown(not iconic)
        pin.fill:SetShown(not iconic)
        local color = UI.PIN[spot.kind] or UI.PIN.kill
        pin.fill:SetColorTexture(color[1], color[2], color[3], 1)
        -- Icon pins sit above the dots so a quest giver isn't buried under kill spots.
        pin:SetFrameLevel(canvas:GetFrameLevel() + (iconic and 4 or 2))
        -- Labelled pins answer hover with their label; clicks still reach the map underneath
        -- (to put it on the world map).
        pin.label = spot.label
        pin:SetMouseMotionEnabled(spot.label ~= nil)
        pin:SetMouseClickEnabled(false)
        local size = iconic and math.floor(dotSize * 2.4) or dotSize
        pin:SetSize(size, size)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", canvas, "TOPLEFT", spot[1] * width, -spot[2] * height)
        pin:Show()
    end

    -- View cones for spots that say which way they faced (pictures).
    canvas.cones = canvas.cones or {}
    for _, cone in ipairs(canvas.cones) do
        for _, line in ipairs(cone.fill) do line:Hide() end
        for _, line in ipairs(cone.lines) do line:Hide() end
    end
    local count = 0
    for _, spot in ipairs(spots) do
        if spot.facing then
            count = count + 1
            canvas.cones[count] = canvas.cones[count] or { fill = {}, lines = {} }
            UI.DrawCone(canvas, canvas.cones[count], spot[1] * width, spot[2] * height, spot.facing, spot.fov,
                width * UI.CONE_SHARE)
        end
    end
    return height
end

-- A filled triangle in `frame`'s coordinates (x right, y down from its top-left): a plain
-- texture over its bounding box, with its corners moved onto the points (the fourth onto the third).
local UL, LL, UR, LR = UPPER_LEFT_VERTEX or 1, LOWER_LEFT_VERTEX or 2, UPPER_RIGHT_VERTEX or 3, LOWER_RIGHT_VERTEX or 4
function UI.DrawTriangle(texture, frame, ax, ay, bx, by, cx, cy)
    local minX, maxX = math.min(ax, bx, cx), math.max(ax, bx, cx)
    local minY, maxY = math.min(ay, by, cy), math.max(ay, by, cy)
    maxX, maxY = math.max(maxX, minX + 0.01), math.max(maxY, minY + 0.01)
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT", minX, -minY)
    texture:SetSize(maxX - minX, maxY - minY)
    -- Offsets are from each corner's own place, with y pointing up.
    texture:SetVertexOffset(UL, ax - minX, -(ay - minY))
    texture:SetVertexOffset(LL, bx - minX, -(by - maxY))
    texture:SetVertexOffset(UR, cx - maxX, -(cy - minY))
    texture:SetVertexOffset(LR, cx - maxX, -(cy - maxY))
    texture:Show()
end

-- What a picture captured: a gold wedge from where you stood, the way you faced (radians, 0 = north,
-- anticlockwise), as wide as the camera sees, `reach` long. Lines only (corner-moved triangles drew as
-- rectangles here): rings of short curved bands for an even fill, then the two edges and the far curve.
local RINGS, SEGMENT = 8, 10 -- bands from the spot outward; roughly how long each piece of a band is
UI.CONE_SHARE = 0.08 -- the cone's reach as a share of its map's width, here and on the world map
function UI.DrawCone(canvas, cone, x, y, facing, fov, reach)
    local half = math.rad(math.max(25, math.min(60, (fov or 90) / 2)))
    local function Point(radius, angle) return x - math.sin(angle) * radius, y - math.cos(angle) * radius end
    local color = UI.PIN.place
    local function Line(pool, index, layer, thickness, r, g, b, a, x1, y1, x2, y2)
        local line = pool[index]
        if not line then
            line = canvas:CreateLine(nil, "ARTWORK", nil, layer)
            pool[index] = line
        end
        line:SetThickness(thickness)
        line:SetColorTexture(r, g, b, a)
        line:SetStartPoint("TOPLEFT", canvas, x1, -y1)
        line:SetEndPoint("TOPLEFT", canvas, x2, -y2)
        line:Show()
    end
    -- The fill: each ring a chain of short pieces along its arc, as thick as the ring is wide.
    local ringWidth, fillCount = reach / RINGS, 0
    for ring = 1, RINGS do
        local radius = (ring - 0.5) * ringWidth
        local pieces = math.max(1, math.ceil(2 * half * radius / SEGMENT))
        for piece = 0, pieces - 1 do
            local x1, y1 = Point(radius, facing - half + 2 * half * piece / pieces)
            local x2, y2 = Point(radius, facing - half + 2 * half * (piece + 1) / pieces)
            fillCount = fillCount + 1
            Line(cone.fill, fillCount, 2, ringWidth, color[1], color[2], color[3], 0.3, x1, y1, x2, y2)
        end
    end
    for i = fillCount + 1, #cone.fill do cone.fill[i]:Hide() end
    -- The outline: both edges, then the far end as a curve, so it reads over bright map art.
    local edgeR, edgeG, edgeB = color[1] * 0.6, color[2] * 0.6, color[3] * 0.4
    local lineCount = 0
    for _, angle in ipairs({ facing - half, facing + half }) do
        local endX, endY = Point(reach, angle)
        lineCount = lineCount + 1
        Line(cone.lines, lineCount, 3, 1.5, edgeR, edgeG, edgeB, 0.9, x, y, endX, endY)
    end
    local pieces = math.max(2, math.ceil(2 * half * reach / SEGMENT))
    for piece = 0, pieces - 1 do
        local x1, y1 = Point(reach, facing - half + 2 * half * piece / pieces)
        local x2, y2 = Point(reach, facing - half + 2 * half * (piece + 1) / pieces)
        lineCount = lineCount + 1
        Line(cone.lines, lineCount, 3, 1.5, edgeR, edgeG, edgeB, 0.9, x1, y1, x2, y2)
    end
    for i = lineCount + 1, #cone.lines do cone.lines[i]:Hide() end
end

-- A map pin link in chat for a spot: click it and the game puts its own waypoint pin there and opens the map on it
-- (click the pin to track it, with the on-screen arrow). The book never places, tracks or opens these itself: the
-- game's waypoint event runs the map's code at once, under the add-on's taint, and Blizzard's quest pins are then
-- blocked in combat; the link's click is yours, so the game's code does it.
function UI.Waypoint(mapID, x, y, label)
    mapID, x, y = tonumber(mapID), tonumber(x), tonumber(y)
    if not (mapID and x and y) then return end
    local link = FrogLib.MapPins.Link(mapID, x, y)
    if not link then
        ns.Print(L["The game doesn't allow a waypoint on that map."])
        return
    end
    local where = label and string.format("%s (%.1f, %.1f)", label, x * 100, y * 100)
        or string.format("(%.1f, %.1f)", x * 100, y * 100)
    ns.Print(link .. " " .. where .. " |cff999999" .. L["Click the pin link to put the game's waypoint there."] .. "|r")
end

local function MakeMap(doc)
    local map = CreateFrame("Button", nil, doc.child, "BackdropTemplate")
    map:SetClipsChildren(true)
    map:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    map:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.08)
    map:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.5)
    map:SetScript("OnClick", function(self)
        if self.layer then ns.MapPins.Show(self.layer[1], self.layer[2], self.mapID) else ns.MapPins.Open(self.mapID) end
    end)
    map:SetScript("OnEnter", function(self)
        ShowTip(self, "ANCHOR_CURSOR", L["Show on your world map"],
            L["Pins these to the game's map. Right-click a pin there to remove it."])
    end)
    map:SetScript("OnLeave", GameTooltip_Hide)
    return map
end

-- The page thumbnail. Clicking it pins `layer` ({ kind, id }, see MapPins.lua) to the game's
-- world map and opens it there. A page can hold several.
function Doc:Map(mapID, spots, layer)
    local map = self:Take("maps", MakeMap)
    map.mapID, map.spots, map.layer = mapID, spots, layer
    local width = self.width - 8
    local height = PaintMap(map, mapID, spots, width, 6)
    map:SetSize(width, height)
    map:ClearAllPoints()
    map:SetPoint("TOPLEFT", 8, -self.y)
    map:Show()
    self.y = self.y + height + 4
    self:Faded(layer and L["Click the map to show these on your world map."] or L["Click the map to open it on your world map."])
end

------------------------------------------------------------------------------
-- Photographs (see Photos.lua): a developed picture on the page, and a larger viewer
------------------------------------------------------------------------------

local viewer

-- Crops a texture of the given shape (width / height) to fill a frame of another, evenly.
local function CropTo(texture, aspect, frameAspect)
    if aspect > frameAspect then
        local cut = (1 - frameAspect / aspect) / 2
        texture:SetTexCoord(cut, 1 - cut, 0, 1)
    else
        local cut = (1 - aspect / frameAspect) / 2
        texture:SetTexCoord(0, 1, cut, 1 - cut)
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
    local width = math.min(1400, UIParent:GetWidth() * 0.85)
    local height = width / aspect
    local maxHeight = UIParent:GetHeight() * 0.85 - 54
    if height > maxHeight then height, width = maxHeight, maxHeight * aspect end
    viewer:SetSize(width + 28, height + 54)
    viewer.image:SetTexture(path)
    viewer.image:SetTexCoord(0, 1, 0, 1)
    viewer.title:SetText(title or "")
    viewer:Show()
    viewer:Raise()
end

local function MakePicture(doc)
    local button = CreateFrame("Button", nil, doc.child, "BackdropTemplate")
    button:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    button:SetBackdropColor(0, 0, 0, 0.6)
    button:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
    button.image = button:CreateTexture(nil, "ARTWORK")
    button.image:SetPoint("TOPLEFT", 1, -1)
    button.image:SetPoint("BOTTOMRIGHT", -1, 1)
    button:SetScript("OnClick", function(self) UI.ShowPhoto(self.path, self.title, self.aspect) end)
    button:SetScript("OnEnter", function(self) ShowTip(self, "ANCHOR_CURSOR", L["Click to see it whole"]) end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

-- A picture in a 2:1 frame at x, y (from the page's top-left), `width` wide, cropped evenly to fill
-- it (aspect = the picture's own width / height); click it to see the whole picture.
function Doc:PlacePicture(path, title, aspect, x, y, width)
    local button = self:Take("pictures", MakePicture)
    button.image:SetTexture(path)
    button.path, button.title, button.aspect = path, title, aspect or 2
    CropTo(button.image, button.aspect, 2)
    button:SetSize(width, width / 2)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", x, -y)
    button:Show()
end

local function MakeSpotMap(doc)
    local frame = CreateFrame("Button", nil, doc.child, "BackdropTemplate")
    frame:SetClipsChildren(true)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.15)
    frame:SetBackdropBorderColor(UI.INK[1], UI.INK[2], UI.INK[3], 0.6)
    frame.canvas = CreateFrame("Frame", nil, frame)
    frame:SetScript("OnClick", function(self)
        if self.onClick then self.onClick() else ns.MapPins.Open(self.mapID) end
    end)
    frame:SetScript("OnEnter", function(self)
        ShowTip(self, "ANCHOR_CURSOR", self.label or L["Where it was taken"],
            self.onClick and L["Click to mark it on your world map"] or L["Click to open it on your world map"])
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
    return frame
end

-- A close-up of the map around one spot, in a 2:1 frame at x, y, `width` wide: zoomed in and moved
-- so the spot sits in the middle (as near as the map's edge allows), with its pin and view cone. A
-- click runs onClick (marking it on the world map), or opens that map.
local SPOT_ZOOM = 3
function Doc:PlaceSpotMap(mapID, spot, x, y, width, onClick)
    local frame = self:Take("spotMaps", MakeSpotMap)
    local height = width / 2
    frame.mapID, frame.label, frame.onClick = mapID, spot.label, onClick
    frame:SetSize(width, height)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", x, -y)
    local canvasWidth = width * SPOT_ZOOM
    local canvasHeight = PaintMap(frame.canvas, mapID, { spot }, canvasWidth, 8)
    frame.canvas:SetSize(canvasWidth, canvasHeight)
    -- How far the canvas shifts left and up (both <= 0), keeping the frame covered.
    local left = math.max(width - canvasWidth, math.min(0, width / 2 - spot[1] * canvasWidth))
    local up = math.max(height - canvasHeight, math.min(0, height / 2 - spot[2] * canvasHeight))
    frame.canvas:ClearAllPoints()
    frame.canvas:SetPoint("TOPLEFT", left, -up)
    frame:Show()
end

-- Full-width versions, written at the current line.
function Doc:Picture(path, title, aspect)
    local width = self.width - 8
    self:PlacePicture(path, title, aspect, 8, self.y, width)
    self.y = self.y + width / 2 + 6
    return true
end

function Doc:SpotMap(mapID, spot)
    local width = self.width - 8
    self:PlaceSpotMap(mapID, spot, 8, self.y, width)
    self.y = self.y + width / 2 + 6
end

-- One line of small text at x, y, cut to `width` wide (grid captions); doesn't move the page on.
function Doc:Label(text, x, y, width, color)
    local fontString = self:Take("texts", MakeText)
    SetInk(fontString, 11, color or UI.FADED)
    fontString:SetJustifyH("LEFT")
    fontString:ClearAllPoints()
    fontString:SetPoint("TOPLEFT", x, -y)
    fontString:SetWidth(width)
    fontString:SetWordWrap(false)
    fontString:SetText(text)
    fontString:Show()
end

local function MakeBar(doc)
    local bar = CreateFrame("Frame", nil, doc.child)
    bar:SetHeight(26)
    bar.label = UI.Text(bar, 12)
    bar.label:SetPoint("TOPLEFT", 0, 0)
    bar.label:SetWordWrap(false)
    bar.right = UI.Text(bar, 11, UI.FADED)
    bar.right:SetPoint("TOPRIGHT", 0, 0)
    bar.right:SetJustifyH("RIGHT")
    bar.label:SetPoint("RIGHT", bar.right, "LEFT", -6, 0)
    bar.track = bar:CreateTexture(nil, "ARTWORK")
    bar.track:SetPoint("BOTTOMLEFT", 0, 5)
    bar.track:SetPoint("BOTTOMRIGHT", 0, 5)
    bar.track:SetHeight(6)
    bar.track:SetColorTexture(UI.INK[1], UI.INK[2], UI.INK[3], 0.12)
    bar.fill = bar:CreateTexture(nil, "ARTWORK", nil, 1)
    bar.fill:SetPoint("TOPLEFT", bar.track)
    bar.fill:SetHeight(6)
    return bar
end

-- A labelled bar: the label on the left, `right` (an amount) on the right, and an inked bar
-- beneath, filled value / max of the way. color = { r, g, b } for the fill.
function Doc:Bar(label, value, max, right, color)
    local bar = self:Take("bars", MakeBar)
    local width = self.width - 8
    bar:SetWidth(width)
    bar.label:SetText(label)
    bar.right:SetText(right or "")
    local share = (max and max > 0) and math.max(0, math.min(1, (value or 0) / max)) or 0
    bar.fill:SetWidth(math.max(0.01, width * share))
    bar.fill:SetShown(share > 0)
    local fill = color or UI.ACCENT
    bar.fill:SetColorTexture(fill[1], fill[2], fill[3], 0.8)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", 8, -self.y)
    bar:Show()
    self.y = self.y + 28
end

function Doc:Finish()
    self.child:SetHeight(math.max(1, self.y))
    if self.keepScroll then
        local maxScroll = math.max(0, self.y - self.scroll:GetHeight())
        self.scroll:SetVerticalScroll(math.min(self.keepScroll, maxScroll))
        self.keepScroll = nil
    end
    self.updateBar()
end

function Doc:ScrollToEnd()
    C_Timer.After(0, function()
        self.scroll:SetVerticalScroll(math.max(0, self.child:GetHeight() - self.scroll:GetHeight()))
    end)
end

------------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------------

function UI.Button(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height or 22)
    button:SetText(text)
    return button
end

function UI.Checkbox(parent, text, get, set)
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkbox:SetSize(24, 24)
    local label = UI.Text(checkbox, 12)
    label:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
    label:SetText(text)
    checkbox:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    checkbox:SetScript("OnClick", function(self) set(self:GetChecked()) end)
    checkbox:SetChecked(get())
    return checkbox
end

function UI.SearchBox(parent, width, onChange)
    local box = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    box:SetSize(width, 20)
    box:HookScript("OnTextChanged", function(self) onChange(self:GetText()) end)
    return box
end

-- Blizzard's modern dropdown over a fixed list of { value, label } options.
function UI.Dropdown(parent, width, options, get, set)
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(width)
    dropdown:SetupMenu(function(_, root)
        for _, option in ipairs(options) do
            root:CreateRadio(option[2], function() return get() == option[1] end, function() set(option[1]) end)
        end
    end)
    return dropdown
end
