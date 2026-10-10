-- Overlord relay (was "BetaNetwork" until 1.8.0; wire kinds BR/BF unchanged):
-- bounded store-and-forward over group/channel and Battle.net.
-- The last hop is authenticated by WoW/BNet. Earlier authors are vouched for by
-- that peer, not cryptographically authenticated by Blizzard. Keep the original
-- author when dispatching so relays never manufacture additional witnesses.
local addon = Overlord
local sync = addon.Sync
local net = { peers = {}, stats = { sent = 0, received = 0, dropped = 0 } }
addon.Relay = net
local allowed = {}
for kind in ("NH SR K EK C ZS ZR ZA CB NR NC NA FA FK LK LR LC LO LOC TV VT VF FR VB MN MS OP OC SH HR HB HA CR CA GR GY GI FC GW GE GP GX GD GM"):gmatch("%S+") do
    allowed[kind] = true
end
local MAX_PACKET, MAX_PATH, TTL = 3600, 4, 120
-- Channel/group fragment size. An addon message carries 255 bytes: "BF:" plus
-- "<id>:<part>:<count>:" leave room for ~228 bytes of packet, but clients up to
-- 1.8.0 refuse a piece longer than 170. Two steps so no version stops reading the
-- others: receivers accept up to FRAGMENT_RECEIVE_MAX now (1.8.1); the sending size
-- goes up in a later version once 1.8.0 is gone. A relayed capture (~185 bytes of
-- wire) then fits one channel message instead of two.
local FRAGMENT_CHUNK, FRAGMENT_RECEIVE_MAX = 170, 230
-- A legal packet (<= MAX_PACKET bytes) needs at most 22 pieces of 170 bytes.
local MAX_FRAGMENTS = 24
-- A legal multi-fragment relay packet can span more than 15 seconds at the
-- reserved 300 B/s share while urgent traffic is continuous. Expire stalled
-- assemblies by inactivity and always by the packet's maximum lifetime.
local ASSEMBLY_IDLE_TIMEOUT = 30
local MAX_BRIDGE_FRIENDS = 5
local MAX_QUEUE = 128
-- Every player re-broadcasts each held outpost every 120 s: an identical routine
-- state is relayed once per 10 min per hop (was 1 min). Any change has a new
-- payload and passes at once.
local ROUTINE_FORWARD_SEC = 600
-- A state changed less than 10 min ago (claimedAt/ts) keeps the old 60 s window:
-- if its first relayed copy was evicted under saturation, the next copy may pass.
local ROUTINE_FRESH_FORWARD_SEC, ROUTINE_FRESH_AGE = 60, 600
-- A capture in progress is ticked every 5 s by EVERY player in the area, and each
-- origin's ticks were relayed. A relayed tick never counts as capture-credit
-- evidence (direct copies only), so far peers only need the site's progress:
-- one forward per (site, attacking guild, faction) per OP_PROGRESS_FORWARD_SEC,
-- whichever origin. A new attacker has another key and passes at once.
local OP_PROGRESS_FORWARD_SEC = 15
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
    return p.kind == "HR" or p.kind == "HB" or p.kind == "HA"
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
        and (p.payload:sub(1, 2) == "5:" or p.payload:sub(1, 2) == "6:" or p.payload:sub(1, 2) == "7:"
            or p.payload:sub(1, 2) == "8:")
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
-- Our own kill total (K) is absolute: in a fight it is queued every 2 s, about
-- 1.6 KB each with five bridges, more than the 1,000 B/s budget drains. A newer
-- unsent total for the same zone takes the waiting one's place (nothing is lost:
-- only the latest total counts). A total carrying the owner's race (13 fields,
-- every 10 min) is never replaced by one without it.
local function killFieldCount(payload)
    local _, colons = payload:gsub(":", "")
    return colons + 1
end
-- The channel takes one own total every 30 s (Sync:ChannelCarries): a waiting total
-- holding that copy is never replaced, or the fight's first total never reached the
-- channel (nor the score bridges that read it there).
local function holdsChannelCopy(item)
    for _, task in ipairs(item.tasks) do
        if task.transport == "CHANNEL" then return true end
    end
    return false
end
local function waitingKillItem(p)
    if p.kind ~= "K" or p.target ~= "*" or #p.path ~= 1 or type(p.payload) ~= "string" then return nil end
    local zone = p.payload:match("^[^:]*:([^:]*):")
    if not zone then return nil end
    local withRace = killFieldCount(p.payload) >= 13
    local origin = p.path[1]:lower()
    for i = bulkLane.head, #bulkLane.items do
        local item = bulkLane.items[i]
        local q = item and item.p
        if q and item.index == 1 and not item.tasks[1].sending and q.kind == "K" and q.target == "*"
            and #q.path == 1 and q.path[1]:lower() == origin
            and q.payload:match("^[^:]*:([^:]*):") == zone
            and (withRace or killFieldCount(q.payload) < 13) and not holdsChannelCopy(item) then
            return item
        end
    end
    return nil
