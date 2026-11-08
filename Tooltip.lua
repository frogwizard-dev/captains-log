local _, ns = ...
local L = ns.L

-- Adds your history with a creature to its tooltip: "Killed 27 · last 2d ago".
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
        if not ns.db or not ns.db.settings.tooltip or not data then return end
        local id = ns.NpcID(data.guid)
        local m = id and ns.db.mobs[id]
        if not m then return end

        local line
        if m.kills > 0 then
            line = L["Killed %s"]:format(ns.Number(m.kills))
            if m.lastKill then line = line .. L["  ·  last %s"]:format(ns.Ago(m.lastKill)) end
        else
            line = L["Met, never slain"]
        end
        tooltip:AddLine("|cffd8b56a" .. L["Captain's Log:"] .. "|r " .. line, 0.9, 0.85, 0.7)
        if m.killedMe > 0 then
            tooltip:AddLine((m.killedMe == 1 and L["Has killed you %d time"] or L["Has killed you %d times"]):format(m.killedMe), 1, 0.45, 0.4)
        end
    end)
end
