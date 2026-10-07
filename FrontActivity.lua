-- FrontActivity.lua : activite recente connue par front.
--
-- Le panneau ne cherche pas a reconstruire un nombre global de joueurs. Il conserve
-- le dernier evenement valide observe sur chaque front et le propage dans les reponses
-- SR via un payload compact FA. La taille des combats (kills sur 5 min) est partagee par
-- paliers (message FK, voir plus bas) pour que tous les joueurs voient le meme panneau.
-- Relais actif (1.7.0) : une ligne n'est allumee que par ces paliers partages et par les
-- captures lues sur la carte commune (GetRecentCaptureCount), jamais par un evenement
-- que ce client serait seul a avoir recu.
-- Les compteurs d'acteurs restent internes afin de ne pas casser l'annonce de faction
-- historique, mais ils ne pilotent plus le panneau.
--
-- Donnees :
--   OverlordDB.frontActivity[frontId] = epoch serveur de la derniere activite connue
--   OverlordDB.frontActivityActors[frontId][Nom-Royaume] = epoch serveur derniere action

Overlord = Overlord or {}
Overlord.FrontActivity = Overlord.FrontActivity or {}
local FA = Overlord.FrontActivity
local L = Overlord.L

local ACTIVITY_WINDOW = 300
local ACTIVITY_SCHEMA = 5
local ACTIVITY_ACTOR_MAX = 64
-- Aligne sur Sync.MAX_CLOCK_SKEW pour ne pas refuser un evenement deja accepte par le coeur.
local MAX_FUTURE_SKEW = 300
local MAX_SYNC_PAYLOAD_BYTES = 240
local MAX_SYNC_ENTRIES = 16
local SYNC_BROADCAST_RESPONSE_TTL = 8
-- Les SR directes peuvent rester jusqu'a 90 s dans la file anti-amplification distante.
local SYNC_TARGET_RESPONSE_TTL = 100
local ACTIVITY_WRITE_PURGE_INTERVAL = 30

local activityRevision = 0
local activityChangeListeners = {}
local zoneToFront = nil
local expectedAnySyncResponseUntil = 0
local expectedSyncSenders = {}
local expectedSenderNodes = {}
local expectedSenderHead, expectedSenderTail, expectedSenderCount = nil, nil, 0
local EXPECTED_SENDER_MAX = 64
local lastWritePurgeAtByFront = {}
-- Kills par front sur la fenetre de 5 min, en tranches de 10 s (30 au plus par front).
-- Memoire seulement : alimente par les K deja recus et valides, aucun paquet en plus.
local KILL_SLOT_SEC = 10
local KILL_DELTA_MAX = 30
local killSlotsByFront = {}
-- Hors front : la carte de zone "#uiMapID" deja portee par le K. Nom localise en cache,
-- au plus WORLD_KEY_MAX zones suivies, et seulement les combats d'au moins 5 kills
-- (3 lignes au plus) dans le panneau.
local WORLD_KEY_MAX = 24
local WORLD_MIN_KILLS = 5
local WORLD_ROWS_MAX = 3
local killLastAtByKey = {}
local worldNameByKey = {}
local worldNameCount = 0
local worldKeyCount = 0
local preparedActivityRoot, preparedActorRoot = nil, nil
-- Paliers de combat annonces (FK), voir plus bas : zone -> { [palier] = expiration }.
local reportedByKey = {}
local reportedCount = 0
local reportRevision = 0
local ownSentByKey = {}
-- Budget glissant par cle (expediteur, passerelle) : `limit` annonces par fenetre,
-- `maxKeys` cles suivies, la plus ancienne cede sa place (jamais de refus en bloc).
local function NewLimiter(limit, window, maxKeys)
    local entries, count = {}, 0
    local limiter = {}
    function limiter.take(key, now)
        local entry = entries[key]
        if not entry or now - entry.since >= window or now < entry.since then
            if not entry then
                if count >= maxKeys then
                    local oldest, oldestSince
                    for name, e in pairs(entries) do
                        if now - e.since >= window then
                            entries[name] = nil
                            count = count - 1
                        elseif not oldestSince or e.since < oldestSince then
                            oldest, oldestSince = name, e.since
                        end
                    end
                    if count >= maxKeys and oldest then
                        entries[oldest] = nil
                        count = count - 1
                    end
                end
                count = count + 1
            end
            entry = { since = now, used = 0 }
            entries[key] = entry
        end
        if entry.used >= limit then return false end
        entry.used = entry.used + 1
        return true
    end
    function limiter.reset() wipe(entries); count = 0 end
    return limiter
end
-- A la reception : 20 annonces par expediteur et par minute (une reponse de synchro en
-- porte jusqu'a 10), 80 par passerelle (le
-- dernier saut authentifie : un faussaire qui change de nom passe par la meme).
local originLimiter = NewLimiter(20, 60, 256)
local gatewayLimiter = NewLimiter(80, 60, 256)

-- Horloge commune Blizzard : contrairement a l'heure systeme du PC, elle ne derive pas
-- entre deux joueurs. Le fallback ne sert que pendant une indisponibilite API improbable.
local function ActivityNow()
    local now = GetServerTime and tonumber(GetServerTime()) or nil
    if now and now > 0 and now ~= math.huge then return math.floor(now) end
    return time()
end

function FA:GetRevision()
    return activityRevision
end

-- Reset hebdomadaire : l'activite de la semaine passee disparait du dock tout de suite
-- (au lieu de vieillir 5 min). Appele par Overlord:ResetAll.
function FA:ResetForCampaign()
    if OverlordDB then
        OverlordDB.frontActivity, OverlordDB.frontActivityActors = {}, {}
    end
    wipe(killSlotsByFront)
    wipe(killLastAtByKey)
    worldKeyCount = 0
    wipe(reportedByKey)
    reportedCount = 0
    wipe(ownSentByKey)
    reportRevision = reportRevision + 1
    originLimiter.reset()
    gatewayLimiter.reset()
    preparedActivityRoot, preparedActorRoot = nil, nil
    wipe(lastWritePurgeAtByFront)
    activityRevision = activityRevision + 1
    for _, callback in pairs(activityChangeListeners) do
        pcall(callback, nil, activityRevision)
    end
end

local function PublishActivityChange(frontId)
    activityRevision = activityRevision + 1
    for _, callback in pairs(activityChangeListeners) do
        pcall(callback, frontId, activityRevision)
    end
end

