-- 1.7.0 audit: ranking pages v7 ("7:") follow the same relay rules as v5/v6. A page is
-- whispered along its established route and never copied to the group, the realm
-- channel or Battle.net friends; with no route it is not sent at all.
local now, pending = 100, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return true end
C_Timer = { After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end }
Overlord = { Version = "1.7.0", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end }, Sync = {} }
local sync = Overlord.Sync
local sent = {}
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return 1 end
function sync:ChannelCarries() return true end
function sync:GetBetaBNetTargets() return { 7 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Friend Tester" end
function sync:SendToBNet() sent.BNET = (sent.BNET or 0) + 1; return true end
function sync:SendWhisper() sent.WHISPER = (sent.WHISPER or 0) + 1; return true end
function sync:SendToGroup() sent.GROUP = (sent.GROUP or 0) + 1; return true end
function sync:SendToChannel() sent.CHANNEL = (sent.CHANNEL or 0) + 1; return true end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork

local function drain()
    local steps = 0
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = item.at
        item.run()
        steps = steps + 1
        assert(steps < 10000, "queue did not settle")
    end
end

for _, version in ipairs({ "6", "7" }) do
    -- A direct neighbour heard through the party: its route has no whisper/channel transport.
    net.peers["party tester"] = { at = now, via = "Party Tester", name = "Party Tester",
        transport = "PARTY", hops = 1 }
    for k in pairs(sent) do sent[k] = nil end
    for _, packet in ipairs({
        { "HR", version .. ":Q:1790016000:nonce" .. version .. ":1:1:-:0:0:LK" },
        { "HA", version .. ":P:1790016000:nonce" .. version .. ":1:1:0:0:-:1:LK" },
        { "HB", version .. ":D:1790016000:nonce" .. version .. ":1:1:1:LK:" .. string.rep("x", 120) },
    }) do
        assert(net:Send(packet[1], packet[2], "Party Tester"), "v" .. version .. " page refused on a route")
    end
    drain()
    assert((sent.WHISPER or 0) >= 3, "v" .. version .. " pages not whispered: " .. tostring(sent.WHISPER))
    assert(not sent.GROUP and not sent.CHANNEL and not sent.BNET,
        ("v%s page broadcast: group %s, channel %s, bnet %s"):format(version,
            tostring(sent.GROUP), tostring(sent.CHANNEL), tostring(sent.BNET)))
    -- No route: nothing leaves (no discovery flood).
    for k in pairs(sent) do sent[k] = nil end
    assert(not net:Send("HB", version .. ":D:1790016000:nonce:1:1:1:LK:orphan", "Missing Tester"),
        "v" .. version .. " page accepted without a route")
    drain()
    assert(next(sent) == nil, "v" .. version .. " page without a route left anyway")
end
print("Paged v7 routing: whispered on the route like v6, never group/channel/Battle.net, dropped without route OK")