end
-- Place pour un terminal : d'abord une presence (NH), puis un tick de progression
-- relaye pour un autre, et seulement en dernier recours un tick de NOTRE capture
-- (chemin a un seul noeud) : a 60 s de cadence en gros event, le perdre annulait la
-- vague chez les observateurs.
local function dropWaitingForTerminal()
    for pass = 1, 3 do
        for i = urgentLane.head, #urgentLane.items do
            local item = urgentLane.items[i]
            if item and item.index == 1 and not item.tasks[1].sending then
                local p = item.p
                local victim = pass == 1 and p.kind == "NH"
                    or (pass >= 2 and p.kind == "ZS" and (pass == 3 or #p.path > 1)
                        and p.payload:match("^[^:]+:([^:]+):") == "in_progress")
                if victim then
                    table.remove(urgentLane.items, i)
                    forgetPresence(item)
                    countKind(p.kind, "dropped")
                    return true
                end
            end
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
-- Packets already handled (origin:id). A late copy (bridge hold, queue wait, other
-- path) must still find its entry: at 2,048 a busy channel recycled the ring in
-- ~10 s and duplicates were handled and forwarded again. ~1 MB at 8,192.
-- Ring sizes are never a power of two: a full Lua 5.1 table holding exactly 2^k
-- keys rehashes on every evict-and-insert (measured: ~150 us per packet at 8,192).
local SEEN_RING = 8000
-- Per-player memories whose rule spans minutes (heard on our channel within 300 s,
-- presence forwarded once per 90 s): sized for a launch channel of thousands, not
-- the beta's hundreds (256/512 recycled within seconds and the rules stopped acting).
local PLAYER_RING = 4000
-- Neighbour routes (300 s). A map reply (up to 32 pages at the catch-up rate) lasts
-- about 30 s and every page needs the requester's route: at 512 a launch channel
-- recycled the table in seconds and the later pages of a map were refused, as were
-- whispered ranking pages and activity replies from "unknown" peers (~3 MB at 8,192).
local PEER_RING = 8000
-- Capabilities advertised in first-hand presence (300 s): at 512 most neighbours
-- looked unknown and every ranking pull fell back to a full v7 sweep instead of v8.
local CAPABILITY_RING = 8000
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
-- Relayed presence (NH that already crossed a hop) only keeps routes alive (300 s TTL,
-- refreshed by every relayed packet of the origin); since 1.7.5 the paged capability
-- comes only from the origin's own first-hand NH.
-- The origin's own copies keep the full fan-out. A hop forwards to every opposite-faction
-- bridge plus NH_RELAY_SLOTS rotating friend (was up to 3), and puts it on the realm channel
-- only for an origin that is not audible there (was every hop and every beat): channel
-- mates already hear the origins on their channel themselves. An origin reachable only
-- through a hop keeps one channel copy per forwarded beat: routes live 300 s and must
-- survive one lost copy.
local NH_RELAY_SLOTS = 1
-- Opposite-faction friends not heard yet that one own presence beat probes (in
-- rotation): 40 friends are all probed within five beats, never in one burst.
local PRESENCE_PROBES = 8
-- A presence capability is only a protocol hint, never proof of an origin's
-- identity or authority. Generic traffic may refresh a route, but not this TTL.
local pagedCapabilities, pagedCapabilityOrder = {}, {}
local seenOrder, recentOrder, assemblyOrder, peerOrder = {}, {}, {}, {}
local function IsPagedSessionPeer(key)
    return sync.IsPagedSessionPeer ~= nil and sync:IsPagedSessionPeer(key) == true
end
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
-- Packet ids are "<session>-<serial>", unique per origin. Base 36 (11 characters
-- instead of 21): ten bytes less in every packet and every fragment header, so
-- more captures and alerts fit one fragment (one channel message instead of two).
local function base36(n, width)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    n = tonumber(n) or 0
    if not (n >= 0) or n == math.huge then n = 0 end
    n = math.floor(n)
    repeat
        local d = n % 36
        out = digits:sub(d + 1, d + 1) .. out
        n = math.floor(n / 36)
    until n == 0
    return string.rep("0", (width or 0) - #out) .. out
end
local session = base36(time()) .. base36(math.random(0, 60466175), 5)
-- Map freshness (1.8.1): the newest confirmed capture this client knows, by its event
-- time (identical on every client that holds it). Own presence advertises it as
-- "~m<base 36>"; a neighbour's presence triggers a full map pull only when it knows a
-- newer capture (it used to pull on every new neighbour, about one full map a minute
-- per client on a busy channel, and from whoever spoke, not from who had the news).
local mapStampCache = { at = -1000, value = 0 }
local function localMapStamp()
    local now = GetTime()
    if now - mapStampCache.at < 5 then return mapStampCache.value end
    local best = 0
    local registry = addon.Fronts and addon.Fronts.Registry
    for _, front in pairs(registry or {}) do
        for _, zone in ipairs(type(front) == "table" and front.zones or {}) do
            if zone.owner and zone.status ~= "in_progress" and not zone._loginSyncUnconfirmed then
                local ct = math.floor(tonumber(zone.capturedTime) or 0)
                if ct > best then best = ct end
            end
        end
    end
    mapStampCache.at, mapStampCache.value = now, best
    return best
end
-- Packet dates use Blizzard's shared server clock: a PC clock more than 30 s
-- ahead made every relayed packet from that player invisible to all others.
local function serverNow() return (GetServerTime and GetServerTime()) or time() end
local function enabled() return addon.RelayEnabled ~= false end
local function active() return enabled() and not addon.InstanceSuspended and not IsInInstance() end
-- Battle.net friends heard from (any Overlord message, game account id -> time).
-- Only a friend running Overlord outside an instance sends anything: those are
-- the real bridges. A friend without the addon, or one inside an instance (it
-- drops everything it gets), only wasted the 1000 B/s budget when it sat among
-- the first five of the friend list. Own presence goes out every 120 s, so a
-- live bridge is heard again well within this window.
local BNET_ALIVE_SEC = 300
local bnetHeard, bnetHeardCount = {}, 0
local function noteBNetHeard(id)
    if id == nil then return end
    if bnetHeard[id] == nil then
        -- Bounded at 64 game accounts: every Battle.net sender lands here, same-faction
        -- friends and friends beyond our 40 included. Full: forget the stale ones, else
        -- the one heard longest ago (a friend who just spoke is always recorded).
        if bnetHeardCount >= 64 then
            local now, oldestKey, oldestAt = GetTime(), nil, nil
            for key, at in pairs(bnetHeard) do
                if now - at > BNET_ALIVE_SEC then
                    bnetHeard[key] = nil; bnetHeardCount = bnetHeardCount - 1
                elseif not oldestAt or at < oldestAt then
                    oldestKey, oldestAt = key, at
                end
            end
            if bnetHeardCount >= 64 and oldestKey then
                bnetHeard[oldestKey] = nil; bnetHeardCount = bnetHeardCount - 1
            end
        end
        bnetHeardCount = bnetHeardCount + 1
    end
    bnetHeard[id] = GetTime()
end
local function bnetAlive(id)
    local at = id ~= nil and bnetHeard[id] or nil
    return at ~= nil and GetTime() - at <= BNET_ALIVE_SEC
end
function net:NoteBNetHeard(id) noteBNetHeard(id) end
function net:IsBNetFriendAlive(id) return bnetAlive(id) end
function net:HasLiveEnemyBridge()
    local mine = addon.PlayerFaction
    if mine ~= "Alliance" and mine ~= "Horde" then return false end
    local targets = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
    for _, id in ipairs(targets) do
        local faction = sync.GetBetaBNetTargetInfo and sync:GetBetaBNetTargetInfo(id)
        if (faction == "Alliance" or faction == "Horde") and faction ~= mine and bnetAlive(id) then
            return true
        end
    end
    return false
end
local function region() return addon.RealmPools:GetOverlordPoolTag() end
local function canonical(name) return sync:CanonicalForeverName(name) end
local function same(a, b) return sync:ForeverIdentitiesMatch(a, b) end
-- FIFO ring (order.first..order.last): same eviction order as before, but O(1).
-- Removing the first array slot shifted up to 2048 keys for every received packet.
local function remember(values, order, key, value, limit, keep)
    if values[key] == nil then
        local first, last = order.first or 1, order.last or 0
        local count = last - first + 1
        if count >= limit then
            -- keep (neighbour table only, 1.8.0): the peers of a running ranking
            -- session move to the newest end instead of being forgotten. On a busy
            -- channel an entry lived ~12 s (5,000 members, 512 entries), shorter
            -- than a page exchange: replies left unrouted and were dropped.
            local rotated = 0
            while keep and rotated < count and keep(order[first]) do
                last = last + 1
                order[last], order[first] = order[first], nil
                first, rotated = first + 1, rotated + 1
            end
            if rotated < count then
                values[order[first]] = nil
                order[first] = nil
                first = first + 1
            end
        end
        last = last + 1
        order[last] = key
        order.first, order.last = first, last
    end
    values[key] = value
end
-- Held forwards (1.4.2). Two cases share one mechanism:
--  * bridge: a broadcast that reached this client over Battle.net reached every
--    other bridge of the faction in the same second; each one then put its copy on
--    the channel (only the LK bridge had an election). Wait 2-15 s (1-4 s for a
--    terminal event) before forwarding. A copy heard on the channel meanwhile means
--    another bridge did it: our channel copy is dropped, the Battle.net copies to
--    friends the channel cannot reach still go out.
--  * group: a broadcast heard on the channel is heard by our group mates too, except
--    the ones whose channel join failed. Instead of 40 raid copies per packet, the
--    group copy waits the same window and is dropped if a mate's copy is heard in the
--    raid/party first.
-- Entries are counted, never evicted: a forward in flight is never lost; above the
-- cap the packet is forwarded at once. Tests set BridgeChannelHold to { 0, 0 }.
-- djb2 over the text, spread by the golden ratio into [0, 1): names differing only
-- in their last letters map to neighbouring hashes, which a plain modulus kept
-- clustered. Shared by the held forwards and the LK bridge election.
local function hashFrac(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return (h * 0.6180339887498949) % 1
end
-- Bridge election (launch scale). Every same-faction client that hears a broadcast
-- forwards it once, Battle.net legs included: with hundreds of players holding a
-- live opposite-faction friend, each routine packet crossed hundreds of times and
-- burnt everyone's 1,000 B/s budget. Clients with a live enemy bridge say so in
-- their own presence ("~b"); each client counts those it heard first-hand in the
-- last 5 min. Up to CROSS_FULL_BRIDGES nothing changes (every hearer crosses, as
-- on the beta). Above, a forwarder crosses a ROUTINE packet only when a hash of
-- (itself, origin, packet id) falls under CROSS_TARGET / bridges: about four
-- forwarders per packet, a different set for each packet. Never elected away: the
-- origin's own copies, terminal events (captures, releases, victories), and the
-- channel/group/same-faction copies. Transport only, never acceptance.
local CROSS_FULL_BRIDGES, CROSS_TARGET, CROSS_MIN_SHARE = 8, 4, 0.02
local CROSS_ELECTED_KINDS = { NH = true, SH = true, ZS = true, OP = true, GW = true,
    FK = true, MN = true, MS = true, GP = true }
local sameFactionBridges, sameFactionBridgesOrder = {}, {}
local bridgeCountCache = { at = -1000, value = 0 }
local function sameFactionBridgeCount()
    local now = GetTime()
    if now - bridgeCountCache.at < 10 then return bridgeCountCache.value end
    local count = 0
    for _, at in pairs(sameFactionBridges) do
        if now - at <= 300 then count = count + 1 end
    end
    bridgeCountCache.at, bridgeCountCache.value = now, count
    return count
end
local function crossShare()
    local bridges = sameFactionBridgeCount()
    if bridges <= CROSS_FULL_BRIDGES then return 1 end
    return math.max(CROSS_TARGET / bridges, CROSS_MIN_SHARE)
end
local function crossElected(p)
    if #p.path < 2 or not CROSS_ELECTED_KINDS[p.kind] or isTerminal(p) then return true end
    -- A siege start (defenders' early warning) and an assault given up (neutral
    -- outpost) are rare and matter: never elected away either.
    if type(p.payload) == "string" then
        if p.kind == "ZS" and (tonumber(p.payload:match("^[^:]+:in_progress:[^:]*:(%d+):")) or 999) <= 10 then
            return true
        end
        if p.kind == "OP" and p.payload:match("^v%d+:[^:]*:([^:]*)") == "neutral" then return true end
    end
    local share = crossShare()
    if share >= 1 then return true end
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    return hashFrac(tostring(me):lower() .. "|" .. tostring(p.path[1]):lower()
        .. "|" .. tostring(p.id)) < share
end
function net:GetCrossElection() return sameFactionBridgeCount(), crossShare() end
local heldForwards, heldCount = {}, { bridge = 0, group = 0 }
local HELD_FORWARD_MAX = { bridge = 256, group = 128 }
local function holdForward(key, p, mode)
    local hold = net.BridgeChannelHold or {}
    local lo, hi = tonumber(hold[1]) or 0, tonumber(hold[2]) or 0
    if heldForwards[key] then return true end
    if hi <= 0 or heldCount[mode] >= HELD_FORWARD_MAX[mode] then return false end
    -- Only a client with a channel is a bridge to it; elsewhere forward at once.
    if mode == "bridge" and not (sync.GetChannelId and sync:GetChannelId()) then return false end
    -- Terminal events and urgent ones (siege start, active capture, call to arms)
    -- wait 1-4 s only: a Battle.net alert reached remote defenders ~8 s late.
    if isTerminal(p) or isUrgent(p) then lo, hi = math.min(lo, 1), math.min(hi, 4) end
    -- One delay per (client, origin) pair, not per packet: packets of the same
    -- origin keep their order through the hold (TV before VB), while different
    -- clients spread over the window.
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    local frac = hashFrac(tostring(me):lower() .. "|" .. tostring(p.path[1] or ""):lower())
    local entry = { p = p, mode = mode }
    heldForwards[key] = entry
    heldCount[mode] = heldCount[mode] + 1
    C_Timer.After(lo + frac * math.max(0, hi - lo), function()
        if heldForwards[key] ~= entry then return end
        heldForwards[key] = nil
        heldCount[mode] = heldCount[mode] - 1
        if entry.heard then
            if mode == "group" then return end
            -- Keep only what the channel cannot reach: enemy bridges and friends
            -- never heard on our channel.
            p.skipChannel, p.skipGroup, p.heardOn = true, true, "CHANNEL"
        end
        if net:Queue(p) == true then
            local stat = mode == "group" and "groupCopiesSent" or "bridgeForwardsSent"
            net.stats[stat] = (net.stats[stat] or 0) + 1
        elseif mode == "bridge" then
            remember(forwardRetry, forwardRetryOrder, key, GetTime(), 250)
        end
    end)
    return true
end
-- A copy of a held packet heard on the channel (bridge entry) or in the group
-- (group entry): someone else carried it there. Only the id and the origin are
-- read from the wire, without copying its body.
local function noteHeardCopy(wire, transport)
    if type(wire) ~= "string" then return end
    if transport ~= "CHANNEL" and transport ~= "RAID" and transport ~= "PARTY" then return end
    if heldCount.bridge + heldCount.group == 0 then return end
    local id, origin = wire:match("^[^|]*|([^|]*)|[^|]*|[^|]*|([^|,]*)")
    if not id or not origin or origin == "" then return end
    local key = origin:lower() .. ":" .. id
    if transport == "CHANNEL" then
        local entry = heldForwards[key]
        if entry and not entry.heard then
            entry.heard = true
            net.stats.bridgeForwardsCancelled = (net.stats.bridgeForwardsCancelled or 0) + 1
        end
    elseif transport == "RAID" or transport == "PARTY" then
        local entry = heldForwards["G:" .. key]
        if entry and not entry.heard then
            entry.heard = true
            net.stats.groupCopiesCancelled = (net.stats.groupCopiesCancelled or 0) + 1
        end
    end
end
-- Duplicate check on the raw wire, before decode and identity work. Same key as
-- Receive records (origin = first path node, which decode requires canonical).
-- A seal holds the packet's origin timestamp: a copy is a duplicate only when its
-- origin:id AND its timestamp match. The origin of a relayed copy is not
-- authenticated and ids are predictable (session + serial): a forged relayed copy
-- carrying a victim's next ids used to seal them on every hearer and silence the
-- victim's genuine packets.
-- Seal of a handled packet: its origin time AND a sample of its content (kind, then
-- length and first/last 48 bytes of the payload). Ids are predictable (session +
-- serial): a forged relayed copy reusing a victim's next id in the same second only
-- seals itself, the genuine packet (whose content the forger cannot know) is still
-- handled. Every copy of one packet carries the same kind and payload.
local SEAL_MOD = 1048573
local function sealRange(s, from, to, h)
    local stop = math.min(to, from + 47)
    for i = from, stop do h = (h * 31 + s:byte(i)) % SEAL_MOD end
    for i = math.max(stop + 1, to - 47), to do h = (h * 31 + s:byte(i)) % SEAL_MOD end
    return (h * 31 + math.max(0, to - from + 1)) % SEAL_MOD
end
-- origin time * 2^20 + sample (exact below 2^53 for any 21st-century date)
local function sealOf(at, kind, payload)
    local h = sealRange(kind, 1, #kind, 7)
    return math.floor(tonumber(at) or 0) * 1048576 + sealRange(payload, 1, #payload, h)
end
-- Same value from the raw wire's "kind|payload" tail, without splitting it.
local function sealOfBody(at, body)
    local bar = body:find("|", 1, true)
    if not bar then return nil end
    local h = sealRange(body, 1, bar - 1, 7)
    return math.floor(tonumber(at) or 0) * 1048576 + sealRange(body, bar + 1, #body, h)
end
local function alreadySeen(wire, sender)
    if type(wire) ~= "string" then return false end
    local pool, id, at, target, path, body = strsplit("|", wire, 6)
    local origin = path and path:match("^[^,]+")
    local sealed = id ~= nil and origin ~= nil and seen[origin:lower() .. ":" .. id] or nil
    local known = sealed ~= nil and type(body) == "string" and sealed == sealOfBody(at, body)
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
-- (GR, CR; a relayed one is ignored on arrival anyway) follow the same rule.
-- Guild identity (GI) is never relayed either: OnReceiveGuildIdentity only
-- applies the owner's own direct copy (KillSyncSenderOwnsPlayer rejects any relayed
-- origin), so forwarded GI was dropped by every receiver while costing about a
-- quarter of relay bytes (2026-10-01). The owner still sends its own copies to its
-- channel, group and Battle.net friends.
local CATCHUP_KINDS = {}
for kind in ("SR ZA HR HA HB LK LC LR LO LOC GY CA GR CR"):gmatch("%S+") do CATCHUP_KINDS[kind] = true end
local function isPointToPointCatchup(kind, target)
    return CATCHUP_KINDS[kind] == true and target ~= nil and target ~= "*"
end
function net:IsDirectPeer(name)
    return self:GetPeerHops(name) == 1
end
-- Direct neighbours to pick catch-up partners from (callers keep one to three): at
-- most DIRECT_PEER_SAMPLE live routes read around the route ring from a random
-- place (every neighbour equally likely; walking from the newest end made every
-- client ask the same recent logins), plus every Battle.net friend's route, sorted
-- by name. With a launch-size table (8,000) every caller sorted thousands of names.
local DIRECT_PEER_SAMPLE = 250
function net:GetDirectPeers()
    local now, names, taken = GetTime(), {}, {}
    local function take(row)
        if row and not taken[row] and now - row.at <= 300 and tonumber(row.hops) == 1 then
            taken[row] = true
            names[#names + 1] = row.name
        end
    end
    local first, last = peerOrder.first or 1, peerOrder.last or 0
    if last - first + 1 <= DIRECT_PEER_SAMPLE then
        -- Small table: every route (cheap, and independent of the ring's order).
        for _, row in pairs(self.peers) do take(row) end
    else
        local size = last - first + 1
        local start = math.random(0, size - 1)
        for step = 0, size - 1 do
            if #names >= DIRECT_PEER_SAMPLE then break end
            local key = peerOrder[first + (start + step) % size]
            if key then take(self.peers[key]) end
        end
    end
    local targets = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
    for _, id in ipairs(targets) do
        local _, character = nil, nil
        if sync.GetBetaBNetTargetInfo then _, character = sync:GetBetaBNetTargetInfo(id) end
        if type(character) == "string" then take(self.peers[character:lower()]) end
    end
    table.sort(names)
    return names
end
-- Relais en service (option activee) : la taille des combats est alors partagee.
function net:IsEnabled() return enabled() end
-- Every live direct route (GetDirectPeers only returns a sample). Read for
-- every broadcast request received (answer chance): kept 5 s, the table holds
-- thousands of neighbours at launch.
local directCountCache = { at = -1000, value = 0, peers = nil }
function net:CountDirectPeers()
    local now = GetTime()
    if directCountCache.peers == self.peers and now - directCountCache.at < 5 then
        return directCountCache.value
    end
    local count = 0
    for _, row in pairs(self.peers) do
        if now - row.at <= 300 and tonumber(row.hops) == 1 then count = count + 1 end
    end
    directCountCache.at, directCountCache.value, directCountCache.peers = now, count, self.peers
    return count
end
function net:GetPeerPagedProtocol(name)
    local key = canonical(name)
    local row = key and pagedCapabilities[key:lower()]
    if not row or GetTime() - row.at > 300 then return nil end
    return row.version
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
    lines[#lines + 1] = string.format("Catch-up detail now: %d map, %d paged v5-v7 (max %d), %d legacy/other; paged producer backpressure checks: %d.",
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
    lines[#lines + 1] = string.format("Waiting SR duplicates coalesced: %d (same origin/target only). Guild identities not relayed: %d. Outpost repeats not relayed: %d routine, %d progress. Waiting kill totals replaced by a newer one: %d.",
        self.stats.mapRequestsCoalesced or 0, self.stats.giForwardSkipped or 0,
        self.stats.routineForwardSkipped or 0, self.stats.progressForwardSkipped or 0,
        self.stats.killCoalesced or 0)
    -- 1.3.2 cross-faction live totals: what reached us, and what our own bridge did.
    lines[#lines + 1] = string.format("Enemy live totals received: %d from the channel, %d from Battle.net friends"
        .. " (their own kills: %d). Your bridge: %d posted on the channel, %d sent to enemy friends,"
        .. " %d skipped (already on the channel). Bridge share: %d%% (%d held back as fallback).",
        self.stats.enemyTotalsFromChannel or 0, self.stats.enemyTotalsFromFriends or 0,
        self.stats.enemyFriendKills or 0, self.stats.bridgeLKChannel or 0,
        self.stats.bridgeOut or 0, self.stats.bridgeLKCovered or 0,
        math.floor((net.GetBridgeShare and net:GetBridgeShare() or 1) * 100 + 0.5),
        self.stats.bridgeLKDeferred or 0)
    local enemies, live = 0, 0
    local targets = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
    for _, id in ipairs(targets) do
        local faction = sync.GetBetaBNetTargetInfo and sync:GetBetaBNetTargetInfo(id)
        if (faction == "Alliance" or faction == "Horde") and faction ~= addon.PlayerFaction then
            enemies = enemies + 1
            if bnetAlive(id) then live = live + 1 end
        end
    end
    lines[#lines + 1] = string.format("Battle.net bridges: %d of %d opposite-faction friends heard in the last %d min"
        .. " (the others only get rotating copies).", live, enemies, BNET_ALIVE_SEC / 60)
    lines[#lines + 1] = string.format("Map pulls on a neighbour's presence skipped (it knew no newer capture): %d.",
        self.stats.mapPullsNoNews or 0)
    lines[#lines + 1] = string.format("Bridge election: %d same-faction bridges heard, crossing share %d%%"
        .. " (100%% up to %d), %d enemy copies of routine traffic and %d score rows left to the elected forwarders;"
        .. " %d captures not sent back to the side that made them.",
        sameFactionBridgeCount(), math.floor(crossShare() * 100 + 0.5), CROSS_FULL_BRIDGES,
        self.stats.crossElectionSkipped or 0, self.stats.bridgeOutElectedAway or 0,
        self.stats.captureBackSkipped or 0)
    local lb = addon.Leaderboard
    if lb and lb.GetHotIndexStats then
        local h = lb:GetHotIndexStats()
        lines[#lines + 1] = string.format("Ranking index rebuilds: %d full + %d meta-only finished;"
            .. " %d refreshed later (change not replayable); restarted %d.",
            h.completed or 0, h.metaOnly or 0, h.metaDrift or 0, h.abortedOther or 0)
    end
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
-- FR : meme contenu "front:epoque" chez tous les clients qui terminent la treve.
-- FK : meme palier dans la meme tranche de 30 s chez tous ceux qui l'annoncent.
local DEDUP_KINDS = { OP = true, LO = true, LOC = true, VB = true, TV = true, FR = true, FK = true }
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
    local ckey, pathFriends, trimmed, coverId, coverCarrier, groupSuppressed, unheard
    -- Same test as the lanes (v5, v6 and v7 pages): a page is never broadcast.
    local paged = isPagedCatchup(p)
    local count = math.ceil(#wire / FRAGMENT_CHUNK)
    for i = 1, count do
        fragments[i] = p.id .. ":" .. i .. ":" .. count .. ":"
            .. wire:sub((i - 1) * FRAGMENT_CHUNK + 1, i * FRAGMENT_CHUNK)
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
    if p.groupOnly then
        if IsInGroup() then
            for _, fragment in ipairs(fragments) do add("GROUP", fragment, "BF") end
        end
        return tasks, #tasks == 0 and "no_transport" or nil
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
        -- only handles DEDUP_KINDS.)
        local chanCover = channelCopy and not isTerminal(p)
            and { kind = p.kind, payload = p.payload, origin = p.path[1] } or nil
        -- A terminal event relayed for someone else (an enemy capture that just came
        -- over Battle.net, typically) takes a priority channel token like the
        -- origin's own copy: it no longer waits behind this client's routine traffic.
        local chanCritical = channelCopy and isTerminal(p) and #p.path > 1
        local now, rec, trim, groupAgain, channelAgain = GetTime()
        ckey = dedup.key(p)
        if ckey then
            rec = dedup.records[ckey]
            pathFriends, trimmed = {}, 0
            -- Only copies relayed for others are trimmed, never our own broadcast.
            -- FK : copies identiques coupees meme hors charge (une rafale de joueurs
            -- franchit le meme palier en meme temps).
            trim = #p.path > 1 and (p.kind == "FK" or dedup.busy(p))
            groupAgain = rec ~= nil and dedup.count(rec.carriers.group, now) >= COVER_COPIES
            channelAgain = rec ~= nil and dedup.count(rec.carriers.channel, now) >= COVER_COPIES
        end
        -- Meme reserve Blizzard que le canal : pas de copie de fond au groupe pour une
        -- diffusion. Un paquet adresse (reponse de rattrapage a un coequipier joint par
        -- le groupe) garde sa copie : c'est parfois sa seule livraison.
        local groupCopy = not p.skipGroup
            and (p.target ~= "*" or not sync.GroupCarries or sync:GroupCarries(p.kind, p.payload))
        groupSuppressed = not p.skipGroup and not groupCopy
        for _, fragment in ipairs(fragments) do
            if groupCopy then
                if trim and groupAgain then trimmed = trimmed + 1
                elseif not (trim and not IsInGroup()) then coverCarrier = "group"; add("GROUP", fragment, "BF") end
            end
            if channelCopy then
                if trim and channelAgain then trimmed = trimmed + 1
                elseif not (trim and sync.GetChannelId and not sync:GetChannelId()) then
                    coverCarrier = "channel"
                    local task = add("CHANNEL", fragment, "BF")
                    task.chanCover, task.critical = chanCover, chanCritical
                end
            end
        end
        coverCarrier = nil
        -- Opposite-faction friends are the only Horde/Alliance bridges: each packet
        -- reaches the live ones (heard from within BNET_ALIVE_SEC, bounded). The
        -- other opposite-faction friends (no addon, in an instance, not heard yet)
        -- join the rotating slots, so a bridge that comes online is still found.
        -- Same-faction friends already hear it on the channel and share the same
        -- rotating slots. Friends already on the path have the packet and are skipped.
        -- Our own presence (one small NH every 120 s) also goes to PRESENCE_PROBES
        -- opposite-faction friends not heard yet, in rotation: two friends running
        -- Overlord find each other within a few beats (five with 40 silent friends),
        -- then exchange everything as live bridges.
        local friends = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
        local myFaction = addon.PlayerFaction
        local ownPresence = p.kind == "NH" and #p.path == 1
        -- A call to arms (FC) is only ever shown to its own faction: the other
        -- faction's bridges dropped it after spending budget and a channel slot.
        local ownFactionOnly = p.kind == "FC"
        -- A capture (C, or ZS in progress / captured) is only ever accepted from its
        -- author: relayed for someone else, the side that made it already has it, and
        -- a copy sent back there over Battle.net only burnt the bridge's budget.
        local backToCapturer = false
        if #p.path > 1 and (p.kind == "C" or p.kind == "ZS") and type(p.payload) == "string"
            and (myFaction == "Alliance" or myFaction == "Horde") then
            local side
            if p.kind == "C" then
                side = p.payload:match("^[^:]*:[^:]*:([^:]*):")
            else
                local status, code = p.payload:match("^[^:]*:([^:]*):[^:]*:[^:]*:([AH]):")
                if status == "in_progress" or status == "captured" then
                    side = code == "A" and "Alliance" or "Horde"
                end
            end
            backToCapturer = (side == "Alliance" or side == "Horde") and side ~= myFaction
        end
        local crossing = ownFactionOnly or crossElected(p)
        local bridges, others, probes = {}, {}, {}
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
                local enemy = (faction == "Alliance" or faction == "Horde")
                    and (myFaction == "Alliance" or myFaction == "Horde") and faction ~= myFaction
                local alive = enemy and bnetAlive(id)
                if enemy and ownFactionOnly then
                    net.stats.ownFactionOnlySkipped = (net.stats.ownFactionOnlySkipped or 0) + 1
                elseif enemy and backToCapturer then
                    net.stats.captureBackSkipped = (net.stats.captureBackSkipped or 0) + 1
                elseif enemy and not crossing then
                    net.stats.crossElectionSkipped = (net.stats.crossElectionSkipped or 0) + 1
                elseif alive and #bridges < MAX_BRIDGE_FRIENDS then
                    bridges[#bridges + 1] = id
                elseif enemy and not alive and ownPresence then
                    probes[#probes + 1] = id
                else
                    -- A same-faction friend we hear on our channel heard this channel
                    -- copy too; only friends on another realm (never on our channel)
                    -- still need the Battle.net copy.
                    local heardAt = p.heardOn == "CHANNEL" and type(character) == "string"
                        and channelHeard[character:lower()] or nil
                    if heardAt ~= nil and GetTime() - heardAt <= 300 then
                        net.stats.friendCopiesOnChannelSkipped = (net.stats.friendCopiesOnChannelSkipped or 0) + 1
                    elseif #p.path > 1 and not bnetAlive(id) then
                        -- A copy relayed for someone else rotates among friends heard
                        -- under Overlord only: every hearer forwards it, and three
                        -- copies each to friends without the addon (or on another
                        -- ruleset, or in an instance) filled queues at launch scale.
                        -- Our own packets keep the full rotation and the presence
                        -- probes, which find new bridges.
                        unheard = true
                        net.stats.friendCopiesUnheardSkipped = (net.stats.friendCopiesUnheardSkipped or 0) + 1
                    else
                        others[#others + 1] = id
                    end
                end
            end
        end
        -- Same selection as ever: every bridge, then `slots` rotating friends
        -- (the cursor advances identically). Coverage only adds substitutes and,
        -- while busy, removes repeats.
        local entries, picked = {}, {}
        for _, id in ipairs(bridges) do entries[#entries + 1] = { id = id } end
        if #probes > 0 then
            local start = net.probeCursor or 0
            for i = 1, math.min(PRESENCE_PROBES, #probes) do
                entries[#entries + 1] = { id = probes[(start + i - 1) % #probes + 1] }
            end
            net.probeCursor = (start + math.min(PRESENCE_PROBES, #probes)) % #probes
        end
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
    end
    if ckey then tasks.cover = { key = ckey, path = pathFriends } end
    if trimmed and trimmed > 0 then
        -- Everything this copy would send is already covered and the queue is busy.
        if #tasks == 0 then return tasks, "redundant" end
        net.stats.contentDedupTrimmed = (net.stats.contentDedupTrimmed or 0) + trimmed
    end
    -- Only a background group copy was left out on purpose: not a loss.
    if #tasks == 0 and groupSuppressed then return tasks, "suppressed" end
    -- Only friends never heard under Overlord were left: not a loss either.
    if #tasks == 0 and unheard then return tasks, "unheard" end
    return tasks, #tasks == 0 and (routeFailure or "no_transport") or nil
end
local function emit(task)
    task.spent = nil
    if task.skip then return true end
    -- Missing optional local paths are not send failures; a throttled channel
    -- that is present must, however, retry the same fragment.
    if task.transport == "GROUP" and not IsInGroup() then
        return true
    end
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
        -- Priority token for relayed terminals, at most one every 1.25 s: a burst
        -- (truce end, victory) would otherwise outrun Blizzard's ~1 msg/s and be refused.
        local critical = false
        if task.critical == true and GetTime() - (net._lastRelayCriticalAt or -10) >= 1.25 then
            critical = true
            net._lastRelayCriticalAt = GetTime()
        end
        sent, reason = sync:SendToChannel(task.kind, task.data, critical)
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
    if reason == "suppressed" then
        net.stats.groupCopySuppressed = (net.stats.groupCopySuppressed or 0) + 1
        return true
    end
    if reason == "unheard" then return true end
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
    -- A held group-only copy must never replace the full forward of the same packet.
    local statePrevious = not p.groupOnly and waitingStateItem(p) or nil
    if statePrevious and p.at < statePrevious.p.at then return true end
    local replace = previous and previous.index == 1
        and not previous.tasks[1].sending and p.at >= previous.p.at
    if statePrevious then previous, replace = statePrevious, true end
    if requestPrevious then
        previous, replace = requestPrevious, p.at >= requestPrevious.p.at
        if not replace then return true end
    end
    local outpostPrevious = not previous and not p.groupOnly and waitingOutpostItem(p) or nil
    if outpostPrevious then
        previous, replace = outpostPrevious, p.at >= outpostPrevious.p.at
        if not replace then return true end
    end
    local killPrevious = not previous and not p.groupOnly and waitingKillItem(p) or nil
    if killPrevious then
        previous, replace = killPrevious, p.at >= killPrevious.p.at
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
        if killPrevious then
            self.stats.killCoalesced = (self.stats.killCoalesced or 0) + 1
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
    -- The startup heartbeat calls Broadcast with the plain addon version.
    -- Annotate at the producer boundary.
    -- "~lr" (1.7.0): ranking pages v7, race in each score row. It stays before
    -- "~lp6" because older clients only read the suffix and still see lp6.
    -- "~ld" (1.8.0): ranking pages v8 (only differing rows); v7 clients still read v7.
    -- "~b" (1.8.1): we hold a live opposite-faction Battle.net bridge (election
    -- below). Inserted before "~ld~lr~lp6", which older clients still find.
    -- "~l9" (1.8.1): ranking capability 9, v8 pages with the Skyborne race; peers
    -- advertising less are neither asked nor served (SyncLeaderboardPages).
    if kind == "NH" and payload == tostring(addon.Version or "") then
        local stamp = localMapStamp()
        payload = payload .. (self:HasLiveEnemyBridge() and "~b" or "")
            .. "~m" .. base36(stamp) .. "~l9~ld~lr~lp6"
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
    remember(recent, recentOrder, key, now, 500)
    remember(seen, seenOrder, name:lower() .. ":" .. p.id, sealOf(p.at, p.kind, p.payload), SEEN_RING)
    return true
end
function net:Broadcast(kind, payload, extras)
    local sent = self:Send(kind, payload or "")
    -- Producers bundle further payloads (victory bonus after TV, resource stocks)
    -- with the first message. Preserve every payload and their order.
    for _, extra in ipairs(extras or {}) do
        if extra.type and extra.payload then
            if not self:Send(extra.type, extra.payload) then sent = false end
        end
    end
    return sent and 1 or 0
end
-- seenChecked: ReceiveFragment already ran alreadySeen on this wire (its result).
function net:Receive(wire, sender, transport, bnetID, decoded, seenChecked)
    if not active() then return false end
    if transport == "BNET" then noteBNetHeard(bnetID) end
    -- Copies of an already processed packet (other bridges, group + channel) are
    -- rejected before any decode; the result is the same false as below. The one
    -- exception is a broadcast whose forward was refused here: that copy only
    -- retries the forward.
    local retryForward = false
    -- A copy someone else carried to the channel or the group: see holdForward.
    -- (ReceiveFragment noted it already when it hands over a decoded packet.)
    if not decoded then noteHeardCopy(wire, transport) end
    local wasSeen
    if decoded and seenChecked ~= nil then wasSeen = seenChecked else wasSeen = alreadySeen(wire, sender) end
    if wasSeen then
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
    local seal = sealOf(p.at, p.kind, p.payload)
    if seen[key] == seal and not retryForward then return false end
    local addressed = p.target == "*" or same(p.target, me)
    -- An intermediate targeted hop can reject a packet after route lookup or
    -- queue admission. Do not seal origin:id until at least one forwarding task
    -- is accepted, so another verified path can deliver the same packet.
    -- Local delivery, broadcasts, and the deliberately unrelayed K retain the
    -- original immediate replay seal.
    local pendingForward = not addressed and p.kind ~= "K" and p.kind ~= "EK"
    if not pendingForward then remember(seen, seenOrder, key, seal, SEEN_RING) end
    local previousRoute = self.peers[origin:lower()]
    -- A direct route outlives relayed copies for two presence intervals (4 min):
    -- a peer is heard first-hand only every ~2 min, while relayed copies of the
    -- same presence keep arriving; letting them win after 60 s made a Battle.net
    -- friend look "far" half of the time, and catch-up only runs with direct peers.
    local keepRoute = previousRoute and tonumber(previousRoute.hops) == 1 and 240 or 60
    if not previousRoute or GetTime() - previousRoute.at > keepRoute or #p.path <= previousRoute.hops then
        remember(self.peers, peerOrder, origin:lower(), {
            name = origin, at = GetTime(), via = sender, transport = transport, bnet = bnetID, hops = #p.path,
        }, self.PEER_RING_LIMIT or PEER_RING, IsPagedSessionPeer)
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
        if version == 6 and p.payload:find("~lr~lp6", 1, true) then version = 7 end
        if version == 7 and p.payload:find("~ld~lr~lp6", 1, true) then version = 8 end
        if version == 8 and p.payload:find("~l9~ld~lr~lp6", 1, true) then version = 9 end
        local previous = pagedCapabilities[originKey]
        -- First-hand presence of a same-faction player (never one that came over
        -- Battle.net: that is the other faction): count its bridge flag.
        if #p.path == 1 and transport ~= "BNET" then
            if p.payload:find("~b~", 1, true) then
                remember(sameFactionBridges, sameFactionBridgesOrder, originKey, GetTime(), 500)
            elseif sameFactionBridges[originKey] then
                sameFactionBridges[originKey] = -1000
            end
        end
        -- 1.7.5 : seul le NH de premier ordre (envoye par le voisin lui-meme) dit sa
        -- capacite. Un relais ecrivait "Voisin,Relais" sans suffixe : le voisin honnete
        -- passait en v5, n'etait plus interroge, et le relais restait seul candidat.
        if #p.path == 1 and (not previous or GetTime() - previous.at > 300
            or p.at > previous.originAt
            or (p.at == previous.originAt and version > previous.version)) then
            -- Sized like self.peers (CAPABILITY_RING): too small, most direct neighbours
            -- of a busy channel looked "unknown" and were asked the slower v7 sweep.
            remember(pagedCapabilities, pagedCapabilityOrder, originKey,
                { version = version, at = GetTime(), originAt = p.at }, CAPABILITY_RING)
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
        -- A neighbour that advertises its newest capture and knows none newer than
        -- ours has nothing a full map would add (older clients advertise nothing:
        -- unchanged for them). Periodic and login catch-ups are unchanged.
        local advertisedMap = p.payload:match("~m(%w+)~")
        local peerStamp = advertisedMap and tonumber(advertisedMap, 36) or nil
        local noNews = peerStamp ~= nil and peerStamp <= localMapStamp()
        if noNews and #p.path == 1 and self.pulls < 2 and now - last >= 300 and not recentFullMap then
            self.stats.mapPullsNoNews = (self.stats.mapPullsNoNews or 0) + 1
        end
        -- Only a direct neighbour is asked: its map reply never needs a relay.
        if #p.path == 1 and self.pulls < 2 and now - last >= 300 and not recentFullMap and not noNews then
            self.pulls = self.pulls + 1
            -- Bound this cache by the same live peer population.
            self.requested = self.requested or {}
            if not self.requestOrder then self.requestOrder = {} end
            if sync:SendSyncRequest({ betaTarget = origin }) then
                remember(self.requested, self.requestOrder, origin:lower(), now, 125)
            end
        end
    end
    -- A relayed kill is never credited (only its author's direct copy counts, anti-
    -- forgery since 1.0.19): forwarding it only burned relay and channel budget. The
    -- death notice EK (front activity only) is not forwarded either.
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
    -- 1.7.2: a keep/outpost capture (OC, LO, LOC, held OP) is only believed from
    -- its capturer or inside a reply the receiver asked for; a forwarded copy would
    -- be refused by every receiver, so none is relayed. Assaults in progress and
    -- releases (neutral) still cross factions through the relay.
    local captureClaim = p.kind == "OC" or p.kind == "LO" or p.kind == "LOC"
        or (p.kind == "OP" and type(p.payload) == "string"
            and p.payload:match("^v%d+:[^:]*:([^:]*)") == "held")
    local relayable = not captureClaim and not isPointToPointCatchup(p.kind, p.target)
        and not ((p.kind == "SR" or p.kind == "GR" or p.kind == "CR") and p.target == "*")
        and p.kind ~= "GI"
    if p.kind == "GI" then
        self.stats.giForwardSkipped = (self.stats.giForwardSkipped or 0) + 1
    end
    if not relayable and not addressed then
        self.stats.catchupNotRelayed = (self.stats.catchupNotRelayed or 0) + 1
        -- Never relayed: seal it so duplicate copies are not decoded again.
        remember(seen, seenOrder, key, seal, SEEN_RING)
    end
    -- K et EK ne sont jamais retransmis : un avis de mort d'un ancien client ne doit
    -- plus inonder le relais a travers nous (il reste livre localement).
    if relayable and p.kind ~= "K" and p.kind ~= "EK" and forwardPresence and #p.path < MAX_PATH
        and (p.target == "*" or not addressed) then
        p.path[#p.path + 1] = me
        p.heardOn = transport
        -- A copy heard on the channel was heard by our group mates too (same realm,
        -- same faction): in a 40-man raid every hearer re-sent it to the raid.
        p.skipGroup = transport == "RAID" or transport == "PARTY" or transport == "CHANNEL"
        -- Whoever gave us a group copy either put it on the channel or got it from
        -- there. Only a gateway we never hear on our channel (another realm) needs it.
        local heardAt = (transport == "RAID" or transport == "PARTY") and channelHeard[sender:lower()] or nil
        p.skipChannel = transport == "CHANNEL"
            or (heardAt ~= nil and GetTime() - heardAt <= 300)

        -- The same routine outpost state (held/neutral, identical payload from any
        -- origin) already relayed within 10 min is handled, not queued again; the
        -- same site's progress within 15 s likewise (see OP_PROGRESS_FORWARD_SEC).
        -- Channel receivers trust OP from any origin, so the origin is not part of
        -- the key.
        local routineKey, routineWindow
        if p.kind == "OP" and p.target == "*" then
            if not isUrgent(p) then
                routineKey, routineWindow = "OP|" .. p.payload, ROUTINE_FORWARD_SEC
                local claimed, stamped = p.payload:match(
                    "^v%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):[^:]*:([^:]*)")
                local changedAt = math.max(tonumber(claimed) or 0, tonumber(stamped) or 0)
                if changedAt > 0 and (tonumber(p.at) or 0) - changedAt < ROUTINE_FRESH_AGE then
                    routineWindow = ROUTINE_FRESH_FORWARD_SEC
                end
            else
                local site, guild, fac = p.payload:match("^v%d+:([^:]*):[^:]*:[^:]*:([^:]*):([^:]*)")
                if site then
                    routineKey = "OPP|" .. site .. "|" .. guild:lower() .. "|" .. fac
                    routineWindow = OP_PROGRESS_FORWARD_SEC
                end
            end
        end
        -- Remembered at admission, even if that copy is later evicted: under
        -- saturation, re-admitting each duplicate only churned the queue (1.2.4 test).
        local routineAt = routineKey and routineForwarded[routineKey]
        if routineAt and GetTime() - routineAt < routineWindow then
            forwarded = true
            if routineWindow == OP_PROGRESS_FORWARD_SEC then
                self.stats.progressForwardSkipped = (self.stats.progressForwardSkipped or 0) + 1
            else
                self.stats.routineForwardSkipped = (self.stats.routineForwardSkipped or 0) + 1
            end
        elseif transport == "BNET" and p.target == "*" and p.kind ~= "NH" and p.kind ~= "SH"
            and not p.skipChannel and holdForward(key, p, "bridge") then
            forwarded = true
            self.stats.bridgeForwardsHeld = (self.stats.bridgeForwardsHeld or 0) + 1
            if routineKey then
                remember(routineForwarded, routineForwardedOrder, routineKey, GetTime(), 250)
            end
        else
            forwarded = self:Queue(p) == true
            if forwarded and routineKey then
                remember(routineForwarded, routineForwardedOrder, routineKey, GetTime(), 250)
            end
        end
        if p.target == "*" then
            if forwarded then
                forwardRetry[key] = nil
            elseif not retryForward then
                remember(forwardRetry, forwardRetryOrder, key, GetTime(), 250)
            end
        end
        -- Group mates without the channel still need a copy: one held group-only
        -- copy per hearer, dropped as soon as a mate's copy is heard in the group.
        if transport == "CHANNEL" and p.target == "*" and p.kind ~= "NH"
            and p.kind ~= "SH" and IsInGroup() and not retryForward
            and (not sync.GroupCarries or sync:GroupCarries(p.kind, p.payload)) then
            local pg = { region = p.region, id = p.id, at = p.at, target = p.target, path = p.path,
                kind = p.kind, payload = p.payload, groupOnly = true, skipChannel = true, heardOn = transport }
            if holdForward("G:" .. key, pg, "group") then
                self.stats.groupCopiesHeld = (self.stats.groupCopiesHeld or 0) + 1
            -- Hold table full (a crowd): only terminal events and siege starts still
            -- get an immediate group copy. Re-sending every routine packet from all 40 raid members
            -- was the amplifier the hold removes; mates without the channel catch
            -- routine state up through the periodic map request.
            elseif (not ((tonumber((net.BridgeChannelHold or {})[2]) or 0) > 0)
                    or isTerminal(p) or isOwnSiegeStart(p))
                and self:Queue(pg) == true then
                self.stats.groupCopiesSent = (self.stats.groupCopiesSent or 0) + 1
            end
        end
        if forwarded then
            if pendingForward then remember(seen, seenOrder, key, seal, SEEN_RING) end
            if p.kind == "NH" then
                remember(nhForwarded, nhForwardedOrder, origin:lower(), p.at, PLAYER_RING)
            elseif p.kind == "SH" then
                remember(shForwarded, shForwardedOrder, origin:lower(), p.at, PLAYER_RING)
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
    if transport == "BNET" then noteBNetHeard(bnetID) end
    local id, part, count, chunk = strsplit(":", payload, 4)
    part, count = tonumber(part), tonumber(count)
    local name = canonical(sender)
    if not name or not id or #id > 64 or not id:match("^[%w%-]+$") or not chunk
        or #chunk > FRAGMENT_RECEIVE_MAX or not part or not count or count < 1 or count > MAX_FRAGMENTS
        or part < 1 or part > count or part ~= math.floor(part) or count ~= math.floor(count) then return false end
    local nameKey = name:lower()
    if transport == "CHANNEL" then
        remember(channelHeard, channelHeardOrder, nameKey, GetTime(), PLAYER_RING)
    end
    local wire
    if count == 1 then
        -- Most packets fit one fragment: no assembly. They used to take a slot of
        -- the 64-entry assembly ring each, and on a busy channel evicted the
        -- multi-fragment packets still waiting for their next piece (a capture's
        -- second fragment comes >= 1.25 s later at the channel's pace).
        wire = chunk
    else
        local key = nameKey .. ":" .. id
        local a = assemblies[key]
        if not a or GetTime() - a.at > TTL
            or GetTime() - (a.lastAt or a.at) > ASSEMBLY_IDLE_TIMEOUT then
            a = { at = GetTime(), lastAt = GetTime(), count = count, got = 0, bytes = 0, chunks = {} }
            -- Only multi-fragment packets live here (singles skip it): 1,000 pending
            -- packets cover tens of seconds of a launch channel. Each holds at most
            -- MAX_PACKET bytes (below), so a flooder cannot pin more than ~3.6 MB.
            remember(assemblies, assemblyOrder, key, a, 1000)
        end
        if a.count ~= count then return false end
        if a.chunks[part] and a.chunks[part] ~= chunk then return false end
        if not a.chunks[part] then
            if a.bytes + #chunk > MAX_PACKET then return false end
            a.chunks[part] = chunk
            a.got = a.got + 1
            a.bytes = a.bytes + #chunk
            a.lastAt = GetTime()
        end
        if a.got ~= count then return true end
        wire = table.concat(a.chunks)
    end
    noteHeardCopy(wire, transport)
    -- Every later duplicate fragment of a completed packet lands here again.
    -- Let refused broadcast forwards reach Receive's retry-only path as well.
    local wasSeen = alreadySeen(wire, name)
    if wasSeen and not forwardRetryKey(wire) then return false end
    local p = decode(wire)
    if not p or p.id ~= id then return false end
    return self:Receive(wire, name, transport, bnetID, p, wasSeen)
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
local BRIDGE_LK_ALLOWANCE, BRIDGE_LK_MAX_ROWS = 30, 250
-- bridgeLK: enemy totals passed on to our own faction (channel, whispers as fallback).
-- bridgeOut (1.3.2): our own faction's totals, heard from their owners, passed on to
-- our opposite-faction Battle.net friends, whose clients then put them on their
-- channel. Same bounds for both: one row per subject per 60 s, 6 rows/min, 3 targets.
local bridgeLK = { rows = {}, order = {}, queue = {}, sent = {}, peerAt = {}, peerOrder = {} }
local bridgeOut = { rows = {}, order = {}, queue = {}, sent = {}, outbound = true }
-- Random wait before a channel copy (seconds); tests may set { 0, 0 }.
net.BridgeChannelHold = { 2, 15 }
-- Bridge election (2026-10-02). Every client that receives an enemy total over
-- Battle.net is a channel bridge for it. With hundreds of them, the 2-15 s hold and
-- the "already on the channel" cancel still let dozens of copies through (those sent
-- in the same second). Each client counts the channel copies of every enemy total
-- and adapts the share of subjects it posts first: copies ~ bridges x share, so
-- share x TARGET / copies brings them back to about TARGET. Which subjects a client
-- keeps is a hash of (client, subject): each client decides alone, no message.
-- With few bridges the share stays 1, today's behaviour. A client not elected for a
-- subject keeps its copy as a fallback 20-60 s later (spread by the same hash),
-- cancelled as soon as another copy is heard: a total can be late, never lost.
local ELECTION_TARGET, ELECTION_MIN_SHARE = 3, 0.005
local ELECTION_FALLBACK_MIN, ELECTION_FALLBACK_SPAN = 20, 40
local bridgeCopies, bridgeCopiesOrder = {}, {}
bridgeLK.share = 1
local function electionRoll(salt, subjectKey)
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    return hashFrac(salt .. "|" .. tostring(me or ""):lower() .. "|" .. subjectKey)
end
-- One more channel copy of an enemy total (heard, or our own post). When a newer
-- total of the same subject shows up, the previous one is complete: its copies,
-- divided by the share in force when it started, estimate how many bridges carry
-- this subject. That estimate is smoothed and the share set to TARGET / bridges.
-- (Scaling the share by each sample instead compounded stale samples and swung it
-- from 1 to the floor and back.) A total seen once or not at all means bridges are
-- scarce: the estimate shrinks and the share grows back toward 1.
bridgeLK.bridges = ELECTION_TARGET
local function noteBridgeCopy(name, total, sender)
    local key, now = name:lower(), math.floor(tonumber(total) or 0)
    local who = type(sender) == "string" and sender:lower() or "?"
    local record = bridgeCopies[key]
    if record and record.total == now then
        -- One copy per sender: a single channel member repeating a row cannot
        -- push everyone's share down.
        if not record.senders[who] then
            record.senders[who] = true
            record.count = record.count + 1
        end
        return
    end
    -- A lower total is an old copy heard late, unless the record itself is old:
    -- after the weekly reset totals restart near 0 and last week's records must
    -- not freeze the estimate for the rest of the session.
    if record and now < record.total and GetTime() - (record.at or 0) < 120 then return end
    if record and now < record.total then record = nil end
    if record then
        local estimate = bridgeLK.bridges or ELECTION_TARGET
        if record.count <= 1 then
            estimate = math.max(ELECTION_TARGET, estimate * 0.6)
        else
            local sample = record.count / math.max(ELECTION_MIN_SHARE, record.share or 1)
            estimate = estimate * 0.7 + sample * 0.3
        end
        bridgeLK.bridges = estimate
        -- Dead zone: up to twice the target the share stays exactly 1, so a stray
        -- burst of copies never changes the behaviour of small groups of bridges.
        if estimate <= 2 * ELECTION_TARGET then
            bridgeLK.share = 1
        else
            bridgeLK.share = math.max(ELECTION_MIN_SHARE, math.min(1, ELECTION_TARGET / estimate))
        end
    end
    -- 1024 subjects (was 256): a crowd of active enemies evicted records before
    -- their next total and froze the estimate exactly where it is needed.
    remember(bridgeCopies, bridgeCopiesOrder, key,
        { total = now, count = 1, share = bridgeLK.share or 1, senders = { [who] = true },
            at = GetTime() }, 1000)
end
function net:GetBridgeShare() return bridgeLK.share or 1 end
local bridgeFlush
function net:EmitBridgeLK(row, payload)
    local now = GetTime()
    local reached = 0
    -- 1.3.2: one copy on our faction channel reaches every same-faction player
    -- there. The three whispers below date from 1.2.0, when Blizzard refused most
    -- channel traffic; they stay the fallback when the channel is unavailable or
    -- its send budget is spent.
    local onChannel, why = false, nil
    if sync.SendBridgeLKToChannel then onChannel, why = sync:SendBridgeLKToChannel(payload) end
    if onChannel then
        -- Group members on our channel heard it there: no second copy.
        self.stats.bridgeLK = (self.stats.bridgeLK or 0) + 1
        self.stats.bridgeLKChannel = (self.stats.bridgeLKChannel or 0) + 1
        -- Our own copy counts too: we never receive our own channel line back.
        if row and row.name and row.pendingTotal then
            noteBridgeCopy(row.name, row.pendingTotal, sync.GetPlayerFullName and sync:GetPlayerFullName())
        end
        return true
    end
    -- Channel only busy: retry shortly (the flush waits 5 s); whisper only when the
    -- channel is unavailable (not joined, instance).
    if why == "wait" then return false end
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
            remember(bridgeLK.peerAt, bridgeLK.peerOrder, name:lower(), now, 250)
            bridgeLK.peerAt[name:lower()] = now
            reached = reached + 1
        end
    end
    if IsInGroup() and sync:SendToGroup("LK", payload) then reached = reached + 1 end
    self.stats.bridgeLK = (self.stats.bridgeLK or 0) + (reached > 0 and 1 or 0)
    return reached > 0
end
-- Opposite-faction Battle.net friends (game account ids), from the cached list:
-- the live bridges first (see bnetAlive), then the others in list order.
local function enemyBNetFriends()
    local out, quiet, mine = {}, {}, addon.PlayerFaction
    local targets = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
    for _, id in ipairs(targets) do
        local faction = sync.GetBetaBNetTargetInfo and sync:GetBetaBNetTargetInfo(id)
        if (faction == "Alliance" or faction == "Horde") and faction ~= mine then
            if bnetAlive(id) then out[#out + 1] = id else quiet[#quiet + 1] = id end
        end
    end
    for _, id in ipairs(quiet) do out[#out + 1] = id end
    return out
end
-- Live friends only (heard under Overlord within BNET_ALIVE_SEC): a friend without
-- the addon, on another ruleset or in an instance drops the row.
function net:EmitBridgeOut(row, payload)
    local reached, tried = 0, 0
    for _, id in ipairs(enemyBNetFriends()) do
        if tried >= BRIDGE_LK_FANOUT or not bnetAlive(id) then break end
        tried = tried + 1
        if sync.SendToBNet and sync:SendToBNet(id, "LK", payload) then reached = reached + 1 end
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
            elseif row.holdUntil and now < row.holdUntil then
                wait = math.min(wait, row.holdUntil - now)
                keep[#keep + 1] = key
            elseif now < ready then
                wait = math.min(wait, ready - now)
                keep[#keep + 1] = key
            elseif #sent >= BRIDGE_LK_PER_MIN then
                wait = math.min(wait, sent[1] + 60 - now)
                keep[#keep + 1] = key
            else
                local payload, emitted = row.pending, false
                -- An unexpected error on one row must not block the rows behind it.
                local ok, result = pcall(state.outbound and net.EmitBridgeOut or net.EmitBridgeLK,
                    net, row, payload)
                emitted = ok and result == true
                if emitted then
                    row.pending, row.sentAt = nil, now
                    sent[#sent + 1] = now
                else
                    -- nobody to tell right now, or the channel is busy: try again
                    -- shortly, with a fresh random hold for channel copies so the
                    -- bridges that were all busy do not retry in the same second.
                    if not state.outbound then
                        local hold = net.BridgeChannelHold or {}
                        local hi = math.floor(tonumber(hold[2]) or 0)
                        if hi > 0 then row.holdUntil = now + 2 + math.random() * math.max(0, math.min(6, hi) - 2) end
                    end
                    wait = math.min(wait, 5)
                    keep[#keep + 1] = key
                end
            end
        elseif row then
            row.pending = nil
        end
    end
    state.queue = keep
    -- One live timer per bridge, moved earlier when a nearer row arrives: a stale
    -- 30 s timer let rows wait for the next kill, heard in the same second by
    -- every bridge. Superseded timers see a newer token and do nothing.
    if #keep > 0 then
        local due = now + math.max(1, math.min(30, wait))
        if not state.armed or due < (state.due or math.huge) - 0.5 then
            local token = (state.token or 0) + 1
            state.armed, state.due, state.token = true, due, token
            C_Timer.After(due - now, function()
                if state.token ~= token then return end
                state.armed, state.due = false, nil
                bridgeFlush(state)
            end)
        end
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
    if not row.pending then
        state.queue[#state.queue + 1] = key
        -- Channel copies wait 2-15 s at random: every bridge hears the same kill at
        -- the same moment, so without it they all sent before hearing each other
        -- and the coverage rule (NoteChannelBridgeRow) never applied.
        local hold = net.BridgeChannelHold or {}
        local lo, hi = math.floor(tonumber(hold[1]) or 0), math.floor(tonumber(hold[2]) or 0)
        -- Counted from when the row may leave (60 s per subject): bridges that all sent
        -- or all heard the previous copy at the same moment stay spread out.
        if not state.outbound and hi > 0 then
            local from = math.max(now, (row.sentAt or -math.huge) + BRIDGE_LK_SUBJECT_GAP)
            local share = state.share or 1
            if share < 1 and electionRoll("E", key) >= share then
                -- Not elected for this subject: fallback copy only (see election).
                row.holdUntil = from + ELECTION_FALLBACK_MIN
                    + electionRoll("F", key) * ELECTION_FALLBACK_SPAN
                net.stats.bridgeLKDeferred = (net.stats.bridgeLKDeferred or 0) + 1
            else
                row.holdUntil = from + math.max(0, lo) + math.random() * (hi - math.max(0, lo))
            end
        end
    end
    row.pending, row.pendingAt, row.pendingTotal = payload, now, total
    if #state.queue > 64 then
        -- Rows cancelled by a copy heard meanwhile still sit in the queue until the
        -- next flush: drop them first, before evicting a row that is still due.
        local live = {}
        for _, queued in ipairs(state.queue) do
            local r = state.rows[queued]
            if r and r.pending then live[#live + 1] = queued end
        end
        state.queue = live
    end
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
        local t, b = tonumber(total) or 0, tonumber(before) or 0
        if b <= 0 or t <= b then return false end
        -- Every client of the faction hears the owner's total on the channel: with
        -- many bridges (see crossShare) only about CROSS_TARGET of them, chosen per
        -- subject by hash, pass it on. The owner's own K still reaches its own
        -- opposite-faction friends directly. (Checked before the friend scan.)
        local share = crossShare()
        if share < 1 then
            local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
            -- The electors of a subject change every 15 min: a subject whose few
            -- electors have no live bridge is not left out for good.
            local bucket = math.floor(serverNow() / 900)
            if hashFrac("O|" .. bucket .. "|" .. tostring(me):lower() .. "|" .. name:lower()) >= share then
                self.stats.bridgeOutElectedAway = (self.stats.bridgeOutElectedAway or 0) + 1
                return false
            end
        end
        if not self:HasLiveEnemyBridge() then return false end
        return queueBridgeRow(bridgeOut, name, faction, total, before, class, locale,
            epoch, bucketToken, levelToken)
    end
    -- Enemy owner: only a K that reached us over Battle.net from its owner (the
    -- friend link is what makes this client the bridge).
    if not c or c.transport ~= "BNET" or (tonumber(c.hops) or 0) ~= 0 then return false end
    self.stats.enemyFriendKills = (self.stats.enemyFriendKills or 0) + 1
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
function net:NoteChannelBridgeRow(name, total, faction, sender)
    if type(name) ~= "string" then return false end
    -- Only enemy totals are bridge copies (own-faction LK on our channel is not).
    local mine = addon.PlayerFaction
    if (faction == "Alliance" or faction == "Horde") and faction ~= mine then
        noteBridgeCopy(name, total, sender)
    end
    local row = bridgeLK.rows[name:lower()]
    total = tonumber(total)
    if not (row and row.pending and total and total >= (row.pendingTotal or math.huge)) then return false end
    row.pending, row.sentAt = nil, GetTime()
    self.stats.bridgeLKCovered = (self.stats.bridgeLKCovered or 0) + 1
    return true
end
function net:ScheduleReturnPresence()
    if not enabled() or not self.started or self.returnPresencePending then return end
    self.returnPresencePending = true
    C_Timer.After(5 + math.random() * 10, function()
        net.returnPresencePending = nil
        if active() then net:Broadcast("NH", addon.Version) end
    end)
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
