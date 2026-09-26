-- SyncOutpost.lua - Protocoles OP / OC pour avant-postes
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local OP_COMMUNITY_CAPTURE_MAX = 40
local OP_COMMUNITY_CAPTURE_DELAY = 0.25
local OP_COMMUNITY_CAPTURE_MAX_LARGE = 12
local OP_COMMUNITY_CAPTURE_DELAY_LARGE = 0.35
local OP_POST_CAPTURE_STATE_DELAY = 4.0
local OP_CAPTURE_REPLAY_DELAY_1 = 1.0
local OP_CAPTURE_REPLAY_DELAY_2 = 3.0
local lastCommunityOPBroadcast = {}
local OP_COMMUNITY_ROUTINE_INTERVAL = 12
local VALID_OP_STATUS = { neutral = true, in_progress = true, held = true }
local MAX_CLOCK_SKEW = 300
local OC_DEDUP_SEC = 10
local OP_DEDUP_SEC = 4
local OP_DEDUP_MAX = 128
local OC_DEDUP_MAX = 256
local OC_COMMUNITY_ACCEPT_MAX_AGE = 900
local lastStaleOutpostObserverPoll = 0
local STALE_OUTPOST_OBSERVER_POLL_INTERVAL = 22
local STALE_OUTPOST_OBSERVER_POLL_INTERVAL_LARGE = 45
local opCaptureAlertDedup = {}
local OP_CAPTURE_ALERT_DEDUP_SEC = 12
local OP_ASSAULT_ALERT_COOLDOWN = 90
local OP_DEFENDER_ALERT_COOLDOWN = 90
local opAssaultAlertLast = {}
local opAssaultAlertEmitted = {}
local opAssaultAlertWaveKey = {}
local opDefenderAlertLast = {}
local opDefenderAlertEmitted = {}
local opDefenderAlertHadGuild = {}
local opDefenderAlertWaveKey = {}
-- Sept tables reutilisees (une par avant-poste) : conserver le vrai etat pre-mutation
-- sans allouer une table a chaque heartbeat OP de 5 s.
local opTransitionBefore = {}
local pendingRestoreOc = {}
local pendingRestoreOcCount = 0
local PENDING_RESTORE_OC_MAX = 24
local pendingRestoreOcFlushQueued = false
local LO_DEDUP_SEC = 12
local LOC_DEDUP_SEC = 12
local OUTPOST_LADDER_DEDUP_MAX = 256
local srLegacyOutpostCountCursor = 0

-- Registre TTL/LRU a expirations liees. Chaque lookup/admission/refresh est O(1) ;
-- la purge ne visite que la tete expiree avec un quota fixe. A saturation, une
-- nouvelle cle est refusee (fail closed) plutot que d'evincer une preuve encore
-- vivante, ce qui empecherait un ancien paquet de rejouer pendant sa fenetre TTL.
local function NewOutpostDedup(ttl, maxRows)
    return {
        ttl = ttl, max = maxRows, count = 0,
        nodes = {}, head = nil, tail = nil,
    }
end

local opDedup = NewOutpostDedup(OP_DEDUP_SEC, OP_DEDUP_MAX)
local ocDedup = NewOutpostDedup(OC_DEDUP_SEC, OC_DEDUP_MAX)
local loDedup = NewOutpostDedup(LO_DEDUP_SEC, OUTPOST_LADDER_DEDUP_MAX)
local loSendDedup = NewOutpostDedup(LO_DEDUP_SEC, OUTPOST_LADDER_DEDUP_MAX)
local locDedup = NewOutpostDedup(LOC_DEDUP_SEC, OUTPOST_LADDER_DEDUP_MAX)
local locSendDedup = NewOutpostDedup(LOC_DEDUP_SEC, OUTPOST_LADDER_DEDUP_MAX)

local function RemoveOutpostDedupNode(registry, node)
    if node.previous then node.previous.next = node.next else registry.head = node.next end
    if node.next then node.next.previous = node.previous else registry.tail = node.previous end
    registry.nodes[node.key] = nil
    registry.count = math.max(0, registry.count - 1)
end

local function PruneOutpostDedupRegistry(registry, now, quota)
    local removed = 0
    while registry.head and registry.head.expiresAt <= now
        and removed < (quota or 4) do
        RemoveOutpostDedupNode(registry, registry.head)
        removed = removed + 1
    end
    return removed
end

local function OutpostDedupIsRecent(registry, key, now)
    local node = registry.nodes[key]
    if not node then return false end
    if node.expiresAt <= now then
        RemoveOutpostDedupNode(registry, node)
        return false
    end
    return true
end

local function RememberOutpostDedup(registry, key, now)
    if key == nil then return false end
    local node = registry.nodes[key]
    if node then
        node.expiresAt = now + registry.ttl
        if node ~= registry.tail then
            if node.previous then node.previous.next = node.next else registry.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = registry.tail, nil
            if registry.tail then registry.tail.next = node else registry.head = node end
            registry.tail = node
        end
        return true
    end
    PruneOutpostDedupRegistry(registry, now, 4)
    if registry.count >= registry.max then return false end
    node = { key = key, expiresAt = now + registry.ttl, previous = registry.tail }
    registry.nodes[key] = node
    if registry.tail then registry.tail.next = node else registry.head = node end
    registry.tail = node
    registry.count = registry.count + 1
    return true
end

local function AdmitOutpostDedup(registry, key, now)
    if OutpostDedupIsRecent(registry, key, now) then return false end
    return RememberOutpostDedup(registry, key, now)
end

local FactionToCode

local function SnapshotOutpostTransitionState(siteKey, st)
    local snap = opTransitionBefore[siteKey]
    if not snap then
        snap = {}
        opTransitionBefore[siteKey] = snap
    end
    snap.status = st and st.status or "neutral"
    snap.ownerGuild = st and st.ownerGuild or ""
    snap.ownerFaction = st and st.ownerFaction or nil
    snap.claimedAt = st and st.claimedAt or 0
    snap.expiresAt = st and st.expiresAt or 0
    snap.updatedAt = st and st.updatedAt or 0
    snap.holdTimeElapsed = st and st.holdTimeElapsed or 0
    snap.holdTimeRequired = st and st.holdTimeRequired or nil
    snap.isContested = st and st.isContested or false
    snap.holdAuthorityLocal = st and st.holdAuthorityLocal or false
    snap.previousOwnerGuild = st and st.previousOwnerGuild or ""
    snap.previousOwnerFaction = st and st.previousOwnerFaction or nil
    snap.previousClaimedAt = st and st.previousClaimedAt or 0
    snap.previousExpiresAt = st and st.previousExpiresAt or 0
    snap.pool = st and st.pool or ""
    return snap
end

local function StableSyncBucket(value, bucketCount)
    local h = 5381
    value = tostring(value or "")
    for i = 1, #value do
        h = (h * 33 + string.byte(value, i)) % 2147483647
    end
    return h % bucketCount
end

local function FactionCodeToFaction(code)
    if code == "A" then return "Alliance" end
    if code == "H" then return "Horde" end
    return nil
end

FactionToCode = function(fac)
    if fac == "Alliance" then return "A" end
    if fac == "Horde" then return "H" end
    return ""
end

local VALID_POOL_TAG = { global = true }

local function NormalizePoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if VALID_POOL_TAG[pool] then return pool end
    return ""
end

local function CurrentOutpostPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizePoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

-- Le lien Outpost historique FR<->EU reste compatible sur ses transports
-- existants. Les autres pools europeens ne se projettent localement que via
-- un membre reel du PARTY/RAID.
local function OutpostPayloadPoolAcceptable(remotePool, sender, sourceChannel)
    remotePool = NormalizePoolTag(remotePool)
    if remotePool == "" then return false end
    local localPool = CurrentOutpostPoolTag()
    if localPool == "" then return false end
    local rp = Overlord.RealmPools
    if rp and rp.AreOutpostCrossPoolsLinked
        and rp:AreOutpostCrossPoolsLinked(localPool, remotePool) then
        return remotePool
    end
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        return Overlord.Sync:ResolveDirectGroupTerritorialPool(
            remotePool, sender, sourceChannel)
    end
    return localPool ~= "" and remotePool == localPool and localPool or false
end

local function OutpostPayloadHasExplicitLinkedPool(remotePool)
    return OutpostPayloadPoolAcceptable(remotePool)
end

local function OutpostSyncBlocked(allowInstance)
    if Overlord.InstanceSuspended then return true end
    if allowInstance then return false end
    return IsInInstance and IsInInstance()
end

