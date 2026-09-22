-- Commands.lua - Commandes slash pour contrôle manuel
Overlord = Overlord or {}

local L = Overlord.L

-- Mapping des alias de zones (pour faciliter les commandes)
local zoneAliases = {
    ["stromgarde"] = "stromgarde",
    ["strom"] = "stromgarde",
    ["faldir"] = "faldir",
    ["witherbark"] = "witherbark",
    ["wither"] = "witherbark",
    ["goshek"] = "goshek",
    ["dabyrie"] = "dabyrie",
    ["refuge"] = "refuge",
    ["highperch"] = "highperch",
    ["high"] = "highperch",
    ["perch"] = "highperch",
    ["newstead"] = "newstead",
    ["hammerfell"] = "hammerfell",
    ["hammer"] = "hammerfell",
    ["argorok"] = "argorok",
    ["argo"] = "argorok",
    ["gilneas_alliance_capital"] = "gilneas_alliance_capital",
    ["gilneas_horde_capital"] = "gilneas_horde_capital",
    ["eminence"] = "gilneas_eminence",
    ["l'eminence"] = "gilneas_eminence",
    ["quilleport"] = "gilneas_keel_harbor",
    ["keel"] = "gilneas_keel_harbor",
    ["phare"] = "gilneas_lighthouse",
    ["lighthouse"] = "gilneas_lighthouse",
    ["ilemaudite"] = "gilneas_lighthouse",
    ["pierrebraise"] = "gilneas_emberstone_mine",
    ["emberstone"] = "gilneas_emberstone_mine",
    ["aderic"] = "gilneas_aderic_repose",
    ["tempest"] = "gilneas_tempest_reach",
    ["tourmente"] = "gilneas_tempest_reach",
    ["stormglen"] = "gilneas_stormglen",
    ["valtempete"] = "gilneas_stormglen",
    ["cursed"] = "gilneas_hayward_fisheries",
    ["maudite"] = "gilneas_lighthouse",
    ["hayward"] = "gilneas_hayward_fisheries",
    ["pecheries"] = "gilneas_hayward_fisheries",
    ["thelsamar"] = "loch_alliance_capital",
    ["mogrosh"] = "loch_horde_capital",
    ["mo'grosh"] = "loch_horde_capital",
    ["vallee"] = "loch_valley_of_kings",
    ["valley"] = "loch_valley_of_kings",
    ["rois"] = "loch_valley_of_kings",
    ["portesud"] = "loch_south_gate_pass",
    ["southgate"] = "loch_south_gate_pass",
    ["ru"] = "loch_silver_stream_mine",
    ["ruissant"] = "loch_silver_stream_mine",
    ["silverstream"] = "loch_silver_stream_mine",
    ["algaz"] = "loch_algaz_post",
    ["postealgaz"] = "loch_algaz_post",
    ["farstrider"] = "loch_farstrider_lodge",
    ["peregrins"] = "loch_farstrider_lodge",
    ["ironband"] = "loch_ironband",
    ["excavations"] = "loch_ironband",
    ["loch"] = "loch_the_loch",
    ["barrage"] = "loch_stonewrought_dam",
    ["formepierre"] = "loch_stonewrought_dam",
    ["stonewrought"] = "loch_stonewrought_dam",
    ["sejour"] = "sb_alliance_capital",
    ["sejourhonneur"] = "sb_alliance_capital",
    ["honneur"] = "sb_alliance_capital",
    ["honorsstand"] = "sb_alliance_capital",
    ["honorstand"] = "sb_alliance_capital",
    ["desolation"] = "sb_horde_capital",
    ["desolationhold"] = "sb_horde_capital",
    ["bastion"] = "sb_horde_capital",
    ["folcrame"] = "sb_frazzlecraz_motherlode",
    ["frazzlecraz"] = "sb_frazzlecraz_motherlode",
    ["motherlode"] = "sb_frazzlecraz_motherlode",
    ["taurajo"] = "sb_ruins_of_taurajo",
    ["ruins"] = "sb_ruins_of_taurajo",
    ["lacis"] = "sb_the_tangle",
    ["tangle"] = "sb_the_tangle",
    ["guetdunord"] = "sb_northwatch_hold",
    ["northwatch"] = "sb_northwatch_hold",
    ["balafre"] = "sb_battlescar",
    ["battlescar"] = "sb_battlescar",
    ["chasseur"] = "sb_hunters_hill",
    ["collinechasseur"] = "sb_hunters_hill",
    ["huntershill"] = "sb_hunters_hill",
    ["hunters"] = "sb_hunters_hill",
    ["baelmodan"] = "sb_bael_modan",
    ["tranchebauge"] = "sb_razorfen_kraul",
    ["razorfen"] = "sb_razorfen_kraul",
    ["kraul"] = "sb_razorfen_kraul",
}

