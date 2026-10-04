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
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r Diagnostic front :")
    local killScoring = Overlord.IsKillScoringActive and Overlord:IsKillScoringActive()
    local killZone = Overlord.Ressources and Overlord.Ressources.IsInOverlordKillZone
        and Overlord.Ressources:IsInOverlordKillZone()
    local temporaryKillZone = Overlord.IsInTemporaryKillScoringZone
        and Overlord:IsInTemporaryKillScoringZone()
    Overlord:PrintNotification(string.format("  InActiveFront=%s  KillScoring=%s  KillZone=%s  OutdoorPvPZone=%s  InstanceSuspended=%s",
        tostring(Overlord.InActiveFront), tostring(killScoring), tostring(killZone), tostring(temporaryKillZone),
        tostring(Overlord.InstanceSuspended)))
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

-- /ov sync : resume en tete (vert = OK, jaune = a surveiller, rouge = probleme),
-- puis le detail technique en gris, compteurs de pertes/refus > 0 en rouge.
-- Une seule table locale : Commands.lua reste loin de la limite de 200 locals.
local SyncReport = {}
do
    local GREEN, YELLOW, RED = "|cFF40FF40", "|cFFFFD100", "|cFFFF4040"
    local GREY, GOLD, WHITE = "|cFF9D9D9D", "|cFFFFD100", "|cFFFFFFFF"
    local ICON = {
        ok = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t",
        warn = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t",
        bad = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t",
    }
    local LEVEL_COLOR = { ok = GREEN, warn = YELLOW, bad = RED }
    local LEVEL_RANK = { ok = 1, warn = 2, bad = 3 }
    local LEVEL_WORD = { ok = "all good", warn = "worth watching", bad = "problem" }
    local PREFIX = GOLD .. "[Overlord]|r "
    function SyncReport.Print(text) Overlord:PrintNotification(PREFIX .. text) end
    function SyncReport.Worst(a, b) return LEVEL_RANK[b] > LEVEL_RANK[a] and b or a end
    function SyncReport.Header(level)
        SyncReport.Print(GOLD .. "===== Network status: |r" .. LEVEL_COLOR[level] .. LEVEL_WORD[level]
            .. "|r" .. GOLD .. " =====|r")
    end
    function SyncReport.Status(level, title, text)
        SyncReport.Print(ICON[level] .. " " .. LEVEL_COLOR[level] .. title .. "|r  " .. WHITE .. text .. "|r")
    end
    -- Nombre en rouge s'il est > 0, puis retour a la couleur de base de la ligne.
    local function hot(n, base)
        n = tonumber(n) or 0
        if n > 0 then return RED .. n .. "|r" .. base end
        return tostring(n)
    end
    local WORDS = { "refused", "evicted", "expired", "abandoned", "dropped" }
    function SyncReport.Detail(line, mode)
        local base, body = GREY, tostring(line or "")
        if mode == "relayKinds" then
            body = body:gsub("(%u+%*?) ([%d%.]+)/(%d+)/(%d+)", function(k, kb, ok, bad)
                return k .. " " .. kb .. "/" .. ok .. "/" .. hot(bad, base)
            end)
        elseif mode == "channelKinds" then
            body = body:gsub("(%u+%*?) (%d+)/(%d+)", function(k, bad, total)
                return k .. " " .. hot(bad, base) .. "/" .. total
            end)
        else
            for _, word in ipairs(WORDS) do
                body = body:gsub("(" .. word .. " )(%d+)", function(w, n) return w .. hot(n, base) end)
                body = body:gsub("(%d+)( " .. word .. ")", function(n, w) return hot(n, base) .. w end)
            end
        end
        local label, rest = body:match("^([^:|]+:)(.*)$")
        if label and body:sub(1, 2) ~= "  " then
            body = GOLD .. label .. "|r" .. base .. rest
        else
            body = base .. body
        end
        SyncReport.Print(body .. "|r")
    end
    function SyncReport.Title(text) SyncReport.Print(GOLD .. text .. "|r") end
end