local function NormalizeRemoteTimestamp(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return 0 end
    local now = time()
    if ts > now + MAX_CLOCK_SKEW then return nil end
    return math.floor(ts)
end

local function IsStaleCampaignTimestamp(ts)
    local lastReset = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    return ts and ts > 0 and lastReset > 0 and ts < lastReset
end

local function OutpostSyncTimestamp(st)
    if not st then return 0 end
    local ts = tonumber(st.updatedAt) or 0
    if ts > 0 then return ts end
    if st.status == "held" then
        local ca = math.floor(tonumber(st.claimedAt) or 0)
        if ca > 0 then return ca end
    end
    if st.status == "neutral" and (st.ownerGuild or "") == ""
        and (st.holdTimeElapsed or 0) <= 0 and (st.claimedAt or 0) <= 0 then
        return 0
    end
    return 0
end

local function IsOpLargeEvent()
    return Overlord.Sync and Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
end

local function GetOcCommunityRelayLimits()
    if IsOpLargeEvent() then
        return OP_COMMUNITY_CAPTURE_MAX_LARGE, OP_COMMUNITY_CAPTURE_DELAY_LARGE
    end
    return OP_COMMUNITY_CAPTURE_MAX, OP_COMMUNITY_CAPTURE_DELAY
end

local function BroadcastOutpostToGroup(msgType, payload)
    if not payload or payload == "" then return end
    if not IsInGroup or not IsInGroup() then return end
    if Overlord.Sync and Overlord.Sync.Send then
        Overlord.Sync:Send(msgType, payload)
    end
end

local function BroadcastOutpostCaptureToCommunity(msgType, payload, maxMembers, whisperDelaySec, forceTargets)
    if not payload or payload == "" then return end
    if Overlord.Sync and Overlord.Sync.BroadcastToCommunity then
        Overlord.Sync:BroadcastToCommunity(msgType, payload, maxMembers, whisperDelaySec, forceTargets)
    end
end

local function NormalizeOpCapturerName(name)
    if not name or type(name) ~= "string" then return "" end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t < 2 or #t > 50 then return "" end
    return t
end

local function BuildOutpostPayload(siteKey, st)
    if not siteKey or not st or not Overlord.Outpost then return nil end
    local OP = Overlord.Outpost
    if OP.IsOutpostStateAwaitingNetworkSnapshot and OP:IsOutpostStateAwaitingNetworkSnapshot(st) then
        return nil
    end
    local status = st.status or "neutral"
    local holdTime = math.floor(st.holdTimeElapsed or 0)
    local guild = OP:SanitizeGuildName(st.ownerGuild or "")
    local facCode = FactionToCode(st.ownerFaction)
    local claimedAt = math.floor(st.claimedAt or 0)
    local expiresAt = math.floor(st.expiresAt or 0)
    local ts = OutpostSyncTimestamp(st)
    local holdReq = math.floor(OP:GetDefaultHoldTimeRequired(st))
    local pool = NormalizePoolTag(st.pool)
    if pool == "" then pool = CurrentOutpostPoolTag() end
    if pool == "" then return nil end
    local contested = (st.isContested and status == "in_progress") and 1 or 0
    local payload = string.format("v1:%s:%s:%d:%s:%s:%d:%d:%d:%d:%s:%d",
        siteKey, status, holdTime, guild, facCode, claimedAt, expiresAt, ts, holdReq, pool, contested)
    if status == "in_progress" then
        local prevG = OP:SanitizeGuildName(st.previousOwnerGuild or "")
        local prevF, prevCa, prevEx = "", 0, 0
        if prevG ~= "" and st.previousOwnerFaction then
            prevF = FactionToCode(st.previousOwnerFaction) or ""
            prevCa = math.floor(st.previousClaimedAt or 0)
            prevEx = math.floor(st.previousExpiresAt or 0)
        end
        local capturerName = ""
        if st.holdAuthorityLocal and st.isHolding and st.ownerFaction == Overlord.PlayerFaction then
            if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
                capturerName = NormalizeOpCapturerName(Overlord.Sync:GetPlayerFullName() or "")
            end
        end
        payload = payload .. string.format(":%s:%s:%d:%d:%s",
            prevG, prevF, prevCa, prevEx, capturerName)
    end
    return payload
end

local function OpRosterMatchKey(name)
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local dk = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if dk and dk ~= "" then return dk:lower() end
    end
    return ""
end

local function PruneOpDedup(now)
    -- Six quotas fixes : meme sous flood, aucun handler ne rescane une table.
    PruneOutpostDedupRegistry(opDedup, now, 4)
    PruneOutpostDedupRegistry(ocDedup, now, 4)
    PruneOutpostDedupRegistry(loDedup, now, 4)
    PruneOutpostDedupRegistry(loSendDedup, now, 4)
    PruneOutpostDedupRegistry(locDedup, now, 4)
    PruneOutpostDedupRegistry(locSendDedup, now, 4)
end

local function OcHasLocalCaptureEvidence(st, guild, fac, remoteTs)
    if not st or st.status ~= "in_progress" or not fac then return false end
    local op = Overlord.Outpost
    guild = op and op:SanitizeGuildName(guild or "") or (guild or "")
    local localGuild = op and op:SanitizeGuildName(st.ownerGuild or "") or (st.ownerGuild or "")
    if guild == "" or localGuild ~= guild or st.ownerFaction ~= fac then return false end
    local localTs = tonumber(st.updatedAt) or 0
    if localTs <= 0 or remoteTs <= 0 then return true end
    return remoteTs + 5 >= localTs
end

local function OcCaptureTimestampAcceptable(st, guild, fac, remoteTs)
    if not st or not fac or not remoteTs or remoteTs <= 0 then return true end
    local op = Overlord.Outpost
    guild = op and op:SanitizeGuildName(guild or "") or (guild or "")
    local localClaimed = tonumber(st.claimedAt) or 0
    if st.status == "held" then
        local tg = op and op:SanitizeGuildName(st.ownerGuild or "") or (st.ownerGuild or "")
        if st.ownerFaction and fac ~= st.ownerFaction and guild ~= "" and tg ~= guild then
            if localClaimed <= 0 or remoteTs > localClaimed then return true end
            if remoteTs < localClaimed then return false end
            return (guild:lower() .. ":" .. fac) < (tg:lower() .. ":" .. st.ownerFaction)
        end
    end
    if st.status == "neutral" or st.status == "in_progress" then
        return localClaimed <= 0 or remoteTs >= localClaimed
    end
    local localTs = tonumber(st.updatedAt) or 0
    if localTs <= 0 or remoteTs >= localTs then return true end
    return false
end

local function OpSenderIsInOurGroup(sender)
    if not sender or sender == "" or not IsInGroup() then return false end
    local want = OpRosterMatchKey(sender)
    local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and 40 or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local full = Overlord:SafeGetUnitName(unit, true)
            if OpRosterMatchKey(full) == want then return true end
        end
    end
    local selfFull = Overlord:SafeGetUnitName("player", true)
    return OpRosterMatchKey(selfFull) == want
end

local function GetOpAddonSenderGuild(sender)
    if not sender or sender == "" or sender:find("^BNet%-", 1) then return nil end
    if not IsInGroup() then return nil end
    local want = OpRosterMatchKey(sender)
    local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and 40 or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local full = Overlord:SafeGetUnitName(unit, true)
            if OpRosterMatchKey(full) == want and Overlord.SafeGetGuildInfo then
                local g = Overlord:SafeGetGuildInfo(unit) or ""
                if Overlord.Outpost and Overlord.Outpost.SanitizeGuildName then
                    return Overlord.Outpost:SanitizeGuildName(g), UnitFactionGroup(unit)
                end
                return g, UnitFactionGroup(unit)
            end
        end
    end
    return nil
end

local function OcSenderMatchesPayloadGuild(sender, guild, faction)
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    if not sender or sender == "" or guild == "" then return false end
    if sender:find("^BNet%-", 1) then return false end
    if not OpSenderIsInOurGroup(sender) then return false end
    local senderGuild, senderFaction = GetOpAddonSenderGuild(sender)
    if senderGuild and senderGuild ~= "" then
        return senderGuild == guild
            and (not faction or faction == "" or senderFaction == faction)
    end
    return false
end

local function ShouldAcceptOutpostCapture(siteKey, guild, fac, remoteTs, sender, sourceChannel)
    if not Overlord.Outpost then return false end
    local st = Overlord.Outpost:GetState(siteKey)
    if not st then return false end
    guild = Overlord.Outpost:SanitizeGuildName(guild or "")
    if guild == "" or not fac then return false end
    -- Faction declaree du paquet d'abord, vote heuristique en secours (anti-homonymie),
    -- meme regle que ShouldAcceptGuildKeepCapture.
    local effectiveFac = (fac == "Alliance" or fac == "Horde") and fac
        or Overlord.Outpost:GetEffectiveGuildFaction(guild, fac)
    if not effectiveFac then return false end
    if not Overlord.Outpost:IsCaptureTakeoverAllowed(
        st, guild, effectiveFac, remoteTs) then return false end

    if st.status == "held" then
        local heldGuild = Overlord.Outpost:SanitizeGuildName(st.ownerGuild or "")
        if heldGuild ~= "" and heldGuild == guild then return false end
        if st.ownerGuild == guild and st.ownerFaction == fac then return false end
        if st.ownerFaction and effectiveFac == st.ownerFaction then return false end
    end

    if st.status == "in_progress" then
        local previousGuild = Overlord.Outpost:SanitizeGuildName(st.previousOwnerGuild or "")
        if previousGuild ~= "" and previousGuild == guild then return false end
        if st.previousOwnerFaction and effectiveFac == st.previousOwnerFaction then return false end
        if st.ownerFaction and effectiveFac == st.ownerFaction and guild ~= (st.ownerGuild or "") then
            return false
        end
    end

    if st.holdAuthorityLocal and st.status == "in_progress" then
        local site = Overlord.Outpost:GetSite(siteKey)
        local req = st.holdTimeRequired or (site and site.holdTimeRequired) or 300
        if st.isPaused or st.isContested or (st.holdTimeElapsed or 0) < req then
            return false
        end
        if effectiveFac == st.ownerFaction and guild ~= (st.ownerGuild or "") then
            return false
        end
    end

    if not OcSenderMatchesPayloadGuild(sender, guild, fac) then
        local fromChannel = sourceChannel == "CHANNEL"
        if not fromChannel and (not Overlord.Sync.IsGuildKeepCommunitySender
            or not Overlord.Sync:IsGuildKeepCommunitySender(sender)) then
            return false
        end
        if not OcHasLocalCaptureEvidence(st, guild, fac, remoteTs) then
            local crossFactionTakeover = st.status == "held" and st.ownerFaction
                and effectiveFac ~= st.ownerFaction
            local neutralCatchup = st.status == "neutral"
            if not crossFactionTakeover and not neutralCatchup then
                return false
            end
        end
        if remoteTs > 0 and (time() - remoteTs) > OC_COMMUNITY_ACCEPT_MAX_AGE then
            return false
        end
    end

    if not OcCaptureTimestampAcceptable(st, guild, fac, remoteTs) then
        return false
    end
    return true
end

local function OutpostRestoreOcBlocked()
    if OutpostSyncBlocked() or Overlord.WaitingForSync then return true end
    if Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive() then return true end
    return false
end

local function ScheduleOcFlushRetry()
    if pendingRestoreOcFlushQueued then return end
    if not next(pendingRestoreOc) then return end
    pendingRestoreOcFlushQueued = true
    C_Timer.After(9, function()
        pendingRestoreOcFlushQueued = false
        if Overlord.Sync and Overlord.Sync.FlushPendingOutpostRestoreBroadcasts then
            Overlord.Sync:FlushPendingOutpostRestoreBroadcasts()
        end
    end)
end

-- Identite de campagne : fenetre hebdomadaire du reset officiel Blizzard (region-wide coherent),
-- pas le jour calendaire. Le jour (AAAAMMJJ) derivait selon le fuseau cote NA (mardi continental vs
-- mercredi Oceanique) et faisait rejeter les messages outpost entre clients d'une meme region.
-- Un epoch distant est valide s'il tombe dans la meme fenetre [debut campagne ; debut + 1 semaine).
-- 604800 = 7 jours. EU non affecte (reset deja coherent tous fuseaux).
local function IsCurrentSyncCampaignEpoch(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local localStart = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if localStart <= 0 then return false end
    if Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(epoch, localStart) then
        return true
    end
    return epoch >= localStart and epoch < localStart + 604800
end

local function IsOutpostLeaderboardTimestampCurrent(ts, wireEpoch)
    ts = math.floor(tonumber(ts) or 0)
    wireEpoch = math.floor(tonumber(wireEpoch) or 0)
    if ts <= 0 or wireEpoch <= 0 then return false end
    if ts >= wireEpoch and ts < wireEpoch + 604800 then return true end
    return Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(ts, wireEpoch) or false
end

local function SenderRealmMatchesCurrentOutpostPool(sender, sourceChannel)
    if sourceChannel == "BETA" and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:IsDispatching(sender)
    end
    if type(sender) ~= "string" or sender == "" then return false end
    if (sourceChannel == "PARTY" or sourceChannel == "RAID")
        and Overlord.Sync and Overlord.Sync.SenderIsInOurGroup
        and Overlord.Sync:SenderIsInOurGroup(sender) then return true end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return true end
    local localPool = CurrentOutpostPoolTag()
    if localPool == "" then return false end
    local rp = Overlord.RealmPools
    if not rp or not rp.GetOverlordPoolTag then return false end
    local realm = sender:match("^.-%-(.+)$")
    if not realm or realm == "" then return false end
    local senderPool = NormalizePoolTag(rp:GetOverlordPoolTag(realm))
    if senderPool == "" then return false end
    if Overlord.RealmPools and Overlord.RealmPools.AreOutpostCrossPoolsLinked then
        return Overlord.RealmPools:AreOutpostCrossPoolsLinked(localPool, senderPool)
    end
    return senderPool == localPool
end

local function BuildLeaderboardOutpostTenantPayload(siteKey, guild, faction, claimedTs)
    siteKey = tostring(siteKey or "")
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    local facCode = FactionToCode(faction)
    local pool = CurrentOutpostPoolTag()
    if pool == "" or siteKey == "" or guild == "" or facCode == "" then return nil end
    claimedTs = math.floor(tonumber(claimedTs) or 0)
    if claimedTs <= 0 then return nil end
    local epoch = OverlordDB and tonumber(OverlordDB.lastResetTimestamp) or 0
    if epoch <= 0 or not IsOutpostLeaderboardTimestampCurrent(claimedTs, epoch) then return nil end
    return string.format("%s:%s:%s:%d:%d:%s", siteKey, guild, facCode, claimedTs, epoch, pool)
end

local function OutpostTenantProjectionMatches(siteKey, guild, faction, claimedAt, pool)
    local lb = Overlord.Leaderboard
    if not lb or not lb.GetOutpostTenantsTable then return false end
    local tenants = lb:GetOutpostTenantsTable()
    local current = tenants and tenants[siteKey]
    return type(current) == "table"
        and current.guild == guild
        and current.faction == faction
        and math.floor(tonumber(current.claimedAt) or 0) == claimedAt
        and current.pool == pool
end

-- LOC : compteur de captures d'avant-poste (total additif, fusionne en max chez le receveur).
local function BuildLeaderboardOutpostCountPayload(siteKey, guild, faction, count, latestTs)
    siteKey = tostring(siteKey or "")
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    local facCode = FactionToCode(faction)
    local pool = CurrentOutpostPoolTag()
    if pool == "" or siteKey == "" or guild == "" or facCode == "" then return nil end
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return nil end
    latestTs = math.floor(tonumber(latestTs) or 0)
    if latestTs < 0 then latestTs = 0 end
    local epoch = OverlordDB and tonumber(OverlordDB.lastResetTimestamp) or 0
    if epoch <= 0 then return nil end
    if latestTs > 0 and not IsOutpostLeaderboardTimestampCurrent(latestTs, epoch) then
        latestTs = 0
    end
    -- latestTs = ts de la capture la plus recente incluse dans ce total : permet au receveur de
    -- ne pas re-compter via OC une capture deja contenue dans ce LOC (anti double-comptage).
    return string.format("%s:%s:%s:%d:%d:%d:%s", siteKey, guild, facCode, count, latestTs, epoch, pool)
end

function Overlord.Sync:BuildOutpostPayload(siteKey)
    if not siteKey or not Overlord.Outpost then return nil end
    local st = Overlord.Outpost:GetState(siteKey)
    return BuildOutpostPayload(siteKey, st)
end

function Overlord.Sync:BroadcastOutpostState(siteKey, forceFull, allowInstance)
    if not siteKey or not Overlord.Outpost then return end
    if OutpostSyncBlocked(allowInstance) then return end
    if not forceFull then
        if Overlord.WaitingForSync then return end
        if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    elseif Overlord.WaitingForSync then
        return
    end
    local st = Overlord.Outpost:GetState(siteKey)
    if not st then return end
    if st.status == "held" and (tonumber(st.updatedAt) or 0) <= 0
        and (tonumber(st.claimedAt) or 0) <= 0 then
        return
    end
    local payload = BuildOutpostPayload(siteKey, st)
    if not payload then return end
    BroadcastOutpostToGroup("OP", payload)
    local isCriticalStart = st.status == "in_progress" and (st.holdTimeElapsed or 0) <= 5
    if forceFull or st.status == "held" or st.status == "in_progress" then
        self:SendToChannel("OP", payload, forceFull or st.status == "held" or st.status == "in_progress")
    end
    local now = GetTime()
    local last = lastCommunityOPBroadcast[siteKey] or 0
    local full = forceFull and true or false
    if not full and now - last < OP_COMMUNITY_ROUTINE_INTERVAL then return end
    lastCommunityOPBroadcast[siteKey] = now
    local maxM, delay = GetOcCommunityRelayLimits()
    if full or st.status == "held" or isCriticalStart then
        BroadcastOutpostCaptureToCommunity("OP", payload, maxM, delay, true)
    else
        if Overlord.Sync.BroadcastToCommunity then
            Overlord.Sync:BroadcastToCommunity("OP", payload, 4, 0.4, false)
        end
    end
end

function Overlord.Sync:BroadcastOutpostCapture(siteKey, guild, faction, captureTs)
    if not siteKey or OutpostSyncBlocked() then return end
    local gateBlocked = Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive())
    if gateBlocked then
        local restoreTs = math.floor(tonumber(captureTs) or 0)
        if restoreTs <= 0 then restoreTs = time() end
        local previous = pendingRestoreOc[siteKey]
        if not previous then
            if pendingRestoreOcCount >= PENDING_RESTORE_OC_MAX then
                local oldestKey, oldestAt
                for key, entry in pairs(pendingRestoreOc) do
                    local queuedAt = tonumber(entry and entry.queuedAt) or 0
                    if not oldestAt or queuedAt < oldestAt then
                        oldestKey, oldestAt = key, queuedAt
                    end
                end
                if oldestKey then
                    pendingRestoreOc[oldestKey] = nil
                    pendingRestoreOcCount = math.max(0, pendingRestoreOcCount - 1)
                end
            end
            pendingRestoreOcCount = pendingRestoreOcCount + 1
        end
        if not previous or restoreTs >= (tonumber(previous[4]) or 0) then
            pendingRestoreOc[siteKey] = {
                siteKey, guild, faction, restoreTs, queuedAt = GetTime(),
            }
        end
        ScheduleOcFlushRetry()
    end
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    local facCode = FactionToCode(faction)
    local pool = CurrentOutpostPoolTag()
    if pool == "" then return end
    captureTs = math.floor(tonumber(captureTs) or 0)
    if captureTs <= 0 then captureTs = time() end
    local payload = siteKey .. ":" .. guild .. ":" .. facCode .. ":" .. captureTs .. ":" .. pool
    local maxM, delay = GetOcCommunityRelayLimits()
    local function emitCapture()
        if not Overlord.Sync or Overlord.InstanceSuspended or not payload or payload == "" then return end
        BroadcastOutpostToGroup("OC", payload)
        Overlord.Sync:SendToChannel("OC", payload, true)
        BroadcastOutpostCaptureToCommunity("OC", payload, maxM, delay, true)
        if Overlord.Sync.BroadcastLeaderboardOutpostTenant then
            Overlord.Sync:BroadcastLeaderboardOutpostTenant(siteKey, guild, faction, captureTs)
        end
        -- Propage le total de captures (LOC, fusion max) en plus du OC additif : un retardataire
        -- ou un client cross-faction recupere le vrai compteur, pas seulement +1 / 1.
        if Overlord.Sync.BroadcastLeaderboardOutpostCount and Overlord.Leaderboard
            and Overlord.Leaderboard.GetOutpostCaptureCountRow then
            local row = Overlord.Leaderboard:GetOutpostCaptureCountRow(siteKey, guild, pool)
            local cnt = row and math.floor(tonumber(row.count) or 0) or 0
            local lts = row and math.floor(tonumber(row.lastTs) or 0) or 0
            if cnt > 0 then
                Overlord.Sync:BroadcastLeaderboardOutpostCount(siteKey, guild, faction, cnt, lts)
            end
        end
    end
    emitCapture()
    C_Timer.After(OP_CAPTURE_REPLAY_DELAY_1, emitCapture)
    C_Timer.After(OP_CAPTURE_REPLAY_DELAY_2, emitCapture)
    C_Timer.After(OP_POST_CAPTURE_STATE_DELAY, function()
        if Overlord.Sync and not Overlord.InstanceSuspended and siteKey then
            Overlord.Sync:BroadcastOutpostState(siteKey, true)
        end
    end)
end

function Overlord.Sync:FlushPendingOutpostRestoreBroadcasts()
    if OutpostRestoreOcBlocked()
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()) then
        ScheduleOcFlushRetry()
        return
    end
    local list = pendingRestoreOc
    pendingRestoreOc = {}
    pendingRestoreOcCount = 0
    for _, e in pairs(list) do
        local sk, g, fac, cts = e[1], e[2], e[3], e[4]
        if sk and g and g ~= "" and fac then
            self:BroadcastOutpostCapture(sk, g, fac, cts)
        end
    end