-- Résout un alias de zone
local function ResolveZoneAlias(input)
    if not input then return nil end
    local lower = string.lower(input)
    if lower == "alliance_capital" or lower == "base_alliance" then
        return Overlord.Fronts and Overlord.Fronts:GetCapitalId("Alliance") or lower
    elseif lower == "horde_capital" or lower == "base_horde" then
        return Overlord.Fronts and Overlord.Fronts:GetCapitalId("Horde") or lower
    end
    return zoneAliases[lower] or lower
end

-- Affiche l'aide des commandes
local function ShowFrontDebug()
    Overlord:CheckActiveFrontZone()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    local mapName = "?"
    if ok and mapID and C_Map.GetMapInfo then
        local okInfo, info = pcall(C_Map.GetMapInfo, mapID)
        if okInfo and info and info.name then mapName = info.name end
    end
    local playerFront = Overlord.GetPlayerMapFront and Overlord:GetPlayerMapFront()
    local reason = Overlord.GetFrontDetectionBlockReason and Overlord:GetFrontDetectionBlockReason()
    local wm = (C_PvP and C_PvP.IsWarModeActive and C_PvP.IsWarModeActive()) and "ON" or "OFF"
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r Diagnostic front :")
    local killScoring = Overlord.IsKillScoringActive and Overlord:IsKillScoringActive()
    local killZone = Overlord.Ressources and Overlord.Ressources.IsInOverlordKillZone
        and Overlord.Ressources:IsInOverlordKillZone()
    local temporaryKillZone = Overlord.IsInTemporaryKillScoringZone
        and Overlord:IsInTemporaryKillScoringZone()
    Overlord:PrintNotification(string.format("  InActiveFront=%s  KillScoring=%s  KillZone=%s  OutdoorPvPZone=%s  InstanceSuspended=%s  WarMode=%s",
        tostring(Overlord.InActiveFront), tostring(killScoring), tostring(killZone), tostring(temporaryKillZone),
        tostring(Overlord.InstanceSuspended), wm))
    Overlord:PrintNotification(string.format("  Carte=%s (UiMapID %s)  Front=%s  Actif=%s  Panel=%s",
        mapName, tostring(mapID),
        playerFront and playerFront.id or "nil",
        Overlord.Fronts and Overlord.Fronts.activeFrontId or "?",
        Overlord.UI and Overlord.UI:GetPanelViewFrontId() or "?"))
    if reason then
        Overlord:PrintNotification("  Blocage: |cFFFF6666" .. reason .. "|r")
    else
        Overlord:PrintNotification("  Blocage: |cFF66FF66aucun|r (activation attendue)")
    end
    local okInst, _, instType, _, _, _, _, _, instID = pcall(GetInstanceInfo)
    if okInst then
        Overlord:PrintNotification(string.format("  GetInstanceInfo: type=%s instID=%s  catchup=%s",
            tostring(instType), tostring(instID),
            tostring(Overlord.IsInCatchUpPhase and Overlord:IsInCatchUpPhase())))
    end
end

