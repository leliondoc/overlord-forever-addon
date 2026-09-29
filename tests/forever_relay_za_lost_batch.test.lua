-- Once a FORWARDED ZA page of a batch is refused at a relay, later pages of that
-- same batch (origin + snapshot id) are refused at once: downstream discards a
-- batch that misses a page. Local batches, other ids/origins, and expiry unaffected.
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
    local a = { Version = "1.0.0", BetaNetworkEnabled = true, PlayerFaction = "Alliance",
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
    assert(loadfile(os.getenv("SBN_FILE") or "SyncBetaNetwork.lua"))()
    return a
end
local relay = client("Bridge Tester")
local net = relay.BetaNetwork
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
-- Saturate the addressed ZA batch allowance with one origin's batch A.
for i = 1, 32 do assert(page("Origin Alpha", "G-1-1", i, 32), "batch A page " .. i) end
-- Batch X (other origin): page 1 is refused while A holds the allowance.
assert(not page("Origin Bravo", "G-2-1", 1, 3), "test setup: ZA allowance not saturated")
drain()
route()
-- A later page of the doomed batch X must not spend downstream budget.
assert(not page("Origin Bravo", "G-2-1", 2, 3),
    "later page of an already-refused forwarded ZA batch was admitted")
assert((net.stats.zaBatchSkipped or 0) >= 1, "skip not counted")
-- Target isolation: the same snapshot id addressed to another (routable) recipient is a
-- different batch; a refusal for "Reader Tester" must not block it.
net.peers["second reader"] = { name = "Second Reader", at = now, via = "Second Reader",
    transport = "WHISPER", hops = 1 }
assert(page("Origin Bravo", "G-2-1", 2, 3, "Second Reader"),
    "refusal for one target blocked the same snapshot id addressed to another target")
-- Controls: other snapshot id, other origin, and an unrelated fresh batch still flow.
assert(page("Origin Bravo", "G-2-2", 1, 3), "different snapshot id was blocked")
assert(page("Origin Charlie", "G-2-1", 1, 3), "same id from another origin was blocked")
drain(); route()
-- The mark expires (60 s) so a legitimately re-sent batch is not blocked forever.
now = now + 61
assert(page("Origin Bravo", "G-2-1", 1, 3), "expired batch mark still blocks")
drain(); route()
-- Non-sliding window: blocked pages must not extend the 60 s mark.
route()
for i = 1, 32 do assert(page("Origin Alpha", "G-3-0", i, 32), "batch A2 page " .. i) end
local markedAt = now
assert(not page("Origin Bravo", "G-3-1", 1, 3), "setup: batch not refused")
drain(); route()
assert(now - markedAt > 1 and now - markedAt < 59, "setup: drain took " .. (now - markedAt) .. " s")
assert(not page("Origin Bravo", "G-3-1", 2, 3), "mark did not block within its window")
now = markedAt + 61; route()
assert(page("Origin Bravo", "G-3-1", 3, 3),
    "a blocked page extended the mark beyond 60 s after the first refusal")
drain(); route()
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
print("Forever relay lost ZA batch: forwarded pages skipped, local/other/expired unaffected")
