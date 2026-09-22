-- ManualBountySync.lua - Sync contrats en or (PB/PK/PX/PP) et positions de cible (PM)
Overlord = Overlord or {}
Overlord.ManualBountySync = {}

local PB_DEDUP_SEC = 12
local PK_DEDUP_SEC = 10
local MK_DEDUP_SEC = 10
local PX_DEDUP_SEC = 10
local PP_DEDUP_SEC = 10
local PM_DEDUP_SEC = 3
local DEDUP_PURGE_INTERVAL = 15
local PENDING_TRANSITION_SEC = 600
local MAX_PENDING_CONTRACTS = 256
local MAX_PENDING_POSITIONS = 256
local EPHEMERAL_CACHE_MAX = 1024
local PENDING_POSITION_SEC = 120
local VICTIM_KILL_PROOF_SEC = 45
local CLAIM_PROOF_CLOCK_SEC = 10
local MAX_PAYLOAD_BYTES = 245
local PROTOCOL_VERSION = "2"
local MAX_CONTRACT_ID_BYTES = 64
local MAX_CLOCK_SKEW = 300
local PM_COMMUNITY_MAX = 8
local PM_COMMUNITY_MAX_LARGE = 4
local PM_COMMUNITY_DELAY = 0.35
local PM_COMMUNITY_DELAY_LARGE = 0.4
local CONTRACT_QUEUE_GAP_SEC = 0.5
local CONTRACT_QUEUE_MAX = 384
local CONTRACT_QUEUE_BULK_MAX = 320
local CATALOG_REQUEST_COOLDOWN_SEC = 30
-- 256 destinataires a 0,5 s, plus les reparations prioritaires : garder une
-- marge de cinq minutes pour que la fin d'une demande bornee reste recevable.
local CATALOG_REQUEST_TTL_SEC = 300
local CATALOG_REQUEST_DEDUP_SEC = 10
local CATALOG_SUBSCRIBER_SEC = 15 * 60
local CATALOG_MAX_SUBSCRIBERS = 128
local CATALOG_MAX_RECIPIENTS = 256
local CATALOG_MAX_CONTRACTS = 32
local CATALOG_BR_MAX_PER_REQUEST = 32
local CATALOG_RECENT_QUERY_MAX = CATALOG_MAX_SUBSCRIBERS * 4
local CATALOG_RECENT_CONTRACT_MAX = CATALOG_MAX_SUBSCRIBERS * CATALOG_MAX_CONTRACTS
local DIRECT_MAINTENANCE_INTERVAL_SEC = 60
local STATUS_TO_CODE = {
    open = "O",
    claimed = "C",
    approved = "A",
    paid = "P",
    cancelled = "X",
}
local CODE_TO_STATUS = {
    O = "open",
    C = "claimed",
    A = "approved",
    P = "paid",
    X = "cancelled",
}

local recentPB = {}
local recentPK = {}
local recentMK = {}
local recentPX = {}
local recentPP = {}
local recentPM = {}
local pendingTransitions = {}
local pendingPositions = {}
local recentVictimKillProofs = {}
local pendingPositionCount = 0
local lastDedupPurgeAt = 0
local contractPriorityQueue = {}
local contractBulkQueue = {}
local contractPriorityHead = 1
local contractBulkHead = 1
local contractQueueCount = 0
local contractQueueByKey = {}
local contractPumpScheduled = false
local contractPumpToken = 0
local recentCatalogRequests = {}
local recentCatalogRequestCount = 0
local recentCatalogRequestOrder = { nodes = {} }
local recentContractRequests = {}
local recentContractRequestCount = 0
local recentContractRequestOrder = { nodes = {} }
local contractRequestBudgets = {}
local lastCatalogRequestBySender = {}
local catalogSubscribers = {}
local catalogSubscriberCount = 0
local catalogSubscriberOrder = { nodes = {} }
local catalogRequestSequence = 0
local catalogRecipientCursor = 0
local lastCatalogRequestAt = -math.huge
local directMaintenanceCursor = 0
local lastDirectMaintenanceAt = -math.huge
local QueueContractWhisper
local DEDUP_PRUNE_QUOTA = 24
local ORDERED_PRUNE_QUOTA = 4
local dedupPruneSpecIndex = 1
local dedupPruneNextKey = nil

-- Ces caches n'ont de valeur que pendant leur fenetre de deduplication/preuve.
-- Une liste d'expiration par cache permet de garantir la borne a l'insertion sans
-- oublier une entree encore active, meme si la maintenance cadencee n'a pas tourne.
local ephemeralCacheState = {
    [recentPB] = { count = 0, ttl = PB_DEDUP_SEC, nodes = {} },
    [recentPK] = { count = 0, ttl = PK_DEDUP_SEC, nodes = {} },
    [recentMK] = { count = 0, ttl = MK_DEDUP_SEC, nodes = {} },
    [recentPX] = { count = 0, ttl = PX_DEDUP_SEC, nodes = {} },
    [recentPP] = { count = 0, ttl = PP_DEDUP_SEC, nodes = {} },
    [recentPM] = { count = 0, ttl = PM_DEDUP_SEC, nodes = {} },
    [recentVictimKillProofs] = {
        count = 0, ttl = VICTIM_KILL_PROOF_SEC, nodes = {},
    },
}

local function UnlinkEphemeralNode(state, key)
    local node = state and state.nodes and state.nodes[key]
    if not node then return nil end
    if node.prev then node.prev.next = node.next else state.head = node.next end
    if node.next then node.next.prev = node.prev else state.tail = node.prev end
    state.nodes[key] = nil
    node.prev, node.next = nil, nil
    return node
end

local function TouchEphemeralNode(state, key, expiresAt)
    local node = UnlinkEphemeralNode(state, key) or { key = key }
    node.expiresAt = expiresAt
    node.prev, node.next = state.tail, nil
    if state.tail then state.tail.next = node else state.head = node end
    state.tail = node
    state.nodes[key] = node
end

local function ForgetEphemeral(cache, key)
    if cache[key] == nil then return end
    cache[key] = nil
    local state = ephemeralCacheState[cache]
    if state then
        UnlinkEphemeralNode(state, key)
        state.count = math.max(0, state.count - 1)
    end
end

local function EnsureEphemeralCapacity(cache, key, now)
    local state = ephemeralCacheState[cache]
    if not state then return false end
    if cache[key] ~= nil or state.count < EPHEMERAL_CACHE_MAX then return true end
    local oldest = state.head
    if oldest and (tonumber(now) or GetTime()) >= (tonumber(oldest.expiresAt) or 0) then
        ForgetEphemeral(cache, oldest.key)
        return true
    end
    return false
end

local function CommitEphemeral(cache, key, value, now)
    local state = ephemeralCacheState[cache]
    if not state or key == nil then return false end
    if cache[key] == nil then state.count = state.count + 1 end
    cache[key] = value
    TouchEphemeralNode(state, key, (tonumber(now) or GetTime()) + state.ttl)
    return true
end

local function RememberEphemeral(cache, key, value, now)
    if not EnsureEphemeralCapacity(cache, key, now) then return false end
    return CommitEphemeral(cache, key, value, now)
end

local function Dbg(msg)
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFFFF8800[Overlord:ManualBounty]|r " .. tostring(msg))
    end
end

local function CampaignEpoch()
    if Overlord.GetCurrentCampaignWireEpoch then
        local e = Overlord:GetCurrentCampaignWireEpoch()
        if e and e > 0 then return e end
    end
    return OverlordDB and OverlordDB.lastResetTimestamp or 0
end

local function ServerNow()
    return GetServerTime()
end

local function NormalizePool(pool)
    pool = type(pool) == "string" and pool:lower() or ""
    if pool == "us" or pool == "fr" or pool == "de" or pool == "eu" then
        return pool
    end
    return nil
end

local function CurrentPool()
    if not Overlord.GetCurrentSavedVarsPool then return nil end
    return NormalizePool(Overlord:GetCurrentSavedVarsPool())
end

local function AcceptPool(pool)
    pool = NormalizePool(pool)
    local current = CurrentPool()
    return pool ~= nil and current ~= nil and pool == current
end

local function NormalizeWireTimestamp(value)
    local timestamp = tonumber(value)
    if not timestamp then return nil end
    timestamp = math.floor(timestamp)
    local now = ServerNow()
    if timestamp <= 0 or timestamp > now + MAX_CLOCK_SKEW then return nil end
    return timestamp
end

local function TimestampMatchesCampaign(timestamp, epoch)
    epoch = tonumber(epoch) or 0
    return epoch <= 0 or timestamp >= epoch - MAX_CLOCK_SKEW
end

local function IsValidContractId(id)
    return type(id) == "string"
        and #id > 0
        and #id <= MAX_CONTRACT_ID_BYTES
        and id:match("^MB[%w%-]+$") ~= nil
end

local function LimitPayload(payload)
    if not payload or #payload > MAX_PAYLOAD_BYTES then return nil end
    return payload
end

local function AcceptEpoch(epochStr)
    local remote = tonumber(epochStr) or 0
    local localEpoch = CampaignEpoch()
    if Overlord.CampaignEpochsMatch then
        return Overlord:CampaignEpochsMatch(remote, localEpoch)
    end
    if localEpoch <= 0 then return remote <= 0 end
    return remote == localEpoch
