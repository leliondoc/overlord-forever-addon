-- SyncGuildKeep.lua - Protocoles GK / GC et boosts domination WB.
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local function NetworkNow()
    local GK = Overlord.GuildKeep
    if GK and GK.GetNetworkTimestamp then return GK:GetNetworkTimestamp() end
    if GetServerTime then return math.floor(tonumber(GetServerTime()) or 0) end
    return time()
end

-- Filet UI/login : C_Timer communaute peut fired avant enregistrement du chunk Sync (gros Sync.lua).
if not Overlord.Sync.FindCommunityClub then
    function Overlord.Sync:FindCommunityClub()
        return nil
    end
end

function Overlord.Sync:HasCommunityClub()
    if self.FindCommunityClub then
        return self:FindCommunityClub() ~= nil
    end
    return OverlordDB and OverlordDB.inCommunity == true
end

-- Fortin : GC final est une verite critique. Il part groupe, canal et communaute large ;
-- les recepteurs tranchent par l'identite d'assaut ancree, pas par l'ordre d'arrivee.
local lastCommunityGKBroadcast = {}
local lastCommunityGKCriticalStart = {}
local pendingCommunityGKCriticalStart = {}
local pendingCommunityGKCriticalFallback = {}
local seenCommunityGKCriticalStart = {}
local GK_COMMUNITY_START_REVALIDATE_DELAY = 0.75
local GK_COMMUNITY_START_FALLBACK_DELAY = 6
local GK_COMMUNITY_ROUTINE_INTERVAL = 12
-- Heure des forts US : 80-90 joueurs Overlord = toujours en Large Event (seuil 15). L'intervalle
-- routine descend un peu pour compenser un fan-out large-event volontairement etroit (cout recurrent,
-- cf. GK_COMMUNITY_MAX_ROUTINE) sans re-ouvrir la porte a un cout qui grossit avec la duree du siege.
local GK_COMMUNITY_ROUTINE_INTERVAL_LARGE = 10
local GK_COMMUNITY_MAX_ROUTINE = 6
local GK_COMMUNITY_DELAY_ROUTINE = 0.9
-- Capture fortin (GC + GK force apres GC) : evenement rare, fan-out maximal comme les captures C.
local GK_COMMUNITY_CAPTURE_MAX = 40
local GK_COMMUNITY_CAPTURE_DELAY = 0.5
-- Debut de siege / GC / GA / poll observateur perime : cout BORNE (one-shot ou throttle par site,
-- pas repete pendant toute la duree du siege comme la routine). C'est justement le message qui
-- compte le plus a l'heure des forts US (80-90 joueurs) : ne pas le sacrifier autant que la routine.
local GK_COMMUNITY_CAPTURE_MAX_LARGE = 25
local GK_COMMUNITY_CAPTURE_DELAY_LARGE = 0.5
local GK_POST_CAPTURE_STATE_DELAY = 4.0
local GK_CAPTURE_REPLAY_DELAY_1 = 1.0
local GK_CAPTURE_REPLAY_DELAY_2 = 3.0
-- WB domination (bois individuel / victoire map) : evenements rares, relais communaute elargi cross-realm.
local WB_COMMUNITY_MAX = 12
local WB_COMMUNITY_DELAY = 0.35
local WB_COMMUNITY_MAX_LARGE = 8
local WB_COMMUNITY_DELAY_LARGE = 0.4
local WB_MAX_TOTAL_PCT = 1.0
local WB_CHANNEL_MAX_EVENT_DELTA = 0.02
-- Rattrapage/poll : petit fan-out, distinct d'une transition de siege. Le debut de siege
-- garde volontairement la couverture historique 25/40 ci-dessus ; sa charge est maintenant
-- etalee par la pompe globale et coalescee par fortin/cible dans SyncAux.
local GK_COMMUNITY_CATCHUP_NORMAL = 6
local GK_COMMUNITY_CATCHUP_DELAY_NORMAL = 0.9
local GK_COMMUNITY_CATCHUP_LARGE = 3
local GK_COMMUNITY_CATCHUP_DELAY_LARGE = 1.0
local GK_COMMUNITY_ROUTINE_NORMAL = 4
local FactionToCode

local function IsGkLargeEvent()
    return Overlord.Sync and Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
end

-- Transitions critiques fortin : non throttlees en routine, mais capees en Large Event
-- pour eviter une longue file de whispers quand 80+ joueurs sont au meme endroit.
local function GetGuildKeepCriticalRelayLimits()
    if IsGkLargeEvent() then
        return GK_COMMUNITY_CAPTURE_MAX_LARGE, GK_COMMUNITY_CAPTURE_DELAY_LARGE
    end
    return GK_COMMUNITY_CAPTURE_MAX, GK_COMMUNITY_CAPTURE_DELAY
end

local function GetWbCommunityRelayLimits()
    if IsGkLargeEvent() then
        return WB_COMMUNITY_MAX_LARGE, WB_COMMUNITY_DELAY_LARGE
    end
    return WB_COMMUNITY_MAX, WB_COMMUNITY_DELAY
end

local DOMINATION_BOOST_EVENT_MAX = 1024
local DOMINATION_BOOST_EVENT_TTL = 86400
local DOMINATION_BOOST_MAINTENANCE_INTERVAL = 60
local DOMINATION_BOOST_MAINTENANCE_WORK = 64
local DOMINATION_BOOST_MAINTENANCE_MS = 1.25
local dominationBoostLedgerState = {
    source = nil, epoch = 0, count = 0, valid = false, pending = false,
    generation = 0, lastBuiltAt = -DOMINATION_BOOST_MAINTENANCE_INTERVAL,
}

local function StartDominationBoostLedgerMaintenance(epoch)
    if not OverlordDB or not C_Timer or not C_Timer.After then return false end
    local source = OverlordDB.dominationBoostEvents
    if type(source) ~= "table" then
        source = {}
        OverlordDB.dominationBoostEvents = source
    end
    local state = dominationBoostLedgerState
    if state.pending and state.source == source and state.epoch == epoch then
        return state.valid
    end
    local initialBuild = not (state.source == source and state.epoch == epoch and state.valid)
    state.generation = state.generation + 1
    local generation = state.generation
    state.source, state.epoch = source, epoch
    if initialBuild then state.valid = false end
    state.pending = true
    local count = 0
    local processed = 0
    local started = debugprofilestop and debugprofilestop() or 0
    local worker = coroutine.create(function()
        local now = GetTime()
        local cursor, pendingDeleteKey = nil, nil
        while true do
            -- Garder `cursor` present jusqu'a l'appel next suivant : supprimer la
            -- cle courante avant un yield rend la continuation indefinie en Lua.
            local ok, key, seen = pcall(next, source, cursor)
            if not ok then error(key) end
            if pendingDeleteKey ~= nil then
                source[pendingDeleteKey] = nil
                if not initialBuild then
                    state.count = math.max(0, state.count - 1)
                end
                pendingDeleteKey = nil
            end
            if key == nil then break end
            cursor = key
            local evEpoch = tonumber(tostring(key):match("^(%d+):")) or 0
            local seenAt = type(seen) == "number" and seen or now
            if (epoch > 0 and evEpoch > 0 and evEpoch ~= epoch)
                or now - seenAt > DOMINATION_BOOST_EVENT_TTL then
                pendingDeleteKey = key
            elseif initialBuild then
                count = count + 1
            end
            processed = processed + 1
            local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
            if processed >= DOMINATION_BOOST_MAINTENANCE_WORK
                or elapsed >= DOMINATION_BOOST_MAINTENANCE_MS then
                processed = 0
                coroutine.yield()
                started = debugprofilestop and debugprofilestop() or 0
            end
        end
    end)
    local ResumeWorker
    ResumeWorker = function()
        if state.generation ~= generation or state.source ~= source
            or OverlordDB.dominationBoostEvents ~= source then return end
        local ok = coroutine.resume(worker)
        if not ok then
            state.pending = false
            if initialBuild then
                state.valid, state.failed = false, true
            end
            state.retryAt = GetTime() + 5
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        if initialBuild then state.count, state.valid = count, true end
        state.pending, state.failed = false, nil
        state.lastBuiltAt, state.retryAt = GetTime(), nil
        -- Un evenement peut etre admis entre deux tranches d'une maintenance
        -- periodique. Cette insertion peut reordonner la table parcourue par
        -- `next` en Lua 5.1 ; refaire une passe cooperative garantit qu'aucune
        -- ancienne entree expiree n'est sautee, sans scanner dans le handler WB.
        local restartRequested = state.restartRequested
        state.restartRequested = nil
        if restartRequested then
            StartDominationBoostLedgerMaintenance(epoch)
        end
    end
    ResumeWorker()
    return state.valid == true
end

function Overlord.Sync:EnsureDominationBoostEventLedgerPrepared(epoch)
    if not OverlordDB then return false end
    epoch = math.floor(tonumber(epoch) or tonumber(OverlordDB.lastResetTimestamp) or 0)
    OverlordDB.dominationBoostEvents = type(OverlordDB.dominationBoostEvents) == "table"
        and OverlordDB.dominationBoostEvents or {}
    local state = dominationBoostLedgerState
    local source = OverlordDB.dominationBoostEvents
    local now = GetTime()
    local currentValid = state.source == source and state.epoch == epoch and state.valid
    if currentValid then
        if not state.pending
            and (not state.retryAt or now >= state.retryAt)
            and now - state.lastBuiltAt >= DOMINATION_BOOST_MAINTENANCE_INTERVAL then
            StartDominationBoostLedgerMaintenance(epoch)
        end
        -- La maintenance periodique ne rend pas l'index partiel : son compteur
        -- reste exact au fil des suppressions et insertions cooperatives.
        return true
    end
    if state.pending and state.source == source and state.epoch == epoch then return false end
    if state.failed and state.source == source and state.epoch == epoch then return "blocked" end
    if state.retryAt and now < state.retryAt then return false end
    return StartDominationBoostLedgerMaintenance(epoch)
end

local function NormalizeDominationBoostEventId(eventId)
    if type(eventId) ~= "string" then return "" end
    eventId = eventId:match("^%s*([%w_%-%.]+)%s*$") or ""
    if #eventId > 80 then eventId = eventId:sub(1, 80) end
    return eventId
end

function Overlord.Sync:BuildDominationBoostEventId(faction)
    local name = (Overlord.SafeUnitName and select(1, Overlord:SafeUnitName("player"))) or UnitName("player") or "player"
    name = tostring(name):gsub("[^%w_%-]", "")
    local facCode = FactionToCode(faction) or "X"
    return string.format("%s-%s-%d-%d-%d", facCode, name, NetworkNow(), math.floor(GetTime() * 1000), math.random(1000, 9999))
end

function Overlord.Sync:MarkDominationBoostEventSeen(faction, eventId, epoch)
    if not OverlordDB then return false end
    eventId = NormalizeDominationBoostEventId(eventId)
    if eventId == "" then return false end
    local facCode = FactionToCode(faction) or tostring(faction or "")
    if facCode == "" then return false end
    epoch = math.floor(tonumber(epoch) or tonumber(OverlordDB.lastResetTimestamp) or 0)
    OverlordDB.dominationBoostEvents = OverlordDB.dominationBoostEvents or {}
    local key = string.format("%d:%s:%s", epoch, facCode, eventId)
    -- Exact avant toute maintenance : les replays restent O(1), meme pendant
    -- une reconstruction tranchee ou lorsque le ledger est sature.
    if OverlordDB.dominationBoostEvents[key] then return false end
    if not self:EnsureDominationBoostEventLedgerPrepared(epoch) then return false end
    local state = dominationBoostLedgerState
    if state.source ~= OverlordDB.dominationBoostEvents or not state.valid
        or state.count >= DOMINATION_BOOST_EVENT_MAX then return false end
    if state.pending and state.source == OverlordDB.dominationBoostEvents then
        state.restartRequested = true
    end
    OverlordDB.dominationBoostEvents[key] = GetTime()
    state.count = state.count + 1
    return true
end

local function GetGkCommunityRoutineRelayLimits()
    if IsGkLargeEvent() then
        return GK_COMMUNITY_MAX_ROUTINE, GK_COMMUNITY_DELAY_ROUTINE
    end
    return GK_COMMUNITY_ROUTINE_NORMAL, GK_COMMUNITY_DELAY_ROUTINE
end

local function GetGkCommunityCatchupRelayLimits()
    if IsGkLargeEvent() then
        return GK_COMMUNITY_CATCHUP_LARGE, GK_COMMUNITY_CATCHUP_DELAY_LARGE
    end
    return GK_COMMUNITY_CATCHUP_NORMAL, GK_COMMUNITY_CATCHUP_DELAY_NORMAL
end

local function GuildKeepCriticalStartKey(siteKey, st)
    if not siteKey or not st then return nil end
    local guild = (Overlord.GuildKeep and Overlord.GuildKeep.SanitizeGuildName)
        and Overlord.GuildKeep:SanitizeGuildName(st.ownerGuild or "") or (st.ownerGuild or "")
    local startAt = math.floor(tonumber(st.assaultShardStartedAt) or 0)
    if startAt <= 0 then return nil end
    return string.format("%s:%s:%s:%s:%d:%d:%d:%s:%s",
        siteKey, guild or "", st.ownerFaction or "", st.previousOwnerGuild or "",
        math.floor(tonumber(st.previousClaimedAt) or 0), startAt,
        math.floor(tonumber(st.assaultGenerationAt) or 0),
        tostring(st.assaultShardId or ""), tostring(st.assaultShardPlayer or ""))
end

