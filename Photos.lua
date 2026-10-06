local _, ns = ...
local issecret = ns.issecret

-- Pictures of the journey. Every screenshot (the game's own key, or the book's "Take a
-- picture") is written into that day's page as a photo card: where you stood, who you were
-- with, what you were looking at. With the one-time setup (see below), the card shows the
-- screenshot itself, straight from the game's Screenshots folder.

BINDING_HEADER_CAPTAINSLOG = "Captain's Log"
BINDING_NAME_CAPTAINSLOG_PICTURE = "Take a picture for the journal"
BINDING_NAME_CAPTAINSLOG_TOGGLE = "Open or close the book"

------------------------------------------------------------------------------
-- Taking a picture
------------------------------------------------------------------------------

local restoreUI, restoreBook, fromBook = false, false, false

local function Restore()
    if restoreUI and not InCombatLockdown() then UIParent:Show() end
    if restoreBook and ns.Book.frame then ns.Book.frame:Show() end
    restoreUI, restoreBook = false, false
end

-- The book steps out of shot; with "clean pictures" on, so does the whole interface (only out
-- of combat: hiding it mid-fight is blocked). Both come back once the picture is saved.
function ns.TakePicture()
    fromBook = true
    if ns.Book.frame and ns.Book.frame:IsShown() then
        ns.Book.frame:Hide()
        restoreBook = true
    end
    if ns.db.settings.photoClean and not InCombatLockdown() and UIParent:IsShown() then
        UIParent:Hide()
        restoreUI = true
    end
    -- One frame later, so the hidden interface is already gone from the picture.
    C_Timer.After(0.05, function()
        Screenshot()
        C_Timer.After(3, function() if restoreUI or restoreBook then Restore() end end) -- never stuck hidden
    end)
end

function CaptainsLog_TakePicture() ns.TakePicture() end
function CaptainsLog_Toggle() ns.Book:Toggle() end

------------------------------------------------------------------------------
-- Writing it down
------------------------------------------------------------------------------

local function Clean(v)
    if type(v) ~= "string" or issecret(v) or v == "" then return nil end
    return v
end

local function Group()
    local names = {}
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, math.min(GetNumGroupMembers(), 8) do
        local unit = prefix .. i
        if UnitExists(unit) and not FrogLib.Safe(UnitIsUnit(unit, "player")) then
            local name = Clean(UnitName(unit))
            if name then names[#names + 1] = name end
        end
    end
    return #names > 0 and names or nil
end

-- The file the game just saved: WoWScrnShot_MMDDYY_HHMMSS, in your chosen format.
local EXT = { jpeg = "jpg", jpg = "jpg", png = "png", tga = "tga" }
local function FileName(t)
    local format = GetCVar and GetCVar("screenshotFormat") or "jpeg"
    return ("WoWScrnShot_%s.%s"):format(date("%m%d%y_%H%M%S", t), EXT[format] or "jpg")
end

local function Record()
    local t = time()
    local mapID, x, y = ns.Position()
    local target = UnitExists("target") and not FrogLib.Safe(UnitIsUnit("target", "player")) and Clean(UnitName("target")) or nil
    local photo = {
        t = t, file = FileName(t),
        zone = ns.Zone(), place = Clean(GetSubZoneText and GetSubZoneText()),
        mapID = mapID, x = x, y = y, level = UnitLevel("player"),
        target = target, group = Group(),
    }
    -- The screenshot is the size of your screen; kept so the picture keeps its shape.
    if GetPhysicalScreenSize then photo.w, photo.h = GetPhysicalScreenSize() end
    -- Which way you faced (radians, 0 = north, turning anticlockwise) and how wide the camera
    -- sees, for the view cone on the card's map. The camera itself can't be read, so this is
    -- your character's facing: the same as the camera's unless you'd swung it round.
    local facing = GetPlayerFacing and GetPlayerFacing()
    if type(facing) == "number" and not issecret(facing) then photo.facing = facing end
    local ok, fov = pcall(GetCVar, "cameraFov")
    photo.fov = ok and tonumber(fov) or nil
    local day = ns.Day()
    day.photos = day.photos or {}
    table.insert(day.photos, photo)
    ns.Log("photo", { photoT = t, place = photo.place, zone = photo.zone })
    if fromBook then
        ns.Print(ns.db.settings.photosShow and "Picture taken for today's page; /reload to see it in the book."
            or "Picture taken for today's page.")
    end
end

ns.On("SCREENSHOT_SUCCEEDED", function()
    -- Only the book's own pictures, unless every screenshot goes in (the default).
    if fromBook or ns.db.settings.photosAll then Record() end
    fromBook = false
    Restore()
end)
ns.On("SCREENSHOT_FAILED", function()
    fromBook = false
    Restore()
end)

------------------------------------------------------------------------------
-- Finding the picture
------------------------------------------------------------------------------

-- The game only loads files from Interface\AddOns, so "Set up pictures.bat" (once) makes
-- Interface\AddOns\CaptainsLogShots a junction to the Screenshots folder: a folder of its own
-- with no .toc, so no addon update ever replaces it. Through it the game loads screenshots
-- directly, the moment they're taken. It can't tell a missing file from a real one, though,
-- so pictures are only shown once you've said the link is set up.
local SHOTS = "Interface\\AddOns\\CaptainsLogShots\\"

-- The game only notices new files when the interface loads, so a picture taken since then
-- can't be shown until a /reload. This file runs at every load, so this is when that was.
ns.sessionStart = time()

function ns.PhotoPending(photo)
    return photo.t >= ns.sessionStart
end

function ns.PhotoTexture(photo)
    if ns.db.settings.photosShow and photo.file then return SHOTS .. photo.file end
end

-- The shape of the picture: your screen's, recorded when it was taken (older cards: 16:9).
function ns.PhotoAspect(photo)
    if photo.w and photo.h and photo.h > 0 then return photo.w / photo.h end
    return 16 / 9
end

-- Screenshots the book has no card for, listed by "Set up pictures.bat" (Shots.lua), become
-- cards on their day: just the picture and its time, as nothing else was recorded. Only days
-- already in the journal, and never a picture you removed.
local function ShotTime(file)
    local mo, d, y, h, mi, s = file:match("^WoWScrnShot_(%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)%.")
    if not mo then return end
    local t = time({ year = 2000 + tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    return ("20%s-%s-%s"):format(y, mo, d), t
end

function ns.ImportShots()
    local list = CaptainsLogShotList
    if type(list) ~= "table" or #list == 0 then return end
    local known = {}
    for _, day in pairs(ns.db.days) do
        for _, p in ipairs(day.photos or {}) do
            if p.file then known[p.file] = true end
        end
    end
    local removed, added, touched = ns.db.photoRemoved, 0, {}
    for _, file in ipairs(list) do
        if type(file) == "string" and not known[file] and not removed[file] then
            local key, t = ShotTime(file)
            local day = key and ns.db.days[key]
            if day then
                day.photos = day.photos or {}
                table.insert(day.photos, { t = t, file = file, imported = true })
                known[file] = true
                touched[day] = true
                added = added + 1
            end
        end
    end
    for day in pairs(touched) do
        table.sort(day.photos, function(a, b) return a.t < b.t end)
    end
    if added > 0 then
        ns.Print(("Added %d screenshot%s from your Screenshots folder to the journal."):format(added, added == 1 and "" or "s"))
    end
end
ns.On("PLAYER_LOGIN", function() ns.ImportShots() end)

-- Every photo with the day it belongs to, newest last; optionally only those taken in a land.
function ns.AllPhotos(zone)
    local list = {}
    for key, day in pairs(ns.db.days) do
        for i, p in ipairs(day.photos or {}) do
            if not zone or p.zone == zone then list[#list + 1] = { day = key, index = i, photo = p } end
        end
    end
    table.sort(list, function(a, b) return a.photo.t < b.photo.t end)
    return list
end

function ns.FindPhoto(t)
    for key, day in pairs(ns.db.days) do
        for i, p in ipairs(day.photos or {}) do
            if p.t == t then return p, key, i end
        end
    end
end
