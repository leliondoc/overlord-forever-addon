-- A full addressed v5 page must reassemble while urgent traffic consumes the
-- shared relay budget. The catch-up lane guarantees 300 B/s, so 22 fragments
-- legitimately take longer than 15 seconds from first to last fragment.
local now, timers = 100, {}
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
    After = function(delay, callback) timers[#timers + 1] = { at = now + delay, run = callback } end,
    NewTicker = function() return {} end,
}
local clients = {}
local function client(name)
    local a = {
        Version = "1.0.0", BetaNetworkEnabled = true, PlayerFaction = "Alliance",
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end,
        },
        Sync = {}, received = {},
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
    function s:OnAddonMessage(_, message, channel, origin)
        a.received[#a.received + 1] = {
            message = message, channel = channel, origin = origin, at = now,
        }
    end
    a.name = name
    Overlord = a
    assert(loadfile("SyncBetaNetwork.lua"))()
    clients[#clients + 1] = a
    return a
end
local sender = client("Alice Tester")
local receiver = client("Bob Tester")
sender.BetaNetwork.peers["bob tester"] = {
    name = receiver.name, at = now, via = receiver.name,
    transport = "WHISPER", hops = 1,
}

-- Keep urgent work continuously available for the first 20+ seconds.
for i = 1, 82 do
    assert(sender.BetaNetwork:Send("ZS", string.rep("u", 130) .. i))
end
local page = "5:" .. string.rep("x", 3480)
assert(sender.BetaNetwork:Send("HB", page, receiver.name))

local firstFragmentAt, lastFragmentAt
local originalReceive = receiver.BetaNetwork.ReceiveFragment
receiver.BetaNetwork.ReceiveFragment = function(self, fragment, ...)
    local _, part, count = strsplit(":", fragment, 4)
    if tonumber(count) and tonumber(count) > 1 then
        if tonumber(part) == 1 then firstFragmentAt = now end
        if tonumber(part) == tonumber(count) then lastFragmentAt = now end
    end
    return originalReceive(self, fragment, ...)
end

local ticks = 0
while #timers > 0 do
    ticks = ticks + 1
    assert(ticks < 10000, "Transport failed to settle")
    table.sort(timers, function(a, b) return a.at < b.at end)
    local timer = table.remove(timers, 1)
    now = timer.at
    timer.run()
end
assert(firstFragmentAt and lastFragmentAt and lastFragmentAt - firstFragmentAt > 15,
    "Fixture did not cover assembly lifetime under urgent saturation")
local delivered = false
for _, item in ipairs(receiver.received) do
    if item.message == "HB:" .. page then delivered = true end
end
assert(delivered, "Accepted full catch-up page expired before its final fragment")

-- Repeating one fragment must not pin an incomplete assembly indefinitely.
-- Only a new fragment refreshes its idle clock; packet syntax/TTL still apply.
local id = "late-1"
local wire = table.concat({ "global", id, tostring(time()), receiver.name,
    "Carol Tester", "HB", "5:" .. string.rep("q", 180) }, "|")
assert(#wire > 170 and #wire <= 340)
local first = id .. ":1:2:" .. wire:sub(1, 170)
local second = id .. ":2:2:" .. wire:sub(171)
local before = #receiver.received
assert(receiver.BetaNetwork:ReceiveFragment(first, "Carol Tester", "WHISPER"))
now = now + 20
assert(receiver.BetaNetwork:ReceiveFragment(first, "Carol Tester", "WHISPER"))
now = now + 11
assert(receiver.BetaNetwork:ReceiveFragment(second, "Carol Tester", "WHISPER"))
assert(#receiver.received == before, "Duplicate fragment extended a stalled assembly")
assert(receiver.BetaNetwork:ReceiveFragment(first, "Carol Tester", "WHISPER"))
assert(#receiver.received == before + 1, "Fresh fragments did not reassemble after idle expiry")
assert(not receiver.BetaNetwork:ReceiveFragment(
    "bad:1:65:x", "Carol Tester", "WHISPER"), "Invalid fragment count accepted")
print("Beta full-page catch-up survived urgent saturation and fragment spacing")
