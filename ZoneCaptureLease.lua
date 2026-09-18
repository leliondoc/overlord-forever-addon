-- ZoneCaptureLease.lua : bail ephemere pour les captures ZS distantes.
--
-- Un ZS in_progress est une vue reseau, pas un etat confirme. On garde donc
-- l'etat materialise pour l'UI, mais on conserve un snapshot stable qui seul
-- peut etre persiste. Le bail expire localement sans fabriquer ni diffuser un
-- nouvel etat de zone.

Overlord = Overlord or {}
Overlord.CaptureLease = Overlord.CaptureLease or {}
local Lease = Overlord.CaptureLease

local SOFT_TTL = 20
local HARD_TTL = 90
local TOMBSTONE_TTL = 600
local MAX_ROWS = 512
local TOMBSTONE_PURGE_INTERVAL = 60
local LEASE_TIMER_EPSILON = 0.05
local NETWORK_PROOF_HOLD_SLACK = 8
-- Un heartbeat W part toutes les 15 s. Cinquante secondes tolerent deux pertes
-- consecutives sans assouplir la fraicheur du terminal, bornee separement.
local NETWORK_PROOF_MAX_GAP = 50
local BASE_HOLD_REQUIRED = 120

local tombstones = {}
local tombstoneCount = 0
local lastTombstonePurgeAt = 0
local activeLeaseZones = {}
local activeLeaseZoneCount = 0
local leaseMaintenanceTimer
local leaseMaintenanceDueAt = 0
local leaseMaintenanceRunning = false
local ScheduleLeaseMaintenance
local GetZoneMaintenanceDeadline
local waveSequence = 0
local CapturerVisibleOnLocalDisk

local function ZoneNeedsLeaseMaintenance(zone)
    return zone and (zone._remoteCaptureLease ~= nil
        or zone._captureBarrierProposalUntil ~= nil)
end

local function TrackLeaseZone(zone)
    if not zone or not zone.id then return end
    local wasTracked = activeLeaseZones[zone.id] ~= nil
    local needsMaintenance = ZoneNeedsLeaseMaintenance(zone)
    if needsMaintenance then
        activeLeaseZones[zone.id] = zone
        if not wasTracked then activeLeaseZoneCount = activeLeaseZoneCount + 1 end
    else
        activeLeaseZones[zone.id] = nil
        if wasTracked then activeLeaseZoneCount = math.max(0, activeLeaseZoneCount - 1) end
    end
    if ScheduleLeaseMaintenance and not leaseMaintenanceRunning then
        -- Le hotpath reseau ne rescane jamais toutes les zones. Un nouveau deadline
        -- plus proche peut avancer le timer en O(1) ; un deadline repousse laisse
        -- simplement le timer existant se reveiller un peu tot et refaire un sweep.
        if needsMaintenance then
            ScheduleLeaseMaintenance(nil, zone)
        elseif activeLeaseZoneCount == 0 then
            ScheduleLeaseMaintenance()
        end
    end
end

local SNAPSHOT_FIELDS = {
    "status", "owner", "capturedTime", "updatedAt", "killsCurrent",
    "allyKillsCurrent", "enemyKillsCurrent", "holdTimeElapsed",
    "holdTimeRequired", "previousOwner", "_assaultFromAvailable",
    "_captureFinalUnattested", "_captureFinalUnattestedOriginKey",
    "_captureFinalUnattestedWaveId", "_captureFinalUnattestedAt",
    "_captureFinalConfirmedBase",
}

local function CopySnapshot(source)
    local copy = {}
    for _, field in ipairs(SNAPSHOT_FIELDS) do copy[field] = source[field] end
    return copy
end

local function StableSnapshot(zone)
    local snapshot = CopySnapshot(zone)
    -- Migration/filet : un ancien in_progress distant peut exister sans bail.
    -- Reconstruire son dernier etat confirme au lieu de le prendre comme base.
    if snapshot.status == "in_progress" and not zone.holdAuthorityLocal then
        local previous = snapshot.previousOwner
        if not previous and Overlord.Zones and Overlord.Zones.GetBaseZoneFixedOwner then
            previous = Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
        end
        snapshot.owner = previous
        snapshot.status = previous and "captured" or "available"
        snapshot.holdTimeElapsed = 0
        -- Barricade/Renfort ne vivent que pendant une tentative. Une migration
        -- d'ancien in_progress repart toujours du requis canonique.
        snapshot.holdTimeRequired = 120
        snapshot.previousOwner = nil
        snapshot._assaultFromAvailable = nil
        snapshot.updatedAt = tonumber(snapshot.capturedTime) or 0
    end
    return snapshot
end

local function RestoreSnapshot(zone, snapshot)
    for _, field in ipairs(SNAPSHOT_FIELDS) do zone[field] = snapshot[field] end
end

local function CanonicalPlayer(name)
    local sync = Overlord.Sync
    return sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(name) or nil
end

local function IsSyntheticSender(sender)
    return type(sender) == "string"
        and (sender:match("^BNet%-%d+$") or sender:match("^Bridge%-%d+$")) ~= nil
end

local function ValidWave(raw)
    if type(raw) ~= "string" or raw == "" or #raw > 48 then return nil end
    return raw:match("^[%w_-]+$") and raw or nil
end

local function ValidPlayerGuid(raw)
    if type(raw) ~= "string" or raw == "" or #raw > 80 then return nil end
    return raw:match("^Player%-%d+%-%w+$") and raw or nil
end

local function LegacyWave(zoneId, originKey, owner, remoteTs, holdTime)
    local startedAt = math.max(0, math.floor((tonumber(remoteTs) or 0) - (tonumber(holdTime) or 0)))
    -- Les timestamps/hold sont arrondis et peuvent bouger d'une seconde selon le relais.
    startedAt = math.floor(startedAt / 15) * 15
    return "legacy_" .. tostring(startedAt),
        table.concat({ tostring(zoneId), tostring(originKey), tostring(owner), tostring(startedAt) }, "|")
end

local function LeaseKey(zoneId, originKey, waveId)
    return table.concat({ tostring(zoneId), tostring(originKey), tostring(waveId) }, "|")
end

local function PurgeBounded(store, now, ttl)
    local count = 0
    local oldestKey, oldestAt
    for key, row in pairs(store) do
        local stamp = type(row) == "table" and (row.lastSeen or row.createdAt or 0) or row
        if now - (tonumber(stamp) or 0) > ttl then
            store[key] = nil
        else
            count = count + 1
            if not oldestAt or stamp < oldestAt then oldestKey, oldestAt = key, stamp end
        end
    end
    if count >= MAX_ROWS and oldestKey then
        store[oldestKey] = nil
        count = count - 1
    end
    return count
end

local function PutTombstone(zoneId, originKey, waveId)
    if not zoneId or not originKey or not waveId then return end
    local now = GetTime()
    local key = LeaseKey(zoneId, originKey, waveId)
    if tombstones[key] == nil then tombstoneCount = tombstoneCount + 1 end
    tombstones[key] = now
    if tombstoneCount >= MAX_ROWS
        or now - lastTombstonePurgeAt >= TOMBSTONE_PURGE_INTERVAL then
        tombstoneCount = PurgeBounded(tombstones, now, TOMBSTONE_TTL)
        lastTombstonePurgeAt = now
    end
end

local function IsTombstoned(zoneId, originKey, waveId)
    local key = LeaseKey(zoneId, originKey, waveId)
    local seen = tombstones[key]
    if not seen then return false end
    if GetTime() - seen > TOMBSTONE_TTL then
        tombstones[key] = nil
        tombstoneCount = math.max(0, tombstoneCount - 1)
        return false
    end
    return true
end

local function ClearLocalWaveEphemera(zone)
    zone._captureDefensiveRequired = nil
    zone._captureDefensiveWaveId = nil
    zone._captureBarrierProposalUntil = nil
    zone._captureBarrierPreviousRequired = nil
    zone._captureBarrierDefenderKey = nil
    zone._captureBarrierDefenderGuid = nil
    zone._captureBarrierOriginGuid = nil
    zone._captureBarrierCommitted = nil
end

local function ClearTransient(zone)
    zone._observerDisplayHold = nil
    zone._observerDisplayNetworkFloor = nil
    zone._lastObserverSyncPollAt = nil
    zone._observerFinalStatePollAt = nil
    zone._observerFinalStatePollCount = nil
    zone._observerCaptureConfirmPollAt = nil
    zone._syncGateRemoteProgress = nil
    zone._syncGateRemoteProgressUntil = nil
    zone.zsOfficialCapturerName = nil
    zone._zsOfficialCapturerSeenAt = nil
    zone.zsRelayCapturerName = nil
    zone.zsRelayCapturerShard = nil
    zone.lastZSSender = nil
    zone._restoredInProgress = nil
    zone.isHolding = false
    zone.isPaused = false
    zone.isContested = false
    zone.holdAuthorityLocal = nil
    zone.holdStartTime = nil
    ClearLocalWaveEphemera(zone)
end

local function RefreshVisuals()
    if Overlord.UI and Overlord.UI.RequestRefresh then Overlord.UI:RequestRefresh() end
    if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh()
    end
end

-- Le snapshot restaure peut changer les prerequis des zones suivantes. Le
-- recalcul est differe pour ne jamais re-entrer dans invalidateInProgressCapture
-- pendant l'expiration du bail, et reste strictement local (aucun ZS fabrique).
local function ScheduleAvailabilityRefresh(zone)
    if not zone or not C_Timer or not C_Timer.After then return end
    local zoneId = zone.id
    C_Timer.After(0, function()
        if not zoneId or not Overlord.Zones then return end
        local active = Overlord.Zones.GetZone and Overlord.Zones:GetZone(zoneId)
        if active and Overlord.Zones.UpdateAvailableZones then
            Overlord.Zones:UpdateAvailableZones()
            return
        end
        local front
        if Overlord.Fronts and Overlord.Fronts.GetZone then
            local _, foundFront = Overlord.Fronts:GetZone(zoneId)
            front = foundFront
        end
        if front and Overlord.Zones.RefreshInactiveFrontAvailability then
            Overlord.Zones:RefreshInactiveFrontAvailability(front.id)
        end
    end)
end