local lastStaleKeepObserverPoll = 0
local STALE_KEEP_OBSERVER_POLL_INTERVAL = 22
local STALE_KEEP_OBSERVER_POLL_INTERVAL_LARGE = 45
local STALE_KEEP_OBSERVER_MAX_POLLS = 4
local staleKeepObserverPollState = {}
local forcedKeepRecoverySeenAt = {}
local lastForcedKeepRecoveryPoll = -1000000
local lastTrustedGuildKeepTrafficAt = {}
-- Dernier envoi CANAL reussi (SendToChannel a renvoye true) d'un GK in_progress par site.
-- Sert uniquement a detecter une secheresse prolongee (budget CHANNEL_BYTE_BUDGET_PER_SEC
-- sature par le reste du trafic de l'emetteur) pour forcer UN tick critique de rattrapage,
-- sans jamais augmenter le trafic moyen hors de ce cas de secheresse reelle.
local lastGkChannelSentAt = {}
local GK_CHANNEL_STALE_ESCALATE_SEC = 18
local lastObserverKeepFinalStatePoll = 0
local OBSERVER_KEEP_FINAL_STATE_MAX_POLLS = 4
local OBSERVER_KEEP_FINAL_STATE_BACKOFF = { 8, 20, 45, 90 }

local VALID_GK_STATUS = { neutral = true, in_progress = true, held = true, aborted = true }
local MAX_CLOCK_SKEW = 300
local GC_DEDUP_SEC = 10
local GK_DEDUP_SEC = 4
local GK_DEDUP_MAX = 128
local GC_DEDUP_MAX = 256

-- Chaque transport garde sa fenetre TTL sans balayage de table dans le handler.
-- GK/GC conservent les preuves vivantes. GH est un cache d'optimisation : son
-- registre persistant tranche deja les doublons. Une eviction FIFO doit donc
-- laisser entrer les nouvelles corrections historiques sans bloquer le classement.
local function NewGuildKeepDedup(ttl, maximum, evictOldest)
    return { ttl = ttl, max = maximum, count = 0, nodes = {}, head = nil, tail = nil,
        evictOldest = evictOldest == true }
end

local function RemoveGuildKeepDedupNode(registry, node)
    if node.previous then node.previous.next = node.next else registry.head = node.next end
    if node.next then node.next.previous = node.previous else registry.tail = node.previous end
    registry.nodes[node.key] = nil
    registry.count = registry.count - 1
end

local function PruneGuildKeepDedup(registry, now)
    local removed = 0
    while registry.head and registry.head.expiresAt <= now and removed < 4 do
        RemoveGuildKeepDedupNode(registry, registry.head)
        removed = removed + 1
    end
    return removed
end

local function GetGuildKeepDedupNode(registry, key, now)
    local node = registry.nodes[key]
    if node and node.expiresAt <= now then
        RemoveGuildKeepDedupNode(registry, node)
        return nil
    end
    return node
end

local function GuildKeepDedupHasCapacity(registry, now)
    PruneGuildKeepDedup(registry, now)
    return registry.count < registry.max or registry.evictOldest
end

local function RememberGuildKeepDedup(registry, key, now)
    local node = GetGuildKeepDedupNode(registry, key, now)
    if node then
        node.expiresAt = now + registry.ttl
        if registry.tail ~= node then
            if node.previous then node.previous.next = node.next else registry.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = registry.tail, nil
            registry.tail.next = node
            registry.tail = node
        end
        return node
    end
    if not GuildKeepDedupHasCapacity(registry, now) then return nil end
    if registry.count >= registry.max then
        RemoveGuildKeepDedupNode(registry, registry.head)
    end
    node = { key = key, expiresAt = now + registry.ttl, previous = registry.tail }
    registry.nodes[key] = node
    if registry.tail then registry.tail.next = node else registry.head = node end
    registry.tail = node
    registry.count = registry.count + 1
    return node
end

local gcDedup = NewGuildKeepDedup(GC_DEDUP_SEC, GC_DEDUP_MAX)
local gkDedup = NewGuildKeepDedup(GK_DEDUP_SEC, GK_DEDUP_MAX)
local gkDefenderAlertLast = {}
local gkDefenderAlertEmitted = {}
local gkDefenderAlertInactiveSince = {}
local GK_DEFENDER_ALERT_COOLDOWN = 90
local gkAssaultAlertLast = {}
local gkAssaultAlertEmitted = {}
local gkAssaultAlertInactiveSince = {}
local GK_ASSAULT_ALERT_COOLDOWN = 90
-- Un seul snapshot held/neutral ne termine pas une vague : plusieurs observateurs peuvent
-- encore relayer l'assaut live et faire osciller l'etat recu. Il faut une vraie periode
-- calme avant de reautoriser les notifications du meme siege.
local GK_ALERT_REARM_QUIET_SEC = 90
local gkCaptureAlertDedup = {}
local GK_CAPTURE_ALERT_DEDUP_SEC = 12

-- Forward : utilise avant definition (GcSenderMatchesPayloadGuild)
local SyncSenderIsInOurGroup
local IsStaleCampaignTimestamp
local NormalizeGkCapturerName

local function NormalizeGkRosterName(name)
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local dk = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if dk then return dk end
    end
    return ""
end

local function LocalPlayerIsGuildKeepAnchor(st)
    if not st or not Overlord.Sync or not Overlord.Sync.GetPlayerFullName then return false end
    local selfKey = NormalizeGkRosterName(Overlord.Sync:GetPlayerFullName())
    local anchorKey = NormalizeGkRosterName(st.assaultShardPlayer)
    return selfKey ~= "" and selfKey == anchorKey
end

-- Meme chaine que Sync.lua:SenderIsInOurGroup (dedup key + compactage royaume).
local function GkRosterMatchKey(name)
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local dk = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if dk and dk ~= "" then return dk:lower() end
    end
    return NormalizeGkRosterName(name)
end

-- Si le premier tagueur disparait avant sa vague +0,75 s, l'Anchor reste le tuple/shard,
-- pas ce client immortel. Apres une grace, le minimum des porteurs DIRECTS encore frais
-- peut reprendre la vague ; un simple relay ne figure jamais dans cette table d'attestation.
local function LocalPlayerIsGuildKeepFallbackAuthority(st, siteKey)
    if not st or not st.holdAuthorityLocal or not st.isHolding then return false end
    if Overlord.GuildKeep and Overlord.GuildKeep.IsLocalShardBlockedFromKeepAssault
        and Overlord.GuildKeep:IsLocalShardBlockedFromKeepAssault(st, siteKey) then return false end
    local selfName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
        and Overlord.Sync:GetPlayerFullName() or ""
    local selfKey = Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey
        and Overlord.Sync:GetCaptureContributorDedupKey(selfName)
        or NormalizeGkRosterName(selfName)
    selfKey = tostring(selfKey or ""):lower()
    if selfKey == "" then return false end
    local elected, now = selfKey, GetTime()
    for rawKey, seenAt in pairs(st._gkVerifiedCapturerKeys or {}) do
        local key = tostring(rawKey or ""):lower()
        if key ~= "" and now - (tonumber(seenAt) or 0) <= 5.5
            and key < elected then elected = key end
    end
    return elected == selfKey
end

-- Meme filet que Sync:Send / SendToChannel. Le revert local avant suspension peut
-- forcer le dernier snapshot si l'API IsInInstance a deja bascule.
local function GuildKeepSyncBlocked(allowInstance)
    if Overlord.InstanceSuspended then return true end
    if allowInstance then return false end
    return IsInInstance and IsInInstance()
end

local function NormalizeRemoteTimestamp(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return 0 end
    local now = NetworkNow()
    if ts > now + MAX_CLOCK_SKEW then return nil end
    if ts > now then return now end
    return ts
end

local function GetAddonSenderGuild(sender)
    if not sender or sender == "" or sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then
        return nil
    end
    if not IsInGroup() then return nil end
    -- Cache roster partage de Sync.lua : le heartbeat GK arrive toutes les 5 s et
    -- plusieurs emetteurs ne doivent pas chacun rescanner jusqu'a 40 unites.
    local g = Overlord.Sync and Overlord.Sync.GetGroupMemberGuild
        and Overlord.Sync:GetGroupMemberGuild(sender) or nil
    if g and Overlord.GuildKeep and Overlord.GuildKeep.SanitizeGuildName then
        return Overlord.GuildKeep:SanitizeGuildName(g)
    end
    return g
end

-- GC : emetteur addon groupe = meme guilde que le payload (pas de BNet aveugle)
local function GcSenderMatchesPayloadGuild(sender, guild)
    guild = (Overlord.GuildKeep and Overlord.GuildKeep.SanitizeGuildName)
        and Overlord.GuildKeep:SanitizeGuildName(guild or "") or (guild or "")
    if not sender or sender == "" or guild == "" then return false end
    if sender:find("^BNet%-", 1) then return false end
    if not SyncSenderIsInOurGroup(sender) then return false end
    local senderGuild = GetAddonSenderGuild(sender)
    if senderGuild and senderGuild ~= "" then
        return senderGuild == guild
    end
    return false
end

-- Final direct du porteur deja observe : l'identite doit egaler l'autorite d'un heartbeat
-- direct recent et la guilde/faction du siege courant. Le transport peut etre groupe,
-- canal ou communaute sans permettre a un simple relais de s'auto-proclamer capteur.
local function GkSenderMatchesObservedCapturer(siteKey, sender, guild, fac)
    local GK = Overlord.GuildKeep
    local st = GK and GK.GetState and GK:GetState(siteKey)
    if not st or st.status ~= "in_progress" then return false end

    guild = GK:SanitizeGuildName(guild or "")
    local assaultGuild = GK:SanitizeGuildName(st.canonicalAssaultGuild or "")
    if assaultGuild == "" then
        assaultGuild = GK:SanitizeGuildName(st.ownerGuild or "")
    end
    local assaultFac = st.canonicalAssaultFaction or st.ownerFaction
    if guild == "" or guild ~= assaultGuild or not fac or fac ~= assaultFac then return false end

    local senderKey = GkRosterMatchKey(sender)
    if senderKey == "" then return false end
    local officialKey = GkRosterMatchKey(st.gkOfficialCapturerName or "")
    if officialKey == "" or senderKey ~= officialKey then return false end
    local verifiedAt = st._gkVerifiedCapturerKeys
        and tonumber(st._gkVerifiedCapturerKeys[senderKey]) or 0
    -- La continuite ne vaut que pour le siege actif et un heartbeat direct recent. Elle
    -- couvre un GetGuildInfo nil au moment du final sans transformer un nom relaye en preuve.
    return verifiedAt > 0 and GetTime() - verifiedAt <= 30
end

local function GkSenderMatchesNamedPlayer(sender, player)
    local senderKey = GkRosterMatchKey(sender or "")
    local playerKey = GkRosterMatchKey(player or "")
    return senderKey ~= "" and playerKey ~= "" and senderKey == playerKey
end

local function GkKnownAnchorMatches(
    status, st, guild, faction, shard, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    local GK = Overlord.GuildKeep
    if not GK or not st then return false end
    if status == "in_progress" then
        return GK.ActiveAssaultAnchorMatches and GK:ActiveAssaultAnchorMatches(
            st, guild, faction, shard, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt) or false
    elseif status == "held" then
        return GK.FinalAssaultAnchorMatches and GK:FinalAssaultAnchorMatches(
            st, guild, faction, shard, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt) or false
    elseif status == "aborted" then
        return GK.AbortedAssaultAnchorMatches and GK:AbortedAssaultAnchorMatches(
            st, guild, faction, shard, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt) or false
    end
    return false
end

-- GC/GA groupe+canal peut preceder de quelques millisecondes le GK terminal enrichi. Le
-- premier paquet enregistre alors l'Anchor comme autorite de secours. Si le GK trusted suivant
-- prouve exactement le meme terminal, autoriser une unique promotion vers son successeur sans
-- rejouer capture, score, immersion ou alertes. Une autorite deja promue ne retrograde jamais.
local function RefreshExactGuildKeepTerminalAuthority(
    status, st, eventAt, authorityPlayer,
    guild, faction, shard, startedAt, generationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    local GK = Overlord.GuildKeep
    authorityPlayer = NormalizeGkCapturerName(authorityPlayer)
    anchorPlayer = NormalizeGkCapturerName(anchorPlayer)
    eventAt = math.floor(tonumber(eventAt) or 0)
    if not GK or not st or authorityPlayer == "" or anchorPlayer == "" or eventAt <= 0 then
        return false, false
    end

    local field, exact
    if status == "held" then
        exact = st.status == "held"
            and math.floor(tonumber(st.finalAssaultCapturedAt) or 0) == eventAt
            and GK.FinalAssaultAnchorMatches and GK:FinalAssaultAnchorMatches(
                st, guild, faction, shard, startedAt, generationAt, anchorPlayer,
                baseGuild, baseFaction, baseCapturedAt)
        field = "finalAssaultAuthorityPlayer"
    elseif status == "aborted" then
        exact = GK.IsAbortedAssaultTerminalCurrent
            and GK:IsAbortedAssaultTerminalCurrent(st)
            and math.floor(tonumber(st.abortedAssaultAt) or 0) == eventAt
            and GK.AbortedAssaultAnchorMatches and GK:AbortedAssaultAnchorMatches(
                st, guild, faction, shard, startedAt, generationAt, anchorPlayer,
                baseGuild, baseFaction, baseCapturedAt)
        field = "abortedAssaultAuthorityPlayer"
    end
    if not exact or not field then return false, false end

    local current = NormalizeGkCapturerName(st[field])
    local currentKey = GkRosterMatchKey(current)
    local authorityKey = GkRosterMatchKey(authorityPlayer)
    if authorityKey == "" then return false, false end
    if currentKey == authorityKey then return true, false end
    local elected = GK.ChooseTerminalAuthority
        and GK:ChooseTerminalAuthority(anchorPlayer, current, authorityPlayer)
        or authorityPlayer
    if GkRosterMatchKey(elected) == currentKey then return true, false end
    st[field] = elected
    if GK.MarkDirty then GK:MarkDirty() elseif Overlord.MarkDirty then Overlord:MarkDirty() end
    return true, true
end

local function ShouldAcceptGuildKeepCapture(
    siteKey, guild, fac, remoteTs, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    local GK = Overlord.GuildKeep
    local st = GK and GK.GetState and GK:GetState(siteKey)
    if not st then return false end
    remoteTs = math.floor(tonumber(remoteTs) or 0)
    anchorStartedAt = math.floor(tonumber(anchorStartedAt) or 0)
    local attemptStartedAt = GK.GetAssaultAttemptStartedAt
        and math.floor(tonumber(GK:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    if remoteTs <= 0 or anchorStartedAt <= 0 or attemptStartedAt <= 0
        or remoteTs < attemptStartedAt
        or remoteTs > NetworkNow() + MAX_CLOCK_SKEW
        or IsStaleCampaignTimestamp(remoteTs) then return false end
    if GK.GetServerSiegeDayKey
        and GK:GetServerSiegeDayKey(anchorStartedAt) ~= GK:GetServerSiegeDayKey(remoteTs) then
        return false
    end
    if GK.IsSiegeGameplayTimestampAllowed
        and not GK:IsSiegeGameplayTimestampAllowed(remoteTs) then return false end
    -- Les terminaux -60 s restent verifiables meme si ce client a manque le GK
    -- initial qui transportait le contrat d'attaque d'or.
    local req = GK.GetMinimumHoldTimeRequired
        and GK:GetMinimumHoldTimeRequired(GK:GetSite(siteKey)) or nil
    if not req or remoteTs - attemptStartedAt < math.max(0, req - 1) then return false end
    guild = GK:SanitizeGuildName(guild or "")
    if guild == "" or (fac ~= "Alliance" and fac ~= "Horde") then return false end
    local repairsPriorBase = GK.IsPriorCaptureCorrectionForCurrentLineage
        and GK:IsPriorCaptureCorrectionForCurrentLineage(
            st, guild, fac, anchorShard, anchorStartedAt,
            anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt, remoteTs, siteKey)
    local captureCandidate = {
        kind = "GC", eventAt = remoteTs, guild = guild, faction = fac,
        shard = anchorShard, startedAt = anchorStartedAt,
        generationAt = anchorGenerationAt, player = anchorPlayer,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }
    local repairsAbortedDescendant = repairsPriorBase
        and GK.IsCaptureCausalPredecessorOfAbortedAssault
        and GK:IsCaptureCausalPredecessorOfAbortedAssault(st, captureCandidate)
    local repairsAbortedRetry = GK.IsCaptureRepairForActiveRetry
        and GK:IsCaptureRepairForActiveRetry(
            st, guild, fac, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    if not repairsAbortedDescendant and not repairsAbortedRetry
        and GK.IsCaptureCandidateBlockedByAbort
        and GK:IsCaptureCandidateBlockedByAbort(
            st, guild, fac, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt, remoteTs) then return false end
    if st.status == "in_progress" then
        return GK:ActiveAssaultAnchorMatches(
            st, guild, fac, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
            or GK:WouldAdoptAssaultAnchor(
                st, guild, fac, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
                baseGuild, baseFaction, baseCapturedAt)
            or repairsPriorBase
            or repairsAbortedRetry
    end
    if repairsPriorBase then return true end
    if GK.IsAssaultBaseCompatibleWithHeldState
        and not GK:IsAssaultBaseCompatibleWithHeldState(
            st, baseGuild, baseFaction, baseCapturedAt, anchorStartedAt) then return false end
    return GK:IsFinalAssaultCandidatePreferred(
        st, guild, fac, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, remoteTs)
end

local function ShouldAcceptGuildKeepAbort(
    siteKey, guild, fac, eventTs, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    local GK = Overlord.GuildKeep
    local st = GK and GK.GetState and GK:GetState(siteKey)
    if not st or not GK.CanAcceptGuildKeepAbort then return false end
    eventTs = math.floor(tonumber(eventTs) or 0)
    anchorStartedAt = math.floor(tonumber(anchorStartedAt) or 0)
    local attemptStartedAt = GK.GetAssaultAttemptStartedAt
        and math.floor(tonumber(GK:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    if eventTs <= 0 or anchorStartedAt <= 0 or attemptStartedAt <= 0
        or eventTs < attemptStartedAt
        or eventTs > NetworkNow() + MAX_CLOCK_SKEW
        or IsStaleCampaignTimestamp(eventTs) then return false end
    return GK:CanAcceptGuildKeepAbort(
        st, guild, fac, eventTs, anchorShard, anchorStartedAt,
        anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt)
end

-- Un final conserve son horloge wire : racine, offset de tentative et eventAt restent
-- identiques chez tous les recepteurs ; la duree repart bien de racine + offset.
local function NormalizeGuildKeepFinalTimestamp(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts <= 0 or ts > NetworkNow() + MAX_CLOCK_SKEW then return nil end
    return ts
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

IsStaleCampaignTimestamp = function(ts)
    local lastReset = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    return ts and ts > 0 and lastReset > 0 and ts < lastReset
end

-- Identite de campagne : fenetre hebdomadaire du reset officiel Blizzard (region-wide coherent),
-- pas le jour calendaire. Le jour (AAAAMMJJ) derivait selon le fuseau cote NA (mardi continental vs
-- mercredi Oceanique) et faisait rejeter les messages guild keep entre clients d'une meme region.
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

-- Validation ladder commune : quand deux epochs regionaux toleres encadrent le meme
-- evenement, la decision repose sur la preuve causale v8 partagee (GH),
-- jamais sur le seul reset local du receveur.
local function IsGuildKeepLeaderboardTimestampCurrent(ts, wireEpoch)
    ts = math.floor(tonumber(ts) or 0)
    wireEpoch = math.floor(tonumber(wireEpoch) or 0)
    if ts <= 0 then return false end
    if wireEpoch > 0 then
        if ts >= wireEpoch and ts < wireEpoch + 604800 then return true end
        return Overlord.CampaignEpochsMatch
            and Overlord:CampaignEpochsMatch(ts, wireEpoch) or false
    end
    local lb = Overlord.Leaderboard
    if lb and lb.IsTimestampInCurrentCampaign then
        return lb:IsTimestampInCurrentCampaign(ts)
    end
    return not IsStaleCampaignTimestamp(ts)
end

-- Timestamp sync : neutre vierge reste 0 (evite d'ecraser une capture locale).
-- Held en rattrapage (updatedAt=0) : utiliser claimedAt pour que les pairs puissent fusionner.
local function GuildKeepSyncTimestamp(st)
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

local VALID_POOL_TAG = { global = true }

local function NormalizePoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if VALID_POOL_TAG[pool] then return pool end
    return ""
end

local function CurrentGuildKeepPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizePoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function GuildKeepPayloadPoolMatchesLocal(remotePool)
    remotePool = NormalizePoolTag(remotePool)
    if remotePool == "" then return false end
    local localPool = CurrentGuildKeepPoolTag()
    return localPool ~= "" and remotePool == localPool
end

local function ResolveGuildKeepPayloadPool(remotePool, sender, sourceChannel)
    remotePool = NormalizePoolTag(remotePool)
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        return Overlord.Sync:ResolveDirectGroupTerritorialPool(
            remotePool, sender, sourceChannel)
    end
    return GuildKeepPayloadPoolMatchesLocal(remotePool) and remotePool or nil
end

local function GuildKeepPayloadHasExplicitLocalPool(remotePool)
    remotePool = NormalizePoolTag(remotePool)
    if remotePool == "" then return false end
    return GuildKeepPayloadPoolMatchesLocal(remotePool)
end

-- GH : le royaume expediteur doit correspondre au pool local.
local function SenderRealmMatchesCurrentPool(sender, sourceChannel)
    if sourceChannel == "BETA" and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:IsDispatching(sender)
    end
    if type(sender) ~= "string" or sender == "" then return false end
    if (sourceChannel == "PARTY" or sourceChannel == "RAID")
        and SyncSenderIsInOurGroup(sender) then return true end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return true end
    local localPool = CurrentGuildKeepPoolTag()
    if localPool == "" then return false end
    local rp = Overlord.RealmPools
    if not rp or not rp.GetOverlordPoolTag then return false end
    local realm = sender:match("^.-%-(.+)$")
    if not realm or realm == "" then return false end
    local senderPool = NormalizePoolTag(rp:GetOverlordPoolTag(realm))
    if senderPool == "" then return false end
    return senderPool == localPool
end

local function ResolveGkShardId(nameHint, shardHint)
    local sid = tonumber(shardHint)
    local shardMod = Overlord.Shard
    if not sid and shardMod and shardMod.ResolveKnownShardPlayer then
        local _, resolvedSid = shardMod:ResolveKnownShardPlayer(nameHint, true)
        sid = resolvedSid
        if not sid then
            _, sid = shardMod:ResolveKnownShardPlayer(nameHint, false)
        end
    end
    return sid
end

local function AppendGkShardTagToPlayerName(nameHint, shardHint)
    if not nameHint or nameHint == "" then return nameHint end
    local sid = ResolveGkShardId(nameHint, shardHint)
    if not sid then return nameHint end
    local tag = Overlord.L and Overlord.L.SHARD_ALERT_TAG
    if tag then
        return nameHint .. string.format(tag, tostring(sid))
    end
    return nameHint .. " #" .. tostring(sid)
end

-- Nom capteur dans l'alerte assaut : si le lecteur est hors shard, le lien lui fait
-- demander une invitation au porteur. Il ne tire jamais le porteur sur sa shard locale.
local function FormatGkCapturerForAlert(capturer, shardHint, siteKey)
    if not capturer or capturer == "" then return "" end
    local shardMod = Overlord.Shard
    local targetShard = ResolveGkShardId(capturer, shardHint)
    local display = AppendGkShardTagToPlayerName(capturer, targetShard)
    if not shardMod or not shardMod.BuildKeepInviteRequestHyperlink then return display end
    local currentShard
    if siteKey and siteKey ~= "" and shardMod.GetCaptureLocalShardID then
        currentShard = shardMod:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8)
    elseif shardMod.GetFreshLocalShardID then
        currentShard = shardMod:GetFreshLocalShardID(8)
    end
    if not targetShard or not currentShard or tonumber(targetShard) == currentShard then return display end
    if not shardMod:PartyInviteTargetIsUsable(capturer) then return display end
    if shardMod:IsPlayerAlreadyGrouped(capturer) then return display end
    if Overlord.UI and Overlord.UI.EnsureAddonLinkHandlers then
        Overlord.UI:EnsureAddonLinkHandlers()
    end
    local faction
    if Overlord.Leaderboard and Overlord.Leaderboard.GetExportPlayerMeta then
        _, faction = Overlord.Leaderboard:GetExportPlayerMeta(capturer)
    end
    local colorEsc = "|cffffffff"
    if faction == "Alliance" then
        colorEsc = "|cff6db3f2"
    elseif faction == "Horde" then
        colorEsc = "|cffff7359"
    end
    local link = shardMod:BuildKeepInviteRequestHyperlink(
        capturer, siteKey, targetShard, colorEsc, display)
    return link ~= "" and link or display
end

NormalizeGkCapturerName = function(name)
    if not name or type(name) ~= "string" then return "" end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t < 2 or #t > 50 then return "" end
    return t
end

local function RememberGkCapturerShard(capturerName, shardId)
    shardId = tonumber(shardId)
    if not capturerName or capturerName == "" or not shardId then return end
    if Overlord.Shard and Overlord.Shard.SetPlayerShard then
        Overlord.Shard:SetPlayerShard(capturerName, shardId)
    end
end

local function GkAnchorFieldsForPayload(st)
    if not st or (st.status or "") ~= "in_progress" then return nil end
    local GK = Overlord.GuildKeep
    if not GK or not GK.HasAssaultShardAnchor or not GK:HasAssaultShardAnchor(st) then return nil end
    local authorityPlayer = GK.GetEffectiveCapturerName
        and NormalizeGkCapturerName(GK:GetEffectiveCapturerName(st)) or ""
    if authorityPlayer == "" or st.assaultShardFaction ~= st.ownerFaction then return nil end
    return NormalizeGkCapturerName(st.assaultShardPlayer),
        tonumber(st.assaultShardId), math.floor(tonumber(st.assaultShardStartedAt) or 0),
        math.floor(tonumber(st.assaultGenerationAt) or 0), authorityPlayer,
        GK:SanitizeGuildName(st.assaultBaseGuild or ""),
        FactionToCode(st.assaultBaseFaction), math.floor(tonumber(st.assaultBaseCapturedAt) or 0)
end

-- Version semantique des quatre payloads. Elle est volontairement distincte de G7,
-- qui est seulement le nom historique de l'enveloppe de fragmentation.
-- Wire-only revision: saved v8 causal tuples remain valid; daily schedules do not.
local GK_WIRE_SEMANTIC_VERSION = "v9"
local function isGuildKeepSiegeKey(key)
    if type(key) ~= "string" or not key:match("^%d+$") then return false end
    if #key == 8 then return true end
    local hour = #key == 10 and tonumber(key:sub(9, 10))
    return hour == 3 or hour == 9 or hour == 15 or hour == 21
end

-- G7 fragmente uniquement les rares payloads UTF-8 qui depassent la limite
-- SendAddonMessage. L'identite/hash porte le payload complet ; aucun fragment
-- partiel ne peut muter l'etat et les recepteurs gardent des buffers bornes.
local GK_WIRE_FRAGMENT_TYPE = "G7"
local GK_WIRE_FRAGMENT_BYTES = 220
local GK_WIRE_MAX_PARTS = 5
local GK_WIRE_FRAGMENT_TTL = 90
local GK_WIRE_FRAGMENT_MAX_BATCHES = 64
local GK_WIRE_ALLOWED = { GK = true, GC = true, GA = true, GH = true }

local function GuildKeepWireHash(msgType, payload)
    local h = 5381
    local s = tostring(msgType or "") .. "\031" .. tostring(payload or "")
    for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 2147483647 end
    return tostring(#payload) .. "-" .. tostring(h)
end

local function SplitGuildKeepWirePayload(payload)
    local chunks, pos = {}, 1
    while pos <= #payload do
        local last = math.min(#payload, pos + GK_WIRE_FRAGMENT_BYTES - 1)
        if last < #payload then
            while last >= pos do
                local nextByte = string.byte(payload, last + 1)
                if not nextByte or nextByte < 128 or nextByte > 191 then break end
                last = last - 1
            end
        end
        if last < pos then return nil end
        chunks[#chunks + 1] = payload:sub(pos, last)
        if #chunks > GK_WIRE_MAX_PARTS then return nil end
        pos = last + 1
    end
    return chunks
end

function Overlord.Sync:BuildGuildKeepWireMessages(msgType, payload)
    if not GK_WIRE_ALLOWED[msgType] or type(payload) ~= "string" or payload == "" then return nil end
    if #(msgType .. ":" .. payload) <= 255 then
        return { { type = msgType, data = payload } }
    end
    local chunks = SplitGuildKeepWirePayload(payload)
    if not chunks or #chunks < 2 then return nil end
    local id, messages = GuildKeepWireHash(msgType, payload), {}
    for i, chunk in ipairs(chunks) do
        local data = table.concat({ "1", msgType, id, tostring(i), tostring(#chunks), chunk }, ":")
        if #(GK_WIRE_FRAGMENT_TYPE .. ":" .. data) > 255 then return nil end
        messages[#messages + 1] = { type = GK_WIRE_FRAGMENT_TYPE, data = data }
    end
    return messages
end

local function AppendGuildKeepWireToQueue(queue, msgType, payload)
    local messages = Overlord.Sync:BuildGuildKeepWireMessages(msgType, payload)
    if not messages then return false end
    for _, message in ipairs(messages) do
        queue[#queue + 1] = message
    end
    return true
end

-- Les helpers ci-dessous transportent aussi WB, dont le payload est court et
-- n'appartient pas au protocole causal v8. Le conserver brut sans l'autoriser
-- dans G7 evite qu'un fragment puisse contourner son receveur dedie.
local function BuildGuildKeepTransportMessages(msgType, payload)
    if type(payload) ~= "string" or payload == "" then return nil end
    if GK_WIRE_ALLOWED[msgType] then
        return Overlord.Sync:BuildGuildKeepWireMessages(msgType, payload)
    end
    if #(tostring(msgType or "") .. ":" .. payload) > 255 then return nil end
    return { { type = msgType, data = payload } }
end

local pendingGuildKeepFragments = {}

function Overlord.Sync:OnReceiveGuildKeepFragment(payload, sender, sourceChannel)
    if type(payload) ~= "string" or payload == "" or not sender or sender == "" then return end
    local version, msgType, id, indexStr, totalStr, chunk = strsplit(":", payload, 6)
    local index, total = tonumber(indexStr), tonumber(totalStr)
    if version ~= "1" or not GK_WIRE_ALLOWED[msgType]
        or type(id) ~= "string" or not id:match("^%d+%-%d+$")
        or not index or not total or index ~= math.floor(index) or total ~= math.floor(total)
        or index < 1 or total < 2 or index > total or total > GK_WIRE_MAX_PARTS
        or type(chunk) ~= "string" or chunk == "" or #chunk > GK_WIRE_FRAGMENT_BYTES then return end
    local now, count, oldestKey, oldestAt = GetTime(), 0, nil, nil
    for key, row in pairs(pendingGuildKeepFragments) do
        if now - (row.at or 0) > GK_WIRE_FRAGMENT_TTL then
            pendingGuildKeepFragments[key] = nil
        else
            count = count + 1
            if not oldestAt or row.at < oldestAt then oldestKey, oldestAt = key, row.at end
        end
    end
    local senderKey = GkRosterMatchKey(sender)
    if senderKey == "" then return end
    local key = table.concat({ sourceChannel or "", senderKey, msgType, id }, "\031")
    local row = pendingGuildKeepFragments[key]
    if not row then
        if count >= GK_WIRE_FRAGMENT_MAX_BATCHES and oldestKey then
            pendingGuildKeepFragments[oldestKey] = nil
        end
        row = { at = now, total = total, chunks = {}, count = 0 }
        pendingGuildKeepFragments[key] = row
    elseif row.total ~= total then
        pendingGuildKeepFragments[key] = nil
        return
    end
    if row.chunks[index] and row.chunks[index] ~= chunk then
        pendingGuildKeepFragments[key] = nil
        return
    end
    if not row.chunks[index] then
        row.chunks[index], row.count = chunk, row.count + 1
    end
    row.at = now
    if row.count ~= row.total then return end
    local full = table.concat(row.chunks)
    pendingGuildKeepFragments[key] = nil
    if GuildKeepWireHash(msgType, full) ~= id then return end
    if msgType == "GK" then
        return self:OnReceiveGuildKeepState(full, sender, sourceChannel)
    elseif msgType == "GC" then
        return self:OnReceiveGuildKeepCapture(full, sender, sourceChannel)
    elseif msgType == "GA" then
        return self:OnReceiveGuildKeepAbort(full, sender, sourceChannel)
    elseif msgType == "GH" then
        return self:OnReceiveGuildKeepDailyProof(full, sender, sourceChannel)
    end
end

local function GkFinalFieldsForPayload(st)
    if not st or (st.status or "") ~= "held" then return nil end
    local GK = Overlord.GuildKeep
    local terminal = GK and GK.GetCurrentTerminalProof
        and GK:GetCurrentTerminalProof(st) or nil
    if not terminal or terminal.kind ~= "GC" then return nil end
    local shardId = tonumber(st.finalAssaultShardId)
    local startedAt = math.floor(tonumber(st.finalAssaultStartedAt) or 0)
    local generationAt = math.floor(tonumber(st.finalAssaultGenerationAt) or 0)
    local player = NormalizeGkCapturerName(st.finalAssaultPlayer)
    local authorityPlayer = NormalizeGkCapturerName(st.finalAssaultAuthorityPlayer)
    local capturedAt = math.floor(tonumber(st.finalAssaultCapturedAt) or 0)
    local guild = GK:SanitizeGuildName(st.finalAssaultGuild or "")
    local baseGuild = GK:SanitizeGuildName(st.finalAssaultBaseGuild or "")
    local baseFactionCode = FactionToCode(st.finalAssaultBaseFaction)
    local baseCapturedAt = math.floor(tonumber(st.finalAssaultBaseCapturedAt) or 0)
    local validBase = (baseGuild == "" and baseFactionCode == "" and baseCapturedAt == 0)
        or (baseGuild ~= "" and baseFactionCode ~= "" and baseCapturedAt > 0)
    if not shardId or shardId < 0 or shardId >= 100000000 or shardId ~= math.floor(shardId)
        or startedAt <= 0 or capturedAt <= 0 or player == "" or guild == ""
        or guild ~= GK:SanitizeGuildName(st.ownerGuild or "")
        or st.finalAssaultFaction ~= st.ownerFaction or not validBase then return nil end
    if authorityPlayer == "" then authorityPlayer = player end
    return player, shardId, startedAt, generationAt, authorityPlayer,
        baseGuild, baseFactionCode, baseCapturedAt
end

local function GkAbortFieldsForPayload(st)
    local GK = Overlord.GuildKeep
    if not st or not GK or not GK.HasAbortedAssaultAnchor
        or not GK:HasAbortedAssaultAnchor(st) then return nil end
    local guild = GK:SanitizeGuildName(st.abortedAssaultGuild or "")
    local factionCode = FactionToCode(st.abortedAssaultFaction)
    local shardId = tonumber(st.abortedAssaultShardId)
    local startedAt = math.floor(tonumber(st.abortedAssaultStartedAt) or 0)
    local generationAt = math.floor(tonumber(st.abortedAssaultGenerationAt) or 0)
    local player = NormalizeGkCapturerName(st.abortedAssaultPlayer)
    local authorityPlayer = NormalizeGkCapturerName(st.abortedAssaultAuthorityPlayer)
    local abortedAt = math.floor(tonumber(st.abortedAssaultAt) or 0)
    local baseGuild = GK:SanitizeGuildName(st.abortedAssaultBaseGuild or "")
    local baseFactionCode = FactionToCode(st.abortedAssaultBaseFaction)
    local baseCapturedAt = math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0)
    local validBase = (baseGuild == "" and baseFactionCode == "" and baseCapturedAt == 0)
        or (baseGuild ~= "" and baseFactionCode ~= "" and baseCapturedAt > 0)
    local attemptStartedAt = GK.GetAssaultAttemptStartedAt
        and math.floor(tonumber(GK:GetAssaultAttemptStartedAt(
            startedAt, generationAt)) or 0) or 0
    if guild == "" or factionCode == "" or not shardId or startedAt <= 0
        or attemptStartedAt <= 0 or player == ""
        or abortedAt < attemptStartedAt or not validBase then return nil end
    if authorityPlayer == "" then authorityPlayer = player end
    return guild, factionCode, abortedAt, player, shardId, startedAt, generationAt,
        baseGuild, baseFactionCode, baseCapturedAt, authorityPlayer
end

-- GK v8 fixe : tenure, racine Anchor et offset de tentative forment l'identite.
-- Un snapshot held transporte exactement la meme preuve que GC.
local function BuildGuildKeepPayload(siteKey, st)
    if not siteKey or not st or not Overlord.GuildKeep then return nil end
    local GK = Overlord.GuildKeep
    local status = st.status or "neutral"
    if status ~= "in_progress" and GK.IsAbortedAssaultTerminalCurrent
        and GK:IsAbortedAssaultTerminalCurrent(st) then status = "aborted" end
    if status ~= "neutral" and status ~= "in_progress"
        and status ~= "held" and status ~= "aborted" then return nil end
    if status == "in_progress" and GK.IsCurrentKeepSiegeState
        and not GK:IsCurrentKeepSiegeState(st) then return nil end

    local guild = status == "neutral" and "" or GK:SanitizeGuildName(st.ownerGuild or "")
    local factionCode = status == "neutral" and "" or FactionToCode(st.ownerFaction)
    local abortFields
    if status == "aborted" then
        abortFields = { GkAbortFieldsForPayload(st) }
        if not abortFields[1] then return nil end
        guild, factionCode = abortFields[1], abortFields[2]
    end
    if status ~= "neutral" and (guild == "" or factionCode == "") then return nil end
    local claimedAt = status == "held" and math.floor(tonumber(st.claimedAt) or 0) or 0
    if status == "aborted" then claimedAt = abortFields[3] end
    local holdTime = status == "in_progress"
        and math.floor(tonumber(st.holdTimeElapsed) or 0) or 0
    local syncTs = status == "aborted" and abortFields[3] or GuildKeepSyncTimestamp(st)
    local holdReq = math.floor(GK:GetDefaultHoldTimeRequired(st, GK:GetSite(siteKey)))
    local pool = CurrentGuildKeepPoolTag()
    if pool == "" then return nil end
    if status ~= "neutral" and NormalizePoolTag(st.pool) ~= pool then
        return nil
    end
    local contested = status == "in_progress" and st.isContested and 1 or 0

    local anchorPlayer, anchorShard, anchorStartedAt, anchorGenerationAt, authorityPlayer =
        "", "", 0, 0, ""
    local baseGuild, baseFactionCode, baseCapturedAt = "", "", 0
    if status == "in_progress" then
        anchorPlayer, anchorShard, anchorStartedAt, anchorGenerationAt, authorityPlayer,
            baseGuild, baseFactionCode, baseCapturedAt = GkAnchorFieldsForPayload(st)
        if not anchorPlayer then return nil end
    elseif status == "held" then
        anchorPlayer, anchorShard, anchorStartedAt, anchorGenerationAt, authorityPlayer,
            baseGuild, baseFactionCode, baseCapturedAt = GkFinalFieldsForPayload(st)
        if not anchorPlayer then return nil end
    elseif status == "aborted" then
        anchorPlayer, anchorShard, anchorStartedAt, anchorGenerationAt =
            abortFields[4], abortFields[5], abortFields[6], abortFields[7]
        baseGuild, baseFactionCode, baseCapturedAt =
            abortFields[8], abortFields[9], abortFields[10]
        authorityPlayer = abortFields[11] or ""
    end

    local payload = GK_WIRE_SEMANTIC_VERSION .. ":" .. table.concat({
        siteKey, status, tostring(holdTime), guild, factionCode, tostring(claimedAt),
        tostring(syncTs), tostring(holdReq), pool, tostring(contested),
        baseGuild, baseFactionCode, tostring(baseCapturedAt), anchorPlayer,
        tostring(anchorShard), tostring(anchorStartedAt), tostring(anchorGenerationAt),
        authorityPlayer,
    }, ":")
    return payload
end

local pendingGkFinals = {}
local pendingGkAborts = {}
local pendingGkCriticalFlushQueued = false
-- GH v8 porte directement la preuve causale et le score quotidien.
local pendingGhBroadcasts = {}

local function QueuePendingGuildKeepDailyProof(siteKey, dayKey)
    if not siteKey or not dayKey then return end
    local key = tostring(siteKey) .. ":" .. tostring(dayKey)
    for _, row in ipairs(pendingGhBroadcasts) do
        if row.key == key then return end
    end
    if #pendingGhBroadcasts < 64 then
        pendingGhBroadcasts[#pendingGhBroadcasts + 1] = {
            key = key, siteKey = siteKey, dayKey = dayKey,
        }
    end
end

local function QueuePendingGuildKeepTerminal(list, entry)
    if not list or not entry or not entry[1] then return end
    local GK = Overlord.GuildKeep
    for i = 1, #list do
        local current = list[i]
        if current and current[1] == entry[1] then
            local candidateWins = GK and GK.AssaultIdentityWins and GK:AssaultIdentityWins(
                entry[2], entry[3], entry[5], entry[6], entry[7], entry[8],
                entry[9], entry[10], entry[11],
                current[2], current[3], current[5], current[6], current[7], current[8],
                current[9], current[10], current[11])
            local currentWins = GK and GK.AssaultIdentityWins and GK:AssaultIdentityWins(
                current[2], current[3], current[5], current[6], current[7], current[8],
                current[9], current[10], current[11],
                entry[2], entry[3], entry[5], entry[6], entry[7], entry[8],
                entry[9], entry[10], entry[11])
            if candidateWins or (not currentWins and (entry[4] or 0) >= (current[4] or 0)) then
                list[i] = entry
            end
            return
        end
    end
    -- Six keep sites existent ; la marge evite toute croissance non bornee en cas de
    -- SavedVariables corrompues ou de futurs sites ajoutes sans revoir la pompe.
    if #list < 24 then list[#list + 1] = entry end
end

local function GuildKeepCriticalFlushBlocked()
    if GuildKeepSyncBlocked() or Overlord.WaitingForSync then return true end
    if Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive() then return true end
    return false
end

local function ScheduleGkCriticalFlushRetry()
    if pendingGkCriticalFlushQueued then return end
    if #pendingGkFinals == 0 and #pendingGkAborts == 0
        and #pendingGhBroadcasts == 0 then return end
    pendingGkCriticalFlushQueued = true
    C_Timer.After(9, function()
        pendingGkCriticalFlushQueued = false
        if Overlord.Sync and Overlord.Sync.FlushPendingGuildKeepCriticalBroadcasts then
            Overlord.Sync:FlushPendingGuildKeepCriticalBroadcasts()
        end
    end)
end

function Overlord.Sync:FlushPendingGuildKeepCriticalBroadcasts()
    if GuildKeepCriticalFlushBlocked()
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()) then
        ScheduleGkCriticalFlushRetry()
        return
    end
    local list = pendingGkFinals
    pendingGkFinals = {}
    for _, e in ipairs(list) do
        local siteKey, guild, fac, captureTs = e[1], e[2], e[3], e[4]
        if siteKey and guild and guild ~= "" and fac then
            self:BroadcastGuildKeepCapture(siteKey, guild, fac, captureTs,
                e[5], e[6], e[7], e[8], e[9], e[10], e[11])
        end
    end
    local aborts = pendingGkAborts
    pendingGkAborts = {}
    for _, e in ipairs(aborts) do
        self:BroadcastGuildKeepAbort(
            e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], e[11])
    end
    local ghList = pendingGhBroadcasts
    pendingGhBroadcasts = {}
    for _, e in ipairs(ghList) do
        if e.siteKey and e.dayKey then
            self:BroadcastGuildKeepDailyProof(e.siteKey, e.dayKey, true)
        end
    end
end

function Overlord.Sync:BuildGuildKeepPayload(siteKey)
    if not siteKey or not Overlord.GuildKeep then return nil end
    local st = Overlord.GuildKeep:GetState(siteKey)
    if not st then return nil end
    if Overlord.GuildKeep.IsKeepStateAwaitingNetworkSnapshot
        and Overlord.GuildKeep:IsKeepStateAwaitingNetworkSnapshot(st) then
        -- Ne pas republier un tenant restaure du disque avant confirmation reseau.
        return nil
    end
    return BuildGuildKeepPayload(siteKey, st)
end

local function GetGroupSenderFaction(sender)
    return Overlord.Sync and Overlord.Sync.GetGroupMemberFaction
        and Overlord.Sync:GetGroupMemberFaction(sender) or nil
end

-- GK : communaute + groupe/raid + canal meme faction pour snapshots.
-- GC : evenement final critique, toujours lie a l'ancre immutable du siege.
function Overlord.Sync:IsGuildKeepSenderTrusted(sender, remoteFaction, sourceChannel, msgType, remoteStatus)
    if not sender or sender == "" then return false end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return false end
    local pf = Overlord.PlayerFaction
    if not pf or pf == "" then return false end

    if self.IsGuildKeepCommunitySender and self:IsGuildKeepCommunitySender(sender) then
        return true
    end

    -- Canal : chemin critique meme-royaume. Le canal custom est par faction, donc l'EMETTEUR
    -- est forcement de notre faction ; la faction du PAYLOAD, elle, peut etre ennemie : les
    -- captures de fortin sont par nature cross-faction et un defenseur doit pouvoir relayer
    -- l'etat du siege ennemi a son propre canal (sinon tout son cote reste aveugle, cf. events 21h).
    -- Securite : pool + campagne + fenetre siege (GK in_progress) + claimedAt/captureTs
    -- (ApplyRemoteState / ShouldAcceptGuildKeepCapture), comme indique pour GC.
    if sourceChannel == "CHANNEL" and (msgType == "GK" or msgType == "GC" or msgType == "GA" or msgType == "GH" or msgType == "WB"
        or msgType == "LO" or msgType == "LOC" or msgType == "OE"
        or msgType == "OP" or msgType == "OC") then
        return true
    end

    -- GK in_progress + terminaux : etats bornes par pool/site/timestamp et identite v8.
    -- En raid Warmode mixte, UnitFactionGroup peut etre indisponible pour l'autre faction :
    -- n'exiger la meme faction que pour les messages GK routine (bois, held tick).
    if SyncSenderIsInOurGroup(sender) then
        if msgType == "GK" and (remoteStatus == "in_progress"
            or remoteStatus == "held" or remoteStatus == "aborted") then
            return true
        end
        if msgType == "GC" or msgType == "GA" or msgType == "GH" or msgType == "LO"
            or msgType == "LOC" or msgType == "OE" or msgType == "OC" then
            return true
        end
        if msgType == "OP" and remoteStatus == "in_progress" then
            return true
        end
        local sf = GetGroupSenderFaction(sender)
        return sf and sf == pf
    end
    return false
end

-- Raid / party uniquement (Send ne tombe pas sur le canal si en groupe).
local function BroadcastGuildKeepToGroup(msgType, payload)
    if not payload or payload == "" then return false end
    if not IsInGroup or not IsInGroup() then return false end
    if Overlord.Sync and Overlord.Sync.Send then
        local messages = BuildGuildKeepTransportMessages(msgType, payload)
        if not messages then return false end
        local sent = true
        for _, message in ipairs(messages) do
            if not Overlord.Sync:Send(message.type, message.data) then sent = false end
        end
        return sent
    end
    return false
end

local function SendGuildKeepToChannel(msgType, payload, critical)
    local messages = Overlord.Sync:BuildGuildKeepWireMessages(msgType, payload)
    if not messages then return false end
    local sent = true
    for _, message in ipairs(messages) do
        if not Overlord.Sync:SendToChannel(message.type, message.data, critical) then sent = false end
    end
    return sent
end

-- GK routine : tourniquet + cooldown 8s par cible (anti-spam).
local function BroadcastGuildKeepToCommunityOnly(msgType, payload, maxMembers, whisperDelaySec)
    if not payload or payload == "" then return end
    if Overlord.Sync and Overlord.Sync.BroadcastGuildKeepToCommunity then
        local messages = Overlord.Sync:BuildGuildKeepWireMessages(msgType, payload)
        if not messages then return end
        local extras = {}
        for i = 2, #messages do
            extras[#extras + 1] = { type = messages[i].type, payload = messages[i].data }
        end
        Overlord.Sync:BroadcastGuildKeepToCommunity(
            messages[1].type, messages[1].data, maxMembers, whisperDelaySec,
            extras, 30)
    end
end

-- GC / GK post-capture : meme chemin que BroadcastCapture C (pas de rotation ni cooldown 8s).
local function BroadcastGuildKeepCaptureToCommunity(
    msgType, payload, maxMembers, whisperDelaySec, forceTargets)
    if not payload or payload == "" then return false end
    if Overlord.Sync and Overlord.Sync.BroadcastToCommunity then
        local messages = BuildGuildKeepTransportMessages(msgType, payload)
        if not messages then return false end
        local extras = {}
        for i = 2, #messages do
            extras[#extras + 1] = { type = messages[i].type, payload = messages[i].data }
        end
        return Overlord.Sync:BroadcastToCommunity(
            messages[1].type, messages[1].data, maxMembers, whisperDelaySec,
            forceTargets, extras)
    end
    return false
end

-- Reponse SR complete : inclure GK/WB (whisper direct, pas le canal). En reponse
-- minimale gros event : tous les sieges in_progress + tous les tenants held (6 sites max).
function Overlord.Sync:AppendGuildKeepToSrQueue(queue, minimalResponseOnly)
    if not queue or not Overlord.GuildKeep or not Overlord.GuildKeepSites then return end
    if minimalResponseOnly then
        local queued = {}
        for siteKey in pairs(Overlord.GuildKeepSites) do
            local st = Overlord.GuildKeep:GetState(siteKey)
            if st and (st.status == "in_progress"
                or (Overlord.GuildKeep.IsAbortedAssaultTerminalCurrent
                    and Overlord.GuildKeep:IsAbortedAssaultTerminalCurrent(st))) then
                local gkData = self.BuildGuildKeepPayload and self:BuildGuildKeepPayload(siteKey)
                if gkData then
                    AppendGuildKeepWireToQueue(queue, "GK", gkData)
                    queued[siteKey] = true
                end
            end
        end
        -- Rattrapage tenant : inclure tous les held confirmes (peu de sites, filet anti-desync).
        for siteKey in pairs(Overlord.GuildKeepSites) do
            if not queued[siteKey] then
                local st = Overlord.GuildKeep:GetState(siteKey)
                if st and st.status == "held" and (st.ownerGuild or "") ~= "" then
                    local gkData = self.BuildGuildKeepPayload and self:BuildGuildKeepPayload(siteKey)
                    if gkData then
                        AppendGuildKeepWireToQueue(queue, "GK", gkData)
                    end
                end
            end
        end
        return
    end
    for siteKey in pairs(Overlord.GuildKeepSites) do
        local gkData = self.BuildGuildKeepPayload and self:BuildGuildKeepPayload(siteKey)
        if gkData then
            AppendGuildKeepWireToQueue(queue, "GK", gkData)
        end
    end
end

local function BuildGuildKeepDailyProofPayload(row, pool)
    if not row then return nil end
    local epoch = row.epoch
    local siteKey, dayKey = row.siteKey, row.dayKey
    pool = NormalizePoolTag(pool or row.pool)
    row = Overlord.Leaderboard and Overlord.Leaderboard.NormalizeGuildKeepDailyProof
        and Overlord.Leaderboard:NormalizeGuildKeepDailyProof(
            siteKey, dayKey, row) or nil
    if not row or pool == "" or row.pool ~= pool then return nil end
    local facCode, baseFacCode = FactionToCode(row.faction), FactionToCode(row.baseFaction)
    if facCode == "" or not siteKey or not dayKey
        or (row.kind ~= "GC" and row.kind ~= "GA") then return nil end
    local payload = table.concat({
        GK_WIRE_SEMANTIC_VERSION, siteKey, dayKey, row.kind, tostring(row.eventAt or 0),
        row.guild or "", facCode, row.baseGuild or "", baseFacCode,
        tostring(row.baseCapturedAt or 0), tostring(row.shard or ""),
        tostring(row.startedAt or 0), tostring(row.generationAt or 0),
        row.player or "", tostring(epoch or 0), pool,
    }, ":")
    return payload
end

-- GH v8 est a la fois la preuve de cloture et l'autorite du score quotidien.
function Overlord.Sync:AppendLeaderboardGuildKeepDailyProofsToSrQueue(queue)
    if not queue or not Overlord.Leaderboard
        or not Overlord.Leaderboard.BuildGuildKeepDailyProofSyncRows then return end
    local pool = CurrentGuildKeepPoolTag()
    if pool == "" then return end
    for _, row in ipairs(Overlord.Leaderboard:BuildGuildKeepDailyProofSyncRows()) do
        local payload = BuildGuildKeepDailyProofPayload(row, pool)
        if payload then
            AppendGuildKeepWireToQueue(queue, "GH", payload)
        end
    end
end

-- Emetteur dans notre groupe / raid (format Name-Realm addon)
SyncSenderIsInOurGroup = function(sender)
    return Overlord.Sync and Overlord.Sync.SenderIsInOurGroup
        and Overlord.Sync:SenderIsInOurGroup(sender) or false
end

local function PruneGkDedup(now)
    PruneGuildKeepDedup(gkDedup, now)
    PruneGuildKeepDedup(gcDedup, now)
end

local function SnapshotGuildKeepAlertState(st)
    if not st then return nil end
    return {
        status = st.status,
        ownerGuild = st.ownerGuild or "",
        ownerFaction = st.ownerFaction,
        previousOwnerGuild = st.previousOwnerGuild or "",
        previousOwnerFaction = st.previousOwnerFaction,
        holdTimeElapsed = math.floor(tonumber(st.holdTimeElapsed) or 0),
        isContested = st.isContested and true or false,
        updatedAt = st.updatedAt or 0,
        gkRelayCapturerName = st.gkRelayCapturerName,
        gkRelayCapturerShard = st.gkRelayCapturerShard,
        gkOfficialCapturerName = st.gkOfficialCapturerName,
    }
end

-- Reinitialise l'alerte defense guilde (fin de conteste ou reprise du fortin).
local function ResetGuildKeepDefenderAlert(siteKey)
    if not siteKey then return end
    gkDefenderAlertLast[siteKey] = nil
    gkDefenderAlertEmitted[siteKey] = nil
    gkDefenderAlertInactiveSince[siteKey] = nil
end

-- Detection locale defenseur (GuildKeepControl) : memoriser l'alerte pour que le merge GK
-- qui arrivera ensuite (held -> in_progress) ne reimprime pas le meme avertissement.
function Overlord.Sync:NoteGuildKeepDefenderAlerted(siteKey)
    if not siteKey then return end
    gkDefenderAlertLast[siteKey] = GetTime()
    gkDefenderAlertEmitted[siteKey] = true
    gkDefenderAlertInactiveSince[siteKey] = nil
end

-- Alerte chat : apres merge GK, si notre guilde tenait le fortin et l'etat local est passe en in_progress (ennemi).
local function TryPrintGuildKeepDefenderAlert(siteKey, stBefore, stAfter)
    if not siteKey or not stBefore or not stAfter or not Overlord.GuildKeep then return end
    local GK = Overlord.GuildKeep
    local L = Overlord.L
    if not L or not L.GUILD_KEEP_UNDER_ATTACK then return end
    local localGuild = GK:GetLocalPlayerGuild()
    if localGuild == "" then return end
    local pf = Overlord.PlayerFaction
    if not pf then return end
    local heldGuild = GK.SanitizeGuildName and GK:SanitizeGuildName(stBefore.ownerGuild or "")
        or (stBefore.ownerGuild or "")
    -- Meme faction, guilde differente = fortin allie : alerte precoce aussi utile que pour
    -- notre propre guilde (GUILD_KEEP_ALLIED_UNDER_ATTACK), pas seulement CheckLocalKeepDefense
    -- qui exige d'etre deja physiquement sur le disque.
    if stBefore.status ~= "held" or heldGuild == "" then return end
    if stBefore.ownerFaction ~= pf then return end
    local isOwnGuild = heldGuild == localGuild
    local rFac = stAfter.ownerFaction
    local rGuild = GK.SanitizeGuildName and GK:SanitizeGuildName(stAfter.ownerGuild or "")
        or (stAfter.ownerGuild or "")
    if stAfter.status ~= "in_progress" then return end
    if not rFac or rFac == pf then return end
    if rGuild ~= "" and rGuild == localGuild then return end

    local nowAlert = GetTime()
    local inactiveSince = gkDefenderAlertInactiveSince[siteKey]
    if inactiveSince and nowAlert - inactiveSince >= GK_ALERT_REARM_QUIET_SEC then
        ResetGuildKeepDefenderAlert(siteKey)
    end
    -- Toute reprise avant la fin de la periode calme appartient a la meme vague, meme si
    -- un snapshot intermediaire a momentanement affiche held/neutral.
    gkDefenderAlertInactiveSince[siteKey] = nil
    if gkDefenderAlertEmitted[siteKey] then return end
    local lastAlert = gkDefenderAlertLast[siteKey] or 0
    if nowAlert - lastAlert < GK_DEFENDER_ALERT_COOLDOWN then return end

    gkDefenderAlertLast[siteKey] = nowAlert
    -- Meme une alerte local-only compte comme emise. La reimprimer plus tard juste pour
    -- ajouter le nom de guilde/capteur produit deux notifications pour le meme evenement.
    gkDefenderAlertEmitted[siteKey] = true

    local siteRef = GK.GetSite and GK:GetSite(siteKey)
    local whereLabel = (siteRef and GK.GetDisplayName and GK:GetDisplayName(siteRef)) or siteKey
    local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
        and Overlord.Zones:GetEnemyFactionName() or rFac
    if not isOwnGuild then
        if L.GUILD_KEEP_ALLIED_UNDER_ATTACK then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ALLIED_UNDER_ATTACK,
                whereLabel, heldGuild, facLabel))
        end
    elseif rGuild ~= "" and L.GUILD_KEEP_UNDER_ATTACK_BY then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_UNDER_ATTACK_BY,
            whereLabel, rGuild, facLabel))
    else
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_UNDER_ATTACK,
            whereLabel, facLabel))
    end
end

local function MaybeResetGuildKeepDefenderAlert(siteKey, stAfter)
    if not siteKey or not stAfter then return end
    local pf = Overlord.PlayerFaction
    -- Tant qu'une capture ennemie est en cours, garder l'anti-spam de la vague et annuler
    -- toute fausse sortie transitoire observee juste avant.
    if stAfter.status == "in_progress" and pf and stAfter.ownerFaction
        and stAfter.ownerFaction ~= pf then
        gkDefenderAlertInactiveSince[siteKey] = nil
        return
    end
    if not gkDefenderAlertInactiveSince[siteKey] then
        gkDefenderAlertInactiveSince[siteKey] = GetTime()
    end
end

local function ResetGuildKeepAssaultAlert(siteKey)
    if not siteKey then return end
    gkAssaultAlertLast[siteKey] = nil
    gkAssaultAlertEmitted[siteKey] = nil
    gkAssaultAlertInactiveSince[siteKey] = nil
end

local function MaybeResetGuildKeepAssaultAlert(siteKey, stAfter)
    if not siteKey or not stAfter then return end
    if stAfter.status == "in_progress" then
        gkAssaultAlertInactiveSince[siteKey] = nil
        return
    end
    if not gkAssaultAlertInactiveSince[siteKey] then
        gkAssaultAlertInactiveSince[siteKey] = GetTime()
    end
end

local function EffectiveGkCapturerNameForAlert(st, gkCapturerName)
    local z = NormalizeGkCapturerName(gkCapturerName)
    if z ~= "" then return z end
    local GK = Overlord.GuildKeep
    if GK and GK.GetEffectiveCapturerName then
        return NormalizeGkCapturerName(GK:GetEffectiveCapturerName(st))
    end
    return ""
end

-- Alerte faction : assaut en cours (hors guilde assaillante et guilde tenant assiegee).
local function TryPrintGuildKeepAssaultAlert(siteKey, stBefore, stAfter, gkCapturerName, gkCapturerShard)
    if not siteKey or not stAfter or not Overlord.GuildKeep then return end
    local L = Overlord.L
    if not L then return end
    if stAfter.status ~= "in_progress" then return end
    local nowAlert = GetTime()
    local inactiveSince = gkAssaultAlertInactiveSince[siteKey]
    if inactiveSince and nowAlert - inactiveSince >= GK_ALERT_REARM_QUIET_SEC then
        ResetGuildKeepAssaultAlert(siteKey)
    end
    gkAssaultAlertInactiveSince[siteKey] = nil
    if stBefore and stBefore.status == "in_progress" then
        local beforeGuild = Overlord.GuildKeep.SanitizeGuildName
            and Overlord.GuildKeep:SanitizeGuildName(stBefore.ownerGuild or "")
            or (stBefore.ownerGuild or "")
        local afterGuild = Overlord.GuildKeep.SanitizeGuildName
            and Overlord.GuildKeep:SanitizeGuildName(stAfter.ownerGuild or "")
            or (stAfter.ownerGuild or "")
        if beforeGuild == afterGuild and stBefore.ownerFaction == stAfter.ownerFaction then
            return
        end
    end
    local assaultFac = stAfter.ownerFaction
    local assaultGuild = Overlord.GuildKeep.SanitizeGuildName
        and Overlord.GuildKeep:SanitizeGuildName(stAfter.ownerGuild or "")
        or (stAfter.ownerGuild or "")
    if Overlord.GuildKeep.GetCanonicalAssaultGuild then
        local cg, cf = Overlord.GuildKeep:GetCanonicalAssaultGuild(stAfter)
        if cg ~= "" then
            assaultGuild = cg
            assaultFac = cf or assaultFac
        end
    end
    if not assaultFac or assaultGuild == "" then return end

    local localGuild = Overlord.GuildKeep:GetLocalPlayerGuild()
    if localGuild ~= "" and localGuild == assaultGuild
        and stAfter.holdAuthorityLocal then
        return
    end

    -- Source unique du defenseur : meme resolution que la carte (GetKeepSiegeSummary),
    -- a savoir previousOwnerGuild puis tenant officiel. On ne lit plus stBefore.ownerGuild
    -- qui peut etre stale (ISR d'une capture precedente) et faire afficher un mauvais
    -- defenseur (ex. ISR au lieu de CBH sur Wetlands).
    local defendedGuild = ""
    local prevDefender = Overlord.GuildKeep.SanitizeGuildName
        and Overlord.GuildKeep:SanitizeGuildName(stAfter.previousOwnerGuild or "")
        or (stAfter.previousOwnerGuild or "")
    if prevDefender ~= "" then
        defendedGuild = prevDefender
    elseif Overlord.GuildKeep.GetOfficialKeepTenant then
        local official = Overlord.GuildKeep:GetOfficialKeepTenant(siteKey)
        local officialGuild = official and (Overlord.GuildKeep.SanitizeGuildName
            and Overlord.GuildKeep:SanitizeGuildName(official.guild or "")
            or (official.guild or "")) or ""
        if officialGuild ~= "" then
            defendedGuild = officialGuild
        end
    end
    -- Etat in_progress oscillant : le defenseur calcule peut retomber sur l'attaquant
    -- ("X assaille X"). On supprime alors la forme "VS" (message d'assaut simple sans
    -- defenseur faux) plutot que d'afficher un defenseur incoherent.
    if defendedGuild == assaultGuild then
        defendedGuild = ""
    end
    if localGuild ~= "" and defendedGuild ~= "" and localGuild == defendedGuild then
        return
    end

    -- updatedAt est un timestamp de SNAPSHOT et change a chaque tick : il ne peut pas servir
    -- d'identifiant d'evenement. La vague retient plutot chaque identite semantique
    -- faction+guilde une seule fois. Si deux guildes concurrentes oscillent, chacune peut
    -- etre annoncee une fois, jamais a chaque aller-retour.
    local alertIdentity = tostring(assaultFac) .. "\031" .. string.lower(assaultGuild)
    local emittedForSite = gkAssaultAlertEmitted[siteKey]
    if emittedForSite and emittedForSite[alertIdentity] then return end
    local lastAlert = gkAssaultAlertLast[siteKey] or 0
    local alreadyEmittedThisWave = emittedForSite and next(emittedForSite) ~= nil
    if not alreadyEmittedThisWave and nowAlert - lastAlert < GK_ASSAULT_ALERT_COOLDOWN then return end

    gkAssaultAlertLast[siteKey] = nowAlert
    emittedForSite = emittedForSite or {}
    emittedForSite[alertIdentity] = true
    gkAssaultAlertEmitted[siteKey] = emittedForSite

    local siteRef = Overlord.GuildKeep.GetSite and Overlord.GuildKeep:GetSite(siteKey)
    local whereLabel = (siteRef and Overlord.GuildKeep.GetDisplayName)
        and Overlord.GuildKeep:GetDisplayName(siteRef) or siteKey
    local pf = Overlord.PlayerFaction
    local capturer = EffectiveGkCapturerNameForAlert(stAfter, gkCapturerName)
    local shardHint = gkCapturerShard or (stAfter.gkRelayCapturerShard)

    if pf and assaultFac == pf then
        if defendedGuild ~= "" and capturer ~= "" and L.GUILD_KEEP_ALLY_ASSAULT_VS_BY then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_ALLY_ASSAULT_VS_BY,
                whereLabel, assaultGuild, defendedGuild,
                FormatGkCapturerForAlert(capturer, shardHint, siteKey)))
        elseif defendedGuild ~= "" and L.GUILD_KEEP_ALLY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_ALLY_ASSAULT_VS,
                whereLabel, assaultGuild, defendedGuild))
        elseif capturer ~= "" and L.GUILD_KEEP_ALLY_ASSAULT_BY then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_ALLY_ASSAULT_BY,
                whereLabel, assaultGuild,
                FormatGkCapturerForAlert(capturer, shardHint, siteKey)))
        elseif L.GUILD_KEEP_ALLY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. L.GUILD_KEEP_ALLY_ASSAULT,
                whereLabel, assaultGuild))
        end
    else
        local facLabel = (Overlord.Zones and Overlord.Zones.GetEnemyFactionName)
            and Overlord.Zones:GetEnemyFactionName() or assaultFac
        if defendedGuild ~= "" and capturer ~= "" and L.GUILD_KEEP_ENEMY_ASSAULT_VS_BY then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ENEMY_ASSAULT_VS_BY,
                whereLabel, assaultGuild, defendedGuild, facLabel,
                FormatGkCapturerForAlert(capturer, shardHint, siteKey)))
        elseif defendedGuild ~= "" and L.GUILD_KEEP_ENEMY_ASSAULT_VS then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ENEMY_ASSAULT_VS,
                whereLabel, assaultGuild, defendedGuild, facLabel))
        elseif capturer ~= "" and L.GUILD_KEEP_ENEMY_ASSAULT_BY then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ENEMY_ASSAULT_BY,
                whereLabel, assaultGuild, facLabel,
                FormatGkCapturerForAlert(capturer, shardHint, siteKey)))
        elseif L.GUILD_KEEP_ENEMY_ASSAULT then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_ENEMY_ASSAULT,
                whereLabel, assaultGuild, facLabel))
        end
    end
