-- 2.2.0: the chain (SyncDirectory.lua): live news whispered from hand to hand along the channel's
-- member list while the server refuses the channel. Real relay, guild lane and directory; the
-- contacts, the clock and SendAddonMessage are stubs.
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
local clock = 1000
function GetTime() return clock end
function GetServerTime() return 1790018000 + math.floor(clock) end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
function InCombatLockdown() return false end
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncGuild.lua"))()
assert(loadfile("SyncDirectory.lua"))()
local net, lane, dir = Overlord.Relay, Overlord.GuildLane, Overlord.ChannelDirectory
Overlord.PlayerFaction = "Alliance"
function IsInInstance() return false end
function IsInGuild() return false end
function IsInGroup() return false end
function IsInRaid() return false end
local me = s:GetPlayerFullName()

local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = math.max(clock, timer.at)
        timer.fn()
    end
    clock = stop
end

-- Thirty players of the list, all of them contacts (they greeted us under 2.2.0).
local active = true
dir.IsActive = function() return active end
local contacts = {}
for i = 1, 30 do
    local name = "Contact " .. string.char(64 + math.ceil(i / 26)) .. string.char(96 + (i - 1) % 26 + 1)
    contacts[i] = name
    dir.names[i] = name
    dir.partners[name:lower()] = { name = name, heardAt = clock, chainAt = clock }
end
net.IsDirectPeer = function(_, name) return dir.partners[tostring(name):lower()] ~= nil end
local outdated = {}
net.IsOutdatedMapPeer = function(_, name) return outdated[name] ~= false end
net.HeardPresenceOf = function(_, name) return outdated[name] ~= nil end

-- Points of the test: every name but "nowhere".
dir.KnowsZone = function(_, zoneId) return zoneId ~= nil and zoneId ~= "nowhere" end

local serial = 0
local function packet(kind, payload, path, heardOn)
    serial = serial + 1
    return { region = "global", id = "t-" .. serial, at = GetServerTime(), target = "*",
        path = path or { me }, kind = kind, payload = payload, heardOn = heardOn }
end
local function capture(zone, side, at, wave)
    return ("%s:Somebody|WARRIOR:%s:%d:%s:Player-1"):format(zone, side, at, wave or "w1")
end
local function siege(zone, code, startAt, wave)
    return ("%s:in_progress:0:0:%s:%d:0:120:Somebody::%s"):format(zone, code, startAt, wave)
end
local function release(zone, wave) return ("%s:%s:Somebody"):format(zone, wave) end
local function distinct(list)
    local seen = {}
    for _, name in ipairs(list) do
        if seen[name] then return false end
        seen[name] = true
    end
    return true
end

