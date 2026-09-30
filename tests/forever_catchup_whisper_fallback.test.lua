-- Audit 2026-09-30: a targeted map request (SR) to a capturer heard only through
-- relays was refused by the point-to-point rule, with no other route, so an
-- observer could keep an orange zone for minutes. Catch-up to a non-direct peer
-- now goes as a plain addon whisper (same faction), never through relays.
local now = 100
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return 'enUS' end
function IsInGroup() return false end
function IsInRaid() return false end
function IsInInstance() return false end
function UnitExists() return false end
function UnitName() return 'Local Tester' end
function UnitFactionGroup() return 'Alliance' end
function GetGuildInfo() return nil end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
local methods = {}
setmetatable(methods, { __index = function() return function() end end })
function CreateFrame() return setmetatable({}, { __index = methods }) end
C_Timer = { After = function() end, NewTicker = function() return {} end, NewTimer = function() return {} end }
Overlord = { L = {} }
assert(loadfile('Core.lua'))()
Overlord.PlayerFaction = 'Alliance'
assert(loadfile('Sync.lua'))()
local sync = Overlord.Sync
local relayed, whispered = {}, {}
Overlord.BetaNetworkEnabled = true
Overlord.BetaNetwork = {
    IsPeer = function() return true end,
    IsDirectPeer = function(_, name) return name == 'Near Tester' end,
    IsPointToPointCatchupKind = function(_, kind) return kind == 'SR' or kind == 'ZA' end,
    Send = function(_, kind, _, target) relayed[#relayed + 1] = kind .. '>' .. target; return true end,
}
function sync:IsValidWhisperTarget() return true end
function sync:SendAddonChecked(msg, channel, target)
    whispered[#whispered + 1] = channel .. '>' .. target .. '>' .. msg:sub(1, 2)
    return true
end
local factions = { ['Red Tester'] = 'Horde' }
function sync:GetLivePlayerFaction(name) return factions[name] end

assert(sync:SendWhisper('SR', 'x', 'Near Tester') == true)
assert(relayed[1] == 'SR>Near Tester' and #whispered == 0, 'A direct neighbour did not get the relay route')
assert(sync:SendWhisper('SR', 'x', 'Far Tester') == true, 'A far capturer got no request')
assert(#relayed == 1 and whispered[1] == 'WHISPER>Far Tester>SR', 'The far request did not go as a plain whisper')
assert(sync:SendWhisper('ZA', 'page', 'Far Tester') == true)
assert(whispered[2] == 'WHISPER>Far Tester>ZA', 'The map reply did not follow the same plain route')
assert(sync:SendWhisper('SR', 'x', 'Red Tester') == false, 'An enemy-faction far peer was whispered')
assert(#whispered == 2)
-- Live traffic keeps the relay route to far peers.
assert(sync:SendWhisper('K', 'x', 'Far Tester') == true and relayed[2] == 'K>Far Tester')
print('Catch-up whisper fallback: direct via relay, far same-faction via plain whisper, enemy refused, live unchanged')