-- Diagnostic demande explicitement : conserver une trace exploitable meme quand
-- le client ne fournit aucun GUID sur place (PNJ / nameplates desactives).
local function ShowShardDebug()
    local shard = Overlord.Shard
    if not shard then return end
    shard:Update()
    local age = shard.currentShardID ~= nil and (GetTime() - shard.lastUpdateAt) or nil
    Overlord:PrintNotification(string.format(
        "|cFFFFD100[Overlord]|r Shard=%s  context=%s  source=%s  age=%s  groupRequest=%s",
        tostring(shard.currentShardID or "?"), tostring(shard.localContextKey),
        tostring(shard.localShardSource or "?"), age and string.format("%.1fs", age) or "?",
        tostring(shard.keepShardRequest ~= nil)))
    local gk = Overlord.GuildKeep
    if not gk then return end
    local onMap, site, mapKnown = gk:IsPlayerOnKeepMap()
    local inKeep, positionKnown = gk:IsPlayerInKeepGeometry(site)
    local st = site and gk:GetState(site.siteKey or site.id)
    Overlord:PrintNotification(string.format(
        "  Keep=%s  mapKnown=%s  inside=%s  positionKnown=%s  status=%s  anchor=%s  progress=%s",
        onMap and gk:GetDisplayName(site) or "?", tostring(mapKnown), tostring(inKeep),
        tostring(positionKnown), st and st.status or "?",
        st and tostring(st.assaultShardId or "?") or "?",
        st and tostring(math.floor(st.holdTimeElapsed or 0)) or "?"))
end

local function ShowHelp()
    Overlord:PrintNotification(L.HELP_HEADER)
    Overlord:PrintNotification(L.HELP_SHOW)
    Overlord:PrintNotification(L.HELP_HIDE)
    Overlord:PrintNotification(L.HELP_TOGGLE)
    Overlord:PrintNotification(L.HELP_HUD)
    Overlord:PrintNotification(L.HELP_STATUS)
    Overlord:PrintNotification(L.HELP_ZONES)
    Overlord:PrintNotification(L.HELP_WHERE)
    Overlord:PrintNotification(L.HELP_START)
    Overlord:PrintNotification(L.HELP_LB)
    Overlord:PrintNotification(L.HELP_SYNC)
    Overlord:PrintNotification(L.HELP_EXPORT)
    Overlord:PrintNotification(L.HELP_DOM)
    Overlord:PrintNotification(L.HELP_SCALE)
    Overlord:PrintNotification(L.HELP_GUIDE)
    Overlord:PrintNotification(L.HELP_FOOTER)
end

-- Affiche le statut de toutes les zones
local function ShowStatus()
    Overlord:PrintNotification(L.STATUS_HEADER)
    
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local statusIcon = ""
        local statusText = ""
        local color = ""
        
        local pf = Overlord.PlayerFaction
        local ef = Overlord.Zones:GetEnemyFaction()
        if zone.status == "in_progress" then
            local elapsed = zone.holdTimeElapsed or 0
            statusIcon = "[~]"
            statusText = string.format(L.STATUS_IN_PROGRESS,
                math.floor(elapsed / 60), 
                math.floor(elapsed % 60))
            color = "|cFFFFD100"
        elseif pf and zone.owner == pf then
            statusIcon = "[" .. pf:sub(1,1) .. "]"
            statusText = pf:upper()
            color = "|cFF4488FF"
        elseif ef and zone.owner == ef then
            statusIcon = "[" .. ef:sub(1,1) .. "]"
            statusText = ef:upper()
            color = "|cFFFF4444"
        elseif zone.status == "available" then
            statusIcon = "[!]"
            statusText = L.STATUS_AVAILABLE
            color = "|cFFFFFF00"
        else
            statusIcon = "[X]"
            statusText = L.STATUS_LOCKED
            color = "|cFF888888"
        end
        
        Overlord:PrintNotification(string.format("%s %s%s|r : %s", statusIcon, color, zone.name, statusText))
    end
    
    local captured = Overlord.Zones:GetCapturedCount()
    local total = Overlord.Zones:GetTotalCount()
    local pct = total > 0 and math.floor((captured / total) * 100) or 0
    
    Overlord:PrintNotification(L.STATUS_FOOTER)
    Overlord:PrintNotification(string.format("|cFF00FF00" .. L.STATUS_TOTAL .. "|r", captured, total, pct))
