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
-- The gateways' Battle.net friends run Overlord (heard): a copy relayed for someone
-- else rotates among such friends only.
for _, kind in ipairs(kinds) do
    b.Relay:NoteBNetHeard(c); b.Relay:NoteBNetHeard(us); c.Relay:NoteBNetHeard(b)
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
    -- b's Battle.net friends run Overlord (heard): relayed copies rotate among them.
    local function friendsHeard() b.Relay:NoteBNetHeard(c); b.Relay:NoteBNetHeard(us) end
    -- emitted at T (arrives 20 s late), T+45 (no forward), T+90 (arrives only 75 s after T's arrival)
    local w1 = table.concat({ "global", "delay-1", tostring(base - 20), "*", "Delay Origin", "SH", "beat" }, "|")
    friendsHeard()
    assert(b.Relay:Receive(w1, "Delay Origin", "CHANNEL")); drain()
    now = now + 45
    local w2 = table.concat({ "global", "delay-2", tostring(base + 25), "*", "Delay Origin", "SH", "beat" }, "|")
    friendsHeard()
    assert(b.Relay:Receive(w2, "Delay Origin", "CHANNEL")); drain()
    now = now + 30
    local w3 = table.concat({ "global", "delay-3", tostring(base + 70), "*", "Delay Origin", "SH", "beat" }, "|")
    friendsHeard()
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
    -- Like Sync:ChannelCarries, the channel takes the first own total only (30 s window).
    local channelTaken = false
    function killer.Sync:ChannelCarries(kind)
        if kind ~= "K" then return true end
        if channelTaken then return false end
        channelTaken = true
        return true
    end
    for i = 1, 20 do assert(killer.Relay:Send("K", "Killer Tester:front_a:" .. i .. ":WARRIOR")) end
    drain()
    local got = kills("Killer Tester:front_a:")
    assert(#got <= 2 and got[#got] == "Killer Tester:front_a:20:WARRIOR",
        "Waiting kill totals were not replaced by the newest: " .. #got)
    assert(got[1] == "Killer Tester:front_a:1:WARRIOR",
        "The total holding the channel copy was replaced: " .. tostring(got[1]))
    killer.Sync.ChannelCarries = nil
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
-- Packet ids stay short (base-36 session): every byte counts against the fragment size.
local probeId = gate.lastWire and gate.lastWire:match("^[^|]*|([^|]*)|")
assert(probeId and probeId:match("^%w+%-%d+$") and #probeId <= 16, "Packet id too long: " .. tostring(probeId))
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
-- Many opposite-faction friends not heard yet: one presence beat probes eight of
-- them, the next beat the others (no burst of copies).
do
    local wide = client("Wide Tester", "wide")
    wide.PlayerFaction = "Horde"
    local letters = "abcdefghijkl"
    local probedBy = {}
    for i = 1, 12 do
        local friend = client("Far" .. letters:sub(i, i) .. " Tester", "far " .. i)
        friend.faction, friend.PlayerFaction = "Alliance", "Alliance"
        wide.friends[#wide.friends + 1] = friend
    end
    local wideSend = wide.Sync.SendToBNet
    function wide.Sync:SendToBNet(other, kind, wire)
        if wire:find("|NH|", 1, true) then probedBy[other.name] = (probedBy[other.name] or 0) + 1 end
        return wideSend(self, other, kind, wire)
    end
    assert(wide.Relay:Send("NH", "beat-1")); drain()
    local first = 0
    for _ in pairs(probedBy) do first = first + 1 end
    assert(first == 8, "One presence beat did not probe exactly eight unheard friends: " .. first)
    now = now + 120
    assert(wide.Relay:Send("NH", "beat-2")); drain()
    local covered = 0
    for _ in pairs(probedBy) do covered = covered + 1 end
    assert(covered == 12, "Two beats did not reach every unheard friend: " .. covered)
end
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
    local hello = "global|map-hello|" .. time() .. "|*|Veteran Tester|NH|1.7.0~lr~lp6"
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
    -- Hundreds of other two-piece packets started meanwhile do not evict it either.
    local wire2 = "global|twopart-2|" .. time() .. "|*|Origin Tester|C|" .. string.rep("d", 260)
    assert(busy.Relay:ReceiveFragment("twopart-2:1:2:" .. wire2:sub(1, 170), "Origin Tester", "CHANNEL"))
    for i = 1, 500 do
        busy.Relay:ReceiveFragment("half-" .. i .. ":1:2:" .. string.rep("h", 170), "Noise Tester", "CHANNEL")
    end
    busy.Relay:ReceiveFragment("twopart-2:2:2:" .. wire2:sub(171), "Origin Tester", "CHANNEL")
    drain()
    got = false
    for _, row in ipairs(busy.received) do
        if row.kind == "C" and row.payload == string.rep("d", 260) then got = true end
    end
    assert(got, "A two-fragment capture was evicted by other packets still waiting for their pieces")
    -- Pieces up to 230 bytes (the size later versions will send) are read already;
    -- longer ones are still refused.
    local head = "global|wide-1|" .. time() .. "|*|Origin Tester|C|"
    local wide = head .. string.rep("w", 228 - #head)
    assert(#wide == 228)
    assert(busy.Relay:ReceiveFragment("wide-1:1:1:" .. wide, "Origin Tester", "CHANNEL"),
        "A 228-byte piece from a newer sender was refused")
    local tooWide = "global|wide-2|" .. time() .. "|*|Origin Tester|C|" .. string.rep("v", 200)
    assert(#tooWide > 230 and not busy.Relay:ReceiveFragment("wide-2:1:1:" .. tooWide, "Origin Tester", "CHANNEL"),
        "An oversized piece was accepted")
    -- A flooder cannot pin memory with huge assemblies: more pieces than a legal
    -- packet needs, or more bytes than a packet may hold, are refused.
    assert(not busy.Relay:ReceiveFragment("many-1:1:30:" .. string.rep("m", 170), "Noise Tester", "CHANNEL"),
        "A 30-piece packet was accepted")
    local held = 0
    for part = 1, 24 do
        if busy.Relay:ReceiveFragment("heavy-1:" .. part .. ":24:" .. string.rep("z", 220), "Noise Tester", "CHANNEL") then
            held = held + 1
        end
    end
    assert(held == 16, "An assembly grew past the packet size: " .. held .. " pieces of 220 bytes")
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
-- A terminal event relayed for someone else (an enemy capture from Battle.net) takes
-- a priority channel token; routine traffic and our own copies do not.
do
    local relayer = client("Relayer Tester", "crit-chan")
    local foe = client("Foe Tester", "crit-foe")
    foe.faction = "Alliance"
    local critical = {}
    local relayerChannel = relayer.Sync.SendToChannel
    function relayer.Sync:SendToChannel(kind, fragment, isCritical)
        local tag = fragment:match("|(%u%u?)|crit%-")
        if tag then critical[tag .. (fragment:find("own%-") and "own" or "")] = isCritical == true end
        return relayerChannel(self, kind, fragment, isCritical)
    end
    assert(relayer.Relay:Receive("global|crit-c|" .. time() .. "|*|Foe Tester|C|crit-zone:Alliance:x",
        "Foe Tester", "BNET", foe))
    assert(relayer.Relay:Receive("global|crit-zs|" .. time() .. "|*|Foe Tester|ZS|crit-zone:in_progress:Alliance:20:x",
        "Foe Tester", "BNET", foe))
    assert(relayer.Relay:Send("C", "crit-own-zone:Horde:x"))
    drain()
    assert(critical.C == true, "A relayed capture final waited for an ordinary channel token")
    assert(critical.ZS == false, "Relayed routine progress took a priority token")
    assert(critical.Cown == false, "Our own relay copy took a priority token")
    -- A burst of relayed terminals: one priority token per 1.25 s, the next ones wait
    -- their ordinary turn instead of being refused by Blizzard.
    critical = {}
    now = now + 5
    assert(relayer.Relay:Receive("global|crit-c2|" .. time() .. "|*|Foe Tester|C|crit-two:Alliance:x",
        "Foe Tester", "BNET", foe))
    assert(relayer.Relay:Receive("global|crit-c3|" .. time() .. "|*|Foe Tester|ZR|crit-three:w:Foe Tester",
        "Foe Tester", "BNET", foe))
    local priority = 0
    local relayerChannel2 = relayer.Sync.SendToChannel
    function relayer.Sync:SendToChannel(kind, fragment, isCritical)
        if fragment:find("crit%-t") and isCritical then priority = priority + 1 end
        return relayerChannel2(self, kind, fragment, isCritical)
    end
    drain()
    assert(priority == 1, "Relayed terminals in a burst all took a priority token: " .. priority)
end
-- Back from an instance, one presence beat comes soon (bridges find us again).
do
    local back = client("Back Tester", "back-chan")
    local beats = 0
    local backSend = back.Relay.Send
    back.Relay.Send = function(self, kind, ...)
        if kind == "NH" then beats = beats + 1 end
        return backSend(self, kind, ...)
    end
    back.Relay:Start()
    drain()
    beats = 0
    back.Relay:ScheduleReturnPresence()
    back.Relay:ScheduleReturnPresence()
    drain()
    assert(beats == 1, "Return from an instance did not send exactly one presence beat: " .. beats)
end
-- A neighbour's route and advertised ranking protocol survive a launch-sized channel:
-- a map reply (~30 s of pages) and the choice of the v8 exchange need them.
do
    local busy = client("Router Tester", "route-chan")
    busy.Relay:Receive("global|first-nh|" .. time() .. "|*|First Tester|NH|1.0.0~ld~lr~lp6",
        "First Tester", "CHANNEL")
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 1000 do
        local who = "Peer" .. letters:sub(i % 26 + 1, i % 26 + 1)
            .. letters:sub(math.floor(i / 26) % 26 + 1, math.floor(i / 26) % 26 + 1)
            .. letters:sub(math.floor(i / 676) + 1, math.floor(i / 676) + 1) .. " Tester"
        busy.Relay:Receive("global|peer-nh-" .. i .. "|" .. time() .. "|*|" .. who .. "|NH|1.0.0~ld~lr~lp6",
            who, "CHANNEL")
    end
    drain()
    assert(busy.Relay:IsDirectPeer("First Tester"), "A neighbour's route was forgotten on a busy channel")
    assert(busy.Relay:GetPeerPagedProtocol("First Tester") == 8,
        "A neighbour's v8 capability was forgotten on a busy channel")
    now = now + 6 -- the count is cached 5 s (read for every broadcast request)
    assert(busy.Relay:CountDirectPeers() >= 1000, "Direct neighbours undercounted")
    -- Catch-up partners come from a bounded sample read from a random place, so
    -- clients do not all ask the same neighbours.
    local first = busy.Relay:GetDirectPeers()
    local second = busy.Relay:GetDirectPeers()
    assert(#first <= 260 and #second <= 260, "Direct neighbour sample unbounded: " .. #first)
    local same = 0
    local inFirst = {}
    for _, name in ipairs(first) do inFirst[name] = true end
    for _, name in ipairs(second) do if inFirst[name] then same = same + 1 end end
    assert(same < #second, "Two samples of 1,000 neighbours were identical (no random start)")
    -- A Battle.net friend's route is always offered (the only way to an enemy peer).
    busy.friends = { { name = "First Tester", faction = "Horde" } }
    for _ = 1, 30 do
        local found = false
        for _, name in ipairs(busy.Relay:GetDirectPeers()) do
            if name == "First Tester" then found = true end
        end
        assert(found, "A Battle.net friend's route was left out of the neighbour sample")
    end
    busy.friends = {}
end
-- Map content (1.8.2): a neighbour's presence pulls our map when the two maps differ,
-- and the one that lacks a capture pulls. The newest capture alone (1.8.1) could not
-- see a capture missed on one front under a newer one held elsewhere. Clients that
-- say nothing about their content (1.8.1 and older) are pulled as before.
do
    local fresh = client("Fresh Tester", "fresh-chan")
    fresh.Fronts = { Registry = { arathi = { zones = {
        { id = "a1", owner = "Horde", status = "captured", capturedTime = 2000 },
        { id = "a2", owner = "Alliance", status = "in_progress", capturedTime = 9000 },
    } } } }
    local pulls = {}
    function fresh.Sync:SendSyncRequest(options)
        pulls[#pulls + 1] = options and options.betaTarget
        return true
    end
    local function presence(who, suffix, transport, friend)
        fresh.Relay:Receive("global|map-" .. who:gsub(" ", "") .. "|" .. time() .. "|*|" .. who
            .. "|NH|1.0.0" .. suffix .. "~ld~lr~lp6", who, transport or "CHANNEL", friend)
    end
    local function b36(n, width)
        local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
        repeat local r = n % 36; out = digits:sub(r + 1, r + 1) .. out; n = math.floor(n / 36) until n == 0
        return string.rep("0", (width or 0) - #out) .. out
    end
    -- What a map holds, written as the wire says it: "~z" + digest (6) + sum.
    local function content(...)
        local sum, digest = 0, 0
        for _, zone in ipairs({ ... }) do
            local text, hash = zone[1] .. zone[2] .. zone[3], 5381
            for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 2147483647 end
            sum, digest = sum + zone[3], (digest + hash) % 2147483647
        end
        return "~z" .. b36(digest, 6) .. b36(sum)
    end
    local function pulled(who, suffix, transport, friend)
        local before = #pulls
        presence(who, suffix, transport, friend)
        return #pulls == before + 1 and pulls[#pulls] == who
    end
    local ours = content({ "a1", "H", 2000 }) -- the siege in progress has no base: not counted
    assert(not pulled("Same Tester", "~m1jk~o0" .. ours), "A neighbour holding our map triggered a full map pull")
    assert((fresh.Relay.stats.mapPullsNoNews or 0) == 1, "Skipped pull not counted")
    -- The hole of 2026-10-10: the same newest capture (2000) and an older one we missed.
    local hole = "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "a0", "A", 1500 })
    assert(pulled("Hole Tester", hole), "A capture missed under a newer one was never pulled")
    assert(fresh.Relay.stats.mapPullsForDiff == 1, "Pull for a different map not counted")
    assert(pulled("Older Tester", ""), "An older neighbour lost its presence-triggered pull")
    -- Our map did not change (reply lost or refused): the same other map is asked
    -- again after 1 min, then 2, whoever advertises it.
    now = now + 61 -- (two pulls per minute at most)
    assert(pulled("Hole Second", hole), "A lost reply was never asked again")
    assert(not pulled("Hole Third", hole), "The same other map was pulled on every presence")
    now = now + 61
    assert(not pulled("Hole Fourth", hole), "The second retry did not wait two minutes")
    now = now + 61
    assert(pulled("Hole Fifth", hole), "The second retry never came")
    assert(fresh.Relay.stats.mapPullsForDiff == 3)
    -- Same dates, another owner (two captures in one second): both sides ask.
    assert(pulled("Tie Tester", "~m1jk~o0" .. content({ "a1", "A", 2000 })), "A tie between two maps was not pulled")
    -- The neighbour lacks one of ours (lower sum): its turn to pull, on our presence.
    now = now + 61
    local behind = "~m11s~o0" .. content({ "a1", "H", 1500 })
    local skipped = fresh.Relay.stats.mapPullsNoNews
    assert(not pulled("Behind Tester", behind), "A neighbour that lacks our capture was pulled at once")
    assert(fresh.Relay.stats.mapPullsNoNews == skipped + 1, "Skipped pull not counted")
    assert(not pulled("Empty Tester", "~m0~o0~z0000000"), "A neighbour with an empty map was pulled")
    -- It never caught up: after 5 min a few neighbours pull it anyway, then every 10 min.
    now = now + 301
    fresh.Relay.MAP_DIFF_ASKERS = 0
    assert(not pulled("Behind Unpicked", behind), "A neighbour outside the draw pulled a map that is behind")
    fresh.Relay.MAP_DIFF_ASKERS = 4
    assert(pulled("Behind Late", behind), "A map that never caught up was never pulled")
    now = now + 301
    assert(not pulled("Behind Again", behind), "A map that is behind was pulled twice within 10 min")
    now = now + 301
    assert(pulled("Behind Later", behind), "A map still behind after 10 min was not pulled again")
    -- A capture both sides learn does not restart the schedule of a difference no
    -- reply repaired: the difference is the same one (it used to be asked again at
    -- once after every capture anywhere on the map).
    do
        now = now + 61
        local stuck = { "a9", "A", 1200 } -- held by the neighbour, refused here whatever the reply
        local zones = fresh.Fronts.Registry.arathi.zones
        assert(pulled("Stuck First", "~m1jk~o0" .. content({ "a1", "H", 2000 }, stuck)), "fixture: first pull")
        now = now + 61
        assert(pulled("Stuck Second", "~m1jk~o0" .. content({ "a1", "H", 2000 }, stuck)), "fixture: retry after 1 min")
        -- A new capture reaches both sides: the two maps change, their difference does not.
        zones[3] = { id = "a3", owner = "Alliance", status = "captured", capturedTime = 2600 }
        now = now + 61
        assert(not pulled("Stuck Third", "~m208~o0" .. content({ "a1", "H", 2000 }, { "a3", "A", 2600 }, stuck)),
            "A capture both sides learnt restarted the retries of an unrepaired difference")
        now = now + 61
        assert(pulled("Stuck Fourth", "~m208~o0" .. content({ "a1", "H", 2000 }, { "a3", "A", 2600 }, stuck)),
            "The retry of an unrepaired difference never came")
        -- A capture only the neighbour holds is a new difference: asked at once.
        now = now + 61
        assert(pulled("Stuck News", "~m2bi~o0" .. content({ "a1", "H", 2000 }, { "a3", "A", 2600 }, stuck, { "a4", "H", 3000 })),
            "A new difference waited behind the schedule of an old one")
        zones[3] = nil
        now = now + 6
    end
    -- A Battle.net friend that stays behind is pulled by us after 5 min, draw or not:
    -- only its friends hear it.
    do
        now = now + 61
        local behindFriend = "~m11s~o0" .. content({ "a1", "H", 1400 })
        local friend = { name = "Behind Friend", faction = "Horde" }
        fresh.Relay.MAP_DIFF_ASKERS = 0
        assert(not pulled("Behind Friend", behindFriend, "BNET", friend), "A friend that is behind was pulled at once")
        now = now + 301
        assert(pulled("Behind Friend", behindFriend, "BNET", friend),
            "A Battle.net friend that never caught up was left to a draw among channel neighbours")
        fresh.Relay.MAP_DIFF_ASKERS = 4
    end
    -- A map of our own side received moments ago holds back a channel neighbour's
    -- pull, never the pull toward a friend of the other faction (and the reverse).
    do
        now = now + 61
        fresh.PlayerFaction = "Alliance"
        function fresh.Sync:GetBetaPeerFaction(who) return who:find("^Enemy ") and "Horde" or nil end
        local other = "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "h7", "H", 1700 })
        fresh.Sync._lastFullZaAt, fresh.Sync._lastEnemyFullZaAt = now - 10, nil
        assert(not pulled("Recent Chan", other), "A map received moments ago did not hold back a channel pull")
        assert(pulled("Enemy Friend", other, "BNET", { name = "Enemy Friend", faction = "Horde" }),
            "A map of our own side held back the pull toward a friend of the other faction")
        now = now + 61
        local another = "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "h8", "H", 1750 })
        fresh.Sync._lastFullZaAt, fresh.Sync._lastEnemyFullZaAt = nil, now - 10
        assert(not pulled("Enemy Second", another, "BNET", { name = "Enemy Second", faction = "Horde" }),
            "A map of the other faction received moments ago did not hold back the pull toward it")
        assert(pulled("Recent Other", another), "A map of the other faction held back a channel pull")
        fresh.Sync._lastFullZaAt, fresh.Sync._lastEnemyFullZaAt = nil, nil
        fresh.Sync.GetBetaPeerFaction, fresh.PlayerFaction = nil, nil
    end
    -- A 1.8.1 neighbour only says its newest capture. Newer than ours: pulled. Not
    -- newer: it cannot tell a hole, so it is pulled, but once per 150 s for its whole
    -- side, not on every presence (two full maps a minute during the whole rollout).
    do
        now = now + 61
        assert(pulled("Stamp Newer", "~m2bi"), "A 1.8.1 neighbour knowing a newer capture was not pulled")
        fresh.Sync._lastFullZaAt = now - 60
        assert(not pulled("Stamp Recent", "~m1jk"), "A 1.8.1 neighbour was pulled a minute after a map")
        fresh.Sync._lastFullZaAt = now - 151
        assert(pulled("Stamp Later", "~m1jk"), "A 1.8.1 neighbour was never pulled for a hole")
        now = now + 61
        fresh.Sync._lastFullZaAt = now - 60
        assert(pulled("Stamp News", "~m2bi"), "A newer capture of a 1.8.1 neighbour waited for the 150 s")
        fresh.Sync._lastFullZaAt = nil
        -- The reply to "Stamp Later" (122 s ago) never came: still one request per
        -- 150 s for that side, a lost or refused reply does not raise the pace.
        now = now + 61
        assert(not pulled("Stamp Lost", "~m1jk"), "A lost reply made a 1.8.1 neighbour be asked again before 150 s")
        now = now + 30
        assert(pulled("Stamp Again", "~m1jk"), "A 1.8.1 neighbour was not asked again 150 s after the last request")
    end
    -- 1.8.2: a client from before 1.7.0 (its own presence says less than v7) is
    -- never asked for its map; a 1.7.x neighbour still is.
    do
        now = now + 61
        local before = #pulls
        fresh.Relay:Receive("global|map-OldSix|" .. time() .. "|*|Old Six|NH|1.6.3~lp6", "Old Six", "CHANNEL")
        fresh.Relay:Receive("global|map-OldFive|" .. time() .. "|*|Old Five|NH|1.5.0", "Old Five", "CHANNEL")
        assert(#pulls == before, "A client from before 1.7.0 was asked for its map")
        assert(fresh.Relay:IsOutdatedMapPeer("Old Six") and fresh.Relay:IsOutdatedMapPeer("Old Five"),
            "A client from before 1.7.0 is not known as such")
        assert(fresh.Relay.stats.outdatedPresences == 2, "Presences of clients before 1.7.0 not counted")
        local report = fresh.Relay:GetKindDiagnostics()
        if type(report) == "table" then report = table.concat(report, " ") end
        assert(tostring(report):find("Clients before 1.7.0 (update required): 2 presences", 1, true),
            "The network report does not say that clients before 1.7.0 were heard")
        fresh.Relay:Receive("global|map-OldSeven|" .. time() .. "|*|Old Seven|NH|1.7.2~lr~lp6", "Old Seven", "CHANNEL")
        assert(#pulls == before + 1 and pulls[#pulls] == "Old Seven", "A 1.7.x neighbour lost its map pull")
        assert(not fresh.Relay:IsOutdatedMapPeer("Old Seven") and not fresh.Relay:IsOutdatedMapPeer("Never Heard"),
            "A 1.7.x or unknown neighbour counts as a client from before 1.7.0")
        -- Its presence relayed by someone else says nothing about it.
        fresh.Relay:Receive("global|map-FarOld|" .. time() .. "|*|Far Old,Old Seven|NH|1.6.3~lp6", "Old Seven", "CHANNEL")
        assert(not fresh.Relay:IsOutdatedMapPeer("Far Old"), "A relayed presence decided a neighbour's version")
    end
    -- The table of pairs is bounded: the pair seen longest ago gives way.
    for i = 1, 40 do
        fresh.Relay:MapDiffDue(1, 10, 1000 + i, 5, "Row Tester", now + i)
    end
    local rows = 0
    for _ in pairs(fresh.Relay.mapDiffs) do rows = rows + 1 end
    assert(rows == fresh.Relay.MAP_DIFF_ROWS, "Map pair table unbounded: " .. rows)
    now = now + 61
    -- A Battle.net friend is the way to the other faction's map: when the channel has
    -- used both pulls of the minute, its presence still has one of its own.
    local friendMap = "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "h1", "H", 1800 })
    assert(pulled("Chan First", "") and pulled("Chan Second", ""))
    assert(not pulled("Chan Third", ""), "More than two channel pulls in a minute")
    local friend = { name = "Friend Tester", faction = "Horde" }
    assert(pulled("Friend Tester", friendMap, "BNET", friend), "A friend's different map was not pulled on a busy channel")
    -- (another map again: the pair just asked would wait a minute anyway)
    assert(not pulled("Friend Other", "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "h2", "H", 1900 }), "BNET",
        { name = "Friend Other", faction = "Horde" }), "More than one extra pull a minute for Battle.net friends")
    now = now + 61
    assert(pulled("Chan Fourth", "") and pulled("Chan Fifth", ""))
    assert(pulled("Friend Third", "~m1jk~o0" .. content({ "a1", "H", 2000 }, { "h3", "H", 1950 }), "BNET",
        { name = "Friend Third", faction = "Horde" }), "The friends' own pull did not come back the next minute")
    now = now + 61
    fresh.Fronts.Registry.arathi.zones[1].owner = nil -- a fresh week: no capture known here either
    now = now + 6                      -- (own stamp cached 5 s)
    assert(not pulled("Week Tester", "~m0~o0~z0000000"), "Two empty maps were pulled")
    fresh.Fronts.Registry.arathi.zones[1].owner = "Horde"
    now = now + 6
    -- Our own presence advertises our newest confirmed capture (not the siege in
    -- progress) and what the map holds.
    local advertised
    local freshChannel = fresh.Sync.SendToChannel
    function fresh.Sync:SendToChannel(kind, fragment)
        if fragment:find("|NH|", 1, true) then advertised = fragment end
        return freshChannel(self, kind, fragment)
    end
    assert(fresh.Relay:Send("NH", "1.0.0")); drain()
    assert(advertised and advertised:find("~m1jk~o0" .. ours .. "~l9~ld~lr~lp6", 1, true), "Own presence lacks the map stamp")
    -- Clients of 1.8.1 read "~m...~" and nothing else of this.
    assert(("1.8.2~b~m1jk~o0" .. ours .. "~l9~ld~lr~lp6"):match("~m(%w+)~") == "1jk")
    -- The sum of sixty-four capture dates is beyond 32 bits, where tonumber(text, 36)
    -- stops on some builds: the stamp is read digit by digit.
    assert(fresh.Relay.ParseBase36(b36(114561024000)) == 114561024000, "A sum beyond 32 bits was misread")
    assert(fresh.Relay.ParseBase36("zik0zj") == 2147483647 and fresh.Relay.ParseBase36("0") == 0)
    assert(fresh.Relay.ParseBase36("") == nil and fresh.Relay.ParseBase36("1Z") == nil
        and fresh.Relay.ParseBase36("1-2") == nil, "A malformed stamp was read as a number")
    -- A truncated stamp says nothing: pulled as before the stamps.
    now = now + 61
    assert(pulled("Short Tester", "~m1jk~o0~z12345"), "A truncated content stamp was trusted")
    -- Keeps and outposts are part of the content: the same zones with a tenant we
    -- lack (older than our newest keep/outpost capture, which "~o" cannot see) are
    -- another map, and ours is advertised with our own tenants.
    do
        local siteSum, siteDigest = 0, 0
        function fresh.Sync:GetOutpostMapContent() return siteSum, siteDigest end
        now = now + 61
        assert(not pulled("Sites Equal", "~m1jk~o0" .. ours), "fixture: equal maps pulled")
        -- zones a1 (sum 2000) plus one tenant dated 1500 on their side
        local zoneDigest = fresh.Relay.ParseBase36(ours:sub(3, 8))
        local theirs = "~z" .. b36((zoneDigest + 777) % 2147483647, 6) .. b36(2000 + 1500)
        assert(pulled("Sites Hole", "~m1jk~o0" .. theirs), "A keep/outpost capture missed under a newer one was not pulled")
        -- Once our map holds that tenant too, the two maps are equal again.
        siteSum, siteDigest = 1500, 777
        now = now + 61
        assert(not pulled("Sites Held", "~m1jk~o0" .. theirs), "Our own tenants are not part of our content")
        advertised = nil
        assert(fresh.Relay:Send("NH", "1.0.0")); drain()
        assert(advertised and advertised:find("~m1jk~o0" .. theirs .. "~l9~ld~lr~lp6", 1, true),
            "Own presence does not advertise our keeps and outposts in the content")
        fresh.Sync.GetOutpostMapContent = nil
        now = now + 6
    end
    -- Keeps and outposts (1.8.2): their captures ride the same map reply and are
    -- believed from no other source we did not witness. The zone stamp alone skipped
    -- the pulls that brought them, so they have their own stamp ("~o").
    local served, known = 6000, 5000
    function fresh.Sync:GetOutpostMapStamps() return served, known end
    local zonesOnly = pulled
    -- From here every neighbour holds our zones: only the keeps and outposts speak.
    pulled = function(who, suffix)
        return zonesOnly(who, suffix:find("~o", 1, true) and (suffix .. ours) or suffix)
    end
    now = now + 61
    skipped = fresh.Relay.stats.mapPullsNoNews or 0
    assert(not pulled("Sites Same", "~m1jk~o3uw"), "A neighbour with no newer keep/outpost capture was pulled") -- 5000
    assert(fresh.Relay.stats.mapPullsNoNews == skipped + 1, "Skipped pull not counted")
    -- 1.8.1 advertises its zones only: it says nothing about its keeps and outposts.
    assert(pulled("Sites Legacy", "~m1jk"), "A neighbour silent about its keeps and outposts was not pulled")
    assert((fresh.Relay.stats.mapPullsForSites or 0) == 0)
    assert(pulled("Sites Newer", "~m1jk~o4mo"), "A newer keep/outpost capture triggered no pull")          -- 6000
    assert(fresh.Relay.stats.mapPullsForSites == 1, "Keep/outpost pull not counted")
    -- The reply could not make us accept it (capturer not ranked here): three pulls
    -- for that capture per half hour, whoever advertises it, then no more.
    now = now + 61
    assert(pulled("Sites Second", "~m1jk~o4mo") and pulled("Sites Third", "~m1jk~o4mo"))
    now = now + 61
    assert(not pulled("Sites Fourth", "~m1jk~o4mo"), "An unresolved keep/outpost capture was pulled on every presence")
    -- A newer capture is news again; the half hour over, the old one is tried again.
    assert(pulled("Sites Higher", "~m1jk~o5eg"), "A capture newer than the unresolved one was not pulled")  -- 7000
    assert(pulled("Sites Fifth", "~m1jk~o4mo"))
    now = now + 61
    assert(pulled("Sites Sixth", "~m1jk~o5eg"))
    assert(not pulled("Sites Seventh", "~m1jk~o5eg"), "The bound of pulls per capture was lost")
    now = now + 1801
    assert(pulled("Sites Late", "~m1jk~o5eg"), "An unresolved capture was never asked again")
    -- Once the map holds it, nothing is pulled; our own presence advertises what a
    -- reply of ours would state.
    known = 7000
    now = now + 61
    assert(not pulled("Sites Known", "~m1jk~o5eg"), "A capture our map holds was pulled")
    advertised = nil
    assert(fresh.Relay:Send("NH", "1.0.0")); drain()
    assert(advertised and advertised:find("~m1jk~o4mo" .. ours .. "~l9~ld~lr~lp6", 1, true),
        "Own presence lacks the keep/outpost stamp")
end
-- A forged relayed copy carrying a victim's next packet id (ids are predictable)
-- must not seal that id: the victim's genuine packet, with its own timestamp, still
-- gets through; a real duplicate (same id and timestamp) is still refused.
do
    local hearer = client("Sealed Tester", "seal-chan")
    local genuineAt = time()
    assert(hearer.Relay:Receive("global|victim-7|" .. (genuineAt - 40) .. "|*|Victim Tester,Cheater Tester|SH|forged",
        "Cheater Tester", "WHISPER"))
    local genuine = "global|victim-7|" .. genuineAt .. "|*|Victim Tester|C|zone:Alliance:real"
    assert(hearer.Relay:Receive(genuine, "Victim Tester", "CHANNEL"), "A pre-sealed id silenced the genuine packet")
    hearer.Relay:Receive(genuine, "Victim Tester", "CHANNEL") -- a true duplicate (at most a forward retry)
    drain()
    local got = 0
    for _, row in ipairs(hearer.received) do if row.payload == "zone:Alliance:real" then got = got + 1 end end
    assert(got == 1, "The genuine packet was not delivered exactly once: " .. got)
end
-- ... nor a forged copy stamped in the same second: the seal also covers the content,
-- which the forger cannot know before the victim sends it.
do
    local hearer = client("Samesec Tester", "seal-same")
    local at = time()
    assert(hearer.Relay:Receive("global|victim-9|" .. at .. "|*|Victim Tester,Cheater Tester|C|zone:Horde:forged",
        "Cheater Tester", "WHISPER"))
    local genuine = "global|victim-9|" .. at .. "|*|Victim Tester|C|zone:Alliance:real"
    assert(hearer.Relay:Receive(genuine, "Victim Tester", "CHANNEL"), "A same-second pre-seal silenced the genuine packet")
    hearer.Relay:Receive(genuine, "Victim Tester", "CHANNEL") -- a true duplicate (at most a forward retry)
    drain()
    local got = 0
    for _, row in ipairs(hearer.received) do if row.payload == "zone:Alliance:real" then got = got + 1 end end
    assert(got == 1, "The genuine packet was not delivered exactly once after a same-second forgery: " .. got)
end
-- A copy relayed for someone else rotates among Battle.net friends heard under
-- Overlord only (no copies to friends without the addon, on another ruleset or in an
-- instance); skipping them is not a loss. Our own packets keep the full rotation.
do
    local hearer = client("Rotate Tester", "rotate")
    hearer.PlayerFaction = "Alliance"
    local quietAlly = client("Quietally Tester", "rotate-qa")
    quietAlly.faction = "Alliance"
    local liveAlly = client("Liveally Tester", "rotate-la")
    liveAlly.faction = "Alliance"
    local quietEnemy = client("Quietenemy Tester", "rotate-qe")
    quietEnemy.faction, quietEnemy.PlayerFaction = "Horde", "Horde"
    hearer.friends = { quietAlly, liveAlly, quietEnemy }
    local got = {}
    local send = hearer.Sync.SendToBNet
    function hearer.Sync:SendToBNet(other, kind, wire)
        got[other] = (got[other] or 0) + 1
        return send(self, other, kind, wire)
    end
    hearer.Relay:NoteBNetHeard(liveAlly)
    assert(hearer.Relay:Receive("global|rot-1|" .. time() .. "|*|Rotate Origin|C|rot_zone:Alliance:x",
        "Rotate Origin", "CHANNEL"))
    drain()
    assert(not got[quietAlly] and not got[quietEnemy], "a relayed copy went to friends never heard under Overlord")
    assert(got[liveAlly], "a relayed copy did not reach the friend heard under Overlord")
    -- Only unheard friends left: no copy, and not counted as a loss.
    hearer.friends = { quietAlly, quietEnemy }
    got = {}
    local dropped = hearer.Relay.stats.dropped
    assert(hearer.Relay:Receive("global|rot-2|" .. time() .. "|*|Rotate Origin|C|rot_zone:Alliance:y",
        "Rotate Origin", "CHANNEL"))
    drain()
    assert(next(got) == nil and hearer.Relay.stats.dropped == dropped,
        "skipping friends never heard under Overlord was sent or counted as a loss")
    -- Our own packet still rotates among every friend.
    assert(hearer.Relay:Send("C", "own_zone:Alliance:z")); drain()
    assert(got[quietAlly] or got[quietEnemy], "our own packet lost its rotating Battle.net copies")
end
-- Battle.net liveness memory is bounded (64 accounts, every Battle.net sender): when
-- full of fresh senders, the one heard longest ago gives way, so a friend who just
-- spoke is always recorded as a live bridge.
do
    local busy = client("Busybnet Tester", "bnet-full")
    for i = 1, 64 do busy.Relay:NoteBNetHeard(1000 + i); now = now + 1 end
    busy.Relay:NoteBNetHeard(5000)
    assert(busy.Relay:IsBNetFriendAlive(5000), "A friend who just spoke was not recorded once 64 senders were live")
    assert(not busy.Relay:IsBNetFriendAlive(1001), "The sender heard longest ago did not give way")
    assert(busy.Relay:IsBNetFriendAlive(1064), "A recent sender was forgotten")
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
        hearer.Relay:NoteBNetHeard(enemy) -- a live bridge for the whole block
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
    for i = 1, 10 do heard("ZS", "wetlands_" .. i .. ":in_progress:Horde:90:x") end
    assert(crossed == 10, "Eight bridges: a routine packet was already shared out: " .. crossed)
    bridgesHeard(9, 12)
    crossed = 0
    for i = 1, 60 do heard("ZS", "loch_" .. i .. ":in_progress:Horde:90:x") end
    assert(crossed > 5 and crossed < 40, "Many bridges: routine crossings not shared out: " .. crossed)
    assert((hearer.Relay.stats.crossElectionSkipped or 0) == 60 - crossed, "Skipped crossings not counted")
    bridgesHeard(1, 12)
    assert(hearer.Relay:GetCrossElection() == 12, "Bridge count fixture expired")
    crossed = 0
    for i = 1, 10 do heard("C", "ashen_" .. i .. ":Horde:x") end
    for i = 1, 10 do heard("ZS", "hills_" .. i .. ":captured:Horde:0:x") end
    assert(crossed == 20, "A terminal event was elected away: " .. crossed)
    -- Siege starts (defenders' warning) and assaults given up are not elected either.
    crossed = 0
    for i = 1, 10 do heard("ZS", "start_" .. i .. ":in_progress:Horde:5:x") end
    for i = 1, 10 do heard("OP", "v2:site_" .. i .. ":neutral:x") end
    assert(crossed == 20, "A siege start or an abandoned assault was elected away: " .. crossed)
    -- Past the first ticks, siege progress is routine again (shared out).
    bridgesHeard(1, 12)
    assert(hearer.Relay:GetCrossElection() == 12, "Bridge count fixture expired")
    crossed = 0
    for i = 1, 30 do heard("ZS", "later_" .. i .. ":in_progress:Horde:20:x") end
    assert(crossed < 30, "Siege progress past its start was never elected away")
    -- A capture is only accepted from its author: relayed for someone else, it crosses
    -- toward the other side only, never back to the side that made it.
    crossed = 0
    heard("C", "back_c1:Capper Tester|WARRIOR:Alliance:" .. time() .. ":w1:g1:120")
    heard("ZS", "back_z1:in_progress:0:5:A:" .. time() .. ":0:120:Capper Tester")
    heard("ZS", "back_z2:captured:0:0:A:" .. time() .. ":0:120:Capper Tester")
    assert(crossed == 0, "An Alliance capture was sent back to the Alliance: " .. crossed)
    assert((hearer.Relay.stats.captureBackSkipped or 0) == 3, "Captures not sent back were not counted")
    heard("C", "fwd_c1:Capper Tester|WARRIOR:Horde:" .. time() .. ":w1:g1:120")
    heard("ZS", "fwd_z1:in_progress:0:5:H:" .. time() .. ":0:120:Capper Tester")
    assert(crossed == 2, "A Horde capture did not cross to the Alliance: " .. crossed)
    crossed = 0
    for i = 1, 10 do assert(hearer.Relay:Send("ZS", "own_" .. i .. ":in_progress:Horde:20:x")); drain() end
    assert(crossed == 10, "Our own routine packets lost their Battle.net copies: " .. crossed)
    -- Same share for the outbound live-score bridge (our faction's totals heard
    -- first-hand on the channel), per subject.
    bridgesHeard(1, 12)
    -- This hearer is a live bridge (its enemy friend heard again: rows go to live friends only).
    hearer.Relay:NoteBNetHeard(enemy)
    local queued = 0
    for i = 1, 40 do
        local who = "Owner" .. letters:sub((i - 1) % 12 + 1, (i - 1) % 12 + 1)
            .. letters:sub(math.floor((i - 1) / 12) + 1, math.floor((i - 1) / 12) + 1) .. " Tester"
        if hearer.Relay:NoteOwnerKill(who, "Horde", 50, 40, "WARRIOR", "enus", 1789527600, "B1789527600", "60") then
            queued = queued + 1
        end
    end
    drain()
    assert(queued > 3 and queued < 30, "Outbound score bridge not shared out with many bridges: " .. queued)
end
a.RelayEnabled = false
assert(not a.Relay:Send("K", "disabled"), "Beta transport remained active after community re-enable")
print("Beta network: community-parallel relay, fragmentation, global routing, reply path, dedup, identity, expiry and queue bounds OK")