end

function Overlord.Sync:PollIfStaleObserverOutpost(secondsSinceOp)
    local isLarge = IsOpLargeEvent()
    local minInterval = isLarge and STALE_OUTPOST_OBSERVER_POLL_INTERVAL_LARGE or STALE_OUTPOST_OBSERVER_POLL_INTERVAL
    if not secondsSinceOp or secondsSinceOp < minInterval then return end
    local now = GetTime()
    if now - lastStaleOutpostObserverPoll < minInterval then return end
    lastStaleOutpostObserverPoll = now
    local maxM, delay = GetOcCommunityRelayLimits()
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        communityMax = maxM,
        communityDelay = delay,
        criticalChannel = true,
    })
end

local function OutpostWhereLabel(siteKey)
    local OP = Overlord.Outpost
    if not OP then return siteKey or "?" end
    local site = OP.GetSite and OP:GetSite(siteKey)
    return (site and OP.GetDisplayName and OP:GetDisplayName(site)) or siteKey or "?"
end

local function OutpostCapturingFactionLabel(fac)
    local L = Overlord.L
    if fac == "Alliance" then return (L and L.THE_ALLIANCE) or "the Alliance" end
    if fac == "Horde" then return (L and L.THE_HORDE) or "the Horde" end
    return fac or ""
