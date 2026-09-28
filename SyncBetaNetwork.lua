-- Beta transport: bounded store-and-forward over group/channel and Battle.net.
-- The last hop is authenticated by WoW/BNet. Earlier authors are vouched for by
-- that peer, not cryptographically authenticated by Blizzard. Keep the original
-- author when dispatching so relays never manufacture additional witnesses.
local addon = Overlord
local sync = addon.Sync
local net = { peers = {}, stats = { sent = 0, received = 0, dropped = 0 } }
addon.BetaNetwork = net
local allowed = {}
for kind in ("NH SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC OE TV VT VF FR DX VB MN MS WN WS OP OC WB SH HR HB HC HA LD CR CA GR GY GI FC GW GE GP GX GD GM BQ BR PB PK MK PX PP PM"):gmatch("%S+") do
    allowed[kind] = true
end
local MAX_PACKET, MAX_PATH, TTL = 3600, 4, 120
-- A legal multi-fragment relay packet can span more than 15 seconds at the
-- reserved 300 B/s share while urgent traffic is continuous. Expire stalled
-- assemblies by inactivity and always by the packet's maximum lifetime.
local ASSEMBLY_IDLE_TIMEOUT = 30
local MAX_BRIDGE_FRIENDS = 5
local MAX_QUEUE = 128
local CATCHUP_QUEUE = 16
local PAGED_QUEUE = 4
local MAP_CATCHUP_EXTRA = 2
local MAP_RELAY_BATCH = 32
local CATCHUP_RATE = 300
local STATE_QUEUE, STATE_RATE = 24, 250
-- All four lanes share the same 1,000 B/s budget and 128-packet bound.
-- Addressed ranking/map data has a 300 B/s service share; bounded DX/VB
-- snapshots have 250 B/s. Presence and timer updates use the remainder.
local URGENT = {}
-- HR/HA are the tiny catch-up requests and acknowledgements (one every few
-- minutes). Broadcast legacy controls remain urgent; addressed exchanges use
-- the reserved lane below, including their requests and acknowledgements.
for kind in ("NH SH C ZS ZR CB OP OC TV FR FC GE GP GX GD GM HR HA"):gmatch("%S+") do
    URGENT[kind] = true
end
-- Fortresses and outposts share priorities: active captures and final OC events
-- stay urgent; routine snapshots wait.
local function isUrgent(p)
    local kind = p and p.kind
    if kind == "OP" then
        return type(p.payload) == "string" and p.payload:match("^v%d+:[^:]*:([^:]*)") == "in_progress"
    end
    return URGENT[kind] == true
end
local function isCatchup(p)
    if p.target == "*" then return false end
    if p.kind == "SR" or p.kind == "ZA" then
        -- Reserve a map exchange only after discovery established an unexpired
        -- route. Unknown targets keep the old ordinary lane/discovery behavior.
        local route = net.peers[p.target:lower()]
        if not route or GetTime() - route.at > 300 then return false end
        local via = type(route.via) == "string" and route.via:lower() or ""
        for _, node in ipairs(p.path or {}) do
            if node:lower() == via then return false end
        end
        return true
    end
    return p.kind == "HR" or p.kind == "HB" or p.kind == "HC" or p.kind == "HA"
        or p.kind == "LK" or p.kind == "LC" or p.kind == "LR"
end
local function isMapCatchup(p)
    return p.kind == "SR" or p.kind == "ZA"
end
local function isTargetedMapControl(p)
    return p.kind == "SR" and p.target ~= "*"
        and type(p.payload) == "string" and p.payload:match(":T$") ~= nil
end
local function isPagedCatchup(p)
    return p and type(p.payload) == "string"
        and (p.kind == "HR" or p.kind == "HB" or p.kind == "HA")
        and (p.payload:sub(1, 2) == "5:" or p.payload:sub(1, 2) == "6:")
end
local function isPagedControl(p)
    return isPagedCatchup(p) and (p.kind == "HR" or p.kind == "HA")
end
local function isReplicatedState(p)
    if type(p.payload) ~= "string" then return false end
    if p.kind == "DX" then
        return #p.payload <= 250
            and p.payload:match("^%d+:%d+:%d+:[^:]+:%d+:") ~= nil
    end
    return p.kind == "VB" and #p.payload <= 220
        and p.payload:match("^%d+:[^:]+:") ~= nil
end
-- A completion/release must overtake routine timer updates. Preserve FIFO among
-- terminals: C is emitted before its final ZS, and neither invents a victory.
local function isTerminal(p)
    if p.kind == "C" or p.kind == "ZR"
        or p.kind == "OC" or p.kind == "TV" or p.kind == "FR" then return true end
    if p.kind ~= "ZS" then return false end
    local status = p.payload:match("^[^:]+:([^:]+):")
    return status == "captured" or status == "available" or status == "locked"
end
local urgentLane, bulkLane, catchupLane, stateLane =
    { items = {}, head = 1 }, { items = {}, head = 1 },
    { items = {}, head = 1 }, { items = {}, head = 1 }
local pendingPresence = {}
local pumping = false
local function laneSize(lane) return #lane.items - lane.head + 1 end
local function queuedCount()
    return laneSize(urgentLane) + laneSize(bulkLane)
        + laneSize(catchupLane) + laneSize(stateLane)
end
local function queuedMapCount()
    local count = 0
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and isMapCatchup(item.p) then count = count + 1 end
    end
    return count
end
local function queuedZaCount()
    local count = 0
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and item.p.kind == "ZA" then count = count + 1 end
    end
    return count
end
local function queuedMapControlCount()
    local count = 0
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and isTargetedMapControl(item.p) then count = count + 1 end
    end
    return count
end
local function queuedPagedCount()
    local count = 0
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and isPagedCatchup(item.p) then count = count + 1 end
    end
    return count
end
local function laneFor(p)
    return isCatchup(p) and catchupLane
        or (isReplicatedState(p) and stateLane or (isUrgent(p) and urgentLane or bulkLane))
end
local function reclaimablePresenceCount()
    local count = 0
    for i = urgentLane.head, #urgentLane.items do
        local item = urgentLane.items[i]
        if item and item.p.kind == "NH" and item.index == 1
            and not item.tasks[1].sending then count = count + 1 end
    end
    return count
