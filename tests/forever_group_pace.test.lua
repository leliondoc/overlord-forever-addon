-- 2.3.0: messages to the group share the channel's message token: a burst is held on the client
-- (the relay keeps the copy) instead of being refused by the server (code 3).
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now, calls = 1000, {}
function GetTime() return now end
function IsInInstance() return false end
function IsInRaid() return false end
function UnitInRaid() return nil end
function IsInGroup() return true end
function securecall(fn, ...) return fn(...) end
C_ChatInfo = { SendAddonMessage = function(prefix, msg, chatType) calls[#calls + 1] = chatType; return 0 end }
Overlord.InstanceSuspended = false
local sync = Overlord.Sync
sync._channelTokens, sync._channelTokensAt = nil, nil
local ok1 = sync:Send("ZS", "pace-one", true)
local ok2, why2 = sync:Send("ZS", "pace-two", true)
assert(ok1 == true and #calls == 1 and calls[1] == "PARTY", "the first group message did not leave")
assert(ok2 == false and why2 == "budget" and #calls == 1,
    "a second group message in the same second reached the server: " .. #calls)
now = now + 1.3
assert(sync:Send("ZS", "pace-three", true) == true and #calls == 2, "the group stayed held after its token came back")
-- The kill total of a large event goes to the group on the same token.
sync.IsLargeEvent = function() return true end
sync.RelayAlreadyCarries = function() return false end
sync.SendToChannel = function() return false end
local relay = Overlord.Relay
Overlord.Relay = nil
sync._channelTokens, sync._channelTokensAt = nil, nil
local before = #calls
sync:SendKillBroadcast("Pace Tester:41")
sync:SendKillBroadcast("Pace Tester:42")
Overlord.Relay = relay
assert(#calls == before + 1, "two kill totals reached the group in the same second: " .. (#calls - before))
-- /ov network names our channel joins and leaves (to tell our "too fast" from the game's own).
assert(sync:GetChannelOpDiagnostics():find("none this session", 1, true), "channel ops before any")
sync:NoteChannelOp("join pad")
now = now + 5
sync:NoteChannelOp("leave pad")
now = now + 12
local line = sync:GetChannelOpDiagnostics()
assert(line:find("2 in the last 10 min", 1, true) and line:find("leave pad 12 s ago", 1, true), line)
print("Group pace: group messages share the channel token, bursts held on the client")
