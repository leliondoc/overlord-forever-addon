-- ZoneControl.lua - Gestion de la capture et du maintien des zones
Overlord = Overlord or {}
Overlord.ZoneControl = {}

local L = Overlord.L

-- Auras qui rendent le joueur invisible/invincible via Lorewalking.
-- Elles ne doivent jamais permettre de capturer ni de contester une zone.
local BLOCKED_CAPTURE_AURA_SPELL_IDS = {
    463943, -- Lorewalking
    468122, -- Lost in Thought
    385298, -- Magical Snow Sled
}

-- Spell ID des buffs druide : Travel Form (vol/terre/eau) et Mount Form (cerf montable, vitesse monture)
local DRUID_TRAVEL_FORM_SPELL_ID = 783
local DRUID_MOUNT_FORM_SPELL_ID = 210053

-- Liste ciblee pour les API par spell ID. Depuis WoW 12.1, parcourir les
-- auras par index depuis du code addon leve une erreur lorsque leur acces est
-- secret. Les recherches ciblees restent appelables depuis un chemin tainted
-- tant que l'aura demandee n'est pas elle-meme secrete.
local NON_CAPTURE_AURA_SPELL_IDS = {
    463943, 468122, 385298,
    115191, 11327, 5215, 58984, 199483, 114018,
    DRUID_TRAVEL_FORM_SPELL_ID, DRUID_MOUNT_FORM_SPELL_ID,
}

-- Index construit une seule fois au chargement. Quand le bulk aura est autorise,
-- il remplace les onze lookups cibles par une seule passe et conserve les memes regles.
local NON_CAPTURE_AURA_SPELL_ID_SET = {}
for i = 1, #NON_CAPTURE_AURA_SPELL_IDS do
    NON_CAPTURE_AURA_SPELL_ID_SET[NON_CAPTURE_AURA_SPELL_IDS[i]] = true
end

local BULK_AURA_FAST_PATH_LIMIT = 40

local DRUID_TRAVEL_AURA_SPELL_IDS = {
    DRUID_TRAVEL_FORM_SPELL_ID,
    DRUID_MOUNT_FORM_SPELL_ID,
}

-- GetShapeshiftFormID utilise des IDs de forme, pas des spell IDs.
-- Travel terrestre, aquatique, vol rapide et vol normal bloquent tous la capture locale.
local function IsDruidTravelShapeshiftForm(formID)
    return formID == 3 or formID == 4 or formID == 27 or formID == 29
end

-- WoW 12.0.5 : une AuraData peut etre secrete sur raid/nameplate.
local function ReadNonNilValue(value)
    return value ~= nil
end

-- WoW 12.x : pas de test direct d'un bool potentiellement secret en chemin taint.
local function ReadAccessibleBool(value)
    if value == nil then return nil end
    return value == true
end

local function AccessibleBoolIsTrue(value, whenInaccessible)
    if canaccessvalue then
        local okAcc, accessible = pcall(canaccessvalue, value)
        if not okAcc or not accessible then return whenInaccessible end
        if value == nil then return whenInaccessible end
        return value == true
    end
    local ok, result = pcall(ReadAccessibleBool, value)
    if not ok or result == nil then return whenInaccessible end
    return result
end

-- WoW 12.0.5 : cle de table (nom joueur) : pas d'index si secret value.
local function ReadAccessibleString(value)
    if value == nil or value == "" then return nil end
    return value
end

local function AccessibleStringKey(value)
    if canaccessvalue then
        local okAcc, accessible = pcall(canaccessvalue, value)
        if not okAcc or not accessible then return nil end
        return ReadAccessibleString(value)
    end
    local ok, result = pcall(ReadAccessibleString, value)
    if not ok then return nil end
    return result
end

-- Sentinelle de cache : nil signifie « pas encore calcule », cette valeur signifie
-- « calcule mais inconnu ». Les bools de politique ne doivent jamais entrer dans le cache.
local UNKNOWN_AURA_CACHE_VALUE = {}

-- ShouldSpellAuraBeSecret est la garde RequiresNonSecretAura des lookups cibles en 12.1.
-- Une erreur ou une valeur inaccessible signifie « inconnu » et interdit l'appel aura.
-- Les cles numeriques negatives sont reservees a ce cache par scan (les GUID sont des strings).
local function IsSpellAuraSecret(spellID, auraResultByGUID)
    local cacheKey = -spellID
    if auraResultByGUID then
        local cached = auraResultByGUID[cacheKey]
        if cached ~= nil then return cached end
    end

    local secret = false
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, value = pcall(C_Secrets.ShouldSpellAuraBeSecret, spellID)
        secret = not ok or AccessibleBoolIsTrue(value, true)
    end
    if auraResultByGUID then auraResultByGUID[cacheKey] = secret end
    return secret
end

-- nil = l'API ou sa valeur etaient inaccessibles ; false = aura absente ; true = presente.
-- Ne jamais laisser une valeur AuraData secrete sortir de cette fonction.
local function GetUnitAuraPresenceBySpellID(unit, spellID, auraResultByGUID)
    if not unit or not spellID or not C_UnitAuras then return nil end
    if IsSpellAuraSecret(spellID, auraResultByGUID) then return nil end

    local ok, aura
    if unit == "player" and C_UnitAuras.GetPlayerAuraBySpellID then
        ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    elseif C_UnitAuras.GetUnitAuraBySpellID then
        ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellID)
    else
        return nil
    end
    if not ok then return nil end

    if canaccessvalue then
        local okAcc, accessible = pcall(canaccessvalue, aura)
        if not okAcc or not accessible then return nil end
        return aura ~= nil
    end
    local okRead, present = pcall(ReadNonNilValue, aura)
    if not okRead then return nil end
    return present
end

-- Agregation tri-state : une aura presente gagne toujours, meme si une aura precedente
-- etait secrete. L'inconnu ne sort qu'apres avoir teste toute la liste.
local function UnitHasListedAura(unit, spellIDs, auraResultByGUID)
    local sawUnknown = false
    for i = 1, #spellIDs do
        local present = GetUnitAuraPresenceBySpellID(unit, spellIDs[i], auraResultByGUID)
        if present == true then return true end
        if present == nil then sawUnknown = true end
    end
    if sawUnknown then return nil end
    return false
end

-- Chemin rapide hors restriction : une seule lecture groupee detecte a la fois monture,
-- furtivite, formes et auras bloquantes. Toute lecture de champ reste dans le pcall appelant.
local function ReadUnitBulkNonCaptureState(unit)
    -- Plafond historique pour borner l'allocation AuraData. Une liste saturee n'est
    -- jamais consideree complete : le caller retombera alors sur les lookups cibles.
    local auras = C_UnitAuras.GetUnitAuras(unit, "HELPFUL", BULK_AURA_FAST_PATH_LIMIT)
    if not auras then return nil end
    local auraCount = #auras
    for i = 1, auraCount do
        local aura = auras[i]
        if aura then
            if aura.isMounted == true then return true end
            if NON_CAPTURE_AURA_SPELL_ID_SET[aura.spellId] == true then return true end
        end
    end
    if auraCount >= BULK_AURA_FAST_PATH_LIMIT then return nil end
    return false
end

local function AreAurasRestricted(auraResultByGUID)
    if auraResultByGUID and auraResultByGUID[0] ~= nil then
        return auraResultByGUID[0]
    end
    if not C_Secrets or not C_Secrets.ShouldAurasBeSecret then return false end
    local ok, restricted = pcall(C_Secrets.ShouldAurasBeSecret)
    -- Une erreur du predicat ne doit jamais autoriser ensuite l'API gardee.
    local result = not ok or AccessibleBoolIsTrue(restricted, true)
    if auraResultByGUID then auraResultByGUID[0] = result end
    return result
end

local function GetUnitBulkNonCaptureState(unit, auraResultByGUID)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return nil end
    -- WoW 12.1 : GetUnitAuras a RequiresUnitAuraAccess et leve une erreur pour
    -- un appelant addon lorsque ce predicat est vrai. Ne pas tenter l'appel.
    if AreAurasRestricted(auraResultByGUID) then return nil end
    local ok, blocked = pcall(ReadUnitBulkNonCaptureState, unit)
    if not ok then return nil end
    return blocked
end

local function GetAccessibleUnitGUID(unit)
    if not unit or not UnitGUID then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok then return nil end
    return AccessibleStringKey(guid)
end

local function UnitHasBlockedCaptureAura(unit)
    if not unit or not UnitExists(unit) then return false end
    return UnitHasListedAura(unit, BLOCKED_CAPTURE_AURA_SPELL_IDS)
end

-- Zone (id) ou le joueur etait au dernier CheckPlayerPosition : permet d'eviter de re-afficher
-- « entre dans la zone » + minuteur quand un sync remet status=available sans quitter le disque.
local previousCaptureCheckZoneId = nil
-- Disque capture (tous statuts) : entree cercle pour popup shard auto.
local previousPlayerDiskZoneId = nil
local previousCaptureCheckShardId = nil
local pendingEntrySyncZoneId = nil
local pendingEntrySyncUntil = 0
local ZONE_ENTRY_SYNC_GRACE_SECONDS = 7

local function BeginZoneEntrySyncGrace(zoneId)
    pendingEntrySyncZoneId = zoneId
    pendingEntrySyncUntil = GetTime() + ZONE_ENTRY_SYNC_GRACE_SECONDS
    if Overlord.Sync and Overlord.Sync.SendSyncRequest then
        Overlord.Sync:SendSyncRequest({ territorialOnly = true, criticalChannel = true })
    end
end

-- Anti-spam : ScanNearbyPlayers peut voir 0 ennemis une fraction de seconde (LOS, nameplate),
-- ou la sync fait osciller in_progress / conteste - sans ca le meme revert s'imprime a chaque tick (1/s).
local lastEnemyReversedChatAt = {}  -- zone.id -> GetTime()
local ENEMY_REVERSED_CHAT_GAP = 45   -- secondes entre deux messages identiques pour la meme zone

-- Chat « capture ennemie annulee » : uniquement depuis les reverts autoritaires sur le disque
-- (contestation / timer ennemi a 0). Les autres chemins restent silencieux volontairement.
function Overlord.ZoneControl:TryChatEnemyCaptureReversed(zone)
    if not zone or not zone.id then return end
    local now = GetTime()
    local last = lastEnemyReversedChatAt[zone.id] or 0
    if now - last < ENEMY_REVERSED_CHAT_GAP then return end
    lastEnemyReversedChatAt[zone.id] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.ENEMY_CAPTURE_REVERSED, zone.name))
