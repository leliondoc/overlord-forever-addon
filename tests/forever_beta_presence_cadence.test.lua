-- Presence (NH) cadence and reclaim: the heartbeat runs every 120 s (routes and
-- the ~lp6 capability live 300 s), and ordinary traffic can take back a slot an
-- unsent presence borrowed instead of being refused behind a queue of NH.
local now, pending, ticker = 100, {}, nil
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function(interval, callback) ticker = { interval = interval, run = callback }; return ticker end,
}
Overlord = { Version = "1.1.5", PlayerFaction = "Alliance", RelayEnabled = true,
    RealmPools = { GetOverlordPoolTag = function() return "global" end }, Sync = {} }
local sync = Overlord.Sync
local sentKinds = {}
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return { 1 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Reader Tester" end
function sync:SendToBNet(_, kind, wire)
    -- wire = region|id|at|target|path|kind|payload
    local inner = wire:match("^[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|([^|]*)|") or "?"
    sentKinds[#sentKinds + 1] = inner
    return true
end
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay

-- Heartbeat cadence.
net:Start()
assert(ticker and ticker.interval == 120, "Presence heartbeat is not every 120 s: " .. tostring(ticker and ticker.interval))
assert(#pending == 1 and pending[1].at == now + 3, "Login presence is not sent shortly after start")

-- A queue fully borrowed by presence copies.
local function presence(i)
    return net:Queue({ region = "global", id = "nh" .. i, at = time(), target = "*",
        path = { "Origin" .. i .. " Tester", "Gateway Tester" }, kind = "NH", payload = "1.1.3" })
end
for i = 1, 128 do assert(presence(i), "Idle queue refused a borrowing presence") end
assert(not presence(129), "Presence exceeded the global 128-item bound")
local function nhDropped() return net.kindStats.NH and net.kindStats.NH.dropped or 0 end
local before = nhDropped()

-- Ordinary (bulk) traffic reclaims presence slots one for one: guild and class
-- requests, the guild raid alert, a broadcast sync request.
local ordinary = {
    { "GR", "Some Player:1790016000" },
    { "GI", "Some Guild:1790016000" },
    { "GW", "1:Empire:A:20:5:#1417:143:1790016000" },
    { "SR", "A:1.1.5:0::S" },
}
for i, row in ipairs(ordinary) do
    assert(not net:IsUrgentPacket(row[1], row[2]), row[1] .. " is expected to be ordinary traffic")
    assert(net:Send(row[1], row[2]), row[1] .. " was refused behind borrowed presence slots")
    assert(nhDropped() == before + i, row[1] .. " did not take back exactly one presence slot")
end
-- A presence still never evicts another presence, and the bound holds.
assert(not presence(200), "A presence evicted another presence")
local later = nhDropped()

-- Everything admitted is eventually sent, ordinary packets included.
while #pending > 0 do
    table.sort(pending, function(a, b) return a.at < b.at end)
    local item = table.remove(pending, 1)
    now = item.at
    item.run()
end
local got = {}
for _, kind in ipairs(sentKinds) do got[kind] = (got[kind] or 0) + 1 end
for _, row in ipairs(ordinary) do
    assert((got[row[1]] or 0) >= 1, row[1] .. " was admitted but never sent")
end
assert(nhDropped() == later, "Draining the queue dropped more presence copies")
print("Beta presence cadence: 120 s heartbeat, ordinary traffic reclaims borrowed presence slots")

-- Anti-starvation: under a continuous stream of relayed presence (urgent), an
-- ordinary packet queued behind it is sent after ~20 s instead of expiring (120 s).
do
    local serial, sentAt, flowUntil = 1000, nil, now + 150
    local base = now
    sync.SendToBNet = function(_, _, kind, wire) -- called as sync:SendToBNet(target, kind, data)
        local inner = wire:match("^[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|([^|]*)|")
        if inner == "OP" and not sentAt then sentAt = now end
        return true
    end
    local function flow()
        if now >= flowUntil then return end
        serial = serial + 1
        net:Queue({ region = "global", id = "flow" .. serial, at = time(), target = "*",
            path = { "Flow" .. serial .. " Tester", "Gateway Tester" }, kind = "NH", payload = "1.1.3" })
        C_Timer.After(0.1, flow)
    end
    flow()
    for _ = 1, 30 do pending[#pending + 1] = { at = now + 0.05, run = function() end } end
    assert(net:Send("OP", "v1:badlands:held:0:Keep Guild:A:1790017500:0:1790017500:600:global:0"),
        "Routine outpost state refused")
    local steps = 0
    while #pending > 0 and not sentAt do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = item.at
        item.run()
        steps = steps + 1
        assert(steps < 200000, "Relay did not settle")
    end
    assert(sentAt, "Routine outpost state never left behind continuous presence")
    assert(sentAt - base < 60, ("Routine outpost state waited %.1f s behind presence"):format(sentAt - base))
    print(("Beta anti-starvation: routine OP sent after %.1f s of continuous presence"):format(sentAt - base))
end