end

local function NameDedupKey(name)
    if not name or name == "" then return nil end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(name)
    end
    return (name:match("^(.-)%-") or name):lower()
end

local function SenderMatchesName(sender, name)
    if not sender or sender == "" or not name or name == "" then return false end
    if sender:sub(1, 5) == "BNet-" then return false end
    local sk = NameDedupKey(sender)
    local nk = NameDedupKey(name)
    return sk ~= nil and nk ~= nil and sk == nk
end

local function NamesMatch(a, b)
    if not a or not b or a == "" or b == "" then return false end
    local ak = NameDedupKey(a)
    local bk = NameDedupKey(b)
    return ak ~= nil and bk ~= nil and ak == bk
end

local function GetLocalFullName()
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName then
        return sync:GetPlayerFullName()
    end
    return Overlord.SafeGetUnitName and Overlord:SafeGetUnitName("player", true) or nil
end

local RequestUiRefresh

local function KillProofKey(killer, victim)
    local killerKey = NameDedupKey(killer)
    local victimKey = NameDedupKey(victim)
    if not killerKey or not victimKey then return nil end
    return killerKey .. "|" .. victimKey
end

local function GetVictimKillProof(killer, victim)
    local key = KillProofKey(killer, victim)
    local proof = key and recentVictimKillProofs[key]
    if type(proof) ~= "table" then return nil end
    if GetTime() - (tonumber(proof.receivedAt) or 0) > VICTIM_KILL_PROOF_SEC then
        ForgetEphemeral(recentVictimKillProofs, key)
        return nil
    end
    return proof
end

local function HasVictimKillProof(killer, victim)
    return GetVictimKillProof(killer, victim) ~= nil
end

local function RegisterVictimKillProof(killer, victim, receivedAt, killedAt)
    local proofKey = KillProofKey(killer, victim)
    if not proofKey or NamesMatch(killer, victim) then return false end
    killedAt = NormalizeWireTimestamp(killedAt)
    if not killedAt then return false end
    if not RememberEphemeral(recentVictimKillProofs, proofKey, {
        receivedAt = receivedAt or GetTime(),
        killedAt = killedAt,
    }, receivedAt) then return false end
    local changed = false
    for id, pending in pairs(pendingTransitions) do
        local claim = pending and pending.PK
        if claim and NamesMatch(claim.claimer, killer)
            and NamesMatch(claim.victim, victim) then
            changed = Overlord.ManualBountySync:ApplyPendingTransitions(id) or changed
        end
    end
    if changed then RequestUiRefresh() end
    return true
end

local function ShouldApplyClaim(contract, updatedAt, claimer)
    local incomingTs = tonumber(updatedAt) or 0
    local currentTs = tonumber(contract.updatedAt) or 0
    if contract.status == "open" then return true end
    if contract.status == "cancelled" then return false end
    if contract.status ~= "claimed" then return false end
    if incomingTs ~= currentTs then
        return incomingTs < currentTs
    end
    local incomingActor = (NameDedupKey(claimer) or claimer or ""):lower()
    local currentActor = (NameDedupKey(contract.claimer)
        or contract.claimer or ""):lower()
    return incomingActor < currentActor
end

local function ShouldApplyCancel(contract, updatedAt)
    return contract.status == "open" or contract.status == "claimed"
end

local function IsCompleteName(name)
    local sync = Overlord.Sync
    return sync and sync.HasCompleteContributorIdentity
        and sync:HasCompleteContributorIdentity(name) or false
end

local function PaymentIdentitiesValid(a, b)
    return IsCompleteName(a) and IsCompleteName(b)
end

local function IsLargeEvent()
    local sync = Overlord.Sync
    return sync and sync.IsLargeEvent and sync:IsLargeEvent()
end

RequestUiRefresh = function()
    if Overlord.ManualBountyUI and Overlord.ManualBountyUI.RequestRefresh then
        Overlord.ManualBountyUI:RequestRefresh()
    end
end

local function OrderedUnlink(order, node)
    if node.previous then
        node.previous.next = node.next
    else
        order.head = node.next
    end
    if node.next then
        node.next.previous = node.previous
    else
        order.tail = node.previous
    end
    node.previous, node.next = nil, nil
end

local function OrderedTouch(order, key)
    local node = order.nodes[key]
    if node then
        if order.tail == node then return node end
        OrderedUnlink(order, node)
    else
        node = { key = key }
        order.nodes[key] = node
    end
    node.previous = order.tail
    if order.tail then order.tail.next = node else order.head = node end
    order.tail = node
    return node
end

local function OrderedRemove(order, key)
    local node = order.nodes[key]
    if not node then return false end
    OrderedUnlink(order, node)
    order.nodes[key] = nil
    return true
end

local function RemoveRecentCatalogRequest(key)
    if recentCatalogRequests[key] == nil then
        OrderedRemove(recentCatalogRequestOrder, key)
        return false
    end
    recentCatalogRequests[key] = nil
    OrderedRemove(recentCatalogRequestOrder, key)
    recentCatalogRequestCount = math.max(0, recentCatalogRequestCount - 1)
    return true
end

local function RemoveRecentContractRequest(key)
    if recentContractRequests[key] == nil then
        OrderedRemove(recentContractRequestOrder, key)
        return false
    end
    recentContractRequests[key] = nil
    OrderedRemove(recentContractRequestOrder, key)
    recentContractRequestCount = math.max(0, recentContractRequestCount - 1)
    return true
end

local function RemoveCatalogSubscriber(key)
    if catalogSubscribers[key] == nil then
        OrderedRemove(catalogSubscriberOrder, key)
        return false
    end
    catalogSubscribers[key] = nil
    OrderedRemove(catalogSubscriberOrder, key)
    lastCatalogRequestBySender[key] = nil
    contractRequestBudgets[key] = nil
    catalogSubscriberCount = math.max(0, catalogSubscriberCount - 1)
    return true
end

local function PruneOrderedRequests(order, values, now, quota, remove)
    local processed = 0
    while processed < quota and order.head do
        local key = order.head.key
        local receivedAt = tonumber(values[key])
        if receivedAt and now - receivedAt <= CATALOG_REQUEST_TTL_SEC then break end
        remove(key)
        processed = processed + 1
    end
end

local dedupPruneSpecs = {
    { values = recentPB, ttl = PB_DEDUP_SEC * 4 },
    { values = recentPK, ttl = PK_DEDUP_SEC * 4 },
    { values = recentMK, ttl = MK_DEDUP_SEC * 4 },
    { values = recentPX, ttl = PX_DEDUP_SEC * 4 },
    { values = recentPP, ttl = PP_DEDUP_SEC * 4 },
    { values = recentPM, ttl = PM_DEDUP_SEC * 4 },
    { values = pendingTransitions, ttl = PENDING_TRANSITION_SEC, field = "receivedAt" },
    { values = pendingPositions, ttl = PENDING_POSITION_SEC,
        field = "receivedAt", decrementsPosition = true },
    { values = recentVictimKillProofs, ttl = VICTIM_KILL_PROOF_SEC,
        field = "receivedAt" },
    { values = lastCatalogRequestBySender, ttl = CATALOG_REQUEST_TTL_SEC },
    { values = contractRequestBudgets, ttl = CATALOG_REQUEST_TTL_SEC,
        field = "startedAt" },
}

