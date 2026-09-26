-- FrontActivity.lua : activite recente connue par front.
--
-- Le panneau ne cherche pas a reconstruire un nombre global de joueurs. Il conserve
-- le dernier evenement valide observe sur chaque front et le propage dans les reponses
-- SR via un payload compact FA. Les compteurs d'acteurs restent internes afin de ne pas
-- casser l'annonce de faction historique, mais ils ne pilotent plus le panneau.
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
local preparedActivityRoot, preparedActorRoot = nil, nil

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

local function PublishActivityChange(frontId)
    activityRevision = activityRevision + 1
    for _, callback in pairs(activityChangeListeners) do
        pcall(callback, frontId, activityRevision)
    end
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
    if sync.IsGuildKeepCommunitySender and sync:IsGuildKeepCommunitySender(sender) then
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
function FA:Record(frontId, playerName, ts)
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
    if ts > previous then
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

local function GetFrontActivityDisplayName(front)
    if not front then return "?" end
    return front.dropdownLabel or front.mapName or front.id or "?"
end

-- Retourne tous les fronts. Les actifs sont tries par recence, puis les autres par nom.
function FA:GetActivityRows()
    local rows = {}
    local fronts = Overlord.Fronts
    if not fronts or not fronts.Order then return rows end
    local activity, actors = GetStores()
    local now = ActivityNow()
    if activity then PurgeAll(activity, actors, now) end

    for _, frontId in ipairs(GetActivitySourceOrder()) do
        local front = fronts:GetFront(frontId)
        if front then
            local lastActivityAt = activity and tonumber(activity[frontId]) or nil
            local ageSeconds = lastActivityAt and math.max(0, now - lastActivityAt) or nil
            local active = ageSeconds ~= nil and ageSeconds <= ACTIVITY_WINDOW
            rows[#rows + 1] = {
                frontId = frontId,
                label = GetFrontActivityDisplayName(front),
                lastActivityAt = active and lastActivityAt or nil,
                ageSeconds = active and ageSeconds or nil,
                active = active,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.active ~= b.active then return a.active end
        if a.active and a.lastActivityAt ~= b.lastActivityAt then
            return a.lastActivityAt > b.lastActivityAt
        end
        return a.label < b.label
    end)
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
                FA:RecordLocalByZoneRef(zoneId, myName)
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

    function Sync:AppendFrontActivityToSrQueue(queue)
        if type(queue) ~= "table" then return end
        local payload = FA:BuildSyncPayload()
        if payload then
            queue[#queue + 1] = { type = "FA", data = payload }
        end
    end
end
