-- Audit 2026-10-15 (Hillsbrad redrawn): an enemy capture whose prerequisites our map
-- never meets (a client with the old two-point Hillsbrad takes Tarren Mill) asked
-- the channel and whispered the capturer every 20 s for the whole 8-minute siege.
-- Now three rounds per siege wave (at 0, 20 and 60 s), the capturer whispered once; a
-- new wave asks again.
local now = 1000
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return 'enUS' end
function IsInGroup() return false end
function IsInRaid() return false end
function UnitName() return 'Local Tester' end
GetUnitName = UnitName
function UnitFactionGroup() return 'Alliance' end
function UnitClass() return 'Warrior', 'WARRIOR' end
function UnitRace() return 'Human', 'Human' end
function UnitSex() return 2 end
function UnitLevel() return 60 end
function GetGuildInfo() return nil end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
local methods = {}
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') or key:match('^Register') or key == 'Hide' then return function() end end
end })
function CreateFrame() return setmetatable({}, { __index = methods }) end
C_Timer = { After = function() end, NewTicker = function() return {} end }
WOW_PROJECT_ID = 1
Overlord = { L = {} }
assert(loadfile('Core.lua'))()
Overlord.PlayerFaction = 'Alliance'
assert(loadfile('Sync.lua'))()
assert(loadfile('SyncAux.lua'))()

local sync = Overlord.Sync
local whispers, requests = 0, 0
Overlord.ServerNow = function() return time() end
Overlord.InstanceSuspended = false
Overlord.Zones = { FactionMeetsPrereqsForZoneCapture = function() return false end }
sync.GetSRPayload = function() return 'payload' end
sync.IsValidWhisperTarget = function() return true end
local whisperRefused = false
sync.SendWhisper = function()
    if whisperRefused then return false end
    whispers = whispers + 1
    return true
end
sync.SendSyncRequest = function() requests = requests + 1 end

local zone = { id = 'hillsbrad_tarren_mill', status = 'in_progress', owner = 'Horde' }
local function siege(lease, seconds)
    zone._remoteCaptureLease = lease
    for _ = 1, seconds do
        now = now + 1
        zone.updatedAt = time() - 2 -- the capturer keeps the siege alive
        sync:RequestPrereqMismatchCatchup(zone)
    end
end

-- One 8-minute siege wave: three rounds, spread at 0, 20 and 60 s, one whisper to the
-- capturer.
local first = { originName = 'Old Capturer', directValidated = true }
siege(first, 45)
assert(requests == 2, 'rounds in the first 45 s (third one due at 60 s): ' .. requests)
siege(first, 435)
assert(requests == 3, 'rounds in one siege wave: ' .. requests)
assert(whispers == 1, 'whispers to the capturer in one wave: ' .. whispers)

-- A new wave (a new lease) is a new question.
siege({ originName = 'Old Capturer', directValidated = true }, 480)
assert(requests == 6 and whispers == 2, 'a new wave did not ask again: ' .. requests .. '/' .. whispers)

-- Without a lease: the capturing faction is the wave, forgotten after a quiet minute and a half.
siege(nil, 480)
assert(requests == 9 and whispers == 2, 'leaseless rounds: ' .. requests .. '/' .. whispers)
siege(nil, 300)
assert(requests == 9, 'leaseless siege kept asking: ' .. requests)
now = now + 700
siege(nil, 30)
assert(requests == 11, 'a later leaseless siege did not ask again (two rounds in 30 s): ' .. requests)

-- A terminal change of the zone (the siege ends, a reset) starts a new wave at once,
-- even for the same faction within the minute and a half.
siege(nil, 120)
assert(requests == 12, 'the leaseless wave did not end at its third round: ' .. requests)
do
    local stub = Overlord.Zones
    Overlord.L.ZONE_NAMES = Overlord.L.ZONE_NAMES or {}
    assert(loadfile('Fronts.lua'))()
    assert(loadfile('Zones.lua'))()
    Overlord.Zones:ClearCaptureFinalUnattestedState(zone)
    Overlord.Zones = stub
end
assert(zone._prereqMismatchRounds == nil and zone._prereqMismatchOwner == nil, 'the zone reset kept the wave')
siege(nil, 30)
assert(requests == 14, 'a siege after the zone reset did not ask again: ' .. requests)