end

-- Diagnostic barre domination hebdo (secondes, bonus %, ratio affiche).
local function ShowDominationDebug()
    if not OverlordDB then
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.NOT_INITIALIZED)
        return
    end
    local allySec, hordeSec = 0, 0
    if Overlord.GetDominationTotals then
        allySec, hordeSec = Overlord:GetDominationTotals()
    end
    local boosts = OverlordDB.dominationBoostPct or {}
    local legacyA = tonumber(boosts.Alliance) or 0
    local legacyH = tonumber(boosts.Horde) or 0
    local totalSec = allySec + hordeSec
    local terrA, terrH = 0.5, 0.5
    if totalSec > 0 then
        terrA = allySec / totalSec
        terrH = hordeSec / totalSec
    end
    local allyPct, hordePct = terrA, terrH
    if Overlord.GetDominationDisplayFractions then
        allyPct, hordePct = Overlord:GetDominationDisplayFractions()
    end
    local function FmtPct(v)
        local s = string.format("%.2f", (v or 0) * 100)
        if Overlord.UsesCommaDecimalLocale and Overlord.UsesCommaDecimalLocale() then
            s = s:gsub("%.", ",")
        end
        return s
    end
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.DOM_DEBUG_HEADER or "Weekly domination:"))
    Overlord:PrintNotification(string.format(L.DOM_DEBUG_LINE or "sec A/H: %d / %d | territorial: %s / %s | bar: %s / %s",
        allySec, hordeSec, FmtPct(terrA), FmtPct(terrH), FmtPct(allyPct), FmtPct(hordePct)))
    if legacyA > 0 or legacyH > 0 then
        Overlord:PrintNotification(string.format(L.DOM_DEBUG_LEGACY or "legacy overlay (ignored): %s / %s",
            FmtPct(legacyA), FmtPct(legacyH)))
    end
    -- Detail par front + detection des buckets corrompus (valeur aberrante figeant la barre a 50/50).
    local fdt = OverlordDB.frontDominationTime
    if type(fdt) == "table" then
        local limit = Overlord.DOMINATION_PLAUSIBLE_MAX or 1000000000
        for frontId, bucket in pairs(fdt) do
            if type(bucket) == "table" then
                local a = math.floor(tonumber(bucket.Alliance) or 0)
                local h = math.floor(tonumber(bucket.Horde) or 0)
                local flag = (a >= limit or h >= limit) and " |cFFFF0000[CORROMPU]|r" or ""
                Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r  %s: A=%d H=%d%s",
                    tostring(frontId), a, h, flag))
            end
        end
    end
end