-- Opt-in observation of actual incoming packets, independent of the relay's
-- preferred-route cache. No payloads, BattleTags or account IDs are displayed.
local networkProbeRunning = false
local function StartNetworkProbe()
    if networkProbeRunning then
        Overlord:PrintNotification("[Overlord] Network observation already running (30s).")
        return
    end
    networkProbeRunning = true
    local counts, rows, order = {}, {}, {}
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("BN_CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
        if Overlord.InstanceSuspended or IsInInstance() then return end
        if prefix ~= "OverlordF" or type(message) ~= "string" then return end
        local transport = event == "BN_CHAT_MSG_ADDON" and "BNET" or channel
        if type(transport) ~= "string" then return end
        if transport ~= "BNET" and Overlord.Sync:IsSenderLocalPlayer(sender) then return end
        counts[transport] = (counts[transport] or 0) + 1
        local name = sender
        if transport == "BNET" then
            name = "Battle.net contact"
            local getGameAccount = C_BattleNet and C_BattleNet.GetGameAccountInfoByID
            if getGameAccount then
                local ok, game = pcall(getGameAccount, sender)
                if ok and game and game.characterName then name = game.characterName end
            end
        end
        if type(name) ~= "string" then return end
        local key = transport .. ":" .. name
        local row = rows[key]
        if not row and #order < 100 then
            row = { name = name, transport = transport, count = 0 }
            rows[key] = row
            order[#order + 1] = row
        end
        if row then row.count = row.count + 1 end
    end)
    -- Le rapport ne doit jamais empecher la fermeture de la fenetre d'observation de 30 s
    -- (frame CHAT_MSG_ADDON enregistree plus haut) : une erreur est affichee, pas propagee.
    local reportOk, reportErr = pcall(function()
        local sync, net = Overlord.Sync, Overlord.BetaNetwork
        local R = SyncReport
        -- 1. Summary: the five things that matter, worst first in the header.
        local rows, overall = {}, "ok"
        local function add(level, title, text)
            rows[#rows + 1] = { level, title, text }
            overall = R.Worst(overall, level)
        end
        local sendStats = sync._addonSendStats
        if sendStats then
            local refused, attempts, parts = 0, 0, {}
            for _, chatType in ipairs({ "CHANNEL", "RAID", "PARTY", "WHISPER" }) do
                local row = sendStats[chatType]
                if row then
                    refused, attempts = refused + row.refused, attempts + row.ok + row.refused
                    -- Blizzard's last refusal code, to tell a throttle from a channel not joined yet.
                    local code = row.refused > 0 and row.lastCode ~= nil
                        and (" code " .. tostring(row.lastCode)) or ""
                    parts[#parts + 1] = string.format("%s %d/%d%s", chatType:lower(), row.refused,
                        row.ok + row.refused, code)
                end
            end
            local ratio = attempts > 0 and refused / attempts or 0
            -- A lone refusal (e.g. a send just before the channel is joined at login)
            -- is not a problem: red only for a real, repeated throttle.
            add(refused == 0 and "ok" or ((ratio < 0.05 or refused < 3) and "warn" or "bad"),
                "Blizzard throttle", string.format("%d refused (%s)", refused, table.concat(parts, ", ")))
        end
        local relayStats = net and net.stats
        if relayStats then
            local sent, dropped = relayStats.sent or 0, relayStats.dropped or 0
            local pct = sent > 0 and dropped * 100 / sent or 0
            -- The login burst (map pages answering several catch-ups) can refuse a
            -- dozen own pages out of a few hundred sends: red only on a real sample.
            add(pct < 1 and "ok" or ((pct < 5 or sent < 500) and "warn" or "bad"), "Relay losses",
                string.format("%d lost of %d sent (%.1f%%), %d received", dropped, sent, pct, relayStats.received or 0))
        end
        if sync.GetPagedLeaderboardSummary then
            local lb = sync:GetPagedLeaderboardSummary()
            local stuck = lb.status:find("interrupted", 1, true) ~= nil
            add(stuck and "warn" or "ok", "Leaderboard catch-up",
                string.format("%s, %d pages / %d rows (v%d)", lb.status, lb.pages, lb.rows, lb.protocol))
        end
        if sync.GetHistoryCatchupSummary then
            local hr = sync:GetHistoryCatchupSummary()
            local waiting = hr.running and hr.step == "paged ladder catch-up" and hr.stepAge > 600
            local text = hr.running and string.format("%s, %ds ago", tostring(hr.step or "?"), hr.stepAge) or "idle"
            add(waiting and "warn" or "ok", "Capture history catch-up",
                waiting and string.format("waiting on one peer for %ds", hr.stepAge) or text)
        end
        if net and net.GetQueueSummary then
            local q = net:GetQueueSummary()
            add(q.catchup >= q.catchupMax and "warn" or "ok", "Relay queue",
                string.format("%d waiting (catch-up %d/%d, domination %d/%d)", q.total, q.catchup, q.catchupMax,
                    q.state, q.stateMax))
        end
        R.Header(overall)
        for _, row in ipairs(rows) do R.Status(row[1], row[2], row[3]) end

        -- 2. Details, for debugging: grey, with any loss or refusal counter in red.
        R.Title("Details:")
        -- 1.4.0: each Forever ruleset runs its own campaign.
        local pools = Overlord.RealmPools
        if pools and pools.GetRuleset then
            R.Detail("Campaign: " .. pools:GetRuleset() .. " ruleset (pool " .. pools:GetOverlordPoolTag()
                .. ", channel OverlordF" .. pools:GetChannelSuffix() .. ")"
                .. (pools._rulesetAssumed and " ASSUMED: game rules and realm name gave no answer" or ""))
        end
        if sync.GetEnemyCaptureFinalDiagnostics then R.Detail(sync:GetEnemyCaptureFinalDiagnostics()) end
        if sync.GetSuspiciousSenderDiagnostics then R.Detail(sync:GetSuspiciousSenderDiagnostics()) end
        if sync.GetThirdPartyInflationDiagnostics then R.Detail(sync:GetThirdPartyInflationDiagnostics()) end
        if sync.GetHistoryCatchupDiagnostics then
            for _, line in ipairs(sync:GetHistoryCatchupDiagnostics()) do R.Detail(line) end
        end
        if sync.GetPagedLeaderboardDiagnostics then R.Detail(sync:GetPagedLeaderboardDiagnostics()) end
        if sync.GetChannelKindDiagnostics then
            for i, line in ipairs(sync:GetChannelKindDiagnostics(12)) do
                R.Detail(line, i > 1 and "channelKinds" or nil)
            end
        end
        if net and net.GetKindDiagnostics then
            local lines = net:GetKindDiagnostics(12)
            for i, line in ipairs(lines) do
                R.Detail(line, (i > 1 and line:sub(1, 2) == "  ") and "relayKinds" or nil)
            end
        end
        if relayStats then
            R.Detail(string.format(
                "Relay: %d sent, %d received, %d dropped, %d refused then retried, %d channel copies skipped.",
                relayStats.sent or 0, relayStats.received or 0, relayStats.dropped or 0, relayStats.refused or 0,
                relayStats.channelSkipped or 0))
        end
        R.Detail("Network observation: 30s. Use /ov sync now.")
    end)
    if not reportOk then
        Overlord:PrintNotification("|cFFFF4040[Overlord]|r /ov network report error: " .. tostring(reportErr))
    end
    C_Timer.After(30, function()
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
        networkProbeRunning = false
        local function emit(text) Overlord:PrintNotification(text) end
        emit("|cFFFFD100[Overlord] Incoming Overlord packets (30s; includes fragments, not score changes):|r")
        local transports = {}
        for transport in pairs(counts) do transports[#transports + 1] = transport end
        table.sort(transports)
        for _, transport in ipairs(transports) do emit(transport .. " = " .. counts[transport]) end
        if #transports == 0 then emit("No packets observed. Try outside instances.") end
        if (counts.BNET or 0) > 0 then
            emit("Battle.net reception confirmed on this client.")
        else
            emit("No Battle.net reception here during this sample; upstream Battle.net remains possible.")
        end
        -- Prefer known opposite-faction senders in the bounded output. Faction
        -- is leaderboard metadata, not a Blizzard-authenticated observation.
        for _, row in ipairs(order) do
            local info = Overlord.Leaderboard and Overlord.Leaderboard:GetPlayerInfo(row.name)
            row.faction = info and info.faction or "?"
            row.enemy = (row.faction == "Horde" or row.faction == "Alliance")
                and row.faction ~= Overlord.PlayerFaction
        end
        table.sort(order, function(a, b)
            if a.enemy ~= b.enemy then return a.enemy end
            if a.count ~= b.count then return a.count > b.count end
            return a.transport .. a.name < b.transport .. b.name
        end)
        emit("Direct senders; faction from stored leaderboard metadata (may be stale):")
        for i = 1, math.min(15, #order) do
            local row = order[i]
            emit(string.format("%s [%s] %s x%d", row.name, row.faction, row.transport, row.count))
        end
        emit("Up to 15 senders shown; this does not identify earlier hops or validate payloads.")
    end)
end

-- Opt-in profiler (/ov perf [seconds]): times every function of the Overlord
-- modules for a bounded window, prints any single call over 50 ms immediately,
-- then a top list, and restores the original functions. Off by default.
-- It also sums the Lua memory each call allocates (collectgarbage("count") before
-- and after, inclusive of nested calls; a GC step inside a call can only make the
-- figure smaller), to find what keeps refilling the addon's garbage.
local PERF_MODULES = {
    "ActionShortcut", "Button", "CaptureLease", "Combat", "FrontActivity", "Fronts",
    "General", "GeneralMap", "GeneralNameplate", "GeneralSync", "GuildKeep",
    "HallOfFameUI", "Leaderboard",
    "LeaderboardUI", "MapMarkers", "Outpost", "OutpostControl",
    "Popups", "Ressources", "SettingsPanel", "Shard", "Sync", "UI", "ZoneControl",
    "ZoneIndicator", "Zones", "BetaNetwork",
}
local PERF_SPIKE_MS = 50
local perfState = nil

local function PerfFinish(label, startedAt, startKb, sliced, ...)
    local state = perfState
    if state then
        if not sliced then state.depth = state.depth - 1 end
        local elapsed = debugprofilestop() - startedAt
        local allocated = math.max(0, collectgarbage("count") - startKb)
        -- Inside a coroutine the clock also runs while the worker is paused between
        -- frames: that is elapsed wall time, not one frame. Keep it apart.
        if sliced then label = label .. " (sliced, multi-frame)" end
        local row = state.stats[label]
        if not row then
            row = { calls = 0, total = 0, max = 0 }
            state.stats[label] = row
        end
        row.calls = row.calls + 1
        row.total = row.total + elapsed
        row.kb = (row.kb or 0) + allocated
        if elapsed > row.max then row.max = elapsed end
        -- Only the outermost call is reported live, so one freeze prints one line.
        if not sliced and elapsed >= PERF_SPIKE_MS and state.depth == 0 then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord perf]|r %d ms  %s",
                math.floor(elapsed + 0.5), label))
        end
    end
    return ...
end

local function PerfWrap(label, fn)
    return function(...)
        local state = perfState
        if not state then return fn(...) end
        local sliced = coroutine.running() ~= nil
        if not sliced then state.depth = state.depth + 1 end
        return PerfFinish(label, debugprofilestop(), collectgarbage("count"), sliced, fn(...))
    end
end

local function StopPerf()
    local state = perfState
    if not state then return end
    perfState = nil
    for i = #state.wrapped, 1, -1 do
        local item = state.wrapped[i]
        if item.owner[item.key] == item.wrapper then item.owner[item.key] = item.original end
    end
    state.frame:SetScript("OnUpdate", nil)
    local rows = {}
    for label, row in pairs(state.stats) do
        rows[#rows + 1] = { label = label, calls = row.calls, total = row.total, max = row.max,
            kb = row.kb or 0 }
    end
    -- Multi-frame (sliced) timings are wall time: excluded from both rankings.
    local frameRows = {}
    for _, r in ipairs(rows) do
        if not r.label:find("(sliced", 1, true) then frameRows[#frameRows + 1] = r end
    end
    rows = frameRows
    table.sort(rows, function(a, b) return a.max > b.max end)
    Overlord:PrintNotification("[Overlord perf] Slowest single calls in one frame (max ms / total ms / calls):")
    for i = 1, math.min(12, #rows) do
        local r = rows[i]
        Overlord:PrintNotification(string.format("  %.1f / %.0f / %d  %s", r.max, r.total, r.calls, r.label))
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    Overlord:PrintNotification("[Overlord perf] Most total time:")
    for i = 1, math.min(8, #rows) do
        local r = rows[i]
        Overlord:PrintNotification(string.format("  %.0f ms / %d calls  %s", r.total, r.calls, r.label))
    end
    table.sort(rows, function(a, b) return a.kb > b.kb end)
    Overlord:PrintNotification("[Overlord perf] Most memory allocated (KB, includes nested calls):")
    for i = 1, math.min(10, #rows) do
        local r = rows[i]
        if r.kb < 1 then break end
        Overlord:PrintNotification(string.format("  %.0f KB / %d calls  %s", r.kb, r.calls, r.label))
    end
end

local function StartPerf(seconds)
    if perfState then
        Overlord:PrintNotification("[Overlord perf] Already running. /ov perf stop to end it now.")
        return
    end
    local state = { stats = {}, wrapped = {}, depth = 0, frame = CreateFrame("Frame") }
    local function wrapTable(owner, prefix)
        if type(owner) ~= "table" then return end
        for key, value in pairs(owner) do
            if type(value) == "function" and type(key) == "string" then
                local wrapper = PerfWrap(prefix .. key, value)
                state.wrapped[#state.wrapped + 1] = { owner = owner, key = key, original = value, wrapper = wrapper }
            end
        end
    end
    wrapTable(Overlord, "Core:")
    for _, name in ipairs(PERF_MODULES) do
        local module = Overlord[name]
        -- Frames and Blizzard objects are skipped: only plain module tables.
        if type(module) == "table" and not module.GetObjectType then wrapTable(module, name .. ":") end
    end
    for _, item in ipairs(state.wrapped) do item.owner[item.key] = item.wrapper end
    -- An error inside a timed call skips PerfFinish; never let depth drift across frames.
    state.frame:SetScript("OnUpdate", function() if perfState then perfState.depth = 0 end end)
    perfState = state
    Overlord:PrintNotification(string.format(
        "[Overlord perf] Timing %d functions for %ds. Calls over %d ms print here.",
        #state.wrapped, seconds, PERF_SPIKE_MS))
    C_Timer.After(seconds, function()
        if perfState == state then StopPerf() end
    end)
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
    Overlord:PrintNotification(L.HELP_DOM)
    Overlord:PrintNotification(L.HELP_SCALE)
    Overlord:PrintNotification(L.HELP_GUIDE)
    if L.HELP_GUILD_KILLS then Overlord:PrintNotification(L.HELP_GUILD_KILLS) end
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

-- Diagnostic barre domination hebdo v2 : victoires + depenses de bois par faction.
local function ShowDominationDebug()
    if not OverlordDB then
        Overlord:PrintNotification("|cFFFF0000[Overlord]|r " .. L.NOT_INITIALIZED)
        return
    end
    local allyPct, hordePct, victoriesA, victoriesH = 50, 50, 0, 0
    if Overlord.GetDominationBarScore then
        allyPct, hordePct, victoriesA, victoriesH = Overlord:GetDominationBarScore()
    end
    local function FmtPct(v)
        local s = string.format("%.2f", (v or 0) * 100)
        if Overlord.UsesCommaDecimalLocale and Overlord.UsesCommaDecimalLocale() then
            s = s:gsub("%.", ",")
        end
        return s
    end
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.DOM_DEBUG_HEADER or "Weekly domination:"))
    Overlord:PrintNotification(string.format(
        L.DOM_DEBUG_COUNTS or "A: %d victories / H: %d victories | bar: %s / %s",
        victoriesA, victoriesH, FmtPct(allyPct / 100), FmtPct(hordePct / 100)))
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
        emit("No save loaded (first login or beta loader issue). Network sync can recover shared scores.")
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

    elseif cmd == "guildkills" then
        if Overlord.GuildKillAlert then Overlord.GuildKillAlert:HandleCommand(args) end

    elseif cmd == "map" or cmd == "carte" then
        local mm = Overlord.MapMarkers
        if mm and mm.SetWorldMapOverlaysShown then
            local shown = not mm:AreWorldMapOverlaysShown()
            mm:SetWorldMapOverlaysShown(shown)
            Overlord:PrintNotification("[Overlord] " .. (shown and (L.MAP_FILTER_SHOWN or "World map display: on")
                or (L.MAP_FILTER_HIDDEN or "World map display: off")))
        end

    elseif cmd == "network" or cmd == "reseau" then
        StartNetworkProbe()

    elseif cmd == "perf" then
        if args[2] == "stop" then
            StopPerf()
        else
            local seconds = math.floor(tonumber(args[2]) or 60)
            StartPerf(math.max(10, math.min(600, seconds)))
        end
        
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

    elseif cmd == "scale" then
        RunScaleCommand(args)

    elseif cmd == "sync" then
        if Overlord.Sync then
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
                -- Trois vagues territoriales legeres ; la derniere ajoute UNE demande
                -- historique complete au lieu de provoquer un dump chez tous les pairs.
                for i = 1, 3 do
                    local firstWave = i == 1
                    C_Timer.After((i - 1) * 2, function()
                        if not Overlord.InstanceSuspended then
                            Overlord.Sync:SendSyncRequest()
                            if i == 3 and Overlord.Sync.BroadcastToRelay then
                                Overlord.Sync:BroadcastToRelay("SR", Overlord.Sync:GetSRPayload("F"))
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