end

function Overlord.Sync:BroadcastGuildKeepState(siteKey, forceFull, allowInstance)
    if not siteKey or not Overlord.GuildKeep then return end
    if GuildKeepSyncBlocked(allowInstance) then return end
    local st = Overlord.GuildKeep:GetState(siteKey)
    if not st then return end
    local isCriticalStart = st.status == "in_progress" and (st.holdTimeElapsed or 0) <= 5
    local criticalStartKey = isCriticalStart and GuildKeepCriticalStartKey(siteKey, st) or nil
    local shouldRelayCriticalStart = criticalStartKey
        and lastCommunityGKCriticalStart[siteKey] ~= criticalStartKey
    local isCriticalEmit = forceFull or shouldRelayCriticalStart
    -- GK post-capture / debut de siege : ne pas bloquer sur gate login ou settle.
    if not isCriticalEmit then
        if Overlord.WaitingForSync then return end
        if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    end
    -- Rattrapage login : sans claimedAt on ne connait pas le tenant ; avec claimedAt on emet (ts=claimedAt).
    if st.status == "held" and (tonumber(st.updatedAt) or 0) <= 0
        and (tonumber(st.claimedAt) or 0) <= 0 then
        return
    end
    local payload = BuildGuildKeepPayload(siteKey, st)
    if not payload then return end
    BroadcastGuildKeepToGroup("GK", payload)
    if forceFull or st.status == "held" or st.status == "in_progress" then
        -- Le debut de siege est l'alerte visible ; les ticks suivants restent repetables.
        local wantsCriticalChannel = forceFull or st.status == "held" or shouldRelayCriticalStart
        local nowChannel = GetTime()
        if not wantsCriticalChannel and st.status == "in_progress" then
            -- Secheresse prolongee du canal pour ce site (budget emetteur sature par le reste
            -- de son trafic, cf. CHANNEL_BYTE_BUDGET_PER_SEC) : forcer UN tick critique de
            -- rattrapage. Sans ca, l'observateur peut geler bien au-dela des ~45s couvertes
            -- par l'extrapolation d'affichage (GetObserverHoldTimeElapsed).
            local lastSent = lastGkChannelSentAt[siteKey] or 0
            if lastSent <= 0 or (nowChannel - lastSent) >= GK_CHANNEL_STALE_ESCALATE_SEC then
                wantsCriticalChannel = true
            end
        end
        if SendGuildKeepToChannel("GK", payload, wantsCriticalChannel) then
            lastGkChannelSentAt[siteKey] = nowChannel
        end
    end
    local now = GetTime()
    local last = lastCommunityGKBroadcast[siteKey] or 0
    -- forceFull signifie normalement snapshot terminal (held/neutral). Si un appelant force
    -- encore un in_progress, le traiter comme un DEBUT borne, jamais comme une capture finale
    -- a fan-out 25/40.
    local forcedProgress = forceFull and st.status == "in_progress"
    local full = forceFull and not forcedProgress
    local startTransition = shouldRelayCriticalStart or forcedProgress
    local isCriticalCommunity = full or startTransition
    -- Throttle routine uniquement : debut de siege et post-capture passent toujours.
    local routineInterval = IsGkLargeEvent() and GK_COMMUNITY_ROUTINE_INTERVAL_LARGE or GK_COMMUNITY_ROUTINE_INTERVAL
    if not isCriticalCommunity and now - last < routineInterval then
        return
    end
    lastCommunityGKBroadcast[siteKey] = now
    local maxM, delay
    if full then
        -- forceFull couvre aussi les reverts/retours au tenant precedent, qui n'ont pas
        -- forcement de GC compagnon. Garder ici la couverture 25/40 ; la pompe globale
        -- et le coalescing GK suppriment la rafale sans sacrifier cette verite terminale.
        maxM, delay = GetGuildKeepCriticalRelayLimits()
        BroadcastGuildKeepCaptureToCommunity("GK", payload, maxM, delay, true)
    else
        if startTransition then
            -- Groupe + canal ont deja diffuse toutes les propositions d'Anchor. Attendre
            -- leur convergence, puis laisser uniquement le premier tagueur encore elu
            -- lancer la vague communautaire 25/40.
            if criticalStartKey
                and pendingCommunityGKCriticalStart[siteKey] ~= criticalStartKey then
                pendingCommunityGKCriticalStart[siteKey] = criticalStartKey
                C_Timer.After(GK_COMMUNITY_START_REVALIDATE_DELAY, function()
                    if pendingCommunityGKCriticalStart[siteKey] ~= criticalStartKey then return end
                    pendingCommunityGKCriticalStart[siteKey] = nil
                    if not Overlord.Sync or GuildKeepSyncBlocked() then return end
                    local current = Overlord.GuildKeep and Overlord.GuildKeep:GetState(siteKey)
                    if not current or current.status ~= "in_progress"
                        or GuildKeepCriticalStartKey(siteKey, current) ~= criticalStartKey
                        or lastCommunityGKCriticalStart[siteKey] == criticalStartKey then return end
                    local function emitCritical(snapshot)
                        local currentPayload = BuildGuildKeepPayload(siteKey, snapshot)
                        if not currentPayload then return false end
                        lastCommunityGKCriticalStart[siteKey] = criticalStartKey
                        lastCommunityGKBroadcast[siteKey] = GetTime()
                        local criticalMax, criticalDelay = GetGuildKeepCriticalRelayLimits()
                        BroadcastGuildKeepCaptureToCommunity(
                            "GK", currentPayload, criticalMax, criticalDelay, true)
                        return true
                    end
                    if LocalPlayerIsGuildKeepAnchor(current) then
                        emitCritical(current)
                        return
                    end
                    if pendingCommunityGKCriticalFallback[siteKey] == criticalStartKey then return end
                    pendingCommunityGKCriticalFallback[siteKey] = criticalStartKey
                    C_Timer.After(GK_COMMUNITY_START_FALLBACK_DELAY, function()
                        if pendingCommunityGKCriticalFallback[siteKey] ~= criticalStartKey then return end
                        pendingCommunityGKCriticalFallback[siteKey] = nil
                        if not Overlord.Sync or GuildKeepSyncBlocked()
                            or seenCommunityGKCriticalStart[siteKey] == criticalStartKey
                            or lastCommunityGKCriticalStart[siteKey] == criticalStartKey then return end
                        local fallback = Overlord.GuildKeep
                            and Overlord.GuildKeep:GetState(siteKey)
                        if not fallback or fallback.status ~= "in_progress"
                            or GuildKeepCriticalStartKey(siteKey, fallback) ~= criticalStartKey
                            or not LocalPlayerIsGuildKeepFallbackAuthority(fallback, siteKey) then return end
                        emitCritical(fallback)
                    end)
                end)
            end
        else
            maxM, delay = GetGkCommunityRoutineRelayLimits()
            BroadcastGuildKeepToCommunityOnly("GK", payload, maxM, delay)
        end
    end
