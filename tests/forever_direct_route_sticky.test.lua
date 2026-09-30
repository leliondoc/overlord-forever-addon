-- Live report 2026-09-30: the Horde total froze once catch-up became point to
-- point. A Battle.net friend is heard first-hand only every ~2 minutes while
-- relayed copies of its presence keep arriving; those copies replaced the direct
-- route after 60 s, so the friend looked "far" half of the time and every
-- ranking request to it was refused. A direct route now outlives relayed copies.
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
function sync:GetBetaBNetTargets() return {} end
function sync:OnAddonMessage() end
function sync:SendSyncRequest() return true end
function sync:SendToChannel() return true end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
local serial = 0
local function presence(path, sender, transport)
    serial = serial + 1
    local wire = table.concat({ "global", "nh" .. serial, tostring(time()), "*",
        path, "NH", "1.2.4~lp6" }, "|")
    return net:Receive(wire, sender, transport)
end

presence("Ida Forever", "Ida Forever", "BNET")
assert(net:IsDirectPeer("Ida Forever"), "A first-hand presence did not make a direct peer")
now = now + 90
presence("Ida Forever,Relay Tester", "Relay Tester", "CHANNEL")
assert(net:IsDirectPeer("Ida Forever"), "A relayed copy replaced a fresh direct route")
now = now + 60
presence("Ida Forever,Other Tester", "Other Tester", "CHANNEL")
assert(net:IsDirectPeer("Ida Forever"), "A relayed copy replaced a direct route after 150 s")
local direct = net:GetDirectPeers()
assert(#direct == 1 and direct[1] == "Ida Forever", "The direct peer left the catch-up candidates")
-- The next first-hand presence refreshes the direct route.
now = now + 30
presence("Ida Forever", "Ida Forever", "BNET")
-- Heard only through relays for more than four minutes: the relayed route wins.
now = now + 250
presence("Ida Forever,Relay Tester", "Relay Tester", "CHANNEL")
assert(net:IsPeer("Ida Forever") and not net:IsDirectPeer("Ida Forever"),
    "A long-lost direct route was kept forever")
print("Direct route sticky: first-hand route outlives relayed copies for 4 min, then yields")
