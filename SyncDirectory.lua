-- The channel's member list as a directory of catch-up partners (2.2.0).
--
-- While the server refuses addon messages on our channel (SyncGuild.lua), a client only
-- exchanges with its guild, its group and its Battle.net friends: every guild is an island,
-- and a ranking row or a capture made in another guild arrives late or never. The channel
-- still has its member list, which the game gives to any member: every Overlord user of our
-- faction and ruleset, whatever their guild or realm, as "First Last" without a realm. A
-- whisper to such a name crosses realms (tested in game, 2026-11-05).
--
-- So, while the channel does not carry (GuildLane:ChannelDown):
--  * The list is read every REFRESH_SEC. After a login the game holds no list until it
--    fetches one, and it fetches one when our channel becomes the one selected for display:
--    selecting another channel first, then ours, makes it fetch (FETCH_METHODS: the group's
--    channel while in a group, another channel otherwise, a custom one before a world one, each
--    set aside apart when it brings nothing; a header does nothing, measured in game 2026-11-06). Never while the game's channel window is
--    open (it shows the selected channel's members) nor in combat. That window selects its own
--    entry again every time it opens (ChannelListMixin:Update): it is not disturbed.
--  * About once a minute, while fewer than MAX_PARTNERS answer us, one listed player we do not
--    hear yet gets our presence by whisper (Greet). A client from 2.2.0 on answers with its own
--    (OnGreeting), once per PRESENCE_SEC per player and REPLIES_PER_MIN at most: each side then
--    holds the other as a direct neighbour, with its capability and its map stamps. A map that
--    differs is pulled as from any neighbour (the relay's presence branch). No map is taken
--    from a player whose presence was never heard (Relay:IsOutdatedMapPeer): a client before
--    2.2.0 does not answer, and only serves the ranking if it ever speaks to us.
--  * Every other ranking round and map round of our own side goes to such a partner, one
--    partner per round as with any neighbour. The ranking rounds come closer (FastRounds,
--    SyncHistoryCatchup); the map rounds keep their pace (closer ones were measured: twice the
--    map answers, for a minute or two less on the slowest capture).
--  * Live news (captures, sieges, outposts, map news, victories...) are whispered from hand to
--    hand among the players who greeted us under 2.2.0 (the chain, ChainTargets below): a few
--    contacts at each hand, each fact once, within a whisper budget.
-- A presence is answered once, a player who stays silent is left alone for SILENT_SEC, nothing
-- is kept in the saved variables, and inside an instance nothing runs (Suspend).
local addon = Overlord
local sync = addon.Sync
local dir = {
    TICK_SEC = 20,
    -- The list: read again after REFRESH_SEC, fetched again (selection) after STALE_SEC, a
    -- failed read tried again after RETRY_SEC; the count is looked at READ_POLLS seconds after
    -- a fetch. A fetch method that brought nothing waits STALE_SEC.
    REFRESH_SEC = 600, STALE_SEC = 1800, RETRY_SEC = 60, READ_POLLS = { 3, 8 },
    FETCH_METHODS = { "group", "custom", "world" },
    MAX_NAMES = 1500, MAX_DISPLAY = 60,
    -- Greetings: one every GREET_SEC + 0..GREET_JITTER while fewer than MAX_PARTNERS partners
    -- answer us; our presence to one same player at most every PRESENCE_SEC (greeting, answer
    -- or before a map round); a greeted player that says nothing within ANSWER_WAIT is left
    -- alone for SILENT_SEC; answers to greetings, REPLIES_PER_MIN for the whole client.
    GREET_SEC = 60, GREET_JITTER = 30, MAX_PARTNERS = 6,
    PRESENCE_SEC = 150, ANSWER_WAIT = 30, SILENT_SEC = 1800, REPLIES_PER_MIN = 6,
    PARTNER_ROWS = 400,
    -- Ranking rounds while a partner can take a turn (FastRounds): 20-40 s after a v8 sweep
    -- (45-105 s otherwise). A map round (at its usual pace) with a player of the list we hear
    -- from sends our presence first when it is older than MAP_PRESENCE_SEC, MAP_PULL_DELAY
    -- before the request, so that an identical map is answered without its pages
    -- (Relay:PeerHoldsOurMap, BeforeMapPull).
    LADDER_ACK_SEC = 20, LADDER_JITTER_SEC = 20, LADDER_FLOOR_SEC = 20,
    MAP_PRESENCE_SEC = 100, MAP_PULL_DELAY = 2,
}
addon.ChannelDirectory = dir
dir.names, dir.partners, dir.partnerCount, dir.failedMethods, dir.provenMethods = {}, {}, 0, {}, {}
dir.replies = { at = -1000, count = 0 }
dir.generation = 0
dir.stats = { reads = 0, fetches = 0, fetchFailed = 0, greeted = 0, answered = 0, silent = 0,
    greetedUs = 0, replies = 0, repliesCapped = 0, ladderTurns = 0, mapTurns = 0, full = 0, gapPulls = 0 }

local function now() return GetTime() end
local function outside() return not addon.InstanceSuspended and not IsInInstance() end
local function readable(value)
    return value ~= nil and (not canaccessvalue or canaccessvalue(value))
        and not (issecretvalue and issecretvalue(value))
end
-- nil, or a value addon code may look at.
local function plain(value) return value == nil or readable(value) end
local function inCombat() return InCombatLockdown ~= nil and InCombatLockdown() == true end
-- The game's channel window shows the selected channel's members: never select while it is open.
local function windowOpen()
    local frame = _G.ChannelFrame
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return not ok or shown == true
end

-- ---------------------------------------------------------------------------
-- The member list
-- ---------------------------------------------------------------------------

local function displaySize()
    if type(GetNumDisplayChannels) == "function" then
        local ok, size = pcall(GetNumDisplayChannels)
        if ok and tonumber(size) then return math.min(math.floor(tonumber(size)), dir.MAX_DISPLAY) end
    end
    return dir.MAX_DISPLAY
end

-- Our channel's place in the display list, its member count (nil until the game fetched the
-- list), and the entries that can be selected before it: the group's channel, another channel
-- (a custom one before a world one).
local function scanDisplay()
    if type(GetChannelDisplayInfo) ~= "function" then return nil end
    local mine = sync:GetChannelBaseName():lower()
    local ours, members, group, custom, world
    for i = 1, displaySize() do
        local ok, name, isHeader, _, _, count, _, category = pcall(GetChannelDisplayInfo, i)
        if ok and readable(name) and type(name) == "string" and plain(isHeader) and plain(count)
            and plain(category) and not isHeader and name ~= "" then
            if name:lower() == mine then
                ours, members = i, tonumber(count)
            elseif category == "CHANNEL_CATEGORY_GROUP" then
                if (tonumber(count) or 0) > 0 then group = group or i end
            elseif category == "CHANNEL_CATEGORY_CUSTOM" then
                custom = custom or i
            elseif category == "CHANNEL_CATEGORY_WORLD" then
                world = world or i
            end
        end
    end
    return ours, members, group, custom, world
end

-- The names of the list, canonical, without ours.
local function readList(index, members)
    if type(C_ChatInfo) ~= "table" or type(C_ChatInfo.GetChannelRosterInfo) ~= "function" then return nil end
    local me = sync:GetPlayerFullName()
    -- (Our own name, by its first part: the full identity test only for the names that share it.)
    local mine = tostring(me or ""):match("^[^%-]*"):lower()
    local names, seen = {}, {}
    for k = 1, math.min(members, dir.MAX_NAMES) do
        local ok, name = pcall(C_ChatInfo.GetChannelRosterInfo, index, k)
        local canon = ok and readable(name) and type(name) == "string" and sync:CanonicalForeverName(name) or nil
        local lower = canon and canon:lower()
        if lower and not seen[lower] and not (lower:match("^[^%-]*") == mine
            and sync:ForeverIdentitiesMatch(canon, me)) then
            seen[lower] = true
            names[#names + 1] = canon
        end
    end
    return names, seen
end

-- Our channel kept by the game but put aside by the server (GetChannelList's third value):
-- out of the display list, no member list; leaving it is "wrong channel name", joining it
-- "not allowed" (measured in game 2026-11-06). Nothing to do but read again later.
local function suspended()
    if type(GetChannelList) ~= "function" then return false end
    local mine = sync:GetChannelBaseName():lower()
    local list = { pcall(GetChannelList) }
    if not list[1] then return false end
    for i = 2, #list, 3 do
        local name, disabled = list[i + 1], list[i + 2]
        if readable(name) and type(name) == "string" and name:lower() == mine then
            return plain(disabled) and disabled == true
        end
    end
    return false
end

local function selectEntry(index)
    if type(SetSelectedDisplayChannel) ~= "function" or not index then return false end
    return (pcall(SetSelectedDisplayChannel, index))
end

function dir:CanFetch()
    return outside() and not inCombat() and not windowOpen()
end

function dir:Take(index, members)
    local names, listed = readList(index, members)
    if not names then
        self.state = "member list unreadable"
        return false
    end
    self.names, self.readAt, self.state = names, now(), nil
    -- (The lookup of dir:Lists, built here out of combat rather than at its first use.)
    self.listed, self.listedFor, self.listedCount = listed, names, #names
    self.nextReadAt = now() + self.REFRESH_SEC
    self.stats.reads = self.stats.reads + 1
    return true
end

-- Read the list, after asking the game for it when it holds none or an old one.
function dir:Refresh()
    local at = now()
    self.nextReadAt = at + self.RETRY_SEC
    if not self:CanFetch() then return false end
    local index, members, group, custom, world = scanDisplay()
    self.suspended = nil
    if not index then
        self.suspended = suspended() or nil
        self.state = self.suspended and "channel suspended by the game for this session" or "not in the channel"
        return false
    end
    local fresh = self.fetchAt and at - self.fetchAt < self.STALE_SEC
    if members and members > 0 and fresh then return self:Take(index, members) end
    local method, other
    for _, candidate in ipairs(self.FETCH_METHODS) do
        local entry = candidate == "group" and group or candidate == "custom" and custom
            or candidate == "world" and world or nil
        local failed = self.failedMethods[candidate]
        if entry and entry ~= index and not (failed and at - failed < self.STALE_SEC) then
            method, other = candidate, entry
            break
        end
    end
    if not method then
        if members and members > 0 then return self:Take(index, members) end
        self.state = "member list not loaded"
        return false
    end
    if not (selectEntry(other) and selectEntry(index)) then
        self.failedMethods[method] = at
        self.state = "member list not loaded"
        return false
    end
    self.stats.fetches = self.stats.fetches + 1
    -- (A list "not there" may come as nil or as 0.)
    local fetch = { method = method, at = at, fromNothing = not (members and members > 0) }
    self.fetching = fetch
    for i, delay in ipairs(self.READ_POLLS) do
        local last = i == #self.READ_POLLS
        C_Timer.After(delay, function()
            if dir.fetching == fetch then dir:Poll(fetch, last) end
        end)
    end
    return true
end

function dir:Poll(fetch, last)
    if not outside() then
        self.fetching = nil
        return false
    end
    -- A fight or the channel window since the fetch began: the list is read later (Refresh).
    if inCombat() or windowOpen() then
        self.fetching, self.nextReadAt = nil, now() + self.RETRY_SEC
        -- (A list that came meanwhile is read then, not fetched again a minute later.)
        local _, members = scanDisplay()
        if members and members > 0 then self.fetchAt = now() end
        return false
    end
    local index, members = scanDisplay()
    if index and members and members > 0 then
        self.fetching, self.fetchAt = nil, now()
        self.failedMethods[fetch.method] = nil
        -- Only a list that was not there before proves the method.
        if fetch.fromNothing then self.provenMethods[fetch.method] = true end
        return self:Take(index, members)
    end
    if not last then return false end
    self.fetching = nil
    self.failedMethods[fetch.method] = now()
    self.stats.fetchFailed = self.stats.fetchFailed + 1
    self.state = "member list not loaded"
    return false
end

-- ---------------------------------------------------------------------------
-- Partners
-- ---------------------------------------------------------------------------

function dir:Forget(force)
    local at = now()
    for key, row in pairs(self.partners) do
        local last = math.max(row.greetedAt or -1e9, row.heardAt or -1e9, row.presenceAt or -1e9,
            row.askedAt or -1e9, row.silentUntil or -1e9)
        if at - last > self.SILENT_SEC or (force and at - last > self.PRESENCE_SEC) then
            self.partners[key] = nil
            self.partnerCount = self.partnerCount - 1
        end
    end
end

local function partnerRow(name, create)
    local key = name:lower()
    local row = dir.partners[key]
    if row or not create then return row end
    if dir.partnerCount >= dir.PARTNER_ROWS then dir:Forget(true) end
    if dir.partnerCount >= dir.PARTNER_ROWS then
        dir.stats.full = dir.stats.full + 1
        return nil
    end
    row = { name = name }
    dir.partners[key] = row
    dir.partnerCount = dir.partnerCount + 1
    return row
end

-- A partner: a player we greeted ourselves, that answered, and that the relay still reaches
-- directly (the route written for a greeting is no neighbour until something comes back:
-- Relay:NoteDirectoryRoute). A player who greeted us first is answered and stays an ordinary
-- neighbour: nobody earns a share of our rounds by whispering to us.
function dir:IsUsable(row)
    local net = addon.Relay
    return net ~= nil and row.greetedAt ~= nil and net:IsDirectPeer(row.name)
end

-- 2.2.1: players of the list that answered our greeting by whisper (2.2.0 or later) and that
-- the relay reaches. A guild mate we greeted is a direct peer through the guild without ever
-- answering: it showed as "exchanging with you" while nothing went through the list.
function dir:AnsweringCount()
    local live = 0
    for _, row in pairs(self.partners) do
        if row.heardAt and self:IsUsable(row) then live = live + 1 end
    end
    return live
end

-- Partners answering us now, and greetings still waiting for their answer.
function dir:LiveCount()
    local count, at = 0, now()
    for _, row in pairs(self.partners) do
        if self:IsUsable(row) or (row.greetedAt and at - row.greetedAt < self.ANSWER_WAIT
            and not row.heardAt) then
            count = count + 1
        end
    end
    return count
end

-- A listed player we do not hear yet, not greeted lately, not left alone.
function dir:PickNew()
    local names, net = self.names, addon.Relay
    local size = #names
    if size == 0 or not net then return nil end
    local at, start = now(), math.random(1, size)
    for step = 0, math.min(size, 40) - 1 do
        local name = names[(start + step - 1) % size + 1]
        local row = self.partners[name:lower()]
        if not net:IsPeer(name) and not (row and ((row.silentUntil or 0) > at
            or at - (row.presenceAt or -1e9) < self.PRESENCE_SEC)) then
            return name
        end
    end
    return nil
end

local function sendPresence(row)
    local net = addon.Relay
    if not net or not net:Send("NH", tostring(addon.Version or ""), row.name) then return false end
    row.presenceAt = now()
    return true
end

function dir:Greet(name)
    local net = addon.Relay
    if not net or not net.NoteDirectoryRoute then return false end
    local row = partnerRow(name, true)
    if not row then return false end
    -- The whisper follows a route: one is written for this player unless a live one exists.
    net:NoteDirectoryRoute(name)
    if not sendPresence(row) then return false end
    row.greetedAt, row.heardAt = now(), nil
    self.stats.greeted = self.stats.greeted + 1
    local generation = self.generation
    C_Timer.After(self.ANSWER_WAIT, function()
        if dir.generation == generation then dir:CheckAnswer(row) end
    end)
    return true
end

function dir:CheckAnswer(row)
    if self.partners[row.name:lower()] ~= row or not row.greetedAt or row.heardAt then return end
    if self:IsUsable(row) then
        -- It spoke (a client before 2.2.0 that pulled our map, for instance).
        row.heardAt = now()
        return
    end
    row.silentUntil = now() + self.SILENT_SEC
    self.stats.silent = self.stats.silent + 1
end

-- A presence addressed to us alone, by whisper from its own author (Relay:Receive): a player
-- that found us in the list, or the answer to our greeting. Answered once per PRESENCE_SEC.
-- session: its relay session. A new one (a /reload, a relog) knows nothing of the presence we
-- gave the old one: answered then even within PRESENCE_SEC, once per PRESENCE_SEC.
function dir:OnGreeting(origin, session)
    -- Nothing of this runs while the channel works.
    if not self:IsActive() then return false end
    local row = partnerRow(origin, true)
    if not row then return false end
    local at = now()
    if type(session) == "string" and session ~= "" and row.session ~= session then
        if row.session and at - (row.renewedAt or -1e9) >= self.PRESENCE_SEC then
            row.presenceAt, row.renewedAt = nil, at
        end
        row.session = session
    end
    if row.greetedAt and not row.heardAt and at - row.greetedAt <= self.ANSWER_WAIT then
        self.stats.answered = self.stats.answered + 1
    elseif not row.heardAt or at - row.heardAt > self.PRESENCE_SEC then
        self.stats.greetedUs = self.stats.greetedUs + 1
    end
    row.heardAt, row.silentUntil = at, nil
    -- 2.2.0 or later (only the list greets this way): a contact of the chain (ChainTargets), once
    -- the list we read names it. A newcomer to the list: read it again soon.
    row.chainAt = at
    -- (Never later than planned: no planned read yet is a read at once.)
    if not self:Lists(origin) and at - (self.readAt or -1e9) >= self.REREAD_SEC
        and self.nextReadAt and self.nextReadAt > at + self.RETRY_SEC then
        self.nextReadAt = at + self.RETRY_SEC
    end
    if at - (row.presenceAt or -1e9) < self.PRESENCE_SEC then return false end
    local replies = self.replies
    if at - replies.at >= 60 then replies.at, replies.count = at, 0 end
    if replies.count >= self.REPLIES_PER_MIN then
        self.stats.repliesCapped = self.stats.repliesCapped + 1
        return false
    end
    if not sendPresence(row) then return false end
    replies.count = replies.count + 1
    self.stats.replies = self.stats.replies + 1
    return true
end

-- Is there a partner to ask (accept: the caller's own rules), and which one, the one asked
-- longest ago?
function dir:HasPartner(accept)
    if not self:IsActive() then return false end
    for _, row in pairs(self.partners) do
        if self:IsUsable(row) and (not accept or accept(row.name)) then return true end
    end
    return false
end

function dir:PickPartner(accept, purpose)
    if not self:IsActive() then return nil end
    local best
    for _, row in pairs(self.partners) do
        if self:IsUsable(row) and (not accept or accept(row.name))
            and (not best or (row.askedAt or 0) < (best.askedAt or 0)) then
            best = row
        end
    end
    if not best then return nil end
    best.askedAt = now()
    if purpose == "map" then self.stats.mapTurns = self.stats.mapTurns + 1
    else self.stats.ladderTurns = self.stats.ladderTurns + 1 end
    return best.name
end

-- Before a map round with a player of the list we hear from (a partner, or a player who greeted
-- us: our presence reaches neither through the guild): our presence, unless it went there
-- lately. True when one went out (the caller then waits MAP_PULL_DELAY before its request).
-- Measured: with partners alone, the others answered an identical map with its pages (10 to
-- 20 more map pages a minute for 36 clients, as many relay forwards). Not to a listed player
-- we never heard through the list (greeted and silent: a client before 2.2.0, which our guild
-- presence reaches when it is a guild mate). Nothing once the channel carries again: the
-- channel takes our presence there.
function dir:BeforeMapPull(name)
    if not self:IsActive() then return false end
    local row = type(name) == "string" and self.partners[name:lower()] or nil
    if not row or not row.heardAt or now() - (row.presenceAt or -1e9) < self.MAP_PRESENCE_SEC then
        return false
    end
    return sendPresence(row)
end

-- ---------------------------------------------------------------------------
-- The chain: live news passed from hand to hand
-- ---------------------------------------------------------------------------
--
-- The rounds above bring the map minutes late: on the beta the channel told every player of a
-- capture within a second. So, while the channel does not carry, a few live facts go from hand to
-- hand along the list instead: a capture (C, or its final ZS), a siege as it starts (never its
-- ticks: GuildLane:KeepFollowing keeps its clock, as for a siege told in the guild), the release of
-- a siege we passed on, a victory, a call to arms, a general's news, an outpost under attack, our
-- own keep or outpost capture. Whoever starts one whispers it to a few of its contacts, each of
-- them to a few of theirs, and so on: four hands at most, the relay's longest path.
--  * A contact is a player of the list whose own presence came to us by whisper, addressed to us
--    (a greeting or its answer, OnGreeting: 2.2.0 or later), and whom the relay still reaches
--    directly. Nothing goes to anybody else, and nothing is passed on for anybody else: what a
--    stranger whispers is delivered here and goes no further by the list.
--  * Each fact is passed on once (GuildLane:CoverKey: one capture told by several players, or by
--    its C and its final ZS, is one fact; a capture dated later is passed on again: every client
--    keeps the latest date). A release follows its start: only those who passed the start on.
--  * Heard in the guild or the group, a fact was heard by everybody there: only about
--    MULTICAST_SPEAKERS of them pass it on.
--  * Budgets: CHAIN_RATE whispers a second (CHAIN_BURST at once) for the whole client, and at
--    most PER_GATEWAY facts a minute passed on for one sender, PER_MIN for all. Past them a fact
--    is still delivered here; it reaches the others by the rounds.
-- Sized by a model of the list (contacts as this file makes them, 10-20 % of them gone into an
-- instance): 96-98 % of the 2.2.0 clients of a list of 270 within four hands, about four whispers
-- per client and per fact (FANS: per list size, the fewest whispers that still reach 97 %).
dir.FANS = {
    { 45, { 10, 6, 3, 2 } }, { 80, { 10, 6, 4, 2 } }, { 125, { 10, 6, 4, 3 } },
    { 200, { 12, 8, 5, 3 } }, { 330, { 12, 8, 6, 4 } }, { math.huge, { 12, 10, 6, 4 } },
}
dir.CHAIN_RATE, dir.CHAIN_BURST = 0.75, 30
-- Our own kill total (K): first-hand to RANK_FAN contacts, who credit it (Sync:OnReceiveKill: the
-- whisper names its author) and answer ranking pages with it. One per RANK_GAP at most, never
-- from the RANK_RESERVE tokens kept for captures and sieges. Nobody passes a K on.
dir.RANK_GAP, dir.RANK_FAN, dir.RANK_RESERVE = 30, 6, 20
-- Copies we pass on never spend the last FORWARD_RESERVE tokens: those are our own captures'.
dir.FORWARD_RESERVE = 10
dir.PER_GATEWAY, dir.PER_MIN = 8, 30
dir.MULTICAST_SPEAKERS, dir.CHAIN_FRAGMENTS = 2, 2
-- How long a passed start is remembered for its release (the relay's TTL and a margin), and how
-- long a heard copy of a capture keeps our own report of it quiet (GuildLane: HEARD_COVER_SEC).
dir.START_MEMORY, dir.OWN_COVER_SEC = 300, 10
dir.CHAIN_ROWS = 256
dir.chain = { tokens = dir.CHAIN_BURST, cover = {}, starts = {}, intake = {}, rows = 0,
    minute = { at = -1000, count = 0 } }
for _, key in ipairs({ "chainOwn", "chainForwarded", "chainWhispers", "chainCovered", "chainCapped",
    "chainNoContact", "chainLeft", "chainStranger", "chainRetold", "chainUnvouched" }) do dir.stats[key] = 0 end

local FIXED_FACTS = { C = true, TV = true, GE = true, GX = true, GD = true, FC = true }

-- The 11th field of a zone state: its wave (as GuildLane reads it).
local function stateWave(payload)
    return payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*)")
end

-- A capture of the other side reaches our list over a Battle.net friend, a hand or two along the
-- relay's four already: the hands left (two, mostly) spread it with the fans of the first ones.
local function enemyCapture(p)
    local mine = addon.PlayerFaction
    if mine ~= "Alliance" and mine ~= "Horde" then return false end
    local side
    if p.kind == "C" then
        side = p.payload:match("^[^:]*:[^:]*:([^:]*):")
    elseif p.kind == "ZS" then
        local code = p.payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:([AH]):")
        side = code == "A" and "Alliance" or code == "H" and "Horde" or nil
    end
    return (side == "Alliance" or side == "Horde") and side ~= mine
end

local function captureDate(p)
    if p.kind == "C" then return tonumber(p.payload:match("^[^:]*:[^:]*:[^:]*:(%d+)")) end
    if p.kind == "ZS" then return tonumber(p.payload:match("^[^:]*:captured:[^:]*:[^:]*:[^:]*:(%d+)")) end
    return nil
end

-- A point of our maps (a fact about another one is nobody's news).
function dir:KnowsZone(zoneId)
    if type(zoneId) ~= "string" or zoneId == "" then return false end
    local zones, fronts = addon.Zones, addon.Fronts
    return (zones ~= nil and zones.GetZone ~= nil and zones:GetZone(zoneId) ~= nil)
        or (fronts ~= nil and fronts.IsKnownZoneId ~= nil and fronts:IsKnownZoneId(zoneId) == true)
end
dir.FACT_SKEW = 900

-- What the chain does with a broadcast: "fact", "start" (a siege starting; zone, wave), "release"
-- (zone, wave), or nil when it stays off the chain.
local function chainShape(p)
    local kind, payload = p.kind, p.payload
    if type(payload) ~= "string" then return nil end
    if FIXED_FACTS[kind] then return "fact" end
    if kind == "K" then return #p.path == 1 and "rank" or nil end
    -- Believed first-hand only (Relay:Receive does not pass one on): our own, to our contacts.
    if kind == "OC" then return #p.path == 1 and "fact" or nil end
    if kind == "OP" then
        return payload:match("^v%d+:[^:]*:([^:]*)") == "in_progress" and "fact" or nil
    end
    if kind == "ZR" then
        local zone, wave = payload:match("^([^:]*):([^:]*)")
        if zone and zone ~= "" and wave and wave ~= "" then return "release", zone, wave end
        return nil
    end
    -- Map news (Sync:QueueMapNews, NoteMapNews): what a client of ours learnt from the other side.
    if kind == "ZA" then
        local net = addon.Relay
        return net and net.IsMapNews and net.IsMapNews(p) and "news" or nil
    end
    if kind ~= "ZS" then return nil end
    local zone, status, hold = payload:match("^([^:]+):([^:]+):[^:]*:(%d*)")
    if status == "captured" then
        local wave = stateWave(payload)
        if not wave or wave == "" then return nil end
        -- A failed siege hands the point back with its author's name: its release says it. (Not
        -- over Battle.net: there the author is of the other side, and that is its capture.)
        if p.heardOn ~= "BNET" then
            local code, capturer = payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:([AH]?):[^:]*:[^:]*:[^:]*:([^:]*)")
            if code and code ~= tostring(addon.PlayerFaction):sub(1, 1) and capturer and capturer ~= ""
                and sync:ForeverIdentitiesMatch(capturer, p.path[1]) then
                return nil
            end
        end
        return "fact"
    end
    if status == "in_progress" and (tonumber(hold) or 999) <= 45 then
        local wave = stateWave(payload)
        if wave and wave ~= "" then return "start", zone, wave end
    end
    return nil
end

-- Whispers for a copy leaving with a path of `level` names (1: our own).
function dir:FanFor(level)
    local size, fans = #self.names, self.FANS[#self.FANS][2]
    for _, row in ipairs(self.FANS) do
        if size < row[1] then fans = row[2]; break end
    end
    return fans[math.min(math.max(level, 1), #fans)]
end

-- A whisper to it came back "no player named" (SyncAux's filter): no contact and no partner until it
-- greets us again.
function dir:NoteUnreachable(name)
    local canon = type(name) == "string" and sync:CanonicalForeverName(name) or nil
    local row = canon and self.partners[canon:lower()] or nil
    if not row then return false end
    row.chainAt, row.silentUntil = nil, now() + self.PRESENCE_SEC
    return true
end

-- In the channel member list as last read (names are canonical there).
function dir:Lists(name)
    if type(name) ~= "string" then return false end
    if self.listedFor ~= self.names or self.listedCount ~= #self.names then
        local listed = {}
        for _, listedName in ipairs(self.names) do listed[listedName:lower()] = true end
        self.listed, self.listedFor, self.listedCount = listed, self.names, #self.names
    end
    return self.listed[name:lower()] == true
end

-- A contact: whispered its presence to us (OnGreeting), in the member list, and reached directly
-- now. (A whisper alone makes no contact: anybody can send one.)
function dir:IsContact(name)
    local net = addon.Relay
    local row = type(name) == "string" and self.partners[name:lower()] or nil
    return row ~= nil and row.chainAt ~= nil and net ~= nil and self:Lists(row.name)
        and net:IsDirectPeer(row.name)
end

-- Sync:OnReceiveZoneAll, for a map whose author's presence was never heard here (without the
-- channel, most of the list): taken when it is one capture told as map news, whispered along the
-- chain by a contact up to date, and the author is not known here as out of date. The contact
-- passed it on only when it knew the author up to date, or had it from a contact itself
-- (ChainTargets): the word of those who heard the author goes from hand to hand.
function dir:VouchesMapNews(origin, payload)
    local net = addon.Relay
    local context = net and net.context
    if not context or context.transport ~= "WHISPER" or context.targeted ~= false
        or not net:IsDispatching(origin) or net:HeardPresenceOf(origin) then return false end
    if type(payload) ~= "string" or not payload:match("^@P%-%d+%-%d+:1:1|[^,]+$") then return false end
    local gateway = context.gateway
    if not self:IsContact(gateway) or net:IsOutdatedMapPeer(gateway) then return false end
    -- Taken, never a second source (Sync:IsSuspiciousZaFlip): one sender whispering the same
    -- news to two hands would confirm itself.
    context.vouched = true
    return true
end

-- A siege told along the chain or in the guild (no ticks follow it, CaptureLease opens it): its
-- outcome, passed from hand to hand at random, may miss us (a few in a hundred). Once its capture
-- could have been made, plus GAP_WAIT and up to GAP_SPREAD, a partner is asked for its map, unless
-- the outcome came meanwhile (PullAfterWave). Those who heard it never ask: a siege given up without
-- a word makes every follower ask once, spread, one partner each (an identical map comes back
-- without its pages).
dir.GAP_WAIT, dir.GAP_SPREAD, dir.GAP_MIN_SEC = 10, 30, 30
-- And GAP_BUDGET maps at most per GAP_WINDOW: sieges told and never ended cost no more than that.
dir.GAP_BUDGET, dir.GAP_WINDOW = 5, 600
-- About GAP_ASKERS clients of the list ask (the same ones for one siege); one that learns a capture
-- that way tells it along the chain as map news.
dir.GAP_ASKERS, dir.GAP_TELL_SEC = 4, 10
-- (A siege still followed past its end is more often a missed capture: more of the list ask.)
dir.GAP_ASKERS_FOLLOWED = 12
-- A list read at most every REREAD_SEC for a newcomer that greeted us.
dir.REREAD_SEC = 120
function dir:WatchWave(zone, remote)
    if not self:IsActive() or type(zone) ~= "table" or type(remote) ~= "table" or not remote.viaGuild
        or remote.watched then return false end
    remote.watched = true
    local at = now()
    local openedAt = tonumber(remote.openedAt) or at
    local required = tonumber(remote.effectiveRequired) or 120
    local finish = openedAt + math.max(0, required - (tonumber(remote.openedHold) or 0))
    local serverAt = addon.ServerNow and addon.ServerNow() or time()
    local opened = serverAt - (at - openedAt)
    local generation = self.generation
    C_Timer.After(math.max(0, finish - at) + self.GAP_WAIT + math.random() * self.GAP_SPREAD, function()
        if dir.generation == generation then dir:PullAfterWave(zone, remote, opened) end
    end)
    return true
end

function dir:PullAfterWave(zone, remote, opened, retried)
    if not self:IsActive() or addon.InstanceSuspended then return false end
    -- Still followed, or given up in silence with no capture dated since it began: no outcome
    -- reached us. Anything else is one (its capture, its release), or another wave runs there.
    local current = zone._remoteCaptureLease
    if current ~= remote and (current or remote.endedBy ~= "timeout"
        or (tonumber(zone.capturedTime) or 0) >= opened - 5) then return false end
    local at = now()
    if at - (self.gapAt or -1e9) < self.GAP_MIN_SEC then
        -- One map answers for every point: another silent siege asks once the spacing allows.
        if not retried then
            local generation = self.generation
            C_Timer.After(self.GAP_MIN_SEC - (at - self.gapAt) + 1, function()
                if dir.generation == generation then dir:PullAfterWave(zone, remote, opened, true) end
            end)
        end
        return false
    end
    -- Every follower would ask at once (a siege given up in silence, or still fought past its
    -- end): a few of the list ask, the same ones for one siege, and tell along the chain what the
    -- map taught them (below).
    local net, size = addon.Relay, #self.names
    local askers = current == remote and self.GAP_ASKERS_FOLLOWED or self.GAP_ASKERS
    if size > askers and net and net.HashFrac then
        local me = tostring(sync:GetPlayerFullName() or ""):lower()
        if net.HashFrac(me .. "|" .. tostring(zone.id) .. "|" .. math.floor(opened)) >= askers / size then
            return false
        end
    end
    if at - (self.gapWindowAt or -1e9) >= self.GAP_WINDOW then self.gapWindowAt, self.gapCount = at, 0 end
    if self.gapCount >= self.GAP_BUDGET then return false end
    local payload = sync.GetSRPayload and sync:GetSRPayload("T")
    -- (A partner whose map we would refuse, a client before 2.2.0 that pulled ours, is not asked.)
    local target = payload and self:PickPartner(function(name) return not sync:IsOutdatedMapPeer(name) end, "map")
    if not target then return false end
    self.gapAt, self.gapCount = at, self.gapCount + 1
    self.stats.gapPulls = self.stats.gapPulls + 1
    local generation = self.generation
    local function ask()
        if addon.InstanceSuspended or not outside() or dir.generation ~= generation then return end
        pcall(sync.SendWhisper, sync, "SR", payload, target)
        -- A capture the map taught us is told along the chain: the others did not ask.
        C_Timer.After(dir.GAP_TELL_SEC, function()
            local ct = tonumber(zone.capturedTime) or 0
            if dir.generation == generation and dir:IsActive() and ct >= opened - 5 and sync.NoteMapNews then
                pcall(sync.NoteMapNews, sync, zone.id, ct)
            end
        end)
    end
    -- Our presence first, so that an identical map comes back without its pages.
    if self:BeforeMapPull(target) then C_Timer.After(self.MAP_PULL_DELAY, ask) else ask() end
    return true
end

-- How many clients may follow a siege the chain told (GuildLane:AsksAboutWave).
function dir:ChainFollowers()
    if not self:IsActive() then return 0 end
    return #self.names
end

-- The chain's three small books share one bound.
-- book: the name of the table in dir.chain (a flood replaces the tables themselves).
local function keep(book, key, value)
    local chain = dir.chain
    if chain[book][key] == nil then
        chain.rows = chain.rows + 1
        if chain.rows > dir.CHAIN_ROWS then
            local at, rows = now(), 0
            for k, row in pairs(chain.cover) do
                if at - row.at > 300 then chain.cover[k] = nil else rows = rows + 1 end
            end
            for k, row in pairs(chain.starts) do
                if at - row.at > dir.START_MEMORY then chain.starts[k] = nil else rows = rows + 1 end
            end
            for k, row in pairs(chain.intake) do
                if at - row.at >= 60 then chain.intake[k] = nil else rows = rows + 1 end
            end
            -- A flood of made-up facts only costs this memory.
            -- (The intake counters stay: they are the caps against that flood.)
            if rows > dir.CHAIN_ROWS then
                rows = 0
                for _ in pairs(chain.intake) do rows = rows + 1 end
                chain.cover, chain.starts = {}, {}
            end
            chain.rows = rows + 1
        end
    end
    chain[book][key] = value
end

-- Every whisper counts: a fact of two fragments costs two tokens per contact.
local function takeTokens(wanted, fragments)
    local chain, at = dir.chain, now()
    chain.tokens = math.min(dir.CHAIN_BURST, chain.tokens + math.max(0, at - (chain.at or at)) * dir.CHAIN_RATE)
    chain.at = at
    fragments = math.max(1, tonumber(fragments) or 1)
    local granted = math.min(wanted, math.floor(chain.tokens / fragments))
    if granted > 0 then chain.tokens = chain.tokens - granted * fragments end
    return granted
end

-- Relay tasksFor, for a broadcast about to leave (ours, or one we pass on: we are then the last
-- name of its path): the contacts to whisper it to, or nil.
function dir:ChainTargets(p, fragmentCount)
    local net = addon.Relay
    if not net or p.target ~= "*" or p.groupOnly or type(p.path) ~= "table" or #p.path < 1 or #p.path > 4
        or (tonumber(fragmentCount) or 99) > self.CHAIN_FRAGMENTS then return nil end
    local shape, zone, wave = chainShape(p)
    if not shape or not self:IsActive() then return nil end
    local stats, chain, at = self.stats, self.chain, now()
    local own = #p.path == 1
    local startKey = zone and (zone .. "|" .. wave) or nil
    local lane = addon.GuildLane
    local key, window
    if lane and lane.CoverKey then key, window = lane:CoverKey(p) end
    key, window = key or (p.kind .. "|" .. p.payload), window or 30
    local date = captureDate(p)
    if shape == "news" then
        -- One capture told as map news is the same fact as its C (a client that passed the C
        -- on does not pass the news on).
        local body = p.payload:match("^@P%-%d+%-%d+:1:1|([^,]+)$")
        local newsZone, owner, ct
        if body and sync.MapNewsEntry then newsZone, owner, ct = sync:MapNewsEntry(body) end
        if newsZone and (owner == "Alliance" or owner == "Horde") and tonumber(ct) then
            key, window, date = "CAP|" .. newsZone .. "|" .. owner:sub(1, 1), 30, tonumber(ct)
        end
    end
    -- A capture of the other side heard from a Battle.net friend with too few hands left for our
    -- list (the relay stops at four names): passed on as it is, for those who follow its siege (a
    -- map does not end a wave they follow: only its capture does), and told again by us as map
    -- news, a path of its own, for everybody further.
    if enemyCapture(p) and p.heardOn == "BNET" and #p.path >= 3 and date and sync.NoteMapNews then
        local captured = p.payload:match("^([^:]+):")
        local okNews, told = pcall(sync.NoteMapNews, sync, captured, date)
        if okNews and told then
            stats.chainRetold = stats.chainRetold + 1
            chain.retold = chain.retold or {}
            chain.retold[captured] = date
        end
    end
    -- Our own retelling of it is not covered by the capture we just passed on.
    local newsZone = shape == "news" and own and key:match("^CAP|([^|]+)|") or nil
    if newsZone and chain.retold and chain.retold[newsZone] == date then
        chain.retold[newsZone] = nil
        shape = "retelling"
    end
    local start = startKey and chain.starts[startKey] or nil
    if shape == "rank" then
        -- A newer total taking the place of one still waiting in the relay queue (SyncRelay Send):
        -- the same whispers, nothing spent again.
        if p.chainRetake and chain.rankTargets and at - (chain.rankAt or -1e9) < self.RANK_GAP then
            local again = {}
            for _, name in ipairs(chain.rankTargets) do
                if net:IsDirectPeer(name) then again[#again + 1] = name end
            end
            chain.rankTargets = again
            return #again > 0 and again or nil
        end
        if at - (chain.rankAt or -1e9) < self.RANK_GAP then
            -- Told once more when the gap ends, if still the latest (a fight that stops).
            chain.rankLatest = p.payload
            if not chain.rankTimer then
                chain.rankTimer = true
                local generation = self.generation
                C_Timer.After(self.RANK_GAP - (at - chain.rankAt) + 0.5, function()
                    chain.rankTimer = nil
                    local latest = chain.rankLatest
                    chain.rankLatest = nil
                    if dir.generation == generation and latest and dir:IsActive() then
                        pcall(net.Broadcast, net, "K", latest)
                    end
                end)
            end
            return nil
        end
        chain.rankLatest = nil
        takeTokens(0, 1)
        if chain.tokens - self.RANK_FAN < self.RANK_RESERVE then
            stats.chainCapped = stats.chainCapped + 1
            return nil
        end
    elseif shape == "release" then
        -- A release follows its start, by the same hands only.
        if not start or at - start.at > self.START_MEMORY then return nil end
    elseif shape ~= "retelling" then
        -- Told already. Our own report of a capture gives way only to a copy heard just now and
        -- dated at least as late (a copy made up in advance must not silence the capturer).
        local cover = chain.cover[key]
        local limit = (own and date) and math.min(window, self.OWN_COVER_SEC) or window
        if cover and at - cover.at < limit and not (date and date > (cover.date or 0)) then
            stats.chainCovered = stats.chainCovered + 1
            return nil
        end
    end
    local me = tostring(sync:GetPlayerFullName() or ""):lower()
    if not own then
        local heardOn, gateway = p.heardOn, p.path[#p.path - 1]
        if heardOn == "WHISPER" and not self:IsContact(gateway) then
            stats.chainStranger = stats.chainStranger + 1
            return nil
        end
        -- Heard by a whole guild or group: a few of them speak, the same ones for one fact.
        local audience
        if heardOn == "GUILD" then audience = lane and lane.PeerCount and lane:PeerCount() or 1
        elseif heardOn == "PARTY" or heardOn == "RAID" then
            audience = GetNumGroupMembers and tonumber(GetNumGroupMembers()) or 1
        end
        if shape ~= "release" and audience and audience > self.MULTICAST_SPEAKERS and net.HashFrac
            and net.HashFrac(me .. "|" .. key) >= self.MULTICAST_SPEAKERS / audience then
            stats.chainLeft = stats.chainLeft + 1
            return nil
        end
        -- A map news is taken only from an author whose presence says it is up to date
        -- (Sync:IsOutdatedMapPeer). Passed on only by those who know it so, or who had it from a
        -- contact that did (VouchesMapNews): whoever gets it from us takes it on our word.
        local author = p.path[1]
        -- Several captures in one news are taken only from an author heard first-hand: passed on,
        -- only one capture is (VouchesMapNews).
        if shape == "news" and not p.payload:match("^@P%-%d+%-%d+:1:1|[^,]+$")
            and not (net:HeardPresenceOf(author) and not net:IsOutdatedMapPeer(author)) then
            stats.chainUnvouched = stats.chainUnvouched + 1
            return nil
        end
        if shape == "news" and net:IsOutdatedMapPeer(author)
            and not (heardOn == "WHISPER" and not net:HeardPresenceOf(author)) then
            stats.chainUnvouched = stats.chainUnvouched + 1
            return nil
        end
        -- Someone else's capture or siege is passed on only for a point of ours, dated about now:
        -- made-up points or dates would each be a new fact for the cover, and fill the chain.
        if p.kind == "C" or p.kind == "ZS" or p.kind == "ZR" then
            local serverAt = addon.ServerNow and addon.ServerNow() or time()
            if not self:KnowsZone(p.payload:match("^([^:]+)"))
                or (date and math.abs(date - serverAt) > self.FACT_SKEW) then
                stats.chainUnvouched = stats.chainUnvouched + 1
                return nil
            end
        end
        local minute = chain.minute
        if at - minute.at >= 60 then minute.at, minute.count = at, 0 end
        local gatewayKey = tostring(gateway or ""):lower()
        local intake = chain.intake[gatewayKey]
        if not intake or at - intake.at >= 60 then
            intake = { at = at, count = 0 }
            keep("intake", gatewayKey, intake)
        end
        if minute.count >= self.PER_MIN or intake.count >= self.PER_GATEWAY then
            stats.chainCapped = stats.chainCapped + 1
            return nil
        end
        minute.count, intake.count = minute.count + 1, intake.count + 1
    end
    -- Our contacts, those already on the path left out.
    local onPath = {}
    for _, node in ipairs(p.path) do onPath[node:lower()] = true end
    local view = {}
    for lower, row in pairs(self.partners) do
        if row.chainAt and not onPath[lower] and self:Lists(row.name) and net:IsDirectPeer(row.name) then
            view[#view + 1] = row.name
        end
    end
    local level = #p.path
    if level > 1 and enemyCapture(p) then level = math.max(1, level - 2) end
    local wanted = math.min(shape == "rank" and self.RANK_FAN or self:FanFor(level), #view)
    if wanted == 0 then
        stats.chainNoContact = stats.chainNoContact + 1
        return nil
    end
    local granted
    if own then
        granted = takeTokens(wanted, fragmentCount)
    else
        takeTokens(0, 1)
        local spare = math.floor((chain.tokens - self.FORWARD_RESERVE) / math.max(1, tonumber(fragmentCount) or 1))
        granted = spare > 0 and takeTokens(math.min(wanted, spare), fragmentCount) or 0
    end
    if granted == 0 then
        stats.chainCapped = stats.chainCapped + 1
        return nil
    end
    for i = 1, granted do
        local j = math.random(i, #view)
        view[i], view[j] = view[j], view[i]
    end
    local targets = {}
    for i = 1, granted do targets[i] = view[i] end
    if shape == "rank" then
        chain.rankAt, chain.rankTargets = at, targets
    elseif shape == "release" then
        chain.starts[startKey] = nil
        -- The point may be told again at once: a new wave is a new start.
        if start.cover then chain.cover[start.cover] = nil end
    else
        keep("cover", key, { at = at, date = date })
    end
    if shape == "start" then keep("starts", startKey, { at = at, cover = key }) end
    if own then stats.chainOwn = stats.chainOwn + 1 else stats.chainForwarded = stats.chainForwarded + 1 end
    stats.chainWhispers = stats.chainWhispers + granted * math.max(1, tonumber(fragmentCount) or 1)
    return targets
end

-- ---------------------------------------------------------------------------
-- When it runs
-- ---------------------------------------------------------------------------

function dir:IsActive()
    local net, lane = addon.Relay, addon.GuildLane
    if addon.RelayEnabled == false or not net or not net.started or not self.started or not outside() then
        return false
    end
    return lane ~= nil and lane:ChannelDown()
end

-- Closer rounds while a partner answers that the caller may ask (accept: the caller's own
-- rules, see PartnerTurnAhead in SyncHistoryCatchup.lua).
function dir:FastRounds(accept)
    return self:HasPartner(accept)
end

function dir:Tick()
    if not self:IsActive() then
        self.suspended = nil
        return
    end
    local at = now()
    if not self.fetching and at >= (self.nextReadAt or 0) then self:Refresh() end
    if #self.names > 0 and at >= (self.nextGreetAt or 0) then
        local greeted = false
        if self:LiveCount() < self.MAX_PARTNERS then
            local name = self:PickNew()
            greeted = name ~= nil and self:Greet(name)
        end
        self.nextGreetAt = greeted and at + self.GREET_SEC + math.random(0, self.GREET_JITTER)
            or at + self.TICK_SEC
    end
    if at - (self.forgottenAt or 0) >= 300 then
        self.forgottenAt = at
        self:Forget()
    end
end

function dir:Arm(delay)
    local generation = self.generation
    C_Timer.After(delay, function()
        if dir.generation ~= generation then return end
        local ok, err = pcall(dir.Tick, dir)
        if not ok then dir.lastError = tostring(err) end
        dir:Arm(dir.TICK_SEC)
    end)
end

-- Relay:Start. The first look comes once the channel had time to be refused or seated.
function dir:Start()
    if self.started then return end
    self.started = true
    self.generation = self.generation + 1
    self:Arm(self.TICK_SEC)
end

-- An instance: everything stops (the list, greetings waiting for an answer, the ticker).
function dir:Suspend()
    self.generation = self.generation + 1
    self.fetching = nil
end

function dir:Resume()
    if not self.started then return end
    self.generation = self.generation + 1
    self:Arm(self.TICK_SEC * (1 + math.random()))
end

-- ---------------------------------------------------------------------------
-- Reports (/ov network, panel)
-- ---------------------------------------------------------------------------

-- One phrase for the panel's "Channel and guild" line, nil while the directory has nothing,
-- and how many players of the list exchange with us.
function dir:Describe()
    if not self:IsActive() then return nil, 0 end
    if #self.names == 0 then return "channel member list: " .. (self.state or "not read yet"), 0 end
    local live = self:AnsweringCount()
    return string.format("%d players in the channel member list, %d of them exchanging with you", #self.names, live),
        live
end

function dir:GetDiagnostics()
    local s, at = self.stats, now()
    local proven = {}
    for _, method in ipairs(self.FETCH_METHODS) do
        if self.provenMethods[method] then proven[#proven + 1] = method end
    end
    local live = self:AnsweringCount()
    return string.format("Channel member list: %d names%s, %d reads, %d fetches (%s), %d failed%s; "
        .. "partners: %d greeted, %d answered, %d silent, %d greeted us, %d answers, %d capped, "
        .. "%d refused (table full), %d live, %d ranking rounds, %d map rounds%s",
        #self.names, self.readAt and string.format(" read %d s ago", math.floor(at - self.readAt)) or "",
        s.reads, s.fetches, #proven > 0 and table.concat(proven, ", ") or "no method proven", s.fetchFailed,
        self.state and (", " .. self.state) or "",
        s.greeted, s.answered, s.silent, s.greetedUs, s.replies, s.repliesCapped, s.full, live,
        s.ladderTurns, s.mapTurns, self.lastError and ("; last error: " .. self.lastError) or "")
        .. string.format("; chain: %d own, %d passed on, %d whispers, %d told already, %d capped, "
            .. "%d without a contact, %d left to others, %d from strangers, %d told again as map news, "
            .. "%d map news of an unknown author kept; %d maps asked after a silent siege",
            s.chainOwn, s.chainForwarded, s.chainWhispers, s.chainCovered, s.chainCapped, s.chainNoContact,
            s.chainLeft, s.chainStranger, s.chainRetold, s.chainUnvouched, s.gapPulls)
end
