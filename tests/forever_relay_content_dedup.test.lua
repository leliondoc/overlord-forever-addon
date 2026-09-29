-- Local content coverage for relayed broadcast content (OP, LO, LOC, VB, TV, DX).
-- Run from the repo root under Lua 5.1: lua proposal_test.lua
-- (OVERLORD_AUDIT_BETA_SOURCE may point to another SyncBetaNetwork.lua).
-- Fails on 1.1.10 (sections 1 and 2), passes with proposal.diff.
local now, pending, sentTo = 100, {}, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end }
Overlord = { Version = "1.1.11", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end }, Sync = {} }
local sync = Overlord.Sync
local names = { "Friend A", "Friend B", "Friend C", "Friend D", "Friend E", "Friend F", "Friend G" }
local friends = { 1, 2, 3, 4, 5, 6, 7 }
local failNext = {}
function sync:GetPlayerFullName() return "Relay Tester" end
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return friends end
function sync:GetBetaBNetTargetInfo(id) return "Alliance", names[id] end
function sync:SendToBNet(id, kind, wire)
    assert(kind == "BR")
    if failNext[id] then failNext[id] = nil; return false end
    sentTo[id] = sentTo[id] or {}
    table.insert(sentTo[id], wire)
    return true
end
assert(loadfile(os.getenv("OVERLORD_AUDIT_BETA_SOURCE") or "SyncBetaNetwork.lua"))()
local net, serial = Overlord.BetaNetwork, 0
local function drain(limit)
    local steps = 0
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        if limit and pending[1].at > limit then break end
        local item = table.remove(pending, 1)
        now = math.max(now, item.at)
        item.run()
        steps = steps + 1
        assert(steps < 20000, "scenario did not settle")
    end
end
-- A copy relayed for another origin through gateway friend `via` (index in names).
local function relay(kind, payload, via, origin)
    serial = serial + 1
    return net:Queue({ region = "global", id = "cov-" .. serial, at = time(),
        target = "*", path = { origin or ("Far Origin " .. serial), names[via], "Relay Tester" },
        kind = kind, payload = payload })
end
local function received(part)
    local n = 0
    for _, id in ipairs(friends) do
        for _, wire in ipairs(sentTo[id] or {}) do
            if wire:find(part, 1, true) then n = n + 1; break end
        end
    end
    return n
end
local function copies(part)
    local n = 0
    for _, id in ipairs(friends) do
        for _, wire in ipairs(sentTo[id] or {}) do
            if wire:find(part, 1, true) then n = n + 1 end
        end
    end
    return n
end
local function reset() sentTo = {} end
local function fill(kind, count, payloadOf)
    for i = 1, count do
        serial = serial + 1
        assert(net:Queue({ region = "global", id = "fill-" .. serial, at = time(), target = "*",
            path = { "Filler " .. serial, "Relay Tester" }, kind = kind, payload = payloadOf(i) }))
    end
end

-- kind, payload of the shared content, lane fill needed to be "busy", filler
-- kind/payload (same lane as the content).
local suites = {
    { kind = "VB", payload = function(n) return "10:front" .. n .. ":5:srcA" end, busy = 12,
      filler = function(i) return "1:fill" .. i .. ":1:src" end, fillKind = "VB" },
    { kind = "LO", payload = function(n) return "outpost" .. n .. ":Guild One:A:100:200:global" end, busy = 42,
      filler = function(i) return "filler-" .. i end, fillKind = "GR" },
    { kind = "OP", payload = function(n) return "v1:outpost" .. n .. ":held:0:Guild One:A:1:2:3:3600:global:0" end,
      busy = 42, filler = function(i) return "filler-" .. i end, fillKind = "GR" },
}
for _, suite in ipairs(suites) do
    local kind = suite.kind
    now = now + 200
    drain()
    reset()
    -- 1. Rotating slots never repeat a covered friend while another one has not
    -- got the content: unrelated broadcasts move the shared cursor between the
    -- copies, so 1.1.10 sends copy 2 to friends that already hold it and leaves
    -- some friends out.
    local A = suite.payload(1)
    assert(relay(kind, A, 1))
    drain(now + 5)
    assert(relay("GR", "unrelated-" .. kind, 1, "Other Origin"))
    drain(now + 5)
    assert(relay(kind, A, 2))
    drain(now + 5)
    -- Friends A and B (the gateways of the two copies) hold it; every other friend must by now.
    local missing = {}
    for id = 3, 7 do
        local got = false
        for _, wire in ipairs(sentTo[id] or {}) do if wire:find(A, 1, true) then got = true end end
        if not got then missing[#missing + 1] = names[id] end
    end
    assert(#missing == 0, kind .. ": identical copy from a second origin left friends out: "
        .. table.concat(missing, ", "))

    -- 2. Busy queue: an identical copy whose friends are all covered is not
    -- queued again, and covered friends are not sent it.
    drain()
    now = now + 100 -- coverage of the previous content expired
    reset()
    local B = suite.payload(2)
    for i = 1, 7 do assert(relay(kind, B, i)) end -- every friend hears it once
    drain()
    assert(received(B) == 7)
    for i = 1, 7 do assert(relay(kind, B, i)) end -- and a second time
    drain()
    reset()
    fill(suite.fillKind, suite.busy, suite.filler)
    local skipped = net.stats.contentDedupSkipped or 0
    assert(relay(kind, B, 4, "Another Origin"))
    assert((net.stats.contentDedupSkipped or 0) == skipped + 1,
        kind .. ": busy queue took an identical copy whose friends were all covered")
    drain()
    assert(copies(B) == 0, kind .. ": covered friends received the repeat while the queue was busy")

    -- 3. Quiet queue: an identical copy is still repeated exactly like 1.1.10
    -- (a copy lost on one hop is recovered by the next origin).
    now = now + 100
    drain()
    reset()
    local C = suite.payload(3)
    assert(relay(kind, C, 1, "Origin One"))
    drain()
    local first = copies(C)
    assert(first > 0)
    assert(relay(kind, C, 1, "Origin Two"))
    drain()
    assert(copies(C) > first, kind .. ": quiet queue no longer repeats an identical copy")

    -- 4. A send that failed does not count as covered: the next copy retries it
    -- even while the queue is busy.
    now = now + 100
    drain()
    reset()
    local D = suite.payload(4)
    for id = 1, 7 do failNext[id] = true end
    assert(relay(kind, D, 1, "Origin Three"))
    drain()
    assert(received(D) == 0)
    failNext = {}
    fill(suite.fillKind, suite.busy, suite.filler)
    assert(relay(kind, D, 2, "Origin Four"))
    drain()
    assert(received(D) > 0, kind .. ": friends whose first copy failed were never retried")
end
print("Forever relay content dedup: fan-out coverage substitution, busy-queue skip, failed copies retried OK")
