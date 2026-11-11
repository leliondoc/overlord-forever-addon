-- Channel state and guild fallback of the relay (2.1.1).
--
-- Since the launch of Forever (2026-11-04) the server refuses addon messages on custom
-- channels: SendAddonMessage answers 0, then a notice the chat frames do not show for a
-- channel they do not display (NOT_ALLOWED_IN_CHANNEL), or code 7 straight away. The
-- client went on talking to nobody, with a green network dot.
--
-- This file does two things:
--  1. It says when the channel does not work. A refusal makes Sync:GetChannelId() answer
--     nil, so every channel user behaves as without a channel; one small probe every five
--     minutes finds out when the server takes it back.
--  2. While the channel does not work, it carries the few messages that make a network
--     over the GUILD addon chat type: our presence, spaced out, and captures. The presence
--     gives guild mates routes to each other; everything else (maps, ranking, catch-up)
--     then travels by whisper between those neighbours, as it always did.
--
-- Guild messages are kept rare on purpose. Each one may scroll the chat frame of every
-- guild member (measured on the beta by another addon's author), and a player who sent many
-- of them may have every later addon message dropped with a result of 0 (US forum, launch
-- day, cause unknown). Hence, whatever the population:
--   * nothing in the guild while the channel works (but our own last words, once, if they were
--     waiting when it came back: see Flush), and nothing but presence as long as no other
--     Overlord has been heard there;
--   * one message per TOKEN_SEC per client, and a ceiling for the whole guild, counted on
--     what is heard there (SOFT_PER_MIN, HARD_PER_MIN);
--   * a message waits a moment and is given up if someone else has said the same thing;
--   * a packet relayed to us (a friend's, a group mate's, a chain contact's whisper: see Level) is
--     said by a few of its holders, from a share of about two a minute for the whole guild
--     (RELAYED_SEC), unless it is a capture our own map has just taken;
--   * nothing ever answers a guild message in the guild: no request goes there, and what is
--     heard there is never said there again;
--   * a siege is said when it starts and when it ends, never its ticks: whoever follows it
--     keeps its clock in the meantime (KeepFollowing), and a guild mate's capture ends a wave
--     of our own (CaptureLease:GuildFinalEndsLocalWave), as nobody on a point hears the others;
--   * our own copy comes back from the server in about a second, and how long it takes sets
--     how long a message waits for someone else to say it (DrawWait). When it stops coming back
--     the rate falls to one message per five minutes, and the panel says so.
-- A client up to 2.1.0 ignores what it hears on GUILD (Sync:OnAddonMessage), so nothing here
-- changes for it. Inside an instance nothing is sent or read, and nothing waits to be sent.
local addon = Overlord
local sync = addon.Sync
local lane = {
    TOKEN_SEC = 12, TOKEN_BURST = 3,
    SOFT_PER_MIN = 4, HARD_PER_MIN = 10, PER_SENDER_PER_MIN = 3,
    -- More than TOKEN_BURST + 60 / TOKEN_SEC a minute is not this code: it is not read (OnHeard).
    INTAKE_PER_MIN = 12,
    OUTBOX_MAX = 16, OUTBOX_TTL = 60,
    MAX_FRAGMENTS = 2,
    COVER_SEC = 30, SIEGE_COVER_SEC = 60, SITE_COVER_SEC = 120, DATE_SKEW = 5,
    -- What somebody else said can keep our own report of a capture quiet this long (a
    -- raid taking one point), and no longer. Memory of what was heard: COVER_ROWS lines.
    HEARD_COVER_SEC = 10, COVER_ROWS = 512,
    -- How many of the holders of a relayed packet say it in the guild, on average; the
    -- share of the guild's messages relayed packets may take, said or heard; how long a
    -- capture on our own map counts as proof that a relayed copy of it was not made up.
    RELAY_SPEAKERS = 3, RELAYED_SEC = 30, RELAYED_BURST = 3, PROVEN_SEC = 120,
    -- How long past its end a silent wave is still followed (its capture may be on its way), and
    -- how long without a tick makes a wave told in the guild silent (ticks come every 5 s).
    SIEGE_GRACE = 15, TICK_SEC = 8,
    -- 2.4.0: from this hold time on (a capital's siege) a capture is told again while it runs (Level).
    BEAT_MIN_HOLD = 300,
    -- (Less than Sync:CanCreditDirectCapture leaves between two credits of a sender on a zone.)
    CLOSED_WAVE_SEC = 30,
    -- Our own releases are remembered as long as the relay may still hand over a start of theirs
    -- (its TTL of 120 s, counted in whole seconds, and a margin): a fight on the edge of a disc
    -- makes many short waves on one point.
    RELEASED_SEC = 150,
    -- A slow guild: how many of our echoes a message may wait for somebody else to say it, and
    -- the echo past which a siege would be announced about when it ends. PACKET_LIFE: wait and
    -- way together, for it to arrive alive (the relay's TTL is 120 s).
    ECHO_SPANS = 2.5, SLOW_ECHO = 20, PACKET_LIFE = 100,
    -- One presence per PRESENCE_PER_PEER seconds per guild mate running Overlord: about
    -- 1.3 messages a minute for the whole guild, whatever its size.
    PRESENCE_MIN = 120, PRESENCE_PER_PEER = 45, PRESENCE_ALONE = 600,
    PEER_MEMORY = 3600, HEARD_FRESH = 300,
    ECHO_PATIENCE = 300, UNHEARD_GAP = 300, ECHO_SENDS = 3, ECHO_MEMORY = 900, ECHO_ROWS = 16,
    NO_GUILD_BACKOFF = 300,
    -- The channel: how long a join may run before it counts as down, how much talking to
    -- nobody makes it "silent", how often and how patiently a refused one is tried again.
    JOIN_GRACE = 60, SETTLE_SEC = 180,
    SILENT_SEC = 300, SILENT_SENDS = 3,
    PROBE_SEC = 300, PROBE_WAIT = 20, PROBE_AFTER_INSTANCE = 20,
    PROBE_MESSAGE = "PB",
    outbox = {}, awaiting = {}, peers = {}, cover = {}, ownCover = {}, coverDate = {}, log = {}, spoken = {},
    intake = {}, closedWaves = {}, released = {},
    stats = { sent = 0, failed = 0, heard = 0, echoes = 0, covered = 0, cancelled = 0, expired = 0,
        capped = 0, noListener = 0, notSpeaker = 0, refusals = 0, reopened = 0, probes = 0, tooFast = 0 },
}
addon.GuildLane = lane

local TERMINAL, ALERT, ROUTINE = 3, 2, 1
-- Any path: a capture told by a friend of ours is what the guild would otherwise never hear.
-- (2.4.0: ZD, defenders a capturer cannot see: said for the guild mates that carry it to the
-- other faction, and on that side for the capturer.)
local FIXED_LEVEL = { C = TERMINAL, TV = TERMINAL, GE = TERMINAL, GX = TERMINAL,
    GD = TERMINAL, FC = ALERT, ZD = ALERT }
-- Our own only: nobody relays a presence or a keep claim, and a relayed guild kill alert has
-- somebody else to say it.
local OWN_LEVEL = { NH = ROUTINE, OC = TERMINAL, GW = ROUTINE }
-- How long a message waits for someone else to say it: { first, last } in seconds. Long
-- enough for the first copy to come back (about a second) in a raid of one guild.
local WAIT = { [TERMINAL] = { 1, 6 }, [ALERT] = { 0.5, 5.5 }, [ROUTINE] = { 0, 5 } }
local RELAYED_WAIT = { 2, 8 }
-- Who told the guild a siege began tells it how it ended, at once: everybody follows that wave,
-- and a capture heard early also ends the waves of those about to finish theirs (fewer dates).
local ANNOUNCED_WAIT = { 0, 0.5 }

local function now() return GetTime() end
-- The wave of a zone state, as BroadcastZoneState writes it.
local function stateWave(payload)
    return payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*)")
end
local function readable(value)
    return value ~= nil and (not canaccessvalue or canaccessvalue(value))
end
local function outside()
    return not addon.InstanceSuspended and not IsInInstance()
end

-- ---------------------------------------------------------------------------
-- The channel
-- ---------------------------------------------------------------------------

-- A notice that says our messages do not get through. THROTTLED is not one of them.
lane.REFUSAL_NOTICES = { NOT_ALLOWED_IN_CHANNEL = true, TRIAL_RESTRICTED = true, MUTED = true,
    BANNED = true, NOT_MEMBER = true }
local CODE_INVALID_CHANNEL = 7
local CODE_NOT_IN_GUILD = 10

local function noticeNamesOurChannel(channelName, channelIndex, baseName)
    local mine = sync:GetChannelBaseName():lower()
    if readable(baseName) and type(baseName) == "string" and baseName ~= "" then
        return baseName:lower() == mine
    end
    if readable(channelName) and type(channelName) == "string" then
        -- "5. OverlordF"
        local plain = channelName:gsub("^%d+%.%s*", "")
        if plain:lower() == mine then return true end
    end
    if readable(channelIndex) and tonumber(channelIndex) then
        return tonumber(channelIndex) == sync:GetJoinedChannelId()
    end
    return false
end

-- Arguments of CHAT_MSG_CHANNEL_NOTICE(_USER). They can be secret: nothing is compared
-- before canaccessvalue, and the frame does not even call this inside an instance.
function sync:OnChannelNotice(text, _, _, channelName, _, _, _, channelIndex, baseName)
    if not readable(text) or type(text) ~= "string" or not lane.REFUSAL_NOTICES[text] then return end
    if not noticeNamesOurChannel(channelName, channelIndex, baseName) then return end
    self:NoteChannelRefused(text)
end

local function touchFinder()
    local finder = addon.GroupFinder
    if finder and finder.Touch then finder:Touch() end
end

function sync:NoteChannelRefused(why)
    local at = now()
    self._channelLastRefusalAt = at
    self._channelRefusedWhy = why
    lane.stats.refusals = lane.stats.refusals + 1
    -- 2.3.1: remembered across a /reload or a login too (Sync:ChannelRefusedLately).
    if OverlordDB and type(time) == "function" then OverlordDB.channelRefusedAt = time() end
    if self._channelRefusedAt then return end
    self._channelRefusedAt = at
    self._channelSilence = nil
    self:ScheduleChannelProbe(lane.PROBE_SEC)
    touchFinder()
    -- The presence that met the refusal reached nobody. One more soon, for the guild.
    local net = addon.Relay
    if lane:IsActive() and net and net.ScheduleReturnPresence then net:ScheduleReturnPresence() end
end

function sync:NoteChannelReopened()
    if not self._channelRefusedAt then return end
    self._channelRefusedAt, self._channelRefusedWhy = nil, nil
    if OverlordDB then OverlordDB.channelRefusedAt = nil end
    self._channelSilence, self._channelHeardAt = nil, nil
    lane.probeGeneration = (lane.probeGeneration or 0) + 1
    lane.stats.reopened = lane.stats.reopened + 1
    touchFinder()
end

function sync:ScheduleChannelProbe(delay)
    lane.probeGeneration = (lane.probeGeneration or 0) + 1
    local generation = lane.probeGeneration
    C_Timer.After(delay, function()
        if lane.probeGeneration == generation then sync:ProbeChannel() end
    end)
end

-- One message, read by nobody: a client of any version drops an unknown type. Taken back
-- when the server gives no refusal within PROBE_WAIT, or sends our own copy back.
function sync:ProbeChannel()
    if not self._channelRefusedAt then return end
    self:ScheduleChannelProbe(lane.PROBE_SEC * (0.9 + 0.2 * math.random()))
    local id = outside() and self:GetJoinedChannelId() or nil
    if not id then return end
    local sentAt = now()
    lane.stats.probes = lane.stats.probes + 1
    if self:SendAddonChecked(lane.PROBE_MESSAGE, "CHANNEL", id) ~= true then return end
    local generation = lane.probeGeneration
    C_Timer.After(lane.PROBE_WAIT, function()
        if lane.probeGeneration ~= generation or not outside() then return end
        if sync._channelRefusedAt and (sync._channelLastRefusalAt or 0) < sentAt then
            sync:NoteChannelReopened()
        end
    end)
end

-- Called with every result of a channel send (Sync:SendAddonChecked).
function sync:NoteChannelSendResult(result, ok)
    if result == CODE_INVALID_CHANNEL then return self:NoteChannelRefused("code 7") end
    if not ok or self._channelRefusedAt then return end
    local at, silence = now(), self._channelSilence
    if not silence or (self._channelHeardAt and self._channelHeardAt >= silence.since) then
        silence = { sends = 0, since = at }
        self._channelSilence = silence
    end
    silence.sends = silence.sends + 1
end

-- Accepted by the game and not refused, yet nobody has been heard there for five minutes:
-- alone on the channel, or a refusal that does not reach us. Anything heard ends it.
function sync:IsChannelSilent()
    local silence = self._channelSilence
    if not silence or silence.sends < lane.SILENT_SENDS then return false end
    if self._channelHeardAt and self._channelHeardAt >= silence.since then return false end
    return now() - silence.since >= lane.SILENT_SEC
end

function sync:OnNetworkSuspend()
    lane.generation = (lane.generation or 0) + 1
    lane.probeGeneration = (lane.probeGeneration or 0) + 1
    lane.armedAt, lane.notJoinedSince = nil, nil
    lane.outbox, lane.awaiting = {}, {}
    self._channelSilence, self._channelHeardAt = nil, nil
    -- 2.2.0: the channel's member list stops too (SyncDirectory.lua).
    if addon.ChannelDirectory then addon.ChannelDirectory:Suspend() end
end

function sync:OnNetworkResume()
    if self._channelRefusedAt then
        self:ScheduleChannelProbe(lane.PROBE_AFTER_INSTANCE * (1 + math.random()))
    end
    if addon.ChannelDirectory then addon.ChannelDirectory:Resume() end
end

-- ---------------------------------------------------------------------------
-- Is the guild in use?
-- ---------------------------------------------------------------------------

function lane:IsSwitchedOff()
    return type(OverlordDB) == "table" and OverlordDB.guildLaneOff == true
end

function lane:SetSwitchedOff(off)
    if type(OverlordDB) ~= "table" then return false end
    OverlordDB.guildLaneOff = off and true or nil
    if off then self.outbox = {} end
    return true
end

function lane:ChannelDown()
    -- Refused by the server, or a join the game answered with a request of its own.
    local down
    if sync:IsChannelClosed() then
        down = true
    elseif not sync:GetJoinedChannelId() then
        -- Not joined for a while: a join still running (40 s at most at login) is no verdict.
        local at = now()
        self.notJoinedSince = self.notJoinedSince or at
        down = at - self.notJoinedSince >= self.JOIN_GRACE
    else
        self.notJoinedSince = nil
        down = sync:IsChannelSilent()
    end
    -- (Since when, for Describe: the member list needs a minute or two to answer.)
    if down then self.downSince = self.downSince or now() else self.downSince = nil end
    return down
end

-- Free to speak in the guild, whatever the channel does?
function lane:CanSpeak()
    if addon.RelayEnabled == false or not outside() or self:IsSwitchedOff() then return false end
    if not (IsInGuild and IsInGuild()) then return false end
    return not (self.noGuildUntil and now() < self.noGuildUntil)
end

function lane:IsActive()
    return self:CanSpeak() and self:ChannelDown()
end

-- Somebody the guild hears by itself?
local function isGuildMate(self, name)
    local lb = addon.Leaderboard
    return self.peers[name:lower()] ~= nil
        or (lb and lb.IsLocalGuildRosterMember and lb:IsLocalGuildRosterMember(name)) or false
end

-- Our start of this wave, still waiting in the box.
local function waitingStart(self, zone, wave)
    for i, entry in ipairs(self.outbox) do
        if entry.startedZone == zone and entry.startedWave == wave then return i end
    end
    return nil
end

-- What our client says when a siege of ours fails on a point the other side holds: the point goes
-- back to them, with our wave and our name. Its release ends whatever the guild was told.
local function isFailedSiege(p)
    if #p.path > 1 then return false end
    local code, capturer = p.payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:([AH]?):[^:]*:[^:]*:[^:]*:([^:]*)")
    return code ~= nil and code ~= tostring(addon.PlayerFaction):sub(1, 1) and sync:IsSenderLocalPlayer(capturer)
end

-- The level of a packet in the guild, nil when it stays out of it.
function lane:Level(p)
    local kind, payload = p.kind, p.payload
    if type(payload) ~= "string" then return nil end
    -- A broadcast whispered to us travels the chain (SyncDirectory, 2.2.0) and comes from one of
    -- our contacts: those are said here like any relayed packet (same share, same few speakers),
    -- or a siege a lone player starts never reaches the guilds the chain touches. A leaf's own
    -- fact too (a player out of the member lists: SyncDirectory IsLeafOrigin). Any other
    -- broadcast whispered to us is a modified client's: never said to the whole guild.
    if p.heardOn == "WHISPER" then
        local directory, from = addon.ChannelDirectory, p.path and p.path[#p.path - 1]
        if not (directory and directory.IsContact and type(from) == "string"
            and (directory:IsContact(from) == true
                or (directory.IsLeafOrigin and directory:IsLeafOrigin(p) == true))) then
            return nil
        end
    end
    local level = FIXED_LEVEL[kind]
    if level then return level end
    local own = #p.path == 1
    level = OWN_LEVEL[kind]
    if level then return own and level or nil end
    if kind == "ZS" then
        local status, hold = payload:match("^[^:]+:([^:]+):[^:]*:(%d*)")
        -- A final names its wave. Without one it is a point handed back, and an "available" says
        -- no more than its ZR: receivers drop them, and the guild pays for every message.
        if status == "captured" then
            local wave = stateWave(payload)
            return wave and wave ~= "" and not isFailedSiege(p) and TERMINAL or nil
        end
        -- The defenders' early warning, not the ticks of the siege (see KeepFollowing).
        if status == "in_progress" and (tonumber(hold) or 999) <= 45
            and (self.lastEchoDelay or 0) < self.SLOW_ECHO then return ALERT end
        -- 2.4.0: the siege of a capital (eight minutes) is told again while it runs, once per
        -- SIEGE_COVER_SEC for the whole guild (CoverKey), as along the member list (SyncDirectory
        -- chainShape): whoever logs in or reaches the front after its start saw nothing of it,
        -- and its clock drifts when it is put on hold. Never the ticks of an ordinary capture.
        if status == "in_progress" and (self.lastEchoDelay or 0) < self.SLOW_ECHO
            and (tonumber(payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%d+)")) or 0) >= self.BEAT_MIN_HOLD then
            local wave = stateWave(payload)
            if wave and wave ~= "" then return ROUTINE end
        end
        return nil
    end
    -- The end of a wave is news to those who follow it: the guild has it from us only if it
    -- had the start from us (a raid leaving a point would say it once per player), and from
    -- nobody else: a follower on the point takes a relayed one for hearsay, and the author's
    -- own would give way to it. Only an author outside the guild has it said for them.
    if kind == "ZR" then
        if #p.path > 1 then return not isGuildMate(self, p.path[1]) and TERMINAL or nil end
        local zone, wave = payload:match("^([^:]*):([^:]*)")
        -- (Or its start waits to be said: Offer takes it back, and then nothing is said at all.)
        return zone and wave and (self.spoken[zone] == wave or waitingStart(self, zone, wave)) and TERMINAL or nil
    end
    if kind == "OP" then
        return payload:match("^v%d+:[^:]*:([^:]*)") == "in_progress" and ROUTINE or nil
    end
    -- Map news of a single page: said before our presence shows a map that differs, or
    -- the whole guild would ask us for it in the same second.
    if kind == "ZA" then
        return own and payload:match("^@P%-%d+%-%d+:1:1|") ~= nil and ROUTINE or nil
    end
    return nil
end

-- 2.4.0: a wave of this point ended without a capture (released, lost): the next one is a new
-- start, said within RESTART_GAP seconds. Its cover (one siege start per point and
-- SIEGE_COVER_SEC) kept a capture begun again within the minute out of the guild, hence from the
-- other faction, for good when its timer had passed 45 s by the time the cover ended: their map
-- showed the point safe while it was being taken. Not at once: a fight on the edge of a point makes
-- a wave every few seconds, and the guild pays for every message. (The chain forgets it at once.)
lane.RESTART_GAP = 30
-- wave: the one that ended, when known. Only its own start leaves the box: a release that comes
-- after the start of the next wave (the relay does not keep their order) must not take that one.
function lane:ForgetSiege(zone, wave)
    if type(zone) ~= "string" or zone == "" then return end
    if type(wave) ~= "string" or wave == "" then wave = nil end
    local limit = now() - self.SIEGE_COVER_SEC + self.RESTART_GAP
    for _, code in ipairs({ "A", "H" }) do
        local key = "SIEGE|" .. zone .. "|" .. code
        if self.cover[key] and self.cover[key] > limit then self.cover[key] = limit end
        if self.ownCover[key] and self.ownCover[key] > limit then self.ownCover[key] = limit end
        -- Somebody else's start of that point still waiting here (for its share): its wave may
        -- be the one that just ended. Not said after the end.
        for i = #self.outbox, 1, -1 do
            local entry = self.outbox[i]
            if entry.relayed and entry.cover == key and (not wave or not entry.wave or entry.wave == wave) then
                table.remove(self.outbox, i)
            end
        end
    end
end

-- 2.4.0: one timer per point (CaptureLease YieldToElderWave): our capture gave way to an elder
-- one. True when the guild never heard of ours: its start leaves the box if it waited there, and
-- one still on its way through the relay is refused like the start of a released wave (Offer).
-- False when ours was said: the guild follows it, its release is to be said.
function lane:NoteYielded(zone, wave)
    if type(zone) ~= "string" or type(wave) ~= "string" or wave == "" then return true end
    if self.spoken[zone] == wave then return false end
    for i = #self.outbox, 1, -1 do
        local entry = self.outbox[i]
        if entry.startedZone == zone and entry.startedWave == wave then
            table.remove(self.outbox, i)
            self.stats.cancelled = self.stats.cancelled + 1
        end
    end
    local at, waves = now(), self.released[zone] or {}
    for given, releasedAt in pairs(waves) do
        if at - releasedAt > self.RELEASED_SEC then waves[given] = nil end
    end
    waves[wave] = at
    self.released[zone] = waves
    return true
end

-- What tasksFor asks: does this broadcast take a guild copy?
function lane:Carries(p, fragmentCount)
    -- Our own release, whatever the guild does with it: the start of that wave may still wait in
    -- the relay's queue behind its other copies, and Offer must not take it after this.
    if p.kind == "ZR" and #p.path == 1 and type(p.payload) == "string" then
        local zone, wave = p.payload:match("^([^:]*):([^:]*)")
        if zone and wave ~= "" then
            local at, waves = now(), self.released[zone] or {}
            for given, releasedAt in pairs(waves) do
                if at - releasedAt > self.RELEASED_SEC then waves[given] = nil end
            end
            waves[wave] = at
            self.released[zone] = waves
            self:ForgetSiege(zone, wave)
        end
    end
    if p.skipGuild or p.groupOnly or p.target ~= "*" or fragmentCount > self.MAX_FRAGMENTS then return false end
    return self:Level(p) ~= nil and self:IsActive()
end

-- Two copies of one fact have one key: the same capture told by several players (or by
-- its C and its final ZS), the same siege, the same outpost under attack. Nil: never covered.
function lane:CoverKey(p)
    local kind, payload = p.kind, p.payload
    if kind == "NH" or type(payload) ~= "string" then return nil end
    if kind == "C" then
        local zone, faction = payload:match("^([^:]*):[^:]*:([^:]*):")
        if zone then return "CAP|" .. zone .. "|" .. faction:sub(1, 1), self.COVER_SEC end
    elseif kind == "ZS" then
        local zone, status, code = payload:match("^([^:]*):([^:]*):[^:]*:[^:]*:([AH]?)")
        if status == "captured" then return "CAP|" .. zone .. "|" .. code, self.COVER_SEC end
        if status == "in_progress" then return "SIEGE|" .. zone .. "|" .. code, self.SIEGE_COVER_SEC end
    elseif kind == "OP" then
        local site = payload:match("^v%d+:([^:]*):")
        if site then return "OP|" .. site, self.SITE_COVER_SEC end
    elseif kind == "ZD" then
        -- 2.4.0: one report per point, whoever counted the defenders, however many, whatever
        -- wave they name (a field anybody writes must not make as many facts as it has values).
        local zone = payload:match("^([^:]*):")
        if zone then return "ZD|" .. zone, 25 end
    end
    return kind .. "|" .. payload, self.COVER_SEC
end

-- The date a capture is told with. Every client keeps the latest one (OnReceiveCapture).
local function captureDate(p)
    if p.kind == "C" then return tonumber(p.payload:match("^[^:]*:[^:]*:[^:]*:(%d+)")) end
    if p.kind == "ZS" then return tonumber(p.payload:match("^[^:]*:captured:[^:]*:[^:]*:[^:]*:(%d+)")) end
    return nil
end

-- Has this fact been said? By us: for its whole time. By somebody else: likewise, except
-- for our own report of a capture (firm): a line heard in a guild is only somebody's word,
-- and one posted in advance must not keep the real capturer quiet. It takes a copy heard
-- just now, as in a raid taking one point, and dated at least as late as ours: co-capturers
-- date it a second or two apart, and without the latest date maps stay apart for minutes.
-- Our next copies then count as said.
local function isCovered(self, key, seconds, at, firm, date)
    if not key then return false end
    local limit = seconds or self.COVER_SEC
    local mine = self.ownCover[key]
    if mine and at - mine < limit then return true end
    local heard = self.cover[key]
    if not heard then return false end
    if not firm then return at - heard < limit end
    if at - heard >= math.min(limit, self.HEARD_COVER_SEC) then return false end
    if date and (self.coverDate[key] or 0) < date then return false end
    self.ownCover[key] = heard
    return true
end

local function pruneCover(book, at, oldest)
    local kept = 0
    for key, said in pairs(book) do
        if at - said >= oldest then book[key] = nil else kept = kept + 1 end
    end
    return kept
end

-- mine: said by us. Otherwise heard; a guild mate flooding made-up facts fills only that
-- memory, which is worth less than its size past COVER_ROWS.
function lane:RememberCover(key, at, mine)
    if mine then self.ownCover[key] = at else self.cover[key] = at end
    self.coverCount = (self.coverCount or 0) + 1
    if self.coverCount <= 128 then return end
    self.coverCount = 0
    pruneCover(self.ownCover, at, self.SITE_COVER_SEC)
    if pruneCover(self.cover, at, self.SITE_COVER_SEC) > self.COVER_ROWS then self.cover = {} end
    self.coverDate = {}
end

-- The guild hears that a siege starts and that it ends, not its ticks: one a minute per wave
-- would make it talk all the time. So the silence of a wave of our side proves nothing until
-- it should be over; on the 75 s silence of a channel, a guild mate on the point would start
-- again from 0:00, then refuse the real capture in favour of that new wave. Gives the wave's clock
-- while that lasts. A wave told in the guild is as silent for a guild mate outside the lane (its
-- channel works, the guild switched off). A wave heard elsewhere whose ticks do reach us (a group, a
-- friend) is another matter: their silence says what it always did. An enemy wave has no such claim
-- either: silence is how an assault given up ends on our map. Called by the zone timers and the lease
-- sweep; nothing is sent.
function lane:KeepFollowing(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or not remote.tickAt or remote.owner ~= addon.PlayerFaction or not outside() then return nil end
    if not remote.viaGuild and (not self:IsActive() or remote.tickAt ~= remote.openedAt) then return nil end
    local at = now()
    local clock = (tonumber(remote.tickHold) or 0) + at - remote.tickAt
    if clock >= (tonumber(remote.effectiveRequired) or 120) + self.SIEGE_GRACE then return nil end
    remote.lastSeen = at
    if remote.directValidated then remote.lastDirectSeen = at end
    if zone._zsOfficialCapturerSeenAt then zone._zsOfficialCapturerSeenAt = at end
    return clock
end

-- What the ticks that do not come would have proved before a capture counts for its author
-- (Sync:CanCreditDirectCapture): that author told us in the guild when this wave began, and it has
-- run as long since. A guild mate writing both gets what writing the ticks gets on a channel.
local function waveProves(remote, sender, faction, minObserved, minHold)
    if not remote or not remote.guildAuthor or remote.credited or not remote.tickAt or remote.owner ~= faction then
        return false
    end
    if not sync:CaptureContributorMatchesSender(remote.originName, sender) then return false end
    local at = now()
    local clock = (tonumber(remote.tickHold) or 0) + at - remote.tickAt
    if at - remote.openedAt < minObserved or clock < minHold or clock - (tonumber(remote.openedHold) or 0) < minHold then
        return false
    end
    -- One wave, one capture, like the ticks it stands in for.
    remote.credited = true
    return true
end

function lane:ProvesWave(sender, zoneId, faction, minObserved, minHold)
    local zone = addon.Fronts and addon.Fronts:GetZone(zoneId)
    if waveProves(zone and zone._remoteCaptureLease, sender, faction, minObserved, minHold) then return true end
    local closed = self.closedWaves[zoneId]
    return closed ~= nil and now() - closed.closedAt <= self.CLOSED_WAVE_SEC
        and waveProves(closed, sender, faction, minObserved, minHold)
end

-- Somebody else's final ends the wave we follow, and its author's own comes seconds later with the
-- later date every client keeps: what it proved still stands for that long.
function lane:NoteWaveClosed(zoneId, remote)
    if not remote.guildAuthor then return end
    self.closedWaves[zoneId] = { guildAuthor = true, credited = remote.credited, originName = remote.originName,
        owner = remote.owner, openedAt = remote.openedAt, openedHold = remote.openedHold,
        tickAt = remote.tickAt, tickHold = remote.tickHold, closedAt = now() }
end

-- What the timer of a wave told in the guild shows: how far it should be by now. Nil while ticks
-- come some other way (a group, a friend), which say more. Asking changes nothing.
-- 2.5.0: while the channel does not carry, any wave we follow, however its start reached us (a
-- Battle.net friend, a player out of the member list, a contact gone quiet for five minutes): no
-- tick of it will come either, and its timer stood still at the hold its start told (measured on
-- 36 whole clients: 9 showed about 8 s at the 53rd second of a siege). The timer only: how long
-- such a wave is believed is decided as before (KeepFollowing, CaptureLease:MaybeExpire). Not a
-- wave on hold or released, whose capturer has left the point.
function lane:WaveClock(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or not remote.tickAt then return nil end
    -- (Ticks that do come first: asked by every timer on screen, it costs nothing then.)
    local serverNow = addon.ServerNow and addon.ServerNow() or time()
    if serverNow - (tonumber(remote.lastRemoteTs) or 0) < self.TICK_SEC then return nil end
    if not remote.viaGuild and (remote.away or remote.releasedAt or not self:ChannelDown()) then return nil end
    return (tonumber(remote.tickHold) or 0) + now() - remote.tickAt
end

-- A wave told in the guild that outlives its clock: everybody following it would ask at once,
-- having heard its start in the same second. A few of them do (RELAY_SPEAKERS), the same ones
-- every time; its end reaches the others anyway.
function lane:AsksAboutWave(zone)
    local remote = zone and zone._remoteCaptureLease
    if not remote or not remote.viaGuild then return true end
    local peers = self:PeerCount()
    -- 2.2.0: told along the channel's member list, the whole list may follow it.
    local directory = addon.ChannelDirectory
    if directory and directory.ChainFollowers then peers = math.max(peers, directory:ChainFollowers()) end
    if peers <= self.RELAY_SPEAKERS then return true end
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    return addon.Relay.HashFrac(tostring(me):lower() .. "|" .. tostring(remote.waveId)) < self.RELAY_SPEAKERS / peers
end

-- Is what is being delivered right now a copy heard in the guild? 2.2.0: or a broadcast whispered
-- along the channel's member list (SyncDirectory.lua, the only sender of one): no ticks follow it
-- either. (Not its author's word for HeardFromAuthor: that stays the guild's.)
function lane:HeardHere()
    local context = addon.Relay and addon.Relay.context
    if context == nil then return false end
    if context.transport == "GUILD" then return true end
    -- Whispered: from a contact of the chain only (a stranger's word keeps its ticks).
    local directory = addon.ChannelDirectory
    -- (2.3.0: or a leaf's own fact, hops 0: SyncDirectory IsLeafOrigin.)
    return context.transport == "WHISPER" and context.targeted == false and directory ~= nil
        and ((directory.IsContact ~= nil and directory:IsContact(context.gateway) == true)
            or (directory.IsLeaf ~= nil and (tonumber(context.hops) or 1) == 0
                and directory:IsLeaf(context.gateway) == true))
end

-- The same, from its author: the game gives that name, and it is one of ours. (A relayed copy
-- carries a name anybody wrote.)
function lane:HeardFromAuthor()
    local context = addon.Relay and addon.Relay.context
    return context ~= nil and context.transport == "GUILD" and (tonumber(context.hops) or 0) == 0
end

-- ---------------------------------------------------------------------------
-- What the guild says
-- ---------------------------------------------------------------------------

-- Everything said in the guild during the last minute, ours included. One sender counts
-- for PER_SENDER_PER_MIN at most, so that a single client cannot silence the others.
function lane:HeardLastMinute(at)
    local log, first = self.log, 1
    while log[first] and at - log[first].at >= 60 do first = first + 1 end
    if first > 1 then
        local kept = {}
        for i = first, #log do kept[#kept + 1] = log[i] end
        self.log, log = kept, kept
    end
    local bySender, total = {}, 0
    for i = 1, #log do
        local who = log[i].who
        local count = (bySender[who] or 0) + 1
        bySender[who] = count
        if count <= self.PER_SENDER_PER_MIN then total = total + 1 end
    end
    return total
end

local function logMessage(self, who, at)
    local log = self.log
    -- A flood is bounded by the server's own rate; the list by a minute of it anyway.
    if #log >= 256 then table.remove(log, 1) end
    log[#log + 1] = { at = at, who = who }
end

-- Guild mates heard under Overlord in the last hour (a whole presence round in any guild).
function lane:PeerCount()
    local at = now()
    if self.peerCountAt and at - self.peerCountAt < 30 then return self.peerCountValue end
    -- Those heard in a guild we have since left are nobody's guild mates any more.
    local guild = GetGuildInfo and GetGuildInfo("player")
    if readable(guild) and guild ~= self.peersGuild then
        if self.peersGuild then self.peers, self.intake = {}, {} end
        self.peersGuild = guild
    end
    local count = 0
    for key, heardAt in pairs(self.peers) do
        if at - heardAt >= self.PEER_MEMORY then self.peers[key] = nil else count = count + 1 end
    end
    self.peerCountAt, self.peerCountValue = at, count
    return count
end

-- 2.2.2: a guild mate heard here within PEER_MEMORY (Sync:NoteFullMapReceived).
function lane:IsGuildMate(name)
    -- (Peers are kept by canonical name: a sender may come with its realm suffix.)
    local canon = type(name) == "string" and sync.CanonicalForeverName and sync:CanonicalForeverName(name) or name
    local key = type(canon) == "string" and canon:lower() or nil
    local heardAt = key and self.peers[key]
    return heardAt ~= nil and now() - heardAt < self.PEER_MEMORY
end

-- When this guild mate was last heard here, nil beyond HEARD_FRESH (see tasksFor).
function lane:HeardAt(name)
    local key = type(name) == "string" and name:lower() or nil
    local heardAt = key and self.peers[key]
    if heardAt and now() - heardAt <= self.HEARD_FRESH then return heardAt end
    return nil
end

function lane:PresenceGap()
    local peers = self:PeerCount()
    if peers == 0 then return self.PRESENCE_ALONE end
    return math.max(self.PRESENCE_MIN, self.PRESENCE_PER_PEER * peers)
end

-- True while our last messages stay unanswered by the server: at least three sent, the
-- oldest for five minutes, and no copy of any of them back in that time.
function lane:IsUnheard()
    local at, pending, oldest = now(), 0, nil
    for _, sentAt in pairs(self.awaiting) do
        pending = pending + 1
        if not oldest or sentAt < oldest then oldest = sentAt end
    end
    if pending < self.ECHO_SENDS or at - oldest < self.ECHO_PATIENCE then return false end
    return not self.lastEchoAt or at - self.lastEchoAt >= self.ECHO_PATIENCE
end

local function takeTokens(self, count, at)
    local tokens = math.min(self.TOKEN_BURST,
        (self.tokens or self.TOKEN_BURST) + math.max(0, at - (self.tokensAt or at)) / self.TOKEN_SEC)
    self.tokensAt = at
    if tokens < count then
        self.tokens = tokens
        return false
    end
    self.tokens = tokens - count
    return true
end

local function relayedShare(self, at)
    local tokens = math.min(self.RELAYED_BURST, (self.relayedTokens or self.RELAYED_BURST)
        + math.max(0, at - (self.relayedTokensAt or at)) / self.RELAYED_SEC)
    self.relayedTokens, self.relayedTokensAt = tokens, at
    return tokens
end

-- Said or heard, one less for everybody. Each client draws how much more it wants before
-- speaking again, or all those holding a packet would speak when the share comes back.
local function spendRelayedShare(self, at)
    self.relayedTokens, self.relayedJitter = math.max(0, relayedShare(self, at) - 1), math.random()
end

-- A capture our own map has just taken: nobody made that up, whatever else is pushed at us.
-- It goes without the share and before the rest, or a flood would keep it out of the guild.
local function mapShowsCapture(key)
    if not key then return false end
    local zoneId, code = key:match("^CAP|([^|]*)|([AH])$")
    local zone = zoneId and sync:MapNewsZone(zoneId)
    if not zone or zone.status == "in_progress" or type(zone.owner) ~= "string"
        or zone.owner:sub(1, 1) ~= code then return false end
    local serverNow = addon.ServerNow and addon.ServerNow() or time()
    return serverNow - (tonumber(zone.capturedTime) or 0) <= lane.PROVEN_SEC
end

-- May this waiting message leave now? Spends the client's tokens when it may. Second return:
-- give it up. A relayed packet does not wait for its share (the next map pull brings what it
-- says), and anything but a capture leaves the last of the share to one.
local function mayPost(self, entry, at)
    if entry.kind ~= "NH" and self:PeerCount() == 0 then
        self.stats.noListener = self.stats.noListener + 1
        return false, true
    end
    if self:IsUnheard() and self.lastSendAt and at - self.lastSendAt < self.UNHEARD_GAP then return false end
    local said = self:HeardLastMinute(at)
    if said >= self.HARD_PER_MIN or (entry.level == ROUTINE and said >= self.SOFT_PER_MIN) then
        self.stats.capped = self.stats.capped + 1
        return false
    end
    -- (2.3.0: a copy of the whisper chain pays the share even for a capture our map shows: many
    -- holders get chain copies, and they would fill the guild's minute for its routine words.)
    local shared = entry.relayed and (entry.chained or not mapShowsCapture(entry.cover))
    if shared and relayedShare(self, at) < (entry.level == TERMINAL and 1 or 2) + (self.relayedJitter or 0) then
        -- 2.4.0: the start of a capture waits for the share instead of being given up (its
        -- time in the box bounds the wait): it is the defenders' warning, and a capture begun
        -- again right after its release was the third relayed word of the minute; given up
        -- here, the point fell without a sign for the whole guild. The last of the share is
        -- still left to a capture.
        local waits = entry.kind == "ZS" and entry.level == ALERT
        if not (waits and entry.capped) then self.stats.capped = self.stats.capped + 1 end
        entry.capped = true
        return false, not waits
    end
    if not takeTokens(self, #entry.fragments, at) then return false end
    if shared then spendRelayedShare(self, at) end
    return true
end

local function remember(self, id, at)
    local count, oldestId, oldest = 0, nil, nil
    for other, sentAt in pairs(self.awaiting) do
        if at - sentAt >= self.ECHO_MEMORY then
            self.awaiting[other] = nil
        else
            count = count + 1
            if not oldest or sentAt < oldest then oldestId, oldest = other, sentAt end
        end
    end
    if count >= self.ECHO_ROWS and oldestId then self.awaiting[oldestId] = nil end
    self.awaiting[id] = at
end

-- True when the whole message left.
local function post(self, entry, at)
    local stats, sent, whole = self.stats, false, true
    for _, fragment in ipairs(entry.fragments) do
        if sync:SendAddonChecked("BF:" .. fragment, "GUILD") == true then
            stats.sent = stats.sent + 1
            logMessage(self, "", at)
            sent = true
        else
            stats.failed = stats.failed + 1
            local row = sync._addonSendStats and sync._addonSendStats.GUILD
            if row and row.lastCode == CODE_NOT_IN_GUILD then
                self.noGuildUntil = at + self.NO_GUILD_BACKOFF
            end
            whole = false
            break
        end
    end
    if sent then
        self.lastSendAt = at
        remember(self, entry.id, at)
    end
    if not whole then return false end
    if entry.kind == "NH" then
        self.lastPresenceAt, self.presenceFactor = at, 0.85 + 0.3 * math.random()
    end
    -- (Saying somebody else's word leaves our own report of the same thing still to say.)
    if entry.cover then self:RememberCover(entry.cover, at, not entry.relayed) end
    if entry.startedWave then self.spoken[entry.startedZone] = entry.startedWave end
    return true
end

function lane:Arm(delay)
    local at = now()
    if self.armedAt and self.armedAt <= at + delay then return end
    self.armedAt = at + delay
    self.generation = (self.generation or 0) + 1
    local generation = self.generation
    C_Timer.After(delay, function()
        if lane.generation ~= generation then return end
        lane.armedAt = nil
        lane:Flush()
    end)
end

function lane:Flush()
    local at, outbox = now(), self.outbox
    if #outbox == 0 then return end
    if not self:IsActive() then
        -- The channel is back while our own last words wait here (a capture, how a siege ended):
        -- they went out while it was down, so not on it, and guild mates follow that wave.
        -- Anything else comes again by itself.
        if self:CanSpeak() then
            for _, entry in ipairs(outbox) do
                if entry.firm and not isCovered(self, entry.cover, entry.coverSec, at, true, entry.date)
                    and mayPost(self, entry, at) then post(self, entry, at) end
            end
        end
        self.outbox = {}
        return
    end
    local best
    for i = #outbox, 1, -1 do
        local entry = outbox[i]
        if at > entry.due + self.OUTBOX_TTL then
            table.remove(outbox, i)
            self.stats.expired = self.stats.expired + 1
        elseif isCovered(self, entry.cover, entry.coverSec, at, entry.firm, entry.date) then
            table.remove(outbox, i)
            self.stats.covered = self.stats.covered + 1
        elseif entry.due <= at then
            if not best or entry.rank > best.rank
                or (entry.rank == best.rank and entry.due < best.due) then best = entry end
        end
    end
    local pause = 0.5
    if best then
        local allowed, drop = mayPost(self, best, at)
        if allowed then drop = post(self, best, at) end
        -- A presence or a site's progress comes again by itself.
        if not drop and best.level == ROUTINE then drop = true end
        if drop then
            for i = #outbox, 1, -1 do
                if outbox[i] == best then table.remove(outbox, i) break end
            end
        else
            -- Waits for tokens, for the guild to calm down or for the game to take it
            -- (a refused send spent its tokens: one try per TOKEN_SEC), until its time is up.
            pause = 2
        end
    end
    local wake
    for _, entry in ipairs(outbox) do
        local when = math.max(entry.due, at + pause)
        if not wake or when < wake then wake = when end
    end
    if wake then self:Arm(wake - at) end
end

-- A relayed packet is held by several guild mates at once. A few of them say it, on a draw
-- each makes alone: with a slow echo nobody would hear the first copy in time to keep quiet.
-- Not what comes from outside the guild (a friend in another guild or the other faction, over
-- Battle.net, or a group mate): the guild has no other way to hear that.
local function isSpeaker(self, p)
    local from = p.path[#p.path - 1]
    if not from or not isGuildMate(self, from) then return true end
    local peers = self:PeerCount()
    if peers <= self.RELAY_SPEAKERS then return true end
    local draw = addon.Relay.HashFrac(p.path[#p.path]:lower() .. "|" .. p.path[1]:lower() .. "|" .. tostring(p.id))
    return draw < self.RELAY_SPEAKERS / peers
end

-- How long a message waits for somebody else to say it. Most wait long and a few little, the
-- more so as more guild mates may hold it (exponential suppression timers): for 3 holders or
-- 40, the first speaks early and about the same few speak before its copy comes back, even when
-- that takes half a minute in this guild; past that a message has to arrive before it expires,
-- and a raid on one point says it once per player. A presence is nobody else's to say: any
-- moment of its range will do.
function lane:DrawWait(wait, shared)
    local first, last = wait[1], wait[2]
    if not shared then return first + math.random() * (last - first) end
    local echo = self.lastEchoDelay or 0
    local span = math.max(last - first, math.min(self.ECHO_SPANS * echo, self.PACKET_LIFE - echo))
    local holders = math.max(2, self:PeerCount() + 1)
    return first + math.max(0, 1 + math.log(math.random()) / math.log(holders)) * span
end

-- Is this our own capture of a wave whose start we said here?
local function endsSpokenWave(self, p)
    local zone, wave
    if p.kind == "C" then
        zone, wave = p.payload:match("^([^:]*):[^:]*:[^:]*:[^:]*:([^:]*)")
    elseif p.kind == "ZS" then
        zone, wave = p.payload:match("^[^:]*"), stateWave(p.payload)
    end
    return zone ~= nil and wave ~= nil and wave ~= "" and self.spoken[zone] == wave
end

-- From the relay's pump: nothing waits there, and nothing is refused to it.
function lane:Offer(p, fragments)
    if not p or not fragments or not self:IsActive() then return false end
    local level = self:Level(p)
    if not level then return false end
    local at, own = now(), #p.path == 1
    -- A wave of ours given up before its start was said: the guild never hears of it. (Said after
    -- its end, that start would have the whole guild follow a wave nobody holds.)
    if own and p.kind == "ZR" then
        local zone, wave = p.payload:match("^([^:]*):([^:]*)")
        local waiting = self.spoken[zone] ~= wave and waitingStart(self, zone, wave)
        if waiting then
            table.remove(self.outbox, waiting)
            self.stats.cancelled = self.stats.cancelled + 1
            return false
        end
        -- (2.4.0: a word of that wave still waiting, a siege told again: not said after its end.)
        local late = waitingStart(self, zone, wave)
        while late do
            table.remove(self.outbox, late)
            late = waitingStart(self, zone, wave)
        end
    end
    -- Or given up while its start still waited in the relay's queue: the release went first.
    -- (2.4.0: likewise a siege told again, ROUTINE.)
    if own and p.kind == "ZS" and (level == ALERT or level == ROUTINE) then
        local wave, waves = stateWave(p.payload), self.released[p.payload:match("^[^:]*")]
        if wave and waves and waves[wave] then
            self.stats.cancelled = self.stats.cancelled + 1
            return false
        end
    end
    if not own and not isSpeaker(self, p) then
        self.stats.notSpeaker = self.stats.notSpeaker + 1
        return false
    end
    if p.kind == "NH" then
        if self.lastPresenceAt
            and at - self.lastPresenceAt < self:PresenceGap() * (self.presenceFactor or 1) then return false end
    end
    local key, seconds = self:CoverKey(p)
    local firm = own and level == TERMINAL
    local date = firm and captureDate(p) or nil
    if isCovered(self, key, seconds, at, firm, date) then
        self.stats.covered = self.stats.covered + 1
        return false
    end
    local outbox = self.outbox
    for i = #outbox, 1, -1 do
        local entry = outbox[i]
        -- Already waiting: the same fact, or our own presence (the newest one says more). A copy
        -- relayed to us is somebody's word, with their date: our own report takes its place.
        if (key and entry.cover == key) or (p.kind == "NH" and entry.kind == "NH") then
            if not (own and entry.relayed) then
                if p.kind == "NH" then entry.fragments, entry.id = fragments, p.id end
                return true
            end
            table.remove(outbox, i)
        end
    end
    -- Our own release (Level: of a wave we announced) is nobody else's to say, and a loading
    -- screen may close the box in this very frame: it leaves now, ahead of the rest.
    local release = own and p.kind == "ZR"
    -- Ours first, then a capture our map shows, then anything else relayed to us: a flood of
    -- whispers takes the place of none of them.
    local rank = release and TERMINAL + TERMINAL + 1 or own and level + TERMINAL
        or (mapShowsCapture(key) and TERMINAL + 0.5) or level
    if #outbox >= self.OUTBOX_MAX then
        -- A full box gives up what matters least, the oldest first.
        local worst
        for i, entry in ipairs(outbox) do
            if not worst or entry.rank < outbox[worst].rank then worst = i end
        end
        if outbox[worst].rank > rank then
            self.stats.expired = self.stats.expired + 1
            return false
        end
        table.remove(outbox, worst)
        self.stats.expired = self.stats.expired + 1
    end
    local delay
    if release then
        delay = 0
    elseif firm and date and endsSpokenWave(self, p) then
        delay = self:DrawWait(ANNOUNCED_WAIT)
    else
        -- (A friend or a group mate can put one packet in the hands of many: relayed ones draw too.)
        delay = self:DrawWait(own and WAIT[level] or RELAYED_WAIT, key ~= nil)
    end
    -- (2.4.0: or a siege told again, ROUTINE: when its start gave way to a raid mate's, this is
    -- what the guild has from us, and its release must follow.)
    local started = own and p.kind == "ZS" and (level == ALERT or level == ROUTINE)
    outbox[#outbox + 1] = { kind = p.kind, level = level, rank = rank, relayed = not own, cover = key,
        chained = p.heardOn == "WHISPER" or nil,
        coverSec = seconds, firm = firm, date = date,
        startedZone = started and p.payload:match("^[^:]*") or nil,
        startedWave = started and stateWave(p.payload) or nil,
        wave = p.kind == "ZS" and stateWave(p.payload) or nil,
        id = p.id, origin = p.path[1]:lower(), fragments = fragments, due = at + delay }
    if release then self:Flush() else self:Arm(delay) end
    return true
end

-- ---------------------------------------------------------------------------
-- What the guild hears
-- ---------------------------------------------------------------------------

-- Every message of ours on GUILD, before anything is done with it. True when the relay
-- should read it. Only relay fragments are read, and our own copy stops here (by its sender:
-- anybody can copy an id, to hide that the server drops our messages).
function lane:OnHeard(message, sender)
    if type(message) ~= "string" or message:sub(1, 3) ~= "BF:" then return false end
    local at = now()
    if sync:IsSenderLocalPlayer(sender) then
        local id = message:match("^BF:([%w%-]+):")
        local sentAt = id and self.awaiting[id]
        if sentAt then
            self.awaiting[id] = nil
            self.lastEchoDelay = at - sentAt
        end
        self.lastEchoAt = at
        self.stats.echoes = self.stats.echoes + 1
        return false
    end
    local name = sync:CanonicalForeverName(sender)
    local key = name and name:lower() or tostring(sender):lower()
    -- Nobody gets the guild to forward, remember or count more than this code can say.
    local intake = self.intake[key]
    if not intake or at - intake.since >= 60 then
        intake = { since = at, count = 0 }
        self.intake[key] = intake
    end
    intake.count = intake.count + 1
    if intake.count > self.INTAKE_PER_MIN then
        self.stats.tooFast = self.stats.tooFast + 1
        return false
    end
    if not self.peers[key] then self.peerCountAt = nil end
    self.peers[key] = at
    logMessage(self, key, at)
    self.stats.heard = self.stats.heard + 1
    return true
end

-- A whole packet heard in the guild, once the relay has taken it: said, nothing left for us
-- to say about it. relayed: its sender is not its author.
function lane:NoteHeardPacket(p, relayed)
    local at, key, seconds = now(), self:CoverKey(p)
    -- One fact takes one from the share, however many holders say it, and only what the guild
    -- carries: anything else a guild mate pushes through it says nothing about its share.
    local heard = key and self.cover[key]
    local news = not heard or at - heard >= (seconds or self.COVER_SEC)
    if key then self:RememberCover(key, at) end
    -- 2.4.0: a release heard here: that point's next wave is a new start (ForgetSiege).
    if p.kind == "ZR" and type(p.payload) == "string" then self:ForgetSiege(p.payload:match("^([^:]*):([^:]*)")) end
    if relayed and news and self:Level(p) then spendRelayedShare(self, at) end
    local date = captureDate(p)
    if key and date then
        -- (A date to come stays here for good otherwise; receivers take it for the present.)
        local latest = (addon.ServerNow and addon.ServerNow() or time()) + self.DATE_SKEW
        self.coverDate[key] = math.max(self.coverDate[key] or 0, math.min(date, latest))
    end
    -- Our own siege start, said for us by whoever holds it: the guild has it from us (see Level).
    if p.kind == "ZS" and key and key:sub(1, 6) == "SIEGE|" and sync:IsSenderLocalPlayer(p.path[1]) then
        self.spoken[p.payload:match("^[^:]*")] = stateWave(p.payload)
    end
    local origin = p.path[1]:lower()
    local outbox = self.outbox
    for i = #outbox, 1, -1 do
        local entry = outbox[i]
        -- (A later date of ours still has something to say.)
        if ((key and entry.cover == key) and not (entry.date and entry.date > (self.coverDate[key] or 0)))
            or (entry.id == p.id and entry.origin == origin) then
            -- Ours was waiting: its next copies count as said too.
            if entry.firm and entry.cover then self:RememberCover(entry.cover, at, true) end
            table.remove(outbox, i)
            self.stats.cancelled = self.stats.cancelled + 1
        end
    end
end

-- ---------------------------------------------------------------------------
-- Reports (/ov network, panel)
-- ---------------------------------------------------------------------------

-- Level, the full text (/ov network) and a short one (the panel dot's tooltip).
function lane:Describe()
    local at, stats = now(), self.stats
    local channel, short
    if sync._channelRefusedAt then
        channel, short = "channel refused by the server", "channel refused"
    elseif not sync:GetJoinedChannelId() then
        channel = sync._joinChannelAttemptPending and "joining the channel" or "channel not joined"
    elseif sync:IsChannelSilent() then
        channel = "nobody heard on the channel for 5 min"
    else
        return "ok", "channel open", "channel open"
    end
    short = short or channel
    if not self:ChannelDown() then return "ok", channel, short end
    -- 2.2.0: a refused channel is the server's choice, not a fault: the dot stays green while
    -- something carries our data instead (players of the channel's member list exchanging with us,
    -- SyncDirectory.lua; guild mates heard under Overlord), and says what.
    local listed, exchanging, listLess = nil, 0, false
    if addon.ChannelDirectory then listed, exchanging, listLess = addon.ChannelDirectory:Describe() end
    exchanging = tonumber(exchanging) or 0
    if listed then channel = channel .. "; " .. listed end
    local suspended = addon.ChannelDirectory and addon.ChannelDirectory.suspended
    if suspended then short = "channel suspended by the game" end
    local carriers = {}
    -- (2.2.2: without the list, players found otherwise: address book, ranking, met in the world.)
    if exchanging > 0 then
        carriers[#carriers + 1] = listLess and "players found without the list" or "the channel member list"
    end
    local guildText, unheard
    if self:IsSwitchedOff() then
        guildText = "guild fallback off (/ov guild on)"
    elseif not (IsInGuild and IsInGuild()) or (self.noGuildUntil and at < self.noGuildUntil) then
        guildText = "no guild"
    else
        local echo = self.lastEchoDelay and string.format(", last in %.1f s", self.lastEchoDelay) or ""
        guildText = string.format("guild fallback on: %d sent, %d back%s, %d heard from %d players",
            stats.sent, stats.echoes, echo, stats.heard, self:PeerCount())
        unheard = self:IsUnheard()
        if self:PeerCount() > 0 and not unheard then carriers[#carriers + 1] = "the guild" end
    end
    -- (The guild is a carrier only while heard: a silent guild does not turn a working list yellow.)
    -- Nor while the member list is still being read and greeted (the first SETTLE_SEC).
    local settling = at - (self.downSince or at) < self.SETTLE_SEC
    local level = (#carriers > 0 or settling) and "ok" or "warn"
    if #carriers == 0 and settling then
        carriers[#carriers + 1] = listLess and "players found without the list (looking for some)"
            or "the channel member list (looking for players)"
    end
    carriers[#carriers + 1] = "your group and Battle.net friends"
    local text = string.format("%s; %s; data goes through %s", channel, guildText, table.concat(carriers, ", "))
    short = string.format("%s; data goes through %s", short, table.concat(carriers, ", "))
    -- (Yellow: why, in the tooltip too.)
    -- (Not the list's state when the game suspended the channel: the short text says it already.)
    if level == "warn" and listed and not suspended then short = short .. "; " .. listed end
    if unheard and exchanging == 0 then
        local warning = "; nothing came back for 5 min: the server may be dropping this account's addon messages"
        text, short = text .. warning, short .. warning
    end
    return level, text, short
end

function lane:GetDiagnostics()
    local s = self.stats
    return string.format("Guild fallback: %d covered by someone else, %d cancelled (heard or given up), %d left to "
        .. "other holders, %d capped, %d expired, %d alone in the guild, %d failed, %d unread; channel: "
        .. "%d refusals, %d probes, %d reopened",
        s.covered, s.cancelled, s.notSpeaker, s.capped, s.expired, s.noListener, s.failed, s.tooFast,
        s.refusals, s.probes, s.reopened)
end
