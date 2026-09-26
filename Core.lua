-- Core.lua - Point d'entrée principal de l'addon Overlord
Overlord = Overlord or {}
Overlord.Version = "1.0.27"
-- Forever uses one global community. The beta relay remains enabled in parallel
-- so non-members and temporarily unavailable C_Club rosters still converge.
Overlord.CommunityModeEnabled = true
Overlord.BetaNetworkEnabled = true
Overlord.IsInitialized = false
Overlord.PlayerFaction = nil
Overlord.InActiveFront = false
Overlord.InstanceSuspended = false
-- Garde-fou technique pour les secondes de domination : tres au-dessus du gameplay,
-- mais evite une valeur corrompue/infinie dans SavedVariables, sync ou export.
Overlord.DOMINATION_SANITY_CAP = 2147483647
-- Plafond absolu par front/faction. Le garde dynamique reseau reste bien plus
-- strict en debut de semaine ; 500 M permet toutefois aux bonus bois legitimes
-- de se composer lors d'une campagne tres active sans couper la convergence.
-- La migration 11 purge une derniere fois les anciens buckets >= 50 M avant
-- d'adopter ce nouveau plafond (anciens bugs d'amplification).
Overlord.DOMINATION_PLAUSIBLE_MAX = 500000000

-- Palette tooltips unifiee (accent = ligne « pas assez d'or », Ressources / mines / shard / export)
Overlord.UI_TT = {
    HL   = { 1.0, 0.82, 0.0 },   -- or UI Blizzard (#FFD100) : titres, alertes, lignes d'action
    BODY = { 1.0, 1.0, 1.0 },
    MUTED = { 0.72, 0.72, 0.72 },
}

-- Invitation serveur Discord Overlord (bouton Actions du panneau principal).
Overlord.DISCORD_INVITE_URL = "https://discord.com/invite/53VrYYtPz5"
-- Atlas officiel Blizzard (Interface/ChatFrame/UIChatIcon).
Overlord.DISCORD_BUTTON_ATLAS = "UI-ChatIcon-Discord"

local L = Overlord.L

-- Verrou anti-capture instantanee apres login / sortie d'instance.
-- Tant qu'au moins une sync n'a pas ete recue, le client local observe la carte
-- mais ne devient pas autorite de capture.
local CAPTURE_SYNC_GATE_TIMEOUT = 45
-- Settle : temps minimum apres la premiere sync recue avant d'autoriser les captures.
-- 8s laisse le temps aux reponses cross-faction (bridges BNet, communaute) d'arriver
-- et d'ecraser les donnees potentiellement stale de la meme faction.
local CAPTURE_SYNC_SETTLE_SECONDS = 8
local CAPTURE_SYNC_REMOTE_ADOPT_RESET_SECONDS = 45
local staleSessionUpdatedAtZeroed = false
local captureSyncGate = {
    active = false,
    reason = nil,
    expiresAt = 0,
    settleUntil = 0,
    remoteAdoptResetUntil = 0,
    notified = false,
    notifiedZoneId = nil,
    receivedDuringGate = false,
    gkReceivedDuringGate = false,
}

-- Apres timeout gate sans sync : updatedAt=0 pour que le premier ZS distant gagne (solo login).
-- Ne pas toucher in_progress : sinon interpolation carte figee a 00:00 (regression 6.3.x).
local function ZeroActiveFrontZonesForSyncCatchup()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    if not front or not front.zones or not Overlord.Zones or not Overlord.Zones.GetZone then return end
    for _, z in ipairs(front.zones) do
        local zd = Overlord.Zones:GetZone(z.id)
        if zd and zd.status ~= "in_progress" then
            zd.updatedAt = 0
        end
    end
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

local function ZeroGuildKeepsForSyncCatchup()
    if not OverlordDB or not OverlordDB.guildKeeps then return end
    for _, saved in pairs(OverlordDB.guildKeeps) do
        if type(saved) == "table" and saved.status ~= "in_progress" then
            saved.updatedAt = 0
        end
    end
    if Overlord.GuildKeep and Overlord.GuildKeep.MarkDirty then
        Overlord.GuildKeep:MarkDirty()
    end
end

local function ClearLoginUnconfirmedZoneState()
    local seen = {}
    local changed = false
    local function clearZone(zone)
        if not zone or not zone.id or seen[zone.id] then return end
        seen[zone.id] = true
        if zone._loginSyncUnconfirmed then
            zone._loginSyncUnconfirmed = nil
            changed = true
        end
    end

    if Overlord.Fronts and Overlord.Fronts.Registry then
        for _, front in pairs(Overlord.Fronts.Registry) do
            if front and front.zones then
                for _, zone in ipairs(front.zones) do
                    clearZone(zone)
                end
            end
        end
    end
    for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
        clearZone(zone)
    end
    return changed
end

function Overlord:ClearLoginUnconfirmedZoneState()
    return ClearLoginUnconfirmedZoneState()
end

-- Invalidation visuelle legere des transitions de quarantaine. La carte peut
-- etre ouverte sans que le panneau principal ou le HUD le soient : elle doit
-- donc etre rafraichie explicitement quand SYNC apparait ou disparait.
function Overlord:RefreshCaptureSyncVisuals()
    if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh(true)
    end
    if Overlord.UI and Overlord.UI.RequestRefresh then
        Overlord.UI:RequestRefresh()
    end
end

-- Recalcule immediatement les statuts local-only available/locked quand la
-- gate de login se ferme. Le throttle normal peut sinon repousser le calcul
-- apres le repaint et laisser toute la carte verrouillee jusqu'au prochain ZS.
-- Ce recalcul ne certifie pas les donnees : les flags bruts de quarantaine
-- restent en place pour les votes, victoires, recompenses et emissions reseau.
function Overlord:RefreshCaptureSyncGameplayAvailability()
    if Overlord.Zones then
        if Overlord.Zones._DoUpdateAvailableZones then
            Overlord.Zones:_DoUpdateAvailableZones(true)
        elseif Overlord.Zones.UpdateAvailableZones then
            Overlord.Zones:UpdateAvailableZones(true)
        end
    end
    self:RefreshCaptureSyncVisuals()
    if self.NotifyDominationOwnersChanged then
        self:NotifyDominationOwnersChanged()
    end
end

function Overlord:ClearLoginUnconfirmedFrontState(frontId)
    local front = frontId and Overlord.Fronts and Overlord.Fronts:GetFront(frontId)
    if not front or not front.zones then return false end
    local changed = false
    for _, zone in ipairs(front.zones) do
        if zone and zone._loginSyncUnconfirmed then
            zone._loginSyncUnconfirmed = nil
            changed = true
        end
    end
    return changed
end

function Overlord:IsLoginZoneStateUnconfirmed(zone)
    -- Quarantaine transitoire uniquement. IsCaptureSyncPending la supprime au
    -- plus tard a l'expiration de la gate, apres avoir remis updatedAt a 0 :
    -- un disque stale reste donc rattrapable sans bloquer carte/domination a vie.
    return zone and zone._loginSyncUnconfirmed == true
end

-- Predicate strictement visuel pendant la fenetre bornee. Au plus tard apres
-- 45 s, IsCaptureSyncPending materialise l'expiration et retire aussi le flag
-- brut : le dernier etat persiste redevient alors territorial comme en 9.3.1.
function Overlord:IsLoginZoneDisplayPending(zone)
    if not zone or not zone._loginSyncUnconfirmed then return false end
    local remote = zone._remoteCaptureLease
    -- Un bail ZS deja valide reste un overlay ephemere : montrer son orange ne
    -- certifie pas le socle disque, qui conserve le flag brut ci-dessus.
    if zone.status == "in_progress" and remote and not zone.holdAuthorityLocal
        and remote.directValidated == true then
        return false
    end
    local now = GetTime()
    return (captureSyncGate.active and captureSyncGate.reason == "login"
            and now < (captureSyncGate.expiresAt or 0))
        or now < (captureSyncGate.settleUntil or 0)
end

-- La quarantaine brute protege l'autorite reseau pendant la gate/settle. Le
-- meme timeout borne son effet sur le gameplay et sur l'etat territorial :
-- CanStartLocalCapture materialise l'expiration avant toute prise de point.
function Overlord:IsLoginZoneGameplayBlocked(zone)
    if not zone or not zone._loginSyncUnconfirmed then return false end
    local now = GetTime()
    if captureSyncGate.active and now < (captureSyncGate.expiresAt or 0) then
        return true
    end
    return now < (captureSyncGate.settleUntil or 0)
end

function Overlord:RequireCaptureSync(reason, timeoutSeconds)
    local now = GetTime()
    local wasActive = captureSyncGate.active
    captureSyncGate.active = true
    captureSyncGate.reason = reason or "sync"
    captureSyncGate.expiresAt = now + (timeoutSeconds or CAPTURE_SYNC_GATE_TIMEOUT)
    local scheduledExpiresAt = captureSyncGate.expiresAt
    captureSyncGate.settleUntil = 0
    captureSyncGate.remoteAdoptResetUntil = 0
    -- Si la fenetre est seulement prolongee, garder le fait qu'on a deja prevenu
    -- le joueur pour ne pas repeter la meme ligne dans le chat.
    if not wasActive then
        captureSyncGate.notified = false
        captureSyncGate.notifiedZoneId = nil
        captureSyncGate.receivedDuringGate = false
        captureSyncGate.gkReceivedDuringGate = false
    end
    -- Le ticker principal dort hors front. Sans ce one-shot, le predicat visuel
    -- expirait bien mais une carte deja ouverte ne recevait jamais le repaint.
    -- L'egalite d'expiration annule silencieusement les anciennes generations.
    if C_Timer and C_Timer.After then
        C_Timer.After(math.max(0.1, scheduledExpiresAt - now + 0.05), function()
            if not captureSyncGate.active
                or captureSyncGate.expiresAt ~= scheduledExpiresAt then return end
            if Overlord.IsCaptureSyncPending then
                Overlord:IsCaptureSyncPending()
            end
        end)
    end
end

function Overlord:MarkCaptureSyncReceived(snapshotComplete, confirmedFrontId)
    captureSyncGate.receivedDuringGate = true
    if not captureSyncGate.active then return end
    -- Un seul ZS (ex. Thelsamar in_progress) ne suffit pas : attendre un snapshot ZA
    -- avant d'ouvrir la gate, sinon la carte disque stale peut etre imposee au reseau.
    if not snapshotComplete then return end
    local now = GetTime()
    local wasLoginGate = captureSyncGate.reason == "login"
    captureSyncGate.active = false
    captureSyncGate.reason = nil
    captureSyncGate.expiresAt = 0
    -- Courte stabilisation : le paquet qui debloque la sync ne doit pas
    -- aussi rendre ce client autorite locale avec un timer distant avance.
    captureSyncGate.settleUntil = now + CAPTURE_SYNC_SETTLE_SECONDS
    captureSyncGate.remoteAdoptResetUntil = now + CAPTURE_SYNC_REMOTE_ADOPT_RESET_SECONDS
    captureSyncGate.notifiedZoneId = nil
    if wasLoginGate then
        C_Timer.After(CAPTURE_SYNC_SETTLE_SECONDS + 0.5, function()
            local changed = false
            if confirmedFrontId and Overlord.ClearLoginUnconfirmedFrontState then
                changed = Overlord:ClearLoginUnconfirmedFrontState(confirmedFrontId)
            elseif Overlord.ClearLoginUnconfirmedZoneState then
                changed = Overlord:ClearLoginUnconfirmedZoneState()
            end
            if Overlord.RefreshCaptureSyncGameplayAvailability then
                Overlord:RefreshCaptureSyncGameplayAvailability()
            elseif changed and Overlord.RefreshCaptureSyncVisuals then
                Overlord:RefreshCaptureSyncVisuals()
            end
        end)
    end
    if Overlord.Sync and Overlord.Sync.FlushPendingGuildKeepCriticalBroadcasts then
        Overlord.Sync:FlushPendingGuildKeepCriticalBroadcasts()
    end
    if Overlord.Sync and Overlord.Sync.FlushPendingOutpostRestoreBroadcasts then
        Overlord.Sync:FlushPendingOutpostRestoreBroadcasts()
    end
end

-- True si la carte du front actif vient du disque (updatedAt=0) sans confirmation reseau.
function Overlord:LocalFrontAwaitingNetworkSnapshot()
    if not self.ZoneDatabase then return false end
    local captured, awaiting = 0, 0
    for _, z in ipairs(self.ZoneDatabase) do
        if z.owner and z.status == "captured" then
            captured = captured + 1
            if (z.updatedAt or 0) <= 0 then
                awaiting = awaiting + 1
            end
        end
    end
    return captured > 0 and awaiting == captured
end

-- True si aucune zone du front actif n'a de snapshot sync recent (install, pool, session stale).
function Overlord:ZonesNeedLoginSyncNotice()
    if not self.ZoneDatabase then return true end
    for _, zone in ipairs(self.ZoneDatabase) do
        if zone.status ~= "in_progress" and (zone.updatedAt or 0) > 0 then
            return false
        end
    end
    return true
end

function Overlord:IsCaptureSyncPending()
    local now = GetTime()
    if not captureSyncGate.active then
        return now < (captureSyncGate.settleUntil or 0)
    end
    if now >= (captureSyncGate.expiresAt or 0) then
        -- Filet solo : debloquer apres timeout ; sans snapshot ZA utile, neutraliser updatedAt
        -- pour ne pas imposer un etat SV obsolete en capteur autoritaire.
        local needsCatchup = not captureSyncGate.receivedDuringGate
            or (self.LocalFrontAwaitingNetworkSnapshot and self:LocalFrontAwaitingNetworkSnapshot())
        -- Login : un LK/ZS partiel ne suffit pas ; forcer updatedAt=0 pour que le prochain ZA
        -- corrige Grangeneuve et les autres zones (sinon blocage localTs jusqu'au prochain C live).
        if captureSyncGate.reason == "login" then
            needsCatchup = true
        end
        local wasLoginGate = captureSyncGate.reason == "login"
        local wasInstanceGate = captureSyncGate.reason == "instance"
        if needsCatchup then
            ZeroActiveFrontZonesForSyncCatchup()
        end
        -- GK/GC ont leur propre catchup ; ne pas rendre stale un fortin deja confirme.
        if not captureSyncGate.gkReceivedDuringGate then
            ZeroGuildKeepsForSyncCatchup()
        end
        captureSyncGate.active = false
        captureSyncGate.reason = nil
        captureSyncGate.expiresAt = 0
        captureSyncGate.settleUntil = 0
        captureSyncGate.remoteAdoptResetUntil = 0
        captureSyncGate.notified = false
        captureSyncGate.notifiedZoneId = nil
        captureSyncGate.gkReceivedDuringGate = false
        -- La quarantaine de login est bornee comme en 9.3.1. updatedAt a deja
        -- ete neutralise pour le rattrapage : retirer maintenant les flags rend
        -- a nouveau carte, domination et capture locale canoniques, sans donner
        -- a l'ancien etat disque un avantage de fraicheur sur un futur ZA/ZS.
        self:ClearLoginUnconfirmedZoneState()
        if self.RefreshCaptureSyncGameplayAvailability then
            self:RefreshCaptureSyncGameplayAvailability()
        elseif self.RefreshCaptureSyncVisuals then
            self:RefreshCaptureSyncVisuals()
        end
        if Overlord.Sync and Overlord.Sync.FlushPendingGuildKeepCriticalBroadcasts then
            Overlord.Sync:FlushPendingGuildKeepCriticalBroadcasts()
        end
        if Overlord.Sync and Overlord.Sync.FlushPendingOutpostRestoreBroadcasts then
            Overlord.Sync:FlushPendingOutpostRestoreBroadcasts()
        end
        if not self.InstanceSuspended and Overlord.Sync and Overlord.Sync.SendSyncRequest then
            C_Timer.After(0.5, function()
                if Overlord.InstanceSuspended or not Overlord.Sync then return end
                Overlord.Sync:SendSyncRequest({
                    includeCommunity = wasLoginGate or wasInstanceGate,
                    allowCommunityInLargeEvent = wasLoginGate or wasInstanceGate,
                    criticalChannel = wasLoginGate or wasInstanceGate,
                    territorialOnly = wasInstanceGate,
                    targetedCommunityOnly = wasInstanceGate,
                    communityMax = wasInstanceGate and 2 or nil,
                    communityRosterMinTtl = wasInstanceGate and 18 or nil,
                })
                if wasLoginGate
                    and Overlord.Sync.SendLoginCatchupSyncToCommunity then
                    Overlord.Sync:SendLoginCatchupSyncToCommunity()
                end
            end)
        end
        return false
    end
    return true
end

-- Gate login active (hors settle post-ZA) : pour différer GC restore sans bloquer le flush après ZA.
function Overlord:IsCaptureSyncGateActive()
    if not captureSyncGate.active then return false end
    return GetTime() < (captureSyncGate.expiresAt or 0)
end

function Overlord:IsCaptureSyncGateReasonActive(reason)
    if not captureSyncGate.active or captureSyncGate.reason ~= reason then return false end
    return GetTime() < (captureSyncGate.expiresAt or 0)
end

-- Les preuves ponctuelles C/ZS restent utiles pendant le login, mais elles ne
-- doivent pas certifier visuellement une carte zone par zone. Seul un snapshot
-- global atomique ferme cette quarantaine ; apres timeout, les corrections
-- ponctuelles peuvent de nouveau confirmer individuellement les zones.
function Overlord:IsLoginCaptureSyncGateActive()
    return self:IsCaptureSyncGateReasonActive("login")
end

function Overlord:IsInstanceCaptureSyncGateActive()
    return self:IsCaptureSyncGateReasonActive("instance")
end

function Overlord:MarkGuildKeepSyncReceived()
    captureSyncGate.gkReceivedDuringGate = true
end

function Overlord:NotifyCaptureSyncPending(zone)
    if not self:IsCaptureSyncPending() then return end
    if not zone or not zone.id then return end
    if captureSyncGate.notified then return end
    captureSyncGate.notified = true
    captureSyncGate.notifiedZoneId = zone.id
    local msg = (L and L.CAPTURE_SYNC_WAITING) or "Initial sync pending: capture of %s is temporarily blocked."
    self:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. msg, zone.name or zone.id))
end

function Overlord:CanStartLocalCapture(zone, notify)
    if self:IsCaptureSyncPending() then
        if notify then self:NotifyCaptureSyncPending(zone) end
        return false
    end
    return true
end

-- Messages joueur hors debug : passe par cette fonction pour respecter
-- OverlordDB.config.notificationChatFrame (voir infobulle Options).
-- Pratique habituelle WoW pour un addon sans canal dédié : ChatFrame:AddMessage(...)
-- avec texte formaté ; print() équivalent utilise la fenêtre générale mais ne choisit pas l’onglet.
-- numéro d’ONGLET (ChatFrameN), pas un canal /join ni une ligne dans Config. > Canaux.
-- Valeur 0 ou cadre inexistant : fallback vers print().
function Overlord:PrintNotification(text)
    if not text or text == "" then return end
    local cfg = OverlordDB and OverlordDB.config
    local idx = cfg and tonumber(cfg.notificationChatFrame) or 0
    local maxWin = (type(NUM_CHAT_WINDOWS) == "number" and NUM_CHAT_WINDOWS) or 10
    if idx < 1 or idx > maxWin then
        print(text)
        return
    end
    local cf = _G["ChatFrame" .. idx]
    if cf and type(cf.AddMessage) == "function" then
        cf:AddMessage(text)
    else
        print(text)
    end
end

-- Alerte rouge milieu d'ecran (RaidNotice), comme les avertissements de raid Blizzard.
function Overlord:PrintRaidWarning(text)
    if not text or text == "" then return end
    -- Codes couleur WoW : |c + 8 hex (AARRGGBB). 7 hex laissait un « 0 » parasite (ex. |cFFFFD100).
    local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local shown = false
    if RaidNotice_AddMessage then
        local info = ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]
        local noticeFrame = RaidWarningFrame or RaidBossEmoteFrame
        if noticeFrame and info then
            local ok = pcall(RaidNotice_AddMessage, noticeFrame, plain, info)
            shown = ok and true or false
        end
    end
    if not shown and UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(plain, 1.0, 0.1, 0.1, 1.0, 5.0)
        shown = true
    end
    if not shown then
        self:PrintNotification("|cFFFF4444[Overlord]|r " .. plain)
    end
    local cfg = OverlordDB and OverlordDB.config
    if cfg == nil or cfg.soundEnabled ~= false then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
    end
end

function Overlord:ShouldResetSyncedLocalCaptureProgress()
    return GetTime() < (captureSyncGate.remoteAdoptResetUntil or 0)
end

-- ============================================================
-- WoW 12.0.5 : Wrappers simples pour les APIs sensibles
-- En instance, on retourne nil pour eviter toute propagation de taint.
-- Hors instance, on utilise les APIs normalement (pas de issecretvalue/canaccessvalue
-- qui propagent eux-memes du taint).
-- ============================================================

-- Wrapper pour UnitName - retourne name, realm
function Overlord:SafeUnitName(unit)
    if Overlord.InstanceSuspended then return nil, nil end
    if not unit then return nil, nil end
    local ok, name, realm = pcall(UnitName, unit)
    if not ok then return nil, nil end
    return name, realm
end

-- Wrapper pour GetUnitName - retourne le nom complet
function Overlord:SafeGetUnitName(unit, includeServerName)
    if Overlord.InstanceSuspended then return nil end
    if not unit then return nil end
    local ok, name = pcall(GetUnitName, unit, includeServerName)
    if not ok then return nil end
    return name
end

-- Wrapper pour UnitLevel. La conversion reste dans le pcall afin qu'une valeur
-- protegee/indisponible ne se propage jamais jusqu'aux comparaisons du ladder.
function Overlord:SafeUnitLevel(unit)
    if Overlord.InstanceSuspended or not unit or not UnitLevel then return nil end
    local ok, level = pcall(UnitLevel, unit)
    if not ok then return nil end
    local okNumber, normalized = pcall(tonumber, level)
    if not okNumber or not normalized then return nil end
    local okFloor, floored = pcall(math.floor, normalized)
    if not okFloor then return nil end
    return floored
end

-- Wrapper pour GetNormalizedRealmName / GetRealmName
function Overlord:SafeGetRealmName()
    if Overlord.InstanceSuspended then return nil end
    local ok, realm = pcall(GetNormalizedRealmName)
    if not ok or not realm or realm == "" then
        ok, realm = pcall(GetRealmName)
        if ok and realm then
            realm = realm:gsub("%s", "")
        else
            realm = nil
        end
    end
    return realm
end