-- Diagnostic pin avant-poste sur carte monde (Warchief's Watch / Durotar, etc.).
local function ShowOutpostMapDebug()
    if not OverlordDB then
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.NOT_INITIALIZED)
        return
    end
    local mapID
    if WorldMapFrame and WorldMapFrame.GetMapID then
        local ok, mid = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
        if ok then mapID = mid end
    end
    if not mapID and C_Map and C_Map.GetBestMapForUnit then
        local ok, mid = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then mapID = mid end
    end
    local frontOverlay = Overlord.Fronts and mapID
        and Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
    local frontMap = Overlord.Fronts and mapID
        and Overlord.Fronts:ResolveFrontByMapID(mapID)
    local activeId = Overlord.Fronts and Overlord.Fronts.activeFrontId or "?"
    local sites = (Overlord.Outpost and mapID and activeId ~= "?")
        and Overlord.Outpost:GetSitesOnMap(mapID, activeId) or {}
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r Outpost map debug:")
    Overlord:PrintNotification(string.format("  mapID=%s | front actif=%s | overlay=%s | map=%s | sites=%d",
        tostring(mapID or "?"), tostring(activeId),
        frontOverlay and frontOverlay.id or "nil",
        frontMap and frontMap.id or "nil",
        #sites))
    if Overlord.Outpost and activeId ~= "?" then
        for _, site in pairs(Overlord.Outpost:GetSitesForFront(activeId)) do
            local geom = Overlord.Outpost:GetGeometryMapID(site)
            Overlord:PrintNotification(string.format("  %s geom=%s center=%.1f,%.1f",
                tostring(site.siteKey), tostring(geom),
                site.center and site.center[1] or 0, site.center and site.center[2] or 0))
        end
    end
end

-- /ov scale [valeur] : echelle panneau + classement (paliers 0.1, plage 0.8-1.2)
local function RunScaleCommand(args)
    if not Overlord.UI or not OverlordDB or not OverlordDB.config then
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.NOT_INITIALIZED)
        return
    end
    local lo, hi = 0.8, 1.2
    local raw = args[2] and tostring(args[2]):gsub(",", ".")
    local v = raw and tonumber(raw)
    if not v then
        local s = Overlord.UI:GetEffectiveUiScale()
        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.SCALE_CURRENT, s, lo, hi))
        return
    end
    if v > 2 then
        v = v / 100
    end
    v = math.max(lo, math.min(hi, v))
    v = math.floor(v * 10 + 0.5) / 10
    OverlordDB.config.uiScale = v
    Overlord.UI:ApplyUiScale()
    Overlord.UI:UpdateUiScaleSlider()
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.SCALE_SET, v))
end

-- Read-only evidence: distinguishes an unloaded save from a campaign rollover.
local function ShowPersistenceStatus()
    local function emit(message)
        Overlord:PrintNotification("|cFFFFD100[Overlord:persistence]|r " .. message)
    end
    local function totals(bucket)
        local kills, captures = 0, 0
        for _, n in pairs(type(bucket.kills) == "table" and bucket.kills or {}) do
            kills = kills + math.max(0, tonumber(n) or 0)
        end
        for _, n in pairs(type(bucket.captureCount) == "table" and bucket.captureCount
            or type(bucket.captureCounts) == "table" and bucket.captureCounts or {}) do
            captures = captures + math.max(0, tonumber(n) or 0)
        end
        return tostring(kills) .. " kills, " .. tostring(captures) .. " captures"
    end
    local db = OverlordDB or {}
    emit("Save at login: " .. tostring(Overlord.SavedVariablesLoadedAtLogin))
    emit("Campaign at login: " .. tostring(Overlord.SavedVariablesCampaignAtLogin)
        .. "; active: " .. tostring(db.lastResetTimestamp))
    emit("Active: " .. totals(db.leaderboard or {}))
    local latest
    for _, row in pairs(db.history or {}) do
        if type(row) == "table" and (not latest
            or (tonumber(row.campaignStart) or 0) > (tonumber(latest.campaignStart) or 0)) then
            latest = row
        end
    end
    if latest then emit("Latest archive: " .. tostring(latest.campaignStart) .. "; " .. totals(latest)) end
    if Overlord.SavedVariablesLoadedAtLogin == false then
        emit("No save loaded (first login or beta loader issue). Community sync can recover shared scores.")
    end
end

