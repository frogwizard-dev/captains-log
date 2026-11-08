local ADDON, ns = ...

-- Translations. Every bit of on-screen text is written in English in the code as L["..."]; a
-- language file (Locales\zhCN.lua, ...) fills ns.L with its own wording for the game's language.
-- Anything it doesn't have shows in English, so a half-done translation still works.
-- Keys keep their format codes (%s, %d): a translation may move them but must keep them in order.
ns.L = setmetatable({}, { __index = function(_, k) return k end })
ns.locale = GetLocale()

-- Adds a language's wording, if it's the game's language.
function ns.AddLocale(code, words)
    if code ~= ns.locale then return end
    for en, text in pairs(words) do
        if text and text ~= "" then rawset(ns.L, en, text) end
    end
end
