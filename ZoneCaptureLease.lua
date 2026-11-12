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
-- Silence d'un capteur toleré avant de geler le minuteur ou de laisser un autre
-- joueur reprendre la capture. Le relais n'envoie un tick que toutes les 60 s apres
-- les 45 premieres secondes d'une vague en gros event : 20 s figeait l'affichage et
-- laissait un allie du disque repartir a 0:00 pendant que le capteur continuait.
local LIVE_SILENCE = 75
-- Un tick perdu ne doit pas annuler la vague : 60 s de cadence + une perte + latence.
local HARD_TTL = 150
local TOMBSTONE_TTL = 600
local MAX_ROWS = 512
local TOMBSTONE_PURGE_INTERVAL = 60
local LEASE_TIMER_EPSILON = 0.05
local NETWORK_PROOF_HOLD_SLACK = 8
-- Un heartbeat W part toutes les 15 s. Cinquante secondes tolerent deux pertes
-- consecutives sans assouplir la fraicheur du terminal, bornee separement.
local NETWORK_PROOF_MAX_GAP = 50
local BASE_HOLD_REQUIRED = 120
-- 2.4.0: a wave of the other faction heard within this many seconds of its start is "told live".
local LIVE_START_LAG = 30
-- 2.4.0 (relief, see TakeOverStanding): how far past the relieved timer a relief may be told.
local RELIEF_SLACK = 10
-- A word of the capturer is fresh for this long; a lease silent that long may be relieved.
local RELIEF_FRESH = 8
-- 2.1.1: how long before our wave opened a capture of the point can still be that same capture
-- (not heard yet when we stepped on it).
local GUILD_FINAL_SLACK = 10

