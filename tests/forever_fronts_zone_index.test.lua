-- Perf audit 2026-10-01: Fronts:GetZone(zoneId) without a front allocated a list of
-- fronts and scanned ~70 zones per call (hundreds of calls per full-map ZA). It now
-- reads a cached index. It must give exactly the former answer for every zone and
-- rebuild when a front's zone list changes.
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
C_Map = { GetMapInfo = function() return nil end }
assert(loadfile("Fronts.lua"))()
local Fronts = Overlord.Fronts

local function scan(zoneId)
    for _, frontId in ipairs(Fronts.Order) do
        local front = Fronts.Registry[frontId]
        for _, zone in ipairs((front and front.zones) or {}) do
            if zone.id == zoneId then return zone, front end
        end
    end
end

local checked = 0
for _, frontId in ipairs(Fronts.Order) do
    for _, zone in ipairs(Fronts.Registry[frontId].zones or {}) do
        local expectZone, expectFront = scan(zone.id)
        local gotZone, gotFront = Fronts:GetZone(zone.id)
        assert(gotZone == expectZone and gotFront == expectFront, "Index differs for " .. tostring(zone.id))
        checked = checked + 1
    end
end
assert(checked > 20, "Fixture: too few zones checked")
assert(Fronts:GetZone("no_such_zone") == nil)
assert(Fronts:GetZone(nil) == nil)

-- The index is reused between calls (no rebuild, no allocation)...
local index = Fronts:_ZoneIndex()
assert(Fronts:_ZoneIndex() == index, "Index rebuilt without any change")
-- ...and rebuilt when a front's list grows.
local front = Fronts.Registry[Fronts.Order[1]]
table.insert(front.zones, { id = "test_added_zone" })
local added, owner = Fronts:GetZone("test_added_zone")
assert(added and owner == front, "Index missed a zone added at runtime")
table.remove(front.zones)
assert(Fronts:GetZone("test_added_zone") == nil, "Index kept a removed zone")
print("Fronts zone index: same answers as the scan for " .. checked .. " zones, rebuilt on list change")
