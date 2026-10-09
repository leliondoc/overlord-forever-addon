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
            local bytes = replica.Relay.stats.bytes or 0
            local credit = math.min(500, (replica.credit or 500) + (now - (replica.checkedAt or 100)) * 1000)
            assert(bytes - (replica.checkedBytes or 0) <= credit + 0.001, "Shared transport budget exceeded")
            replica.credit = credit - (bytes - (replica.checkedBytes or 0))
            replica.checkedAt, replica.checkedBytes = now, bytes
        end
        assert(calls < 100000, "Relay loop / unbounded pump")
    end
end
local function client(name, channel, pool)
    local a = { Version = "1.0.0", CommunityModeEnabled = true, RelayEnabled = true,
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
                other.Relay:ReceiveFragment(fragment, name, "CHANNEL")
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
            other.Relay:Receive(wire, name, "BNET", a)
        else
            assert(kind == "BF")
            other.Relay:ReceiveFragment(wire, name, "BNET", a)
        end
        return true
    end
    function s:SendWhisper(kind, data, target)
        assert(kind == "BF" and #data + 3 <= 255)
        for _, other in ipairs(clients) do
            if other.name == target then other.Relay:ReceiveFragment(data, name, "WHISPER") end
        end
        return true
    end
    function s:OnAddonMessage(_, message, transport, origin)
        assert(transport == "BETA")
        assert(a.Relay:IsDispatching(origin))
        local kind, payload = strsplit(":", message, 2)
        a.received[#a.received + 1] = { kind = kind, payload = payload, origin = origin, at = now }
        -- A snapshot handler must not re-author the same received state.
        assert(a.Relay:Broadcast(kind, payload) == 0)
        if kind == "MN" and a.Relay:IsTargetedDispatch() then
            a.Relay:Send("MS", "reply", origin)
        elseif kind ~= "MS" then
            assert(not a.Relay:IsTargetedDispatch(), "Broadcast gained direct-whisper authority")
        end
    end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
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
for kind in ("SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC TV VT VF FR VB MN MS OP OC SH HR HB HA CR CA GR GY GI FC GE GP GX GD GM"):gmatch("%S+") do
    -- K is never re-forwarded: a relayed kill is never credited (anti-forgery).
    -- EK (death notice, front activity only) is never re-forwarded either: it flooded
    -- the whole relay on every PvP death.
    -- SR/GR/CR broadcasts are answered by direct neighbours only (1.2.4): not relayed.
    -- GI is never relayed: receivers apply only the owner's direct copy.
    -- OC/LO/LOC (1.7.2): a capture claim is only believed from its capturer or in a
    -- reply the receiver asked for, so a forwarded copy is never relayed.
    if kind ~= "SR" and kind ~= "K" and kind ~= "EK" and kind ~= "GR" and kind ~= "CR"
        and kind ~= "GI" and kind ~= "OC" and kind ~= "LO" and kind ~= "LOC" then kinds[#kinds + 1] = kind end
end
-- A capture claim reaches the direct neighbour (gateway) but goes no further.
for _, kind in ipairs({ "OC", "LO", "LOC" }) do
    local beforeB, beforeD = #b.received, #d.received
    assert(a.Relay:Send(kind, "site:Guild:A:1:global:Given Family"))
    drain()
    assert(#d.received == beforeD, "A capture claim (" .. kind .. ") was re-forwarded through the gateway")
    assert(#b.received == beforeB + 1, "The gateway itself lost the capture claim " .. kind)
end
do
    local beforeB, beforeD = #b.received, #d.received
    assert(a.Relay:Send("OP", "v1:site:held:0:Guild:A:1:0:1:300:global:0:::0:0:Given Family"))
    drain()
    assert(#d.received == beforeD, "A held outpost state was re-forwarded through the gateway")
    assert(#b.received == beforeB + 1, "The gateway itself lost the held state")
end
-- A death notice reaches the direct neighbour (gateway) but goes no further.
do
    local beforeB, beforeD = #b.received, #d.received
    assert(a.Relay:Send("EK", "death-notice"))
    drain()
    assert(#d.received == beforeD, "A death notice (EK) was re-forwarded through the gateway")
    assert(#b.received == beforeB + 1, "The gateway itself lost the death notice")
end
for _, kind in ipairs(kinds) do
    assert(a.Relay:Send(kind, string.rep("x", 450)))
    drain()
    local received = d.received[#d.received]
    assert(received and received.kind == kind and received.origin == a.name
        and #received.payload == 450, "Community message lost through gateway: " .. kind)
end
assert(#d.received == #kinds, "Duplicate routes produced duplicate delivery")
assert(#us.received == #kinds, "Global Forever data did not reach the former NA route")
assert(#a.received == 0, "Original sender received its own forwarded event")
a.refuseChannel = true
assert(a.Relay:Broadcast("VB", "front-one", {
    { type = "VB", payload = "front-two" }, { type = "VB", payload = "bonus" },
    { type = "MS", payload = "stock" },
}) == 1)
drain()
for i, payload in ipairs({ "front-one", "front-two", "bonus", "stock" }) do
    assert(d.received[#kinds + i].payload == payload, "Bundled payload/throttled fragment lost: " .. payload)
end
IsInGroup = function() return false end
a.refuseChannel = true
assert(a.Relay:Send("C", "retry-without-group"))
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
    b.Relay:ReceiveFragment("probe-1:1:1:x", a.name, "CHANNEL")
    assert(b.Relay:Receive(groupWire("raid-1", a.name), a.name, "RAID"))
    drain()
    assert(channelSends == 0, "Raid copy from a channel peer was re-emitted on the channel")
    assert(c.received[#c.received].payload == "raid-copy-raid-1", "Raid copy no longer reached the bridge")
    assert(b.Relay:Receive(groupWire("raid-2", "Remote Realmer"), "Remote Realmer", "RAID"))
    drain()
    assert(channelSends > 0, "Raid copy from another realm was not forwarded to the channel")
    b.Sync.SendToChannel = originalSendToChannel
end
-- Our own 1 s channel byte budget is not a Blizzard refusal: the fragment waits in
-- place (as before) and is never counted as refused nor dropped.
do
    local refusedBefore, droppedBefore = b.Relay.stats.refused or 0, b.Relay.stats.dropped
    b.budgetTicks = 8
    assert(b.Relay:Send("C", "bridge-budget-wait"))
    drain()
    assert(a.received[#a.received].payload == "bridge-budget-wait", "Budget-deferred channel copy was lost")
    assert((b.Relay.stats.refused or 0) == refusedBefore and b.Relay.stats.dropped == droppedBefore,
        "Local channel budget was treated as a Blizzard refusal")
end
-- Keeps/outposts are the lowest priority: only sieges in progress and rare final
-- events stay in the urgent lane; captures and alerts keep priority.
do
    local n = a.Relay
    assert(n:IsUrgentPacket("C", "x") and n:IsUrgentPacket("ZS", "x") and n:IsUrgentPacket("TV", "x"))
    assert(n:IsUrgentPacket("OC", "x"))
    assert(n:IsUrgentPacket("OP", "v1:site:in_progress:1"))
    assert(not n:IsUrgentPacket("GK", "v9:site:held:1") and not n:IsUrgentPacket("OP", "v1:site:neutral:1"))
    assert(not n:IsUrgentPacket("G7", "x") and not n:IsUrgentPacket("GH", "x") and not n:IsUrgentPacket("K", "x"))
end
-- A bridge never relays another player's presence (NH, 1.2.4).
do
    local channelSends = 0
    local originalSendToChannel = c.Sync.SendToChannel
    c.Sync.SendToChannel = function(self, kind, fragment)
        channelSends = channelSends + 1
        return originalSendToChannel(self, kind, fragment)
    end
    local before = #d.received
    assert(a.Relay:Send("NH", "presence-one")); drain()
    local afterFirst = channelSends
    now = now + 5
    assert(a.Relay:Send("NH", "presence-two")); drain()
    c.Sync.SendToChannel = originalSendToChannel
    assert(afterFirst == 0 and channelSends == 0, "The bridge relayed another player's presence")
    assert(#d.received == before, "Presence was dispatched as a sync message")
end
-- /ov network: relay cost per kind (bytes sent, packets, drops), heaviest first.
do
    local lines = table.concat(a.Relay:GetKindDiagnostics(12), " ")
    assert(lines:find("Relay by type", 1, true) and a.Relay.kindStats.VB
        and a.Relay.kindStats.VB.queued > 0 and a.Relay.kindStats.VB.bytes > 0,
        "Relay per-kind diagnostics missing: " .. lines)
end
-- 1.2.4: presence is never relayed. Over ten minutes of beats from a, its direct
-- neighbour b keeps a fresh direct route, while the far peer d (a -> b -> BNet ->
-- c -> d) stops knowing a once earlier routes expire: presence alone never reaches it.
do
    local startAt = now
    local nextBeat = now
    while now < startAt + 600 do
        if now >= nextBeat then
            assert(a.Relay:Send("NH", "beat-" .. math.floor(now)))
            nextBeat = nextBeat + 45
        end
        drain()
        now = now + 5
    end
    assert(b.Relay:IsDirectPeer(a.name), "The direct neighbour lost the presence route")
    assert(not d.Relay:IsPeer(a.name), "A far peer still learned a relayed presence")
end
-- Transit delays must not change the presence decision: it follows the author's
-- timestamp, identical at every hop (Astra's case: 20 s late, then 75 s gap).
-- Since 1.2.4 only shard presence (SH) is still forwarded, so the check uses SH.
do
    local forwarded = {}
    local originalSendToBNet = b.Sync.SendToBNet
    b.Sync.SendToBNet = function(self, other, kind, wire)
        local at = wire:match("^[^|]*|[^|]*|(%d+)|[^|]*|Delay Origin[^|]*|SH|")
        if at then forwarded[#forwarded + 1] = tonumber(at) end
        return originalSendToBNet(self, other, kind, wire)
    end
    local base = time()
    -- emitted at T (arrives 20 s late), T+45 (no forward), T+90 (arrives only 75 s after T's arrival)
    local w1 = table.concat({ "global", "delay-1", tostring(base - 20), "*", "Delay Origin", "SH", "beat" }, "|")
    assert(b.Relay:Receive(w1, "Delay Origin", "CHANNEL")); drain()
    now = now + 45
    local w2 = table.concat({ "global", "delay-2", tostring(base + 25), "*", "Delay Origin", "SH", "beat" }, "|")
    assert(b.Relay:Receive(w2, "Delay Origin", "CHANNEL")); drain()
    now = now + 30
    local w3 = table.concat({ "global", "delay-3", tostring(base + 70), "*", "Delay Origin", "SH", "beat" }, "|")
    assert(b.Relay:Receive(w3, "Delay Origin", "CHANNEL")); drain()
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
    assert(a.Relay:Send("K", "kill-not-forwarded"))
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
local refusedBefore, droppedBefore = b.Relay.stats.refused or 0, b.Relay.stats.dropped
assert(b.Relay:Send("C", "bridge-channel-throttled"))
drain()
b.refuseAlways = nil
assert(c.received[#c.received].payload == "bridge-channel-throttled",
    "Throttled channel copy blocked the Battle.net bridge")
assert((b.Relay.stats.refused or 0) - refusedBefore == 4
    and b.Relay.stats.dropped - droppedBefore == 1, "Refused channel copy was not bounded")
-- A friend disconnecting must not hold the FIFO until its packet expires.
us.offline = true
local started = now
assert(a.Relay:Send("C", "dead-friend-one"))
assert(a.Relay:Send("C", "dead-friend-two"))
drain()
assert(now - started < 20 and d.received[#d.received].payload == "dead-friend-two", "Offline BNet friend blocked the relay")
IsInGroup = function() return true end
assert(a.Relay:Send("HB", string.rep("y", 3300))); drain()
assert(d.received[#d.received].payload == string.rep("y", 3300), "Large history page lost fragments")
-- Targeted request/reply traverses the reverse route without cross-faction whispers.
local before = #a.received
assert(a.Relay:Send("MN", "request", d.name)); drain()
assert(#a.received == before + 1 and a.received[#a.received].payload == "reply"
    and a.received[#a.received].origin == d.name, "Routed reply did not return")
-- Catch-up is point to point (1.2.4): never started toward a peer behind relays.
assert(not a.Relay:IsDirectPeer(d.name), "Test setup: the far peer looked direct")
assert(not a.Relay:Send("SR", "request", d.name), "A catch-up request left for a far peer")
assert((a.Relay.stats.catchupNotDirect or 0) >= 1, "Refused far catch-up was not counted")
assert(not c.Relay:Receive(b.lastWire, "Forged Tester"), "Last-hop identity was not verified")
assert(not a.Relay:Send("RESET", "all"), "Administrative mutation entered gameplay relay")
assert(not a.Relay:Send("K", string.rep("x", 4000)), "Oversized packet was queued")
now = now + 301
assert(not a.Relay:IsPeer(d.name), "Stale peer route never expired")
assert(not c.Relay:Receive(b.lastWire, b.name), "Expired packet was replayed")
-- Hard queue bound under overload; producers receive an explicit false result.
local accepted = 0
for i = 1, 200 do if a.Relay:Send("K", tostring(i)) then accepted = accepted + 1 end end
assert(accepted == 84 and a.Relay.stats.dropped >= 116, "Ordinary traffic consumed reserved catch-up/state/paged slots")
drain()
-- Own kill totals are absolute: a newer unsent total of the same zone replaces the
-- waiting one; a total carrying the race is kept; another zone is not merged.
do
    local killer = client("Killer Tester", "kills")
    local watcher = client("Killwatch Tester", "kills")
    local function kills(prefix)
        local out = {}
        for _, row in ipairs(watcher.received) do
            if row.kind == "K" and row.payload:sub(1, #prefix) == prefix then out[#out + 1] = row.payload end
        end
        return out
    end
    for i = 1, 20 do assert(killer.Relay:Send("K", "Killer Tester:front_a:" .. i .. ":WARRIOR")) end
    drain()
    local got = kills("Killer Tester:front_a:")
    assert(#got <= 2 and got[#got] == "Killer Tester:front_a:20:WARRIOR",
        "Waiting kill totals were not replaced by the newest: " .. #got)
    assert((killer.Relay.stats.killCoalesced or 0) >= 18, "Kill coalescing not counted")
    local raced = "Killer Tester:front_b:21:WARRIOR:Horde:1:G:enus:0:o:2:B1:60"
    assert(killer.Relay:Send("K", "Killer Tester:front_b:20:WARRIOR"))
    assert(killer.Relay:Send("K", raced))
    assert(killer.Relay:Send("K", "Killer Tester:front_b:22:WARRIOR"))
    assert(killer.Relay:Send("K", "Killer Tester:front_c:23:WARRIOR"))
    drain()
    local b = kills("Killer Tester:front_b:")
    local hasRace = false
    for _, payload in ipairs(b) do if payload == raced then hasRace = true end end
    assert(hasRace, "A total carrying the race was replaced by one without it")
    assert(#kills("Killer Tester:front_c:") == 1, "Another zone's total was merged away")
    assert(b[#b] == "Killer Tester:front_b:22:WARRIOR", "A total was merged into another zone's")
end
-- A Horde gateway with five Horde friends and one Alliance friend (listed last).
-- An opposite-faction friend never heard from (no addon, in an instance, not met
-- yet) only gets the rotating copies; once its own traffic reached us it is a live
-- bridge and must get every packet, not one packet in two.
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
-- Our own presence beat reaches every opposite-faction friend not heard yet.
-- (Presence is consumed by the relay itself: count the Battle.net copies.)
assert(gate.Relay:Send("NH", "presence-probe")); drain()
assert(sentTo[ally.name] == 1, "Own presence skipped an opposite-faction friend not heard yet")
sentTo = {}
for i = 1, 6 do
    assert(gate.Relay:Send("C", "quiet-" .. i)); drain()
end
local probed = 0
for _, row in ipairs(ally.received) do
    if row.payload:match("^quiet%-") then probed = probed + 1 end
end
assert(probed == 3, "A friend never heard from was not limited to the rotating copies: " .. probed)
assert(not gate.Relay:IsBNetFriendAlive(ally), "A silent friend counted as a live bridge")
-- The ally's own traffic reaches the gateway over Battle.net.
ally.friends = { gate }
assert(ally.Relay:Send("C", "ally-hello")); drain()
ally.friends = {}
assert(gate.Relay:IsBNetFriendAlive(ally), "A friend heard over Battle.net is not a live bridge")
sentTo = {}
for i = 1, 10 do
    assert(gate.Relay:Send("C", "bridge-" .. i)); drain()
end
local bridged = 0
for _, row in ipairs(ally.received) do
    if row.payload:match("^bridge%-") then bridged = bridged + 1 end
end
assert(bridged == 10, "Opposite-faction friend missed packets behind same-faction rotation: " .. bridged)
local hordeSends = 0
for name, count in pairs(sentTo) do if name ~= ally.name then hordeSends = hordeSends + count end end
assert(hordeSends == 20, "Same-faction rotation no longer shares the remaining slots")
-- A call to arms is for its own faction only: no copy to the live enemy bridge.
sentTo = {}
assert(gate.Relay:Send("FC", "H:front:front")); drain()
assert(not sentTo[ally.name], "A call to arms crossed to the other faction")
assert((sentTo["Horde One"] or 0) + (sentTo["Horde Two"] or 0) + (sentTo["Horde Three"] or 0)
    + (sentTo["Horde Four"] or 0) + (sentTo["Horde Five"] or 0) > 0, "A call to arms lost its own-faction copies")
-- Silent for longer than the window (instance, logout): back to the rotation only.
now = now + 301
assert(not gate.Relay:IsBNetFriendAlive(ally), "A friend silent for 5 min is still a live bridge")
now = now - 301
-- The friend a packet came from already has it: never bounce it back.
ally.friends = { gate }
gate.faction = "Horde"
sentTo = {}
assert(ally.Relay:Send("C", "from-ally")); drain()
assert(gate.received[#gate.received].payload == "from-ally", "Alliance packet did not reach the gateway")
assert(not sentTo[ally.name], "Gateway bounced a packet back to the friend on its path")
-- Saturated bridge: a capture alert overtakes queued kills, and a full queue
-- displaces its oldest waiting kill instead of refusing the alert.
local rush = client("Rush Tester", "rush")
local watch = client("Watch Tester", "rush")
for i = 1, 60 do assert(rush.Relay:Send("K", "bulk-" .. i)) end
assert(rush.Relay:Send("ZS", "alert-now"))
drain()
assert(watch.received[1] and watch.received[1].kind == "ZS",
    "Capture alert waited behind queued kills")
local full = client("Full Tester", "full")
local fullWatch = client("Fullwatch Tester", "full")
for i = 1, 84 do assert(full.Relay:Send("K", "fill-" .. i)) end
local fullTargets = full.Sync.GetBetaBNetTargets
full.Sync.GetBetaBNetTargets = function() error('Refused packet still allocated routes/fragments') end
assert(not full.Relay:Send("K", "fill-overflow"), "Bulk packet exceeded the queue bound")
full.Sync.GetBetaBNetTargets = fullTargets
assert(full.Relay:Send("ZS", "alert-full"), "Full queue refused a capture alert")
assert(full.Relay.stats.displaced == 1, "Alert did not displace exactly one waiting kill")
drain()
assert(fullWatch.received[1].payload == "alert-full", "Displacing alert was not sent first")
assert(#fullWatch.received == 84, "Ordinary queue bound changed: " .. #fullWatch.received)
-- A busy bridge (queue full of bulk) must still send its catch-up request and ack.
do
    local busy = client("Busy Tester", "busy")
    client("Busywatch Tester", "busy")
    for i = 1, 84 do assert(busy.Relay:Send("K", "busy-fill-" .. i)) end
    assert(busy.Relay:Send("HR", "catch-up-request"), "Full relay queue refused a catch-up request")
    assert(busy.Relay:Send("HA", "catch-up-ack"), "Full relay queue refused a catch-up acknowledgement")
    assert(busy.Relay:IsUrgentPacket("HR", "x") and not busy.Relay:IsUrgentPacket("HB", "x")
        and not busy.Relay:IsUrgentPacket("LK", "x"), "Catch-up data must stay in the bulk lane")
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
    assert(paced.Relay:Send("K", "paced-bulk"))
    assert(paced.Relay:Send("ZS", "paced-urgent"))
    C_Timer.After(1, function()
        assert(paced.Relay:Send("K", "behind-bulk"))
        assert(paced.Relay:Send("ZS", "behind-urgent"))
    end)
    drain()
    assert(rejects == 4, "Quota-blocked copies were polled/reallocated on every tick")
    assert(bnetAt["behind-bulk"] < readyAt and bnetAt["behind-urgent"] < readyAt,
        "Blocked lane heads delayed ready BNet traffic")
    assert(#peer.received == 4 and not paced.Relay.stats.channelSkipped,
        "Waiting copies expired after 30 polls instead of waiting for the quota")
    IsInGroup = function() return true end
end
-- Continuous priority traffic must not starve addressed ranking data. The real
-- fragmented whisper path runs while alerts keep the ordinary lane saturated.
do
    local fair = client("Fair Tester", "fair")
    local receiver = client("Fairwatch Tester", "fair")
    fair.Relay.peers[receiver.name:lower()] = { via = receiver.name, transport = "CHANNEL", at = now, hops = 1 }
    for i = 1, 84 do assert(fair.Relay:Send("ZS", "pressure-" .. i)) end
    assert(fair.Relay:CanSendLeaderboardPage(), "A busy alert lane blocked page admission")
    for i = 1, 16 do assert(fair.Relay:Send("LK", "reserved-score-" .. i, receiver.name)) end
    assert(not fair.Relay:Send("LK", "reserved-overflow", receiver.name), "Catch-up queue is unbounded")
    assert(fair.Relay:CanSendLeaderboardPage(),
        "Legacy LK backlog blocked reserved v5/v6 page admission")
    local start = now
    for i = 1, 225 do
        C_Timer.After(i * 0.2, function() fair.Relay:Send("ZS", "continuous-alert-" .. i) end)
    end
    drain()
    local delivered, lastScore, firstAlert = 0, nil, nil
    for _, row in ipairs(receiver.received) do
        if row.kind == "LK" then delivered = delivered + 1; lastScore = row.at
        elseif row.kind == "ZS" then firstAlert = firstAlert or row.at end
    end
    assert(delivered == 16 and lastScore - start < 25, "Ranking data starved behind continuous alerts")
    assert(firstAlert and firstAlert - start < 2, "Reserved ranking share starved live alerts")
    assert(not fair.Relay.kindStats.LK.dropped or fair.Relay.kindStats.LK.dropped == 1,
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
            gate.Relay:Receive(wire, remote.name, "BNET", remote)
            assert(not gate.Relay.stats.presenceCopiesSkipped, "Unverified last hop cancelled a presence")
            gate.Relay:Receive(wire, neighbour.name, "BNET", neighbour)
        end
        return result
    end
    IsInGroup = function() return false end
    assert(gate.Relay:Send("NH", "echo-presence"))
    drain()
    assert(not bnetCopies[neighbour] and bnetCopies[remote] == 1, "Presence suppression skipped the wrong recipient")
    assert(neighbour.Relay:IsPeer(gate.name) and remote.Relay:IsPeer(gate.name),
        "Reducing redundant copies lost a peer")
    assert(gate.Relay.stats.presenceCopiesSkipped == 1, "Redundant presence copy was not counted")
    -- Supersede an unsent old heartbeat during congestion without waiting for a
    -- new interval; the new value keeps the existing queue position.
    gate.Sync.SendToChannel = sendChannel
    assert(gate.Relay:Send("NH", "old-unsent"))
    now = now + 45
    assert(gate.Relay:Send("NH", "fresh-unsent"))
    drain()
    assert(gate.Relay.stats.presenceCoalesced == 1, "Unsent presence was not replaced by the fresh value")
    assert(gate.lastWire:find("|NH|fresh-unsent", 1, true), "Stale presence was sent after its replacement")
    IsInGroup = function() return true end
end
-- Sixteen slots are reserved, not a smaller hard cap. A legacy burst may borrow
-- idle slots up to the non-state allotment; a live alert reclaims an excess slot.
do
    local burst = client("Burst Tester", "burst")
    local receiver = client("Burstwatch Tester", "burst")
    burst.Relay.peers[receiver.name:lower()] = { via = receiver.name, transport = "CHANNEL", at = now, hops = 1 }
    for i = 1, 100 do assert(burst.Relay:Send("LK", "burst-score-" .. i, receiver.name)) end
    assert(not burst.Relay:Send("LK", "burst-overflow", receiver.name), "Borrowing exceeded the total queue bound")
    assert(burst.Relay:Send("ZS", "burst-alert"), "Borrowed catch-up capacity blocked a live alert")
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
    assert(joiner.Relay:Receive(hello, "Veteran Tester", "CHANNEL"))
    assert(request and request.betaTarget == "Veteran Tester", "No targeted map request on discovery")
    assert(not request.fullResponse and not request.stateResponse,
        "Peer discovery still requests a full ranking instead of the map")
    drain()
end
-- Old clients may keep sending fortress siege packets during the transition.
-- They cannot occupy the new relay queue, deliver data or evict useful traffic.
do
    local modern = client("Modern Tester", "modern")
    local beforeDrops = modern.Relay.stats.dropped
    for _, kind in ipairs({ "GK", "GC", "GA", "GH", "G7" }) do
        assert(not modern.Relay:Send(kind, "old-fortress"), "Retired producer accepted: " .. kind)
        local packet = { kind = kind, payload = "old-fortress", target = "*", path = { "Legacy Tester" } }
        assert(not modern.Relay:Queue(packet), "Retired packet queued: " .. kind)
        local wire = "global|retired-" .. kind .. "|" .. time() .. "|*|Legacy Tester|" .. kind .. "|old-fortress"
        assert(not modern.Relay:Receive(wire, "Legacy Tester", "CHANNEL"),
            "Retired packet received: " .. kind)
    end
    assert(#modern.received == 0 and modern.Relay.stats.dropped == beforeDrops,
        "Retired messages consumed admission capacity")
end
-- Group and raid share Blizzard's ~1 msg/s per-prefix quota with the channel: the
-- relay copies to the group only what Sync:GroupCarries keeps (no background pages).
do
    local grouped = client("Grouped Tester", "grouped")
    local groupKinds = {}
    function grouped.Sync:SendToGroup(kind, fragment)
        -- Fragment = "id:i:n:" .. wire ; wire = pool|id|ts|target|origin|KIND|payload.
        groupKinds[#groupKinds + 1] = fragment:match("^[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|([%u%d]+)|") or kind
        return true
    end
    function grouped.Sync:GroupCarries(kind) return kind ~= "ZA" end
    -- As in Sync.lua: map pages never go on the channel either.
    function grouped.Sync:ChannelCarries(kind) return kind ~= "ZA" end
    local wasInGroup = IsInGroup
    IsInGroup = function() return true end
    assert(grouped.Relay:Send("ZA", "map-page"))
    assert(grouped.Relay:Send("C", "capture-final"))
    drain()
    IsInGroup = wasInGroup
    local sawZA, sawC = false, false
    for _, k in ipairs(groupKinds) do
        if k == "ZA" then sawZA = true elseif k == "C" then sawC = true end
    end
    assert(sawC, "A capture final lost its group copy")
    assert(not sawZA, "A background map page was still copied to the group")
    -- Leaving out a background group copy is not a relay loss.
    assert(grouped.Relay.stats.dropped == 0, "A suppressed group copy was counted as lost")
    -- An addressed reply to a mate known through the group keeps its group copy: it
    -- may be the only way to reach a cross-realm or channel-less team mate.
    IsInGroup = function() return true end
    local hello = "global|mate-hello|" .. time() .. "|*|Mate Tester|NH|1.1.1"
    assert(grouped.Relay:Receive(hello, "Mate Tester", "PARTY"))
    groupKinds = {}
    assert(grouped.Relay:Send("ZA", "map-page-for-mate", "Mate Tester"), "Addressed map page refused")
    drain()
    IsInGroup = wasInGroup
    local delivered = false
    for _, k in ipairs(groupKinds) do if k == "ZA" then delivered = true end end
    assert(delivered, "An addressed map page to a group-only mate lost its only delivery path")
end
-- Fight brackets (FK) travel on the relay like other broadcasts.
do
    local fkOne, fkTwo = client("Fkone Tester", "fk-chan"), client("Fktwo Tester", "fk-chan")
    assert(fkOne.Relay:Send("FK", "1:arathi:30:59650000"), "A fight bracket was refused by the relay")
    drain()
    local got = fkTwo.received[#fkTwo.received]
    assert(got and got.kind == "FK" and got.payload == "1:arathi:30:59650000", "A fight bracket was not delivered")
end
-- A capture in two fragments survives a busy channel: single-fragment packets heard
-- between its pieces never take its reassembly slot.
do
    local busy = client("Busy Tester", "busy-chan")
    local wire = "global|twopart-1|" .. time() .. "|*|Origin Tester|C|" .. string.rep("c", 260)
    local first, second = wire:sub(1, 170), wire:sub(171)
    assert(#second > 0 and #second <= 170, "Fixture must need exactly two fragments")
    assert(busy.Relay:ReceiveFragment("twopart-1:1:2:" .. first, "Origin Tester", "CHANNEL"))
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 150 do
        local who = "Noise" .. letters:sub(i % 26 + 1, i % 26 + 1) .. letters:sub(math.floor(i / 26) + 1, math.floor(i / 26) + 1) .. " Tester"
        local single = "global|noise-" .. i .. "|" .. time() .. "|*|" .. who .. "|SH|" .. i
        busy.Relay:ReceiveFragment("noise-" .. i .. ":1:1:" .. single, who, "CHANNEL")
    end
    busy.Relay:ReceiveFragment("twopart-1:2:2:" .. second, "Origin Tester", "CHANNEL")
    drain()
    local got = false
    for _, row in ipairs(busy.received) do
        if row.kind == "C" and row.payload == string.rep("c", 260) then got = true end
    end
    assert(got, "A two-fragment capture was lost to single-fragment traffic between its pieces")
end
-- A late copy of a packet is still recognised after thousands of others (a busy
-- channel recycled a 2,048-entry ring in seconds and handled duplicates again).
do
    local late = client("Late Tester", "late-chan")
    local function deliveries(payload)
        local n = 0
        for _, row in ipairs(late.received) do if row.payload == payload then n = n + 1 end end
        return n
    end
    local first = "global|late-1|" .. time() .. "|*|Origin Tester|SH|late-first"
    assert(late.Relay:Receive(first, "Origin Tester", "CHANNEL"))
    for i = 1, 3000 do
        late.Relay:Receive("global|flood-" .. i .. "|" .. time() .. "|*|Flood Tester|SH|" .. i,
            "Flood Tester", "CHANNEL")
    end
    assert(not late.Relay:Receive(first, "Origin Tester", "CHANNEL"), "A late duplicate was handled again")
    drain()
    assert(deliveries("late-first") == 1, "A late duplicate was delivered twice")
end
-- A packet a raid mate gives us goes back to the channel only if that mate is not
-- on our channel: still true after a thousand other players spoke there since
-- (the 256-entry memory of a launch channel recycled in seconds).
do
    local hop = client("Hop Tester", "hop-chan")
    local onChannel = 0
    local hopChannel = hop.Sync.SendToChannel
    function hop.Sync:SendToChannel(kind, fragment)
        if fragment:find("raid-zs", 1, true) then onChannel = onChannel + 1 end
        return hopChannel(self, kind, fragment)
    end
    hop.Relay:ReceiveFragment("heard-1:1:1:global|heard-1|" .. time() .. "|*|Mate Tester|SH|1",
        "Mate Tester", "CHANNEL")
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 1000 do
        local who = "Chat" .. letters:sub(i % 26 + 1, i % 26 + 1)
            .. letters:sub(math.floor(i / 26) % 26 + 1, math.floor(i / 26) % 26 + 1) .. "x Tester"
        hop.Relay:ReceiveFragment("chat-" .. i .. ":1:1:global|chat-" .. i .. "|" .. time() .. "|*|" .. who .. "|SH|" .. i,
            who, "CHANNEL")
    end
    drain()
    assert(hop.Relay:Receive("global|raid-1|" .. time() .. "|*|Origin Tester,Mate Tester|ZS|raid-zs:in_progress:Horde:20:x",
        "Mate Tester", "RAID"))
    drain()
    assert(onChannel == 0, "A raid copy from a mate heard on our channel went back to the channel")
end
-- Bridge election: routine traffic heard on the channel crosses through every hearer
-- while few bridges are known, through a hashed share of them beyond eight; the
-- origin's own copies and terminal events always cross.
do
    local hearer = client("Hearer Tester", "elect")
    hearer.PlayerFaction = "Horde"
    local enemy = client("Enemy Tester", "elect-enemy")
    enemy.faction, enemy.PlayerFaction = "Alliance", "Alliance"
    hearer.friends = { enemy }
    hearer.Relay:NoteBNetHeard(enemy)
    local crossed = 0
    local hearerSend = hearer.Sync.SendToBNet
    function hearer.Sync:SendToBNet(other, kind, wire)
        if other == enemy then crossed = crossed + 1 end
        return hearerSend(self, other, kind, wire)
    end
    local serialNo = 0
    local function heard(kind, payload)
        serialNo = serialNo + 1
        local wire = "global|elect-" .. serialNo .. "|" .. time() .. "|*|Origin Tester|" .. kind .. "|" .. payload
        assert(hearer.Relay:Receive(wire, "Origin Tester", "CHANNEL"), "Election fixture packet refused")
        drain()
    end
    for i = 1, 10 do heard("ZS", "arathi_" .. i .. ":in_progress:Horde:20:x") end
    assert(crossed == 10, "Few bridges: a routine packet did not cross through every hearer: " .. crossed)
    -- Own presence advertises the live bridge to the channel mates.
    assert(hearer.Relay:HasLiveEnemyBridge(), "A live enemy friend is not advertised")
    local mate = client("Mate Tester", "elect")
    assert(hearer.Relay:Send("NH", "1.0.0")); drain()
    now = now + 11
    assert(mate.Relay:GetCrossElection() == 1, "Own presence did not carry the bridge flag")
    local letters = "abcdefghijkl"
    local round = 0
    local function bridgesHeard(from, to)
        round = round + 1
        for i = from, to do
            local who = "Bridge" .. letters:sub(i, i) .. " Tester"
            local wire = "global|nh-" .. round .. "-" .. i .. "|" .. time() .. "|*|" .. who .. "|NH|1.0.0~b~ld~lr~lp6"
            hearer.Relay:Receive(wire, who, "CHANNEL")
        end
        drain()
        now = now + 11
    end
    -- Eight same-faction bridges: still everyone crosses. The same flag heard over
    -- Battle.net is the other faction's and is never counted.
    bridgesHeard(1, 8)
    hearer.Relay:Receive("global|nh-x|" .. time() .. "|*|Farside Tester|NH|1.0.0~b~ld~lr~lp6",
        "Farside Tester", "BNET", enemy)
    drain()
    now = now + 11
    assert(hearer.Relay:GetCrossElection() == 8, "Bridge count wrong (enemy presence counted?)")
    crossed = 0
    for i = 1, 10 do heard("ZS", "wetlands_" .. i .. ":in_progress:Horde:20:x") end
    assert(crossed == 10, "Eight bridges: a routine packet was already shared out: " .. crossed)
    bridgesHeard(9, 12)
    crossed = 0
    for i = 1, 60 do heard("ZS", "loch_" .. i .. ":in_progress:Horde:20:x") end
    assert(crossed > 5 and crossed < 40, "Many bridges: routine crossings not shared out: " .. crossed)
    assert((hearer.Relay.stats.crossElectionSkipped or 0) == 60 - crossed, "Skipped crossings not counted")
    bridgesHeard(1, 12)
    assert(hearer.Relay:GetCrossElection() == 12, "Bridge count fixture expired")
    crossed = 0
    for i = 1, 10 do heard("C", "ashen_" .. i .. ":Horde:x") end
    for i = 1, 10 do heard("ZS", "hills_" .. i .. ":captured:Horde:0:x") end
    assert(crossed == 20, "A terminal event was elected away: " .. crossed)
    crossed = 0
    for i = 1, 10 do assert(hearer.Relay:Send("ZS", "own_" .. i .. ":in_progress:Horde:20:x")); drain() end
    assert(crossed == 10, "Our own routine packets lost their Battle.net copies: " .. crossed)
end
a.RelayEnabled = false
assert(not a.Relay:Send("K", "disabled"), "Beta transport remained active after community re-enable")
print("Beta network: community-parallel relay, fragmentation, global routing, reply path, dedup, identity, expiry and queue bounds OK")