-- Paliers de combat partages (relais en service) : le panneau ne montre alors que
-- l'etat partage, le meme chez tous (voir FK plus bas).
local function SharingActive()
    local net = Overlord.BetaNetwork
    return net ~= nil and net.Broadcast ~= nil and (not net.IsEnabled or net:IsEnabled())
end

local function IsKnownFrontId(frontId)
    return type(frontId) == "string" and frontId ~= ""
        and Overlord.Fronts and Overlord.Fronts.GetFront
        and Overlord.Fronts:GetFront(frontId) ~= nil
end

local function GetActivitySourceOrder()
    local order = {}
    local fronts = Overlord.Fronts
    for _, frontId in ipairs((fronts and fronts.Order) or {}) do
        order[#order + 1] = frontId
    end
    return order
end

local function EnsureZoneIndex()
    if zoneToFront then return zoneToFront end
    local fronts = Overlord.Fronts
    if not fronts or not fronts.Order then return nil end
    local index = {}
    for _, frontId in ipairs(fronts.Order) do
        local front = fronts:GetFront(frontId)
        for _, zone in ipairs((front and front.zones) or {}) do
            index[zone.id] = frontId
        end
    end
    zoneToFront = index
    return index
end

local function GetStores()
    if not OverlordDB then return nil, nil end
    if OverlordDB.frontActivitySchema ~= ACTIVITY_SCHEMA then
        -- Le timestamp agrege reste valable depuis le schema 3. Les acteurs ne
        -- servent qu'a un libelle borne (31+) : repartir a vide elimine en O(1)
        -- les anciens buckets non bornes sans perdre l'activite du front.
        local previous = type(OverlordDB.frontActivity) == "table"
            and OverlordDB.frontActivity or {}
        local bounded = {}
        for _, frontId in ipairs(GetActivitySourceOrder()) do
            if previous[frontId] ~= nil then bounded[frontId] = previous[frontId] end
        end
        OverlordDB.frontActivity = bounded
        OverlordDB.frontActivityActors = {}
        OverlordDB.frontActivitySchema = ACTIVITY_SCHEMA
    end
    if type(OverlordDB.frontActivity) ~= "table" then
        OverlordDB.frontActivity = {}
    end
    if type(OverlordDB.frontActivityActors) ~= "table" then
        OverlordDB.frontActivityActors = {}
    end
    if preparedActivityRoot ~= OverlordDB.frontActivity
        or preparedActorRoot ~= OverlordDB.frontActivityActors then
        -- Une SavedVariable au schema courant peut tout de meme avoir ete tronquee ou
        -- editee. Ne jamais laisser un getter/ticker decouvrir une racine de 10k lignes :
        -- seuls les fronts fixes sont copies et chaque bucket est inspecte au plus 65 fois.
        local previousActivity, previousActors =
            OverlordDB.frontActivity, OverlordDB.frontActivityActors
        local boundedActivity, boundedActors = {}, {}
        for _, frontId in ipairs(GetActivitySourceOrder()) do
            if previousActivity[frontId] ~= nil then
                boundedActivity[frontId] = previousActivity[frontId]
            end
            local bucket = previousActors[frontId]
            if type(bucket) == "table" then
                local count = 0
                for _ in pairs(bucket) do
                    count = count + 1
                    if count > ACTIVITY_ACTOR_MAX then break end
                end
                if count <= ACTIVITY_ACTOR_MAX then boundedActors[frontId] = bucket end
            end
        end
        OverlordDB.frontActivity = boundedActivity
        OverlordDB.frontActivityActors = boundedActors
        preparedActivityRoot, preparedActorRoot = boundedActivity, boundedActors
    end
    return OverlordDB.frontActivity, OverlordDB.frontActivityActors
end

local function NormalizeTimestamp(ts, now)
    now = now or ActivityNow()
    if ts == nil then
        ts = now
    else
        ts = tonumber(ts)
        if not ts then return nil end
    end
    if ts ~= ts or ts == math.huge or ts == -math.huge then return nil end
    ts = math.floor(ts)
    if ts <= 0 or ts > now + MAX_FUTURE_SKEW then return nil end
    if ts > now then ts = now end
    if (now - ts) > ACTIVITY_WINDOW then return nil end
    return ts
end

local function NormalizeActorKey(playerName)
    if type(playerName) ~= "string" or playerName == "" then return nil end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName) or playerName
    end
    playerName = playerName:match("^%s*(.-)%s*$") or ""
    if playerName == "" then return nil end
    if sync and sync.IsValidPlayerName and not sync:IsValidPlayerName(playerName) then
        return nil
    end
    return playerName:lower()
end

local function NormalizeSenderKey(sender)
    if type(sender) ~= "string" or sender == "" then return nil end
    if sender:match("^BNet%-%d+$") then return sender:lower() end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local key = sync:GetCaptureContributorDedupKey(sender)
        if key and key ~= "" then return key:lower() end
    end
    return sender:lower()
end

local function IsRecognizedActivitySender(sender)
    if type(sender) ~= "string" or sender == "" then return false end
    -- Un identifiant BNet vient necessairement d'un compte ami dans la region courante.
    if sender:match("^BNet%-%d+$") then return true end
    local sync = Overlord.Sync
    if not sync then return false end
    if sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender) then return true end
    -- Reutilise le cache de roster communaute deja durci pour GK/GC. Cela exclut un
    -- inconnu du canal royaume qui tenterait d'injecter directement un FA agrege.
    if sync.IsKnownRelayPeer and sync:IsKnownRelayPeer(sender) then
        return true
    end
    return false
end

local function RemoveExpectedSender(senderKey)
    local node = expectedSenderNodes[senderKey]
    if not node then return end
    if node.previous then node.previous.next = node.next else expectedSenderHead = node.next end
    if node.next then node.next.previous = node.previous else expectedSenderTail = node.previous end
    expectedSenderNodes[senderKey], expectedSyncSenders[senderKey] = nil, nil
    expectedSenderCount = math.max(0, expectedSenderCount - 1)
end

local function PurgeExpectedSyncSenders(now, maxRows)
    local visited = 0
    while expectedSenderHead and expectedSenderHead.expiresAt < now
        and visited < (maxRows or 8) do
        local key = expectedSenderHead.key
        RemoveExpectedSender(key)
        visited = visited + 1
    end
end

