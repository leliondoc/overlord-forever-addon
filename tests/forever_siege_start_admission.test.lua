-- The first in_progress ZS of our own capture is admitted even when the urgent lane is full of
-- forwarded traffic (it displaces an unsent forwarded copy); a forwarded copy gets no such privilege.
local now, pending = 100, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function(delay, fn) pending[#pending + 1] = { at = now + delay, fn = fn } end }
Overlord = { Version = "1.1.10", PlayerFaction = "Horde", RealmPools = {
    GetOverlordPoolTag = function() return "global" end,
}, Sync = {} }
local sync = Overlord.Sync
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a == b end
function sync:GetPlayerFullName() return "Capper Tester" end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return {} end
function sync:GetBetaBNetTargetInfo() return nil end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
local function packet(id, path, payload)
    return { region = "global", id = id, at = time(), target = "*", path = path, kind = "ZS", payload = payload }
end
local admitted = 0
for i = 1, 100 do
    local origin = "Stub Origin" .. string.char(65 + i % 26) .. string.char(97 + math.floor(i / 26))
    if net:Queue(packet("fill-" .. i, { origin, "Capper Tester" },
        "stub" .. i .. ":in_progress:0:60:H:" .. time() .. ":0:120:" .. origin .. ":::")) then admitted = admitted + 1 end
end
assert(admitted < 100, "precondition: the urgent lane must be full (" .. admitted .. "/100 admitted)")
local forwarded = packet("fwd-1", { "Stub OriginZ", "Capper Tester" },
    "stubfwd:in_progress:0:0:H:" .. time() .. ":0:120:Stub OriginZ:::")
assert(net:Queue(forwarded) == false, "a forwarded ZS must not displace another forwarded copy")
local late = packet("own-late", { "Capper Tester" }, "zone:in_progress:0:90:H:" .. time() .. ":0:120:Capper Tester:::wave")
assert(net:Queue(late) == false, "a late progress ZS (hold > 45 s) must not get the privilege")
local own = packet("own-1", { "Capper Tester" }, "zone:in_progress:0:0:H:" .. time() .. ":0:120:Capper Tester:::wave-1")
assert(net:Queue(own) == true, "the capture-start ZS was refused by a full urgent lane")
print("Forever siege start admission: own capture start displaces a forwarded copy, others do not")
