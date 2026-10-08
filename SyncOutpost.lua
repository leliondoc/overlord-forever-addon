-- SyncOutpost.lua - Protocoles OP / OC pour avant-postes
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local OP_POST_CAPTURE_STATE_DELAY = 4.0
local OP_CAPTURE_REPLAY_DELAY_1 = 1.0
local OP_CAPTURE_REPLAY_DELAY_2 = 3.0
local lastOPRelayBroadcast = {}
local OP_ROUTINE_RELAY_INTERVAL = 12
local VALID_OP_STATUS = { neutral = true, in_progress = true, held = true }
local MAX_CLOCK_SKEW = 300
local OC_DEDUP_SEC = 10
local OP_DEDUP_SEC = 4
local OP_DEDUP_MAX = 128
local OC_DEDUP_MAX = 256
local lastStaleOutpostObserverPoll = 0
local staleOutpostPullRound = 0
local STALE_OUTPOST_OBSERVER_POLL_INTERVAL = 22
local STALE_OUTPOST_OBSERVER_POLL_INTERVAL_LARGE = 45
local opCaptureAlertDedup = {}
local OP_CAPTURE_ALERT_DEDUP_SEC = 12
-- One assault alert per site per 5 min (2026-10-01: two guilds alternating on the
-- same site re-alerted on every flip). A guild change or a state leaving
-- in_progress re-arms the alert but never resets this cooldown.
local OP_ASSAULT_ALERT_COOLDOWN = 300
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

-- 1.7.2: a keep/outpost capture is a claim signed by the character who made it
-- (site, guild, faction, time, capturer). Live, only that character, as the sender
-- WoW authenticates, can state it: a copy carried by a relay, a bridge or a group
-- mate is refused. A reply we asked for (targeted map pull, outpost history) may
-- carry claims we did not witness, judged by content only: a ranked capturer whose
-- known guild is the claiming guild. The same event seen again needs no authority.
local OUTPOST_CLAIM_PEER_WINDOW = 120
local OUTPOST_CLAIM_HISTORY_WINDOW = 300
local OUTPOST_CLAIM_PEER_MAX = 64
local OUTPOST_OWNER_CLAIM_TTL = 3600
local OUTPOST_OWNER_CLAIM_MAX = 512

local OUTPOST_CLAIM_WINDOW_BUDGET = 480
local OUTPOST_ROW_PACKETS_MAX = 3
local OUTPOST_OWNER_CLAIMS_PER_HOUR = 16
local OUTPOST_CLAIM_REFILL_SEC = 60
-- Capture times come from the shared server clock: a claim further ahead is forged.
local OUTPOST_CLAIM_FUTURE_SKEW = 30
local outpostClaimPeers = {}
local outpostClaimPeerCount = 0
local ownerClaimDedup = NewOutpostDedup(OUTPOST_OWNER_CLAIM_TTL, OUTPOST_OWNER_CLAIM_MAX)
local outpostClaimStats = { accepted = 0, refused = 0 }

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
    -- 1.4.0: one campaign per Forever ruleset (RealmPools.lua).
    if Overlord.RealmPools and Overlord.RealmPools.RULESET_POOLS
        and Overlord.RealmPools.RULESET_POOLS[pool] then return pool end
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

-- Meme regle que Sync.lua (heure serveur, futur borne) : un seul comportement
-- pour les horodatages d'avant-poste et de zone.
local function NormalizeRemoteTimestamp(ts)
    return Overlord.Sync.NormalizeRemoteTimestamp(ts)
end

local function ClaimServerNow()
    return Overlord.ServerNow and Overlord.ServerNow() or time()
end

-- The time of a signed capture is its identity: kept exactly as written on every
-- client (never brought back to the local clock); only a value beyond the clock
-- skew (broken or forged packet) is refused.
local function ParseClaimTimestamp(ts)
    ts = tonumber(ts)
    if not ts or ts ~= ts then return nil end
    ts = math.floor(ts)
    if ts <= 0 or ts > ClaimServerNow() + OUTPOST_CLAIM_FUTURE_SKEW then return nil end
    return ts
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


local function BroadcastOutpostToGroup(msgType, payload)
    if not payload or payload == "" then return end
    if not IsInGroup or not IsInGroup() then return end
    if Overlord.Sync and Overlord.Sync.Send then
        Overlord.Sync:Send(msgType, payload)
    end
end

local function BroadcastOutpostToRelay(msgType, payload)
    if not payload or payload == "" then return end
    if Overlord.Sync and Overlord.Sync.BroadcastToRelay then
        Overlord.Sync:BroadcastToRelay(msgType, payload)
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
    elseif status == "held" then
        -- 1.5.1 : le capteur voyage avec l'etat tenu, dans le champ deja lu par tous
        -- les clients (meme queue que in_progress, champs precedents vides).
        local heldCapturer = OP.NormalizeHeldCapturerName
            and OP:NormalizeHeldCapturerName(st.heldCapturerName) or nil
        if heldCapturer and st.heldCapturerGuild ~= guild then heldCapturer = nil end
        if heldCapturer then
            payload = payload .. string.format(":%s:%s:%d:%d:%s", "", "", 0, 0, heldCapturer)
        end
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
    -- Cinq quotas fixes : meme sous flood, aucun handler ne rescane une table.
    PruneOutpostDedupRegistry(opDedup, now, 4)
    PruneOutpostDedupRegistry(ocDedup, now, 4)
    PruneOutpostDedupRegistry(loDedup, now, 4)
    PruneOutpostDedupRegistry(loSendDedup, now, 4)
    PruneOutpostDedupRegistry(locDedup, now, 4)
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
            if OpRosterMatchKey(full) == want then
                return true
            end
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
    -- Un nom d'origine ecrit par une passerelle relais n'est pas le membre du groupe.
    if Overlord.Sync and Overlord.Sync.IsUnauthenticatedRelayOrigin
        and Overlord.Sync:IsUnauthenticatedRelayOrigin(sender) then return false end
    if not OpSenderIsInOurGroup(sender) then return false end
    local senderGuild, senderFaction = GetOpAddonSenderGuild(sender)
    if senderGuild and senderGuild ~= "" then
        return senderGuild == guild
            and (not faction or faction == "" or senderFaction == faction)
    end
    return false
end

-- Map plausibility of a final the capturer himself announced (the authority of the
-- claim is checked before, see AuthorizeOutpostClaim).
local function ShouldAcceptOutpostCapture(siteKey, guild, fac, remoteTs)
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
        st, guild, effectiveFac, remoteTs, Overlord.Outpost:GetSite(siteKey)) then return false end

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

