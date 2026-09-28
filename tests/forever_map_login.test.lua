-- Real seven-front login with empty SavedVariables, as on Forever beta.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync = Overlord.Sync
local epoch = Overlord:GetCurrentCampaignStartTs()
OverlordDB.zones = {}
OverlordDB.frontVictories = {}
OverlordDB.frontTruceResetEpoch = {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()

local zones = {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zones[#zones + 1] = zone end
end
local function assertGlobalMap()
    local pages, count = sync:BuildZoneAllSnapshotPages(zones, "G")
    assert(count > 0 and pages[1]:match("^@[GQ]%-"), "Login did not produce a complete map")
    local capitals = 0
    for _, page in ipairs(pages) do
        for entry in page:match("|(.*)$"):gmatch("[^,]+") do
            local id, owner, ts, ct = strsplit(":", entry)
            local fixed = Overlord.Zones:GetBaseZoneFixedOwner(id)
            if fixed then
                capitals = capitals + 1
                assert(owner ~= "N", "Global map rejected: uninitialized capital " .. id)
                assert(tonumber(ts) > 0 and tonumber(ct) > 0, "Unstamped capital " .. id)
            end
        end
    end
    assert(capitals == 14, "Global snapshot omitted a front's capitals")
    return pages
end
assertGlobalMap()

-- A veteran has taken Elwynn's branches and is attacking Blackrock Advance.
-- The map carries the Horde base under that timer, plus the captured branches.
local elwynn = Overlord.Fronts:GetFront("elwynn")
for _, zone in ipairs(elwynn.zones) do
    zone._loginSyncUnconfirmed = nil
    if zone.id ~= elwynn.hordeCapitalId then
        zone.owner, zone.status = "Alliance", "captured"
        zone.updatedAt, zone.capturedTime = epoch + 100, epoch + 100
    else
        zone._localCaptureBase = { owner = "Horde", status = "locked",
            updatedAt = epoch, capturedTime = epoch }
        zone.owner, zone.status = "Alliance", "in_progress"
    end
end
local pages = assertGlobalMap()

-- Fresh receiver; deliver every page through the real atomic ZA handler.
for _, zone in ipairs(zones) do
    zone.owner, zone.capturedTime, zone.updatedAt = nil, nil, nil
    zone.status, zone._localCaptureBase = "locked", nil
end
OverlordDB.zones = {}
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
local complete = false
Overlord.MarkCaptureSyncReceived = function(_, full) complete = complete or full == true end
for _, page in ipairs(pages) do sync:OnReceiveZoneAll(page, "Veteran Tester") end
assert(complete, "Receiver rejected the global map")
for _, zone in ipairs(elwynn.zones) do
    local expected = zone.id == elwynn.hordeCapitalId and "Horde" or "Alliance"
    assert(zone.owner == expected, "Late joiner missed " .. zone.id)
    assert(not zone._loginSyncUnconfirmed, "Zone still waiting for map sync: " .. zone.id)
end

-- Older saves may already contain the uninitialized capital. Repair the missing
-- baseline at the campaign/reset epoch, never at this character's login time.
local ash = Overlord.Fronts:GetFront("ashenvale")
local capital = Overlord.Fronts:GetZone(ash.allianceCapitalId)
OverlordDB.zones = { [capital.id] = { status = "locked", updatedAt = 0 } }
OverlordDB.frontTruceResetEpoch.ashenvale = epoch + 50
Overlord:RestoreZoneState()
assert(capital.owner == "Alliance" and capital.capturedTime == epoch + 50,
    "Saved empty capital was not restored at its front's reset epoch")

-- Default initialization must never claim a captured capital back or end an
-- observed assault, even if the latter temporarily has no owner.
capital.owner, capital.status = "Horde", "captured"
capital.capturedTime, capital.updatedAt = epoch + 200, epoch + 200
Overlord.Zones:InitializeMissingCapitalDefaults()
assert(capital.owner == "Horde" and capital.capturedTime == epoch + 200,
    "Default initialization erased a real capital capture")
capital.owner, capital.status, capital.capturedTime = nil, "in_progress", nil
Overlord.Zones:InitializeMissingCapitalDefaults()
assert(capital.status == "in_progress" and capital.owner == nil,
    "Default initialization ended a capture in progress")
print("Forever map login: seven-front defaults and full Elwynn catch-up during capital assault OK")