local function PruneDedupTables(now)
    if now - lastDedupPurgeAt < DEDUP_PURGE_INTERVAL then return end
    lastDedupPurgeAt = now
    PruneOrderedRequests(recentCatalogRequestOrder, recentCatalogRequests,
        now, ORDERED_PRUNE_QUOTA, RemoveRecentCatalogRequest)
    PruneOrderedRequests(recentContractRequestOrder, recentContractRequests,
        now, ORDERED_PRUNE_QUOTA, RemoveRecentContractRequest)
    local subscriberWork = 0
    while subscriberWork < ORDERED_PRUNE_QUOTA and catalogSubscriberOrder.head do
        local key = catalogSubscriberOrder.head.key
        local subscriber = catalogSubscribers[key]
        if subscriber and tonumber(subscriber.expiresAt)
            and subscriber.expiresAt > now then break end
        RemoveCatalogSubscriber(key)
        subscriberWork = subscriberWork + 1
    end

    -- Les autres tables sont petites mais restent traitees avec un quota global
    -- strict. Aucun paquet entrant ne peut donc provoquer une purge proportionnelle
    -- a l'historique catalogue.
    local work, emptyAdvances = 0, 0
    while work < DEDUP_PRUNE_QUOTA and emptyAdvances < #dedupPruneSpecs do
        local spec = dedupPruneSpecs[dedupPruneSpecIndex]
        local values = spec.values
        if dedupPruneNextKey and values[dedupPruneNextKey] == nil then
            dedupPruneNextKey = nil
        end
        local key = dedupPruneNextKey or next(values)
        if not key then
            dedupPruneSpecIndex = (dedupPruneSpecIndex % #dedupPruneSpecs) + 1
            dedupPruneNextKey = nil
            emptyAdvances = emptyAdvances + 1
        else
            local value = values[key]
            local nextKey = next(values, key)
            local receivedAt = spec.field and type(value) == "table"
                and tonumber(value[spec.field]) or tonumber(value)
            if not receivedAt or now - receivedAt > spec.ttl then
                if ephemeralCacheState[values] then
                    ForgetEphemeral(values, key)
                else
                    values[key] = nil
                end
                if spec.decrementsPosition then
                    pendingPositionCount = math.max(0, pendingPositionCount - 1)
                end
            end
            work = work + 1
            emptyAdvances = 0
            if nextKey then
                dedupPruneNextKey = nextKey
            else
                dedupPruneSpecIndex = (dedupPruneSpecIndex % #dedupPruneSpecs) + 1
                dedupPruneNextKey = nil
            end
        end
    end
end

local function RememberPendingPosition(name, mapX, mapY, mapID, sentAt, receivedAt)
    local key = NameDedupKey(name)
    if not key then return end
    if not pendingPositions[key] then
        if pendingPositionCount >= MAX_PENDING_POSITIONS then
            local evictedKey = next(pendingPositions)
            if evictedKey then
                pendingPositions[evictedKey] = nil
                pendingPositionCount = pendingPositionCount - 1
            end
        end
        pendingPositionCount = pendingPositionCount + 1
    end
    local previous = pendingPositions[key]
    if previous and (tonumber(previous.sentAt) or 0) > sentAt then return end
    pendingPositions[key] = {
        name = name,
        mapX = mapX,
        mapY = mapY,
        mapID = mapID,
        sentAt = sentAt,
        receivedAt = receivedAt,
    }
end

local function ApplyPendingPosition(name)
    local key = NameDedupKey(name)
    local pending = key and pendingPositions[key]
    if not pending then return false end
    if math.abs(ServerNow() - (tonumber(pending.sentAt) or 0)) > PENDING_POSITION_SEC then
        pendingPositions[key] = nil
        pendingPositionCount = math.max(0, pendingPositionCount - 1)
        return false
    end
    local mb = Overlord.ManualBounty
    local applied = mb and mb:ApplyTargetPosition(
        pending.name, pending.mapX, pending.mapY, pending.mapID, pending.sentAt) or false
    if applied then
        pendingPositions[key] = nil
        pendingPositionCount = math.max(0, pendingPositionCount - 1)
    end
    return applied
end

local function EmitAll(msgType, payload, critical, communityWide)
    local sync = Overlord.Sync
    if not sync or not payload or payload == "" then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
    if Overlord.CommunityModeEnabled == false and Overlord.BetaNetwork then
        return Overlord.BetaNetwork:Broadcast(msgType, payload)
    end
    sync:Send(msgType, payload)
    if sync.SendToChannel and IsInGroup and IsInGroup() then
        sync:SendToChannel(msgType, payload, critical == true)
    end
    if communityWide and sync.BroadcastGeneralToFactionCommunity then
        sync:BroadcastGeneralToFactionCommunity(msgType, payload, 8, 0.22, false)
    end
    if communityWide and sync.BroadcastToEnemyFactionCommunity then
        sync:BroadcastToEnemyFactionCommunity(msgType, payload, 8, 0.22, false)
    end
end

local function EmitPosition(payload)
    local sync = Overlord.Sync
    if not sync or not payload or payload == "" then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
    local isLarge = IsLargeEvent()
    local maxMembers = isLarge and PM_COMMUNITY_MAX_LARGE or PM_COMMUNITY_MAX
    local delay = isLarge and PM_COMMUNITY_DELAY_LARGE or PM_COMMUNITY_DELAY
    if IsInGroup() or IsInRaid() then
        sync:Send("PM", payload)
    end
    if sync.SendToChannel then
        sync:SendToChannel("PM", payload, false)
    end
    if sync.BroadcastGeneralToFactionCommunity then
        sync:BroadcastGeneralToFactionCommunity("PM", payload, maxMembers, delay, false)
    end
    if sync.BroadcastToEnemyFactionCommunity then
        sync:BroadcastToEnemyFactionCommunity("PM", payload, maxMembers, delay, false)
    end
end

local function EmitDirect(msgType, payload, names)
    local sync = Overlord.Sync
    if not sync or not QueueContractWhisper or type(names) ~= "table" then return end
    local seen = {}
    local subject = payload and payload:match("^[^:]*:([^:]+)") or payload
    if msgType == "MK" then subject = payload end
    for i = 1, #names do
        local name = names[i]
        local key = NameDedupKey(name)
        if key and not seen[key] and not NamesMatch(name, GetLocalFullName()) then
            seen[key] = true
            QueueContractWhisper(msgType, payload, name, true,
                table.concat({ msgType, key, tostring(subject or "") }, "|"))
        end
    end
end

local function NormalizeAmount(copper)
    local n = math.floor(tonumber(copper) or 0)
    local mb = Overlord.ManualBounty
    if not mb then return nil end
    if n < mb.MIN_COPPER or n > mb.MAX_COPPER then return nil end
    return n
end

function Overlord.ManualBountySync:CanBroadcast()
    local sync = Overlord.Sync
    if not sync or Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        return false
    end
    if IsInGroup and IsInGroup() then return true end
    if Overlord.CommunityModeEnabled == false and Overlord.BetaNetwork
        and #Overlord.BetaNetwork:GetPeers() > 0 then return true end
    if sync.HasCommunityClub and sync:HasCommunityClub() then return true end
    return sync.GetChannelId and sync:GetChannelId() ~= nil
end

function Overlord.ManualBountySync:BuildPBPayload(contract)
    if not contract or not IsValidContractId(contract.id) then return nil end
    local statusCode = STATUS_TO_CODE[contract.status]
    if not statusCode then return nil end
    local pool = NormalizePool(contract.pool) or CurrentPool()
    if not pool then return nil end
    local createdAt = NormalizeWireTimestamp(contract.createdAt)
    local updatedAt = NormalizeWireTimestamp(contract.updatedAt)
    if not createdAt or not updatedAt or createdAt > updatedAt then return nil end
    local payload = string.format("%s:%s:%s:%s:%s:%d:%s:%s:%d:%s:%d:%d:%d:%s:%s",
        PROTOCOL_VERSION,
        contract.id,
        contract.poster or "",
        contract.target or "",
        contract.targetRace or "",
        tonumber(contract.targetRaceSex) or 0,
        contract.targetGuild or "",
        contract.targetFaction or "",
        contract.amountCopper or 0,
        pool,
        contract.epoch or CampaignEpoch(),
        createdAt,
        updatedAt,
        statusCode,
        contract.claimer or "")
    return LimitPayload(payload)
end

local function ContractQueuePaused()
    return Overlord.InstanceSuspended or (IsInInstance and IsInInstance())
end

local ScheduleContractPump

local function FinishContractQueueItem(item)
    if not item or item.done then return end
    item.done = true
    contractQueueCount = math.max(0, contractQueueCount - 1)
    if item.key and contractQueueByKey[item.key] == item then
        contractQueueByKey[item.key] = nil
    end
end

local function PeekContractQueue(queue, head)
    while head <= #queue do
        local item = queue[head]
        if item and not item.done then return item, head end
        head = head + 1
    end
    return nil, head
end

local function EvictOldestBulkContractItem()
    for i = contractBulkHead, #contractBulkQueue do
        local item = contractBulkQueue[i]
        if item and not item.done and not item.priority then
            FinishContractQueueItem(item)
            return true
        end
    end
    return false
end

local function CompactContractQueuesIfNeeded()
    if contractPriorityHead > CONTRACT_QUEUE_MAX
        or #contractPriorityQueue > CONTRACT_QUEUE_MAX * 2 then
        local compact = {}
        for i = contractPriorityHead, #contractPriorityQueue do
            local item = contractPriorityQueue[i]
            if item and not item.done then compact[#compact + 1] = item end
        end
        contractPriorityQueue = compact
        contractPriorityHead = 1
    end
    if contractBulkHead > CONTRACT_QUEUE_MAX
        or #contractBulkQueue > CONTRACT_QUEUE_MAX * 2 then
        local compact = {}
        for i = contractBulkHead, #contractBulkQueue do
            local item = contractBulkQueue[i]
            if item and not item.done then compact[#compact + 1] = item end
        end
        contractBulkQueue = compact
        contractBulkHead = 1
    end
end

local function PumpContractQueue()
    contractPumpScheduled = false
    -- Ne jamais avancer la tete pendant une instance : le message reste exactement
    -- a sa place et ResumeContractQueue le reprendra a la sortie.
    if ContractQueuePaused() or contractQueueCount == 0 then return end
    local item
    item, contractPriorityHead = PeekContractQueue(
        contractPriorityQueue, contractPriorityHead)
    if not item then
        item, contractBulkHead = PeekContractQueue(contractBulkQueue, contractBulkHead)
    end
    if not item then
        contractPriorityQueue = {}
        contractBulkQueue = {}
        contractPriorityHead = 1
        contractBulkHead = 1
        contractQueueCount = 0
        wipe(contractQueueByKey)
        return
    end

    local sync = Overlord.Sync
    if not sync or not sync.SendWhisper then return end
    local sent = sync:SendWhisper(item.msgType, item.payload, item.target)
    if sent ~= true and Overlord.CommunityModeEnabled == false then
        item.firstFailureAt = item.firstFailureAt or GetTime()
        if GetTime() - item.firstFailureAt < 120 then
            ScheduleContractPump(CONTRACT_QUEUE_GAP_SEC)
            return
        end
    end
    -- Les cibles et la taille ont deja ete validees a l'entree. Un false residuel
    -- ne doit pas bloquer indefiniment les etats critiques places derriere.
    FinishContractQueueItem(item)
    if sent == false then
        Dbg("drop " .. tostring(item.msgType) .. " -> " .. tostring(item.target))
    end
    CompactContractQueuesIfNeeded()

    if contractQueueCount > 0 then
        ScheduleContractPump(CONTRACT_QUEUE_GAP_SEC)
    else
        contractPriorityQueue = {}
        contractBulkQueue = {}
        contractPriorityHead = 1
        contractBulkHead = 1
    end
end

ScheduleContractPump = function(delaySec)
    if contractPumpScheduled or contractQueueCount == 0 or ContractQueuePaused() then
        return
    end
    contractPumpScheduled = true
    local token = contractPumpToken
    C_Timer.After(math.max(0, tonumber(delaySec) or 0), function()
        if token ~= contractPumpToken then return end
        PumpContractQueue()
    end)
end

QueueContractWhisper = function(msgType, payload, target, priority, coalesceKey)
    local sync = Overlord.Sync
    if not sync or not sync.SendWhisper or not sync.IsValidWhisperTarget
        or type(msgType) ~= "string" or msgType == ""
        or type(payload) ~= "string" or payload == ""
        or type(target) ~= "string" or not sync:IsValidWhisperTarget(target)
        or #msgType + #payload + 1 > 255 then
        return false
    end
    local targetKey = NameDedupKey(target) or target:lower()
    local key = coalesceKey or table.concat({ msgType, targetKey, payload }, "|")
    local existing = contractQueueByKey[key]
    if existing and not existing.done then
        existing.payload = payload
        existing.target = target
        if priority and not existing.priority then
            existing.priority = true
            contractPriorityQueue[#contractPriorityQueue + 1] = existing
        end
        ScheduleContractPump(0)
        return true
    end

    if not priority and contractQueueCount >= CONTRACT_QUEUE_BULK_MAX then return false end
    if contractQueueCount >= CONTRACT_QUEUE_MAX and not EvictOldestBulkContractItem() then
        return false
    end
    local item = {
        msgType = msgType,
        payload = payload,
        target = target,
        key = key,
        priority = priority == true,
    }
    contractQueueByKey[key] = item
    contractQueueCount = contractQueueCount + 1
    if item.priority then
        contractPriorityQueue[#contractPriorityQueue + 1] = item
    else
        contractBulkQueue[#contractBulkQueue + 1] = item
    end
    ScheduleContractPump(0)
    return true
end

local function RegisterCatalogSubscriber(name, now)
    local key = NameDedupKey(name)
    if not key then return end
    local subscriber = catalogSubscribers[key]
    if not subscriber and catalogSubscriberCount >= CATALOG_MAX_SUBSCRIBERS then
        local oldestKey = catalogSubscriberOrder.head
            and catalogSubscriberOrder.head.key
        if oldestKey then
            -- Les cles de requete ont leur propre LRU/TTL borne. Les balayer par
            -- prefixe ici recréait precisement le pic O(4096) sur un paquet BQ.
            RemoveCatalogSubscriber(oldestKey)
        end
    end
    if not subscriber then catalogSubscriberCount = catalogSubscriberCount + 1 end
    catalogSubscribers[key] = {
        name = name,
        expiresAt = now + CATALOG_SUBSCRIBER_SEC,
    }
    OrderedTouch(catalogSubscriberOrder, key)
end

local function RememberCatalogRequest(key, now)
    local previous = recentCatalogRequests[key]
    if previous and now - previous <= CATALOG_REQUEST_TTL_SEC then return false end
    if previous then RemoveRecentCatalogRequest(key) end
    if recentCatalogRequestCount >= CATALOG_RECENT_QUERY_MAX then
        local oldestKey = recentCatalogRequestOrder.head
            and recentCatalogRequestOrder.head.key
        if oldestKey then RemoveRecentCatalogRequest(oldestKey) end
    end
    recentCatalogRequests[key] = now
    OrderedTouch(recentCatalogRequestOrder, key)
    recentCatalogRequestCount = recentCatalogRequestCount + 1
    return true
end

local function RememberContractRequest(key, now)
    local previous = recentContractRequests[key]
    if previous and now - previous <= CATALOG_REQUEST_DEDUP_SEC then return false end
    if not previous and recentContractRequestCount >= CATALOG_RECENT_CONTRACT_MAX then
        local oldestKey = recentContractRequestOrder.head
            and recentContractRequestOrder.head.key
        if oldestKey then RemoveRecentContractRequest(oldestKey) end
    end
    if not recentContractRequests[key] then
        recentContractRequestCount = recentContractRequestCount + 1
    end
    recentContractRequests[key] = now
    OrderedTouch(recentContractRequestOrder, key)
    return true
end

local function PrepareContractRequestBudget(senderKey, requestId, now)
    local budget = contractRequestBudgets[senderKey]
    if budget and budget.requestId == requestId then
        if (tonumber(budget.count) or 0) >= CATALOG_BR_MAX_PER_REQUEST then return nil end
        return budget
    end
    if budget and now - (tonumber(budget.startedAt) or 0)
        < CATALOG_REQUEST_COOLDOWN_SEC then return nil end
    budget = { requestId = requestId, startedAt = now, count = 0 }
    contractRequestBudgets[senderKey] = budget
    return budget
end

local function QueuePBRecipients(contract, names, priority, includeSubscribers)
    if not contract or not contract.id then return 0 end
    local payload = Overlord.ManualBountySync:BuildPBPayload(contract)
    if not payload then return 0 end
    local queued, seen = 0, {}
    local me = GetLocalFullName()
    local function Add(name)
        local key = NameDedupKey(name)
        if not key or seen[key] or NamesMatch(name, me) then return end
        seen[key] = true
        if QueueContractWhisper("PB", payload, name, priority == true,
            table.concat({ "PB", key, contract.id }, "|")) then
            queued = queued + 1
        end
    end
    for i = 1, #(names or {}) do Add(names[i]) end
    if includeSubscribers then
        local now = GetTime()
        for key, subscriber in pairs(catalogSubscribers) do
            if subscriber.expiresAt and subscriber.expiresAt > now then
                Add(subscriber.name)
            else
                RemoveCatalogSubscriber(key)
            end
        end
    end
    return queued
end

local function IsValidRequestId(requestId)
    return type(requestId) == "string" and #requestId > 0 and #requestId <= 32
        and requestId:match("^[%w%-]+$") ~= nil
end

local function IsTrustedCatalogRequester(sender)
    local sync = Overlord.Sync
    if not sync then return false end
    if sync.IsOnlineCommunitySender then
        return sync:IsOnlineCommunitySender(sender)
    end
    return sync.IsGuildKeepCommunitySender
        and sync:IsGuildKeepCommunitySender(sender) or false
end

local function NextCatalogRequestId()
    catalogRequestSequence = (catalogRequestSequence % 999999) + 1
    return string.format("%d-%d", math.floor(GetTime() * 1000), catalogRequestSequence)
end

function Overlord.ManualBountySync:BuildBQPayload(requester, requestId, sentAt)
    local pool = CurrentPool()
    sentAt = NormalizeWireTimestamp(sentAt)
    if not requester or requester == "" or not pool or not IsValidRequestId(requestId)
        or not sentAt then return nil end
    return LimitPayload(string.format("%s:%s:%s:%d:%s:%d",
        PROTOCOL_VERSION, requester, pool, CampaignEpoch(), requestId, sentAt))
end

function Overlord.ManualBountySync:BuildBRPayload(contractId, requester, requestId, sentAt)
    local pool = CurrentPool()
    sentAt = NormalizeWireTimestamp(sentAt)
    if not IsValidContractId(contractId) or not requester or requester == ""
        or not pool or not IsValidRequestId(requestId) or not sentAt then return nil end
    return LimitPayload(string.format("%s:%s:%s:%s:%d:%s:%d",
        PROTOCOL_VERSION, contractId, requester, pool, CampaignEpoch(), requestId, sentAt))
end

function Overlord.ManualBountySync:ResumeContractQueue()
    ScheduleContractPump(0)
end

function Overlord.ManualBountySync:RequestCatalogSync()
    if ContractQueuePaused() then return false end
    local now = GetTime()
    PruneDedupTables(now)
    if now - lastCatalogRequestAt < CATALOG_REQUEST_COOLDOWN_SEC then return false end
    local sync = Overlord.Sync
    local mb = Overlord.ManualBounty
    local requester = GetLocalFullName()
    if not sync or not mb or not requester or requester == "" then return false end

    local requestId = NextCatalogRequestId()
    local sentAt = ServerNow()
    local payload = self:BuildBQPayload(requester, requestId, sentAt)
    if not payload then return false end
    lastCatalogRequestAt = now

    -- Les contrats deja connus sont places avant les requetes de decouverte, un par
    -- identifiant. Ils restent en trafic routine afin qu'un etat de vie critique saute devant.
    if mb.GetKnownContractsForSync then
        for _, contract in ipairs(mb:GetKnownContractsForSync(CATALOG_MAX_CONTRACTS)) do
            local refreshPayload = self:BuildBRPayload(
                contract.id, requester, requestId, sentAt)
            local posterKey = NameDedupKey(contract.poster)
            if refreshPayload and posterKey then
                QueueContractWhisper("BR", refreshPayload, contract.poster, false,
                    table.concat({ "BR", posterKey, contract.id }, "|"))
            end
        end
    end

    -- Chemins locaux/groupes immediats, puis fan-out communaute dans la file dediee.
    EmitAll("BQ", payload, false, false)
    local online = sync.GetOnlineCommunityMembers
        and sync:GetOnlineCommunityMembers(false, 15) or {}
    local count = #online
    if count > 0 then
        local start = (catalogRecipientCursor % count) + 1
        local accepted, scanned, seen = 0, 0, {}
        while scanned < count and accepted < CATALOG_MAX_RECIPIENTS do
            local index = ((start + scanned - 1) % count) + 1
            local memberName = online[index]
            local key = NameDedupKey(memberName)
            if key and not seen[key] and not NamesMatch(memberName, requester) then
                seen[key] = true
                if QueueContractWhisper("BQ", payload, memberName, false,
                    "BQ|" .. key) then
                    accepted = accepted + 1
                end
            end
            scanned = scanned + 1
        end
        catalogRecipientCursor = (catalogRecipientCursor + math.max(1, scanned)) % count
    end
    return true
end

function Overlord.ManualBountySync:OnReceiveBQ(payload, sender)
    if not payload or payload == "" then return end
    local version, requester, pool, epochStr, requestId, sentAtStr =
        strsplit(":", payload, 6)
    if version ~= PROTOCOL_VERSION or not SenderMatchesName(sender, requester)
        or not AcceptPool(pool) or not AcceptEpoch(epochStr)
        or not IsValidRequestId(requestId) then return end
    local sentAt = NormalizeWireTimestamp(sentAtStr)
    if not sentAt or math.abs(ServerNow() - sentAt) > CATALOG_REQUEST_TTL_SEC
        or not IsTrustedCatalogRequester(sender) then return end

    local now = GetTime()
    local senderKey = NameDedupKey(sender)
    if not senderKey then return end
    PruneDedupTables(now)
    local dedupKey = senderKey .. "|" .. requestId
    local previous = lastCatalogRequestBySender[senderKey]
    if previous and now - previous < CATALOG_REQUEST_COOLDOWN_SEC then return end
    if not RememberCatalogRequest(dedupKey, now) then return end
    lastCatalogRequestBySender[senderKey] = now
    RegisterCatalogSubscriber(sender, now)

    local mb = Overlord.ManualBounty
    if not mb or not mb.GetOwnedActiveContractsForSync then return end
    for _, contract in ipairs(mb:GetOwnedActiveContractsForSync(CATALOG_MAX_CONTRACTS)) do
        QueuePBRecipients(contract, { sender }, false, false)
    end
end

function Overlord.ManualBountySync:OnReceiveBR(payload, sender)
    if not payload or payload == "" then return end
    local version, contractId, requester, pool, epochStr, requestId, sentAtStr =
        strsplit(":", payload, 7)
    if version ~= PROTOCOL_VERSION or not IsValidContractId(contractId)
        or not SenderMatchesName(sender, requester) or not AcceptPool(pool)
        or not AcceptEpoch(epochStr) or not IsValidRequestId(requestId) then return end
    local sentAt = NormalizeWireTimestamp(sentAtStr)
    if not sentAt or math.abs(ServerNow() - sentAt) > CATALOG_REQUEST_TTL_SEC
        or not IsTrustedCatalogRequester(sender) then return end

    local mb = Overlord.ManualBounty
    local contract = mb and mb:GetContract(contractId)
    if not contract or not NamesMatch(contract.poster, GetLocalFullName())
        or not AcceptPool(contract.pool)
        or not AcceptEpoch(tostring(contract.epoch or 0)) then return end
    local now = GetTime()
    local senderKey = NameDedupKey(sender)
    if not senderKey then return end
    PruneDedupTables(now)
    local budget = PrepareContractRequestBudget(senderKey, requestId, now)
    if not budget then return end
    local dedupKey = senderKey .. "|" .. contractId
    if not RememberContractRequest(dedupKey, now) then return end
    budget.count = (tonumber(budget.count) or 0) + 1
    RegisterCatalogSubscriber(sender, now)
    QueuePBRecipients(contract, { sender }, false, false)
end

-- Filet de reconnexion cible/gagnant : un contrat par minute en tourniquet. Aucun
-- membre sans lien avec le contrat n'est contacte et aucun tri global n'est effectue.
function Overlord.ManualBountySync:QueueDirectContractMaintenance(maxContracts, force)
    self:ResumeContractQueue()
    local now = GetTime()
    if not force and now - lastDirectMaintenanceAt < DIRECT_MAINTENANCE_INTERVAL_SEC then
        return 0
    end
    lastDirectMaintenanceAt = now
    local mb = Overlord.ManualBounty
    if not mb or not mb.GetOwnedActiveContractsForSync then return 0 end
    local owned = mb:GetOwnedActiveContractsForSync(CATALOG_MAX_CONTRACTS)
    if #owned == 0 then
        directMaintenanceCursor = 0
        return 0
    end
    local limit = math.min(2, math.max(1, math.floor(tonumber(maxContracts) or 1)))
    local queued = 0
    local start = (directMaintenanceCursor % #owned) + 1
    for offset = 0, math.min(limit, #owned) - 1 do
        local index = ((start + offset - 1) % #owned) + 1
        local contract = owned[index]
        queued = queued + QueuePBRecipients(
            contract, { contract.target, contract.claimer }, false, false)
    end
    directMaintenanceCursor = (directMaintenanceCursor + math.min(limit, #owned)) % #owned
    return queued
end

function Overlord.ManualBountySync:BuildPKPayload(id, claimer, victim, pool, epoch, updatedAt)
    if not IsValidContractId(id) then return nil end
    pool = NormalizePool(pool) or CurrentPool()
    updatedAt = NormalizeWireTimestamp(updatedAt)
    if not pool or not updatedAt then return nil end
    return LimitPayload(string.format("%s:%s:%s:%s:%s:%d:%d",
        PROTOCOL_VERSION, id, claimer or "", victim or "", pool,
        tonumber(epoch) or CampaignEpoch(), updatedAt))
end

function Overlord.ManualBountySync:BuildMKPayload(killer, victim, pool, epoch, killedAt)
    pool = NormalizePool(pool) or CurrentPool()
    killedAt = NormalizeWireTimestamp(killedAt)
    if not pool or not killedAt or not killer or killer == ""
        or not victim or victim == "" or NamesMatch(killer, victim) then
        return nil
    end
    return LimitPayload(string.format("%s:%s:%s:%s:%d:%d",
        PROTOCOL_VERSION, killer, victim, pool,
        tonumber(epoch) or CampaignEpoch(), killedAt))
end

function Overlord.ManualBountySync:BuildPXPayload(id, poster, pool, epoch, updatedAt)
    if not IsValidContractId(id) then return nil end
    pool = NormalizePool(pool) or CurrentPool()
    updatedAt = NormalizeWireTimestamp(updatedAt)
    if not pool or not updatedAt then return nil end
    return LimitPayload(string.format("%s:%s:%s:%s:%d:%d",
        PROTOCOL_VERSION, id, poster or "", pool,
        tonumber(epoch) or CampaignEpoch(), updatedAt))
end

function Overlord.ManualBountySync:BuildPPPayload(
    id, poster, claimer, victim, pool, epoch, updatedAt)
    if not IsValidContractId(id) then return nil end
    pool = NormalizePool(pool) or CurrentPool()
    updatedAt = NormalizeWireTimestamp(updatedAt)
    if not pool or not updatedAt then return nil end
    return LimitPayload(string.format("%s:%s:%s:%s:%s:%s:%d:%d",
        PROTOCOL_VERSION, id, poster or "", claimer or "", victim or "", pool,
        tonumber(epoch) or CampaignEpoch(), updatedAt))
end

function Overlord.ManualBountySync:BuildPMPayload(name, mapX, mapY, mapID, pool, sentAt)
    local xC = math.floor((tonumber(mapX) or 0) * 100 + 0.5)
    local yC = math.floor((tonumber(mapY) or 0) * 100 + 0.5)
    pool = NormalizePool(pool) or CurrentPool()
    sentAt = NormalizeWireTimestamp(sentAt)
    if not pool or not sentAt then return nil end
    return LimitPayload(string.format("%s:%s:%d:%d:%d:%d:%s:%d",
        PROTOCOL_VERSION, name or "", xC, yC, tonumber(mapID) or 0,
        sentAt, pool, CampaignEpoch()))
end

function Overlord.ManualBountySync:BroadcastPost(contract)
    local payload = self:BuildPBPayload(contract)
    if not payload then return end
    EmitAll("PB", payload, true, false)
    QueuePBRecipients(contract, { contract.target, contract.claimer }, true, true)
    Dbg("PB " .. tostring(contract.id))
end

function Overlord.ManualBountySync:BroadcastClaim(id, claimer, victim)
    local contract = Overlord.ManualBounty and Overlord.ManualBounty:GetContract(id)
    local payload = self:BuildPKPayload(
        id, claimer, victim,
        contract and contract.pool,
        contract and contract.epoch,
        contract and contract.updatedAt)
    if not payload then return end
    EmitAll("PK", payload, true, false)
    if contract then
        EmitDirect("PK", payload, { contract.poster, contract.target })
    end
    Dbg("PK " .. tostring(id))
end

-- Deuxieme attestation d'un contrat reclame : la victime emet cette preuve depuis
-- PLAYER_DEAD. Un PK du seul chasseur ne peut ainsi plus fermer une prime publique.
function Overlord.ManualBountySync:BroadcastDeathProof(killer, victim, posters)
    local payload = self:BuildMKPayload(
        killer, victim, CurrentPool(), CampaignEpoch(), ServerNow())
    if not payload then return end
    -- CHAT_MSG_ADDON ignore nos propres paquets : enregistrer aussi la preuve locale
    -- afin que le client de la victime puisse appliquer un PK arrive avant/apres sa mort.
    RegisterVictimKillProof(killer, victim, GetTime(), ServerNow())
    EmitAll("MK", payload, true, false)
    EmitDirect("MK", payload, posters or {})
    Dbg("MK " .. tostring(killer) .. " -> " .. tostring(victim))
end

function Overlord.ManualBountySync:BroadcastCancel(contract)
    local payload = self:BuildPXPayload(
        contract.id, contract.poster, contract.pool, contract.epoch, contract.updatedAt)
    if not payload then return end
    EmitAll("PX", payload, true, false)
    EmitDirect("PX", payload, { contract.target })
    QueuePBRecipients(contract, { contract.target, contract.claimer }, true, true)
    Dbg("PX " .. tostring(contract.id))
end

function Overlord.ManualBountySync:BroadcastPaid(contract)
    local payload = self:BuildPPPayload(
        contract.id, contract.poster, contract.claimer, contract.target,
        contract.pool, contract.epoch, contract.updatedAt)
    if not payload then return end
    EmitAll("PP", payload, true, false)
    EmitDirect("PP", payload, { contract.claimer, contract.target })
    QueuePBRecipients(contract, { contract.claimer, contract.target }, true, true)
    Dbg("PP " .. tostring(contract.id))
end

function Overlord.ManualBountySync:BroadcastPosition(name, mapX, mapY, mapID, pool, sentAt)
    local payload = self:BuildPMPayload(name, mapX, mapY, mapID, pool, sentAt)
    if not payload then return end
    EmitPosition(payload)
end

function Overlord.ManualBountySync:OnReceivePB(payload, sender)
    if not payload or payload == "" then return end
    local version, id, poster, target, race, raceSexStr, guild, faction, amountStr,
        pool, epochStr, createdAtStr, updatedAtStr, statusCode, claimer =
        strsplit(":", payload, 15)
    if version ~= PROTOCOL_VERSION or not IsValidContractId(id)
        or not poster or poster == "" then return end
    if not SenderMatchesName(sender, poster) then return end
    if not AcceptPool(pool) then return end
    if not AcceptEpoch(epochStr) then return end
    local createdAt = NormalizeWireTimestamp(createdAtStr)
    local updatedAt = NormalizeWireTimestamp(updatedAtStr)
    if not createdAt or not updatedAt or createdAt > updatedAt
        or not TimestampMatchesCampaign(createdAt, epochStr)
        or not TimestampMatchesCampaign(updatedAt, epochStr) then
        return
    end
    local amount = NormalizeAmount(amountStr)
    if not amount then return end
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName then
        if not sync:AcceptSyncedContributorName(target) then return end
        if not sync:AcceptSyncedContributorName(poster) then return end
    end
    local mb = Overlord.ManualBounty
    if not mb then return end
    local raceSex = math.floor(tonumber(raceSexStr) or 0)
    if raceSex ~= 2 and raceSex ~= 3 then raceSex = 0 end
    local hasRace = race ~= ""
    if hasRace and sync and sync.NormalizeRaceFileToken then
        race = sync:NormalizeRaceFileToken(race)
    end
    if hasRace and (not race or race == "") then return end
    if guild ~= "" and sync and sync.IsValidGuildSyncToken
        and not sync:IsValidGuildSyncToken(guild) then
        return
    end
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    local posterRealm, targetRealm = "", ""
    if not IsCompleteName(poster) or not IsCompleteName(target) then return end
    local incomingStatus = CODE_TO_STATUS[statusCode]
    if not incomingStatus then return end
    if (incomingStatus == "claimed" or incomingStatus == "approved"
        or incomingStatus == "paid")
        and (not claimer or claimer == "") then
        return
    end
    if (incomingStatus == "claimed" or incomingStatus == "approved"
        or incomingStatus == "paid")
        and sync and sync.AcceptSyncedContributorName
        and not sync:AcceptSyncedContributorName(claimer) then
        return
    end
    local existing = mb:GetContract(id)
    if existing then
        if not NamesMatch(existing.poster, poster)
            or not NamesMatch(existing.target, target)
            or tonumber(existing.amountCopper) ~= amount
            or NormalizePool(existing.pool) ~= pool then
            return
        end
    end
    local now = GetTime()
    PruneDedupTables(now)
    local pbDedupKey = id .. "|" .. tostring(statusCode) .. "|" .. tostring(updatedAtStr)
    if recentPB[pbDedupKey] and (now - recentPB[pbDedupKey]) < PB_DEDUP_SEC then return end
    if not RememberEphemeral(recentPB, pbDedupKey, now, now) then return end
    local finalUpdatedAt = updatedAt
    local contract = {
        id = id,
        poster = poster,
        posterRealm = posterRealm,
        target = target or "",
        targetRealm = targetRealm,
        targetRace = race or "",
        targetRaceSex = raceSex,
        targetGuild = guild or "",
        targetFaction = faction,
        amountCopper = amount,
        status = incomingStatus,
        claimer = claimer or "",
        createdAt = createdAt,
        updatedAt = finalUpdatedAt,
        epoch = tonumber(epochStr) or 0,
        pool = pool,
        versionActor = incomingStatus == "claimed" and claimer or poster,
    }
    local changed = false
    if not existing then
        changed = mb:ApplyRemoteContract(contract, false)
        existing = mb:GetContract(id)
    elseif incomingStatus == "claimed" then
        -- Le PB est signe par le poseur : il peut relayer une reclamation deja
        -- validee, notamment lors d'un rattrapage apres expiration de la preuve MK.
        changed = self:ApplyClaimTransition(
            existing, claimer, target, contract.epoch, finalUpdatedAt, true) or changed
    elseif incomingStatus == "approved" then
        changed = self:ApplyApprovedSnapshotFromPB(
            existing, poster, claimer, target, contract.epoch, finalUpdatedAt) or changed
    elseif incomingStatus == "paid" then
        changed = self:ApplyPaidSnapshotFromPB(
            existing, poster, claimer, target, contract.epoch, finalUpdatedAt) or changed
    elseif incomingStatus == "cancelled" then
        changed = self:ApplyCancelTransition(
            existing, poster, contract.epoch, finalUpdatedAt) or changed
    end
    if existing then
        changed = self:ApplyPendingTransitions(id) or changed
    end
    ApplyPendingPosition(target)
    if changed then
        RequestUiRefresh()
    end
end

function Overlord.ManualBountySync:ApplyClaimTransition(
    c, claimer, victim, epoch, updatedAt, posterAttested)
    local mb = Overlord.ManualBounty
    if not mb or not c or c.status == "approved" or c.status == "paid" then return false end
    if not Overlord:CampaignEpochsMatch(c.epoch, epoch) then return false end
    if not victim or victim == "" or not NamesMatch(c.target, victim) then return false end
    if not claimer or claimer == "" then return false end
    -- Un client modifie pouvait auparavant se declarer tueur de lui-meme et retirer
    -- unilateralement tous les contrats ouverts sur son personnage.
    if NamesMatch(claimer, victim) then return false end
    if NormalizePool(c.pool) ~= CurrentPool() then return false end
    -- Le signataire et les clients de son groupe peuvent verifier la compatibilite
    -- du paiement via leur liste Blizzard. Les autres pools attendent le PB signe du
    -- signataire, qui constitue alors l'attestation portable.
    if not posterAttested and not PaymentIdentitiesValid(c.poster, claimer) then return false end
    if not posterAttested and not HasVictimKillProof(claimer, victim) then return false end
    local claimTimestamp = math.floor(tonumber(updatedAt) or 0)
    if not posterAttested then
        local proof = GetVictimKillProof(claimer, victim)
        if not proof or math.abs(claimTimestamp - proof.killedAt) > CLAIM_PROOF_CLOCK_SEC then
            return false
        end
        -- L'heure de la victime est la seule horloge utilisee pour arbitrer et
        -- demarrer la fenetre de convergence. Le claimant ne choisit pas ce temps.
        claimTimestamp = proof.killedAt
    end
    if claimTimestamp < (tonumber(c.createdAt) or 0) then return false end
    if not ShouldApplyClaim(c, claimTimestamp, claimer) then return false end
    c.status = "claimed"
    c.claimer = claimer
    c.claimedAt = claimTimestamp
    c.approvedAt = nil
    c.paymentSentAt = nil
    c.updatedAt = claimTimestamp
    c.versionActor = claimer
    local changed = mb:ApplyRemoteContract(c, true)
    if changed and mb.RecordClaimCandidate then mb:RecordClaimCandidate(c) end
    if changed and NamesMatch(c.poster, GetLocalFullName()) then
        -- Le poseur transforme la preuve PK+MK en snapshot portable signe par lui.
        -- Les autres clients ne relaient jamais le contrat.
        self:BroadcastPost(c)
    end
    return changed
end

function Overlord.ManualBountySync:ApplyCancelTransition(c, poster, epoch, updatedAt)
    local mb = Overlord.ManualBounty
    if not mb or not c or c.status == "approved" or c.status == "paid"
        or c.status == "cancelled" then return false end
    if not Overlord:CampaignEpochsMatch(c.epoch, epoch) then return false end
    if NormalizePool(c.pool) ~= CurrentPool() then return false end
    if not NamesMatch(c.poster, poster) then return false end
    if (tonumber(updatedAt) or 0) < (tonumber(c.createdAt) or 0) then return false end
    if not ShouldApplyCancel(c, updatedAt) then return false end
    c.status = "cancelled"
    c.claimer = ""
    c.updatedAt = math.floor(tonumber(updatedAt))
    c.versionActor = poster
    return mb:ApplyRemoteContract(c, true)
end

-- Un contrat ne devient payable que par un PB approuve emis par le signataire.
-- Cette transition fige le gagnant : les PK tardifs ne peuvent plus le remplacer.
function Overlord.ManualBountySync:ApplyApprovedSnapshotFromPB(
    c, poster, claimer, victim, epoch, updatedAt)
    local mb = Overlord.ManualBounty
    if not mb or not c or c.status == "paid" or c.status == "cancelled" then return false end
    if not Overlord:CampaignEpochsMatch(c.epoch, epoch) then return false end
    if NormalizePool(c.pool) ~= CurrentPool() then return false end
    if not NamesMatch(c.poster, poster) then return false end
    if not victim or victim == "" or not NamesMatch(c.target, victim) then return false end
    if not claimer or claimer == "" or NamesMatch(claimer, victim) then return false end
    if not PaymentIdentitiesValid(c.poster, claimer) then return false end
    local incTs = math.floor(tonumber(updatedAt) or 0)
    if incTs < (tonumber(c.updatedAt) or 0) then return false end
    c.status = "approved"
    c.claimer = claimer
    c.approvedAt = incTs
    c.paymentSentAt = nil
    c.updatedAt = incTs
    c.versionActor = poster
    return mb:ApplyRemoteContract(c, true)
end

-- Snapshot PB paid : autorite du poseur, converge sans exiger un PK/PP deja recu.
function Overlord.ManualBountySync:ApplyPaidSnapshotFromPB(c, poster, claimer, victim, epoch, updatedAt)
    local mb = Overlord.ManualBounty
    if not mb or not c or c.status == "paid" then return false end
    if not Overlord:CampaignEpochsMatch(c.epoch, epoch) then return false end
    if NormalizePool(c.pool) ~= CurrentPool() then return false end
    if not NamesMatch(c.poster, poster) then return false end
    if not victim or victim == "" or not NamesMatch(c.target, victim) then return false end
    if not claimer or claimer == "" then return false end
    local incTs = math.floor(tonumber(updatedAt) or 0)
    if incTs < (tonumber(c.createdAt) or 0) then return false end
    if incTs < (tonumber(c.updatedAt) or 0) then return false end
    c.status = "paid"
    c.claimer = claimer
    c.paidAt = incTs
    c.updatedAt = incTs
    c.versionActor = poster
    return mb:ApplyRemoteContract(c, true)
end

function Overlord.ManualBountySync:ApplyPaidTransition(c, poster, claimer, victim, epoch, updatedAt)
    local mb = Overlord.ManualBounty
    if not mb or not c or c.status ~= "approved" then return false end
    if not Overlord:CampaignEpochsMatch(c.epoch, epoch) then return false end
    if NormalizePool(c.pool) ~= CurrentPool() then return false end
    if not NamesMatch(c.poster, poster) then return false end
    if not victim or victim == "" or not NamesMatch(c.target, victim) then return false end
    if not claimer or claimer == "" then return false end
    if not NamesMatch(c.claimer, claimer) then return false end
    if (tonumber(updatedAt) or 0) < (tonumber(c.updatedAt) or 0) then return false end
    c.status = "paid"
    c.claimer = claimer
    c.updatedAt = math.max(tonumber(updatedAt) or 0, tonumber(c.updatedAt) or 0)
    c.paidAt = c.updatedAt
    c.versionActor = poster
    return mb:ApplyRemoteContract(c, true)
end

local function IsBetterPendingClaim(incoming, current)
    if not current then return true end
    local incomingTs = tonumber(incoming.updatedAt) or 0
    local currentTs = tonumber(current.updatedAt) or 0
    if incomingTs ~= currentTs then return incomingTs < currentTs end
    local incomingActor = (NameDedupKey(incoming.claimer)
        or incoming.claimer or ""):lower()
    local currentActor = (NameDedupKey(current.claimer)
        or current.claimer or ""):lower()
    return incomingActor < currentActor
end

function Overlord.ManualBountySync:RememberPending(id, kind, data)
    local pending = pendingTransitions[id]
    if not pending then
        local count = 0
        local oldestId
        local oldestAt
        for pendingId, entry in pairs(pendingTransitions) do
            count = count + 1
            local receivedAt = tonumber(entry.receivedAt) or 0
            if not oldestAt or receivedAt < oldestAt then
                oldestAt = receivedAt
                oldestId = pendingId
            end
        end
        if count >= MAX_PENDING_CONTRACTS and oldestId then
            pendingTransitions[oldestId] = nil
        end
        pending = {}
        pendingTransitions[id] = pending
    end
    if kind == "PK" and pending.PK and not IsBetterPendingClaim(data, pending.PK) then
        return
    end
    pending[kind] = data
    pending.receivedAt = GetTime()
end

function Overlord.ManualBountySync:ApplyPendingTransitions(id)
    local pending = pendingTransitions[id]
    local mb = Overlord.ManualBounty
    local c = mb and mb:GetContract(id)
    if not pending or not c then return false end
    if c.status == "paid" then
        pendingTransitions[id] = nil
        return false
    end
    if c.status == "approved" then
        pending.PK = nil
        pending.PX = nil
    end

    local changed = false
    local claim = pending.PK
    local cancel = pending.PX
    if claim then
        if self:ApplyClaimTransition(
            c, claim.claimer, claim.victim, claim.epoch, claim.updatedAt) then
            pending.PK = nil
            changed = true
        end
        c = mb:GetContract(id)
    end
    if cancel and c then
        if self:ApplyCancelTransition(c, cancel.poster, cancel.epoch, cancel.updatedAt) then
            pending.PX = nil
            changed = true
        end
    end

    c = mb:GetContract(id)
    local paid = pending.PP
    if paid and c then
        if self:ApplyPaidTransition(
            c, paid.poster, paid.claimer, paid.victim, paid.epoch, paid.updatedAt) then
            pending.PP = nil
            changed = true
        end
    end
    if not pending.PK and not pending.PX and not pending.PP then
        pendingTransitions[id] = nil
    end
    return changed
end

function Overlord.ManualBountySync:OnReceivePK(payload, sender)
    if not payload or payload == "" then return end
    local version, id, claimer, victim, pool, epochStr, tsStr = strsplit(":", payload, 7)
    if version ~= PROTOCOL_VERSION or not IsValidContractId(id)
        or not claimer or claimer == "" then return end
    if not SenderMatchesName(sender, claimer) then return end
    if not AcceptPool(pool) then return end
    if not AcceptEpoch(epochStr) then return end
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName then
        if not sync:AcceptSyncedContributorName(claimer) then return end
        if not sync:AcceptSyncedContributorName(victim) then return end
    end
    local updatedAt = NormalizeWireTimestamp(tsStr)
    if not updatedAt or not TimestampMatchesCampaign(updatedAt, epochStr) then return end
    local mb = Overlord.ManualBounty
    if not mb then return end
    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = id .. "|" .. claimer .. "|" .. tostring(tsStr)
    if recentPK[dedupKey] and (now - recentPK[dedupKey]) < PK_DEDUP_SEC then return end
    if not RememberEphemeral(recentPK, dedupKey, now, now) then return end
    local c = mb:GetContract(id)
    local transition = {
        claimer = claimer,
        victim = victim,
        pool = pool,
        epoch = tonumber(epochStr) or 0,
        updatedAt = updatedAt,
    }
    if not c then
        self:RememberPending(id, "PK", transition)
        return
    end
    if self:ApplyClaimTransition(
        c, transition.claimer, transition.victim, transition.epoch, transition.updatedAt) then
        self:ApplyPendingTransitions(id)
        RequestUiRefresh()
    elseif c.status ~= "approved" and c.status ~= "paid"
        and not NamesMatch(transition.claimer, transition.victim) then
        -- PK et MK empruntent des routes distinctes. Conserver la reclamation bornee
        -- jusqu'a l'arrivee de la preuve de mort emise par la victime.
        self:RememberPending(id, "PK", transition)
    end
end

function Overlord.ManualBountySync:OnReceiveMK(payload, sender)
    if not payload or payload == "" then return end
    local version, killer, victim, pool, epochStr, tsStr = strsplit(":", payload, 6)
    if version ~= PROTOCOL_VERSION or not killer or killer == ""
        or not victim or victim == "" or NamesMatch(killer, victim) then return end
    -- La seconde moitie de la preuve doit venir du personnage mort, jamais du claimant.
    if not SenderMatchesName(sender, victim) then return end
    if not AcceptPool(pool) or not AcceptEpoch(epochStr) then return end
    local killedAt = NormalizeWireTimestamp(tsStr)
    if not killedAt or not TimestampMatchesCampaign(killedAt, epochStr)
        or math.abs(ServerNow() - killedAt) > VICTIM_KILL_PROOF_SEC then return end
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName then
        if not sync:AcceptSyncedContributorName(killer) then return end
        if not sync:AcceptSyncedContributorName(victim) then return end
    end
    local proofKey = KillProofKey(killer, victim)
    if not proofKey then return end
    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = proofKey .. "|" .. tostring(tsStr)
    if recentMK[dedupKey] and now - recentMK[dedupKey] < MK_DEDUP_SEC then return end
    if not EnsureEphemeralCapacity(recentMK, dedupKey, now)
        or not EnsureEphemeralCapacity(recentVictimKillProofs, proofKey, now) then return end
    CommitEphemeral(recentMK, dedupKey, now, now)
    RegisterVictimKillProof(killer, victim, now, killedAt)
end

function Overlord.ManualBountySync:OnReceivePX(payload, sender)
    if not payload or payload == "" then return end
    local version, id, poster, pool, epochStr, tsStr = strsplit(":", payload, 6)
    if version ~= PROTOCOL_VERSION or not IsValidContractId(id)
        or not poster or poster == "" then return end
    if not SenderMatchesName(sender, poster) then return end
    if not AcceptPool(pool) then return end
    if not AcceptEpoch(epochStr) then return end
    local updatedAt = NormalizeWireTimestamp(tsStr)
    if not updatedAt or not TimestampMatchesCampaign(updatedAt, epochStr) then return end
    local mb = Overlord.ManualBounty
    if not mb then return end
    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = id .. "|" .. poster .. "|" .. tostring(tsStr)
    if recentPX[dedupKey] and (now - recentPX[dedupKey]) < PX_DEDUP_SEC then return end
    if not RememberEphemeral(recentPX, dedupKey, now, now) then return end
    local c = mb:GetContract(id)
    local transition = {
        poster = poster,
        pool = pool,
        epoch = tonumber(epochStr) or 0,
        updatedAt = updatedAt,
    }
    if not c then
        self:RememberPending(id, "PX", transition)
        return
    end
    if not NamesMatch(c.poster, poster) then return end
    if self:ApplyCancelTransition(
        c, transition.poster, transition.epoch, transition.updatedAt) then
        self:ApplyPendingTransitions(id)
        RequestUiRefresh()
    end
end

function Overlord.ManualBountySync:OnReceivePP(payload, sender)
    if not payload or payload == "" then return end
    local version, id, poster, claimer, victim, pool, epochStr, tsStr =
        strsplit(":", payload, 8)
    if version ~= PROTOCOL_VERSION or not IsValidContractId(id)
        or not poster or poster == "" then return end
    if not SenderMatchesName(sender, poster) then return end
    if not AcceptPool(pool) then return end
    if not AcceptEpoch(epochStr) then return end
    local updatedAt = NormalizeWireTimestamp(tsStr)
    if not updatedAt or not TimestampMatchesCampaign(updatedAt, epochStr) then return end
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName then
        if not sync:AcceptSyncedContributorName(claimer) then return end
        if not sync:AcceptSyncedContributorName(victim) then return end
    end
    local mb = Overlord.ManualBounty
    if not mb then return end
    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = id .. "|" .. poster .. "|" .. claimer .. "|" .. tostring(tsStr)
    if recentPP[dedupKey] and (now - recentPP[dedupKey]) < PP_DEDUP_SEC then return end
    if not RememberEphemeral(recentPP, dedupKey, now, now) then return end
    local c = mb:GetContract(id)
    local transition = {
        poster = poster,
        claimer = claimer,
        victim = victim,
        pool = pool,
        epoch = tonumber(epochStr) or 0,
        updatedAt = updatedAt,
    }
    if not c then
        self:RememberPending(id, "PP", transition)
        return
    end
    if not NamesMatch(c.poster, poster) then return end
    if self:ApplyPaidTransition(
        c, transition.poster, transition.claimer, transition.victim,
        transition.epoch, transition.updatedAt) then
        self:ApplyPendingTransitions(id)
        RequestUiRefresh()
    elseif c.status ~= "paid" then
        self:RememberPending(id, "PP", transition)
    end
end

function Overlord.ManualBountySync:OnReceivePM(payload, sender)
    if not payload or payload == "" then return end
    local version, name, xStr, yStr, mapIDStr, sentAtStr, pool, epochStr =
        strsplit(":", payload, 8)
    if version ~= PROTOCOL_VERSION or not name or name == ""
        or not SenderMatchesName(sender, name) then return end
    if not AcceptPool(pool) then return end
    if not AcceptEpoch(epochStr) then return end
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName
        and not sync:AcceptSyncedContributorName(name) then
        return
    end
    local xC = tonumber(xStr)
    local yC = tonumber(yStr)
    local mapID = tonumber(mapIDStr)
    local sentAt = NormalizeWireTimestamp(sentAtStr)
    if not xC or not yC or not mapID or not sentAt then return end
    if xC < 0 or xC > 10000 or yC < 0 or yC > 10000 or mapID <= 0 then return end
    local wallNow = ServerNow()
    if sentAt > wallNow + 120 or wallNow - sentAt > 120 then return end
    local mb = Overlord.ManualBounty
    if not mb then return end
    local dedupKey = (NameDedupKey(name) or name) .. ":" .. tostring(sentAt)
    local now = GetTime()
    PruneDedupTables(now)
    if recentPM[dedupKey] and now - recentPM[dedupKey] < PM_DEDUP_SEC then return end
    if not RememberEphemeral(recentPM, dedupKey, now, now) then return end
    local mapX, mapY = xC / 100, yC / 100
    if not mb:ApplyTargetPosition(name, mapX, mapY, mapID, sentAt) then
        -- PB et PM peuvent emprunter des routes différentes : conserver le PM validé
        -- jusqu'à l'arrivée du contrat ouvert correspondant.
        RememberPendingPosition(name, mapX, mapY, mapID, sentAt, now)
    end
end

function Overlord.ManualBountySync:OnCampaignReset()
    wipe(recentPB)
    wipe(recentPK)
    wipe(recentMK)
    wipe(recentPX)
    wipe(recentPP)
    wipe(recentPM)
    wipe(pendingTransitions)
    wipe(pendingPositions)
    wipe(recentVictimKillProofs)
    for _, state in pairs(ephemeralCacheState) do
        wipe(state.nodes)
        state.count, state.head, state.tail = 0, nil, nil
    end
    wipe(contractPriorityQueue)
    wipe(contractBulkQueue)
    wipe(contractQueueByKey)
    wipe(recentCatalogRequests)
    wipe(recentContractRequests)
    wipe(recentCatalogRequestOrder.nodes)
    recentCatalogRequestOrder.head, recentCatalogRequestOrder.tail = nil, nil
    wipe(recentContractRequestOrder.nodes)
    recentContractRequestOrder.head, recentContractRequestOrder.tail = nil, nil
    wipe(contractRequestBudgets)
    wipe(lastCatalogRequestBySender)
    wipe(catalogSubscribers)
    wipe(catalogSubscriberOrder.nodes)
    catalogSubscriberOrder.head, catalogSubscriberOrder.tail = nil, nil
    pendingPositionCount = 0
    lastDedupPurgeAt = 0
    dedupPruneSpecIndex = 1
    dedupPruneNextKey = nil
    contractPriorityHead = 1
    contractBulkHead = 1
    contractQueueCount = 0
    contractPumpScheduled = false
    contractPumpToken = contractPumpToken + 1
    catalogSubscriberCount = 0
    recentCatalogRequestCount = 0
    recentContractRequestCount = 0
    catalogRecipientCursor = 0
    lastCatalogRequestAt = -math.huge
    directMaintenanceCursor = 0
    lastDirectMaintenanceAt = -math.huge
end