local function BuildLeaderboardOutpostTenantPayload(siteKey, guild, faction, claimedTs, capturer)
    siteKey = tostring(siteKey or "")
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    local facCode = FactionToCode(faction)
    local pool = CurrentOutpostPoolTag()
    capturer = NormalizeOpCapturerName(capturer)
    if pool == "" or siteKey == "" or guild == "" or facCode == "" or capturer == "" then return nil end
    claimedTs = math.floor(tonumber(claimedTs) or 0)
    if claimedTs <= 0 then return nil end
    local epoch = OverlordDB and tonumber(OverlordDB.lastResetTimestamp) or 0
    if epoch <= 0 or not IsOutpostLeaderboardTimestampCurrent(claimedTs, epoch) then return nil end
    return string.format("%s:%s:%s:%d:%d:%s:%s", siteKey, guild, facCode, claimedTs, epoch, pool, capturer)
end

-- A reply carries the newest LOC packet of a row and up to OUTPOST_ROW_PACKETS_MAX - 1
-- older ones, chosen by the requester's rotation so that successive replies walk
-- through a long history instead of starving the other rows. The packets are
-- built once per snapshot (Leaderboard.lua), never inside a reply.
local function SelectOutpostEventPackets(packets, rotation)
    local total = #packets
    if total <= OUTPOST_ROW_PACKETS_MAX then return packets end
    local picked = { packets[1] }
    local older = total - 1
    local start = (math.floor(tonumber(rotation) or 0) % older)
    for i = 1, OUTPOST_ROW_PACKETS_MAX - 1 do
        picked[#picked + 1] = packets[2 + ((start + i - 1) % older)]
    end
    return picked
end

local function OutpostClaimPeerKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    local sync = Overlord.Sync
    local key = sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(name) or nil
    if key and key ~= "" then return key end
    return name:lower()
end

-- A map or history request opens a window during which that peer's whispered or
-- targeted reply may carry capture claims we did not witness (SendWhisper / SR),
-- with a budget of events judged per window (an honest reply holds far fewer).
-- Repeated requests to the same peer extend the window but refill the budget at
-- most once a minute.
function Overlord.Sync:NoteOutpostClaimPeer(target, srPayload)
    local key = OutpostClaimPeerKey(target)
    if not key then return false end
    local window = type(srPayload) == "string" and srPayload:match(":H$")
        and OUTPOST_CLAIM_HISTORY_WINDOW or OUTPOST_CLAIM_PEER_WINDOW
    local now = GetTime()
    local row = outpostClaimPeers[key]
    if not row then
        if outpostClaimPeerCount >= OUTPOST_CLAIM_PEER_MAX then
            for peer, entry in pairs(outpostClaimPeers) do
                if entry.until_ <= now then
                    outpostClaimPeers[peer] = nil
                    outpostClaimPeerCount = math.max(0, outpostClaimPeerCount - 1)
                end
            end
            if outpostClaimPeerCount >= OUTPOST_CLAIM_PEER_MAX then return false end
        end
        row = { refilledAt = -OUTPOST_CLAIM_REFILL_SEC }
        outpostClaimPeers[key] = row
        outpostClaimPeerCount = outpostClaimPeerCount + 1
    end
    row.until_ = math.max(row.until_ or 0, now + window)
    if now - row.refilledAt >= OUTPOST_CLAIM_REFILL_SEC then
        row.left = OUTPOST_CLAIM_WINDOW_BUDGET
        row.refilledAt = now
    end
    return true
end

-- One judged event of a reply we asked for; false once the window or its budget is gone.
local function ConsumeSolicitedOutpostClaim(sender, sourceChannel)
    if sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork
        and Overlord.BetaNetwork:IsTargetedDispatch()) then return false end
    local sync = Overlord.Sync
    if sync.IsUnauthenticatedRelayOrigin and sync:IsUnauthenticatedRelayOrigin(sender) then return false end
    local key = OutpostClaimPeerKey(sender)
    local row = key and outpostClaimPeers[key] or nil
    if not row or GetTime() > row.until_ or (row.left or 0) <= 0 then return false end
    row.left = row.left - 1
    return true
end

-- The WoW-authenticated sender is the capturer himself (never a relayed origin,
-- never a name that is not a full Forever identity).
local function SenderIsOutpostCapturer(sender, capturer)
    if type(sender) ~= "string" or sender == "" or capturer == "" then return false end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return false end
    local sync = Overlord.Sync
    if sync.IsUnauthenticatedRelayOrigin and sync:IsUnauthenticatedRelayOrigin(sender) then return false end
    if sync.CanonicalForeverName and not sync:CanonicalForeverName(sender) then return false end
    return sync.KillSyncSenderOwnsPlayer and sync:KillSyncSenderOwnsPlayer(sender, capturer) or false
end

-- Faction the transport proves for a live sender: the channel and whispers are
-- faction-bound, a group mate's unit tells it, a Battle.net friend is resolved.
-- nil when nothing proves it (the claim is then refused).
local function LiveSenderFaction(sender, sourceChannel)
    local sync = Overlord.Sync
    if sourceChannel == "CHANNEL" or sourceChannel == "WHISPER" then return Overlord.PlayerFaction end
    local transport = sourceChannel
    if sourceChannel == "BETA" then
        local context = Overlord.BetaNetwork and Overlord.BetaNetwork.context
        transport = context and context.transport or "BNET"
    end
    if transport == "PARTY" or transport == "RAID" then
        local faction = sync.GetGroupMemberFaction and sync:GetGroupMemberFaction(sender) or nil
        if faction == "Alliance" or faction == "Horde" then return faction end
        return nil
    end
    if transport == "CHANNEL" or transport == "WHISPER" then return Overlord.PlayerFaction end
    local resolved = sync.GetResolvedBNetPlayerFaction and sync:GetResolvedBNetPlayerFaction(sender)
    if resolved == "Alliance" or resolved == "Horde" then return resolved end
    return nil
end

local function CapturerLadderGuild(capturer)
    local lb = Overlord.Leaderboard
    if not lb or not lb.GetHotPlayerGuildState then return "" end
    local guild = lb:GetHotPlayerGuildState(capturer)
    return Overlord.Outpost:SanitizeGuildName(guild or "")
end

local function CapturerLadderFaction(capturer)
    local lb = Overlord.Leaderboard
    local info = lb and type(lb.playerInfo) == "table" and lb.playerInfo[capturer] or nil
    local faction = info and info.faction
    if faction == "Alliance" or faction == "Horde" then return faction end
    return nil
end

local function NoteOutpostClaimRefused(msgType, reason)
    outpostClaimStats.refused = outpostClaimStats.refused + 1
    outpostClaimStats.lastRefused = tostring(msgType) .. " " .. tostring(reason)
end

function Overlord.Sync:GetOutpostClaimStats()
    return outpostClaimStats.accepted, outpostClaimStats.refused, outpostClaimStats.lastRefused
end

