-- An addressed packet only ever follows a route (2.0.2).
-- A row of a map answer (truce end, victory journal, siege state...) is addressed to
-- the one neighbour that asked. The relay used to fall back to its broadcast fan-out
-- (group, faction channel, every Battle.net bridge) whenever the route to that
-- neighbour was a group route, was missing, or looped; and every client that heard
-- such a copy on its channel or in its group passed it on again, by whisper to the
-- target or over Battle.net to the other faction, whose bridges put it on their own
-- channel with the priority of a capture end. Seen in game on 2026-10-13: half of the
-- channel messages of a lone bridge were truce ends addressed to somebody else.
--  (1) our own row to a group mate leaves once, by whisper;
--  (2) a row addressed to somebody else that a Battle.net friend passed us is dropped
--      when we hold no route to its target (it is not put on our channel);
--  (3) a row addressed to somebody else heard on the channel or in the group is not
--      passed on, even with a route to its target;
--  (4) the same row received point to point (whisper, Battle.net) with a direct route
--      to its target is still passed on, to that target only;
--  (5) broadcasts are unchanged.
math.randomseed(5)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s = Overlord.Sync
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
net.BridgeChannelHold = { 0, 0 }
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Alliance"
function s:GetChannelId() return 5 end
function s:GetPlayerFullName() return "Abri Bridger" end
function IsInInstance() return false end
local grouped = true
function IsInGroup() return grouped end
function IsInRaid() return false end
function UnitInRaid() return false end
-- The handlers are not under test: only what the relay sends.
s.OnAddonMessage = function() end

local clock = 1000
function GetTime() return clock end
local wall = time()
function time() return wall + math.floor(clock - 1000) end
GetServerTime = time
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

