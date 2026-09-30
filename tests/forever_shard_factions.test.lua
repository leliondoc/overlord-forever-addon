-- Layer colors must reflect the current character, not stale score metadata or
-- the faction of a relay. Exercise real identity resolution and UI color helpers.
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
Overlord.Leaderboard = {
    -- Deliberately inverted persisted metadata; the layer UI must never read it.
    playerInfo = { ['Red Tester'] = { faction = 'Alliance' }, ['Blue Tester'] = { faction = 'Horde' } },
    GetExportPlayerMeta = function() error('Layer color consulted historical ranking metadata') end,
}
local function upvalue(fn, name)
    for i = 1, 80 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then return value end
    end
    error('Missing UI fixture binding: ' .. name)
end
local resolve = upvalue(Overlord.UI.CreateMainFrame, 'GetShardPlayerFaction')
local color = upvalue(Overlord.UI.CreateMainFrame, 'GetShardPlayerNameColorEscape')
local function check(name, expected, prefix)
    assert(resolve(name) == expected, 'Wrong faction for ' .. name)
    assert(color(resolve(name)) == prefix, 'Wrong tooltip color for ' .. name)
end
check('Red Tester', 'Horde', '|cffff6645')
check('Blue Tester', 'Alliance', '|cff6db3f2')
check('Bridge Tester', 'Horde', '|cffff6645')
check('Blue Friend', 'Alliance', '|cff6db3f2')
check('Unknown Tester', nil, '|cffb8b8b8')
check('Retail Tester', nil, '|cffb8b8b8')
check('Blue Stranger', nil, '|cffb8b8b8')
check('Blue', nil, '|cffb8b8b8')
-- A relayed Horde origin is not the Alliance character who forwarded it.
Overlord.BetaNetwork = { context = { origin = 'Remote Tester', gateway = 'Blue Friend', hops = 2 } }
check('Remote Tester', nil, '|cffb8b8b8')
local reads, scans = unitReads, friendScans
for _ = 1, 100 do resolve('Unknown Tester'); resolve('Red Tester') end
assert(unitReads == reads and friendScans == scans, 'Faction lookup rescanned units/friends per row')

-- A live faction change beats old score data, in both directions.
units.nameplate1.faction, units.nameplate2.faction = 'Alliance', 'Horde'
now = now + 4
check('Red Tester', 'Alliance', '|cff6db3f2')
check('Blue Tester', 'Horde', '|cffff6645')
units.nameplate1, units.nameplate2 = nil, nil
now = now + 4
check('Red Tester', nil, '|cffb8b8b8')
check('Blue Tester', nil, '|cffb8b8b8')

-- Battle.net's existing cache refreshes off the receive/render path. Once it
-- refreshes, a logout or a switch of character must remove the previous faction.
friends[1].isOnline = false
friends[2].characterName, friends[2].factionName = 'New Friend', 'Horde'
now = now + 46
resolve('Unknown Tester')
drain()
check('Bridge Tester', nil, '|cffb8b8b8')
check('Blue Friend', nil, '|cffb8b8b8')
check('New Friend', 'Horde', '|cffff6645')
Overlord.InstanceSuspended = true
reads, scans = unitReads, friendScans
check('New Friend', nil, '|cffb8b8b8')
assert(unitReads == reads and friendScans == scans, 'Suspended UI queried live units')
print('Layer factions: live Alliance/Horde, stale metadata, unknown grey, relays, identity, faction changes, and bounded cache reads OK')
