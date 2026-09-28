-- A relayed v4 LK backlog may borrow idle catch-up slots, but it must not
-- prevent a local v6 request, acknowledgement or four-page production window.
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
    After = function(delay, callback)
        pending[#pending + 1] = { at = now + delay, run = callback }
    end,
}
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
        a.received[#a.received + 1] = { message = message, at = now }
    end
    Overlord = a
    assert(loadfile("SyncBetaNetwork.lua"))()
    clients[#clients + 1] = a
    return a
end
local gateway = client("Gateway Tester")
local receiver = client("Reader Tester")
gateway.BetaNetwork.peers["reader tester"] = {
    name = receiver.name, at = now, via = receiver.name,
    transport = "WHISPER", hops = 1,
}
for i = 1, 98 do
    assert(gateway.BetaNetwork:Send("LK", "v4-row-" .. i .. ":"
        .. string.rep("l", 145), receiver.name))
end
local start = now
assert(gateway.BetaNetwork:CanSendLeaderboardPage(),
    "Borrowed legacy rows blocked the reserved paged stream")
local packets = {
    { "HR", "6:Q:1:nonce:1:1:-:0:0:LK" },
    { "HA", "6:P:1:nonce:1:1:0:0:-:1:LK" },
    { "HB", "6:D:1:nonce:1:1:2:LK:one" },
    { "HB", "6:D:1:nonce:1:2:2:LK:two" },
}
for _, packet in ipairs(packets) do
    assert(gateway.BetaNetwork:Send(packet[1], packet[2], receiver.name),
        "Legacy LK backlog refused a paged packet")
end
assert(not gateway.BetaNetwork:CanSendLeaderboardPage(),
    "Paged producer bypassed its four-slot backpressure")
assert(not gateway.BetaNetwork:Send("HB", "6:D:1:nonce:1:3:3:LK:overflow", receiver.name),
    "Paged packets exceeded their four-slot reservation")
assert(gateway.BetaNetwork:Queue({
    region = "global", id = "paged-terminal", at = time(),
    target = receiver.name, path = {gateway.name}, kind = "C",
    payload = "terminal-under-backlog",
}, false), "Terminal capture could not reclaim a borrowed legacy row")
local originalWhisper = gateway.Sync.SendWhisper
local refusedOnce = false
gateway.Sync.SendWhisper = function(self, kind, fragment, target)
    if not refusedOnce and fragment:find(":one", 1, true) then
        refusedOnce = true
        return false
    end
    return originalWhisper(self, kind, fragment, target)
end
local serial = 0
local function feedLegacy()
    if now - start >= 40 then return end
    serial = serial + 1
    gateway.BetaNetwork:Send("LK", "late-row-" .. serial .. ":"
        .. string.rep("l", 145), receiver.name)
    C_Timer.After(0.2, feedLegacy)
end
local function feedUrgent()
    if now - start >= 40 then return end
    gateway.BetaNetwork:Send("ZS", "active:in_progress:0:400:A:" .. time())
    C_Timer.After(0.2, feedUrgent)
end
C_Timer.After(0.2, feedLegacy)
C_Timer.After(0.2, feedUrgent)
local ticks = 0
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 30000, "Relay did not settle")
    table.sort(pending, function(a, b) return a.at < b.at end)
    local item = table.remove(pending, 1)
    now = item.at
    item.run()
end
local arrived = {}
for _, item in ipairs(receiver.received) do arrived[item.message] = item.at end
for _, packet in ipairs(packets) do
    local at = arrived[packet[1] .. ":" .. packet[2]]
    assert(at and at - start < 20,
        "Pooled v6 packet waited behind the legacy LK backlog: " .. packet[1])
end
assert(arrived["LK:v4-row-1:" .. string.rep("l", 145)],
    "Paged priority starved the protected legacy row")
assert(refusedOnce and gateway.BetaNetwork.stats.refused >= 1,
    "Fixture did not exercise a refused copy while all four paged slots were full")
assert(arrived["C:terminal-under-backlog"]
    and arrived["C:terminal-under-backlog"] - start < 2,
    "Terminal capture waited behind paged and legacy queues")
local legacyDelivered = 0
for i = 1, 98 do
    if arrived["LK:v4-row-" .. i .. ":" .. string.rep("l", 145)] then
        legacyDelivered = legacyDelivered + 1
    end
end

-- The old source may have 32 relayed map pages and a borrowed LK tail waiting
-- when an observer needs a fresh territorial map. A newer SR:T to the same
-- target supersedes its unsent predecessor; no accepted ZA page is displaced.
gateway.BetaNetwork.peers["reader tester"].at = now
local mapStart, protectedLegacy, pages = now, {}, {}
for i = 1, 16 do
    local row = "map-legacy-" .. i .. ":" .. string.rep("l", 145)
    protectedLegacy[#protectedLegacy + 1] = row
    assert(gateway.BetaNetwork:Send("LK", row, receiver.name))
end
for i = 1, 32 do
    local page = "@G-sr-priority:" .. i .. ":32|" .. string.rep("z", 170)
    pages[#pages + 1] = page
    assert(gateway.BetaNetwork:Queue({
        region = "global", id = "za-sr-priority-" .. i, at = time(),
        target = receiver.name, path = {"Origin Tester", gateway.name},
        kind = "ZA", payload = page,
    }, false))
end
for i = 1, 52 do
    assert(gateway.BetaNetwork:Send("LK", "borrowed-" .. i .. ":"
        .. string.rep("l", 145), receiver.name))
end
local oldRequest = "Alliance:1.0.0~1:0:::T"
local newRequest = "Alliance:1.0.0~2:0:::T"
assert(gateway.BetaNetwork:Send("SR", oldRequest, receiver.name),
    "Full legacy/map queue refused targeted SR")
assert(gateway.BetaNetwork:Send("SR", newRequest, receiver.name),
    "Repeated targeted SR was not coalesced")
assert(gateway.BetaNetwork:Queue({
    region = "global", id = "map-terminal", at = time(),
    target = receiver.name, path = {gateway.name}, kind = "C",
    payload = "terminal-with-map",
}, false), "Terminal capture could not displace borrowed legacy work")
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 70000, "Map control relay did not settle")
    table.sort(pending, function(a, b) return a.at < b.at end)
    local item = table.remove(pending, 1)
    now = item.at
    item.run()
end
local mapArrived = {}
for _, item in ipairs(receiver.received) do
    if item.at >= mapStart then mapArrived[item.message] = item.at end
end
assert(mapArrived["SR:" .. newRequest]
    and mapArrived["SR:" .. newRequest] - mapStart < 5,
    "Targeted SR waited behind the old ZA/LK batch")
assert(not mapArrived["SR:" .. oldRequest]
    and (gateway.BetaNetwork.stats.mapRequestsCoalesced or 0) >= 1,
    "An unsent repeated map request was not coalesced")
assert(mapArrived["C:terminal-with-map"]
    and mapArrived["C:terminal-with-map"] - mapStart < 2,
    "Terminal capture waited behind map and ranking work")
for _, row in ipairs(protectedLegacy) do
    assert(mapArrived["LK:" .. row], "Protected legacy row was displaced by SR")
end
for i, page in ipairs(pages) do
    assert(mapArrived["ZA:" .. page], "Accepted map page was lost to SR at " .. i)
end
print(string.format("Beta paged/legacy contention: v6 passed 98 LK rows; %d/98 initial LK delivered, %d transport expirations; targeted SR preceded 32 ZA pages",
    legacyDelivered, gateway.BetaNetwork.stats.expired or 0))
