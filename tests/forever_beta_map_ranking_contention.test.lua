-- A known-target SR/ZA response enters even when sixteen ranking pages and
-- 84 progress updates fill the ordinary relay allotment. Neither accepted ranking nor map pages
-- may be displaced when later terminal traffic reorders the catch-up lane.
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
        Version = "1.0.0", BetaNetworkEnabled = true, PlayerFaction = "Alliance",
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
for i = 1, 84 do
    assert(gateway.BetaNetwork:Send(
        "ZS", "zone" .. i .. ":in_progress:" .. string.rep("u", 120)))
end
local rankings = {}
for i = 1, 16 do
    local row = "6:D:ranking:" .. i .. ":" .. string.rep("h", 145)
    rankings[#rankings + 1] = row
    assert(gateway.BetaNetwork:Send("LK", row, receiver.name))
end
local request = "A:1.0.0:0::T"
local page = "@G-1790016100-1:1:1|elwynn_blackrock_advance:A:1790016100:1790016100"
local progressDropped = gateway.BetaNetwork.kindStats.ZS.dropped
assert(not gateway.BetaNetwork:Send("ZA", string.rep("x", 3600), receiver.name),
    "Oversized map packet passed relay validation")
assert(gateway.BetaNetwork.kindStats.ZS.dropped == progressDropped,
    "Rejected oversized map packet evicted valid progress")
assert(gateway.BetaNetwork:Send("SR", request, receiver.name),
    "Full ranking and progress queue refused addressed SR")
assert(gateway.BetaNetwork:Send("ZA", page, receiver.name),
    "Full ranking and progress queue refused addressed ZA")
assert(gateway.BetaNetwork:Send("ZA", page .. ":second", receiver.name))
assert(not gateway.BetaNetwork:Send("ZA", page .. ":third", receiver.name),
    "Map producer exceeded two extra protected ZA slots")
-- Once map and ranking items have been reordered, subsequent terminal traffic
-- must not evict one of the sixteen ranking pages shifted beyond index 16.
local function nextTick()
    table.sort(pending, function(a, b) return a.at < b.at end)
    local nextItem = table.remove(pending, 1)
    now = nextItem.at
    nextItem.run()
end
for _ = 1, 30 do nextTick() end
assert(gateway.BetaNetwork:Send("C", "final-capture"))
local ticks = 0
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 10000, "Relay did not settle")
    nextTick()
end
local got, mapAt, firstRankingAt = {}, nil, nil
for _, item in ipairs(receiver.received) do
    got[item.message] = true
    if item.message == "ZA:" .. page then mapAt = item.at end
    if item.message:sub(1, 3) == "LK:" then
        firstRankingAt = math.min(firstRankingAt or item.at, item.at)
    end
end
assert(got["SR:" .. request] and mapAt,
    "Accepted addressed map response did not arrive")
assert(mapAt - 100 < 20, "Map response missed a bounded repair window")
assert(firstRankingAt and firstRankingAt - 100 < 20,
    "Ranking pages were starved by map response")
for _, row in ipairs(rankings) do
    assert(got["LK:" .. row], "Accepted ranking page was displaced or expired")
end

-- GW is informational. A full GW bulk lane yields to a final capture while
-- the sixteen protected ranking packets continue to completion.
gateway.BetaNetwork.peers["reader tester"].at = now
for i = 1, 84 do
    assert(gateway.BetaNetwork:Send("GW", "alert-" .. i .. ":" .. string.rep("g", 80)))
end
local secondRankings = {}
for i = 1, 16 do
    local row = "6:D:second:" .. i .. ":" .. string.rep("h", 145)
    secondRankings[#secondRankings + 1] = row
    assert(gateway.BetaNetwork:Send("LK", row, receiver.name))
end
assert(not gateway.BetaNetwork:IsUrgentPacket("GW", "alert"),
    "Informational GW packet entered the urgent lane")
assert(gateway.BetaNetwork:Send("C", "second-final"),
    "Final capture could not displace an unsent GW")
assert(gateway.BetaNetwork.kindStats.GW.dropped > 0,
    "Final capture did not reclaim a waiting GW")
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 20000, "Second relay drain did not settle")
    nextTick()