end

local function ResolveLocalFailedCaptureOwner(zone)
    if not zone or not Overlord.Zones then return nil end
    local assailant = zone.owner
    local prev = zone.previousOwner
    local enemyFaction = Overlord.Zones:GetEnemyFaction()
    local playerFaction = Overlord.PlayerFaction
    if zone.status == "in_progress" and assailant and prev == assailant and assailant == enemyFaction then
        -- previousOwner identique a l'assaillant = valeur polluee (ZS/reprise locale apres ecrasement owner).
        -- Sur une annulation autoritaire depuis le disque, ne jamais restaurer le point a l'assaillant.
        if zone._assaultFromAvailable then return nil end
        local fixedOwner = Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
        if fixedOwner and fixedOwner ~= assailant then
            return fixedOwner
        end
        if not zone.capturedTime or zone.capturedTime <= 0 then return nil end
        if playerFaction and playerFaction ~= assailant then
            return playerFaction
        end
        if assailant == "Alliance" then return "Horde" end
        if assailant == "Horde" then return "Alliance" end
        return nil
    end
    return Overlord.Zones:ResolveRevertOwnerAfterFailedCapture(zone)
end

local lastZoneSecuredChatAt = {}
local ZONE_SECURED_CHAT_GAP = 10

local function TryChatZoneSecured(zone)
    if not zone or not zone.id then return end
    local now = GetTime()
    local last = lastZoneSecuredChatAt[zone.id] or 0
    if now - last < ZONE_SECURED_CHAT_GAP then return end
    lastZoneSecuredChatAt[zone.id] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.ZONE_SECURED, zone.name))
end

-- Entree / sortie du disque : meme intervalle que ZONE_SECURED (spam bord sans changer la geometrie).
local lastEnteredZoneChatAt = {}
local lastLeftZoneChatAt = {}
local lastBackInZoneChatAt = {}

local function TryChatEnteredZone(zone)
    if not zone or not zone.id then return end
    local now = GetTime()
    local last = lastEnteredZoneChatAt[zone.id] or 0
    if now - last < ZONE_SECURED_CHAT_GAP then return end
    lastEnteredZoneChatAt[zone.id] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.ENTERED_ZONE, zone.name))
end

local function TryChatLeftZone(zone)
    if not zone or not zone.id then return end
    local now = GetTime()
    local last = lastLeftZoneChatAt[zone.id] or 0
    if now - last < ZONE_SECURED_CHAT_GAP then return end
    lastLeftZoneChatAt[zone.id] = now
    Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.LEFT_ZONE, zone.name))
end

local function TryChatBackInZone(zone)
    if not zone or not zone.id then return end
    local now = GetTime()
    local last = lastBackInZoneChatAt[zone.id] or 0
    if now - last < ZONE_SECURED_CHAT_GAP then return end
    lastBackInZoneChatAt[zone.id] = now
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.BACK_IN_ZONE, zone.name))
end

local IsPlayerInNonCaptureState

-- Compte une unite pour la contestation. Le joueur local dispose des API dediees fiables ;
-- une aura distante inconnue n'est jamais transformee en preuve d'ineligibilite.
local function UnitCountsForCapture(unit)
    if not unit or not UnitExists(unit) then return 0 end
    if unit == "player" and IsPlayerInNonCaptureState then
        return IsPlayerInNonCaptureState() and 0 or 1
    end
    if UnitHasBlockedCaptureAura(unit) then return 0 end
    return 1
end

-- Passager monture 2 places, véhicule ou taxi : bloque capture / contestation.
local function IsUnitInVehicleState(unit)
    unit = unit or "player"
    if UnitInVehicle then
        local ok, inVehicle = pcall(UnitInVehicle, unit)
        if ok and AccessibleBoolIsTrue(inVehicle, false) then return true end
    end
    if UnitOnTaxi then
        local ok, onTaxi = pcall(UnitOnTaxi, unit)
        if ok and AccessibleBoolIsTrue(onTaxi, false) then return true end
    end
    return false
end

-- Detection montage/demontage et véhicule : broadcast immediat du ZS pour que les observateurs
-- voient le timer se pauser/reprendre sans attendre le cycle ZS de 5s.
-- Evite le bug ou deux joueurs montes voient le timer continuer a avancer.
local lastMountedState = nil
local lastVehicleState = nil
local lastMountZSBroadcastAt = 0
local MOUNT_ZS_DEBOUNCE = 2 -- secondes : monture/demontage sans spam ZS
local mountFrame = CreateFrame("Frame")

local function BroadcastZoneStateIfCapturing()
    local pz = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
    if pz and pz.status == "in_progress" and pz.holdAuthorityLocal and Overlord.Sync then
        local now = GetTime()
        if now - lastMountZSBroadcastAt < MOUNT_ZS_DEBOUNCE then return end
        lastMountZSBroadcastAt = now
        Overlord.Sync:BroadcastZoneState(pz)
    end
end

local function MountFrame_OnEvent(_, event, unit)
    if unit and unit ~= "player" then return end
    if not Overlord.InActiveFront then return end
    local nowMounted = IsMounted and IsMounted()
    local nowVehicle = IsUnitInVehicleState("player")
    if lastMountedState == nil then
        lastMountedState = nowMounted
        lastVehicleState = nowVehicle
        return
    end
    if nowMounted ~= lastMountedState or nowVehicle ~= lastVehicleState then
        lastMountedState = nowMounted
        lastVehicleState = nowVehicle
        -- ZS immediat seulement pour le capteur officiel (evite reset timer allie co-present).
        BroadcastZoneStateIfCapturing()
    end
end

mountFrame:SetScript("OnEvent", MountFrame_OnEvent)
-- Ne PAS enregistrer ici - sera fait dans Resume()

-- Detecte si le joueur est dans un etat qui empeche la capture :
-- monture, vol actif, passager/véhicule, Travel / Mount Form druide, ou furtivite (rogue, druide prowl, shadowmeld...).
-- On doit capturer a pied pour eviter les abus (survol rapide des points).
local PLAYER_NON_CAPTURE_CACHE_SEC = 0.05
local playerNonCaptureCacheAt = -1
local playerNonCaptureCached = false

IsPlayerInNonCaptureState = function()
    local now = GetTime()
    local cacheAge = now - playerNonCaptureCacheAt
    if cacheAge >= 0 and cacheAge <= PLAYER_NON_CAPTURE_CACHE_SEC then
        return playerNonCaptureCached
    end
    playerNonCaptureCacheAt = now
    -- Passager monture 2 places ou véhicule : bloque la capture
    if IsUnitInVehicleState("player") then
        playerNonCaptureCached = true
        return true
    end
    -- Monture : bloque la capture (on doit etre a pied)
    if IsMounted and IsMounted() then
        playerNonCaptureCached = true
        return true
    end
    -- Vol actif
    if IsFlying and IsFlying() then
        playerNonCaptureCached = true
        return true
    end
    -- Dragonriding / plane : IsFlying peut etre faux alors que le joueur est en l'air
    if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
        local ok, isGliding = pcall(C_PlayerInfo.GetGlidingInfo)
        if ok and isGliding then
            playerNonCaptureCached = true
            return true
        end
    end
    -- Druide Travel Form : bloque la capture meme au sol
    if GetShapeshiftFormID then
        local ok, formID = pcall(GetShapeshiftFormID)
        local okForm, isTravel = pcall(IsDruidTravelShapeshiftForm, formID)
        if ok and okForm and isTravel then
            playerNonCaptureCached = true
            return true
        end
    end
    -- Les API dediees ci-dessus font autorite. Une aura Travel devenue secrete est
    -- inconnue, pas presente : seul un true lisible bloque le joueur.
    if UnitHasListedAura("player", DRUID_TRAVEL_AURA_SPELL_IDS) == true then
        playerNonCaptureCached = true
        return true
    end
    if IsStealthed and IsStealthed() then
        playerNonCaptureCached = true
        return true
    end
    -- Lorewalking / Lost in Thought : invisibilite + invincibilite hors PvP normal.
    if UnitHasBlockedCaptureAura("player") then
        playerNonCaptureCached = true
        return true
    end
    playerNonCaptureCached = false
    return false
end

-- Requetes ciblees par spell ID : auras bloquantes, furtivite et formes druide.
-- Le cache optionnel ne vit que pendant ScanNearbyPlayers. Il conserve le tri-state brut :
-- true / false / UNKNOWN_AURA_CACHE_VALUE. La politique allie/ennemi reste chez l'appelant.
local function UnitHasNonCaptureAura(unit, auraResultByGUID, unitGUID)
    if auraResultByGUID and unitGUID then
        local cached = auraResultByGUID[unitGUID]
        if cached ~= nil then
            if cached == UNKNOWN_AURA_CACHE_VALUE then return nil end
            return cached
        end
    end

    -- Hors restriction, le bulk est definitif et evite onze transitions Lua -> C par unite.
    -- S'il est refuse/indisponible, les lookups cibles peuvent encore fournir une preuve true ;
    -- sans preuve, l'etat reste nil car une monture generique pourrait etre cachee.
    local bulk = GetUnitBulkNonCaptureState(unit, auraResultByGUID)
    local result
    if bulk ~= nil then
        result = bulk
    else
        local listed = UnitHasListedAura(unit, NON_CAPTURE_AURA_SPELL_IDS, auraResultByGUID)
        result = listed == true and true or nil
    end
    if auraResultByGUID and unitGUID then
        auraResultByGUID[unitGUID] = result == nil and UNKNOWN_AURA_CACHE_VALUE or result
    end
    return result
end

-- Etat brut pour les autres joueurs visibles. Retail 12.1 n'expose pas de
-- UnitIsMounted(unit) / UnitIsFlying(unit) documentes ; ne jamais fonder le comptage dessus.
local function GetUnitNonCaptureState(unit, auraResultByGUID, unitGUID)
    if not unit or not UnitExists(unit) then return true end
    if IsUnitInVehicleState(unit) then return true end
    return UnitHasNonCaptureAura(unit, auraResultByGUID, unitGUID)
end

-- Politique la moins destructive : un allie lisiblement bloque est exclu ; un etat
-- secret/inconnu reste eligible. Le cache conserve toujours l'etat brut.
local function IsUnitInNonCaptureState(unit, auraResultByGUID, unitGUID)
    return GetUnitNonCaptureState(unit, auraResultByGUID, unitGUID) == true
end