local function TombstoneLocalWave(zone)
    if not zone or not zone.id or not zone._localCaptureWaveId then return end
    local sync = Overlord.Sync
    local localName = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
    local originKey = CanonicalPlayer(localName)
    if originKey then PutTombstone(zone.id, originKey, zone._localCaptureWaveId) end
end

local function StrategicOutpostPenaltySeconds()
    return math.max(0, math.floor(tonumber(
        Overlord.Outpost and Overlord.Outpost.ZONE_CAPTURE_PENALTY_SECONDS) or 30))
end

local function LocalStrategicCapturePenalty(zone)
    if not zone or zone.isCapital or not Overlord.Outpost
        or not Overlord.Outpost.GetZoneCapturePenaltySeconds then return 0 end
    return math.max(0, math.floor(tonumber(
        Overlord.Outpost:GetZoneCapturePenaltySeconds(
            zone, Overlord.PlayerFaction)) or 0))
end

local function NormalCaptureRequirements(penalty)
    local constants = Overlord.RessourcesConstants or {}
    local reduction = math.max(0, tonumber(constants.REINFORCE_REDUCTION) or 60)
    local minimum = math.max(30, tonumber(constants.REINFORCE_MIN_HOLD) or 30)
    local increase = math.max(0, tonumber(constants.BARRICADE_INCREASE) or 60)
    penalty = math.max(0, math.floor(tonumber(penalty) or 0))
    return math.max(minimum, BASE_HOLD_REQUIRED - reduction) + penalty,
        BASE_HOLD_REQUIRED + penalty, BASE_HOLD_REQUIRED + increase + penalty
end


local function CaptureRequirementPenaltyOffset(rawRequirement)
    local raw = math.floor(tonumber(rawRequirement) or -1)
    local penalty = StrategicOutpostPenaltySeconds()
    if penalty <= 0 then return 0 end
    local reduced, normal, extended = NormalCaptureRequirements(penalty)
    if raw == reduced or raw == normal or raw == extended then return penalty end
    return 0
end

local function IsExtendedCaptureRequirement(rawRequirement)
    local raw = math.floor(tonumber(rawRequirement) or -1)
    local _, _, baseExtended = NormalCaptureRequirements(0)
    local _, _, penalizedExtended = NormalCaptureRequirements(
        StrategicOutpostPenaltySeconds())
    return raw == baseExtended or raw == penalizedExtended
end

local function ExtendedCaptureRequirementFor(rawRequirement)
    local _, _, extended = NormalCaptureRequirements(
        CaptureRequirementPenaltyOffset(rawRequirement))
    return extended
end

local function CapitalRequirement(zone, owner)
    if not zone or not zone.isCapital or not Overlord.Zones then return nil end
    if Overlord.Zones.GetCapitalSiegeHoldRequired then
        local required = Overlord.Zones:GetCapitalSiegeHoldRequired(
            zone, owner, BASE_HOLD_REQUIRED)
        if tonumber(required) then return math.floor(tonumber(required)) end
    end
    if Overlord.Zones.GetCapitalHoldTime then
        local required = Overlord.Zones:GetCapitalHoldTime(zone)
        if tonumber(required) then return math.floor(tonumber(required)) end
    end
    return nil
end

-- Les bonus personnels ne sont pas persistants dans l'etat de zone. Sur le fil,
-- leur resultat est donc limite a trois valeurs connues ; aucune valeur libre ne
-- peut raccourcir ou allonger arbitrairement une capture. Les capitales gardent
-- leur duree canonique et n'acceptent jamais ces modificateurs.
function Lease:NormalizeCaptureRequirement(zone, owner, rawRequirement)
    local raw = tonumber(rawRequirement)
    if not raw then return nil end
    raw = math.floor(raw)
    local capital = CapitalRequirement(zone, owner)
    if capital then return raw == capital and capital or nil end
    local reduced, normal, extended = NormalCaptureRequirements(0)
    if raw == reduced or raw == normal or raw == extended then return raw end
    local strategicPenalty = StrategicOutpostPenaltySeconds()
    local penalizedReduced, penalizedNormal, penalizedExtended =
        NormalCaptureRequirements(strategicPenalty)
    if strategicPenalty > 0 and (raw == penalizedReduced
        or raw == penalizedNormal or raw == penalizedExtended) then
        return raw
    end
    return nil
end

function Lease:GetDefaultCaptureRequirement(zone, owner)
    return CapitalRequirement(zone, owner) or BASE_HOLD_REQUIRED
end

function Lease:NormalizeWaveId(raw, zoneId, originName, owner, remoteTs, holdTime)
    local valid = ValidWave(raw)
    local originKey = CanonicalPlayer(originName)
    if not originKey then return nil, nil end
    if valid then return valid end
    return LegacyWave(zoneId, originKey, owner, remoteTs, holdTime)
end

function Lease:NewWaveId()
    waveSequence = (waveSequence + 1) % 1000000
    local wall = math.max(0, math.floor(time()))
    local mono = math.max(0, math.floor(GetTime() * 1000)) % 1000000000
    return string.format("w%x_%x_%x", wall, mono, waveSequence)
end

-- Les champs d'affichage SR sont ephemeres et projetes une seule fois a la
-- reception du paquet direct du capteur.
local function ProjectObserverDisplay(hold, remoteTs, displayHold, displayAt, required, nowWall)
    -- Le requis peut manquer sur un ancien paquet de capitale. Ne pas caper ici
    -- a 120 : RebaseRemoteObserverDisplay connait ensuite le vrai requis de zone.
    local wireMax = math.max(BASE_HOLD_REQUIRED, tonumber(required) or 600)
    local raw = math.max(0, tonumber(hold) or 0)
    local remote = tonumber(remoteTs) or nowWall
    local shown = tonumber(displayHold)
    local shownAt = tonumber(displayAt)
    if shown and shownAt and shown >= 0 and shown <= wireMax
        and shownAt >= remote and shownAt <= nowWall + 5 then
        return shown + math.max(0, nowWall - shownAt)
    end
    return raw + math.max(0, nowWall - remote)
end

function Lease:RestoreLocalWave(zone, rawWave)
    local waveId = ValidWave(rawWave)
    if not zone or zone.status ~= "in_progress" or not waveId then return false end
    zone._localCaptureWaveId = waveId
    zone._localCaptureOpenedAt = GetTime() - math.max(0, tonumber(zone.holdTimeElapsed) or 0)
    zone._captureReleaseSentWave = nil
    return true
end

function Lease:BeginLocal(zone)
    if not zone then return nil end
    if zone._remoteCaptureLease then
        return self:PromoteRemoteToLocal(zone)
    end
    if not zone._localCaptureWaveId then
        ClearLocalWaveEphemera(zone)
        zone._localCaptureBase = StableSnapshot(zone)
        zone._localCaptureWaveId = self:NewWaveId()
        zone._localCaptureOpenedAt = GetTime()
        zone._captureReleaseSentWave = nil
    elseif not zone._localCaptureOpenedAt then
        zone._localCaptureOpenedAt = GetTime()
    end
    return zone._localCaptureWaveId
end

function Lease:PromoteRemoteToLocal(zone, releasedByOrigin)
    if not zone then return nil end
    local remote = zone._remoteCaptureLease
    if remote then
        -- Defense en profondeur : une entree tardive sur le disque ne peut pas
        -- tombstoner la vague authentifiee encore vivante puis repartir a zero.
        -- Seul le ZR direct de cette origine autorise une releve immediate.
        if not releasedByOrigin and remote.directValidated == true
            and GetTime() - (remote.lastDirectSeen or 0) < SOFT_TTL then
            return nil
        end
        PutTombstone(zone.id, remote.originKey, remote.waveId)
        local base = CopySnapshot(remote.base)
        zone._remoteCaptureLease = nil
        -- Toujours reconstruire depuis la base : les champs directs ephemeres
        -- ne doivent pas survivre par accident a un handoff local.
        RestoreSnapshot(zone, base)
        ClearTransient(zone)
        local previousOwner = zone.owner
        zone.previousOwner = previousOwner
        zone._assaultFromAvailable = zone.status == "available" and not previousOwner or nil
        if zone._assaultFromAvailable then zone.capturedTime = nil end
        zone.status = "in_progress"
        zone.owner = Overlord.PlayerFaction
        -- Une nouvelle origine/GUID/wave ne peut pas heriter d'une preuve
        -- temporelle. Le handoff repart a zero et restaure seulement la base.
        zone.holdTimeElapsed = 0
        zone.killsCurrent = tonumber(base.killsCurrent) or 0
        zone.holdTimeRequired = BASE_HOLD_REQUIRED
            + LocalStrategicCapturePenalty(zone)
        if zone.isCapital and Overlord.Zones then
            local fixedOwner = Overlord.Zones.GetBaseZoneFixedOwner
                and Overlord.Zones:GetBaseZoneFixedOwner(zone.id) or nil
            if fixedOwner and fixedOwner ~= Overlord.PlayerFaction
                and Overlord.Zones.GetCapitalHoldTime then
                zone.holdTimeRequired = math.max(zone.holdTimeRequired,
                    Overlord.Zones:GetCapitalHoldTime(zone))
            end
        end
        zone.updatedAt = time()
        zone.isHolding = true
        zone.isPaused = false
        zone.holdStartTime = GetTime()
        zone._localCaptureBase = base
    elseif not zone._localCaptureBase then
        zone._localCaptureBase = StableSnapshot(zone)
    end
    zone._localCaptureWaveId = self:NewWaveId()
    zone._localCaptureOpenedAt = GetTime()
    zone._captureReleaseSentWave = nil
    TrackLeaseZone(zone)
    return zone._localCaptureWaveId
end

function Lease:GetWaveId(zone)
    if not zone then return nil end
    if zone._localCaptureWaveId then return zone._localCaptureWaveId end
    local remote = zone._remoteCaptureLease
    return remote and remote.waveId or nil
end

function Lease:GetPersistableView(zone)
    local remote = zone and zone._remoteCaptureLease
    -- Seul l'overlay in_progress est ephemere. Si un chemin terminal a deja
    -- mute la zone mais n'a pas encore ferme le bail, persister le terminal
    -- plutot que ressusciter sa base.
    if remote and not zone.holdAuthorityLocal and zone.status == "in_progress" then
        return remote.base
    end
    return zone
