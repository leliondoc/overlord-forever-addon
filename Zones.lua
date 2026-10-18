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
-- 2.0.3: a point the player's faction can take now is shown in yellow, and an ordinary one
-- takes the Warfronts barracks (crossed swords). The client has the barracks in grey, blue
-- and red only: the grey one is tinted, and a copy on top in ADD mode (the "glow" texture
-- of ApplyZoneMapIcon) lifts it to the yellow of the Warfronts "Neutral" banner.
Overlord.Zones.OBJECTIVE_ATTACK_ATLAS = "Warfronts-BaseMapIcons-Empty-Barracks"
Overlord.Zones.ATTACK_COLOR = { 1, 0.82, 0 }
Overlord.Zones.ATTACK_ICON_GLOW = { 0.55, 0.45, 0.05 }

local function objectiveAtlasForOwner(owner)
    local Z = Overlord.Zones
    if owner == "Alliance" then return Z.OBJECTIVE_ALLIANCE_ATLAS end
    if owner == "Horde" then return Z.OBJECTIVE_HORDE_ATLAS end
    return Z.OBJECTIVE_NEUTRAL_ATLAS
end

-- A point the player's faction can attack now, on any front: not its own, not in progress,
-- every point before it (for that faction) held by it, every other point of the front for
-- the enemy capital, and the front not on truce (onTruce is read here when the caller does
-- not know it). Read from the owners, not from the "available" status, which is only kept
-- up to date for the front the player stands on (other fronts' maps showed no yellow).
function Overlord.Zones:IsZoneAttackable(zone, onTruce)
    local pf = Overlord.PlayerFaction
    if not zone or not pf or zone.owner == pf or zone.status == "in_progress" then return false end
    local fronts, front = Overlord.Fronts, nil
    if fronts and fronts.GetZone then front = select(2, fronts:GetZone(zone.id)) end
    local ids = front and front.prereqs and front.prereqs[pf] and front.prereqs[pf][zone.id]
    if not ids then return false end
    for _, id in ipairs(ids) do
        local held = fronts:GetZone(id)
        if not held or held.owner ~= pf or held.status == "in_progress" or held._loginSyncUnconfirmed then
            return false
        end
    end
    if zone.id == fronts:GetEnemyCapitalId(pf, front.id) then
        for _, other in ipairs(front.zones or {}) do
            if other.id ~= zone.id and (other.owner ~= pf or other.status == "in_progress"
                or other._loginSyncUnconfirmed) then
                return false
            end
        end
    end
    if onTruce == nil then onTruce = self:IsFrontOnTruce(zone.id, front.id) end
    return not onTruce
end

-- Applique une icone de zone sur une texture de la carte. La taille reste celle posee par
-- l'appelant (AnchorZoneIcon) : l'atlas ne l'impose pas. glow (optional): a second texture
-- laid over tex, shown only for the attack icon (see OBJECTIVE_ATTACK_ATLAS).
function Overlord.Zones:ApplyZoneMapIcon(tex, atlas, glow)
    if not tex or not atlas or atlas == "" or not tex.SetAtlas then return false end
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetVertexColor(1, 1, 1, 1)
    local ok, applied = pcall(tex.SetAtlas, tex, atlas, false)
    local attack = ok and atlas == self.OBJECTIVE_ATTACK_ATLAS
    if attack then
        local c = self.ATTACK_COLOR
        tex:SetVertexColor(c[1], c[2], c[3], 1)
    end
    if glow then
        if attack and glow.SetAtlas and pcall(glow.SetAtlas, glow, atlas, false) then
            local c = self.ATTACK_ICON_GLOW
            glow:SetTexCoord(0, 1, 0, 1)
            glow:SetBlendMode("ADD")
            glow:SetVertexColor(c[1], c[2], c[3], 1)
            glow:Show()
        else
            glow:Hide()
        end
    end
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
function Overlord.Zones:GetZoneMapIconAtlas(zone, hideWhenContestedWithOwner, attackable)
    if not zone then return self.OBJECTIVE_NEUTRAL_ATLAS end

    -- attackable: the caller's IsZoneAttackable (capitals keep their main hall).
    if attackable and not zone.isCapital and zone.status ~= "in_progress" then
        return self.OBJECTIVE_ATTACK_ATLAS
    end

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
-- 2.0.2: the truce is retired. A victory dated from TRUCELESS_FROM on opens none: the
-- front is the winner's at once, the fallen capital takes its kept stamp at once (one
-- second after the victory) and the loser may take points back at once; the 6 hours
-- between two victories of a front stay. The date is the weekly reset of Tuesday
-- 2026-10-20, 08:00 UTC (2.0.3: the map layout cut already leaves every older client
-- out of the map exchange, so the week first left for 2.0.2 to spread is not needed;
-- 2.0.2 itself keeps 2026-10-27), when every map and every truce is wiped anyway: all
-- clients change rule on the same empty map, and no truce-end record of the old rule
-- survives (see TruceSecondsOfEpoch). It must stay a weekly reset. Before it nothing
-- changes; nil = never.
-- Why a date: a client without the truce next to clients that still have it gave two
-- maps for 25 minutes after a victory, then a legitimate capture erased everywhere
-- (bench of 86 clients, 2026-10-14). Clients that do not run this rule are therefore
-- left out of the map exchange from the same moment (SyncRelay, "~t0"): update required.
Overlord.Zones.TRUCELESS_FROM = 1792483200
local function TruceSecondsFor(victoryTs)
    local from = tonumber(Overlord.Zones.TRUCELESS_FROM)
    victoryTs = tonumber(victoryTs)
    if from and victoryTs and victoryTs >= from then return 0 end
    return CAPITAL_VICTORY_COOLDOWN
