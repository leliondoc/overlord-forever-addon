-- CombatTracker.lua - Detection des kills ennemis et des morts du joueur
-- WoW 12.0 (Midnight) : COMBAT_LOG_EVENT_UNFILTERED supprime pour les addons.
-- Detection multi-source :
--   1) PARTY_KILL : attribue le killing blow au vrai membre du groupe/raid
--   2) PLAYER_PVP_KILLS_CHANGED : confirme les KB et la contribution des soigneurs
--   3) CHAT_MSG_COMBAT_HONOR_GAIN : diagnostic localise, jamais une attribution
--   4) PLAYER_DEAD : detecte nos morts, attribue le kill a l'ennemi cible/proche
Overlord = Overlord or {}
Overlord.Combat = {}

local L = Overlord.L

local function IsKillScoringActive()
    return Overlord.IsKillScoringActive and Overlord:IsKillScoringActive()
end

local function ResetBountyStreakOutsideFront()
    if not Overlord.InActiveFront
        and Overlord.Bounty and Overlord.Bounty.ResetStreak
        and not (Overlord.Bounty.IsLocalPlayerBounty and Overlord.Bounty:IsLocalPlayerBounty()) then
        Overlord.Bounty:ResetStreak()
    end
end

local combatFrame = CreateFrame("Frame")

-- Cache GUID -> faction, mis a jour sur GROUP_ROSTER_UPDATE
local guidFactionCache = {}
-- Cache GUID -> classe (allies du groupe/raid), mis a jour sur GROUP_ROSTER_UPDATE
local guidAllyClassCache = {}
-- Cache GUID -> guilde (allies), meme refresh que la classe (evite scan raid par kill)
local guidAllyGuildCache = {}
local rosterRefreshTimer = nil

-- Cache GUID -> infos visibles pour enrichir le leaderboard (joueurs ennemis).
-- Permet de retrouver la classe et la race meme si la nameplate a disparu.
local guidPlayerInfoCache = {}

-- Dedup : evite de compter le meme kill 2x si plusieurs events firent
-- pour la meme mort (honor + PARTY_KILL + PVP_KILLS_CHANGED)
local recentlyProcessedKills = {}
local KILL_DEDUP_WINDOW = 5
local UNKNOWN_LOCAL_BACKUP_DELAY = 0.75
local UNKNOWN_LOCAL_BACKUP_DEDUP_WINDOW = 3
local UNKNOWN_NAME_RETRY_DELAY = 0.25
local UNKNOWN_NAME_RETRY_COUNT = 8
local lastDedupCleanup = 0
local DEDUP_CLEANUP_INTERVAL = 60
local DEDUP_CLEANUP_QUOTA = 32
local dedupCleanupActive = false
local dedupCleanupNextKey = nil
local lastUnknownLocalBackupQueuedAt = 0
local pendingUnknownLocalKill = nil
local IsValidPlayerName

local function CleanupRecentlyProcessedKills(now)
    if not dedupCleanupActive then
        if now - lastDedupCleanup < DEDUP_CLEANUP_INTERVAL then return end
        dedupCleanupActive = true
        dedupCleanupNextKey = next(recentlyProcessedKills)
    end

    local processed = 0
    while dedupCleanupNextKey ~= nil and processed < DEDUP_CLEANUP_QUOTA do
        local key = dedupCleanupNextKey
        dedupCleanupNextKey = next(recentlyProcessedKills, key)
        local ts = recentlyProcessedKills[key]
        if not ts or now - ts > KILL_DEDUP_WINDOW then
            recentlyProcessedKills[key] = nil
        end
        processed = processed + 1
    end

    if dedupCleanupNextKey == nil then
        dedupCleanupActive = false
        lastDedupCleanup = now
    end
end

-- Dedup morts : evite de compter la meme mort 2x (PLAYER_DEAD + PLAYER_FLAGS_CHANGED)
local lastDeathTime = 0
local DEATH_DEDUP_WINDOW = 5

-- Achievement "Total Killing Blows" (ID 1487, critere 0)
-- Sert a confirmer qu'un vrai killing blow a eu lieu
local TOTAL_KB_ACHIEVEMENT_ID = 1487
local previousKillingBlows = 0
-- Le compteur HK Blizzard est un compteur de proximite de raid, pas une preuve
-- d'action individuelle. Il ne sert qu'au secours soigneur, apres reconciliation
-- avec les morts deja attribuees par PARTY_KILL / compteur de killing blows.
local previousSessionHonorableKills = nil
local previousSessionKillingBlows = nil
local pvpKillBaselineReady = false
local MAX_PVP_KILL_DELTA = 40
-- Attendre aussi le dernier retry du backup KB sans nom (0.75 + 8 * 0.25 s).
-- Le secours anonyme ne passe qu'apres toutes les sources detaillees possibles.
local HEALER_HK_RECONCILE_DELAY = 3.0
local HEALER_HK_EVIDENCE_WINDOW = 3
local recentDetailedLocalKillTimes = {}
local pendingHealerHonorCredits = nil

-- Tracking du dernier ennemi vu (nameplate) pour attribuer les morts
local lastEnemyTarget = { name = nil, guid = nil, time = 0 }

-- ============================================================
-- Anti-farming : paires (attaquant, victime) trop frequentes
-- Supprime les stats uniquement - aucun impact sur la mecanique de jeu.
-- ============================================================
local farmKillPairs    = {}   -- [key] = anneau borne des derniers kills (GetTime)
local farmKillWarned   = {}   -- [key] = true : avertissement deja affiche cette session
local FARM_KILL_WINDOW     = 300   -- fenetre 5 minutes
local FARM_KILL_THRESHOLD  = 4     -- les 4 premiers kills sont credites ; le 5e et au-dela = farming
local farmKillLastClean    = 0
local FARM_KILL_CLEAN_INT  = 120
local FARM_KILL_CLEAN_QUOTA = 16
local farmKillCleanupActive = false
local farmKillCleanupNextKey = nil

-- Distribue la purge sur les kills suivants au lieu de balayer/copier toutes les paires
-- sur le premier kill qui franchit l'intervalle.
local function CleanupFarmKillPairs(now)
    if not farmKillCleanupActive then
        if now - farmKillLastClean < FARM_KILL_CLEAN_INT then return end
        farmKillCleanupActive = true
        farmKillCleanupNextKey = next(farmKillPairs)
    end

    local processed = 0
    while farmKillCleanupNextKey ~= nil and processed < FARM_KILL_CLEAN_QUOTA do
        local key = farmKillCleanupNextKey
        farmKillCleanupNextKey = next(farmKillPairs, key)
        local history = farmKillPairs[key]
        if not history or now - (history.lastSeen or 0) >= FARM_KILL_WINDOW then
            farmKillPairs[key] = nil
            farmKillWarned[key] = nil
        end
        processed = processed + 1
    end

    if farmKillCleanupNextKey == nil then
        farmKillCleanupActive = false
        farmKillLastClean = now
    end
end

-- Enregistre le kill dans la table de suivi, retourne true si la paire depasse le seuil.
-- attackerName / victimName : noms complets (Nom-Royaume) ou courts.
local function RecordAndCheckKillFarm(attackerName, victimName)
    if not attackerName or not victimName
       or attackerName == "?" or victimName == "?" then
        return false
    end
    -- Cle normalisee : sans suffixe -Royaume pour matcher "Troma" == "Troma-Defias"
    local aKey = (attackerName:match("^(.-)%-") or attackerName):lower()
    local vKey = (victimName:match("^(.-)%-")  or victimName):lower()
    if aKey == vKey then return false end  -- ne jamais se compter soi-meme
    local key = aKey .. "|" .. vKey

    local now = GetTime()
    CleanupFarmKillPairs(now)

    -- Les quatre derniers timestamps suffisent pour savoir si le kill courant est
    -- le cinquieme dans la fenetre. L'anneau est mute en place, sans copie recente.
    local history = farmKillPairs[key]
    if not history then
        history = { first = 1, count = 0, lastSeen = now }
        farmKillPairs[key] = history
    end

    local first = history.first or 1
    local count = history.count or 0
    while count > 0 do
        local oldest = history[first]
        if oldest and now - oldest < FARM_KILL_WINDOW then break end
        history[first] = nil
        first = (first % FARM_KILL_THRESHOLD) + 1
        count = count - 1
    end

    local isFarming = count >= FARM_KILL_THRESHOLD
    if isFarming then
        history[first] = now
        first = (first % FARM_KILL_THRESHOLD) + 1
    else
        local slot = ((first + count - 1) % FARM_KILL_THRESHOLD) + 1
        history[slot] = now
        count = count + 1
    end
    history.first = first
    history.count = count
    history.lastSeen = now

    if isFarming then
        if not farmKillWarned[key] then
            farmKillWarned[key] = true
            local fmt = (Overlord.L and Overlord.L.FARM_KILL_DETECTED)
                or "Kill farming suppressed: %s → %s (%d+ kills in 5 min, stats not counted)."
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. fmt, attackerName, victimName, FARM_KILL_THRESHOLD + 1))
        end
        return true
    end
    return false
end

-- Mode debug : affiche chaque etape de detection dans le chat
local debugKillMode = false
local debugKillExpiry = 0

local function dbg(...)
    if debugKillMode and GetTime() < debugKillExpiry then
        print("|cFF00FFFF[Debug]|r", ...)
    end
