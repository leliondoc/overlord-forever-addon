-- Live: a call to arms for Redridge, received while another front was shown,
-- printed the raw id "redridge_three_corners". The zone name is now looked up in
-- every front, then the translated names; a raw id is never printed.
assert(loadfile("tests/forever_map_login.test.lua"))()
local sync = Overlord.Sync
Overlord.Fronts:Activate("elwynn")
local zoneName, frontName = sync:ResolveFactionCallPlace("redridge_three_corners", "redridge")
local expected = Overlord.Fronts:GetZone("redridge_three_corners")
assert(expected, "fixture: Redridge zone missing")
assert(zoneName == (expected.name or "Three Corners") and zoneName ~= "redridge_three_corners",
    "Raw zone id shown: " .. tostring(zoneName))
assert(frontName ~= "" and frontName ~= "redridge", "Raw front id shown: " .. tostring(frontName))
-- Unknown id (newer client, renamed zone): readable words, never underscores.
local unknown = sync:ResolveFactionCallPlace("redridge_old_watch_tower", "")
assert(unknown == "Old Watch Tower", "Unknown id not made readable: " .. tostring(unknown))
print("Call to arms: zone and front names, never raw ids")