-- 1. Our own capture: the first fan for thirty names, ten contacts, all different.
local stats = dir.stats
local now = GetServerTime()
local targets = dir:ChainTargets(packet("C", capture("elwynn_goldshire", "Alliance", now)), 1)
assert(targets and #targets == dir:FanFor(1) and #targets == 10 and distinct(targets), "own capture fan")
assert(stats.chainOwn == 1 and stats.chainWhispers == 10, "own capture counted")
-- Told already: the same capture again is not.
assert(dir:ChainTargets(packet("C", capture("elwynn_goldshire", "Alliance", now)), 1) == nil
    and stats.chainCovered == 1, "a capture told twice")
-- Too many fragments, or no chain (the channel carries): nothing.
assert(dir:ChainTargets(packet("C", capture("elwynn_eastvale", "Alliance", now)), 3) == nil, "three fragments")
active = false
assert(dir:ChainTargets(packet("C", capture("elwynn_eastvale", "Alliance", now)), 1) == nil, "chain while inactive")
active = true
-- Addressed packets never go along the chain.
local addressed = packet("C", capture("elwynn_eastvale", "Alliance", now))
addressed.target = contacts[1]
assert(dir:ChainTargets(addressed, 1) == nil, "an addressed packet went along the chain")

-- 2. Passed on: a whispered copy from a contact, the next fan, never back to the path.
local copy = packet("C", capture("elwynn_mirror_lake", "Alliance", now), { contacts[1], contacts[2], me }, "WHISPER")
targets = dir:ChainTargets(copy, 1)
assert(targets and #targets == dir:FanFor(3) and distinct(targets), "passed-on fan")
for _, name in ipairs(targets) do
    assert(name ~= contacts[1] and name ~= contacts[2], "whispered back to the path")
end
-- From a stranger (not a contact): not passed on.
local stranger = packet("C", capture("elwynn_fargodeep", "Alliance", now), { "Some Body", "Other Body", me }, "WHISPER")
assert(dir:ChainTargets(stranger, 1) == nil and stats.chainStranger == 1, "a stranger's copy passed on")

-- 3. A siege start, then its release by the same hands; a release without its start is not.
assert(dir:ChainTargets(packet("ZR", release("elwynn_ridgepoint", "w9")), 1) == nil, "a release without its start")
assert(dir:ChainTargets(packet("ZS", siege("elwynn_ridgepoint", "A", now, "w9")), 1), "own siege start")
assert(dir:ChainTargets(packet("ZS", siege("elwynn_ridgepoint", "A", now, "w9")), 1) == nil, "a start told twice")
assert(dir:ChainTargets(packet("ZR", release("elwynn_ridgepoint", "w9")), 1), "the release of a start")
assert(dir.chain.starts["elwynn_ridgepoint|w9"] == nil, "the start outlived its release")
-- The point may be told again at once: a new wave is a new start (once the tokens came back).
assert(dir.chain.tokens < 1, "the bucket should be empty here: " .. dir.chain.tokens)
assert(dir:ChainTargets(packet("ZS", siege("elwynn_ridgepoint", "A", now, "w10")), 1) == nil, "a start without tokens")
advance(20)
assert(dir:ChainTargets(packet("ZS", siege("elwynn_ridgepoint", "A", now, "w10")), 1), "a new wave after a release")

-- 4. Heard by a whole guild: a few of them speak, the same ones for one fact.
lane.PeerCount = function() return 40 end
dir.PER_MIN, dir.PER_GATEWAY = 1000, 1000
local spoke, leftBefore = 0, stats.chainLeft
for i = 1, 200 do
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local zone = "zone_" .. i
    local guildCopy = packet("C", capture(zone, "Alliance", now), { "Guild Mate", me }, "GUILD")
    if dir:ChainTargets(guildCopy, 1) then spoke = spoke + 1 end
end
-- Two speakers in forty: about ten facts in two hundred, the others left to them.
assert(spoke >= 3 and spoke <= 22 and stats.chainLeft - leftBefore == 200 - spoke, "speakers of a guild copy: " .. spoke)
-- The same ones for one fact: asked again, the same answer.
local again = dir:ChainTargets(packet("C", capture("zone_1", "Alliance", now + 1), { "Guild Mate", me }, "GUILD"), 1)
dir.PER_MIN, dir.PER_GATEWAY = 30, 8

-- 5. Caps: per gateway and per minute, whatever the tokens.
advance(61)
dir.CHAIN_BURST, dir.chain.tokens = 1000, 1000
local passed = 0
for i = 1, 20 do
    local burst = packet("C", capture("burst_" .. i, "Alliance", now), { contacts[3], contacts[4], me }, "WHISPER")
    if dir:ChainTargets(burst, 1) then passed = passed + 1 end
end
assert(passed == dir.PER_GATEWAY, "per gateway cap: " .. passed)
dir.CHAIN_BURST = 30
-- Tokens: an empty bucket stops the chain.
advance(61)
dir.chain.tokens, dir.chain.at = 0, clock
assert(dir:ChainTargets(packet("C", capture("elwynn_tower", "Alliance", now)), 1) == nil, "no tokens, no chain")
advance(60)
targets = dir:ChainTargets(packet("C", capture("elwynn_tower", "Alliance", now)), 1)
assert(targets and #targets == 10, "tokens refill")
-- Every fragment counts: a fact of two fragments costs two tokens per contact.
advance(60)
targets = dir:ChainTargets(packet("C", capture("elwynn_two_pages", "Alliance", now)), 2)
assert(targets and #targets == 10 and dir.chain.tokens < 11, "two fragments cost two tokens: " .. dir.chain.tokens)
-- One watch per wave.
local watchedZone = { id = "watched", capturedTime = 1 }
local watchedWave = { viaGuild = true, openedAt = clock, openedHold = 0, effectiveRequired = 120 }
assert(dir:WatchWave(watchedZone, watchedWave) and not dir:WatchWave(watchedZone, watchedWave), "a wave watched twice")

-- 6. Map news: passed on only by those who know its author up to date, or had it from a contact.
local function news(zone, ct, path, heardOn)
    return packet("ZA", ("@P-%d-1:1:1|%s:H:%d:%d"):format(ct, zone, ct, ct), path, heardOn)
end
lane.PeerCount = function() return 1 end
advance(60)
outdated["News Author"] = nil
assert(dir:ChainTargets(news("elwynn_one", now, { "News Author", "Guild Mate", me }, "GUILD"), 1) == nil
    and stats.chainUnvouched == 1, "map news of an unknown author passed on from the guild")
assert(dir:ChainTargets(news("elwynn_two", now, { "News Author", contacts[5], me }, "WHISPER"), 1),
    "map news vouched by a contact")
outdated["Old Author"] = true
assert(dir:ChainTargets(news("elwynn_three", now, { "Old Author", contacts[5], me }, "WHISPER"), 1) == nil,
    "map news of an author known out of date")
outdated["Known Author"] = false
assert(dir:ChainTargets(news("elwynn_four", now, { "Known Author", "Guild Mate", me }, "GUILD"), 1),
    "map news of an author known up to date")
-- Taken from an unknown author when a contact whispered it along the chain (Sync:OnReceiveZoneAll).
local single = ("@P-%d-1:1:1|elwynn_five:H:%d:%d"):format(now, now, now)
net.context = { origin = "News Author", gateway = contacts[6], transport = "WHISPER", targeted = false }
outdated[contacts[6]] = false
assert(dir:VouchesMapNews("News Author", single), "a contact's map news refused")
assert(net.context.vouched == true, "a vouched map news can confirm a flip")
-- A player who greeted us but is not in the member list is no contact.
dir.partners["off list"] = { name = "Off List", heardAt = clock, chainAt = clock }
net.context = { origin = "News Author", gateway = "Off List", transport = "WHISPER", targeted = false }
assert(not dir:IsContact("Off List") and not dir:VouchesMapNews("News Author", single),
    "a whisper outside the member list made a contact")
dir.names[#dir.names + 1] = "Off List"
assert(dir:IsContact("Off List"), "a contact found in the list read later")
dir.names[#dir.names] = nil
dir.partners["off list"] = nil
net.context = { origin = "News Author", gateway = contacts[6], transport = "WHISPER", targeted = false }
assert(not dir:VouchesMapNews("News Author", single .. ",elwynn_six:H:1:1"), "a map of two entries vouched")
assert(not dir:VouchesMapNews("Other Author", single), "vouched for another author than the packet's")
net.context.targeted = true
assert(not dir:VouchesMapNews("News Author", single), "an addressed map vouched")
net.context = { origin = "News Author", gateway = "Some Body", transport = "WHISPER", targeted = false }
assert(not dir:VouchesMapNews("News Author", single), "a stranger's map vouched")
net.context = { origin = "Old Author", gateway = contacts[6], transport = "WHISPER", targeted = false }
assert(not dir:VouchesMapNews("Old Author", single), "an author known out of date vouched")
net.context = { origin = "News Author", gateway = contacts[6], transport = "GUILD", targeted = false }
assert(not dir:VouchesMapNews("News Author", single), "a guild copy vouched")
net.context = nil

-- 7. A siege without ticks whose outcome did not reach us: one partner asked for its map, once.
local asked = {}
s.GetSRPayload = function() return "T" end
s.SendWhisper = function(_, kind, payload, target) asked[#asked + 1] = { kind = kind, target = target, at = clock } return true end
dir.PickPartner = function() return contacts[7] end
dir.BeforeMapPull = function() return false end
local askers = dir.GAP_ASKERS
dir.GAP_ASKERS, dir.GAP_ASKERS_FOLLOWED = 1000, 1000
local function wave(zone)
    local remote = { viaGuild = true, openedAt = clock, openedHold = 0, effectiveRequired = 120 }
    zone._remoteCaptureLease = remote
    zone.status = "in_progress"
    assert(dir:WatchWave(zone, remote), "a siege without ticks is watched")
    return remote
end
local followed = { id = "elwynn_followed", capturedTime = now - 3600 }
wave(followed)
advance(100)
assert(#asked == 0, "asked before the capture could be made")
advance(60)
assert(#asked == 1 and asked[1].kind == "SR" and asked[1].target == contacts[7], "no map asked after a silent siege")
assert(stats.gapPulls == 1, "gap pull counted")
-- Its capture came: nothing asked.
advance(60)
local captured = { id = "elwynn_captured", capturedTime = now - 3600 }
wave(captured)
advance(130)
captured._remoteCaptureLease, captured.status, captured.capturedTime = nil, "captured", GetServerTime()
advance(60)
assert(#asked == 1, "a map asked after the capture came")
-- Released (its end came another way): nothing asked.
advance(60)
local released = { id = "elwynn_released", capturedTime = now - 3600 }
local remote = wave(released)
advance(60)
released._remoteCaptureLease, released.status, remote.endedBy = nil, "captured", "relayedRelease"
advance(120)
assert(#asked == 1, "a map asked after a release")
-- Given up in silence (timed out, no capture since it began): asked.
advance(60)
local silent = { id = "elwynn_silent", capturedTime = now - 3600 }
remote = wave(silent)
advance(80)
silent._remoteCaptureLease, silent.status, remote.endedBy = nil, "captured", "timeout"
advance(120)
assert(#asked == 2, "no map asked after a siege given up in silence")
-- Two silent sieges at once: one question per GAP_MIN_SEC at most, the second one later.
advance(60)
local a, b = { id = "a", capturedTime = 1 }, { id = "b", capturedTime = 1 }
dir.GAP_SPREAD = 0
wave(a); wave(b)
advance(200)
assert(#asked == 4 and asked[4].at - asked[3].at >= dir.GAP_MIN_SEC, "two silent sieges: " .. #asked)
-- Sieges told and never ended cost GAP_BUDGET maps per GAP_WINDOW at most.
for i = 1, 8 do advance(40); wave({ id = "flood" .. i, capturedTime = 1 }); advance(80) end
local inWindow = 0
for _, question in ipairs(asked) do
    if clock - question.at < dir.GAP_WINDOW then inWindow = inWindow + 1 end
end
assert(inWindow <= dir.GAP_BUDGET, "silent sieges asked " .. inWindow .. " maps in one window")
-- Of a long list only about GAP_ASKERS ask about one siege, the same ones each time.
dir.GAP_ASKERS = askers
local budget = dir.GAP_BUDGET
dir.GAP_BUDGET = 1000
local tried = 0
for i = 1, 40 do
    local zone = { id = "herd" .. i, capturedTime = 1 }
    local remote = { viaGuild = true, endedBy = "timeout" }
    advance(31)
    if dir:PullAfterWave(zone, remote, 1000) then tried = tried + 1 end
end
assert(tried >= 1 and tried <= 15, "followers asking about silent sieges: " .. tried .. " of 40")
dir.GAP_BUDGET = budget

-- A failed siege handed back by its author (another side's code, the author's own name) is not
-- passed on; a Battle.net copy of that kind is the other side's capture.
local handback = ("elwynn_back:captured:0:0:H:%d:0:120:%s::w77"):format(now, me)
assert(dir:ChainTargets(packet("ZS", handback), 1) == nil, "a handback went along the chain")
local relayedBack = ("elwynn_back2:captured:0:0:H:%d:0:120:%s::w78"):format(now, contacts[8])
advance(60)
assert(dir:ChainTargets(packet("ZS", relayedBack, { contacts[8], me }, "WHISPER"), 1) == nil,
    "a relayed handback went along the chain")

-- Our kill total: first-hand to RANK_FAN contacts, one per RANK_GAP, never from the reserve, and
-- never passed on.
advance(120)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local kill = packet("K", "Me|elwynn|12|WARRIOR|Alliance")
local ranked = dir:ChainTargets(kill, 1)
assert(ranked and #ranked == dir.RANK_FAN and distinct(ranked), "our kill total did not leave")
assert(dir:ChainTargets(packet("K", "Me|elwynn|13|WARRIOR|Alliance"), 1) == nil, "two kill totals within RANK_GAP")
-- A newer total replacing one still queued takes its whispers over, nothing spent again.
local tokensBefore = dir.chain.tokens
local retake = packet("K", "Me|elwynn|13|WARRIOR|Alliance")
retake.chainRetake = true
local again = dir:ChainTargets(retake, 1)
assert(again and #again == #ranked and dir.chain.tokens == tokensBefore, "a queued kill total lost its whispers")
-- A contact that went offline ("no player named") is no contact until it greets us again.
assert(dir:NoteUnreachable(contacts[30]) and not dir:IsContact(contacts[30]), "an unreachable contact kept")
dir.partners[contacts[30]:lower()].chainAt = clock
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.RANK_RESERVE + dir.RANK_FAN - 1, clock
assert(dir:ChainTargets(packet("K", "Me|elwynn|14|WARRIOR|Alliance"), 1) == nil, "a kill total took the reserve")
dir.chain.tokens = dir.CHAIN_BURST
assert(dir:ChainTargets(packet("K", "X|elwynn|9|MAGE|Alliance", { "X Author", contacts[3], me }, "WHISPER"), 1) == nil,
    "a kill total passed on")

-- Someone else's capture of a point that is not ours, or dated far from now, is not passed on.
advance(60)
assert(dir:ChainTargets(packet("C", capture("nowhere", "Alliance", now), { contacts[9], me }, "WHISPER"), 1) == nil,
    "a capture of an unknown point passed on")
assert(dir:ChainTargets(packet("C", capture("far_date", "Alliance", now + 5000), { contacts[9], me }, "WHISPER"), 1) == nil,
    "a capture dated far from now passed on")

-- 8. Siege copies whispered along the chain count as heard without ticks (GuildLane:HeardHere).
net.context = { transport = "WHISPER", targeted = false, gateway = contacts[2] }
assert(lane:HeardHere(), "a whispered broadcast is not heard here")
net.context = { transport = "WHISPER", targeted = false, gateway = "Some Body" }
assert(not lane:HeardHere(), "a stranger's whisper is heard here without ticks")
net.context = { transport = "WHISPER", targeted = true }
assert(not lane:HeardHere(), "an addressed whisper is heard here")
net.context = nil

-- 9. 2.2.2: players that greeted us outside our list get a few copies (leaves), never our total;
-- fights (FK) ride the chain within their own cap and keep the tokens of captures; a fact capped
-- by the tokens costs nothing of the minute's intake.
advance(120)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local leafNames = { "Leaf Una", "Leaf Duo", "Leaf Tria" }
for _, name in ipairs(leafNames) do dir.partners[name:lower()] = { name = name, heardAt = clock, chainAt = clock } end
local function isLeaf(name)
    for _, leaf in ipairs(leafNames) do if leaf == name then return true end end
    return false
end
targets = dir:ChainTargets(packet("C", capture("leaf_point", "Alliance", now)), 1)
local leafCount = 0
for _, name in ipairs(targets or {}) do if isLeaf(name) then leafCount = leafCount + 1 end end
assert(targets and #targets == 10 + dir.LEAF_FANS and leafCount == dir.LEAF_FANS,
    "contacts then leaves: " .. #(targets or {}) .. ", leaves " .. leafCount)
-- 2.3.0: a leaf's own fact is passed on (a player out of the lists starts a siege alone); what a
-- leaf passes on for somebody else is a stranger's copy.
local fromLeaf = packet("C", capture("elwynn_mirror_lake", "Alliance", GetServerTime()), { "Leaf Una", me }, "WHISPER")
local strangers = stats.chainStranger
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
assert(dir:ChainTargets(fromLeaf, 1) and stats.chainStranger == strangers, "a leaf's own fact was not passed on")
local leafRelay = packet("C", capture("elwynn_fargodeep", "Alliance", GetServerTime() + 1), { "Some Author", "Leaf Una", me }, "WHISPER")
assert(dir:ChainTargets(leafRelay, 1) == nil and stats.chainStranger == strangers + 1,
    "a leaf's copy of somebody else's fact passed on")
local unknown = packet("C", capture("elwynn_fargodeep", "Alliance", GetServerTime() + 2), { "Never Greeted", me }, "WHISPER")
assert(dir:ChainTargets(unknown, 1) == nil and stats.chainStranger == strangers + 2,
    "a whisper of somebody who never greeted us passed on")
-- Fights: FK_PER_MIN brackets a minute, and never below FK_RESERVE tokens.
advance(61)
dir.CHAIN_BURST, dir.chain.tokens, dir.chain.at = 1000, 1000, clock
local fights = 0
for i = 1, dir.FK_PER_MIN + 4 do
    if dir:ChainTargets(packet("FK", "bracket" .. i .. ":elwynn:3:2", { "Guild Mate", me }, "GUILD"), 1) then
        fights = fights + 1
    end
end
assert(fights == dir.FK_PER_MIN, "fights passed on per minute: " .. fights)
-- Our own front's fight still leaves once the minute is full of others'.
assert(dir:ChainTargets(packet("FK", "bracket_own:elwynn:3:2"), 1), "our own fight capped by the forwards")
-- Guild rampages (GW): only one GuildKillAlert would show, once per guild every GW_COVER_SEC, and
-- GW_PER_MIN passed on a minute on their own count.
if not Overlord.GuildKillAlert then assert(loadfile("GuildKillAlert.lua"))() end
local gwAt = GetServerTime()
assert(dir:ChainTargets(packet("GW", "1:Some Guild:H:12:5:::" .. gwAt), 1) == nil, "a rampage below the threshold rides the chain")
assert(dir:ChainTargets(packet("GW", "1:Some Guild:H:40:8:::" .. (gwAt - 900)), 1) == nil, "an old rampage rides the chain")
local rampage = dir:ChainTargets(packet("GW", "1:Some Guild:H:40:8:::" .. gwAt), 1)
assert(rampage and #rampage <= dir.FK_FAN + dir.LEAF_FANS, "a rampage does not ride the chain within the fights' fan")
assert(dir:ChainTargets(packet("GW", "1:some guild:H:60:9:::" .. gwAt), 1) == nil, "the same guild's rampage told twice")
local rampages = 0
for i = 1, dir.GW_PER_MIN + 3 do
    if dir:ChainTargets(packet("GW", "1:Guild " .. string.char(64 + i) .. ":H:40:8:::" .. gwAt, { "Guild Mate", me }, "GUILD"), 1) then
        rampages = rampages + 1
    end
end
assert(rampages == dir.GW_PER_MIN, "rampages passed on per minute: " .. rampages)
assert(dir:ChainTargets(packet("FK", "bracket_after_gw:elwynn:3:2", { "Guild Mate", me }, "GUILD"), 1) == nil,
    "the fights' minute is not full any more")
dir.CHAIN_BURST = 30
advance(61)
dir.chain.tokens, dir.chain.at = dir.FK_RESERVE, clock
assert(dir:ChainTargets(packet("FK", "bracket_reserve:elwynn:3:2"), 1) == nil, "a fight spent the reserve")
assert(dir:ChainTargets(packet("C", capture("reserve_point", "Alliance", now)), 1), "a capture still goes")
-- Capped by the tokens: the gateway's intake is not spent.
advance(61)
dir.chain.tokens, dir.chain.at = 0, clock
local starved = packet("C", capture("starved_point", "Alliance", GetServerTime()), { contacts[5], me }, "WHISPER")
local unvouched = stats.chainUnvouched
assert(dir:ChainTargets(starved, 1) == nil and stats.chainUnvouched == unvouched, "no tokens, no chain")
local intake = dir.chain.intake[contacts[5]:lower()]
assert(not intake or intake.count == 0, "a capped fact spent the intake: " .. tostring(intake and intake.count))
assert(dir.chain.minute.count == 0, "a capped fact spent the minute: " .. dir.chain.minute.count)
-- Said offline: no copies until it greets again.
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
for _, name in ipairs(leafNames) do dir.partners[name:lower()] = nil end
for i = 1, 25 do dir.partners[contacts[i]:lower()].unreachableUntil = clock + 100 end
targets = dir:ChainTargets(packet("C", capture("offline_point", "Alliance", now)), 1)
for _, name in ipairs(targets or {}) do
    assert((dir.partners[name:lower()].unreachableUntil or 0) <= clock, "an offline contact got a copy: " .. name)
end
for i = 1, 25 do dir.partners[contacts[i]:lower()].unreachableUntil = nil end

-- 2.2.2: a release goes to the hands its start went to; our own total also goes to the rampage
-- collectors of the guild (the same two mates for every member), inside the same fan.
do
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    dir.chain.cover, dir.chain.starts, dir.chain.rankAt, dir.chain.minute = {}, {}, nil, { at = -1000, count = 0 }
    dir.chain.intake = {}
    local started = GetServerTime()
    local first = dir:ChainTargets(packet("ZS", siege("pin_point", "A", started, "wpin")), 1)
    assert(first and #first == 10, "the start of the pinned release")
    advance(30)
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local second = dir:ChainTargets(packet("ZR", release("pin_point", "wpin")), 1)
    assert(second and #second >= #first, "the release of the pinned start")
    local told = {}
    for _, name in ipairs(second) do told[name] = true end
    for _, name in ipairs(first) do assert(told[name], name .. " heard the start and not its release") end
    -- A forwarder passes the release to the contacts it passed the start to.
    local viaHand = packet("ZS", siege("pin_other", "A", GetServerTime(), "wpin2"), { contacts[1], me }, "WHISPER")
    local passed = dir:ChainTargets(viaHand, 1)
    assert(passed and #passed > 0, "a start passed on")
    advance(30)
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local back = dir:ChainTargets(packet("ZR", release("pin_other", "wpin2"), { contacts[1], me }, "WHISPER"), 1)
    local backTold = {}
    for _, name in ipairs(back or {}) do backTold[name] = true end
    for _, name in ipairs(passed) do assert(backTold[name], name .. " got the start from us and not the release") end

    -- Rampage collectors.
    function GetGuildInfo() return "Test Guild" end
    local mates, collectors = {}, {}
    lane.peers = {}
    for i = 1, 8 do
        local name = "Mate " .. string.char(64 + i) .. "x"
        mates[i] = name
        lane.peers[name:lower()] = clock
        net.peers[name:lower()] = { name = name, at = clock, hops = 1 }
        dir.partners[name:lower()] = { name = name, heardAt = clock }
    end
    lane.PeerCount = function() return 8 end
    local ranked = { { me:lower(), net.HashFrac("test guild|" .. me:lower()) } }
    for _, name in ipairs(mates) do ranked[#ranked + 1] = { name:lower(), net.HashFrac("test guild|" .. name:lower()) } end
    table.sort(ranked, function(a, b) return a[2] < b[2] end)
    for i = 1, dir.RAMPAGE_COLLECTORS do
        if ranked[i][1] ~= me:lower() then collectors[ranked[i][1]] = true end
    end
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local own = dir:ChainTargets(packet("K", "total"), 1)
    assert(own and #own == dir.RANK_FAN and distinct(own), "a total goes to the usual fan: " .. tostring(own and #own))
    local got = {}
    for _, name in ipairs(own) do got[name:lower()] = true end
    local expected = 0
    for key in pairs(collectors) do
        expected = expected + 1
        assert(got[key], key .. " is a collector and heard no total")
    end
    assert(expected >= 1, "no collector was drawn")
    assert(stats.chainRampage >= expected, "the collectors are not counted")
    -- The same two for the next total (a guild mate draws the same).
    advance(31)
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local again = dir:ChainTargets(packet("K", "total 2"), 1)
    local gotAgain = {}
    for _, name in ipairs(again or {}) do gotAgain[name:lower()] = true end
    for key in pairs(collectors) do assert(gotAgain[key], key .. " is not a collector any more") end
    -- Too few mates for a rampage: the fan is the contacts' alone.
    lane.PeerCount = function() return 2 end
    advance(31)
    dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
    local small = dir:ChainTargets(packet("K", "total 3"), 1)
    for _, name in ipairs(small or {}) do assert(not name:find("^Mate "), "a mate heard a total of a guild too small for a rampage") end
    lane.PeerCount = function() return 40 end
end

-- 10. Our own fight bracket already told (covered): the chain takes it, so FrontActivity does not
-- send its report again.
do
    advance(61)
    dir.CHAIN_BURST, dir.chain.tokens, dir.chain.at = 1000, 1000, clock
    assert(dir:ChainTargets(packet("FK", "bracket_cover:elwynn:3:2"), 1), "our own fight did not go the first time")
    dir.ownFKTaken = nil
    assert(dir:ChainTargets(packet("FK", "bracket_cover:elwynn:3:2"), 1) == nil, "a fight told twice went along twice")
    assert(dir.ownFKTaken and dir.ownFKTaken["bracket_cover:elwynn:3:2"],
        "a covered fight of ours was not marked as taken")
    -- Somebody else's covered copy is not ours to mark.
    dir.ownFKTaken = nil
    assert(dir:ChainTargets(packet("FK", "bracket_cover:elwynn:3:2", { "Guild Mate", me }, "GUILD"), 1) == nil)
    assert(not (dir.ownFKTaken and dir.ownFKTaken["bracket_cover:elwynn:3:2"]), "a forwarded fight was marked as ours")
end

-- 11. 2.3.0: a fight bracket passed on for others that a fresher one known here covers
-- (FrontActivity:CoversRelayedBracket) is not passed on and spends nothing of the fights' minute;
-- our own bracket is never checked against the brackets heard.
do
    advance(61)
    dir.CHAIN_BURST, dir.chain.tokens, dir.chain.at = 1000, 1000, clock
    local covered, asked = { ["1:elwynn:10:5"] = true, ["1:elwynn:5:9"] = true }, {}
    local savedFA = Overlord.FrontActivity
    Overlord.FrontActivity = { CoversRelayedBracket = function(_, payload)
        asked[payload] = true
        return covered[payload] == true
    end }
    local coveredBefore = stats.chainCovered
    assert(dir:ChainTargets(packet("FK", "1:elwynn:10:5", { contacts[21], me }, "WHISPER"), 1) == nil,
        "a covered fight bracket was passed on")
    assert(stats.chainCovered == coveredBefore + 1, "a covered fight bracket was not counted as covered")
    local passed = 0
    for i = 1, dir.FK_PER_MIN do
        if dir:ChainTargets(packet("FK", "1:elwynn:20:" .. (5 + i), { contacts[21 + i], me }, "WHISPER"), 1) then
            passed = passed + 1
        end
    end
    assert(passed == dir.FK_PER_MIN, "a covered bracket spent the fights' minute: " .. passed)
    assert(dir:ChainTargets(packet("FK", "1:elwynn:5:9"), 1), "our own fight bracket was held back")
    assert(not asked["1:elwynn:5:9"], "our own fight bracket was checked against the brackets heard")
    Overlord.FrontActivity = savedFA
end

-- 12. 2.3.0: a fight bracket passed on reaches five contacts: the relay's four names allow three hands
-- after the author, and hands of four (1 + 4 + 16 + 64 = 85) could never cover a 93-player list.
do
    advance(61)
    dir.CHAIN_BURST, dir.chain.tokens, dir.chain.at = 1000, 1000, clock
    local fan = dir:ChainTargets(packet("FK", "1:elwynn:30:12", { contacts[21], me }, "WHISPER"), 1)
    assert(fan and #fan == 5, "a passed-on fight bracket reached " .. tostring(fan and #fan) .. " contacts, not 5")
end

print("Directory chain: fans, cover, start and release, guild speakers, caps, tokens, vouched map news, "
    .. "silent sieges, leaves, fights, intake, offline contacts OK")