end

local function ResetOutpostAssaultAlert(siteKey)
    if not siteKey then return end
    opAssaultAlertLast[siteKey] = nil
    opAssaultAlertEmitted[siteKey] = nil
    local prefix = siteKey .. ":"
    for k in pairs(opAssaultAlertWaveKey) do
        if k:sub(1, #prefix) == prefix then
            opAssaultAlertWaveKey[k] = nil
        end
    end
end

local function MaybeResetOutpostAssaultAlert(siteKey, stAfter)
    if not siteKey or not stAfter then return end
    if stAfter.status == "in_progress" then return end
    ResetOutpostAssaultAlert(siteKey)
end

local function ResetOutpostDefenderAlert(siteKey)
    if not siteKey then return end
    opDefenderAlertLast[siteKey] = nil
    opDefenderAlertEmitted[siteKey] = nil
    opDefenderAlertHadGuild[siteKey] = nil
    local prefix = siteKey .. ":"
    for k in pairs(opDefenderAlertWaveKey) do
        if k:sub(1, #prefix) == prefix then
            opDefenderAlertWaveKey[k] = nil
        end
    end
end

local function MaybeResetOutpostDefenderAlert(siteKey, stAfter)
    if not siteKey or not stAfter then return end
    local pf = Overlord.PlayerFaction
    local enemyFac = Overlord.Zones and Overlord.Zones.GetEnemyFaction
        and Overlord.Zones:GetEnemyFaction() or nil
    if stAfter.status == "in_progress" and pf and enemyFac and stAfter.ownerFaction == enemyFac then
        return
    end
    ResetOutpostDefenderAlert(siteKey)
end

local function OutpostDefendedGuildFromState(stAfter)
    if not stAfter or not Overlord.Outpost then return "" end
    local OP = Overlord.Outpost
    local prev = OP.SanitizeGuildName and OP:SanitizeGuildName(stAfter.previousOwnerGuild or "")
        or (stAfter.previousOwnerGuild or "")
    if prev ~= "" then return prev end
    return ""
end

-- Une alerte defense ne vaut que pour l'occupation actuellement tenue. Les snapshots
-- in_progress peuvent survivre chez des relais bien apres une capture terminee ; l'UI
-- les masque deja quand ils sont stale, le chat doit appliquer la meme regle.
local function OutpostAssaultTargetsHeldState(siteKey, stBefore, stAfter)
    if not siteKey or not stBefore or not stAfter or not Overlord.Outpost then return false end
    local OP = Overlord.Outpost
    local heldGuild = OP:SanitizeGuildName(stBefore.ownerGuild or "")
    local previousGuild = OP:SanitizeGuildName(stAfter.previousOwnerGuild or "")
    if heldGuild == "" or previousGuild ~= heldGuild then return false end
    if not stBefore.ownerFaction or stAfter.previousOwnerFaction ~= stBefore.ownerFaction then return false end

    local heldClaimedAt = math.floor(tonumber(stBefore.claimedAt) or 0)
    local previousClaimedAt = math.floor(tonumber(stAfter.previousClaimedAt) or 0)
    if heldClaimedAt > 0 and previousClaimedAt ~= heldClaimedAt then return false end

    local site = OP.GetSite and OP:GetSite(siteKey)
    if OP.IsObserverOutpostCaptureStale
        and OP:IsObserverOutpostCaptureStale(stAfter, site, time()) then
        return false
    end
    return true
end

local function TryPrintOutpostDefenderAlert(siteKey, stBefore, stAfter)
    if not siteKey or not stBefore or not stAfter or not Overlord.Outpost then return end
    local OP = Overlord.Outpost
    local L = Overlord.L
    if not L or not L.OUTPOST_DEFENDER_UNDER_ATTACK then return end
    local localGuild = OP.GetLocalPlayerGuild and OP:GetLocalPlayerGuild() or ""
    if localGuild == "" then return end
    local pf = Overlord.PlayerFaction
    if not pf then return end
    local heldGuild = OP.SanitizeGuildName and OP:SanitizeGuildName(stBefore.ownerGuild or "")
        or (stBefore.ownerGuild or "")
    if stBefore.status ~= "held" or heldGuild == "" then return end
    if stBefore.ownerFaction ~= pf then return end
    local isOwnGuild = heldGuild == localGuild
    local rFac = stAfter.ownerFaction
    local rGuild = OP.SanitizeGuildName and OP:SanitizeGuildName(stAfter.ownerGuild or "")
        or (stAfter.ownerGuild or "")
    if stAfter.status ~= "in_progress" then return end
    if not rFac or rFac == pf then return end
    if rGuild ~= "" and rGuild == localGuild then return end
    if not OutpostAssaultTargetsHeldState(siteKey, stBefore, stAfter) then return end
    local localOnlyAlert = stAfter._localOnlyAlert and true or false

    local remoteTs = tonumber(stAfter.updatedAt) or 0
    local waveKey = siteKey .. ":" .. tostring(remoteTs)
    if remoteTs > 0 and opDefenderAlertWaveKey[waveKey] then return end
    local nowAlert = GetTime()
    local enrichGenericAlert = opDefenderAlertEmitted[siteKey]
        and rGuild ~= "" and not opDefenderAlertHadGuild[siteKey]
    if opDefenderAlertEmitted[siteKey] and not enrichGenericAlert then return end
    local lastAlert = opDefenderAlertLast[siteKey] or 0
    if not enrichGenericAlert and nowAlert - lastAlert < OP_DEFENDER_ALERT_COOLDOWN then return end

    opDefenderAlertLast[siteKey] = nowAlert
    if localOnlyAlert then
        if opDefenderAlertEmitted[siteKey] then
            opDefenderAlertHadGuild[siteKey] = rGuild ~= ""
        end
    else
        opDefenderAlertEmitted[siteKey] = true
        opDefenderAlertHadGuild[siteKey] = rGuild ~= ""
    end
    if remoteTs > 0 then
        opDefenderAlertWaveKey[waveKey] = nowAlert
    end

    local whereLabel = OutpostWhereLabel(siteKey)
    local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
        and Overlord.Zones:GetEnemyFactionName() or rFac
    if not isOwnGuild then
        if L.OUTPOST_ALLIED_UNDER_ATTACK then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_ALLIED_UNDER_ATTACK,
                whereLabel, heldGuild, facLabel))
        end
    elseif rGuild ~= "" and L.OUTPOST_DEFENDER_UNDER_ATTACK_BY then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_DEFENDER_UNDER_ATTACK_BY,
            whereLabel, rGuild, facLabel))
    else
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_DEFENDER_UNDER_ATTACK,
            whereLabel, facLabel))
    end
