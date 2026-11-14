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
    -- 2.2.2: after a round that changed our ranking, the next one comes in LADDER_HOT_SEC +
    -- 0..LADDER_HOT_JITTER s (what we just took is news to our other partners); an idle one
    -- rests as above.
    LADDER_HOT_SEC = 6, LADDER_HOT_JITTER = 6,
    -- 2.5.0: once LADDER_FED_SOURCES peers feed us the rows that move (SyncLeaderboardPages, "The
    -- feed"), an idle round is followed LADDER_FED_SEC + 0..LADDER_FED_JITTER s later.
    LADDER_FED_SEC = 100, LADDER_FED_JITTER = 60, LADDER_FED_SOURCES = 3,
    MAP_PRESENCE_SEC = 100, MAP_PULL_DELAY = 2,
    -- 2.2.2: a first silence keeps a player alone FIRST_SILENT_SEC (SILENT_SEC from the second):
    -- the first players back after a restart were greeted by many at once, their answers
    -- capped, and the whole faction left them alone for half an hour. Answers past the cap
    -- wait for the next minute (REPLY_QUEUE at most) instead of being dropped.
    FIRST_SILENT_SEC = 300, REPLY_QUEUE = 6,
    -- 2.2.2: a quicker start: BOOT_GREETS greetings BOOT_GAP apart after the first list read,
    -- and greetings go on while fewer than MIN_CONTACTS contacts are in the chain's view.
    BOOT_GREETS = 3, BOOT_GAP = 4, MIN_CONTACTS = 8,
    -- 2.2.2: the address book. Some clients never get the member list (the game keeps our
    -- channel suspended for them, or never loads its list): they had no contact at all, and
    -- the chain never reached them. Players of the list that answered our greeting are kept
    -- (BOOK_MAX names, BOOK_DAYS) in the saved variables, per region, channel and faction; a
    -- client without a list greets them (one every BOOK_GREET_SEC) and takes them as contacts.
    -- An offline name costs one whisper, its "no player named" line hidden (SyncAux).
    BOOK_MAX = 60, BOOK_DAYS = 3, BOOK_GREET_SEC = 20,
    -- 2.2.2: a player that greeted us and is not in our list (a client the game keeps out of
    -- the list) gets live news too, at most LEAF_FANS of them per fact; what it passes on is
    -- not taken further (its word is a stranger's).
    LEAF_FANS = 2,
    -- 2.2.2: the list read again (fetched anew) for a newcomer at most every REFETCH_SEC.
    REFETCH_SEC = 300,
    -- 2.2.2: a client without a list and without a book yet (a first session the game keeps out
    -- of the list) had nobody: it greets players of its own faction from this week's ranking
    -- instead, the LADDER_SEEDS with most kills (Overlord players, most of them often online),
    -- looked up again every LADDER_SEED_SEC. An offline one costs one whisper, hidden.
    -- One look reads LADDER_SEED_SCAN rows of the ranking from a random place (another one on
    -- every client: not all greeting the same players), never the whole ranking, never in combat.
    -- 2.3.0: the place is a cursor moved on by 0..LADDER_SEED_SKIP rows at every look (bounded:
    -- the ranking is no longer counted nor walked whole in one frame).
    LADDER_SEEDS = 40, LADDER_SEED_SEC = 300, LADDER_SEED_SCAN = 2000, LADDER_SEED_SKIP = 8000,
    -- 2.2.2: a client with nobody at all (no list, no book, no ranking yet, no guild mate or
    -- Battle.net friend heard: a first install the game keeps out of the list) greets players
    -- of its faction it meets, PvP on (target, mouseover, nameplates): the last WORLD_SEEN, met
    -- under WORLD_FRESH s ago, WORLD_MAX greetings a session at most. Only while no peer is
    -- heard directly: the unit events are registered then only (Tick), never otherwise.
    WORLD_SEEN = 12, WORLD_FRESH = 600, WORLD_MAX = 20,
}
addon.ChannelDirectory = dir
dir.names, dir.partners, dir.partnerCount, dir.failedMethods, dir.provenMethods = {}, {}, 0, {}, {}
dir.replies = { at = -1000, count = 0 }
dir.generation = 0
dir.stats = { reads = 0, fetches = 0, fetchFailed = 0, greeted = 0, answered = 0, silent = 0,
    greetedUs = 0, replies = 0, repliesCapped = 0, ladderTurns = 0, mapTurns = 0, full = 0, gapPulls = 0,
    worldGreeted = 0 }
dir.world = {}

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

-- (2.2.2: never right after a zone change, while the game swaps its own channels.)
function dir:CanFetch()
    return outside() and not inCombat() and not windowOpen()
        and (sync.ChannelZoneQuiet == nil or sync:ChannelZoneQuiet())
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
    if #names > 0 then self:Boot() end
    return true
end

-- Read the list, after asking the game for it when it holds none or an old one.
function dir:Refresh()
    local at = now()
    self.nextReadAt = at + self.RETRY_SEC
    if not self:CanFetch() then return false end
    self.refreshTried = true
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
    -- 2.2.2: the two channel selections are spaced from our joins and leaves like any channel
    -- operation (the next look comes NEXT_READ later).
    if sync.TakeChannelOp and not sync:TakeChannelOp() then
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
-- The address book (2.2.2)
-- ---------------------------------------------------------------------------

local function serverNow() return addon.ServerNow and addon.ServerNow() or time() end

-- This region's, this channel's and this faction's page of the book (nil before the saved
-- variables or without a faction).
function dir:Book(create)
    local db = _G.OverlordDB
    local faction = addon.PlayerFaction
    if type(db) ~= "table" or (faction ~= "Alliance" and faction ~= "Horde") then return nil end
    -- (The page's key, made once per faction: Known asks for it on every whisper.)
    local key = self.bookKeyFaction == faction and self.bookKey or nil
    if not key then
        local region = type(GetCurrentRegionName) == "function" and GetCurrentRegionName() or nil
        key = tostring(readable(region) and region or "?") .. "|" .. sync:GetChannelBaseName():lower() .. "|" .. faction
        self.bookKey, self.bookKeyFaction = key, faction
    end
    local books = db.directoryBook
    if type(books) ~= "table" then
        if not create then return nil end
        books = {}
        db.directoryBook = books
    end
    local page = books[key]
    if type(page) ~= "table" then
        if not create then return nil end
        page = {}
        books[key] = page
    end
    return page
end

-- A listed player that answered our greeting, or greeted us, first-hand by whisper.
-- 2.2.2: without a list, a player we greeted ourselves (book or ranking) that answered
-- (ours: our own pick, never somebody that whispered first).
function dir:Remember(name, ours)
    if type(name) ~= "string" or not (self:Lists(name) or (ours and self:ListLess())) then return false end
    local page = self:Book(true)
    if not page then return false end
    local lower, at = name:lower(), serverNow()
    local entry = page[lower]
    if type(entry) == "table" then
        entry.n, entry.t = name, at
        return true
    end
    local count, oldest, oldestKey = 0, math.huge, nil
    for key, row in pairs(page) do
        count = count + 1
        local t = type(row) == "table" and tonumber(row.t) or 0
        if t < oldest then oldest, oldestKey = t, key end
    end
    if count >= self.BOOK_MAX and oldestKey then page[oldestKey] = nil end
    page[lower] = { n = name, t = at }
    return true
end

-- The book's live names, newest first (old and malformed ones dropped).
function dir:BookNames()
    local page = self:Book(false)
    if not page then return {} end
    local at, limit, rows = serverNow(), self.BOOK_DAYS * 86400, {}
    for key, row in pairs(page) do
        local name = type(row) == "table" and row.n
        local t = type(row) == "table" and tonumber(row.t) or nil
        if type(name) ~= "string" or name:lower() ~= key or not t or at - t > limit or t > at + 3600 then
            page[key] = nil
        else
            rows[#rows + 1] = { name = name, t = t }
        end
    end
    table.sort(rows, function(a, b) if a.t ~= b.t then return a.t > b.t end return a.name < b.name end)
    local names = {}
    for i, row in ipairs(rows) do names[i] = row.name end
    return names
end

function dir:InBook(name)
    local page = type(name) == "string" and self:Book(false) or nil
    local row = page and page[name:lower()]
    return type(row) == "table" and tonumber(row.t) ~= nil and serverNow() - row.t <= self.BOOK_DAYS * 86400
end

-- 2.2.2: players of our faction in this week's ranking, most kills first (LADDER_SEEDS),
-- not us; looked up again every LADDER_SEED_SEC.
function dir:LadderSeeds()
    local at = now()
    if inCombat() then return self.seeds or {} end
    if self.seeds and at - (self.seedsAt or -1e9) < self.LADDER_SEED_SEC then return self.seeds end
    self.seedsAt = at
    local lb, faction = addon.Leaderboard, addon.PlayerFaction
    local kills = lb and lb.kills
    local info = lb and lb.playerInfo
    local seeds = {}
    self.seeds = seeds
    if type(kills) ~= "table" or type(info) ~= "table" or (faction ~= "Alliance" and faction ~= "Horde") then
        return seeds
    end
    -- The window: LADDER_SEED_SCAN rows from a random place (wrapping round), the LADDER_SEEDS
    -- with most kills kept in two small arrays (no table per row, no sort of the ranking).
    -- 2.3.0: the place is a cursor kept from one look to the next, moved on by a random
    -- 0..LADDER_SEED_SKIP rows first: a look walks LADDER_SEED_SKIP + LADDER_SEED_SCAN rows at
    -- most, the ranking is never counted nor walked whole (a frame spike on big rankings).
    if next(kills) == nil then return seeds end
    local key = self.seedCursor
    -- (A key gone from the ranking cannot be followed by next: start again from its top.)
    if key ~= nil and kills[key] == nil then key = nil end
    for _ = 1, math.random(0, self.LADDER_SEED_SKIP - 1) do key = next(kills, key) end
    local names, counts, size, minAt = {}, {}, 0, 1
    local limit, first = self.LADDER_SEEDS, nil
    for _ = 1, self.LADDER_SEED_SCAN do
        local name, count = next(kills, key)
        if name == nil then name, count = next(kills) end
        -- (Round the whole ranking already: a small one, each row once.)
        if name == first then break end
        first, key = first or name, name
        count = tonumber(count)
        if count and count > 0 and type(name) == "string" and (size < limit or count > counts[minAt]) then
            local row = info[name]
            if type(row) == "table" and row.faction == faction and name:find(" ", 1, true) then
                if size < limit then
                    size = size + 1
                    names[size], counts[size] = name, count
                else
                    names[minAt], counts[minAt] = name, count
                end
                if size == limit then
                    minAt = 1
                    for k = 2, size do if counts[k] < counts[minAt] then minAt = k end end
                end
            end
        end
    end
    self.seedCursor = key
    local me = tostring(sync:GetPlayerFullName() or ""):lower()
    for k = 1, size do
        local canon = names[k]:lower() ~= me and sync:CanonicalForeverName(names[k]) or nil
        if canon then seeds[#seeds + 1] = canon end
    end
    return seeds
end

-- 2.2.2: a player of our faction met in the world, PvP on (a unit event, only while isolated).
function dir:NoteSeen(unit)
    if not unit or type(UnitIsPlayer) ~= "function" or not UnitIsPlayer(unit) then return false end
    if UnitIsUnit and UnitIsUnit(unit, "player") then return false end
    local faction = UnitFactionGroup and UnitFactionGroup(unit)
    if not readable(faction) or faction ~= addon.PlayerFaction then return false end
    if UnitIsPVP and not UnitIsPVP(unit) then return false end
    local raw = addon.SafeGetUnitName and addon:SafeGetUnitName(unit, true)
    local name = readable(raw) and type(raw) == "string" and sync:CanonicalForeverName(raw) or nil
    if not name then return false end
    local world, at, lower = self.world, now(), name:lower()
    for i = #world, 1, -1 do
        if world[i].key == lower then table.remove(world, i) end
    end
    table.insert(world, 1, { name = name, key = lower, at = at })
    while #world > self.WORLD_SEEN do world[#world] = nil end
    return true
end

-- Nobody heard directly (guild, Battle.net, whisper) and no list: a player met may be greeted.
function dir:Isolated()
    local net = addon.Relay
    return net ~= nil and net.CountDirectPeers ~= nil and self:ListLess() and net:CountDirectPeers() == 0
        and self.stats.worldGreeted < self.WORLD_MAX
end

-- The unit events, registered only while isolated (no cost for everyone else).
function dir:WatchWorld(on)
    on = on == true
    if on == (self.worldWatched == true) then return end
    self.worldWatched = on
    local frame = self.worldFrame
    if not frame then
        if not on or type(CreateFrame) ~= "function" then return end
        frame = CreateFrame("Frame")
        frame:SetScript("OnEvent", function(_, event, unit)
            if event == "PLAYER_TARGET_CHANGED" then unit = "target"
            elseif event == "UPDATE_MOUSEOVER_UNIT" then unit = "mouseover" end
            pcall(dir.NoteSeen, dir, unit)
        end)
        self.worldFrame = frame
    end
    local method = on and frame.RegisterEvent or frame.UnregisterEvent
    if type(method) == "function" then
        for _, event in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED" }) do
            pcall(method, frame, event)
        end
    end
    if not on then self.world = {} end
end

-- No member list to go by: never read, the channel suspended for us, or its list not loaded.
function dir:ListLess()
    -- (Not while a fetch is on its way: its list may come within seconds.)
    return #self.names == 0 and self.refreshTried == true and not self.fetching
end

-- Known to us as a player of the list: read in it now or, without a list, kept in the book.
function dir:Known(name)
    if self:Lists(name) then return true end
    return self:ListLess() and self:InBook(name)
end

-- ---------------------------------------------------------------------------
-- Partners
-- ---------------------------------------------------------------------------

function dir:Forget(force)
    local at, net = now(), addon.Relay
    for key, row in pairs(self.partners) do
        local last = math.max(row.greetedAt or -1e9, row.heardAt or -1e9, row.presenceAt or -1e9,
            row.askedAt or -1e9, row.silentUntil or -1e9)
        -- 2.3.0: a contact the relay still reaches directly is live: its ranking rounds and the chain
        -- keep its route, only its presence is old (a player that greeted us first sends none again
        -- while it hears us). Forgotten, its whispered news was a stranger's and another player was
        -- greeted in its place. A full table still makes room (force).
        if (at - last > self.SILENT_SEC and not (row.chainAt and net and net:IsDirectPeer(row.name)))
            or (force and at - last > self.PRESENCE_SEC) then
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
    -- (2.2.2: nor one the game said is offline, NoteUnreachable: it kept its turns.)
    return net ~= nil and row.greetedAt ~= nil and not (row.unreachableUntil and row.unreachableUntil > now())
        and net:IsDirectPeer(row.name)
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

-- 2.3.0: our route to this player came from our channel (heard there, not by whisper since).
function dir:HeardOnChannelOnly(name)
    local net = addon.Relay
    local route = net and type(net.peers) == "table" and type(name) == "string" and net.peers[name:lower()] or nil
    return route ~= nil and route.transport == "CHANNEL"
end

-- A listed player we do not hear yet, not greeted lately, not left alone.
-- 2.2.2: a player that answered us before comes first (a known 2.2 client: no greeting lost on
-- a silent one); a guild mate never (the guild carries to it already); without a list, the
-- book's names, newest first.
function dir:PickNew()
    local net = addon.Relay
    if not net then return nil end
    local lane = addon.GuildLane
    local guildOn = lane ~= nil and lane.IsGuildMate ~= nil and lane.IsActive ~= nil and lane:IsActive()
    local at = now()
    local function free(name)
        local row = self.partners[name:lower()]
        -- (2.3.0: heard on our channel only, a player does not hear us: the directory runs while the
        -- channel does not carry what we send. Refused alone, or just after a refusal, the whole list
        -- was such a neighbour and nobody was greeted.)
        return not (net:IsPeer(name) and not self:HeardOnChannelOnly(name)) and not (guildOn and lane:IsGuildMate(name))
            and not (row and ((row.silentUntil or 0) > at or at - (row.presenceAt or -1e9) < self.PRESENCE_SEC))
    end
    if self:ListLess() then
        for _, name in ipairs(self:BookNames()) do
            if free(name) then return name end
        end
        -- 2.2.2: isolated, a player met lately (online a moment ago) before the ranking's.
        if self:Isolated() then
            for _, seen in ipairs(self.world) do
                if at - seen.at <= self.WORLD_FRESH and free(seen.name) then
                    seen.at = -1e9
                    self.stats.worldGreeted = self.stats.worldGreeted + 1
                    return seen.name
                end
            end
        end
        local seeds = self:LadderSeeds()
        local size = #seeds
        if size == 0 then return nil end
        local start = math.random(1, size)
        for step = 0, size - 1 do
            local name = seeds[(start + step - 1) % size + 1]
            if free(name) then return name end
        end
        return nil
    end
    local names = self.names
    local size = #names
    if size == 0 then return nil end
    for _, row in pairs(self.partners) do
        if row.heardAt and at - row.heardAt < self.SILENT_SEC and self:Lists(row.name) and free(row.name) then
            return row.name
        end
    end
    local start = math.random(1, size)
    for step = 0, math.min(size, 40) - 1 do
        local name = names[(start + step - 1) % size + 1]
        if free(name) then return name end
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
    -- (2.3.0: a route from our channel alone is no answer: a 2.2.1 client whose channel carries never answers.)
    if self:IsUsable(row) and not self:HeardOnChannelOnly(row.name) then
        -- It spoke (a client before 2.2.0 that pulled our map, for instance).
        row.heardAt = now()
        return
    end
    row.silences = (row.silences or 0) + 1
    row.silentUntil = now() + (row.silences > 1 and self.SILENT_SEC or self.FIRST_SILENT_SEC)
    self.stats.silent = self.stats.silent + 1
end

-- A presence addressed to us alone, by whisper from its own author (Relay:Receive): a player
-- that found us in the list, or the answer to our greeting. Answered once per PRESENCE_SEC.
-- session: its relay session. A new one (a /reload, a relog) knows nothing of the presence we
-- gave the old one: answered then even within PRESENCE_SEC, once per PRESENCE_SEC.
function dir:OnGreeting(origin, session)
    -- 2.2.2: answered even while our own channel carries: the greeter's may be refused (a
    -- channel that works for some players only made them islands). The rest stays as it was.
    if not self.started or not outside() or addon.RelayEnabled == false then return false end
    local row = partnerRow(origin, true)
    if not row then return false end
    local at = now()
    if type(session) == "string" and session ~= "" and row.session ~= session then
        if row.session and at - (row.renewedAt or -1e9) >= self.PRESENCE_SEC then
            row.presenceAt, row.renewedAt = nil, at
        end
        row.session = session
    end
    local hadAnswer = row.heardAt ~= nil
    local answersOurs = row.greetedAt ~= nil and not row.heardAt and at - row.greetedAt <= self.ANSWER_WAIT
    if answersOurs then
        self.stats.answered = self.stats.answered + 1
    elseif not row.heardAt or at - row.heardAt > self.PRESENCE_SEC then
        self.stats.greetedUs = self.stats.greetedUs + 1
    end
    row.heardAt, row.silentUntil, row.silences, row.unreachableUntil = at, nil, nil, nil
    -- 2.2.0 or later (only the list greets this way): a contact of the chain (ChainTargets), once
    -- the list we read names it. A newcomer to the list: read it again soon.
    row.chainAt = at
    -- 2.2.2: kept in the book for a session without the list. (A busy player's answer may wait
    -- for its next minute, REPLY_QUEUE: still the answer to our own greeting.)
    self:Remember(row.name, answersOurs or (row.greetedAt ~= nil and not hadAnswer
        and at - row.greetedAt <= self.ANSWER_WAIT + 62))
    -- (Never later than planned: no planned read yet is a read at once.)
    -- 2.3.0: once per greeter. A player the game keeps out of every list (a leaf) never shows in
    -- ours: its greetings and map-round presences had every listed client read its whole list
    -- every REREAD_SEC and fetch it every REFETCH_SEC, for nothing.
    if not self:Lists(origin) and not row.rereadAsked and at - (self.readAt or -1e9) >= self.REREAD_SEC
        and self.nextReadAt and self.nextReadAt > at + self.RETRY_SEC then
        row.rereadAsked = true
        self.nextReadAt = at + self.RETRY_SEC
        -- 2.2.2: fetched anew (the game may hold an old list), at most every REFETCH_SEC.
        if at - (self.refetchAt or -1e9) >= self.REFETCH_SEC then
            self.refetchAt, self.fetchAt = at, nil
        end
    end
    if at - (row.presenceAt or -1e9) < self.PRESENCE_SEC then return false end
    return self:Answer(row)
end

-- One answer to a greeting, within REPLIES_PER_MIN; past it, the answer waits for the next minute
-- (REPLY_QUEUE at most): dropped, the greeter took us for silent.
function dir:Answer(row)
    local at, replies = now(), self.replies
    if at - replies.at >= 60 then replies.at, replies.count = at, 0 end
    if replies.count >= self.REPLIES_PER_MIN then
        self.stats.repliesCapped = self.stats.repliesCapped + 1
        local queue = self.replyQueue or {}
        self.replyQueue = queue
        if #queue < self.REPLY_QUEUE and not row.queued then
            row.queued = true
            queue[#queue + 1] = row
            if not self.replyTimer then
                -- (Its own token: a timer from before a suspension (Suspend drops the queue)
                -- touches nothing of a later queue.)
                local token = {}
                self.replyTimer = token
                C_Timer.After(math.max(1, 60 - (at - replies.at) + 0.5), function()
                    if dir.replyTimer ~= token then return end
                    dir.replyTimer = nil
                    return dir:DrainReplies()
                end)
            end
        end
        return false
    end
    if not sendPresence(row) then return false end
    replies.count = replies.count + 1
    self.stats.replies = self.stats.replies + 1
    return true
end

function dir:DrainReplies()
    local queue = self.replyQueue
    self.replyQueue = nil
    if not queue then return end
    local at = now()
    for _, row in ipairs(queue) do
        row.queued = nil
        if outside() and self.partners[row.name:lower()] == row and at - (row.presenceAt or -1e9) >= self.PRESENCE_SEC then
            self:Answer(row)
        end
    end
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
-- Fight brackets (FK) leave or pass on only above FK_RESERVE tokens; those we pass on, FK_PER_MIN a
-- minute at most (our own front's are paced by Recent activity itself).
-- (Four a minute to five contacts at most: a busy evening tells many brackets. Five, not four: the
-- relay's four names allow three hands after the author, and 1 + 4 + 16 + 64 = 85 could never reach
-- a 93-player list without the channel; 1 + 5 + 25 + 125 does, with room for the random overlap.)
dir.FK_RESERVE, dir.FK_PER_MIN, dir.FK_FAN = 20, 4, 5
-- Guild rampages (GuildKillAlert GW): checked as GuildKillAlert shows them, one per guild and side
-- every GW_COVER_SEC, those we pass on GW_PER_MIN a minute (their own count, not the fights'),
-- the fights' fan and reserve.
dir.GW_PER_MIN, dir.GW_COVER_SEC = 2, 600
-- 2.5.0: the Commander's position (General GP, sent every 20 s while it moves, 40 s otherwise) is
-- passed along once per GP_COVER_SEC and Commander, whichever of its positions comes first after
-- that: about one a minute, enough to keep its icon on every map (General.ENTRY_STALE_CHAIN_SEC).
-- Never from the tokens kept for captures and sieges (the fights' reserve); those we pass on,
-- GP_PER_MIN a minute (two Commanders, one per faction, make two).
dir.GP_COVER_SEC, dir.GP_PER_MIN = 55, 4
-- Our own kill total (K) also goes to RAMPAGE_COLLECTORS guild mates (the same ones for the whole
-- guild: the lowest hash of guild and name among the mates reached directly), inside the K fan.
-- A rampage (GuildKillAlert) needs one client to hear five members of a guild; with the totals
-- thrown at random contacts none ever did. A guild of fewer than RAMPAGE_MIN_MATES other mates
-- online cannot make one; past RAMPAGE_LOAD mates only that many senders in all take part (a
-- collector hears RAMPAGE_LOAD totals per RANK_GAP at most).
dir.RAMPAGE_COLLECTORS, dir.RAMPAGE_MIN_MATES, dir.RAMPAGE_LOAD = 2, 4, 60
dir.MULTICAST_SPEAKERS, dir.CHAIN_FRAGMENTS = 2, 2
-- 2.5.0: bridges first. The other faction only has a fact from a player holding a Battle.net friend
-- of that faction (a bridge), and the relay stops at four names: a siege that reached a bridge
-- as the fourth name never crossed, and one that crossed as the third could go no further than
-- the friend (measured on 36 whole clients: one siege in two unseen by most of the other faction,
-- by the draw of the contacts alone). The author of a fact and the hand after it now whisper it
-- first to the contacts whose own presence says they are bridges, BRIDGE_FANS of them at most,
-- inside the same fan (no whisper more). Never for a kill total (it does not cross), nor for what
-- came over Battle.net (it has crossed already).
dir.BRIDGE_FANS, dir.BRIDGE_HANDS = 2, 2
-- How long a passed start is remembered for its release (the relay's TTL and a margin), and how
-- long a heard copy of a capture keeps our own report of it quiet (GuildLane: HEARD_COVER_SEC).
dir.START_MEMORY, dir.OWN_COVER_SEC = 300, 10
-- 2.4.0: from this hold time on (a capital's siege) a capture is told again while it runs
-- (chainShape); how many hands a start remembers for its release, over those tellings.
dir.BEAT_MIN_HOLD, dir.START_HANDS = 300, 16
dir.CHAIN_ROWS = 256
dir.chain = { tokens = dir.CHAIN_BURST, cover = {}, starts = {}, intake = {}, rows = 0,
    minute = { at = -1000, count = 0 } }
for _, key in ipairs({ "chainOwn", "chainForwarded", "chainWhispers", "chainCovered", "chainCapped",
    "chainNoContact", "chainLeft", "chainStranger", "chainRetold", "chainUnvouched", "chainRampage" }) do dir.stats[key] = 0 end

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
    -- 2.2.2: a fight's bracket (FrontActivity FK) is the dock's "Recent activity": without the
    -- channel it only went to Battle.net friends, so every panel showed its own fights. A bracket
    -- has no author in it, so the same one told by several fighters is one fact (cover), and it
    -- never spends the tokens kept for captures and sieges (FK_RESERVE, FK_PER_MIN).
    if kind == "FK" then return "fact" end
    if kind == "GW" then
        local gka = addon.GuildKillAlert
        return gka and gka.ChainCoverKey and gka:ChainCoverKey(payload) and "fact" or nil
    end
    if kind == "K" then return #p.path == 1 and "rank" or nil end
    -- 2.5.0: a Commander's position (its cover and pace: ChainTargets).
    if kind == "GP" then
        return payload:match("^[AH]:[^:]*:%-?%d+:%-?%d+:%d+:%d+:%d+:%d+$") and "fact" or nil
    end
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
    -- 2.4.0: defenders a capturer cannot see (ZoneDefense): one fact per wave and half a minute,
    -- whoever says it (GuildLane CoverKey), on its way back to the capturer's side.
    if kind == "ZD" then
        local wave, count = payload:match("^[^:]+:([%w_]+):[^:]+:(%d+)")
        return wave and #wave <= 48 and #count <= 2 and "fact" or nil
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
    -- 2.4.0: the siege of a capital (eight minutes) is told again along the way, once per
    -- SIEGE_COVER_SEC at most (the cover of its start): whoever logs in or reaches the front
    -- after its start saw nothing of it, and its release only follows a start told in the last
    -- START_MEMORY seconds. Any other capture is over before a second word would help.
    if status == "in_progress" and (tonumber(payload:match("^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%d+)")) or 0) >= dir.BEAT_MIN_HOLD then
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
    -- 2.2.2: no partner turns either, and the route forgotten (another one is greeted).
    row.unreachableUntil = now() + self.PRESENCE_SEC
    local net = addon.Relay
    if net and net.ForgetDirectRoute then net:ForgetDirectRoute(row.name) end
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
    return row ~= nil and row.chainAt ~= nil and net ~= nil and self:Known(row.name)
        and net:IsDirectPeer(row.name)
end

-- 2.2.2: players that greeted us and are not in our list (the game keeps them out of it: about a
-- third of the clients on the beta), reached directly now. The chain tells them live news as
-- leaves (LEAF_FANS); the PvP Groups' hands and pulls serve them the same way (GroupFinder).
function dir:LeafNames()
    local net, out, at = addon.Relay, {}, now()
    if not net or not net.IsDirectPeer then return out end
    for _, row in pairs(self.partners) do
        -- (2.3.0: however old its greeting: a leaf sends no presence again while it hears us; the
        -- direct route says it is there.)
        if row.chainAt and not (row.unreachableUntil and row.unreachableUntil > at)
            and not self:Known(row.name) and net:IsDirectPeer(row.name) then
            out[#out + 1] = row.name
        end
    end
    return out
end

function dir:IsLeaf(name)
    local net = addon.Relay
    local row = type(name) == "string" and self.partners[name:lower()] or nil
    return row ~= nil and row.chainAt ~= nil and net ~= nil
        and not (row.unreachableUntil and row.unreachableUntil > now())
        and not self:Known(row.name) and net:IsDirectPeer(row.name)
end

-- 2.3.0: a whispered copy that is a leaf's own fact (it made it and whispered it to us: the path is
-- that leaf, then us). A player out of every member list (about a third on the beta) starts a
-- siege alone: its contacts take it on as if from a contact, else it never goes further than
-- them. What a leaf passes on for somebody else stays a stranger's copy.
function dir:IsLeafOrigin(p)
    local path = type(p) == "table" and p.path
    return type(path) == "table" and #path == 2 and type(path[1]) == "string" and self:IsLeaf(path[1])
end

-- 2.2.2: a contact that passes a broadcast on is online and reached directly (SyncRelay Receive):
-- its own route is refreshed, so a quiet contact is no stranger to the next hand.
function dir:KeepsContactAlive(name)
    local row = type(name) == "string" and self.partners[name:lower()] or nil
    return row ~= nil and row.chainAt ~= nil and self:IsActive() and self:Known(row.name)
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
    -- (2.4.0: a wave of the other faction now stays past its clock: the few askers of before.)
    if current == remote and addon.CaptureLease and addon.CaptureLease.FollowedByClock
        and addon.CaptureLease:FollowedByClock(zone) then askers = self.GAP_ASKERS end
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
                -- (Rampages are covered GW_COVER_SEC; everything else 300 s, or the book overflows.)
                local limit = k:sub(1, 3) == "GW|" and math.max(300, dir.GW_COVER_SEC) or 300
                if at - row.at > limit then chain.cover[k] = nil else rows = rows + 1 end
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

-- The guild mates that hear our kill total for a rampage, or nil: the RAMPAGE_COLLECTORS lowest of
-- (hash of guild and name) among us and the mates reached directly (we drop ourselves).
function dir:RampageCollectors()
    local lane, net = addon.GuildLane, addon.Relay
    if not (lane and lane.peers and lane.PeerCount and net and net.IsDirectPeer and net.peers and net.HashFrac) then
        return nil
    end
    local mates = lane:PeerCount()
    if mates < self.RAMPAGE_MIN_MATES then return nil end
    if mates > self.RAMPAGE_LOAD and math.random() * mates >= self.RAMPAGE_LOAD then return nil end
    local guild = GetGuildInfo and GetGuildInfo("player")
    if not readable(guild) or type(guild) ~= "string" or guild == "" then return nil end
    local salt, at = guild:lower() .. "|", now()
    local me = tostring(sync:GetPlayerFullName() or ""):lower()
    local ranked = { { key = me, score = net.HashFrac(salt .. me), me = true } }
    for key in pairs(lane.peers) do
        local route, partner = net.peers[key], self.partners[key]
        if route and route.name and key ~= me and net:IsDirectPeer(route.name)
            and not (partner and partner.unreachableUntil and partner.unreachableUntil > at) then
            ranked[#ranked + 1] = { key = key, name = route.name, score = net.HashFrac(salt .. key) }
        end
    end
    table.sort(ranked, function(a, b) return a.score < b.score end)
    local out = {}
    for i = 1, math.min(self.RAMPAGE_COLLECTORS, #ranked) do
        if not ranked[i].me then out[#out + 1] = ranked[i].name end
    end
    return out[1] and out or nil
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
    if p.kind == "GW" then
        -- (Read once more here: its date may have just aged past the limit since chainShape.)
        key, window = addon.GuildKillAlert:ChainCoverKey(p.payload), self.GW_COVER_SEC
        if not key then return nil end
    end
    local beat = p.kind == "GP"
    if beat then
        local faction, claim = p.payload:match("^([AH]):[^:]*:%-?%d+:%-?%d+:%d+:(%d+):")
        key, window = "GP|" .. tostring(faction) .. "|" .. tostring(claim), self.GP_COVER_SEC
        -- Somebody else's Commander: passed on only for a claim dated about now or in the week
        -- (its date is the claimant's own clock: a claim dated far ahead would outrank every real
        -- one for good, and the chain would keep it on every map).
        if not own then
            local serverAt = addon.ServerNow and addon.ServerNow() or time()
            local claimed = tonumber(claim) or 0
            if claimed > serverAt + self.FACT_SKEW or claimed < serverAt - 8 * 86400 then
                stats.chainUnvouched = stats.chainUnvouched + 1
                return nil
            end
        end
    end
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
    -- 2.4.0: one timer per point. A group stepping on a point begins several waves in one
    -- second, one start is passed on and the others are covered by it, then all but the first
    -- give way in silence (CaptureLease YieldToElderWave). The release of the one that goes on
    -- follows the hands of the start we passed, whichever of them it was.
    if shape == "release" and not start and zone and addon.CaptureLease and addon.CaptureLease.SameStart then
        local prefix = zone .. "|"
        for other, row in pairs(chain.starts) do
            if other:sub(1, #prefix) == prefix and at - row.at <= self.START_MEMORY
                and addon.CaptureLease:SameStart(wave, other:sub(#prefix + 1)) then
                start, startKey = row, other
                break
            end
        end
    end
    if shape == "rank" then
        -- 2.2.2: told to the rest of our contacts once it stops moving (SettleStep).
        self:NoteOwnTotal(p.payload)
        -- A newer total taking the place of one still waiting in the relay queue (SyncRelay Send):
        -- the same whispers, nothing spent again.
        if p.chainRetake and chain.rankTargets and at - (chain.rankAt or -1e9) < self.RANK_GAP then
            local again = {}
            for _, name in ipairs(chain.rankTargets) do
                if net:IsDirectPeer(name) then again[#again + 1] = name end
            end
            chain.rankTargets = again
            self:SettleTold(again)
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
            -- Our own fight bracket told already: taken (FrontActivity must not send it again).
            if own and p.kind == "FK" then
                local took = self.ownFKTaken
                if not took or took.n >= 16 then took = { n = 0 }; self.ownFKTaken = took end
                if not took[p.payload] then took[p.payload], took.n = at, took.n + 1 end
            end
            return nil
        end
    end
    -- 2.3.0: a fight bracket passed on for others is one FrontActivity would take (a known front, a
    -- listed bracket, a slot of the activity window: IsLiveBracket); anything else is a modified
    -- client's and stops here (a bracket dated far ahead covered a front's real ones for the session).
    if not own and p.kind == "FK" and addon.FrontActivity and addon.FrontActivity.IsLiveBracket
        and not addon.FrontActivity:IsLiveBracket(p.payload) then
        stats.chainStranger = stats.chainStranger + 1
        return nil
    end
    -- 2.3.0: a fight bracket passed on for others that a fresher one known here covers (higher, or
    -- the same of a later slot, valid 90 s more: FrontActivity CoversRelayedBracket) is not passed
    -- on: a busy fight's lower and older brackets spent FK_PER_MIN, and the bracket that counts,
    -- coming last, was capped by them. Our own brackets are FrontActivity's (ReportCovers).
    if not own and p.kind == "FK" and addon.FrontActivity and addon.FrontActivity.CoversRelayedBracket
        and addon.FrontActivity:CoversRelayedBracket(p.payload) then
        stats.chainCovered = stats.chainCovered + 1
        return nil
    end
    local me = tostring(sync:GetPlayerFullName() or ""):lower()
    if not own then
        local heardOn, gateway = p.heardOn, p.path[#p.path - 1]
        if heardOn == "WHISPER" and not self:IsContact(gateway) and not self:IsLeafOrigin(p) then
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
        if p.kind == "C" or p.kind == "ZS" or p.kind == "ZR" or p.kind == "ZD" then
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
        -- (2.2.2: counted once a whisper leaves, below: a fact capped by the tokens or without a
        -- contact spent the minute's intake for nothing.)
        chain.pendingIntake = intake
    else
        chain.pendingIntake = nil
    end
    -- Our contacts, those already on the path left out. 2.2.2: guild mates are left out for what
    -- the guild lane carries (it reached them already); players that greeted us but are not in
    -- our list (kept out of it by the game) get the fact too, LEAF_FANS of them at most, as leaves.
    local onPath = {}
    for _, node in ipairs(p.path) do onPath[node:lower()] = true end
    local lane0 = addon.GuildLane
    -- (2.3.0: not for a whispered copy: the guild lane says it only within its small share, and
    -- may give it up; its guild mates stay in our fan.)
    local skipGuild = lane0 ~= nil and lane0.IsGuildMate ~= nil and lane0.IsActive ~= nil and lane0:IsActive()
        and p.heardOn ~= "WHISPER" and lane0.Level ~= nil and lane0:Level(p) ~= nil
        -- (2.5.1: nor for a rampage relayed to us: the lane may give it up too, and its guild mates
        -- had it from our fan in 2.5.0.)
        and not (p.kind == "GW" and #p.path > 1)
    local view, leaves = {}, {}
    local at0 = now()
    for lower, row in pairs(self.partners) do
        if row.chainAt and not onPath[lower] and net:IsDirectPeer(row.name)
            and not (row.unreachableUntil and row.unreachableUntil > at0)
            and not (skipGuild and lane0:IsGuildMate(row.name)) then
            if self:Known(row.name) then
                view[#view + 1] = row.name
            else
                leaves[#leaves + 1] = row.name
            end
        end
    end
    -- Names that must be among the targets, taken out of the random draw and counted in the fan:
    -- a release goes to the hands its start went to; our own total also to the rampage collectors.
    local forced = {}
    local function pinned(names)
        local want = {}
        for _, name in ipairs(names) do want[name:lower()] = true end
        local function split(list)
            local kept = {}
            for _, name in ipairs(list) do
                if want[name:lower()] then forced[#forced + 1] = name else kept[#kept + 1] = name end
            end
            return kept
        end
        view, leaves = split(view), split(leaves)
    end
    if shape == "release" and start and start.targets then
        pinned(start.targets)
    elseif shape == "rank" and own then
        local collectors = self:RampageCollectors()
        if collectors then
            for _, name in ipairs(collectors) do forced[#forced + 1] = name end
            local want = {}
            for _, name in ipairs(collectors) do want[name:lower()] = true end
            local function without(list)
                local kept = {}
                for _, name in ipairs(list) do if not want[name:lower()] then kept[#kept + 1] = name end end
                return kept
            end
            view, leaves = without(view), without(leaves)
        end
    end
    if shape ~= "rank" and shape ~= "release" and #p.path <= self.BRIDGE_HANDS and p.heardOn ~= "BNET"
        and net.IsKnownBridge then
        -- (Which of the bridges: drawn per fact, a hash of us, the fact and their name. Taken in
        -- the table's own order, every client pinned the same two for every fact.)
        -- (One pass keeping the lowest scores: no table per bridge, no sort.)
        local bridges, scores, salt = {}, {}, me .. "|" .. tostring(key) .. "|"
        local wantCount = self.BRIDGE_FANS
        for _, name in ipairs(view) do
            if net:IsKnownBridge(name) then
                local score = net.HashFrac and net.HashFrac(salt .. name:lower()) or math.random()
                local at = #bridges + 1
                while at > 1 and scores[at - 1] > score do at = at - 1 end
                if at <= wantCount then
                    table.insert(bridges, at, name)
                    table.insert(scores, at, score)
                    bridges[wantCount + 1], scores[wantCount + 1] = nil, nil
                end
            end
        end
        if bridges[1] then
            pinned(bridges)
            stats.chainBridged = (stats.chainBridged or 0) + #bridges
        end
    end
    local level = #p.path
    if level > 1 and enemyCapture(p) then level = math.max(1, level - 2) end
    local wanted = math.min(shape == "rank" and self.RANK_FAN or self:FanFor(level), #view + #forced)
    wanted = math.max(0, math.min(wanted - #forced, #view))
    local rampage = p.kind == "GW"
    local fight = p.kind == "FK" or rampage
    if fight then wanted = math.max(0, math.min(wanted, self.FK_FAN - #forced)) end
    -- Leaves after the contacts, never for our own first-hand total (its settle rotation, SettleNext,
    -- reaches leaves too: a K is credited from its owner only, whoever receives it).
    local leafCount = shape ~= "rank" and math.min(self.LEAF_FANS, #leaves) or 0
    for i = 1, leafCount do
        local j = math.random(i, #leaves)
        leaves[i], leaves[j] = leaves[j], leaves[i]
    end
    if #forced + wanted + leafCount == 0 then
        stats.chainNoContact = stats.chainNoContact + 1
        return nil
    end
    if beat and not own then
        local gp = chain.gpMinute
        if not gp or at - gp.at >= 60 then
            gp = { at = at, count = 0 }
            chain.gpMinute = gp
        end
        if gp.count >= self.GP_PER_MIN then
            stats.chainCapped = stats.chainCapped + 1
            return nil
        end
    end
    local granted
    local minuteKey = rampage and "gwMinute" or "fkMinute"
    if fight then
        local fk = chain[minuteKey]
        if not fk or at - fk.at >= 60 then
            fk = { at = at, count = 0 }
            chain[minuteKey] = fk
        end
        -- (The minute cap is for the fights we pass on: our own front's fight always leaves,
        -- paced by Recent activity itself; before, a busy evening's forwards silenced it.)
        if not own and fk.count >= (rampage and self.GW_PER_MIN or self.FK_PER_MIN) then
            stats.chainCapped = stats.chainCapped + 1
            return nil
        end
    end
    local reserve = (fight or beat) and self.FK_RESERVE or (not own and self.FORWARD_RESERVE) or nil
    local total = #forced + wanted + leafCount
    if not reserve then
        granted = takeTokens(total, fragmentCount)
    else
        takeTokens(0, 1)
        local spare = math.floor((chain.tokens - reserve) / math.max(1, tonumber(fragmentCount) or 1))
        granted = spare > 0 and takeTokens(math.min(total, spare), fragmentCount) or 0
    end
    if fight and not own and granted > 0 then chain[minuteKey].count = chain[minuteKey].count + 1 end
    if beat and not own and granted > 0 then chain.gpMinute.count = chain.gpMinute.count + 1 end
    if granted == 0 then
        chain.pendingIntake = nil
        stats.chainCapped = stats.chainCapped + 1
        return nil
    end
    if chain.pendingIntake then
        chain.minute.count, chain.pendingIntake.count = chain.minute.count + 1, chain.pendingIntake.count + 1
        chain.pendingIntake = nil
    end
    -- Contacts first, then the leaves with what is left.
    local fromForced = math.min(granted, #forced)
    local fromView = math.min(granted - fromForced, wanted)
    for i = 1, fromView do
        local j = math.random(i, #view)
        view[i], view[j] = view[j], view[i]
    end
    local targets = {}
    for i = 1, fromForced do targets[i] = forced[i] end
    for i = 1, fromView do targets[#targets + 1] = view[i] end
    for i = 1, math.min(granted - fromForced - fromView, leafCount) do targets[#targets + 1] = leaves[i] end
    if fromForced > 0 and shape == "rank" then stats.chainRampage = stats.chainRampage + fromForced end
    granted = #targets
    if shape == "rank" then
        chain.rankAt, chain.rankTargets = at, targets
        self:SettleTold(targets)
    elseif shape == "release" then
        chain.starts[startKey] = nil
        -- The point may be told again at once: a new wave is a new start.
        if start.cover then chain.cover[start.cover] = nil end
    else
        keep("cover", key, { at = at, date = date })
        -- Our own fight brackets the chain took (FrontActivity checks its report left).
        if own and p.kind == "FK" then
            local took = self.ownFKTaken
            if not took or took.n >= 16 then took = { n = 0 }; self.ownFKTaken = took end
            if not took[p.payload] then took[p.payload], took.n = at, took.n + 1 end
        end
    end
    if shape == "start" then
        -- 2.4.0: a siege told again keeps the hands of its earlier tellings for its release.
        local hands = targets
        if start and start.targets and at - start.at <= self.START_MEMORY then
            local known = {}
            hands = {}
            for _, name in ipairs(targets) do hands[#hands + 1] = name; known[name:lower()] = true end
            for _, name in ipairs(start.targets) do
                if #hands >= self.START_HANDS then break end
                if not known[name:lower()] then hands[#hands + 1] = name; known[name:lower()] = true end
            end
        end
        keep("starts", startKey, { at = at, cover = key, targets = hands })
    end
    if not own and p.kind == "FK" and addon.FrontActivity and addon.FrontActivity.NoteRelayedBracketPassed then
        addon.FrontActivity:NoteRelayedBracketPassed(p.payload)
    end
    if own then stats.chainOwn = stats.chainOwn + 1 else stats.chainForwarded = stats.chainForwarded + 1 end
    stats.chainWhispers = stats.chainWhispers + granted * math.max(1, tonumber(fragmentCount) or 1)
    return targets
end

-- ---------------------------------------------------------------------------
-- 2.2.2: our settled total, told to the rest of our contacts
-- ---------------------------------------------------------------------------
--
-- Our own total (K) leaves first-hand to RANK_FAN contacts; every other client of the list
-- waited for ranking rounds to bring it (minutes without the channel). Once our total stops
-- moving (SETTLE_QUIET), it goes, one whisper every SETTLE_GAP, to the next of our contacts and
-- leaves in a fixed order (a hash of our name and theirs: not the same few every time), each of
-- them once for that total, SETTLE_MAX at most, then nothing more until it moves again. Only
-- from spare tokens (above SETTLE_RESERVE, what captures and sieges keep). First-hand from its
-- owner, like any K (Sync:OnReceiveKill: the whisper names its author); nobody passes it on.
dir.SETTLE_QUIET, dir.SETTLE_JITTER, dir.SETTLE_GAP, dir.SETTLE_MAX, dir.SETTLE_RESERVE = 30, 10, 3, 24, 24
-- (Given up SETTLE_LIFE after the total last moved: a whole evening without spare tokens.)
dir.SETTLE_LIFE = 600
-- (A contact the relay refused our whisper to: tried again SETTLE_RETRY later, the others meanwhile.)
dir.SETTLE_RETRY = 60

-- Every own total ChainTargets sees (sent, held for the gap or capped).
function dir:NoteOwnTotal(payload)
    if type(payload) ~= "string" then return nil end
    local total = tonumber(payload:match("^[^:]*:[^:]*:(%d+)"))
    if not total then return nil end
    local chain, at = self.chain, now()
    local settle = chain.settle
    if settle and settle.total == total then
        settle.payload = payload
        return settle
    end
    settle = { total = total, payload = payload, changedAt = at, told = {}, sent = 0 }
    chain.settle = settle
    local generation = self.generation
    C_Timer.After(self.SETTLE_QUIET + math.random() * self.SETTLE_JITTER, function()
        if dir.generation == generation then dir:SettleStep(settle) end
    end)
    return settle
end

-- The contacts (or leaves) a total of ours already went to.
function dir:SettleTold(targets)
    local settle = self.chain.settle
    if not settle or type(targets) ~= "table" then return end
    for _, name in ipairs(targets) do settle.told[name:lower()] = true end
end

-- Not told this total yet, nor refused by the relay in the last SETTLE_RETRY.
function dir:SettleOpen(settle, lower, at)
    local retry = settle.refused and settle.refused[lower]
    return not settle.told[lower] and not (retry and retry > at)
end

-- The next one of the rotation not told this total yet, or nil.
function dir:SettleNext(settle)
    local net = addon.Relay
    if not net or not net.HashFrac then return nil end
    local me = tostring(sync:GetPlayerFullName() or ""):lower()
    -- (Guild mates included: the guild lane never carries a K.)
    local at, best, bestScore = now(), nil, nil
    for lower, row in pairs(self.partners) do
        if row.chainAt and self:SettleOpen(settle, lower, at) and self:PeerSettles(row.name) and net:IsDirectPeer(row.name)
            and not (row.unreachableUntil and row.unreachableUntil > at) then
            local score = net.HashFrac(me .. "|" .. lower)
            if not bestScore or score < bestScore then best, bestScore = row, score end
        end
    end
    -- 2.2.2: and the guild mates the relay reaches directly. Nobody greets a guild mate, so
    -- they were hardly ever contacts: past the two rampage collectors of the first fan, our
    -- guild only had our total from the ranking rounds, minutes later. Same rotation, same
    -- once-per-total, same SETTLE_MAX; a guild mate heard in the last hour only.
    -- (The guild lane keeps its mates by lower-case canonical name, as the relay its routes.)
    local lane = addon.GuildLane
    local memory = lane and tonumber(lane.PEER_MEMORY)
    if memory and type(lane.peers) == "table" and type(net.peers) == "table" then
        for lower, heardAt in pairs(lane.peers) do
            local route, row = net.peers[lower], self.partners[lower]
            local name = route and route.name
            if name and lower ~= me and self:SettleOpen(settle, lower, at) and at - (tonumber(heardAt) or -1e9) < memory
                and not (row and (row.chainAt or (row.unreachableUntil and row.unreachableUntil > at)))
                and net:IsDirectPeer(name) and self:PeerSettles(name) then
                local score = net.HashFrac(me .. "|" .. lower)
                if not bestScore or score < bestScore then best, bestScore = { name = name }, score end
            end
        end
    end
    return best
end

-- Only peers announcing 2.2.2 or later get a settled total: they know it is no kill made now
-- (an earlier release counted it in its fights and rampages).
function dir:PeerSettles(name)
    local net = addon.Relay
    local release = net and net.GetPeerReleaseWithin and net:GetPeerReleaseWithin(name, 3 * 3600)
    local x, y, z = tostring(release or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not x then return false end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x ~= 2 then return x > 2 end
    if y ~= 2 then return y > 2 end
    return z >= 2
end

function dir:SettleStep(settle)
    local chain = self.chain
    if chain.settle ~= settle or settle.sent >= self.SETTLE_MAX
        or now() - settle.changedAt > self.SETTLE_LIFE then return false end
    local at = now()
    local generation = self.generation
    local function again(delay)
        C_Timer.After(delay, function()
            if dir.generation == generation then dir:SettleStep(settle) end
        end)
    end
    -- (Directory idle for now, channel seated again or relay off: nothing sent, still ours to
    -- tell if it comes back before SETTLE_LIFE. An instance ends this timer: Suspend, Resume.)
    if not self:IsActive() then again(30); return false end
    -- (Moved meanwhile with the same total: wait for the quiet again.)
    if at - settle.changedAt < self.SETTLE_QUIET then
        again(self.SETTLE_QUIET - (at - settle.changedAt) + 1)
        return false
    end
    -- In a fight: later (the whispers are the fight's).
    if inCombat() then again(10); return false end
    local row = self:SettleNext(settle)
    -- (Nobody left for now: a contact met later may still want it, until SETTLE_LIFE.)
    if not row then again(30); return false end
    takeTokens(0, 1)
    if chain.tokens - 1 < self.SETTLE_RESERVE then
        again(self.SETTLE_GAP * 3)
        return false
    end
    local net, lower = addon.Relay, row.name:lower()
    if net:Send("K", settle.payload, row.name) then
        settle.told[lower] = true
        takeTokens(1, 1)
        settle.sent = settle.sent + 1
        self.stats.chainSettled = (self.stats.chainSettled or 0) + 1
        self.stats.chainWhispers = self.stats.chainWhispers + 1
    else
        -- (Refused here, nothing left: not lost for this total, tried again SETTLE_RETRY later.)
        settle.refused = settle.refused or {}
        settle.refused[lower] = at + self.SETTLE_RETRY
    end
    again(self.SETTLE_GAP + math.random() * self.SETTLE_GAP)
    return true
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
        self:WatchWorld(false)
        -- 2.3.0: idle (the channel carries) after a refused spell. Should it be refused again, see
        -- below. (Not before the first refusal: the login's own list boots as before.)
        -- Only when the channel itself carries: an instance or a pause keeps the partners.
        local lane = addon.GuildLane
        if self.activeSeen and outside() and lane ~= nil and not lane:ChannelDown() then
            self.wasIdle = true
        end
        return
    end
    self.activeSeen = true
    -- 2.3.0: refused again after carrying: the first greetings come together as after a login
    -- (Boot), not one a minute from nothing (the partners of before went silent or were forgotten).
    if self.wasIdle then
        self.wasIdle, self.booted = nil, nil
        if #self.names > 0 then self:Boot() end
    end
    self:WatchWorld(self:Isolated())
    local at = now()
    if not self.fetching and at >= (self.nextReadAt or 0) then self:Refresh() end
    -- 2.2.2: without a list, the book's players are greeted, one every BOOK_GREET_SEC.
    local listLess = self:ListLess()
    if (#self.names > 0 or listLess) and at >= (self.nextGreetAt or 0) then
        local greeted = self:GreetOne()
        self.nextGreetAt = not greeted and at + self.TICK_SEC
            or listLess and at + self.BOOK_GREET_SEC
            or at + self.GREET_SEC + math.random(0, self.GREET_JITTER)
    end
    if at - (self.forgottenAt or 0) >= 300 then
        self.forgottenAt = at
        self:Forget()
    end
end

-- Contacts in the chain's view now (ChainTargets' rule, leaves left out).
function dir:ContactCount()
    local count = 0
    for _, row in pairs(self.partners) do
        if row.chainAt and self:IsContact(row.name) then count = count + 1 end
    end
    return count
end

-- One greeting while fewer than MAX_PARTNERS answer us, or (2.2.2) fewer than MIN_CONTACTS are
-- contacts of the chain.
function dir:GreetOne()
    if self:LiveCount() >= self.MAX_PARTNERS and (self:ListLess() or self:ContactCount() >= self.MIN_CONTACTS) then
        return false
    end
    local name = self:PickNew()
    return name ~= nil and self:Greet(name)
end

-- 2.2.2: the first list of the session: BOOT_GREETS greetings BOOT_GAP apart, not one a minute
-- (a fresh login waited ten minutes for its partners and was out of the chain meanwhile).
function dir:Boot()
    if self.booted then return end
    self.booted = true
    local generation = self.generation
    for i = 1, self.BOOT_GREETS do
        C_Timer.After(i * self.BOOT_GAP + math.random() * 2, function()
            if dir.generation == generation and dir:IsActive() and not inCombat() then dir:GreetOne() end
        end)
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
    self.suspendedAt = now()
    self:WatchWorld(false)
    self.fetching = nil
    -- (2.2.2: answers waiting dropped, and their timer with them: a later queue arms its own.)
    for _, row in ipairs(self.replyQueue or {}) do row.queued = nil end
    self.replyQueue, self.replyTimer = nil, nil
    -- (2.3.0: a total still settling is told after the instance, see Resume; one already given
    -- up, SETTLE_LIFE past or SETTLE_MAX told, stays given up.)
    local settle = self.chain and self.chain.settle
    self.settlePaused = settle and settle.sent < self.SETTLE_MAX
        and now() - settle.changedAt <= self.SETTLE_LIFE and settle or nil
end

function dir:Resume()
    self.generation = self.generation + 1
    -- 2.3.0: an instance longer than the relay keeps a route (300 s, Relay:GetPeerHops): nothing
    -- refreshed them inside, every partner and contact is a stranger again and the chain's view is
    -- empty, as after a login. The next Tick boots (BOOT_GREETS greetings together) instead of one
    -- greeting a minute; a short instance keeps its partners and boots nothing.
    if self.suspendedAt and now() - self.suspendedAt > 300 then self.wasIdle = true end
    self.suspendedAt = nil
    if self.started then self:Arm(self.TICK_SEC * (1 + math.random())) end
    -- (A total settling when the instance began: its timer died with the generation.)
    local settle, paused = self.chain and self.chain.settle, self.settlePaused
    self.settlePaused = nil
    if settle and settle == paused and settle.sent < self.SETTLE_MAX then
        settle.changedAt = now()
        local generation = self.generation
        C_Timer.After(self.SETTLE_QUIET + math.random() * self.SETTLE_JITTER, function()
            if dir.generation == generation then dir:SettleStep(settle) end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Reports (/ov network, panel)
-- ---------------------------------------------------------------------------

-- One phrase for the panel's "Channel and guild" line, nil while the directory has nothing,
-- and how many players of the list exchange with us.
function dir:Describe()
    if not self:IsActive() then return nil, 0 end
    if #self.names == 0 then
        -- 2.2.2: without the list, players of the address book may still exchange with us.
        local listLess = self:ListLess()
        local live = listLess and self:AnsweringCount() or 0
        local state = "channel member list: " .. (self.state or "not read yet")
        if live > 0 then
            state = string.format("%s, %d players found without it exchanging with you", state, live)
        end
        return state, live, listLess
    end
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
        .. self:BookDiagnostics()
end

-- 2.2.2: the address book, the contacts and leaves of the chain, the answers waiting.
function dir:BookDiagnostics()
    local book, at = 0, now()
    for _ in pairs(self:Book(false) or {}) do book = book + 1 end
    local leaves = 0
    for _, row in pairs(self.partners) do
        if row.chainAt and self:IsLeaf(row.name) then leaves = leaves + 1 end
    end
    return string.format("; address book: %d players%s; %d players met in the world greeted%s; "
        .. "%d contacts, %d leaves; %d answers waiting",
        book, self:ListLess() and " (greeted without the list)" or "", self.stats.worldGreeted,
        self.worldWatched and " (looking: nobody heard)" or "", self:ContactCount(), leaves,
        #(self.replyQueue or {}))
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["SyncDirectory.lua"] = function() return { addon = addon, sync = sync, dir = dir, FIXED_FACTS = FIXED_FACTS } end
