-- Zones.lua - Gestion des zones du front actif
-- Coordonnees center en % de la carte (0-100), rayon en % aussi
-- Noms localisés via Locales.lua (EN/FR/ES/DE/RU selon le client)
Overlord = Overlord or {}
Overlord.Zones = {}

local L = Overlord.L

-- Bannières Warfronts PvE (objectifs de zone, hors capitales et avant-postes).
Overlord.Zones.OBJECTIVE_NEUTRAL_ATLAS = "Warfronts-FieldMapIcons-Empty-Banner"
Overlord.Zones.OBJECTIVE_ALLIANCE_ATLAS = "Warfronts-FieldMapIcons-Alliance-Banner"
Overlord.Zones.OBJECTIVE_HORDE_ATLAS = "Warfronts-FieldMapIcons-Horde-Banner"

local function objectiveAtlasForOwner(owner)
    local Z = Overlord.Zones
    if owner == "Alliance" then return Z.OBJECTIVE_ALLIANCE_ATLAS end
    if owner == "Horde" then return Z.OBJECTIVE_HORDE_ATLAS end
    return Z.OBJECTIVE_NEUTRAL_ATLAS
end

-- Applique un atlas d'objectif Warfronts sur une texture.
function Overlord.Zones:ApplyZoneMapIcon(tex, atlas)
    if not tex or not atlas or atlas == "" or not tex.SetAtlas then return false end
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetVertexColor(1, 1, 1, 1)
    local ok, applied = pcall(tex.SetAtlas, tex, atlas, true)
    return ok and applied
end

local function capitalMainHallAtlas(zone, owner)
    local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
    if fixedOwner == "Alliance" then
        return (owner == "Horde") and "Warfronts-BaseMapIcons-Horde-MainHall"
            or "Warfronts-BaseMapIcons-Alliance-MainHall"
    elseif fixedOwner == "Horde" then
        return (owner == "Alliance") and "Warfronts-BaseMapIcons-Alliance-MainHall"
            or "Warfronts-BaseMapIcons-Horde-MainHall"
    end
    return nil
end

local function heldCapitalMainHallAtlas(zone)
    local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
    if fixedOwner == "Alliance" then
        return "Warfronts-BaseMapIcons-Alliance-MainHall"
    elseif fixedOwner == "Horde" then
        return "Warfronts-BaseMapIcons-Horde-MainHall"
    end
    return nil
end

-- Atlas icône carte / panneau zone. hideWhenContestedWithOwner=true : pas d'icône en conteste (carte).
function Overlord.Zones:GetZoneMapIconAtlas(zone, hideWhenContestedWithOwner)
    if not zone then return self.OBJECTIVE_NEUTRAL_ATLAS end

    if zone.status == "in_progress" and zone.owner then
        if hideWhenContestedWithOwner then return nil end
        if zone.isCapital then
            return capitalMainHallAtlas(zone, zone.owner)
        end
        return objectiveAtlasForOwner(zone.owner)
    end

    if zone.status == "in_progress" and not zone.owner then
        if zone.isCapital then
            return "Warfronts-BaseMapIcons-Empty-Tower"
        end
        return self.OBJECTIVE_NEUTRAL_ATLAS
    end

    if zone.owner and zone.status ~= "in_progress" then
        if zone.isCapital then
            return heldCapitalMainHallAtlas(zone) or "Warfronts-BaseMapIcons-Empty-Tower"
        end
        return objectiveAtlasForOwner(zone.owner)
    end

    -- Capitale de base sans owner encore seede (nouveau front) : MainHall faction, pas la tour vide.
    if zone.isCapital then
        return heldCapitalMainHallAtlas(zone) or "Warfronts-BaseMapIcons-Empty-Tower"
    end
    return self.OBJECTIVE_NEUTRAL_ATLAS
end

-- Capitales ennemies : timer fixe (8 min) + treve post-victoire.
local CAPITAL_HOLD_TIME = 480
local CAPITAL_VICTORY_COOLDOWN = 900 -- 15 min (anti chain-cap ; etait 30 min)
if Overlord.Fronts then
    Overlord.Fronts:Activate(Overlord.Fronts.activeFrontId)
end

-- Le flag brut reste fail-closed pour toute autorite reseau. Pour l'affichage
-- et la capture physique locale, il ne bloque que pendant la gate de login :
-- apres sync/timeout, le joueur doit retrouver available/attaque sans que son
-- ancien etat disque puisse voter, declencher une victoire ou etre relaye.
local function LoginQuarantineBlocksLocalGameplay(zone)
    if not zone or not zone._loginSyncUnconfirmed then return false end
    if Overlord.IsLoginZoneGameplayBlocked then
        return Overlord:IsLoginZoneGameplayBlocked(zone)
    end
    return true
end

-- 9.5-9.6 pouvaient conserver une capture visuelle valide dans une quarantaine
-- `_captureFinalUnattested` sans borne de liveness. Le marqueur finissait alors
-- par bloquer la chaine, les compteurs et meme l'entree physique sur une zone que
-- la carte affichait pourtant disponible. Depuis le retour au comportement 9.3.1,
-- cette quarantaine terminale n'est plus un etat de gameplay persistant.
--
-- Ce nettoyage est volontairement etroit : il ne touche ni l'etat canonique de
-- la zone, ni les tombstones de vague, ni un lease local/distant en cours. Il peut
-- donc etre applique aux anciennes SavedVariables sans simuler un reset.
local function ClearLegacyCaptureFinalQuarantine(zone)
    if not zone then return false end
    local changed = zone._captureFinalUnattested ~= nil
        or zone._captureFinalUnattestedOriginKey ~= nil
        or zone._captureFinalUnattestedWaveId ~= nil
        or zone._captureFinalUnattestedAt ~= nil
        or zone._captureFinalConfirmedBase ~= nil
    if not changed then return false end

    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    zone._captureFinalConfirmedBase = nil
    return true
end

function Overlord.Zones:MigrateLegacyCaptureFinalQuarantines(frontId)
    -- Migration one-shot session : deja faite et sans changement = skip total.
    if not frontId and self._legacyCaptureFinalQuarantinesMigrated then
        return false
    end
    local changed = false
    local seen = {}

    local function migrateZones(zones)
        for _, zone in ipairs(zones or {}) do
            if not seen[zone] then
                seen[zone] = true
                changed = ClearLegacyCaptureFinalQuarantine(zone) or changed
            end
        end
    end

    if frontId and Overlord.Fronts and Overlord.Fronts.GetFront then
        local front = Overlord.Fronts:GetFront(frontId)
        migrateZones(front and front.zones)
    elseif Overlord.Fronts and Overlord.Fronts.Registry then
        for _, front in pairs(Overlord.Fronts.Registry) do
            migrateZones(front and front.zones)
        end
    end
    -- Fallback et alias actif : ZoneDatabase peut exister sans Registry dans un
    -- test, et peut aussi pointer vers les memes objets (dedupes par `seen`).
    migrateZones(Overlord.ZoneDatabase)
    if not frontId then
        self._legacyCaptureFinalQuarantinesMigrated = true
    end
    if changed and Overlord.MarkDirty then
        Overlord:MarkDirty()
    end
    return changed
end

-- Liste des prérequis pour qu'une faction attaque / tienne une capture sur zoneId (chaîne + base ennemie).
function Overlord.Zones:GetPrereqZoneIdsForAttacker(zoneId, attackingFaction)
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local prereqs = front and front.prereqs and front.prereqs[attackingFaction]
    if prereqs then return prereqs[zoneId] end
    return nil
end

-- La faction attackingFaction peut-elle légalement poursuivre une capture sur zoneId ? (prérequis + toutes les zones si base ennemie)
function Overlord.Zones:FactionMeetsPrereqsForZoneCapture(zoneId, attackingFaction, localGameplay)
    if not zoneId or not attackingFaction then return true end
    local zone = self:GetZone(zoneId)
    if not zone then return true end

    -- Zone tenue par l'assaillant pour la chaîne globale : owner correct et pas de capture
    -- inachevée sur CETTE zone. On n'exige pas status=="captured" : UpdateAvailableZones
    -- marque souvent les zones ennemies en "locked" pour le joueur local (non attaquables
    -- pour lui), ce qui n'est pas "non tenues" par l'assaillant - sinon un client Alliance
    -- invalide les captures Horde (Prérequis perdus + ZS de revert) à tort.
    local function zoneHeldByAttacker(pz)
        local loginBlocked = pz and pz._loginSyncUnconfirmed
        if localGameplay then
            loginBlocked = LoginQuarantineBlocksLocalGameplay(pz)
        end
        return pz and pz.owner == attackingFaction and pz.status ~= "in_progress"
            and not loginBlocked
    end

    local prereqIds = self:GetPrereqZoneIdsForAttacker(zoneId, attackingFaction)
    if not prereqIds then return false end
    for _, pid in ipairs(prereqIds) do
        if not zoneHeldByAttacker(self:GetZone(pid)) then
            return false
        end
    end
    local enemyBaseId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(attackingFaction)
    if zoneId == enemyBaseId then
        for _, z in ipairs(Overlord.ZoneDatabase) do
            if z.id ~= zoneId and not zoneHeldByAttacker(z) then
                return false
            end
        end
    end
    return true
end

local cachedDisplayOrder = nil
local cachedDisplayFaction = nil
local cachedDisplayFrontId = nil
local cachedPlayerZone = nil
local cachedPlayerZoneTime = 0

