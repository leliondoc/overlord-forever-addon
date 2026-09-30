-- Relay saturation, 2026-09-30 (queue 123-126/128): every player near an outpost
-- relayed the same routine outpost state, each capture tick queued another copy,
-- and stale items behind the lane heads held slots until their TTL. Now:
--  * an identical routine OP already relayed within a minute is not queued again;
--  * an unsent in-progress OP of the same origin and site is replaced in place;
--  * relayed shard presence (SH) never displaces anything;
--  * a full queue first frees unsent items that outlived their TTL.
local now = 100
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function() end }
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
Overlord = { Version = "1.2.4", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end,
        NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end }, Sync = {} }
local sync = Overlord.Sync
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return type(name) == "string" and name:match("^%a+ %a+$") and name or nil end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return { 1 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Reader Tester" end
function sync:SendToBNet() return true end
function sync:OnAddonMessage() end
function sync:SendSyncRequest() return true end
function sync:SendToChannel() return true end
local function load()
    assert(loadfile("SyncBetaNetwork.lua"))()
    local net = Overlord.BetaNetwork
    net.peers["reader tester"] = {
        at = now, via = "Reader Tester", name = "Reader Tester", transport = "BNET", bnet = 1, hops = 1,
    }
    return net
end
local net = load()
local serial = 0
local function receive(origin, kind, payload)
    serial = serial + 1
    local wire = table.concat({ "global", "op" .. serial, tostring(time()), "*",
        origin, kind, payload }, "|")
    return net:Receive(wire, origin, "BNET")
end
local HELD = "v2:ashenvale_outpost:held:Alliance:0"

-- 1. The same routine state heard from three players is relayed once per minute.
local before = net:GetQueueSummary().total
assert(receive("Ida Forever", "OP", HELD))
assert(receive("Bob Forever", "OP", HELD))
assert(receive("Cid Forever", "OP", HELD))
assert(net:GetQueueSummary().total == before + 1, "An identical routine outpost state was relayed twice")
assert(net.stats.routineForwardSkipped == 2)
now = now + 61
assert(receive("Ida Forever", "OP", HELD))
assert(net:GetQueueSummary().total == before + 2, "The routine state was not relayed again after a minute")

-- 2. Capture ticks from one player replace each other while unsent; another site
--    or another player keeps its own slot.
net = load()
before = net:GetQueueSummary().total
for tick = 1, 6 do
    assert(receive("Ida Forever", "OP", "v2:ashenvale_outpost:in_progress:Alliance:" .. tick * 5))
end
assert(net:GetQueueSummary().total == before + 1, "Capture ticks of one site piled up")
assert(net.stats.outpostCoalesced == 5)
assert(receive("Ida Forever", "OP", "v2:barrens_outpost:in_progress:Alliance:5"))
assert(receive("Bob Forever", "OP", "v2:ashenvale_outpost:in_progress:Alliance:5"))
assert(net:GetQueueSummary().total == before + 3, "Different sites or players were merged")

-- 3. A full queue: relayed SH is refused rather than displacing anything, while
--    stale items that outlived their TTL are freed for new traffic.
net = load()
local function forwarded(kind, i, payload)
    return net:Queue({ region = "global", id = kind .. i, at = GetServerTime and GetServerTime() or time(),
        target = "*", path = { "Origin" .. i .. " Tester", "Gateway Tester" }, kind = kind,
        payload = payload })
end
local admitted = 0
for i = 1, 200 do
    if forwarded("K", i, "live-" .. i) then admitted = admitted + 1 end
end
local full = net:GetQueueSummary().total
assert(admitted < 200, "Test setup: the queue never filled")
local displaced = net.stats.displaced or 0
assert(not forwarded("SH", 900, "shard"), "A relayed SH was admitted into a full queue")
assert((net.stats.displaced or 0) == displaced, "A relayed SH displaced queued traffic")
-- Even with presence holding most of the queue, a relayed SH takes no presence slot.
local shNet = net
net = load()
for i = 1, 80 do assert(forwarded("NH", 1000 + i, "1.2.4~lp6"), "Test setup: presence refused") end
for i = 1, 200 do forwarded("K", 2000 + i, "live-" .. i) end
local presenceSlots = net:GetQueueSummary().total
displaced = net.stats.displaced or 0
assert(not forwarded("SH", 902, "shard"), "A relayed SH took a presence slot")
assert((net.stats.displaced or 0) == displaced, "A relayed SH evicted a waiting presence")
assert(net:GetQueueSummary().total == presenceSlots)
net = shNet
now = now + 121
assert(forwarded("K", 901, "fresh"), "A full queue of expired items refused fresh traffic")
assert((net.stats.expired or 0) >= 1, "No expired item was freed")
assert(net:GetQueueSummary().total <= full, "Queue exceeded its bound")
print("Relay outpost coalescing: routine OP relayed once a minute, capture ticks merged, "
    .. "relayed SH never displaces, expired items freed on a full queue")
