-- Map layout (2.0.3, Hillsbrad on 10 points). Two clients whose fronts hold different
-- point ids refuse each other's whole maps (Sync:OnReceiveZoneAll wants the same zone
-- set): on the bench, 2.0.2 next to 2.0.3 cost 3.8 times the whispers for the same maps.
-- A presence says the layout ("~y<layout>"); a neighbour with another layout, or none,
-- is outside the map exchange both ways. The layout does not depend on the walk order.
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

local function registry(ids)
    local zones = {}
    for i, id in ipairs(ids) do zones[i] = { id = id } end
    return { Registry = { one = { zones = zones } } }
end
local TEN = { "hillsbrad_southshore", "hillsbrad_western_strand", "hillsbrad_fields", "hillsbrad_internment_camp",
    "hillsbrad_bridge", "hillsbrad_nethander", "hillsbrad_dun_garok", "hillsbrad_thoradin_gate",
    "hillsbrad_durnholde", "hillsbrad_tarren_mill" }
local TWO = { "hillsbrad_southshore", "hillsbrad_tarren_mill" }

local asked = {}
local function client(name, ids)
    local a = { Version = "2.0.3", RelayEnabled = true, PlayerFaction = "Alliance", Fronts = registry(ids),
        RealmPools = { GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, p) return p == "global" and p or "" end }, Sync = {} }
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
    function s:GetPlayerFullName() return name end
    function s:GetChannelId() return 1 end
    function s:SendToGroup() return false end
    function s:SendToChannel() return true end
    function s:GetBetaBNetTargets() return {} end
    function s:SendWhisper() return true end
    function s:OnAddonMessage() end
    function s:SendSyncRequest(opts) asked[#asked + 1] = opts and opts.betaTarget; return true end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    return a
end

local me = client("Local Tester", TEN)
local net = me.Relay
local layout = net.LocalMapLayout()
assert(type(layout) == "string" and #layout == 4 and layout ~= "0000", "no layout: " .. tostring(layout))
-- Order-free and id-driven: the same ids in another order, the same layout; other ids, another.
local reversed = {}
for i = #TEN, 1, -1 do reversed[#reversed + 1] = TEN[i] end
assert(client("Order Tester", reversed).Relay.LocalMapLayout() == layout, "the layout depends on the walk order")
local older = client("Older Tester", TWO).Relay.LocalMapLayout()
assert(older ~= layout, "the 2-point Hillsbrad has the same layout as the 10-point one")
Overlord = me

-- Our presence says it, after "~t0" whose readers look for "~t0~".
local queued
local realQueue = net.Queue
net.Queue = function(_, packet) queued = packet; return true end
net:Send("NH", "2.0.3")
net.Queue = realQueue
assert(queued and queued.payload:find("~t0~y" .. layout .. "~m", 1, true), "presence: " .. tostring(queued and queued.payload))

local serial = 0
local function presence(who, payload)
    serial = serial + 1
    now = now + 400 -- past the per-origin gap and the pull window
    return net:Receive(table.concat({ "global", "nh" .. serial, time(), "*", who, "NH", payload }, "|"), who, "CHANNEL")
end
local richer = "~m1~o0~z000001zz~l9~ld~lr~lp6" -- a map with a capture we lack: worth a pull

presence("Same Layout", "2.0.3~t0~y" .. layout .. richer)
assert(asked[#asked] == "Same Layout", "a neighbour with our layout and news is not asked")
assert(not net:IsOutdatedMapPeer("Same Layout"), "a neighbour with our layout is out of the map exchange")

local before, outdated = #asked, net.stats.outdatedPresences or 0
presence("Older Release", "2.0.2~t0" .. richer)
assert(#asked == before, "a neighbour without a layout (2.0.2) was asked for its map")
assert(net:IsOutdatedMapPeer("Older Release"), "a 2.0.2 neighbour is in the map exchange")
assert((net.stats.outdatedPresences or 0) == outdated + 1, "the left-out presence is not counted")

presence("Other Layout", "2.0.9~t0~y" .. older .. richer)
assert(#asked == before, "a neighbour with another layout was asked for its map")
assert(net:IsOutdatedMapPeer("Other Layout"), "a neighbour with another layout is in the map exchange")
-- What a request stating a version at the floor still checks (Sync:IsOutdatedMapPeer):
-- a known other layout is outside; no layout said (2.0.2) is left to the stated version.
assert(net:PeerLayoutDiffers("Other Layout"), "another known layout does not differ")
assert(not net:PeerLayoutDiffers("Older Release"), "a presence without a layout counts as another layout")
assert(not net:PeerLayoutDiffers("Same Layout") and not net:PeerLayoutDiffers("Never Heard"),
    "our own layout, or a neighbour never heard, counts as another layout")

-- Once it updates, its next presence brings it back.
presence("Older Release", "2.0.3~t0~y" .. layout .. richer)
assert(not net:IsOutdatedMapPeer("Older Release"), "an updated neighbour stayed out")
print("Map layout cut: presence mark, order-free layout, older and other layouts out of the map exchange OK")
