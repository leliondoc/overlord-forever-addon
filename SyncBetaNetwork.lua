-- Beta transport: bounded store-and-forward over group/channel and Battle.net.
-- The last hop is authenticated by WoW/BNet. Earlier authors are vouched for by
-- that peer, not cryptographically authenticated by Blizzard. Keep the original
-- author when dispatching so relays never manufacture additional witnesses.
local addon = Overlord
local sync = addon.Sync
local net = { peers = {}, stats = { sent = 0, received = 0, dropped = 0 } }
addon.BetaNetwork = net
local allowed = {}
for kind in ("NH SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC OE TV VT VF FR DX VB MN MS WN WS GK GC GA G7 GH OP OC WB SH HR HB HC HA LD CR CA GR GY GI FC GE GP GX GD GM BQ BR PB PK MK PX PP PM"):gmatch("%S+") do
    allowed[kind] = true
end
local MAX_PACKET, MAX_PATH, TTL = 3600, 4, 120
local MAX_BRIDGE_FRIENDS = 5
local MAX_QUEUE = 128
local CATCHUP_QUEUE = 16
local CATCHUP_RATE = 300
-- All three lanes share the same 1,000 B/s budget and 128-packet bound.
-- Addressed ranking data has reserved slots and a 300 B/s service credit so a
-- busy bridge cannot indefinitely evict it in favour of presence and alerts.
local URGENT = {}
-- HR/HA are the tiny catch-up requests and acknowledgements (one every few
-- minutes). Broadcast legacy controls remain urgent; addressed exchanges use
-- the reserved lane below, including their requests and acknowledgements.
for kind in ("NH SH C ZS ZR CB GK GC GA G7 OP OC TV FR FC GE GP GX GD GM HR HA"):gmatch("%S+") do
    URGENT[kind] = true
end
-- Keeps and outposts are the lowest priority: only a siege in progress and the
-- rare final events (GC/OC/GA) stay urgent; routine snapshots and G7 fragments wait.
local function isUrgent(p)
    local kind = p and p.kind
    if kind == "GK" or kind == "OP" then
        return type(p.payload) == "string" and p.payload:match("^v%d+:[^:]*:([^:]*)") == "in_progress"
    end
    if kind == "G7" then return false end
    return URGENT[kind] == true
end
local function isCatchup(p)
    return p.target ~= "*" and (p.kind == "HR" or p.kind == "HB" or p.kind == "HC" or p.kind == "HA"
        or p.kind == "LK" or p.kind == "LC" or p.kind == "LR")
