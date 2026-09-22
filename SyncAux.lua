-- SyncAux.lua - Mines (MS/MN), forests (WS/WN), whispers communaute, appel de faction (FC),
-- rattrapage passif SR, filtre whisper hors-ligne et anti-spoof ZS.
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}
Overlord.SyncTuning = Overlord.SyncTuning or {}
local TUNING = Overlord.SyncTuning

-- Reglages de Sync.lua centralises ici pour garder son chunk nettement sous la limite
-- WoW de 200 locales. SyncAux est charge avant tout evenement ADDON_LOADED.
TUNING.MAX_SYNC_KILLS = 9999
TUNING.MAX_SYNC_HOLD_TIME = 600
TUNING.OBSERVER_CAPTURE_CONFIRMATION_COOLDOWN = 8
TUNING.STALE_FRIENDLY_CAPTURE_HEAL_MAX_AGE = 7200
TUNING.STALE_CAPITAL_FRIENDLY_CAPTURE_HEAL_MAX_AGE = 300
TUNING.LOGIN_FRIENDLY_CAPTURE_HEAL_MAX_AGE = 8 * 3600
TUNING.SYNC_GATE_REMOTE_PROGRESS_SECONDS = 45
TUNING.BNET_KILL_INTERVAL = 10
TUNING.KILL_BROADCAST_INTERVAL = 2
TUNING.KILL_BROADCAST_INTERVAL_LARGE = 3
TUNING.BNET_ZS_INTERVAL = 15
TUNING.OBSERVER_CRITICAL_COMMUNITY_MAX = 40
TUNING.OBSERVER_CRITICAL_COMMUNITY_DELAY = 0.25
TUNING.LB_CLASS_REFRESH_FROM_NP_INTERVAL = 2
TUNING.PERIODIC_SYNC_INTERVAL = 30

local L = Overlord.L

local COMMUNITY_WHISPER_MAX = 10
local MN_COMMUNITY_WHISPER_MAX = 50
local COMMUNITY_DIRECT_TARGET_COOLDOWN = 8
local lastCommunityDirectWhisper = {
    values = {},
    nodes = {},
    head = nil,
    tail = nil,
    count = 0,
    max = 4096,
}

function lastCommunityDirectWhisper:Remove(node)
    if not node then return end
    if node.previous then node.previous.next = node.next else self.head = node.next end
    if node.next then node.next.previous = node.previous else self.tail = node.previous end
    self.nodes[node.key] = nil
    self.values[node.key] = nil
    self.count = math.max(0, self.count - 1)
end

function lastCommunityDirectWhisper:Prune(now, budget)
    local removed = 0
    local cutoff = (tonumber(now) or GetTime()) - COMMUNITY_DIRECT_TARGET_COOLDOWN * 4
    while self.head and self.head.timestamp < cutoff
        and removed < math.max(1, math.floor(tonumber(budget) or 1)) do
        self:Remove(self.head)
        removed = removed + 1
    end
end

function lastCommunityDirectWhisper:Remember(key, now)
    if not key or key == "" then return end
    now = tonumber(now) or GetTime()
    self:Prune(now, 8)
    local node = self.nodes[key]
    if node then
        node.timestamp = now
        self.values[key] = now
        if node ~= self.tail then
            if node.previous then node.previous.next = node.next else self.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous = self.tail
            node.next = nil
            if self.tail then self.tail.next = node end
            self.tail = node
            if not self.head then self.head = node end
        end
        return
    end
    if self.count >= self.max then self:Remove(self.head) end
    node = { key = key, timestamp = now, previous = self.tail, next = nil }
    if self.tail then self.tail.next = node else self.head = node end
    self.tail = node
    self.nodes[key] = node
    self.values[key] = now
    self.count = self.count + 1
end

function lastCommunityDirectWhisper:Get(key)
    return self.values[key]
end

function lastCommunityDirectWhisper:Reset()
    wipe(self.values)
    wipe(self.nodes)
    self.head, self.tail, self.count = nil, nil, 0
end
-- Identites choisies localement comme destinataires SR. Leur reponse peut durer
-- plus longtemps que le TTL roster (ticker + backlog), mais ne doit jamais
-- declencher un second scan C_Club depuis le chemin de reception.
local communityExpectedSrResponders = {}
local communityCriticalCursor = 0
local communityRoutineCursor = 0
local bountyEnemyCriticalCursor = 0
local bountyEnemyRoutineCursor = 0

local lastStaleObserverCommunityPoll = 0
local STALE_OBSERVER_POLL_INTERVAL = 22
local STALE_OBSERVER_POLL_INTERVAL_LARGE = 32
local STALE_CAPITAL_OBSERVER_POLL_INTERVAL = 55
local lastObserverFinalStatePoll = 0
local OBSERVER_FINAL_STATE_POLL_INTERVAL = 8
local OBSERVER_FINAL_STATE_ESCALATE_AFTER = 3
local OBSERVER_FINAL_STATE_FORCE_AFTER = 5

local CONSULT_FRONT_SR_COOLDOWN = 60
local lastConsultFrontCommunitySR = {}

local ACTIVE_ZA_COOLDOWN = 75
local ACTIVE_ZA_CAPTURE_COOLDOWN = 24
local PASSIVE_ZA_COOLDOWN = 90
local PASSIVE_STATE_BUNDLE_COOLDOWN = 120
local CONTROLLED_ZA_JITTER_MIN = 1.5
local CONTROLLED_ZA_JITTER_MAX = 6.0
local activeZaLastSentAt = 0
local passiveZaLastSentAt = 0
local controlledZaPending = false
local controlledZaToken = 0
local passiveStateBundleLastSentAt = 0

-- Cache membres en ligne : evite d'iterer tous les membres communaute + N securecall
-- (C_Club.GetMemberInfo) a chaque BroadcastToCommunity (5-15s pendant une capture).
local cachedOnlineMembers = {}
local cachedOnlineMembersTime = 0
local cachedOnlineMembersPrimed = false
-- Un refresh parcourt tous les membres de tous les clubs via securecall. Il ne doit
-- jamais etre cadence par les broadcasts kills (2 s) ou GK (5-12 s).
local ONLINE_MEMBERS_CACHE_TTL = 60
local ONLINE_MEMBERS_CACHE_TTL_LARGE = 120
local ONLINE_MEMBERS_REFRESH_BATCH = 12
local onlineMembersRefreshPending = false
local onlineMembersRefreshToken = 0
local cachedOnlineMemberFaction = {}
local cachedOnlineMemberLevel = {}
local COMMUNITY_CHARACTERS_CACHE_TTL = 30
local COMMUNITY_GUID_RETRY_TTL = 300
local communityRaceById = {}
local communityRaceCheckedAt = {}
local communityGuidMeta = {}
local COMMUNITY_CHARACTERS_REFRESH_BATCH = 12
local COMMUNITY_MEMBERS_READY_TIMEOUT = 20
local communityCharactersRefreshPending = false
local communityCharactersRefreshToken = 0
-- Le tableau des contrats doit aussi voir les personnages hors ligne des clubs Overlord.
-- Son cache est reconstruit par petits lots et remplace atomiquement l'ancien a la fin.
local communityCharacterCache = {
    rows = {},
    byKey = {},
    signature = "",
    revision = 0,
    refreshedAt = 0,
    memberIdsByClub = {},
}
-- Lookup O(1) pour confiance GK/GC (reconstruit avec le cache membres, pas de C_Club par message).
local communitySenderKeys = {}

-- Etat confirme "aucun club" : remplacer en une seule frame tous les index du
-- roster. Cette operation est distincte de l'invalidation stale-while-refresh :
-- un C_Club encore en bootstrap doit continuer a exposer le dernier snapshot.
local function CommitEmptyOnlineMembersSnapshot(sync)
    onlineMembersRefreshToken = onlineMembersRefreshToken + 1
    onlineMembersRefreshPending = false
    cachedOnlineMembers = {}
    cachedOnlineMemberFaction = {}
    cachedOnlineMemberLevel = {}
    communitySenderKeys = {}
    cachedOnlineMembersTime = GetTime()
    cachedOnlineMembersPrimed = true
    if sync then
        sync._communityCriticalRosterRetryCount = 0
        if sync.ClearCommunityTransportQueues then
            sync:ClearCommunityTransportQueues()
        end
    end
end

function Overlord.Sync:CommitEmptyOnlineMembersCache()
    CommitEmptyOnlineMembersSnapshot(self)
end

-- Le registre complet des personnages de communaute est bien plus couteux a reconstruire
-- que la petite liste des membres en ligne. Garder les deux invalidations separees : les
-- retries SR du login rafraichissent plusieurs fois la liste en ligne et ne doivent pas
-- annuler/recommencer le scan des cibles de contrats a chaque tentative.
function Overlord.Sync:InvalidateCommunityMemberCharactersCache()
    communityCharactersRefreshToken = communityCharactersRefreshToken + 1
    communityCharactersRefreshPending = false
    wipe(communityGuidMeta)
    wipe(communityCharacterCache.rows)
    wipe(communityCharacterCache.byKey)
    communityCharacterCache.signature = ""
    communityCharacterCache.revision = communityCharacterCache.revision + 1
    communityCharacterCache.refreshedAt = 0
    wipe(communityCharacterCache.memberIdsByClub)
end

function Overlord.Sync:InvalidateOnlineMembersCache()
    onlineMembersRefreshToken = onlineMembersRefreshToken + 1
    onlineMembersRefreshPending = false
    -- Ne jamais creer une fenetre vide entre deux generations du roster. Les
    -- broadcasts et la validation entrante continuent a lire le dernier snapshot
    -- atomique pendant que le suivant se construit. Une date tres ancienne force
    -- le prochain lecteur a relancer le refresh, meme juste apres le login quand
    -- GetTime() est encore inferieur au TTL normal.
    cachedOnlineMembersTime = -1000000000
    wipe(communityCharacterCache.memberIdsByClub)
    if self.InvalidateCommunityStatsCache then
        self:InvalidateCommunityStatsCache()
    end
end

function Overlord.Sync:HasUsableOnlineMembersCache()
    return cachedOnlineMembersPrimed and #cachedOnlineMembers > 0
end

local FC_COOLDOWN_FACTION = 600
local FC_COOLDOWN_RECV = 600
local FC_COMMUNITY_MAX = 80
local FC_WHISPER_DELAY = 0.35
local FC_MIN_ENEMIES = 5
local FC_COOLDOWN_EPOCH_MIN = 1000000000
local factionCallCommunityCursor = 0
local generalCommunityCursor = 0

local function NormalizeCommunityRosterName(name)
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local dk = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if dk then return dk end
    end
    return ""
end

local function CommunityFactionToken(faction)
    if faction == "Alliance" or faction == "Horde" then return faction end
    local FA = Enum and Enum.PvPFaction
    if not FA then return nil end
    if faction == FA.Alliance then return "Alliance" end
    if faction == FA.Horde then return "Horde" end
    return nil
end

local function ResolveCommunityGuidMeta(info)
    local guid = info and info.guid
    if not guid or guid == "" or not GetPlayerInfoByGUID then return nil end
    local now = GetTime()
    local cached = communityGuidMeta[guid]
    if cached and (cached.complete or now - cached.checkedAt < COMMUNITY_GUID_RETRY_TTL) then
        return cached
    end
    local ok, _, _, _, raceFile, raceSex, _, realm = pcall(GetPlayerInfoByGUID, guid)
    if not ok then
        communityGuidMeta[guid] = { checkedAt = now, complete = false }
        return communityGuidMeta[guid]
    end
    raceFile = type(raceFile) == "string" and raceFile or ""
    raceSex = math.floor(tonumber(raceSex) or 0)
    realm = type(realm) == "string" and realm or ""
    cached = {
        race = raceFile,
        sex = (raceSex == 2 or raceSex == 3) and raceSex or 0,
        realm = realm,
        checkedAt = now,
    }
    cached.complete = cached.race ~= "" and cached.sex > 0
    communityGuidMeta[guid] = cached
    return cached
end

local function ResolveCommunityCharacterName(sync, info)
    if not info or type(info.name) ~= "string" then return nil end
    local memberName = info.name:match("^%s*(.-)%s*$") or ""
    if memberName == "" then return nil end
    if sync.NormalizeContributorFullName then
        memberName = sync:NormalizeContributorFullName(memberName) or memberName
    end
    -- Forever : Prenom Nom. Ne jamais recoller un -Royaume.
    if sync.CanonicalForeverName then
        memberName = sync:CanonicalForeverName(memberName)
    elseif sync.HasCompleteContributorIdentity
        and not sync:HasCompleteContributorIdentity(memberName) then
        memberName = nil
    end
    if not memberName then return nil end
    if sync.IsValidWhisperTarget and not sync:IsValidWhisperTarget(memberName) then
        return nil
    end
    return memberName
end

-- ClubMemberInfo.race : historiquement un RaceId numerique. Sur Midnight, certains
-- clients exposent deja le clientFileString (ex. "Haranir"). Le GUID complete le sexe.
local function ResolveCommunityCharacterRace(sync, info)
    if not info then return "", 0 end
    local raceFile = ""
    local raceSex = 0
    local raceRaw = info.race

    -- Token deja present (string non numerique) : l'enregistrer / normaliser.
    if type(raceRaw) == "string" then
        local trimmed = raceRaw:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" and not tonumber(trimmed) then
            if sync.RegisterTrustedRaceFileToken then
                raceFile = sync:RegisterTrustedRaceFileToken(trimmed) or ""
            end
            if raceFile == "" and sync.NormalizeRaceFileToken then
                raceFile = sync:NormalizeRaceFileToken(trimmed) or ""
            end
            if raceFile == "" then
                raceFile = trimmed
            end
        end
    end

    local raceId = math.floor(tonumber(raceRaw) or 0)
    if raceFile == "" and raceId > 0 and C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
        raceFile = communityRaceById[raceId]
        local checkedAt = communityRaceCheckedAt[raceId] or 0
        if raceFile == nil or (raceFile == "" and GetTime() - checkedAt >= COMMUNITY_GUID_RETRY_TTL) then
            local ok, raceInfo = pcall(C_CreatureInfo.GetRaceInfo, raceId)
            raceFile = ok and raceInfo and type(raceInfo.clientFileString) == "string"
                and raceInfo.clientFileString or ""
            if raceFile ~= "" then
                if sync.RegisterTrustedRaceFileToken then
                    raceFile = sync:RegisterTrustedRaceFileToken(raceFile) or ""
                elseif sync.NormalizeRaceFileToken then
                    raceFile = sync:NormalizeRaceFileToken(raceFile) or ""
                end
            end
            communityRaceById[raceId] = raceFile
            communityRaceCheckedAt[raceId] = GetTime()
        end
    end
    if info.guid and GetPlayerInfoByGUID then
        local guidMeta = ResolveCommunityGuidMeta(info)
        if guidMeta then
            -- GUID gagne toujours s'il connait la race (source client fraiche).
            if guidMeta.race and guidMeta.race ~= "" then
                raceFile = guidMeta.race
            end
            if guidMeta.sex == 2 or guidMeta.sex == 3 then
                raceSex = guidMeta.sex
            end
        end
    end
    if raceFile ~= "" then
        if sync.RegisterTrustedRaceFileToken then
            raceFile = sync:RegisterTrustedRaceFileToken(raceFile) or ""
        elseif sync.NormalizeRaceFileToken then
            raceFile = sync:NormalizeRaceFileToken(raceFile) or ""
        end
    end
    return raceFile, raceSex
end

