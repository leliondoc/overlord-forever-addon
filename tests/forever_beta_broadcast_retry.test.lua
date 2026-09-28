-- A broadcast terminal (C, ZR, OC, TV, FR...) handled at a relay whose forward
-- was refused (full queue) used to be sealed as seen: an identical copy arriving
-- through another bridge was dropped, and downstream players missed the event.
-- The second copy must retry the forward only, never be handled locally twice.
local now = 100
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
C_Timer = { After = function() end, NewTicker = function() return {} end }
Overlord = {
    Version = "1.1.5", BetaNetworkEnabled = true, PlayerFaction = "Alliance",
    RealmPools = {
        GetOverlordPoolTag = function() return "global" end,
        NormalizeRegionPool = function(_, pool) return pool == "global" and pool or "" end,
    }, Sync = {},
}
local s = Overlord.Sync
function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
function s:GetPlayerFullName() return "Relay Hop" end
function s:GetChannelId() return 1 end
function s:SendToGroup() return false end
function s:SendToChannel() return true end
function s:GetBetaBNetTargets() return {} end
function s:SendWhisper() return false end
local delivered = 0
function s:OnAddonMessage(_, message) if message:sub(1, 2) == "C:" then delivered = delivered + 1 end end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork

local realQueue, failNext, attempts = net.Queue, false, 0
net.Queue = function(self, p, immediate)
    attempts = attempts + 1
    if failNext then failNext = false; return false end
    return realQueue(self, p, immediate)
end
local function wire(id, path, kind, payload)
    return table.concat({ "global", id, tostring(time()), "*", path, kind, payload }, "|")
end
local function queued(kind) return net.kindStats[kind] and net.kindStats[kind].queued or 0 end

-- First copy: handled locally, forward refused.
failNext = true
net:Receive(wire("origin-1", "Origin Player,First Bridge", "C", "zone:Alliance:1"), "First Bridge", "WHISPER")
assert(delivered == 1 and queued("C") == 0, "First copy was not handled or was forwarded")

-- Same origin:id through another bridge: forwarded, not handled a second time.
now = now + 5
net:Receive(wire("origin-1", "Origin Player,Second Bridge", "C", "zone:Alliance:1"), "Second Bridge", "WHISPER")
assert(delivered == 1, "Second copy was handled locally twice")
assert(queued("C") == 1, "Second copy did not retry the refused forward")

-- Once forwarded, further copies are plain duplicates.
local before = attempts
net:Receive(wire("origin-1", "Origin Player,Third Bridge", "C", "zone:Alliance:1"), "Third Bridge", "WHISPER")
assert(delivered == 1 and queued("C") == 1 and attempts == before, "A forwarded packet was retried again")

-- A packet whose forward succeeded the first time is never retried.
net:Receive(wire("origin-2", "Origin Player,First Bridge", "C", "zone:Alliance:2"), "First Bridge", "WHISPER")
local after = attempts
net:Receive(wire("origin-2", "Origin Player,Second Bridge", "C", "zone:Alliance:2"), "Second Bridge", "WHISPER")
assert(attempts == after and delivered == 2, "A successfully forwarded packet was processed again")

-- The retry window follows the packet lifetime (120 s).
failNext = true
net:Receive(wire("origin-3", "Origin Player,First Bridge", "C", "zone:Alliance:3"), "First Bridge", "WHISPER")
now = now + 121
local late = attempts
net:Receive(wire("origin-3", "Origin Player,Second Bridge", "C", "zone:Alliance:3"), "Second Bridge", "WHISPER")
assert(attempts == late and delivered == 3, "An expired refused forward was retried")
print("Beta broadcast retry: refused forward retried by a second copy, no double handling")