end

function Overlord.Sync:BroadcastHeldGuildKeepStates()
    if not Overlord.GuildKeep or not Overlord.GuildKeepSites then return end
    if GuildKeepSyncBlocked() or Overlord.WaitingForSync then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    for siteKey in pairs(Overlord.GuildKeepSites) do
        local st = Overlord.GuildKeep:GetState(siteKey)
        if st and st.status == "held" and (st.ownerGuild or "") ~= "" then
            self:BroadcastGuildKeepState(siteKey, false)
        end
    end
end

local function NoteTrustedGuildKeepTraffic(siteKey, recoveryAdvanced)
    if not siteKey or siteKey == "" or not recoveryAdvanced then return end
    lastTrustedGuildKeepTrafficAt[siteKey] = GetTime()
    staleKeepObserverPollState[siteKey] = nil
end

local function GetStaleKeepPollEpisodeKey(siteKey)
    local GK = Overlord.GuildKeep
    local st = siteKey and GK and GK.GetState and GK:GetState(siteKey)
    if not st then return tostring(siteKey or "__global") end
    local startedAt = math.floor(tonumber(st.canonicalAssaultStartedAt) or 0)
    if startedAt <= 0 and st.status == "in_progress" then
        startedAt = math.floor((tonumber(st.updatedAt) or 0)
            - (tonumber(st.holdTimeElapsed) or 0))
    end
    -- v8 conserve la meme racine lors d'un retry : l'offset doit donc faire partie de
    -- l'episode, sinon la nouvelle tentative herite du backoff/dedup de la precedente.
    local generationAt = st.status == "in_progress"
        and math.floor(tonumber(st.assaultGenerationAt) or 0) or 0
    local campaign = (Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs()) or 0
    return table.concat({
        tostring(campaign), tostring(st.status or ""), tostring(st.ownerGuild or ""),
        tostring(st.ownerFaction or ""), tostring(st.claimedAt or 0), tostring(startedAt),
        tostring(generationAt),
    }, "|")