-- Shortest time a character needs before completing a capture of this site (the
-- gold-reduced contract, minus a little clock skew), the same on every client.
local function OutpostClaimGap(siteKey)
    local lb = Overlord.Leaderboard
    if lb and lb.GetOutpostSiteGap then return lb:GetOutpostSiteGap(siteKey) end
    local OP = Overlord.Outpost
    local site = OP:GetSite(siteKey)
    return (OP.GetMinimumHoldTimeRequired and OP:GetMinimumHoldTimeRequired(site) or 240) - 5
end

-- Who may end an assault we only observe: its assailant, as the authenticated
-- sender (his heartbeats named him), or anyone once the assault went quiet. A
-- stranger cannot hide a live assault from the defenders.
local function MayRestoreObservedAssault(siteKey, st, sender)
    local OP = Overlord.Outpost
    if not st or st.status ~= "in_progress" or not OP then return false end
    local assailant = NormalizeOpCapturerName(st.opRelayCapturerName)
    if assailant ~= "" and SenderIsOutpostCapturer(sender, assailant) then
        -- The assailant is who his heartbeats said, and the ladder knows him in
        -- the assaulting guild: a stranger naming himself assailant ends nothing.
        local guild = OP:SanitizeGuildName(st.ownerGuild or "")
        local ladderGuild = CapturerLadderGuild(assailant)
        if guild ~= "" and ladderGuild ~= "" and ladderGuild:lower() == guild:lower() then return true end
    end
    return OP.IsObserverOutpostCaptureStale
        and OP:IsObserverOutpostCaptureStale(st, OP:GetSite(siteKey), ClaimServerNow()) or false
end

-- A direct adoption is for a capture the map missed in between: a takeover by the
-- faction the map already shows as tenant is only adopted when the ledger holds a
-- capture of the other faction on this site newer than that tenant (the missed one).
local function OutpostAdoptionJustified(siteKey, st, faction, lb)
    local mapFaction = (st.status == "held" and st.ownerFaction)
        or (st.status == "in_progress" and st.previousOwnerFaction) or nil
    if mapFaction ~= "Alliance" and mapFaction ~= "Horde" then return true end
    if mapFaction ~= faction then return true end
    local mapTs = math.max(math.floor(tonumber(st.claimedAt) or 0),
        math.floor(tonumber(st.previousClaimedAt) or 0))
    local other = faction == "Alliance" and "Horde" or "Alliance"
    return lb.HasOutpostEventOfFactionSince
        and lb:HasOutpostEventOfFactionSince(siteKey, other, mapTs) or false
end

-- Decides whether one capture claim may enter the ledger and the map.
-- Returns true, "known" | "catch-up" | "owner", canonical capturer; or false, reason.
function Overlord.Sync:AuthorizeOutpostClaim(siteKey, guild, faction, claimTs, capturer, sender, sourceChannel, pool)
    local OP = Overlord.Outpost
    if not OP or (faction ~= "Alliance" and faction ~= "Horde") then return false, "faction" end
    guild = OP:SanitizeGuildName(guild or "")
    if guild == "" or (self.IsValidGuildSyncToken and not self:IsValidGuildSyncToken(guild)) then
        return false, "guild"
    end
    -- One spelling of the capturer everywhere: Given Family, no realm suffix.
    capturer = self.CanonicalForeverName
        and self:CanonicalForeverName(NormalizeOpCapturerName(capturer)) or nil
    if not capturer or capturer:find("[:|,=%c]")
        or (self.HasForeverNameCase and not self:HasForeverNameCase(capturer))
        or (self.IsDeniedKillContributor and self:IsDeniedKillContributor(capturer)) then
        return false, "capturer"
    end
    claimTs = tonumber(claimTs)
    if not claimTs or claimTs ~= claimTs then return false, "stale" end
    claimTs = math.floor(claimTs)
    if claimTs <= 0 then return false, "stale" end
    -- Captures of the release week were stated without their capturer: none of
    -- them can be re-announced (the saved rows were dropped on every client too).
    local lb = Overlord.Leaderboard
    local minTs = lb and math.floor(tonumber(lb.OUTPOST_CLAIM_MIN_TS) or 0) or 0
    if claimTs <= minTs and minTs - claimTs < 604800 then return false, "stale" end
    if claimTs > ClaimServerNow() + OUTPOST_CLAIM_FUTURE_SKEW then return false, "future" end
    local knownFaction = CapturerLadderFaction(capturer)
    if knownFaction and knownFaction ~= faction then return false, "capturer-faction" end
    if lb and lb.IsOutpostClaimAccepted
        and lb:IsOutpostClaimAccepted(siteKey, guild, faction, claimTs, capturer, pool) then
        return true, "known", capturer
    end
    -- An event of this second already credited to another character is never
    -- re-attributed; the ledger keeps the first capturer it accepted.
    if lb and lb.HasOutpostEvent and lb:HasOutpostEvent(siteKey, guild, faction, claimTs, pool) then
        return false, "event-owned"
    end
    -- By content, on every path: a character captures at most once per contract,
    -- whatever the site or the guild (the ledger index of his captures decides).
    local gap = OutpostClaimGap(siteKey)
    if lb and lb.IsOutpostCapturerPaced and not lb:IsOutpostCapturerPaced(capturer, claimTs, gap) then
        return false, "capturer-pace"
    end
    -- A reply we asked for is judged by content first: a capturer answering for his
    -- own history is not held to the live pace.
    local solicitedReason = nil
    if ConsumeSolicitedOutpostClaim(sender, sourceChannel) then
        if not self.IsKnownLeaderboardSubject or not self:IsKnownLeaderboardSubject(capturer) then
            solicitedReason = "catch-up-unknown"
        else
            local ladderGuild = CapturerLadderGuild(capturer)
            if ladderGuild == "" or ladderGuild:lower() ~= guild:lower() then
                solicitedReason = "catch-up-guild"
            else
                outpostClaimStats.accepted = outpostClaimStats.accepted + 1
                return true, "catch-up", capturer
            end
        end
    end
    if SenderIsOutpostCapturer(sender, capturer) then
        local senderFaction = LiveSenderFaction(sender, sourceChannel)
        if senderFaction ~= faction then return false, "owner-faction" end
        -- Credited to the guild the ladder knows for him (his own K / GI, our roster
        -- or group, a page): an unknown guild is not his to name live.
        local ladderGuild = CapturerLadderGuild(capturer)
        if ladderGuild == "" then return false, "owner-guild-unknown" end
        if ladderGuild:lower() ~= guild:lower() then return false, "owner-guild" end
        -- The live sender also carries a pace and an hourly budget of his own: a
        -- repeat of the very same claim (OC, then LO, then OP) costs nothing.
        local identity = siteKey .. "|" .. guild:lower() .. "|" .. faction .. "|" .. claimTs
        local key = OutpostClaimPeerKey(sender)
        local now = GetTime()
        PruneOutpostDedupRegistry(ownerClaimDedup, now, 4)
        local node = key and ownerClaimDedup.nodes[key] or nil
        if node and node.expiresAt > now and node.claimTs and node.lastClaim ~= identity then
            -- Pair rule as in the ledger: the gap of the later capture of the two.
            local required = claimTs >= node.claimTs and gap or (node.claimGap or gap)
            if math.abs(claimTs - node.claimTs) < required then return false, "owner-pace" end
            if (node.hourStart or 0) + 3600 <= now then node.hourStart, node.hourCount = now, 0 end
            if (node.hourCount or 0) >= OUTPOST_OWNER_CLAIMS_PER_HOUR then return false, "owner-budget" end
        end
        -- A full registry refuses rather than letting a claim through unpaced.
        if not key or not RememberOutpostDedup(ownerClaimDedup, key, now) then return false, "owner-busy" end
        node = ownerClaimDedup.nodes[key]
        if node and node.lastClaim ~= identity then
            if not node.hourStart or node.hourStart + 3600 <= now then node.hourStart, node.hourCount = now, 0 end
            node.hourCount = (node.hourCount or 0) + 1
            node.lastClaim = identity
            if not node.claimTs or claimTs > node.claimTs then node.claimTs, node.claimGap = claimTs, gap end
        end
        outpostClaimStats.accepted = outpostClaimStats.accepted + 1
        return true, "owner", capturer
    end
    return false, solicitedReason or "untrusted"
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
    if forceFull or st.status == "held" or st.status == "in_progress" then
        self:SendToChannel("OP", payload, forceFull or st.status == "held" or st.status == "in_progress")
    end
    local now = GetTime()
    local last = lastOPRelayBroadcast[siteKey] or 0
    local full = forceFull and true or false
    if not full and now - last < OP_ROUTINE_RELAY_INTERVAL then return end
    lastOPRelayBroadcast[siteKey] = now
    BroadcastOutpostToRelay("OP", payload)
