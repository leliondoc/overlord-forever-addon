-- SyncAux.lua - Mines (MS/MN), whispers communaute, appel de faction (FC),
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
TUNING.LB_CLASS_REFRESH_FROM_NP_INTERVAL = 2
TUNING.PERIODIC_SYNC_INTERVAL = 30

local L = Overlord.L


local lastStaleObserverPoll = 0
local STALE_OBSERVER_POLL_INTERVAL = 22
local STALE_OBSERVER_POLL_INTERVAL_LARGE = 32
local STALE_CAPITAL_OBSERVER_POLL_INTERVAL = 55
local lastObserverFinalStatePoll = 0
local OBSERVER_FINAL_STATE_POLL_INTERVAL = 8

local CONSULT_FRONT_SR_COOLDOWN = 60
local lastConsultFrontSR = {}

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


-- Appel aux armes (1.2.1) : un appel toutes les 4 h pour toute la faction, depuis un front.
local FC_COOLDOWN_FACTION = 4 * 3600
local FC_COOLDOWN_RECV = 600
local FC_COOLDOWN_EPOCH_MIN = 1000000000


-- Heure serveur : le delai partage est compare entre clients dont l'horloge PC differe.
local function FactionCallCooldownNow()
    if GetServerTime then return math.floor(tonumber(GetServerTime()) or time()) end
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
function Overlord.Sync:SendTargetedObserverMapRequest(zone, payload)
    local remote = zone and zone._remoteCaptureLease
    local origin = remote and remote.originName or (zone and zone.lastZSSender)
    local beta = Overlord.BetaNetwork
    if not origin or not payload or payload == "" or not beta or not beta.IsPeer
        or not beta:IsPeer(origin) or not self.SendWhisper
        or not self.IsValidWhisperTarget or not self:IsValidWhisperTarget(origin)
        or (self.ForeverIdentitiesMatch and self:ForeverIdentitiesMatch(
            origin, self:GetPlayerFullName())) then return false end
    return self:SendWhisper("SR", payload, origin) == true
