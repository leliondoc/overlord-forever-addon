-- Reproduce the measured regression: synchronous presence bursts evicted
-- accepted LK rows even though unused reservations could hold the presence.
local run = assert(loadfile("tests/forever_beta_head_comparison.audit.lua"))
for _, phased in ipairs({ false, true }) do
    local result = run({ source = "SyncBetaNetwork.lua", duration = 540, phased = phased })
    assert(result.deliveredLK == result.offeredLK, "Presence bursts lost accepted ranking rows")
    assert(result.deliveredZA == 32 and result.deliveredDX == result.offeredDX,
        "Preserving ranking rows starved map or domination delivery")
    assert((result.stats.expired or 0) == 0 and (result.stats.displaced or 0) == 0,
        "Mixed traffic evicted or expired accepted data")
    assert(result.stats.bytes <= 500 + 1000 * result.elapsed,
        "Relay exceeded the shared byte budget")
    for _, friend in ipairs(result.friends) do
        local origins = 0
        for key in pairs(friend.BetaNetwork.peers) do
            if key:match("^origin") then origins = origins + 1 end
        end
        assert(origins == 100, "Reducing drops lost origin discovery on a Horde bridge")
    end
end

-- A queue fully borrowed by NH must still recover all reservations, reject
-- overflow, and validate routes before evicting anything.
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
function sync:SendToBNet(_, kind, wire)
    assert(kind == "BR", "Small fixture unexpectedly fragmented")
    sent[#sent + 1] = { wire = wire, at = now }
    return true
end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
net.peers["reader tester"] = {
    at = now, via = "Reader Tester", name = "Reader Tester", transport = "BNET", bnet = 1,
}
local function presence(i)
    return net:Queue({ region = "global", id = "nh" .. i, at = time(), target = "*",
        path = { "Origin" .. i .. " Tester", "Gateway Tester" }, kind = "NH", payload = "1.1.3" })
end
for i = 1, 128 do assert(presence(i), "Idle queue reservations refused reclaimable presence") end
assert(not presence(129), "Presence exceeded the global 128-item bound")
assert(not net:Send("HB", "6:D:1:nonce:1:1:1:LK:orphan", "Missing Tester"))
assert(not net.stats.displaced, "An unroutable page evicted a pending presence")
for i = 1, 100 do
    assert(net:Send("LK", "row-" .. i, "Reader Tester"), "Ranking could not reclaim borrowed space")
end
assert(not net:Send("LK", "ranking-overflow", "Reader Tester"), "Legacy rows took paged/state reservations")
for i = 1, 4 do
    assert(net:Send("HB", "6:D:1:nonce:1:" .. i .. ":4:LK:page", "Reader Tester"))
end
assert(not net:Send("HB", "6:D:1:nonce:1:5:5:LK:overflow", "Reader Tester"))
for i = 1, 24 do
    assert(net:Send("VB", "1790016000:global:front" .. i .. ",A,1790016001,1790016001,20,1000"))
end
assert(not net:Send("VB", "1790016000:global:overflow,A,1790016001,1790016001,20,1000"))
assert(net.stats.displaced == 128, "Reservation recovery did not evict exactly the borrowed presence")
local before = net.stats.displaced
assert(not presence(130), "A full data queue admitted NH by evicting accepted data")
assert(net.stats.displaced == before, "Presence displaced accepted data")
assert(net:Send("C", "terminal", "Reader Tester"), "Terminal lost priority over borrowed legacy rows")
local steps = 0
while #pending > 0 do
    table.sort(pending, function(a, b) return a.at < b.at end)
    local item = table.remove(pending, 1)
    now = item.at
    item.run()
    steps = steps + 1
    assert(steps < 10000, "Full queue did not settle")
end
local rows, pages, states, terminals = {}, 0, 0, 0
for _, item in ipairs(sent) do
    local row = item.wire:match("|LK|row%-(%d+)$")
    if row then rows[tonumber(row)] = true end
    if item.wire:find("|HB|", 1, true) then pages = pages + 1 end
    if item.wire:find("|VB|", 1, true) then states = states + 1 end
    if item.wire:find("|C|terminal", 1, true) then
        terminals = terminals + 1
        assert(item.at - 100 < 2, "Terminal delayed by presence borrowing")
    end
end
for i = 1, 16 do assert(rows[i], "Reserved legacy row was evicted") end
assert(#sent == 128 and pages == 4 and states == 24 and terminals == 1,
    "Full queue lost protected data or exceeded its bound")
assert((net.stats.expired or 0) == 0, "Accepted data expired")
print("Beta presence: idle reservations borrowed safely, bounded data reclaimed, all mixed-load data delivered")