local function CommitCommunityCharacterCache(sync, allCharactersByKey, refreshToken)
    -- Le scan C_Club est cooperative, mais son ancien commit rematerialisait, triait,
    -- concaténait puis reindexait tout le roster dans une seule frame. Garder ici un
    -- snapshot prive jusqu'a la publication finale, tout en bornant chaque tranche.
    local nextRows, sortKeys, mergeRows, nextByKey = {}, {}, {}, {}
    local collectKey = nil
    local mergeSource, mergeTarget = nextRows, mergeRows
    local mergeWidth, mergeLeft = 1, 1
    local mergeI, mergeJ, mergeIEnd, mergeJEnd, mergeOut
    local hashIndex, hashA, hashB = 1, 0, 0
    local indexCursor = 1
    local workBudget = 768

    local function IsCancelled()
        return refreshToken ~= communityCharactersRefreshToken
            or Overlord.InstanceSuspended or IsInInstance()
    end

    local function Abort()
        if refreshToken == communityCharactersRefreshToken then
            communityCharactersRefreshPending = false
        end
    end

    local function Schedule(step)
        C_Timer.After(0, step)
    end

    local function TimeBudgetExpired(startedAt)
        return startedAt and debugprofilestop
            and debugprofilestop() - startedAt >= 1.25
    end

    local function HashText(text)
        text = tostring(text or "")
        for i = 1, #text do
            local byte = text:byte(i)
            -- Les produits restent tres loin de 2^53 : arithmetique entiere exacte
            -- avec les nombres Lua 5.1, sans dependance bit/bit32.
            hashA = (hashA * 131 + byte) % 2147483647
            hashB = (hashB * 137 + byte) % 2147483629
        end
        hashA = (hashA * 131) % 2147483647
        hashB = (hashB * 137) % 2147483629
    end

    local Publish
    local BuildIndex
    local HashRows
    local SortRows
    local CollectRows

    Publish = function(signature)
        if IsCancelled() then Abort() return end
        communityCharactersRefreshPending = false
        communityCharacterCache.refreshedAt = GetTime()
        if signature == communityCharacterCache.signature then return end

        -- Un lecteur voit soit l'ancien snapshot complet, soit le nouveau complet.
        -- Aucun wipe/rebuild observable ne traverse plusieurs frames.
        communityCharacterCache.rows = mergeSource
        communityCharacterCache.byKey = nextByKey
        communityCharacterCache.signature = signature
        communityCharacterCache.revision = communityCharacterCache.revision + 1
        if Overlord.Leaderboard and Overlord.Leaderboard.MarkMetaDirty then
            Overlord.Leaderboard:MarkMetaDirty()
        end
        -- Le roster est construit par lots apres l'ouverture du panneau. Sans
        -- notification explicite, l'UI conserve sa revision initiale (souvent vide)
        -- jusqu'a ce qu'un autre paquet reseau provoque fortuitement un refresh.
        if Overlord.ManualBountyUI and Overlord.ManualBountyUI.RequestRefresh then
            Overlord.ManualBountyUI:RequestRefresh()
        end
    end

    BuildIndex = function()
        if IsCancelled() then Abort() return end
        local startedAt = debugprofilestop and debugprofilestop() or nil
        local work = 0
        while indexCursor <= #mergeSource and work < workBudget
            and not TimeBudgetExpired(startedAt) do
            local entry = mergeSource[indexCursor]
            local nameKey = sortKeys[entry] or ""
            if nameKey ~= "" then nextByKey[nameKey] = entry end
            local normalized = NormalizeCommunityRosterName(entry.name)
            if normalized ~= "" then nextByKey[normalized] = entry end
            if sync.GetCaptureContributorDedupKey then
                local dk = sync:GetCaptureContributorDedupKey(entry.name)
                if dk and dk ~= "" then nextByKey[dk:lower()] = entry end
            end
            indexCursor = indexCursor + 1
            work = work + 1
        end
        if indexCursor <= #mergeSource then
            Schedule(BuildIndex)
            return
        end
        Publish(#mergeSource == 0 and "" or
            (tostring(#mergeSource) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB)))
    end

    HashRows = function()
        if IsCancelled() then Abort() return end
        local startedAt = debugprofilestop and debugprofilestop() or nil
        local work = 0
        while hashIndex <= #mergeSource and work < workBudget
            and not TimeBudgetExpired(startedAt) do
            local entry = mergeSource[hashIndex]
            HashText(sortKeys[entry])
            HashText(entry.faction or "")
            HashText(entry.race or "")
            HashText(entry.raceSex or 0)
            hashIndex = hashIndex + 1
            work = work + 1
        end
        if hashIndex <= #mergeSource then
            Schedule(HashRows)
            return
        end
        local signature = #mergeSource == 0 and "" or
            (tostring(#mergeSource) .. ":" .. tostring(hashA) .. ":" .. tostring(hashB))
        communityCharacterCache.refreshedAt = GetTime()
        if signature == communityCharacterCache.signature then
            communityCharactersRefreshPending = false
            return
        end
        Schedule(BuildIndex)
    end

    SortRows = function()
        if IsCancelled() then Abort() return end
        local total, work = #mergeSource, 0
        local startedAt = debugprofilestop and debugprofilestop() or nil
        if total <= 1 or mergeWidth >= total then
            hashIndex = 1
            Schedule(HashRows)
            return
        end

        while work < workBudget and not TimeBudgetExpired(startedAt) do
            if not mergeI then
                if mergeLeft > total then
                    mergeSource, mergeTarget = mergeTarget, mergeSource
                    mergeWidth = mergeWidth * 2
                    mergeLeft = 1
                    if mergeWidth >= total then
                        hashIndex = 1
                        Schedule(HashRows)
                        return
                    end
                end
                mergeI = mergeLeft
                mergeIEnd = math.min(mergeLeft + mergeWidth - 1, total)
                mergeJ = mergeIEnd + 1
                mergeJEnd = math.min(mergeLeft + mergeWidth * 2 - 1, total)
                mergeOut = mergeLeft
            end

            while work < workBudget and not TimeBudgetExpired(startedAt)
                and (mergeI <= mergeIEnd or mergeJ <= mergeJEnd) do
                local takeLeft = mergeJ > mergeJEnd
                if not takeLeft and mergeI <= mergeIEnd then
                    -- Stable sur les egalites, donc ordre et signature deterministes.
                    takeLeft = sortKeys[mergeSource[mergeI]] <= sortKeys[mergeSource[mergeJ]]
                end
                if takeLeft then
                    mergeTarget[mergeOut] = mergeSource[mergeI]
                    mergeI = mergeI + 1
                else
                    mergeTarget[mergeOut] = mergeSource[mergeJ]
                    mergeJ = mergeJ + 1
                end
                mergeOut = mergeOut + 1
                work = work + 1
            end
            if mergeI > mergeIEnd and mergeJ > mergeJEnd then
                mergeLeft = mergeLeft + mergeWidth * 2
                mergeI, mergeJ, mergeIEnd, mergeJEnd, mergeOut = nil, nil, nil, nil, nil
            end
        end
        Schedule(SortRows)
    end

    CollectRows = function()
        if IsCancelled() then Abort() return end
        local work = 0
        local startedAt = debugprofilestop and debugprofilestop() or nil
        while work < workBudget and not TimeBudgetExpired(startedAt) do
            local key, entry = next(allCharactersByKey or {}, collectKey)
            collectKey = key
            if key == nil then
                mergeSource, mergeTarget = nextRows, mergeRows
                Schedule(SortRows)
                return
            end
            nextRows[#nextRows + 1] = entry
            sortKeys[entry] = (entry.name or ""):lower()
            work = work + 1
        end
        Schedule(CollectRows)
    end

    CollectRows()
end

local function FactionCallCooldownNow()
    return time()
end

local function NormalizeFactionCallTimestamp(raw)
    local t = tonumber(raw) or 0
    if t <= 0 then return 0 end
    if t < FC_COOLDOWN_EPOCH_MIN then return 0 end
    return t
end

-- Surcharge les versions de base de Sync.lua pour garder la logique passif/communaute
-- hors du chunk principal, deja proche de la limite WoW des 200 locals.
function Overlord.Sync:PollIfStaleObserverInProgress(secondsSinceZs, zone)
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local pollInterval
    if zone and zone.isCapital then
        pollInterval = STALE_CAPITAL_OBSERVER_POLL_INTERVAL
    elseif isLarge then
        pollInterval = STALE_OBSERVER_POLL_INTERVAL_LARGE
    else
        pollInterval = STALE_OBSERVER_POLL_INTERVAL
    end
    if Overlord.InstanceSuspended or not secondsSinceZs or secondsSinceZs < pollInterval then return end
    local now = GetTime()
    if now - lastStaleObserverCommunityPoll < pollInterval then return end
    lastStaleObserverCommunityPoll = now
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        communityMax = isLarge and 3 or 8,
        communityDelay = isLarge and 0.75 or 0.45,
        criticalChannel = true,
    })
end

local function GetObserverFinalStatePollOptions(isLarge, attempts)
    local communityMax
    local communityDelay

    if isLarge then
        if attempts >= OBSERVER_FINAL_STATE_FORCE_AFTER then
            communityMax = 16
        elseif attempts >= OBSERVER_FINAL_STATE_ESCALATE_AFTER then
            communityMax = 10
        else
            communityMax = 6
        end
        communityDelay = 0.45
    else
        if attempts >= OBSERVER_FINAL_STATE_FORCE_AFTER then
            communityMax = 32
        elseif attempts >= OBSERVER_FINAL_STATE_ESCALATE_AFTER then
            communityMax = 20
        else
            communityMax = 12
        end
        communityDelay = 0.30
    end

    return communityMax, communityDelay, attempts >= OBSERVER_FINAL_STATE_FORCE_AFTER
end

-- Timer observateur a 100% : on demande une vraie reponse reseau.
-- Aucun etat local n'est promu ici, la correction vient uniquement de C, ZS captured ou ZA.
function Overlord.Sync:RequestObserverCaptureConfirmationIfComplete(zone)
    if not zone or zone.status ~= "in_progress" then
        if zone then zone._observerFinalStatePollCount = nil end
        return
    end
    if zone.isHolding then return end
    if not Overlord.Zones or not Overlord.Zones.GetObserverHoldTimeElapsed then return end

    local req = tonumber(zone.holdTimeRequired) or 120
    local stored = tonumber(zone.holdTimeElapsed) or 0
    local elapsed = Overlord.Zones:GetObserverHoldTimeElapsed(zone)
    if math.max(elapsed or 0, stored) < req then
        zone._observerFinalStatePollCount = nil
        return
    end
    if Overlord.InstanceSuspended then return end

    local now = GetTime()
    if now - (zone._observerFinalStatePollAt or 0) < OBSERVER_FINAL_STATE_POLL_INTERVAL then return end
    if now - lastObserverFinalStatePoll < OBSERVER_FINAL_STATE_POLL_INTERVAL then return end

    zone._observerFinalStatePollAt = now
    lastObserverFinalStatePoll = now
    zone._observerFinalStatePollCount = (zone._observerFinalStatePollCount or 0) + 1

    local payload = self.GetSRPayload and self:GetSRPayload("T")
    if not payload or payload == "" then return end

    self:Send("SR", payload)
    if IsInRaid() or IsInGroup() then
        self:SendToChannel("SR", payload, true)
    end

    if self.BroadcastToCommunity and Overlord.InActiveFront then
        local isLarge = self.IsLargeEvent and self:IsLargeEvent()
        local maxMembers, delay, forceTargets =
            GetObserverFinalStatePollOptions(isLarge, zone._observerFinalStatePollCount)
        self:BroadcastToCommunity("SR", payload, maxMembers, delay, forceTargets)
    end
end

-- Rattrapage incoherence prerequis : une capture/siege ennemi observe (in_progress distant)
-- implique que l'assaillant tient sa chaine de prerequis (toutes les zones pour une capitale).
-- Si notre carte locale dit le contraire (ex. capitale assiegee par la Horde alors qu'un
-- prerequis est affiche allie), nous avons rate un C / ZS captured cross-faction : l'etat
-- "captured" stale n'est jamais re-verifie par les polls (ils ne surveillent que in_progress).
-- Observateur : on ne corrige RIEN localement (regle dure), on force un SR canal + communaute,
-- seule passerelle cross-faction ; la verite revient via ZS/ZA avec un ts plus recent.
local PREREQ_MISMATCH_CHECK_INTERVAL = 5
local PREREQ_MISMATCH_SR_COOLDOWN = 20
local PREREQ_MISMATCH_MAX_ZS_AGE = 120
local lastPrereqMismatchCheck = 0
local lastPrereqMismatchSR = 0

function Overlord.Sync:RequestPrereqMismatchCatchup(zone)
    if not zone or zone.status ~= "in_progress" or zone.isHolding then return end
    local owner = zone.owner
    local pf = Overlord.PlayerFaction
    -- Seulement une capture ENNEMIE observee : pour les captures alliees, le canal
    -- same-faction (critical) garantit deja la coherence des prerequis.
    if not owner or not pf or owner == pf then return end
    if Overlord.InstanceSuspended then return end
    local now = GetTime()
    if now - lastPrereqMismatchCheck < PREREQ_MISMATCH_CHECK_INTERVAL then return end
    lastPrereqMismatchCheck = now
    if now - lastPrereqMismatchSR < PREREQ_MISMATCH_SR_COOLDOWN then return end
    -- Capture activement entretenue par le reseau : un in_progress orphelin/stale est
    -- deja couvert par PollIfStaleObserverInProgress (pas de double source de SR).
    local age = time() - (tonumber(zone.updatedAt) or 0)
    if age > PREREQ_MISMATCH_MAX_ZS_AGE then return end
    local Z = Overlord.Zones
    if not Z or not Z.FactionMeetsPrereqsForZoneCapture then return end
    if Z:FactionMeetsPrereqsForZoneCapture(zone.id, owner) then return end
    lastPrereqMismatchSR = now
    -- La meilleure source est l'auteur direct du ZS de capitale : il vient de
    -- franchir la chaine et possede donc la photo qui contient le C manque.
    -- Un SR territorial whisper est garanti et conserve l'identite gameplay,
    -- contrairement a un nouvel echantillonnage aleatoire de la communaute.
    local remoteLease = zone._remoteCaptureLease
    local directOrigin = remoteLease and remoteLease.directValidated == true
        and remoteLease.originName or nil
    local srPayload = self.GetSRPayload and self:GetSRPayload("T") or nil
    if directOrigin and directOrigin ~= "" and srPayload and srPayload ~= ""
        and self.IsValidWhisperTarget and self:IsValidWhisperTarget(directOrigin)
        and self.SendWhisper then
        self:SendWhisper("SR", srPayload, directOrigin)
    end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        territorialOnly = true,
        communityMax = isLarge and 6 or 12,
        communityDelay = isLarge and 0.6 or 0.35,
        criticalChannel = true,
    })
end

function Overlord.Sync:ScheduleDeferredConsultFrontRetry()
    if Overlord._loginConsultFrontRetryPending
        or not C_Timer or not C_Timer.After then return end
    local delay = math.max(1, math.min(8,
        tonumber(Overlord._loginConsultFrontRetryDelay) or 1))
    Overlord._loginConsultFrontRetryDelay = math.min(8, delay * 2)
    Overlord._loginConsultFrontRetryPending = true
    C_Timer.After(delay, function()
        Overlord._loginConsultFrontRetryPending = nil
        if not Overlord.IsInitialized or not Overlord._deferredModuleInitDone then return end
        local deferred = Overlord._loginConsultFrontDeferred
        if not deferred or not Overlord.Sync then return end
        Overlord._loginConsultFrontDeferred = nil
        Overlord.Sync:RequestConsultFrontSync(deferred)
    end)
end

function Overlord.Sync:RequestConsultFrontSync(frontId)
    if not frontId or type(frontId) ~= "string" or frontId == "" then return end
    -- MapMarkers peut etre initialise par le timer PLAYER_LOGIN +3 alors que les
    -- sanitizers requis travaillent encore. Ne consommer ni cooldown ni transport
    -- avant LoginSync : garder uniquement le dernier front consulte, puis le runner
    -- Core le rejoue une fois toutes les barrieres terminees.
    if not Overlord._deferredModuleInitDone then
        Overlord._loginConsultFrontDeferred = frontId
        return false
    end
    if Overlord.InstanceSuspended then
        Overlord._loginConsultFrontDeferred = frontId
        self:ScheduleDeferredConsultFrontRetry()
        return false
    end
    if Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()) then
        -- Le commit des sanitizers precede volontairement le burst de capture.
        -- Conserver l'intent jusqu'a la levee de ce second gate ; le retry possede
        -- utilise un backoff borne et ne consomme pas le cooldown d'envoi.
        if Overlord._deferredModuleInitDone then
            Overlord._loginConsultFrontDeferred = frontId
            self:ScheduleDeferredConsultFrontRetry()
        end
        return false
    end
    -- Un appel direct plus recent gagne contre une ancienne relance programmee.
    Overlord._loginConsultFrontDeferred = nil
    Overlord._loginConsultFrontRetryDelay = nil
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local activeId = Overlord.Fronts and Overlord.Fronts.activeFrontId
    if activeId and frontId == activeId then return end
    local now = GetTime()
    local last = lastConsultFrontCommunitySR[frontId] or 0
    -- 0 signifie "jamais envoye", pas "envoye au chargement": sinon le consult
    -- differe a t<60 s serait consomme sans transport apres la barriere.
    if last > 0 and now - last < CONSULT_FRONT_SR_COOLDOWN then return end
    lastConsultFrontCommunitySR[frontId] = now
    self:SendSyncRequest({
        includeCommunity = true,
        allowCommunityInLargeEvent = true,
        communityMax = isLarge and 4 or 8,
        communityDelay = isLarge and 0.75 or 0.45,
    })
end

local function CanSendControlledZoneSnapshot()
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if Overlord.WaitingForSync then return false end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return false end
    if Overlord.LocalFrontAwaitingNetworkSnapshot and Overlord:LocalFrontAwaitingNetworkSnapshot() then
        return false
    end
    return true
end

local function GetElectionName(sync)
    if sync and sync.GetPlayerFullName then
        local full = sync:GetPlayerFullName()
        if full and full ~= "" then return full end
    end
    return UnitName and (UnitName("player") or "") or ""
end

local function IsControlledZoneSnapshotSender(sync, windowSec, pct)
    pct = tonumber(pct) or 0
    if pct >= 100 then return true end
    if pct <= 0 then return false end
    local now = GetTime()
    local bucket = math.floor(now / math.max(1, windowSec or ACTIVE_ZA_COOLDOWN))
    local name = GetElectionName(sync)
    local hash = bucket * 37
    for i = 1, #name do
        hash = (hash + (string.byte(name, i) or 0) * (i + 11)) % 9973
    end
    return (hash % 100) < pct
end

function Overlord.Sync:ScheduleControlledZoneSnapshot(reason, opts)
    opts = opts or {}
    if not self.BroadcastCompactZoneSnapshot then return false end
    if controlledZaPending then
        if not opts.force then return false end
        controlledZaToken = controlledZaToken + 1
        controlledZaPending = false
    end
    if not CanSendControlledZoneSnapshot() then return false end

    local now = GetTime()
    local active = Overlord.InActiveFront
    local cooldown = opts.cooldown
    if not cooldown then
        if not active then
            cooldown = PASSIVE_ZA_COOLDOWN
        elseif reason == "capture" then
            cooldown = ACTIVE_ZA_CAPTURE_COOLDOWN
        else
            cooldown = ACTIVE_ZA_COOLDOWN
        end
    end

    local last = active and activeZaLastSentAt or passiveZaLastSentAt
    if now - last < cooldown then return false end

    if active and not opts.force then
        local isLarge = self.IsLargeEvent and self:IsLargeEvent()
        local pct = opts.electionPct
            or (isLarge and (opts.largeElectionPct or 12) or (opts.smallElectionPct or 100))
        if not IsControlledZoneSnapshotSender(self, cooldown, pct) then return false end
    end

    controlledZaPending = true
    controlledZaToken = controlledZaToken + 1
    local token = controlledZaToken
    local jitterMin = opts.jitterMin or CONTROLLED_ZA_JITTER_MIN
    local jitterMax = opts.jitterMax or CONTROLLED_ZA_JITTER_MAX
    local delay = jitterMin + math.random() * math.max(0, jitterMax - jitterMin)
    C_Timer.After(delay, function()
        if token ~= controlledZaToken then return end
        if not Overlord.Sync or not Overlord.Sync.BroadcastCompactZoneSnapshot then
            controlledZaPending = false
            return
        end
        if not CanSendControlledZoneSnapshot() then
            controlledZaPending = false
            return
        end
        local t = GetTime()
        local currentlyActive = Overlord.InActiveFront
        local lastSent = currentlyActive and activeZaLastSentAt or passiveZaLastSentAt
        if t - lastSent < cooldown then
            controlledZaPending = false
            return
        end
        if currentlyActive and not opts.force then
            local isLarge = Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
            local pct = opts.electionPct
                or (isLarge and (opts.largeElectionPct or 12) or (opts.smallElectionPct or 100))
            if not IsControlledZoneSnapshotSender(Overlord.Sync, cooldown, pct) then
                controlledZaPending = false
                return
            end
        end
        local sent = Overlord.Sync:BroadcastCompactZoneSnapshot()
        if sent then
            if currentlyActive then
                activeZaLastSentAt = t
            else
                passiveZaLastSentAt = t
            end
        end
        controlledZaPending = false
    end)
    return true
end

function Overlord.Sync:ShouldRunPassiveStateBundle(opts)
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if Overlord.WaitingForSync then return false end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return false end
    opts = opts or {}
    local cooldown = opts.cooldown or PASSIVE_STATE_BUNDLE_COOLDOWN
    local now = GetTime()
    if now - passiveStateBundleLastSentAt < cooldown then return false end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local pct = opts.electionPct
        or (isLarge and (opts.largeElectionPct or 10) or (opts.smallElectionPct or 25))
    if not IsControlledZoneSnapshotSender(self, cooldown, pct) then return false end
    passiveStateBundleLastSentAt = now
    return true
end

-- Accumulateur domination : election deterministe par fenetre de 120 s.
-- En gros event, peu de clients tickent ; en petit groupe (<=6), tout le monde tick
-- et la fusion DX (total max a seq egale) fait converger.
function Overlord.Sync:ShouldAccumulateDomination()
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if Overlord.WaitingForSync then return false end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local pct = isLarge and 15 or 35
    -- Solo = groupe de 1 : tout le monde tick, la fusion DX fait converger.
    -- Sans ca, un joueur seul (cas typique Forever) reste bloque a 0 %.
    if not isLarge then
        local n = 1
        if IsInGroup() or IsInRaid() then
            n = GetNumGroupMembers() or 1
            if n < 1 then n = 1 end
        end
        if n <= 6 then
            pct = 100
        end
    end
    return IsControlledZoneSnapshotSender(self, 120, pct)
end

local function SanitizeFactionCallSavedTimestamps(fac)
    if not OverlordDB then return end
    OverlordDB.factionCallSharedAt = OverlordDB.factionCallSharedAt or {}
    if fac and OverlordDB.factionCallSharedAt[fac]
        and NormalizeFactionCallTimestamp(OverlordDB.factionCallSharedAt[fac]) <= 0 then
        OverlordDB.factionCallSharedAt[fac] = nil
    end
    if OverlordDB.factionCallLastAt
        and NormalizeFactionCallTimestamp(OverlordDB.factionCallLastAt) <= 0 then
        OverlordDB.factionCallLastAt = nil
    end
end

local function FactionCallEnemyCountOk(forceRefresh)
    if not Overlord.InActiveFront then return false end
    if Overlord.UI and Overlord.UI.GetNearbyEnemyCountRaw then
        return Overlord.UI:GetNearbyEnemyCountRaw(forceRefresh) >= FC_MIN_ENEMIES
    end
    return false
end

-- ============ Stock mine (MS) ============

function Overlord.Sync:MaybeBroadcastMineStock(mineId)
    if not mineId or Overlord.WaitingForSync then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local p = self:GetPriv()
    if not p then return end
    local res = Overlord.Ressources
    if not res or not res.GetMineStock then return end
    local now = GetTime()
    if (p.mineStockLast[mineId] or 0) + p.mineStockInterval > now then return end
    p.mineStockLast[mineId] = now
    local stock = res:GetMineStock(mineId)
    local cap = (res.GetMineStockMax and res:GetMineStockMax()) or 100
    stock = math.max(0, math.min(cap, math.floor(tonumber(stock) or 0)))
    local payload = mineId .. ":" .. stock
    self:SendToChannel("MS", payload)
    if IsInGroup() or IsInRaid() then
        self:Send("MS", payload)
    end
    if not self.IsLargeEvent or not self:IsLargeEvent() then
        if (p.mineStockBNetLast[mineId] or 0) + p.mineStockBNetInterval <= now then
            p.mineStockBNetLast[mineId] = now
            self:SendToBNetFriends("MS", payload)
        end
    end
end

function Overlord.Sync:OnReceiveMineStock(payload, sender)
    if not payload or payload == "" then return end
    local mineId, stockStr = strsplit(":", payload, 2)
    if not mineId or not stockStr then return end
    if Overlord.Ressources and Overlord.Ressources.ApplyRemoteMineStock then
        Overlord.Ressources:ApplyRemoteMineStock(mineId, stockStr)
    end
end

-- ============ Stock foret (WS) ============

function Overlord.Sync:MaybeBroadcastWoodStock(woodId)
    if not woodId or Overlord.WaitingForSync then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local p = self:GetPriv()
    if not p then return end
    local res = Overlord.Ressources
    if not res or not res.GetWoodStock then return end
    local now = GetTime()
    if (p.woodStockLast[woodId] or 0) + p.woodStockInterval > now then return end
    p.woodStockLast[woodId] = now
    local stock = res:GetWoodStock(woodId)
    local cap = (res.GetWoodStockMax and res:GetWoodStockMax()) or 100
    stock = math.max(0, math.min(cap, math.floor(tonumber(stock) or 0)))
    local payload = woodId .. ":" .. stock
    self:SendToChannel("WS", payload)
    if IsInGroup() or IsInRaid() then
        self:Send("WS", payload)
    end
    if not self.IsLargeEvent or not self:IsLargeEvent() then
        if (p.woodStockBNetLast[woodId] or 0) + p.woodStockBNetInterval <= now then
            p.woodStockBNetLast[woodId] = now
            self:SendToBNetFriends("WS", payload)
        end
    end
end

function Overlord.Sync:OnReceiveWoodStock(payload, sender)
    if not payload or payload == "" then return end
    local woodId, stockStr = strsplit(":", payload, 2)
    if not woodId or not stockStr then return end
    if Overlord.Ressources and Overlord.Ressources.ApplyRemoteWoodStock then
        Overlord.Ressources:ApplyRemoteWoodStock(woodId, stockStr)
    end
end

-- ============ Recolte bois (WN) ============

function Overlord.Sync:BroadcastWoodHarvesting(woodId)
    if not woodId then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if Overlord.WaitingForSync then return end
    if not self:GetChannelId() then
        local now = GetTime()
        if not self._lastWoodChannelJoinAttempt or now - self._lastWoodChannelJoinAttempt > 20 then
            self._lastWoodChannelJoinAttempt = now
            self:JoinChannel(1)
        end
    end
    local factionCode = (Overlord.PlayerFaction == "Alliance") and "A" or "H"
    local payload = woodId .. ":" .. factionCode
    local extraWhispers = nil
    local res = Overlord.Ressources
    if res and res.GetWoodStock then
        local stock = res:GetWoodStock(woodId)
        local cap = (res.GetWoodStockMax and res:GetWoodStockMax()) or 100
        stock = math.max(0, math.min(cap, math.floor(tonumber(stock) or 0)))
        extraWhispers = { { type = "WS", payload = woodId .. ":" .. stock } }
    end
    self:SendToGroup("WN", payload)
    self:SendToChannel("WN", payload)
    if not self.IsLargeEvent or not self:IsLargeEvent() then
        self:BroadcastToCommunity("WN", payload, MN_COMMUNITY_WHISPER_MAX, 0.5, nil, extraWhispers)
        self:SendToBNetFriends("WN", payload)
        if extraWhispers and extraWhispers[1] and extraWhispers[1].payload ~= "" then
            self:SendToBNetFriends(extraWhispers[1].type, extraWhispers[1].payload)
        end
    end
end

function Overlord.Sync:OnReceiveWoodHarvesting(payload, sender)
    if not payload or payload == "" then return end
    if not Overlord.Zones then return end

    local woodId, factionCode = strsplit(":", payload, 3)
    woodId = woodId and woodId:match("^%s*(.-)%s*$") or woodId
    if not woodId or woodId == "" then return end

    local senderFaction = nil
    if factionCode == "A" then senderFaction = "Alliance"
    elseif factionCode == "H" then senderFaction = "Horde" end

    if not senderFaction or senderFaction == Overlord.PlayerFaction then return end

    local p = self:GetPriv()
    if not p then return end
    local now = GetTime()
    if (p.woodAlertLast[woodId] or 0) + p.woodAlertCooldown > now then return end
    p.woodAlertLast[woodId] = now
    local woodZone = Overlord.Zones.GetWoodZone and Overlord.Zones:GetWoodZone(woodId)
    local woodName = woodZone and woodZone.name or woodId
    local line = (senderFaction == "Horde" and L and L.ENEMY_WOOD_HORDE)
        or (senderFaction == "Alliance" and L and L.ENEMY_WOOD_ALLIANCE)
    if line then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. line, woodName))
    end
end

-- ============ Minage (MN) ============

function Overlord.Sync:BroadcastMining(mineId)
    if not mineId then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if Overlord.WaitingForSync then return end
    if not self:GetChannelId() then
        local now = GetTime()
        if not self._lastMineChannelJoinAttempt or now - self._lastMineChannelJoinAttempt > 20 then
            self._lastMineChannelJoinAttempt = now
            self:JoinChannel(1)
        end
    end
    local factionCode = (Overlord.PlayerFaction == "Alliance") and "A" or "H"
    local payload = mineId .. ":" .. factionCode
    local extraWhispers = nil
    local res = Overlord.Ressources
    if res and res.GetMineStock then
        local stock = res:GetMineStock(mineId)
        local cap = (res.GetMineStockMax and res:GetMineStockMax()) or 100
        stock = math.max(0, math.min(cap, math.floor(tonumber(stock) or 0)))
        extraWhispers = { { type = "MS", payload = mineId .. ":" .. stock } }
    end
    self:SendToGroup("MN", payload)
    self:SendToChannel("MN", payload)
    if not self.IsLargeEvent or not self:IsLargeEvent() then
        self:BroadcastToCommunity("MN", payload, MN_COMMUNITY_WHISPER_MAX, 0.5, nil, extraWhispers)
        self:SendToBNetFriends("MN", payload)
        if extraWhispers and extraWhispers[1] and extraWhispers[1].payload ~= "" then
            self:SendToBNetFriends(extraWhispers[1].type, extraWhispers[1].payload)
        end
    end
end

-- Construit / rafraichit le cache des membres en ligne (noms Nom-Royaume complets).
-- Evite N securecall(C_Club.GetMemberInfo) a chaque broadcast (lourd avec 200+ membres).

-- Helpers nommes (crees une seule fois) pour eviter N closures/appel dans la boucle membres.
local _scClubId, _scMemberId, _scInfo
local function _secureFetchMemberInfo()
    _scInfo = C_Club.GetMemberInfo(_scClubId, _scMemberId)
end
local _scMembersReady
local function _secureFocusMembers()
    C_Club.FocusMembers(_scClubId)
end
local function _secureAreMembersReady()
    _scMembersReady = C_Club.AreMembersReady(_scClubId) == true