local function ExpectSyncResponse(target, bnetTarget)
    local expiresAt = GetTime()
        + (target ~= nil and SYNC_TARGET_RESPONSE_TTL or SYNC_BROADCAST_RESPONSE_TTL)
    if target ~= nil then
        local senderKey = bnetTarget and ("bnet-" .. tostring(target))
            or NormalizeSenderKey(target)
        if senderKey then
            local node = expectedSenderNodes[senderKey]
            if node then
                node.expiresAt = math.max(node.expiresAt, expiresAt)
                expectedSyncSenders[senderKey] = node.expiresAt
                if node ~= expectedSenderTail then
                    if node.previous then node.previous.next = node.next
                    else expectedSenderHead = node.next end
                    if node.next then node.next.previous = node.previous end
                    node.previous, node.next = expectedSenderTail, nil
                    if expectedSenderTail then expectedSenderTail.next = node end
                    expectedSenderTail = node
                end
            else
                PurgeExpectedSyncSenders(GetTime(), 8)
                if expectedSenderCount < EXPECTED_SENDER_MAX then
                    node = { key = senderKey, expiresAt = expiresAt, previous = expectedSenderTail }
                    if expectedSenderTail then expectedSenderTail.next = node else expectedSenderHead = node end
                    expectedSenderTail = node
                    expectedSenderNodes[senderKey] = node
                    expectedSyncSenders[senderKey] = expiresAt
                    expectedSenderCount = expectedSenderCount + 1
                end
            end
        end
    else
        expectedAnySyncResponseUntil = math.max(expectedAnySyncResponseUntil, expiresAt)
    end
    PurgeExpectedSyncSenders(GetTime(), 8)
end

local function IsExpectedSyncResponse(sender, sourceChannel)
    if sourceChannel ~= "CHANNEL" and sourceChannel ~= "PARTY"
        and sourceChannel ~= "RAID" and sourceChannel ~= "WHISPER"
        and sourceChannel ~= "BNET" then
        return false
    end
    local now = GetTime()
    if expectedAnySyncResponseUntil >= now then return true end
    local senderKey = NormalizeSenderKey(sender)
    local expiresAt = senderKey and expectedSyncSenders[senderKey]
    if expiresAt and expiresAt >= now then return true end
    if expiresAt then RemoveExpectedSender(senderKey) end
    return false
end

local function IsTrustedAggregateSender(sender, sourceChannel)
    return IsRecognizedActivitySender(sender)
        or IsExpectedSyncResponse(sender, sourceChannel)
end

function FA:IsTrustedEventSender(sender)
    return IsRecognizedActivitySender(sender)
end

local function PurgeFront(frontId, activity, actors, now)
    local changed = false
    local lastTs = tonumber(activity[frontId])
    local normalizedLastTs = lastTs and NormalizeTimestamp(lastTs, now) or nil
    if not normalizedLastTs then
        if activity[frontId] ~= nil then
            activity[frontId] = nil
            changed = true
        end
    elseif normalizedLastTs ~= lastTs then
        activity[frontId] = normalizedLastTs
        changed = true
    end

    local bucket = actors[frontId]
    if type(bucket) ~= "table" then
        if bucket ~= nil then
            actors[frontId] = nil
            changed = true
        end
        return changed
    end
    for name, ts in pairs(bucket) do
        ts = tonumber(ts)
        local normalizedTs = ts and NormalizeTimestamp(ts, now) or nil
        if not normalizedTs then
            bucket[name] = nil
            changed = true
        elseif normalizedTs ~= ts then
            bucket[name] = normalizedTs
            changed = true
        end
    end
    if not next(bucket) then
        actors[frontId] = nil
        changed = true
    end
    return changed
end

local function PurgeAll(activity, actors, now)
    local seen = {}
    for frontId in pairs(activity) do seen[frontId] = true end
    for frontId in pairs(actors) do seen[frontId] = true end
    local changed = false
    for frontId in pairs(seen) do
        if not IsKnownFrontId(frontId) then
            activity[frontId] = nil
            actors[frontId] = nil
            changed = true
        elseif PurgeFront(frontId, activity, actors, now) then
            changed = true
        end
    end
    if changed then PublishActivityChange(nil) end
end

function FA:GetFrontIdFromZoneRef(zoneRef)
    if type(zoneRef) ~= "string" or zoneRef == "" then return nil end
    if zoneRef:sub(1, 1) == "@" then
        local frontId = zoneRef:sub(2)
        return IsKnownFrontId(frontId) and frontId or nil
    end
    local index = EnsureZoneIndex()
    return index and index[zoneRef] or nil
end

function FA:GetLocalFrontId(zoneRef)
    local frontId = self:GetFrontIdFromZoneRef(zoneRef)
    if frontId then return frontId end
    if (zoneRef == nil or zoneRef == "") and Overlord.InActiveFront
        and Overlord.Fronts and IsKnownFrontId(Overlord.Fronts.activeFrontId) then
        return Overlord.Fronts.activeFrontId
    end
    return nil
end

-- Enregistre une activite deja validee. playerName est optionnel : FA/ZA transportent
-- un timestamp fiable sans necessairement connaitre l'acteur d'origine.
function FA:Record(frontId, playerName, ts, actorOnly)
    if not IsKnownFrontId(frontId) then return false end
    local activity, actors = GetStores()
    if not activity then return false end
    local now = ActivityNow()
    ts = NormalizeTimestamp(ts, now)
    if not ts then return false end

    local changed = false
    local lastPurgeAt = tonumber(lastWritePurgeAtByFront[frontId]) or 0
    if now - lastPurgeAt >= ACTIVITY_WRITE_PURGE_INTERVAL then
        lastWritePurgeAtByFront[frontId] = now
        if PurgeFront(frontId, activity, actors, now) then
            changed = true
        end
    end
    local previous = tonumber(activity[frontId]) or 0
    if not actorOnly and ts > previous then
        activity[frontId] = ts
        changed = true
    end

    local actorKey = NormalizeActorKey(playerName)
    if actorKey then
        local bucket = actors[frontId]
        if type(bucket) ~= "table" then
            bucket = {}
            actors[frontId] = bucket
        end
        local actorPrevious = tonumber(bucket[actorKey]) or 0
        if actorPrevious <= 0 then
            local actorCount = 0
            for _ in pairs(bucket) do
                actorCount = actorCount + 1
                if actorCount >= ACTIVITY_ACTOR_MAX then break end
            end
            -- Le panneau n'observe jamais au-dela du bucket "31+". Refuser un
            -- 65e nom garde purge/UI strictement bornes sous une rafale reseau.
            if actorCount >= ACTIVITY_ACTOR_MAX then actorKey = nil end
        end
        if not actorKey then
            if changed then PublishActivityChange(frontId) end
            return changed
        end
        if ts > actorPrevious then
            bucket[actorKey] = ts
            changed = true
        end
    end

    if changed then PublishActivityChange(frontId) end
    return changed
