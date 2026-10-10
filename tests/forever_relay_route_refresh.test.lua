-- A peer's route row is refreshed in place on every received packet (it used to be
-- a new table each time: tens of KB/s of garbage on a launch channel), with the same
-- values as before; a relayed copy still never replaces a fresh direct route.
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s = Overlord.Sync
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Horde"
function s:GetChannelId() return 5 end
function IsInInstance() return false end
function s:SendAddonChecked() return true end
local clock = 3000
function GetTime() return clock end
C_Timer = { After = function() end, NewTicker = function() return {} end }

local serial = 0
local function hear(origin, path, transport, bnetID)
    serial = serial + 1
    net:Receive("eu|r-" .. serial .. "|" .. time() .. "|*|" .. path .. "|NH|1.8.1~l9~ld~lr~lp6",
        path:match("([^,]+)$"), transport, bnetID)
end
hear("Route Tester", "Route Tester", "BNET", 7)
local row = net.peers["route tester"]
assert(row and row.hops == 1 and row.transport == "BNET" and row.bnet == 7, "the first route was not recorded")
clock = clock + 5
hear("Route Tester", "Route Tester", "CHANNEL")
assert(net.peers["route tester"] == row, "a refreshed route allocated a new table")
assert(row.at == clock and row.transport == "CHANNEL" and row.bnet == nil and row.via == "Route Tester"
    and row.hops == 1, "the refreshed route does not carry the new packet's values")
-- A relayed copy (2 hops) does not replace a fresh direct route.
clock = clock + 5
hear("Route Tester", "Route Tester,Middle Hop", "CHANNEL")
assert(row.hops == 1 and row.via == "Route Tester" and row.at == clock - 5,
    "a relayed copy replaced a fresh direct route")
-- After the direct route's 240 s, the relayed one takes over (same row).
clock = clock + 241
hear("Route Tester", "Route Tester,Middle Hop", "CHANNEL")
assert(net.peers["route tester"] == row and row.hops == 2 and row.via == "Middle Hop",
    "an expired direct route was not replaced by the relayed one")
print("Relay routes: refreshed in place with the same values; fresh direct routes kept")