end

-- Un etat in_progress conserve le dernier porteur prouve par un heartbeat DIRECT.
-- L'interroger en plus du fan-out aleatoire est le chemin le plus court vers le GC/GK held
-- manque : contrairement a un relais choisi au hasard, c'est la derniere source directement
-- validee comme porteur du siege (et donc la plus susceptible d'avoir produit son terminal).
local function GetObservedKeepAuthorityTarget(sync, st)
    if not sync or not st or st.status ~= "in_progress" then return nil end
    local target = NormalizeGkCapturerName(st.gkOfficialCapturerName)
    if target == "" then return nil end
    if sync.IsValidWhisperTarget and not sync:IsValidWhisperTarget(target) then return nil end
    if sync.IsSenderLocalPlayer and sync:IsSenderLocalPlayer(target) then return nil end
    return target
end

function Overlord.Sync:RequestObservedGuildKeepAuthorityState(siteKey, st, payload)
    if Overlord.InstanceSuspended or GuildKeepSyncBlocked() then return false end
    local GK = Overlord.GuildKeep
    st = st or (siteKey and GK and GK.GetState and GK:GetState(siteKey))
    local target = GetObservedKeepAuthorityTarget(self, st)
    if not target or not self.SendWhisper then return false end
    payload = payload or (self.GetSRPayload and self:GetSRPayload("T"))
    if not payload or payload == "" then return false end
    return self:SendWhisper("SR", payload, target) == true
end

-- Utilise par /ov sync : une seule SR territoriale par autorite observee, meme si ce
-- porteur apparait sur plusieurs snapshots locaux. Le fan-out communautaire general reste
-- ensuite le filet pour les etats qui n'ont jamais recu de heartbeat direct.
function Overlord.Sync:RequestActiveGuildKeepAuthorityCatchup()
    if Overlord.InstanceSuspended or GuildKeepSyncBlocked() then return 0 end
    local GK = Overlord.GuildKeep
    if not GK or not GK.GetState or not Overlord.GuildKeepSites then return 0 end
    local payload = self.GetSRPayload and self:GetSRPayload("T") or nil
    if not payload or payload == "" then return 0 end
    local requested, count = {}, 0
    for siteKey in pairs(Overlord.GuildKeepSites) do
        local st = GK:GetState(siteKey)
        local target = GetObservedKeepAuthorityTarget(self, st)
        local targetKey = target and GkRosterMatchKey(target) or ""
        if target and targetKey ~= "" and not requested[targetKey] then
            requested[targetKey] = true
            if self:RequestObservedGuildKeepAuthorityState(siteKey, st, payload) then
                count = count + 1
            end
        end
    end
    return count
end

function Overlord.Sync:PollIfStaleObserverKeep(
    secondsSinceGk, siteKey, forceTrustedBypass, forceRecoveryKey)
    local isLarge = IsGkLargeEvent()
    local baseInterval = isLarge
        and STALE_KEEP_OBSERVER_POLL_INTERVAL_LARGE or STALE_KEEP_OBSERVER_POLL_INTERVAL
    local pollKey = siteKey or "__global"
    if not secondsSinceGk or secondsSinceGk < baseInterval then
        staleKeepObserverPollState[pollKey] = nil
        return
    end
    local now = GetTime()
    forceRecoveryKey = tostring(forceRecoveryKey or "")
    if forceRecoveryKey ~= "" then
        local semanticKey = tostring(siteKey or "__global") .. "|" .. forceRecoveryKey
        local lastForced = forcedKeepRecoverySeenAt[semanticKey]
        if lastForced and now - lastForced < 300 then return end
        for key, at in pairs(forcedKeepRecoverySeenAt) do
            if now - at >= 300 then forcedKeepRecoverySeenAt[key] = nil end
        end
        forcedKeepRecoverySeenAt[semanticKey] = now
        -- Une SR restitue les six keeps : si deux corrections critiques arrivent dans le
        -- meme burst, une seule requete couvre les deux sans tempete communautaire.
        if now - lastForcedKeepRecoveryPoll < 2 then return end
        lastForcedKeepRecoveryPoll = now
        lastStaleKeepObserverPoll = now
        local maxM, delay = GetGkCommunityCatchupRelayLimits()
        self:SendSyncRequest({
            includeCommunity = true,
            allowCommunityInLargeEvent = true,
            communityMax = maxM,
            communityDelay = delay,
            criticalChannel = true,
        })
        return
    end
    if not forceTrustedBypass and siteKey
        and now - (lastTrustedGuildKeepTrafficAt[siteKey] or 0) < baseInterval then
        staleKeepObserverPollState[pollKey] = nil
        return
    end
    local episodeKey = GetStaleKeepPollEpisodeKey(siteKey)
    local poll = staleKeepObserverPollState[pollKey]
    if not poll or poll.episodeKey ~= episodeKey then
        poll = { attempts = 0, at = 0, episodeKey = episodeKey }
    end
    if poll.attempts >= STALE_KEEP_OBSERVER_MAX_POLLS then return end
    local minInterval = baseInterval * (2 ^ poll.attempts)
    if now - poll.at < minInterval then return end
    if now - lastStaleKeepObserverPoll < baseInterval then return end
    poll.attempts = poll.attempts + 1
    poll.at = now
    staleKeepObserverPollState[pollKey] = poll
    lastStaleKeepObserverPoll = now
    -- Un poll est une requete de rattrapage, pas une transition : trois a six graines
    -- communautaires plus le canal critique suffisent et ne saturent pas le client.
    local maxM, delay = GetGkCommunityCatchupRelayLimits()
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        communityMax = maxM,
        communityDelay = delay,
        criticalChannel = true,
        territorialOnly = true,
    })
    self:RequestObservedGuildKeepAuthorityState(siteKey)
end

local function GetObserverKeepFinalStatePollOptions(isLarge, attempts)
    if isLarge then
        return math.min(6, 2 + attempts), 0.75
    end
    return math.min(12, 4 + attempts * 2), 0.65
end

-- Observateur fortin : timer au seuil sans GC recu (parite RequestObserverCaptureConfirmationIfComplete).
local function CanKeepObserverRequestConfirmation(st, site)
    if not st or st.status ~= "in_progress" then return false end
    if st.holdAuthorityLocal and (st.isHolding or st.isPaused or st.isContested) then return false end
    local GK = Overlord.GuildKeep
    if not GK or not site then return false end
    if GK.IsCurrentKeepSiegeState and not GK:IsCurrentKeepSiegeState(st) then return false end
    if st._gkStaleObserver then return false end
    if GK.IsPlayerInKeepGeometry and GK:IsPlayerInKeepGeometry(site) then
        if st.isHolding then return false end
        if GK.IsPlayerKeepAssailant and GK:IsPlayerKeepAssailant(st) then
            if not GK.ShouldDeferToRemoteKeepCapturer
                or not GK:ShouldDeferToRemoteKeepCapturer(st) then
                return false
            end
        end
    end
    return true
end

function Overlord.Sync:RequestObserverKeepCaptureConfirmationIfComplete(siteKey, st, site)
    if not st or st.status ~= "in_progress" then
        if st then
            st._observerKeepFinalStatePollCount = nil
            st._observerKeepFinalStatePollAt = nil
        end
        return
    end
    if st.holdAuthorityLocal and (st.isHolding or st.isPaused or st.isContested) then return end
    local GK = Overlord.GuildKeep
    if GK and GK.IsCurrentKeepSiegeState and not GK:IsCurrentKeepSiegeState(st) then
        st._observerKeepFinalStatePollCount = nil
        return
    end
    if st._gkStaleObserver then
        st._observerKeepFinalStatePollCount = nil
        return
    end
    if not CanKeepObserverRequestConfirmation(st, site) then return end
    if not GK or not GK.GetObserverHoldTimeElapsed or not GK.GetDefaultHoldTimeRequired then return end
    local req = GK:GetDefaultHoldTimeRequired(st, site)
    local stored = tonumber(st.holdTimeElapsed) or 0
    local elapsed = GK:GetObserverHoldTimeElapsed(st, site)
    -- L'interpolation observateur s'arrete volontairement a req-1. C'est precisement
    -- a ce seuil qu'il faut demander le final : exiger que la valeur STOCKEE atteigne
    -- req-1 rendait l'interpolation inutile pour le rattrapage et laissait un co-capteur
    -- bloque sur l'avant-dernier GK si le GC/GK held avait ete perdu.
    if math.max(elapsed or 0, stored) < req - 1 then
        st._observerKeepFinalStatePollCount = nil
        st._observerKeepFinalStatePollAt = nil
        return
    end
    if Overlord.InstanceSuspended or GuildKeepSyncBlocked() then return end
    local attempts = math.floor(tonumber(st._observerKeepFinalStatePollCount) or 0)
    if attempts >= OBSERVER_KEEP_FINAL_STATE_MAX_POLLS then return end
    local now = GetTime()
    local minInterval = OBSERVER_KEEP_FINAL_STATE_BACKOFF[attempts + 1] or 90
    if now - (st._observerKeepFinalStatePollAt or 0) < minInterval then return end
    if now - lastObserverKeepFinalStatePoll < minInterval then return end
    st._observerKeepFinalStatePollAt = now
    lastObserverKeepFinalStatePoll = now
    st._observerKeepFinalStatePollCount = attempts + 1
    local isLarge = IsGkLargeEvent()
    local maxM, delay = GetObserverKeepFinalStatePollOptions(isLarge, st._observerKeepFinalStatePollCount)
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        communityMax = maxM,
        communityDelay = delay,
        criticalChannel = true,
        territorialOnly = true,
    })
    self:RequestObservedGuildKeepAuthorityState(siteKey, st)
end