end

local function ResolveLeaseZone(zoneId)
    local zone = Overlord.Zones and Overlord.Zones.GetZone
        and Overlord.Zones:GetZone(zoneId) or nil
    if not zone and Overlord.Fronts and Overlord.Fronts.GetZone then
        zone = select(1, Overlord.Fronts:GetZone(zoneId))
    end
    return zone
end

local function BuildCertifiedStableBase(zone, remote, ownerCode, owner, rawTs, rawCt)
    if not zone or type(remote) ~= "table" or type(remote.base) ~= "table" then return nil end
    local canonicalOwner
    if ownerCode == "A" then
        canonicalOwner = "Alliance"
    elseif ownerCode == "H" then
        canonicalOwner = "Horde"
    elseif ownerCode ~= "N" then
        return nil
    end
    if owner ~= canonicalOwner then return nil end
    if ownerCode == "N" and Overlord.Zones
        and Overlord.Zones.GetBaseZoneFixedOwner
        and Overlord.Zones:GetBaseZoneFixedOwner(zone.id) then return nil end

    local ts = math.floor(tonumber(rawTs) or 0)
    local ct = math.floor(tonumber(rawCt) or 0)
    if ts <= 0 or ct < 0 or (ct > 0 and ct ~= ts) then return nil end
    if canonicalOwner and ct <= 0 then ct = ts end
    if not canonicalOwner and ct ~= 0 then return nil end

    local base = CopySnapshot(remote.base)
    base.owner = canonicalOwner
    base.status = canonicalOwner and "captured" or "locked"
    base.capturedTime = canonicalOwner and ((ct > 0) and ct or ts) or nil
    base.updatedAt = ts
    base.holdTimeElapsed = 0
    base.holdTimeRequired = BASE_HOLD_REQUIRED
    base.previousOwner = nil
    base._assaultFromAvailable = nil
    base._captureFinalUnattested = nil
    base._captureFinalUnattestedOriginKey = nil
    base._captureFinalUnattestedWaveId = nil
    base._captureFinalUnattestedAt = nil
    base._captureFinalConfirmedBase = nil
    return base
end

-- Le wire peut etre exact grace aux canonicalisations de BuildZoneAllSnapshotPart
-- alors que le socle brut reste ancien (owner sans horloge, N:0, final visuel).
-- Un G exact doit alors remplacer uniquement ce socle, sinon ZR/expiration le
-- restaurerait sous une forme qui ne peut plus participer au prochain snapshot.
function Lease:RemoteStableNeedsCanonicalRebase(zone, ownerCode, owner, rawTs, rawCt)
    local remote = zone and zone._remoteCaptureLease
    if not remote or type(remote.base) ~= "table" then return false end
    local base = BuildCertifiedStableBase(zone, remote, ownerCode, owner, rawTs, rawCt)
    if not base then return true end
    local current = remote.base
    return current.owner ~= base.owner
        or math.floor(tonumber(current.capturedTime) or 0)
            ~= math.floor(tonumber(base.capturedTime) or 0)
        or math.floor(tonumber(current.updatedAt) or 0)
            ~= math.floor(tonumber(base.updatedAt) or 0)
        or current._captureFinalUnattested ~= nil
        or current._captureFinalUnattestedOriginKey ~= nil
        or current._captureFinalUnattestedWaveId ~= nil
        or current._captureFinalConfirmedBase ~= nil
end

local function ApplyRebasedStableBase(zone, remote, base)
    remote.base = base

    -- Ces deux champs de l'overlay decrivent son socle et servent aux gardes de
    -- revert/final ; updatedAt/hold/kills restent ceux de la vague ZS courante.
    zone.previousOwner = base.owner
    zone.capturedTime = base.capturedTime
    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    zone._captureFinalConfirmedBase = nil
end

-- Un ZS valide peut ouvrir l'orange avant que le ZA global de login n'arrive.
-- Si la SavedVariable etait stale, le ZA corrige alors uniquement le socle
-- restaure/persiste sous l'overlay : la wave, son TTL et ses preuves restent
-- intacts. Cette exception n'existe que tant que le socle est en quarantaine.
function Lease:RebaseRemoteStableByZoneId(zoneId, ownerCode, owner, rawTs, rawCt)
    local zone = ResolveLeaseZone(zoneId)
    local remote = zone and zone._remoteCaptureLease
    if not zone or zone.status ~= "in_progress" or not remote
        or zone.holdAuthorityLocal or zone._loginSyncUnconfirmed ~= true then return false end
    local base = BuildCertifiedStableBase(zone, remote, ownerCode, owner, rawTs, rawCt)
    if not base then return false end
    ApplyRebasedStableBase(zone, remote, base)
    return true
end

-- Prepare une resolution ZA totalement detachee pendant le dry-run atomique.
-- Aucun etat live n'est modifie ici. Le commit peut ainsi fermer une wave que
-- la carte exacte invalide sans laisser cet overlay ephemere vetoer la carte.
function Lease:PrepareRemoteStablePlan(zoneId, ownerCode, owner, rawTs, rawCt, action)
    if action ~= "preserve" and action ~= "rebase"
        and action ~= "cleanup" and action ~= "close"
        and action ~= "rebase_close" then return nil end
    local zone = ResolveLeaseZone(zoneId)
    local remote = zone and zone._remoteCaptureLease
    if not zone or zone.status ~= "in_progress" or not remote
        or zone.holdAuthorityLocal then return nil end
    if action == "rebase" and zone._loginSyncUnconfirmed ~= true then return nil end
    local base = BuildCertifiedStableBase(zone, remote, ownerCode, owner, rawTs, rawCt)
    if not base then return nil end

    -- L'egalite wire a deja ete calculee par BuildZoneAllSnapshotPart pendant
    -- le preflight ZA. Ne pas la refaire depuis les champs bruts : N:0 et les
    -- anciens owners sans horloge y sont canonicalises sur l'epoch campagne.

    local front
    if Overlord.Fronts and Overlord.Fronts.GetZone then
        local _, foundFront = Overlord.Fronts:GetZone(zoneId)
        front = foundFront
    end
    return {
        zone = zone,
        remote = remote,
        base = base,
        action = action,
        close = action == "close" or action == "rebase_close",
        frontId = front and front.id or nil,
    }
end

function Lease:ValidateRemoteStablePlan(plan)
    return type(plan) == "table" and plan.zone
        and plan.zone.status == "in_progress"
        and plan.zone._remoteCaptureLease == plan.remote
        and not plan.zone.holdAuthorityLocal
        and type(plan.base) == "table"
end

-- Total apres ValidateRemoteStablePlan : Lua ne yield pas entre validation et
-- commit. Aucun lookup, timer ou branche fallible ne peut donc couper le lot.
function Lease:CommitRemoteStablePlan(plan)
    local zone, remote = plan.zone, plan.remote
    if plan.close then
        PutTombstone(zone.id, remote.originKey, remote.waveId)
        RestoreSnapshot(zone, plan.base)
        zone._remoteCaptureLease = nil
        ClearTransient(zone)
        zone._remoteLeaseExpiredReason = "certified_snapshot"
        TrackLeaseZone(zone)
    elseif plan.action == "rebase" or plan.action == "cleanup" then
        ApplyRebasedStableBase(zone, remote, plan.base)
    end
end

-- Snapshot lecture seule pris apres validation cryptographique/protocolaire mais
-- avant toute mutation. Il n'ouvre pas le bail et ne cree aucun tombstone.
function Lease:PrepareRemote(zone)
    if not zone then return nil end
    local current = zone._remoteCaptureLease
    return current and CopySnapshot(current.base) or StableSnapshot(zone)
end

local function ResolveZoneMapID(zone)
    if not zone or not Overlord.Fronts or not Overlord.Fronts.GetZone then return nil end
    local _, front = Overlord.Fronts:GetZone(zone.id)
    if front and Overlord.Fronts.GetMapID then
        local ok, mapID = pcall(Overlord.Fronts.GetMapID, Overlord.Fronts, front.id)
        if ok and mapID then return mapID end
    end
    -- Fail closed : zone.center est exprime sur la carte du front. Une sous-map
    -- retournee par GetBestMapForUnit utiliserait un autre repere et pourrait
    -- valider fortuitement une position de securite.
    return nil
end

-- Retourne le GUID uniquement si Blizzard fournit une position exacte du unit
-- dans le cercle. Une nameplate simplement visible ne suffit jamais.
local findCapturerMapID
local findCapturerWanted
local findCapturerOwner
local findCapturerZone
local findCapturerExpectedGuid
local findCapturerRaidUnits = {}
local findCapturerPartyUnits = {}
local findCapturerNameplateUnits = {}
local findCapturerPointUnits = { "target", "mouseover", "focus" }
for i = 1, 40 do
    findCapturerRaidUnits[i] = "raid" .. i
    findCapturerNameplateUnits[i] = "nameplate" .. i
end
for i = 1, 4 do findCapturerPartyUnits[i] = "party" .. i end

-- Le nom/GUID attendu elimine presque tous les tokens avant les appels couteux
-- d'aura, phase, faction et position. Cette fonction reste sous pcall car les
-- identites d'unites peuvent etre des valeurs protegees sur Retail.
local function FindCapturerUnitIdentity(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local name
    if Overlord.SafeGetUnitName then
        name = Overlord:SafeGetUnitName(unit, true)
    elseif type(GetUnitName) == "function" then
        name = GetUnitName(unit, true)
    elseif type(UnitName) == "function" then
        name = UnitName(unit)
    end
    if CanonicalPlayer(name) ~= findCapturerWanted
        or type(UnitGUID) ~= "function" then return nil end
    local guid = UnitGUID(unit)
    if not guid or (findCapturerExpectedGuid and guid ~= findCapturerExpectedGuid) then
        return nil
    end
    return guid
end

local function FindCapturerUnitEligible(unit)
    if type(UnitIsConnected) == "function" and not UnitIsConnected(unit) then return false end
    if type(UnitInPhase) == "function" and UnitInPhase(unit) ~= true then return false end
    if type(UnitIsVisible) == "function" and UnitIsVisible(unit) ~= true then return false end
    if type(UnitIsDead) == "function" and UnitIsDead(unit) then return false end
    if type(UnitIsGhost) == "function" and UnitIsGhost(unit) then return false end
    if UnitFactionGroup(unit) ~= findCapturerOwner then return false end
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync
        and Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync(unit) then return false end
    return true
end

local function FindCapturerUnitInsideDisk(pos)
    local ux, uy = pos:GetXY()
    if not ux or not uy then return false end
    local aspect = Overlord.Zones and Overlord.Zones.GetMapAspectRatio
        and Overlord.Zones:GetMapAspectRatio() or 1
    local dx = findCapturerZone.center[1] - ux * 100
    local dy = (findCapturerZone.center[2] - uy * 100) * aspect
    return dx * dx + dy * dy <= findCapturerZone.radius * findCapturerZone.radius
end

local function FindCapturerMatchUnit(unit)
    local okIdentity, guid = pcall(FindCapturerUnitIdentity, unit)
    if not okIdentity or not guid then return nil end
    local okEligible, eligible = pcall(FindCapturerUnitEligible, unit)
    if not okEligible or not eligible then return nil end

    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, findCapturerMapID, unit)
    if not okPos or not pos then return nil end
    local okInside, inside = pcall(FindCapturerUnitInsideDisk, pos)
    if not okInside or not inside then return nil end
    return guid
