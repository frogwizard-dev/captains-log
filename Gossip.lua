local _, ns = ...

-- What people say: each NPC's gossip window, kept as a conversation tree on its People entry
-- (db.npcs[id].gossip, a list of pages, [1] the greeting). A page's words are kept once per NPC,
-- so a reply that loops back ("Tell me something else") points at the page it returns to; each
-- reply counts how often it was offered and chosen, and which page it led to.

local MAX_PAGES = 30  -- pages kept per NPC
local MAX_SAYS = 5    -- versions of one page's words; the one unseen longest makes way
local MAX_OPTS = 16   -- replies kept per page
local MAX_DEPTH = 8   -- how far down a conversation new pages are added
local MAX_TEXT = 1500 -- characters kept of one page's words
local FOLLOW = 5      -- seconds after a choice in which a new page counts as its answer
local OPENS = 3       -- seconds after a choice in which a shop or trainer opening is its doing
local VISIT = 60      -- the same page shown again this soon isn't counted again

local Clean = FrogLib.Safe -- nil for a value the game hides

-- What the gossip window shows right now: its words, its replies in the window's order, and the
-- quests listed on it. Anything hidden from addons is left out.
local function ReadWindow()
    local text = Clean(C_GossipInfo.GetText())
    if type(text) == "string" then
        text = strtrim(text)
        if text == "" then text = nil elseif #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    else
        text = nil
    end

    local replies = {}
    for _, option in ipairs(C_GossipInfo.GetOptions() or {}) do
        local name = Clean(option.name)
        if type(name) == "string" and name ~= "" then
            local id, order = Clean(option.gossipOptionID), Clean(option.orderIndex)
            replies[#replies + 1] = {
                name = name,
                icon = Clean(option.overrideIconID) or Clean(option.icon),
                id = (type(id) == "number" and id > 0) and id or nil,
                order = type(order) == "number" and order or #replies,
            }
        end
    end
    table.sort(replies, function(first, second) return first.order < second.order end)

    local quests = {}
    for _, GetQuests in ipairs({ C_GossipInfo.GetAvailableQuests, C_GossipInfo.GetActiveQuests }) do
        local ok, list = pcall(GetQuests)
        for _, quest in ipairs(ok and list or {}) do
            local id, title = Clean(quest.questID), Clean(quest.title)
            if type(id) == "number" and id > 0 then
                quests[id] = (type(title) == "string" and title ~= "") and title or true
            end
        end
    end
    return text, replies, quests
end