end
-- The truce length behind a truce-end date: every truce-end record of an earlier week is
-- wiped by the weekly reset, so a record dated from TRUCELESS_FROM on is a victory's own
-- moment.
local function TruceSecondsOfEpoch(epoch)
    return TruceSecondsFor(epoch)
end
-- True once victories open no truce any more (by the server clock).
function Overlord.Zones:IsTruceRetired(at)
    at = tonumber(at) or (Overlord.ServerNow and Overlord.ServerNow()) or time()
    return TruceSecondsFor(at) == 0
end
-- 1.7 : une nouvelle victoire sur un meme front ne compte que 6 h apres la precedente
-- (la capitale peut etre reprise entre-temps : le combat continue, sans bonus ni treve).
local VICTORY_SPACING = 6 * 3600
-- Fin de treve : la capitale tombee reste au vainqueur, re-horodatee une seconde apres
-- l'epoch. Plus recente que l'etat d'un client 1.6.x (capitale rendue a l'epoch), elle
-- l'emporte partout ; et l'ecart d'une seconde avec les autres zones (epoch) la signe.
local CAPITAL_KEPT_STAMP_OFFSET = 1
-- Fenetre de tolerance (horloges) pour reconnaitre une fin de treve deja appliquee.
local CAPITAL_STAMP_SLACK = 5
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
-- The list is shared: callers read it, never change it. Fronts, their zones and their
-- orders are fixed tables (Fronts.lua): the list is built once per front and faction.
-- (The panel, the HUD and the observers asked for it several times a second, each time
-- a new table and a search of the front's zones for every zone.)
function Overlord.Zones:GetDisplayOrderForFront(frontId)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front then return {} end
    local order = front.displayOrder and front.displayOrder[Overlord.PlayerFaction]
    local cache = self._displayOrderCache
    if not cache then
        cache = {}
        self._displayOrderCache = cache
    end
    local hit = cache[front]
    if hit and hit.order == order and hit.zones == front.zones and hit.count == #(front.zones or {}) then
        return hit.out
    end
    local out = {}
    cache[front] = { order = order, zones = front.zones, count = #(front.zones or {}), out = out }
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

-- ApplyFactionConfig initialise seulement le front actif. Sans SavedVariables,
-- les capitales des six autres fronts restent owner=nil : un ZA global les
-- serialise alors en N et chaque receveur rejette le lot entier. Completer les
-- bases absentes APRES restore, sans toucher aux captures ni aux baux existants.
function Overlord.Zones:InitializeMissingCapitalDefaults()
    local fronts = Overlord.Fronts and Overlord.Fronts.Registry
    if not fronts then return end
    local campaignStart = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if campaignStart <= 0 then return end
    for frontId, front in pairs(fronts) do
        local resetEpoch = OverlordDB and OverlordDB.frontTruceResetEpoch
            and tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0
        local baseline = math.max(campaignStart, resetEpoch)
        for _, zone in ipairs(front.zones or {}) do
            local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
            if fixedOwner and not zone.owner and zone.status ~= "in_progress"
                and not zone._captureFinalUnattested
                and (tonumber(zone.capturedTime) or 0) <= 0 then
                zone.owner = fixedOwner
                zone.status = fixedOwner == Overlord.PlayerFaction and "captured" or "locked"
                zone.capturedTime = baseline
                zone.updatedAt = baseline
            end
        end
    end
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
        or math.max(0, (Overlord.ServerNow and Overlord.ServerNow() or time()) - (zone.updatedAt or 0))
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
                -- The hold was already complete at logout (online, the client would
                -- have finalized it): date it from the logout, in server time, not from
                -- this login. A login stamp looked like a fresh capture in Recent
                -- activity and went out as such in this client's ZA.
                local serverNow = Overlord.ServerNow and Overlord.ServerNow() or time()
                zone.capturedTime = math.max(1, math.floor(serverNow - offlineSec))
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
        zone.updatedAt = (Overlord.ServerNow and Overlord.ServerNow() or time())
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
    if zoneId:sub(1, 5) == "loch_" then return "loch_modan" end
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
    if frontId == "loch_modan" then return L.FRONT_LOCH_MODAN_NAME end
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
    local age = math.max(0, (Overlord.ServerNow and Overlord.ServerNow() or time()) - ts)
    return math.min(req, base + age)
end

-- victoryTs: the victory whose truce is meant (2.0.2: none from TRUCELESS_FROM on).
-- Without it, the rule in force now.
function Overlord.Zones:GetVictoryCooldownSeconds(victoryTs)
    return TruceSecondsFor(victoryTs or (Overlord.ServerNow and Overlord.ServerNow()) or time())
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
    -- A new state is a new siege wave for the prerequisite catch-up (SyncAux).
    zone._prereqMismatchOwner = nil
    zone._prereqMismatchRounds = nil
    zone._prereqMismatchLastAt = nil
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
    if zone._loginSyncUnconfirmed then return false end
    return (tonumber(zone.capturedTime) or 0) > 0
end

-- Zones du front qui ne sont pas encore au gagnant (carte encore disputee).
-- victoryTs (2.0.2, only where a victory announced for that moment is being proven): a
-- point the other faction took strictly after it, within the truce that follows, is not
-- counted. No capture is allowed then: it was made by a player who had not heard the
-- victory, and it used to keep every client that had not accepted the victory yet out
-- of the truce for good, on two maps (see tests/forever_victory_late_capture.test.lua).
-- Only while the truce of that victory runs (an old announcement replayed later gets
-- the plain count). Also returns how many points were set aside, and how many points
-- other than the fallen capital the winner still holds from before the victory.
-- 2.0.2, a victory without a truce: the loser may take points back at once, and those
-- captures are legitimate; a client that learns the victory late (through a Battle.net
-- bridge, after a battleground) must still believe it. They are set aside for as long as
-- an announcement is believed at all (2 h, the age limit of a TV).
local VICTORY_PROOF_LATE_SECONDS = 2 * 3600
local function ProofSetAsideSeconds(victoryTs)
    local truce = TruceSecondsFor(victoryTs)
    return truce > 0 and truce or VICTORY_PROOF_LATE_SECONDS
end
function Overlord.Zones:CountZonesNotOwnedByOnFront(frontId, faction, victoryTs)
    if not frontId or not faction or not Overlord.Fronts then return 999 end
    local front = Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return 999 end
    victoryTs = tonumber(victoryTs)
    if victoryTs and (victoryTs <= 0 or (Overlord.ServerNow and Overlord.ServerNow() or time())
        > victoryTs + ProofSetAsideSeconds(victoryTs)) then victoryTs = nil end
    local capitalId = victoryTs and Overlord.Fronts:GetEnemyCapitalId(faction, frontId) or nil
    local n, setAside, heldBefore = 0, 0, 0
    for _, z in ipairs(front.zones) do
        local zd = select(1, Overlord.Fronts:GetZone(z.id, frontId))
        if zd and (zd.owner ~= faction or zd._loginSyncUnconfirmed) then
            local ct = tonumber(zd.capturedTime) or 0
            local afterVictory = victoryTs and not zd._loginSyncUnconfirmed
                and (zd.owner == "Alliance" or zd.owner == "Horde") and zd.status ~= "in_progress"
                and ct > victoryTs and ct <= victoryTs + ProofSetAsideSeconds(victoryTs)
            if afterVictory then setAside = setAside + 1 else n = n + 1 end
        elseif zd and victoryTs and z.id ~= capitalId
            and (tonumber(zd.capturedTime) or 0) <= victoryTs then
            heldBefore = heldBefore + 1
        end
    end
    return n, setAside, heldBefore
end

-- Treve sync (SR/VT) valide seulement si l'etat local correspond a une vraie victoire totale.
function Overlord.Zones:LocalStateSupportsVictoryTruce(frontId, winningFaction, victoryTs)
    if not self:ConfirmsFrontCapitalCaptured(frontId, winningFaction) then
        return false
    end
    local missing, setAside, heldBefore = self:CountZonesNotOwnedByOnFront(frontId, winningFaction, victoryTs)
    -- Points set aside never make a front the loser retook entirely look like a victory.
    return missing == 0 and (setAside == 0 or heldBefore > 0)
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
    OverlordDB.frontCapitalImmuneFrom = nil -- 1.7: no capital protection any more
    if Overlord.Sync and Overlord.Sync.ClearTruceReleaseState then
        Overlord.Sync:ClearTruceReleaseState()
    end
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
    -- 2.0.2, no truce: a point taken after the victory (by the loser, or retaken later by
    -- the winner) is legitimate and newer. A client that learns the victory late keeps it
    -- (every client that heard the victory in time holds it too); only what is dated before
    -- is repainted.
    local truceless = TruceSecondsFor(ts) == 0

    for _, zone in ipairs(front.zones) do
        if not (truceless and zone.owner and zone.status ~= "in_progress"
                and not zone._loginSyncUnconfirmed and (tonumber(zone.capturedTime) or 0) > ts) then
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
    end

    -- 2.0.2, no truce: the fallen capital is "kept" from the first second (the stamp a
    -- truce end used to give it fifteen minutes later). Every client that repaints a
    -- victory holds the same dates at once, whatever the order of its own bookkeeping,
    -- and a kept capital is never read as a new victory.
    if TruceSecondsFor(ts) == 0 and Overlord.Fronts.GetEnemyCapitalId then
        local capitalId = Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
        local capital = capitalId and select(1, Overlord.Fronts:GetZone(capitalId, frontId))
        if capital and capital.owner == winningFaction then
            capital.capturedTime = ts + CAPITAL_KEPT_STAMP_OFFSET
            capital.updatedAt = capital.capturedTime
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
    -- Reset hebdo : les treves de la campagne precedente ne bloquent plus
    local lastReset = (OverlordDB.lastResetTimestamp and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if lastReset > 0 and victoryTimestamp < lastReset then
        return false, 0, nil, victoryFrontId
    end
    -- Horloge serveur : un PC en avance ne termine pas la treve trop tot.
    local elapsed = ((Overlord.ServerNow and Overlord.ServerNow()) or time()) - victoryTimestamp
    local remaining = TruceSecondsFor(victoryTimestamp) - elapsed
    if remaining > 0 and winningFaction then
        -- Treve orpheline (SR/VT sans TV) : carte mixte -> pas de blocage gameplay ni UI grisee.
        if self:LocalStateSupportsVictoryTruce(victoryFrontId, winningFaction) then
            return true, remaining, winningFaction, victoryFrontId
        end
    end
    return false, 0, nil, victoryFrontId
end

local NormalizePlayerOwnedZoneStatus

-- Recalcule UNIQUEMENT les statuts locked/available des zones sans proprietaire d'un front
-- INACTIF apres une sync passive (C / ZS / ZA) : un prerequis vient peut-etre d'etre (de)bloque
-- et le statut local-only restait fige (ex. "Verrouillee" fantome alors que la chaine est verte).
-- Non destructif : ne touche
-- jamais owner, capturedTime, updatedAt, ni les zones possedees ou in_progress.
function Overlord.Zones:RefreshInactiveFrontAvailability(frontId)
    if not frontId then return end
    if Overlord.Fronts and Overlord.Fronts.activeFrontId == frontId then return end
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

local function NowServer()
    return (Overlord.ServerNow and Overlord.ServerNow()) or time()
end

local function CurrentCampaignStartTs()
    return (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
end

-- Socle stable d'une zone : elle-meme, ou l'etat confirme sous une capture en cours
-- (bail local ou distant). nil si aucun socle fiable n'existe.
local function StableZoneView(zone)
    if not zone or zone.status ~= "in_progress" then return zone end
    local base = zone._localCaptureBase
    if not base and Overlord.CaptureLease and Overlord.CaptureLease.GetPersistableView then
        base = Overlord.CaptureLease:GetPersistableView(zone)
    end
    if type(base) ~= "table" or base == zone or base.status == "in_progress" then return nil end
    return base
end
function Overlord.Zones:GetStableZoneView(zone) return StableZoneView(zone) end

-- Fin de treve (1.7) : rien ne revient. La capitale tombee reste au vainqueur jusqu'a ce
-- que sa faction la reprenne. ZA transporte capturedTime : une zone gardee sous l'epoch
-- ferait refuser le lot entier par chaque pair qui porte le tombstone, d'ou le
-- re-horodatage (epoch, et une seconde de plus pour la capitale tombee).
function Overlord.Zones:KeepFrontConquestAtTruceEnd(frontId, epoch)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    epoch = tonumber(epoch) or 0
    if not front or not front.zones or epoch <= 0 then return false end

    for _, zone in ipairs(front.zones) do
        zone.killsCurrent = 0
        zone.allyKillsCurrent = 0
        zone.enemyKillsCurrent = 0
        -- Une capture deja lancee a l'epoch (les defenceurs reprennent leur capitale)
        -- re-horodate son socle : si elle echoue, la zone revient au meme etat que
        -- chez les clients passes avant elle.
        local target = StableZoneView(zone)
        if target and target.owner then
            local fixedOwner = self:GetBaseZoneFixedOwner(zone.id)
            local floorTs = epoch
            if fixedOwner and target.owner ~= fixedOwner then
                floorTs = epoch + CAPITAL_KEPT_STAMP_OFFSET
            end
            -- Jamais d'horloge reculee : une zone reprise apres l'epoch garde la sienne.
            target.capturedTime = math.max(tonumber(target.capturedTime) or 0, floorTs)
            target.updatedAt = math.max(tonumber(target.updatedAt) or 0, target.capturedTime)
        elseif target then
            target.updatedAt = math.max(tonumber(target.updatedAt) or 0, epoch)
        end
    end

    if Overlord.Fronts.activeFrontId == frontId and self.RebuildZoneLookup then
        self:RebuildZoneLookup()
    end
    if Overlord.Fronts.activeFrontId == frontId then
        self:UpdateAvailableZones()
    elseif self.RefreshInactiveFrontAvailability then
        self:RefreshInactiveFrontAvailability(frontId)
    end
    return true
end

-- Derniere victoire connue sur ce front (horloge serveur) : treve en cours, fin de treve
-- appliquee (epoch - 15 min) ou journal de domination (replique a tous, meme hors front).
function Overlord.Zones:GetPreviousFrontVictoryTs(frontId)
    if not frontId then return 0 end
    local latest = 0
    local victory = OverlordDB and OverlordDB.frontVictories and OverlordDB.frontVictories[frontId]
    if type(victory) == "table" then
        latest = math.max(latest, math.floor(tonumber(victory.timestamp) or 0))
    end
    local resetEpoch = OverlordDB and OverlordDB.frontTruceResetEpoch
        and math.floor(tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0) or 0
    if resetEpoch > 0 then latest = math.max(latest, resetEpoch - TruceSecondsOfEpoch(resetEpoch)) end
    if Overlord.GetLatestDominationVictoryForFront then
        local journalTs = Overlord:GetLatestDominationVictoryForFront(frontId)
        latest = math.max(latest, math.floor(tonumber(journalTs) or 0))
    end
    -- Une victoire de la campagne precedente ne retient rien apres le reset hebdo.
    local campaignStart = CurrentCampaignStartTs()
    if campaignStart > 0 and latest < campaignStart then return 0 end
    return latest
end

-- Regle (b) : la meme victoire (a quelques secondes pres) reste valide ; une autre sur ce
-- front ne compte que 6 h apres la precedente. Retourne ok et l'heure a partir de laquelle
-- une victoire comptera. Meme decision partout : capteur, TV, VB et carte.
function Overlord.Zones:IsFrontVictoryAllowed(frontId, victoryTs)
    victoryTs = math.floor(tonumber(victoryTs) or 0)
    local previous = self:GetPreviousFrontVictoryTs(frontId)
    if previous <= 0 or victoryTs <= 0 then return true, 0 end
    if math.abs(victoryTs - previous) <= CAPITAL_STAMP_SLACK then return true, 0 end
    local allowedFrom = previous + VICTORY_SPACING
    return victoryTs >= allowedFrom, allowedFrom
end

function Overlord.Zones:GetVictorySpacingSeconds()
    return VICTORY_SPACING
end

local function FrontZoneView(zone, frontId)
    return (Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zone.id, frontId))) or zone
end

-- Capitale gardee a une fin de treve, jamais une capture fraiche : elle porte une seconde
-- de plus qu'une autre zone du front tenue par le meme camp (toutes a l'epoch). Une vraie
-- prise de capitale suit d'au moins 8 min la derniere zone conquise.
function Overlord.Zones:IsKeptCapitalStamp(frontId, capital)
    local ct = math.floor(tonumber(capital and capital.capturedTime) or 0)
    if ct <= 0 or not capital.owner then return false end
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    for _, z in ipairs((front and front.zones) or {}) do
        if z.id ~= capital.id then
            local zd = FrontZoneView(z, frontId)
            if zd.owner == capital.owner and zd.status ~= "in_progress"
                and math.floor(tonumber(zd.capturedTime) or 0) == ct - CAPITAL_KEPT_STAMP_OFFSET then
                return true
            end
        end
    end
    return false
end

-- 2.0.2: the victory checks read this one. A kept stamp left by a truce end is never a
-- new victory. A truce-less victory's own stamp (capital at victory + 1 with the points
-- at the victory, see ForceSyncFrontToWinner) is one only for a client that has not filed
-- that victory yet: a client that got the repainted front before the victory itself must
-- still believe it (record, screen, 6 h spacing), and one that filed it is not told it
-- again (after a /reload, by a replayed announcement). In the first 15 min after
-- TRUCELESS_FROM a truce of the day before could end there: read as kept, as before.
function Overlord.Zones:IsKeptCapitalAfterTruce(frontId, capital)
    if not self:IsKeptCapitalStamp(frontId, capital) then return false end
    local ct = math.floor(tonumber(capital.capturedTime) or 0)
    if TruceSecondsFor(ct - CAPITAL_KEPT_STAMP_OFFSET - CAPITAL_VICTORY_COOLDOWN) > 0 then return true end
    local filed = OverlordDB and type(OverlordDB.frontTruceResetEpoch) == "table"
        and math.floor(tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0) or 0
    return filed > 0 and math.abs(filed - (ct - CAPITAL_KEPT_STAMP_OFFSET)) <= CAPITAL_STAMP_SLACK