end

function Overlord.Sync:BroadcastOutpostCapture(siteKey, guild, faction, captureTs, capturer)
    if not siteKey or OutpostSyncBlocked() then return end
    capturer = NormalizeOpCapturerName(capturer)
    if capturer == "" and self.GetPlayerFullName then
        capturer = NormalizeOpCapturerName(self:GetPlayerFullName() or "")
    end
    if capturer == "" then return end
    local gateBlocked = Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive())
    if gateBlocked then
        local restoreTs = math.floor(tonumber(captureTs) or 0)
        if restoreTs <= 0 then restoreTs = ClaimServerNow() end
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
                siteKey, guild, faction, restoreTs, capturer, queuedAt = GetTime(),
            }
        end
        ScheduleOcFlushRetry()
    end
    guild = Overlord.Outpost and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    local facCode = FactionToCode(faction)
    local pool = CurrentOutpostPoolTag()
    if pool == "" then return end
    captureTs = math.floor(tonumber(captureTs) or 0)
    if captureTs <= 0 then captureTs = ClaimServerNow() end
    local payload = siteKey .. ":" .. guild .. ":" .. facCode .. ":" .. captureTs .. ":" .. pool .. ":" .. capturer
    local function emitCapture()
        if not Overlord.Sync or Overlord.InstanceSuspended or not payload or payload == "" then return end
        BroadcastOutpostToGroup("OC", payload)
        Overlord.Sync:SendToChannel("OC", payload, true)
        BroadcastOutpostToRelay("OC", payload)
        if Overlord.Sync.BroadcastLeaderboardOutpostTenant then
            Overlord.Sync:BroadcastLeaderboardOutpostTenant(siteKey, guild, faction, captureTs, capturer)
        end
        -- No live count (LOC): the capturer can only vouch for his own capture, which
        -- OC and LO already carry; the full signed history comes with catch-up replies.
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
        local sk, g, fac, cts, capturer = e[1], e[2], e[3], e[4], e[5]
        if sk and g and g ~= "" and fac then
            self:BroadcastOutpostCapture(sk, g, fac, cts, capturer)
        end
    end
end

