-- The local identity must use a complete API name, even when UnitName only
-- supplies the given name. Never infer a surname from a realm or saved data.
local unitName, displayName
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function() end }
end
local function session(unit, display)
    unitName, displayName = unit, display
    Overlord = {
        L = {},
        SafeUnitName = function() return unitName end,
        SafeGetUnitName = function() return displayName end,
    }
    assert(loadfile("Sync.lua"))()
    return Overlord.Sync
end

local sync = session("Tro", "Tro Ma")
assert(sync:GetPlayerFullName() == "Tro Ma", "Short UnitName blocked the local identity")
assert(sync:HasCompleteContributorIdentity(sync:GetPlayerFullName()))

sync = session("Tro Ma", "Tro")
assert(sync:GetPlayerFullName() == "Tro Ma", "Incomplete display name masked complete UnitName")
assert(sync:CanonicalForeverNameFromUnit("target") == "Tro Ma")

sync = session("Tro", "Tro-Realm")
assert(sync:GetPlayerFullName() == "", "A realm was mistaken for a surname")
displayName = "Tro Ma-Realm"
assert(sync:GetPlayerFullName() == "Tro Ma", "An incomplete login name was cached permanently")
unitName, displayName = nil, nil
assert(sync:GetPlayerFullName() == "Tro Ma", "Validated local identity was lost during a transition")

sync = session(nil, nil)
assert(sync:GetPlayerFullName() == "", "Unavailable identity was invented")
unitName = "Tro Ma"
assert(sync:GetPlayerFullName() == "Tro Ma")
assert(not sync:HasCompleteContributorIdentity("Tro"))

print("Forever player identity: complete API fallback, strict validation, delayed name and cache OK")
