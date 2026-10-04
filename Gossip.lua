local _, ns = ...
local issecret = ns.issecret

-- What people say: each NPC's gossip window, written down as a conversation. The greeting and
-- every page reached from it keep their words (each version once, with when it was first and
-- last seen) and the replies offered there: how often each was offered and how often you chose
-- it. Choosing a reply that brings up another page from the same NPC files that page under it,
-- so the conversation grows into a tree as you explore it.
--
-- Saved on the NPC's People entry (db.npcs[id].gossip), a list of pages; [1] is the greeting:
--   page = { n = times seen, last, says = { { text, first, last } }, quests = { [questID] = title },
--            opts = { { name, icon, id = gossipOptionID, order, first, last, n = times offered,
--                       picks = times chosen, to = the page it led to, opens = "shop"... } } }
-- Each page's words are kept once per NPC: a page whose words match one already written down is
-- that page, wherever it was reached from, so a reply that loops back ("Tell me something else")
-- points at the page it returns to instead of copying it. Quests on a page are kept by ID (with
-- their title, for ones you never took); the quest journal keeps the rest.

local MAX_PAGES = 30  -- pages kept per NPC
local MAX_SAYS = 5    -- versions of one page's words; the one unseen longest makes way
local MAX_OPTS = 16   -- replies kept per page
local MAX_DEPTH = 8   -- how far down a conversation new pages are added
local MAX_TEXT = 1500 -- characters kept of one page's words
local FOLLOW = 5      -- seconds after a choice in which a new page counts as its answer
local OPENS = 3       -- seconds after a choice in which a shop or trainer opening is its doing
local VISIT = 60      -- the same page shown again this soon isn't counted again

local function Clean(v)
    if v == nil or issecret(v) then return nil end
    return v
end

-- What the gossip window shows right now: its words, its replies in the window's order, and the
-- quests listed on it. Anything hidden from addons is left out.
local function Read()
    local text = Clean(C_GossipInfo.GetText())
    if type(text) == "string" then
        text = strtrim(text)
        if text == "" then text = nil elseif #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    else
        text = nil
    end

    local opts = {}
    for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
        local name = Clean(o.name)
        if type(name) == "string" and name ~= "" then
            local id, order = Clean(o.gossipOptionID), Clean(o.orderIndex)
            opts[#opts + 1] = {
                name = name,
                icon = Clean(o.overrideIconID) or Clean(o.icon),
                id = (type(id) == "number" and id > 0) and id or nil,
                order = type(order) == "number" and order or #opts,
            }
        end
    end
    table.sort(opts, function(a, b) return a.order < b.order end)

    local quests = {}
    for _, fn in ipairs({ C_GossipInfo.GetAvailableQuests, C_GossipInfo.GetActiveQuests }) do
        local ok, list = pcall(fn)
        for _, q in ipairs(ok and list or {}) do
            local id, title = Clean(q.questID), Clean(q.title)
            if type(id) == "number" and id > 0 then
                quests[id] = (type(title) == "string" and title ~= "") and title or true
            end
        end
    end
    return text, opts, quests
end

