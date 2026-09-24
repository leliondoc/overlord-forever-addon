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

-- Exercise the actual login barrier which prevented the main panel from opening.
sync = session("Tro", "Tro Ma")
local timers = {}
C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
function wipe(t) for key in pairs(t) do t[key] = nil end return t end
function GetServerTime() return 1790272800 end
Overlord.GetCurrentSavedVarsPool = function() return "global" end
OverlordDB = {}
assert(loadfile("ManualBounty.lua"))()
assert(Overlord.ManualBounty:Initialize() == "waiting")
local slices = 0
while not Overlord.ManualBounty._initialized do
    local callback = assert(table.remove(timers, 1), "Identity wait did not start the login worker")
    callback()
    slices = slices + 1
    assert(slices < 20, "ManualBounty login did not finish")
end
assert(Overlord.ManualBounty:Initialize() == true, "Login barrier still blocks UI initialization")
print("Forever player identity: complete API fallback, strict validation, delayed name and cache OK")
