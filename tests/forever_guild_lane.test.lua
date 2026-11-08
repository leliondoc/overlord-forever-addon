-- 2.1.1: the channel refused by the server, and the guild standing in for it.
-- Real relay, real lane, real SendAddonChecked: only the game's SendAddonMessage is a stub.
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
local clock = 1000
function GetTime() return clock end
-- (Later than the capture dates used below.)
function GetServerTime() return 1790018000 end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncGuild.lua"))()
local net, lane = Overlord.Relay, Overlord.GuildLane
assert(lane, "SyncGuild.lua did not load")
net.BridgeChannelHold = { 0, 0 }
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Alliance"
local instanced, inGuild, grouped = false, true, false
function IsInInstance() return instanced end
function IsInGuild() return inGuild end
function IsInGroup() return grouped end
function IsInRaid() return false end
s.GetBetaBNetTargets = function() return {} end
local me = s:GetPlayerFullName()
assert(type(me) == "string" and me:find(" ", 1, true), "fixture: a Forever name is expected")
local PREFIX = "OverlordF"

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

local sent, channelCode, guildCode, serverRefuses = {}, 0, 0, false
local refuse
C_ChatInfo = C_ChatInfo or {}
C_ChatInfo.SendAddonMessage = function(_, msg, chatType, target)
    sent[#sent + 1] = { msg = msg, chatType = chatType, target = target, at = clock }
    if chatType == "CHANNEL" then
        if serverRefuses then C_Timer.After(0.5, refuse) end
        return channelCode
    end
    if chatType == "GUILD" then return guildCode end
    return 0
end
local function count(chatType, marker)
    local n = 0
    for _, row in ipairs(sent) do
        if row.chatType == chatType and (not marker or row.msg:find(marker, 1, true)) then n = n + 1 end
    end
    return n
end
local function resetLane()
    -- Whatever is on its way ends first (the relay's pump keeps its own timer).
    channelCode, guildCode, instanced, inGuild, grouped, serverRefuses = 0, 0, false, true, false, false
    Overlord.InstanceSuspended = false
    s._channelRefusedAt, s._channelRefusedWhy, s._channelLastRefusalAt = nil, nil, nil
    lane.outbox = {}
    lane.generation = (lane.generation or 0) + 1
    lane.probeGeneration = (lane.probeGeneration or 0) + 1
    OverlordDB.guildLaneOff = nil
    advance(1000)
    sent = {}
    lane.outbox, lane.awaiting, lane.peers, lane.cover, lane.ownCover, lane.log = {}, {}, {}, {}, {}, {}
    lane.tokens, lane.tokensAt, lane.lastSendAt, lane.lastEchoAt, lane.lastEchoDelay = nil, nil, nil, nil, nil
    lane.lastPresenceAt, lane.presenceFactor, lane.peerCountAt, lane.peerCountValue = nil, nil, nil, nil
    lane.armedAt, lane.notJoinedSince, lane.noGuildUntil, lane.coverCount = nil, nil, nil, nil
    lane.relayedTokens, lane.relayedTokensAt, lane.relayedJitter = nil, nil, nil
    lane.spoken, lane.coverDate, lane.intake, lane.released = {}, {}, {}, {}
    for key in pairs(lane.stats) do lane.stats[key] = 0 end
    s._channelSilence, s._channelHeardAt = nil, nil
end
refuse = function() s:OnChannelNotice("NOT_ALLOWED_IN_CHANNEL", "", "", "5. " .. s:GetChannelBaseName()) end
-- As live: every message that reaches the channel, the probe included, is answered by a refusal.
local function refused()
    serverRefuses = true
    refuse()
end

-- Wire of a packet somebody else says, as it travels.
local serial = 0
local function wireOf(kind, payload, origin, path, target)
    serial = serial + 1
    local id = "t" .. serial .. "-1"
    return id, table.concat({ Overlord.RealmPools:GetOverlordPoolTag(), id, tostring(GetServerTime()), target or "*",
        path or origin, kind, payload }, "|")
end
local function hear(kind, payload, origin, path, target)
    local id, wire = wireOf(kind, payload, origin, path, target)
    local last = path and path:match("[^,]+$") or origin
    s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "GUILD", last)
    return id
end
local function hearPresence(name)
    return hear("NH", tostring(Overlord.Version) .. "~t0~y1~m0~o0~z0000000~l9~ld~lr~lp6", name)
end
-- Our own broadcast, offered at once (the pump's budget is not the subject here).
local function packet(kind, payload, id)
    serial = serial + 1
    return { region = "x", id = id or ("own" .. serial .. "-1"), at = GetServerTime(), target = "*",
        path = { me }, kind = kind, payload = payload }
end
local function offer(kind, payload, id)
    local p = packet(kind, payload, id)
    return lane:Offer(p, { p.id .. ":1:1:" .. kind }), p
end
local function capture(zone, faction, stamp)
    return (zone or "elwynn_goldshire") .. ":Dwarf Tester|PRIEST:" .. (faction or "Alliance") .. ":"
        .. tostring(stamp or 1790017000) .. ":w1:Player-1-1:300"
end
-- As BroadcastZoneState writes it. A final names its wave; no wave: a point handed back.
local function zoneState(status, zone, code, hold, wave)
    return (zone or "elwynn_goldshire") .. ":" .. status .. ":0:" .. tostring(hold or 30) .. ":" .. (code or "A")
        .. ":1790017000:0:120:Dwarf Tester:0:" .. (wave or "w1") .. ":Player-1-1:120"
end

-- ---------------------------------------------------------------------------
-- (1) The channel
-- ---------------------------------------------------------------------------
resetLane()
assert(s:GetChannelId() == 5 and s:GetJoinedChannelId() == 5 and not s:IsChannelClosed(), "fixture: channel open")
-- A notice of another channel, another kind of notice: nothing.
s:OnChannelNotice("NOT_ALLOWED_IN_CHANNEL", "", "", "3. Commerce", "", "", 0, 3, "Commerce")
s:OnChannelNotice("THROTTLED", "", "", "5. " .. s:GetChannelBaseName())
assert(s._channelRefusedAt == nil, "a foreign channel or a throttle counted as a refusal")
-- Secret values: never compared, never a verdict.
local realAccess = canaccessvalue
canaccessvalue = function(value) return value ~= "SECRET" end
s:OnChannelNotice("SECRET", "", "", "5. " .. s:GetChannelBaseName())
s:OnChannelNotice("NOT_ALLOWED_IN_CHANNEL", "", "", "SECRET", "", "", "SECRET", "SECRET", "SECRET")
assert(s._channelRefusedAt == nil, "a secret value gave a verdict")
canaccessvalue = realAccess
-- Our channel, however the notice names it.
refuse()
assert(s._channelRefusedAt == clock and s:GetChannelId() == nil and s:GetJoinedChannelId() == 5 and s:IsChannelClosed(),
    "the refusal must take the channel away from every sender")
resetLane()
s:OnChannelNotice("NOT_ALLOWED_IN_CHANNEL", "", "", nil, "", "", 0, 5, nil)
assert(s._channelRefusedAt ~= nil, "a notice with only the channel number was missed")
resetLane()
s:OnChannelNotice("NOT_ALLOWED_IN_CHANNEL", "", "", "", "", "", 0, 2, s:GetChannelBaseName():lower())
assert(s._channelRefusedAt ~= nil, "a notice with the base name was missed")
-- Code 7 says the same, at once. Another refusal code does not.
resetLane()
channelCode = 8
s:SendAddonChecked("x", "CHANNEL", 5)
assert(s._channelRefusedAt == nil, "a channel throttle counted as a refusal")
channelCode = 7
s:SendAddonChecked("x", "CHANNEL", 5)
assert(s._channelRefusedAt ~= nil and s._channelRefusedWhy == "code 7" and s:GetChannelId() == nil, "code 7 was not taken")
print("Guild lane: refusals by notice and code 7; foreign, secret and throttle notices ignored")

-- Nothing goes to the channel any more; the probe is the only message.
resetLane()
refuse()
sent = {}
assert(s:SendToChannel("TEST", "x") == false, "SendToChannel must see no channel")
assert(s:SendBridgeLKToChannel("x") == false, "the bridge must see no channel, hence its whisper fallback")
advance(299)
assert(count("CHANNEL") == 0, "a message reached a refused channel")
advance(2)
assert(count("CHANNEL") == 1 and sent[#sent].msg == "PB" and sent[#sent].target == 5, "no probe after five minutes")
-- The server still refuses: the notice comes back within a second.
advance(1); refuse(); advance(10)
assert(s._channelRefusedAt ~= nil, "the channel reopened on a refused probe")
-- Next probe, nothing comes back: taken back, and no further probe.
advance(340)
assert(count("CHANNEL") == 2, "no second probe")
assert(s._channelRefusedAt == nil and s:GetChannelId() == 5 and not s:IsChannelClosed(), "the channel never reopened")
assert(lane.stats.reopened == 1)
advance(1000)
assert(count("CHANNEL") == 2, "a probe after the channel came back")

-- A refused probe by code: stays refused, keeps probing.
resetLane()
refuse()
channelCode = 7
advance(301)
advance(10)
assert(s._channelRefusedAt ~= nil, "a probe answered by code 7 reopened the channel")
channelCode = 8
advance(400)
assert(s._channelRefusedAt ~= nil, "a throttled probe reopened the channel")
-- The own copy back on the channel: open at once. Somebody else: only "not silent".
resetLane()
refuse()
s:OnAddonMessage(PREFIX, "PB", "CHANNEL", "Bob Tester")
assert(s._channelRefusedAt ~= nil, "somebody else's message cannot reopen for us")
s:OnAddonMessage(PREFIX, "PB", "CHANNEL", me)
assert(s._channelRefusedAt == nil and s:GetChannelId() == 5, "our own copy back must reopen the channel")
-- No probe inside an instance, and one soon after leaving it.
resetLane()
refuse()
instanced = true
advance(301)
assert(count("CHANNEL") == 0, "a probe left inside an instance")
s:OnNetworkSuspend()
instanced = false
s:OnNetworkResume()
advance(19)
assert(count("CHANNEL") == 0)
local waited = 19
while count("CHANNEL") == 0 and waited < 41 do advance(1); waited = waited + 1 end
assert(count("CHANNEL") == 1 and s._channelRefusedAt ~= nil, "no probe after leaving the instance")
advance(lane.PROBE_WAIT + 1)
assert(s._channelRefusedAt == nil, "the probe after an instance did not take the channel back")
-- A probe that was on its way when the instance began says nothing.
resetLane()
refuse()
advance(301)
assert(count("CHANNEL") == 1)
instanced = true
advance(lane.PROBE_WAIT + 1)
assert(s._channelRefusedAt ~= nil, "silence inside an instance reopened the channel")
-- A refusal that takes its time still counts: the channel is not taken back in the meantime.
resetLane()
refuse()
advance(301)
assert(count("CHANNEL") == 1)
advance(10)
assert(s._channelRefusedAt ~= nil and lane.stats.reopened == 0, "the channel was taken back before the refusal could come")
refuse()
advance(lane.PROBE_WAIT + 1)
assert(s._channelRefusedAt ~= nil and lane.stats.reopened == 0, "a refusal ten seconds late did not count")
print("Guild lane: probe every five minutes, reopening, refused probes, instances")

-- Silent: accepted, not refused, and nobody for five minutes.
resetLane()
for _ = 1, 3 do s:SendAddonChecked("x", "CHANNEL", 5) end
assert(not s:IsChannelSilent(), "silent at once")
advance(299)
assert(not s:IsChannelSilent(), "silent before five minutes")
advance(2)
assert(s:IsChannelSilent(), "five minutes of talking to nobody must count as silent")
assert(lane:IsActive(), "the guild takes over on a silent channel")
assert(s:GetChannelId() == 5, "a silent channel stays in use: somebody may yet come")
s:OnAddonMessage(PREFIX, "XX:1", "CHANNEL", "Bob Tester")
assert(not s:IsChannelSilent() and not lane:IsActive(), "anybody heard ends the silence")
advance(301)
assert(not s:IsChannelSilent(), "silence needs sends of its own")
for _ = 1, 3 do s:SendAddonChecked("x", "CHANNEL", 5) end
advance(301)
assert(s:IsChannelSilent(), "a new silence after a heard message")

-- Not joined: a join still running is no verdict.
resetLane()
GetChannelName = function() return 0 end
assert(not lane:IsActive(), "a join still running counted as down")
advance(59)
assert(not lane:IsActive())
advance(2)
assert(lane:IsActive(), "not joined for a minute counts as down")
GetChannelName = function() return 5 end
assert(not lane:IsActive() and lane.notJoinedSince == nil, "joined again: not down")
print("Guild lane: silent channel, not joined")

-- ---------------------------------------------------------------------------
-- (2) When the guild is used, and for what
-- ---------------------------------------------------------------------------
resetLane()
refused()
assert(lane:IsActive())
inGuild = false; assert(not lane:IsActive(), "active without a guild"); inGuild = true
instanced = true; assert(not lane:IsActive(), "active in an instance"); instanced = false
Overlord.InstanceSuspended = true; assert(not lane:IsActive(), "active while suspended"); Overlord.InstanceSuspended = false
Overlord.RelayEnabled = false; assert(not lane:IsActive(), "active with the relay off"); Overlord.RelayEnabled = true
lane:SetSwitchedOff(true); assert(not lane:IsActive() and OverlordDB.guildLaneOff == true, "switched off is off")
lane:SetSwitchedOff(false); assert(lane:IsActive() and OverlordDB.guildLaneOff == nil, "and on again")

local own, other = { me }, { "Bob Tester", me }
local LEVELS = {
    { "C", capture(), own, 3 }, { "C", capture(), other, 3 },
    { "ZR", "z:w:n", own, nil }, { "ZR", "z:w:n", other, 3 },
    { "TV", "x", other, 3 }, { "GE", "x", own, 3 }, { "GX", "x", own, 3 },
    { "GD", "x", other, 3 }, { "FC", "x", own, 2 }, { "FC", "x", other, 2 },
    { "ZS", zoneState("captured"), own, 3 }, { "ZS", zoneState("captured"), other, 3 },
    { "ZS", zoneState("captured", nil, nil, nil, ""), own, nil }, { "ZS", zoneState("captured", nil, nil, nil, ""), other, nil },
    { "ZS", zoneState("available"), own, nil }, { "ZS", zoneState("locked"), own, nil },
    { "ZS", zoneState("available"), other, nil },
    { "ZS", zoneState("in_progress", nil, nil, 30), own, 2 }, { "ZS", zoneState("in_progress", nil, nil, 45), own, 2 },
    { "ZS", zoneState("in_progress", nil, nil, 46), own, nil }, { "ZS", zoneState("other"), own, nil },
    { "NH", "2.1.1", own, 1 }, { "NH", "2.1.1", other, nil },
    { "OC", "x", own, 3 }, { "OC", "x", other, nil }, { "GW", "x", own, 1 }, { "GW", "x", other, nil },
    { "OP", "v1:site:in_progress:x", own, 1 }, { "OP", "v1:site:captured:x", own, nil },
    { "ZA", "@P-1-2:1:1|x", own, 1 }, { "ZA", "@P-1-2:1:1|x", other, nil }, { "ZA", "@P-1-2:1:2|x", own, nil },
    { "ZA", "G:1:1:x", own, nil },
    { "SR", "x", own, nil }, { "K", "x", own, nil }, { "EK", "x", own, nil }, { "FK", "x", own, nil }, { "MN", "x", own, nil },
    { "MS", "x", own, nil }, { "SH", "x", own, nil }, { "GI", "x", own, nil }, { "GR", "x", own, nil }, { "GY", "x", own, nil },
    { "CR", "x", own, nil }, { "CA", "x", own, nil }, { "LK", "x", own, nil }, { "LC", "x", own, nil }, { "LR", "x", own, nil },
    { "LO", "x", own, nil }, { "LOC", "x", own, nil }, { "VB", "x", own, nil }, { "VT", "x", own, nil }, { "VF", "x", own, nil },
    { "FR", "x", own, nil }, { "GP", "x", own, nil }, { "GM", "x", own, nil }, { "HR", "x", own, nil }, { "HB", "x", own, nil },
    { "HA", "x", own, nil },
}
for _, row in ipairs(LEVELS) do
    local got = lane:Level({ kind = row[1], payload = row[2], path = row[3] })
    assert(got == row[4], string.format("level of %s %s (%d hops): %s", row[1], row[2], #row[3], tostring(got)))
end
local broadcast = { kind = "C", payload = capture(), path = own, target = "*" }
assert(lane:Carries(broadcast, 2), "a capture must be carried")
assert(not lane:Carries(broadcast, 3), "three fragments are too many")
assert(not lane:Carries({ kind = "C", payload = capture(), path = own, target = "Bob Tester" }, 1), "an addressed packet stays out")
assert(not lane:Carries({ kind = "C", payload = capture(), path = own, target = "*", skipGuild = true }, 1), "heard there, never said there")
assert(not lane:Carries({ kind = "C", payload = capture(), path = own, target = "*", groupOnly = true }, 1), "a group copy stays out")
-- One fact, one key.
local keyC = lane:CoverKey({ kind = "C", payload = capture(), path = own })
local keyZ = lane:CoverKey({ kind = "ZS", payload = zoneState("captured"), path = own })
assert(keyC and keyC == keyZ, "a capture and its final state must share a key: " .. tostring(keyC) .. " / " .. tostring(keyZ))
assert(lane:CoverKey({ kind = "C", payload = capture(nil, "Horde"), path = own }) ~= keyC, "the two factions' captures differ")
assert(lane:CoverKey({ kind = "C", payload = capture("elwynn_other"), path = own }) ~= keyC, "two zones differ")
assert(lane:CoverKey({ kind = "NH", payload = "x", path = own }) == nil, "a presence is nobody else's to say")
print("Guild lane: conditions, levels, one key per fact")

-- ---------------------------------------------------------------------------
-- (3) The relay: nothing changes while the channel works
-- ---------------------------------------------------------------------------
resetLane()
assert(net:Send("C", capture("elwynn_a")), "the capture was not queued")
advance(10)
assert(count("CHANNEL") >= 1 and count("GUILD") == 0, "the guild was used with a working channel")
assert(net:Send("NH", "x1"), "the presence was not queued")
advance(10)
assert(count("GUILD") == 0, "a presence went to the guild with a working channel")

-- Channel refused, somebody heard in the guild: a capture crosses, the channel stays quiet.
resetLane()
refused()
hearPresence("Bob Tester")
assert(lane:PeerCount() == 1, "the guild mate was not counted")
assert(net:Send("C", capture("elwynn_b")), "the capture was not queued")
advance(10)
assert(count("GUILD", "elwynn_b") == 1, "the capture did not reach the guild")
assert(count("CHANNEL", "elwynn_b") == 0, "the capture went to a refused channel")
local row = sent[#sent]
assert(row.msg:sub(1, 3) == "BF:" and #row.msg <= 255, "a guild message is one relay fragment")
-- A presence goes too, then waits its turn.
resetLane()
refused()
hearPresence("Bob Tester")
assert(net:Send("NH", "x2"), "the presence was not queued")
advance(10)
assert(count("GUILD", "NH") == 1, "the presence did not reach the guild")
assert(net:Send("NH", "x3"), "the second presence was not queued")
advance(10)
assert(count("GUILD", "NH") == 1, "the second presence ignored its spacing")
advance(120)
assert(net:Send("NH", "x4"), "the third presence was not queued")
advance(10)
assert(count("GUILD", "NH") == 2, "the presence did not come back after its gap")
print("Guild lane: nothing with a working channel; captures and presence without")

-- Alone in the guild: the presence alone goes out, rarely.
resetLane()
refused()
assert(net:Send("C", capture("elwynn_c")), "the capture was not queued")
advance(10)
assert(count("GUILD") == 0 and lane.stats.noListener == 1, "a capture was said to nobody")
assert(net:Send("NH", "y1"))
advance(10)
assert(count("GUILD", "NH") == 1, "the presence is how the guild mates find each other")
for i = 2, 4 do
    advance(120)
    assert(net:Send("NH", "y" .. i))
    advance(10)
end
assert(count("GUILD", "NH") == 1, "alone, a presence every 120 s is too many")
advance(400)
assert(net:Send("NH", "y6"))
advance(10)
assert(count("GUILD", "NH") == 2, "alone, the presence comes back after ten minutes or so")
print("Guild lane: alone in the guild, a presence every ten minutes and nothing else")

-- ---------------------------------------------------------------------------
-- (4) Rates
-- ---------------------------------------------------------------------------
-- The gap grows with the guild: about 1.3 presences a minute, whatever its size.
resetLane()
assert(lane:PresenceGap() == 600)
for i = 1, 40 do lane.peers["peer " .. i] = clock end
lane.peerCountAt = nil
assert(lane:PeerCount() == 40 and lane:PresenceGap() == 1800, "40 peers: 1800 s, got " .. lane:PresenceGap())
for i = 4, 40 do lane.peers["peer " .. i] = nil end
lane.peerCountAt = nil
assert(lane:PresenceGap() == 135, "3 peers: 135 s, got " .. lane:PresenceGap())
lane.peers["peer 2"], lane.peers["peer 3"] = nil, nil
lane.peerCountAt = nil
assert(lane:PresenceGap() == 120, "1 peer: 120 s")
-- A guild mate not heard for an hour is forgotten.
advance(3599)
lane.peerCountAt = nil
assert(lane:PeerCount() == 1)
advance(2)
lane.peerCountAt = nil
assert(lane:PeerCount() == 0, "a peer outlived an hour")

-- Three at once, then one per twelve seconds (terminal messages wait for tokens).
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
for i = 1, 10 do offer("TV", "front" .. i) end
advance(7)
assert(count("GUILD") == 3, "burst of three expected, got " .. count("GUILD"))
advance(12)
assert(count("GUILD") == 4, "one per twelve seconds expected, got " .. count("GUILD"))
advance(12)
assert(count("GUILD") == 5, "one per twelve seconds expected, got " .. count("GUILD"))
-- Nothing leaves a minute past its time: it is no longer news.
advance(60)
local total = count("GUILD")
advance(120)
assert(count("GUILD") == total and #lane.outbox == 0, "a stale message left or stayed")
assert(lane.stats.expired > 0, "expiry was not counted")

-- Everything said in the guild counts against its ceiling.
resetLane()
refused()
hearPresence("Bob Tester")
for i = 1, 3 do hear("TV", "busy" .. i, "Carol Tester") end
sent = {}
lane.tokens = 3
offer("NH", "z")  -- routine: said + 1 >= SOFT
advance(6)
assert(count("GUILD") == 0, "a routine message passed the soft ceiling (" .. lane:HeardLastMinute(clock) .. " heard)")
assert(lane.stats.capped > 0, "the ceiling was not counted")
-- A terminal one still passes the soft ceiling.
offer("TV", "important")
advance(7)
assert(count("GUILD") == 1, "a terminal message stopped at the soft ceiling")
-- A flood from a single sender counts for three a minute: it cannot silence a guild.
resetLane()
refused()
for i = 1, 40 do hear("TV", "flood" .. i, "Evil Tester") end
assert(lane:HeardLastMinute(clock) == 3, "one sender must count for three, got " .. lane:HeardLastMinute(clock))
for i = 1, 3 do hear("TV", "busy" .. i, "Carol Tester") end
for i = 1, 3 do hear("TV", "again" .. i, "Dave Tester") end
for i = 1, 1 do hear("TV", "more" .. i, "Erin Tester") end
assert(lane:HeardLastMinute(clock) == 10, "ten heard, got " .. lane:HeardLastMinute(clock))
sent = {}
offer("TV", "blocked")
advance(7)
assert(count("GUILD") == 0, "a terminal message passed the hard ceiling")
lane.outbox = {}
advance(60)
assert(lane:HeardLastMinute(clock) == 0, "the minute is over")
-- Waits for the guild to calm down and leaves within its minute.
resetLane()
refused()
hearPresence("Bob Tester")
for i = 1, 3 do hear("TV", "busy" .. i, "Carol Tester") end
for i = 1, 3 do hear("TV", "again" .. i, "Dave Tester") end
for i = 1, 3 do hear("TV", "more" .. i, "Erin Tester") end
sent = {}
advance(10)
offer("TV", "patient")
advance(6)
assert(count("GUILD") == 0, "left over the hard ceiling")
advance(48)
assert(count("GUILD") == 1, "did not leave once the guild calmed down")
print("Guild lane: presence gap, tokens, ceilings, one sender cannot silence a guild")

-- Said by somebody else while we wait: given up.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_d")))
assert(#lane.outbox == 1)
hear("C", capture("elwynn_d"), "Carol Tester")
assert(#lane.outbox == 0 and lane.stats.cancelled == 1, "a capture heard from somebody else was not given up")
advance(10)
assert(count("GUILD") == 0, "the capture was said twice")
-- Heard before we even offer it: covered.
assert(offer("C", capture("elwynn_d")) == false and lane.stats.covered == 1, "a fresh capture was said again")
-- After the cover, the fact may be told again.
advance(31)
assert(offer("C", capture("elwynn_d")) == true, "the cover lasted too long")
-- C and ZS captured: one message.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_e")))
assert(offer("ZS", zoneState("captured", "elwynn_e")))
assert(#lane.outbox == 1, "a capture and its final state take two messages")
advance(10)
assert(count("GUILD") == 1, "a capture and its final state were both said")
assert(offer("ZS", zoneState("captured", "elwynn_e")) == false, "our own message must cover the next copy")
-- A newer presence replaces a waiting one, and the box is bounded, the least important going first.
resetLane()
refused()
hearPresence("Bob Tester")
offer("NH", "first")
offer("NH", "second")
assert(#lane.outbox == 1 and lane.outbox[1].fragments[1]:find("NH", 1, true), "two waiting presences")
for i = 1, lane.OUTBOX_MAX do offer("TV", "fill" .. i) end
assert(#lane.outbox == lane.OUTBOX_MAX, "the box grew past its bound")
for _, entry in ipairs(lane.outbox) do assert(entry.kind ~= "NH", "the box kept a presence over a terminal message") end
assert(offer("FC", "alert") == false, "an alert took the place of a terminal message")
-- A relayed copy waits longer than its author's.
resetLane()
refused()
hearPresence("Bob Tester")
local relayed = packet("C", capture("elwynn_f"))
relayed.path = { "Carol Tester", me }
lane:Offer(relayed, { "x:1:1:y" })
assert(lane.outbox[1].due - clock >= 2, "a relayed copy must leave the author time")
print("Guild lane: covered by the guild, one message per fact, bounded box")

-- A line posted in advance does not keep the capturer quiet: their own report of a capture
-- answers only to a copy heard just now.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("C", capture("elwynn_j"), "Carol Tester")
advance(lane.HEARD_COVER_SEC + 1)
assert(offer("C", capture("elwynn_j")) == true, "a line heard in advance silenced our own capture")
advance(10)
assert(count("GUILD") == 1, "our own capture was not said")
assert(offer("ZS", zoneState("captured", "elwynn_j")) == false, "what we said ourselves must cover our next copies")
-- Heard just now, as in a raid: not said, and its later copies neither, for the whole time.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("C", capture("elwynn_k"), "Carol Tester")
advance(5)
assert(offer("C", capture("elwynn_k")) == false, "a capture heard five seconds ago was said again")
advance(lane.COVER_SEC - 10)
assert(offer("ZS", zoneState("captured", "elwynn_k")) == false, "a later copy of a capture somebody else said was offered")
assert(offer("C", capture("elwynn_k")) == false)
advance(10)
assert(count("GUILD") == 0, "a capture somebody else said went out")
assert(offer("C", capture("elwynn_k")) == true, "the cover must end")
-- Heard while ours waits: the same.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_l")))
hear("C", capture("elwynn_l"), "Carol Tester")
assert(#lane.outbox == 0)
advance(lane.COVER_SEC - 5)
assert(offer("ZS", zoneState("captured", "elwynn_l")) == false, "our replay was not covered after a copy heard while ours waited")
-- The rest yields for the whole time: a relayed copy, a siege alert.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("C", capture("elwynn_m"), "Carol Tester")
hear("ZS", zoneState("in_progress", "elwynn_m", "H"), "Carol Tester")
advance(lane.HEARD_COVER_SEC + 5)
local relayedCopy = packet("C", capture("elwynn_m"))
relayedCopy.path = { "Dana Tester", me }
assert(lane:Offer(relayedCopy, { "x:1:1:y" }) == false, "a relayed copy must yield to what the guild heard")
assert(offer("ZS", zoneState("in_progress", "elwynn_m", "H")) == false, "a siege alert must yield to what the guild heard")
-- A copy the relay does not take says nothing: a last hop that is not its sender, a line
-- addressed to somebody else.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_n")))
local badId, badWire = wireOf("C", capture("elwynn_n"), "Carol Tester")
s:OnAddonMessage(PREFIX, "BF:" .. badId .. ":1:1:" .. badWire, "GUILD", "Bob Tester")
assert(#lane.outbox == 1 and lane.stats.cancelled == 0 and lane.cover["CAP|elwynn_n|A"] == nil, "a refused copy covered a capture")
hear("C", capture("elwynn_n"), "Bob Tester", nil, "Zed Tester")
assert(#lane.outbox == 1 and lane.stats.cancelled == 0 and lane.cover["CAP|elwynn_n|A"] == nil, "an addressed line covered a capture")
-- Our own packet coming back through a guild mate (already seen by the relay): said.
resetLane()
refused()
hearPresence("Bob Tester")
assert(net:Send("TV", "back"))
local pumped = 0
while #lane.outbox == 0 and pumped < 40 do advance(0.25); pumped = pumped + 1 end
local waiting = lane.outbox[1]
assert(waiting and waiting.kind == "TV", "the relay did not offer our own packet to the guild")
local backWire = (waiting.fragments[1]:match("^[^:]+:1:1:(.*)$"):gsub("|" .. me .. "|", "|" .. me .. ",Bob Tester|", 1))
s:OnAddonMessage(PREFIX, "BF:" .. waiting.id .. ":1:1:" .. backWire, "GUILD", "Bob Tester")
assert(#lane.outbox == 0 and lane.stats.cancelled == 1, "our own packet back through a guild mate was said again")
-- A flood of made-up facts fills a bounded memory.
resetLane()
for i = 1, 3000 do lane:RememberCover("flood" .. i, clock) end
local rows = 0
for _ in pairs(lane.cover) do rows = rows + 1 end
assert(rows <= lane.COVER_ROWS + 128, "the memory of what was heard grew to " .. rows)
print("Guild lane: only a copy the relay took covers, a capturer answers only to what was heard just now, bounded memory")

-- A relayed packet: a few of its holders say it, on a draw of their own.
resetLane()
refused()
for i = 1, 40 do hearPresence("Peer" .. i .. " Tester") end
lane.peerCountAt = nil
assert(lane:PeerCount() == 40)
local function spoken(path, heardOn)
    local spoke = 0
    for i = 1, 400 do
        local r = packet("TV", "held" .. i)
        r.path, r.heardOn = path, heardOn
        if lane:Offer(r, { r.id .. ":1:1:x" }) then spoke = spoke + 1 end
        lane.outbox, lane.cover, lane.ownCover = {}, {}, {}
    end
    return spoke
end
local fromMate = spoken({ "Origin Tester", "Peer1 Tester", me }, "RAID")
assert(fromMate >= 12 and fromMate <= 52, "about 3 holders in 40 must say it: " .. fromMate .. " of 400")
assert(lane.stats.notSpeaker == 400 - fromMate)
-- Another holder draws differently.
local drawnBy = {}
for i = 1, 40 do
    local r = packet("TV", "same")
    r.id = "same-1"
    r.path, r.heardOn = { "Origin Tester", "Peer1 Tester", "Peer" .. i .. " Tester" }, "RAID"
    if lane:Offer(r, { "x:1:1:y" }) then drawnBy[#drawnBy + 1] = i end
    lane.outbox, lane.cover, lane.ownCover = {}, {}, {}
end
assert(#drawnBy >= 1 and #drawnBy <= 12, "the draw must pick a few of the forty holders: " .. #drawnBy)
-- From outside the guild, nobody else has it: every holder says it.
assert(spoken({ "Origin Tester", "Stranger Tester", me }, "BNET") == 400, "what a friend outside the guild told us must be said")
assert(spoken({ "Origin Tester", "Stranger Tester", me }, "RAID") == 400, "what came from outside the guild must be said")
-- A friend in the guild says it there; several of them holding one packet are just more holders.
local friendInGuild = spoken({ "Origin Tester", "Peer1 Tester", me }, "BNET")
assert(friendInGuild >= 12 and friendInGuild <= 52, "a friend in the guild is not outside: " .. friendInGuild)
local realRoster = Overlord.Leaderboard.IsLocalGuildRosterMember
Overlord.Leaderboard.IsLocalGuildRosterMember = function(_, name) return name == "Silent Mate" end
local fromRoster = spoken({ "Origin Tester", "Silent Mate", me }, "RAID")
assert(fromRoster >= 12 and fromRoster <= 52, "a guild mate on the roster is not outside: " .. fromRoster)
Overlord.Leaderboard.IsLocalGuildRosterMember = realRoster
-- Our own: always ours to say. A small guild: everybody.
assert(spoken({ me }) == 400, "our own message must not depend on a draw")
lane.peers, lane.peerCountAt = { ["peer1 tester"] = clock, ["peer2 tester"] = clock, ["peer3 tester"] = clock }, nil
assert(spoken({ "Origin Tester", "Peer1 Tester", me }, "RAID") == 400, "three guild mates: everybody says it")
print("Guild lane: a few holders say a relayed packet, all of them what came from outside")

-- Made-up facts pushed at one of us by a friend: whatever their number, the guild hears
-- about two a minute of them, and nothing of ours waits or goes for it.
local function pushed(i, kind, payload)
    local r = packet(kind or "TV", payload or ("made up " .. i))
    r.path, r.heardOn = { "Origin Tester", "Stranger Tester", me }, "BNET"
    return lane:Offer(r, { r.id .. ":1:1:pushed" })
end
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
for second = 1, 300 do
    pushed(second)
    advance(1)
end
local forgedSaid = count("GUILD", "pushed")
assert(forgedSaid >= 5 and forgedSaid <= lane.RELAYED_BURST + 300 / lane.RELAYED_SEC + 1,
    "a friend's pushes made the guild talk " .. forgedSaid .. " times in five minutes")
-- Heard or said, one share for the guild.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("TV", "heard 1", "Origin Tester", "Origin Tester,Bob Tester")
hear("TV", "heard 2", "Origin Tester", "Origin Tester,Bob Tester")
hear("TV", "heard 3", "Origin Tester", "Origin Tester,Bob Tester")
assert(pushed(1))
advance(9)
assert(count("GUILD", "pushed") == 0, "what the guild heard from others must take from the same share")
advance(lane.RELAYED_SEC * 2)
assert(pushed(2))
advance(9)
assert(count("GUILD", "pushed") == 1, "the share must come back")
-- What a guild mate says of their own takes nothing from it, and our own needs nothing of it.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("TV", "their own 1", "Bob Tester")
hear("TV", "their own 2", "Bob Tester")
hear("TV", "their own 3", "Bob Tester")
assert(pushed(1))
advance(9)
assert(count("GUILD", "pushed") == 1, "a guild mate's own messages took from the relayed share")
hear("TV", "heard 4", "Origin Tester", "Origin Tester,Bob Tester")
hear("TV", "heard 5", "Origin Tester", "Origin Tester,Bob Tester")
hear("TV", "heard 6", "Origin Tester", "Origin Tester,Bob Tester")
assert(offer("TV", "ours"))
advance(7)
assert(lane.ownCover["TV|ours"] ~= nil, "our own message depends on the relayed share")
-- A relayed alert leaves the last of it to a capture.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(pushed(1, "ZS", zoneState("in_progress", "elwynn_p", "H")))
advance(9)
assert(count("GUILD", "pushed") == 1, "a relayed alert must go out with a full share")
lane.relayedJitter = 0.9
assert(pushed(2, "ZS", zoneState("in_progress", "elwynn_q", "H")))
advance(9)
assert(count("GUILD", "pushed") == 1, "a relayed alert took the last of the share")
assert(pushed(3, "C", capture("elwynn_q")))
advance(9)
assert(count("GUILD", "pushed") == 2, "a relayed capture must have the last of the share")
-- Each client wants a little more than the others before speaking again, drawn anew each time.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
lane.relayedTokens, lane.relayedTokensAt = 1.2, clock
lane.relayedJitter = 0.5
assert(pushed(1))
advance(9)
assert(count("GUILD", "pushed") == 0, "the share was taken below what this client wants")
lane.relayedTokens, lane.relayedTokensAt = 1.2, clock
lane.relayedJitter = 0.1
assert(pushed(2))
advance(9)
assert(count("GUILD", "pushed") == 1, "the share was refused above what this client wants")
assert(lane.relayedJitter ~= 0.1, "what this client wants must be drawn anew")
-- A capture our own map has just taken needs no share and leaves before the rest; a capture
-- our map does not show, or shows from long ago or for the other side, is one more push.
local realMapZone = s.MapNewsZone
local function serverClock() return Overlord.ServerNow and Overlord.ServerNow() or time() end
local mapZone
s.MapNewsZone = function(_, zoneId) return zoneId == "elwynn_s" and mapZone or nil end
local function drained()
    resetLane()
    refused()
    hearPresence("Bob Tester")
    sent = {}
    lane.relayedTokens, lane.relayedTokensAt = 0, clock
end
local function saidWith(zone)
    drained()
    mapZone = zone
    assert(pushed(1, "C", capture("elwynn_s")))
    advance(9)
    return count("GUILD", "pushed") == 1
end
assert(saidWith({ owner = "Alliance", status = "captured", capturedTime = serverClock() - 10 }),
    "a capture on our own map was held back by the share")
assert(not saidWith({ owner = "Horde", status = "captured", capturedTime = serverClock() - 10 }), "our map shows the other side")
assert(not saidWith({ owner = "Alliance", status = "in_progress", capturedTime = serverClock() - 10 }), "our map shows a siege")
assert(not saidWith({ owner = "Alliance", status = "captured", capturedTime = serverClock() - lane.PROVEN_SEC - 30 }),
    "an old capture proves nothing: anybody can quote it")
assert(not saidWith(nil), "a zone we do not know proves nothing")
-- 2.3.0: heard from a guild mate, a relayed capture takes one from the share (whisper-chain copies
-- reach many holders; uncounted, they filled the guild's minute and its routine words were lost).
resetLane()
refused()
hearPresence("Bob Tester")
mapZone = { owner = "Alliance", status = "captured", capturedTime = serverClock() - 10 }
hear("C", capture("elwynn_s"), "Origin Tester", "Origin Tester,Bob Tester")
assert((lane.relayedTokens or lane.RELAYED_BURST) == lane.RELAYED_BURST - 1, "a relayed capture heard took nothing from the share")
-- In the box: it stays through a flood, and goes first.
drained()
mapZone = { owner = "Alliance", status = "captured", capturedTime = serverClock() - 10 }
assert(pushed(1, "C", capture("elwynn_s")))
local provenEntry = lane.outbox[1]
for i = 1, lane.OUTBOX_MAX * 3 do pushed(100 + i) end
local provenKept = false
for _, entry in ipairs(lane.outbox) do provenKept = provenKept or entry == provenEntry end
assert(provenKept, "a flood pushed a capture our map shows out of the box")
for i = #lane.outbox, 1, -1 do lane.outbox[i].due = clock end
lane:Flush()
assert(lane.cover["CAP|elwynn_s|A"] ~= nil, "a capture our map shows must leave before the rest")
s.MapNewsZone = realMapZone
-- The box: a flood of relayed copies never pushes out what is ours, and ours leaves first.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_r")))
assert(offer("NH", "present"))
for i = 1, lane.OUTBOX_MAX * 3 do pushed(i) end
assert(#lane.outbox == lane.OUTBOX_MAX, "the box grew past its bound")
local keptCapture, keptPresence = false, false
for _, entry in ipairs(lane.outbox) do
    if entry.cover == "CAP|elwynn_r|A" then keptCapture = true end
    if entry.kind == "NH" then keptPresence = true end
end
assert(keptCapture and keptPresence, "a flood of relayed copies pushed our own messages out of the box")
for i = #lane.outbox, 1, -1 do lane.outbox[i].due = clock end
lane:Flush()
assert(lane.ownCover["CAP|elwynn_r|A"] ~= nil, "our own capture must leave before relayed copies")
print("Guild lane: a friend's pushes cost the guild about two messages a minute, ours go first")

-- A broadcast never travels by whisper: heard that way, it goes nowhere near the guild, however
-- real it looks. Real receive path, up to the guild's box.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
do
    local id, wire = wireOf("TV", "Alliance:1790017000:0:0:x", "Made Up", "Made Up,Stranger Tester")
    s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "WHISPER", "Stranger Tester")
    advance(30)
    assert(count("GUILD", "BF:") == 0 and #lane.outbox == 0, "a broadcast heard by whisper was said in the guild")
    local r = packet("C", capture("elwynn_t"))
    r.path, r.heardOn = { "Origin Tester", "Stranger Tester", me }, "WHISPER"
    assert(lane:Carries(r, 1) == false and lane:Offer(r, { r.id .. ":1:1:x" }) == false, "by whisper, not even offered")
    r.heardOn = "BNET"
    assert(lane:Carries(r, 1) == true, "fixture: from a friend it is")
end
-- A wave told in the guild that outlives its clock: a few of those following it ask about it, the
-- same ones every time. Any other wave, and a small guild: as before.
resetLane()
refused()
for i = 1, 40 do hearPresence("Peer" .. i .. " Tester") end
lane.peerCountAt = nil
do
    local asking = 0
    local realName = s.GetPlayerFullName
    local zone = { _remoteCaptureLease = { viaGuild = true, waveId = "wAsk" } }
    for i = 1, 400 do
        s.GetPlayerFullName = function() return "Holder" .. i .. " Tester" end
        if lane:AsksAboutWave(zone) then asking = asking + 1 end
    end
    assert(asking >= 12 and asking <= 52, "about 3 in 40 must ask about a wave told in the guild: " .. asking .. " of 400")
    s.GetPlayerFullName = function() return "Holder1 Tester" end
    local firstTime = lane:AsksAboutWave(zone)
    assert(lane:AsksAboutWave(zone) == firstTime, "the same client must decide the same way")
    s.GetPlayerFullName = realName
    assert(lane:AsksAboutWave({ _remoteCaptureLease = { waveId = "wAsk" } }) == true, "a wave with ticks asks as before")
    assert(lane:AsksAboutWave({}) == true, "no wave followed: as before")
    resetLane()
    refused()
    hearPresence("Bob Tester")
    assert(lane:AsksAboutWave(zone) == true, "in a small guild everybody asks")
end
-- One packet in the hands of many (a raid, a well-connected friend): its holders draw like the
-- holders of a capture. Uniform waits had all of them speak before the first copy came back.
resetLane()
refused()
hearPresence("Bob Tester")
do
    local realDraw, shared = lane.DrawWait, nil
    lane.DrawWait = function(self, wait, isShared)
        shared = isShared
        return realDraw(self, wait, isShared)
    end
    assert(pushed(1))
    lane.DrawWait = realDraw
    assert(shared == true, "the holders of a relayed packet must draw how long they wait")
end
-- Somebody's word pushed at us never takes the place of our own report, nor quiets it. (Nor does it
-- keep our date from being said: it may be a real copy of an older capture.)
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(pushed(1, "C", "elwynn_w:junk:A:"))
assert(#lane.outbox == 1 and lane.outbox[1].relayed, "fixture: the copy waits")
assert(offer("C", capture("elwynn_w", "Alliance", GetServerTime())))
assert(#lane.outbox == 1 and lane.outbox[1].firm and not lane.outbox[1].relayed,
    "a copy relayed to us took the place of our own capture")
advance(9)
assert(count("GUILD", ":1:1:C") == 1 and count("GUILD", "pushed") == 0, "our own capture must be what the guild hears")
pushed(2, "C", "elwynn_w:junk:A:")
assert(#lane.outbox == 0 and lane.stats.covered >= 1, "what we said covers the copies")
-- Our own report waiting: a relayed copy does not replace it, nor wait beside it.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_w", "Alliance", GetServerTime())))
assert(pushed(1, "C", "elwynn_w:junk:A:"))
assert(#lane.outbox == 1 and lane.outbox[1].firm, "a relayed copy took the place of what waits, or waits beside it")
-- A copy we said ourselves: other copies stay quiet, our own report does not.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(pushed(1, "C", "elwynn_w:junk:A:"))
lane.outbox[1].due = clock
lane:Flush()
assert(count("GUILD", "pushed") == 1, "fixture: the copy was said")
assert(lane.ownCover["CAP|elwynn_w|A"] == nil and lane.cover["CAP|elwynn_w|A"] ~= nil,
    "somebody's word said by us must not count as our own report")
pushed(2, "C", "elwynn_w:junk:A:")
assert(count("GUILD", "pushed") == 1 and #lane.outbox == 0, "a relayed copy must stay quiet after the first")
advance(13)
assert(offer("C", capture("elwynn_w", "Alliance", GetServerTime())))
advance(9)
assert(count("GUILD", ":1:1:C") == 1, "our own capture was kept quiet by a copy we relayed")
-- A date to come says nothing past its time: it does not cover what is really captured later.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
local farFuture = serverClock() + 86400
hear("C", capture("elwynn_x", "Alliance", farFuture), "Mallory Tester")
assert(lane.coverDate["CAP|elwynn_x|A"] <= serverClock() + lane.DATE_SKEW, "a date to come was kept as it is")
assert(offer("C", capture("elwynn_x", "Alliance", serverClock() + lane.DATE_SKEW + 2)))
hear("C", capture("elwynn_x", "Alliance", farFuture), "Mallory Tester")
assert(#lane.outbox == 1, "a date to come cancelled a real report made since")
-- What no client running this code can send is not read, and costs that sender nothing else.
resetLane()
refused()
assert(lane.TOKEN_BURST + 60 / lane.TOKEN_SEC < lane.INTAKE_PER_MIN, "the intake limit must be above what this code says")
for i = 1, lane.INTAKE_PER_MIN do
    assert(lane:OnHeard("BF:x" .. i .. "-1:1:1:w", "Bob Tester") == true, "within the limit: read")
end
assert(lane:OnHeard("BF:y-1:1:1:w", "Bob Tester") == false, "past the limit: not read")
assert(lane.stats.tooFast == 1 and lane.stats.heard == lane.INTAKE_PER_MIN, "past the limit it must count nowhere else")
assert(lane:OnHeard("BF:z-1:1:1:w", "Carl Tester") == true, "another sender pays for nobody")
advance(61)
assert(lane:OnHeard("BF:w-1:1:1:w", "Bob Tester") == true, "a minute later it is read again")
assert(lane:GetDiagnostics():find("1 unread", 1, true), "the panel must say it")

-- ---------------------------------------------------------------------------
-- (5) The echo
-- ---------------------------------------------------------------------------
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
local ok, p = offer("TV", "echoed")
assert(ok)
advance(7)
assert(count("GUILD") == 1 and lane.awaiting[p.id] ~= nil, "the message is awaited")
local before = net.stats.received
advance(1)
assert(lane:OnHeard(sent[#sent].msg, me) == false, "our own copy must stop at the lane")
assert(lane.awaiting[p.id] == nil and lane.stats.echoes == 1 and lane.lastEchoDelay and lane.lastEchoDelay > 0, "the echo was not read")
assert(net.stats.received == before, "our own copy reached the relay")
-- Anybody can copy an id: only our own copy says the server took our message.
local ok2, p2 = offer("TV", "echoed2")
advance(25)
assert(ok2 and count("GUILD") == 2, "second message")
local echoesSoFar = lane.stats.echoes
assert(lane:OnHeard(sent[#sent].msg, "Somebody Else") == true, "somebody else's message must be read as theirs")
assert(lane.awaiting[p2.id] ~= nil and lane.stats.echoes == echoesSoFar, "somebody else's copy of our id counted as our echo")
-- Our name spelled differently (with a realm, say) is still us.
assert(lane:OnHeard(sent[#sent].msg, me .. "-Otherrealm") == false, "our own name with a realm is us")
assert(lane.awaiting[p2.id] == nil and lane.stats.echoes == echoesSoFar + 1)
-- A newer presence replacing a waiting one is the one awaited.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
local _, firstPresence = offer("NH", "first")
local _, newestPresence = offer("NH", "second")
advance(6)
assert(count("GUILD") == 1 and lane.awaiting[newestPresence.id] ~= nil and lane.awaiting[firstPresence.id] == nil,
    "the presence sent is not the one awaited")

-- Nothing comes back: one message per five minutes.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
for i = 1, 3 do offer("TV", "lost" .. i) end
advance(7)
assert(count("GUILD") == 3)
assert(not lane:IsUnheard(), "unheard before five minutes")
advance(300)
assert(lane:IsUnheard(), "three messages with no echo for five minutes")
hearPresence("Bob Tester")
offer("TV", "lost4")
advance(7)
assert(count("GUILD") == 4, "one after the gap")
offer("TV", "lost5")
advance(7)
assert(count("GUILD") == 4, "a second one within five minutes")
local level, text = lane:Describe()
assert(level == "warn" and text:find("dropping", 1, true), "the panel must say so: " .. tostring(text))
-- An echo clears it.
assert(lane:OnHeard(sent[#sent].msg, me) == false)
assert(not lane:IsUnheard(), "an echo must clear it")

-- Refused for no guild: quiet for five minutes.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
guildCode = 10
offer("TV", "noguild")
advance(7)
assert(count("GUILD") == 1 and lane.stats.failed == 1, "the refused send")
assert(not lane:IsActive(), "code 10 must stop the lane")
guildCode = 0
advance(301)
assert(lane:IsActive(), "code 10 stops it for five minutes only")
-- Refused by the game for a moment: tried again until its time is up, at the pace of the tokens.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
guildCode = 3
local _, retried = offer("TV", "retry")
advance(7)
assert(lane.stats.failed >= 1 and lane.stats.sent == 0 and #lane.outbox == 1, "a terminal message was lost on a refused send")
assert(lane.ownCover["TV|retry"] == nil, "a message that did not leave covers nothing")
guildCode = 0
advance(lane.TOKEN_SEC + 3)
assert(lane.stats.sent == 1 and #lane.outbox == 0 and lane.awaiting[retried.id] ~= nil, "not tried again")
assert(lane.ownCover["TV|retry"] ~= nil, "a message sent covers its next copy")
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
guildCode = 3
offer("TV", "never")
advance(lane.OUTBOX_TTL + 10)
assert(#lane.outbox == 0 and lane.stats.expired == 1 and lane.stats.sent == 0, "a message the game keeps refusing must expire")
assert(lane.stats.failed <= lane.TOKEN_BURST + lane.OUTBOX_TTL / lane.TOKEN_SEC + 1, "tried too often: " .. lane.stats.failed)
-- A presence is not tried again, and the next one is not held back by it.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
guildCode = 3
offer("NH", "lost")
advance(6)
assert(#lane.outbox == 0 and lane.stats.failed == 1 and lane.lastPresenceAt == nil, "a presence that did not leave")
guildCode = 0
assert(offer("NH", "next"), "the next presence was held back by one that never left")
-- Half a message left: all of it is tried again, nothing is taken as said until then.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
local realChecked, calls = s.SendAddonChecked, 0
s.SendAddonChecked = function(self, message, chatType, target)
    calls = calls + 1
    if chatType == "GUILD" and calls == 2 then return false end
    return realChecked(self, message, chatType, target)
end
local twoParts = packet("TV", "two parts")
lane:Offer(twoParts, { twoParts.id .. ":1:2:a", twoParts.id .. ":2:2:b" })
advance(7)
assert(calls == 2 and lane.stats.sent == 1 and #lane.outbox == 1 and lane.ownCover["TV|two parts"] == nil,
    "half a message counted as said")
assert(lane.awaiting[twoParts.id] ~= nil, "its first part is on its way: its echo must be known")
advance(lane.TOKEN_SEC * 2 + 3)
s.SendAddonChecked = realChecked
assert(lane.stats.sent == 3 and #lane.outbox == 0 and lane.ownCover["TV|two parts"] ~= nil, "the whole message was not tried again")
print("Guild lane: echo, a server that swallows our messages, not in a guild, a refused send tried again")

-- ---------------------------------------------------------------------------
-- (6) What is heard
-- ---------------------------------------------------------------------------
resetLane()
assert(lane:OnHeard("K:1:2:3", "Bob Tester") == false, "only relay fragments are read")
assert(lane.stats.heard == 0)
local delivered = {}
local realOnAddon = s.OnAddonMessage
s.OnAddonMessage = function(self, prefix, message, channel, sender)
    if channel == "BETA" then
        delivered[#delivered + 1] = { message = message, sender = sender, transport = net.context and net.context.transport,
            direct = net:IsDirectChannelDispatch() }
        return
    end
    return realOnAddon(self, prefix, message, channel, sender)
end
-- With a working channel too: what comes from the guild is read and bridged.
refused()
hearPresence("Bob Tester")
local route = net.peers["bob tester"]
assert(route and route.transport == "GUILD" and route.hops == 1 and route.via == "Bob Tester", "no route from a guild presence")
assert(net:IsDirectPeer("Bob Tester"), "a guild mate heard first-hand is a neighbour")
assert(lane:HeardAt("Bob Tester") == clock and lane:HeardAt("Nobody Tester") == nil)
sent = {}
hear("C", capture("elwynn_g"), "Bob Tester")
assert(#delivered == 1 and delivered[1].message == "C:" .. capture("elwynn_g") and delivered[1].transport == "GUILD",
    "the capture was not delivered")
assert(delivered[1].direct == true, "without a channel, the guild stands in for it for direct dispatch")
advance(20)
assert(count("GUILD") == 0, "what the guild heard was said there again")
assert(count("CHANNEL") == 0, "what the guild heard went to a refused channel")
-- A guild mate's second copy, a fragment that is not ours to read: no second delivery.
local id, wire = wireOf("TV", "once", "Bob Tester")
delivered = {}
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "GUILD", "Bob Tester")
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "GUILD", "Bob Tester")
assert(#delivered == 1, "a duplicate was delivered twice")
-- Forged fragments: last hop not the sender, wrong region.
delivered = {}
id, wire = wireOf("TV", "forged", "Carol Tester")
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "GUILD", "Bob Tester")
assert(#delivered == 0, "a packet whose path does not end at its sender was read")
id, wire = wireOf("TV", "forged2", "Carol Tester")
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire:gsub("^[^|]*", "otherpool"), "GUILD", "Carol Tester")
assert(#delivered == 0, "a packet of another pool was read")
-- A relayed copy heard in the guild has been said: nobody else needs to say it, and it is delivered.
delivered = {}
hear("TV", "relayed", "Carol Tester", "Carol Tester,Bob Tester")
assert(#delivered == 1 and delivered[1].direct == false, "a relayed copy is delivered, not direct")
-- A multi-fragment message, in two guild messages.
delivered = {}
local longPayload = "elwynn_h:" .. string.rep("x", 190)
id, wire = wireOf("TV", longPayload, "Bob Tester")
assert(#wire > 200)
local firstPart, secondPart = wire:sub(1, 200), wire:sub(201)
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:2:" .. firstPart, "GUILD", "Bob Tester")
assert(#delivered == 0, "half a packet was delivered")
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":2:2:" .. secondPart, "GUILD", "Bob Tester")
assert(#delivered == 1 and delivered[1].message == "TV:" .. longPayload, "two fragments were not assembled")

-- A client whose channel works bridges a guild mate's copy onto it.
resetLane()
delivered = {}
sent = {}
hear("C", capture("elwynn_i"), "Bob Tester")
assert(#delivered == 1 and delivered[1].direct == false, "with a channel of our own, a guild copy is not a channel dispatch")
advance(20)
assert(count("CHANNEL", "elwynn_i") >= 1, "a client with a working channel must bridge the guild's copy")
assert(count("GUILD") == 0, "and never back to the guild")
-- Our own path stops a loop.
delivered = {}
id, wire = wireOf("TV", "loop", me, me .. ",Bob Tester")
s:OnAddonMessage(PREFIX, "BF:" .. id .. ":1:1:" .. wire, "GUILD", "Bob Tester")
assert(#delivered == 0, "a packet that already went through us came back in")
s.OnAddonMessage = realOnAddon
print("Guild lane: routes, delivery, no repost, duplicates, forged paths, fragments, bridging")

-- ---------------------------------------------------------------------------
-- (7) A presence heard by a whole guild at once
-- ---------------------------------------------------------------------------
resetLane()
refused()
local realPending = Overlord.IsCaptureSyncPending
Overlord.IsCaptureSyncPending = function() return false end
for i = 1, 4 do lane.peers["peer " .. i] = clock end
lane.peerCountAt = nil
assert(net:GuildPresenceLeavesUsQuiet("Bob Tester", clock) == false, "four peers: everybody may ask")
for i = 5, 40 do lane.peers["peer " .. i] = clock end
lane.peerCountAt = nil
local quiet, asked = 0, 0
for i = 1, 2000 do
    if net:GuildPresenceLeavesUsQuiet("Origin" .. i .. " Tester", clock) then quiet = quiet + 1 else asked = asked + 1 end
end
assert(asked > 100 and asked < 320, "about 10 % of the guild should ask: " .. asked .. " of 2000")
-- The same answer for the same origin within ten minutes, not forever.
local first = net:GuildPresenceLeavesUsQuiet("Bob Tester", 6000)
assert(net:GuildPresenceLeavesUsQuiet("Bob Tester", 6010) == first, "the answer changed within its window")
local changed = false
for i = 1, 40 do
    if net:GuildPresenceLeavesUsQuiet("Bob Tester", 6000 + i * 600) ~= first then changed = true end
end
assert(changed, "the same client answered the same way for hours")
-- Waiting for its login map, a client always asks.
Overlord.IsCaptureSyncPending = function() return true end
for i = 1, 200 do
    assert(net:GuildPresenceLeavesUsQuiet("Origin" .. i .. " Tester", clock) == false, "a client waiting for its map stayed quiet")
end
Overlord.IsCaptureSyncPending = realPending
print("Guild lane: a guild presence leaves about four askers")

-- ---------------------------------------------------------------------------
-- (8) Instances and the switch
-- ---------------------------------------------------------------------------
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
offer("TV", "before")
assert(#lane.outbox == 1)
s:OnNetworkSuspend()
assert(#lane.outbox == 0, "an instance must empty the box")
advance(30)
assert(count("GUILD") == 0, "a message left after the suspension")
-- Inside: nothing offered, nothing read (the frame's barrier, checked in the source below).
instanced = true
assert(offer("TV", "inside") == false and #lane.outbox == 0, "offered inside an instance")
instanced = false
-- Entered after an offer, the suspension has not run yet: the flush gives it up.
offer("TV", "late")
assert(#lane.outbox == 1)
instanced = true
advance(30)
assert(count("GUILD") == 0 and #lane.outbox == 0, "left from inside an instance")
instanced = false
-- Switched off: nothing leaves; what is heard is still read.
resetLane()
refused()
hearPresence("Bob Tester")
offer("TV", "off")
lane:SetSwitchedOff(true)
assert(#lane.outbox == 0, "switching off keeps a waiting message")
sent = {}
assert(net:Send("TV", "offgoing"))
advance(20)
assert(count("GUILD") == 0, "switched off, a message left")
local heardBefore = lane.stats.heard
hear("TV", "still read", "Bob Tester")
assert(lane.stats.heard == heardBefore + 1, "switched off, the guild must still be read")
lane:SetSwitchedOff(false)
print("Guild lane: instances, switch")

-- ---------------------------------------------------------------------------
-- (9) Reports
-- ---------------------------------------------------------------------------
resetLane()
local lvl, what = lane:Describe()
assert(lvl == "ok" and what == "channel open", "open channel: " .. tostring(what))
refused()
lvl, what = lane:Describe()
assert(lvl == "warn" and what:find("refused", 1, true) and what:find("guild fallback on", 1, true), tostring(what))
inGuild = false
lvl, what = lane:Describe()
assert(lvl == "warn" and what:find("no guild", 1, true), tostring(what))
inGuild = true
-- The game told a send that we have no guild: nothing goes out for now, and the panel says so.
lane.noGuildUntil = clock + 60
lvl, what = lane:Describe()
assert(lvl == "warn" and what:find("no guild", 1, true) and not what:find("guild fallback on", 1, true), tostring(what))
lane.noGuildUntil = nil
lane:SetSwitchedOff(true)
lvl, what = lane:Describe()
assert(lvl == "warn" and what:find("/ov guild on", 1, true), tostring(what))
lane:SetSwitchedOff(false)
assert(type(lane:GetDiagnostics()) == "string")

-- ---------------------------------------------------------------------------
-- (9b) What the guild is not told, and a siege it hears nothing more about
-- ---------------------------------------------------------------------------
-- The end of a wave is news only to those who follow it, and in the guild they can only have
-- it from us: said if our start was said, not if somebody else's covered it.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("ZS", zoneState("in_progress", "elwynn_z", "A", 2, "wz")))
advance(9)
assert(count("GUILD") == 1 and lane.spoken["elwynn_z"] == "wz", "our start was not remembered")
local kept = lane:Level({ kind = "ZR", payload = "elwynn_z:wz:" .. me, path = { me } })
assert(kept == 3, "the end of a wave the guild heard of must be said")
assert(lane:Level({ kind = "ZR", payload = "elwynn_z:wother:" .. me, path = { me } }) == nil,
    "the end of another wave of ours is news to nobody")
assert(lane:Level({ kind = "ZR", payload = "elwynn_y:wz:" .. me, path = { me } }) == nil,
    "the end of a wave nobody heard of is news to nobody")
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("ZS", zoneState("in_progress", "elwynn_x", "A", 2, "wx")))
hear("ZS", zoneState("in_progress", "elwynn_x", "A", 2, "wb"), "Bob Tester")
advance(9)
assert(lane.spoken["elwynn_x"] == nil, "a start that was cancelled was not said")

-- A wave heard once, in the guild: its silence means nothing until it should be over.
resetLane()
refused()
local followed = { id = "elwynn_f", status = "in_progress", owner = "Alliance", _zsOfficialCapturerSeenAt = clock,
    _remoteCaptureLease = { owner = "Alliance", tickAt = clock, openedAt = clock, tickHold = 10, effectiveRequired = 120,
        lastSeen = clock, lastDirectSeen = clock, directValidated = true } }
local lease = followed._remoteCaptureLease
advance(60)
assert(lane:KeepFollowing(followed) == 70, "the wave's clock is its first hold plus the time since")
assert(lease.lastSeen == clock and lease.lastDirectSeen == clock and followed._zsOfficialCapturerSeenAt == clock,
    "silence must not count while the wave can still be running")
advance(50 + lane.SIEGE_GRACE - 1)
assert(lane:KeepFollowing(followed), "a capture just due may still be on its way")
local lastKept = lease.lastSeen
advance(2)
assert(lane:KeepFollowing(followed) == nil and lease.lastSeen == lastKept, "past its end, silence counts again")
-- With the channel back, or without a guild, or without a wave: nothing.
followed._remoteCaptureLease.tickAt, followed._remoteCaptureLease.openedAt = clock, clock
serverRefuses = false
s:NoteChannelReopened()
assert(not lane:IsActive() and lane:KeepFollowing(followed) == nil, "the channel carries the ticks again")
refused()
inGuild = false
assert(lane:KeepFollowing(followed) == nil, "no guild, no guild rule")
inGuild = true
assert(lane:KeepFollowing({ status = "in_progress" }) == nil and lane:KeepFollowing(nil) == nil)
-- No proof of a direct contact is made up.
local indirect = { _remoteCaptureLease = { owner = "Alliance", tickAt = clock, openedAt = clock, tickHold = 0,
    effectiveRequired = 120, lastSeen = 0 } }
assert(lane:KeepFollowing(indirect) == 0 and indirect._remoteCaptureLease.lastDirectSeen == nil
    and indirect._zsOfficialCapturerSeenAt == nil, "only the silence is forgiven")
-- A wave heard elsewhere whose ticks do reach us: their silence says what it always did. Told in the
-- guild, later ticks (a group left since, a friend gone) do not change what its silence is worth.
local ticking = { _remoteCaptureLease = { owner = "Alliance", openedAt = clock - 10, tickAt = clock - 5, tickHold = 15,
    effectiveRequired = 120, lastSeen = clock - 5 } }
assert(lane:KeepFollowing(ticking) == nil and ticking._remoteCaptureLease.lastSeen == clock - 5,
    "the silence of a wave with ticks was forgiven")
ticking._remoteCaptureLease.viaGuild = true
assert(lane:KeepFollowing(ticking) and ticking._remoteCaptureLease.lastSeen == clock, "a wave told in the guild was dropped")

-- Those heard in a guild we have left are nobody's guild mates any more. A guild the game does
-- not give yet changes nothing.
resetLane()
refused()
local guildNow, realGuildInfo = "First Guild", GetGuildInfo
GetGuildInfo = function() return guildNow end
hearPresence("Bob Tester")
lane.peerCountAt = nil
assert(lane:PeerCount() == 1, "a guild mate must be counted")
guildNow = nil
lane.peerCountAt = nil
assert(lane:PeerCount() == 1, "a guild not known for a moment forgets nobody")
guildNow = "Second Guild"
lane.peerCountAt = nil
assert(lane:PeerCount() == 0, "the old guild's members are not in this one")
sent = {}
assert(offer("C", capture("elwynn_h", "Alliance", 1790017100)))
advance(9)
assert(count("GUILD", "BF:") == 0, "nobody heard here yet: nothing is said to nobody")
GetGuildInfo, lane.peersGuild = realGuildInfo, nil

-- One fact said by several holders takes one from the share; a kind the guild never carries, none.
resetLane()
refused()
hearPresence("Bob Tester")
local before = lane.RELAYED_BURST
for _, mate in ipairs({ "Ann", "Bea", "Cid" }) do
    local copyId, copyWire = wireOf("TV", "same fact", "Origin Tester", "Origin Tester," .. mate .. " Tester")
    s:OnAddonMessage(PREFIX, "BF:" .. copyId .. ":1:1:" .. copyWire, "GUILD", mate .. " Tester")
end
assert(lane.relayedTokens == before - 1, "three copies of one fact took " .. tostring(before - (lane.relayedTokens or before)))
hear("TV", "another fact", "Origin Tester", "Origin Tester,Bob Tester")
assert(lane.relayedTokens == before - 2, "another fact takes its own")
local tokensThen = lane.relayedTokens
hear("K", "x", "Origin Tester", "Origin Tester,Bob Tester")
hear("LK", "x", "Origin Tester", "Origin Tester,Bob Tester")
assert(lane.relayedTokens == tokensThen, "what the guild never carries must not take from its share")
print("Guild lane: nothing said to nobody, a silent wave followed to its end, one fact one share")

-- A wave told in the guild has no ticks for whoever hears it, in the lane or not: a guild mate
-- whose channel works, or who switched the guild off, reads the guild all the same.
resetLane()
local heardWave = { _remoteCaptureLease = { owner = "Alliance", tickAt = clock - 30, tickHold = 40, effectiveRequired = 120, viaGuild = true } }
assert(lane:IsActive() == false, "the channel works here")
local heardClock = lane:KeepFollowing(heardWave)
assert(heardClock and math.abs(heardClock - 70) < 1, "a wave heard in the guild is followed outside the lane too")
heardWave._remoteCaptureLease.viaGuild = nil
assert(lane:KeepFollowing(heardWave) == nil, "a wave heard elsewhere has its ticks while the channel works")
heardWave._remoteCaptureLease.viaGuild = true
instanced = true
assert(lane:KeepFollowing(heardWave) == nil, "nothing is followed from inside an instance")
instanced = false
assert(not lane:HeardHere(), "nothing is being delivered")
net.context = { transport = "CHANNEL" }
assert(not lane:HeardHere(), "a channel copy is no guild copy")
net.context = { transport = "GUILD" }
assert(lane:HeardHere(), "a guild copy being delivered")
net.context = nil

-- An enemy wave is not kept alive, however it was heard: its silence is how an assault given up
-- ends on our map (its release rarely crosses over).
refused()
local enemyWave = { _remoteCaptureLease = { owner = "Horde", tickAt = clock - 30, tickHold = 40,
    effectiveRequired = 120, viaGuild = true, lastSeen = clock - 30 } }
assert(lane:IsActive() and lane:KeepFollowing(enemyWave) == nil
    and enemyWave._remoteCaptureLease.lastSeen == clock - 30, "an enemy wave told in the guild must not be kept")
enemyWave._remoteCaptureLease.viaGuild = nil
assert(lane:KeepFollowing(enemyWave) == nil, "an enemy wave heard elsewhere must not be kept")
-- What a timer shows: the clock of a wave told in the guild, either side's, once no tick has come
-- for a while. Asking changes nothing.
local wall = Overlord.ServerNow and Overlord.ServerNow() or time()
local shownWave = { _remoteCaptureLease = { owner = "Horde", tickAt = clock - 30, tickHold = 40,
    effectiveRequired = 120, viaGuild = true, lastSeen = clock - 30, lastRemoteTs = wall - 30 } }
local shownClock = lane:WaveClock(shownWave)
assert(shownClock and math.abs(shownClock - 70) < 1, "a wave told in the guild has its clock")
assert(shownWave._remoteCaptureLease.lastSeen == clock - 30, "asking for the clock must change nothing")
shownWave._remoteCaptureLease.lastRemoteTs = wall - 2
assert(lane:WaveClock(shownWave) == nil, "ticks coming some other way say more than a clock")
shownWave._remoteCaptureLease.lastRemoteTs = wall - 30
shownWave._remoteCaptureLease.viaGuild = nil
assert(lane:WaveClock(shownWave) == nil, "a wave heard elsewhere has its ticks")
assert(lane:WaveClock({}) == nil and lane:WaveClock(nil) == nil)

-- Our own siege start said for us by whoever holds it counts as said by us: our release and our
-- capture are expected from us. Whoever else's start that was, it does not.
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("ZS", zoneState("in_progress", "elwynn_q", "A", 2, "mine")))
-- (Our own packets are in the relay's seen list from the moment they leave: a copy reaches the
-- lane straight from ReceiveFragment, without Receive.)
lane:NoteHeardPacket({ region = "x", id = "own9-1", at = GetServerTime(), target = "*", path = { me, "Nell Tester" },
    kind = "ZS", payload = zoneState("in_progress", "elwynn_q", "A", 2, "mine") }, true)
assert(#lane.outbox == 0, "the copy cancels ours")
assert(lane.spoken.elwynn_q == "mine", "the guild has our start from us")
hear("ZS", zoneState("in_progress", "elwynn_r", "A", 2, "theirs"), "Origin Tester")
assert(lane.spoken.elwynn_r == nil, "somebody else's start")
-- A release is said by the one who announced the wave, at once: a loading screen may follow in
-- the same frame. Nobody else says it for a guild mate: a follower on the point would take
-- it for hearsay, and the author's own would give way to it. From outside the guild it has no other way.
sent = {}
lane.tokens = 3
assert(offer("ZR", "elwynn_q:mine:" .. me))
assert(count("GUILD", "BF:") == 1 and #lane.outbox == 0, "the release must leave in the same frame")
assert(offer("ZR", "elwynn_r:mine:" .. me) == false, "nothing to release: the guild never had that start")
local relayedRelease = { region = "x", id = "rz1-1", at = GetServerTime(), target = "*",
    path = { "Bob Tester", me }, kind = "ZR", payload = "elwynn_s:w:Bob Tester", heardOn = "BNET" }
assert(lane:Level(relayedRelease) == nil, "a relayed release of a guild mate")
relayedRelease.path = { "Far Tester", me }
assert(lane:Level(relayedRelease), "a relayed release from outside the guild")
-- However little of the relay's byte budget is left: this copy costs it nothing, and a loading
-- screen may stop the pump before its first tick.
resetLane()
refused()
hearPresence("Bob Tester")
grouped = true
lane.spoken.elwynn_y = "gone"
for i = 1, 8 do net:Send("ZR", "elwynn_z" .. i .. ":w:" .. me, nil, true) end
sent = {}
assert(net:Send("ZR", "elwynn_y:gone:" .. me, nil, true))
assert(count("GROUP") == 0 and count("PARTY") == 0, "the budget should be spent for this test to mean anything")
assert(count("GUILD", "|ZR|") == 1, "the guild's copy of a release must not wait behind the byte budget")
grouped = false
-- It goes ahead of the rest of ours, whatever else waits for a token.
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("ZS", zoneState("in_progress", "elwynn_t", "A", 2, "mine")))
advance(9)
sent = {}
assert(offer("C", capture("elwynn_k", "Alliance", 1790017100)))
lane.tokens, lane.tokensAt = 0, clock
advance(7)
assert(#lane.outbox == 1 and count("GUILD", "BF:") == 0, "out of tokens, the capture waits")
lane.tokens, lane.tokensAt = 1, clock
assert(offer("ZR", "elwynn_t:mine:" .. me))
assert(count("GUILD", ":1:1:ZR") == 1 and count("GUILD", "BF:") == 1, "the release must go first")

-- The channel comes back while how a siege ended waits here: it was told nowhere else, and guild
-- mates follow that wave. Anything else comes again by itself.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_m", "Alliance", 1790017100)))
assert(lane:Offer({ region = "x", id = "rel9-1", at = GetServerTime(), target = "*", path = { "Far Tester", me },
    kind = "TV", payload = "far fact", heardOn = "BNET" }, { "rel9-1:1:1:far fact" }))
serverRefuses = false
s:NoteChannelReopened()
assert(not lane:IsActive(), "the channel is back")
advance(9)
assert(count("GUILD", ":1:1:C") == 1 and count("GUILD", "far fact") == 0 and #lane.outbox == 0,
    "only our own end of a siege still goes to the guild")
advance(30)
assert(count("GUILD", "BF:") == 1, "and only once")
assert(lane:CanSpeak(), "the guild is free, the channel is what took it out of use")
-- Switched off, nothing at all.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_n", "Alliance", 1790017100)))
lane:SetSwitchedOff(true)
advance(9)
assert(count("GUILD", "BF:") == 0 and #lane.outbox == 0 and not lane:CanSpeak(), "the player's switch stands")
lane:SetSwitchedOff(false)
-- Somebody said it in the meantime: nothing either.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
assert(offer("C", capture("elwynn_o", "Alliance", 1790017100)))
hear("C", capture("elwynn_o", "Alliance", 1790017100), "Origin Tester")
serverRefuses = false
s:NoteChannelReopened()
advance(9)
assert(count("GUILD", "BF:") == 0 and #lane.outbox == 0, "already said")

-- Every client keeps the latest date of a capture. Ours gives way to a copy dated at least as
-- late: hearing an earlier one, it still has something to say, or dates stay apart for minutes.
resetLane()
refused()
hearPresence("Bob Tester")
sent = {}
hear("C", capture("elwynn_u", "Alliance", 1790017005), "Origin Tester")
assert(offer("C", capture("elwynn_u", "Alliance", 1790017007)), "a later date of ours gave way to an earlier one")
advance(9)
assert(count("GUILD", "BF:") == 1, "the later date must be said")
hear("C", capture("elwynn_v", "Alliance", 1790017007), "Origin Tester")
assert(offer("C", capture("elwynn_v", "Alliance", 1790017007)) == false, "the same date was said twice")
hear("C", capture("elwynn_w", "Alliance", 1790017009), "Origin Tester")
assert(offer("ZS", zoneState("captured", "elwynn_w", "A")) == false, "an earlier date of ours was said after a later one")
-- The same while ours waits.
sent = {}
assert(offer("C", capture("elwynn_a", "Alliance", 1790017007)))
hear("C", capture("elwynn_a", "Alliance", 1790017006), "Origin Tester")
assert(#lane.outbox == 1, "a copy with an earlier date cancelled our later one")
hear("C", capture("elwynn_a", "Alliance", 1790017007), "Origin Tester")
assert(#lane.outbox == 0, "a copy with our date must cancel ours")
assert(offer("C", capture("elwynn_b", "Alliance", 1790017007)))
hear("C", capture("elwynn_b", "Alliance", 1790017008), "Origin Tester")
assert(#lane.outbox == 0, "a copy with a later date must cancel ours")
-- What we said ourselves covers our next copies, whatever is heard: same capture, same date.
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("C", capture("elwynn_c", "Alliance", 1790017007)))
advance(9)
assert(offer("ZS", zoneState("captured", "elwynn_c", "A")) == false, "our own message must cover the next copy")
-- Relayed copies keep the plain rule: said by somebody, nothing to add.
resetLane()
refused()
hearPresence("Bob Tester")
hear("C", capture("elwynn_d", "Alliance", 1790017005), "Origin Tester")
sent = {}
assert(not lane:Offer({ region = "x", id = "rel1-1", at = GetServerTime(), target = "*", path = { "Far Tester", me },
    kind = "C", payload = capture("elwynn_d", "Alliance", 1790017009), heardOn = "BNET" }, { "rel1-1:1:1:C" }),
    "a relayed copy gave no way to one already said")

-- Who told the guild a siege began tells it how it ended, at once. Anybody else waits, and
-- most often has nothing left to say.
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("ZS", zoneState("in_progress", "elwynn_g", "A", 2, "w1")))
advance(9)
sent = {}
assert(offer("C", capture("elwynn_g", "Alliance", 1790017007)))
advance(0.6)
assert(count("GUILD", "BF:") == 1, "the end of the siege we announced must leave at once")
resetLane()
refused()
hearPresence("Bob Tester")
assert(offer("ZS", zoneState("in_progress", "elwynn_h", "A", 2, "w1")))
advance(9)
sent = {}
assert(offer("ZS", zoneState("captured", "elwynn_h", "A", 0, "w1")))
advance(0.6)
assert(count("GUILD", "BF:") == 1, "so must its final state")
for _, wave in ipairs({ "another wave", "no announced wave" }) do
    resetLane()
    refused()
    hearPresence("Bob Tester")
    if wave == "another wave" then
        assert(offer("ZS", zoneState("in_progress", "elwynn_i", "A", 2, "wx")))
        advance(9)
    end
    sent = {}
    assert(offer("C", capture("elwynn_i", "Alliance", 1790017007)))
    advance(0.9)
    assert(count("GUILD", "BF:") == 0, wave .. ": said without waiting")
    advance(9)
    assert(count("GUILD", "BF:") == 1, wave .. ": never said")
end

-- Most wait long, a few little: whoever many hold one fact, about the same few speak before
-- the first copy comes back, and it is said early. Nothing else is drawn that way.
resetLane()
refused()
for _, mate in ipairs({ "Ann", "Bea", "Cid" }) do hearPresence(mate .. " Tester") end
local waitRange = { 1, 6 }
for _ = 1, 500 do
    local drawn = lane:DrawWait(waitRange, true)
    assert(drawn >= 1 and drawn <= 6, "a wait left its range: " .. tostring(drawn))
end
for peers, atMost in pairs({ [39] = 8, [99] = 8, [7] = 8 }) do
    for name in pairs(lane.peers) do lane.peers[name] = nil end
    for i = 1, peers do lane.peers["mate" .. i] = clock end
    lane.peerCountAt = nil
    local rounds, spokeTotal, firstTotal = 200, 0, 0
    for _ = 1, rounds do
        local earliest, draws = math.huge, {}
        for i = 1, peers + 1 do
            draws[i] = lane:DrawWait(waitRange, true)
            earliest = math.min(earliest, draws[i])
        end
        firstTotal = firstTotal + earliest
        for i = 1, peers + 1 do
            if draws[i] < earliest + 1 then spokeTotal = spokeTotal + 1 end
        end
    end
    assert(spokeTotal / rounds <= atMost, (peers + 1) .. " holders: " .. spokeTotal / rounds .. " spoke before the echo")
    assert(firstTotal / rounds <= 2.5, (peers + 1) .. " holders: the first spoke after " .. firstTotal / rounds .. " s")
end

-- The copy that keeps the others quiet comes back after an echo: up to half a minute, about the
-- same few speak before it does. An echo of a second changes nothing. Longer, nothing keeps them
-- quiet in time: a message has to arrive before it expires.
resetLane()
refused()
for _, echo in ipairs({ 5, 20, 30 }) do
    lane.lastEchoDelay = echo
    for peers, atMost in pairs({ [39] = 8, [99] = 12, [7] = 5 }) do
        for name in pairs(lane.peers) do lane.peers[name] = nil end
        for i = 1, peers do lane.peers["mate" .. i] = clock end
        lane.peerCountAt = nil
        local rounds, spokeTotal = 200, 0
        for _ = 1, rounds do
            local earliest, draws = math.huge, {}
            for i = 1, peers + 1 do
                draws[i] = lane:DrawWait(waitRange, true)
                assert(draws[i] >= 1 and draws[i] <= 1 + lane.ECHO_SPANS * echo, "a wait left its range: " .. tostring(draws[i]))
                earliest = math.min(earliest, draws[i])
            end
            for i = 1, peers + 1 do
                if draws[i] < earliest + echo then spokeTotal = spokeTotal + 1 end
            end
        end
        assert(spokeTotal / rounds <= atMost, (peers + 1) .. " holders, echo " .. echo .. ": " .. spokeTotal / rounds .. " spoke before it")
    end
end
lane.lastEchoDelay = 1
for _ = 1, 500 do
    local drawn = lane:DrawWait(waitRange, true)
    assert(drawn >= 1 and drawn <= 6, "an echo of a second changed the wait: " .. tostring(drawn))
end
for _, echo in ipairs({ 60, 90, 110 }) do
    lane.lastEchoDelay = echo
    for _ = 1, 500 do
        local drawn = lane:DrawWait(waitRange, true)
        assert(drawn <= math.max(6, 1 + lane.PACKET_LIFE - echo), "echo " .. echo .. ": it would expire on its way after " .. drawn)
    end
end
-- It is not lost for waiting, and a siege a slow guild would announce once it is over is not said.
resetLane()
refused()
hearPresence("Bob Tester")
lane.lastEchoDelay = 30
for name in pairs(lane.peers) do lane.peers[name] = nil end
for i = 1, 200 do lane.peers["mate" .. i] = clock end
lane.peerCountAt = nil
sent = {}
for i = 1, 16 do assert(offer("C", capture("elwynn_e" .. i, "Alliance", 1790017007))) end
lane.tokens, lane.tokensAt = 3, clock
advance(lane.OUTBOX_TTL)
assert(lane.stats.expired == 0, "a capture expired while it waited for a slow guild")
lane.outbox = { lane.outbox[1] }
advance(lane.PACKET_LIFE)
assert(#lane.outbox == 0, "a capture was lost in a slow guild")
assert(lane:Level(packet("ZS", zoneState("in_progress", "elwynn_e", "A", 2))) == nil, "a siege said too late")
assert(lane:Level(packet("ZS", zoneState("captured", "elwynn_e", "A", 0))), "a capture is always worth saying")
lane.lastEchoDelay = lane.SLOW_ECHO - 1
assert(lane:Level(packet("ZS", zoneState("in_progress", "elwynn_e", "A", 2))), "a siege is said in time")
-- 2.3.0: a siege the chain whispers to us is said in the guild when a contact gave it to us;
-- a stranger's whisper never is.
do
    local savedDirectory = Overlord.ChannelDirectory
    Overlord.ChannelDirectory = { IsContact = function(_, name) return name == "Chain Contact" end,
        IsLeafOrigin = function(_, p) return #p.path == 2 and p.path[1] == "Lone Leaf" end }
    local function whispered(by)
        local p = packet("ZS", zoneState("in_progress", "elwynn_e", "A", 2))
        p.path, p.heardOn = { "Siege Author", by, me }, "WHISPER"
        return p
    end
    assert(lane:Level(whispered("Chain Contact")), "a siege a chain contact whispered is said in the guild")
    assert(lane:Level(whispered("Some Stranger")) == nil, "a stranger's whispered broadcast is never said")
    -- (2.3.0) A leaf's own siege (out of every list) is said; its copy of another's is not.
    local own = packet("ZS", zoneState("in_progress", "elwynn_e", "A", 2))
    own.path, own.heardOn = { "Lone Leaf", me }, "WHISPER"
    assert(lane:Level(own), "a leaf's own whispered siege is not said in the guild")
    assert(lane:Level(whispered("Lone Leaf")) == nil, "a leaf's copy of another's siege is said in the guild")
    -- (2.3.0) A leaf's own siege is heard here like a contact's: no ticks follow it either.
    Overlord.ChannelDirectory.IsLeaf = function(_, name) return name == "Lone Leaf" end
    local savedContext = Overlord.Relay.context
    Overlord.Relay.context = { transport = "WHISPER", targeted = false, gateway = "Lone Leaf", hops = 0 }
    assert(lane:HeardHere(), "a leaf's own whispered siege is not followed as heard here")
    Overlord.Relay.context = { transport = "WHISPER", targeted = false, gateway = "Lone Leaf", hops = 1 }
    assert(not lane:HeardHere(), "a leaf's copy of another's siege is followed as heard here")
    Overlord.Relay.context = savedContext
    Overlord.ChannelDirectory = nil
    assert(lane:Level(whispered("Chain Contact")) == nil, "no directory: no whispered broadcast is said")
    Overlord.ChannelDirectory = savedDirectory
end

-- ---------------------------------------------------------------------------
-- (10) Wiring, read in the source
-- ---------------------------------------------------------------------------
local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return (text:gsub("\r\n", "\n"))
end
local source = read("Sync.lua")
for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
    local _, registered = source:gsub('RegisterEvent, syncFrame, "' .. event .. '"%)', "")
    assert(registered == 2, event .. " must be registered at start and on leaving an instance, found " .. registered)
end
local barrier = source:find("if Overlord.InstanceSuspended or IsInInstance() then return end", 1, true)
local branch = source:find('elseif event == "CHAT_MSG_CHANNEL_NOTICE" or', 1, true)
assert(barrier and branch and branch > barrier, "the notice must sit behind the instance barrier")
local guard = source:find("if not Overlord.InstanceSuspended and not IsInInstance() then", 1, true)
local firstRegistration = source:find('RegisterEvent, syncFrame, "CHAT_MSG_CHANNEL_NOTICE"', 1, true)
assert(guard and firstRegistration and firstRegistration > guard, "at start the notice is registered outside instances only")
local suspend = source:find("function Overlord.Sync:Suspend()", 1, true)
assert(source:find("syncFrame:UnregisterAllEvents()\n    if self.OnNetworkSuspend then self:OnNetworkSuspend() end", suspend, true),
    "a suspension must empty the lane")
local toc = read("Overlord.toc")
assert(toc:find("SyncRelay.lua\nSyncGuild.lua\n", 1, true), "SyncGuild.lua must load right after SyncRelay.lua")
for _, workflow in ipairs({ ".github/workflows/validate.yml", ".github/workflows/release.yml" }) do
    assert(read(workflow):find("lua5.1 tests/forever_guild_lane.test.lua", 1, true), workflow .. " misses this test")
end
-- The siege engine asks the lane in these places, or a guild mate on the point starts again from 0:00.
assert(read("ZoneCaptureLease.lua"):find("viaGuild", 1, true), "a lease must know it was told in the guild")
local control = read("ZoneControl.lua")
assert(control:find("function Overlord.ZoneControl:UpdateHoldTimer%(zone, deltaTime%)\n    if not zone.isHolding then return end\n[^\n]*\n[^\n]*KeepFollowing"),
    "a follower mounted or contested on the point keeps following")
assert(read("Sync.lua"):find("GuildFinalEndsLocalWave(zone, owner, ts)", 1, true), "a final ZS dated before our last tick")
assert(read("SyncAux.lua"):find("GuildLane:AsksAboutWave(zone)", 1, true), "the stale poll of a wave told in the guild")
local leaseSource = read("ZoneCaptureLease.lua")
assert(leaseSource:find("function Lease:MaybeExpire%(zone%).-KeepFollowing.-HARD_TTL"),
    "the sweep must ask, or a siege dies at 150 s for whoever is off the fronts")
assert(read("Zones.lua"):find("function Overlord.Zones:GetObserverHoldTimeElapsed%(zone%).-WaveClock"),
    "an observer's timer must show the wave's clock")
assert(read("SyncAux.lua"):find("function Overlord.Sync:RequestObserverCaptureConfirmationIfComplete%(zone%).-WaveClock.-GetObserverHoldTimeElapsed"),
    "a clock at 100 % must not make every observer ask together")
assert(control:find("zone.owner ~= Overlord.PlayerFaction then return false end\n    -- 2.1.1: no ticks in the guild", 1, true),
    "a silent wave must not be taken over while the guild is in use")

-- A wave given up before its start was said: the guild hears of neither, or it would follow a
-- wave nobody holds. Through the relay, as the release leaves: only a carried packet gets offered.
do
    resetLane()
    refused()
    hearPresence("Bob Tester")
    sent = {}
    assert(offer("ZS", zoneState("in_progress", "elwynn_v", "A", 1, "brief")))
    assert(lane.outbox[1] and lane.outbox[1].startedWave == "brief", "fixture: the start waits")
    assert(net:Send("ZR", "elwynn_v:other:" .. me, nil, true))
    assert(#lane.outbox == 1 and lane.stats.cancelled == 0, "the release of another wave leaves it alone")
    assert(net:Send("ZR", "elwynn_v:brief:" .. me, nil, true))
    assert(#lane.outbox == 0 and lane.stats.cancelled == 1, "a start waiting must go with its release")
    assert(lane.spoken.elwynn_v == nil, "nothing was said about that wave")
    advance(30)
    assert(count("GUILD", ":1:1:ZS") == 0 and count("GUILD", "|ZR|") == 0, "the guild heard about a wave given up")
    assert(lane:Level(packet("ZR", "elwynn_v:brief:" .. me)) == nil, "a second copy of that release")
    -- Several short waves on the edge of the disc, each released while its start still waits in the
    -- relay's queue behind its other copies (here: offered after its release): none of them comes out.
    assert(net:Send("ZR", "elwynn_v:queued:" .. me, nil, true))
    advance(3)
    assert(net:Send("ZR", "elwynn_v:again:" .. me, nil, true))
    assert(lane.released.elwynn_v.queued and lane.released.elwynn_v.again, "the releases were not noted")
    assert(not offer("ZS", zoneState("in_progress", "elwynn_v", "A", 1, "queued"))
        and not offer("ZS", zoneState("in_progress", "elwynn_v", "A", 1, "again"))
        and #lane.outbox == 0 and lane.stats.cancelled == 3, "a start offered after its release")
    advance(30)
    assert(count("GUILD", ":1:1:ZS") == 0 and count("GUILD", "|ZR|") == 0, "the guild heard about a wave given up")
    -- The next wave of ours on that point is told as usual, and its end too.
    assert(offer("ZS", zoneState("in_progress", "elwynn_v", "A", 1, "next")))
    advance(10)
    assert(count("GUILD", ":1:1:ZS") == 1 and lane.spoken.elwynn_v == "next", "the next start was not said")
    assert(net:Send("ZR", "elwynn_v:next:" .. me, nil, true))
    assert(count("GUILD", "|ZR|") == 1, "the end of a wave the guild heard of must be said")
    -- A siege of ours failing on a point the other side holds: its state gives it back, with our wave
    -- and our name. Their real final, told again by us, carries its author's name.
    local function backToThem(name)
        return (zoneState("captured", "elwynn_v", "H", 0, "brief"):gsub("Dwarf Tester", name))
    end
    assert(lane:Level(packet("ZS", backToThem(me))) == nil, "a failed siege is not a capture to tell the guild")
    assert(lane:Level(packet("ZS", backToThem("Horde Author"))), "their final told again by us")
    assert(lane:Level(packet("ZS", (zoneState("captured", "elwynn_v", "A", 0, "ours"):gsub("Dwarf Tester", me)))),
        "our own capture")
    local relayed = packet("ZS", backToThem("Far Tester"))
    relayed.path = { "Far Tester", "Bob Tester" }
    assert(lane:Level(relayed), "a relayed final of theirs")
    -- A release is remembered while the relay may still hand over its start (its TTL: 120 s), even
    -- when a later release on that point prunes the list, and forgotten after RELEASED_SEC.
    local function release(wave) return lane:Carries(packet("ZR", "elwynn_w:" .. wave .. ":" .. me), 1) end
    release("first")
    advance(121)
    release("second")
    assert(lane.released.elwynn_w.first and lane.released.elwynn_w.second,
        "a release forgotten while its start may still come")
    advance(lane.RELEASED_SEC - 120)
    release("third")
    assert(lane.released.elwynn_w.first == nil and lane.released.elwynn_w.second and lane.released.elwynn_w.third,
        "old releases are kept")
end
print("Guild lane: reports and wiring OK")
print("Forever guild lane: refused channel, probe, guild fallback, rates, echo, reception and instances OK")
