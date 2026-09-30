-- 1.3.1: a total victory shows a raid warning, not the old full-screen frame
-- (it got in the way of players still fighting on the front). The victory
-- music plays when the client has it, otherwise the raid warning sound.
local now = 100
local callbacks = {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return 'enUS' end
function IsInGroup() return false end
function IsInRaid() return false end
function UnitExists() return false end
function UnitName() return 'Local Tester' end
function UnitFactionGroup() return 'Alliance' end
function GetGuildInfo() return nil end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
local methods = {}
setmetatable(methods, { __index = function() return function() end end })
local framesCreated = 0
function CreateFrame() framesCreated = framesCreated + 1; return setmetatable({}, { __index = methods }) end
C_Timer = { After = function(_, fn) callbacks[#callbacks + 1] = fn end,
    NewTicker = function() return {} end, NewTimer = function() return {} end }
Overlord = { L = {} }
assert(loadfile('Core.lua'))()
assert(loadfile('Locales.lua'))()
Overlord.PlayerFaction = 'Alliance'
assert(loadfile('Sync.lua'))()
assert(loadfile('SyncAux.lua'))()
assert(loadfile('UI.lua'))()
local L = Overlord.L
OverlordDB = { config = { soundEnabled = true } }
Overlord.Fronts = { GetCurrentFront = function() return nil end }

local notices, sounds = {}, {}
RaidWarningFrame = {}
function RaidNotice_AddMessage(frame, text, color)
    notices[#notices + 1] = { frame = frame, text = text, color = color }
end
local victoryMusicAvailable = false
SOUNDKIT = { UI_WARFRONTS_BATTLE_COMPLETE = 175409, RAID_WARNING = 8959 }
function PlaySound(id)
    sounds[#sounds + 1] = id
    if id == 175409 then return victoryMusicAvailable end
    return true
end

local before = framesCreated
Overlord.UI:ShowVictoryScreen(L.VICTORY_FACTION_HORDE)
assert(#notices == 1 and notices[1].frame == RaidWarningFrame, 'Total victory did not raise a raid warning')
assert(notices[1].text == 'TOTAL VICTORY FOR THE HORDE!', 'Unexpected raid warning text: ' .. tostring(notices[1].text))
assert(notices[1].color.r > notices[1].color.b, 'Horde victory is not shown in Horde red')
assert(framesCreated == before, 'A victory frame was still created')
assert(sounds[1] == 175409 and sounds[2] == 8959, 'Missing victory music fell back to no sound')

-- The same victory delivered again (TV, SR replay) does not repeat the alert.
Overlord.UI:ShowVictoryScreen(L.VICTORY_FACTION_HORDE)
assert(#notices == 1, 'The same victory raised a second alert')

-- Later, an Alliance victory: blue, and the victory music alone when available.
now = now + 60
sounds = {}
victoryMusicAvailable = true
Overlord.UI:ShowVictoryScreen(L.VICTORY_FACTION_ALLIANCE)
assert(#notices == 2 and notices[2].text == 'TOTAL VICTORY FOR THE ALLIANCE!')
assert(notices[2].color.b > notices[2].color.r, 'Alliance victory is not shown in Alliance blue')
assert(#sounds == 1 and sounds[1] == 175409, 'The raid warning sound played over the victory music')

-- Sound option off: the alert stays silent.
now = now + 60
sounds = {}
OverlordDB.config.soundEnabled = false
Overlord.UI:ShowVictoryScreen(L.VICTORY_FACTION_HORDE)
assert(#notices == 3 and #sounds == 0, 'Victory alert played a sound with sounds disabled')
print('Victory raid alert: raid warning in faction color, no frame, one alert per victory, music or raid sound, silent when disabled OK')