end

local function TryPrintOutpostAssaultAlert(siteKey, stBefore, stAfter)
    if not siteKey or not stAfter or not Overlord.Outpost then return end
    local L = Overlord.L
    if not L then return end
    if stAfter.status ~= "in_progress" then return end
    local OP = Overlord.Outpost
    if stBefore and stBefore.status == "in_progress" then
        local beforeGuild = OP.SanitizeGuildName and OP:SanitizeGuildName(stBefore.ownerGuild or "")
            or (stBefore.ownerGuild or "")
        local afterGuild = OP.SanitizeGuildName and OP:SanitizeGuildName(stAfter.ownerGuild or "")
            or (stAfter.ownerGuild or "")
        if beforeGuild == afterGuild and stBefore.ownerFaction == stAfter.ownerFaction then
            return
        end
        ResetOutpostAssaultAlert(siteKey)
    end
    local assaultFac = stAfter.ownerFaction
    local assaultGuild = OP.SanitizeGuildName and OP:SanitizeGuildName(stAfter.ownerGuild or "")
        or (stAfter.ownerGuild or "")
    if not assaultFac or assaultGuild == "" then return end
    local localGuild = OP.GetLocalPlayerGuild and OP:GetLocalPlayerGuild() or ""
    if localGuild ~= "" and localGuild == assaultGuild and stAfter.holdAuthorityLocal then
        return
    end
    local defendedGuild = OutpostDefendedGuildFromState(stAfter)
    if defendedGuild == assaultGuild then
        defendedGuild = ""
    end
    if localGuild ~= "" and defendedGuild ~= "" and localGuild == defendedGuild then
        return
    end

    local remoteTs = tonumber(stAfter.updatedAt) or 0
    local waveKey = siteKey .. ":" .. tostring(remoteTs)
    if remoteTs > 0 and opAssaultAlertWaveKey[waveKey] then return end
    local nowAlert = GetTime()
    if opAssaultAlertEmitted[siteKey] then return end
    local lastAlert = opAssaultAlertLast[siteKey] or 0
    if nowAlert - lastAlert < OP_ASSAULT_ALERT_COOLDOWN then return end

    opAssaultAlertLast[siteKey] = nowAlert
    opAssaultAlertEmitted[siteKey] = true
    if remoteTs > 0 then
        opAssaultAlertWaveKey[waveKey] = nowAlert
    end

    local whereLabel = OutpostWhereLabel(siteKey)
    local pf = Overlord.PlayerFaction
    if pf and assaultFac == pf then
        if defendedGuild ~= "" and L.OUTPOST_ALLY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.OUTPOST_ALLY_ASSAULT_VS,
                whereLabel, assaultGuild, defendedGuild))
        elseif L.OUTPOST_ALLY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.OUTPOST_ALLY_ASSAULT,
                whereLabel, assaultGuild))
        end
    else
        local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
            and Overlord.Zones:GetEnemyFactionName() or assaultFac
        if defendedGuild ~= "" and L.OUTPOST_ENEMY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_ENEMY_ASSAULT_VS,
                whereLabel, assaultGuild, defendedGuild, facLabel))
        elseif L.OUTPOST_ENEMY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_ENEMY_ASSAULT,
                whereLabel, assaultGuild, facLabel))
        end
    end
end

function Overlord.Sync:PrintOutpostCaptureAlert(siteKey, guild, faction, captureTs)
    if not siteKey or not faction or not Overlord.Outpost then return end
    if Overlord.WaitingForSync then return end
    local L = Overlord.L
    if not L then return end
    local OP = Overlord.Outpost
    guild = OP.SanitizeGuildName and OP:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return end
    captureTs = tonumber(captureTs) or 0
    local dedupKey = string.format("%s:%s:%s:%d", siteKey, guild, faction, captureTs)
    local now = GetTime()
    if opCaptureAlertDedup[dedupKey] and (now - opCaptureAlertDedup[dedupKey]) < OP_CAPTURE_ALERT_DEDUP_SEC then
        return
    end
    opCaptureAlertDedup[dedupKey] = now
    for k, t in pairs(opCaptureAlertDedup) do
        if now - t > OP_CAPTURE_ALERT_DEDUP_SEC then opCaptureAlertDedup[k] = nil end
    end

    local whereLabel = OutpostWhereLabel(siteKey)
    local pf = Overlord.PlayerFaction
    if pf and faction == pf then
        if L.OUTPOST_CAPTURE_ALERT_FRIENDLY then
            Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.OUTPOST_CAPTURE_ALERT_FRIENDLY,
                whereLabel, guild))
        end
    elseif L.OUTPOST_CAPTURE_ALERT_ENEMY then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_CAPTURE_ALERT_ENEMY,
            whereLabel, guild, OutpostCapturingFactionLabel(faction)))
    end
    local localGuild = OP.GetLocalPlayerGuild and OP:GetLocalPlayerGuild() or ""
    if localGuild ~= "" and localGuild == guild and pf and faction == pf
        and Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("welcome_popup")
    elseif OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
    end
end