-- One string per page as shown, to tell whether the window still shows the page last written.
local function Signature(text, opts)
    local parts = { text or "" }
    for _, o in ipairs(opts) do parts[#parts + 1] = o.name end
    return table.concat(parts, "\n")
end

-- The page (by its place in the list) whose words include `text`, if any.
local function FindSaid(pages, text)
    if not text then return end
    for i, page in ipairs(pages) do
        for _, s in ipairs(page.says) do
            if s[1] == text then return i end
        end
    end
end

-- A saved reply matching one on screen: by its option ID where both have one, else by name.
local function FindOpt(page, o)
    for _, e in ipairs(page.opts) do
        local same
        if o.id and e.id then same = o.id == e.id else same = e.name == o.name end
        if same then return e end
    end
end

local function Say(page, text, now)
    if not text then return end
    for _, s in ipairs(page.says) do
        if s[1] == text then
            s[3] = now
            return
        end
    end
    table.insert(page.says, { text, now, now })
    if #page.says > MAX_SAYS then
        local oldest = 1
        for i, s in ipairs(page.says) do
            if s[3] < page.says[oldest][3] then oldest = i end
        end
        table.remove(page.says, oldest)
    end
end

-- Notes the replies on screen against the page. `count` = this is a fresh look at the page.
local function Offer(page, opts, now, count)
    for _, o in ipairs(opts) do
        local e = FindOpt(page, o)
        if not e and #page.opts < MAX_OPTS then
            e = { first = now }
            table.insert(page.opts, e)
        end
        if e then
            e.name, e.id, e.order = o.name, o.id or e.id, o.order
            e.icon = o.icon or e.icon
            e.last = now
            if count or not e.n then e.n = (e.n or 0) + 1 end
        end
    end
end

local function NewPage()
    return { n = 0, says = {}, opts = {} }
end

local shown   -- the page on screen: { npc, page = its index, sig, at = GetTime(), depth }
local pending -- the reply just chosen: { npc, opt = its saved entry, at, depth, closed }
local lastPick -- { opt, at }, so one choice reaching us through two functions counts once
local counted = {} -- ["npc:page"] = GetTime() the page was last counted as seen
local depths = {}  -- ["npc:page"] = how many replies deep the page has been found

-- Writes down the page the gossip window shows: under the reply that led to it when one was just
-- chosen, otherwise as the greeting (or the page already kept with these words).
local function Record()
    local npc = ns.NpcID(UnitGUID("npc"))
    local n = npc and ns.db.npcs[npc]
    if not n then return end
    local text, opts, quests = Read()
    if not text and #opts == 0 then return end
    local sig = Signature(text, opts)
    -- Already written down this very moment (a lone reply the game picks as the window opens).
    if shown and shown.npc == npc and shown.sig == sig and shown.at == GetTime() then return end

    n.gossip = n.gossip or {}
    local pages = n.gossip
    local now = time()

    -- The answer to a reply just chosen: the same NPC, soon after, without the window closing
    -- in between (a reply that opens a shop closes it, and the next greeting is a new talk).
    local from = pending
    pending = nil
    if from and (from.npc ~= npc or GetTime() - from.at > FOLLOW
        or (from.closed and GetTime() - from.closed > 1)) then
        from = nil
    end

    local index, depth = FindSaid(pages, text), 0
    if from then
        depth = from.depth + 1
        local opt = from.opt -- nil after a page too deep to keep
        if not index and opt and opt.to and pages[opt.to] then index = opt.to end
        if not index and opt and depth <= MAX_DEPTH and #pages < MAX_PAGES then
            pages[#pages + 1] = NewPage()
            index = #pages
        end
        if not index then -- too deep, or this NPC's conversation is full
            shown = { npc = npc, sig = sig, at = GetTime(), depth = depth }
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
    local count = not counted[key] or GetTime() - counted[key] > VISIT
    counted[key] = GetTime()
    if count then page.n = (page.n or 0) + 1 end
    page.last = now
    Say(page, text, now)
    Offer(page, opts, now, count)
    if next(quests) then
        page.quests = page.quests or {}
        for id, title in pairs(quests) do page.quests[id] = title end
    end
    shown = { npc = npc, page = index, sig = sig, at = GetTime(), depth = depth }
    ns.Refresh()
end

-- A reply chosen: `match(o)` picks it out of the replies on screen. Counted against the page on
-- screen, and remembered so the page it brings up can be filed under it.
local function Choose(match, confirmed)
    local npc = ns.NpcID(UnitGUID("npc"))
    if not npc then return end
    local text, opts = Read()
    -- The window may have opened this moment, before the GOSSIP_SHOW below had its turn.
    if not shown or shown.npc ~= npc or shown.sig ~= Signature(text, opts) then Record() end
    if not (shown and shown.npc == npc) then return end
    if not shown.page then -- a page too deep to keep: whatever it leads to is deeper still
        pending = { npc = npc, at = GetTime(), depth = shown.depth }
        return
    end
    local n = ns.db.npcs[npc]
    local page = n and n.gossip and n.gossip[shown.page]
    if not page then return end

    local chosen
    for i, o in ipairs(opts) do
        if match(o, i) then
            chosen = o
            break
        end
    end
    local e = chosen and FindOpt(page, chosen)
    if not e then
        -- A reply that can't be placed (one past the page's limit, or one the client won't name):
        -- what it brings up can't be filed under it, but mustn't pass for the greeting either.
        -- (A confirmation of a reply already counted leaves that reply's answer to come.)
        if not (confirmed and pending and pending.npc == npc) then
            pending = { npc = npc, at = GetTime(), depth = shown.depth }
        end
        return
    end
    -- A reply that asks "Are you sure?" comes back through SelectOption once confirmed.
    local again = lastPick and lastPick.opt == e and GetTime() - lastPick.at < (confirmed and 30 or 1)
    if not again then e.picks = (e.picks or 0) + 1 end
    lastPick = { opt = e, at = GetTime() }
    pending = { npc = npc, opt = e, at = GetTime(), depth = shown.depth }
    ns.Refresh()
end

local function Enabled()
    return ns.db and ns.db.settings.gossip and C_GossipInfo
end

local function Safely(fn, ...)
    local ok, err = pcall(fn, ...)
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
        Safely(Choose, function(o) return o.order == index end)
    end)
end
if C_GossipInfo and C_GossipInfo.SelectOption then
    hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID, _, confirmed)
        if not Enabled() or type(optionID) ~= "number" then return end
        Safely(Choose, function(o) return o.id == optionID end, confirmed)
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
        local p = pending
        if p and p.opt and GetTime() - p.at <= OPENS and p.npc == ns.NpcID(UnitGUID("npc")) then
            p.opt.opens = what
        end
    end
end
ns.On("MERCHANT_SHOW", Opened("shop"))
ns.On("TRAINER_SHOW", Opened("training"))
ns.On("TAXIMAP_OPENED", Opened("flight"))
ns.On("BANKFRAME_OPENED", Opened("bank"))
