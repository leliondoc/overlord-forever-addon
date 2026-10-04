-- Layer Jumper x Sync: the partner of a layer jump never gets Sync group trust,
-- and a normal group member still does.
-- Loads the real Core.lua and Sync.lua like the other Sync tests.
local now = 100
local callbacks = {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return 'enUS' end
local grouped = true
function IsInGroup() return grouped end
function IsInRaid() return false end
function GetNumGroupMembers() return grouped and 2 or 0 end
function UnitIsGroupLeader() return false end
local units = {
    player = { name = 'Ann Requester', faction = 'Alliance' },
    party1 = { name = 'Bob Helper', faction = 'Alliance' },
}
function UnitExists(unit) return units[unit] ~= nil end
function UnitIsPlayer(unit) return units[unit] ~= nil end
function GetUnitName(unit) return units[unit] and units[unit].name end
UnitName = GetUnitName
function UnitFactionGroup(unit) return units[unit] and units[unit].faction end
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitRace() return 'Human', 'Human' end
function UnitSex() return 2 end
function UnitLevel() return 60 end
function GetGuildInfo() return nil end
function IsInInstance() return false end
function InCombatLockdown() return false end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
function strsplit(sep, value)
    local out, start = {}, 1
    while true do
        local i = value:find(sep, start, true)
        if not i then out[#out + 1] = value:sub(start); break end
        out[#out + 1] = value:sub(start, i - 1)
        start = i + 1
    end
    return unpack(out)
end
local methods = {}
local function widget() return setmetatable({}, { __index = methods }) end
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') or key:match('^Register') or key:match('^Unregister') or key == 'Hide' then
        return function() end
    end
end })
function CreateFrame() return widget() end
C_Timer = { After = function(_, fn) callbacks[#callbacks + 1] = fn end,
    NewTicker = function() return { Cancel = function() end } end,
    NewTimer = function() return { Cancel = function() end } end }
WOW_PROJECT_ID = 1
function BNGetNumFriends() return 0 end
C_BattleNet = { GetFriendNumGameAccounts = function() return 0 end }
Overlord = { L = {} }
assert(loadfile('Core.lua'))()
Overlord.PlayerFaction = 'Alliance'
assert(loadfile('Sync.lua'))()
assert(loadfile('LayerJumper.lua'))()
local sync, LJ = Overlord.Sync, Overlord.LayerJumper
assert(sync and sync.SenderIsInOurGroup and LJ, 'modules loaded')

-- No hop: a real group member is trusted.
assert(sync:SenderIsInOurGroup('Bob Helper'), 'normal group member trusted')
assert(not LJ:IsHopGroup(), 'a normal duo is not a hop group')

-- Requester verifying a hop with Bob: Bob is in the roster but never trusted.
LJ:MarkHopEpoch()
LJ.hop = { candidates = {}, index = 1, reqId = 'x1', originMap = 1, originLayer = 5,
    current = { name = 'Bob Helper', key = 'bob helper', layer = 9 } }
LJ.state = 'verifying'
now = now + 3 -- Sync caches the roster for 2 s
assert(LJ:IsHopGroup(), 'hop pair recognised')
assert(not sync:SenderIsInOurGroup('Bob Helper'), 'hop partner gets no group trust')

-- Sync:Send during the hop group: nothing to the stranger, nothing doubled on the channel.
local wire = {}
C_ChatInfo = C_ChatInfo or {}
C_ChatInfo.SendAddonMessage = function(prefix, msg, chatType) wire[#wire + 1] = chatType; return 0 end
assert(sync:Send('MS', 'probe') == true, 'Send reports handled during a hop')
assert(#wire == 0, 'no PARTY copy and no extra channel copy during a hop')
assert(LJ:IsNamedHopPartner('Bob Helper') and not LJ:IsNamedHopPartner('Other Player'),
    'proximity skip limited to the partner')

-- After the jump (grace over, partner mark expired) Bob is a normal member again.
LJ.hop, LJ.state = nil, 'idle'
LJ.hopGroupUntil, LJ.partners = nil, {}
now = now + 3
assert(sync:SenderIsInOurGroup('Bob Helper'), 'trust back once the jump is over')

-- Helper side: while our invited guest is in the pair, nobody in it is trusted.
LJ.guests = { ['bob helper'] = { name = 'Bob Helper', at = now, joined = true } }
now = now + 3
assert(not sync:SenderIsInOurGroup('Bob Helper'), 'helper: guest untrusted')
LJ.guests = {}

-- Solo again: nothing is a hop group.
grouped = false
assert(not LJ:IsHopGroup(), 'solo: no hop group')

print('forever_layer_jumper_sync: ok')