function Overlord.Sync:OnReceiveOutpostState(payload, sender, channel)
    if not payload or payload == "" or not Overlord.Outpost then return end
    if OutpostSyncBlocked() then return end

    local version, versionedPayload = payload:match("^(v%d+):(.*)$")
    if version and version ~= "v1" then return end
    local parsePayload = versionedPayload or payload
    local siteKey, status, holdStr, guild, facCode, caStr, exStr, tsStr, holdReqStr,
        poolStr, contestedStr, prevGuild, prevFacCode, prevCaStr, prevExStr, capturerName
        = strsplit(":", parsePayload, 16)
    local remoteFac = FactionCodeToFaction(facCode)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return end
    if status and not VALID_OP_STATUS[status] then return end
    if facCode and facCode ~= "" and not remoteFac then return end
    local remotePool = OutpostPayloadPoolAcceptable(poolStr, sender, channel)
    if not remotePool then return end
    local ownerSourceVerified = OcSenderMatchesPayloadGuild(sender or "", guild or "", remoteFac)
    if not ownerSourceVerified and not self:IsGuildKeepSenderTrusted(sender or "", remoteFac, channel, "OP", status) then
        return
    end
    local hadTs = tsStr and tsStr ~= ""
    local remoteTs = NormalizeRemoteTimestamp(tsStr)
    if hadTs and not remoteTs then return end
    if not remoteTs then remoteTs = 0 end
    if IsStaleCampaignTimestamp(remoteTs) then return end
    local communitySource = self.IsGuildKeepCommunitySender
        and self:IsGuildKeepCommunitySender(sender or "") or false
    if communitySource and not ownerSourceVerified and remoteTs <= 0 then
        return
    end
    if status == "held" then
        local heldCaptureTs = math.floor(tonumber(caStr) or 0)
        if heldCaptureTs <= 0 then heldCaptureTs = remoteTs end
        if heldCaptureTs <= 0 or heldCaptureTs > time() + MAX_CLOCK_SKEW
            or IsStaleCampaignTimestamp(heldCaptureTs) then
            return
        end
    end

    -- Ne memoriser qu'une livraison ayant passe le pool, la confiance et les
    -- timestamps. Sinon un whisper DE refuse peut masquer pendant 8 s sa copie
    -- PARTY identique, pourtant autorisee par le groupe reel.
    local nowD = GetTime()
    local deliveryKey = tostring(sender or "") .. ":" .. payload
    PruneOpDedup(nowD)
    if not AdmitOutpostDedup(opDedup, deliveryKey, nowD) then return end

    local stBefore = SnapshotOutpostTransitionState(
        siteKey, Overlord.Outpost:GetState(siteKey))
    local remote = {
        status = status,
        holdTimeElapsed = tonumber(holdStr) or 0,
        ownerGuild = guild or "",
        ownerFaction = remoteFac,
        claimedAt = tonumber(caStr) or 0,
        expiresAt = tonumber(exStr) or 0,
        updatedAt = remoteTs,
        holdTimeRequired = tonumber(holdReqStr) or nil,
        isContested = (contestedStr == "1"),
        previousOwnerGuild = prevGuild or "",
        previousOwnerFaction = FactionCodeToFaction(prevFacCode),
        previousClaimedAt = tonumber(prevCaStr) or 0,
        previousExpiresAt = tonumber(prevExStr) or 0,
        pool = remotePool,
        opRelayCapturerName = NormalizeOpCapturerName(capturerName),
    }
    local relayCapturer = remote.opRelayCapturerName or ""
    local objective = Overlord.OutpostSites[siteKey]
    if status == "in_progress" and objective and objective.id and relayCapturer ~= ""
        and ownerSourceVerified and self.RecordCaptureCreditProgressEvidence then
        self:RecordCaptureCreditProgressEvidence(
            sender, relayCapturer, objective.id, remoteFac, remote.holdTimeElapsed)
    end
    if relayCapturer ~= "" and Overlord.Shard and Overlord.Shard.ResolveKnownShardPlayer then
        local _, sid = Overlord.Shard:ResolveKnownShardPlayer(relayCapturer, true)
        if sid then remote.opRelayCapturerShard = sid end
    end
    if not remote.opRelayCapturerShard and sender and sender ~= ""
        and Overlord.Shard and Overlord.Shard.GetKnownPlayerShard then
        local sid = Overlord.Shard:GetKnownPlayerShard(sender)
        if sid and (relayCapturer == "" or ownerSourceVerified) then
            remote.opRelayCapturerShard = sid
        end
    end
    Overlord.Outpost:ApplyRemoteState(siteKey, remote, true)
    local stAfter = Overlord.Outpost:GetState(siteKey)
    if (status == "in_progress" or status == "held")
        and Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(
            siteKey, relayCapturer ~= "" and relayCapturer or sender,
            remoteTs > 0 and remoteTs or nil)
    end
    if status == "held" and stAfter and stAfter.status == "held"
        and Overlord.Leaderboard and Overlord.Leaderboard.ApplyOutpostTenantSync then
        local payloadGuild = Overlord.Outpost:SanitizeGuildName(guild or "")
        local heldGuild = Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "")
        local heldPool = NormalizePoolTag(stAfter.pool)
        local heldTs = math.floor(tonumber(stAfter.claimedAt) or tonumber(remote.claimedAt) or remoteTs or 0)
        if payloadGuild ~= "" and heldGuild == payloadGuild
            and stAfter.ownerFaction == remoteFac and heldPool ~= "" and heldTs > 0 then
            -- OP est repetable : il peut reparer le registre monotone du tenant sans
            -- jamais crediter une capture. Toujours projeter le pool canonique post-merge :
            -- un paquet stale accepte par le transport ne doit pas retagger un etat plus recent.
            local tenantChanged = false
            if not OutpostTenantProjectionMatches(
                siteKey, heldGuild, remoteFac, heldTs, heldPool) then
                tenantChanged = Overlord.Leaderboard:ApplyOutpostTenantSync(
                    siteKey, heldGuild, remoteFac, heldTs, heldPool) == true
            end
            -- Un etat canonique held prouve au moins une prise pendant la campagne.
            -- Poser un plancher LOC(1), jamais un +1 : les heartbeats OP repetes restent
            -- idempotents et un total LOC plus riche (3, 4...) ne peut pas etre gonfle.
            local countChanged = false
            local countRow = Overlord.Leaderboard.GetOutpostCaptureCountRow
                and Overlord.Leaderboard:GetOutpostCaptureCountRow(
                    siteKey, heldGuild, heldPool) or nil
            if (not countRow or math.floor(tonumber(countRow.count) or 0) <= 0)
                and Overlord.Leaderboard.ApplyOutpostCaptureCountSync then
                countChanged = Overlord.Leaderboard:ApplyOutpostCaptureCountSync(
                    siteKey, heldGuild, remoteFac, 1, heldTs, heldPool) == true
            end
            local stateChanged = stBefore
                and (stBefore.status ~= "held"
                    or Overlord.Outpost:SanitizeGuildName(stBefore.ownerGuild or "") ~= heldGuild
                    or stBefore.ownerFaction ~= remoteFac)
            if tenantChanged or countChanged or stateChanged then
                if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
                    Overlord.LeaderboardUI:RefreshIfVisible()
                end
            end
        end
    end
    -- Alertes chat depuis la sync OP (assaut, defense, capture terminee).
    if status == "held" and stAfter and stAfter.status == "held" then
        local payloadGuild = Overlord.Outpost:SanitizeGuildName(guild or "")
        local heldGuild = Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "")
        local heldTs = math.floor(tonumber(stAfter.claimedAt) or tonumber(remote.claimedAt) or remoteTs or 0)
        if payloadGuild ~= "" and heldGuild == payloadGuild
            and stAfter.ownerFaction == remoteFac and heldTs > 0 then
            local stateChanged = stBefore
                and (stBefore.status ~= "held"
                    or Overlord.Outpost:SanitizeGuildName(stBefore.ownerGuild or "") ~= heldGuild
                    or stBefore.ownerFaction ~= remoteFac)
            if stateChanged and stBefore and stBefore.status == "in_progress"
                and (time() - heldTs) <= 90
                and self.PrintOutpostCaptureAlert then
                self:PrintOutpostCaptureAlert(siteKey, heldGuild, remoteFac, heldTs)
            end
        end
    end
    local defenderAlertState = stAfter
    if status == "in_progress" and stBefore and stBefore.status == "held"
        and stAfter and stAfter.status ~= "in_progress" then
        defenderAlertState = {
            status = "in_progress",
            ownerGuild = guild or "",
            ownerFaction = remoteFac,
            holdTimeElapsed = remote.holdTimeElapsed,
            holdTimeRequired = remote.holdTimeRequired,
            previousOwnerGuild = remote.previousOwnerGuild,
            previousOwnerFaction = remote.previousOwnerFaction,
            previousClaimedAt = remote.previousClaimedAt,
            updatedAt = remoteTs,
            _localOnlyAlert = true,
        }
    end
    TryPrintOutpostDefenderAlert(siteKey, stBefore, defenderAlertState)
    TryPrintOutpostAssaultAlert(siteKey, stBefore, stAfter)
    if not (defenderAlertState and defenderAlertState._localOnlyAlert) then
        MaybeResetOutpostDefenderAlert(siteKey, stAfter)
    end
    MaybeResetOutpostAssaultAlert(siteKey, stAfter)
    if (channel == "WHISPER" or (channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload and payload ~= ""
        and OutpostPayloadHasExplicitLinkedPool(remotePool) then
        if status == "in_progress" then
            local payloadGuild = Overlord.Outpost:SanitizeGuildName(guild or "")
            local adoptedProgress = stAfter and stAfter.status == "in_progress"
                and payloadGuild ~= ""
                and Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "") == payloadGuild
                and stAfter.ownerFaction == remoteFac
            if not adoptedProgress then return end
            local transitioned = stBefore and stBefore.status ~= "in_progress"
                and stAfter and stAfter.status == "in_progress"
            local adoptedTick = stBefore and stAfter
                and stBefore.status == "in_progress" and stAfter.status == "in_progress"
                and (math.floor(tonumber(stAfter.holdTimeElapsed) or 0) ~= (stBefore.holdTimeElapsed or 0)
                    or (stAfter.isContested and true or false) ~= (stBefore.isContested and true or false)
                    or (tonumber(stAfter.updatedAt) or 0) ~= (tonumber(stBefore.updatedAt) or 0))
            if not transitioned and not adoptedTick then return end
            BroadcastOutpostToGroup("OP", payload)
            self:SendToChannel("OP", payload, true)
        elseif status == "held" and stAfter and stAfter.status == "held" then
            local payloadGuild = Overlord.Outpost:SanitizeGuildName(guild or "")
            local adoptedTenantChange = payloadGuild ~= ""
                and Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "") == payloadGuild
                and stAfter.ownerFaction == remoteFac
                and stBefore
                and (stBefore.status ~= "held"
                    or Overlord.Outpost:SanitizeGuildName(stBefore.ownerGuild or "") ~= payloadGuild
                    or stBefore.ownerFaction ~= remoteFac)
            if adoptedTenantChange then
                BroadcastOutpostToGroup("OP", payload)
                self:SendToChannel("OP", payload, true)
            end
        end
    end