end

local function FindCapturerOnDisk(zone, capturerName, owner, expectedGuid)
    if not zone or not zone.center or not zone.radius or not C_Map
        or type(C_Map.GetPlayerMapPosition) ~= "function"
        or type(UnitExists) ~= "function" or type(UnitIsPlayer) ~= "function"
        or type(UnitFactionGroup) ~= "function" then return nil end
    -- Hors du territoire (ex. Silvermoon), aucun token ne peut constituer une
    -- preuve physique. Evite jusqu'a 84 tests d'unites par heartbeat W.
    if Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone then
        local current = Overlord.Zones:GetCurrentPlayerZone()
        if not current or current.id ~= zone.id then return nil end
    end
    local wanted = CanonicalPlayer(capturerName)
    local mapID = ResolveZoneMapID(zone)
    if not wanted or not mapID then return nil end

    findCapturerMapID = mapID
    findCapturerWanted = wanted
    findCapturerOwner = owner
    findCapturerZone = zone
    findCapturerExpectedGuid = expectedGuid

    -- Les positions roster sont les plus fiables. Les tokens visibles restent
    -- utilisables uniquement si GetPlayerMapPosition retourne lui-meme un point.
    for i = 1, #findCapturerRaidUnits do
        local guid = FindCapturerMatchUnit(findCapturerRaidUnits[i])
        if guid then return guid end
    end
    for i = 1, #findCapturerPartyUnits do
        local guid = FindCapturerMatchUnit(findCapturerPartyUnits[i])
        if guid then return guid end
    end
    for _, unit in ipairs(findCapturerPointUnits) do
        local guid = FindCapturerMatchUnit(unit)
        if guid then return guid end
    end
    for i = 1, #findCapturerNameplateUnits do
        local guid = FindCapturerMatchUnit(findCapturerNameplateUnits[i])
        if guid then return guid end
    end
    return nil
end

CapturerVisibleOnLocalDisk = function(zone, capturerName, owner)
    return FindCapturerOnDisk(zone, capturerName, owner)
end

function Lease:IsPlayerOnDisk(zone, playerName, faction, expectedGuid)
    local guid = FindCapturerOnDisk(zone, playerName, faction, expectedGuid)
    if not guid then return false end
    return expectedGuid == nil or guid == expectedGuid
end

function Lease:ValidateProgress(zoneId, owner, capturerName, rawWave, remoteTs,
    holdTime, kills, holdReq, shard, sender, originGuid, networkDesignated,
    networkRouteId, relayedDisplayHold, relayedDisplayAt)
    if not zoneId or (owner ~= "Alliance" and owner ~= "Horde") then return nil end
    local originKey = CanonicalPlayer(capturerName)
    local identityDirect = not IsSyntheticSender(sender)
        and Overlord.Sync and Overlord.Sync.CaptureContributorMatchesSender
        and Overlord.Sync:CaptureContributorMatchesSender(capturerName, sender) or false
    if not originKey or not identityDirect then return nil end
    local waveId
    if not ValidWave(rawWave) then
        local knownZone = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
            or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId)))
        local current = knownZone and knownZone._remoteCaptureLease
        if current and current.originKey == originKey and current.owner == owner then
            -- Compat anciens clients : updatedAt-hold bouge pendant contestation.
            -- Tant que le meme capteur entretient son bail, conserver sa generation.
            waveId = current.waveId
        end
    end
    if not waveId then
        waveId = self:NormalizeWaveId(
            rawWave, zoneId, capturerName, owner, remoteTs, holdTime)
    end
    if not waveId or IsTombstoned(zoneId, originKey, waveId) then return nil end

    local knownZone = (Overlord.Zones and Overlord.Zones.GetZone
        and Overlord.Zones:GetZone(zoneId))
        or (Overlord.Fronts and Overlord.Fronts.GetZone
             and select(1, Overlord.Fronts:GetZone(zoneId)))
    if knownZone and knownZone._captureFinalUnattested
        and knownZone._captureFinalUnattestedOriginKey == originKey
        and knownZone._captureFinalUnattestedWaveId == waveId then
        return nil
    end
    local now = GetTime()
    local claimedNetworkWitnessSlot = identityDirect and type(networkDesignated) == "string"
        and tonumber(networkDesignated:match("^W([1-5])$")) or nil
    local networkOriginGuid = identityDirect and ValidPlayerGuid(originGuid) or nil
    local networkRouteInfo
    if claimedNetworkWitnessSlot and networkOriginGuid then
        local active = knownZone and knownZone._remoteCaptureLease
        local proof = active and active.originKey == originKey
            and active.owner == owner and active.waveId == waveId
            and active.networkProof or nil
        if proof and proof.slot == claimedNetworkWitnessSlot
            and proof.guid == networkOriginGuid and proof.routeSeed
            and proof.routeId == networkRouteId then
            networkRouteInfo = {
                seed = proof.routeSeed, routeId = proof.routeId,
                slot = proof.slot, size = proof.routeSize,
                baseline = proof.baseline, openedAt = proof.openedAt,
                keySet = proof.routeKeys,
                predecessorName = proof.predecessorName,
                predecessorKey = proof.predecessorKey,
                successorName = proof.successorName,
                successorKey = proof.successorKey,
            }
        elseif (tonumber(holdTime) or 0) <= 10 and Overlord.Sync
            and Overlord.Sync.ResolveCaptureNetworkWitnessRoute then
            local selfName = Overlord.Sync.GetPlayerFullName
                and Overlord.Sync:GetPlayerFullName() or nil
            local resolved = selfName and Overlord.Sync:ResolveCaptureNetworkWitnessRoute(
                zoneId, owner, capturerName, waveId, networkOriginGuid, selfName,
                networkRouteId, claimedNetworkWitnessSlot) or nil
            if resolved and resolved.slot == claimedNetworkWitnessSlot then
                networkRouteInfo = resolved
            end
        end
    end
    -- L'identite addon du capteur est la source canonique. Une verification de
    -- faction issue d'un cache roster local recreerait exactement le desync que
    -- ce bail doit eviter ; les valeurs libres restent bornees ci-dessous.
    local direct = true
    local physicalPresenceGuid = direct
        and FindCapturerOnDisk(knownZone, capturerName, owner, networkOriginGuid) or nil
    local networkRequired = direct and self:NormalizeCaptureRequirement(
        knownZone, owner, holdReq) or nil
    local networkWitnessSlot = networkRouteInfo and networkRouteInfo.slot or nil
    local networkPeer = networkRouteInfo and networkRouteInfo.successorName or nil
    local proofRequired = networkRequired
    if IsExtendedCaptureRequirement(proofRequired)
        and knownZone and not knownZone.isCapital then
        local active = knownZone._remoteCaptureLease
        local barrierAllowsExtended = active
            and active.originKey == originKey and active.waveId == waveId
            and (active.barrierCommitted
                or (active.barrierProposalUntil and now <= active.barrierProposalUntil))
        if not barrierAllowsExtended then proofRequired = nil end
    end
    local nowWall = time()
    local observerDisplayHold = ProjectObserverDisplay(
        holdTime, remoteTs, relayedDisplayHold, relayedDisplayAt, holdReq, nowWall)
    local decision = {
        direct = direct, waveId = waveId, originKey = originKey,
        hold = tonumber(holdTime) or 0, ts = tonumber(remoteTs) or 0,
        -- Les kills sont un effet gameplay et ne sont jamais herites d'un ZS.
        -- Le requis est accepte uniquement via la liste canonique normalisee.
        kills = 0, holdReq = proofRequired, shard = tonumber(shard),
        physicalPresenceGuid = physicalPresenceGuid,
        proofRequired = proofRequired,
        networkRequired = networkRequired,
        networkOriginGuid = networkOriginGuid,
        networkDesignated = networkWitnessSlot ~= nil,
        networkWitnessSlot = networkWitnessSlot,
        networkWitnessPeer = networkPeer,
        networkWitnessRouteSeed = networkRouteInfo and networkRouteInfo.seed or nil,
        networkWitnessRouteId = networkRouteInfo and networkRouteInfo.routeId or nil,
        networkWitnessRouteSize = networkRouteInfo and networkRouteInfo.size or nil,
        networkWitnessBaseline = networkRouteInfo and networkRouteInfo.baseline or nil,
        networkWitnessOpenedAt = networkRouteInfo and networkRouteInfo.openedAt or nil,
        networkWitnessRouteKeys = networkRouteInfo and networkRouteInfo.keySet or nil,
        networkWitnessPredecessorName = networkRouteInfo and networkRouteInfo.predecessorName or nil,
        networkWitnessPredecessorKey = networkRouteInfo and networkRouteInfo.predecessorKey or nil,
        networkWitnessSuccessorName = networkRouteInfo and networkRouteInfo.successorName or nil,
        networkWitnessSuccessorKey = networkRouteInfo and networkRouteInfo.successorKey or nil,
        observerDisplayHold = observerDisplayHold,
        observerDisplayAt = nowWall,
    }
    return decision
end

