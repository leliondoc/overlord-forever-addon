-- Sync.lua - Synchronisation peer-to-peer entre joueurs via Addon Messages
-- Protocole : messages courts (<255 octets), faction-filtres
-- Tout joueur peut repondre aux sync requests (progression additive, jamais de recul)
-- Seuls les admins peuvent envoyer des commandes destructives (reset, force capture)
-- BRIDGE : relais cross-server cross-faction via amis BNet (inspire de Cross RP)
Overlord = Overlord or {}
-- Ne pas ecraser : chunks WoW / fichiers Sync*.lua ajoutent des methodes au meme table.
Overlord.Sync = Overlord.Sync or {}
Overlord.SyncTuning = Overlord.SyncTuning or {}
local TUNING = Overlord.SyncTuning

local L = Overlord.L

local PREFIX = "OverlordF"
local CHANNEL_NAME = "OverlordF"
-- Forever : canal royaume + groupe + communaute + BNet (cross-faction, pas de Warmode).
local SYNC_USE_REALM_CHANNEL = true
local SYNC_USE_BNET_OUTBOUND = true
local syncFrame = CreateFrame("Frame")
local pendingSync = false
local MAX_CLOCK_SKEW = 300           -- 5 min de tolerance pour le decalage d'horloge entre joueurs
local POST_VICTORY_SYNC_GUARD = 60   -- Ignore les anciens C/ZS/ZA qui arrivent juste apres un TV

-- Flag anti-doublon victoire + garde post-TV (dans priv : limite 200 locals WoW)
local priv = {
    totalVictoryAnnounced = {},
    totalVictoryDeliveredAt = {},
    postVictorySyncGuardUntil = {},
    captureDedup = {},
    captureDedupCount = 0,
    captureDedupMax = 128,
    captureDedupBlockedUntil = 0,
    captureChatDedup = {},
    captureChatDedupTs = {},
    captureChatDedupTsCount = 0,
    captureChatDedupTsMax = 256,
    captureChatDedupTsBlockedUntil = 0,
    captureDedupSec = 10,
    captureChatDedupSec = 30,
    captureChatDedupCapitalSec = 45,
    enemyAlertLast = {},
    enemyAlertSkipUntil = {},
    enemyAlertEmitted = {},
    enemyAlertWaveKey = {},
    enemyAlertCooldown = 90,
    zsPayloadDedup = nil,
    zsPayloadDedupSec = 4,
    prereqGraceUntil = {},
    prereqGraceSec = 14,
    mineStockLast = {},
    mineStockBNetLast = {},
    mineStockInterval = 2.5,
    mineStockBNetInterval = 30,
    woodStockLast = {},
    woodStockBNetLast = {},
    woodStockInterval = 2.5,
    woodStockBNetInterval = 30,
    mineAlertLast = {},
    mineAlertCooldown = 60,
    woodAlertLast = {},
    woodAlertCooldown = 60,
    staleSameSecHoldSec = 20,
    fcRecvLast = {},
    recentAddonWhispers = {},
    recentAddonWhisperAliases = {},
    recentAddonWhisperNodes = {},
    recentAddonWhisperHead = nil,
    recentAddonWhisperTail = nil,
    recentAddonWhisperCount = 0,
    recentAddonWhisperMax = 1024,
    pendingDirectSR = {},
    pendingDirectSRRetryScheduled = false,
    pendingDirectSRCount = 0,
    syncResponseDeadline = 0,
    raidLateJoinSrMaxTargets = 2,
    raidLateJoinSrBurstMax = 3,
    raidLateJoinSrBurstWindow = 90,
    raidLateJoinSrGlobalCooldown = 90,
    lastRaidLateJoinSr = 0,
    raidLateJoinSrBurstCount = 0,
    raidLateJoinSrBurstStart = 0,
    raidLateJoinCatchUpPending = false,
    raidLateJoinForceNext = false,
    raidLateJoinTargetCursor = 0,
    raidLateJoinExpectedResponders = {},
    groupSyncStatePrimed = false,
    wasGroupedForSync = false,
    captureOriginSrLast = {},
    syncCampaignCacheAt = 0,
    syncCampaignStart = 0,
    syncCampaignId = 0,
    syncCampaignWireEpoch = 0,
    recentCaptureLeaderboardRows = {},
    observedRaceBroadcastEpoch = 0,
    observedRaceBroadcast = {},
    -- Admission des lignes de classement tierces. SR:F n'a pas de nonce dans
    -- les anciens clients : une reservation courte, liee au whisper cible et
    -- plafonnee par type, est la seule autorite temporaire accordee.
    expectedFullLeaderboardResponses = {},
    -- ZA v2 : les pages d'un snapshot de carte ne sont jamais appliquees
    -- separement. Le cache est borne et ephemere (anti-spam / anti-rejeu).
    pendingZaSnapshotPages = {},
    completedZaSnapshots = {},
    zaPendingSenderWindows = nil,
}

-- Ledger ephemere fail-closed : une cle encore dans sa fenetre de dedup n'est
-- jamais evincee pour admettre un nouvel evenement. Le scan O(N) ne se produit
-- qu'a l'expiration la plus proche; entre-temps la saturation est O(1).
local function EnsureCaptureDedupCapacity(deliveryKey, now)
    if priv.captureDedup[deliveryKey] ~= nil then return true end
    if priv.captureDedupCount < priv.captureDedupMax then return true end
    if now < (tonumber(priv.captureDedupBlockedUntil) or 0) then return false end
    local count, earliestExpiry = 0, math.huge
    for key, seenAt in pairs(priv.captureDedup) do
        seenAt = tonumber(seenAt) or 0
        if now - seenAt > priv.captureDedupSec then
            priv.captureDedup[key] = nil
        else
            count = count + 1
            earliestExpiry = math.min(earliestExpiry, seenAt + priv.captureDedupSec)
        end
    end
    priv.captureDedupCount = count
    if count >= priv.captureDedupMax then
        priv.captureDedupBlockedUntil = earliestExpiry + 0.01
        return false
    end
    priv.captureDedupBlockedUntil = 0
    return true
end

local function RememberCaptureDelivery(deliveryKey, now)
    if priv.captureDedup[deliveryKey] ~= nil then return true end
    if not EnsureCaptureDedupCapacity(deliveryKey, now) then return false end
    priv.captureDedup[deliveryKey] = now
    priv.captureDedupCount = priv.captureDedupCount + 1
    return true
end

-- Etat interne partage avec SyncAux.lua / SyncGuildKeep (pas d'export direct de la table).
function Overlord.Sync:GetPriv()
    return priv
end

local function MarkPostVictorySyncGuard(frontId)
    if not frontId or frontId == "" then return end
    priv.postVictorySyncGuardUntil[frontId] = GetTime() + POST_VICTORY_SYNC_GUARD
end

function Overlord.Sync:MarkPostVictorySyncGuard(frontId)
    MarkPostVictorySyncGuard(frontId)
end

local function NormalizeRemoteTimestamp(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return 0 end
    local now = time()
    if ts > now + MAX_CLOCK_SKEW then return nil end
    return math.floor(ts)
end

function Overlord.Sync:DeterministicCaptureTieOwner(zoneId, capturedAt)
    -- Les anciens formats n'ont pas d'eventId. Pour deux captures opposees dans
    -- la meme seconde, tous les transports doivent choisir le meme resultat,
    -- independamment de l'ordre des paquets.
    local hash = math.floor(tonumber(capturedAt) or 0)
    for i = 1, #(zoneId or "") do
        hash = (hash + string.byte(zoneId, i) * i) % 2147483647
    end
    return (hash % 2 == 0) and "Alliance" or "Horde"
end

local function IsStaleCampaignTimestamp(ts)
    local lastReset = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    return ts and ts > 0 and lastReset > 0 and ts < lastReset
end

-- Pendant la treve post-victoire (15 min), ignorer les assauts et changements de proprietaire.
-- ZA/ZS anterieurs au reset post-treve : ne pas re-appliquer l'etat « tout Alliance » de la victoire.
local function ShouldRejectStaleTruceResetZone(zoneId, ts)
    if not OverlordDB or not zoneId or not ts or ts <= 0 then return false end
    if not Overlord.Fronts then return false end
    local _, front = Overlord.Fronts:GetZone(zoneId)
    local frontId = front and front.id
    if not frontId then return false end
    local resetEpoch = OverlordDB.frontTruceResetEpoch and tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0
    return resetEpoch > 0 and ts < resetEpoch
end

-- Un snapshot neutre est destructeur : sans preuve de reset il ne peut pas
-- effacer une capture canonique de la campagne courante. La quarantaine login
-- et les anciens finals visuels ne sont pas des tombstones de reset.
local function CanNeutralZaReplaceCanonicalCapture(zoneId, zone, ts)
    -- L'owner d'un lease orange est un overlay, pas le socle que ZA transporte.
    -- Comparer N au snapshot stable permet de garder la wave visible sans traiter
    -- son attaquant transitoire comme une capture canonique a neutraliser.
    if zone and zone.status == "in_progress" and zone._remoteCaptureLease
        and not zone.holdAuthorityLocal and Overlord.CaptureLease
        and Overlord.CaptureLease.GetPersistableView then
        local stable = Overlord.CaptureLease:GetPersistableView(zone)
        if stable and stable ~= zone then zone = stable end
    end
    if not zone then return true end
    local capturedAt = tonumber(zone.capturedTime) or 0
    -- Owner vide mais horloge de campagne : ApplyFactionConfig a pu nil l'owner
    -- avant Restore. Un ZA N ne doit pas effacer cette capture.
    if not zone.owner and capturedAt <= 0 then return true end

    local localClock = math.max(capturedAt, tonumber(zone.updatedAt) or 0)
    local campaignStart = (Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    -- Donnee disque d'une ancienne campagne : le reset hebdomadaire courant
    -- suffit, notamment pendant la restauration/login. Un owner sans horloge
    -- n'est en revanche jamais efface sur la seule parole d'un ZA.
    if localClock > 0 and campaignStart > 0 and localClock < campaignStart then
        return true
    end
    if not OverlordDB or not Overlord.Fronts then return false end
    local _, front = Overlord.Fronts:GetZone(zoneId)
    local frontId = front and front.id
    local resetEpoch = frontId and OverlordDB.frontTruceResetEpoch
        and tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0
    -- Hors login, seul un reset de treve deja derive/applique localement peut
    -- rendre neutre une capture courante. Le ZA doit porter le meme tombstone.
    return resetEpoch > localClock and math.abs((tonumber(ts) or 0) - resetEpoch) <= 5
end

local function ShouldRejectFrontTruceZoneChange(zoneId, owner, status)
    if not OverlordDB or not zoneId or not Overlord.Fronts or not Overlord.Zones then return false end
    local _, front = Overlord.Fronts:GetZone(zoneId)
    local frontId = front and front.id
    if not frontId then return false end
    local onCooldown, _, winner = Overlord.Zones:IsOnVictoryCooldown(frontId)
    if not onCooldown or not winner then return false end
    if status == "in_progress" then return true end
    if status == "captured" and owner and owner ~= winner then return true end
    -- Pas de ZS « available » : evite de rouvrir la carte pendant la treve.
    if status == "available" then return true end
    return false
end

local function ShouldRejectPostVictoryZoneOwner(zoneId, owner, status, ts, source)
    if ShouldRejectFrontTruceZoneChange(zoneId, owner, status) then return true end
    if not OverlordDB or not zoneId or not owner or not ts or ts <= 0 then return false end
    if owner ~= "Alliance" and owner ~= "Horde" then return false end
    if not Overlord.Fronts then return false end

    local _, front = Overlord.Fronts:GetZone(zoneId)
    local frontId = front and front.id
    if not frontId then return false end

    local victory = OverlordDB.frontVictories and OverlordDB.frontVictories[frontId]
    local victoryTs = victory and tonumber(victory.timestamp)
    local winner = victory and victory.faction
    if (not victoryTs or not winner) and OverlordDB.lastVictoryFrontId == frontId then
        victoryTs = tonumber(OverlordDB.lastVictoryTimestamp)
        winner = OverlordDB.lastVictoryFaction
    end
    if not victoryTs or not winner or owner == winner then return false end
    local inLocalGuard = GetTime() <= (priv.postVictorySyncGuardUntil[frontId] or 0)
    if not inLocalGuard then return false end

    return true
end

local srEvidencePageNonce = 0

-- Payload SR : faction + version + victoire + page de preuves demandee.
-- Modes :
--   T = territorial leger (defaut, y compris pour les clients legacy sans mode)
--   S = etats gameplay secondaires bornes, sans classement
--   F = historique complet, uniquement honore en transport direct
-- Le nonce final est ignore par les anciennes versions, mais force tous les repondeurs
-- d'une meme requete a choisir le meme bloc de lignes LOC au lieu de curseurs divergents.
local function SRPayload(requestMode)
    local vts = (OverlordDB and OverlordDB.lastVictoryTimestamp) or 0
    local vf = OverlordDB and OverlordDB.lastVictoryFaction
    local vfront = (OverlordDB and OverlordDB.lastVictoryFrontId) or ""
    local vfCode = ""
    if vf == "Alliance" then vfCode = "A"
    elseif vf == "Horde" then vfCode = "H" end
    local persistedNonce = OverlordDB and tonumber(OverlordDB.syncEvidencePageNonce)
    if persistedNonce and persistedNonce >= 0 and persistedNonce <= 2147483646 then
        srEvidencePageNonce = math.floor(persistedNonce)
    end
    srEvidencePageNonce = (srEvidencePageNonce + 1) % 2147483647
    if OverlordDB then OverlordDB.syncEvidencePageNonce = srEvidencePageNonce end
    local versionField = (Overlord.Version or "") .. "~" .. srEvidencePageNonce
    local mode = (requestMode == "F" and "F")
        or (requestMode == "S" and "S") or "T"
    return (Overlord.PlayerFaction or "") .. ":" .. versionField .. ":" .. vts
        .. ":" .. vfCode .. ":" .. vfront .. ":" .. mode
end

-- Accesseur public pour SRPayload (utilise par Commands.lua pour /ov sync <target>)
function Overlord.Sync:GetSRPayload(requestMode)
    return SRPayload(requestMode)
end

-- Comparaison semver simple (retourne >0 si v1 > v2, 0 si egal, <0 si v1 < v2)
local function CompareVersions(v1, v2)
    local a1, b1, c1 = tostring(v1 or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    local a2, b2, c2 = tostring(v2 or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a1 or not a2 then return 0 end
    if c1 == "" then c1 = "0" end
    if c2 == "" then c2 = "0" end
    a1, b1, c1 = tonumber(a1), tonumber(b1), tonumber(c1)
    a2, b2, c2 = tonumber(a2), tonumber(b2), tonumber(c2)
    if a1 ~= a2 then return a1 - a2 end
    if b1 ~= b2 then return b1 - b2 end
    return c1 - c2
end

-- Message chat one-shot (feedback immediat) + memoire de la version la plus recente vue sur le
-- reseau (pour l'alerte raid a chaque entree de front, cf. Overlord:OnEnterFront dans Core.lua).
-- Stockee sur Overlord.Sync (pas un nouveau local top-level : Sync.lua est proche de la limite des 200
-- locals par chunk).
local versionNotified = false

local function CheckRemoteVersion(remoteVersion)
    if not remoteVersion or remoteVersion == "" then return end
    if not Overlord.Version then return end
    if CompareVersions(remoteVersion, Overlord.Version) > 0 then
        if not Overlord.Sync._knownNewerVersion
            or CompareVersions(remoteVersion, Overlord.Sync._knownNewerVersion) > 0 then
            Overlord.Sync._knownNewerVersion = remoteVersion
        end
        if not versionNotified then
            versionNotified = true
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.VERSION_OUTDATED, remoteVersion))
        end
    end
end

-- Accesseur : version la plus recente connue (nil si aucune version plus recente vue encore).
function Overlord.Sync:GetKnownNewerVersion()
    return self._knownNewerVersion
end

-- Capture vue en observateur distant : dernier ZS peut manquer (throttle BNet/canaux).
-- Un SR groupe/canal rafraichit ZA/ZS sans attendre approach-proximity (throttle global anti-spam).
local lastStaleObserverPoll = 0
local STALE_OBSERVER_POLL_INTERVAL = 22
local STALE_OBSERVER_POLL_INTERVAL_LARGE = 32
local STALE_CAPITAL_OBSERVER_POLL_INTERVAL = 55

function Overlord.Sync:PollIfStaleObserverInProgress(secondsSinceZs, zone)
    local pollInterval
    if zone and zone.isCapital then
        pollInterval = STALE_CAPITAL_OBSERVER_POLL_INTERVAL
    elseif self:IsLargeEvent() then
        pollInterval = STALE_OBSERVER_POLL_INTERVAL_LARGE
    else
        pollInterval = STALE_OBSERVER_POLL_INTERVAL
    end
    if Overlord.InstanceSuspended or not secondsSinceZs or secondsSinceZs < pollInterval then return end
    local now = GetTime()
    if now - lastStaleObserverPoll < pollInterval then return end
    lastStaleObserverPoll = now
    self:SendSyncRequest()
end

-- ==================== Systeme de bridges (cross-server cross-faction) ====================
-- Band = realm_faction (ex: "MoonGuard_A", "Hyjal_H")
-- Bridge = joueur local (meme realm/faction) qui a des amis BNet de l'autre faction/realm
-- R1 = requete au bridge (whisper) ; R2 = relais via BNet ; reponse en whisper au demandeur

local BRIDGE_ST_INTERVAL = 90
local BRIDGE_EXPIRE = 180
local bnet_links = {}       -- gameAccountID -> band (amis BNet, band appris via leurs messages)
local bridges = { values = {}, nodes = {}, head = nil, tail = nil, count = 0, max = 512 }
function bridges:Remove(node)
    if not node then return end
    if node.previous then node.previous.next = node.next else self.head = node.next end
    if node.next then node.next.previous = node.previous else self.tail = node.previous end
    self.nodes[node.key], self.values[node.key] = nil, nil
    self.count = math.max(0, self.count - 1)
end
function bridges:Remember(key, value, now)
    local node = self.nodes[key]
    if node then
        node.timestamp = now
        self.values[key] = value
        if node ~= self.tail then
            if node.previous then node.previous.next = node.next else self.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = self.tail, nil
            if self.tail then self.tail.next = node end
            self.tail = node
        end
        return
    end
    if self.count >= self.max then self:Remove(self.head) end
    node = { key = key, timestamp = now, previous = self.tail, next = nil }
    if self.tail then self.tail.next = node else self.head = node end
    self.tail = node
    self.nodes[key], self.values[key] = node, value
    self.count = self.count + 1
end
function bridges:Prune(now, budget)
    local removed = 0
    while self.head and now - self.head.timestamp > BRIDGE_EXPIRE * 2
        and removed < math.max(1, math.floor(tonumber(budget) or 1)) do
        self:Remove(self.head)
        removed = removed + 1
    end
end
local lastSTBroadcast = 0

-- ==================== Decouverte via Communaute WoW (cross-realm + cross-faction) ====================
-- Scanne les membres en ligne de la communaute "Overlord" pour envoyer des SR en whisper.
-- Cross-realm : le canal "Overlord" est realm-only, la communaute traverse les royaumes.
-- Cross-faction : la communaute active le whisper entre ses membres, y compris cross-faction.
-- Filtre CHAT_MSG_SYSTEM restreint (voir InstallWhisperOfflineChatFilter) : masque uniquement les erreurs
-- Blizzard du type hors-ligne correlees aux whispers addon Overlord (recentAddonWhispers).
-- Le canal "Overlord" (realm-only, cross-faction) et les bridges BNet completent la couverture.

local COMMUNITY_SCAN_INTERVAL = 120
local COMMUNITY_SR_COOLDOWN = 90
local COMMUNITY_MAX_SR_PER_SCAN = 10
local LOGIN_CATCHUP_SR_MAX = 40
local LOGIN_CATCHUP_SR_MAX_LARGE = 15
local LOGIN_CATCHUP_SR_DELAY = 0.25
local COMMUNITY_SEARCH_INTERVAL = 300
local communityClubId = nil
local communityClubIds = {}
-- Clubs europeens d'un AUTRE pool territorial auxquels le compte est aussi
-- abonne. Ils restent separes de FindAllCommunityClubs : seul le protocole
-- leaderboard HR peut les consommer, jamais les transports C/ZA/ZS/GK.
local europeanLeaderboardBridgeClubIds = {}
local lastCommunityScan = 0
local lastCommunitySearch = -COMMUNITY_SEARCH_INTERVAL
local lastCommunitySR = { values = {}, nodes = {}, head = nil, tail = nil, count = 0, max = 1024 }
function lastCommunitySR:Remove(node)
    if not node then return end
    if node.previous then node.previous.next = node.next else self.head = node.next end
    if node.next then node.next.previous = node.previous else self.tail = node.previous end
    self.nodes[node.key] = nil
    self.values[node.key] = nil
    self.count = math.max(0, self.count - 1)
end
function lastCommunitySR:Prune(now, budget)
    local removed = 0
    while self.head and now - self.head.timestamp > COMMUNITY_SR_COOLDOWN
        and removed < math.max(1, math.floor(tonumber(budget) or 1)) do
        self:Remove(self.head)
        removed = removed + 1
    end
end
function lastCommunitySR:Get(key)
    return self.values[key]
end
function lastCommunitySR:Remember(key, now)
    self:Prune(now, 8)
    local node = self.nodes[key]
    if node then
        node.timestamp = now
        self.values[key] = now
        if node ~= self.tail then
            if node.previous then node.previous.next = node.next else self.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = self.tail, nil
            if self.tail then self.tail.next = node end
            self.tail = node
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
local communityCachedScanCursor = 0

-- Retry adaptatif : au login, C_Club.GetSubscribedClubs() n'est pas pret immediatement.
-- On retente toutes les 15s pendant ~2min avant de passer au cooldown normal de 5min.
local COMMUNITY_EARLY_RETRY = 15
local COMMUNITY_MAX_EARLY_RETRIES = 8
local communityEarlyRetries = 0
local communityNotFoundWarned = false

local EK_DEDUP_WINDOW    = 8

-- Dedup croisee K/EK a cout strictement borne. L'ancien sweep des deux tables
-- toutes les 30 s pouvait visiter des dizaines de milliers de cles apres une
-- rafale multi-emetteurs. Une liste TTL ordonnee garde lookup/admission O(1),
-- purge au plus un petit quota, et n'evince jamais une preuve encore valide.
function Overlord.Sync:NewBoundedSessionLedger(maxEntries, reserve, ttl)
    local state = {
        nodes = {}, head = nil, tail = nil, count = 0,
        max = math.max(1, math.floor(tonumber(maxEntries) or 1)),
        reserve = math.max(0, math.floor(tonumber(reserve) or 0)),
        ttl = math.max(0.01, tonumber(ttl) or EK_DEDUP_WINDOW),
        maintenanceVisits = 0,
    }
    function state:Remove(node)
        if not node then return end
        if node.previous then node.previous.next = node.next else self.head = node.next end
        if node.next then node.next.previous = node.previous else self.tail = node.previous end
        self.nodes[node.key] = nil
        self.count = math.max(0, self.count - 1)
        node.previous, node.next = nil, nil
    end
    function state:Prune(now, budget)
        local removed = 0
        local limit = math.max(1, math.floor(tonumber(budget) or 1))
        while self.head and removed < limit do
            self.maintenanceVisits = self.maintenanceVisits + 1
            if now - (tonumber(self.head.timestamp) or 0) < self.ttl then break end
            self:Remove(self.head)
            removed = removed + 1
        end
        return removed
    end
    function state:Get(key, now, maxAge)
        local node = self.nodes[key]
        if not node then return nil end
        if now - (tonumber(node.timestamp) or 0) >= (tonumber(maxAge) or self.ttl) then
            self:Remove(node)
            return nil
        end
        return node.value
    end
    function state:CanRemember(key, now, allowReserve)
        if self.nodes[key] then return true end
        self:Prune(now, 8)
        local limit = self.max + (allowReserve and self.reserve or 0)
        return self.count < limit
    end
    function state:Remember(key, value, now, allowReserve)
        local node = self.nodes[key]
        if node then
            node.timestamp, node.value = now, value
            if node ~= self.tail then
                if node.previous then node.previous.next = node.next else self.head = node.next end
                if node.next then node.next.previous = node.previous end
                node.previous, node.next = self.tail, nil
                if self.tail then self.tail.next = node end
                self.tail = node
            end
            return true
        end
        if not self:CanRemember(key, now, allowReserve) then return false end
        node = { key = key, value = value, timestamp = now, previous = self.tail }
        if self.tail then self.tail.next = node else self.head = node end
        self.tail = node
        self.nodes[key] = node
        self.count = self.count + 1
        return true
    end
    function state:HasAtLeast(now, threshold)
        local count = 0
        local node = self.tail
        while node and now - (tonumber(node.timestamp) or 0) < self.ttl do
            count = count + 1
            if count >= threshold then return true end
            node = node.previous
        end
        return false
    end
    function state:Clear()
        wipe(self.nodes)
        self.head, self.tail, self.count = nil, nil, 0
    end
    return state
end

local recentKCredits = Overlord.Sync:NewBoundedSessionLedger(1024, 64, EK_DEDUP_WINDOW)
local recentEKs = Overlord.Sync:NewBoundedSessionLedger(1024, 0, EK_DEDUP_WINDOW)
priv.zsPayloadDedup = Overlord.Sync:NewBoundedSessionLedger(512, 0, priv.zsPayloadDedupSec)
priv.zaPendingSenderWindows = Overlord.Sync:NewBoundedSessionLedger(512, 0, 30)

-- Compteur de joueurs Overlord actifs a proximite (incremente par chaque message addon recu)
-- Sert a detecter les events massifs SANS raid (80 joueurs sans groupe)
local NEARBY_WINDOW = 60
local LARGE_EVENT_THRESHOLD = 15
local nearbyAddonTimestamps = Overlord.Sync:NewBoundedSessionLedger(576, 0, NEARBY_WINDOW)

-- Joueurs recemment vus en front (emetteurs ZA/ZS/SR) : cibles RG sans whisper hors-zone.
local FRONT_SENDER_TTL = 300
local recentFrontSenders = Overlord.Sync:NewBoundedSessionLedger(512, 64, FRONT_SENDER_TTL)
local lastRGSentWaveAt = 0
local RG_COOLDOWN = 60

-- Cache du resultat IsLargeEvent : evite d'iterer ~200 entries 10-20x/s en 100v100
local cachedIsLarge = false
local cachedIsLargeTime = 0
local IS_LARGE_CACHE_TTL = 2

-- Cache du nom complet du joueur (ne change jamais en session)
local cachedPlayerFullName = nil

local function RecordNearbySender(sender)
    if not sender or sender == "" then return end
    local key = tostring(sender):lower()
    if Overlord.Sync.GetCaptureContributorDedupKey then
        local dedupKey = Overlord.Sync:GetCaptureContributorDedupKey(sender)
        if dedupKey and dedupKey ~= "" then key = dedupKey:lower() end
    end
    local now = GetTime()
    nearbyAddonTimestamps:Remember(key, now, now, false)
end

function Overlord.Sync:Initialize()
    if Overlord.BetaNetwork then Overlord.BetaNetwork:Start() end
    -- Restaure le flag de victoire depuis la DB (TV-2 : evite le re-fire apres /reload).
    -- Si une victoire a eu lieu apres le dernier reset hebdo, la campagne est terminee.
    if OverlordDB then
        local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
        local frontVictory = front and OverlordDB.frontVictories and OverlordDB.frontVictories[front.id]
        local lastVts   = (frontVictory and frontVictory.timestamp) or 0
        local lastReset = OverlordDB.lastResetTimestamp   or 0
        if front and lastVts > 0 and lastVts >= lastReset then
            priv.totalVictoryAnnounced[front.id] = true
        end
        for frontId, victory in pairs(OverlordDB.frontVictories or {}) do
            local victoryTs = math.floor(tonumber(victory and victory.timestamp) or 0)
            if victoryTs > 0 and victoryTs >= lastReset then
                -- Une victoire deja persistee avant ce chargement ne doit pas
                -- refaire apparaitre l'ecran via le replay TV d'une future SR.
                priv.totalVictoryDeliveredAt[frontId] = victoryTs
            end
        end
    end

    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    -- Installer avant le burst login (+0,25 s). Attendre une seconde laissait toutes les
    -- cibles communautaires stale produire le spam Blizzard "No player named ...".
    -- Le helper possede deja son propre retry si ChatFrame n'est pas encore pret.
    if self.InstallWhisperOfflineChatFilter then
        self:InstallWhisperOfflineChatFilter()
    end

    priv.groupSyncStatePrimed = true
    priv.wasGroupedForSync = IsInGroup and IsInGroup() or false
    -- Ne pas ecouter CHAT_MSG_CHANNEL_NOTICE : en arene/BG, ses arguments peuvent
    -- etre proteges/tainted et une simple comparaison Lua peut ouvrir une erreur.
    -- La boucle StartChannelRetryLoop() suffit a rejoindre le canal si necessaire.
    syncFrame:SetScript("OnEvent", function(_, event, ...)
        -- Une entree en instance pendant une migration ferme le transport
        -- immediatement, avant que le pipeline puisse appeler Suspend().
        if Overlord.InstanceSuspended or IsInInstance() then return end
        if event == "CHAT_MSG_ADDON" then
            Overlord.Sync:OnAddonMessage(...)
        elseif event == "BN_CHAT_MSG_ADDON" then
            local prefix, text, _, senderID = ...
            if prefix == PREFIX and text and text ~= "" then
                Overlord.Sync:OnBNetMessage(text, senderID)
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            Overlord.Sync:OnGroupChanged()
        elseif event == "NAME_PLATE_UNIT_ADDED" then
            Overlord.Sync:OnNameplateAdded(...)
        end
    end)
    -- Cold /reload en arene : preparer le protocole mais ne jamais ouvrir ses
    -- handlers avant la sortie autoritaire. Resume() reinstalle les quatre events.
    if not Overlord.InstanceSuspended and not IsInInstance() then
        syncFrame:RegisterEvent("CHAT_MSG_ADDON")
        syncFrame:RegisterEvent("BN_CHAT_MSG_ADDON")
        syncFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
        syncFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    end
    -- Preparer hors handler le ledger WB persistant. Une ancienne table volumineuse
    -- est nettoyee par tranches; les paquets restent fail-closed jusqu'au commit.
    if self.EnsureDominationBoostEventLedgerPrepared then
        self:EnsureDominationBoostEventLedgerPrepared()
    end
end

-- Rejoint le canal Overlord (avec retry exponentiel, max 4 tentatives)
-- Au succes : envoie un SR immediat + 2 SR différés (15s, 35s) pour maximiser les chances d'avoir une reponse
-- frameID = 0 : canal invisible (pas attache a un onglet chat), sync uniquement via addon messages
function Overlord.Sync:JoinChannel(attempt, generation)
    if not SYNC_USE_REALM_CHANNEL then return end
    attempt = attempt or 1
    if not generation then
        local existingId = GetChannelName(CHANNEL_NAME)
        if existingId and existingId > 0 then return end
        -- Core, Resume et le ticker peuvent tous demander un join au meme moment.
        -- Une seule chaine possede les retries et les SR +15/+35.
        if self._joinChannelAttemptPending then return end
        self._joinChannelGeneration = (tonumber(self._joinChannelGeneration) or 0) + 1
        generation = self._joinChannelGeneration
        self._joinChannelAttemptPending = generation
    elseif self._joinChannelAttemptPending ~= generation then
        return
    end

    local function FinishJoinAttempt()
        if self._joinChannelAttemptPending == generation then
            self._joinChannelAttemptPending = nil
        end
    end
    if attempt > 4 then
        FinishJoinAttempt()
        return
    end
    -- Anti vol du slot /1 : au login, les canaux serveur (Général...) arrivent quelques
    -- secondes apres PLAYER_ENTERING_WORLD. Si on rejoint avant, le canal Overlord prend
    -- le /1 et Général passe en /2 a chaque session (signalement joueur). On differe tant
    -- que le slot 1 est vide, max ~30 s : un joueur qui a quitté tous les canaux serveur
    -- garde un slot 1 vide en permanence et la sync ne doit jamais rester bloquee pour ça.
    if attempt == 1 then
        local deferCount = self._joinChannelDeferCount or 0
        local slot1 = GetChannelName(1)
        if (not slot1 or slot1 == 0) and deferCount < 15 then
            self._joinChannelDeferCount = deferCount + 1
            C_Timer.After(2, function()
                if Overlord.Sync._joinChannelAttemptPending ~= generation then return end
                if Overlord.InstanceSuspended then
                    FinishJoinAttempt()
                    return
                end
                Overlord.Sync:JoinChannel(1, generation)
            end)
            return
        end
        self._joinChannelDeferCount = 0
    end
    -- frameID 0 = canal invisible (les joueurs ne voient pas le canal dans leur chat)
    -- WoW 12.0.5 : securecall pour ne pas taint le systeme de chat
    securecall(JoinChannelByName, CHANNEL_NAME, nil, 0, 0)
    C_Timer.After(3 * attempt, function()
        if Overlord.Sync._joinChannelAttemptPending ~= generation then return end
        if Overlord.InstanceSuspended then
            FinishJoinAttempt()
            return
        end
        local id = GetChannelName(CHANNEL_NAME)
        if id and id > 0 then
            FinishJoinAttempt()
            Overlord.Sync:SendSyncRequest()
            Overlord.Sync:BroadcastST()
            -- Relances SR a 15s et 35s pour les late-joiners (au cas ou personne ne repond au premier)
            C_Timer.After(15, function()
                if Overlord.InstanceSuspended
                    or Overlord.Sync._joinChannelGeneration ~= generation then return end
                if Overlord.Sync:GetChannelId() then Overlord.Sync:SendSyncRequest() end
            end)
            C_Timer.After(35, function()
                if Overlord.InstanceSuspended
                    or Overlord.Sync._joinChannelGeneration ~= generation then return end
                if Overlord.Sync:GetChannelId() then Overlord.Sync:SendSyncRequest() end
            end)
        else
            Overlord.Sync:JoinChannel(attempt + 1, generation)
        end
    end)
end

-- Relance periodique du join canal (toutes les 60s) si on n'est pas dedans (evite de rester desync si le join a rate au chargement)
local channelRetryTicker = nil
function Overlord.Sync:StartChannelRetryLoop()
    if not SYNC_USE_REALM_CHANNEL then return end
    if channelRetryTicker then channelRetryTicker:Cancel() end
    channelRetryTicker = C_Timer.NewTicker(60, function()
        if not Overlord.IsInitialized then return end
        if Overlord.Sync:GetChannelId() then return end
        Overlord.Sync:JoinChannel(1)
    end)
end

function Overlord.Sync:StopChannelRetryLoop()
    if channelRetryTicker then
        channelRetryTicker:Cancel()
        channelRetryTicker = nil
    end
end

-- Cooldown global BNet SR : evite d'envoyer 50 msgs BNet en 35s a l'init
-- (JoinChannel retry + ticker + StartPeriodicChannelSync = 5 vagues de 10 msgs)
local lastBNetSRBroadcast = 0
local BNET_SR_COOLDOWN = 25
local BNET_SR_COOLDOWN_LARGE = 120

-- Envoi centralise d'une Sync Request (evite duplication dans JoinChannel, OnGroupChanged, etc.)
-- Utilise les bridges si pas de lien BNet direct vers la faction adverse (cross-server cross-faction)
function Overlord.Sync:SendSyncRequest(opts)
    opts = opts or {}
    -- Une demande automatique ne doit jamais faire trier/reconstruire le classement
    -- entier chez chaque receveur. Le mode complet est reserve aux actions explicites
    -- et ne sera de toute facon honore qu'en whisper/BNet par OnSyncRequest.
    local requestMode = opts.fullResponse == true and "F"
        or (opts.stateResponse == true and "S") or "T"
    local payload = SRPayload(requestMode)
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        if opts.betaTarget then
            local sent = Overlord.BetaNetwork:Send("SR", payload, opts.betaTarget)
            if sent and requestMode == "F" then
                self:ExpectDirectFullLeaderboardResponse(opts.betaTarget)
            end
            return sent
        end
        Overlord.BetaNetwork:Broadcast("SR", payload)
    end
    -- Une SR locale partagee remplit deja le role de la prochaine vague periodique.
    -- La noter avant les transports evite qu'un ticker decale de quelques secondes
    -- emette la meme demande une seconde fois.
    if Overlord.InActiveFront and not opts.targetedCommunityOnly then
        self._lastActivePeriodicSrAt = GetTime()
    end
    if not opts.targetedCommunityOnly then
        self:Send("SR", payload)
        if SYNC_USE_REALM_CHANNEL and (IsInRaid() or IsInGroup()) and self:GetChannelId() then
            self:SendToChannel("SR", payload, opts.criticalChannel == true)
        end
    end
    -- /ov sync doit atteindre la communaute Overlord : c'est le chemin fiable
    -- pour les joueurs cross-faction/cross-realm. Les vagues periodiques territoriales
    -- peuvent l'autoriser explicitement en gros event avec un nombre de cibles borne.
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local forceCommunity = opts.includeCommunity == true
    if self.BroadcastToCommunity
        and (Overlord.InActiveFront or forceCommunity)
        and (not isLarge or opts.allowCommunityInLargeEvent) then
        self:BroadcastToCommunity(
            "SR",
            payload,
            opts.communityMax or 12,
            opts.communityDelay or 0.35,
            opts.forceCommunityTargets == true,
            nil,
            opts.communityRosterMinTtl)
    end
    if not opts.targetedCommunityOnly
        and SYNC_USE_BNET_OUTBOUND and Overlord.InActiveFront then
        local now = GetTime()
        local bnetSRCooldown = self:IsLargeEvent() and BNET_SR_COOLDOWN_LARGE or BNET_SR_COOLDOWN
        if now - lastBNetSRBroadcast >= bnetSRCooldown then
            lastBNetSRBroadcast = now
            self:SendToBNetFriends("SR", payload)
        end
        if not self:HasDirectBNetToEnemyFaction() then
            local bridge, targetBand = self:FindBridgeForEnemyFaction()
            if bridge and targetBand then
                local replyTo = self:GetPlayerFullName()
                local relayPayload = "SR:" .. payload
                self:SendWhisper("R1", targetBand .. ":" .. replyTo .. ":" .. relayPayload, bridge)
            end
        end
    end
end

-- Au /reload, le premier SR partait souvent avant que le canal de royaume ou
-- C_Club soit pret. Le fan-out fiable n'arrivait alors qu'au timeout de 45 s.
-- Ces essais courts couvrent le chargement progressif des transports ;
-- le dedup communautaire evite de re-whisper les memes joueurs.
function Overlord.Sync:StartLoginCaptureSyncBurst()
    self._loginCaptureSyncBurstGeneration =
        (tonumber(self._loginCaptureSyncBurstGeneration) or 0) + 1
    local generation = self._loginCaptureSyncBurstGeneration
    local delays = { 0.25, 2.5, 6.5, 12.0 }
    for attempt, delay in ipairs(delays) do
        C_Timer.After(delay, function()
            if not Overlord.Sync
                or Overlord.Sync._loginCaptureSyncBurstGeneration ~= generation
                or Overlord.InstanceSuspended or IsInInstance() then return end
            if Overlord.IsLoginCaptureSyncGateActive
                and not Overlord:IsLoginCaptureSyncGateActive() then return end
            -- C_Club peut exposer le club avant ses streams/membres. Une liste
            -- vide lue au premier essai ne doit jamais condamner tout le burst
            -- via le cache roster (cas observe : carte entierement en SYNC).
            if Overlord.Sync.InvalidateOnlineMembersCache
                and (attempt == 1
                    or not Overlord.Sync.HasUsableOnlineMembersCache
                    or not Overlord.Sync:HasUsableOnlineMembersCache()) then
                Overlord.Sync:InvalidateOnlineMembersCache()
            end
            Overlord.Sync:SendSyncRequest({
                includeCommunity = true,
                allowCommunityInLargeEvent = true,
                criticalChannel = true,
                -- La gate login ne demande que la carte. Une reponse ladder complete
                -- multiplie les copies/tri O(N) lors des reloads collectifs.
                territorialOnly = true,
                communityMax = 12,
                communityDelay = (attempt == 1) and 0.12 or 0.2,
            })
            if attempt == #delays and Overlord.Sync.SendLoginCatchupSyncToCommunity
                and Overlord:IsLoginCaptureSyncGateActive() then
                -- Dernier filet petit-comite : au dernier essai, recontacter chaque membre
                -- en ligne plutot que d'attendre le rattrapage historique a 45 s.
                Overlord.Sync:SendLoginCatchupSyncToCommunity()
            end
        end)
    end
    -- La gate cartographique et le filet communautaire ont des contrats distincts.
    -- Une premiere SR:T peut fermer ZA en moins d'une seconde ; elle ne doit pas annuler
    -- l'unique relance cross-realm du login hors front. Cette vague territoriale est ciblee
    -- vers un seul membre communaute, repartie par le curseur local, et reste donc bornee
    -- lors des /reload collectifs. En front, OnEnterFront lance deja ScanCommunityMembers(true).
    C_Timer.After(16 + math.random() * 4, function()
        if not Overlord.Sync
            or Overlord.Sync._loginCaptureSyncBurstGeneration ~= generation
            or Overlord.InstanceSuspended or IsInInstance()
            or Overlord.InActiveFront then return end
        Overlord.Sync:SendSyncRequest({
            includeCommunity = true,
            allowCommunityInLargeEvent = true,
            targetedCommunityOnly = true,
            forceCommunityTargets = true,
            communityMax = 1,
            communityDelay = 0.2,
        })
    end)
    -- Une campagne deja alimentee converge par K/LK/LC sans aucun travail global.
    -- Le seul cas dormant (client neuf, campagne vide) recoit plus tard UNE SR:F
    -- directe, bornee et persistante ; jamais de F sur groupe/canal/communaute.
    if self.ScheduleLoginLeaderboardHistoryCatchUp then
        self:ScheduleLoginLeaderboardHistoryCatchUp()
    end
end

-- A la sortie d'instance, le premier pair joignable est souvent un membre du
-- groupe qui possede exactement la meme vieille carte. Cette reponse peut fermer
-- la gate, mais ne doit pas annuler les essais suivants vers le canal/club : la
-- capture et le TV reels ont eu lieu pendant que CHAT_MSG_ADDON etait suspendu.
function Overlord.Sync:StartInstanceCaptureSyncBurst()
    self._instanceCaptureSyncBurstGeneration =
        (tonumber(self._instanceCaptureSyncBurstGeneration) or 0) + 1
    local generation = self._instanceCaptureSyncBurstGeneration
    local delays = { 0.25, 2.5, 6.5, 12.0 }
    self._instanceCaptureSyncBurstUntil = GetTime() + 18
    -- Une seule invalidation suffit : le premier BroadcastToCommunity reconstruit
    -- le roster, puis les essais suivants reutilisent ce cache pendant le burst.
    -- Scanner C_Club a chaque callback provoquait cinq parcours synchrones du club.
    if self.InvalidateOnlineMembersCache then
        self:InvalidateOnlineMembersCache()
    end
    for attempt, delay in ipairs(delays) do
        C_Timer.After(delay, function()
            if not Overlord.Sync
                or Overlord.Sync._instanceCaptureSyncBurstGeneration ~= generation
                or Overlord.InstanceSuspended or IsInInstance() then return end
            Overlord.Sync:SendSyncRequest({
                includeCommunity = true,
                allowCommunityInLargeEvent = true,
                criticalChannel = true,
                territorialOnly = true,
                targetedCommunityOnly = true,
                communityMax = (attempt == 1) and 3 or 1,
                communityRosterMinTtl = 18,
                communityDelay = (attempt == 1) and 0.12 or 0.2,
            })
        end)
    end
end

-- SR legere quand on consulte un front inactif (carte monde ou onglet panneau).
-- Canal/groupe seulement : pas de burst communaute/BNet (cf. SendSyncRequest).
local CONSULT_FRONT_SR_COOLDOWN = 60
local lastConsultFrontSR = {}

function Overlord.Sync:RequestConsultFrontSync(frontId)
    if not frontId or type(frontId) ~= "string" or frontId == "" then return end
    if Overlord.InstanceSuspended then return end
    if Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()) then
        return
    end
    if self.IsLargeEvent and self:IsLargeEvent() then return end
    local activeId = Overlord.Fronts and Overlord.Fronts.activeFrontId
    if activeId and frontId == activeId then return end
    local now = GetTime()
    local last = lastConsultFrontSR[frontId] or 0
    if now - last < CONSULT_FRONT_SR_COOLDOWN then return end
    lastConsultFrontSR[frontId] = now
    local payload = SRPayload("T")
    self:Send("SR", payload)
    if SYNC_USE_REALM_CHANNEL and (IsInRaid() or IsInGroup()) then
        self:SendToChannel("SR", payload)
    end
end

local lastEnemyBridgeRelay = {}
local ENEMY_BRIDGE_RELAY_INTERVAL = 4
local ENEMY_BRIDGE_RELAY_TTL = 90
local lastEnemyBridgeRelayPurge = 0

function Overlord.Sync:RelayToEnemyBridge(msgType, payload)
    -- Les etats qui exigent une identite gameplay (C/ZS) sont interdits ici.
    -- TV reste sans autorite propre : son receveur exige une preuve locale independante.
    if msgType ~= "TV" or not SYNC_USE_BNET_OUTBOUND
        or not Overlord.InActiveFront or not payload then return end
    local key = msgType .. ":" .. payload
    local now = GetTime()
    if now - lastEnemyBridgeRelayPurge > 30 then
        lastEnemyBridgeRelayPurge = now
        for k, ts in pairs(lastEnemyBridgeRelay) do
            if now - ts > ENEMY_BRIDGE_RELAY_TTL then
                lastEnemyBridgeRelay[k] = nil
            end
        end
    end
    local last = lastEnemyBridgeRelay[key]
    if last and now - last < ENEMY_BRIDGE_RELAY_INTERVAL then return end
    lastEnemyBridgeRelay[key] = now
    if self:HasDirectBNetToEnemyFaction() then return end
    local bridge, targetBand = self:FindBridgeForEnemyFaction()
    if not bridge or not targetBand then return end
    local replyTo = self:GetPlayerFullName()
    if not replyTo then return end
    self:SendWhisper("R1", targetBand .. ":" .. replyTo .. ":" .. msgType .. ":" .. payload, bridge)
end

-- Retourne le canal prioritaire : groupe (cross-realm) > channel (realm uniquement)
function Overlord.Sync:GetChannelId()
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then return id end
    return nil
end

-- Forever : base Prenom Nom. Un suffixe -Royaume d'API est ignore, jamais recolle.
function Overlord.Sync:ForeverCharacterBase(name)
    name = self:NormalizeContributorFullName(name) or name
    if type(name) ~= "string" then return nil end
    name = name:match("^%s*(.-)%s*$") or ""
    if name == "" or #name > 80 then return nil end
    local hyphen = name:find("-", 1, true)
    local base = hyphen and name:sub(1, hyphen - 1) or name
    base = (base:match("^%s*(.-)%s*$") or ""):gsub("%s+", " ")
    if base == "" then return nil end
    return base
end

-- Identite canonique Forever : "Prenom Nom". Nil si le nom n'est pas complet.
function Overlord.Sync:CanonicalForeverName(name)
    local base = self:ForeverCharacterBase(name)
    if not base or not self:IsForeverCharacterName(base) then return nil end
    return base
end

function Overlord.Sync:CanonicalForeverNameFromUnit(unit)
    if not unit then return nil end
    local name = Overlord:SafeGetUnitName(unit, true) or Overlord:SafeUnitName(unit)
    return self:CanonicalForeverName(name)
end

function Overlord.Sync:GetPlayerFullName()
    if cachedPlayerFullName then return cachedPlayerFullName end
    local name = Overlord:SafeUnitName("player")
    if not name or name == "" then return "" end
    local canon = self:CanonicalForeverName(name)
    if not canon then return "" end
    cachedPlayerFullName = canon
    return canon
end

-- Forever : Prenom Nom uniquement. Un token unique ou un Nom-Royaume Retail est refuse.
function Overlord.Sync:IsValidPlayerName(name)
    return self:IsForeverCharacterName(name)
end

-- Forever : identite personnage = Prenom Nom (un seul espace).
-- Un -Royaume eventuel (API) est ignore, il ne fait pas partie de l'identite.
function Overlord.Sync:IsForeverCharacterName(name)
    if type(name) ~= "string" then return false end
    name = self:NormalizeContributorFullName(name) or name
    if type(name) ~= "string" or name == "" or #name > 80 then return false end
    if name ~= (name:match("^%s*(.-)%s*$") or "") then return false end
    if name:find("[%c|:]") then return false end
    local hyphen = name:find("-", 1, true)
    if hyphen and (hyphen == 1 or hyphen == #name
        or name:find("-", hyphen + 1, true)) then return false end
    local base = hyphen and name:sub(1, hyphen - 1) or name
    base = (base:match("^%s*(.-)%s*$") or ""):gsub("%s+", " ")
    local given, family = base:match("^([^%s]+)%s([^%s]+)$")
    if not given or not family then return false end
    if not self:IsValidPlayerNameSegment(given, 24, false)
        or not self:IsValidPlayerNameSegment(family, 24, false) then
        return false
    end
    local lower = given:lower()
    if lower == "unknown" or lower == "inconnu" or lower == "unbekannt"
       or lower == "desconocido" or lower == "desconhecido" then
        return false
    end
    return true
end

-- Valide un segment UTF-8 sans dependre des classes de caracteres de Lua 5.1,
-- qui ne reconnaissent que l'ASCII. Les caracteres ASCII sont volontairement
-- limites aux lettres/apostrophe (et aux chiffres dans le royaume) ; les suites UTF-8 surlongues,
-- tronquees et les surrogate code points sont refusees.
function Overlord.Sync:IsValidPlayerNameSegment(segment, maxBytes, allowDigits)
    if type(segment) ~= "string" or segment == ""
        or #segment > math.floor(tonumber(maxBytes) or 64) then return false end
    local i, length = 1, #segment
    while i <= length do
        local b1 = string.byte(segment, i)
        if b1 < 128 then
            local asciiAllowed = (b1 >= 65 and b1 <= 90)
                or (b1 >= 97 and b1 <= 122)
                or (allowDigits == true and b1 >= 48 and b1 <= 57) or b1 == 39
            if not asciiAllowed then return false end
            i = i + 1
        else
            local needed, b2Min, b2Max = 0, 128, 191
            if b1 >= 194 and b1 <= 223 then
                needed = 1
            elseif b1 >= 224 and b1 <= 239 then
                needed = 2
                if b1 == 224 then b2Min = 160 end
                if b1 == 237 then b2Max = 159 end
            elseif b1 >= 240 and b1 <= 244 then
                needed = 3
                if b1 == 240 then b2Min = 144 end
                if b1 == 244 then b2Max = 143 end
            else
                return false
            end
            if i + needed > length then return false end
            local b2 = string.byte(segment, i + 1)
            if b2 < b2Min or b2 > b2Max then return false end
            for offset = 2, needed do
                local continuation = string.byte(segment, i + offset)
                if continuation < 128 or continuation > 191 then return false end
            end
            i = i + needed + 1
        end
    end
    local first, last = string.byte(segment, 1), string.byte(segment, #segment)
    if (first >= 48 and first <= 57) or first == 39 or last == 39 then return false end
    return true
end

-- Cible whisper addon (communaute / SR / bridge) : refuse le bruit API Club ou fragments de payload.
function Overlord.Sync:IsValidWhisperTarget(target)
    if type(target) ~= "string" then return false end
    target = target:match("^%s*(.-)%s*$") or ""
    if target == "" or #target < 2 or #target > 50 then return false end
    if not self:IsValidPlayerName(target) then return false end
    if target:find("[%(%)%[%]{}|:<>=\"`~!@#$%%^&*]", 1) then return false end
    return true
end

-- Identite complete Forever : Prenom Nom.
function Overlord.Sync:HasCompleteContributorIdentity(name)
    return self:CanonicalForeverName(name) ~= nil
end

-- Accepte un nom sync distant uniquement s'il est un Prenom Nom Forever.
function Overlord.Sync:AcceptSyncedContributorName(name)
    return self:HasCompleteContributorIdentity(name)
end

-- Lookup strictement O(1). Ne jamais appeler ici EnsureDedupMetaIndex ni les
-- getters de max : la premiere ligne d'un flood ne doit pas construire un
-- index ou scanner tout le classement dans la frame reseau.
function Overlord.Sync:IsKnownLeaderboardSubject(playerName)
    if not self:IsValidPlayerName(playerName) then return false end
    local lb = Overlord.Leaderboard
    if not lb then return false end
    if (type(lb.kills) == "table" and lb.kills[playerName] ~= nil)
        or (type(lb.captureCount) == "table" and lb.captureCount[playerName] ~= nil)
        or (type(lb.captures) == "table" and lb.captures[playerName] ~= nil)
        or (type(lb.playerInfo) == "table" and lb.playerInfo[playerName] ~= nil) then
        return true
    end
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(playerName) or playerName:lower()
    local index = lb._dedupMetaIndex
    return type(index) == "table" and key and index[key:lower()] ~= nil or false
end

function Overlord.Sync:ExpectedFullLeaderboardResponseKey(target)
    if not self:IsValidPlayerName(target) then return nil end
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(target) or target:lower()
    return key and key:lower() or nil
end

-- Arme le contexte uniquement APRES qu'un SR:F direct a effectivement ete
-- mis en file. 50 LK + 20 LC + 30 LR correspondent aux maxima du repondeur.
function Overlord.Sync:ExpectDirectFullLeaderboardResponse(target)
    local key = self:ExpectedFullLeaderboardResponseKey(target)
    if not key or key == "" then return false end
    local now = GetTime()
    local expected = priv.expectedFullLeaderboardResponses
    local oldestKey, oldestOrder, oldestExpiry, count = nil, nil, nil, 0
    for candidate, state in pairs(expected) do
        local expiresAt = tonumber(state and state.expiresAt) or 0
        if expiresAt <= now then
            expected[candidate] = nil
        else
            count = count + 1
            local order = math.floor(tonumber(state and state.order) or 0)
            if not oldestOrder or order < oldestOrder
                or (order == oldestOrder and expiresAt < oldestExpiry) then
                oldestKey, oldestOrder, oldestExpiry = candidate, order, expiresAt
            end
        end
    end
    local replacing = expected[key] ~= nil
    if not replacing and count >= 16 and oldestKey then
        expected[oldestKey] = nil
        count = count - 1
    end
    -- Couvre le watchdog et le pire backlog secondaire qui precede LK/LR/LC
    -- en gros event, sans survivre au prochain cycle de rattrapage.
    priv.expectedFullLeaderboardResponseSerial =
        math.floor(tonumber(priv.expectedFullLeaderboardResponseSerial) or 0) + 1
    expected[key] = {
        expiresAt = now + 300,
        order = priv.expectedFullLeaderboardResponseSerial,
        LK = 50, LC = 20, LR = 30, total = 100,
    }
    return true
end

function Overlord.Sync:ConsumeExpectedFullLeaderboardResponse(msgType, sender, channel)
    if channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsDispatching(sender)
        and Overlord.BetaNetwork:IsTargetedDispatch() then channel = "WHISPER" end
    if channel ~= "WHISPER" or (msgType ~= "LK" and msgType ~= "LC" and msgType ~= "LR") then
        return false
    end
    local key = self:ExpectedFullLeaderboardResponseKey(sender)
    local expected = key and priv.expectedFullLeaderboardResponses[key] or nil
    local now = GetTime()
    if not expected or now > (tonumber(expected.expiresAt) or 0) then
        if key and expected then
            priv.expectedFullLeaderboardResponses[key] = nil
        end
        return false
    end
    local remaining = math.floor(tonumber(expected[msgType]) or 0)
    local total = math.floor(tonumber(expected.total) or 0)
    if remaining <= 0 or total <= 0 then return false end
    expected[msgType] = remaining - 1
    expected.total = total - 1
    if expected.total <= 0 then
        priv.expectedFullLeaderboardResponses[key] = nil
    end
    return true
end

-- Une nouvelle cle distante n'est admise que si elle appartient a l'emetteur
-- authentifie par WoW, ou si elle arrive dans une reponse directe explicitement
-- attendue (HR v3 ou SR:F legacy). Les mises a jour des cles deja connues
-- restent monotones et ne consomment aucun budget.
function Overlord.Sync:AuthorizeLeaderboardSubject(msgType, playerName, sender, channel)
    if not self:IsValidPlayerName(playerName) then return false, "invalid-subject" end
    if self:IsKnownLeaderboardSubject(playerName) then return true, "known" end
    if self.KillSyncSenderOwnsPlayer
        and self:KillSyncSenderOwnsPlayer(sender, playerName) then return true, "owner" end
    if self.IsExpectedHistoryCatchupDelivery
        and self:IsExpectedHistoryCatchupDelivery(msgType, sender, channel) then
        return true, "history"
    end
    if self:ConsumeExpectedFullLeaderboardResponse(msgType, sender, channel) then
        return true, "full"
    end
    return false, "untrusted-new-subject"
end

-- Une file SR:F peut recevoir son bloc classement apres le demarrage du pump,
-- lorsque le snapshot tranche est pret. Ne jamais avancer l'index pendant cette
-- attente : sinon le ticker depasserait #queue et fermerait la reponse avant le callback.
function Overlord.Sync:NextPreparedSrResponseItem(state, now)
    if type(state) ~= "table" or type(state.queue) ~= "table" then return nil, true end
    if state.finished == true then return nil, true end
    local nextIndex = math.floor(tonumber(state.queueIndex) or 0) + 1
    local item = state.queue[nextIndex]
    if item then
        state.queueIndex = nextIndex
        return item, false
    end
    local deadline = tonumber(state.preparationDeadline) or 0
    if state.preparingLadder == true and (tonumber(now) or GetTime()) <= deadline then
        return nil, false
    end
    return nil, true
end

-- Retire un suffixe "|CLASSE" colle au nom (format message C mal absorbe en cle SavedVariables).
-- Sinon cle "Nom-Royaume|WARRIOR" != "Nom-Royaume" et l'export Check PvP remplace | par "_" (lignes grises).
function Overlord.Sync:StripPipeLeakFromContributorName(name)
    if type(name) ~= "string" then return name end
    name = name:match("^%s*(.-)%s*$") or name
    local p = name:find("|", 1, true)
    if p then
        name = name:sub(1, p - 1):match("^%s*(.-)%s*$") or name:sub(1, p - 1)
    end
    return name
end

-- Forme canonique pour comparaisons Nom-Royaume (import / SV vs GetUnitName en jeu).
-- Apostrophe typographique (Vol'jin) et tirets Unicode cassaient ResolveContributorClassToken.
function Overlord.Sync:NormalizeContributorFullName(name)
    if type(name) ~= "string" then return name end
    name = self:StripPipeLeakFromContributorName(name)
    if not name or name == "" then return name end
    name = name:gsub("\226\128\152", "'"):gsub("\226\128\153", "'")
        :gsub("\226\128\147", "-"):gsub("\226\128\148", "-"):gsub("\194\173", "-")
    return name
end

-- Cle stable Forever : "prenom nom". Jamais de -Royaume.
function Overlord.Sync:GetCaptureContributorDedupKey(name)
    local canon = self:CanonicalForeverName(name)
    if not canon then return nil end
    return canon:lower()
end

-- True si l'expediteur addon designe le joueur local (formats Nom vs Nom-Royaume du canal).
function Overlord.Sync:IsSenderLocalPlayer(sender)
    if not sender or sender == "" then return false end
    if sender:sub(1, 5) == "BNet-" then return false end
    -- WoW 12.0.5 : SafeStringEquals pour comparer avec les noms potentiellement secrets
    local myFullName = self:GetPlayerFullName()
    local myShortName = Overlord:SafeUnitName("player")
    if Overlord:SafeStringEquals(sender, myFullName) or Overlord:SafeStringEquals(sender, myShortName) then
        return true
    end
    local sk = self:GetCaptureContributorDedupKey(sender)
    local mk = self:GetCaptureContributorDedupKey(myFullName)
    if sk ~= nil and mk ~= nil and Overlord:SafeStringEquals(sk, mk) then
        return true
    end
    return self.ForeverIdentitiesMatch and self:ForeverIdentitiesMatch(sender, myFullName)
        or false
end

-- Forever : un seul monde, pas de royaume. Band = faction pour le routage BNet.
function Overlord.Sync:GetMyBand()
    local faction = Overlord.PlayerFaction or ""
    local fc = (faction == "Horde") and "H" or "A"
    return "Forever_" .. Overlord.RealmPools:GetOverlordPoolTag() .. "_" .. fc
end

local function IsCompatibleForeverBand(band)
    if type(band) ~= "string" then return false end
    local pool, faction = band:match("^Forever_([a-z]+)_([AH])$")
    if not pool or not faction then return false end
    return Overlord.RealmPools:NormalizeRegionPool(pool)
        == Overlord.RealmPools:GetOverlordPoolTag()
end

-- Verifie si on a un lien BNet direct vers la faction adverse (amis BNet de l'autre faction)
function Overlord.Sync:HasDirectBNetToEnemyFaction()
    for _, band in pairs(bnet_links) do
        if band:match("_H$") and Overlord.PlayerFaction == "Alliance" then return true end
        if band:match("_A$") and Overlord.PlayerFaction == "Horde" then return true end
    end
    return false
end

-- Trouve un bridge disponible pour atteindre une band ennemie (faction adverse)
function Overlord.Sync:FindBridgeForEnemyFaction()
    local now = GetTime()
    local wantH = (Overlord.PlayerFaction == "Alliance")
    for fullname, data in pairs(bridges.values) do
        if now - data.time < BRIDGE_EXPIRE then
            for _, b in ipairs(data.bands or {}) do
                if (wantH and b:match("_H$")) or (not wantH and b:match("_A$")) then
                    return fullname, b
                end
            end
        end
    end
    return nil, nil
end

-- ==================== Decouverte via Communaute ====================

-- Trouve la communaute "Overlord" parmi les clubs Character souscrits (cache le resultat).
-- Re-cherche toutes les 5 min si pas trouvee (le joueur peut rejoindre en cours de session).
-- Liens d'invitation par pool (table ordonnee : dernier = shard overflow si cap Blizzard 1000).
local COMMUNITY_INVITES = {
    global = { "0m7kdXcnvR" },
}

-- Forever beta has one global population, including US and EU players.
local function GetPlayerRegion()
    local rp = Overlord.RealmPools
    if rp and rp.GetOverlordPoolTag then
        return rp:GetOverlordPoolTag() or "global"
    end
    return "global"
end

-- Compatibilite des appels historiques : Forever ne classe pas les royaumes RP.
function Overlord.Sync:IsRPRealm()
    return false
end

-- Horodatage du dernier envoi RG (au moins un whisper) : auto-accept groupe cote demandeur RP.
Overlord.Sync.lastRGSentAt = 0

function Overlord.Sync:ClearRecentFrontSenders()
    recentFrontSenders:Clear()
end

-- Verifie si un joueur figure dans le cache des emetteurs front recents (utilise par PARTY_INVITE_REQUEST)
function Overlord.Sync:IsRecentFrontSender(name)
    if not name or name == "" then return false end
    return recentFrontSenders:Get(name, GetTime()) ~= nil
end

local function RecordRecentFrontSender(sender)
    if not sender or sender == "" then return end
    if sender:find("^BNet%-", 1) then return end
    if Overlord.Sync.IsValidWhisperTarget and not Overlord.Sync:IsValidWhisperTarget(sender) then return end
    local now = GetTime()
    local groupReserve = Overlord.Sync.SenderIsInOurGroup
        and Overlord.Sync:SenderIsInOurGroup(sender) or false
    recentFrontSenders:Remember(sender, now, now, groupReserve)
end

-- Demande de groupe vers des joueurs ayant emis ZA/ZS/SR recemment.
function Overlord.Sync:BroadcastRPGroupRequest()
    local now = GetTime()
    local myName = self:GetPlayerFullName()
    if not myName or myName == "" then return end
    recentFrontSenders:Prune(now, 8)
    local targets, node, visited = {}, recentFrontSenders.tail, 0
    while node and #targets < 3 and visited < 8 do
        visited = visited + 1
        if now - (tonumber(node.timestamp) or 0) >= FRONT_SENDER_TTL then break end
        if node.key ~= myName then targets[#targets + 1] = node.key end
        node = node.previous
    end
    if #targets == 0 then return end
    if lastRGSentWaveAt > 0 and (now - lastRGSentWaveAt < RG_COOLDOWN) then return end
    lastRGSentWaveAt = now
    self.lastRGSentAt = now
    for i = 1, math.min(3, #targets) do
        self:SendWhisper("RG", myName, targets[i])
    end
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L and L.RP_GROUP_REQUEST_SENT or "RP group request sent."))
end

local function SyncCanInviteForRG()
    if not IsInGroup() then return true end
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then return n < 40 end
    return n < 5
end

local function OnReceiveRG(payload, sender)
    if not Overlord.InActiveFront or Overlord:IsInCatchUpPhase() then return end
    if not SyncCanInviteForRG() then return end
    local requester = (payload or ""):match("^%s*(.-)%s*$") or ""
    if requester == "" then return end
    -- Securite : le payload doit etre le nom du sender lui-meme (evite les RG forges)
    if requester ~= sender then return end
    C_Timer.After(0.5, function()
        if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
        pcall(InviteUnit, requester)
    end)
end

-- Pool FR/DE : royaume EU francophone / germanophone (cf. RealmPools.lua). Pas la locale client.
local function IsLocaleInFRPool()
    local rp = Overlord.RealmPools
    return rp and rp.GetOverlordPoolTag and rp:GetOverlordPoolTag() == "fr"
end

local function IsLocaleInDEPool()
    local rp = Overlord.RealmPools
    return rp and rp.GetOverlordPoolTag and rp:GetOverlordPoolTag() == "de"
end

local function GetCommunityPoolTag()
    local rp = Overlord.RealmPools
    if rp and rp.GetOverlordPoolTag then
        local tag = rp:GetOverlordPoolTag()
        if tag then return tag end
    end
    return GetPlayerRegion()
end

function Overlord.Sync:GetCommunityPoolTag()
    return GetCommunityPoolTag()
end

local function GetCommunityInviteListForPool()
    return COMMUNITY_INVITES.global
end

local function ClearCommunityClubCache()
    wipe(communityClubIds)
    wipe(europeanLeaderboardBridgeClubIds)
    communityClubId = nil
    local sync = Overlord.Sync
    if sync then
        sync._communityClubEmptyScans = 0
        if sync.InvalidateOnlineMembersCache then
            sync:InvalidateOnlineMembersCache()
        end
        if sync.InvalidateCommunityMemberCharactersCache then
            sync:InvalidateCommunityMemberCharactersCache()
        end
        if sync.InvalidateEuropeanLeaderboardBridgeMembersCache then
            sync:InvalidateEuropeanLeaderboardBridgeMembersCache(true)
        end
    end
end

-- C_Club retourne parfois une liste vide pendant un refresh interne. Tant qu'un
-- club Overlord est deja connu, trois lectures forcees sont requises avant de
-- publier une perte d'adhesion. Les deux confirmations sont ponctuelles : aucun
-- polling permanent et aucun roster lourd dans le chemin UI.
function Overlord.Sync:HandleCommunityClubSearchMiss(preserveCache)
    if not communityClubId and #communityClubIds == 0 then return nil end
    if preserveCache then return nil end
    self._communityClubEmptyScans =
        math.floor(tonumber(self._communityClubEmptyScans) or 0) + 1
    if self._communityClubEmptyScans < 3 then
        if not self._communityClubLossProbeScheduled and C_Timer and C_Timer.After then
            self._communityClubLossProbeScheduled = true
            C_Timer.After(2, function()
                local current = Overlord.Sync
                if not current then return end
                current._communityClubLossProbeScheduled = false
                current:FindCommunityClub(true)
            end)
        end
        return communityClubId
    end
    ClearCommunityClubCache()
    return nil
end

-- Code affiche dans le popup : dernier shard (overflow) si le pool en a plusieurs.
function Overlord.Sync:GetCommunityInviteCode()
    local codes = GetCommunityInviteListForPool()
    if type(codes) == "table" then
        return codes[#codes]
    end
    return codes
end

-- The supplied Forever invite is global and intentionally has no region tag.
function Overlord.Sync:GetCommunityRegionTag()
    return ""
end

-- Export Check PvP / affichage : aligne sur le pool FR (royaume EU francophone)
function Overlord.Sync:IsInFrenchCommunityPool()
    return IsLocaleInFRPool()
end

-- Export Check PvP / affichage : aligne sur le pool DE (royaume EU germanophone)
function Overlord.Sync:IsInGermanCommunityPool()
    return IsLocaleInDEPool()
end

-- C_Club est pret ou les early retries sont epuises : on peut faire confiance a un "pas membre".
function Overlord.Sync:IsCommunitySearchSettled()
    if communityClubId or #communityClubIds > 0 then return true end
    return communityEarlyRetries >= COMMUNITY_MAX_EARLY_RETRIES
end

-- Membre detecte au login / migration legacy (flag absent) : pas de message ni burst SR.
function Overlord.Sync:AdoptCommunityMembershipSilent()
    if not OverlordDB then return end
    OverlordDB.inCommunity = true
end

-- Join commu mid-session (inCommunity == false) : SR whisper commu + canal same-faction.
function Overlord.Sync:TryCommunityJoinSync(forceHistory)
    if Overlord.InstanceSuspended or not OverlordDB then return end
    if OverlordDB.inCommunity == true then return end
    local clubId = self:FindCommunityClub()
    if not clubId then
        ClearCommunityClubCache()
        lastCommunitySearch = -COMMUNITY_SEARCH_INTERVAL
        clubId = self:FindCommunityClub()
    end
    if not clubId then return end
    -- Flag absent = membre avant introduction du flag : migration silencieuse.
    if OverlordDB.inCommunity == nil then
        self:AdoptCommunityMembershipSilent()
        return
    end
    OverlordDB.inCommunity = true
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L.SYNC_REQUESTED or "Sync requested."))
    -- Cross-faction : whispers commu (le canal Overlord est filtre par faction en War Mode).
    self:ScanCommunityMembers(true)
    for i = 1, 3 do
        C_Timer.After((i - 1) * 2, function()
            if Overlord.InstanceSuspended or not Overlord.Sync then return end
            Overlord.Sync:SendSyncRequest()
        end)
    end
    if self.ScheduleLoginLeaderboardHistoryCatchUp then
        self:ScheduleLoginLeaderboardHistoryCatchUp(forceHistory == true)
    end
end

-- Detection commu (UI login / refresh) : sync seulement apres join explicite (flag false).
function Overlord.Sync:HandleCommunityMembershipDetected()
    if not OverlordDB then return end
    if OverlordDB.inCommunity == true then return end
    lastCommunitySearch = -COMMUNITY_SEARCH_INTERVAL
    ClearCommunityClubCache()
    if not self:FindCommunityClub() then return end
    self:TryCommunityJoinSync(true)
end

-- Perte commu confirmee : ne pas resetter tant que C_Club n'est pas pret au login.
function Overlord.Sync:HandleCommunityMembershipLost()
    if not OverlordDB then return end
    if not self:IsCommunitySearchSettled() then return end
    lastCommunitySearch = -COMMUNITY_SEARCH_INTERVAL
    ClearCommunityClubCache()
    if self:FindCommunityClub() then return end
    OverlordDB.inCommunity = false
    if self.CommitEmptyOnlineMembersCache then
        self:CommitEmptyOnlineMembersCache()
    end
end

function Overlord.Sync:FindCommunityClub(forceRefresh, preserveCacheOnMiss)
    if Overlord.CommunityModeEnabled == false then return nil end
    if Overlord.InstanceSuspended then return communityClubId end
    local now = GetTime()

    -- Cooldown adaptatif : au login, C_Club n'est pas pret immediatement.
    -- On retente toutes les 15s pendant ~2min, puis on passe au cooldown normal (5min).
    local cooldown = (communityEarlyRetries < COMMUNITY_MAX_EARLY_RETRIES)
        and COMMUNITY_EARLY_RETRY or COMMUNITY_SEARCH_INTERVAL
    -- Rescan periodique meme si un shard est deja connu (join US 2 mid-session, pont multi-club).
    if not forceRefresh then
        if communityClubId and (now - lastCommunitySearch < cooldown) then
            return communityClubId
        end
        if now - lastCommunitySearch < cooldown then
            return communityClubId
        end
    end

    if not C_Club or not C_Club.GetSubscribedClubs then
        -- C_Club pas encore pret au login : ne pas poser lastCommunitySearch (sinon les scans
        -- a +12 s sont ignores alors que l'API est chargee entre-temps).
        return communityClubId
    end

    -- Snapshot de la constante Enum pour eviter le taint lors de la comparaison
    local CHARACTER_CLUB = Enum.ClubType.Character

    -- Copie locale des infos clubs pour eviter de propager le taint de la table C_Club
    -- (evite l'erreur "Secret values" quand le joueur ouvre le panneau Communautes)
    local clubInfos = {}
    securecall(function()
        local clubs = C_Club.GetSubscribedClubs()
        if clubs then
            for i = 1, #clubs do
                local c = clubs[i]
                if c and c.name and c.clubType == CHARACTER_CLUB then
                    clubInfos[#clubInfos + 1] = { id = c.clubId, name = c.name:lower() }
                end
            end
        end
    end)
    if #clubInfos == 0 then
        communityEarlyRetries = communityEarlyRetries + 1
        -- Liste vide souvent transitoire au login : retry rapide sans bloquer 15 s.
        if communityEarlyRetries >= COMMUNITY_MAX_EARLY_RETRIES then
            lastCommunitySearch = now
        end
        return self:HandleCommunityClubSearchMiss(preserveCacheOnMiss)
    end
    lastCommunitySearch = now

    -- Forever : club personnage dont le nom contient "overlord"
    -- (ex. "Overlord Forever EU", "Overlord test" en beta).
    -- Tous les clubs du pool (shards) : roster fusionne dans SyncAux pour la sync whisper.
    local wantTag = GetCommunityPoolTag()
    if not wantTag then
        communityEarlyRetries = communityEarlyRetries + 1
        return communityClubId
    end
    local matchedClubIds = {}
    local subscribedEuropeanClubIds = {}
    for _, info in ipairs(clubInfos) do
        if info.name:find("overlord", 1, true) then
            matchedClubIds[#matchedClubIds + 1] = info.id
        end
        local words = " " .. info.name:gsub("[^%w]+", " ") .. " "
        if GetPlayerRegion() == "eu" and info.name:find("overlord", 1, true)
            and (words:find(" fr ", 1, true) or words:find(" de ", 1, true)
                or words:find(" eu ", 1, true)) then
            subscribedEuropeanClubIds[#subscribedEuropeanClubIds + 1] = info.id
        end
    end
    if #matchedClubIds == 0 and (communityClubId or #communityClubIds > 0) then
        return self:HandleCommunityClubSearchMiss(preserveCacheOnMiss)
    end
    -- Retirer les shards du pool territorial courant : le cache communautaire
    -- normal les couvre deja. Ce tableau ne contient donc que de vrais ponts
    -- FR<->DE<->EU et ne peut pas elargir FindAllCommunityClubs.
    local matchedBridgeClubIds = {}
    local localClubSet = {}
    for i = 1, #matchedClubIds do localClubSet[matchedClubIds[i]] = true end
    for i = 1, #subscribedEuropeanClubIds do
        local id = subscribedEuropeanClubIds[i]
        if not localClubSet[id] then
            matchedBridgeClubIds[#matchedBridgeClubIds + 1] = id
        end
    end
    self._communityClubEmptyScans = 0
    local clubsChanged = #matchedClubIds ~= #communityClubIds
    if not clubsChanged then
        for i = 1, #matchedClubIds do
            if matchedClubIds[i] ~= communityClubIds[i] then
                clubsChanged = true
                break
            end
        end
    end
    local bridgeClubsChanged = #matchedBridgeClubIds
        ~= #europeanLeaderboardBridgeClubIds
    if not bridgeClubsChanged then
        for i = 1, #matchedBridgeClubIds do
            if matchedBridgeClubIds[i] ~= europeanLeaderboardBridgeClubIds[i] then
                bridgeClubsChanged = true
                break
            end
        end
    end
    -- Le rescan periodique des clubs tourne meme quand le pool n'a pas change.
    -- Ne pas jeter les gros caches roster/characters dans ce cas.
    if clubsChanged then
        ClearCommunityClubCache()
        for i = 1, #matchedClubIds do
            communityClubIds[i] = matchedClubIds[i]
        end
        for i = 1, #matchedBridgeClubIds do
            europeanLeaderboardBridgeClubIds[i] = matchedBridgeClubIds[i]
        end
    elseif bridgeClubsChanged then
        wipe(europeanLeaderboardBridgeClubIds)
        for i = 1, #matchedBridgeClubIds do
            europeanLeaderboardBridgeClubIds[i] = matchedBridgeClubIds[i]
        end
        if self.InvalidateEuropeanLeaderboardBridgeMembersCache then
            self:InvalidateEuropeanLeaderboardBridgeMembersCache(true)
        end
    end
    communityClubId = communityClubIds[1]

    if communityClubId then
        -- Les retries rapides ne servent qu'au bootstrap de C_Club. Une fois le
        -- pool trouve, rester a 15 s invaliderait les caches roster en boucle et
        -- pourrait annuler un scan de contrats en cours. Les rescans normaux de
        -- nouveaux shards gardent leur cadence de cinq minutes.
        communityEarlyRetries = COMMUNITY_MAX_EARLY_RETRIES
    else
        communityEarlyRetries = communityEarlyRetries + 1
        -- Avertissement unique quand les retries sont epuises (C_Club a eu le temps de charger)
        if communityEarlyRetries >= COMMUNITY_MAX_EARLY_RETRIES
            and not communityNotFoundWarned and Overlord.InActiveFront then
            communityNotFoundWarned = true
            local code = self:GetCommunityInviteCode()
            Overlord:PrintNotification("|cffff6600[Overlord]|r " .. L.COMMUNITY_NOT_FOUND)
            Overlord:PrintNotification("|cffff6600[Overlord]|r " .. string.format(L.COMMUNITY_JOIN_LINK, code))
        end
    end

    return communityClubId
end

-- Tous les clubs Overlord du pool local (ex. US + US 2 si le joueur y est abonne).
function Overlord.Sync:FindAllCommunityClubs()
    if Overlord.CommunityModeEnabled == false then return {} end
    if not communityClubId and #communityClubIds == 0 then
        self:FindCommunityClub()
    end
    return communityClubIds
end

-- Clubs d'autres pools territoriaux europeens, reserves au classement. Cette
-- API retourne deliberement un cache distinct : FindAllCommunityClubs garde
-- exactement sa portee locale pour les captures, alertes et Guild Keeps.
function Overlord.Sync:FindEuropeanLeaderboardBridgeClubs()
    if Overlord.CommunityModeEnabled == false then return {} end
    if GetPlayerRegion() ~= "eu" then return europeanLeaderboardBridgeClubIds end
    if #europeanLeaderboardBridgeClubIds == 0 then
        self:FindCommunityClub()
    end
    return europeanLeaderboardBridgeClubIds
end

-- Export Check PvP: the global Forever population uses the single Overlord club.
function Overlord.Sync:IsEligibleForCheckPvPExport()
    local pr = GetPlayerRegion()
    if pr ~= "global" then
        return true
    end
    -- En instance PvP suspendue : FindCommunityClub ne relit pas C_Club (tables interdites) ;
    -- on s'appuie sur le cache communityClubId pour eviter un faux NO_COMMUNITY.
    if Overlord.InstanceSuspended then
        return self:FindCommunityClub() ~= nil
    end
    -- Re-scan immediat : lastCommunitySearch = 0 cassait le premier GetTime() (< cooldown, jamais C_Club).
    return self:FindCommunityClub(true, true) ~= nil
end

-- Reinitialise le compteur de retries au login/entree en front pour relancer la recherche.
-- Appele depuis OnEnterFront (le joueur a pu rejoindre la commu depuis la derniere session).
function Overlord.Sync:ResetCommunitySearch()
    communityEarlyRetries = 0
    communityNotFoundWarned = false
    lastCommunitySearch = -COMMUNITY_SEARCH_INTERVAL
    self._communityClubEmptyScans = 0
    self._communityClubLossProbeScheduled = false
end

-- Scanne les membres en ligne de la communaute et envoie des SR en whisper.
-- Rotation aleatoire de l'index de depart pour couvrir tous les membres sur plusieurs scans.
-- Cross-realm ET cross-faction : la communaute active le whisper entre ses membres,
-- meme entre factions differentes sur des royaumes differents.
-- Le filtre ChatFrame masque les erreurs residuelles (joueur offline, etc).
-- force=true : bypasse le cooldown scanInterval (utilise apres BroadcastCapture pour propagation
-- immediate cross-realm / cross-faction sans attendre le prochain cycle de 120s).
function Overlord.Sync:ScanCommunityMembers(force)
    local betaSent = Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork
        and Overlord.BetaNetwork:Broadcast("NH", Overlord.Version) or 0
    if Overlord.CommunityModeEnabled == false then return betaSent end
    -- C_Club retourne des tables "forbidden" en instance PvP : ne pas iterer du tout
    if Overlord.InstanceSuspended then return betaSent end
    local clubId = self:FindCommunityClub()
    if not clubId then return betaSent end

    -- En event massif (raid 20+ OU 15+ joueurs Overlord a proximite) : reduire le scan
    local inLargeEvent = self:IsLargeEvent()
    local scanInterval = inLargeEvent and 300 or COMMUNITY_SCAN_INTERVAL

    local now = GetTime()
    if not force and now - lastCommunityScan < scanInterval then return betaSent end
    lastCommunityScan = now

    lastCommunitySR:Prune(now, 8)

    local myName = self:GetPlayerFullName()
    local sent = 0
    local maxSR = inLargeEvent and 3 or COMMUNITY_MAX_SR_PER_SCAN
    local cachedOnline = self.GetOnlineCommunityMembersIfFresh and self:GetOnlineCommunityMembersIfFresh(15)
    if cachedOnline and #cachedOnline == 0 then
        return betaSent
    end
    if not cachedOnline and self.GetOnlineCommunityMembers then
        cachedOnline = self:GetOnlineCommunityMembers(true, 15)
    end
    if cachedOnline and #cachedOnline == 0 then
        return betaSent
    end
    if cachedOnline and #cachedOnline > 0 then
        local startIdx = (communityCachedScanCursor % #cachedOnline) + 1
        local scanned = 0
        for i = 0, #cachedOnline - 1 do
            if sent >= maxSR then break end
            scanned = i + 1
            local idx = ((startIdx + i - 1) % #cachedOnline) + 1
            local memberName = cachedOnline[idx]
            if memberName and memberName ~= "" and memberName ~= myName then
                local lastSR = lastCommunitySR:Get(memberName) or 0
                if now - lastSR >= COMMUNITY_SR_COOLDOWN then
                    lastCommunitySR:Remember(memberName, now)
                    local target = memberName
                    C_Timer.After(sent * 0.5, function()
                        if Overlord.Sync and not Overlord.InstanceSuspended then
                            pcall(Overlord.Sync.SendWhisper, Overlord.Sync,
                                "SR", SRPayload("T"), target)
                        end
                    end)
                    sent = sent + 1
                end
            end
        end
        communityCachedScanCursor = (communityCachedScanCursor + math.max(1, scanned))
            % #cachedOnline
        return sent + betaSent
    end
    -- Cache froid : GetOnlineCommunityMembers a deja demarre le worker tranche de
    -- SyncAux. Ne jamais retomber ici sur un GetClubMembers/GetMemberInfo synchrone.
    return betaSent
end

-- Fin de gate login : SR whisper a tous les membres commu en ligne (pas 12 au hasard).
-- Chemin fiable pour late joiner ; reponse whisper SR = 100 % ZA garanti cote receveur.
function Overlord.Sync:SendLoginCatchupSyncToCommunity()
    if Overlord.InstanceSuspended or IsInInstance() then return 0 end
    local betaSent = Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork
        and Overlord.BetaNetwork:Broadcast("SR", SRPayload("T")) or 0
    if Overlord.CommunityModeEnabled == false then
        return betaSent
    end
    if not self:FindCommunityClub() then return betaSent end

    local myName = self:GetPlayerFullName()
    local payload = SRPayload("T")
    local sent = 0
    local maxSR = (self.IsLargeEvent and self:IsLargeEvent()) and LOGIN_CATCHUP_SR_MAX_LARGE or LOGIN_CATCHUP_SR_MAX
    -- Force un vrai relire du roster : au login, un cache vide peut provenir
    -- d'un C_Club encore partiellement initialise, pas d'une communaute vide.
    local onlineList = (self.GetOnlineCommunityMembers and self:GetOnlineCommunityMembers(true, 0)) or {}
    if #onlineList == 0 then return betaSent end

    for i = 1, #onlineList do
        if sent >= maxSR then break end
        local memberName = onlineList[i]
        if memberName and memberName ~= "" and memberName ~= myName then
            local target = memberName
            C_Timer.After(sent * LOGIN_CATCHUP_SR_DELAY, function()
                if Overlord.Sync and not Overlord.InstanceSuspended then
                    pcall(Overlord.Sync.SendWhisper, Overlord.Sync, "SR", payload, target)
                end
            end)
            sent = sent + 1
        end
    end
    return sent + betaSent
end

-- Stats communaute (utilise par la sync cross-realm)
-- Cache de 30s : evite 200+ appels API/s quand RefreshCommunityButton est appele chaque seconde
local cachedCommunityOnline = 0
local lastCommunityStatsTime = 0
local COMMUNITY_STATS_CACHE_INTERVAL = 30

function Overlord.Sync:InvalidateCommunityStatsCache()
    cachedCommunityOnline = 0
    lastCommunityStatsTime = 0 - COMMUNITY_STATS_CACHE_INTERVAL
end

function Overlord.Sync:GetCommunityStats()
    if Overlord.InstanceSuspended then return false, 0 end
    if not communityClubId and #communityClubIds == 0 then return false, 0 end

    local now = GetTime()
    if now - lastCommunityStatsTime < COMMUNITY_STATS_CACHE_INTERVAL then
        return true, cachedCommunityOnline
    end
    lastCommunityStatsTime = now
    if self.GetOnlineCommunityMemberCount then
        cachedCommunityOnline = self:GetOnlineCommunityMemberCount(COMMUNITY_STATS_CACHE_INTERVAL)
        return true, cachedCommunityOnline
    end

    -- SyncAux fournit le worker partage en production. Sans lui, ne jamais
    -- retomber sur un parcours C_Club synchrone depuis le rafraichissement UI.
    return true, cachedCommunityOnline
end

-- Envoi : priorite GROUPE (RAID/PARTY) pour que la sync marche cross-realm, sinon canal Overlord (meme royaume uniquement).
function Overlord.Sync:Send(msgType, data, groupOnly)
    if Overlord.BetaNetwork and Overlord.BetaNetwork:IsEcho(msgType, data) then return false end
    if Overlord.InstanceSuspended then return end
    -- Filet de securite : IsInInstance/GetInstanceInfo peuvent confirmer une instance
    -- meme quand InstanceSuspended est brievement false (race condition en loading)
    if IsInInstance() then return end
    local msg = msgType
    if data and data ~= "" then
        msg = msgType .. ":" .. data
    end
    if #msg > 255 then return false end

    -- WoW API : PARTY = membres de *votre* groupe (en raid souvent uniquement le sous-groupe ~5).
    -- RAID = tout le raid. Toujours envoyer RAID en raid reel pour la sync 40v40 ; sinon PARTY.
    -- IsInRaid() peut rester vrai alors que le canal RAID refuse (spam "pas de groupe de raid") :
    -- on exige aussi UnitInRaid("player") reel pour prendre la branche RAID.
    -- Apres sortie ARENE/BG, grace period PARTY dans Resume().
    -- WoW 12.0.5 : securecall (evite taint ChatFrame_MessageEventFilters)
    local raidOk = IsInRaid() and UnitInRaid("player")
        and (not self._instanceResumeTime or GetTime() - self._instanceResumeTime > 5)
    if raidOk then
        securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "RAID")
        return true
    end
    if IsInGroup() then
        securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "PARTY")
        return true
    end

    if groupOnly then return false end
    if SYNC_USE_REALM_CHANNEL then
        local channelId = self:GetChannelId()
        if channelId then
            securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "CHANNEL", channelId)
            return true
        end
    end
    return false
end

-- Variante pour les producteurs qui envoient ensuite explicitement au canal.
-- Sans cette garde, Send() retombe deja sur CHANNEL en solo et le meme paquet
-- est emis deux fois (puis parse/dedup deux fois chez chaque receveur).
function Overlord.Sync:SendToGroup(msgType, data)
    return self:Send(msgType, data, true)
end

-- Budget de debit canal : Blizzard limite ~4096 B/s sur CHANNEL addon.
-- On se donne un plafond conservateur de 2800 B/s pour laisser une marge aux autres addons.
local CHANNEL_BYTE_BUDGET_PER_SEC = 2800
local channelBytesSent = 0
local channelBudgetResetTime = 0

-- Envoi supplementaire au canal (pour visibilite cross-faction : ennemis voient captures/zones en cours)
function Overlord.Sync:SendToChannel(msgType, data, critical)
    if Overlord.BetaNetwork and Overlord.BetaNetwork:IsEcho(msgType, data) then return false end
    if not SYNC_USE_REALM_CHANNEL or Overlord.InstanceSuspended or IsInInstance() then return false end
    local channelId = self:GetChannelId()
    if not channelId then return false end
    local msg = msgType
    if data and data ~= "" then msg = msgType .. ":" .. data end
    if #msg > 255 then return false end
    -- Throttle de debit : refuse l'envoi si le budget seconde est epuise.
    -- Les messages finaux critiques restent envoyes, mais leurs octets sont comptes.
    local now = GetTime()
    if now - channelBudgetResetTime >= 1 then
        channelBytesSent = 0
        channelBudgetResetTime = now
    end
    local msgLen = #msg + #PREFIX + 4
    if channelBytesSent + msgLen > CHANNEL_BYTE_BUDGET_PER_SEC and not critical then return false end
    channelBytesSent = channelBytesSent + msgLen
    securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "CHANNEL", channelId)
    return true
end

-- Broadcast du shardID courant (permet de detecter si des joueurs sont sur des shards differents)
-- Format : SH:shardID
function Overlord.Sync:BroadcastShard(shardID)
    if shardID == nil then return end
    local payload = tostring(shardID)
    -- SH doit sortir du raid : plusieurs raids peuvent tenir le meme event / shard.
    self:SendToGroup("SH", payload)
    self:SendToChannel("SH", payload)
    -- En 40v40, eviter que chaque client heartbeat vers communaute/BNet.
    -- Raid + canal suffisent pour l'event principal ; les chemins larges restent utiles en petit groupe.
    if Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()
        and (not self.IsLargeEvent or not self:IsLargeEvent()) then
        if self.BroadcastToCommunity then
            self:BroadcastToCommunity("SH", payload, 20, 0.5)
        end
    end
end

function Overlord.Sync:_RemoveRecentAddonWhisperNode(node)
    if not node then return end
    if node.previous then
        node.previous.next = node.next
    else
        priv.recentAddonWhisperHead = node.next
    end
    if node.next then
        node.next.previous = node.previous
    else
        priv.recentAddonWhisperTail = node.previous
    end
    priv.recentAddonWhisperNodes[node.key] = nil
    priv.recentAddonWhispers[node.key] = nil
    local baseKey = node.key:match("^([^%-]+)") or node.key
    if priv.recentAddonWhisperAliases[node.key] == node.timestamp then
        priv.recentAddonWhisperAliases[node.key] = nil
    end
    if priv.recentAddonWhisperAliases[baseKey] == node.timestamp then
        priv.recentAddonWhisperAliases[baseKey] = nil
    end
    priv.recentAddonWhisperCount = math.max(0, priv.recentAddonWhisperCount - 1)
end

function Overlord.Sync:_PruneRecentAddonWhispers(now, budget)
    local cutoff = (tonumber(now) or GetTime()) - 15
    local removed = 0
    budget = math.max(1, math.floor(tonumber(budget) or 1))
    while priv.recentAddonWhisperHead
        and priv.recentAddonWhisperHead.timestamp < cutoff
        and removed < budget do
        self:_RemoveRecentAddonWhisperNode(priv.recentAddonWhisperHead)
        removed = removed + 1
    end
end

function Overlord.Sync:_RememberRecentAddonWhisper(target, now)
    local key = target and target:lower()
    if not key or key == "" then return end
    now = tonumber(now) or GetTime()
    self:_PruneRecentAddonWhispers(now, 8)
    local node = priv.recentAddonWhisperNodes[key]
    if node then
        node.timestamp = now
        priv.recentAddonWhispers[key] = now
        priv.recentAddonWhisperAliases[key] = now
        priv.recentAddonWhisperAliases[key:match("^([^%-]+)") or key] = now
        if node ~= priv.recentAddonWhisperTail then
            if node.previous then
                node.previous.next = node.next
            else
                priv.recentAddonWhisperHead = node.next
            end
            if node.next then node.next.previous = node.previous end
            node.previous = priv.recentAddonWhisperTail
            node.next = nil
            if priv.recentAddonWhisperTail then
                priv.recentAddonWhisperTail.next = node
            end
            priv.recentAddonWhisperTail = node
            if not priv.recentAddonWhisperHead then priv.recentAddonWhisperHead = node end
        end
        return
    end
    if priv.recentAddonWhisperCount >= priv.recentAddonWhisperMax then
        self:_RemoveRecentAddonWhisperNode(priv.recentAddonWhisperHead)
    end
    node = { key = key, timestamp = now, previous = priv.recentAddonWhisperTail, next = nil }
    if priv.recentAddonWhisperTail then
        priv.recentAddonWhisperTail.next = node
    else
        priv.recentAddonWhisperHead = node
    end
    priv.recentAddonWhisperTail = node
    priv.recentAddonWhisperNodes[key] = node
    priv.recentAddonWhispers[key] = now
    priv.recentAddonWhisperAliases[key] = now
    priv.recentAddonWhisperAliases[key:match("^([^%-]+)") or key] = now
    priv.recentAddonWhisperCount = priv.recentAddonWhisperCount + 1
end

-- Enregistre un nom dans le filtre d'erreurs whisper (masque "Aucun joueur nomme 'X'...").
-- Utilise par UI.lua pour les whispers en clair (SendChatMessage) du systeme d'invite shard.
function Overlord.Sync:RegisterRecentWhisperTarget(target)
    if not target or type(target) ~= "string" then return end
    target = target:match("^%s*(.-)%s*$") or ""
    if target == "" or #target < 2 then return end
    self:_RememberRecentAddonWhisper(target, GetTime())
end

-- Enregistre un credit kill total (K reseau ou credit local groupe) pour bloquer EK additif en double.
-- skipZone=true : le client a deja incremente les compteurs de zone localement (ProcessKill groupe).
function Overlord.Sync:RegisterRecentKCredit(playerName, skipZone)
    if not playerName or playerName == "" then return end
    playerName = self:NormalizeContributorFullName(playerName) or playerName
    if playerName == "" then return end
    local now = GetTime()
    return recentKCredits:Remember(playerName:lower(),
        { ts = now, skipZone = skipZone and true or false }, now, true)
end

-- Credit kill total (K) recent pour dedup EK et bonus prime BD (+1 si deja compte via K).
function Overlord.Sync:HasRecentKillCredit(playerName)
    if not playerName or playerName == "" then return false end
    playerName = self:NormalizeContributorFullName(playerName) or playerName
    if playerName == "" then return false end
    return recentKCredits:Get(playerName:lower(), GetTime()) ~= nil
end

function Overlord.Sync:SendWhisper(msgType, data, target)
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork
        and msgType ~= "R1" and msgType ~= "BF" and Overlord.BetaNetwork:IsPeer(target) then
        return Overlord.BetaNetwork:Send(msgType, data or "", target)
    end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    -- Cible vide / trop courte / espaces : l'API envoie quand meme et Blizzard affiche
    -- "Aucun joueur nommé '' ne joue actuellement" (non filtre par l'ancien pattern (.+)).
    if not target or type(target) ~= "string" then return end
    target = target:match("^%s*(.-)%s*$") or ""
    if not self:IsValidWhisperTarget(target) then return end
    local msg = msgType
    if data and data ~= "" then
        msg = msgType .. ":" .. data
    end
    -- C_ChatInfo refuse silencieusement les messages addon trop longs. Garder
    -- une borne unique ici evite qu'un retry critique (C/NW/route) paraisse
    -- envoye alors qu'il n'a jamais quitte le client.
    if #msg > 255 then return false end
    local now = GetTime()
    self:_RememberRecentAddonWhisper(target, now)
    -- securecall : empeche le taint addon de contaminer SetLastTellTarget
    -- (meme fix que SendToBNet, sinon "secret string value" sur les whispers entrants)
    securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "WHISPER", target)
    return true
end

-- Envoi via Battle.net (cross-faction, cross-realm, amis BNet uniquement)
-- Inclut notre band pour que le recepteur puisse nous identifier (routage bridge)
-- Pas de sync addon cross-region (US vs EU) : Check PvP et SV restent dans le bon pool.
local function IsBNetGameAccountInCurrentRegion(gameAccountID)
    if not gameAccountID then return false end
    local ok, allow = pcall(function()
        if C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
            local info = C_BattleNet.GetGameAccountInfoByID(gameAccountID)
            if info and info.isInCurrentRegion == false then
                return false
            end
        end
        return true
    end)
    return ok and allow
end

-- BNet transporte une identite de compte synthetique, mais l'API locale expose
-- le personnage Retail actuellement connecte. Le resoudre permet d'afficher un
-- in_progress BNet sans compter WoW+BNet comme deux temoins differents : les
-- deux chemins se dedupliquent sur la meme identite canonique.
local resolvedBNetFactionByPlayer = {}
local function ResolveBNetGameplaySender(sync, gameAccountID)
    if not sync or not gameAccountID or not C_BattleNet
        or not C_BattleNet.GetGameAccountInfoByID then return nil end
    local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, gameAccountID)
    if not ok or not info or not info.characterName or info.characterName == ""
        or (info.clientProgram and info.clientProgram ~= "WoW")
        or (info.wowProjectID and info.wowProjectID ~= WOW_PROJECT_ID)
        or info.isInCurrentRegion == false then return nil end
    local fullName = sync.CanonicalForeverName
        and sync:CanonicalForeverName(info.characterName) or nil
    if not fullName then return nil end
    local key = sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(fullName) or nil
    local faction = info.factionName
    if key and (faction == "Alliance" or faction == "Horde") then
        resolvedBNetFactionByPlayer[key] = faction
    end
    return fullName
end

function Overlord.Sync:GetResolvedBNetPlayerFaction(playerName)
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(playerName) or nil
    return key and resolvedBNetFactionByPlayer[key] or nil
end

function Overlord.Sync:SendToBNet(gameAccountID, msgType, data)
    if not SYNC_USE_BNET_OUTBOUND or not gameAccountID or Overlord.InstanceSuspended or IsInInstance() then return end
    if not IsBNetGameAccountInCurrentRegion(gameAccountID) then return end
    local band = self:GetMyBand()
    local msg = msgType .. ":" .. band
    if data and data ~= "" then msg = msg .. ":" .. data end
    if #msg > 4000 then return end
    if (msgType == "BR" or msgType == "BF") and Overlord.BetaNetworkEnabled ~= false then
        msg = "R2:" .. band .. ":" .. msgType .. ":" .. (data or "")
    end
    -- securecall au lieu de pcall : empeche le taint de se propager au systeme de chat
    -- (pcall attrape les erreurs mais laisse le taint contaminer SetLastTellTarget)
    if C_BattleNet and C_BattleNet.SendGameData then
        securecall(C_BattleNet.SendGameData, gameAccountID, PREFIX, msg)
        return true
    end
    return false
end

-- Liste des amis BNet connectes en WoW Forever (meme projet que le client local).
local BNET_MAX_FRIENDS = 15
local BNET_DELAY_PER_FRIEND = 0.4
local WOW_CLIENT_PROGRAM = "WoW"
local cachedBNetFriendsList = nil
local cachedBNetFriendsAt = 0
local BNET_FRIENDS_CACHE_TTL = 45

local function IsForeverWowGameAccount(game)
    if not game or not game.isOnline or not game.characterName then return false end
    if game.clientProgram ~= WOW_CLIENT_PROGRAM then return false end
    if game.isInCurrentRegion == false then return false end
    if not game.wowProjectID then return true end
    return game.wowProjectID == WOW_PROJECT_ID
end

local function GetBNetFriendsInWoW()
    local now = GetTime()
    if cachedBNetFriendsList and (now - cachedBNetFriendsAt) < BNET_FRIENDS_CACHE_TTL then
        return cachedBNetFriendsList
    end
    local list = {}
    pcall(function()
        local numFriends = BNGetNumFriends()
        if not numFriends or numFriends == 0 then return end
        for i = 1, numFriends do
            local numAccounts = C_BattleNet and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i)
            if numAccounts then
                for j = 1, numAccounts do
                    if #list >= BNET_MAX_FRIENDS then break end
                    local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
                    if game and game.gameAccountID and IsForeverWowGameAccount(game) then
                        table.insert(list, game.gameAccountID)
                    end
                end
            end
        end
    end)
    cachedBNetFriendsList = list
    cachedBNetFriendsAt = now
    return list
end

-- Envoi a tous les amis BNet (throttle 0.4s entre chaque, max 10 amis)
-- Donnees addon uniquement : rien n'apparait dans le chat (BN_CHAT_MSG_ADDON)
function Overlord.Sync:GetBetaBNetTargets()
    return GetBNetFriendsInWoW()
end

function Overlord.Sync:SendToBNetFriends(msgType, data)
    if not SYNC_USE_BNET_OUTBOUND then return end
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:Broadcast(msgType, data or "")
    end
    local friends = GetBNetFriendsInWoW()
    for idx, gameAccountID in ipairs(friends) do
        C_Timer.After((idx - 1) * BNET_DELAY_PER_FRIEND, function()
            if Overlord.Sync and not Overlord.InstanceSuspended then
                Overlord.Sync:SendToBNet(gameAccountID, msgType, data)
            end
        end)
    end
end

-- ==================== Reception des messages ====================

-- Reception des messages Battle.net. Format: msgType:band:payload (band pour routage bridge)
-- Stocke senderID -> band pour savoir quels amis BNet sont dans quelles bands
function Overlord.Sync:OnBNetMessage(message, senderID)
    if not IsBNetGameAccountInCurrentRegion(senderID) then return end
    local msgType, rest = strsplit(":", message, 2)
    if not rest then return end

    -- R2 = message relaye par un bridge, format: R2:replyTo:msgType:band:payload
    if msgType == "R2" then
        if not SYNC_USE_BNET_OUTBOUND then return end
        local replyTo, innerMsg = strsplit(":", rest, 2)
        if replyTo and innerMsg then
            self:OnReceiveR2Relay(senderID, replyTo, innerMsg)
        end
        return
    end

    -- Format normal: msgType:band:payload (band = realm_A ou realm_H)
    local band, payload = strsplit(":", rest, 2)
    if band and band:match("_[AH]$") then
        bnet_links[senderID] = band
    else
        payload = rest
        band = nil
    end

    local sender = "BNet-" .. tostring(senderID)

    -- Dispatch via fonction nommee (evite de creer une closure pcall a chaque message BNet : GC).
    pcall(self.DispatchBNetMessage, self, msgType, payload, sender, senderID)
end

-- Dispatch des messages BNet recus (appele sous pcall depuis OnBNetMessage).
function Overlord.Sync:DispatchBNetMessage(msgType, payload, sender, senderID)
    if msgType == "BR" and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:Receive(payload, ResolveBNetGameplaySender(self, senderID), "BNET", senderID)
    elseif msgType == "BF" and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:ReceiveFragment(payload, ResolveBNetGameplaySender(self, senderID), "BNET", senderID)
    end
    if self.SenderBurstShouldDrop and self:SenderBurstShouldDrop(sender, msgType) then return end
    if msgType == "K" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveKill(payload or "", gameplaySender)
    elseif msgType == "EK" then
        self:OnReceiveEnemyKill(payload or "", sender)
    elseif msgType == "C" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveCapture(payload or "", gameplaySender)
    elseif msgType == "SR" then
        if not SYNC_USE_BNET_OUTBOUND then return end
        self:OnSyncRequest(senderID, payload or "", "BNET")
    elseif msgType == "ZS" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveZoneState(payload or "", gameplaySender)
    elseif msgType == "ZA" then
        -- Comme C/ZS, ZA a besoin de l'identite Retail Name-Realm reelle pour
        -- dedupliquer les voix. Le placeholder BNet-ID est volontairement exclu
        -- des quorums et bloquait sinon toute convergence BNet-only.
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveZoneAll(payload or "", gameplaySender)
    elseif msgType == "FA" then
        if Overlord.FrontActivity and Overlord.FrontActivity.OnReceiveSyncPayload then
            Overlord.FrontActivity:OnReceiveSyncPayload(payload or "", sender, "BNET")
        end
    elseif msgType == "LK" then
        self:OnReceiveLeaderboardKills(payload or "", sender, "BNET")
    elseif msgType == "LR" then
        self:OnReceiveLeaderboardRace(payload or "", sender, "BNET")
    elseif msgType == "LC" then
        -- Conserver l'identite Retail reelle quand elle est disponible, meme si
        -- LC est maintenant fusionne comme un snapshot monotone sans quorum.
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveLeaderboardCaptures(payload or "", gameplaySender, "BNET")
    elseif msgType == "LO" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveLeaderboardOutpostTenant(payload or "", gameplaySender, "BNET")
    elseif msgType == "LOC" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveLeaderboardOutpostCount(payload or "", gameplaySender, "BNET")
    elseif msgType == "OE" then
        self:OnReceiveLeaderboardOutpostEvidence(payload or "", sender, "BNET")
    elseif msgType == "TV" then
        self:OnReceiveTotalVictory(payload or "", sender, "BNET")
    elseif msgType == "VT" then
        self:OnReceiveVictoryTimestamp(payload or "")
    elseif msgType == "VF" then
        self:OnReceiveVictoryFaction(payload or "")
    elseif msgType == "FR" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveFrontTruceEndReset(payload or "", gameplaySender, "BNET")
    elseif msgType == "DX" then
        self:OnReceiveDomination(payload or "", sender, "BNET")
    elseif msgType == "VB" then
        self:OnReceiveVictoryBonus(payload or "", sender, "BNET")
    elseif msgType == "MN" then
        self:OnReceiveMining(payload or "", sender)
    elseif msgType == "MS" then
        self:OnReceiveMineStock(payload or "", sender)
    elseif msgType == "WN" then
        self:OnReceiveWoodHarvesting(payload or "", sender)
    elseif msgType == "WS" then
        self:OnReceiveWoodStock(payload or "", sender)
    elseif msgType == "GK" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveGuildKeepState(payload or "", gameplaySender, "BNET")
    elseif msgType == "GC" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveGuildKeepCapture(payload or "", gameplaySender, "BNET")
    elseif msgType == "GA" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveGuildKeepAbort(payload or "", gameplaySender, "BNET")
    elseif msgType == "G7" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveGuildKeepFragment(payload or "", gameplaySender, "BNET")
    elseif msgType == "GH" then
        local gameplaySender = ResolveBNetGameplaySender(self, senderID) or sender
        self:OnReceiveGuildKeepDailyProof(payload or "", gameplaySender, "BNET")
    elseif msgType == "OP" then
        self:OnReceiveOutpostState(payload or "", sender, "BNET")
    elseif msgType == "OC" then
        self:OnReceiveOutpostCapture(payload or "", sender, "BNET")
    elseif msgType == "WB" then
        self:OnReceiveDominationBoost(payload or "", sender, "BNET")
    elseif msgType == "SH" then
        self:OnReceiveShard(payload or "", sender, "BNET")
    end
end

-- Beta BR/BF preserves the original author through a bounded relay envelope.
-- Earlier hops are vouched for by the BNet peer; legacy R2 remains SR/TV only.
function Overlord.Sync:OnReceiveR2Relay(senderID, replyTo, innerMsg)
    if innerMsg and (innerMsg:sub(1, 3) == "BR:" or innerMsg:sub(1, 3) == "BF:") and Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        if not IsCompatibleForeverBand(replyTo) then return end
        if innerMsg:sub(1, 3) == "BF:" then
            return Overlord.BetaNetwork:ReceiveFragment(innerMsg:sub(4), ResolveBNetGameplaySender(self, senderID), "BNET", senderID)
        end
        return Overlord.BetaNetwork:Receive(innerMsg:sub(4), ResolveBNetGameplaySender(self, senderID), "BNET", senderID)
    end
    local msgType, payload = strsplit(":", innerMsg, 2)
    if msgType == "SR" then
        -- On simule une SR et on envoie la reponse a replyTo au lieu du sender BNet.
        self:OnSyncRequestRelayed(replyTo, payload or "")
    elseif msgType == "TV" then
        self:OnReceiveTotalVictory(payload or "", "Bridge-" .. tostring(senderID), "BNET")
    end
end

function Overlord.Sync:OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if channel == "BETA" and (not Overlord.BetaNetwork or not Overlord.BetaNetwork:IsDispatching(sender)) then return end
    if message and message:sub(1, 3) == "BF:" and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:ReceiveFragment(message:sub(4), sender, channel)
    end

    if self:IsSenderLocalPlayer(sender) then return end

    -- Tracker les joueurs Overlord actifs pour la detection d'events massifs (80v80 sans raid)
    if channel ~= "BETA" then RecordNearbySender(sender) end

    local msgType, payload = strsplit(":", message, 2)
    if self.NoteRaidLateJoinCatchUpResponse then
        self:NoteRaidLateJoinCatchUpResponse(sender, msgType, channel, payload)
    end

    -- Anti-triche : ignore les rafales anormales de messages mutateurs de score.
    -- C et LC ont des seuils compatibles avec les retries et reponses SR normaux.
    if self.SenderBurstShouldDrop and self:SenderBurstShouldDrop(sender, msgType) then
        return
    end

    -- GK/GC exclus : pas de confiance « recent front sender » (spoof cross-faction)
    if msgType == "SR" or msgType == "ZA" or msgType == "ZS" then
        RecordRecentFrontSender(sender)
    end

    local ok, err = true, nil
    if msgType == "ST" then
        ok, err = pcall(self.OnReceiveST, self, sender, payload)
    elseif msgType == "R1" then
        ok, err = pcall(self.OnReceiveR1, self, sender, payload)
    elseif msgType == "K" then
        self:OnReceiveKill(payload, sender)
    elseif msgType == "EK" then
        self:OnReceiveEnemyKill(payload, sender)
    elseif msgType == "C" then
        ok, err = pcall(self.OnReceiveCapture, self, payload, sender, channel)
    elseif msgType == "SR" then
        ok, err = pcall(self.OnSyncRequest, self, sender, payload, channel)
    elseif msgType == "ZS" then
        self:OnReceiveZoneState(payload, sender, channel)
    elseif msgType == "ZR" then
        if Overlord.CaptureLease and Overlord.CaptureLease.ReceiveRelease then
            ok, err = pcall(Overlord.CaptureLease.ReceiveRelease,
                Overlord.CaptureLease, payload or "", sender)
        end
    elseif msgType == "NR" then
        ok, err = pcall(self.OnReceiveCaptureNetworkProbeReply,
            self, payload or "", sender, channel)
    elseif msgType == "NC" then
        ok, err = pcall(self.OnReceiveCaptureNetworkRouteCommit,
            self, payload or "", sender, channel)
    elseif msgType == "NA" then
        ok, err = pcall(self.OnReceiveCaptureNetworkRouteAck,
            self, payload or "", sender, channel)
    elseif msgType == "CB" then
        ok, err = pcall(self.OnReceiveCaptureBarrier, self, payload or "", sender)
    elseif msgType == "ZA" then
        ok, err = pcall(self.OnReceiveZoneAll, self, payload, sender)
    elseif msgType == "FA" then
        if Overlord.FrontActivity and Overlord.FrontActivity.OnReceiveSyncPayload then
            ok, err = pcall(Overlord.FrontActivity.OnReceiveSyncPayload,
                Overlord.FrontActivity, payload or "", sender, channel)
        end
    elseif msgType == "RG" then
        OnReceiveRG(payload, sender)
    elseif msgType == "LK" then
        local accepted = self:OnReceiveLeaderboardKills(payload, sender, channel)
        if accepted and self.NoteHistoryCatchupDelivery then
            self:NoteHistoryCatchupDelivery("LK", payload or "", sender, channel)
        end
    elseif msgType == "LR" then
        local accepted = self:OnReceiveLeaderboardRace(payload, sender, channel)
        if accepted and self.NoteHistoryCatchupDelivery then
            self:NoteHistoryCatchupDelivery("LR", payload or "", sender, channel)
        end
    elseif msgType == "LC" then
        local accepted = self:OnReceiveLeaderboardCaptures(payload, sender, channel)
        if accepted and self.NoteHistoryCatchupDelivery then
            self:NoteHistoryCatchupDelivery("LC", payload or "", sender, channel)
        end
    elseif msgType == "HR" then
        if self.OnHistoryCatchupRequest then
            ok, err = pcall(self.OnHistoryCatchupRequest,
                self, payload or "", sender, channel)
        end
    elseif msgType == "HB" then
        if self.OnHistoryPushBegin then
            ok, err = pcall(self.OnHistoryPushBegin,
                self, payload or "", sender, channel)
        end
    elseif msgType == "HC" then
        if self.OnHistoryPushCommit then
            ok, err = pcall(self.OnHistoryPushCommit,
                self, payload or "", sender, channel)
        end
    elseif msgType == "HA" then
        if self.OnHistoryCatchupAck then
            ok, err = pcall(self.OnHistoryCatchupAck,
                self, payload or "", sender, channel)
        end
    elseif msgType == "LD" then
        -- Digest de classement : detecteur de divergence (ne mute rien, declenche un SR existant).
        if Overlord.LadderDigest then Overlord.LadderDigest:OnReceive(payload or "", sender) end
    elseif msgType == "LO" then
        ok, err = pcall(self.OnReceiveLeaderboardOutpostTenant, self, payload or "", sender, channel)
    elseif msgType == "LOC" then
        ok, err = pcall(self.OnReceiveLeaderboardOutpostCount, self, payload or "", sender, channel)
    elseif msgType == "OE" then
        ok, err = pcall(self.OnReceiveLeaderboardOutpostEvidence, self, payload or "", sender, channel)
    elseif msgType == "TV" then
        ok, err = pcall(self.OnReceiveTotalVictory, self, payload, sender, channel)
    elseif msgType == "VT" then
        self:OnReceiveVictoryTimestamp(payload or "")
    elseif msgType == "VF" then
        self:OnReceiveVictoryFaction(payload or "")
    elseif msgType == "FR" then
        self:OnReceiveFrontTruceEndReset(payload or "", sender, channel)
    elseif msgType == "DX" then
        self:OnReceiveDomination(payload or "", sender, channel)
    elseif msgType == "VB" then
        ok, err = pcall(self.OnReceiveVictoryBonus, self, payload or "", sender, channel)
    elseif msgType == "MN" then
        self:OnReceiveMining(payload or "", sender)
    elseif msgType == "MS" then
        self:OnReceiveMineStock(payload or "", sender)
    elseif msgType == "WN" then
        self:OnReceiveWoodHarvesting(payload or "", sender)
    elseif msgType == "WS" then
        self:OnReceiveWoodStock(payload or "", sender)
    elseif msgType == "GK" then
        ok, err = pcall(self.OnReceiveGuildKeepState, self, payload or "", sender, channel)
    elseif msgType == "GC" then
        ok, err = pcall(self.OnReceiveGuildKeepCapture, self, payload or "", sender, channel)
    elseif msgType == "GA" then
        ok, err = pcall(self.OnReceiveGuildKeepAbort, self, payload or "", sender, channel)
    elseif msgType == "G7" then
        ok, err = pcall(self.OnReceiveGuildKeepFragment, self, payload or "", sender, channel)
    elseif msgType == "GH" then
        ok, err = pcall(self.OnReceiveGuildKeepDailyProof, self, payload or "", sender, channel)
    elseif msgType == "OP" then
        ok, err = pcall(self.OnReceiveOutpostState, self, payload or "", sender, channel)
    elseif msgType == "OC" then
        ok, err = pcall(self.OnReceiveOutpostCapture, self, payload or "", sender, channel)
    elseif msgType == "WB" then
        ok, err = pcall(self.OnReceiveDominationBoost, self, payload or "", sender, channel)
    elseif msgType == "SH" then
        self:OnReceiveShard(payload or "", sender, channel)
    elseif msgType == "CR" then
        self:OnReceiveClassRequest(payload or "", sender)
    elseif msgType == "CA" then
        self:OnReceiveClassAnswer(payload or "", sender, channel)
    elseif msgType == "GR" then
        if self.OnReceiveGuildRequest then
            ok, err = pcall(self.OnReceiveGuildRequest, self, payload or "", sender, channel)
        end
    elseif msgType == "GY" then
        if self.OnReceiveGuildAnswer then
            ok, err = pcall(self.OnReceiveGuildAnswer, self, payload or "", sender, channel)
        end
    elseif msgType == "GI" then
        if self.OnReceiveGuildIdentity then
            ok, err = pcall(self.OnReceiveGuildIdentity, self, payload or "", sender, channel)
        end
    elseif msgType == "FC" then
        self:OnReceiveFactionCall(payload or "", sender)
    elseif msgType == "WD" then
        if Overlord.WorldDefense then
            ok, err = pcall(Overlord.WorldDefense.OnReceive,
                Overlord.WorldDefense, payload or "", sender, channel)
        end
    elseif msgType == "BS" then
        if Overlord.BountySync then
            ok, err = pcall(Overlord.BountySync.OnReceiveBS, Overlord.BountySync, payload or "", sender)
        end
    elseif msgType == "BP" then
        if Overlord.BountySync then
            ok, err = pcall(Overlord.BountySync.OnReceiveBP, Overlord.BountySync, payload or "", sender)
        end
    elseif msgType == "BD" then
        if Overlord.BountySync then
            ok, err = pcall(Overlord.BountySync.OnReceiveBD, Overlord.BountySync, payload or "", sender)
        end
    elseif msgType == "BC" then
        if Overlord.BountySync then
            ok, err = pcall(Overlord.BountySync.OnReceiveBC, Overlord.BountySync, payload or "", sender)
        end
    elseif msgType == "GE" then
        if Overlord.GeneralSync then
            ok, err = pcall(Overlord.GeneralSync.OnReceiveGE,
                Overlord.GeneralSync, payload or "", sender, channel)
        end
    elseif msgType == "GP" then
        if Overlord.GeneralSync then
            ok, err = pcall(Overlord.GeneralSync.OnReceiveGP,
                Overlord.GeneralSync, payload or "", sender, channel)
        end
    elseif msgType == "GX" then
        if Overlord.GeneralSync then
            ok, err = pcall(Overlord.GeneralSync.OnReceiveGX,
                Overlord.GeneralSync, payload or "", sender, channel)
        end
    elseif msgType == "GD" then
        if Overlord.GeneralSync then
            ok, err = pcall(Overlord.GeneralSync.OnReceiveGD,
                Overlord.GeneralSync, payload or "", sender, channel)
        end
    elseif msgType == "GM" then
        if Overlord.GeneralSync then
            ok, err = pcall(Overlord.GeneralSync.OnReceiveGM,
                Overlord.GeneralSync, payload or "", sender, channel)
        end
    elseif msgType == "BQ" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceiveBQ, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "BR" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceiveBR, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "PB" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceivePB, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "PK" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceivePK, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "MK" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceiveMK, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "PX" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceivePX, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "PP" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceivePP, Overlord.ManualBountySync, payload or "", sender)
        end
    elseif msgType == "PM" then
        if Overlord.ManualBountySync then
            ok, err = pcall(Overlord.ManualBountySync.OnReceivePM, Overlord.ManualBountySync, payload or "", sender)
        end
    end
    if not ok and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFFFF4444[Overlord:dbg]|r Sync " .. tostring(msgType) .. ": " .. tostring(err))
    end
end

-- Recoit SH (shard) : un joueur nous indique son shardID
function Overlord.Sync:OnReceiveShard(payload, sender, channel)
    if not payload or payload == "" then return end
    local shardID = tonumber(payload)
    if shardID == nil then
        if Overlord.Shard and Overlord.Shard.OnKeepShardWitness then
            Overlord.Shard:OnKeepShardWitness(payload, sender, channel)
        end
        return
    end
    if Overlord.Shard and Overlord.Shard.SetPlayerShard then
        Overlord.Shard:SetPlayerShard(sender, shardID)
    end
end

-- Recoit ST (status) : un bridge annonce sa band et celles qu'il peut atteindre via BNet
-- Format: ST:bridgeBand:targetBand1,targetBand2 (on n'utilise que les bridges de notre faction)
function Overlord.Sync:OnReceiveST(sender, payload)
    if not payload or payload == "" then return end
    local bridgeBand, rest = strsplit(":", payload, 2)
    if not bridgeBand or not rest then return end
    -- Ne garder que les bridges de notre faction (on ne peut pas whisper aux ennemis)
    local myBand = self:GetMyBand()
    if bridgeBand:match("_A$") ~= myBand:match("_A$") then return end
    local bands = {}
    for b in string.gmatch(rest, "[^,]+") do
        bands[#bands + 1] = b:match("^%s*(.-)%s*$") or b
    end
    if #bands > 0 then
        local seenAt = GetTime()
        bridges:Remember(sender, { bands = bands, time = seenAt }, seenAt)
    end
end

local R1_RELAY_COOLDOWN = 2
local R1_RELAY_MAX_PAYLOAD = 320
local lastR1RelayBySender = Overlord.Sync:NewBoundedSessionLedger(512, 0, 60)

-- R1 beta accepts bounded BF envelopes; legacy R1 remains restricted to SR/TV.
function Overlord.Sync:OnReceiveR1(sender, payload)
    if not payload then return end
    if #payload > R1_RELAY_MAX_PAYLOAD then return end
    local targetBand, replyTo, rest = strsplit(":", payload, 3)
    if not targetBand or not replyTo or not rest then return end
    if #targetBand > 80 or targetBand:find(":", 1, true) or not targetBand:match("_[AH]$") then return end
    if #replyTo < 2 or #replyTo > 50 or replyTo:find(":", 1, true)
        or not self:HasCompleteContributorIdentity(replyTo) then return end
    -- replyTo n'est pas libre : il doit etre l'identite WoW portee par le message addon direct.
    if not self.CaptureContributorMatchesSender
        or not self:CaptureContributorMatchesSender(replyTo, sender) then return end
    local innerType = rest:match("^([^:]+)")
    if innerType == "BF" and Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        if not IsCompatibleForeverBand(targetBand) then return end
        return Overlord.BetaNetwork:ReceiveFragment(rest:sub(4), sender, "WHISPER")
    end
    if not Overlord.InActiveFront then return end
    if innerType ~= "SR" and innerType ~= "TV" then return end
    local now = GetTime()
    local relayKey = tostring(sender) .. ":" .. innerType
    if lastR1RelayBySender:Get(relayKey, now, R1_RELAY_COOLDOWN) ~= nil then return end
    -- Trouver un ami BNet dans targetBand
    local gameAccountID = nil
    for gid, band in pairs(bnet_links) do
        if band == targetBand then
            gameAccountID = gid
            break
        end
    end
    if not gameAccountID then return end
    if not IsBNetGameAccountInCurrentRegion(gameAccountID) then return end
    if not lastR1RelayBySender:Remember(relayKey, now, now, false) then return end
    -- Envoyer R2 a notre ami BNet : il traitera la SR et repondra a replyTo en whisper
    local msg = "R2:" .. replyTo .. ":" .. rest
    if C_BattleNet and C_BattleNet.SendGameData then
        securecall(C_BattleNet.SendGameData, gameAccountID, PREFIX, msg)
    elseif BNSendGameData then
        securecall(BNSendGameData, gameAccountID, PREFIX, msg)
    end
end

-- ==================== Handlers entrants ====================

-- Un joueur a tue un ennemi (cross-faction : leaderboard melange = tetes a prix)
-- Cap pour les valeurs numeriques recues (anti-exploit : empeche l'injection de scores astronomiques)
local function SyncEpochToCampaignId(epoch)
    epoch = tonumber(epoch) or 0
    if epoch <= 0 then return 0 end
    if Overlord.TimestampToCampaignId then
        return Overlord:TimestampToCampaignId(epoch)
    end
    -- Repli UTC (date("!*t", ...)) aligne sur Core.lua : campaignId identique tous fuseaux NA.
    local t = date("!*t", epoch)
    if not t then return 0 end
    return (t.year * 10000) + (t.month * 100) + t.day
end

local function GetCurrentSyncCampaignStartAndId()
    local now = GetTime()
    if (priv.syncCampaignId or 0) > 0 and now - (priv.syncCampaignCacheAt or 0) < 1 then
        return priv.syncCampaignStart or 0, priv.syncCampaignId or 0, priv.syncCampaignWireEpoch or 0
    end
    local start = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and OverlordDB.lastResetTimestamp) or 0
    local wireEpoch = (Overlord.GetCurrentCampaignWireEpoch and Overlord:GetCurrentCampaignWireEpoch()) or start
    local id = SyncEpochToCampaignId(start)
    if id <= 0 then
        id = tonumber(OverlordDB and OverlordDB.campaignId) or 0
    end
    if id <= 0 then
        id = SyncEpochToCampaignId(OverlordDB and OverlordDB.lastResetTimestamp)
    end
    priv.syncCampaignCacheAt = now
    priv.syncCampaignStart = start
    priv.syncCampaignId = id
    priv.syncCampaignWireEpoch = wireEpoch
    return start, id, wireEpoch
end

-- Identite de campagne : on se cale sur la FENETRE hebdomadaire du reset officiel Blizzard
-- (region-wide coherent), pas sur le jour calendaire. Le jour (AAAAMMJJ) derivait selon le fuseau
-- cote NA (mardi continental vs mercredi Oceanique) et faisait rejeter les paquets entre clients
-- d'une meme region -> desync. Un epoch distant est valide s'il tombe dans la meme fenetre
-- [debut campagne ; debut + 1 semaine). 604800 = 7 jours. EU non affecte (reset deja coherent).
local function IsCurrentSyncCampaignEpoch(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local localStart = GetCurrentSyncCampaignStartAndId()
    if not localStart or localStart <= 0 then return false end
    if Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(epoch, localStart) then
        return true
    end
    return epoch >= localStart and epoch < localStart + 604800
end

function Overlord.Sync:IsCurrentCampaignEpoch(epoch)
    return IsCurrentSyncCampaignEpoch(tonumber(epoch))
end

-- Les messages de score modernes transportent deux epochs :
--   * remoteEpoch = fenetre calendrier officielle utilisee par le protocole ;
--   * BbucketEpoch = campagne reellement estampillee sur le bucket SavedVariables emetteur.
-- Exiger les deux ferme le cas d'un client qui a manque son wipe mais recalcule quand meme le
-- nouvel epoch officiel avant de rediffuser ses anciens totaux.
local function ParseLeaderboardBucketEpochToken(token)
    if type(token) ~= "string" then return nil end
    local epoch = token:match("^B(%d+)$")
    epoch = math.floor(tonumber(epoch) or 0)
    if epoch <= 0 then return nil end
    return epoch
end

local function CampaignEpochsMatch(a, b)
    if Overlord.CampaignEpochsMatch then
        return Overlord:CampaignEpochsMatch(a, b)
    end
    a = math.floor(tonumber(a) or 0)
    b = math.floor(tonumber(b) or 0)
    return a > 0 and b > 0 and math.abs(a - b) <= 3600
end

local function IsCurrentLeaderboardScoreBucket(remoteEpoch, bucketEpochToken)
    remoteEpoch = math.floor(tonumber(remoteEpoch) or 0)
    local bucketEpoch = ParseLeaderboardBucketEpochToken(bucketEpochToken)
    if not bucketEpoch or not IsCurrentSyncCampaignEpoch(remoteEpoch) then return false end
    local currentStart = GetCurrentSyncCampaignStartAndId()
    if not currentStart or currentStart <= 0 then return false end
    if not CampaignEpochsMatch(bucketEpoch, currentStart)
        or not CampaignEpochsMatch(bucketEpoch, remoteEpoch) then
        return false
    end
    -- Ne pas ecrire dans notre propre ancien bucket pendant la courte fenetre entre le reset
    -- Blizzard et le rattrapage local. CheckWeeklyReset/EnsureLeaderboardCampaignFresh le videra.
    if Overlord.Leaderboard and Overlord.Leaderboard.IsCurrentCampaignBucket
        and not Overlord.Leaderboard:IsCurrentCampaignBucket() then
        return false
    end
    return true
end

local function GetLocalLeaderboardBucketEpoch()
    local bucket = OverlordDB and OverlordDB.leaderboard
    local bucketEpoch = bucket and math.floor(tonumber(bucket.campaignStart) or 0) or 0
    local attestedEpoch = OverlordDB
        and math.floor(tonumber(OverlordDB.leaderboardScoreBucketEpoch) or 0) or 0
    if bucketEpoch <= 0 or attestedEpoch <= 0
        or not CampaignEpochsMatch(bucketEpoch, attestedEpoch) then
        return nil
    end
    return attestedEpoch
end

local function PersistSyncedZoneState(zone)
    if not zone or not zone.id or not OverlordDB or not OverlordDB.zones then return end
    local persisted = Overlord.CaptureLease and Overlord.CaptureLease.GetPersistableView
        and Overlord.CaptureLease:GetPersistableView(zone) or zone
    OverlordDB.zones[zone.id] = {
        status = persisted.status,
        killsCurrent = persisted.killsCurrent,
        allyKillsCurrent = persisted.allyKillsCurrent,
        enemyKillsCurrent = persisted.enemyKillsCurrent,
        holdTimeElapsed = persisted.holdTimeElapsed,
        capturedTime = persisted.capturedTime,
        updatedAt = persisted.updatedAt,
        owner = persisted.owner,
        previousOwner = persisted.previousOwner,
        assaultFromAvailable = persisted._assaultFromAvailable and true or nil,
    }
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

-- Un C/ZS ponctuel peut mettre a jour l'etat sous-jacent au login, mais ne doit
-- pas faire disparaitre SYNC sur une seule zone pendant que la carte globale
-- atomique n'est pas encore arrivee ou que la gate bornee n'a pas expire.
function Overlord.Sync:ClearPointSyncLoginQuarantine(zone)
    if not zone then return false end
    -- Un ZS in_progress ne certifie que l'overlay orange. Meme apres le timeout
    -- de login, son socle stable reste en quarantaine jusqu'a C/ZS final ou ZA
    -- global exact ; sinon un simple timer blanchirait une SavedVariable stale.
    if zone.status == "in_progress" and zone._remoteCaptureLease then return false end
    if Overlord.IsLoginCaptureSyncGateActive
        and Overlord:IsLoginCaptureSyncGateActive() then return false end
    zone._loginSyncUnconfirmed = nil
    return true
end

-- Le gagnant de l'election login a deja passe l'assemblage exact, les deux
-- identites distantes et le dry-run global (dont capitales/prerequis). Le
-- rejouer ensuite dans le merge historique zone par zone recreait des vetos
-- locaux APRES les premieres mutations : carte rouge appliquee, quelques zones
-- bleues encore en SYNC. Ce commit ne leve pas lui-meme la quarantaine ; tous
-- les flags sont retires ensemble une fois le lot entier applique.
function Overlord.Sync:ApplyLoginElectedZoneSnapshot(zoneId, ownerCode, owner, ts, ct)
    local zone = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
    local resolvedZone, resolvedFront
    if Overlord.Fronts then
        resolvedZone, resolvedFront = Overlord.Fronts:GetZone(zoneId)
    end
    zone = zone or resolvedZone
    if not zone or not zone._loginSyncUnconfirmed then return false end

    local keepLoginUnconfirmed = zone._loginSyncUnconfirmed
    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
        Overlord.CaptureLease:Complete(zone)
    end
    if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
        Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
    end
    -- ClearCaptureFinalUnattestedState nettoie normalement aussi ce flag. Ici
    -- on le conserve jusqu'au commit global, pour ne jamais rendre le lot
    -- partiellement visible si une erreur interrompt la boucle.
    zone._loginSyncUnconfirmed = keepLoginUnconfirmed
    zone.previousOwner = nil
    zone.isHolding = false
    zone.holdAuthorityLocal = nil
    zone.isContested = false
    zone.isPaused = false
    zone.holdTimeElapsed = 0
    zone.holdStartTime = nil
    zone.holdTimeRequired = 120
    zone._syncGateRemoteProgress = nil
    zone._syncGateRemoteProgressUntil = nil

    if ownerCode == "N" then
        zone.owner = nil
        zone.status = "locked"
        zone.capturedTime = nil
    else
        zone.owner = owner
        zone.status = "captured"
        zone.capturedTime = (ct and ct > 0) and ct or ts
    end
    zone.updatedAt = ts
    return true, resolvedFront and resolvedFront.id
end

local function ApplyInactiveFrontCapture(zoneId, newOwner, ts)
    local zone, zoneFront
    if Overlord.Fronts then zone, zoneFront = Overlord.Fronts:GetZone(zoneId) end
    if not zone or Overlord.Zones:GetZone(zoneId) then return false end
    if IsStaleCampaignTimestamp(ts) then return false end
    local loginUnconfirmed = Overlord.IsLoginZoneStateUnconfirmed
        and Overlord:IsLoginZoneStateUnconfirmed(zone)
    local stateUnconfirmed = loginUnconfirmed or zone._captureFinalUnattested
    local localFreshness = stateUnconfirmed and 0
        or math.max(zone.updatedAt or 0, zone.capturedTime or 0)
    if localFreshness > ts then return false end
    if localFreshness == ts and zone.owner and zone.owner ~= newOwner
        and Overlord.Sync:DeterministicCaptureTieOwner(zoneId, ts) ~= newOwner then
        return false
    end
    zone.owner = newOwner
    zone.status = "captured"
    zone.capturedTime = ts
    zone.updatedAt = ts
    zone.isHolding = false
    zone.isContested = false
    zone.isPaused = false
    zone.holdTimeElapsed = 0
    zone.holdStartTime = nil
    zone.holdTimeRequired = 120
    Overlord.Sync:ClearPointSyncLoginQuarantine(zone)
    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
        Overlord.CaptureLease:Complete(zone)
    end
    PersistSyncedZoneState(zone)
    -- La capture peut (de)bloquer des prerequis : rafraichir les statuts local-only du front.
    if zoneFront and Overlord.Zones.RefreshInactiveFrontAvailability then
        Overlord.Zones:RefreshInactiveFrontAvailability(zoneFront.id)
    end
    return true
end

-- Reprend une capture recue tardivement sans transformer l'interpolation locale
-- en donnee reseau. Exemple : un relais conserve hold=0, ts=t0 cinq minutes plus
-- tard ; l'affichage commence a 5:00, tandis que BuildSrZsPayload continue de
-- relayer le couple brut 0/t0. Le plancher est remplace a chaque vrai ZS, ce qui
-- permet encore un retour progressif si le capteur est conteste.
function Overlord.Sync:RebaseRemoteObserverDisplay(
    zone, holdTime, remoteTs, required, resetDisplay, relayedDisplayHold, relayedDisplayAt)
    if not zone then return 0 end
    local req = math.max(1, tonumber(required) or 120)
    local raw = math.max(0, tonumber(holdTime) or 0)
    local now = time()
    local displayHold = tonumber(relayedDisplayHold)
    local displayAt = tonumber(relayedDisplayAt)
    local projected
    if displayHold and displayAt and displayHold >= 0 and displayHold <= req
        and displayAt >= (tonumber(remoteTs) or 0) and displayAt <= now + 5 then
        -- Snapshot SR moderne : reprendre l'affichage deja projete par le relais,
        -- puis ajouter seulement le vrai temps de transport. Aucun double-age.
        projected = math.min(req, displayHold + math.max(0, now - displayAt))
    else
        -- Compat anciens ZS : leur seul ancrage est le timestamp de progression.
        local age = math.max(0, now - (tonumber(remoteTs) or now))
        projected = math.min(req, raw + age)
    end
    zone._observerDisplayNetworkFloor = projected
    local display = tonumber(zone._observerDisplayHold)
    if resetDisplay or not display or display < projected then
        zone._observerDisplayHold = projected
    end
    return projected
end

local function ApplyInactiveFrontZoneState(zoneId, status, kills, holdTime, owner, ts,
    _siegePhaseLegacy, holdReq, capturedTimeOverride, capturerName, progressDecision,
    preparedBase, forceConvergence, directTerminalRevert,
    relayedDisplayHold, relayedDisplayAt)
    local zone, zoneFront
    if Overlord.Fronts then zone, zoneFront = Overlord.Fronts:GetZone(zoneId) end
    if not zone or Overlord.Zones:GetZone(zoneId) then return false end
    local oldStatus, oldOwner = zone.status, zone.owner
    local loginUnconfirmed = Overlord.IsLoginZoneStateUnconfirmed
        and Overlord:IsLoginZoneStateUnconfirmed(zone)
    local stateUnconfirmed = loginUnconfirmed
        or (status == "captured" and zone._captureFinalUnattested)
        or forceConvergence
    local localTs = stateUnconfirmed and 0 or (zone.updatedAt or 0)
    if (status == "captured" or status == "in_progress") and not owner then return false end
    if (status == "captured" or status == "in_progress") and IsStaleCampaignTimestamp(ts) then return false end
    -- Ne pas ecraser une capture ou une zone deja capturee par un abandon ZS distant (revert observateur SR).
    if status == "available" or status == "locked" then
        if zone.status == "captured" and zone.owner then return false end
        if zone.capturedTime and zone.capturedTime > 0 then return false end
        -- Fin de timer : attendre un vrai captured/C, pas un abandon observateur.
        if zone.status == "in_progress" then
            local req = zone.holdTimeRequired or 120
            if (zone.holdTimeElapsed or 0) >= req - 1
                and not directTerminalRevert then return false end
        end
    end
    local remoteCapturedTime = tonumber(capturedTimeOverride) or 0
    if status == "captured" and remoteCapturedTime > 0
        and not stateUnconfirmed and (tonumber(zone.capturedTime) or 0) > 0 then
        localTs = tonumber(zone.capturedTime) or localTs
    end
    if ts <= localTs then
        local canHealCapturedTime = status == "captured"
            and owner and zone.owner == owner
            and remoteCapturedTime > (zone.capturedTime or 0)
        local canCaptureNeutralAtSameTs = status == "captured" and owner
            and not zone.owner and ts == localTs
        local canResolveCaptureTie = status == "captured" and owner
            and zone.owner and zone.owner ~= owner
            and remoteCapturedTime > 0
            and remoteCapturedTime == (tonumber(zone.capturedTime) or 0)
            and ts == localTs
            and Overlord.Sync:DeterministicCaptureTieOwner(zoneId, remoteCapturedTime) == owner
        local canCloseDirectLeaseAtSameTs = directTerminalRevert
            and status == "available" and ts == localTs
        if not canHealCapturedTime and not canCaptureNeutralAtSameTs
            and not canResolveCaptureTie and not canCloseDirectLeaseAtSameTs then return false end
    end
    if status == "in_progress" and progressDecision then
        if not Overlord.CaptureLease or not Overlord.CaptureLease.AdoptRemote
            or not Overlord.CaptureLease:AdoptRemote(
                zone, owner, capturerName, progressDecision, preparedBase) then
            return false
        end
    end
    zone.status = status
    zone.killsCurrent = kills
    -- Meme regle que OnReceiveZoneState : LOSING = ignorer, CAPTURING = math.max, observateur = direct.
    -- Front inactif = jamais holdAuthorityLocal, donc toujours observateur : valeur directe.
    if status == "in_progress" and owner == Overlord.PlayerFaction then
        if zone.holdAuthorityLocal and zone.isPaused then
            -- LOSING : ignorer le holdTime distant.
        elseif zone.holdAuthorityLocal then
            zone.holdTimeElapsed = math.max(holdTime or 0, zone.holdTimeElapsed or 0)
        else
            zone.holdTimeElapsed = holdTime or 0
        end
    else
        zone.holdTimeElapsed = holdTime
    end
    if ts > localTs then
        zone.updatedAt = ts
    end
    if status == "available" or status == "locked" then
        zone.isHolding = false
        zone.isContested = false
        zone.isPaused = false
        zone.holdStartTime = nil
        zone.holdTimeElapsed = 0
        local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
        zone.owner = fixedOwner or nil
        if fixedOwner then zone.status = "captured" end
    elseif owner then
        zone.owner = owner
    end
    if status == "captured" then
        zone.capturedTime = (remoteCapturedTime > 0) and remoteCapturedTime or ts
        zone.isHolding = false
        zone.isContested = false
        zone.isPaused = false
        zone.holdTimeElapsed = 0
        zone.holdStartTime = nil
        zone.holdTimeRequired = 120
    elseif status == "in_progress" and holdReq and holdReq > 0 then
        zone.holdTimeRequired = holdReq
    end
    if status == "in_progress" and progressDecision then
        Overlord.Sync:RebaseRemoteObserverDisplay(
            zone, holdTime, ts, zone.holdTimeRequired,
            oldStatus ~= status or oldOwner ~= owner,
            relayedDisplayHold, relayedDisplayAt)
    else
        zone._observerDisplayNetworkFloor = nil
    end
    Overlord.Sync:ClearPointSyncLoginQuarantine(zone)
    if status ~= "in_progress" and Overlord.CaptureLease
        and Overlord.CaptureLease.Complete then
        Overlord.CaptureLease:Complete(zone)
    end
    PersistSyncedZoneState(zone)
    -- Le changement d'etat peut (de)bloquer des prerequis : rafraichir les statuts local-only du front.
    if zoneFront and Overlord.Zones.RefreshInactiveFrontAvailability then
        Overlord.Zones:RefreshInactiveFrontAvailability(zoneFront.id)
    end
    return true
end

-- Format : name:zoneId (K moderne ci-dessous ; ce marqueur delimite aussi le handler ZS dans les tests)
-- Format moderne :
-- name:zoneId:totalKills:class:faction:epoch:guild:locale:guildAt:BbucketEpoch:level
-- Race : cache Communaute en priorite, LR dedie en fallback (K 13 champs encore accepte).
-- (7.5+) guild = guilde du joueur emetteur (autoritaire si owned). Retro : sans guild (6-7 champs).
-- Rejete si epoch absent ou hors campaignId courant.
-- Meme regle que LK : les anciens clients sans epoch ne peuvent plus
-- injecter des totaux de kills d'une ancienne campagne.
function Overlord.Sync:OnReceiveKill(payload, sender)
    if not payload then return end
    -- Anti-triche : expediteur deja en quarantaine (injection de kills detectee).
    if self.KillAntiSpoofIsBlacklisted and self:KillAntiSpoofIsBlacklisted(sender) then return end
    local rawName, zoneId, totalKills, class, faction, epochStr, guildTag, locTag,
        guildAtTag, raceTag, raceSexTag, bucketEpochToken, levelToken
    if self.ParseKillPayload then
        rawName, zoneId, totalKills, class, faction, epochStr, guildTag, locTag,
            guildAtTag, raceTag, raceSexTag, bucketEpochToken, levelToken =
            self:ParseKillPayload(payload)
    end
    if not rawName or rawName == "" or #rawName > 50 then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    -- Ancien format ou bucket emetteur encore estampille sur la semaine precedente : aucune
    -- mutation de score. Le rejet intervient avant les votes/metadonnees afin qu'un vieux client
    -- ne puisse pas non plus alimenter indirectement les preuves d'un paquet moderne.
    if not IsCurrentLeaderboardScoreBucket(remoteEpoch, bucketEpochToken) then return end
    -- Normalise le nom pour eviter doublons (pipe, apostrophes unicode, etc.)
    local playerName = self:NormalizeContributorFullName(rawName)
    if not playerName or playerName == "" then return end
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    -- Refuse les placeholders "Unknown" (API WoW sur unite non resolue) pour ne
    -- pas creer de lignes parasites dans le leaderboard via le reseau.
    if not self:AcceptSyncedContributorName(playerName) then return end
    if self.IsDeniedKillContributor and self:IsDeniedKillContributor(playerName) then return end
    if not self.IsEligibleKillContributorLevel
        or not self:IsEligibleKillContributorLevel(levelToken) then return end
    -- Anti-injection : un K transporte toujours le total du joueur qui l'emet
    -- (BroadcastKill = GetPlayerFullName). Sur un canal direct (non BNet), seul le
    -- proprietaire peut crediter son propre nom. BNet/Bridge ne peuvent pas crediter K.
    local isBNetRelay = type(sender) == "string" and sender:sub(1, 5) == "BNet-"
    -- Sans resolution fiable BNet -> personnage courant, un K BNet n'est pas une preuve
    -- d'identite. Les rattrapages cross-realm passent par les snapshots SR/LK.
    if isBNetRelay then return end
    local owned = not isBNetRelay and self:KillSyncSenderOwnsPlayer(sender, playerName)
    if not owned then
        if sender and sender ~= "" and self.KillAntiSpoofRecord then
            self:KillAntiSpoofRecord(sender)
        end
        return
    end
    local observedLevelEligible = self.IsObservedPlayerKillLevelEligible
        and self:IsObservedPlayerKillLevelEligible(playerName)
    if observedLevelEligible == false then return end
    -- K est deja lie au personnage emetteur par KillSyncSenderOwnsPlayer. Ses
    -- metadonnees valides sont donc applicables directement et deviennent
    -- relayables avec le meme score sur tous les clients.
    local classVerified = class and class ~= "" and class ~= "UNKNOWN"
        and self:IsValidCaptureClassToken(class) or false
    local localeVerified = locTag and locTag ~= ""
    local sanitized = self.SanitizeSyncedKillTotal
        and self:SanitizeSyncedKillTotal(totalKills)
    if not sanitized then return end
    totalKills = sanitized
    local guildRegister = tonumber(guildAtTag) and tonumber(guildAtTag) > 0
    local validGuild = guildTag and guildTag ~= ""
        and self.IsValidGuildSyncToken and self:IsValidGuildSyncToken(guildTag) or false
    if validGuild then guildRegister = true end
    if Overlord.Leaderboard.MergeLeaderboardKillMetadata then
        -- Une seule fusion O(1) et une seule invalidation pour toutes les
        -- metadonnees d'un K proprietaire. Les anciens setters reconstruisaient
        -- potentiellement l'index dedup a chaque champ pendant une rafale.
        Overlord.Leaderboard:MergeLeaderboardKillMetadata(
            playerName, levelToken,
            classVerified and class or nil,
            faction,
            localeVerified and locTag or nil,
            validGuild and guildTag or "",
            guildAtTag,
            guildRegister,
            raceTag,
            raceSexTag,
            0,
            true)
    end
    self:MaybeRequestMissingGuild(playerName)
    Overlord.Leaderboard:SetPlayerKills(playerName, totalKills, true)
    local killCreditNow = GetTime()
    recentKCredits:Remember(playerName:lower(),
        { ts = killCreditNow, skipZone = false }, killCreditNow, false)
    if Overlord.BountySync and Overlord.BountySync.ReconcileKillAfterBountyPayout then
        Overlord.BountySync:ReconcileKillAfterBountyPayout(playerName, totalKills)
    end
    -- Activite uniquement apres toutes les validations K (epoch, identite, anti-spoof, total).
    if Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(zoneId, playerName)
    end
    -- Le cache du ladder est deja invalide par les setters, mais un panneau ouvert
    -- n'a pas de ticker : demander explicitement le rendu de l'etat accepte.
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end
end

-- Recoit la race d'un contributeur kills (meta compacte, hors LK).
-- Format : name:raceFile:raceSex:epoch (raceSex 2=homme, 3=femme, 0=inconnu)
function Overlord.Sync:OnReceiveLeaderboardRace(payload, sender, channel)
    if not payload or not Overlord.Leaderboard or not Overlord.Leaderboard.SetPlayerRace then return end
    local rawName, raceFile, raceSex, epochStr, observedAt
    if self.ParseLeaderboardRacePayload then
        rawName, raceFile, raceSex, epochStr, observedAt =
            self:ParseLeaderboardRacePayload(payload)
    end
    if not rawName or not self:IsValidPlayerName(rawName)
        or not raceFile or raceFile == "" then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    local playerName = self:NormalizeContributorFullName(rawName)
    if not playerName or playerName == "" then return end
    if not self:AcceptSyncedContributorName(playerName) then return end
    if not self:AuthorizeLeaderboardSubject("LR", playerName, sender, channel) then return end
    -- LR est une replique de metadata du classement : SetPlayerRace normalise
    -- le token et departage les conflits par timestamp/ordre canonique.
    Overlord.Leaderboard:SetPlayerRace(playerName, raceFile, raceSex, true, observedAt, true)
    return true
end

-- Recoit un EK (Enemy Kill event) : un allie est mort et a identifie son tueur.
-- Dedup par (killerName + sender) pour eviter de compter le meme kill deux fois
-- (meme victime via plusieurs canaux) tout en acceptant deux kills differents
-- du meme tueur sur deux victimes distinctes.
function Overlord.Sync:OnReceiveEnemyKill(payload, sender)
    if not payload then return end
    -- Anti-triche : expediteur en quarantaine (flood EK = chemin additif non plafonne).
    if self.KillAntiSpoofIsBlacklisted and self:KillAntiSpoofIsBlacklisted(sender) then return end
    local playerName, class, faction, tsStr, zoneId, epochStr = strsplit(":", payload, 6)
    if not playerName or playerName == "" or #playerName > 50 then return end
    -- EK est additif : sans epoch, un vieux client peut gonfler la campagne courante.
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    -- Normalisation UTF-8 (apostrophes / tirets typographiques) pour que les clefs
    -- restent identiques entre pairs : sans ca, un nom comme "Vol'jin-Royaume" arrivait
    -- sous deux formes distinctes et creait des doublons dans le classement.
    playerName = self:NormalizeContributorFullName(playerName) or playerName
    -- Refuse les placeholders "Unknown" : un pair non patche aurait pu en emettre.
    if not self:AcceptSyncedContributorName(playerName) then return end

    -- Tueur local : kill deja credite par ProcessKill, ignorer EK entrant.
    if Overlord.Leaderboard and Overlord.Leaderboard.IsLocalDisplayName
        and Overlord.Leaderboard:IsLocalDisplayName(playerName) then
        return
    end

    -- EK ne mute plus aucun score : son seul effet est l'activite de front. Refuser
    -- les emetteurs non fiables avant toute reservation de dedup empeche un flood
    -- public de saturer le registre des evenements utiles.
    if not Overlord.FrontActivity
        or not Overlord.FrontActivity.IsTrustedEventSender
        or not Overlord.FrontActivity:IsTrustedEventSender(sender)
        or not Overlord.FrontActivity.RecordByZoneRef then return end

    local now = GetTime()
    -- Cle = tueur + victime (sender) pour accepter plusieurs kills du meme tueur
    local senderKey = sender and sender:lower() or "unknown"
    local key = playerName:lower() .. ":" .. senderKey
    if recentEKs:Get(key, now) ~= nil then return end
    if not recentEKs:Remember(key, now, now, false) then return end
    -- EK est une preuve de combat non autoritaire pour le score, mais valide pour le panneau.
    Overlord.FrontActivity:RecordByZoneRef(zoneId, playerName, tsStr)
    -- EK entrant est volontairement non autoritaire : pas de leaderboard, pas de prime,
    -- pas de metadonnees et pas de compteurs zone depuis une simple affirmation de victime.
    return
end

-- Dedup des messages "C" : BroadcastCapture envoie via RAID/PARTY + canal + BNet,
-- le recepteur peut donc recevoir 2-3 copies du meme evenement. Sans dedup, chaque
-- copie incremente captureCount et gonfle le classement.
-- Chat capture : dedup par (zone, faction, capturedTime) + fenetre courte (C + ZS captured).
local function AppendShardTagToPlayerName(nameHint, shardHint)
    if not nameHint or nameHint == "" then return nameHint end
    local sid = tonumber(shardHint)
    local shardMod = Overlord.Shard
    if not sid and shardMod and shardMod.ResolveKnownShardPlayer then
        local _, resolvedSid = shardMod:ResolveKnownShardPlayer(nameHint, true)
        sid = resolvedSid
        if not sid then
            _, sid = shardMod:ResolveKnownShardPlayer(nameHint, false)
        end
    end
    if not sid then return nameHint end
    local tag = L and L.SHARD_ALERT_TAG
    if tag then
        return nameHint .. string.format(tag, tostring(sid))
    end
    return nameHint .. " #" .. tostring(sid)
end

local function RememberCapturerShard(capturerName, shardId)
    shardId = tonumber(shardId)
    if not capturerName or capturerName == "" or not shardId then return end
    if Overlord.Shard and Overlord.Shard.SetPlayerShard then
        Overlord.Shard:SetPlayerShard(capturerName, shardId)
    end
end

local function LearnCapturerShardFromZsSender(sender, capturerName)
    if not sender or not capturerName or capturerName == "" then return end
    local sync = Overlord.Sync
    if not sync or not sync.GetCaptureContributorDedupKey then return end
    local sdk = sync:GetCaptureContributorDedupKey(sender)
    local cdk = sync:GetCaptureContributorDedupKey(capturerName)
    if not sdk or not cdk or sdk:lower() ~= cdk:lower() then return end
    local shardMod = Overlord.Shard
    if not shardMod or not shardMod.GetKnownPlayerShard then return end
    local sid = shardMod:GetKnownPlayerShard(sender)
    if sid then
        RememberCapturerShard(capturerName, sid)
    end
end

local function RememberCaptureChatTimestamp(tsKey, now)
    if priv.captureChatDedupTs[tsKey] ~= nil then return false end
    if priv.captureChatDedupTsCount >= priv.captureChatDedupTsMax then
        if now < (tonumber(priv.captureChatDedupTsBlockedUntil) or 0) then return false end
        local count, earliestExpiry = 0, math.huge
        for key, seenAt in pairs(priv.captureChatDedupTs) do
            seenAt = tonumber(seenAt) or 0
            if now - seenAt > 600 then
                priv.captureChatDedupTs[key] = nil
            else
                count = count + 1
                earliestExpiry = math.min(earliestExpiry, seenAt + 600)
            end
        end
        priv.captureChatDedupTsCount = count
        if count >= priv.captureChatDedupTsMax then
            priv.captureChatDedupTsBlockedUntil = earliestExpiry + 0.01
            return false
        end
        priv.captureChatDedupTsBlockedUntil = 0
    end
    priv.captureChatDedupTs[tsKey] = now
    priv.captureChatDedupTsCount = priv.captureChatDedupTsCount + 1
    return true
end

local function PrintCaptureChatOnce(zone, newOwner, capturerName, captureTs)
    if not zone or not zone.id or not newOwner then return end
    local now = GetTime()
    local key = zone.id .. ":" .. newOwner
    local dedupSec = zone.isCapital and priv.captureChatDedupCapitalSec or priv.captureChatDedupSec
    captureTs = tonumber(captureTs) or tonumber(zone.capturedTime) or 0
    if captureTs > 0 then
        local tsKey = key .. ":" .. captureTs
        if not RememberCaptureChatTimestamp(tsKey, now) then return end
    end
    local last = priv.captureChatDedup[key]
    if last and now - last < dedupSec then return end
    priv.captureChatDedup[key] = now
    -- `key` = zone connue + faction valide : cardinalite structurellement bornee
    -- a deux fois le nombre fixe de zones, sans besoin de rescanner a chaque chat.

    if newOwner == Overlord.PlayerFaction then
        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.SYNC_CAPTURED_FRIENDLY,
            zone.name, Overlord.Zones:GetFactionName()))
    else
        -- Affiche le nom du capteur (avec royaume) si disponible
        if capturerName and capturerName ~= "" then
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.SYNC_CAPTURED_ENEMY_BY,
                zone.name, Overlord.Zones:GetEnemyFactionName(),
                AppendShardTagToPlayerName(capturerName, zone and zone.zsRelayCapturerShard)))
        else
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.SYNC_CAPTURED_ENEMY,
                zone.name, Overlord.Zones:GetEnemyFactionName()))
        end
    end
end

local function WasOurZoneBeforeEnemyCapture(oldStatus, oldOwner, oldPreviousOwner, newOwner)
    if not newOwner or not Overlord.PlayerFaction or not Overlord.Zones then return false end
    if newOwner ~= Overlord.Zones:GetEnemyFaction() then return false end
    -- Pendant un in_progress ennemi, owner vaut deja l'ennemi ; previousOwner garde le vrai defenseur.
    return oldOwner == Overlord.PlayerFaction
        or (oldStatus == "in_progress" and oldPreviousOwner == Overlord.PlayerFaction)
end

-- Rejette un ZS/C ennemi anterieur (ou « tag deja fini » a la meme seconde) qui ecraserait
-- notre zone deja captured. Pas de fenetre aveugle : ts > capturedTime = recap legitime conservee.
-- holdTime bas a ts == capturedTime = tag qui demarre (rare, meme seconde) - on laisse passer.

local function ShouldRejectStaleEnemyAttackOnOurCapture(zone, status, owner, ts, holdTime, opts)
    if not zone or not ts or ts <= 0 then return false end
    if not Overlord.PlayerFaction or not Overlord.Zones then return false end
    local ef = Overlord.Zones:GetEnemyFaction()
    if not ef or owner ~= ef then return false end

    opts = opts or {}
    local defenderOwner = opts.defenderOwner or zone.owner
    local defenderStatus = opts.defenderStatus or zone.status
    local capturedAt = opts.capturedTime or zone.capturedTime or 0

    if defenderOwner ~= Overlord.PlayerFaction or capturedAt <= 0 then return false end
    local captureConfirmed = defenderStatus == "captured"
        or (defenderStatus ~= "in_progress" and capturedAt > 0)
    if not captureConfirmed then return false end
    if status ~= "in_progress" and status ~= "captured" then return false end

    -- Recap reelle : evenement reseau strictement apres notre capture confirmee.
    if ts > capturedAt then return false end

    if ts < capturedAt then return true end

    -- ts == capturedAt (time() a la seconde)
    if status == "captured" then
        return true
    end

    local req = zone.holdTimeRequired or 120
    local ht = holdTime or 0
    local staleHoldCutoff = math.min(priv.staleSameSecHoldSec, math.max(req - 15, 10))
    return ht >= staleHoldCutoff
end

local function IsLocalAuthoritativeCapture(zone)
    return zone
        and zone.isHolding
        and zone.holdAuthorityLocal
        and zone.status == "in_progress"
        and zone.owner == Overlord.PlayerFaction
end

local function NormalizeZsCapturerName(name)
    if not name or name == "" then return nil end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t >= 2 and #t <= 50 then return t end
    return nil
end

local function GetSelfCapturerFullName()
    return Overlord.Sync and Overlord.Sync.GetPlayerFullName and Overlord.Sync:GetPlayerFullName() or nil
end

-- Geometrie du disque uniquement (monture / furtif inclus) : co-presence physique sur le point.
local function IsPlayerPhysicallyOnCaptureDisk(zone)
    if not zone or not Overlord.Zones or not Overlord.Zones.GetCurrentPlayerZone then return false end
    local pz = Overlord.Zones:GetCurrentPlayerZone()
    return pz and pz.id == zone.id
end

-- True si nous capturons encore sur le disque (isHolding ou presence physique active).
local function AllyStillCapturingOnDisk(zone)
    if not zone or zone.status ~= "in_progress" or zone.owner ~= Overlord.PlayerFaction then
        return false
    end
    if zone.isHolding then return true end
    if not Overlord.Zones or not Overlord.Zones.GetCurrentPlayerZone then return false end
    local pz = Overlord.Zones:GetCurrentPlayerZone()
    if not pz or pz.id ~= zone.id then return false end
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync
        and Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync() then
        return false
    end
    return true
end

-- Demande de confirmation ZS alliee in_progress : pas si nous sommes absents du disque apres /reload
-- ou si l'echo ZS pre-reload porte notre propre nom sans capteur actif.
local function CanAllyInProgressZsRequestConfirmation(zone, zsCapturerName)
    if not zone or zone.status ~= "in_progress" or zone.owner ~= Overlord.PlayerFaction then
        return false
    end
    if zone.isHolding and zone.holdAuthorityLocal then return false end
    if zone._restoredInProgress then return false end
    -- Sur le disque sans participer (monture / furtif) : attendre le message C.
    -- Co-captureur actif sans autorite : demander un SR reste lecture seule et evite 00:00 orange.
    if IsPlayerPhysicallyOnCaptureDisk(zone) and not (zone.isHolding and not zone.holdAuthorityLocal) then
        return false
    end
    local selfName = GetSelfCapturerFullName()
    local official = NormalizeZsCapturerName(zsCapturerName)
        or NormalizeZsCapturerName(zone.zsOfficialCapturerName)
    if official and selfName and official == selfName then
        return false
    end
    return true
end

-- Ferme immediatement le bail quand un etat ZS terminal est accepte. Attendre le
-- sweep periodique laisserait une courte fenetre ou SaveState persisterait la
-- base du bail au lieu de la capture finale.
local function CompleteAcceptedZsTerminal(zone, status)
    if not zone or (status ~= "captured" and status ~= "available" and status ~= "locked") then
        return false
    end
    zone.holdTimeRequired = 120
    zone._observerDisplayNetworkFloor = nil
    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
        Overlord.CaptureLease:Complete(zone)
    end
    return true
end

-- Efface le relais quand l'etat ZS est terminal ou que c'est notre vague de capture.
local function ClearZsRelayAfterZsApply(zone, status, owner)
    if not zone then return end
    if status == "captured" or status == "available" or status == "locked" then
        CompleteAcceptedZsTerminal(zone, status)
        zone.zsRelayCapturerName = nil
        zone.zsRelayCapturerShard = nil
        zone.zsOfficialCapturerName = nil
        zone._zsOfficialCapturerSeenAt = nil
    elseif status == "in_progress" and owner == Overlord.PlayerFaction then
        zone.zsRelayCapturerName = nil
        zone.zsRelayCapturerShard = nil
    end
end

local lastObserverCaptureConfirmationAt = 0

local function RequestObserverCaptureConfirmation(zone)
    if not zone or not Overlord.Sync or not Overlord.Sync.SendSyncRequest then return end
    if Overlord.InstanceSuspended then return end
    local now = GetTime()
    local zoneLast = zone._observerCaptureConfirmPollAt or 0
    if now - zoneLast < TUNING.OBSERVER_CAPTURE_CONFIRMATION_COOLDOWN then return end
    if now - lastObserverCaptureConfirmationAt < TUNING.OBSERVER_CAPTURE_CONFIRMATION_COOLDOWN then return end
    zone._observerCaptureConfirmPollAt = now
    lastObserverCaptureConfirmationAt = now
    Overlord.Sync:SendSyncRequest({ territorialOnly = true })
    -- Gros event cross-faction : SendSyncRequest evite la communaute par defaut.
    -- Ici le timer est deja au seuil, donc on fait un petit SR cible pour obtenir
    -- un C / ZS captured reel au lieu de laisser l'observateur orange longtemps.
    if Overlord.InActiveFront and Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
        and Overlord.Sync.BroadcastToCommunity then
        Overlord.Sync:BroadcastToCommunity("SR", SRPayload("T"), 6, 0.35)
    end
end

-- Observateur distant seulement (pas isHolding) : ZS a 100 % sans message C recu.
-- Ne pas promouvoir localement : demander une confirmation reseau (C, ZS captured, ZA/SR).
local function MaybeRequestAllyCaptureConfirmationFromZs(zone, owner, holdTime, autoReq, syncGateRemoteProgress, zsCapturerName)
    if not zone or not owner or owner ~= Overlord.PlayerFaction then return false end
    if (holdTime or 0) < (autoReq or 120) then return false end
    if zone.isHolding and zone.holdAuthorityLocal then return false end
    -- Monte sur le disque : isHolding reste false mais ce n'est pas un observateur distant.
    if IsPlayerPhysicallyOnCaptureDisk(zone) and not (zone.isHolding and not zone.holdAuthorityLocal) then
        return false
    end
    if syncGateRemoteProgress then return false end
    if not CanAllyInProgressZsRequestConfirmation(zone, zsCapturerName) then return false end
    RequestObserverCaptureConfirmation(zone)
    return true
end

-- Bloque les confirmations/alertes ennemies fantomes quand nous sommes l'assaillant sur le point
-- (faux positifs chat « prise par l'ennemi » avant notre propre message de capture locale).
local function ShouldSkipEnemyCaptureConfirmation(zone, oldStatus, oldOwner)
    if not zone or not Overlord.PlayerFaction then return false end
    if IsLocalAuthoritativeCapture(zone) or AllyStillCapturingOnDisk(zone) then
        return true
    end
    if oldStatus == "in_progress" and oldOwner == Overlord.PlayerFaction
        and zone.isHolding then
        return true
    end
    if oldStatus == "available" or oldStatus == "locked" then
        if Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone then
            local pz = Overlord.Zones:GetCurrentPlayerZone()
            if pz and pz.id == zone.id then return true end
        end
    end
    return false
end

-- Alerte chat quand l'ennemi capture une zone : perte, prise depuis « disponible », ou sync ZA/ZS sans C.
local function ShouldAlertEnemyZoneCapture(oldStatus, oldOwner, oldPreviousOwner, newOwner, zone)
    if not newOwner or not Overlord.PlayerFaction or not Overlord.Zones then return false end
    local enemy = Overlord.Zones:GetEnemyFaction()
    if newOwner ~= enemy then return false end
    if zone and ShouldSkipEnemyCaptureConfirmation(zone, oldStatus, oldOwner) then return false end
    if oldStatus == "captured" and oldOwner == newOwner then return false end
    if WasOurZoneBeforeEnemyCapture(oldStatus, oldOwner, oldPreviousOwner, newOwner) then return true end
    if oldStatus == "available" or oldStatus == "locked" then return true end
    if (not oldOwner or oldOwner == "") and oldStatus ~= "captured" then return true end
    if oldStatus == "in_progress" and oldOwner == newOwner and not oldPreviousOwner then return true end
    return false
end

-- Capteur officiel (9e champ ZS) : autre allie sur le meme point.
-- Compare par cle dedup (pas seulement ==) : un nom relaye par un tiers (ex. bonus defensif
-- Barricade de l'ennemi qui repasse notre propre nom) peut porter une variante Nom / Nom-Royaume
-- de NOUS-MEME si notre royaume n'etait pas encore resolu au tout premier ZS envoye. Sans cette
-- tolerance, on se croit "un autre allie" et on se retire a tort notre propre autorite locale
-- (holdAuthorityLocal), ce qui gele la decroissance hors-zone (reservee au capteur officiel).
local function CapturerNameMatchesSelf(name, selfName)
    if not name or name == "" or not selfName or selfName == "" then return false end
    if name == selfName then return true end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local a = sync:GetCaptureContributorDedupKey(name)
        local b = sync:GetCaptureContributorDedupKey(selfName)
        return a ~= nil and b ~= nil and a == b
    end
    return false
end

-- La presence physique reste necessaire pour les effets irreversibles (Barricade,
-- credit gameplay). L'election reversible du timer accepte aussi un ZS direct :
-- son sender WoW est deja lie au capteur, a la faction et a la vague validee.
function Overlord.Sync:HasIndependentCaptureProgressEvidence(progressDecision)
    return progressDecision and progressDecision.physicalPresenceGuid
        and progressDecision.physicalPresenceGuid ~= "" or false
end

-- Une alerte chat est reversible et ne doit pas attendre un quorum. Le ZS direct
-- est deja lie a l'identite addon du capteur et sa faction a ete verifiee par
-- CaptureLease:ValidateProgress. Les preuves independantes restent obligatoires
-- pour l'autorite locale et les effets gameplay irreversibles.
function Overlord.Sync:CanEmitEnemyCaptureAlert(progressDecision)
    if not progressDecision then return false end
    if progressDecision.direct == true then return true end
    return self:HasIndependentCaptureProgressEvidence(progressDecision)
end

-- Un ZS relaye ne decide plus l'etat : demander directement la photo territoriale
-- au capteur annonce. Le cooldown et la borne evitent tout fan-out/stutter lors
-- d'une rafale de relais communautaires.
function Overlord.Sync:RequestDirectCaptureOriginSnapshot(originName, zoneId)
    local target = NormalizeZsCapturerName(originName)
    if not target or not self:IsValidWhisperTarget(target) then return false end
    local now = GetTime()
    local key = target:lower() .. "\31" .. tostring(zoneId or "")
    local last = priv.captureOriginSrLast[key]
    if last and now - last < 20 then return false end
    local count, oldestKey, oldestAt = 0, nil, nil
    for existingKey, seenAt in pairs(priv.captureOriginSrLast) do
        if now - seenAt > 120 then
            priv.captureOriginSrLast[existingKey] = nil
        else
            count = count + 1
            if not oldestAt or seenAt < oldestAt then
                oldestKey, oldestAt = existingKey, seenAt
            end
        end
    end
    if count >= 64 and oldestKey then priv.captureOriginSrLast[oldestKey] = nil end
    priv.captureOriginSrLast[key] = now
    return self:SendWhisper("SR", SRPayload("T"), target) == true
end

function Overlord.Sync:ShouldDeferToRemoteAllyCapturer(zone, zsCapturerName, progressDecision)
    if not zone then return false end
    if not progressDecision or (progressDecision.direct ~= true
        and not self:HasIndependentCaptureProgressEvidence(progressDecision)) then return false end
    local selfName = GetSelfCapturerFullName()
    if not selfName or selfName == "" then return false end

    local official = zone.zsOfficialCapturerName
    if official and official ~= "" and CapturerNameMatchesSelf(official, selfName) then
        return false
    end

    local remote = NormalizeZsCapturerName(zsCapturerName)
    if remote and not CapturerNameMatchesSelf(remote, selfName) then
        return true
    end

    if official and official ~= "" and not CapturerNameMatchesSelf(official, selfName) then
        return true
    end

    return false
end

function Overlord.Sync:StoreAllyOfficialCapturerFromZs(
    zone, status, owner, zsCapturerName, sender, zsCapturerShard, progressDecision)
    if not zone or status ~= "in_progress" or owner ~= Overlord.PlayerFaction then return end
    if not progressDecision or (progressDecision.direct ~= true
        and not self:HasIndependentCaptureProgressEvidence(progressDecision)) then return end
    local n = NormalizeZsCapturerName(zsCapturerName)
    if n then
        zone.zsOfficialCapturerName = n
        local sid = tonumber(zsCapturerShard)
        if sid then
            RememberCapturerShard(n, sid)
        end
        local s = NormalizeZsCapturerName(sender)
        local senderMatches = s == n
        if not senderMatches and s and Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
            local sk = Overlord.Sync:GetCaptureContributorDedupKey(s)
            local nk = Overlord.Sync:GetCaptureContributorDedupKey(n)
            senderMatches = sk and nk and sk == nk
        end
        if senderMatches then
            zone._zsOfficialCapturerSeenAt = GetTime()
        end
    end
end

-- Late joiner / co-captureur (monture incluse) : aligner le timer meme si updatedAt local est en avance.
-- Doit aussi basculer status -> in_progress : sinon carte bleue/rouge + timer reseau sans orange.
local function TryAlignAllyCoCaptureTimer(zone, status, owner, holdTime, ts,
    zsCapturerName, sender, zsCapturerShard, progressDecision, adoptRemote)
    if status ~= "in_progress" or owner ~= Overlord.PlayerFaction then return false end
    if not Overlord.Sync:ShouldDeferToRemoteAllyCapturer(
        zone, zsCapturerName, progressDecision) then return false end
    local remoteHold = holdTime or 0
    if zone.status == "in_progress" then
        if remoteHold <= (zone.holdTimeElapsed or 0) then return false end
    elseif remoteHold <= 0 then
        return false
    end
    -- Ne pas regresser une capture confirmee avec un ZS in_progress plus ancien.
    if Overlord.Zones and Overlord.Zones.IsNetworkConfirmedCapture
        and Overlord.Zones:IsNetworkConfirmedCapture(zone) and zone.owner == owner then
        local confirmTs = math.max(zone.capturedTime or 0, zone.updatedAt or 0)
        if ts and confirmTs > 0 and ts <= confirmTs then
            return false
        end
    end
    -- Toutes les gardes sont passees ; materialiser le bail juste avant la
    -- premiere mutation. Un paquet rejete ne doit jamais toucher le snapshot.
    if adoptRemote and not adoptRemote() then return false end
    if zone.status ~= "in_progress" then
        if not zone.previousOwner then
            zone.previousOwner = zone.owner
        end
        zone.status = "in_progress"
        zone.owner = owner
    end
    zone.holdAuthorityLocal = nil
    zone.holdTimeElapsed = remoteHold
    if ts and ts > 0 then
        zone.updatedAt = ts
    end
    if zone.isHolding then
        zone.holdStartTime = GetTime() - remoteHold
    end
    Overlord.Sync:StoreAllyOfficialCapturerFromZs(
        zone, status, owner, zsCapturerName, sender, zsCapturerShard, progressDecision)
    return true
end

-- CR/CA et GR/GY : voir SyncResolution.lua (limite 200 locals WoW par chunk).

-- Suivi des alertes "ennemi capture" par zone.
-- L'INFLATION_BUFFER peut bloquer la mise a jour d'etat (anti-gonflement de timestamp)
-- mais l'alerte chat doit quand meme partir une fois par tentative de capture ennemie.
-- Cooldown filet : en conteste, les ZS alternent souvent A/H (timestamps qui montent) et
-- rouvrent la condition "nouvelle capture" ; le flag enemyWasPushing supprime le gros du spam.

function Overlord.Sync:BumpPrereqChainGrace(zoneId)
    if not zoneId then return end
    priv.prereqGraceUntil[zoneId] = GetTime() + priv.prereqGraceSec
end

-- true = ne pas invalider la capture in_progress pour prerequis casses (vue locale en retard).
function Overlord.Sync:ShouldDeferPrereqChainInvalidate(zoneId)
    local u = priv.prereqGraceUntil[zoneId]
    if not u then return false end
    if GetTime() >= u then
        priv.prereqGraceUntil[zoneId] = nil
        return false
    end
    return true
end

-- Memorise le nom capteur ennemi recu dans un ZS (9e champ) pour relais allie sans isHolding.
local function StoreZsRelayCapturerFromZs(zone, status, owner, zsCapturerName, zsCapturerShard)
    if not zone or not Overlord.PlayerFaction then return end
    if status == "in_progress" and owner and owner ~= Overlord.PlayerFaction
        and zsCapturerName and zsCapturerName ~= "" then
        local tn = zsCapturerName:match("^%s*(.-)%s*$") or ""
        if #tn >= 2 and #tn <= 50 then
            zone.zsRelayCapturerName = tn
            local sid = tonumber(zsCapturerShard)
            if sid then
                zone.zsRelayCapturerShard = sid
                RememberCapturerShard(tn, sid)
            end
        end
    end
end

local function MaybeRequestEnemyCaptureConfirmationFromZs(zone, owner, holdTime, required, oldStatus, oldOwner)
    if not zone or not owner or owner == Overlord.PlayerFaction then return end
    if (holdTime or 0) < (required or 120) then return end
    if ShouldSkipEnemyCaptureConfirmation(zone, oldStatus, oldOwner) then return end
    RequestObserverCaptureConfirmation(zone)
end

-- Nom affiche alertes : paquet courant, sinon dernier nom ennemi relais valide.
local function EffectiveCapturerNameForAlert(zone, zsCapturerName)
    local z = zsCapturerName and zsCapturerName:match("^%s*(.-)%s*$") or ""
    if z ~= "" and #z >= 2 and #z <= 50 then return z end
    local r = zone and zone.zsRelayCapturerName
    if r and type(r) == "string" then
        local t = r:match("^%s*(.-)%s*$") or ""
        if t ~= "" and #t >= 2 and #t <= 50 then return t end
    end
    return ""
end

-- Interpolation observateur a 100% sans ZS captured/C : NE TRANCHE PAS la verite gameplay.
-- Demande un SR poll agressif pour obtenir la confirmation reseau.
-- L'UI continue d'afficher le timer cappe a holdTimeRequired (GetObserverHoldTimeElapsed).
-- La capture reelle n'arrive que via un vrai C, ZS captured, ou reponse SR.
function Overlord.Sync:RequestObserverCaptureConfirmationIfComplete(zone)
    if not zone or zone.status ~= "in_progress" or zone.isHolding then return end
    if not Overlord.Zones or not Overlord.Zones.GetObserverHoldTimeElapsed then return end
    local elapsed = Overlord.Zones:GetObserverHoldTimeElapsed(zone)
    local req = zone.holdTimeRequired or 120
    local stored = tonumber(zone.holdTimeElapsed) or 0
    if math.max(elapsed, stored) < req then return end
    -- Timer a 100% : demander la verite au reseau (SR) au lieu de trancher localement.
    RequestObserverCaptureConfirmation(zone)
end

-- Affiche l'alerte chat ENEMY_CAPTURING si le cooldown par zone est ecoule.
-- capturerName : nom du capteur (avec royaume) si disponible
-- waveTs : timestamp de la vague (ZS) - dedup multi-relais (canal + whispers + holdTime variant)
local function TryPrintEnemyCapturingAlert(zone, capturerName, waveTs)
    if not zone or not zone.id then return end
    local efAlert = Overlord.Zones:GetEnemyFaction()
    -- Plus de vague ennemie sur cette zone : reinitialiser (sinon blocage apres inflation seule, etc.)
    if zone.status ~= "in_progress" or zone.owner ~= efAlert then
        priv.enemyAlertEmitted[zone.id] = nil
        priv.enemyAlertSkipUntil[zone.id] = nil
    elseif Overlord.Shard and Overlord.Shard.ScheduleAutoPromptOnZoneEntry then
        -- Push ennemi recu alors que le joueur DEFEND deja le point : le popup shard n'etait
        -- arme qu'a l'entree du disque (ZoneControl), donc un defenseur en place ne recevait
        -- jamais l'invite cross-shard. Re-armer ici ; les gates internes (cooldown 60 s/zone,
        -- capteur resolu, shard connue) empechent tout spam, et FinishAutoPromptOnZoneEntry
        -- verifie que le joueur est bien dans cette zone avant d'ouvrir le popup.
        local cz = Overlord.Zones.GetCurrentPlayerZone and Overlord.Zones:GetCurrentPlayerZone()
        if cz and cz.id == zone.id then
            Overlord.Shard:ScheduleAutoPromptOnZoneEntry(zone)
        end
    end
    waveTs = tonumber(waveTs) or zone.updatedAt or 0
    local waveKey = zone.id .. ":" .. tostring(waveTs)
    if waveTs > 0 and priv.enemyAlertWaveKey[waveKey] then
        return
    end
    local nowAlert = GetTime()
    local skipUntil = priv.enemyAlertSkipUntil[zone.id]
    if skipUntil and nowAlert < skipUntil then
        return
    end
    if priv.enemyAlertEmitted[zone.id] then
        return
    end
    local lastAlert = priv.enemyAlertLast[zone.id]
    -- nil signifie qu'aucune alerte n'a encore ete emise dans cette session.
    -- Ne jamais transformer ce nil en t=0 : cela muselait tous les tags ennemis
    -- recus pendant les 90 premieres secondes apres login ou /reload.
    if lastAlert and nowAlert - lastAlert < priv.enemyAlertCooldown then return end
    priv.enemyAlertLast[zone.id] = nowAlert
    priv.enemyAlertEmitted[zone.id] = true
    if waveTs > 0 then
        priv.enemyAlertWaveKey[waveKey] = nowAlert
    end
    -- Affiche le nom du capteur (avec royaume) si disponible
    local whereLabel = Overlord.Zones:GetZoneCaptureAlertLocationLabel(zone)
    if capturerName and capturerName ~= "" then
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.ENEMY_CAPTURING_BY,
            whereLabel, Overlord.Zones:GetEnemyFactionName(),
            AppendShardTagToPlayerName(capturerName, zone and zone.zsRelayCapturerShard)))
    else
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.ENEMY_CAPTURING,
            whereLabel, Overlord.Zones:GetEnemyFactionName()))
    end
end

-- Remet a zero le cooldown d'alerte ennemie pour une zone.
-- Doit etre appele des que notre faction recapture la zone (localement ou via sync),
-- sinon un retag ennemi immediat dans la fenetre de cooldown serait silencieux (ni chat, ni orange).
function Overlord.Sync:ResetEnemyCaptureAlert(zoneId)
    if not zoneId then return end
    priv.enemyAlertLast[zoneId] = nil
    priv.enemyAlertSkipUntil[zoneId] = nil
    priv.enemyAlertEmitted[zoneId] = nil
    local prefix = zoneId .. ":"
    for k in pairs(priv.enemyAlertWaveKey) do
        if k:sub(1, #prefix) == prefix then
            priv.enemyAlertWaveKey[k] = nil
        end
    end
end

-- Fin locale d'un bail distant : autorise une nouvelle vague a emettre son alerte,
-- sans effacer le cooldown global anti-spam de la zone.
function Overlord.Sync:OnRemoteCaptureLeaseEnded(zoneId)
    if not zoneId then return end
    priv.enemyAlertEmitted[zoneId] = nil
    priv.enemyAlertSkipUntil[zoneId] = nil
end

-- Migration/nettoyage des anciens finals visuels deja presents en SavedVariables.
-- Aucun nouveau chemin reseau ne cree cet etat depuis le retour mono-source.
local function ClearVisualFinalPending(zone, originName, waveId, terminalTs, certifiedOverride)
    if not zone or not zone._captureFinalUnattested then return false end
    local originKey = Overlord.Sync:GetCaptureContributorDedupKey(originName)
    local sameWave = zone._captureFinalUnattestedOriginKey == originKey
        and zone._captureFinalUnattestedWaveId == waveId
    local pendingAt = tonumber(zone._captureFinalUnattestedAt) or 0
    local supersedes = tonumber(terminalTs) and tonumber(terminalTs) >= pendingAt
    if not sameWave and not supersedes and not certifiedOverride then return false end
    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    zone._captureFinalConfirmedBase = nil
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    return true
end

-- Une preuve finale ne devient non rejouable qu'apres convergence effective de
-- l'etat canonique. Ce helper est donc appele uniquement apres mutation acceptee
-- ou constat idempotent d'un etat deja au moins aussi recent.
function Overlord.Sync:FinalizeAcceptedCaptureFinal(zone, zoneId, originName, waveId,
    terminalTs, deliveryDedup, deliveryKey)
    if not zone then return false end
    -- Un final ponctuel peut corriger le socle pendant le login, mais il ne doit
    -- pas faire sortir cette seule zone de la quarantaine visuelle. Le lot ZA
    -- global la levera atomiquement apres sa fenetre de stabilisation.
    local preserveLoginQuarantine = zone._loginSyncUnconfirmed == true
        and Overlord.IsLoginCaptureSyncGateActive
        and Overlord:IsLoginCaptureSyncGateActive()
    local hadVisualPending = zone._captureFinalUnattested == true
    local upgradedVisualFinal = ClearVisualFinalPending(
        zone, originName, waveId, terminalTs, true)
    -- Ce helper n'est appele qu'apres acceptation canonique : une horloge gonflee
    -- par l'ancien overlay visuel ne peut donc pas bloquer le vrai certificat.
    if hadVisualPending and not upgradedVisualFinal then return false end
    local terminalReachesCurrent = (tonumber(terminalTs) or 0)
        >= (tonumber(zone.capturedTime) or 0)
    if terminalReachesCurrent then
        zone.previousOwner = nil
        if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
            Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
        end
        if preserveLoginQuarantine then
            zone._loginSyncUnconfirmed = true
        end
    end
    if Overlord.CaptureLease and Overlord.CaptureLease.TombstoneFinalWave then
        Overlord.CaptureLease:TombstoneFinalWave(zoneId, originName, waveId)
    end
    if deliveryDedup and deliveryKey then
        if deliveryDedup == priv.captureDedup then
            RememberCaptureDelivery(deliveryKey, GetTime())
        elseif deliveryDedup.Remember then
            local now = GetTime()
            deliveryDedup:Remember(deliveryKey, now, now, false)
        else
            deliveryDedup[deliveryKey] = GetTime()
        end
    end
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    return upgradedVisualFinal
end

-- Une capture canonique recente doit rester dans la tranche LC fixe, meme si le
-- joueur n'est pas encore dans le haut du classement. Buffer borne, sans wire.
function Overlord.Sync:MarkFreshCaptureLeaderboardRow(playerName)
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(playerName) or nil
    if not key then return false end
    local now = GetTime()
    local rows = priv.recentCaptureLeaderboardRows
    local count, oldestKey, oldestExpiry = 0, nil, nil
    for rowKey, expiry in pairs(rows) do
        if (tonumber(expiry) or 0) <= now then
            rows[rowKey] = nil
        else
            count = count + 1
            if not oldestExpiry or expiry < oldestExpiry then
                oldestKey, oldestExpiry = rowKey, expiry
            end
        end
    end
    if count >= 32 and oldestKey then rows[oldestKey] = nil end
    rows[key] = now + 600
    return true
end

-- CB (Capture Barrier) ne transporte aucun etat final. Il propose uniquement le
-- contrat 180 s d'une Barricade pour une vague deja visible. ZoneCaptureLease ne
-- l'accepte que si Blizzard montre le defenseur emetteur et le capteur sur le
-- meme disque, dans la bonne phase, au tout debut de la vague.
function Overlord.Sync:OnReceiveCaptureBarrier(payload, sender)
    if not payload or payload == "" or not sender or sender == "" then return end
    local zoneId, mode, originName, waveId, originGuid, defenderGuid,
        requirement, issuedAt = strsplit(":", payload)
    if not Overlord.CaptureLease or not Overlord.CaptureLease.ApplyDefensiveRequirement then
        return
    end
    Overlord.CaptureLease:ApplyDefensiveRequirement(
        zoneId, mode, originName, waveId, originGuid, defenderGuid,
        requirement, issuedAt, sender)
end

-- Une zone a ete capturee (cross-faction : tout le monde voit les captures)
function Overlord.Sync:OnReceiveCapture(payload, sender)
    if not payload then return end
    local zoneId, participantsStr, faction, ts, captureWaveId, captureOriginGuid,
        captureFinalRequirement = strsplit(":", payload)
    local hadExplicitTs = ts and ts ~= ""
    ts = NormalizeRemoteTimestamp(ts)
    if hadExplicitTs and not ts then return end
    if not ts or ts <= 0 then
        ts = time()
    end
    if hadExplicitTs then
        local lastReset = OverlordDB and OverlordDB.lastResetTimestamp or 0
        if lastReset > 0 and ts < lastReset then return end
    end

    if not zoneId or not participantsStr or participantsStr == "" then return end

    -- Participants : "Nom,Nom2" (legacy) ou "Nom|WARRIOR,Nom2|MAGE" (WoW n'autorise ni | ni , dans les noms)
    local parsedContributors = {}
    for part in string.gmatch(participantsStr, "[^,]+") do
        local seg = part:match("^%s*(.-)%s*$")
        if seg and seg ~= "" then
            local pname, pclass = seg, nil
            local pipePos = seg:find("|", 1, true)
            if pipePos then
                pname = seg:sub(1, pipePos - 1):match("^%s*(.-)%s*$")
                pclass = seg:sub(pipePos + 1):match("^%s*(.-)%s*$")
                if pclass and not self:IsValidCaptureClassToken(pclass) then
                    pclass = nil
                end
            end
            -- Ignore les contributeurs au nom "Unknown" (non resolu cote emetteur).
            if pname and pname ~= "" and self:IsValidPlayerName(pname) then
                parsedContributors[#parsedContributors + 1] = { name = pname, class = pclass }
            end
        end
    end
    if #parsedContributors == 0 then return end
    local triggerName = parsedContributors[1] and parsedContributors[1].name or nil

    -- Dedup : rejette les copies du meme evenement recues via d'autres canaux
    -- Normalise la cle : trie les noms en minuscules pour eviter variations de format
    local sortedNames = {}
    for _, entry in ipairs(parsedContributors) do
        local baseName = entry.name:match("^([^%-]+)") or entry.name
        sortedNames[#sortedNames + 1] = baseName:lower()
    end
    table.sort(sortedNames)
    local captureKey = zoneId .. ":" .. table.concat(sortedNames, ",") .. ":" .. ts
        .. ":" .. tostring(captureWaveId or "") .. ":" .. tostring(captureOriginGuid or "")
        .. ":" .. tostring(captureFinalRequirement or "")
    local now = GetTime()
    local captureSenderKey = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(sender) or tostring(sender or "")
    local captureDeliveryKey = captureKey .. "\31" .. tostring(faction or "")
        .. "\31" .. tostring(captureSenderKey)
    local duplicateCaptureMessage = priv.captureDedup[captureDeliveryKey] ~= nil
    local ownedDuplicateCapture = false
    for _, entry in ipairs(parsedContributors) do
        if self:CaptureContributorMatchesSender(entry.name, sender) then
            ownedDuplicateCapture = true
            break
        end
    end
    -- Une copie refusee d'un transport/sender ne doit jamais bloquer ensuite la
    -- copie WoW directe authentifiee du capteur.
    if duplicateCaptureMessage then return end
    local zone = Overlord.Zones:GetZone(zoneId)
    local knownZone = zone or (Overlord.Fronts and Overlord.Fronts:IsKnownZoneId(zoneId))
    if not knownZone then return end
    local newOwner = faction
    if not newOwner or newOwner == "" then return end
    -- Validation stricte : seules Alliance et Horde sont acceptees (anti-exploit/corruption)
    if newOwner ~= "Alliance" and newOwner ~= "Horde" then return end
    if zone and not zone._captureFinalUnattested
        and zone.owner and zone.owner ~= newOwner
        and (tonumber(zone.capturedTime) or 0) == ts
        and self:DeterministicCaptureTieOwner(zoneId, ts) ~= newOwner then
        return
    end
    if ShouldRejectPostVictoryZoneOwner(zoneId, newOwner, "captured", ts, "C") then return end
    -- Rejette un vieux "C" arrive apres une capture plus recente, meme si le proprietaire
    -- change. Sinon un paquet retarde peut reflipper la carte chez certains clients.
    if zone and not zone._captureFinalUnattested
        and zone.capturedTime and zone.capturedTime > 0 then
        local ef = Overlord.Zones and Overlord.Zones:GetEnemyFaction()
        -- C ennemi : exiger ts strictement > notre capturedTime (evite meme seconde / rejoue).
        -- previousOwner couvre le cas ou un ZS in_progress ennemi vient de passer avant ce C.
        -- Recap legitime postereure reste acceptee ; pas de fenetre 60-120s.
        if ef and faction == ef
            and (zone.owner == Overlord.PlayerFaction or zone.previousOwner == Overlord.PlayerFaction) then
            if ts < zone.capturedTime
                or (ts == zone.capturedTime and not ownedDuplicateCapture) then
                return
            end
        elseif zone.capturedTime and zone.capturedTime > ts then
            return
        end
    end

    -- Un C final doit porter origin+wave+GUID et partager sa claim minimale avec
    -- ZS captured. Le format legacy est refuse : ces champs lient directement
    -- l'identite WoW du capteur a la vague et au contrat termines.
    local captureFinalClaimKey = self.BuildCaptureFinalClaimKey
        and self:BuildCaptureFinalClaimKey(
            zoneId, newOwner == "Alliance" and "A" or "H", ts,
            triggerName, captureWaveId, captureOriginGuid,
            captureFinalRequirement) or nil
    if not captureFinalClaimKey then return end
    local finalRequirementZone = zone or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId)))
    local directCaptureFinal = ownedDuplicateCapture and #parsedContributors == 1
    -- Seul le C emis directement par son unique capteur peut muter owner/status.
    if not directCaptureFinal then return end
    if Overlord.CaptureLease
        and Overlord.CaptureLease.ShouldRejectFinal
        and Overlord.CaptureLease:ShouldRejectFinal(
            finalRequirementZone, triggerName, captureWaveId) then return end
    if Overlord.CaptureLease
        and Overlord.CaptureLease.FinalSatisfiesLocalRequirement
        and not Overlord.CaptureLease:FinalSatisfiesLocalRequirement(
            finalRequirementZone, newOwner, triggerName, captureWaveId,
            captureFinalRequirement) then return end
    -- Admission fail-closed avant le moindre credit/effet. Les paquets invalides
    -- n'entretiennent plus un scan du ledger, et une saturation ne peut pas
    -- oublier une livraison encore rejouable puis doubler la capture.
    if not EnsureCaptureDedupCapacity(captureDeliveryKey, now) then return end
    -- Le sender WoW est une identite de transport non choisie par le payload.
    -- Une claim moderne complete (faction, wave, GUID, requis, timestamp),
    -- apres les gardes du bail local ci-dessus, redevient canonique
    -- immediatement, selon la semantique territoriale 9.3.1.
    -- Leaderboard : crediter le(s) nom(s) du payload (declencheur ; anciens clients = liste).
    -- L'emetteur ne recoit pas son propre "C" via PARTY/RAID (filtre OnAddonMessage).
    -- Le declencheur a deja +1 en local via CaptureZone : ShouldSkipDuplicateLbCaptureBatch evite le double.
    local skipLeaderboard = false
    if sender and self:IsSenderLocalPlayer(sender) then
        skipLeaderboard = true
    end
    if not skipLeaderboard and faction and faction ~= "" then
        do
            -- Uniquement les noms du payload C (declencheur cote emetteur ; anciens clients peuvent
            -- encore envoyer plusieurs noms separes par des virgules - on les parse tels quels).
            -- Dedup par cle canonique : evite "Nom" + "Nom-Royaume" = deux points.
            local byDedupKey = {}
            local classByDedupKey = {}
            local function considerContributor(rawName)
                local key = self:GetCaptureContributorDedupKey(rawName)
                if not key then return end
                byDedupKey[key] = self:ChooseRicherCaptureContributorName(byDedupKey[key], rawName)
            end
            for _, entry in ipairs(parsedContributors) do
                considerContributor(entry.name)
                local dk = self:GetCaptureContributorDedupKey(entry.name)
                if dk and entry.class and entry.class ~= "" then
                    classByDedupKey[dk] = entry.class
                end
            end
            for _, n in pairs(byDedupKey) do
                local skipDup = self:ShouldSkipDuplicateLbCaptureBatch(zoneId, ts, n)
                -- Les anciens payloads pouvaient lister plusieurs participants. Ne jamais
                -- crediter un nom simplement affirme par un tiers.
                local creditAllowed = self.CanCreditDirectCapture
                    and self:CanCreditDirectCapture(sender, n, zoneId, faction)
                if skipDup or not creditAllowed then
                    n = nil
                end
                if n then
                    local dk = self:GetCaptureContributorDedupKey(n)
                    local cls = dk and classByDedupKey[dk]
                    -- CanCreditDirectCapture lie deja le contributeur au sender
                    -- WoW. Ses metadonnees valides ne doivent pas attendre une
                    -- seconde observation propre a chaque recepteur.
                    Overlord.Leaderboard:SetPlayerFaction(n, faction)
                    local classVerified = cls and cls ~= ""
                        and self:IsValidCaptureClassToken(cls)
                    if classVerified then
                        Overlord.Leaderboard:SetPlayerClassFromSync(n, cls)
                    end
                    Overlord.Leaderboard:AddPlayerCapture(n, zoneId, true)
                    self:MarkLbCaptureBatchCredited(zoneId, ts, n)
                    self:MarkFreshCaptureLeaderboardRow(n)
                end
            end
        end
    end

    -- La preuve d'etat est verifiee avant tout effet ; CanCreditDirectCapture ne
    -- sert plus qu'au point de classement du declencheur authentifie.
    -- Le C est maintenant completement valide : il peut alimenter l'activite recente.
    if Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(zoneId, sender, ts)
    end
    if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
    if Overlord.WaitingForSync then Overlord.WaitingForSync = nil end

    -- Nom du premier contributeur (capteur principal) pour affichage dans les alertes
    local oldStatus = zone and zone.status
    local oldOwner = zone and zone.owner

    -- Si la capture concerne un front non actif, on persiste son etat sans toucher
    -- ZoneDatabase : elle appartient au front courant.
    if not zone then
        local inactiveZone = Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId))
        local oldInactiveStatus = inactiveZone and inactiveZone.status
        local oldInactiveOwner = inactiveZone and inactiveZone.owner
        local shouldPrintInactiveCapture = oldInactiveOwner ~= newOwner or oldInactiveStatus ~= "captured"
        local captureApplied = ApplyInactiveFrontCapture(zoneId, newOwner, ts)
        local captureAlreadyCanonical = inactiveZone and inactiveZone.owner == newOwner
            and inactiveZone.status ~= "in_progress"
            and (tonumber(inactiveZone.capturedTime) or 0) >= ts
        if inactiveZone and (captureApplied or captureAlreadyCanonical) then
            if not captureApplied and Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                Overlord.CaptureLease:Complete(inactiveZone)
            end
            local upgradedVisualFinal = self:FinalizeAcceptedCaptureFinal(
                inactiveZone, zoneId, triggerName, captureWaveId,
                ts, priv.captureDedup, captureDeliveryKey)
            -- ApplyInactiveFrontCapture persiste avant la finalisation ; repersister
            -- pour ne jamais sauver previousOwner/quarantaine de l'ancienne vague.
            PersistSyncedZoneState(inactiveZone)
            if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
                Overlord.MapMarkers:RequestOverlayRefresh()
            end
            if Overlord.UI then Overlord.UI:RequestRefresh() end
            if captureApplied and shouldPrintInactiveCapture then
                -- Hors front actif (ex : Silvermoon), conserver les alertes chat critiques.
                if newOwner == Overlord.PlayerFaction then
                    priv.enemyAlertLast[inactiveZone.id] = nil
                end
                -- Passe le nom du capteur (avec royaume) si capture ennemie
                local capturerForChat = (newOwner ~= Overlord.PlayerFaction) and triggerName or nil
                PrintCaptureChatOnce(inactiveZone, newOwner, capturerForChat, ts)
            end
            if upgradedVisualFinal then self:CheckTotalVictoryFromSync() end
        end
        return
    end

    -- Etat zone : ignorer si deja capture avec un timestamp >= (ex. ZA/ZS avant C).
    -- Le chat peut manquer si ZA a promu sans PrintCaptureChatOnce : tenter le print ici
    -- (dedup PrintCaptureChatOnce evite le double si le message est deja passe).
    if Overlord.Zones and Overlord.Zones.IsNetworkConfirmedCapture
        and Overlord.Zones:IsNetworkConfirmedCapture(zone)
        and zone.capturedTime and zone.capturedTime >= ts
        and zone.owner == newOwner then
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        self:FinalizeAcceptedCaptureFinal(
            zone, zoneId, triggerName, captureWaveId,
            ts, priv.captureDedup, captureDeliveryKey)
        if newOwner ~= Overlord.PlayerFaction then
            local capturerForChat = triggerName
            PrintCaptureChatOnce(zone, newOwner, capturerForChat, zone.capturedTime)
        end
        self:CheckTotalVictoryFromSync()
        return
    end

    -- NOTE : la protection prerequis (allControlled) a ete retiree intentionnellement.
    -- Le message C est emis par le joueur qui vient de capturer : il est toujours frais (ts ~ time()).
    -- La protection ts ligne ~1052 (capturedTime >= ts) couvre les vrais C stales.
    -- Bloquer le C sur prerequis incomplets provoque "zone bloquee en in_progress" si le
    -- ZS in_progress a passe mais que le C arrive avant que les autres zones soient synced.

    -- Appliquer si le proprietaire/statut change ou si ce final avance le certificat temporel.
    -- Corrige le cas ou un ZS in_progress avait deja set owner=faction avant le C :
    -- sans ca, zone.owner == newOwner -> la capture etait silencieusement ignoree
    -- et la zone restait bloquee en "in_progress" pour toujours
    local ownerChanged = (zone.owner ~= newOwner)
    local captureTimeAdvanced = (tonumber(zone.capturedTime) or 0) < ts
    if ownerChanged or zone.status ~= "captured" or captureTimeAdvanced
        or zone._captureFinalUnattested then
        -- Perdre la zone (capture ennemie) : invalide le marqueur allie pour la prochaine recapture.
        if ownerChanged and newOwner ~= Overlord.PlayerFaction then
            self:ClearLbCaptureBatchDedup(zoneId)
        end
        -- Ne pas remettre killsCurrent a 0 ici : l'ecran de victoire lit ce compteur par zone.
        -- Un reset a la reception du C laissait 0 kills sur les zones capturees par un allie
        -- (status local in_progress) alors que ally/enemyKillsCurrent restaient non nuls.

        zone.owner = newOwner
        zone.capturedTime = ts
        zone.updatedAt = ts
        zone.status = "captured"
        zone.previousOwner = nil
        -- FinalizeAcceptedCaptureFinal pose ensuite le TombstoneFinalWave : jamais
        -- avant que owner/status/capturedTime soient devenus canoniques.
        zone.isHolding = false
        zone.isContested = false
        zone.isPaused = false
        zone.holdTimeElapsed = 0
        zone.holdStartTime = nil
        zone.holdTimeRequired = 120
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        self:FinalizeAcceptedCaptureFinal(
            zone, zoneId, triggerName, captureWaveId,
            ts, priv.captureDedup, captureDeliveryKey)
        Overlord.Zones:UpdateAvailableZones()
        Overlord:MarkDirty()
        if Overlord.UI then Overlord.UI:RequestRefresh() end

        -- Message C = capture definitive : fin de vague in_progress (alertes chat).
        priv.enemyAlertEmitted[zoneId] = nil
        priv.enemyAlertSkipUntil[zoneId] = nil
        -- Reset cooldown si notre capture : l'ennemi peut retagger tout de suite avec alerte.
        if newOwner == Overlord.PlayerFaction then
            priv.enemyAlertLast[zone.id] = nil
        end
        -- Victoire OU defaite totale : avant seul le cas "on capture la capitale ennemie" appelait ce check,
        -- donc la prise de NOTRE capitale par l'ennemi (message C) ne declenchait ni ecran ni treve sans TV.
        self:CheckTotalVictoryFromSync()

        local shouldPrintCapture = ownerChanged or oldStatus ~= "captured"
        if shouldPrintCapture then
            -- Passe le nom du capteur (avec royaume) si capture ennemie
            local capturerForChat = (newOwner ~= Overlord.PlayerFaction) and triggerName or nil
            PrintCaptureChatOnce(zone, newOwner, capturerForChat, ts)
        end
    end
end

-- Toutes les zones connues pour une reponse SR (front actif + cache des autres fronts).
local function CollectSrResponseZones()
    local zones = {}
    local seen = {}
    if Overlord.Fronts and Overlord.Fronts.Registry then
        local function appendFront(front)
            if not front or not front.zones then return end
            for _, zone in ipairs(front.zones) do
                if zone and zone.id and not seen[zone.id] then
                    seen[zone.id] = true
                    zones[#zones + 1] = zone
                end
            end
        end
        for _, frontId in ipairs(Overlord.Fronts.Order or {}) do
            appendFront(Overlord.Fronts.Registry[frontId])
        end
        -- Ne jamais laisser un front enregistre mais absent de l'ordre UI hors
        -- du snapshot exact ni du post-check de quarantaine.
        for _, front in pairs(Overlord.Fronts.Registry) do
            appendFront(front)
        end
    end
    if #zones == 0 then
        for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
            if zone and zone.id and not seen[zone.id] then
                seen[zone.id] = true
                zones[#zones + 1] = zone
            end
        end
    end
    return zones
end

-- ZA v2 transporte une vue complete en pages identifiees. Une page seule ne
-- constitue jamais un snapshot : le receveur assemble tout le lot avant de
-- valider ou de toucher une zone.
Overlord.Sync.ZA_SNAPSHOT_BODY_BYTES = 175
Overlord.Sync.ZA_SNAPSHOT_MAX_PAGES = 32

function Overlord.Sync:NextZaSnapshotId(scope)
    local persisted = OverlordDB and tonumber(OverlordDB.zaSnapshotSequence)
    if persisted and persisted >= 0 and persisted < 1000000 then
        priv.zaSnapshotSequence = math.max(
            tonumber(priv.zaSnapshotSequence) or 0, math.floor(persisted))
    end
    priv.zaSnapshotSequence = ((tonumber(priv.zaSnapshotSequence) or 0) + 1) % 1000000
    if OverlordDB then OverlordDB.zaSnapshotSequence = priv.zaSnapshotSequence end
    return tostring(scope or "G") .. "-" .. tostring(time()) .. "-"
        .. tostring(priv.zaSnapshotSequence)
end

function Overlord.Sync:BuildZoneAllSnapshotPart(zone, allowLoginBase)
    if not zone or not zone.id
        or (zone._loginSyncUnconfirmed and not allowLoginBase) then
        return nil
    end

    -- Le timer orange voyage par ZS/lease. ZA transporte le dernier socle
    -- stable afin qu'une capture en cours, meme sur un autre front, ne rende
    -- pas toute la photo de connexion impossible a assembler.
    local state = zone
    if zone._captureFinalUnattested then
        state = zone._captureFinalConfirmedBase
        if not state then return nil end
    elseif zone.status == "in_progress" then
        if zone._localCaptureBase then
            state = zone._localCaptureBase
        elseif Overlord.CaptureLease and Overlord.CaptureLease.GetPersistableView then
            state = Overlord.CaptureLease:GetPersistableView(zone)
        end
        if not state or state == zone or state.status == "in_progress" then
            return nil
        end
    end

    local code
    if state.owner == "Alliance" then
        code = "A"
    elseif state.owner == "Horde" then
        code = "H"
    elseif state.owner == nil then
        -- Le N explicite est indispensable : sans lui, un client qui a manque
        -- FR/abandon conserve indefiniment les anciennes couleurs de la carte.
        code = "N"
    else
        return nil
    end

    local ct = (code ~= "N") and (tonumber(state.capturedTime) or 0) or 0
    -- Le receveur remplace deja updatedAt par capturedTime pour toute capture :
    -- emettre exactement la meme horloge canonique evite qu'un socle pourtant
    -- identique soit vu comme un conflit avec le bail ZS orange qui le recouvre.
    local ts = (ct > 0) and ct or (tonumber(state.updatedAt) or 0)
    if code == "N" and ts <= 0 then
        -- Etat neutre de base de la campagne : l'absence de timestamp ne doit
        -- pas transformer un snapshot "global" en liste implicite/incomplete.
        -- Affectation intermediaire obligatoire : la fonction renvoie aussi le
        -- campaignId et tonumber(f()) traiterait ce 2e retour comme une base.
        local campaignStart = GetCurrentSyncCampaignStartAndId()
        ts = tonumber(campaignStart) or 0
    end
    if ts <= 0 and allowLoginBase and zone._loginSyncUnconfirmed then
        -- Une ancienne SavedVariable peut avoir un owner sans horloge. Dans Q,
        -- l'epoch de campagne permet a deux vues identiques de la normaliser ;
        -- hors quarantaine cet owner sans preuve reste non serialisable.
        local campaignStart = GetCurrentSyncCampaignStartAndId()
        ts = tonumber(campaignStart) or 0
    end
    if ts <= 0 then return nil end
    -- 9.6 n'emet qu'une seule representation d'une capture. Les anciens etats
    -- pouvaient avoir owner+updatedAt sans capturedTime et produire ct=0 ; apres
    -- application ils etaient reemis avec ct=ts, ce qui cassait l'identite canonique.
    if code ~= "N" and ct <= 0 then ct = ts end
    return zone.id .. ":" .. code .. ":" .. math.floor(ts) .. ":" .. math.floor(ct)
end

function Overlord.Sync:BuildZoneAllSnapshotPages(zones, requestedScope)
    local parts = {}
    local expectedCount = 0
    -- Une vue disque en quarantaine login n'est pas une verite canonique, mais
    -- elle doit pouvoir voter dans un G exact. Sinon trois joueurs qui /reload
    -- ensemble n'emettent plus aucune carte et ne peuvent jamais converger.
    local allowLoginBase = requestedScope == "G"
    local hasLoginBase = false
    for _, zone in ipairs(zones or {}) do
        if zone and zone.id then expectedCount = expectedCount + 1 end
        if allowLoginBase and zone and zone._loginSyncUnconfirmed then
            hasLoginBase = true
        end
        local part = self:BuildZoneAllSnapshotPart(zone, allowLoginBase)
        if part then parts[#parts + 1] = part end
    end
    table.sort(parts)

    -- Un snapshot global qui omet une zone en cours/quarantaine reste utile pour
    -- le rattrapage, mais ne doit jamais pretendre avoir couvert toute la carte.
    local scope = requestedScope or "G"
    if scope == "G" then
        if #parts ~= expectedCount then
            -- Un Q incomplet ne doit pas retomber en P avec des lignes login :
            -- reconstruire la partie strictement canonique avant emission.
            parts = {}
            for _, zone in ipairs(zones or {}) do
                local canonicalPart = self:BuildZoneAllSnapshotPart(zone, false)
                if canonicalPart then parts[#parts + 1] = canonicalPart end
            end
            table.sort(parts)
            scope = "P"
        elseif hasLoginBase then
            -- Q = carte globale exacte mais source elle-meme en quarantaine.
            -- Elle reste distincte pour signaler que la source est elle-meme en
            -- quarantaine, mais le receveur valide et applique son lot atomiquement.
            scope = "Q"
        end
    end
    if #parts == 0 then return {}, 0 end
    local zaSnapshotId = self:NextZaSnapshotId(scope)

    local bodies, page, pageLen = {}, {}, 0
    for _, part in ipairs(parts) do
        if pageLen + #part + 1 > self.ZA_SNAPSHOT_BODY_BYTES and #page > 0 then
            bodies[#bodies + 1] = table.concat(page, ",")
            page, pageLen = {}, 0
        end
        page[#page + 1] = part
        pageLen = pageLen + #part + 1
    end
    if #page > 0 then bodies[#bodies + 1] = table.concat(page, ",") end
    if #bodies > self.ZA_SNAPSHOT_MAX_PAGES then return {}, 0 end

    local zaPageCount = #bodies
    local pages = {}
    for zaPageIndex, body in ipairs(bodies) do
        pages[zaPageIndex] = "@" .. zaSnapshotId .. ":" .. zaPageIndex
            .. ":" .. zaPageCount .. "|" .. body
    end
    return pages, zaPageCount
end

function Overlord.Sync:OrderZoneAllEntries(entries)
    -- Ordre stable : les territoires doivent etre poses avant les capitales,
    -- dont la validation depend de la possession du reste du front.
    table.sort(entries, function(a, b)
        local aId = strsplit(":", a)
        local bId = strsplit(":", b)
        local aBase = Overlord.Zones:GetBaseZoneFixedOwner(aId) ~= nil
        local bBase = Overlord.Zones:GetBaseZoneFixedOwner(bId) ~= nil
        if aBase ~= bBase then return not aBase end
        return tostring(a) < tostring(b)
    end)
    return entries
end

-- Payload ZS ponctuel pour reponse SR (nil si zone trop vieille).
-- Sert aussi a propager les fins d'abandon available/locked que ZA ne transporte pas.
local function BuildSrZsPayload(zone)
    if not zone then return nil end
    local status = zone.status
    if status ~= "in_progress" and status ~= "available" and status ~= "locked" then return nil end
    local zoneTs = zone.updatedAt or 0
    if zoneTs <= 0 then return nil end
    local age = time() - zoneTs
    local maxAge = (status == "in_progress") and ((zone.holdTimeRequired or 120) + 30) or 120
    if age >= maxAge then return nil end
    local kills = zone.killsCurrent or 0
    local holdTime = (status == "in_progress") and math.floor(zone.holdTimeElapsed or 0) or 0
    local ownerCode = (zone.owner == "Alliance") and "A" or ((zone.owner == "Horde") and "H" or "")
    if status == "in_progress" and ownerCode == "" and Overlord.PlayerFaction then
        ownerCode = (Overlord.PlayerFaction == "Alliance") and "A" or "H"
    end
    -- Une zone owned + capturedTime est une capture confirmee. Si elle est localement
    -- available/locked, c'est seulement notre vue d'assaut ; ZA porte deja la verite owner/ct.
    if status ~= "in_progress" and ownerCode ~= "" and (tonumber(zone.capturedTime) or 0) > 0 then
        return nil
    end
    local siegePhase = 0
    local holdReq = math.floor(zone.holdTimeRequired or 120)
    local capturerName = ""
    local capturerShard = ""
    if status == "in_progress" and Overlord.PlayerFaction then
        if zone.isHolding and zone.holdAuthorityLocal and zone.owner == Overlord.PlayerFaction then
            capturerName = Overlord.Sync:GetPlayerFullName() or ""
        elseif zone.owner == Overlord.PlayerFaction then
            local official = zone.zsOfficialCapturerName
            if official and type(official) == "string" then
                local t = official:match("^%s*(.-)%s*$") or ""
                if t ~= "" and #t >= 2 and #t <= 50 then capturerName = t end
            end
        elseif zone.owner and zone.owner ~= Overlord.PlayerFaction then
            local r = zone.zsRelayCapturerName
            if r and type(r) == "string" then
                local t = r:match("^%s*(.-)%s*$") or ""
                if t ~= "" and #t >= 2 and #t <= 50 then capturerName = t end
            end
            if capturerName ~= "" and zone.zsRelayCapturerShard then
                capturerShard = tostring(zone.zsRelayCapturerShard)
            end
        end
    end
    local waveId = status == "in_progress" and Overlord.CaptureLease
        and Overlord.CaptureLease.GetWaveId and Overlord.CaptureLease:GetWaveId(zone) or ""
    local relayedDisplayHold = ""
    local relayedDisplayAt = ""
    if status == "in_progress" and Overlord.Zones
        and Overlord.Zones.GetObserverHoldTimeElapsed then
        relayedDisplayHold = tostring(math.floor(
            Overlord.Zones:GetObserverHoldTimeElapsed(zone)))
        relayedDisplayAt = tostring(time())
    end
    return zone.id .. ":" .. status .. ":" .. kills .. ":" .. holdTime .. ":" .. ownerCode .. ":"
        .. zoneTs .. ":" .. siegePhase .. ":" .. holdReq .. ":" .. capturerName
        .. ":" .. capturerShard .. ":" .. (waveId or "")
        .. ":::::" .. relayedDisplayHold .. ":" .. relayedDisplayAt
end

local function SrInProgressFrontPriority(zone, activeFrontId)
    if not activeFrontId or not zone or not zone.id or not Overlord.Fronts or not Overlord.Fronts.GetZone then
        return 0
    end
    local _, fr = Overlord.Fronts:GetZone(zone.id)
    return (fr and fr.id == activeFrontId) and 1 or 0
end

-- Un joueur demande la sync. Tout joueur peut repondre (cross-faction).
-- Whisper : 100% (demande directe 1:1, on repond toujours)
-- Groupe (PARTY/RAID) : 95%
-- Canal : 95% (augmente pour fiabilite cross-faction Alliance/Horde)
local lastSyncResponse = 0
local syncResponseInFlight = false
local syncResponseGeneration = 0
local CHANNEL_RESPONSE_COOLDOWN = 8  -- secondes entre reponses canal (8s = safe en 80v80)
local lastSRPerSender = {
    values = {}, nodes = {}, head = nil, tail = nil, count = 0, max = 512,
}
local SR_PER_SENDER_COOLDOWN = 30
function lastSRPerSender:Remove(node)
    if not node then return end
    if node.previous then node.previous.next = node.next else self.head = node.next end
    if node.next then node.next.previous = node.previous else self.tail = node.previous end
    self.nodes[node.key], self.values[node.key] = nil, nil
    self.count = math.max(0, self.count - 1)
end
function lastSRPerSender:RemoveKey(key)
    self:Remove(self.nodes[key])
end
function lastSRPerSender:Get(key)
    return self.values[key]
end
function lastSRPerSender:Remember(key, now)
    local node = self.nodes[key]
    if node then
        node.timestamp = now
        self.values[key] = now
        if node ~= self.tail then
            if node.previous then node.previous.next = node.next else self.head = node.next end
            if node.next then node.next.previous = node.previous end
            node.previous, node.next = self.tail, nil
            if self.tail then self.tail.next = node end
            self.tail = node
        end
        return
    end
    if self.count >= self.max then self:Remove(self.head) end
    node = { key = key, timestamp = now, previous = self.tail, next = nil }
    if self.tail then self.tail.next = node else self.head = node end
    self.tail = node
    self.nodes[key], self.values[key] = node, now
    self.count = self.count + 1
end
function lastSRPerSender:Prune(now, budget)
    local removed = 0
    while self.head and now - self.head.timestamp > SR_PER_SENDER_COOLDOWN * 2
        and removed < math.max(1, math.floor(tonumber(budget) or 1)) do
        self:Remove(self.head)
        removed = removed + 1
    end
end
local lbRaceBeaconWireEpoch = 0

local function QueuePendingDirectSR(senderKey, sender, payload, channel, replyToOverride)
    if not senderKey or senderKey == "" then return end
    if not priv.pendingDirectSR[senderKey] then
        if (priv.pendingDirectSRCount or 0) >= 12 then
            local oldestKey, oldestAt
            for k, req in pairs(priv.pendingDirectSR) do
                local queuedAt = tonumber(req and req.queuedAt) or 0
                if not oldestAt or queuedAt < oldestAt then
                    oldestKey, oldestAt = k, queuedAt
                end
            end
            if oldestKey then
                priv.pendingDirectSR[oldestKey] = nil
                priv.pendingDirectSRCount = math.max((priv.pendingDirectSRCount or 1) - 1, 0)
            else
                return
            end
        end
        priv.pendingDirectSRCount = (priv.pendingDirectSRCount or 0) + 1
    end
    priv.pendingDirectSR[senderKey] = {
        sender = sender,
        payload = payload,
        channel = channel,
        replyToOverride = replyToOverride,
        queuedAt = GetTime(),
        expiresAt = math.max(
            GetTime() + 90,
            (tonumber(priv.syncResponseDeadline) or 0) + 30),
    }
end

local function SchedulePendingDirectSRRetry()
    if priv.pendingDirectSRRetryScheduled then return end
    priv.pendingDirectSRRetryScheduled = true
    C_Timer.After(1, function()
        priv.pendingDirectSRRetryScheduled = false
        if Overlord.InstanceSuspended then
            wipe(priv.pendingDirectSR)
            priv.pendingDirectSRCount = 0
            return
        end
        if syncResponseInFlight then
            SchedulePendingDirectSRRetry()
            return
        end
        -- Une demande directe doit pouvoir recevoir la photo Q pendant notre
        -- propre gate login. OnSyncRequest garde alors toutes les reponses
        -- secondaires hors file ; bloquer ici creait un cycle A -> B -> C -> A.
        local senderKey, req = next(priv.pendingDirectSR)
        if not req then return end
        priv.pendingDirectSR[senderKey] = nil
        priv.pendingDirectSRCount = math.max((priv.pendingDirectSRCount or 1) - 1, 0)
        local expiresAt = tonumber(req.expiresAt)
            or ((tonumber(req.queuedAt) or 0) + 90)
        if GetTime() > expiresAt then
            if next(priv.pendingDirectSR) then
                SchedulePendingDirectSRRetry()
            end
            return
        end
        lastSRPerSender:RemoveKey(senderKey)
        Overlord.Sync:OnSyncRequest(req.sender, req.payload, req.channel, req.replyToOverride)
        if next(priv.pendingDirectSR) then
            SchedulePendingDirectSRRetry()
        end
    end)
end

-- Appele quand on recoit R2 (relais) : on envoie la reponse en whisper a replyTo
function Overlord.Sync:OnSyncRequestRelayed(replyTo, payload)
    if not replyTo or replyTo == "" or #replyTo > 50 then return end
    if not self:HasCompleteContributorIdentity(replyTo) then return end
    self:OnSyncRequest(replyTo, payload or "", "WHISPER", replyTo)
end

function Overlord.Sync:OnSyncRequest(sender, payload, channel, replyToOverride)
    -- Routed request: delayed replies return through SendWhisper's beta route.
    if channel == "BETA" then
        if not Overlord.BetaNetwork or not Overlord.BetaNetwork:IsDispatching(sender) then return end
        channel = Overlord.BetaNetwork:IsTargetedDispatch() and "WHISPER" or "CHANNEL"
        replyToOverride = sender
    end
    -- Extraction de la version, victoryTs et victoryFaction du payload SR
    -- Format: "faction:version:victoryTs:victoryFaction"
    local _, senderVersionField, senderVTs, senderVF, senderVFront, senderRequestMode =
        strsplit(":", payload or "", 6)
    local directSR = (channel == "WHISPER" or channel == "BNET")
    local fullResponseRequested = senderRequestMode == "F" and directSR
    local stateResponseRequested = senderRequestMode == "S" and directSR
    local territorialResponseOnly = true
    local senderVersion, senderEvidencePage = tostring(senderVersionField or ""):match("^(.-)~(%d+)$")
    local hasEvidencePage = senderEvidencePage ~= nil
    if not senderVersion then senderVersion = senderVersionField end
    senderEvidencePage = tonumber(senderEvidencePage)
    if not senderEvidencePage or senderEvidencePage ~= senderEvidencePage
        or senderEvidencePage < 0 or senderEvidencePage > 2147483646 then
        senderEvidencePage = 0
    else
        senderEvidencePage = math.floor(senderEvidencePage)
    end
    CheckRemoteVersion(senderVersion)
    -- Propage la treve : prend le max(local, distant) pour que tout le monde converge
    -- IMPORTANT: on n'accepte que si la faction gagnante est fournie (evite les donnees corrompues)
    local remoteVTs = tonumber(senderVTs) or 0
    local remoteVictoryFaction = nil
    if senderVF == "A" then remoteVictoryFaction = "Alliance"
    elseif senderVF == "H" then remoteVictoryFaction = "Horde" end
    
    if remoteVTs > 0 and remoteVictoryFaction and OverlordDB and remoteVTs <= time() + MAX_CLOCK_SKEW
        and not IsStaleCampaignTimestamp(remoteVTs) then
        local frontVictory = senderVFront and senderVFront ~= "" and OverlordDB.frontVictories and OverlordDB.frontVictories[senderVFront]
        local localVTs = (frontVictory and frontVictory.timestamp) or 0
        if remoteVTs > localVTs and senderVFront and senderVFront ~= "" then
            -- N'appliquer la treve que si la carte locale confirme la victoire totale (capitale + tout le front).
            -- Sinon : treve fantome avec zones encore disputees (bug « Trêve » sur toute la carte).
            if Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce
                and Overlord.Zones:LocalStateSupportsVictoryTruce(senderVFront, remoteVictoryFaction)
                and Overlord.Zones.SetVictoryCooldown then
                Overlord.Zones:SetVictoryCooldown(senderVFront, remoteVictoryFaction, remoteVTs)
            end
        end
    end

    -- Pendant la gate, ne repondre qu'avec un Q global exact. Sans cette voix
    -- non canonique, trois joueurs qui /reload ensemble attendraient tous une
    -- reponse que chacun refuse d'emettre.
    local quarantinedMapOnly = Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending())

    local now = GetTime()

    -- Anti-amplification : cooldown par sender pour les whispers.
    -- On ne marque le sender qu'apres les throttles globaux, sinon une SR directe peut
    -- etre "consommee" sans reponse quand lastSyncResponse bloque encore.
    -- Defense receveur : un SR legacy sans mode, ou un F diffuse sur canal/groupe,
    -- reste territorial. Cela empeche un ancien client (ou un paquet forge) de lancer
    -- une construction monolithique du classement chez tous les pairs idle.
    territorialResponseOnly = not (stateResponseRequested or fullResponseRequested)
    if Overlord.InActiveFront and not directSR then
        -- RAID/PARTY/CHANNEL est une vague visible de tous les pairs locaux : elle
        -- annule leurs callbacks periodiques encore en attente.
        self._lastActivePeriodicSrAt = GetTime()
    end
    local senderKey = directSR and tostring(sender) or nil
    if directSR then
        local lastSR = lastSRPerSender:Get(senderKey) or 0
        if now - lastSR < SR_PER_SENDER_COOLDOWN then return end
    end

    -- Whisper/BNet = reponse garantie ; canal/groupe = probabilite adaptee a la taille de l'event.
    -- En event massif, on reste conservateur : trop de repondeurs canal paralleles saturent
    -- vite le throttle Blizzard en 40v40. Les whispers/BNet restent garantis pour les demandes ciblees.
    local isLarge = self:IsLargeEvent()
    local respondChance
    if quarantinedMapOnly then
        -- Reponse Q seule, bornee : ne pas ajouter 5 % de deadlock aleatoire au
        -- seul chemin qui permet a plusieurs reloads simultanes de voter.
        respondChance = 1.0
    elseif channel == "WHISPER" or channel == "BNET" then
        respondChance = 1.0
    elseif isLarge then
        respondChance = 0.18
    else
        respondChance = 0.95
    end
    -- En event massif sur canal : reponse courte garantie (ZA + DM + treve) meme si la file complete est refusee.
    local minimalResponseOnly = territorialResponseOnly or stateResponseRequested
    if math.random() > respondChance then
        if isLarge and channel ~= "WHISPER" and channel ~= "BNET" then
            minimalResponseOnly = true
        else
            return
        end
    end
    -- Whisper/BNet : reponse garantie, on attend que le vol en cours finisse au lieu de jeter.
    -- Les reponses Large Event peuvent durer longtemps avec un rattrapage leaderboard complet.
    if syncResponseInFlight then
        if channel == "WHISPER" or channel == "BNET" then
            QueuePendingDirectSR(senderKey, sender, payload, channel, replyToOverride)
            SchedulePendingDirectSRRetry()
        end
        return
    end
    local WHISPER_RESPONSE_COOLDOWN = 5
    local PASSIVE_RESPONSE_COOLDOWN = 30
    local cooldown
    if not Overlord.InActiveFront then
        cooldown = PASSIVE_RESPONSE_COOLDOWN
    elseif isLarge then
        -- En event massif : cooldown plus long pour eviter les rafales SR multi-clients.
        cooldown = (channel == "WHISPER" or channel == "BNET") and WHISPER_RESPONSE_COOLDOWN or 35
    else
        cooldown = (channel == "WHISPER" or channel == "BNET") and WHISPER_RESPONSE_COOLDOWN or CHANNEL_RESPONSE_COOLDOWN
    end
    if now - lastSyncResponse < cooldown then
        if directSR then
            QueuePendingDirectSR(senderKey, sender, payload, channel, replyToOverride)
            SchedulePendingDirectSRRetry()
        end
        return
    end
    if directSR then
        lastSRPerSender:Remember(senderKey, now)
    end
    local previousLastSyncResponse = lastSyncResponse
    lastSyncResponse = now

    local delay = 0.3 + math.random() * 1.2  -- 0.3-1.5s (avant 1-5s = latence visible pour l'adversaire)
    local bnetTarget = (channel == "BNET" and not replyToOverride) and sender or nil
    local whisperTarget = replyToOverride or (channel == "WHISPER" and sender or nil)

    -- Reserver le slot avant le jitter : sinon plusieurs SR recus pendant 0,3-1,5 s passent
    -- tous la garde et construisent/envoient des files concurrentes.
    syncResponseGeneration = syncResponseGeneration + 1
    local responseGeneration = syncResponseGeneration
    local responseTickerStarted = false
    syncResponseInFlight = true
    -- Filet de deverrouillage : une erreur Lua imprÃ©vue dans le constructeur ne doit jamais
    -- condamner toutes les futures reponses SR de la session.
    C_Timer.After(120, function()
        if syncResponseInFlight and syncResponseGeneration == responseGeneration
            and not responseTickerStarted then
            syncResponseInFlight = false
            priv.syncResponseDeadline = 0
        end
    end)
    C_Timer.After(delay, function()
        if syncResponseGeneration ~= responseGeneration then return end
        -- Garde instance : si on est entre en BG/donjon pendant le delai, ne rien envoyer
        if Overlord.InstanceSuspended then
            if syncResponseGeneration == responseGeneration then
                syncResponseInFlight = false
                priv.syncResponseDeadline = 0
            end
            return
        end
        quarantinedMapOnly = quarantinedMapOnly or Overlord.WaitingForSync
            or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending())
        -- Une reponse SR territoriale reste disponible en combat, mais le snapshot
        -- tranche du classement attendra une demande ulterieure.
        if InCombatLockdown and InCombatLockdown() then
            minimalResponseOnly = true
        end
        local queue = {}
        local responseState = {
            queue = queue,
            queueIndex = 0,
            preparingLadder = false,
            preparationDeadline = 0,
            finished = false,
        }
        local srZones = CollectSrResponseZones()

        -- Zones compactes (ZA) : snapshot atomique, toutes les pages portent le meme identifiant.
        -- Les zones neutres sont explicites (N) et les reparations locales non
        -- confirmees ne sont jamais relayees comme verite reseau.
        local zaPages, zaPageCount = self:BuildZoneAllSnapshotPages(srZones, "G")
        for zaPageIndex = 1, zaPageCount do
            local zaPage = zaPages[zaPageIndex]
            if not quarantinedMapOnly or zaPage:match("^@Q%-") then
                table.insert(queue, { type = "ZA", data = zaPage })
            end
        end

        if not quarantinedMapOnly then
        -- La carte ZA est deja dans queue. Tout ce qui suit est du rattrapage
        -- secondaire (TV, ZS, classement, ressources, domination...). Une erreur
        -- dans un de ces modules ne doit JAMAIS annuler la reponse territoriale
        -- communautaire ni laisser syncResponseInFlight verrouille 120 secondes.
        pcall(function()
        -- Rejouer pendant deux heures la preuve terminale apres ZA. Le receveur
        -- valide donc d'abord la carte complete, puis TV peut restaurer la capitale,
        -- la treve et l'annonce ratees pendant une instance. La dedup timestamp du
        -- handler empeche tout re-pop lors des SR suivantes ou apres /reload.
        if OverlordDB and OverlordDB.frontVictories then
            for frontId, victory in pairs(OverlordDB.frontVictories) do
                local tvPayload = self:BuildTotalVictoryReplayPayload(frontId, victory)
                if tvPayload then
                    table.insert(queue, { type = "TV", data = tvPayload })
                end
            end
        end
        if not territorialResponseOnly and self.AppendFrontActivityToSrQueue then
            pcall(self.AppendFrontActivityToSrQueue, self, queue)
        end
        -- Etat live immediat : les timers/tenants ne doivent pas attendre les historiques.
        if self.AppendGuildKeepToSrQueue then
            pcall(self.AppendGuildKeepToSrQueue, self, queue, minimalResponseOnly)
        end
        -- Une reponse territoriale reprend toutes les captures du front actif.
        -- Les six places supplementaires couvrent les vagues recentes des fronts
        -- inactifs sans refaire une reponse SR complete.
        local srZsMax = minimalResponseOnly and 6 or 99
        local activeFrontId = Overlord.Fronts and Overlord.Fronts.activeFrontId
        if minimalResponseOnly and srZsMax < 99 then
            local activePicks, otherPicks = {}, {}
            for _, zone in ipairs(srZones) do
                local payload = BuildSrZsPayload(zone)
                if payload then
                    local pick = {
                        payload = payload,
                        prio = SrInProgressFrontPriority(zone, activeFrontId),
                        ts = zone.updatedAt or 0,
                        inProgress = zone.status == "in_progress",
                    }
                    if pick.prio == 1 and pick.inProgress then
                        activePicks[#activePicks + 1] = pick
                    else
                        otherPicks[#otherPicks + 1] = pick
                    end
                end
            end
            table.sort(activePicks, function(a, b) return a.ts > b.ts end)
            table.sort(otherPicks, function(a, b)
                if a.prio ~= b.prio then return a.prio > b.prio end
                if a.inProgress ~= b.inProgress then return a.inProgress end
                return a.ts > b.ts
            end)
            for i = 1, #activePicks do
                table.insert(queue, { type = "ZS", data = activePicks[i].payload })
            end
            for i = 1, math.min(#otherPicks, srZsMax) do
                table.insert(queue, { type = "ZS", data = otherPicks[i].payload })
            end
        else
            local srZsCount = 0
            for _, zone in ipairs(srZones) do
                if srZsCount >= srZsMax then break end
                local payload = BuildSrZsPayload(zone)
                if payload then
                    table.insert(queue, { type = "ZS", data = payload })
                    srZsCount = srZsCount + 1
                end
            end
        end

        if self.AppendOutpostToSrQueue then
            pcall(self.AppendOutpostToSrQueue, self, queue, minimalResponseOnly)
        end
        if not minimalResponseOnly then
            if self.AppendLeaderboardOutpostToSrQueue then
                pcall(self.AppendLeaderboardOutpostToSrQueue, self, queue)
            end
            if self.AppendLeaderboardOutpostCountToSrQueue then
                pcall(self.AppendLeaderboardOutpostCountToSrQueue, self,
                    queue, senderEvidencePage, hasEvidencePage)
            end
            -- Apres les snapshots territoriaux prioritaires, reconstruire la lignee GH puis
            -- rejouer les six GK avec ce contexte. Le pire historique ne bloque ainsi ni ZA,
            -- ni les timers, ni ZS/outposts pendant une minute.
            if self.AppendLeaderboardGuildKeepDailyProofsToSrQueue then
                local proofQueueStart = #queue
                pcall(self.AppendLeaderboardGuildKeepDailyProofsToSrQueue, self, queue)
                if #queue > proofQueueStart and self.AppendGuildKeepToSrQueue then
                    pcall(self.AppendGuildKeepToSrQueue, self, queue, false)
                end
            end
        end
        if not territorialResponseOnly
            and Overlord.Bounty and Overlord.Bounty.AppendToSrQueue then
            pcall(Overlord.Bounty.AppendToSrQueue, Overlord.Bounty,
                queue, minimalResponseOnly)
        end
        if not territorialResponseOnly
            and Overlord.General and Overlord.General.AppendToSrQueue then
            pcall(Overlord.General.AppendToSrQueue, Overlord.General,
                queue, minimalResponseOnly)
        end
        if not territorialResponseOnly
            and Overlord.ManualBounty and Overlord.ManualBounty.AppendToSrQueue then
            pcall(Overlord.ManualBounty.AppendToSrQueue, Overlord.ManualBounty,
                queue, minimalResponseOnly)
        end

        local isLargeEvent = Overlord.Sync:IsLargeEvent()
        if fullResponseRequested and not minimalResponseOnly
            and Overlord.Leaderboard:IsCurrentCampaignBucket() then
            responseState.preparingLadder = true
            responseState.preparationDeadline = GetTime() + 120
            local accepted = self.PrepareBoundedFullSrLeaderboardQueue
                and self:PrepareBoundedFullSrLeaderboardQueue(
                    isLargeEvent, function(success, ladderPage)
                        if responseState.finished
                            or syncResponseGeneration ~= responseGeneration
                            or not syncResponseInFlight then return end
                        if success and type(ladderPage) == "table" then
                            for i = 1, #ladderPage do
                                queue[#queue + 1] = ladderPage[i]
                            end
                        end
                        responseState.preparingLadder = false
                        if responseState.responseDeadline then
                            local interval = tonumber(responseState.messageInterval) or 0.2
                            local remaining = math.max(
                                0, #queue - (tonumber(responseState.queueIndex) or 0))
                            responseState.responseDeadline = math.max(
                                responseState.responseDeadline,
                                GetTime() + math.max(20, remaining * interval * 3))
                            priv.syncResponseDeadline = responseState.responseDeadline
                        end
                    end)
            if accepted ~= true then responseState.preparingLadder = false end
        end
        -- Treve post-victoire par front : les late joiners doivent recevoir chaque front en jeu
        if OverlordDB and OverlordDB.frontVictories then
            for frontId, victory in pairs(OverlordDB.frontVictories) do
                local vts = tonumber(victory.timestamp) or 0
                local vf = victory.faction
                local vfCode = (vf == "Alliance") and "A" or (vf == "Horde") and "H" or ""
                if vts > 0 and vfCode ~= "" and not IsStaleCampaignTimestamp(vts) then
                    table.insert(queue, { type = "VT", data = tostring(vts) .. ":" .. frontId })
                    table.insert(queue, { type = "VF", data = vts .. ":" .. vfCode .. ":" .. frontId })
                end
            end
        end
        -- Tombstones de fin de treve : indispensables aux clients absents lors du FR initial.
        if OverlordDB and OverlordDB.frontTruceResetEpoch then
            for frontId, resetEpoch in pairs(OverlordDB.frontTruceResetEpoch) do
                resetEpoch = math.floor(tonumber(resetEpoch) or 0)
                if resetEpoch > 0 and not IsStaleCampaignTimestamp(resetEpoch) then
                    table.insert(queue, { type = "FR", data = frontId .. ":" .. resetEpoch })
                end
            end
        end

        -- Domination hebdo par front : snapshot complet avec sequence de score si disponible.
        if OverlordDB and OverlordDB.frontDominationTime and Overlord.Sync.BuildDominationPayload then
            for frontId, bucket in pairs(OverlordDB.frontDominationTime) do
                local dxPayload = Overlord.Sync:BuildDominationPayload(frontId, bucket)
                if dxPayload then
                    table.insert(queue, { type = "DX", data = dxPayload })
                end
            end
        end

        -- Bonus victoire hebdo apres DX : le late joiner dispose d'abord du socle
        -- territorial, puis applique les evenements persistants VB.
        if self.AppendVictoryBonusToSrQueue and not bnetTarget then
            self:AppendVictoryBonusToSrQueue(
                queue, minimalResponseOnly, directSR)
        end

        -- Stocks de mines (MS) : utile aux late joiners qui voient 100/100 partout sinon.
        if not minimalResponseOnly then
        local res = Overlord.Ressources
        if res and res.GetMineStock and res.GetMineStockMax and Overlord.MineDatabase then
            local stockMax = res:GetMineStockMax()
            for _, mine in ipairs(Overlord.MineDatabase) do
                local s = res:GetMineStock(mine.id)
                if s < stockMax then
                    table.insert(queue, { type = "MS", data = mine.id .. ":" .. s })
                end
            end
        end
        if res and res.GetWoodStock and res.GetWoodStockMax and Overlord.WoodDatabase then
            local woodMax = res:GetWoodStockMax()
            for _, woodZone in ipairs(Overlord.WoodDatabase) do
                local s = res:GetWoodStock(woodZone.id)
                if s < woodMax then
                    table.insert(queue, { type = "WS", data = woodZone.id .. ":" .. s })
                end
            end
        end
        end
        end) -- extras SR secondaires proteges ; ZA reste toujours envoyable
        end -- not quarantinedMapOnly

        if #queue == 0 and not responseState.preparingLadder then
            -- Ne pas consommer 5-30 s de cooldown quand aucune photo territoriale
            -- n'a pu etre construite. Le prochain burst pourra reessayer aussitot.
            if syncResponseGeneration == responseGeneration then
                syncResponseInFlight = false
                priv.syncResponseDeadline = 0
                if lastSyncResponse == now then
                    lastSyncResponse = previousLastSyncResponse
                end
                if directSR and lastSRPerSender:Get(senderKey) == now then
                    lastSRPerSender:RemoveKey(senderKey)
                end
            end
            if next(priv.pendingDirectSR) then SchedulePendingDirectSRRetry() end
            return
        end

        -- Envoi echelonne via ticker unique (evite N closures par reponse SR)
        local msgInterval = 0.2
        if Overlord.Sync:IsLargeEvent() then
            msgInterval = minimalResponseOnly and 0.5 or 0.45
        end
        local consecutiveSendFailures = 0
        local projectedRows = #queue + (responseState.preparingLadder and 100 or 0)
        responseState.messageInterval = msgInterval
        responseState.responseDeadline = GetTime() + math.max(
            responseState.preparingLadder and 150 or 20,
            projectedRows * msgInterval * 3)
        priv.syncResponseDeadline = responseState.responseDeadline
        -- Les SR directes deja en attente ont ete recues avant que la taille exacte
        -- de cette reponse soit connue. Leur TTL doit suivre le deadline reel de la
        -- file en vol, sinon une seconde demande expire pendant un dump LK/LR/LC long.
        for _, pending in pairs(priv.pendingDirectSR) do
            pending.expiresAt = math.max(
                tonumber(pending.expiresAt) or 0,
                responseState.responseDeadline + 30)
        end
        local ticker
        responseTickerStarted = true
        -- Une file SR pleine peut legitiment depasser 120 s. Le watchdog constructeur
        -- ci-dessus ne doit jamais liberer son slot au milieu puis laisser une nouvelle
        -- generation annuler le tail LK/LR/LC. Ce second filet expire seulement apres le
        -- deadline dynamique du ticker.
        C_Timer.After(math.max(180, projectedRows * msgInterval * 4 + 130), function()
            if syncResponseInFlight and syncResponseGeneration == responseGeneration then
                responseState.finished = true
                syncResponseInFlight = false
                priv.syncResponseDeadline = 0
            end
        end)
        ticker = C_Timer.NewTicker(msgInterval, function()
            if syncResponseGeneration ~= responseGeneration then
                ticker:Cancel()
                responseState.finished = true
                return
            end
            local tickNow = GetTime()
            if Overlord.InstanceSuspended
                or tickNow > (tonumber(responseState.responseDeadline) or 0) then
                ticker:Cancel()
                responseState.finished = true
                if syncResponseGeneration == responseGeneration then
                    syncResponseInFlight = false
                    priv.syncResponseDeadline = 0
                end
                if next(priv.pendingDirectSR) then SchedulePendingDirectSRRetry() end
                return
            end
            local item, finished = Overlord.Sync:NextPreparedSrResponseItem(
                responseState, tickNow)
            if finished then
                ticker:Cancel()
                responseState.finished = true
                if syncResponseGeneration == responseGeneration then
                    syncResponseInFlight = false
                    priv.syncResponseDeadline = 0
                end
                if next(priv.pendingDirectSR) then SchedulePendingDirectSRRetry() end
                return
            end
            -- File territoriale deja vide, snapshot encore en construction :
            -- ce tick n'avance pas l'index et le suivant reprendra le meme slot.
            if not item then return end
            if whisperTarget then
                if Overlord.Sync:SendWhisper(item.type, item.data, whisperTarget) ~= true then
                    -- A bounded beta relay can apply backpressure. Keep this row
                    -- until accepted (or the response watchdog expires).
                    responseState.queueIndex = math.max(
                        0, (tonumber(responseState.queueIndex) or 1) - 1)
                end
            elseif bnetTarget then
                Overlord.Sync:SendToBNet(bnetTarget, item.type, item.data)
            elseif channel == "RAID" or channel == "PARTY" then
                Overlord.Sync:Send(item.type, item.data)
            else
                local cid = Overlord.Sync:GetChannelId()
                if cid and not Overlord.Sync:SendToChannel(
                    item.type, item.data, item.critical == true) then
                    consecutiveSendFailures = consecutiveSendFailures + 1
                    if consecutiveSendFailures < 10 then
                        responseState.queueIndex = math.max(
                            0, (tonumber(responseState.queueIndex) or 1) - 1)
                    end
                else
                    consecutiveSendFailures = 0
                end
            end
        end)
    end)
end

-- Empeche d'appliquer des ZS captured allie d'une ancienne campagne (timestamps tres vieux).

-- Cache unique du roster pour les validations Sync/GK et les scans de proximite. Avant,
-- trois helpers rescannaient jusqu'a 40 units pour CHAQUE membre de communaute cible.
local cachedGroupNames = {}
local cachedGroupGuilds = {}
local cachedGroupUnits = {}
local cachedGroupStamp = -10

local function GetGroupMemberNames()
    local now = GetTime()
    if now - cachedGroupStamp < 2 then return cachedGroupNames end
    cachedGroupStamp = now
    wipe(cachedGroupNames)
    wipe(cachedGroupGuilds)
    wipe(cachedGroupUnits)
    if not IsInGroup() then return cachedGroupNames end
    local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and 40 or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local raw = Overlord:SafeGetUnitName(unit, true)
            local full = Overlord.Sync.CanonicalForeverName
                and Overlord.Sync:CanonicalForeverName(raw) or nil
            if full and full ~= "" then
                local faction = UnitFactionGroup(unit)
                cachedGroupNames[full] = faction or true
                cachedGroupUnits[full:lower()] = unit
                local key = Overlord.Sync.GetCaptureContributorDedupKey
                    and Overlord.Sync:GetCaptureContributorDedupKey(full) or full:lower()
                if key and key ~= "" then
                    key = key:lower()
                    cachedGroupNames[key] = faction or true
                    cachedGroupUnits[key] = unit
                end
            end
        end
    end
    local selfFull = Overlord:SafeGetUnitName("player", true)
    if selfFull and selfFull ~= "" then
        local faction = UnitFactionGroup("player")
        cachedGroupNames[selfFull] = faction or true
        cachedGroupUnits[selfFull:lower()] = "player"
        local selfKey = Overlord.Sync.GetCaptureContributorDedupKey
            and Overlord.Sync:GetCaptureContributorDedupKey(selfFull) or selfFull:lower()
        if selfKey and selfKey ~= "" then
            selfKey = selfKey:lower()
            cachedGroupNames[selfKey] = faction or true
            cachedGroupUnits[selfKey] = "player"
        end
    end
    return cachedGroupNames
end

-- True si sender (format Name-Realm addon) est dans notre groupe / raid.
local function SyncSenderIsInOurGroup(sender)
    if not sender or sender == "" or not IsInGroup() then return false end
    local want = (Overlord.Sync.GetCaptureContributorDedupKey
        and Overlord.Sync:GetCaptureContributorDedupKey(sender)) or sender:lower()
    if not want or want == "" then return false end
    return GetGroupMemberNames()[want:lower()] ~= nil
end

function Overlord.Sync:SenderIsInOurGroup(sender)
    return SyncSenderIsInOurGroup(sender)
end

-- Resout le pool d'un paquet territorial recu par un groupe explicite :
-- CHANNEL/WHISPER restent strictement locaux ; seul un vrai membre PARTY/RAID
-- peut faire adopter un etat europeen voisin par le pool local, comme C/ZS/ZA.
function Overlord.Sync:ResolveDirectGroupTerritorialPool(remotePool, sender, sourceChannel)
    local function normalize(pool)
        if type(pool) ~= "string" then return "" end
        pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
        if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
            or pool == "fr" or pool == "de" then return "global" end
        return ""
    end
    local localPool = Overlord.GetCurrentSavedVarsPool
        and normalize(Overlord:GetCurrentSavedVarsPool()) or ""
    remotePool = normalize(remotePool)
    if localPool == "" or remotePool == "" then return nil end
    if remotePool == localPool then return localPool end
    return nil
end

function Overlord.Sync:GetGroupMemberFaction(sender)
    if not sender or sender == "" or not IsInGroup() then return nil end
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(sender) or sender:lower()
    local value = key and GetGroupMemberNames()[key:lower()] or nil
    return type(value) == "string" and value or nil
end

function Overlord.Sync:GetGroupMemberGuild(sender)
    if not sender or sender == "" or not IsInGroup() then return nil end
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(sender) or sender:lower()
    -- Rafraichit le roster au plus une fois / 2 s, puis lit la guilde du seul
    -- unit token correspondant (pas les 40 guildes du raid).
    GetGroupMemberNames()
    key = key and key:lower() or nil
    if not key then return nil end
    local cached = cachedGroupGuilds[key]
    if cached ~= nil then return cached end
    local unit = cachedGroupUnits[key]
    if not unit or not Overlord.SafeGetGuildInfo then return nil end
    local guild = Overlord:SafeGetGuildInfo(unit) or ""
    cachedGroupGuilds[key] = guild
    return guild
end

-- Ponts GK (implementation dans SyncGuildKeep.lua)
function Overlord.Sync:GetBNetLinkBand(gameAccountID)
    if not gameAccountID then return nil end
    return bnet_links[gameAccountID]
end

function Overlord.Sync:IsNearbyAddonSender(sender)
    if not sender or sender == "" then return false end
    local key = tostring(sender):lower()
    if self.GetCaptureContributorDedupKey then
        local dedupKey = self:GetCaptureContributorDedupKey(sender)
        if dedupKey and dedupKey ~= "" then key = dedupKey:lower() end
    end
    return nearbyAddonTimestamps:Get(key, GetTime()) ~= nil
end

-- Temoins temporels des captures solo. La selection ne tourne qu'une fois par
-- vague et reutilise exclusivement le cache deja alimente par la sync. Le top 5
-- est calcule en O(N * 5), sans tri complet ni lecture C_Club pilotee par le wire.
Overlord.Sync.CAPTURE_NETWORK_WITNESS_TARGETS = 5
-- On sonde jusqu'a cinq clients pour absorber les absents, puis on ne gele que
-- trois repondants. Dans un anneau de 2-3, toute paire de temoins est voisine :
-- les deux preuves finales requises peuvent donc toujours se croiser.
Overlord.Sync.CAPTURE_NETWORK_WITNESS_ROUTE_MAX = 3
Overlord.Sync.CAPTURE_NETWORK_WITNESS_HEARTBEAT = 15
Overlord.Sync.CAPTURE_NETWORK_WITNESS_CACHE_MAX_AGE = 600
Overlord.Sync.CAPTURE_NETWORK_ROUTE_TTL = 720

function Overlord.Sync:GetCaptureNetworkWitnessIdentityKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    local key = self.GetSecuritySenderKey and self:GetSecuritySenderKey(name)
        or (self.GetCaptureContributorDedupKey
            and self:GetCaptureContributorDedupKey(name))
    return key and tostring(key):lower() or nil
end

-- Graine invariante pendant toute la vague : ni le timestamp final ni le requis
-- (qui peut passer de 120 a 180) n'y figurent.
function Overlord.Sync:BuildCaptureNetworkWitnessSeed(
    zoneId, owner, originName, waveId, originGuid)
    local ownerCode = owner == "Alliance" and "A"
        or (owner == "Horde" and "H" or owner)
    local originKey = self:GetCaptureNetworkWitnessIdentityKey(originName)
    local _, _, epoch = GetCurrentSyncCampaignStartAndId()
    if type(zoneId) ~= "string" or zoneId == "" or #zoneId > 80
        or (ownerCode ~= "A" and ownerCode ~= "H") or not originKey
        or type(waveId) ~= "string" or waveId == "" or #waveId > 48
        or not waveId:match("^[%w_-]+$")
        or type(originGuid) ~= "string" or originGuid == "" or #originGuid > 80
        or not originGuid:match("^[%w-]+$") or (tonumber(epoch) or 0) <= 0 then
        return nil
    end
    return table.concat({
        tostring(math.floor(epoch)), zoneId, ownerCode, originKey, waveId, originGuid,
    }, "|")
end

-- Double empreinte 31-bit : compacte sur le wire, stable en Lua 5.1 et sans
-- allocation/bitop externe. Ce n'est pas une signature ; l'identite vient du
-- transport WHISPER et de l'accuse croise entre temoins.
function Overlord.Sync:BuildCaptureNetworkToken(input)
    if type(input) ~= "string" or input == "" then return nil end
    local h1, h2 = 5381, 52711
    for i = 1, #input do
        local b = string.byte(input, i) or 0
        h1 = (h1 * 33 + b) % 2147483647
        h2 = (h2 * 65599 + b + i) % 2147483629
    end
    return string.format("%08x%08x", h1, h2)
end

function Overlord.Sync:GetCaptureNetworkLeaderboardBaseline(originName)
    local leaderboard = Overlord.Leaderboard
    if not leaderboard or type(originName) ~= "string" or originName == "" then return nil end
    local total = leaderboard.GetMaxCapturesForDedupName
        and leaderboard:GetMaxCapturesForDedupName(originName)
        or tonumber(leaderboard.captureCount and leaderboard.captureCount[originName]) or 0
    total = tonumber(total)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if not total or total < 0 or total ~= math.floor(total)
        or total + 1 >= ceiling then return nil end
    return math.floor(total)
end

function Overlord.Sync:BuildCaptureNetworkRouteToken(seed, targets, baseline)
    baseline = tonumber(baseline)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if type(seed) ~= "string" or type(targets) ~= "table"
        or not baseline or baseline < 0 or baseline ~= math.floor(baseline)
        or baseline + 1 >= ceiling then return nil end
    local parts = { "R", seed, "B" .. tostring(math.floor(baseline)) }
    for i = 1, #targets do
        local value = type(targets[i]) == "table" and targets[i].key or targets[i]
        local key = self:GetCaptureNetworkWitnessIdentityKey(value)
        if not key then return nil end
        parts[#parts + 1] = key
    end
    if #parts < 5 then return nil end
    return self:BuildCaptureNetworkToken(table.concat(parts, "|"))
end

-- Le cache ne sert qu'a constituer un pool de cinq sondes cote origine. Les
-- receveurs ne recalculent jamais cette liste : ils valident ensuite un engagement
-- prive, ce qui tolere leurs snapshots communautaires differents.
function Overlord.Sync:GetCaptureNetworkWitnessTopCandidates(seed, originName)
    if not seed or not self.GetOnlineCommunityMembersIfFresh then return {} end
    local online = self:GetOnlineCommunityMembersIfFresh(
        self.CAPTURE_NETWORK_WITNESS_CACHE_MAX_AGE)
    if not online then return {} end
    local originKey = self:GetCaptureNetworkWitnessIdentityKey(originName)
    if not originKey then return {} end
    -- Le pool reste stable pour ce capteur pendant la campagne. Le waveId garde
    -- les preuves uniques, mais ne doit pas faire tourner les deux replicas qui
    -- possedent deja son total cumulatif n.
    local campaignEpoch = tostring(seed):match("^([^|]+)|")
    if not campaignEpoch then return {} end
    local rankingSeed = campaignEpoch .. "|" .. originKey
    local limit = self.CAPTURE_NETWORK_WITNESS_TARGETS or 5
    local top, seen = {}, {}
    local function consider(name)
        if type(name) ~= "string" or name == ""
            or not self:HasCompleteContributorIdentity(name)
            or not self.IsValidWhisperTarget or not self:IsValidWhisperTarget(name) then return end
        local key = self:GetCaptureNetworkWitnessIdentityKey(name)
        if not key or key == originKey or seen[key] then return end
        seen[key] = true
        local input = rankingSeed .. "|" .. key
        local score = 0
        for i = 1, #input do
            score = (score * 33 + (string.byte(input, i) or 0)) % 2147483647
        end
        local row = { name = name, key = key, score = score }
        local insertAt = #top + 1
        for i = 1, #top do
            if score < top[i].score or (score == top[i].score and key < top[i].key) then
                insertAt = i
                break
            end
        end
        table.insert(top, insertAt, row)
        if #top > limit then table.remove(top) end
    end
    for i = 1, #online do consider(online[i]) end
    return top
end

function Overlord.Sync:PruneCaptureNetworkRows(rows, now, maxRows)
    if type(rows) ~= "table" then return end
    local count, oldestKey, oldestAt = 0, nil, nil
    for key, row in pairs(rows) do
        local expiry = tonumber(type(row) == "table" and row.expiresAt or row) or 0
        if expiry <= now then
            rows[key] = nil
        else
            count = count + 1
            local created = tonumber(type(row) == "table" and row.createdAt) or expiry
            if not oldestAt or created < oldestAt then oldestKey, oldestAt = key, created end
        end
    end
    if count >= (maxRows or 128) and oldestKey then rows[oldestKey] = nil end
end

-- La route privee peut remplacer un lookup de faction devenu froid pendant les
-- W suivants uniquement parce que chaque temoin a verifie la faction au Q.
-- Cache-only : une sonde hostile ne doit jamais declencher un scan C_Club.
function Overlord.Sync:CaptureNetworkProbeFactionVerified(originName, owner)
    if owner ~= "Alliance" and owner ~= "Horde" then return false end
    if self.IsObservedPlayerFaction
        and self:IsObservedPlayerFaction(originName, owner) then return true end
    local bnetFaction = self.GetResolvedBNetPlayerFaction
        and self:GetResolvedBNetPlayerFaction(originName) or nil
    if bnetFaction then return bnetFaction == owner end
    local rosterFaction = self.GetOnlineCommunityMemberFactionIfFresh
        and self:GetOnlineCommunityMemberFactionIfFresh(
            originName, self.CAPTURE_NETWORK_WITNESS_CACHE_MAX_AGE) or nil
    local factions = Enum and Enum.PvPFaction
    return factions and ((owner == "Alliance" and rosterFaction == factions.Alliance)
        or (owner == "Horde" and rosterFaction == factions.Horde)) or false
end

-- Une sonde Q ne cree aucune preuve. Elle confirme seulement que la cible est
-- joignable sous une vraie identite WoW avant que l'origine ne gele sa route.
function Overlord.Sync:OnReceiveCaptureNetworkProbe(
    probeId, zoneId, owner, originName, waveId, originGuid,
    holdTime, holdRequirement, captureBaseline, sender, sourceChannel)
    local baseline = tonumber(captureBaseline)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if (sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) or type(probeId) ~= "string"
        or not probeId:match("^[0-9a-f]+$") or #probeId > 24
        or (tonumber(holdTime) or 0) > 10
        or not baseline or baseline < 0 or baseline ~= math.floor(baseline)
        or baseline + 1 >= ceiling
        or type(originGuid) ~= "string"
        or not originGuid:match("^Player%-%d+%-%w+$")
        or not self.CaptureContributorMatchesSender
        or not self:CaptureContributorMatchesSender(originName, sender)
        or not self:CaptureNetworkProbeFactionVerified(originName, owner) then return false end
    local seed = self:BuildCaptureNetworkWitnessSeed(
        zoneId, owner, originName, waveId, originGuid)
    if not seed or self:BuildCaptureNetworkToken(
        "P|" .. seed .. "|B" .. tostring(math.floor(baseline))) ~= probeId then return false end
    local zone = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
        or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId)))
    local required = Overlord.CaptureLease and Overlord.CaptureLease.NormalizeCaptureRequirement
        and Overlord.CaptureLease:NormalizeCaptureRequirement(zone, owner, holdRequirement) or nil
    if not required or self:GetCaptureNetworkLeaderboardBaseline(originName) ~= baseline then
        return false
    end

    local originKey = self:GetCaptureNetworkWitnessIdentityKey(originName)
    if not originKey then return false end
    -- Le classement est filtre par faction. La meme verification cache-only
    -- qui autorise la sonde suffit a materialiser cette metadata ; sinon le
    -- point pouvait etre stocke puis rester invisible dans les deux colonnes.
    if Overlord.Leaderboard and Overlord.Leaderboard.SetPlayerFaction then
        Overlord.Leaderboard:SetPlayerFaction(originName, owner)
    end
    self._captureNetworkWitnessProbes = self._captureNetworkWitnessProbes or {}
    local now = GetTime()
    self:PruneCaptureNetworkRows(self._captureNetworkWitnessProbes, now, 128)
    local key = originKey .. "\31" .. waveId .. "\31" .. probeId
    local previous = self._captureNetworkWitnessProbes[key]
    self._captureNetworkProbeReplyLast = self._captureNetworkProbeReplyLast or {}
    local lastReply = self._captureNetworkProbeReplyLast[originKey] or 0
    if not previous and lastReply > 0 and now - lastReply < 2 then return false end
    if not previous then self._captureNetworkProbeReplyLast[originKey] = now end
    self._captureNetworkWitnessProbes[key] = previous or {
        createdAt = now, seed = seed, probeId = probeId, waveId = waveId,
        originKey = originKey, originName = originName, baseline = baseline,
    }
    local row = self._captureNetworkWitnessProbes[key]
    if row.baseline ~= baseline then return false end
    row.expiresAt = now + 18
    -- Les deux Q d'un meme round ne doivent produire qu'une paire de NR. En
    -- revanche, le second round (+2,2 s) doit pouvoir reparer deux NR perdus.
    local lastQueued = tonumber(row.lastReplyQueuedAt) or -math.huge
    if now - lastQueued < 1.8 or (tonumber(row.replyRounds) or 0) >= 2 then
        return true
    end
    row.lastReplyQueuedAt = now
    row.replyRounds = (tonumber(row.replyRounds) or 0) + 1
    local reply = probeId .. ":" .. waveId
    for attempt = 1, 2 do
        local delay = (attempt - 1) * 1.0
        if C_Timer and C_Timer.After then
            C_Timer.After(delay, function()
                if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                    Overlord.Sync:SendWhisper("NR", reply, sender)
                end
            end)
        else
            self:SendWhisper("NR", reply, sender)
        end
    end
    return true
end

function Overlord.Sync:OnReceiveCaptureNetworkProbeReply(payload, sender, sourceChannel)
    if (sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) or type(payload) ~= "string" or #payload > 80 then return end
    local probeId, waveId = strsplit(":", payload)
    if not probeId or not probeId:match("^[0-9a-f]+$")
        or not waveId or not waveId:match("^[%w_-]+$") then return end
    local senderKey = self:GetCaptureNetworkWitnessIdentityKey(sender)
    if not senderKey then return end
    local now = GetTime()
    for _, route in pairs(self._captureNetworkWitnessRoutes or {}) do
        if not route.frozen and route.probeId == probeId and route.waveId == waveId
            and now <= (tonumber(route.expiresAt) or 0)
            and route.candidateByKey and route.candidateByKey[senderKey] then
            route.acknowledgements[senderKey] = true
            return
        end
    end
end

function Overlord.Sync:BuildCaptureNetworkWitnessRoute(
    zoneId, owner, originName, waveId, originGuid)
    local seed = self:BuildCaptureNetworkWitnessSeed(
        zoneId, owner, originName, waveId, originGuid)
    local baseline = self:GetCaptureNetworkLeaderboardBaseline(originName)
    if not seed or baseline == nil then return nil end
    self._captureNetworkWitnessRoutes = self._captureNetworkWitnessRoutes or {}
    local now = GetTime()
    for id, route in pairs(self._captureNetworkWitnessRoutes) do
        if now > (tonumber(route and route.expiresAt) or 0) then
            self._captureNetworkWitnessRoutes[id] = nil
        end
    end
    local candidates = self:GetCaptureNetworkWitnessTopCandidates(seed, originName)
    -- Apres /reload, le cache communaute peut ne pas etre encore prime. Ne pas
    -- attacher une route vide ni bruler ses deux rounds : un tick d'ouverture
    -- suivant pourra la construire des que le cache periodique est disponible.
    if #candidates < 2 then return nil end
    local byKey = {}
    for i = 1, #candidates do byKey[candidates[i].key] = candidates[i] end
    local route = {
        zoneId = zoneId, waveId = waveId, seed = seed, originGuid = originGuid,
        originKey = self:GetCaptureNetworkWitnessIdentityKey(originName),
        baseline = baseline,
        candidates = candidates, candidateByKey = byKey,
        acknowledgements = {}, targets = {}, targetKeys = {},
        probeId = self:BuildCaptureNetworkToken(
            "P|" .. seed .. "|B" .. tostring(baseline)),
        probeRounds = 0, frozen = false, createdAt = now,
        expiresAt = now + (self.CAPTURE_NETWORK_ROUTE_TTL or 720),
    }
    self._captureNetworkWitnessRoutes[zoneId] = route
    return route
end

function Overlord.Sync:SendCaptureNetworkProbePackets(route, payload, openingContext)
    if not route or route.frozen or not route.probeId or type(payload) ~= "string" then return 0 end
    if #(route.candidates or {}) < 2 then return 0 end
    route.openingPayload = route.openingPayload or payload
    route.openingContext = route.openingContext or openingContext
    local marked = route.openingPayload .. ":Q" .. route.probeId
        .. ":" .. tostring(route.baseline)
    if #marked > 250 then return 0 end
    local now = GetTime()
    route.probeRounds = (tonumber(route.probeRounds) or 0) + 1
    local probeRound = route.probeRounds
    route.commitAt = now + 2.2
    route.lastProbeAt = now
    local queued = 0
    for attempt = 1, 2 do
        for i = 1, #(route.candidates or {}) do
            local target = route.candidates[i].name
            local delay = (attempt - 1) * 1.0 + (i - 1) * 0.12
            if C_Timer and C_Timer.After then
                C_Timer.After(delay, function()
                    if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                        Overlord.Sync:SendWhisper("ZS", marked, target)
                    end
                end)
            else
                self:SendWhisper("ZS", marked, target)
            end
            queued = queued + 1
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(2.25, function()
            local sync = Overlord.Sync
            local current = sync and sync._captureNetworkWitnessRoutes
                and sync._captureNetworkWitnessRoutes[route.zoneId] or nil
            if not sync or current ~= route or route.frozen
                or tonumber(route.probeRounds) ~= probeRound
                or Overlord.InstanceSuspended or IsInInstance() then return end
            if sync:FinalizeCaptureNetworkWitnessRoute(route) then
                route.justCommittedAt = GetTime()
                sync:SendCaptureNetworkRouteCommits(route)
                local context = route.openingContext
                local openingPayload = route.openingPayload
                route.openingContext, route.openingPayload = nil, nil
                if context and openingPayload then
                    sync:SendCaptureNetworkWitnessHeartbeat(
                        context.zone, openingPayload, context.status, context.holdTime,
                        context.waveId, context.holdRequirement, context.owner,
                        context.originName, context.originGuid)
                end
            elseif probeRound < 2 then
                sync:SendCaptureNetworkProbePackets(
                    route, route.openingPayload, route.openingContext)
            else
                route.openingContext, route.openingPayload = nil, nil
            end
        end)
    end
    return queued
end

function Overlord.Sync:FinalizeCaptureNetworkWitnessRoute(route)
    if not route or route.frozen then return route and route.frozen or false end
    local targets, keys = {}, {}
    local routeLimit = math.max(2, math.min(
        tonumber(self.CAPTURE_NETWORK_WITNESS_ROUTE_MAX) or 3, 3))
    for i = 1, #(route.candidates or {}) do
        local row = route.candidates[i]
        if #targets < routeLimit and route.acknowledgements
            and route.acknowledgements[row.key] then
            targets[#targets + 1] = row.name
            keys[#keys + 1] = row.key
        end
    end
    if #targets < 2 then return false end
    route.targets, route.targetKeys = targets, keys
    route.routeId = self:BuildCaptureNetworkRouteToken(
        route.seed, keys, route.baseline)
    if not route.routeId then return false end
    route.frozen = true
    route.lastSentAt = nil
    route.expiresAt = GetTime() + (self.CAPTURE_NETWORK_ROUTE_TTL or 720)
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    return true
end

function Overlord.Sync:SendCaptureNetworkRouteCommits(route)
    if not route or not route.frozen or not route.routeId or route.commitsQueued then return 0 end
    route.commitsQueued = true
    local queued, size = 0, #(route.targets or {})
    for attempt = 1, 2 do
        for i = 1, size do
            local predecessor = route.targets[((i - 2) % size) + 1]
            local successor = route.targets[(i % size) + 1]
            local commit = table.concat({
                route.probeId, route.routeId, route.waveId, tostring(i), tostring(size),
                tostring(route.baseline), predecessor, successor,
            }, ":")
            if #commit <= 240 then
                local target = route.targets[i]
                local delay = (attempt - 1) * 1.0 + (i - 1) * 0.12
                if C_Timer and C_Timer.After then
                    C_Timer.After(delay, function()
                        if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                            Overlord.Sync:SendWhisper("NC", commit, target)
                        end
                    end)
                else
                    self:SendWhisper("NC", commit, target)
                end
                queued = queued + 1
            end
        end
    end
    return queued
end

function Overlord.Sync:ActivateCaptureNetworkRouteCommit(row)
    if not row or row.active then return false end
    row.active = true
    row.expiresAt = GetTime() + (self.CAPTURE_NETWORK_ROUTE_TTL or 720)
    local bufferedPayload, bufferedSender = row.bufferedPayload, row.bufferedSender
    row.bufferedPayload, row.bufferedSender = nil, nil
    if bufferedPayload and bufferedSender then
        local function replay()
            if Overlord.Sync and not Overlord.InstanceSuspended then
                Overlord.Sync:OnReceiveZoneState(bufferedPayload, bufferedSender, "WHISPER")
            end
        end
        if C_Timer and C_Timer.After then C_Timer.After(0, replay) else replay() end
    end
    return true
end

function Overlord.Sync:OnReceiveCaptureNetworkRouteCommit(payload, sender, sourceChannel)
    if (sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) or type(payload) ~= "string" or #payload > 240 then return end
    local probeId, routeId, waveId, slotRaw, sizeRaw, baselineRaw,
        predecessorName, successorName =
        strsplit(":", payload)
    local slot, size = math.floor(tonumber(slotRaw) or 0), math.floor(tonumber(sizeRaw) or 0)
    local baseline = tonumber(baselineRaw)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if not probeId or not probeId:match("^[0-9a-f]+$")
        or not routeId or not routeId:match("^[0-9a-f]+$")
        or not waveId or not waveId:match("^[%w_-]+$")
        or slot < 1 or slot > 3 or size < 2 or size > 3 or slot > size
        or not baseline or baseline < 0 or baseline ~= math.floor(baseline)
        or baseline + 1 >= ceiling
        or type(predecessorName) ~= "string"
        or not self:HasCompleteContributorIdentity(predecessorName)
        or type(successorName) ~= "string"
        or not self:HasCompleteContributorIdentity(successorName)
        or not self:IsValidWhisperTarget(predecessorName)
        or not self:IsValidWhisperTarget(successorName) then return end
    local originKey = self:GetCaptureNetworkWitnessIdentityKey(sender)
    local selfName = self.GetPlayerFullName and self:GetPlayerFullName() or nil
    local selfKey = self:GetCaptureNetworkWitnessIdentityKey(selfName)
    local predecessorKey = self:GetCaptureNetworkWitnessIdentityKey(predecessorName)
    local successorKey = self:GetCaptureNetworkWitnessIdentityKey(successorName)
    if not originKey or not selfKey or not predecessorKey or not successorKey
        or predecessorKey == originKey or successorKey == originKey
        or predecessorKey == selfKey or successorKey == selfKey
        or (size == 2 and predecessorKey ~= successorKey)
        or (size > 2 and predecessorKey == successorKey) then return end
    local probeKey = originKey .. "\31" .. waveId .. "\31" .. probeId
    local probe = self._captureNetworkWitnessProbes and self._captureNetworkWitnessProbes[probeKey]
    local now = GetTime()
    if not probe or probe.baseline ~= baseline
        or now > (tonumber(probe.expiresAt) or 0) then return end
    local predecessorSlot = ((slot - 2) % size) + 1
    local successorSlot = (slot % size) + 1
    local orderedNames = {}
    orderedNames[slot] = selfName
    orderedNames[predecessorSlot] = predecessorName
    orderedNames[successorSlot] = successorName
    if self:BuildCaptureNetworkRouteToken(
        probe.seed, orderedNames, baseline) ~= routeId then return end
    self._captureNetworkWitnessCommits = self._captureNetworkWitnessCommits or {}
    self:PruneCaptureNetworkRows(self._captureNetworkWitnessCommits, now, 128)
    local commitKey = probe.seed .. "\31" .. routeId
    local previous = self._captureNetworkWitnessCommits[commitKey]
    if previous and (previous.slot ~= slot or previous.size ~= size
        or previous.baseline ~= baseline
        or previous.predecessorKey ~= predecessorKey
        or previous.successorKey ~= successorKey) then
        self._captureNetworkWitnessCommits[commitKey] = nil
        return
    end
    local row = previous or {
        createdAt = now, seed = probe.seed, routeId = routeId, waveId = waveId,
        originKey = originKey, selfKey = selfKey, slot = slot, size = size,
        baseline = baseline, openedAt = tonumber(probe.createdAt) or now,
        predecessorName = predecessorName, predecessorKey = predecessorKey,
        successorName = successorName, successorKey = successorKey,
        keySet = { [selfKey] = true, [predecessorKey] = true, [successorKey] = true },
    }
    row.expiresAt = now + (self.CAPTURE_NETWORK_ROUTE_TTL or 720)
    self._captureNetworkWitnessCommits[commitKey] = row

    local earlyKey = routeId .. "\31" .. waveId .. "\31"
        .. predecessorKey .. "\31" .. tostring(predecessorSlot)
    local early = self._captureNetworkEarlyRouteAcks
        and self._captureNetworkEarlyRouteAcks[earlyKey]
    if early and early > now then self:ActivateCaptureNetworkRouteCommit(row) end

    if not row.ackQueued then
        row.ackQueued = true
        local ack = routeId .. ":" .. waveId .. ":" .. tostring(slot)
        for attempt = 1, 2 do
            local delay = (attempt - 1) * 1.0
            if C_Timer and C_Timer.After then
                C_Timer.After(delay, function()
                    if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                        Overlord.Sync:SendWhisper("NA", ack, successorName)
                    end
                end)
            else
                self:SendWhisper("NA", ack, successorName)
            end
        end
    end
end

function Overlord.Sync:OnReceiveCaptureNetworkRouteAck(payload, sender, sourceChannel)
    if (sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) or type(payload) ~= "string" or #payload > 90 then return end
    local routeId, waveId, senderSlotRaw = strsplit(":", payload)
    local senderSlot = math.floor(tonumber(senderSlotRaw) or 0)
    if not routeId or not routeId:match("^[0-9a-f]+$")
        or not waveId or not waveId:match("^[%w_-]+$")
        or senderSlot < 1 or senderSlot > 3 then return end
    local senderKey = self:GetCaptureNetworkWitnessIdentityKey(sender)
    if not senderKey then return end
    local now, matched = GetTime(), false
    for _, row in pairs(self._captureNetworkWitnessCommits or {}) do
        local expectedSlot = ((row.slot - 2) % row.size) + 1
        if row.routeId == routeId and row.waveId == waveId
            and row.predecessorKey == senderKey and senderSlot == expectedSlot
            and now <= (tonumber(row.expiresAt) or 0) then
            self:ActivateCaptureNetworkRouteCommit(row)
            matched = true
        end
    end
    if matched then return end
    self._captureNetworkEarlyRouteAcks = self._captureNetworkEarlyRouteAcks or {}
    self:PruneCaptureNetworkRows(self._captureNetworkEarlyRouteAcks, now, 128)
    local key = routeId .. "\31" .. waveId .. "\31" .. senderKey .. "\31" .. tostring(senderSlot)
    self._captureNetworkEarlyRouteAcks[key] = now + 12
end

function Overlord.Sync:FindCaptureNetworkWitnessCommit(seed, routeId, slot, requireActive)
    if not seed or type(routeId) ~= "string" or not routeId:match("^[0-9a-f]+$") then return nil end
    local row = self._captureNetworkWitnessCommits
        and self._captureNetworkWitnessCommits[seed .. "\31" .. routeId] or nil
    if not row or GetTime() > (tonumber(row.expiresAt) or 0)
        or tonumber(row.slot) ~= tonumber(slot) or (requireActive and not row.active) then return nil end
    return row
end

function Overlord.Sync:BufferCaptureNetworkWitnessProgress(
    zoneId, owner, originName, waveId, originGuid, routeId, slot, payload, sender)
    local seed = self:BuildCaptureNetworkWitnessSeed(
        zoneId, owner, originName, waveId, originGuid)
    local row = seed and self:FindCaptureNetworkWitnessCommit(seed, routeId, slot, false) or nil
    if not row or row.active then return false end
    row.bufferedPayload, row.bufferedSender = payload, sender
    return true
end

function Overlord.Sync:ResolveCaptureNetworkWitnessRoute(
    zoneId, owner, originName, waveId, originGuid, candidateName,
    routeId, claimedSlot)
    local seed = self:BuildCaptureNetworkWitnessSeed(
        zoneId, owner, originName, waveId, originGuid)
    local row = seed and self:FindCaptureNetworkWitnessCommit(
        seed, routeId, claimedSlot, true) or nil
    local candidateKey = self:GetCaptureNetworkWitnessIdentityKey(candidateName)
    if not row or not candidateKey or candidateKey ~= row.selfKey then return nil end
    return {
        seed = seed, routeId = routeId, slot = row.slot, size = row.size,
        baseline = row.baseline, openedAt = row.openedAt,
        keySet = row.keySet,
        predecessorName = row.predecessorName, predecessorKey = row.predecessorKey,
        successorName = row.successorName, successorKey = row.successorKey,
    }
end

function Overlord.Sync:GetPersistableCaptureNetworkWitnessRoute(zoneId, waveId)
    local route = self._captureNetworkWitnessRoutes
        and self._captureNetworkWitnessRoutes[zoneId] or nil
    if not route or not route.frozen or not route.routeId
        or route.waveId ~= waveId or #(route.targets or {}) < 2 then return nil end
    return {
        routeId = route.routeId,
        originGuid = route.originGuid,
        baseline = route.baseline,
        targets = table.concat(route.targets, ","),
    }
end

-- /reload conserve le meme wave+GUID+route. Les temoins deja engages peuvent
-- ainsi reprendre le heartbeat ; un trou superieur a la borne temporelle reste
-- refuse par ZoneCaptureLease.
function Overlord.Sync:RestoreCaptureNetworkWitnessRouteFromSaved(
    zone, owner, originName, waveId, originGuid)
    local saved = OverlordDB and OverlordDB.zones and zone
        and OverlordDB.zones[zone.id] or nil
    if not saved or saved.localCapture ~= true
        or saved.localCaptureWaveId ~= waveId
        or saved.captureNetworkWitnessOriginGuid ~= originGuid
        or type(saved.captureNetworkWitnessTargets) ~= "string"
        or type(saved.captureNetworkWitnessRouteId) ~= "string" then return nil end
    local baseline = tonumber(saved.captureNetworkWitnessBaseline)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if not baseline or baseline < 0 or baseline ~= math.floor(baseline)
        or baseline + 1 >= ceiling
        or self:GetCaptureNetworkLeaderboardBaseline(originName) ~= baseline then return nil end
    local seed = self:BuildCaptureNetworkWitnessSeed(
        zone.id, owner, originName, waveId, originGuid)
    if not seed then return nil end
    local targets, keys, seen = {}, {}, {}
    for name in saved.captureNetworkWitnessTargets:gmatch("[^,]+") do
        if #targets >= 3 or not self:HasCompleteContributorIdentity(name)
            or not self:IsValidWhisperTarget(name) then return nil end
        local key = self:GetCaptureNetworkWitnessIdentityKey(name)
        if not key or key == self:GetCaptureNetworkWitnessIdentityKey(originName)
            or seen[key] then return nil end
        seen[key] = true
        targets[#targets + 1], keys[#keys + 1] = name, key
    end
    if #targets < 2 then return nil end
    local routeId = self:BuildCaptureNetworkRouteToken(seed, keys, baseline)
    if routeId ~= saved.captureNetworkWitnessRouteId then return nil end
    self._captureNetworkWitnessRoutes = self._captureNetworkWitnessRoutes or {}
    local route = {
        zoneId = zone.id, waveId = waveId, seed = seed, originGuid = originGuid,
        originKey = self:GetCaptureNetworkWitnessIdentityKey(originName),
        baseline = baseline,
        targets = targets, targetKeys = keys, routeId = routeId,
        frozen = true, restored = true, expiresAt = GetTime() + 600,
    }
    self._captureNetworkWitnessRoutes[zone.id] = route
    return route
end

function Overlord.Sync:SendCaptureNetworkWitnessHeartbeat(
    zone, payload, status, holdTime, waveId, holdRequirement,
    owner, originName, originGuid)
    if not zone or not zone.id or not payload or payload == ""
        or not waveId or waveId == "" then return 0 end
    self._captureNetworkWitnessRoutes = self._captureNetworkWitnessRoutes or {}
    local route = self._captureNetworkWitnessRoutes[zone.id]
    local now = GetTime()
    local expectedSeed = self:BuildCaptureNetworkWitnessSeed(
        zone.id, owner, originName, waveId, originGuid)
    if not expectedSeed then return 0 end
    local openingHeartbeat = status == "in_progress"
        and zone.holdAuthorityLocal and (tonumber(holdTime) or 0) <= 10
    local routeMissing = not route or route.seed ~= expectedSeed
    if routeMissing and status == "in_progress"
        and self.RestoreCaptureNetworkWitnessRouteFromSaved then
        route = self:RestoreCaptureNetworkWitnessRouteFromSaved(
            zone, owner, originName, waveId, originGuid)
        routeMissing = not route or route.seed ~= expectedSeed
    end
    if openingHeartbeat and routeMissing then
        route = self:BuildCaptureNetworkWitnessRoute(
            zone.id, owner, originName, waveId, originGuid)
    end
    if not route or route.seed ~= expectedSeed then return 0 end
    local openingCommitted = false
    if not route.frozen then
        if status ~= "in_progress" or not openingHeartbeat then return 0 end
        if (tonumber(route.probeRounds) or 0) == 0 then
            return self:SendCaptureNetworkProbePackets(route, payload, {
                zone = zone, status = status, holdTime = holdTime, waveId = waveId,
                holdRequirement = holdRequirement, owner = owner,
                originName = originName, originGuid = originGuid,
            })
        end
        if now < (tonumber(route.commitAt) or math.huge) then return 0 end
        if not self:FinalizeCaptureNetworkWitnessRoute(route) then
            if (tonumber(route.probeRounds) or 0) < 2 then
                return self:SendCaptureNetworkProbePackets(
                    route, route.openingPayload or payload, route.openingContext)
            end
            return 0
        end
        openingCommitted = true
        route.justCommittedAt = now
        self:SendCaptureNetworkRouteCommits(route)
        route.openingContext, route.openingPayload = nil, nil
    end
    -- Un /reload peut annuler les timers NC/NA juste apres le gel de la route.
    -- Rejouer une seule fois l'engagement avant le premier W restaure cette
    -- petite fenetre, sans trafic periodique supplementaire.
    if route.restored and not route.commitsQueued then
        route.justCommittedAt = now
        self:SendCaptureNetworkRouteCommits(route)
        route.restored = nil
    end
    if not route.routeId or #(route.targets or {}) < 2 then return 0 end
    local recentlyCommitted = route.justCommittedAt
        and now - route.justCommittedAt < 3 or false
    local currentRequirement = math.floor(tonumber(holdRequirement) or 0)
    local previousRequirement = tonumber(route.lastRequirement)
    local requirementChanged = status == "in_progress" and currentRequirement > 0
        and previousRequirement and currentRequirement ~= previousRequirement
    if status == "in_progress" then
        local lastSentAt = tonumber(route.lastSentAt)
        if not requirementChanged and lastSentAt and now - lastSentAt
            < self.CAPTURE_NETWORK_WITNESS_HEARTBEAT - 0.5 then return 0 end
    elseif status ~= "captured" then
        self._captureNetworkWitnessRoutes[zone.id] = nil
        return 0
    end

    route.lastSentAt = now
    if currentRequirement > 0 then route.lastRequirement = currentRequirement end
    route.expiresAt = now + ((status == "captured") and 45 or 600)
    -- Le premier W n'est envoye qu'apres probe, reselection et engagement croise.
    -- Caches divergents et cibles offline ne peuvent donc plus casser l'anneau.
    local attempts = (status == "captured" or openingCommitted or recentlyCommitted
        or requirementChanged) and 2 or 1
    local retryDelay = (status == "captured") and 2 or 1
    local queued = 0
    for attempt = 1, attempts do
        for i = 1, #route.targets do
            local target = route.targets[i]
            local markedPayload = payload .. ":W" .. tostring(i) .. ":" .. route.routeId
            local finalLead = status == "captured" and 0.8
                or ((openingCommitted or recentlyCommitted) and 1.4 or 0)
            local delay = finalLead + (attempt - 1) * retryDelay + (i - 1) * 0.12
            if #markedPayload <= 250 and C_Timer and C_Timer.After then
                C_Timer.After(delay, function()
                    if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                        Overlord.Sync:SendWhisper("ZS", markedPayload, target)
                    end
                end)
                queued = queued + 1
            elseif #markedPayload <= 250 then
                self:SendWhisper("ZS", markedPayload, target)
                queued = queued + 1
            end
        end
    end
    return queued
end

-- Le payload C riche est indispensable au classement. Il est livre aux cibles
-- gelees de l'ouverture avant le ZS final W, avec un seul retry borne.
function Overlord.Sync:SendCaptureFinalToNetworkWitnesses(
    zoneId, waveId, originGuid, payload)
    local routes = self._captureNetworkWitnessRoutes
    local route = routes and routes[zoneId]
    if not route or not route.frozen or route.waveId ~= waveId
        or route.originGuid ~= originGuid or route.finalCSentAt
        or type(payload) ~= "string" or payload == "" or #payload > 250 then return 0 end
    route.finalCSentAt = GetTime()
    route.expiresAt = route.finalCSentAt + 45
    local queued = 0
    for attempt = 1, 2 do
        for i = 1, #route.targets do
            local target = route.targets[i]
            local delay = (attempt - 1) * 2 + (i - 1) * 0.12
            if C_Timer and C_Timer.After then
                C_Timer.After(delay, function()
                    if Overlord.Sync and not Overlord.InstanceSuspended and not IsInInstance() then
                        Overlord.Sync:SendWhisper("C", payload, target)
                    end
                end)
                queued = queued + 1
            else
                self:SendWhisper("C", payload, target)
                queued = queued + 1
            end
        end
    end
    return queued
end

-- Notre updatedAt est trop frais (ex. faux ZS) alors qu'un allie envoie encore captured local
-- avec un ts plus petit : le merge classique ignorait tout ts < localTs -> carte rouge figee.
local function TryHealStaleEnemyOwnerFromFriendlyCapture(zone, status, owner, ts, sender, opts)
    if status ~= "captured" or owner ~= Overlord.PlayerFaction or not zone then return false end
    local ef = Overlord.Zones:GetEnemyFaction()
    if zone.owner ~= ef then return false end
    if zone.isHolding and zone.holdAuthorityLocal then return false end
    opts = opts or {}
    local now = time()
    local age = now - ts
    local maxAge = opts.loginUnconfirmed and TUNING.LOGIN_FRIENDLY_CAPTURE_HEAL_MAX_AGE
        or TUNING.STALE_FRIENDLY_CAPTURE_HEAL_MAX_AGE
    if ts <= 0 or age > maxAge then return false end

    local trusted = (sender and sender ~= "" and SyncSenderIsInOurGroup(sender))
    if zone.isCapital then
        -- Capitale : correction plus stricte, uniquement depuis le groupe/raid et tres recente.
        -- Evite qu'un vieux relais communautaire reflippe une victoire ou une reprise de base.
        if not trusted or age > TUNING.STALE_CAPITAL_FRIENDLY_CAPTURE_HEAL_MAX_AGE then return false end
    elseif not trusted and Overlord.ZoneControl and Overlord.Zones then
        local pz = Overlord.Zones:GetCurrentPlayerZone()
        if pz and pz.id == zone.id then
            local f, e = Overlord.ZoneControl:ScanNearbyPlayers(zone)
            -- Au moins nous + un allie visible, aucun ennemi en nameplate (furtifs peuvent fausser).
            if e == 0 and f >= 2 then
                trusted = true
            end
        end
    end
    if not trusted then return false end

    zone.status = "captured"
    zone.owner = owner
    zone.capturedTime = ts
    zone.isHolding = false
    zone.isContested = false
    zone.isPaused = false
    zone.holdStartTime = nil
    zone.holdAuthorityLocal = nil
    zone.previousOwner = nil
    Overlord.Sync:ClearPointSyncLoginQuarantine(zone)
    -- Garder le timestamp de la capture soignee : utiliser "now" rendrait ce client trop
    -- autoritaire et pourrait rejeter des paquets legitimes arrives avec un ts intermediaire.
    zone.updatedAt = ts
    zone.holdTimeRequired = 120
    CompleteAcceptedZsTerminal(zone, zone.status)
    return true
end

-- Recoit l'etat complet d'une zone avec proprietaire et timestamp (cross-faction)
function Overlord.Sync:OnReceiveZoneState(payload, sender, sourceChannel)
    if not payload then return end
    local syncGateWasPending = Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()

    local VALID_ZS_STATUSES = { in_progress = true, captured = true, available = true, locked = true }
    -- 8e champ optionnel : holdTimeRequired emetteur (retro-compat : absents des vieux clients)
    -- 9e champ optionnel : nom du capteur (avec royaume) pour affichage dans les alertes
    -- 10e champ optionnel : shard du capteur (couche WoW)
    -- 11e champ optionnel : identifiant stable de la tentative (bail ZS / release ZR)
    -- 12e champ : GUID Blizzard de l'origine, requis pour les attestations finales.
    -- 13e champ : duree effectivement terminee, liee au claim final.
    -- 14e champ : Q<probe> a l'ouverture, puis W1..W3 sur les heartbeats engages.
    -- 15e champ : baseline du classement pour Q, route gelee pour W.
    -- 16e/17e champs : affichage observateur + timestamp d'envoi SR. Ils restent
    -- ephemeres et empechent un relais tardif de reappliquer deux fois l'age.
    local zoneId, status, kills, holdTime, ownerCode, ts, siegePhaseStr, remoteHoldReqStr,
        zsCapturerName, zsCapturerShardStr, zsWaveId, zsOriginGuid,
        zsFinalRequirement, zsNetworkWitness, zsNetworkRouteId,
        zsRelayedDisplayHold, zsRelayedDisplayAt = strsplit(":", payload)
    -- Un W honnete est toujours un addon whisper cible. Ignorer le marqueur sur
    -- PARTY/RAID/CHANNEL/BNet empeche un diffuseur de designer tous les receveurs
    -- et garantit la borne stricte de trois temoins engages.
    if (sourceChannel ~= "WHISPER" and not (sourceChannel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) then
        zsNetworkWitness, zsNetworkRouteId = nil, nil
    end
    local zsCapturerShard = tonumber(zsCapturerShardStr)
    if not VALID_ZS_STATUSES[status] then return end
    local wireStatus = status
    kills = math.max(0, math.min(tonumber(kills) or 0, TUNING.MAX_SYNC_KILLS))
    holdTime = math.max(0, math.min(tonumber(holdTime) or 0, TUNING.MAX_SYNC_HOLD_TIME))
    ts = NormalizeRemoteTimestamp(ts)
    if not ts then return end
    if (status == "captured" or status == "in_progress") and IsStaleCampaignTimestamp(ts) then return end
    local knownStateZone = zoneId and (Overlord.Zones:GetZone(zoneId)
        or (Overlord.Fronts and Overlord.Fronts.GetZone
            and select(1, Overlord.Fronts:GetZone(zoneId))))
    if not knownStateZone then return end
    local remoteSiegePhase = tonumber(siegePhaseStr) or 0
    local remoteHoldParsed = tonumber(remoteHoldReqStr)
    if remoteHoldParsed then
        remoteHoldParsed = math.min(math.max(remoteHoldParsed, 30), TUNING.MAX_SYNC_HOLD_TIME)
    end

    local owner = nil
    if ownerCode == "A" then owner = "Alliance"
    elseif ownerCode == "H" then owner = "Horde" end
    if (status == "available" or status == "locked") and owner then
        -- Compat 7.0.8-7.0.12 : ces clients pouvaient envoyer la vue locale
        -- "locked/available" d'une zone deja capturee. Le reseau doit conserver la capture.
        status = "captured"
    end
    if (status == "captured" or status == "in_progress") and not owner then return end
    if ShouldRejectStaleTruceResetZone(zoneId, ts) then return end
    if ShouldRejectPostVictoryZoneOwner(zoneId, owner, status, ts, "ZS") then return end
    if status == "in_progress" and type(zsNetworkWitness) == "string" then
        local probeId = zsNetworkWitness:match("^Q([0-9a-f]+)$")
        if probeId and self.OnReceiveCaptureNetworkProbe then
            self:OnReceiveCaptureNetworkProbe(
                probeId, zoneId, owner, zsCapturerName, zsWaveId, zsOriginGuid,
                holdTime, remoteHoldParsed, zsNetworkRouteId, sender, sourceChannel)
            -- Une sonde ne doit jamais ouvrir elle-meme une preuve temporelle.
            zsNetworkWitness, zsNetworkRouteId = nil, nil
        end
    end
    local progressDecision
    local progressPreparedBase
    local stateClaimKey
    local captureFinalClaimKey
    local finalDeliveryDedupKey
    local directRevertVerified = false
    if status == "in_progress" then
        -- La blacklist est consultee avant d'enregistrer le moindre temoignage.
        -- AntiSpoofCheck ne comptabilise ensuite que sender == capturer.
        if sender and self:AntiSpoofCheck(sender, zoneId, zsCapturerName) then return end
        -- Seul le capteur direct ouvre/renouvelle la vue orange. Un relais ne vote
        -- plus localement : il declenche une demande SR canonique au capteur.
        if not self:CaptureContributorMatchesSender(zsCapturerName, sender) then
            self:RequestDirectCaptureOriginSnapshot(zsCapturerName, zoneId)
            return
        end
        progressDecision = Overlord.CaptureLease and Overlord.CaptureLease.ValidateProgress
            and Overlord.CaptureLease:ValidateProgress(
                zoneId, owner, zsCapturerName, zsWaveId, ts, holdTime, kills,
                remoteHoldParsed, zsCapturerShard, sender, zsOriginGuid,
                zsNetworkWitness, zsNetworkRouteId,
                zsRelayedDisplayHold, zsRelayedDisplayAt)
        if not progressDecision then return end
        if type(zsNetworkWitness) == "string" and zsNetworkWitness:match("^W[1-5]$")
            and not progressDecision.networkDesignated
            and self.BufferCaptureNetworkWitnessProgress then
            self:BufferCaptureNetworkWitnessProgress(
                zoneId, owner, zsCapturerName, zsWaveId, zsOriginGuid,
                zsNetworkRouteId, tonumber(zsNetworkWitness:sub(2)), payload, sender)
        end
        -- Le whisper W peut suivre un ZS large de meme timestamp (ou legerement
        -- plus recent). Il nourrit la preuve sans dependre du merge d'etat.
        if progressDecision.networkDesignated and Overlord.CaptureLease
            and Overlord.CaptureLease.ObserveNetworkProgress then
            Overlord.CaptureLease:ObserveNetworkProgress(
                knownStateZone, owner, progressDecision)
        end
        holdTime = progressDecision.hold
        kills = progressDecision.kills
        ts = progressDecision.ts
        -- Toujours afficher la projection validee par CaptureLease du capteur direct.
        zsRelayedDisplayHold = progressDecision.observerDisplayHold
        zsRelayedDisplayAt = progressDecision.observerDisplayAt
        -- Le requis direct reste ephemere et borne par ZoneCaptureLease. Il sert
        -- a l'UI et a la preuve temporelle, jamais a la persistance/takeover.
        remoteHoldParsed = progressDecision.proofRequired
        local activeLease = knownStateZone._remoteCaptureLease
        if activeLease and tonumber(activeLease.effectiveRequired)
            and (not remoteHoldParsed
                or remoteHoldParsed < tonumber(activeLease.effectiveRequired)) then
            remoteHoldParsed = tonumber(activeLease.effectiveRequired)
        end
        zsCapturerShard = progressDecision.shard
    else
        -- Un captured moderne rejoint la meme claim minimale que C. Un revert
        -- available ne peut fermer que le bail direct de ce meme capteur.
        local _, campaignId, campaignEpoch = GetCurrentSyncCampaignStartAndId()
        captureFinalClaimKey = status == "captured" and self.BuildCaptureFinalClaimKey
            and self:BuildCaptureFinalClaimKey(
                zoneId, ownerCode, ts, zsCapturerName, zsWaveId, zsOriginGuid,
                zsFinalRequirement) or nil
        if status == "captured" and not captureFinalClaimKey then return end
        if captureFinalClaimKey and Overlord.CaptureLease and Overlord.CaptureLease.ShouldRejectFinal
            and Overlord.CaptureLease:ShouldRejectFinal(
                knownStateZone, zsCapturerName, zsWaveId) then return end
        if captureFinalClaimKey and Overlord.CaptureLease
            and Overlord.CaptureLease.FinalSatisfiesLocalRequirement
            and not Overlord.CaptureLease:FinalSatisfiesLocalRequirement(
                knownStateZone, owner, zsCapturerName, zsWaveId,
                zsFinalRequirement) then return end
        stateClaimKey = captureFinalClaimKey or table.concat({
            tostring(campaignEpoch or campaignId or 0), tostring(zoneId or ""),
            tostring(status or ""), tostring(ownerCode or ""), tostring(ts or 0),
            tostring(kills or 0), tostring(holdTime or 0), tostring(remoteSiegePhase or 0),
            tostring(remoteHoldParsed or 0), tostring(zsCapturerName or ""),
            tostring(zsCapturerShard or 0), tostring(zsWaveId or ""), tostring(zsOriginGuid or ""),
            tostring(zsFinalRequirement or ""),
        }, ":")
        local originDirect = captureFinalClaimKey and self.CaptureContributorMatchesSender
            and self:CaptureContributorMatchesSender(zsCapturerName, sender) or false
        local activeRemoteLease = knownStateZone._remoteCaptureLease
        local directRevertOrigin = activeRemoteLease
            and (activeRemoteLease.originName or activeRemoteLease.originKey) or nil
        directRevertVerified = not captureFinalClaimKey and status == "available"
            and holdTime == 0 and activeRemoteLease
            and activeRemoteLease.directValidated == true
            and ts >= (tonumber(activeRemoteLease.lastRemoteTs) or 0)
            and self.CaptureContributorMatchesSender
            and self:CaptureContributorMatchesSender(directRevertOrigin, sender) or false
        -- Le ZS terminal direct porte la meme claim moderne complete que C.
        -- L'identite WoW du sender suffit : aucun temoin territorial n'est requis.
        local terminalVerified = originDirect or directRevertVerified
        if not captureFinalClaimKey and not directRevertVerified then
            -- Un available sans owner est destructeur. Il ne converge directement
            -- que comme fin a zero, fraiche, du bail ouvert par ce meme sender ;
            -- les resets et snapshots neutres passent par FR/ZA avec tombstone.
            return
        end
        if terminalVerified and captureFinalClaimKey and originDirect
            and self.CreditDirectCaptureFromFinalState then
            self:CreditDirectCaptureFromFinalState(
                captureFinalClaimKey, zsCapturerName, sender)
        end
        if not terminalVerified then return end
        if captureFinalClaimKey then
            -- Le final authentifie autorise owner/status/ts uniquement. Les
            -- valeurs de gameplay du dernier paquet restent non autoritaires.
            kills, holdTime, remoteSiegePhase, remoteHoldParsed, zsCapturerShard = 0, 0, 0, nil, nil
        end
    end

    -- Dedoublonner seulement APRES la validation. Une copie BNet/Bridge refusee ne
    -- peut plus bloquer la copie WoW directe. Un terminal deja applique reste
    -- globalement idempotent.
    do
        local nowD = GetTime()
        local senderKey = self.GetCaptureContributorDedupKey
            and self:GetCaptureContributorDedupKey(sender) or tostring(sender or "")
        local sourceRank = progressDecision and (progressDecision.direct and "D" or "R") or "F"
        local dedupKey = stateClaimKey and ("FINAL\31" .. stateClaimKey)
            or (sourceRank .. "\31" .. tostring(senderKey) .. "\31" .. payload)
        if priv.zsPayloadDedup:Get(dedupKey, nowD, priv.zsPayloadDedupSec) ~= nil then return end
        if captureFinalClaimKey then
            -- Un final moderne n'est dedup qu'apres mutation/idempotence canonique.
            -- Un paquet valide mais non applicable doit rester rejouable.
            if not priv.zsPayloadDedup:CanRemember(dedupKey, nowD, false) then return end
            finalDeliveryDedupKey = dedupKey
        else
            if not priv.zsPayloadDedup:Remember(dedupKey, nowD, nowD, false) then return end
        end
    end

    local function CommitAcceptedZsFinal(targetZone)
        if status ~= "captured" or not captureFinalClaimKey or not targetZone then
            return false
        end
        self:FinalizeAcceptedCaptureFinal(
            targetZone, zoneId, zsCapturerName, zsWaveId,
            ts, priv.zsPayloadDedup, finalDeliveryDedupKey)
        -- Une fin ZS canonique peut etre la derniere zone de n'importe quel camp.
        -- Le check est idempotent et ne doit pas dependre d'un ancien overlay visuel.
        self:CheckTotalVictoryFromSync()
        return true
    end

    if progressDecision then
        -- Anti-spoof et preuve C ne concernent que le capteur WoW authentifie.
        if progressDecision.direct and owner and self.RecordCaptureCreditProgressEvidence then
            self:RecordCaptureCreditProgressEvidence(sender, zsCapturerName, zoneId, owner, holdTime)
        end
        progressPreparedBase = Overlord.CaptureLease.PrepareRemote
            and Overlord.CaptureLease:PrepareRemote(knownStateZone) or nil
    end
    -- Un assaut ou une capture ZS valide signale du combat, meme si notre etat local
    -- plus recent n'a ensuite rien a appliquer.
    if owner and (wireStatus == "in_progress" or wireStatus == "captured")
        and Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
        Overlord.FrontActivity:RecordByZoneRef(zoneId, zsCapturerName, ts)
    end
    if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
    if Overlord.WaitingForSync then Overlord.WaitingForSync = nil end
    if not progressDecision or progressDecision.direct then
        LearnCapturerShardFromZsSender(sender, zsCapturerName)
    end

    local zone = Overlord.Zones:GetZone(zoneId)
    if not zone then
        local inactiveZone = Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId))
        local oldInactiveStatus = inactiveZone and inactiveZone.status
        local oldInactiveOwner = inactiveZone and inactiveZone.owner
        local oldInactivePreviousOwner = inactiveZone and inactiveZone.previousOwner
        local enemyFaction = Overlord.Zones:GetEnemyFaction()
        local inactiveApplied = ApplyInactiveFrontZoneState(
            zoneId, status, kills, holdTime, owner, ts, remoteSiegePhase, remoteHoldParsed,
            (status == "captured") and ts or nil,
            zsCapturerName, progressDecision, progressPreparedBase, nil,
            directRevertVerified, zsRelayedDisplayHold, zsRelayedDisplayAt)
        if inactiveApplied and inactiveZone and owner then
            StoreZsRelayCapturerFromZs(inactiveZone, status, owner, zsCapturerName, zsCapturerShard)
        end
        local inactiveCaptureCanonical = status == "captured" and inactiveZone and owner
            and inactiveZone.owner == owner and inactiveZone.status ~= "in_progress"
            and (tonumber(inactiveZone.capturedTime) or 0) >= ts
        if inactiveZone and (inactiveApplied or inactiveCaptureCanonical)
            and status == "captured" then
            if not inactiveApplied and Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                Overlord.CaptureLease:Complete(inactiveZone)
            end
            CommitAcceptedZsFinal(inactiveZone)
            -- ApplyInactiveFrontZoneState a persiste avant la finalisation.
            PersistSyncedZoneState(inactiveZone)
        elseif inactiveApplied and inactiveZone and inactiveZone.status == "captured" then
            -- Un revert terminal available/locked peut restaurer une capitale.
            -- Ce nouvel etat canonique ne doit garder aucune vague precedente.
            inactiveZone.previousOwner = nil
            if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
                Overlord.Zones:ClearCaptureFinalUnattestedState(inactiveZone)
            end
            PersistSyncedZoneState(inactiveZone)
        end
        if inactiveApplied and inactiveZone and owner then
            if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
            if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
                Overlord.MapMarkers:RequestOverlayRefresh()
            end
            if Overlord.UI then Overlord.UI:RequestRefresh() end
            if status == "in_progress" and owner == enemyFaction
                and self:CanEmitEnemyCaptureAlert(progressDecision) then
                -- Ne jamais alerter sur un replay stale refuse par ApplyInactiveFrontZoneState.
                TryPrintEnemyCapturingAlert(
                    inactiveZone, EffectiveCapturerNameForAlert(inactiveZone, zsCapturerName), ts)
            elseif status == "captured" and owner == enemyFaction
                and ShouldAlertEnemyZoneCapture(oldInactiveStatus, oldInactiveOwner, oldInactivePreviousOwner, owner, inactiveZone) then
                PrintCaptureChatOnce(inactiveZone, owner, EffectiveCapturerNameForAlert(inactiveZone, zsCapturerName), ts)
            elseif status == "captured" and owner == Overlord.PlayerFaction then
                priv.enemyAlertLast[inactiveZone.id] = nil
                priv.enemyAlertSkipUntil[inactiveZone.id] = nil
                priv.enemyAlertEmitted[inactiveZone.id] = nil
            end
            ClearZsRelayAfterZsApply(inactiveZone, status, owner)
        end
        return
    end

    local localTs = zone.updatedAt or 0
    local oldStatus, oldOwner = zone.status, zone.owner
    local oldPreviousOwner = zone.previousOwner
    local progressAdopted = false
    local progressLeaseOpened = false
    local progressEffectEligible = false
    local function AdoptAcceptedProgress()
        if not progressDecision then return true end
        if progressAdopted then return true end
        if not Overlord.CaptureLease or not Overlord.CaptureLease.AdoptRemote then
            return false
        end
        local adopted, opened, effectEligible = Overlord.CaptureLease:AdoptRemote(
            zone, owner, zsCapturerName, progressDecision, progressPreparedBase)
        if not adopted then return false end
        progressAdopted = true
        progressLeaseOpened = opened == true
        progressEffectEligible = effectEligible == true
        local activeLease = zone._remoteCaptureLease
        if activeLease and tonumber(activeLease.effectiveRequired) then
            remoteHoldParsed = tonumber(activeLease.effectiveRequired)
        end
        return true
    end

    -- Cas special : ennemi en train de capturer (in_progress, owner=Horde quand on est Alliance)
    -- On accepte meme si ts < localTs : une sync Alliance recente peut avoir localTs > ts, mais on DOIT
    -- afficher la phase orange. Sinon on passe directement de bleu a rouge (bug "Trépas rouge tout de suite")
    -- On refuse seulement si on a deja "ennemi a capture" (status=captured, owner=ennemi) plus recent
    local enemyFaction = Overlord.Zones:GetEnemyFaction()
    -- Pas de force-accept : les captures actives ont toujours ts = time() (frais),
    -- donc ts > localTs naturellement. Forcer l'acceptation des vieux ZS creait un cycle
    -- de propagation ou les timestamps gonfles (localTs+1) etaient relayes a d'autres joueurs,
    -- faisant flipper les zones capturees en boucle.

    -- Autorite locale : pendant notre capture physique, ignorer les ZS ennemis "in_progress"
    -- qui peuvent etre des echos/replays/reverts distants.
    -- Un observateur distant qui ne voit pas d'ennemis (phase/layer/shard) peut broadcaster un
    -- revert en boucle, cassant notre timer et creant une oscillation infinie
    -- (le capteur recommence holdTime=0 a chaque reset -> boucle de flip).
    if IsLocalAuthoritativeCapture(zone) and owner == enemyFaction
        and status == "in_progress" then
        zone.zsRelayCapturerName = nil
        zone.zsRelayCapturerShard = nil
        return
    end

    -- Cap anti-exploit pour les in_progress allies : evite la capture instantanee
    -- quand 2 joueurs de meme faction recoivent mutuellement des timers via sync.
    -- Ne s'applique PAS aux captures ennemies (on ne peut pas capturer pour l'ennemi).
    -- Si le ZS porte holdTimeRequired (8e champ), on s'en sert pour le plafond (barricade / renfort / capitale).
    local requiredForCap = zone.holdTimeRequired or 120
    if status == "in_progress" then
        if Overlord.Zones and Overlord.Zones.GetCapitalSiegeHoldRequired then
            requiredForCap = Overlord.Zones:GetCapitalSiegeHoldRequired(zone, owner, remoteHoldParsed or requiredForCap)
        elseif remoteHoldParsed then
            requiredForCap = remoteHoldParsed
        end
    end
    local function CapHoldTimeIfNeeded(remoteHoldTime)
        if owner ~= Overlord.PlayerFaction then return remoteHoldTime end
        if self:ShouldDeferToRemoteAllyCapturer(
            zone, zsCapturerName, progressDecision) then
            return remoteHoldTime
        end
        if zone.holdAuthorityLocal
            and not self:HasIndependentCaptureProgressEvidence(progressDecision) then
            return zone.holdTimeElapsed or 0
        end
        -- Zone deja in_progress : le holdTime vient d'un capteur actif (pas interpole
        -- localement depuis 6.3.0). Faire confiance au reseau pour eviter le reset du
        -- timer quand un allie rejoint un siege de capitale deja avance.
        if oldStatus == "in_progress" then return remoteHoldTime end
        local inThisZonePhysically = false
        if Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone then
            local pz = Overlord.Zones:GetCurrentPlayerZone()
            if pz and pz.id == zone.id then
                inThisZonePhysically = true
            end
        end
        if not zone.isHolding and not inThisZonePhysically then return remoteHoldTime end
        local timeInZone = zone.holdStartTime and (GetTime() - zone.holdStartTime) or 0
        if timeInZone < 1 then timeInZone = 5 end
        local maxAllowed = math.min(timeInZone + 15, requiredForCap - 1)
        if remoteHoldTime > maxAllowed then
            return maxAllowed
        end
        return remoteHoldTime
    end
    holdTime = CapHoldTimeIfNeeded(holdTime)

    if ts <= localTs and TryAlignAllyCoCaptureTimer(
        zone, status, owner, holdTime, ts, zsCapturerName, sender,
        zsCapturerShard, progressDecision, AdoptAcceptedProgress) then
        if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
        Overlord.Zones:UpdateAvailableZones()
        Overlord:MarkDirty()
        if Overlord.UI then Overlord.UI:RequestRefresh() end
        ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
        return
    end

    -- ts < localTs : normalement ignore ; exception si on est bloque en "rouge" (owner ennemi)
    -- alors qu'un allie fiable envoie captured local (voir TryHealStaleEnemyOwnerFromFriendlyCapture).
    if ts < localTs and TryHealStaleEnemyOwnerFromFriendlyCapture(zone, status, owner, ts, sender) then
        CommitAcceptedZsFinal(zone)
        if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
        Overlord.Zones:UpdateAvailableZones()
        Overlord:MarkDirty()
        if Overlord.UI then Overlord.UI:RequestRefresh() end
        priv.enemyAlertLast[zone.id] = nil
        priv.enemyAlertSkipUntil[zone.id] = nil
        priv.enemyAlertEmitted[zone.id] = nil
        self:CheckTotalVictoryFromSync()
        ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
        return
    end

    -- Fin de capture arrivee legerement apres un bump local updatedAt (contestation, relais ZS, barricade).
    -- On accepte uniquement si c'est la meme vague/proprietaire et que nous ne sommes pas capteur local.
    if ts < localTs and status == "captured" and owner
        and zone.status == "in_progress" and zone.owner == owner
        and not IsLocalAuthoritativeCapture(zone) then
        local lateWindow = zone.isCapital and 120 or 45
        local closeEnough = (localTs - ts) <= lateWindow
        local req = zone.holdTimeRequired or 120
        local observedComplete = (zone.holdTimeElapsed or 0) >= (req - 1)
        if closeEnough and observedComplete then
            if owner == enemyFaction and zone.previousOwner == Overlord.PlayerFaction
                and ShouldRejectStaleEnemyAttackOnOurCapture(zone, "captured", owner, ts, 0, {
                    defenderOwner = zone.previousOwner,
                    defenderStatus = "captured",
                    capturedTime = zone.capturedTime,
                }) then
                ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
                return
            end
            local oldStatusForLate = zone.status
            local oldOwnerForLate = zone.owner
            local oldPreviousOwnerForLate = zone.previousOwner
            zone.status = "captured"
            zone.owner = owner
            zone.capturedTime = ts
            zone.updatedAt = ts
            zone.killsCurrent = math.max(kills, zone.killsCurrent or 0)
            zone.holdTimeElapsed = 0
            zone.isHolding = false
            zone.isContested = false
            zone.isPaused = false
            zone.holdAuthorityLocal = nil
            zone.holdStartTime = nil
            zone.previousOwner = nil
            zone.lastZSSender = nil
            CompleteAcceptedZsTerminal(zone, zone.status)
            -- CommitAcceptedZsFinal pose le TombstoneFinalWave seulement apres
            -- cette promotion canonique owner/status/capturedTime.
            CommitAcceptedZsFinal(zone)
            zone._syncGateRemoteProgress = nil
            zone._syncGateRemoteProgressUntil = nil
            if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
            Overlord.Zones:UpdateAvailableZones()
            Overlord:MarkDirty()
            if Overlord.UI then Overlord.UI:RequestRefresh() end
            if owner == Overlord.PlayerFaction then
                priv.enemyAlertLast[zone.id] = nil
                priv.enemyAlertSkipUntil[zone.id] = nil
                priv.enemyAlertEmitted[zone.id] = nil
                self:CheckTotalVictoryFromSync()
            elseif owner == enemyFaction
                and ShouldAlertEnemyZoneCapture(oldStatusForLate, oldOwnerForLate, oldPreviousOwnerForLate, owner, zone) then
                PrintCaptureChatOnce(zone, owner, EffectiveCapturerNameForAlert(zone, zsCapturerName), ts)
            end
            ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
            return
        end
    end

    -- Donnee distante plus recente : on prend tout (owner deja defini plus haut).
    -- La fin directe d'un bail peut partager la seconde de son dernier heartbeat.
    if ts > localTs or (directRevertVerified and ts == localTs) then
        -- Protection : allie encore sur le disque - ignorer abandon/revert d'un partant.
        if AllyStillCapturingOnDisk(zone) then
            if status == "available" or status == "locked" then
                return
            end
            if status == "captured" and owner ~= Overlord.PlayerFaction then
                return
            end
        end

        -- Protection : si nous capturons physiquement pour notre faction,
        -- un ZS "in_progress" ennemi ne doit pas ecraser notre owner.
        -- La contestation se fait naturellement via ScanNearbyPlayers (nameplates).
        -- Sans ca, le owner est ecrase a la faction ennemie et le timer recule en permanence
        -- meme avec 0 ennemis visibles (bug "CONTESTE sans ennemis").
        if zone.isHolding and zone.owner == Overlord.PlayerFaction
            and status == "in_progress" and owner == enemyFaction then
            -- On ignore ce ZS : ne pas garder un zsRelayCapturerName ennemi d'une vague anterieure
            -- (sinon relais/alertes peuvent ressortir un nom apres coup).
            zone.zsRelayCapturerName = nil
            zone.zsRelayCapturerShard = nil
            return
        end

        -- Protection contestation/reprise locale autoritaire.
        -- Un observateur present sur le disque ne bloque plus le ZS du capteur officiel :
        -- sinon deux clients peuvent garder des timers differents selon leurs nameplates.
        if status == "in_progress" and owner == enemyFaction
            and holdTime > (zone.holdTimeElapsed or 0) then
            local playerInThisZone = false
            if zone.isHolding and zone.owner == enemyFaction then
                playerInThisZone = true
            elseif Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone then
                local pz = Overlord.Zones:GetCurrentPlayerZone()
                if pz and pz.id == zone.id then
                    playerInThisZone = true
                end
            end
            if playerInThisZone and zone.holdAuthorityLocal then
                return
            end
        end

        -- Protection : capture confirmee ne regresse pas vers in_progress du meme proprio
        -- (ZS en retard) ; inclut status local locked/available (vue assaut front actif).
        if status == "in_progress" and zone.owner == owner
            and Overlord.Zones and Overlord.Zones.IsNetworkConfirmedCapture
            and Overlord.Zones:IsNetworkConfirmedCapture(zone) then
            return
        end

        -- Fantome : vieux tag Horde (ou timer deja a 100 %) qui ecrase notre capture confirmee.
        -- ts > capturedTime = nouvelle vague ennemie - on n'applique pas ce garde-fou.
        local loginUnconfirmed = Overlord.IsLoginZoneStateUnconfirmed
            and Overlord:IsLoginZoneStateUnconfirmed(zone)
        local staleAttackOpts = loginUnconfirmed and { capturedTime = 0 } or nil
        if ShouldRejectStaleEnemyAttackOnOurCapture(zone, status, owner, ts, holdTime, staleAttackOpts) then
            zone.zsRelayCapturerName = nil
            zone.zsRelayCapturerShard = nil
            return
        end

        -- NOTE : la protection prerequis (allControlled) a ete retiree ici intentionnellement.
        -- Elle bloquait les ZS in_progress REELS quand le client Horde avait encore la 9e zone
        -- marquee "in_progress" (pas encore "captured") au moment ou l'Alliance attaquait la
        -- capitale. Resultat : 0 alerte + zone bleue instantanee apres le message C final.
        -- Ancien buffer capturedTime+60s sur in_progress retire : causait des desyncs observateur.
        -- ShouldRejectStaleEnemyAttackOnOurCapture : ts > capturedTime seulement pour les vagues ennemies.

        -- Protection : une zone qui a ete capturee (capturedTime > 0) ne peut pas regresser
        -- vers available/locked via ZS. Seule une capture (message C) ou un in_progress ennemi
        -- peut changer l'etat. Corrige le bug ou un ZS d'un Horde ecrase nos captures.
        if (status == "available" or status == "locked")
            and zone.capturedTime and zone.capturedTime > 0 then
            -- Capture abandonnee sur zone deja prise : restaurer le defenseur (ex. Faldir Horde
            -- apres kill + depart Alliance), pas « Disponible » neutre si previousOwner manque.
            if zone.status == "in_progress" then
                local revertTo = Overlord.Zones:ResolveRevertOwnerAfterFailedCapture(zone)
                if revertTo then
                    zone.status = "captured"
                    zone.owner = revertTo
                    zone.previousOwner = nil
                    zone.isHolding = false
                    zone.isContested = false
                    zone.isPaused = false
                    zone.holdStartTime = nil
                    zone.holdTimeElapsed = 0
                    zone.killsCurrent = 0
                    CompleteAcceptedZsTerminal(zone, zone.status)
                    if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
                        Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
                    end
                    zone.updatedAt = ts
                    Overlord.Zones:UpdateAvailableZones()
                    Overlord:MarkDirty()
                    if Overlord.UI then Overlord.UI:RequestRefresh() end
                    priv.enemyAlertEmitted[zone.id] = nil
                    priv.enemyAlertSkipUntil[zone.id] = nil
                end
            end
            return
        end

        -- Dernier point avant mutation pour une progression acceptee : le bail
        -- possede ainsi la base stable exacte et couvre tous les chemins actifs.
        if status == "in_progress" and not AdoptAcceptedProgress() then return end

        if zone.status == "in_progress" and owner ~= zone.owner then
            zone.isHolding = false
            zone.isContested = false
            -- Evite holdAuthorityLocal vrai alors que zone.owner alle / ennemi diverge du contexte autorite locale.
            zone.holdAuthorityLocal = nil
        end

        -- Sauvegarde le vrai proprietaire AVANT que le ZS ecrase zone.owner.
        -- Sinon, quand on entre contester une capture ennemie, Update()
        -- poserait previousOwner = ennemi (au lieu du vrai proprio d'origine), et le revert
        -- donne la zone a l'ennemi au lieu de restaurer l'etat correct.
        if status == "in_progress" and not zone.previousOwner then
            zone.previousOwner = zone.owner
        end

        -- Ne pas appliquer status sans owner valide pour captured (evite incohérence)
        if status == "captured" and not owner then
            return
        end
        if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
        if oldStatus ~= status or oldOwner ~= owner then
            zone._observerDisplayHold = nil
        end
        zone.status = status
        -- Seul le capteur direct est responsable de cette vague pour l'anti-spoof.
        if status == "in_progress" and sender and progressDecision and progressDecision.direct then
            zone.lastZSSender = sender
        elseif status ~= "in_progress" then
            zone.lastZSSender = nil
        end
        zone.killsCurrent = math.max(kills, zone.killsCurrent or 0)
        -- in_progress + notre faction : regle de mise a jour du holdTimeElapsed.
        --
        -- CAPTURING (holdAuthorityLocal + !isPaused) : monotone (math.max) pour eviter
        -- que les ZS legerement en retard (math.floor, relais) fassent reculer le timer.
        --
        -- LOSING (holdAuthorityLocal + isPaused) : le joueur a quitte la zone, le timer
        -- decroit localement. La valeur locale est autorite ABSOLUE : ignorer tout holdTime
        -- distant. Sans ca, un allie sur le meme disque (timer croissant) ou un observateur
        -- qui interpole vers le haut repoussent le timer a chaque ZS (oscillation).
        --
        -- Observateur (pas holdAuthorityLocal) : accepter la valeur du capteur telle quelle.
        -- Le tri par timestamp (ts > localTs) garantit l'ordre.
        -- Les captures ennemies utilisent le hold distant tel quel (recul conteste, etc.).
        if status == "in_progress" and owner == Overlord.PlayerFaction then
            local deferOfficial = self:ShouldDeferToRemoteAllyCapturer(
                zone, zsCapturerName, progressDecision)
            if deferOfficial then
                zone.holdAuthorityLocal = nil
            end
            if zone.isPaused and zone.holdAuthorityLocal then
                -- LOSING : ignorer le holdTime distant, la decroissance locale fait autorite.
            elseif deferOfficial then
                -- Co-capture : un seul capteur officiel (9e champ ZS).
                zone.holdTimeElapsed = holdTime or 0
                if zone.isHolding then
                    zone.holdStartTime = GetTime() - (holdTime or 0)
                end
            elseif zone.holdAuthorityLocal then
                zone.holdTimeElapsed = math.max(holdTime or 0, zone.holdTimeElapsed or 0)
            else
                zone.holdTimeElapsed = holdTime or 0
                local ht = holdTime or 0
                if zone._observerDisplayHold and zone._observerDisplayHold > ht + 1 then
                    zone._observerDisplayHold = ht
                end
            end
        else
            zone.holdTimeElapsed = holdTime
        end
        self:StoreAllyOfficialCapturerFromZs(
            zone, status, owner, zsCapturerName, sender, zsCapturerShard, progressDecision)
        zone.updatedAt = ts
        self:ClearPointSyncLoginQuarantine(zone)
        if owner then
            zone.owner = owner
            -- capturedTime uniquement pour les captures confirmees : evite qu'un in_progress
            -- bloque la zone si la capture echoue (la protection capturedTime>0 rejetterait
            -- le ZS "available" qui suivrait, laissant la zone bloquee en in_progress)
            if status == "captured" then
                zone.capturedTime = ts
            end
        end
        StoreZsRelayCapturerFromZs(zone, status, owner, zsCapturerName, zsCapturerShard)
        if status == "in_progress" then
            if Overlord.Zones and Overlord.Zones.GetCapitalSiegeHoldRequired then
                zone.holdTimeRequired = Overlord.Zones:GetCapitalSiegeHoldRequired(zone, owner, remoteHoldParsed)
            elseif remoteHoldParsed then
                zone.holdTimeRequired = remoteHoldParsed
            end
            self:RebaseRemoteObserverDisplay(
                zone, holdTime, ts, zone.holdTimeRequired,
                oldStatus ~= status or oldOwner ~= owner,
                zsRelayedDisplayHold, zsRelayedDisplayAt)
        else
            zone._observerDisplayNetworkFloor = nil
            CompleteAcceptedZsTerminal(zone, status)
            if status == "captured" then
                CommitAcceptedZsFinal(zone)
            end
        end
        if status == "captured" then
            zone.isHolding = false
            zone.isContested = false
            zone.isPaused = false
            zone.holdTimeElapsed = 0
            zone.holdStartTime = nil
            zone._syncGateRemoteProgress = nil
            zone._syncGateRemoteProgressUntil = nil
            -- Check victoire totale (la derniere zone capturee par notre faction via ZS)
            if owner == Overlord.PlayerFaction then
                self:CheckTotalVictoryFromSync()
            end
        elseif status == "in_progress" then
            local syncGateRemoteProgress = owner == Overlord.PlayerFaction
                and (syncGateWasPending
                    or (Overlord.ShouldResetSyncedLocalCaptureProgress
                        and Overlord:ShouldResetSyncedLocalCaptureProgress()))
            if syncGateRemoteProgress then
                -- Apres login / instance, observer le timer allie mais ne pas le reprendre
                -- comme progression locale. Sinon un vieux ZS a 2:59 se termine en 1 tick.
                -- Un timer avance ne doit pas devenir autorite locale juste parce que
                -- le joueur revient sur le disque apres une sync.
                zone._syncGateRemoteProgress = true
                zone._syncGateRemoteProgressUntil = GetTime() + TUNING.SYNC_GATE_REMOTE_PROGRESS_SECONDS
            end
            -- Timer distant au seuil : ne pas trancher localement. Un observateur
            -- demande une confirmation reseau et attend un vrai C / ZS captured / ZA.
            local autoReq = zone.holdTimeRequired or 120
            MaybeRequestEnemyCaptureConfirmationFromZs(zone, owner, holdTime, autoReq, oldStatus, oldOwner)
            local playerZone = Overlord.Zones:GetCurrentPlayerZone()
            local inThisZone = playerZone and playerZone.id == zone.id
            -- Meme regle que ZoneControl: monture/vol/furtif = pas "sur le point" pour isHolding
            local blockPhys = Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync
                and Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync()
            if zone._syncGateRemoteProgressUntil and GetTime() >= zone._syncGateRemoteProgressUntil then
                zone._syncGateRemoteProgress = nil
                zone._syncGateRemoteProgressUntil = nil
            end
            local weAreCapturing = inThisZone
                and (not owner or owner == Overlord.PlayerFaction)
                and not blockPhys
                and not zone._syncGateRemoteProgress
                and (not Overlord.CanStartLocalCapture or Overlord:CanStartLocalCapture(zone, false))
            -- Ne pas ecraser isHolding si on est en phase LOSING (isPaused = timer decroit hors zone).
            -- Exception : sur le disque mais monte = pas une vraie participation ; debloquer isPaused.
            local forceReleaseHold = not weAreCapturing and blockPhys and inThisZone
            local wasHolding = zone.isHolding
            if zone.holdAuthorityLocal and zone.isHolding and not weAreCapturing and not forceReleaseHold then
                -- Autorite locale hors disque : forcer LOSING (evite isHolding=false avant le 1er tick Update).
                zone.isPaused = true
            elseif not (zone.isHolding and zone.isPaused) or forceReleaseHold then
                zone.isHolding = weAreCapturing
            end
            -- holdStartTime : ne set que si pas encore defini (premiere activation).
            -- Re-set a chaque ZS = CapHoldTimeIfNeeded croit qu'on vient d'arriver et cap
            -- systématiquement, meme apres 2 minutes de presence dans la zone.
            if zone.isHolding and not zone.holdAuthorityLocal
                and zone._observerDisplayNetworkFloor then
                zone.holdStartTime = GetTime() - zone._observerDisplayNetworkFloor
            elseif zone.isHolding and not zone.holdStartTime then
                zone.holdStartTime = GetTime()
            end
            -- Anti-exploit : cap holdTimeElapsed quand on devient capteur actif sur
            -- une NOUVELLE capture (oldStatus != in_progress). Evite qu'un ZS stale
            -- permette un instant-cap en entrant dans la zone.
            -- Si la capture etait deja in_progress (oldStatus == "in_progress"),
            -- le holdTimeElapsed provient du reseau (pas interpole depuis 6.3.0) :
            -- le capper inherite le vrai progres du capteur actif.
            local joinAllyCoCapture = self:ShouldDeferToRemoteAllyCapturer(
                zone, zsCapturerName, progressDecision)
                or (zone.zsOfficialCapturerName and zone.zsOfficialCapturerName ~= ""
                    and GetSelfCapturerFullName() and zone.zsOfficialCapturerName ~= GetSelfCapturerFullName())
            if zone.isHolding and not wasHolding and oldStatus ~= "in_progress"
                and not joinAllyCoCapture then
                local timeInZone = zone.holdStartTime and (GetTime() - zone.holdStartTime) or 0
                local maxHold = zone.holdTimeRequired or 120
                local capValue = math.min(timeInZone + 15, maxHold - 1)
                if (zone.holdTimeElapsed or 0) > capValue then
                    zone.holdTimeElapsed = capValue
                end
            end
            if not zone.isHolding then
                zone.isPaused = false
            end
            -- Confirmation alliee APRES weAreCapturing : le co-captureur sur le disque
            -- garde la phase orange jusqu'au vrai message final partage.
            MaybeRequestAllyCaptureConfirmationFromZs(
                zone, owner, holdTime, autoReq, syncGateRemoteProgress, zsCapturerName)
        elseif status == "available" or status == "locked" then
            zone.isHolding = false
            zone.isContested = false
            zone._syncGateRemoteProgress = nil
            zone._syncGateRemoteProgressUntil = nil
            local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
            if fixedOwner then
                zone.owner = fixedOwner
                zone.status = "captured"
            elseif zone.capturedTime and zone.capturedTime > 0 then
                local revertTo = Overlord.Zones:ResolveRevertOwnerAfterFailedCapture(zone)
                if revertTo then
                    zone.status = "captured"
                    zone.owner = revertTo
                else
                    zone.owner = nil
                end
            else
                zone.owner = nil
            end
            if zone.status == "captured" then
                zone.previousOwner = nil
                if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
                    Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
                end
            end
        end

        if zone.status == "in_progress" then
            self:BumpPrereqChainGrace(zone.id)
        end
        Overlord.Zones:UpdateAvailableZones()
        Overlord:MarkDirty()
        if loginUnconfirmed and Overlord.RefreshCaptureSyncVisuals then
            -- La quarantaine brute reste active, mais le bail valide doit
            -- remplacer immediatement SYNC par le vrai timer orange sur la carte.
            Overlord:RefreshCaptureSyncVisuals()
        elseif Overlord.UI then
            Overlord.UI:RequestRefresh()
        end

        -- Alerte : ennemi en train de capturer (anti-spam conteste : ZS A/H alternes)
        if status == "in_progress" and owner and owner == enemyFaction
            and self:CanEmitEnemyCaptureAlert(progressDecision) then
            -- L'orange direct reste reactif, mais une ressource irreversible exige
            -- trois temoins frais ou une position Blizzard exacte du capteur dans le cercle.
            if Overlord.CaptureLease and Overlord.CaptureLease.MaybeConsumeBarricade then
                Overlord.CaptureLease:MaybeConsumeBarricade(
                    zone, owner, zsCapturerName, progressDecision,
                    progressEffectEligible)
            end
            -- TryPrintEnemyCapturingAlert dedup lui-meme la vague ; l'appeler aussi quand l'etat local
            -- etait deja in_progress couvre les retours de voyage / reload sans alerte initiale.
            TryPrintEnemyCapturingAlert(zone, EffectiveCapturerNameForAlert(zone, zsCapturerName), ts)
        end
        -- Alerte : zone perdue sans phase in_progress visible (attaquant sans addon, cross-realm, etc.)
        -- La zone est passee directement de notre faction a l'ennemi via un ZS "captured".
        -- Le message C (OnReceiveCapture) couvre le cas normal ; ici on couvre le ZS seul.
        -- Condition : oldOwner etait notre faction (pas deja l'ennemi) pour eviter le doublon avec C.
        if status == "captured" and owner == enemyFaction
            and ShouldAlertEnemyZoneCapture(oldStatus, oldOwner, zone.previousOwner, owner, zone) then
            PrintCaptureChatOnce(zone, owner, EffectiveCapturerNameForAlert(zone, zsCapturerName), ts)
        end
        -- Reset le cooldown d'alerte si notre faction vient de recapturer la zone
        if status == "captured" and owner == Overlord.PlayerFaction then
            priv.enemyAlertLast[zone.id] = nil
            priv.enemyAlertSkipUntil[zone.id] = nil
            priv.enemyAlertEmitted[zone.id] = nil
        end

        -- Fin de vague "ennemi en train de capturer" : permet une nouvelle alerte au prochain tag.
        local wasEnemyPush = (oldStatus == "in_progress" and oldOwner == enemyFaction)
        local nowEnemyPush = (zone.status == "in_progress" and zone.owner == enemyFaction)
        if wasEnemyPush and not nowEnemyPush then
            priv.enemyAlertEmitted[zone.id] = nil
            priv.enemyAlertSkipUntil[zone.id] = nil
            -- Pas de chat ici : souvent un revert sync/observateur ; le vrai message part de ZoneControl sur le disque.
        end

        ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)

    -- Meme timestamp : merge additif (max kills/holdTime)
    -- holdTime deja passe par CapHoldTimeIfNeeded en debut de fonction
    elseif ts == localTs then
        if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
        local changed = false
        if status ~= "in_progress" then
            StoreZsRelayCapturerFromZs(zone, status, owner, zsCapturerName, zsCapturerShard)
        end

        -- Fin de capture recue dans la meme seconde que le dernier ZS in_progress.
        -- Sans cette promotion, un observateur qui a manque C reste orange jusqu'au prochain SR/ZA.
        if status == "captured" and owner and zone.status == "in_progress" then
            if AllyStillCapturingOnDisk(zone) and owner ~= Overlord.PlayerFaction then
                ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
                return
            end
            zone.status = "captured"
            zone.owner = owner
            zone.capturedTime = ts
            zone.updatedAt = ts
            zone.killsCurrent = math.max(kills, zone.killsCurrent or 0)
            zone.holdTimeElapsed = 0
            zone.isHolding = false
            zone.isContested = false
            zone.isPaused = false
            zone.holdAuthorityLocal = nil
            zone.holdStartTime = nil
            zone.previousOwner = nil
            zone.lastZSSender = nil
            CompleteAcceptedZsTerminal(zone, zone.status)
            CommitAcceptedZsFinal(zone)
            zone._syncGateRemoteProgress = nil
            zone._syncGateRemoteProgressUntil = nil
            if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived() end
            Overlord.Zones:UpdateAvailableZones()
            Overlord:MarkDirty()
            if Overlord.UI then Overlord.UI:RequestRefresh() end
            if owner == Overlord.PlayerFaction then
                priv.enemyAlertLast[zone.id] = nil
                priv.enemyAlertSkipUntil[zone.id] = nil
                priv.enemyAlertEmitted[zone.id] = nil
                self:CheckTotalVictoryFromSync()
            elseif owner == enemyFaction
                and ShouldAlertEnemyZoneCapture(oldStatus, oldOwner, oldPreviousOwner, owner, zone) then
                PrintCaptureChatOnce(zone, owner, EffectiveCapturerNameForAlert(zone, zsCapturerName), ts)
            end
            ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
            return
        end

        -- DESYNC FIX : meme timestamp mais owner different pour une zone captured.
        -- Cela arrive quand deux joueurs ont des SavedVariables divergentes avec le meme updatedAt.
        -- Resolution : capturedTime le plus recent gagne ; si egal, tie-break deterministe.
        if status == "captured" and owner and zone.owner and owner ~= zone.owner then
            local remoteCapturedTime = ts  -- Le ZS "captured" implique que ct = ts a l'emission
            local localCapturedTime = zone.capturedTime or 0
            local remoteWinsTie = remoteCapturedTime == localCapturedTime
                and remoteCapturedTime > 0
                and self:DeterministicCaptureTieOwner(zoneId, remoteCapturedTime) == owner
            if remoteCapturedTime > localCapturedTime or remoteWinsTie then
                -- Le ZS distant gagne : plus recent, ou tie-break stable a la meme seconde.
                zone.owner = owner
                zone.status = "captured"
                zone.capturedTime = remoteCapturedTime
                zone.isHolding = false
                zone.isContested = false
                zone.isPaused = false
                zone.holdStartTime = nil
                zone.previousOwner = nil
                CompleteAcceptedZsTerminal(zone, zone.status)
                CommitAcceptedZsFinal(zone)
                Overlord.Zones:UpdateAvailableZones()
                Overlord:MarkDirty()
                if Overlord.UI then Overlord.UI:RequestRefresh() end
                -- La capture elle-meme reste l'horloge canonique : utiliser time()
                -- ici rendrait le resultat dependant du moment ou chaque pair repare le tie.
                zone.updatedAt = remoteCapturedTime
                self:BroadcastZoneState(zone, true)
            end
            -- Si localCapturedTime > remoteCapturedTime, on garde notre version (deja plus recente)
            return
        end

        -- Changement de faction avec meme timestamp : la faction adverse a pris la releve.
        -- On doit ecraser le timer (pas max) et mettre a jour owner, sinon le timer reste
        -- bloque a l'ancienne valeur et l'affichage est incoherent (bug "timer bloque 1:05").
        local factionSwitched = (status == "in_progress" and owner and owner ~= zone.owner)
        if factionSwitched and owner == enemyFaction and oldOwner == Overlord.PlayerFaction
            and oldStatus == "captured"
            and ShouldRejectStaleEnemyAttackOnOurCapture(zone, status, owner, ts, holdTime, {
                defenderOwner = oldOwner,
                defenderStatus = oldStatus,
                capturedTime = zone.capturedTime,
            }) then
            ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
            return
        end
        if status == "in_progress" and owner == enemyFaction
            and zone.previousOwner == Overlord.PlayerFaction
            and ShouldRejectStaleEnemyAttackOnOurCapture(zone, status, owner, ts, holdTime, {
                defenderOwner = zone.previousOwner,
                defenderStatus = "captured",
                capturedTime = zone.capturedTime,
            }) then
            ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
            return
        end
        local progressWillApply = status == "in_progress"
            and (zone.status == "in_progress" or factionSwitched)
        if status == "in_progress" and not progressWillApply then
            return
        end
        if progressWillApply then
            if not AdoptAcceptedProgress() then return end
            StoreZsRelayCapturerFromZs(zone, status, owner, zsCapturerName, zsCapturerShard)
            if progressLeaseOpened then factionSwitched = true end
        end
        if factionSwitched then
            -- Sauvegarde previousOwner avant ecrasement (pour revert si abandon)
            if not zone.previousOwner then
                zone.previousOwner = zone.owner
            end
            zone.status = status
            zone.owner = owner
            zone.holdTimeElapsed = holdTime
            zone.isHolding = false
            zone.isContested = false
            zone.holdAuthorityLocal = nil
            zone.isPaused = false
            zone.holdStartTime = nil
            if status == "in_progress" and Overlord.Zones and Overlord.Zones.GetCapitalSiegeHoldRequired then
                zone.holdTimeRequired = Overlord.Zones:GetCapitalSiegeHoldRequired(zone, owner, remoteHoldParsed)
            elseif remoteHoldParsed then
                zone.holdTimeRequired = remoteHoldParsed
            end
            changed = true
            Overlord.Zones:UpdateAvailableZones()
            if Overlord.UI then Overlord.UI:RequestRefresh() end
            -- Alerte capture ennemie si la nouvelle faction est l'ennemi
            if owner == enemyFaction and oldOwner == Overlord.PlayerFaction
                and self:CanEmitEnemyCaptureAlert(progressDecision) then
                TryPrintEnemyCapturingAlert(zone, EffectiveCapturerNameForAlert(zone, zsCapturerName), ts)
            end
        else
            if kills > zone.killsCurrent then
                zone.killsCurrent = kills
                changed = true
            end
            -- Meme timestamp : aligner la capture ennemie sur le capteur officiel.
            -- Seule une autorite locale explicite peut bloquer une remontee du timer.
            if status == "in_progress" and owner == enemyFaction then
                local allowUpdate = true
                if holdTime > (zone.holdTimeElapsed or 0) then
                    -- Verifier si on est physiquement dans cette zone
                    local playerInThisZone = false
                    if zone.isHolding and zone.owner == enemyFaction then
                        playerInThisZone = true
                    elseif Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone then
                        local pz = Overlord.Zones:GetCurrentPlayerZone()
                        if pz and pz.id == zone.id then
                            playerInThisZone = true
                        end
                    end
                    if playerInThisZone and zone.holdAuthorityLocal then
                        allowUpdate = false
                    end
                end
                if allowUpdate and (zone.holdTimeElapsed or 0) ~= holdTime then
                    zone.holdTimeElapsed = holdTime
                    changed = true
                end
            elseif status == "in_progress" and owner == Overlord.PlayerFaction
                and zone.isPaused and zone.holdAuthorityLocal then
                -- LOSING : le timer local decroit, ne pas le remonter avec un ZS allie meme ts.
            elseif holdTime > (zone.holdTimeElapsed or 0) then
                zone.holdTimeElapsed = holdTime
                changed = true
            end
            -- Meme ts : converger holdTimeRequired (ex. barricade / capitale recue avec le meme updatedAt)
            if status == "in_progress" then
                local mergedReq = (Overlord.Zones and Overlord.Zones.GetCapitalSiegeHoldRequired)
                    and Overlord.Zones:GetCapitalSiegeHoldRequired(zone, owner, remoteHoldParsed)
                    or remoteHoldParsed
                if mergedReq and mergedReq > (zone.holdTimeRequired or 120) then
                    zone.holdTimeRequired = mergedReq
                    changed = true
                end
            end
        end
        if changed then Overlord:MarkDirty() end

        -- Meme ts que le ZS precedent : si le paquet recu porte holdTime >= requis,
        -- demander une confirmation reseau. Ne pas utiliser l'interpolation observateur
        -- pour promouvoir localement en captured.
        if status == "in_progress" and zone.status == "in_progress" then
            if owner == enemyFaction and Overlord.CaptureLease
                and Overlord.CaptureLease.MaybeConsumeBarricade then
                Overlord.CaptureLease:MaybeConsumeBarricade(
                    zone, owner, zsCapturerName, progressDecision,
                    progressEffectEligible)
            end
            local autoReq = zone.holdTimeRequired or 120
            local ht = holdTime or 0
            if owner and owner ~= Overlord.PlayerFaction then
                MaybeRequestEnemyCaptureConfirmationFromZs(zone, owner, ht, autoReq, oldStatus, oldOwner)
            else
                MaybeRequestAllyCaptureConfirmationFromZs(zone, owner, ht, autoReq, false, zsCapturerName)
            end
        end

        -- Etat deja canonique a timestamp egal : final idempotent accepte.
        if status == "captured" and owner == zone.owner
            and zone.status ~= "in_progress"
            and (tonumber(zone.capturedTime) or 0) >= ts then
            CompleteAcceptedZsTerminal(zone, "captured")
            CommitAcceptedZsFinal(zone)
        end

        ClearZsRelayAfterZsApply(zone, zone.status, zone.owner)
    end
    -- Un certificat plus ancien du meme proprietaire est idempotent si l'etat
    -- local canonique le supersede deja ; sinon ts < localTs reste ignore.
    if ts < localTs and status == "captured" and owner == zone.owner
        and zone.status ~= "in_progress"
        and (tonumber(zone.capturedTime) or 0) >= ts then
        CompleteAcceptedZsTerminal(zone, "captured")
        CommitAcceptedZsFinal(zone)
    end
end

-- Evalue une vague distante uniquement dans la vue stable d'un snapshot global
-- exact. Les overlays locaux ne doivent ni blanchir des prerequis, ni provoquer
-- un veto de convergence. Une liste vide est un prerequis valide ; nil ne l'est pas.
local function RemoteCaptureMeetsStagedPrereqs(
    zoneId, attackingFaction, stagedOwners, stagedOwnerPresent)
    if not zoneId or (attackingFaction ~= "Alliance" and attackingFaction ~= "Horde")
        or not Overlord.Fronts or not Overlord.Fronts.GetZone then return false end
    local _, front = Overlord.Fronts:GetZone(zoneId)
    local factionPrereqs = front and front.prereqs and front.prereqs[attackingFaction]
    local prereqIds = factionPrereqs and factionPrereqs[zoneId]
    if not front or prereqIds == nil then return false end
    for _, prereqId in ipairs(prereqIds) do
        if not stagedOwnerPresent[prereqId]
            or stagedOwners[prereqId] ~= attackingFaction then return false end
    end
    local enemyCapitalId = Overlord.Fronts.GetEnemyCapitalId
        and Overlord.Fronts:GetEnemyCapitalId(attackingFaction, front.id) or nil
    if zoneId == enemyCapitalId then
        for _, otherZone in ipairs(front.zones or {}) do
            if otherZone.id ~= zoneId and (not stagedOwnerPresent[otherZone.id]
                or stagedOwners[otherZone.id] ~= attackingFaction) then return false end
        end
    end
    return true
end

-- Recoit une liste compacte de zones avec proprietaire et timestamp (peer-to-peer cross-faction)
function Overlord.Sync:OnReceiveZoneAll(
    payload, sender, loginElectionClaimKey, runtimeElectionClaimKey)
    if not payload or payload == "" then return end
    if loginElectionClaimKey or runtimeElectionClaimKey then return end
    local snapshotComplete = false
    local snapshotAtomic = false
    local snapshotGlobal = false
    local zaSnapshotScope
    local zaSnapshotId, zaPageIndexRaw, zaPageCountRaw, zaPageBody =
        payload:match("^@([%w_-]+):(%d+):(%d+)|(.*)$")
    if payload:sub(1, 1) == "@" then
        if not zaSnapshotId or #zaSnapshotId > 40 then return end
        zaSnapshotScope = zaSnapshotId:match("^([GFPQ])%-%d+%-%d+$")
        if not zaSnapshotScope then return end
        local zaPageIndex = tonumber(zaPageIndexRaw)
        local zaPageCount = tonumber(zaPageCountRaw)
        if not zaPageIndex or not zaPageCount or zaPageIndex < 1
            or zaPageCount < 1 or zaPageIndex > zaPageCount
            or zaPageCount > self.ZA_SNAPSHOT_MAX_PAGES
            or #zaPageBody > self.ZA_SNAPSHOT_BODY_BYTES then return end

        local now = GetTime()
        local senderKey = tostring(sender or ""):lower()
        if senderKey == "" then return end
        priv.zaPendingSenderWindows:Prune(now, 8)
        for key, batch in pairs(priv.pendingZaSnapshotPages) do
            if now - (batch.lastAt or batch.createdAt or 0) > 45 then
                priv.pendingZaSnapshotPages[key] = nil
            end
        end
        local completedCount, oldestCompletedKey, oldestCompletedAt = 0, nil, nil
        for key, completedAt in pairs(priv.completedZaSnapshots) do
            if now - completedAt > 90 then
                priv.completedZaSnapshots[key] = nil
            else
                completedCount = completedCount + 1
                if not oldestCompletedAt or completedAt < oldestCompletedAt then
                    oldestCompletedKey, oldestCompletedAt = key, completedAt
                end
            end
        end
        if completedCount >= 64 and oldestCompletedKey then
            priv.completedZaSnapshots[oldestCompletedKey] = nil
        end

        local batchKey = senderKey .. "\31" .. zaSnapshotId
        if priv.completedZaSnapshots[batchKey] then return end
        local pendingZaSnapshot = priv.pendingZaSnapshotPages[batchKey]
        if not pendingZaSnapshot then
            local senderWindow = priv.zaPendingSenderWindows:Get(senderKey, now)
            if not senderWindow or now - (senderWindow.startedAt or 0) > 10 then
                senderWindow = { startedAt = now, count = 0 }
                if not priv.zaPendingSenderWindows:Remember(
                    senderKey, senderWindow, now, false) then return end
            end
            if senderWindow.count >= 4 then return end
            senderWindow.count = senderWindow.count + 1

            local pendingCount = 0
            local senderPendingCount, senderOldestKey, senderOldestAt = 0, nil, nil
            for key, batch in pairs(priv.pendingZaSnapshotPages) do
                pendingCount = pendingCount + 1
                local createdAt = batch.createdAt or 0
                if batch.senderKey == senderKey then
                    senderPendingCount = senderPendingCount + 1
                    if not senderOldestAt or createdAt < senderOldestAt then
                        senderOldestKey, senderOldestAt = key, createdAt
                    end
                end
            end
            if senderPendingCount >= 3 and senderOldestKey then
                priv.pendingZaSnapshotPages[senderOldestKey] = nil
                pendingCount = pendingCount - 1
            end
            -- Ne jamais laisser un sender evincer le lot d'une autre identite.
            if pendingCount >= 24 then return end
            pendingZaSnapshot = {
                createdAt = now,
                lastAt = now,
                senderKey = senderKey,
                pageCount = zaPageCount,
                receivedCount = 0,
                pages = {},
            }
            priv.pendingZaSnapshotPages[batchKey] = pendingZaSnapshot
        elseif pendingZaSnapshot.pageCount ~= zaPageCount then
            -- Meme sender/id avec deux tailles = equivocation, jeter tout le lot.
            priv.pendingZaSnapshotPages[batchKey] = nil
            priv.completedZaSnapshots[batchKey] = now
            return
        end

        local previousBody = pendingZaSnapshot.pages[zaPageIndex]
        if previousBody and previousBody ~= zaPageBody then
            priv.pendingZaSnapshotPages[batchKey] = nil
            priv.completedZaSnapshots[batchKey] = now
            return
        end
        if not previousBody then
            pendingZaSnapshot.pages[zaPageIndex] = zaPageBody
            pendingZaSnapshot.receivedCount = pendingZaSnapshot.receivedCount + 1
        end
        pendingZaSnapshot.lastAt = now
        local receivedCount = pendingZaSnapshot.receivedCount
        if receivedCount < zaPageCount then return end

        local assembledZaSnapshot = {}
        for pageIndex = 1, zaPageCount do
            local body = pendingZaSnapshot.pages[pageIndex]
            if body == nil then return end
            if body ~= "" then assembledZaSnapshot[#assembledZaSnapshot + 1] = body end
        end
        priv.pendingZaSnapshotPages[batchKey] = nil
        priv.completedZaSnapshots[batchKey] = now
        payload = table.concat(assembledZaSnapshot, ",")
        if payload == "" then return end
        -- Tous les lots v2 (G/F/P/Q) sont atomiques jusqu'a validation. Q est une
        -- vue globale exacte emise par un client encore en quarantaine login.
        snapshotAtomic = true
        snapshotGlobal = zaSnapshotScope == "G" or zaSnapshotScope == "Q"
        snapshotComplete = snapshotGlobal
    end

    -- Protocole territorial 9.6 uniquement : un ZA non page n'a ni identite de
    -- lot, ni scope, ni preuve d'ensemble exact. Il ne doit jamais retomber sur
    -- un merge zone par zone. Les replays d'election portent explicitement leur
    -- claim key et ont deja force snapshotAtomic ci-dessus.
    if not snapshotAtomic then return end

    local changed = false
    local syncUseful = false
    local touchedInactiveFronts = {}
    local entries = self:OrderZoneAllEntries({ strsplit(",", payload) })

    local function ParseZoneAllEntry(entry)
        local zoneId, ownerCode, ts, ct = strsplit(":", entry)
        local rawCt = tonumber(ct)
        local normalizedCt = NormalizeRemoteTimestamp(ct)
        local validClockFields = rawCt ~= nil and rawCt >= 0
            and (rawCt <= 0 or normalizedCt ~= nil)
        ts = NormalizeRemoteTimestamp(ts)
        ct = normalizedCt or 0
        if (not ts or ts <= 0) and ct > 0 then ts = ct end
        local owner
        if ownerCode == "A" then owner = "Alliance"
        elseif ownerCode == "H" then owner = "Horde" end
        -- Canonicaliser AVANT les fingerprints, votes et dry-runs. Une capture
        -- historique A/H avec ct=0 equivaut a ct=ts ; N ne porte jamais de ct.
        if owner then
            if ct <= 0 and ts and ts > 0 then ct = ts end
            if ct > 0 then ts = ct end
        elseif ownerCode == "N" then
            if rawCt ~= 0 then validClockFields = false end
            ct = 0
        end
        local validOwnerCode = (owner ~= nil or ownerCode == "N") and validClockFields
        return zoneId, ownerCode, ts, ct, owner, validOwnerCode
    end

    -- Preflight complet avant toute mutation : un snapshot assemble et valide
    -- applique ensuite territoires et capitales dans un seul commit atomique.
    local zaVerifiedEntries = {}
    local seenZaZoneIds = {}
    local snapshotConsensusComplete = snapshotAtomic
    local loginPairRepairMode = false
    local runtimeGlobalRepairMode = false
    local loginPairApplyMask = {}
    local preserveRemoteLeaseMask = {}
    local expectedGlobalZoneIds = {}
    local expectedGlobalZoneCount = 0
    if snapshotGlobal then
        for _, knownZone in ipairs(CollectSrResponseZones()) do
            if knownZone and knownZone.id and not expectedGlobalZoneIds[knownZone.id] then
                expectedGlobalZoneIds[knownZone.id] = true
                expectedGlobalZoneCount = expectedGlobalZoneCount + 1
            end
        end
        if expectedGlobalZoneCount == 0 or #entries ~= expectedGlobalZoneCount then
            snapshotConsensusComplete = false
        end
    end
    for entryIndex, entry in ipairs(entries) do
        local zoneId, ownerCode, ts, ct, owner, validOwnerCode = ParseZoneAllEntry(entry)
        local stateZoneForVote = zoneId and ((Overlord.Zones and Overlord.Zones:GetZone(zoneId))
            or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId))))
        local knownZone = stateZoneForVote
            or (zoneId and Overlord.Fronts and Overlord.Fronts:IsKnownZoneId(zoneId))
        local validEntry = ts and ts > 0 and validOwnerCode and knownZone
            and not (ownerCode == "N"
                and Overlord.Zones:GetBaseZoneFixedOwner(zoneId) ~= nil)
            and not (ownerCode == "N"
                and not CanNeutralZaReplaceCanonicalCapture(
                    zoneId, stateZoneForVote, ts))
        if validEntry then
            validEntry = not IsStaleCampaignTimestamp(ts)
                and not ShouldRejectStaleTruceResetZone(zoneId, ts)
                and not ShouldRejectPostVictoryZoneOwner(
                    zoneId, owner, "captured", ts, "ZA")
        end
        local previousIndex = zoneId and seenZaZoneIds[zoneId]
        if previousIndex then
            validEntry = false
            zaVerifiedEntries[previousIndex] = false
            snapshotConsensusComplete = false
        elseif zoneId then
            seenZaZoneIds[zoneId] = entryIndex
        end
        if snapshotGlobal and not expectedGlobalZoneIds[zoneId] then
            validEntry = false
            snapshotConsensusComplete = false
        end
        -- ZA revient a une convergence mono-source : le sender fournit un lot
        -- complet, pagine, anti-equivocation, borne a la campagne et valide par
        -- freshness. Le quorum territorial ne fait plus partie de l'acceptation.
        zaVerifiedEntries[entryIndex] = validEntry == true
        if snapshotAtomic and not zaVerifiedEntries[entryIndex] then
            snapshotConsensusComplete = false
        end
    end
    if snapshotGlobal then
        for expectedZoneId in pairs(expectedGlobalZoneIds) do
            if not seenZaZoneIds[expectedZoneId] then
                snapshotConsensusComplete = false
                break
            end
        end
    end

    -- Les anciennes elections ZA dependaient des paquets vus par ce recepteur.
    -- Un lot atomique direct qui ne passe pas toutes les gardes echoue ferme ;
    -- une prochaine reponse SR complete retentera sans vote ni carte synthetique.
    if snapshotAtomic and snapshotConsensusComplete == false then return end

    -- Dry-run conservateur des lots v2. Le commit ne commence que si chaque
    -- entree peut converger depuis l'etat local actuel et si une capitale prise
    -- est valide dans la vue finale du lot entier.
    if snapshotAtomic and snapshotConsensusComplete then
        local stagedOwners = {}
        local stagedOwnerPresent = {}
        local stagedEntries = {}
        for entryIndex, entry in ipairs(entries) do
            local zoneId, ownerCode, ts, ct, owner = ParseZoneAllEntry(entry)
            local stateZone = Overlord.Zones:GetZone(zoneId)
                or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId)))
            stagedOwnerPresent[zoneId] = true
            stagedOwners[zoneId] = owner or false
            stagedEntries[#stagedEntries + 1] = {
                zoneId = zoneId, ownerCode = ownerCode, owner = owner,
                ts = ts, ct = ct, zone = stateZone, entryIndex = entryIndex,
            }

            if not zaVerifiedEntries[entryIndex] or not stateZone then
                snapshotConsensusComplete = false
                break
            end

            local loginUnconfirmed = Overlord.IsLoginZoneStateUnconfirmed
                and Overlord:IsLoginZoneStateUnconfirmed(stateZone)
            stagedEntries[#stagedEntries].loginUnconfirmed = loginUnconfirmed
            local stateUnconfirmed = loginUnconfirmed
                or stateZone._captureFinalUnattested or runtimeGlobalRepairMode
            local localCapturedAt = stateUnconfirmed and 0
                or (tonumber(stateZone.capturedTime) or 0)
            local localCanonicalTs = stateUnconfirmed and 0 or math.max(
                tonumber(stateZone.updatedAt) or 0, localCapturedAt)

            -- ZA transporte le socle stable sous le timer ZS. La premiere passe
            -- note seulement exact/mismatch ; la vue staged globale decide ensuite
            -- si la wave reste valide, doit etre rebasee ou doit etre fermee.
            local preserveRemoteLease = false
            if stateZone.status == "in_progress"
                and stateZone._remoteCaptureLease
                and not stateZone.holdAuthorityLocal then
                -- Comparaison locale uniquement : pendant la gate login, le ZS
                -- conserve volontairement _loginSyncUnconfirmed. Autoriser ici
                -- la lecture de son socle stable ne lui donne aucune voix ZA ;
                -- cela evite de rejeter le lot exact et de masquer l'orange.
                local localPart = self:BuildZoneAllSnapshotPart(stateZone, true)
                local remotePart = table.concat({
                    zoneId, ownerCode, tostring(ts), tostring(ct),
                }, ":")
                if not localPart or localPart ~= remotePart then
                    preserveRemoteLeaseMask[entryIndex] = "mismatch"
                elseif stateZone._captureFinalUnattested
                    or (Overlord.CaptureLease.RemoteStableNeedsCanonicalRebase
                        and Overlord.CaptureLease:RemoteStableNeedsCanonicalRebase(
                            stateZone, ownerCode, owner, ts, ct)) then
                    -- Le wire est exact mais le socle brut est ancien (final
                    -- visuel, owner sans horloge, N:0). Ce n'est pas un conflit.
                    preserveRemoteLeaseMask[entryIndex] = "base_cleanup"
                else
                    preserveRemoteLeaseMask[entryIndex] = "exact"
                end
                preserveRemoteLease = true
            end

            -- Une capture locale encore active est l'unique autorite physique :
            -- aucun snapshot ne peut terminer une partie du lot autour d'elle.
            if not preserveRemoteLease then
                if stateZone.status == "in_progress" and stateZone.isHolding
                    and stateZone.owner == Overlord.PlayerFaction then
                    snapshotConsensusComplete = false
                    break
                end
            end

            local skipPairMutation = preserveRemoteLease
            if loginPairRepairMode then
                if loginUnconfirmed then
                    loginPairApplyMask[entryIndex] = true
                else
                    loginPairApplyMask[entryIndex] = false
                    skipPairMutation = true
                    local localPart = self:BuildZoneAllSnapshotPart(stateZone, false)
                    local remotePart = table.concat({
                        zoneId, ownerCode, tostring(ts), tostring(ct),
                    }, ":")
                    if localPart ~= remotePart then
                        snapshotConsensusComplete = false
                        break
                    end
                end
            else
                loginPairApplyMask[entryIndex] = true
            end

            if not skipPairMutation and ownerCode == "N" then
                local neutralIdempotent = not stateZone.owner
                    and ts >= localCanonicalTs and stateZone.status ~= "in_progress"
                local neutralCanApply = stateZone.status ~= "in_progress"
                    and ts > localCanonicalTs
                if not neutralIdempotent and not neutralCanApply then
                    snapshotConsensusComplete = false
                    break
                end
            elseif not skipPairMutation and stateZone.status == "in_progress" then
                -- La branche de commit ne promeut un timer observe qu'avec une
                -- capturedTime strictement plus recente.
                if ct <= localCapturedAt or ts <= localCanonicalTs then
                    snapshotConsensusComplete = false
                    break
                end
            elseif not skipPairMutation and stateZone.owner
                and stateZone.owner ~= owner and not stateUnconfirmed then
                local captureWins = ct > 0 and (localCapturedAt <= 0
                    or ct > localCapturedAt
                    or (ct == localCapturedAt
                        and self:DeterministicCaptureTieOwner(zoneId, ct) == owner))
                if not captureWins or (localCapturedAt <= 0 and ts < localCanonicalTs) then
                    snapshotConsensusComplete = false
                    break
                end
            elseif not skipPairMutation and not stateZone.owner and not stateUnconfirmed
                and ts < localCanonicalTs then
                snapshotConsensusComplete = false
                break
            end
        end

        if snapshotConsensusComplete then
            for _, staged in ipairs(stagedEntries) do
                if staged.zone and staged.zone.status == "in_progress"
                    and staged.zone._remoteCaptureLease
                    and not staged.zone.holdAuthorityLocal then
                    -- Une carte globale exacte peut prouver que la wave est
                    -- impossible : cible deja possedee par l'attaquant, chaine
                    -- de prerequis absente, ou capitale ouverte trop tot. Fermer
                    -- sur le socle ZA certifie ; l'overlay n'a aucun droit de veto.
                    if snapshotComplete and ((staged.owner ~= nil
                            and staged.owner == staged.zone._remoteCaptureLease.owner)
                        or not RemoteCaptureMeetsStagedPrereqs(
                            staged.zoneId, staged.zone._remoteCaptureLease.owner,
                            stagedOwners, stagedOwnerPresent)) then
                        if preserveRemoteLeaseMask[staged.entryIndex] == "mismatch"
                            or preserveRemoteLeaseMask[staged.entryIndex]
                                == "base_cleanup" then
                            preserveRemoteLeaseMask[staged.entryIndex] = "rebase_close"
                        else
                            preserveRemoteLeaseMask[staged.entryIndex] = "close"
                        end
                    elseif preserveRemoteLeaseMask[staged.entryIndex] == "mismatch" then
                        if staged.loginUnconfirmed and snapshotComplete then
                            preserveRemoteLeaseMask[staged.entryIndex] = "rebase"
                        else
                            snapshotConsensusComplete = false
                            break
                        end
                    elseif preserveRemoteLeaseMask[staged.entryIndex] == "base_cleanup"
                        and snapshotComplete then
                        -- Le G exact certifie le socle : nettoyer l'ancien final
                        -- sans toucher a l'identite, au TTL ni aux preuves de la wave.
                        preserveRemoteLeaseMask[staged.entryIndex] = "cleanup"
                    else
                        preserveRemoteLeaseMask[staged.entryIndex] = "preserve"
                    end
                    preserveRemoteLeaseMask[staged.entryIndex] =
                        Overlord.CaptureLease:PrepareRemoteStablePlan(
                            staged.zoneId, staged.ownerCode, staged.owner,
                            staged.ts, staged.ct,
                            preserveRemoteLeaseMask[staged.entryIndex])
                    if not preserveRemoteLeaseMask[staged.entryIndex]
                        or not Overlord.CaptureLease:ValidateRemoteStablePlan(
                            preserveRemoteLeaseMask[staged.entryIndex]) then
                        snapshotConsensusComplete = false
                        break
                    end
                    if preserveRemoteLeaseMask[staged.entryIndex].close
                        and preserveRemoteLeaseMask[staged.entryIndex].frontId
                        and Overlord.Fronts.activeFrontId
                            ~= preserveRemoteLeaseMask[staged.entryIndex].frontId then
                        touchedInactiveFronts[
                            preserveRemoteLeaseMask[staged.entryIndex].frontId] = true
                    end
                end

                local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(staged.zoneId)
                if fixedOwner and staged.owner and staged.owner ~= fixedOwner then
                    local _, stagedFront = Overlord.Fronts:GetZone(staged.zoneId)
                    for _, otherZone in ipairs((stagedFront and stagedFront.zones) or {}) do
                        if otherZone.id ~= staged.zoneId then
                            local prospectiveOwner
                            if stagedOwnerPresent[otherZone.id] then
                                prospectiveOwner = stagedOwners[otherZone.id]
                            else
                                prospectiveOwner = otherZone.owner
                            end
                            local omittedStateUnsafe = not stagedOwnerPresent[otherZone.id]
                                and (otherZone.status == "in_progress"
                                    or otherZone._captureFinalUnattested
                                    or otherZone._loginSyncUnconfirmed)
                            if prospectiveOwner == false then prospectiveOwner = nil end
                            if omittedStateUnsafe or prospectiveOwner ~= staged.owner then
                                snapshotConsensusComplete = false
                                break
                            end
                        end
                    end
                    if not snapshotConsensusComplete then break end
                end
            end
        end
    end
    -- Un lot moderne ne touche rien tant que chacune de ses zones n'a pas passe
    -- la validation atomique.
    if snapshotAtomic and not snapshotConsensusComplete then return end

    -- Au moins une zone avec owner : rejeter les ts d'ancienne campagne (bloc dominated, localTs==0)
    local hasAnyLocalData = false
    for _, z in ipairs(Overlord.ZoneDatabase) do
        if z.owner then hasAnyLocalData = true; break end
    end

    for entryIndex, entry in ipairs(entries) do
        -- 4e champ (capturedTime) optionnel pour retro-compat avec anciens clients
        local zoneId, ownerCode, ts, ct, owner = ParseZoneAllEntry(entry)
        local zaClaimVerified = zaVerifiedEntries[entryIndex] == true
        local zaEntryAccepted = zaClaimVerified
            and (not loginPairRepairMode or loginPairApplyMask[entryIndex] == true)
            and not preserveRemoteLeaseMask[entryIndex]
        if zaClaimVerified and preserveRemoteLeaseMask[entryIndex] then
            -- Le plan reste detache jusqu'a la fin des autres commits, dont les
            -- chemins login historiques peuvent encore refuser une application.
            syncUseful = true
        end
        local loginWinnerApplied = false
        if zaEntryAccepted and loginPairRepairMode then
            local applied, appliedFrontId = self:ApplyLoginElectedZoneSnapshot(
                zoneId, ownerCode, owner, ts, ct)
            if not applied then return end
            if appliedFrontId and Overlord.Fronts.activeFrontId ~= appliedFrontId then
                touchedInactiveFronts[appliedFrontId] = true
            end
            changed = true
            syncUseful = true
            loginWinnerApplied = true
        end
        if zaEntryAccepted and not loginWinnerApplied then
            -- ZA est un snapshot : seul capturedTime prouve une capture recente.
            -- updatedAt peut etre frais pour un etat ancien et ne doit pas creer d'activite.
            if not loginPairRepairMode and not runtimeGlobalRepairMode and ct > 0
                and Overlord.FrontActivity and Overlord.FrontActivity.RecordByZoneRef then
                Overlord.FrontActivity:RecordByZoneRef(zoneId, nil, ct)
            end
            local zone = Overlord.Zones:GetZone(zoneId)
            if ownerCode == "N" then
                -- Etat neutre explicite : CanNeutralZaReplaceCanonicalCapture a
                -- deja exige une frontiere de campagne ou un tombstone de reset.
                -- Une capitale ne peut jamais devenir neutre.
                local neutralZone, neutralFront = zone, nil
                if Overlord.Fronts then
                    local resolvedZone, resolvedFront = Overlord.Fronts:GetZone(zoneId)
                    neutralZone = neutralZone or resolvedZone
                    neutralFront = resolvedFront
                end
                local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
                local neutralLoginUnconfirmed = neutralZone
                    and Overlord.IsLoginZoneStateUnconfirmed
                    and Overlord:IsLoginZoneStateUnconfirmed(neutralZone)
                local neutralStateUnconfirmed = neutralLoginUnconfirmed
                    or (neutralZone and neutralZone._captureFinalUnattested)
                    or runtimeGlobalRepairMode
                local localCanonicalTs = neutralStateUnconfirmed and 0
                    or (neutralZone and math.max(
                        tonumber(neutralZone.updatedAt) or 0,
                        tonumber(neutralZone.capturedTime) or 0) or 0)
                local localHolding = neutralZone and neutralZone.status == "in_progress"
                    and neutralZone.isHolding and neutralZone.owner == Overlord.PlayerFaction
                if neutralZone and not fixedOwner and not localHolding and ts > localCanonicalTs then
                    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                        Overlord.CaptureLease:Complete(neutralZone)
                    end
                    if Overlord.Zones.ClearCaptureFinalUnattestedState then
                        Overlord.Zones:ClearCaptureFinalUnattestedState(neutralZone)
                    end
                    neutralZone.owner = nil
                    neutralZone.previousOwner = nil
                    neutralZone.capturedTime = nil
                    neutralZone.status = "locked"
                    neutralZone.updatedAt = ts
                    neutralZone.isHolding = false
                    neutralZone.holdAuthorityLocal = nil
                    neutralZone.isContested = false
                    neutralZone.isPaused = false
                    neutralZone.holdTimeElapsed = 0
                    neutralZone.holdStartTime = nil
                    neutralZone.holdTimeRequired = 120
                    if neutralFront and Overlord.Fronts.activeFrontId ~= neutralFront.id then
                        touchedInactiveFronts[neutralFront.id] = true
                    end
                    changed = true
                elseif neutralZone and not fixedOwner and not localHolding
                    and not neutralZone.owner and ts >= localCanonicalTs then
                    neutralZone._loginSyncUnconfirmed = nil
                    syncUseful = true
                end
            else
            -- Apres validation ZA, un timer orange purement observe peut etre termine
            -- avec une capturedTime plus recente. La capture locale encore tenue
            -- reste protegee par la branche isHolding ci-dessous et par le dry-run.
            if zone then
                local loginUnconfirmed = Overlord.IsLoginZoneStateUnconfirmed
                    and Overlord:IsLoginZoneStateUnconfirmed(zone)
                local stateUnconfirmed = loginUnconfirmed
                    or zone._captureFinalUnattested or runtimeGlobalRepairMode
                local localCapturedTs = stateUnconfirmed and 0
                    or (tonumber(zone.capturedTime) or 0)
                local localTs = stateUnconfirmed and 0
                    or (((ct > 0 and localCapturedTs > 0)
                        and localCapturedTs) or (zone.updatedAt or 0))
                if zone.owner == owner and ts > 0
                    and (ts >= localTs or (ct > 0 and ct >= (zone.capturedTime or 0))) then
                    syncUseful = true
                end
                if ts < localTs then
                    -- Donnee distante plus ancienne : ignore
                    -- Meme proprietaire, donnee plus ancienne : sync capturedTime + force status
                    -- (corrige forteresse desyncee apres retour d'instance ET zones bloquees
                    -- en "locked" par UpdateAvailableZones quand les prereqs arrivent dans le desordre)
                    if zone.owner == owner then
                        if ct > 0 and ct > (zone.capturedTime or 0) then
                            zone.capturedTime = ct
                            changed = true
                        end
                        if zone.status ~= "captured" and zone.status ~= "in_progress" then
                            zone.status = "captured"
                            changed = true
                        end
                    elseif owner == Overlord.PlayerFaction
                        and TryHealStaleEnemyOwnerFromFriendlyCapture(zone, "captured", owner, ts, sender, {
                            loginUnconfirmed = loginUnconfirmed,
                        }) then
                        if ct > 0 then
                            zone.capturedTime = ct
                        end
                        changed = true
                    end
                elseif zone.status == "in_progress" and zone.isHolding
                    and zone.owner == Overlord.PlayerFaction then
                    -- Capture alliee locale (autorite ou co-capture) : ZA ne peut pas l'ecraser.
                    -- Une defense locale d'un in_progress ennemi garde owner=ennemi :
                    -- elle peut donc accepter un ZA captured frais si C/ZS final a ete perdu.
                elseif zone.status == "in_progress" then
                    -- Zone in_progress mais pas tenue localement (capture distante en cours).
                    -- ZA est un snapshot : il ne termine pas une capture sans capturedTime.
                    -- Les fins reelles arrivent par C, ZS captured, ou ZA avec ct plus recent.
                    local capturedAt = stateUnconfirmed and 0
                        or (zone.capturedTime or 0)
                    local hasFreshCapturedTime = ct > 0 and ct > capturedAt
                    local canPromoteFromZA = hasFreshCapturedTime
                    if canPromoteFromZA then
                        local zaCaptureTs = (ct > 0) and ct or ts
                        if owner == Overlord.Zones:GetEnemyFaction()
                            and zone.previousOwner == Overlord.PlayerFaction
                            and ShouldRejectStaleEnemyAttackOnOurCapture(zone, "captured", owner, zaCaptureTs, 0, {
                                defenderOwner = zone.previousOwner,
                                defenderStatus = "captured",
                                capturedTime = capturedAt,
                            }) then
                            canPromoteFromZA = false
                        end
                    end
                    if canPromoteFromZA then
                        local oldStatus = zone.status
                        local oldOwner = zone.owner
                        local previousBeforePromote = zone.previousOwner
                        local zaCaptureTs = (ct > 0) and ct or ts
                        zone.status = "captured"
                        zone.owner = owner
                        zone.capturedTime = zaCaptureTs
                        zone.isHolding = false
                        zone.isContested = false
                        zone.isPaused = false
                        zone.holdTimeElapsed = 0
                        zone.holdStartTime = nil
                        zone.previousOwner = nil
                        zone._syncGateRemoteProgress = nil
                        zone._syncGateRemoteProgressUntil = nil
                        zone.updatedAt = ts
                        zone._loginSyncUnconfirmed = nil
                        changed = true
                        if not loginPairRepairMode and not runtimeGlobalRepairMode
                            and ShouldAlertEnemyZoneCapture(
                                oldStatus, oldOwner, previousBeforePromote, owner, zone) then
                            PrintCaptureChatOnce(zone, owner, EffectiveCapturerNameForAlert(zone, nil), zaCaptureTs)
                        end
                        priv.enemyAlertEmitted[zoneId] = nil
                        priv.enemyAlertSkipUntil[zoneId] = nil
                    end
                elseif zone.owner == owner then
                    -- Meme proprio, mise a jour du timestamp + capturedTime + force status.
                    -- capturedTime protege les captures stales au sync ZA.
                    -- Force status = "captured" : corrige les zones bloquees en "locked" par
                    -- UpdateAvailableZones quand les prereqs ne sont pas encore synches.
                    zone.updatedAt = ts
                    if zone.status ~= "captured" and zone.status ~= "in_progress" then
                        zone.status = "captured"
                    end
                    if stateUnconfirmed then
                        zone.capturedTime = (ct > 0) and ct or ts
                    elseif ct > 0 and ct > (zone.capturedTime or 0) then
                        zone.capturedTime = ct
                    end
                    zone._loginSyncUnconfirmed = nil
                    changed = true
                else
                    -- Changement de proprietaire via ZA : ZA est un snapshot, pas une preuve de capture.
                    -- Exiger capturedTime plus recent empeche un vieux snapshot avec updatedAt gonfle
                    -- de reflipper silencieusement une zone deja reprise par l'autre faction.
                    local capturedAt = stateUnconfirmed and 0 or (zone.capturedTime or 0)
                    local zaWinsCaptureTie = capturedAt > 0 and ct == capturedAt
                        and zone.owner ~= owner
                        and self:DeterministicCaptureTieOwner(zoneId, ct) == owner
                    local dominated = false
                    -- ZA est un snapshot, pas une preuve : sans capturedTime distant,
                    -- il ne peut pas changer le proprietaire d'une zone deja attribuee.
                    if zone.owner and zone.owner ~= owner and ct <= 0 and not stateUnconfirmed then
                        dominated = true
                    end
                    -- Sous quarantaine login, l'ancien capturedTime disque n'est
                    -- pas une preuve contre un snapshot ZA certifie, meme legacy ct=0.
                    -- Si on possede deja un capturedTime, un ZA sans ct ne peut pas prouver
                    -- une capture plus recente : updatedAt ordonne les snapshots, pas les captures.
                    if capturedAt > 0 then
                        if ct == 0 or ct < capturedAt
                            or (ct == capturedAt and not zaWinsCaptureTie) then
                            dominated = true
                        end
                    end
                    -- Protection prerequis : une zone de base ne peut pas changer
                    -- de proprietaire via ZA sauf si le nouveau proprio controle tout.
                    -- Empeche la propagation de donnees stales (ex: hammerfell Alliance
                    -- alors que la Horde controle 9 zones).
                    if not dominated then
                        local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
                        -- Les lots atomiques ont deja valide la capitale contre
                        -- stagedOwners (socles certifies, sans overlays orange).
                        -- Relire ici zone.owner recreerait un veto apres dry-run.
                        if not snapshotAtomic and fixedOwner and owner ~= fixedOwner then
                            local allControlled = true
                            for _, z in ipairs(Overlord.ZoneDatabase) do
                                if z.id ~= zoneId and z.owner ~= owner then
                                    allControlled = false
                                    break
                                end
                            end
                            if not allControlled then
                                dominated = true
                            end
                        end
                    end
                    -- Protection supplementaire : si localTs = 0 (zone jamais mise a jour)
                    -- ET qu'on a deja des donnees locales (post-reset ou reconnexion),
                    -- rejeter uniquement les donnees anterieures au dernier reset hebdo.
                    -- L'ancien seuil de 10 min rejetait les captures legitimement faites
                    -- pendant la campagne en cours (ex : revenir le soir apres reset du matin).
                    -- La vraie frontiere est le timestamp du reset : ts < lastReset = ancienne campagne.
                    if not dominated and localTs == 0 and hasAnyLocalData then
                        local lastReset = OverlordDB and OverlordDB.lastResetTimestamp or 0
                        if ts > 0 and lastReset > 0 and ts < lastReset then
                            dominated = true
                        end
                    end
                    local enemyFac = Overlord.Zones:GetEnemyFaction()
                    if not dominated and not zaWinsCaptureTie
                        and zone.owner == Overlord.PlayerFaction
                        and owner == enemyFac
                        and (zone.status == "captured" or zone.status == "locked") then
                        local zaCaptureTs = (ct > 0) and ct or ts
                        local staleAttackOpts = stateUnconfirmed and { capturedTime = 0 } or nil
                        if ShouldRejectStaleEnemyAttackOnOurCapture(zone, "captured", owner, zaCaptureTs, 0, staleAttackOpts) then
                            dominated = true
                        elseif Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive() then
                            -- Gate login : bloquer seulement sans capturedTime distant plus recent.
                            -- ct > capturedAt + ShouldRejectStaleEnemyAttackOnOurCapture suffisent sinon ;
                            -- un blocage inconditionnel laissait la carte SV stale jusqu'a timeout (45 s).
                            if not stateUnconfirmed and (ct <= 0 or ct <= capturedAt) then
                                dominated = true
                            end
                        end
                    end
                    if not dominated then
                        local oldStatus = zone.status
                        local oldOwner = zone.owner
                        local oldPreviousOwner = zone.previousOwner
                        local zaCaptureTs = (ct > 0) and ct or ts
                        zone.owner = owner
                        zone.status = "captured"
                        zone.capturedTime = zaCaptureTs
                        zone.holdTimeElapsed = 0
                        zone.updatedAt = ts
                        zone._loginSyncUnconfirmed = nil
                        CompleteAcceptedZsTerminal(zone, zone.status)
                        changed = true
                        if not loginPairRepairMode and not runtimeGlobalRepairMode
                            and ShouldAlertEnemyZoneCapture(
                                oldStatus, oldOwner, oldPreviousOwner, owner, zone) then
                            PrintCaptureChatOnce(zone, owner, EffectiveCapturerNameForAlert(zone, nil), zaCaptureTs)
                        end
                        if owner == Overlord.Zones:GetEnemyFaction() then
                            priv.enemyAlertEmitted[zoneId] = nil
                            priv.enemyAlertSkipUntil[zoneId] = nil
                        end
                    end
                end
                if zone.status == "captured" and zone.owner == owner then
                    -- Une quarantaine visuelle n'est levee qu'apres que le meme
                    -- owner/timestamp a effectivement gagne le merge ZA certifie.
                    ClearVisualFinalPending(
                        zone, nil, nil, (ct > 0) and ct or ts, true)
                end
                if zone.status == "captured" and zone.owner == owner
                    and not zone._captureFinalUnattested
                    and ((ct > 0 and ct >= (tonumber(zone.capturedTime) or 0))
                        or (ct <= 0 and (tonumber(zone.capturedTime) or 0) <= 0)) then
                    local hadTerminalEphemera = zone.previousOwner ~= nil
                        or zone._remoteCaptureLease ~= nil
                        or zone._lastCaptureFinalWaveId ~= nil
                        or zone._observerDisplayHold ~= nil
                    zone.previousOwner = nil
                    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                        Overlord.CaptureLease:Complete(zone)
                    end
                    if Overlord.Zones.ClearCaptureFinalUnattestedState then
                        Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
                    end
                    if hadTerminalEphemera then changed = true end
                end
            elseif not zone then
                local inactiveZone, inactiveFront
                if Overlord.Fronts then
                    inactiveZone, inactiveFront = Overlord.Fronts:GetZone(zoneId)
                end
                local inactiveBaseAllowed = true
                local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
                -- Meme regle pour un front inactif : la vue staged globale a
                -- deja certifie toutes les zones avant la premiere mutation.
                if not snapshotAtomic and fixedOwner and owner ~= fixedOwner then
                    for _, otherZone in ipairs((inactiveFront and inactiveFront.zones) or {}) do
                        if otherZone.id ~= zoneId and otherZone.owner ~= owner then
                            inactiveBaseAllowed = false
                            break
                        end
                    end
                end
                local inactiveApplied = inactiveBaseAllowed and ApplyInactiveFrontZoneState(
                    zoneId, "captured", 0, 0, owner, ts, nil, nil, ct,
                    nil, nil, nil, runtimeGlobalRepairMode) or false
                if inactiveApplied then
                    changed = true
                end
                if inactiveZone and inactiveZone.status == "captured"
                    and inactiveZone.owner == owner then
                    ClearVisualFinalPending(
                        inactiveZone, nil, nil, (ct > 0) and ct or ts, true)
                end
                if inactiveZone and inactiveZone.status == "captured"
                    and inactiveZone.owner == owner and not inactiveZone._captureFinalUnattested
                    and ((ct > 0 and ct >= (tonumber(inactiveZone.capturedTime) or 0))
                        or (ct <= 0 and (tonumber(inactiveZone.capturedTime) or 0) <= 0)) then
                    inactiveZone.previousOwner = nil
                    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                        Overlord.CaptureLease:Complete(inactiveZone)
                    end
                    if Overlord.Zones.ClearCaptureFinalUnattestedState then
                        Overlord.Zones:ClearCaptureFinalUnattestedState(inactiveZone)
                    end
                    PersistSyncedZoneState(inactiveZone)
                end
            end
            end
        end
    end
    -- Les autres commits potentiellement fallibles sont termines. Ces plans sont
    -- totaux : aucun lookup/return ne peut couper le lot entre deux leases.
    for planIndex = 1, #entries do
        if preserveRemoteLeaseMask[planIndex] then
            Overlord.CaptureLease:CommitRemoteStablePlan(
                preserveRemoteLeaseMask[planIndex])
            if preserveRemoteLeaseMask[planIndex].action ~= "preserve" then
                changed = true
            end
            if preserveRemoteLeaseMask[planIndex].close then
                priv.enemyAlertEmitted[
                    preserveRemoteLeaseMask[planIndex].zone.id] = nil
                priv.enemyAlertSkipUntil[
                    preserveRemoteLeaseMask[planIndex].zone.id] = nil
            end
        end
    end
    if snapshotComplete and snapshotConsensusComplete
        and Overlord.ClearLoginUnconfirmedZoneState then
        -- Visuellement atomique : aucun marqueur ne sort de SYNC avant que le
        -- snapshot global ait fini de remplacer/rebaser toutes les zones.
        if Overlord:ClearLoginUnconfirmedZoneState() then changed = true end
    end
    local allLoginZonesConfirmed = true
    if snapshotComplete then
        for _, knownZone in ipairs(CollectSrResponseZones()) do
            if knownZone._loginSyncUnconfirmed
                or (loginPairRepairMode and knownZone._captureFinalUnattested) then
                allLoginZonesConfirmed = false
                break
            end
        end
    end
    snapshotComplete = snapshotComplete and snapshotConsensusComplete
        and allLoginZonesConfirmed
    for frontId in pairs(touchedInactiveFronts) do
        if Overlord.Zones.RefreshInactiveFrontAvailability then
            Overlord.Zones:RefreshInactiveFrontAvailability(frontId)
        end
    end
    if changed then
        Overlord.Zones:UpdateAvailableZones(
            loginPairRepairMode or runtimeGlobalRepairMode)
        Overlord:MarkDirty()
        if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
            Overlord.MapMarkers:RequestOverlayRefresh()
        end
        if Overlord.UI then Overlord.UI:RequestRefresh() end
    end
    if snapshotComplete and (changed or syncUseful) and Overlord.MarkCaptureSyncReceived then
        Overlord:MarkCaptureSyncReceived(true)
    elseif (changed or syncUseful) and Overlord.MarkCaptureSyncReceived then
        -- Compat anciens ZA : utile pour corriger une zone, jamais suffisant pour
        -- declarer que la carte entiere a ete recue.
        Overlord:MarkCaptureSyncReceived()
    end
    if snapshotComplete and (changed or syncUseful) and Overlord.WaitingForSync then
        Overlord.WaitingForSync = nil
    end
    if loginPairRepairMode and snapshotComplete and C_Timer and C_Timer.After then
        -- Le client repare devient la troisieme vue correcte pour les deux pairs
        -- qui auraient eux-memes demarre en quarantaine avec seulement une voix
        -- concordante. Attendre la courte gate de stabilisation avant de republier.
        C_Timer.After(9, function()
            if Overlord.Sync and Overlord.Sync.BroadcastCompactZoneSnapshot then
                Overlord.Sync:BroadcastCompactZoneSnapshot({ includeCommunity = true })
                -- En split 2/1 simultane, les deux membres deja sur la carte
                -- gagnante n'avaient chacun qu'une voix distante. Leur redemander
                -- un Q/G fournit la seconde vue necessaire sans baisser le seuil.
                Overlord.Sync:SendSyncRequest({ includeCommunity = true })
            end
        end)
    end
    -- Un ZA de rattrapage peut etre le premier paquet qui aligne toute la carte
    -- apres la perte d'un C / ZS captured / TV. Dans ce cas, il doit aussi poser la treve.
    if (changed or syncUseful)
        and not loginPairRepairMode and not runtimeGlobalRepairMode then
        self:CheckTotalVictoryFromSync()
    end
    -- Carte realignee : pousser les totaux DM pour que la barre domination reconverge entre pairs.
    if changed and not loginPairRepairMode and not runtimeGlobalRepairMode
        and Overlord.Sync and Overlord.Sync.BroadcastDomination
        and not Overlord.InstanceSuspended and not IsInInstance() then
        C_Timer.After(0.5, function()
            if Overlord.InstanceSuspended or not Overlord.Sync then return end
            Overlord.Sync:BroadcastDomination()
        end)
    end
    return snapshotComplete and snapshotConsensusComplete
        and (changed or syncUseful)
end

-- Recoit un entry de leaderboard kills avec classe+faction (prend le max)
-- Format : name:kills:class:faction:epoch:locale:guild:guildAt:BbucketEpoch:level
-- Rejete si l'epoch calendrier ou l'epoch reel du bucket est absent/perime.
-- Classe vide ou "UNKNOWN" : ne pas appeler SetPlayerInfo avec ca (pollution SV - voir Leaderboard entete GetExportPlayerMeta).
function Overlord.Sync:OnReceiveLeaderboardKills(payload, sender, channel)
    if not payload then return end
    -- Anti-triche : expediteur en quarantaine (faux classement diffuse via LK).
    if self.KillAntiSpoofIsBlacklisted and self:KillAntiSpoofIsBlacklisted(sender) then return end
    local rawName, kills, class, faction, epochStr, locTag, guildTag, guildAtStr,
        bucketEpochToken, levelToken = strsplit(":", payload, 10)
    if not rawName or not self:IsValidPlayerName(rawName) then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    if not IsCurrentLeaderboardScoreBucket(remoteEpoch, bucketEpochToken) then return end
    -- Normalise le nom pour eviter doublons (pipe, apostrophes unicode, etc.)
    local playerName = self:NormalizeContributorFullName(rawName)
    if not playerName or playerName == "" then return end
    local validFaction = faction == "Alliance" or faction == "Horde"
    if faction ~= "" and faction ~= "U" and not validFaction then return end
    -- Refuse les placeholders "Unknown" venus d'un pair non patche.
    if not self:AcceptSyncedContributorName(playerName) then return end
    if self.IsDeniedKillContributor and self:IsDeniedKillContributor(playerName) then return end
    if not self.IsEligibleKillContributorLevel
        or not self:IsEligibleKillContributorLevel(levelToken) then return end
    local classMetadataValid = class and class ~= "" and class ~= "UNKNOWN"
        and self.IsValidCaptureClassToken and self:IsValidCaptureClassToken(class)
    -- LK est un snapshot monotone deja atteste par campagne + bucket. Les
    -- champs valides sont fusionnes immediatement ; attendre des votes locaux
    -- produisait un classement different sur chaque client.
    local classClaimVerified = classMetadataValid
    local factionClaimVerified = validFaction
    local localeClaimVerified = locTag and locTag ~= ""
    local sanitizedKills = self.SanitizeSyncedKillTotal
        and self:SanitizeSyncedKillTotal(kills)
    if not sanitizedKills then return end
    kills = sanitizedKills
    local guildAt = tonumber(guildAtStr) or 0
    local validGuildRegister = guildTag and guildTag ~= ""
        and self:IsValidGuildSyncToken(guildTag)
    local hasGuildRegister = validGuildRegister or guildAt > 0
    if not self:AuthorizeLeaderboardSubject("LK", playerName, sender, channel) then return end
    local observedLevelEligible = self.IsObservedPlayerKillLevelEligible
        and self:IsObservedPlayerKillLevelEligible(playerName)
    if observedLevelEligible == false then return end
    if Overlord.Leaderboard.MergeLeaderboardKillMetadata then
        Overlord.Leaderboard:MergeLeaderboardKillMetadata(
            playerName,
            levelToken,
            classClaimVerified and class or nil,
            factionClaimVerified and faction or nil,
            localeClaimVerified and locTag or nil,
            validGuildRegister and guildTag or "",
            guildAt,
            hasGuildRegister)
    elseif Overlord.Leaderboard.SetPlayerLevel then
        Overlord.Leaderboard:SetPlayerLevel(playerName, levelToken)
    end
    Overlord.Leaderboard:SetPlayerKills(playerName, kills, true)
    -- Classe / faction / locale ci-dessous ; la guilde (champ 7) est traitee plus bas.
    if classClaimVerified and not Overlord.Leaderboard.MergeLeaderboardKillMetadata then
        Overlord.Leaderboard:SetPlayerClassFromSync(playerName, class)
    elseif not class or class == "" or class == "UNKNOWN" then
        if Overlord.Leaderboard.AllowClassRefetchFromSync then
            Overlord.Leaderboard:AllowClassRefetchFromSync(playerName)
        end
        self:MaybeRequestMissingClass(playerName)
    end
    if factionClaimVerified and not Overlord.Leaderboard.MergeLeaderboardKillMetadata then
        Overlord.Leaderboard:SetPlayerFaction(playerName, faction)
    end
    if localeClaimVerified and Overlord.Leaderboard.SetPlayerLocale
        and not Overlord.Leaderboard.MergeLeaderboardKillMetadata then
        Overlord.Leaderboard:SetPlayerLocale(playerName, locTag)
    end
    -- Un LK peut relayer la ligne d'un tiers : la guilde est un hint horodate,
    -- non autoritaire, fusionne deterministement comme en 9.3.1.
    if not Overlord.Leaderboard.MergeLeaderboardKillMetadata
        and guildTag and guildTag ~= "" and self:IsValidGuildSyncToken(guildTag)
        and Overlord.Leaderboard.SetPlayerGuild then
        Overlord.Leaderboard:SetPlayerGuild(
            playerName, guildTag, true, false, guildAtStr, false)
    elseif not Overlord.Leaderboard.MergeLeaderboardKillMetadata
        and tonumber(guildAtStr) and tonumber(guildAtStr) > 0
        and Overlord.Leaderboard.ClearPlayerGuild then
        -- Le tombstone voyage dans LK avec le meme registre LWW que la guilde non vide.
        Overlord.Leaderboard:ClearPlayerGuild(playerName, true, true, guildAtStr)
    end
    -- MaybeRequestMissingGuild verifie deja la guilde connue en interne (pas de pre-check O(N)).
    self:MaybeRequestMissingGuild(playerName)
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end
    return true
end

-- Recoit un entry de leaderboard captures
-- Format actuel : name:A|H:class:captureCount:epoch:zone1,zone2,...:locale:BbucketEpoch
-- Ancien (retro) : name:A|H:captureCount:epoch:zones... si le 3e champ est numerique
-- Rejete si epoch absent ou hors campaignId courant
function Overlord.Sync:OnReceiveLeaderboardCaptures(payload, sender, channel)
    if not payload then return end
    local p1, p2, p3, p4, p5, p6, p7, p8 = strsplit(":", payload, 8)
    if not p1 or not self:IsValidPlayerName(p1) or not p2 or p2 == "" then return end

    -- Normalise le nom pour eviter doublons (pipe, apostrophes unicode, etc.)
    local playerName = self:NormalizeContributorFullName(p1)
    if not playerName or playerName == "" then return end
    local factionCode = p2
    local classToken, capRemote, remoteEpoch, zoneList, locTag, bucketEpochToken
    if tonumber(p3) ~= nil then
        -- Legacy sans classe (3e champ numerique) : pas de locale dans ce format
        capRemote = tonumber(p3)
        remoteEpoch = tonumber(p4)
        zoneList = p5
        classToken = nil
        locTag = nil
        bucketEpochToken = nil
    else
        classToken = p3
        capRemote = tonumber(p4)
        remoteEpoch = tonumber(p5)
        zoneList = p6
        locTag = p7
        bucketEpochToken = p8
    end

    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    if not IsCurrentLeaderboardScoreBucket(remoteEpoch, bucketEpochToken) then return end
    if not capRemote then return end
    if not self:AcceptSyncedContributorName(playerName) then return end
    -- Valider l'integralite du score avant toute ecriture de metadonnees ou de zones.
    -- Un LC refuse ne doit pas pouvoir polluer faction/classe/captures malgre son total rejete.
    if factionCode ~= "H" and factionCode ~= "A" and factionCode ~= "U" then return end
    local normalizedFaction = factionCode == "H" and "Horde"
        or (factionCode == "A" and "Alliance" or nil)
    local classMetadataValid = classToken and classToken ~= ""
        and classToken ~= "UNKNOWN" and self.IsValidCaptureClassToken
        and self:IsValidCaptureClassToken(classToken)
    -- LC est un snapshot du meme CRDT que LK : metadata validee, max du
    -- compteur et union des zones doivent s'appliquer depuis une seule replique.
    local classClaimVerified = classMetadataValid
    local factionClaimVerified = normalizedFaction ~= nil
    local localeClaimVerified = locTag and locTag ~= ""
    local sanitizedCap = self.SanitizeSyncedCaptureCount
        and self:SanitizeSyncedCaptureCount(capRemote)
    if sanitizedCap == nil then return end
    if not self:AuthorizeLeaderboardSubject("LC", playerName, sender, channel) then return end
    local verifiedZones = {}
    if zoneList and zoneList ~= "" then
        for zoneId in string.gmatch(zoneList, "[^,]+") do
            local knownZone = Overlord.Zones:GetZone(zoneId)
                or (Overlord.Fronts and Overlord.Fronts:IsKnownZoneId(zoneId))
                or (Overlord.Leaderboard.IsValidCaptureObjectiveId
                    and Overlord.Leaderboard:IsValidCaptureObjectiveId(zoneId))
            if zoneId ~= "" and knownZone then
                verifiedZones[#verifiedZones + 1] = zoneId
            end
        end
    end
    local previousCaptureTotal = Overlord.Leaderboard.GetMaxCapturesForDedupName
        and Overlord.Leaderboard:GetMaxCapturesForDedupName(playerName) or 0
    -- Ecriture paresseuse : on stocke le nom brut sans merge dedup.
    -- La fusion se fait a la lecture (UI, SR, Export) via MergeDuplicateLeaderboardKeysByDedup.

    -- SetPlayerCaptureCount ne fait que monter le total : appliquer LC pour soi-meme meme si
    -- capRemote > local (sinon compteur fige quand le credit local etait bloque a tort).

    if factionClaimVerified then
        Overlord.Leaderboard:SetPlayerFaction(playerName, normalizedFaction)
    end

    if classClaimVerified then
        Overlord.Leaderboard:SetPlayerClassFromSync(playerName, classToken)
    elseif not classToken or classToken == "" or classToken == "UNKNOWN" then
        -- Classe absente du LC : tenter de la recuperer localement
        local resolved = self:ResolveContributorClassToken(playerName)
        if resolved and resolved ~= "" then
            Overlord.Leaderboard:SetPlayerClassFromSync(playerName, resolved)
        else
            if Overlord.Leaderboard.AllowClassRefetchFromSync then
                Overlord.Leaderboard:AllowClassRefetchFromSync(playerName)
            end
            -- LC en chaine contamine : demande active aux pairs du canal (protocole CR/CA).
            -- Sans ca, les joueurs distants jamais vus localement restent en UNKNOWN a vie.
            self:MaybeRequestMissingClass(playerName)
        end
    end
    if localeClaimVerified and Overlord.Leaderboard.SetPlayerLocale then
        Overlord.Leaderboard:SetPlayerLocale(playerName, locTag)
    end

    for _, zoneId in ipairs(verifiedZones) do
        local lb = Overlord.Leaderboard
        if not lb.captures[playerName] then lb.captures[playerName] = {} end
        local found = false
        for _, z in ipairs(lb.captures[playerName]) do
            if z == zoneId then found = true; break end
        end
        if not found then
            table.insert(lb.captures[playerName], zoneId)
            lb:MarkDirty()
        end
    end
    Overlord.Leaderboard:SetPlayerCaptureCount(playerName, sanitizedCap, true)
    if sanitizedCap > (tonumber(previousCaptureTotal) or 0)
        and self.MarkFreshCaptureLeaderboardRow then
        self:MarkFreshCaptureLeaderboardRow(playerName)
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end
    return true
end


-- ==================== Changement de groupe ====================

function Overlord.Sync:OnGroupChanged()
    cachedGroupStamp = -10
    if Overlord.Shard then
        Overlord.Shard._gkPromptPeerRevision =
            (tonumber(Overlord.Shard._gkPromptPeerRevision) or 0) + 1
    end
    if not Overlord.IsInitialized then return end
    local inGroupNow = IsInGroup() and true or false
    local joinedGroupNow = priv.groupSyncStatePrimed
        and inGroupNow and not priv.wasGroupedForSync
    priv.groupSyncStatePrimed = true
    priv.wasGroupedForSync = inGroupNow
    if joinedGroupNow then priv.groupJoinCatchUpPending = true end
    -- En instance (BG, arene, donjon) : ne rien faire. GROUP_ROSTER_UPDATE peut arriver
    -- avant PLAYER_ENTERING_WORLD ou via des C_Timer en vol planifies avant la suspension.
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local okInst, _, instType = pcall(GetInstanceInfo)
    if okInst and instType and instType ~= "none" and instType ~= "" then return end

    -- Scanne les infos classe/faction des membres du groupe.
    -- Coalesce : GROUP_ROSTER_UPDATE arrive en rafale (formation/dissolution de raid) ;
    -- un seul scan differe de 2 s par rafale au lieu d'un scan O(40) par event.
    if not self._rosterScanPending then
        self._rosterScanPending = true
        C_Timer.After(2, function()
            local sync = Overlord.Sync
            if sync then sync._rosterScanPending = false end
            if Overlord.InstanceSuspended or IsInInstance() then return end
            if Overlord.Leaderboard and Overlord.Leaderboard.ScanRaidInfo then
                Overlord.Leaderboard:ScanRaidInfo()
            end
        end)
    end

    -- Une mutation du roster est observee par les 40 clients. Toutes les demandes
    -- automatiques restent territoriales ; en raid massif, les membres deja presents
    -- passent par l'election partagee et seul le nouveau membre fait une relance directe.
    local canSend = self:GetChannelId() or IsInRaid() or IsInGroup()
    if canSend and not pendingSync then
        pendingSync = true
        C_Timer.After(3, function()
            pendingSync = false
            if Overlord.InstanceSuspended then return end
            local sync = Overlord.Sync
            if not sync then return end
            local joinCatchUp = priv.groupJoinCatchUpPending
            priv.groupJoinCatchUpPending = false
            if sync.IsLargeEvent and sync:IsLargeEvent() and not joinCatchUp then
                if sync.ScheduleActivePeriodicCatchUp then
                    sync:ScheduleActivePeriodicCatchUp()
                end
            else
                sync:SendSyncRequest()
            end
        end)
    end

    -- Le rattrapage direct appartient uniquement au nouveau membre. Les membres deja
    -- presents ne doivent pas chacun creer une reponse territoriale a chaque mutation.
    if joinedGroupNow and Overlord.InActiveFront
        and self.IsLargeEvent and self:IsLargeEvent() and IsInGroup() then
        C_Timer.After(5, function()
            if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
            if Overlord.Sync and Overlord.Sync.RequestRaidLeaderboardCatchUp then
                Overlord.Sync:RequestRaidLeaderboardCatchUp()
            end
        end)
    end
end

-- ==================== Broadcasts sortants ====================

-- Throttle : max 1 broadcast kill (agrege le dernier total). 4s en event massif, 2s sinon.
-- BNet kills : throttle a 10s (evite 10 msgs BNet toutes les 2s pendant le combat)
local killBroadcastPending = false
local killBroadcastData = nil
local lastBNetKillBroadcast = 0

-- Emission K : en event massif, garder le groupe et ajouter le canal budgete.
-- K transporte un total absolu, donc les doublons sont absorbes par SetPlayerKills(max).
function Overlord.Sync:SendKillBroadcast(payload)
    if not payload or payload == "" then return end
    if Overlord.BetaNetworkEnabled ~= false and Overlord.BetaNetwork then
        Overlord.BetaNetwork:Broadcast("K", payload)
    end
    local msg = "K:" .. payload
    if self:IsLargeEvent() then
        local raidOk = IsInRaid() and UnitInRaid("player")
            and (not self._instanceResumeTime or GetTime() - self._instanceResumeTime > 5)
        if raidOk then
            securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "RAID")
        elseif IsInGroup() then
            securecall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "PARTY")
        end
        self:SendToChannel("K", payload)
        return
    end
    self:Send("K", payload)
end

-- Diffuse une race une seule fois par campagne et par valeur observee localement.
-- LR reste un message autonome : aucun octet n'est ajoute aux payloads K ou PB.
function Overlord.Sync:MaybeBroadcastObservedLeaderboardRace(
    playerName, raceFile, raceSex, observedAt)
    local _, _, epoch = GetCurrentSyncCampaignStartAndId()
    if not epoch or epoch <= 0 then return false end
    playerName = self.NormalizeContributorFullName
        and self:NormalizeContributorFullName(playerName) or playerName
    if not playerName or playerName == "" then return false end
    if not self:HasCompleteContributorIdentity(playerName)
        and not (Overlord.Leaderboard and Overlord.Leaderboard.IsLocalDisplayName
            and Overlord.Leaderboard:IsLocalDisplayName(playerName)) then
        return false
    end
    raceFile = self.NormalizeRaceFileToken and self:NormalizeRaceFileToken(raceFile)
    if not raceFile then return false end
    local sex = math.floor(tonumber(raceSex) or 0)
    if sex ~= 2 and sex ~= 3 then sex = 0 end

    if priv.observedRaceBroadcastEpoch ~= epoch then
        priv.observedRaceBroadcastEpoch = epoch
        wipe(priv.observedRaceBroadcast)
    end
    local dk = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(playerName) or playerName:lower()
    if not dk then return false end
    local signature = raceFile .. ":" .. tostring(sex)
    if priv.observedRaceBroadcast[dk] == signature then return false end

    local payload = self.BuildLeaderboardRacePayload
        and self:BuildLeaderboardRacePayload(
            playerName, raceFile, sex, epoch, observedAt)
    if not payload then return false end
    if not self.EnqueueLeaderboardRaceBroadcast then return false end
    local leaderboard = Overlord.Leaderboard
    local isOwner = leaderboard and leaderboard.IsLocalDisplayName
        and leaderboard:IsLocalDisplayName(playerName) or false
    local sendChannel = IsInGroup()
        and not (self.IsLargeEvent and self:IsLargeEvent())
    if not self:EnqueueLeaderboardRaceBroadcast(payload, isOwner, sendChannel) then
        return false
    end
    priv.observedRaceBroadcast[dk] = signature
    return true
end

function Overlord.Sync:MaybeBroadcastLeaderboardRaceBeacon()
    local _, _, epoch = GetCurrentSyncCampaignStartAndId()
    if not epoch or epoch <= 0 or lbRaceBeaconWireEpoch == epoch then return end
    local playerName = self:GetPlayerFullName()
    if not playerName or playerName == "" then return end
    local _, raceFile = UnitRace("player")
    raceFile = self.NormalizeRaceFileToken and self:NormalizeRaceFileToken(raceFile)
    if not raceFile then return end
    local sex = UnitSex("player") or 0
    lbRaceBeaconWireEpoch = epoch
    self:MaybeBroadcastObservedLeaderboardRace(playerName, raceFile, sex)
end

function Overlord.Sync:BroadcastKill(zoneId, totalKills, killScoringAtEvent,
    campaignEpochAtEvent, bucketEpochAtEvent, isPendingReplay)
    -- Hors d'un disque de capture, conserver tout de meme le front du kill.
    -- Le marqueur @frontId reste retro-compatible : les anciens clients ignoraient deja
    -- le champ zoneId dans OnReceiveKill, tandis que FrontActivity peut maintenant le resoudre.
    if (not zoneId or zoneId == "") and Overlord.InActiveFront
        and Overlord.Fronts and Overlord.Fronts.activeFrontId then
        zoneId = "@" .. Overlord.Fronts.activeFrontId
    end
    -- Figer l'eligibilite au moment du kill : le joueur peut changer de carte
    -- pendant le delai de coalescence sans que le relais large soit perdu.
    local killScoring = killScoringAtEvent
    if killScoring == nil then
        killScoring = Overlord.IsKillScoringActive and Overlord:IsKillScoringActive() or false
    end
    local _, _, currentCampaignEpoch = GetCurrentSyncCampaignStartAndId()
    local campaignEpoch = math.floor(tonumber(campaignEpochAtEvent) or currentCampaignEpoch or 0)
    local bucketEpoch = math.floor(tonumber(bucketEpochAtEvent)
        or GetLocalLeaderboardBucketEpoch() or 0)
    killBroadcastData = {
        zoneId = zoneId,
        totalKills = totalKills,
        killScoring = killScoring,
        campaignEpoch = campaignEpoch,
        bucketEpoch = bucketEpoch,
    }
    if killBroadcastPending then return end
    killBroadcastPending = true
    local delay = (self.IsLargeEvent and self:IsLargeEvent()) and TUNING.KILL_BROADCAST_INTERVAL_LARGE
        or TUNING.KILL_BROADCAST_INTERVAL
    C_Timer.After(delay, function()
        killBroadcastPending = false
        -- Une entree en instance ne doit pas perdre un kill open-world deja valide.
        -- Conserver le snapshot en memoire ; ResumePendingKillBroadcast le reprogramme
        -- une fois les transports reactives, sans rien emettre depuis l'instance.
        if Overlord.InstanceSuspended then return end
        if killBroadcastData then
            local playerName = Overlord.Sync:GetPlayerFullName()
            local _, class = UnitClass("player")
            local _, raceFile = UnitRace("player")
            local raceSex = UnitSex("player") or 0
            if Overlord.Leaderboard and Overlord.Leaderboard.SetPlayerRace and raceFile then
                Overlord.Leaderboard:SetPlayerRace(playerName, raceFile, raceSex, false)
            end
            local faction = Overlord.PlayerFaction or ""
            local d = killBroadcastData
            -- Le pending peut survivre a une instance. Ne jamais re-etiqueter un
            -- total de la semaine precedente avec l'epoch du nouveau bucket.
            local _, _, currentEpoch = GetCurrentSyncCampaignStartAndId()
            local currentBucketEpoch = GetLocalLeaderboardBucketEpoch()
            if not CampaignEpochsMatch(d.campaignEpoch, currentEpoch)
                or not CampaignEpochsMatch(d.bucketEpoch, currentBucketEpoch) then
                killBroadcastData = nil
                return
            end
            -- Relire le total autoritaire actuel evite une valeur perimee si d'autres
            -- kills de la meme campagne ont ete fusionnes pendant le delai.
            local totalKills = (Overlord.Leaderboard and Overlord.Leaderboard.kills
                and Overlord.Leaderboard.kills[playerName]) or d.totalKills
            local locTag = (Overlord.GetClientLocaleTag and Overlord:GetClientLocaleTag()) or ""
            local guildTag = Overlord.SafeGetGuildInfo and (Overlord:SafeGetGuildInfo("player") or "") or ""
            local guildAt = time()
            local playerLevel = Overlord.SafeUnitLevel
                and (Overlord:SafeUnitLevel("player") or 0) or 0
            if Overlord.Leaderboard and Overlord.Leaderboard.SetPlayerLevel then
                Overlord.Leaderboard:SetPlayerLevel(playerName, playerLevel)
            end
            local payload = Overlord.Sync.BuildKillBroadcastPayload
                and Overlord.Sync:BuildKillBroadcastPayload(
                    playerName, d.zoneId, totalKills, class or "", faction, d.campaignEpoch,
                    guildTag, locTag, guildAt, d.bucketEpoch, playerLevel)
            if not payload then killBroadcastData = nil; return end
            local isLarge = Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
            Overlord.Sync:SendKillBroadcast(payload)
            Overlord.Sync:MaybeBroadcastLeaderboardRaceBeacon()
            -- Canal : doublon cross-faction hors event massif (large gere dans SendKillBroadcast).
            if not isLarge and (IsInRaid() or IsInGroup()) then
                Overlord.Sync:SendToChannel("K", payload)
            end
            if d.killScoring and not isLarge then
                local now = GetTime()
                if now - lastBNetKillBroadcast >= TUNING.BNET_KILL_INTERVAL then
                    lastBNetKillBroadcast = now
                    Overlord.Sync:SendToBNetFriends("K", payload)
                end
                -- Petit comité cross-faction/cross-realm : le canal/raid ne suffit pas toujours.
                -- K est un total absolu (SetPlayerKills prend le max), donc les doublons sont sûrs.
                if Overlord.Sync.BroadcastToCommunity then
                    Overlord.Sync:BroadcastToCommunity("K", payload, 12, 0.35)
                end
            end
            killBroadcastData = nil
        end
    end)
end

function Overlord.Sync:ResumePendingKillBroadcast()
    if Overlord.InstanceSuspended or killBroadcastPending or not killBroadcastData then return end
    local d = killBroadcastData
    self:BroadcastKill(d.zoneId, d.totalKills, d.killScoring,
        d.campaignEpoch, d.bucketEpoch, true)
end

function Overlord.Sync:BroadcastCaptureBarrier(
    zone, mode, originName, waveId, originGuid, requirement,
    defenderGuidOverride, whisperTarget)
    if not zone or not zone.id or not originName or originName == ""
        or (mode ~= "P" and mode ~= "A" and mode ~= "C")
        or not waveId or waveId == "" or not originGuid or originGuid == ""
        or type(UnitGUID) ~= "function" then return false end
    local defenderGuid = defenderGuidOverride or UnitGUID("player")
    if not defenderGuid or defenderGuid == "" then return false end
    local payload = table.concat({
        zone.id, mode, originName, waveId, originGuid, defenderGuid,
        tostring(math.floor(tonumber(requirement) or 0)), tostring(time()),
    }, ":")
    self:SendToGroup("CB", payload)
    self:SendToChannel("CB", payload, true)
    local directTarget = whisperTarget or originName
    if self.SendWhisper then self:SendWhisper("CB", payload, directTarget) end
    if self.BroadcastToCommunity then
        self:BroadcastToCommunity("CB", payload, 12, 0.2, true)
    end
    -- Le CB est une proposition en deux phases : la Barricade n'est consommee
    -- qu'apres le ZS 180 direct du capteur. Quelques retries whisper bornes
    -- evitent donc une divergence si le premier paquet cross-faction est perdu.
    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 2.5, 5.5, 9.0 }) do
            C_Timer.After(delay, function()
                local remote = zone and zone._remoteCaptureLease
                if mode == "A" then
                    if not zone or zone._localCaptureWaveId ~= waveId
                        or zone._captureBarrierCommitted
                        or not zone._captureBarrierProposalUntil
                        or GetTime() > zone._captureBarrierProposalUntil then return end
                else
                    if not remote or remote.waveId ~= waveId
                        or not remote.barrierLocalProposal then return end
                    if mode == "P" and (remote.barrierAcknowledged
                        or (tonumber(remote.lastHold) or 0) > 20
                        or GetTime() - (remote.openedAt or GetTime()) > 30) then return end
                    if mode == "C" and not remote.barrierCommitted then return end
                end
                if Overlord.Sync and Overlord.Sync.SendWhisper then
                    Overlord.Sync:SendWhisper("CB", payload, directTarget)
                end
            end)
        end
    end
    return true
end

function Overlord.Sync:BroadcastCapture(zoneId, completedRequirement)
    -- Capture locale terminee : message final critique, ne jamais le dropper via WaitingForSync.
    -- CanStartLocalCapture bloque deja le demarrage pendant la gate initiale.
    local faction = Overlord.PlayerFaction or ""
    local fullName = self:GetPlayerFullName()
    if not fullName or fullName == "" then return end
    local _, cls = UnitClass("player")
    local triggerField = fullName
    if cls and self:IsValidCaptureClassToken(cls) then
        triggerField = fullName .. "|" .. cls
    end

    local zone = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
    local ts = math.floor(tonumber(zone and zone.capturedTime) or time())
    local waveId = zone and Overlord.CaptureLease and Overlord.CaptureLease.GetWaveId
        and Overlord.CaptureLease:GetWaveId(zone) or ""
    local originGuid = type(UnitGUID) == "function" and UnitGUID("player") or ""
    local finalRequirement = Overlord.CaptureLease
        and Overlord.CaptureLease.NormalizeCaptureRequirement
        and Overlord.CaptureLease:NormalizeCaptureRequirement(
            zone, faction, completedRequirement) or nil
    if not finalRequirement then return end
    if zone and waveId ~= "" and originGuid ~= "" then
        zone._lastCaptureFinalWaveId = waveId
        zone._lastCaptureFinalOrigin = fullName
        zone._lastCaptureFinalGuid = originGuid
        zone._lastCaptureFinalRequired = finalRequirement
        zone._lastCaptureFinalAt = GetTime()
    end
    local payload = zoneId .. ":" .. triggerField .. ":" .. faction .. ":" .. ts
        .. ":" .. tostring(waveId or "") .. ":" .. tostring(originGuid or "")
        .. ":" .. tostring(finalRequirement)
    -- Secours ultra-rare : noms tres longs + royaume
    if #payload > (self.MAX_CAPTURE_PAYLOAD_BYTES or 250) then
        payload = zoneId .. ":" .. fullName .. ":" .. faction .. ":" .. ts
            .. ":" .. tostring(waveId or "") .. ":" .. tostring(originGuid or "")
            .. ":" .. tostring(finalRequirement)
    end
    if #payload > (self.MAX_CAPTURE_PAYLOAD_BYTES or 250) then return end
    if self.MarkFreshCaptureLeaderboardRow then
        self:MarkFreshCaptureLeaderboardRow(fullName)
    end

    -- En 40v40, C est critique : canal, communaute complete et amis BNet directs.
    -- Un bridge indirect n'est pas une preuve d'identite capteur et ne transporte pas C.
    local largeEvent = self:IsLargeEvent()
    local wideCaptureRelay = true

    local function sendCapturePayload()
        self:SendToGroup("C", payload)
        -- Toujours envoyer au canal en plus (le "C" est critique et rare : 1x par capture).
        -- SendToGroup reste strictement PARTY/RAID : un joueur solo ne duplique donc
        -- plus le meme C deux fois de suite sur CHANNEL.
        self:SendToChannel("C", payload, true)
        -- Les temoins temporels doivent recevoir le C riche avant leur ZS final :
        -- c'est lui qui credite ensuite le classement, pas le simple overlay.
        if self.SendCaptureFinalToNetworkWitnesses then
            self:SendCaptureFinalToNetworkWitnesses(
                zoneId, waveId, originGuid, payload)
        end
        if Overlord.InActiveFront and wideCaptureRelay then
            if SYNC_USE_BNET_OUTBOUND then
                self:SendToBNetFriends("C", payload)
            end
            if self.BroadcastToCommunity then
                -- C est un terminal rare : chaque membre communautaire en ligne
                -- doit recevoir la copie directe du capteur, y compris en gros event.
                -- La pompe coalesce les retries par cible+zone et garde le debit borne.
                local maxCommunity = 200
                local whisperDelay = largeEvent and 0.20 or 0.18
                self:BroadcastToCommunity("C", payload, maxCommunity, whisperDelay, true)
            end
        end
    end

    local function retryCaptureToCommunity()
        -- Retry capitale leger : la premiere vague couvre deja canal/BNet/bridge.
        -- Les reprises communaute ameliorent la couverture cross-faction sans refaire le fan-out complet.
        if not Overlord.InActiveFront or not self.BroadcastToCommunity then return end
        local maxCommunity = largeEvent and 40 or 80
        local whisperDelay = largeEvent and 0.35 or 0.25
        self:BroadcastToCommunity("C", payload, maxCommunity, whisperDelay, true)
    end

    sendCapturePayload()

    local function retryFinalCaptureState()
        local z = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
        if not z or z.owner ~= faction then return end
        if not Overlord.Zones:IsNetworkConfirmedCapture(z) then return end
        if Overlord.InstanceSuspended or not Overlord.Sync then return end
        -- Rejoue seulement les chemins critiques + ZS final. Pas de fan-out communaute/BNet supplementaire.
        self:SendToGroup("C", payload)
        self:SendToChannel("C", payload, true)
        self:BroadcastZoneState(z, true, true)
    end
    if Overlord.InActiveFront then
        -- Filet anti-orange 00:00 : deux retries rares apres une vraie capture locale.
        -- Garde ci-dessus empeche de republier un etat stale si la zone a deja ete retag.
        C_Timer.After(2.5, retryFinalCaptureState)
        C_Timer.After(6, retryFinalCaptureState)

        -- Relais communaute retarde (toutes zones) : cross-realm/RP sans C recu au premier envoi.
        C_Timer.After(1.5, function()
            if not Overlord.InstanceSuspended and Overlord.Sync then
                retryCaptureToCommunity()
            end
        end)
        if zone and zone.isCapital then
            C_Timer.After(4, function()
                if not Overlord.InstanceSuspended and Overlord.Sync then
                    retryCaptureToCommunity()
                end
            end)
        end
    end

    if Overlord.InActiveFront then
        -- Propage immediatement la capture aux membres de la communaute (cross-realm, cross-faction).
        -- Sans ca, un joueur qui n'est ni dans le meme groupe ni ami BNet avec le capteur
        -- n'apprend la capture qu'au prochain scan communaute periodique (120s de retard).
        -- Le SR garde son role de rattrapage ZA/LK/LC/DM pour les joueurs encore incomplets.
        C_Timer.After(2, function()
            if not Overlord.InstanceSuspended and Overlord.InActiveFront and Overlord.Sync then
                local nowScan = GetTime()
                local scanCooldown = largeEvent and 30 or 12
                if not Overlord.Sync._lastPostCaptureCommunityScan
                    or nowScan - Overlord.Sync._lastPostCaptureCommunityScan >= scanCooldown then
                    Overlord.Sync._lastPostCaptureCommunityScan = nowScan
                    Overlord.Sync:ScanCommunityMembers(true)
                end
            end
        end)
    end
end

-- priv.totalVictoryAnnounced : table priv (debut de fichier)

-- Check de victoire totale apres reception d'une capture/ZS par sync.
-- Appele depuis OnReceiveCapture et OnReceiveZoneState quand une zone passe en "captured".
-- Condition requise : la capitale ennemie doit etre capturee par notre faction (ou la notre
-- par l'ennemi pour la victoire adverse). GetCapturedCount() >= total seul est insuffisant :
-- les SavedVariables d'une session precedente peuvent corrompre le comptage.
function Overlord.Sync:CheckTotalVictoryFromSync()
    -- TV-1 : ne jamais afficher l'ecran hors front (sync passive en ville, donjon, etc.)
    if not Overlord.InActiveFront then return end

    local pf = Overlord.PlayerFaction
    local ef = Overlord.Zones:GetEnemyFaction()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local frontId = front and front.id
    if not frontId or priv.totalVictoryAnnounced[frontId] then return end

    -- Protection : ne pas ecraser une treve active (evite que la reprise de base par le perdant
    -- annule la treve de 15 min en cours). On ne met a jour que si pas de treve OU si c'est une
    -- nouvelle victoire de la meme faction (refresh du timer).
    local currentTruce, _, currentWinner = Overlord.Zones:IsOnVictoryCooldown(frontId)
    local function GetVictoryCaptureTimestamp(winningFaction)
        local capId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
        local cap = capId and Overlord.Zones:GetZone(capId)
        local ts = tonumber(cap and cap.capturedTime) or 0
        return (ts > 0) and ts or time()
    end

    -- Victoire de notre faction : capitale ennemie capturee (owner + capturedTime via LocalStateSupportsVictoryTruce).
    if Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce
        and Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, pf) then
        -- Capitale seule en sync sans TV : ne pas figer le front si le reste de la carte est encore mixte.
        if Overlord.Zones and Overlord.Zones.CountZonesNotOwnedByOnFront
            and Overlord.Zones:CountZonesNotOwnedByOnFront(frontId, pf) > 0 then
            return
        end
        local victoryTs = GetVictoryCaptureTimestamp(pf)
        if OverlordDB and (not currentTruce or currentWinner == pf) then
            Overlord.Zones:SetVictoryCooldown(frontId, pf, victoryTs)
            if Overlord.TryGrantVictoryDominationBonus then
                Overlord:TryGrantVictoryDominationBonus(frontId, pf, victoryTs, false)
            end
            MarkPostVictorySyncGuard(frontId)
        end
        if Overlord.InstanceSuspended then return end
        local factionUpper = (pf == "Horde") and L.VICTORY_FACTION_HORDE or L.VICTORY_FACTION_ALLIANCE
        if Overlord.ZoneControl and Overlord.ZoneControl.WriteLastCampaignStatsFromCurrentZones then
            Overlord.ZoneControl:WriteLastCampaignStatsFromCurrentZones(factionUpper)
        end
        if Overlord.Zones and Overlord.Zones.ForceSyncFrontToWinner then
            Overlord.Zones:ForceSyncFrontToWinner(frontId, pf, victoryTs, true)
        end
        if Overlord.UI then
            Overlord.UI:ShowVictoryScreen(factionUpper)
        end
        priv.totalVictoryAnnounced[frontId] = true
        priv.totalVictoryDeliveredAt[frontId] = victoryTs
        return
    end

    -- Victoire ennemie : notre capitale est capturee par l'ennemi
    -- (cas ou le TV broadcast n'est pas arrive mais les ZS ont converge)
    if Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce
        and Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, ef) then
        if Overlord.Zones and Overlord.Zones.CountZonesNotOwnedByOnFront
            and Overlord.Zones:CountZonesNotOwnedByOnFront(frontId, ef) > 0 then
            return
        end
        local victoryTs = GetVictoryCaptureTimestamp(ef)
        if OverlordDB and (not currentTruce or currentWinner == ef) then
            Overlord.Zones:SetVictoryCooldown(frontId, ef, victoryTs)
            if Overlord.TryGrantVictoryDominationBonus then
                Overlord:TryGrantVictoryDominationBonus(frontId, ef, victoryTs, false)
            end
            MarkPostVictorySyncGuard(frontId)
        end
        if not Overlord.InstanceSuspended then
            local factionName = (ef == "Horde") and L.VICTORY_FACTION_HORDE or L.VICTORY_FACTION_ALLIANCE
            -- Meme ecran de fin que le broadcast TV.
            if Overlord.ZoneControl and Overlord.ZoneControl.WriteLastCampaignStatsFromCurrentZones then
                Overlord.ZoneControl:WriteLastCampaignStatsFromCurrentZones(factionName)
            end
            if Overlord.Zones and Overlord.Zones.ForceSyncFrontToWinner then
                Overlord.Zones:ForceSyncFrontToWinner(frontId, ef, victoryTs, true)
            end
            Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. string.format(L.TOTAL_VICTORY_MSG, factionName))
            if Overlord.UI then
                Overlord.UI:ShowVictoryScreen(factionName)
            end
            priv.totalVictoryAnnounced[frontId] = true
            priv.totalVictoryDeliveredAt[frontId] = victoryTs
        end
    end
end

-- Reception du timestamp de treve via sync regulier (pas le broadcast TV initial).
-- Propage la treve aux joueurs qui n'etaient pas en ligne au moment de la victoire.
function Overlord.Sync:OnReceiveVictoryTimestamp(payload)
    local tsStr, frontId = strsplit(":", payload or "", 2)
    local ts = NormalizeRemoteTimestamp(tsStr) or 0
    if ts <= 0 or not OverlordDB or IsStaleCampaignTimestamp(ts) then return end

    if frontId and frontId ~= "" then
        OverlordDB.frontVictories = OverlordDB.frontVictories or {}
        local fv = OverlordDB.frontVictories[frontId]
        local frontTs = (fv and tonumber(fv.timestamp)) or 0
        if ts > frontTs then
            local fac = fv and fv.faction
            local capitalId = fac and Overlord.Fronts
                and Overlord.Fronts:GetEnemyCapitalId(fac, frontId)
            local capital = capitalId and Overlord.Fronts
                and select(1, Overlord.Fronts:GetZone(capitalId, frontId))
            local proofTs = math.floor(tonumber(capital and capital.capturedTime) or 0)
            if fac and Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce
                and Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, fac)
                and proofTs > 0 and math.abs(ts - proofTs) <= 5
                and Overlord.Zones.SetVictoryCooldown then
                Overlord.Zones:SetVictoryCooldown(frontId, fac, ts)
            end
        end
        return
    end

    -- Legacy sans front : impossible a attribuer de facon sure avec plusieurs fronts.
    return
end

-- Propage la faction gagnante avec le timestamp (message VF, apres VT dans la file SR).
-- Les clients sans handler VF ignorent le message ; VT reste numerique pur pour eux.
function Overlord.Sync:OnReceiveVictoryFaction(payload)
    if not payload or payload == "" or not OverlordDB then return end
    local tsStr, code, frontId = strsplit(":", payload, 3)
    local ts = NormalizeRemoteTimestamp(tsStr) or 0
    if ts <= 0 or IsStaleCampaignTimestamp(ts) then return end
    local fac = nil
    if code == "A" then fac = "Alliance"
    elseif code == "H" then fac = "Horde" end
    if not fac then return end

    if not frontId or frontId == "" then
        local order = Overlord.Fronts and Overlord.Fronts.Order
        if order and #order == 1 then
            frontId = order[1]
        else
            return
        end
    end

    OverlordDB.frontVictories = OverlordDB.frontVictories or {}
    local fv = OverlordDB.frontVictories[frontId]
    local frontTs = (fv and tonumber(fv.timestamp)) or 0
    if ts < frontTs - 30 then return end
    if Overlord.Zones and Overlord.Zones.SetVictoryCooldown
        and Overlord.Zones.LocalStateSupportsVictoryTruce
        and Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, fac) then
        local capitalId = Overlord.Fronts
            and Overlord.Fronts:GetEnemyCapitalId(fac, frontId)
        local capital = capitalId and Overlord.Fronts
            and select(1, Overlord.Fronts:GetZone(capitalId, frontId))
        local proofTs = math.floor(tonumber(capital and capital.capturedTime) or 0)
        if proofTs <= 0 or math.abs(ts - proofTs) > 5 then return end
        local appliedTs = (frontTs > ts) and frontTs or ts
        Overlord.Zones:SetVictoryCooldown(frontId, fac, appliedTs)
    end
end

-- Broadcast de victoire totale a TOUS les joueurs addon (meme hors front)
-- Le payload inclut les totaux ally/enemy kills du snapshot pour que les clients
-- distants puissent afficher les vraies stats de campagne sans avoir de snapshot local.
function Overlord.Sync:BroadcastTotalVictory(victoryTs, victoryBonusPayload)
    local faction = Overlord.PlayerFaction or ""
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local frontId = front and front.id
    if frontId then priv.totalVictoryAnnounced[frontId] = true end
    MarkPostVictorySyncGuard(frontId)
    local snap = OverlordDB and OverlordDB.lastCampaignStats
    local allyK  = (snap and snap.allyKills)  or 0
    local enemyK = (snap and snap.enemyKills) or 0
    victoryTs = math.floor(tonumber(victoryTs) or time())
    if frontId then
        -- WoW ne reboucle pas notre propre TV. Marquer aussi la livraison locale
        -- empeche qu'un replay SR du meme timestamp recree popup + annonce.
        priv.totalVictoryDeliveredAt[frontId] = math.max(
            tonumber(priv.totalVictoryDeliveredAt[frontId]) or 0, victoryTs)
    end
    local payload = faction .. ":" .. victoryTs .. ":" .. allyK .. ":" .. enemyK .. ":" .. (frontId or "")
    self:SendToGroup("TV", payload)
    self:SendToChannel("TV", payload, true)
    if victoryBonusPayload and victoryBonusPayload ~= "" then
        self:SendToGroup("VB", victoryBonusPayload)
        self:SendToChannel("VB", victoryBonusPayload, true)
    end
    self:SendToBNetFriends("TV", payload)
    self:RelayToEnemyBridge("TV", payload)
    if self.BroadcastToCommunity then
        local largeEvent = self:IsLargeEvent()
        local maxCommunity = largeEvent and 20 or 40
        local whisperDelay = largeEvent and 0.35 or 0.25
        local victoryExtras
        if victoryBonusPayload and victoryBonusPayload ~= "" then
            victoryExtras = { { type = "VB", payload = victoryBonusPayload } }
        end
        -- Meme destinataire, ordre garanti TV puis VB : la preuve de victoire existe
        -- avant l'application du bonus, y compris cross-faction par communaute.
        self:BroadcastToCommunity(
            "TV", payload, maxCommunity, whisperDelay, true, victoryExtras)
        if OverlordDB and OverlordDB.frontVictories then
            for fid, victory in pairs(OverlordDB.frontVictories) do
                local vts = tonumber(victory.timestamp) or 0
                local vf = victory.faction
                local vfCode = (vf == "Alliance") and "A" or (vf == "Horde") and "H" or ""
                if vts > 0 and vfCode ~= "" and not IsStaleCampaignTimestamp(vts) then
                    self:BroadcastToCommunity("VT", tostring(vts) .. ":" .. fid, maxCommunity, whisperDelay)
                    self:BroadcastToCommunity("VF", vts .. ":" .. vfCode .. ":" .. fid, maxCommunity, whisperDelay)
                end
            end
        end
    end
end

function Overlord.Sync:BuildTotalVictoryReplayPayload(frontId, victory)
    if not frontId or frontId == "" or type(victory) ~= "table" then return nil end
    local faction = victory.faction
    local victoryTs = math.floor(tonumber(victory.timestamp) or 0)
    if (faction ~= "Alliance" and faction ~= "Horde") or victoryTs <= 0 then return nil end
    local now = time()
    if now - victoryTs > 7200 or victoryTs > now + MAX_CLOCK_SKEW
        or IsStaleCampaignTimestamp(victoryTs) then return nil end
    local allyK, enemyK = 0, 0
    local snap = OverlordDB and OverlordDB.lastCampaignStats
    if snap and snap.frontId == frontId and snap.faction == faction then
        allyK = math.max(0, math.floor(tonumber(snap.allyKills) or 0))
        enemyK = math.max(0, math.floor(tonumber(snap.enemyKills) or 0))
    end
    return table.concat({
        faction, tostring(victoryTs), tostring(allyK), tostring(enemyK), frontId,
    }, ":")
end

-- Reception d'une victoire totale distante.
-- Dans le warfront actif : ecran de victoire ; sinon message chat (non intrusif).
function Overlord.Sync:OnReceiveTotalVictory(payload, sender, sourceChannel)
    if not payload then return end

    local faction, ts, allyKStr, enemyKStr, frontId = strsplit(":", payload)
    local rawVictoryTs = tonumber(ts)
    local normalizedVictoryTs = rawVictoryTs and NormalizeRemoteTimestamp(rawVictoryTs)
    if not normalizedVictoryTs then return end
    -- La treve utilise le temps local normalise ; la preuve VB conserve en parallele
    -- le timestamp emetteur exact pour lier les deux messages sans ambiguite.
    rawVictoryTs = math.floor(rawVictoryTs)
    ts = math.floor(normalizedVictoryTs)
    if not faction or faction == "" then return end
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    -- ts obligatoire : ts=0 contournait la dedup dbVts et le rejet >2h (forge / paquet casse)
    if ts <= 0 then return end

    -- Rejette les replays de sessions precedentes (> 2h)
    if time() - ts > 7200 then return end

    -- Ne PAS utiliser priv.totalVictoryAnnounced ici : Initialize() le met a true des qu'il y a eu
    -- une victoire apres le reset hebdo (evite le re-pop de l'ecran au /reload). Sans ce
    -- garde-fou par timestamp, toute TV d'une NOUVELLE victoire (autre faction ou 2e vague
    -- dans la meme semaine) etait ignoree -> desync (ex. Horde 10-0 vs Alliance encore en siege).
    local currentFront = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local currentFrontId = currentFront and currentFront.id
    if frontId == "" then frontId = nil end
    if frontId and (not Overlord.Fronts or not Overlord.Fronts:GetFront(frontId)) then return end
    local appliesToCurrentFront = (not frontId) or frontId == currentFrontId
    local proofFrontId = frontId or currentFrontId
    local deliveredTs = proofFrontId
        and math.floor(tonumber(priv.totalVictoryDeliveredAt[proofFrontId]) or 0) or 0
    if deliveredTs > 0 and math.abs(ts - deliveredTs) <= 5 then return end
    local truceResetEpoch = proofFrontId and OverlordDB
        and OverlordDB.frontTruceResetEpoch
        and tonumber(OverlordDB.frontTruceResetEpoch[proofFrontId]) or 0
    -- Une TV de l'ancienne victoire ne peut jamais repeindre le front apres le FR.
    if truceResetEpoch > 0 and ts < truceResetEpoch then return end
    -- Deja livre pour l'ere courante : ignore chat + rejoue d'etat (anti-spam timestamps).
    if deliveredTs > 0 and deliveredTs >= truceResetEpoch then
        return
    end
    local frontVictory = proofFrontId and OverlordDB and OverlordDB.frontVictories
        and OverlordDB.frontVictories[proofFrontId]
    local dbVts = (frontVictory and frontVictory.timestamp) or 0
    -- Comparaison avec tolerance de 30s : si le C est arrive avant le TV, CheckTotalVictoryFromSync
    -- a pu setter dbVts = time() local (quelques secondes apres l'emission du TV par l'emetteur).
    -- Sans tolerance, ts < dbVts rejette le TV -> l'ecran de victoire n'est jamais affiche pour
    -- les joueurs qui ont recu le C en premier (race condition reseau C+TV).
    -- Les vrais replays sont deja filtres par la check "> 2h" ci-dessus.
    if ts < dbVts - 30 then return end

    local localVictoryEvidence = proofFrontId and Overlord.Zones
        and Overlord.Zones.LocalStateSupportsVictoryTruce
        and Overlord.Zones:LocalStateSupportsVictoryTruce(proofFrontId, faction)
    if localVictoryEvidence and Overlord.Fronts and Overlord.Zones then
        local capitalId = Overlord.Fronts:GetEnemyCapitalId(faction, proofFrontId)
        local capital = capitalId and select(1, Overlord.Fronts:GetZone(capitalId, proofFrontId))
        local localProofTs = math.floor(tonumber(capital and capital.capturedTime) or 0)
        if localProofTs <= 0 or math.abs(ts - localProofTs) > 5 then
            localVictoryEvidence = false
        end
    end
    local trustedVictorySource = self.IsDominationChannelSenderVerified
        and self:IsDominationChannelSenderVerified(sender or "") or false
    -- La carte locale reste la preuve la plus forte. A defaut, une source
    -- groupe/communaute authentifiee applique TV immediatement ; un vote de trois
    -- paquets dependait du chemin reseau propre a chaque client.
    if not localVictoryEvidence and not trustedVictorySource then return end
    if Overlord.WaitingForSync then Overlord.WaitingForSync = nil end

    -- NOTE : l'ancien check "toutes les zones doivent etre a faction" a ete retire.
    -- Il creait un deadlock : ZA anti-cascade bloquait les 9+ changements post-victoire
    -- -> TV rejete car zones locales pas synced -> Horde reste bloquee sur l'etat de combat.
    -- On fait confiance au TV (emis uniquement apres verif complete cote emetteur).

    if not appliesToCurrentFront then
        if OverlordDB and Overlord.Zones and Overlord.Zones.SetVictoryCooldown and frontId then
            -- Une TV attestee est aussi un etat territorial terminal pour un
            -- front inactif. Ne poser que la treve laissait sa carte ancienne.
            if Overlord.Zones.ForceSyncFrontToWinner then
                Overlord.Zones:ForceSyncFrontToWinner(frontId, faction, ts, true)
            end
            Overlord.Zones:SetVictoryCooldown(frontId, faction, ts)
            if self.RecordVictoryBonusTransportEvidence then
                self:RecordVictoryBonusTransportEvidence(
                    frontId, faction, rawVictoryTs, sender, sourceChannel)
            end
            if Overlord.TryGrantVictoryDominationBonus then
                Overlord:TryGrantVictoryDominationBonus(frontId, faction, ts, false)
            end
        end
        local factionName = (faction == "Horde")
            and L.VICTORY_FACTION_HORDE or L.VICTORY_FACTION_ALLIANCE
        Overlord:PrintNotification(
            "|cFFFFD100[Overlord]|r " .. string.format(L.TOTAL_VICTORY_MSG, factionName))
        -- Ne verrouiller l'anti-replay qu'apres tous les effets territoriaux.
        -- Une erreur Lua transitoire laisse ainsi le prochain TV retenter la livraison.
        if proofFrontId then priv.totalVictoryDeliveredAt[proofFrontId] = ts end
        return
    end

    if currentFrontId then priv.totalVictoryAnnounced[currentFrontId] = true end
    if frontId then
        MarkPostVictorySyncGuard(frontId)
    elseif currentFrontId then
        MarkPostVictorySyncGuard(currentFrontId)
    end

    -- Snapshot AVANT reset : capture les kills de cette campagne pour l'ecran de victoire.
    -- Doit etre fait avant le reset des zones ci-dessous.
    local factionUpper = (faction == "Horde") and L.VICTORY_FACTION_HORDE or L.VICTORY_FACTION_ALLIANCE
    local preResetSnap = Overlord.ZoneControl and Overlord.ZoneControl.BuildCampaignKillSnapshot
        and Overlord.ZoneControl:BuildCampaignKillSnapshot(factionUpper)
    local localZonesSnapshot = (preResetSnap and preResetSnap.zones) or {}
    local localAllyKills = (preResetSnap and preResetSnap.allyKills) or 0
    local localEnemyKills = (preResetSnap and preResetSnap.enemyKills) or 0
    local localTotalKills = (preResetSnap and preResetSnap.totalKills) or 0

    -- Enregistre le timestamp et la faction gagnante avant le refresh issu du force-sync.
    if OverlordDB then
        if Overlord.Zones and Overlord.Zones.SetVictoryCooldown then
            Overlord.Zones:SetVictoryCooldown(currentFrontId, faction, ts)
        end
        if self.RecordVictoryBonusTransportEvidence then
            self:RecordVictoryBonusTransportEvidence(
                currentFrontId or frontId, faction, rawVictoryTs, sender, sourceChannel)
        end
        if Overlord.TryGrantVictoryDominationBonus then
            local grantFrontId = currentFrontId or frontId
            Overlord:TryGrantVictoryDominationBonus(grantFrontId, faction, ts, false)
        end
    end

    -- Force-sync : met toutes les zones au proprietaire gagnant.
    -- Necessaire pour le joueur qui a rate le ZA/ZS post-victoire (ex. deco/reco, lag).
    if Overlord.Zones and Overlord.Zones.ForceSyncFrontToWinner then
        Overlord.Zones:ForceSyncFrontToWinner(currentFrontId, faction, ts, true)
    end

    -- Snapshot pour l'ecran de victoire : jamais fusionner avec lastCampaignStats (meme campaignId
    -- = toute la semaine ; math.max introduisait des kills d'un autre front ou d'une victoire precedente).
    -- Totaux : paquet TV (snapshot emetteur au moment du reset) si non nuls, sinon somme locale.
    -- Lignes par zone : toujours la copie locale avant reset (pas de reutilisation d'un vieux snapshot).
    if OverlordDB then
        -- Meme plafond que ZS (MAX_SYNC_KILLS) : TV vehicule un total agrege auto-declare par
        -- l'emetteur, sans autre controle en aval (affichage direct sur l'ecran de victoire).
        local allyK  = math.min(tonumber(allyKStr)  or 0, TUNING.MAX_SYNC_KILLS)
        local enemyK = math.min(tonumber(enemyKStr) or 0, TUNING.MAX_SYNC_KILLS)
        local useAlly, useEnemy = allyK, enemyK
        if useAlly + useEnemy <= 0 then
            useAlly, useEnemy = localAllyKills, localEnemyKills
        end
        local snapFrontId = (frontId and frontId ~= "") and frontId or currentFrontId
        OverlordDB.lastCampaignStats = {
            faction    = faction,
            allyKills  = useAlly,
            enemyKills = useEnemy,
            totalKills = localTotalKills,
            zones      = localZonesSnapshot,
            campaignId = OverlordDB.campaignId,
            frontId    = snapFrontId,
        }
    end

    local factionName
    if faction == "Horde" then
        factionName = L.VICTORY_FACTION_HORDE
    elseif faction == "Alliance" then
        factionName = L.VICTORY_FACTION_ALLIANCE
    else
        return
    end

    if Overlord.InActiveFront then
        if Overlord.UI then
            Overlord.UI:ShowVictoryScreen(factionName)
        end
    else
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.TOTAL_VICTORY_MSG, factionName))
    end
    -- Commit de livraison en dernier : les doublons sont bloques uniquement une
    -- fois la treve, les zones et l'affichage effectivement appliques.
    if proofFrontId then priv.totalVictoryDeliveredAt[proofFrontId] = ts end
end

-- Domination hebdo (DM) : voir SyncDomination.lua

-- Envoie l'etat "en cours" d'une zone pour que les autres joueurs voient le timer (sinon seul le capteur le voit).
-- Send() utilise le canal si pas en groupe ; SendToChannel toujours (comme BroadcastCapture) pour couvrir
-- le cas ou le capteur est seul (sans groupe) mais dans le canal.
-- BNet : throttle a 15s PAR ZONE pour les ZS (evite 15 msgs toutes les 5s pendant la capture = deconnexion serveur).
-- Throttle par zone : evite que les ZS d'autres zones (captures recentes) consomment le quota de la zone active.
local lastBNetZSBroadcast = {}   -- zone.id -> GetTime() du dernier envoi BNet ZS
-- Hors gros event : fan-out communaute des fins/debuts de capture (aligne sur BroadcastCapture C).

function Overlord.Sync:BroadcastZoneState(zone, forceBNetZS, primaryOnly)
    if not zone or not zone.id then return end
    local status = zone.status or "available"
    local capturedAt = tonumber(zone.capturedTime) or 0
    if status ~= "in_progress" and zone.owner and capturedAt > 0 then
        -- Sur le reseau, une zone owned + capturedTime reste une capture confirmee
        -- (le status local available/locked ne doit jamais etre broadcast tel quel).
        status = "captured"
    end
    -- Etat final force : capture locale reelle (captured, accompagne BroadcastCapture) ou
    -- revert capteur apres echec de capture (available/captured decide par un joueur present
    -- sur le disque). Ces messages one-shot ne doivent etre bloques par aucune gate (regle dure).
    local isForcedFinalState = forceBNetZS and (status == "captured" or status == "available")
    -- Ne pas broadcaster tant qu'on attend la sync initiale ou le snapshot reseau :
    -- nos donnees locales peuvent etre stale et empoisonneraient les autres clients.
    if Overlord.WaitingForSync and not isForcedFinalState then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() and not isForcedFinalState then return end
    if status == "captured"
        and not isForcedFinalState
        and Overlord.LocalFrontAwaitingNetworkSnapshot
        and Overlord:LocalFrontAwaitingNetworkSnapshot() then
        return
    end
    local kills = zone.killsCurrent or 0
    local holdTime = math.floor(zone.holdTimeElapsed or 0)
    -- Une capture confirmee doit porter son timestamp de capture, pas "maintenant".
    -- Sinon une zone restauree avec updatedAt=0 devient faussement ultra-fraiche en ZS/ZA.
    local ua = zone.updatedAt
    local ts
    if status == "captured" and capturedAt > 0 then
        ts = capturedAt
    else
        -- En Lua, 0 est truthy : updatedAt == 0 ne doit pas produire ts=0 pour les etats non captures.
        ts = (ua and ua > 0) and ua or time()
    end
    local ownerCode = ""
    if zone.owner == "Alliance" then ownerCode = "A"
    elseif zone.owner == "Horde" then ownerCode = "H" end
    -- Ne pas envoyer un ZS qui exige un propriétaire sans owner valide.
    if (status == "captured" or status == "in_progress") and ownerCode == "" then
        return
    end
    -- holdTimeRequired (8e champ) : timer de siege capitale (480 s fixe, sync cross-client).
    -- 9e champ : notre capture (nom local) ou relais du nom ennemi (zsRelayCapturerName).
    -- 10e champ optionnel : shard du capteur (si 9e champ present).
    local siegePhase = 0
    local holdReq = math.floor(zone.holdTimeRequired or 120)
    if status == "in_progress" and zone.isCapital and zone.owner
        and Overlord.Zones and Overlord.Zones.GetCapitalSiegeHoldRequired then
        holdReq = math.floor(Overlord.Zones:GetCapitalSiegeHoldRequired(zone, zone.owner, holdReq))
        zone.holdTimeRequired = holdReq
    end
    local capturerName = ""
    local capturerShard = ""
    local recentFinalProof = status == "captured" and zone._lastCaptureFinalWaveId
        and zone._lastCaptureFinalGuid and zone._lastCaptureFinalAt
        and GetTime() - zone._lastCaptureFinalAt <= 15
    local terminalLocalWave = status == "captured"
        and (zone._localCaptureWaveId ~= nil or recentFinalProof)
    if (status == "in_progress" or terminalLocalWave) and Overlord.PlayerFaction then
        if terminalLocalWave or (zone.isHolding and zone.holdAuthorityLocal
            and zone.owner == Overlord.PlayerFaction) then
            capturerName = (recentFinalProof and zone._lastCaptureFinalOrigin)
                or self:GetPlayerFullName() or ""
            if capturerName ~= "" and Overlord.Shard and Overlord.Shard.currentShardID ~= nil then
                capturerShard = tostring(Overlord.Shard.currentShardID)
            end
        elseif zone.owner and zone.owner ~= Overlord.PlayerFaction then
            local r = zone.zsRelayCapturerName
            if r and type(r) == "string" then
                local t = r:match("^%s*(.-)%s*$") or ""
                if t ~= "" and #t >= 2 and #t <= 50 then capturerName = t end
            end
            if capturerName ~= "" and zone.zsRelayCapturerShard then
                capturerShard = tostring(zone.zsRelayCapturerShard)
            end
        end
    end
    local waveId = (status == "in_progress" or terminalLocalWave) and Overlord.CaptureLease
        and Overlord.CaptureLease.GetWaveId
        and Overlord.CaptureLease:GetWaveId(zone) or ""
    if terminalLocalWave and (not waveId or waveId == "") then
        waveId = zone._lastCaptureFinalWaveId or ""
    end
    -- Le GUID voyage aussi pendant la vague locale. Les anciens clients ignorent
    -- ce champ en in_progress ; les nouveaux peuvent ainsi lier tous les
    -- heartbeats d'un temoin reseau au meme personnage Blizzard.
    local localOriginWave = terminalLocalWave or (status == "in_progress"
        and zone.holdAuthorityLocal and zone.owner == Overlord.PlayerFaction)
    local originGuid = localOriginWave and ((recentFinalProof and zone._lastCaptureFinalGuid)
        or (type(UnitGUID) == "function" and UnitGUID("player"))) or ""
    local finalRequirement = terminalLocalWave and ((recentFinalProof
        and zone._lastCaptureFinalRequired) or holdReq) or ""
    local payload = zone.id .. ":" .. status .. ":" .. kills .. ":" .. holdTime .. ":" .. ownerCode .. ":" .. ts .. ":" .. siegePhase .. ":" .. holdReq .. ":" .. capturerName
        .. ":" .. capturerShard .. ":" .. (waveId or "") .. ":" .. tostring(originGuid or "")
        .. ":" .. tostring(finalRequirement or "")
    self:SendToGroup("ZS", payload)
    -- SendToChannel toujours (pas seulement si groupe) : aligne le comportement sur BroadcastCapture.
    -- Sans ca, un capteur solo n'envoie pas au canal -> les joueurs ennemis du meme canal ne voient rien.
    -- critical : captured (fin d'etat) et revert force vers available (fin d'echec de capture).
    self:SendToChannel("ZS", payload, status == "captured" or isForcedFinalState)
    if primaryOnly then return end
    -- BNet : throttle adaptatif par zone.
    -- En event normal : 15s entre chaque ZS BNet par zone (pas de saturation).
    -- En event massif (15+ joueurs Overlord visibles) : 60s au lieu de skip complet.
    -- Le skip complet supposait que le canal suffit pour la faction adverse, mais le canal Overlord
    -- est separe par faction en Warmode -> les ZS Horde ne parviennent jamais a l'Alliance via canal.
    -- Avec 60s : garanti qu'au moins le ZS initial (in_progress) arrive a la faction adverse via BNet.
    -- forceBNetZS : barricade - l'attaquant doit recevoir tout de suite le timer a 4 min.
    -- On utilise la communaute (cross-realm, cross-faction) EN PREMIER car c'est le canal
    -- le plus fiable et le plus large. BNet couvre les amis que la communaute ne touche pas.
    if Overlord.InActiveFront then
        if forceBNetZS then
            -- Barricade : envoi immediat communaute. Captured en event massif : echantillonne.
            local largeEvent = self:IsLargeEvent()
            local allowWideRelay = (not largeEvent) or status ~= "captured" or (math.random() <= 0.20)
            if allowWideRelay then
                local maxCommunity = largeEvent and 8 or TUNING.OBSERVER_CRITICAL_COMMUNITY_MAX
                local whisperDelay = largeEvent and 0.35 or TUNING.OBSERVER_CRITICAL_COMMUNITY_DELAY
                self:BroadcastToCommunity("ZS", payload, maxCommunity, whisperDelay)
                lastBNetZSBroadcast[zone.id] = GetTime()
                if SYNC_USE_BNET_OUTBOUND then
                    self:SendToBNetFriends("ZS", payload)
                end
            end
        else
            local now = GetTime()
            local lastForZone = lastBNetZSBroadcast[zone.id] or 0
            local largeEvent = self:IsLargeEvent()
            local wideInterval = largeEvent and 60 or TUNING.BNET_ZS_INTERVAL
            local isCaptureStart = (status == "in_progress" and holdTime <= 5)
            local isCaptureEnd = (status == "captured")
            -- Hors gros event : ZS captured immediate (pas d'attente 15s) pour l'observateur cross-faction.
            if isCaptureStart or (isCaptureEnd and not largeEvent) or now - lastForZone >= wideInterval then
                lastBNetZSBroadcast[zone.id] = now
                local maxCommunity, whisperDelay
                if largeEvent then
                    maxCommunity = 8
                    whisperDelay = 0.35
                elseif isCaptureStart or isCaptureEnd then
                    maxCommunity = TUNING.OBSERVER_CRITICAL_COMMUNITY_MAX
                    whisperDelay = TUNING.OBSERVER_CRITICAL_COMMUNITY_DELAY
                else
                    maxCommunity = nil
                    whisperDelay = nil
                end
                self:BroadcastToCommunity("ZS", payload, maxCommunity, whisperDelay)
                if SYNC_USE_BNET_OUTBOUND then
                    self:SendToBNetFriends("ZS", payload)
                end
            end
        end
    end
    -- Trois whispers maximum toutes les 15 s, vers les memes cibles pour toute la
    -- vague. Le payload W n'est jamais diffuse largement et n'ajoute aucun scan.
    if localOriginWave and self.SendCaptureNetworkWitnessHeartbeat then
        self:SendCaptureNetworkWitnessHeartbeat(
            zone, payload, status, holdTime, waveId, holdReq,
            zone.owner, capturerName, originGuid)
    end
end

-- ==================== Sync de proximite (nameplates) ====================
-- Event-driven : NAME_PLATE_UNIT_ADDED = un joueur entre en vue. SR en whisper pour sync cross-realm hors raid.
-- Messages addon invisibles. Throttle : 90s par joueur, max 5 SR/seconde (anti-burst).

local proximityBurstCount = 0
local proximityBurstTime = 0
local PROXIMITY_COOLDOWN = 90
local PROXIMITY_MAX_PER_SECOND = 3
local lastProximitySR = Overlord.Sync:NewBoundedSessionLedger(576, 0, PROXIMITY_COOLDOWN)

-- Large event : etat du rattrapage raid stocke dans priv pour conserver une marge
-- sous la limite des 200 locals du chunk Lua principal.

function Overlord.Sync:IsLargeEvent()
    local now = GetTime()
    if now - cachedIsLargeTime < IS_LARGE_CACHE_TTL then
        return cachedIsLarge
    end
    cachedIsLargeTime = now
    if IsInRaid() and GetNumGroupMembers() >= 20 then
        cachedIsLarge = true
        return true
    end
    nearbyAddonTimestamps:Prune(now, 8)
    cachedIsLarge = nearbyAddonTimestamps:HasAtLeast(now, LARGE_EVENT_THRESHOLD)
    return cachedIsLarge
end

-- Cibles whisper SR en raid : anneau du roster a partir de notre propre slot.
-- Chaque membre recoit ainsi au plus quelques demandes par vague, au lieu de concentrer
-- les reponses completes (et leurs tris O(N)) sur le chef et raid1.
local function CollectRaidSyncWhisperTargets(maxCount)
    local out = {}
    maxCount = maxCount or priv.raidLateJoinSrMaxTargets
    if not IsInGroup() then return out end
    local inRaid = IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local count = inRaid and GetNumGroupMembers() or 4
    local leaders, others = {}, {}
    local roster = {}
    local selfIndex = nil
    local sync = Overlord.Sync

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local full = sync and sync.CanonicalForeverNameFromUnit
                and sync:CanonicalForeverNameFromUnit(unit) or nil
            if full and full ~= "" then
                roster[#roster + 1] = full
                if UnitIsUnit(unit, "player") then
                    selfIndex = #roster
                elseif UnitIsGroupLeader(unit) then
                    leaders[#leaders + 1] = full
                else
                    others[#others + 1] = full
                end
            end
        end
    end

    if inRaid and selfIndex and #roster > 1 then
        local knownAddon, fallback = {}, {}
        local peerCount = #roster - 1
        local startOffset = ((tonumber(priv.raidLateJoinTargetCursor) or 0) % peerCount) + 1
        for step = 0, peerCount - 1 do
            local offset = ((startOffset + step - 1) % peerCount) + 1
            local idx = ((selfIndex + offset - 1) % #roster) + 1
            if idx ~= selfIndex then
                local full = roster[idx]
                if Overlord.Sync:IsNearbyAddonSender(full) then
                    knownAddon[#knownAddon + 1] = full
                else
                    fallback[#fallback + 1] = full
                end
            end
        end
        -- Les emetteurs addon recents sont des cibles prouvees. Le reste du roster
        -- demeure un filet de decouverte, mais son point de depart tourne a chaque vague.
        for _, list in ipairs({ knownAddon, fallback }) do
            for _, full in ipairs(list) do
                if #out >= maxCount then break end
                out[#out + 1] = full
            end
            if #out >= maxCount then break end
        end
        return out
    end

    -- Secours party ou roster raid incomplet pendant un changement de groupe.
    for _, full in ipairs(leaders) do
        if #out >= maxCount then break end
        out[#out + 1] = full
    end
    for _, full in ipairs(others) do
        if #out >= maxCount then break end
        out[#out + 1] = full
    end
    return out
end

function Overlord.Sync:ClearRaidLateJoinCatchUpPending()
    priv.raidLateJoinCatchUpPending = false
    priv.raidLateJoinForceNext = false
    priv.raidLateJoinFollowUpTarget = nil
    wipe(priv.raidLateJoinExpectedResponders)
end

function Overlord.Sync:MarkRaidLateJoinCatchUpPending()
    priv.raidLateJoinCatchUpPending = true
    priv.raidLateJoinForceNext = true
end

-- Une page ZA en whisper provenant d'une cible attendue constitue l'ACK du dump SR.
-- Le simple succes syntaxique de SendAddonMessage ne ferme plus le rattrapage.
function Overlord.Sync:NoteRaidLateJoinCatchUpResponse(sender, msgType, channel, payload)
    if (channel ~= "WHISPER" and not (channel == "BETA" and Overlord.BetaNetwork and Overlord.BetaNetwork:IsTargetedDispatch())) or msgType ~= "ZA" or not sender or sender == "" then
        return false
    end
    local snapshotId, pageIndex, pageCount, body =
        tostring(payload or ""):match("^@([%w_-]+):(%d+):(%d+)|(.*)$")
    pageIndex, pageCount = tonumber(pageIndex), tonumber(pageCount)
    if not snapshotId or #snapshotId > 40
        or not pageIndex or not pageCount or pageIndex < 1
        or pageCount < 1 or pageIndex > pageCount
        or pageCount > self.ZA_SNAPSHOT_MAX_PAGES
        or #body > self.ZA_SNAPSHOT_BODY_BYTES then
        return false
    end
    local key = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(sender) or tostring(sender):lower()
    key = key and key:lower() or ""
    local expiresAt = priv.raidLateJoinExpectedResponders[key]
    if not expiresAt then return false end
    if GetTime() > expiresAt then
        priv.raidLateJoinExpectedResponders[key] = nil
        return false
    end
    priv.raidLateJoinCatchUpPending = false
    priv.raidLateJoinForceNext = false
    wipe(priv.raidLateJoinExpectedResponders)
    return true
end

-- Budget global 3 whispers / 90 s pour le rattrapage raid et sa relance.
function Overlord.Sync:TryConsumeRaidLateJoinWhisperBudget()
    local now = GetTime()
    if now - priv.raidLateJoinSrBurstStart >= priv.raidLateJoinSrBurstWindow then
        priv.raidLateJoinSrBurstStart = now
        priv.raidLateJoinSrBurstCount = 0
    end
    if priv.raidLateJoinSrBurstCount >= priv.raidLateJoinSrBurstMax then
        return false
    end
    priv.raidLateJoinSrBurstCount = priv.raidLateJoinSrBurstCount + 1
    return true
end

-- Un whisper SR vers un membre du roster (reponse garantie cote receveur).
function Overlord.Sync:SendRaidLateJoinSyncWhisper(fullName)
    if not fullName or fullName == "" then return false end
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return false end
    if not self:IsLargeEvent() then return false end
    if not IsInGroup() then return false end

    if not self:SenderIsInOurGroup(fullName) then return false end

    local now = GetTime()
    if lastProximitySR:Get(fullName, now) ~= nil then
        return false
    end
    if not lastProximitySR:CanRemember(fullName, now, false) then return false end
    if not self:TryConsumeRaidLateJoinWhisperBudget() then return false end

    if not self:SendWhisper("SR", SRPayload("T"), fullName) then return false end
    if not lastProximitySR:Remember(fullName, now, now, false) then return false end
    for key, expiresAt in pairs(priv.raidLateJoinExpectedResponders) do
        if now > (tonumber(expiresAt) or 0) then
            priv.raidLateJoinExpectedResponders[key] = nil
        end
    end
    local responderKey = self.GetCaptureContributorDedupKey
        and self:GetCaptureContributorDedupKey(fullName) or fullName:lower()
    responderKey = responderKey and responderKey:lower() or ""
    if responderKey ~= "" then
        priv.raidLateJoinExpectedResponders[responderKey] = now + 180
    end
    return true
end

-- Late joiner / entree front : demande une photo territoriale a deux voisins repartis
-- dans l'anneau du roster (whisper, pas le canal 18 %).
function Overlord.Sync:RequestRaidLeaderboardCatchUp()
    if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
    if Overlord.InstanceSuspended then return end
    if not self:IsLargeEvent() then return end
    if not IsInGroup() then return end

    local now = GetTime()
    if not priv.raidLateJoinForceNext
        and now - priv.lastRaidLateJoinSr < priv.raidLateJoinSrGlobalCooldown then
        return
    end

    local targets = CollectRaidSyncWhisperTargets(priv.raidLateJoinSrMaxTargets + 1)
    if #targets == 0 then return end
    priv.raidLateJoinTargetCursor =
        (tonumber(priv.raidLateJoinTargetCursor) or 0) + math.max(1, #targets)
    priv.raidLateJoinFollowUpTarget = targets[priv.raidLateJoinSrMaxTargets + 1]
    priv.raidLateJoinFollowUpAt = now

    local sent = 0
    for i = 1, math.min(priv.raidLateJoinSrMaxTargets, #targets) do
        local name = targets[i]
        if self:SendRaidLateJoinSyncWhisper(name) then
            sent = sent + 1
        end
    end
    if sent > 0 then
        priv.lastRaidLateJoinSr = now
        priv.raidLateJoinCatchUpPending = true
        priv.raidLateJoinForceNext = false
    end
end

-- Relance legere (entree front) : 3e membre si le budget burst le permet, sans cooldown global 90s.
function Overlord.Sync:RequestRaidLeaderboardCatchUpFollowUp()
    if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
    if Overlord.InstanceSuspended then return end
    if not self:IsLargeEvent() or not IsInGroup() then return end

    local target = priv.raidLateJoinFollowUpTarget
    if not target or GetTime() - (tonumber(priv.raidLateJoinFollowUpAt) or 0) > 30 then
        return
    end
    priv.raidLateJoinFollowUpTarget = nil
    self:SendRaidLateJoinSyncWhisper(target)
end

-- Rafraichit le classement (classe depuis nameplates) si la fenetre est ouverte - throttle 2s.
-- OnNameplateAdded persiste deja la classe de l'unite visible ; le scan global des lignes
-- leaderboard reste reserve aux lectures lourdes (UI/export) pour eviter les pics en 100v100.
local lastLbClassRefreshFromNp = 0

function Overlord.Sync:MaybeLeaderboardClassRefreshFromNameplate()
    local lbUI = Overlord.LeaderboardUI
    if not lbUI or not lbUI.IsShown or not lbUI:IsShown() then return end
    local now = GetTime()
    if now - lastLbClassRefreshFromNp < TUNING.LB_CLASS_REFRESH_FROM_NP_INTERVAL then return end
    lastLbClassRefreshFromNp = now
    -- OnNameplateAdded appelle deja SetPlayerClassFromSync pour l'unite concernee.
    -- EnrichMissingClassesFromVisibleUnits (scan O(N) kills + 40 nameplates) reste
    -- reserve au prep lourd du classement (ouverture / PrepareForHeavyRead).
    if lbUI.RequestRefresh then
        lbUI:RequestRefresh()
    elseif lbUI.RefreshIfVisible then
        lbUI:RefreshIfVisible()
    end
end

-- Traite un joueur qui vient d'apparaitre a l'ecran (nameplate)
-- Utilise GetUnitName(unit, true) pour le format cross-realm recommande par l'API WoW
-- Whisper addon = allie meme faction. Une nameplate ennemie declenche la vague SR:T elue :
-- annulation par canal partage meme-royaume, plus echantillon communautaire cross-realm borne.
-- Large event : une apparition alliee declenche au plus le rattrapage distribue du roster.
-- Hors large event : whisper allie classique (90s/joueur, hors groupe).
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Sync:OnNameplateAdded(unit)
    if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
    -- WoW 12.0.5 : ne rien faire en instance (evite taint sur tables C_Club/Unit)
    if Overlord.InstanceSuspended then return end
    -- NAME_PLATE_UNIT_ADDED concerne surtout des PNJ. Les rejeter avant IsLargeEvent
    -- evite qu'une rafale de creatures rescane la table des emetteurs addon.
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    local now = GetTime()
    lastProximitySR:Prune(now, 8)
    local isLarge = Overlord.Sync:IsLargeEvent()
    -- WoW 12.0.5 : SafeGetUnitName gere les secret values
    local rawName = Overlord:SafeGetUnitName(unit, true)
    local fullName = self:CanonicalForeverName(rawName)
    if not fullName or fullName == "" then return end
    -- Classe : tout joueur en nameplate est une unite valide - imperative pour le classement.
    local _, plateClass = UnitClass(unit)
    if plateClass and plateClass ~= "" and self:IsValidCaptureClassToken(plateClass)
        and Overlord.Leaderboard and Overlord.Leaderboard.SetPlayerClassFromSync then
        Overlord.Leaderboard:SetPlayerClassFromSync(fullName, plateClass)
    end
    local faction = UnitFactionGroup(unit)
    if faction and faction ~= "" then
        Overlord.Leaderboard:SetPlayerFaction(fullName, faction)
    end
    self:MaybeLeaderboardClassRefreshFromNameplate()
    -- Faction inconnue (unite pas encore chargee) : ne pas whisper, risque d'erreur visible
    if not faction or faction == "" then return end
    local myFaction = UnitFactionGroup("player")
    if faction ~= myFaction then
        -- Une nameplate ennemie apparait chez beaucoup de clients au meme instant.
        -- Passer par l'election territoriale partagee evite autant de SR canal completes
        -- que de joueurs presents ; un seul callback local peut rester en attente.
        local key = "enemy_sr"
        local last = lastProximitySR:Get(key, now, 20)
        if not last then
            if not lastProximitySR:Remember(key, now, now, false) then return end
            if self.ScheduleActivePeriodicCatchUp then
                self:ScheduleActivePeriodicCatchUp()
            end
        end
        return
    end

    -- Gros event : ne jamais viser directement la nameplate visible. Un tank/chef vu
    -- par tout le raid recevrait sinon des dizaines de demandes completes simultanees.
    -- Le rattrapage en anneau partage le meme cooldown global et repartit la charge.
    if isLarge then
        self:RequestRaidLeaderboardCatchUp()
        return
    end

    local now = GetTime()
    if now - proximityBurstTime >= 1 then
        proximityBurstTime = now
        proximityBurstCount = 0
    end
    if proximityBurstCount >= PROXIMITY_MAX_PER_SECOND then return end

    local myName = self:GetPlayerFullName()
    -- WoW 12.0.5 : SafeUnitName gere les secret values
    local myShortName = Overlord:SafeUnitName("player")
    -- SafeStringEquals pour comparer avec les noms potentiellement secrets
    if Overlord:SafeStringEquals(fullName, myName)
        or Overlord:SafeStringEquals(fullName, myShortName)
        or self:SenderIsInOurGroup(fullName) then return end

    local last = lastProximitySR:Get(fullName, now)
    if not last then
        if not lastProximitySR:Remember(fullName, now, now, false) then return end
        proximityBurstCount = proximityBurstCount + 1
        self:SendWhisper("SR", SRPayload("T"), fullName)
    end
end

-- Scan unique des nameplates deja visibles (quand on entre en front ou /reload sur place)
-- Etale sur 20s (0.5s par nameplate) pour eviter le burst avec 40 joueurs a proximite.
-- Ticker unique avec compteur : 1 closure par scan au lieu de 40 C_Timer.After (pression GC).
function Overlord.Sync:ProximitySync()
    if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
    if Overlord.InstanceSuspended then return end
    if self._proximityScanTicker then
        self._proximityScanTicker:Cancel()
        self._proximityScanTicker = nil
    end
    self:OnNameplateAdded("nameplate1")
    local index = 1
    self._proximityScanTicker = C_Timer.NewTicker(0.5, function()
        index = index + 1
        if not Overlord.InActiveFront or Overlord.InstanceSuspended then
            local sync = Overlord.Sync
            if sync and sync._proximityScanTicker then
                sync._proximityScanTicker:Cancel()
                sync._proximityScanTicker = nil
            end
            return
        end
        Overlord.Sync:OnNameplateAdded("nameplate" .. index)
    end, 39)
end

-- Re-scan periodique des nameplates visibles (cross-realm : pas de canal partage, on doit re-demander)
local proximityRescanTicker = nil
function Overlord.Sync:StartProximityRescan()
    if proximityRescanTicker then proximityRescanTicker:Cancel() end
    proximityRescanTicker = C_Timer.NewTicker(60, function()
        if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
        Overlord.Sync:ProximitySync()
    end)
end

function Overlord.Sync:StopProximityRescan()
    if proximityRescanTicker then
        proximityRescanTicker:Cancel()
        proximityRescanTicker = nil
    end
end

function Overlord.Sync:StartProximitySync()
    -- Event NAME_PLATE_UNIT_ADDED deja enregistre dans Initialize. Scan initial si deja en front.
    C_Timer.After(1, function()
        if Overlord.InActiveFront and not Overlord.InstanceSuspended then
            Overlord.Sync:ProximitySync()
        end
    end)
    -- Re-scan toutes les 60s pour cross-realm (Melicole-Hyjal etc : pas de canal partage)
    self:StartProximityRescan()
end

-- Broadcast ST : annonce notre band et celles qu'on peut atteindre via nos amis BNet (pour etre bridge)
function Overlord.Sync:BroadcastST()
    local now = GetTime()
    if now - lastSTBroadcast < 10 then return end
    local bands = {}
    for _, band in pairs(bnet_links) do
        bands[#bands + 1] = band
    end
    if #bands > 0 then
        local myBand = self:GetMyBand()
        local payload = myBand .. ":" .. table.concat(bands, ",")
        self:SendToChannel("ST", payload)
        lastSTBroadcast = now
    end
end

-- Election periodique sans nouveau message wire : chaque client etale son callback sur
-- la meme fenetre deterministe a partir de Nom-Royaume. Cela couvre aussi les solos et
-- groupes differents d'un meme canal de royaume ; son premier SR annule les callbacks suivants.
-- Le petit rang roster ne sert que de departage local. Si le premier client disparait,
-- le suivant emet naturellement dans la meme fenetre, bien avant la periode suivante.
function Overlord.Sync:GetActivePeriodicCatchUpElectionDelay()
    local selfName = self.GetPlayerFullName and self:GetPlayerFullName() or ""
    local function sortKey(name)
        if type(name) ~= "string" or name == "" then return "" end
        local key = self.GetCaptureContributorDedupKey
            and self:GetCaptureContributorDedupKey(name) or name:lower()
        return type(key) == "string" and key:lower() or ""
    end
    local selfKey = sortKey(selfName)
    if selfKey == "" then return 0 end

    -- Modulo premier assez grand : resolution sub-ms sur 8 s, sans bitops ni allocation.
    -- Le delai reste stable pour un personnage : les groupes/solos qui partagent le
    -- canal de royaume peuvent s'annuler. Le cross-realm reste un echantillon commu
    -- borne, pas une election universelle que le client ne pourrait pas observer.
    local hash = 0
    for i = 1, #selfKey do
        hash = (hash * 131 + (string.byte(selfKey, i) or 0)) % 2147483647
    end
    local globalDelay = (hash / 2147483647) * 8
    if not IsInGroup() then return globalDelay end

    local rank, seen = 0, { [selfKey] = true }
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and (GetNumGroupMembers() or 0) or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local key = sortKey(Overlord:SafeGetUnitName(unit, true))
            if key ~= "" and not seen[key] then
                seen[key] = true
                if key < selfKey then rank = rank + 1 end
            end
        end
    end
    -- Deux millisecondes par rang departagent un improbable hash identique dans
    -- le meme roster sans transformer un raid de 40 en attente de 14 secondes.
    return globalDelay + math.min(rank, 39) * 0.002
end

function Overlord.Sync:ScheduleActivePeriodicCatchUp()
    if not Overlord.IsInitialized or not Overlord.InActiveFront
        or Overlord.InstanceSuspended then return false end
    -- Entrée en front, ticker et nameplates peuvent demander la même vague pendant
    -- les quelques secondes de jitter. Garder un seul callback par client.
    if self._activePeriodicElectionPending then return false end
    local now = GetTime()
    local interval = tonumber(TUNING.PERIODIC_SYNC_INTERVAL) or 30
    local quietWindow = math.max(10, interval - 6)
    local lastSeen = tonumber(self._lastActivePeriodicSrAt) or 0
    if lastSeen > 0 and now - lastSeen < quietWindow then return false end

    self._activePeriodicElectionGeneration =
        (tonumber(self._activePeriodicElectionGeneration) or 0) + 1
    local generation = self._activePeriodicElectionGeneration
    local waveStartedAt = now
    local delay = self:GetActivePeriodicCatchUpElectionDelay()
    self._activePeriodicElectionPending = true
    C_Timer.After(delay, function()
        local sync = Overlord.Sync
        -- Les seules invalidations de generation sont Start/Stop ; elles effacent aussi
        -- pending avant que cet ancien callback puisse revenir.
        if not sync or generation ~= sync._activePeriodicElectionGeneration then return end
        sync._activePeriodicElectionPending = nil
        if not Overlord.IsInitialized or not Overlord.InActiveFront
            or Overlord.InstanceSuspended then return end
        -- Une SR partagee d'un rang precedent (ou d'un autre groupe du front) suffit.
        if (tonumber(sync._lastActivePeriodicSrAt) or 0) >= waveStartedAt then return end
        sync._lastActivePeriodicSrAt = GetTime()
        local large = sync.IsLargeEvent and sync:IsLargeEvent()
        -- Une seule vague communautaire, toujours territoriale. L'ancien appel
        -- ScanCommunityMembers ajoutait 3/10 SR completes (LK/GH historiques) et un
        -- second parcours roster juste apres les 12 SR:T deja emises ici.
        sync:SendSyncRequest({
            territorialOnly = true,
            allowCommunityInLargeEvent = true,
            communityMax = large and 3 or 6,
            communityDelay = large and 0.8 or 0.6,
            communityRosterMinTtl = 60,
        })
    end)
    return true
end

-- Sync periodique au canal (toutes les 30s) pour recuperer l'etat - cross-faction Alliance/Horde.
-- La SR/communaute est coalescee par les transports partages ; le snapshot ZA
-- conserve sa propre selection probabiliste existante.
local periodicSyncTicker = nil
function Overlord.Sync:StartPeriodicChannelSync()
    if periodicSyncTicker then periodicSyncTicker:Cancel() end
    self._activePeriodicElectionGeneration =
        (tonumber(self._activePeriodicElectionGeneration) or 0) + 1
    self._activePeriodicElectionPending = nil
    -- Les deux callbacks d'amorcage survivent a Cancel() du ticker. Une nouvelle
    -- entree en front doit invalider ceux de la visite precedente, meme si
    -- InActiveFront est deja redevenu true lorsqu'ils se reveillent.
    self._periodicChannelSyncGeneration = (self._periodicChannelSyncGeneration or 0) + 1
    local startupGeneration = self._periodicChannelSyncGeneration
    -- Premier SR BNet immediat a l'entree en front (le ticker attend 30s)
    -- Passe par le cooldown global pour eviter la rafale init (JoinChannel envoie aussi)
    local now = GetTime()
    if SYNC_USE_BNET_OUTBOUND then
        local bnetSRCooldown = self:IsLargeEvent() and BNET_SR_COOLDOWN_LARGE or BNET_SR_COOLDOWN
        if now - lastBNetSRBroadcast >= bnetSRCooldown then
            lastBNetSRBroadcast = now
            self:SendToBNetFriends("SR", SRPayload("T"))
        end
    end
    if SYNC_USE_BNET_OUTBOUND then
        self:BroadcastST()
    end
    -- Amorcer le cache local chez tous (validation entrante O(1)), mais n'envoyer la
    -- demande communautaire que depuis l'elu.
    C_Timer.After(10, function()
        if startupGeneration ~= self._periodicChannelSyncGeneration then return end
        if Overlord.IsInitialized and Overlord.InActiveFront
            and not Overlord.InstanceSuspended and Overlord.Sync then
            if Overlord.Sync.GetOnlineCommunityMembers then
                Overlord.Sync:GetOnlineCommunityMembers(false, 15)
            end
            Overlord.Sync:ScheduleActivePeriodicCatchUp()
        end
    end)
    C_Timer.After(12 + math.random() * 6, function()
        if startupGeneration ~= self._periodicChannelSyncGeneration then return end
        if Overlord.IsInitialized and Overlord.InActiveFront
            and not Overlord.InstanceSuspended and Overlord.Sync
            and Overlord.Sync.ScheduleControlledZoneSnapshot then
            Overlord.Sync:ScheduleControlledZoneSnapshot("active_enter", {
                cooldown = 45,
                largeElectionPct = 18,
                smallElectionPct = 100,
                jitterMin = 1.0,
                jitterMax = 4.0,
            })
        end
    end)
    periodicSyncTicker = C_Timer.NewTicker(TUNING.PERIODIC_SYNC_INTERVAL, function()
        if not Overlord.IsInitialized or not Overlord.InActiveFront then return end
        self:ScheduleActivePeriodicCatchUp()
        if self.ScheduleControlledZoneSnapshot then
            self:ScheduleControlledZoneSnapshot("active_periodic")
        end
        -- Gros event : SR whisper borne (cooldown 90 s) pour LK/LC/GY complets.
        -- Le canal reste probabiliste/minimal pour proteger le throttle Blizzard.
        if self.RequestRaidLeaderboardCatchUp then
            self:RequestRaidLeaderboardCatchUp()
        end
        -- Broadcast ST toutes les 90s si on a des liens BNet (pour etre bridge)
        local now = GetTime()
        if now - lastSTBroadcast >= BRIDGE_ST_INTERVAL then
            self:BroadcastST()
        end
        -- Purges amorties : aucune table sender/bridge complete dans le ticker.
        bridges:Prune(now, 32)
        lastSRPerSender:Prune(now, 32)
    end)
end

function Overlord.Sync:StopPeriodicChannelSync()
    self._periodicChannelSyncGeneration = (self._periodicChannelSyncGeneration or 0) + 1
    self._activePeriodicElectionGeneration =
        (tonumber(self._activePeriodicElectionGeneration) or 0) + 1
    self._activePeriodicElectionPending = nil
    if periodicSyncTicker then
        periodicSyncTicker:Cancel()
        periodicSyncTicker = nil
    end
end

-- Sync passive (hors instance) : voir SyncAux.lua

-- Coupe toute l'activite sync (events + tickers) pour les instances
function Overlord.Sync:Suspend()
    syncFrame:UnregisterAllEvents()
    syncResponseGeneration = syncResponseGeneration + 1
    syncResponseInFlight = false
    priv.syncResponseDeadline = 0
    self:StopChannelRetryLoop()
    self:StopPeriodicChannelSync()
    self:StopPassiveSync()
    self:StopProximityRescan()
    recentFrontSenders:Clear()
    wipe(priv.prereqGraceUntil)
    wipe(lastEnemyBridgeRelay)
    lastR1RelayBySender:Clear()
    -- Remet a zero les timestamps RG pour eviter un auto-accept parasite au retour
    lastRGSentWaveAt = 0
    self.lastRGSentAt = 0
end

-- Reinitialise le flag de victoire (appele depuis ResetAll pour la nouvelle campagne)
function Overlord.Sync:ResetVictoryFlag()
    wipe(priv.totalVictoryAnnounced)
    wipe(priv.totalVictoryDeliveredAt)
end

function Overlord.Sync:ResetVictoryFlagForFront(frontId)
    if frontId then
        priv.totalVictoryAnnounced[frontId] = nil
        priv.totalVictoryDeliveredAt[frontId] = nil
    end
end

-- FR : fin de treve - reset des zones du front (capitales + branches initiales).
function Overlord.Sync:BroadcastFrontTruceEndReset(frontId, resetEpoch)
    if not frontId or not resetEpoch or resetEpoch <= 0 then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local payload = frontId .. ":" .. math.floor(resetEpoch)
    self:SendToGroup("FR", payload)
    self:SendToChannel("FR", payload, true)
    if self.BroadcastToCommunity then
        self:BroadcastToCommunity("FR", payload, 12, 0.35)
    end
    self:BroadcastFrontZoneSnapshot(frontId)
end

function Overlord.Sync:BroadcastFrontZoneSnapshot(frontId)
    if not frontId or Overlord.InstanceSuspended or IsInInstance() then return end
    if Overlord.WaitingForSync then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    if Overlord.LocalFrontAwaitingNetworkSnapshot and Overlord:LocalFrontAwaitingNetworkSnapshot() then
        return
    end
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return end
    local zaPages, zaPageCount = self:BuildZoneAllSnapshotPages(front.zones, "F")
    for zaPageIndex = 1, zaPageCount do
        local data = zaPages[zaPageIndex]
        self:Send("ZA", data)
    end
    if zaPageCount > 0 and self.BroadcastZoneSnapshotPagesToCommunity then
        self:BroadcastZoneSnapshotPagesToCommunity(zaPages, 12, 0.2, true)
    end
end

function Overlord.Sync:OnReceiveFrontTruceEndReset(payload, sender, sourceChannel)
    if not payload or payload == "" then return end
    local frontId, epochStr = strsplit(":", payload, 2)
    local resetEpoch = NormalizeRemoteTimestamp(epochStr)
    if not frontId or not resetEpoch or resetEpoch <= 0 then return end
    if not Overlord.Fronts or not Overlord.Fronts:GetFront(frontId) then return end
    if IsStaleCampaignTimestamp(resetEpoch) then return end
    local locallyDerivedReset = false
    local victory = OverlordDB and OverlordDB.frontVictories
        and OverlordDB.frontVictories[frontId]
    local victoryTs = victory and math.floor(tonumber(victory.timestamp) or 0) or 0
    local victoryFaction = victory and victory.faction
    local cooldown = Overlord.Zones and Overlord.Zones.GetVictoryCooldownSeconds
        and math.floor(tonumber(Overlord.Zones:GetVictoryCooldownSeconds()) or 0) or 0
    if victoryTs > 0 and victoryFaction and cooldown > 0
        and resetEpoch == victoryTs + cooldown and resetEpoch <= time() + 5
        and Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce
        and Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, victoryFaction) then
        -- Ce FR est entierement derivable d'une victoire deja canonique locale :
        -- une voix suffit sans elargir ce qu'un sender peut inventer.
        locallyDerivedReset = true
    end
    if not locallyDerivedReset and cooldown > 0 and resetEpoch <= time() + 5
        and Overlord.Zones and Overlord.Zones.LocalStateSupportsVictoryTruce then
        -- Un late joiner peut avoir recu la carte de victoire totale mais manque
        -- VT/VF. La carte elle-meme prouve alors le meme tombstone FR : toutes les
        -- zones sont au gagnant et sa capitale ennemie porte exactement l'horloge
        -- de victoire deduite. Cela evite qu'un unique client reset reste oppose a
        -- deux anciennes cartes sans accepter un FR arbitraire a une voix.
        local inferredVictoryTs = resetEpoch - cooldown
        if inferredVictoryTs > 0 and not IsStaleCampaignTimestamp(inferredVictoryTs) then
            for _, inferredFaction in ipairs({ "Alliance", "Horde" }) do
                if Overlord.Zones:LocalStateSupportsVictoryTruce(
                    frontId, inferredFaction) then
                    local capitalId = Overlord.Fronts:GetEnemyCapitalId(
                        inferredFaction, frontId)
                    local capital = capitalId
                        and select(1, Overlord.Fronts:GetZone(capitalId, frontId))
                    local capitalTs = math.floor(
                        tonumber(capital and capital.capturedTime) or 0)
                    if capitalTs > 0
                        and math.abs(capitalTs - inferredVictoryTs) <= 5 then
                        locallyDerivedReset = true
                        break
                    end
                end
            end
        end
    end
    -- FR est destructif : sans preuve locale derivable, on ignore le paquet et
    -- on attend ZA/TV. Accumuler des votes inutilises consommait CPU/memoire et
    -- donnait l'impression qu'un quorum pouvait rendre ce reset fiable.
    if not locallyDerivedReset then return end
    if Overlord.Zones and Overlord.Zones.ApplyFrontTruceEndReset then
        Overlord.Zones:ApplyFrontTruceEndReset(frontId, resetEpoch, true)
    end
end

-- Snapshot ZA compact (owners, tous les fronts) : canal + groupe, comme DM en sync passive.
function Overlord.Sync:BroadcastCompactZoneSnapshot(opts)
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if Overlord.WaitingForSync then return end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then return end
    if Overlord.LocalFrontAwaitingNetworkSnapshot and Overlord:LocalFrontAwaitingNetworkSnapshot() then
        return
    end
    opts = opts or {}
    local sent = false
    local sendChannel = IsInGroup() or IsInRaid()
    local srZones = CollectSrResponseZones()
    local zaPages, zaPageCount = self:BuildZoneAllSnapshotPages(srZones, "G")
    for zaPageIndex = 1, zaPageCount do
        local data = zaPages[zaPageIndex]
        self:Send("ZA", data)
        if sendChannel then
            self:SendToChannel("ZA", data)
        end
        sent = true
    end
    if opts.includeCommunity and zaPageCount > 0
        and self.BroadcastZoneSnapshotPagesToCommunity then
        self:BroadcastZoneSnapshotPagesToCommunity(zaPages, 12, 0.2, true)
    end
    return sent
end

-- Apres sortie d'instance : demander l'etat reseau et pousser le notre (pas de ZS a la suspension).
function Overlord.Sync:FlushStateAfterInstance()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if Overlord.WaitingForSync then return end
    self:StartInstanceCaptureSyncBurst()
    local attempts = 0
    local function tryPushSnapshot()
        attempts = attempts + 1
        if Overlord.InstanceSuspended or not Overlord.Sync then return end
        if Overlord.WaitingForSync then return end
        -- Ne pas pousser ZA/DM tant que la gate OU le burst fiable sont actifs.
        -- Un ZA exact mais stale du groupe peut fermer la gate des le premier essai ;
        -- attendre quand meme les reponses communaute empeche de le republier.
        local burstPending = GetTime()
            < (tonumber(Overlord.Sync._instanceCaptureSyncBurstUntil) or 0)
        local gatePending = Overlord.IsCaptureSyncPending
            and Overlord:IsCaptureSyncPending()
        if burstPending or gatePending then
            if attempts < 12 then
                C_Timer.After(3, tryPushSnapshot)
            end
            return
        end
        if Overlord.Sync.ScheduleControlledZoneSnapshot then
            Overlord.Sync:ScheduleControlledZoneSnapshot("instance_exit", {
                cooldown = 30,
                largeElectionPct = 25,
                smallElectionPct = 100,
                jitterMin = 2.0,
                jitterMax = 8.0,
            })
        else
            Overlord.Sync:BroadcastCompactZoneSnapshot()
        end
        if Overlord.InActiveFront and Overlord.Sync.BroadcastDomination then
            Overlord.Sync:BroadcastDomination()
        end
    end
    C_Timer.After(2 + math.random() * 1.5, tryPushSnapshot)
end

-- Retablit la sync apres sortie d'instance
function Overlord.Sync:Resume()
    -- Grace RAID : si IsInRaid() reste vrai alors que la couche RAID n'est pas prête (instance -> monde),
    -- on utilise PARTY quelques secondes dans Send().
    self._instanceResumeTime = GetTime()
    syncFrame:RegisterEvent("CHAT_MSG_ADDON")
    syncFrame:RegisterEvent("BN_CHAT_MSG_ADDON")
    syncFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    -- Voir Initialize() : on evite CHAT_MSG_CHANNEL_NOTICE pour ne pas toucher
    -- a ses arguments proteges pendant les transitions d'instance.
    syncFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    self:JoinChannel()
    self:StartChannelRetryLoop()
    self:StartProximitySync()
    self:StartPassiveSync()
    self:ResumePendingKillBroadcast()
end

-- Mines (MS/MN), forets (WS), whispers communaute, appel de faction (FC), sync passive : voir SyncAux.lua
-- Domination hebdo (DM) : voir SyncDomination.lua
-- Guild Keep (GK / GC / WB) : voir SyncGuildKeep.lua
