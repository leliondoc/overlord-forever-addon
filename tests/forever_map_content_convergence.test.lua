-- 1.8.2 map convergence under loss. Forty clients (two factions, two channels, two
-- Battle.net bridges) run the real relay. Captures reach only part of them live
-- (half of the capturer's faction, a tenth of the other one), as on a lossy bridge.
-- Each map pull is modelled as the reply it brings: a merge by capture date. Every
-- map must end identical, with a bounded number of pulls, and stay silent once equal.
-- Under the 1.8.1 rule (pull only for a capture newer than our newest) the same run
-- left most clients with holes for good.
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
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function() return {} end,
}
-- Own generator: the suite must not depend on the platform's math.random.
local seed = 20261010
local function draw()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end
local clients, byName = {}, {}
local function runUntil(stop)
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        if pending[1].at > stop then break end
        local item = table.remove(pending, 1)
        now = math.max(now, item.at)
        item.run()
    end
    now = stop
end
local FRONTS, ZONES = 4, 6
local pulls, replyLoss = 0, 0
local function merge(into, from)
    for f = 1, FRONTS do
        for z = 1, ZONES do
            local mine, theirs = into.Fronts.Registry["f" .. f].zones[z], from.Fronts.Registry["f" .. f].zones[z]
            local mineAt, theirsAt = mine.owner and mine.capturedTime or 0, theirs.owner and theirs.capturedTime or 0
            if theirsAt > mineAt or (theirsAt == mineAt and theirs.owner and theirs.owner ~= mine.owner
                and theirs.owner == "Alliance") then
                mine.owner, mine.capturedTime = theirs.owner, theirs.capturedTime
            end
        end
    end