local function ExpireUnacknowledgedBarrier(remote, now)
    if not remote or remote.barrierCommitted
        or not remote.barrierProposalUntil
        or now <= remote.barrierProposalUntil then return false end
    remote.effectiveRequired = tonumber(remote.barrierPreviousRequired)
        or BASE_HOLD_REQUIRED
    remote.barrierProposalRequired = nil
    remote.barrierProposalUntil = nil
    remote.barrierPreviousRequired = nil
    remote.barrierLocalProposal = nil
    remote.barrierProposalObserved = nil
    remote.barrierAcknowledged = nil
    remote.barrierDefenderKey = nil
    remote.barrierDefenderGuid = nil
    remote.barrierOriginGuid = nil
    return true
end

local function ApplyRemoteRequirement(remote, decision)
    if not remote or not decision then return end
    ExpireUnacknowledgedBarrier(remote, GetTime())
    local incoming = tonumber(decision.proofRequired)
    if not incoming then return end
    local current = tonumber(remote.effectiveRequired)
    if not current then
        remote.effectiveRequired = incoming
    elseif incoming > current then
        -- Seule une hausse est admise en cours de vague (Barricade). Renfort doit
        -- etre annonce sur le premier sample et ne peut jamais apparaitre tard.
        remote.effectiveRequired = incoming
    end
end

-- Preuve chronometrique destinee aux captures solo. Elle reste distincte de la
-- preuve physique : seuls les heartbeats directs explicitement marques pour un
-- petit groupe de temoins peuvent l'ouvrir. Les paquets suivants doivent garder
-- le meme GUID/wave/requis et ne jamais progresser plus vite que l'horloge locale.
local function StartNetworkProof(remote, decision, now)
    remote.networkProof = nil
    local hold = tonumber(decision and decision.hold) or 0
    local required = tonumber(decision and decision.networkRequired)
    local routeSize = math.floor(tonumber(decision and decision.networkWitnessRouteSize) or 0)
    local baseline = tonumber(decision and decision.networkWitnessBaseline)
    local openedAt = tonumber(decision and decision.networkWitnessOpenedAt)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING) or 500
    if not decision or decision.direct ~= true or decision.networkDesignated ~= true
        or not decision.networkOriginGuid or not required or hold > 10
        or type(decision.networkWitnessRouteSeed) ~= "string"
        or decision.networkWitnessRouteSeed == ""
        or type(decision.networkWitnessRouteId) ~= "string"
        or decision.networkWitnessRouteId == "" or routeSize < 2 or routeSize > 3
        or not baseline or baseline < 0 or baseline ~= math.floor(baseline)
        or baseline + 1 >= ceiling
        or not openedAt or openedAt > now or now - openedAt > 12
        or not decision.networkWitnessPredecessorKey
        or not decision.networkWitnessSuccessorKey then return end
    remote.networkProof = {
        guid = decision.networkOriginGuid,
        firstSeen = openedAt,
        openedAt = openedAt,
        lastSeen = now,
        firstHold = hold,
        lastHold = hold,
        maxHold = hold,
        samples = 1,
        required = required,
        lastRemoteTs = tonumber(decision.ts) or 0,
        designated = true,
        slot = decision.networkWitnessSlot,
        routeSeed = decision.networkWitnessRouteSeed,
        routeId = decision.networkWitnessRouteId,
        routeSize = routeSize,
        baseline = math.floor(baseline),
        routeKeys = decision.networkWitnessRouteKeys,
        predecessorName = decision.networkWitnessPredecessorName,
        predecessorKey = decision.networkWitnessPredecessorKey,
        successorName = decision.networkWitnessSuccessorName,
        successorKey = decision.networkWitnessSuccessorKey,
        peerName = decision.networkWitnessSuccessorName,
    }
end

local function UpdateNetworkProof(remote, decision, now)
    -- Les ZS ordinaires, SR et anciens clients ne participent jamais a cette
    -- preuve et ne peuvent donc pas la casser faute de GUID/marqueur W.
    if not remote or not decision or decision.direct ~= true
        or decision.networkDesignated ~= true then return end
    local proof = remote.networkProof
    if not proof then
        StartNetworkProof(remote, decision, now)
        return
    end
    proof.designated = true

    -- Slot et voisins viennent de l'engagement prive croise a l'ouverture, puis
    -- restent geles. Aucun paquet W ulterieur ne peut modifier cette route.
    if decision.networkWitnessSlot ~= proof.slot
        or decision.networkWitnessRouteSeed ~= proof.routeSeed
        or decision.networkWitnessRouteId ~= proof.routeId
        or tonumber(decision.networkWitnessRouteSize) ~= tonumber(proof.routeSize)
        or tonumber(decision.networkWitnessBaseline) ~= tonumber(proof.baseline)
        or decision.networkWitnessPredecessorKey ~= proof.predecessorKey
        or decision.networkWitnessSuccessorKey ~= proof.successorKey then
        remote.networkProof = nil
        return
    end

    local guid = decision.networkOriginGuid
    local required = tonumber(decision.networkRequired)
    local hold = tonumber(decision.hold) or 0
    if not guid or guid ~= proof.guid or not required then
        remote.networkProof = nil
        return
    end
    if required ~= tonumber(proof.required) then
        -- Barricade : le contrat peut passer de 120 a 180 au tout debut. Une
        -- reduction tardive ou toute autre mutation invalide la vague reseau.
        if required > (tonumber(proof.required) or 0) and hold <= 30 then
            proof.required = required
        else
            remote.networkProof = nil
            return
        end
    end

    local remoteTs = tonumber(decision.ts) or 0
    if remoteTs <= (tonumber(proof.lastRemoteTs) or 0) then return end
    local gap = now - (proof.lastSeen or now)
    local totalElapsed = now - (proof.firstSeen or now)
    local firstHold = tonumber(proof.firstHold) or 0
    -- Deux paquets retardes peuvent etre livres dans la meme frame. La borne
    -- globale empeche toujours une progression acceleree sans confondre ce cas
    -- avec un saut frauduleux entre deux callbacks rapproches.
    if gap > NETWORK_PROOF_MAX_GAP
        or hold > firstHold + totalElapsed + NETWORK_PROOF_HOLD_SLACK then
        remote.networkProof = nil
        return
    end
    proof.lastSeen = now
    proof.lastRemoteTs = remoteTs
    proof.lastHold = hold
    proof.maxHold = math.max(tonumber(proof.maxHold) or 0, hold)
    proof.samples = (tonumber(proof.samples) or 0) + 1
end

-- Un W cible peut arriver apres un ZS large de la meme version, voire apres le
-- tick large suivant. Dans ce cas l'etat est deja applique : on alimente seulement
-- la preuve W, sans faire regresser updatedAt ni rouvrir un autre bail.
function Lease:ObserveNetworkProgress(zone, owner, decision)
    local remote = zone and zone._remoteCaptureLease
    if not remote or not decision or decision.direct ~= true
        or decision.networkDesignated ~= true or remote.owner ~= owner
        or remote.originKey ~= decision.originKey
        or remote.waveId ~= decision.waveId then return false end
    local before = remote.networkProof
    local beforeTs = before and before.lastRemoteTs or nil
    UpdateNetworkProof(remote, decision, GetTime())
    local after = remote.networkProof
    return after ~= nil and (after ~= before or after.lastRemoteTs ~= beforeTs)
end

function Lease:AdoptRemote(zone, owner, capturerName, decision, preparedBase)
    if not zone or not decision or zone.holdAuthorityLocal then return false end
    if IsTombstoned(zone.id, decision.originKey, decision.waveId) then return false end
    local now = GetTime()
    local current = zone._remoteCaptureLease
    if current and current.originKey == decision.originKey and current.owner == owner
        and current.waveId == decision.waveId then
        local remoteTs = decision.ts or 0
        local previousTs = current.lastRemoteTs or 0
        -- Une version identique ne renouvelle jamais le bail : des observateurs
        -- qui se relaient le meme snapshot ne peuvent ainsi s'auto-entretenir.
        if remoteTs < previousTs then return false end
        if remoteTs == previousTs then
            local stillFresh = now - (current.lastSeen or 0) < SOFT_TTL
            if stillFresh then
                if decision.direct == true and not current.lastDirectSeen then
                    current.directValidated = true
                    current.lastDirectSeen = now
                end
                current.lastHold = decision.hold or 0
                ApplyRemoteRequirement(current, decision)
                UpdateNetworkProof(current, decision, now)
                zone.holdTimeRequired = tonumber(current.effectiveRequired)
                    or self:GetDefaultCaptureRequirement(zone, owner)
            end
            return true, false, stillFresh
        end
        ApplyRemoteRequirement(current, decision)
        UpdateNetworkProof(current, decision, now)
        if decision.direct == true then
            current.directValidated = true
            current.lastDirectSeen = now
        end
        current.lastSeen = now
        current.lastRemoteTs = remoteTs
        current.lastHold = decision.hold or 0
        zone.holdTimeRequired = tonumber(current.effectiveRequired)
            or self:GetDefaultCaptureRequirement(zone, owner)
        TrackLeaseZone(zone)
        return true, false, true
    end

    local base
    if current then
        local age = now - (current.lastSeen or 0)
        local expired = age >= HARD_TTL
        local softExpired = age >= SOFT_TTL
        local sameOriginDirectContinuation = decision.direct == true
            and current.owner == owner
            and current.originKey == decision.originKey
            and (decision.ts or 0) >= (current.lastRemoteTs or 0)
            and (decision.hold or 0) <= (current.lastHold or 0) + 15
        local softExpiredDirectHandoff = softExpired and decision.direct == true
            and current.owner == owner
            and (decision.ts or 0) >= (current.lastRemoteTs or 0)
            and (decision.hold or 0) <= (current.lastHold or 0) + 15
        local locallyObserved = CapturerVisibleOnLocalDisk
            and CapturerVisibleOnLocalDisk(zone, capturerName, owner) or false
        local cleanRestart = (decision.hold or 0) <= 15
            and (decision.ts or 0) >= (current.lastRemoteTs or 0)
            and (softExpired or locallyObserved)
        -- Une rotation directe du meme capteur couvre un loading. Un autre
        -- capteur du meme camp attend au moins le soft-TTL si son ZR a ete rate.
        if not expired and not cleanRestart and not sameOriginDirectContinuation
            and not softExpiredDirectHandoff then return false end
        base = CopySnapshot(current.base)
        PutTombstone(zone.id, current.originKey, current.waveId)
        RestoreSnapshot(zone, base)
        ClearTransient(zone)
    else
        base = preparedBase and CopySnapshot(preparedBase) or StableSnapshot(zone)
    end

    local remote = {
        originKey = decision.originKey,
        originName = capturerName,
        owner = owner,
        waveId = decision.waveId,
        lastSeen = now,
        lastRemoteTs = decision.ts or 0,
        lastHold = decision.hold or 0,
        openedAt = now,
        openedHold = decision.hold or 0,
        directValidated = decision.direct == true,
        lastDirectSeen = decision.direct == true and now or nil,
        effectiveRequired = decision.proofRequired
            or self:GetDefaultCaptureRequirement(zone, owner),
        base = base,
    }
    StartNetworkProof(remote, decision, now)
    zone._remoteCaptureLease = remote
    TrackLeaseZone(zone)
    return true, true, true