end
local function _secureFetchAllMembersSnapshot()
    local members = C_Club.GetClubMembers(_scClubId)
    local snapshot = {}
    for i = 1, members and #members or 0 do
        local memberId = members[i]
        if memberId ~= nil then snapshot[#snapshot + 1] = memberId end
    end
    communityCharacterCache.memberIdsSnapshot = snapshot
end

local function GetClubMemberIdsSnapshot(clubId)
    local now = GetTime()
    local cached = communityCharacterCache.memberIdsByClub[clubId]
    if cached and now - (cached.refreshedAt or 0) < 30 then return cached.rows end
    _scClubId = clubId
    communityCharacterCache.memberIdsSnapshot = nil
    securecall(_secureFetchAllMembersSnapshot)
    local rows = communityCharacterCache.memberIdsSnapshot or {}
    communityCharacterCache.memberIdsSnapshot = nil
    communityCharacterCache.memberIdsByClub[clubId] = { rows = rows, refreshedAt = now }
    return rows
end

local function RefreshOnlineMembersCache(sync, forceRefresh, minTtl)
    local now = GetTime()
    local ttl = ONLINE_MEMBERS_CACHE_TTL
    if sync and sync.IsLargeEvent and sync:IsLargeEvent() then
        ttl = ONLINE_MEMBERS_CACHE_TTL_LARGE
    end
    if minTtl and minTtl > ttl then
        ttl = minTtl
    end
    if cachedOnlineMembersPrimed and not forceRefresh and now - cachedOnlineMembersTime < ttl then
        return cachedOnlineMembers
    end
    -- Le chemin kill/GK appelle ce helper depuis le gameplay. Un roster stale vaut
    -- mieux qu'une boucle de centaines de C_Club.GetMemberInfo dans une frame de combat.
    -- S'il n'est pas encore prime, les transports groupe/canal/BNet restent disponibles.
    if InCombatLockdown and InCombatLockdown() then
        return cachedOnlineMembers
    end
    -- Stale-while-refresh : tous les transports continuent a lire le dernier snapshot
    -- complet. Un broadcast ne doit jamais attendre ni relancer le parcours C_Club.
    if onlineMembersRefreshPending then return cachedOnlineMembers end

    local sourceClubIds
    if sync.FindAllCommunityClubs then
        sourceClubIds = sync:FindAllCommunityClubs()
    end
    if not sourceClubIds or #sourceClubIds == 0 then
        local single = sync.FindCommunityClub and sync:FindCommunityClub()
        sourceClubIds = single and { single } or {}
    end
    -- FindAllCommunityClubs expose son tableau interne. Le refresh peut traverser
    -- plusieurs frames : conserver une copie ordinaire et stable.
    local clubIds = {}
    for i = 1, #sourceClubIds do clubIds[i] = sourceClubIds[i] end
    if #clubIds == 0 then
        local searchSettled = sync.IsCommunitySearchSettled
            and sync:IsCommunitySearchSettled() == true
        local membershipConfirmedAbsent = OverlordDB
            and OverlordDB.inCommunity == false
        if searchSettled or membershipConfirmedAbsent then
            CommitEmptyOnlineMembersSnapshot(sync)
        end
        return cachedOnlineMembers
    end

    local ONLINE = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Online or 1
    local AWAY   = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Away or 2
    local BUSY   = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Busy or 3
    local nextOnlineMembers = {}
    local nextOnlineMemberFaction = {}
    local nextOnlineMemberLevel = {}
    -- Distinct de nextOnlineMembers : la reception d'un whisper prouve deja que
    -- le personnage est en ligne. La confiance doit donc suivre le roster complet
    -- du club, sans rejeter un membre qui vient de se connecter apres le snapshot
    -- de presence precedent.
    local nextCommunitySenderKeys = {}
    local seenMemberKeys = {}

    local function AddCommunityMemberKeys(memberName)
        if not memberName or memberName == "" then return end
        if not sync.IsValidWhisperTarget or not sync:IsValidWhisperTarget(memberName) then return end
        local dedupKey = memberName:lower()
        if sync.GetCaptureContributorDedupKey then
            local dk = sync:GetCaptureContributorDedupKey(memberName)
            if dk and dk ~= "" then dedupKey = dk:lower() end
        end
        local normalized = NormalizeCommunityRosterName(memberName)
        nextCommunitySenderKeys[memberName:lower()] = true
        if normalized ~= "" then nextCommunitySenderKeys[normalized] = true end
        nextCommunitySenderKeys[dedupKey] = true
        return dedupKey, normalized
    end

    local function TryAddOnlineMember(memberName, faction, level, dedupKey, normalized)
        if not dedupKey then
            dedupKey, normalized = AddCommunityMemberKeys(memberName)
        end
        if not dedupKey or seenMemberKeys[dedupKey] then return end
        seenMemberKeys[dedupKey] = true
        nextOnlineMembers[#nextOnlineMembers + 1] = memberName
        if faction ~= nil then
            nextOnlineMemberFaction[memberName:lower()] = faction
            nextOnlineMemberFaction[dedupKey] = faction
            if normalized ~= "" then
                nextOnlineMemberFaction[normalized] = faction
            end
        end
        level = math.floor(tonumber(level) or 0)
        if level > 0 then
            nextOnlineMemberLevel[memberName:lower()] = level
            nextOnlineMemberLevel[dedupKey] = level
            if normalized ~= "" then nextOnlineMemberLevel[normalized] = level end
        end
    end

    onlineMembersRefreshPending = true
    onlineMembersRefreshToken = onlineMembersRefreshToken + 1
    local refreshToken = onlineMembersRefreshToken
    local clubIndex, memberIndex, memberIds = 1, 1, nil

    local function FinishRefresh()
        if refreshToken ~= onlineMembersRefreshToken then return end
        -- Commit atomique : aucun lecteur ne voit un roster partiellement reconstruit.
        cachedOnlineMembers = nextOnlineMembers
        cachedOnlineMemberFaction = nextOnlineMemberFaction
        cachedOnlineMemberLevel = nextOnlineMemberLevel
        communitySenderKeys = nextCommunitySenderKeys
        cachedOnlineMembersTime = GetTime()
        cachedOnlineMembersPrimed = true
        onlineMembersRefreshPending = false
        sync._communityCriticalRosterRetryCount = 0
        if sync.SchedulePendingCommunityCriticalReplayFlush then
            sync:SchedulePendingCommunityCriticalReplayFlush()
        end
    end

    local function ProcessBatch()
        if refreshToken ~= onlineMembersRefreshToken
            or Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            if refreshToken == onlineMembersRefreshToken then
                onlineMembersRefreshPending = false
            end
            return
        end
        local processed = 0
        while processed < ONLINE_MEMBERS_REFRESH_BATCH do
            if clubIndex > #clubIds then
                _scInfo = nil
                FinishRefresh()
                return
            end
            if not memberIds then
                memberIds = GetClubMemberIdsSnapshot(clubIds[clubIndex])
                memberIndex = 1
            end
            local memberId = memberIds[memberIndex]
            if memberId then
                _scClubId = clubIds[clubIndex]
                _scMemberId = memberId
                _scInfo = nil
                securecall(_secureFetchMemberInfo)
                local info = _scInfo
                if info then
                    local memberName = ResolveCommunityCharacterName(sync, info)
                    local dedupKey, normalized = AddCommunityMemberKeys(memberName)
                    local p = info.presence
                    if not info.isSelf and memberName
                        and p and (p == ONLINE or p == AWAY or p == BUSY) then
                        TryAddOnlineMember(
                            memberName, info.faction, info.level, dedupKey, normalized)
                    end
                end
                memberIndex = memberIndex + 1
                processed = processed + 1
            else
                clubIndex = clubIndex + 1
                memberIds = nil
            end
        end
        _scInfo = nil
        C_Timer.After(0, ProcessBatch)
    end

    -- Retail peut exposer le club avant son roster. Sans cette gate, une lecture
    -- transitoire vide remplacait le dernier snapshot valide pendant 60-120 s.
    if C_Club.FocusMembers then
        for i = 1, #clubIds do
            _scClubId = clubIds[i]
            securecall(_secureFocusMembers)
        end
    end
    local readyWaitStartedAt = GetTime()
    local readyWaitDelay = 0.1
    local function WaitForMemberData()
        if refreshToken ~= onlineMembersRefreshToken
            or Overlord.InstanceSuspended or IsInInstance() then
            if refreshToken == onlineMembersRefreshToken then
                onlineMembersRefreshPending = false
            end
            return
        end
        local allReady = true
        if C_Club.AreMembersReady then
            for i = 1, #clubIds do
                _scClubId = clubIds[i]
                _scMembersReady = false
                securecall(_secureAreMembersReady)
                if not _scMembersReady then
                    allReady = false
                    break
                end
            end
        end
        if allReady then
            ProcessBatch()
            return
        end
        if GetTime() - readyWaitStartedAt >= COMMUNITY_MEMBERS_READY_TIMEOUT then
            -- Conserver le snapshot precedent et reessayer seulement si un final
            -- attend vraiment le roster ; aucun polling permanent a vide.
            onlineMembersRefreshPending = false
            local pending = sync._pendingCommunityCriticalReplays
            local retries = tonumber(sync._communityCriticalRosterRetryCount) or 0
            if pending and #pending > 0 and retries < 3 then
                sync._communityCriticalRosterRetryCount = retries + 1
                C_Timer.After(5, function()
                    if Overlord.Sync == sync and not Overlord.InstanceSuspended
                        and not IsInInstance() then
                        RefreshOnlineMembersCache(sync, true, minTtl)
                    end
                end)
            end
            return
        end
        local delay = readyWaitDelay
        readyWaitDelay = math.min(1, readyWaitDelay * 2)
        C_Timer.After(delay, WaitForMemberData)
    end

    WaitForMemberData()
    return cachedOnlineMembers
end

local function CachedMemberFactionMatches(memberName, playerFaction)
    if not memberName or memberName == "" then return false end
    local faction = cachedOnlineMemberFaction[memberName:lower()]
    if faction == nil then return true end
    local FA = Enum.PvPFaction
    if not FA then return true end
    if playerFaction == "Horde" then
        return faction == FA.Horde
    end
    return faction == FA.Alliance
end

function Overlord.Sync:GetOnlineCommunityMembers(forceRefresh, minTtl)
    if Overlord.CommunityModeEnabled == false then
        return Overlord.BetaNetwork and Overlord.BetaNetwork:GetPeers() or {}
    end
    if Overlord.InstanceSuspended or IsInInstance() then return {} end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return {} end
    return RefreshOnlineMembersCache(self, forceRefresh, minTtl)
end

function Overlord.Sync:RequestCommunityMemberCharactersRefresh(forceRefresh, minTtl)
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if communityCharactersRefreshPending then return false end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return false end
    local ttl = math.max(1, tonumber(minTtl) or COMMUNITY_CHARACTERS_CACHE_TTL)
    local now = GetTime()
    if not forceRefresh and communityCharacterCache.refreshedAt > 0
        and now - communityCharacterCache.refreshedAt < ttl then
        return false
    end
    communityCharactersRefreshPending = true
    communityCharactersRefreshToken = communityCharactersRefreshToken + 1
    local refreshToken = communityCharactersRefreshToken
    local sync = self

    C_Timer.After(0, function()
        if refreshToken ~= communityCharactersRefreshToken
            or Overlord.InstanceSuspended or IsInInstance() then
            if refreshToken == communityCharactersRefreshToken then
                communityCharactersRefreshPending = false
            end
            return
        end

        local sourceClubIds = sync.FindAllCommunityClubs and sync:FindAllCommunityClubs() or nil
        if not sourceClubIds or #sourceClubIds == 0 then
            local single = sync.FindCommunityClub and sync:FindCommunityClub()
            sourceClubIds = single and { single } or {}
        end
        -- FindAllCommunityClubs expose le tableau interne de Sync. Le copier est
        -- obligatoire : un rescan periodique des clubs peut wipe ce tableau pendant
        -- notre traitement par lots et faire valider un faux roster vide.
        local clubIds = {}
        for i = 1, #sourceClubIds do
            clubIds[i] = sourceClubIds[i]
        end
        if #clubIds == 0 then
            communityCharactersRefreshPending = false
            return
        end
        local allCharactersByKey = {}
        local clubIndex, memberIndex, memberIds = 1, 1, nil

        local function AddCharacter(memberName, faction, race, raceSex)
            local factionToken = CommunityFactionToken(faction)
            if not memberName or memberName == "" or not factionToken then return end
            local dedupKey = memberName:lower()
            if sync.GetCaptureContributorDedupKey then
                local dk = sync:GetCaptureContributorDedupKey(memberName)
                if dk and dk ~= "" then dedupKey = dk:lower() end
            end
            local existing = allCharactersByKey[dedupKey]
            if not existing then
                allCharactersByKey[dedupKey] = {
                    name = memberName,
                    faction = factionToken,
                    race = race or "",
                    raceSex = raceSex or 0,
                }
                return
            end
            if #memberName > #(existing.name or "") then existing.name = memberName end
            if not existing.faction then existing.faction = factionToken end
            if race and race ~= "" then existing.race = race end
            raceSex = math.floor(tonumber(raceSex) or 0)
            if raceSex == 2 or raceSex == 3 then existing.raceSex = raceSex end
        end

        local function FinishRefresh()
            if refreshToken ~= communityCharactersRefreshToken then return end
            CommitCommunityCharacterCache(sync, allCharactersByKey, refreshToken)
        end

        local function ProcessBatch()
            if refreshToken ~= communityCharactersRefreshToken
                or Overlord.InstanceSuspended or IsInInstance() then
                if refreshToken == communityCharactersRefreshToken then
                    communityCharactersRefreshPending = false
                end
                return
            end
            local processed = 0
            while processed < COMMUNITY_CHARACTERS_REFRESH_BATCH do
                if clubIndex > #clubIds then
                    FinishRefresh()
                    return
                end
                if not memberIds then
                    memberIds = GetClubMemberIdsSnapshot(clubIds[clubIndex])
                    memberIndex = 1
                end

                local memberId = memberIds[memberIndex]
                if memberId then
                    _scClubId = clubIds[clubIndex]
                    _scMemberId = memberId
                    _scInfo = nil
                    securecall(_secureFetchMemberInfo)
                    local info = _scInfo
                    if info then
                        local memberName = ResolveCommunityCharacterName(sync, info)
                        local race, raceSex = ResolveCommunityCharacterRace(sync, info)
                        AddCharacter(memberName, info.faction, race, raceSex)
                    end
                    memberIndex = memberIndex + 1
                    processed = processed + 1
                else
                    clubIndex = clubIndex + 1
                    memberIds = nil
                end
            end
            _scInfo = nil
            C_Timer.After(0, ProcessBatch)
        end

        -- Depuis Retail 11.2, la liste des membres n'est pas necessairement chargee
        -- tant qu'un consommateur ne l'a pas explicitement focalisee. Lire avant
        -- AreMembersReady renvoie souvent {}, que l'ancien code prenait pour un
        -- roster complet et mettait en cache pendant 30 secondes.
        if C_Club.FocusMembers and C_Club.AreMembersReady then
            for i = 1, #clubIds do
                _scClubId = clubIds[i]
                securecall(_secureFocusMembers)
            end
        end

        local readyWaitStartedAt = GetTime()
        local readyWaitDelay = 0.1
        local function WaitForMemberData()
            if refreshToken ~= communityCharactersRefreshToken
                or Overlord.InstanceSuspended or IsInInstance() then
                if refreshToken == communityCharactersRefreshToken then
                    communityCharactersRefreshPending = false
                end
                return
            end

            local allReady = true
            if C_Club.AreMembersReady then
                for i = 1, #clubIds do
                    _scClubId = clubIds[i]
                    _scMembersReady = false
                    securecall(_secureAreMembersReady)
                    if not _scMembersReady then
                        allReady = false
                        break
                    end
                end
            end
            if allReady then
                ProcessBatch()
                return
            end
            if GetTime() - readyWaitStartedAt >= COMMUNITY_MEMBERS_READY_TIMEOUT then
                -- Ne jamais remplacer le dernier cache valide par un faux vide. Une
                -- prochaine ouverture pourra relancer FocusMembers proprement.
                communityCharactersRefreshPending = false
                return
            end
            local delay = readyWaitDelay
            readyWaitDelay = math.min(1, readyWaitDelay * 2)
            C_Timer.After(delay, WaitForMemberData)
        end

        WaitForMemberData()
    end)
    return true
end

function Overlord.Sync:GetCommunityMemberCharacters(forceRefresh, minTtl)
    if Overlord.InstanceSuspended or IsInInstance() then return {} end
    if communityCharactersRefreshPending then return communityCharacterCache.rows end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return {} end
    self:RequestCommunityMemberCharactersRefresh(forceRefresh, minTtl)
    return communityCharacterCache.rows
end

local function FindCachedCommunityMemberCharacter(sync, memberName)
    if not memberName or memberName == "" or #communityCharacterCache.rows == 0 then return nil end
    local key = memberName:lower()
    local entry = communityCharacterCache.byKey[key]
    if entry then return entry end
    key = NormalizeCommunityRosterName(memberName)
    if key ~= "" and communityCharacterCache.byKey[key] then
        return communityCharacterCache.byKey[key]
    end
    if sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(memberName)
        if dk and dk ~= "" then return communityCharacterCache.byKey[dk:lower()] end
    end
    return nil
end

-- Lookup strictement pur pour les lecteurs UI : ne lance ni FocusMembers, ni parcours C_Club.
-- Le cache peut etre ancien ; sa revision invalide deja les consommateurs quand un vrai refresh finit.
function Overlord.Sync:GetCommunityMemberCharacterIfFresh(memberName, maxAge)
    maxAge = math.max(1, tonumber(maxAge) or COMMUNITY_CHARACTERS_CACHE_TTL)
    if communityCharacterCache.refreshedAt <= 0
        or GetTime() - communityCharacterCache.refreshedAt >= maxAge then
        return nil
    end
    return FindCachedCommunityMemberCharacter(self, memberName)
end

function Overlord.Sync:GetCommunityMemberCharacter(memberName, forceRefresh, minTtl)
    if not memberName or memberName == "" then return nil end
    local ttl = math.max(1, tonumber(minTtl) or COMMUNITY_CHARACTERS_CACHE_TTL)
    local rows = communityCharacterCache.rows
    if forceRefresh or communityCharacterCache.refreshedAt <= 0
        or GetTime() - communityCharacterCache.refreshedAt >= ttl then
        rows = self:GetCommunityMemberCharacters(forceRefresh, ttl)
    end
    if #rows == 0 then return nil end
    return FindCachedCommunityMemberCharacter(self, memberName)
end

function Overlord.Sync:GetCommunityMemberCharactersRevision()
    return communityCharacterCache.revision
end

function Overlord.Sync:GetOnlineCommunityMembersIfFresh(maxAge)
    if Overlord.CommunityModeEnabled == false then
        return Overlord.BetaNetwork and Overlord.BetaNetwork:GetPeers() or {}
    end
    if not cachedOnlineMembersPrimed then return nil end
    maxAge = tonumber(maxAge) or ONLINE_MEMBERS_CACHE_TTL
    if GetTime() - cachedOnlineMembersTime > maxAge then return nil end
    return cachedOnlineMembers
end

-- Cache completement distinct des transports territoriaux. Il ne parcourt que
-- les clubs europeens hors pool local exposes par FindEuropeanLeaderboardBridgeClubs
-- et n'est lu que par l'anti-entropie HR du classement.
function Overlord.Sync:InvalidateEuropeanLeaderboardBridgeMembersCache(clearSnapshot)
    wipe(communityCharacterCache.memberIdsByClub)
    local cache = self._europeanLeaderboardBridgeMembersCache
    if not cache then return end
    cache.generation = math.floor(tonumber(cache.generation) or 0) + 1
    cache.pending = false
    cache.refreshedAt = -1000000000
    if clearSnapshot then
        cache.rows = {}
        cache.senderKeys = {}
        cache.primed = true
    end
end

function Overlord.Sync:GetOnlineEuropeanLeaderboardBridgeMembers(forceRefresh, minTtl)
    if Overlord.InstanceSuspended or IsInInstance() then return {} end
    local sourceClubIds = self.FindEuropeanLeaderboardBridgeClubs
        and self:FindEuropeanLeaderboardBridgeClubs() or {}
    local cache = self._europeanLeaderboardBridgeMembersCache
    if not cache then
        cache = {
            rows = {}, senderKeys = {}, refreshedAt = -1000000000,
            primed = false, pending = false, generation = 0,
        }
        self._europeanLeaderboardBridgeMembersCache = cache
    end
    if not sourceClubIds or #sourceClubIds == 0 then
        if #cache.rows > 0 or next(cache.senderKeys) then
            self:InvalidateEuropeanLeaderboardBridgeMembersCache(true)
        end
        return cache.rows
    end
    if not C_Club or not C_Club.GetClubMembers or not C_Club.GetMemberInfo then
        return cache.rows
    end
    local ttl = math.max(30, tonumber(minTtl) or 15 * 60)
    if cache.primed and not forceRefresh
        and GetTime() - cache.refreshedAt < ttl then
        return cache.rows
    end
    if cache.pending or (InCombatLockdown and InCombatLockdown()) then
        return cache.rows
    end

    -- Le tableau de decouverte est interne a Sync.lua et peut etre remplace par
    -- un rescan : le worker conserve sa propre copie stable et annulable.
    local clubIds = {}
    for i = 1, #sourceClubIds do clubIds[i] = sourceClubIds[i] end
    local ONLINE = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Online or 1
    local AWAY = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Away or 2
    local BUSY = Enum.ClubMemberPresence and Enum.ClubMemberPresence.Busy or 3
    local nextRows, nextSenderKeys, seen = {}, {}, {}
    cache.pending = true
    cache.generation = math.floor(tonumber(cache.generation) or 0) + 1
    local generation = cache.generation
    local clubIndex, memberIndex, memberIds = 1, 1, nil
    local sync = self

    local function AddSenderKeys(memberName)
        if not memberName or memberName == ""
            or not sync.IsValidWhisperTarget
            or not sync:IsValidWhisperTarget(memberName) then return nil end
        local dedupKey = memberName:lower()
        if sync.GetCaptureContributorDedupKey then
            local dk = sync:GetCaptureContributorDedupKey(memberName)
            if dk and dk ~= "" then dedupKey = dk:lower() end
        end
        local normalized = NormalizeCommunityRosterName(memberName)
        nextSenderKeys[memberName:lower()] = true
        nextSenderKeys[dedupKey] = true
        if normalized ~= "" then nextSenderKeys[normalized] = true end
        return dedupKey
    end

    local function FinishRefresh()
        if cache.generation ~= generation then return end
        cache.rows = nextRows
        cache.senderKeys = nextSenderKeys
        cache.refreshedAt = GetTime()
        cache.primed = true
        cache.pending = false
    end

    local function ProcessBatch()
        if cache.generation ~= generation or Overlord.InstanceSuspended
            or IsInInstance() or (InCombatLockdown and InCombatLockdown()) then
            if cache.generation == generation then cache.pending = false end
            return
        end
        local processed = 0
        while processed < ONLINE_MEMBERS_REFRESH_BATCH do
            if clubIndex > #clubIds then
                _scInfo = nil
                FinishRefresh()
                return
            end
            if not memberIds then
                memberIds = GetClubMemberIdsSnapshot(clubIds[clubIndex])
                memberIndex = 1
            end
            local memberId = memberIds[memberIndex]
            if memberId then
                _scClubId = clubIds[clubIndex]
                _scMemberId = memberId
                _scInfo = nil
                securecall(_secureFetchMemberInfo)
                local info = _scInfo
                if info then
                    local memberName = ResolveCommunityCharacterName(sync, info)
                    local dedupKey = AddSenderKeys(memberName)
                    local presence = info.presence
                    if dedupKey and not info.isSelf and not seen[dedupKey]
                        and presence and (presence == ONLINE
                            or presence == AWAY or presence == BUSY) then
                        seen[dedupKey] = true
                        nextRows[#nextRows + 1] = memberName
                    end
                end
                memberIndex = memberIndex + 1
                processed = processed + 1
            else
                clubIndex = clubIndex + 1
                memberIds = nil
            end
        end
        _scInfo = nil
        C_Timer.After(0, ProcessBatch)
    end

    if C_Club.FocusMembers then
        for i = 1, #clubIds do
            _scClubId = clubIds[i]
            securecall(_secureFocusMembers)
        end
    end
    local readyWaitStartedAt = GetTime()
    local readyWaitDelay = 0.1
    local function WaitForMemberData()
        if cache.generation ~= generation or Overlord.InstanceSuspended
            or IsInInstance() then
            if cache.generation == generation then cache.pending = false end
            return
        end
        local allReady = true
        if C_Club.AreMembersReady then
            for i = 1, #clubIds do
                _scClubId = clubIds[i]
                _scMembersReady = false
                securecall(_secureAreMembersReady)
                if not _scMembersReady then
                    allReady = false
                    break
                end
            end
        end
        if allReady then
            ProcessBatch()
            return
        end
        if GetTime() - readyWaitStartedAt >= COMMUNITY_MEMBERS_READY_TIMEOUT then
            cache.pending = false
            return
        end
        local delay = readyWaitDelay
        readyWaitDelay = math.min(1, readyWaitDelay * 2)
        C_Timer.After(delay, WaitForMemberData)
    end
    WaitForMemberData()
    return cache.rows
end

-- Validation pure du sender : aucune reception HR ne peut declencher FocusMembers
-- ni un parcours C_Club. Le dernier snapshot atomique suffit jusqu'au refresh suivant.
function Overlord.Sync:IsEuropeanLeaderboardBridgeSender(memberName)
    if not memberName or memberName == "" then return false end
    local cache = self._europeanLeaderboardBridgeMembersCache
    if not cache or not cache.primed then return false end
    local key = memberName:lower()
    if cache.senderKeys[key] then return true end
    key = NormalizeCommunityRosterName(memberName)
    if key ~= "" and cache.senderKeys[key] then return true end
    if self.GetCaptureContributorDedupKey then
        local dk = self:GetCaptureContributorDedupKey(memberName)
        if dk and dk ~= "" then return cache.senderKeys[dk:lower()] == true end
    end
    return false
end

function Overlord.Sync:GetOnlineCommunityMemberCount(minTtl)
    if Overlord.CommunityModeEnabled == false then return #self:GetOnlineCommunityMembers() end
    local members = self:GetOnlineCommunityMembers(false, minTtl)
    return #members
end

-- Lookup pur pour les paquets entrants : ne doit jamais transformer un whisper
-- hostile en scan synchrone de centaines de membres C_Club.
function Overlord.Sync:GetOnlineCommunityMemberFactionIfFresh(memberName, maxAge)
    if not memberName or memberName == "" or not cachedOnlineMembersPrimed then return nil end
    if GetTime() - cachedOnlineMembersTime > (tonumber(maxAge) or 600) then return nil end
    local fac = cachedOnlineMemberFaction[memberName:lower()]
    if fac ~= nil then return fac end
    if self.GetCaptureContributorDedupKey then
        local dk = self:GetCaptureContributorDedupKey(memberName)
        if dk and dk ~= "" then
            fac = cachedOnlineMemberFaction[dk:lower()]
            if fac ~= nil then return fac end
        end
    end
    local normalized = NormalizeCommunityRosterName(memberName)
    if normalized ~= "" then return cachedOnlineMemberFaction[normalized] end
    return nil
end

-- Niveau fourni par le roster Blizzard, independant du payload addon. Lookup
-- pur uniquement : jamais de scan C_Club synchrone depuis un paquet entrant.
function Overlord.Sync:GetOnlineCommunityMemberLevelIfFresh(memberName, maxAge)
    if not memberName or memberName == "" or not cachedOnlineMembersPrimed then return nil end
    if GetTime() - cachedOnlineMembersTime > (tonumber(maxAge) or 600) then return nil end
    local level = cachedOnlineMemberLevel[memberName:lower()]
    if level then return level end
    if self.GetCaptureContributorDedupKey then
        local dk = self:GetCaptureContributorDedupKey(memberName)
        if dk and dk ~= "" then
            level = cachedOnlineMemberLevel[dk:lower()]
            if level then return level end
        end
    end
    local normalized = NormalizeCommunityRosterName(memberName)
    if normalized ~= "" then return cachedOnlineMemberLevel[normalized] end
    return nil
end

function Overlord.Sync:GetOnlineCommunityMemberFaction(memberName)
    if not memberName or memberName == "" then return nil end
    RefreshOnlineMembersCache(self)
    local fac = cachedOnlineMemberFaction[memberName:lower()]
    if fac ~= nil then return fac end
    if self.GetCaptureContributorDedupKey then
        local dk = self:GetCaptureContributorDedupKey(memberName)
        if dk and dk ~= "" then
            fac = cachedOnlineMemberFaction[dk:lower()]
            if fac ~= nil then return fac end
        end
    end
    local normalized = NormalizeCommunityRosterName(memberName)
    if normalized ~= "" then return cachedOnlineMemberFaction[normalized] end
    return nil
end

local function CommunityRosterMatchKey(name)
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local dk = Overlord.Sync:GetCaptureContributorDedupKey(name)
        if dk and dk ~= "" then return dk:lower() end
    end
    return NormalizeCommunityRosterName(name)
end

-- Fortin : membre du club Overlord en ligne (cross-faction). Cache prolonge cote reception GK/GC.
function Overlord.Sync:IsGuildKeepCommunitySender(sender)
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork
        and Overlord.BetaNetwork:IsPeer(sender) then return true end
    if Overlord.CommunityModeEnabled == false then return false end
    if not sender or sender == "" then return false end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return false end
    local key = CommunityRosterMatchKey(sender)
    if not key or key == "" then return false end
    local expectedUntil = communityExpectedSrResponders[key]
    if expectedUntil then
        if expectedUntil >= GetTime() then return true end
        communityExpectedSrResponders[key] = nil
    end
    -- Chemin entrant strictement O(1) : un paquet addon ne doit jamais provoquer le
    -- parcours synchrone C_Club de centaines de membres. Le cache est amorce au login
    -- puis rafraichi par les chemins passifs/sortants ; les reponses SR ciblees sont
    -- deja couvertes par communityExpectedSrResponders ci-dessus.
    if communitySenderKeys[key] then return true end
    if self.GetCaptureContributorDedupKey then
        local dk = self:GetCaptureContributorDedupKey(sender)
        if dk and dk ~= "" and communitySenderKeys[dk:lower()] then
            return true
        end
    end
    return false
end

-- Alias semantique pour les protocoles qui reutilisent cette validation O(1)
-- sans dependre du vocabulaire historique des fortins.
function Overlord.Sync:IsOnlineCommunitySender(sender)
    return self:IsGuildKeepCommunitySender(sender)
end

-- Fortin : hors raid/party (deja couverts par Send) ; tourniquet sur la liste en ligne.
local gkCommunityRotateCursor = 0
local EnqueueCommunityWhisper

local function CommunityMemberInOurGroup(memberName)
    return Overlord.Sync and Overlord.Sync.SenderIsInOurGroup
        and Overlord.Sync:SenderIsInOurGroup(memberName) or false
end

local function BroadcastViaBeta(msgType, payload, extras)
    if Overlord.BetaNetworkEnabled == false or not Overlord.BetaNetwork then return 0 end
    return Overlord.BetaNetwork:Broadcast(msgType, payload or "", extras) or 0
end

function Overlord.Sync:BroadcastGuildKeepToCommunity(
    msgType, payload, maxMembers, whisperDelaySec, extraWhispers, onlineMembersMinTtl)
    local betaSent = BroadcastViaBeta(msgType, payload, extraWhispers)
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not msgType or not payload or payload == "" then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return betaSent end
    maxMembers = maxMembers or 4
    whisperDelaySec = tonumber(whisperDelaySec) or 0.35

    local onlineList = RefreshOnlineMembersCache(
        self, false, tonumber(onlineMembersMinTtl))
    if #onlineList == 0 then return betaSent end

    local candidates = {}
    for i = 1, #onlineList do
        local name = onlineList[i]
        if not CommunityMemberInOurGroup(name) then
            candidates[#candidates + 1] = name
        end
    end
    if #candidates == 0 then
        candidates = onlineList
    end
    local n = #candidates
    local now = GetTime()

    lastCommunityDirectWhisper:Prune(now, 8)

    local sent = 0
    for attempt = 1, n do
        if sent >= maxMembers then break end
        local idx = ((gkCommunityRotateCursor + attempt - 1) % n) + 1
        local memberName = candidates[idx]
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            local queued = EnqueueCommunityWhisper(
                msgType, payload, memberName, extraWhispers,
                sent * whisperDelaySec, whisperDelaySec, false)
            if queued then
                lastCommunityDirectWhisper:Remember(targetKey, now)
                sent = sent + 1
            end
        end
    end
    if sent > 0 then
        gkCommunityRotateCursor = (gkCommunityRotateCursor + sent) % n
    end
    return sent + betaSent
end

-- Toutes les emissions communautaires passent par une seule pompe afin de borner
-- les timers et de donner la priorite aux transitions contractuelles.

-- Communaute : faction ennemie uniquement (prime de sang), meme tourniquet/cooldown que BroadcastToCommunity.
function Overlord.Sync:BroadcastToEnemyFactionCommunity(msgType, payload, maxMembers, whisperDelaySec, forceTargets)
    local betaSent = BroadcastViaBeta(msgType, payload)
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not msgType or not payload or payload == "" then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return betaSent end
    if not self.GetOnlineCommunityMembers or not self.SendWhisper then return betaSent end
    local pf = Overlord.PlayerFaction
    if not pf then return betaSent end

    maxMembers = maxMembers or COMMUNITY_WHISPER_MAX
    whisperDelaySec = tonumber(whisperDelaySec) or 0.3

    local onlineList = RefreshOnlineMembersCache(self)
    if #onlineList == 0 then
        if forceTargets and onlineMembersRefreshPending
            and self.QueuePendingCommunityCriticalReplay then
            self:QueuePendingCommunityCriticalReplay({
                method = "BroadcastToEnemyFactionCommunity",
                msgType = msgType,
                payload = payload,
                maxMembers = maxMembers,
                whisperDelaySec = whisperDelaySec,
                forceTargets = true,
            })
        end
        return betaSent
    end

    local FA = Enum.PvPFaction
    local wantEnemy = (pf == "Horde") and FA.Alliance or FA.Horde
    local candidates = {}
    for i = 1, #onlineList do
        local memberName = onlineList[i]
        if memberName and memberName ~= "" then
            if self.GetOnlineCommunityMemberFaction then
                local fac = self:GetOnlineCommunityMemberFaction(memberName)
                if fac == wantEnemy then
                    candidates[#candidates + 1] = memberName
                end
            end
        end
    end
    if #candidates == 0 then return betaSent end

    local sent = 0
    local now = GetTime()
    lastCommunityDirectWhisper:Prune(now, 8)

    local total = #candidates
    local cursor = forceTargets and bountyEnemyCriticalCursor or bountyEnemyRoutineCursor
    local startIdx = (total > 0) and ((cursor % total) + 1) or 1
    for attempt = 1, total do
        if sent >= maxMembers then break end
        local idx = ((startIdx + attempt - 2) % total) + 1
        local memberName = candidates[idx]
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if forceTargets or now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            local queued = EnqueueCommunityWhisper(
                msgType, payload, memberName, nil,
                sent * whisperDelaySec, whisperDelaySec, forceTargets)
            if queued then
                lastCommunityDirectWhisper:Remember(targetKey, now)
                sent = sent + 1
            end
        end
    end
    if sent > 0 and total > 0 then
        if forceTargets then
            bountyEnemyCriticalCursor = (bountyEnemyCriticalCursor + sent) % total
        else
            bountyEnemyRoutineCursor = (bountyEnemyRoutineCursor + sent) % total
        end
    end
    return sent + betaSent
end

-- File d'envoi communautaire : un whisper a la fois (evite N closures C_Timer.After en rafale).
-- Une voie chainee FIFO par rang : append, promotion, pop et eviction restent O(1)
-- meme pendant un final GK fragmente vers 40 membres.
local communityWhisperLanes = {}
for rank = 0, 4 do
    communityWhisperLanes[rank] = { head = nil, tail = nil, count = 0 }
end
local communityWhisperQueueCount = 0
local communityWhisperPumpScheduled = false
local communityWhisperByCoalesceKey = {}
local communityWhisperUnavailableUntil = {}
local COMMUNITY_WHISPER_UNAVAILABLE_TTL = 60
local communityWhisperQueueOps = {}

function communityWhisperQueueOps.reset()
    for rank = 0, 4 do
        local lane = communityWhisperLanes[rank]
        lane.head = nil
        lane.tail = nil
        lane.count = 0
    end
    communityWhisperQueueCount = 0
end

function communityWhisperQueueOps.append(item, rank, countAsNew)
    local lane = communityWhisperLanes[rank]
    if not lane or not item then return false end
    local tail = lane.tail
    item._queuePrev = tail
    item._queueNext = nil
    item._queueRank = rank
    if tail then
        tail._queueNext = item
    else
        lane.head = item
    end
    lane.tail = item
    lane.count = lane.count + 1
    if countAsNew ~= false then
        communityWhisperQueueCount = communityWhisperQueueCount + 1
    end
    return true
end

function communityWhisperQueueOps.unlink(item, countAsRemoved)
    local rank = item and item._queueRank
    local lane = rank ~= nil and communityWhisperLanes[rank] or nil
    if not lane then return false end
    local previous, following = item._queuePrev, item._queueNext
    if previous then previous._queueNext = following else lane.head = following end
    if following then following._queuePrev = previous else lane.tail = previous end
    item._queuePrev = nil
    item._queueNext = nil
    item._queueRank = nil
    lane.count = math.max(0, lane.count - 1)
    if countAsRemoved ~= false then
        communityWhisperQueueCount = math.max(0, communityWhisperQueueCount - 1)
    end
    return true
end

function communityWhisperQueueOps.promote(item, rank)
    if not item or item._queueRank == nil or rank <= item._queueRank then return false end
    communityWhisperQueueOps.unlink(item, false)
    return communityWhisperQueueOps.append(item, rank, false)
end

function communityWhisperQueueOps.peekHighest()
    for rank = 4, 0, -1 do
        local item = communityWhisperLanes[rank].head
        if item then return item end
    end
    return nil
end

function communityWhisperQueueOps.popHighest()
    local item = communityWhisperQueueOps.peekHighest()
    if item then communityWhisperQueueOps.unlink(item, true) end
    return item
end

function communityWhisperQueueOps.evictRoutineTail()
    local item = communityWhisperLanes[0].tail
    if not item then return false end
    communityWhisperQueueOps.unlink(item, true)
    if item.coalesceKey and communityWhisperByCoalesceKey[item.coalesceKey] == item then
        communityWhisperByCoalesceKey[item.coalesceKey] = nil
    end
    return true
end

function communityWhisperQueueOps.commitRoutineEvictions(count)
    for _ = 1, math.max(0, math.floor(tonumber(count) or 0)) do
        if not communityWhisperQueueOps.evictRoutineTail() then return false end
    end
    return true
end

-- Une perte de communaute confirmee invalide aussi les destinataires deja mis en
-- file. Sans ce reset, un ancien final ou une ancienne SR pourrait etre envoye au
-- prochain tick vers un membre du club quitte, ou rejoue lors d'une future adhesion.
function Overlord.Sync:ClearCommunityTransportQueues()
    self._communityTransportGeneration =
        (tonumber(self._communityTransportGeneration) or 0) + 1
    communityWhisperQueueOps.reset()
    communityWhisperPumpScheduled = false
    wipe(communityWhisperByCoalesceKey)
    lastCommunityDirectWhisper:Reset()
    wipe(communityExpectedSrResponders)
    self._pendingCommunityCriticalReplays = nil
    self._pendingCommunityCriticalReplayHead = nil
    self._pendingCommunityCriticalReplayByKey = nil
    self._pendingCommunityCriticalReplayScheduled = false
end

local function CommunityWhisperTargetIsUnavailable(memberName)
    if not memberName or memberName == "" then return true end
    local key = CommunityRosterMatchKey(memberName)
    if not key or key == "" then key = memberName:lower():gsub("%s+", "") end
    local unavailableUntil = communityWhisperUnavailableUntil[key]
    if not unavailableUntil then return false end
    if unavailableUntil > GetTime() then return true end
    communityWhisperUnavailableUntil[key] = nil
    return false
end

local function MarkCommunityWhisperTargetUnavailable(memberName)
    if not memberName or memberName == "" then return end
    local key = CommunityRosterMatchKey(memberName)
    if not key or key == "" then key = memberName:lower():gsub("%s+", "") end
    communityWhisperUnavailableUntil[key] = GetTime() + COMMUNITY_WHISPER_UNAVAILABLE_TTL
end

local function CommunityWhisperQueueSize()
    return communityWhisperQueueCount
end

local function CommunityWhisperPriorityRank(msgType, payload, priority)
    if not priority then return 0 end
    if msgType == "C" or msgType == "GC" or msgType == "GA" then return 4 end
    if msgType == "G7" then return 4 end
    if msgType == "GK" then
        local status = payload and (payload:match("^v%d+:[^:]+:([^:]+)")
            or payload:match("^[^:]+:([^:]+)")) or nil
        if status == "held" or status == "aborted" then return 4 end
        return 2
    end
    return 1
end

local function CommunityWhisperPayloadTimestamp(msgType, payload)
    if not payload or payload == "" then return 0 end
    if msgType == "C" then
        return tonumber(payload:match("^[^:]*:[^:]*:[^:]*:([^:]*)")) or 0
    end
    if msgType == "GC" or msgType == "GA" then
        local body = payload:match("^v8:(.*)$")
        return body and tonumber(body:match("^[^:]*:[^:]*:[^:]*:([^:]*)")) or 0
    end
    if msgType == "GK" then
        local body = payload:gsub("^v%d+:", "")
        local ts = select(7, strsplit(":", body))
        return tonumber(ts) or 0
    end
    return 0
end

local function CommunityWhisperFaction(code)
    if code == "A" then return "Alliance" end
    if code == "H" then return "Horde" end
    return nil
end

local function ParseCommunityWhisperGkIdentity(msgType, payload)
    if msgType == "GC" or msgType == "GA" then
        local body = (payload or ""):match("^v8:(.*)$")
        if not body then return nil end
        local _, guild, factionCode, eventTs, baseGuild, baseFactionCode,
            baseCaptured, shard, started, generation, player =
            strsplit(":", body, 12)
        return {
            kind = msgType, guild = guild, faction = CommunityWhisperFaction(factionCode),
            eventTs = tonumber(eventTs), baseGuild = baseGuild,
            baseFaction = CommunityWhisperFaction(baseFactionCode),
            baseCaptured = tonumber(baseCaptured), shard = tonumber(shard),
            started = tonumber(started), generation = tonumber(generation), player = player,
        }
    end
    if msgType ~= "GK" then return nil end
    local body = (payload or ""):gsub("^v%d+:", "")
    local _, status, _, guild, factionCode, claimedAt, syncTs, _, _, _,
        baseGuild, baseFactionCode, baseCaptured, player, shard, started, generation =
        strsplit(":", body, 18)
    if status ~= "in_progress" and status ~= "held" and status ~= "aborted" then return nil end
    return {
        kind = status == "aborted" and "GA" or (status == "held" and "GC" or "GK"),
        guild = guild, faction = CommunityWhisperFaction(factionCode),
        eventTs = tonumber(status == "in_progress" and syncTs or claimedAt),
        baseGuild = baseGuild, baseFaction = CommunityWhisperFaction(baseFactionCode),
        baseCaptured = tonumber(baseCaptured), shard = tonumber(shard),
        started = tonumber(started), generation = tonumber(generation), player = player,
    }
end

local function CommunityWhisperGkPayloadWins(
    candidateType, candidatePayload, currentType, currentPayload)
    local candidate = ParseCommunityWhisperGkIdentity(candidateType, candidatePayload)
    local current = ParseCommunityWhisperGkIdentity(currentType, currentPayload)
    if not candidate or not current then
        return CommunityWhisperPayloadTimestamp(candidateType, candidatePayload)
            >= CommunityWhisperPayloadTimestamp(currentType, currentPayload)
    end
    local GK = Overlord.GuildKeep
    if not GK or not GK.AssaultResolutionWins then
        return (candidate.eventTs or 0) >= (current.eventTs or 0)
    end
    return GK:AssaultResolutionWins({
        kind = candidate.kind, eventAt = candidate.eventTs,
        guild = candidate.guild, faction = candidate.faction,
        shard = candidate.shard, startedAt = candidate.started,
        generationAt = candidate.generation, player = candidate.player,
        baseGuild = candidate.baseGuild, baseFaction = candidate.baseFaction,
        baseCapturedAt = candidate.baseCaptured,
    }, {
        kind = current.kind, eventAt = current.eventTs,
        guild = current.guild, faction = current.faction,
        shard = current.shard, startedAt = current.started,
        generationAt = current.generation, player = current.player,
        baseGuild = current.baseGuild, baseFaction = current.baseFaction,
        baseCapturedAt = current.baseCaptured,
    })
end

local function CommunityWhisperGkAttemptKey(msgType, payload)
    local identity = ParseCommunityWhisperGkIdentity(msgType, payload)
    local started = identity and tonumber(identity.started)
    local shard = identity and tonumber(identity.shard)
    local generation = identity and tonumber(identity.generation)
    if not started or started <= 0 or not shard or shard < 0
        or not generation or generation < 0 then return nil end
    return table.concat({
        tostring(math.floor(started)), tostring(math.floor(shard)),
        tostring(math.floor(generation)),
    }, ":")
end

local function DispatchOneCommunityWhisper(item)
    if not Overlord.Sync or Overlord.InstanceSuspended then return end
    if not item.payload or item.payload == "" then return end
    -- C_Club peut conserver quelques instants une presence en ligne stale. Une
    -- erreur Blizzard correlee au premier whisper coupe les suivants deja en file.
    if CommunityWhisperTargetIsUnavailable(item.memberName) then return end
    pcall(Overlord.Sync.SendWhisper, Overlord.Sync, item.msgType, item.payload, item.memberName)
end

local function BuildCommunityWhisperCoalesceKey(msgType, payload, memberName, priority)
    payload = payload or ""
    if msgType == "GK" then
        local siteKey = payload:match("^v%d+:([^:]+):") or payload:match("^([^:]+):")
        if siteKey and siteKey ~= "" then
            local status = payload:match("^v%d+:[^:]+:([^:]+)")
            local family = (status == "held" or status == "aborted"
                or status == "in_progress") and "GKA" or "GKN"
            local attemptKey = family == "GKA"
                and CommunityWhisperGkAttemptKey(msgType, payload) or nil
            return family .. ":" .. tostring(memberName) .. ":" .. siteKey
                .. (attemptKey and (":" .. attemptKey) or "")
        end
    elseif msgType == "GC" or msgType == "GA" then
        local siteKey = payload:match("^v8:([^:]+):")
        if siteKey and siteKey ~= "" then
            local attemptKey = CommunityWhisperGkAttemptKey(msgType, payload)
            return "GKA:" .. tostring(memberName) .. ":" .. siteKey
                .. (attemptKey and (":" .. attemptKey) or "")
        end
    elseif msgType == "GH" then
        -- Deux vagues d'une meme preuve ne doivent jamais occuper deux cases par cible.
        -- Les payloads fragmentes passent par G7, qui possede deja sa cle transactionnelle.
        return "GH:" .. tostring(memberName) .. ":" .. payload
    elseif msgType == "C" then
        local zoneId = payload:match("^([^:]+):")
        if zoneId and zoneId ~= "" then
            return "C:" .. tostring(memberName) .. ":" .. zoneId
        end
    elseif msgType == "G7" then
        local _, innerType, fragmentId, fragmentIndex = strsplit(":", payload, 5)
        if innerType and fragmentId and fragmentIndex then
            return table.concat({
                "G7", tostring(memberName), innerType, fragmentId, fragmentIndex,
            }, ":")
        end
    elseif not priority and (msgType == "PM" or msgType == "LR") then
        local subject = msgType == "PM"
            and payload:match("^[^:]*:([^:]+)")
            or payload:match("^([^:]+)")
        return msgType .. ":" .. tostring(memberName) .. ":" .. tostring(subject)
    end
    return nil
end

local function CommunityWhisperQueueHasCoalesceKey(key)
    return key ~= nil and communityWhisperByCoalesceKey[key] ~= nil
end

local function CountNewCommunityWhisperBundleItems(
    memberName, extraWhispers, priority, primaryKey)
    local needed = CommunityWhisperQueueHasCoalesceKey(primaryKey) and 0 or 1
    for index, extra in ipairs(extraWhispers or {}) do
        if extra.type and extra.payload and extra.payload ~= "" then
            local key = BuildCommunityWhisperCoalesceKey(
                extra.type, extra.payload, memberName, priority)
            local duplicate = key and key == primaryKey
            if key and not duplicate then
                for previous = 1, index - 1 do
                    local prior = extraWhispers[previous]
                    if prior and prior.type and prior.payload and prior.payload ~= ""
                        and BuildCommunityWhisperCoalesceKey(
                            prior.type, prior.payload, memberName, priority) == key then
                        duplicate = true
                        break
                    end
                end
            end
            if not duplicate and not CommunityWhisperQueueHasCoalesceKey(key) then
                needed = needed + 1
            end
        end
    end
    return needed
end

-- Un payload fragmente est une transaction de transport : soit toute la serie tient
-- dans la file, soit aucun fragment n'est insere. Sinon G7 pouvait ajouter le debut
-- d'un lot puis perdre sa fin au plafond 256/384.
local function ReserveCommunityWhisperBundle(needed, priority)
    needed = math.max(0, math.floor(tonumber(needed) or 0))
    local size = CommunityWhisperQueueSize()
    if not priority then return size + needed <= 256, 0 end
    if needed == 0 then return true, 0 end

    local routineCount = communityWhisperLanes[0].count
    local evictions
    if size >= 256 then
        evictions = math.min(needed, routineCount)
    else
        evictions = math.min(math.max(0, size + needed - 256), routineCount)
    end
    local finalSize = size + needed - evictions
    if finalSize > 384 then
        local extra = finalSize - 384
        -- Verifier toute la reservation avant la premiere eviction : un lot G7
        -- qui ne tient pas ne doit jamais modifier la file existante.
        if routineCount - evictions < extra then return false, 0 end
        evictions = evictions + extra
    end
    return true, evictions
end

local function PumpCommunityWhisperQueue()
    communityWhisperPumpScheduled = false
    local item = communityWhisperQueueOps.popHighest()
    if not item then
        communityWhisperQueueOps.reset()
        wipe(communityWhisperByCoalesceKey)
        return
    end
    if item.coalesceKey and communityWhisperByCoalesceKey[item.coalesceKey] == item then
        communityWhisperByCoalesceKey[item.coalesceKey] = nil
    end
    DispatchOneCommunityWhisper(item)
    if CommunityWhisperQueueSize() > 0 then
        communityWhisperPumpScheduled = true
        local nextItem = communityWhisperQueueOps.peekHighest()
        -- La contrainte du PROCHAIN message compte aussi : une routine 0,3 s ne doit
        -- jamais faire partir un GK critique 0,5 s seulement 0,3 s plus tard.
        local nextGap = nextItem and nextItem.gap or 0
        local generation = tonumber(Overlord.Sync._communityTransportGeneration) or 0
        C_Timer.After(math.max(item.gap or 0.3, nextGap or 0), function()
            local sync = Overlord.Sync
            if not sync or (tonumber(sync._communityTransportGeneration) or 0)
                ~= generation then return end
            PumpCommunityWhisperQueue()
        end)
    else
        communityWhisperQueueOps.reset()
        wipe(communityWhisperByCoalesceKey)
    end
end

EnqueueCommunityWhisper = function(
    msgType, payload, memberName, extraWhispers, delaySec, gapSec, priority, bundleReserved)
    if CommunityWhisperTargetIsUnavailable(memberName) then return false end
    local coalesceKey = BuildCommunityWhisperCoalesceKey(
        msgType, payload, memberName, priority)
    local reservedEvictions = 0
    if not bundleReserved then
        local needed = CountNewCommunityWhisperBundleItems(
            memberName, extraWhispers, priority, coalesceKey)
        local reserved
        reserved, reservedEvictions = ReserveCommunityWhisperBundle(needed, priority)
        if not reserved then return false end
    end
    local priorityRank = CommunityWhisperPriorityRank(msgType, payload, priority)
    -- Tous les finals partagent la meme borne de transport, y compris les relais
    -- secondaires historiquement configures a 1 s.
    if priorityRank >= 4 then
        gapSec = math.min(tonumber(gapSec) or 0.5, 0.5)
    end
    if coalesceKey then
        local queued = communityWhisperByCoalesceKey[coalesceKey]
        if queued then
                local oldRank = queued.priorityRank or (queued.priority and 1 or 0)
                -- Un ancien heartbeat ne doit jamais degrader un final deja en file. A
                -- rang egal, conserver aussi le payload au timestamp le plus recent.
                local gkAnchored = msgType == "GK" or msgType == "GC" or msgType == "GA"
                if gkAnchored then
                    -- L'identite causale prime sur la classe transport : un retry gen+1
                    -- remplace l'ancien GA meme si ce dernier avait une priorite terminale.
                    if not CommunityWhisperGkPayloadWins(
                        msgType, payload, queued.msgType, queued.payload) then return true end
                else
                    if priorityRank < oldRank then return true end
                    if priorityRank == oldRank then
                        local oldTs = CommunityWhisperPayloadTimestamp(msgType, queued.payload)
                        local newTs = CommunityWhisperPayloadTimestamp(msgType, payload)
                        if oldTs > 0 and newTs > 0 and newTs < oldTs then return true end
                    end
                end
                communityWhisperQueueOps.commitRoutineEvictions(reservedEvictions)
                queued.payload = payload
                queued.msgType = msgType
                -- A rang egal, ne jamais accelerer une vague deja prudente. Un snapshot
                -- terminal qui remplace une routine adopte sa cadence finale et est deplace.
                if priorityRank > oldRank then
                    -- Une promotion terminale doit prendre la cadence du final. Conserver
                    -- le 0,9 s routine rendrait fausse la borne 384 * 0,5 s de la file.
                    queued.gap = gapSec or queued.gap or 0.3
                else
                    queued.gap = math.max(queued.gap or 0, gapSec or 0)
                end
                if priorityRank > oldRank then
                    queued.priority = true
                    queued.priorityRank = priorityRank
                    communityWhisperQueueOps.promote(queued, priorityRank)
                end
                if extraWhispers then
                    for _, extra in ipairs(extraWhispers) do
                        if extra.type and extra.payload and extra.payload ~= "" then
                            EnqueueCommunityWhisper(extra.type, extra.payload, memberName, nil,
                                0, gapSec, priority, true)
                        end
                    end
                end
                return true
        end
    end
    communityWhisperQueueOps.commitRoutineEvictions(reservedEvictions)
    local item = {
        msgType = msgType,
        payload = payload,
        memberName = memberName,
        gap = gapSec or 0.3,
        coalesceKey = coalesceKey,
        priorityRank = priorityRank,
    }
    if priority then item.priority = true end
    communityWhisperQueueOps.append(item, priorityRank, true)
    if coalesceKey then communityWhisperByCoalesceKey[coalesceKey] = item end
    -- Les compagnons d'un snapshot sont des messages reels : les inserer comme items
    -- distincts afin que la pompe garantisse effectivement un seul whisper par cadence.
    if extraWhispers then
        for _, extra in ipairs(extraWhispers) do
            if extra.type and extra.payload and extra.payload ~= "" then
                EnqueueCommunityWhisper(extra.type, extra.payload, memberName, nil,
                    0, gapSec, priority, true)
            end
        end
    end
    if not communityWhisperPumpScheduled then
        communityWhisperPumpScheduled = true
        local generation = tonumber(Overlord.Sync._communityTransportGeneration) or 0
        C_Timer.After(delaySec or 0, function()
            local sync = Overlord.Sync
            if not sync or (tonumber(sync._communityTransportGeneration) or 0)
                ~= generation then return end
            PumpCommunityWhisperQueue()
        end)
    end
    return true
end

-- Une transition critique peut arriver pendant le tout premier scan C_Club. Dans ce
-- cas seulement, la conserver jusqu'au commit du roster au lieu de la perdre. Cette
-- file est petite, fusionnee par sujet et consommee par index de tete : aucun shift
-- de tableau ni rafale de timers sur les chemins combat.
function Overlord.Sync:QueuePendingCommunityCriticalReplay(item)
    if type(item) ~= "table" or type(item.method) ~= "string" then return false end
    local allowed = item.method == "BroadcastToCommunity"
        or item.method == "BroadcastToEnemyFactionCommunity"
        or item.method == "BroadcastGeneralToFactionCommunity"
        or item.method == "BroadcastZoneSnapshotPagesToCommunity"
        or item.method == "BroadcastToCommunityImmediate"
    if not allowed then return false end

    local payload = item.payload
    if item.method == "BroadcastZoneSnapshotPagesToCommunity" then
        payload = item.pages and item.pages[1]
    end
    payload = type(payload) == "string" and payload or ""
    local subject
    if item.msgType == "SR" then
        subject = "state-request"
    else
        subject = payload:match("^v%d+:([^:]+)")
            or payload:match("^([^:]+)") or "global"
    end
    local key = table.concat({
        item.method, tostring(item.msgType or "ZA"), subject,
    }, ":")

    local pending = self._pendingCommunityCriticalReplays
    if not pending then
        pending = {}
        self._pendingCommunityCriticalReplays = pending
        self._pendingCommunityCriticalReplayHead = 1
        self._pendingCommunityCriticalReplayByKey = {}
    end
    local byKey = self._pendingCommunityCriticalReplayByKey
    local existing = byKey[key]
    if existing then
        existing.method = item.method
        existing.msgType = item.msgType
        existing.payload = item.payload
        existing.pages = item.pages
        existing.maxMembers = item.maxMembers
        existing.whisperDelaySec = item.whisperDelaySec
        existing.forceTargets = item.forceTargets
        existing.extraWhispers = item.extraWhispers
        existing.onlineMembersMinTtl = item.onlineMembersMinTtl
        existing.replayKey = key
        return true
    end

    local head = tonumber(self._pendingCommunityCriticalReplayHead) or 1
    if head > 32 and head > math.floor(#pending / 2) then
        local compact = {}
        for i = head, #pending do
            if pending[i] then compact[#compact + 1] = pending[i] end
        end
        pending = compact
        self._pendingCommunityCriticalReplays = pending
        head = 1
        self._pendingCommunityCriticalReplayHead = 1
    end
    if #pending - head + 1 >= 32 then
        local oldest = pending[head]
        pending[head] = false
        head = head + 1
        self._pendingCommunityCriticalReplayHead = head
        if oldest and byKey[oldest.replayKey] == oldest then
            byKey[oldest.replayKey] = nil
        end
    end
    item.replayKey = key
    pending[#pending + 1] = item
    byKey[key] = item
    return true
end

function Overlord.Sync:SchedulePendingCommunityCriticalReplayFlush()
    if self._pendingCommunityCriticalReplayScheduled then return end
    local pending = self._pendingCommunityCriticalReplays
    local head = tonumber(self._pendingCommunityCriticalReplayHead) or 1
    if not pending or not pending[head] then return end

    self._pendingCommunityCriticalReplayScheduled = true
    local generation = tonumber(self._communityTransportGeneration) or 0
    C_Timer.After(0, function()
        local sync = Overlord.Sync
        if not sync then return end
        if (tonumber(sync._communityTransportGeneration) or 0) ~= generation then return end
        sync._pendingCommunityCriticalReplayScheduled = false
        if Overlord.InstanceSuspended or IsInInstance()
            or onlineMembersRefreshPending then return end

        local queue = sync._pendingCommunityCriticalReplays
        local queueHead = tonumber(sync._pendingCommunityCriticalReplayHead) or 1
        local replay = queue and queue[queueHead]
        if not replay then return end
        queue[queueHead] = false
        sync._pendingCommunityCriticalReplayHead = queueHead + 1
        local index = sync._pendingCommunityCriticalReplayByKey
        if index and index[replay.replayKey] == replay then
            index[replay.replayKey] = nil
        end

        if replay.method == "BroadcastToCommunity" then
            sync:BroadcastToCommunity(
                replay.msgType, replay.payload, replay.maxMembers,
                replay.whisperDelaySec, true, replay.extraWhispers,
                replay.onlineMembersMinTtl)
        elseif replay.method == "BroadcastToEnemyFactionCommunity" then
            sync:BroadcastToEnemyFactionCommunity(
                replay.msgType, replay.payload, replay.maxMembers,
                replay.whisperDelaySec, true)
        elseif replay.method == "BroadcastGeneralToFactionCommunity" then
            sync:BroadcastGeneralToFactionCommunity(
                replay.msgType, replay.payload, replay.maxMembers,
                replay.whisperDelaySec, true)
        elseif replay.method == "BroadcastZoneSnapshotPagesToCommunity" then
            sync:BroadcastZoneSnapshotPagesToCommunity(
                replay.pages, replay.maxMembers, replay.whisperDelaySec, true)
        elseif replay.method == "BroadcastToCommunityImmediate" then
            sync:BroadcastToCommunityImmediate(
                replay.msgType, replay.payload, replay.maxMembers)
        end

        local nextHead = tonumber(sync._pendingCommunityCriticalReplayHead) or 1
        if queue[nextHead] then
            -- La pompe whisper est elle-meme cadencee : etaler aussi les reprises
            -- empeche 32 transitions froides de rescanner le roster sur 32 frames
            -- consecutives ou de remplir instantanement sa file prioritaire.
            sync._pendingCommunityCriticalReplayScheduled = true
            C_Timer.After(0.5, function()
                if Overlord.Sync == sync
                    and (tonumber(sync._communityTransportGeneration) or 0)
                        == generation then
                    sync._pendingCommunityCriticalReplayScheduled = false
                    sync:SchedulePendingCommunityCriticalReplayFlush()
                end
            end)
        else
            sync._pendingCommunityCriticalReplays = nil
            sync._pendingCommunityCriticalReplayHead = nil
            sync._pendingCommunityCriticalReplayByKey = nil
        end
    end)
end

function Overlord.Sync:BroadcastToCommunity(
    msgType, payload, maxMembers, whisperDelaySec, forceTargets, extraWhispers,
    onlineMembersMinTtl)
    local betaSent = BroadcastViaBeta(msgType, payload, extraWhispers)
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not msgType or not payload or payload == "" then return betaSent > 0 end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent > 0 end
    maxMembers = maxMembers or COMMUNITY_WHISPER_MAX
    whisperDelaySec = tonumber(whisperDelaySec) or 0.3

    local onlineList = RefreshOnlineMembersCache(
        self, false, tonumber(onlineMembersMinTtl))
    if #onlineList == 0 then
        if forceTargets and onlineMembersRefreshPending then
            self:QueuePendingCommunityCriticalReplay({
                method = "BroadcastToCommunity",
                msgType = msgType,
                payload = payload,
                maxMembers = maxMembers,
                whisperDelaySec = whisperDelaySec,
                forceTargets = true,
                extraWhispers = extraWhispers,
                onlineMembersMinTtl = onlineMembersMinTtl,
            })
        end
        return betaSent > 0
    end

    local sent = 0
    local now = GetTime()

    lastCommunityDirectWhisper:Prune(now, 8)

    local total = #onlineList
    if not self._communityCursorSeeded then
        local identity = self.GetPlayerFullName and self:GetPlayerFullName() or ""
        -- En Lua, "" est truthy : un simple `or UnitGUID()` ne constitue donc pas
        -- un fallback. Au chargement precoce le nom peut etre vide ; utiliser alors
        -- le GUID, et ne figer aucun seed tant qu'aucune identite n'est disponible.
        if identity == "" and UnitGUID then
            identity = UnitGUID("player") or ""
        end
        local seed = 0
        identity = tostring(identity or ""):lower()
        if identity ~= "" then
            for i = 1, #identity do
                seed = (seed * 33 + identity:byte(i)) % 2147483647
            end
            communityCriticalCursor = seed
            communityRoutineCursor = seed + math.floor(total / 2)
            self._communityCursorSeeded = true
        end
    end
    local cursor = forceTargets and communityCriticalCursor or communityRoutineCursor
    local startIdx = (total > 0) and ((cursor % total) + 1) or 1
    for attempt = 1, total do
        if sent >= maxMembers then break end
        local idx = ((startIdx + attempt - 2) % total) + 1
        local memberName = onlineList[idx]
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if forceTargets or now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            local queued = EnqueueCommunityWhisper(
                msgType, payload, memberName, extraWhispers,
                sent * whisperDelaySec, whisperDelaySec, forceTargets)
            if queued and msgType == "SR" then
                local responderKey = CommunityRosterMatchKey(memberName)
                if responderKey and responderKey ~= "" then
                    -- Couvre le watchdog de reponse (120 s) et un backlog de
                    -- whispers sans etendre la confiance a une identite externe.
                    communityExpectedSrResponders[responderKey] = now + 300
                end
                if payload:match(":F$")
                    and self.ExpectDirectFullLeaderboardResponse then
                    self:ExpectDirectFullLeaderboardResponse(memberName)
                end
            end
            if queued then
                lastCommunityDirectWhisper:Remember(targetKey, now)
                sent = sent + 1
            end
        end
    end
    if sent > 0 and total > 0 then
        if forceTargets then
            communityCriticalCursor = (communityCriticalCursor + sent) % total
        else
            communityRoutineCursor = (communityRoutineCursor + sent) % total
        end
    end
    return sent > 0 or betaSent > 0
end

function Overlord.Sync:WhisperCommunityMembersForContributorNames(
    msgType, payload, contributorNames, whisperDelaySec, forceTargets)
    local betaSent = 0
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        for i, name in ipairs(contributorNames or {}) do
            if i > 12 then break end
            if Overlord.BetaNetwork:Send(msgType, payload, name) then betaSent = betaSent + 1 end
        end
    end
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not msgType or not payload or payload == "" then return betaSent end
    if not contributorNames or #contributorNames == 0 then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    whisperDelaySec = tonumber(whisperDelaySec) or 0.3

    local wanted = {}
    for _, n in ipairs(contributorNames) do
        local dk = self:GetCaptureContributorDedupKey(n)
        if dk then wanted[dk:lower()] = true end
    end
    if not next(wanted) then return betaSent end

    local onlineList = RefreshOnlineMembersCache(self)
    if #onlineList == 0 then return betaSent end

    local now = GetTime()
    local matched = {}
    local sent = 0

    for _, memberName in ipairs(onlineList) do
        local dk = self:GetCaptureContributorDedupKey(memberName)
        if dk and wanted[dk:lower()] and not matched[dk:lower()] then
            matched[dk:lower()] = memberName
        end
    end

    for _, memberName in pairs(matched) do
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if forceTargets or now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            local queued = EnqueueCommunityWhisper(
                msgType, payload, memberName, nil,
                sent * whisperDelaySec, whisperDelaySec, forceTargets)
            if queued then
                lastCommunityDirectWhisper:Remember(targetKey, now)
                sent = sent + 1
            end
        end
    end
    return sent + betaSent
end

-- File LR : cadence les observations de race sans creer une closure par joueur visible.
local leaderboardRaceQueue = {}
local leaderboardRacePumpScheduled = false
local LEADERBOARD_RACE_QUEUE_MAX = 128
local LEADERBOARD_RACE_GAP = 0.25

local function PumpLeaderboardRaceQueue()
    leaderboardRacePumpScheduled = false
    if not Overlord.Sync or Overlord.InstanceSuspended then
        wipe(leaderboardRaceQueue)
        return
    end
    local item = table.remove(leaderboardRaceQueue, 1)
    if not item then return end

    Overlord.Sync:Send("LR", item.payload)
    if item.sendChannel and Overlord.Sync.SendToChannel then
        Overlord.Sync:SendToChannel("LR", item.payload, false)
    end
    if item.communityWide and Overlord.Sync.BroadcastToCommunity then
        Overlord.Sync:BroadcastToCommunity("LR", item.payload, 2, 0.5)
    end

    if #leaderboardRaceQueue > 0 then
        leaderboardRacePumpScheduled = true
        C_Timer.After(LEADERBOARD_RACE_GAP, PumpLeaderboardRaceQueue)
    end
end

function Overlord.Sync:EnqueueLeaderboardRaceBroadcast(payload, communityWide, sendChannel)
    if not payload or payload == "" or Overlord.InstanceSuspended then return false end
    local subject = payload:match("^([^:]+)")
    if not subject or subject == "" then return false end

    for i = #leaderboardRaceQueue, 1, -1 do
        local queued = leaderboardRaceQueue[i]
        if queued and queued.subject == subject then
            queued.payload = payload
            queued.communityWide = communityWide == true
            queued.sendChannel = sendChannel == true
            return true
        end
    end
    if #leaderboardRaceQueue >= LEADERBOARD_RACE_QUEUE_MAX then return false end

    leaderboardRaceQueue[#leaderboardRaceQueue + 1] = {
        subject = subject,
        payload = payload,
        communityWide = communityWide == true,
        sendChannel = sendChannel == true,
    }
    if not leaderboardRacePumpScheduled then
        leaderboardRacePumpScheduled = true
        C_Timer.After(0, PumpLeaderboardRaceQueue)
    end
    return true
end

-- Relais communauté Général de faction (same-faction, cache TTL long, exclusion groupe).
function Overlord.Sync:BroadcastGeneralToFactionCommunity(msgType, payload, maxMembers, whisperDelaySec, forceTargets)
    local betaSent = BroadcastViaBeta(msgType, payload)
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not msgType or not payload or payload == "" then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    if not self.HasCommunityClub or not self:HasCommunityClub() then return betaSent end
    if not Overlord.PlayerFaction then return betaSent end

    maxMembers = maxMembers or 12
    whisperDelaySec = tonumber(whisperDelaySec) or 0.35

    local onlineList = RefreshOnlineMembersCache(self, false, 45)
    if #onlineList == 0 then
        if forceTargets and onlineMembersRefreshPending then
            self:QueuePendingCommunityCriticalReplay({
                method = "BroadcastGeneralToFactionCommunity",
                msgType = msgType,
                payload = payload,
                maxMembers = maxMembers,
                whisperDelaySec = whisperDelaySec,
                forceTargets = true,
            })
        end
        return betaSent
    end

    local groupKeys = {}
    if IsInGroup() then
        local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and 40 or 4
        for i = 1, count do
            local unit = prefix .. i
            if UnitExists(unit) then
                local full = Overlord:SafeGetUnitName(unit, true)
                local k = CommunityRosterMatchKey(full)
                if k and k ~= "" then groupKeys[k] = true end
            end
        end
        local selfFull = Overlord:SafeGetUnitName("player", true)
        local sk = CommunityRosterMatchKey(selfFull)
        if sk and sk ~= "" then groupKeys[sk] = true end
    end

    local candidates = {}
    for i = 1, #onlineList do
        local memberName = onlineList[i]
        if CachedMemberFactionMatches(memberName, Overlord.PlayerFaction) then
            local targetKey = CommunityRosterMatchKey(memberName)
            if not groupKeys[targetKey] then
                candidates[#candidates + 1] = memberName
            end
        end
    end
    if #candidates == 0 then
        for i = 1, #onlineList do
            local memberName = onlineList[i]
            if CachedMemberFactionMatches(memberName, Overlord.PlayerFaction) then
                candidates[#candidates + 1] = memberName
            end
        end
    end

    local now = GetTime()
    lastCommunityDirectWhisper:Prune(now, 8)

    local sent = 0
    local total = #candidates
    for attempt = 1, total do
        if sent >= maxMembers then break end
        local idx = ((generalCommunityCursor + attempt - 1) % total) + 1
        local memberName = candidates[idx]
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if forceTargets or now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            local queued = EnqueueCommunityWhisper(
                msgType, payload, memberName, nil,
                sent * whisperDelaySec, whisperDelaySec, forceTargets)
            if queued then
                lastCommunityDirectWhisper:Remember(targetKey, now)
                sent = sent + 1
            end
        end
    end
    if sent > 0 and total > 0 then
        generalCommunityCursor = (generalCommunityCursor + sent) % total
    end
    return sent + betaSent
end

-- ============ Appel de faction (FC) ============

function Overlord.Sync:GetFactionCallCooldownRemaining()
    local fac = Overlord.PlayerFaction
    if not fac or not OverlordDB then return 0 end
    SanitizeFactionCallSavedTimestamps(fac)
    local last = NormalizeFactionCallTimestamp(OverlordDB.factionCallSharedAt[fac])
    if last <= 0 then
        last = NormalizeFactionCallTimestamp(OverlordDB.factionCallLastAt)
    end
    if last <= 0 then return 0 end
    local rem = FC_COOLDOWN_FACTION - (FactionCallCooldownNow() - last)
    if rem <= 0 then return 0 end
    return math.min(rem, FC_COOLDOWN_FACTION)
end

function Overlord.Sync:SetFactionCallSharedCooldown(at)
    local fac = Overlord.PlayerFaction
    if not fac or not OverlordDB then return end
    OverlordDB.factionCallSharedAt = OverlordDB.factionCallSharedAt or {}
    local t = tonumber(at) or FactionCallCooldownNow()
    if NormalizeFactionCallTimestamp(t) <= 0 then
        t = FactionCallCooldownNow()
    end
    local prev = NormalizeFactionCallTimestamp(OverlordDB.factionCallSharedAt[fac])
    if t >= prev then
        OverlordDB.factionCallSharedAt[fac] = t
    end
    if Overlord.Button and Overlord.Button.Refresh then
        Overlord.Button:Refresh()
    end
end

function Overlord.Sync:BuildFactionCallPayload()
    local fac = (Overlord.PlayerFaction == "Horde") and "H" or "A"
    local zone = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
    local zoneId = (zone and zone.id) or ""
    local frontId = (Overlord.Fronts and Overlord.Fronts.activeFrontId) or ""
    local epoch = math.floor(GetTime())
    return fac .. ":" .. zoneId .. ":" .. frontId .. ":" .. epoch
end

function Overlord.Sync:BroadcastFactionCall(payload)
    if not payload or payload == "" then return 0 end
    if Overlord.InstanceSuspended or IsInInstance() then return 0 end
    if not Overlord.InActiveFront then return 0 end
    if not FactionCallEnemyCountOk(true) then return 0 end
    if self:GetFactionCallCooldownRemaining() > 0 then return 0 end
    local playerFaction = Overlord.PlayerFaction
    if not playerFaction then return 0 end

    local betaSent = BroadcastViaBeta("FC", payload)
    if Overlord.CommunityModeEnabled == false then
        if betaSent > 0 then self:SetFactionCallSharedCooldown(FactionCallCooldownNow()) end
        return betaSent
    end
    local onlineList = RefreshOnlineMembersCache(self, false, 15)
    if #onlineList == 0 then
        if betaSent > 0 then self:SetFactionCallSharedCooldown(FactionCallCooldownNow()) end
        return betaSent
    end
    local sent = 0
    local now = GetTime()

    lastCommunityDirectWhisper:Prune(now, 8)

    local total = #onlineList
    for attempt = 1, total do
        if sent >= FC_COMMUNITY_MAX then break end
        local idx = ((factionCallCommunityCursor + attempt - 1) % total) + 1
        local memberName = onlineList[idx]
        if CachedMemberFactionMatches(memberName, playerFaction) then
            local targetKey = memberName:lower()
            local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
            if now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
                local queued = EnqueueCommunityWhisper(
                    "FC", payload, memberName, nil,
                    sent * FC_WHISPER_DELAY, FC_WHISPER_DELAY, false)
                if queued then
                    lastCommunityDirectWhisper:Remember(targetKey, now)
                    sent = sent + 1
                end
            end
        end
    end
    if sent > 0 or betaSent > 0 then
        factionCallCommunityCursor = (factionCallCommunityCursor + sent) % total
        self:SetFactionCallSharedCooldown(FactionCallCooldownNow())
        self:SendToChannel("FC", payload)
        if IsInRaid() or IsInGroup() then
            self:Send("FC", payload)
        end
    end
    return sent + betaSent
end

function Overlord.Sync:ResolveFactionCallPlace(zoneId, frontId)
    local zoneName = ""
    if zoneId and zoneId ~= "" and Overlord.Zones then
        local z = Overlord.Zones:GetZone(zoneId)
        zoneName = (z and z.name) or zoneId
    end
    local frontName = ""
    if frontId and frontId ~= "" and Overlord.Fronts then
        local front = Overlord.Fronts:GetFront(frontId)
        frontName = (front and front.mapName) or frontId
    end
    return zoneName, frontName
end

function Overlord.Sync:OnReceiveFactionCall(payload, sender)
    if not payload or payload == "" or not sender then return end
    local facCode, zoneId, frontId = strsplit(":", payload, 4)
    local senderFaction = nil
    if facCode == "A" then senderFaction = "Alliance"
    elseif facCode == "H" then senderFaction = "Horde" end
    if not senderFaction or senderFaction ~= Overlord.PlayerFaction then return end
    if Overlord.InstanceSuspended then return end
    local myName = self.GetPlayerFullName and self:GetPlayerFullName()
    if myName and sender:lower() == myName:lower() then return end

    local p = self:GetPriv()
    if not p then return end
    local senderKey = sender:lower()
    local now = GetTime()
    if (p.fcRecvLast[senderKey] or 0) + FC_COOLDOWN_RECV > now then return end
    p.fcRecvLast[senderKey] = now

    self:SetFactionCallSharedCooldown(FactionCallCooldownNow())

    local senderShort = sender:match("^([^%-]+)") or sender
    local zoneName, frontName = self:ResolveFactionCallPlace(zoneId or "", frontId or "")
    local msg
    if zoneName ~= "" and frontName ~= "" then
        msg = string.format(L.FACTION_CALL_RECEIVED, senderShort, zoneName, frontName)
    elseif frontName ~= "" then
        msg = string.format(L.FACTION_CALL_RECEIVED_NO_ZONE, senderShort, frontName)
    else
        msg = string.format(L.FACTION_CALL_RECEIVED_GENERIC, senderShort)
    end
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r |cFFFF4444" .. msg .. "|r")
    if Overlord.Popups and Overlord.Popups.ShowFactionCall then
        Overlord.Popups:ShowFactionCall(senderShort, zoneName, frontName)
    elseif Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("faction_call")
    end
end

function Overlord.Sync:OnReceiveMining(payload, sender)
    if not payload or payload == "" then return end
    if not Overlord.Zones then return end

    local mineId, factionCode = strsplit(":", payload, 3)
    mineId = mineId and mineId:match("^%s*(.-)%s*$") or mineId
    if not mineId or mineId == "" then return end

    local senderFaction = nil
    if factionCode == "A" then senderFaction = "Alliance"
    elseif factionCode == "H" then senderFaction = "Horde" end

    if not senderFaction or senderFaction == Overlord.PlayerFaction then return end

    local p = self:GetPriv()
    if not p then return end
    local now = GetTime()
    if (p.mineAlertLast[mineId] or 0) + p.mineAlertCooldown > now then return end
    p.mineAlertLast[mineId] = now
    local mine = Overlord.Zones:GetMine(mineId)
    local mineName = mine and mine.name or mineId
    local line = (senderFaction == "Horde" and L and L.ENEMY_MINING_HORDE)
        or (senderFaction == "Alliance" and L and L.ENEMY_MINING_ALLIANCE)
    if line then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. line, mineName))
    end
end

-- ============ Filtre whisper hors-ligne (CHAT_MSG_SYSTEM) ============

local whisperOfflineFilterInstalled = false
local whisperOfflineFilterAttempts = 0

local WHISPER_FAIL_NEEDLES = {
    "ne joue actuellement",
    "no player named",
    "currently playing",
}

local function matchesLocalizedPlayerNotFound(msg)
    local fmt = _G and _G.ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(fmt) ~= "string" or fmt == "" then return false end
    local a, b = fmt:find("%%[%d%$]*s")
    if not a then return false end
    local lowered = msg:lower()
    local prefix = fmt:sub(1, a - 1):lower()
    local suffix = fmt:sub(b + 1):lower()
    return (prefix == "" or lowered:find(prefix, 1, true) ~= nil)
        and (suffix == "" or lowered:find(suffix, 1, true) ~= nil)
end

local function firstQuotedToken(msg)
    if not msg then return nil end
    local patts = {
        "'([^']+)'",
        "\226\128\152([^\226\128\153]+)\226\128\153",
        "\226\128\156([^\226\128\157]+)\226\128\157",
    }
    for _, pat in ipairs(patts) do
        local q = msg:match(pat)
        if q then return q:match("^%s*(.-)%s*$") or q end
    end
    return nil
end

local function hasAnyRecentAddonWhisper(maxAge)
    local p = Overlord.Sync and Overlord.Sync.GetPriv and Overlord.Sync:GetPriv()
    local newest = p and p.recentAddonWhisperTail
    return newest and GetTime() - (newest.timestamp or 0) <= maxAge or false
end

local function recentWhisperLooksLikeFailedTarget(quoted)
    local p = Overlord.Sync and Overlord.Sync.GetPriv and Overlord.Sync:GetPriv()
    local aliases = p and p.recentAddonWhisperAliases
    if not aliases then return false end
    local now = GetTime()
    local ql = quoted:lower()
    local qb = ql:match("^([^%-]+)") or ql
    local seenAt = math.max(tonumber(aliases[ql]) or 0, tonumber(aliases[qb]) or 0)
    return seenAt > 0 and now - seenAt <= 18
end

local function SuppressAddonWhisperOfflineSystem(_, _, msg)
    if not msg or type(msg) ~= "string" then return false end
    local lowered = msg:lower()
    local hit = matchesLocalizedPlayerNotFound(msg)
    for _, needle in ipairs(WHISPER_FAIL_NEEDLES) do
        if lowered:find(needle, 1, true) then
            hit = true
            break
        end
    end
    if not hit then return false end
    local quoted = firstQuotedToken(msg)
    if quoted and recentWhisperLooksLikeFailedTarget(quoted) then
        MarkCommunityWhisperTargetUnavailable(quoted)
        return true
    end
    -- Rafale /ov sync : masque aussi les cibles corrompues (ex. bruit API Club ')g]').
    return hasAnyRecentAddonWhisper(8)
end

function Overlord.Sync:InstallWhisperOfflineChatFilter()
    if whisperOfflineFilterInstalled then return end
    local ok = false
    local add = ChatFrame_AddMessageEventFilter
    if add then
        ok = select(1, pcall(add, "CHAT_MSG_SYSTEM", SuppressAddonWhisperOfflineSystem))
    end
    if not ok and type(Chat_AddMessageEventFilter) == "function" then
        ok = select(1, pcall(Chat_AddMessageEventFilter, SuppressAddonWhisperOfflineSystem))
    end
    if ok then
        whisperOfflineFilterInstalled = true
    elseif whisperOfflineFilterAttempts < 6 then
        whisperOfflineFilterAttempts = whisperOfflineFilterAttempts + 1
        C_Timer.After(5, function()
            if Overlord.Sync and Overlord.Sync.InstallWhisperOfflineChatFilter then
                Overlord.Sync:InstallWhisperOfflineChatFilter()
            end
        end)
    end
end

-- ============ Anti-spoof : detection de captures fantomes (ZS) ============

local BoundSecurityEvidenceTable, ReleaseSecurityEvidenceKey, PruneSecurityEvidenceTable
local senderBroadcastHistory = {}
local spoofBlacklist = {}
local ANTISPOOF_WINDOW = 30
local ANTISPOOF_ACTIVE_THRESHOLD = 6
local ANTISPOOF_RECENT = 8
local ANTISPOOF_MIN_ACTIVE_ZONES = 3
local ANTISPOOF_BLACKLIST_DURATION = 300
local spoofDetectedNotified = {}

local function ZsSenderMatchesCapturer(sender, capturerName)
    if not capturerName or capturerName == "" then return true end
    if not sender or sender == "" then return false end
    if sender == capturerName then return true end
    local sync = Overlord.Sync
    if sync and sync.CaptureContributorMatchesSender
        and sync:CaptureContributorMatchesSender(capturerName, sender) then
        return true
    end
    if sync and sync.GetCaptureContributorDedupKey then
        local senderKey = sync:GetCaptureContributorDedupKey(sender)
        local capturerKey = sync:GetCaptureContributorDedupKey(capturerName)
        return senderKey and capturerKey and senderKey == capturerKey
    end
    return false
end

local function AntiSpoofCleanSender(sender)
    local now = GetTime()
    local h = senderBroadcastHistory[sender]
    if not h then return end
    for zid, d in pairs(h) do
        if now - d.lastSeen > ANTISPOOF_WINDOW then
            h[zid] = nil
        end
    end
end

local function AntiSpoofRevertZones(sender)
    local reverted = 0
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.status == "in_progress" and zone.lastZSSender == sender then
            -- Le bail connait exactement l'etat confirme precedent. Le restaurer
            -- localement evite l'ancien rewrite available/captured + SaveState.
            if Overlord.CaptureLease and Overlord.CaptureLease.ExpireRemote
                and Overlord.CaptureLease:ExpireRemote(zone, "anti_spoof") then
                reverted = reverted + 1
            else
                zone.lastZSSender = nil
            end
        end
    end
    return reverted
end

-- Un snapshot ZA pagine est une seule unite logique : chaque destinataire doit
-- recevoir toutes ses pages, dans le meme ordre. Selectionner les membres page
-- par page faisait tourner le curseur et produisait des lots impossibles a
-- reassembler des qu'il y avait plus de membres que la limite d'un broadcast.
function Overlord.Sync:BroadcastZoneSnapshotPagesToCommunity(
    pages, maxMembers, whisperDelaySec, forceTargets)
    local betaSent = 0
    if type(pages) == "table" then
        for _, page in ipairs(pages) do
            betaSent = betaSent + BroadcastViaBeta("ZA", page)
        end
    end
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if type(pages) ~= "table" or #pages == 0 then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    maxMembers = math.max(0, math.floor(tonumber(maxMembers) or COMMUNITY_WHISPER_MAX))
    whisperDelaySec = math.max(0.08, tonumber(whisperDelaySec) or 0.2)

    local validPages = {}
    for _, payload in ipairs(pages) do
        if type(payload) == "string" and payload ~= "" then
            validPages[#validPages + 1] = payload
        end
    end
    if #validPages == 0 then return betaSent end

    local onlineList = RefreshOnlineMembersCache(self)
    if #onlineList == 0 then
        if forceTargets and onlineMembersRefreshPending then
            local replayPages = {}
            for i = 1, #validPages do replayPages[i] = validPages[i] end
            self:QueuePendingCommunityCriticalReplay({
                method = "BroadcastZoneSnapshotPagesToCommunity",
                msgType = "ZA",
                pages = replayPages,
                maxMembers = maxMembers,
                whisperDelaySec = whisperDelaySec,
                forceTargets = true,
            })
        end
        return betaSent
    end

    -- Un lot prioritaire ne doit pas depasser la borne dure de la file. On
    -- reduit le nombre de cibles, jamais le nombre de pages d'une cible.
    local queueCap = forceTargets and 384 or 256
    local freeSlots = math.max(0, queueCap - CommunityWhisperQueueSize())
    maxMembers = math.min(maxMembers, math.floor(freeSlots / #validPages))
    if maxMembers <= 0 then return betaSent end

    local now = GetTime()
    lastCommunityDirectWhisper:Prune(now, 8)

    local sent = 0
    local total = #onlineList
    local cursor = forceTargets and communityCriticalCursor or communityRoutineCursor
    local startIdx = (cursor % total) + 1
    for attempt = 1, total do
        if sent >= maxMembers then break end
        local idx = ((startIdx + attempt - 2) % total) + 1
        local memberName = onlineList[idx]
        local targetKey = memberName:lower()
        local lastDirect = lastCommunityDirectWhisper:Get(targetKey) or 0
        if forceTargets or now - lastDirect >= COMMUNITY_DIRECT_TARGET_COOLDOWN then
            lastCommunityDirectWhisper:Remember(targetKey, now)
            for pageIndex, payload in ipairs(validPages) do
                EnqueueCommunityWhisper(
                    "ZA", payload, memberName, nil,
                    (sent * #validPages + pageIndex - 1) * whisperDelaySec,
                    whisperDelaySec, forceTargets)
            end
            sent = sent + 1
        end
    end
    if sent > 0 then
        if forceTargets then
            communityCriticalCursor = (communityCriticalCursor + sent) % total
        else
            communityRoutineCursor = (communityRoutineCursor + sent) % total
        end
    end
    return sent + betaSent
end

-- Petit fan-out synchrone reserve aux releases de bail juste avant un loading.
-- La file normale utilise C_Timer.After et peut etre suspendue avant son premier
-- item ; quelques whispers immediats donnent au ZR une vraie voie cross-faction.
function Overlord.Sync:BroadcastToCommunityImmediate(msgType, payload, maxMembers)
    local betaSent = msgType == "ZR" and Overlord.BetaNetworkEnabled ~= false
        and Overlord.BetaNetwork and Overlord.BetaNetwork:Send(msgType, payload, nil, true)
        and 1 or 0
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if msgType ~= "ZR" or not payload or payload == "" then return betaSent end
    if Overlord.InstanceSuspended or IsInInstance() then return betaSent end
    if not self.SendWhisper then return betaSent end
    local onlineList = RefreshOnlineMembersCache(self)
    if #onlineList == 0 then
        if onlineMembersRefreshPending then
            self:QueuePendingCommunityCriticalReplay({
                method = "BroadcastToCommunityImmediate",
                msgType = msgType,
                payload = payload,
                maxMembers = maxMembers,
                forceTargets = true,
            })
        end
        return betaSent
    end
    local limit = math.min(math.max(1, tonumber(maxMembers) or 6), 8)
    local sent = 0
    for i = 1, #onlineList do
        if sent >= limit then break end
        local memberName = onlineList[i]
        if memberName and memberName ~= "" then
            self:SendWhisper(msgType, payload, memberName)
            sent = sent + 1
        end
    end
    return sent + betaSent
end

function Overlord.Sync:AntiSpoofCheck(sender, zoneId, capturerName)
    if not sender or sender == "" then return false end
    local now = GetTime()

    local bl = spoofBlacklist[sender]
    if bl then
        if now < bl then
            BoundSecurityEvidenceTable(spoofBlacklist, 512, sender)
            return true
        end
        ReleaseSecurityEvidenceKey(spoofBlacklist, sender)
    end

    -- Un ZS relaye par SR/communaute peut porter le capteur officiel d'un autre joueur.
    -- Il ne doit pas compter comme une capture simultanee du relais lui-meme.
    -- La blacklist existante reste appliquee avant cette exemption.
    if not ZsSenderMatchesCapturer(sender, capturerName) then return false end

    BoundSecurityEvidenceTable(senderBroadcastHistory, 512, sender)
    if not senderBroadcastHistory[sender] then
        senderBroadcastHistory[sender] = {}
    end
    AntiSpoofCleanSender(sender)

    local h = senderBroadcastHistory[sender]
    local d = h[zoneId]
    if not d then
        h[zoneId] = { count = 1, firstSeen = now, lastSeen = now }
    else
        d.count = d.count + 1
        d.lastSeen = now
    end

    local activeZones = 0
    for _, data in pairs(h) do
        if data.count >= ANTISPOOF_ACTIVE_THRESHOLD
            and (now - data.lastSeen) < ANTISPOOF_RECENT then
            activeZones = activeZones + 1
        end
    end

    if activeZones >= ANTISPOOF_MIN_ACTIVE_ZONES then
        BoundSecurityEvidenceTable(spoofBlacklist, 512, sender)
        spoofBlacklist[sender] = now + ANTISPOOF_BLACKLIST_DURATION
        AntiSpoofRevertZones(sender)
        local senderShort = tostring(sender):match("^(.-)%-") or tostring(sender)
        local notifiedUntil = tonumber(spoofDetectedNotified[sender]) or 0
        if now >= notifiedUntil then
            BoundSecurityEvidenceTable(spoofDetectedNotified, 512, sender)
            spoofDetectedNotified[sender] = now + ANTISPOOF_BLACKLIST_DURATION
            Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. string.format(L.SPOOF_DETECTED, senderShort))
        end
        return true
    end

    return false
end

local function AntiSpoofPeriodicCleanup()
    local now = GetTime()
    PruneSecurityEvidenceTable(senderBroadcastHistory, ANTISPOOF_WINDOW, 32)
    PruneSecurityEvidenceTable(spoofBlacklist, ANTISPOOF_BLACKLIST_DURATION, 32)
    PruneSecurityEvidenceTable(spoofDetectedNotified, ANTISPOOF_BLACKLIST_DURATION, 32)
    local expectedCount = 0
    for key, expire in pairs(communityExpectedSrResponders) do
        if now >= expire then
            communityExpectedSrResponders[key] = nil
        else
            expectedCount = expectedCount + 1
        end
    end
    -- Cache de confiance opportuniste seulement : au-dela d'un roster communautaire
    -- plausible, repartir du cache roster local est plus sur que conserver une table gonflee.
    if expectedCount > 1024 then wipe(communityExpectedSrResponders) end
end

C_Timer.NewTicker(60, function()
    if Overlord.InstanceSuspended then return end
    AntiSpoofPeriodicCleanup()
end)

-- ============ Relais structures 1-hop communaute ============

local OC_CAPTURE_RELAY_MAX_NORMAL = 40
local OC_CAPTURE_RELAY_MAX_LARGE = 12
local OC_CAPTURE_RELAY_DELAY = 0.25
local function NormalizeRelayPoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    return ""
end

local function RelayPoolMatchesLocal(pool)
    pool = NormalizeRelayPoolTag(pool)
    if pool == "" then return false end
    local localPool = Overlord.GetCurrentSavedVarsPool
        and NormalizeRelayPoolTag(Overlord:GetCurrentSavedVarsPool()) or ""
    return localPool ~= "" and pool == localPool
end

local function RelayOutpostPoolMatchesLocal(pool)
    pool = NormalizeRelayPoolTag(pool)
    if pool == "" then return false end
    local localPool = Overlord.GetCurrentSavedVarsPool
        and NormalizeRelayPoolTag(Overlord:GetCurrentSavedVarsPool()) or ""
    if localPool == "" then return false end
    local rp = Overlord.RealmPools
    if not rp or not rp.AreOutpostCrossPoolsLinked then return false end
    return rp:AreOutpostCrossPoolsLinked(localPool, pool)
end

-- Relais 1-hop avant-poste : pool local ou pont FR/EU. Les deux caches restent
-- bornes et n'oublient jamais une cle encore vivante : une rafale saturee est
-- refusee avant diffusion au lieu de pouvoir reboucler apres eviction.
local STRUCTURE_RELAY_DEDUP_MAX = 128
local STRUCTURE_RELAY_DEDUP_TTL = 30
local ocCaptureRelayDedup = {}
local wbRelayDedup = {}
local structureRelayDedupState = {
    [ocCaptureRelayDedup] = { count = 0, blockedUntil = nil },
    [wbRelayDedup] = { count = 0, blockedUntil = nil },
}

local function RememberStructureRelay(cache, relayKey, now)
    if type(relayKey) ~= "string" or relayKey == "" then return false end
    if cache[relayKey] ~= nil then return false end
    local state = structureRelayDedupState[cache]
    if not state then return false end

    if state.count >= STRUCTURE_RELAY_DEDUP_MAX then
        if state.blockedUntil and now < state.blockedUntil then return false end
        local earliestExpiry = nil
        for key, stamp in pairs(cache) do
            local expiresAt = (tonumber(stamp) or 0) + STRUCTURE_RELAY_DEDUP_TTL
            if expiresAt <= now then
                cache[key] = nil
                state.count = math.max(0, state.count - 1)
            elseif not earliestExpiry or expiresAt < earliestExpiry then
                earliestExpiry = expiresAt
            end
        end
        state.blockedUntil = earliestExpiry or (now + STRUCTURE_RELAY_DEDUP_TTL)
        if state.count >= STRUCTURE_RELAY_DEDUP_MAX then return false end
    end

    cache[relayKey] = now
    state.count = state.count + 1
    state.blockedUntil = nil
    return true
end

function Overlord.Sync:RelayOutpostCaptureToCommunitySafe(payload, relayKey, poolTag)
    if not payload or payload == "" then return end
    if not RelayOutpostPoolMatchesLocal(poolTag) then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if not self.BroadcastToCommunity then return end
    local now = GetTime()
    if not RememberStructureRelay(ocCaptureRelayDedup, relayKey, now) then return end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local maxM = isLarge and OC_CAPTURE_RELAY_MAX_LARGE or OC_CAPTURE_RELAY_MAX_NORMAL
    self:BroadcastToCommunity("OC", payload, maxM, OC_CAPTURE_RELAY_DELAY, true)
end

function Overlord.Sync:RelayDominationBoostToCommunitySafe(payload, relayKey, poolTag)
    if not payload or payload == "" then return end
    if not RelayPoolMatchesLocal(poolTag) then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if not self.BroadcastToCommunity then return end
    local now = GetTime()
    if not RememberStructureRelay(wbRelayDedup, relayKey, now) then return end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    -- WB et OC partagent le meme budget de relais. Les anciens noms CAPTURE_*
    -- n'existaient plus dans ce chunk et activaient silencieusement les defaults.
    local maxM = isLarge and OC_CAPTURE_RELAY_MAX_LARGE or OC_CAPTURE_RELAY_MAX_NORMAL
    self:BroadcastToCommunity("WB", payload, maxM, OC_CAPTURE_RELAY_DELAY, true)
end

-- ==================== Sync Passive (hors instance) ====================
-- Ticker lent (2 min) : SR canal + scan communaute + rattrapages hors front.
-- En front actif, DominationTick diffuse deja le DM ; les snapshots ZA tous fronts
-- passent par ScheduleControlledZoneSnapshot (election + cooldown) pour eviter
-- les rafales 40 joueurs sans laisser les observateurs attendre plusieurs minutes.
local passiveSyncTicker = nil
local PASSIVE_SYNC_INTERVAL = 120

function Overlord.Sync:StartPassiveSync()
    self:StopPassiveSync()
    self._passiveSyncToken = (self._passiveSyncToken or 0) + 1
    local token = self._passiveSyncToken
    local function runPassiveSync()
        if token ~= Overlord.Sync._passiveSyncToken then return end
        if not Overlord.IsInitialized or Overlord.InstanceSuspended then return end
        -- Une seule decision d'echantillonnage gouverne le bundle local. Ce n'est pas
        -- une election universelle : plusieurs royaumes peuvent choisir un diffuseur,
        -- mais les clients refuses s'arretent avant tout SR ou scan C_Club.
        local passiveBroadcaster = self.ShouldRunPassiveStateBundle
            and self:ShouldRunPassiveStateBundle()
        if not passiveBroadcaster then return end
        -- En front actif, l'election territoriale de Sync.lua couvre deja SR + communaute.
        -- Garder ici uniquement les heartbeats held/outpost evite une seconde vague SR
        -- complete et un second scan C_Club toutes les deux minutes.
        if not Overlord.InActiveFront then
            local skipDuplicateSr = Overlord.UI and Overlord.UI.IsSpectatorSyncActive
                and Overlord.UI:IsSpectatorSyncActive()
            if not skipDuplicateSr and self.SendToChannel then
                -- Rattrapage lent mais important : ne pas le laisser tomber sur budget canal sature.
                self:SendToChannel("SR", self:GetSRPayload("T"), true)
            end
            self:ScanCommunityMembers()
            if self.ScheduleControlledZoneSnapshot then
                self:ScheduleControlledZoneSnapshot("passive", {
                    cooldown = 90,
                    electionPct = 100,
                    jitterMin = 1.0,
                    jitterMax = 5.0,
                })
            end
            if Overlord.AccumulatePassiveDominationForInactiveFronts then
                Overlord:AccumulatePassiveDominationForInactiveFronts(PASSIVE_SYNC_INTERVAL)
            end
            if self.BroadcastDomination then
                self:BroadcastDomination({ passiveOffFront = true })
            end
        end
        if self.BroadcastHeldGuildKeepStates then
            self:BroadcastHeldGuildKeepStates()
        end
        if self.BroadcastHeldOutpostStates then
            self:BroadcastHeldOutpostStates()
        end
    end

    C_Timer.After(12, function()
        if token ~= Overlord.Sync._passiveSyncToken then return end
        if Overlord.IsInitialized and not Overlord.InstanceSuspended and Overlord.Sync then
            -- Chaque client amorce son cache de confiance entrant, sans declencher une
            -- rafale N-way de SR. Un prochain runPassiveSync echantillonne fera le fan-out.
            if Overlord.Sync.GetOnlineCommunityMembers then
                Overlord.Sync:GetOnlineCommunityMembers(false, 30)
            end
        end
    end)
    C_Timer.After(math.random(10, 45), function()
        if token ~= Overlord.Sync._passiveSyncToken then return end
        runPassiveSync()
        passiveSyncTicker = C_Timer.NewTicker(PASSIVE_SYNC_INTERVAL, runPassiveSync)
    end)
end

function Overlord.Sync:StopPassiveSync()
    self._passiveSyncToken = (self._passiveSyncToken or 0) + 1
    if passiveSyncTicker then
        passiveSyncTicker:Cancel()
        passiveSyncTicker = nil
    end
end

-- ============ Anti-triche : injection de kills (K / LK / EK) ============
-- Le canal addon WoW n'est pas authentifie : un client modifie peut forger des K
-- pour autrui ou diffuser un faux classement via LK (totaux 9999, etc.). On compte
-- les lignes de kills aberrantes par expediteur dans une fenetre ; au-dela d'un seuil,
-- l'expediteur est mis en quarantaine silencieuse et ses messages kills sont ignores un moment.
local killSpoofCounts = {}        -- sender -> { count, firstSeen, lastSeen }
local killSpoofBlacklist = {}     -- sender -> expiration (GetTime)
local KILLSPOOF_WINDOW = 30
local KILLSPOOF_THRESHOLD = 5
local KILLSPOOF_BLACKLIST_DURATION = 300
-- Plafond plausible d'un total de kills sur une campagne hebdo : au-dela on REFUSE la
-- valeur (pas de clamp, qui figeait les injections au plafond). Marge large au-dessus
-- des tops legitimes (500+ observes en event massif) sans laisser passer les 9999 injectes.
local PLAUSIBLE_KILL_CEILING = 1000
-- Expose le plafond pour la defense en profondeur cote Leaderboard et Sync.
Overlord.PLAUSIBLE_SYNC_KILL_CEILING = PLAUSIBLE_KILL_CEILING
-- Forever : tous les niveaux participent. Le champ K/LK reste valide et
-- obligatoire, sans exiger le niveau maximum du client Retail ou de la beta.

-- Incident OL2 (2026-07-15) : cette ligne a injecte 480 kills. Le denylist est
-- volontairement base-name afin de couvrir toutes ses variantes Nom-Royaume et
-- d'autoriser une purge deterministe sur chaque SavedVariables deja contaminee.
local BLOCKED_KILL_CONTRIBUTOR_BASES = {
    sfvsafqw = true,
}

function Overlord.Sync:IsDeniedKillContributor(playerName)
    if type(playerName) ~= "string" or playerName == "" then return false end
    local normalized = self.NormalizeContributorFullName
        and self:NormalizeContributorFullName(playerName) or playerName
    if type(normalized) ~= "string" or normalized == "" then return false end
    local base = normalized:match("^([^%-]+)") or normalized
    return BLOCKED_KILL_CONTRIBUTOR_BASES[base:lower()] == true
end

function Overlord.Sync:IsEligibleKillContributorLevel(level)
    level = tonumber(level)
    return level ~= nil and level >= 1 and level <= 90 and level == math.floor(level)
end

-- K wire (9.7.3+) :
-- name:zoneId:totalKills:class:faction:epoch:guild:locale:guildAt:BbucketEpoch:level
-- La race vient en priorite du cache Communaute et, a defaut, du message LR dedie.
-- Le parseur accepte encore le K 9.7.2 a 13 champs pour la compatibilite descendante.
-- Les deux derniers champs sont volontairement obligatoires pour toute mutation de score.
-- BbucketEpoch atteste
-- l'epoch reel du bucket SavedVariables, distinct de l'epoch calendrier recalcule au moment
-- d'envoyer. Un client qui a manque son wipe ne peut ainsi plus re-etiqueter son ancien total
-- avec la nouvelle campagne. Les anciens formats restent parsables pour compatibilite du code,
-- mais Sync.lua les refuse avant toute mutation/vote faute de jeton BbucketEpoch.
-- LR wire : name:raceFile:raceSex:epoch (meta race compacte, hors LK)
-- Limite SendAddonMessage 255 octets (PREFIX + "K:" inclus cote receveur).
local MAX_KILL_PAYLOAD_BYTES = 250
local MAX_LR_PAYLOAD_BYTES = 120

local VALID_RACE_FILE = {
    Human = true, Dwarf = true, NightElf = true, Gnome = true, Draenei = true,
    Worgen = true, Orc = true, Scourge = true, Tauren = true, Troll = true,
    BloodElf = true, Goblin = true, Pandaren = true, Nightborne = true,
    HighmountainTauren = true, VoidElf = true, LightforgedDraenei = true,
    ZandalariTroll = true, KulTiran = true, DarkIronDwarf = true, Vulpera = true,
    MagharOrc = true, Mechagnome = true, Dracthyr = true, Earthen = true,
    EarthenDwarf = true, Haranir = true, Harronir = true, Haronir = true,
}

-- Alias orthographiques / typos joueurs (Haronir) vers le clientFileString canonique.
local RACE_FILE_ALIASES = {
    Harronir = "Haranir",
    Haronir = "Haranir",
    haranir = "Haranir",
    harronir = "Haranir",
    haronir = "Haranir",
}

local function normalizeRaceSexCode(sex)
    sex = math.floor(tonumber(sex) or 0)
    if sex == 2 or sex == 3 then return sex end
    return 0
end

function Overlord.Sync.IsValidRaceFileToken(token)
    if not token or token == "" then return false end
    if RACE_FILE_ALIASES[token] then return true end
    return VALID_RACE_FILE[token] == true
end

function Overlord.Sync:NormalizeRaceFileToken(race)
    if not race or race == "" then return nil end
    race = race:match("^%s*(.-)%s*$") or race
    if race == "" then return nil end
    race = RACE_FILE_ALIASES[race] or race
    if not VALID_RACE_FILE[race] then
        -- Match insensible a la casse sur la table connue (GUID / commu parfois en camelCase).
        local lower = race:lower()
        for token in pairs(VALID_RACE_FILE) do
            if token:lower() == lower then
                race = token
                break
            end
        end
    end
    race = RACE_FILE_ALIASES[race] or race
    if race == "" or not VALID_RACE_FILE[race] then return nil end
    return race
end

-- Etend sans risque la liste statique lorsqu'un nouveau token vient directement
-- de C_CreatureInfo/GetPlayerInfoByGUID (utile aux nouvelles races jouables).
function Overlord.Sync:RegisterTrustedRaceFileToken(race)
    if type(race) ~= "string" then return nil end
    race = race:match("^%s*(.-)%s*$") or ""
    if race == "" or #race > 40 or not race:match("^[A-Za-z]+$") then return nil end
    race = RACE_FILE_ALIASES[race] or race
    VALID_RACE_FILE[race] = true
    return race
end
local MAX_KILL_PAYLOAD_GUILD_LEN = 24

local function normalizeKillPayloadGuildAt(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts < 0 then return 0 end
    return ts
end

local function sanitizeKillPayloadGuild(guild)
    if type(guild) ~= "string" or guild == "" then return "" end
    guild = (guild:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or "")
    if guild == "" then return "" end
    if #guild > MAX_KILL_PAYLOAD_GUILD_LEN then
        guild = guild:sub(1, MAX_KILL_PAYLOAD_GUILD_LEN)
    end
    return guild
end

local function looksLikeSyncLocaleTag(s)
    if not s or s == "" then return false end
    return s:match("^[a-z][a-z][a-z]?[a-z]?[a-z]?$") ~= nil
end

local function buildLeaderboardBucketEpochToken(epoch)
    epoch = math.floor(tonumber(epoch) or 0)
    if epoch <= 0 then return nil end
    return "B" .. tostring(epoch)
end

-- Parse un payload K (retro-compat ; bucketEpoch + niveau obligatoires pour le score moderne).
function Overlord.Sync:ParseKillPayload(payload)
    if not payload or payload == "" then return nil end
    local name, zoneId, kills, class, faction, epochStr, field7, field8, field9,
        field10, field11, field12, field13 = strsplit(":", payload, 13)
    if not name or name == "" then return nil end
    local guild, locTag = "", ""
    if field8 and field8 ~= "" then
        if field8 == "-" then
            guild = sanitizeKillPayloadGuild(field7 or "")
            locTag = ""
        else
            guild = sanitizeKillPayloadGuild(field7 or "")
            locTag = field8
        end
    elseif field7 and field7 ~= "" then
        if looksLikeSyncLocaleTag(field7) then
            locTag = field7
        end
    end
    local guildAt = normalizeKillPayloadGuildAt(field9)
    local race, raceSex = "", 0
    local bucketEpochToken, levelToken
    if field12 ~= nil then
        -- K 9.7.2 : race et sexe etaient encore repetes dans chaque score.
        race = self:NormalizeRaceFileToken(field10) or ""
        raceSex = normalizeRaceSexCode(field11)
        bucketEpochToken = field12
        levelToken = field13
    else
        -- K 9.7.3+ : race fournie par la Communaute ou le fallback LR.
        bucketEpochToken = field10
        levelToken = field11
    end
    return name, zoneId, kills, class, faction, epochStr, guild, locTag, guildAt,
        race, raceSex, bucketEpochToken, levelToken
end

function Overlord.Sync:ParseLeaderboardRacePayload(payload)
    if not payload or payload == "" then return nil end
    local name, raceField, raceSexField, epochStr, observedAtStr = strsplit(":", payload, 5)
    if not name or name == "" then return nil end
    local race = self:NormalizeRaceFileToken(raceField)
    if not race then return nil end
    local observedAt = math.floor(tonumber(observedAtStr) or 0)
    return name, race, normalizeRaceSexCode(raceSexField), epochStr, observedAt
end

function Overlord.Sync:BuildLeaderboardRacePayload(playerName, raceFile, raceSex, epoch, observedAt)
    playerName = tostring(playerName or "")
    raceFile = self:NormalizeRaceFileToken(raceFile) or ""
    epoch = tostring(epoch or "0")
    if playerName == "" or raceFile == "" then return nil end
    local sex = normalizeRaceSexCode(raceSex)
    observedAt = math.floor(tonumber(observedAt) or 0)
    local payload = string.format(
        "%s:%s:%d:%s:%d", playerName, raceFile, sex, epoch, observedAt)
    if #payload > MAX_LR_PAYLOAD_BYTES then return nil end
    return payload
end

function Overlord.Sync:BuildKillBroadcastPayload(playerName, zoneId, totalKills, class, faction,
    epoch, guild, locale, guildAt, bucketEpoch, playerLevel)
    playerName = tostring(playerName or "")
    zoneId = tostring(zoneId or "")
    totalKills = tostring(totalKills or "0")
    class = tostring(class or "")
    faction = tostring(faction or "")
    epoch = tostring(epoch or "0")
    guild = sanitizeKillPayloadGuild(guild or "")
    locale = tostring(locale or "")
    guildAt = normalizeKillPayloadGuildAt(guildAt)
    local bucketEpochToken = buildLeaderboardBucketEpochToken(bucketEpoch)
    playerLevel = math.floor(tonumber(playerLevel) or 0)
    if playerName == "" or not bucketEpochToken
        or not self:IsEligibleKillContributorLevel(playerLevel) then return nil end
    local function pack(g, loc, ga)
        return string.format("%s:%s:%s:%s:%s:%s:%s:%s:%d:%s:%d",
            playerName, zoneId, totalKills, class, faction, epoch, g or "", loc or "",
            normalizeKillPayloadGuildAt(ga), bucketEpochToken, playerLevel)
    end
    local payload = pack(guild, locale, guildAt)
    if #payload <= MAX_KILL_PAYLOAD_BYTES then return payload end
    payload = pack(guild, "", guildAt)
    if #payload <= MAX_KILL_PAYLOAD_BYTES then return payload end
    -- Payload trop long : retirer la classe, conserver la guilde autoritaire.
    class = ""
    payload = pack(guild, "", guildAt)
    if #payload <= MAX_KILL_PAYLOAD_BYTES then return payload end
    guild = ""
    payload = pack("", "", 0)
    if #payload <= MAX_KILL_PAYLOAD_BYTES then return payload end
    return nil
end

function Overlord.Sync:KillAntiSpoofIsBlacklisted(sender)
    if not sender or sender == "" then return false end
    local exp = killSpoofBlacklist[sender]
    if not exp then return false end
    if GetTime() < exp then
        BoundSecurityEvidenceTable(killSpoofBlacklist, 512, sender)
        return true
    end
    ReleaseSecurityEvidenceKey(killSpoofBlacklist, sender)
    return false
end

-- Enregistre une forge directe de kills (ex. K qui credite un autre joueur). Les valeurs
-- trop hautes heritees d'anciens clients sont refusees ailleurs sans punir l'expediteur.
-- Retourne true si l'expediteur vient d'etre mis en quarantaine.
function Overlord.Sync:KillAntiSpoofRecord(sender)
    if not sender or sender == "" then return false end
    local now = GetTime()
    BoundSecurityEvidenceTable(killSpoofCounts, 512, sender)
    local d = killSpoofCounts[sender]
    if not d or (now - (d.firstSeen or now)) > KILLSPOOF_WINDOW then
        d = { count = 0, firstSeen = now, lastSeen = now }
        killSpoofCounts[sender] = d
    end
    d.count = d.count + 1
    d.lastSeen = now
    if d.count >= KILLSPOOF_THRESHOLD then
        BoundSecurityEvidenceTable(killSpoofBlacklist, 512, sender)
        killSpoofBlacklist[sender] = now + KILLSPOOF_BLACKLIST_DURATION
        return true
    end
    return false
end

-- Compare sender et nom credite (canal direct). Retourne true si l'expediteur est le proprietaire.
function Overlord.Sync:KillSyncSenderOwnsPlayer(sender, playerName)
    if not sender or sender == "" or not playerName or playerName == "" then return false end
    if sender:sub(1, 5) == "BNet-" or sender:sub(1, 7) == "Bridge-" then return false end
    local normSender = self:NormalizeContributorFullName(sender)
    local normPlayer = self:NormalizeContributorFullName(playerName)
    if normSender and normPlayer and normSender == normPlayer then return true end
    local sk = self:GetCaptureContributorDedupKey(sender)
    local nk = self:GetCaptureContributorDedupKey(playerName)
    if sk and nk and sk == nk then return true end
    return self:ForeverIdentitiesMatch(sender, playerName)
end

-- LRU generique des preuves de securite transitoires. Chaque admission/touch est
-- O(1), l'eviction retire la ligne la moins recente sans materialiser ni trier la
-- table a saturation. Les nettoyages TTL consomment eux aussi un quota fixe.
local securityEvidenceTableMeta = setmetatable({}, { __mode = "k" })
BoundSecurityEvidenceTable = function(tbl, maxRows, incomingKey)
    if incomingKey == nil then return end
    maxRows = math.max(1, math.floor(tonumber(maxRows) or 1))
    local meta = securityEvidenceTableMeta[tbl]
    if not meta then
        meta = { nodes = {}, head = nil, tail = nil, count = 0 }
        securityEvidenceTableMeta[tbl] = meta
    end
    local now = GetTime()
    local node = meta.nodes[incomingKey]
    if node then
        node.touchedAt = now
        if node ~= meta.tail then
            if node.previous then node.previous.next = node.next else meta.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = meta.tail, nil
            if meta.tail then meta.tail.next = node end
            meta.tail = node
            if not meta.head then meta.head = node end
        end
        return
    end
    if meta.count >= maxRows and meta.head then
        local evicted = meta.head
        meta.head = evicted.next
        if meta.head then meta.head.previous = nil else meta.tail = nil end
        meta.nodes[evicted.key] = nil
        tbl[evicted.key] = nil
        meta.count = meta.count - 1
    end
    node = { key = incomingKey, touchedAt = now, previous = meta.tail, next = nil }
    if meta.tail then meta.tail.next = node else meta.head = node end
    meta.tail = node
    meta.nodes[incomingKey] = node
    meta.count = meta.count + 1
end

ReleaseSecurityEvidenceKey = function(tbl, key)
    local meta = securityEvidenceTableMeta[tbl]
    local node = meta and meta.nodes[key]
    if node then
        if node.previous then node.previous.next = node.next else meta.head = node.next end
        if node.next then node.next.previous = node.previous else meta.tail = node.previous end
        meta.nodes[key] = nil
        meta.count = math.max(0, meta.count - 1)
    end
    tbl[key] = nil
end

PruneSecurityEvidenceTable = function(tbl, maxAge, budget)
    local meta = securityEvidenceTableMeta[tbl]
    if not meta then return end
    local cutoff = GetTime() - math.max(0, tonumber(maxAge) or 0)
    local removed = 0
    while meta.head and meta.head.touchedAt < cutoff
        and removed < math.max(1, math.floor(tonumber(budget) or 1)) do
        ReleaseSecurityEvidenceKey(tbl, meta.head.key)
        removed = removed + 1
    end
end

local function GetDirectEvidenceSenderKey(sender)
    if not sender or sender == "" then return nil end
    if sender:match("^BNet%-%d+$") or sender:match("^Bridge%-%d+$") then return nil end
    local sync = Overlord.Sync
    return sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(sender) or nil
end

-- K/LK transportent un compteur cumulatif. Apres validation de l'identite K et
-- du bucket de campagne dans Sync.lua, toute replique plausible doit rejoindre
-- le max local. Un quorum ici rendait le resultat dependant des messages recus
-- par chaque client et bloquait notamment le rattrapage BNet/cross-realm.
function Overlord.Sync:SanitizeSyncedKillTotal(total)
    total = math.floor(tonumber(total) or 0)
    if total <= 0 then return 0 end
    if total > PLAUSIBLE_KILL_CEILING then
        -- Donnee refusee, mais pas de quarantaine : des joueurs legit peuvent relayer
        -- un vieux total contamine jusqu'au reset hebdomadaire.
        return nil
    end
    return total
end

-- Plafond plausible des captures LC. Le bucket hebdomadaire obligatoire bloque
-- les replays d'une ancienne campagne ; le plafond bloque les totaux absurdes.
-- 500 etait l'ancienne valeur sentinelle acceptee par erreur (test strictement >).
-- Elle circule maintenant dans des clients modifies : la borne est donc exclusive.
local PLAUSIBLE_CAPTURE_CEILING = 500
Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING = PLAUSIBLE_CAPTURE_CEILING

local lastLbCaptureBatchTsByZoneId = {}
local captureCreditProgressEvidence = {}
local lastDirectCaptureCreditAt = {}
-- Un seul scan nameplate/groupe par fenetre : evite N x 40 unites par rafale LK/LC
-- (regression 9.4+ : IsObservedPlayer* appelait GetObservedPlayerIdentity a chaque message).
local observedUnitsSnapshot = nil
local observedUnitsSnapshotAt = 0
local OBSERVED_UNITS_SNAPSHOT_INTERVAL = 3

local function RefreshObservedUnitsSnapshot()
    local now = GetTime()
    if observedUnitsSnapshot and (now - observedUnitsSnapshotAt) < OBSERVED_UNITS_SNAPSHOT_INTERVAL then
        return observedUnitsSnapshot
    end
    local snapshot = {}
    local sync = Overlord.Sync
    local function readUnit(unit)
        if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
        local unitName = Overlord:SafeGetUnitName(unit, true)
        if not unitName or not sync or not sync.GetCaptureContributorDedupKey then return end
        local targetKey = sync:GetCaptureContributorDedupKey(unitName)
        if not targetKey or snapshot[targetKey] then return end
        local _, classToken = UnitClass(unit)
        local faction = UnitFactionGroup(unit)
        local _, raceFile = UnitRace(unit)
        local raceSex = UnitSex(unit)
        local level = Overlord.SafeUnitLevel and (Overlord:SafeUnitLevel(unit) or 0) or 0
        local guild = Overlord.SafeGetGuildInfo and (Overlord:SafeGetGuildInfo(unit) or "") or ""
        guild = guild:match("^%s*(.-)%s*$") or ""
        snapshot[targetKey] = {
            class = classToken, faction = faction,
            race = raceFile, raceSex = raceSex, guild = guild, level = level,
        }
    end
    readUnit("player")
    if IsInRaid() then
        for i = 1, 40 do readUnit("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, 4 do readUnit("party" .. i) end
    end
    for i = 1, 40 do readUnit("nameplate" .. i) end
    observedUnitsSnapshot = snapshot
    observedUnitsSnapshotAt = now
    return snapshot
end
local CAPTURE_CREDIT_MIN_OBSERVED_SEC = 45
local CAPTURE_CREDIT_MIN_HOLD_SEC = 30
local CAPTURE_CREDIT_SENDER_GAP_SEC = 60

-- Payload C : zoneId:declencheur:faction:ts. Garde une marge sous la limite WoW de 255 octets.
Overlord.Sync.MAX_CAPTURE_PAYLOAD_BYTES = 250

local VALID_CAPTURE_CLASS = {
    WARRIOR = true, MAGE = true, ROGUE = true, DRUID = true, HUNTER = true,
    SHAMAN = true, PRIEST = true, WARLOCK = true, PALADIN = true, DEATHKNIGHT = true,
    MONK = true, DEMONHUNTER = true, EVOKER = true,
}

function Overlord.Sync:IsValidCaptureClassToken(token)
    return token and VALID_CAPTURE_CLASS[token] or false
end

-- Classe connue pour un contributeur : cache LB puis lookup O(1) dans la meme
-- photo bornee groupe/nameplates que toutes les autres preuves d'identite.
function Overlord.Sync:ResolveContributorClassToken(fullName)
    if not fullName or fullName == "" then return nil end
    local targetKey = self:GetCaptureContributorDedupKey(fullName)
    local lb = Overlord.Leaderboard
    if lb then
        -- Handler LC : ne jamais appeler GetExportPlayerMeta ici. Une faction recue juste
        -- avant peut avoir invalide l'index ; le getter reconstruirait alors tout playerInfo
        -- pour chaque paquet de la rafale. Lire seulement la ligne exacte et l'index s'il est chaud.
        local exact = lb.playerInfo and lb.playerInfo[fullName]
        local cachedClass = exact and exact.class or ""
        if (not cachedClass or cachedClass == "") and targetKey
            and type(lb._dedupMetaIndex) == "table" then
            local bucket = lb._dedupMetaIndex[targetKey:lower()]
            cachedClass = bucket and bucket.class or ""
        end
        if cachedClass and cachedClass ~= "" and self:IsValidCaptureClassToken(cachedClass) then
            return cachedClass
        end
    end
    local observed = targetKey and RefreshObservedUnitsSnapshot()[targetKey]
    local token = observed and observed.class
    if token and self:IsValidCaptureClassToken(token) then
        if Overlord.Leaderboard and Overlord.Leaderboard.SetPlayerClassFromSync then
            Overlord.Leaderboard:SetPlayerClassFromSync(fullName, token)
        end
        return token
    end
    return nil
end

-- Prefere Prenom Nom Forever, jamais un suffixe -Royaume.
function Overlord.Sync:ChooseRicherCaptureContributorName(prev, new)
    local prevCanon = self:CanonicalForeverName(prev)
    local newCanon = self:CanonicalForeverName(new)
    if newCanon and not prevCanon then return newCanon end
    if prevCanon and not newCanon then return prevCanon end
    if newCanon and prevCanon then
        if #newCanon > #prevCanon then return newCanon end
        return prevCanon
    end
    if not prev then return new end
    if not new then return prev end
    if #new > #prev then return new end
    return prev
end

-- Anti double-comptage captures : la cle zone+contributeur+timestamp absorbe les copies
-- multi-canaux sans bloquer un co-capteur legitime de la meme zone dans la meme seconde.
function Overlord.Sync:ShouldSkipDuplicateLbCaptureBatch(zoneId, eventTs, contributor)
    if not zoneId or not eventTs or eventTs <= 0 then return false end
    local bucket = lastLbCaptureBatchTsByZoneId[zoneId]
    if not bucket then return false end
    local contributorKey = contributor and self:GetCaptureContributorDedupKey(contributor) or "*"
    return bucket[contributorKey or "*"] == eventTs
end

function Overlord.Sync:MarkLbCaptureBatchCredited(zoneId, eventTs, contributor)
    if zoneId and eventTs and eventTs > 0 then
        local bucket = lastLbCaptureBatchTsByZoneId[zoneId]
        if not bucket then
            bucket = {}
            lastLbCaptureBatchTsByZoneId[zoneId] = bucket
        end
        local contributorKey = contributor and self:GetCaptureContributorDedupKey(contributor) or "*"
        bucket[contributorKey or "*"] = eventTs
        for key, seenTs in pairs(bucket) do
            if eventTs - (tonumber(seenTs) or 0) > 600 then bucket[key] = nil end
        end
    end
end

-- Le ZS terminal direct contient le capteur authentifie et la meme claim que C.
-- Il peut donc reparer le point de classement si le payload C a ete perdu. La
-- preuve longue de CanCreditDirectCapture et le dedup d'evenement restent
-- obligatoires : un simple ZS final isole ne gagne jamais un point.
function Overlord.Sync:CreditDirectCaptureFromFinalState(
    claimKey, originName, sender)
    if not self.ParseCaptureFinalClaimKey then return false end
    local parsed = self:ParseCaptureFinalClaimKey(claimKey)
    local originKey = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(originName) or nil
    if not parsed or not originKey or parsed.originKey ~= originKey
        or not self.CaptureContributorMatchesSender
        or not self:CaptureContributorMatchesSender(originName, sender) then return false end
    if self:ShouldSkipDuplicateLbCaptureBatch(
        parsed.zoneId, parsed.captureTs, originName) then return true end
    local faction = parsed.ownerCode == "A" and "Alliance" or "Horde"
    if not self.CanCreditDirectCapture
        or not self:CanCreditDirectCapture(
            sender, originName, parsed.zoneId, faction) then return false end
    if not Overlord.Leaderboard or not Overlord.Leaderboard.AddPlayerCapture then return false end
    if Overlord.Leaderboard.SetPlayerFaction then
        -- La faction appartient a la claim finale emise par le capteur direct.
        Overlord.Leaderboard:SetPlayerFaction(originName, faction)
    end
    Overlord.Leaderboard:AddPlayerCapture(originName, parsed.zoneId, true)
    self:MarkLbCaptureBatchCredited(parsed.zoneId, parsed.captureTs, originName)
    if self.MarkFreshCaptureLeaderboardRow then
        self:MarkFreshCaptureLeaderboardRow(originName)
    end
    return true
end

-- Invalide le marqueur quand le proprietaire change : une recapture doit pouvoir etre creditee.
function Overlord.Sync:ClearLbCaptureBatchDedup(zoneId)
    if zoneId then
        lastLbCaptureBatchTsByZoneId[zoneId] = nil
    end
end

-- Forever : Prenom Nom vs compact PrenomNom. Le seul prenom ne match jamais le nom complet.
function Overlord.Sync:ForeverIdentitiesMatch(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then
        return false
    end
    if a:match("^BNet%-") or b:match("^BNet%-") then return false end
    if a:match("^Bridge%-") or b:match("^Bridge%-") then return false end
    local ca = self:CanonicalForeverName(a)
    local cb = self:CanonicalForeverName(b)
    if ca and cb then return ca:lower() == cb:lower() end
    local function compact(n)
        local base = self:ForeverCharacterBase(n)
        return base and base:gsub("%s", ""):lower() or nil
    end
    local xa, xb = compact(a), compact(b)
    if not xa or not xb or xa ~= xb then return false end
    return ca ~= nil or cb ~= nil
end

-- Un message addon direct porte une identite WoW non choisie par le payload. Seul ce joueur
-- peut donc gagner un point via C. Les bridges/BNet restent utiles pour l'etat de carte, mais
-- ne constituent pas une preuve d'identite suffisante pour modifier le classement.
-- Methode placee dans SyncAux pour ne pas ajouter de local au chunk Sync.lua (limite WoW: 200).
function Overlord.Sync:CaptureContributorMatchesSender(contributor, sender)
    if not contributor or not sender or sender == "" then return false end
    if sender:match("^BNet%-%d+$") or sender:match("^Bridge%-%d+$") then return false end
    local contributorKey = self:GetCaptureContributorDedupKey(contributor)
    local senderKey = self:GetCaptureContributorDedupKey(sender)
    if contributorKey and senderKey and contributorKey == senderKey then return true end
    return self:ForeverIdentitiesMatch(contributor, sender)
end

function Overlord.Sync:GetObservedPlayerIdentity(playerName)
    if not playerName then return nil end
    local targetKey = self:GetCaptureContributorDedupKey(playerName)
    if not targetKey then return nil end
    -- Le snapshot est deja un cache indexe par cle dedup. Un second cache par nom
    -- dupliquait les lignes positives et conservait sans borne chaque miss distant.
    return RefreshObservedUnitsSnapshot()[targetKey]
end

function Overlord.Sync:IsObservedPlayerRace(playerName, raceFile, raceSex)
    raceFile = self:NormalizeRaceFileToken(raceFile)
    local row = raceFile and self:GetObservedPlayerIdentity(playerName)
    if not row or not Overlord:SafeStringEquals(row.race, raceFile) then return false end
    raceSex = math.floor(tonumber(raceSex) or 0)
    return raceSex ~= 2 and raceSex ~= 3 or row.raceSex == raceSex
end

function Overlord.Sync:IsObservedPlayerClass(playerName, classToken)
    if not playerName or not self:IsValidCaptureClassToken(classToken) then return false end
    local row = self:GetObservedPlayerIdentity(playerName)
    return row and Overlord:SafeStringEquals(row.class, classToken) or false
end

function Overlord.Sync:IsObservedPlayerFaction(playerName, faction)
    if not playerName or (faction ~= "Alliance" and faction ~= "Horde") then return false end
    local row = self:GetObservedPlayerIdentity(playerName)
    return row and Overlord:SafeStringEquals(row.faction, faction) or false
end

-- Une observation WoW locale est une preuve plus forte qu'un vote reseau. Ce
-- raccourci reste limite aux metadonnees directement visibles et s'execute avant
-- toute allocation de ligne/quota dans le chemin de classement.
function Overlord.Sync:IsLocallyObservedLeaderboardClaim(kind, claimKey)
    if type(claimKey) ~= "string" or claimKey == "" then return false end
    local playerName, value, extra = strsplit(":", claimKey, 3)
    if not playerName or playerName == "" or not value or value == "" then return false end
    if kind == "META-CLASS" then
        return self.IsObservedPlayerClass and self:IsObservedPlayerClass(playerName, value) or false
    elseif kind == "META-FACTION" then
        return self.IsObservedPlayerFaction and self:IsObservedPlayerFaction(playerName, value) or false
    elseif kind == "META-RACE" then
        return self.IsObservedPlayerRace
            and self:IsObservedPlayerRace(playerName, value, tonumber(extra) or 0) or false
    elseif kind == "GY" then
        return self.IsObservedPlayerGuild and self:IsObservedPlayerGuild(playerName, value) or false
    end
    return false
end

function Overlord.Sync:RecordCaptureCreditProgressEvidence(sender, capturer, zoneId, faction, holdTime)
    if not self:CaptureContributorMatchesSender(capturer, sender) then return end
    if not zoneId or zoneId == "" or (faction ~= "Alliance" and faction ~= "Horde") then return end
    -- Le sender WoW doit etre le capteur et maintenir une progression coherente pendant 45 s.
    -- Cela conserve la convergence des captures solo/cross-faction tout en bloquant les +1 instantanes.
    local remoteHold = tonumber(holdTime) or 0
    local senderKey = GetDirectEvidenceSenderKey(sender)
    if not senderKey then return end
    local key = senderKey .. ":" .. zoneId .. ":" .. faction
    local now = GetTime()
    BoundSecurityEvidenceTable(captureCreditProgressEvidence, 256, key)
    local row = captureCreditProgressEvidence[key]
    if not row or now - (row.lastSeen or 0) > 180 then
        row = { firstSeen = now, lastSeen = now, firstHold = remoteHold, maxHold = remoteHold, lastHold = remoteHold }
        captureCreditProgressEvidence[key] = row
    end
    if remoteHold + 5 < (row.lastHold or remoteHold) then return end
    row.lastSeen = now
    row.lastHold = math.max(row.lastHold or 0, remoteHold)
    row.maxHold = math.max(row.maxHold or 0, remoteHold)
end

function Overlord.Sync:CanCreditDirectCapture(sender, contributor, zoneId, faction)
    if not self:CaptureContributorMatchesSender(contributor, sender) then return false end
    local senderKey = GetDirectEvidenceSenderKey(sender)
    if not senderKey then return false end
    local now = GetTime()
    local creditGapKey = senderKey .. ":" .. tostring(zoneId or "")
    local lastCreditAt = lastDirectCaptureCreditAt[creditGapKey] or 0
    if now - lastCreditAt < CAPTURE_CREDIT_SENDER_GAP_SEC then
        BoundSecurityEvidenceTable(lastDirectCaptureCreditAt, 512, creditGapKey)
        return false
    end
    if lastCreditAt > 0 and now - lastCreditAt > 300 then
        ReleaseSecurityEvidenceKey(lastDirectCaptureCreditAt, creditGapKey)
    end
    local key = senderKey .. ":" .. tostring(zoneId or "") .. ":" .. tostring(faction or "")
    local row = captureCreditProgressEvidence[key]
    if not row or now - (row.firstSeen or now) < CAPTURE_CREDIT_MIN_OBSERVED_SEC
        or (row.maxHold or 0) < CAPTURE_CREDIT_MIN_HOLD_SEC
        or (row.maxHold or 0) - (row.firstHold or 0) < CAPTURE_CREDIT_MIN_HOLD_SEC
        or now - (row.lastSeen or 0) > 30 then
        return false
    end
    ReleaseSecurityEvidenceKey(captureCreditProgressEvidence, key)
    BoundSecurityEvidenceTable(lastDirectCaptureCreditAt, 512, creditGapKey)
    lastDirectCaptureCreditAt[creditGapKey] = now
    return true
end

function Overlord.Sync:GetSecuritySenderKey(sender)
    return GetDirectEvidenceSenderKey(sender)
end

-- C et ZS terminal transportent la meme affirmation minimale. Les compteurs,
-- classe et shard restent hors de cette cle. La duree finale y est incluse pour
-- lier le contrat 60/120/180 (ou la duree canonique d'une capitale) a la vague.
function Overlord.Sync:BuildCaptureFinalClaimKey(zoneId, ownerCode, captureTs,
    originName, waveId, originGuid, finalRequirement)
    local originKey = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(originName) or nil
    local ts = math.floor(tonumber(captureTs) or 0)
    if not zoneId or zoneId == "" or (ownerCode ~= "A" and ownerCode ~= "H")
        or ts <= 0 or not originKey or type(waveId) ~= "string"
        or waveId == "" or #waveId > 48 or not waveId:match("^[%w_-]+$")
        or type(originGuid) ~= "string" or originGuid == "" or #originGuid > 80
        or not originGuid:match("^[%w-]+$") then return nil end
    local zone = (Overlord.Zones and Overlord.Zones.GetZone
        and Overlord.Zones:GetZone(zoneId))
        or (Overlord.Fronts and Overlord.Fronts.GetZone
            and select(1, Overlord.Fronts:GetZone(zoneId)))
    local owner = ownerCode == "A" and "Alliance" or "Horde"
    local requirement = Overlord.CaptureLease
        and Overlord.CaptureLease.NormalizeCaptureRequirement
        and Overlord.CaptureLease:NormalizeCaptureRequirement(
            zone, owner, finalRequirement) or nil
    if not requirement then return nil end
    local epoch = (Overlord.GetCurrentCampaignWireEpoch
        and Overlord:GetCurrentCampaignWireEpoch())
        or (OverlordDB and OverlordDB.lastResetTimestamp) or 0
    return table.concat({
        tostring(math.floor(tonumber(epoch) or 0)), tostring(zoneId), ownerCode,
        tostring(ts), originKey, waveId, originGuid, tostring(requirement),
    }, ":")
end

-- Retourne nil si l'unite n'est pas visible, sinon le verdict issu de l'API WoW.
-- Tous les niveaux valides sont acceptes, y compris ceux observes sur les rerolls.
function Overlord.Sync:IsObservedPlayerKillLevelEligible(playerName)
    if not playerName then return nil end
    local row = self:GetObservedPlayerIdentity(playerName)
    if row and (tonumber(row.level) or 0) > 0 then
        return self:IsEligibleKillContributorLevel(row.level)
    end
    local rosterLevel = self.GetOnlineCommunityMemberLevelIfFresh
        and self:GetOnlineCommunityMemberLevelIfFresh(playerName, 600) or nil
    if rosterLevel then return self:IsEligibleKillContributorLevel(rosterLevel) end
    return nil
end

function Overlord.Sync:ParseCaptureFinalClaimKey(claimKey)
    if type(claimKey) ~= "string" or claimKey == "" or #claimKey > 320 then return nil end
    local epoch, zoneId, ownerCode, captureTs, originKey, waveId, originGuid,
        finalRequirement = claimKey:match(
            "^([^:]+):([^:]+):([AH]):([^:]+):([^:]+):([^:]+):([^:]+):([^:]+)$")
    if not epoch then return nil end
    local rebuilt = self:BuildCaptureFinalClaimKey(
        zoneId, ownerCode, captureTs, originKey, waveId, originGuid,
        finalRequirement)
    if rebuilt ~= claimKey then return nil end
    return {
        epoch = tonumber(epoch), zoneId = zoneId, ownerCode = ownerCode,
        captureTs = tonumber(captureTs), originKey = originKey,
        waveId = waveId, originGuid = originGuid,
        finalRequirement = tonumber(finalRequirement),
    }
end

-- LC suit le meme merge monotone que LK : une replique valide suffit, puis
-- Leaderboard:SetPlayerCaptureCount conserve le maximum connu.
function Overlord.Sync:SanitizeSyncedCaptureCount(total)
    total = math.floor(tonumber(total) or 0)
    if total <= 0 then return 0 end
    if total >= PLAUSIBLE_CAPTURE_CEILING then
        return nil
    end
    return total
end

-- ============ Quarantaine anti-burst (messages mutateurs de score) ============
-- Les paquets de classement LK/LC/LR sont cadences par les pompes SR/HR : 80
-- lignes par type sur cinq secondes laisse une marge superieure au debit legitime
-- (~42) tout en coupant les rafales avant les allocations et mutations suivantes.
-- Les snapshots territoriaux (GK/GH/LO/LOC/ZA/ZS...) gardent leurs propres bornes.
local SCORE_BURST_TYPES = { K = true, EK = true, LK = true, LC = true, LR = true }
local SCORE_BURST_MAX = { K = 40, EK = 40, LK = 80, LC = 80, LR = 80 }
local senderBurstWindow = {}      -- sender -> { counts = { K=.. }, windowStart }
local senderBurstQuarantine = {}  -- sender -> msgType -> expiration (GetTime)
local BURST_WINDOW = 5
local BURST_QUARANTINE_DURATION = 120

-- Retourne true si le message doit etre ignore (expediteur en quarantaine de rafale).
function Overlord.Sync:SenderBurstShouldDrop(sender, msgType)
    if not sender or sender == "" then return false end
    local burstMax = SCORE_BURST_MAX[msgType]
    if not SCORE_BURST_TYPES[msgType] or not burstMax then return false end
    local now = GetTime()
    local quarantines = senderBurstQuarantine[sender]
    local exp = quarantines and quarantines[msgType]
    if exp then
        if now < exp then
            BoundSecurityEvidenceTable(senderBurstQuarantine, 512, sender)
            return true
        end
        quarantines[msgType] = nil
        if not next(quarantines) then
            ReleaseSecurityEvidenceKey(senderBurstQuarantine, sender)
            quarantines = nil
        end
    end
    BoundSecurityEvidenceTable(senderBurstWindow, 512, sender)
    local w = senderBurstWindow[sender]
    if not w or (now - (w.windowStart or now)) > BURST_WINDOW then
        w = { counts = {}, windowStart = now }
        senderBurstWindow[sender] = w
    end
    w.counts[msgType] = (w.counts[msgType] or 0) + 1
    if w.counts[msgType] > burstMax then
        quarantines = senderBurstQuarantine[sender]
        if not quarantines then
            BoundSecurityEvidenceTable(senderBurstQuarantine, 512, sender)
            quarantines = {}
            senderBurstQuarantine[sender] = quarantines
        end
        quarantines[msgType] = now + BURST_QUARANTINE_DURATION
        return true
    end
    return false
end

-- Nettoyage periodique des tables anti-triche kills / rafale (evite la croissance en session longue).
C_Timer.NewTicker(120, function()
    if Overlord.InstanceSuspended then return end
    PruneSecurityEvidenceTable(killSpoofCounts, KILLSPOOF_WINDOW, 32)
    PruneSecurityEvidenceTable(killSpoofBlacklist, KILLSPOOF_BLACKLIST_DURATION, 32)
    PruneSecurityEvidenceTable(senderBurstWindow, BURST_WINDOW, 32)
    PruneSecurityEvidenceTable(senderBurstQuarantine, BURST_QUARANTINE_DURATION, 32)
    PruneSecurityEvidenceTable(captureCreditProgressEvidence, 180, 32)
    PruneSecurityEvidenceTable(lastDirectCaptureCreditAt, 300, 32)
end)