end

function FA:RecordByZoneRef(zoneRef, playerName, ts)
    local frontId = self:GetFrontIdFromZoneRef(zoneRef)
    if not frontId then return false end
    return self:Record(frontId, playerName, ts)
end

function FA:RecordLocalByZoneRef(zoneRef, playerName, ts)
    local frontId = self:GetLocalFrontId(zoneRef)
    if not frontId then return false end
    return self:Record(frontId, playerName, ts)
end

-- Preuve de combat entendue seulement par ce client (K recu, notre kill, avis de mort) :
-- quand les paliers sont partages (relais actif), elle ne date plus la ligne du
-- panneau. L'activite des combats arrive alors par les paliers FK, les memes chez tous.
function FA:RecordKillActivity(zoneRef, playerName, ts, isLocal)
    local frontId
    if isLocal then frontId = self:GetLocalFrontId(zoneRef) else frontId = self:GetFrontIdFromZoneRef(zoneRef) end
    if not frontId then return false end
    return self:Record(frontId, playerName, ts, SharingActive())
end

-- Taille du combat : nouveaux kills deja comptes par l'alerte de guilde (delta de
-- totaux K successifs d'un meme joueur, une copie en double ne compte pas).
-- "#uiMapID" : le front de cette carte s'il y en a un, sinon la zone du monde (une
-- vraie carte de zone seulement : un identifiant invente ou une instance est ignore).
local function ResolveWorldKillKey(zoneRef)
    local mapID = type(zoneRef) == "string" and tonumber(zoneRef:match("^#(%d+)$"))
    if not mapID or mapID <= 0 then return nil end
    local key = "#" .. mapID
    local cached = worldNameByKey[key]
    if cached == false then return nil end
    -- Carte encore illisible (donnees pas chargees au login) : nouvel essai apres 60 s.
    if type(cached) == "number" then
        if GetTime() < cached then return nil end
        cached = nil
    end
    if cached == nil then
        local ok, info = false, nil
        if C_Map and C_Map.GetMapInfo then ok, info = pcall(C_Map.GetMapInfo, mapID) end
        local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
        cached = ok and type(info) == "table" and info.mapType == zoneType
            and type(info.name) == "string" and info.name ~= "" and info.name or false
        if cached == false and not (ok and type(info) == "table") then cached = GetTime() + 60 end
        -- Des identifiants inventes ne font jamais grossir le cache au-dela de 256.
        -- Les noms des zones suivies sont gardes (leur ligne ne disparait pas).
        if worldNameCount >= 256 then
            local kept = {}
            for tracked in pairs(killLastAtByKey) do kept[tracked] = worldNameByKey[tracked] end
            -- Zones dont un palier partage est affiche : leur nom reste aussi.
            for tracked in pairs(reportedByKey) do
                if kept[tracked] == nil then kept[tracked] = worldNameByKey[tracked] end
            end
            wipe(worldNameByKey)
            worldNameCount = 0
            for tracked, name in pairs(kept) do
                worldNameByKey[tracked] = name
                worldNameCount = worldNameCount + 1
            end
        end
        worldNameByKey[key] = cached
        worldNameCount = worldNameCount + 1
        if type(cached) ~= "string" then return nil end
    end
    -- Une carte de zone d'un front compte pour ce front.
    local fronts = Overlord.Fronts
    local front = fronts and fronts.ResolveFrontByOverlayMapID and fronts:ResolveFrontByOverlayMapID(mapID)
    if front and IsKnownFrontId(front.id) then return front.id end
    return key
end

-- Zones inactives retirees ; liste pleine : la zone la plus ancienne cede sa place, pour
-- qu'un nouveau combat ne soit jamais refuse.
local function PurgeIdleWorldKeys(now)
    local oldestKey, oldestAt
    for key in pairs(killLastAtByKey) do
        local lastAt = killLastAtByKey[key]
        if now - lastAt > ACTIVITY_WINDOW then
            killLastAtByKey[key], killSlotsByFront[key] = nil, nil
            worldKeyCount = math.max(0, worldKeyCount - 1)
        elseif not oldestAt or lastAt < oldestAt then
            oldestKey, oldestAt = key, lastAt
        end
    end
    if worldKeyCount >= WORLD_KEY_MAX and oldestKey then
        killLastAtByKey[oldestKey], killSlotsByFront[oldestKey] = nil, nil
        worldKeyCount = worldKeyCount - 1
    end
end

-- Zone hors front suivie (kills locaux ou palier recu) ; liste pleine : la plus
-- ancienne cede sa place.
local function TrackWorldKey(key, at, now)
    if not killLastAtByKey[key] then
        if worldKeyCount >= WORLD_KEY_MAX then PurgeIdleWorldKeys(now) end
        if worldKeyCount >= WORLD_KEY_MAX then return false end
        worldKeyCount = worldKeyCount + 1
    end
    killLastAtByKey[key] = math.max(killLastAtByKey[key] or 0, at)
    return true
end

local MaybeScheduleReport

