-- 2.5.5: the fight brackets (FK, the "Recent activity" panel) have a share of the relay's bytes.
-- Past it, a bracket relayed for somebody else is handled here and not passed on; captures and
-- everything else keep their room. Our own announcements are not weighed (their bytes count).
-- (2026-11-17: on a client that was the only bridge between the factions, FK was 45 % of the
-- bytes the relay sent and 93 % of what it refused.)
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
-- (The relay's pump runs on timers: kept, and run by drain().)
local pending = {}
C_Timer = { After = function(delay, run) pending[#pending + 1] = { at = now + delay, run = run } end,
    NewTicker = function() return {} end }
local function drain()
    local steps = 0
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = math.max(now, item.at)
        item.run()
        steps = steps + 1
        assert(steps < 10000, "fixture: unbounded pump")
    end
end
Overlord = {
    Version = "2.5.5", RelayEnabled = true, PlayerFaction = "Alliance",
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
-- (Battle.net friend 77 is a player of the other faction: what it hands us crosses the factions.)
function s:GetBetaBNetTargetInfo(id) if id == 77 then return "Horde", "Enemy Friend" end end
local handled = {}
function s:OnAddonMessage(_, message)
    local kind = message:match("^(%u+):")
    if kind then handled[kind] = (handled[kind] or 0) + 1 end
end
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
net.BridgeChannelHold = { 0, 0 } -- forward at once: this test is about the share, not bridging

local stampedAt = {}
local function wire(id, path, kind, payload)
    stampedAt[id] = stampedAt[id] or time()
    return table.concat({ "global", id, tostring(stampedAt[id]), "*", path, kind, payload }, "|")
end
local function queued(kind) return net.kindStats[kind] and net.kindStats[kind].queued or 0 end
local function bracket(zone, size) return "1:" .. zone .. ":" .. size .. ":" .. math.floor(time() / 30) end
local serial = 0
local function receive(kind, payload, gateway)
    serial = serial + 1
    gateway = gateway or "First Bridge"
    return net:Receive(wire("packet-" .. serial, "Origin Player," .. gateway, kind, payload), gateway, "WHISPER")
end

assert(net.FK_SHARE_RATE > 0 and net.FK_SHARE_WINDOW > 0, "the share is not set")
local budget = net.FK_SHARE_RATE * net.FK_SHARE_WINDOW

-- 1. Under the share a bracket relayed for somebody else is handled here and passed on.
receive("FK", bracket("durotar", 5))
assert(queued("FK") == 1 and (handled.FK or 0) == 1, "a bracket under the share was not passed on: " .. queued("FK"))
assert((net.stats.fightShareSkipped or 0) == 0)
-- (The share counts the bytes of FK that really leave: here the copy just passed on.)
drain()
assert(net.kindStats.FK.bytes > 0, "the bytes of a fight bracket that left are not counted: the share would never close")
assert(net:FightShareSpent() == false, "fixture: one bracket used the whole share")

-- 2. The share is counted in bytes really sent, our own announcements included. Once the
--    window's bytes are used, a bracket relayed for somebody else is still handled here (our
--    own panel) and not passed on.
local row = net.kindStats.FK
row.bytes = row.bytes + budget
local before, handledBefore = queued("FK"), handled.FK
receive("FK", bracket("durotar", 10))
receive("FK", bracket("ashenvale", 5))
assert(queued("FK") == before, "a bracket past the share was passed on")
assert(handled.FK == handledBefore + 2, "a bracket past the share was not taken for our own panel")
assert(net.stats.fightShareSkipped == 2, "brackets left out past the share are not counted: " .. tostring(net.stats.fightShareSkipped))

-- 3. Nothing else is held to that share: a capture relayed for somebody else passes.
local captures = queued("C")
receive("C", "elwynn_point:Origin Player:Alliance:" .. time())
assert(queued("C") == captures + 1, "a capture was held to the fight brackets' share")

-- 4. Our own announcement does not go through the share at all (it is weighed in net:Receive,
--    which our own packets never enter): with the share spent it still leaves. (A guard
--    against the check being moved into the queue's admission one day.)
before = queued("FK")
assert((net:Broadcast("FK", bracket("hillsbrad", 25)) or 0) > 0, "our own bracket was refused past the share")
assert(queued("FK") == before + 1, "our own bracket was not queued")
-- (Its bytes count in the share once they leave.)
local sentBefore = row.bytes
drain()
assert(row.bytes > sentBefore, "the bytes of our own bracket are not counted in the share")

-- 5. A new window opens the share again.
now = now + net.FK_SHARE_WINDOW + 1
before = queued("FK")
receive("FK", bracket("durotar", 25))
assert(queued("FK") == before + 1, "the share did not open again with a new window")
-- (And it closes at the same number of bytes, not sooner.)
row.bytes = row.bytes + budget - 1
receive("FK", bracket("durotar", 50))
assert(queued("FK") == before + 2, "the share closed one byte early")
row.bytes = row.bytes + 1
receive("FK", bracket("durotar", 75))
assert(queued("FK") == before + 2 and net.stats.fightShareSkipped == 3, "the share did not close at its bytes")

-- 6. A counter that went back (statistics started again) starts a window: the share counts
--    from there, it neither locks nor stays open for as many bytes as were counted before.
row.bytes = 0
assert(net:FightShareSpent() == false, "a counter that went back locked the share")
row.bytes = budget
assert(net:FightShareSpent() == true, "a counter that went back left the share open")

-- 7. A bracket that has just crossed the factions (a Battle.net friend of the other side handed
--    it to us: we may be its only way in) has room of its own, up to twice the share in all.
do
    now = now + net.FK_SHARE_WINDOW + 1
    assert(net:FightShareSpent() == false, "fixture: the window did not start afresh")
    row.bytes = row.bytes + budget
    local function crossing(zone, size)
        serial = serial + 1
        return net:Receive(wire("packet-" .. serial, "Other Player,Enemy Friend", "FK", bracket(zone, size)), "Enemy Friend", "BNET", 77)
    end
    local skipped = net.stats.fightShareSkipped
    before = queued("FK")
    receive("FK", bracket("redridge", 5))
    assert(queued("FK") == before and net.stats.fightShareSkipped == skipped + 1, "fixture: the share is not spent for our own side")
    crossing("redridge", 10)
    assert(queued("FK") == before + 1 and net.stats.fightShareSkipped == skipped + 1,
        "a bracket that had just crossed the factions was closed out by our own side's share")
    row.bytes = row.bytes + budget
    crossing("redridge", 25)
    assert(queued("FK") == before + 1 and net.stats.fightShareSkipped == skipped + 2,
        "the brackets crossing the factions have no bound")
end

-- 8. A bracket held by the share is weighed again when another copy of the same packet comes:
--    held from a neighbour of our own side, it still passes when a friend of the other faction
--    hands us that very packet (its room of its own).
do
    now = now + net.FK_SHARE_WINDOW + 1
    assert(net:FightShareSpent() == false, "fixture: the window did not start afresh")
    row.bytes = row.bytes + budget
    serial = serial + 1
    local id, payload = "packet-" .. serial, bracket("arathi", 5)
    local skipped = net.stats.fightShareSkipped
    before = queued("FK")
    net:Receive(wire(id, "Other Player,First Bridge", "FK", payload), "First Bridge", "WHISPER")
    assert(queued("FK") == before and net.stats.fightShareSkipped == skipped + 1, "fixture: the first copy was not held")
    net:Receive(wire(id, "Other Player,Enemy Friend", "FK", payload), "Enemy Friend", "BNET", 77)
    assert(queued("FK") == before + 1, "the copy that crossed the factions was dropped because another copy had been held")
end

-- 9. One neighbour cannot use up the share of everybody else: FK_GATEWAY_MAX brackets to pass
--    on per window, whoever it says wrote them; another neighbour's still pass.
do
    now = now + net.FK_SHARE_WINDOW + 1
    assert(net:FightShareSpent() == false, "fixture: the window did not start afresh")
    before = queued("FK")
    local skipped = net.stats.fightShareSkipped
    for i = 1, net.FK_GATEWAY_MAX do receive("FK", bracket("#" .. (2000 + i), 5), "Loud Neighbour") end
    assert(queued("FK") == before + net.FK_GATEWAY_MAX and net.stats.fightShareSkipped == skipped,
        "fixture: brackets under a neighbour's count were held")
    receive("FK", bracket("#2100", 5), "Loud Neighbour")
    assert(queued("FK") == before + net.FK_GATEWAY_MAX and net.stats.fightShareSkipped == skipped + 1,
        "a neighbour past its count still had its brackets passed on")
    receive("FK", bracket("#2101", 5), "Quiet Neighbour")
    assert(queued("FK") == before + net.FK_GATEWAY_MAX + 1, "a neighbour's count closed the share for another neighbour")
    -- (A new window opens it again for the loud one.)
    now = now + net.FK_SHARE_WINDOW + 1
    receive("FK", bracket("#2102", 5), "Loud Neighbour")
    assert(queued("FK") == before + net.FK_GATEWAY_MAX + 2, "a neighbour's count did not start afresh with a new window")
end

print("Fight bracket share: FK relayed for others bounded in bytes, own panel and own announcements untouched, captures unaffected OK")