end

-- 2.0.2: the truce-less victory filed for this front (its moment and winner), read from
-- the map itself: the fallen capital still held by the winner with the victory's kept
-- stamp. nil when none, or when the capital was retaken since (nobody could prove it).
function Overlord.Zones:GetFiledTrucelessVictory(frontId)
    local vts = OverlordDB and type(OverlordDB.frontTruceResetEpoch) == "table"
        and math.floor(tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0) or 0
    if vts <= 0 or TruceSecondsFor(vts) > 0 or not Overlord.Fronts or not Overlord.Fronts.GetEnemyCapitalId then
        return nil
    end
    for _, winner in ipairs({ "Alliance", "Horde" }) do
        local capId = Overlord.Fronts:GetEnemyCapitalId(winner, frontId)
        local cap = capId and select(1, Overlord.Fronts:GetZone(capId, frontId))
        if cap and cap.owner == winner and cap.status ~= "in_progress"
            and math.abs(math.floor(tonumber(cap.capturedTime) or 0) - (vts + CAPITAL_KEPT_STAMP_OFFSET)) <= CAPITAL_STAMP_SLACK then
            return vts, winner
        end
    end
    return nil
end

-- Fin de treve deja recue par ZA avant FR (ou vue au login) : la capitale du perdant est
-- restee au vainqueur, re-horodatee une seconde apres l'epoch.
function Overlord.Zones:LocalStateShowsKeptConquest(frontId, winningFaction, resetEpoch)
    if not frontId or not winningFaction or not resetEpoch or not Overlord.Fronts then return false end
    local capId = Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
    local cap = capId and select(1, Overlord.Fronts:GetZone(capId, frontId))
    if not cap or cap.status == "in_progress" or cap.owner ~= winningFaction then return false end
    return math.abs((tonumber(cap.capturedTime) or 0) - (resetEpoch + CAPITAL_KEPT_STAMP_OFFSET))
        <= CAPITAL_STAMP_SLACK