end
got = {}
for _, item in ipairs(receiver.received) do got[item.message] = true end
for _, row in ipairs(secondRankings) do
    assert(got["LK:" .. row], "Protected ranking page was lost to a GW/final collision")
end

-- The producer retries each page when the two extra map slots are full. All
-- 32 pages of one atomic ZA snapshot must arrive before its scaled SR deadline.
gateway.BetaNetwork.peers["reader tester"].at = now
for i = 1, 84 do
    assert(gateway.BetaNetwork:Send(
        "ZS", "next" .. i .. ":in_progress:" .. string.rep("u", 120)))
end
for i = 1, 16 do
    assert(gateway.BetaNetwork:Send(
        "LK", "6:D:third:" .. i .. ":" .. string.rep("h", 145), receiver.name))
end
local snapshotStart, nextPage, pages = now, 1, {}
for i = 1, 32 do
    pages[i] = "@G-1790016100-2:" .. i .. ":32|" .. string.rep("z", 175)
end
local function offerPage()
    if nextPage > #pages then return end
    if gateway.BetaNetwork:Send("ZA", pages[nextPage], receiver.name) then
        nextPage = nextPage + 1
    end
    if nextPage <= #pages then C_Timer.After(0.2, offerPage) end
end
offerPage()
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 30000, "Paged map response did not settle")
    nextTick()
end
assert(nextPage == 33, "SR source did not enqueue every ZA page")
local snapshotArrivals = {}
for _, item in ipairs(receiver.received) do
    for i, payload in ipairs(pages) do
        if item.message == "ZA:" .. payload then snapshotArrivals[i] = item.at end
    end
end
for i = 1, 32 do
    assert(snapshotArrivals[i], "Atomic ZA snapshot lost page " .. i)
    assert(snapshotArrivals[i] - snapshotStart < 20 + 32 * 2.5,
        "Atomic ZA snapshot exceeded scaled response deadline at page " .. i)
end

-- At the far end of a multihop bridge, long path names make each ZA page span
-- three fragments. Keep urgent progress flowing so the 300 B/s floor, rather
-- than idle spare bandwidth, sets the service bound.
gateway.BetaNetwork.peers["reader tester"].at = now
local longPath = {
    "Originplayer Verylongrealmname", "Relayplayer Verylongrealmname",
    "Secondrelay Verylongrealmname", gateway.name,
}
local function queueRelayed(kind, payload, id)
    return gateway.BetaNetwork:Queue({
        region = "global", id = id, at = time(), target = receiver.name,
        path = longPath, kind = kind, payload = payload,
    }, false)
end
for i = 1, 84 do
    assert(gateway.BetaNetwork:Send(
        "ZS", "long" .. i .. ":in_progress:" .. string.rep("u", 120)))
end
for i = 1, 16 do
    assert(queueRelayed("LK", "6:D:long:" .. i .. ":" .. string.rep("h", 145),
        "long-hb-" .. i))
end
local longStart, longNext, longPages = now, 1, {}
for i = 1, 32 do
    longPages[i] = "@G-1790016100-3:" .. i .. ":32|" .. string.rep("z", 175)
end
local function offerLongPage()
    if longNext > #longPages then return end
    if queueRelayed("ZA", longPages[longNext], "long-za-" .. longNext) then
        longNext = longNext + 1
    end
    if longNext <= #longPages then C_Timer.After(0.2, offerLongPage) end
end
local urgentSerial = 0
local function feedUrgent()
    if now - longStart >= 200 then return end
    urgentSerial = urgentSerial + 1
    gateway.BetaNetwork:Send("ZS", "flow" .. urgentSerial
        .. ":in_progress:" .. string.rep("u", 120))
    C_Timer.After(0.2, feedUrgent)
end
offerLongPage()
C_Timer.After(0.2, feedUrgent)
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 70000, "Long-path map response did not settle")
    nextTick()
end
assert(longNext == 33, "Relayed SR source did not enqueue every page")
local longArrivals = {}
local longRankings = {}
for _, item in ipairs(receiver.received) do
    for i, payload in ipairs(longPages) do
        if item.message == "ZA:" .. payload then longArrivals[i] = item.at end
    end
    for i = 1, 16 do
        if item.message == "LK:6:D:long:" .. i .. ":" .. string.rep("h", 145) then
            longRankings[i] = item.at
        end
    end