local function IsUnitIneligibleToContest(unit, auraResultByGUID, unitGUID)
    if not unit or not UnitExists(unit) then return true end
    -- Une valeur WoW 12.x secrete n'est pas une preuve que l'ennemi est monte ou en vol.
    -- L'exclure faisait tomber enemyCount a 0 et permettait a un assaillant de continuer
    -- seul face a plusieurs defenseurs. Seul un true lisible exclut la nameplate ;
    -- l'inconnu reste contestataire.
    return GetUnitNonCaptureState(unit, auraResultByGUID, unitGUID) == true
end

-- True si cette tentative de capture a ete demarree localement (StartHoldTimer).
-- Les observateurs montes a cote d'un allie qui cap (sync ZS seulement) n'ont pas ce flag :
-- UpdateHoldTimer ne doit pas les traiter en LOSING "vous avez quitte la zone".
local function clearHoldAuthorityLocal(zone)
    if zone then
        zone.holdAuthorityLocal = nil
    end
end

-- Co-capture : ne pas prendre holdAuthorityLocal si un autre allie est deja capteur officiel (ZS).
local STALE_OFFICIAL_CAPTURE_TAKEOVER_SECONDS = 18

local function CapturerNamesMatch(a, b)
    if not a or a == "" or not b or b == "" then return false end
    if a == b then return true end
    if Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey then
        local ak = Overlord.Sync:GetCaptureContributorDedupKey(a)
        local bk = Overlord.Sync:GetCaptureContributorDedupKey(b)
        if ak and bk and ak == bk then return true end
    end
    return false
end

local function IsOfficialCapturerFresh(zone, selfName)
    if not zone then return false end
    local official = zone.zsOfficialCapturerName
    if not official or official == "" then return false end
    if selfName and selfName ~= "" and CapturerNamesMatch(official, selfName) then return true end
    local seenAt = tonumber(zone._zsOfficialCapturerSeenAt) or 0
    return seenAt > 0 and (GetTime() - seenAt) < STALE_OFFICIAL_CAPTURE_TAKEOVER_SECONDS
end

local function CanClaimLocalCaptureAuthority(zone)
    if not zone then return true end
    -- Un heartbeat ZS envoye directement par le capteur est deja lie au sender
    -- WoW et a la vague validee. Tant que ce bail est frais, un late joiner ne
    -- doit jamais le convertir en nouvelle capture locale (timer remis a zero).
    if Overlord.CaptureLease and Overlord.CaptureLease.IsFreshDirect
        and Overlord.CaptureLease:IsFreshDirect(zone) then
        return false
    end
    local official = zone.zsOfficialCapturerName
    if not official or official == "" then return true end
    if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        local selfName = Overlord.Sync:GetPlayerFullName()
        if selfName and selfName ~= "" then
            return CapturerNamesMatch(selfName, official) or not IsOfficialCapturerFresh(zone, selfName)
        end
    end
    return not IsOfficialCapturerFresh(zone)
end

local function MaybeTakeOverStaleAllyCaptureAuthority(zone)
    if not zone or zone.holdAuthorityLocal then return false end
    if zone.status ~= "in_progress" or zone.owner ~= Overlord.PlayerFaction then return false end
    local official = zone.zsOfficialCapturerName
    if not official or official == "" then return false end
    if not Overlord.Sync or not Overlord.Sync.GetPlayerFullName then return false end
    local selfName = Overlord.Sync:GetPlayerFullName()
    if not selfName or selfName == "" or CapturerNamesMatch(official, selfName) then return false end
    if IsOfficialCapturerFresh(zone, selfName) then return false end

    if Overlord.CaptureLease and Overlord.CaptureLease.PromoteRemoteToLocal then
        if not Overlord.CaptureLease:PromoteRemoteToLocal(zone) then return false end
    end
    zone.holdAuthorityLocal = true
    zone.zsOfficialCapturerName = selfName
    zone._zsOfficialCapturerSeenAt = GetTime()
    if not zone.holdStartTime then
        zone.holdStartTime = GetTime() - (tonumber(zone.holdTimeElapsed) or 0)
    end

    -- Si on vient seulement d'arriver sur un vieux ZS avance, ne pas instant-cap.
    local req = zone.holdTimeRequired or 120
    local timeInZone = math.max(0, GetTime() - (zone.holdStartTime or GetTime()))
    local maxAllowed = math.min(timeInZone + 15, req)
    if (zone.holdTimeElapsed or 0) > maxAllowed then
        zone.holdTimeElapsed = maxAllowed
        zone.holdStartTime = GetTime() - zone.holdTimeElapsed
    end
    return true
end

-- Le siege ne concerne que l'attaque de la capitale ennemie.
-- Recuperer sa propre capitale (Alliance -> Stromgarde, Horde -> Hammerfell)
-- utilise le timer normal, sans phases ni bonus defenseur de forteresse.
local function IsEnemyCapitalSiege(zone)
    if not zone or not zone.isCapital then return false end
    local fixedOwner = Overlord.Zones and Overlord.Zones:GetBaseZoneFixedOwner(zone.id)
    return fixedOwner and fixedOwner ~= Overlord.PlayerFaction
end

-- Meme regle que CheckPlayerPosition : Sync ne doit pas poser isHolding si monture/vol/furtif.
-- Avec un unit optionnel, reutilise aussi les regles chaudes de ScanNearbyPlayers.
function Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync(
    unit, auraResultByGUID, unitGUID, _inaccessibleMeansBlocked)
    if unit and unit ~= "player" then
        if UnitIsDead(unit) or UnitIsGhost(unit) then return true end
        local ok, result = pcall(
            GetUnitNonCaptureState, unit, auraResultByGUID, unitGUID)
        -- Une erreur est un etat inconnu, pas une preuve permettant de supprimer un allie.
        if not ok then return false end
        return result == true
    end
    if UnitIsDead("player") or UnitIsGhost("player") then return true end
    return IsPlayerInNonCaptureState()
end

function Overlord.ZoneControl:IsUnitIneligibleToContestForSync(unit, auraResultByGUID, unitGUID)
    local ok, result = pcall(IsUnitIneligibleToContest, unit, auraResultByGUID, unitGUID)
    -- Un ennemi vivant dont l'etat devient illisible doit continuer a contester.
    if not ok then return false end
    return result
end

-- Regle numerique unique pour zones, fortins et consommateurs sync.
-- `friendlyCount` est toujours le camp qui porte le timer ; `enemyCount` celui qui
-- le conteste. Le troisieme argument sert a la vue autoritaire du capteur : toute presence
-- ennemie physique fait alors reculer sa tentative, meme sans surnombre.
function Overlord.ZoneControl:EvaluateCaptureForces(
    friendlyCount, enemyCount, enemyIsCapturing)
    friendlyCount = math.max(0, tonumber(friendlyCount) or 0)
    enemyCount = math.max(0, tonumber(enemyCount) or 0)
    local contested = enemyCount > 0
        and (enemyIsCapturing == true or enemyCount >= friendlyCount)
    local contestPull = 1
    if friendlyCount > 0 and enemyCount >= friendlyCount then
        contestPull = math.max(1, enemyCount / friendlyCount)
    end
    return contested, contestPull
end

-- Demontage auto dans les cercles : uniquement en vol / plane (dragonriding, monture en l'air).
-- Les montures au sol et le mode « monture uniquement au sol » restent autorises dans le disque.
local function ShouldAutoDismountForFlightInCircle()
    if IsFlying and IsFlying() then return true end
    if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
        local ok, isGliding = pcall(C_PlayerInfo.GetGlidingInfo)
        if ok and isGliding then return true end
    end
    return false
end

-- Demontage auto dans les cercles (API client : uniquement votre personnage).
local AUTO_DISMOUNT_DELAY = 10
local captureCircleDismountState = { accum = 0, warned = false, key = nil }
local mineCircleDismountState = { accum = 0, warned = false, key = nil }

local function AutoDismountTryPlayer()
    if IsMounted and IsMounted() then
        pcall(Dismount)
    end
    if C_MountJournal and C_MountJournal.Dismount then
        pcall(C_MountJournal.Dismount)
    end
end

-- Anti-spam demontage auto : le throttle par zone floodait au changement de sous-zone (meme vol continu).
-- Un seul message chat pour cap OU mine tant que la fenetre globale n'est pas ecoulee ; le delai local continue quand meme.
local lastAutoDismountGlobalWarnAt = 0
local AUTO_DISMOUNT_GLOBAL_CHAT_GAP = 28 -- secondes entre deux annonces quel que soit le cercle

local function TryChatAutoDismountWarning(channelPrefix, circleKey, warningFmt, displayName)
    if not circleKey or circleKey == "" then return false end
    if (UnitIsDead and UnitIsDead("player")) or (UnitIsGhost and UnitIsGhost("player")) then return false end
    local now = GetTime()
    if now - lastAutoDismountGlobalWarnAt >= AUTO_DISMOUNT_GLOBAL_CHAT_GAP then
        lastAutoDismountGlobalWarnAt = now
        local msg = displayName and string.format(warningFmt, displayName, AUTO_DISMOUNT_DELAY) or warningFmt
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. msg)
    end
    -- true = ne pas reessayer le chat a chaque tick ; accum du tick parent continue (meme sans nouveau print)
    return true
end

-- deltaTime : secondes ecoulees (tick 1 Hz depuis Core.lua ou mine ticker).
local function AutoDismountStateTick(state, deltaTime, inCircle, circleKey, warningFmt, displayName, channelPrefix)
    if UnitIsDead("player") or UnitIsGhost("player") then
        state.accum = 0
        state.warned = false
        state.key = nil
        return
    end
    if not inCircle or not circleKey then
        state.accum = 0
        state.warned = false
        state.key = nil
        return
    end
    if not ShouldAutoDismountForFlightInCircle() then
        state.accum = 0
        state.warned = false
        state.key = nil
        return
    end

    if state.key ~= circleKey then
        state.key = circleKey
        state.accum = 0
        state.warned = false
    end

    if not state.warned then
        if TryChatAutoDismountWarning(channelPrefix, circleKey, warningFmt, displayName) then
            state.warned = true
        end
    end

    state.accum = state.accum + deltaTime
    if state.accum >= AUTO_DISMOUNT_DELAY then
        AutoDismountTryPlayer()
        if not ShouldAutoDismountForFlightInCircle() then
            state.accum = 0
            state.warned = false
            state.key = nil
        end
    end
end