local sent = {}
function s:SendAddonChecked(msg, chatType, target)
    sent[#sent + 1] = { transport = chatType, target = target, msg = msg }
    return true
end
function s:SendToBNet(id, kind, payload)
    sent[#sent + 1] = { transport = "BNET", target = id, msg = tostring(payload) }
    return true
end
local friends = { 777, faction = { [777] = "Horde" } }
function s:GetBetaBNetTargets() return friends end
function s:GetBetaBNetTargetInfo(id) return friends.faction[id], "Hoda Bridger" end
net:NoteBNetHeard(777)

local function copies(marker)
    local out, total = {}, 0
    for _, m in ipairs(sent) do
        if m.msg:find(marker, 1, true) then
            out[m.transport] = (out[m.transport] or 0) + 1
            out.last = m
            total = total + 1
        end
    end
    return out, total
end
local serial = 0
local function wire(kind, payload, target, path)
    serial = serial + 1
    return "eu|t-" .. serial .. "|" .. time() .. "|" .. target .. "|" .. path .. "|" .. kind .. "|" .. payload
end
-- A neighbour heard first-hand on a transport: that is its route.
local function heard(name, transport, bnetID)
    assert(net:Receive(wire("SH", "42", "*", name), name, transport, bnetID) ~= nil)
    advance(2)
    sent = {}
end

-- (1) Our own row to a group mate.
heard("Reqa Mate", "PARTY")
assert(net:IsDirectPeer("Reqa Mate"), "The group mate is not a direct peer (vacuous case)")
assert(net:Send("VF", "1790017900:A:elwynn:OWNMARK", "Reqa Mate"), "The addressed row was refused")
advance(5)
local own, ownTotal = copies("OWNMARK")
assert(own.CHANNEL == nil, "A row addressed to a group mate was put on the faction channel")
assert(own.BNET == nil, "A row addressed to a group mate was sent to the other faction's bridges")
assert(ownTotal == 1 and own.WHISPER == 1 and own.last.target == "Reqa Mate",
    "A row addressed to a group mate did not leave once, by whisper to him: " .. ownTotal)
print("Addressed route: a row for a group mate leaves once, by whisper")

-- (2) Passed to us over Battle.net, addressed to a player we hold no route to.
sent = {}
local before = net.stats.dropped
net:Receive(wire("TV", "Horde:1790017900:1:2:elwynn:FARMARK", "Hugo Capturer", "Hoda Bridger"), "Hoda Bridger", "BNET", 777)
advance(5)
local far, farTotal = copies("FARMARK")
assert(farTotal == 0, "A row addressed to a player we cannot reach was fanned out ("
    .. tostring(far.CHANNEL or 0) .. " on the channel, " .. tostring(far.BNET or 0) .. " over Battle.net)")
assert(net.stats.dropped == before, "A row that is not ours to deliver was counted as a loss")
assert((net.stats.addressedNotPassed or 0) == 1, "The dropped row was not counted")
print("Addressed route: a row for a player we cannot reach is not put on our channel")

-- (3) Heard on the channel or in the group, addressed to a neighbour we could reach.
heard("Chan Mate", "CHANNEL")
net:Receive(wire("TV", "Alliance:1790017900:1:2:elwynn:LEAKMARK", "Chan Mate", "Alda Capturer"), "Alda Capturer", "CHANNEL")
net:Receive(wire("VF", "1790017900:A:elwynn:LEAKMARK2", "Chan Mate", "Reqa Mate"), "Reqa Mate", "PARTY")
advance(5)
local _, leakTotal = copies("LEAKMARK")
assert(leakTotal == 0, "A row addressed to somebody else, heard on a shared transport, was passed on: " .. leakTotal)
assert((net.stats.addressedNotPassed or 0) == 3, "The two overheard rows were not counted")
print("Addressed route: a row overheard on the channel or in the group is not passed on")

-- (4) Received point to point, with a direct route to its target: one whisper.
sent = {}
net:Receive(wire("MS", "mine:5:HOPMARK", "Chan Mate", "Hoda Bridger"), "Hoda Bridger", "BNET", 777)
advance(5)
local hop, hopTotal = copies("HOPMARK")
assert(hopTotal == 1 and hop.WHISPER == 1 and hop.last.target == "Chan Mate",
    "A row we are the next hop of was not passed to its target alone: " .. hopTotal)
print("Addressed route: the next hop still delivers")

-- (5) A broadcast keeps its fan-out (channel, group, the bridge).
sent = {}
assert(net:Send("TV", "Alliance:1790017900:1:2:elwynn:ALLMARK"))
advance(5)
local all = copies("ALLMARK")
assert(all.CHANNEL == 1 and all.BNET == 1 and all.PARTY == 1, "A broadcast lost a copy")
print("Addressed route: broadcasts unchanged")

-- (6) A refused own row becomes "offered again" (not a loss) only when its sender says
-- the row was accepted in the end, for the refusals it counted itself; never more than
-- the queue really refused, and never for a broadcast.
advance(200)
heard("Chan Mate", "CHANNEL")
local accepted = 0
for i = 1, 200 do if net:Send("MS", "fill" .. i .. ":1") then accepted = accepted + 1 end end
assert(accepted < 200, "Test setup: the queue never filled")
local refusedBefore, rowsBefore, retriedBefore = net.stats.localRejected or 0, net.stats.localRowsRefused or 0,
    net.stats.localRetried or 0
assert(not net:Send("VF", "1790017900:A:elwynn:REFUSED", "Chan Mate"), "Test setup: the row was admitted")
assert(not net:Send("VF", "1790017900:A:elwynn:REFUSED", "Chan Mate"), "Test setup: the row was admitted")
assert((net.stats.localRejected or 0) == refusedBefore + 2 and (net.stats.localRowsRefused or 0) == rowsBefore + 2,
    "The two refusals of an own row were not counted")
assert((net.stats.localRetried or 0) == retriedBefore, "A refused row counted as offered again by itself")
assert(not net:Send("MS", "fill-broadcast:1"), "Test setup: the broadcast was admitted")
assert((net.stats.localRowsRefused or 0) == rowsBefore + 2, "A refused broadcast counted as a row for one peer")
net:NoteOfferedAgain(0)
assert((net.stats.localRetried or 0) == retriedBefore, "Nothing accepted, yet rows read as offered again")
net:NoteOfferedAgain(2)
assert((net.stats.localRetried or 0) == retriedBefore + 2, "An accepted row's two refusals were not reported as offered again")
net:NoteOfferedAgain(50)
assert((net.stats.localRetried or 0) == retriedBefore + 2, "More rows offered again than the queue ever refused")
print("Addressed route: refusals become offered-again on acceptance only, never beyond what was refused")
