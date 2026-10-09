-- Repeated requests/proofs with fresh envelope IDs must not fill the relay
-- while the equivalent unsent packet is still waiting. Distinct work survives.
local now, pending, sent = 100, {}, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end }
Overlord = { Version = "1.1.3", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end }, Sync = {} }
local sync = Overlord.Sync
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return { 1 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Reader Tester" end
local onSend
function sync:SendToBNet(_, kind, wire)
    assert(kind == "BR")
    if onSend then onSend(wire) end
    sent[#sent + 1] = wire
    return true
end
assert(loadfile(os.getenv("OVERLORD_AUDIT_BETA_SOURCE") or "SyncRelay.lua"))()
local net, serial = Overlord.Relay, 0
for _, name in ipairs({ "Reader Tester", "Second Tester" }) do
    net.peers[name:lower()] = { at = now, via = name, name = name, transport = "BNET", bnet = 1 }
end
local function queue(kind, payload, origin, target, at)
    serial = serial + 1
    return net:Queue({ region = "global", id = "duplicate-" .. serial, at = at or time(),
        target = target or "*", path = { origin or "Origin Tester", "Gateway Tester" },
        kind = kind, payload = payload })
end
local function request(n, mode) return "Horde:1.1.3~" .. n .. ":0:::" .. (mode or "T") end
local function drain()
    local steps = 0
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local item = table.remove(pending, 1)
        now = item.at
        item.run()
        steps = steps + 1
        assert(steps < 10000, "Duplicate scenario did not settle")
    end
end
assert(queue("SR", request(1)))
for i = 1, 83 do assert(queue("GR", "distinct-" .. i)) end
-- Full ordinary queue: replacement needs no extra slot and keeps its position.
for i = 2, 21 do
    assert(queue("SR", request(i)), "Waiting territorial requests consumed additional slots")
end
assert(queue("SR", request(0), nil, nil, time() - 1))
assert(not queue("GH", "proof-two"), "Distinct proof was merged")
assert(not queue("GH", "proof-one", "Another Tester"), "Proof authors were merged")
assert(not queue("GH", "proof-one", nil, "Reader Tester"), "Proof destinations were merged")
assert(net.stats.mapRequestsCoalesced == 20)
drain()
assert(#sent == 84, "Coalescing altered the ordinary queue bound")
assert(sent[1]:find("|SR|" .. request(21), 1, true), "Newest request lost its place or payload")

-- Forwarded targeted requests are coalesced per origin AND destination.
sent = {}
assert(queue("SR", request(30), nil, "Reader Tester"))
assert(queue("SR", request(31), nil, "Second Tester"))
for i = 32, 41 do assert(queue("SR", request(i), nil, "Reader Tester")) end
drain()
assert(#sent == 2 and sent[1]:find("|Reader Tester|", 1, true)
    and sent[1]:find("|SR|" .. request(41), 1, true)
    and sent[2]:find("|Second Tester|", 1, true), "Targeted request crossed destinations")

-- Once sending has begun, keep the original immutable until it completes.
sent = {}
local injected = false
onSend = function(wire)
    if not injected and wire:find("|SR|" .. request(50), 1, true) then
        injected = true
        assert(queue("SR", request(51)))
    end
end
assert(queue("SR", request(50)))
drain()
assert(injected and #sent == 2, "A request already being sent was replaced")
onSend = nil
sent = {}
assert(queue("SR", request(60, "F")))
assert(queue("SR", request(61, "F")))
assert(queue("SR", request(62, "S")))
assert(queue("SR", request(63)))
assert(queue("SR", request(64), "Another Tester"))
assert(queue("GR", "different-guild-one"))
assert(queue("GR", "different-guild-two"))
drain()
assert(#sent == 7, "Request modes, origins, history pages or distinct causal proofs were coalesced")
print("Beta pending duplicates: 20 repeated SR use one slot; origins, targets, history, proofs and sends preserved")