end

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
    -- Gros event : le relais n'envoie un tick que toutes les 60 s et le bail tolere
    -- 75 s de silence. Sonder des 32 s faisait demander l'etat a chaque observateur
    -- relais, a chaque cycle (300 observateurs d'un siege = ~5 SR/s sur le capteur).
    if isLarge and zone and zone._remoteCaptureLease then
        pollInterval = math.max(pollInterval, 75)
    end
    if Overlord.InstanceSuspended or not secondsSinceZs or secondsSinceZs < pollInterval then return end
    local now = GetTime()
    if now - lastStaleObserverPoll < pollInterval then return end
    lastStaleObserverPoll = now
    local payload = self.GetSRPayload and self:GetSRPayload("T")
    if payload then self:SendTargetedObserverMapRequest(zone, payload) end
    self:SendSyncRequest({
        criticalChannel = true,
    })
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
    local remote = zone._remoteCaptureLease
    local nearExpectedFinish = remote and remote.lastHold
        and remote.lastHold >= req - 5
        and GetTime() - (remote.lastSeen or GetTime())
            >= math.max(0, req - remote.lastHold)
    if math.max(elapsed or 0, stored) < req and not nearExpectedFinish then
        zone._observerFinalStatePollCount = nil
        return
    end
    if Overlord.InstanceSuspended then return end

    local now = GetTime()
    if now - (zone._observerFinalStatePollAt or 0) < OBSERVER_FINAL_STATE_POLL_INTERVAL then return end
    if now - lastObserverFinalStatePoll < OBSERVER_FINAL_STATE_POLL_INTERVAL then return end

    -- Quatre demandes au plus par fin attendue : au-dela, la finale arrive par le
    -- relais ou le rattrapage de carte (bail tenu 150 s), sans relance en boucle.
    if (zone._observerFinalStatePollCount or 0) >= 4 then return end
    zone._observerFinalStatePollAt = now
    lastObserverFinalStatePoll = now
    zone._observerFinalStatePollCount = (zone._observerFinalStatePollCount or 0) + 1

    local payload = self.GetSRPayload and self:GetSRPayload("T")
    if not payload or payload == "" then return end

    -- At 100% (or a near-final stale heartbeat), ask the known origin first.
    -- The read-only request never grants capture authority.
    self:SendTargetedObserverMapRequest(zone, payload)
    self:Send("SR", payload)
    if IsInRaid() or IsInGroup() then
        self:SendToChannel("SR", payload, true)
    end

    if Overlord.InActiveFront then
        self:BroadcastToRelay("SR", payload)
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
    local age = (Overlord.ServerNow and Overlord.ServerNow() or time()) - (tonumber(zone.updatedAt) or 0)
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
    local last = lastConsultFrontSR[frontId] or 0
    -- 0 signifie "jamais envoye", pas "envoye au chargement": sinon le consult
    -- differe a t<60 s serait consomme sans transport apres la barriere.
    if last > 0 and now - last < CONSULT_FRONT_SR_COOLDOWN then return end
    lastConsultFrontSR[frontId] = now
    self:SendSyncRequest({
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

-- Share of clients that emit a ZA per window. The fixed 12-25 % made the number of
-- snapshots grow with the crowd (about one full map per second received at 500
-- players, each re-parsed by every client). Aim for about five senders per window
-- whatever the population, never above the configured share.
function Overlord.Sync:ControlledZaElectionPct(opts, isLarge)
    local pct = opts.electionPct
        or (isLarge and (opts.largeElectionPct or 12) or (opts.smallElectionPct or 100))
    local net = Overlord.BetaNetwork
    local population = net and net.CountDirectPeers and net:CountDirectPeers() or 0
    if population > 5 then
        pct = math.min(pct, math.max(2, math.ceil(500 / population)))
    end
    return pct
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
        local pct = self:ControlledZaElectionPct(opts, isLarge)
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
            local pct = Overlord.Sync:ControlledZaElectionPct(opts, isLarge)
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
    -- MS ne porte ni campagne ni date : un stock de la semaine passee, relaye ou envoye
    -- par un client en retard de reset, viderait les mines neuves. Ignore pendant les
    -- premieres minutes de campagne (TTL du relais 120 s + marge).
    local start = Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs() or 0
    local serverNow = Overlord.ServerNow and Overlord.ServerNow() or time()
    if start > 0 and serverNow - start < 180 then return end
    if Overlord.Ressources and Overlord.Ressources.ApplyRemoteMineStock then
        Overlord.Ressources:ApplyRemoteMineStock(mineId, stockStr)
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
        self:BroadcastToRelay("MN", payload, nil, nil, nil, extraWhispers)
        self:SendToBNetFriends("MN", payload)
        if extraWhispers and extraWhispers[1] and extraWhispers[1].payload ~= "" then
            self:SendToBNetFriends(extraWhispers[1].type, extraWhispers[1].payload)
        end
    end
end


-- Pairs Overlord vus recemment sur le relais.
function Overlord.Sync:GetRelayPeers()
    return Overlord.BetaNetwork and Overlord.BetaNetwork:GetPeers() or {}
end



-- Expediteur dont WoW ou Battle.net a authentifie le nom : membre du groupe, ou
-- paquet recu de son auteur lui-meme (canal, whisper, BNet, dispatch relais a 0 saut).
-- Une origine relayee est ecrite par la passerelle et peut etre n'importe quel nom :
-- elle ne suffit jamais a appliquer une victoire (TV) ni un bonus historique (VB).
-- A ne pas confondre avec IsKnownRelayPeer, qui repond seulement
-- "ce nom est un client Overlord vu recemment".
function Overlord.Sync:IsAuthenticatedDirectSender(sender)
    if not sender or sender == "" then return false end
    local net = Overlord.BetaNetwork
    -- Une origine relayee d'abord : un nom de membre du groupe ecrit par une
    -- passerelle n'est pas ce membre.
    if net and net.IsDispatching and net:IsDispatching(sender) then
        return not (net.IsRelayedOrigin and net:IsRelayedOrigin(sender))
    end
    return true
end

-- "Ce nom est un client Overlord entendu dans les 300 s" (route relais connue).
-- Ce n'est PAS une authentification : voir IsAuthenticatedDirectSender.
function Overlord.Sync:IsKnownRelayPeer(sender)
    local net = Overlord.BetaNetwork
    return net ~= nil and net:IsPeer(sender) == true
end

local function BroadcastViaBeta(msgType, payload, extras)
    if not Overlord.BetaNetwork then return 0 end
    return Overlord.BetaNetwork:Broadcast(msgType, payload or "", extras) or 0
end


-- Diffusion a tous les clients Overlord par le relais (canal de faction, groupe,
-- ponts Battle.net vers l'autre faction). Les payloads "extras" partent dans le
-- meme ordre (TV puis VB). Les anciens parametres de fan-out (max, delai, force)
-- sont acceptes et ignores.
function Overlord.Sync:BroadcastToRelay(msgType, payload, _, _, _, extras)
    return BroadcastViaBeta(msgType, payload, extras)
end

-- Message adresse aux joueurs nommes, par le relais (route connue exigee quand
-- knownPeersOnly : une revalidation de guilde ne cherche pas un joueur hors ligne).
function Overlord.Sync:SendToNamedPeers(msgType, payload, contributorNames, _, _, knownPeersOnly)
    local net = Overlord.BetaNetwork
    if not net then return 0 end
    local sent = 0
    for i, name in ipairs(contributorNames or {}) do
        if i > 12 then break end
        if not knownPeersOnly or net:IsPeer(name) then
            if net:Send(msgType, payload, name) then sent = sent + 1 end
        end
    end
    return sent
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
    if item.relayWide and Overlord.Sync.BroadcastToRelay then
        Overlord.Sync:BroadcastToRelay("LR", item.payload)
    end

    if #leaderboardRaceQueue > 0 then
        leaderboardRacePumpScheduled = true
        C_Timer.After(LEADERBOARD_RACE_GAP, PumpLeaderboardRaceQueue)
    end
end

function Overlord.Sync:EnqueueLeaderboardRaceBroadcast(payload, relayWide, sendChannel)
    if not payload or payload == "" or Overlord.InstanceSuspended then return false end
    local subject = payload:match("^([^:]+)")
    if not subject or subject == "" then return false end

    for i = #leaderboardRaceQueue, 1, -1 do
        local queued = leaderboardRaceQueue[i]
        if queued and queued.subject == subject then
            queued.payload = payload
            queued.relayWide = relayWide == true
            queued.sendChannel = sendChannel == true
            return true
        end
    end
    if #leaderboardRaceQueue >= LEADERBOARD_RACE_QUEUE_MAX then return false end

    leaderboardRaceQueue[#leaderboardRaceQueue + 1] = {
        subject = subject,
        payload = payload,
        relayWide = relayWide == true,
        sendChannel = sendChannel == true,
    }
    if not leaderboardRacePumpScheduled then
        leaderboardRacePumpScheduled = true
        C_Timer.After(0, PumpLeaderboardRaceQueue)
    end
    return true
end

-- Relais communauté Général de faction (same-faction, cache TTL long, exclusion groupe).

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
    -- Un appel lance avant le reset hebdomadaire (relaye en retard) ne bloque pas la
    -- nouvelle campagne.
    local start = Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs() or 0
    if start > 0 and NormalizeFactionCallTimestamp(t) < start then return end
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

-- Canal Overlord de la faction (tous les joueurs Overlord du royaume) + relais (amis
-- Battle.net, multi-sauts) + groupe. Plus de communaute ni de condition d'ennemis.
function Overlord.Sync:BroadcastFactionCall(payload)
    if not payload or payload == "" then return 0 end
    if Overlord.InstanceSuspended or IsInInstance() then return 0 end
    if not Overlord.InActiveFront then return 0 end
    if self:GetFactionCallCooldownRemaining() > 0 then return 0 end
    if not Overlord.PlayerFaction then return 0 end
    local sent = BroadcastViaBeta("FC", payload)
    if self:SendToChannel("FC", payload) then sent = sent + 1 end
    if (IsInRaid() or IsInGroup()) and self:SendToGroup("FC", payload) then sent = sent + 1 end
    if sent > 0 then self:SetFactionCallSharedCooldown(FactionCallCooldownNow()) end
    return sent
end

function Overlord.Sync:ResolveFactionCallPlace(zoneId, frontId)
    local zoneName = ""
    if zoneId and zoneId ~= "" then
        -- The call may be for another front than the one shown here: look in every
        -- front, then the translated names; never print the raw id
        -- ("redridge_three_corners" -> "Three Corners").
        local z = Overlord.Zones and Overlord.Zones:GetZone(zoneId)
        if not z and Overlord.Fronts and Overlord.Fronts.GetZone then
            z = Overlord.Fronts:GetZone(zoneId)
        end
        zoneName = (z and z.name) or (L.ZONE_NAMES and L.ZONE_NAMES[zoneId]) or ""
        if zoneName == "" then
            local words = {}
            local raw = zoneId:gsub("^[^_]+_", "", 1)
            for word in raw:gmatch("[^_]+") do
                words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
            end
            zoneName = table.concat(words, " ")
        end
    end
    local frontName = ""
    if frontId and frontId ~= "" and Overlord.Fronts then
        local front = Overlord.Fronts:GetFront(frontId)
        frontName = (front and front.mapName) or ""
        if frontName == "" then
            local words = {}
            for word in frontId:gmatch("[^_]+") do
                words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2)
            end
            frontName = table.concat(words, " ")
        end
    end
    return zoneName, frontName
end

-- 1.4.1 diagnostics: enemy capture finals (C, ZS captured) that reached this client,
-- by outcome. Live report: Horde captures seen in progress but not turning red on
-- Alliance maps. Counters only: no message sent, no behaviour change.
function Overlord.Sync:NoteEnemyCaptureFinal(faction, kind, outcome)
    if faction ~= "Alliance" and faction ~= "Horde" or faction == Overlord.PlayerFaction then return end
    local stats = self._enemyFinalStats
    if not stats then
        stats = {}
        self._enemyFinalStats = stats
    end
    local key = kind .. " " .. outcome
    stats[key] = (stats[key] or 0) + 1
end

-- Captures ennemies vues en cours puis terminees sans finale chez nous : expirees
-- faute de nouvelles, ou fermees par une carte globale. Meme tableau, compteurs seuls.
function Overlord.Sync:NoteEnemyCaptureLeaseEnd(faction, outcome)
    self:NoteEnemyCaptureFinal(faction, "lease", outcome)
end

function Overlord.Sync:GetEnemyCaptureFinalDiagnostics()
    local stats = self._enemyFinalStats
    if not stats or next(stats) == nil then return "Enemy capture finals: none received yet." end
    local keys = {}
    for key in pairs(stats) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. " " .. stats[key] end
    return "Enemy capture finals (C / ZS captured / lease end): " .. table.concat(parts, ", ") .. "."
end

-- Message chat de victoire totale, avec le front concerne quand il est connu.
function Overlord.Sync:FormatTotalVictoryMessage(factionName, frontId)
    local known = frontId and frontId ~= "" and Overlord.Fronts and Overlord.Fronts.GetFront
        and Overlord.Fronts:GetFront(frontId)
    local frontName = known and select(2, self:ResolveFactionCallPlace("", frontId)) or ""
    if frontName ~= "" and L.TOTAL_VICTORY_FRONT_MSG then
        return string.format(L.TOTAL_VICTORY_FRONT_MSG, factionName, frontName)
    end
    return string.format(L.TOTAL_VICTORY_MSG, factionName)
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
    local lastFromSender = p.fcRecvLast[senderKey]
    if lastFromSender and lastFromSender + FC_COOLDOWN_RECV > now then return end
    -- Un seul appel par delai de faction : les copies canal/relais du meme appel, et tout
    -- appel envoye pendant le delai, sont ignores.
    if self:GetFactionCallCooldownRemaining() > 0 then return end
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
    -- Alerte de raid au centre de l'ecran (comme le commandant), sans fenetre.
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r |cFFFF4444" .. msg .. "|r")
    Overlord:PrintRaidWarning(msg)
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
    -- 1.3.6: 120 s (was 18 s). Live, an error for a relay whisper still slipped through.
    return seenAt > 0 and now - seenAt <= 120
end

local function SuppressAddonWhisperOfflineSystem(_, _, msg)
    -- No addon whisper is ever sent in an instance, and there chat text can be a
    -- 12.x secret value that addon code must not read: leave every line alone.
    if Overlord.InstanceSuspended then return false end
    if issecretvalue and issecretvalue(msg) then return false end
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
        return true
    end
    -- Rafale /ov sync : masque aussi les cibles corrompues (ex. bruit API Club ')g]').
    return hasAnyRecentAddonWhisper(8)
end

function Overlord.Sync:InstallWhisperOfflineChatFilter()
    if whisperOfflineFilterInstalled then return end
    local ok = false
    -- Current clients expose the filter on ChatFrameUtil; the old global is
    -- optional. Keep the legacy path for clients with the earlier chat API.
    local add = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter
    if type(add) == "function" then
        ok = select(1, pcall(add, "CHAT_MSG_SYSTEM", SuppressAddonWhisperOfflineSystem))
    end
    if not ok and type(ChatFrame_AddMessageEventFilter) == "function" then
        ok = select(1, pcall(ChatFrame_AddMessageEventFilter,
            "CHAT_MSG_SYSTEM", SuppressAddonWhisperOfflineSystem))
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
-- Pages ZA d'un snapshot : une diffusion relais par page.
function Overlord.Sync:BroadcastZoneSnapshotPages(pages)
    local sent = 0
    for _, page in ipairs(type(pages) == "table" and pages or {}) do
        sent = sent + BroadcastViaBeta("ZA", page)
    end
    return sent
end

-- Petit fan-out synchrone reserve aux releases de bail juste avant un loading.
-- La file normale utilise C_Timer.After et peut etre suspendue avant son premier
-- item ; quelques whispers immediats donnent au ZR une vraie voie cross-faction.
-- Release de bail juste avant un chargement : envoi relais immediat (budget respecte).
function Overlord.Sync:SendReleaseImmediate(msgType, payload)
    local net = Overlord.BetaNetwork
    if msgType ~= "ZR" or not net then return 0 end
    return net:Send(msgType, payload, nil, true) and 1 or 0
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
    -- Origine relayee : nom potentiellement usurpe, ne jamais l'accumuler vers une quarantaine.
    if self:IsUnauthenticatedRelayOrigin(sender) then return false end

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
    PruneSecurityEvidenceTable(senderBroadcastHistory, ANTISPOOF_WINDOW, 32)
    PruneSecurityEvidenceTable(spoofBlacklist, ANTISPOOF_BLACKLIST_DURATION, 32)
    PruneSecurityEvidenceTable(spoofDetectedNotified, ANTISPOOF_BLACKLIST_DURATION, 32)
end

C_Timer.NewTicker(60, function()
    if Overlord.InstanceSuspended then return end
    AntiSpoofPeriodicCleanup()
end)


-- ==================== Sync Passive (hors instance) ====================
-- Ticker lent (2 min) : SR canal + scan communaute + rattrapages hors front.
-- Les snapshots ZA tous fronts passent par ScheduleControlledZoneSnapshot (election +
-- cooldown) pour eviter les rafales 40 joueurs sans laisser les observateurs attendre
-- plusieurs minutes. La domination (v2) ne passe plus par ce ticker : elle compte des
-- evenements VB rejoues par les reponses SR.
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
        -- mais les clients refuses s'arretent avant tout SR.
        local passiveBroadcaster = self.ShouldRunPassiveStateBundle
            and self:ShouldRunPassiveStateBundle()
        if not passiveBroadcaster then return end
        -- En front actif, l'election territoriale de Sync.lua couvre deja la SR.
        -- Garder ici uniquement les heartbeats held/outpost evite une seconde vague SR
        -- complete toutes les deux minutes.
        if not Overlord.InActiveFront then
            local skipDuplicateSr = Overlord.UI and Overlord.UI.IsSpectatorSyncActive
                and Overlord.UI:IsSpectatorSyncActive()
            if not skipDuplicateSr and self.SendToChannel then
                -- Rattrapage lent mais important : ne pas le laisser tomber sur budget canal sature.
                self:SendToChannel("SR", self:GetSRPayload("T"), true)
            end
            if self.ScheduleControlledZoneSnapshot then
                self:ScheduleControlledZoneSnapshot("passive", {
                    cooldown = 90,
                    electionPct = 100,
                    jitterMin = 1.0,
                    jitterMax = 5.0,
                })
            end
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
-- valeur (pas de clamp, qui figeait les injections au plafond). 10000 depuis 1.1.11 :
-- des joueurs honnetes depassaient 5000 en fin de semaine (6017) et disparaissaient
-- alors de toute la synchro. 15000 depuis 1.4.2 : sur la beta (niveau 30 maximum)
-- des honnetes approchent 6000 des le dimanche, 10000 avant le reset devenait
-- possible. Ce seuil ne change ni le nombre de lignes du classement, ni les
-- budgets/cadences de synchronisation.
local PLAUSIBLE_KILL_CEILING = 15000
-- Expose le plafond pour la defense en profondeur cote Leaderboard et Sync.
Overlord.PLAUSIBLE_SYNC_KILL_CEILING = PLAUSIBLE_KILL_CEILING
-- Forever : tous les niveaux participent. Le champ K/LK reste valide et
-- obligatoire, sans exiger le niveau maximum du client Retail ou de la beta.

-- Incident OL2 (2026-07-15) : cette ligne a injecte 480 kills. Le denylist est
-- volontairement base-name afin de couvrir toutes ses variantes Nom-Royaume et
-- d'autoriser une purge deterministe sur chaque SavedVariables deja contaminee.
local BLOCKED_KILL_CONTRIBUTOR_BASES = {
    sfvsafqw = true,
    -- 2026-10-09 : ligne injectee une seconde fois (deja retiree le 2026-09-22),
    -- refusee desormais sur toutes les campagnes.
    ["asmon gold"] = true,
}

-- Moderation d'un classement hebdomadaire precis (campaignId -> base-names). Un ancien
-- pair peut encore relayer son total maximal : la ligne reste refusee jusqu'au reset
-- suivant, puis le nom peut de nouveau etre credite normalement.
-- (La ligne retiree le 2026-09-22 avec celle-ci est refusee en permanence plus haut.)
local CAMPAIGN_KILL_ROW_REMOVALS = {
    [20260922] = {
        ["roxymigurdia greyrat"] = true,
    },
    -- 2026-10-06 : Empire Sucks (1088 VH injectes via un indice de guilde puis un LK
    -- diffuses sur le canal, guilde "EMPIRE HACKS").
    [20261006] = {
        ["empire sucks"] = true,
    },
}

function Overlord.Sync:IsDeniedKillContributor(playerName)
    if type(playerName) ~= "string" or playerName == "" then return false end
    local normalized = self.NormalizeContributorFullName
        and self:NormalizeContributorFullName(playerName) or playerName
    if type(normalized) ~= "string" or normalized == "" then return false end
    -- A name no character can have ("EMPIRE SUCKS") is never a ladder row, on every
    -- client alike; the v8 cleanup removes the copies already saved.
    if self.HasForeverNameCase and not self:HasForeverNameCase(normalized) then return true end
    local base = normalized:match("^([^%-]+)") or normalized
    local lowerBase = base:lower()
    if BLOCKED_KILL_CONTRIBUTOR_BASES[lowerBase] == true then return true end
    local campaignId = OverlordDB and tonumber(OverlordDB.campaignId)
    if not campaignId and Overlord.TimestampToCampaignId
        and Overlord.GetCurrentCampaignStartTs then
        campaignId = Overlord:TimestampToCampaignId(Overlord:GetCurrentCampaignStartTs())
    end
    local removed = campaignId and CAMPAIGN_KILL_ROW_REMOVALS[campaignId]
    return removed ~= nil and removed[lowerBase] == true
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

-- Race field of a v7 ranking page row (LK): one letter for the Classic races, the
-- file token otherwise, then the sex digit ("o2" = male orc). Fixed letters: they
-- are part of the wire format (bucket digests leave the race out).
do
    local RACE_WIRE_LETTER = { Human = "h", Dwarf = "d", NightElf = "n", Gnome = "g",
        Orc = "o", Scourge = "u", Tauren = "t", Troll = "r" }
    local RACE_WIRE_FILE = {}
    for race, letter in pairs(RACE_WIRE_LETTER) do RACE_WIRE_FILE[letter] = race end

    function Overlord.Sync:EncodeRaceWireField(raceFile, raceSex)
        local race = self:NormalizeRaceFileToken(raceFile)
        if not race or not race:match("^[A-Za-z]+$") then return nil end
        return (RACE_WIRE_LETTER[race] or race) .. tostring(normalizeRaceSexCode(raceSex))
    end

    function Overlord.Sync:DecodeRaceWireField(field)
        if type(field) ~= "string" or #field > 41 then return nil end
        local token, sex = field:match("^([A-Za-z]+)([023])$")
        if not token then return nil end
        local race = #token == 1 and RACE_WIRE_FILE[token] or self:NormalizeRaceFileToken(token)
        if not race then return nil end
        return race, tonumber(sex)
    end
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
    epoch, guild, locale, guildAt, bucketEpoch, playerLevel, raceFile, raceSex)
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
    -- Optional race + sex (13-field K, the 9.7.2 layout every client still parses):
    -- the owner's own race, sent now and then by the caller so that players who
    -- missed the weekly race beacon learn it from a kill, at ~10 bytes. Dropped
    -- first if the payload is too long.
    local raceToken = raceFile and self.NormalizeRaceFileToken and self:NormalizeRaceFileToken(raceFile)
    if raceToken and not raceToken:find(":", 1, true) then
        local sexCode = math.floor(tonumber(raceSex) or 0)
        if sexCode ~= 2 and sexCode ~= 3 then sexCode = 0 end
        local withRace = string.format("%s:%s:%s:%s:%s:%s:%s:%s:%d:%s:%d:%s:%d",
            playerName, zoneId, totalKills, class, faction, epoch, guild or "", locale or "",
            normalizeKillPayloadGuildAt(guildAt), raceToken, sexCode, bucketEpochToken, playerLevel)
        if #withRace <= MAX_KILL_PAYLOAD_BYTES then return withRace end
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

-- Origine BetaNetwork a plus d'un saut : nom ecrit par la passerelle, pas par WoW.
-- Faille exploitee jusqu'en 1.0.18 : path = "Victime,Forgeur" faisait passer un K
-- forge pour un K proprietaire (ex. Asmon Gold 4999). Aucun score ni credit ne
-- doit en dependre ; l'etat de carte reste relaye normalement.
function Overlord.Sync:IsUnauthenticatedRelayOrigin(sender)
    local net = Overlord.BetaNetwork
    return net ~= nil and net.IsRelayedOrigin ~= nil and net:IsRelayedOrigin(sender) == true
end

-- Compare sender et nom credite (canal direct). Retourne true si l'expediteur est le proprietaire.
function Overlord.Sync:KillSyncSenderOwnsPlayer(sender, playerName)
    if not sender or sender == "" or not playerName or playerName == "" then return false end
    if sender:sub(1, 5) == "BNet-" or sender:sub(1, 7) == "Bridge-" then return false end
    if self:IsUnauthenticatedRelayOrigin(sender) then return false end
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
-- Plafond par niveau (1.4.2) : 350 par niveau au-dela du premier, 2000 au moins
-- (niveau 14 : 4550, niveau 20 : 6650, plafond global des le niveau 30). La beta est
-- plafonnee au niveau 30 et des joueurs legit y approchent 6000 kills : le niveau
-- maximum garde tout le plafond global. Un personnage de niveau 14 avec 5000 kills
-- dans la semaine etait la triche observee. Le niveau voyage dans le paquet K/LK
-- lui-meme : la regle est identique chez tous les receveurs, donc sans divergence.
function Overlord.Sync:MaxPlausibleKillsForLevel(level)
    level = tonumber(level)
    if not level or level >= 30 then return PLAUSIBLE_KILL_CEILING end
    return math.min(PLAUSIBLE_KILL_CEILING, math.max(2000, (math.floor(level) - 1) * 350))
end

-- Retourne le total retenu et true s'il a ete ecrete au plafond du niveau. Au-dela
-- du plafond global (ou NaN) : nil, refuse. Le plafond par niveau ecrete au lieu de
-- refuser : tous les clients retiennent la meme valeur (le plafond), et les pages
-- et digests de l'emetteur restent identiques aux leurs.
function Overlord.Sync:SanitizeSyncedKillTotal(total, level)
    total = tonumber(total)
    if not total or total ~= total then return nil end
    total = math.floor(total)
    if total <= 0 then return 0 end
    if total > PLAUSIBLE_KILL_CEILING then
        -- Donnee refusee, mais pas de quarantaine : des joueurs legit peuvent relayer
        -- un vieux total contamine jusqu'au reset hebdomadaire.
        return nil
    end
    if level ~= nil then
        local ceiling = self:MaxPlausibleKillsForLevel(level)
        if total > ceiling then return ceiling, true end
    end
    return total, false
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
-- 8 s (was 3): the scan (~81 unit tokens, ~1-1.5 ms) ran every 3 s through any fight;
-- it only backs level/faction/guild hints when the ladder row lacks them.
local OBSERVED_UNITS_SNAPSHOT_INTERVAL = 8

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

-- Current faction for layer guidance only. Ranking metadata is a historical,
-- convergent merge (not a live roster), so it must not color live players.
-- Reuse one bounded unit snapshot for the whole list.
function Overlord.Sync:GetLivePlayerFaction(playerName)
    if Overlord.InstanceSuspended or not playerName or playerName == "" then return nil end
    local observed = self:GetObservedPlayerIdentity(playerName)
    if observed then
        if Overlord:SafeStringEquals(observed.faction, "Alliance") then return "Alliance" end
        if Overlord:SafeStringEquals(observed.faction, "Horde") then return "Horde" end
    end
    return self.GetOnlineBNetPlayerFaction and self:GetOnlineBNetPlayerFaction(playerName) or nil
end

function Overlord.Sync:IsObservedPlayerFaction(playerName, faction)
    if not playerName or (faction ~= "Alliance" and faction ~= "Horde") then return false end
    local row = self:GetObservedPlayerIdentity(playerName)
    return row and Overlord:SafeStringEquals(row.faction, faction) or false
end

function Overlord.Sync:RecordCaptureCreditProgressEvidence(sender, capturer, zoneId, faction, holdTime)
    if self:IsUnauthenticatedRelayOrigin(sender) then return end
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
    if self:IsUnauthenticatedRelayOrigin(sender) then return false end
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
-- Les snapshots territoriaux (OP/LO/LOC/ZA/ZS...) gardent leurs propres bornes.
local SCORE_BURST_TYPES = { K = true, EK = true, LK = true, LC = true, LR = true }
-- K : un proprietaire honnete emet son total au plus toutes les 30 s (trois copies
-- directes au plus) ; 8 par 5 s coupe un flood de totaux sans toucher au legitime.
local SCORE_BURST_MAX = { K = 8, EK = 40, LK = 80, LC = 80, LR = 80 }
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
    -- Cle "via:<passerelle>" (paquets relayes) : un relais honnete peut porter le
    -- flood d'un tiers ; on laisse passer quatre fois plus et on ecarte seulement
    -- l'excedent, sans jamais mettre la passerelle en quarantaine.
    if sender:sub(1, 4) == "via:" then
        return w.counts[msgType] > burstMax * 4
    end
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