function Overlord.ZoneControl:TickAutoDismountCaptureCircle(deltaTime)
    if not Overlord.InActiveFront then
        captureCircleDismountState.accum = 0
        captureCircleDismountState.warned = false
        captureCircleDismountState.key = nil
        return
    end
    local zone = Overlord.Zones and Overlord.Zones:GetCurrentPlayerZone()
    local key = zone and zone.id or nil
    -- Uniquement les disques ou la capture peut demarrer / continuer : pas locked ni
    -- captured (survol d'une base alliee ou d'un point encore ferme).
    local canCaptureHere = zone and (
        zone.isHolding
        or zone.status == "available"
        or zone.status == "in_progress"
    )
    local inCircle = canCaptureHere and key ~= nil
    local name = zone and zone.name or "?"
    AutoDismountStateTick(captureCircleDismountState, deltaTime, inCircle, key, L.AUTO_DISMOUNT_CAPTURE_CIRCLE, name, "cap")
end

function Overlord.ZoneControl:TickAutoDismountMineCircle(deltaTime, mine)
    local key = mine and mine.id or nil
    local inCircle = key ~= nil
    local name = mine and mine.name or "?"
    AutoDismountStateTick(mineCircleDismountState, deltaTime, inCircle, key, L.AUTO_DISMOUNT_MINE_CIRCLE, name, "mine")
end

-- Throttle des appels Sync depuis l'observateur distant (4 Hz ticker → ~1 poll / 2,5 s / zone).
local OBSERVER_SYNC_POLL_INTERVAL = 2.5