end
local function hasLaneRoom(lane, p, reclaimPresence)
    local total = queuedCount()
    -- Unsent presence may borrow idle reservations, but every data/control
    -- reservation can reclaim it. Never grow the global 128-item queue.
    local presence = total >= MAX_QUEUE - CATCHUP_QUEUE - STATE_QUEUE - PAGED_QUEUE
        and reclaimablePresenceCount() or 0
    if reclaimPresence and presence > 0 then total = total - 1 end
    if total >= MAX_QUEUE then return false end
    if p.kind == "NH" then return true end
    if lane == stateLane then return laneSize(stateLane) < STATE_QUEUE end
    local nonState = queuedCount() - laneSize(stateLane) - presence
    -- Preserve 24 slots for weekly DX/VB before any producer can fill the
    -- global queue with ranking pages or terminal controls. State admission
    -- must not depend on finding a disposable NH/ZS already in the queue.
    if nonState >= MAX_QUEUE - STATE_QUEUE then return false end
    if isPagedCatchup(p) then
        return queuedPagedCount() < PAGED_QUEUE
    end
    -- Keep four of the 104 non-state slots available to the v5/v6 request,
    -- acknowledgement and page stream even when v4 relay rows borrow space.
    if nonState - queuedPagedCount() >= MAX_QUEUE - STATE_QUEUE - PAGED_QUEUE then
        return false
    end
    -- Legacy relays cannot propagate backpressure to the original sender. Let
    -- short bursts borrow idle slots rather than turn the reservation into a
    -- smaller hard cap. Local v5/v6 producers stop at four queued packets.
    if lane == catchupLane then return true end
    return laneSize(urgentLane) + laneSize(bulkLane) - presence
        < MAX_QUEUE - CATCHUP_QUEUE - STATE_QUEUE - PAGED_QUEUE
end
local function forgetPresence(item)
    local key = item.p.kind == "NH" and item.p.path[1]:lower()
    if key and pendingPresence[key] == item then pendingPresence[key] = nil end
end
local function compactLane(lane)
    if lane.head > #lane.items then
        lane.items, lane.head = {}, 1
    elseif lane.head > MAX_QUEUE then
        local remaining = {}
        for i = lane.head, #lane.items do remaining[#remaining + 1] = lane.items[i] end
        lane.items, lane.head = remaining, 1
    end
end
-- Oldest bulk packet whose sending has not started (partially sent packets are
-- kept so their fragments still reassemble).
-- /ov network: relay cost per packet kind (session only, bounded to 64 kinds).
net.kindStats = {}
local kindStatsCount = 0
local function kindRow(kind)
    kind = tostring(kind or "?")
    local row = net.kindStats[kind]
    if not row then
        if kindStatsCount >= 64 then return nil end
        row = { queued = 0, dropped = 0, bytes = 0 }
        net.kindStats[kind] = row
        kindStatsCount = kindStatsCount + 1
    end
    return row
end
local function countKind(kind, field, amount)
    local row = kindRow(kind)
    if row then row[field] = row[field] + (amount or 1) end
end
local function rejectAdmission(p)
    net.stats.dropped = net.stats.dropped + 1
    local field = p.path and #p.path > 1 and "relayRejected" or "localRejected"
    net.stats[field] = (net.stats[field] or 0) + 1
    countKind(p.kind, "dropped")
    return false
end
local function rejectNoTask(p, reason)
    net.stats.dropped = net.stats.dropped + 1
    local side = p.path and #p.path > 1 and "forward" or "local"
    local category = reason == "loop" and "Loop"
        or ((reason == "missing" or reason == "stale") and "Missing" or "Other")
    local field = side .. "NoTask"
    net.stats[field] = (net.stats[field] or 0) + 1
    field = field .. category
    net.stats[field] = (net.stats[field] or 0) + 1
    countKind(p.kind, "dropped")
    return false
end
local function dropWaitingForUrgent()
    for i = bulkLane.head, #bulkLane.items do
        local item = bulkLane.items[i]
        if item and item.index == 1 then
            table.remove(bulkLane.items, i)
            countKind(item.p and item.p.kind, "dropped")
            return true
        end
    end
    -- Protection belongs to the admitted item, not its array position: pump
    -- can move a map reply ahead of ranking pages for bounded service.
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and item.index == 1 and not item.protected then
            table.remove(catchupLane.items, i)
            countKind(item.p.kind, "dropped")
            return true
        end
    end
    return false
end
local function dropWaitingPresence()
    for i = urgentLane.head, #urgentLane.items do
        local item = urgentLane.items[i]
        if item and item.p.kind == "NH" and item.index == 1
            and not item.tasks[1].sending then
            table.remove(urgentLane.items, i)
            forgetPresence(item)
            countKind("NH", "dropped")
            return true
        end
    end
    return false
end
local function dropWaitingForTerminal()
    for i = urgentLane.head, #urgentLane.items do
        local item = urgentLane.items[i]
        if item and item.index == 1 and not item.tasks[1].sending
            and (item.p.kind == "NH" or (item.p.kind == "ZS"
                and item.p.payload:match("^[^:]+:([^:]+):") == "in_progress")) then
            table.remove(urgentLane.items, i)
            forgetPresence(item)
            countKind(item.p.kind, "dropped")
            return true
        end
    end
    return false
end
local function dropWaitingForState()
    -- State snapshots are recoverable from another replica, but an already
    -- admitted page/event must not be silently displaced by an urgent burst.
    -- Reclaim only unsent, lower-priority traffic at the 128-packet limit.
    for i = bulkLane.head, #bulkLane.items do
        local item = bulkLane.items[i]
        if item and item.index == 1 and not item.tasks[1].sending then
            table.remove(bulkLane.items, i)
            countKind(item.p.kind, "dropped")
            return true
        end
    end
    return dropWaitingForTerminal()
end
local function dropBorrowedLegacyForMapControl()
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        local kind = item and item.p.kind
        if item and item.index == 1 and not item.tasks[1].sending
            and not item.protected and (kind == "LK" or kind == "LC" or kind == "LR") then
            table.remove(catchupLane.items, i)
            countKind(kind, "dropped")
            return true
        end
    end
    return false
end
local function waitingMapControl(p)
    -- A territorial request asks for the current map, not a distinct history
    -- page. Keep only its freshest unsent version for this origin/destination,
    -- including on intermediate bridges. F/S requests are never merged here.
    if p.kind ~= "SR" or type(p.payload) ~= "string"
        or not p.payload:match(":T$") then return nil end
    local lane = laneFor(p)
    for i = lane.head, #lane.items do
        local item = lane.items[i]
        if item and item.index == 1 and not item.tasks[1].sending
            and item.p.kind == "SR" and item.p.payload:match(":T$")
            and item.p.target:lower() == p.target:lower()
            and item.p.path[1]:lower() == p.path[1]:lower() then return item end
    end
end
local function stateKey(p)
    if not isReplicatedState(p) then return nil end
    local origin = p.path and p.path[1]
    if not origin then return nil end
    if p.kind == "VB" then
        return "VB|" .. origin:lower() .. "|" .. p.target .. "|" .. p.payload
    end
    local front = p.payload:match("^[^:]*:[^:]*:[^:]*:([^:]+):")
    return front and ("DX|" .. origin:lower() .. "|" .. p.target .. "|" .. front) or nil
