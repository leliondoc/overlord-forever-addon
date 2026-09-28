-- A targeted packet is not consumed at an intermediate relay until a valid
-- forwarding task has actually entered its queue. Another authenticated path
-- may deliver the same origin:id after a route or capacity failure.
local now, pending = 100, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1)
        start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Timer = { After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end }
local clients = {}
local function client(name)
    local a = {
        Version = "1.0.0", BetaNetworkEnabled = true,
        PlayerFaction = "Alliance", name = name, received = {},
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end,
        }, Sync = {},
    }
    local s = a.Sync
    function s:CanonicalForeverName(n)
        return type(n) == "string" and n:match("^%a+ %a+$") and n or nil
    end
    function s:ForeverIdentitiesMatch(x, y)
        return type(x) == "string" and type(y) == "string" and x:lower() == y:lower()
    end
    function s:GetPlayerFullName() return name end
    function s:GetChannelId() return 1 end
    function s:SendToGroup() return false end
    function s:SendToChannel() return true end
    function s:GetBetaBNetTargets() return {} end
    function s:SendWhisper(kind, fragment, target)
        assert(kind == "BF")
        for _, other in ipairs(clients) do
            if other.name == target then
                other.BetaNetwork:ReceiveFragment(fragment, name, "WHISPER")
                return true
            end
        end
        return false
    end
    function s:OnAddonMessage(_, message)
        a.received[#a.received + 1] = message
    end
    Overlord = a
    assert(loadfile("SyncBetaNetwork.lua"))()
    clients[#clients + 1] = a
    return a
end
local relay = client("Relay Tester")
local target = client("Target Tester")
local function route()
    relay.BetaNetwork.peers["target tester"] = {
        name = target.name, at = now, via = target.name,
        transport = "WHISPER", hops = 1,
    }
end
local function wire(id, via, payload)
    return table.concat({ "global", id, tostring(time()), target.name,
        "Origin Tester," .. via, "HR", payload }, "|")
end
local function drain()
    local ticks = 0
    while #pending > 0 do
        ticks = ticks + 1
        assert(ticks < 30000, "Relay did not settle")
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = item.at
        item.run()
    end
end

local payload = "6:Q:1:nonce:1:1:-:0:0:LK"
assert(not relay.BetaNetwork:Receive(wire("route-one", "West Tester", payload),
    "West Tester", "WHISPER"), "Missing-route copy was reported forwarded")
route()
assert(relay.BetaNetwork:Receive(wire("route-one", "East Tester", payload),
    "East Tester", "WHISPER"), "A valid alternate route was deduplicated")
drain()
local first = 0
for _, message in ipairs(target.received) do
    if message == "HR:" .. payload then first = first + 1 end
end
assert(first == 1, "Alternate route did not deliver exactly once")
assert((relay.BetaNetwork.stats.forwardNoTaskMissing or 0) == 1,
    "Missing route did not expose its forwarding failure")
assert(not relay.BetaNetwork:Receive(wire("route-one", "East Tester", payload),
    "East Tester", "WHISPER"), "An accepted alternate copy was not deduplicated")

relay.BetaNetwork.peers["target tester"].via = "West Tester"
local loopPayload = "6:Q:1:loop:1:1:-:0:0:LK"
assert(not relay.BetaNetwork:Receive(wire("loop-one", "West Tester", loopPayload),
    "West Tester", "WHISPER"), "Looped next hop was reported forwarded")
route()
assert(relay.BetaNetwork:Receive(wire("loop-one", "East Tester", loopPayload),
    "East Tester", "WHISPER"), "A loop rejection sealed origin:id")
drain()
assert((relay.BetaNetwork.stats.forwardNoTaskLoop or 0) == 1,
    "Looped route did not expose its forwarding failure")

for i = 1, 4 do
    assert(relay.BetaNetwork:Send("HB", "6:D:1:local:1:" .. i .. ":4:LK:full", target.name))
end
local second = "6:Q:1:fullqueue:2:1:-:0:0:LK"
assert(not relay.BetaNetwork:Receive(wire("capacity-one", "West Tester", second),
    "West Tester", "WHISPER"), "Full paged lane claimed a refused relay copy")
drain()
assert(relay.BetaNetwork:Receive(wire("capacity-one", "East Tester", second),
    "East Tester", "WHISPER"), "Capacity recovery was blocked by premature dedup")
drain()
local delivered = 0
for _, message in ipairs(target.received) do
    if message == "HR:" .. second then delivered = delivered + 1 end
end
assert(delivered == 1, "Retried origin:id did not reach the target exactly once")
assert((relay.BetaNetwork.stats.relayRejected or 0) >= 1,
    "Full paged lane did not count the refused forward admission")
print("Beta targeted relay: route and capacity failures allow one valid alternate copy")