end

-- Une finale directe ne doit pas annuler une Barricade que ce client a lui-meme
-- consommee. L'autorite locale sur le requis prolonge exige aussi que le flux ait
-- reellement approche ce seuil.
function Lease:FinalSatisfiesLocalRequirement(zone, owner, originName, waveId, finalRequirement)
    local remote = zone and zone._remoteCaptureLease
    if not remote then return true end
    if owner ~= remote.owner or CanonicalPlayer(originName) ~= remote.originKey
        or ValidWave(waveId) ~= remote.waveId then return false end
    local required = tonumber(remote.localRequired)
    if not required then return true end
    if tonumber(finalRequirement) ~= required then return false end
    local observedDuration = (GetTime() - (remote.openedAt or GetTime()))
        + math.max(0, tonumber(remote.openedHold) or 0)
    return (tonumber(remote.lastHold) or 0) >= required - 10
        and observedDuration >= required - 15
end

function Lease:ShouldRejectFinal(zone, originName, waveId)
    if not zone then return true end
    local originKey = CanonicalPlayer(originName)
    local validWave = ValidWave(waveId)
    if not originKey or not validWave then return true end
    if zone._captureFinalUnattested
        and zone._captureFinalUnattestedOriginKey == originKey
        and zone._captureFinalUnattestedWaveId == validWave then
        return false
    end
    if zone.holdAuthorityLocal and zone._localCaptureWaveId ~= validWave then return true end
    return IsTombstoned(zone.id, originKey, validWave)
end

function Lease:TombstoneFinalWave(zoneId, originName, waveId)
    local originKey = CanonicalPlayer(originName)
    local validWave = ValidWave(waveId)
    if not zoneId or not originKey or not validWave then return false end
    PutTombstone(zoneId, originKey, validWave)
    return true
end

function Lease:IsSoftExpired(zone)
    local remote = zone and zone._remoteCaptureLease
    return remote ~= nil and GetTime() - (remote.lastSeen or 0) >= SOFT_TTL
end

function Lease:IsFreshDirect(zone)
    local remote = zone and zone._remoteCaptureLease
    return remote ~= nil and zone.status == "in_progress"
        and remote.directValidated == true
        and GetTime() - (remote.lastDirectSeen or 0) < SOFT_TTL
end

function Lease:ExpireRemote(zone, reason)
    local remote = zone and zone._remoteCaptureLease
    if not remote or zone.holdAuthorityLocal then return false end
    PutTombstone(zone.id, remote.originKey, remote.waveId)
    RestoreSnapshot(zone, remote.base)
    zone._remoteCaptureLease = nil
    ClearTransient(zone)
    zone._remoteLeaseExpiredReason = reason
    if Overlord.Sync and Overlord.Sync.OnRemoteCaptureLeaseEnded then
        Overlord.Sync:OnRemoteCaptureLeaseEnded(zone.id)
    end
    ScheduleAvailabilityRefresh(zone)
    RefreshVisuals()
    TrackLeaseZone(zone)
    return true
end

function Lease:MaybeExpire(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or zone.holdAuthorityLocal then return false end
    if ExpireUnacknowledgedBarrier(remote, GetTime()) then
        zone.holdTimeRequired = remote.effectiveRequired
        RefreshVisuals()
    end
    if GetTime() - (remote.lastSeen or 0) < HARD_TTL then return false end
    return self:ExpireRemote(zone, "timeout")
end

function Lease:Complete(zone)
    if not zone then return end
    local remote = zone._remoteCaptureLease
    if remote then
        PutTombstone(zone.id, remote.originKey, remote.waveId)
        ClearTransient(zone)
    end
    TombstoneLocalWave(zone)
    zone._remoteCaptureLease = nil
    zone._localCaptureWaveId = nil
    zone._localCaptureOpenedAt = nil
    zone._localCaptureBase = nil
    zone._captureReleaseSentWave = nil
    ClearLocalWaveEphemera(zone)
    TrackLeaseZone(zone)
end

function Lease:ClearLocal(zone)
    if not zone then return end
    TombstoneLocalWave(zone)
    zone._localCaptureWaveId = nil
    zone._localCaptureOpenedAt = nil
    zone._localCaptureBase = nil
    zone._captureReleaseSentWave = nil
    ClearLocalWaveEphemera(zone)
    TrackLeaseZone(zone)
end

function Lease:SnapshotLocalRelease(zone)
    if not zone or not zone.id or not zone._localCaptureWaveId then return nil end
    local waveId = zone._localCaptureWaveId
    if zone._captureReleaseSentWave == waveId then return nil end
    local sync = Overlord.Sync
    local origin = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
    return {
        zone = zone,
        zoneId = zone.id,
        waveId = waveId,
        origin = origin,
        payload = origin and origin ~= ""
            and table.concat({ zone.id, waveId, origin }, ":") or nil,
        -- Une vague locale restauree peut exister avant que CheckActiveFrontZone
        -- ait reconstruit InActiveFront. Le ZR critique conserve donc toujours la
        -- voie communaute bornee, y compris pendant une longue barriere login.
        includeCommunity = true,
    }
end

function Lease:SnapshotAllLocalReleases()
    local snapshots = {}
    if not Overlord.Fronts or not Overlord.Fronts.Order then return snapshots end
    for _, frontId in ipairs(Overlord.Fronts.Order) do
        local front = Overlord.Fronts:GetFront(frontId)
        for _, zone in ipairs((front and front.zones) or {}) do
            if zone.holdAuthorityLocal and zone._localCaptureWaveId then
                local snapshot = self:SnapshotLocalRelease(zone)
                if snapshot then snapshots[#snapshots + 1] = snapshot end
            end
        end
    end
    return snapshots
end

function Lease:BroadcastReleaseSnapshot(snapshot)
    if type(snapshot) ~= "table" or not snapshot.zoneId or not snapshot.waveId then return false end
    local sync = Overlord.Sync
    if not sync then return false end
    if not snapshot.origin or snapshot.origin == "" then
        snapshot.origin = sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
    end
    if not snapshot.origin or snapshot.origin == "" then return false end
    snapshot.payload = snapshot.payload
        or table.concat({ snapshot.zoneId, snapshot.waveId, snapshot.origin }, ":")
    local emitted = sync.SendToGroup
        and sync:SendToGroup("ZR", snapshot.payload) == true or false
    if sync.SendToChannel and sync:SendToChannel("ZR", snapshot.payload, true) == true then
        emitted = true
    end
    if snapshot.includeCommunity then
        local large = sync.IsLargeEvent and sync:IsLargeEvent()
        local maxMembers = large and 8 or 40
        -- Cette voie est synchrone : la queue communautaire normale est souvent
        -- suspendue quelques millisecondes plus tard par l'entree en instance.
        if sync.BroadcastToCommunityImmediate
            and (tonumber(sync:BroadcastToCommunityImmediate(
                "ZR", snapshot.payload, maxMembers)) or 0) > 0 then
            emitted = true
        end
        -- Garder aussi le fan-out temporise complet lorsqu'il reste assez de
        -- temps avant la suspension ; ReceiveRelease est idempotent.
        if sync.BroadcastToCommunity
            and sync:BroadcastToCommunity(
                "ZR", snapshot.payload, maxMembers, 0.12, true) == true then
            emitted = true
        end
    end
    -- Ne jamais tombstoner localement une vague que personne n'a pu recevoir.
    -- Au login/sortie d'instance, Core conserve alors l'intent et retente apres
    -- que Sync et au moins un transport soient effectivement disponibles.
    if not emitted then return false end
    local zone = snapshot.zone
    if zone and zone._localCaptureWaveId == snapshot.waveId then
        zone._captureReleaseSentWave = snapshot.waveId
    end
    return true
end

function Lease:BroadcastLocalRelease(zone)
    local snapshot = self:SnapshotLocalRelease(zone)
    if not snapshot then return false end
    return self:BroadcastReleaseSnapshot(snapshot)
end

function Lease:ReceiveRelease(payload, sender)
    if type(payload) ~= "string" or payload == "" then return false end
    local zoneId, rawWave, originName = strsplit(":", payload)
    local waveId = ValidWave(rawWave)
    local originKey = CanonicalPlayer(originName)
    local sync = Overlord.Sync
    if not zoneId or not waveId or not originKey or IsSyntheticSender(sender)
        or not sync or not sync.CaptureContributorMatchesSender
        or not sync:CaptureContributorMatchesSender(originName, sender) then
        return false
    end
    local zone = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
        or (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId)))
    if not zone then return false end
    PutTombstone(zoneId, originKey, waveId)
    local remote = zone._remoteCaptureLease
    if remote and remote.originKey == originKey and remote.waveId == waveId then
        -- Un co-capteur allie deja physiquement sur le disque reprend la vague
        -- avec un nouvel id local au lieu de perdre tout le progres.
        if zone.isHolding and zone.owner == Overlord.PlayerFaction then
            local takeoverWave = self:PromoteRemoteToLocal(zone, true)
            if not takeoverWave then return false end
            zone.holdAuthorityLocal = true
            local selfName = sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
            if selfName and selfName ~= "" then
                zone.zsOfficialCapturerName = selfName
                zone._zsOfficialCapturerSeenAt = GetTime()
            end
            if sync.BroadcastZoneState then sync:BroadcastZoneState(zone) end
            return true
        end
        return self:ExpireRemote(zone, "release")
    end
    return true
