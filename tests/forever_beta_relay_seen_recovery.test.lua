-- A targeted packet is not consumed at an intermediate relay until a valid
-- forwarding task has actually entered its queue. Another authenticated path
-- may deliver the same origin:id after a capacity failure. Catch-up addressed to
-- someone else is never relayed at all since 1.2.4 (point to point).
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
        Version = "1.0.0", RelayEnabled = true,
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
                other.Relay:ReceiveFragment(fragment, name, "WHISPER")
                return true
            end
        end
        return false
    end
    function s:OnAddonMessage(_, message)
        a.received[#a.received + 1] = message
    end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    clients[#clients + 1] = a
    return a
end
local relay = client("Relay Tester")
local target = client("Target Tester")
local function route()
    relay.Relay.peers["target tester"] = {
        name = target.name, at = now, via = target.name,
        transport = "WHISPER", hops = 1,
    }
end
local function wire(id, via, payload, kind)
    return table.concat({ "global", id, tostring(time()), target.name,
        "Origin Tester," .. via, kind or "MS", payload }, "|")
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

route()
-- A full queue refuses a forwarded copy without sealing origin:id, so the same
-- packet can still arrive by another path once room is back.
local filled = 0
while relay.Relay:Send("MS", "local-fill-" .. filled, target.name) do filled = filled + 1 end
assert(filled > 0, "Test setup: the queue took no local packet")
local second = "guild-request-capacity"
assert(not relay.Relay:Receive(wire("capacity-one", "West Tester", second),
    "West Tester", "WHISPER"), "Full queue claimed a refused relay copy")
drain()
assert(relay.Relay:Receive(wire("capacity-one", "East Tester", second),
    "East Tester", "WHISPER"), "Capacity recovery was blocked by premature dedup")
drain()
local delivered = 0
for _, message in ipairs(target.received) do
    if message == "MS:" .. second then delivered = delivered + 1 end
end
assert(delivered == 1, "Retried origin:id did not reach the target exactly once")
assert((relay.Relay.stats.relayRejected or 0) >= 1,
    "Full queue did not count the refused forward admission")

-- Catch-up addressed to someone else is never relayed (point to point, 1.2.4).
local before = #target.received
assert(not relay.Relay:Receive(wire("catchup-one", "East Tester",
    "6:Q:1:far:1:1:-:0:0:LK", "HR"), "East Tester", "WHISPER"), "A far catch-up request was relayed")
drain()
assert(#target.received == before and (relay.Relay.stats.catchupNotRelayed or 0) == 1,
    "Relayed catch-up reached its target")
-- A broadcast map request is handled locally but never forwarded further.
local sentBefore = relay.Relay.stats.sent
local broadcastWire = table.concat({ "global", "sr-broadcast", tostring(time()), "*",
    "Origin Tester,East Tester", "SR", "H:1.2.4:0:::T" }, "|")
assert(relay.Relay:Receive(broadcastWire, "East Tester", "WHISPER"))
drain()
assert(relay.Relay.stats.sent == sentBefore, "A broadcast map request was relayed onward")
print("Beta targeted relay: capacity failure allows one valid alternate copy; catch-up never relayed")
