local _, ns = ...

-- Adds your history with a creature to its tooltip: "Killed 27 · last 2d ago".
if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
        if not ns.db or not ns.db.settings.tooltip or not data then return end
        local id = ns.NpcID(data.guid)
        local m = id and ns.db.mobs[id]
        if not m then return end

        local line
        if m.kills > 0 then
            line = "Killed " .. ns.Number(m.kills)
            if m.lastKill then line = line .. "  ·  last " .. ns.Ago(m.lastKill) end
        else
            line = "Met, never slain"
        end
        tooltip:AddLine("|cffd8b56aCaptain's Log:|r " .. line, 0.9, 0.85, 0.7)
        if m.killedMe > 0 then
            tooltip:AddLine("Has killed you " .. m.killedMe .. (m.killedMe == 1 and " time" or " times"), 1, 0.45, 0.4)
        end
    end)
end