end

function Lease:ReleaseAllLocal()
    if not Overlord.Fronts or not Overlord.Fronts.Order then return true end
    local allReleased = true
    for _, frontId in ipairs(Overlord.Fronts.Order) do
        local front = Overlord.Fronts:GetFront(frontId)
        for _, zone in ipairs((front and front.zones) or {}) do
            if zone.holdAuthorityLocal and zone._localCaptureWaveId
                and zone._captureReleaseSentWave ~= zone._localCaptureWaveId
                and not self:BroadcastLocalRelease(zone) then
                allReleased = false
            end
        end
    end
    return allReleased
end

-- Un loading hors instance a deja emis ZR, mais la capture locale continue. Il
-- faut donc changer de generation avant le prochain ZS ; sinon les observateurs
-- ont tombstone la vague encore active et ignoreraient tous ses futurs ticks.
function Lease:RotateReleasedLocalWaves()
    if not Overlord.Fronts or not Overlord.Fronts.Order then return end
    local sync = Overlord.Sync
    for _, frontId in ipairs(Overlord.Fronts.Order) do
        local front = Overlord.Fronts:GetFront(frontId)
        for _, zone in ipairs((front and front.zones) or {}) do
            local oldWave = zone._localCaptureWaveId
            if zone.holdAuthorityLocal and oldWave
                and zone._captureReleaseSentWave == oldWave then
                TombstoneLocalWave(zone)
                ClearLocalWaveEphemera(zone)
                zone._localCaptureWaveId = self:NewWaveId()
                zone._localCaptureOpenedAt = GetTime()
                zone.holdTimeElapsed = 0
                zone.holdTimeRequired = BASE_HOLD_REQUIRED
                    + LocalStrategicCapturePenalty(zone)
                zone.holdStartTime = GetTime()
                zone._captureReleaseSentWave = nil
                zone.updatedAt = time()
                if sync and sync.BroadcastZoneState then sync:BroadcastZoneState(zone) end
            end
        end
    end
end

function Lease:ApplyDefensiveRequirement(zoneId, mode, originName, waveId, originGuid,
    defenderGuid, rawRequirement, issuedAt, sender)
    local zone = Overlord.Zones and Overlord.Zones.GetZone
        and Overlord.Zones:GetZone(zoneId)
        or (Overlord.Fronts and Overlord.Fronts.GetZone
            and select(1, Overlord.Fronts:GetZone(zoneId)))
    if not zone or zone.isCapital or IsSyntheticSender(sender)
        or (mode ~= "P" and mode ~= "A" and mode ~= "C") then return false end
    local validWave = ValidWave(waveId)
    local originKey = CanonicalPlayer(originName)
    local senderKey = CanonicalPlayer(sender)
    if not validWave or not originKey or not senderKey
        or type(originGuid) ~= "string" or originGuid == ""
        or type(defenderGuid) ~= "string" or defenderGuid == ""
        or math.abs(time() - (tonumber(issuedAt) or 0)) > 120 then return false end
    local required = self:NormalizeCaptureRequirement(
        zone, zone.owner, rawRequirement)
    if not IsExtendedCaptureRequirement(required) then return false end

    local remote = zone._remoteCaptureLease
    local expectedDefender
    if remote and zone.status == "in_progress" and remote.originKey == originKey
        and remote.waveId == validWave and remote.owner == zone.owner then
        if required ~= ExtendedCaptureRequirementFor(
            tonumber(remote.effectiveRequired) or zone.holdTimeRequired) then
            return false
        end
        expectedDefender = remote.base and remote.base.owner
        if not expectedDefender or IsTombstoned(zone.id, originKey, validWave) then
            return false
        end
        if mode == "A" then
            if senderKey ~= originKey or not remote.barrierProposalUntil
                or GetTime() > remote.barrierProposalUntil
                or remote.barrierDefenderGuid ~= defenderGuid
                or remote.barrierOriginGuid ~= originGuid
                or tonumber(remote.barrierProposalRequired) ~= required
                or not self:IsPlayerOnDisk(
                    zone, originName, remote.owner, originGuid) then return false end
            remote.barrierAcknowledged = true
            -- Seul le defenseur selectionne consomme. Les temoins attaquants
            -- memorisent l'ack mais attendent le commit C du defenseur.
            local selfName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
                and Overlord.Sync:GetPlayerFullName() or nil
            local selfGuid = type(UnitGUID) == "function" and UnitGUID("player") or nil
            if expectedDefender == Overlord.PlayerFaction
                and CanonicalPlayer(selfName) == remote.barrierDefenderKey
                and selfGuid == remote.barrierDefenderGuid
                and Overlord.Ressources and Overlord.Ressources.IsBarricadeActive
                and Overlord.Ressources:IsBarricadeActive() then
                local increase = Overlord.Ressources:ConsumeBarricade()
                if increase and increase > 0 then
                    remote.barricadeHandled = true
                    remote.barrierCommitted = true
                    remote.barrierProposalUntil = nil
                    remote.barrierPreviousRequired = nil
                    remote.localRequired = required
                    remote.effectiveRequired = math.max(
                        tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED,
                        remote.localRequired)
                    zone.holdTimeRequired = remote.effectiveRequired
                    if Overlord.Sync and Overlord.Sync.BroadcastCaptureBarrier then
                        Overlord.Sync:BroadcastCaptureBarrier(
                            zone, "C", originName, validWave, originGuid,
                            remote.localRequired)
                    end
                end
            end
            return true
        end
        if mode == "C" then
            if remote.barrierCommitted then return true end
            if not remote.barrierProposalUntil then
                -- Un temoin qui a manque P/A peut encore accepter le commit si
                -- les deux joueurs sont toujours physiquement verifies au debut.
                if (tonumber(remote.lastHold) or 0) > 20
                    or GetTime() - (remote.openedAt or GetTime()) > 30
                    or not self:IsPlayerOnDisk(zone, originName, remote.owner, originGuid)
                    or not self:IsPlayerOnDisk(
                        zone, sender, expectedDefender, defenderGuid) then return false end
                remote.barrierPreviousRequired = tonumber(remote.effectiveRequired)
                    or BASE_HOLD_REQUIRED
                remote.barrierProposalRequired = required
                remote.barrierDefenderKey = senderKey
                remote.barrierDefenderGuid = defenderGuid
                remote.barrierOriginGuid = originGuid
                remote.barrierProposalObserved = true
            elseif GetTime() > remote.barrierProposalUntil
                or remote.barrierDefenderKey ~= senderKey
                or remote.barrierDefenderGuid ~= defenderGuid
                or remote.barrierOriginGuid ~= originGuid
                or tonumber(remote.barrierProposalRequired) ~= required then return false end
            remote.barrierCommitted = true
            remote.barrierAcknowledged = true
            remote.barrierProposalUntil = nil
            remote.barrierPreviousRequired = nil
            remote.effectiveRequired = math.max(
                tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED, required)
            zone.holdTimeRequired = remote.effectiveRequired
            return true
        end
        if remote.barrierCommitted then return true end
        if remote.barrierProposalUntil then
            return remote.barrierDefenderKey == senderKey
                and remote.barrierDefenderGuid == defenderGuid
                and remote.barrierOriginGuid == originGuid
        end
        if (tonumber(remote.lastHold) or 0) > 20
            or GetTime() - (remote.openedAt or GetTime()) > 30 then return false end
        if not self:IsPlayerOnDisk(zone, originName, remote.owner, originGuid)
            or not self:IsPlayerOnDisk(zone, sender, expectedDefender, defenderGuid) then
            return false
        end
        if not remote.barrierProposalRequired then
            remote.barrierPreviousRequired = tonumber(remote.effectiveRequired)
                or BASE_HOLD_REQUIRED
        end
        remote.barrierProposalRequired = required
        remote.barrierProposalUntil = GetTime() + 30
        remote.barrierDefenderKey = senderKey
        remote.barrierDefenderGuid = defenderGuid
        remote.barrierOriginGuid = originGuid
        remote.barrierProposalObserved = true
        remote.effectiveRequired = math.max(
            tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED, required)
        zone.holdTimeRequired = remote.effectiveRequired
        TrackLeaseZone(zone)
        return true
    end

    -- Le capteur local n'a pas de bail distant. Il n'accepte la Barricade que
    -- pour sa vague courante et seulement si Blizzard montre le defenseur sur le
    -- meme disque au moment exact du message.
    local selfName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
        and Overlord.Sync:GetPlayerFullName() or nil
    if not zone.holdAuthorityLocal or zone.status ~= "in_progress"
        or zone._localCaptureWaveId ~= validWave
        or CanonicalPlayer(selfName) ~= originKey
        or type(UnitGUID) ~= "function" or UnitGUID("player") ~= originGuid then return false end
    if required ~= ExtendedCaptureRequirementFor(zone.holdTimeRequired) then
        return false
    end
    expectedDefender = zone.previousOwner
        or (zone._localCaptureBase and zone._localCaptureBase.owner)
    if not expectedDefender or expectedDefender == zone.owner then
        return false
    end
    if mode == "A" then return false end
    if mode == "C" then
        if zone._captureBarrierCommitted then return true end
        if not zone._captureBarrierProposalUntil
            or GetTime() > zone._captureBarrierProposalUntil
            or zone._captureBarrierDefenderKey ~= senderKey
            or zone._captureBarrierDefenderGuid ~= defenderGuid
            or zone._captureBarrierOriginGuid ~= originGuid
            or tonumber(zone._captureDefensiveRequired) ~= required then return false end
        zone._captureBarrierCommitted = true
        zone._captureBarrierProposalUntil = nil
        zone._captureBarrierPreviousRequired = nil
        zone.holdTimeRequired = math.max(
            tonumber(zone.holdTimeRequired) or BASE_HOLD_REQUIRED, required)
        TrackLeaseZone(zone)
        return true
    end
    if zone._captureBarrierCommitted then return true end
    if zone._captureBarrierProposalUntil then
        return zone._captureBarrierDefenderKey == senderKey
            and zone._captureBarrierDefenderGuid == defenderGuid
            and zone._captureBarrierOriginGuid == originGuid
    end
    if (tonumber(zone.holdTimeElapsed) or 0) > 20
        or GetTime() - (zone._localCaptureOpenedAt or GetTime()) > 30
        or not self:IsPlayerOnDisk(zone, sender, expectedDefender, defenderGuid) then
        return false
    end
    if zone._captureDefensiveWaveId == validWave
        and tonumber(zone._captureDefensiveRequired) == required then return true end
    zone._captureDefensiveWaveId = validWave
    zone._captureDefensiveRequired = required
    zone._captureBarrierProposalUntil = GetTime() + 30
    zone._captureBarrierPreviousRequired = tonumber(zone.holdTimeRequired)
        or BASE_HOLD_REQUIRED
    zone._captureBarrierDefenderKey = senderKey
    zone._captureBarrierDefenderGuid = defenderGuid
    zone._captureBarrierOriginGuid = originGuid
    zone.holdTimeRequired = math.max(tonumber(zone.holdTimeRequired) or BASE_HOLD_REQUIRED,
        required)
    zone.updatedAt = math.max(time(), (tonumber(zone.updatedAt) or 0) + 1)
    if Overlord.Sync and Overlord.Sync.BroadcastZoneState then
        Overlord.Sync:BroadcastZoneState(zone, true)
    end
    if Overlord.Sync and Overlord.Sync.BroadcastCaptureBarrier then
        Overlord.Sync:BroadcastCaptureBarrier(
            zone, "A", originName, validWave, originGuid, required,
            defenderGuid, sender)
    end
    TrackLeaseZone(zone)
    return true
