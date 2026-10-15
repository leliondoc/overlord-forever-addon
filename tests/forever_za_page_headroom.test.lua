-- Tripwire (audit 2026-10-15, Hillsbrad on 10 points): a whole map answer is cut into
-- pages of Sync.ZA_SNAPSHOT_BODY_BYTES and a map of more than Sync.ZA_SNAPSHOT_MAX_PAGES
-- pages is not built at all: no client could answer a map any more, without an error.
-- The worst case (every point owned, ten-digit dates) must keep a margin, so that the
-- commit that adds fronts or points fails here, not in the field. Raising the page cap
-- is a wire change (older receivers refuse more pages).
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync = Overlord.Sync
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("hillsbrad")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RestoreZoneState()

local zones, count = {}, 0
for _, frontId in ipairs(Overlord.Fronts.Order) do
    for _, zone in ipairs(Overlord.Fronts.Registry[frontId].zones) do
        zones[#zones + 1] = zone
        count = count + 1
        -- Worst case: owned, a ten-digit date (a capture row writes it twice).
        zone.owner, zone.status = (count % 2 == 0) and "Horde" or "Alliance", "captured"
        zone.capturedTime, zone.updatedAt = 1999999999, 1999999999
        zone._loginSyncUnconfirmed = nil
    end
end
assert(count == 67, "67 points on the 7 fronts (2.0.3), found " .. count)
local pages, built = sync:BuildZoneAllSnapshotPages(zones, "G")
assert(type(pages) == "table" and #pages > 0, "no map built for the worst case")
local cap = sync.ZA_SNAPSHOT_MAX_PAGES
local margin = 4
assert(#pages <= cap - margin, ("the worst-case map takes %d pages of %d: less than %d left before no map is built at all")
    :format(#pages, cap, margin))
print(("ZA headroom: worst-case whole map of %d points = %d pages of %d"):format(count, #pages, cap))