function FA:RecordKills(zoneRef, kills)
    if Overlord.InstanceSuspended then return false end
    kills = tonumber(kills)
    if not kills or kills <= 0 or kills ~= kills then return false end
    local frontId = self:GetFrontIdFromZoneRef(zoneRef)
    local now = ActivityNow()
    if not frontId then
        frontId = ResolveWorldKillKey(zoneRef)
        if not frontId then return false end
        if frontId:sub(1, 1) == "#" then
            if not TrackWorldKey(frontId, now, now) then return false end
        else
            -- Carte d'un front annoncee en "#uiMapID" : le front devient actif aussi
            -- (sauf quand les paliers sont partages : c'est alors le palier qui le date).
            self:Record(frontId, nil, now, SharingActive())
        end
    end
    local slot = math.floor(now / KILL_SLOT_SEC)
    local slots = killSlotsByFront[frontId]
    if not slots then
        slots = {}
        killSlotsByFront[frontId] = slots
    end
    local oldest = slot - math.floor(ACTIVITY_WINDOW / KILL_SLOT_SEC)
    for key in pairs(slots) do
        if key <= oldest or key > slot then slots[key] = nil end
    end
    slots[slot] = (slots[slot] or 0) + math.min(KILL_DELTA_MAX, math.floor(kills))
    MaybeScheduleReport(frontId, now)
    return true
end

function FA:GetKillCount(frontId, now)
    local slots = killSlotsByFront[frontId]
    if not slots then return 0 end
    now = now or ActivityNow()
    local slot = math.floor(now / KILL_SLOT_SEC)
    local oldest = slot - math.floor(ACTIVITY_WINDOW / KILL_SLOT_SEC)
    local total = 0
    for key, count in pairs(slots) do
        if key <= oldest or key > slot then slots[key] = nil else total = total + count end
    end
    if not next(slots) then killSlotsByFront[frontId] = nil end
    return total
end

-- Taille des combats partagee. Chaque client compte les K qu'il recoit, et un K n'est
-- jamais relaye : deux joueurs voyaient donc des chiffres differents. Quand le compte
-- local d'une zone franchit un palier (1 = front actif, puis 5+, 10+, 20+...), le client
-- l'annonce (FK) ; chacun affiche le plus haut palier encore frais, le sien ou un recu.
-- Tous convergent sur le meme chiffre : celui du joueur le mieux informe.
-- Cout : une annonce par palier franchi, puis un rappel toutes les ~3,5 min tant que le
-- combat dure (un palier recu au moins egal et encore valable plus de 90 s couvre le
-- notre). Tous ceux qui entendent les memes K franchissent le palier ensemble : seule
-- une petite part (environ 4 / voisins directs) annonce dans les 1-6 s, les autres
-- attendent 10-18 s puis 25-40 s et renoncent des qu'un palier couvrant a circule.
-- Le relais coupe toujours les copies identiques (meme palier, meme tranche de 30 s),
-- un client ne renvoie jamais son propre palier avant l'heure du rappel, et une
-- annonce recue ne declenche jamais d'envoi.
-- FK : 1:<front|#uiMapID>:<palier>:<tranche de 30 s du serveur>
local FIGHT_BRACKETS = { 500, 300, 200, 150, 100, 75, 50, 40, 30, 20, 10, 5 }
local REPORT_BRACKET_OK = { [1] = true }
for _, floor in ipairs(FIGHT_BRACKETS) do REPORT_BRACKET_OK[floor] = true end
local REPORT_SLOT_SEC = 30
local REPORT_REFRESH_MARGIN = 90
local REPORT_MAX_KEYS = 32
local REPORT_MAX_PAYLOAD = 48
local pendingReport = {}

local function IsWorldKey(key)
    return type(key) == "string" and key:sub(1, 1) == "#"
end

-- Palier annonce pour un compte local : hors front, seuls les combats listes (5+).
local function ReportBracket(key, kills)
    kills = tonumber(kills) or 0
    for _, floor in ipairs(FIGHT_BRACKETS) do
        if kills >= floor then return floor end
    end
    if kills >= 1 and not IsWorldKey(key) then return 1 end
    return 0
end

-- Par zone, l'expiration de chaque palier annonce : le plus haut encore frais
-- s'affiche, et un rappel a un palier plus bas (le combat faiblit) couvre ce palier.
local function FreshBrackets(key, now)
    local entries = reportedByKey[key]
    if not entries then return nil end
    local any = false
    for bracket, expiresAt in pairs(entries) do
        if expiresAt <= now then entries[bracket] = nil else any = true end
    end
    if not any then
        reportedByKey[key] = nil
        reportedCount = math.max(0, reportedCount - 1)
        return nil
    end
    return entries
end

local function TopBracket(key, now)
    local entries = FreshBrackets(key, now)
    local top = 0
    if entries then
        for bracket in pairs(entries) do
            if bracket > top then top = bracket end
        end
    end
    return top
end

local function StoreReport(key, bracket, expiresAt, now)
    local entries = FreshBrackets(key, now)
    if not entries then
        if reportedCount >= REPORT_MAX_KEYS then
            for tracked in pairs(reportedByKey) do FreshBrackets(tracked, now) end
        end
        if reportedCount >= REPORT_MAX_KEYS then
            -- Table pleine : la zone dont les paliers expirent le plus tot cede sa place.
            local victim, victimAt
            for tracked, list in pairs(reportedByKey) do
                local latest = 0
                for _, expiresAt in pairs(list) do
                    if expiresAt > latest then latest = expiresAt end
                end
                if not victimAt or latest < victimAt then victim, victimAt = tracked, latest end
            end
            if victim then
                reportedByKey[victim] = nil
                reportedCount = reportedCount - 1
            end
        end
        entries = {}
        reportedByKey[key] = entries
        reportedCount = reportedCount + 1
    end
    if (entries[bracket] or 0) >= expiresAt then return false end
    entries[bracket] = expiresAt
    reportRevision = reportRevision + 1
    return true
end

-- Couvert : un palier au moins egal reste valable plus de 90 s.
local function ReportCovers(key, bracket, now)
    local own = ownSentByKey[key]
    if own and own.expiresAt <= now then
        ownSentByKey[key] = nil
        own = nil
    end
    if own and own.bracket >= bracket and own.expiresAt - now > REPORT_REFRESH_MARGIN then
        return true
    end
    local entries = FreshBrackets(key, now)
    if not entries then return false end
    for reported, expiresAt in pairs(entries) do
        if reported >= bracket and expiresAt - now > REPORT_REFRESH_MARGIN then return true end
    end
    return false
end

-- Vague d'annonce : environ 4 clients sur l'ensemble des voisins directs annoncent
-- tout de suite, une part 8 fois plus grande ensuite, les autres en dernier.
local function ReportDelay()
    local crowd = 1
    local net = Overlord.BetaNetwork
    if net and net.CountDirectPeers then
        local ok, count = pcall(net.CountDirectPeers, net)
        if ok and tonumber(count) then crowd = tonumber(count) + 1 end
    elseif net and net.GetDirectPeers then
        local ok, peers = pcall(net.GetDirectPeers, net)
        if ok and type(peers) == "table" then crowd = #peers + 1 end
    end
    -- Plancher : sans maillage dense (peu de voisins directs), beaucoup de clients
    -- franchissent quand meme le palier ensemble ; mieux vaut converger un peu plus tard.
    local early = math.min(1, 4 / math.max(crowd, 100))
    local roll = math.random()
    if roll < early then return 1 + math.random() * 5 end
    if roll < math.min(1, early * 8) then return 10 + math.random() * 8 end
    return 25 + math.random() * 15
end

local function SendReport(key, bracket, now)
    local slot = math.floor(now / REPORT_SLOT_SEC)
    local expiresAt = slot * REPORT_SLOT_SEC + ACTIVITY_WINDOW
    local payload = "1:" .. key .. ":" .. bracket .. ":" .. slot
    local net = Overlord.BetaNetwork
    if not (net and net.Broadcast) or (net:Broadcast("FK", payload) or 0) <= 0 then
        -- Refuse (relais sature ou absent) : rien n'est couvert ni affiche, nouvel essai
        -- dans 20 s au plus tot (pas a chaque kill).
        ownSentByKey[key] = { bracket = bracket, expiresAt = now + REPORT_REFRESH_MARGIN + 20 }
        return false
    end
    -- Notre envoi couvre ce palier meme si la table des paliers recus est pleine.
    ownSentByKey[key] = { bracket = bracket, expiresAt = expiresAt }
    StoreReport(key, bracket, expiresAt, now)
    if IsWorldKey(key) then
        TrackWorldKey(key, slot * REPORT_SLOT_SEC, now)
        PublishActivityChange(key)
    else
        FA:Record(key, nil, slot * REPORT_SLOT_SEC)
    end
    return true
end

MaybeScheduleReport = function(key, now)
    if pendingReport[key] or Overlord.InstanceSuspended or not SharingActive() then return end
    local bracket = ReportBracket(key, FA:GetKillCount(key, now))
    if bracket <= 0 or ReportCovers(key, bracket, now) then return end
    if not (C_Timer and C_Timer.After) then return end
    pendingReport[key] = true
    C_Timer.After(ReportDelay(), function()
        pendingReport[key] = nil
        if Overlord.InstanceSuspended then return end
        local t = ActivityNow()
        local current = ReportBracket(key, FA:GetKillCount(key, t))
        if current <= 0 or ReportCovers(key, current, t) then return end
        SendReport(key, current, t)
    end)
end

-- Kills affiches. Relais actif : seulement les paliers partages (les memes chez tous ;
-- notre compte local sert a annoncer). Sans relais : le compte local, comme avant.
function FA:GetDisplayKillCount(key, now)
    now = now or ActivityNow()
    local top = TopBracket(key, now)
    if SharingActive() then return top end
    local localCount = self:GetKillCount(key, now)
    if top > localCount then return top end
    return localCount
end

-- Heure (serveur) du palier frais le plus recent d'une zone, ou nil.
local function LatestReportAt(key, now)
    local entries = FreshBrackets(key, now)
    if not entries then return nil end
    local latest
    for _, expiresAt in pairs(entries) do
        local at = expiresAt - ACTIVITY_WINDOW
        if not latest or at > latest then latest = at end
    end
    return latest
end

-- Paliers frais a transmettre dans une reponse de synchronisation (connexion, reload,
-- retour d'instance). Par zone : le plus haut, et celui qui vit le plus longtemps s'il
-- est different (sinon la zone disparaitrait plus tot chez l'arrivant). 10 au plus.
local syncEntriesCache, syncEntriesAt, syncEntriesRevision = nil, 0, -1
function FA:BuildKillBracketSyncEntries()
    local now = ActivityNow()
    -- Une vague de connexions demande souvent la meme liste : gardee 10 s tant
    -- qu'aucun palier n'a change.
    if syncEntriesCache and syncEntriesRevision == reportRevision and now - syncEntriesAt < 10 then
        return syncEntriesCache
    end
    local out = {}
    for key in pairs(reportedByKey) do
        local entries = FreshBrackets(key, now)
        if entries then
            local top, topAt, last, lastAt = 0, 0, 0, 0
            for bracket, at in pairs(entries) do
                if bracket > top then top, topAt = bracket, at end
                if at > lastAt or (at == lastAt and bracket > last) then last, lastAt = bracket, at end
            end
            out[#out + 1] = { key = key, bracket = top, rank = top, at = topAt }
            if last ~= top then out[#out + 1] = { key = key, bracket = last, rank = top, at = lastAt } end
        end
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.key ~= b.key then return a.key < b.key end
        return a.bracket > b.bracket
    end)
    local payloads = {}
    for i = 1, math.min(10, #out) do
        local slot = math.floor((out[i].at - ACTIVITY_WINDOW) / REPORT_SLOT_SEC)
        payloads[i] = "1:" .. out[i].key .. ":" .. out[i].bracket .. ":" .. slot
    end
    syncEntriesCache, syncEntriesAt, syncEntriesRevision = payloads, now, reportRevision
    return payloads
end

function FA:OnReceiveKillBracket(payload, sender, sourceChannel)
    if Overlord.InstanceSuspended then return false end
    if type(payload) ~= "string" or #payload > REPORT_MAX_PAYLOAD then return false end
    local key, bracketStr, slotStr = payload:match("^1:([^:]+):(%d+):(%d+)$")
    local bracket, slot = tonumber(bracketStr), tonumber(slotStr)
    if not key or not REPORT_BRACKET_OK[bracket] or not slot then return false end
    -- Hors front, seuls les combats listes (5+) : rejete avant toute recherche de carte.
    if bracket < 5 and IsWorldKey(key) then return false end
    -- Seulement par le relais (ou dans la reponse a notre demande de synchro) : un FK
    -- brut pose sur le canal ou le groupe par un inconnu est ignore.
    if sourceChannel ~= "BETA" and not IsTrustedAggregateSender(sender, sourceChannel) then
        return false
    end
    local now = ActivityNow()
    local at = slot * REPORT_SLOT_SEC
    if at > now + 60 or now - at > ACTIVITY_WINDOW then return false end
    at = math.min(at, now)
    -- Budgets avant toute recherche de carte : la passerelle d'abord (un faussaire qui
    -- change de nom passe par la meme), puis l'expediteur.
    local sync = Overlord.Sync
    local gateway = sync and sync.BurstLimiterKey and sync:BurstLimiterKey(sender) or sender
    gateway = type(gateway) == "string" and gateway:lower() or "?"
    if not gatewayLimiter.take(gateway, now) then return false end
    if not originLimiter.take(type(sender) == "string" and sender:lower() or "?", now) then
        return false
    end
    local resolved
    if key:match("^#%d+$") then
        resolved = ResolveWorldKillKey(key)
    elseif IsKnownFrontId(key) then
        resolved = key
    end
    if not resolved or (bracket < 5 and IsWorldKey(resolved)) then return false end
    if IsWorldKey(resolved) then
        if not TrackWorldKey(resolved, at, now) then return false end
    else
        self:Record(resolved, nil, at)
    end
    if not StoreReport(resolved, bracket, at + ACTIVITY_WINDOW, now) then return false end
    PublishActivityChange(resolved)
    return true
end

local function WorldRowBefore(a, b)
    if a.bracket ~= b.bracket then return a.bracket > b.bracket end
    return a.frontId < b.frontId
end

-- Captures shown by bracket (1+, 5+, 10+, like Popups): rows are ordered by the shown
-- bracket, never the raw count, so one capture not yet synced cannot swap two rows.
local function CaptureBracket(captures)
    captures = tonumber(captures) or 0
    if captures >= 10 then return 10 elseif captures >= 5 then return 5 end
    return captures >= 1 and 1 or 0
end
FA.GetCaptureBracket = CaptureBracket

-- Inactive rows follow the fronts' fixed order, never the translated name.
local function FrontOrderIndex(frontId)
    local order = Overlord.Fronts and Overlord.Fronts.Order
    if order then
        for i = 1, #order do
            if order[i] == frontId then return i end
        end
    end
    return 1000
end

local function ActivityRowBefore(a, b)
    if a.active ~= b.active then return a.active end
    if a.active then
        if a.bracket ~= b.bracket then return a.bracket > b.bracket end
        local ca, cb = CaptureBracket(a.captures), CaptureBracket(b.captures)
        if ca ~= cb then return ca > cb end
        -- Identifiant, pas le nom traduit : meme ordre quelle que soit la langue.
        return a.frontId < b.frontId
    end
    local ia, ib = FrontOrderIndex(a.frontId), FrontOrderIndex(b.frontId)
    if ia ~= ib then return ia < ib end
    return tostring(a.frontId) < tostring(b.frontId)
end

local function GetFrontActivityDisplayName(front)
    if not front then return "?" end
    return front.dropdownLabel or front.mapName or front.id or "?"
end

-- Zones of a front taken in the last 5 minutes, read from the shared map: the
-- capture time is the capture's own server time, the same on every client once
-- the map is synced. Shared stamps that are not captures (campaign start, a
-- truce end: zones at its epoch, the kept capital one second later) never count.
-- Each distinct capture time counts once:
-- a front victory stamps every zone with its time, which is one capture (the
-- capital), not "10+". Read from the map alone, so a client missing the victory
-- record counts the same as the others.
local seenCaptureTimes = {}
function FA:GetRecentCaptureCount(frontId, now)
    local front = Overlord.Fronts and Overlord.Fronts.GetFront and Overlord.Fronts:GetFront(frontId)
    if not front or type(front.zones) ~= "table" then return 0 end
    now = now or ActivityNow()
    local campaignStart = math.floor(tonumber(Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs()) or 0)
    local releaseEpoch = OverlordDB and OverlordDB.frontTruceResetEpoch
        and math.floor(tonumber(OverlordDB.frontTruceResetEpoch[frontId]) or 0) or 0
    local count = 0
    wipe(seenCaptureTimes)
    -- A truce end read from the map alone (kept capital one second after the other
    -- zones), so a client that has the map but not yet the truce end counts alike.
    -- A capital being retaken is judged on its stable base, like every zone below: the
    -- capture in progress is not a capture yet, and its overlay keeps the base's stamp.
    local zonesApi = Overlord.Zones
    local function stable(zone)
        if zone.status ~= "in_progress" then return zone end
        return zonesApi and zonesApi.GetStableZoneView and zonesApi:GetStableZoneView(zone) or nil
    end
    if zonesApi and zonesApi.IsKeptCapitalStamp then
        for _, capId in ipairs({ front.allianceCapitalId or false, front.hordeCapitalId or false }) do
            local cap = capId and Overlord.Fronts.GetZone and select(1, Overlord.Fronts:GetZone(capId, frontId))
            local sv = cap and stable(cap)
            if sv and zonesApi:IsKeptCapitalStamp(frontId,
                { id = cap.id, owner = sv.owner, capturedTime = sv.capturedTime }) then
                local kept = math.floor(tonumber(sv.capturedTime) or 0)
                seenCaptureTimes[kept], seenCaptureTimes[kept - 1] = true, true
            end
        end
    end
    for _, live in ipairs(front.zones) do
        local zone = stable(live)
        local ct = zone and math.floor(tonumber(zone.capturedTime) or 0) or 0
        if zone and zone.owner and not live._captureFinalUnattested and ct > 0
            and now - ct <= ACTIVITY_WINDOW and ct <= now + MAX_FUTURE_SKEW
            and ct ~= campaignStart and ct ~= releaseEpoch and ct ~= releaseEpoch + 1
            and not seenCaptureTimes[ct] then
            seenCaptureTimes[ct] = true
            count = count + 1
        end
    end
    wipe(seenCaptureTimes)
    return count
end

-- Retourne tous les fronts. Les actifs d'abord (palier de kills, palier de captures,
-- puis identifiant du front), puis les autres dans l'ordre fixe des fronts.
function FA:GetActivityRows()
    local rows = {}
    local fronts = Overlord.Fronts
    if not fronts or not fronts.Order then return rows end
    local activity, actors = GetStores()
    local now = ActivityNow()
    if activity then PurgeAll(activity, actors, now) end

    local sharing = SharingActive()
    for _, frontId in ipairs(GetActivitySourceOrder()) do
        local front = fronts:GetFront(frontId)
        if front then
            local lastActivityAt = activity and tonumber(activity[frontId]) or nil
            local reportAt = LatestReportAt(frontId, now)
            if reportAt and (not lastActivityAt or reportAt > lastActivityAt) then lastActivityAt = reportAt end
            local ageSeconds = lastActivityAt and math.max(0, now - lastActivityAt) or nil
            local active = ageSeconds ~= nil and ageSeconds <= ACTIVITY_WINDOW
            local kills = self:GetDisplayKillCount(frontId, now)
            local captures = self:GetRecentCaptureCount(frontId, now)
            -- Relay on: a row shows only shared state (kill brackets, captures on the
            -- map), so it is active exactly when one of them is, for everyone alike.
            if sharing then active = kills > 0 or captures > 0
            elseif captures > 0 then active = true end
            rows[#rows + 1] = {
                frontId = frontId,
                label = GetFrontActivityDisplayName(front),
                lastActivityAt = active and lastActivityAt or nil,
                ageSeconds = active and ageSeconds or nil,
                active = active,
                kills = active and kills or 0,
                captures = active and captures or 0,
            }
        end
    end
    -- Combats hors front : les plus gros d'abord, 3 lignes au plus.
    local world = {}
    if sharing then
        -- Relais actif : les zones hors front annoncees (5+), les memes chez tous.
        for key in pairs(reportedByKey) do
            local kills = IsWorldKey(key) and TopBracket(key, now) or 0
            local name = worldNameByKey[key]
            if kills >= WORLD_MIN_KILLS and type(name) == "string" then
                local at = LatestReportAt(key, now) or now
                world[#world + 1] = { frontId = key, label = name, lastActivityAt = at,
                    ageSeconds = math.max(0, now - at), active = true, kills = kills, world = true }
            end
        end
    else
        for key, lastAt in pairs(killLastAtByKey) do
            local age = now - lastAt
            local kills = age <= ACTIVITY_WINDOW and self:GetDisplayKillCount(key, now) or 0
            if kills >= WORLD_MIN_KILLS and worldNameByKey[key] then
                world[#world + 1] = { frontId = key, label = worldNameByKey[key], lastActivityAt = lastAt,
                    ageSeconds = math.max(0, age), active = true, kills = kills, world = true }
            end
        end
    end
    -- Meme ordre chez tous : palier affiche, puis carte (jamais l'heure locale).
    for _, row in ipairs(world) do row.bracket = ReportBracket(row.frontId, row.kills) end
    table.sort(world, WorldRowBefore)
    for i = 1, math.min(WORLD_ROWS_MAX, #world) do rows[#rows + 1] = world[i] end
    -- Fronts actifs d'abord, les plus gros combats en tete (palier affiche, le meme chez
    -- tous grace aux annonces FK), puis l'ordre fixe des fronts : ni l'heure locale ni la langue.
    for _, row in ipairs(rows) do row.bracket = row.bracket or ReportBracket(row.frontId, row.kills) end
    table.sort(rows, ActivityRowBefore)
    return rows
end

-- FA: frontId=epochServeur,frontId=epochServeur...
-- GetServerTime fournit la meme horloge a tous les clients : le timestamp garde son age
-- exact pendant les relais, sans rajeunissement lie a la latence ou a l'horloge du PC.
function FA:BuildSyncPayload()
    local fronts = Overlord.Fronts
    if not fronts or not fronts.Order then return nil end
    local activity, actors = GetStores()
    if not activity then return nil end
    local now = ActivityNow()
    PurgeAll(activity, actors, now)
    local parts = {}
    for _, frontId in ipairs(GetActivitySourceOrder()) do
        local ts = tonumber(activity[frontId])
        if ts and (now - ts) <= ACTIVITY_WINDOW then
            parts[#parts + 1] = frontId .. "=" .. tostring(math.floor(ts))
        end
    end
    if #parts == 0 then return nil end
    local payload = table.concat(parts, ",")
    if #payload > MAX_SYNC_PAYLOAD_BYTES then return nil end
    return payload
end

function FA:OnReceiveSyncPayload(payload, sender, sourceChannel)
    if type(payload) ~= "string" or payload == "" or #payload > MAX_SYNC_PAYLOAD_BYTES then
        return false
    end
    if not IsTrustedAggregateSender(sender, sourceChannel) then return false end
    local changed = false
    local count = 0
    for entry in payload:gmatch("[^,]+") do
        count = count + 1
        if count > MAX_SYNC_ENTRIES then break end
        local frontId, tsStr = entry:match("^([%w_%-]+)=(%d+)$")
        if frontId and tsStr and self:Record(frontId, nil, tsStr) then
            changed = true
        end
    end
    return changed
end

-- Emissions locales fiables : le joueur ne recoit pas ses propres messages addon.
local Sync = Overlord.Sync
if Sync then
    -- Correlation legere des reponses FA avec nos demandes SR. Elle couvre le canal
    -- royaume et les whispers de proximite sans accepter un FA spontane d'un inconnu.
    local origSend = Sync.Send
    function Sync:Send(msgType, data, groupOnly)
        if msgType == "SR" then ExpectSyncResponse() end
        return origSend(self, msgType, data, groupOnly)
    end

    local origSendToChannel = Sync.SendToChannel
    function Sync:SendToChannel(msgType, data, critical)
        if msgType == "SR" then ExpectSyncResponse() end
        return origSendToChannel(self, msgType, data, critical)
    end

    local origSendWhisper = Sync.SendWhisper
    function Sync:SendWhisper(msgType, data, target)
        if msgType == "SR" then ExpectSyncResponse(target, false) end
        return origSendWhisper(self, msgType, data, target)
    end

    local origSendToBNet = Sync.SendToBNet
    function Sync:SendToBNet(gameAccountID, msgType, data)
        if msgType == "SR" then ExpectSyncResponse(gameAccountID, true) end
        return origSendToBNet(self, gameAccountID, msgType, data)
    end

    local origBroadcastKill = Sync.BroadcastKill
    function Sync:BroadcastKill(zoneId, totalKills, killScoringAtEvent,
        campaignEpochAtEvent, bucketEpochAtEvent, isPendingReplay)
        if not isPendingReplay then
            local myName = self.GetPlayerFullName and self:GetPlayerFullName()
            if myName and myName ~= "" then
                FA:RecordKillActivity(zoneId, myName, nil, true)
            end
        end
        return origBroadcastKill(self, zoneId, totalKills, killScoringAtEvent,
            campaignEpochAtEvent, bucketEpochAtEvent, isPendingReplay)
    end

    local origBroadcastCapture = Sync.BroadcastCapture
    function Sync:BroadcastCapture(zoneId, completedRequirement)
        local myName = self.GetPlayerFullName and self:GetPlayerFullName()
        if myName and myName ~= "" then
            FA:RecordLocalByZoneRef(zoneId, myName)
        end
        return origBroadcastCapture(self, zoneId, completedRequirement)
    end

    local origBroadcastZoneState = Sync.BroadcastZoneState
    function Sync:BroadcastZoneState(zone, forceBNetZS, primaryOnly)
        if zone and zone.status == "in_progress"
            and zone.isHolding and zone.holdAuthorityLocal then
            local myName = self.GetPlayerFullName and self:GetPlayerFullName()
            if myName and myName ~= "" then
                FA:RecordLocalByZoneRef(zone.id, myName)
            end
        end
        return origBroadcastZoneState(self, zone, forceBNetZS, primaryOnly)
    end

    function Sync:AppendFrontActivityToSrQueue(queue, directReply)
        if type(queue) ~= "table" then return end
        local payload = FA:BuildSyncPayload()
        if payload then
            queue[#queue + 1] = { type = "FA", data = payload }
        end
        -- Paliers de combat en cours : un client qui arrive voit tout de suite les
        -- memes combats que les autres (les anciens clients ignorent FK). Reponse
        -- directe seulement : rien de plus sur le quota partage du groupe et du canal.
        if directReply then
            for _, entry in ipairs(FA:BuildKillBracketSyncEntries()) do
                queue[#queue + 1] = { type = "FK", data = entry }
            end
        end
    end
end