end

-- Vainqueur d'une fin de treve lu sur la carte seule (retardataire sans victoire connue) :
-- nil si les deux camps correspondent.
function Overlord.Zones:KeptConquestWinnerFromMap(frontId, epoch)
    local winner
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        if self:LocalStateShowsKeptConquest(frontId, faction, epoch) then
            if winner then return nil end
            winner = faction
        end
    end
    return winner
end

-- Fin de treve : la conquete reste entiere, la capitale tombee comprise.
function Overlord.Zones:ApplyFrontTruceEndReset(frontId, resetEpoch, fromSync)
    if not frontId or not resetEpoch or resetEpoch <= 0 then return false end
    if not OverlordDB then return false end
    OverlordDB.frontTruceResetEpoch = OverlordDB.frontTruceResetEpoch or {}
    local truceSeconds = TruceSecondsOfEpoch(resetEpoch)
    if (OverlordDB.frontTruceResetEpoch[frontId] or 0) >= resetEpoch then
        -- 2.0.2, no truce: the record of this very victory has nothing left to wait for.
        if truceSeconds == 0 then
            local victory = OverlordDB.frontVictories and OverlordDB.frontVictories[frontId]
            if victory and math.floor(tonumber(victory.timestamp) or 0) <= resetEpoch then
                self:ClearFrontVictory(frontId)
            end
        end
        return false
    end
    -- Victoire de la campagne precedente (client pas encore passe au reset hebdo) :
    -- ne jamais re-horodater cette conquete dans la nouvelle semaine.
    local campaignStart = CurrentCampaignStartTs()
    if campaignStart > 0 and resetEpoch - truceSeconds < campaignStart then
        return false
    end
    if not self:KeepFrontConquestAtTruceEnd(frontId, resetEpoch) then return false end

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
        -- Connexion tardive : pas d'annonce perimee dans le chat.
        -- (2.0.2: no truce, nothing ended.)
        if truceSeconds > 0 and L.FRONT_TRUCE_ENDED_KEPT
            and resetEpoch + CAPITAL_VICTORY_COOLDOWN > NowServer() then
            Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.FRONT_TRUCE_ENDED_KEPT,
                mapLabel))
        end
        -- 2.0.2: nothing is announced. Every client that holds the victory ends its truce
        -- by itself at this same second and gives the conquest these same dates.
    end

    return true
