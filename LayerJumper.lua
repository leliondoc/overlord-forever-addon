-- LayerJumper.lua : changer de layer a la demande (Overlord Forever).
--
-- Un passeur (joueur Overlord de la meme zone, sur un autre layer) t'invite ; hors
-- combat, le jeu te deplace sur le layer du chef de groupe en quelques secondes,
-- puis Overlord quitte le groupe. Principes :
--   * rien d'automatique tant que personne ne clique (l'ancienne invitation entre
--     couches, retiree en 1.2.4, etait jugee intrusive) ;
--   * passeurs volontaires seulement : « Aider les autres » est desactive par defaut ;
--     un volontaire invite automatiquement, sans aucune fenetre chez personne ;
--   * messages addon invisibles, prefixe dedie : une recherche (guilde + canal), puis
--     des chuchotements directs. Rien ne passe par le relais, aucune reponse relayee ;
--   * les reponses sont eclaircies par un pourcentage porte dans la requete, appris
--     par zone et plafonne a 40 % par le passeur lui-meme (pas d'amplificateur) ;
--   * le partenaire d'un saut n'obtient aucune confiance de groupe de la synchro, et
--     le groupe a deux du saut ne declenche aucun rattrapage de synchro.
--
-- Protocole (prefixe OverlordLJ, champs separes par ":") :
--   Q:1:<req>:<mapID>:<monLayer|->:<voulu|*>:<pct>:<A|H>   recherche (GUILD + CHANNEL)
--   A:<req>:<layer>                                         volontaire dispo (WHISPER)
--   R:<req>                                                  demande d'invitation (WHISPER)
--   N:<req>:<raison>                                         refus / indisponible (WHISPER)

Overlord = Overlord or {}
local L = Overlord.L or {}
local LJ = Overlord.LayerJumper or {}
Overlord.LayerJumper = LJ

local securecall = securecall or function(fn, ...) return fn(...) end

LJ.PREFIX = "OverlordLJ"
LJ.PROTOCOL = "1"
LJ.SEARCH_COOLDOWN = 20        -- s entre deux recherches emises
LJ.SEARCH_WINDOW = 4           -- s de collecte des reponses
LJ.RESULT_TTL = 90             -- s de validite d'une liste de passeurs
LJ.INVITE_WAIT = 12            -- s d'attente de l'invitation du passeur
LJ.JOIN_WAIT = 10              -- s entre l'acceptation et l'entree dans le groupe
LJ.VERIFY_TIMEOUT = 40         -- s hors combat pour constater le nouveau layer
LJ.MAX_ATTEMPTS = 4            -- passeurs essayes par saut
LJ.MAX_RESULTS = 16            -- reponses gardees par recherche
LJ.DEFAULT_PCT = 20            -- part des passeurs qui repond a une premiere recherche
LJ.MIN_PCT = 2
LJ.LAYER_FRESH = 600           -- s de validite d'une lecture de layer dans la meme zone
LJ.SEEN_TTL = 7200             -- s de memoire des layers vus par zone (liste)
LJ.MAX_PCT = 40                -- plafond de la part qui repond (zone deja connue)
LJ.LARGE_ZONE_PCT = 10         -- depart dans une zone peuplee (Sync:IsLargeEvent)
LJ.PCT_TTL = 900               -- s : la part apprise pour une zone s'oublie
LJ.TARGET_REPLIES = 6          -- reponses visees par recherche
LJ.HOP_GROUP_GRACE = 8         -- s apres un saut ou les evenements de groupe restent « a nous »
LJ.HOP_PENDING = 15            -- s ou une invitation de passeur reste « en attente »
LJ.GUEST_INVITE_TTL = 70       -- s : au-dela, une invitation non acceptee est perimee
LJ.HELPER_REPLY_GAP = 8        -- passeur : une reponse au plus toutes les 8 s
LJ.HELPER_PER_SENDER_GAP = 20  -- passeur : une reponse au plus par demandeur toutes les 20 s
LJ.HELPER_INVITE_GAP = 15      -- passeur : une invitation au plus toutes les 15 s
LJ.HELPER_INVITES_PER_HOUR = 20
LJ.HELPER_SAME_REQUESTER_GAP = 600 -- volontaire : une invitation par demandeur toutes les 10 min
LJ.GUEST_KICK_AFTER = 120      -- filet : invite reste dans un groupe cree pour lui
LJ.OBSERVE_GAP = 5             -- lecture de nameplates au plus toutes les 5 s au repos

LJ.state = LJ.state or "idle"  -- idle | searching | ready | requesting | joining | verifying
LJ.results = LJ.results or {}
LJ.seenLayers = LJ.seenLayers or {}
LJ.mine = LJ.mine or {}
LJ.pctByMap = LJ.pctByMap or {}
LJ.answered = LJ.answered or {}
LJ.guests = LJ.guests or {}
LJ.inviteLog = LJ.inviteLog or {}
LJ.repliedTo = LJ.repliedTo or {}
LJ.partners = LJ.partners or {}
LJ.invitedAt = LJ.invitedAt or {}

local function Now() return GetTime() end

local function Print(text)
    if not text or text == "" then return end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    elseif print then
        print("[Overlord] " .. text)
    end
end

local function T(key, fallback) return L[key] or fallback end
local GroupHasMember -- defini avec le cote passeur

-- "Prenom Nom-Royaume" ou "Prenom Nom" -> "prenom nom" (cle de comparaison).
local function NameKey(name)
    if type(name) ~= "string" then return nil end
    local base = name:match("^([^%-]+)") or name
    base = base:gsub("^%s+", ""):gsub("%s+$", "")
    if base == "" or #base > 60 or base:find("[%c:|]") then return nil end
    return base:lower()
end
LJ.NameKey = NameKey

local function SameName(a, b)
    if NameKey(a) == nil or NameKey(a) ~= NameKey(b) then return false end
    local ra, rb = a:match("%-(.+)$"), b:match("%-(.+)$")
    if not (ra and rb) then return true end
    -- Le meme royaume peut s'ecrire avec ou sans espaces / apostrophes selon l'API.
    return ra:gsub("[%s%-']", ""):lower() == rb:gsub("[%s%-']", ""):lower()
end
LJ.SameName = SameName

local function Hash100(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h % 100
end
LJ.Hash100 = Hash100

local function SafeBool(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, ...)
    return (ok and value) and true or false
end

local function MyFactionChar()
    local faction = Overlord.PlayerFaction
    if not faction and UnitFactionGroup then
        local ok, f = pcall(UnitFactionGroup, "player")
        faction = ok and f or nil
    end
    if faction == "Horde" then return "H" end
    if faction == "Alliance" then return "A" end
    return nil
end

function LJ:MyKey()
    if not self._myKey and UnitName then
        local ok, name = pcall(UnitName, "player")
        self._myKey = ok and NameKey(name) or nil
    end
    return self._myKey
end

-- ============================================================
-- Configuration
-- ============================================================

-- « auto » = volontaire (invite automatiquement), « off » = jamais. Un ancien
-- reglage « ask » (fenetre de demande, retiree) vaut « off ».
local HELP_MODES = { auto = true, off = true }

function LJ:GetHelpMode()
    local cfg = OverlordDB and OverlordDB.config
    local mode = cfg and cfg.layerHelpMode
    if HELP_MODES[mode] then return mode end
    return "off"
end

function LJ:SetHelpMode(mode)
    if not HELP_MODES[mode] then return end
    if OverlordDB then
        OverlordDB.config = OverlordDB.config or {}
        OverlordDB.config.layerHelpMode = mode
    end
    self:RefreshUI()
end

function LJ:HelpModeLabel(mode)
    mode = mode or self:GetHelpMode()
    if mode == "auto" then return T("LJ_HELP_MODE_AUTO", "on") end
    return T("LJ_HELP_MODE_OFF", "off")
end

-- ============================================================
-- Contexte : zone, instance, groupe
-- ============================================================

-- Le ZoneUID d'un PNJ n'a de sens que dans sa zone : on remonte la micro-carte
-- (grotte, sous-zone) jusqu'a la carte de zone.
function LJ:CurrentZone()
    local now = Now()
    if self._zoneAt and now - self._zoneAt < 1 then return self._zone end
    self._zone, self._zoneAt = self:ReadZone(), now
    return self._zone
end

function LJ:ReadZone()
    if not C_Map or not C_Map.GetBestMapForUnit then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or type(mapID) ~= "number" or mapID <= 0 then return nil end
    if not C_Map.GetMapInfo then return mapID end
    for _ = 1, 6 do
        local okInfo, info = pcall(C_Map.GetMapInfo, mapID)
        if not okInfo or type(info) ~= "table" then return mapID end
        if (tonumber(info.mapType) or 3) <= 3 then return mapID end
        local parent = tonumber(info.parentMapID)
        if not parent or parent <= 0 then return mapID end
        mapID = parent
    end
    return mapID
end

function LJ:ZoneName(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then return "?" end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    return ok and type(info) == "table" and info.name or "?"
end

function LJ:InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

function LJ:InCombat()
    return SafeBool(InCombatLockdown) or SafeBool(UnitAffectingCombat, "player")
end

function LJ:InBattlegroundQueue()
    if not GetMaxBattlefieldID or not GetBattlefieldStatus then return false end
    local ok, maxId = pcall(GetMaxBattlefieldID)
    for i = 1, (ok and tonumber(maxId) or 0) do
        local okS, status = pcall(GetBattlefieldStatus, i)
        if okS and (status == "queued" or status == "confirm") then return true end
    end
    return false
end

function LJ:IsGrouped()
    return SafeBool(IsInGroup) or SafeBool(IsInRaid)
end

function LJ:GroupSize()
    if not self:IsGrouped() then return 1 end
    local ok, n = pcall(GetNumGroupMembers)
    return ok and tonumber(n) or 1
end

-- Passeur seul uniquement : le groupe forme pour un saut ne compte que deux joueurs
-- (aucun raid ni groupe existant secoue par l'arrivee puis le depart de l'invite).
function LJ:CanHostGuest()
    return not self:IsGrouped()
end

-- ============================================================
-- Lecture locale du layer (aucun trafic)
-- ============================================================

local function ParseLayerFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local guidType, zero, _, _, zoneUid = strsplit("-", guid)
    if guidType ~= "Creature" and guidType ~= "Vehicle" and guidType ~= "GameObject" then return nil end
    if zero ~= "0" then return nil end
    local id = tonumber(zoneUid)
    if id and id > 0 and id < 100000000 then return id end
    return nil
end
LJ.ParseLayerFromGUID = ParseLayerFromGUID

-- Lecture stricte : ZoneUID d'un PNJ visible, jamais l'identifiant de continent que
-- le parseur des fronts renvoie quand le ZoneUID vaut 0. Fonctions nommees : aucun
-- closure alloue par plaque de nom.
local function ReadUnitLayerRaw(unit)
    if not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
    if UnitIsVisible and not UnitIsVisible(unit) then return nil end
    return ParseLayerFromGUID(UnitGUID(unit))
end

function LJ:ReadUnitLayer(unit)
    if self:InInstance() then return nil end
    local ok, id = pcall(ReadUnitLayerRaw, unit)
    return ok and id or nil
end

local function PlateUnit(plate) return plate.namePlateUnitToken end

local SCAN_UNITS = { "target", "mouseover", "focus", "softenemy", "softfriend", "softinteract" }

function LJ:ScanLayer()
    for i = 1, #SCAN_UNITS do
        local id = self:ReadUnitLayer(SCAN_UNITS[i])
        if id then return id end
    end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for i = 1, math.min(#plates, 40) do
                local readable, unit = pcall(PlateUnit, plates[i])
                if readable and unit then
                    local id = self:ReadUnitLayer(unit)
                    if id then return id end
                end
            end
        end
    end
    return nil
end

function LJ:RememberLayer(mapID, layer, at)
    if not mapID or layer == nil then return end
    local seen = self.seenLayers[mapID]
    if not seen then
        seen = {}
        self.seenLayers[mapID] = seen
    end
    seen[layer] = at or Now()
    local count, oldestId, oldestAt = 0, nil, nil
    for id, seenAt in pairs(seen) do
        if Now() - seenAt > self.SEEN_TTL then
            seen[id] = nil
        else
            count = count + 1
            if not oldestAt or seenAt < oldestAt then oldestId, oldestAt = id, seenAt end
        end
    end
    if count > 12 and oldestId then seen[oldestId] = nil end
end

function LJ:Observe(layer, mapID)
    if layer == nil then return false end
    mapID = mapID or self:CurrentZone()
    if not mapID then return false end
    local m = self.mine
    local changed = m.mapID ~= mapID or m.layer ~= layer
    m.mapID, m.layer, m.at = mapID, layer, Now()
    self:RememberLayer(mapID, layer, m.at)
    if self.state == "verifying" then self:CheckVerify() end
    if changed then self:RefreshUI() end
    return changed
end

function LJ:ObserveUnit(unit, force)
    if Overlord.InstanceSuspended then return end
    local now = Now()
    if not force then
        local gap = self.state == "verifying" and 1 or self.OBSERVE_GAP
        if now - (self._lastObserveAt or -100) < gap then return end
        -- Foule de joueurs : une tentative au plus toutes les 0,2 s, meme sans PNJ.
        if now - (self._lastObserveTry or -100) < 0.2 then return end
        self._lastObserveTry = now
    end
    local id = self:ReadUnitLayer(unit)
    if id then
        self._lastObserveAt = now
        self:Observe(id)
    end
end

-- Layer actuel dans la zone actuelle, ou nil s'il n'a pas ete lu (ou plus fiable).
function LJ:GetMyLayer(scan)
    local mapID = self:CurrentZone()
    if scan then
        local id = self:ScanLayer()
        if id then self:Observe(id, mapID) end
    end
    local m = self.mine
    if m.layer ~= nil and m.mapID == mapID and m.at
        and Now() - m.at <= self.LAYER_FRESH and m.at >= (self.layerDirtyAt or 0) then
        return m.layer, mapID
    end
    return nil, mapID
end

-- Le jeu ne numerote pas les layers : on affiche l'identifiant reel, sans rang invente.
function LJ:FormatLayer(mapID, layer)
    if layer == nil then return T("LJ_LAYER_UNKNOWN", "unknown") end
    return string.format(T("LJ_LAYER_NAME", "Layer #%s"), tostring(layer))
end

-- ============================================================
-- Transport
-- ============================================================

function LJ:Send(msg, chatType, target)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    if self:InInstance() then return false end
    local result = securecall(C_ChatInfo.SendAddonMessage, self.PREFIX, msg, chatType, target)
    local ok = result == nil or result == true or result == 0
    if chatType == "CHANNEL" and Overlord.Sync and Overlord.Sync.NoteChannelSendKind then
        Overlord.Sync:NoteChannelSendKind("LQ", ok, #msg)
    end
    return ok
end

function LJ:Whisper(target, msg)
    if type(target) ~= "string" or target == "" then return false end
    -- Meme filtre « Aucun joueur nomme X » que la synchro si la cible s'est deconnectee.
    local sync = Overlord.Sync
    if sync and sync.RegisterRecentWhisperTarget then sync:RegisterRecentWhisperTarget(target) end
    return self:Send(msg, "WHISPER", target)
end

-- Recherche : guilde (gratuite, hors quota canal) + canal Overlord. Le canal ne prend
-- qu'un jeton libre du budget de la synchro (jamais de dette) : sinon on reessaie
-- 1,3 s plus tard, trois fois au plus, tant que cette recherche est la courante.
function LJ:BroadcastQuery(msg, reqId)
    local sent = false
    if SafeBool(IsInGuild) then
        sent = self:Send(msg, "GUILD") or sent
    end
    self.querySent = sent
    local sync = Overlord.Sync
    if not (sync and sync.GetChannelId and sync:GetChannelId()) then return sent end
    local function tryChannel(attempt)
        if LJ.reqId ~= reqId or LJ.state ~= "searching" then return end
        local channelId = sync:GetChannelId()
        if not channelId then return end
        if sync.TakeChannelToken and not sync:TakeChannelToken(false) then
            if attempt < 3 then C_Timer.After(1.3, function() tryChannel(attempt + 1) end) end
            return
        end
        if LJ:Send(msg, "CHANNEL", channelId) then LJ.querySent = true end
    end
    tryChannel(1)
    return true
end

-- ============================================================
-- Cote demandeur
-- ============================================================

local function NewRequestId()
    local t = math.floor((time and time() or 0) % 65536)
    return string.format("%x%04x", t, math.random(0, 65535))
end

-- Garde-fou : aucune phase active ne peut rester bloquee (boutons grises a vie).
local PHASE_LIMIT = { searching = 15, requesting = 30, joining = 15 }

function LJ:SetState(state, statusKey, ...)
    self.state = state
    self.phaseDeadline = PHASE_LIMIT[state] and (Now() + PHASE_LIMIT[state]) or nil
    if statusKey then
        self.statusText = string.format(T(statusKey, statusKey), ...)
    end
    self:UpdateTicker()
    self:RefreshUI()
end

function LJ:IsActive()
    return self.state == "searching" or self.state == "requesting"
        or self.state == "joining" or self.state == "verifying"
end

-- Groupe forme ou quitte pour un saut (des deux cotes). La synchro n'en tire aucun
-- rattrapage : changer de layer sur le meme royaume ne change pas la carte.
-- Strict : un vrai groupe (plus de deux joueurs, ou sans le partenaire attendu)
-- garde son rattrapage normal, meme pendant un saut ou une invitation en attente.
function LJ:IsHopGroup()
    local now = Now()
    local grouped = self:IsGrouped()
    -- Le groupe d'un saut compte deux joueurs : un raid repond tout de suite, sans
    -- parcourir ses membres (appel par paquet du relais quand on est groupe).
    if grouped and self:GroupSize() > 2 then return false end
    if now < (self.hopGroupUntil or 0) then
        if not grouped then return true end
        -- Meme dans la grace, un groupe sans le partenaire du saut est un vrai groupe.
        local st = self.hopGroupKey and self:HopPairStatus(self.hopGroupKey)
        if st == "pair" or st == "pending" then return true end
    end
    local hop = self.hop
    if hop and hop.current and (self.state == "joining" or self.state == "verifying") then
        if not grouped then return true end
        local st = self:HopPairStatus(hop.current.key)
        return st == "pair" or st == "pending"
    end
    for key, guest in pairs(self.guests) do
        -- Une invitation jamais acceptee perime (celle de WoW expire avant) : un groupe
        -- forme plus tard avec ce joueur est un vrai groupe.
        if guest.joined or now - guest.at < self.GUEST_INVITE_TTL then
            if not grouped then
                -- Invitation en attente, ou invite parti apres un long saut.
                if guest.joined or now - guest.at < self.HOP_PENDING then return true end
            else
                local st = self:HopPairStatus(key)
                if st == "pair" then
                    guest.joined = true
                    self.hopPairSeen = true
                end
                if st == "pair" or st == "pending" then return true end
            end
        end
    end
    return false
end

-- Etat du groupe vu depuis le saut : "none", "pair" (nous + partenaire), "pending"
-- (a deux, nom du partenaire pas encore connu), "crowded" (partenaire + d'autres),
-- "foreign" (un groupe sans le partenaire, rejoint par une AUTRE invitation recue
-- depuis le debut du saut), "hijacked" (sans le partenaire et sans autre invitation :
-- on n'entre dans un groupe que par invitation, c'est donc un detournement).
function LJ:HopPairStatus(key)
    if not self:IsGrouped() then return "none" end
    local size = self:GroupSize()
    if key and GroupHasMember(key) then return size <= 2 and "pair" or "crowded" end
    if size <= 2 then
        local ok, name = pcall(UnitName, "party1")
        if not ok or name == nil or name == "" or name == UNKNOWNOBJECT then return "pending" end
    end
    -- Apres avoir vu la paire, un autre groupe sans depart entre les deux ne peut
    -- etre qu'un remplacement : jamais « foreign ».
    if not self.hopPairSeen and (self.otherInviteAt or -1) >= (self.hopEpochAt or 0) then
        return "foreign"
    end
    return "hijacked"
end

function LJ:MarkHopEpoch()
    self.hopEpochAt = Now()
    self.hopPairSeen = false
end

-- Le partenaire d'un saut (inconnu tire d'une liste publique) n'est jamais un
-- membre de confiance pour la synchro (Sync.lua SyncSenderIsInOurGroup).
function LJ:IsHopPartner(name)
    -- Pendant un saut, personne dans ce groupe n'est de confiance (meme un tiers
    -- que le passeur aurait invite).
    local hop = self.hop
    if hop and (self.state == "joining" or self.state == "verifying") then
        return not hop.current or self:HopPairStatus(hop.current.key) ~= "foreign"
    end
    -- Passeur : tant que l'invite est attendu ou dans le groupe, personne n'y est de
    -- confiance (sauf groupe rejoint par une autre invitation).
    if next(self.guests) ~= nil then
        local now = Now()
        for key, guest in pairs(self.guests) do
            if (guest.joined or now - guest.at < self.HOP_PENDING)
                and self:HopPairStatus(key) ~= "foreign" then
                return true
            end
        end
    end
    -- Juste apres un saut (depart du groupe en cours, grace) : meme regle.
    if Now() < (self.hopGroupUntil or 0) and self:IsGrouped()
        and self:HopPairStatus(self.hopGroupKey) ~= "foreign" then
        return true
    end
    if next(self.partners) == nil then return false end
    local now = Now()
    for k, untilAt in pairs(self.partners) do
        if now > untilAt then self.partners[k] = nil end
    end
    if next(self.partners) == nil then return false end
    local key = NameKey(name)
    local untilAt = key and self.partners[key]
    if not untilAt then return false end
    if Now() > untilAt then
        self.partners[key] = nil
        return false
    end
    return true
end

-- Ce joueur precis est-il le partenaire d'un saut (pas « tout le groupe ») ?
-- Sert aux contacts de proximite : les autres joueurs gardent leur synchro.
function LJ:IsNamedHopPartner(name)
    if not self.hop and next(self.guests) == nil and next(self.partners) == nil then return false end
    local key = NameKey(name)
    if not key then return false end
    local hop = self.hop
    if hop and hop.current and hop.current.key == key
        and (self.state == "joining" or self.state == "verifying") then
        return true
    end
    local guest = self.guests[key]
    if guest and (guest.joined or Now() - guest.at < self.HOP_PENDING) then return true end
    local untilAt = self.partners[key]
    return untilAt ~= nil and Now() <= untilAt
end

function LJ:MarkPartner(key, seconds)
    if not key then return end
    local now = Now()
    for k, untilAt in pairs(self.partners) do
        if now > untilAt then self.partners[k] = nil end
    end
    self.partners[key] = now + seconds
end

function LJ:MarkHopGroupEnding(partnerKey)
    self.hopGroupUntil = Now() + self.HOP_GROUP_GRACE
    if partnerKey then self.hopGroupKey = partnerKey end
    if OverlordDB then OverlordDB.layerJumperHop = nil end
end

-- Un /reload au milieu d'un saut efface l'etat : on garde juste de quoi ne pas faire
-- confiance au partenaire et sortir de son groupe au retour (3 min au plus).
function LJ:RememberHop(key)
    if OverlordDB and key and time then
        OverlordDB.layerJumperHop = { key = key, at = time() }
    end
end

function LJ:RestoreHopAfterReload()
    local rec = OverlordDB and OverlordDB.layerJumperHop
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    if type(rec) ~= "table" or type(rec.key) ~= "string" or not time then return end
    local left = 180 - (time() - (tonumber(rec.at) or 0))
    if left <= 0 or left > 180 then return end
    self:MarkPartner(rec.key, left)
    C_Timer.After(5, function()
        -- Seulement si le partenaire est vraiment la : un groupe d'amis reste intact.
        if Overlord.InstanceSuspended or LJ:InInstance() then return end
        if GroupHasMember(rec.key) then LJ:LeaveHopGroup(rec.key) end
    end)
end

function LJ:CheckRequesterBlocked(needsSolo)
    if self:InInstance() then return T("LJ_ERR_INSTANCE", "Not available in instances.") end
    if needsSolo and self:InBattlegroundQueue() then
        return T("LJ_ERR_QUEUE", "Not available while queued for a battleground.")
    end
    if needsSolo and self:IsGrouped() then
        return T("LJ_ERR_GROUPED", "Leave your group first.")
    end
    return nil
end

function LJ:ResultsFresh(mapID)
    return self.resultsReq ~= nil and self.resultsMap == mapID
        and Now() - (self.resultsAt or -1000) <= self.RESULT_TTL
end

-- target : nil (liste seule), "any" (n'importe quel autre layer) ou un identifiant.
function LJ:Search(target)
    if self:IsActive() then return false end
    local blocked = self:CheckRequesterBlocked(target ~= nil)
    if blocked then
        self.statusText = blocked
        self:RefreshUI()
        Print(blocked)
        return false
    end
    local myLayer, mapID = self:GetMyLayer(true)
    if not mapID then return false end
    if target ~= nil and target ~= "any" and target == myLayer then
        self.statusText = T("LJ_ERR_SAME_LAYER", "You are already on this layer.")
        self:RefreshUI()
        return false
    end
    -- « Autre layer » exige de connaitre le sien : sinon aucune preuve possible.
    if target == "any" and myLayer == nil then
        self.statusText = T("LJ_ERR_LAYER_UNKNOWN", "Target an NPC first to read your layer.")
        self:RefreshUI()
        return false
    end
    -- Une liste recente qui contient deja un passeur adapte evite une nouvelle recherche.
    if target ~= nil and self:ResultsFresh(mapID) and #self:BuildCandidates(target, myLayer) > 0 then
        return self:StartHop(target)
    end
    local now = Now()
    local wait = self.SEARCH_COOLDOWN - (now - (self.lastSearchAt or -1000))
    if wait > 0 then
        self.statusText = string.format(T("LJ_ERR_COOLDOWN", "Wait %d s before searching again."), math.ceil(wait))
        self:RefreshUI()
        return false
    end
    self.pendingTarget = target
    self.retryPct = nil
    if not self:SendQuery(mapID, myLayer, target) then
        self.pendingTarget = nil
        return false
    end
    self.lastSearchAt = now
    return true
end

-- Part des passeurs qui repond : apprise par zone (oubliee apres 15 min, plafonnee),
-- sinon basse dans une zone peuplee. Jamais d'amplificateur de reponses.
function LJ:StartPct(mapID)
    local learned = self.pctByMap[mapID]
    if type(learned) == "table" and Now() - (learned.at or -1e9) <= self.PCT_TTL then
        return learned.pct
    end
    local sync = Overlord.Sync
    if sync and sync.IsLargeEvent and sync:IsLargeEvent() then return self.LARGE_ZONE_PCT end
    return self.DEFAULT_PCT
end

function LJ:SendQuery(mapID, myLayer, target)
    local faction = MyFactionChar()
    if not faction then
        self:SetState("idle", "LJ_ERR_NO_NETWORK")
        return false
    end
    local reqId = NewRequestId()
    local pct = self.retryPct or self:StartPct(mapID)
    -- Layer inconnu : meme les passeurs de notre layer repondraient. Part reduite.
    if myLayer == nil then pct = math.min(pct, self.LARGE_ZONE_PCT) end
    local want = (type(target) == "number") and tostring(target) or "*"
    local msg = table.concat({ "Q", self.PROTOCOL, reqId, tostring(mapID),
        myLayer and tostring(myLayer) or "-", want, tostring(pct), faction }, ":")
    self.queryPct = pct
    self.reqId = reqId
    self.resultsReq = reqId
    self.resultsMap = mapID
    self.resultsAt = Now()
    self.results = {}
    self.resultCount = 0
    self.answerTotal = 0
    self.answerSeen = {}
    self.querySent = false
    -- Timer et etat poses avant tout envoi / rafraichissement : rien ne peut les sauter.
    C_Timer.After(self.SEARCH_WINDOW, function()
        if LJ.reqId == reqId and LJ.state == "searching" then LJ:FinishSearch() end
    end)
    self:SetState("searching", "LJ_STATUS_SEARCHING", self:ZoneName(mapID))
    if not self:BroadcastQuery(msg, reqId) then
        self.reqId = nil
        self.retryPct = nil
        self:SetState("idle", "LJ_ERR_NO_NETWORK")
        return false
    end
    return true
end

function LJ:FinishSearch()
    local mapID = self.resultsMap
    local total = self.answerTotal or 0
    local pct = self.queryPct or self.DEFAULT_PCT
    if total == 0 and not self.querySent then
        -- Ni guilde ni jeton canal libre : rien n'est parti. Pas de relance, pas
        -- d'attente imposee, aucune lecon tiree pour la zone.
        self.retryPct, self.pendingTarget, self.lastSearchAt = nil, nil, nil
        self:SetState("ready", "LJ_ERR_NO_NETWORK")
        return
    end
    local sync = Overlord.Sync
    local crowded = sync and sync.IsLargeEvent and sync:IsLargeEvent()
    -- Viser TARGET_REPLIES reponses la prochaine fois, d'apres TOUTES les reponses recues.
    -- Zero reponse ne fait jamais monter la part (souvent : tout le monde est sur notre layer).
    if total > 0 then
        local nextPct = math.floor(pct * self.TARGET_REPLIES / total + 0.5)
        nextPct = math.max(self.MIN_PCT, math.min(self.MAX_PCT, nextPct))
        self.pctByMap[mapID] = { pct = nextPct, at = Now() }
    end
    if total == 0 and not self.retryPct and not crowded and self:GetMyLayer(false) ~= nil then
        -- Une seule relance quand personne n'a repondu, jamais au-dela de MAX_PCT,
        -- et jamais dans une foule (les relances s'y synchroniseraient).
        local retryPct = math.min(self.MAX_PCT, pct * 4)
        if retryPct > pct then
            self.retryPct = retryPct
            return self:SendQuery(mapID, self:GetMyLayer(false), self.pendingTarget)
        end
    end
    self.retryPct = nil
    local count = self.resultCount or 0
    if count == 0 then
        self.pendingTarget = nil
        self:SetState("ready", "LJ_STATUS_NONE")
        return
    end
    self:SetState("ready", "LJ_STATUS_READY", count)
    local target = self.pendingTarget
    self.pendingTarget = nil
    if target ~= nil then self:StartHop(target) end
end

-- Les reponses arrivent en rafale : un seul rafraichissement par quart de seconde.
function LJ:ScheduleRefresh()
    if self._refreshPending then return end
    self._refreshPending = true
    C_Timer.After(0.25, function()
        LJ._refreshPending = nil
        LJ:RefreshUI()
    end)
end

function LJ:OnAnswer(sender, reqId, layerText)
    if reqId ~= self.resultsReq or not self:ResultsFresh(self.resultsMap) then return end
    local key = NameKey(sender)
    if not key or key == self:MyKey() then return end
    local layer = tonumber(layerText)
    if not layer or layer <= 0 or layer >= 100000000 then return end
    if not self.results[key] then
        local seen = self.answerSeen
        if seen and not seen[key] then
            seen[key] = true
            self.answerTotal = (self.answerTotal or 0) + 1
        end
        if (self.resultCount or 0) >= self.MAX_RESULTS then return end
        self.resultCount = (self.resultCount or 0) + 1
    end
    self.results[key] = {
        name = sender, key = key, layer = layer,
        at = Now(), roll = math.random(),
    }
    self:RememberLayer(self.resultsMap, layer)
    if self.state == "ready" then
        self.statusText = string.format(T("LJ_STATUS_READY", "%d helper(s) found."), self.resultCount)
    end
    self:ScheduleRefresh()
end

function LJ:BuildCandidates(target, myLayer)
    local list = {}
    for _, r in pairs(self.results) do
        if not r.failed then
            local fits
            if type(target) == "number" then
                fits = r.layer == target
            else
                fits = myLayer == nil or r.layer ~= myLayer
            end
            if fits then list[#list + 1] = r end
        end
    end
    table.sort(list, function(a, b) return a.roll < b.roll end)
    return list
end

function LJ:StartHop(target)
    if self:IsActive() then return false end
    local blocked = self:CheckRequesterBlocked(true)
    if blocked then
        self.statusText = blocked
        self:RefreshUI()
        Print(blocked)
        return false
    end
    local myLayer, mapID = self:GetMyLayer(true)
    if target == "any" and myLayer == nil then
        self.statusText = T("LJ_ERR_LAYER_UNKNOWN", "Target an NPC first to read your layer.")
        self:RefreshUI()
        return false
    end
    if not self:ResultsFresh(mapID) then return self:Search(target) end
    local candidates = self:BuildCandidates(target, myLayer)
    if #candidates == 0 then
        self:SetState("ready", "LJ_STATUS_NONE")
        return false
    end
    self:MarkHopEpoch()
    self.hop = {
        target = target, originLayer = myLayer, originMap = mapID,
        candidates = candidates, index = 0, reqId = self.resultsReq,
    }
    return self:NextCandidate()
end

-- Une invitation acceptee trop tard (ou a la main) d'un passeur abandonne :
-- on ressort du groupe des qu'on y entre.
function LJ:ArmLateJoinLeave(cand)
    if not cand or not cand.key then return end
    -- Candidat abandonne : plus de raison de s'en mefier au-dela de la courte grace.
    if self.partners[cand.key] then self:MarkPartner(cand.key, self.HOP_GROUP_GRACE + 5) end
    self.lateLeave = self.lateLeave or {}
    self.lateLeave[cand.key] = { untilAt = Now() + 15, name = cand.name }
end

function LJ:NextCandidate()
    local hop = self.hop
    if not hop then return false end
    -- Le passeur precedent est abandonne : rien a retenir pour un /reload.
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    hop.index = hop.index + 1
    local cand = hop.candidates[hop.index]
    if not cand or hop.index > self.MAX_ATTEMPTS then
        self.hop = nil
        if hop.acceptedAt and hop.current then self:ArmLateJoinLeave(hop.current) end
        self:SetState("ready", "LJ_STATUS_FAILED")
        Print(self.statusText)
        return false
    end
    hop.current = cand
    hop.acceptedAt = nil
    local wait = self.INVITE_WAIT
    local index = hop.index
    C_Timer.After(wait, function()
        if LJ.hop == hop and hop.index == index and LJ.state == "requesting" then
            cand.failed = true
            LJ:ArmLateJoinLeave(cand)
            LJ:NextCandidate()
        end
    end)
    self:SetState("requesting", "LJ_STATUS_REQUESTING", cand.name)
    self:Whisper(cand.name, "R:" .. hop.reqId)
    return true
end

function LJ:OnDecline(sender, reqId)
    local hop = self.hop
    if not hop or hop.reqId ~= reqId or self.state ~= "requesting" then return end
    if not hop.current or NameKey(sender) ~= hop.current.key then return end
    hop.current.failed = true
    self:NextCandidate()
end

local function AcceptHopInvite()
    -- Fermer la fenetre sans accepter refuserait l'invitation.
    if not AcceptGroup then return end
    AcceptGroup()
    local dialog = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
    if dialog then dialog.inviteAccepted = 1 end
    if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
end

-- Seule l'invitation du passeur sollicite est acceptee automatiquement.
function LJ:OnPartyInvite(inviter)
    local hop = self.hop
    if not hop or self.state ~= "requesting" or not hop.current then return false end
    if type(inviter) ~= "string" or not SameName(inviter, hop.current.name) then return false end
    pcall(AcceptHopInvite)
    hop.acceptedAt = Now()
    local cand = hop.current
    self:MarkHopEpoch()
    self:RememberHop(cand.key)
    self:MarkPartner(cand.key, self.JOIN_WAIT + 120 + self.HOP_GROUP_GRACE)
    C_Timer.After(self.JOIN_WAIT, function()
        if LJ.hop == hop and hop.current == cand and LJ.state == "joining" then
            if LJ:IsGrouped() then return LJ:OnGroupJoined() end
            cand.failed = true
            LJ:ArmLateJoinLeave(cand)
            LJ:NextCandidate()
        end
    end)
    self:SetState("joining", "LJ_STATUS_JOINING", hop.current.name)
    return true
end

function LJ:OnGroupJoined()
    local hop = self.hop
    if not hop or self.state ~= "joining" or not hop.current then return end
    local pair = self:HopPairStatus(hop.current.key)
    if pair == "none" then return end
    if pair == "foreign" then
        -- Un autre groupe, accepte a la main : on le garde et on abandonne le saut.
        self.hop = nil
        if OverlordDB then OverlordDB.layerJumperHop = nil end
        self:ArmLateJoinLeave(hop.current)
        self:SetState("idle", "LJ_STATUS_CANCELLED")
        return
    end
    if pair == "crowded" or pair == "hijacked" then
        -- Le passeur a fait entrer d'autres joueurs (ou s'est fait remplacer) : on ne reste pas.
        self.state = "verifying"
        return self:FinishHop(false, "LJ_STATUS_CROWDED")
    end
    if pair == "pair" then self.hopPairSeen = true end
    hop.joinedAt = Now()
    hop.verifyLeft = self.VERIFY_TIMEOUT
    hop.hardDeadline = hop.joinedAt + 120
    self.layerDirtyAt = hop.joinedAt
    self.state = "verifying"
    self.phaseDeadline = nil
    self:UpdateTicker()
    self:UpdateVerifyStatus()
    self:CheckVerify()
end

function LJ:UpdateVerifyStatus()
    local hop = self.hop
    if not hop then return end
    local left = math.max(0, math.ceil(hop.verifyLeft or 0))
    if self:InCombat() then
        self.statusText = string.format(T("LJ_STATUS_VERIFY_COMBAT", "In combat: the switch waits (%ds)."), left)
    else
        self.statusText = string.format(T("LJ_STATUS_VERIFYING", "Switching layer... (%ds)"), left)
    end
    self:RefreshUI()
end

-- Preuve : un PNJ lu apres l'entree dans le groupe porte le layer du passeur (ou
-- celui demande). « Different de l'origine » seulement en dernier recours : un PNJ
-- de la zone voisine ne doit pas faire croire au changement.
function LJ:CheckVerify()
    local hop = self.hop
    if not hop or self.state ~= "verifying" then return false end
    local m = self.mine
    if not m.at or m.at <= (hop.joinedAt or 0) or m.mapID ~= hop.originMap then return false end
    local done
    if type(hop.target) == "number" then
        done = m.layer == hop.target
    elseif hop.current and hop.current.layer ~= nil then
        done = m.layer == hop.current.layer
    elseif hop.originLayer ~= nil then
        done = m.layer ~= hop.originLayer
    end
    if not done then return false end
    self:FinishHop(true)
    return true
end

-- Ne quitte jamais un groupe qui n'est pas celui du saut (key = partenaire attendu).
function LJ:LeaveHopGroup(key)
    -- Jamais en instance : le groupe y est celui du donjon ou du champ de bataille.
    if Overlord.InstanceSuspended or self:InInstance() then return end
    if not self:IsGrouped() then return end
    if key and self:HopPairStatus(key) == "foreign" then return end
    self:MarkHopGroupEnding(key)
    if C_PartyInfo and C_PartyInfo.LeaveParty then
        pcall(C_PartyInfo.LeaveParty)
    elseif LeaveParty then
        pcall(LeaveParty)
    end
end

function LJ:FinishHop(confirmed, failKey)
    local hop = self.hop
    self.hop = nil
    if not hop then return end
    local partnerKey = hop.current and hop.current.key
    self:MarkHopGroupEnding(partnerKey)
    if partnerKey then self:MarkPartner(partnerKey, self.HOP_GROUP_GRACE + 5) end
    -- La liste ne reflete plus notre position : la prochaine recherche repart de zero.
    self.resultsReq = nil
    if confirmed then
        local m = self.mine
        self:SetState("idle", "LJ_STATUS_SUCCESS", self:FormatLayer(m.mapID, m.layer))
    else
        self:SetState("idle", failKey or "LJ_STATUS_UNCONFIRMED")
    end
    Print(self.statusText)
    -- Une seconde de marge : le serveur termine le transfert avant le depart du groupe.
    C_Timer.After(1, function() LJ:LeaveHopGroup(partnerKey) end)
end

function LJ:Cancel()
    local hop = self.hop
    if hop and hop.current and self.state == "requesting" then
        hop.current.failed = true
        self:ArmLateJoinLeave(hop.current)
    end
    local wasInHopGroup = hop and (self.state == "joining" or self.state == "verifying")
    if hop and hop.acceptedAt and hop.current then self:ArmLateJoinLeave(hop.current) end
    self.hop = nil
    self.pendingTarget = nil
    self.retryPct = nil
    if self.state == "searching" then self.reqId = nil end
    if wasInHopGroup then self:MarkHopGroupEnding(hop.current and hop.current.key) end
    if hop and hop.acceptedAt and hop.current then
        self:MarkPartner(hop.current.key, self.HOP_GROUP_GRACE + 5)
    end
    self:SetState("idle", "LJ_STATUS_CANCELLED")
    if wasInHopGroup then self:LeaveHopGroup(hop.current and hop.current.key) end
end

-- Battement 1 s seulement pendant une operation (compte a rebours + verification).
function LJ:Tick()
    if self.phaseDeadline and Now() > self.phaseDeadline then
        self:Cancel()
        return
    end
    if self.state == "verifying" then
        local hop = self.hop
        if not hop then return self:SetState("idle") end
        local id = self:ScanLayer()
        if id then self:Observe(id) end
        if self.state ~= "verifying" then return end
        if not self:InCombat() then hop.verifyLeft = (hop.verifyLeft or 0) - 1 end
        if hop.verifyLeft <= 0 or Now() > (hop.hardDeadline or math.huge) then
            self:FinishHop(false)
            return
        end
        self:UpdateVerifyStatus()
    elseif self:IsActive() then
        self:RefreshUI()
    end
end

function LJ:UpdateTicker()
    local active = self:IsActive()
    if active and not self.ticker and C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(1, function() LJ:Tick() end)
    elseif not active and self.ticker then
        if self.ticker.Cancel then self.ticker:Cancel() end
        self.ticker = nil
    end
end

-- ============================================================
-- Cote passeur
-- ============================================================

local function PruneByAge(map, field, ttl, cap)
    local now, count, oldestId, oldestAt = Now(), 0, nil, nil
    for id, rec in pairs(map) do
        local at = field and rec[field] or rec
        if now - at > ttl then
            map[id] = nil
        else
            count = count + 1
            if not oldestAt or at < oldestAt then oldestId, oldestAt = id, at end
        end
    end
    if count > cap and oldestId then map[oldestId] = nil end
end

-- Pourquoi ce client ne peut pas servir de passeur maintenant (nil = disponible).
function LJ:HelperUnavailableReason()
    if self:InInstance() then return "instance" end
    if self:InCombat() then return "combat" end
    if self:InBattlegroundQueue() then return "queue" end
    if not self:CanHostGuest() then return "full" end
    if self.hop then return "busy" end
    -- Une invitation deja en cours : un seul invite a la fois.
    local now = Now()
    for _, guest in pairs(self.guests) do
        if not guest.joined and now - guest.at < self.GUEST_INVITE_TTL then return "busy" end
    end
    return nil
end

-- Ordre des filtres : du moins cher au plus cher. La lecture des plaques de nom
-- (GetMyLayer(true)) n'a lieu que pour une recherche de NOTRE zone a laquelle
-- ce client repondrait vraiment.
function LJ:OnQuery(sender, proto, reqId, mapText, theirLayerText, wantText, pctText, faction)
    if proto ~= self.PROTOCOL or type(reqId) ~= "string" or #reqId > 12 then return end
    if faction ~= MyFactionChar() or self:GetHelpMode() ~= "auto" then return end
    if self.answered[reqId] then return end
    local now = Now()
    if now - (self.lastReplyAt or -100) < self.HELPER_REPLY_GAP then return end
    -- La part vient du demandeur : jamais au-dela de MAX_PCT, 0 si absente.
    local pct = math.max(0, math.min(self.MAX_PCT, tonumber(pctText) or 0))
    if Hash100(reqId .. ":" .. (self:MyKey() or "")) >= pct then return end
    local senderKey = NameKey(sender)
    if not senderKey or senderKey == self:MyKey() then return end
    if now - (self.repliedTo[senderKey] or -100) < self.HELPER_PER_SENDER_GAP then return end
    if now - (self.invitedAt[senderKey] or -1e9) < self.HELPER_SAME_REQUESTER_GAP then return end
    local mapID = self:CurrentZone()
    if not mapID or mapID ~= tonumber(mapText) then return end
    if self:HelperUnavailableReason() then return end
    -- Un passeur qui ne connait pas son layer ne repond pas : reponse inutile et
    -- verification impossible. Lecture recente d'abord, plaques de nom ensuite
    -- (et pas plus d'une lecture ratee toutes les 2 s).
    local m, myLayer = self.mine, nil
    if m.layer ~= nil and m.mapID == mapID and m.at and now - m.at < 30
        and m.at >= (self.layerDirtyAt or 0) then
        myLayer = m.layer
    elseif now - (self._scanFailAt or -100) >= 2 then
        myLayer = self:GetMyLayer(true)
        if myLayer == nil then self._scanFailAt = now end
    end
    if myLayer == nil then return end
    local theirLayer, want = tonumber(theirLayerText), tonumber(wantText)
    if theirLayer ~= nil and myLayer == theirLayer then return end
    if want ~= nil and myLayer ~= want then return end
    self.lastReplyAt = now
    self.repliedTo[senderKey] = now
    PruneByAge(self.repliedTo, nil, self.HELPER_PER_SENDER_GAP, 32)
    self.answered[reqId] = { key = senderKey, name = sender, at = now, layer = myLayer }
    PruneByAge(self.answered, "at", 180, 32)
    local msg = "A:" .. reqId .. ":" .. tostring(myLayer)
    -- Petit etalement : les reponses d'une zone peuplee n'arrivent pas dans la meme frame.
    C_Timer.After(0.2 + math.random() * 1.3, function() LJ:Whisper(sender, msg) end)
end

function LJ:InviteBudgetOk()
    local now, recent = Now(), 0
    local log = self.inviteLog
    for i = #log, 1, -1 do
        if now - log[i] > 3600 then table.remove(log, i) else recent = recent + 1 end
    end
    if recent >= self.HELPER_INVITES_PER_HOUR then return false end
    return now - (log[#log] or -1000) >= self.HELPER_INVITE_GAP
end

function LJ:OnRequest(sender, reqId)
    local rec = self.answered[reqId]
    if not rec or rec.key ~= NameKey(sender) or Now() - rec.at > 120 or rec.handled then return end
    rec.handled = true
    local reason = self:GetHelpMode() ~= "auto" and "off" or self:HelperUnavailableReason()
    if not reason and not self:InviteBudgetOk() then reason = "busy" end
    if not reason and Now() - (self.invitedAt[rec.key] or -1e9) < self.HELPER_SAME_REQUESTER_GAP then
        reason = "busy"
    end
    -- Le layer annonce doit encore etre le notre : sinon la preuve echouerait a tort.
    if not reason and rec.layer ~= nil and self:GetMyLayer(true) ~= rec.layer then reason = "moved" end
    if reason then
        self:Whisper(sender, "N:" .. reqId .. ":" .. reason)
        return
    end
    self:InviteGuest(sender, reqId)
end

function LJ:InviteGuest(name, reqId)
    if self:HelperUnavailableReason() then
        self:Whisper(name, "N:" .. reqId .. ":busy")
        return false
    end
    local key = NameKey(name)
    self.inviteLog[#self.inviteLog + 1] = Now()
    PruneByAge(self.invitedAt, nil, self.HELPER_SAME_REQUESTER_GAP, 64)
    self.invitedAt[key] = Now()
    -- Enregistre AVANT l'invitation : le groupe a deux qui va se former est « a nous ».
    self.guests[key] = { name = name, at = Now() }
    self:MarkHopEpoch()
    self:RememberHop(key)
    self:MarkPartner(key, self.GUEST_KICK_AFTER + self.HOP_GROUP_GRACE)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        securecall(C_PartyInfo.InviteUnit, name)
    elseif InviteUnit then
        securecall(InviteUnit, name)
    end
    local invitedAt = self.guests[key].at
    C_Timer.After(self.GUEST_KICK_AFTER, function() LJ:ReleaseGuest(key, invitedAt) end)
    return true
end

local function MemberKey(unit) return NameKey((UnitName(unit))) end

GroupHasMember = function(key)
    local n = LJ:GroupSize()
    local prefix = SafeBool(IsInRaid) and "raid" or "party"
    local last = prefix == "raid" and n or math.max(0, n - 1)
    for i = 1, last do
        local ok, memberKey = pcall(MemberKey, prefix .. i)
        if ok and memberKey == key then return true end
    end
    return false
end

-- Filet : le client de l'invite quitte seul ; si ce n'est pas arrive au bout de 2 min
-- dans le groupe a deux cree pour lui, on le libere.
function LJ:ReleaseGuest(key, invitedAt)
    local guest = self.guests[key]
    if not guest or (invitedAt and guest.at ~= invitedAt) then return end
    if Overlord.InstanceSuspended or self:InInstance() then return end
    self.guests[key] = nil
    self:MarkHopGroupEnding(key)
    self:MarkPartner(key, self.HOP_GROUP_GRACE)
    -- Rien a faire pour une invitation jamais acceptee : ce joueur n'est pas notre invite.
    -- Invitation jamais acceptee : ce joueur pourra redemander (le WoW l'a expiree).
    if not guest.joined then
        self.invitedAt[key] = nil
        return
    end
    local st = self:HopPairStatus(key)
    if st == "crowded" or st == "hijacked" then return self:LeaveHopGroup(key) end
    if self:GroupSize() ~= 2 or not SafeBool(UnitIsGroupLeader, "player") or not GroupHasMember(key) then
        return
    end
    if C_PartyInfo and C_PartyInfo.UninviteUnit then
        securecall(C_PartyInfo.UninviteUnit, guest.name)
    elseif UninviteUnit then
        securecall(UninviteUnit, guest.name)
    end
    Print(string.format(T("LJ_GUEST_REMOVED", "%s removed from the group."), guest.name))
end

-- Entree dans un groupe hors saut en cours : si c'est celui d'un passeur abandonne
-- (invitation arrivee trop tard), on en ressort.
-- Rend true quand le groupe d'un passeur abandonne vient d'etre quitte.
function LJ:CheckLateJoin()
    local late = self.lateLeave
    if not late or self.state == "joining" then return false end
    local now = Now()
    for key, entry in pairs(late) do
        if now > entry.untilAt then late[key] = nil end
    end
    if next(late) == nil then
        self.lateLeave = nil
        return false
    end
    -- Un passeur ne recoit que seul : un groupe de plus de cinq n'est pas le sien.
    if not self:IsGrouped() or self:GroupSize() > 5 then return false end
    for key, entry in pairs(late) do
        if GroupHasMember(key) then
            late[key] = nil
            self:LeaveHopGroup(key)
            Print(string.format(T("LJ_LATE_LEAVE", "Left %s's group: that layer jump was cancelled."),
                (entry.name or key):match("^([^%-]+)") or key))
            return true
        end
    end
    return false
end

-- ============================================================
-- Reception
-- ============================================================

function LJ:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX or type(text) ~= "string" or #text > 200 then return end
    if type(sender) ~= "string" or Overlord.InstanceSuspended then return end
    local kind = text:sub(1, 1)
    if kind == "Q" then
        if channel ~= "GUILD" and channel ~= "CHANNEL" then return end
        local _, proto, reqId, mapText, theirLayer, want, pct, faction = strsplit(":", text)
        return self:OnQuery(sender, proto, reqId, mapText, theirLayer, want, pct, faction)
    end
    if channel ~= "WHISPER" then return end
    local _, a, b, c, d = strsplit(":", text)
    if kind == "A" then
        self:OnAnswer(sender, a, b, c, d)
    elseif kind == "R" then
        self:OnRequest(sender, a)
    elseif kind == "N" then
        self:OnDecline(sender, a)
    end
end

-- Instance (donjon, raid, champ de bataille) : comme le reste d'Overlord, le Layer
-- Jumper se coupe. Le saut en cours est abandonne SANS toucher au groupe (un groupe
-- de donjon ou de champ de bataille n'est jamais quitte ni lu), et plus aucun
-- evenement n'est traite jusqu'a la sortie. Appele par Overlord:SuspendForInstance.
function LJ:OnInstanceSuspend()
    -- Fenetre fermee d'abord : aucun rafraichissement ne relit la carte en instance.
    if self.frame and self.frame:IsShown() then self.frame:Hide() end
    -- Le layer lu avant l'instance ne vaut plus rien a la sortie.
    self.layerDirtyAt = Now()
    self.hop, self.pendingTarget, self.retryPct, self.reqId = nil, nil, nil, nil
    self.resultsReq, self.lateLeave = nil, nil
    for key in pairs(self.guests) do self.guests[key] = nil end
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    if self.state ~= "idle" then
        self:SetState("idle", "LJ_STATUS_CANCELLED")
    else
        self:UpdateTicker()
    end
end

function LJ:OnEvent(event, ...)
    -- Rien en instance (ni messages, ni groupe, ni plaques) : voir OnInstanceSuspend.
    -- Le drapeau d'Overlord n'est pose qu'a son PLAYER_ENTERING_WORLD : pendant le
    -- chargement, seul IsInInstance dit deja vrai (meme double garde que la synchro).
    if self:InInstance() then return end
    if event == "CHAT_MSG_ADDON" then
        -- Comme la synchro : en instance, aucun argument d'evenement n'est lu.
        if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
        if (...) ~= self.PREFIX then return end
        self:OnAddonMessage(...)
    elseif event == "PARTY_INVITE_REQUEST" then
        if not self:OnPartyInvite((...)) then self.otherInviteAt = Now() end
    elseif event == "GROUP_JOINED" or event == "GROUP_ROSTER_UPDATE" then
        if self.state == "joining" then
            if event == "GROUP_JOINED" then self.layerDirtyAt = Now() end
            self:OnGroupJoined()
            return
        end
        local verifyStatus = self.state == "verifying" and self.hop and self.hop.current
            and self:HopPairStatus(self.hop.current.key)
        if verifyStatus == "pair" then self.hopPairSeen = true end
        if verifyStatus == "crowded" or verifyStatus == "hijacked" then
            -- Un tiers est entre dans le groupe du saut : on en sort.
            return self:FinishHop(false, "LJ_STATUS_CROWDED")
        end
        if self.state == "requesting" and self:IsGrouped() and self.hop and self.hop.current then
            -- Groupe d'un passeur abandonne (invitation tardive) : on en sort et la demande
            -- en cours continue.
            if self.lateLeave and self:CheckLateJoin() then return end
            -- Un autre groupe rejoint pendant la demande : le passeur ne pourra plus inviter.
            local st = self:HopPairStatus(self.hop.current.key)
            if st == "foreign" or st == "crowded" or st == "hijacked" then return self:Cancel() end
        end
        if next(self.guests) ~= nil and self:IsGrouped() and self:GroupSize() <= 2 then
            local now = Now()
            for key, guest in pairs(self.guests) do
                if not guest.joined and now - guest.at < self.GUEST_INVITE_TTL and GroupHasMember(key) then
                    guest.joined = true
                    self.hopPairSeen = true
                end
            end
        end
        if next(self.guests) ~= nil and self:IsGrouped() then
            -- Passeur : l'invite a fait entrer d'autres joueurs, ou a ete remplace apres
            -- etre entre (aucune autre invitation recue). On quitte ce groupe.
            for key, guest in pairs(self.guests) do
                local st = self:HopPairStatus(key)
                if guest.joined and (st == "crowded" or st == "hijacked") then
                    for k in pairs(self.guests) do self.guests[k] = nil end
                    self:MarkPartner(key, self.HOP_GROUP_GRACE)
                    return self:LeaveHopGroup(key)
                end
            end
        end
        -- Rejoindre un vrai groupe peut changer de layer : la lecture n'est plus sure.
        if event == "GROUP_JOINED" and not self:IsHopGroup() then self.layerDirtyAt = Now() end
        if self.lateLeave then self:CheckLateJoin() end
    elseif event == "GROUP_LEFT" then
        self.hopPairSeen = false
        if next(self.guests) ~= nil then
            for key in pairs(self.guests) do
                self:MarkHopGroupEnding(key)
                self:MarkPartner(key, self.HOP_GROUP_GRACE)
                self.guests[key] = nil
            end
        end
        if self.state == "joining" and self.hop and self.hop.current then
            -- Groupe perdu avant d'y etre vraiment : passeur suivant (et pas de retour
            -- tardif dans le groupe de celui-ci).
            self.hop.current.failed = true
            self:ArmLateJoinLeave(self.hop.current)
            self:NextCandidate()
        elseif self.state == "verifying" then
            -- Retire du groupe (filet du passeur, deconnexion) avant la preuve.
            self:FinishHop(false)
        elseif Now() >= (self.hopGroupUntil or 0) then
            -- Un depart de groupe ordinaire peut changer de layer ; celui du saut non.
            self.layerDirtyAt = Now()
        end
        self:RefreshUI()
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        self.layerDirtyAt = Now()
        self._zoneAt = nil
        if self.state == "verifying" then
            -- Un ecran de chargement du transfert ne termine rien ; quitter la zone du
            -- saut, si : aucune preuve possible ailleurs.
            local zone = event == "ZONE_CHANGED_NEW_AREA" and self.hop and self:CurrentZone()
            if zone and zone ~= self.hop.originMap then self:FinishHop(false) end
        elseif self.state == "ready" or self.state == "searching" then
            self.resultsReq = nil
            if self.state == "searching" then self.reqId = nil end
            self:SetState("idle", "LJ_STATUS_IDLE")
        else
            self:RefreshUI()
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        self:ObserveUnit("target", true)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        self:ObserveUnit("mouseover", false)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        self:ObserveUnit((...), false)
    end
end

function LJ:Initialize()
    if self.initialized then return end
    self.initialized = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    end
    self.statusText = T("LJ_STATUS_IDLE", "")
    self:RestoreHopAfterReload()
    local f = CreateFrame("Frame")
    self.eventFrame = f
    for _, event in ipairs({ "CHAT_MSG_ADDON", "PARTY_INVITE_REQUEST", "GROUP_JOINED",
        "GROUP_ROSTER_UPDATE", "GROUP_LEFT", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED" }) do
        pcall(f.RegisterEvent, f, event)
    end
    f:SetScript("OnEvent", function(_, event, ...) LJ:OnEvent(event, ...) end)
end

-- ============================================================
-- Interface : fenetre Layer Jumper
-- ============================================================

local GOLD = { 1, 0.82, 0 }

-- Portail de mage de la capitale du joueur (icones presentes depuis le jeu d'origine).
function LJ:PortalIcon()
    if MyFactionChar() == "H" then return "Interface\\Icons\\Spell_Arcane_PortalOrgrimmar" end
    return "Interface\\Icons\\Spell_Arcane_PortalStormwind"
end
local ROW_COUNT = 6
local FRAME_W, FRAME_H = 360, 330

local function SetButtonEnabled(btn, enabled)
    if not btn then return end
    if enabled then btn:Enable() else btn:Disable() end
    btn:SetAlpha(enabled and 1 or 0.45)
end

local function MakeButton(parent, w, h, text, onClick, icon)
    local UI = Overlord.UI
    if UI and UI.CreateWC3Button then
        return UI.CreateWC3Button(parent, w, h, text, onClick, icon)
    end
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w, h)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function SetButtonText(btn, text)
    if btn.label then btn.label:SetText(text) elseif btn.SetText then btn:SetText(text) end
end

function LJ:CreateWindow()
    if self.frame then return self.frame end
    local UI = Overlord.UI or {}
    local f = CreateFrame("Frame", "OverlordLayerJumperFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    if UI.ApplyWoodDialogBackdrop then UI.ApplyWoodDialogBackdrop(f) end
    if UI.AttachOpenFade then UI.AttachOpenFade(f) end
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetScript("OnHide", function()
        LJ._lastGridShown = false
        if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh then
            Overlord.UI:ScheduleActionGridActiveRefresh()
        end
    end)
    f:Hide()
    tinsert(UISpecialFrames, "OverlordLayerJumperFrame")

    local close = UI.CreateWC3CloseButton and UI.CreateWC3CloseButton(f, function() LJ:Hide() end)
        or CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
    icon:SetTexture(LJ:PortalIcon())
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(T("LJ_TITLE", "Layer Jumper"))
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    local zoneText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneText:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -52)
    zoneText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -52)
    zoneText:SetJustifyH("LEFT")
    zoneText:SetWordWrap(false)
    zoneText:SetHeight(16)
    f.zoneText = zoneText

    local list = UI.CreateWC3SubPanel and UI.CreateWC3SubPanel(f, FRAME_W - 36, ROW_COUNT * 24 + 12)
        or CreateFrame("Frame", nil, f)
    list:SetSize(FRAME_W - 36, ROW_COUNT * 24 + 12)
    list:SetPoint("TOP", f, "TOP", 0, -74)
    f.rows = {}
    for i = 1, ROW_COUNT do
        local row = CreateFrame("Frame", nil, list)
        row:SetSize(FRAME_W - 52, 22)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6 - (i - 1) * 24)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", row, "LEFT", 2, 0)
        label:SetJustifyH("LEFT")
        local info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        info:SetPoint("LEFT", row, "LEFT", 110, 0)
        info:SetJustifyH("LEFT")
        local join = MakeButton(row, 86, 20, T("LJ_JOIN", "Join"), function(btn)
            if btn._layer then LJ:StartHop(btn._layer) end
        end)
        join:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.label, row.info, row.join = label, info, join
        row:Hide()
        f.rows[i] = row
    end
    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -10)
    empty:SetPoint("TOPRIGHT", list, "TOPRIGHT", -10, -10)
    empty:SetJustifyH("LEFT")
    empty:SetText(T("LJ_LIST_EMPTY", "Click Search to list the layers of this zone."))
    f.emptyText = empty

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 2, -8)
    status:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", -2, -8)
    status:SetJustifyH("LEFT")
    status:SetHeight(36)
    status:SetJustifyV("TOP")
    f.statusLine = status

    local btnW = math.floor((FRAME_W - 36 - 12) / 3)
    local search = MakeButton(f, btnW, 24, T("LJ_SEARCH", "Search"), function() LJ:Search(nil) end)
    search:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -46)
    local random = MakeButton(f, btnW, 24, T("LJ_RANDOM", "Change layer"), function() LJ:Search("any") end)
    random:SetPoint("LEFT", search, "RIGHT", 6, 0)
    local cancel = MakeButton(f, btnW, 24, T("LJ_CANCEL", "Cancel"), function() LJ:Cancel() end)
    cancel:SetPoint("LEFT", random, "RIGHT", 6, 0)
    f.searchBtn, f.randomBtn, f.cancelBtn = search, random, cancel
    random:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(T("LJ_RANDOM_TOOLTIP", ""), 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    random:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local help = MakeButton(f, FRAME_W - 36, 22, "", function()
        LJ:SetHelpMode(LJ:GetHelpMode() == "auto" and "off" or "auto")
    end)
    help:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -8)
    help:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(T("LJ_HELP_MODE_TOOLTIP", ""), 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    help:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.helpBtn = help

    local explain = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    explain:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 2, -8)
    explain:SetWidth(FRAME_W - 40)
    explain:SetJustifyH("LEFT")
    explain:SetText(T("LJ_EXPLAIN", ""))
    f.explain = explain

    self.frame = f
    self:FitWindowHeight()
    return f
end

-- Le texte d'aide fait 2 a 4 lignes selon la langue : le cadre suit sa hauteur
-- (haut du texte a 338 px du bord, puis la meme marge que sur les cotes).
function LJ:FitWindowHeight()
    local f = self.frame
    if not f or not f.explain then return end
    local textH = tonumber(f.explain:GetStringHeight()) or 0
    if textH <= 0 then textH = 40 end
    f:SetHeight(math.max(FRAME_H, math.ceil(338 + textH + 22)))
end

-- Lignes : layers connus de la zone (le notre inclus) + passeurs trouves par layer.
function LJ:BuildRows(mapID, myLayer)
    local byLayer = {}
    if self:ResultsFresh(mapID) then
        for _, r in pairs(self.results) do
            if not r.failed then byLayer[r.layer] = (byLayer[r.layer] or 0) + 1 end
        end
    end
    local ids, present = {}, {}
    local seen = mapID and self.seenLayers[mapID] or {}
    for id, at in pairs(seen) do
        if Now() - at <= self.SEEN_TTL and not present[id] then
            present[id] = true
            ids[#ids + 1] = id
        end
    end
    for id in pairs(byLayer) do
        if not present[id] then present[id] = true; ids[#ids + 1] = id end
    end
    local rows = {}
    for _, id in ipairs(ids) do
        rows[#rows + 1] = { layer = id, here = id == myLayer, helpers = byLayer[id] or 0 }
    end
    -- Six lignes au plus : notre layer, puis ceux qui ont des passeurs, puis le reste.
    table.sort(rows, function(a, b)
        if a.here ~= b.here then return a.here end
        if a.helpers ~= b.helpers then return a.helpers > b.helpers end
        return a.layer < b.layer
    end)
    return rows
end

-- Un affichage ne doit jamais interrompre la logique (etat, minuteries) qui l'appelle.
function LJ:RefreshUI()
    if Overlord.UI and Overlord.UI.ScheduleActionGridActiveRefresh and self._lastGridShown ~= self:IsShown() then
        self._lastGridShown = self:IsShown()
        Overlord.UI:ScheduleActionGridActiveRefresh()
    end
    local f = self.frame
    if not f or not f:IsShown() then return end
    local ok, err = pcall(self.PaintWindow, self, f)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

function LJ:PaintWindow(f)
    local myLayer, mapID = self:GetMyLayer(false)
    f.zoneText:SetText(string.format(T("LJ_ZONE_LAYER", "%s - your layer: %s"),
        self:ZoneName(mapID), self:FormatLayer(mapID, myLayer)))
    local rows = self:BuildRows(mapID, myLayer)
    local active = self:IsActive()
    for i = 1, ROW_COUNT do
        local row, data = f.rows[i], rows[i]
        if data then
            row.label:SetText(self:FormatLayer(mapID, data.layer))
            row.join._layer = data.layer
            row.join:SetShown(not data.here)
            SetButtonEnabled(row.join, not active and data.helpers > 0)
            if data.here then
                row.info:SetText(T("LJ_HERE", "you are here"))
                row.label:SetTextColor(0.4, 1, 0.4)
            else
                row.info:SetText(string.format(T("LJ_HELPERS", "%d helper(s)"), data.helpers))
                row.label:SetTextColor(1, 1, 1)
            end
            row:Show()
        else
            row:Hide()
        end
    end
    f.emptyText:SetShown(#rows == 0)
    f.statusLine:SetText(self.statusText or "")
    SetButtonEnabled(f.searchBtn, not active)
    SetButtonEnabled(f.randomBtn, not active)
    SetButtonEnabled(f.cancelBtn, active)
    SetButtonText(f.helpBtn, string.format(T("LJ_HELP_MODE", "Help others: %s"), self:HelpModeLabel()))
end

function LJ:Show()
    self:Initialize()
    local f = self:CreateWindow()
    if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
        f:SetScale(Overlord.UI:GetEffectiveUiScale())
    end
    if not self:IsActive() and self.state ~= "ready" then
        self.statusText = T("LJ_STATUS_IDLE", "")
    end
    f:Show()
    self:FitWindowHeight()
    self:GetMyLayer(true)
    if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
    self:RefreshUI()
end

function LJ:Hide()
    if self.frame and self.frame:IsShown() then
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        self.frame:Hide()
    end
    self:RefreshUI()
end

function LJ:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
end

function LJ:IsShown()
    return self.frame ~= nil and self.frame:IsShown() == true
end

-- Commandes : /ov layer [help on|off], /ov hop
function LJ:HandleCommand(args)
    local sub = args and args[2] and args[2]:lower() or nil
    if sub == "help" or sub == "aide" then
        local arg = args[3] and args[3]:lower()
        local mode = (arg == "on" or arg == "auto") and "auto" or (arg == "off" and "off") or nil
        if mode then
            self:SetHelpMode(mode)
        elseif arg then
            Print(T("HELP_LAYER", "/ov layer [help on|off]"))
        end
        Print(string.format(T("LJ_HELP_MODE", "Help others: %s"), self:HelpModeLabel()))
        return
    end
    self:Toggle()
end

if CreateFrame then
    local boot = CreateFrame("Frame")
    boot:RegisterEvent("PLAYER_LOGIN")
    boot:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        LJ:Initialize()
    end)
end