function Overlord.Sync:BroadcastGuildKeepCapture(
    siteKey, guild, faction, captureTs, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    if not siteKey or not Overlord.GuildKeepSites[siteKey] or not Overlord.GuildKeep then return end
    captureTs = math.floor(tonumber(captureTs) or 0)
    anchorShard = tonumber(anchorShard)
    anchorStartedAt = math.floor(tonumber(anchorStartedAt) or 0)
    anchorGenerationAt = math.floor(tonumber(anchorGenerationAt) or 0)
    anchorPlayer = NormalizeGkCapturerName(anchorPlayer)
    guild = Overlord.GuildKeep.SanitizeGuildName
        and Overlord.GuildKeep:SanitizeGuildName(guild or "") or (guild or "")
    baseGuild = Overlord.GuildKeep:SanitizeGuildName(baseGuild or "")
    baseCapturedAt = math.floor(tonumber(baseCapturedAt) or 0)
    local facCode = FactionToCode(faction)
    local baseFacCode = FactionToCode(baseFaction)
    local validBase = (baseGuild == "" and baseFacCode == "" and baseCapturedAt == 0)
        or (baseGuild ~= "" and baseFacCode ~= "" and baseCapturedAt > 0)
    local st = Overlord.GuildKeep:GetState(siteKey)
    local finalMatchesState = st and st.status == "held"
        and tonumber(st.finalAssaultShardId) == anchorShard
        and math.floor(tonumber(st.finalAssaultStartedAt) or 0) == anchorStartedAt
        and math.floor(tonumber(st.finalAssaultGenerationAt) or 0) == anchorGenerationAt
        and Overlord.GuildKeep:SanitizeGuildName(st.finalAssaultGuild or ""):lower() == guild:lower()
        and st.finalAssaultFaction == faction
        and GkRosterMatchKey(st.finalAssaultPlayer or "") == GkRosterMatchKey(anchorPlayer)
        and math.floor(tonumber(st.finalAssaultCapturedAt) or 0) == captureTs
        and Overlord.GuildKeep:SanitizeGuildName(st.finalAssaultBaseGuild or ""):lower()
            == baseGuild:lower()
        and st.finalAssaultBaseFaction == baseFaction
        and math.floor(tonumber(st.finalAssaultBaseCapturedAt) or 0) == baseCapturedAt
    local req = Overlord.GuildKeep:GetDefaultHoldTimeRequired(st, Overlord.GuildKeep:GetSite(siteKey))
    local attemptStartedAt = Overlord.GuildKeep.GetAssaultAttemptStartedAt
        and math.floor(tonumber(Overlord.GuildKeep:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    if captureTs <= 0 or not anchorShard or anchorShard < 0 or anchorShard >= 100000000
        or anchorShard ~= math.floor(anchorShard) or anchorStartedAt <= 0
        or anchorGenerationAt < 0 or anchorGenerationAt > 1000000
        or attemptStartedAt <= 0
        or captureTs > NetworkNow() + MAX_CLOCK_SKEW
        or attemptStartedAt > captureTs or anchorPlayer == ""
        or guild == "" or facCode == ""
        or not validBase
        or (baseCapturedAt > 0 and baseCapturedAt > anchorStartedAt)
        or captureTs - attemptStartedAt < math.max(0, req - 1)
        or (Overlord.GuildKeep.GetServerSiegeDayKey
            and Overlord.GuildKeep:GetServerSiegeDayKey(anchorStartedAt)
                ~= Overlord.GuildKeep:GetServerSiegeDayKey(captureTs))
        or not finalMatchesState
        or IsStaleCampaignTimestamp(captureTs) or IsStaleCampaignTimestamp(anchorStartedAt)
        or (Overlord.GuildKeep.IsSiegeGameplayTimestampAllowed
            and not Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(anchorStartedAt)) then
        return
    end
    if GuildKeepSyncBlocked() then
        -- GC = etat final one-shot : jamais droppe silencieusement (regle dure). Bloque par
        -- instance/suspension : mettre en file et re-emettre apres la sortie plutot que perdre
        -- la capture (le captureTs d'origine est conserve pour l'arbitrage cote recepteurs).
        QueuePendingGuildKeepTerminal(pendingGkFinals, {
            siteKey, guild, faction, captureTs or NetworkNow(),
            anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt,
        })
        ScheduleGkCriticalFlushRetry()
        return
    end
    local gateBlocked = Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive())
    local queuedForRetry = false
    if gateBlocked then
        -- GC = etat final one-shot : file de secours + emission immediate (comme BroadcastCapture C).
        QueuePendingGuildKeepTerminal(pendingGkFinals, {
            siteKey, guild, faction, captureTs or NetworkNow(),
            anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt,
        })
        ScheduleGkCriticalFlushRetry()
        queuedForRetry = true
    end
    local pool = CurrentGuildKeepPoolTag()
    if pool == "" then
        -- Pool pas encore resolu (tout debut de session) : meme garantie one-shot que le gate,
        -- re-essai differe au lieu d'un drop silencieux de la capture.
        if not queuedForRetry then
            QueuePendingGuildKeepTerminal(pendingGkFinals, {
                siteKey, guild, faction, captureTs or NetworkNow(),
                anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
                baseGuild, baseFaction, baseCapturedAt,
            })
            ScheduleGkCriticalFlushRetry()
        end
        return
    end
    local payload = table.concat({
        GK_WIRE_SEMANTIC_VERSION, siteKey, guild, facCode, tostring(captureTs), baseGuild, baseFacCode,
        tostring(baseCapturedAt), tostring(anchorShard), tostring(anchorStartedAt),
        tostring(anchorGenerationAt), anchorPlayer, pool,
    }, ":")
    local function emitCapture()
        if not Overlord.Sync or Overlord.InstanceSuspended or not payload or payload == "" then return end
        BroadcastGuildKeepToGroup("GC", payload)
        SendGuildKeepToChannel("GC", payload, true)
    end
    emitCapture()
    C_Timer.After(GK_CAPTURE_REPLAY_DELAY_1, emitCapture)
    C_Timer.After(GK_CAPTURE_REPLAY_DELAY_2, emitCapture)
    -- Communaute : uniquement le snapshot GK terminal auto-suffisant (avec autorite
    -- effective), deux vagues bornees. GC reste le chemin faible latence groupe+canal.
    self:BroadcastGuildKeepState(siteKey, true)
    C_Timer.After(GK_POST_CAPTURE_STATE_DELAY, function()
        if Overlord.Sync and not Overlord.InstanceSuspended and siteKey then
            Overlord.Sync:BroadcastGuildKeepState(siteKey, true)
        end
    end)
end

function Overlord.Sync:BroadcastGuildKeepAbort(
    siteKey, guild, faction, abortedAt, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    local GK = Overlord.GuildKeep
    if not GK or not siteKey or not Overlord.GuildKeepSites[siteKey] then return end
    guild = GK:SanitizeGuildName(guild or "")
    baseGuild = GK:SanitizeGuildName(baseGuild or "")
    abortedAt = math.floor(tonumber(abortedAt) or 0)
    anchorShard = tonumber(anchorShard)
    anchorStartedAt = math.floor(tonumber(anchorStartedAt) or 0)
    anchorGenerationAt = math.floor(tonumber(anchorGenerationAt) or 0)
    anchorPlayer = NormalizeGkCapturerName(anchorPlayer)
    baseCapturedAt = math.floor(tonumber(baseCapturedAt) or 0)
    local facCode, baseFacCode = FactionToCode(faction), FactionToCode(baseFaction)
    local identityValid = GK:AssaultIdentityWins(
        guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt,
        "", nil, nil, 0, 0, "", "", nil, 0)
    local st = GK:GetState(siteKey)
    local terminalRecorded = st and GK.AbortedAssaultAnchorMatches
        and GK:AbortedAssaultAnchorMatches(
            st, guild, faction, anchorShard, anchorStartedAt,
            anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    local attemptStartedAt = GK.GetAssaultAttemptStartedAt
        and math.floor(tonumber(GK:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    if not identityValid or not terminalRecorded or facCode == "" or abortedAt <= 0
        or attemptStartedAt <= 0 or abortedAt > NetworkNow() + MAX_CLOCK_SKEW
        or attemptStartedAt > abortedAt
        or (baseCapturedAt > 0 and baseCapturedAt > anchorStartedAt)
        or (GK.GetServerSiegeDayKey
            and GK:GetServerSiegeDayKey(anchorStartedAt)
                ~= GK:GetServerSiegeDayKey(abortedAt))
        or IsStaleCampaignTimestamp(abortedAt) or IsStaleCampaignTimestamp(anchorStartedAt) then
        return
    end

    local queued = false
    local function queueAbort()
        if queued then return end
        queued = true
        QueuePendingGuildKeepTerminal(pendingGkAborts, {
            siteKey, guild, faction, abortedAt, anchorShard, anchorStartedAt,
            anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt,
        })
        ScheduleGkCriticalFlushRetry()
    end
    if GuildKeepSyncBlocked() then queueAbort(); return end
    if Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive()) then
        queueAbort()
    end
    local pool = CurrentGuildKeepPoolTag()
    if pool == "" then queueAbort(); return end
    local payload = table.concat({
        GK_WIRE_SEMANTIC_VERSION, siteKey, guild, facCode, tostring(abortedAt), baseGuild, baseFacCode,
        tostring(baseCapturedAt), tostring(anchorShard), tostring(anchorStartedAt),
        tostring(anchorGenerationAt), anchorPlayer, pool,
    }, ":")
    local function emit()
        if not Overlord.Sync or Overlord.InstanceSuspended then return end
        BroadcastGuildKeepToGroup("GA", payload)
        SendGuildKeepToChannel("GA", payload, true)
    end
    emit()
    C_Timer.After(GK_CAPTURE_REPLAY_DELAY_1, emit)
    C_Timer.After(GK_CAPTURE_REPLAY_DELAY_2, emit)
    self:BroadcastGuildKeepState(siteKey, true)
    C_Timer.After(GK_POST_CAPTURE_STATE_DELAY, function()
        if Overlord.Sync and not Overlord.InstanceSuspended then
            Overlord.Sync:BroadcastGuildKeepState(siteKey, true)
        end
    end)
end

function Overlord.Sync:BroadcastDominationBoost(faction, boostPct, siteKey, eventId, eventDelta)
    if not faction or not OverlordDB or GuildKeepSyncBlocked() then return end
    local epoch = OverlordDB.lastResetTimestamp or 0
    local facCode = FactionToCode(faction)
    if facCode == "" then return end
    local pct = math.floor((boostPct or 0) * 10000) / 10000
    local pool = CurrentGuildKeepPoolTag()
    if pool == "" then return end
    local poolSuffix = ":" .. pool
    if siteKey ~= "wood_resource" then return end
    local eventSuffix = ""
    eventId = NormalizeDominationBoostEventId(eventId)
    eventDelta = math.floor((tonumber(eventDelta) or 0) * 10000) / 10000
    if eventId ~= "" and eventDelta > 0 then
        eventSuffix = ":" .. eventId .. ":" .. eventDelta
    end
    local payload = facCode .. ":" .. pct .. ":" .. epoch .. ":" .. siteKey .. ":_" .. poolSuffix .. eventSuffix
    BroadcastGuildKeepToGroup("WB", payload)
    self:SendToChannel("WB", payload)
    -- Cross-realm / cross-faction : communaute (canal Overlord = realm-only).
    local maxM, delay = GetWbCommunityRelayLimits()
    BroadcastGuildKeepCaptureToCommunity("WB", payload, maxM, delay, true)
    C_Timer.After(2.5, function()
        if Overlord.Sync and not Overlord.InstanceSuspended and payload and payload ~= "" then
            BroadcastGuildKeepCaptureToCommunity("WB", payload, maxM, delay, true)
        end
    end)
end

local function CapturingFactionLabel(fac)
    local L = Overlord.L
    if fac == "Alliance" then return (L and L.THE_ALLIANCE) or "the Alliance" end
    if fac == "Horde" then return (L and L.THE_HORDE) or "the Horde" end
    return fac or ""
end

-- Alerte chat (GC / capture locale) : les deux factions via relais communaute, comme les zones (C).
function Overlord.Sync:PrintGuildKeepCaptureAlert(siteKey, guild, faction, captureTs)
    if not siteKey or not faction or not Overlord.GuildKeep then return end
    if Overlord.WaitingForSync then return end
    local L = Overlord.L
    if not L then return end
    local GK = Overlord.GuildKeep
    -- GC / herald hors fenetre siege + grace 15 min : etat applique ailleurs, pas de chat tardif.
    local immersion = Overlord.GuildKeepImmersion
    if immersion and immersion.IsPostCutoffKeepChatAllowed
        and not immersion:IsPostCutoffKeepChatAllowed(GK) then
        return
    end
    guild = GK.SanitizeGuildName and GK:SanitizeGuildName(guild or "") or (guild or "")
    if guild == "" then return end
    captureTs = tonumber(captureTs) or 0
    local dedupKey = string.format("%s:%s:%s:%d", siteKey, guild, faction, captureTs)
    local now = GetTime()
    if gkCaptureAlertDedup[dedupKey] then return end
    gkCaptureAlertDedup[dedupKey] = now
    for k, t in pairs(gkCaptureAlertDedup) do
        if now - t > GK_CAPTURE_ALERT_DEDUP_SEC then gkCaptureAlertDedup[k] = nil end
    end

    if Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.PrintHeraldCapture then
        Overlord.GuildKeepImmersion:PrintHeraldCapture(siteKey, guild, faction)
    else
        local site = GK.GetSite and GK:GetSite(siteKey)
        local whereLabel = (site and GK.GetDisplayName and GK:GetDisplayName(site)) or siteKey
        local pf = Overlord.PlayerFaction
        if pf and faction == pf then
            if L.GUILD_KEEP_CAPTURE_ALERT_FRIENDLY then
                Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_ALERT_FRIENDLY,
                    whereLabel, guild))
            end
        elseif L.GUILD_KEEP_CAPTURE_ALERT_ENEMY then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.GUILD_KEEP_CAPTURE_ALERT_ENEMY,
                whereLabel, guild, CapturingFactionLabel(faction)))
        end
    end
    local localGuild = GK.GetLocalPlayerGuild and GK:GetLocalPlayerGuild() or ""
    local pf = Overlord.PlayerFaction
    if localGuild ~= "" and localGuild == guild and pf and faction == pf
        and Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("welcome_popup")
    elseif OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
    end
end

function Overlord.Sync:OnReceiveGuildKeepState(payload, sender, channel)
    if not payload or payload == "" or not Overlord.GuildKeep then return end
    if GuildKeepSyncBlocked() then return end

    local version, parsePayload = payload:match("^(v%d+):(.*)$")
    -- v7 donnait a generationAt un autre sens. Le convertir ici ferait valider une
    -- fausse duree ou elire une autre Anchor selon l'ordre d'arrivee : rupture stricte.
    if version ~= GK_WIRE_SEMANTIC_VERSION or not parsePayload then return end
    local siteKey, status, holdStr, guild, facCode, caStr, tsStr, holdReqStr,
        poolStr, contestedStr, baseGuild, baseFacCode, baseCapturedStr,
        gkCapturerName, gkCapturerShard, gkAssaultStartedAt,
        gkAssaultGenerationAt, gkAuthorityPlayer =
        strsplit(":", parsePayload, 18)
    local remoteFac = FactionCodeToFaction(facCode)
    if not siteKey or not Overlord.GuildKeepSites[siteKey] then return end
    if not VALID_GK_STATUS[status] then return end
    if facCode and facCode ~= "" and not remoteFac then return end
    guild = Overlord.GuildKeep:SanitizeGuildName(guild or "")
    if status == "neutral" then
        if guild ~= "" or (facCode and facCode ~= "") then return end
    elseif guild == "" or not remoteFac then
        return
    end
    baseGuild = Overlord.GuildKeep:SanitizeGuildName(baseGuild or "")
    local baseFaction = FactionCodeToFaction(baseFacCode)
    local baseCapturedAt = math.floor(tonumber(baseCapturedStr) or 0)
    local validBase = (baseGuild == "" and (baseFacCode or "") == "" and baseCapturedAt == 0)
        or (baseGuild ~= "" and baseFaction ~= nil and baseCapturedAt > 0)
    if not validBase then return end
    if baseCapturedAt > 0 and baseCapturedAt > NetworkNow() + MAX_CLOCK_SKEW then return end
    if status == "neutral" and (baseGuild ~= "" or (gkCapturerName or "") ~= ""
        or (gkAuthorityPlayer or "") ~= "") then return end
    local remotePool = ResolveGuildKeepPayloadPool(poolStr, sender, channel)
    if not remotePool then return end
    local ownerSourceVerified = GcSenderMatchesPayloadGuild(sender or "", guild or "")
        or (status == "held"
            and GkSenderMatchesObservedCapturer(siteKey, sender or "", guild or "", remoteFac))
    local hadTs = tsStr and tsStr ~= ""
    local remoteTs = NormalizeRemoteTimestamp(tsStr)
    if hadTs and not remoteTs then return end
    if not remoteTs then remoteTs = 0 end
    if IsStaleCampaignTimestamp(remoteTs) then return end
    local communitySource = self.IsGuildKeepCommunitySender and self:IsGuildKeepCommunitySender(sender or "") or false
    if communitySource and not ownerSourceVerified and remoteTs <= 0 then
        -- GK est un snapshot d'etat (souvent reponse SR/login), pas un evenement live GC :
        -- on exige un timestamp, mais on ne limite pas son age hors campagne courante.
        return
    end
    if status == "in_progress" then
        if not Overlord.GuildKeep.IsSiegeWindowOpen or not Overlord.GuildKeep:IsSiegeWindowOpen() then
            return
        end
        if Overlord.GuildKeep.GetServerSiegeDayKey and remoteTs > 0
            and Overlord.GuildKeep:GetServerSiegeDayKey(remoteTs) ~= Overlord.GuildKeep:GetServerSiegeDayKey(NetworkNow()) then
            return
        end
        if Overlord.GuildKeep.IsSiegeGameplayTimestampAllowed
            and not Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(remoteTs > 0 and remoteTs or NetworkNow()) then
            return
        end
    end

    local anchorShard = tonumber(gkCapturerShard)
    local anchorStartedAt = tonumber(gkAssaultStartedAt)
    local anchorGenerationAt = tonumber(gkAssaultGenerationAt)
    local statusNeedsAnchor = status == "in_progress" or status == "held" or status == "aborted"
    local anchorAttemptStartedAt = statusNeedsAnchor
        and Overlord.GuildKeep.GetAssaultAttemptStartedAt
        and math.floor(tonumber(Overlord.GuildKeep:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    local explicitAnchor = statusNeedsAnchor
        and anchorShard and anchorStartedAt and anchorGenerationAt
        and anchorShard >= 0 and anchorShard < 100000000
        and anchorShard == math.floor(anchorShard)
        and anchorStartedAt > 0 and anchorStartedAt == math.floor(anchorStartedAt)
        and anchorGenerationAt >= 0 and anchorGenerationAt <= 1000000
        and anchorGenerationAt == math.floor(anchorGenerationAt)
        and anchorAttemptStartedAt > 0
        and anchorStartedAt <= NetworkNow() + MAX_CLOCK_SKEW
        and anchorAttemptStartedAt <= NetworkNow() + MAX_CLOCK_SKEW
        and (baseCapturedAt == 0 or baseCapturedAt <= anchorStartedAt)
        and (remoteTs <= 0 or anchorAttemptStartedAt <= remoteTs + MAX_CLOCK_SKEW)
        and not IsStaleCampaignTimestamp(anchorStartedAt)
        and (not Overlord.GuildKeep.IsSiegeGameplayTimestampAllowed
            or Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(anchorStartedAt))

    local remoteIsContested
    remoteIsContested = (contestedStr == "1")

    local normalizedCapturer = NormalizeGkCapturerName(gkCapturerName)
    local authorityPlayer = NormalizeGkCapturerName(gkAuthorityPlayer)
    local assaultAnchorVerified = explicitAnchor == true and normalizedCapturer ~= ""
        and remoteFac ~= nil
    if statusNeedsAnchor and not assaultAnchorVerified then return end
    if status == "in_progress" and authorityPlayer == "" then return end
    if status == "in_progress" and remoteTs <= 0 then return end
    local transportTrusted = self:IsGuildKeepSenderTrusted(
        sender or "", remoteFac, channel, "GK", status)
    if not transportTrusted then return end
    local directAuthority = statusNeedsAnchor and authorityPlayer ~= ""
        and GkSenderMatchesNamedPlayer(sender, authorityPlayer)
    local terminalDirect = status ~= "in_progress"
        and statusNeedsAnchor and GkSenderMatchesNamedPlayer(sender, normalizedCapturer)
    local stCurrent = Overlord.GuildKeep:GetState(siteKey)
    local knownAnchor = statusNeedsAnchor and GkKnownAnchorMatches(
        status, stCurrent, guild, remoteFac, anchorShard, anchorStartedAt,
        anchorGenerationAt, normalizedCapturer,
        baseGuild, baseFaction, baseCapturedAt) or false
    local terminalEventAt, terminalAdmissible
    if status == "held" then
        local heldCaptureTs = math.floor(tonumber(caStr) or 0)
        if heldCaptureTs <= 0 or heldCaptureTs > NetworkNow() + MAX_CLOCK_SKEW
            or heldCaptureTs < anchorAttemptStartedAt
            or IsStaleCampaignTimestamp(heldCaptureTs) then return end
        terminalEventAt = heldCaptureTs
        terminalAdmissible = ShouldAcceptGuildKeepCapture(
            siteKey, guild, remoteFac, heldCaptureTs, anchorShard, anchorStartedAt,
            anchorGenerationAt, normalizedCapturer,
            baseGuild, baseFaction, baseCapturedAt)
    elseif status == "aborted" then
        local abortedAt = math.floor(tonumber(caStr) or 0)
        if abortedAt <= 0 or abortedAt > NetworkNow() + MAX_CLOCK_SKEW
            or abortedAt < anchorAttemptStartedAt
            or IsStaleCampaignTimestamp(abortedAt) then return end
        terminalEventAt = abortedAt
        terminalAdmissible = ShouldAcceptGuildKeepAbort(
            siteKey, guild, remoteFac, abortedAt, anchorShard, anchorStartedAt,
            anchorGenerationAt, normalizedCapturer,
            baseGuild, baseFaction, baseCapturedAt)
    end
    if (status == "held" or status == "aborted") and not terminalAdmissible then
        local directlyAttestedAuthority = directAuthority and authorityPlayer
            or (terminalDirect and normalizedCapturer) or ""
        local exactHandled, authorityChanged = RefreshExactGuildKeepTerminalAuthority(
            status, stCurrent, terminalEventAt, directlyAttestedAuthority,
            guild, remoteFac, anchorShard, anchorStartedAt, anchorGenerationAt,
            normalizedCapturer, baseGuild, baseFaction, baseCapturedAt)
        if exactHandled then
            NoteTrustedGuildKeepTraffic(siteKey, true)
            if Overlord.MarkGuildKeepSyncReceived then Overlord:MarkGuildKeepSyncReceived() end
            if authorityChanged and (channel == "WHISPER" or (channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch()))
                and GuildKeepPayloadHasExplicitLocalPool(remotePool) then
                local correctedPayload = BuildGuildKeepPayload(siteKey, stCurrent)
                if correctedPayload then
                    BroadcastGuildKeepToGroup("GK", correctedPayload)
                    SendGuildKeepToChannel("GK", correctedPayload, true)
                end
            end
            return
        end
    end
    -- Un terminal causal valide est une valeur repliquee : tout transport deja approuve
    -- (groupe/canal/roster communautaire) peut le relayer. Exiger a vie le premier tagueur
    -- rendait les clients frais aveugles des qu'il se deconnectait. L'ancre directe reste
    -- obligatoire pour creer/faire avancer un in_progress.
    local trustedTerminalRelay = (status == "held" or status == "aborted")
        and terminalAdmissible == true
    -- Un responder SR/peer de groupe peut relayer l'identite/timer sans devenir lui-meme
    -- l'autorite. Sans ce chemin, seuls les whispers emis par le porteur exact etaient utiles :
    -- /reload et le fan-out raid/canal laissaient donc la majorite des joueurs sans timer.
    local trustedProgressRelay = status == "in_progress" and transportTrusted == true
    if statusNeedsAnchor and not directAuthority and not terminalDirect
        and not knownAnchor and not trustedTerminalRelay and not trustedProgressRelay then return end
    local capturerSourceVerified = directAuthority == true
    if status == "held" then
        if not terminalAdmissible then return end
        local gcPayload = table.concat({
            GK_WIRE_SEMANTIC_VERSION, siteKey, guild, facCode,
            tostring(terminalEventAt), baseGuild, baseFacCode,
            tostring(baseCapturedAt), tostring(anchorShard),
            tostring(math.floor(anchorStartedAt)), tostring(math.floor(anchorGenerationAt)),
            normalizedCapturer, remotePool,
        }, ":")
        -- Un snapshot held v8 est une rediffusion du meme final ancre, jamais une seconde
        -- voie de merge. Tous les effets passent donc par l'unique receveur GC.
        return self:OnReceiveGuildKeepCapture(
            gcPayload, sender, channel,
            directAuthority,
            directAuthority and authorityPlayer or normalizedCapturer)
    end
    if status == "aborted" then
        if not terminalAdmissible then return end
        local gaPayload = table.concat({
            GK_WIRE_SEMANTIC_VERSION, siteKey, guild, facCode,
            tostring(terminalEventAt), baseGuild, baseFacCode,
            tostring(baseCapturedAt), tostring(anchorShard),
            tostring(math.floor(anchorStartedAt)), tostring(math.floor(anchorGenerationAt)),
            normalizedCapturer, remotePool,
        }, ":")
        -- Comme held/GC, un snapshot d'abandon rejoint l'unique merge terminal GA.
        return self:OnReceiveGuildKeepAbort(
            gaPayload, sender, channel,
            directAuthority,
            directAuthority and authorityPlayer or normalizedCapturer)
    end
    if capturerSourceVerified then
        RememberGkCapturerShard(authorityPlayer, anchorShard)
    end

    -- Dedup apres parsing/confiance, et par expéditeur : un relais livre avant le capteur
    -- direct ne peut plus supprimer le seul paquet qui atteste l'ancre.
    local nowD = GetTime()
    local dedupKey = GkRosterMatchKey(sender or "") .. "\031" .. payload
    PruneGkDedup(nowD)
    if GetGuildKeepDedupNode(gkDedup, dedupKey, nowD) then return end
    if not RememberGuildKeepDedup(gkDedup, dedupKey, nowD) then return end

    local remote = {
        status = status,
        holdTimeElapsed = tonumber(holdStr) or 0,
        ownerGuild = guild or "",
        ownerFaction = FactionCodeToFaction(facCode),
        claimedAt = tonumber(caStr) or 0,
        expiresAt = 0,
        updatedAt = remoteTs,
        holdTimeRequired = tonumber(holdReqStr) or nil,
        isContested = remoteIsContested,
        previousOwnerGuild = baseGuild,
        previousOwnerFaction = baseFaction,
        previousClaimedAt = baseCapturedAt,
        previousExpiresAt = 0,
        ownerSourceVerified = ownerSourceVerified,
        capturerSourceVerified = capturerSourceVerified,
        assaultAnchorVerified = assaultAnchorVerified,
        assaultShardId = assaultAnchorVerified and anchorShard or nil,
        assaultShardStartedAt = assaultAnchorVerified and anchorStartedAt or 0,
        assaultGenerationAt = assaultAnchorVerified and anchorGenerationAt or 0,
        assaultShardGuild = assaultAnchorVerified and (guild or "") or "",
        assaultShardFaction = assaultAnchorVerified and remoteFac or nil,
        assaultShardPlayer = assaultAnchorVerified and normalizedCapturer or "",
        assaultBaseGuild = assaultAnchorVerified and baseGuild or "",
        assaultBaseFaction = assaultAnchorVerified and baseFaction or nil,
        assaultBaseCapturedAt = assaultAnchorVerified and baseCapturedAt or 0,
        communitySource = communitySource,
        gkRelayCapturerName = authorityPlayer,
        gkRelayCapturerShard = anchorShard or tonumber(gkCapturerShard),
        gkRelaySenderFallback = sender or "",
        pool = remotePool,
    }
    local stBefore = SnapshotGuildKeepAlertState(Overlord.GuildKeep:GetState(siteKey))
    local applied, recoveryAdvanced =
        Overlord.GuildKeep:ApplyRemoteState(siteKey, remote)
    if not applied then return end
    NoteTrustedGuildKeepTraffic(siteKey, recoveryAdvanced)
    local stAfter = Overlord.GuildKeep:GetState(siteKey)
    if (channel == "WHISPER" or channel == "BETA") and status == "in_progress" and stAfter then
        local deliveredKey = GuildKeepCriticalStartKey(siteKey, stAfter)
        if deliveredKey then seenCommunityGKCriticalStart[siteKey] = deliveredKey end
    end
    -- Seule l'ancre effectivement adoptee prouve qu'un assaut ennemi reste vivant.
    if status == "in_progress" and stAfter and remote.ownerFaction
        and Overlord.PlayerFaction and remote.ownerFaction ~= Overlord.PlayerFaction then
        stAfter._lastEnemyInProgressGkAt = NetworkNow()
    end
    local adoptedAssault = status == "in_progress" and stAfter and stAfter.status == "in_progress"
        and stBefore.status ~= "in_progress"
        and Overlord.GuildKeep:SanitizeGuildName(stAfter.ownerGuild or "") == Overlord.GuildKeep:SanitizeGuildName(guild or "")
        and stAfter.ownerFaction == remoteFac
    if adoptedAssault
        and Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.OnSiegeAssaultBegan then
        Overlord.GuildKeepImmersion:OnSiegeAssaultBegan(siteKey, guild, remoteFac)
    end
    TryPrintGuildKeepDefenderAlert(siteKey, stBefore, stAfter)
    TryPrintGuildKeepAssaultAlert(siteKey, stBefore, stAfter, authorityPlayer, gkCapturerShard)
    MaybeResetGuildKeepDefenderAlert(siteKey, stAfter)
    MaybeResetGuildKeepAssaultAlert(siteKey, stAfter)
    if Overlord.MarkGuildKeepSyncReceived then
        Overlord:MarkGuildKeepSyncReceived()
    end
    -- Un GK ennemi peut arriver par la communaute sur un seul joueur du raid.
    -- Le republier sur les chemins primaires locaux aligne GK sur ZS :
    -- groupe/raid + canal, sans re-fan-out communaute (relai 1-hop).
    if (channel == "WHISPER" or (channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload and payload ~= ""
        and GuildKeepPayloadHasExplicitLocalPool(remotePool) then
        if status == "in_progress" then
            -- Transition locale (notre cote decouvre le siege) : message one-shot critique,
            -- jamais droppe par le budget canal ; les ticks suivants restent repetables.
            local payloadGuild = Overlord.GuildKeep:SanitizeGuildName(guild or "")
            local adoptedProgress = stAfter and stAfter.status == "in_progress"
                and payloadGuild ~= ""
                and Overlord.GuildKeep:SanitizeGuildName(stAfter.ownerGuild or "") == payloadGuild
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
            BroadcastGuildKeepToGroup("GK", payload)
            SendGuildKeepToChannel("GK", payload, transitioned and true or false)
        end
    end
end

local function ParseGuildKeepTerminalPayload(payload, sender, sourceChannel)
    local version, siteKey, guild, facCode, eventTsStr, baseGuild, baseFacCode,
        baseCapturedStr, shardStr, startedStr, generationStr, anchorPlayer, remotePool =
        strsplit(":", payload or "", 13)
    -- GC/GA v7 n'avaient aucun prefixe et generationAt n'etait pas un offset.
    -- Seul v8 est donc admissible ; l'ancien layout ne peut pas etre devine sans ambiguite.
    if version ~= GK_WIRE_SEMANTIC_VERSION then return nil end
    if not siteKey or not Overlord.GuildKeepSites[siteKey] then return nil end
    remotePool = ResolveGuildKeepPayloadPool(remotePool, sender, sourceChannel)
    if not remotePool then return nil end
    local faction = FactionCodeToFaction(facCode)
    local eventTs = NormalizeGuildKeepFinalTimestamp(eventTsStr)
    local anchorShard = tonumber(shardStr)
    local rawStartedAt, rawGenerationAt = tonumber(startedStr), tonumber(generationStr)
    local rawBaseCapturedAt = tonumber(baseCapturedStr)
    local anchorStartedAt = math.floor(rawStartedAt or 0)
    local anchorGenerationAt = math.floor(rawGenerationAt or -1)
    local baseCapturedAt = math.floor(rawBaseCapturedAt or 0)
    if not anchorShard or anchorShard < 0 or anchorShard >= 100000000
        or anchorShard ~= math.floor(anchorShard) or anchorStartedAt <= 0
        or rawStartedAt ~= anchorStartedAt or rawGenerationAt ~= anchorGenerationAt
        or rawBaseCapturedAt ~= baseCapturedAt
        or anchorGenerationAt < 0 or anchorGenerationAt > 1000000
        or anchorStartedAt > NetworkNow() + MAX_CLOCK_SKEW
        or baseCapturedAt < 0 or baseCapturedAt > NetworkNow() + MAX_CLOCK_SKEW then
        return nil
    end
    local attemptStartedAt = Overlord.GuildKeep.GetAssaultAttemptStartedAt
        and math.floor(tonumber(Overlord.GuildKeep:GetAssaultAttemptStartedAt(
            anchorStartedAt, anchorGenerationAt)) or 0) or 0
    anchorPlayer = NormalizeGkCapturerName(anchorPlayer)
    guild = Overlord.GuildKeep:SanitizeGuildName(guild or "")
    baseGuild = Overlord.GuildKeep:SanitizeGuildName(baseGuild or "")
    local baseFaction = FactionCodeToFaction(baseFacCode)
    local validBase = (baseGuild == "" and (baseFacCode or "") == "" and baseCapturedAt == 0)
        or (baseGuild ~= "" and baseFaction ~= nil and baseCapturedAt > 0)
    if not faction or not eventTs or guild == "" or not validBase
        or attemptStartedAt <= 0 or attemptStartedAt > eventTs
        or anchorPlayer == ""
        or (baseCapturedAt > 0 and baseCapturedAt > anchorStartedAt)
        or IsStaleCampaignTimestamp(eventTs) or IsStaleCampaignTimestamp(anchorStartedAt)
        or (baseCapturedAt > 0 and IsStaleCampaignTimestamp(baseCapturedAt))
        or (Overlord.GuildKeep.GetServerSiegeDayKey
            and Overlord.GuildKeep:GetServerSiegeDayKey(anchorStartedAt)
                ~= Overlord.GuildKeep:GetServerSiegeDayKey(eventTs))
        or (Overlord.GuildKeep.IsSiegeGameplayTimestampAllowed
            and not Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(anchorStartedAt)) then
        return nil
    end
    return {
        siteKey = siteKey, guild = guild, faction = faction, facCode = facCode,
        eventTs = eventTs, baseGuild = baseGuild, baseFaction = baseFaction,
        baseFacCode = baseFacCode, baseCapturedAt = baseCapturedAt,
        anchorShard = anchorShard, anchorStartedAt = anchorStartedAt,
        anchorGenerationAt = anchorGenerationAt, attemptStartedAt = attemptStartedAt,
        anchorPlayer = anchorPlayer, pool = remotePool,
    }
end

function Overlord.Sync:OnReceiveGuildKeepAbort(
    payload, sender, sourceChannel, terminalAuthorityAttested, terminalAuthorityPlayer)
    if not payload or not Overlord.GuildKeep or GuildKeepSyncBlocked() then return end
    local terminal = ParseGuildKeepTerminalPayload(payload, sender, sourceChannel)
    if not terminal then return end
    if not self:IsGuildKeepSenderTrusted(
        sender or "", terminal.faction, sourceChannel, "GA") then return end
    local st = Overlord.GuildKeep:GetState(terminal.siteKey)
    if not ShouldAcceptGuildKeepAbort(
        terminal.siteKey, terminal.guild, terminal.faction, terminal.eventTs,
        terminal.anchorShard, terminal.anchorStartedAt,
        terminal.anchorGenerationAt, terminal.anchorPlayer,
        terminal.baseGuild, terminal.baseFaction, terminal.baseCapturedAt) then return end
    local directAnchor = GkSenderMatchesNamedPlayer(sender, terminal.anchorPlayer)
    local directKnownAuthority = GkSenderMatchesObservedCapturer(
        terminal.siteKey, sender or "", terminal.guild, terminal.faction)
    local acceptedTerminalAuthority = terminalAuthorityAttested == true
        and NormalizeGkCapturerName(terminalAuthorityPlayer) or ""
    if acceptedTerminalAuthority == "" and directKnownAuthority then
        acceptedTerminalAuthority = NormalizeGkCapturerName(sender)
    end
    if acceptedTerminalAuthority == "" and directAnchor then
        acceptedTerminalAuthority = terminal.anchorPlayer
    end
    -- L'autorite terminale fait partie du replay utile : si le premier tagueur relaie
    -- avant le successeur reel, le GK direct de ce dernier doit encore corriger le champ.
    local dedupKey = "GA:" .. payload .. "\31" .. acceptedTerminalAuthority:lower()
    local now = GetTime()
    if GetGuildKeepDedupNode(gcDedup, dedupKey, now) then return end
    if not GuildKeepDedupHasCapacity(gcDedup, now) then return end
    if not Overlord.GuildKeep:AbortAssault(
        terminal.siteKey, terminal.guild, terminal.faction, terminal.eventTs,
        terminal.anchorShard, terminal.anchorStartedAt,
        terminal.anchorGenerationAt, terminal.anchorPlayer,
        terminal.baseGuild, terminal.baseFaction, terminal.baseCapturedAt,
        acceptedTerminalAuthority) then return end
    RememberGuildKeepDedup(gcDedup, dedupKey, now)
    if self.PublishGuildKeepDailyProofAfterTerminal then
        self:PublishGuildKeepDailyProofAfterTerminal(terminal.siteKey)
    end
    NoteTrustedGuildKeepTraffic(terminal.siteKey, true)
    if Overlord.MarkGuildKeepSyncReceived then Overlord:MarkGuildKeepSyncReceived() end
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) then
        local statePayload = BuildGuildKeepPayload(
            terminal.siteKey, Overlord.GuildKeep:GetState(terminal.siteKey))
        if statePayload then
            BroadcastGuildKeepToGroup("GK", statePayload)
            SendGuildKeepToChannel("GK", statePayload, true)
        end
    end
    return true
end

function Overlord.Sync:OnReceiveGuildKeepCapture(
    payload, sender, sourceChannel, terminalAuthorityAttested, terminalAuthorityPlayer)
    if not payload or not Overlord.GuildKeep or GuildKeepSyncBlocked() then return end
    local terminal = ParseGuildKeepTerminalPayload(payload, sender, sourceChannel)
    if not terminal then return end
    local siteKey, guild, fac, facCode, remoteTs = terminal.siteKey,
        terminal.guild, terminal.faction, terminal.facCode, terminal.eventTs
    local baseGuild, baseFac, baseFacCode, baseCapturedAt = terminal.baseGuild,
        terminal.baseFaction, terminal.baseFacCode, terminal.baseCapturedAt
    local anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer, remotePool =
        terminal.anchorShard, terminal.anchorStartedAt, terminal.anchorGenerationAt,
        terminal.anchorPlayer, terminal.pool
    if not self:IsGuildKeepSenderTrusted(sender or "", fac, sourceChannel, "GC") then return end
    if not ShouldAcceptGuildKeepCapture(
        siteKey, guild, fac, remoteTs, anchorShard, anchorStartedAt,
        anchorGenerationAt, anchorPlayer,
        baseGuild, baseFac, baseCapturedAt) then return end
    local directAnchor = GkSenderMatchesNamedPlayer(sender, anchorPlayer)
    local directKnownAuthority = GkSenderMatchesObservedCapturer(
        siteKey, sender or "", guild, fac)
    local acceptedTerminalAuthority = terminalAuthorityAttested == true
        and NormalizeGkCapturerName(terminalAuthorityPlayer) or ""
    if acceptedTerminalAuthority == "" and directKnownAuthority then
        acceptedTerminalAuthority = NormalizeGkCapturerName(sender)
    end
    if acceptedTerminalAuthority == "" and directAnchor then
        acceptedTerminalAuthority = anchorPlayer
    end
    local dedupKey = table.concat({
        siteKey, guild, facCode or "", tostring(remoteTs), baseGuild,
        baseFacCode or "", tostring(baseCapturedAt), tostring(anchorShard),
        tostring(anchorStartedAt), tostring(anchorGenerationAt), anchorPlayer,
        acceptedTerminalAuthority:lower(),
    }, ":")
    local now = GetTime()
    if GetGuildKeepDedupNode(gcDedup, dedupKey, now) then return end
    if not GuildKeepDedupHasCapacity(gcDedup, now) then return end

    local before = Overlord.GuildKeep:GetState(siteKey)
    local previousGuild = before and Overlord.GuildKeep:SanitizeGuildName(before.ownerGuild or "") or ""
    local previousStatus = before and before.status or "neutral"
    if not Overlord.GuildKeep:CompleteCapture(siteKey, guild, fac, remoteTs,
        anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFac, baseCapturedAt, acceptedTerminalAuthority) then return end
    local objective = Overlord.GuildKeepSites[siteKey]
    -- Une origine BetaNetwork relayee n'est pas authentifiee : l'etat du donjon suit,
    -- mais aucun point de classement ne lui est attribue.
    local relayedOrigin = self.IsUnauthenticatedRelayOrigin
        and self:IsUnauthenticatedRelayOrigin(sender or "")
    if acceptedTerminalAuthority ~= "" and objective and objective.id and not relayedOrigin
        and Overlord.Leaderboard and Overlord.Leaderboard.CreditPlayerObjectiveCapture then
        local classToken = self.ResolveContributorClassToken
            and self:ResolveContributorClassToken(acceptedTerminalAuthority) or nil
        Overlord.Leaderboard:CreditPlayerObjectiveCapture(
            acceptedTerminalAuthority, objective.id, fac, remoteTs, true, classToken)
    end
    RememberGuildKeepDedup(gcDedup, dedupKey, now)
    NoteTrustedGuildKeepTraffic(siteKey, true)
    if previousStatus ~= "neutral" and previousGuild ~= "" and previousGuild ~= guild
        and Overlord.GuildKeep.FireCrossShardKeepPopup then
        Overlord.GuildKeep:FireCrossShardKeepPopup({
            kind = "already_captured",
            guild = guild,
            fac = fac,
            remoteTs = remoteTs,
            siteKey = siteKey,
            sender = acceptedTerminalAuthority ~= "" and acceptedTerminalAuthority or anchorPlayer,
            senderIsCapturer = acceptedTerminalAuthority ~= "",
            shardId = anchorShard,
        })
    end
    if Overlord.Leaderboard and Overlord.Leaderboard.ApplyGuildKeepTenant then
        Overlord.Leaderboard:ApplyGuildKeepTenant(
            siteKey, guild, fac, remoteTs, remotePool, true)
        if self.PublishGuildKeepDailyProofAfterTerminal then
            self:PublishGuildKeepDailyProofAfterTerminal(siteKey)
        end
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    if Overlord.MarkGuildKeepSyncReceived then
        Overlord:MarkGuildKeepSyncReceived()
    end
    -- Si la verite arrive par communaute, conserver le snapshot GK enrichi (autorite
    -- terminale) sur les chemins locaux. Le degrader en GC faisait rejeter le relais
    -- par tous les peers froids du raid/canal.
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and payload and payload ~= "" and GuildKeepPayloadHasExplicitLocalPool(remotePool) then
        local statePayload = BuildGuildKeepPayload(siteKey, Overlord.GuildKeep:GetState(siteKey))
        if statePayload then
            BroadcastGuildKeepToGroup("GK", statePayload)
            SendGuildKeepToChannel("GK", statePayload, true)
        end
    end
    return true
end

function Overlord.Sync:OnReceiveDominationBoost(payload, sender, sourceChannel)
    if not payload or not OverlordDB or GuildKeepSyncBlocked() then return end
    local facCode, pctStr, epochStr, siteKey, guildStr, remotePool, eventId, deltaStr = strsplit(":", payload, 8)
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = ResolveGuildKeepPayloadPool(wirePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    if not self:IsGuildKeepSenderTrusted(sender or "", fac, sourceChannel, "WB") then return end
    local epoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(epoch) then return end
    local pct = tonumber(pctStr) or 0
    if pct > WB_MAX_TOTAL_PCT then return end
    if not fac or pct <= 0 then return end
    if siteKey ~= "wood_resource" then return end
    -- Boost global bois : pas de lien fortin ; pas de proximite addon seule (spoof)
    if sourceChannel ~= "CHANNEL" and sender and self.IsNearbyAddonSender and self:IsNearbyAddonSender(sender) then
        if not SyncSenderIsInOurGroup(sender) then
            return
        end
    end
    -- Boost public : les deux factions doivent voir la meme domination (via secondes zone).
    eventId = NormalizeDominationBoostEventId(eventId)
    local isWoodSpendEvent = siteKey == "wood_resource" and eventId ~= ""
    local channelSenderVerified = sourceChannel == "CHANNEL"
        and (SyncSenderIsInOurGroup(sender or "")
            or (self.IsGuildKeepCommunitySender and self:IsGuildKeepCommunitySender(sender or "")))
    local weakChannelSender = sourceChannel == "CHANNEL" and not channelSenderVerified
    if isWoodSpendEvent then
        local delta = math.floor((tonumber(deltaStr) or 0) * 10000) / 10000
        if delta <= 0 then return end
        if weakChannelSender then return end
        if delta > WB_CHANNEL_MAX_EVENT_DELTA then return end
        if not self:MarkDominationBoostEventSeen(fac, eventId, epoch) then return end
        -- Canal/groupe : le DX emis au spend porte les secondes exactes (merge max).
        -- Whisper/BNet : relais communaute sans DX dedie ; completer seulement jusqu'au ratio cible.
        local secondsViaWbOnly = (sourceChannel == "WHISPER" or sourceChannel == "BETA") or sourceChannel == "BNET"
        if secondsViaWbOnly and Overlord.ApplyWoodDominationBonusSeconds then
            local applyDelta = delta
            if Overlord.GetDominationDisplayFractions then
                local allyPct, hordePct = Overlord:GetDominationDisplayFractions()
                local currentPct = (fac == "Alliance") and allyPct or hordePct
                local missing = pct - currentPct
                if missing <= 0.000001 then
                    applyDelta = 0
                elseif missing < applyDelta then
                    applyDelta = missing
                end
            end
            if applyDelta > 0 then
                Overlord:ApplyWoodDominationBonusSeconds(fac, applyDelta)
            end
        end
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
        if (sourceChannel ~= "WHISPER" and sourceChannel ~= "BETA") and payload and payload ~= ""
            and GuildKeepPayloadHasExplicitLocalPool(wirePool) then
            local relayPl, relayKey = payload, "WB:" .. payload
            C_Timer.After(0.5, function()
                if Overlord.Sync and Overlord.Sync.RelayDominationBoostToCommunitySafe then
                    Overlord.Sync:RelayDominationBoostToCommunitySafe(relayPl, relayKey, remotePool)
                end
            end)
        end
        return
    end
    -- Snapshots WB legacy sans eventId/delta : ignores (7.1.13+, barre = secondes).
end

-- Preuve quotidienne causale v8 : elle porte le terminal GC/GA complet et
-- projette elle-meme l'unique award, sans protocole de score separe.
local GH_DEDUP_SEC = 86400
local GH_RECEIVE_DEDUP_MAX = 384
local ghReceiveDedup = NewGuildKeepDedup(GH_DEDUP_SEC, GH_RECEIVE_DEDUP_MAX, true)
local ghSendDedup = NewGuildKeepDedup(GH_DEDUP_SEC, GH_RECEIVE_DEDUP_MAX, true)

local function GuildKeepProofMatches(a, b)
    if not a or not b then return false end
    return a.kind == b.kind and a.eventAt == b.eventAt
        and (a.guild or ""):lower() == (b.guild or ""):lower()
        and a.faction == b.faction and tonumber(a.shard) == tonumber(b.shard)
        and a.startedAt == b.startedAt and a.generationAt == b.generationAt
        and GkRosterMatchKey(a.player or "") == GkRosterMatchKey(b.player or "")
        and (a.baseGuild or ""):lower() == (b.baseGuild or ""):lower()
        and a.baseFaction == b.baseFaction and a.baseCapturedAt == b.baseCapturedAt
end

-- Cle semantique bornee : les variantes de transport d'une meme preuve partagent
-- le meme slot de dedup, sans permettre au message GH de creer une preuve terrain.
local function BuildGuildKeepProofSemanticKey(siteKey, dayKey, proof)
    if not proof then return nil end
    return table.concat({
        tostring(siteKey or ""), tostring(dayKey or ""), tostring(proof.kind or ""),
        tostring(math.floor(tonumber(proof.eventAt) or 0)),
        tostring(proof.guild or ""):lower(), tostring(proof.faction or ""),
        tostring(math.floor(tonumber(proof.shard) or -1)),
        tostring(math.floor(tonumber(proof.startedAt) or 0)),
        tostring(math.floor(tonumber(proof.generationAt) or -1)),
        tostring(GkRosterMatchKey(proof.player or "") or ""),
        tostring(proof.baseGuild or ""):lower(), tostring(proof.baseFaction or ""),
        tostring(math.floor(tonumber(proof.baseCapturedAt) or 0)),
        tostring(proof.pool or ""),
    }, "\31")
end

function Overlord.Sync:BroadcastGuildKeepDailyProof(siteKey, dayKey, forceReplay)
    if not siteKey or not dayKey then return end
    local lb = Overlord.Leaderboard
    if not lb or not lb.IsGuildKeepDailyProofCampaignActive
        or not lb:IsGuildKeepDailyProofCampaignActive() then return end
    if GuildKeepSyncBlocked() then
        QueuePendingGuildKeepDailyProof(siteKey, dayKey)
        ScheduleGkCriticalFlushRetry()
        return
    end
    local gateBlocked = Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive())
    local queuedForRetry = false
    if gateBlocked then
        QueuePendingGuildKeepDailyProof(siteKey, dayKey)
        ScheduleGkCriticalFlushRetry()
        queuedForRetry = true
    end
    dayKey = tostring(dayKey or "")
    local pool = CurrentGuildKeepPoolTag()
    local epoch = math.floor(tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0)
    if not isGuildKeepSiegeKey(dayKey) or epoch <= 0 then return end
    if pool == "" then
        if not queuedForRetry then
            QueuePendingGuildKeepDailyProof(siteKey, dayKey)
            ScheduleGkCriticalFlushRetry()
        end
        return
    end
    -- Le wire transporte le winner brut de chaque tenure de depart. La projection de
    -- lineage est locale ; n'envoyer que le winner global ferait perdre une branche valide
    -- si une autre base, d'abord dominante, est ensuite invalidee.
    local proofs = lb and lb.GetRawGuildKeepDailyProofCandidatesForDay
        and lb:GetRawGuildKeepDailyProofCandidatesForDay(siteKey, dayKey) or {}
    if #proofs == 0 then return end
    local now = GetTime()
    PruneGuildKeepDedup(ghSendDedup, now)
    local maxM, delay = GetWbCommunityRelayLimits()
    local function emitProof(payload)
        if not Overlord.Sync or Overlord.InstanceSuspended then return false end
        local sent = BroadcastGuildKeepToGroup("GH", payload)
        sent = SendGuildKeepToChannel("GH", payload, true) or sent
        sent = BroadcastGuildKeepCaptureToCommunity(
            "GH", payload, maxM, delay, true) or sent
        if sent then
            RememberGuildKeepDedup(ghSendDedup, payload, GetTime())
        else
            QueuePendingGuildKeepDailyProof(siteKey, dayKey)
            ScheduleGkCriticalFlushRetry()
        end
        return sent
    end
    local emitted = false
    local replayPayloads = {}
    for _, proof in ipairs(proofs) do
        local payload = BuildGuildKeepDailyProofPayload({
            siteKey = siteKey, dayKey = dayKey, kind = proof.kind,
            eventAt = proof.eventAt, guild = proof.guild, faction = proof.faction,
            baseGuild = proof.baseGuild, baseFaction = proof.baseFaction,
            baseCapturedAt = proof.baseCapturedAt, shard = proof.shard,
            startedAt = proof.startedAt, generationAt = proof.generationAt,
            player = proof.player, epoch = epoch, pool = proof.pool,
        }, pool)
        if payload and (forceReplay or (not GetGuildKeepDedupNode(ghSendDedup, payload, now)
            and GuildKeepDedupHasCapacity(ghSendDedup, now))) then
            emitted = emitProof(payload) or emitted
            if forceReplay then replayPayloads[#replayPayloads + 1] = payload end
        end
    end
    if #replayPayloads > 0 then
        C_Timer.After(2.5, function()
            for _, replayPayload in ipairs(replayPayloads) do emitProof(replayPayload) end
        end)
    end
    if not emitted and not forceReplay then return end
end

function Overlord.Sync:OnReceiveGuildKeepDailyProof(payload, sender, sourceChannel)
    if not payload or not Overlord.Leaderboard or GuildKeepSyncBlocked() then return end
    local version, siteKey, dayKey, kind, eventStr, guild, facCode,
        baseGuild, baseFacCode, baseCapturedStr, shardStr, startedStr,
        generationStr, player, epochStr, remotePool = strsplit(":", payload, 16)
    -- Une GH v7 ne peut pas etre convertie : generationAt n'y est pas l'offset de retry.
    if version ~= GK_WIRE_SEMANTIC_VERSION then return end
    if not siteKey or not Overlord.GuildKeepSites[siteKey]
        or not dayKey or not isGuildKeepSiegeKey(dayKey) then return end
    remotePool = ResolveGuildKeepPayloadPool(remotePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    local baseFac = FactionCodeToFaction(baseFacCode)
    local remoteEpoch = tonumber(epochStr)
    local eventAt = NormalizeGuildKeepFinalTimestamp(eventStr)
    if (kind ~= "GC" and kind ~= "GA") or not fac
        or not IsCurrentSyncCampaignEpoch(remoteEpoch)
        or not eventAt or eventAt <= 0
        or not IsGuildKeepLeaderboardTimestampCurrent(eventAt, remoteEpoch) then return end
    guild = Overlord.GuildKeep and Overlord.GuildKeep.SanitizeGuildName
        and Overlord.GuildKeep:SanitizeGuildName(guild or "") or (guild or "")
    baseGuild = Overlord.GuildKeep and Overlord.GuildKeep.SanitizeGuildName
        and Overlord.GuildKeep:SanitizeGuildName(baseGuild or "") or (baseGuild or "")
    if guild == "" or not SenderRealmMatchesCurrentPool(sender or "", sourceChannel)
        or not self:IsGuildKeepSenderTrusted(sender or "", fac, sourceChannel, "GH") then return end

    local incoming = {
        kind = kind, eventAt = eventAt, guild = guild, faction = fac,
        shard = tonumber(shardStr), startedAt = tonumber(startedStr),
        generationAt = tonumber(generationStr), player = player or "",
        baseGuild = baseGuild, baseFaction = baseFac,
        baseCapturedAt = tonumber(baseCapturedStr), pool = remotePool,
    }
    incoming = Overlord.Leaderboard.NormalizeGuildKeepDailyProof
        and Overlord.Leaderboard:NormalizeGuildKeepDailyProof(
            siteKey, dayKey, incoming) or nil
    if not incoming then return end
    -- Le jour courant reste scelle par le terminal terrain local. Pour un jour ANTERIEUR,
    -- ce terminal n'existe plus necessairement (le registre live ne garde que le dernier) :
    -- le GH causal complet d'un transport deja approuve est alors la replique historique.
    -- Sans cette exception bornee aux jours clos, un client froid refusait definitivement
    -- lundi/mardi au /reload et son leaderboard restait partiel.
    local localProof = Overlord.Leaderboard.BuildGuildKeepDailyProofForState
        and Overlord.Leaderboard:BuildGuildKeepDailyProofForState(siteKey, dayKey) or nil
    local existingProof
    local existingCandidates = Overlord.Leaderboard.GetRawGuildKeepDailyProofCandidatesForDay
        and Overlord.Leaderboard:GetRawGuildKeepDailyProofCandidatesForDay(
            siteKey, dayKey) or {}
    for _, proof in ipairs(existingCandidates) do
        if GuildKeepProofMatches(incoming, proof) then existingProof = proof; break end
    end
    local currentDay = Overlord.GuildKeep and Overlord.GuildKeep.GetServerSiegeDayKey
        and Overlord.GuildKeep:GetServerSiegeDayKey() or ""
    local trustedHistoricalTransport = (sourceChannel == "WHISPER" or sourceChannel == "BETA")
        or sourceChannel == "RAID" or sourceChannel == "PARTY"
    local trustedHistoricalReplay = trustedHistoricalTransport
        and currentDay ~= "" and dayKey < currentDay
    if not GuildKeepProofMatches(incoming, localProof)
        and not GuildKeepProofMatches(incoming, existingProof)
        and not trustedHistoricalReplay then
        if self.PollIfStaleObserverKeep then
            self:PollIfStaleObserverKeep(999, siteKey)
        end
        return
    end

    local function maybeRepairHistoricalTerrain()
        if not trustedHistoricalReplay or not Overlord.GuildKeep then return end
        local gk = Overlord.GuildKeep
        local lb = Overlord.Leaderboard
        local live = gk:GetState(siteKey)
        if live and live._gkDeferredLineage then
            -- ApplyGuildKeepDailyProofSync vient deja de recalculer le winner effectif.
            -- Tant qu'un undo historique est actif, seul le reconciler peut avancer sa
            -- correction sans perdre le descendant qu'il devra peut-etre restaurer.
            return gk:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey)
        end
        local function applyGc(proof)
            if not proof or proof.kind ~= "GC" then return false end
            if lb.WouldGuildKeepCaptureWinOwnDay
                and not lb:WouldGuildKeepCaptureWinOwnDay(siteKey, proof) then
                return false
            end
            local current = gk:GetCurrentTerminalProof(gk:GetState(siteKey))
            if gk:AssaultProofMatches(current, proof) then return false end
            return gk:CompleteCapture(
                siteKey, proof.guild, proof.faction, proof.eventAt, proof.shard,
                proof.startedAt, proof.generationAt, proof.player,
                proof.baseGuild, proof.baseFaction, proof.baseCapturedAt,
                proof.player, true)
        end

        -- Le premier GC peut etre une correction directe du live, ou simplement le
        -- prochain maillon dont la base correspond deja. CompleteCapture conserve les
        -- memes preflights que le message GC terrain.
        local changed = applyGc(incoming)
        live = gk:GetState(siteKey)
        if live and live._gkDeferredLineage then
            gk:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey)
            return changed
        end

        -- B(base A) peut etre arrive avant A(base X). Une fois A applique, les six
        -- branches brutes bornees suffisent pour rejouer toute la chaine du jour.
        local candidates = lb.GetRawGuildKeepDailyProofCandidatesForDay
            and lb:GetRawGuildKeepDailyProofCandidatesForDay(siteKey, dayKey) or {}
        for _ = 1, 6 do
            local advanced = false
            for _, proof in ipairs(candidates) do
                if applyGc(proof) then
                    advanced, changed = true, true
                    break
                end
            end
            live = gk:GetState(siteKey)
            if live and live._gkDeferredLineage then
                gk:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey)
                break
            end
            if not advanced then break end
        end
        return changed
    end

    local dedupKey = BuildGuildKeepProofSemanticKey(siteKey, dayKey, incoming)
    if not dedupKey then return end
    local now = GetTime()
    local seen = GetGuildKeepDedupNode(ghReceiveDedup, dedupKey, now)
    if seen then
        local liveFingerprint = GetStaleKeepPollEpisodeKey(siteKey)
        if seen.repairFingerprint ~= liveFingerprint then
            maybeRepairHistoricalTerrain()
            if Overlord.GuildKeep
                and Overlord.GuildKeep.ReconcileDeferredLineageAfterDailyProofChange then
                Overlord.GuildKeep:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey)
            end
            seen.repairFingerprint = GetStaleKeepPollEpisodeKey(siteKey)
        end
        return
    end
    if not GuildKeepDedupHasCapacity(ghReceiveDedup, now) then return end
    local lb = Overlord.Leaderboard
    local proofApplied = lb:ApplyGuildKeepDailyProofSync(
        siteKey, dayKey, incoming.kind, incoming.eventAt,
        incoming.guild, incoming.faction, incoming.shard,
        incoming.startedAt, incoming.generationAt, incoming.player,
        incoming.baseGuild, incoming.baseFaction, incoming.baseCapturedAt, incoming.pool)
    if not proofApplied then
        local existing
        local candidates = lb.GetRawGuildKeepDailyProofCandidatesForDay
            and lb:GetRawGuildKeepDailyProofCandidatesForDay(siteKey, dayKey) or {}
        for _, proof in ipairs(candidates) do
            if GuildKeepProofMatches(incoming, proof) then existing = proof; break end
        end
        if not existing then return end
    end
    -- Le rattrapage terrain reste borne aux GC effectivement consommes par la lignee.
    maybeRepairHistoricalTerrain()
    if Overlord.GuildKeep and Overlord.GuildKeep.ReconcileDeferredLineageAfterDailyProofChange then
        Overlord.GuildKeep:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey)
    end
    if lb.ReconcileGuildKeepDailyAwardsFromDay then
        lb:ReconcileGuildKeepDailyAwardsFromDay(siteKey, dayKey)
    elseif lb.ReconcileGuildKeepDailyAward then
        lb:ReconcileGuildKeepDailyAward(siteKey, dayKey)
    end
    local remembered = RememberGuildKeepDedup(ghReceiveDedup, dedupKey, now)
    if remembered then remembered.repairFingerprint = GetStaleKeepPollEpisodeKey(siteKey) end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    if (sourceChannel == "WHISPER" or (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) and GuildKeepPayloadHasExplicitLocalPool(remotePool) then
        BroadcastGuildKeepToGroup("GH", payload)
        SendGuildKeepToChannel("GH", payload, true)
    end
end

function Overlord.Sync:PublishGuildKeepDailyProofAfterTerminal(siteKey)
    local gk, lb = Overlord.GuildKeep, Overlord.Leaderboard
    if not gk or not lb or not gk.IsSiegeWindowClosedForToday
        or not gk.GetServerSiegeDayKey
        or not lb.BuildGuildKeepDailyProofForState then return false end
    local st = gk.GetState and gk:GetState(siteKey)
    local terminal = st and gk.GetCurrentTerminalProof and gk:GetCurrentTerminalProof(st)
    if not terminal then return false end
    local dayKey = gk:GetServerSiegeDayKey(terminal.eventAt)
    local currentDay = gk:GetServerSiegeDayKey()
    if dayKey == currentDay and not gk:IsSiegeWindowClosedForToday() then return false end
    local proof = lb:BuildGuildKeepDailyProofForState(siteKey, dayKey)
    if not proof then return false end
    local proofApplied = lb:ApplyGuildKeepDailyProofSync(
        siteKey, dayKey, proof.kind, proof.eventAt, proof.guild, proof.faction,
        proof.shard, proof.startedAt, proof.generationAt, proof.player,
        proof.baseGuild, proof.baseFaction, proof.baseCapturedAt, proof.pool)
    local changed = proofApplied
    if gk.ReconcileDeferredLineageAfterDailyProofChange
        and gk:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey) then
        changed = true
    end
    if lb.ReconcileGuildKeepDailyAwardsFromDay
        and lb:ReconcileGuildKeepDailyAwardsFromDay(siteKey, dayKey) then changed = true end
    if lb.ShouldBroadcastLocalGuildKeepProof
        and lb:ShouldBroadcastLocalGuildKeepProof(proof, siteKey) then
        self:BroadcastGuildKeepDailyProof(siteKey, dayKey, proofApplied)
    end
    return changed
end