-- Returns true when a request was sent (the caller bounds its attempts). Besides
-- the channel request, withPull adds one targeted pull to a direct neighbour (the
-- other faction first: a quiet assault is usually theirs), which opens the window
-- through which the held final, a capture claim, may be believed (1.7.2).
function Overlord.Sync:PollIfStaleObserverOutpost(secondsSinceOp, withPull)
    local isLarge = IsOpLargeEvent()
    local minInterval = isLarge and STALE_OUTPOST_OBSERVER_POLL_INTERVAL_LARGE or STALE_OUTPOST_OBSERVER_POLL_INTERVAL
    if not secondsSinceOp or secondsSinceOp < minInterval then return false end
    local now = GetTime()
    if now - lastStaleOutpostObserverPoll < minInterval then return false end
    lastStaleOutpostObserverPoll = now
    self:SendSyncRequest({
        criticalChannel = true,
    })
    local net = Overlord.BetaNetwork
    if withPull and net and net.GetDirectPeers and self.GetBetaPeerFaction then
        local myName, myFaction = self:GetPlayerFullName(), Overlord.PlayerFaction
        local enemies, allies = {}, {}
        for _, name in ipairs(net:GetDirectPeers()) do
            if name ~= "" and not (self.ForeverIdentitiesMatch and self:ForeverIdentitiesMatch(name, myName)) then
                local faction = self:GetBetaPeerFaction(name)
                if faction and myFaction and faction ~= myFaction then
                    enemies[#enemies + 1] = name
                else
                    allies[#allies + 1] = name
                end
            end
        end
        local list = #enemies > 0 and enemies or allies
        if #list > 0 then
            staleOutpostPullRound = staleOutpostPullRound + 1
            self:SendSyncRequest({ betaTarget = list[(staleOutpostPullRound % #list) + 1] })
        end
    end
    return true
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
    if heldGuild == "" then return false end
    -- An assailant of the other faction may not know the tenant yet (1.7.2: a
    -- capture reaches the other faction by catch-up only): an assault that names
    -- no previous tenant still targets what we hold.
    local tenantUnknown = previousGuild == "" and not stAfter.previousOwnerFaction
    if not tenantUnknown then
        if previousGuild ~= heldGuild then return false end
        if not stBefore.ownerFaction or stAfter.previousOwnerFaction ~= stBefore.ownerFaction then return false end
        local heldClaimedAt = math.floor(tonumber(stBefore.claimedAt) or 0)
        local previousClaimedAt = math.floor(tonumber(stAfter.previousClaimedAt) or 0)
        if heldClaimedAt > 0 and previousClaimedAt ~= heldClaimedAt then return false end
    end

    local site = OP.GetSite and OP:GetSite(siteKey)
    if OP.IsObserverOutpostCaptureStale
        and OP:IsObserverOutpostCaptureStale(stAfter, site, ClaimServerNow()) then
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
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. Overlord:EnemyFactionChatIcon() .. L.OUTPOST_ALLIED_UNDER_ATTACK,
                whereLabel, heldGuild, facLabel))
        end
    elseif rGuild ~= "" and L.OUTPOST_DEFENDER_UNDER_ATTACK_BY then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. Overlord:EnemyFactionChatIcon() .. L.OUTPOST_DEFENDER_UNDER_ATTACK_BY,
            whereLabel, rGuild, facLabel))
    else
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. Overlord:EnemyFactionChatIcon() .. L.OUTPOST_DEFENDER_UNDER_ATTACK,
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
    -- Player feedback (2026-10-02): "(the Horde)" sat next to the Alliance guild.
    -- Each guild now carries its own crest: "<Ruthless> [H] is assaulting <EMPIRE> [A]".
    local holderFac = assaultFac == "Horde" and "Alliance" or assaultFac == "Alliance" and "Horde" or nil
    local attacker = Overlord:GuildChatTag(assaultGuild, assaultFac)
    local holder = defendedGuild ~= "" and Overlord:GuildChatTag(defendedGuild, holderFac) or nil
    if pf and assaultFac == pf then
        if holder and L.OUTPOST_ALLY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.OUTPOST_ALLY_ASSAULT_VS,
                whereLabel, attacker, holder))
        elseif L.OUTPOST_ALLY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.OUTPOST_ALLY_ASSAULT,
                whereLabel, attacker))
        end
    else
        if holder and L.OUTPOST_ENEMY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_ENEMY_ASSAULT_VS,
                whereLabel, attacker, holder))
        elseif L.OUTPOST_ENEMY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.OUTPOST_ENEMY_ASSAULT,
                whereLabel, attacker))
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
    -- Guild names reach chat alerts and tooltips: a name no guild can have is a forgery.
    guild = Overlord.Outpost:SanitizeGuildName(guild or "")
    prevGuild = Overlord.Outpost:SanitizeGuildName(prevGuild or "")
    if self.IsValidGuildSyncToken and ((guild ~= "" and not self:IsValidGuildSyncToken(guild))
        or (prevGuild ~= "" and not self:IsValidGuildSyncToken(prevGuild))) then
        return
    end
    local remotePool = OutpostPayloadPoolAcceptable(poolStr, sender, channel)
    if not remotePool then return end
    local ownerSourceVerified = OcSenderMatchesPayloadGuild(sender or "", guild, remoteFac)
    local hadTs = tsStr and tsStr ~= ""
    local remoteTs = NormalizeRemoteTimestamp(tsStr)
    if hadTs and not remoteTs then return end
    if not remoteTs then remoteTs = 0 end
    if IsStaleCampaignTimestamp(remoteTs) then return end
    local relayCapturer = NormalizeOpCapturerName(capturerName)
    local stLocal = Overlord.Outpost:GetState(siteKey)
    local heldCaptureTs, mapClaimedAt = 0, nil
    if status == "held" then
        heldCaptureTs = math.floor(tonumber(caStr) or 0)
        if heldCaptureTs <= 0 then heldCaptureTs = remoteTs end
        if heldCaptureTs <= 0 or heldCaptureTs > ClaimServerNow() + OUTPOST_CLAIM_FUTURE_SKEW
            or IsStaleCampaignTimestamp(heldCaptureTs) then
            return
        end
        -- The assault we observed ended and its assailant put back the tenant we
        -- already knew: nothing to judge, our own knowledge comes back. Only the
        -- assailant himself (or anyone once the assault went quiet) may say so.
        if MayRestoreObservedAssault(siteKey, stLocal, sender)
            and Overlord.Outpost:RestorePreviousTenant(siteKey, stLocal, guild, remoteFac, heldCaptureTs, remoteTs) then
            MaybeResetOutpostDefenderAlert(siteKey, stLocal)
            MaybeResetOutpostAssaultAlert(siteKey, stLocal)
            return
        end
        -- A held state is a capture claim (1.7.2): its capturer states it himself,
        -- or we asked for it, or we already hold this exact event (routine copies).
        local ok, reason, signedCapturer = self:AuthorizeOutpostClaim(
            siteKey, guild, remoteFac, heldCaptureTs, relayCapturer, sender, channel, remotePool)
        if not ok then
            NoteOutpostClaimRefused("OP", reason)
            return
        end
        relayCapturer = signedCapturer
        -- The ledger keeps the written second; the map never runs ahead of the clock.
        mapClaimedAt = math.min(heldCaptureTs, ClaimServerNow() + 5)
    else
        if not ownerSourceVerified
            and not self:IsStrategicSiteSenderTrusted(sender or "", remoteFac, channel, "OP", status) then
            return
        end
        local relayPeerSource = self.IsKnownRelayPeer
            and self:IsKnownRelayPeer(sender or "") or false
        if relayPeerSource and not ownerSourceVerified and remoteTs <= 0 then
            return
        end
        -- A release of an assault we observe gives the site back to the tenant we
        -- knew, when its assailant says so (or once the assault went quiet).
        if status == "neutral" and stLocal and stLocal.status == "in_progress"
            and Overlord.Outpost:SanitizeGuildName(stLocal.previousOwnerGuild or "") ~= "" then
            if MayRestoreObservedAssault(siteKey, stLocal, sender)
                and Overlord.Outpost:RestorePreviousTenant(siteKey, stLocal, nil, nil, nil, remoteTs) then
                MaybeResetOutpostDefenderAlert(siteKey, stLocal)
                MaybeResetOutpostAssaultAlert(siteKey, stLocal)
            end
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

    local stBefore = SnapshotOutpostTransitionState(siteKey, stLocal)
    local remote = {
        status = status,
        holdTimeElapsed = tonumber(holdStr) or 0,
        ownerGuild = guild,
        ownerFaction = remoteFac,
        claimedAt = mapClaimedAt or (tonumber(caStr) or 0),
        expiresAt = tonumber(exStr) or 0,
        updatedAt = remoteTs,
        holdTimeRequired = tonumber(holdReqStr) or nil,
        isContested = (contestedStr == "1"),
        previousOwnerGuild = prevGuild,
        previousOwnerFaction = FactionCodeToFaction(prevFacCode),
        previousClaimedAt = tonumber(prevCaStr) or 0,
        previousExpiresAt = tonumber(prevExStr) or 0,
        pool = remotePool,
        opRelayCapturerName = relayCapturer,
    }
    if status == "in_progress" then
        -- The previous tenant of an assault is what WE know, never what the assailant
        -- writes (he often does not know it since 1.7.2, and a forged one would show
        -- a tenant nobody captured). On a neutral site, only a capture the ledger holds.
        local OP = Overlord.Outpost
        if stLocal and stLocal.status == "held" and OP:SanitizeGuildName(stLocal.ownerGuild or "") ~= "" then
            remote.previousOwnerGuild = stLocal.ownerGuild
            remote.previousOwnerFaction = stLocal.ownerFaction
            remote.previousClaimedAt = math.floor(tonumber(stLocal.claimedAt) or 0)
            remote.previousExpiresAt = math.floor(tonumber(stLocal.expiresAt) or 0)
        elseif stLocal and stLocal.status == "in_progress"
            and OP:SanitizeGuildName(stLocal.previousOwnerGuild or "") ~= "" then
            remote.previousOwnerGuild = stLocal.previousOwnerGuild
            remote.previousOwnerFaction = stLocal.previousOwnerFaction
            remote.previousClaimedAt = math.floor(tonumber(stLocal.previousClaimedAt) or 0)
            remote.previousExpiresAt = math.floor(tonumber(stLocal.previousExpiresAt) or 0)
        elseif remote.previousOwnerGuild ~= "" then
            local lb = Overlord.Leaderboard
            if not (lb and lb.HasOutpostEvent and lb:HasOutpostEvent(siteKey, remote.previousOwnerGuild,
                remote.previousOwnerFaction, remote.previousClaimedAt, remotePool)) then
                remote.previousOwnerGuild, remote.previousOwnerFaction = "", nil
                remote.previousClaimedAt, remote.previousExpiresAt = 0, 0
            end
        end
    end
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
    -- A capture the ledger holds as the newest tenant of the site is the truth the
    -- map must follow, even when the map, which may have missed a capture in
    -- between, would refuse the takeover on its own (same-faction rule).
    local lb = Overlord.Leaderboard
    local heldNewEvent, heldTenantChanged = false, false
    if status == "held" and guild ~= "" and lb and lb.RecordOutpostCapture then
        heldNewEvent, heldTenantChanged = lb:RecordOutpostCapture(
            siteKey, guild, remoteFac, heldCaptureTs, remotePool, relayCapturer)
    end
    if status == "held" and lb and lb.IsOutpostLedgerTenant
        and lb:IsOutpostLedgerTenant(siteKey, guild, remoteFac, heldCaptureTs)
        and lb.OutpostLedgerAheadOfMap and lb:OutpostLedgerAheadOfMap(siteKey, stLocal)
        and OutpostAdoptionJustified(siteKey, stLocal, remoteFac, lb)
        and Overlord.Outpost.AdoptLedgerTenant then
        Overlord.Outpost:AdoptLedgerTenant(siteKey, stLocal, remote)
    else
        Overlord.Outpost:ApplyRemoteState(siteKey, remote, true)
    end
    local stAfter = Overlord.Outpost:GetState(siteKey)
    if (status == "in_progress" or status == "held")
        and Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(
            siteKey, relayCapturer ~= "" and relayCapturer or sender,
            remoteTs > 0 and remoteTs or nil)
    end
    if status == "held" then
        -- The authorized event entered the ledger above whatever the map decided (a
        -- late copy of an older capture still counts); the map keeps its LWW merge.
        local newEvent, tenantChanged = heldNewEvent, heldTenantChanged
        local stateChanged = false
        if stAfter and stAfter.status == "held" then
            local heldGuild = Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "")
            local heldTs = math.floor(tonumber(stAfter.claimedAt) or 0)
            if guild ~= "" and heldGuild == guild
                and stAfter.ownerFaction == remoteFac and heldTs == mapClaimedAt then
                stateChanged = stBefore
                    and (stBefore.status ~= "held"
                        or Overlord.Outpost:SanitizeGuildName(stBefore.ownerGuild or "") ~= heldGuild
                        or stBefore.ownerFaction ~= remoteFac
                        or (stBefore.claimedAt or 0) ~= heldTs) or false
                -- The map adopted this claim: it names the capturer the ledger kept
                -- for the event (the first one accepted, never a later rename).
                local kept = lb and lb.GetOutpostEventCapturer
                    and lb:GetOutpostEventCapturer(siteKey, guild, remoteFac, heldCaptureTs, remotePool) or nil
                stAfter.heldCapturerName = kept or relayCapturer
                stAfter.heldCapturerGuild = heldGuild
                if stateChanged and stBefore and stBefore.status == "in_progress"
                    and (ClaimServerNow() - heldTs) <= 90
                    and self.PrintOutpostCaptureAlert then
                    self:PrintOutpostCaptureAlert(siteKey, heldGuild, remoteFac, heldTs)
                end
            end
        end
        if (newEvent or tenantChanged or stateChanged)
            and Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
    end
    local defenderAlertState = stAfter
    if status == "in_progress" and stBefore and stBefore.status == "held"
        and stAfter and stAfter.status ~= "in_progress" then
        defenderAlertState = {
            status = "in_progress",
            ownerGuild = guild,
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
    -- An assault in progress learned from a reply is reposted on the local paths;
    -- a held state is not: a capture claim is only believed from its capturer.
    if status == "in_progress"
        and (channel == "WHISPER" or (channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch()))
        and payload and payload ~= "" and OutpostPayloadHasExplicitLinkedPool(remotePool) then
        local adoptedProgress = stAfter and stAfter.status == "in_progress"
            and guild ~= ""
            and Overlord.Outpost:SanitizeGuildName(stAfter.ownerGuild or "") == guild
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
    end
end

function Overlord.Sync:OnReceiveOutpostCapture(payload, sender, sourceChannel)
    if not payload or not Overlord.Outpost or OutpostSyncBlocked() then return false end
    local siteKey, guild, facCode, tsStr, remotePool, capturerName = strsplit(":", payload, 6)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return false end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return false end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return false end
    -- The time is the identity of the signed event: taken as written (never
    -- rewritten to the local clock, every client must hold the same event).
    local remoteTs = ParseClaimTimestamp(tsStr)
    if not remoteTs or IsStaleCampaignTimestamp(remoteTs) then return false end
    guild = Overlord.Outpost:SanitizeGuildName(guild or "")
    local capturer = NormalizeOpCapturerName(capturerName)
    -- OC is the one-shot live final: the capturer himself states it (a group mate
    -- or a relay copy is refused); a peer we asked may carry it by content.
    local ok, reason, signedCapturer = self:AuthorizeOutpostClaim(
        siteKey, guild, fac, remoteTs, capturer, sender, sourceChannel, remotePool)
    if not ok then
        NoteOutpostClaimRefused("OC", reason)
        return false
    end
    capturer = signedCapturer
    local dedupKey = string.format("%s:%s:%s:%d:%s:%s",
        siteKey, guild, facCode or "", remoteTs, remotePool, capturer:lower())
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(ocDedup, dedupKey, now) then return true end
    if Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(siteKey, capturer, remoteTs)
    end
    local lb = Overlord.Leaderboard
    local leaderboardChanged = false
    if lb and lb.RecordOutpostCapture then
        local newEvent, tenantChanged = lb:RecordOutpostCapture(
            siteKey, guild, fac, remoteTs, remotePool, capturer)
        leaderboardChanged = newEvent or tenantChanged
    end
    -- The map names the capturer the ledger kept for this event (the first accepted).
    local keptCapturer = lb and lb.GetOutpostEventCapturer
        and lb:GetOutpostEventCapturer(siteKey, guild, fac, remoteTs, remotePool) or capturer
    local objective = Overlord.OutpostSites[siteKey]
    if objective and objective.id and self.CanCreditDirectCapture
        and self:CanCreditDirectCapture(sender, capturer, objective.id, fac)
        and lb and lb.CreditPlayerObjectiveCapture then
        local classToken = self.ResolveContributorClassToken
            and self:ResolveContributorClassToken(capturer) or nil
        lb:CreditPlayerObjectiveCapture(capturer, objective.id, fac, remoteTs, true, classToken)
    end
    -- The ledger keeps the written second; the map never runs ahead of the clock.
    local mapTs = math.min(remoteTs, ClaimServerNow() + 5)
    local captureAccepted = ShouldAcceptOutpostCapture(siteKey, guild, fac, mapTs)
    local stEarly = Overlord.Outpost:GetState(siteKey)
    if not captureAccepted or (stEarly and stEarly.status == "held"
        and Overlord.Outpost:SanitizeGuildName(stEarly.ownerGuild or "") == guild
        and stEarly.ownerFaction == fac and NormalizePoolTag(stEarly.pool) == remotePool) then
        if leaderboardChanged and Overlord.LeaderboardUI
            and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
        return true
    end
    if not Overlord.Outpost:CompleteCapture(siteKey, guild, fac, mapTs, remotePool, true, keptCapturer) then
        if leaderboardChanged and Overlord.LeaderboardUI
            and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
        return true
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    return true
end

-- Il existe sept sites : une SR territoriale doit pouvoir transporter
-- les sept etats simultanes, y compris neutral. Sans le terminal neutre, un client
-- hors ligne pendant un abandon conserverait indefiniment son ancien assaut.
local SR_MINIMAL_OP_SITE_MAX = 16

-- A neutral site that never changed state (timestamp 0) tells a receiver nothing:
-- it is neutral there too, and a zero timestamp never wins a merge. Since 1.1.4
-- the five fortresses start neutral, so every SR answer carried up to twelve such
-- OP packets. A site that became neutral again (abandon) keeps its timestamp and
-- is still sent, so peers clear their stale state.
local function IsNeverTouchedNeutral(st)
    return st and st.status == "neutral" and OutpostSyncTimestamp(st) <= 0
end

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
            if st and st.status == "neutral" and not IsNeverTouchedNeutral(st) then
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
        local st = Overlord.Outpost:GetState(siteKey)
        local opData = not IsNeverTouchedNeutral(st)
            and self.BuildOutpostPayload and self:BuildOutpostPayload(siteKey)
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
        local capturer = NormalizeOpCapturerName(row.capturer)
        if facCode ~= "" and row.siteKey and row.guild and row.guild ~= "" and rowPool ~= ""
            and capturer ~= "" then
            local payload = string.format("%s:%s:%s:%d:%d:%s:%s",
                row.siteKey, row.guild, facCode, row.claimedAt or 0, row.epoch or 0, rowPool, capturer)
            table.insert(queue, { type = "LO", data = payload })
        end
    end
end

-- LOC en SR : les captures signees de chaque couple (avant-poste, guilde). Il
-- n'existe que douze sites ; le nombre de couples reste petit en pratique. La borne
-- (en paquets) sert de garde-fou anti-bloat : on la garde large pour qu'un
-- retardataire recoive TOUS les couples au login (convergence > rattrapage tardif).
-- Une ligne ne prend que quelques paquets par reponse (SelectOutpostEventPackets),
-- les reponses suivantes parcourent le reste de son historique.
-- Tri par nombre de captures decroissant (essentiel d'abord).
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
    -- Rotation of the older event slices: the requester's nonce when it has one,
    -- this responder's cursor otherwise (legacy requesters).
    local rotation = hasEvidencePage and math.floor(evidencePageNonce / rowBlockCount)
        or srLegacyOutpostCountCursor
    local function appendRow(row)
        if not row or emitted >= SR_OUTPOST_COUNT_MAX then return false end
        local packets = type(row.packets) == "table" and row.packets or nil
        if not packets or #packets == 0 then return false end
        packets = SelectOutpostEventPackets(packets, rotation)
        for i = 1, #packets do
            if emitted >= SR_OUTPOST_COUNT_MAX then break end
            table.insert(queue, { type = "LOC", data = packets[i] })
            emitted = emitted + 1
        end
        return true
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
    elseif not hasEvidencePage then
        -- No row beyond the fixed ones: still move the slice rotation along.
        srLegacyOutpostCountCursor = srLegacyOutpostCountCursor + 1
    end
end

function Overlord.Sync:BroadcastHeldOutpostStates()
    if not Overlord.Outpost or not Overlord.OutpostSites then return end
    if OutpostSyncBlocked() or Overlord.WaitingForSync then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    for siteKey in pairs(Overlord.OutpostSites) do
        local st = Overlord.Outpost:GetState(siteKey)
        -- 1.7.2: a held state is a capture claim believed from its capturer only;
        -- re-announcing the capture of another player costs traffic for nothing.
        if st and st.status == "held" and (st.ownerGuild or "") ~= ""
            and st.heldCapturerName and self.ForeverIdentitiesMatch
            and self:ForeverIdentitiesMatch(self:GetPlayerFullName() or "", st.heldCapturerName) then
            self:BroadcastOutpostState(siteKey, false)
        end
    end
end

function Overlord.Sync:BroadcastLeaderboardOutpostTenant(siteKey, guild, faction, claimedTs, capturer)
    if not siteKey or OutpostSyncBlocked() then return end
    local payload = BuildLeaderboardOutpostTenantPayload(siteKey, guild, faction, claimedTs, capturer)
    if not payload then return end
    local sendKey = payload
    local now = GetTime()
    PruneOpDedup(now)
    if not AdmitOutpostDedup(loSendDedup, sendKey, now) then return end
    local function emitTenant()
        if not Overlord.Sync or Overlord.InstanceSuspended or not payload or payload == "" then return end
        BroadcastOutpostToGroup("LO", payload)
        Overlord.Sync:SendToChannel("LO", payload, true)
        BroadcastOutpostToRelay("LO", payload)
    end
    emitTenant()
    C_Timer.After(OP_CAPTURE_REPLAY_DELAY_1, emitTenant)
end

-- LO: "site:guild:fac:claimedAt:epoch:pool:capturer", one signed capture.
-- Returns true when the claim was accepted; an accepted row from the peer we asked
-- for outpost history confirms that round (fresh when it brought a new event).
function Overlord.Sync:OnReceiveLeaderboardOutpostTenant(payload, sender, sourceChannel)
    if not payload or not Overlord.Leaderboard or OutpostSyncBlocked() then return false end
    if not Overlord.Leaderboard.RecordOutpostCapture then return false end
    local siteKey, guild, facCode, claimedStr, epochStr, remotePool, capturerName = strsplit(":", payload, 7)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return false end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return false end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return false end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return false end
    local claimedAt = ParseClaimTimestamp(claimedStr)
    if not claimedAt or not IsOutpostLeaderboardTimestampCurrent(claimedAt, remoteEpoch) then return false end
    guild = Overlord.Outpost and Overlord.Outpost.SanitizeGuildName
        and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return false end
    if not SenderRealmMatchesCurrentOutpostPool(sender or "", sourceChannel) then return false end
    local ok, reason, capturer = self:AuthorizeOutpostClaim(
        siteKey, guild, fac, claimedAt, capturerName, sender, sourceChannel, remotePool)
    if not ok then
        NoteOutpostClaimRefused("LO", reason)
        return false
    end
    local dedupKey = string.format("%s:%s:%s:%d:%s:%s",
        siteKey, guild, facCode or "", claimedAt, remotePool, capturer:lower())
    local now = GetTime()
    PruneOpDedup(now)
    local newEvent, tenantChanged = false, false
    if AdmitOutpostDedup(loDedup, dedupKey, now) and reason ~= "known" then
        newEvent, tenantChanged = Overlord.Leaderboard:RecordOutpostCapture(
            siteKey, guild, fac, claimedAt, remotePool, capturer)
    end
    if self.NoteOutpostHistoryDelivery then self:NoteOutpostHistoryDelivery(sender, newEvent) end
    if not newEvent and not tenantChanged then return true end
    if Overlord.Outpost and Overlord.Outpost.RefreshOutpostPresentation then
        Overlord.Outpost:RefreshOutpostPresentation(siteKey)
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    return true
end

-- LOC: "site:guild:fac:epoch:pool:ts=Given Family,ts=...", the signed captures of
-- one row. Each event is judged on its own: live from its capturer, or by content
-- in a reply we asked for. Returns true when at least one event was accepted.
function Overlord.Sync:OnReceiveLeaderboardOutpostCount(payload, sender, sourceChannel)
    if not payload or not Overlord.Leaderboard or OutpostSyncBlocked() then return false end
    if not Overlord.Leaderboard.RecordOutpostCapture then return false end
    local siteKey, guild, facCode, epochStr, remotePool, eventsStr = strsplit(":", payload, 6)
    if not siteKey or not Overlord.OutpostSites[siteKey] then return false end
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = OutpostPayloadPoolAcceptable(wirePool, sender, sourceChannel)
    if not remotePool then return false end
    local fac = FactionCodeToFaction(facCode)
    if not fac then return false end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return false end
    guild = Overlord.Outpost and Overlord.Outpost.SanitizeGuildName
        and Overlord.Outpost:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return false end
    if type(eventsStr) ~= "string" or eventsStr == "" then return false end
    if not SenderRealmMatchesCurrentOutpostPool(sender or "", sourceChannel) then return false end
    local deliveryKey = tostring(sender or "") .. ":" .. payload
    local now = GetTime()
    PruneOpDedup(now)
    if OutpostDedupIsRecent(locDedup, deliveryKey, now) then return true end

    local accepted, fresh, changed, tenantMoved, parsed = false, false, false, false, 0
    for tsStr, name in eventsStr:gmatch("([^,=]+)=([^,]+)") do
        parsed = parsed + 1
        if parsed > (Overlord.Leaderboard.OUTPOST_EVENTS_PER_PACKET or 6) then break end
        local ts = ParseClaimTimestamp(tsStr)
        if ts and IsOutpostLeaderboardTimestampCurrent(ts, remoteEpoch) then
            local ok, reason, capturer = self:AuthorizeOutpostClaim(
                siteKey, guild, fac, ts, name, sender, sourceChannel, remotePool)
            if ok then
                accepted = true
                if reason ~= "known" then
                    local newEvent, tenantChanged = Overlord.Leaderboard:RecordOutpostCapture(
                        siteKey, guild, fac, ts, remotePool, capturer)
                    if newEvent then fresh = true end
                    if newEvent or tenantChanged then changed = true end
                    if tenantChanged then tenantMoved = true end
                end
            else
                NoteOutpostClaimRefused("LOC", reason)
            end
        end
    end
    -- Only a packet with an accepted event is remembered: a refused copy must not
    -- mask the same packet from its capturer a moment later.
    if accepted then RememberOutpostDedup(locDedup, deliveryKey, now) end
    if accepted and self.NoteOutpostHistoryDelivery then self:NoteOutpostHistoryDelivery(sender, fresh) end
    if not changed then return accepted end
    if tenantMoved and Overlord.Outpost and Overlord.Outpost.RefreshOutpostPresentation then
        Overlord.Outpost:RefreshOutpostPresentation(siteKey)
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    return true
end

-- Outpost/fortress leaderboard history (1.2.4): tenants (LO) and capture counts
-- (LOC), at most ~76 small rows, exchanged point to point with one direct
-- neighbour through SR mode "H". Replaces the v4 ladder exchange that carried the
-- same rows behind up to 615 ranking rows.
local OUTPOST_HISTORY_REPLY_COOLDOWN = 600
local OUTPOST_HISTORY_SEND_INTERVAL = 0.5
local outpostHistoryRepliedAt = {}
local outpostHistoryReply = nil

function Overlord.Sync:RespondOutpostHistory(target, evidencePage, hasEvidencePage)
    if type(target) ~= "string" or target == "" or outpostHistoryReply then return false end
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    local key = target:lower()
    local now = GetTime()
    if now - (outpostHistoryRepliedAt[key] or -OUTPOST_HISTORY_REPLY_COOLDOWN)
        < OUTPOST_HISTORY_REPLY_COOLDOWN then return false end
    local queue = {}
    pcall(self.AppendLeaderboardOutpostToSrQueue, self, queue)
    pcall(self.AppendLeaderboardOutpostCountToSrQueue, self, queue, evidencePage, hasEvidencePage)
    if #queue == 0 then return false end
    outpostHistoryRepliedAt[key] = now
    local reply = { target = target, queue = queue, index = 1, startedAt = now }
    outpostHistoryReply = reply
    local function tick()
        if outpostHistoryReply ~= reply then return end
        local packet = reply.queue[reply.index]
        -- A refused send (queue full, target no longer direct) is retried; the
        -- whole reply is bounded to two minutes.
        if not packet or GetTime() - reply.startedAt > 120 then
            outpostHistoryReply = nil
            return
        end
        if Overlord.Sync:SendWhisper(packet.type, packet.data, reply.target) then
            reply.index = reply.index + 1
        end
        C_Timer.After(OUTPOST_HISTORY_SEND_INTERVAL, tick)
    end
    tick()
    return true
end

-- One request to one direct neighbour; the scheduler retries another peer later.
function Overlord.Sync:RequestOutpostHistory(target)
    if type(target) ~= "string" or target == "" or not self.GetSRPayload then return false end
    return self:SendWhisper("SR", self:GetSRPayload("H"), target) == true
end