-- Observation a distance : interpolation du timer entre les ZS (~5 s) sans attendre uniquement Update(1 s).
-- appelee plusieurs fois par seconde depuis Core.lua (Ticker dedie),
-- alors que Update(...) reste a 1 Hz pour limiter ScanNearbyPlayers / LOSING complexe.
function Overlord.ZoneControl:TickRemoteObserverZone(zone, deltaTime)
    if zone.status ~= "in_progress" or zone.isHolding then return end
    if Overlord.CaptureLease and Overlord.CaptureLease.MaybeExpire
        and Overlord.CaptureLease:MaybeExpire(zone) then return end
    local remoteLease = zone._remoteCaptureLease
    local zsWatcherAge = remoteLease
        and (GetTime() - (remoteLease.lastSeen or 0))
        or math.max(0, time() - (zone.updatedAt or 0))
    local INTERPOLATION_STALE_PAUSE = 8
    local OBSERVER_DISPLAY_MAX_LEAD = 5
    local OBSERVER_DISPLAY_REWIND_RATE = 3
    local staleInterpCheck = zsWatcherAge >= INTERPOLATION_STALE_PAUSE

    -- Affichage seulement : avancer localement entre deux ZS, mais revenir doucement
    -- si une verite reseau plus basse arrive (conteste, abandon, capteur non finalise).
    -- Sinon l'observateur peut rester orange a 0:00 alors que le vrai timer reseau est plus bas.
    local req = zone.holdTimeRequired or 120
    -- Un relais SR conserve volontairement le hold brut et l'ancien timestamp
    -- pour ne pas amplifier une interpolation. Le receveur materialise une seule
    -- fois leur projection dans ce plancher d'affichage.
    local base = math.max(tonumber(zone.holdTimeElapsed) or 0,
        tonumber(zone._observerDisplayNetworkFloor) or 0)
    local cur = zone._observerDisplayHold
    if not cur or cur < base then
        cur = base
    elseif cur > base + OBSERVER_DISPLAY_MAX_LEAD then
        cur = math.max(base, cur - (deltaTime * OBSERVER_DISPLAY_REWIND_RATE))
    end
    if not (Overlord.CaptureLease and Overlord.CaptureLease.IsSoftExpired
        and Overlord.CaptureLease:IsSoftExpired(zone)) then
        zone._observerDisplayHold = math.min(cur + deltaTime, req)
    else
        zone._observerDisplayHold = math.min(cur, req)
    end

    local now = GetTime()
    local lastPoll = zone._lastObserverSyncPollAt or 0
    if now - lastPoll < OBSERVER_SYNC_POLL_INTERVAL then
        return
    end
    zone._lastObserverSyncPollAt = now

    -- Sync : SR poll si ZS stale (ne coupe pas l'interpolation affichage).
    if staleInterpCheck and Overlord.Sync and Overlord.Sync.PollIfStaleObserverInProgress then
        Overlord.Sync:PollIfStaleObserverInProgress(zsWatcherAge, zone)
    end

    if Overlord.Sync and Overlord.Sync.RequestObserverCaptureConfirmationIfComplete then
        Overlord.Sync:RequestObserverCaptureConfirmationIfComplete(zone)
    end

    -- Capture ennemie dont la chaine de prerequis contredit notre carte locale
    -- (C / ZS captured cross-faction manque) : SR de rattrapage, sans rien ecrire.
    if Overlord.Sync and Overlord.Sync.RequestPrereqMismatchCatchup then
        Overlord.Sync:RequestPrereqMismatchCatchup(zone)
    end
end

-- Tick unique par zone (fonction nommee : evite de creer 30 closures/s via pcall(function())).
local function ZoneTickOne(zoneCtrl, zone, deltaTime, playerZoneId)
    if zone.status == "in_progress" and not zone.isHolding then
        if zone._syncGateRemoteProgressUntil and GetTime() >= zone._syncGateRemoteProgressUntil then
            zone._syncGateRemoteProgress = nil
            zone._syncGateRemoteProgressUntil = nil
        end
        if playerZoneId and playerZoneId == zone.id
            and not UnitIsDead("player") and not UnitIsGhost("player")
            and not IsPlayerInNonCaptureState()
            and not zone._syncGateRemoteProgress
            and (not Overlord.CanStartLocalCapture or Overlord:CanStartLocalCapture(zone, true)) then
            if zone.owner ~= Overlord.Zones:GetEnemyFaction() and not zone.previousOwner then
                zone.previousOwner = zone.owner
            end
            if zone.isCapital and IsEnemyCapitalSiege(zone) and Overlord.Zones and Overlord.Zones.GetCapitalHoldTime then
                local capReq = Overlord.Zones:GetCapitalHoldTime(zone)
                if (zone.holdTimeRequired or 120) < capReq then
                    zone.holdTimeRequired = capReq
                end
            end
            zone.isHolding = true
            zone.isPaused = false
            if zone.owner == Overlord.PlayerFaction and CanClaimLocalCaptureAuthority(zone) then
                if not zone.holdAuthorityLocal and Overlord.CaptureLease
                    and Overlord.CaptureLease.PromoteRemoteToLocal then
                    if not Overlord.CaptureLease:PromoteRemoteToLocal(zone) then
                        return
                    end
                end
                zone.holdAuthorityLocal = true
            end
            if not zone._restoredInProgress and zone.owner == Overlord.PlayerFaction then
                -- Cap anti-exploit uniquement si aucun ZS reseau frais (< 15s).
                -- Depuis 6.3.0, holdTimeElapsed n'est plus interpole localement :
                -- un ZS recent porte le vrai progres du capteur actif.
                -- updatedAt=0 (login) n'est pas un ZS stale : ne pas ecraser la progression alliee.
                local official = zone.zsOfficialCapturerName
                local selfName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
                    and Overlord.Sync:GetPlayerFullName() or ""
                local joinAllyCapture = official and official ~= "" and official ~= selfName
                local updatedAt = zone.updatedAt or 0
                local zsAge = (updatedAt > 0) and (time() - updatedAt) or 0
                if not joinAllyCapture and updatedAt > 0 and zsAge >= 15 then
                    local maxHold = zone.holdTimeRequired or 120
                    local capValue = math.min(15, maxHold - 1)
                    if (zone.holdTimeElapsed or 0) > capValue then
                        zone.holdTimeElapsed = capValue
                    end
                end
            end
            if zone._restoredInProgress and zone.holdAuthorityLocal then
                -- Reprise physique sur le disque : ancrer le timer local (pas d'interpolation fantome).
                zone.updatedAt = time()
            end
            zone._restoredInProgress = nil
            if not zone.holdStartTime then
                zone.holdStartTime = GetTime() - (tonumber(zone.holdTimeElapsed) or 0)
            end
        end
    end

    if zone.isHolding then
        zoneCtrl:UpdateHoldTimer(zone, deltaTime)
    end
end

-- Mise a jour lourde (1/s) : filets presence + captures locales + UpdateHoldTimer quand isHolding.
function Overlord.ZoneControl:Update(deltaTime)
    self:TickAutoDismountCaptureCircle(deltaTime)
    pcall(self.CheckPlayerPosition, self)

    local playerZone = Overlord.Zones and Overlord.Zones.GetCurrentPlayerZone
        and Overlord.Zones:GetCurrentPlayerZone()
    local playerZoneId = playerZone and playerZone.id

    for _, zone in ipairs(Overlord.ZoneDatabase) do
        if zone.isHolding or (playerZoneId and zone.id == playerZoneId) then
            local zoneOk, zoneErr = pcall(ZoneTickOne, self, zone, deltaTime, playerZoneId)
            if not zoneOk and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
                print("|cFFFF4444[Overlord:dbg]|r ZoneTick " .. tostring(zone.id) .. ": " .. tostring(zoneErr))
            end
        end
    end
end

-- Verifie si le joueur est dans une zone disponible
function Overlord.ZoneControl:CheckPlayerPosition()
    local currentZone = Overlord.Zones:GetCurrentPlayerZone()
    local currentId = currentZone and currentZone.id or nil
    local currentShardId = Overlord.Shard and tonumber(Overlord.Shard.currentShardID) or nil
    if previousCaptureCheckShardId ~= nil and currentShardId ~= nil
        and previousCaptureCheckShardId ~= currentShardId then
        -- Un hop de shard peut conserver exactement les memes coordonnees/disque. Sans
        -- reset, crossedDiskBoundary reste faux et ce client s'auto-elit avant le premier ZS.
        previousCaptureCheckZoneId = nil
        previousPlayerDiskZoneId = nil
        pendingEntrySyncZoneId = nil
        pendingEntrySyncUntil = 0
    end
    if currentShardId ~= nil then previousCaptureCheckShardId = currentShardId end

    -- Entree cercle (shard auto-invite) : une comparaison d'id/s ; travail lourd seulement au changement.
    if currentId then
        if previousPlayerDiskZoneId ~= currentId then
            if Overlord.Shard and Overlord.Shard.ScheduleAutoPromptOnZoneEntry then
                Overlord.Shard:ScheduleAutoPromptOnZoneEntry(currentZone)
            end
        end
        previousPlayerDiskZoneId = currentId
    else
        previousPlayerDiskZoneId = nil
    end

    if not currentZone then
        previousCaptureCheckZoneId = nil
        pendingEntrySyncZoneId = nil
        pendingEntrySyncUntil = 0
        return
    end

    -- Ne pas capturer en vol, forme de vol druide, ou furtivite.
    -- Ne pas marquer le disque comme deja vu : sinon, apres atterrissage/demontage sur
    -- place, crossedDiskBoundary reste faux et le chat d'entree / hold est coupe.
    if IsPlayerInNonCaptureState() then
        return
    end
    -- Ne pas capturer quand on est mort ou en forme fantome
    if UnitIsDead("player") or UnitIsGhost("player") then
        previousCaptureCheckZoneId = currentId
        return
    end

    if currentZone.status ~= "available" or currentZone.isHolding then
        previousCaptureCheckZoneId = currentId
        return
    end

    -- Un allie est deja capteur officiel sur ce point (sync ZS) : ne pas repartir a 0.
    local allyOfficial = currentZone.zsOfficialCapturerName
    if allyOfficial and allyOfficial ~= "" and Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        local selfName = Overlord.Sync:GetPlayerFullName()
        if selfName and selfName ~= "" and not CapturerNamesMatch(allyOfficial, selfName)
            and IsOfficialCapturerFresh(currentZone, selfName) then
            previousCaptureCheckZoneId = currentId
            return
        end
    end

    -- Treve post-victoire (front entier) + prerequis : si le statut local est "available"
    -- en retard sur UpdateAvailableZones ou la sync, on ne demarre pas le timer (exploit Sage).
    if Overlord.Zones and not Overlord.Zones:IsZoneAvailable(currentZone.id) then
        previousCaptureCheckZoneId = currentId
        return
    end

    -- Apres login / sortie d'instance, attendre une vraie sync avant de
    -- laisser ce client devenir autorite uniquement sur un disque capturable.
    if Overlord.CanStartLocalCapture and not Overlord:CanStartLocalCapture(currentZone, true) then
        previousCaptureCheckZoneId = nil
        return
    end

    -- True seulement si on change de disque (nil -> zone ou zone A -> zone B), pas si le sync
    -- a rebascule la meme zone en available alors qu'on est reste sur place.
    local crossedDiskBoundary = (previousCaptureCheckZoneId ~= currentId)

    -- A l'entree (ou apres un hop de shard sur place), demander le snapshot territorial
    -- avant de creer une nouvelle vague locale. Le capteur deja a 1:50 garde ainsi son
    -- timer et le nouvel arrivant devient observateur/co-capteur au lieu de repartir a 0.
    if crossedDiskBoundary then
        BeginZoneEntrySyncGrace(currentId)
        previousCaptureCheckZoneId = currentId
        return
    end
    if pendingEntrySyncZoneId == currentId and GetTime() < pendingEntrySyncUntil then
        return
    end
    pendingEntrySyncZoneId = nil
    pendingEntrySyncUntil = 0

    -- Nouvelle capture locale depuis une zone disponible : repartir de 0.
    -- StartHoldTimer conserve volontairement un elapsed restaure pour les captures
    -- deja in_progress apres /reload ; ici on vient justement de passer available -> in_progress.
    if Overlord.CaptureLease and Overlord.CaptureLease.BeginLocal then
        Overlord.CaptureLease:BeginLocal(currentZone)
    end
    currentZone.holdTimeElapsed = 0
    currentZone.holdStartTime = nil
    currentZone.isContested = false
    currentZone.isPaused = false
    currentZone._assaultFromAvailable = (currentZone.status == "available" and not currentZone.owner)
    if currentZone._assaultFromAvailable then
        currentZone.capturedTime = nil
    end
    currentZone.previousOwner = currentZone.owner
    currentZone.status = "in_progress"
    currentZone.updatedAt = time()
    self:StartHoldTimer(currentZone, not crossedDiskBoundary)

    if crossedDiskBoundary then
        TryChatEnteredZone(currentZone)
    end

    previousCaptureCheckZoneId = currentId

    if Overlord.ZoneIndicator then
        Overlord.ZoneIndicator:Show()
    end

    -- MarkDirty au lieu de SaveState : l'entree sur disque est frequente et transitoire ;
    -- l'autosave 30 s persiste, les transitions finales (capture, revert) gardent SaveState.
    Overlord:MarkDirty()
    if Overlord.UI then
        Overlord.UI:RequestRefresh()
    end
end

-- Demarre le timer de maintien pour une zone
-- suppressChat : si true, pas de lignes chat (relance capture sur le meme disque apres sync).
function Overlord.ZoneControl:StartHoldTimer(zone, suppressChat)
    if zone.isHolding then
        return
    end

    if Overlord.CaptureLease and Overlord.CaptureLease.BeginLocal then
        Overlord.CaptureLease:BeginLocal(zone)
    end

    -- Sauvegarde le proprietaire reel avant la tentative de capture
    -- (ex: Alliance a capture hammerfell -> on garde "Alliance" pour restaurer en cas d'echec)
    -- Ne pas ecraser si deja defini (un ZS peut avoir pose previousOwner avant StartHoldTimer)
    if not zone.previousOwner then
        zone.previousOwner = zone.owner
    end
    zone.isHolding = true
    zone.holdAuthorityLocal = true
    zone.isPaused = false
    if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        local fn = Overlord.Sync:GetPlayerFullName()
        if fn and fn ~= "" then
            zone.zsOfficialCapturerName = fn
            zone._zsOfficialCapturerSeenAt = GetTime()
        end
    end
    -- Apres /reload, RestoreZoneState ou le filet de securite (Update) peuvent avoir
    -- restaure un timer in_progress. CheckPlayerPosition remet holdTimeElapsed a 0
    -- AVANT d'appeler StartHoldTimer pour les nouvelles captures depuis available.
    -- Ici on conserve la valeur deja presente (0 pour une nouvelle, >0 pour un /reload).
    local restoredElapsed = tonumber(zone.holdTimeElapsed) or 0
    local restoredRequired = tonumber(zone.holdTimeRequired)
    zone.holdTimeElapsed = (zone.status == "in_progress" and restoredElapsed > 0) and restoredElapsed or 0
    zone.holdStartTime = GetTime() - zone.holdTimeElapsed
    zone.owner = Overlord.PlayerFaction

    -- Un /reload conserve le contrat de la vague (Renfort/Barricade/avant-poste)
    -- au lieu de recalculer sa duree depuis un etat strategique potentiellement change.
    local continuingRequirement = zone.holdTimeElapsed > 0
        and Overlord.CaptureLease and Overlord.CaptureLease.NormalizeCaptureRequirement
        and Overlord.CaptureLease:NormalizeCaptureRequirement(
            zone, Overlord.PlayerFaction, restoredRequired)
    if continuingRequirement then
        zone.holdTimeRequired = continuingRequirement
    else
        -- Capitale ennemie : timer fixe 8 min. Zones normales : 120 s.
        if IsEnemyCapitalSiege(zone) then
            zone.holdTimeRequired = Overlord.Zones:GetCapitalHoldTime(zone)
        else
            zone.holdTimeRequired = 120
        end

        -- Attaque d'or : reduit aussi les capitales. Calcul unique au debut de la vague.
        if Overlord.Ressources and Overlord.Ressources.ConsumeCaptureReduction then
            local minHold = (Overlord.RessourcesConstants
                and Overlord.RessourcesConstants.REINFORCE_MIN_HOLD) or 30
            zone.holdTimeRequired = Overlord.Ressources:ConsumeCaptureReduction(
                zone.holdTimeRequired, minHold)
        end

        -- Effet strategique de l'avant-poste du front. Lecture unique au debut de
        -- la vague : aucun ticker ni scan supplementaire ; la valeur exacte voyage
        -- deja dans holdTimeRequired via ZS puis dans la finale C.
        if Overlord.Outpost and Overlord.Outpost.GetZoneCapturePenaltySeconds then
            zone.holdTimeRequired = zone.holdTimeRequired
                + Overlord.Outpost:GetZoneCapturePenaltySeconds(
                    zone, Overlord.PlayerFaction)
        end
    end

    -- Diffuse l'etat "en cours" pour que les autres joueurs (groupe/canal) voient le timer
    if Overlord.Sync then
        Overlord.Sync:BroadcastZoneState(zone)
    end

    if not suppressChat then
        Overlord:PrintNotification(string.format("|cFFFFFF00[Overlord]|r " .. L.HOLD_TIMER_STARTED,
            zone.name,
            math.floor(zone.holdTimeRequired / 60),
            zone.holdTimeRequired % 60))
    end
end

-- Met a jour le timer de maintien.
-- 3 etats : CAPTURING (allies >= ennemis), CONTESTE (ennemis > allies), LOSING (hors zone).
local ZS_BROADCAST_INTERVAL = 5  -- secondes entre chaque sync du timer (5 = equilibre reactivite/throttle)
local contestedMsgCooldown = 0
local lastZSBroadcast = {}  -- zone.id -> GetTime() du dernier envoi ZS (sync timer aux autres)
-- Anti passage eclair : une nameplate ennemie en vol peut etre vue sur le disque.
-- Elle peut faire reculer le timer, mais ne doit pas casser toute la capture en 1-2 ticks.
local CONTEST_RESET_GRACE_SECONDS = 8
local contestedStartedAt = {} -- zone.id -> GetTime() de debut de contestation continue
function Overlord.ZoneControl:UpdateHoldTimer(zone, deltaTime)
    if not zone.isHolding then return end

    local playerZone = Overlord.Zones:GetCurrentPlayerZone()
    local inZone = playerZone and playerZone.id == zone.id
    local enemyFactionMt = Overlord.Zones:GetEnemyFaction()
    -- Un client defenseur n'est qu'un observateur du timer ennemi recu par ZS. Le faire
    -- regresser puis diffuser/sauver localement creait plusieurs producteurs et pouvait
    -- persister un faux revert. Seul le client qui a demarre la capture porte le timer ;
    -- sa propre vue des defenseurs decide la regression autoritaire.
    if inZone and zone.owner == enemyFactionMt then
        return
    end
    -- Monture / vol / furtif : capteur local = traite comme hors zone (LOSING).
    -- Observateur (cap alliee par sync, sans StartHoldTimer) : ne pas LOSING ni spam LEFT_ZONE.
    if inZone and IsPlayerInNonCaptureState() then
        if zone.holdAuthorityLocal then
            -- Capteur officiel sur le disque en monture : pause sans decay LOSING ni ZS « reset » allie.
            if zone.owner == Overlord.PlayerFaction then
                return
            end
            inZone = false
        else
            return
        end
    end
    -- Mort ou fantome : ne pas faire progresser le timer (corps dans la zone mais pas actif)
    if inZone and (UnitIsDead("player") or UnitIsGhost("player")) then
        inZone = false
    end

    if inZone then
        local enemyFaction = Overlord.Zones:GetEnemyFaction()
        local enemyIsCapturing = (zone.owner == enemyFaction)
        local friendlyCount, enemyCount = self:ScanNearbyPlayers(zone)
        -- Conteste si : des ennemis sont visibles ET en surnombre (>= allies), OU l'ennemi capture
        -- et est physiquement present (au moins 1 nameplate). Si 0 ennemis, l'ennemi a quitte :
        -- on reprend la zone normalement (le timer va decroitre puis repartir pour notre faction).
        local contested, contestPull = self:EvaluateCaptureForces(
            friendlyCount, enemyCount, enemyIsCapturing)

        if contested then
            -- Un seul producteur autoritaire peut regresser, finaliser et diffuser le timer.
            if not zone.holdAuthorityLocal then
                return
            end
            -- CONTESTE : le timer decroit (bloquer reduit la progression ennemie)
            -- Evite le "tag instant" quand on quitte apres avoir bloque
            local now = GetTime()
            if not zone.isContested then
                zone.isContested = true
                zone.isPaused = false
                contestedStartedAt[zone.id] = now
                -- Cooldown de 60s pour eviter le spam quand les deux factions se battent sur le meme point
                if now - contestedMsgCooldown > 60 then
                    contestedMsgCooldown = now
                    if enemyCount >= friendlyCount then
                        -- Message distinct si surnombre strict ou égalité (ex. 1v1)
                        local contestedFmt = (enemyCount > friendlyCount) and L.ZONE_CONTESTED_OUTNUMBER
                            or L.ZONE_CONTESTED_EVEN
                        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. contestedFmt,
                            zone.name, enemyCount, friendlyCount))
                    end
                end
            elseif not contestedStartedAt[zone.id] then
                contestedStartedAt[zone.id] = now
            end
            -- Recul accéléré si l'ennemi domine en force effective (ex. 1 DPS vs 1 soigneur = x2).
            zone.holdTimeElapsed = math.max(0, (zone.holdTimeElapsed or 0) - deltaTime * contestPull)

            -- Capture ennemie annulee : le timer est retombe a 0 pendant notre contestation.
            -- Revert la zone a son proprietaire d'avant la tentative (meme logique que LOSING).
            if zone.holdTimeElapsed <= 0 then
                -- Un survol / passage en monture ne doit pas reset une capture alliee.
                -- On garde l'etat in_progress a 0 jusqu'a une vraie contestation continue.
                if zone.owner == Overlord.PlayerFaction then
                    local contestedFor = now - (contestedStartedAt[zone.id] or now)
                    if contestedFor < CONTEST_RESET_GRACE_SECONDS then
                        if Overlord.Sync and (not lastZSBroadcast[zone.id] or now - lastZSBroadcast[zone.id] >= ZS_BROADCAST_INTERVAL) then
                            zone.updatedAt = time()
                            Overlord.Sync:BroadcastZoneState(zone)
                            lastZSBroadcast[zone.id] = now
                        end
                        return
                    end
                end
                local wasLocalAuthority = zone.holdAuthorityLocal == true
                if wasLocalAuthority and Overlord.CaptureLease
                    and Overlord.CaptureLease.BroadcastLocalRelease then
                    Overlord.CaptureLease:BroadcastLocalRelease(zone)
                end
                zone.holdTimeElapsed = 0
                zone.isHolding = false
                clearHoldAuthorityLocal(zone)
                zone.isContested = false
                zone.isPaused = false
                zone.holdStartTime = nil
                contestedStartedAt[zone.id] = nil

                zone.holdTimeRequired = 120

                local prevOwner = ResolveLocalFailedCaptureOwner(zone)
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

                zone.updatedAt = time()
                if Overlord.Sync then
                    -- force=true : revert decide par un joueur present sur le disque = etat final
                    -- one-shot ; doit passer les gates login et le canal en critical (regle dure).
                    Overlord.Sync:BroadcastZoneState(zone, true)
                end
                if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                    Overlord.CaptureLease:Complete(zone)
                end
                Overlord.Zones:UpdateAvailableZones()
                self:TryChatEnemyCaptureReversed(zone)

                Overlord:SaveState()
                if Overlord.UI then
                    Overlord.UI:RequestRefresh()
                end
                return
            end

            -- Sync periodique meme en conteste (pour que les autres voient la regression)
            local now = GetTime()
            if Overlord.Sync and (not lastZSBroadcast[zone.id] or now - lastZSBroadcast[zone.id] >= ZS_BROADCAST_INTERVAL) then
                zone.updatedAt = time()
                Overlord.Sync:BroadcastZoneState(zone)
                lastZSBroadcast[zone.id] = now
            end
        elseif enemyIsCapturing then
            -- L'ennemi possedait la zone mais a quitte (0 ennemis visibles).
            -- Le timer continue a decroitre : on ne capture PAS pour notre faction
            -- avec la progression de l'ennemi. A 0, revert a previousOwner.
            if zone.isContested then
                zone.isContested = false
                contestedStartedAt[zone.id] = nil
                TryChatZoneSecured(zone)
            end
            zone.isPaused = false
            zone.holdTimeElapsed = math.max(0, (zone.holdTimeElapsed or 0) - deltaTime)

            if zone.holdTimeElapsed <= 0 then
                local wasLocalAuthority = zone.holdAuthorityLocal == true
                if wasLocalAuthority and Overlord.CaptureLease
                    and Overlord.CaptureLease.BroadcastLocalRelease then
                    Overlord.CaptureLease:BroadcastLocalRelease(zone)
                end
                zone.holdTimeElapsed = 0
                zone.isHolding = false
                clearHoldAuthorityLocal(zone)
                zone.isContested = false
                zone.isPaused = false
                zone.holdStartTime = nil

                zone.holdTimeRequired = 120

                local prevOwner = ResolveLocalFailedCaptureOwner(zone)
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

                zone.updatedAt = time()
                if Overlord.Sync then
                    -- force=true : revert decide par un joueur present sur le disque = etat final
                    -- one-shot ; doit passer les gates login et le canal en critical (regle dure).
                    Overlord.Sync:BroadcastZoneState(zone, true)
                end
                if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
                    Overlord.CaptureLease:Complete(zone)
                end
                Overlord.Zones:UpdateAvailableZones()
                self:TryChatEnemyCaptureReversed(zone)

                Overlord:SaveState()
                if Overlord.UI then
                    Overlord.UI:RequestRefresh()
                end
                return
            end

            -- Sync periodique (pour que les autres voient la regression)
            local now = GetTime()
            if Overlord.Sync and (not lastZSBroadcast[zone.id] or now - lastZSBroadcast[zone.id] >= ZS_BROADCAST_INTERVAL) then
                zone.updatedAt = time()
                Overlord.Sync:BroadcastZoneState(zone)
                lastZSBroadcast[zone.id] = now
            end
        else
            -- CAPTURING : le timer monte
            if zone.isContested then
                zone.isContested = false
                contestedStartedAt[zone.id] = nil
                TryChatZoneSecured(zone)
            end
            if zone.isPaused then
                zone.isPaused = false
                TryChatBackInZone(zone)
            end

            if zone.holdAuthorityLocal or MaybeTakeOverStaleAllyCaptureAuthority(zone) then
                zone.holdTimeElapsed = (zone.holdTimeElapsed or 0) + deltaTime

                -- Sync du timer aux autres joueurs
                local now = GetTime()
                if Overlord.Sync and (not lastZSBroadcast[zone.id] or now - lastZSBroadcast[zone.id] >= ZS_BROADCAST_INTERVAL) then
                    zone.updatedAt = time()
                    Overlord.Sync:BroadcastZoneState(zone)
                    lastZSBroadcast[zone.id] = now
                end

                if (zone.holdTimeElapsed or 0) >= (zone.holdTimeRequired or 120) then
                    self:CaptureZone(zone)
                end
            end
            -- Co-captureur sans autorite : timer pousse par le ZS du capteur officiel uniquement.
        end
    else
        -- LOSING : hors de la zone, le timer decroit
        -- Exception : quand l'ENNEMI capture, on arrete de participer (mort, fantome, ou juste quitte)
        -- Sinon on decrementerait et broadcasterait, bloquant la progression du capteur ennemi
        if zone.owner == Overlord.Zones:GetEnemyFaction() then
            zone.isHolding = false
            clearHoldAuthorityLocal(zone)
            zone.isContested = false
            zone.isPaused = false
            zone.holdStartTime = nil
            -- Ne pas effacer previousOwner : necessaire pour restaurer la faction d'origine
            -- si l'ennemi abandonne sans terminer (reprise quand on revient dans la zone).
            return
        end

        -- Co-captureur sans autorite : ne pas decay ni revert (seul le capteur officiel tranche).
        if zone.owner == Overlord.PlayerFaction and not zone.holdAuthorityLocal then
            zone.isHolding = false
            zone.isContested = false
            zone.isPaused = false
            zone.holdStartTime = nil
            return
        end

        zone.isContested = false
        contestedStartedAt[zone.id] = nil
        if not zone.isPaused then
            zone.isPaused = true
            TryChatLeftZone(zone)
        end

        zone.holdTimeElapsed = (zone.holdTimeElapsed or 0) - deltaTime

        if zone.holdTimeElapsed <= 0 then
            if zone.holdAuthorityLocal and Overlord.CaptureLease
                and Overlord.CaptureLease.BroadcastLocalRelease then
                Overlord.CaptureLease:BroadcastLocalRelease(zone)
            end
            zone.holdTimeElapsed = 0
            zone.isHolding = false
            clearHoldAuthorityLocal(zone)
            zone.isPaused = false
            zone.holdStartTime = nil

            zone.holdTimeRequired = 120

            -- Restaure le proprietaire d'avant la tentative de capture.
            -- previousOwner est sauvegarde au moment ou la capture demarre (StartHoldTimer)
            -- OU quand un ZS ennemi arrive (OnReceiveZoneState, avant l'ecrasement de owner).
            -- Couvre : echec de notre capture ET succes de notre contestation ennemie.
            local prevOwner = ResolveLocalFailedCaptureOwner(zone)
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

            -- Broadcast AVANT UpdateAvailableZones : envoie l'etat reel aux autres joueurs
            -- (captured par le proprio precedent), puis recalcule localement la disponibilite
            zone.updatedAt = time()
            if Overlord.Sync then
                Overlord.Sync:BroadcastZoneState(zone, true)
            end
            if Overlord.CaptureLease and Overlord.CaptureLease.ClearLocal then
                Overlord.CaptureLease:ClearLocal(zone)
            end
            Overlord.Zones:UpdateAvailableZones()
            Overlord:PrintNotification(string.format("|cFFFF0000[Overlord]|r " .. L.CAPTURE_LOST, zone.name))

            Overlord:SaveState()
            if Overlord.UI then
                Overlord.UI:RequestRefresh()
            end
        end
    end
end

-- Sortie de front / instance : StopUpdateLoop() empeche LOSING ; sans nettoyage, isHolding et
-- in_progress stale bloquent la sync passive et figent le panneau spectateur (ex. mine a 1:47).
function Overlord.ZoneControl:ReleaseLocalCaptureState(allowFinalRewrite)
    local changed = false
    for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
        if zone.holdAuthorityLocal then
            -- Capture demarree localement : revert meme si la sync a deja coupe isHolding
            -- (sinon in_progress orange fige quand on quitte tout le front / la carte).
            Overlord.Zones:RevertInterruptedCapture(zone, allowFinalRewrite ~= false)
            changed = true
        elseif zone.status == "in_progress" and zone._restoredInProgress then
            -- Un reload peut restaurer un timer avant que l'initialisation ne
            -- decouvre l'instance. Il n'a encore aucune autorite locale mais ne
            -- doit pas survivre a toute la suspension puis ressortir orange.
            Overlord.Zones:RevertInterruptedCapture(zone, false)
            changed = true
        elseif zone.isHolding then
            -- Observateur isHolding pose par la sync : debloquer les merges entrants
            zone.isHolding = false
            zone.isPaused = false
            zone.isContested = false
            zone.holdStartTime = nil
            clearHoldAuthorityLocal(zone)
            changed = true
        end
    end
    if changed then
        Overlord.Zones:UpdateAvailableZones()
        Overlord:MarkDirty()
        Overlord:SaveState()
        if Overlord.UI then Overlord.UI:RequestRefresh() end
    end
    return changed
end

function Overlord.ZoneControl:OnInstanceSuspend()
    -- ZR + bail local : ne pas reecrire un faux etat final chez les observateurs.
    self:ReleaseLocalCaptureState(false)
end

-- Compte les allies et ennemis a proximite.
-- Allies : membres du groupe/raid dans le rayon de la zone (position carte precise)
--          + nameplates allies visibles hors-groupe (dedoublonnes pour eviter de compter 2x).
-- Ennemis : nameplates hostiles visibles (portee ~40-60y, fiable en War Mode).
-- Tables recyclees pour eviter les allocations et les rescans raid/nameplate (1x/s).
local scanCountedFriendly = {}
local scanGroupUnitKeys = {}
local scanSeenNameplateKeys = {}
local scanAuraResultByGUID = {}

local function GetScanUnitIdentity(unit)
    local guid = GetAccessibleUnitGUID(unit)
    if guid then return guid, guid end
    return AccessibleStringKey(Overlord:SafeGetUnitName(unit, true)), nil
end

-- Cache du dernier scan pour eviter le double scan (ZoneControl:Update + UI:RefreshForces)
local lastScanResult = { friendly = 0, enemy = 0, enemyRaw = 0, visibleEnemy = 0, time = 0, zoneId = nil }
local NEARBY_SCAN_CACHE_SECONDS = 2.0

function Overlord.ZoneControl:GetCachedScan()
    return lastScanResult
end

function Overlord.ZoneControl:ScanNearbyPlayers(zone)
    local now = GetTime()
    if lastScanResult.zoneId == zone.id and now - lastScanResult.time < NEARBY_SCAN_CACHE_SECONDS then
        return lastScanResult.friendly, lastScanResult.enemy
    end

    local friendlyCount = UnitCountsForCapture("player")
    local enemyCount = 0
    local visibleEnemyCount = 0
    local enemyFaction = Overlord.Zones:GetEnemyFaction()
    wipe(scanCountedFriendly)
    wipe(scanGroupUnitKeys)
    wipe(scanSeenNameplateKeys)
    wipe(scanAuraResultByGUID)
    local countedFriendly = scanCountedFriendly
    local groupUnitKeys = scanGroupUnitKeys
    local seenNameplateKeys = scanSeenNameplateKeys
    local auraResultByGUID = scanAuraResultByGUID

    -- Allies du groupe/raid : position carte precise, dans le rayon de la zone
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID then
        local prefix, count
        if IsInRaid() then
            prefix, count = "raid", 40
        elseif IsInGroup() then
            prefix, count = "party", 4
        end

        if prefix then
            local ar = Overlord.Zones:GetMapAspectRatio()
            local cx, cy = zone.center[1], zone.center[2]
            local r2 = zone.radius * zone.radius
            for i = 1, count do
                local unit = prefix .. i
                if UnitExists(unit) and not UnitIsDead(unit) and not UnitIsGhost(unit)
                   and not UnitIsUnit(unit, "player") then
                    local identity, guid = GetScanUnitIdentity(unit)
                    local firstGroupIdentity = not identity or not groupUnitKeys[identity]
                    if identity then groupUnitKeys[identity] = true end

                    -- La geometrie est bien moins couteuse qu'un balayage de 40 auras : ne verifier
                    -- l'eligibilite que pour les membres reellement dans le disque de capture.
                    if firstGroupIdentity then
                        local pos = C_Map.GetPlayerMapPosition(mapID, unit)
                        if pos then
                            local ux, uy = pos:GetXY()
                            if ux then
                                local dx = cx - ux * 100
                                local dy = (cy - uy * 100) * ar
                                if (dx * dx + dy * dy) <= r2
                                   and (not identity or not countedFriendly[identity])
                                   and not IsUnitInNonCaptureState(unit, auraResultByGUID, guid) then
                                    -- +1 (pas UnitCountsForCapture) : l'etat non-capturable est deja verifie.
                                    friendlyCount = friendlyCount + 1
                                    if identity then countedFriendly[identity] = true end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Nameplates : ennemis + allies hors-groupe (cross-realm non-groupes, etc.)
    -- WoW 12.0.5 : SafeGetUnitName gere les secret values
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsDead(unit) and not UnitIsGhost(unit) then
            local identity, guid = GetScanUnitIdentity(unit)
            -- Un membre du groupe peut aussi avoir une nameplate. L'ignorer avant les auras
            -- evite le double comptage et un second scan de la meme unite. Meme protection pour
            -- les alias nameplate dupliques.
            -- Un membre du groupe hors du disque n'a pas ete compte par la passe
            -- positionnelle : sa nameplate doit encore suivre la regle historique.
            -- Seuls les membres effectivement comptes et les alias nameplate sont
            -- des doublons ici.
            local duplicate = identity
                and (countedFriendly[identity] or seenNameplateKeys[identity])
            if not duplicate then
                if identity then seenNameplateKeys[identity] = true end

                local faction = UnitFactionGroup(unit)
                if faction == enemyFaction then
                    visibleEnemyCount = visibleEnemyCount + 1
                    if not IsUnitIneligibleToContest(unit, auraResultByGUID, guid) then
                        -- +1 (pas UnitCountsForCapture) : l'etat non-capturable est deja verifie.
                        enemyCount = enemyCount + 1
                    end
                elseif faction == Overlord.PlayerFaction and not UnitIsUnit(unit, "player")
                    and identity and not countedFriendly[identity]
                    and not IsUnitInNonCaptureState(unit, auraResultByGUID, guid) then
                    countedFriendly[identity] = true
                    -- +1 (pas UnitCountsForCapture) : l'etat non-capturable est deja verifie.
                    friendlyCount = friendlyCount + 1
                end
            end
        end
    end

    lastScanResult.enemyRaw = enemyCount
    lastScanResult.visibleEnemy = visibleEnemyCount

    lastScanResult.friendly = friendlyCount
    lastScanResult.enemy = enemyCount
    lastScanResult.time = now
    lastScanResult.zoneId = zone.id

    return friendlyCount, enemyCount
end

-- Capture une zone (objectif atteint)
function Overlord.ZoneControl:CaptureZone(zone)
    -- Avant d'ecraser owner : necessaire pour ClearLbCaptureBatchDedup (recapture depuis l'ennemi).
    local ownerBeforeCapture = zone.owner
    -- Conserver le contrat termine avant de remettre l'etat stable a 120. Il est
    -- lie au claim C/ZS et verifie par les temoins physiques (Renfort/Barricade).
    local completedHoldRequirement = tonumber(zone.holdTimeRequired) or 120
    zone.previousOwner = nil
    zone._assaultFromAvailable = nil
    zone.status = "captured"
    zone._captureFinalUnattested = nil
    zone._captureFinalUnattestedOriginKey = nil
    zone._captureFinalUnattestedWaveId = nil
    zone._captureFinalUnattestedAt = nil
    -- Une capture terminee physiquement est la nouvelle verite locale. Lever la
    -- quarantaine AVANT C/ZS pour que le final et son snapshot soient diffuses
    -- et comptes par la domination. Ne pas utiliser le nettoyeur generique :
    -- la wave locale et sa preuve temporelle sont encore requises par C/ZS.
    zone._loginSyncUnconfirmed = nil
    zone.owner = Overlord.PlayerFaction
    zone.isHolding = false
    clearHoldAuthorityLocal(zone)
    zone.zsOfficialCapturerName = nil
    zone._zsOfficialCapturerSeenAt = nil
    zone.holdTimeElapsed = 0
    zone.holdStartTime = nil
    local now = time()
    zone.capturedTime = now
    zone.updatedAt = now
    zone.holdTimeRequired = 120

    -- Meme logique que Sync:OnReceiveCapture : evite +2 quand un allie envoie aussi un "C"
    -- apres son propre CaptureZone (deux joueurs sur le point).
    local capTs = zone.capturedTime
    local pname = Overlord.Sync and Overlord.Sync.GetPlayerFullName and Overlord.Sync:GetPlayerFullName()
    -- Prise sur l'ennemi / neutre : effacer le marqueur LB pour ne pas bloquer le credit (ancien ts local).
    if Overlord.Sync and ownerBeforeCapture and ownerBeforeCapture ~= Overlord.PlayerFaction then
        Overlord.Sync:ClearLbCaptureBatchDedup(zone.id)
    end
    if Overlord.Sync and pname and pname ~= ""
        and not Overlord.Sync:ShouldSkipDuplicateLbCaptureBatch(zone.id, capTs, pname) then
        local capFac = Overlord.PlayerFaction
        -- Classement captures : uniquement le declencheur (joueur local qui a complete la capture).
        if capFac == "Alliance" or capFac == "Horde" then
            Overlord.Leaderboard:SetPlayerFaction(pname, capFac)
        end
        local _, cls = UnitClass("player")
        if cls and Overlord.Sync and Overlord.Sync.IsValidCaptureClassToken
            and Overlord.Sync:IsValidCaptureClassToken(cls) then
            Overlord.Leaderboard:SetPlayerClassFromSync(pname, cls)
        end
        Overlord.Leaderboard:AddPlayerCapture(pname, zone.id)
        Overlord.Sync:MarkLbCaptureBatchCredited(zone.id, capTs, pname)
    end

    -- Broadcast la capture (declencheur seul dans le payload C ; voir Sync.BroadcastCapture)
    if Overlord.Sync then
        Overlord.Sync:BroadcastCapture(zone.id, completedHoldRequirement)
        -- Envoie aussi un ZS "captured" pour redondance : si le message C est perdu
        -- (throttle WoW, canal non joint), le ZS seul suffit a promouvoir la zone.
        -- Sans ca, la zone reste in_progress chez les clients distants et le timeout
        -- stale de 45s finit par la reverter (bug "toute la map revert").
        Overlord.Sync:BroadcastZoneState(zone, true)
        -- Reset le cooldown d'alerte ennemie : si l'ennemi re-tag juste apres notre
        -- capture locale, l'alerte doit partir immediatement (sinon silence garanti)
        Overlord.Sync:ResetEnemyCaptureAlert(zone.id)
        if Overlord.Sync.ScheduleControlledZoneSnapshot then
            Overlord.Sync:ScheduleControlledZoneSnapshot("capture", {
                force = true,
                cooldown = 8,
                jitterMin = 1.0,
                jitterMax = 3.5,
            })
        end
    end
    if Overlord.CaptureLease and Overlord.CaptureLease.Complete then
        Overlord.CaptureLease:Complete(zone)
    end
    
    -- Notification visuelle
    local factionName = Overlord.Zones:GetFactionName()
    Overlord:PrintNotification(string.format("|cFF00FF00[Overlord]|r " .. L.ZONE_CAPTURED_BY, zone.name, factionName))
    
    -- Son de victoire (pcall pour eviter taint si SOUNDKIT indisponible)
    if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
    end
    
    -- Debloque les zones suivantes (UpdateAvailableZones affiche deja les notifications)
    Overlord.Zones:UpdateAvailableZones()

    -- Victoire totale : uniquement en capturant la capitale ennemie.
    -- NE PAS utiliser GetCapturedCount() == GetTotalCount() : les SavedVariables d'une session
    -- precedente peuvent conserver owner=PlayerFaction sur toutes les zones, ce qui ferait
    -- declencher OnTotalVictory() des la premiere capture de la nouvelle campagne (faux positif
    -- qui pose une treve de 2h sur la capitale ennemie et affiche l'ecran de victoire a tort).
    local enemyBaseId = Overlord.Fronts and Overlord.Fronts:GetEnemyCapitalId(Overlord.PlayerFaction)
    if zone.id == enemyBaseId then
        self:OnTotalVictory()
    end
    
    -- Sauvegarde et refresh
    Overlord:SaveState()
    if Overlord.NotifyDominationOwnersChanged then
        Overlord:NotifyDominationOwnersChanged()
    end
    if Overlord.UI then
        Overlord.UI:RequestRefresh()
    end
end

-- Total fiable pour l'ecran de victoire : killsCurrent peut etre remis a 0 par un C distant
-- alors que allyKillsCurrent / enemyKillsCurrent conservent les kills de l'assaut.
local function GetZoneCampaignKillCount(zone)
    if not zone then return 0 end
    local total = zone.killsCurrent or 0
    local byFaction = (zone.allyKillsCurrent or 0) + (zone.enemyKillsCurrent or 0)
    return (byFaction > total) and byFaction or total
end

-- Snapshot des kills comptabilises sur les zones du front actif (sans reset).
-- allyKills / enemyKills : totaux absolus Alliance / Horde (indispensable pour l'ecran TV).
function Overlord.ZoneControl:BuildCampaignKillSnapshot(factionUpper)
    if not OverlordDB or not Overlord.ZoneDatabase then return nil end
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local frontId = front and front.id
    local snapshot = {
        faction    = factionUpper,
        allyKills  = 0,
        enemyKills = 0,
        totalKills = 0,
        zones      = {},
        campaignId = OverlordDB.campaignId,
        frontId    = frontId,
    }
    -- Totaux : toujours sur l'ensemble complet du front (ZoneDatabase) pour que les sommes
    -- allyKills / enemyKills restent identiques quoi qu'il arrive (payload TV inchange).
    -- displayOrder ne sert qu'a ORDONNER l'affichage, jamais a filtrer les zones sommees.
    local orderIndex
    if frontId and Overlord.Zones and Overlord.Zones.GetDisplayOrderForFront then
        local ordered = Overlord.Zones:GetDisplayOrderForFront(frontId)
        if ordered and #ordered > 0 then
            orderIndex = {}
            for i, z in ipairs(ordered) do
                orderIndex[z.id] = i
            end
        end
    end
    local entries = {}
    for _, zone in ipairs(Overlord.ZoneDatabase) do
        local ally  = zone.allyKillsCurrent  or 0
        local enemy = zone.enemyKillsCurrent or 0
        local total = GetZoneCampaignKillCount(zone)
        snapshot.allyKills  = snapshot.allyKills  + ally
        snapshot.enemyKills = snapshot.enemyKills + enemy
        snapshot.totalKills = snapshot.totalKills + total
        entries[#entries + 1] = {
            name = zone.name,
            kills = total,
            ord = (orderIndex and orderIndex[zone.id]) or math.huge,
            seq = #entries + 1,
        }
    end
    -- Tri stable : ordre du panneau si connu, sinon ordre d'origine (zones hors displayOrder en fin).
    table.sort(entries, function(a, b)
        if a.ord ~= b.ord then return a.ord < b.ord end
        return a.seq < b.seq
    end)
    for _, e in ipairs(entries) do
        snapshot.zones[#snapshot.zones + 1] = { name = e.name, kills = e.kills }
    end
    return snapshot
end

-- Met a jour lastCampaignStats depuis l'etat courant des zones (victoire detectee par sync avant TV).
function Overlord.ZoneControl:WriteLastCampaignStatsFromCurrentZones(factionUpper)
    local snap = self:BuildCampaignKillSnapshot(factionUpper)
    if snap and OverlordDB then
        OverlordDB.lastCampaignStats = snap
    end
end

-- Victoire totale (toutes les zones capturees)
function Overlord.ZoneControl:OnTotalVictory()
    local factionUpper = (Overlord.PlayerFaction == "Horde") and L.VICTORY_FACTION_HORDE or L.VICTORY_FACTION_ALLIANCE
    local victoryTs = time()
    local front = Overlord.Fronts and Overlord.Fronts:GetCurrentFront()
    local frontId = front and front.id
    local victoryBonusGranted = false

    -- Enregistre le timestamp et la faction gagnante pour la treve post-victoire (front entier, 15 min).
    -- OnTotalVictory est uniquement declenche localement (le joueur vient de capturer
    -- la capitale ennemie lui-meme) : c'est une source de verite absolue, jamais stale.
    if OverlordDB then
        if Overlord.Zones and Overlord.Zones.SetVictoryCooldown then
            Overlord.Zones:SetVictoryCooldown(frontId, Overlord.PlayerFaction, victoryTs)
        end
        if Overlord.TryGrantVictoryDominationBonus then
            victoryBonusGranted = Overlord:TryGrantVictoryDominationBonus(
                frontId, Overlord.PlayerFaction, victoryTs, true) == true
        end
        if Overlord.Sync and Overlord.Sync.MarkPostVictorySyncGuard then
            Overlord.Sync:MarkPostVictorySyncGuard(frontId)
        end
    end

    -- Snapshot des kills sur ce front avant le reset immediat des compteurs de zone.
    if OverlordDB and Overlord.ZoneDatabase then
        local snapshot = self:BuildCampaignKillSnapshot(factionUpper)
        if snapshot then
            OverlordDB.lastCampaignStats = snapshot
        end
    end

    -- Meme force-sync que les recepteurs du TV : une victoire totale fige toute la carte
    -- au gagnant avant que d'anciens C/ZS/ZA puissent repeindre quelques zones.
    if Overlord.Zones and Overlord.Zones.ForceSyncFrontToWinner then
        Overlord.Zones:ForceSyncFrontToWinner(frontId, Overlord.PlayerFaction, victoryTs, true)
    end

    if Overlord.LifetimeStats and Overlord.LifetimeStats.AddTotalVictory then
        Overlord.LifetimeStats:AddTotalVictory(frontId)
    end

    -- Ecran de victoire (totaux = snapshot zone, pas le classement hebdo multi-fronts)
    if Overlord.UI then
        Overlord.UI:ShowVictoryScreen(factionUpper)
    end

    -- Broadcast a TOUS les joueurs addon (meme hors front)
    if Overlord.Sync then
        -- TV precede toujours VB : les recepteurs peuvent valider le bonus contre
        -- la victoire correspondante avant de persister l'evenement hebdomadaire.
        local victoryBonusPayload
        if victoryBonusGranted and Overlord.Sync.BuildVictoryBonusPayloadForVictory then
            victoryBonusPayload = Overlord.Sync:BuildVictoryBonusPayloadForVictory(
                frontId, Overlord.PlayerFaction, victoryTs)
        end
        Overlord.Sync:BroadcastTotalVictory(victoryTs, victoryBonusPayload)
    end
end

-- WoW 12.0.5 : Suspend/Resume pour eviter le taint en instance
-- UNIT_AURA fire des centaines de fois par seconde en combat et taint l'execution
function Overlord.ZoneControl:Suspend()
    mountFrame:UnregisterAllEvents()
end

function Overlord.ZoneControl:Resume()
    -- RegisterUnitEvent filtre cote C++ : seul "player" dispatch vers Lua.
    -- RegisterEvent("UNIT_AURA") sans filtre fire pour TOUTES les unites en vue
    -- (centaines/sec en PvP 15v15+) ; meme avec early-return le dispatch coute cher.
    mountFrame:RegisterUnitEvent("UNIT_AURA", "player")
    mountFrame:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", "player")
    mountFrame:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")
end