-- Handler principal des commandes
local function CommandHandler(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end
    
    local cmd = args[1] and string.lower(args[1]) or nil
    if cmd == "persistence" then ShowPersistenceStatus(); return end
    
    if not cmd or cmd == "help" then
        ShowHelp()
        return
    end

    if not Overlord.IsInitialized then
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.NOT_INITIALIZED)
        return
    end

    if cmd == "hud" then
        local settings = Overlord.SettingsPanel
        if not settings then return end
        local action = args[2] and string.lower(args[2]) or "toggle"
        if action == "auto" then
            settings:SetTopHudMode("auto")
            Overlord:PrintNotification(L.HUD_AUTO)
            return
        end
        local visible
        if action == "toggle" then
            visible = not settings:IsTopHudVisible()
        elseif action == "on" then
            visible = true
        elseif action == "off" then
            visible = false
        else
            Overlord:PrintNotification(L.HELP_HUD)
            return
        end
        settings:SetTopHudVisible(visible)
        Overlord:PrintNotification(visible and L.HUD_SHOWN or L.HUD_HIDDEN)
        return
    end

    -- Commandes lecture seule autorisees en instance (status, lb, hide)
    if Overlord.InstanceSuspended then
        if cmd == "status" then ShowStatus(); return
        elseif cmd == "dom" or cmd == "domination" then ShowDominationDebug(); return
        elseif cmd == "hide" then if Overlord.UI then Overlord.UI:Hide() end; return
        elseif cmd == "lb" or cmd == "leaderboard" then
            if Overlord.LeaderboardUI then Overlord.LeaderboardUI:Toggle() end; return
        elseif cmd == "scale" then
            RunScaleCommand(args)
            return
        end
        Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.DISABLED_IN_INSTANCE)
        return
    end

    if cmd == "show" then
        if Overlord.UI then Overlord.UI:Show() end

    elseif cmd == "guide" or cmd == "helpme" then
        if Overlord.Popups then Overlord.Popups:ShowQuickGuide() end

    elseif cmd == "hide" then
        if Overlord.UI then Overlord.UI:Hide() end
        
    elseif cmd == "toggle" then
        if Overlord.UI then Overlord.UI:Toggle() end
        
    elseif cmd == "status" then
        ShowStatus()

    elseif cmd == "dom" or cmd == "domination" then
        ShowDominationDebug()

    elseif cmd == "outpost" then
        ShowOutpostMapDebug()
        
    elseif cmd == "zones" then
        if Overlord.MapMarkers then Overlord.MapMarkers:ShowAvailableZones() end
        
    elseif cmd == "where" then
        if Overlord.ZoneIndicator then Overlord.ZoneIndicator:Toggle() end

    elseif cmd == "front" then
        ShowFrontDebug()

    elseif cmd == "shard" then
        ShowShardDebug()
        
    elseif cmd == "start" then
        local zoneInput = args[2]
        if not zoneInput then
            Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.USAGE_START)
            return
        end

        local zoneId = ResolveZoneAlias(zoneInput)
        local zone = Overlord.Zones:GetZone(zoneId)

        if not zone then
            Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. string.format(L.ZONE_UNKNOWN, zoneInput))
            return
        end

        if zone.status ~= "available" and zone.status ~= "in_progress" then
            Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.ZONE_NOT_AVAILABLE, zone.name))
            return
        end

        -- Verifie que le joueur est physiquement dans la zone
        local playerZone = Overlord.Zones:GetCurrentPlayerZone()
        if not playerZone or playerZone.id ~= zone.id then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.MUST_BE_IN_ZONE,
                zone.name, zone.center[1], zone.center[2]))
            return
        end

        if not Overlord.Zones:IsZoneAvailable(zone.id) then
            Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.CAPTURE_BLOCKED_RULES, zone.name))
            return
        end

        if zone.status == "available" then
            zone.holdTimeElapsed = 0
            zone.holdStartTime = nil
            zone.isContested = false
            zone.isPaused = false
        end
        zone.status = "in_progress"
        Overlord.ZoneControl:StartHoldTimer(zone)
        Overlord:MarkDirty()
        if Overlord.UI then Overlord.UI:RequestRefresh() end
        
    elseif cmd == "lb" or cmd == "leaderboard" then
        if Overlord.LeaderboardUI then Overlord.LeaderboardUI:Toggle() end

    elseif cmd == "debugkill" then
        if not (OverlordDB and OverlordDB.config and OverlordDB.config.debug) then
            Overlord:PrintNotification("|cFFFF0000[Overlord]|r Kill debug requires debug mode.")
            return
        end
        if Overlord.Combat then
            Overlord.Combat:SetDebugKill(true)
        end
        return

    elseif cmd == "resetpos" then
        if OverlordDB then
            OverlordDB.panelPos = nil
            OverlordDB.panelAnchor = nil
        end
        if Overlord.UI then
            Overlord.UI:ResetPosition()
        end
        Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.POS_RESET)

    elseif cmd == "export" then
        if Overlord.Export then
            Overlord.Export:ShowUI()
        end

    elseif cmd == "scale" then
        RunScaleCommand(args)

    elseif cmd == "bountytest" then
        if not Overlord.ManualBounty then
            Overlord:PrintNotification("|cFFFF0000[Overlord]|r Gold contract module unavailable.")
            return
        end
        if not (OverlordDB and OverlordDB.config and OverlordDB.config.debug) then
            Overlord:PrintNotification("|cFFFF0000[Overlord]|r Gold contract test requires debug mode.")
            return
        end
        if args[2] and string.lower(args[2]) == "clear" then
            Overlord.ManualBounty:DebugClear()
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r Gold contract test cleared.")
        else
            Overlord.ManualBounty:DebugPlaceTest()
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r Gold contract test placed on you. Use |cFFFFFF00/ov bountytest clear|r to remove.")
        end

    elseif cmd == "sync" then
        if Overlord.Sync then
            if Overlord.Sync.InvalidateOnlineMembersCache then
                Overlord.Sync:InvalidateOnlineMembersCache()
            end
            -- Cible canonique Blizzard Nom-Royaume (ex. "Melicole-Hyjal").
            local target = args[2] and table.concat(args, " ", 2) or nil
            if target and target ~= "" then
                -- Seule une action explicite peut demander l'historique complet, et
                -- OnSyncRequest ne l'honore qu'en transport direct.
                local sent = Overlord.Sync:SendWhisper(
                    "SR", Overlord.Sync:GetSRPayload("F"), target)
                if sent and Overlord.Sync.ExpectDirectFullLeaderboardResponse then
                    Overlord.Sync:ExpectDirectFullLeaderboardResponse(target)
                end
                Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.SYNC_WHISPER_SENT, target))
            else
                -- Trois vagues territoriales legeres. La deuxieme profite du roster
                -- communaute amorce par la premiere ; la derniere ajoute UNE demande
                -- historique directe au lieu de provoquer un dump chez tous les pairs.
                for i = 1, 3 do
                    local firstWave = i == 1
                    C_Timer.After((i - 1) * 2, function()
                        if not Overlord.InstanceSuspended then
                            Overlord.Sync:SendSyncRequest({
                                includeCommunity = i <= 2,
                                allowCommunityInLargeEvent = true,
                                communityMax = 6,
                                communityDelay = 0.35,
                            })
                            if i == 3 and Overlord.Sync.BroadcastToCommunity then
                                Overlord.Sync:BroadcastToCommunity(
                                    "SR", Overlord.Sync:GetSRPayload("F"),
                                    1, 0.35, true)
                            end
                            -- La premiere vague interroge aussi directement chaque porteur
                            -- de timer GK deja prouve. Cela repare le cas ou tous les pairs
                            -- choisis par le fan-out ont encore l'ancien tenant.
                            if firstWave and Overlord.Sync.RequestActiveGuildKeepAuthorityCatchup then
                                Overlord.Sync:RequestActiveGuildKeepAuthorityCatchup()
                            end
                        end
                    end)
                end
                Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.SYNC_REQUESTED)
            end
        end

    else
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. string.format(L.UNKNOWN_COMMAND, cmd))
        Overlord:PrintNotification("|cFFFFFF00" .. L.HELP_HINT .. "|r")
    end
end

-- Enregistre la commande slash
SLASH_OVERLORD1 = "/ov"
SLASH_OVERLORD2 = "/overlord"
SlashCmdList["OVERLORD"] = CommandHandler
