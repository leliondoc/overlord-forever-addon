-- 2.5.0: a capture in progress between the factions (Relay CrossHands).
-- A packet carries four names at most. The start of a capture of the other side reached a
-- Battle.net friend with three or four of them most of the time: the friend saw it and could
-- tell nobody; and a client standing fifth in line on the capturer's side sent nothing to its
-- friend of the other side at all.
--  (A) Heard from a Battle.net friend of the other side: passed on under the author's name and
--      ours, whatever the hands it took over there. Nothing goes back there.
--  (B) Heard on our side with its four names: the start of a capture of ours still goes to our
--      live friends of the other side, and to nobody else.
math.randomseed(7)
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
Overlord.PlayerFaction = "Horde"
function s:GetChannelId() return 5 end
function s:GetPlayerFullName() return "Local Tester" end
function IsInInstance() return false end
function IsInGroup() return false end

local clock = 1000
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

local sent, bnet = {}, {}
function s:SendAddonChecked(msg, chatType, target)
    sent[#sent + 1] = { msg = msg, chatType = chatType, target = target }
    return true
end
function s:SendToBNet(id, kind, payload)
    bnet[#bnet + 1] = { id = id, kind = kind, payload = payload }
    return true
end
local friends = { faction = {} }
function s:GetBetaBNetTargets() return friends end
function s:GetBetaBNetTargetInfo(id)
    for _, f in ipairs(friends) do if f == id then return friends.faction[id], "Abri Bridger" end end
    return nil
end
s.OnAddonMessage = function() end -- only the relay's forwarding is under test

-- Every packet the relay takes for sending.
local queued = {}
local realQueue = net.Queue
function net:Queue(p, ...)
    queued[#queued + 1] = p
    return realQueue(self, p, ...)
end
local function queuedWith(marker)
    local out = {}
    for _, p in ipairs(queued) do
        if type(p.payload) == "string" and p.payload:find(marker, 1, true) then out[#out + 1] = p end
    end
    return out
end
local function bnetWith(marker)
    local n = 0
    for _, row in ipairs(bnet) do if tostring(row.payload):find(marker, 1, true) then n = n + 1 end end
    return n
end
local function sentWith(marker, chatType)
    local n = 0
    for _, row in ipairs(sent) do
        if row.msg:find(marker, 1, true) and (not chatType or row.chatType == chatType) then n = n + 1 end
    end
    return n
end
local serial = 0
local function hear(path, kind, payload, sender, transport, bnetID)
    serial = serial + 1
    return net:Receive("eu|x-" .. serial .. "|" .. time() .. "|*|" .. path .. "|" .. kind .. "|" .. payload,
        sender, transport, bnetID)
end
-- (zone : status : owner : hold : side of the capturer : ...)
local function start(zone, side, marker)
    return zone .. ":in_progress::5:" .. side .. ":w1:" .. marker
end

-- (A) One live friend of the other side.
friends[1], friends.faction[777] = 777, "Alliance"
net:NoteBNetHeard(777)

-- A1. Four names from over there: passed on as the author's and ours.
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "ZS", start("elwynn_goldshire", "A", "STARTMARK"), "Abri Bridger", "BNET", 777)
advance(3)
local rows = queuedWith("STARTMARK")
assert(#rows == 1, "the start of a capture of the other side, come with four names, was not passed on: " .. #rows)
assert(#rows[1].path == 2 and rows[1].path[1] == "Alda Capturer" and rows[1].path[2] == "Local Tester",
    "its path here: " .. table.concat(rows[1].path, ","))
assert(rows[1].heardOn == "BNET" and not rows[1].crossOnly, "it is an ordinary forward of a friend's copy")
assert(bnetWith("STARTMARK") == 0, "a capture of the other side went back there")
assert((net.stats.crossHandsReset or 0) == 1)
-- Its second copy (another friend, another path) is the same packet: nothing more.
local before = #queued
net:Receive("eu|x-" .. serial .. "|" .. time() .. "|*|Alda Capturer,Abri Bridger|ZS|"
    .. start("elwynn_goldshire", "A", "STARTMARK"), "Abri Bridger", "BNET", 777)
advance(3)
assert(#queued == before, "the same packet was passed on twice")

-- A2. Two names (the friend had it first-hand), three names: the author's and ours too.
hear("Alda Capturer,Abri Bridger", "ZS", start("elwynn_goldshire", "A", "NEARMARK"), "Abri Bridger", "BNET", 777)
hear("Alda Capturer,Hand One,Abri Bridger", "ZS", start("elwynn_goldshire", "A", "THREEMARK"), "Abri Bridger", "BNET", 777)
advance(3)
rows = queuedWith("NEARMARK")
assert(#rows == 1 and #rows[1].path == 2 and rows[1].path[2] == "Local Tester", "a friend's first-hand copy")
rows = queuedWith("THREEMARK")
assert(#rows == 1 and #rows[1].path == 2 and rows[1].path[1] == "Alda Capturer" and rows[1].path[2] == "Local Tester",
    "three names from over there: " .. (rows[1] and table.concat(rows[1].path, ",") or "not passed on"))

-- A3. Its release follows, the same way.
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "ZR", "elwynn_goldshire:w1:Alda Capturer:RELEASEMARK", "Abri Bridger", "BNET", 777)
advance(3)
rows = queuedWith("RELEASEMARK")
assert(#rows == 1 and #rows[1].path == 2 and rows[1].path[1] == "Alda Capturer" and rows[1].path[2] == "Local Tester",
    "the release of the other side's capture")
-- (A release names no side and the friend is no longer on its path: skipped by its id, crossFrom.)
assert(bnetWith("RELEASEMARK") == 0, "a release went back to the friend it came from")
-- A second friend of the other side does get it (that is what a bridge between two friends is),
-- the first one still does not.
friends[2], friends.faction[778] = 778, "Alliance"
net:NoteBNetHeard(778)
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "ZR", "elwynn_goldshire:w2:Alda Capturer:SECONDRELEASE", "Abri Bridger", "BNET", 777)
advance(3)
local toSecond = 0
for _, row in ipairs(bnet) do
    if tostring(row.payload):find("SECONDRELEASE", 1, true) then
        assert(row.id ~= 777, "a release went back to the friend it came from")
        if row.id == 778 then toSecond = toSecond + 1 end
    end
end
assert(toSecond >= 1, "fixture: the release reached no other friend, the check above proves nothing")
friends[2], friends.faction[778] = nil, nil

-- A4. A capture of OUR side coming back from over there with four names: nothing is done to it.
before = #queued
hear("Orc Capturer,Hand One,Hand Two,Abri Bridger", "ZS", start("barrens_crossroads", "H", "OURSMARK"), "Abri Bridger", "BNET", 777)
advance(3)
assert(#queuedWith("OURSMARK") == 0 and #queued == before, "our own capture, back from the other side, was passed on again")

-- A5. Anything else with four names stops as ever (a capture's end has its own way: map news).
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "C", "elwynn_goldshire:x:Alliance:ENDMARK", "Abri Bridger", "BNET", 777)
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "ZS", "elwynn_goldshire:captured::0:A:w1:DONEMARK", "Abri Bridger", "BNET", 777)
advance(3)
assert(#queuedWith("ENDMARK") == 0 and #queuedWith("DONEMARK") == 0, "another kind of packet lost its hands")

-- A5b. A fight bracket of "Recent activity" (FK) with four names from over there: passed on under
--      its author's name and ours, like a release, and never back to the friend it came from.
do
    local bracket = "1:elwynn:100:" .. math.floor(time() / 30)
    before = #queued
    hear("Alda Fighter,Hand One,Hand Two,Abri Bridger", "FK", bracket, "Abri Bridger", "BNET", 777)
    advance(3)
    local passed = queuedWith(bracket)
    assert(#passed == 1 and #passed[1].path == 2 and passed[1].path[1] == "Alda Fighter" and passed[1].path[2] == "Local Tester",
        "a fight bracket from the other side: " .. (passed[1] and table.concat(passed[1].path, ",") or "not passed on"))
    for _, row in ipairs(bnet) do
        assert(not (tostring(row.payload):find(bracket, 1, true) and row.id == 777), "a fight bracket went back to the friend it came from")
    end
    -- From a friend of our own side its four names stay four names.
    friends.faction[777] = "Horde"
    local other = "1:elwynn:150:" .. math.floor(time() / 30)
    hear("Alda Fighter,Hand One,Hand Two,Abri Bridger", "FK", other, "Abri Bridger", "BNET", 777)
    advance(3)
    assert(#queuedWith(other) == 0, "a fight bracket from a friend of our own side lost its hands")
    friends.faction[777] = "Alliance"
end

-- A6. A friend of our own side: its four names are four names.
friends.faction[777] = "Horde"
hear("Alda Capturer,Hand One,Hand Two,Abri Bridger", "ZS", start("elwynn_goldshire", "A", "SAMESIDEMARK"), "Abri Bridger", "BNET", 777)
advance(3)
assert(#queuedWith("SAMESIDEMARK") == 0, "a friend of our own side reset the hands")
friends.faction[777] = "Alliance"
print("Cross hands: a capture of the other side heard from a Battle.net friend is passed on whatever the hands it took there")

-- (B) Our side: four names heard here, a live friend over there.
advance(10)
net:NoteBNetHeard(777)
net.peers["hand three"] = { name = "Hand Three", at = clock, via = "Hand Three", transport = "WHISPER", hops = 1 }
sent, bnet, queued = {}, {}, {}
hear("Orc Capturer,Hand One,Hand Two,Hand Three", "ZS", start("barrens_crossroads", "H", "FIFTHMARK"), "Hand Three", "WHISPER")
advance(3)
rows = queuedWith("FIFTHMARK")
assert(#rows == 1 and rows[1].crossOnly == true, "the fifth in line told its friend of the other side nothing: " .. #rows)
assert(#rows[1].path == 2 and rows[1].path[1] == "Orc Capturer" and rows[1].path[2] == "Local Tester",
    "its path: " .. table.concat(rows[1].path, ","))
assert(bnetWith("FIFTHMARK") >= 1, "no Battle.net copy left")
assert(sentWith("FIFTHMARK") == 0, "a copy for the other side only went to our own side (channel, group, whisper)")
assert((net.stats.crossHandsSent or 0) == 1)

-- B2. A capture of the other side with its four names on our side: it stops (it is theirs).
sent, bnet, queued = {}, {}, {}
hear("Alda Capturer,Hand One,Hand Two,Hand Three", "ZS", start("elwynn_goldshire", "A", "THEIRSMARK"), "Hand Three", "WHISPER")
-- B3. A release with four names: it stops too (the capture's time runs out over there).
hear("Orc Capturer,Hand One,Hand Two,Hand Three", "ZR", "barrens_crossroads:w1:Orc Capturer:LATEMARK", "Hand Three", "WHISPER")
advance(3)
assert(#queued == 0 and #bnet == 0, "something else than the start of a capture of ours crossed with four names")

-- B4. Three names: the ordinary forward, as before (one packet, not two).
sent, bnet, queued = {}, {}, {}
hear("Orc Capturer,Hand One,Hand Three", "ZS", start("barrens_crossroads", "H", "THIRDMARK"), "Hand Three", "WHISPER")
advance(3)
rows = queuedWith("THIRDMARK")
assert(#rows == 1 and not rows[1].crossOnly and #rows[1].path == 4, "three names: " .. #rows)
assert(bnetWith("THIRDMARK") >= 1, "the ordinary forward no longer crosses")

-- B5. The same packet heard again with four names (other hands): told once.
sent, bnet, queued = {}, {}, {}
hear("Orc Capturer,Hand One,Hand Two,Hand Three", "ZS", start("barrens_crossroads", "H", "ONCEMARK"), "Hand Three", "WHISPER")
net:Receive("eu|x-" .. serial .. "|" .. time() .. "|*|Orc Capturer,Hand Four,Hand Two,Hand Three|ZS|"
    .. start("barrens_crossroads", "H", "ONCEMARK"), "Hand Three", "WHISPER")
advance(3)
assert(#queuedWith("ONCEMARK") == 1, "the fifth in line told the same start twice: " .. #queuedWith("ONCEMARK"))

-- B6. Many bridges about (their presences said so): only a share of the fifth row crosses.
do
    for i = 1, 80 do
        local who = "Bridge Number" .. string.char(97 + i % 26) .. string.char(97 + math.floor(i / 26))
        net:Receive("eu|nh-" .. i .. "|" .. time() .. "|*|" .. who .. "|NH|1.0.0~b~ld~lr~lp6", who, "CHANNEL")
    end
    advance(11) -- (the count of bridges is read again every 10 s)
    net:NoteBNetHeard(777)
    local bridges, share = net:GetCrossElection()
    assert(bridges >= 80 and share < 0.2, "fixture: the election did not start: " .. tostring(bridges) .. " " .. tostring(share))
    sent, bnet, queued = {}, {}, {}
    for i = 1, 60 do
        hear("Orc Capturer,Hand One,Hand Two,Hand Three", "ZS", start("barrens_crossroads", "H", "SHAREMARK" .. i .. "x"), "Hand Three", "WHISPER")
    end
    advance(3)
    local crossed = #queuedWith("SHAREMARK")
    assert(crossed >= 1 and crossed <= 20, "of 60 starts heard fifth in line, crossed with 80 bridges about: " .. crossed)
end

-- B7. No live friend over there: nothing.
friends[1], friends.faction[777] = nil, nil
sent, bnet, queued = {}, {}, {}
hear("Orc Capturer,Hand One,Hand Two,Hand Three", "ZS", start("barrens_crossroads", "H", "ALONEMARK"), "Hand Three", "WHISPER")
advance(3)
assert(#queued == 0 and #bnet == 0, "a copy was made for a friend that is not there")
print("Cross hands: the fifth in line still tells its friends of the other side the start of a capture of ours, and nobody else")
