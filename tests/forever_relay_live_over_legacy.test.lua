-- Evening peak, 2026-09-30: forwarded v4 ranking rows for other players borrowed
-- 94 of the 128 relay slots (16 reserved) and every live kill/score broadcast was
-- refused. Catch-up may still borrow idle slots, but live traffic and map
-- batches take borrowed slots back; the sixteen protected rows are never evicted.
local now, pending, sent = 100, {}, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end }
Overlord = { Version = "1.2.4", PlayerFaction = "Alliance",
    RealmPools = { GetOverlordPoolTag = function() return "global" end }, Sync = {} }
local sync = Overlord.Sync
function sync:GetPlayerFullName() return "Gateway Tester" end
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a, b) return a:lower() == b:lower() end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return { 1 } end
function sync:GetBetaBNetTargetInfo() return "Horde", "Reader Tester" end
function sync:SendToBNet(_, kind, wire)
    sent[#sent + 1] = { wire = wire, at = now }
    return true
end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
net.peers["reader tester"] = {
    at = now, via = "Reader Tester", name = "Reader Tester", transport = "BNET", bnet = 1,
}
local function forwarded(kind, i, target, payload)
    return net:Queue({ region = "global", id = kind .. i, at = time(), target = target,
        path = { "Origin" .. i .. " Tester", "Gateway Tester" }, kind = kind,
        payload = payload })
end

-- 1. On an idle queue a burst of forwarded v4 rows still borrows free slots.
for i = 1, 100 do
    assert(forwarded("LK", i, "Reader Tester", "legacy-" .. i), "Idle borrowing was refused")
end
assert(net:GetQueueSummary().catchup == 100)

-- 2. Live broadcasts take borrowed slots back: kills, scores, captures, progress.
for i = 1, 60 do
    local kind = ({ "K", "LK", "C", "ZS" })[(i - 1) % 4 + 1]
    assert(forwarded(kind, 1000 + i, "*", "live-" .. i),
        "Live " .. kind .. " was refused behind borrowed catch-up")
end
assert(net.stats.displaced == 60, "Live traffic evicted something other than borrowed rows")

-- 3. A map batch also outranks borrowed rows; v6 pages keep their reservation.
for i = 1, 16 do
    assert(forwarded("ZA", 2000 + i, "Reader Tester",
        "@G-live:" .. i .. ":16|" .. string.rep("z", 40)), "Map batch refused behind borrowed rows")
end
for i = 1, 4 do
    assert(net:Send("HB", "6:D:1:nonce:1:" .. i .. ":4:LK:page", "Reader Tester"),
        "v6 pages lost their reservation")
end

-- 4. The protected rows are never displaced: with no borrowed row left, a new
--    local v4 row is refused (its producer resends it) and nothing is evicted.
local before = net.stats.displaced
for i = 1, 8 do forwarded("K", 3000 + i, "*", "more-live-" .. i) end
assert(not net:Send("LK", "local-overflow", "Reader Tester"), "Local v4 row exceeded the bound")
assert(net.stats.displaced - before <= 8, "More than the remaining borrowed rows were evicted")

-- 5. Everything admitted is delivered, protected rows first included.
local steps = 0
while #pending > 0 do
    table.sort(pending, function(a, b) return a.at < b.at end)
    local item = table.remove(pending, 1)
    now = item.at
    item.run()
    steps = steps + 1
    assert(steps < 20000, "Queue did not settle")
end
local rows, live, pages, maps = {}, 0, 0, 0
for _, item in ipairs(sent) do
    local row = item.wire:match("|LK|legacy%-(%d+)$")
    if row then rows[tonumber(row)] = true end
    if item.wire:find("|live-", 1, true) or item.wire:find("|more-live-", 1, true) then live = live + 1 end
    if item.wire:find("|HB|", 1, true) then pages = pages + 1 end
    if item.wire:find("|ZA|", 1, true) then maps = maps + 1 end
end
for i = 1, 16 do assert(rows[i], "Protected v4 row " .. i .. " was evicted") end
assert(live >= 60 and pages == 4 and maps == 16, "Admitted live/map/v6 data was not delivered")
assert((net.stats.expired or 0) == 0, "Admitted data expired")
print(string.format("Relay live over legacy: idle borrowing kept, %d live packets delivered, "
    .. "16 protected v4 rows kept, map and v6 intact", live))