end
local urgentLane, bulkLane, catchupLane = { items = {}, head = 1 }, { items = {}, head = 1 }, { items = {}, head = 1 }
local pendingPresence = {}
local pumping = false
local function laneSize(lane) return #lane.items - lane.head + 1 end
local function queuedCount() return laneSize(urgentLane) + laneSize(bulkLane) + laneSize(catchupLane) end
local function laneFor(p) return isCatchup(p) and catchupLane or (isUrgent(p) and urgentLane or bulkLane) end
local function hasLaneRoom(lane)
    if queuedCount() >= MAX_QUEUE then return false end
    -- Legacy relays cannot propagate backpressure to the original sender. Let
    -- short bursts borrow idle slots rather than turn the reservation into a
    -- smaller hard cap. Local v5 producers still stop at 16 queued packets.
    if lane == catchupLane then return true end
    return laneSize(urgentLane) + laneSize(bulkLane) < MAX_QUEUE - CATCHUP_QUEUE
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
local function dropWaitingForUrgent()
    for i = bulkLane.head, #bulkLane.items do
        local item = bulkLane.items[i]
        if item and item.index == 1 then
            table.remove(bulkLane.items, i)
            countKind(item.p and item.p.kind, "dropped")
            return true
        end
    end
    -- Only borrowed catch-up slots can be reclaimed; the first 16 and any
    -- partially sent packet stay protected, so their fragments can finish.
    for i = catchupLane.head + CATCHUP_QUEUE, #catchupLane.items do
        local item = catchupLane.items[i]
        if item and item.index == 1 then
            table.remove(catchupLane.items, i)
            countKind(item.p.kind, "dropped")
            return true
        end
    end
    return false
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
    local lines = { "Relay by type (KB sent / packets / dropped):" }
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
    local paged = (p.kind == "HR" or p.kind == "HB" or p.kind == "HA")
        and p.payload:sub(1, 2) == "5:"
    local count = math.ceil(#wire / 170)
    for i = 1, count do
        fragments[i] = p.id .. ":" .. i .. ":" .. count .. ":" .. wire:sub((i - 1) * 170 + 1, i * 170)
    end
    local route = p.target ~= "*" and net.peers[p.target:lower()] or nil
    if route and GetTime() - route.at > 300 then route = nil end
    if route then
        for _, name in ipairs(p.path) do if same(name, route.via) then route = nil; break end end
    end
    -- Bulk v5 catch-up is always addressed over an established route. Never
    -- flood the realm/group or fan out to friends to discover a missing path.
    if paged and (p.target == "*" or not route) then return tasks end
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
    return tasks
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
    local urgent = isUrgent(p)
    local catchup = isCatchup(p)
    -- Keep the freshest unsent presence in its original place in the queue.
    -- Once any copy has started, finish it instead of disrupting its fragments.
    local presenceKey = p.kind == "NH" and p.path[1]:lower()
    local previous = presenceKey and pendingPresence[presenceKey]
    local replace = previous and previous.index == 1 and not previous.tasks[1].sending and p.at >= previous.p.at
    local lane = laneFor(p)
    if not replace and not hasLaneRoom(lane) then
        -- Full: an urgent packet displaces the oldest waiting bulk packet instead
        -- of being refused. Bulk packets are refused as before.
        if catchup or not urgent or not dropWaitingForUrgent() then
            self.stats.dropped = self.stats.dropped + 1
            countKind(p.kind, "dropped")
            return false
        end
        self.stats.dropped = self.stats.dropped + 1
        self.stats.displaced = (self.stats.displaced or 0) + 1
    end
    -- Reject overload before encoding, fragment allocation and route discovery.
    local wire = encode(p)
    if #wire > MAX_PACKET then return false end
    local item = { p = p, tasks = tasksFor(p, wire), index = 1 }
    if #item.tasks == 0 then return false end
    if replace then
        previous.p, previous.tasks = p, item.tasks
        self.stats.presenceCoalesced = (self.stats.presenceCoalesced or 0) + 1
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
    return laneSize(catchupLane) < CATCHUP_QUEUE
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
    local function readyIndex(lane)
        for i = lane.head, #lane.items do
            local it = lane.items[i]
            local task = it.tasks[it.index]
            if channelReady or now - it.p.at > TTL or not task
                or task.transport ~= "CHANNEL" or not task.defers then return i end
        end
    end
    local urgentIndex, bulkIndex = readyIndex(urgentLane), readyIndex(bulkLane)
    local catchupIndex = readyIndex(catchupLane)
    local stamp = GetTime()
    catchupCredit = math.min(500, catchupCredit + math.max(0, stamp - catchupAt) * CATCHUP_RATE)
    catchupAt = stamp
    -- Finish a bulk packet already partly sent, otherwise urgent first.
    local lane, index = urgentLane, urgentIndex
    if bulkIndex and (not urgentIndex or bulkLane.items[bulkIndex].index > 1) then
        lane, index = bulkLane, bulkIndex
    end
    if catchupIndex then
        local it = catchupLane.items[catchupIndex]
        local task = it.tasks[it.index]
        -- The share is a minimum, not a ceiling: without live urgent traffic,
        -- recover ranking data before routine history. Old v4 producers send
        -- one whole row/s and cannot obey per-hop backpressure.
        if not urgentIndex or not task or now - it.p.at > TTL or catchupCredit >= task.bytes then
            lane, index = catchupLane, catchupIndex
        end
    end
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
            if task then countKind(item.p.kind, "dropped") end
            item.index = #item.tasks + 1
            break
        end
        if lane == catchupLane and urgentIndex and not task.skip
            and catchupCredit < task.bytes then break end
        local emitted = emit(task)
        if lane == catchupLane and task.spent then catchupCredit = math.max(0, catchupCredit - task.spent) end
        if emitted then
            item.index = item.index + 1
        elseif task.deferred then
            -- Channel message budget empty: this copy waits at the end of its lane
            -- while the item's Battle.net/whisper copies keep going in this tick.
            task.deferred = nil
            task.defers = (task.defers or 0) + 1
            item.index = item.index + 1
            local deferLane = laneFor(item.p)
            if hasLaneRoom(deferLane) then
                deferLane.items[#deferLane.items + 1] = { p = item.p, tasks = { task }, index = 1 }
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
            local retryLane = laneFor(item.p)
            if task.retries <= 3 and hasLaneRoom(retryLane) then
                retryLane.items[#retryLane.items + 1] = { p = item.p, tasks = { task }, index = 1 }
            else
                net.stats.dropped = net.stats.dropped + 1
            end
            break
        else
            -- Shared relay byte budget: wait for the next tick.
            break
        end
    end
    if item.index > #item.tasks then
        forgetPresence(item)
        lane.items[lane.head] = false; lane.head = lane.head + 1
    end
    compactLane(urgentLane)
    compactLane(bulkLane)
    compactLane(catchupLane)
    if queuedCount() > 0 then schedule() end
end
function net:Send(kind, payload, target, immediate)
    if not active() or not allowed[kind] or type(payload) ~= "string"
        or payload:find("[%c]") then return false end
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
    remember(seen, seenOrder, key, GetTime(), 2048)
    local previousRoute = self.peers[origin:lower()]
    if not previousRoute or GetTime() - previousRoute.at > 60 or #p.path <= previousRoute.hops then
        remember(self.peers, peerOrder, origin:lower(), {
            name = origin, at = GetTime(), via = sender, transport = transport, bnet = bnetID, hops = #p.path,
        }, 128)
    end
    self.stats.received = self.stats.received + 1
    local addressed = p.target == "*" or same(p.target, me)
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
        -- At most two full pulls per minute. No roster/club required for discovery.
        local now = GetTime()
        if not self.pullWindow or now - self.pullWindow >= 60 then self.pullWindow, self.pulls = now, 0 end
        self.requested = self.requested or {}
        local last = self.requested[origin:lower()] or -300
        if self.pulls < 2 and now - last >= 300 then
            self.pulls = self.pulls + 1
            -- Bound this cache by the same live peer population.
            self.requested = self.requested or {}
            if not self.requestOrder then self.requestOrder = {} end
            if sync:SendSyncRequest({ fullResponse = true, betaTarget = origin }) then
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
    if p.kind ~= "K" and forwardPresence and #p.path < MAX_PATH and (p.target == "*" or not addressed) then
        p.path[#p.path + 1] = me
        p.skipGroup = transport == "RAID" or transport == "PARTY"
        -- Whoever gave us a group copy either put it on the channel or got it from
        -- there. Only a gateway we never hear on our channel (another realm) needs it.
        local heardAt = p.skipGroup and channelHeard[sender:lower()] or nil
        p.skipChannel = transport == "CHANNEL"
            or (heardAt ~= nil and GetTime() - heardAt <= 300)

        if self:Queue(p) and p.kind == "NH" then
            remember(nhForwarded, nhForwardedOrder, origin:lower(), p.at, 512)
        end
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
    if not a or GetTime() - a.at > 15 then
        a = { at = GetTime(), count = count, got = 0, chunks = {} }
        remember(assemblies, assemblyOrder, key, a, 64)
    end
    if a.count ~= count then return false end
    if a.chunks[part] and a.chunks[part] ~= chunk then return false end
    if not a.chunks[part] then a.chunks[part] = chunk; a.got = a.got + 1 end
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