-- The capturer is whispered once per wave, on the first round where it is known first
-- hand, even if that is not the first round.
do
    local lease = { originName = 'Late Capturer', directValidated = false }
    now = now + 700
    siege(lease, 15) -- first round, the capturer not validated yet: no whisper
    assert(requests == 15 and whispers == 2, 'first round: ' .. requests .. '/' .. whispers)
    lease.directValidated = true
    siege(lease, 480)
    assert(requests == 17 and whispers == 3, 'the capturer validated later was not whispered once: '
        .. requests .. '/' .. whispers)
end

-- A whisper the route refused is tried again at the next round of the same wave.
do
    now = now + 700
    local lease = { originName = 'Busy Capturer', directValidated = true }
    whisperRefused = true
    siege(lease, 15)
    whisperRefused = false
    local before = whispers
    siege(lease, 480)
    assert(whispers == before + 1, 'a refused whisper was not tried again once: ' .. (whispers - before))
end

-- A capturer outside the map exchange (an older release) is not whispered: its whole
-- map would be refused. The channel is still asked.
do
    now = now + 700
    local relay = Overlord.Relay
    Overlord.Relay = { IsOutdatedMapPeer = function() return true end }
    local beforeRequests, beforeWhispers = requests, whispers
    siege({ originName = 'Old Release', directValidated = true }, 15)
    Overlord.Relay = relay
    assert(requests == beforeRequests + 1 and whispers == beforeWhispers,
        'a capturer outside the map exchange was whispered: ' .. (whispers - beforeWhispers))
end

-- Other zones polled first (a spent wave, a healthy siege whose chain our map meets) do
-- not keep a mismatched zone from asking at its first chance.
do
    local meets = Overlord.Zones.FactionMeetsPrereqsForZoneCapture
    Overlord.Zones.FactionMeetsPrereqsForZoneCapture = function(_, id) return id == 'hillsbrad_durnholde' end
    local spent = { id = 'hillsbrad_bridge', status = 'in_progress', owner = 'Horde',
        _remoteCaptureLease = { originName = 'Spent', _prereqMismatchRounds = 3 } }
    local healthy = { id = 'hillsbrad_durnholde', status = 'in_progress', owner = 'Horde',
        _remoteCaptureLease = { originName = 'Fair' } }
    local fresh = { id = 'hillsbrad_fields', status = 'in_progress', owner = 'Horde',
        _remoteCaptureLease = { originName = 'Fresh' } }
    now = now + 30
    local before = requests
    for _ = 1, 3 do
        now = now + 2.5
        spent.updatedAt, healthy.updatedAt, fresh.updatedAt = time() - 2, time() - 2, time() - 2
        sync:RequestPrereqMismatchCatchup(spent)
        sync:RequestPrereqMismatchCatchup(healthy)
    end
    sync:RequestPrereqMismatchCatchup(fresh)
    assert(requests == before + 1, 'zones polled first kept a mismatched zone from asking: ' .. (requests - before))
    Overlord.Zones.FactionMeetsPrereqsForZoneCapture = meets
end

-- Login (or instance exit) quarantine: our own chain is not confirmed yet, no round is
-- spent; the wave asks once it lifts.
do
    now = now + 30
    local before = requests
    Overlord.WaitingForSync = true
    siege({ originName = 'Login Capturer' }, 40)
    assert(requests == before, 'a round was spent during the login quarantine')
    Overlord.WaitingForSync = nil
    zone._remoteCaptureLease.originName = 'Login Capturer'
    siege(zone._remoteCaptureLease, 10)
    assert(requests == before + 1, 'the wave did not ask once the quarantine lifted: ' .. (requests - before))
end

-- Nothing for our own faction's captures, nor when our map meets the chain.
zone.owner = 'Alliance'
siege({ originName = 'Ally' }, 60)
assert(requests == 23, 'asked for an allied capture')
zone.owner = 'Horde'
Overlord.Zones.FactionMeetsPrereqsForZoneCapture = function() return true end
siege({ originName = 'Fair Capturer' }, 60)
assert(requests == 23, 'asked although our map meets the chain')
print('Prerequisite mismatch catch-up: three rounds per siege wave, capturer whispered once OK')