end

-- "Capitale liberee" : une faction reprend sa propre capitale a l'ennemi. Lu sur la carte
-- (deux capitales par front) ; seulement pour une prise recente (pas au login ni au reset
-- hebdo) vue en direct (C/ZS recus, ou capture locale) : une carte ZA seule, d'une seule
-- source, ne fait pas imprimer la ligne a tout le monde. Aucun trafic.
local capitalOwnerSeen = {}
function Overlord.Zones:CheckCapitalLiberations()
    local fronts = Overlord.Fronts and Overlord.Fronts.Registry
    if not fronts or Overlord.InstanceSuspended then return end
    local now = NowServer()
    local campaignStart = CurrentCampaignStartTs()
    for frontId, front in pairs(fronts) do
        for _, capId in ipairs({ front.allianceCapitalId or false, front.hordeCapitalId or false }) do
            local zone = capId and select(1, Overlord.Fronts:GetZone(capId, frontId))
            if zone and zone.status ~= "in_progress" and zone.owner then
                local native = self:GetBaseZoneFixedOwner(capId)
                local seen = capitalOwnerSeen[capId]
                if seen and seen ~= native and zone.owner == native
                    and now - (tonumber(zone.capturedTime) or 0) <= 120
                    and (tonumber(zone.capturedTime) or 0) > campaignStart
                    and (not Overlord.Sync or not Overlord.Sync.HasRecentLiveZoneTraffic
                        or Overlord.Sync:HasRecentLiveZoneTraffic(capId, 300))
                    and L.FRONT_CAPITAL_LIBERATED then
                    local mapLabel = self:GetFrontMapDisplayName(frontId) or frontId
                    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r "
                        .. L.FRONT_CAPITAL_LIBERATED, zone.name or capId, mapLabel))
                end
                capitalOwnerSeen[capId] = zone.owner
            end
        end
    end
