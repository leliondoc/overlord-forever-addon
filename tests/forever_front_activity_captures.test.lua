-- 1.7.0 Recent activity: "1+ kill" under 5 kills and zones taken in the last 5 min
-- (1+, 5+, 10+ captures) instead of "x min ago". Captures are read from the shared
-- map (capture times), so every client shows the same rows in the same order.
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
Enum = { UIMapType = { Zone = 3, Dungeon = 4 } }
C_Map = { GetMapInfo = function() return nil end }
wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local serverNow = 1789530000
local campaignStart = 1789527600
GetServerTime = function() return serverNow end
GetTime = function() return serverNow end
time = os.time
OverlordDB = { frontTruceResetEpoch = {} }
Overlord.GetCurrentCampaignStartTs = function() return campaignStart end
-- Relay on: rows show only shared state.
Overlord.BetaNetwork = { Broadcast = function() end, IsEnabled = function() return true end }
assert(loadfile("Fronts.lua"))()
assert(loadfile("FrontActivity.lua"))()
local FA, fronts = Overlord.FrontActivity, Overlord.Fronts

local function zonesOf(frontId)
    local front = fronts:GetFront(frontId)
    assert(front and front.zones and #front.zones >= 6, "test front has too few zones: " .. frontId)
    for _, zone in ipairs(front.zones) do zone.owner, zone.capturedTime = nil, nil end
    return front.zones
end
local function row(frontId)
    for _, r in ipairs(FA:GetActivityRows()) do if r.frontId == frontId then return r end end
end

local ash = zonesOf("ashenvale")
local dur = zonesOf("durotar")
assert(not row("ashenvale").active, "a quiet front was active")
-- Quiet rows follow the fixed front order, the same in every language.
do
    local seen = {}
    for _, r in ipairs(FA:GetActivityRows()) do
        if not r.active then seen[#seen + 1] = r.frontId end
    end
    local expected = {}
    for _, id in ipairs(fronts.Order) do
        if fronts:GetFront(id) then expected[#expected + 1] = id end
    end
    assert(table.concat(seen, ",") == table.concat(expected, ","),
        "quiet rows not in front order: " .. table.concat(seen, ","))
end
-- Relay on: an event only this client recorded (no shared bracket, no capture on the
-- map) never lights a row, so every client shows the same panel.
FA:Record("ashenvale", nil, serverNow)
FA:RecordKillActivity("@ashenvale", "Local Tester", serverNow, true)
assert(not row("ashenvale").active, "a local-only event lit the row with the relay on")

-- Two zones taken 1 and 4 minutes ago count; one taken 6 minutes ago does not.
ash[1].owner, ash[1].capturedTime = "Horde", serverNow - 60
ash[2].owner, ash[2].capturedTime = "Horde", serverNow - 240
ash[3].owner, ash[3].capturedTime = "Alliance", serverNow - 360
-- Shared stamps that are not captures: campaign start and a truce end epoch.
ash[4].owner, ash[4].capturedTime = "Alliance", campaignStart
OverlordDB.frontTruceResetEpoch.ashenvale = serverNow - 30
ash[5].owner, ash[5].capturedTime = "Alliance", serverNow - 30
-- The kept capital of that truce end, one second later, is not a capture either.
assert(ash[7], "fixture needs 7 zones")
ash[7].owner, ash[7].capturedTime = "Horde", serverNow - 29
-- A capture not yet attested and a zone without owner never count.
ash[6].owner, ash[6].capturedTime, ash[6]._captureFinalUnattested = "Horde", serverNow - 10, true
assert(FA:GetRecentCaptureCount("ashenvale") == 2, "captures: " .. FA:GetRecentCaptureCount("ashenvale"))
ash[6]._captureFinalUnattested = nil
local r = row("ashenvale")
assert(r.active and r.captures == 3 and r.kills == 0, "the capture-only front is not listed")
-- The campaign start stamp is ignored even inside the 5 min window (fresh week).
Overlord.GetCurrentCampaignStartTs = function() return serverNow - 100 end
ash[4].capturedTime = serverNow - 100
assert(FA:GetRecentCaptureCount("ashenvale") == 3, "the campaign start stamp counted as a capture")
Overlord.GetCurrentCampaignStartTs = function() return campaignStart end
-- A stamp beyond the accepted clock skew (more than 5 min ahead) never counts.
ash[4].capturedTime = serverNow + 400
assert(FA:GetRecentCaptureCount("ashenvale") == 3, "a future stamp counted as a capture")
ash[4].capturedTime = campaignStart
-- A fresh stamp on a zone without owner (neutral) is not a capture.
local ownerBefore = ash[2].owner
ash[2].owner = nil
assert(FA:GetRecentCaptureCount("ashenvale") == 2, "an ownerless zone counted as a capture")
ash[2].owner = ownerBefore

-- Kills come first: a front with 1+ kill (shared bracket 1) sorts above captures only,
-- and a bigger kill bracket above that. Ties fall back to the front id, never a clock.
dur[1].owner, dur[1].capturedTime = "Horde", serverNow - 20
local peer = 0
local function bracket(frontId, value)
    local slot = math.floor(serverNow / 30)
    peer = peer + 1
    assert(FA:OnReceiveKillBracket("1:" .. frontId .. ":" .. value .. ":" .. slot,
        "Peer" .. peer .. " Tester", "BETA"), "bracket refused: " .. frontId)
end
bracket("durotar", 1)
assert(row("durotar").kills == 1 and row("durotar").active, "1+ kill row missing")
local rows, order = FA:GetActivityRows(), {}
for _, x in ipairs(rows) do if x.active then order[#order + 1] = x.frontId end end
assert(order[1] == "durotar" and order[2] == "ashenvale",
    "row order: " .. table.concat(order, ","))
bracket("ashenvale", 5)
rows, order = FA:GetActivityRows(), {}
for _, x in ipairs(rows) do if x.active then order[#order + 1] = x.frontId end end
assert(order[1] == "ashenvale" and order[2] == "durotar", "row order: " .. table.concat(order, ","))

-- A victory stamps every zone of the front with its time: one capture, not 10+.
local victoryTs = serverNow - 5
-- No victory record needed: a client missing it (late joiner) counts the same.
OverlordDB.frontVictories = nil
for _, zone in ipairs(dur) do zone.owner, zone.capturedTime = "Horde", victoryTs end
assert(FA:GetRecentCaptureCount("durotar") == 1, "victory restamp counted as "
    .. FA:GetRecentCaptureCount("durotar") .. " captures")
dur[2].capturedTime = serverNow - 2 -- a real capture after the victory still counts
assert(FA:GetRecentCaptureCount("durotar") == 2)

-- After 5 minutes the captures expire and the row goes quiet (brackets expire too).
serverNow = serverNow + 400
assert(FA:GetRecentCaptureCount("ashenvale") == 0)
assert(not row("ashenvale").active and not row("durotar").active, "an expired front stayed active")
-- Rows are ordered by the shown capture bracket, not the raw count: 6 and 5 captures
-- both read "5+", so the front id decides (one capture not yet synced swaps nothing).
OverlordDB.frontVictories = nil
for i = 1, 5 do ash[i].owner, ash[i].capturedTime = "Horde", serverNow - 10 - i end
ash[6].owner, ash[6].capturedTime = nil, nil
for i = 1, 6 do dur[i].owner, dur[i].capturedTime = "Horde", serverNow - 10 - i end
rows, order = FA:GetActivityRows(), {}
for _, x in ipairs(rows) do if x.active then order[#order + 1] = x.frontId end end
assert(order[1] == "ashenvale" and order[2] == "durotar", "raw capture count decided the order: "
    .. table.concat(order, ","))

-- A bigger capture bracket sorts first even when the front id would not: 1 capture in
-- Ashenvale, 5+ in Durotar -> Durotar first.
for i = 2, 5 do ash[i].owner, ash[i].capturedTime = nil, nil end
rows, order = FA:GetActivityRows(), {}
for _, x in ipairs(rows) do if x.active then order[#order + 1] = x.frontId end end
assert(order[1] == "durotar" and order[2] == "ashenvale", "capture bracket did not decide the order: "
    .. table.concat(order, ","))

-- 10+ beats 5+ (same shared thresholds as the text): the front with the most zones
-- takes 10 captures, the other keeps 6.
local big, small
for _, id in ipairs({ "ashenvale", "durotar" }) do
    local count = #fronts:GetFront(id).zones
    if count >= 10 and not big then big = id else small = id end
end
if big then
    local bigZones = big == "ashenvale" and ash or dur
    for i = 1, 10 do bigZones[i].owner, bigZones[i].capturedTime = "Horde", serverNow - 20 - i end
    local smallZones = small == "ashenvale" and ash or dur
    for i = 1, 6 do smallZones[i].owner, smallZones[i].capturedTime = "Horde", serverNow - 40 - i end
    assert(FA.GetCaptureBracket(10) == 10 and FA.GetCaptureBracket(9) == 5)
    rows, order = FA:GetActivityRows(), {}
    for _, x in ipairs(rows) do if x.active then order[#order + 1] = x.frontId end end
    assert(order[1] == big, "10+ captures did not sort above 5+: " .. table.concat(order, ","))
    for i = 1, 10 do bigZones[i].owner, bigZones[i].capturedTime = nil, nil end
    for i = 1, 6 do dur[i].owner, dur[i].capturedTime = "Horde", serverNow - 10 - i end
    ash[1].owner, ash[1].capturedTime = "Horde", serverNow - 10
else
    assert(FA.GetCaptureBracket(10) == 10 and FA.GetCaptureBracket(9) == 5 and FA.GetCaptureBracket(4) == 1)
end

-- A truce end known only from the map (zones at E, kept capital at E + 1, no local
-- truce-end record yet) is not a capture either: the late joiner counts like the others.
do
    local savedZones = Overlord.Zones
    Overlord.Zones = { IsKeptCapitalStamp = function(_, frontId, cap)
        local ct = tonumber(cap.capturedTime) or 0
        for _, z in ipairs(fronts:GetFront(frontId).zones) do
            if z.id ~= cap.id and z.owner == cap.owner and z.capturedTime == ct - 1 then return true end
        end
        return false
    end }
    local front = fronts:GetFront("durotar")
    local saved = {}
    for i, z in ipairs(front.zones) do saved[i] = { z.owner, z.capturedTime } end
    local E = serverNow - 40
    OverlordDB.frontTruceResetEpoch.durotar = nil
    for _, z in ipairs(front.zones) do z.owner, z.capturedTime = "Horde", E end
    local keep = select(1, fronts:GetZone(front.allianceCapitalId, "durotar"))
    assert(keep, "fixture: Durotar has no Alliance capital")
    keep.capturedTime = E + 1
    assert(FA:GetRecentCaptureCount("durotar") == 0,
        "a truce end read from the map counted as captures: " .. FA:GetRecentCaptureCount("durotar"))
    -- The fallen capital being retaken (in progress, stable base = the kept stamp): the
    -- truce end is still read from the map, and the capture in progress is not a capture.
    Overlord.Zones.GetStableZoneView = function(_, z)
        if z.status ~= "in_progress" then return z end
        return z._base
    end
    keep._base = { owner = keep.owner, status = "captured", capturedTime = keep.capturedTime }
    keep.status, keep.owner = "in_progress", "Alliance"
    assert(FA:GetRecentCaptureCount("durotar") == 0,
        "a capital being retaken hid the truce end: " .. FA:GetRecentCaptureCount("durotar"))
    keep.status, keep.owner, keep._base = "captured", "Horde", nil
    -- A real capture after the truce end still counts.
    local other = front.zones[1] ~= keep and front.zones[1] or front.zones[2]
    other.capturedTime = serverNow - 5
    assert(FA:GetRecentCaptureCount("durotar") == 1, "a capture after the truce end was hidden")
    for i, z in ipairs(front.zones) do z.owner, z.capturedTime = saved[i][1], saved[i][2] end
    Overlord.Zones = savedZones
end

-- Relay off: a capture still lights the row (local view, as before 1.7.0).
Overlord.BetaNetwork.IsEnabled = function() return false end
assert(row("durotar").active and row("durotar").captures == 6, "relay off: capture row missing")
print("Front activity captures: shared map count, release/campaign stamps ignored, kills first, expiry OK")
