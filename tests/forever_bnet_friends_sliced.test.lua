-- Perf audit 2026-10-01: the Battle.net friend list (150-300 friends) was rebuilt in
-- one frame every 90 s. It is now rebuilt 25 friends per frame while the old list is
-- still served, then swapped in whole.
local now, unitReads, friendScans = 100, 0, 0
local callbacks = {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return 'enUS' end
function IsInGroup() return false end
function IsInRaid() return false end
local units = {
    player = { name = 'Local Tester', faction = 'Alliance' },
    nameplate1 = { name = 'Red Tester', faction = 'Horde' },
    nameplate2 = { name = 'Blue Tester', faction = 'Alliance' },
}
function UnitExists(unit) unitReads = unitReads + 1; return units[unit] ~= nil end
function UnitIsPlayer(unit) return units[unit] ~= nil end
function GetUnitName(unit) return units[unit] and units[unit].name end
UnitName = GetUnitName
function UnitFactionGroup(unit) return units[unit] and units[unit].faction end
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitRace() return 'Human', 'Human' end
function UnitSex() return 2 end
function UnitLevel() return 60 end
function GetGuildInfo() return nil end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
local methods = {}
local function widget() return setmetatable({}, { __index = methods }) end
function methods:SetText(text) self.text = text end
function methods:SetTextColor(r, g, b) self.color = { r, g, b } end
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') or key:match('^Register') or key == 'Hide' then return function() end end
end })
function CreateFrame() return widget() end
C_Timer = { After = function(_, fn) callbacks[#callbacks + 1] = fn end,
    NewTicker = function() return {} end }
local function drain()
    while #callbacks > 0 do table.remove(callbacks, 1)() end
end
WOW_PROJECT_ID = 1
local friends = {
    { gameAccountID = 1, characterName = 'Bridge Tester', factionName = 'Horde',
        wowProjectID = 18, clientProgram = 'WoW', isOnline = true },
    { gameAccountID = 2, characterName = 'Blue Friend', factionName = 'Alliance',
        wowProjectID = 18, clientProgram = 'WoW', isOnline = true },
    { gameAccountID = 3, characterName = 'Retail Tester', factionName = 'Horde',
        wowProjectID = 1, clientProgram = 'WoW', isOnline = true },
}
function BNGetNumFriends() friendScans = friendScans + 1; return #friends end
C_BattleNet = {
    GetFriendNumGameAccounts = function() return 1 end,
    GetFriendGameAccountInfo = function(i) return friends[i] end,
}
Overlord = { L = {} }
assert(loadfile('Core.lua'))()
Overlord.PlayerFaction = 'Alliance'
assert(loadfile('Sync.lua'))()
assert(loadfile('SyncAux.lua'))()
assert(loadfile('UI.lua'))()
local sync = Overlord.Sync
-- 100 Forever friends, half of them Horde.
for i = #friends + 1, 100 do
    friends[i] = { gameAccountID = 100 + i, characterName = "Friend Number" .. string.char(65 + i % 26) .. string.char(65 + math.floor(i / 26)),
        factionName = (i % 2 == 0) and "Horde" or "Alliance", wowProjectID = 18, clientProgram = "WoW", isOnline = true }
end
local first = sync:GetBetaBNetTargets()
assert(#first > 0, "Fixture: no Battle.net targets")
-- Expire the cache: the stale list is served, the rebuild is queued, not run inline.
now = now + 91
local scansBefore = friendScans
local served = sync:GetBetaBNetTargets()
assert(served == first, "The stale list was not served while rebuilding")
assert(friendScans == scansBefore, "The rebuild ran inside the caller's frame")
-- Each queued callback is one frame: the rebuild must take several of them.
local frames = 0
while #callbacks > 0 and frames < 50 do
    frames = frames + 1
    table.remove(callbacks, 1)()
end
assert(frames >= 4, "Rebuild was not sliced across frames: " .. frames)
local rebuilt = sync:GetBetaBNetTargets()
assert(rebuilt ~= first and #rebuilt == #first, "The rebuilt list was not swapped in whole")
print("Battle.net friends: stale list served, rebuild sliced over " .. frames .. " frames, swapped whole")