end

-- Carte disque (quarantaine login comprise) encore figee sur la victoire : le login
-- ne doit pas la prendre pour une victoire fantome et laisser la capitale au vainqueur.
local function DiskStateShowsFrontVictory(frontId, winningFaction, victoryTs)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return false end
    local capId = Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
    if not capId then return false end
    for _, z in ipairs(front.zones) do
        local zd = select(1, Overlord.Fronts:GetZone(z.id, frontId)) or z
        if zd.owner ~= winningFaction or zd.status == "in_progress"
            or zd._captureFinalUnattested then
            return false
        end
        if z.id == capId and math.abs((tonumber(zd.capturedTime) or 0) - victoryTs)
            > CAPITAL_STAMP_SLACK then
            return false
        end
    end
    return true
end

-- Fin de treve vue apres le debut de la reprise : les defenseurs ont lance la capture de
-- leur capitale (ou l'ont deja reprise) avant le tick de 30 s de ce client. La victoire
-- etait reelle : la carte la montre sur le socle stable des zones en cours de capture, et
-- une capitale revenue a sa faction a l'epoch ou apres est une liberation, pas un fantome.
local function StableStateShowsTruceEnd(frontId, winningFaction, victoryTs, epoch)
    local front = Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return false end
    local capId = Overlord.Fronts:GetEnemyCapitalId(winningFaction, frontId)
    if not capId then return false end
    local native = Overlord.Zones:GetBaseZoneFixedOwner(capId)
    local sawCapital = false
    for _, z in ipairs(front.zones) do
        local zd = FrontZoneView(z, frontId)
        if zd._captureFinalUnattested then return false end
        local sv = StableZoneView(zd)
        if not sv then return false end
        local ct = tonumber(sv.capturedTime) or 0
        if z.id == capId then
            -- Tenue : a l'heure de la victoire, ou deja re-horodatee par cette fin de treve
            -- (ZA d'un pair passe avant nous, recu avant son FR).
            local held = sv.owner == winningFaction and (math.abs(ct - victoryTs) <= CAPITAL_STAMP_SLACK
                or math.abs(ct - (epoch + CAPITAL_KEPT_STAMP_OFFSET)) <= CAPITAL_STAMP_SLACK)
            local liberated = native ~= nil and sv.owner == native and ct >= epoch - CAPITAL_STAMP_SLACK
            if not held and not liberated then return false end
            sawCapital = true
        elseif sv.owner ~= winningFaction then
            return false
        end
    end
    return sawCapital
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
    -- Coupure en instance : ni fin de treve, ni message, ni FR (le ticker reprend apres).
    if Overlord.InstanceSuspended then return end
    self:CheckCapitalLiberations()
    if Overlord.Sync and Overlord.Sync.RetryPendingTruceReleases then
        Overlord.Sync:RetryPendingTruceReleases()
    end
    local victories = OverlordDB.frontVictories
    if not victories then return end

    local lastReset = tonumber(OverlordDB.lastResetTimestamp) or 0
    local toProcess = {}
    for frontId, victory in pairs(victories) do
        local victoryTs = tonumber(victory.timestamp) or 0
        local winningFaction = victory.faction
        if victoryTs > 0 and winningFaction
            and (lastReset <= 0 or victoryTs >= lastReset)
            and victoryTs >= CurrentCampaignStartTs() then
            -- Horloge serveur : un PC en avance ne termine pas la treve trop tot.
            if NowServer() - victoryTs >= TruceSecondsFor(victoryTs) then
                toProcess[#toProcess + 1] = {
                    frontId = frontId,
                    victoryTs = victoryTs,
                    winningFaction = winningFaction,
                }
            end
        end
    end

    for _, entry in ipairs(toProcess) do
        local epoch = entry.victoryTs + TruceSecondsFor(entry.victoryTs)
        -- Fin de treve + message seulement si la carte locale confirme une vraie victoire totale (pas SR/VT fantome).
        if self:LocalStateSupportsVictoryTruce(entry.frontId, entry.winningFaction) then
            self:ApplyFrontTruceEndReset(entry.frontId, epoch, false)
        elseif self:LocalStateShowsKeptConquest(entry.frontId, entry.winningFaction, epoch)
            or DiskStateShowsFrontVictory(entry.frontId, entry.winningFaction, entry.victoryTs) then
            -- Meme fin de treve, deja propagee ou vue au login : appliquer sans rediffuser.
            self:ApplyFrontTruceEndReset(entry.frontId, epoch, true)
        elseif StableStateShowsTruceEnd(entry.frontId, entry.winningFaction, entry.victoryTs, epoch) then
            self:ApplyFrontTruceEndReset(entry.frontId, epoch, false)
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

-- Test de contexte leger pour couper le ticker de detection ressources partout
-- ailleurs. Les sous-cartes/grottes sont resolues comme dans le detecteur de mines.
local resourceContextByMapID = {}
function Overlord.Zones:IsResourceMapContext(mapID)
    if not mapID then return false end
    local cached = resourceContextByMapID[mapID]
    if cached ~= nil then return cached end
    local resolvedMapID = mapID
    local depth = 0
    while resolvedMapID and depth <= 3 do
        if mineMapIDs[resolvedMapID] then
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