end
local function waitingStateItem(p)
    local key = stateKey(p)
    if not key then return nil end
    for i = stateLane.head, #stateLane.items do
        local item = stateLane.items[i]
        if item and item.index == 1 and not item.tasks[1].sending
            and stateKey(item.p) == key then return item end
    end
end
local seen, recent, assemblies = {}, {}, {}
-- Gateways heard on our realm channel (last hop). A group copy coming from one of
-- them is already on that channel: re-emitting it there only burns the Blizzard
-- channel throttle of every raid member.
local channelHeard, channelHeardOrder = {}, {}
-- Each origin's presence (NH) is re-forwarded only when its ORIGIN timestamp is at
-- least NH_FORWARD_SEC after the last forwarded one. Measured on a 3-friend
-- bridge, presence was ~95% of relay bytes. Deciding on the author's timestamp
-- (identical at every hop) instead of the arrival time keeps every relay's
-- choice the same whatever the transit delays: with 45 s heartbeats one in two
-- is forwarded (every 90 s), and even after one lost copy plus delay a peer is
-- heard again within ~200 s, well under the 5 min peer TTL.
local NH_FORWARD_SEC = 90
local nhForwarded, nhForwardedOrder = {}, {}
-- A presence capability is only a protocol hint, never proof of an origin's
-- identity or authority. Generic traffic may refresh a route, but not this TTL.
local pagedCapabilities, pagedCapabilityOrder = {}, {}
local seenOrder, recentOrder, assemblyOrder, peerOrder = {}, {}, {}, {}
local serial = 0
local session = tostring(time()) .. "-" .. tostring(math.random(1, 2147483646))
local function enabled() return addon.BetaNetworkEnabled ~= false end
local function active() return enabled() and not addon.InstanceSuspended and not IsInInstance() end
local function region() return addon.RealmPools:GetOverlordPoolTag() end
local function canonical(name) return sync:CanonicalForeverName(name) end
local function same(a, b) return sync:ForeverIdentitiesMatch(a, b) end
-- FIFO ring (order.first..order.last): same eviction order as before, but O(1).
-- Removing the first array slot shifted up to 2048 keys for every received packet.
local function remember(values, order, key, value, limit)
    if values[key] == nil then
        local first, last = order.first or 1, order.last or 0
        if last - first + 1 >= limit then
            values[order[first]] = nil
            order[first] = nil
            first = first + 1
        end
        last = last + 1
        order[last] = key
        order.first, order.last = first, last
    end
    values[key] = value
end
-- Duplicate check on the raw wire, before decode and identity work. Same key as
-- Receive records (origin = first path node, which decode requires canonical).
local function alreadySeen(wire, sender)
    if type(wire) ~= "string" then return false end
    local pool, id, at, target, path, body = strsplit("|", wire, 6)
    local origin = path and path:match("^[^,]+")
    local known = id ~= nil and origin ~= nil and seen[origin:lower() .. ":" .. id] ~= nil
    local item = known and pendingPresence[origin:lower()]
    -- An authenticated last hop that sends back this exact presence already has
    -- it. Cancel only that peer's remaining copy, never another peer's or the
    -- realm/group broadcast. No change to heartbeat cadence or peer lifetime.
    if not item or item.p.id ~= id or item.p.region ~= pool or item.p.at ~= tonumber(at)
        or item.p.target ~= target or type(body) ~= "string" then return known end
    local kind, payload = strsplit("|", body, 2)
    if kind == "NH" and item.p.payload == payload and same(path:match("[^,]+$"), sender) then
        for i = item.index, #item.tasks do
            local task = item.tasks[i]
            if not task.skip and not task.sending and task.recipient and same(task.recipient, sender) then
                task.skip = true
                net.stats.presenceCopiesSkipped = (net.stats.presenceCopiesSkipped or 0) + 1
            end
        end
    end
    return known
end
local function encode(p)
    return table.concat({ p.region, p.id, tostring(p.at), p.target,
        table.concat(p.path, ","), p.kind, p.payload }, "|")
