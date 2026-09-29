-- Four replicas: channel A -> BNet gateway -> other faction/shard channel.
-- There is no community membership or C_Club API in this fixture.
local now, pending, calls = 100, {}, 0
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return true end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function() return {} end,
}
local clients = {}
local function drain()
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = item.at; item.run(); calls = calls + 1
        for _, replica in ipairs(clients) do
            local bytes = replica.BetaNetwork.stats.bytes or 0
            local credit = math.min(500, (replica.credit or 500) + (now - (replica.checkedAt or 100)) * 1000)
            assert(bytes - (replica.checkedBytes or 0) <= credit + 0.001, "Shared transport budget exceeded")
            replica.credit = credit - (bytes - (replica.checkedBytes or 0))
            replica.checkedAt, replica.checkedBytes = now, bytes
        end
        assert(calls < 100000, "Relay loop / unbounded pump")
    end
end
local function client(name, channel, pool)
    local a = { Version = "1.0.0", CommunityModeEnabled = true, BetaNetworkEnabled = true,
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, value)
                return ({ global = true, us = true, na = true, eu = true, fr = true, de = true })[value]
                    and "global" or ""
            end,
        }, Sync = {}, received = {} }
    a.name, a.channel, a.friends = name, channel, {}
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
    function s:GetPlayerFullName() return name end
    function s:GetChannelId() return 1 end
    function s:ExpectDirectFullLeaderboardResponse() end
    function s:SendSyncRequest() end
    function s:SendToGroup(kind, fragment)
        if not IsInGroup() then return false end
        -- Deliberately duplicate every channel delivery to exercise dedup.
        return self:SendToChannel(kind, fragment)
    end
    function s:SendToChannel(kind, fragment)
        if a.refuseAlways then return false end
        if a.budgetTicks and a.budgetTicks > 0 then a.budgetTicks = a.budgetTicks - 1; return false, "budget" end
        if a.refuseChannel then a.refuseChannel = false; return false end
        assert(#kind + #fragment + 1 <= 255, "Addon packet exceeded 255 bytes")
        for _, other in ipairs(clients) do
            if other ~= a and other.channel == channel then
                other.BetaNetwork:ReceiveFragment(fragment, name, "CHANNEL")
            end
        end
        return true
    end
    function s:GetBetaBNetTargets() return a.friends end
    function s:GetBetaBNetTargetInfo(other) return other.faction, other.name end
    function s:SendToBNet(other, kind, wire)
        if other.offline then return false end
        assert(#wire < 4000)
        if kind == "BR" then
            a.lastWire = wire
            other.BetaNetwork:Receive(wire, name, "BNET", a)
        else
            assert(kind == "BF")
            other.BetaNetwork:ReceiveFragment(wire, name, "BNET", a)
        end
        return true
    end
    function s:SendWhisper(kind, data, target)
        assert(kind == "BF" and #data + 3 <= 255)
        for _, other in ipairs(clients) do
            if other.name == target then other.BetaNetwork:ReceiveFragment(data, name, "WHISPER") end
        end
        return true
    end
    function s:OnAddonMessage(_, message, transport, origin)
        assert(transport == "BETA")
        assert(a.BetaNetwork:IsDispatching(origin))
        local kind, payload = strsplit(":", message, 2)
        a.received[#a.received + 1] = { kind = kind, payload = payload, origin = origin, at = now }
        -- A snapshot handler must not re-author the same received state.
        assert(a.BetaNetwork:Broadcast(kind, payload) == 0)
        if kind == "SR" then
            assert(a.BetaNetwork:IsTargetedDispatch(), "Targeted request lost its transport semantics")
            a.BetaNetwork:Send("LK", "reply", origin)
        elseif kind ~= "LK" then
            assert(not a.BetaNetwork:IsTargetedDispatch(), "Broadcast gained direct-whisper authority")
        end
    end
    Overlord = a
    assert(loadfile("SyncBetaNetwork.lua"))()
    clients[#clients + 1] = a
    return a
end
local a = client("Alice Tester", "one")
local b = client("Bridge Tester", "one")
local c = client("Horde Tester", "two")
local d = client("Dwarf Tester", "two")
local us = client("Other Tester", "us", "us")
b.friends, c.friends = { c, us }, { b }
local kinds = {}
for kind in ("SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC OE TV VT VF FR DX VB MN MS OP OC SH HR HB HC HA LD CR CA GR GY GI FC GE GP GX GD GM BQ BR PB PK MK PX PP PM"):gmatch("%S+") do
    -- K is never re-forwarded: a relayed kill is never credited (anti-forgery).
    if kind ~= "SR" and kind ~= "K" then kinds[#kinds + 1] = kind end
end
for _, kind in ipairs(kinds) do
    assert(a.BetaNetwork:Send(kind, string.rep("x", 450)))
    drain()
    local received = d.received[#d.received]
    assert(received and received.kind == kind and received.origin == a.name
        and #received.payload == 450, "Community message lost through gateway: " .. kind)
end
assert(#d.received == #kinds, "Duplicate routes produced duplicate delivery")
assert(#us.received == #kinds, "Global Forever data did not reach the former NA route")
assert(#a.received == 0, "Original sender received its own forwarded event")
a.refuseChannel = true
assert(a.BetaNetwork:Broadcast("DX", "front-one", {
    { type = "DX", payload = "front-two" }, { type = "VB", payload = "bonus" },
    { type = "MS", payload = "stock" },
}) == 1)
drain()
for i, payload in ipairs({ "front-one", "front-two", "bonus", "stock" }) do
    assert(d.received[#kinds + i].payload == payload, "Bundled payload/throttled fragment lost: " .. payload)
end
IsInGroup = function() return false end
a.refuseChannel = true
assert(a.BetaNetwork:Send("C", "retry-without-group"))
drain()
assert(d.received[#d.received].payload == "retry-without-group", "Throttled solo channel fragment was discarded")
-- A group copy from a gateway heard on our channel is already on that channel:
-- re-emitting it there burned every raid member's channel throttle. A gateway we
-- never hear on the channel (other realm) still gets its copy forwarded.
do
    local channelSends = 0
    local originalSendToChannel = b.Sync.SendToChannel
    b.Sync.SendToChannel = function(self, kind, fragment)
        channelSends = channelSends + 1
        return originalSendToChannel(self, kind, fragment)
    end
    local function groupWire(id, origin)
        return table.concat({ "global", id, tostring(time()), "*", origin, "C", "raid-copy-" .. id }, "|")
    end
    b.BetaNetwork:ReceiveFragment("probe-1:1:1:x", a.name, "CHANNEL")
    assert(b.BetaNetwork:Receive(groupWire("raid-1", a.name), a.name, "RAID"))
    drain()
    assert(channelSends == 0, "Raid copy from a channel peer was re-emitted on the channel")
    assert(c.received[#c.received].payload == "raid-copy-raid-1", "Raid copy no longer reached the bridge")
    assert(b.BetaNetwork:Receive(groupWire("raid-2", "Remote Realmer"), "Remote Realmer", "RAID"))
    drain()
    assert(channelSends > 0, "Raid copy from another realm was not forwarded to the channel")
    b.Sync.SendToChannel = originalSendToChannel
end
-- Our own 1 s channel byte budget is not a Blizzard refusal: the fragment waits in
-- place (as before) and is never counted as refused nor dropped.
do
    local refusedBefore, droppedBefore = b.BetaNetwork.stats.refused or 0, b.BetaNetwork.stats.dropped
    b.budgetTicks = 8
    assert(b.BetaNetwork:Send("C", "bridge-budget-wait"))
    drain()
    assert(a.received[#a.received].payload == "bridge-budget-wait", "Budget-deferred channel copy was lost")
    assert((b.BetaNetwork.stats.refused or 0) == refusedBefore and b.BetaNetwork.stats.dropped == droppedBefore,
        "Local channel budget was treated as a Blizzard refusal")
end
-- Keeps/outposts are the lowest priority: only sieges in progress and rare final
-- events stay in the urgent lane; captures and alerts keep priority.
do
    local n = a.BetaNetwork
    assert(n:IsUrgentPacket("C", "x") and n:IsUrgentPacket("ZS", "x") and n:IsUrgentPacket("TV", "x"))
    assert(n:IsUrgentPacket("OC", "x"))
    assert(n:IsUrgentPacket("OP", "v1:site:in_progress:1"))
    assert(not n:IsUrgentPacket("GK", "v9:site:held:1") and not n:IsUrgentPacket("OP", "v1:site:neutral:1"))
    assert(not n:IsUrgentPacket("G7", "x") and not n:IsUrgentPacket("GH", "x") and not n:IsUrgentPacket("K", "x"))
end
-- A bridge re-forwards each origin's presence (NH) at most once per 2 minutes.
do
    local channelSends = 0
    local originalSendToChannel = c.Sync.SendToChannel
    c.Sync.SendToChannel = function(self, kind, fragment)
        channelSends = channelSends + 1
        return originalSendToChannel(self, kind, fragment)
    end
    local before = #d.received
    assert(a.BetaNetwork:Send("NH", "presence-one")); drain()
    local afterFirst = channelSends
    now = now + 5
    assert(a.BetaNetwork:Send("NH", "presence-two")); drain()
    c.Sync.SendToChannel = originalSendToChannel
    assert(afterFirst > 0, "First presence never reached the bridge's channel")
    assert(channelSends == afterFirst, "Bridge re-emitted the same origin's presence within 2 minutes")
    assert(#d.received == before, "Presence was dispatched as a sync message")
end
-- /ov network: relay cost per kind (bytes sent, packets, drops), heaviest first.
do
    local lines = table.concat(a.BetaNetwork:GetKindDiagnostics(12), " ")
    assert(lines:find("Relay by type", 1, true) and a.BetaNetwork.kindStats.DX
        and a.BetaNetwork.kindStats.DX.queued > 0 and a.BetaNetwork.kindStats.DX.bytes > 0,
        "Relay per-kind diagnostics missing: " .. lines)
end
-- Presence stays fresh across hops even with the 2-minute forward limit and one
-- lost copy: a far peer (a -> b -> BNet -> c -> d) never drops out of the 5 min list.
do
    local lostOnce = false
    local lossAfter = now + 200
    local originalSendToBNet = b.Sync.SendToBNet
    b.Sync.SendToBNet = function(self, other, kind, wire)
        if not lostOnce and now > lossAfter and wire:find("|NH|", 1, true) then
            lostOnce = true
            return true
        end
        return originalSendToBNet(self, other, kind, wire)
    end
    local startAt = now
    local nextBeat = now
    while now < startAt + 600 do
        if now >= nextBeat then
            assert(a.BetaNetwork:Send("NH", "beat-" .. math.floor(now)))
            nextBeat = nextBeat + 45
        end
        drain()
        if now > startAt + 60 then
            assert(d.BetaNetwork:IsPeer(a.name), "Far peer dropped out of the known list at +" .. math.floor(now - startAt) .. " s")
        end
        now = now + 5
    end
    b.Sync.SendToBNet = originalSendToBNet
    assert(lostOnce, "Fixture never lost a presence copy")
end
-- Transit delays must not change the presence decision: it follows the author's
-- timestamp, identical at every hop (Astra's case: 20 s late, then 75 s gap).
do
    local forwarded = {}
    local originalSendToBNet = b.Sync.SendToBNet
    b.Sync.SendToBNet = function(self, other, kind, wire)
        local at = wire:match("^[^|]*|[^|]*|(%d+)|[^|]*|Delay Origin[^|]*|NH|")
        if at then forwarded[#forwarded + 1] = tonumber(at) end
        return originalSendToBNet(self, other, kind, wire)
    end
    local base = time()
    -- emitted at T (arrives 20 s late), T+45 (no forward), T+90 (arrives only 75 s after T's arrival)
    local w1 = table.concat({ "global", "delay-1", tostring(base - 20), "*", "Delay Origin", "NH", "beat" }, "|")
    assert(b.BetaNetwork:Receive(w1, "Delay Origin", "CHANNEL")); drain()
    now = now + 45
    local w2 = table.concat({ "global", "delay-2", tostring(base + 25), "*", "Delay Origin", "NH", "beat" }, "|")
    assert(b.BetaNetwork:Receive(w2, "Delay Origin", "CHANNEL")); drain()
    now = now + 30
    local w3 = table.concat({ "global", "delay-3", tostring(base + 70), "*", "Delay Origin", "NH", "beat" }, "|")
    assert(b.BetaNetwork:Receive(w3, "Delay Origin", "CHANNEL")); drain()
    b.Sync.SendToBNet = originalSendToBNet
    local seenFirst, seenSecond, seenThird = false, false, false
    for _, at in ipairs(forwarded) do
        if at == base - 20 then seenFirst = true end
        if at == base + 25 then seenSecond = true end
        if at == base + 70 then seenThird = true end
    end
    assert(seenFirst and not seenSecond and seenThird,
        "Presence forwarding depended on arrival time instead of the author's timestamp")
end
-- A kill reaches its author's direct neighbours but is never re-forwarded.
do
    local before = #d.received
    assert(a.BetaNetwork:Send("K", "kill-not-forwarded"))
    drain()
    for i = before + 1, #d.received do
        assert(d.received[i].payload ~= "kill-not-forwarded", "A relayed kill was forwarded past its first hop")
    end
    local heardByNeighbour = false
    for _, r in ipairs(b.received) do if r.payload == "kill-not-forwarded" then heardByNeighbour = true end end
    assert(heardByNeighbour, "The author's direct copy of a kill was lost")
end
-- A channel that stays throttled must neither stall the Battle.net copy behind it
-- nor retry forever: three bounded retries, then the copy is counted as dropped.
b.refuseAlways = true
local refusedBefore, droppedBefore = b.BetaNetwork.stats.refused or 0, b.BetaNetwork.stats.dropped
assert(b.BetaNetwork:Send("C", "bridge-channel-throttled"))
drain()
b.refuseAlways = nil
assert(c.received[#c.received].payload == "bridge-channel-throttled",
    "Throttled channel copy blocked the Battle.net bridge")
assert((b.BetaNetwork.stats.refused or 0) - refusedBefore == 4
    and b.BetaNetwork.stats.dropped - droppedBefore == 1, "Refused channel copy was not bounded")
-- A friend disconnecting must not hold the FIFO until its packet expires.
us.offline = true
local started = now
assert(a.BetaNetwork:Send("C", "dead-friend-one"))
assert(a.BetaNetwork:Send("C", "dead-friend-two"))
drain()
assert(now - started < 20 and d.received[#d.received].payload == "dead-friend-two", "Offline BNet friend blocked the relay")
IsInGroup = function() return true end
assert(a.BetaNetwork:Send("HB", string.rep("y", 3300))); drain()
assert(d.received[#d.received].payload == string.rep("y", 3300), "Large history page lost fragments")
-- Targeted request/reply traverses the reverse route without cross-faction whispers.
local before = #a.received
assert(a.BetaNetwork:Send("SR", "request", d.name)); drain()
assert(#a.received == before + 1 and a.received[#a.received].payload == "reply"
    and a.received[#a.received].origin == d.name, "Routed reply did not return")
assert(not c.BetaNetwork:Receive(b.lastWire, "Forged Tester"), "Last-hop identity was not verified")
assert(not a.BetaNetwork:Send("RESET", "all"), "Administrative mutation entered gameplay relay")
assert(not a.BetaNetwork:Send("K", string.rep("x", 4000)), "Oversized packet was queued")
now = now + 301
assert(not a.BetaNetwork:IsPeer(d.name), "Stale peer route never expired")
assert(not c.BetaNetwork:Receive(b.lastWire, b.name), "Expired packet was replayed")
-- Hard queue bound under overload; producers receive an explicit false result.
local accepted = 0
for i = 1, 200 do if a.BetaNetwork:Send("K", tostring(i)) then accepted = accepted + 1 end end
assert(accepted == 84 and a.BetaNetwork.stats.dropped >= 116, "Ordinary traffic consumed reserved catch-up/state/paged slots")
drain()
-- A Horde gateway with five Horde friends and one Alliance friend (listed last)
-- must hand every packet to the Alliance bridge, not one packet in two.
local gate = client("Gate Tester", "gate")
gate.PlayerFaction = "Horde"
local ally = client("Ally Tester", "ally")
ally.faction, ally.PlayerFaction = "Alliance", "Alliance"
for _, n in ipairs({ "Horde One", "Horde Two", "Horde Three", "Horde Four", "Horde Five" }) do
    local friend = client(n, "friend " .. n)
    friend.faction = "Horde"
    gate.friends[#gate.friends + 1] = friend
end
gate.friends[#gate.friends + 1] = ally
local sentTo = {}
local gateSend = gate.Sync.SendToBNet
function gate.Sync:SendToBNet(other, kind, wire)
    sentTo[other.name] = (sentTo[other.name] or 0) + 1
    return gateSend(self, other, kind, wire)
end
for i = 1, 10 do
    assert(gate.BetaNetwork:Send("C", "bridge-" .. i)); drain()
end
local bridged = 0
for _, row in ipairs(ally.received) do
    if row.payload:match("^bridge%-") then bridged = bridged + 1 end
end
assert(bridged == 10, "Opposite-faction friend missed packets behind same-faction rotation: " .. bridged)
local hordeSends = 0
for name, count in pairs(sentTo) do if name ~= ally.name then hordeSends = hordeSends + count end end
assert(hordeSends == 20, "Same-faction rotation no longer shares the remaining slots")
-- The friend a packet came from already has it: never bounce it back.
ally.friends = { gate }
gate.faction = "Horde"
sentTo = {}
assert(ally.BetaNetwork:Send("C", "from-ally")); drain()
assert(gate.received[#gate.received].payload == "from-ally", "Alliance packet did not reach the gateway")
assert(not sentTo[ally.name], "Gateway bounced a packet back to the friend on its path")
-- Saturated bridge: a capture alert overtakes queued kills, and a full queue
-- displaces its oldest waiting kill instead of refusing the alert.
local rush = client("Rush Tester", "rush")
local watch = client("Watch Tester", "rush")
for i = 1, 60 do assert(rush.BetaNetwork:Send("K", "bulk-" .. i)) end
assert(rush.BetaNetwork:Send("ZS", "alert-now"))
drain()
assert(watch.received[1] and watch.received[1].kind == "ZS",
    "Capture alert waited behind queued kills")
local full = client("Full Tester", "full")
local fullWatch = client("Fullwatch Tester", "full")
for i = 1, 84 do assert(full.BetaNetwork:Send("K", "fill-" .. i)) end
local fullTargets = full.Sync.GetBetaBNetTargets
full.Sync.GetBetaBNetTargets = function() error('Refused packet still allocated routes/fragments') end
assert(not full.BetaNetwork:Send("K", "fill-overflow"), "Bulk packet exceeded the queue bound")
full.Sync.GetBetaBNetTargets = fullTargets
assert(full.BetaNetwork:Send("ZS", "alert-full"), "Full queue refused a capture alert")
assert(full.BetaNetwork.stats.displaced == 1, "Alert did not displace exactly one waiting kill")
drain()
assert(fullWatch.received[1].payload == "alert-full", "Displacing alert was not sent first")
assert(#fullWatch.received == 84, "Ordinary queue bound changed: " .. #fullWatch.received)
-- A busy bridge (queue full of bulk) must still send its catch-up request and ack.
do
    local busy = client("Busy Tester", "busy")
    client("Busywatch Tester", "busy")
    for i = 1, 84 do assert(busy.BetaNetwork:Send("K", "busy-fill-" .. i)) end
    assert(busy.BetaNetwork:Send("HR", "catch-up-request"), "Full relay queue refused a catch-up request")
    assert(busy.BetaNetwork:Send("HA", "catch-up-ack"), "Full relay queue refused a catch-up acknowledgement")
    assert(busy.BetaNetwork:IsUrgentPacket("HR", "x") and not busy.BetaNetwork:IsUrgentPacket("HB", "x")
        and not busy.BetaNetwork:IsUrgentPacket("LK", "x"), "Catch-up data must stay in the bulk lane")
    drain()
end
-- A long local quota wait must not churn retry records or discard copies after
-- three seconds. Ready BNet work behind waiting copies in BOTH lanes still runs.
do
    local paced = client("Paced Tester", "paced")
    local peer = client("Pacedwatch Tester", "paced")
    local readyAt, rejects, bnetAt = now + 8, 0, {}
    local send = paced.Sync.SendToChannel
    IsInGroup = function() return false end
    paced.friends = { peer }
    function paced.Sync:ChannelTokenReady() return now >= readyAt end
    function paced.Sync:SendToChannel(kind, payload)
        if now < readyAt then rejects = rejects + 1; return false, "budget" end
        return send(self, kind, payload)
    end
    function paced.Sync:SendToBNet(_, _, wire)
        bnetAt[wire:match("([^|]+)$")] = now
        return true
    end
    assert(paced.BetaNetwork:Send("K", "paced-bulk"))
    assert(paced.BetaNetwork:Send("ZS", "paced-urgent"))
    C_Timer.After(1, function()
        assert(paced.BetaNetwork:Send("K", "behind-bulk"))
        assert(paced.BetaNetwork:Send("ZS", "behind-urgent"))
    end)
    drain()
    assert(rejects == 4, "Quota-blocked copies were polled/reallocated on every tick")
    assert(bnetAt["behind-bulk"] < readyAt and bnetAt["behind-urgent"] < readyAt,
        "Blocked lane heads delayed ready BNet traffic")
    assert(#peer.received == 4 and not paced.BetaNetwork.stats.channelSkipped,
        "Waiting copies expired after 30 polls instead of waiting for the quota")
    IsInGroup = function() return true end
end
-- Continuous priority traffic must not starve addressed ranking data. The real
-- fragmented whisper path runs while alerts keep the ordinary lane saturated.
do
    local fair = client("Fair Tester", "fair")
    local receiver = client("Fairwatch Tester", "fair")
    fair.BetaNetwork.peers[receiver.name:lower()] = { via = receiver.name, transport = "CHANNEL", at = now }
    for i = 1, 84 do assert(fair.BetaNetwork:Send("ZS", "pressure-" .. i)) end
    assert(fair.BetaNetwork:CanSendLeaderboardPage(), "A busy alert lane blocked page admission")
    for i = 1, 16 do assert(fair.BetaNetwork:Send("LK", "reserved-score-" .. i, receiver.name)) end
    assert(not fair.BetaNetwork:Send("LK", "reserved-overflow", receiver.name), "Catch-up queue is unbounded")
    assert(fair.BetaNetwork:CanSendLeaderboardPage(),
        "Legacy LK backlog blocked reserved v5/v6 page admission")
    local start = now
    for i = 1, 225 do
        C_Timer.After(i * 0.2, function() fair.BetaNetwork:Send("ZS", "continuous-alert-" .. i) end)
    end
    drain()
    local delivered, lastScore, firstAlert = 0, nil, nil
    for _, row in ipairs(receiver.received) do
        if row.kind == "LK" then delivered = delivered + 1; lastScore = row.at
        elseif row.kind == "ZS" then firstAlert = firstAlert or row.at end
    end
    assert(delivered == 16 and lastScore - start < 25, "Ranking data starved behind continuous alerts")
    assert(firstAlert and firstAlert - start < 2, "Reserved ranking share starved live alerts")
    assert(not fair.BetaNetwork.kindStats.LK.dropped or fair.BetaNetwork.kindStats.LK.dropped == 1,
        "Live traffic evicted reserved ranking packets")
end
-- A presence returned by a peer proves that peer already has it. Suppress just
-- its pending BNet copy, not copies needed by other peers or an unverified hop.
do
    local gate = client("Echo Tester", "echo")
    local neighbour = client("Neighbour Tester", "echo")
    local remote = client("Remote Tester", "remote")
    gate.friends = { neighbour, remote }
    local bnetCopies = {}
    local sendBNet, sendChannel = gate.Sync.SendToBNet, gate.Sync.SendToChannel
    function gate.Sync:SendToBNet(peer, kind, wire)
        bnetCopies[peer] = (bnetCopies[peer] or 0) + 1
        return sendBNet(self, peer, kind, wire)
    end
    function gate.Sync:SendToChannel(kind, fragment)
        local result = sendChannel(self, kind, fragment)
        local wire = fragment:match("^[^:]+:1:1:(.+)$")
        if wire and wire:find("|NH|", 1, true) then
            wire = wire:gsub("|Echo Tester|NH|", "|Echo Tester,Neighbour Tester|NH|")
            gate.BetaNetwork:Receive(wire, remote.name, "BNET", remote)
            assert(not gate.BetaNetwork.stats.presenceCopiesSkipped, "Unverified last hop cancelled a presence")
            gate.BetaNetwork:Receive(wire, neighbour.name, "BNET", neighbour)
        end
        return result
    end
    IsInGroup = function() return false end
    assert(gate.BetaNetwork:Send("NH", "echo-presence"))
    drain()
    assert(not bnetCopies[neighbour] and bnetCopies[remote] == 1, "Presence suppression skipped the wrong recipient")
    assert(neighbour.BetaNetwork:IsPeer(gate.name) and remote.BetaNetwork:IsPeer(gate.name),
        "Reducing redundant copies lost a peer")
    assert(gate.BetaNetwork.stats.presenceCopiesSkipped == 1, "Redundant presence copy was not counted")
    -- Supersede an unsent old heartbeat during congestion without waiting for a
    -- new interval; the new value keeps the existing queue position.
    gate.Sync.SendToChannel = sendChannel
    assert(gate.BetaNetwork:Send("NH", "old-unsent"))
    now = now + 45
    assert(gate.BetaNetwork:Send("NH", "fresh-unsent"))
    drain()
    assert(gate.BetaNetwork.stats.presenceCoalesced == 1, "Unsent presence was not replaced by the fresh value")
    assert(gate.lastWire:find("|NH|fresh-unsent", 1, true), "Stale presence was sent after its replacement")
    IsInGroup = function() return true end
end
-- Sixteen slots are reserved, not a smaller hard cap. A legacy burst may borrow
-- idle slots up to the non-state allotment; a live alert reclaims an excess slot.
do
    local burst = client("Burst Tester", "burst")
    local receiver = client("Burstwatch Tester", "burst")
    burst.BetaNetwork.peers[receiver.name:lower()] = { via = receiver.name, transport = "CHANNEL", at = now }
    for i = 1, 100 do assert(burst.BetaNetwork:Send("LK", "burst-score-" .. i, receiver.name)) end
    assert(not burst.BetaNetwork:Send("LK", "burst-overflow", receiver.name), "Borrowing exceeded the total queue bound")
    assert(burst.BetaNetwork:Send("ZS", "burst-alert"), "Borrowed catch-up capacity blocked a live alert")
    drain()
    local kept, alerts = {}, 0
    for _, row in ipairs(receiver.received) do
        if row.kind == "LK" then kept[row.payload] = true else alerts = alerts + 1 end
    end
    for i = 1, 16 do assert(kept['burst-score-' .. i], 'Reserved catch-up slot was reclaimed') end
    assert(#receiver.received == 100 and alerts == 1, 'Borrowed queue capacity was not bounded/reclaimed correctly')
end
-- Retail's login requests only the map; ranking has its own paged catch-up.
-- Discovering a peer must not start another full ranking response on the bridge.
do
    local joiner = client("Joiner Tester", "joiner")
    local request
    function joiner.Sync:SendSyncRequest(opts) request = opts; return true end
    local hello = "global|map-hello|" .. time() .. "|*|Veteran Tester|NH|1.1.1"
    assert(joiner.BetaNetwork:Receive(hello, "Veteran Tester", "CHANNEL"))
    assert(request and request.betaTarget == "Veteran Tester", "No targeted map request on discovery")
    assert(not request.fullResponse and not request.stateResponse,
        "Peer discovery still requests a full ranking instead of the map")
    drain()
end
-- Old clients may keep sending fortress siege packets during the transition.
-- They cannot occupy the new relay queue, deliver data or evict useful traffic.
do
    local modern = client("Modern Tester", "modern")
    local beforeDrops = modern.BetaNetwork.stats.dropped
    for _, kind in ipairs({ "GK", "GC", "GA", "GH", "G7" }) do
        assert(not modern.BetaNetwork:Send(kind, "old-fortress"), "Retired producer accepted: " .. kind)
        local packet = { kind = kind, payload = "old-fortress", target = "*", path = { "Legacy Tester" } }
        assert(not modern.BetaNetwork:Queue(packet), "Retired packet queued: " .. kind)
        local wire = "global|retired-" .. kind .. "|" .. time() .. "|*|Legacy Tester|" .. kind .. "|old-fortress"
        assert(not modern.BetaNetwork:Receive(wire, "Legacy Tester", "CHANNEL"),
            "Retired packet received: " .. kind)
    end
    assert(#modern.received == 0 and modern.BetaNetwork.stats.dropped == beforeDrops,
        "Retired messages consumed admission capacity")
end
a.BetaNetworkEnabled = false
assert(not a.BetaNetwork:Send("K", "disabled"), "Beta transport remained active after community re-enable")
print("Beta network: community-parallel relay, fragmentation, global routing, reply path, dedup, identity, expiry and queue bounds OK")