end
for i = 1, 32 do
    assert(longArrivals[i], "Multihop atomic ZA snapshot lost page " .. i)
    assert(longArrivals[i] - longStart < 20 + 32 * 6,
        "Multihop atomic ZA exceeded scaled source deadline at page " .. i)
end
for i = 1, 16 do
    assert(longRankings[i], "Long-path ranking page expired behind map batch " .. i)
end

-- DX carries one absolute score per front; the periodic producer can refresh
-- the same front while its first copy still waits behind saturated progress.
-- VB events remain distinct, and neither kind may displace accepted LK/ZA.
gateway.BetaNetwork.peers["reader tester"].at = now
local stateStart = now
for i = 1, 84 do
    assert(gateway.BetaNetwork:Send(
        "ZS", "state" .. i .. ":in_progress:" .. string.rep("u", 120)))
end
local stateRankings = {}
for i = 1, 16 do
    local row = "6:D:state:" .. i .. ":" .. string.rep("h", 145)
    stateRankings[#stateRankings + 1] = row
    assert(gateway.BetaNetwork:Send("LK", row, receiver.name))
end
local statePages = {}
for i = 1, 2 do
    local page = "@G-1790016100-state:" .. i .. ":2|" .. string.rep("z", 170)
    statePages[#statePages + 1] = page
    assert(gateway.BetaNetwork:Send("ZA", page, receiver.name))
end
for i = 1, 14 do
    local front = "front" .. i
    assert(gateway.BetaNetwork:Send("DX", "1:1:1790016000:" .. front
        .. ":1:source:global:0:0:11", receiver.name))
end
local oldDx = "1:1:1790016000:front1:1:source:global:0:0:11"
local newDx = "2:1:1790016000:front1:2:source:global:0:0:11"
assert(gateway.BetaNetwork:Send("DX", newDx, receiver.name))
local bonus = "1790016000:global:front1,A,1790016001,1790016001,20,1000"
assert(gateway.BetaNetwork:Send("VB", bonus, receiver.name))
local stateSerial = 0
local function feedStateUrgent()
    if now - stateStart >= 100 then return end
    stateSerial = stateSerial + 1
    gateway.BetaNetwork:Send("ZS", "stateflow" .. stateSerial
        .. ":in_progress:" .. string.rep("u", 120))
    C_Timer.After(0.2, feedStateUrgent)
end
C_Timer.After(0.2, feedStateUrgent)
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 110000, "State relay did not settle")
    nextTick()
end
local stateArrivals = {}
for _, item in ipairs(receiver.received) do
    if item.at >= stateStart then stateArrivals[item.message] = item.at end
end
assert(stateArrivals["DX:" .. newDx] and not stateArrivals["DX:" .. oldDx],
    "Waiting DX front was not coalesced to its newest sequence")
for i = 2, 14 do
    local payload = "1:1:1790016000:front" .. i .. ":1:source:global:0:0:11"
    assert(stateArrivals["DX:" .. payload], "Saturated relay lost front " .. i)
end
assert(stateArrivals["VB:" .. bonus], "Saturated relay lost a distinct VB event")
assert(stateArrivals["VB:" .. bonus] - stateStart < 120,
    "State service missed the relay packet lifetime")
for _, row in ipairs(stateRankings) do
    assert(stateArrivals["LK:" .. row], "State lane displaced an accepted ranking page")
end
for _, page in ipairs(statePages) do
    assert(stateArrivals["ZA:" .. page], "State lane displaced an accepted map page")
end
-- A transport refusal leaves the BF copy unsent. The bounded retry must
-- deliver it without creating a second replicated-state entry or bypassing
-- the shared byte budget.
gateway.BetaNetwork.peers["reader tester"].at = now
local originalWhisper = gateway.Sync.SendWhisper
local refusedOnce = false
gateway.Sync.SendWhisper = function(self, kind, data, target)
    if kind == "BF" and not refusedOnce and data:find("retryfront", 1, true) then
        refusedOnce = true
        return false
    end
    return originalWhisper(self, kind, data, target)
end
local retryDx = "5:3:1790016000:retryfront:3:source:global:0:0:11"
assert(gateway.BetaNetwork:Send("DX", retryDx, receiver.name))
local retrySiblings = {}
for i = 1, 23 do
    local row = "5:3:1790016000:retry" .. i .. ":3:source:global:0:0:11"
    retrySiblings[#retrySiblings + 1] = row
    assert(gateway.BetaNetwork:Send("DX", row, receiver.name))
end
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 120000, "Refused state copy never settled")
    nextTick()
end
gateway.Sync.SendWhisper = originalWhisper
local retryArrivals = {}
for _, item in ipairs(receiver.received) do retryArrivals[item.message] = true end
assert(refusedOnce and retryArrivals["DX:" .. retryDx],
    "A refused DX copy was not retried and delivered")
for _, row in ipairs(retrySiblings) do
    assert(retryArrivals["DX:" .. row], "Full state lane lost a distinct DX on retry")
end

-- Relayed ranking bursts can borrow beyond their protected sixteen slots.
-- Even 128 attempted LK rows must leave the global state reservation usable;
-- one terminal may reclaim an unprotected borrowed page, but not DX/VB or the
-- sixteen protected ranking pages.
gateway.BetaNetwork.peers["reader tester"].at = now
local reserveStart, reserveRankings, reserveState = now, {}, {}
local accepted = 0
for i = 1, 128 do
    local row = "6:D:reserve:" .. i .. ":" .. string.rep("h", 145)
    if gateway.BetaNetwork:Send("LK", row, receiver.name) then
        accepted = accepted + 1
        if i <= 16 then reserveRankings[#reserveRankings + 1] = row end
    end
end
assert(accepted == 100, "Ranking burst consumed the global DX/VB/paged reservation")
for i = 1, 14 do
    local row = "1:1:1790016000:reservefront" .. i .. ":1:source:global:0:0:11"
    reserveState[#reserveState + 1] = "DX:" .. row
    assert(gateway.BetaNetwork:Send("DX", row, receiver.name),
        "Full ranking burst refused a reserved DX")
end
for i = 1, 10 do
    local row = "1790016000:global:reserve" .. i .. ",A,1790016001,1790016001,20,1000"
    reserveState[#reserveState + 1] = "VB:" .. row
    assert(gateway.BetaNetwork:Send("VB", row, receiver.name),
        "Full ranking burst refused a reserved VB")
end
assert(not gateway.BetaNetwork:Send("VB",
    "1790016000:global:overflow,A,1790016001,1790016001,20,1000", receiver.name),
    "State lane exceeded its twenty-four-slot bound")
assert(gateway.BetaNetwork:Queue({
    region = "global", id = "reserved-capture", at = time(),
    target = receiver.name, path = {gateway.name}, kind = "C",
    payload = "reserved-terminal",
}, false),
    "Full ranking/state queue refused a terminal capture")
while #pending > 0 do
    ticks = ticks + 1
    assert(ticks < 180000, "Reserved state relay did not settle")
    nextTick()
end
local reserveArrivals, terminalAt = {}, nil
for _, item in ipairs(receiver.received) do
    if item.at >= reserveStart then reserveArrivals[item.message] = true end
    if item.message == "C:reserved-terminal" then terminalAt = item.at end
end
assert(terminalAt and terminalAt - reserveStart < 2,
    "Terminal capture waited behind saturated ranking/state traffic: "
        .. tostring(terminalAt and terminalAt - reserveStart))
for _, row in ipairs(reserveRankings) do
    assert(reserveArrivals["LK:" .. row], "Protected ranking page was displaced")
end
for _, row in ipairs(reserveState) do
    assert(reserveArrivals[row], "Reserved state packet was displaced or expired: " .. row)
end
print(string.format(
    "Beta map/ranking contention: 32-page multihop ZA %.1fs, final LK %.1fs; state VB %.1fs; global reservations and priorities OK",
    longArrivals[32] - longStart, longRankings[16] - longStart,
    stateArrivals["VB:" .. bonus] - stateStart))
