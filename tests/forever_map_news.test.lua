-- 2.0.1 map news. A capture learnt from the map of a Battle.net friend of the other
-- faction (the answer to a request of ours) is said once to our faction: the changed
-- entries only, as a partial map of one to three small pages on the channel. Before,
-- every channel mate asked the bridge for a whole map (14 to 17 pages), one requester
-- served at a time: a faction lagged 10 to 30 minutes behind its own bridge.
-- Real Sync code; the relay, the clock and Blizzard's timers are simulated.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync = Overlord.Sync
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RequireCaptureSync("login")
Overlord:RestoreZoneState()
Overlord.SaveState = function() end
Overlord.PrintNotification = function() end
local zones, plain = {}, {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do
        zone.name = zone.name or zone.id
        zones[#zones + 1] = zone
        if not Overlord.Zones:GetBaseZoneFixedOwner(zone.id) then plain[#plain + 1] = zone end
    end
end
table.sort(plain, function(a, b) return a.id < b.id end)
Overlord:MarkCaptureSyncReceived(true)
for _, z in ipairs(zones) do z._loginSyncUnconfirmed = nil end

local clock, timers = 100, {}
function GetTime() return clock end
C_Timer.After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end
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
local T = time()
local gate = false
Overlord.IsCaptureSyncPending = function() return gate end

local targeted, said, presences, refuse = true, {}, 0, 0
Overlord.Relay = {
    stats = {},
    IsTargetedDispatch = function() return targeted end,
    -- (a broadcast in this fixture is heard first-hand on our channel)
    IsDirectChannelDispatch = function() return not targeted end,
    Broadcast = function(_, kind, payload)
        said[#said + 1] = { kind = kind, payload = payload }
        if refuse > 0 then refuse = refuse - 1; return 0 end
        return 1
    end,
    ScheduleReturnPresence = function() presences = presences + 1 end,
    MapChanged = function() end,
}
function sync:GetBetaPeerFaction(who) return tostring(who):find("^Enemy") and "Horde" or "Alliance" end
function sync:IsOutdatedMapPeer() return false end

local function zoneOf(id) return (select(1, Overlord.Fronts:GetZone(id))) end
local function set(id, owner, ct)
    local z = zoneOf(id)
    z.owner, z.status, z.capturedTime, z.updatedAt = owner, owner and "captured" or "locked", ct, ct
end
local function state(id) local z = zoneOf(id); return (z.owner or "N") .. "@" .. tostring(z.capturedTime or 0) end
local function snapshot()
    local pages, count = sync:BuildZoneAllSnapshotPages(zones, "G")
    assert(count > 1 and pages[1]:match("^@G%-"), "not a complete global snapshot")
    return pages
end
local senders = 0
local function deliver(pages, who)
    senders = senders + 1
    for _, p in ipairs(pages) do sync:OnReceiveZoneAll(p, who .. string.rep("x", senders)) end
end
local function saidText()
    local out = {}
    for _, m in ipairs(said) do out[#out + 1] = m.payload end
    return table.concat(out, " ")
end
-- Every zone starts Alliance, long ago.
for i, z in ipairs(zones) do set(z.id, "Alliance", T - 9000 - i) end
local X, Y = "elwynn_goldshire", "ash_iris_lake"

-- (1) The channel carries our own news pages and no other map page.
assert(sync:ChannelCarries("ZA", "@P-1790017000-7:1:1|x:A:1:1", true), "our own news page is kept off the channel")
assert(sync:ChannelCarries("ZA", "@P-1790017000-7:3:3|x:A:1:1", true), "a three-page news batch is kept off the channel")
assert(not sync:ChannelCarries("ZA", "@P-1790017000-7:1:1|x:A:1:1", false), "a relayed news page went on the channel again")
assert(not sync:ChannelCarries("ZA", "@P-1790017000-7:2:4|x:A:1:1", true), "a four-page partial map went on the channel")
assert(not sync:ChannelCarries("ZA", "@P-1790017000-7:5:17|x:A:1:1", true), "a whole partial map went on the channel")
assert(not sync:ChannelCarries("ZA", "@G-1790017000-7:1:1|x:A:1:1", true), "a global map page went on the channel")

-- (2) The reply of a Battle.net friend of the other faction teaches us one capture:
-- said once, that entry only, then our presence.
set(X, "Horde", T - 300)
local pages = snapshot()
set(X, "Alliance", T - 4000)
deliver(pages, "Enemy Friend")
assert(state(X) == "Horde@" .. (T - 300), "fixture: the reply was not applied: " .. state(X))
assert(#said == 0, "the news left before its short hold")
advance(4)
assert(#said == 1 and said[1].kind == "ZA" and said[1].payload:match("^@P%-%d+%-%d+:1:1|"),
    "the capture learnt from the other faction's map was not said as one partial page: " .. saidText())
assert(said[1].payload:find(X .. ":H:" .. (T - 300) .. ":" .. (T - 300), 1, true), "the news does not carry the capture")
assert(not said[1].payload:find(Y, 1, true), "the news carries a zone that did not change")
assert(sync:ChannelCarries("ZA", said[1].payload, true), "the news page would not reach the channel")
assert(presences == 1, "our presence does not follow the news: " .. presences)
local line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("Map news told to our faction: 1 announcements (1 captures)", 1, true), "not reported: " .. line)

-- (3) Nothing is said for what a channel mate's map taught us (it already holds it),
-- nor for a batch heard as a broadcast (everyone heard it).
advance(60)
said, presences = {}, 0
set(X, "Horde", T - 250)
pages = snapshot()
set(X, "Alliance", T - 4000)
deliver(pages, "Ally Neighbour")
assert(state(X) == "Horde@" .. (T - 250), "fixture: the ally's reply was not applied")
advance(20)
assert(#said == 0, "a capture learnt from a channel mate was announced")
advance(60)
set(X, "Horde", T - 240)
pages = snapshot()
set(X, "Alliance", T - 4000)
targeted = false
deliver(pages, "Enemy Friend")
targeted = true
assert(state(X) == "Horde@" .. (T - 240), "fixture: the broadcast was not applied")
advance(20)
assert(#said == 0, "a capture learnt from a broadcast was announced again")

-- (4) Someone else says it first: our own announcement is dropped.
advance(60)
set(X, "Horde", T - 200)
pages = snapshot()
local heard = sync:BuildZoneAllSnapshotPages({ zoneOf(X) }, "P")
set(X, "Alliance", T - 4000)
deliver(pages, "Enemy Friend")
targeted = false
deliver(heard, "Ally Speaker")
targeted = true
advance(20)
assert(#said == 0, "a capture another client had just said was said again: " .. saidText())
line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("1 captures left to someone who said them first", 1, true), "not reported: " .. line)

-- (5) Many captures at once (a bridge back after a long absence): the twelve newest,
-- in three pages at most; captures older than two hours are left to the usual pulls.
advance(60)
said = {}
assert(#plain >= 16, "fixture: not enough zones")
for i = 1, 15 do set(plain[i].id, "Horde", T - 100 - i) end
set(plain[16].id, "Horde", T - 8000)
pages = snapshot()
for i = 1, 16 do set(plain[i].id, "Alliance", T - 9000 - i) end
deliver(pages, "Enemy Friend")
advance(20)
assert(#said >= 1 and #said <= 3, "news pages: " .. #said)
local text, count = saidText(), 0
for i = 1, 15 do
    if text:find(plain[i].id .. ":H:", 1, true) then count = count + 1 end
end
assert(count == 12, "captures announced: " .. count)
assert(text:find(plain[1].id .. ":H:", 1, true) and not text:find(plain[15].id .. ":H:", 1, true),
    "the newest captures were not the ones announced")
assert(not text:find(plain[16].id .. ":H:", 1, true), "a capture older than two hours was announced")
for _, m in ipairs(said) do
    assert(m.payload:match("^@P%-%d+%-%d+:%d+:" .. #said .. "|") and sync:ChannelCarries("ZA", m.payload, true),
        "a news page would not reach the channel: " .. m.payload:sub(1, 30))
end

-- (6) Back from an instance or just logged in: the news waits for the end of the gate.
advance(60)
said = {}
set(X, "Horde", T - 90)
pages = snapshot()
set(X, "Alliance", T - 4000)
deliver(pages, "Enemy Friend")
gate = true
advance(8)
assert(#said == 0, "the news left during the wait for a first map")
gate = false
advance(8)
assert(#said == 1 and said[1].payload:find(X .. ":H:" .. (T - 90), 1, true), "the news was lost with the gate")

-- (7) A capture end that expired in our relay queue is said the same way (the relay
-- calls NoteMapNews with the zone): only when our map holds the capture.
advance(60)
said = {}
set(Y, "Horde", T - 60)
assert(sync:NoteMapNews(Y, nil, true), "a capture of the other faction that our map holds was not queued")
assert(not sync:NoteMapNews("no_such_zone", nil, true), "an unknown zone was queued")
-- Our own faction's captures were heard first-hand on the channel: nothing to say.
set(plain[1].id, "Alliance", T - 40)
assert(not sync:NoteMapNews(plain[1].id, nil, true), "a capture of our own faction was queued")
advance(20)
assert(#said == 1 and said[1].payload:find(Y .. ":H:" .. (T - 60), 1, true), "the expired capture end was not said")
-- Retaken meanwhile: the stale entry is not said.
advance(60)
said = {}
set(Y, "Horde", T - 50)
sync:NoteMapNews(Y)
set(Y, "Alliance", T - 10)
advance(20)
assert(#said == 0, "a capture replaced meanwhile was announced: " .. saidText())

-- (8) Only a first-hand Battle.net reply is a source. A relayed packet that names our
-- friend as its origin (the name is written by the hop that passed it on) is merged like
-- any map and nothing is announced.
advance(120)
said, presences = {}, 0
local relayedOrigin = true
Overlord.Relay.IsRelayedOrigin = function() return relayedOrigin end
local Z1, Z2, Z3 = plain[14].id, plain[15].id, plain[16].id
set(Z1, "Horde", T - 30)
pages = snapshot()
set(Z1, "Alliance", T - 9100)
deliver(pages, "Enemy Friend")
assert(state(Z1) == "Horde@" .. (T - 30), "fixture: the relayed map was not merged: " .. state(Z1))
advance(20)
assert(#said == 0, "a map relayed under our friend's name was announced: " .. saidText())
relayedOrigin = false

-- (9) A broadcast batch that fails its checks does not silence our announcement: its
-- first page only delays ours (once, eight seconds).
advance(60)
said = {}
set(Z2, "Horde", T - 25)
pages = snapshot()
local forged = sync:BuildZoneAllSnapshotPages({ zoneOf(Z2) }, "P")
set(Z2, "Alliance", T - 9200)
deliver(pages, "Enemy Friend")
targeted = false
senders = senders + 1
sync:OnReceiveZoneAll(forged[1] .. ",no_such_zone:A:1:1", "Ally Forger" .. string.rep("x", senders))
targeted = true
assert(state(Z2) == "Horde@" .. (T - 25), "fixture: the friend's reply was not applied: " .. state(Z2))
advance(5)
assert(#said == 0, "a page that names our capture did not delay our announcement")
advance(15)
assert(#said == 1 and said[1].payload:find(Z2 .. ":H:" .. (T - 25), 1, true),
    "a batch that was refused silenced our announcement: " .. saidText())
line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("1 captures left to someone who said them first", 1, true),
    "a refused batch was counted as someone saying it first: " .. line)

-- (10) Said once: the same capture is not announced again (a copy of its final that
-- expires in our relay queue after the announcement).
assert(not sync:NoteMapNews(Z2, nil, true), "a capture already announced was queued again")

-- (11) A change of owner that our own live traffic contradicts is applied (the friend's
-- reply is the only door to its side) but is not ours to spread, and no presence is
-- brought forward for it.
advance(60)
said, presences = {}, 0
sync:NoteLiveZoneTraffic(Z3, "Alliance")
set(Z3, "Horde", T - 15)
pages = snapshot()
set(Z3, "Alliance", T - 9300)
deliver(pages, "Enemy Friend")
assert(state(Z3) == "Horde@" .. (T - 15), "the friend's reply was held: " .. state(Z3))
advance(20)
assert(#said == 0 and presences == 0, "a contradicted change of owner was announced: " .. saidText())

-- (12) Our presence after an announcement: once a minute at most.
advance(120)
said, presences = {}, 0
set(Y, "Horde", T - 12)
pages = snapshot()
set(Y, "Alliance", T - 9400)
deliver(pages, "Enemy Friend")
advance(4)
assert(#said == 1 and presences == 1, "fixture: an announcement and its presence: " .. #said .. " / " .. presences)
advance(16)
set(X, "Horde", T - 11)
pages = snapshot()
set(X, "Alliance", T - 9500)
deliver(pages, "Enemy Friend")
advance(20)
assert(#said == 2 and presences == 1, "a second presence within the minute: " .. #said .. " / " .. presences)
-- (13) Another bridge's announcement in two pages: its first page, heard before our own
-- timer, makes us wait for the rest (twelve seconds, once); the whole batch then says
-- everything we had to say, and we stay silent.
advance(120)
said, presences = {}, 0
local five = {}
for i = 1, 5 do
    five[i] = plain[i]
    set(plain[i].id, "Horde", T - 9 + i)
end
pages = snapshot()
local theirs, theirCount = sync:BuildZoneAllSnapshotPages(five, "P")
assert(theirCount == 2, "fixture: the other bridge's announcement is not two pages: " .. tostring(theirCount))
for i = 1, 5 do set(plain[i].id, "Alliance", T - 9600 - i) end
deliver(pages, "Enemy Friend")
targeted = false
senders = senders + 1
local speaker = "Ally Bridge" .. string.rep("x", senders)
sync:OnReceiveZoneAll(theirs[1], speaker)
sync:OnReceiveZoneAll(theirs[1], speaker) -- (heard twice: the wait is not moved)
targeted = true
advance(6)
assert(#said == 0, "a first page of someone else's announcement did not make us wait: " .. saidText())
targeted = false
sync:OnReceiveZoneAll(theirs[2], speaker)
targeted = true
advance(30)
assert(#said == 0, "captures another bridge had just announced in two pages were said again: " .. saidText())
line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("6 captures left to someone who said them first", 1, true), "not reported: " .. line)

-- (14) A page the relay queue refused goes once more, same batch, and no presence is
-- brought forward for an announcement that did not all leave.
advance(120)
said, presences = {}, 0
set(Z1, "Horde", T - 3)
pages = snapshot()
set(Z1, "Alliance", T - 9700)
refuse = 1
deliver(pages, "Enemy Friend")
advance(4)
assert(#said == 1 and presences == 0, "fixture: one refused page: " .. #said .. " / " .. presences)
advance(12)
assert(#said == 2 and said[2].payload == said[1].payload, "a refused page was not sent once more: " .. #said)
advance(60)
assert(#said == 2, "a refused page was sent more than once more: " .. #said)
line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("1 pages sent twice (queue full)", 1, true), "not reported: " .. line)

-- (15) A new capture of a point already announced is news again.
advance(60)
said = {}
set(Z2, "Horde", T - 2)
pages = snapshot()
set(Z2, "Alliance", T - 9800)
deliver(pages, "Enemy Friend")
advance(4)
assert(#said == 1 and said[1].payload:find(Z2 .. ":H:" .. (T - 2), 1, true),
    "a new capture of a point already announced was not said: " .. saidText())

-- (16) An announcement heard while we had nothing to say is remembered too: when the
-- final of that capture expires in our relay queue later, it is not said again.
advance(60)
said = {}
set(Z3, "Horde", T - 1)
local heardOnly = sync:BuildZoneAllSnapshotPages({ zoneOf(Z3) }, "P")
targeted = false
deliver(heardOnly, "Ally Bridge")
targeted = true
assert(not sync:NoteMapNews(Z3, nil, true), "a capture another bridge announced was queued when its final expired")
-- A partial map that did not come first-hand on our channel says nothing about what
-- our channel heard.
set(Y, "Horde", T - 1)
local viaFriend = sync:BuildZoneAllSnapshotPages({ zoneOf(Y) }, "P")
Overlord.Relay.IsDirectChannelDispatch = function() return false end
targeted = false
deliver(viaFriend, "Ally Bridge")
targeted = true
Overlord.Relay.IsDirectChannelDispatch = function() return not targeted end
assert(sync:NoteMapNews(Y, nil, true), "a partial map that did not come by our channel silenced an announcement")
advance(20)

-- (17) Inside an instance nothing leaves: a pending announcement is given up, counted.
advance(60)
said = {}
set(X, "Horde", T)
pages = snapshot()
set(X, "Alliance", T - 9900)
deliver(pages, "Enemy Friend")
local realInInstance = IsInInstance
IsInInstance = function() return true end
advance(20)
IsInInstance = realInInstance
advance(20)
assert(#said == 0, "an announcement left from an instance, or after it: " .. saidText())
line = table.concat(sync:GetCrossFactionDiagnostics(), " ")
assert(line:find("1 announcements given up", 1, true), "not reported: " .. line)

-- (18) One announcement per friend per two minutes: what the same friend teaches again
-- meanwhile is applied here and not said (a friend whose maps keep changing, or who
-- sends maps nobody asked for, cannot make us speak every fifteen seconds).
advance(300)
said = {}
local function fromSameFriend(zoneId, ct)
    set(zoneId, "Horde", ct)
    local map = snapshot()
    set(zoneId, "Alliance", T - 9950)
    for _, p in ipairs(map) do sync:OnReceiveZoneAll(p, "Enemy Samefriend") end
    assert(state(zoneId) == "Horde@" .. ct, "fixture: the friend's map was not applied: " .. state(zoneId))
end
fromSameFriend(Z1, T + 1)
advance(20)
assert(#said == 1, "fixture: the friend's first map was not announced: " .. #said)
fromSameFriend(Z2, T + 2)
advance(40)
assert(#said == 1, "a second map of the same friend within two minutes was announced: " .. saidText())
advance(120)
fromSameFriend(Z3, T + 3)
advance(20)
assert(#said == 2 and said[2].payload:find(Z3 .. ":H:" .. (T + 3), 1, true),
    "the same friend was not listened to again after two minutes: " .. saidText())
print("Forever map news: learnt from the other faction's map, said once in three pages at most, never echoed")