end

function Overlord.Sync:OnReceiveOutpostCapture(payload, sender, sourceChannel)
    if not payload or not Overlord.Outpost or OutpostSyncBlocked() then return end
    local siteKey, guild, facCode, tsStr, remotePool = strsplit(":", payload, 5)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return end
    local hadTs = tsStr and tsStr ~= ""
    local remoteTs = NormalizeRemoteTimestamp(tsStr)
    if hadTs and not remoteTs then return end
    if not remoteTs or remoteTs <= 0 then remoteTs = time() end
    if IsStaleCampaignTimestamp(remoteTs) then return end
    guild = Overlord.Outpost:SanitizeGuildName(guild or "")
    local ownerSourceVerified = OcSenderMatchesPayloadGuild(sender or "", guild, fac)
    -- OC est un evenement one-shot : seul le membre de la guilde gagnante qui
    -- emet directement peut l'appliquer. Attendre trois recepteurs ou une preuve
    -- murale locale faisait rater la capture et le classement aux late joiners.
    if not ownerSourceVerified then return end
    local captureAccepted = ShouldAcceptOutpostCapture(
        siteKey, guild, fac, remoteTs, sender, sourceChannel)
    if not captureAccepted then return end
    local dedupKey = string.format("%s:%s:%s:%d:%s",
        siteKey, guild, facCode or "", remoteTs, remotePool)
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(ocDedup, dedupKey, now) then return end
    if Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(siteKey, sender, remoteTs)
    end
    local leaderboardChanged = false
    if Overlord.Leaderboard and Overlord.Leaderboard.RecordOutpostCapture then
        leaderboardChanged = Overlord.Leaderboard:RecordOutpostCapture(
            siteKey, guild, fac, remoteTs, remotePool) == true
    end
    local objective = Overlord.OutpostSites[siteKey]
    local capturer = NormalizeOpCapturerName(sender)
    if objective and objective.id and capturer ~= "" and self.CanCreditDirectCapture
        and self:CanCreditDirectCapture(sender, capturer, objective.id, fac)
        and Overlord.Leaderboard and Overlord.Leaderboard.CreditPlayerObjectiveCapture then
        local classToken = self.ResolveContributorClassToken
            and self:ResolveContributorClassToken(capturer) or nil
        Overlord.Leaderboard:CreditPlayerObjectiveCapture(
            capturer, objective.id, fac, remoteTs, true, classToken)
    end
    local stEarly = Overlord.Outpost:GetState(siteKey)
    if stEarly and stEarly.status == "held" then
        local heldGuild = Overlord.Outpost:SanitizeGuildName(stEarly.ownerGuild or "")
        local heldPool = NormalizePoolTag(stEarly.pool)
        if heldGuild ~= "" and heldGuild == guild and stEarly.ownerFaction == fac
            and heldPool == remotePool then
            if leaderboardChanged and Overlord.LeaderboardUI
                and Overlord.LeaderboardUI.RefreshIfVisible then
                Overlord.LeaderboardUI:RefreshIfVisible()
            end
            return
        end
    end

    if not Overlord.Outpost:CompleteCapture(siteKey, guild, fac, remoteTs, remotePool, true) then return end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    -- Si la verite arrive par communaute, la republier sur les chemins primaires locaux.
    -- Pas de re-fanout communaute ici : le relais large est 1-hop pour eviter l'explosion.
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload ~= "" and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        BroadcastOutpostToGroup("OC", payload)
        self:SendToChannel("OC", payload, true)
    end
    -- OC recu en raid/party (souvent Warmode mixte) : republier sur le canal meme faction
    -- pour les guildes qui ne sont pas dans le groupe du capteur.
    if (sourceChannel == "RAID" or sourceChannel == "PARTY") and payload ~= ""
        and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        self:SendToChannel("OC", payload, true)
    end
    -- Relais 1-hop seulement si le payload porte explicitement notre pool.
    if (sourceChannel ~= "WHISPER" and sourceChannel ~= "BETA") and payload ~= "" and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        local relayPl, relayKey = payload, dedupKey
        C_Timer.After(0.5, function()
            if Overlord.Sync and Overlord.Sync.RelayOutpostCaptureToCommunitySafe then
                Overlord.Sync:RelayOutpostCaptureToCommunitySafe(relayPl, relayKey, remotePool)
            end
        end)
    end
end

-- Il existe sept sites : une SR territoriale doit pouvoir transporter
-- les sept etats simultanes, y compris neutral. Sans le terminal neutre, un client
-- hors ligne pendant un abandon conserverait indefiniment son ancien assaut.
local SR_MINIMAL_OP_SITE_MAX = 7

function Overlord.Sync:AppendOutpostToSrQueue(queue, minimalResponseOnly)
    if not queue or not Overlord.Outpost or not Overlord.OutpostSites then return end
    if minimalResponseOnly then
        local added = 0
        for siteKey in pairs(Overlord.OutpostSites) do
            if added >= SR_MINIMAL_OP_SITE_MAX then break end
            local st = Overlord.Outpost:GetState(siteKey)
            if st and st.status == "in_progress" then
                local opData = self.BuildOutpostPayload and self:BuildOutpostPayload(siteKey)
                if opData then
                    table.insert(queue, { type = "OP", data = opData })
                    added = added + 1
                end
            end
        end
        for siteKey in pairs(Overlord.OutpostSites) do
            if added >= SR_MINIMAL_OP_SITE_MAX * 2 then break end
            local st = Overlord.Outpost:GetState(siteKey)
            if st and st.status == "held" and (st.ownerGuild or "") ~= "" then
                local opData = self.BuildOutpostPayload and self:BuildOutpostPayload(siteKey)
                if opData then
                    table.insert(queue, { type = "OP", data = opData })
                    added = added + 1
                end
            end
        end
        for siteKey in pairs(Overlord.OutpostSites) do
            if added >= SR_MINIMAL_OP_SITE_MAX * 3 then break end
            local st = Overlord.Outpost:GetState(siteKey)
            if st and st.status == "neutral" then
                local opData = self.BuildOutpostPayload and self:BuildOutpostPayload(siteKey)
                if opData then
                    table.insert(queue, { type = "OP", data = opData })
                    added = added + 1
                end
            end
        end
        return
    end
    for siteKey in pairs(Overlord.OutpostSites) do
        local opData = self.BuildOutpostPayload and self:BuildOutpostPayload(siteKey)
        if opData then
            table.insert(queue, { type = "OP", data = opData })
        end
    end
end

function Overlord.Sync:AppendLeaderboardOutpostToSrQueue(queue)
    if not queue or not Overlord.Leaderboard or not Overlord.Leaderboard.BuildOutpostTenantSyncRows then
        return
    end
    local rows = Overlord.Leaderboard:BuildOutpostTenantSyncRows()
    for _, row in ipairs(rows) do
        local facCode = FactionToCode(row.faction)
        local rowPool = NormalizePoolTag(row.pool)
        if facCode ~= "" and row.siteKey and row.guild and row.guild ~= "" and rowPool ~= "" then
            local payload = string.format("%s:%s:%s:%d:%d:%s",
                row.siteKey, row.guild, facCode, row.claimedAt or 0, row.epoch or 0, rowPool)
            table.insert(queue, { type = "LO", data = payload })
        end
    end
end

