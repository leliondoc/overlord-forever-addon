-- Addressed territorial requests and ZA pages must survive a relay saturated
-- with ordinary progress alerts. They are the repair path for missed C/ZS finals.
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
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function() return {} end,
}
local clients = {}
local function client(name)
    local a = {
        Version = "1.0.0", RelayEnabled = true, PlayerFaction = "Alliance",
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end,
        }, Sync = {}, name = name, received = {},
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
    function s:OnAddonMessage(_, message, channel, origin)
        a.received[#a.received + 1] = {
            message = message, channel = channel, origin = origin,
        }
    end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    clients[#clients + 1] = a
    return a
end
local gateway = client("Gateway Tester")
local receiver = client("Reader Tester")
gateway.Relay.peers["reader tester"] = {
    name = receiver.name, at = now, via = receiver.name,
    transport = "WHISPER", hops = 1,
}
for i = 1, 84 do
    assert(gateway.Relay:Send(
        "ZS", "zone" .. i .. ":in_progress:" .. string.rep("u", 120)))
end
local request = "A:1.0.0:0::T"
local page = "@G-1790016100-1:1:1|elwynn_blackrock_advance:A:1790016100:1790016100"
assert(gateway.Relay:Send("SR", request, receiver.name),
    "Addressed map request was refused behind progress ZS")
assert(gateway.Relay:Send("ZA", page, receiver.name),
    "Addressed map page was refused behind progress ZS")
assert(gateway.Relay:Send("C", "critical-final"),
    "A terminal displaced protected addressed map catch-up")
local ticks = 0
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 10000, "Relay did not settle")
    table.sort(pending, function(a, b) return a.at < b.at end)
    local nextItem = table.remove(pending, 1)
    now = nextItem.at
    nextItem.run()
end
local got = {}
for _, item in ipairs(receiver.received) do got[item.message] = true end
assert(got["SR:" .. request] and got["ZA:" .. page],
    "Accepted addressed map catch-up was not delivered")

-- No fresh route: targeted map packets retain ordinary-lane admission.
gateway.Relay.peers["reader tester"] = nil
for i = 1, 84 do
    assert(gateway.Relay:Send(
        "ZS", "zone" .. i .. ":in_progress:" .. string.rep("v", 120)))
end
assert(not gateway.Relay:Send("SR", request .. "2", receiver.name),
    "Unknown route borrowed catch-up reservation for an SR")
assert(not gateway.Relay:Send("ZA", page .. "2", receiver.name),
    "Unknown route borrowed catch-up reservation for a ZA")

while #pending > 0 do
    table.sort(pending, function(a, b) return a.at < b.at end)
    local nextItem = table.remove(pending, 1)
    now = nextItem.at
    nextItem.run()
end
gateway.Relay.peers["reader tester"] = {
    name = receiver.name, at = now, via = receiver.name,
    transport = "WHISPER", hops = 1,
}
for i = 1, 16 do
    assert(gateway.Relay:Send("ZA", page .. ":" .. i, receiver.name))
end
assert(not gateway.Relay:Send("ZA", page .. ":overflow", receiver.name),
    "One local map producer borrowed beyond the protected catch-up slots")
print("Beta map catch-up: addressed SR and ZA survive urgent progress backlog")