end

-- Purge periodique du cache GUID -> playerInfo (evite croissance infinie)
local GUID_CACHE_EXPIRY = 3600  -- 1 heure
local lastGuidCacheCleanup = 0
local GUID_CACHE_CLEANUP_INT = 300  -- 5 minutes
local GUID_CACHE_CLEANUP_QUOTA = 16
local guidCacheCleanupActive = false
local guidCacheCleanupNextKey = nil

local function CleanupGuidPlayerInfoCache()
    local now = GetTime()
    if not guidCacheCleanupActive then
        if now - lastGuidCacheCleanup < GUID_CACHE_CLEANUP_INT then return end
        guidCacheCleanupActive = true
        guidCacheCleanupNextKey = next(guidPlayerInfoCache)
    end

    local processed = 0
    while guidCacheCleanupNextKey ~= nil and processed < GUID_CACHE_CLEANUP_QUOTA do
        local guid = guidCacheCleanupNextKey
        guidCacheCleanupNextKey = next(guidPlayerInfoCache, guid)
        local info = guidPlayerInfoCache[guid]
        if now - (info.time or 0) > GUID_CACHE_EXPIRY then
            guidPlayerInfoCache[guid] = nil
        end
        processed = processed + 1
    end

    if guidCacheCleanupNextKey == nil then
        guidCacheCleanupActive = false
        lastGuidCacheCleanup = now
    end
end

-- Cache le GUID d'un joueur ennemi avec ses metadonnees visibles.
-- Met a jour en place pour eviter une table neuve a chaque changement de cible.
local function CacheEnemyPlayerInfo(guid, name, class, race, raceSex)
    if not guid or not name or name == "?" then return end
    CleanupGuidPlayerInfoCache()
    local info = guidPlayerInfoCache[guid]
    if not info then
        info = {}
        guidPlayerInfoCache[guid] = info
    end
    info.name = name
    if class and class ~= "" then info.class = class end
    if race and race ~= "" then info.race = race end
    if raceSex == 2 or raceSex == 3 then info.raceSex = raceSex end
    info.class = info.class or ""
    info.race = info.race or ""
    info.raceSex = info.raceSex or 0
    info.time = GetTime()
end

-- Expose le cache en bloc pour que le Leaderboard l'utilise sans lookup O(N) par ligne.
function Overlord.Combat:ForEachCachedPlayerInfo(callback)
    if not callback then return end
    for _, info in pairs(guidPlayerInfoCache) do
        if info and info.name and info.name ~= "" then
            callback(info.name, info.class or "")
        end
    end
end

-- Expose separement la race pour conserver la signature historique du cache de classes.
function Overlord.Combat:ForEachCachedPlayerRace(callback)
    if not callback then return end
    for _, info in pairs(guidPlayerInfoCache) do
        if info and info.name and info.name ~= "" and info.race and info.race ~= "" then
            callback(info.name, info.race, info.raceSex or 0)
        end
    end
end

local function GetKillingBlows()
    if not C_AchievementInfo or not C_AchievementInfo.GetCriteriaInfo then return 0 end
    local ok, info = pcall(C_AchievementInfo.GetCriteriaInfo, TOTAL_KB_ACHIEVEMENT_ID, 1)
    if ok and info then
        return info.quantity or info.quantityNumber or 0
    end
    return 0
end

local function GetSessionHonorableKills()
    if type(GetPVPSessionStats) ~= "function" then return nil end
    local ok, honorableKills = pcall(GetPVPSessionStats)
    if not ok or type(honorableKills) ~= "number" then return nil end
    if canaccessvalue and not canaccessvalue(honorableKills) then return nil end
    honorableKills = math.floor(honorableKills)
    if honorableKills < 0 then return nil end
    return honorableKills
end

local function IsLocalPlayerHealer()
    if type(UnitGroupRolesAssigned) == "function" then
        local ok, role = pcall(UnitGroupRolesAssigned, "player")
        if ok and role == "HEALER" then return true end
    end
    if type(GetSpecialization) == "function" and type(GetSpecializationRole) == "function" then
        local ok, role = pcall(function()
            local spec = GetSpecialization()
            return spec and GetSpecializationRole(spec) or nil
        end)
        if ok and role == "HEALER" then return true end
    end
    return false
end

local function ResetPvpKillReconciliation()
    recentDetailedLocalKillTimes = {}
    pendingHealerHonorCredits = nil
    pendingUnknownLocalKill = nil
    lastUnknownLocalBackupQueuedAt = 0
end

local function RefreshPvpKillBaselines()
    local killingBlows = GetKillingBlows()
    previousSessionKillingBlows = killingBlows
    if killingBlows > previousKillingBlows then
        previousKillingBlows = killingBlows
    end
    previousSessionHonorableKills = GetSessionHonorableKills()
    pvpKillBaselineReady = previousSessionHonorableKills ~= nil
    ResetPvpKillReconciliation()
end

local function ReadPvpKillDeltas()
    local honorableKills = GetSessionHonorableKills()
    local killingBlows = GetKillingBlows()
    if not pvpKillBaselineReady or previousSessionHonorableKills == nil
        or previousSessionKillingBlows == nil or honorableKills == nil then
        previousSessionHonorableKills = honorableKills
        previousSessionKillingBlows = killingBlows
        pvpKillBaselineReady = honorableKills ~= nil
        return 0, 0, killingBlows
    end

    local honorDelta = honorableKills - previousSessionHonorableKills
    local killingBlowDelta = killingBlows - previousSessionKillingBlows
    previousSessionHonorableKills = honorableKills
    previousSessionKillingBlows = killingBlows
    if honorDelta < 0 or killingBlowDelta < 0
        or honorDelta > MAX_PVP_KILL_DELTA
        or killingBlowDelta > MAX_PVP_KILL_DELTA then
        ResetPvpKillReconciliation()
        return 0, 0, killingBlows
    end
    return honorDelta, killingBlowDelta, killingBlows
end

