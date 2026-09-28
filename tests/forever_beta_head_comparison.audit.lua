-- Deterministic relay-load comparison, run with OVERLORD_AUDIT_BETA_SOURCE
-- pointing either at HEAD's saved source or the current SyncBetaNetwork.lua.
-- This is a transport microbenchmark, not an in-game convergence assertion.
local options = ... or {}
local source = options.source or os.getenv("OVERLORD_AUDIT_BETA_SOURCE") or "SyncBetaNetwork.lua"
local duration = options.duration or tonumber(os.getenv("OVERLORD_AUDIT_DURATION")) or 180
local phased = options.phased
if phased == nil then phased = os.getenv("OVERLORD_AUDIT_NH_PHASED") == "1" end
local now, pending, seq = 100, {}, 0
local function after(delay, fn)
    seq = seq + 1
    pending[#pending + 1] = { at = now + delay, run = fn, seq = seq }
end
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
C_Timer = { After = after, NewTicker = function() return { Cancel = function() end } end }
local clients = {}
local function client(name, faction)
    local a = { Version = "1.0.0", BetaNetworkEnabled = true,
        PlayerFaction = faction, name = name, received = {}, friends = {},
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end,
        }, Sync = {} }
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
    function s:GetBetaBNetTargets() return a.friends end
    function s:GetBetaBNetTargetInfo(friend)
        return friend.PlayerFaction, friend.name
    end
    function s:SendToBNet(friend, kind, wire)
        if kind == "BR" then friend.BetaNetwork:Receive(wire, name, "BNET", a)
        else friend.BetaNetwork:ReceiveFragment(wire, name, "BNET", a) end
        return true
    end
    function s:SendWhisper(kind, fragment, target)
        for _, other in ipairs(clients) do
            if other.name == target then
                other.BetaNetwork:ReceiveFragment(fragment, name, "WHISPER")
                return true
            end
        end
        -- Synthetic NH origins have no client instance; account for the send.
        return true
    end
    function s:SendSyncRequest() return false end
    function s:OnAddonMessage(_, message)
        local kind, payload = strsplit(":", message, 2)
        if kind == "LK" or kind == "ZA" or kind == "DX" then
            a.received[kind] = a.received[kind] or {}
            a.received[kind][payload] = true
        end
    end
    Overlord = a
    assert(loadfile(source))()
    clients[#clients + 1] = a
    return a
end
local bridge = client("Bridge Tester", "Alliance")
local friends = {
    client("Friend One", "Horde"),
    client("Friend Two", "Horde"),
    client("Friend Three", "Horde"),
}
bridge.friends = friends
local destination = friends[1]
local function refreshDestination()
    bridge.BetaNetwork.peers[destination.name:lower()] = {
        name = destination.name, at = now, via = destination.name,
        transport = "BNET", bnet = destination, hops = 1,
    }
end
refreshDestination()
for t = 240, duration, 240 do
    after(t, refreshDestination)
end
local function letters(n)
    local a = string.char(65 + math.floor((n - 1) / 26))
    local b = string.char(65 + (n - 1) % 26)
    return a .. b
end
local nhOffered, lkOffered, lkAccepted, mapOffered, mapAccepted = 0, 0, 0, 0, 0
local dxOffered, dxAccepted = 0, 0
local function offerNh(i, round)
    local origin = "Origin" .. letters(i) .. " Tester"
    local wire = table.concat({ "global", "nh-" .. i .. "-" .. round,
        tostring(time()), "*", origin, "NH", "1.0.0" }, "|")
    nhOffered = nhOffered + 1
    bridge.BetaNetwork:Receive(wire, origin, "CHANNEL")
end
for t = 0, duration - 1, 45 do
    local round = math.floor(t / 45)
    if phased then
        for i = 1, 100 do
            local index = i
            after(t + (i - 1) * 0.45, function() offerNh(index, round) end)
        end
    else
        after(t, function()
            for i = 1, 100 do offerNh(i, round) end
        end)
    end
end
for t = 0, duration - 1 do
    after(t + 0.4, function()
        local payload = "row-" .. t .. ":" .. string.rep("l", 115)
        lkOffered = lkOffered + 1
        if bridge.BetaNetwork:Send("LK", payload, destination.name) then
            lkAccepted = lkAccepted + 1
        end
    end)
end
for t = 0, duration - 1, 60 do
    after(t + 0.7, function()
        local round = math.floor(t / 60)
        for front = 1, 14 do
            local payload = (round + 1) .. ":1:1790016000:front" .. front
                .. ":" .. (round + 1) .. ":source:global:0:0:11"
            dxOffered = dxOffered + 1
            if bridge.BetaNetwork:Send("DX", payload) then
                dxAccepted = dxAccepted + 1
            end
        end
    end)
end
local nextPage = 1
local function offerMap()
    if nextPage > 32 or now > 100 + duration then return end
    local payload = "@G-head-audit:" .. nextPage .. ":32|" .. string.rep("z", 170)
    mapOffered = mapOffered + 1
    if bridge.BetaNetwork:Send("ZA", payload, destination.name) then
        mapAccepted = mapAccepted + 1
        nextPage = nextPage + 1
    end
    if nextPage <= 32 then after(0.2, offerMap) end
end
after(30, offerMap)
local steps = 0
while #pending > 0 do
    steps = steps + 1
    assert(steps < 200000, "load simulation did not settle")
    table.sort(pending, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.seq < b.seq
    end)
    local event = table.remove(pending, 1)
    now = event.at
    event.run()
end
local function count(rows)
    local n = 0
    for _ in pairs(rows or {}) do n = n + 1 end
    return n
end
local stats, kinds = bridge.BetaNetwork.stats, bridge.BetaNetwork.kindStats
print(string.format("source=%s duration=%ds phased=%s NH offered=%d admitted=%d bytes=%d dropped=%d; LK offered=%d accepted=%d delivered=%d bytes=%d dropped=%d; ZA attempts=%d accepted=%d delivered=%d; DX offered=%d accepted=%d delivered=%d; total sent=%d dropped=%d localRejected=%s forwardRejected=%s evicted=%s expired=%s",
    source, duration, tostring(phased), nhOffered, (kinds.NH or {}).queued or 0,
    (kinds.NH or {}).bytes or 0, (kinds.NH or {}).dropped or 0,
    lkOffered, lkAccepted, count(destination.received.LK),
    (kinds.LK or {}).bytes or 0, (kinds.LK or {}).dropped or 0,
    mapOffered, mapAccepted, count(destination.received.ZA),
    dxOffered, dxAccepted, count(destination.received.DX),
    stats.sent, stats.dropped, tostring(stats.localRejected),
    tostring(stats.relayRejected), tostring(stats.displaced), tostring(stats.expired)))
return {
    offeredLK = lkOffered, deliveredLK = count(destination.received.LK),
    deliveredZA = count(destination.received.ZA), offeredDX = dxOffered,
    deliveredDX = count(destination.received.DX), stats = stats,
    kinds = kinds, friends = friends, elapsed = now - 100,
}
