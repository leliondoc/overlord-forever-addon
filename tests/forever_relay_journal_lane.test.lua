-- Truce ends no longer take the relay's priority (2.0.2).
-- A truce end (FR) was urgent and a terminal, like a capture's end: it passed before
-- everything, took the priority channel token of relayed terminals (one per 1.25 s) and,
-- while one was ready, held back the lane of the victory journal (VB). Seen in game on
-- 2026-10-13: truce ends were the first traffic of a lone bridge (one per front in every
-- map answer, plus the leaked copies of other clients' answers), half of its channel
-- messages, while the journal lost 404 of 772 rows and keeps 821 of 1,910. No client
-- sends one any more (Zones:ApplyFrontTruceEndReset); those of older clients are
-- background.
--  (1) guard: under a stream of relayed victory announcements the journal still leaves
--      (true before 2.0.2 as well: a waiting channel fragment is not "ready");
--  (2) a truce end of a client before 2.0.2 is background: not urgent, no priority
--      channel token, and a capture's end that comes meanwhile leaves at once;
--  (3) a capture's end still passes before the journal.
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
function IsInGroup() return false end
s.OnAddonMessage = function() end

local clock = 1000
function GetTime() return clock end
local wall = time()
function time() return wall + math.floor(clock - 1000) end
GetServerTime = time
local timers, order = {}, 0
C_Timer = { After = function(delay, fn)
    order = order + 1
    timers[#timers + 1] = { at = clock + delay, fn = fn, order = order }
end, NewTicker = function() return {} end }
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at or (a.at == b.at and a.order < b.order) end)
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
    sent[#sent + 1] = { at = clock, transport = chatType, msg = msg }
    return true
end
function s:SendToBNet(_, _, payload)
    sent[#sent + 1] = { at = clock, transport = "BNET", msg = tostring(payload) }
    return true
end
local friends = { 777, faction = { [777] = "Horde" } }
function s:GetBetaBNetTargets() return friends end
function s:GetBetaBNetTargetInfo(id) return friends.faction[id], "Hoda Bridger" end
net:NoteBNetHeard(777)
local function count(marker, transport)
    local n, first = 0, nil
    for _, m in ipairs(sent) do
        if m.msg:find(marker, 1, true) and (not transport or m.transport == transport) then
            n = n + 1
            first = first or m.at
        end
    end
    return n, first
end
local serial = 0
local function relayed(kind, payload, origin)
    serial = serial + 1
    local wire = "eu|j" .. serial .. "|" .. time() .. "|*|" .. origin .. ",Hoda Bridger|" .. kind .. "|" .. payload
    return net:Receive(wire, "Hoda Bridger", "BNET", 777)
end
-- A neighbour to send the journal to (as a map answer does).
net:Receive("eu|hello1|" .. time() .. "|*|Chan Mate|SH|42", "Chan Mate", "CHANNEL")
advance(3)
sent = {}

-- One journal row a second for 40 s, as map answers queue them.
local journalRefused = 0
local function journal(prefix, seconds)
    for i = 1, seconds do
        C_Timer.After(i, function()
            if not net:Send("VB", ("1791878400:global:%s%d,A,%d,%d,20,1000"):format(prefix, i, 1791880000 + i, 1791880000 + i),
                "Chan Mate") then journalRefused = journalRefused + 1 end
        end)
    end
end

-- (1) Three relayed victory announcements a second (terminals), each with a channel copy
-- that waits for the priority token: a terminal is ready at every tick.
local function stream(kind, perSecond, seconds, payloadOf)
    for i = 1, perSecond * seconds do
        C_Timer.After(i / perSecond, function() relayed(kind, payloadOf(i), "Hugo Capturer") end)
    end
end
stream("TV", 3, 40, function(i) return ("Horde:%d:1:2:front%d:TVMARK"):format(1791880000 + i, i) end)
journal("tvrun", 40)
advance(45)
local left = count("tvrun", "WHISPER")
assert(journalRefused == 0, "Journal rows were refused under a stream of terminals: " .. journalRefused)
assert(left >= 38, "The journal was not served under a stream of terminals: " .. left .. " of 40 rows left")
print("Journal lane: served under a stream of terminals (" .. left .. " of 40 rows)")

-- (2) Truce ends of clients before 2.0.2, three a second: background. They neither hold
-- the journal back nor take the priority channel token, and a capture's end that comes
-- meanwhile leaves at once.
advance(150)
sent, journalRefused = {}, 0
local criticalAt = net._lastRelayCriticalAt
stream("FR", 3, 40, function(i) return ("front%d:%d:FRMARK"):format(i % 7, 1791880000 + i) end)
journal("frrun", 40)
local capSentAt
C_Timer.After(20, function()
    capSentAt = clock
    relayed("C", "capz1:Hugo Capturer:Horde:" .. time() .. ":CAPMARK", "Hugo Capturer")
end)
advance(45)
left = count("frrun", "WHISPER")
assert(journalRefused == 0 and left >= 38, "Old truce ends held the journal back: " .. left .. " of 40 rows left, "
    .. journalRefused .. " refused")
assert(not net:IsUrgentPacket("FR", "front1:1791880000"), "A truce end is still urgent")
local capCopies, capAt = count("CAPMARK", "CHANNEL")
assert(capCopies >= 1 and capAt - capSentAt <= 3, "A capture's end waited behind old truce ends")
-- The only priority token of the run went to the capture.
local frOnChannel = count("FRMARK", "CHANNEL")
assert(net._lastRelayCriticalAt ~= criticalAt and math.abs(net._lastRelayCriticalAt - capAt) < 0.001,
    "A truce end took the priority channel token")
print("Journal lane: old truce ends are background (" .. frOnChannel .. " on the channel at its ordinary pace), a capture's end leaves at once")

-- (3) A capture's end still goes before the journal.
advance(150)
net:Receive("eu|hello2|" .. time() .. "|*|Chan Mate|SH|42", "Chan Mate", "CHANNEL")
advance(3)
sent = {}
for i = 1, 6 do net:Send("VB", ("1791878400:global:last%d,A,%d,%d,20,1000"):format(i, 1791890000 + i, 1791890000 + i), "Chan Mate") end
relayed("C", "capz2:Hugo Capturer:Horde:" .. time() .. ":LASTMARK", "Hugo Capturer")
advance(10)
local _, lastCap = count("LASTMARK", "CHANNEL")
local _, firstJournal = count("last1,", "WHISPER")
assert(lastCap and firstJournal and lastCap <= firstJournal, "A capture's end waited behind the journal")
print("Journal lane: a capture's end still passes first")
