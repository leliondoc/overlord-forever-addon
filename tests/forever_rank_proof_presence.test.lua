-- Top rank claim in the presence (2.0.5, "~q"): our presence says it right after the map
-- layout, a neighbour's claim is handed to RankProof only when heard first-hand from the
-- player himself (never relayed, never over Battle.net), and the layout is still read the
-- same way: 2.0.3 clients, whose parser is unchanged, keep us in the map exchange.
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

local IDS = { "hillsbrad_southshore", "hillsbrad_western_strand", "hillsbrad_fields", "hillsbrad_tarren_mill" }
local claims = {}
local function client(name, rank)
    local zones = {}
    for i, id in ipairs(IDS) do zones[i] = { id = id } end
    local a = { Version = "2.0.4", RelayEnabled = true, PlayerFaction = "Alliance",
        Fronts = { Registry = { one = { zones = zones } } },
        RealmPools = { GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, p) return p == "global" and p or "" end }, Sync = {} }
    a.RankProof = {
        PresenceToken = function() return "~q" .. rank end,
        OnPresence = function(_, origin, token) claims[#claims + 1] = { origin = origin, token = token } end,
    }
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
    function s:SendSyncRequest() return true end
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    return a
end

local me = client("Local Tester", 13)
local net = me.Relay
local layout = net.LocalMapLayout()

-- Our presence: "~t0~y<layout>~q13~m...".
local queued
local realQueue = net.Queue
net.Queue = function(_, packet) queued = packet; return true end
net:Send("NH", "2.0.4")
net.Queue = realQueue
assert(queued and queued.payload:find("~t0~y" .. layout .. "~q13~m", 1, true), "presence: " .. tostring(queued and queued.payload))
-- What a 2.0.3 client reads from it: the same layout (its pattern is the one below).
assert(queued.payload:match("~t0~y(%w+)~") == layout, "an older client would read another layout")

local serial = 0
local function presence(who, payload, transport, path)
    serial = serial + 1
    now = now + 400
    return net:Receive(table.concat({ "global", "nh" .. serial, time(), "*", path or who, "NH", payload }, "|"),
        transport == "BNET" and who or (path and path:match(",(.+)$") or who), transport or "CHANNEL")
end
local tail = "~m1~o0~z000001zz~l9~ld~lr~lp6"

presence("Top Player", "2.0.4~t0~y" .. layout .. "~q15" .. tail)
assert(#claims == 1 and claims[1].origin == "Top Player" and claims[1].token == "15", "a first-hand claim is handed over")
assert(not net:IsOutdatedMapPeer("Top Player"), "a 2.0.4 presence with a claim left the map exchange")

presence("Plain Player", "2.0.4~t0~y" .. layout .. "~q0" .. tail)
assert(#claims == 2 and claims[2].token == "0", "the protocol mark alone is handed over")

presence("Older Player", "2.0.3~t0~y" .. layout .. tail)
assert(#claims == 3 and claims[3].token == nil, "a 2.0.3 presence says nothing")
assert(not net:IsOutdatedMapPeer("Older Player"), "a 2.0.3 neighbour with our layout is still in the map exchange")

local before = #claims
presence("Far Player", "2.0.4~t0~y" .. layout .. "~q15" .. tail, "CHANNEL", "Far Player,Relay Hop")
assert(#claims == before, "a relayed claim was believed")
presence("Bnet Friend", "2.0.4~t0~y" .. layout .. "~q15" .. tail, "BNET")
assert(#claims == before, "a claim over Battle.net (the other faction) was believed")
-- A friend the game shows in our faction: his own presence may reach us over Battle.net
-- first (the channel's copy is then a duplicate), so it carries his claim too.
me.Sync.GetResolvedBNetPlayerFaction = function(_, who)
    if who == "Bnet Mate" then return "Alliance" end
    if who == "Bnet Foe" then return "Horde" end
    return nil
end
presence("Bnet Mate", "2.0.4~t0~y" .. layout .. "~q14" .. tail, "BNET")
assert(#claims == before + 1 and claims[#claims].origin == "Bnet Mate" and claims[#claims].token == "14",
    "a same-faction Battle.net friend's own presence carries his claim")
presence("Bnet Foe", "2.0.4~t0~y" .. layout .. "~q15" .. tail, "BNET")
presence("Bnet Unknown", "2.0.4~t0~y" .. layout .. "~q15" .. tail, "BNET")
assert(#claims == before + 1, "an enemy friend, or one of unknown faction, is never a claim")
-- A group can hold the other faction: the game's word on the sender decides.
me.Sync.GetGroupMemberFaction = function(_, who) return who == "Group Foe" and "Horde" or "Alliance" end
presence("Group Foe", "2.0.4~t0~y" .. layout .. "~q15" .. tail, "PARTY")
assert(#claims == before + 1, "a group mate of the other faction is never a claim")
presence("Group Mate", "2.0.4~t0~y" .. layout .. "~q12" .. tail, "RAID")
assert(#claims == before + 2 and claims[#claims].origin == "Group Mate", "a group mate of ours is")
-- With one week of his own word (".<week>-<kills>", base 36): the whole token reaches
-- RankProof, older parsers still read the layout.
presence("Word Player", "2.0.4~t0~y" .. layout .. "~q15.9q-3uw" .. tail)
assert(claims[#claims].origin == "Word Player" and claims[#claims].token == "15.9q-3uw", "the word is handed over")
-- The presence of a long-named holder with his word still fits in one fragment (170).
local long = client("Abcdefghijkl Mnopqrstuvwx", "15.zz-zzzz")
local longNet, longQueued = long.Relay, nil
local longQueue = longNet.Queue
longNet.Queue = function(_, p) longQueued = p return true end
longNet:Send("NH", "2.0.4")
longNet.Queue = longQueue
local wire = table.concat({ longQueued.region, longQueued.id, tostring(longQueued.at), longQueued.target,
    table.concat(longQueued.path, ","), longQueued.kind, longQueued.payload }, "|")
assert(longQueued.payload:find("~q15.zz-zzzz~m", 1, true) and #wire <= 170,
    "one fragment: " .. #wire .. " bytes: " .. wire)
print("Rank claim in the presence: after the layout, first-hand only, older parsers unaffected, " .. #wire .. "/170 bytes OK")