local tombstones = {}
local tombstoneCount = 0
-- Vagues arretees faute de nouvelles (timeout) ou relevees par un autre capteur :
-- marque « douce ». Un tick plus recent du meme capteur la ranime, et sa finale
-- reste acceptee (un capteur qui continue malgre une perte n'est jamais efface).
local softTombstones = {}
local softTombstoneCount = 0
-- Vagues fermees par une carte (zone deja au capteur, capture datee ; avant 2.0.1
-- aussi : prerequis absents de notre vue) : la marque dure bloque toujours leurs ticks, mais leur finale reste
-- acceptee. Notre carte peut avoir rate la prise precedente ; une finale authentifiee
-- corrige alors la zone au lieu d'etre refusee 10 min. Valeur = horodatage de la
-- marque dure qu'elle accompagne ; toute nouvelle marque dure l'efface.
local snapshotClosedTombstones = {}
local snapshotClosedCount = 0
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

-- 1.8.2: hard marks put because a capture ended on the zone (the wave we followed,
-- waves relieved or gone quiet). Only those may still give another capture later
-- (see ShouldRejectFinal). A wave closed by anti-spoof, by its own capturer's
-- release or by availability stays closed whatever its final says.
local superseded = { rows = {}, count = 0 }
local function MarkSuperseded(key)
    if superseded.rows[key] == nil then superseded.count = superseded.count + 1 end
    superseded.rows[key] = tombstones[key]
end

local function PutTombstone(zoneId, originKey, waveId)
    if not zoneId or not originKey or not waveId then return end
    local now = GetTime()
    local key = LeaseKey(zoneId, originKey, waveId)
    if tombstones[key] == nil then tombstoneCount = tombstoneCount + 1 end
    tombstones[key] = now
    if snapshotClosedTombstones[key] ~= nil then
        snapshotClosedTombstones[key] = nil
        snapshotClosedCount = math.max(0, snapshotClosedCount - 1)
    end
    if superseded.rows[key] ~= nil then
        superseded.rows[key] = nil
        superseded.count = math.max(0, superseded.count - 1)
    end
    if tombstoneCount >= MAX_ROWS
        or now - lastTombstonePurgeAt >= TOMBSTONE_PURGE_INTERVAL then
        tombstoneCount = PurgeBounded(tombstones, now, TOMBSTONE_TTL)
        if superseded.count > 0 then
            superseded.count = PurgeBounded(superseded.rows, now, TOMBSTONE_TTL)
        end
        if softTombstoneCount > 0 then
            softTombstoneCount = PurgeBounded(softTombstones, now, TOMBSTONE_TTL)
        end
        if snapshotClosedCount > 0 then
            snapshotClosedCount = PurgeBounded(snapshotClosedTombstones, now, TOMBSTONE_TTL)
        end
        lastTombstonePurgeAt = now
    end
end

-- Marque dure posee par une carte globale : bloque les ticks, pas la finale.
local function PutSnapshotClosedTombstone(zoneId, originKey, waveId)
    PutTombstone(zoneId, originKey, waveId)
    if not zoneId or not originKey or not waveId then return end
    local key = LeaseKey(zoneId, originKey, waveId)
    snapshotClosedCount = snapshotClosedCount + 1
    snapshotClosedTombstones[key] = tombstones[key]
    if snapshotClosedCount >= MAX_ROWS then
        snapshotClosedCount = PurgeBounded(snapshotClosedTombstones, GetTime(), TOMBSTONE_TTL)
    end
end

local function PutSoftTombstone(zoneId, originKey, waveId, lastTs)
    if not zoneId or not originKey or not waveId then return end
    local now = GetTime()
    local key = LeaseKey(zoneId, originKey, waveId)
    local row, ts = softTombstones[key], tonumber(lastTs) or 0
    if row == nil then softTombstoneCount = softTombstoneCount + 1 end
    -- Never lowered: a later mark of the same wave (its lease expiring after a relayed
    -- release) must not reopen it to ticks the earlier mark already blocked.
    softTombstones[key] = { lastSeen = now, ts = math.max(ts, row and tonumber(row.ts) or 0) }
    if softTombstoneCount >= MAX_ROWS then
        softTombstoneCount = PurgeBounded(softTombstones, now, TOMBSTONE_TTL)
    end
end

-- Marque douce encore valide qui bloque ce ts (nil = aucune, ou ts plus recent).
local function IsSoftTombstoned(zoneId, originKey, waveId, ts)
    if softTombstoneCount == 0 then return false end
    local key = LeaseKey(zoneId, originKey, waveId)
    local row = softTombstones[key]
    if not row then return false end
    if GetTime() - (row.lastSeen or 0) > TOMBSTONE_TTL then
        softTombstones[key] = nil
        softTombstoneCount = math.max(0, softTombstoneCount - 1)
        return false
    end
    ts = tonumber(ts)
    if ts and ts > (row.ts or 0) then return false end
    return true
end

-- Fin reelle d'une capture sur cette zone : les vagues relevees ou arretees faute de
-- nouvelles ne peuvent plus etre finalisees (sinon deux capteurs credites pour une
-- seule prise). Balayage borne par MAX_ROWS.
local function HardenSoftTombstonesForZone(zoneId)
    if not zoneId or softTombstoneCount == 0 then return end
    local prefix = tostring(zoneId) .. "|"
    local now = GetTime()
    for key in pairs(softTombstones) do
        if key:find(prefix, 1, true) == 1 then
            softTombstones[key] = nil
            softTombstoneCount = math.max(0, softTombstoneCount - 1)
            if tombstones[key] == nil then tombstoneCount = tombstoneCount + 1 end
            tombstones[key] = now
            if snapshotClosedTombstones[key] ~= nil then
                snapshotClosedTombstones[key] = nil
                snapshotClosedCount = math.max(0, snapshotClosedCount - 1)
            end
            MarkSuperseded(key)
        end
    end
end

-- Marque definitive (finale, ZR, anti-spoof...) seulement. Une fermeture par carte
-- globale n'est pas definitive pour la finale.
local function IsHardTombstoned(zoneId, originKey, waveId)
    local key = LeaseKey(zoneId, originKey, waveId)
    local seen = tombstones[key]
    if not seen then return false end
    if GetTime() - seen > TOMBSTONE_TTL then
        tombstones[key] = nil
        tombstoneCount = math.max(0, tombstoneCount - 1)
        return false
    end
    if snapshotClosedTombstones[key] == seen then return false end
    return true
end

-- ts : horodatage du paquet examine (ticks) ; une marque douce ne bloque que les
-- paquets qui ne sont pas plus recents que le dernier vu avant l'arret.
local function IsTombstoned(zoneId, originKey, waveId, ts)
    if IsSoftTombstoned(zoneId, originKey, waveId, ts) then return true end
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
        Overlord.MapMarkers:RequestOverlayRefresh(true)
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

-- beganAt (2.4.0, TakeOverStanding): a relief wave began when its capturer began standing on
-- the point, within the hour; the id says that second, as any wave's says its own, and ends
-- with "r": it carries on a capture that was running (IsReliefWave). Older clients read any id.
function Lease:NewWaveId(beganAt)
    waveSequence = (waveSequence + 1) % 1000000
    local wall = math.max(0, math.floor((Overlord.ServerNow and Overlord.ServerNow() or time())))
    local began = tonumber(beganAt)
    if began and began < wall and began > wall - 3600 then wall = math.floor(began) end
    local mono = math.max(0, math.floor(GetTime() * 1000)) % 1000000000
    return string.format("w%x_%x_%x%s", wall, mono, waveSequence, began and "r" or "")
end

-- 2.4.0: one timer per point. Several players of a group standing on a point when it becomes
-- theirs to take each began a capture of their own in the same second, each with its own timer,
-- its own view of the enemies and its own capture at the end: six raid members showed six timers
-- (Ashenvale, 2026-11-10), and a point was "captured" twice. A wave says when it began in its id
-- (NewWaveId: the server's second), the same for everybody: of two waves of one faction on one
-- point the first one is the capture, by that second, then by the capturer's name.
local function WaveBeganAt(waveId)
    local began = type(waveId) == "string" and waveId:match("^w(%x+)_%x+_%x+r?$") or nil
    return began and tonumber(began, 16) or nil
end
-- A relief (TakeOverStanding): the capture of a player who stood on the point, carried on from
-- the one whose capturer gave way.
local function IsReliefWave(waveId)
    return type(waveId) == "string" and waveId:match("^w%x+_%x+_%x+r$") ~= nil
end
function Lease:IsReliefWave(waveId) return IsReliefWave(waveId) end
-- Is the capture we follow under a Barricade? Known by our own handshake (barrierCommitted), or
-- told by its capturer's ticks (toldRequired, AdoptRemote): a follower who did not see the
-- defender raise it only knows it that way. No relief over one: its longer hold belongs to the
-- wave it was raised against, and a relief would shed it.
local function LeaseUnderBarrier(zone, remote)
    if not remote then return false end
    if remote.barrierCommitted or remote.barrierProposalUntil then return true end
    return not (zone and zone.isCapital) and IsExtendedCaptureRequirement(remote.toldRequired)
end

local function IsElderWave(waveId, originKey, otherWaveId, otherKey)
    local began, otherBegan = WaveBeganAt(waveId), WaveBeganAt(otherWaveId)
    if not began or not otherBegan or type(originKey) ~= "string" or type(otherKey) ~= "string"
        or originKey == otherKey then return false end
    if began ~= otherBegan then return began < otherBegan end
    return originKey < otherKey
end
-- An id is written by its sender. A wave cannot be older than the hour, nor further on than its
-- age allows: without that, any id saying an early second took the place of the capture followed.
-- A name as it came in a packet, for a chat line: nothing from a "|" or a control character on
-- (colour, link and texture codes, line breaks), 48 bytes at most.
function Lease:DisplayName(name)
    local text = tostring(name or ""):match("^[^|%c]*") or ""
    if #text > 48 then text = text:sub(1, 48):gsub("[\192-\247][\128-\191]*$", "") end
    return text ~= "" and text or "?"
end
local function WaveAgeFits(waveId, hold)
    local began = WaveBeganAt(waveId)
    if not began then return false end
    local nowWall = Overlord.ServerNow and Overlord.ServerNow() or time()
    return began <= nowWall + 5 and began >= nowWall - 3600
        and (tonumber(hold) or 0) <= nowWall - began + 15
end

-- Waves begun within this many seconds of each other are one group stepping on one point.
local SAME_START = 2
function Lease:WaveBeganAt(waveId) return WaveBeganAt(waveId) end
function Lease:SameStart(waveId, otherWaveId)
    local began, otherBegan = WaveBeganAt(waveId), WaveBeganAt(otherWaveId)
    return began ~= nil and otherBegan ~= nil and math.abs(began - otherBegan) <= SAME_START
end
function Lease:IsElderWave(waveId, originKey, otherWaveId, otherKey)
    return IsElderWave(waveId, originKey, otherWaveId, otherKey)
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

-- relief, beganAt (2.4.0): TakeOverStanding only. The capturer told us himself that his timer
-- goes down, or went silent, and does not stand on the point: the wave is his to lose, not live.
function Lease:PromoteRemoteToLocal(zone, releasedByOrigin, relief, beganAt)
    if not zone then return nil end
    local remote = zone._remoteCaptureLease
    if remote then
        -- Defense en profondeur : une entree tardive sur le disque ne peut pas
        -- tombstoner la vague authentifiee encore vivante puis repartir a zero.
        -- Seul le ZR direct de cette origine autorise une releve immediate.
        if not releasedByOrigin and relief ~= true and remote.directValidated == true
            and GetTime() - (remote.lastDirectSeen or 0) < LIVE_SILENCE then
            return nil
        end
        if releasedByOrigin then
            PutTombstone(zone.id, remote.originKey, remote.waveId)
        else
            PutSoftTombstone(zone.id, remote.originKey, remote.waveId, remote.lastRemoteTs)
        end
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
        zone.updatedAt = (Overlord.ServerNow and Overlord.ServerNow() or time())
        zone.isHolding = true
        zone.isPaused = false
        zone.holdStartTime = GetTime()
        zone._localCaptureBase = base
    elseif not zone._localCaptureBase then
        zone._localCaptureBase = StableSnapshot(zone)
    end
    zone._localCaptureWaveId = self:NewWaveId(beganAt)
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

-- 2.0.1: a dated capture that a map gives for a followed point, compared with the wave.
-- Without sinceWave: made after the capture under the wave. With it: also not before
-- the wave was first seen here, so it can be that wave's own outcome (its final did not
-- reach us; a capture needs its hold, so an earlier one is at least two minutes older).
function Lease:MapEntryPostdates(zone, rawCt, sinceWave)
    local remote = zone and zone._remoteCaptureLease
    if type(remote) ~= "table" then return false end
    local ct = math.floor(tonumber(rawCt) or 0)
    if ct <= 0 or ct <= math.floor(tonumber(remote.base and remote.base.capturedTime) or 0) then
        return false
    end
    if not sinceWave then return true end
    local now = Overlord.ServerNow and Overlord.ServerNow() or time()
    return ct >= now - (GetTime() - (tonumber(remote.openedAt) or GetTime())) - 30
end

-- 2.0.1: could the followed wave have reached its hold by now (the hold it had when
-- first seen here, plus the time since, thirty seconds of margin)?
function Lease:WaveCouldHaveFinished(zone)
    local remote = zone and zone._remoteCaptureLease
    if type(remote) ~= "table" then return false end
    local required = tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED
    local progressed = (tonumber(remote.openedHold) or 0)
        + (GetTime() - (tonumber(remote.openedAt) or GetTime()))
    return progressed >= required - 30
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
        PutSnapshotClosedTombstone(zone.id, remote.originKey, remote.waveId)
        if Overlord.Sync and Overlord.Sync.NoteEnemyCaptureLeaseEnd then
            Overlord.Sync:NoteEnemyCaptureLeaseEnd(remote.owner, "closedByMapSnapshot")
        end
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

-- Same lookup again within 1.5 s (every in-progress ZS of a siege re-ran it: up to
-- ~90 unit tokens each, perf audit 2026-10-01) reuses the answer. A capturer's own
-- ticks are 5 s apart, so the evidence is never older than one tick. One window at
-- a time: the table is dropped, not grown.
local findCapturerCache = { at = -1000, entries = {} }
local FindCapturerOnDiskUncached
local function FindCapturerOnDisk(zone, capturerName, owner, expectedGuid)
    if not zone or not zone.id then return FindCapturerOnDiskUncached(zone, capturerName, owner, expectedGuid) end
    local now = GetTime and GetTime() or 0
    if now - findCapturerCache.at > 1.5 then
        findCapturerCache.at, findCapturerCache.entries = now, {}
    end
    local key = tostring(zone.id) .. "|" .. tostring(capturerName) .. "|" .. tostring(owner)
        .. "|" .. tostring(expectedGuid)
    local hit = findCapturerCache.entries[key]
    if hit ~= nil then return hit or nil end
    local guid = FindCapturerOnDiskUncached(zone, capturerName, owner, expectedGuid)
    findCapturerCache.entries[key] = guid or false
    return guid
end
FindCapturerOnDiskUncached = function(zone, capturerName, owner, expectedGuid)
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
    -- Barrier handshakes (A/C) need the position now, not the 1.5 s cached answer.
    local guid = FindCapturerOnDiskUncached(zone, playerName, faction, expectedGuid)
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
    if not waveId or IsTombstoned(zoneId, originKey, waveId, remoteTs) then return nil end

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
    local nowWall = (Overlord.ServerNow and Overlord.ServerNow() or time())
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

-- 2.2.2: a wave told without ticks (guild, hands of the member list, answers to a map pull) runs
-- on the clock of its last state heard. A copy that went through hands and queues is late, and
-- the raw hold it carries says nothing of that: the clock starts from the hold projected to
-- now (the decision's observerDisplayHold: the sender's display, or the raw hold aged by the
-- state's date), or a late copy keeps a finished wave on the map for minutes after the others
-- dropped it, and tells it again with a fresh date. (Added to the opening hold as well: the
-- proofs count the progress made since, so they do not change.)
local TRANSIT_LAG_MAX = 100
-- The sender writes the state's date and may write its display hold: neither buys more than
-- the time the state really spent on the way. The lag is bounded by the age of the stamp
-- (a display hold ahead of it is the sender's word only), by TRANSIT_LAG_MAX, and by what is
-- left of the required hold (a late copy never completes a wave on its own); a state without
-- a stamp, or stamped in the future (clamped by NormalizeRemoteTimestamp), has no age.
local function TransitLag(decision, required)
    local raw = tonumber(decision and decision.hold) or 0
    local projected = tonumber(decision and decision.observerDisplayHold)
    if not projected or projected ~= projected then return 0 end
    local stamp = tonumber(decision.ts) or 0
    local at = tonumber(decision.observerDisplayAt) or (Overlord.ServerNow and Overlord.ServerNow() or time())
    if stamp <= 0 then return 0 end
    local lag = math.min(TRANSIT_LAG_MAX, math.floor(projected - raw), math.floor(at - stamp))
    local req = tonumber(required)
    if req then lag = math.min(lag, math.floor(req - raw)) end
    return math.max(0, lag)
end

function Lease:AdoptRemote(zone, owner, capturerName, decision, preparedBase)
    if not zone or not decision or zone.holdAuthorityLocal then return false end
    if IsTombstoned(zone.id, decision.originKey, decision.waveId, decision.ts) then return false end
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
                current.toldRequired = decision.networkRequired or current.toldRequired
                ApplyRemoteRequirement(current, decision)
                UpdateNetworkProof(current, decision, now)
                zone.holdTimeRequired = tonumber(current.effectiveRequired)
                    or self:GetDefaultCaptureRequirement(zone, owner)
            end
            return true, false, stillFresh
        end
        current.toldRequired = decision.networkRequired or current.toldRequired
        ApplyRemoteRequirement(current, decision)
        UpdateNetworkProof(current, decision, now)
        if decision.direct == true then
            current.directValidated = true
            current.lastDirectSeen = now
        end
        current.lastSeen = now
        current.lastRemoteTs = remoteTs
        -- 2.4.0: is its timer going up? (ZoneControl: a co-capturer's timer runs between two ticks.)
        current.rising = (decision.hold or 0) > (current.lastHold or 0)
        if (decision.hold or 0) >= (current.peakHold or 0) then
            current.peakHold, current.peakAt = decision.hold or 0, now
        end
        -- A word of its later time: a siege told again while it runs (EnemyClockOverAt).
        if (decision.hold or 0) > 45 then current.retold = true end
        current.lastHold = decision.hold or 0
        current.tickAt, current.tickHold = now, (decision.hold or 0) + TransitLag(decision, current.effectiveRequired)
        zone.holdTimeRequired = tonumber(current.effectiveRequired)
            or self:GetDefaultCaptureRequirement(zone, owner)
        TrackLeaseZone(zone)
        return true, false, true
    end

    local base, relievedKey
    if current then
        local age = now - (current.lastSeen or 0)
        local expired = age >= HARD_TTL
        local softExpired = age >= LIVE_SILENCE
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
            and not IsElderWave(current.waveId, current.originKey, decision.waveId, decision.originKey)
        -- 2.4.0: of two waves of one faction on this point, the one that began first is followed
        -- (IsElderWave), whichever was heard first: every client ends on the same timer.
        -- On the capturer's own word only (firstHand, set by Sync): the origin of a relayed word
        -- is written by whoever passed it on, and those who hear a capture through relays (the
        -- other faction, far hands) get its start and its end, the same for either wave.
        local elderWave = decision.firstHand == true and current.owner == owner and not current.barrierCommitted
            and (decision.ts or 0) >= (current.lastRemoteTs or 0)
            and IsElderWave(decision.waveId, decision.originKey, current.waveId, current.originKey)
            and WaveAgeFits(decision.waveId, decision.hold)
            -- (Not back to the wave this one relieved, its capturer gave it up; unless he is
            -- back: we see him on the point, or the relief itself went silent. Without this a
            -- capturer who returned before hearing his relief left us on a timer nobody held.)
            and (current.relievedKey ~= LeaseKey(zone.id, decision.originKey, decision.waveId)
                or locallyObserved or now - (current.lastSeen or 0) >= RELIEF_FRESH)
        -- 2.4.0: relief (TakeOverStanding). The capturer we follow told us he is off the point
        -- (away), or released his capture, and another player of his faction carries it on, from
        -- no further than it stood (its highest hold told, plus the time gone since): his is
        -- the timer now. A timer going down alone is a contest, not a reason.
        -- Those who follow the relieved capture by its clock alone (no ticks: the other
        -- faction, the guild, far hands) know a relief by its id, with the same bound: only over
        -- a capture never heard again since its start, or silent, never over one that ticks
        -- (any id would take a running capture's place), nor over another relief (of two, the
        -- elder is followed, as of any two captures).
        -- (A relief is dated from when its capturer began standing behind the capture he
        -- relieves: never before that one began.)
        local reliefById = IsReliefWave(decision.waveId) and not IsReliefWave(current.waveId)
            and WaveAgeFits(decision.waveId, decision.hold)
            and (WaveBeganAt(decision.waveId) or 0) >= (WaveBeganAt(current.waveId) or 0) - RELIEF_SLACK
            and (current.tickAt == current.openedAt or now - (current.lastSeen or 0) >= RELIEF_FRESH)
        local relief = self.RELIEF_ON and current.owner == owner
            and (current.away == true or current.releasedAt ~= nil or reliefById)
            and not LeaseUnderBarrier(zone, current)
            and (decision.ts or 0) >= (current.lastRemoteTs or 0)
            and (decision.hold or 0) <= (tonumber(current.peakHold) or tonumber(current.lastHold) or 0)
                + (now - (current.peakAt or now)) + RELIEF_SLACK
        -- Une rotation directe du meme capteur couvre un loading. Un autre
        -- capteur du meme camp attend au moins le soft-TTL si son ZR a ete rate.
        if not expired and not cleanRestart and not sameOriginDirectContinuation
            and not softExpiredDirectHandoff and not elderWave and not relief then return false end
        if relief then relievedKey = LeaseKey(zone.id, current.originKey, current.waveId) end
        base = CopySnapshot(current.base)
        -- Releve par un autre capteur : marque douce (sa finale reste valable).
        PutSoftTombstone(zone.id, current.originKey, current.waveId, current.lastRemoteTs)
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
        -- 2.1.1: told in the guild, its ticks will not come (GuildLane:KeepFollowing), and
        -- its clock runs from the last one heard. Told there by its author, its end comes the
        -- same way, and no tick would refute a forged release (ReceiveRelease).
        viaGuild = Overlord.GuildLane ~= nil and Overlord.GuildLane:HeardHere() or nil,
        guildAuthor = Overlord.GuildLane ~= nil and Overlord.GuildLane:HeardFromAuthor() or nil,
        tickAt = now,
        tickHold = decision.hold or 0,
        peakHold = decision.hold or 0,
        peakAt = now,
        relievedKey = relievedKey,
        toldRequired = decision.networkRequired,
        -- 2.4.0: when it began, on the server's clock (ZoneDefense: which of two captures was first).
        startedTs = (tonumber(decision.ts) or 0) - (tonumber(decision.hold) or 0),
    }
    local lag = TransitLag(decision, remote.effectiveRequired)
    remote.tickHold, remote.openedHold = remote.tickHold + lag, remote.openedHold + lag
    -- 2.4.0: heard as it began (not a copy told late): see ClockOverAt.
    remote.toldLive = lag <= LIVE_START_LAG or nil
    StartNetworkProof(remote, decision, now)
    zone._remoteCaptureLease = remote
    -- 2.2.0: without ticks, its outcome is all we will hear of it (SyncDirectory WatchWave).
    local directory = remote.viaGuild and Overlord.ChannelDirectory
    if directory and directory.WatchWave then pcall(directory.WatchWave, directory, zone, remote) end
    -- Vague (re)ouverte : plus de marque douce (sinon ses Barricade P/A/C restaient refusees).
    local reopenedKey = LeaseKey(zone.id, decision.originKey, decision.waveId)
    if softTombstones[reopenedKey] then
        softTombstones[reopenedKey] = nil
        softTombstoneCount = math.max(0, softTombstoneCount - 1)
    end
    TrackLeaseZone(zone)
    return true, true, true
end

-- 2.4.0: we hold a capture of this point and hear, first-hand, another player of our faction
-- holding one that began before ours (IsElderWave): his is the capture, ours ends without a word
-- and we follow his timer, as a player who steps on the point later does. Those who followed ours
-- by its ticks switch the same way (AdoptRemote, elderWave); those who only heard its start keep
-- its clock, and any capture of the point ends it (FinalSatisfiesLocalRequirement).
-- firstHand: the game named the sender (group, guild, whisper), not a relay. And the capturer
-- stands on the point with us (decision.physicalPresenceGuid: a group member alive, in sight,
-- inside the disc): a guild mate's word from another layer, or a late copy, is no reason to give
-- up a capture that runs. Not when ours is the shorter one (a gold attack spent on it), nor over
-- a Barricade already raised against it.
function Lease:YieldToElderWave(zone, owner, capturerName, decision, firstHand)
    if not zone or not decision or firstHand ~= true or not decision.physicalPresenceGuid
        or not zone.holdAuthorityLocal or not zone.isHolding or zone.status ~= "in_progress"
        or zone.owner ~= owner or owner ~= Overlord.PlayerFaction then return false end
    if zone._captureBarrierCommitted or zone._captureBarrierProposalUntil then return false end
    local theirRequired = tonumber(decision.proofRequired) or tonumber(decision.networkRequired) or BASE_HOLD_REQUIRED
    if (tonumber(zone.holdTimeRequired) or BASE_HOLD_REQUIRED) < theirRequired then return false end
    local sync = Overlord.Sync
    local selfKey = CanonicalPlayer(sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil)
    local own = zone._localCaptureWaveId
    if not selfKey or not own or not IsElderWave(decision.waveId, decision.originKey, own, selfKey) then
        return false
    end
    -- A wave cannot be older than the hour, nor further on than its age allows.
    local nowWall = Overlord.ServerNow and Overlord.ServerNow() or time()
    local began = WaveBeganAt(decision.waveId)
    if began > nowWall + 5 or began < nowWall - 3600
        or (tonumber(decision.hold) or 0) > nowWall - began + 15 then return false end
    if IsTombstoned(zone.id, decision.originKey, decision.waveId, decision.ts) then return false end
    local base = zone._localCaptureBase and CopySnapshot(zone._localCaptureBase) or nil
    local openedAt = zone._localCaptureOpenedAt
    local ownHold = math.max(0, tonumber(zone.holdTimeElapsed) or 0)
    zone.holdAuthorityLocal = nil
    zone._localCaptureWaveId = nil
    if not self:AdoptRemote(zone, owner, capturerName, decision, base) then
        zone.holdAuthorityLocal, zone._localCaptureWaveId, zone._localCaptureOpenedAt = true, own, openedAt
        return false
    end
    -- Ours is over, here only: nobody is asked. Its start leaves the guild's box if it still
    -- waited there, so that the elder's own is the one the guild hears; already said, the guild
    -- follows our wave: its release is said like any other (the elder's start follows).
    local lane = Overlord.GuildLane
    if lane and lane.NoteYielded and not lane:NoteYielded(zone.id, own) then
        local origin = sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
        if origin and origin ~= "" and sync.BroadcastToRelay then
            pcall(sync.BroadcastToRelay, sync, "ZR", table.concat({ zone.id, own, origin }, ":"))
        end
    end
    PutTombstone(zone.id, selfKey, own)
    zone._localCaptureOpenedAt, zone._localCaptureBase, zone._captureReleaseSentWave = nil, nil, nil
    ClearLocalWaveEphemera(zone)
    local remote = zone._remoteCaptureLease
    local hold = tonumber(remote and remote.tickHold) or tonumber(decision.hold) or 0
    zone.holdTimeElapsed = hold
    zone.holdTimeRequired = tonumber(remote and remote.effectiveRequired) or zone.holdTimeRequired
    zone.holdStartTime = GetTime() - hold
    zone.isContested, zone.isPaused = false, false
    zone.zsOfficialCapturerName = capturerName
    zone._zsOfficialCapturerSeenAt = GetTime()
    zone.updatedAt = math.max(tonumber(zone.updatedAt) or 0, tonumber(decision.ts) or 0)
    -- We have stood here since our own capture began (StandingSeconds), for no longer than it
    -- earned (pushed back or off the point for a while, its timer says less than its age).
    zone._standSince = GetTime() - math.min(math.max(0, GetTime() - (openedAt or GetTime())), ownHold)
    zone._standSeenAt = GetTime()
    if self.stats then self.stats.yielded = self.stats.yielded + 1 end
    TrackLeaseZone(zone)
    RefreshVisuals()
    return true
end

-- 2.4.0: relief. One timer per point made the whole group's capture depend on one player:
-- when he died or stepped off the point his timer went down for everybody and the capture was
-- lost with four others standing on it (2.3.3: those who had begun their own in the same second
-- still held theirs, and one of them completed). A player who stands on the point while a
-- member of his group captures it carries the capture on when that capturer gives way:
-- - the capturer is a member of his group and tells him first-hand that he is off the point
--   (NoteFirstHand, away), or went silent for RELIEF_SILENCE seconds after his ticks came
--   while the game itself shows him dead, disconnected or standing outside the disc
--   (ShouldRelieve). Not seeing him proves nothing (another layer, out of sight): a capturer
--   pushed back by enemies where he stands keeps his capture, that is a contest, not an
--   absence, and a timer going down alone is no reason;
-- - the relief starts from what the timer showed, and never from more than the time he
--   himself has stood on the point without a break (NoteStanding, each second of ZoneControl's
--   follower path: on the disc, alive, on foot, not contested on his own screen). Nothing is
--   inherited: the wave is his own, dated from when he began to stand (NewWaveId beganAt), as
--   the capture he would have run alone;
-- - of several players standing there the first by name goes first (StandingRank, RELIEF_STEP
--   apart); the others hear him and follow (AdoptRemote, relief), or yield to him as the elder;
-- - never over a Barricade (its longer hold belongs to the wave it was raised against).
-- Only between members of a group: nobody else hears the ticks that say a timer goes down.
local STAND_GAP = 2.5
local RELIEF_SILENCE, RELIEF_STEP, RELIEF_MAX_RANK = 16, 1.5, 4
-- A capture released by its capturer is kept that long for the turn of the last in line
-- (rank and late-comer waits, ReliefDue), then dropped.
local RELEASE_KEEP = (2 * RELIEF_MAX_RANK + 1) * RELIEF_STEP + 4
Lease.RELIEF_SILENCE, Lease.RELIEF_STEP = RELIEF_SILENCE, RELIEF_STEP
-- The rule in one switch: false, nobody's time on the point is counted, so no capture is
-- carried on (a hand-over starts from nothing, as before) and none of ours is given up to one.
Lease.RELIEF_ON = true
-- Counted since login, for the network report (ZoneDefense:GetDiagnostics): captures of ours
-- given to an elder one of the point, captures carried on by us, captures of ours carried on.
Lease.stats = Lease.stats or { yielded = 0, relieved = 0, handedOn = 0 }

function Lease:NoteStanding(zone)
    if not zone or not self.RELIEF_ON then return end
    local now = GetTime()
    if not zone._standSince or now - (zone._standSeenAt or 0) > STAND_GAP then zone._standSince = now end
    zone._standSeenAt = now
end

function Lease:StandingSeconds(zone)
    local now = GetTime()
    if not self.RELIEF_ON or not zone or not zone._standSince or now - (zone._standSeenAt or 0) > STAND_GAP then return nil end
    return math.max(0, now - zone._standSince)
end

-- A word of the wave we follow came from its capturer himself (Sync, after AdoptRemote).
-- away: he says he is off the point (the state's seventh field, Sync BroadcastZoneState).
-- Only a word newer than the last one counts: a copy of the same state (a witness whisper, his
-- answer to a map request, which says nothing of "away") is neither a tick nor news.
function Lease:NoteFirstHand(zone, away)
    local remote = zone and zone._remoteCaptureLease
    if not remote then return end
    local ts = tonumber(remote.lastRemoteTs) or 0
    if remote.firstHandTs and ts <= remote.firstHandTs then return end
    remote.firstHandTs = ts
    remote.firstHandAt = GetTime()
    remote.firstHandTicks = (remote.firstHandTicks or 0) + 1
    remote.away = away == true or nil
end

local function GroupUnitName(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    if Overlord.SafeGetUnitName then return Overlord:SafeGetUnitName(unit, true) end
    if type(GetUnitName) == "function" then return GetUnitName(unit, true) end
    return type(UnitName) == "function" and UnitName(unit) or nil
end

-- The unit of our party or raid that bears this name, if any.
local function CapturerGroupUnit(name)
    local wanted = CanonicalPlayer(name)
    if not wanted or type(UnitExists) ~= "function" or type(UnitIsPlayer) ~= "function" then return nil end
    local units = (type(IsInRaid) == "function" and IsInRaid()) and findCapturerRaidUnits or findCapturerPartyUnits
    for i = 1, #units do
        local ok, unitName = pcall(GroupUnitName, units[i])
        if ok and unitName and CanonicalPlayer(unitName) == wanted then return units[i] end
    end
    return nil
end
-- (2.5.0: never the partner of a layer change, grouped with us for a few seconds: LayerJumper.)
function Lease:IsGroupMember(name)
    if CapturerGroupUnit(name) == nil then return false end
    local jumper = Overlord.LayerJumper
    return not (jumper and jumper.IsHopPartner and jumper:IsHopPartner(name))
end

-- Does the game itself show this member of our group off the point? true: dead, a ghost,
-- disconnected, or standing outside the disc; false: his position is inside it (he stands
-- there, seen or not: another layer keeps the coordinates); nil: no position to judge by.
local function GroupUnitOffDisk(unit, zone)
    if type(UnitIsConnected) == "function" and UnitIsConnected(unit) == false then return true end
    if type(UnitIsDead) == "function" and UnitIsDead(unit) then return true end
    if type(UnitIsGhost) == "function" and UnitIsGhost(unit) then return true end
    local mapID = zone and zone.center and zone.radius and ResolveZoneMapID(zone) or nil
    if not mapID or not C_Map or type(C_Map.GetPlayerMapPosition) ~= "function" then return nil end
    local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, unit)
    if not okPos or not pos then return nil end
    findCapturerZone = zone
    local okInside, inside = pcall(FindCapturerUnitInsideDisk, pos)
    if not okInside then return nil end
    return not inside
end

function Lease:ShouldRelieve(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or zone.holdAuthorityLocal or remote.owner ~= Overlord.PlayerFaction then return false end
    if LeaseUnderBarrier(zone, remote) then return false end
    -- Its capturer released it himself and we were not the first in line (ReceiveRelease).
    if remote.releasedAt then return true end
    local heard = tonumber(remote.firstHandAt)
    -- (His last word must be his own, and not the first: a start alone says nothing of ticks.)
    if not heard or (remote.firstHandTicks or 0) < 2 or heard < (remote.lastSeen or 0) - 0.5 then return false end
    local silent = GetTime() - heard
    local saysAway = remote.away == true and silent < RELIEF_FRESH
    if not saysAway and silent < RELIEF_SILENCE then return false end
    local unit = CapturerGroupUnit(remote.originName)
    if not unit then return false end
    local off = GroupUnitOffDisk(unit, zone)
    -- He says he is away: unless the game shows him standing on the disc. Silent: only when
    -- the game shows him off it.
    if saysAway then return off ~= false end
    return off == true
end

-- Members of our group standing on the point, fit to capture, whose name comes before ours.
function Lease:StandingRank(zone)
    local sync = Overlord.Sync
    local me = CanonicalPlayer(sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil)
    local mapID = zone and zone.center and zone.radius and ResolveZoneMapID(zone) or nil
    if not me or not mapID or not C_Map or type(C_Map.GetPlayerMapPosition) ~= "function"
        or type(UnitExists) ~= "function" then return 0 end
    local units = (type(IsInRaid) == "function" and IsInRaid()) and findCapturerRaidUnits or findCapturerPartyUnits
    findCapturerMapID, findCapturerOwner, findCapturerZone = mapID, Overlord.PlayerFaction, zone
    local rank = 0
    for i = 1, #units do
        local unit = units[i]
        local okName, name = pcall(GroupUnitName, unit)
        local key = okName and CanonicalPlayer(name) or nil
        if key and key < me then
            -- (2.5.1: the position first, a few map reads; the fitness check reads the unit's
            -- state and auras, and most of a raid stands elsewhere.)
            local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, unit)
            local okInside, inside = false, false
            if okPos and pos then okInside, inside = pcall(FindCapturerUnitInsideDisk, pos) end
            if okInside and inside then
                local okEligible, eligible = pcall(FindCapturerUnitEligible, unit)
                if okEligible and eligible then
                    rank = rank + 1
                    if rank >= RELIEF_MAX_RANK then break end
                end
            end
        end
    end
    return rank
end

-- Once a second from ZoneControl while we stand on a point whose capture we follow. True when
-- its capturer gave way and our turn has come: the caller then takes it over.
function Lease:ReliefDue(zone)
    local stand = self:ShouldRelieve(zone) and self:StandingSeconds(zone) or nil
    if not stand then
        if zone then zone._reliefSince = nil end
        return false
    end
    local now = GetTime()
    zone._reliefSince = zone._reliefSince or now
    local wait = self:StandingRank(zone) * RELIEF_STEP
    -- We stood there for less time than the timer shows (we came late, or came back): taking
    -- it over would set the capture back to our own time. Whoever stood through it goes first,
    -- whatever his name; we go after the whole line if nobody did.
    local remote = zone._remoteCaptureLease
    local shown = math.min(tonumber(zone.holdTimeElapsed) or 0, (tonumber(remote and remote.tickHold) or 0) + 6)
    if stand + 3 < shown then wait = wait + (RELIEF_MAX_RANK + 1) * RELIEF_STEP end
    return now - zone._reliefSince >= wait
end

-- released: the capturer's own release handed the wave over (ReceiveRelease), else relief.
-- Returns true and the hold the capture goes on from.
function Lease:TakeOverStanding(zone, released)
    local remote = zone and zone._remoteCaptureLease
    local stand = self:StandingSeconds(zone)
    if not remote or not stand or zone.holdAuthorityLocal or remote.owner ~= Overlord.PlayerFaction
        or zone.owner ~= Overlord.PlayerFaction or zone.status ~= "in_progress"
        or LeaseUnderBarrier(zone, remote) then return false end
    released = released == true or remote.releasedAt ~= nil
    local previous = remote.originName
    -- What our screen shows of his timer, never past his last word by more than a tick.
    local shown = math.max(0, math.min(tonumber(zone.holdTimeElapsed) or 0,
        (tonumber(remote.tickHold) or 0) + 6))
    local nowWall = Overlord.ServerNow and Overlord.ServerNow() or time()
    if not self:PromoteRemoteToLocal(zone, released == true, released ~= true, nowWall - stand) then return false end
    local hold = math.floor(math.max(0, math.min(shown, stand,
        (tonumber(zone.holdTimeRequired) or BASE_HOLD_REQUIRED) - 1)))
    zone.holdTimeElapsed = hold
    zone.holdStartTime = GetTime() - hold
    zone._localCaptureOpenedAt = GetTime() - stand
    zone._reliefSince = nil
    zone.holdAuthorityLocal = true
    local sync = Overlord.Sync
    local selfName = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
    if selfName and selfName ~= "" then
        zone.zsOfficialCapturerName = selfName
        zone._zsOfficialCapturerSeenAt = GetTime()
    end
    zone.updatedAt = nowWall
    if self.stats then self.stats.relieved = self.stats.relieved + 1 end
    return true, hold, previous
end

-- The other side of a relief: we hold a capture of this point, we are not on it (gone, dead:
-- our timer goes down) and a player of our faction, heard first-hand, carries one on there.
-- Ours is over and we follow his. Its release is said to our group only (members on an older
-- version follow ours until then): further away the capture goes on, and those who follow it
-- by the clock of our start keep that clock until the relief's own word or its capture (a
-- release there would show the point free for the rest of a capture that is running).
function Lease:YieldAwayWave(zone, owner, capturerName, decision, firstHand)
    if not self.RELIEF_ON or not zone or not decision or firstHand ~= true
        or not zone.holdAuthorityLocal or not zone.isHolding or zone.status ~= "in_progress"
        or zone.owner ~= owner or owner ~= Overlord.PlayerFaction then return false end
    if zone._captureBarrierCommitted or zone._captureBarrierProposalUntil then return false end
    local sync = Overlord.Sync
    local selfKey = CanonicalPlayer(sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil)
    local own = zone._localCaptureWaveId
    if not selfKey or not own or decision.originKey == selfKey then return false end
    -- Away: not on this point, or on it without counting (dead, ghost, mounted).
    local current = Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone and Overlord.Zones:GetCurrentPlayerZone() or nil
    local here = current ~= nil and current.id == zone.id
        and not (type(UnitIsDead) == "function" and UnitIsDead("player"))
        and not (type(UnitIsGhost) == "function" and UnitIsGhost("player"))
        and not (Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync
            and Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync())
    if here then return false end
    -- A relief only (it says so in its id), by a member of our group. Any other capture of the
    -- point (a guild mate's on another layer, begun while we were off ours for a moment) is
    -- not carrying ours on: ours stays ours to come back to, as it always did.
    if not IsReliefWave(decision.waveId) or not Lease:IsGroupMember(capturerName) then return false end
    local nowWall = Overlord.ServerNow and Overlord.ServerNow() or time()
    local began = WaveBeganAt(decision.waveId)
    if began > nowWall + 5 or began < nowWall - 3600
        or (tonumber(decision.hold) or 0) > nowWall - began + 15 then return false end
    if IsTombstoned(zone.id, decision.originKey, decision.waveId, decision.ts) then return false end
    local base = zone._localCaptureBase and CopySnapshot(zone._localCaptureBase) or nil
    local openedAt = zone._localCaptureOpenedAt
    local release = self:SnapshotLocalRelease(zone)
    zone.holdAuthorityLocal = nil
    zone._localCaptureWaveId = nil
    if not self:AdoptRemote(zone, owner, capturerName, decision, base) then
        zone.holdAuthorityLocal, zone._localCaptureWaveId, zone._localCaptureOpenedAt = true, own, openedAt
        return false
    end
    if release and release.payload and sync.SendToGroup then
        pcall(sync.SendToGroup, sync, "ZR", release.payload)
    end
    PutTombstone(zone.id, selfKey, own)
    zone._localCaptureOpenedAt, zone._localCaptureBase, zone._captureReleaseSentWave = nil, nil, nil
    ClearLocalWaveEphemera(zone)
    local remote = zone._remoteCaptureLease
    local hold = tonumber(remote and remote.tickHold) or tonumber(decision.hold) or 0
    zone.holdTimeElapsed = hold
    zone.holdTimeRequired = tonumber(remote and remote.effectiveRequired) or zone.holdTimeRequired
    zone.holdStartTime = nil
    zone.isHolding, zone.isContested, zone.isPaused = false, false, false
    zone.zsOfficialCapturerName = capturerName
    zone._zsOfficialCapturerSeenAt = GetTime()
    zone.updatedAt = math.max(tonumber(zone.updatedAt) or 0, tonumber(decision.ts) or 0)
    if self.stats then self.stats.handedOn = self.stats.handedOn + 1 end
    TrackLeaseZone(zone)
    RefreshVisuals()
    return true
end

-- Une finale directe ne doit pas annuler une Barricade que ce client a lui-meme
-- consommee. L'autorite locale sur le requis prolonge exige aussi que le flux ait
-- reellement approche ce seuil.
function Lease:FinalSatisfiesLocalRequirement(zone, owner, originName, waveId, finalRequirement)
    local remote = zone and zone._remoteCaptureLease
    if not remote then return true end
    local originKey, validWave = CanonicalPlayer(originName), ValidWave(waveId)
    local sameWave = owner == remote.owner and originKey == remote.originKey
        and validWave == remote.waveId
    local required = tonumber(remote.localRequired)
    if not required then
        -- No Barricade consumed here: any well-formed final ends the capture we
        -- follow, whoever signs it (1.8.2). Since 1.5.1 only the followed wave (or
        -- one relieved or timed out here) was accepted. A point taken by a group is
        -- often finished by another player than the one whose timer we follow (the
        -- first one died or stepped off, and his release did not reach us, as often
        -- across factions): his final and its retries were refused, the followed
        -- wave then timed out and the point went back to its previous owner on this
        -- map for good ("C otherCapturer" then "lease expiredWithoutFinal" in
        -- /ov network; Horde captures seen in progress, never turning red). The
        -- refusal protected nothing: with no wave followed the same final is
        -- accepted, and the capture count comes from the capturer's own total.
        if not originKey or not validWave then return false end
        -- Two finals are still refused, because they could only cancel the assault
        -- on every observer: one that names the very wave we follow for another
        -- owner (it would also close the real capturer's wave), and one that gives
        -- the point to the faction already holding it under the assault (not a
        -- capture).
        if originKey == remote.originKey and validWave == remote.waveId and owner ~= remote.owner then
            return false
        end
        -- 2.0.1: "under the assault" means an assault by the OTHER faction. A wave
        -- followed over a point that its own faction already holds on our map (we
        -- missed the enemy's capture in between; far fronts follow such a wave) ends
        -- with a real capture: its final was refused here, the point kept its old
        -- date on every far observer, and their maps then differed by one date from
        -- everyone else's (a whole map pulled by each of them).
        local base = remote.base
        if type(base) == "table" and base.owner ~= nil and owner == base.owner
            and owner ~= remote.owner then return false end
        return true
    end
    if not sameWave then return false end
    if tonumber(finalRequirement) ~= required then return false end
    local now = GetTime()
    local observedDuration = (now - (remote.openedAt or now))
        + math.max(0, tonumber(remote.openedHold) or 0)
    -- Le dernier tick recu date de remote.lastSeen ; le maintien a continue depuis.
    -- Un observateur de l'autre faction ne recoit un tick que toutes les 15 a 60 s
    -- (pont Battle.net) : exiger lastHold brut manquait la fenetre finale et la
    -- capture ennemie restait orange (jamais rouge). Projeter le maintien jusqu'a
    -- maintenant, borne par la duree reellement observee.
    local projectedHold = (tonumber(remote.lastHold) or 0)
    if remote.lastSeen then
        projectedHold = math.min(projectedHold + math.max(0, now - remote.lastSeen),
            math.max(projectedHold, observedDuration))
    end
    return projectedHold >= required - 10
        and observedDuration >= required - 15
end

-- 2.1.1: on a refused channel the guild hears one copy of a capture and those holding others keep
-- quiet, so a co-capturer holding a separate wave (anyone who stepped on the point before the
-- start could be heard) would refuse it, and lose the point on leaving before that wave's timer
-- ended. A capture of the point by our own side, said there by its author and dated since our
-- wave opened, ends our wave too. No other copy of it: anybody can write one, with any name.
function Lease:GuildFinalEndsLocalWave(zone, owner, ts)
    local guild = Overlord.GuildLane
    if owner ~= zone.owner or not guild or not guild:HeardFromAuthor() then return false end
    local openedAt, dated = tonumber(zone._localCaptureOpenedAt), tonumber(ts)
    if not openedAt or not dated then return false end
    local nowWall = Overlord.ServerNow and Overlord.ServerNow() or time()
    return dated >= nowWall - (GetTime() - openedAt) - GUILD_FINAL_SLACK
end

function Lease:ShouldRejectFinal(zone, originName, waveId, owner, ts)
    if not zone then return true end
    local originKey = CanonicalPlayer(originName)
    local validWave = ValidWave(waveId)
    if not originKey or not validWave then return true end
    if zone._captureFinalUnattested
        and zone._captureFinalUnattestedOriginKey == originKey
        and zone._captureFinalUnattestedWaveId == validWave then
        return false
    end
    if zone.holdAuthorityLocal and zone._localCaptureWaveId ~= validWave
        and not self:GuildFinalEndsLocalWave(zone, owner, ts) then return true end
    -- Une marque douce (arret faute de nouvelles, releve) ne bloque jamais une finale.
    if not IsHardTombstoned(zone.id, originKey, validWave) then return false end
    -- 1.8.2: the final of a closed wave repeats a capture already taken into account,
    -- unless it comes at a later date: then it is another capture, by the other faction or
    -- by a player of the same side finishing seconds after (every client keeps the latest
    -- date). A final accepted while another timer is followed closes that timer: when
    -- somebody else completed first and the followed player completes afterwards, that
    -- capture must still count. Only for a wave closed that way (see MarkSuperseded):
    -- never for one closed by anti-spoof or released.
    local key = LeaseKey(zone.id, originKey, validWave)
    if superseded.rows[key] == nil or superseded.rows[key] ~= tombstones[key] then return true end
    local at = tonumber(ts)
    if owner and at and zone.owner and zone.status ~= "in_progress"
        and at > (tonumber(zone.capturedTime) or 0) then return false end
    return true
end

function Lease:TombstoneFinalWave(zoneId, originName, waveId)
    local originKey = CanonicalPlayer(originName)
    local validWave = ValidWave(waveId)
    if not zoneId or not originKey or not validWave then return false end
    PutTombstone(zoneId, originKey, validWave)
    HardenSoftTombstonesForZone(zoneId)
    return true
end

function Lease:IsSoftExpired(zone)
    local remote = zone and zone._remoteCaptureLease
    return remote ~= nil and GetTime() - (remote.lastSeen or 0) >= LIVE_SILENCE
end

function Lease:IsFreshDirect(zone)
    local remote = zone and zone._remoteCaptureLease
    return remote ~= nil and zone.status == "in_progress"
        and remote.directValidated == true
        and GetTime() - (remote.lastDirectSeen or 0) < LIVE_SILENCE
end

function Lease:ExpireRemote(zone, reason)
    local remote = zone and zone._remoteCaptureLease
    if not remote or zone.holdAuthorityLocal then return false end
    if reason == "timeout" or reason == "relayedRelease" then
        -- Arret faute de nouvelles (ou relache relayee, non authentifiee) : le
        -- capteur peut continuer, ses ticks plus recents et sa finale restent acceptes.
        PutSoftTombstone(zone.id, remote.originKey, remote.waveId, remote.lastRemoteTs)
        if Overlord.Sync and Overlord.Sync.NoteEnemyCaptureLeaseEnd then
            Overlord.Sync:NoteEnemyCaptureLeaseEnd(remote.owner,
                reason == "timeout" and "expiredWithoutFinal" or "relayedRelease")
        end
    else
        PutTombstone(zone.id, remote.originKey, remote.waveId)
    end
    RestoreSnapshot(zone, remote.base)
    -- 2.4.0: the next wave of this point is a new start for the guild (GuildLane ForgetSiege).
    if Overlord.GuildLane and Overlord.GuildLane.ForgetSiege then
        Overlord.GuildLane:ForgetSiege(zone.id, remote.waveId)
    end
    -- 2.2.0: how it ended, for SyncDirectory:PullAfterWave.
    remote.endedBy = reason
    zone._remoteCaptureLease = nil
    ClearTransient(zone)
    zone._remoteLeaseExpiredReason = reason
    -- 2.4.0: and when (ZoneDefense: a capture on hold waits a moment after a silent end).
    zone._remoteLeaseExpiredAt, zone._remoteLeaseExpiredOwner = GetTime(), remote.owner
    if Overlord.Sync and Overlord.Sync.OnRemoteCaptureLeaseEnded then
        Overlord.Sync:OnRemoteCaptureLeaseEnded(zone.id)
    end
    ScheduleAvailabilityRefresh(zone)
    RefreshVisuals()
    TrackLeaseZone(zone)
    return true
end

-- 2.2.2: when the clock of a followed wave (the hold of its last state heard, run on) is past its
-- requirement and a grace, in GetTime() seconds; nil without a clock.
local CLOCK_GRACE = 15
-- 2.4.0: how long past its clock a wave of the other faction, told live and never renewed, stays on
-- the map. Without the channel only the start and the end of a wave cross to the other faction, so
-- its clock is all we have: a capturer who steps off the point or is contested for a while finishes
-- later than that clock says. Ending the wave 15 s past it showed the point safe again, then lost
-- without a word (seen in Ashenvale, 2026-11-10). Its release or its capture still ends it at once.
local CLOCK_OVERTIME = 120
-- A capital's siege (hold of SIEGE_RETOLD_MIN or more) is told again about once a minute while it
-- runs (SyncDirectory chainShape, GuildLane Level): this long without a word after one of them
-- ends it on our map (several of them lost in a row).
local SIEGE_RETOLD_MIN, SIEGE_RETOLD_SILENCE = 300, 240
local function ClockOverAt(remote, zone)
    if not remote or not remote.tickAt then return nil end
    -- Only a lease never renewed (the late copy that opened it): a wave still ticking may be
    -- contested or paused (its hold does not run 1 s per second; a Battle.net tick comes every
    -- 15-60 s), and a capturer seen on our own disk is followed there.
    if remote.tickAt ~= remote.openedAt then return nil end
    if zone and CapturerVisibleOnLocalDisk and CapturerVisibleOnLocalDisk(zone, remote.originName, remote.owner) then
        return nil
    end
    local required = tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED
    return remote.tickAt + required + CLOCK_GRACE - (tonumber(remote.tickHold) or 0)
end

-- 2.4.0: a wave of the other faction is ended by its clock, never by silence alone: a siege of
-- eight minutes was gone from the besieged faction's map after 150 s, and its back points looked
-- free to take again. The clock runs from the last word heard of it (its start, or a later one: a
-- siege is told again along the way, SyncDirectory chainShape), with CLOCK_OVERTIME when that word
-- was live. A capturer seen on our own disk is followed there, as before.
local function EnemyClockOverAt(remote, zone)
    if not remote or not remote.tickAt or remote.owner == Overlord.PlayerFaction then return nil end
    if zone and CapturerVisibleOnLocalDisk and CapturerVisibleOnLocalDisk(zone, remote.originName, remote.owner) then
        return nil
    end
    local required = tonumber(remote.effectiveRequired) or BASE_HOLD_REQUIRED
    local renewed = remote.tickAt ~= remote.openedAt
    local over = remote.tickAt + required + ((remote.toldLive or renewed) and CLOCK_OVERTIME or CLOCK_GRACE)
        - (tonumber(remote.tickHold) or 0)
    -- A siege that was told again and then is not: given up in silence (its capturer gone
    -- without a release). Not kept to the end of its eight minutes.
    if remote.retold and required >= SIEGE_RETOLD_MIN then over = math.min(over, remote.tickAt + SIEGE_RETOLD_SILENCE) end
    return over
end

function Lease:FollowedByClock(zone)
    local remote = zone and zone._remoteCaptureLease
    return remote ~= nil and not zone.holdAuthorityLocal and EnemyClockOverAt(remote, zone) ~= nil
end

function Lease:MaybeExpire(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or zone.holdAuthorityLocal then return false end
    -- 2.4.0: released by its capturer and kept for our turn to take it over (ReceiveRelease):
    -- nobody did, we left the point.
    if remote.releasedAt and GetTime() - remote.releasedAt > RELEASE_KEEP then
        return self:ExpireRemote(zone, "release")
    end
    if ExpireUnacknowledgedBarrier(remote, GetTime()) then
        zone.holdTimeRequired = remote.effectiveRequired
        RefreshVisuals()
    end
    -- 2.1.1: told in the guild, a wave has no ticks: its silence proves nothing until its end.
    -- (Off the fronts this sweep is all there is: no observer tick runs there.)
    if Overlord.GuildLane and Overlord.GuildLane:KeepFollowing(zone) then return false end
    local silence = GetTime() - (remote.lastSeen or 0)
    local enemyOver = EnemyClockOverAt(remote, zone)
    if enemyOver then
        if GetTime() < enemyOver or silence < SOFT_TTL then return false end
    elseif silence < HARD_TTL then
        -- 2.2.2: past its clock a wave nobody renews is over; waiting HARD_TTL more left finished
        -- sieges on the map for minutes (a copy told late opens a lease that nothing ends).
        local over = ClockOverAt(remote, zone)
        if not (over and silence >= SOFT_TTL and GetTime() >= over) then return false end
    end
    return self:ExpireRemote(zone, "timeout")
end

function Lease:Complete(zone)
    if not zone then return end
    HardenSoftTombstonesForZone(zone.id)
    local remote = zone._remoteCaptureLease
    if remote then
        PutTombstone(zone.id, remote.originKey, remote.waveId)
        if remote.originKey and remote.waveId then
            MarkSuperseded(LeaseKey(zone.id, remote.originKey, remote.waveId))
        end
        ClearTransient(zone)
        if Overlord.GuildLane then Overlord.GuildLane:NoteWaveClosed(zone.id, remote) end
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
        -- ait reconstruit InActiveFront : le ZR critique part toujours sur le relais.
        relay = true,
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
    if snapshot.relay then
        -- Envoi relais synchrone : la file normale peut etre suspendue quelques
        -- millisecondes plus tard par l'entree en instance.
        if sync.SendReleaseImmediate
            and (tonumber(sync:SendReleaseImmediate("ZR", snapshot.payload)) or 0) > 0 then
            emitted = true
        end
        -- Diffusion relais ordinaire en plus ; ReceiveRelease est idempotent.
        if sync.BroadcastToRelay
            and (tonumber(sync:BroadcastToRelay("ZR", snapshot.payload)) or 0) > 0 then
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
    -- A release relayed for its origin (the name was written by a gateway, not
    -- authenticated by WoW or Battle.net) ends the orange state like a silence: only
    -- a soft mark, so the origin's later ticks and final stay accepted. A hard mark
    -- let one forged release make the genuine final of that wave refused everywhere.
    local relayed = sync.IsUnauthenticatedRelayOrigin ~= nil
        and sync:IsUnauthenticatedRelayOrigin(sender) == true
    local remote = zone._remoteCaptureLease
    local following = remote ~= nil and remote.originKey == originKey and remote.waveId == waveId
    if relayed and following and remote.guildAuthor then return false end
    -- 2.4.0: a wave of this point is over (its state may have ended our view of it before this
    -- release came): the next one is told as a new start (GuildLane ForgetSiege).
    if Overlord.GuildLane and Overlord.GuildLane.ForgetSiege then
        Overlord.GuildLane:ForgetSiege(zoneId, waveId)
    end
    if relayed then
        -- Dated from its arrival, not from the last tick seen: a release jumps the
        -- queues (terminal first, priority token), so a tick it overtook is older than
        -- this and stays blocked instead of reopening the wave for 150 s. The origin's
        -- next ticks are newer and still pass (a forged release cannot end a live wave).
        -- Not put while an ally on the point keeps that wave first-hand (below): the
        -- mark would refuse the kept wave's Barricade too.
        local keptFirstHand = following and zone.isHolding and zone.owner == Overlord.PlayerFaction
            and self:IsFreshDirect(zone)
        if not keptFirstHand then
            local arrived = math.floor(tonumber(Overlord.ServerNow and Overlord.ServerNow() or time()) or 0)
            PutSoftTombstone(zoneId, originKey, waveId,
                math.max(following and tonumber(remote.lastRemoteTs) or 0, arrived))
        end
    else
        PutTombstone(zoneId, originKey, waveId)
    end
    -- 2.4.0: one timer per point (YieldToElderWave). The wave we follow may be one that gave way
    -- in silence to this elder one of its faction: the elder's release ends ours too, or a wave
    -- nobody holds stayed on the map to the end of its clock.
    -- Only that case: began within SAME_START seconds of it, and never heard again since its
    -- start (a wave that ticks, a takeover, a capture of the other faction begun later are alive).
    -- (Nor a relief: the wave it relieved is released as it gives way, YieldAwayWave.)
    if not following and remote and not zone.holdAuthorityLocal and remote.tickAt == remote.openedAt
        and not remote.relievedKey and not IsReliefWave(remote.waveId)
        and IsElderWave(waveId, originKey, remote.waveId, remote.originKey)
        and WaveBeganAt(remote.waveId) - WaveBeganAt(waveId) <= SAME_START then
        return self:ExpireRemote(zone, "relayedRelease")
    end
    if following then
        -- Un co-capteur allie deja physiquement sur le disque reprend la vague
        -- avec un nouvel id local au lieu de perdre tout le progres.
        if zone.isHolding and zone.owner == Overlord.PlayerFaction then
            -- Only the origin's own release hands a fresh first-hand wave over at once.
            -- 2.4.0: from the time we stood there ourselves, when we did (TakeOverStanding), and
            -- one player at a time: everybody standing on the point took the capture over in
            -- the same second, each with a timer of his own. The first in line takes it now;
            -- the others keep the released capture on screen for their turn (ReliefDue), follow
            -- him as soon as they hear him (AdoptRemote, relief), and let it go after that.
            local stood = not relayed and self:StandingSeconds(zone) or nil
            if stood then
                -- (Or we stood there for less time than the timer shows: see ReliefDue.)
                local shown = math.min(tonumber(zone.holdTimeElapsed) or 0, (tonumber(remote.tickHold) or 0) + 6)
                if not LeaseUnderBarrier(zone, remote) and (self:StandingRank(zone) > 0 or stood + 3 < shown) then
                    remote.releasedAt = GetTime()
                    TrackLeaseZone(zone)
                    return true
                end
                if self:TakeOverStanding(zone, true) then
                    if sync.BroadcastZoneState then sync:BroadcastZoneState(zone, true) end
                    return true
                end
            end
            local takeoverWave = self:PromoteRemoteToLocal(zone, not relayed)
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
        return self:ExpireRemote(zone, relayed and "relayedRelease" or "release")
    end
    return true
end

-- Tests only: is this wave blocked (hard or soft mark, ts nil = any tick)?
function Lease._IsTombstoned(zoneId, originKey, waveId, ts)
    return IsTombstoned(zoneId, originKey, waveId, ts)
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
                zone.updatedAt = (Overlord.ServerNow and Overlord.ServerNow() or time())
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
        or math.abs((Overlord.ServerNow and Overlord.ServerNow() or time()) - (tonumber(issuedAt) or 0)) > 120 then return false end
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
    zone.updatedAt = math.max((Overlord.ServerNow and Overlord.ServerNow() or time()), (tonumber(zone.updatedAt) or 0) + 1)
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
    zone.updatedAt = (Overlord.ServerNow and Overlord.ServerNow() or time())
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
    zone.updatedAt = math.max((Overlord.ServerNow and Overlord.ServerNow() or time()), (tonumber(zone.updatedAt) or 0) + 1)
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
        local enemyOver = EnemyClockOverAt(remote, zone)
        local over = not enemyOver and ClockOverAt(remote, zone) or nil
        if enemyOver then
            -- 2.4.0: the clock alone ends it (MaybeExpire), however long the silence.
            deadline = math.max(enemyOver, (tonumber(remote.lastSeen) or 0) + SOFT_TTL)
        elseif over then
            deadline = math.min(deadline, math.max(over, (tonumber(remote.lastSeen) or 0) + SOFT_TTL))
        end
        if not remote.barrierCommitted and remote.barrierProposalUntil then
            deadline = math.min(deadline, tonumber(remote.barrierProposalUntil) or deadline)
        end
        -- 2.4.0: released and kept for our turn (ReceiveRelease): dropped when that time is up.
        if remote.releasedAt then
            deadline = math.min(deadline, remote.releasedAt + RELEASE_KEEP + 0.5)
        end
    end
    if not zone._captureBarrierCommitted and zone._captureBarrierProposalUntil then
        local localDeadline = tonumber(zone._captureBarrierProposalUntil) or now
        deadline = deadline and math.min(deadline, localDeadline) or localDeadline
    end
    return deadline or now
end

local function SweepOneLease(zoneId, zone)
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
    -- (2.2.2: one zone's error no longer leaves the sweep marked running for the session,
    -- every remote lease then waiting for a /reload to expire; a zone that keeps failing is
    -- looked at again in 5 s, not at once.)
    local failed = false
    for zoneId, zone in pairs(activeLeaseZones) do
        if not pcall(SweepOneLease, zoneId, zone) then failed = true end
    end
    leaseMaintenanceRunning = false
    ScheduleLeaseMaintenance(failed and 5 or nil)
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
