local _, ns = ...
local L = ns.L

-- Adds your history with a creature to its tooltip: "Killed 27 · last 2d ago".
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, unitInfo)
        if not ns.db or not ns.db.settings.tooltip or not unitInfo then return end
        local id = ns.NpcID(unitInfo.guid)
        local mob = id and ns.db.mobs[id]
        if not mob then return end

        local line
        if mob.kills > 0 then
            line = L["Killed %s"]:format(ns.Number(mob.kills))
            if mob.lastKill then line = line .. L["  ·  last %s"]:format(ns.Ago(mob.lastKill)) end
        else
            line = L["Met, never slain"]
        end
        tooltip:AddLine("|cffd8b56a" .. L["Captain's Log:"] .. "|r " .. line, 0.9, 0.85, 0.7)
        if mob.killedMe > 0 then
            local template = mob.killedMe == 1 and L["Has killed you %d time"] or L["Has killed you %d times"]
            tooltip:AddLine(template:format(mob.killedMe), 1, 0.45, 0.4)
        end
    end)
end