-- Ordre d'affichage pour un front donne (consultation UI sans activer ce front).
function Overlord.Zones:GetDisplayOrderForFront(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front then return {} end
    local order = front.displayOrder and front.displayOrder[Overlord.PlayerFaction]
    local out = {}
    if order then
        for _, zid in ipairs(order) do
            local z = Overlord.Fronts:GetZone(zid, frontId)
            if z then
                table.insert(out, z)
            end
        end
    end
    return out
end

-- Prochaines zones a viser (toutes les branches debloquees en parallele, ex. Faldir + Haut-Perchoir).
function Overlord.Zones:GetNextObjectiveZoneIds(frontId)
    local pf = Overlord.PlayerFaction
    if not pf then return {} end
    -- Meme trêve que le gameplay : pas d'objectif HUD seulement si la carte confirme la victoire.
    if frontId and self.IsOnVictoryCooldown and select(1, self:IsOnVictoryCooldown(frontId, true)) then
        return {}
    end
    local ordered = self:GetDisplayOrderForFront(frontId)
    if not ordered or #ordered == 0 then return {} end
    for _, zone in ipairs(ordered) do
        if zone.status == "in_progress" and zone.isHolding then
            return { zone.id }
        end
    end
    local ids = {}
    for _, zone in ipairs(ordered) do
        if zone.status == "in_progress" and zone.owner == pf then
            ids[#ids + 1] = zone.id
        end
    end
    if #ids > 0 then return ids end
    for _, zone in ipairs(ordered) do
        if zone.status == "available" then
            ids[#ids + 1] = zone.id
        end
    end
    return ids
end

-- Une zone pour le HUD : capture en cours, sinon la plus proche parmi les objectifs paralleles.
function Overlord.Zones:GetNextObjectiveZone(frontId)
    local ids = self:GetNextObjectiveZoneIds(frontId)
    if #ids == 0 then return nil end
    if #ids == 1 then return self:GetZone(ids[1]) end
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.GetDistanceToZone then
        local best, bestDist = nil, math.huge
        for _, id in ipairs(ids) do
            local z = self:GetZone(id)
            if z then
                local d = Overlord.ZoneIndicator:GetDistanceToZone(z)
                if d and d < bestDist then
                    best, bestDist = z, d
                end
            end
        end
        if best then return best end
    end
    return self:GetZone(ids[1])
end

function Overlord.Zones:IsNextObjectiveZone(zoneId, frontId)
    if not zoneId then return false end
    for _, id in ipairs(self:GetNextObjectiveZoneIds(frontId)) do
        if id == zoneId then return true end
    end
    return false
end

function Overlord.Zones:GetCapturedCountForFront(frontId)
    self:MigrateLegacyCaptureFinalQuarantines(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return 0 end
    local n = 0
    local pf = Overlord.PlayerFaction
    for _, zone in ipairs(front.zones) do
        if zone.owner == pf and zone.status == "captured"
            and not zone._loginSyncUnconfirmed then
            n = n + 1
        end
    end
    return n
end

function Overlord.Zones:GetEnemyCapturedCountForFront(frontId)
    self:MigrateLegacyCaptureFinalQuarantines(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return 0 end
    local enemy = self:GetEnemyFaction()
    local n = 0
    for _, zone in ipairs(front.zones) do
        if zone.owner == enemy and zone.status ~= "in_progress"
            and not zone._loginSyncUnconfirmed then
            n = n + 1
        end
    end
    return n
end

function Overlord.Zones:GetTotalCountForFront(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    return (front and front.zones and #front.zones) or 0
end

function Overlord.Zones:GetDisplayOrder()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    if not front then return {} end
    local frontId = front.id
    if cachedDisplayFaction == Overlord.PlayerFaction and cachedDisplayFrontId == frontId and cachedDisplayOrder then
        return cachedDisplayOrder
    end
    local order = front and front.displayOrder and front.displayOrder[Overlord.PlayerFaction]
    cachedDisplayOrder = {}
    if order then
        for _, zoneId in ipairs(order) do
            local zone = self:GetZone(zoneId)
            if zone then table.insert(cachedDisplayOrder, zone) end
        end
    end
    cachedDisplayFaction = Overlord.PlayerFaction
    cachedDisplayFrontId = frontId
    return cachedDisplayOrder
end

-- Prérequis du front selon la faction locale (voyage inter-front ou init login).
function Overlord.Zones:ApplyFrontPrereqs(faction, zones)
    zones = zones or Overlord.ZoneDatabase
    if not zones or not faction then return end
    for _, zone in ipairs(zones) do
        zone.prereqZones = self:GetPrereqZoneIdsForAttacker(zone.id, faction)
    end
end

-- Applique les prérequis selon la faction et initialise les propriétaires de base
function Overlord.Zones:ApplyFactionConfig(faction)
    -- Bases : chaque faction possède son point de départ (visible par tous)
    -- capturedTime protege contre les ZS stales (la protection exige capturedTime > 0)
    -- Epoch de campagne partagee, pas l'heure de connexion propre a ce client.
    -- Sinon trois installations fraiches donnent trois claims ZA differentes.
    local now = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or time()
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
        if fixedOwner then
            zone.owner = fixedOwner
            zone.capturedTime = zone.capturedTime or now
            zone.updatedAt = zone.updatedAt or now
        else
            zone.owner = nil
        end
    end

    self:ApplyFrontPrereqs(faction)

    -- Statuts initiaux basés sur le propriétaire
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.owner == faction then
            zone.status = "captured"
        else
            zone.status = "locked"
        end
    end
end

-- Retourne le proprietaire fixe d'une zone de base (nil si pas une base)
function Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
    if not zoneId or not Overlord.Fronts then return nil end
    local _, front = Overlord.Fronts:GetZone(zoneId)
    if not front then return nil end
    if zoneId == front.allianceCapitalId then return "Alliance" end
    if zoneId == front.hordeCapitalId then return "Horde" end
    return nil
end

function Overlord.Zones:GetInterruptedCaptureRevertOwner(zone)
    if not zone then return nil end
    -- StartHoldTimer pose owner = PlayerFaction identique a previousOwner sur defense d'un point deja allie.
    -- L'ancienne condition (~=) renvoyait nil -> zone "available" neutre apres LOSING au lieu du proprio.
    if zone.previousOwner then
        return zone.previousOwner
    end
    local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
    -- Recapture de sa propre capitale : pendant l'in_progress, owner = notre faction
    -- (le proprietaire fixe). Si previousOwner manque, revenir au proprietaire fixe
    -- donnerait la capitale gratuitement. Le defenseur reel est alors la faction ennemie.
    if zone.isCapital and fixedOwner and zone.owner == fixedOwner then
        return self:GetEnemyFaction()
    end
    return fixedOwner
end

-- Proprietaire a restaurer apres echec de capture (LOSING, ZS available, observateur stale).
-- Complete GetInterruptedCaptureRevertOwner (deja corrige pour previousOwner + capitales) :
-- sur zones type Faldir, sans previousOwner en memoire, on deduit le defenseur depuis l'assaillant
-- UNIQUEMENT si la zone avait deja ete capturee (capturedTime > 0), sinon retomber neutre/available
-- (evite de donner la zone a l'ennemi apres abandon sur un point vraiment neutre).
function Overlord.Zones:ResolveRevertOwnerAfterFailedCapture(zone)
    if not zone then return nil end
    local prev = self:GetInterruptedCaptureRevertOwner(zone)
    if prev then return prev end
    -- Assaut depuis une branche « disponible » : previousOwner nil ; un capturedTime residuel
    -- (ancienne capture de la campagne) ne doit pas inventer un defenseur (ex. barrage -> faux bleu).
    if zone._assaultFromAvailable then
        return nil
    end
    if not zone.capturedTime or zone.capturedTime <= 0 then
        return nil
    end
    local assailant = zone.owner
    if assailant == "Alliance" or assailant == "Horde" then
        return (assailant == "Alliance") and "Horde" or "Alliance"
    end
    return nil
end

function Overlord.Zones:GetEnemyFaction()
    if not Overlord.PlayerFaction then return nil end
    return (Overlord.PlayerFaction == "Horde") and "Alliance" or "Horde"
end

-- Decroissance du timer in_progress apres deconnexion ou /reload (fronts + adaptateur fortin).
function Overlord.Zones:RestoreInProgressAfterOffline(zone, savedData, playerFaction)
    if not zone then return end
    savedData = savedData or {}
    zone.isHolding = false
    zone.isPaused = false

    local lastLogout = OverlordDB and tonumber(OverlordDB.lastSessionTimestamp) or nil
    local offlineSec = lastLogout and math.max(0, time() - lastLogout)
        or math.max(0, time() - (zone.updatedAt or 0))
    if offlineSec > 0 and (zone.holdTimeElapsed or 0) > 0 then
        local promotedOfflineEnemyCapture = false
        if zone.owner == playerFaction or zone.owner == nil then
            zone.holdTimeElapsed = math.max(0, (zone.holdTimeElapsed or 0) - offlineSec)
        else
            local req = zone.holdTimeRequired or 120
            if zone.isCapital and self:IsEnemyCapitalCapture(zone) then
                req = self:GetCapitalHoldTime(zone)
            end
            if offlineSec > req + 60 then
                zone.holdTimeElapsed = 0
            elseif (zone.holdTimeElapsed or 0) >= req then
                zone.holdTimeElapsed = 0
                zone.status = "captured"
                zone.previousOwner = nil
                zone.holdTimeRequired = 120
                zone.capturedTime = time()
                zone.updatedAt = 0
                promotedOfflineEnemyCapture = true
            end
        end

        if not promotedOfflineEnemyCapture and zone.holdTimeElapsed <= 0 then
            zone.holdTimeElapsed = 0
            local prevOwner = self:GetInterruptedCaptureRevertOwner(zone)
            zone.previousOwner = nil
            if prevOwner then
                zone.status = "captured"
                zone.owner = prevOwner
            else
                zone.status = "locked"
                zone.owner = nil
            end
            zone.holdTimeRequired = 120
            zone.updatedAt = 0
            zone.capturedTime = savedData.capturedTime or zone.updatedAt
        end
    end
    if zone.status == "in_progress" and zone.owner == playerFaction then
        -- Ne pas bump updatedAt au reload : ts frais + holdTime stale fait rejeter les ZS
        -- du capteur actif (ts plus ancien mais timer correct) et peut remettre le compteur
        -- a zero pour tout le groupe (bug forteresse / capitale Gilneas en raid).
        zone._restoredInProgress = true
        zone.holdStartTime = nil
        -- Revert immediat si la position carte est deja connue et qu'on est hors disque.
        -- Evite qu'un /reload + depart offre le point via interpolation ou echo ZS pre-reload.
        local pz = self:GetCurrentPlayerZone()
        if pz and pz.id ~= zone.id then
            zone._restoredInProgress = nil
            self:RevertInterruptedCapture(zone, false)
        end
    end
end

-- Apres /reload : si la capture restauree n'a pas ete reprise sur le disque, abandonner.
function Overlord.Zones:FinalizeRestoredInProgressAfterReload()
    if not Overlord.ZoneDatabase then return end
    local changed = false
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.status == "in_progress" and zone._restoredInProgress and not zone.isHolding then
            local pz = self:GetCurrentPlayerZone()
            if pz and pz.id ~= zone.id and zone.owner == Overlord.PlayerFaction then
                zone._restoredInProgress = nil
                self:RevertInterruptedCapture(zone, true)
                changed = true
            end
        end
    end
    if changed then
        self:UpdateAvailableZones()
        Overlord:MarkDirty()
        if Overlord.UI then Overlord.UI:RequestRefresh() end
    end
end

-- Abandon capture interrompue (LOSING a 0, instance, sortie de zone) - partage fronts / fortin.
function Overlord.Zones:RevertInterruptedCapture(zone, broadcast)
    if not zone then return end
    local wasAuthoritative = zone.holdAuthorityLocal == true
    if wasAuthoritative and Overlord.CaptureLease
        and Overlord.CaptureLease.BroadcastLocalRelease then
        -- ZR part avant toute mutation ; le bail distant disparait sans rewrite ZS.
        Overlord.CaptureLease:BroadcastLocalRelease(zone)
    end
    zone.holdTimeElapsed = 0
    zone._observerDisplayHold = nil
    zone._observerDisplayNetworkFloor = nil
    zone.isHolding = false
    if zone.holdAuthorityLocal ~= nil then
        zone.holdAuthorityLocal = nil
    end
    zone.isContested = false
    zone.isPaused = false
    zone.holdStartTime = nil
    if zone._restoredInProgress ~= nil then
        zone._restoredInProgress = nil
    end
    if zone.zsOfficialCapturerName ~= nil then
        zone.zsOfficialCapturerName = nil
    end
    zone._zsOfficialCapturerSeenAt = nil
    zone.holdTimeRequired = 120
    local prevOwner = self:ResolveRevertOwnerAfterFailedCapture(zone)
    zone.previousOwner = nil
    if prevOwner then
        zone.status = "captured"
        zone.owner = prevOwner
    else
        zone.status = "available"
        zone.owner = nil
        zone.capturedTime = nil
    end
    zone._assaultFromAvailable = nil
    if not wasAuthoritative then
        zone.updatedAt = 0
        broadcast = false
    else
        zone.updatedAt = time()
    end
    if broadcast and Overlord.Sync and zone.id and Overlord.Sync.BroadcastZoneState then
        Overlord.Sync:BroadcastZoneState(zone, true)
    end
    if wasAuthoritative and Overlord.CaptureLease and Overlord.CaptureLease.ClearLocal then
        Overlord.CaptureLease:ClearLocal(zone)
    end
end

function Overlord.Zones:GetFactionName()
    return (Overlord.PlayerFaction == "Horde") and L.THE_HORDE or L.THE_ALLIANCE
end

function Overlord.Zones:GetEnemyFactionName()
    return (Overlord.PlayerFaction == "Horde") and L.THE_ALLIANCE or L.THE_HORDE
end

-- ID front depuis zone.id (indépendant du front actif affiché dans ZoneDatabase).
local function ResolveFrontIdFromZoneId(zoneId)
    if not zoneId or zoneId == "" then return nil end
    if zoneId:sub(1, 3) == "sb_" then return "southern_barrens" end
    if zoneId:sub(1, 5) == "loch_" then return "loch_modan" end
    if zoneId:sub(1, 8) == "gilneas_" then return "gilneas" end
    if zoneId:sub(1, 8) == "durotar_" then return "durotar" end
    if zoneId:sub(1, 4) == "ash_" then return "ashenvale" end
    if Overlord.Fronts and Overlord.Fronts.GetZone then
        local _, front = Overlord.Fronts:GetZone(zoneId)
        if front and front.id then return front.id end
    end
    return "arathi"
end

function Overlord.Zones:GetFrontMapDisplayName(frontId)
    if not frontId or not L then return nil end
    if frontId == "southern_barrens" then return L.FRONT_SOUTHERN_BARRENS_NAME end
    if frontId == "loch_modan" then return L.FRONT_LOCH_MODAN_NAME end
    if frontId == "gilneas" then return L.FRONT_GILNEAS_NAME end
    if frontId == "arathi" then return L.FRONT_ARATHI_NAME end
    if frontId == "ashenvale" then return L.FRONT_ASHENVALE_NAME end
    if frontId == "durotar" then return L.FRONT_DUROTAR_NAME end
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    return front and front.mapName
end

-- Libellé pour alertes « ennemi capture » : sous-objectif + grande région du front (ex. Gilneas, Arathi).
-- zoneIdFallback : id ZS si la table zone n'a pas .id (sync front inactif).
function Overlord.Zones:GetZoneCaptureAlertLocationLabel(zone, zoneIdFallback)
    local zoneId = (zone and zone.id) or zoneIdFallback
    local zoneName = (zone and zone.name) or (zoneId and L.ZONE_NAMES and L.ZONE_NAMES[zoneId]) or zoneId or ""
    if not zoneId or zoneId == "" then return zoneName end

    local regionName
    if Overlord.Fronts and Overlord.Fronts.GetZone then
        local _, front = Overlord.Fronts:GetZone(zoneId)
        if front then
            regionName = (front.mapName and front.mapName ~= "") and front.mapName
                or self:GetFrontMapDisplayName(front.id)
        end
    end
    if not regionName or regionName == "" then
        regionName = self:GetFrontMapDisplayName(ResolveFrontIdFromZoneId(zoneId))
    end

    local fmt = L.CAPTURE_ALERT_SUBZONE_IN_REGION
    if regionName and regionName ~= "" and fmt and fmt ~= "" then
        return string.format(fmt, zoneName, regionName)
    end
    return zoneName
end

-- Index de lookup par ID (construit une seule fois)
local ZoneLookup = {}

function Overlord.Zones:RebuildZoneLookup()
    wipe(ZoneLookup)
    for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
        ZoneLookup[zone.id] = zone
    end
    cachedDisplayOrder = nil
    cachedDisplayFaction = nil
    cachedDisplayFrontId = nil
    cachedPlayerZone = nil
    cachedPlayerZoneTime = 0
end

Overlord.Zones:RebuildZoneLookup()

function Overlord.Zones:GetZone(zoneId)
    return ZoneLookup[zoneId]
end

-- ==================== Capitales (timer fixe 8 min) ====================

-- Capitale ennemie du joueur local (siege long) vs recapture de sa propre base (120 s).
function Overlord.Zones:IsEnemyCapitalCapture(zone)
    if not zone or not zone.isCapital or not Overlord.PlayerFaction then return false end
    local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
    return fixedOwner and fixedOwner ~= Overlord.PlayerFaction
end

-- Timer de capture sur capitale ennemie : 8 min fixe.
function Overlord.Zones:GetCapitalHoldTime(zone)
    if not zone or not zone.isCapital then return 120 end
    return CAPITAL_HOLD_TIME
end

-- Timer in_progress sur capitale : 8 min si assaut sur la base ennemie, 120 s si recapture de sa base.
function Overlord.Zones:GetCapitalSiegeHoldRequired(zone, assaultOwnerFaction, remoteParsed)
    if not zone or not zone.isCapital then
        return tonumber(remoteParsed) or 120
    end
    local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
    if fixedOwner and assaultOwnerFaction and assaultOwnerFaction ~= fixedOwner then
        return CAPITAL_HOLD_TIME
    end
    return 120
end

-- Timer affiche pour capture observee a distance : utilise l'interpolation locale (_observerDisplayHold)
-- qui avance chaque frame dans TickRemoteObserverZone, recalee a chaque ZS recu.
function Overlord.Zones:GetObserverHoldTimeElapsed(zone)
    if not zone or zone.status ~= "in_progress" then
        if zone then
            zone._observerDisplayHold = nil
            zone._observerDisplayNetworkFloor = nil
        end
        return tonumber(zone and zone.holdTimeElapsed) or 0
    end
    if zone.isHolding and zone.holdAuthorityLocal then
        return tonumber(zone.holdTimeElapsed) or 0
    end
    if zone.isHolding and zone.holdStartTime then
        -- Co-captureur : affichage fluide entre deux ZS (n'altere pas holdTimeElapsed sync).
        local req = tonumber(zone.holdTimeRequired) or 120
        local base = math.max(tonumber(zone.holdTimeElapsed) or 0,
            tonumber(zone._observerDisplayNetworkFloor) or 0)
        local interp = GetTime() - zone.holdStartTime
        return math.min(req, math.max(base, interp))
    end
    local base = math.max(tonumber(zone.holdTimeElapsed) or 0,
        tonumber(zone._observerDisplayNetworkFloor) or 0)
    if zone._restoredInProgress then
        local display = zone._observerDisplayHold
        if display and display >= base then
            return math.min(zone.holdTimeRequired or 120, display)
        end
        return base
    end
    local display = zone._observerDisplayHold
    if display and display >= base then
        return math.min(zone.holdTimeRequired or 120, display)
    end
    local req = tonumber(zone.holdTimeRequired) or 120
    if base >= req then return base end
    local ts = tonumber(zone.updatedAt) or 0
    if ts <= 0 then
        return base
    end
    local age = math.max(0, time() - ts)
    return math.min(req, base + age)
end

function Overlord.Zones:GetVictoryCooldownSeconds()
    return CAPITAL_VICTORY_COOLDOWN
end

local function GetVictoryFrontId(frontId)
    if frontId then return frontId end
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    return front and front.id
end

-- Nettoyage commun des preuves/overlays d'une ancienne vague de capture.
-- Les transitions canoniques (victoire ou reset) ne doivent jamais conserver
-- un marqueur terminal qui ferait diverger prerequis, victoire ou affichage.
function Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
    if not zone then return end

    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    zone._captureFinalConfirmedBase = nil
    zone._lastCaptureFinalWaveId = nil
    zone._lastCaptureFinalOrigin = nil
    zone._lastCaptureFinalGuid = nil
    zone._lastCaptureFinalRequired = nil
    zone._lastCaptureFinalAt = nil

    zone._observerDisplayHold = nil
    zone._observerDisplayNetworkFloor = nil
    zone._lastObserverSyncPollAt = nil
    zone._observerFinalStatePollAt = nil
    zone._observerFinalStatePollCount = nil
    zone._observerCaptureConfirmPollAt = nil
    zone._syncGateRemoteProgress = nil
    zone._syncGateRemoteProgressUntil = nil
    zone._restoredInProgress = nil
    zone._remoteLeaseExpiredReason = nil
    zone._loginSyncUnconfirmed = nil

    zone.zsOfficialCapturerName = nil
    zone._zsOfficialCapturerSeenAt = nil
    zone.zsRelayCapturerName = nil
    zone.zsRelayCapturerShard = nil
    zone.lastZSSender = nil

    -- Complete() nettoie normalement ces champs. Les remettre a nil ici garde
    -- les resets deterministes meme si CaptureLease n'est pas encore charge.
    zone._remoteCaptureLease = nil
    zone._localCaptureWaveId = nil
    zone._localCaptureOpenedAt = nil
    zone._localCaptureBase = nil
    zone._captureReleaseSentWave = nil
    zone._captureDefensiveRequired = nil
    zone._captureDefensiveWaveId = nil
    zone._captureBarrierProposalUntil = nil
    zone._captureBarrierPreviousRequired = nil
    zone._captureBarrierDefenderKey = nil
    zone._captureBarrierDefenderGuid = nil
    zone._captureBarrierOriginGuid = nil
    zone._captureBarrierCommitted = nil
    zone._assaultFromAvailable = nil
end

-- Capitale ennemie du gagnant bien capturee (condition minimale victoire totale).
function Overlord.Zones:ConfirmsFrontCapitalCaptured(frontId, winningFaction)
    if not frontId or not winningFaction or not Overlord.Fronts then return false end
    local capId = Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
    if not capId then return false end
    -- GetZone() ne couvre que le front actif ; une victoire recue pour un autre
    -- front doit etre validee contre l'objet de ce front precis.
    local cap = select(1, Overlord.Fronts:GetZone(capId, frontId))
    return cap and cap.owner == winningFaction and self:IsNetworkConfirmedCapture(cap)
end

-- Capture confirmee (sync / victoire) : owner + capturedTime, pas le status local-only
-- (available/locked = vue prérequis assaut sur le front actif).
function Overlord.Zones:IsNetworkConfirmedCapture(zone)
    zone = type(zone) == "table" and zone or self:GetZone(zone)
    if not zone or not zone.owner then return false end
    if zone.status == "in_progress" then return false end
    ClearLegacyCaptureFinalQuarantine(zone)
    if zone._loginSyncUnconfirmed then return false end
    return (tonumber(zone.capturedTime) or 0) > 0
end

-- Zones du front qui ne sont pas encore au gagnant (carte encore disputee).
function Overlord.Zones:CountZonesNotOwnedByOnFront(frontId, faction)
    if not frontId or not faction or not Overlord.Fronts then return 999 end
    self:MigrateLegacyCaptureFinalQuarantines(frontId)
    local front = Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return 999 end
    local n = 0
    for _, z in ipairs(front.zones) do
        local zd = select(1, Overlord.Fronts:GetZone(z.id, frontId))
        if zd and (zd.owner ~= faction or zd._loginSyncUnconfirmed) then
            n = n + 1
        end
    end
    return n
end

-- Treve sync (SR/VT) valide seulement si l'etat local correspond a une vraie victoire totale.
function Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, winningFaction)
    if not self:ConfirmsFrontCapitalCaptured(frontId, winningFaction) then
        return false
    end
    return self:CountZonesNotOwnedByOnFront(frontId, winningFaction) == 0
end

function Overlord.Zones:ClearFrontVictory(frontId)
    if not OverlordDB or not frontId then return end
    OverlordDB.frontVictories = OverlordDB.frontVictories or {}
    OverlordDB.frontVictories[frontId] = nil
    if OverlordDB.lastVictoryFrontId == frontId then
        OverlordDB.lastVictoryTimestamp = nil
        OverlordDB.lastVictoryFaction = nil
        OverlordDB.lastVictoryFrontId = nil
    end
end

-- Efface toutes les treves (reset hebdo / admin).
function Overlord.Zones:ClearFrontVictories()
    if not OverlordDB then return end
    OverlordDB.frontVictories = {}
    OverlordDB.lastVictoryTimestamp = nil
    OverlordDB.lastVictoryFaction = nil
    OverlordDB.lastVictoryFrontId = nil
    OverlordDB.frontTruceResetEpoch = {}
end

function Overlord.Zones:SetVictoryCooldown(frontId, winningFaction, timestamp)
    if not OverlordDB or not frontId or not winningFaction or not timestamp then return end
    OverlordDB.frontVictories = OverlordDB.frontVictories or {}
    OverlordDB.frontVictories[frontId] = {
        timestamp = timestamp,
        faction = winningFaction,
    }
    -- Champs historiques gardes alignes sur le front actif pour les anciens pairs.
    OverlordDB.lastVictoryTimestamp = timestamp
    OverlordDB.lastVictoryFaction = winningFaction
    OverlordDB.lastVictoryFrontId = frontId
end

-- Etat final unique d'une victoire totale : toute la carte du front appartient au gagnant.
function Overlord.Zones:ForceSyncFrontToWinner(frontId, winningFaction, timestamp, resetKills)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones or not winningFaction or not timestamp then return false end
    local ts = tonumber(timestamp) or time()

    for _, zone in ipairs(front.zones) do
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        self:ClearCaptureFinalUnattestedState(zone)
        zone.owner = winningFaction
        zone.status = "captured"
        zone.capturedTime = ts
        zone.updatedAt = ts
        zone.isHolding = false
        zone.holdAuthorityLocal = nil
        zone.isContested = false
        zone.isPaused = false
        zone.holdTimeElapsed = 0
        zone.holdStartTime = nil
        zone.previousOwner = nil
        zone.zsOfficialCapturerName = nil
        zone._zsOfficialCapturerSeenAt = nil
        zone.zsRelayCapturerName = nil
        zone.zsRelayCapturerShard = nil
        zone.lastZSSender = nil
        zone._syncGateRemoteProgress = nil
        zone._syncGateRemoteProgressUntil = nil
        zone.holdTimeRequired = 120
        if resetKills then
            zone.killsCurrent = 0
            zone.allyKillsCurrent = 0
            zone.enemyKillsCurrent = 0
        end
    end

    if Overlord.Fronts and Overlord.Fronts.activeFrontId == frontId and self.RebuildZoneLookup then
        self:RebuildZoneLookup()
    end
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    if Overlord.UI then Overlord.UI:RequestRefresh() end
    if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh()
    end
    return true
end

-- Treve post-victoire : tout le front est en pause apres une victoire totale (15 min).
-- Empeche le chain-cap et la reprise immediate sur d'autres objectifs.
-- forDisplay est conserve pour compat appelants ; UI et gameplay utilisent la meme validation locale.
-- Retourne : onCooldown, remaining, winningFaction, frontId
function Overlord.Zones:IsOnVictoryCooldown(frontId, forDisplay)
    if not OverlordDB then return false, 0, nil, nil end
    local victoryFrontId = GetVictoryFrontId(frontId)
    if not victoryFrontId then return false, 0, nil, nil end
    local frontVictory = OverlordDB.frontVictories and OverlordDB.frontVictories[victoryFrontId]
    local victoryTimestamp = frontVictory and frontVictory.timestamp
    local winningFaction = frontVictory and frontVictory.faction
    if not victoryTimestamp and OverlordDB.lastVictoryFrontId == victoryFrontId then
        victoryTimestamp = OverlordDB.lastVictoryTimestamp
        winningFaction = OverlordDB.lastVictoryFaction
    end
    if not victoryTimestamp then return false, 0, nil, victoryFrontId end
    -- Reset hebdo mercredi : les treves de la campagne precedente ne bloquent plus
    local lastReset = (OverlordDB.lastResetTimestamp and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if lastReset > 0 and victoryTimestamp < lastReset then
        return false, 0, nil, victoryFrontId
    end
    local elapsed = time() - victoryTimestamp
    local remaining = CAPITAL_VICTORY_COOLDOWN - elapsed
    if remaining > 0 and winningFaction then
        -- Treve orpheline (SR/VT sans TV) : carte mixte -> pas de blocage gameplay ni UI grisee.
        if self:LocalStateSupportsVictoryTruce(victoryFrontId, winningFaction) then
            return true, remaining, winningFaction, victoryFrontId
        end
    end
    return false, 0, nil, victoryFrontId
end

local NormalizePlayerOwnedZoneStatus

-- Recalcule available/locked/captured pour toutes les zones d'un front (apres fin de treve).
function Overlord.Zones:UpdateAvailableZonesForFront(frontId)
    self:MigrateLegacyCaptureFinalQuarantines(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return end
    local pf = Overlord.PlayerFaction
    local prereqs = front.prereqs and front.prereqs[pf]

    for _, zone in ipairs(front.zones) do
        -- Capitales de base : seeder owner/status si le front n'a jamais eu ApplyFactionConfig
        -- (ex. Elwynn active apres login sur un autre front).
        local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
        if fixedOwner and not zone.owner then
            zone.owner = fixedOwner
            zone.status = "captured"
            local now = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
                or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or time()
            zone.capturedTime = zone.capturedTime or now
            zone.updatedAt = zone.updatedAt or now
        end
        -- Branches : pas de proprietaire fixe ; effacer un owner ennemi residuel (post-treve)
        if not fixedOwner and zone.owner and zone.owner ~= pf then
            zone.owner = nil
            zone.capturedTime = nil
        end
        NormalizePlayerOwnedZoneStatus(zone, pf)
        if zone.owner == pf and zone.status == "captured" then
            -- Deja normalise ; ne pas recalculer les prereqs.
        elseif zone.status == "in_progress" then
            zone.status = "locked"
            zone.isHolding = false
            zone.holdTimeElapsed = 0
        else
            local prereqIds = prereqs and prereqs[zone.id]
            local available = prereqIds ~= nil
            if available and prereqIds then
                for _, prereqId in ipairs(prereqIds) do
                    local prereq = self:GetZone(prereqId) or Overlord.Fronts:GetZone(prereqId, frontId)
                    if not prereq or prereq.owner ~= pf or prereq.status ~= "captured"
                        or LoginQuarantineBlocksLocalGameplay(prereq) then
                        available = false
                        break
                    end
                end
            end
            if available then
                local enemyBaseId = Overlord.Fronts:GetEnemyCapitalId(pf, frontId)
                if zone.id == enemyBaseId then
                    for _, z in ipairs(front.zones) do
                        if z.id ~= zone.id and (z.owner ~= pf or z.status ~= "captured"
                            or LoginQuarantineBlocksLocalGameplay(z)) then
                            available = false
                            break
                        end
                    end
                end
            end
            zone.status = available and "available" or "locked"
            if zone.status == "available" and (not zone.capturedTime or zone.capturedTime <= 0) then
                zone.owner = nil
            end
        end
    end
end

-- Recalcule UNIQUEMENT les statuts locked/available des zones sans proprietaire d'un front
-- INACTIF apres une sync passive (C / ZS / ZA) : un prerequis vient peut-etre d'etre (de)bloque
-- et le statut local-only restait fige (ex. "Verrouillee" fantome alors que la chaine est verte).
-- Non destructif, contrairement a UpdateAvailableZonesForFront (reset post-treve) : ne touche
-- jamais owner, capturedTime, updatedAt, ni les zones possedees ou in_progress.
function Overlord.Zones:RefreshInactiveFrontAvailability(frontId)
    if not frontId then return end
    if Overlord.Fronts and Overlord.Fronts.activeFrontId == frontId then return end
    self:MigrateLegacyCaptureFinalQuarantines(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return end
    local pf = Overlord.PlayerFaction
    local prereqs = front.prereqs and front.prereqs[pf]
    if not prereqs then return end

    local changed = false
    for _, zone in ipairs(front.zones) do
        if not zone.owner and (zone.status == "locked" or zone.status == "available") then
            local prereqIds = prereqs[zone.id]
            local available = prereqIds ~= nil
            if prereqIds then
                for _, prereqId in ipairs(prereqIds) do
                    local prereq = Overlord.Fronts:GetZone(prereqId, frontId)
                    if not prereq or prereq.owner ~= pf or prereq.status ~= "captured"
                        or LoginQuarantineBlocksLocalGameplay(prereq) then
                        available = false
                        break
                    end
                end
            end
            -- Capitale ennemie : exige tout le front capture (meme regle que le recalcul actif).
            if available and zone.id == Overlord.Fronts:GetEnemyCapitalId(pf, frontId) then
                for _, z in ipairs(front.zones) do
                    if z.id ~= zone.id and (z.owner ~= pf or z.status ~= "captured"
                        or LoginQuarantineBlocksLocalGameplay(z)) then
                        available = false
                        break
                    end
                end
            end
            local newStatus = available and "available" or "locked"
            if zone.status ~= newStatus then
                zone.status = newStatus
                changed = true
            end
        end
    end
    if changed and Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh(true)
    end
end

-- Remet les zones d'un front a l'etat initial (capitales tenues, branches selon prerequis).
function Overlord.Zones:ResetFrontZonesToInitial(frontId, resetEpoch)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return false end

    local now = tonumber(resetEpoch) or time()
    for _, zone in ipairs(front.zones) do
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        self:ClearCaptureFinalUnattestedState(zone)
        zone.killsCurrent = 0
        zone.allyKillsCurrent = 0
        zone.enemyKillsCurrent = 0
        zone.holdTimeElapsed = 0
        zone.isHolding = false
        zone.holdAuthorityLocal = nil
        zone.isContested = false
        zone.isPaused = false
        zone.holdStartTime = nil
        zone.capturedTime = nil
        zone.previousOwner = nil
        zone.zsOfficialCapturerName = nil
        zone._zsOfficialCapturerSeenAt = nil
        zone.zsRelayCapturerName = nil
        zone.zsRelayCapturerShard = nil
        zone.lastZSSender = nil
        zone._syncGateRemoteProgress = nil
        zone._syncGateRemoteProgressUntil = nil
        zone.owner = nil
        zone.status = "locked"
        zone.holdTimeRequired = 120
        -- Horodatage uniforme : updatedAt=0 laissait les vieux ZA (post-victoire) repasser
        zone.updatedAt = now
    end

    for _, zone in ipairs(front.zones) do
        local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
        if fixedOwner then
            zone.owner = fixedOwner
            zone.status = "captured"
            zone.capturedTime = now
            zone.updatedAt = now
        end
    end

    self:UpdateAvailableZonesForFront(frontId)

    if Overlord.Fronts.activeFrontId == frontId and self.RebuildZoneLookup then
        self:RebuildZoneLookup()
    end
    if Overlord.Fronts.activeFrontId == frontId then
        self:UpdateAvailableZones()
    end

    return true
end

-- Fin de treve : reset des zones du front uniquement (pas domination / or / fortin).
function Overlord.Zones:ApplyFrontTruceEndReset(frontId, resetEpoch, fromSync)
    if not frontId or not resetEpoch or resetEpoch <= 0 then return false end
    if not OverlordDB then return false end
    OverlordDB.frontTruceResetEpoch = OverlordDB.frontTruceResetEpoch or {}
    if (OverlordDB.frontTruceResetEpoch[frontId] or 0) >= resetEpoch then
        return false
    end

    if not self:ResetFrontZonesToInitial(frontId, resetEpoch) then return false end

    OverlordDB.frontTruceResetEpoch[frontId] = resetEpoch
    self:ClearFrontVictory(frontId)

    if Overlord.Sync and Overlord.Sync.ResetVictoryFlagForFront then
        Overlord.Sync:ResetVictoryFlagForFront(frontId)
    end

    Overlord:MarkDirty()
    if Overlord.SaveState then Overlord:SaveState() end
    if Overlord.UI then Overlord.UI:RequestRefresh() end
    if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh()
    end

    if not fromSync then
        local mapLabel = self:GetFrontMapDisplayName(frontId) or frontId
        if L.FRONT_TRUCE_ENDED_RESET then
            Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.FRONT_TRUCE_ENDED_RESET, mapLabel))
        end
        if Overlord.Sync and Overlord.Sync.BroadcastFrontTruceEndReset then
            Overlord.Sync:BroadcastFrontTruceEndReset(frontId, resetEpoch)
        end
    end

    return true
end

-- Victoire fantome en SavedVariables : effacer sans reset carte ni message chat.
local function PrunePhantomFrontVictory(frontId, victoryTs)
    if not OverlordDB or not frontId then return end
    OverlordDB.frontTruceResetEpoch = OverlordDB.frontTruceResetEpoch or {}
    local prev = OverlordDB.frontTruceResetEpoch[frontId] or 0
    if victoryTs > prev then
        OverlordDB.frontTruceResetEpoch[frontId] = victoryTs
    end
    Overlord.Zones:ClearFrontVictory(frontId)
    if Overlord.Sync and Overlord.Sync.ResetVictoryFlagForFront then
        Overlord.Sync:ResetVictoryFlagForFront(frontId)
    end
end

-- Verifie tous les fronts dont la treve de 15 min est terminee.
function Overlord.Zones:TryExpireFrontTruces()
    if not OverlordDB or not Overlord.Fronts then return end
    local victories = OverlordDB.frontVictories
    if not victories then return end

    local lastReset = tonumber(OverlordDB.lastResetTimestamp) or 0
    local toProcess = {}
    for frontId, victory in pairs(victories) do
        local victoryTs = tonumber(victory.timestamp) or 0
        local winningFaction = victory.faction
        if victoryTs > 0 and winningFaction
            and (lastReset <= 0 or victoryTs >= lastReset) then
            if time() - victoryTs >= CAPITAL_VICTORY_COOLDOWN then
                toProcess[#toProcess + 1] = {
                    frontId = frontId,
                    victoryTs = victoryTs,
                    winningFaction = winningFaction,
                }
            end
        end
    end

    for _, entry in ipairs(toProcess) do
        -- Reset + message seulement si la carte locale confirme une vraie victoire totale (pas SR/VT fantome).
        if self:LocalStateSupportsVictoryTruce(entry.frontId, entry.winningFaction) then
            self:ApplyFrontTruceEndReset(entry.frontId, entry.victoryTs + CAPITAL_VICTORY_COOLDOWN, false)
        else
            PrunePhantomFrontVictory(entry.frontId, entry.victoryTs)
        end
    end
end

-- Au login : nettoyer les victoires expirees sans treve reelle (evite faux message au reload).
function Overlord.Zones:PruneExpiredPhantomVictories()
    self:TryExpireFrontTruces()
end

-- Treve active sur le front de cette zone (apres victoire totale).
-- frontIdHint : front consulte (panneau / carte) ; evite de retomber sur le front actif du joueur.
function Overlord.Zones:IsFrontOnTruce(zoneId, frontIdHint, forDisplay)
    local resolvedFrontId = frontIdHint
    if not resolvedFrontId and zoneId and Overlord.Fronts and Overlord.Fronts.GetZone then
        local _, front = Overlord.Fronts:GetZone(zoneId, frontIdHint)
        resolvedFrontId = front and front.id
    end
    if not resolvedFrontId then
        return false, 0
    end
    local onCooldown, remaining = self:IsOnVictoryCooldown(resolvedFrontId, forDisplay)
    return onCooldown, remaining
end

-- Alias historique : treve etendue a toute la carte du front, pas seulement la capitale perdante.
function Overlord.Zones:IsCapitalOnTruce(zoneId)
    return self:IsFrontOnTruce(zoneId)
end

-- Formate une duree en secondes en "Xh00", "Xm" ou "Xs" sous la minute
-- (sinon la derniere minute d'un verrou / d'une treve affiche "0m" alors qu'il reste du temps).
function Overlord.Zones:FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh%02d", h, m)
    elseif m > 0 then
        return string.format("%dm", m)
    else
        return string.format("%ds", seconds)
    end
end

function Overlord.Zones:IsZoneAvailable(zoneId)
    local zone = self:GetZone(zoneId)
    if not zone then return false end
    -- Accepte et nettoie les anciennes captures finales mises en quarantaine :
    -- un marqueur affiche ATTACK/available doit toujours etre physiquement jouable.
    self:MigrateLegacyCaptureFinalQuarantines()
    if LoginQuarantineBlocksLocalGameplay(zone) then return false end

    -- Treve post-victoire : aucune nouvelle capture sur le front (carte entiere fermee).
    local onTruce = select(1, self:IsFrontOnTruce(zoneId))
    if onTruce then
        if zone.owner == Overlord.PlayerFaction and zone.status == "captured" then
            return true
        end
        return false
    end

    -- Déjà possédée par notre faction = oui
    if zone.owner == Overlord.PlayerFaction then return true end

    -- Tous les prérequis doivent être complètement capturés (owner + status == "captured")
    local prereqIds = self:GetPrereqZoneIdsForAttacker(zoneId, Overlord.PlayerFaction)
    if not prereqIds then return false end
    for _, prereqId in ipairs(prereqIds) do
        local prereq = self:GetZone(prereqId)
        if not prereq or prereq.owner ~= Overlord.PlayerFaction or prereq.status ~= "captured"
            or LoginQuarantineBlocksLocalGameplay(prereq) then
            return false
        end
    end

    -- L'objectif final (base ennemie) nécessite TOUTES les autres zones complètement capturées
    local enemyBaseId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(Overlord.PlayerFaction)
    if zoneId == enemyBaseId then
        for _, z in ipairs(Overlord.ZoneDatabase) do
            if z.id ~= zoneId and (z.owner ~= Overlord.PlayerFaction
                or z.status ~= "captured"
                or LoginQuarantineBlocksLocalGameplay(z)) then
                return false
            end
        end
    end

    return true
end

-- Ratio d'aspect de la carte (largeur/hauteur en yards). Calculé par front.
-- Corrige la détection pour que le cercle de détection corresponde au cercle visuel.
local mapAspectRatio = 1.0
local mapAspectCalculatedFor = nil

function Overlord.Zones:CalcMapAspect()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    if not front then return end
    local frontId = front.id
    if mapAspectCalculatedFor == frontId then return end
    pcall(function()
        if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return end
        local mapID = Overlord.Fronts and Overlord.Fronts:GetMapID(frontId)
        if not mapID then return end
        local _, w0 = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
        local _, wX = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 0))
        local _, wY = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 1))
        if w0 and wX and wY then
            local dX = math.sqrt((wX.x - w0.x) ^ 2 + (wX.y - w0.y) ^ 2)
            local dY = math.sqrt((wY.x - w0.x) ^ 2 + (wY.y - w0.y) ^ 2)
            if dX > 0 and dY > 0 then
                mapAspectRatio = dY / dX
                mapAspectCalculatedFor = frontId
            end
        end
    end)
end

function Overlord.Zones:GetMapAspectRatio()
    return mapAspectRatio
end

function Overlord.Zones:IsWarFrontMapID(mapID)
    return Overlord.Fronts and Overlord.Fronts:ResolveFrontByMapID(mapID) ~= nil or false
end

function Overlord.Zones:IsActiveFrontMapID(mapID)
    return Overlord.Fronts and Overlord.Fronts:IsActiveFrontMapID(mapID) or false
end

-- Cache de GetCurrentPlayerZone (evite 3 pcall + 10 iterations par appel, appele ~3 fois/s)
local PLAYER_ZONE_CACHE_TTL = 0.9

function Overlord.Zones:GetCurrentPlayerZone()
    local now = GetTime()
    if now - cachedPlayerZoneTime < PLAYER_ZONE_CACHE_TTL then
        return cachedPlayerZone
    end

    cachedPlayerZone = nil
    cachedPlayerZoneTime = now

    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil end

    if Overlord.Fronts then
        local front = Overlord.Fronts:ResolveFrontByMapID(mapID)
        if not front then return nil end
        -- Getter pur : n'active jamais un front (CheckActiveFrontZone / IsPlayerInActiveFront).
        if front.id ~= Overlord.Fronts.activeFrontId then
            return nil
        end
        local frontMapID = Overlord.Fronts:GetMapID(front.id)
        if not frontMapID then return nil end
        mapID = frontMapID
    else
        -- Sans Fronts.lua (TOC casse) impossible de resoudre une carte de front
        return nil
    end
    self:CalcMapAspect()

    local ok3, playerPos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok3 or not playerPos then return nil end

    local ok4, px, py = pcall(playerPos.GetXY, playerPos)
    if not ok4 or not px then return nil end
    px = px * 100
    py = py * 100

    local ar = mapAspectRatio
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local dx = zone.center[1] - px
        local dy = (zone.center[2] - py) * ar
        if dx * dx + dy * dy <= zone.radius * zone.radius then
            cachedPlayerZone = zone
            return zone
        end
    end

    return nil
end

function Overlord.Zones:GetCapturedCount()
    self:MigrateLegacyCaptureFinalQuarantines()
    local count = 0
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        -- Ne compter que les zones effectivement capturees (pas celles en cours de capture)
        if zone.owner == Overlord.PlayerFaction and zone.status == "captured"
            and not zone._loginSyncUnconfirmed then
            count = count + 1
        end
    end
    return count
end

function Overlord.Zones:GetEnemyCapturedCount()
    self:MigrateLegacyCaptureFinalQuarantines()
    local count = 0
    local enemy = self:GetEnemyFaction()
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        -- Compter sur owner, pas sur status : UpdateAvailableZones ecrase le status
        -- des zones ennemies en "available"/"locked" selon nos prereqs, mais owner reste correct
        if zone.owner == enemy and zone.status ~= "in_progress"
            and not zone._loginSyncUnconfirmed then
            count = count + 1
        end
    end
    return count
end

function Overlord.Zones:GetTotalCount()
    return #Overlord.ZoneDatabase
end

-- Cooldown pour le message CAPTURE_CANCELLED (evite le spam quand les ZS arrivent toutes les 2s)
local captureCancelledCooldowns = {}
local CAPTURE_CANCELLED_COOLDOWN = 30

-- ==================== Mines de coins ====================
-- Zones de minage separees du systeme de capture. Le joueur accumule de l'or
-- en restant dans le cercle d'une mine (+ bonus si vrai node mine).

Overlord.MineDatabase = {
    {
        id = "azurelode",
        name = L.MINE_AZURELODE,
        mapID = 1424, mapIDs = { [25] = true, [1424] = true }, -- Hillsbrad Foothills
        -- Entrées de Veine-d'Azur (26,58 et 30,56), au sud des champs de Hautebrande.
        center = {28.0, 57.0},
        radius = 4,
    },
    {
        id = "darrow",
        name = L.MINE_DARROW,
        mapID = 1424, mapIDs = { [25] = true, [1424] = true }, -- Colline de Darrow, au nord d'Austrivage
        center = {46.0, 32.0},
        radius = 4,
    },
    {
        id = "elemgorge",
        name = L.MINE_ELEMGORGE,
        mapID = 1421, mapIDs = { [21] = true, [1421] = true }, -- Silverpine Forest
        center = {57.3, 46.4},
        radius = 4,
    },
    {
        id = "stonessplinter",
        name = L.MINE_STONESSPLINTER,
        mapID = 1432, mapIDs = { [48] = true, [1432] = true }, -- Loch Modan
        center = {33.2, 70.0},
        radius = 4,
    },
        {
        id = "jasperlode",
        name = L.MINE_JASPERLODE,
        -- Mine de Veine-de-Jaspe sur le front d'Elwynn.
        mapID = 1429,
        mapIDs = { [37] = true, [1429] = true },
        center = {61.9, 54.2},
        radius = 4,
    },
}

-- Index de lookup par ID
-- Use the same map aliases for harvesting, world-map circles and minimap pins.
function Overlord.Zones:ResourceMatchesMap(resource, mapID)
    return resource ~= nil and mapID ~= nil
        and (resource.mapID == mapID or (resource.mapIDs and resource.mapIDs[mapID] == true)) or false
end

local MineLookup = {}
for _, mine in ipairs(Overlord.MineDatabase) do
    MineLookup[mine.id] = mine
end

-- Le cercle jaune et la detection joueur utilisent exactement la meme demi-echelle.
Overlord.MineMapCircleScale = 0.50

function Overlord.Zones:GetMine(mineId)
    return MineLookup[mineId]
end

-- Index des mapIDs contenant des mines (pour detection rapide)
local mineMapIDs = {}
for _, mine in ipairs(Overlord.MineDatabase) do
    mineMapIDs[mine.mapID] = true
    for mapID in pairs(mine.mapIDs or {}) do mineMapIDs[mapID] = true end
end

function Overlord.Zones:IsMineMapID(mapID)
    return mapID and mineMapIDs[mapID] or false
end

-- Cache de GetCurrentPlayerMine (meme logique que GetCurrentPlayerZone)
local cachedPlayerMine = nil
local cachedPlayerMineTime = 0
local PLAYER_MINE_CACHE_TTL = 0.25

function Overlord.Zones:GetCurrentPlayerMine()
    local now = GetTime()
    if now - cachedPlayerMineTime < PLAYER_MINE_CACHE_TTL then
        return cachedPlayerMine
    end

    cachedPlayerMine = nil
    cachedPlayerMineTime = now

    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil end

    -- Si le mapID courant n'est pas une carte de mine, remonter la hierarchie.
    -- Couvre les sous-zones interieures (etages, grottes) dont un ancetre est
    -- la carte de mine (ex. etage superieur de Veine-d'Azur dans Hillsbrad).
    -- On remonte jusqu'a 3 niveaux pour couvrir les hierarchies profondes.
    local resolvedMapID = mapID
    local depth = 0
    while not mineMapIDs[resolvedMapID] and depth < 3 do
        local ok2, info = pcall(C_Map.GetMapInfo, resolvedMapID)
        if not ok2 or not info or not info.parentMapID or info.parentMapID == 0 then break end
        resolvedMapID = info.parentMapID
        depth = depth + 1
    end
    if not mineMapIDs[resolvedMapID] then return nil end

    local ok3, playerPos = pcall(C_Map.GetPlayerMapPosition, resolvedMapID, "player")
    if not ok3 or not playerPos then return nil end

    local ok4, px, py = pcall(playerPos.GetXY, playerPos)
    if not ok4 or not px then return nil end
    px = px * 100
    py = py * 100

    for _, mine in ipairs(Overlord.MineDatabase) do
        if self:ResourceMatchesMap(mine, resolvedMapID) then
            local dx = mine.center[1] - px
            local dy = mine.center[2] - py
            local scale = Overlord.MineMapCircleScale or 0.50
            local radius = mine.radius * scale
            if dx * dx + dy * dy <= radius * radius then
                cachedPlayerMine = mine
                return mine
            end
        end
    end

    return nil
end

-- ==================== Zones de bois ====================
-- Ressource individuelle type or.
-- { id = "wood_x", name = "...", mapID = 0, center = {x, y}, radius = 4 }.
Overlord.WoodDatabase = {
    {
        id = "wetlands_forest",
        name = (L and L.WOOD_ZONE_WETLANDS_FOREST) or "Wetlands Forest",
        mapID = 1437, mapIDs = { [56] = true, [1437] = true }, -- Les Paluns
        center = {53.8, 43.7},
        radius = 4,
    },
    {
        id = "ashenvale_forest",
        name = (L and L.WOOD_ZONE_ASHENVALE_FOREST) or "Ashenvale Forest",
        mapID = 1440, mapIDs = { [63] = true, [1440] = true },
        center = {33.6, 63.6},
        radius = 4,
    },
}

-- Forets : le cercle affiche correspond au rayon de gain reel.
Overlord.WoodMapCircleScale = 1.0

local WoodLookup = {}
local woodMapIDs = {}
for _, woodZone in ipairs(Overlord.WoodDatabase) do
    if woodZone.id then
        WoodLookup[woodZone.id] = woodZone
    end
    if woodZone.mapID then
        woodMapIDs[woodZone.mapID] = true
        for mapID in pairs(woodZone.mapIDs or {}) do woodMapIDs[mapID] = true end
    end
end

function Overlord.Zones:GetWoodZone(woodId)
    return WoodLookup[woodId]
end

function Overlord.Zones:IsWoodMapID(mapID)
    return mapID and woodMapIDs[mapID] or false
end

-- Test de contexte leger pour couper le ticker de detection ressources partout
-- ailleurs. Les sous-cartes/grottes sont resolues comme dans les detecteurs mine/bois.
local resourceContextByMapID = {}
function Overlord.Zones:IsResourceMapContext(mapID)
    if not mapID then return false end
    local cached = resourceContextByMapID[mapID]
    if cached ~= nil then return cached end
    local resolvedMapID = mapID
    local depth = 0
    while resolvedMapID and depth <= 3 do
        if mineMapIDs[resolvedMapID] or woodMapIDs[resolvedMapID] then
            resourceContextByMapID[mapID] = true
            return true
        end
        local ok, info = pcall(C_Map.GetMapInfo, resolvedMapID)
        if not ok or not info or not info.parentMapID or info.parentMapID == 0 then
            break
        end
        resolvedMapID = info.parentMapID
        depth = depth + 1
    end
    resourceContextByMapID[mapID] = false
    return false
end

local cachedPlayerWoodZone = nil
local cachedPlayerWoodZoneTime = 0
local PLAYER_WOOD_CACHE_TTL = 0.25

function Overlord.Zones:GetCurrentPlayerWoodZone()
    local now = GetTime()
    if now - cachedPlayerWoodZoneTime < PLAYER_WOOD_CACHE_TTL then
        return cachedPlayerWoodZone
    end

    cachedPlayerWoodZone = nil
    cachedPlayerWoodZoneTime = now

    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil end

    local resolvedMapID = mapID
    local depth = 0
    while not woodMapIDs[resolvedMapID] and depth < 3 do
        local ok2, info = pcall(C_Map.GetMapInfo, resolvedMapID)
        if not ok2 or not info or not info.parentMapID or info.parentMapID == 0 then break end
        resolvedMapID = info.parentMapID
        depth = depth + 1
    end
    if not woodMapIDs[resolvedMapID] then return nil end

    local ok3, playerPos = pcall(C_Map.GetPlayerMapPosition, resolvedMapID, "player")
    if not ok3 or not playerPos then return nil end

    local ok4, px, py = pcall(playerPos.GetXY, playerPos)
    if not ok4 or not px then return nil end
    px = px * 100
    py = py * 100

    for _, woodZone in ipairs(Overlord.WoodDatabase) do
        if self:ResourceMatchesMap(woodZone, resolvedMapID) and woodZone.center and woodZone.radius then
            local dx = woodZone.center[1] - px
            local dy = woodZone.center[2] - py
            if dx * dx + dy * dy <= woodZone.radius * woodZone.radius then
                cachedPlayerWoodZone = woodZone
                return woodZone
            end
        end
    end

    return nil
end

-- Normalise owner + statut : une zone « available » sans capturedTime n'est pas tenue
-- (owner résiduel après ZS/revert) - ne pas la promouvoir en captured (ex. Loch Modan).
NormalizePlayerOwnedZoneStatus = function(zone, pf)
    if zone.owner ~= pf or zone.status == "in_progress" then
        return
    end
    if zone.status == "available" then
        if zone.capturedTime and zone.capturedTime > 0 then
            zone.status = "captured"
        else
            zone.owner = nil
        end
        return
    end
    zone.status = "captured"
end

-- Throttle UpdateAvailableZones : max 1 appel par 0,15 s (coalesce les rafales ZS)
local _lastUpdateAvailableAt = 0
local _updateAvailablePending = false
local _updateAvailableSuppressNotifications = false
local UPDATE_AVAILABLE_MIN_INTERVAL = 0.15

function Overlord.Zones:UpdateAvailableZones(suppressNotifications)
    local now = GetTime()
    if now - _lastUpdateAvailableAt < UPDATE_AVAILABLE_MIN_INTERVAL then
        _updateAvailableSuppressNotifications = _updateAvailableSuppressNotifications
            or suppressNotifications == true
        if not _updateAvailablePending then
            _updateAvailablePending = true
            C_Timer.After(UPDATE_AVAILABLE_MIN_INTERVAL, function()
                _updateAvailablePending = false
                local suppress = _updateAvailableSuppressNotifications
                _updateAvailableSuppressNotifications = false
                if Overlord.Zones then
                    Overlord.Zones:_DoUpdateAvailableZones(suppress)
                end
            end)
        end
        return
    end
    _lastUpdateAvailableAt = now
    local suppress = suppressNotifications == true or _updateAvailableSuppressNotifications
    _updateAvailableSuppressNotifications = false
    self:_DoUpdateAvailableZones(suppress)
end

function Overlord.Zones:_DoUpdateAvailableZones(suppressNotifications)
    -- RestoreZoneState aboutit ici : la migration retire aussi les quarantaines
    -- terminales chargees depuis une version 9.5/9.6 avant de recalculer la chaine.
    self:MigrateLegacyCaptureFinalQuarantines()
    local pf = Overlord.PlayerFaction

    -- Annule un siege / une capture in_progress (prerequis, treve capitale, etc.)
    local function invalidateInProgressCapture(zone)
        if zone._remoteCaptureLease and not zone.holdAuthorityLocal
            and Overlord.CaptureLease and Overlord.CaptureLease.ExpireRemote then
            -- Vue distante transitoire : restauration locale du snapshot, aucun
            -- broadcast ni SaveState depuis les prerequis de cet observateur.
            Overlord.CaptureLease:ExpireRemote(zone, "availability")
            return
        end
        local wasLocalAuthority = zone.holdAuthorityLocal == true
        if wasLocalAuthority and Overlord.CaptureLease
            and Overlord.CaptureLease.BroadcastLocalRelease then
            Overlord.CaptureLease:BroadcastLocalRelease(zone)
        end
        zone.isContested = false
        zone.isPaused = false
        zone.isHolding = false
        zone.holdStartTime = nil
        if zone.holdAuthorityLocal ~= nil then
            zone.holdAuthorityLocal = nil
        end
        if zone.zsOfficialCapturerName ~= nil then
            zone.zsOfficialCapturerName = nil
        end
        zone._zsOfficialCapturerSeenAt = nil
        zone.killsCurrent = 0
        zone.holdTimeElapsed = 0
        zone.holdTimeRequired = 120
        local prevOwner = self:ResolveRevertOwnerAfterFailedCapture(zone)
        zone.previousOwner = nil
        zone.status = "captured"
        zone.owner = prevOwner
        if not zone.owner then
            zone.status = "available"
            zone.capturedTime = nil
        end
        zone._assaultFromAvailable = nil
        -- NE PAS bumper zone.updatedAt ici : si la capture est reelle (le capteur a les prereqs),
        -- son ZS "captured" / message "C" aura ts = T_capture > zone.updatedAt (stale).
        -- Bumper a time() rendrait ce ts stale identique ou superieur au ts du capteur,
        -- bloquant le message "C" (check capturedTime >= ts dans OnReceiveCapture) et le ZS
        -- "captured" (check ts > localTs dans OnReceiveZoneState) chez les observateurs secondaires.
        -- Meme raisonnement que le revert stale de ZoneControl.lua (commentaire "NE PAS ecraser updatedAt").
        local nowMsg = GetTime()
        local lastMsg = captureCancelledCooldowns[zone.id] or 0
        if nowMsg - lastMsg >= CAPTURE_CANCELLED_COOLDOWN then
            captureCancelledCooldowns[zone.id] = nowMsg
            Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. L.CAPTURE_CANCELLED, zone.name))
        end
        if Overlord.Sync then
            -- force=true : revert capteur (prereqs/treve) = etat final one-shot ; ne pas bloquer par gate login.
            Overlord.Sync:BroadcastZoneState(zone, true)
        end
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        if Overlord.MarkDirty then
            Overlord:MarkDirty()
        end
        if Overlord.SaveState then
            pcall(Overlord.SaveState, Overlord)
        end
        if Overlord.UI then Overlord.UI:RequestRefresh() end
    end

    -- Normalise d'abord toutes les zones deja possedees : les prerequis peuvent
    -- pointer vers une zone plus loin dans l'ordre du tableau (ex: Refuge -> Ar'gorok).
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        NormalizePlayerOwnedZoneStatus(zone, pf)
    end

    -- Ne pas "corriger" une capture confirmee parce que la chaine locale semble cassee.
    -- Les messages C/ZS peuvent arriver hors ordre entre joueurs ; reverter ici Newstead/Refuge
    -- vers le proprietaire du prerequis propageait de faux retours Horde. Les prerequis restent
    -- appliques avant le depart d'une capture et pour l'affichage des zones disponibles.

    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.owner == pf and zone.status == "captured" then
            -- Deja normalise dans la premiere passe ; ne pas recalculer les prereqs.
        elseif zone.status == "in_progress" then
            -- Treve : toute capture in_progress est annulee sur le front (carte fermee).
            local truceBlocks = select(1, self:IsFrontOnTruce(zone.id))
            -- Prerequis pour la faction qui CAPTURE (owner = assaillant pendant in_progress)
            local chainBroken = zone.owner and not self:FactionMeetsPrereqsForZoneCapture(
                zone.id, zone.owner, zone.holdAuthorityLocal == true)
            -- Prerequis : grace courte si ZS in_progress reseau vient d'arriver (Sync:BumpPrereqChainGrace).
            if truceBlocks then
                invalidateInProgressCapture(zone)
            elseif chainBroken then
                -- Capture ennemie : nos prereqs locaux (ex. Gilneas : chaine A/H) sont souvent
                -- en retard apres voyage / SR ; invalider ici cassait l'orange et laissait gris « Disponible ».
                local enemyCapturing = zone.owner and zone.owner ~= pf
                if enemyCapturing then
                    -- Ne pas annuler : l'etat reel arrive par ZS ; annulation = faux positif frequent.
                elseif Overlord.Sync and Overlord.Sync.ShouldDeferPrereqChainInvalidate
                    and Overlord.Sync:ShouldDeferPrereqChainInvalidate(zone.id) then
                    -- Attendre : prereqs locaux souvent en retard sur l'observateur (notre capture)
                elseif not zone.holdAuthorityLocal then
                    -- Observateur / co-captureur : ne pas publier un revert base sur nos prereqs locaux.
                    -- Le capteur officiel ou un C / ZS captured tranchera l'etat partage.
                else
                    invalidateInProgressCapture(zone)
                end
            end
        else
            -- Treve : pas de zone « disponible » tant que le front est en pause (aligne carte / pointillés / capteur).
            if select(1, self:IsFrontOnTruce(zone.id)) then
                if zone.owner == pf and zone.status == "captured" then
                    zone.status = "captured"
                else
                    zone.status = "locked"
                end
            else
            local prereqsMet = true
            local prereqIds = self:GetPrereqZoneIdsForAttacker(zone.id, pf)
            if not prereqIds then
                prereqsMet = false
            end
            if prereqIds then
                for _, prereqId in ipairs(prereqIds) do
                    local prereq = self:GetZone(prereqId)
                    -- Le prerequis doit etre COMPLETEMENT capture (status == "captured"),
                    -- pas seulement owner == pf. Une zone en "in_progress" a deja owner = pf
                    -- via le ZS broadcast mais la capture n'est pas terminee : l'accepter comme
                    -- prerequis debloque les zones suivantes trop tot (ex: hammerfell dispo
                    -- pendant la capture de Grangeneuve au lieu d'apres).
                    if not prereq or prereq.owner ~= pf or prereq.status ~= "captured"
                        or LoginQuarantineBlocksLocalGameplay(prereq) then
                        prereqsMet = false
                        break
                    end
                end
            end
            -- L'objectif final (base ennemie) nécessite TOUTES les autres zones completement capturees
            if prereqsMet then
                local enemyBaseId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(pf)
                if zone.id == enemyBaseId then
                    for _, z in ipairs(Overlord.ZoneDatabase) do
                        if z.id ~= zone.id and (z.owner ~= pf or z.status ~= "captured"
                            or LoginQuarantineBlocksLocalGameplay(z)) then
                            prereqsMet = false
                            break
                        end
                    end
                end
            end
            local old = zone.status
            if prereqsMet then
                if old ~= "available" then
                    zone.status = "available"
                    if old ~= "captured" and Overlord.InActiveFront
                        and not suppressNotifications then
                        Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.ZONE_NOW_AVAILABLE, zone.name))
                    end
                end
                if zone.status == "available" and (not zone.capturedTime or zone.capturedTime <= 0) then
                    zone.owner = nil
                end
            else
                zone.status = "locked"
            end
            end
        end
    end
end