-- LOC en SR : compteur total de captures par (avant-poste, guilde), fusionne en max.
-- Il n'existe que 7 sites d'avant-poste ; le nombre de couples (site, guilde) avec captures est
-- donc petit en pratique. La borne sert seulement de garde-fou anti-bloat : on la garde large
-- pour qu'un retardataire recoive TOUS les couples au login (convergence > rattrapage tardif),
-- la troncature ne devant jamais frapper un campagne reelle. Tri par count desc (essentiel d'abord).
local SR_OUTPOST_COUNT_MAX = 64
local SR_OUTPOST_ROW_BUCKETS = 256
local SR_OUTPOST_ROW_BUCKETS_PER_REQUEST = 16
function Overlord.Sync:AppendLeaderboardOutpostCountToSrQueue(
    queue, evidencePageNonce, hasEvidencePage)
    if not queue or not Overlord.Leaderboard or not Overlord.Leaderboard.BuildOutpostCaptureCountSyncRows then
        return
    end
    local rows, blocks, subPages = Overlord.Leaderboard:BuildOutpostCaptureCountSyncRows()
    local emitted = 0
    evidencePageNonce = math.floor(tonumber(evidencePageNonce) or 0)
    local rowBlockCount = SR_OUTPOST_ROW_BUCKETS / SR_OUTPOST_ROW_BUCKETS_PER_REQUEST
    local rowBlock = evidencePageNonce % rowBlockCount
    local emittedKeys = {}
    local function rowStableKey(row)
        return table.concat({ row.siteKey or "", (row.guild or ""):lower(),
            NormalizePoolTag(row.pool) }, ":")
    end
    local function appendRow(row)
        if not row or emitted >= SR_OUTPOST_COUNT_MAX then return false end
        local facCode = FactionToCode(row.faction)
        local rowPool = NormalizePoolTag(row.pool)
        if facCode ~= "" and row.siteKey and row.guild and row.guild ~= ""
            and (row.count or 0) > 0 and rowPool ~= "" then
            local payload = string.format("%s:%s:%s:%d:%d:%d:%s",
                row.siteKey, row.guild, facCode, row.count or 0, row.lastTs or 0, row.epoch or 0, rowPool)
            table.insert(queue, { type = "LOC", data = payload })
            emittedKeys[rowStableKey(row)] = true
            emitted = emitted + 1
            return true
        end
        return false
    end
    local fixed = math.min(#rows, 16, SR_OUTPOST_COUNT_MAX)
    for i = 1, fixed do appendRow(rows[i]) end
    if #rows > fixed and emitted < SR_OUTPOST_COUNT_MAX then
        if not hasEvidencePage then
            local pool = #rows - fixed
            local start = (srLegacyOutpostCountCursor % pool) + 1
            local sent = 0
            for attempt = 1, pool do
                if emitted >= SR_OUTPOST_COUNT_MAX then break end
                local idx = fixed + ((start + attempt - 2) % pool) + 1
                if appendRow(rows[idx]) then sent = sent + 1 end
            end
            if sent > 0 then srLegacyOutpostCountCursor = (srLegacyOutpostCountCursor + sent) % pool end
            return
        end
        local blockRows = type(blocks) == "table" and blocks[rowBlock + 1] or nil
        local candidates = type(blockRows) == "table" and blockRows or {}
        if #candidates > (SR_OUTPOST_COUNT_MAX - emitted) then
            -- Sous-page stable seulement en historique anormalement large. Le hash secondaire
            -- est independant du contenu local, donc deux repondeurs choisissent les memes rows.
            local subPage = math.floor(evidencePageNonce / rowBlockCount) % 16
            local blockPages = type(subPages) == "table" and subPages[rowBlock + 1] or nil
            candidates = type(blockPages) == "table" and blockPages[subPage + 1] or {}
        end
        for _, row in ipairs(candidates) do
            if emitted >= SR_OUTPOST_COUNT_MAX then break end
            appendRow(row)
        end
    end
end

function Overlord.Sync:BroadcastHeldOutpostStates()
    if not Overlord.Outpost or not Overlord.OutpostSites then return end
    if OutpostSyncBlocked() or Overlord.WaitingForSync then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    for siteKey in pairs(Overlord.OutpostSites) do
        local st = Overlord.Outpost:GetState(siteKey)
        if st and st.status == "held" and (st.ownerGuild or "") ~= "" then
            self:BroadcastOutpostState(siteKey, false)
        end
    end
end

function Overlord.Sync:BroadcastLeaderboardOutpostTenant(siteKey, guild, faction, claimedTs)
    if not siteKey or OutpostSyncBlocked() then return end
    local payload = BuildLeaderboardOutpostTenantPayload(siteKey, guild, faction, claimedTs)
    if not payload then return end
    local sendKey = payload
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(loSendDedup, sendKey, now) then return end
    local maxM, delay = GetOcCommunityRelayLimits()
    local function emitTenant()
        if not Overlord.Sync or Overlord.InstanceSuspended or not payload or payload == "" then return end
        BroadcastOutpostToGroup("LO", payload)
        Overlord.Sync:SendToChannel("LO", payload, true)
        BroadcastOutpostCaptureToCommunity("LO", payload, maxM, delay, true)
    end
    emitTenant()
    C_Timer.After(OP_CAPTURE_REPLAY_DELAY_1, emitTenant)
end

function Overlord.Sync:OnReceiveLeaderboardOutpostTenant(payload, sender, sourceChannel)
    if not payload or not Overlord.Leaderboard or OutpostSyncBlocked() then return end
    local siteKey, guild, facCode, claimedStr, epochStr, remotePool = strsplit(":", payload, 6)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    local claimedAt = NormalizeRemoteTimestamp(claimedStr)
    if not claimedAt or claimedAt <= 0 then return end
    if not IsOutpostLeaderboardTimestampCurrent(claimedAt, remoteEpoch) then return end
    guild = Overlord.Outpost and Overlord.Outpost.SanitizeGuildName
        and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return end
    if not SenderRealmMatchesCurrentOutpostPool(sender or "", sourceChannel) then return end
    if not self:IsGuildKeepSenderTrusted(sender or "", fac, sourceChannel, "LO") then return end
    local dedupKey = string.format("%s:%s:%s:%d:%s",
        siteKey, guild, facCode or "", claimedAt, remotePool)
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(loDedup, dedupKey, now) then return end

    local tenantChanged = Overlord.Leaderboard:ApplyOutpostTenantSync(
        siteKey, guild, fac, claimedAt, remotePool) == true
    local countChanged = false
    if Overlord.Leaderboard.EnsureOutpostCaptureCounted then
        -- Le credit fallback du LO valide est independant du tenant courant : un LO ancien
        -- recu apres un LO recent doit encore compter sa propre capture.
        countChanged = Overlord.Leaderboard:EnsureOutpostCaptureCounted(
            siteKey, guild, fac, claimedAt, remotePool) == true
    end
    if not tenantChanged and not countChanged then return end
    if Overlord.Outpost and Overlord.Outpost.RefreshOutpostPresentation then
        Overlord.Outpost:RefreshOutpostPresentation(siteKey)
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload ~= "" and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        BroadcastOutpostToGroup("LO", payload)
        self:SendToChannel("LO", payload, true)
    end
    if (sourceChannel == "RAID" or sourceChannel == "PARTY") and payload ~= ""
        and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        self:SendToChannel("LO", payload, true)
    end
end

function Overlord.Sync:BroadcastLeaderboardOutpostCount(siteKey, guild, faction, count, latestTs)
    if not siteKey or OutpostSyncBlocked() then return end
    local payload = BuildLeaderboardOutpostCountPayload(siteKey, guild, faction, count, latestTs)
    if not payload then return end
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(locSendDedup, payload, now) then return end
    local maxM, delay = GetOcCommunityRelayLimits()
    BroadcastOutpostToGroup("LOC", payload)
    self:SendToChannel("LOC", payload, true)
    BroadcastOutpostCaptureToCommunity("LOC", payload, maxM, delay, true)
end

function Overlord.Sync:OnReceiveLeaderboardOutpostCount(payload, sender, sourceChannel)
    if not payload or not Overlord.Leaderboard or OutpostSyncBlocked() then return end
    if not Overlord.Leaderboard.ApplyOutpostCaptureCountSync then return end
    local siteKey, guild, facCode, countStr, latestTsStr, epochStr, remotePool = strsplit(":", payload, 7)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    local count = math.floor(tonumber(countStr) or 0)
    if count <= 0 then return end
    -- Borne anti-poison sur latestTs : un ts absurde dans le futur ferait monter row.lastTs trop
    -- haut et BLOQUERAIT les futurs +1 (RecordOutpostCapture n'incremente que si ts > lastTs).
    -- On le passe par la meme normalisation que les autres ts (rejet futur lointain, clamp now).
    local latestTs = NormalizeRemoteTimestamp(latestTsStr) or 0
    if latestTs > 0 and not IsOutpostLeaderboardTimestampCurrent(
        latestTs, remoteEpoch) then latestTs = 0 end
    guild = Overlord.Outpost and Overlord.Outpost.SanitizeGuildName
        and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return end
    if not SenderRealmMatchesCurrentOutpostPool(sender or "", sourceChannel) then return end
    if not self:IsGuildKeepSenderTrusted(sender or "", fac, sourceChannel, "LOC") then return end
    local dedupKey = string.format("%s:%s:%s:%d:%d:%s",
        siteKey, guild, facCode or "", count, latestTs, remotePool)
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(locDedup, dedupKey, now) then return end

    if not Overlord.Leaderboard:ApplyOutpostCaptureCountSync(siteKey, guild, fac, count, latestTs, remotePool) then
        return
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    local relayPayload = string.format("%s:%s:%s:%d:%d:%d:%s",
        siteKey, guild, facCode or "", count, latestTs, remoteEpoch, remotePool)
    -- Relais 1-hop comme LO : republier si le pool appartient au groupe Outpost local.
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload ~= "" and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        BroadcastOutpostToGroup("LOC", relayPayload)
        self:SendToChannel("LOC", relayPayload, true)
    end
    if (sourceChannel == "RAID" or sourceChannel == "PARTY") and payload ~= ""
        and OutpostPayloadHasExplicitLinkedPool(wirePool) then
        self:SendToChannel("LOC", relayPayload, true)
    end
end

-- OE intermediaire (pre-v5) : ignore volontairement, voir commentaire du handler.
function Overlord.Sync:OnReceiveLeaderboardOutpostEvidence(payload, sender, sourceChannel)
    -- v5 : les preuves brutes ne sont plus une surface reseau. LOC transporte le total
    -- valide et son ancre temporelle, suffisants pour la convergence semantique du ladder.
    -- Garder le handler no-op evite une erreur avec un client intermediaire ayant connu OE.
    return
end