-- Wrapper pour GetGuildInfo (WoW 12.x : pcall + pas d'appel en instance suspendue)
function Overlord:SafeGetGuildInfo(unit)
    if Overlord.InstanceSuspended then return nil end
    if not unit or not GetGuildInfo then return nil end
    local ok, guild = pcall(function()
        return select(1, GetGuildInfo(unit))
    end)
    if not ok or not guild or guild == "" then return nil end
    return guild
end

-- nil = metadata pas encore disponible ; "" = absence de guilde confirmee.
-- GetGuildInfo peut etre vide pendant le login alors que IsInGuild reste vrai.
function Overlord:GetLocalGuildIdentity()
    local guild = self:SafeGetGuildInfo("player")
    if guild then return guild end
    if self.InstanceSuspended or type(IsInGuild) ~= "function" then return nil end
    local ok, inGuild = pcall(IsInGuild)
    if ok and (not canaccessvalue or canaccessvalue(inGuild)) and inGuild == false then
        return ""
    end
    return nil
end

-- Comparaison simple - en instance, retourne false
function Overlord:SafeStringEquals(a, b)
    if Overlord.InstanceSuspended then return false end
    if a == nil or b == nil then return a == b end
    return a == b
end

function Overlord:IsShardHelperActive()
    if self.InstanceSuspended then return false end
    if self.InActiveFront then return true end
    if self.Outpost and self.Outpost.IsPlayerOnOutpostMap then
        local onOutpost, site = self.Outpost:IsPlayerOnOutpostMap()
        if onOutpost and site and site.standaloneOpenWorld then return true end
    end
    if self.GuildKeep and self.GuildKeep.IsPlayerOnKeepMap then
        return (select(1, self.GuildKeep:IsPlayerOnKeepMap())) == true
    end
    return false
end

-- Exceptions PvP exterieures sans front Overlord. C_Map.GetBestMapForUnit renvoie
-- la carte la plus profonde ; remonter les parents couvre les micro-cartes ajoutees
-- par Blizzard, notamment l'UiMap 2509 dont le parent API est 2512.
-- Slayer's Rise reutilise aussi son UiMap dans un champ de bataille epique, mais les
-- gardes IsInInstance/GetInstanceInfo ci-dessous refusent toujours cette version.
-- Capitales de faction : classement uniquement, sans activer un front territorial.
local CAPITAL_KILL_SCORING_MAPS = {
    [84] = true,   -- Stormwind
    [85] = true,   -- Orgrimmar
    [87] = true,   -- Ironforge
    [88] = true,   -- Thunder Bluff
    [89] = true,   -- Darnassus
    [90] = true,   -- Undercity
    [103] = true,  -- The Exodar
    [110] = true,  -- Silvermoon (ancienne carte)
    [1161] = true, -- Boralus
    [1165] = true, -- Dazar'alor
    [2393] = true, -- Silvermoon (Midnight)
}

function Overlord:ResolveTemporaryKillScoringMapID(mapID)
    local seen = {}
    while mapID and mapID > 0 and not seen[mapID] do
        if mapID == 2444 or mapID == 2512 then return mapID end
        if CAPITAL_KILL_SCORING_MAPS[mapID] then return mapID end
        seen[mapID] = true
        if not C_Map or not C_Map.GetMapInfo then break end
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if not ok or not info then break end
        mapID = tonumber(info.parentMapID) or 0
    end
    return nil
end

function Overlord:IsTemporaryKillScoringMap(mapID)
    return self:ResolveTemporaryKillScoringMapID(mapID) ~= nil
end

function Overlord:IsInTemporaryKillScoringZone()
    if not C_Map or not C_Map.GetBestMapForUnit then return false end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then return false end
    local rootMapID = self:ResolveTemporaryKillScoringMapID(mapID)
    return rootMapID ~= nil, rootMapID
end

-- Contexte PvP ouvert (pas instance) requis pour compter un kill au classement.
function Overlord:IsKillContextBlocked()
    if self.InstanceSuspended then return true end
    if IsInInstance() then return true end
    local okInst, _, instType = pcall(GetInstanceInfo)
    if okInst and instType and instType ~= "none" and instType ~= "" then return true end
    -- Aucune liste de cartes/continents Retail : les phases et evenements
    -- exterieurs restent eligibles. Les vraies instances sont refusees ci-dessus.
    return false
end

-- Classement kills Forever : tout le monde ouvert, a tous les niveaux.
-- Les primes (bounty) restent sur InActiveFront uniquement.
function Overlord:IsKillScoringActive()
    return not self:IsKillContextBlocked()
end

-- ============================================================
-- Module Shard : detection du shardID via parsing GUID (ZoneUID)
-- Format retail : Type-0-ServerID-InstanceID-ZoneUID-NpcID-SpawnUID
-- Le ZoneUID (5e segment apres le 0) identifie la couche / le shard client.
-- Sources : vignettes monde, cible, souris, nameplates.
-- ============================================================
Overlord.Shard = {
    currentShardID = nil,        -- shardID local detecte (0 = couche par defaut valide)
    knownShards = {},            -- [playerName] = shardID (autres joueurs via sync)
    knownShardUpdatedAt = {},    -- [playerName] = GetTime() du dernier SH recu
    peerNodes = {},              -- ordre LRU/TTL, entretien O(1)
    peerHead = nil,
    peerTail = nil,
    peerCount = 0,
    peerMax = 512,
    peerGroupedReserve = 64,
    shardReferencePlayers = {},  -- [shardID] = joueur referent actif, elu deterministement
    shardReferenceFullNames = {},-- [shardID] = Nom-Royaume canonique du referent
    shardReferenceRealms = {},   -- [shardID] = royaume affiche pour le referent
    shardReferenceCheckedAt = {},-- [shardID] = dernier recalcul du referent
    lastUpdateAt = 0,            -- GetTime() de la derniere detection
    lastScanAttemptAt = 0,       -- GetTime() du dernier scan, y compris resultat inconnu
    nextMaintenanceScanAt = 0,   -- prochain essai adaptatif (backoff si shard inconnue)
    lastBroadcastAt = 0,         -- GetTime() du dernier SH envoye
    localContextKey = "",       -- front/fortin pour lequel currentShardID a ete mesure
    localContextStartedAt = 0,   -- interdit de reutiliser le shard de la carte precedente
}

local SHARD_BROADCAST_INTERVAL = 60
local SHARD_PEER_TTL = 180
local SHARD_LAYER_ID_MAX = 100000000
local ScheduleNextShardScan
local StopShardScanMaintenance

local function CoerceShardId(value)
    if value == nil then return nil end
    return tonumber(value)
end

local function ShardIdIsKnown(value)
    return CoerceShardId(value) ~= nil
end

-- Parse le layer ID depuis un GUID unit/vignette (pcall : valeurs secret 12.0.5).
local function ParseLayerIdFromGuidString(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    local guidType, zero, _, instanceId, zoneUid = strsplit("-", guid)
    if guidType ~= "Creature" and guidType ~= "Vehicle" and guidType ~= "GameObject" and guidType ~= "Vignette" then
        return nil
    end
    -- Format moderne : Type-0-server-instance-zoneUID-npc-spawn
    if zero == "0" and zoneUid and zoneUid ~= "" then
        local zoneLayer = tonumber(zoneUid)
        if zoneLayer and zoneLayer >= 0 and zoneLayer < SHARD_LAYER_ID_MAX then
            if zoneLayer > 0 then return zoneLayer end
            local instLayer = tonumber(instanceId)
            if instLayer and instLayer > 0 and instLayer < SHARD_LAYER_ID_MAX then
                return instLayer
            end
            return 0
        end
    end
    -- Ancien format sans le 0 central (legacy).
    local legacy = tonumber(zoneUid)
    if legacy and legacy >= 0 and legacy < SHARD_LAYER_ID_MAX then
        return legacy
    end
    return nil
end

local function ExtractShardIDFromGUID(guid)
    local ok, layerId = pcall(ParseLayerIdFromGuidString, guid)
    if ok then return layerId end
    return nil
end

local function SafeUnitGUID(unit)
    if not UnitGUID then return nil end
    -- Ne pas inspecter `unit` avant le pcall : PARTY_KILL peut fournir une valeur
    -- secrete 12.x a la place d'un ancien unit token.
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or type(guid) ~= "string" then return nil end
    return guid
end

local function ReadShardIDFromUnit(unit)
    if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
    if UnitIsVisible and not UnitIsVisible(unit) then return nil end
    local guid = SafeUnitGUID(unit)
    return ExtractShardIDFromGUID(guid), guid
end

local function ExtractShardIDFromUnit(unit)
    -- Les tests UnitExists/UnitIsPlayer et le GUID peuvent tous etre secrets en 12.x.
    local ok, shardID, guid = pcall(ReadShardIDFromUnit, unit)
    return ok and shardID or nil, ok and guid or nil
end

-- Certaines vignettes retail utilisent un GUID d'enveloppe qui ne transporte pas un
-- ZoneUID exploitable. Leur objectGUID pointe en revanche vers la creature / l'objet
-- effectivement present sur notre couche. L'acces reste protege car ces valeurs peuvent
-- etre secretes dans certains contextes 12.x.
local function GetVignetteObjectGUID(vignetteGUID)
    if not C_VignetteInfo or not C_VignetteInfo.GetVignetteInfo then return nil end
    local ok, objectGUID = pcall(function()
        local info = C_VignetteInfo.GetVignetteInfo(vignetteGUID)
        local guid = info and info.objectGUID
        if type(guid) ~= "string" or guid == "" then return nil end
        return guid
    end)
    if not ok then return nil end
    return objectGUID
end

-- GUID de vignette : meme parseur ; repli sur le dernier entier si structure atypique.
local function ExtractShardIDFromVignetteGUID(guid)
    local id = ExtractShardIDFromGUID(guid)
    if id ~= nil then return id end
    if type(guid) ~= "string" or guid == "" then return nil end
    local lastNum
    for n in guid:gmatch("(%d+)") do
        lastNum = n
    end
    if lastNum then
        local v = tonumber(lastNum)
        if v and v >= 0 and v < SHARD_LAYER_ID_MAX then return v end
    end
    return nil
end

-- Parcourt les vignettes actives (objectifs, caisses, elites, etc.) - se met a jour souvent sans PNJ a portee
local function ScanVignettesForShardID(strictZoneUid)
    if not C_VignetteInfo or not C_VignetteInfo.GetVignettes then return nil end
    local ok, vignettes = pcall(C_VignetteInfo.GetVignettes)
    if not ok or type(vignettes) ~= "table" then return nil end
    for _, vignetteGUID in ipairs(vignettes) do
        -- Une Anchor GK immuable ne doit jamais utiliser le dernier nombre arbitraire
        -- d'un GUID atypique (souvent NPC/spawn ID). Le GUID objet est une preuve stricte
        -- equivalente a une cible/nameplate ; seul le vieux repli numerique reste interdit.
        local sid = ExtractShardIDFromGUID(vignetteGUID)
        if sid == nil then
            sid = ExtractShardIDFromGUID(GetVignetteObjectGUID(vignetteGUID))
        end
        if sid == nil and not strictZoneUid then
            sid = ExtractShardIDFromVignetteGUID(vignetteGUID)
        end
        if sid ~= nil then return sid end
    end
    return nil
end

-- Scanne les unites proches pour trouver un shardID
local SHARD_SCAN_UNITS = { "target", "mouseover", "focus", "softenemy", "softfriend", "softinteract" }
local SHARD_NAMEPLATE_UNITS = {}
for i = 1, 40 do SHARD_NAMEPLATE_UNITS[i] = "nameplate" .. i end

function Overlord.Shard:ScanForShardID()
    local strictZoneUid = type(self.localContextKey) == "string"
        and self.localContextKey:find("^keep:") ~= nil
    local shardID
    for i = 1, #SHARD_SCAN_UNITS do
        shardID = ExtractShardIDFromUnit(SHARD_SCAN_UNITS[i])
        if shardID ~= nil then return shardID end
    end
    -- Les tokens sont attribues par WoW et ne sont pas limites a nameplate1..40.
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for _, plate in ipairs(plates) do
                local readable, unit = pcall(function() return plate.namePlateUnitToken end)
                if readable and unit then
                    shardID = ExtractShardIDFromUnit(unit)
                    if shardID ~= nil then return shardID end
                end
            end
        end
    end
    -- Secours pour les clients qui n'exposent pas la liste des frames.
    for i = 1, #SHARD_NAMEPLATE_UNITS do
        shardID = ExtractShardIDFromUnit(SHARD_NAMEPLATE_UNITS[i])
        if shardID ~= nil then return shardID end
    end
    return ScanVignettesForShardID(strictZoneUid)
end

-- Duree pendant laquelle les events bruyants reutilisent une mesure confirmee.
-- La maintenance one-shot et les invalidations monde/phase assurent le filet de fraicheur.
local SHARD_FRESH_SECONDS = 30
local SHARD_NEGATIVE_FRESH_SECONDS = 2
local SHARD_KNOWN_SCAN_INTERVAL = 30
local SHARD_UNKNOWN_SCAN_MIN = 2
local SHARD_UNKNOWN_SCAN_MAX = 30
local SHARD_ON_DEMAND_RESCAN_GAP = 8

-- Met a jour le shardID courant. skipIfFresh=true (evenements haute frequence) : ne rescanne pas
-- (GetVignettes + jusqu'a 40 nameplates) si un shardID a deja ete confirme il y a moins de
-- SHARD_FRESH_SECONDS -- les changements monde/phase invalident le contexte immediatement.
function Overlord.Shard:Update(skipIfFresh)
    if not self:SyncLocalContext() then return false end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then
        self.currentShardID = nil
        self.lastUpdateAt = 0
        if StopShardScanMaintenance then StopShardScanMaintenance() end
        return false
    end
    local now = GetTime()
    local freshFor = self.currentShardID ~= nil
        and SHARD_FRESH_SECONDS or SHARD_NEGATIVE_FRESH_SECONDS
    if skipIfFresh and self.currentShardID == nil
        and now < (tonumber(self.nextMaintenanceScanAt) or 0) then
        return false
    end
    if skipIfFresh and (tonumber(self.lastScanAttemptAt) or 0) > 0
        and (now - self.lastScanAttemptAt) < freshFor then
        return false
    end
    self.lastScanAttemptAt = now
    local newShard = self:ScanForShardID()
    if newShard ~= nil then
        local changed = (newShard ~= self.currentShardID)
        self.currentShardID = newShard
        self.lastUpdateAt = now
        self.localShardSource = "guid"
        -- Heartbeat leger : garde les infos de shard vivantes entre raids / communaute.
        if Overlord.Sync and Overlord.Sync.BroadcastShard
            and (changed or (self.lastBroadcastAt + SHARD_BROADCAST_INTERVAL <= self.lastUpdateAt)) then
            self.lastBroadcastAt = self.lastUpdateAt
            Overlord.Sync:BroadcastShard(newShard)
        end
    end
    if self.currentShardID == nil then self:RequestKeepShardWitness() end
    if ScheduleNextShardScan then
        ScheduleNextShardScan(self.currentShardID ~= nil)
    end
    return true, newShard
end

-- Retourne le shardID courant (ou nil si inconnu)
function Overlord.Shard:GetCurrentShardID()
    return self.currentShardID
end

-- Un rapporteur distant n'est exploitable que si WoW fournit un Prenom Nom Forever.
local function BuildShardReferenceCandidate(playerName)
    if type(playerName) ~= "string" or playerName == "" then return nil, nil end
    local canon = Overlord.Sync and Overlord.Sync.CanonicalForeverName
        and Overlord.Sync:CanonicalForeverName(playerName) or nil
    if not canon then return nil, nil end
    return canon, nil
end

local localShardReferenceFullName
local localShardReferenceRealm
local function GetLocalShardReferenceCandidate()
    if localShardReferenceFullName then
        return localShardReferenceFullName, localShardReferenceRealm
    end
    local fullName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
        and Overlord.Sync:GetPlayerFullName()
    if not fullName or fullName == "" then return nil, nil end
    localShardReferenceFullName, localShardReferenceRealm =
        BuildShardReferenceCandidate(fullName)
    return localShardReferenceFullName, localShardReferenceRealm
end

local function ClearShardReferenceForPlayer(self, player, shardId)
    local sid = CoerceShardId(shardId)
    if sid == nil or self.shardReferencePlayers[sid] ~= player then return end
    self.shardReferencePlayers[sid] = nil
    self.shardReferenceFullNames[sid] = nil
    self.shardReferenceRealms[sid] = nil
    self.shardReferenceCheckedAt[sid] = nil
end

local function RebuildKnownShardReference(self, shardID, now)
    local bestPlayer
    local bestFullName
    local bestRealm
    local bestSortKey
    for player, knownShard in pairs(self.knownShards) do
        local seenAt = self.knownShardUpdatedAt[player] or 0
        if now - seenAt > SHARD_PEER_TTL then
            self:RemoveKnownShardPeer(player)
        elseif CoerceShardId(knownShard) == shardID and self:PartyInviteTargetIsUsable(player) then
            local fullName, realm = BuildShardReferenceCandidate(player)
            local sortKey = fullName and fullName:lower()
            if sortKey and (not bestSortKey or sortKey < bestSortKey) then
                bestPlayer = player
                bestFullName = fullName
                bestRealm = realm
                bestSortKey = sortKey
            end
        end
    end
    self.shardReferencePlayers[shardID] = bestPlayer
    self.shardReferenceFullNames[shardID] = bestFullName
    self.shardReferenceRealms[shardID] = bestRealm
    self.shardReferenceCheckedAt[shardID] = now
    return bestPlayer, bestFullName, bestRealm
end

local function GetKnownShardReference(self, shardID)
    local now = GetTime()
    local player = self.shardReferencePlayers[shardID]
    if player then
        local seenAt = self.knownShardUpdatedAt[player] or 0
        if now - seenAt <= SHARD_PEER_TTL
            and CoerceShardId(self.knownShards[player]) == shardID
            and self:PartyInviteTargetIsUsable(player) then
            return player, self.shardReferenceFullNames[shardID], self.shardReferenceRealms[shardID]
        end
        self.shardReferencePlayers[shardID] = nil
        self.shardReferenceFullNames[shardID] = nil
        self.shardReferenceRealms[shardID] = nil
        self.shardReferenceCheckedAt[shardID] = nil
    end
    if self.shardReferenceCheckedAt[shardID] then return nil end
    return RebuildKnownShardReference(self, shardID, now)
end

-- Elit le meme rapporteur chez les clients qui connaissent le meme ensemble de joueurs.
function Overlord.Shard:GetShardReference(shardId)
    local shardID = CoerceShardId(shardId)
    if shardID == nil then return nil, nil end

    local _, peerFullName, peerRealm = GetKnownShardReference(self, shardID)
    local selfFullName, selfRealm
    if CoerceShardId(self.currentShardID) == shardID then
        selfFullName, selfRealm = GetLocalShardReferenceCandidate()
    end

    if peerFullName and (not selfFullName or peerFullName < selfFullName) then
        return peerFullName, peerRealm
    end
    return selfFullName, selfRealm
end

function Overlord.Shard:GetCurrentShardReference()
    return self:GetShardReference(self.currentShardID)
end

function Overlord.Shard:UnlinkPeerNode(node)
    if not node then return end
    if node.prev then node.prev.next = node.next else self.peerHead = node.next end
    if node.next then node.next.prev = node.prev else self.peerTail = node.prev end
    node.prev, node.next = nil, nil
end

function Overlord.Shard:TouchPeerNode(playerName, now)
    local node = self.peerNodes[playerName]
    if node then
        self:UnlinkPeerNode(node)
    else
        node = { key = playerName }
        self.peerNodes[playerName] = node
        self.peerCount = (tonumber(self.peerCount) or 0) + 1
    end
    node.expiresAt = now + SHARD_PEER_TTL
    node.prev = self.peerTail
    if self.peerTail then self.peerTail.next = node else self.peerHead = node end
    self.peerTail = node
end

function Overlord.Shard:RemoveKnownShardPeer(playerName)
    local shard = self.knownShards[playerName]
    self.knownShards[playerName] = nil
    self.knownShardUpdatedAt[playerName] = nil
    local node = self.peerNodes[playerName]
    if node then
        self:UnlinkPeerNode(node)
        self.peerNodes[playerName] = nil
        self.peerCount = math.max(0, (tonumber(self.peerCount) or 1) - 1)
    end
    ClearShardReferenceForPlayer(self, playerName, shard)
end

function Overlord.Shard:EnsurePeerCapacity(playerName, now)
    if self.knownShards[playerName] ~= nil then return true end
    local maxPeers = tonumber(self.peerMax) or 512
    local head = self.peerHead
    if (tonumber(self.peerCount) or 0) >= maxPeers and head
        and (tonumber(head.expiresAt) or 0) <= now then
        self:RemoveKnownShardPeer(head.key)
    end
    if (tonumber(self.peerCount) or 0) < maxPeers then return true end
    -- Les rapports SH viennent de vrais senders Blizzard, pas d'une identite
    -- choisie dans le payload. Une reserve garantit qu'une communaute pleine
    -- ne masque pas un membre du groupe arrive plus tard.
    if self:IsPlayerAlreadyGrouped(playerName)
        and (tonumber(self.peerCount) or 0)
            < maxPeers + (tonumber(self.peerGroupedReserve) or 64) then
        return true
    end
    return false
end

-- Enregistre le shardID d'un autre joueur (recu via sync)
function Overlord.Shard:SetPlayerShard(playerName, shardID)
    if not playerName or shardID == nil then return end
    local sid = CoerceShardId(shardID)
    if sid == nil or sid ~= sid or sid < 0 or sid >= SHARD_LAYER_ID_MAX then return false end
    local previousShard = CoerceShardId(self.knownShards[playerName])
    local now = GetTime()
    if previousShard == nil and not self:EnsurePeerCapacity(playerName, now) then return false end
    self.knownShards[playerName] = sid
    self.knownShardUpdatedAt[playerName] = now
    self:TouchPeerNode(playerName, now)
    if previousShard ~= sid then
        self._gkPromptPeerRevision = (tonumber(self._gkPromptPeerRevision) or 0) + 1
    end

    if previousShard ~= nil and previousShard ~= sid
        and self.shardReferencePlayers[previousShard] == playerName then
        self.shardReferencePlayers[previousShard] = nil
        self.shardReferenceFullNames[previousShard] = nil
        self.shardReferenceRealms[previousShard] = nil
        self.shardReferenceCheckedAt[previousShard] = nil
    end

    if self:PartyInviteTargetIsUsable(playerName) then
        local candidate, candidateRealm = BuildShardReferenceCandidate(playerName)
        local current = self.shardReferencePlayers[sid]
        local currentCandidate = current and self.shardReferenceFullNames[sid]
        if candidate and (not currentCandidate or candidate:lower() < currentCandidate:lower()) then
            self.shardReferencePlayers[sid] = playerName
            self.shardReferenceFullNames[sid] = candidate
            self.shardReferenceRealms[sid] = candidateRealm
        end
        if candidate then
            self.shardReferenceCheckedAt[sid] = now
        end
    end
    return true
end

-- Prefix lien addon invite shard (handler SetItemRef dans UI.lua).
Overlord.Shard.INVITE_LINK_PREFIX = "addon:Overlord:invite:"
Overlord.Shard.KEEP_INVITE_REQUEST_LINK_PREFIX = "addon:Overlord:requestkeep:"

-- Hyperlien cliquable invite shard (chat, tooltip).
function Overlord.Shard:BuildInviteHyperlink(playerName, colorEsc, displayText)
    if not playerName or playerName == "" then return "" end
    playerName = tostring(playerName)
    if playerName:find("[%c:|]") then return "" end
    colorEsc = colorEsc or "|cffffffff"
    displayText = displayText or playerName
    return string.format(
        "%s|H%s%s|h[%s]|h|r",
        colorEsc,
        self.INVITE_LINK_PREFIX,
        playerName,
        displayText
    )
end

-- Un ZoneUID n'est valable que dans le contexte (front ou fortin) ou il a ete lu.
-- Le ticker gameplay appelle ceci avant toute tentative de tag : un passage Redridge ->
-- Wetlands ne peut donc jamais reutiliser l'identifiant de la carte precedente.
function Overlord.Shard:RefreshLocalContext(contextKey, skipScan)
    contextKey = tostring(contextKey or "")
    if self.localContextKey == contextKey then return false end
    self.localContextKey = contextKey
    self.localContextStartedAt = GetTime()
    self.currentShardID = nil
    self.lastUpdateAt = 0
    self.lastScanAttemptAt = 0
    self.localShardSource = nil
    self.keepShardRequest = nil
    if StopShardScanMaintenance then StopShardScanMaintenance() end
    if not skipScan and contextKey ~= "" and Overlord.IsShardHelperActive
        and Overlord:IsShardHelperActive() then
        self:Update()
    end
    return true
end

-- Les preuves arrivent aussi entre deux ticks. Resoudre leur contexte AVANT de les
-- enregistrer evite que le tick suivant efface le seul GUID vu a l'entree du fortin.
-- Une carte indisponible n'est pas une sortie : le gameplay attend un vrai echantillon.
function Overlord.Shard:SyncLocalContext()
    if Overlord.InstanceSuspended then
        self:RefreshLocalContext("", true)
        return false
    end
    if Overlord.GuildKeep and Overlord.GuildKeep.IsPlayerOnKeepMap then
        local onKeep, site, known = Overlord.GuildKeep:IsPlayerOnKeepMap()
        if onKeep and site then
            self:RefreshLocalContext("keep:" .. tostring(site.siteKey or site.id), true)
            return true
        end
        if known == false then return false end
    end
    if Overlord.Outpost and Overlord.Outpost.IsPlayerOnOutpostMap then
        local onOutpost, site = Overlord.Outpost:IsPlayerOnOutpostMap()
        if onOutpost and site then
            self:RefreshLocalContext("outpost:" .. tostring(site.siteKey or site.id), true)
            return true
        end
    end
    local front = Overlord.InActiveFront and Overlord.Fronts
        and Overlord.Fronts:GetCurrentFront()
    self:RefreshLocalContext(front and ("front:" .. tostring(front.id)) or "", true)
    return true
end

function Overlord.Shard:InvalidateLocalContext()
    self.localContextKey = ""
    self.localContextStartedAt = GetTime()
    self.currentShardID = nil
    self.lastUpdateAt = 0
    self.lastScanAttemptAt = 0
    self.localShardSource = nil
    self.keepShardRequest = nil
    if StopShardScanMaintenance then StopShardScanMaintenance() end
end

function Overlord.Shard:GetFreshLocalShardID(maxAge)
    local shardID = CoerceShardId(self.currentShardID)
    local measuredAt = tonumber(self.lastUpdateAt) or 0
    local contextAt = tonumber(self.localContextStartedAt) or 0
    maxAge = tonumber(maxAge) or 15
    local now = GetTime()
    local stale = shardID == nil or measuredAt <= 0 or measuredAt < contextAt
        or (now - measuredAt) > maxAge
    -- Les consommateurs critiques (debut/reprise d'un assaut) peuvent demander une
    -- preuve fraiche sans imposer un scan de fond toutes les cinq secondes au joueur
    -- immobile. Le garde borne aussi les echecs dans un fortin vide.
    if stale and Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()
        and ((tonumber(self.lastScanAttemptAt) or 0) == 0
            or now - (tonumber(self.lastScanAttemptAt) or 0)
                >= math.max(SHARD_ON_DEMAND_RESCAN_GAP, maxAge)) then
        self:Update()
        shardID = CoerceShardId(self.currentShardID)
        measuredAt = tonumber(self.lastUpdateAt) or 0
        contextAt = tonumber(self.localContextStartedAt) or 0
        now = GetTime()
    end
    if shardID == nil or measuredAt <= 0 or measuredAt < contextAt
        or (now - measuredAt) > maxAge then return nil end
    return shardID
end

-- Pendant un assaut deja ancre, un scan negatif ne signifie pas que le joueur a change
-- de couche : un fortin vide peut simplement ne fournir aucun GUID pendant plusieurs minutes.
-- Le contexte est invalide immediatement aux transitions monde/carte ; tant qu'il est identique,
-- conserver la derniere mesure de CE contexte sans TTL evite de geler le chrono apres 8 secondes.
function Overlord.Shard:GetContextLocalShardID(expectedContextKey)
    local shardID = CoerceShardId(self.currentShardID)
    local measuredAt = tonumber(self.lastUpdateAt) or 0
    local contextAt = tonumber(self.localContextStartedAt) or 0
    local contextKey = tostring(self.localContextKey or "")
    if shardID == nil or measuredAt <= 0 or measuredAt < contextAt
        or contextKey == ""
        or (expectedContextKey ~= nil and contextKey ~= tostring(expectedContextKey)) then return nil end
    return shardID
end

-- Identite de shard utilisable par une action de capture dans un contexte exact.
-- Une preuve de moins de maxAge secondes reste preferee, mais une mesure plus ancienne
-- du MEME contexte reste valide : ZONE_CHANGED_NEW_AREA, PLAYER_ENTERING_WORLD et
-- UNIT_PHASE invalident toutes trois ce contexte avant le prochain tick gameplay.
function Overlord.Shard:GetCaptureLocalShardID(expectedContextKey, maxAge)
    if not self:SyncLocalContext() then return nil end
    expectedContextKey = tostring(expectedContextKey or "")
    if expectedContextKey == "" or tostring(self.localContextKey or "") ~= expectedContextKey then
        return nil
    end
    local shardID = self:GetFreshLocalShardID(maxAge)
    if shardID ~= nil then return shardID end
    if self.currentShardID == nil then self:RequestKeepShardWitness() end
    return self:GetContextLocalShardID(expectedContextKey)
end

-- PLAYER_LOGOUT ne dit pas s'il precede un /reload ou une vraie deconnexion. On garde donc
-- un bail exact tres court, mais il ne sera consomme que si PLAYER_ENTERING_WORLD confirme
-- `isReloadingUi=true`. Un login normal ou UNIT_PHASE ne reutilise jamais cette mesure.
function Overlord.Shard:PersistGuildKeepReloadShardLease()
    if not OverlordDB or not Overlord.GuildKeep then return false end
    local contextKey = tostring(self.localContextKey or "")
    local siteKey = contextKey:match("^keep:([%w_%-]+)$")
    local st = siteKey and Overlord.GuildKeep:GetState(siteKey) or nil
    local shardId = self:GetContextLocalShardID()
    if not st or st.status ~= "in_progress" or not st.holdAuthorityLocal
        or not (st.isHolding or st.isPaused) or shardId == nil
        or not Overlord.GuildKeep:HasAssaultShardAnchor(st)
        or tonumber(Overlord.GuildKeep:GetAssaultShardId(st)) ~= tonumber(shardId) then
        OverlordDB.guildKeepReloadShardLease = nil
        return false
    end
    OverlordDB.guildKeepReloadShardLease = {
        serverTs = (GetServerTime and GetServerTime()) or time(),
        contextKey = contextKey, siteKey = siteKey, shardId = shardId,
        guild = st.assaultShardGuild, faction = st.assaultShardFaction,
        startedAt = st.assaultShardStartedAt, generationAt = st.assaultGenerationAt,
        player = st.assaultShardPlayer, baseGuild = st.assaultBaseGuild,
        baseFaction = st.assaultBaseFaction, baseCapturedAt = st.assaultBaseCapturedAt,
    }
    return true
end

function Overlord.Shard:RestoreGuildKeepReloadShardLease(isReloadingUi)
    local row = OverlordDB and OverlordDB.guildKeepReloadShardLease
    if OverlordDB then OverlordDB.guildKeepReloadShardLease = nil end
    if isReloadingUi ~= true or type(row) ~= "table" or not Overlord.GuildKeep then
        return false
    end
    local now = (GetServerTime and GetServerTime()) or time()
    local savedAt = math.floor(tonumber(row.serverTs) or 0)
    local shardId = CoerceShardId(row.shardId)
    local siteKey = tostring(row.siteKey or "")
    local contextKey = tostring(row.contextKey or "")
    local st = Overlord.GuildKeep:GetState(siteKey)
    if savedAt <= 0 or now < savedAt or now - savedAt > 20 or shardId == nil
        or contextKey ~= "keep:" .. siteKey or not Overlord.GuildKeepSites
        or not Overlord.GuildKeepSites[siteKey] or not st
        or not Overlord.GuildKeep:ActiveAssaultAnchorMatches(
            st, row.guild, row.faction, shardId, row.startedAt, row.generationAt,
            row.player, row.baseGuild, row.baseFaction, row.baseCapturedAt) then return false end
    self.localContextKey = contextKey
    self.localContextStartedAt = GetTime()
    self.currentShardID = shardId
    self.lastUpdateAt = GetTime()
    self.lastScanAttemptAt = GetTime()
    self.localShardSource = "reload"
    if ScheduleNextShardScan then ScheduleNextShardScan(true) end
    return true
end

-- Lien Guild Keep dans le chat : le joueur en retard demande a l'ancre de
-- l'inviter. Il ne doit jamais inviter l'ancre et la tirer sur sa propre shard.
function Overlord.Shard:BuildKeepInviteRequestHyperlink(
    playerName, siteKey, shardId, colorEsc, displayText)
    if not playerName or playerName == "" then return "" end
    playerName = tostring(playerName)
    if playerName:find("[%c:|]") then return "" end
    siteKey = tostring(siteKey or "")
    shardId = tonumber(shardId)
    if not siteKey:match("^[%w_%-]+$") or not Overlord.GuildKeepSites
        or not Overlord.GuildKeepSites[siteKey]
        or not shardId or shardId ~= math.floor(shardId) then return "" end
    colorEsc = colorEsc or "|cffffffff"
    displayText = displayText or playerName
    return string.format(
        "%s|H%s%s:%d:%s|h[%s]|h|r",
        colorEsc,
        self.KEEP_INVITE_REQUEST_LINK_PREFIX,
        siteKey,
        shardId,
        playerName,
        displayText
    )
end

-- Clefs sync non invitables (pas de joueur WoW lisible pour InviteUnit)
function Overlord.Shard:PartyInviteTargetIsUsable(sender)
    if not sender or type(sender) ~= "string" then return false end
    -- BNet : clef fictive dans knownShards pour les broadcasts SendGameData
    if sender:sub(1, 5) == "BNet-" then return false end
    -- Relais R2 bridge : pseudonyme local, pas un nom reel
    if sender:sub(1, 7) == "Bridge-" then return false end
    return true
end

function Overlord.Shard:IsPlayerAlreadyGrouped(playerName)
    if not playerName or playerName == "" or not IsInGroup or not IsInGroup() then return false end
    local sync = Overlord.Sync
    if sync and sync.SenderIsInOurGroup then
        return sync:SenderIsInOurGroup(playerName)
    end
    local targetKey = sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(playerName)
    local targetLower = tostring(playerName):lower()

    local function unitMatches(unit)
        if not UnitExists or not UnitExists(unit) then return false end
        local name = Overlord:SafeUnitName(unit)
        if not name or name == "" then return false end
        local full = sync and sync.CanonicalForeverName and sync:CanonicalForeverName(name) or name
        if full:lower() == targetLower then return true end
        if sync and sync.GetCaptureContributorDedupKey and targetKey then
            local unitKey = sync:GetCaptureContributorDedupKey(full)
            if unitKey and unitKey:lower() == targetKey:lower() then return true end
        end
        return false
    end

    if unitMatches("player") then return true end
    if IsInRaid and IsInRaid() then
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        for i = 1, n do
            if unitMatches("raid" .. i) then return true end
        end
    else
        for i = 1, 4 do
            if unitMatches("party" .. i) then return true end
        end
    end
    return false
end

-- Un SH historique (sans carte) n'est jamais une preuve locale. Un fortin sans PNJ
-- demande une reponse directe, liee a cette entree, a un membre physiquement proche.
local KEEP_SHARD_WITNESS_GAP = 8
local KEEP_SHARD_WITNESS_RANGE_SQ = 100 * 100

function Overlord.Shard:GetNearbyKeepGroupUnit(sender, siteKey)
    local site = Overlord.GuildKeepSites and Overlord.GuildKeepSites[siteKey]
    if not site or not IsInGroup or not IsInGroup()
        or not UnitFullName or not UnitPhaseReason or not UnitDistanceSquared
        or not UnitIsVisible or not C_Map or not C_Map.GetPlayerMapPosition then return nil end
    local ok, unit = pcall(function()
        local sync = Overlord.Sync
        local targetKey = sync and sync.GetCaptureContributorDedupKey
            and sync:GetCaptureContributorDedupKey(sender) or nil
        if not targetKey then return nil end
        local prefix = IsInRaid() and "raid" or "party"
        local count = prefix == "raid" and math.min(GetNumGroupMembers(), 40) or 4
        for i = 1, count do
            local token = prefix .. i
            if UnitExists(token) and not UnitIsUnit(token, "player") then
                local unitName = sync.CanonicalForeverNameFromUnit
                    and sync:CanonicalForeverNameFromUnit(token)
                local unitKey = unitName and sync:GetCaptureContributorDedupKey(unitName) or nil
                if unitKey and unitKey == targetKey then
                    if not UnitIsVisible(token) or UnitPhaseReason(token) ~= nil then return nil end
                    local distance, checked = UnitDistanceSquared(token)
                    if checked ~= true or not distance or distance < 0
                        or distance > KEEP_SHARD_WITNESS_RANGE_SQ then return nil end
                    local pos = C_Map.GetPlayerMapPosition(site.mapID, token)
                    if not pos then return nil end
                    local x, y = pos:GetXY()
                    if not x or not y or (x == 0 and y == 0)
                        or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
                    return token
                end
            end
        end
    end)
    return ok and unit or nil
end

function Overlord.Shard:RequestKeepShardWitness()
    local sync = Overlord.Sync
    local siteKey = tostring(self.localContextKey or ""):match("^keep:([%w_%-]+)$")
    if not siteKey or self.currentShardID ~= nil or not sync or not sync.SendToGroup
        or not IsInGroup or not IsInGroup() then return false end
    local now = GetTime()
    if now < (self.nextKeepShardRequestAt or 0) then return false end
    local site = Overlord.GuildKeepSites and Overlord.GuildKeepSites[siteKey]
    if not site or not Overlord.GuildKeep:IsPlayerInKeepGeometry(site) then return false end
    self.nextKeepShardRequestAt = now + KEEP_SHARD_WITNESS_GAP
    self.keepShardRequestSequence = (self.keepShardRequestSequence or 0) + 1
    local nonce = tostring(GetServerTime()) .. "-" .. tostring(self.keepShardRequestSequence)
    self.keepShardRequest = { siteKey = siteKey, nonce = nonce, sentAt = now,
        contextAt = self.localContextStartedAt }
    -- Les anciennes versions ignorent Q/A (tonumber renvoie nil) et continuent de
    -- recevoir le SH numerique inchange. Aucun changement du protocole d'assaut GK.
    sync:SendToGroup("SH", "Q:" .. siteKey .. ":" .. nonce)
    return true
end

function Overlord.Shard:OnKeepShardWitness(payload, sender, channel)
    if channel ~= "PARTY" and channel ~= "RAID" and channel ~= "WHISPER" then return false end
    if type(payload) ~= "string" or #payload > 120 or type(sender) ~= "string"
        or not self:SyncLocalContext() then return false end
    local kind, siteKey, nonce, shardText = strsplit(":", payload)
    if (kind ~= "Q" and kind ~= "A") or not siteKey or not nonce
        or #nonce > 40 or not nonce:match("^%d+%-%d+$")
        or self.localContextKey ~= "keep:" .. siteKey then return false end
    local now = GetTime()
    local request = self.keepShardRequest
    if kind == "A" and (not request or request.siteKey ~= siteKey or request.nonce ~= nonce
        or request.contextAt ~= self.localContextStartedAt or now < request.sentAt
        or now - request.sentAt > KEEP_SHARD_WITNESS_GAP or self.currentShardID ~= nil) then
        return false
    end
    local unit = self:GetNearbyKeepGroupUnit(sender, siteKey)
    if not unit then return false end
    if kind == "Q" then
        local shardID = self:GetContextLocalShardID("keep:" .. siteKey)
        -- Une reponse apprise d'un pair ne peut pas engendrer une chaine de preuves.
        if shardID == nil or self.localShardSource ~= "guid" then return false end
        self.keepShardReplyAt = self.keepShardReplyAt or {}
        if now < (self.keepShardReplyAt[unit] or 0) then return false end
        self.keepShardReplyAt[unit] = now + KEEP_SHARD_WITNESS_GAP
        if Overlord.Sync and Overlord.Sync.SendWhisper then
            Overlord.Sync:SendWhisper("SH", "A:" .. siteKey .. ":" .. nonce .. ":" .. shardID, sender)
            return true
        end
        return false
    end
    local shardID = tonumber(shardText)
    if not shardID or shardID < 0 or shardID >= SHARD_LAYER_ID_MAX
        or shardID ~= math.floor(shardID) then return false end
    self.currentShardID = shardID
    self.lastUpdateAt = now
    self.lastScanAttemptAt = now
    self.localShardSource = "group"
    self.keepShardRequest = nil
    if ScheduleNextShardScan then ScheduleNextShardScan(true) end
    return true
end

-- Retourne la liste des joueurs sur un shard different du notre
function Overlord.Shard:GetPlayersOnDifferentShard()
    local result = {}
    local myShard = CoerceShardId(self.currentShardID)
    if myShard == nil then return result end
    local now = GetTime()
    for player, shard in pairs(self.knownShards) do
        local seenAt = self.knownShardUpdatedAt[player] or 0
        if now - seenAt > SHARD_PEER_TTL then
            self:RemoveKnownShardPeer(player)
        elseif shard and tonumber(shard) ~= myShard and self:PartyInviteTargetIsUsable(player)
            and not self:IsPlayerAlreadyGrouped(player) then
            result[player] = shard
        end
    end
    return result
end

-- Shard connu pour un joueur sync (nil si expire ou absent).
function Overlord.Shard:GetKnownPlayerShard(playerName)
    if not playerName or playerName == "" then return nil end
    local seenAt = self.knownShardUpdatedAt[playerName] or 0
    if GetTime() - seenAt > SHARD_PEER_TTL then
        self:RemoveKnownShardPeer(playerName)
        return nil
    end
    return self.knownShards[playerName]
end

-- Joueurs connus sur un shard donne. Pour un Guild Keep, ils servent de contacts
-- auxquels le retardataire demande une invitation vers la shard ancree.
function Overlord.Shard:GetPlayersOnShard(shardId, includeGrouped)
    local result = {}
    local sid = CoerceShardId(shardId)
    if sid == nil then return result end
    local myShard = CoerceShardId(self.currentShardID)
    local now = GetTime()
    for player, shard in pairs(self.knownShards) do
        local seenAt = self.knownShardUpdatedAt[player] or 0
        if now - seenAt > SHARD_PEER_TTL then
            self:RemoveKnownShardPeer(player)
        elseif CoerceShardId(shard) == sid and self:PartyInviteTargetIsUsable(player)
            and (includeGrouped or not self:IsPlayerAlreadyGrouped(player)) then
            result[player] = shard
        end
    end
    return result
end

local function NormalizeShardPlayerName(name)
    if type(name) ~= "string" then return "" end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t >= 2 and #t <= 50 then return t end
    return ""
end

-- zsRelayCapturerName peut etre court ; knownShards utilise souvent Nom-Royaume (SH sync).
-- strict : pas de match par prenom seul (evite faux positifs popup entree cercle).
function Overlord.Shard:ResolveKnownShardPlayer(nameHint, strict)
    local hint = NormalizeShardPlayerName(nameHint)
    if hint == "" then return nil, nil end
    if not self:PartyInviteTargetIsUsable(hint) then return nil, nil end

    local exactShard = self:GetKnownPlayerShard(hint)
    if exactShard then return hint, exactShard end

    local sync = Overlord.Sync
    local hintDK = sync and sync.GetCaptureContributorDedupKey and sync:GetCaptureContributorDedupKey(hint)
    local hintLower = hint:lower()

    for player, _ in pairs(self.knownShards) do
        if self:PartyInviteTargetIsUsable(player) then
            local shard = self:GetKnownPlayerShard(player)
            if shard then
                if player:lower() == hintLower then return player, shard end
                if hintDK and sync then
                    local pdk = sync:GetCaptureContributorDedupKey(player)
                    if pdk and pdk:lower() == hintDK:lower() then return player, shard end
                end
                if not strict then
                    local hintBase = hint:match("^([^%-]+)") or hint
                    local base = player:match("^([^%-]+)") or player
                    if base:lower() == hintBase:lower() then return player, shard end
                end
            end
        end
    end
    return nil, nil
end

function Overlord.Shard:IsPlayerOnDifferentShard(playerName)
    local myShard = CoerceShardId(self.currentShardID)
    if myShard == nil then return false end
    local resolved, theirShard = self:ResolveKnownShardPlayer(playerName)
    if not resolved or not theirShard then return false end
    return tonumber(theirShard) ~= myShard
end

local SHARD_ZONE_PROMPT_COOLDOWN = 60
local SHARD_KEEP_NEGATIVE_PROBE_COOLDOWN = 4
local SHARD_ZONE_ENTRY_RESOLVE_TTL = 5
local lastShardZonePromptAt = {}
local lastShardKeepPromptAt = {}
local lastShardKeepPromptIdentity = {}
local lastShardKeepPromptRevision = {}
local lastShardKeepProbeAt = {}
local lastShardKeepProbeRevision = {}
local lastShardKeepProbeIdentity = {}
local lastShardOutpostPromptAt = {}
local shardZonePromptPendingZoneId = nil
local zoneEntryCapturerCache = nil

-- Popup auto entree disque : OK en party ; desactive en raid (evite spam massif au bord du cercle).
local function ShardZoneEntryAutoPromptSuppressed()
    return IsInRaid and IsInRaid()
end

local function CacheZoneEntryCapturer(zoneId, capturerKey, resolved, sid)
    zoneEntryCapturerCache = {
        zoneId = zoneId,
        capturerKey = capturerKey:lower(),
        resolved = resolved,
        sid = sid,
        at = GetTime(),
    }
end

local function GetCachedZoneEntryCapturer(zoneId, capturerKey)
    local c = zoneEntryCapturerCache
    if not c then return nil end
    if GetTime() - c.at > SHARD_ZONE_ENTRY_RESOLVE_TTL then
        zoneEntryCapturerCache = nil
        return nil
    end
    if c.zoneId ~= zoneId or c.capturerKey ~= capturerKey:lower() then
        return nil
    end
    return c
end

local function ZoneEntryCapturerQualifiesPrompt(shard, resolved, sid)
    local myShard = CoerceShardId(shard.currentShardID)
    if myShard == nil then return false end
    if resolved and sid then
        return tonumber(sid) ~= myShard
    end
    return true
end

local function ShardTargetFaction(playerName)
    if Overlord.Leaderboard and Overlord.Leaderboard.GetExportPlayerMeta then
        local _, f = Overlord.Leaderboard:GetExportPlayerMeta(playerName)
        if f == "Alliance" or f == "Horde" then return f end
    end
    return nil
end

local function GetEnemyFactionForShardPrompt()
    if Overlord.Zones and Overlord.Zones.GetEnemyFaction then
        local fac = Overlord.Zones:GetEnemyFaction()
        if fac then return fac end
    end
    if Overlord.PlayerFaction == "Alliance" then return "Horde" end
    if Overlord.PlayerFaction == "Horde" then return "Alliance" end
    return nil
end

local function ZoneEntryIsEnemyPush(zone)
    local enemyFac = GetEnemyFactionForShardPrompt()
    return zone and zone.status == "in_progress" and enemyFac and zone.owner == enemyFac
end

local function ZoneEntryIsAllyPush(zone)
    local playerFac = Overlord.PlayerFaction
    return zone and zone.status == "in_progress" and playerFac and zone.owner == playerFac
end

-- Capteur relais ZS (ennemi) ou capteur officiel allie (9e champ ZS).
local function GetZoneEntryCapturerName(zone)
    if not zone then return "" end
    if not Overlord.CaptureLease or not Overlord.CaptureLease.IsFreshDirect
        or not Overlord.CaptureLease:IsFreshDirect(zone) then return "" end
    if ZoneEntryIsAllyPush(zone) then
        return NormalizeShardPlayerName(zone.zsOfficialCapturerName)
    end
    if ZoneEntryIsEnemyPush(zone) then
        return NormalizeShardPlayerName(zone.zsRelayCapturerName)
    end
    return ""
end

local function IsSelfShardInviteTarget(playerName)
    if not playerName or playerName == "" then return false end
    local sync = Overlord.Sync
    if not sync or not sync.GetPlayerFullName then return false end
    local selfName = sync:GetPlayerFullName()
    if not selfName or selfName == "" then return false end
    if playerName:lower() == selfName:lower() then return true end
    if sync.GetCaptureContributorDedupKey then
        local sk = sync:GetCaptureContributorDedupKey(selfName)
        local pk = sync:GetCaptureContributorDedupKey(playerName)
        if sk and pk and sk:lower() == pk:lower() then return true end
    end
    if sync and sync.ForeverIdentitiesMatch then
        return sync:ForeverIdentitiesMatch(playerName, selfName)
    end
    return false
end

local function BuildDifferentShardRowsForFaction(shard, faction)
    return {
        _overlordShardRowSource = true,
        source = shard.knownShards,
        differentCurrent = true,
        getRevision = function() return tonumber(shard._gkPromptPeerRevision) or 0 end,
        accept = function(player)
            if shard:IsPlayerAlreadyGrouped(player) then return false, true end
        local pf = ShardTargetFaction(player)
            return not faction or not pf or pf == faction, false
        end,
    }
end

-- Cibles invite a l'entree cercle : capteur sync sur autre shard (ennemi relais ZS ou allie officiel).
-- preferCache : reutilise le resolve de ScheduleAutoPromptOnZoneEntry (evite double scan knownShards).
function Overlord.Shard:BuildZoneEntryInviteRows(zone, preferCache)
    local myShard = CoerceShardId(self.currentShardID)
    if myShard == nil or not zone then return {} end

    local capturer = GetZoneEntryCapturerName(zone)
    if capturer == "" then return {} end

    local resolved, sid
    local fromCache = false
    if preferCache then
        local c = GetCachedZoneEntryCapturer(zone.id, capturer)
        if c then
            resolved, sid = c.resolved, c.sid
            fromCache = true
        end
    end
    if not fromCache then
        resolved, sid = self:ResolveKnownShardPlayer(capturer, true)
    end

    if resolved and sid then
        if self:IsPlayerAlreadyGrouped(resolved) then return {} end
        if tonumber(sid) == myShard then return {} end
        return { { player = resolved, shard = sid } }
    end

    -- Capteur sync sans entree SH locale : proposer le nom ZS (ex. RP Kirin Tor sur shard 9).
    if self:IsPlayerAlreadyGrouped(capturer) then return {} end
    return { { player = capturer, shard = "?" } }
end

function Overlord.Shard:ZoneQualifiesForShardPrompt(zone, rows)
    if not zone or not zone.id then return false end
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return false end
    if ShardZoneEntryAutoPromptSuppressed() then return false end
    if not ShardIdIsKnown(self.currentShardID) then return false end
    if not ZoneEntryIsEnemyPush(zone) and not ZoneEntryIsAllyPush(zone) then return false end
    if rows then return #rows > 0 end
    return #self:BuildZoneEntryInviteRows(zone) > 0
end

function Overlord.Shard:FinishAutoPromptOnZoneEntry(zoneId)
    shardZonePromptPendingZoneId = nil
    if not zoneId or zoneId == "" then return end
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return end
    if ShardZoneEntryAutoPromptSuppressed() then return end
    local zone = Overlord.Zones and Overlord.Zones.GetZone and Overlord.Zones:GetZone(zoneId)
    if not zone then return end
    local currentZone = Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone
        and Overlord.Zones:GetCurrentPlayerZone()
    if not currentZone or currentZone.id ~= zoneId then return end
    local now = GetTime()
    if now - (lastShardZonePromptAt[zoneId] or 0) < SHARD_ZONE_PROMPT_COOLDOWN then return end

    local rows = self:BuildZoneEntryInviteRows(zone, true)
    if not self:ZoneQualifiesForShardPrompt(zone, rows) then return end

    if rows[1] and rows[1].player then
        if ZoneEntryIsAllyPush(zone) and IsSelfShardInviteTarget(rows[1].player) then return end
        local expectedFac = zone.owner
        if expectedFac then
            local pf = ShardTargetFaction(rows[1].player)
            if pf and pf ~= expectedFac then return end
        end
    end

    lastShardZonePromptAt[zoneId] = now
    if Overlord.UI and Overlord.UI.OpenShardMismatchPopup then
        Overlord.UI:OpenShardMismatchPopup(nil, {
            zoneEntry = true,
            zoneName = zone.name or zoneId,
            rows = rows,
            promptKind = ZoneEntryIsAllyPush(zone) and "ally" or "enemy",
        })
    end
end

-- Entree cercle uniquement : gates legeres sync, resolve capteur une fois, popup au frame suivant.
function Overlord.Shard:ScheduleAutoPromptOnZoneEntry(zone)
    if not zone or not zone.id then return end
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return end
    if ShardZoneEntryAutoPromptSuppressed() then return end
    if not ShardIdIsKnown(self.currentShardID) then return end
    if not ZoneEntryIsEnemyPush(zone) and not ZoneEntryIsAllyPush(zone) then return end
    local capturer = GetZoneEntryCapturerName(zone)
    if capturer == "" then return end
    if ZoneEntryIsAllyPush(zone) and IsSelfShardInviteTarget(capturer) then return end
    local now = GetTime()
    if now - (lastShardZonePromptAt[zone.id] or 0) < SHARD_ZONE_PROMPT_COOLDOWN then return end

    local resolved, sid = self:ResolveKnownShardPlayer(capturer, true)
    CacheZoneEntryCapturer(zone.id, capturer, resolved, sid)
    if not ZoneEntryCapturerQualifiesPrompt(self, resolved, sid) then return end
    if shardZonePromptPendingZoneId == zone.id then return end

    shardZonePromptPendingZoneId = zone.id
    local zoneId = zone.id
    C_Timer.After(0, function()
        if shardZonePromptPendingZoneId ~= zoneId then return end
        if Overlord.Shard and Overlord.Shard.FinishAutoPromptOnZoneEntry then
            Overlord.Shard:FinishAutoPromptOnZoneEntry(zoneId)
        end
    end)
end

-- Entre deux tentatives v8, le GA conserve le shard Anchor requis. Le rendre visible ici
-- evite qu'un joueur sur une autre couche voie simplement son tag refuse sans hop possible.
local function GetGkEntryRetryInfo(st)
    local gk = Overlord.GuildKeep
    if not st or not gk or not gk.GetRequiredRetryShardInfo then return nil end
    return gk:GetRequiredRetryShardInfo(
        st, st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt,
        (GetServerTime and GetServerTime()) or time())
end

local function GetGkEntryAssaultFaction(st)
    if st and st.status == "in_progress" then return st.ownerFaction end
    local _, _, retryFaction = GetGkEntryRetryInfo(st)
    return retryFaction
end

local function GkEntryIsEnemyPush(st)
    local enemyFac = GetEnemyFactionForShardPrompt()
    return enemyFac and GetGkEntryAssaultFaction(st) == enemyFac
end

local function GkEntryIsAllyPush(st)
    local playerFac = Overlord.PlayerFaction
    return playerFac and GetGkEntryAssaultFaction(st) == playerFac
end

local function GetGkEntryCapturerName(st)
    if not st or not Overlord.GuildKeep then return "" end
    if st.status ~= "in_progress" then
        local _, retryPlayer = GetGkEntryRetryInfo(st)
        return NormalizeShardPlayerName(retryPlayer)
    end
    -- Le relay est l'autorite transportee par le dernier GK. L'officiel direct peut rester
    -- l'ancien porteur apres un handoff si ce client n'a pas vu le heartbeat du successeur.
    local relay = NormalizeShardPlayerName(st.gkRelayCapturerName)
    if relay ~= "" then return relay end
    if Overlord.GuildKeep.GetEffectiveCapturerName then
        local active = NormalizeShardPlayerName(Overlord.GuildKeep:GetEffectiveCapturerName(st))
        if active ~= "" then return active end
    end
    if Overlord.GuildKeep.GetAssaultShardPlayer then
        local anchorPlayer = NormalizeShardPlayerName(Overlord.GuildKeep:GetAssaultShardPlayer(st))
        if anchorPlayer ~= "" then return anchorPlayer end
    end
    return ""
end

function Overlord.Shard:BuildGkEntryInviteRows(st, siteKey)
    local myShard
    if siteKey and self.GetCaptureLocalShardID then
        myShard = self:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8)
    elseif self.GetFreshLocalShardID then
        myShard = self:GetFreshLocalShardID(8)
    else
        myShard = CoerceShardId(self.currentShardID)
    end
    if myShard == nil or not st then return {} end
    local assaultShard = Overlord.GuildKeep and Overlord.GuildKeep.GetAssaultShardId
        and Overlord.GuildKeep:GetAssaultShardId(st) or nil
    if not assaultShard then assaultShard = GetGkEntryRetryInfo(st) end
    if not assaultShard or tonumber(assaultShard) == myShard then return {} end
    local targetFac, capturer = GetGkEntryAssaultFaction(st), GetGkEntryCapturerName(st)
    local anchorContact = ""
    if capturer ~= "" then
        if st.status ~= "in_progress" then
            -- Le helper n'expose ici qu'un GA terminal courant/rejouable.
            anchorContact = capturer
        else
        local serverNow = (GetServerTime and GetServerTime()) or time()
        local updatedAt = math.floor(tonumber(st.updatedAt) or 0)
        -- En Large Event, SH peut etre volontairement coupe alors que le GK relayé est frais.
        -- Le nom d'autorite de ce GK reste un contact sûr : le lien lui DEMANDE une invitation
        -- et ne peut donc jamais tirer l'Anchor sur notre mauvaise couche.
        if updatedAt > 0 and updatedAt <= serverNow + 300 and serverNow - updatedAt <= 20 then
            anchorContact = capturer
        end
        end
    end
    local anchorKey = capturer:lower()
    return {
        _overlordShardRowSource = true,
        source = self.knownShards,
        targetShard = assaultShard,
        anchorPlayer = anchorContact ~= "" and anchorContact or nil,
        anchorShard = assaultShard,
        getRevision = function() return tonumber(self._gkPromptPeerRevision) or 0 end,
        accept = function(player, _, isSyntheticAnchor)
            player = NormalizeShardPlayerName(player)
            if player == "" or IsSelfShardInviteTarget(player) then return false, false end
        if self:IsPlayerAlreadyGrouped(player) then
                return false, true
        end
        local playerFac = ShardTargetFaction(player)
            local isAnchorPlayer = isSyntheticAnchor or (anchorKey ~= ""
                and player:lower() == anchorKey)
            if targetFac and playerFac ~= targetFac
                and not (isAnchorPlayer and not playerFac) then return false, false end
            return true, false
        end,
        less = function(a, b)
            local ac = anchorKey ~= "" and a.player:lower() == anchorKey
            local bc = anchorKey ~= "" and b.player:lower() == anchorKey
        if ac ~= bc then return ac end
        return a.player:lower() < b.player:lower()
        end,
    }
end

local shownGkOutdatedVersion

local function MaybeWarnOutdatedOnGuildKeepEntry()
    local newer = Overlord.Sync and Overlord.Sync.GetKnownNewerVersion
        and Overlord.Sync:GetKnownNewerVersion()
    if not newer or newer == shownGkOutdatedVersion
        or not Overlord.Popups or not Overlord.Popups.ShowOutdatedVersion then return end
    shownGkOutdatedVersion = newer
    Overlord.Popups:ShowOutdatedVersion(newer)
end

function Overlord.Shard:TryAutoPromptOnGuildKeepEntry(siteKey, site, st)
    if not siteKey or not site or not st then return end
    -- Un client pre-v8 ou reste sur l'ancien 9.9.1 ignore le tuple root+offset. Le prevenir ici permet de
    -- distinguer immediatement un addon obsolete d'un vrai bug de timer/Anchor.
    MaybeWarnOutdatedOnGuildKeepEntry()
    -- Capture GK en monde ouvert Forever (pas de Warmode).
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return end
    -- Contrairement aux zones ordinaires, le raid est le cas principal des Guild Keeps.
    -- Les gardes ci-dessous filtrent deja la shard courante et les contacts groupes.
    local localShard = self.GetCaptureLocalShardID
        and self:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8)
    if not localShard then return end
    if not GkEntryIsEnemyPush(st) and not GkEntryIsAllyPush(st) then return end
    local assaultShard = Overlord.GuildKeep and Overlord.GuildKeep.GetAssaultShardId
        and Overlord.GuildKeep:GetAssaultShardId(st) or tonumber(st.assaultShardId)
    local retryShard, retryPlayer
    if not assaultShard then
        retryShard, retryPlayer = GetGkEntryRetryInfo(st)
        assaultShard = retryShard
    end
    -- Cas ultra-majoritaire : deja sur l'Anchor. Eviter de reconstruire une identite et de
    -- rescanner les contacts connus a chaque tick pour tout le raid.
    if not assaultShard or tonumber(localShard) == tonumber(assaultShard) then return end
    local now = GetTime()
    local anchorIdentity = table.concat({
        tostring(assaultShard or ""),
        tostring(math.floor(tonumber(retryShard and st.abortedAssaultStartedAt
            or st.assaultShardStartedAt) or 0)),
        tostring(math.floor(tonumber(retryShard and st.abortedAssaultGenerationAt
            or st.assaultGenerationAt) or 0)),
        tostring(retryPlayer or st.assaultShardPlayer or ""),
    }, ":")
    local peerRevision = tonumber(self._gkPromptPeerRevision) or 0
    local samePromptIdentity = lastShardKeepPromptIdentity[siteKey] == anchorIdentity
    if samePromptIdentity and lastShardKeepPromptRevision[siteKey] == peerRevision
        and now - (lastShardKeepPromptAt[siteKey] or 0) < SHARD_ZONE_PROMPT_COOLDOWN then return end
    local sameProbeIdentity = lastShardKeepProbeIdentity[siteKey] == anchorIdentity
    if sameProbeIdentity and lastShardKeepProbeRevision[siteKey] == peerRevision
        and now - (lastShardKeepProbeAt[siteKey] or 0) < SHARD_KEEP_NEGATIVE_PROBE_COOLDOWN then
        return
    end
    lastShardKeepProbeAt[siteKey] = now
    lastShardKeepProbeRevision[siteKey] = peerRevision
    lastShardKeepProbeIdentity[siteKey] = anchorIdentity

    local rowSource = self:BuildGkEntryInviteRows(st, siteKey)
    local function FinishGkPrompt(rows, groupedContact)
        rows = type(rows) == "table" and rows or {}
        groupedContact = groupedContact or ""
    if rows[1] and rows[1].player then
        local expectedFac = GetGkEntryAssaultFaction(st)
        if expectedFac then
            local pf = ShardTargetFaction(rows[1].player)
            if pf and pf ~= expectedFac then return end
        end
    end

    lastShardKeepPromptAt[siteKey] = now
    lastShardKeepPromptIdentity[siteKey] = anchorIdentity
    lastShardKeepPromptRevision[siteKey] = peerRevision
    if Overlord.UI and Overlord.UI.OpenShardMismatchPopup then
        local label = (Overlord.GuildKeep and Overlord.GuildKeep.GetDisplayName)
            and Overlord.GuildKeep:GetDisplayName(site) or siteKey
        assaultShard = assaultShard or (rows[1] and rows[1].shard)
        local shardLabel = "#" .. tostring(assaultShard or "?")
        if assaultShard and self.GetShardReference then
            local _, realm = self:GetShardReference(assaultShard)
            if realm and realm ~= "" then
                shardLabel = shardLabel .. " " .. string.format(L.SHARD_BADGE_REFERENCE, realm)
            end
        end
        if groupedContact ~= "" then
            local currentShard = self:GetCurrentShardID() or "?"
            local guidance = string.format(
                L.GUILD_KEEP_GROUPED_WRONG_SHARD,
                groupedContact, tostring(currentShard), tostring(assaultShard or "?"))
            Overlord.UI:OpenShardMismatchPopup(nil, {
                zoneEntry = true,
                zoneName = label,
                rows = {},
                rowsReady = true,
                promptKind = GkEntryIsAllyPush(st) and "ally" or "enemy",
                subText = guidance,
                hintText = L.GUILD_KEEP_GROUPED_WRONG_SHARD_HINT,
                emptyText = L.GUILD_KEEP_GROUPED_WRONG_SHARD_EMPTY,
            })
            return
        end
        if #rows == 0 then
            -- L'Anchor est connue mais aucun contact compatible n'est encore visible.
            -- Informer tout de suite le retardataire et lancer un petit rattrapage ; une
            -- revision de peers rouvrira ce meme popup avec le bouton de demande d'invite.
            Overlord.UI:OpenShardMismatchPopup(nil, {
                zoneEntry = true,
                zoneName = label,
                rows = {},
                rowsReady = true,
                promptKind = GkEntryIsAllyPush(st) and "ally" or "enemy",
                requestInvite = true,
                targetShard = assaultShard,
                subText = string.format(
                    L.GUILD_KEEP_ANCHOR_CONTACT_PENDING,
                    label, shardLabel),
                hintText = L.GUILD_KEEP_ANCHOR_CONTACT_HINT,
                emptyText = L.GUILD_KEEP_ANCHOR_CONTACT_EMPTY,
            })
            if Overlord.Sync and Overlord.Sync.SendSyncRequest then
                Overlord.Sync:SendSyncRequest({
                    includeCommunity = true,
                    allowCommunityInLargeEvent = true,
                    communityMax = 3,
                    communityDelay = 1.0,
                    criticalChannel = true,
                    territorialOnly = true,
                })
            end
            return
        end
        local contact = rows[1].player
        Overlord.UI:OpenShardMismatchPopup(nil, {
            zoneEntry = true,
            zoneName = label,
            rows = rows,
            rowsReady = true,
            promptKind = GkEntryIsAllyPush(st) and "ally" or "enemy",
            requestInvite = true,
            targetShard = assaultShard,
            subText = string.format(L.SHARD_POPUP_KEEP_JOIN_SUB, label, shardLabel, contact),
        })
    end
    end
    if rowSource and rowSource._overlordShardRowSource
        and Overlord.UI and Overlord.UI.RequestShardMismatchRowsBuild then
        Overlord.UI:RequestShardMismatchRowsBuild(rowSource,
            "prepare:gk:" .. tostring(siteKey) .. ":" .. anchorIdentity,
            function(rows, meta)
                FinishGkPrompt(rows, meta and meta.groupedContact)
            end)
    else
        FinishGkPrompt(rowSource, "")
    end
end

local function OpEntryIsEnemyPush(st)
    local enemyFac = GetEnemyFactionForShardPrompt()
    return st and st.status == "in_progress" and enemyFac and st.ownerFaction == enemyFac
end

local function OpEntryIsAllyPush(st)
    local playerFac = Overlord.PlayerFaction
    return st and st.status == "in_progress" and playerFac and st.ownerFaction == playerFac
end

local function GetOpEntryCapturerName(st)
    if not st or not Overlord.Outpost then return "" end
    if OpEntryIsAllyPush(st) then
        return NormalizeShardPlayerName(st.opOfficialCapturerName)
    end
    if OpEntryIsEnemyPush(st) then
        return NormalizeShardPlayerName(Overlord.Outpost:GetEffectiveCapturerName(st))
    end
    return ""
end

function Overlord.Shard:BuildOpEntryInviteRows(st)
    local myShard = CoerceShardId(self.currentShardID)
    if myShard == nil or not st then return {} end
    local capturer = GetOpEntryCapturerName(st)
    if capturer == "" then
        local targetFac = OpEntryIsAllyPush(st) and Overlord.PlayerFaction or GetEnemyFactionForShardPrompt()
        return BuildDifferentShardRowsForFaction(self, targetFac)
    end
    local resolved, sid = self:ResolveKnownShardPlayer(capturer, true)
    if resolved and sid then
        if self:IsPlayerAlreadyGrouped(resolved) then return {} end
        if tonumber(sid) == myShard then return {} end
        return { { player = resolved, shard = sid } }
    end
    if self:IsPlayerAlreadyGrouped(capturer) then return {} end
    return { { player = capturer, shard = "?" } }
end

function Overlord.Shard:TryAutoPromptOnOutpostEntry(siteKey, site, st)
    if not siteKey or not site or not st then return end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return end
    if ShardZoneEntryAutoPromptSuppressed() then return end
    if not ShardIdIsKnown(self.currentShardID) then return end
    if not OpEntryIsEnemyPush(st) and not OpEntryIsAllyPush(st) then return end
    local now = GetTime()
    if now - (lastShardOutpostPromptAt[siteKey] or 0) < SHARD_ZONE_PROMPT_COOLDOWN then return end

    local rowSource = self:BuildOpEntryInviteRows(st)
    local function FinishOutpostPrompt(rows)
        rows = type(rows) == "table" and rows or {}
        if #rows == 0 then return end
    if rows[1] and rows[1].player then
        if OpEntryIsAllyPush(st) and IsSelfShardInviteTarget(rows[1].player) then return end
        local expectedFac = st.ownerFaction
        if expectedFac then
            local pf = ShardTargetFaction(rows[1].player)
            if pf and pf ~= expectedFac then return end
        end
    end

    lastShardOutpostPromptAt[siteKey] = now
    if Overlord.UI and Overlord.UI.OpenShardMismatchPopup then
        local label = (Overlord.Outpost and Overlord.Outpost.GetDisplayName)
            and Overlord.Outpost:GetDisplayName(site) or siteKey
        Overlord.UI:OpenShardMismatchPopup(nil, {
            zoneEntry = true,
            zoneName = label,
            rows = rows,
            rowsReady = true,
            promptKind = OpEntryIsAllyPush(st) and "ally" or "enemy",
        })
    end
    end
    if rowSource and rowSource._overlordShardRowSource
        and Overlord.UI and Overlord.UI.RequestShardMismatchRowsBuild then
        Overlord.UI:RequestShardMismatchRowsBuild(rowSource,
            "prepare:op:" .. tostring(siteKey) .. ":" .. tostring(st.updatedAt or ""),
            function(rows) FinishOutpostPrompt(rows) end)
    else
        FinishOutpostPrompt(rowSource)
    end
end

-- Filet d'evenements : vignettes, souris et kills rafraichissent sans attendre le ticker.
-- VIGNETTES_UPDATED peut spammer (zone chargee) : debounce pour eviter N scans par frame.
-- Aucun risque de "throttle" cote serveur : tout est local (GUID / liste vignettes).
local shardPulseFrame
local shardEventDebounceHandle
local shardEventNeedsUnthrottledScan = false
local SHARD_EVENT_DEBOUNCE_SEC = 0.3
local lastShardPeerPurgeAt = 0
local shardScanTimer
local shardPeerMaintenanceTimer
local shardUnknownScanDelay = SHARD_UNKNOWN_SCAN_MIN

local function PurgeExpiredShardPeers()
    local now = GetTime()
    if now - lastShardPeerPurgeAt < SHARD_BROADCAST_INTERVAL then return end
    lastShardPeerPurgeAt = now
    -- Ordre par derniere observation : au plus 32 suppressions par reveil, sans
    -- scan du cache. L'admission retire aussi la tete expiree en O(1) a saturation.
    local removed = 0
    while removed < 32 do
        local head = Overlord.Shard.peerHead
        if not head or (tonumber(head.expiresAt) or 0) > now then break end
        Overlord.Shard:RemoveKnownShardPeer(head.key)
        removed = removed + 1
    end
end

local function RefreshShardBadgeAfterScan()
    if Overlord.UI and Overlord.UI.RefreshShardBadge then
        Overlord.UI:RefreshShardBadge()
    end
end

-- Les preuves unitaires sont lues au moment exact ou WoW expose le token. Attendre le
-- debounce perdait parfois la cible / le cadavre avant le scan, notamment dans un fortin
-- sans vignette exploitable. Ce chemin ne parcourt ni les vignettes ni les 40 nameplates.
local function ObserveShardFromGUID(guid)
    if not Overlord.Shard:SyncLocalContext() then return false end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return false end
    local shardID = ExtractShardIDFromGUID(guid)
    if shardID == nil then return false end
    local now = GetTime()
    local changed = shardID ~= CoerceShardId(Overlord.Shard.currentShardID)
    Overlord.Shard.currentShardID = shardID
    Overlord.Shard.lastUpdateAt = now
    Overlord.Shard.lastScanAttemptAt = now
    Overlord.Shard.localShardSource = "guid"
    if Overlord.Sync and Overlord.Sync.BroadcastShard
        and (changed or (tonumber(Overlord.Shard.lastBroadcastAt) or 0)
            + SHARD_BROADCAST_INTERVAL <= now) then
        Overlord.Shard.lastBroadcastAt = now
        Overlord.Sync:BroadcastShard(shardID)
    end
    -- Ne pas annuler/recreer le timer pour chaque nameplate d'une zone peuplee.
    if ScheduleNextShardScan and (changed or not shardScanTimer) then
        ScheduleNextShardScan(true)
    end
    RefreshShardBadgeAfterScan()
    return true
end

local function ObserveShardFromUnit(unit)
    local shardID, guid = ExtractShardIDFromUnit(unit)
    return shardID ~= nil and ObserveShardFromGUID(guid)
end

local function LocalShardEvidenceNeedsRefresh(maxAge)
    local shardID = CoerceShardId(Overlord.Shard.currentShardID)
    local measuredAt = tonumber(Overlord.Shard.lastUpdateAt) or 0
    local contextAt = tonumber(Overlord.Shard.localContextStartedAt) or 0
    return shardID == nil or measuredAt <= 0 or measuredAt < contextAt
        or GetTime() - measuredAt > (tonumber(maxAge) or 8)
end

local SHARD_LOCAL_KILL_UNITS = { "player", "pet", "vehicle" }
local function PartyKillAttackerIsLocal(attackerGUID)
    if not UnitGUID then return false end
    -- Un PARTY_KILL de raid peut provenir d'un membre sur une autre couche. La comparaison
    -- complete reste dans pcall car les GUID de combat peuvent etre secrets en 12.x.
    local ok, isLocal = pcall(function()
        if type(attackerGUID) ~= "string" or attackerGUID == "" then return false end
        for i = 1, #SHARD_LOCAL_KILL_UNITS do
            local localGUID = UnitGUID(SHARD_LOCAL_KILL_UNITS[i])
            if localGUID and attackerGUID == localGUID then return true end
        end
        return false
    end)
    return ok and isLocal == true
end

StopShardScanMaintenance = function()
    if shardScanTimer and shardScanTimer.Cancel then shardScanTimer:Cancel() end
    shardScanTimer = nil
    shardUnknownScanDelay = SHARD_UNKNOWN_SCAN_MIN
    Overlord.Shard.nextMaintenanceScanAt = 0
end

ScheduleNextShardScan = function(hasKnownShard)
    if not C_Timer or not C_Timer.NewTimer then return end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then
        StopShardScanMaintenance()
        return false
    end

    local delay
    if hasKnownShard then
        shardUnknownScanDelay = SHARD_UNKNOWN_SCAN_MIN
        delay = SHARD_KNOWN_SCAN_INTERVAL
        local lastBroadcast = tonumber(Overlord.Shard.lastBroadcastAt) or 0
        if lastBroadcast > 0 then
            delay = math.min(delay,
                math.max(1, SHARD_BROADCAST_INTERVAL - (GetTime() - lastBroadcast)))
        end
    else
        delay = shardUnknownScanDelay
        shardUnknownScanDelay = math.min(
            SHARD_UNKNOWN_SCAN_MAX, math.max(SHARD_UNKNOWN_SCAN_MIN, delay * 2))
    end

    if shardScanTimer and shardScanTimer.Cancel then shardScanTimer:Cancel() end
    Overlord.Shard.nextMaintenanceScanAt = GetTime() + delay
    shardScanTimer = C_Timer.NewTimer(delay, function()
        shardScanTimer = nil
        Overlord.Shard.nextMaintenanceScanAt = 0
        if Overlord.InstanceSuspended then
            ScheduleNextShardScan(Overlord.Shard.currentShardID ~= nil)
            return
        end
        if Overlord.IsShardHelperActive and Overlord:IsShardHelperActive() then
            Overlord.Shard:Update()
            RefreshShardBadgeAfterScan()
        else
            StopShardScanMaintenance()
        end
    end)
end

local function ScheduleShardPeerMaintenance()
    if shardPeerMaintenanceTimer or not C_Timer or not C_Timer.NewTimer then return end
    shardPeerMaintenanceTimer = C_Timer.NewTimer(SHARD_BROADCAST_INTERVAL, function()
        shardPeerMaintenanceTimer = nil
        if not Overlord.InstanceSuspended then PurgeExpiredShardPeers() end
        ScheduleShardPeerMaintenance()
    end)
end

local function ScheduleShardUpdateFromEvent(_, event, unit)
    if Overlord.InstanceSuspended then return end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return end
    local evidenceUnit
    if event == "PLAYER_TARGET_CHANGED" then
        evidenceUnit = "target"
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        evidenceUnit = "mouseover"
    elseif event == "PLAYER_FOCUS_CHANGED" then
        evidenceUnit = "focus"
    elseif event == "PLAYER_SOFT_ENEMY_CHANGED" then
        evidenceUnit = "softenemy"
    elseif event == "PLAYER_SOFT_FRIEND_CHANGED" then
        evidenceUnit = "softfriend"
    elseif event == "PLAYER_SOFT_INTERACT_CHANGED" then
        evidenceUnit = "softinteract"
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        evidenceUnit = unit
    end
    -- Une preuve unitaire rafraichit aussi un shard connu mais age de plus de 8 s.
    -- C'etait le cas exact ou le timer refusait de partir malgre un nouveau PNJ cible.
    local needsRefresh = LocalShardEvidenceNeedsRefresh(8)
    if evidenceUnit and ObserveShardFromUnit(evidenceUnit) then return end
    if needsRefresh then
        -- Une cible peut devenir indisponible entre l'event et UnitGUID. Le scan debounced
        -- reste force pour profiter d'une autre nameplate / vignette de la meme frame.
        if evidenceUnit then shardEventNeedsUnthrottledScan = true end
    end
    -- Coalescer la rafale sans annuler/recreer un timer a chaque evenement.
    if shardEventDebounceHandle then return end
    shardEventDebounceHandle = C_Timer.NewTimer(SHARD_EVENT_DEBOUNCE_SEC, function()
        shardEventDebounceHandle = nil
        if Overlord.InstanceSuspended then return end
        if Overlord.IsShardHelperActive and Overlord:IsShardHelperActive() then
            local forceScan = shardEventNeedsUnthrottledScan
            shardEventNeedsUnthrottledScan = false
            Overlord.Shard:Update(not forceScan)
            RefreshShardBadgeAfterScan()
        end
    end)
end

local function HandleShardPulseEvent(frame, event, ...)
    if event == "PARTY_KILL" then
        if Overlord.InstanceSuspended then return end
        if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return end
        local arg1, arg2 = ...
        -- En 12.0 PARTY_KILL peut fournir (attackerGUID, targetGUID). Consommer d'abord
        -- targetGUID : contrairement au token "target", il survit a la disparition du cadavre.
        -- Le format legacy fournit parfois arg1 comme unit token ; les deux replis le couvrent.
        if not (PartyKillAttackerIsLocal(arg1) and ObserveShardFromGUID(arg2))
            and not ObserveShardFromUnit(arg1)
            and not ObserveShardFromUnit("target") then
            if LocalShardEvidenceNeedsRefresh(8) then
                Overlord.Shard:Update()
                RefreshShardBadgeAfterScan()
            end
        end
        return
    end
    ScheduleShardUpdateFromEvent(frame, event, ...)
end

-- Initialise le ticker de mise a jour du shard (marqueur legacy des tests).
-- Maintenance one-shot adaptative : rapide tant que la shard est inconnue, lente
-- une fois stable. Les transitions et preuves ephemeres restent event-driven.
function Overlord.Shard:Initialize()
    ScheduleShardPeerMaintenance()
    if not shardPulseFrame then
        shardPulseFrame = CreateFrame("Frame")
        shardPulseFrame:RegisterEvent("VIGNETTES_UPDATED")
        shardPulseFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        shardPulseFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
        shardPulseFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
        shardPulseFrame:RegisterEvent("PLAYER_SOFT_ENEMY_CHANGED")
        shardPulseFrame:RegisterEvent("PLAYER_SOFT_FRIEND_CHANGED")
        shardPulseFrame:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
        shardPulseFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        shardPulseFrame:RegisterEvent("PARTY_KILL")
        shardPulseFrame:SetScript("OnEvent", HandleShardPulseEvent)
    end
    if Overlord.IsShardHelperActive and Overlord:IsShardHelperActive() then
        self:Update()
    end
end

-- ============================================================
-- WoW 12.0.5 : Suppression des workarounds de taint
-- Les hooks sur StaticPopup et UIErrorsFrame CAUSAIENT du taint.
-- Si l'addon fonctionne correctement, ces popups ne devraient pas apparaitre.
-- Si un popup apparait, c'est un bug a corriger, pas a masquer.
-- ============================================================

-- Forward-declare : pendingFrontEnter + ticker domination
local pendingFrontEnter = nil
local StartDominationTicker, StopDominationTicker, TryDominationInitialGrant
-- Phase de rattrapage (instanceID parasite) sur carte de front : message chat une fois puis reset quand OK
local catchUpNotified = false

-- Ticker relances demande de groupe RP (annule aussi a l'entree en instance)
local rpGroupRetryTicker = nil
local function CancelRPGroupRetryTicker()
    if rpGroupRetryTicker then
        rpGroupRetryTicker:Cancel()
        rpGroupRetryTicker = nil
    end
end

-- Timers differees annulables (sortie instance / reprise GetInstanceInfo)
local postInstanceRecoveryTimers = {}
local resumeInstanceRetryTimers = {}
local RESUME_INSTANCE_RETRY_DELAYS = { 0.35, 0.95, 2.0 }

-- Apres sortie d'instance : la carte / GetInstanceInfo / scenario peuvent etre faux
-- pendant ~0,5-2 s. Re-verifie le front actif et raccroche minimap + carte si besoin.
local POST_INSTANCE_RECHECK_DELAYS = { 0.55, 1.35, 2.8, 4.5 }

local function DebugOverlord(msg)
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFF8888FF[Overlord:dbg]|r " .. tostring(msg))
    end
end

-- Sons UI (respecte config.soundEnabled) : buff or, classement, etc.
local ADDON_SOUNDS = {
    gold_buff = {
        SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND,
        120,
        SOUNDKIT and SOUNDKIT.IG_BACKPACK_COIN_OK,
        865,
    },
    -- Depense bois individuel (coupe / craft, repli sac si indisponible)
    wood_spend = {
        122698,
        SOUNDKIT and SOUNDKIT.IG_BACKPACK_OPEN,
        852,
    },
    lb_open = {
        SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN,
        850,
    },
    lb_close = {
        SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE,
        851,
    },
    general_fallen = {
        SOUNDKIT and SOUNDKIT.RAID_WARNING,
        8959,
    },
}

-- Appel de faction : SoundKitID Wowhead - Master, selon la faction du joueur
local FACTION_CALL_SOUND_KIT = {
    Horde = 123840,    -- FX_Warsong_WarHorn_6.0_LongDistance
    Alliance = 137963, -- WorldPVP_82_Nazjatar_EventStart_Horn
}

-- Popup bienvenue : Bloodlust (Horde) / Heroism (Alliance shaman)
local WELCOME_POPUP_SOUND_KIT = {
    Horde = 10030,    -- bloodlust_player_cast_head
    Alliance = 10049, -- Heroism_Cast
}

-- Bouton Général : mêmes retours que le toggle Mode guerre (UI Blizzard).
local WARMODE_ACTIVATE_SOUND = (SOUNDKIT and SOUNDKIT.UI_WARMODE_ACTIVATE) or 118563
local WARMODE_DEACTIVATE_SOUND = (SOUNDKIT and SOUNDKIT.UI_WARMODE_DECTIVATE) or 118564

local function PlayGeneralFactionEmote()
    if InCombatLockdown() or not DoEmote then return end
    local token = (Overlord.PlayerFaction == "Horde") and "FORTHEHORDE" or "FORTHEALLIANCE"
    pcall(DoEmote, token, "none")
end

-- Musique de duel Général : Before the Storm (BFA main title)
local GENERAL_DUEL_MUSIC_FILE = 2146580
local GENERAL_DUEL_FADE_MS = 2000
local generalDuelMusicActive = false
local generalDuelSoundHandle = nil
local generalDuelFadeStopHandle = nil

local function TryPlaySoundEntry(entry, channelOrder)
    if not entry then return false end
    local channels = channelOrder or { "SFX", "Master" }
    for _, channel in ipairs(channels) do
        if PlaySound then
            local ok, willPlay = pcall(PlaySound, entry, channel, false)
            if ok and willPlay then return true end
        end
        if PlaySoundFile then
            local ok, willPlay = pcall(PlaySoundFile, entry, channel)
            if ok and willPlay then return true end
        end
    end
    return false
end

local function TryPlaySoundList(ids, channelOrder)
    if not ids then return false end
    for i = 1, #ids do
        local id = ids[i]
        if id and TryPlaySoundEntry(id, channelOrder) then
            return true
        end
    end
    return false
end

-- Panneaux flottants (tutoriel, export, communaute, etc.) : meme son que le classement.
function Overlord:PlayPanelOpenSound()
    if self.PlayAddonSound then self:PlayAddonSound("lb_open") end
end

function Overlord:PlayPanelCloseSound()
    if self.PlayAddonSound then self:PlayAddonSound("lb_close") end
end

function Overlord:PlayGeneralDuelMusic()
    if not OverlordDB or not OverlordDB.config then return end
    if OverlordDB.config.soundEnabled == false then return end
    if not PlaySoundFile then return false end
    if generalDuelMusicActive then return true end
    -- Coupe immédiatement une piste encore en fondu (évite chevauchement au redémarrage).
    if generalDuelFadeStopHandle and StopSound then
        pcall(StopSound, generalDuelFadeStopHandle, 0)
        generalDuelFadeStopHandle = nil
    end
    local ok, willPlay, handle = pcall(PlaySoundFile, GENERAL_DUEL_MUSIC_FILE, "Music")
    if ok and willPlay then
        generalDuelMusicActive = true
        generalDuelSoundHandle = handle
        return true
    end
    return false
end

function Overlord:StopGeneralDuelMusic()
    if not generalDuelMusicActive and not generalDuelSoundHandle and not generalDuelFadeStopHandle then return end
    generalDuelMusicActive = false
    local handle = generalDuelSoundHandle
    generalDuelSoundHandle = nil
    if handle and StopSound then
        pcall(StopSound, handle, GENERAL_DUEL_FADE_MS)
        if GENERAL_DUEL_FADE_MS > 0 then
            generalDuelFadeStopHandle = handle
        end
    end
end

function Overlord:PlayAddonSound(key)
    if not OverlordDB or not OverlordDB.config then return end
    if OverlordDB.config.soundEnabled == false then return end
    if key == "faction_call" then
        local soundId = FACTION_CALL_SOUND_KIT[Overlord.PlayerFaction]
            or FACTION_CALL_SOUND_KIT.Horde
        TryPlaySoundEntry(soundId, { "Master", "SFX" })
        return
    end
    if key == "welcome_popup" then
        local soundId = WELCOME_POPUP_SOUND_KIT[Overlord.PlayerFaction]
            or WELCOME_POPUP_SOUND_KIT.Alliance
        TryPlaySoundEntry(soundId, { "Master", "SFX" })
        return
    end
    if key == "general_claim" then
        TryPlaySoundEntry(WARMODE_ACTIVATE_SOUND, { "Master", "SFX" })
        PlayGeneralFactionEmote()
        return
    end
    if key == "general_release" then
        TryPlaySoundEntry(WARMODE_DEACTIVATE_SOUND, { "Master", "SFX" })
        return
    end
    if key == "general_assumed" then
        TryPlaySoundEntry(WARMODE_ACTIVATE_SOUND, { "Master", "SFX" })
        return
    end
    local ids = ADDON_SOUNDS[key]
    if not ids then return end
    for _, id in ipairs(ids) do
        if id and TryPlaySoundEntry(id) then return end
    end
end

-- Pool FR/EU/DE/US : royaumes FR/DE dans RealmPools.lua (source unique).

-- Tag locale WoW normalise (sync wire) : frFR -> "frfr", ptBR -> "ptbr", esMX -> "esmx".
function Overlord:GetClientLocaleTag()
    local loc = GetLocale() or "enUS"
    loc = loc:lower():match("^([a-z][a-z][a-z]?[a-z]?[a-z]?)$")
    loc = loc or "enus"
    -- EU : client anglais (souvent enUS chez joueurs FR/DE) -> engb pour sync et affichage.
    if (loc == "enus" or loc == "en")
        and GetCurrentRegion and GetCurrentRegion() == 3 then
        return "engb"
    end
    return loc
end

local function LocaleDisplayIsEuContext(poolHint)
    local pool = type(poolHint) == "string" and poolHint:lower() or ""
    if Overlord.RealmPools and Overlord.RealmPools.NormalizeRegionPool then
        pool = Overlord.RealmPools:NormalizeRegionPool(pool)
    end
    if pool == "eu" then return true end
    if pool == "us" then return false end
    return not (GetCurrentRegion and GetCurrentRegion() == 1)
end

-- Affichage classement : frfr -> frFR, ptbr -> ptBR, esmx -> esMX.
-- poolHint optionnel (us/fr/de/eu) pour trancher en vs enUS sur EU.
function Overlord:FormatLocaleTagForDisplay(localeTag, poolHint)
    if type(localeTag) ~= "string" or localeTag == "" then return "" end
    localeTag = localeTag:lower():match("^([a-z][a-z][a-z]?[a-z]?[a-z]?)$")
    if not localeTag or localeTag == "" then return "" end

    if localeTag == "en" or localeTag == "enus" then
        if LocaleDisplayIsEuContext(poolHint) then return "enGB" end
        return "enUS"
    end

    local KNOWN = {
        enus = "enUS", engb = "enGB", dede = "deDE", eses = "esES", esmx = "esMX",
        frfr = "frFR", itit = "itIT", ptbr = "ptBR", ptpt = "ptPT", ruru = "ruRU",
        kokr = "koKR", zhcn = "zhCN", zhtw = "zhTW",
    }
    if KNOWN[localeTag] then return KNOWN[localeTag] end
    if #localeTag == 4 then
        return localeTag:sub(1, 2):lower() .. localeTag:sub(3, 4):upper()
    end
    -- Legacy sync 2 lettres (avant tag complet).
    if localeTag == "fr" then return "frFR" end
    if localeTag == "de" then return "deDE" end
    if localeTag == "es" then return "esES" end
    if localeTag == "it" then return "itIT" end
    if localeTag == "pt" then return "ptBR" end
    if localeTag == "ru" then return "ruRU" end
    return localeTag:upper()
end

local function GetCurrentPoolForSavedVars()
    local rp = Overlord.RealmPools
    if rp and rp.GetOverlordPoolTag then
        return rp:GetOverlordPoolTag() or "global"
    end
    return "global"
end

function Overlord:GetCurrentSavedVarsPool()
    return GetCurrentPoolForSavedVars()
end

-- Forever realmless : NA et EU seulement. Plus de buckets FR/DE.
function Overlord:GetCurrentLeaderboardSavedVarsPool()
    return GetCurrentPoolForSavedVars()
end

-- Une langue ne permet pas de distinguer NA et EU (frFR existe sur les deux).
function Overlord:SavedVarsPoolFromLocaleTag(localeTag)
    return nil
end

local function EmptyLeaderboardBucket()
    local startTs = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    local campaignId = (startTs > 0 and Overlord.TimestampToCampaignId) and Overlord:TimestampToCampaignId(startTs) or 0
    return {
        kills = {}, captures = {}, captureCount = {},
        bountyTimes = {}, bountyKills = {},
        playerInfo = {}, campaignStart = startTs, campaignId = campaignId,
        -- Ce bucket neuf respecte deja les invariants des reparations lourdes.
        repairVersion = 3,
    }
end

local function CopyLeaderboardBucket(src)
    local out = EmptyLeaderboardBucket()
    if type(src) ~= "table" then return out end
    if type(src.kills) == "table" then
        for k, v in pairs(src.kills) do out.kills[k] = v end
    end
    if type(src.captures) == "table" then
        for k, v in pairs(src.captures) do
            -- Chaque valeur captures est une liste mutable. Une copie superficielle liait
            -- deux pools SavedVariables : ajouter/fusionner une zone dans le pool courant
            -- modifiait silencieusement le bucket source conserve pour l'autre pool.
            if type(v) == "table" then
                local zones = {}
                for zoneKey, zoneId in pairs(v) do zones[zoneKey] = zoneId end
                out.captures[k] = zones
            else
                out.captures[k] = v
            end
        end
    end
    if type(src.captureCount) == "table" then
        for k, v in pairs(src.captureCount) do out.captureCount[k] = v end
    end
    if type(src.bountyTimes) == "table" then
        for k, v in pairs(src.bountyTimes) do out.bountyTimes[k] = v end
    end
    if type(src.bountyKills) == "table" then
        for k, v in pairs(src.bountyKills) do out.bountyKills[k] = v end
    end
    if type(src.playerInfo) == "table" then
        for name, info in pairs(src.playerInfo) do
            if type(info) == "table" then
                local copy = {}
                for k, v in pairs(info) do copy[k] = v end
                out.playerInfo[name] = copy
            else
                out.playerInfo[name] = info
            end
        end
    end
    out.campaignStart = tonumber(src.campaignStart) or out.campaignStart
    out.campaignId = tonumber(src.campaignId) or out.campaignId
    return out
end

local function CancelTimerList(list)
    for i = 1, #list do
        local t = list[i]
        if t and t.Cancel then
            pcall(t.Cancel, t)
        end
    end
    wipe(list)
end

local function CancelPostInstanceRecoveryTimers()
    CancelTimerList(postInstanceRecoveryTimers)
end

local function CancelResumeFromInstanceRetryTimers()
    CancelTimerList(resumeInstanceRetryTimers)
end

-- Annule toutes les relances differees liees a la sortie d'instance (ex. re-entree en arene).
local function CancelAllDeferredInstanceTimers()
    CancelPostInstanceRecoveryTimers()
    CancelResumeFromInstanceRetryTimers()
end

-- Boucle zone + domination + pins / overlays carte (facteur commun sortie instance).
local function RestoreFrontVisualSystems(reason)
    Overlord:StartUpdateLoop()
    if StartDominationTicker then StartDominationTicker() end
    if Overlord.MapMarkers then
        Overlord.MapMarkers:SetMinimapPinsVisible(true)
        Overlord.MapMarkers:ResumeWorldMapOverlays()
    end
    if reason then
        DebugOverlord("RestoreFrontVisualSystems: " .. tostring(reason))
    end
end

local function SchedulePostInstanceWorldRecovery()
    CancelPostInstanceRecoveryTimers()
    for _, d in ipairs(POST_INSTANCE_RECHECK_DELAYS) do
        local delay = d
        local t = C_Timer.NewTimer(delay, function()
            if not Overlord.IsInitialized or Overlord.InstanceSuspended then return end
            Overlord:CheckActiveFrontZone()
            if not Overlord.InActiveFront then return end
            RestoreFrontVisualSystems("postInstanceRecovery @" .. tostring(delay) .. "s")
        end)
        postInstanceRecoveryTimers[#postInstanceRecoveryTimers + 1] = t
    end
    DebugOverlord("SchedulePostInstanceWorldRecovery: " .. #POST_INSTANCE_RECHECK_DELAYS .. " timers")
end

local function CompleteResumeFromInstance(reason)
    if not Overlord._deferredModuleInitDone then
        -- PLAYER_ENTERING_WORLD peut arriver pendant une sanitation login longue. Aucun
        -- Resume/Join/handler module ne doit contourner les barrieres requises. Garder
        -- aussi InstanceSuspended=true : plusieurs handlers utilisent ce flag comme
        -- ultime barriere pendant que les stages requis terminent leur commit.
        Overlord._loginResumeDeferred = reason or true
        Overlord._loginFrontCheckDeferred = true
        return false
    end
    Overlord.InstanceSuspended = false
    CancelResumeFromInstanceRetryTimers()
    Overlord:RequireCaptureSync("instance")
    if Overlord.Combat then Overlord.Combat:Resume() end
    if Overlord.Sync then Overlord.Sync:Resume() end
    -- Un loading survenu avant l'initialisation de Sync conserve le ZR au lieu de
    -- marquer la vague comme relachee sans transport. Le rejouer avant la rotation.
    if Overlord.FlushDeferredCaptureRelease then
        Overlord:FlushDeferredCaptureRelease()
    end
    if Overlord.ManualBountySync and Overlord.ManualBountySync.ResumeContractQueue then
        Overlord.ManualBountySync:ResumeContractQueue()
    end
    -- WoW 12.0.5 : reactive les events ZoneControl (UNIT_AURA, INSPECT_READY)
    if Overlord.ZoneControl and Overlord.ZoneControl.Resume then
        Overlord.ZoneControl:Resume()
    end
    Overlord:CheckActiveFrontZone()
    if Overlord.MapMarkers and Overlord.MapMarkers.CheckOutpostMinimap then
        Overlord.MapMarkers:CheckOutpostMinimap()
    end
    -- Le resume peut etre differe apres PEW pendant que GetInstanceInfo expose encore
    -- "arena"/"pvp". La preuve PEW monde ouvert reste alors posee et autorise ici
    -- la rotation; un ZONE_CHANGED/WAR_MODE anterieur au PEW ne l'autorise jamais.
    if Overlord._loginCaptureReleaseWorldConfirmed == true
        and Overlord.CaptureLease
        and Overlord.CaptureLease.RotateReleasedLocalWaves then
        Overlord.CaptureLease:RotateReleasedLocalWaves()
        if not Overlord._loginCaptureReleaseDeferred then
            Overlord._loginCaptureReleaseWorldConfirmed = nil
        end
    end
    -- Si on est toujours dans un front apres l'instance, relance ce que CheckActiveFrontZone
    -- ne relance pas (wasIn=true, nowIn=true -> pas de transition detectee)
    if Overlord.InActiveFront then
        RestoreFrontVisualSystems(reason or "resumeFromInstance")
        if Overlord.Sync then
            if Overlord.Sync.StartPeriodicChannelSync then Overlord.Sync:StartPeriodicChannelSync() end
            if Overlord.Sync.StartProximityRescan then Overlord.Sync:StartProximityRescan() end
        end
        if Overlord.UI and Overlord.UI.Show
            and OverlordDB and OverlordDB.config and OverlordDB.config.uiVisible then
            Overlord.UI:Show()
        end
    end
    -- Carte monde ouverte pendant suspend : reafficher le OnUpdate masque.
    if WorldMapFrame and WorldMapFrame:IsShown()
        and Overlord.MapMarkers and Overlord.MapMarkers._updateFrame then
        Overlord.MapMarkers._updateFrame:Show()
    end
    if Overlord.Button and Overlord.Button.EnsureCreated then
        Overlord.Button:EnsureCreated()
    end
    SchedulePostInstanceWorldRecovery()
    -- Si le joueur sort en ville, le ticker n'est pas actif -> le relancer ici.
    if StartDominationTicker then StartDominationTicker() end
    Overlord:StartGuildKeepLoop()
    if Overlord._loginFactionChangeDeferred and Overlord.RequestFactionChangeReconcile then
        Overlord:RequestFactionChangeReconcile()
    end
    -- Pousser l'etat carte vers le reseau (l'instance n'envoie pas de ZS a la suspension).
    if Overlord.Sync and Overlord.Sync.FlushStateAfterInstance then
        Overlord._postInstanceFlushGeneration =
            (tonumber(Overlord._postInstanceFlushGeneration) or 0) + 1
        local flushGeneration = Overlord._postInstanceFlushGeneration
        C_Timer.After(1.5, function()
            if not Overlord.InstanceSuspended and Overlord.Sync
                and Overlord._postInstanceFlushGeneration == flushGeneration then
                Overlord.Sync:FlushStateAfterInstance()
            end
        end)
    end
end

local function ScheduleResumeFromInstanceRetries()
    if #resumeInstanceRetryTimers > 0 then return end
    CancelResumeFromInstanceRetryTimers()
    for _, d in ipairs(RESUME_INSTANCE_RETRY_DELAYS) do
        local delay = d
        local t = C_Timer.NewTimer(delay, function()
            if Overlord.InstanceSuspended then
                Overlord:ResumeFromInstance()
            end
        end)
        resumeInstanceRetryTimers[#resumeInstanceRetryTimers + 1] = t
    end
    -- Filet de securite : si les retries echouent mais qu'on est sorti, reprendre
    -- via le meme chemin que la reprise normale.
    local t = C_Timer.NewTimer(5, function()
        if Overlord.InstanceSuspended then
            if not IsInInstance() then
                CompleteResumeFromInstance("resumeFromInstanceForced")
            else
                CancelResumeFromInstanceRetryTimers()
                Overlord:ResumeFromInstance()
            end
        end
    end)
    resumeInstanceRetryTimers[#resumeInstanceRetryTimers + 1] = t
end

-- Suspend total de l'addon en instance (arene, BG, donjon).
-- Deregistre les events et stop les tickers au lieu de checker IsInInstance() partout.
function Overlord:SuspendForInstance()
    -- Si deja suspendu : ne PAS annuler les timers (ResumeFromInstance programme des retry 0.35/0.95/2s).
    -- Un second event (ex. IsInInstance() encore true a la sortie d'arene) appelait Suspend en doublon,
    -- vidait les retry et laissait InstanceSuspended=true sans aucune reprise -> /reload obligatoire.
    if self.InstanceSuspended then
        if not self._deferredModuleInitDone then
            -- Une re-entree peut suivre une sortie observee pendant la meme barriere.
            -- Le dernier etat physique gagne : annuler tout resume deja en attente.
            self._loginSuspendDeferred = true
            self._loginResumeDeferred = nil
        end
        return
    end
    if not self._deferredModuleInitDone then
        -- Les callbacks de suspension liberent/revertissent des captures et peuvent
        -- emettre sur le reseau. Pendant les migrations login, les modules existent
        -- deja mais leurs racines ne sont pas encore publiees : poser la barriere
        -- immediatement et rejouer cette suspension de facon autoritaire au commit.
        self.InstanceSuspended = true
        self._loginSuspendDeferred = true
        self._postInstanceFlushGeneration =
            (tonumber(self._postInstanceFlushGeneration) or 0) + 1
        CancelAllDeferredInstanceTimers()
        CancelRPGroupRetryTicker()
        return false
    end
    -- Invalide le callback Flush differe d'une sortie precedente avant toute
    -- nouvelle suspension/reprise rapide.
    self._postInstanceFlushGeneration =
        (tonumber(self._postInstanceFlushGeneration) or 0) + 1
    CancelAllDeferredInstanceTimers()
    CancelRPGroupRetryTicker()
    -- Revert capture / broadcast AVANT InstanceSuspended (sinon GK bloque l'emission)
    if self.ZoneControl and self.ZoneControl.OnInstanceSuspend then
        self.ZoneControl:OnInstanceSuspend()
    end
    if self.GuildKeepControl and self.GuildKeepControl.OnInstanceSuspend then
        self.GuildKeepControl:OnInstanceSuspend()
    end
    if self.OutpostControl and self.OutpostControl.OnInstanceSuspend then
        self.OutpostControl:OnInstanceSuspend()
    end
    if self.General and self.General.OnInstanceSuspend then
        self.General:OnInstanceSuspend()
    end
    self.InstanceSuspended = true
    -- HUD or : peut s'afficher sur PLAYER_ENTERING_WORLD avant que ce handler finisse - masquage immediat.
    if self.Ressources and self.Ressources.HideGoldHUDForInstance then
        self.Ressources:HideGoldHUDForInstance()
    end
    -- Remet le flag de zone a zero : evite des etats stales si CheckActiveFrontZone n'est pas appele
    self.InActiveFront = false
    catchUpNotified = false
    -- Annule le timer d'entree en front (evite un OnEnterFront differe en instance)
    if pendingFrontEnter then
        pendingFrontEnter:Cancel()
        pendingFrontEnter = nil
    end
    -- WoW 12.0.5 : desactive les events UNIT_AURA qui causent du taint en instance
    if self.ZoneControl and self.ZoneControl.Suspend then
        self.ZoneControl:Suspend()
    end
    self:StopUpdateLoop()
    self:StopGuildKeepLoop()
    if StopDominationTicker then StopDominationTicker() end
    if self.UI then
        if self.UI.StopSpectatorMode then self.UI:StopSpectatorMode() end
        if self.UI.IsVisible and self.UI.Hide and self.UI:IsVisible() then self.UI:Hide(true) end
    end
    if self.MapMarkers then
        self.MapMarkers:SetMinimapPinsVisible(false)
        self.MapMarkers:HideAllOverlays()
        if self.MapMarkers.HideGuildKeepOverlays then self.MapMarkers:HideGuildKeepOverlays() end
        if self.MapMarkers.HideMinimapKeepPin then self.MapMarkers:HideMinimapKeepPin() end
        self.MapMarkers._mmOutpostMapActive = false
        if self.MapMarkers.HideMinimapOutpostPin then self.MapMarkers:HideMinimapOutpostPin() end
        if self.MapMarkers.HideEKKeepPin then self.MapMarkers:HideEKKeepPin() end
    end
    if self.ZoneIndicator then self.ZoneIndicator:Hide() end
    if self.LeaderboardUI then self.LeaderboardUI:Hide() end
    if self.Sync then self.Sync:Suspend() end
    if self.Combat then self.Combat:Suspend() end
    if self.Sync and self.Sync.ClearRecentFrontSenders then
        self.Sync:ClearRecentFrontSenders()
    end
end

function Overlord:ResumeFromInstance()
    if not self.InstanceSuspended then return end
    local okInInstance, physicallyInInstance = pcall(IsInInstance)
    if not okInInstance or physicallyInInstance then return false end
    -- Securite : IsInInstance() peut retourner false brievement pendant un loading en instance.
    -- GetInstanceInfo() est plus fiable : si le type d'instance n'est pas "none", on reste suspendu.
    -- Sans ce check, l'addon se reactive entre deux loading screens puis se re-suspend 1s apres,
    -- ce qui cause des erreurs Lua (events/timers relances en contexte d'instance).
    local ok, _, instType = pcall(GetInstanceInfo)
    if not ok or (instType and instType ~= "none" and instType ~= "") then
        -- Encore en instance selon l'API, ou sortie tout juste : GetInstanceInfo peut
        -- rester "arena" un court instant apres le chargement monde ouvert.
        ScheduleResumeFromInstanceRetries()
        return
    end
    CompleteResumeFromInstance("resumeFromInstance")
end

function Overlord:FlushDeferredInstanceTransition()
    if not self._deferredModuleInitDone then return false end
    local suspendAfterLogin = self._loginSuspendDeferred == true
    self._loginSuspendDeferred = nil
    if suspendAfterLogin then
        -- SuspendForInstance est idempotent sur le flag; le baisser ici ne
        -- publie rien et permet d'executer une fois les callbacks autoritaires
        -- maintenant que toutes les racines requises sont commitees.
        self.InstanceSuspended = false
        self:SuspendForInstance()
    end
    local resumeReason = self._loginResumeDeferred
    self._loginResumeDeferred = nil
    local checkFront = self._loginFrontCheckDeferred
    self._loginFrontCheckDeferred = nil
    if resumeReason then
        -- Revalider l'etat physique au commit. Une re-entree tardive ou une API
        -- transitoire ne doit jamais reactiver les transports dans l'instance.
        self:ResumeFromInstance()
    elseif checkFront then
        self:CheckActiveFrontZone()
    end
    return suspendAfterLogin or resumeReason ~= nil or checkFront == true
end

-- Un /reload peut charger l'addon alors que le joueur est deja en instance et
-- sans nouveau PLAYER_ENTERING_WORLD. Fermer la barriere immediatement; les
-- callbacks modules autoritaires ne tournent qu'apres les stages requis.
function Overlord:PrimeLoginInstanceBarrier(inInstance)
    if not inInstance or self._deferredModuleInitDone then return false end
    self.InstanceSuspended = true
    self._loginSuspendDeferred = true
    self._loginResumeDeferred = nil
    return true
end

function Overlord:ResumeCaptureAfterLoginBarrier()
    if self.InstanceSuspended or IsInInstance() then return false end
    if self.ZoneControl and self.ZoneControl.Resume then
        self.ZoneControl:Resume()
        return true
    end
    return false
end

function Overlord:ScheduleDeferredCaptureReleaseRetry()
    if self._loginCaptureReleaseRetryPending or self.InstanceSuspended
        or not self._deferredModuleInitDone then return end
    self._loginCaptureReleaseRetryPending = true
    local attempt = math.min(tonumber(self._loginCaptureReleaseRetryAttempt) or 0, 3)
    C_Timer.After(2 ^ attempt, function()
        Overlord._loginCaptureReleaseRetryPending = nil
        Overlord:FlushDeferredCaptureRelease()
    end)
end

function Overlord:FlushDeferredCaptureRelease()
    if not self._deferredModuleInitDone or not self._loginCaptureReleaseDeferred then
        return false
    end
    if self.InstanceSuspended then return false end
    local lease = self.CaptureLease
    if not lease or not lease.ReleaseAllLocal then
        self._loginCaptureReleaseDeferred = nil
        self._loginCaptureReleaseSnapshots = nil
        return true
    end
    local snapshots = self._loginCaptureReleaseSnapshots
    local ok, complete = true, true
    if snapshots and #snapshots > 0 and lease.BroadcastReleaseSnapshot then
        local pending = {}
        for i = 1, #snapshots do
            local snapshot = snapshots[i]
            local sentOk, emitted = pcall(lease.BroadcastReleaseSnapshot, lease, snapshot)
            if not sentOk or emitted ~= true then
                pending[#pending + 1] = snapshot
                complete = false
            end
        end
        self._loginCaptureReleaseSnapshots = #pending > 0 and pending or nil
    else
        ok, complete = pcall(lease.ReleaseAllLocal, lease)
    end
    if ok and complete ~= false then
        self._loginCaptureReleaseDeferred = nil
        self._loginCaptureReleaseSnapshots = nil
        self._loginCaptureReleaseRetryAttempt = nil
        self._loginCaptureReleaseRetryPending = nil
        -- Un succes immediat pendant LOADING_SCREEN_ENABLED ne prouve pas encore
        -- la destination. Tourner ici publierait une nouvelle vague juste avant
        -- l'entree en instance, puis la suspension ne pourrait plus emettre son ZR.
        -- Seul un PEW deja confirme hors instance autorise le retry froid a rattraper
        -- la rotation que ce PEW avait tentee avant le succes du transport.
        if self._loginCaptureReleaseWorldConfirmed == true
            and not self.InstanceSuspended and not IsInInstance()
            and lease.RotateReleasedLocalWaves then
            lease:RotateReleasedLocalWaves()
            self._loginCaptureReleaseWorldConfirmed = nil
        end
        return true
    end
    self._loginCaptureReleaseRetryAttempt =
        math.min((tonumber(self._loginCaptureReleaseRetryAttempt) or 0) + 1, 3)
    self:ScheduleDeferredCaptureReleaseRetry()
    return false
end

function Overlord:RunOrDeferCaptureRelease()
    -- Chaque loading ouvre une nouvelle destination inconnue. Un PEW hors instance
    -- devra la confirmer avant toute rotation/republication de vague locale.
    self._loginCaptureReleaseWorldConfirmed = nil
    local lease = self.CaptureLease
    if lease and lease.SnapshotAllLocalReleases then
        local ok, snapshots = pcall(lease.SnapshotAllLocalReleases, lease)
        if ok and type(snapshots) == "table" and #snapshots > 0 then
            local queued = self._loginCaptureReleaseSnapshots or {}
            for i = 1, #snapshots do
                local candidate = snapshots[i]
                local duplicate = false
                for j = 1, #queued do
                    if queued[j].zoneId == candidate.zoneId
                        and queued[j].waveId == candidate.waveId then
                        duplicate = true
                        break
                    end
                end
                if not duplicate then queued[#queued + 1] = candidate end
            end
            self._loginCaptureReleaseSnapshots = queued
        end
    end
    self._loginCaptureReleaseDeferred = true
    if not self._deferredModuleInitDone then return false end
    return self:FlushDeferredCaptureRelease()
end

function Overlord:FinalizeCaptureReleaseAfterWorldEntry(inInstance)
    if inInstance then
        self._loginCaptureReleaseWorldConfirmed = nil
        return false
    end
    -- PLAYER_ENTERING_WORLD a maintenant confirme une destination monde ouvert.
    -- Si le ZR est deja parti, tourner ici. S'il attend encore un transport froid,
    -- conserver la preuve afin que FlushDeferredCaptureRelease tourne au succes.
    self._loginCaptureReleaseWorldConfirmed = true
    if self.InstanceSuspended then return false end
    local lease = self.CaptureLease
    if lease and lease.RotateReleasedLocalWaves then
        lease:RotateReleasedLocalWaves()
    end
    if not self._loginCaptureReleaseDeferred then
        self._loginCaptureReleaseWorldConfirmed = nil
    end
    return true
end

function Overlord:FinishFactionChangeReconcile(state)
    if self._factionChangeReconcileState ~= state then return false end
    self._factionChangeReconcileState = nil
    local currentFaction = UnitFactionGroup("player")
    if state.restartRequested or currentFaction ~= state.faction then
        self._loginFactionChangeDeferred = true
        C_Timer.After(0, function() Overlord:RequestFactionChangeReconcile() end)
        return false
    end

    self._loginFactionChangeDeferred = nil
    if self.Leaderboard and self.Leaderboard.MarkDirty then
        self.Leaderboard:MarkDirty()
    end
    self.WaitingForSync = true
    C_Timer.After(60, function()
        if Overlord.WaitingForSync then Overlord.WaitingForSync = nil end
    end)
    if self.Sync and self.Sync.SendSyncRequest then self.Sync:SendSyncRequest() end
    if self.General and self.General.OnPlayerFactionChanged then
        self.General:OnPlayerFactionChanged()
    end
    if self.ManualBounty and self.ManualBounty.OnPlayerIdentityChanged then
        self.ManualBounty:OnPlayerIdentityChanged()
    end
    if self.Button and self.Button.Refresh then self.Button:Refresh() end
    if self.UI and self.UI.RefreshStatsButton then self.UI:RefreshStatsButton() end
    if self.CharacterStats and self.CharacterStats.Refresh then self.CharacterStats:Refresh() end
    return true
end

function Overlord:RunFactionChangeReconcileSlice(state)
    if self._factionChangeReconcileState ~= state then return false end
    if not self._deferredModuleInitDone or self.InstanceSuspended then
        -- Une tranche peut coincider avec un loading. Les mutations deja appliquees
        -- sont idempotentes; reprendre la reconciliation complete au resume.
        self._factionChangeReconcileState = nil
        self._loginFactionChangeDeferred = true
        return false
    end
    local ok, err = coroutine.resume(state.worker)
    if not ok then
        self._factionChangeReconcileState = nil
        self._loginFactionChangeDeferred = true
        self:PrintNotification("|cFFFF0000[Overlord]|r faction reconcile: " .. tostring(err))
        return false
    end
    if coroutine.status(state.worker) == "dead" then
        return self:FinishFactionChangeReconcile(state)
    end
    C_Timer.After(0, function() Overlord:RunFactionChangeReconcileSlice(state) end)
    return false
end

function Overlord:RequestFactionChangeReconcile()
    if not self._deferredModuleInitDone or self.InstanceSuspended then
        self._loginFactionChangeDeferred = true
        return false
    end
    local faction = UnitFactionGroup("player")
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    local pending = self._factionChangeReconcileState
    if pending then
        if pending.faction ~= faction then pending.restartRequested = true end
        return false
    end

    self._loginFactionChangeDeferred = nil
    self.PlayerFaction = faction
    if self.Zones then
        self.Zones:ApplyFactionConfig(faction)
        -- ApplyFactionConfig remet les owners non-bases a nil; restaurer la carte
        -- une fois apres le commit login, avant de publier la nouvelle identite.
        self:RestoreZoneState()
    end

    local leaderboard = self.Leaderboard
    local state = { faction = faction }
    state.worker = coroutine.create(function()
        if not leaderboard then return end
        if leaderboard.ForceUpdateLocalPlayer then
            local fullName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
                and Overlord.Sync:GetPlayerFullName() or ""
            local _, myClass = UnitClass("player")
            if fullName ~= "" then
                leaderboard:ForceUpdateLocalPlayer(fullName, myClass, faction)
            end
        end
        if leaderboard.PropagateLocalFactionToAllKeys then
            local work, startedAt = 0, debugprofilestop()
            leaderboard:PropagateLocalFactionToAllKeys(function()
                work = work + 1
                local nowMs = debugprofilestop()
                if work >= 64 or nowMs - startedAt >= 1.25 then
                    work, startedAt = 0, nowMs
                    -- Les setters de cette coroutine peuvent eux-memes avancer la
                    -- revision. Seule une variation PENDANT le yield prouve une
                    -- mutation concurrente d'une cle deja parcourue; rejouer alors
                    -- toute la passe avant le moindre SR/UI.
                    local yieldedRevision = leaderboard._localFactionAliasRevision or 0
                    coroutine.yield()
                    if (leaderboard._localFactionAliasRevision or 0) ~= yieldedRevision then
                        state.restartRequested = true
                    end
                end
            end)
        end
    end)
    self._factionChangeReconcileState = state
    return self:RunFactionChangeReconcileSlice(state)
end

-- Frame principal pour gérer les events
local eventFrame = CreateFrame("Frame")

-- BETA Forever : une seule campagne americaine pour tous les comptes/langues.
-- Ne pas utiliser le reset regional du client pendant cette beta.
-- wday: 1=Dimanche, 2=Lundi, 3=Mardi, 4=Mercredi, ..., 7=Samedi
local RESET_HOUR_US = 8
local RESET_WDAY_US = 3  -- Mardi
local SECONDS_PER_DAY = 86400
local SECONDS_PER_WEEK = SECONDS_PER_DAY * 7
-- Regression 8.0.6 : jitter ±1 s sur GetLastResetTimestamp (NA) ne doit jamais
-- declencher un faux reset hebdo ni un faux bucket perime.
-- L'API Blizzard et le repli calendrier peuvent designer le meme reset NA avec
-- plusieurs heures d'ecart (API indisponible pendant maintenance, puis retour de
-- l'epoch officiel). Deux vrais resets restent espaces de sept jours.
local CAMPAIGN_EPOCH_TOLERANCE_SEC = 36 * 3600
local REGIONAL_RESET_CACHE_SEC = 3600
local LEGACY_US_MIN_GAP_SEC = 3600
local WEEKLY_RESET_REENTRY_GUARD_SEC = 6 * SECONDS_PER_DAY
local cachedRegionalResetTs = nil
local cachedRegionalResetWallAt = 0
local lastEnsureCampaignFreshAt = 0
local ENSURE_CAMPAIGN_FRESH_INTERVAL = 60

local function GetLastCompletedWeeklyResetAt()
    if not OverlordDB then return 0 end
    return math.max(
        tonumber(OverlordDB.lastWeeklyMapResetAt) or 0,
        tonumber(OverlordDB.lastLeaderboardResetAt) or 0)
end

local function HasRecentCompletedWeeklyReset(candidateEpoch)
    local completedAt = GetLastCompletedWeeklyResetAt()
    if completedAt <= 0 then return false end
    local now = (GetServerTime and GetServerTime()) or time()
    local age = now - completedAt
    if age < 0 or age >= WEEKLY_RESET_REENTRY_GUARD_SEC then return false end

    -- Le delai seul ne suffit pas : un joueur qui applique tardivement le reset
    -- precedent (ex. dimanche) doit quand meme appliquer la nouvelle campagne le
    -- mercredi suivant. Le garde ne bloque donc que deux epochs representant la
    -- meme frontiere hebdomadaire (repli calendrier puis correction de l'API).
    local appliedEpoch = tonumber(OverlordDB.lastWeeklyMapResetEpoch) or 0
    if appliedEpoch <= 0 then
        appliedEpoch = tonumber(OverlordDB.lastResetTimestamp) or 0
    end
    candidateEpoch = tonumber(candidateEpoch) or 0
    if appliedEpoch <= 0 or candidateEpoch <= 0 then return true end
    return math.abs(candidateEpoch - appliedEpoch) <= CAMPAIGN_EPOCH_TOLERANCE_SEC
end

local function MarkWeeklyMapResetCompleted(resetEpoch)
    if not OverlordDB then return end
    OverlordDB.lastWeeklyMapResetAt = (GetServerTime and GetServerTime()) or time()
    OverlordDB.lastWeeklyMapResetEpoch = math.floor(tonumber(resetEpoch) or 0)
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

local function GetWeeklyResetTimestampForRule(resetWday, resetHour, now)
    -- UTC obligatoire (date("!*t", ...) + arithmetique d'epoch, sans time({...}) qui
    -- interpreterait la table en heure LOCALE). Ce repli sert quand l'API
    -- C_DateAndTime.GetSecondsUntilWeeklyReset est indisponible. En heure locale, deux clients
    -- d'une meme region mais de fuseaux differents (region 1 : US continental -> Oceanique)
    -- calculaient des timestamps de reset REELLEMENT differents -> sync (DM/LK/...) qui diverge
    -- independamment du campaignId. En UTC, tous les clients d'une region obtiennent la meme
    -- valeur pour un meme `now`. resetHour est donc interprete en heure UTC : l'instant exact peut
    -- etre decale du fuseau serveur, mais reste sur le bon JOUR UTC (donc bon campaignId) et,
    -- surtout, identique pour tout le monde.
    local t = date("!*t", now)
    local secsToday = (tonumber(t.hour) or 0) * 3600
        + (tonumber(t.min) or 0) * 60
        + (tonumber(t.sec) or 0)
    -- Epoch de minuit UTC du jour courant, puis l'heure de reset visee, en UTC.
    local resetToday = (now - secsToday) + resetHour * 3600
    -- Jours depuis le dernier jour de reset (0 = jour J, 1 = lendemain, ...)
    local daysSinceReset = ((tonumber(t.wday) or 1) - resetWday + 7) % 7
    -- Si on est le bon jour mais avant l'heure : le reset de la semaine precedente etait il y a 7 jours
    if daysSinceReset == 0 and now < resetToday then
        daysSinceReset = 7
    end
    return resetToday - (daysSinceReset * SECONDS_PER_DAY)
end

local function GetFallbackWeeklyResetRule()
    -- Forever beta is a global population. Use one deterministic US campaign
    -- boundary even when a client is logged in through an EU account endpoint.
    return RESET_WDAY_US, RESET_HOUR_US
end

local function IsLegacyUSResetAhead(dbReset, regionalReset)
    dbReset = math.floor(tonumber(dbReset) or 0)
    regionalReset = math.floor(tonumber(regionalReset) or 0)
    if dbReset <= 0 or regionalReset <= 0 or dbReset <= regionalReset then return false end
    -- Jitter d'une seconde (8.0.6) : ne pas ramener lastResetTimestamp en arriere.
    if (dbReset - regionalReset) < LEGACY_US_MIN_GAP_SEC then return false end
    -- Ancien bug : les royaumes US pouvaient etre estampilles sur mercredi 3h.
    return (dbReset - regionalReset) <= (2 * SECONDS_PER_DAY)
end

-- Deux epochs de campagne designent la meme semaine (tolerance jitter calendrier).
function Overlord:CampaignEpochsMatch(a, b, toleranceSec)
    toleranceSec = tonumber(toleranceSec) or CAMPAIGN_EPOCH_TOLERANCE_SEC
    a = math.floor(tonumber(a) or 0)
    b = math.floor(tonumber(b) or 0)
    if a <= 0 or b <= 0 then return a == b end
    return math.abs(a - b) <= toleranceSec
end

function Overlord:IsLegacyUSResetAhead(dbReset, regionalReset)
    return IsLegacyUSResetAhead(dbReset, regionalReset)
end

-- Epoch diffuse sur le reseau = debut de campagne OFFICIEL (reset Blizzard), identique pour toute
-- la region. On ne diffuse plus l'ancien epoch "mercredi legacy" : tous les clients a jour emettent
-- le meme instant, et la reception compare par fenetre hebdomadaire (IsCurrentSyncCampaignEpoch).
function Overlord:GetCurrentCampaignWireEpoch()
    return self:GetCurrentCampaignStartTs()
end

-- Calcule le timestamp du dernier reset hebdomadaire reel de la region.
function Overlord:GetLastResetTimestamp()
    local now = (GetServerTime and GetServerTime()) or time()
    local resetWday, resetHour = GetFallbackWeeklyResetRule()
    local computed = GetWeeklyResetTimestampForRule(resetWday, resetHour, now)
    -- Stabilise la session : GetServerTime et untilReset ne tickent pas a la meme seconde (NA).
    if cachedRegionalResetTs and (now - cachedRegionalResetWallAt) < REGIONAL_RESET_CACHE_SEC then
        if math.abs(computed - cachedRegionalResetTs) < REGIONAL_RESET_CACHE_SEC then
            return cachedRegionalResetTs
        end
    end
    cachedRegionalResetTs = computed
    cachedRegionalResetWallAt = now
    return computed
end

-- Retourne les dates de debut et fin de la campagne en cours formatees.
function Overlord:GetCampaignDateRange()
    local startTs = self:GetCurrentCampaignStartTs()
    local endTs = startTs + SECONDS_PER_WEEK
    return date(L.DATE_FORMAT, startTs), date(L.DATE_FORMAT, endTs)
end

-- Identifiant campagne (export Check PvP, snapshots) : AAAAMMJJ du reset regional qui ouvre la periode,
-- pas un compteur de sessions (evite "Campagne #6" trompeur vs le calendrier reel).
function Overlord:TimestampToCampaignId(startTs)
    if not startTs or startTs <= 0 then return 0 end
    -- UTC obligatoire (date("!*t", ...)) : la region 1 (US) couvre du continental a l'Oceanique
    -- (jusqu'a ~18 h d'ecart). En date LOCALE, un meme timestamp de reset tombait sur des jours
    -- calendaires differents (ex. mardi cote US continental, mercredi cote Oceanique) -> campaignId
    -- divergents -> les messages domination (DM) etaient rejetes entre clients NA -> barre figee a
    -- 50/50. En UTC le campaignId est identique pour tous, quel que soit le fuseau. Sans effet sur
    -- EU (reset mercredi 03:00 : meme jour en UTC et en local) ni sur la validite des leaderboards
    -- (keyee sur le timestamp campaignStart, pas sur ce campaignId).
    local t = date("!*t", startTs)
    return (t.year * 10000) + (t.month * 100) + t.day
end

-- Timestamp unix de debut de la campagne en cours (aligne sur Leaderboard:GetCurrentCampaignStart).
function Overlord:GetCurrentCampaignStartTs()
    -- Une ancienne sauvegarde EU (ou une date future) ne choisit jamais la
    -- campagne active. La compatibilite des anciens stamps reste dans le lecteur.
    return self:GetLastResetTimestamp() or 0
end

-- Met a jour OverlordDB.campaignId selon la semaine courante (login, apres reset hebdo, correctif saves anciennes).
function Overlord:SyncCampaignIdWithCurrentWeek()
    if not OverlordDB then return end
    OverlordDB.campaignId = self:TimestampToCampaignId(self:GetCurrentCampaignStartTs())
end

-- Verifie si un reset hebdomadaire est necessaire et l'execute
function Overlord:CheckWeeklyReset()
    if self._deferredModuleInitStarted and not self._deferredModuleInitDone
        and not self._loginWeeklyResetStageActive then
        self._loginWeeklyResetDeferred = true
        return false
    end
    -- L'union EU lit les anciens buckets en tranches. Tous les chemins de reset
    -- (stage login, timer regional, freshness) doivent attendre son commit; le
    -- scheduler se rearme de lui-meme une seconde plus tard a la frontiere.
    if self._europeanLeaderboardUnionPending then return false end
    local lastReset = self:GetLastResetTimestamp()
    local lastCampaign = tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0

    -- Reset interrompu : le nouveau bucket a deja pu etre ouvert alors que
    -- l'archive compacte ou les side-effects fixes n'etaient pas termines.
    local pending = tonumber(OverlordDB and OverlordDB.pendingWeeklyResetAt) or 0
    if pending > 0 and pending ~= lastReset then
        -- Ancien reset regional interrompu : ne jamais le rejouer en beta US.
        -- Si son bucket a deja ete detache, finir uniquement l'archive sauvegardee.
        OverlordDB.pendingWeeklyResetAt = nil
        local marker = OverlordDB.pendingWeeklyArchive
        if type(marker) == "table" then
            marker.coreSideEffectsApplied = true
            marker.leaderboardSideEffectsApplied = true
            if self.Leaderboard and self.Leaderboard.ResumePendingWeeklyArchive then
                self.Leaderboard:ResumePendingWeeklyArchive()
            end
        end
        pending = 0
    end
    if pending > 0 then
        if self.Leaderboard then
            OverlordDB.lastResetTimestamp = pending
            self:SyncCampaignIdWithCurrentWeek()
            local campaignId = tonumber(OverlordDB.campaignId) or 0
            local archiveEpoch = pending - SECONDS_PER_WEEK
            if archiveEpoch <= 0 then archiveEpoch = pending end
            self.Leaderboard:Reset(archiveEpoch, pending, campaignId)
            local marker = OverlordDB.pendingWeeklyArchive
            if type(marker) == "table"
                and tonumber(marker.resetEpoch) == pending
                and marker.coreSideEffectsApplied ~= true then
                -- Tables de taille fixe : meme frame logique que le swap leaderboard.
                self:ResetAll()
                MarkWeeklyMapResetCompleted(pending)
                self.Leaderboard:MarkWeeklyResetCoreSideEffectsApplied(pending)
                self:PrintNotification("|cFFFFD100[Overlord]|r " .. L.WEEKLY_RESET)
            end
            self.Leaderboard:ResumePendingWeeklyArchive()
        end
        self:SyncCampaignIdWithCurrentWeek()
        return
    end

    -- Marqueur leaderboardResetEpoch en retard vs lastResetTimestamp alors que la DB est deja
    -- sur la semaine calendaire courante : resynchroniser sans reset global. Un vrai reset hebdo
    -- passe par pendingWeeklyResetAt (crash) ou lastCampaign < lastReset (frontiere Blizzard).
    -- Regression 7.6.42 : ce chemin declenchait ResetAll() en plein milieu de semaine.
    local resetEpoch = tonumber(OverlordDB and OverlordDB.leaderboardResetEpoch) or 0
    if resetEpoch > 0 and lastCampaign > 0 and resetEpoch < lastCampaign
        and lastReset > 0 and lastCampaign >= lastReset then
        if self.Leaderboard and self.Leaderboard.StampCurrentCampaignBucket then
            self.Leaderboard:StampCurrentCampaignBucket(OverlordDB.leaderboard)
        else
            OverlordDB.leaderboardResetEpoch = lastCampaign
        end
    end

    if IsLegacyUSResetAhead(lastCampaign, lastReset) then
        OverlordDB.lastResetTimestamp = lastReset
        self:SyncCampaignIdWithCurrentWeek()
        local campaignId = tonumber(OverlordDB.campaignId) or 0
        if self.Leaderboard and self.Leaderboard.StampCurrentCampaignBucket then
            self.Leaderboard:StampCurrentCampaignBucket(OverlordDB.leaderboard)
        elseif OverlordDB.leaderboard then
            OverlordDB.leaderboard.campaignStart = lastReset
            OverlordDB.leaderboard.campaignId = campaignId
        end
        local currentPool = Overlord:GetCurrentLeaderboardSavedVarsPool() or ""
        local poolBucket = OverlordDB.leaderboardsByPool and OverlordDB.leaderboardsByPool[currentPool]
        if poolBucket then
            poolBucket.campaignStart = lastReset
            poolBucket.campaignId = campaignId
        end
    -- Tolerance jitter (8.0.6) uniquement entre deux epochs valides : une DB vierge
    -- (lastCampaign = 0) doit toujours recevoir son premier estampillage de semaine.
    elseif lastCampaign > 0 and lastCampaign < lastReset
        and HasRecentCompletedWeeklyReset(lastReset) then
        -- Invariant anti-boucle : un ResetAll hebdomadaire termine ne peut pas etre
        -- rejoue pour la meme frontiere moins de six jours plus tard. Une frontiere
        -- distante de sept jours reste toujours eligible, meme si le joueur a
        -- applique tardivement le reset precedent. Le cas re-entry reel est NA : le
        -- repli calendrier a deja reset, puis l'API Blizzard revient avec un epoch
        -- plus tardif le meme mardi. Conserver l'ancre deja appliquee protege aussi
        -- les captures faites entre les deux lectures.
        self:SyncCampaignIdWithCurrentWeek()
    elseif lastCampaign < lastReset
        and (lastCampaign <= 0 or (lastReset - lastCampaign) > CAMPAIGN_EPOCH_TOLERANCE_SEC) then
        OverlordDB.pendingWeeklyResetAt = lastReset
        OverlordDB.lastResetTimestamp = lastReset
        self:SyncCampaignIdWithCurrentWeek()
        local campaignId = tonumber(OverlordDB.campaignId) or 0
        local archiveEpoch = lastCampaign
        if archiveEpoch <= 0 and lastReset > 0 then
            archiveEpoch = lastReset - SECONDS_PER_WEEK
        end
        if self.Leaderboard then
            -- OpenAtomicWeeklyBucket detache l'ancien bucket en O(1). ResetAll
            -- suit immediatement, avant tout retour a la boucle d'evenements.
            self.Leaderboard:Reset(archiveEpoch, lastReset, campaignId)
            local marker = OverlordDB.pendingWeeklyArchive
            if type(marker) == "table"
                and tonumber(marker.resetEpoch) == lastReset
                and marker.coreSideEffectsApplied ~= true then
                self:ResetAll()
                MarkWeeklyMapResetCompleted(lastReset)
                self.Leaderboard:MarkWeeklyResetCoreSideEffectsApplied(lastReset)
                self:PrintNotification("|cFFFFD100[Overlord]|r " .. L.WEEKLY_RESET)
            end
        end
    end
    self:SyncCampaignIdWithCurrentWeek()
end

-- Filet de secours : verifie que le bucket leaderboard local est bien celui de la campagne
-- en cours, sinon force le reset immediatement. Sert de rattrapage si ScheduleNextReset a
-- manque son declenchement (timer non tenu, session ininterrompue depuis longtemps, etc.) :
-- sans ca, un joueur reste bloque sur son ancien total toute la semaine et le rediffuse des
-- son prochain kill/capture, ce qui repollue le classement des autres joueurs deja resets.
function Overlord:EnsureLeaderboardCampaignFresh()
    local now = GetTime()
    if (now - lastEnsureCampaignFreshAt) < ENSURE_CAMPAIGN_FRESH_INTERVAL then return end
    lastEnsureCampaignFreshAt = now
    if self.Leaderboard and self.Leaderboard.IsCurrentCampaignBucket
        and not self.Leaderboard:IsCurrentCampaignBucket() then
        local ok, err = pcall(Overlord.CheckWeeklyReset, self)
        if not ok and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
            print("|cFFFF4444[Overlord:dbg]|r EnsureLeaderboardCampaignFresh: " .. tostring(err))
        end
    end
end

-- Planifie le prochain reset automatique regional. Le rearmement (ligne "Overlord:ScheduleNextReset()"
-- plus bas) doit rester INCONDITIONNEL : une exception dans CheckWeeklyReset ne doit jamais desarmer
-- definitivement ce timer pour le reste de la session (sinon plus aucun reset auto tant que le
-- joueur ne /reload pas), d'ou le pcall qui isole l'appel sans jamais court-circuiter le rearmement.
function Overlord:ScheduleNextReset()
    local now = (GetServerTime and GetServerTime()) or time()
    local nextReset = self:GetLastResetTimestamp() + SECONDS_PER_WEEK
    local delay = nextReset - now

    if delay <= 0 then delay = 1 end

    C_Timer.After(delay, function()
        if Overlord.IsInitialized then
            local ok, err = pcall(Overlord.CheckWeeklyReset, Overlord)
            if not ok and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
                print("|cFFFF4444[Overlord:dbg]|r CheckWeeklyReset: " .. tostring(err))
            end
            if not Overlord._loginWeeklyResetDeferred then
                Overlord:ScheduleNextReset()
            else
                Overlord._loginWeeklyResetTimerStopped = true
            end
        end
    end)
end

-- Migration legacy Gilneas : un ladder ancien peut contenir des dizaines de
-- milliers de joueurs et de zones. Le scan est une barriere login budgetee ; le
-- marker n'est publie qu'apres la derniere tranche, donc un /reload au milieu
-- rejoue idempotemment les remplacements deja appliques.
function Overlord:EnsureGilneasZoneRenamePrepared()
    if not OverlordDB then return "blocked" end
    if OverlordDB.gilneasZoneRename2026 then return true end
    if self._gilneasZoneRenameFailed then return "blocked" end
    if self._gilneasZoneRenamePending then return false end
    if not C_Timer or not C_Timer.After then return "blocked" end

    local zonesTbl = OverlordDB.zones
    if type(zonesTbl) == "table" then
        local function MoveZoneKey(oldId, newId)
            if zonesTbl[oldId] and not zonesTbl[newId] then
                zonesTbl[newId] = zonesTbl[oldId]
            end
            zonesTbl[oldId] = nil
        end
        MoveZoneKey("gilneas_gatewood", "gilneas_lighthouse")
        MoveZoneKey("gilneas_cursed_isle", "gilneas_hayward_fisheries")
    end

    self._gilneasZoneRenamePending = true
    local generation = (tonumber(self._gilneasZoneRenameGeneration) or 0) + 1
    self._gilneasZoneRenameGeneration = generation
    local processed = 0
    local started = debugprofilestop and debugprofilestop() or 0
    local worker = coroutine.create(function()
        local function YieldWork()
            processed = processed + 1
            local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
            if processed >= 64 or elapsed >= 1.25 then
                processed = 0
                coroutine.yield()
                started = debugprofilestop and debugprofilestop() or 0
            end
        end
        local captureSources, seenSources = {}, {}
        local function AddBucket(lb)
            local captures = type(lb) == "table" and lb.captures or nil
            if type(captures) == "table" and not seenSources[captures] then
                seenSources[captures] = true
                captureSources[#captureSources + 1] = captures
            end
        end
        AddBucket(OverlordDB.leaderboard)
        for _, lb in pairs(OverlordDB.leaderboardsByPool or {}) do
            YieldWork()
            AddBucket(lb)
        end
        for sourceIndex = 1, #captureSources do
            for _, zlist in pairs(captureSources[sourceIndex]) do
                YieldWork()
                if type(zlist) == "table" then
                    for i = 1, #zlist do
                        local zid = zlist[i]
                        if zid == "gilneas_gatewood" then
                            zlist[i] = "gilneas_lighthouse"
                        elseif zid == "gilneas_cursed_isle" then
                            zlist[i] = "gilneas_hayward_fisheries"
                        end
                        YieldWork()
                    end
                end
            end
        end
    end)

    local ResumeWorker
    ResumeWorker = function()
        if self._gilneasZoneRenameGeneration ~= generation
            or not self._gilneasZoneRenamePending then return end
        local ok, err = coroutine.resume(worker)
        if not ok then
            self._gilneasZoneRenamePending = false
            self._gilneasZoneRenameFailed = true
            self:PrintNotification("|cFFFF0000[Overlord]|r Gilneas migration failed; /reload required: "
                .. tostring(err))
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        OverlordDB.gilneasZoneRename2026 = true
        self._gilneasZoneRenamePending = false
        self._gilneasZoneRenameFailed = nil
    end
    C_Timer.After(0, ResumeWorker)
    return false
end

-- Les timers PLAYER_LOGIN restent actifs pendant les migrations longues, mais ne
-- doivent ni afficher une vue partielle ni abandonner leur unique tentative. Chaque
-- type de popup devient donc une intention booleenne, rejouee apres le commit global.
function Overlord:RunOrDeferLoginPopup(kind)
    local daily = kind == "daily"
    if not self._deferredModuleInitDone then
        if daily then
            self._loginDailyPopupDeferred = true
        else
            self._loginPopupDeferred = true
        end
        return false
    end
    if self.InstanceSuspended or not self.Popups then return false end
    if daily then
        if self.Popups.TryShowDailyOnLogin then
            self.Popups:TryShowDailyOnLogin(0)
            return true
        end
    elseif self.Popups.TryShowOnLogin then
        self.Popups:TryShowOnLogin(0)
        return true
    end
    return false
end

-- Publication unique des intents accumules pendant une barriere login. Les flags
-- sont effaces avant les callbacks pour rendre un rappel/reload idempotent.
function Overlord:FlushDeferredLoginIntents()
    if not self._deferredModuleInitDone then return false end
    local consultFront = self._loginConsultFrontDeferred
    local showLoginPopup = self._loginPopupDeferred == true
    local showDailyPopup = self._loginDailyPopupDeferred == true
    self._loginConsultFrontDeferred = nil
    self._loginPopupDeferred = nil
    self._loginDailyPopupDeferred = nil
    if consultFront and self.Sync and self.Sync.RequestConsultFrontSync then
        self.Sync:RequestConsultFrontSync(consultFront)
    end
    if showLoginPopup then self:RunOrDeferLoginPopup("login") end
    if showDailyPopup then self:RunOrDeferLoginPopup("daily") end
    return true
end

-- Le timer PLAYER_LOGIN et l'etape UI differee peuvent se croiser dans les deux
-- ordres. Une seule peinture complete doit gagner : si le timer arrive avant la
-- creation de mainFrame, il libere la place pour que l'etape UI la reprogramme.
function Overlord:ScheduleLoginUiFullRefresh(delay)
    local state = self._loginUiRefreshState
    if not state then
        state = { generation = 0 }
        self._loginUiRefreshState = state
    end
    if state.done or state.pending then return end
    state.pending = true
    state.generation = state.generation + 1
    local generation = state.generation
    C_Timer.After(delay or 0, function()
        if generation ~= state.generation then return end
        state.pending = false
        if Overlord.InstanceSuspended then return end
        local ui = Overlord.UI
        if not ui or not ui.IsVisible or not ui:IsVisible() then return end
        state.done = true
        ui:Refresh()
    end)
end

-- Diagnostic de session : une barriere requise peut empecher la creation du
-- panneau. Les commandes et le bouton minimap doivent alors expliquer l'attente.
function Overlord:PrintLoginInitStatus()
    local stage = self._loginInitStage or "startup"
    local state = self._loginInitState or "pending"
    local french = self.IsFrenchLocale and self.IsFrenchLocale()
    local label = french and "Initialisation" or "Initialization"
    local message = "|cFFFFD100[Overlord]|r " .. label .. ": " .. stage .. " (" .. state .. ")"
    if self._loginInitError then message = message .. ": " .. self._loginInitError end
    -- Toujours visible dans le chat general, meme si les notifications sont
    -- dirigees vers un autre onglet ou que le gestionnaire d'erreurs est indisponible.
    print(message)
end

-- Initialisation de l'addon
function Overlord:Initialize()
    if self.IsInitialized then return end
    -- Session-only evidence captured before defaults/migrations/reset stages.
    self.SavedVariablesLoadedAtLogin = type(OverlordDB) == "table"
    self.SavedVariablesCampaignAtLogin = type(OverlordDB) == "table"
        and tonumber(OverlordDB.lastResetTimestamp) or nil
    
    -- ADDON_LOADED follows SavedVariables loading. Waiting cannot repair a client-side load failure.
    if not OverlordDB then
        local campaignStart = self:GetLastResetTimestamp()
        OverlordDB = {
            zones = {},
            config = {},
            history = {},
            leaderboard = { kills = {}, captures = {}, playerInfo = {} },
            -- Une sauvegarde non chargee n'est pas une nouvelle semaine. Ancrer
            -- la session avant le rattrapage reseau evite d'effacer ses scores
            -- et captures avec un faux ResetAll au stage hebdomadaire du login.
            lastResetTimestamp = campaignStart,
            campaignId = self:TimestampToCampaignId(campaignStart),
        }
    end

    -- Migration : assure que chaque sous-table et champ existe
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.leaderboard = OverlordDB.leaderboard or EmptyLeaderboardBucket()
    OverlordDB.leaderboardsByPool = OverlordDB.leaderboardsByPool or {}
    OverlordDB.history = OverlordDB.history or {}
    OverlordDB.lastResetTimestamp = tonumber(OverlordDB.lastResetTimestamp) or 0
    OverlordDB.dominationTime = OverlordDB.dominationTime or { Alliance = 0, Horde = 0 }
    -- Forever beta uses one global domination bucket.
    local currentDominationPool = GetCurrentPoolForSavedVars()
    local legacyFrontDominationTime = OverlordDB.frontDominationTime
    local legacyDominationOwnerPool = currentDominationPool
    OverlordDB.frontDominationTimeByPool = OverlordDB.frontDominationTimeByPool or {}
    if (tonumber(OverlordDB.frontDominationPoolVersion) or 0) < 1 then
        local previousPool = Overlord.RealmPools:NormalizeRegionPool(OverlordDB.lastSessionPool)
        local legacyOwnerPool = previousPool ~= "" and previousPool or currentDominationPool
        legacyDominationOwnerPool = legacyOwnerPool
        if type(OverlordDB.frontDominationTimeByPool[legacyOwnerPool]) ~= "table" then
            OverlordDB.frontDominationTimeByPool[legacyOwnerPool] =
                type(legacyFrontDominationTime) == "table" and legacyFrontDominationTime or {}
        end
        OverlordDB.frontDominationPoolVersion = 1
    end
    -- 1.0.3 briefly split Forever into US/EU. Merge every current legacy bucket
    -- by monotonic maxima, then remove aliases only after the global table exists.
    if (tonumber(OverlordDB.globalDominationUnifiedVersion) or 0) < 1 then
        local global = OverlordDB.frontDominationTimeByPool.global or {}
        for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
            local source = OverlordDB.frontDominationTimeByPool[oldPool]
            if type(source) == "table" then
                for frontId, sourceRow in pairs(source) do
                    if type(sourceRow) == "table" then
                        local targetRow = global[frontId]
                        if type(targetRow) ~= "table" then
                            global[frontId] = sourceRow
                        elseif targetRow ~= sourceRow then
                            for key, value in pairs(sourceRow) do
                                if type(value) == "number" then
                                    targetRow[key] = math.max(tonumber(targetRow[key]) or 0, value)
                                elseif targetRow[key] == nil then
                                    targetRow[key] = value
                                end
                            end
                        end
                    end
                end
            end
        end
        OverlordDB.frontDominationTimeByPool.global = global
        for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
            OverlordDB.frontDominationTimeByPool[oldPool] = nil
        end
        OverlordDB.globalDominationUnifiedVersion = 1
    end
    if type(OverlordDB.frontDominationTimeByPool[currentDominationPool]) ~= "table" then
        OverlordDB.frontDominationTimeByPool[currentDominationPool] = {}
    end
    OverlordDB.frontDominationTime =
        OverlordDB.frontDominationTimeByPool[currentDominationPool]
    if not OverlordDB.frontDominationMigrated and Overlord.Fronts then
        local activeFrontId = Overlord.Fronts.activeFrontId
        local oldDom = OverlordDB.dominationTime
        if activeFrontId and oldDom and ((oldDom.Alliance or 0) > 0 or (oldDom.Horde or 0) > 0) then
            local legacyBuckets = OverlordDB.frontDominationTimeByPool[legacyDominationOwnerPool]
            if type(legacyBuckets) ~= "table" then
                legacyBuckets = {}
                OverlordDB.frontDominationTimeByPool[legacyDominationOwnerPool] = legacyBuckets
            end
            legacyBuckets[activeFrontId] = {
                Alliance = oldDom.Alliance or 0,
                Horde = oldDom.Horde or 0,
            }
        end
        OverlordDB.frontDominationMigrated = true
    end
    -- Recalcul APRES la migration agregat -> front. L'ancien ordre remettait
    -- dominationTime a zero avant d'avoir pu copier un tres vieux profil.
    if self.RecalculateDominationTotals then
        self:RecalculateDominationTotals()
    end
    local dominationSyncVersion = tonumber(OverlordDB.dominationSyncVersion) or 0
    -- Migration domination : les buckets crees avant le tick mono-front peuvent etre gonfles.
    -- On garde leurs valeurs, mais on autorise une baisse controlee par DM verifie une seule fois.
    if dominationSyncVersion < 2 then
        for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
            if type(bucket) == "table" then
                bucket.scoreSeq = 0
                bucket.scoreSource = ""
                bucket.allowLowerDominationSnapshot = true
                bucket.dominationMergeVersion = 2
            end
        end
        OverlordDB.dominationSyncVersion = 2
        dominationSyncVersion = 2
    end
    -- Migration 6.5.19 : la 6.5.18 pouvait empiler plusieurs ticks locaux dans le
    -- meme creneau apres reception d'un DM. Reouvrir une correction basse verifiee.
    if dominationSyncVersion < 3 then
        for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
            if type(bucket) == "table" then
                bucket.scoreSeq = 0
                bucket.scoreSource = ""
                bucket.allowLowerDominationSnapshot = true
                bucket.dominationMergeVersion = 3
            end
        end
        OverlordDB.dominationSyncVersion = 3
        dominationSyncVersion = 3
    end
    -- Migration 6.5.23 : autoriser une correction basse verifiee apres le correctif accumulateur unique.
    if dominationSyncVersion < 4 then
        for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
            if type(bucket) == "table" then
                bucket.allowLowerDominationSnapshot = true
                bucket.dominationMergeVersion = 4
            end
        end
        OverlordDB.dominationSyncVersion = 4
        dominationSyncVersion = 4
    end
    -- Migration 7.0.14 : les clients deja gonfles doivent pouvoir accepter une
    -- derniere baisse verifiee, mais les futures baisses seront refusees par defaut.
    if dominationSyncVersion < 5 then
        for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
            if type(bucket) == "table" then
                bucket.allowLowerDominationSnapshot = true
                bucket.dominationMergeVersion = 5
            end
        end
        OverlordDB.dominationSyncVersion = 5
        dominationSyncVersion = 5
    end
    -- Migration 7.0.15 : les baisses DX ne sont pas suffisamment fiables sans
    -- autorite centrale. On ferme explicitement toute fenetre allowLower restante.
    if dominationSyncVersion < 6 then
        for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
            if type(bucket) == "table" then
                bucket.allowLowerDominationSnapshot = nil
                bucket.dominationMergeVersion = 6
            end
        end
        OverlordDB.dominationSyncVersion = 6
        dominationSyncVersion = 6
    end
    -- Migration 7.1.13 : les overlays dominationBoostPct (WB/DM) pouvaient gonfler sans plafond
    -- et ecraser la barre (ratio + boostA - boostH plafonne a 100/0). Source de verite = secondes.
    if dominationSyncVersion < 7 then
        OverlordDB.dominationBoostPct = { Alliance = 0, Horde = 0 }
        OverlordDB.dominationSyncVersion = 7
        dominationSyncVersion = 7
    end
    -- Migration 8 (bug US signale par Croquette) : purge des buckets domination corrompus. Une
    -- valeur ecretee au cap 2^31-1 (ou un timestamp ayant fuite) rendait Alliance == Horde -> barre
    -- figee a 50/50 cote US, et le CRDT max() interdisait toute correction. On remet ces buckets a
    -- zero pour que le pool guerisse, et la reception DM rejette desormais ces valeurs aberrantes.
    if dominationSyncVersion < 8 then
        if Overlord.SanitizeCorruptDominationBuckets then
            Overlord:SanitizeCorruptDominationBuckets()
        end
        OverlordDB.dominationSyncVersion = 8
        dominationSyncVersion = 8
    end
    -- Migration 9 (bug d'amplification du bonus, signale par Nemy) : l'ancienne formule du bonus
    -- bois/victoire divisait par (1 - pct) et gonflait les buckets a des CENTAINES de millions
    -- (sous le seuil 1 milliard de la v8, donc non purges) -> total > cap 2^31-1 -> barre faussee.
    -- Le seuil plausible est desormais ~50 M / front / faction : on repurge avec ce seuil strict.
    if dominationSyncVersion < 9 then
        if Overlord.SanitizeCorruptDominationBuckets then
            Overlord:SanitizeCorruptDominationBuckets()
        end
        OverlordDB.dominationSyncVersion = 9
        dominationSyncVersion = 9
    end
    -- Migration 10 : journal d'evenements victoire separe des buckets territoriaux.
    -- Les bonus deja materialises dans frontDominationTime ne sont jamais reappliques.
    if dominationSyncVersion < 10 then
        OverlordDB.dominationVictoryEvents = { byPool = {} }
        OverlordDB.dominationSyncVersion = 10
        dominationSyncVersion = 10
    end
    -- Migration 11 : le seuil historique 50 M distinguait les anciens scores
    -- amplifies, mais il devient atteignable avec des centaines de bonus bois
    -- legitimes. Purger une derniere fois tous les pools AVANT de relever le
    -- plafond runtime a 500 M, puis laisser le garde dynamique x64 arbitrer.
    if dominationSyncVersion < 11 then
        for _, poolBuckets in pairs(OverlordDB.frontDominationTimeByPool or {}) do
            if type(poolBuckets) == "table" then
                for _, bucket in pairs(poolBuckets) do
                    local legacyAlly = type(bucket) == "table"
                        and math.max(0, tonumber(bucket.Alliance) or 0) or 0
                    local legacyHorde = type(bucket) == "table"
                        and math.max(0, tonumber(bucket.Horde) or 0) or 0
                    if type(bucket) == "table"
                        and legacyAlly + legacyHorde >= 50000000 then
                        bucket.Alliance = 0
                        bucket.Horde = 0
                        bucket.scoreSeq = 0
                        bucket.scoreSource = ""
                    end
                end
            end
        end
        OverlordDB.dominationSyncVersion = 11
        dominationSyncVersion = 11
        if self.RecalculateDominationTotals then self:RecalculateDominationTotals() end
    end
    if type(OverlordDB.dominationVictoryEvents) ~= "table" then
        OverlordDB.dominationVictoryEvents = { byPool = {} }
    end
    OverlordDB.dominationVictoryEvents.byPool = OverlordDB.dominationVictoryEvents.byPool or {}
    OverlordDB.frontVictories = OverlordDB.frontVictories or {}
    -- Structure seulement : migrations legacy/orphelins et logs corrompus sont
    -- exclusivement traites par la barriere Lifetime cooperative plus bas.
    OverlordDB.lifetimeStatsByCharacter = type(OverlordDB.lifetimeStatsByCharacter) == "table"
        and OverlordDB.lifetimeStatsByCharacter or {}

    -- Migration treve : si lastVictoryTimestamp existe mais pas lastVictoryFaction,
    -- la treve ne fonctionne pas (IsOnVictoryCooldown retourne false). On efface le timestamp
    -- pour eviter une treve "fantome" qui bloque sans proteger la bonne capitale.
    if OverlordDB.lastVictoryTimestamp and OverlordDB.lastVictoryTimestamp > 0
        and not OverlordDB.lastVictoryFaction then
        OverlordDB.lastVictoryTimestamp = nil
    end
    if OverlordDB.lastVictoryTimestamp and OverlordDB.lastVictoryTimestamp > 0
        and OverlordDB.lastVictoryFaction and Overlord.Fronts then
        local victoryFrontId = OverlordDB.lastVictoryFrontId or OverlordDB.activeFrontId or Overlord.Fronts.activeFrontId
        if victoryFrontId and not OverlordDB.frontVictories[victoryFrontId] then
            OverlordDB.frontVictories[victoryFrontId] = {
                timestamp = OverlordDB.lastVictoryTimestamp,
                faction = OverlordDB.lastVictoryFaction,
            }
            OverlordDB.lastVictoryFrontId = victoryFrontId
        end
    end

    -- Initialisation de config et migration de l'ancien choix de HUD.
    -- L'ancien showTopHud=true etait la valeur par defaut, pas un choix "Toujours".
    -- Corrige aussi les saves deja migrees vers always avant ce changement.
    local hudCfg = OverlordDB.config
    if hudCfg.topHudModeUserSelected ~= true then
        hudCfg.topHudMode = (hudCfg.topHudMode == "never" or hudCfg.showTopHud == false)
            and "never" or "auto"
    elseif hudCfg.topHudMode ~= "auto"
        and hudCfg.topHudMode ~= "always"
        and hudCfg.topHudMode ~= "never" then
        hudCfg.topHudMode = "auto"
    end
    if hudCfg.topHudMode == "auto" and hudCfg.showTutorialBookUserSelected ~= true then
        hudCfg.showTutorialBook = false
    end
    local CONFIG_DEFAULTS = {
        uiVisible = true,
        soundEnabled = true,
        debug = false,
        uiScale = 1.0,
        notificationChatFrame = 0,
        mapOverlayOpacity = 1.0,
        minimapOverlayOpacity = 1.0,
        showMinimapButton = true,
        showMinimapCaptureZones = true,
        mapPathOpacity = 1.0,
        autoWaypointNextObjective = true,
        showTopHud = true,
    }
    for k, v in pairs(CONFIG_DEFAULTS) do
        if OverlordDB.config[k] == nil then
            OverlordDB.config[k] = v
        end
    end
    OverlordDB.config.popupsSeen = OverlordDB.config.popupsSeen or {}
    OverlordDB.config.popupsDailyShown = OverlordDB.config.popupsDailyShown or {}

    if Overlord.Fronts and OverlordDB.activeFrontId and Overlord.Fronts:GetFront(OverlordDB.activeFrontId) then
        Overlord.Fronts:Activate(OverlordDB.activeFrontId)
    end

    -- Detecte la faction du joueur et applique la configuration correspondante
    self.PlayerFaction = UnitFactionGroup("player")
    if not self.PlayerFaction then
        C_Timer.After(1, function()
            if not Overlord.IsInitialized then Overlord:Initialize() end
        end)
        return
    end
    self:RequireCaptureSync("login")
    self.Zones:ApplyFactionConfig(self.PlayerFaction)
    -- Fortin : restore in_progress apres PlayerFaction (decroissance offline = meme moteur que les fronts)
    if Overlord.GuildKeep then Overlord.GuildKeep:RestoreKeeps() end
    if Overlord.Outpost then Overlord.Outpost:RestoreOutposts() end

    -- Changement de faction (ex: deconnexion Alliance, reconnexion Horde) : l'etat des zones
    -- (qui controle quoi) est partage entre factions - on restaure pour avoir la map a jour.
    -- On garde WaitingForSync pour ne pas repondre aux SR tant qu'on n'a pas recu de sync
    -- (evite de pousser des donnees potentiellement stale si on etait desync avant la deco).
    local lastFaction = OverlordDB.lastSessionFaction
    local factionSwitched = (lastFaction and lastFaction ~= "" and lastFaction ~= self.PlayerFaction)
    local poolChanged = false
    if factionSwitched then
        self.WaitingForSync = true
        -- Timeout : si personne ne repond sous 60s, on redevient actif
        -- (evite que l'addon reste muet indefiniment si aucun pair n'est en ligne)
        C_Timer.After(60, function()
            if Overlord.WaitingForSync then
                Overlord.WaitingForSync = nil
            end
        end)
    end

    -- Changement de pool (ex. perso FR puis perso EU) : zero updatedAt silencieux
    -- pour accepter les syncs du nouveau pool sans message ni reset visible.
    local currentPool = GetCurrentPoolForSavedVars()
    local currentLeaderboardPool = self:GetCurrentLeaderboardSavedVarsPool()
    local lastPool = OverlordDB.lastSessionPool
    if Overlord.RealmPools and Overlord.RealmPools.NormalizeRegionPool then
        lastPool = Overlord.RealmPools:NormalizeRegionPool(lastPool or "")
    elseif type(lastPool) ~= "string" then
        lastPool = ""
    else
        lastPool = lastPool:lower()
        if lastPool == "fr" or lastPool == "de" then lastPool = "eu" end
    end
    OverlordDB.leaderboardsByPool = OverlordDB.leaderboardsByPool or {}
    -- Seed the global target with the standalone legacy root before union.
    if type(OverlordDB.leaderboardsByPool[currentLeaderboardPool]) ~= "table" then
        OverlordDB.leaderboardsByPool[currentLeaderboardPool] =
            OverlordDB.leaderboard or EmptyLeaderboardBucket()
    end
    self:UnifyEuropeanLeaderboardBuckets()
    -- Reprendre uniquement une migration deja journalisee par une ancienne version.
    if Overlord.Leaderboard and OverlordDB.guildKeepLbMigrationFrom then
        Overlord.Leaderboard._guildKeepLbMigrationFrom = OverlordDB.guildKeepLbMigrationFrom
    end
    OverlordDB.leaderboard = OverlordDB.leaderboardsByPool[currentLeaderboardPool]
    if lastPool ~= "" and lastPool ~= currentPool then
        poolChanged = true
        for _, savedData in pairs(OverlordDB.zones or {}) do
            if type(savedData) == "table" and savedData.status ~= "in_progress" then
                local ct = tonumber(savedData.capturedTime) or 0
                if not ((savedData.owner == "Alliance" or savedData.owner == "Horde") and ct > 0) then
                    savedData.updatedAt = 0
                end
            end
        end
        for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
            local ct = tonumber(zone.capturedTime) or 0
            if not ((zone.owner == "Alliance" or zone.owner == "Horde") and ct > 0) then
                zone.updatedAt = 0
            end
        end
        ZeroGuildKeepsForSyncCatchup()
        if Overlord.GuildKeep and Overlord.GuildKeep.ClearForeignPoolHeldStates then
            Overlord.GuildKeep:ClearForeignPoolHeldStates()
        end
        -- Le bucket domination actif vient lui aussi de changer. Le burst login
        -- demandera le pool correct ; le repush differe ne peut plus re-etiqueter
        -- les valeurs de l'ancien pool grace a frontDominationTimeByPool.
        OverlordDB._dominationPoolResyncPending = true
        DebugOverlord("Changement de pool : " .. lastPool .. " -> " .. currentPool .. " (updatedAt = 0)")
    end
    OverlordDB.lastSessionPool = currentPool
    OverlordDB.lastSessionRealmKey = nil

    self.IsInitialized = true
    -- Toujours dans le chat general par defaut : repere visuel pour nouveau joueur /reload.
    print("|cFF00FF00[Overlord]|r " .. string.format(L.ADDON_LOADED, self.Version))

    -- Message login : uniquement si les donnees locales sont vides/stale (pas les veterans a jour).
    if factionSwitched or poolChanged or self:ZonesNeedLoginSyncNotice() then
        local syncMsg = (L and L.SYNC_LOGIN_WAIT) or "Synchronizing zone data... Map will update shortly."
        self:PrintNotification("|cFFFFD100[Overlord]|r " .. syncMsg)
    end

    local inInstanceAtInit = IsInInstance()
    if not inInstanceAtInit then
        local okInst, _, instType = pcall(GetInstanceInfo)
        if okInst and instType and instType ~= "none" and instType ~= "" then
            inInstanceAtInit = true
        end
    end
    self:PrimeLoginInstanceBarrier(inInstanceAtInit)

    -- Initialisation differee et etalee : chaque etape tourne sur une frame
    -- distincte. Le precedent unique C_Timer.After(0) deplacait le pic
    -- ADDON_LOADED mais empilait encore restore, classement et dix modules.
    C_Timer.After(0, function()
        if not Overlord.IsInitialized or Overlord._deferredModuleInitStarted then return end
        Overlord._deferredModuleInitStarted = true

        local loginInitStages = {}
        local function AddLoginInitStage(name, callback, required)
            loginInitStages[#loginInitStages + 1] = {
                name = name,
                callback = callback,
                required = required == true,
            }
        end

        AddLoginInitStage("GilneasMigration", function()
            return Overlord:EnsureGilneasZoneRenamePrepared()
        end, true)

        AddLoginInitStage("Restore", function()
            Overlord:RestoreZoneState()
            if Overlord.Zones and Overlord.Zones.FinalizeRestoredInProgressAfterReload then
                C_Timer.After(1, function()
                    if not Overlord.IsInitialized or Overlord.InstanceSuspended then return end
                    if not Overlord._deferredModuleInitDone then
                        Overlord._loginFinalizeRestoreDeferred = true
                        return
                    end
                    Overlord.Zones:FinalizeRestoredInProgressAfterReload()
                end)
            end
            if Overlord.Zones and Overlord.Zones.PruneExpiredPhantomVictories then
                Overlord.Zones:PruneExpiredPhantomVictories()
            end
        end)

        AddLoginInitStage("Leaderboard", function()
            if Overlord._europeanLeaderboardUnionPending then return false end
            return Overlord.Leaderboard:Initialize(true)
        end, true)

        -- Tenants/awards/preuves GH sont sanities, bornes et indexes par une
        -- coroutine avant Campaign/Sync. Les migrations de pool ci-dessus ne font
        -- plus aucun scan SavedVariables dans Initialize.
        AddLoginInitStage("GuildKeepLedger", function()
            if not Overlord.Leaderboard
                or not Overlord.Leaderboard.EnsureGuildKeepProofLedgerPrepared then return true end
            local prepared = Overlord.Leaderboard:EnsureGuildKeepProofLedgerPrepared(true)
            if prepared ~= true then return prepared end
            return true
        end, true)

        AddLoginInitStage("Campaign", function()
            -- Le reset/archive ne doit jamais detacher un bucket pendant l'union
            -- EU tranchee. Restore territorial est deja termine; les etapes suivantes
            -- attendent simplement le commit sans bloquer la frame.
            if Overlord._europeanLeaderboardUnionPending then return false end
            -- Ces deux migrations etaient deja isolees : leur echec ne doit pas
            -- empecher les restaurations suivantes de s'executer.
            Overlord._loginWeeklyResetStageActive = true
            local okReset, errReset = pcall(Overlord.CheckWeeklyReset, Overlord)
            Overlord._loginWeeklyResetStageActive = nil
            Overlord._loginWeeklyResetDeferred = nil
            if Overlord._loginWeeklyResetTimerStopped then
                Overlord._loginWeeklyResetTimerStopped = nil
                Overlord:ScheduleNextReset()
            end
            if not okReset and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
                print("|cFFFF4444[Overlord:dbg]|r CheckWeeklyReset (login): " .. tostring(errReset))
            end
            if Overlord.Leaderboard and Overlord.Leaderboard.RestoreLocalKillsFromLatestHistoryIfNeeded then
                Overlord.Leaderboard:RestoreLocalKillsFromLatestHistoryIfNeeded()
            end
            -- Filet anti-perte : restaure le classement complet recu si le snapshot appartient a la
            -- campagne courante (recuperation apres faux reset / crash). Fusion max(), pas de rebroadcast.
            if Overlord.Leaderboard and Overlord.Leaderboard.RestoreFullLadderFromSnapshotIfNeeded then
                Overlord.Leaderboard:RestoreFullLadderFromSnapshotIfNeeded()
            end
            return true
        end, true)

        -- History 8.0.7, alias de personnages et index account-wide peuvent contenir
        -- des milliers de lignes. La barriere Lifetime les traite par tranches apres
        -- le reset/restore Campaign et avant tout consumer Sync/UI.
        AddLoginInitStage("Lifetime", function()
            if not Overlord.LifetimeStats
                or not Overlord.LifetimeStats.EnsurePrepared then return true end
            return Overlord.LifetimeStats:EnsurePrepared(true)
        end, true)

        -- RestoreFullLadderFromSnapshotIfNeeded peut enrichir le bucket apres la
        -- premiere barriere Leaderboard. Revalider les index avant d'armer Sync ;
        -- si rien n'a change, ce stage reste un simple test O(1).
        AddLoginInitStage("NetworkIndexes", function()
            if not Overlord.Leaderboard
                or not Overlord.Leaderboard.EnsureNetworkHotIndexesPrepared then return true end
            return Overlord.Leaderboard:EnsureNetworkHotIndexesPrepared()
        end, true)

        -- La migration/recomposition LOC peut parcourir des milliers de couples et
        -- jusqu'a 5000 evenements par ligne. Construire son snapshot pagine avant Sync
        -- garantit que toute reponse SR reste une lecture O(1) du cache publie.
        AddLoginInitStage("OutpostLedger", function()
            if not Overlord.Leaderboard
                or not Overlord.Leaderboard.EnsureOutpostLedgerPrepared then return true end
            return Overlord.Leaderboard:EnsureOutpostLedgerPrepared(true)
        end, true)

        -- Une ancienne table WB peut contenir des milliers d'identifiants. La
        -- compter/nettoyer par tranches avant Sync evite toute perte du premier
        -- boost recu pendant la construction et garde le handler strictement O(1).
        AddLoginInitStage("WBLedger", function()
            if not Overlord.Sync
                or not Overlord.Sync.EnsureDominationBoostEventLedgerPrepared then return true end
            return Overlord.Sync:EnsureDominationBoostEventLedgerPrepared()
        end, true)

        for _, mod in ipairs({ "Ressources", "Combat", "ManualBounty" }) do
            local moduleName = mod
            AddLoginInitStage(moduleName, function()
                return Overlord[moduleName]:Initialize()
            end, moduleName == "ManualBounty")
        end

        AddLoginInitStage("ManualBountyMailLedger", function()
            return Overlord.ManualBountyMail:EnsureCodSendLedgerPrepared()
        end, true)

        for _, mod in ipairs({
            "ManualBountyMail", "General", "Sync", "ZoneIndicator", "Shard",
        }) do
            local moduleName = mod
            AddLoginInitStage(moduleName, function()
                return Overlord[moduleName]:Initialize()
            end)
        end

        AddLoginInitStage("Capture", function()
            Overlord:ResumeCaptureAfterLoginBarrier()
        end)

        AddLoginInitStage("LoginSync", function()
            if not Overlord.Sync then return end
            Overlord._syncDeferredInitDone = true
            Overlord._loginChannelPending = nil
            if Overlord.InstanceSuspended or IsInInstance() then return end
            Overlord:StartGuildKeepLoop()
            -- Join canal tot : le SR a +1,5 s passait souvent avant GetChannelId() (PLAYER_LOGIN +5 s).
            if Overlord.Sync.JoinChannel then Overlord.Sync:JoinChannel(1) end
            if Overlord.Sync.StartChannelRetryLoop then Overlord.Sync:StartChannelRetryLoop() end
            if Overlord.Sync.StartProximitySync then Overlord.Sync:StartProximitySync() end
            if Overlord.Sync.StartPassiveSync then Overlord.Sync:StartPassiveSync() end
            if Overlord.Sync.StartGuildIdentityHeartbeat then
                Overlord.Sync:StartGuildIdentityHeartbeat()
            end
            if OverlordDB and OverlordDB._dominationPoolResyncPending then
                OverlordDB._dominationPoolResyncPending = nil
                if Overlord.Sync.BroadcastDomination then
                    Overlord.Sync:BroadcastDomination({ passiveOffFront = true })
                end
            end
            if Overlord.Sync.StartLoginCaptureSyncBurst then
                Overlord.Sync:StartLoginCaptureSyncBurst()
            elseif Overlord.Sync.SendSyncRequest then
                C_Timer.After(1.5, function()
                    if Overlord.InstanceSuspended or not Overlord.Sync then return end
                    Overlord.Sync:SendSyncRequest()
                end)
            end
        end)

        AddLoginInitStage("Settings", function()
            if Overlord.SettingsPanel and Overlord.SettingsPanel.Register then
                Overlord.SettingsPanel:Register()
            end
        end)

        AddLoginInitStage("Domination", function()
            if not Overlord.InstanceSuspended and not inInstanceAtInit and StartDominationTicker then
                StartDominationTicker()
            end
        end)

        -- UI apres ses dependances. Si une machine tres chargee atteint le timer
        -- d'auto-affichage de PLAYER_LOGIN avant cette etape, ce rattrapage evite
        -- que UI:Show() ait ete un no-op faute de mainFrame.
        AddLoginInitStage("UI", function()
            Overlord.UI:Initialize()
            if not Overlord.InstanceSuspended and Overlord.InActiveFront
                and OverlordDB and OverlordDB.config and OverlordDB.config.uiVisible
                and Overlord.UI.Show then
                Overlord.UI:Show({ skipRefresh = true })
                Overlord:ScheduleLoginUiFullRefresh(0)
            end
        end)

        -- Les deux autres modules UI conservent chacun leur frame dediee.
        for _, mod in ipairs({ "Button", "ManualBountyUI" }) do
            local moduleName = mod
            AddLoginInitStage(moduleName, function()
                Overlord[moduleName]:Initialize()
            end)
        end

        local loginInitStageIndex = 0
        local RunNextLoginInitStage
        RunNextLoginInitStage = function()
            if not Overlord.IsInitialized then return end
            loginInitStageIndex = loginInitStageIndex + 1
            local stage = loginInitStages[loginInitStageIndex]
        if not stage then
            Overlord._deferredModuleInitDone = true
            Overlord._loginInitStage = "complete"
            Overlord._loginInitState = "ready"
            Overlord._loginInitError = nil
            Overlord:FlushDeferredCaptureRelease()
            Overlord:FlushDeferredInstanceTransition()
            if Overlord._loginFactionChangeDeferred then
                Overlord:RequestFactionChangeReconcile()
            end
            if Overlord._loginFinalizeRestoreDeferred then
                Overlord._loginFinalizeRestoreDeferred = nil
                if not Overlord.InstanceSuspended and Overlord.Zones
                    and Overlord.Zones.FinalizeRestoredInProgressAfterReload then
                    Overlord.Zones:FinalizeRestoredInProgressAfterReload()
                end
            end
            if Overlord._loginWeeklyResetDeferred then
                Overlord._loginWeeklyResetDeferred = nil
                C_Timer.After(0, function()
                    if not Overlord.IsInitialized then return end
                    pcall(Overlord.CheckWeeklyReset, Overlord)
                    Overlord:ScheduleNextReset()
                end)
            end
            Overlord:FlushDeferredLoginIntents()
            return
            end

            Overlord._loginInitStage = stage.name
            Overlord._loginInitState = "running"
            Overlord._loginInitError = nil
            local ok, completedOrErr = pcall(stage.callback)
            if not ok then
                Overlord._loginInitState = "error"
                Overlord._loginInitError = tostring(completedOrErr)
                Overlord:PrintNotification("|cFFFF0000[Overlord]|r "
                    .. string.format(L.MODULE_ERROR, stage.name, tostring(completedOrErr)))
                -- Les handlers Sync ne doivent jamais demarrer apres une exception
                -- du sanitizer/index du classement. Les autres modules restent
                -- best-effort afin qu'une erreur UI n'annule pas tout l'addon.
                if stage.required then return end
            elseif completedOrErr == "blocked" then
                Overlord._loginInitState = "blocked"
                -- Migration/index de securite en echec terminal : fail closed.
                -- Ne pas initialiser Sync et ne pas repoller ce stage chaque frame.
                return
            elseif completedOrErr == "waiting" then
                Overlord._loginInitState = "waiting"
                loginInitStageIndex = loginInitStageIndex - 1
                C_Timer.After(1, RunNextLoginInitStage)
                return
            elseif completedOrErr == false then
                Overlord._loginInitState = "pending"
                loginInitStageIndex = loginInitStageIndex - 1
                C_Timer.After(0, RunNextLoginInitStage)
                return
            end
            C_Timer.After(0, RunNextLoginInitStage)
        end
        RunNextLoginInitStage()
    end)
end

function Overlord:MergeLeaderboardBucketInto(target, source, onDone)
    if type(target) ~= "table" or type(source) ~= "table" or target == source then
        if onDone then onDone(target) end
        return target
    end

    local phases = { "kills", "captureCount", "bountyTimes", "bountyKills", "captures", "playerInfo" }
    local phaseIndex, cursor = 1, nil
    -- Une seule ligne captures peut elle-meme contenir une liste legacy enorme. Le
    -- budget externe par joueur ne suffit donc pas : conserver une continuation
    -- jusque dans les deux listes evite une frame monolithique avant le nettoyage.
    local captureMergeState = nil
    local function classRank(class)
        if not class or class == "" then return 0 end
        if class == "UNKNOWN" then return 1 end
        return 2
    end
    local function cleanGuild(name)
        if type(name) ~= "string" then return "" end
        name = (name:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or "")
        return name:sub(1, 96)
    end
    local function cleanLocale(tag)
        if type(tag) ~= "string" then return "" end
        return tag:lower():match("^([a-z][a-z][a-z]?[a-z]?[a-z]?)$") or ""
    end
    local function cleanPool(pool)
        if Overlord.RealmPools and Overlord.RealmPools.NormalizeRegionPool then
            return Overlord.RealmPools:NormalizeRegionPool(pool)
        end
        if type(pool) ~= "string" then return "" end
        pool = pool:lower()
        if pool == "global" or pool == "us" or pool == "na" or pool == "eu"
            or pool == "fr" or pool == "de" then return "global" end
        return ""
    end
    local function guildHash(name)
        local h = 0
        name = (name or ""):lower()
        for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
        return h
    end
    local function guildWins(newGuild, newAt, curGuild, curAt)
        newGuild, curGuild = cleanGuild(newGuild), cleanGuild(curGuild)
        newAt, curAt = math.max(0, math.floor(tonumber(newAt) or 0)),
            math.max(0, math.floor(tonumber(curAt) or 0))
        if curGuild == "" and curAt <= 0 then return newGuild ~= "" or newAt > 0 end
        if newGuild == "" and newAt <= 0 then return false end
        if newAt ~= curAt then return newAt > curAt end
        if newGuild == curGuild then return false end
        if newGuild:lower() == curGuild:lower() then return newGuild < curGuild end
        if newGuild == "" then return true end
        if curGuild == "" then return false end
        local hn, hc = guildHash(newGuild), guildHash(curGuild)
        if hn ~= hc then return hn < hc end
        return newGuild:lower() < curGuild:lower()
    end
    local function mergePlayerInfo(name, sourceInfo)
        if type(sourceInfo) ~= "table" then return end
        target.playerInfo = target.playerInfo or {}
        local info = target.playerInfo[name]
        if type(info) ~= "table" then info = {}; target.playerInfo[name] = info end
        local sourceClass = type(sourceInfo.class) == "string" and sourceInfo.class or ""
        local targetClass = type(info.class) == "string" and info.class or ""
        if classRank(sourceClass) > classRank(targetClass)
            or (classRank(sourceClass) == classRank(targetClass) and sourceClass ~= ""
                and (targetClass == "" or sourceClass < targetClass)) then
            info.class = sourceClass
        end
        info.level = math.max(tonumber(info.level) or 0, tonumber(sourceInfo.level) or 0)
        local sourceFaction = type(sourceInfo.faction) == "string" and sourceInfo.faction or ""
        local targetFaction = type(info.faction) == "string" and info.faction or ""
        if sourceFaction ~= "Alliance" and sourceFaction ~= "Horde" then sourceFaction = "" end
        if targetFaction ~= "Alliance" and targetFaction ~= "Horde" then targetFaction = "" end
        info.faction = targetFaction
        if sourceFaction ~= "" and (targetFaction == "" or sourceFaction < targetFaction) then
            info.faction = sourceFaction
        end
        info.factionAt = math.max(tonumber(info.factionAt) or 0,
            tonumber(sourceInfo.factionAt) or 0)
        local sourceLocale, targetLocale = cleanLocale(sourceInfo.locale), cleanLocale(info.locale)
        info.locale = targetLocale
        if sourceLocale ~= "" and (targetLocale == "" or sourceLocale < targetLocale) then
            info.locale = sourceLocale
        end
        local sourceGuildAt, targetGuildAt = tonumber(sourceInfo.guildAt) or 0,
            tonumber(info.guildAt) or 0
        local sourceGuild, targetGuild = cleanGuild(sourceInfo.guild), cleanGuild(info.guild)
        local sourceGuildAuth, targetGuildAuth = sourceInfo.guildAuth == true,
            info.guildAuth == true
        if sourceGuild == targetGuild then
            info.guild = sourceGuild
            info.guildAt = math.max(sourceGuildAt, targetGuildAt)
            info.guildAuth = sourceGuildAuth or targetGuildAuth or nil
        elseif (sourceGuildAuth and not targetGuildAuth)
            or (sourceGuildAuth == targetGuildAuth
                and guildWins(sourceGuild, sourceGuildAt, targetGuild, targetGuildAt)) then
            info.guild = sourceGuild
            info.guildAt = sourceGuildAt
            info.guildAuth = sourceGuildAuth or nil
        else
            info.guild = targetGuild
            info.guildAt = targetGuildAt
            info.guildAuth = targetGuildAuth or nil
        end
        local sourceRaceAt, targetRaceAt = tonumber(sourceInfo.raceAt) or 0,
            tonumber(info.raceAt) or 0
        local sourceRace = type(sourceInfo.race) == "string" and sourceInfo.race or ""
        local targetRace = type(info.race) == "string" and info.race or ""
        local sourceSex, targetSex = math.floor(tonumber(sourceInfo.raceSex) or 0),
            math.floor(tonumber(info.raceSex) or 0)
        if sourceSex ~= 2 and sourceSex ~= 3 then sourceSex = 0 end
        if targetSex ~= 2 and targetSex ~= 3 then targetSex = 0 end
        if sourceRace ~= "" and (targetRace == "" or sourceRaceAt > targetRaceAt
            or (sourceRaceAt == targetRaceAt and sourceRace < targetRace)) then
            info.race = sourceRace
            info.raceSex = sourceSex
            info.raceAt = sourceRaceAt
        elseif sourceRace ~= "" and sourceRace == targetRace
            and sourceRaceAt == targetRaceAt
            and sourceSex > 0 and (targetSex == 0 or sourceSex < targetSex) then
            info.raceSex = sourceSex
        end
        local sourcePool, targetPool = cleanPool(sourceInfo.pool), cleanPool(info.pool)
        info.pool = targetPool
        if sourcePool ~= "" and (targetPool == "" or sourcePool < targetPool) then
            info.pool = sourcePool
        end
    end
    local function mergeEntry(field, name, value)
        if field == "playerInfo" then
            mergePlayerInfo(name, value)
        else
            target[field] = target[field] or {}
            local n = tonumber(value) or 0
            if n > (tonumber(target[field][name]) or 0) then target[field][name] = n end
        end
    end
    local function StepCaptureMerge(state)
        if state.phase == "target" then
            local zoneId = state.target[state.index]
            if zoneId ~= nil then
                state.seen[zoneId] = true
                state.index = state.index + 1
                return false
            end
            state.phase, state.index = "source", 1
        end
        local zoneId = state.source[state.index]
        if zoneId ~= nil then
            if not state.seen[zoneId] then
                state.seen[zoneId] = true
                state.target[#state.target + 1] = zoneId
            end
            state.index = state.index + 1
            return false
        end
        return true
    end
    local runSlice
    runSlice = function()
        local processed = 0
        local started = debugprofilestop and debugprofilestop() or 0
        local function BudgetSpent()
            local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
            return processed >= 64 or elapsed >= 1.5
        end
        local function ContinueLater()
            if C_Timer and C_Timer.After then C_Timer.After(0, runSlice) end
        end
        while phaseIndex <= #phases do
            if captureMergeState then
                local state = captureMergeState
                local ok, completeOrErr = pcall(StepCaptureMerge, state)
                if not ok then
                    if onDone then onDone(target, false) end
                    return
                end
                processed = processed + 1
                if completeOrErr then captureMergeState = nil end
                if BudgetSpent() then ContinueLater(); return end
            else
            local field = phases[phaseIndex]
            local sourceTable = type(source[field]) == "table" and source[field] or {}
            local name, value = next(sourceTable, cursor)
            if name == nil then
                phaseIndex, cursor = phaseIndex + 1, nil
            else
                cursor = name
                local ok = true
                if field == "captures" then
                    if type(value) == "table" then
                        target.captures = target.captures or {}
                        local zones = target.captures[name]
                        if type(zones) ~= "table" then
                            zones = {}
                            target.captures[name] = zones
                        end
                        captureMergeState = {
                            target = zones,
                            source = value,
                            seen = {},
                            phase = "target",
                            index = 1,
                        }
                    end
                else
                    ok = pcall(mergeEntry, field, name, value)
                end
                if not ok then
                    if onDone then onDone(target, false) end
                    return
                end
                processed = processed + 1
                if BudgetSpent() then ContinueLater(); return end
            end
            end
        end
        target.campaignStart = math.max(tonumber(target.campaignStart) or 0,
            tonumber(source.campaignStart) or 0)
        target.campaignId = math.max(tonumber(target.campaignId) or 0,
            tonumber(source.campaignId) or 0)
        if onDone then onDone(target, true) end
    end
    runSlice()
    return target
end

-- Migration sans perte vers un unique bucket EU. Les anciens buckets fr/de ne
-- restent pas dupliques : toutes les prochaines sessions europeennes pointent sur eu.
function Overlord:UnifyEuropeanLeaderboardBuckets()
    if not OverlordDB or self:GetCurrentLeaderboardSavedVarsPool() ~= "global" then return end
    if self._europeanLeaderboardUnionPending then return end
    local buckets = OverlordDB.leaderboardsByPool or {}
    OverlordDB.leaderboardsByPool = buckets
    local poolOrder = { "global", "us", "eu", "fr", "de", "na" }
    if tonumber(OverlordDB.globalLeaderboardUnifiedVersion) == 1
        and type(buckets.global) == "table" and buckets.us == nil
        and buckets.eu == nil and buckets.fr == nil and buckets.de == nil
        and buckets.na == nil then
        return
    end
    local expectedEpoch = tonumber(OverlordDB.lastResetTimestamp) or 0
    if expectedEpoch <= 0 then
        for _, pool in ipairs(poolOrder) do
            local bucket = buckets[pool]
            expectedEpoch = math.max(expectedEpoch,
                type(bucket) == "table" and tonumber(bucket.campaignStart) or 0)
        end
    end
    local function bucketHasProgress(bucket)
        if type(bucket) ~= "table" then return false end
        for _, field in ipairs({ "kills", "captureCount", "captures", "bountyTimes", "bountyKills" }) do
            if type(bucket[field]) == "table" and next(bucket[field]) ~= nil then return true end
        end
        return false
    end
    local function bucketIsCurrent(bucket)
        if type(bucket) ~= "table" then return false end
        local epoch = tonumber(bucket.campaignStart) or 0
        if expectedEpoch <= 0 then return true end
        -- Les anciennes versions n'estampillaient pas toujours le bucket actif.
        -- Un ladder sans epoch mais avec scores est la seule copie disponible :
        -- le promouvoir vers la campagne DB conserve les donnees au lieu de les masquer.
        if epoch <= 0 and bucketHasProgress(bucket) then return true end
        return epoch > 0 and math.abs(epoch - expectedEpoch) <= 36 * 3600
    end
    local unified = nil
    -- Reutiliser un bucket existant in-place limite le pic de memoire de migration.
    for _, pool in ipairs(poolOrder) do
        local bucket = buckets[pool]
        if bucketIsCurrent(bucket) then
            if pool == "global" then unified = bucket; break end
            if not unified then unified = bucket end
        end
    end
    if not unified then
        unified = EmptyLeaderboardBucket()
        if expectedEpoch > 0 then
            unified.campaignStart = expectedEpoch
            unified.campaignId = self.TimestampToCampaignId
                and self:TimestampToCampaignId(expectedEpoch) or 0
        end
    elseif (tonumber(unified.campaignStart) or 0) <= 0 and expectedEpoch > 0 then
        unified.campaignStart = expectedEpoch
        unified.campaignId = self.TimestampToCampaignId
            and self:TimestampToCampaignId(expectedEpoch) or 0
    end
    local mergeSources = {}
    for _, pool in ipairs(poolOrder) do
        local bucket = buckets[pool]
        local bucketEpoch = type(bucket) == "table" and tonumber(bucket.campaignStart) or 0
        if type(bucket) == "table" and bucket ~= unified and bucketIsCurrent(bucket) then
            mergeSources[#mergeSources + 1] = bucket
        elseif type(bucket) == "table" and bucket ~= unified then
            -- Ne jamais detruire un bucket d'une autre campagne ou sans provenance.
            OverlordDB.legacyLeaderboardBucketsByPool = OverlordDB.legacyLeaderboardBucketsByPool or {}
            local backupKey = pool .. ":" .. tostring(bucketEpoch)
            OverlordDB.legacyLeaderboardBucketsByPool[backupKey] = bucket
        end
    end
    -- Une source legacy rend aussi la cible legacy. Ecrire le minimum AVANT la
    -- premiere tranche garantit qu'un /reload au milieu de l'union rejouera les
    -- reparations Clean/dedup sur le bucket partiellement consolide.
    local mergedRepairVersion = tonumber(unified.repairVersion) or 0
    for i = 1, #mergeSources do
        mergedRepairVersion = math.min(mergedRepairVersion,
            tonumber(mergeSources[i].repairVersion) or 0)
    end
    unified.repairVersion = mergedRepairVersion
    buckets.global = unified
    self._europeanLeaderboardUnionPending = true
    local sourceIndex = 0
    local function mergeNext(_, previousSucceeded)
        if previousSucceeded == false then
            -- Conserver les sources intactes : la prochaine session pourra rejouer
            -- l'union idempotente au lieu de valider un commit partiel.
            self._europeanLeaderboardUnionPending = nil
            return
        end
        sourceIndex = sourceIndex + 1
        local source = mergeSources[sourceIndex]
        if source then
            self:MergeLeaderboardBucketInto(unified, source, mergeNext)
            return
        end
        -- Commit seulement apres la derniere tranche : un /reload intermediaire garde
        -- fr/de et rejoue une union max/idempotente, donc aucune donnee n'est perdue.
        for _, pool in ipairs({ "us", "eu", "fr", "de", "na" }) do buckets[pool] = nil end
        OverlordDB.globalLeaderboardUnifiedVersion = 1
        OverlordDB.europeanLeaderboardUnifiedVersion = 1
        self._europeanLeaderboardUnionPending = nil
        local lb = self.Leaderboard
        if lb and lb.kills == unified.kills then
            if lb.MarkMetaDirty then lb:MarkMetaDirty() end
            if lb.MarkDirty then lb:MarkDirty() end
        end
    end
    mergeNext()
end

-- Corrige provisoirement les etats impossibles des capitales avant affichage / apres instance.
-- Exemple : Stromgarde rouge cote Alliance alors que des zones qui dependent de Stromgarde
-- sont deja bleues. Cette reparation locale n'est jamais une capture confirmee : aucun
-- capturedTime n'est invente et updatedAt=0 laisse la sync reseau trancher.
local function ReconcileBaseOwnershipSanity()
    if not Overlord.ZoneDatabase or not Overlord.Zones then return false end

    local changed = false
    local now = time()
    local baseIds = {
        Overlord.Fronts and Overlord.Fronts:GetCapitalId("Alliance"),
        Overlord.Fronts and Overlord.Fronts:GetCapitalId("Horde"),
    }
    for _, zoneId in ipairs(baseIds) do
        local zone = Overlord.Zones:GetZone(zoneId)
        local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
        if zone and fixedOwner and zone.owner and zone.owner ~= fixedOwner then
            local allOtherZonesOwned = true
            for _, other in ipairs(Overlord.ZoneDatabase) do
                if other.id ~= zoneId and other.owner ~= zone.owner then
                    allOtherZonesOwned = false
                    break
                end
            end

            local zoneTs = zone.updatedAt or 0
            local stateIsStaleOrOpen = (zoneTs == 0) or (now - zoneTs > 60)
            if not allOtherZonesOwned and stateIsStaleOrOpen then
                zone.owner = fixedOwner
                zone.status = "captured"
                zone.killsCurrent = 0
                zone.holdTimeElapsed = 0
                zone.isHolding = false
                zone.isContested = false
                zone.isPaused = false
                zone.holdStartTime = nil
                zone.previousOwner = nil
                zone.holdTimeRequired = 120
                zone.capturedTime = nil
                zone.updatedAt = 0
                if Overlord.Zones.ClearCaptureFinalUnattestedState then
                    Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
                end
                -- Etat d'affichage provisoire : il ne doit ni gagner un conflit
                -- de fraicheur ni etre pris pour une preuve de capture reseau.
                zone._loginSyncUnconfirmed = true
                changed = true
            end
        end
    end

    return changed
end

-- Applique les champs communs savedData -> objet zone en memoire.
local function ApplySavedBaseFields(zone, savedData)
    zone.status = savedData.status or "locked"
    zone.killsCurrent      = tonumber(savedData.killsCurrent)      or 0
    zone.allyKillsCurrent  = tonumber(savedData.allyKillsCurrent)  or 0
    zone.enemyKillsCurrent = tonumber(savedData.enemyKillsCurrent) or 0
    zone.capturedTime = tonumber(savedData.capturedTime)
    zone.updatedAt = tonumber(savedData.updatedAt) or tonumber(savedData.capturedTime) or 0
    zone.owner = savedData.owner
    zone.previousOwner = savedData.previousOwner
    zone._assaultFromAvailable = savedData.assaultFromAvailable and true or nil
    -- Migration 9.6.x -> semantique territoriale 9.3.1 : un final deja
    -- materialise dans les SavedVariables reste le socle (status/owner/times
    -- ci-dessus). L'ancienne quarantaine visuelle ne doit jamais survivre a un
    -- /reload et bloquer indefiniment carte, prerequis ou domination.
    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    zone._captureFinalConfirmedBase = nil
    savedData.captureFinalUnattested = nil
    savedData.captureFinalUnattestedOriginKey = nil
    savedData.captureFinalUnattestedWaveId = nil
    savedData.captureFinalUnattestedAt = nil
    savedData.captureFinalBaseStatus = nil
    savedData.captureFinalBaseOwner = nil
    savedData.captureFinalBaseCapturedTime = nil
    savedData.captureFinalBaseUpdatedAt = nil
    if zone.status == "in_progress" then
        -- /reload doit reprendre exactement le contrat canonique de la vague
        -- locale (Renfort 60, normal 120, Barricade 180, ou capitale). Sans
        -- cette restauration, l'objet zone gardait souvent son defaut 120 et
        -- invalidait la preuve temporelle deja engagee sur le reseau.
        local restoredRequirement = Overlord.CaptureLease
            and Overlord.CaptureLease.NormalizeCaptureRequirement
            and Overlord.CaptureLease:NormalizeCaptureRequirement(
                zone, zone.owner, savedData.holdTimeRequired) or nil
        if restoredRequirement then
            zone.holdTimeRequired = restoredRequirement
        elseif Overlord.CaptureLease and Overlord.CaptureLease.GetDefaultCaptureRequirement then
            zone.holdTimeRequired = Overlord.CaptureLease:GetDefaultCaptureRequirement(
                zone, zone.owner)
        elseif zone.isCapital and Overlord.Zones then
            if Overlord.Zones.GetCapitalSiegeHoldRequired then
                zone.holdTimeRequired = Overlord.Zones:GetCapitalSiegeHoldRequired(
                    zone, zone.owner, savedData.holdTimeRequired)
            elseif Overlord.Zones.IsEnemyCapitalCapture
                and Overlord.Zones:IsEnemyCapitalCapture(zone) then
                zone.holdTimeRequired = Overlord.Zones:GetCapitalHoldTime(zone)
            end
        else
            zone.holdTimeRequired = 120
        end
    end
    -- Cap holdTimeElapsed a holdTimeRequired (anti-exploit valeurs gonflees en DB).
    -- Migration 180→120 s : ne pas valider une capture in_progress au seul /reload.
    local maxHold = zone.holdTimeRequired or 120
    local elapsed = math.min(tonumber(savedData.holdTimeElapsed) or 0, maxHold)
    if zone.status == "in_progress" and maxHold > 0 and elapsed >= maxHold then
        elapsed = maxHold - 1
    end
    zone.holdTimeElapsed = elapsed
end

-- Auto-reparation : capturedTime present mais status incoherent apres un save precedent.
local function RepairCapturedStatusMismatch(zone)
    if zone.capturedTime and zone.capturedTime > 0
        and zone.status ~= "captured" and zone.status ~= "in_progress" then
        if zone.owner and zone.owner ~= "" then
            zone.status = "captured"
            zone.updatedAt = zone.capturedTime
        else
            zone.updatedAt = 0
        end
    end
end

local function ApplySavedZoneState(zone, savedData, opts)
    opts = opts or {}
    ApplySavedBaseFields(zone, savedData)
    if zone.status == "in_progress" then
        if savedData.localCapture ~= true or not opts.restoreOfflineProgress then
            -- Migration + regle durable : un in_progress sans preuve d'autorite locale
            -- est un ancien overlay distant. Un front inactif ne peut pas non plus
            -- reprendre l'autorite physique d'une capture locale sauvegardee.
            local assaultFromAvailable = zone._assaultFromAvailable == true
            local revertOwner = Overlord.Zones and Overlord.Zones.ResolveRevertOwnerAfterFailedCapture
                and Overlord.Zones:ResolveRevertOwnerAfterFailedCapture(zone) or zone.previousOwner
            zone.holdTimeElapsed = 0
            zone.isHolding = false
            zone.isPaused = false
            zone.isContested = false
            zone.holdStartTime = nil
            zone.holdAuthorityLocal = nil
            zone.previousOwner = nil
            zone._assaultFromAvailable = nil
            if revertOwner then
                zone.status = "captured"
                zone.owner = revertOwner
                zone.updatedAt = tonumber(zone.capturedTime) or 0
            else
                zone.status = assaultFromAvailable and "available" or "locked"
                zone.owner = nil
                zone.capturedTime = nil
                zone.updatedAt = 0
            end
        elseif opts.restoreOfflineProgress and Overlord.Zones and Overlord.Zones.RestoreInProgressAfterOffline then
            Overlord.Zones:RestoreInProgressAfterOffline(zone, savedData, opts.playerFaction)
        else
            zone.isHolding = false
            zone.isPaused = false
        end
    end
    if zone.status == "in_progress" and savedData.localCapture == true
        and opts.restoreOfflineProgress and Overlord.CaptureLease
        and Overlord.CaptureLease.RestoreLocalWave then
        Overlord.CaptureLease:RestoreLocalWave(zone, savedData.localCaptureWaveId)
    else
        zone._localCaptureWaveId = nil
    end
    RepairCapturedStatusMismatch(zone)
end

-- Restaure l'état des zones depuis SavedVariables
function Overlord:RestoreZoneState()
    local loginSyncUnconfirmed = captureSyncGate.active and captureSyncGate.reason == "login"
    if OverlordDB and OverlordDB.zones then
        -- Migration : corrige les updatedAt gonfles par l'ancien bug de ResetAll()/ResetZone()
        -- qui utilisait time() au lieu de 0. Les zones sans capturedTime sont des zones jamais
        -- capturees (reset ou defaut) : leur updatedAt doit etre 0 pour accepter les sync entrantes.
        for _, savedData in pairs(OverlordDB.zones) do
            if savedData.status ~= "in_progress"
                and not savedData.capturedTime
                and savedData.updatedAt
                and savedData.updatedAt > 0 then
                savedData.updatedAt = 0
            end
        end

        -- Rattrapage reset multi-front : si l'ancien client a deja marque le reset hebdo
        -- comme fait alors qu'un front inactif gardait ses captures, ces captures ont un
        -- capturedTime d'avant la campagne courante. On les neutralise sans toucher aux
        -- captures legitimes faites apres le reset.
        local currentReset = (self.GetCurrentCampaignStartTs and self:GetCurrentCampaignStartTs())
            or tonumber(OverlordDB.lastResetTimestamp) or 0
        if currentReset > 0 then
            for zoneId, savedData in pairs(OverlordDB.zones) do
                if type(savedData) == "table" then
                    local capturedTime = tonumber(savedData.capturedTime) or 0
                    local updatedAt = tonumber(savedData.updatedAt) or 0
                    -- Epoch campagne : tout ce qui date d'avant le reset effectif est obsolete.
                    local staleCaptured = capturedTime > 0 and capturedTime < currentReset
                    local staleInProgress = savedData.status == "in_progress" and updatedAt > 0 and updatedAt < currentReset
                    if staleCaptured or staleInProgress then
                        local fixedOwner = Overlord.Zones and Overlord.Zones:GetBaseZoneFixedOwner(zoneId)
                        savedData.killsCurrent = 0
                        savedData.allyKillsCurrent = 0
                        savedData.enemyKillsCurrent = 0
                        savedData.holdTimeElapsed = 0
                        savedData.previousOwner = nil
                        if fixedOwner then
                            -- Bases : proprietaire fixe ; timestamps alignes sur le reset pour rester "frais" vis-a-vis du merge sync.
                            savedData.owner = fixedOwner
                            savedData.status = (fixedOwner == self.PlayerFaction) and "captured" or "locked"
                            savedData.capturedTime = currentReset
                            savedData.updatedAt = currentReset
                        else
                            -- Hors bases : effacer la vieille capture ; updatedAt = 0 pour laisser les pairs ecraser si besoin.
                            savedData.owner = nil
                            savedData.status = "locked"
                            savedData.capturedTime = nil
                            savedData.updatedAt = 0
                        end
                    end
                end
            end
        end

        -- Login / reload : updatedAt=0 seulement si pas de capture confirmee cette campagne.
        -- Garder capturedTime comme updatedAt protege les zones bleues au /reload contre
        -- un ZA stale (updatedAt=0 acceptait tout ts>0 d'un repondeur desync).
        if not staleSessionUpdatedAtZeroed then
            local lastReset = (self.GetCurrentCampaignStartTs and self:GetCurrentCampaignStartTs())
                or tonumber(OverlordDB.lastResetTimestamp) or 0
            for _, savedData in pairs(OverlordDB.zones) do
                if type(savedData) == "table" and savedData.status ~= "in_progress" then
                    local ct = tonumber(savedData.capturedTime) or 0
                    local owner = savedData.owner
                    local keepTs = owner and owner ~= "" and ct > 0
                        and (lastReset <= 0 or ct >= lastReset)
                    if keepTs then
                        savedData.updatedAt = ct
                    else
                        savedData.updatedAt = 0
                    end
                end
            end
            staleSessionUpdatedAtZeroed = true
        end

        local playerFaction = self.PlayerFaction
        for zoneId, savedData in pairs(OverlordDB.zones) do
            local zone = Overlord.Zones:GetZone(zoneId)
            if zone then
                ApplySavedZoneState(zone, savedData, {
                    restoreOfflineProgress = true,
                    playerFaction = playerFaction,
                })
                if loginSyncUnconfirmed and zone.status ~= "in_progress" then
                    -- Etat disque provisoire : le premier ZA/ZS recu au login doit pouvoir corriger
                    -- toute la carte, meme si la session precedente avait un capturedTime plus haut.
                    zone._loginSyncUnconfirmed = true
                    zone.updatedAt = 0
                end
            end
        end

        -- Autres fronts (consultation liste / sync) : memes SavedVariables, objets dans Registry.
        for zoneId, savedData in pairs(OverlordDB.zones) do
            if type(savedData) == "table" and not Overlord.Zones:GetZone(zoneId) then
                local zone = Overlord.Fronts and select(1, Overlord.Fronts:GetZone(zoneId))
                if zone then
                    ApplySavedZoneState(zone, savedData, { restoreOfflineProgress = false })
                    if loginSyncUnconfirmed and zone.status ~= "in_progress" then
                        zone._loginSyncUnconfirmed = true
                        zone.updatedAt = 0
                    end
                end
            end
        end

        -- Statuts local-only des fronts inactifs : les SV peuvent garder un "Verrouillee"
        -- fige d'une session precedente alors que le prerequis a ete capture entre-temps.
        if Overlord.Fronts and Overlord.Zones and Overlord.Zones.RefreshInactiveFrontAvailability then
            for _, frontId in ipairs(Overlord.Fronts.Order or {}) do
                Overlord.Zones:RefreshInactiveFrontAvailability(frontId)
            end
        end
    end

    -- Meme une installation neuve doit participer au consensus de connexion.
    -- Marquer toutes les zones connues evite qu'un client sans ligne SavedVariables
    -- soit considere canonique avant d'avoir recu une carte globale concordante.
    if loginSyncUnconfirmed then
        local seen = {}
        local function quarantine(zone)
            if zone and zone.id and not seen[zone.id] then
                seen[zone.id] = true
                if zone.status ~= "in_progress" then
                    zone._loginSyncUnconfirmed = true
                    zone.updatedAt = 0
                end
            end
        end
        for _, zone in ipairs(Overlord.ZoneDatabase or {}) do quarantine(zone) end
        if Overlord.Fronts and Overlord.Fronts.Registry then
            for _, front in pairs(Overlord.Fronts.Registry) do
                for _, zone in ipairs((front and front.zones) or {}) do quarantine(zone) end
            end
        end
    end

    -- Sanity check : si la capitale ennemie est marquee comme appartenant a notre faction
    -- sans victoire active, la donnee est probablement corrompue (bug de session precedente).
    -- On force updatedAt = 0 pour que le premier ZA/ZS de sync corrige sans delai.
    -- Si c'est une vraie victoire (lastVictoryFaction == nous ET cooldown actif),
    -- on ne touche pas : c'est legitime.
    if self.PlayerFaction then
        -- IsOnVictoryCooldown lu une seule fois pour les deux sanity checks ci-dessous
        local vcOnCd, _, vcWinFac = Overlord.Zones:IsOnVictoryCooldown()

        -- Sanity check : si la capitale ennemie est marquee comme appartenant a notre faction
        -- sans victoire active de notre cote, la donnee est probablement corrompue.
        local enemyBaseId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(self.PlayerFaction)
        local enemyBase = Overlord.Zones:GetZone(enemyBaseId)
        if enemyBase and enemyBase.owner == self.PlayerFaction then
            local legitimateVictory = vcOnCd and vcWinFac == self.PlayerFaction
            if not legitimateVictory then
                -- Donnee suspecte : on garde owner/capturedTime pour l'affichage initial
                -- mais updatedAt = 0 garantit que la sync ecrase au premier message recu
                enemyBase.updatedAt = 0
            end
        end

        -- Sanity check supplementaire : notre propre capitale ne doit pas etre marquee
        -- comme appartenant a l'adversaire sauf si l'adversaire vient de gagner.
        -- Protege contre les reverts anti-stale stales (previousOwner = adverse post-victoire)
        -- qui auraient echappe au correctif principal (ex: donnee DB heritee d'une session precedente).
        local ownBaseId = Overlord.Fronts and Overlord.Fronts:GetCapitalId(self.PlayerFaction)
        local ownFixedOwner = self.PlayerFaction
        local ownBase = Overlord.Zones:GetZone(ownBaseId)
        if ownBase and ownBase.owner and ownBase.owner ~= ownFixedOwner then
            local enemyJustWon = vcOnCd and vcWinFac ~= self.PlayerFaction
            if not enemyJustWon then
                -- Notre base est marquee ennemie sans victoire recente de l'adversaire :
                -- donnee stale. updatedAt = 0 laisse la sync corriger l'etat reel.
                ownBase.updatedAt = 0
            end
        end
    end

    ReconcileBaseOwnershipSanity()
    Overlord.Zones:UpdateAvailableZones()
end

-- Sauvegarde l'état actuel dans SavedVariables
local saveDirty = false

-- Parcourt toutes les zones connues, y compris les fronts non actifs.
-- Overlord.ZoneDatabase ne contient que le front actif ; le reset hebdo doit rester global.
local function ForEachKnownZone(callback)
    if not callback then return end
    local seen = {}

    local function visitFront(front)
        if not front or not front.zones then return end
        for _, zone in ipairs(front.zones) do
            if zone and zone.id and not seen[zone.id] then
                seen[zone.id] = true
                callback(zone, front)
            end
        end
    end

    if Overlord.Fronts and Overlord.Fronts.Registry then
        for _, frontId in ipairs(Overlord.Fronts.Order or {}) do
            visitFront(Overlord.Fronts.Registry[frontId])
        end
        for _, front in pairs(Overlord.Fronts.Registry) do
            visitFront(front)
        end
        return
    end

    for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
        if zone and zone.id and not seen[zone.id] then
            seen[zone.id] = true
            callback(zone, nil)
        end
    end
end

function Overlord:SaveState()
    if not OverlordDB then return end
    
    -- Sauvegarde ressources (or, bois, stocks) et bonus actifs
    if Overlord.Ressources then Overlord.Ressources:SaveResources() end
    if Overlord.GuildKeep then Overlord.GuildKeep:SaveKeeps() end
    if Overlord.Fronts then
        OverlordDB.activeFrontId = Overlord.Fronts.activeFrontId
    end

    if not OverlordDB.zones then OverlordDB.zones = {} end
    ForEachKnownZone(function(zone)
        local persisted = self.CaptureLease and self.CaptureLease.GetPersistableView
            and self.CaptureLease:GetPersistableView(zone) or zone
        local localCapture = persisted == zone and zone.holdAuthorityLocal == true
        local localWaveId = localCapture and self.CaptureLease
            and self.CaptureLease.GetWaveId and self.CaptureLease:GetWaveId(zone) or nil
        local witnessRoute = localCapture and localWaveId and self.Sync
            and self.Sync.GetPersistableCaptureNetworkWitnessRoute
            and self.Sync:GetPersistableCaptureNetworkWitnessRoute(zone.id, localWaveId) or nil
        local savedCapturedTime = persisted.capturedTime
        local savedUpdatedAt = persisted.updatedAt or 0
        if persisted.status == "captured" and persisted.owner and savedCapturedTime and savedCapturedTime > 0
            and savedUpdatedAt < savedCapturedTime then
            savedUpdatedAt = savedCapturedTime
        end
        OverlordDB.zones[zone.id] = {
            status = persisted.status,
            killsCurrent = persisted.killsCurrent,
            allyKillsCurrent  = persisted.allyKillsCurrent,
            enemyKillsCurrent = persisted.enemyKillsCurrent,
            holdTimeElapsed = persisted.holdTimeElapsed,
            holdTimeRequired = persisted.holdTimeRequired,
            capturedTime = savedCapturedTime,
            updatedAt = savedUpdatedAt,
            owner = persisted.owner,
            previousOwner = persisted.previousOwner,
            assaultFromAvailable = persisted._assaultFromAvailable and true or nil,
            localCapture = localCapture and true or nil,
            localCaptureWaveId = localWaveId,
            captureNetworkWitnessRouteId = witnessRoute and witnessRoute.routeId or nil,
            captureNetworkWitnessOriginGuid = witnessRoute and witnessRoute.originGuid or nil,
            captureNetworkWitnessBaseline = witnessRoute and witnessRoute.baseline or nil,
            captureNetworkWitnessTargets = witnessRoute and witnessRoute.targets or nil,
        }
    end)
    saveDirty = false
end

-- Sauvegarde différée (pour éviter le spam de saves en combat)
function Overlord:MarkDirty()
    saveDirty = true
end

-- MapIDs du bassin Arathi (champ de bataille), pas les Hautes-Terres warfront : remonter aux parents pour exclure
Overlord.FRONT_EXCLUDED_BATTLEGROUND_MAP_IDS = { [3358] = true, [10440] = true }
-- Compat : ancien nom exporte (memes mapIDs : Bassin d'Arathi BG, pas le warfront monde).
Overlord.ARATHI_BASIN_MAP_IDS = Overlord.FRONT_EXCLUDED_BATTLEGROUND_MAP_IDS
local EXCLUDED_BG_MAP_IDS = Overlord.FRONT_EXCLUDED_BATTLEGROUND_MAP_IDS

-- Vrai si cette carte (ou un parent) est le BG exclu : ne pas activer le système front depuis le champ de bataille
local function IsExcludedWarfrontBattlegroundMap(mapID)
    local seen = {}
    while mapID and mapID > 0 and not seen[mapID] do
        seen[mapID] = true
        if EXCLUDED_BG_MAP_IDS[mapID] then return true end
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if not ok or not info then break end
        mapID = info.parentMapID or 0
    end
    return false
end

-- GetInstanceInfo() renvoie l'InstanceMapID du continent en monde ouvert (0=EK, 1=Kalimdor, ...).
-- Ce n'est pas une phase de rattrapage : seuls les InstanceMapID de phase separee (ex. RPE Arathi) comptent.
local OPEN_WORLD_CONTINENT_INSTANCE_IDS = {
    [0] = true,     -- Eastern Kingdoms
    [1] = true,     -- Kalimdor
    [530] = true,   -- Outland
    [571] = true,   -- Northrend
    [646] = true,   -- Deepholm
    [730] = true,   -- Maelstrom Zone
    [732] = true,   -- Tol Barad
    [860] = true,   -- The Wandering Isle
    [870] = true,   -- Pandaria
    [1064] = true,  -- Isle of Thunder
    [1116] = true,  -- Draenor
    [1191] = true,  -- Ashran
    [1464] = true,  -- Tanaan Jungle
    [1220] = true,  -- Broken Isles
    [1669] = true,  -- Argus
    [1642] = true,  -- Zandalar
    [1643] = true,  -- Kul Tiras
    [1718] = true,  -- Nazjatar
    [2222] = true,  -- The Shadowlands
    [2374] = true,  -- Zereth Mortis
    [2444] = true,  -- Dragon Isles
    [2454] = true,  -- Zaralek Cavern
}

local function IsPhasedCatchUpInstanceID(instID)
    return instID and instID > 0 and not OPEN_WORLD_CONTINENT_INSTANCE_IDS[instID]
end

-- Carte de front sous le joueur (nil si capitale, BG, micro exclue, etc.)
function Overlord:GetPlayerMapFront()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID or not Overlord.Fronts then return nil, mapID end
    if IsExcludedWarfrontBattlegroundMap(mapID) then return nil, mapID end
    return Overlord.Fronts:ResolveFrontByMapID(mapID), mapID
end

-- Raison pour laquelle le front ne s'active pas (nil = devrait etre actif).
-- Retourne aussi front/mapID resolus pour eviter un second GetPlayerMapFront.
function Overlord:GetFrontDetectionBlockReason()
    if self.InstanceSuspended then return "instance_suspended" end
    if IsInInstance() then return "instance" end
    local okInst, _, instType = pcall(GetInstanceInfo)
    if okInst and instType and instType ~= "none" and instType ~= "" then
        return "instance"
    end
    if self:IsInCatchUpPhase() then
        return "catchup"
    end
    if C_Scenario and C_Scenario.IsInScenario and C_Scenario.IsInScenario() then
        return "scenario"
    end
    local front, mapID = self:GetPlayerMapFront()
    if not mapID then return "nomap" end
    if not front then return "notfrontmap" end
    local requiredArtID = front.currentArtID
    if requiredArtID and C_Map.GetMapArtID then
        local okArt, artID = pcall(C_Map.GetMapArtID, mapID)
        if okArt and artID and artID ~= requiredArtID then
            return "artid", front, mapID
        end
    end
    return nil, front, mapID
end

function Overlord:IsPlayerInActiveFront()
    local reason, front = self:GetFrontDetectionBlockReason()
    if reason then
        return false
    end
    if not front then return false end
    if Overlord.Fronts and front.id ~= Overlord.Fronts.activeFrontId then
        Overlord.Fronts:Activate(front.id)
    end
    return true
end

-- Phase de rattrapage : Chromie Time, Party Sync actif, ou phase separee (instanceID hors continent).
function Overlord:IsInCatchUpPhase(allowUnlistedOpenWorldInstance)
    if C_PlayerInfo and C_PlayerInfo.IsPlayerInChromieTime then
        local okCT, inChromieTime = pcall(C_PlayerInfo.IsPlayerInChromieTime)
        if okCT and inChromieTime then return true end
    end
    if C_QuestSession and C_QuestSession.HasJoined then
        local okQS, joined = pcall(C_QuestSession.HasJoined)
        if okQS and joined then return true end
    end
    local ok, _, instType, _, _, _, _, _, instID = pcall(GetInstanceInfo)
    if not ok then return false end
    if instType and instType ~= "none" and instType ~= "" then return false end
    -- Une nouvelle zone exterieure possede souvent un InstanceID avant que la
    -- liste des continents connus soit mise a jour. L'exception 12.1 ne saute
    -- que ce test : Chromie Time et Party Sync restent bloques ci-dessus.
    if allowUnlistedOpenWorldInstance then return false end
    return IsPhasedCatchUpInstanceID(instID)
end

-- Delai de verification avant activation (secondes)
-- IsInInstance retourne false pendant le loading screen du BG - ce delai evite le faux positif
local FRONT_ENTER_DELAY = 1.2

function Overlord:CheckActiveFrontZone()
    if not self.IsInitialized then return end
    if not self._deferredModuleInitDone then
        self._loginFrontCheckDeferred = true
        return
    end
    local wasIn = self.InActiveFront
    local nowIn = self:IsPlayerInActiveFront()

    -- Message unique si carte de front mais phase rattrapage (IsInCatchUpPhase seul matcherait d'autres maps)
    local okMap, playerMapID = pcall(C_Map.GetBestMapForUnit, "player")
    local onFrontMap = okMap and playerMapID and Overlord.Zones:IsWarFrontMapID(playerMapID)
    if not nowIn and onFrontMap and self:IsInCatchUpPhase() then
        if not catchUpNotified then
            catchUpNotified = true
            self:PrintNotification("|cFFFFD100[Overlord]|r " .. (L and L.CATCHUP_PHASE or "Catch-up phase detected."))
        end
    else
        catchUpNotified = false
    end

    if wasIn and not nowIn then
        if pendingFrontEnter then
            pendingFrontEnter:Cancel()
            pendingFrontEnter = nil
        end
        self.InActiveFront = false
        self:OnLeaveFront()
    elseif not wasIn and nowIn then
        -- Delai avant activation : evite le faux positif pendant le chargement du BG Bassin Arathi (map fantome)
        -- Pendant le loading, IsInInstance=false et la map peut etre incoherente.
        -- NE PAS annuler un timer deja en vol : les timers de recuperation post-instance
        -- (SchedulePostInstanceWorldRecovery) appelent CheckActiveFrontZone plusieurs fois a 0.55/1.35/2.8/4.5s,
        -- et chaque annulation+recreation repousserait l'activation de ~1.2s supplementaire
        -- (effet boule de neige : OnEnterFront n'arriverait qu'apres 5-6s au lieu de 1.5s).
        if pendingFrontEnter then return end
        pendingFrontEnter = C_Timer.NewTimer(FRONT_ENTER_DELAY, function()
            pendingFrontEnter = nil
            if not Overlord.IsInitialized then return end
            if Overlord.InstanceSuspended then return end
            local confirmed = Overlord:IsPlayerInActiveFront()
            if confirmed and not Overlord.InActiveFront then
                -- Flags uniquement apres succes : sinon OnEnterFront echoue en boucle avec update actif sans sync/UI.
                local ok, enteredOrErr = pcall(Overlord.OnEnterFront, Overlord)
                if ok and enteredOrErr ~= false then
                    Overlord.InActiveFront = true
                    -- OnEnterFront a appele SetMinimapPinsVisible(true) AVANT que ce flag passe a true :
                    -- EnsureMinimapDriverVisible avait alors re-masque mmFrame (InActiveFront encore false),
                    -- et sans nouveau ZONE_CHANGED les cercles de front ne revenaient pas sans /reload.
                    -- Re-evaluer maintenant que le flag est correct, et rejouer le changement de front :
                    -- si Activate() a masque les anciens pins pendant que InActiveFront etait encore false,
                    -- il faut recreer/forcer les pins du front courant avant de rallumer le driver.
                    if Overlord.MapMarkers then
                        if Overlord.MapMarkers.OnActiveFrontChanged then
                            Overlord.MapMarkers:OnActiveFrontChanged()
                        elseif Overlord.MapMarkers.EnsureMinimapDriverVisible then
                            Overlord.MapMarkers:EnsureMinimapDriverVisible()
                        end
                    end
                    if Overlord.UI and Overlord.UI.RefreshPanelState then
                        Overlord.UI:RefreshPanelState()
                    end
                elseif not ok then
                    self:PrintNotification("|cFFFF0000[Overlord]|r OnEnterFront error: "
                        .. tostring(enteredOrErr))
                end
            elseif not confirmed then
                -- Carte instable au chargement : retenter si le joueur est sur une carte de front.
                local _, mapID = Overlord:GetPlayerMapFront()
                if mapID and Overlord.Zones and Overlord.Zones:IsWarFrontMapID(mapID) then
                    C_Timer.After(2, function()
                        if not Overlord.IsInitialized or Overlord.InstanceSuspended or Overlord.InActiveFront then return end
                        Overlord:CheckActiveFrontZone()
                    end)
                end
            end
        end)
    end
end

function Overlord:OnLeaveFront()
    -- Meme nettoyage qu'en instance : sinon capture locale figee + sync passive bloquee sur ce front.
    if self.ZoneControl and self.ZoneControl.ReleaseLocalCaptureState then
        self.ZoneControl:ReleaseLocalCaptureState()
    end
    CancelRPGroupRetryTicker()
    if self.rpAutoGrouped then
        self.rpAutoGrouped = false
        C_Timer.After(2, function()
            -- Evite LeaveParty si retour front / instance entre-temps (course 2 s)
            if Overlord.InstanceSuspended or Overlord.InActiveFront then return end
            if not IsInGroup() then return end
            pcall(LeaveParty)
        end)
    end
    if self.Sync and self.Sync.ClearRecentFrontSenders then
        self.Sync:ClearRecentFrontSenders()
        if self.Sync.ClearRaidLateJoinCatchUpPending then
            self.Sync:ClearRaidLateJoinCatchUpPending()
        end
    end
    -- Arrete la boucle de mise a jour pour eviter toute consommation CPU hors front
    self:StopUpdateLoop()
    -- Ne pas arreter la domination : elle suit le nombre de zones (SavedVariables) et continue
    -- a tick hors front + BroadcastDomination pour les autres clients.
    if self.MapMarkers and self.MapMarkers.SetMinimapPinsVisible then
        self.MapMarkers:SetMinimapPinsVisible(false)
    end
    if self.UI and self.UI.IsVisible and self.UI.Hide and self.UI:IsVisible() then
        self.UI:Hide(true)  -- true = auto-hide, ne pas ecraser uiVisible pour le retour
    end
    if self.LeaderboardUI then self.LeaderboardUI:Hide() end
    if self.ZoneIndicator then self.ZoneIndicator:Hide() end
    if self.Sync then
        if self.Sync.StopPeriodicChannelSync then self.Sync:StopPeriodicChannelSync() end
        if self.Sync.StopProximityRescan then self.Sync:StopProximityRescan() end
        -- Bascule en sync passive : SR + scan communaute toutes les 2 min (voir Sync.PASSIVE_SYNC_INTERVAL)
        -- Permet de continuer a partager la data meme a Silvermoon ou en donjon
        if self.Sync.StartPassiveSync then self.Sync:StartPassiveSync() end
        -- Rattrapage immediat : etat Loch/Arathi/Gilneas a jour dans le panneau spectateur
        if self.Sync.SendSyncRequest then
            self.Sync:SendSyncRequest()
        end
    end
    if self.Bounty and self.Bounty.OnLeaveFront then
        self.Bounty:OnLeaveFront()
    end
    if self.ManualBounty and self.ManualBounty.OnLeaveFront then
        self.ManualBounty:OnLeaveFront()
    end
    if self.General and self.General.OnLeaveFront then
        self.General:OnLeaveFront()
    end
end

function Overlord:OnEnterFront()
    if not self._deferredModuleInitDone then
        self._loginFrontCheckDeferred = true
        return false
    end
    -- Panneau : suivre le front actif de la carte (sinon la consultation d'un autre front resterait figee apres /reload ou voyage).
    if OverlordDB then
        OverlordDB.config = OverlordDB.config or {}
        OverlordDB.config.uiPanelFrontId = nil
    end
    -- Rattrapage avant toute capture/kill possible dans ce front (voir EnsureLeaderboardCampaignFresh).
    self:EnsureLeaderboardCampaignFresh()
    local baseStateRepaired = ReconcileBaseOwnershipSanity()
    if baseStateRepaired then
        self.Zones:UpdateAvailableZones()
        self:MarkDirty()
    end

    -- Redemarre la boucle OnUpdate (arretee quand on quitte un front)
    self:StartUpdateLoop()
    if self.Bounty and self.Bounty.OnEnterFront then
        self.Bounty:OnEnterFront()
    end
    if self.ManualBounty and self.ManualBounty.OnEnterFront then
        self.ManualBounty:OnEnterFront()
    end
    if self.General and self.General.OnEnterFront then
        self.General:OnEnterFront()
    end
    -- Sync passive (2 min) reste active pour les autres fronts sur la carte monde.
    if self.Sync and self.Sync.StartPassiveSync then self.Sync:StartPassiveSync() end
    if self.UI and self.UI.StopSpectatorMode then self.UI:StopSpectatorMode() end
    C_Timer.After(1, function()
        if not Overlord.InActiveFront or Overlord.InstanceSuspended then return end
        if Overlord.UI and Overlord.UI.PrewarmShardMismatchPopup then
            Overlord.UI:PrewarmShardMismatchPopup()
        end
    end)
    -- Alerte raid version obsolete : a chaque entree de zone Overlord tant que le reseau a
    -- vu une version plus recente que la notre. Delai 1.5s pour laisser au moins un message
    -- reseau arriver (le reload / la premiere entree du jour n'a souvent encore rien recu).
    C_Timer.After(1.5, function()
        if not Overlord.InActiveFront or Overlord.InstanceSuspended then return end
        local newer = Overlord.Sync and Overlord.Sync.GetKnownNewerVersion and Overlord.Sync:GetKnownNewerVersion()
        if not newer or not Overlord.Popups or not Overlord.Popups.ShowOutdatedVersion then return end
        Overlord.Popups:ShowOutdatedVersion(newer)
    end)
    -- Ticker domination : deja actif hors front (idempotent si deja demarre au login)
    if StartDominationTicker then StartDominationTicker() end
    if TryDominationInitialGrant then TryDominationInitialGrant(true) end
    if self.MapMarkers then
        if self.MapMarkers.SetMinimapPinsVisible then
            self.MapMarkers:SetMinimapPinsVisible(true)
        end
        if self.MapMarkers.CheckOutpostMinimap then
            self.MapMarkers:CheckOutpostMinimap()
        end
        self.MapMarkers:ResumeWorldMapOverlays()
    end
    if self.UI and self.UI.Show
        and OverlordDB and OverlordDB.config and OverlordDB.config.uiVisible then
        self.UI:Show({ skipRefresh = true })
        C_Timer.After(0, function()
            if not Overlord.InActiveFront or not Overlord.UI or not Overlord.UI.Refresh then return end
            Overlord.UI:Refresh()
            C_Timer.After(0, function()
                if Overlord.UI and Overlord.UI.RefreshDomination then
                    Overlord.UI:RefreshDomination()
                end
            end)
        end)
    end
    -- Re-join du canal + scan des nameplates deja visibles (sync joueurs hors royaume / hors raid)
    if self.Sync then
        if self.Sync.ResetCommunitySearch then self.Sync:ResetCommunitySearch() end
        if self.Sync.MarkRaidLateJoinCatchUpPending then
            self.Sync:MarkRaidLateJoinCatchUpPending()
        end
        -- Au login JoinChannel PLAYER_LOGIN (+5 s) suffit : evite double join ~3 s + ~5 s.
        if not Overlord._loginChannelPending then
            if self.Sync.JoinChannel then self.Sync:JoinChannel(1) end
        end
        C_Timer.After(2, function()
            if Overlord.InstanceSuspended then return end
            if Overlord.InActiveFront and Overlord.Sync and Overlord.Sync.ProximitySync then
                Overlord.Sync:ProximitySync()
            end
        end)
        -- Cross-realm / cross-faction : SR whisper commu des que C_Club est pret (login sur le front).
        C_Timer.After(6, function()
            if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
            if Overlord.Sync and Overlord.Sync.ScanCommunityMembers then
                Overlord.Sync:ScanCommunityMembers(true)
            end
        end)
        -- Large event : SR whisper vers chef + membre (reponse LK garantie, hors canal 18 %).
        C_Timer.After(4, function()
            if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
            if Overlord.Sync and Overlord.Sync.RequestRaidLeaderboardCatchUp then
                Overlord.Sync:RequestRaidLeaderboardCatchUp()
            end
        end)
        C_Timer.After(18, function()
            if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
            if Overlord.Sync and Overlord.Sync.RequestRaidLeaderboardCatchUpFollowUp then
                Overlord.Sync:RequestRaidLeaderboardCatchUpFollowUp()
            end
        end)
        if self.Sync.StartPeriodicChannelSync then self.Sync:StartPeriodicChannelSync() end
        if self.Sync.StartProximityRescan then self.Sync:StartProximityRescan() end
        -- Guerison active : 15s apres l'entree, on interroge les pairs pour les classes manquantes
        -- accumulees dans les SavedVariables (UNKNOWN venant de C perdus avant le fix CR/CA).
        C_Timer.After(15, function()
            if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
            if Overlord.Sync and Overlord.Sync.HealRequestMissingClassesFromDB then
                Overlord.Sync:HealRequestMissingClassesFromDB()
            end
            if Overlord.Sync and Overlord.Sync.HealRequestMissingGuildsFromDB then
                Overlord.Sync:HealRequestMissingGuildsFromDB()
            end
        end)
        -- Royaume RP : demande de groupe vers joueurs recemment vus en front (cache sync uniquement)
        if self.Sync.IsRPRealm and self.Sync:IsRPRealm() then
            C_Timer.After(3, function()
                if Overlord.InstanceSuspended or not Overlord.InActiveFront then return end
                if IsInGroup() then return end
                if Overlord.Sync and Overlord.Sync.BroadcastRPGroupRequest then
                    Overlord.Sync:BroadcastRPGroupRequest()
                end
            end)
            CancelRPGroupRetryTicker()
            local n = 0
            rpGroupRetryTicker = C_Timer.NewTicker(25, function()
                if Overlord.InstanceSuspended or not Overlord.InActiveFront or IsInGroup() then
                    CancelRPGroupRetryTicker()
                    return
                end
                n = n + 1
                if n > 10 then
                    CancelRPGroupRetryTicker()
                    return
                end
                if Overlord.Sync and Overlord.Sync.BroadcastRPGroupRequest then
                    Overlord.Sync:BroadcastRPGroupRequest()
                end
            end)
        end
    end
end

-- Ticker domination hebdo : toutes les 120s (aligne sur la sync passive hors front).
-- Meme debit qu'avant (300s) : allyCount*120 chaque 120s = allyCount*300 en 300s.
-- Compte les zones par faction (etat local / sync) et accumule des zone-secondes.
local DOMINATION_INTERVAL = 120
local dominationTicker = nil
-- Flag session : le "tick initial" (+1 par zone possedee) ne doit s'executer qu'une
-- seule fois par front. Sans ca, chaque sortie d'instance (StopDominationTicker
-- puis StartDominationTicker) re-credite les zones et la barre de domination gonflait
-- artificiellement pour les joueurs enchainant BG / arene / donjons.
local dominationInitialGrantDone = {}

local function EnsureFrontDominationBucket(frontId)
    if not OverlordDB or not frontId then return nil end
    OverlordDB.frontDominationTime = OverlordDB.frontDominationTime or {}
    local bucket = OverlordDB.frontDominationTime[frontId]
    if not bucket then
        bucket = { Alliance = 0, Horde = 0 }
        OverlordDB.frontDominationTime[frontId] = bucket
    end
    bucket.Alliance = tonumber(bucket.Alliance) or 0
    bucket.Horde = tonumber(bucket.Horde) or 0
    return bucket
end

local function CountFrontOwners(front)
    local allyCount, hordeCount = 0, 0
    if not front or not front.zones then return allyCount, hordeCount end
    local isActiveFront = Overlord.Fronts and front.id == Overlord.Fronts.activeFrontId
    for _, zone in ipairs(front.zones) do
        local owner = nil
        local state = nil
        if isActiveFront then
            state = zone
        elseif Overlord.Fronts and Overlord.Fronts.GetZone then
            -- Front inactif : preferer l'objet zone du registre (mis a jour par sync inactive)
            -- plutot que OverlordDB.zones seul (peut rester une campagne en retard).
            state = select(1, Overlord.Fronts:GetZone(zone.id, front.id))
        end
        -- Quarantaine visuelle bornee (gate login), pas le flag brut : sinon une
        -- carte jamais confirmee par le reseau bloque la domination a vie.
        local loginPending = state and Overlord.IsLoginZoneDisplayPending
            and Overlord:IsLoginZoneDisplayPending(state)
        if state and not loginPending then
            owner = state.owner
        end
        if not state and OverlordDB and OverlordDB.zones and OverlordDB.zones[zone.id] then
            local saved = OverlordDB.zones[zone.id]
            owner = saved.owner
        end
        if owner == "Alliance" then
            allyCount = allyCount + 1
        elseif owner == "Horde" then
            hordeCount = hordeCount + 1
        end
    end
    return allyCount, hordeCount
end

local function CapDominationValue(n)
    n = tonumber(n) or 0
    if n ~= n or n == math.huge or n == -math.huge then return 0 end
    n = math.floor(n)
    if n < 0 then n = 0 end
    local cap = Overlord.DOMINATION_SANITY_CAP or 2147483647
    if n > cap then n = cap end
    return n
end

-- Une valeur de domination >= plafond plausible est corrompue (cap 2^31 atteint, timestamp ayant
-- fuite, etc.). Impossible a distinguer d'un vrai score pour le max() du CRDT, donc indeboulonnable :
-- on la traite comme nulle plutot que de la laisser figer la barre a 50/50.
local function IsCorruptDominationValue(n)
    n = tonumber(n) or 0
    if n ~= n or n == math.huge or n == -math.huge then return true end
    return n >= (Overlord.DOMINATION_PLAUSIBLE_MAX or 1000000000)
end
Overlord.IsCorruptDominationValue = IsCorruptDominationValue

-- Purge les buckets de domination corrompus (valeur aberrante >= plafond plausible). Remet
-- Alliance/Horde a 0 et rearme le compteur de score pour que le front re-accumule proprement.
-- Indispensable car le CRDT max() ne peut jamais corriger une valeur corrompue vers le bas
-- (bug US signale par Croquette : barre figee a 50/50). Retourne le nombre de buckets nettoyes.
function Overlord:SanitizeCorruptDominationBuckets()
    if not OverlordDB or type(OverlordDB.frontDominationTime) ~= "table" then return 0 end
    local healed = 0
    for _, bucket in pairs(OverlordDB.frontDominationTime) do
        if type(bucket) == "table"
            and (IsCorruptDominationValue(bucket.Alliance) or IsCorruptDominationValue(bucket.Horde)) then
            bucket.Alliance = 0
            bucket.Horde = 0
            bucket.scoreSeq = 0
            bucket.scoreSource = ""
            healed = healed + 1
        end
    end
    return healed
end

local function GetDominationScoreSeq()
    return math.floor((time and time() or 0) / DOMINATION_INTERVAL)
end

local function GetDominationScoreSource()
    if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        return Overlord.Sync:GetPlayerFullName() or ""
    end
    return UnitName and (UnitName("player") or "") or ""
end

TryDominationInitialGrant = function(forceConfirmedFront)
    if (not forceConfirmedFront and not Overlord.InActiveFront)
        or not Overlord.Fronts or not Overlord.Fronts.activeFrontId
        or not Overlord.Fronts.Registry or not OverlordDB then
        return
    end
    -- Entree de front / capture locale : peindre tout de suite, sans election.
    if not forceConfirmedFront
        and Overlord.Sync and Overlord.Sync.ShouldAccumulateDomination
        and not Overlord.Sync:ShouldAccumulateDomination() then
        return
    end
    local front = Overlord.Fronts.Registry[Overlord.Fronts.activeFrontId]
    if not front then return end
    local allyCount, hordeCount = CountFrontOwners(front)
    if allyCount + hordeCount <= 0 then return end
    local bucket = EnsureFrontDominationBucket(front.id)
    if not bucket then return end
    local seq = GetDominationScoreSeq()
    local localSeq = math.floor(tonumber(bucket.scoreSeq) or 0)
    local bucketEmpty = (tonumber(bucket.Alliance) or 0)
        + (tonumber(bucket.Horde) or 0) <= 0
    -- Un tick vide (zones encore en quarantaine) ne doit pas figer la barre a 0 %.
    if dominationInitialGrantDone[front.id] and not bucketEmpty then return end
    if localSeq >= seq and not bucketEmpty then return end
    if bucketEmpty then
        bucket.Alliance = CapDominationValue(allyCount)
        bucket.Horde = CapDominationValue(hordeCount)
    else
        bucket.Alliance = CapDominationValue(bucket.Alliance + allyCount)
        bucket.Horde = CapDominationValue(bucket.Horde + hordeCount)
    end
    bucket.scoreSeq = seq
    bucket.scoreSource = GetDominationScoreSource()
    dominationInitialGrantDone[front.id] = true
    Overlord:RecalculateDominationTotals()
    Overlord:MarkDirty()
    if Overlord.UI and Overlord.UI.RefreshDomination then
        Overlord.UI:RefreshDomination()
    end
    if Overlord.Sync and Overlord.Sync.BroadcastDomination then
        Overlord.Sync:BroadcastDomination()
    end
end

-- Capture locale : le premier owner confirme doit peindre la barre (100 % / 0 %).
function Overlord:NotifyDominationOwnersChanged()
    TryDominationInitialGrant(true)
end

function Overlord:RecalculateDominationTotals()
    if not OverlordDB then return 0, 0 end
    OverlordDB.dominationTime = OverlordDB.dominationTime or { Alliance = 0, Horde = 0 }
    -- Point de passage unique (affichage, export, construction des payloads DM) : on guerit ici
    -- tout bucket corrompu pour qu'une valeur aberrante ne soit jamais affichee, exportee ni diffusee.
    self:SanitizeCorruptDominationBuckets()
    local allyTotal, hordeTotal = 0, 0
    for _, bucket in pairs(OverlordDB.frontDominationTime or {}) do
        local bucketAlly = tonumber(bucket.Alliance) or 0
        local bucketHorde = tonumber(bucket.Horde) or 0
        allyTotal = allyTotal + bucketAlly
        hordeTotal = hordeTotal + bucketHorde
    end
    allyTotal = CapDominationValue(allyTotal)
    hordeTotal = CapDominationValue(hordeTotal)
    OverlordDB.dominationTime.Alliance = allyTotal
    OverlordDB.dominationTime.Horde = hordeTotal
    return allyTotal, hordeTotal
end

function Overlord:GetDominationTotals()
    return self:RecalculateDominationTotals()
end

-- Pourcentages affiches (barre UI, export Check PvP) : territorial + journal victoire hebdo.
-- Les depenses bois restent materialisees dans frontDominationTime ; les victoires totales
-- convergent via le journal dominationVictoryEvents et le message reseau VB.
function Overlord:GetDominationDisplayFractions()
    local allyTime, hordeTime = self:GetDominationTotals()
    local allyVictory, hordeVictory = 0, 0
    if self.GetDominationVictoryBonusTotals then
        allyVictory, hordeVictory = self:GetDominationVictoryBonusTotals()
    end
    allyTime = allyTime + allyVictory
    hordeTime = hordeTime + hordeVictory
    local total = allyTime + hordeTime
    if total <= 0 then return 0.5, 0.5 end
    local allyPct = allyTime / total
    if allyPct < 0 then allyPct = 0 end
    if allyPct > 1 then allyPct = 1 end
    return allyPct, 1 - allyPct
end

-- Secondes exportees vers Check PvP : meme ratio que la barre in-game, total zone-secondes inchange.
function Overlord:GetDominationExportSeconds()
    local allyTime, hordeTime = self:GetDominationTotals()
    local total = allyTime + hordeTime
    if total <= 0 then return 0, 0 end
    local allyPct = self:GetDominationDisplayFractions()
    local allyS = math.floor(total * allyPct + 0.5)
    local hordeS = total - allyS
    if hordeS < 0 then hordeS = 0 end
    return CapDominationValue(allyS), CapDominationValue(hordeS)
end

-- Bonus domination bois : secondes de zone persistantes (CRDT max), pas dominationBoostPct.
-- Un overlay % peut sembler « snap back » quand la sync DM passive derive le ratio territorial
-- pendant que le bonus reste en base ; les secondes fusionnent via max() et ne reculent pas.
function Overlord:ApplyWoodDominationBonusSeconds(faction, boostFraction)
    if not OverlordDB or not faction then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    boostFraction = tonumber(boostFraction) or 0
    if boostFraction <= 0 then return false end
    if not Overlord.Fronts or not Overlord.Fronts.Registry then return false end

    local allyTime, hordeTime = self:GetDominationTotals()
    local total = allyTime + hordeTime
    if total <= 0 then return false end

    -- Bonus BORNE : on ajoute simplement (boostFraction x total) secondes a la faction.
    -- On NE resout PLUS "atteindre pile currentPct + boostFraction", car cette formule
    -- (boostSeconds = (targetPct*total - factionTime) / (1 - targetPct)) divise par (1 - targetPct)
    -- et EXPLOSE quand la faction est deja dominante : un seul +1% pouvait ajouter ~100% du total,
    -- et chaque depense s'amplifiait sur un total plus gros -> buckets gonfles a des centaines de
    -- millions -> barre faussee/figee (bug US signale par Nemy/Croquette). Borne = total.
    local bonusSeconds = math.floor(boostFraction * total + 0.5)
    if bonusSeconds > total then bonusSeconds = total end
    if bonusSeconds <= 0 then return false end

    local frontIds = {}
    for frontId, front in pairs(Overlord.Fronts.Registry) do
        local ac, hc = CountFrontOwners(front)
        if ac + hc > 0 then
            frontIds[#frontIds + 1] = frontId
        end
    end
    if #frontIds == 0 then return false end

    local seq = GetDominationScoreSeq()
    local source = GetDominationScoreSource()
    local perFront = math.floor(bonusSeconds / #frontIds)
    local remainder = bonusSeconds - perFront * #frontIds

    for i, frontId in ipairs(frontIds) do
        local bucket = EnsureFrontDominationBucket(frontId)
        if bucket then
            local add = perFront + ((i == 1) and remainder or 0)
            if add > 0 then
                if faction == "Alliance" then
                    bucket.Alliance = CapDominationValue(bucket.Alliance + add)
                else
                    bucket.Horde = CapDominationValue(bucket.Horde + add)
                end
                bucket.scoreSeq = seq
                bucket.scoreSource = source
            end
        end
    end

    self:RecalculateDominationTotals()
    self:MarkDirty()
    return true
end

function Overlord:AccumulatePassiveDominationForInactiveFronts(seconds)
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if Overlord.InActiveFront then return false end
    if not OverlordDB or not Overlord.Fronts or not Overlord.Fronts.Registry then return false end
    seconds = tonumber(seconds) or DOMINATION_INTERVAL
    if seconds <= 0 then return false end
    local seq = GetDominationScoreSeq()
    local source = GetDominationScoreSource()
    local changed = false
    for frontId, front in pairs(Overlord.Fronts.Registry) do
        local bucket = EnsureFrontDominationBucket(frontId)
        if bucket and math.floor(tonumber(bucket.scoreSeq) or 0) < seq then
            local allyCount, hordeCount = CountFrontOwners(front)
            if allyCount + hordeCount > 0 then
                bucket.Alliance = CapDominationValue(bucket.Alliance + allyCount * seconds)
                bucket.Horde = CapDominationValue(bucket.Horde + hordeCount * seconds)
                bucket.scoreSeq = seq
                bucket.scoreSource = source
                changed = true
            end
        end
    end
    if changed then
        Overlord:RecalculateDominationTotals()
        Overlord:MarkDirty()
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
    end
    return changed
end

local function GetVictoryDominationBonus()
    if Overlord.RessourcesConstants and Overlord.RessourcesConstants.VICTORY_DOMINATION_BONUS then
        return Overlord.RessourcesConstants.VICTORY_DOMINATION_BONUS
    end
    return 0.02
end

local function BuildVictoryDominationEventId(frontId, victoryTs)
    frontId = tostring(frontId or ""):gsub("[^%w_%-]", "")
    if frontId == "" then frontId = "front" end
    victoryTs = math.floor(tonumber(victoryTs) or 0)
    return "front-victory-" .. frontId .. "-" .. victoryTs
end

-- Accorde +2 % domination via journal d'evenements persistant (VB reseau).
-- broadcastSync : true uniquement pour l'emetteur local (evite le spam VB depuis chaque recepteur TV).
function Overlord:TryGrantVictoryDominationBonus(frontId, faction, victoryTs, broadcastSync)
    if not broadcastSync then
        -- Recepteurs TV/sync : convergence via VB (secondes exactes de l'emetteur).
        return true
    end
    if not OverlordDB or not faction or not victoryTs or victoryTs <= 0 then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    frontId = frontId or ""

    local allyTerr, hordeTerr = self:GetDominationTotals()
    local allyVict, hordeVict = 0, 0
    if self.GetDominationVictoryBonusTotals then
        allyVict, hordeVict = self:GetDominationVictoryBonusTotals()
    end
    local totalAtApply = allyTerr + hordeTerr + allyVict + hordeVict
    if totalAtApply <= 0 then return false end

    local bonus = GetVictoryDominationBonus()
    local bonusSeconds = math.floor(bonus * totalAtApply + 0.5)
    if bonusSeconds > totalAtApply then bonusSeconds = totalAtApply end
    if bonusSeconds <= 0 then return false end

    local campaignEpoch = (self.GetCurrentCampaignStartTs and self:GetCurrentCampaignStartTs())
        or tonumber(OverlordDB.lastResetTimestamp) or 0
    if campaignEpoch <= 0 then return false end

    local eventId = BuildVictoryDominationEventId(frontId, victoryTs)
    local ok, reason = self:ApplyDominationVictoryBonusEvent({
        eventId = eventId,
        frontId = frontId,
        faction = faction,
        victoryTs = victoryTs,
        bonusSeconds = bonusSeconds,
        totalAtApply = totalAtApply,
        campaignEpoch = campaignEpoch,
        source = "local_emitter",
    }, { localEmitter = true })
    if not ok then return false end
    if reason == "pending" then return false end

    if reason == "applied" and faction == self.PlayerFaction then
        local L = self.L
        if L and L.VICTORY_DOMINATION_BONUS then
            local pctDisplay = math.floor(bonus * 100 + 0.5)
            self:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.VICTORY_DOMINATION_BONUS, pctDisplay))
        end
    end
    return ok
end

local function DominationTick()
    if Overlord.InstanceSuspended or not Overlord.IsInitialized
        or not OverlordDB or not OverlordDB.dominationTime then
        return
    end
    -- Accumulation locale uniquement sur le disque du front (owners live sync).
    -- Hors front (ville, instance) : pas de tick local ; convergence par DM/SR/passive sync.
    if not Overlord.InActiveFront then
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
        return
    end
    if not Overlord.Fronts or not Overlord.Fronts.activeFrontId or not Overlord.Fronts.Registry then return end
    local shouldAccumulate = Overlord.Sync and Overlord.Sync.ShouldAccumulateDomination
        and Overlord.Sync:ShouldAccumulateDomination()
    local front = Overlord.Fronts.Registry[Overlord.Fronts.activeFrontId]
    local changed = false
    if shouldAccumulate and front then
        local allyCount, hordeCount = CountFrontOwners(front)
        local bucket = EnsureFrontDominationBucket(front.id)
        local seq = GetDominationScoreSeq()
        if bucket and math.floor(tonumber(bucket.scoreSeq) or 0) < seq then
            bucket.Alliance = CapDominationValue(bucket.Alliance + allyCount * DOMINATION_INTERVAL)
            bucket.Horde = CapDominationValue(bucket.Horde + hordeCount * DOMINATION_INTERVAL)
            bucket.scoreSeq = seq
            bucket.scoreSource = GetDominationScoreSource()
            changed = true
        end
    end
    if changed then
        Overlord:RecalculateDominationTotals()
        Overlord:MarkDirty()
    end
    if shouldAccumulate and Overlord.Sync then
        Overlord.Sync:BroadcastDomination()
    end
    if Overlord.UI and Overlord.UI.RefreshDomination then
        Overlord.UI:RefreshDomination()
    end
end

StartDominationTicker = function()
    -- Idempotent : ne pas recreer le ticker (evite double accumulation au OnEnterFront)
    if dominationTicker then return end
    if not OverlordDB or not OverlordDB.dominationTime then return end
    -- Tick initial leger : 1 zone-seconde par zone pour peindre la barre tout de suite.
    -- Execute une seule fois par front : les sorties d'instance rappellent cette
    -- fonction et re-accumulaient ces secondes, gonflant la domination sans jouer.
    local activeFrontId = Overlord.Fronts and Overlord.Fronts.activeFrontId
    if activeFrontId and not dominationInitialGrantDone[activeFrontId] then
        TryDominationInitialGrant()
    end
    dominationTicker = C_Timer.NewTicker(DOMINATION_INTERVAL, DominationTick)
end

StopDominationTicker = function()
    if dominationTicker then
        dominationTicker:Cancel()
        dominationTicker = nil
    end
end

local REMOTE_OBSERVER_INTERVAL = 0.5

-- Boucle de mise à jour principale (C_Timer = 1 tick/s, plus sain que OnUpdate a chaque frame)
local updateTicker = nil
local frontTickPhase = 0
local truceExpireTicker = nil
-- Guild Keep : ticker independant du front actif (captures / stale observers)
local guildKeepTicker = nil
-- Interpolation des minuteurs (capture ennemie a distance), ~4 Hz ; ZoneControl:Update reste a 1/s.
local remoteObserverTicker = nil
local remoteObserverState = {
    lastTick = nil,
    zoneList = nil,
    zoneListFrontId = nil,
    zoneListBuiltAt = 0,
}
local REMOTE_OBSERVER_LIST_REBUILD_SEC = 2.0

local function GetRemoteObserverZones(frontIdOverride)
    local frontId = frontIdOverride
    if frontId == nil then
        frontId = Overlord.Fronts and Overlord.Fronts.activeFrontId
    end
    local now = GetTime()
    if remoteObserverState.zoneList and remoteObserverState.zoneListFrontId == frontId
        and (now - remoteObserverState.zoneListBuiltAt) < REMOTE_OBSERVER_LIST_REBUILD_SEC then
        return remoteObserverState.zoneList
    end
    local list = {}
    local zones = (frontId and Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront)
        and Overlord.Zones:GetDisplayOrderForFront(frontId) or Overlord.ZoneDatabase
    if zones then
        for _, zone in ipairs(zones) do
            if zone.status == "in_progress" and not zone.isHolding then
                list[#list + 1] = zone
            end
        end
    end
    remoteObserverState.zoneList = list
    remoteObserverState.zoneListFrontId = frontId
    remoteObserverState.zoneListBuiltAt = now
    return list
end

function Overlord:GetRemoteObserverZones(frontIdOverride)
    return GetRemoteObserverZones(frontIdOverride)
end

local function RunGuildKeepTick(deltaTime)
    if not Overlord.IsInitialized or Overlord.InstanceSuspended then return end
    deltaTime = math.max(0, math.min(tonumber(deltaTime) or 1, 3))
    -- Filet de fraicheur campagne (1 Hz, cout negligible : quelques comparaisons, pas de boucle).
    -- Ce tick tourne en continu des le login independamment du front actif ; auparavant,
    -- EnsureLeaderboardCampaignFresh n'etait cablee que sur OnEnterFront (transition de zone), donc
    -- un joueur qui reste plante dans le meme front toute la semaine n'avait plus aucun rattrapage
    -- si ScheduleNextReset venait a se desarmer (voir regression ladder NA non resete).
    Overlord:EnsureLeaderboardCampaignFresh()
    if Overlord.GuildKeep then
        Overlord.GuildKeep:TickMaintenance()
        if Overlord.Leaderboard and Overlord.Leaderboard.MaybeAwardGuildKeepDailyWins then
            Overlord.Leaderboard:MaybeAwardGuildKeepDailyWins()
        end
        if Overlord.Popups and Overlord.Popups.TryShowGuildKeepSiegeReminder then
            Overlord.Popups:TryShowGuildKeepSiegeReminder()
        end
        if Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.Tick then
            Overlord.GuildKeepImmersion:Tick()
        end
    end
    local onOutpost, curOutpostSite = false, nil
    if Overlord.Outpost and Overlord.Outpost.IsPlayerOnOutpostMap then
        onOutpost, curOutpostSite = Overlord.Outpost:IsPlayerOnOutpostMap()
        if onOutpost then Overlord.Outpost:TickMaintenance() end
    end
    if Overlord.MapMarkers and Overlord.MapMarkers.CheckOutpostMinimap
        and onOutpost ~= (Overlord.MapMarkers._mmOutpostMapActive == true) then
        -- Detecte aussi l'entree/sortie Party Sync ou Chromie Time sans changement de carte.
        Overlord.MapMarkers:CheckOutpostMinimap()
    end
    if Overlord.GuildKeepControl and Overlord.GuildKeep then
        local onKeep, curKeepSite, keepMapSampleKnown = Overlord.GuildKeep:IsPlayerOnKeepMap()
        if Overlord.Shard and Overlord.Shard.SyncLocalContext then
            Overlord.Shard:SyncLocalContext()
            if Overlord.Shard.localContextKey ~= "" and Overlord.Shard.lastScanAttemptAt == 0 then
                Overlord.Shard:Update()
            end
        end
        if onKeep then
            Overlord.GuildKeepControl:Update(deltaTime)
            local excludeKey = curKeepSite and curKeepSite.siteKey
            if not Overlord.GuildKeepControl.HasLocalAuthority
                or Overlord.GuildKeepControl:HasLocalAuthority(excludeKey) then
                Overlord.GuildKeepControl:TickOffMapAuthority(
                    deltaTime, curKeepSite and curKeepSite.siteKey)
            end
        else
            -- Un nil/0,0 C_Map n'est pas une sortie : geler le timer ce tick.
            -- Seule une carte connue differente autorise le decay hors fortin.
            if keepMapSampleKnown then
                if Overlord.GuildKeepControl.OnKnownKeepMapExit then
                    Overlord.GuildKeepControl:OnKnownKeepMapExit()
                end
                if not Overlord.GuildKeepControl.HasLocalAuthority
                    or Overlord.GuildKeepControl:HasLocalAuthority() then
                    Overlord.GuildKeepControl:TickOffMapAuthority(deltaTime)
                end
            end
            if not Overlord.InActiveFront and Overlord.ZoneIndicator
                and Overlord.ZoneIndicator.SyncGuildKeepCaptureHud
                and Overlord.ZoneIndicator.GuildKeepHudNeedsRefresh
                and Overlord.ZoneIndicator:GuildKeepHudNeedsRefresh() then
                Overlord.ZoneIndicator:SyncGuildKeepCaptureHud()
            end
        end
    end
    -- Les avant-postes de front restent sur le tick de front a 1 Hz. Le site
    -- temporaire des Vaults doit continuer a capturer/decroitre hors front.
    if not Overlord.InActiveFront and Overlord.OutpostControl and Overlord.Outpost then
        if onOutpost then
            Overlord.OutpostControl:Update(deltaTime)
            local excludeKey = curOutpostSite and curOutpostSite.siteKey
            if Overlord.OutpostControl:HasLocalAuthority(excludeKey) then
                Overlord.OutpostControl:TickOffMapAuthority(deltaTime, excludeKey)
            end
        else
            if Overlord.OutpostControl:HasLocalAuthority() then
                Overlord.OutpostControl:TickOffMapAuthority(deltaTime)
            end
            if Overlord.ZoneIndicator and Overlord.ZoneIndicator.SyncOutpostCaptureHud
                and Overlord.ZoneIndicator.OutpostHudNeedsRefresh
                and Overlord.ZoneIndicator:OutpostHudNeedsRefresh() then
                Overlord.ZoneIndicator:SyncOutpostCaptureHud()
            end
        end
    end
end

function Overlord:StartGuildKeepLoop()
    if guildKeepTicker then guildKeepTicker:Cancel() end
    local lastTickAt = GetTime()
    guildKeepTicker = C_Timer.NewTicker(1, function()
        local now = GetTime()
        local deltaTime = now - lastTickAt
        lastTickAt = now
        local ok, err = pcall(RunGuildKeepTick, deltaTime)
        if not ok and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
            print("|cFFFF4444[Overlord:dbg]|r GuildKeep ticker: " .. tostring(err))
        end
    end)
end

function Overlord:StopGuildKeepLoop()
    if guildKeepTicker then
        guildKeepTicker:Cancel()
        guildKeepTicker = nil
    end
end

local function RunFrontMidTick()
    if not Overlord.InActiveFront then return end
    if Overlord.OutpostControl and Overlord.Outpost then
        local onOutpost, curSite = Overlord.Outpost:IsPlayerOnOutpostMap()
        if onOutpost then
            Overlord.OutpostControl:Update(1)
            local excludeKey = curSite and curSite.siteKey
            if Overlord.OutpostControl:HasLocalAuthority(excludeKey) then
                Overlord.OutpostControl:TickOffMapAuthority(1, excludeKey)
            end
        else
            if Overlord.OutpostControl:HasLocalAuthority() then
                Overlord.OutpostControl:TickOffMapAuthority(1)
            end
            if Overlord.ZoneIndicator and Overlord.ZoneIndicator.SyncOutpostCaptureHud
                and Overlord.ZoneIndicator.OutpostHudNeedsRefresh
                and Overlord.ZoneIndicator:OutpostHudNeedsRefresh() then
                Overlord.ZoneIndicator:SyncOutpostCaptureHud()
            end
        end
    end
    if Overlord.UI and Overlord.UI.Update then Overlord.UI:Update() end
end

local function RunFrontLateIndicatorTick()
    if not Overlord.InActiveFront then return end
    if Overlord:IsPlayerDeadOrGhost() then return end
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.FrontLateIndicatorNeedsRefresh
        and not Overlord.ZoneIndicator:FrontLateIndicatorNeedsRefresh() then
        return
    end
    if Overlord.ZoneIndicator then
        if Overlord.ZoneIndicator.RefreshHud then
            Overlord.ZoneIndicator:RefreshHud()
        else
            Overlord.ZoneIndicator:UpdateIndicator()
        end
    end
end

function Overlord:StartUpdateLoop()
    if updateTicker then updateTicker:Cancel() end
    if truceExpireTicker then
        truceExpireTicker:Cancel()
        truceExpireTicker = nil
    end
    if remoteObserverTicker then remoteObserverTicker:Cancel() end
    remoteObserverState.lastTick = GetTime()
    remoteObserverTicker = C_Timer.NewTicker(REMOTE_OBSERVER_INTERVAL, function()
        if not Overlord.InActiveFront then return end
        local zones = GetRemoteObserverZones()
        if #zones == 0 then
            -- Garder la base de temps fraiche sans executer le chemin interpolation.
            remoteObserverState.lastTick = GetTime()
            return
        end
        local now = GetTime()
        local dt = math.max(0.001, math.min(now - remoteObserverState.lastTick, 1.5))
        remoteObserverState.lastTick = now
        if Overlord.ZoneControl and Overlord.ZoneDatabase then
            local zc = Overlord.ZoneControl
            for _, zone in ipairs(zones) do
                zc:TickRemoteObserverZone(zone, dt)
            end
        end
    end)
    truceExpireTicker = C_Timer.NewTicker(30, function()
        if Overlord.IsInitialized and not Overlord.InstanceSuspended
            and Overlord.Zones and Overlord.Zones.TryExpireFrontTruces then
            Overlord.Zones:TryExpireFrontTruces()
        end
    end)

    frontTickPhase = 0
    updateTicker = C_Timer.NewTicker(1 / 3, function()
        if not Overlord.InActiveFront then return end
        -- Un seul ticker a 0.33s : remplace 1 Hz + 2x C_Timer.After / s.
        frontTickPhase = frontTickPhase + 1
        if frontTickPhase == 1 then
            if Overlord.ZoneControl then Overlord.ZoneControl:Update(1) end
        elseif frontTickPhase == 2 then
            RunFrontMidTick()
        else
            RunFrontLateIndicatorTick()
            frontTickPhase = 0
        end
    end)
end

function Overlord:StopUpdateLoop()
    if updateTicker then
        updateTicker:Cancel()
        updateTicker = nil
    end
    if truceExpireTicker then
        truceExpireTicker:Cancel()
        truceExpireTicker = nil
    end
    if remoteObserverTicker then
        remoteObserverTicker:Cancel()
        remoteObserverTicker = nil
    end
    remoteObserverState.lastTick = nil
end

-- Reset complet de toutes les zones
function Overlord:ResetAll()
    -- updatedAt = 0 : permet d'accepter toute donnee sync entrante apres un reset.
    -- Avant : updatedAt = time() bloquait les donnees dont le timestamp etait anterieur
    -- au moment du reset, ce qui empechait les nouveaux joueurs de recevoir l'etat des zones.
    ForEachKnownZone(function(zone)
        if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
            Overlord.CaptureLease:Complete(zone)
        end
        if Overlord.Zones and Overlord.Zones.ClearCaptureFinalUnattestedState then
            Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
        end
        zone.killsCurrent      = 0
        zone.allyKillsCurrent  = 0
        zone.enemyKillsCurrent = 0
        zone.holdTimeElapsed = 0
        zone.isHolding = false
        zone.isContested = false
        zone.isPaused = false
        zone.holdStartTime = nil
        zone.capturedTime = nil
        zone.previousOwner = nil
        zone.owner = nil
        zone.updatedAt = 0
        zone.holdTimeRequired = 120
    end)

    -- Restaure les bases de chaque faction (les deux, visibles par tous)
    -- Timestamp canonique du reset hebdo : tous les clients doivent produire le
    -- meme certificat initial, meme s'ils executent ResetAll a quelques secondes d'ecart.
    local now = (self.GetCurrentCampaignStartTs and self:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or time()
    ForEachKnownZone(function(zone)
        local fixedOwner = Overlord.Zones and Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
        if fixedOwner then
            zone.owner = fixedOwner
            zone.capturedTime = now
            zone.updatedAt = now
        end
    end)

    local pf = self.PlayerFaction
    ForEachKnownZone(function(zone)
        if zone.owner == pf then
            zone.status = "captured"
        else
            zone.status = "locked"
        end
    end)

    -- Rend les premiers objectifs disponibles sur chaque front, pas seulement le front actif.
    -- UpdateAvailableZones recalculera ensuite plus finement le front actif.
    if Overlord.Fronts and Overlord.Fronts.Registry then
        for _, front in pairs(Overlord.Fronts.Registry) do
            if front and front.zones then
                local prereqs = front.prereqs and front.prereqs[pf]
                for _, zone in ipairs(front.zones) do
                    if zone.owner ~= pf then
                        local prereqIds = prereqs and prereqs[zone.id]
                        local available = prereqIds ~= nil
                        if available then
                            for _, prereqId in ipairs(prereqIds) do
                                local prereq = Overlord.Fronts:GetZone(prereqId, front.id)
                                if not prereq or prereq.owner ~= pf or prereq.status ~= "captured" then
                                    available = false
                                    break
                                end
                            end
                        end
                        zone.status = available and "available" or "locked"
                    end
                end
            end
        end
    end
    
    Overlord.Zones:UpdateAvailableZones()
    -- Reset ressources (or, bois, stocks) et bonus actifs
    if Overlord.Ressources then Overlord.Ressources:ResetResources() end
    if Overlord.GuildKeep then Overlord.GuildKeep:ResetKeepsForCampaign() end
    if Overlord.Outpost then Overlord.Outpost:ResetOutpostsForCampaign() end
    OverlordDB.dominationTime    = { Alliance = 0, Horde = 0 }
    OverlordDB.frontDominationTimeByPool =
        OverlordDB.frontDominationTimeByPool or {}
    local resetDominationPool = GetCurrentPoolForSavedVars()
    OverlordDB.frontDominationTimeByPool.global = {}
    for _, oldPool in ipairs({ "fr", "eu", "de", "us", "na" }) do
        OverlordDB.frontDominationTimeByPool[oldPool] = nil
    end
    OverlordDB.frontDominationTime =
        OverlordDB.frontDominationTimeByPool[resetDominationPool]
    dominationInitialGrantDone = {}
    OverlordDB.victoryDominationBonusLastTs = nil
    OverlordDB.dominationVictoryEvents = OverlordDB.dominationVictoryEvents or { byPool = {} }
    OverlordDB.dominationVictoryEvents.byPool =
        OverlordDB.dominationVictoryEvents.byPool or {}
    for _, oldPool in ipairs({ "fr", "eu", "de", "us", "na" }) do
        OverlordDB.dominationVictoryEvents.byPool[oldPool] = nil
    end
    OverlordDB.dominationVictoryEvents.byPool.global = nil
    OverlordDB.lastCampaignStats = nil
    if Overlord.Zones and Overlord.Zones.ClearFrontVictories then
        Overlord.Zones:ClearFrontVictories()
    end
    if self.General and self.General.OnCampaignReset then
        self.General:OnCampaignReset()
    end
    if self.ManualBounty and self.ManualBounty.OnCampaignReset then
        self.ManualBounty:OnCampaignReset()
    end
    if self.ManualBountySync and self.ManualBountySync.OnCampaignReset then
        self.ManualBountySync:OnCampaignReset()
    end
    -- campaignId : recalcule dans CheckWeeklyReset via SyncCampaignIdWithCurrentWeek (date AAAAMMJJ).
    self:SaveState()
    if self.Sync and self.Sync.ResetVictoryFlag then
        self.Sync:ResetVictoryFlag()
    end
    if self.UI and self.UI.Refresh then self.UI:Refresh() end
    -- CheckWeeklyReset s'execute avant UI:Initialize au login : Refresh() ne peint pas la domination.
    -- Apres init + au prochain tick, forcer la barre (largeur / fills) sans attendre un hover.
    C_Timer.After(0, function()
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
    end)

    -- Repaint immediat des cercles carte / pins minimap (sinon attente du prochain OnUpdate carte).
    if self.MapMarkers then
        pcall(function()
            if self.MapMarkers.ResumeWorldMapOverlays then
                self.MapMarkers:ResumeWorldMapOverlays()
            end
            if self.MapMarkers.UpdateMinimapPins then
                self.MapMarkers:UpdateMinimapPins()
            end
        end)
    end

    self:PrintNotification("|cFF00FF00[Overlord]|r " .. L.ALL_ZONES_RESET)
end

-- Sauvegarde automatique toutes les 30s (ou immédiate si dirty)
local autoSaveTickCount = 0
function Overlord:RunAutoSaveTick()
    -- IsInitialized passe vrai avant les sanitizers requis. Persister pendant leur
    -- construction pourrait serialiser des racines partiellement migrees et rendre
    -- la reprise /reload non idempotente : le ticker reste arme mais dort jusqu'au
    -- commit global du pipeline login.
    if not self.IsInitialized or not self._deferredModuleInitDone then return false end
    -- WoW 12.0.5 : ne pas sauvegarder en instance (evite taint)
    if self.InstanceSuspended then return false end
    if saveDirty then self:SaveState() end
    if self.Leaderboard and self.Leaderboard.leaderboardDirty then
        self.Leaderboard:Save()
    end
    -- Snapshot complet du classement toutes les ~2 min (filet anti-perte), mais
    -- seulement apres mutation. Le top 150 utilise un tas a allocations bornees.
    autoSaveTickCount = autoSaveTickCount + 1
    if autoSaveTickCount % 4 == 0
        and self.Leaderboard and self.Leaderboard.SnapshotCurrentCampaignFull
        and self.Leaderboard._snapshotDirty ~= false
        and not (InCombatLockdown and InCombatLockdown()) then
        self.Leaderboard:SnapshotCurrentCampaignFull()
    end
    return true
end

local function StartAutoSave()
    C_Timer.NewTicker(30, function()
        Overlord:RunAutoSaveTick()
    end)
end

-- Masque le HUD Overlord en haut quand le joueur est mort/fantome : sinon les panneaux
-- (stratum HIGH + souris active) recouvrent le bouton Blizzard « Retour au cimetiere ».
local ghostHudSuppressed = false

function Overlord:IsPlayerDeadOrGhost()
    return (UnitIsDead and UnitIsDead("player")) or (UnitIsGhost and UnitIsGhost("player"))
end

function Overlord:ApplyGhostHudLayout()
    local deadOrGhost = self:IsPlayerDeadOrGhost()
    if deadOrGhost and not ghostHudSuppressed then
        ghostHudSuppressed = true
        if Overlord.Ressources and Overlord.Ressources.SuppressForGhost then
            Overlord.Ressources:SuppressForGhost()
        end
        if Overlord.ZoneIndicator and Overlord.ZoneIndicator.SuppressForGhost then
            Overlord.ZoneIndicator:SuppressForGhost()
        end
    elseif not deadOrGhost and ghostHudSuppressed then
        ghostHudSuppressed = false
        if Overlord.Ressources and Overlord.Ressources.RestoreAfterGhost then
            Overlord.Ressources:RestoreAfterGhost()
        end
        if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RestoreAfterGhost then
            Overlord.ZoneIndicator:RestoreAfterGhost()
        end
    end
end

-- Event handlers
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
-- Re-check quand le joueur active/desactive le mode guerre
pcall(function() eventFrame:RegisterEvent("LOADING_SCREEN_ENABLED") end)
pcall(function() eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD") end)
pcall(function() eventFrame:RegisterEvent("WAR_MODE_STATUS_UPDATE") end)
pcall(function() eventFrame:RegisterEvent("PARTY_INVITE_REQUEST") end)
pcall(function() eventFrame:RegisterEvent("PLAYER_FACTION_CHANGED") end)
pcall(function() eventFrame:RegisterEvent("PLAYER_UNGHOST") end)
pcall(function() eventFrame:RegisterEvent("UNIT_PHASE") end)

eventFrame:SetScript("OnEvent", function(_, event, ...)

    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "Overlord" then
            Overlord:Initialize()
            -- Creer le bouton avant PLAYER_LOGIN : un button-bag charge avant
            -- Overlord peut scanner les globals dans son propre handler
            -- PLAYER_LOGIN avant que le notre ne soit appele. Minimap et la DB
            -- sont deja disponibles ici; les appels PLAYER_LOGIN/+3 s restent
            -- des rattrapages idempotents.
            if Minimap and Overlord.MapMarkers
                and Overlord.MapMarkers.CreateMinimapButton then
                Overlord.MapMarkers:CreateMinimapButton()
            end
            eventFrame:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
        Overlord._loginChannelPending = true
        StartAutoSave()
        Overlord:ScheduleNextReset()

        -- Rattrapage idempotent si ADDON_LOADED a rencontre une UI minimap
        -- exceptionnellement indisponible. Les pins et overlays restent differes a +3 s.
        if Minimap and Overlord.MapMarkers
            and Overlord.MapMarkers.CreateMinimapButton then
            Overlord.MapMarkers:CreateMinimapButton()
        end

        C_Timer.After(3, function()
            if Overlord.InstanceSuspended then return end
            Overlord.Zones:CalcMapAspect()
            if Overlord.MapMarkers then
                Overlord.MapMarkers:Initialize()
            end
        end)

        -- Le demarrage reseau est volontairement absent des timers PLAYER_LOGIN :
        -- LoginSync ci-dessus ne s'execute qu'apres toutes les barrieres requises.

        C_Timer.After(2.5, function()
            if Overlord.InstanceSuspended then return end
            Overlord:CheckActiveFrontZone()
            if Overlord.InActiveFront and OverlordDB and OverlordDB.config
                and OverlordDB.config.uiVisible and Overlord.UI and Overlord.UI.Show then
                Overlord.UI:Show({ skipRefresh = true })
                Overlord:ScheduleLoginUiFullRefresh(0.4)
            end
        end)

        C_Timer.After(3.5, function()
            Overlord:RunOrDeferLoginPopup("login")
        end)

        C_Timer.After(8, function()
            Overlord:RunOrDeferLoginPopup("daily")
        end)

    elseif event == "LOADING_SCREEN_ENABLED" or event == "PLAYER_LEAVING_WORLD" then
        -- Derniere fenetre avant qu'IsInInstance() bloque tous les transports :
        -- liberer explicitement les baux distants, sans attendre un rewrite final.
        Overlord:RunOrDeferCaptureRelease()
    elseif event == "PLAYER_FACTION_CHANGED" then
        -- Coalescer pendant les sanitizers puis propager les alias en coroutine.
        -- Aucun scan du classement ni envoi reseau ne tourne dans ce callback event.
        Overlord:RequestFactionChangeReconcile()

    elseif event == "PLAYER_LOGOUT" then
        if Overlord.General and Overlord.General.PersistSession then
            Overlord.General:PersistSession()
        end
        -- Position du panel : derniere ecriture avant fermeture des SavedVariables
        if Overlord.UI and Overlord.UI.PersistPanelPosition then
            Overlord.UI:PersistPanelPosition()
        end
        -- Sauvegarde faction + timestamp pour detecter changement Horde<->Alliance et donnees obsoletes
        if OverlordDB then
            if Overlord.PlayerFaction then
                OverlordDB.lastSessionFaction = Overlord.PlayerFaction
            end
            OverlordDB.lastSessionTimestamp = time()
        end
        if Overlord.Shard and Overlord.Shard.PersistGuildKeepReloadShardLease then
            Overlord.Shard:PersistGuildKeepReloadShardLease()
        end
        if Overlord.Popups and Overlord.Popups.CommitPendingPopupMark then
            Overlord.Popups:CommitPendingPopupMark()
        end
        if Overlord.Popups and Overlord.Popups.PersistSeenFlags then
            Overlord.Popups:PersistSeenFlags()
        end
        Overlord:SaveState()
        if Overlord.Leaderboard then
            -- Un snapshot tranche ne peut pas terminer apres PLAYER_LOGOUT. Le dernier
            -- snapshot autosave complet reste intact ; Save() persiste les buckets courants.
            Overlord.Leaderboard:Save()
        end
    elseif event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        if event == "PLAYER_DEAD" and Overlord.ZoneControl
            and Overlord.ZoneControl.ReleaseLocalCaptureState then
            -- Fermer la vague avant tout ZS/ZA recu ensuite. Attendre la
            -- decroissance LOSING laissait un echo finaliser l'abandon.
            Overlord.ZoneControl:ReleaseLocalCaptureState(true)
        end
        Overlord:ApplyGhostHudLayout()
    elseif event == "UNIT_PHASE" then
        local unit = ...
        if unit == "player" and Overlord.Shard and Overlord.Shard.InvalidateLocalContext then
            -- Un hop de phase peut garder la meme map : invalider avant tout prochain tick/GA.
            Overlord.Shard:InvalidateLocalContext()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" or event == "WAR_MODE_STATUS_UPDATE" then
        local restoredReloadShard = false
        if event == "PLAYER_ENTERING_WORLD" and Overlord.Shard
            and Overlord.Shard.RestoreGuildKeepReloadShardLease then
            local _, isReloadingUi = ...
            restoredReloadShard = Overlord.Shard:RestoreGuildKeepReloadShardLease(
                isReloadingUi == true)
        end
        if event ~= "WAR_MODE_STATUS_UPDATE" and not restoredReloadShard and Overlord.Shard
            and Overlord.Shard.InvalidateLocalContext then
            Overlord.Shard:InvalidateLocalContext()
        end
        if event == "WAR_MODE_STATUS_UPDATE"
            and Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
            -- Masquer / reafficher les markers carte monde sans attendre le prochain tick 2 Hz.
            Overlord.MapMarkers:RequestOverlayRefresh()
        end
        local inInstance = IsInInstance()
        -- Filet de securite GetInstanceInfo() UNIQUEMENT quand on n'est pas deja suspendu :
        -- sert a detecter l'entree en instance quand IsInInstance() est brievement faux pendant le loading.
        -- Quand on est DEJA suspendu (ex. sortie d'arene), on ne fait PAS ce check :
        -- GetInstanceInfo() peut rester "arena"/"pvp" quelques instants apres le chargement
        -- du monde ouvert, ce qui forcerait inInstance=true, appellerait SuspendForInstance()
        -- (qui annule tous les timers et retourne), et bloquerait indefiniment la reprise.
        -- ResumeFromInstance() gere deja ce cas via ses propres retry timers (0.35/0.95/2.0s).
        if not inInstance and not Overlord.InstanceSuspended then
            local okInst, _, instType = pcall(GetInstanceInfo)
            if okInst and instType and instType ~= "none" and instType ~= "" then
                inInstance = true
            end
        end
        if inInstance then
            Overlord:SuspendForInstance()
        else
            Overlord:ResumeFromInstance()
            -- CheckActiveFrontZone uniquement si le resume a reussi (InstanceSuspended=false).
            -- Si le resume est differe (GetInstanceInfo encore "arena"), IsPlayerInActiveFront()
            -- retourne false (car elle verifie aussi GetInstanceInfo), ce qui declencherait
            -- OnLeaveFront() a tort et cacherait la minimap / setterait InActiveFront=false.
            -- ResumeFromInstance() appelle lui-meme CheckActiveFrontZone quand il reussit.
            if not Overlord.InstanceSuspended then
                Overlord:CheckActiveFrontZone()
                if Overlord.UI and Overlord.UI.RefreshPanelState then
                    Overlord.UI:RefreshPanelState()
                end
            end
        end
        if event == "PLAYER_ENTERING_WORLD" then
            Overlord:FinalizeCaptureReleaseAfterWorldEntry(inInstance)
        end
        Overlord:ApplyGhostHudLayout()
    elseif event == "PARTY_INVITE_REQUEST" then
        if Overlord.Sync and Overlord.Sync.IsRPRealm and Overlord.Sync:IsRPRealm() then
            local sentAt = Overlord.Sync.lastRGSentAt or 0
            if sentAt > 0 and GetTime() - sentAt < 90 then
                -- Securite : n'accepter que si l'inviteur est un emetteur front recent connu (cache sync)
                local inviterName = ...
                local fullInviter = Overlord.Sync.CanonicalForeverName
                    and Overlord.Sync:CanonicalForeverName(inviterName) or nil
                local known = fullInviter and Overlord.Sync.IsRecentFrontSender
                    and (Overlord.Sync:IsRecentFrontSender(fullInviter)
                        or Overlord.Sync:IsRecentFrontSender(inviterName))
                if known then
                    pcall(AcceptGroup)
                    Overlord.rpAutoGrouped = true
                    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (L and L.RP_GROUP_ACCEPTED or "Joined group for phasing."))
                end
            end
        end
    end
end)

-- WoW 12.0 (Midnight) : COMBAT_LOG_EVENT_UNFILTERED supprime pour les addons.
-- La detection des kills est geree par CombatTracker.lua via PARTY_KILL
-- et PLAYER_PVP_KILLS_CHANGED (events standards qui fonctionnent en 12.0).
