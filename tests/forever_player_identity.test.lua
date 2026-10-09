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

-- "Is this message mine?" is memoized per sender string (asked for every addon
-- message): same answers, and a change of our own name drops the memo.
Overlord.SafeStringEquals = Overlord.SafeStringEquals or function(_, a, b) return a ~= nil and a == b end
Overlord.SafeUnitName = Overlord.SafeUnitName or function() return "Tro" end
assert(sync:IsSenderLocalPlayer("Tro Ma"), "Own name not recognised")
assert(sync:IsSenderLocalPlayer("Tro Ma"), "Own name not recognised from the memo")
assert(not sync:IsSenderLocalPlayer("Other Player"), "A foreign sender was taken for us")
assert(not sync:IsSenderLocalPlayer("Other Player"), "Memo turned a foreign sender into us")
local realFull = sync.GetPlayerFullName
sync.GetPlayerFullName = function() return "Other Player" end
assert(sync:IsSenderLocalPlayer("Other Player"), "Memo kept the previous identity after a name change")
sync.GetPlayerFullName = realFull

print("Forever player identity: complete API fallback, strict validation, delayed name and cache OK")
