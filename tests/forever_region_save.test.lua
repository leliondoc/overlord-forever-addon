-- 2.1.0: the account's save is shared by every region it plays in; each region keeps its own,
-- whole. A player on two regions never carries one campaign's map and ranking into the other.
local now = 1793833200 + 60
local regionName = "EU"
function time() return now end
function GetServerTime() return now end
function GetTime() return now end
function date(fmt, ts) return os.date(fmt, ts or now) end
function GetCurrentRegion() return 93 end
function GetCurrentRegionName() return regionName end
function GetLocale() return "frFR" end
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end
C_Timer = { After = function() end }
Overlord = { L = {} }
assert(loadfile("Core.lua"))()

-- Most of the players: one region. The save is untouched, whatever it holds.
local eu = { saveRegion = "EU", zones = { z = { owner = "Horde" } }, leaderboard = { kills = { Eu = 5 } } }
OverlordDB = eu
assert(Overlord:SwapRegionSave() == nil and OverlordDB == eu, "same region: the save moved")
local beta = { zones = { b = 1 } } -- a save of 2.0.8 or of the beta: no region noted yet
OverlordDB = beta
assert(Overlord:SwapRegionSave() == nil and OverlordDB == beta, "first 2.1 login: the save moved")
OverlordDB = nil
assert(Overlord:SwapRegionSave() == nil and OverlordDB == nil, "new install")
assert(Overlord._saveRegionName == "EU", "the region to note at login")

-- No name from the client: nothing is decided, the save stays.
for _, name in ipairs({ "", false }) do
    regionName = name or nil
    Overlord._saveRegionName = nil
    OverlordDB = eu
    assert(Overlord:SwapRegionSave() == nil and OverlordDB == eu, "no region name: the save moved")
    assert(Overlord._saveRegionName == nil, "no region name: a region was noted")
end

-- To another region for the first time: starts like a new install, nothing comes along.
regionName = "US"
OverlordDB = eu
local parked = Overlord:SwapRegionSave()
assert(OverlordDB == nil, "the European save followed the player to the Americas")
assert(parked and parked.EU == eu and eu.zones.z.owner == "Horde", "the European save was lost")
assert(eu.otherRegionSaves == nil, "a parked save holds the others")

-- What Initialize does after the new-install block.
OverlordDB = { zones = {}, leaderboard = { kills = { Us = 7 } } }
local us = OverlordDB
OverlordDB.otherRegionSaves = parked
OverlordDB.saveRegion = Overlord._saveRegionName
assert(us.saveRegion == "US")

-- A retry of Initialize in the same session changes nothing.
assert(Overlord:SwapRegionSave() == nil and OverlordDB == us, "second call in the session")

-- Back to Europe: its own save, exact; the American one kept aside.
regionName = "EU"
parked = Overlord:SwapRegionSave()
assert(OverlordDB == eu and eu.zones.z.owner == "Horde" and eu.leaderboard.kills.Eu == 5, "European save not restored")
assert(parked.EU == nil and parked.US == us and us.otherRegionSaves == nil, "saves mixed on the way back")
assert(us.leaderboard.kills.Us == 7 and eu.leaderboard.kills.Us == nil, "two regions' rankings mixed")
OverlordDB.otherRegionSaves = parked

-- A third region: both others kept.
regionName = "KR"
parked = Overlord:SwapRegionSave()
assert(OverlordDB == nil and parked.EU == eu and parked.US == us, "a third region lost a save")

-- Through the real login: Initialize runs up to the modules this test does not load.
local function login(name)
    regionName = name
    Overlord.IsInitialized, Overlord.SavedVariablesLoadedAtLogin = false, nil
    Overlord._saveRegionName = nil
    pcall(Overlord.Initialize, Overlord)
end
eu = { saveRegion = "EU", lastResetTimestamp = 1793764800, zones = { z = { owner = "Horde" } },
    leaderboard = { kills = { Eu = 5 } }, config = {} }
OverlordDB = eu
login("EU")
assert(OverlordDB == eu and eu.zones.z.owner == "Horde" and eu.otherRegionSaves == nil, "one region: the save changed")
assert(Overlord.SavedVariablesLoadedAtLogin == true, "one region: the save was reported lost")
login("US")
us = OverlordDB
assert(us ~= eu and us.saveRegion == "US" and us.otherRegionSaves.EU == eu, "first login in a second region")
assert(us.zones.z == nil and us.leaderboard.kills.Eu == nil, "the European campaign came along")
assert(us.lastResetTimestamp == 1793718000, "a new region's save is anchored on its own week: " .. tostring(us.lastResetTimestamp))
assert(Overlord.SavedVariablesLoadedAtLogin == false, "a new region must behave like a new install")
pcall(Overlord.Initialize, Overlord)
assert(OverlordDB == us and us.otherRegionSaves.EU == eu, "a retry of Initialize moved the save")
us.leaderboard.kills.Us = 7
login("EU")
assert(OverlordDB == eu and eu.saveRegion == "EU" and eu.otherRegionSaves.US == us and us.otherRegionSaves == nil,
    "back in Europe: its own save, the other kept")
assert(eu.zones.z.owner == "Horde" and eu.leaderboard.kills.Eu == 5 and eu.leaderboard.kills.Us == nil,
    "back in Europe: the two campaigns mixed")
assert(Overlord.SavedVariablesLoadedAtLogin == true, "back in Europe: the save was reported lost")
login("")
assert(OverlordDB == eu and eu.saveRegion == "EU", "no region name: the save and its region stay")

-- The wiring: before the save is read, and before the new-install block.
local source = assert(io.open("Core.lua", "rb")):read("*a")
local init = source:find("function Overlord:Initialize()", 1, true)
local swap = source:find("local otherRegionSaves = self:SwapRegionSave()", init, true)
local evidence = source:find("self.SavedVariablesLoadedAtLogin == nil", init, true)
local block = source:find("if not OverlordDB then", init, true)
local attach = source:find("if otherRegionSaves then OverlordDB.otherRegionSaves = otherRegionSaves end", init, true)
local note = source:find("if self._saveRegionName then OverlordDB.saveRegion = self._saveRegionName end", init, true)
assert(swap and evidence and block and attach and note and swap < evidence and evidence < block
    and block < attach and attach < note, "Initialize no longer swaps the region's save first")

print("Region saves: one region untouched, two regions apart, no name left alone OK")