local function ConsumeRecentDetailedLocalKills(limit)
    limit = math.max(0, math.floor(tonumber(limit) or 0))
    local now = GetTime()
    local kept = {}
    for i = 1, #recentDetailedLocalKillTimes do
        local at = tonumber(recentDetailedLocalKillTimes[i]) or 0
        if now - at >= 0 and now - at <= HEALER_HK_EVIDENCE_WINDOW then
            kept[#kept + 1] = at
        end
    end
    recentDetailedLocalKillTimes = kept
    local consumed = math.min(limit, #recentDetailedLocalKillTimes)
    for _ = 1, consumed do
        table.remove(recentDetailedLocalKillTimes, 1)
    end
    return consumed
end

local FlushDueHealerHonorCredits

local function CompactPendingHealerBatches(pending)
    local head = math.max(1, math.floor(tonumber(pending and pending.head) or 1))
    local batches = pending and pending.batches
    if not batches or head <= 32 or head * 2 <= #batches then return end
    local compact = {}
    for i = head, #batches do compact[#compact + 1] = batches[i] end
    pending.batches = compact
    pending.head = 1
end

local function ScheduleNextHealerHonorFlush(pending)
    if pendingHealerHonorCredits ~= pending or not C_Timer or not C_Timer.After then return end
    local batch = pending.batches[pending.head]
    if not batch then
        pendingHealerHonorCredits = nil
        return
    end
    pending.timerGeneration = (tonumber(pending.timerGeneration) or 0) + 1
    local generation = pending.timerGeneration
    pending.timerDueAt = tonumber(batch.dueAt) or GetTime()
    C_Timer.After(math.max(0.05, pending.timerDueAt - GetTime()), function()
        if pendingHealerHonorCredits ~= pending
            or pending.timerGeneration ~= generation then return end
        pending.timerDueAt = 0
        FlushDueHealerHonorCredits(pending)
    end)
end

FlushDueHealerHonorCredits = function(pending)
    if pendingHealerHonorCredits ~= pending then return end
    local now = GetTime()
    local credit = 0
    while pending.head <= #pending.batches do
        local batch = pending.batches[pending.head]
        if (tonumber(batch.dueAt) or 0) > now then break end
        local batchCount = math.max(0, math.floor(tonumber(batch.count) or 0))
        credit = math.min(MAX_PVP_KILL_DELTA, credit + batchCount)
        pending.count = math.max(0, (tonumber(pending.count) or 0) - batchCount)
        pending.head = pending.head + 1
    end
    if credit > 0 and Overlord.Combat and Overlord.Combat.CreditHealerHonorableKills then
        Overlord.Combat:CreditHealerHonorableKills(credit)
    end
    if (tonumber(pending.count) or 0) <= 0 or pending.head > #pending.batches then
        pendingHealerHonorCredits = nil
        return
    end
    CompactPendingHealerBatches(pending)
    ScheduleNextHealerHonorFlush(pending)
end

local function NoteDetailedLocalKillCredit(victimGUID, preferredBatch)
    local unknown = pendingUnknownLocalKill
    if unknown and (not unknown.victimGUID or not victimGUID
        or unknown.victimGUID == victimGUID) then
        preferredBatch = preferredBatch or unknown.healerBatch
        pendingUnknownLocalKill = nil
        lastUnknownLocalBackupQueuedAt = 0
        dbg("backup local sans victime annule par credit detaille")
    end
    local pending = pendingHealerHonorCredits
    if pending and (tonumber(pending.count) or 0) > 0 then
        local batchIndex
        if preferredBatch then
            for i = pending.head, #pending.batches do
                if pending.batches[i] == preferredBatch
                    and (tonumber(preferredBatch.count) or 0) > 0 then
                    batchIndex = i
                    break
                end
            end
        end
        if not batchIndex then
            -- Sans lien explicite (PARTY_KILL arrive seul), la preuve la plus recente
            -- correspond mieux a la rafale courante que le plus ancien lot encore ouvert.
            for i = #pending.batches, pending.head, -1 do
                if (tonumber(pending.batches[i].count) or 0) > 0 then
                    batchIndex = i
                    break
                end
            end
        end
        if batchIndex then
            local batch = pending.batches[batchIndex]
            batch.count = math.max(0, math.floor(tonumber(batch.count) or 0) - 1)
            pending.count = math.max(0, pending.count - 1)
            if batchIndex == pending.head and batch.count <= 0 then
                repeat
                    pending.head = pending.head + 1
                    local nextBatch = pending.batches[pending.head]
                until not nextBatch or (tonumber(nextBatch.count) or 0) > 0
                pending.timerGeneration = (tonumber(pending.timerGeneration) or 0) + 1
                if pending.count > 0 then
                    CompactPendingHealerBatches(pending)
                    ScheduleNextHealerHonorFlush(pending)
                else
                    pendingHealerHonorCredits = nil
                end
            elseif pending.count <= 0 then
                pendingHealerHonorCredits = nil
            end
            dbg("credit HK soigneur annule par preuve detaillee")
            return
        end
        pendingHealerHonorCredits = nil
    end
    recentDetailedLocalKillTimes[#recentDetailedLocalKillTimes + 1] = GetTime()
    if #recentDetailedLocalKillTimes > MAX_PVP_KILL_DELTA then
        table.remove(recentDetailedLocalKillTimes, 1)
    end
end

local function QueueHealerHonorCredits(count)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if count <= 0 or not IsLocalPlayerHealer() or not C_Timer or not C_Timer.After then return end
    local pending = pendingHealerHonorCredits
    if not pending then
        pending = { count = 0, batches = {}, head = 1, timerGeneration = 0, timerDueAt = 0 }
        pendingHealerHonorCredits = pending
    end
    count = math.min(count, MAX_PVP_KILL_DELTA - pending.count)
    if count <= 0 then return end
    local batch = {
        count = count,
        dueAt = GetTime() + HEALER_HK_RECONCILE_DELAY,
    }
    pending.batches[#pending.batches + 1] = batch
    pending.count = pending.count + count
    if (tonumber(pending.timerDueAt) or 0) <= 0 then
        ScheduleNextHealerHonorFlush(pending)
    end
    return batch
end

local function RefreshKillingBlowBaseline()
    local killingBlows = GetKillingBlows()
    if killingBlows > previousKillingBlows then
        previousKillingBlows = killingBlows
    end
end

-- Retente la résolution GUID avant d'abandonner le nom de la victime.
local function ResolvePendingUnknownLocalKill(expectedPending)
    local pending = pendingUnknownLocalKill
    if not pending or pending ~= expectedPending then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        pendingUnknownLocalKill = nil
        return
    end
    local resolvedName
    if pending.victimGUID and UnitNameFromGUID then
        local name = UnitNameFromGUID(pending.victimGUID)
        if name and IsValidPlayerName(name) then resolvedName = name end
    end
    if not resolvedName and pending.victimGUID then
        local cached = guidPlayerInfoCache[pending.victimGUID]
        if cached and cached.name and IsValidPlayerName(cached.name) then
            resolvedName = cached.name
        elseif lastEnemyTarget.guid == pending.victimGUID
            and lastEnemyTarget.name
            and GetTime() - (lastEnemyTarget.time or 0) <= KILL_DEDUP_WINDOW
            and IsValidPlayerName(lastEnemyTarget.name) then
            resolvedName = lastEnemyTarget.name
        end
    end
    if resolvedName or pending.attempts >= UNKNOWN_NAME_RETRY_COUNT then
        pendingUnknownLocalKill = nil
        pending.callback(resolvedName or "?")
        return
    end

    pending.attempts = pending.attempts + 1
    C_Timer.After(UNKNOWN_NAME_RETRY_DELAY, function()
        ResolvePendingUnknownLocalKill(pending)
    end)
end

-- Les backups recents peuvent arriver sans nom de victime. On les differe pour
-- laisser PARTY_KILL ou la resolution du GUID fournir une preuve detaillee.
local function DeferUnknownLocalBackupKill(sourceName, victimGUID, callback, healerBatch)
    local now = GetTime()
    if pendingUnknownLocalKill
        and now - lastUnknownLocalBackupQueuedAt <= UNKNOWN_LOCAL_BACKUP_DEDUP_WINDOW then
        dbg(sourceName .. " backup sans victime ignore: backup deja en attente")
        return true
    end

    lastUnknownLocalBackupQueuedAt = now
    pendingUnknownLocalKill = {
        sourceName = sourceName,
        victimGUID = victimGUID,
        callback = callback,
        healerBatch = healerBatch,
        queuedAt = now,
        attempts = 0,
    }
    local pending = pendingUnknownLocalKill
    C_Timer.After(UNKNOWN_LOCAL_BACKUP_DELAY, function()
        ResolvePendingUnknownLocalKill(pending)
    end)
    dbg(sourceName .. " backup sans victime differe")
    return true
end

function Overlord.Combat:SetDebugKill(enabled)
    debugKillMode = enabled
    if enabled then
        debugKillExpiry = GetTime() + 60
        print("|cFFFFD100[Overlord Debug]|r Kill debug ON (60s).")
        print("|cFFFFD100  InActiveFront:|r " .. tostring(Overlord.InActiveFront))
        print("|cFFFFD100  PlayerFaction:|r " .. tostring(Overlord.PlayerFaction))
        print("|cFFFFD100  InstanceSuspended:|r " .. tostring(Overlord.InstanceSuspended))
        local n = 0; for _ in pairs(guidFactionCache) do n = n + 1 end
        print("|cFFFFD100  guidFactionCache size:|r " .. n)
        print("|cFFFFD100  PreviousKB:|r " .. tostring(previousKillingBlows))
        print("|cFFFFD100  LastEnemy:|r " .. tostring(lastEnemyTarget.name))
        print("|cFFFFD100  Events:|r HONOR_GAIN + PARTY_KILL + PVP_KILLS + PLAYER_DEAD")
    else
        print("|cFFFFD100[Overlord Debug]|r Kill debug OFF.")
    end
end

function Overlord.Combat:Initialize()
    RefreshPvpKillBaselines()
    combatFrame:SetScript("OnEvent", function(_, event, ...)
        -- SuspendForInstance pose ce flag avant les callbacks modules pendant le
        -- login. Bloquer aussi un event deja en file dans cette courte fenetre.
        if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
        if event == "GROUP_ROSTER_UPDATE" then
            Overlord.Combat:RequestGUIDCacheRefresh()
        elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
            Overlord.Combat:OnHonorGain(...)
        elseif event == "PARTY_KILL" then
            Overlord.Combat:OnPartyKillEvent(...)
        elseif event == "PLAYER_PVP_KILLS_CHANGED" then
            Overlord.Combat:OnPVPKillsChanged(...)
        elseif event == "PLAYER_DEAD" then
            Overlord.Combat:OnPlayerDead()
        elseif event == "UNIT_TARGET" then
            Overlord.Combat:OnUnitTarget(...)
        end
    end)

    if not Overlord.InstanceSuspended and not (IsInInstance and IsInInstance()) then
        combatFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        -- Le chat reste diagnostique : en raid son nom de victime n'identifie pas le tueur.
        combatFrame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
        -- PARTY_KILL couvre les KB ; PVP_KILLS_CHANGED couvre aussi les assistants.
        combatFrame:RegisterEvent("PARTY_KILL")
        combatFrame:RegisterEvent("PLAYER_PVP_KILLS_CHANGED")
        -- Detection de nos morts : attribue le kill a l'ennemi cible/proche
        combatFrame:RegisterEvent("PLAYER_DEAD")
        -- Tracking du dernier ennemi cible (RegisterUnitEvent filtre cote C++ :
        -- ne fire que quand NOTRE cible change, pas les 200 unites en 100v100)
        combatFrame:RegisterUnitEvent("UNIT_TARGET", "player")
    end

    C_Timer.After(1, function()
        if not pvpKillBaselineReady then
            RefreshPvpKillBaselines()
        end
        dbg("KB initial:", previousKillingBlows)
    end)

    self:RefreshGUIDCache()
end

function Overlord.Combat:RequestGUIDCacheRefresh()
    if rosterRefreshTimer then
        rosterRefreshTimer:Cancel()
        rosterRefreshTimer = nil
    end
    -- Une conversion/invitation de raid emet plusieurs GROUP_ROSTER_UPDATE dans la
    -- meme rafale. Ne reconstruire les trois index GUID qu'apres stabilisation.
    rosterRefreshTimer = C_Timer.NewTimer(0.2, function()
        rosterRefreshTimer = nil
        if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
        if Overlord.Combat then Overlord.Combat:RefreshGUIDCache() end
    end)
end

-- Reconstruit le cache GUID -> faction du raid/groupe
function Overlord.Combat:RefreshGUIDCache()
    wipe(guidFactionCache)
    wipe(guidAllyClassCache)
    wipe(guidAllyGuildCache)
    local guid = UnitGUID("player")
    if guid then
        guidFactionCache[guid] = UnitFactionGroup("player")
        local _, cls = UnitClass("player")
        if cls then guidAllyClassCache[guid] = cls end
        if Overlord.SafeGetGuildInfo then
            local guild = Overlord:SafeGetGuildInfo("player")
            if guild and guild ~= "" then guidAllyGuildCache[guid] = guild end
        end
    end

    local prefix, count
    if IsInRaid() then prefix, count = "raid", 40
    elseif IsInGroup() then prefix, count = "party", 4
    else return end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local g = UnitGUID(unit)
            if g then
                guidFactionCache[g] = UnitFactionGroup(unit)
                local _, cls = UnitClass(unit)
                if cls then guidAllyClassCache[g] = cls end
                if Overlord.SafeGetGuildInfo then
                    local guild = Overlord:SafeGetGuildInfo(unit)
                    if guild and guild ~= "" then guidAllyGuildCache[g] = guild end
                end
            end
        end
    end
end

-- Verifie si le GUID est accessible (pas un Secret Value opaque)
local function SafeGUID(guid)
    if not guid then return nil end
    if canaccessvalue and not canaccessvalue(guid) then return nil end
    return guid
end

local function SafeHonorMessage(message)
    if not message then return nil end
    if canaccessvalue and not canaccessvalue(message) then return nil end
    if type(message) ~= "string" then return nil end
    if message == "" then return nil end
    return message
end

-- Chaîne exploitable par match/concat : rejette les secret values WoW 12.0
local function SafeAccessibleString(s)
    if not s then return nil end
    if canaccessvalue and not canaccessvalue(s) then return nil end
    if type(s) ~= "string" then return nil end
    return s
end

local function SafeFullUnitName(unit)
    if not unit then return nil end
    -- WoW 12.0.5 : GetUnitName(true) evite UnitFullName + comparaisons sur secret values.
    if Overlord.SafeGetUnitName then
        return SafeAccessibleString(Overlord:SafeGetUnitName(unit, true))
    end
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok then return nil end
    name = SafeAccessibleString(name)
    if not name then return nil end
    realm = SafeAccessibleString(realm)
    if not realm or realm == "" then
        realm = SafeAccessibleString(Overlord:SafeGetRealmName())
    end
    return (realm and realm ~= "") and (name .. "-" .. realm) or name
end

-- Verifie qu'un nom de joueur est exploitable : non vide, pas le placeholder "Unknown"
-- que WoW retourne quand l'unite n'est pas encore resolue (nameplate non charge,
-- cross-realm non broadcast, etc.). Accepte les formes "Unknown-Royaume".
-- Sans ce filtre, des lignes "Unknown" finissaient dans le classement et etaient
-- propagees par sync aux autres joueurs.
IsValidPlayerName = function(name)
    name = SafeAccessibleString(name)
    if not name then return false end
    if name == "" or name == "?" then return false end
    local base = name:match("^([^%-]+)") or name
    if base == "" then return false end
    local lower = base:lower()
    if lower == "unknown" or lower == "inconnu" or lower == "unbekannt"
       or lower == "desconocido" or lower == "desconhecido" then
        return false
    end
    return true
end

-- Expose la validation aux autres modules (Sync.lua l'utilise pour filtrer
-- les payloads reseau qui auraient ete envoyes par un pair pre-correctif).
Overlord.Combat.IsValidPlayerName = function(_, n) return IsValidPlayerName(n) end

-- Compile une GlobalString printf de Blizzard en motif Lua une seule fois. Le
-- premier argument de COMBATLOG_HONORGAIN est toujours la victime, mais certaines
-- locales peuvent reordonner les placeholders avec la notation "%2$s".
local function EscapeLuaPatternLiteral(text)
    return (text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function CompileHonorGainPattern(formatString)
    formatString = SafeAccessibleString(formatString)
    if not formatString or formatString == "" then return nil end

    local parts, captureArgs = { "^" }, {}
    local cursor, nextSequentialArg = 1, 1
    while cursor <= #formatString do
        local percentAt = formatString:find("%", cursor, true)
        if not percentAt then
            parts[#parts + 1] = EscapeLuaPatternLiteral(formatString:sub(cursor))
            break
        end
        if percentAt > cursor then
            parts[#parts + 1] = EscapeLuaPatternLiteral(formatString:sub(cursor, percentAt - 1))
        end
        if formatString:sub(percentAt + 1, percentAt + 1) == "%" then
            parts[#parts + 1] = "%%"
            cursor = percentAt + 2
        else
            local rest = formatString:sub(percentAt)
            local token = rest:match("^%%%d+%$[-+ #0%d%.%*]*[hlL]?[cdeEfgGiouqsxX]")
                or rest:match("^%%[-+ #0%d%.%*]*[hlL]?[cdeEfgGiouqsxX]")
            if not token then return nil end
            local argumentIndex = tonumber(token:match("^%%(%d+)%$"))
            if not argumentIndex then
                argumentIndex = nextSequentialArg
                nextSequentialArg = nextSequentialArg + 1
            end
            captureArgs[#captureArgs + 1] = argumentIndex
            parts[#parts + 1] = "(.-)"
            cursor = percentAt + #token
        end
    end
    parts[#parts + 1] = "$"

    local victimCapture
    for captureIndex, argumentIndex in ipairs(captureArgs) do
        if argumentIndex == 1 then
            victimCapture = captureIndex
            break
        end
    end
    if not victimCapture or victimCapture > 6 then return nil end
    return table.concat(parts), victimCapture
end

local honorGainPatterns
local function GetHonorGainPatterns()
    if honorGainPatterns then return honorGainPatterns end
    honorGainPatterns = {}
    local function AddFormat(formatString)
        local pattern, victimCapture = CompileHonorGainPattern(formatString)
        if not pattern then return end
        for _, row in ipairs(honorGainPatterns) do
            if row.pattern == pattern then return end
        end
        honorGainPatterns[#honorGainPatterns + 1] = {
            pattern = pattern,
            victimCapture = victimCapture,
        }
    end
    -- Les gains forfaitaires COMBATLOG_HONORAWARD ne sont volontairement pas
    -- compiles : seuls les deux formats Blizzard de victoire honorable comptent.
    AddFormat(_G.COMBATLOG_HONORGAIN)
    AddFormat(_G.COMBATLOG_HONORGAIN_NO_RANK)
    return honorGainPatterns
end

local function NormalizeHonorVictimName(name)
    name = SafeAccessibleString(name)
    if not name or name == "" then return nil end
    -- Les messages peuvent contenir un lien de joueur selon les reglages de chat.
    name = name:match("|Hplayer:([^:|]+)") or name
    name = name:match("^%s*(.-)%s*$") or name
    if name == "" or name:find("%s") or name:find("[,:%(%)%[%]|]") then return nil end
    return IsValidPlayerName(name) and name or nil
end

local function ExtractHonorVictim(message, playerName2)
    for _, row in ipairs(GetHonorGainPatterns()) do
        local c1, c2, c3, c4, c5, c6 = message:match(row.pattern)
        local candidate = row.victimCapture == 1 and c1
            or row.victimCapture == 2 and c2
            or row.victimCapture == 3 and c3
            or row.victimCapture == 4 and c4
            or row.victimCapture == 5 and c5
            or row.victimCapture == 6 and c6
        candidate = NormalizeHonorVictimName(candidate)
        if candidate then return candidate end
    end

    -- Sur certains clients, Blizzard fournit directement la cible en arg5 du
    -- CHAT_MSG_*. On ne l'accepte que si elle apparait aussi dans le message.
    local target = NormalizeHonorVictimName(playerName2)
    if target then
        local shortTarget = target:match("^([^%-]+)") or target
        if message:find(target, 1, true) or message:find(shortTarget, 1, true) then
            return target
        end
    end
    return nil
end

-- Cle commune aux sources honor, PARTY_KILL et PVP_KILLS_CHANGED.
-- Le nom court permet de relier un message d'honneur sans royaume au GUID
-- enrichi recu quelques instants plus tard.
local function KillNameDedupKey(name)
    if not IsValidPlayerName(name) then return nil end
    local base = name:match("^([^%-]+)") or name
    return "kill:" .. base:lower()
end

local function WasKillRecentlyProcessed(victimGUID, victimName, now)
    if victimGUID then
        local guidAt = recentlyProcessedKills[victimGUID]
        if guidAt and now - guidAt <= KILL_DEDUP_WINDOW then return true end
    end
    local nameKey = KillNameDedupKey(victimName)
    local nameAt = nameKey and recentlyProcessedKills[nameKey]
    return nameAt ~= nil and now - nameAt <= KILL_DEDUP_WINDOW
end

local function RecordProcessKillDedup(victimGUID, enrichedVictimName, victimName, now)
    if victimGUID then
        recentlyProcessedKills[victimGUID] = now
    end
    local enrichedKey = KillNameDedupKey(enrichedVictimName)
    if enrichedKey then recentlyProcessedKills[enrichedKey] = now end
    local originalKey = KillNameDedupKey(victimName)
    if originalKey then recentlyProcessedKills[originalKey] = now end
end

-- CHAT_MSG_COMBAT_HONOR_GAIN est diffuse a tous les membres eligibles proches.
-- Meme son nom de victime ne peut pas etre correle de facon sure a notre KB pendant
-- une rafale de raid : ce handler reste donc strictement diagnostique.
function Overlord.Combat:OnHonorGain(message, _, _, _, playerName2)
    -- Ce canal n'est qu'un outil /debugkill : hors de sa fenetre, ne toucher ni
    -- aux strings securisees ni aux motifs localises de chaque HK de raid.
    if not debugKillMode or GetTime() >= debugKillExpiry then return end
    local safeMessage = SafeHonorMessage(message)
    if not safeMessage then return end
    local victimName = ExtractHonorVictim(safeMessage, playerName2)
    if not victimName then
        -- CHAT_MSG_COMBAT_HONOR_GAIN couvre aussi des gains d'honneur forfaitaires.
        -- Ils n'ont pas de victime et ne doivent jamais alimenter le classement.
        dbg("HONOR_GAIN sans victoire honorable exploitable, ignore")
        return
    end

    dbg("HONOR_GAIN:", safeMessage)
    dbg("  victime observee sans attribution locale:", victimName)
end

-- PARTY_KILL : backup, fire quand un membre du groupe/raid fait le killing blow.
-- En 12.0 les args peuvent etre (attackerGUID, targetGUID) OU le format legacy (unitTarget).
-- On gere les deux cas pour robustesse.
function Overlord.Combat:OnPartyKillEvent(arg1, arg2)
    local killScoring = IsKillScoringActive()

    dbg("PARTY_KILL event fired")

    -- Detection du format : si arg1 ressemble a un GUID ("Player-xxx"), nouveau format
    -- Sinon c'est un unit token ("target", "nameplate3") ou nil = ancien format
    -- WoW 12.0.5 : arg1/arg2 peuvent etre des secret values - pas de :match() avant canaccessvalue
    local safeArg1 = SafeAccessibleString(arg1)
    local isGUIDFormat = false
    if safeArg1 then
        isGUIDFormat = safeArg1:match("^Player%-") ~= nil
    elseif arg1 and type(arg1) == "string" and canaccessvalue and not canaccessvalue(arg1) then
        -- GUID opaque (secret value) : format 12.0, pas de match possible
        isGUIDFormat = true
    end
    local safeAttacker, safeTarget

    if isGUIDFormat then
        safeAttacker = SafeGUID(arg1)
        safeTarget = SafeGUID(arg2)
        dbg("  Format GUID: attacker=", tostring(safeAttacker or "[secret]"),
            "target=", tostring(safeTarget or "[secret]"))
    else
        -- Format legacy : arg1 = unitTarget (token de l'ennemi tue), pas de GUID
        -- Le tueur est forcement quelqu'un de notre groupe (c'est la semantique de PARTY_KILL)
        dbg("  Format legacy/unit: arg1=", tostring(safeArg1 or arg1))
    end

    local playerGUID = UnitGUID("player")
    local isOurKill = false
    local killerName = nil
    local victimName = "?"

    if isGUIDFormat then
        if safeAttacker then
            if safeAttacker == playerGUID then
                isOurKill = true
                killerName = Overlord:SafeUnitName("player") or "?"
            elseif guidFactionCache[safeAttacker] then
                isOurKill = true
                killerName = self:FindGroupMemberName(safeAttacker)
            end
        else
            -- Pas de GUID attaquant : verifier via KB (API achievement)
            local killingBlows = GetKillingBlows()
            local kbIncreased = (killingBlows > previousKillingBlows)
            if kbIncreased then
                previousKillingBlows = killingBlows
                isOurKill = true
                killerName = Overlord:SafeUnitName("player") or "?"
                safeAttacker = playerGUID
            end
        end
        if safeTarget then
            if not safeTarget:match("^Player%-") then
                dbg("  target pas Player-*, ignore")
                return
            end
            if UnitNameFromGUID then
                local n = UnitNameFromGUID(safeTarget)
                -- Rejette le placeholder "Unknown" que l'API renvoie quand le
                -- joueur cross-realm n'est pas encore resolu cote client.
                if n and IsValidPlayerName(n) then
                    victimName = n
                else
                    victimName = "?"
                end
            end
        end
    else
        -- Format legacy : PARTY_KILL sans GUID explicite.
        local killingBlows = GetKillingBlows()
        local kbIncreased = (killingBlows > previousKillingBlows)
        if kbIncreased then previousKillingBlows = killingBlows end
        if kbIncreased then
            isOurKill = true
            killerName = Overlord:SafeUnitName("player") or "?"
            safeAttacker = playerGUID
        else
            dbg("  format legacy sans KB pour nous, skip (evite faux crediter le joueur local)")
            return
        end
        -- Essaie d'extraire le nom de la victime depuis le unit token
        -- WoW 12.0.5 : SafeGetUnitName gere les secret values ; pas de UnitExists sur arg1 opaque
        if safeArg1 and UnitExists(safeArg1) and UnitIsPlayer(safeArg1) then
            local n = Overlord:SafeGetUnitName(safeArg1, false)
            victimName = (n and IsValidPlayerName(n)) and n or "?"
            safeTarget = UnitGUID(safeArg1)
            -- Cache les infos visibles de la victime pour enrichir le leaderboard.
            local _, victimClass = UnitClass(safeArg1)
            local _, victimRace = UnitRace(safeArg1)
            local victimSex = UnitSex(safeArg1) or 0
            if safeTarget and victimName ~= "?" and victimClass then
                CacheEnemyPlayerInfo(safeTarget, victimName, victimClass, victimRace, victimSex)
            end
        end
    end

    dbg("  isOurKill:", tostring(isOurKill), "killerName:", tostring(killerName))

    if not isOurKill then return end

    -- WoW 12.0.5 : SafeUnitName gere les secret values
    local localName = Overlord:SafeUnitName("player")
    if not killerName and not localName then return end
    local finalKillerGUID = safeAttacker or playerGUID
    local finalKillerName = killerName or localName
    if victimName == "?" and finalKillerGUID and playerGUID and finalKillerGUID == playerGUID then
        if DeferUnknownLocalBackupKill("PARTY_KILL", safeTarget, function(resolvedVictimName)
            self:ProcessKill(finalKillerGUID, finalKillerName, safeTarget, resolvedVictimName, not killScoring)
        end) then
            return
        end
    end
    self:ProcessKill(safeAttacker or playerGUID, killerName or localName,
                     safeTarget, victimName, not killScoring)
end

-- Secours strictement reserve au role soigneur. Il n'est appele qu'apres une
-- courte reconciliation avec les preuves nommees de la meme mort.
function Overlord.Combat:CreditHealerHonorableKills(count)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 or count > MAX_PVP_KILL_DELTA
        or not IsKillScoringActive() or not Overlord.Leaderboard then return 0 end

    ResetBountyStreakOutsideFront()
    local playerFullName = (Overlord.Sync and Overlord.Sync:GetPlayerFullName())
        or Overlord:SafeUnitName("player")
    if not playerFullName or playerFullName == "" then return 0 end

    local totalKills = Overlord.Leaderboard:RegisterKill(playerFullName)
    if totalKills <= 0 then return 0 end
    if count > 1 then
        totalKills = Overlord.Leaderboard:AddKills(playerFullName, count - 1, false)
    end
    if Overlord.Fronts and Overlord.Fronts.IsFeaturedFrontActive
        and Overlord.Fronts:IsFeaturedFrontActive() then
        totalKills = Overlord.Leaderboard:AddKills(playerFullName, count, false)
        if Overlord.Ressources and Overlord.Ressources.AddGold then
            Overlord.Ressources:AddGold(count)
        end
    end
    if Overlord.Leaderboard.UpdateLocalPlayerGuild then
        Overlord.Leaderboard:UpdateLocalPlayerGuild()
    end
    if Overlord.InActiveFront and Overlord.Bounty then
        if Overlord.Bounty.OnLocalKills then
            Overlord.Bounty:OnLocalKills(count)
        elseif Overlord.Bounty.OnLocalKill then
            Overlord.Bounty:OnLocalKill()
        end
    end

    local currentZone = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
    if Overlord.Sync and Overlord.Sync.BroadcastKill then
        Overlord.Sync:BroadcastKill(currentZone and currentZone.id or "", totalKills, true)
    end
    if count == 1 then
        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.KILL_CONFIRM,
            L.HONORABLE_KILL_LABEL or "healer honorable kill", totalKills))
    else
        local fmt = L.HONORABLE_KILLS_CONFIRM or "+%d honorable kills: Total: %d"
        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. fmt,
            count, totalKills))
    end
    return totalKills
end

-- PLAYER_PVP_KILLS_CHANGED : backup strict pour un coup fatal local. Son compteur
-- HK de raid ne devient un credit anonyme qu'en role soigneur et apres reconciliation.
function Overlord.Combat:OnPVPKillsChanged(unitTarget)
    local killScoring = IsKillScoringActive()

    dbg("PLAYER_PVP_KILLS_CHANGED event fired, unitTarget:", tostring(unitTarget))

    local honorDelta, killingBlowDelta, killingBlows = ReadPvpKillDeltas()
    local detailedCredits = ConsumeRecentDetailedLocalKills(honorDelta)
    -- Mettre toutes les HK restantes en attente. Le ProcessKill KB execute plus bas
    -- annule lui-meme une unite s'il credite reellement le joueur ; on ne depend donc
    -- pas du timing relatif des compteurs Blizzard pour reconnaitre un doublon.
    local healerFallback = math.max(0, honorDelta - detailedCredits)
    dbg("  HK delta:", honorDelta, "KB delta:", killingBlowDelta,
        "preuves detaillees:", detailedCredits, "secours soigneur:", healerFallback)
    local healerBatch
    if healerFallback > 0 and killScoring then
        healerBatch = QueueHealerHonorCredits(healerFallback)
    end
    if killingBlows > previousKillingBlows then previousKillingBlows = killingBlows end
    if killingBlowDelta <= 0 then return end

    local playerGUID = UnitGUID("player")
    local targetGUID = nil
    local targetName = nil
    local safeUnitTarget = SafeAccessibleString(unitTarget)
    -- N'utiliser le payload comme victime que si Blizzard fournit reellement un
    -- token joueur hostile ; "player" est le payload normal de cet event.
    if not targetName and safeUnitTarget and safeUnitTarget ~= "player"
        and UnitExists(safeUnitTarget) and UnitIsPlayer(safeUnitTarget)
        and (not UnitCanAttack or UnitCanAttack("player", safeUnitTarget)) then
        targetGUID = UnitGUID(safeUnitTarget)
        targetName = SafeFullUnitName(safeUnitTarget)
    end
    if not IsValidPlayerName(targetName) then
        targetName = "?"
    end

    dbg("  Processing kill via PVP_KILLS_CHANGED:", targetName)

    -- WoW 12.0.5 : SafeUnitName gere les secret values
    local playerName = Overlord:SafeUnitName("player") or "?"
    if targetName == "?" then
        if DeferUnknownLocalBackupKill("PLAYER_PVP_KILLS_CHANGED", targetGUID, function(resolvedTargetName)
            self:ProcessKill(playerGUID, playerName, targetGUID, resolvedTargetName,
                not killScoring, healerBatch)
        end, healerBatch) then
            return
        end
    end
    self:ProcessKill(playerGUID, playerName, targetGUID, targetName, not killScoring,
        healerBatch)
end

-- Cherche le nom d'un membre du groupe par son GUID
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Combat:FindGroupMemberName(guid)
    local prefix, count
    if IsInRaid() then prefix, count = "raid", 40
    elseif IsInGroup() then prefix, count = "party", 4
    else return nil end
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then
            return Overlord:SafeGetUnitName(unit, true)
        end
    end
    return nil
end

-- Nom victime enrichi (royaume) pour le matching des contrats en or.
local function ResolveManualBountyVictimName(victimGUID, victimName)
    local contractVictimName = victimName
    if victimGUID then
        local cachedVictim = guidPlayerInfoCache[victimGUID]
        local cachedName = cachedVictim and SafeAccessibleString(cachedVictim.name)
        if cachedName and cachedName:find("-", 1, true) then
            contractVictimName = cachedName
        elseif UnitNameFromGUID then
            local okName, resolvedName, resolvedRealm = pcall(UnitNameFromGUID, victimGUID)
            resolvedName = okName and SafeAccessibleString(resolvedName) or nil
            resolvedRealm = okName and SafeAccessibleString(resolvedRealm) or nil
            if resolvedName and resolvedRealm and resolvedRealm ~= ""
                and not resolvedName:find("-", 1, true) then
                resolvedName = resolvedName .. "-" .. resolvedRealm:gsub("%s", "")
            end
            if resolvedName and resolvedName:find("-", 1, true) then
                contractVictimName = resolvedName
            end
        end
    end
    return contractVictimName
end

-- Applique les effets qui profitent d'un second événement plus précis sans
-- recréditer le classement. Un PARTY_KILL peut notamment apporter le royaume
-- absent du message d'honneur initial.
local function ApplyLocalKillEvidence(killerGUID, playerGUID, victimGUID, victimName)
    if not killerGUID or not playerGUID or killerGUID ~= playerGUID then return nil, nil end
    local playerFullName = (Overlord.Sync and Overlord.Sync:GetPlayerFullName())
        or Overlord:SafeUnitName("player")
    if not playerFullName or playerFullName == "" then
        dbg("ProcessKill: nom du joueur local indisponible, skip")
        return nil, nil
    end
    local enrichedVictimName = ResolveManualBountyVictimName(victimGUID, victimName)
    if Overlord.ManualBounty and Overlord.ManualBounty.OnLocalKill and Overlord.InActiveFront then
        Overlord.ManualBounty:OnLocalKill(playerFullName, enrichedVictimName)
    end
    return playerFullName, enrichedVictimName
end

-- Traitement commun d'un kill confirme.
-- bountyProofOnly : preuve detaillee pour payout prime (BD) sans crediter le classement.
-- healerBatch : lot HK cree par le meme event, a annuler si ce KB est credite ici.
function Overlord.Combat:ProcessKill(
    killerGUID, killerName, victimGUID, victimName, bountyProofOnly, healerBatch)
    local now = GetTime()
    local playerGUID = UnitGUID("player")

    -- Une seule porte de dedup pour toutes les sources. Aucun handler ne marque
    -- le kill avant que ses effets aient ete appliques.
    if not bountyProofOnly and WasKillRecentlyProcessed(victimGUID, victimName, now) then
        dbg("ProcessKill dedup: deja traite", tostring(victimGUID), tostring(victimName))
        local playerFullName, enrichedVictimName =
            ApplyLocalKillEvidence(killerGUID, playerGUID, victimGUID, victimName)
        if playerFullName and enrichedVictimName
            and Overlord.BountySync and Overlord.BountySync.RegisterPriorKillCredit then
            Overlord.BountySync:RegisterPriorKillCredit(playerFullName, enrichedVictimName)
        end
        if killerGUID and playerGUID and killerGUID == playerGUID and healerBatch then
            NoteDetailedLocalKillCredit(victimGUID, healerBatch)
        end
        return
    end

    -- Purge bornee : aucun kill ne paie un balayage complet de la session.
    CleanupRecentlyProcessedKills(now)
    CleanupGuidPlayerInfoCache()

    -- Cache les metadonnees victime via nameplate/target (apres dedup pour ne scanner qu'une fois).
    if victimGUID and victimName and victimName ~= "?" then
        if not guidPlayerInfoCache[victimGUID] then
            local victimClass, victimRace, victimSex = nil, nil, 0
            if UnitGUID("target") == victimGUID then
                _, victimClass = UnitClass("target")
                _, victimRace = UnitRace("target")
                victimSex = UnitSex("target") or 0
            end
            if not victimClass then
                for i = 1, 40 do
                    local unit = "nameplate" .. i
                    if UnitGUID(unit) == victimGUID then
                        _, victimClass = UnitClass(unit)
                        _, victimRace = UnitRace(unit)
                        victimSex = UnitSex(unit) or 0
                        break
                    end
                end
            end
            CacheEnemyPlayerInfo(victimGUID, victimName, victimClass, victimRace, victimSex)
        end
    end

    local playerFaction = Overlord.PlayerFaction

    dbg("ProcessKill: killer=" .. tostring(killerName) .. " victim=" .. tostring(victimName))

    if bountyProofOnly then
        -- Preuve honor locale : le payout reste gated par BD (victime) + paire killer/victime.
        if killerGUID and playerGUID and killerGUID == playerGUID
            and victimName and victimName ~= "?" then
            local playerFullName = (Overlord.Sync and Overlord.Sync:GetPlayerFullName())
                or Overlord:SafeUnitName("player")
            if playerFullName and playerFullName ~= ""
                and Overlord.BountySync and Overlord.BountySync.RegisterPriorKillCredit then
                Overlord.BountySync:RegisterPriorKillCredit(playerFullName, victimName)
            end
        end
        return
    end

    -- En War Mode monde ouvert (warfront hors BG), PARTY_KILL correspond a un ennemi reel
    -- (on ne peut pas tuer des allies en War Mode)

    local killCredited = false
    if killerGUID and playerGUID and killerGUID == playerGUID then
        ResetBountyStreakOutsideFront()
        local playerFullName, contractVictimName =
            ApplyLocalKillEvidence(killerGUID, playerGUID, victimGUID, victimName)
        if not playerFullName then return end
        -- Anti-farming : supprime les stats si la meme victime est tuee trop souvent
        if RecordAndCheckKillFarm(playerFullName, victimName) then
            RecordProcessKillDedup(victimGUID, contractVictimName, victimName, now)
            -- Le rejet anti-farm reste une preuve detaillee : consommer son lot HK
            -- empeche le secours soigneur anonyme de recreer le score trois secondes apres.
            NoteDetailedLocalKillCredit(victimGUID, healerBatch)
            return
        end

        -- Prime : le +1 kill habituel reste acquis ; BD complete a +2 net si la victime l'emet.
        local totalKills = Overlord.Leaderboard:RegisterKill(playerFullName)
        if Overlord.Fronts and Overlord.Fronts.IsFeaturedFrontActive and Overlord.Fronts:IsFeaturedFrontActive() then
            Overlord.Leaderboard:AddKills(playerFullName, 1, false)
            totalKills = totalKills + 1
            if Overlord.Ressources and Overlord.Ressources.AddGold then
                Overlord.Ressources:AddGold(1)
            end
        end
        if Overlord.BountySync and Overlord.BountySync.RegisterPriorKillCredit then
            Overlord.BountySync:RegisterPriorKillCredit(playerFullName, contractVictimName)
        end
        if Overlord.Leaderboard.UpdateLocalPlayerGuild then
            Overlord.Leaderboard:UpdateLocalPlayerGuild()
        end
        if Overlord.InActiveFront and Overlord.Bounty and Overlord.Bounty.OnLocalKill then
            Overlord.Bounty:OnLocalKill()
        end

        local currentZone = Overlord.Zones:GetCurrentPlayerZone()
        if Overlord.Sync and Overlord.Sync.BroadcastKill then
            -- Le leaderboard est global au front : meme hors disque de capture, diffuser le total.
            -- Le zoneId vide reste valide pour K (il sert seulement aux compteurs de zone distants).
            Overlord.Sync:BroadcastKill(currentZone and currentZone.id or "", totalKills,
                not bountyProofOnly)
        end
        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.KILL_CONFIRM, victimName or "?", totalKills))
        killCredited = true
        NoteDetailedLocalKillCredit(victimGUID, healerBatch)
    elseif killerGUID and killerName and IsValidPlayerName(killerName) then
        local fullKillerName = killerName
        if not fullKillerName:find("-") then
            -- WoW 12.0.5 : SafeGetRealmName gere les secret values
            local realm = Overlord:SafeGetRealmName()
            if realm and realm ~= "" then
                fullKillerName = killerName .. "-" .. realm
            end
        end
        -- Kill allie observe : compter localement, mais ne pas marquer de credit "joueur local"
        -- pour le filtre d'export Check PvP. Si BD arrive ensuite, priorKillCredit garde +2 net.
        Overlord.Leaderboard:RegisterKill(fullKillerName, true)
        if Overlord.BountySync and Overlord.BountySync.RegisterPriorKillCredit then
            Overlord.BountySync:RegisterPriorKillCredit(fullKillerName, victimName)
        end
        if Overlord.Sync and Overlord.Sync.RegisterRecentKCredit then
            Overlord.Sync:RegisterRecentKCredit(fullKillerName, true)
        end
        local killerFac = playerFaction
        if killerGUID and guidFactionCache[killerGUID] then
            killerFac = guidFactionCache[killerGUID]
        end
        local killerClass = killerGUID and guidAllyClassCache[killerGUID]
        if killerClass then
            Overlord.Leaderboard:SetPlayerInfo(fullKillerName, killerClass, killerFac)
        elseif killerFac == "Alliance" or killerFac == "Horde" then
            Overlord.Leaderboard:SetPlayerFaction(fullKillerName, killerFac)
        end
        local killerGuild = killerGUID and guidAllyGuildCache[killerGUID]
        if killerGuild and killerGuild ~= ""
            and Overlord.Leaderboard.SetPlayerGuild then
            Overlord.Leaderboard:SetPlayerGuild(fullKillerName, killerGuild)
        end
        killCredited = true
    end

    -- Kill de zone : disques de capture du front actif uniquement (pas fortins / mines EK).
    if Overlord.InActiveFront and victimName and victimName ~= "?" then
        local currentZone = Overlord.Zones:GetCurrentPlayerZone()
        if currentZone and currentZone.status ~= "locked" then
            self:RegisterZoneKill(currentZone, killerGUID, killerName, victimName, playerFaction)
        end
    end
    if killCredited then
        local enrichedVictimName = ResolveManualBountyVictimName(victimGUID, victimName)
        RecordProcessKillDedup(victimGUID, enrichedVictimName, victimName, now)
    end
    return killCredited
end

-- Enregistre un kill pour une zone specifique (compteur zone + progression capture)
-- killerFaction : faction du tueur ("Alliance" ou "Horde"), nil = inconnu
function Overlord.Combat:RegisterZoneKill(zone, killerGUID, killerName, victimName, killerFaction)
    zone.killsCurrent = (zone.killsCurrent or 0) + 1

    -- Compteurs par faction pour l'ecran de victoire
    if killerFaction == "Alliance" then
        zone.allyKillsCurrent  = (zone.allyKillsCurrent  or 0) + 1
    elseif killerFaction == "Horde" then
        zone.enemyKillsCurrent = (zone.enemyKillsCurrent or 0) + 1
    end

    -- Ne pas demarrer in_progress ici : pas de holdAuthorityLocal ni ZS coherent.
    -- ZoneControl demarre la capture (IsZoneAvailable, StartHoldTimer, BroadcastZoneState).

    Overlord:MarkDirty()
    if Overlord.UI then
        Overlord.UI:RequestRefresh()
    end
end

-- UNIT_TARGET filtre via RegisterUnitEvent("player") : ne fire que pour nos changements
-- de cible, pas les 200 unites du champ de bataille. Stocke le dernier ennemi cible.
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Combat:OnUnitTarget(unit)
    if unit ~= "player" then return end
    if not UnitExists("target") or not UnitIsPlayer("target") then return end
    local enemyFaction = Overlord.Zones and Overlord.Zones:GetEnemyFaction()
    if not enemyFaction then return end
    local targetFaction = UnitFactionGroup("target")
    if targetFaction ~= enemyFaction then return end
    if UnitIsDead("target") then return end
    -- UnitFullName donne le royaume quand l'API le connait ; sinon meme royaume local.
    local name = SafeFullUnitName("target")
    local guid = UnitGUID("target")
    -- N'enregistre pas le placeholder "Unknown" : il empoisonnerait lastEnemyTarget
    -- et serait ensuite credite comme tueur sur PLAYER_DEAD.
    if name and IsValidPlayerName(name) then
        lastEnemyTarget.name = name
        lastEnemyTarget.guid = guid
        lastEnemyTarget.time = GetTime()
        local _, class = UnitClass("target")
        local _, race = UnitRace("target")
        CacheEnemyPlayerInfo(guid, name, class, race, UnitSex("target") or 0)
    end
end

-- PLAYER_DEAD : le joueur est mort. On identifie l'ennemi le plus probable
-- et on enregistre un kill pour la faction ennemie.
-- Sources d'identification du tueur (par priorite) :
--   1) Notre cible actuelle si c'est un joueur ennemi vivant
--   2) Le dernier ennemi cible (lastEnemyTarget, < 10s)
--   3) Le nameplate ennemi le plus proche
function Overlord.Combat:OnPlayerDead()
    dbg("PLAYER_DEAD event fired")

    local now = GetTime()
    local killerName, killerGUID = self:IdentifyKiller()
    local killerValid = killerName and IsValidPlayerName(killerName)
    local victimIsBounty = Overlord.Bounty and Overlord.Bounty.IsLocalPlayerBounty
        and Overlord.Bounty:IsLocalPlayerBounty()
    local victimIsGeneral = Overlord.General and Overlord.General.IsLocalHolder
        and Overlord.General:IsLocalHolder()

    -- Dedup morts rapprochees ; le general local ignore la dedup pour ne pas bloquer GD
    if now - lastDeathTime < DEATH_DEDUP_WINDOW and not victimIsGeneral then
        if not (victimIsBounty and killerValid) then
            dbg("  dedup mort: ignore")
            return
        end
        dbg("  dedup mort: retry prime avec tueur identifie")
    end
    lastDeathTime = now

    if not killerValid then
        dbg("  aucun tueur identifie (ou nom Unknown non resolu)")
        if victimIsGeneral then
            if Overlord.General.ClearLocalOnDeath then
                Overlord.General:ClearLocalOnDeath()
            end
            -- GD part tout de suite : le slot distant ne doit pas survivre à un reload/crash local.
            if Overlord.General and Overlord.General.EmitPendingDown then
                Overlord.General:EmitPendingDown(nil, nil, "")
            end
        end
        if Overlord.Bounty and Overlord.Bounty.OnLocalDeathAbort then
            Overlord.Bounty:OnLocalDeathAbort()
        elseif Overlord.Bounty and Overlord.Bounty.ResetStreak then
            Overlord.Bounty:ResetStreak()
        end
        return
    end

    dbg("  tueur identifie:", killerName)

    -- IdentifyKiller renvoie deja Nom-Royaume pour que les EK soient acceptes en sync.
    local fullKillerName = killerName
    if Overlord.Sync and Overlord.Sync.NormalizeContributorFullName then
        fullKillerName = Overlord.Sync:NormalizeContributorFullName(killerName) or killerName
    end

    if Overlord.ManualBounty and Overlord.ManualBounty.OnLocalDeath then
        Overlord.ManualBounty:OnLocalDeath(fullKillerName)
    end

    local enemyFaction = Overlord.Zones:GetEnemyFaction()
    local killerClass, killerRace, killerRaceSex = self:GetEnemyClassFromNameplate(killerName)
    local cachedKiller = killerGUID and guidPlayerInfoCache[killerGUID]
    if cachedKiller then
        killerClass = killerClass or cachedKiller.class
        killerRace = killerRace or cachedKiller.race
        if killerRaceSex ~= 2 and killerRaceSex ~= 3 then
            killerRaceSex = cachedKiller.raceSex or 0
        end
    end
    local currentZoneOnDeath = Overlord.Zones:GetCurrentPlayerZone()
    local zoneNotLocked = currentZoneOnDeath and currentZoneOnDeath.status ~= "locked"
    local zoneIdForBounty = (zoneNotLocked and currentZoneOnDeath and currentZoneOnDeath.id) or ""

    if victimIsGeneral and Overlord.General.OnLocalDeath then
        Overlord.General:OnLocalDeath(fullKillerName, killerClass, zoneIdForBounty)
    end

    if not Overlord.InActiveFront then
        if not victimIsBounty then
            ResetBountyStreakOutsideFront()
        end
        -- Prime : reglement meme hors zone de scoring (capital, voyage, etc.).
        if victimIsBounty then
            if Overlord.Bounty and Overlord.Bounty.OnLocalDeath then
                Overlord.Bounty:OnLocalDeath(fullKillerName, killerClass, enemyFaction, zoneIdForBounty)
            end
            return
        end
        if not IsKillScoringActive() then return end
    end

    if victimIsBounty then
        if Overlord.Bounty and Overlord.Bounty.OnLocalDeath then
            Overlord.Bounty:OnLocalDeath(fullKillerName, killerClass, enemyFaction, zoneIdForBounty)
        end
    else
        if Overlord.InActiveFront and Overlord.Bounty and Overlord.Bounty.ResetStreak then
            Overlord.Bounty:ResetStreak()
        end
        if IsKillScoringActive() then
            -- Anti-farming : la victime c'est nous ; l'attaquant est l'ennemi qui nous a tues.
            -- WoW 12.0.5 : SafeUnitName gere les secret values
            local myName = Overlord.Sync and Overlord.Sync:GetPlayerFullName() or Overlord:SafeUnitName("player") or "?"
            if not RecordAndCheckKillFarm(fullKillerName, myName) then
                Overlord.Leaderboard:RegisterKill(fullKillerName)
                -- La victime connait le front physique du kill : appliquer aussi localement
                -- le second credit du front du jour sans attendre le total K cross-faction.
                if Overlord.Fronts and Overlord.Fronts.IsFeaturedFrontActive
                    and Overlord.Fronts:IsFeaturedFrontActive() then
                    Overlord.Leaderboard:AddKills(fullKillerName, 1, true)
                end
                Overlord.Leaderboard:SetPlayerFaction(fullKillerName, enemyFaction)

                if killerClass then
                    Overlord.Leaderboard:SetPlayerInfo(fullKillerName, killerClass, enemyFaction)
                end
                if killerRace and Overlord.Leaderboard.SetPlayerRace then
                    Overlord.Leaderboard:SetPlayerRace(fullKillerName, killerRace, killerRaceSex, false)
                end

                -- Broadcast EK (Enemy Kill event) au lieu de K (total).
                if Overlord.Sync then
                    local classStr = killerClass or ""
                    local ts = time()
                    local zoneIdForEK = zoneIdForBounty
                    local temporaryRootMapID = nil
                    if zoneIdForEK == "" and Overlord.IsInTemporaryKillScoringZone then
                        local inTemporaryZone, resolvedRootMapID =
                            Overlord:IsInTemporaryKillScoringZone()
                        if inTemporaryZone then temporaryRootMapID = resolvedRootMapID end
                    end
                    -- L'activite recente n'a pour l'instant qu'une ligne dediee
                    -- a la Coiled Isle : ne pas y classer Slayer's Rise par erreur.
                    if zoneIdForEK == "" and temporaryRootMapID == 2512 then
                        zoneIdForEK = "@coiled_isle"
                    elseif zoneIdForEK == "" and Overlord.InActiveFront
                        and Overlord.Fronts and Overlord.Fronts.activeFrontId then
                        zoneIdForEK = "@" .. Overlord.Fronts.activeFrontId
                    end
                    local epoch = (Overlord.GetCurrentCampaignWireEpoch and Overlord:GetCurrentCampaignWireEpoch())
                        or (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
                        or (OverlordDB and OverlordDB.lastResetTimestamp) or 0
                    local payload = fullKillerName .. ":" .. classStr .. ":" .. (enemyFaction or "") .. ":" .. ts .. ":" .. zoneIdForEK .. ":" .. epoch
                    if Overlord.FrontActivity and Overlord.FrontActivity.RecordLocalByZoneRef then
                        Overlord.FrontActivity:RecordLocalByZoneRef(zoneIdForEK, fullKillerName)
                    end
                    local largeSyncEvent = Overlord.Sync.IsLargeEvent
                        and Overlord.Sync:IsLargeEvent()
                    if largeSyncEvent then
                        Overlord.Sync:Send("EK", payload)
                    elseif Overlord.Sync.SendToGroup then
                        Overlord.Sync:SendToGroup("EK", payload)
                    end
                    if Overlord.Sync.SendToChannel and not largeSyncEvent then
                        Overlord.Sync:SendToChannel("EK", payload)
                    end
                    if Overlord.Sync.BroadcastToCommunity and not largeSyncEvent then
                        Overlord.Sync:BroadcastToCommunity("EK", payload, 12, 0.35)
                    end
                end

                local playerName = Overlord:SafeUnitName("player") or "?"
                Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.KILL_ENEMY_NEARBY,
                    killerName:match("^(.-)%-") or killerName, playerName))
            end
        end
    end

    -- Kill de zone : le tueur est forcement la faction ennemie (on vient de mourir)
    if Overlord.InActiveFront and zoneNotLocked then
        local playerName = Overlord:SafeUnitName("player") or "?"
        self:RegisterZoneKill(currentZoneOnDeath, killerGUID, fullKillerName,
            playerName, enemyFaction)
    end
end

-- Identifie le tueur le plus probable apres notre mort.
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Combat:IdentifyKiller()
    local enemyFaction = Overlord.Zones and Overlord.Zones:GetEnemyFaction()
    if not enemyFaction then return nil, nil end

    -- 1) Cible actuelle = joueur ennemi vivant
    if UnitExists("target") and UnitIsPlayer("target")
        and UnitFactionGroup("target") == enemyFaction and not UnitIsDead("target") then
        -- UnitFullName donne le royaume quand l'API le connait ; sinon meme royaume local.
        local n = SafeFullUnitName("target")
        if n and IsValidPlayerName(n) then
            return n, UnitGUID("target")
        end
    end

    -- 2) Dernier ennemi cible (< 10s, donc pendant le combat recent)
    local now = GetTime()
    if lastEnemyTarget.name and IsValidPlayerName(lastEnemyTarget.name)
        and (now - lastEnemyTarget.time) < 10 then
        return lastEnemyTarget.name, lastEnemyTarget.guid
    end

    -- 3) Nameplate ennemi la plus proche (premier joueur ennemi vivant)
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsDead(unit) then
            local faction = UnitFactionGroup(unit)
            if faction == enemyFaction then
                -- UnitFullName donne le royaume quand l'API le connait ; sinon meme royaume local.
                local n = SafeFullUnitName(unit)
                if n and IsValidPlayerName(n) then
                    return n, UnitGUID(unit)
                end
            end
        end
    end

    return nil, nil
