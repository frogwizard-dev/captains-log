local _, ns = ...
local L = ns.L
local issecret = ns.issecret

-- Pictures of the journey. Every screenshot (the game's own key, or the book's "Take a
-- picture") is written into that day's page as a photo card: where you stood, who you were
-- with, what you were looking at. With the one-time setup (see below), the card shows the
-- screenshot itself, straight from the game's Screenshots folder.

BINDING_HEADER_CAPTAINSLOG = L["Captain's Log"]
BINDING_NAME_CAPTAINSLOG_PICTURE = L["Take a picture for the journal"]
BINDING_NAME_CAPTAINSLOG_TOGGLE = L["Open or close the book"]

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

local Clean = ns.PlainText

local function Group()
    local names = {}
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, math.min(GetNumGroupMembers(), 8) do
        local unit = prefix .. i
        if UnitExists(unit) and not FrogLib.Unit.IsPlayer(unit) then
            local name = Clean(UnitName(unit))
            if name then names[#names + 1] = name end
        end
    end
    return #names > 0 and names or nil
end

-- The file the game just saved: WoWScrnShot_MMDDYY_HHMMSS, in your chosen format.
local EXTENSIONS = { jpeg = "jpg", jpg = "jpg", png = "png", tga = "tga" }
local function FileName(when)
    local format = GetCVar and GetCVar("screenshotFormat") or "jpeg"
    return ("WoWScrnShot_%s.%s"):format(date("%m%d%y_%H%M%S", when), EXTENSIONS[format] or "jpg")
end

local function Record()
    local now = time()
    local mapID, x, y = ns.Position()
    local target = UnitExists("target") and FrogLib.Unit.IsPlayer("target") == false and Clean(UnitName("target")) or nil
    local photo = {
        t = now, file = FileName(now),
        zone = ns.Zone(), place = Clean(GetSubZoneText and GetSubZoneText()),
        mapID = mapID, x = x, y = y, level = UnitLevel("player"),
        target = target, group = Group(),
    }
    -- The screenshot is the size of your screen; kept so the picture keeps its shape.
    if GetPhysicalScreenSize then photo.w, photo.h = GetPhysicalScreenSize() end
    -- Your facing (radians, 0 = north, anticlockwise) and the camera's width, for the card's view
    -- cone: the camera can't be read, so it's your character's facing, the camera's unless swung round.
    local facing = GetPlayerFacing and GetPlayerFacing()
    if type(facing) == "number" and not issecret(facing) then photo.facing = facing end
    local ok, fov = pcall(GetCVar, "cameraFov")
    photo.fov = ok and tonumber(fov) or nil
    local day = ns.Day()
    day.photos = day.photos or {}
    table.insert(day.photos, photo)
    ns.Log("photo", { photoT = now, place = photo.place, zone = photo.zone })
    if fromBook then
        ns.Print(ns.db.settings.photosShow and L["Picture taken for today's page; /reload to see it in the book."]
            or L["Picture taken for today's page."])
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

-- The game loads files only from Interface\AddOns, where "Set up pictures.bat" links CaptainsLogShots to
-- the Screenshots folder; a missing file can't be told from a real one, so pictures wait for that setting.
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

-- A screenshot's day and time, from its file name.
local function ShotTime(file)
    local month, day, year, hour, minute, second =
        file:match("^WoWScrnShot_(%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)(%d%d)%.")
    if not month then return end
    local when = time({ year = 2000 + tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second) })
    return ("20%s-%s-%s"):format(year, month, day), when
end

-- Screenshots with no card (listed by "Set up pictures.bat" in Shots.lua) become bare cards on their
-- day: only days already in the journal, and never a picture you removed.
function ns.ImportShots()
    local list = CaptainsLogShotList
    if type(list) ~= "table" or #list == 0 then return end
    local known = {}
    for _, day in pairs(ns.db.days) do
        for _, photo in ipairs(day.photos or {}) do
            if photo.file then known[photo.file] = true end
        end
    end
    local removed, added, touched = ns.db.photoRemoved, 0, {}
    for _, file in ipairs(list) do
        if type(file) == "string" and not known[file] and not removed[file] then
            local key, when = ShotTime(file)
            local day = key and ns.db.days[key]
            if day then
                day.photos = day.photos or {}
                table.insert(day.photos, { t = when, file = file, imported = true })
                known[file] = true
                touched[day] = true
                added = added + 1
            end
        end
    end
    for day in pairs(touched) do
        table.sort(day.photos, function(first, second) return first.t < second.t end)
    end
    if added > 0 then
        local template = added == 1 and L["Added %d screenshot from your Screenshots folder to the journal."]
            or L["Added %d screenshots from your Screenshots folder to the journal."]
        ns.Print(template:format(added))
    end
end
ns.On("PLAYER_LOGIN", function() ns.ImportShots() end)

-- Every photo with the day it belongs to, newest last; optionally only those taken in a land.
function ns.AllPhotos(zone)
    local list = {}
    for key, day in pairs(ns.db.days) do
        for i, photo in ipairs(day.photos or {}) do
            if not zone or photo.zone == zone then list[#list + 1] = { day = key, index = i, photo = photo } end
        end
    end
    table.sort(list, function(first, second) return first.photo.t < second.photo.t end)
    return list
end

function ns.FindPhoto(when)
    for key, day in pairs(ns.db.days) do
        for i, photo in ipairs(day.photos or {}) do
            if photo.t == when then return photo, key, i end
        end
    end
end