end

function Lease:MaybeConsumeBarricade(zone, owner, capturerName, decision, effectEligible)
    local remote = zone and zone._remoteCaptureLease
    if not remote or remote.barricadeHandled or owner == Overlord.PlayerFaction or zone.isCapital then
        return false
    end
    local baseOwnedByUs = remote.base and remote.base.owner == Overlord.PlayerFaction
    if not baseOwnedByUs then return false end
    -- Une ressource irreversible et son veto +60 exigent la position Blizzard
    -- exacte du capteur sur le disque dans le paquet courant. Un relais ou une
    -- nameplate sans coordonnees ne suffit pas.
    local originGuid = decision and decision.physicalPresenceGuid
    if not effectEligible or not originGuid then return false end
    if not Overlord.Ressources or not Overlord.Ressources.IsBarricadeActive
        or not Overlord.Ressources:IsBarricadeActive() then return false end
    local extended = ExtendedCaptureRequirementFor(
        tonumber(remote.effectiveRequired) or (decision and decision.proofRequired))
    if remote.barrierLocalProposal then
        if not remote.barrierAcknowledged
            or tonumber(decision.proofRequired) ~= extended then return false end
        local increase = Overlord.Ressources:ConsumeBarricade()
        if not increase or increase <= 0 then return false end
        remote.barricadeHandled = true
        remote.barrierCommitted = true
        remote.barrierProposalUntil = nil
        remote.barrierPreviousRequired = nil
        remote.localRequired = extended
        remote.effectiveRequired = math.max(
            tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED,
            remote.localRequired)
        zone.holdTimeRequired = remote.effectiveRequired
        if Overlord.Sync and Overlord.Sync.BroadcastCaptureBarrier then
            Overlord.Sync:BroadcastCaptureBarrier(
                zone, "C", capturerName, remote.waveId, originGuid,
                remote.localRequired)
        end
        return true
    end
    if (tonumber(remote.lastHold) or 0) > 20
        or GetTime() - (remote.openedAt or GetTime()) > 30 then return false end
    -- Phase 1 : proposer le contrat 180 sans consommer la ressource. La
    -- consommation n'a lieu qu'apres le ZS 180 direct du capteur (ack), ce qui
    -- evite une depense locale si CB n'a atteint personne.
    remote.barrierLocalProposal = true
    remote.barrierPreviousRequired = tonumber(remote.effectiveRequired)
        or BASE_HOLD_REQUIRED
    remote.barrierProposalRequired = extended
    remote.barrierProposalUntil = GetTime() + 30
    local selfName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
        and Overlord.Sync:GetPlayerFullName() or nil
    local defenderGuid = type(UnitGUID) == "function" and UnitGUID("player") or nil
    remote.barrierDefenderKey = CanonicalPlayer(selfName)
    remote.barrierDefenderGuid = defenderGuid
    remote.barrierOriginGuid = originGuid
    if not remote.barrierDefenderKey or not defenderGuid then
        remote.barrierLocalProposal = nil
        remote.barrierProposalRequired = nil
        remote.barrierProposalUntil = nil
        remote.barrierPreviousRequired = nil
        return false
    end
    remote.effectiveRequired = math.max(remote.barrierPreviousRequired, extended)
    zone.holdTimeRequired = extended
    zone.updatedAt = time()
    if Overlord.Sync and Overlord.Sync.BroadcastCaptureBarrier then
        Overlord.Sync:BroadcastCaptureBarrier(
            zone, "P", capturerName, remote.waveId, originGuid, extended)
    end
    TrackLeaseZone(zone)
    return false
end

local function ExpireLocalBarrierProposal(zone)
    if not zone or zone._captureBarrierCommitted
        or not zone._captureBarrierProposalUntil
        or GetTime() <= zone._captureBarrierProposalUntil then return false end
    zone.holdTimeRequired = tonumber(zone._captureBarrierPreviousRequired)
        or BASE_HOLD_REQUIRED
    zone._captureDefensiveRequired = nil
    zone._captureDefensiveWaveId = nil
    zone._captureBarrierProposalUntil = nil
    zone._captureBarrierPreviousRequired = nil
    zone._captureBarrierDefenderKey = nil
    zone._captureBarrierDefenderGuid = nil
    zone._captureBarrierOriginGuid = nil
    zone.updatedAt = math.max(time(), (tonumber(zone.updatedAt) or 0) + 1)
    if Overlord.Sync and Overlord.Sync.BroadcastZoneState then
        Overlord.Sync:BroadcastZoneState(zone, true)
    end
    RefreshVisuals()
    return true
end

GetZoneMaintenanceDeadline = function(zone, now)
    if not ZoneNeedsLeaseMaintenance(zone) then return nil end
    local deadline
    local remote = zone._remoteCaptureLease
    if remote then
        if zone.status ~= "in_progress" then
            return now
        end
        deadline = (tonumber(remote.lastSeen) or 0) + HARD_TTL
        if not remote.barrierCommitted and remote.barrierProposalUntil then
            deadline = math.min(deadline, tonumber(remote.barrierProposalUntil) or deadline)
        end
    end
    if not zone._captureBarrierCommitted and zone._captureBarrierProposalUntil then
        local localDeadline = tonumber(zone._captureBarrierProposalUntil) or now
        deadline = deadline and math.min(deadline, localDeadline) or localDeadline
    end
    return deadline or now
end

local function SweepActiveLeases()
    leaseMaintenanceTimer = nil
    leaseMaintenanceDueAt = 0
    if Overlord.InstanceSuspended then
        -- Aucun calcul de zone en instance. Une courte re-verification O(1) suffit
        -- pour expirer rapidement au retour sans reintroduire un sweep global.
        ScheduleLeaseMaintenance(5)
        return
    end

    leaseMaintenanceRunning = true
    for zoneId, zone in pairs(activeLeaseZones) do
        ExpireLocalBarrierProposal(zone)
        if zone._remoteCaptureLease and zone.status ~= "in_progress" then
            Lease:Complete(zone)
        else
            Lease:MaybeExpire(zone)
        end
        if not ZoneNeedsLeaseMaintenance(zone) then
            if activeLeaseZones[zoneId] then
                activeLeaseZoneCount = math.max(0, activeLeaseZoneCount - 1)
            end
            activeLeaseZones[zoneId] = nil
        end
    end
    leaseMaintenanceRunning = false
    ScheduleLeaseMaintenance()
end

ScheduleLeaseMaintenance = function(forcedDelay, zoneHint)
    if not C_Timer or not C_Timer.NewTimer then return end
    local now = GetTime()
    local earliest
    if activeLeaseZoneCount <= 0 then
        if leaseMaintenanceTimer and leaseMaintenanceTimer.Cancel then
            leaseMaintenanceTimer:Cancel()
        end
        leaseMaintenanceTimer = nil
        leaseMaintenanceDueAt = 0
        return
    end
    if forcedDelay == nil and zoneHint then
        earliest = GetZoneMaintenanceDeadline(zoneHint, now)
        if not earliest then return end
    elseif forcedDelay == nil then
        for zoneId, zone in pairs(activeLeaseZones) do
            local deadline = GetZoneMaintenanceDeadline(zone, now)
            if deadline then
                if not earliest or deadline < earliest then earliest = deadline end
            else
                activeLeaseZones[zoneId] = nil
                activeLeaseZoneCount = math.max(0, activeLeaseZoneCount - 1)
            end
        end
        if not earliest then
            if leaseMaintenanceTimer and leaseMaintenanceTimer.Cancel then
                leaseMaintenanceTimer:Cancel()
            end
            leaseMaintenanceTimer = nil
            leaseMaintenanceDueAt = 0
            return
        end
    end

    local delay = tonumber(forcedDelay)
    if not delay then delay = math.max(LEASE_TIMER_EPSILON, earliest - now) end
    local dueAt = now + math.max(LEASE_TIMER_EPSILON, delay)
    -- Un timer deja arme plus tot reste valide : l'activite d'un heartbeat peut
    -- repousser l'expiration, mais ne doit pas creer/annuler un timer par paquet.
    if leaseMaintenanceTimer and leaseMaintenanceDueAt > 0
        and leaseMaintenanceDueAt <= dueAt + LEASE_TIMER_EPSILON then return end
    if leaseMaintenanceTimer and leaseMaintenanceTimer.Cancel then
        leaseMaintenanceTimer:Cancel()
    end
    leaseMaintenanceDueAt = dueAt
    leaseMaintenanceTimer = C_Timer.NewTimer(
        math.max(LEASE_TIMER_EPSILON, dueAt - now), SweepActiveLeases)
end

function Lease:WakeMaintenance(zone)
    TrackLeaseZone(zone)
end