end
local function decode(wire)
    if type(wire) ~= "string" or #wire > MAX_PACKET then return nil end
    local pool, id, at, target, path, kind, payload = strsplit("|", wire, 7)
    at = tonumber(at)
    local normalizedPool = addon.RealmPools:NormalizeRegionPool(pool)
    if normalizedPool ~= region() or not id or #id > 64 or not id:match("^[%w%-]+$")
        or not at or at ~= math.floor(at) or time() - at > TTL or at - time() > 30
        or not allowed[kind] or not payload or payload:find("[%c]")
        or (target ~= "*" and canonical(target) ~= target) then return nil end
    local nodes, unique = {}, {}
    for name in tostring(path):gmatch("[^,]+") do
        if canonical(name) ~= name or unique[name:lower()] then return nil end
        nodes[#nodes + 1] = name
        unique[name:lower()] = true
    end
    if #nodes < 1 or #nodes > MAX_PATH or table.concat(nodes, ",") ~= path then return nil end
    return { region = normalizedPool, id = id, at = at, target = target, path = nodes, kind = kind, payload = payload }
end
function net:IsPeer(name)
    local key = canonical(name)
    local row = key and self.peers[key:lower()]
    return row ~= nil and GetTime() - row.at <= 300
end
-- Path length of the freshest known route to a peer (1 = heard directly from it,
-- e.g. our own Battle.net friend). nil when unknown or stale.
function net:GetPeerHops(name)
    local key = canonical(name)
    local row = key and self.peers[key:lower()]
    if not row or GetTime() - row.at > 300 then return nil end
    return tonumber(row.hops)
end
function net:GetPeerPagedProtocol(name)
    local key = canonical(name)
    local row = key and pagedCapabilities[key:lower()]
    if not row or GetTime() - row.at > 300 then return nil end
    return row.version
end
function net:GetPeers()
    local names = {}
    for _, row in pairs(self.peers) do
        if GetTime() - row.at <= 300 then names[#names + 1] = row.name end
    end
    table.sort(names)
    return names
end
function net:IsDispatching(sender)
    return self.context ~= nil and same(self.context.origin, sender)
end
-- Only the last hop is authenticated by WoW/BNet. Any earlier origin is written
-- by that gateway: a modified client can put any name in path[1]. Such an origin
-- must never own a score, a capture credit or an identity claim.
function net:IsRelayedOrigin(sender)
    local context = self.context
    return context ~= nil and (tonumber(context.hops) or 0) > 0 and same(context.origin, sender)
end
function net:IsTargetedDispatch()
    return self.context ~= nil and self.context.targeted == true
end
-- The same broadcast was queued by this client within 2 s: its channel/group
-- copies already carry it, a legacy direct copy would only duplicate it.
function net:CarriesBroadcast(kind, payload)
    if not active() then return false end
    local at = recent[tostring(kind) .. "|*|" .. tostring(payload or "")]
    return at ~= nil and GetTime() - at < 2
end
-- Packet dispatched straight from its author over our channel or group.
function net:IsDirectLocalDispatch()
    local c = self.context
    return c ~= nil and (tonumber(c.hops) or 0) == 0
        and (c.transport == "CHANNEL" or c.transport == "RAID" or c.transport == "PARTY")
end
-- Rows sorted by bytes actually sent: what costs the most on the relay.
function net:GetKindDiagnostics(maxRows)
    local list = {}
    for kind, row in pairs(self.kindStats) do
        list[#list + 1] = { kind = kind, row = row }
    end
    table.sort(list, function(a, b)
        if a.row.bytes ~= b.row.bytes then return a.row.bytes > b.row.bytes end
        return a.kind < b.kind
    end)
    local lines = { "Relay by type since login (KB sent / admitted / refused or dropped):" }
    local parts = {}
    for i = 1, math.min(#list, tonumber(maxRows) or 12) do
        local e = list[i]
        parts[#parts + 1] = string.format("%s %.1f/%d/%d", e.kind, e.row.bytes / 1024, e.row.queued, e.row.dropped)
        if #parts == 4 then
            lines[#lines + 1] = "  " .. table.concat(parts, ", ")
            parts = {}
        end
    end
    if #parts > 0 then lines[#lines + 1] = "  " .. table.concat(parts, ", ") end
    if #list == 0 then lines[#lines + 1] = "  nothing relayed yet" end
    lines[#lines + 1] = string.format("Catch-up relay: %d queued (%d reserved), %d B/s reserved within 1000 B/s; NH saved: %d copies, %d replaced.",
        laneSize(catchupLane), CATCHUP_QUEUE, CATCHUP_RATE,
        self.stats.presenceCopiesSkipped or 0, self.stats.presenceCoalesced or 0)
    local mapQueued, pagedQueued = queuedMapCount(), queuedPagedCount()
    lines[#lines + 1] = string.format("Catch-up detail now: %d map, %d paged v5/v6 (max %d), %d legacy/other; paged producer backpressure checks: %d.",
        mapQueued, pagedQueued, PAGED_QUEUE,
        laneSize(catchupLane) - mapQueued - pagedQueued,
        self.stats.pagedBackpressureChecks or 0)
    lines[#lines + 1] = string.format("Relay outcomes since login: local admission refused %d, forward admission refused %d, evicted %d, expired %d, failed BNet copies %d, retry abandoned %d, channel copies skipped %d.",
        self.stats.localRejected or 0, self.stats.relayRejected or 0,
        self.stats.displaced or 0, self.stats.expired or 0,
        self.stats.bnetAbandoned or 0, self.stats.retryAbandoned or 0,
        self.stats.channelSkipped or 0)
    lines[#lines + 1] = string.format("No forwarding task: local %d (route missing/stale %d, loop %d), forward %d (route missing/stale %d, loop %d); path limit %d.",
        self.stats.localNoTask or 0, self.stats.localNoTaskMissing or 0,
        self.stats.localNoTaskLoop or 0, self.stats.forwardNoTask or 0,
        self.stats.forwardNoTaskMissing or 0, self.stats.forwardNoTaskLoop or 0,
        self.stats.forwardPathExhausted or 0)
    lines[#lines + 1] = string.format("DX/VB relay: %d queued (max %d), %d B/s share, %d waiting updates coalesced.",
        laneSize(stateLane), STATE_QUEUE, STATE_RATE, self.stats.stateCoalesced or 0)
    lines[#lines + 1] = string.format("Waiting SR duplicates coalesced: %d (same origin/target only).",
        self.stats.mapRequestsCoalesced or 0)
    return lines
end
function net:IsUrgentPacket(kind, payload) return isUrgent({ kind = kind, payload = payload }) end
function net:IsEcho(kind, payload)
    return self.context and self.context.kind == kind and self.context.payload == payload
end
local pump
local function schedule()
    if pumping then return end
    pumping = true
    C_Timer.After(0.1, pump)
end
-- One budget for all beta packets, including each BNet recipient and each
-- group/channel copy. Never use one independent budget per gateway.
local tokens, budgetAt = 500, GetTime()
local catchupCredit, catchupAt = 500, GetTime()
local stateCredit, stateAt = 500, GetTime()
local mapServiceRun = 0
local mapControlCooldown = 0
local pagedServiceRun = 0
local function spend(bytes)
    local now = GetTime()
    tokens = math.min(500, tokens + math.max(0, now - budgetAt) * 1000)
    budgetAt = now
    if bytes > tokens then return false end
    tokens = tokens - bytes
    return true
end
local function tasksFor(p, wire)
    local tasks, fragments = {}, {}
    local pageVersion = p.payload:sub(1, 2)
    local paged = (p.kind == "HR" or p.kind == "HB" or p.kind == "HA")
        and (pageVersion == "5:" or pageVersion == "6:")
    local count = math.ceil(#wire / 170)
    for i = 1, count do
        fragments[i] = p.id .. ":" .. i .. ":" .. count .. ":" .. wire:sub((i - 1) * 170 + 1, i * 170)
    end
    local route = p.target ~= "*" and net.peers[p.target:lower()] or nil
    local routeFailure = not route and "missing" or nil
    if route and GetTime() - route.at > 300 then route, routeFailure = nil, "stale" end
    if route then
        for _, name in ipairs(p.path) do
            if same(name, route.via) then route, routeFailure = nil, "loop"; break end
        end
    end
    -- Bulk v5 catch-up is always addressed over an established route. Never
    -- flood the realm/group or fan out to friends to discover a missing path.
    if paged and (p.target == "*" or not route) then
        return tasks, p.target == "*" and "untargeted" or routeFailure
    end
    local function add(transport, data, kind, target, recipient)
        tasks[#tasks + 1] = { transport = transport, data = data, kind = kind, target = target,
            bytes = #data + 64, packetKind = p.kind, recipient = recipient }
    end
    local function bnet(id)
        local _, recipient
        if p.kind == "NH" and sync.GetBetaBNetTargetInfo then _, recipient = sync:GetBetaBNetTargetInfo(id) end
        if #wire <= 430 then add("BNET", wire, "BR", id, recipient)
        else for _, fragment in ipairs(fragments) do add("BNET", fragment, "BF", id, recipient) end end
    end
    if route and route.bnet then
        bnet(route.bnet)
    elseif route and (paged or route.transport == "CHANNEL" or route.transport == "WHISPER") then
        for _, fragment in ipairs(fragments) do add("WHISPER", fragment, "BF", route.via, route.via) end
    else
        -- The realm channel only carries what Blizzard's ~1 msg/s allows to be useful.
        local channelCopy = not p.skipChannel
            and (not sync.ChannelCarries or sync:ChannelCarries(p.kind, p.payload, #p.path == 1))
        for _, fragment in ipairs(fragments) do
            if not p.skipGroup then add("GROUP", fragment, "BF") end
            if channelCopy then add("CHANNEL", fragment, "BF") end
        end
        -- Opposite-faction friends are the only Horde/Alliance bridges: each packet
        -- reaches all of them (bounded). Same-faction friends already hear it on the
        -- channel and share the remaining rotating slots. Friends already on the path
        -- have the packet and are skipped.
        local friends = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
        local myFaction = addon.PlayerFaction
        local bridges, others = {}, {}
        local pathKeys = {}
        for _, node in ipairs(p.path) do pathKeys[node:lower()] = true end
        for _, id in ipairs(friends) do
            local faction, character
            if sync.GetBetaBNetTargetInfo then faction, character = sync:GetBetaBNetTargetInfo(id) end
            -- Friend names and path nodes are canonical Forever names.
            local onPath = type(character) == "string" and pathKeys[character:lower()] == true
            if not onPath then
                if #bridges < MAX_BRIDGE_FRIENDS and (faction == "Alliance" or faction == "Horde")
                    and (myFaction == "Alliance" or myFaction == "Horde") and faction ~= myFaction then
                    bridges[#bridges + 1] = id
                else
                    others[#others + 1] = id
                end
            end
        end
        for _, id in ipairs(bridges) do bnet(id) end
        local total, slots = #others, math.max(1, 3 - #bridges)
        local cursor = net.friendCursor or 0
        for i = 1, math.min(slots, total) do bnet(others[(cursor + i - 1) % total + 1]) end
        if total > 0 then net.friendCursor = (cursor + math.min(slots, total)) % total end
        -- R1 fallback to a known gateway when there is no local broadcast path.
        if sync.FindBridgeForEnemyFaction and sync.GetChannelId and not sync:GetChannelId()
            and not IsInGroup() then
            local bridge, band = sync:FindBridgeForEnemyFaction()
            if bridge and band then
                local prefix = band .. ":" .. sync:GetPlayerFullName() .. ":BF:" .. p.id .. ":"
                local size = math.min(170, 255 - 3 - #prefix - 6)
                if size > 0 and math.ceil(#wire / size) <= 64 then
                    local n = math.ceil(#wire / size)
                    for i = 1, n do
                        local r1 = prefix .. i .. ":" .. n .. ":" .. wire:sub((i - 1) * size + 1, i * size)
                        add("WHISPER", r1, "R1", bridge)
                    end
                end
            end
        end
    end
    return tasks, #tasks == 0 and (routeFailure or "no_transport") or nil
end
local function emit(task)
    task.spent = nil
    if task.skip then return true end
    -- Missing optional local paths are not send failures; a throttled channel
    -- that is present must, however, retry the same fragment.
    if task.transport == "GROUP" and not IsInGroup() then return true end
    if task.transport == "CHANNEL" and not sync:GetChannelId() then return true end
    if not spend(task.bytes) then return false end
    task.spent = task.bytes
    task.sending = true
    local sent, reason
    if task.transport == "BNET" then sent = sync:SendToBNet(task.target, task.kind, task.data)
    elseif task.transport == "WHISPER" then sent = sync:SendWhisper(task.kind, task.data, task.target)
    elseif task.transport == "GROUP" then sent = sync:SendToGroup(task.kind, task.data)
    else
        -- /ov network: a relay copy is a BF fragment; count it under its real kind.
        sync._channelSendKind = tostring(task.packetKind or "?") .. "*"
        sent, reason = sync:SendToChannel(task.kind, task.data, false)
        sync._channelSendKind = nil
    end
    task.sending = nil
    if sent ~= true then
        -- A BNet recipient can log out after route selection. There is no
        -- throttling retry here; let catchup rediscover a path instead of
        -- blocking every other peer behind a dead friend for the full TTL.
        if task.transport == "BNET" then
            net.stats.dropped = net.stats.dropped + 1
            net.stats.bnetAbandoned = (net.stats.bnetAbandoned or 0) + 1
            return true
        end
        -- Our own channel message budget is empty: retry this copy later without
        -- holding the Battle.net/whisper copies. A Blizzard refusal is retried too.
        task.deferred = reason == "budget"
        task.refused = not task.deferred
        -- Nothing left the client: give the shared relay bytes back to the others.
        if task.deferred then tokens = math.min(500, tokens + task.bytes); task.spent = nil end
        return false
    end
    net.stats.sent = net.stats.sent + 1
    net.stats.bytes = (net.stats.bytes or 0) + task.bytes
    countKind(task.packetKind, "bytes", task.bytes)
    return true
end
function net:Queue(p, immediate)
    if not p or not allowed[p.kind] then return false end
    local urgent = isUrgent(p)
    local catchup = isCatchup(p)
    local mapCatchup = catchup and isMapCatchup(p)
    local mapControl = catchup and isTargetedMapControl(p)
    local localMap = mapCatchup and #p.path == 1
    local requestPrevious = waitingMapControl(p)
    if mapControl and not requestPrevious and queuedMapControlCount() >= 2 then
        return rejectAdmission(p)
    end
    -- The local SR ticker uses two extra slots and retries on backpressure.
    -- An upstream relay cannot retry a refused page, so hold one complete
    -- 32-page addressed ZA batch here instead of accepting pages to evict them.
    if p.kind == "ZA" and mapCatchup and laneSize(catchupLane) >= CATCHUP_QUEUE
        and queuedZaCount() >= (localMap and MAP_CATCHUP_EXTRA
            or MAP_RELAY_BATCH) then return rejectAdmission(p) end
    -- Keep the freshest unsent presence in its original place in the queue.
    -- Once any copy has started, finish it instead of disrupting its fragments.
    local presenceKey = p.kind == "NH" and p.path[1]:lower()
    local previous = presenceKey and pendingPresence[presenceKey]
    local statePrevious = waitingStateItem(p)
    if statePrevious and p.at < statePrevious.p.at then return true end
    if statePrevious and p.kind == "DX" then
        local oldSeq = tonumber(statePrevious.p.payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:]+):"))
        local newSeq = tonumber(p.payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:]+):"))
        if oldSeq and newSeq and newSeq < oldSeq then return true end
    end
    local replace = previous and previous.index == 1
        and not previous.tasks[1].sending and p.at >= previous.p.at
    if statePrevious then previous, replace = statePrevious, true end
    if requestPrevious then
        previous, replace = requestPrevious, p.at >= requestPrevious.p.at
        if not replace then return true end
    end
    local lane = laneFor(p)
    local wire, item
    if not replace and not hasLaneRoom(lane, p) then
        local reclaimPresence = p.kind ~= "NH" and (catchup or urgent or lane == stateLane)
            and hasLaneRoom(lane, p, true)
        -- A malformed or unroutable map page must not evict a live progress
        -- packet just because it claimed a known target.
        if mapCatchup or lane == stateLane or reclaimPresence then
            wire = encode(p)
            if #wire > MAX_PACKET then return false end
            local tasks, reason = tasksFor(p, wire)
            item = { p = p, tasks = tasks, index = 1,
                protected = mapCatchup or lane == stateLane or isPagedCatchup(p)
                    or (catchup and laneSize(catchupLane) < CATCHUP_QUEUE) }
            if #item.tasks == 0 then return rejectNoTask(p, reason) end
        end
        -- Full: an urgent packet displaces the oldest waiting bulk packet instead
        -- of being refused. Bulk packets are refused as before.
        if not ((reclaimPresence and dropWaitingPresence())
            or (lane == stateLane and laneSize(stateLane) < STATE_QUEUE
                and dropWaitingForState())
            or (mapControl and (dropBorrowedLegacyForMapControl()
                or dropWaitingForTerminal()))
            or (p.kind == "ZA" and mapCatchup
                and queuedZaCount() < (localMap and MAP_CATCHUP_EXTRA
                or MAP_RELAY_BATCH)
                and dropWaitingForTerminal())
            or (urgent and p.kind ~= "NH" and not catchup and (dropWaitingForUrgent()
                or (isTerminal(p) and dropWaitingForTerminal())))) then
            return rejectAdmission(p)
        end
        self.stats.dropped = self.stats.dropped + 1
        self.stats.displaced = (self.stats.displaced or 0) + 1
    end
    -- The ordinary path still rejects overload before encoding fragments.
    if not item then
        wire = encode(p)
        if #wire > MAX_PACKET then return false end
        local tasks, reason = tasksFor(p, wire)
        item = { p = p, tasks = tasks, index = 1,
            protected = lane == stateLane or isPagedCatchup(p) or mapControl
                or (catchup and (laneSize(catchupLane) < CATCHUP_QUEUE
                or (p.kind == "ZA" and mapCatchup and queuedZaCount() < (localMap and MAP_CATCHUP_EXTRA
                    or MAP_RELAY_BATCH)))) }
        if #item.tasks == 0 then return rejectNoTask(p, reason) end
    end
    if replace then
        previous.p, previous.tasks = p, item.tasks
        if requestPrevious then
            if mapControl then previous.protected = true end
            self.stats.mapRequestsCoalesced = (self.stats.mapRequestsCoalesced or 0) + 1
            return true
        end
        if presenceKey then
            self.stats.presenceCoalesced = (self.stats.presenceCoalesced or 0) + 1
        else
            self.stats.stateCoalesced = (self.stats.stateCoalesced or 0) + 1
        end
        return true
    end
    if presenceKey then pendingPresence[presenceKey] = item end
    countKind(p.kind, "queued")
    -- A lease release may use the currently available budget synchronously before
    -- entering an instance, but never bypasses that budget.
    if immediate and p.kind == "ZR" then
        while item.tasks[item.index] and emit(item.tasks[item.index]) do item.index = item.index + 1 end
        if not item.tasks[item.index] then return true end
        table.insert(lane.items, lane.head, item)
    else lane.items[#lane.items + 1] = item end
    schedule()
    return true
end
function net:CanSendLeaderboardPage()
    local ready = queuedPagedCount() < PAGED_QUEUE
    if not ready then
        self.stats.pagedBackpressureChecks = (self.stats.pagedBackpressureChecks or 0) + 1
    end
    return ready
end
pump = function()
    pumping = false
    if not active() then
        if enabled() and queuedCount() > 0 then C_Timer.After(2, schedule) end
        return
    end
    -- Leave quota-blocked copies in place, including when both lane heads wait.
    -- Look for useful work behind them without allocating another retry item on
    -- every tick. The queue bounds this scan to at most 128 entries.
    local channelReady = not sync.ChannelTokenReady or sync:ChannelTokenReady()
    local now = time()
    local function readyIndex(lane, predicate)
        local firstReady
        for i = lane.head, #lane.items do
            local it = lane.items[i]
            local task = it.tasks[it.index]
            if (not predicate or predicate(it.p)) and (channelReady or now - it.p.at > TTL or not task
                or task.transport ~= "CHANNEL" or not task.defers) then
                if lane ~= urgentLane or it.index > 1 or isTerminal(it.p) then return i end
                firstReady = firstReady or i
            end
        end
        return firstReady
    end
    local urgentIndex = readyIndex(urgentLane)
    local bulkIndex = readyIndex(bulkLane)
    local stateIndex = readyIndex(stateLane)
    local mapControlIndex = readyIndex(catchupLane, isTargetedMapControl)
    local mapPageIndex = readyIndex(catchupLane, function(p)
        return isMapCatchup(p) and not isTargetedMapControl(p)
    end)
    local mapIndex = mapControlIndex and (not mapPageIndex or mapControlCooldown == 0)
        and mapControlIndex or mapPageIndex or mapControlIndex
    local pagedControlIndex = readyIndex(catchupLane, isPagedControl)
    local pagedPageIndex = readyIndex(catchupLane, function(p)
        return isPagedCatchup(p) and not isPagedControl(p)
    end)
    local legacyIndex = readyIndex(catchupLane, function(p)
        return not isMapCatchup(p) and not isPagedCatchup(p)
    end)
    local rankingIndex = pagedControlIndex
        or (pagedPageIndex and (not legacyIndex or pagedServiceRun < 3)
            and pagedPageIndex or legacyIndex or pagedPageIndex)
    -- A four-to-one map/ranking service ratio gets one complete ZA batch past
    -- a long-path busy bridge before packet TTL, while ranking still advances.
    local catchupIndex = mapIndex and (not rankingIndex or mapServiceRun < 4)
        and mapIndex or rankingIndex or mapIndex
    local stamp = GetTime()
    catchupCredit = math.min(500, catchupCredit + math.max(0, stamp - catchupAt) * CATCHUP_RATE)
    catchupAt = stamp
    stateCredit = math.min(500, stateCredit + math.max(0, stamp - stateAt) * STATE_RATE)
    stateAt = stamp
    -- Finish a bulk packet already partly sent, otherwise urgent first.
    local lane, index = urgentLane, urgentIndex
    if bulkIndex and (not urgentIndex or bulkLane.items[bulkIndex].index > 1) then
        lane, index = bulkLane, bulkIndex
    end
    local terminalReady = urgentIndex and isTerminal(urgentLane.items[urgentIndex].p)
    if stateIndex and not terminalReady then
        local it = stateLane.items[stateIndex]
        local task = it.tasks[it.index]
        if not (urgentIndex or catchupIndex) or not task or now - it.p.at > TTL
            or stateCredit >= task.bytes then
            lane, index = stateLane, stateIndex
        end
    end
    if catchupIndex then
        local it = catchupLane.items[catchupIndex]
        local task = it.tasks[it.index]
        -- The share is a minimum, not a ceiling: without live urgent traffic,
        -- recover ranking data before routine history. Old v4 producers send
        -- one whole row/s and cannot obey per-hop backpressure.
        if not (urgentIndex or stateIndex) or not task or now - it.p.at > TTL
            or catchupCredit >= task.bytes then
            lane, index = catchupLane, catchupIndex
        end
    end
    -- Historical keep proofs and idle snapshots use only otherwise idle service.
    -- They never delay a ready request, ranking row, map page or live state.
    if not index then
        if queuedCount() > 0 then schedule() end
        return
    end
    if index ~= lane.head then
        table.insert(lane.items, lane.head, table.remove(lane.items, index))
    end
    local item = lane.items[lane.head]
    -- Drain the available shared byte budget, not just one fragment per tick.
    -- The old 10-fragment/s ceiling unnecessarily backed up full snapshots.
    for _ = 1, 16 do
        local task = item.tasks[item.index]
        if time() - item.p.at > TTL or not task then
            if task then
                countKind(item.p.kind, "dropped")
                net.stats.expired = (net.stats.expired or 0) + 1
            end
            item.index = #item.tasks + 1
            break
        end
        if lane == catchupLane and (urgentIndex or stateIndex) and not task.skip
            and catchupCredit < task.bytes then break end
        if lane == stateLane and (urgentIndex or catchupIndex) and not task.skip
            and stateCredit < task.bytes then break end
        local emitted = emit(task)
        if lane == catchupLane and task.spent then catchupCredit = math.max(0, catchupCredit - task.spent) end
        if lane == stateLane and task.spent then stateCredit = math.max(0, stateCredit - task.spent) end
        if emitted then
            item.index = item.index + 1
        elseif task.deferred then
            -- Channel message budget empty: this copy waits at the end of its lane
            -- while the item's Battle.net/whisper copies keep going in this tick.
            task.deferred = nil
            task.defers = (task.defers or 0) + 1
            item.index = item.index + 1
            local deferLane = lane
            if hasLaneRoom(deferLane, item.p) then
                deferLane.items[#deferLane.items + 1] = {
                    p = item.p, tasks = { task }, index = 1, protected = item.protected,
                }
            elseif lane == stateLane or (lane == catchupLane and isPagedCatchup(item.p)) then
                -- Keep an accepted state or paged packet's deferred copy in its
                -- bounded item while its reservation is full.
                item.tasks[#item.tasks + 1] = task
                break
            else
                net.stats.channelSkipped = (net.stats.channelSkipped or 0) + 1
            end
        elseif task.refused then
            -- A refused channel/group/whisper copy must not stall the Battle.net
            -- copies behind it: retry it later on its own, at most three times.
            task.refused = nil
            task.retries = (task.retries or 0) + 1
            net.stats.refused = (net.stats.refused or 0) + 1
            item.index = item.index + 1
            local retryLane = lane
            if task.retries <= 3 and hasLaneRoom(retryLane, item.p) then
                retryLane.items[#retryLane.items + 1] = {
                    p = item.p, tasks = { task }, index = 1, protected = item.protected,
                }
            elseif task.retries <= 3 and (lane == stateLane
                or (lane == catchupLane and isPagedCatchup(item.p))) then
                item.tasks[#item.tasks + 1] = task
            else
                net.stats.dropped = net.stats.dropped + 1
                net.stats.retryAbandoned = (net.stats.retryAbandoned or 0) + 1
            end
            break
        else
            -- Shared relay byte budget: wait for the next tick.
            break
        end
    end
    if item.index > #item.tasks then
        if lane == catchupLane then
            mapServiceRun = isMapCatchup(item.p) and math.min(4, mapServiceRun + 1) or 0
            if isTargetedMapControl(item.p) then mapControlCooldown = 4
            elseif isMapCatchup(item.p) then
                mapControlCooldown = math.max(0, mapControlCooldown - 1)
            end
            if not isMapCatchup(item.p) then
                pagedServiceRun = isPagedCatchup(item.p)
                    and math.min(3, pagedServiceRun + 1) or 0
            end
        end
        forgetPresence(item)
        lane.items[lane.head] = false; lane.head = lane.head + 1
    end
    compactLane(urgentLane)
    compactLane(bulkLane)
    compactLane(catchupLane)
    compactLane(stateLane)
    if queuedCount() > 0 then schedule() end
end
function net:Send(kind, payload, target, immediate)
    if not active() or not allowed[kind] or type(payload) ~= "string"
        or payload:find("[%c]") then return false end
    -- Both the startup heartbeat and community scan call Broadcast with the
    -- plain addon version. Annotate at their common producer boundary.
    if kind == "NH" and payload == tostring(addon.Version or "") then
        payload = payload .. "~lp6"
    end
    -- Handlers may rebroadcast received snapshots. The existing packet is already
    -- forwarded below; do not give that replay a fresh author or hop budget.
    if self:IsEcho(kind, payload) and not target then return false end
    local name = sync:GetPlayerFullName()
    if canonical(name) ~= name or name == "" then return false end
    target = target or "*"
    if target ~= "*" and canonical(target) ~= target then return false end
    local key = kind .. "|" .. target .. "|" .. payload
    local now = GetTime()
    if recent[key] and now - recent[key] < 2 then return true end
    serial = serial + 1
    local p = { region = region(), id = session .. "-" .. serial, at = time(),
        target = target, path = { name }, kind = kind, payload = payload }
    if not self:Queue(p, immediate) then return false end
    remember(recent, recentOrder, key, now, 512)
    remember(seen, seenOrder, name:lower() .. ":" .. p.id, now, 2048)
    return true
end
function net:Broadcast(kind, payload, extras)
    local sent = self:Send(kind, payload or "")
    -- Community producers bundle further fronts, victory bonuses and resource
    -- stocks with the first message. Preserve every payload on the beta route.
    for _, extra in ipairs(extras or {}) do
        if extra.type and extra.payload then
            if not self:Send(extra.type, extra.payload) then sent = false end
        end
    end
    return sent and 1 or 0
end
function net:Receive(wire, sender, transport, bnetID, decoded)
    if not active() then return false end
    -- Copies of an already processed packet (other bridges, group + channel) are
    -- rejected before any decode; the result is the same false as below.
    if alreadySeen(wire, sender) then return false end
    local p = decoded or decode(wire)
    if not p or not sender or not same(p.path[#p.path], sender) then return false end
    local me = sync:GetPlayerFullName()
    local meKey = type(me) == "string" and me:lower() or nil
    -- Path nodes and our own name are canonical: case-insensitive equality is same().
    for _, node in ipairs(p.path) do if node:lower() == meKey then return false end end
    local origin = p.path[1]
    local key = origin:lower() .. ":" .. p.id
    if seen[key] then return false end
    local addressed = p.target == "*" or same(p.target, me)
    -- An intermediate targeted hop can reject a packet after route lookup or
    -- queue admission. Do not seal origin:id until at least one forwarding task
    -- is accepted, so another verified path can deliver the same packet.
    -- Local delivery, broadcasts, and the deliberately unrelayed K retain the
    -- original immediate replay seal.
    local pendingForward = not addressed and p.kind ~= "K"
    if not pendingForward then remember(seen, seenOrder, key, GetTime(), 2048) end
    local previousRoute = self.peers[origin:lower()]
    if not previousRoute or GetTime() - previousRoute.at > 60 or #p.path <= previousRoute.hops then
        remember(self.peers, peerOrder, origin:lower(), {
            name = origin, at = GetTime(), via = sender, transport = transport, bnet = bnetID, hops = #p.path,
        }, 128)
    end
    self.stats.received = self.stats.received + 1
    if addressed and p.kind ~= "NH" then
        local previous = self.context
        self.context = { origin = origin, gateway = sender, hops = #p.path - 1,
            kind = p.kind, payload = p.payload, targeted = p.target ~= "*", transport = transport }
        -- BETA is explicit: do not masquerade the relay as a direct WoW whisper.
        local ok, err = pcall(sync.OnAddonMessage, sync, "OverlordF",
            p.kind .. ":" .. p.payload, "BETA", origin)
        self.context = previous
        if not ok then self.stats.lastError = tostring(err) end
    elseif p.kind == "NH" then
        -- Old peers forward NH payloads unchanged and ignore the suffix. Keep
        -- only the origin's most recent advertised capability for five minutes.
        -- A delayed older NH must not downgrade a fresher lp6 advertisement.
        local advertised = p.payload:match("~lp(%d+)$")
        local originKey, version = origin:lower(), advertised == "6" and 6 or 5
        local previous = pagedCapabilities[originKey]
        if not previous or GetTime() - previous.at > 300
            or p.at > previous.originAt
            or (p.at == previous.originAt and version > previous.version) then
            remember(pagedCapabilities, pagedCapabilityOrder, originKey,
                { version = version, at = GetTime(), originAt = p.at }, 128)
        end
        -- Like Retail's community login, pull the territorial map first. Ranking
        -- already has its own paged catch-up; an SR:F on every new peer crowded
        -- the same bridge with redundant leaderboard responses during login.
        -- At most two targeted map pulls per minute, with no roster/club needed.
        local now = GetTime()
        if not self.pullWindow or now - self.pullWindow >= 60 then self.pullWindow, self.pulls = now, 0 end
        self.requested = self.requested or {}
        local last = self.requested[origin:lower()] or -300
        if self.pulls < 2 and now - last >= 300 then
            self.pulls = self.pulls + 1
            -- Bound this cache by the same live peer population.
            self.requested = self.requested or {}
            if not self.requestOrder then self.requestOrder = {} end
            if sync:SendSyncRequest({ betaTarget = origin }) then
                remember(self.requested, self.requestOrder, origin:lower(), now, 128)
            end
        end
    end
    -- A relayed kill is never credited (only its author's direct copy counts, anti-
    -- forgery since 1.0.19): forwarding it only burned relay and channel budget.
    local forwardPresence = true
    if p.kind == "NH" then
        local last = nhForwarded[origin:lower()]
        local at = tonumber(p.at) or 0
        -- A timestamp going backwards (clock fix, stale copy) never blocks a newer one.
        forwardPresence = not last or at - last >= NH_FORWARD_SEC or at < last - NH_FORWARD_SEC
    end
    local forwarded = false
    if p.kind ~= "K" and forwardPresence and #p.path < MAX_PATH and (p.target == "*" or not addressed) then
        p.path[#p.path + 1] = me
        p.skipGroup = transport == "RAID" or transport == "PARTY"
        -- Whoever gave us a group copy either put it on the channel or got it from
        -- there. Only a gateway we never hear on our channel (another realm) needs it.
        local heardAt = p.skipGroup and channelHeard[sender:lower()] or nil
        p.skipChannel = transport == "CHANNEL"
            or (heardAt ~= nil and GetTime() - heardAt <= 300)

        forwarded = self:Queue(p) == true
        if forwarded then
            if pendingForward then remember(seen, seenOrder, key, GetTime(), 2048) end
            if p.kind == "NH" then
                remember(nhForwarded, nhForwardedOrder, origin:lower(), p.at, 512)
            end
        end
    end
    if pendingForward and not forwarded then
        if #p.path >= MAX_PATH then
            self.stats.forwardPathExhausted = (self.stats.forwardPathExhausted or 0) + 1
        end
        return false
    end
    return true
end
function net:ReceiveFragment(payload, sender, transport, bnetID)
    if not active() or type(payload) ~= "string" or #payload > 252 then return false end
    local id, part, count, chunk = strsplit(":", payload, 4)
    part, count = tonumber(part), tonumber(count)
    local name = canonical(sender)
    if not name or not id or #id > 64 or not id:match("^[%w%-]+$") or not chunk
        or #chunk > 170 or not part or not count or count < 1 or count > 64
        or part < 1 or part > count or part ~= math.floor(part) or count ~= math.floor(count) then return false end
    if transport == "CHANNEL" then
        remember(channelHeard, channelHeardOrder, name:lower(), GetTime(), 256)
    end
    local key = name:lower() .. ":" .. id
    local a = assemblies[key]
    if not a or GetTime() - a.at > TTL
        or GetTime() - (a.lastAt or a.at) > ASSEMBLY_IDLE_TIMEOUT then
        a = { at = GetTime(), lastAt = GetTime(), count = count, got = 0, chunks = {} }
        remember(assemblies, assemblyOrder, key, a, 64)
    end
    if a.count ~= count then return false end
    if a.chunks[part] and a.chunks[part] ~= chunk then return false end
    if not a.chunks[part] then
        a.chunks[part] = chunk
        a.got = a.got + 1
        a.lastAt = GetTime()
    end
    if a.got ~= count then return true end
    local wire = table.concat(a.chunks)
    -- Every later duplicate fragment of a completed packet lands here again.
    if alreadySeen(wire, name) then return false end
    local p = decode(wire)
    if not p or p.id ~= id then return false end
    return self:Receive(wire, name, transport, bnetID, p)
end
function net:Start()
    if not enabled() or self.started then return end
    self.started = true
    local function hello()
        if active() then net:Broadcast("NH", addon.Version) end
    end
    C_Timer.After(3, hello)
    self.ticker = C_Timer.NewTicker(45, hello)
end
