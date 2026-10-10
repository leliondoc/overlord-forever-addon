-- Point to point (1.2.4): a map batch addressed to another player is never
-- relayed, so no relay spends budget on pages the recipient may never complete.
-- Local batches still flow, with the producer retrying a refused page.
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
        fields[#fields + 1] = value:sub(start, at - 1)
        start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Timer = { After = function(d, f) pending[#pending + 1] = { at = now + d, run = f } end,
    NewTicker = function() return {} end }
local delivered = {}
local function client(name)
    local a = { Version = "1.0.0", RelayEnabled = true, PlayerFaction = "Alliance",
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
    function s:SendWhisper(kind, fragment, target) delivered[#delivered + 1] = fragment; return true end
    function s:OnAddonMessage() end
    Overlord = a
    assert(loadfile(os.getenv("SBN_FILE") or "SyncRelay.lua"))()
    return a
end
local relay = client("Bridge Tester")
local net = relay.Relay
local function route() net.peers["reader tester"] = { name = "Reader Tester", at = now,
    via = "Reader Tester", transport = "WHISPER", hops = 1 } end
local serial = 0
local function page(origin, id, index, count, target)
    serial = serial + 1
    local payload = "@" .. id .. ":" .. index .. ":" .. count .. "|" .. string.rep("z", 150)
    local wire = table.concat({ "global", "p" .. serial, time(), target or "Reader Tester", origin, "ZA", payload }, "|")
    return net:Receive(wire, origin, "WHISPER")
end
local function drain()
    local guard = 0
    while #pending > 0 do
        guard = guard + 1; assert(guard < 20000, "relay did not settle")
        table.sort(pending, function(x, y) return x.at < y.at end)
        local item = table.remove(pending, 1)
        now = math.max(now, item.at); route(); item.run()
    end
end
route()
-- Forwarded addressed map pages are dropped at the relay, whatever the batch.
for i = 1, 5 do
    assert(not page("Origin Alpha", "G-1-1", i, 5), "forwarded ZA page " .. i .. " was relayed")
end
drain()
assert(#delivered == 0, "a forwarded map page reached the wire")
assert((net.stats.catchupNotRelayed or 0) == 5, "dropped forwarded pages were not counted")
-- Local batches (path length 1) are never marked: producer retry succeeds after drain.
for i = 1, 40 do
    local ok = net:Send("ZA", "@G-9-9:" .. i .. ":40|" .. string.rep("y", 120), "Reader Tester")
    if not ok then
        drain(); route()
        assert(net:Send("ZA", "@G-9-9:" .. i .. ":40|" .. string.rep("y", 120), "Reader Tester"),
            "local ZA retry was blocked by the forwarded-batch mark")
        break
    end
end
-- 1.8.2: a broadcast map of a client from before 1.7.0 (known by its own presence)
-- is not passed on: a receiver one hop further does not hear that client's presence
-- and would take its map. The same broadcast from an updated neighbour still is.
drain()
local channelCopies = 0
function relay.Sync:SendToChannel() channelCopies = channelCopies + 1; return true end
function relay.Sync:SendSyncRequest() return true end
local function hello(who, suffix)
    serial = serial + 1
    assert(net:Receive(table.concat({ "global", "h" .. serial, time(), "*", who, "NH", suffix }, "|"), who, "CHANNEL"))
end
local function broadcastMap(who)
    channelCopies = 0
    page(who, "F-7-" .. serial, 1, 1, "*")
    drain()
    return channelCopies
end
hello("Updated Client", "1.7.2~lr~lp6")
hello("Old Client", "1.6.3~lp6")
assert(net:IsOutdatedMapPeer("Old Client") and not net:IsOutdatedMapPeer("Updated Client"), "fixture: presences not read")
assert(broadcastMap("Updated Client") > 0, "fixture: a broadcast map of an updated neighbour is no longer passed on")
assert(broadcastMap("Old Client") == 0, "the map of a client from before 1.7.0 was passed on")
print("Forever relay ZA batches: forwarded map pages never relayed, local batches unaffected, "
    .. "maps of clients before 1.7.0 not passed on")
