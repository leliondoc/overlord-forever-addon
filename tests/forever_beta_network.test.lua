-- Four replicas: channel A -> BNet gateway -> other faction/shard channel.
-- There is no community membership or C_Club API in this fixture.
local now, pending, calls = 100, {}, 0
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
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
    local a = { Version = "1.0.0", CommunityModeEnabled = false,
        RealmPools = { GetOverlordPoolTag = function() return pool or "eu" end }, Sync = {}, received = {} }
    a.name, a.channel, a.friends = name, channel, {}
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
    function s:GetPlayerFullName() return name end
    function s:ExpectDirectFullLeaderboardResponse() end
    function s:SendSyncRequest() end
    function s:SendToGroup(kind, fragment)
        -- Deliberately duplicate every channel delivery to exercise dedup.
        return self:SendToChannel(kind, fragment)
    end
    function s:SendToChannel(kind, fragment)
        assert(#kind + #fragment + 1 <= 255, "Addon packet exceeded 255 bytes")
        for _, other in ipairs(clients) do
            if other ~= a and other.channel == channel then
                other.BetaNetwork:ReceiveFragment(fragment, name, "CHANNEL")
            end
        end
    end
    function s:GetBetaBNetTargets() return a.friends end
    function s:SendToBNet(other, kind, wire)
        assert(#wire < 4000)
        if kind == "BR" then
            a.lastWire = wire
            other.BetaNetwork:Receive(wire, name, "BNET", a)
        else
            assert(kind == "BF")
            other.BetaNetwork:ReceiveFragment(wire, name, "BNET", a)
        end
    end
    function s:SendWhisper(kind, data, target)
        assert(kind == "BF" and #data + 3 <= 255)
        for _, other in ipairs(clients) do
            if other.name == target then other.BetaNetwork:ReceiveFragment(data, name, "WHISPER") end
        end
    end
    function s:OnAddonMessage(_, message, transport, origin)
        assert(transport == "BETA")
        assert(a.BetaNetwork:IsDispatching(origin))
        local kind, payload = strsplit(":", message, 2)
        a.received[#a.received + 1] = { kind = kind, payload = payload, origin = origin }
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
local kinds = { "C", "ZS", "ZR", "ZA", "GK", "GC", "GA", "G7", "GH", "OP", "OC", "LO", "LOC", "OE",
    "K", "LK", "LR", "LC", "DX", "WB", "VB", "TV", "HR", "HB", "HC", "HA", "GI", "GR", "GY" }
for _, kind in ipairs(kinds) do
    assert(a.BetaNetwork:Send(kind, string.rep("x", 450)))
    drain()
    local received = d.received[#d.received]
    assert(received and received.kind == kind and received.origin == a.name
        and #received.payload == 450, "Community message lost through gateway: " .. kind)
end
assert(#d.received == #kinds, "Duplicate routes produced duplicate delivery")
assert(#us.received == 0, "EU data leaked to NA")
assert(#a.received == 0, "Original sender received its own forwarded event")
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
assert(accepted == 128 and a.BetaNetwork.stats.dropped >= 72, "Queue was not bounded")
drain()
a.CommunityModeEnabled = true
assert(not a.BetaNetwork:Send("K", "disabled"), "Beta transport remained active after community re-enable")
print("Beta network: every data family, fragmentation, 3-hop routing, reply path, dedup, NA/EU, identity, expiry and queue bounds OK")