end
local function client(name, channel, faction)
    local a = { Version = "1.8.2", CommunityModeEnabled = true, RelayEnabled = true, PlayerFaction = faction,
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, value) return value == "global" and "global" or "" end,
        }, Sync = {}, Fronts = { Registry = {} } }
    a.name, a.channel, a.faction, a.friends = name, channel, faction, {}
    for f = 1, FRONTS do
        local zones = {}
        for z = 1, ZONES do zones[z] = { id = "f" .. f .. "z" .. z, status = "captured" } end
        a.Fronts.Registry["f" .. f] = { zones = zones }
    end
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
    function s:GetPlayerFullName() return name end
    function s:GetChannelId() return 1 end
    function s:ExpectDirectFullLeaderboardResponse() end
    function s:SendToGroup() return false end
    function s:SendToChannel(_, fragment)
        for _, other in ipairs(clients) do
            if other ~= a and other.channel == channel then other.Relay:ReceiveFragment(fragment, name, "CHANNEL") end
        end
        return true
    end
    function s:GetBetaBNetTargets() return a.friends end
    function s:GetBetaBNetTargetInfo(other) return other.faction, other.name end
    function s:SendToBNet(other, kind, wire)
        if kind == "BR" then other.Relay:Receive(wire, name, "BNET", a)
        else other.Relay:ReceiveFragment(wire, name, "BNET", a) end
        return true
    end
    function s:SendWhisper() return true end
    function s:OnAddonMessage() end
    -- The map reply a targeted pull brings (a tenth of them are lost).
    function s:SendSyncRequest(options)
        local target = options and byName[options.betaTarget]
        if not target then return false end
        pulls = pulls + 1
        if draw() < replyLoss then return true end
        merge(a, target)
        return true
    end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    a.Relay.BridgeChannelHold = { 0, 0 }
    clients[#clients + 1] = a
    byName[name] = a
    return a
end
local letters = "abcdefghijklmnopqrstuvwxyz"
local function named(i, family)
    return "Peer" .. letters:sub(i % 26 + 1, i % 26 + 1) .. letters:sub(math.floor(i / 26) + 1, math.floor(i / 26) + 1)
        .. " " .. family
end
local PER_FACTION = 20
for i = 1, PER_FACTION do client(named(i, "Lion"), "alliance", "Alliance") end
for i = 1, PER_FACTION do client(named(i, "Wolf"), "horde", "Horde") end
-- Two Battle.net friendships across the factions.
for pair = 1, 2 do
    local ally, horde = clients[pair], clients[PER_FACTION + pair]
    ally.friends[#ally.friends + 1], horde.friends[#horde.friends + 1] = horde, ally
end
-- Every client says hello every 120 s, at its own offset.
local function presence(c)
    Overlord = c
    c.Relay:Send("NH", c.Version)
    C_Timer.After(120, function() presence(c) end)
end
for i, c in ipairs(clients) do C_Timer.After(1 + (i * 7) % 120, function() presence(c) end) end

local function fingerprint(c)
    local out = {}
    for f = 1, FRONTS do
        for z = 1, ZONES do
            local zone = c.Fronts.Registry["f" .. f].zones[z]
            out[#out + 1] = (zone.owner or "N"):sub(1, 1) .. (zone.owner and zone.capturedTime or 0)
        end
    end
    return table.concat(out, " ")
end
local function distinctMaps()
    local seen, count = {}, 0
    for _, c in ipairs(clients) do
        local key = fingerprint(c)
        if not seen[key] then seen[key] = true; count = count + 1 end
    end
    return count
end
-- A capture: its author always, then a lossy live delivery.
local function capture(owner)
    local zoneFront, zoneIndex = math.floor(draw() * FRONTS) + 1, math.floor(draw() * ZONES) + 1
    local at = time()
    for _, c in ipairs(clients) do
        local reach = c.faction == owner and 0.5 or 0.1
        if draw() < reach then
            local zone = c.Fronts.Registry["f" .. zoneFront].zones[zoneIndex]
            if not zone.owner or (zone.capturedTime or 0) < at then zone.owner, zone.capturedTime = owner, at end
        end
    end
end

-- Half an hour of fights: a capture every 45 s, one map reply in ten lost.
replyLoss = 0.1
local stop = now + 1800
local nextCapture = now + 30
while now < stop do
    runUntil(math.min(stop, nextCapture))
    if now >= nextCapture then
        capture(draw() < 0.5 and "Alliance" or "Horde")
        nextCapture = nextCapture + 45
    end
end
local duringFights = pulls
-- Then the fights stop. Every map must become the same one.
replyLoss = 0
runUntil(now + 900)
assert(distinctMaps() == 1, "Maps did not converge 15 min after the last capture: "
    .. distinctMaps() .. " different maps among " .. #clients .. " clients")
-- The final map holds the newest capture of every zone that was ever taken: nothing was lost.
local settled = pulls
assert(duringFights <= #clients * 2 * 30, "Pull budget exceeded during the fights: " .. duringFights)
-- Equal maps: no pull at all, however long the presence goes on.
runUntil(now + 1800)
assert(pulls == settled, "Equal maps still pulled each other: " .. (pulls - settled) .. " pulls in 30 min")
-- A late hole on one client only, older than everyone's newest capture: repaired.
local victim = clients[7]
local zone = victim.Fronts.Registry.f2.zones[3]
local reference = clients[1].Fronts.Registry.f2.zones[3]
assert(reference.owner, "fixture: the zone was never captured")
zone.owner, zone.capturedTime = reference.owner == "Alliance" and "Horde" or "Alliance", reference.capturedTime - 500
local before = pulls
runUntil(now + 300)
assert(distinctMaps() == 1, "A hole older than the newest capture was never repaired")
assert(pulls - before <= 3, "One hole on one client cost " .. (pulls - before) .. " pulls")
print(string.format("Forever map content: %d clients converged under loss (%d pulls in 30 min of fights, %d after), "
    .. "silent once equal, a late hole repaired in %d pull(s)", #clients, duringFights, settled - duringFights, pulls - before))