end

-- Recupere classe, race et sexe d'un joueur ennemi via les nameplates visibles.
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Combat:GetEnemyClassFromNameplate(name)
    if not name or not IsValidPlayerName(name) then return nil end
    local shortName = name:match("^(.-)%-") or name
    local requiresFullName = name:find("-", 1, true) ~= nil
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            -- UnitFullName donne le royaume quand l'API le connait ; sinon meme royaume local.
            local npName = SafeFullUnitName(unit)
            if npName and IsValidPlayerName(npName) then
                local npShort = npName:match("^(.-)%-") or npName
                -- SafeStringEquals pour comparer avec les noms potentiellement secrets
                local matches
                if requiresFullName then
                    matches = Overlord:SafeStringEquals(npName, name)
                else
                    matches = Overlord:SafeStringEquals(npShort, shortName)
                end
                if matches then
                    local _, className = UnitClass(unit)
                    local _, raceFile = UnitRace(unit)
                    return className, raceFile, UnitSex(unit) or 0
                end
            end
        end
    end
    return nil
end


function Overlord.Combat:Suspend()
    ResetPvpKillReconciliation()
    if rosterRefreshTimer then
        rosterRefreshTimer:Cancel()
        rosterRefreshTimer = nil
    end
    combatFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    combatFrame:UnregisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    combatFrame:UnregisterEvent("PARTY_KILL")
    combatFrame:UnregisterEvent("PLAYER_PVP_KILLS_CHANGED")
    combatFrame:UnregisterEvent("PLAYER_DEAD")
    combatFrame:UnregisterEvent("UNIT_TARGET")
end

function Overlord.Combat:Resume()
    -- Les HK/KB gagnees en instance pendant la suspension ne doivent pas etre
    -- rejouees comme des kills open-world au prochain event apres la sortie.
    RefreshPvpKillBaselines()
    combatFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    combatFrame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    combatFrame:RegisterEvent("PARTY_KILL")
    combatFrame:RegisterEvent("PLAYER_PVP_KILLS_CHANGED")
    combatFrame:RegisterEvent("PLAYER_DEAD")
    combatFrame:RegisterUnitEvent("UNIT_TARGET", "player")
    self:RefreshGUIDCache()
end
