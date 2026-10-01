-- Relay budget, 2026-10-01: guild identity (GI) heartbeats were ~27 % of relay
-- bytes although membership almost never changes. A hop now forwards an origin's
-- broadcast GI only when its payload changed or once per 3300 s of the author's
-- timestamp; it is still handled locally every time.
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
Overlord = { Version = "1.3.4", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end,
        NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end }, Sync = {} }
local sync = Overlord.Sync
local delivered = 0
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return type(name) == "string" and name:match("^%a+ %a+$") and name or nil end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return { 1 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Reader Tester" end
function sync:SendToBNet() return true end
function sync:OnAddonMessage(_, message) if message:find("GI", 1, true) then delivered = delivered + 1 end end
function sync:SendSyncRequest() return true end
function sync:SendToChannel() return true end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
net.peers["reader tester"] = {
    at = now, via = "Reader Tester", name = "Reader Tester", transport = "BNET", bnet = 1, hops = 1,
}
local serial = 0
local function receive(origin, payload, target)
    serial = serial + 1
    local wire = table.concat({ "global", "gi" .. serial, tostring(time()), target or "*",
        origin, "GI", payload }, "|")
    return net:Receive(wire, origin, "BNET")
end
local function queued() return net:GetQueueSummary().total end
local IDA = "Ida Forever:Some Guild:2840:1790000000"

-- 1. First heartbeat relayed, the next three (15 min apart) handled but not relayed.
local before = queued()
assert(receive("Ida Forever", IDA))
assert(queued() == before + 1, "The first guild identity was not relayed")
for beat = 1, 3 do
    now = now + 850
    assert(receive("Ida Forever", IDA))
end
assert(queued() == before + 1, "An unchanged guild identity was relayed again within the hour")
assert(net.stats.giForwardSkipped == 3)
assert(delivered >= 4, "A filtered guild identity was not handled locally")

-- 2. The 4th heartbeat (with jitter) passes the 3300 s window.
now = now + 850
assert(receive("Ida Forever", IDA))
assert(queued() == before + 2, "The hourly guild identity refresh was not relayed")

-- 3. A changed guild is relayed at once; another origin has its own window.
now = now + 60
assert(receive("Ida Forever", "Ida Forever:Other Guild:2840:1790009000"))
assert(queued() == before + 3, "A guild change was held back")
assert(receive("Bob Forever", "Bob Forever:Some Guild:2840:1790000000"))
assert(queued() == before + 4, "Another origin was filtered by Ida's window")
print("Relay guild identity: unchanged GI relayed once per hour, changes relayed at once, always handled locally")