-- One string per page as shown, to tell whether the window still shows the page last written.
local function Signature(text, replies)
    local parts = { text or "" }
    for _, reply in ipairs(replies) do parts[#parts + 1] = reply.name end
    return table.concat(parts, "\n")
end

-- The page (by its place in the list) whose words include `text`, if any.
local function FindPage(pages, text)
    if not text then return end
    for i, page in ipairs(pages) do
        for _, version in ipairs(page.says) do
            if version[1] == text then return i end
        end
    end
end

-- A saved reply matching one on screen: by its option ID where both have one, else by name.
local function FindReply(page, reply)
    for _, saved in ipairs(page.opts) do
        local same
        if reply.id and saved.id then same = reply.id == saved.id else same = saved.name == reply.name end
        if same then return saved end
    end
end

local function Say(page, text, now)
    if not text then return end
    for _, version in ipairs(page.says) do
        if version[1] == text then
            version[3] = now
            return
        end
    end
    table.insert(page.says, { text, now, now })
    if #page.says > MAX_SAYS then
        local oldest = 1
        for i, version in ipairs(page.says) do
            if version[3] < page.says[oldest][3] then oldest = i end
        end
        table.remove(page.says, oldest)
    end
end

-- Notes the replies on screen against the page. `freshLook` = the page counts as seen again.
local function Offer(page, replies, now, freshLook)
    for _, reply in ipairs(replies) do
        local saved = FindReply(page, reply)
        if not saved and #page.opts < MAX_OPTS then
            saved = { first = now }
            table.insert(page.opts, saved)
        end
        if saved then
            saved.name, saved.id, saved.order = reply.name, reply.id or saved.id, reply.order
            saved.icon = reply.icon or saved.icon
            saved.last = now
            if freshLook or not saved.n then saved.n = (saved.n or 0) + 1 end
        end
    end
end

-- page = { n = times seen, last, says = { { text, first, last } }, quests = { [questID] = title },
--   opts = { { name, icon, id, order, first, last, n = times offered, picks, to = page, opens } } }
local function NewPage()
    return { n = 0, says = {}, opts = {} }
end

local shown   -- the page on screen: { npc, page = its index, signature, at = GetTime(), depth }
local pending -- the reply just chosen: { npc, opt = its saved entry, at, depth, closed }
local lastPick -- { opt, at }, so one choice reaching us through two functions counts once
local counted = {} -- ["npc:page"] = GetTime() the page was last counted as seen
local depths = {}  -- ["npc:page"] = how many replies deep the page has been found

-- Writes down the page the gossip window shows: under the reply that led to it when one was just
-- chosen, otherwise as the greeting (or the page already kept with these words).
local function Record()
    local npc = ns.NpcID(UnitGUID("npc"))
    local person = npc and ns.db.npcs[npc]
    if not person then return end
    local text, replies, quests = ReadWindow()
    if not text and #replies == 0 then return end
    local signature = Signature(text, replies)
    -- Already written down this very moment (a lone reply the game picks as the window opens).
    if shown and shown.npc == npc and shown.signature == signature and shown.at == GetTime() then return end

    person.gossip = person.gossip or {}
    local pages = person.gossip
    local now = time()

    -- The answer to a reply just chosen: the same NPC, soon after, the window not closed between
    -- (a reply that opens a shop closes it, and the next greeting is a new talk).
    local from = pending
    pending = nil
    if from and (from.npc ~= npc or GetTime() - from.at > FOLLOW
        or (from.closed and GetTime() - from.closed > 1)) then
        from = nil
    end

    local index, depth = FindPage(pages, text), 0
    if from then
        depth = from.depth + 1
        local opt = from.opt -- nil after a page too deep to keep
        if not index and opt and opt.to and pages[opt.to] then index = opt.to end
        if not index and opt and depth <= MAX_DEPTH and #pages < MAX_PAGES then
            pages[#pages + 1] = NewPage()
            index = #pages
        end
        if not index then -- too deep, or this NPC's conversation is full
            shown = { npc = npc, signature = signature, at = GetTime(), depth = depth }
            return
        end
        if opt then opt.to = index end
    elseif not index then
        index = 1
        pages[1] = pages[1] or NewPage()
    end

    local page = pages[index]
    local key = npc .. ":" .. index
    -- A page reached again by a shorter way (a loop back to the greeting) is that shallow.
    depth = math.min(depth, depths[key] or depth)
    depths[key] = depth
    local freshLook = not counted[key] or GetTime() - counted[key] > VISIT
    counted[key] = GetTime()
    if freshLook then page.n = (page.n or 0) + 1 end
    page.last = now
    Say(page, text, now)
    Offer(page, replies, now, freshLook)
    if next(quests) then
        page.quests = page.quests or {}
        for id, title in pairs(quests) do page.quests[id] = title end
    end
    shown = { npc = npc, page = index, signature = signature, at = GetTime(), depth = depth }
    ns.Refresh()
end

-- A reply chosen: `IsChosen(reply, i)` picks it out of the replies on screen. Counted against the
-- page on screen, and remembered so the page it brings up can be filed under it.
local function Choose(IsChosen, confirmed)
    local npc = ns.NpcID(UnitGUID("npc"))
    if not npc then return end
    local text, replies = ReadWindow()
    -- The window may have opened this moment, before the GOSSIP_SHOW below had its turn.
    if not shown or shown.npc ~= npc or shown.signature ~= Signature(text, replies) then Record() end
    if not (shown and shown.npc == npc) then return end
    if not shown.page then -- a page too deep to keep: whatever it leads to is deeper still
        pending = { npc = npc, at = GetTime(), depth = shown.depth }
        return
    end
    local person = ns.db.npcs[npc]
    local page = person and person.gossip and person.gossip[shown.page]
    if not page then return end

    local chosen
    for i, reply in ipairs(replies) do
        if IsChosen(reply, i) then
            chosen = reply
            break
        end
    end
    local saved = chosen and FindReply(page, chosen)
    if not saved then
        -- A reply that can't be placed (past the page's limit, or unnamed) files nothing, but its
        -- answer mustn't pass for the greeting. A confirmation leaves the counted reply's answer to come.
        if not (confirmed and pending and pending.npc == npc) then
            pending = { npc = npc, at = GetTime(), depth = shown.depth }
        end
        return
    end
    -- A reply that asks "Are you sure?" comes back through SelectOption once confirmed.
    local again = lastPick and lastPick.opt == saved and GetTime() - lastPick.at < (confirmed and 30 or 1)
    if not again then saved.picks = (saved.picks or 0) + 1 end
    lastPick = { opt = saved, at = GetTime() }
    pending = { npc = npc, opt = saved, at = GetTime(), depth = shown.depth }
    ns.Refresh()
end

local function Enabled()
    return ns.db and ns.db.settings.gossip and C_GossipInfo
end

local function Safely(step, ...)
    local ok, err = pcall(step, ...)
    if not ok then ns.Debug("Couldn't read the conversation: " .. tostring(err)) end
end

ns.On("GOSSIP_SHOW", function()
    if Enabled() then Safely(Record) end
end)

ns.On("GOSSIP_CLOSED", function()
    if pending then pending.closed = GetTime() end
end)

-- Choices, however they're made: the gossip window picks by its order index, a confirmation
-- (or another add-on) by option ID, and older code by position in the list. Hooked, never
-- replaced, so the game's own handling is untouched.
if C_GossipInfo and C_GossipInfo.SelectOptionByIndex then
    hooksecurefunc(C_GossipInfo, "SelectOptionByIndex", function(index)
        if not Enabled() or type(index) ~= "number" then return end
        Safely(Choose, function(reply) return reply.order == index end)
    end)
end
if C_GossipInfo and C_GossipInfo.SelectOption then
    hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID, _, confirmed)
        if not Enabled() or type(optionID) ~= "number" then return end
        Safely(Choose, function(reply) return reply.id == optionID end, confirmed)
    end)
end
if SelectGossipOption then
    hooksecurefunc("SelectGossipOption", function(position)
        if not Enabled() or type(position) ~= "number" then return end
        Safely(Choose, function(_, i) return i == position end)
    end)
end

-- Replies that open something else instead of another page: noted on the reply.
local function Opened(what)
    return function()
        local pick = pending
        if pick and pick.opt and GetTime() - pick.at <= OPENS and pick.npc == ns.NpcID(UnitGUID("npc")) then
            pick.opt.opens = what
        end
    end
end
ns.On("MERCHANT_SHOW", Opened("shop"))
ns.On("TRAINER_SHOW", Opened("training"))
ns.On("TAXIMAP_OPENED", Opened("flight"))
ns.On("BANKFRAME_OPENED", Opened("bank"))
