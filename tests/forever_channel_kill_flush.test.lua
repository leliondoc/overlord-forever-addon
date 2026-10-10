-- Our own kill total goes on the channel at most once per 30 s; within the window the
-- last one waits and leaves when the window closes (the outbound score bridges read it
-- there for the other faction). (1) A fight's last total queued under 2 s before the
-- window closed was silently skipped: the relay's 2 s broadcast memory answered "already
-- carried" although the relay had no channel copy of it. (2) A flush falling inside an
-- instance was lost; it now waits and leaves once after the exit, never inside.
math.randomseed(6)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s = Overlord.Sync
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Horde"
Overlord.InstanceSuspended = false
function s:GetChannelId() return 5 end
local inInstance = false
function IsInInstance() return inInstance end
function IsInGroup() return false end
function s:GetBetaBNetTargets() return {} end

local clock = 5000
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = timer.at
        timer.fn()
    end
    clock = stop
end
local direct = {}
function s:SendAddonChecked(msg, chatType)
    if chatType == "CHANNEL" and msg:sub(1, 2) == "K:" then direct[#direct + 1] = msg end
    return true
end
local function sent(payload)
    local n = 0
    for _, msg in ipairs(direct) do if msg == "K:" .. payload then n = n + 1 end end
    return n
end

-- (1) Window opened at 5000; the fight's last total is queued at 5029.
s._channelKillAt, s._channelKillPending, s._channelKillArmed = nil, nil, nil
assert(net:Send("K", "Horde Owner:101:WARRIOR"))
advance(29)
assert(net:Send("K", "Horde Owner:103:WARRIOR"))
assert(s._channelKillPending == "Horde Owner:103:WARRIOR", "the in-window total was not held for the window end")
advance(2)
assert(sent("Horde Owner:103:WARRIOR") == 1, "a total queued under 2 s before the window closed never reached the channel")
assert(s._channelKillAt == 5030, "the flush did not open the next window: " .. tostring(s._channelKillAt))
-- The relay's 2 s memory still stops a plain duplicate of a total it just carried.
assert(net:Send("K", "Horde Owner:104:WARRIOR"))
assert(s:SendToChannel("K", "Horde Owner:104:WARRIOR") == true and sent("Horde Owner:104:WARRIOR") == 0,
    "a direct copy of a total the relay just queued was sent twice")
-- A total that opens a window rides the relay's channel copy: the direct copy that
-- follows (SendKillBroadcast) is neither sent nor held for the next window end.
advance(70)
assert(net:Send("K", "Horde Owner:120:WARRIOR"))
assert(s:SendToChannel("K", "Horde Owner:120:WARRIOR") == true)
advance(35)
assert(sent("Horde Owner:120:WARRIOR") == 0, "the relay's own channel copy was doubled at the window end")
print("Channel kill flush: the window's last total leaves even right after the relay queued it")

-- (2) The flush falls inside an instance: nothing leaves there, it leaves once after.
advance(60)
direct = {}
assert(net:Send("K", "Horde Owner:110:WARRIOR")) -- opens a window
advance(10)
assert(net:Send("K", "Horde Owner:112:WARRIOR")) -- held for the window end
advance(5)
inInstance, Overlord.InstanceSuspended = true, true
advance(30)
assert(sent("Horde Owner:112:WARRIOR") == 0, "a total was sent inside an instance")
assert(s._channelKillPending == "Horde Owner:112:WARRIOR", "the held total was lost inside the instance")
inInstance, Overlord.InstanceSuspended = false, false
s:Resume()
advance(15)
assert(sent("Horde Owner:112:WARRIOR") == 1, "the total held during the instance never left after it")
advance(60)
assert(sent("Horde Owner:112:WARRIOR") == 1, "the held total was sent more than once")
print("Channel kill flush: a total held across an instance leaves once after the exit")
