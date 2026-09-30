-- Beta transport: bounded store-and-forward over group/channel and Battle.net.
-- The last hop is authenticated by WoW/BNet. Earlier authors are vouched for by
-- that peer, not cryptographically authenticated by Blizzard. Keep the original
-- author when dispatching so relays never manufacture additional witnesses.
local addon = Overlord
local sync = addon.Sync
local net = { peers = {}, stats = { sent = 0, received = 0, dropped = 0 } }
addon.BetaNetwork = net
local allowed = {}
for kind in ("NH SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC OE TV VT VF FR VB MN MS OP OC SH HR HB HC HA LD CR CA GR GY GI FC GW GE GP GX GD GM"):gmatch("%S+") do
    allowed[kind] = true
end
local MAX_PACKET, MAX_PATH, TTL = 3600, 4, 120
-- A legal multi-fragment relay packet can span more than 15 seconds at the
-- reserved 300 B/s share while urgent traffic is continuous. Expire stalled
-- assemblies by inactivity and always by the packet's maximum lifetime.
local ASSEMBLY_IDLE_TIMEOUT = 30
local MAX_BRIDGE_FRIENDS = 5
local MAX_QUEUE = 128
local ROUTINE_FORWARD_SEC = 60
local routineForwarded, routineForwardedOrder = {}, {}
local CATCHUP_QUEUE = 16
local PAGED_QUEUE = 4
local MAP_CATCHUP_EXTRA = 2
local MAP_RELAY_BATCH = 32
local CATCHUP_RATE = 300
local STATE_QUEUE, STATE_RATE = 24, 250
-- Ordinary packets (routine outpost/fortress states, guild/class requests, alerts)
-- are served after urgent ones. A continuous stream of relayed presence/progress
-- kept them waiting until the 120 s TTL expired; after this wait one of them goes
-- first. Terminal events (C, ZR, OC, TV...) still always pass before.
local BULK_MAX_WAIT = 20
-- ... but at most one such aged packet per second. Under overload every bulk item
-- is older than 20 s: unbounded, this inverted priorities for good and the urgent
-- lane (relayed presence included) stopped draining, so far peers lost their route.
local BULK_AGED_SERVE_INTERVAL = 1
local lastBulkAgedServeAt = -1000
-- Presence keeps routes (and the ~lp6 capability) alive for direct catch-up.
-- Ordinary traffic may take back a borrowed presence slot only while presence
-- holds more than half the queue: below that floor a busy hop evicted every
-- relayed NH before it left and far peers lost their route for good.
local PRESENCE_RECLAIM_FLOOR = 64
-- All four lanes share the same 1,000 B/s budget and 128-packet bound.
-- Addressed ranking/map data has a 300 B/s service share; bounded VB
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
-- The first in_progress ZS of our own capture is the defenders' early warning. When the urgent lane
-- is full of forwarded traffic it may take the slot of an unsent presence/progress copy, like a
-- terminal event (bulk packets were already displaced for it).
local function isOwnSiegeStart(p)
    return p.kind == "ZS" and type(p.path) == "table" and #p.path == 1
        and type(p.payload) == "string"
        and (tonumber(p.payload:match("^[^:]+:in_progress:[^:]*:(%d+):")) or 999) <= 45
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
-- Local content coverage (see the block above tasksFor).
local dedup = { records = {}, order = {} }
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
    -- Preserve 24 slots for weekly VB before any producer can fill the
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
    -- smaller hard cap; live traffic takes a borrowed slot back (see Queue).
    -- Local v5/v6 producers stop at four queued packets.
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
-- Instantane ZA relaye pour un autre : le destinataire jette tout le lot s'il
-- manque une page. Une fois une page refusee ici, les suivantes du meme lot ne
-- servent plus a rien en aval ; les refuser d'emblee rend leur budget aux autres.
-- Jamais pour nos propres lots (#path == 1) : le ticker SR local les relance.
local lostZaBatches, lostZaBatchCount = {}, 0
local LOST_ZA_BATCH_SEC = 60
local function forwardedZaBatchKey(p)
    if p.kind ~= "ZA" or type(p.path) ~= "table" or #p.path < 2
        or type(p.payload) ~= "string" then return nil end
    local id = p.payload:match("^@([%w_-]+):%d+:%d+|")
    -- The target is part of the batch: the same page ids fan out to several
    -- recipients, and a refusal for one of them says nothing about the others.
    return id and (tostring(p.path[1]):lower() .. "|" .. tostring(p.target or "*"):lower()
        .. "|" .. id) or nil
end
local function markZaBatchLost(p)
    local key = forwardedZaBatchKey(p)
    if not key then return end
    local lostAt = lostZaBatches[key]
    -- Only the first refusal starts the window: blocked pages must not extend it.
    if lostAt and GetTime() - lostAt < LOST_ZA_BATCH_SEC then return end
    if not lostAt then
        if lostZaBatchCount >= 256 then lostZaBatches, lostZaBatchCount = {}, 0 end
        lostZaBatchCount = lostZaBatchCount + 1
    end
    lostZaBatches[key] = GetTime()
end
local function isZaBatchLost(p)
    local key = forwardedZaBatchKey(p)
    local lostAt = key and lostZaBatches[key]
    return lostAt ~= nil and GetTime() - lostAt < LOST_ZA_BATCH_SEC
end
local function rejectAdmission(p)
    net.stats.dropped = net.stats.dropped + 1
    local field = p.path and #p.path > 1 and "relayRejected" or "localRejected"
    net.stats[field] = (net.stats[field] or 0) + 1
    countKind(p.kind, "dropped")
    markZaBatchLost(p)
    return false
end
local function rejectNoTask(p, reason)
    markZaBatchLost(p)
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
-- Catch-up admitted beyond its sixteen protected slots only borrowed idle space.
-- Live traffic takes it back: at an evening peak, forwarded v4 rows held 94 of
-- 128 slots and every live kill/score broadcast was refused. Protection belongs
-- to the admitted item, not its array position: pump can move a map reply ahead
-- of ranking pages for bounded service.
-- Ordinary live traffic takes only forwarded rows: a local producer already
-- advanced past a row once Send accepted it, whereas legacy upstream senders
-- cannot back-pressure. Urgent packets (captures, alerts) may also take a local
-- row, as before; the v4 digest recovers it on the next exchange. Live traffic
-- only reclaims while the lane really exceeds its reservation; a map page
-- replacing catch-up with catch-up (anyLevel) may go below it.
local function borrowedCatchupIndex(anyLevel, includeLocal)
    if not anyLevel and laneSize(catchupLane) <= CATCHUP_QUEUE then return nil end
    for i = catchupLane.head, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and item.index == 1 and not item.protected
            and not item.tasks[1].sending and (includeLocal or #item.p.path > 1) then
            return i
        end
    end
    return nil
end
local function dropBorrowedCatchup(anyLevel, includeLocal)
    local i = borrowedCatchupIndex(anyLevel, includeLocal)
    if not i then return false end
    local item = table.remove(catchupLane.items, i)
    dedup.abandon(item.tasks)
    countKind(item.p.kind, "dropped")
    return true
end
local function dropWaitingForUrgent()
    -- Borrowed catch-up goes before live bulk traffic (kills, scores).
    if dropBorrowedCatchup(false, true) then return true end
    for i = bulkLane.head, #bulkLane.items do
        local item = bulkLane.items[i]
        if item and item.index == 1 then
            table.remove(bulkLane.items, i)
            dedup.abandon(item.tasks)
            countKind(item.p and item.p.kind, "dropped")
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
-- A full queue first gives up an unsent item that has already outlived its TTL:
-- pump only expires lane heads, so stale items behind them held slots for nothing.
local function dropExpiredWaiting()
    local now = (GetServerTime and GetServerTime()) or time()
    for _, lane in ipairs({ bulkLane, urgentLane, catchupLane, stateLane }) do
        for i = lane.head, #lane.items do
            local item = lane.items[i]
            if item and item.index == 1 and not item.tasks[1].sending and now - item.p.at > TTL then
                table.remove(lane.items, i)
                forgetPresence(item)
                dedup.abandon(item.tasks)
                countKind(item.p.kind, "dropped")
                net.stats.expired = (net.stats.expired or 0) + 1
                return true
            end
        end
    end
    return false
end
-- One unsent in-progress outpost update per (origin, site): a capture ticks
-- every 5 s with a new hold time, so older queued ticks are only noise.
local function outpostSite(p)
    return p.kind == "OP" and type(p.payload) == "string" and p.payload:match("^v%d+:([^:]*):") or nil
end
local function waitingOutpostItem(p)
    local site = outpostSite(p)
    if not site or not isUrgent(p) then return nil end
    local origin = p.path[1]:lower()
    for i = urgentLane.head, #urgentLane.items do
        local item = urgentLane.items[i]
        if item and item.index == 1 and not item.tasks[1].sending and item.p.kind == "OP" and item.p.target == p.target
            and item.p.path[1]:lower() == origin and outpostSite(item.p) == site then
            return item
        end
    end
    return nil
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
            dedup.abandon(item.tasks)
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
    return "VB|" .. origin:lower() .. "|" .. p.target .. "|" .. p.payload
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
-- choice the same whatever the transit delays.
local NH_FORWARD_SEC = 90
-- Presence heartbeat. Any relayed packet already refreshes its origin's route,
-- so NH only has to keep silent peers and the ~lp6 capability (both 300 s TTL,
-- also in older clients) alive. Every 120 s heartbeat passes the 90 s forward
-- filter; after one lost copy the peer is heard again within 240 s < 300 s.
-- 45 s used to refresh each route six times per TTL for nothing.
local NH_INTERVAL = 120
local nhForwarded, nhForwardedOrder = {}, {}
-- Shard presence (SH) is sent every 60 s by every active-front player and used to be
-- forwarded by every hop with no filter, each copy taking a channel message plus
-- group/BNet copies. Same origin-timestamp rule as NH: a hop forwards an origin's SH
-- only when its timestamp is at least SH_FORWARD_SEC after the last forwarded one, so
-- far peers still hear each player every ~120 s (shard peer TTL is 180 s). The origin's
-- own direct copies are unchanged, and it is always handled locally.
local SH_FORWARD_SEC = 90
local shForwarded, shForwardedOrder = {}, {}
-- Relayed presence (NH that already crossed a hop) only keeps routes and the ~lp6
-- capability alive (both 300 s TTL, refreshed by every relayed packet of the origin).
-- The origin's own copies keep the full fan-out. A hop forwards to every opposite-faction
-- bridge plus NH_RELAY_SLOTS rotating friend (was up to 3), and puts it on the realm channel
-- only for an origin that is not audible there (was every hop and every beat): channel
-- mates already hear the origins on their channel themselves. An origin reachable only
-- through a hop keeps one channel copy per forwarded beat: routes live 300 s and must
-- survive one lost copy.
local NH_RELAY_SLOTS = 1
-- A presence capability is only a protocol hint, never proof of an origin's
-- identity or authority. Generic traffic may refresh a route, but not this TTL.
local pagedCapabilities, pagedCapabilityOrder = {}, {}
local seenOrder, recentOrder, assemblyOrder, peerOrder = {}, {}, {}, {}
-- Broadcast packets handled here whose forward was refused (full queue): a copy
-- of the same origin:id arriving through another bridge may retry the forward
-- only, without being handled locally a second time. Bounded, TTL-limited.
local forwardRetry, forwardRetryOrder = {}, {}
local function forwardRetryKey(wire)
    if type(wire) ~= "string" then return nil end
    local _, id, _, target, path = strsplit("|", wire, 6)
    local origin = path and path:match("^[^,]+")
    if target ~= "*" or not id or not origin then return nil end
    local key = origin:lower() .. ":" .. id
    local at = forwardRetry[key]
    if at and GetTime() - at <= TTL then return key end
    return nil
end
local serial = 0
local session = tostring(time()) .. "-" .. tostring(math.random(1, 2147483646))
-- Packet dates use Blizzard's shared server clock: a PC clock more than 30 s
-- ahead made every relayed packet from that player invisible to all others.
local function serverNow() return (GetServerTime and GetServerTime()) or time() end
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
        or not at or at ~= math.floor(at) or serverNow() - at > TTL or at - serverNow() > 30
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
-- Secondes depuis le dernier paquet de ce pair (nil si inconnu ou perime).
-- Catch-up is point-to-point since 1.2.4: a map, ranking or history exchange only
-- runs between direct neighbours (same channel/group/whisper, or a Battle.net
-- friend). The relay carries live traffic only. Forwarding every exchange across
-- up to four hops multiplied one reply into thousands of copies at evening peaks.
-- Guild/class hints answered by many peers (GY, CA) and their targeted requests
-- (GR, CR; a relayed one is ignored on arrival anyway) follow the same rule. A
-- player's own identity answer (GI) stays relayable: one small authoritative
-- reply per request, the only way a far owner can confirm its guild.
local CATCHUP_KINDS = {}
for kind in ("SR ZA HR HA HB HC LK LC LR LO LOC OE GY CA GR CR"):gmatch("%S+") do CATCHUP_KINDS[kind] = true end
local function isPointToPointCatchup(kind, target)
    return CATCHUP_KINDS[kind] == true and target ~= nil and target ~= "*"
end
function net:IsDirectPeer(name)
    return self:GetPeerHops(name) == 1
end
function net:GetDirectPeers()
    local names = {}
    for _, row in pairs(self.peers) do
        if GetTime() - row.at <= 300 and tonumber(row.hops) == 1 then names[#names + 1] = row.name end
    end
    table.sort(names)
    return names
end
-- Same count as #GetDirectPeers(), without building and sorting a list (up to 512).
function net:CountDirectPeers()
    local count, now = 0, GetTime()
    for _, row in pairs(self.peers) do
        if now - row.at <= 300 and tonumber(row.hops) == 1 then count = count + 1 end
    end
    return count
end
function net:GetPeerAge(name)
    local key = canonical(name)
    local row = key and self.peers[key:lower()]
    local age = row and GetTime() - row.at
    if not age or age > 300 then return nil end
    return age
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
    -- "dropped" mixes intentional refusals with real losses: break it down.
    local noRoute = (self.stats.localNoTask or 0) + (self.stats.forwardNoTask or 0)
    lines[#lines + 1] = string.format("Drops explained: %d copies relayed for others refused by the relay budget (incl. %d pages of already incomplete maps skipped on purpose); %d own messages refused (most are retried); %d evicted and %d expired in the queue; %d without a route.",
        self.stats.relayRejected or 0, self.stats.zaBatchSkipped or 0,
        self.stats.localRejected or 0, self.stats.displaced or 0,
        self.stats.expired or 0, noRoute)
    lines[#lines + 1] = string.format("No forwarding task: local %d (route missing/stale %d, loop %d), forward %d (route missing/stale %d, loop %d); path limit %d.",
        self.stats.localNoTask or 0, self.stats.localNoTaskMissing or 0,
        self.stats.localNoTaskLoop or 0, self.stats.forwardNoTask or 0,
        self.stats.forwardNoTaskMissing or 0, self.stats.forwardNoTaskLoop or 0,
        self.stats.forwardPathExhausted or 0)
    lines[#lines + 1] = string.format("VB relay: %d queued (max %d), %d B/s share, %d waiting updates coalesced.",
        laneSize(stateLane), STATE_QUEUE, STATE_RATE, self.stats.stateCoalesced or 0)
    lines[#lines + 1] = string.format("Waiting SR duplicates coalesced: %d (same origin/target only).",
        self.stats.mapRequestsCoalesced or 0)
    return lines
end
function net:IsUrgentPacket(kind, payload) return isUrgent({ kind = kind, payload = payload }) end
-- Queue sizes for the /ov sync summary (no mutation).
function net:GetQueueSummary()
    return { total = queuedCount(), catchup = laneSize(catchupLane), catchupMax = CATCHUP_QUEUE,
        state = laneSize(stateLane), stateMax = STATE_QUEUE }
end
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
-- Local-only content coverage for broadcast content (OP, LO, LOC, VB and TV).
-- Every origin re-broadcasts the same converged
-- payload, and each copy used to open a complete fan-out here (channel + group +
-- bridges + 3 rotating friends). Track per content who already has it, from what
-- this client queued/sent or saw on a path. A later identical copy (another
-- origin) then
--   * replaces a rotating slot that would repeat a covered friend by the next
--     friend that has not got the content yet, so every copy reaches new friends
--     (this relay never reaches a friend later than before);
--   * still repeats covered friends/channel/group exactly like before while the
--     queue is quiet (a lost copy is retried by the next origin as before);
--   * while the queue is busy, drops only repeats beyond COVER_COPIES per target,
--     and the whole copy when nothing else is left. Local dispatch and the wire
--     format are untouched.
local DEDUP_KINDS = { OP = true, LO = true, LOC = true, VB = true, TV = true }
-- COVER_TTL: how long a sent copy counts. COVER_PENDING: how long a copy still
-- waiting in the queue counts (an evicted/expired one is voided at once).
local COVER_TTL, COVER_PENDING, COVER_RECORDS = 60, 20, 128
-- Copies one target may still receive while busy: an older relay forwards each
-- copy to three more of its own friends, so a friend with many friends needs more
-- than one.
local COVER_COPIES = 2
function dedup.key(p)
    if p.target ~= "*" or not DEDUP_KINDS[p.kind] or type(p.payload) ~= "string" then return nil end
    return p.kind .. "|" .. p.payload
end
-- Live copies of this content already sent (or still waiting) to one target.
function dedup.count(list, now)
    local n = 0
    for i = 1, list and #list or 0 do
        local entry = list[i]
        -- Entries keep a two-field state shared with the task, never the task itself
        -- (a task table is ~1 KB and records live up to COVER_TTL).
        local state = entry.state
        local live
        if not state then live = now - entry.at <= COVER_TTL
        elseif state.sentAt then live = now - state.sentAt <= COVER_TTL
        else live = not state.gone and now - entry.at <= COVER_PENDING end
        if live then n = n + (entry.weight or 1) end
    end
    return n
end
function dedup.add(rec, field, id, entry, now)
    local group = rec[field]
    local list = group[id]
    if not list then list = {}; group[id] = list end
    if #list >= 4 then
        local live = {}
        for i = 1, #list do
            if dedup.count({ list[i] }, now) > 0 then live[#live + 1] = list[i] end
        end
        list = live
        group[id] = list
    end
    list[#list + 1] = entry
end
-- Half of the lane reservation is queued: an identical repeat must not take a
-- slot a fresh packet needs.
function dedup.busy(p)
    local lane = laneFor(p)
    if lane == stateLane then return laneSize(lane) * 2 >= STATE_QUEUE end
    return laneSize(lane) * 2 >= MAX_QUEUE - CATCHUP_QUEUE - STATE_QUEUE - PAGED_QUEUE
        or queuedCount() * 4 >= MAX_QUEUE * 3
end
-- Called once a packet is accepted (or skipped as fully covered), never for a
-- refused one: the coverage must describe what is really going to be sent.
function dedup.commit(tasks)
    local cover = tasks and tasks.cover
    if not cover then return end
    local now = GetTime()
    local rec = dedup.records[cover.key]
    if not rec or now - rec.at > COVER_TTL then
        rec = { at = now, friends = {}, carriers = {} }
        remember(dedup.records, dedup.order, cover.key, rec, COVER_RECORDS)
    end
    -- Friends on the path already hold it: as good as COVER_COPIES copies.
    for _, id in ipairs(cover.path or {}) do
        dedup.add(rec, "friends", id, { at = now, weight = COVER_COPIES }, now)
    end
    -- One copy per target, whatever the number of fragments.
    local counted = {}
    for _, task in ipairs(tasks) do
        local field, id = "friends", task.covId
        if id == nil then field, id = "carriers", task.covCarrier end
        if id ~= nil and not counted[field .. tostring(id)] then
            counted[field .. tostring(id)] = true
            local state = task.covState
            if not state then state = {}; task.covState = state end
            dedup.add(rec, field, id, { at = now, state = state }, now)
        end
    end
end
function dedup.abandon(tasks, from)
    for i = from or 1, #tasks do
        local task = tasks[i]
        task.data = nil
        if task.covState then task.covState.gone = true end
    end
end
local function tasksFor(p, wire)
    local tasks, fragments = {}, {}
    local ckey, pathFriends, trimmed, coverId, coverCarrier
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
        local task = { transport = transport, data = data, kind = kind, target = target,
            bytes = #data + 64, packetKind = p.kind, recipient = recipient,
            covId = coverId, covCarrier = coverCarrier }
        tasks[#tasks + 1] = task
        return task
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
        local relayedPresence = p.kind == "NH" and #p.path > 1
        if channelCopy and relayedPresence then
            -- An origin we hear ourselves on the channel is heard by every channel mate too.
            local heard = channelHeard[p.path[1]:lower()]
            channelCopy = not (heard ~= nil and GetTime() - heard <= 300)
        end
        -- A presence packet (SH) whose content the channel already carries (we sent it
        -- directly and Blizzard accepted it, or a peer's identical message was heard there)
        -- would be one more message on the same ~1 msg/s quota. Decided once per packet when
        -- its first channel fragment is due (see emit). Alerts and terminal events keep every
        -- copy: the relay copy is what channel hearers forward to their own friends and
        -- groups, hence to the other faction. (Separate from the content dedup below, which
        -- only handles OP/LO/LOC/VB/TV.)
        local chanCover = channelCopy and not isTerminal(p)
            and { kind = p.kind, payload = p.payload, origin = p.path[1] } or nil
        local now, rec, trim, groupAgain, channelAgain = GetTime()
        ckey = dedup.key(p)
        if ckey then
            rec = dedup.records[ckey]
            pathFriends, trimmed = {}, 0
            -- Only copies relayed for others are trimmed, never our own broadcast.
            trim = #p.path > 1 and dedup.busy(p)
            groupAgain = rec ~= nil and dedup.count(rec.carriers.group, now) >= COVER_COPIES
            channelAgain = rec ~= nil and dedup.count(rec.carriers.channel, now) >= COVER_COPIES
        end
        for _, fragment in ipairs(fragments) do
            if not p.skipGroup then
                if trim and groupAgain then trimmed = trimmed + 1
                elseif not (trim and not IsInGroup()) then coverCarrier = "group"; add("GROUP", fragment, "BF") end
            end
            if channelCopy then
                if trim and channelAgain then trimmed = trimmed + 1
                elseif not (trim and sync.GetChannelId and not sync:GetChannelId()) then
                    coverCarrier = "channel"; add("CHANNEL", fragment, "BF").chanCover = chanCover
                end
            end
        end
        coverCarrier = nil
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
            if onPath then
                if pathFriends then pathFriends[#pathFriends + 1] = id end
            else
                if #bridges < MAX_BRIDGE_FRIENDS and (faction == "Alliance" or faction == "Horde")
                    and (myFaction == "Alliance" or myFaction == "Horde") and faction ~= myFaction then
                    bridges[#bridges + 1] = id
                else
                    others[#others + 1] = id
                end
            end
        end
        -- Same selection as ever: every bridge, then `slots` rotating friends
        -- (the cursor advances identically). Coverage only adds substitutes and,
        -- while busy, removes repeats.
        local entries, picked = {}, {}
        for _, id in ipairs(bridges) do entries[#entries + 1] = { id = id } end
        local total, slots = #others, math.max(1, 3 - #bridges)
        if relayedPresence then slots = NH_RELAY_SLOTS end
        local cursor = net.friendCursor or 0
        for i = 1, math.min(slots, total) do
            local id = others[(cursor + i - 1) % total + 1]
            picked[id] = true
            entries[#entries + 1] = { id = id }
        end
        if total > 0 then net.friendCursor = (cursor + math.min(slots, total)) % total end
        if rec then
            local spare = 0
            for _, entry in ipairs(entries) do
                local copies = dedup.count(rec.friends[entry.id], now)
                entry.again = copies >= COVER_COPIES
                entry.covered = copies >= 1 and picked[entry.id] == true
                if entry.covered then spare = spare + 1 end
            end
            -- A rotating slot that would repeat a covered friend goes to the next
            -- friend, in rotation order, that has not got this content yet.
            local first = cursor + math.min(slots, total)
            local step, swapped = 0, 0
            while swapped < spare and step < total do
                local id = others[(first + step) % total + 1]
                if not picked[id] and dedup.count(rec.friends[id], now) == 0 then
                    picked[id] = true
                    entries[#entries + 1] = { id = id }
                    swapped = swapped + 1
                end
                step = step + 1
            end
            -- Busy: the covered friend that was replaced is not repeated.
            for _, entry in ipairs(entries) do
                if swapped > 0 and entry.covered and trim then
                    entry.again, swapped = true, swapped - 1
                end
            end
        end
        for _, entry in ipairs(entries) do
            if trim and entry.again then trimmed = trimmed + 1
            else coverId = entry.id; bnet(entry.id) end
        end
        coverId = nil
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
    if ckey then tasks.cover = { key = ckey, path = pathFriends } end
    if trimmed and trimmed > 0 then
        -- Everything this copy would send is already covered and the queue is busy.
        if #tasks == 0 then return tasks, "redundant" end
        net.stats.contentDedupTrimmed = (net.stats.contentDedupTrimmed or 0) + trimmed
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
    local cover = task.transport == "CHANNEL" and task.chanCover or nil
    if cover then
        if cover.skip == nil then
            cover.skip = sync.ChannelAlreadyCovers ~= nil
                and sync:ChannelAlreadyCovers(cover.kind, cover.payload, cover.origin) == true
            if cover.skip then
                net.stats.channelCoveredSkipped = (net.stats.channelCoveredSkipped or 0) + 1
            end
        end
        if cover.skip then return true end
    end
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
            if task.covState then task.covState.gone = true end
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
    -- A sent task is never sent again: release its text; content dedup only needs
    -- the send time, kept in the small shared state.
    task.data = nil
    if task.covState then task.covState.sentAt = GetTime() end
    net.stats.sent = net.stats.sent + 1
    net.stats.bytes = (net.stats.bytes or 0) + task.bytes
    countKind(task.packetKind, "bytes", task.bytes)
    return true
end
-- A relayed copy whose fan-out is entirely covered is not a failure: it is
-- handled (like a forwarded one) and the coverage of its path is kept.
local function noTask(p, tasks, reason)
    if reason ~= "redundant" then return rejectNoTask(p, reason) end
    dedup.commit(tasks)
    net.stats.contentDedupSkipped = (net.stats.contentDedupSkipped or 0) + 1
    return true
end
function net:Queue(p, immediate)
    if not p or not allowed[p.kind] then return false end
    if isZaBatchLost(p) then
        self.stats.zaBatchSkipped = (self.stats.zaBatchSkipped or 0) + 1
        return rejectAdmission(p)
    end
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
    local replace = previous and previous.index == 1
        and not previous.tasks[1].sending and p.at >= previous.p.at
    if statePrevious then previous, replace = statePrevious, true end
    if requestPrevious then
        previous, replace = requestPrevious, p.at >= requestPrevious.p.at
        if not replace then return true end
    end
    local outpostPrevious = not previous and waitingOutpostItem(p) or nil
    if outpostPrevious then
        previous, replace = outpostPrevious, p.at >= outpostPrevious.p.at
        if not replace then return true end
    end
    local lane = laneFor(p)
    local wire, item
    local roomy = replace or hasLaneRoom(lane, p)
    if not roomy and dropExpiredWaiting() then roomy = hasLaneRoom(lane, p) end
    if not roomy then
        -- Priority lanes may always take back a slot an unsent presence borrowed.
        -- Ordinary packets (guild/class requests, alerts, broadcast SR) only when
        -- presence exceeds PRESENCE_RECLAIM_FLOOR, so routes keep a lane.
        -- Relayed shard presence (SH) is routine: it never displaces anything.
        local routineShard = p.kind == "SH" and #p.path > 1
        local reclaimPresence = p.kind ~= "NH" and not routineShard and hasLaneRoom(lane, p, true)
            and (catchup or urgent or lane == stateLane
                or reclaimablePresenceCount() > PRESENCE_RECLAIM_FLOOR)
        -- Live packets that may displace something are encoded first too: a
        -- redundant or oversized copy must not evict a queued item for nothing.
        local liveReclaim = not catchup and p.kind ~= "NH" and not routineShard
            and (urgent or (lane == bulkLane and borrowedCatchupIndex() ~= nil))
        -- A malformed or unroutable map page must not evict a live progress
        -- packet just because it claimed a known target.
        if mapCatchup or lane == stateLane or reclaimPresence or liveReclaim then
            wire = encode(p)
            if #wire > MAX_PACKET then return false end
            local tasks, reason = tasksFor(p, wire)
            item = { p = p, tasks = tasks, index = 1,
                protected = mapCatchup or lane == stateLane or isPagedCatchup(p)
                    or (catchup and laneSize(catchupLane) < CATCHUP_QUEUE) }
            if #item.tasks == 0 then return noTask(p, tasks, reason) end
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
                and (dropBorrowedCatchup(true) or dropWaitingForTerminal()))
            or (urgent and p.kind ~= "NH" and not routineShard
                and not catchup and (dropWaitingForUrgent()
                or ((isTerminal(p) or isOwnSiegeStart(p)) and dropWaitingForTerminal())))
            or (lane == bulkLane and not catchup and dropBorrowedCatchup())) then
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
        if #item.tasks == 0 then return noTask(p, tasks, reason) end
    end
    if replace then
        dedup.abandon(previous.tasks)
        dedup.commit(item.tasks)
        previous.p, previous.tasks = p, item.tasks
        if requestPrevious then
            if mapControl then previous.protected = true end
            self.stats.mapRequestsCoalesced = (self.stats.mapRequestsCoalesced or 0) + 1
            return true
        end
        if outpostPrevious then
            self.stats.outpostCoalesced = (self.stats.outpostCoalesced or 0) + 1
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
    item.queuedAt = GetTime()
    dedup.commit(item.tasks)
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
    local now = serverNow()
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
    if lane == urgentLane and bulkIndex and urgentIndex
        and not isTerminal(urgentLane.items[urgentIndex].p)
        and stamp - lastBulkAgedServeAt >= BULK_AGED_SERVE_INTERVAL then
        local waiting = bulkLane.items[bulkIndex]
        if stamp - (waiting.queuedAt or stamp) >= BULK_MAX_WAIT then
            lane, index = bulkLane, bulkIndex
            lastBulkAgedServeAt = stamp
        end
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
        if serverNow() - item.p.at > TTL or not task then
            if task then
                dedup.abandon(item.tasks, item.index)
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
                    p = item.p, tasks = { task }, index = 1, protected = item.protected, queuedAt = item.queuedAt,
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
                    p = item.p, tasks = { task }, index = 1, protected = item.protected, queuedAt = item.queuedAt,
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
    -- A catch-up exchange never starts toward a peer that is not a direct neighbour.
    if isPointToPointCatchup(kind, target) and not self:IsDirectPeer(target) then
        self.stats.catchupNotDirect = (self.stats.catchupNotDirect or 0) + 1
        return false
    end
    local key = kind .. "|" .. target .. "|" .. payload
    local now = GetTime()
    if recent[key] and now - recent[key] < 2 then return true end
    serial = serial + 1
    local p = { region = region(), id = session .. "-" .. serial, at = serverNow(),
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
    -- rejected before any decode; the result is the same false as below. The one
    -- exception is a broadcast whose forward was refused here: that copy only
    -- retries the forward.
    local retryForward = false
    if alreadySeen(wire, sender) then
        if not forwardRetryKey(wire) then return false end
        retryForward = true
    end
    local p = decoded or decode(wire)
    if not p or not sender or not same(p.path[#p.path], sender) then return false end
    local me = sync:GetPlayerFullName()
    local meKey = type(me) == "string" and me:lower() or nil
    -- Path nodes and our own name are canonical: case-insensitive equality is same().
    for _, node in ipairs(p.path) do if node:lower() == meKey then return false end end
    local origin = p.path[1]
    local key = origin:lower() .. ":" .. p.id
    if seen[key] and not retryForward then return false end
    local addressed = p.target == "*" or same(p.target, me)
    -- An intermediate targeted hop can reject a packet after route lookup or
    -- queue admission. Do not seal origin:id until at least one forwarding task
    -- is accepted, so another verified path can deliver the same packet.
    -- Local delivery, broadcasts, and the deliberately unrelayed K retain the
    -- original immediate replay seal.
    local pendingForward = not addressed and p.kind ~= "K"
    if not pendingForward then remember(seen, seenOrder, key, GetTime(), 2048) end
    local previousRoute = self.peers[origin:lower()]
    -- A direct route outlives relayed copies for two presence intervals (4 min):
    -- a peer is heard first-hand only every ~2 min, while relayed copies of the
    -- same presence keep arriving; letting them win after 60 s made a Battle.net
    -- friend look "far" half of the time, and catch-up only runs with direct peers.
    local keepRoute = previousRoute and tonumber(previousRoute.hops) == 1 and 240 or 60
    if not previousRoute or GetTime() - previousRoute.at > keepRoute or #p.path <= previousRoute.hops then
        remember(self.peers, peerOrder, origin:lower(), {
            name = origin, at = GetTime(), via = sender, transport = transport, bnet = bnetID, hops = #p.path,
        }, 512)
    end
    self.stats.received = self.stats.received + 1
    if retryForward then
        -- Already handled locally: skip delivery, capability and pulls.
    elseif addressed and p.kind ~= "NH" then
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
        -- A complete global map arrived moments ago: another full map pulled just
        -- because a new peer spoke would only repeat it. Periodic and login map
        -- catch-ups are unchanged.
        local recentFullMap = sync._lastFullZaAt and now - sync._lastFullZaAt < 45
        -- Only a direct neighbour is asked: its map reply never needs a relay.
        if #p.path == 1 and self.pulls < 2 and now - last >= 300 and not recentFullMap then
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
    if p.kind == "NH" or p.kind == "SH" then
        local window = p.kind == "NH" and NH_FORWARD_SEC or SH_FORWARD_SEC
        local last = (p.kind == "NH" and nhForwarded or shForwarded)[origin:lower()]
        local at = tonumber(p.at) or 0
        -- A timestamp going backwards (clock fix, stale copy) never blocks a newer one.
        forwardPresence = not last or at - last >= window or at < last - window
        -- Presence only needs to reach direct neighbours since catch-up became
        -- point to point (1.2.4), and each player already sends its own to its
        -- channel, group and Battle.net friends: another player's NH is never
        -- relayed (it was about half of the relay budget). Shard presence (SH,
        -- small, feeds the layer tooltip) keeps one Battle.net hop.
        if p.kind == "NH" or #p.path > 2 or (#p.path == 2 and transport ~= "BNET") then
            forwardPresence = false
        end
    end
    local forwarded = false
    -- Catch-up addressed to someone else is not relayed (point-to-point only).
    -- Broadcast map, guild and class requests are not relayed either: only the
    -- requester's direct neighbours answer them since 1.2.4, first-hand.
    local relayable = not isPointToPointCatchup(p.kind, p.target)
        and not ((p.kind == "SR" or p.kind == "GR" or p.kind == "CR") and p.target == "*")
    if not relayable and not addressed then
        self.stats.catchupNotRelayed = (self.stats.catchupNotRelayed or 0) + 1
        -- Never relayed: seal it so duplicate copies are not decoded again.
        remember(seen, seenOrder, key, GetTime(), 2048)
    end
    if relayable and p.kind ~= "K" and forwardPresence and #p.path < MAX_PATH
        and (p.target == "*" or not addressed) then
        p.path[#p.path + 1] = me
        p.skipGroup = transport == "RAID" or transport == "PARTY"
        -- Whoever gave us a group copy either put it on the channel or got it from
        -- there. Only a gateway we never hear on our channel (another realm) needs it.
        local heardAt = p.skipGroup and channelHeard[sender:lower()] or nil
        p.skipChannel = transport == "CHANNEL"
            or (heardAt ~= nil and GetTime() - heardAt <= 300)

        -- The same routine outpost state (held/neutral, identical payload from any
        -- origin) already relayed within a minute is handled, not queued again.
        -- Channel receivers trust OP from any origin, so the origin is not part of
        -- the key.
        local routineKey = p.kind == "OP" and p.target == "*" and not isUrgent(p)
            and ("OP|" .. p.payload) or nil
        -- Remembered at admission, even if that copy is later evicted: under
        -- saturation, re-admitting each duplicate only churned the queue (1.2.4 test).
        local routineAt = routineKey and routineForwarded[routineKey]
        if routineAt and GetTime() - routineAt < ROUTINE_FORWARD_SEC then
            forwarded = true
            self.stats.routineForwardSkipped = (self.stats.routineForwardSkipped or 0) + 1
        else
            forwarded = self:Queue(p) == true
            if forwarded and routineKey then
                remember(routineForwarded, routineForwardedOrder, routineKey, GetTime(), 256)
            end
        end
        if p.target == "*" then
            if forwarded then
                forwardRetry[key] = nil
            elseif not retryForward then
                remember(forwardRetry, forwardRetryOrder, key, GetTime(), 256)
            end
        end
        if forwarded then
            if pendingForward then remember(seen, seenOrder, key, GetTime(), 2048) end
            if p.kind == "NH" then
                remember(nhForwarded, nhForwardedOrder, origin:lower(), p.at, 512)
            elseif p.kind == "SH" then
                remember(shForwarded, shForwardedOrder, origin:lower(), p.at, 512)
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
    -- Let refused broadcast forwards reach Receive's retry-only path as well.
    if alreadySeen(wire, name) and not forwardRetryKey(wire) then return false end
    local p = decode(wire)
    if not p or p.id ~= id then return false end
    return self:Receive(wire, name, transport, bnetID, p)
end
-- Same-faction peers reachable by a plain whisper: heard directly (hops == 1) and
-- recently, on a transport that is same-faction by construction (channel, group,
-- whisper) or with a known same-faction character (Battle.net friend). Whispers
-- never cross factions, and a peer routed through a bridge is not one hop away.
local LOCAL_PEER_FRESH = 200
function net:GetLocalPeers(exclude)
    local now, mine, out = GetTime(), addon.PlayerFaction, {}
    for key, row in pairs(self.peers) do
        if now - row.at <= LOCAL_PEER_FRESH and tonumber(row.hops) == 1
            and not (exclude and exclude[key]) then
            local t = row.transport
            local direct = t == "CHANNEL" or t == "WHISPER" or t == "RAID" or t == "PARTY"
            local faction = sync.GetBetaPeerFaction and sync:GetBetaPeerFaction(row.name)
            if ((faction ~= nil and faction == mine) or (faction == nil and direct))
                and not (sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(row.name)) then
                out[#out + 1] = row.name
            end
        end
    end
    return out
end
-- Live-score bridge. An opposite-faction player's live total (K) only reaches that
-- player's own Battle.net friends: a relayed K is never credited, and channel and
-- group copies stay on the other faction. The friend that accepted the owner's own
-- K (hop 0, sender == subject) re-emits that same total as a plain LK row, a form
-- every client since 1.1.0 accepts for a subject it already knows, to a few
-- same-faction peers. Bounded: one row per subject per 60 s (newest total wins), at
-- most 6 rows/min for the whole client, 3 peers per row (least recently served
-- first). Only totals accepted from the owner's own K are passed on, only when they
-- grew here, and never a jump larger than 30 kills plus one per second since the
-- last total this client vouched for.
local BRIDGE_LK_SUBJECT_GAP, BRIDGE_LK_PER_MIN, BRIDGE_LK_FANOUT = 60, 6, 3
local BRIDGE_LK_ALLOWANCE, BRIDGE_LK_MAX_ROWS = 30, 256
-- bridgeLK: enemy totals passed on to our own faction (channel, whispers as fallback).
-- bridgeOut (1.3.2): our own faction's totals, heard from their owners, passed on to
-- our opposite-faction Battle.net friends, whose clients then put them on their
-- channel. Same bounds for both: one row per subject per 60 s, 6 rows/min, 3 targets.
local bridgeLK = { rows = {}, order = {}, queue = {}, sent = {}, peerAt = {}, peerOrder = {} }
local bridgeOut = { rows = {}, order = {}, queue = {}, sent = {}, outbound = true }
local bridgeFlush
function net:EmitBridgeLK(row, payload)
    local now = GetTime()
    local reached = 0
    -- 1.3.2: one copy on our faction channel reaches every same-faction player
    -- there. The three whispers below date from 1.2.0, when Blizzard refused most
    -- channel traffic; they stay the fallback when the channel is unavailable or
    -- its send budget is spent.
    if sync.SendBridgeLKToChannel and sync:SendBridgeLKToChannel(payload) then
        if IsInGroup() and sync:SendToGroup("LK", payload) then reached = reached + 1 end
        self.stats.bridgeLK = (self.stats.bridgeLK or 0) + 1
        self.stats.bridgeLKChannel = (self.stats.bridgeLKChannel or 0) + 1
        return true
    end
    local candidates = self:GetLocalPeers({ [row.key] = true })
    -- Spread the load: the peers that got a row from this client longest ago first.
    for i = #candidates, 2, -1 do
        local j = math.random(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    table.sort(candidates, function(a, b)
        return (bridgeLK.peerAt[a:lower()] or -1) < (bridgeLK.peerAt[b:lower()] or -1)
    end)
    for i = 1, math.min(BRIDGE_LK_FANOUT, #candidates) do
        local name = candidates[i]
        if sync:SendWhisper("LK", payload, name, true) then
            remember(bridgeLK.peerAt, bridgeLK.peerOrder, name:lower(), now, 256)
            bridgeLK.peerAt[name:lower()] = now
            reached = reached + 1
        end
    end
    if IsInGroup() and sync:SendToGroup("LK", payload) then reached = reached + 1 end
    self.stats.bridgeLK = (self.stats.bridgeLK or 0) + (reached > 0 and 1 or 0)
    return reached > 0
end
-- Opposite-faction Battle.net friends (game account ids), from the cached list.
local function enemyBNetFriends()
    local out, mine = {}, addon.PlayerFaction
    local targets = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
    for _, id in ipairs(targets) do
        local faction = sync.GetBetaBNetTargetInfo and sync:GetBetaBNetTargetInfo(id)
        if (faction == "Alliance" or faction == "Horde") and faction ~= mine then out[#out + 1] = id end
    end
    return out
end
function net:EmitBridgeOut(row, payload)
    local friends, reached = enemyBNetFriends(), 0
    for i = 1, math.min(BRIDGE_LK_FANOUT, #friends) do
        if sync.SendToBNet and sync:SendToBNet(friends[i], "LK", payload) then reached = reached + 1 end
    end
    self.stats.bridgeOut = (self.stats.bridgeOut or 0) + (reached > 0 and 1 or 0)
    return reached > 0
end
-- One timer chain at most per bridge: only its own firing clears `armed`. Direct
-- calls from a new row flush what is ready now and never start a second chain.
bridgeFlush = function(state)
    local now, sent, wait, keep = GetTime(), state.sent, math.huge, {}
    while sent[1] and now - sent[1] >= 60 do table.remove(sent, 1) end
    for _, key in ipairs(state.queue) do
        local row = state.rows[key]
        if row and row.pending and now - row.pendingAt <= 300 then
            local ready = (row.sentAt or -math.huge) + BRIDGE_LK_SUBJECT_GAP
            if not active() then
                wait = math.min(wait, 10)
                keep[#keep + 1] = key
            elseif now < ready then
                wait = math.min(wait, ready - now)
                keep[#keep + 1] = key
            elseif #sent >= BRIDGE_LK_PER_MIN then
                wait = math.min(wait, sent[1] + 60 - now)
                keep[#keep + 1] = key
            else
                local payload, emitted = row.pending, false
                if state.outbound then
                    emitted = net:EmitBridgeOut(row, payload)
                else
                    emitted = net:EmitBridgeLK(row, payload)
                end
                if emitted then
                    row.pending, row.sentAt = nil, now
                    sent[#sent + 1] = now
                else
                    -- nobody to tell right now (no fresh peer or friend): try again shortly
                    wait = math.min(wait, 5)
                    keep[#keep + 1] = key
                end
            end
        elseif row then
            row.pending = nil
        end
    end
    state.queue = keep
    if #keep > 0 and not state.armed then
        state.armed = true
        C_Timer.After(math.max(1, math.min(30, wait)), function()
            state.armed = false
            bridgeFlush(state)
        end)
    end
end
local function queueBridgeRow(state, name, faction, total, before, class, locale, epoch, bucketToken, levelToken)
    total, before = math.floor(tonumber(total) or 0), math.floor(tonumber(before) or 0)
    epoch = math.floor(tonumber(epoch) or 0)
    levelToken, bucketToken, class, locale = tostring(levelToken or ""), tostring(bucketToken or ""),
        tostring(class or ""), tostring(locale or "")
    -- A subject this client did not know before, or a total that did not grow, is
    -- not news: peers only accept rows for subjects they know anyway.
    if before <= 0 or total <= before or epoch <= 0 then return false end
    if not levelToken:match("^%d+$") or not bucketToken:match("^B%d+$")
        or class:find(":", 1, true) or locale:find(":", 1, true) or name:find(":", 1, true) then return false end
    local now, key = GetTime(), name:lower()
    local row = state.rows[key]
    if not row then
        -- First contact: vouch for what this client already held (assumed at most 5
        -- minutes old). Created before the check so that a refused jump is remembered.
        remember(state.rows, state.order, key,
            { key = key, name = name, trusted = before, trustedAt = now - 300 }, BRIDGE_LK_MAX_ROWS)
        row = state.rows[key]
    end
    -- Plausibility against the last total this client vouched for (not against what
    -- it merely accepted): a jump refused here stays refused on the next row, so a
    -- forged total cannot be walked through in two steps.
    if total - row.trusted > BRIDGE_LK_ALLOWANCE + (now - row.trustedAt) then return false end
    local payload = table.concat({ name, tostring(total), class, faction, tostring(epoch), locale,
        "", "0", bucketToken, levelToken }, ":")
    if #payload > 250 then return false end
    row.name, row.trusted, row.trustedAt = name, total, now
    if not row.pending then state.queue[#state.queue + 1] = key end
    row.pending, row.pendingAt, row.pendingTotal = payload, now, total
    if #state.queue > 64 then
        -- The dropped subject must be queueable again on its next accepted row.
        local dropped = state.rows[table.remove(state.queue, 1)]
        if dropped then dropped.pending = nil end
    end
    bridgeFlush(state)
    return true
end
-- Called by Sync:OnReceiveKill once an owner's own K was accepted (score raised).
function net:NoteOwnerKill(name, faction, total, before, class, locale, epoch, bucketToken, levelToken)
    if not active() or type(name) ~= "string" then return false end
    local c, mine = self.context, addon.PlayerFaction
    if (mine ~= "Alliance" and mine ~= "Horde") or (faction ~= "Alliance" and faction ~= "Horde") then
        return false
    end
    if faction == mine then
        -- 1.3.2: an own-faction owner heard first-hand; worth passing on only when
        -- this client has an opposite-faction Battle.net friend to tell.
        if #enemyBNetFriends() == 0 then return false end
        return queueBridgeRow(bridgeOut, name, faction, total, before, class, locale,
            epoch, bucketToken, levelToken)
    end
    -- Enemy owner: only a K that reached us over Battle.net from its owner (the
    -- friend link is what makes this client the bridge).
    if not c or c.transport ~= "BNET" or (tonumber(c.hops) or 0) ~= 0 then return false end
    return queueBridgeRow(bridgeLK, name, faction, total, before, class, locale,
        epoch, bucketToken, levelToken)
end
-- 1.3.2: an enemy total that an opposite-faction Battle.net friend passed on (its
-- own channel heard it from the owner) and that raised our ranking: put it on our
-- channel. Rows heard on the channel never come back here, so there is no loop.
function net:NoteBridgedEnemyTotal(name, faction, total, before, class, locale, epoch, bucketToken, levelToken)
    if not active() or type(name) ~= "string" then return false end
    local mine = addon.PlayerFaction
    if (mine ~= "Alliance" and mine ~= "Horde") or (faction ~= "Alliance" and faction ~= "Horde")
        or faction == mine then return false end
    return queueBridgeRow(bridgeLK, name, faction, total, before, class, locale,
        epoch, bucketToken, levelToken)
end
-- 1.3.2: another bridge already put this total (or a newer one) on our channel:
-- drop our pending copy, so several bridges do not repeat the same row.
function net:NoteChannelBridgeRow(name, total)
    if type(name) ~= "string" then return false end
    local row = bridgeLK.rows[name:lower()]
    total = tonumber(total)
    if not (row and row.pending and total and total >= (row.pendingTotal or math.huge)) then return false end
    row.pending, row.sentAt = nil, GetTime()
    self.stats.bridgeLKCovered = (self.stats.bridgeLKCovered or 0) + 1
    return true
end
function net:Start()
    if not enabled() or self.started then return end
    self.started = true
    local function hello()
        if active() then net:Broadcast("NH", addon.Version) end
    end
    C_Timer.After(3, hello)
    self.ticker = C_Timer.NewTicker(NH_INTERVAL, hello)
end
