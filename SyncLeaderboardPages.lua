-- Targeted, resumable anti-entropy: v5 covers 5,000 kills; v6 also pages
-- 500 capture rows per faction and race metadata for attested contributors;
-- v7 (1.7.0) is v6 with the race at the end of each sent kill row.
-- Since 1.7.5 peers before v7 are not asked (clients before 1.7.0 are left out,
-- update required); responders still answer v5/v6 requests from old clients.
-- v8 (1.8.0) sends only the rows that differ: one fingerprint per bucket, then one
-- per row of a differing bucket, then the rows asked for (see the v8 block below).
-- Capability 9 (1.8.1) is v8 between clients that know the Skyborne race. A 1.8.0
-- client (capability 8) does not hold it: its race stream never matched ours, so
-- every round resent the same race rows both ways. 1.8.1 neither asked nor served
-- such a client at all, and kills and captures stopped crossing between the two
-- versions (rankings apart for as long as both were online; keep and outpost
-- captures of players unknown to the other side refused). 1.8.2: with capability 8
-- the sweep carries kills and captures, which do match, and leaves the races out.
-- Below 8 (before 1.8.0) a peer is neither asked nor served (update required).
local Overlord = _G.Overlord
if not Overlord or not Overlord.Sync then return end
local sync, lb = Overlord.Sync, Overlord.Leaderboard
local PAGED_PROTOCOL, ASK_PROTOCOL = 9, 8
sync.PAGED_PROTOCOL, sync.PAGED_ASK_PROTOCOL = PAGED_PROTOCOL, ASK_PROTOCOL
local BUCKETS, PAGE_ROWS, CHUNK, MAX_PARTS = 64, 16, 170, 24
local STREAMS = { "LK", "LC", "LR" }
-- 2.5.2: killing blows ("LB", rows "Name:count", KillingBlows) come after the races in a sweep,
-- only between two clients whose presence says capability 11 ("~lb"); the requester says so in
-- its nonce ("b" before its serial), and only then does the fingerprint of the whole ranking
-- (profileFp) count them. Every profile holds the stream (empty in a view of 5,000).
local PROFILE_STREAMS = { "LK", "LC", "LR", "LB" }
-- A sweep carries them once every KB_SWEEP_SEC at most, whoever the peer (the feed carries the
-- moves meanwhile): a sweep without them is a 2.5.1 sweep, its fingerprint and its length too.
-- The column settles later than the kills (the feed first, a sweep within half an hour for what
-- it missed), the rounds keep their pace: a sweep lists every bucket of LB that differs, and a
-- row a peer refuses (above its honorable kills, a banned name) is listed again at each one.
local KB_SWEEP_SEC = 1800
local kbSweepAt
local function carriesKB(peer)
    local blows = Overlord.KillingBlows
    return blows ~= nil and blows.PeerCarries ~= nil and blows:PeerCarries(peer) == true
end
-- A row of the stream, taken by KillingBlows' own acceptance (a page row and a feed row alike).
function sync._ReceiveKillingBlowRow(_, payload, sender)
    local blows = Overlord.KillingBlows
    if not blows or not blows.MergeRow then return false end
    return blows:MergeRow(payload, sender)
end
-- 2.4.0: the ranking holds 10,000 kill rows (it held 5,000). Two clients that both say so in
-- their presence ("~la", capability FULL_PROTOCOL) compare and exchange all of them. A client
-- before that holds, compares and serves its best 5,000: with it, in both directions, we use
-- the same view of ours (LegacyView: our best 5,000 kill rows, every capture row, the race rows
-- of those players, what its own copy would hold of our data), so the fingerprints of two equal
-- rankings still match and nothing is pulled again round after round. Which view a pull is
-- about is said by the requester in its nonce ("w" for the whole ranking, "n" as before) and
-- never guessed by the responder. The numbers a peer sends are bounded by the larger limits.
local STREAM_LIMITS = { LK = 10000, LC = 1500, LR = 11500, LB = 10000 }
local LEGACY_LIMITS = { LK = 5000, LC = 1500, LR = 6500, LB = 10000 }
local FULL_PROTOCOL = 10
sync.PAGED_FULL_PROTOCOL = FULL_PROTOCOL
local MOD, RATE, BURST = 2147483647, 300, 500
local pull, serving, outbound, wake, building
-- Fair share (1.4.2): a Battle.net friend of the other faction is the only source
-- of our ranking for its requesters, while requesters of its own faction have many
-- neighbours. An enemy-faction requester therefore takes over a same-faction
-- session once it is this old (the few bridges were held for a whole sweep while
-- the other faction only got "busy"). Same-faction requesters never preempt each
-- other: slicing every contended responder slowed convergence down.
local SESSION_SHARE_SEC = 120
local function IsOtherFaction(name)
    local mine = Overlord.PlayerFaction
    local theirs = sync.GetBetaPeerFaction and sync:GetBetaPeerFaction(name)
    return (mine == "Alliance" or mine == "Horde") and (theirs == "Alliance" or theirs == "Horde")
        and theirs ~= mine
end
-- At least one direct neighbour that is not of the other faction (allies are the
-- source of our own faction's rows when a pull from an enemy friend skips them).
-- Only one the ranking rotation may ask: an ally too old to be asked (see
-- ASK_PROTOCOL) is no source, and the enemy friend's pull stays unfiltered.
local function HasDirectAlly(except)
    local net = Overlord.Relay
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    for _, name in ipairs(net and net.GetDirectPeers and net:GetDirectPeers() or {}) do
        local capability = net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(name)
        if name ~= except and name ~= me and not IsOtherFaction(name)
            and not (capability and capability < ASK_PROTOCOL) then return true end
    end
    return false
end
local profiles = setmetatable({}, { __mode = "k" })
-- (2.4.0: the view of 5,000 of an attested copy, and its profile; both only exist for a copy
-- holding more kill rows than that.)
local legacyViews = setmetatable({}, { __mode = "k" })
local legacyProfiles = setmetatable({}, { __mode = "k" })
local function LegacyView(snapshot)
    local order = type(snapshot) == "table" and snapshot.killOrder or nil
    if type(order) ~= "table" or #order <= LEGACY_LIMITS.LK then return snapshot end
    local view = legacyViews[snapshot]
    if view then return view end
    local kills, info, top = {}, {}, {}
    local allKills, allInfo = snapshot.kills or {}, snapshot.playerInfo or {}
    for i = 1, LEGACY_LIMITS.LK do
        local name = order[i]
        top[i], kills[name], info[name] = name, allKills[name], allInfo[name]
    end
    for name in pairs(snapshot.captureCount or {}) do
        if info[name] == nil then info[name] = allInfo[name] end
    end
    -- Every other field (captures, dates) is the copy's own, read through a weak link: Lua 5.1
    -- never frees a weak key that its own value holds, and a view holding its copy kept every
    -- copy ever attested (and the profiles and wire rows cached under it) for the session.
    local back = setmetatable({ snapshot }, { __mode = "v" })
    view = setmetatable({ kills = kills, playerInfo = info, killOrder = top }, { __index = function(_, field)
        local copy = back[1]
        return copy and copy[field]
    end })
    legacyViews[snapshot] = view
    return view
end
sync._LegacyLadderView = LegacyView
-- Does this peer hold the whole ranking (its own presence said so in the last five minutes)?
local function HoldsFullLadder(peer)
    local net = Overlord.Relay
    local capability = net and net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(peer)
    return capability ~= nil and capability >= FULL_PROTOCOL
end
local unsupported, unsupportedOrder = {}, {}
local serial, tokens, refillAt = 0, BURST, 0
local stats = { pages = 0, rows = 0, rejected = 0, deferred = 0, retries = 0, bytes = 0 }
sync._leaderboardPageStats = stats
-- 2.5.0: the feed (its block is further down, "The feed"). Declared here: the profile reuse and
-- the pull's own steps read it.
local feed = {
    -- Asked for and served only between clients from MIN_RELEASE on (their own presence says so).
    MIN_RELEASE = { 2, 5, 0 }, RELEASE_AGE = 3 * 3600,
    -- A responder keeps SUBS_MAX subscribers, each SUB_TTL after its last pull or keep-alive. A
    -- requester takes the feed of a peer it asked in the last SOURCE_TTL (the peer has that long to
    -- say its first word) or that feeds it now, and counts a peer as feeding it for LIVE_SEC after
    -- its last word. Every KEEP_SEC it tells each of them it is still there ("HR 8:K"), and the
    -- source answers with a feed message, rows or none: a source only reaches a subscriber the
    -- relay heard in the last five minutes, and the feed alone goes one way. Without that word a
    -- subscription died five minutes after its pull while the subscriber went on counting on it
    -- and resting its rounds. A source silent for LIVE_SEC counts no more, and the rounds take
    -- their usual pace back.
    SUBS_MAX = 8, SUB_TTL = 900, SOURCE_TTL = 600, LIVE_SEC = 420, KEEP_SEC = 200,
    -- Rows read from one source in a minute (a source sends PER_MIN messages at most).
    ROWS_PER_MIN = 240,
    -- Players new to our ranking taken from the feed in an hour: NEW_PER_SOURCE from one source,
    -- NEW_PER_HOUR in all. Past it such a row is left to the pulls, whose acceptance is unchanged
    -- (the same ranking in the end, by the slower way): a source stays one for as long as it
    -- speaks, and what it brings is passed on within seconds.
    NEW_PER_SOURCE = 200, NEW_PER_HOUR = 600,
    -- The feed's own byte bucket (the pages keep theirs: a busy feed must not slow the answers
    -- served to the pulls, those of older clients first).
    RATE = 150, BURST = 450,
    -- A requester asks for the feed of SOURCES_MAX peers at most (those feeding it stay asked):
    -- every further source brings the same rows once more.
    SOURCES_MAX = 4,
    -- One message per subscriber every GAP at most, LINGER after the first row waiting (a few
    -- rows travel together), PER_MIN for the whole client; BLOB bytes and ROWS_MAX rows per
    -- message, PENDING_MAX rows waiting per subscriber.
    -- (PER_MIN 24 and RATE 150 are measured: on 310 whole clients with 119 of them killing, 18 and
    -- 110 gave the same busiest tenth, 59 whispers a minute, a higher median, 42 against 38, the
    -- pulls making up for the feed, and the same ranking 90 s later.)
    -- BLOB: the rows of a message that does not go through the relay (one whisper). Through it a
    -- message fills up to PIECES whispers, the last one FILL full at least (feedSend), and is read
    -- up to MESSAGE_MAX bytes.
    GAP = 8, LINGER = 2, PER_MIN = 24, BLOB = 228, ROWS_MAX = 24, PENDING_MAX = 96,
    PIECES = 3, FILL = 0.5, MESSAGE_MAX = 600,
    -- The fresh fight brackets of "Recent activity" (FrontActivity FK) travel in the feed's
    -- messages too, FIGHT_ROWS a message at most, FIGHT_ROOM bytes kept for them while one waits.
    -- On the whisper chain alone a bracket missed one or two clients in most fights (36 whole
    -- clients, three worlds: a panel one bracket behind for 6 to 9 minutes, another chat line).
    FIGHT_ROWS = 4, FIGHT_ROOM = 60,
    -- They also go up: a client tells the peers that feed it the brackets they have not told it
    -- ("HR 8:W:<epoch>:<bracket>,<bracket>...": W, a letter no step of a pull bears), FIGHT_UP_LINGER after it learnt one, a message
    -- per source every GAP at most. Down alone, a bracket entering by a client few others ask
    -- (a Battle.net friend of the other side, a player out of the member list) stopped at its
    -- one or two subscribers: 19 to 22 of 24 players of a faction a bracket behind for minutes
    -- (304 whole clients, two bridges).
    FIGHT_UP_LINGER = 3,
    -- The zone of a fight. When the channel carried, every client heard every kill total with
    -- its zone and counted the size of a fight by itself ("Recent activity"); without it a total
    -- only reaches its author's guild, group and a few contacts, and the best-informed client
    -- counted about half the kills (36 whole clients, a battle of several guilds). The feed
    -- carries every total to everybody: a kill row now says where its last kills were made, as
    -- a marker row "z<@front|#uiMapID>" in front of the rows of that zone (one marker per zone
    -- and message, about ten bytes), for ZONE_SEC after the kills. PARSE_MAX: rows read in one
    -- message (ROWS_MAX rows, their markers, FIGHT_ROWS brackets).
    -- (ZONE_SEC 180: in the biggest fights a row waits its turn; at 90 the last row of a player
    -- who had stopped left without its zone, and those kills were counted nowhere.)
    ZONE_SEC = 180, ZONE_REF_MAX = 24, PARSE_MAX = 48,
    -- The last RING rows that moved, kept RING_SEC (a profile served to a new subscriber may be
    -- that old); identities born lately (FRESH_MAX of them) travel as whole rows.
    RING = 256, RING_SEC = 130, FRESH_MAX = 1024,
    STOP_GAP = 300, INBOX_MAX = 256, WAIT_MAX = 20,
    -- A capture count leaves CAPTURE_LINGER after it moved, never sooner. A capture is counted by
    -- its event (C) on the clients that witness it and by a row everywhere else: a witness that
    -- took our row (the count with that capture in it) before the event would count it twice,
    -- for good (totals only go up). The event is whispered within a second and lives two minutes
    -- at most in a relay; the row waits most of that.
    -- (125 s: past the two minutes an event lives in a relay, so that no witness can take the row
    -- and then the event.)
    CAPTURE_LINGER = 125, CAPTURE_PENDING = 64,
    -- The rows a pull of ours brings are passed on to our subscribers while that pull has changed
    -- at most PULL_PASS rows of our ranking (a few rows the feed missed). Past it the pull is a
    -- catch-up (a login, an evening away: thousands of rows everybody else holds): passed on, they
    -- filled every subscriber's queue with old rows and the fresh ones were dropped behind them
    -- (bench, 5,000-row rankings: two rows in three sent were already held).
    PULL_PASS = 24, BULK_PER_FRAME = 48,
    subs = {}, subCount = 0, sources = {}, enemy = {}, asked = {}, askedCount = 0, stops = {}, stopCount = 0,
    sourceFights = {}, sourceFightAt = {}, zones = {}, zoneAt = {}, zoneCount = 0,
    pinged = {}, intake = {}, tokens = 450, refillAt = 0, newcomers = { at = -1e9, total = 0, by = {} },
    ring = {}, ringAt = 0, fresh = {}, freshCount = 0, inbox = {}, inboxHead = 1, inboxTail = 0,
    minute = { at = -1000, count = 0 },
    scratch = { kills = {}, captureCount = {}, captures = {}, playerInfo = {} },
}
sync._leaderboardFeed = feed
-- Rows that changed our ranking since login, by pages and by the feed. (Killing blows apart: a
-- profile of ours with their stream up to PROFILE_REUSE_SEC old is fine, they are swept every
-- KB_SWEEP_SEC; counting them rebuilt it after every row "b" of the feed.)
local function movedRows() return (stats.changedRows or 0) + (stats.feedChanged or 0) end

local function epoch()
    return math.floor(tonumber(Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs()) or 0)
end
-- blocked: instance, nothing at all (every Overlord feature stops there).
-- paused: also combat, for the heavy work (building a profile, applying rows).
-- 1.7: a page already built still leaves in combat (sending it costs almost
-- nothing and stays within the byte budget). In PvP everyone is in combat all
-- the time, and a responder that went busy at every fight cut every sweep.
local function blocked()
    return Overlord.InstanceSuspended or (IsInInstance and IsInInstance())
end
local function inCombat() return InCombatLockdown and InCombatLockdown() or false end
local function paused()
    return blocked() or inCombat()
end
-- A requester told "busy: combat" waits for the same peer instead of moving on:
-- 30-45 s per wait (spread, so the requesters of one popular peer do not ask together).
local COMBAT_WAIT_SEC, COMBAT_WAIT_JITTER, COMBAT_WAIT_MAX = 30, 15, 5
-- Same fold as byte by byte (wire-compatible), read 8 bytes per call: a 4 KB
-- page hashed in one frame on both sides cost ~1 ms with one call per byte.
-- (foldRange: the same fold over bytes i..n of value, from h.)
local function foldRange(value, h, i, n)
    while i + 7 <= n do
        local b1, b2, b3, b4, b5, b6, b7, b8 = value:byte(i, i + 7)
        h = (h * 31 + b1) % MOD; h = (h * 31 + b2) % MOD
        h = (h * 31 + b3) % MOD; h = (h * 31 + b4) % MOD
        h = (h * 31 + b5) % MOD; h = (h * 31 + b6) % MOD
        h = (h * 31 + b7) % MOD; h = (h * 31 + b8) % MOD
        i = i + 8
    end
    for j = i, n do h = (h * 31 + value:byte(j)) % MOD end
    return h
end
local function hash(value) return foldRange(value, 0, 1, #value) end
local function key(name)
    local result = sync:GetCaptureContributorDedupKey(name)
    return result and result:lower()
end
local function integer(value, lo, hi)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= lo and n <= hi and n or nil
end
local function validCursor(value)
    return value == "-" or (type(value) == "string" and #value > 0 and #value <= 100
        and not value:find("[:|%c]"))
end
local function allowed(sender, channel)
    if not sync:IsValidPlayerName(sender) then return false end
    if sync.KillAntiSpoofIsBlacklisted and sync:KillAntiSpoofIsBlacklisted(sender) then return false end
    local net = Overlord.Relay
    if channel == "BETA" then
        -- Point to point (1.2.4): an exchange that crossed a relay is ignored,
        -- since its pages would have to cross the same relays back.
        local context = net and net.context
        return net and net:IsDispatching(sender) and net:IsTargetedDispatch()
            and (tonumber(context and context.hops) or 0) == 0
    end
    return channel == "WHISPER" and (
        (sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender))
        or (sync.IsKnownRelayPeer and sync:IsKnownRelayPeer(sender)))
end

-- A single producer queue, paced in estimated wire bytes, also respects live
-- traffic in the relay. No broadcast, no per-peer multiplication of this budget.
local function enqueue(job)
    if outbound then return false end
    outbound = job
    job.at, job.index = GetTime(), 1
    -- 2.0, /ov network only: the answers this client owes its requesters (queued, fully
    -- sent, given up after 240 s, cancelled) and the sends its relay refused.
    stats.repliesQueued = (stats.repliesQueued or 0) + 1
    local function pump()
        wake = nil
        if outbound ~= job then
            -- A preempted job hands the wake-up chain to its successor, which
            -- was queued while this timer was pending and so never armed its own.
            if outbound and outbound.pump and not wake then
                wake = true
                C_Timer.After(0.01, outbound.pump)
            end
            return
        end
        if job.epoch ~= epoch() or (job.valid and not job.valid()) then
            stats.repliesCancelled = (stats.repliesCancelled or 0) + 1
            outbound = nil; return
        end
        if blocked() then job.at = GetTime(); wake = true; C_Timer.After(2, pump); return end
        if GetTime() - job.at > 240 then
            stats.repliesExpired = (stats.repliesExpired or 0) + 1
            outbound = nil; return
        end
        local packet = job.packets[job.index]
        if not packet then outbound = nil; if job.done then job.done() end; return end
        local now, net = GetTime(), Overlord.Relay
        tokens = math.min(BURST, tokens + math.max(0, now - refillAt) * RATE)
        refillAt = now
        -- Envelope + fragmentation overhead is deliberately charged as well.
        local cost = #packet[2] + 200
        -- Page data waits only for space in the reserved catch-up lane. It must
        -- not require silence from presence/alerts to make progress.
        local quietNeeded = packet[1] == "HB"
        if tokens >= cost and (not quietNeeded or not net or not net.CanSendLeaderboardPage
            or net:CanSendLeaderboardPage()) then
            tokens = tokens - cost
            local relayStats = net and net.stats
            local refusedBefore = relayStats and relayStats.localRowsRefused or 0
            if sync:SendWhisper(packet[1], packet[2], job.peer) ~= false then
                -- 2.0.2: the page the relay queue had refused is accepted at last: those
                -- refusals were flow control, not losses.
                if (job.refusals or 0) > 0 and net and net.NoteOfferedAgain then
                    net:NoteOfferedAgain(job.refusals)
                    job.refusals = 0
                end
                job.index = job.index + 1
                stats.bytes = stats.bytes + cost
                if job.index > #job.packets then
                    stats.repliesSent = (stats.repliesSent or 0) + 1
                    outbound = nil
                    if job.done then job.done() end
                    return
                end
            else
                stats.replySendsRefused = (stats.replySendsRefused or 0) + 1
                -- The page stays the next one: it is offered again in half a second.
                job.refusals = (job.refusals or 0)
                    + ((relayStats and relayStats.localRowsRefused or 0) - refusedBefore)
            end
        end
        wake = true
        C_Timer.After(0.5, pump)
    end
    job.pump = pump
    if not wake then wake = true; C_Timer.After(0.01, pump) end
    return true
end

-- Bucket digests skip per-client volatile fields. Two clients with the same
-- kills, guild, class and race used to disagree on almost every bucket because
-- each dates a guild membership (LK guildAt), a level (LK) or a race observation
-- (LR raceAt) at its own moment; every bucket was then sent in full and a sweep
-- took ~35 min (16 s/page live, rounds cut at 15 min). Pages still carry the full
-- rows, so merges are unchanged; peers on older digests simply mismatch, as before.
local function rowDigest(kind, payload)
    if kind == "LK" then
        -- name:kills:class:faction:epoch:locale:guild:guildAt:Bepoch:level
        local head, bucketToken = payload:match(
            "^([^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*):[^:]*:([^:]*):[^:]*$")
        if head then return head .. ":" .. bucketToken end
    elseif kind == "LR" then
        -- name:race:sex:epoch:observedAt
        local head = payload:match("^([^:]*:[^:]*:[^:]*:[^:]*):[^:]*$")
        if head then return head end
    end
    return payload
end
sync._PagedRowDigest = rowDigest
-- 2.5.1: hash(rowDigest(kind, payload)) without building the digest text: the same bytes
-- folded in place (the two cut strings and their join were ~300 B of garbage per row, ~3 MB
-- per profile at 10,000 players). rowDigest stays the definition (tests compare both).
local function colonAfter(payload, at) return payload:find(":", at + 1, true) end
local function digestHash(kind, payload)
    if kind == "LK" then
        -- Ten fields exactly: fields 1-7, ":", field 9.
        local c7 = colonAfter(payload, 0)
        for _ = 2, 7 do c7 = c7 and colonAfter(payload, c7) end
        local c8 = c7 and colonAfter(payload, c7)
        local c9 = c8 and colonAfter(payload, c8)
        if c9 and not colonAfter(payload, c9) then
            return foldRange(payload, (foldRange(payload, 0, 1, c7 - 1) * 31 + 58) % MOD, c8 + 1, c9 - 1)
        end
    elseif kind == "LR" then
        -- Five fields exactly: fields 1-4.
        local c4 = colonAfter(payload, 0)
        for _ = 2, 4 do c4 = c4 and colonAfter(payload, c4) end
        if c4 and not colonAfter(payload, c4) then return foldRange(payload, 0, 1, c4 - 1) end
    end
    return hash(payload)
end
sync._PagedDigestHash = digestHash

-- v7 digests (1.7): each row hash goes through a non-linear mix before the sum. With a
-- plain sum, two clients that each lead on a different row (A: X=102, Y=161; B: X=101,
-- Y=162) could cancel exactly: "identical", no row sent. Exact in doubles (< 2^53).
-- v6 keeps the plain sum, so 1.6.x peers still compare as before.
local function mixRow(h)
    return (h * 31 + (h % 9973) * (h % 10007)) % MOD
end
local function bucketHash(bucket, wire) return (wire == "7" or wire == "8") and bucket.hash7 or bucket.hash end
local function streamHash(profile, wire) return (wire == "7" or wire == "8") and profile.hash7 or profile.hash end
sync._PagedMixRow = mixRow

-- v7 (1.7.0) = v6 whose LK rows end with the player's race (":o2", 3 bytes), so the
-- race arrives with the score instead of waiting for the LR stream at the end of
-- the sweep. Only between peers advertising it; v6 peers keep the 10-field rows.
-- The race stays out of the digests (same as v6): race knowledge differs between
-- peers (one saw the player, the other did not), and digesting it made buckets
-- that only differ by a race go out in full on every sweep. It rides along with
-- any row that is sent; the LR stream still completes the rest. Rows over the
-- 250-byte limit go without it.
local function raceField(snapshot, name, payload)
    local info = snapshot and snapshot.playerInfo and snapshot.playerInfo[name]
    local field = type(info) == "table" and sync.EncodeRaceWireField
        and sync:EncodeRaceWireField(info.race, info.raceSex)
    if field and #payload + 1 + #field <= 250 then return field end
    return nil
end
sync._PagedRaceField = raceField
local function raced(wire, stream) return (wire == "7" or wire == "8") and stream == "LK" end
-- 1.8.0: a profile bucket holds parallel arrays (keys, payloads, digests, factions,
-- races for LK) instead of one table per row: about 100 B less per row (1.3 MB at
-- 13,000 rows), and the per-row digests serve the v8 row lists.
local function rowPayload(bucket, i, withRace)
    local race = withRace and bucket.races and bucket.races[i]
    return race and (bucket.payloads[i] .. ":" .. race) or bucket.payloads[i]
end
-- Faction of the row's player in the attested copy, one character on the wire (v8).
local function factionChar(snapshot, name)
    local info = snapshot and snapshot.playerInfo and snapshot.playerInfo[name]
    local faction = type(info) == "table" and info.faction
    return faction == "Alliance" and "A" or faction == "Horde" and "H" or "?"
end

-- All scans and sorting yield after 32 work units and a ~1 ms slice.
-- Only complete immutable profiles are published: at most 5,000 LK,
-- 1,500 LC, and 6,500 LR source identities.
-- A profile built from a copy younger than PROFILE_REUSE_SEC is served again: a
-- client whose ranking changes all the time (a bridge, a busy fight) rebuilt the copy
-- and its profile for every requester (~220 ms of work and ~29 MB of garbage for
-- 5,000 players, CPU spikes). Pages are then at most 2 minutes old; the next round
-- brings the rest.
local PROFILE_REUSE_SEC, PROFILE_DIRTY_REUSE_SEC, PROFILE_DIRTY_ROW_SEC = 120, 30, 0.03
-- own: the profile is for our own pull. It is not reused once rows were applied
-- since it was built (1.8.0: rounds every 45-105 s after a v8 round would otherwise
-- list and fetch again the rows the previous round just brought).
-- legacy (2.4.0): the profile of our view of 5,000 (LegacyView), for a peer that holds no more.
local function pendingRowBefore(a, b) return a[1] < b[1] end
local function prepare(callback, own, legacy)
    if building then return false end
    stats.profileWhy = nil
    local wanted = epoch()
    local recent = sync.GetAttestedLeaderboardSnapshot and sync:GetAttestedLeaderboardSnapshot()
    local recentCache = (legacy and type(recent) == "table" and LegacyView(recent) ~= recent) and legacyProfiles or profiles
    local cached = type(recent) == "table" and recentCache[recent] or nil
    local age = cached and (((GetServerTime and GetServerTime()) or time()) - (tonumber(recent.at) or 0)) or nil
    -- 2.2.2: without the channel, ranking rows travel from hand to hand by these pages: a copy
    -- two minutes old at every hand made each hop up to two minutes late (the whole ranking
    -- settled 6-7 minutes after the last kill). A copy our ranking moved past is served again
    -- only while younger than PROFILE_DIRTY_REUSE_SEC; an unchanged one as before (and always
    -- while the channel carries: there the totals come live). (Measured: about a quarter more
    -- rebuilds than at 120 s, the rows a fifth sooner; 60 s brought nothing over 120 s.)
    -- A rebuild costs garbage in proportion to the rows: the wait grows with the copy (30 s up
    -- to 1,000 rows, 120 s from 4,000), so at most ~33 rebuilt rows a second (2.2.1's rate for a
    -- 4,000-row copy at 120 s); a smaller copy rebuilds up to 4x more often than in 2.2.1, accepted.
    local reuse = PROFILE_REUSE_SEC
    local directory = Overlord.ChannelDirectory
    if lb._snapshotDirty and directory and directory.IsActive and directory:IsActive() then
        local perRow = tonumber(sync._profileDirtyRowSec) or PROFILE_DIRTY_ROW_SEC
        reuse = math.min(PROFILE_REUSE_SEC,
            math.max(PROFILE_DIRTY_REUSE_SEC, (cached and tonumber(cached.count) or 0) * perRow))
    end
    if cached and cached.epoch == wanted and age and age >= 0 and age < reuse
        and not (own and cached.builtRows ~= movedRows()) then
        stats.profileReused = (stats.profileReused or 0) + 1
        C_Timer.After(0.001, function()
            if wanted ~= epoch() then callback(nil); return end
            callback(cached)
        end)
        return true
    end
    building = true
    -- Rows that really changed our ranking so far (taken before the copy is made).
    local builtRows = movedRows()
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(ok)
        local snapshot = ok and sync:GetAttestedLeaderboardSnapshot()
        if not snapshot or wanted ~= epoch() then
            -- Kept for /ov network: which step left this pull without a local copy.
            stats.profileWhy = not ok and ("build: " .. tostring(lb._snapshotLastFailure or "?"))
                or not snapshot and "built copy not attested" or "campaign changed"
            building = nil; callback(nil); return
        end
        -- (From here on `snapshot` is what the profile is made of: the copy, or its view of 5,000.)
        local attested = snapshot
        if legacy then snapshot = LegacyView(attested) end
        local cache = snapshot ~= attested and legacyProfiles or profiles
        local limits = snapshot ~= attested and LEGACY_LIMITS or STREAM_LIMITS
        -- Killing blows: the live counts, read by key while the profile is built (none in a view
        -- of 5,000: nobody asks it), labelled with KB:ProfileRevision.
        local blows = Overlord.KillingBlows
        local kbCounts = snapshot == attested and blows and blows.Counts and blows:Counts() or nil
        local kbRevision = kbCounts and blows.ProfileRevision and blows:ProfileRevision() or false
        local known = cache[attested]
        if known and known.kbRevision == kbRevision then building = nil; callback(known); return end
        -- Only the killing blows moved since this copy's profile: its other streams are kept as
        -- they are (never written after their build), the stream LB alone is built again.
        local base = known and known.epoch == wanted and type(known.streams) == "table" and known or nil
        local result = { epoch = wanted, streams = {}, builtRows = builtRows, legacy = snapshot ~= attested or nil,
            kbRevision = kbRevision }
        for _, kind in ipairs(PROFILE_STREAMS) do
            result.streams[kind] = base and kind ~= "LB" and base.streams[kind] or { buckets = {}, count = 0,
                hash = 0, hash7 = 0, countA = 0, hashA = 0, countH = 0, hashH = 0 }
        end
        local building8 = base and { "LB" } or PROFILE_STREAMS
        if base then stats.profileKBOnly = (stats.profileKBOnly or 0) + 1 end
        result.buckets = result.streams.LK.buckets
        local units, sliceAt = 0, 0
        -- A slice ends on its time budget (1 ms). The count is only the fallback of a client
        -- without a fine clock: at 32 units a slice did a few hundredths of a millisecond
        -- of work, the answer to a ranking request took over a thousand frames to leave
        -- (half a minute to several minutes by frame rate) and requesters gave up at
        -- 270 s. Same total work, same pause in combat (step below), nothing on the wire.
        local unitCap = debugprofilestop and 4096 or 32
        local function work()
            units = units + 1
            if units >= unitCap or (debugprofilestop and debugprofilestop() - sliceAt >= 1) then
                coroutine.yield()
            end
        end
        local co = coroutine.create(function()
            -- Killing blows of the players of this very copy, by identity, under the copy's own
            -- spelling and within its honorable kills: two clients whose kill rows agree list
            -- the same rows (a row never refused at the other side, never a different spelling,
            -- never more rows than the kill stream holds).
            local kbByKey = kbCounts or {}
            local sources = { LK = snapshot.kills, LC = snapshot.captureCount,
                LR = snapshot.playerInfo, LB = next(kbByKey) ~= nil and snapshot.kills or {} }
            local serializers = {
                LK = sync.BuildPagedLeaderboardKillPayload,
                LC = sync.BuildPagedLeaderboardCapturePayload,
                LR = sync.BuildPagedLeaderboardRacePayload,
                LB = function(_, copy, name)
                    local count, kills = tonumber(kbByKey[key(name)]), tonumber(copy.kills[name])
                    if not count or count <= 0 or not kills or kills <= 0 then return nil end
                    return name .. ":" .. string.format("%d", math.min(count, math.floor(kills)))
                end,
            }
            for _, kind in ipairs(building8) do
                local profile, source, count = result.streams[kind], sources[kind] or {}, 0
                local isKills = kind == "LK"
                -- Rows are gathered and sorted as small arrays { identity, payload, name }
                -- (2.5.1: half the size of a keyed table), then kept as parallel arrays.
                local pending = {}
                for i = 1, BUCKETS do pending[i] = {}; work() end
                for name in pairs(source) do
                    count = count + 1
                    if count > limits[kind] then error("oversized attested snapshot") end
                    local serialize = serializers[kind]
                    local payload = serialize and serialize(sync, snapshot, name, wanted)
                    local identity = payload and key(name)
                    if identity and validCursor(identity) then
                        local rows = pending[hash(identity) % BUCKETS + 1]
                        rows[#rows + 1] = { identity, payload, name }
                    end
                    work()
                end
                for i = 1, BUCKETS do
                    local rows = pending[i]
                    lb:SortNetworkRows(rows, pendingRowBefore, work)
                    local bucket = { hash = 0, hash7 = 0, n = #rows, keys = {}, payloads = {},
                        digests = {}, factions = {}, races = isKills and {} or nil,
                        nA = 0, hashA = 0, nH = 0, hashH = 0 }
                    for j = 1, #rows do
                        local row = rows[j]
                        local rowKey, rowText, rowName = row[1], row[2], row[3]
                        local h = digestHash(kind, rowText)
                        local faction, mixed = factionChar(snapshot, rowName), mixRow(h)
                        bucket.keys[j], bucket.payloads[j], bucket.digests[j] = rowKey, rowText, h
                        bucket.factions[j] = faction
                        if isKills then bucket.races[j] = raceField(snapshot, rowName, rowText) or false end
                        bucket.hash = (bucket.hash + h) % MOD
                        bucket.hash7 = (bucket.hash7 + mixed) % MOD
                        if faction ~= "H" then bucket.nA, bucket.hashA = bucket.nA + 1, (bucket.hashA + mixed) % MOD end
                        if faction ~= "A" then bucket.nH, bucket.hashH = bucket.nH + 1, (bucket.hashH + mixed) % MOD end
                        work()
                    end
                    pending[i] = nil
                    profile.buckets[i] = bucket
                    profile.count = profile.count + bucket.n
                    profile.hash = (profile.hash + bucket.hash) % MOD
                    profile.hash7 = (profile.hash7 + bucket.hash7) % MOD
                    profile.countA, profile.hashA = profile.countA + bucket.nA, (profile.hashA + bucket.hashA) % MOD
                    profile.countH, profile.hashH = profile.countH + bucket.nH, (profile.hashH + bucket.hashH) % MOD
                end
            end
            result.count, result.hash = result.streams.LK.count, result.streams.LK.hash
            -- Rank order of the attested copy (names, best first): a reference only.
            result.order = type(snapshot.killOrder) == "table" and snapshot.killOrder or {}
        end)
        local function step()
            if wanted ~= epoch() then building = nil; callback(nil); return end
            if paused() then C_Timer.After(2, step); return end
            units, sliceAt = 0, debugprofilestop and debugprofilestop() or 0
            local success, err = coroutine.resume(co)
            if not success then
                stats.error = tostring(err)
                stats.profileWhy = "profile error: " .. stats.error:gsub("[%(%)]", "")
                building = nil; callback(nil); return
            end
            if coroutine.status(co) ~= "dead" then C_Timer.After(0.001, step); return end
            cache[attested] = result
            building = nil
            callback(result)
        end
        C_Timer.After(0.001, step)
    end)
    if accepted == false then building = nil; return false end
    return true
end

-- One sweep position shared by every neighbour (1.3.3). Buckets are cut by
-- identity hash, the same on every client, so a bucket certified with one peer
-- need not be asked again of the next. Per-peer positions restarted the sweep
-- each time the scheduler changed neighbour: rounds never reached the end of the
-- 192 buckets and the capture/race streams were never asked. No extra traffic:
-- only where the next pull starts changes.
local function progress()
    local saved = OverlordDB.leaderboardPageProgress
    if type(saved) ~= "table" or saved.version ~= 3 or saved.epoch ~= epoch() then
        -- Older per-peer positions (version 2) are dropped: the sweep restarts once.
        saved = { version = 3, epoch = epoch() }
        OverlordDB.leaderboardPageProgress = saved
    end
    return saved
end
-- v8 (1.8.0): row-level anti-entropy, same budget and same single responder.
-- v7 sent a whole bucket (~80 rows at 5,000 players) as soon as one row differed,
-- and with live scores almost every bucket differs: a sweep resent nearly the whole
-- ranking (about an hour at 5,000 players). v8 per stream:
--   V: the responder sends one 4-character fingerprint per bucket (64, 3 packets);
--   L: for each differing bucket, one fingerprint + faction character per row;
--   G: the requester asks for the rows it lacks (bitmap), in pages of up to 24 rows.
-- From a Battle.net friend of the other faction, only that faction's rows (and rows
-- of unknown faction) are asked: our own faction's rows come first-hand from our
-- channel and our allies. No extra reply: still one request, one answer, in turn.
-- Fingerprints are salted with the pull's nonce, so a rare 24-bit collision cannot
-- hide the same row at every sweep. Acceptance of the rows is unchanged (content only).
local FP_SPACE, LIST_MAX_ROWS, BITMAP_MAX = 16777216, 812, 200
local B64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local B64BYTES, B64INDEX = { B64:byte(1, 64) }, {}
for i = 1, 64 do B64INDEX[B64BYTES[i]] = i - 1 end
local function encodeFp(fp)
    local c4 = fp % 64; fp = (fp - c4) / 64
    local c3 = fp % 64; fp = (fp - c3) / 64
    local c2 = fp % 64
    return string.char(B64BYTES[(fp - c2) / 64 + 1], B64BYTES[c2 + 1], B64BYTES[c3 + 1], B64BYTES[c4 + 1])
end
-- (x * a) % MOD without leaving exact doubles (x, a < 2^31).
local function mulmod(x, a)
    local hi = math.floor(a / 65536)
    return ((x * hi) % MOD * 65536 + x * (a % 65536)) % MOD
end
local function saltOf(nonce)
    local h = hash(nonce)
    return h % (MOD - 1) + 1, (h * 7 + 13) % MOD
end
local function rowFp(digest, a, b) return encodeFp((mulmod(digest, a) + b) % MOD % FP_SPACE) end
-- Count and mixed sum of a bucket or a stream, whole or restricted to one faction
-- (rows of unknown faction belong to both): a pull from a friend of the other faction
-- compares only that faction's rows, so a quiet ranking stays one reply per stream.
local function subset(t, filter)
    if filter == "A" then return t.nA or t.countA, t.hashA end
    if filter == "H" then return t.nH or t.countH, t.hashH end
    return t.n or t.count, t.hash7
end
local function bucketFp(bucket, a, b, filter)
    local n, h = subset(bucket, filter)
    return rowFp((h + n * 65599) % MOD, a, b)
end
-- One fingerprint of the three streams (same filter, same salt): sent with the
-- first request of a pull, it lets a pair that already agrees end in a single
-- exchange (1 request, 1 reply) instead of one per stream.
-- (withKB: a pull between two clients of capability 11 compares the killing blows too.)
local function profileFp(profile, a, b, filter, withKB)
    local acc = 0
    for _, kind in ipairs(withKB and PROFILE_STREAMS or STREAMS) do
        local n, h = subset(profile.streams[kind], filter)
        acc = (acc * 31 + (h + n * 65599) % MOD) % MOD
    end
    return rowFp(acc, a, b)
end
-- Wanted row indexes (ascending, 1-based) as 6 bits per character.
local function encodeBitmap(want)
    local values = {}
    for _, i in ipairs(want) do
        local k = math.floor((i - 1) / 6) + 1
        for j = #values + 1, k do values[j] = 0 end
        values[k] = values[k] + 2 ^ ((i - 1) % 6)
    end
    for j = 1, #values do values[j] = B64BYTES[values[j] + 1] end
    return string.char(unpack(values))
end
-- "*" asks for every row of the bucket, "*A"/"*H" for every row of that faction
-- (and of unknown faction): a bucket we hold nothing of needs no row list.
local function wantedAt(bitmap, i, factions)
    if bitmap == "*" then return true end
    if bitmap == "*A" or bitmap == "*H" then
        local faction = factions and factions[i]
        return faction == bitmap:sub(2, 2) or faction == "?"
    end
    local k = math.floor((i - 1) / 6) + 1
    if k > #bitmap then return false end
    return math.floor(B64INDEX[bitmap:byte(k)] / 2 ^ ((i - 1) % 6)) % 2 == 1
end
-- v8 rows travel without the campaign epoch: every packet of the exchange already
-- carries it (and it must equal ours), so the responder drops it from the row and
-- the requester puts it back before the unchanged acceptance code reads the row.
-- LK name:kills:class:faction:E:locale:guild:guildAt:BE:level[:race] -> without E, BE
-- LC name:F:class:count:E:zones:locale:BE -> without E, BE; LR name:race:sex:E:at -> without E.
-- Fields never hold ':' (SafeWireField), so the patterns are exact. About a quarter
-- fewer bytes per row (25 % of an LK row), at the same byte budget.
local PAGE_ROWS8, PAGE_ROWS8_MAX = 24, 32
-- T (cold pull only): the TOP_ROWS best kill rows first, in rank order, so the
-- visible top of the table fills in about a minute instead of across the sweep.
-- Ranks are walked in order (at most TOP_SCAN per page), skipping rows of the other
-- faction when the requester filters; the cursor is the next rank to look at.
local TOP_ROWS, COLD_PULL_ROWS, TOP_SCAN = 96, 20, 256
local function compactRow8(stream, payload, wireEpoch)
    local e = tostring(wireEpoch)
    if stream == "LK" then
        local head, e1, mid, e2, level = payload:match(
            "^([^:]*:[^:]*:[^:]*:[^:]*):([^:]*):([^:]*:[^:]*:[^:]*):([^:]*):([^:]*)$")
        if head and e1 == e and e2 == "B" .. e then return head .. ":" .. mid .. ":" .. level end
    elseif stream == "LC" then
        local head, e1, mid, e2 = payload:match("^([^:]*:[^:]*:[^:]*:[^:]*):([^:]*):([^:]*:[^:]*):([^:]*)$")
        if head and e1 == e and e2 == "B" .. e then return head .. ":" .. mid end
    elseif stream == "LB" then
        -- (No epoch in a killing blow row: it travels as it is.)
        if payload:match("^[^:]+:%d+$") then return payload end
    else
        local head, e1, at = payload:match("^([^:]*:[^:]*:[^:]*):([^:]*):([^:]*)$")
        if head and e1 == e then return head .. ":" .. at end
    end
    return nil
end
local function expandRow8(stream, row, wireEpoch)
    local e = tostring(wireEpoch)
    local full
    if stream == "LK" then
        local head, mid, level, race = row:match(
            "^([^:]*:[^:]*:[^:]*:[^:]*):([^:]*:[^:]*:[^:]*):([^:]*):([^:]*)$")
        if not head then
            head, mid, level = row:match("^([^:]*:[^:]*:[^:]*:[^:]*):([^:]*:[^:]*:[^:]*):([^:]*)$")
        end
        if head then
            full = head .. ":" .. e .. ":" .. mid .. ":B" .. e .. ":" .. level .. (race and (":" .. race) or "")
        end
        return full and #full <= 250 and full or nil
    elseif stream == "LC" then
        local head, mid = row:match("^([^:]*:[^:]*:[^:]*:[^:]*):([^:]*:[^:]*)$")
        if head then full = head .. ":" .. e .. ":" .. mid .. ":B" .. e end
        return full and #full <= 3500 and full or nil
    elseif stream == "LB" then
        return #row <= 250 and row:match("^[^:]+:%d+$") and row or nil
    end
    local head, at = row:match("^([^:]*:[^:]*:[^:]*):([^:]*)$")
    if head then full = head .. ":" .. e .. ":" .. at end
    return full and #full <= 250 and full or nil
end
sync._PagedCompactRow8, sync._PagedExpandRow8 = compactRow8, expandRow8

local function validBitmap(bitmap)
    return bitmap == "*" or bitmap == "*A" or bitmap == "*H"
        or (type(bitmap) == "string" and #bitmap >= 1 and #bitmap <= BITMAP_MAX
            and not bitmap:find("[^0-9A-Za-z_-]"))
end

local function checkpoint(state)
    -- A pull of a finished campaign must not seed the new campaign's sweep.
    if state.epoch ~= epoch() then return end
    local saved = progress()
    if state.wire == "8" then
        -- A v8 stream restarts with its bucket fingerprints (3 packets): only the
        -- stream is kept, and a v7 pull with another peer resumes at its start.
        saved.shared = { stream = state.stream or "LK", bucket = 1, done = 0, at = GetServerTime(), wire8 = true }
        return
    end
    local previous = saved.shared
    if not state.extended and type(previous) == "table"
        and (previous.stream == "LC" or previous.stream == "LR") then
        -- A compatibility LK pass must not erase a v6 capture/race resume point.
        previous.at = GetServerTime()
        return
    end
    -- Restart the current bucket after reload: a new snapshot may have changed
    -- its order. Persisting its cursor would silently skip inserted identities.
    -- done: buckets of this stream already certified, whichever peer served them.
    saved.shared = { stream = state.stream or "LK", bucket = state.bucket,
        done = (state.completed or 0) % BUCKETS, at = GetServerTime() }
end
local sendControl
local function finish(state, success, unsupportedPeer)
    if pull ~= state then return end
    -- 2.0: a pull whose request left and never got an answer of any kind compared
    -- nothing, so its stream is not kept: the next pull starts again at the kills (one
    -- request and one reply when they are equal). A checkpoint left at the captures or
    -- the races made every later pull ask that stream again, in this session and the
    -- next ones; while the neighbours asked stayed silent the kills were no longer
    -- compared at all. A pull that could not even ask (no local snapshot, request never
    -- admitted) says nothing of the neighbour and keeps its stream.
    -- Nothing is sent and no answer changes: only where the next pull starts.
    if not success and state.wire == "8" and not state.supported and state.sentAny then
        stats.silentPulls = (stats.silentPulls or 0) + 1
        state.stream = "LK"
    end
    checkpoint(state)
    pull = nil
    -- A failed pull tells its responder to drop the session at once; otherwise the
    -- next attempt (fresh nonce) would be answered "busy" for up to five minutes.
    if not success and state.seq > 0 and sendControl then
        sendControl("HR", table.concat({ state.wire, "F",
            state.epoch, state.nonce, state.seq }, ":"), state.peer)
    end
    -- /ov network: why the last pull stopped (busy responder, silence, ...).
    stats.result = success and "sweep received"
        or ("interrupted (" .. tostring(state.why or "?") .. "); bucket retained")
    if unsupportedPeer and not state.extended then
        if not unsupported[state.peer] then
            unsupportedOrder[#unsupportedOrder + 1] = state.peer
            if #unsupportedOrder > 8 then unsupported[table.remove(unsupportedOrder, 1)] = nil end
        end
        unsupported[state.peer] = GetTime() + 600
    end
    if success then
        -- Leaderboard badge: the sweep ends here (LR done, or the whole ranking
        -- matched). Rows it changed in our ranking, counted from the pull that
        -- started it at LK (0 = nothing was missing); "full" only when that start
        -- was seen, and whether an enemy friend's pull compared enemy rows only.
        stats.lastSweepFull = stats.sweepBase ~= nil or state.wholeMatch == true
        stats.lastSweepChanged = (stats.changedRows or 0) - (stats.sweepBase or state.changedAtStart or 0)
        stats.lastSweepFiltered = stats.sweepFiltered == true or state.factionFilter ~= nil
        stats.lastSweepAt = stats.sweepAt or state.startedAt
        stats.sweepBase, stats.sweepAt, stats.sweepFiltered, stats.sweepEpoch = nil, nil, nil, nil
    end
    -- Third value: nothing ever left for this peer (our own copy could not be built,
    -- the round was cut before its first request): the failure is ours, not its.
    state.callback(success, state.supported == true, state.sentAny ~= true)
end

-- Requests, probes and busy replies are a single small packet. They leave
-- directly instead of waiting behind the page producer: a client serving a long
-- sweep could otherwise neither ask for its own pages nor tell another requester
-- it is busy, and that requester concluded "v6 silent" after 270 s.
sendControl = function(kind, payload, peer)
    return sync:SendWhisper(kind, payload, peer) ~= false
end

local request, tryApply
request = function(state, retry)
    if pull ~= state then return end
    if state.epoch ~= epoch() then state.why = "campaign changed"; finish(state, false); return end
    state.waitingForSend = true
    if paused() then C_Timer.After(2, function() request(state, retry) end); return end
    if not retry then
        state.seq = state.seq + 1
        state.tries, state.parts, state.meta, state.partCount, state.bytes = 0, {}, nil, nil, 0
        state.replySeen = nil
    end
    state.tries = state.tries + 1
    local profile = state.extended and state.profile.streams[state.stream] or state.profile
    local fields
    if state.wire == "8" then
        if state.phase == "V" then
            local count, digest = subset(profile, state.factionFilter)
            fields = { "8", "V", state.epoch, state.nonce, state.seq, state.stream, count, digest }
            if state.seq == 1 then
                local a, b = saltOf(state.nonce)
                fields[#fields + 1] = state.factionFilter or "-"
                fields[#fields + 1] = profileFp(state.profile, a, b, state.factionFilter, state.kb)
            elseif state.factionFilter then
                fields[#fields + 1] = state.factionFilter
            end
        elseif state.phase == "T" then
            fields = { "8", "T", state.epoch, state.nonce, state.seq, "LK", state.from,
                state.factionFilter or "-" }
        elseif state.phase == "M" then
            fields = { "8", "M", state.epoch, state.nonce, state.seq, state.stream, state.wideBitmap }
        elseif state.phase == "N" then
            fields = { "8", "N", state.epoch, state.nonce, state.seq, state.stream, state.coveredBitmap,
                state.from, state.bitmap }
        elseif state.phase == "L" then
            fields = { "8", "L", state.epoch, state.nonce, state.seq, state.stream, state.bucket }
        else
            fields = { "8", "G", state.epoch, state.nonce, state.seq, state.stream, state.bucket,
                state.from, state.bitmap }
        end
    else
        local bucket = profile.buckets[state.bucket]
        fields = { state.wire, "Q", state.epoch, state.nonce, state.seq,
            state.bucket, state.cursor, bucket.n, bucketHash(bucket, state.wire) }
        if state.extended then fields[#fields + 1] = state.stream end
        if state.seq == 1 or (state.extended and state.completed == 0) then
            fields[#fields + 1], fields[#fields + 2] = profile.count, streamHash(profile, state.wire)
        end
    end
    local payload = table.concat(fields, ":")
    state.lastRequest = payload
    local seq, tries = state.seq, state.tries
    local function sendRequest()
        if pull ~= state or state.seq ~= seq or state.tries ~= tries then return end
        -- The peer stopped being a direct neighbour (its route is now relayed):
        -- the relay refuses catch-up toward it for good, so end this pull now
        -- instead of retrying until the 15 min watchdog; the next round picks
        -- another neighbour. No packet is sent.
        local net = Overlord.Relay
        if net and net.IsPeer and net.IsDirectPeer and net:IsPeer(state.peer)
            and not net:IsDirectPeer(state.peer) then
            state.why = "peer no longer direct"
            finish(state, false)
            return
        end
        if paused() or not sendControl("HR", payload, state.peer) then
            C_Timer.After(2, sendRequest)
            return
        end
        state.waitingForSend = nil
        state.sentAny = true
        -- (The feed of a peer is taken once we asked it ourselves.)
        if state.feed then
            feed.keep(feed.asked, "askedCount", state.peer:lower(), GetTime(), 64, feed.SOURCE_TTL)
        end
    end
    sendRequest()
    -- Two relay TTLs plus margin also cover a congested first request/reply.
    -- A peer that already answered pages in this pull and then goes silent has
    -- most likely left or zoned in: give up sooner (rows already merged stay).
    -- (2.3.0: a wide round counts no bucket in completed; it only runs after the peer answered
    -- its V, so it is as answered as a pull past its first bucket.)
    local answered = state.completed > 0 or state.replySeen or state.wideTodo ~= nil
    local remaining = state.supported and (answered and 90 or 180) or 270
    state.timeoutRemaining = remaining
    -- The first request can be admitted locally yet disappear in a relay, or
    -- arrive while the responder is briefly busy. Probe with the exact same
    -- frozen request. Active watchdog time keeps probes spaced across combat.
    local nextProbeAt, probesSent = 90, 0
    local seenFragmentAt = state.fragmentAt
    local function timeout()
        if pull ~= state or state.seq ~= seq or state.tries ~= tries or state.applying then return end
        if state.epoch ~= epoch() then state.why = "campaign changed"; finish(state, false); return end
        -- Une page qui arrive encore fragment par fragment n'est pas muette.
        if state.fragmentAt ~= seenFragmentAt then
            seenFragmentAt = state.fragmentAt
            if state.supported and remaining < 90 then remaining = 90 end
        end
        -- A request still waiting for our own send slot does not count as the
        -- peer's silence (a saturated local queue punished a healthy peer 10 min).
        if not paused() and not state.waitingForSend then remaining = remaining - 2 end
        state.timeoutRemaining = remaining
        if tries == 1 and not state.supported and not state.replySeen
            and not paused() and remaining > 0
            and probesSent < 2 and 270 - remaining >= nextProbeAt then
            local elapsed = 270 - remaining
            if sendControl("HR", payload, state.peer) then
                stats.retries = stats.retries + 1
                probesSent = probesSent + 1
                nextProbeAt = elapsed + 90
            end
        end
        if remaining > 0 then C_Timer.After(2, timeout); return end
        if state.supported and state.tries < (answered and 2 or 3) then
            stats.retries = stats.retries + 1
            request(state, true)
        else
            state.why = state.supported and "silent after replying" or "no reply"
            finish(state, false, not state.supported)
        end
    end
    C_Timer.After(2, timeout)
end
-- Overlord Rank: the kills of a sweep have just been compared in full with this peer
-- (the sweep was seen from its start at LK in this session, and is not limited to one
-- faction's rows). A weekly place needs nothing else: it need not wait for the
-- captures and the races, where a sweep can stall for long. Local, O(1), nothing sent,
-- nothing of the pull is changed.
local function noteKillsCompared(state)
    if state.stream ~= "LK" or stats.sweepBase == nil or stats.sweepEpoch ~= state.epoch
        or stats.sweepFiltered or state.factionFilter
        or (stats.sweepAt or 0) < (sync._ladderTrustFloor or 0) then return end
    local ranks = Overlord.Ranks
    if ranks and ranks.NoteLadderSeen then pcall(ranks.NoteLadderSeen, ranks, GetServerTime()) end
end
local function nextPage(state, cursor)
    state.combatWaits = 0 -- progress: a later fight of the peer may be waited for again
    stats.pages = stats.pages + 1
    if cursor == "-" then
        state.bucket, state.completed = state.bucket % BUCKETS + 1, state.completed + 1
        checkpoint(state)
    end
    state.cursor = cursor
    if state.completed >= BUCKETS then
        if state.extended and state.stream ~= "LR" then
            noteKillsCompared(state)
            state.stream = state.stream == "LK" and "LC" or "LR"
            state.bucket, state.completed, state.cursor = 1, 0, "-"
            checkpoint(state)
            request(state)
            return
        end
        if state.extended then
            state.stream, state.bucket, state.completed = "LK", 1, 0
            checkpoint(state)
        end
        -- End notice leaves directly: queued behind our own outbound pages it was
        -- dropped, and the responder kept us as its session (answering "R" to
        -- everyone else) for five minutes.
        sendControl("HR", table.concat({ state.wire, "F",
            state.epoch, state.nonce, state.seq }, ":"), state.peer)
        finish(state, true)
        return
    end
    request(state)
end

-- v8 transitions: next stream, next differing bucket, next page of wanted rows.
-- The stream after this one in a sweep, nil at its end. raceless: a 1.8.0 peer, kills and
-- captures only (see the header); kb: a peer of capability 11, the killing blows last.
local function followingStream8(state)
    if state.stream == "LK" then return "LC" end
    if state.stream == "LC" then return not state.raceless and "LR" or nil end
    if state.stream == "LR" then return state.kb and "LB" or nil end
    return nil
end
local function nextStream8(state)
    state.combatWaits = 0
    local following = followingStream8(state)
    if following then
        noteKillsCompared(state)
        state.stream = following
        if following == "LB" then kbSweepAt = GetTime() end
        state.phase, state.queue, state.qi, state.bucket, state.completed = "V", nil, 0, 0, 0
        checkpoint(state)
        request(state)
        return
    end
    state.stream, state.completed = "LK", 0
    checkpoint(state)
    sendControl("HR", table.concat({ "8", "F", state.epoch, state.nonce, state.seq }, ":"), state.peer)
    finish(state, true)
end
local SMALL_BUCKET_ROWS, SMALL_STREAM_ROWS = 4, 640
local function nextBucket8(state)
    state.combatWaits = 0
    state.qi = state.qi + 1
    local bucketIndex = state.queue and state.queue[state.qi]
    if not bucketIndex then nextStream8(state); return end
    state.bucket, state.gLast = bucketIndex, nil
    local own = state.profile.streams[state.stream].buckets[bucketIndex]
    -- Nothing of ours in this bucket: every row is wanted (of the friend's faction
    -- when it is of the other faction), no list needed.
    -- 2.2.2: a small bucket of a small ranking is asked whole too (the list step is one more
    -- round trip, 3-4 s, for a handful of rows): fewer exchanges, a page of rows we mostly hold.
    local ownStream = state.profile.streams[state.stream]
    local small = own.n <= SMALL_BUCKET_ROWS and (subset(ownStream, state.factionFilter) or 0) <= SMALL_STREAM_ROWS
    if own.n == 0 or small then
        state.phase, state.from = "G", 1
        state.bitmap = state.factionFilter and ("*" .. state.factionFilter) or "*"
    else
        state.phase = "L"
    end
    request(state)
end
local function nextRows8(state, cursor)
    stats.pages = stats.pages + 1
    if cursor == "-" then
        state.completed = (state.completed or 0) + 1
        nextBucket8(state)
        return
    end
    state.combatWaits = 0
    state.from = tonumber(cursor)
    request(state)
end
local function nextTop8(state, cursor)
    stats.pages = stats.pages + 1
    state.combatWaits = 0
    if cursor == "-" or state.topApplied >= TOP_ROWS then
        -- Top received: the normal sweep follows (the rows of T come again once in
        -- it, our frozen profile does not hold them; a capped first contact is then
        -- raised to the served value, as on any second delivery).
        state.phase, state.bucket, state.qi, state.queue = "V", 0, 0, nil
    else
        state.from = tonumber(cursor)
    end
    request(state)
end

-- 2.2.2: wide rounds. Between two 2.2.2 clients the differing buckets of a stream are not
-- walked one at a time (a list and a page of rows each: two round trips of 3-4 s per bucket,
-- and the responder busy for the whole minute): "M" asks the row lists of all the buckets
-- still to do at once (as many as one answer holds, a header and the 5-byte entries of each
-- bucket, in index order), "N" then asks the wanted rows of the listed buckets, numbered along
-- the lists, a page at a time. The same fingerprints, the same rows and the same acceptance
-- as L and G; only the number of exchanges changes. A bucket too big for a list (WIDE_BIG) is
-- left to L and G. Older clients are never asked: their release (their own presence) decides.
local WIDE_MIN_RELEASE, WIDE_BLOB_MAX, WIDE_BIG, WIDE_RELEASE_AGE = { 2, 2, 2 }, 4000, 790, 3 * 3600
-- Hint (kill rows only): next to its fingerprint and faction, every entry of an LK list carries
-- 5 more characters, the player's key tag (14 bits of a key hash whose base and seed come from the
-- pull's nonce, so two keys sharing a tag in one pull almost never do in the next) and the
-- kill total (16 bits, 65535 = "more or unknown"). The requester does not ask the rows it can
-- tell it is AHEAD on (the same tag in the bucket, every row holding it more kills than the
-- list says). A wrong or lying hint can only make us skip rows (the list's sender is asked
-- nothing it could not already refuse us): the rows that are asked and delivered go through the
-- same acceptance as ever, a score is never taken from a list.
-- A list carries hints for the buckets of at most hintMax rows (the entries of a big bucket would
-- cost more than the rows they spare); the count of such a bucket is sent 500 higher.
-- (LK lists, hinted, are cut at blobLK: the requester works a list out in one frame.)
-- hintBudget: own rows a requester turns into hints in one frame (beyond it, rows are asked).
-- fpBudget (2.3.0): own rows a requester fingerprints in one frame (wideAsk: buckets asked per M).
local wide = { bigLK = 400, ordMax = 4000, killsMax = 65535, hintMax = 32, blobLK = 2000, hintBudget = 600,
    fpBudget = 1000 }
sync._leaderboardWide = wide
function wide.big(stream) return stream == "LK" and wide.bigLK or WIDE_BIG end
function wide.blob(stream) return stream == "LK" and wide.blobLK or WIDE_BLOB_MAX end
-- (h < 2^31 and base < 1028: every step stays an exact double. The top 14 bits of a salted
-- product: the low bits of a polynomial hash follow the last characters too closely.)
function wide.tag(key, a, b)
    local base, h = 31 + a % 997, b
    for i = 1, #key do h = (h * base + key:byte(i)) % MOD end
    return math.floor(((mulmod(h, a) + b) % MOD) / 131072)
end
function wide.encode(key, payload, a, b)
    local kills = tonumber(payload:match("^[^:]*:(%d+):"))
    if not kills or kills >= wide.killsMax then kills = wide.killsMax end
    local value = wide.tag(key, a, b) * 65536 + kills
    local d5 = value % 64; value = (value - d5) / 64
    local d4 = value % 64; value = (value - d4) / 64
    local d3 = value % 64; value = (value - d3) / 64
    local d2 = value % 64
    return string.char(B64BYTES[(value - d2) / 64 + 1], B64BYTES[d2 + 1], B64BYTES[d3 + 1], B64BYTES[d4 + 1], B64BYTES[d5 + 1])
end
-- tag, kills (nil when the five characters are not a hint)
function wide.decode(text)
    local value = 0
    for i = 1, 5 do
        local digit = B64INDEX[text:byte(i) or 0]
        if not digit then return nil end
        value = value * 64 + digit
    end
    return math.floor(value / 65536), value % 65536
end
-- Our rows of a bucket by tag: the lowest kill total of each (cached for the pull).
function wide.own(state, bucketIndex, bucket, a, b)
    local cache = state.ownHint
    if not cache then cache = {}; state.ownHint = cache end
    local found = cache[bucketIndex]
    if found then return found end
    found = {}
    for j = 1, bucket.n do
        local tag = wide.tag(bucket.keys[j], a, b)
        local kills = tonumber(bucket.payloads[j]:match("^[^:]*:(%d+):")) or 0
        if not found[tag] or kills < found[tag] then found[tag] = kills end
    end
    cache[bucketIndex] = found
    return found
end
local function wideAllowed(peer)
    local net = Overlord.Relay
    local release = net and net.GetPeerReleaseWithin and net:GetPeerReleaseWithin(peer, WIDE_RELEASE_AGE)
    local x, y, z = tostring(release or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not x then return false end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x ~= WIDE_MIN_RELEASE[1] then return x > WIDE_MIN_RELEASE[1] end
    if y ~= WIDE_MIN_RELEASE[2] then return y > WIDE_MIN_RELEASE[2] end
    return z >= WIDE_MIN_RELEASE[3]
end
local function wideAsk(state)
    local todo = {}
    for i in pairs(state.wideTodo) do todo[#todo + 1] = i end
    table.sort(todo)
    -- 2.3.0: our own fingerprints of the listed buckets are worked out in the frame their list
    -- arrives (applyWideList): one M asks the buckets holding at most fpBudget rows of ours (one
    -- bucket always), the others wait for the next M. A big ranking pulling from a small one had
    -- all 64 buckets in one answer: its whole stream (6,500 race rows) fingerprinted in one frame.
    local own, picked, asked, rows = state.profile.streams[state.stream].buckets, {}, {}, 0
    for _, i in ipairs(todo) do
        local n = own[i].n
        if #picked > 0 and rows + n > wide.fpBudget then break end
        picked[#picked + 1], asked[i], rows = i, true, rows + n
    end
    state.phase, state.wideBitmap, state.wideAsked = "M", encodeBitmap(picked), asked
    state.nLastBucket, state.nLastKey, state.wideCovered = nil, nil, nil
    request(state)
end
local function wideNext(state)
    state.combatWaits = 0
    if next(state.wideTodo) then wideAsk(state); return end
    local left = state.wideLeft
    state.wideTodo, state.wideAsked, state.wideLeft = nil, nil, nil
    state.ownFp, state.ownHint = nil, nil
    if left and #left > 0 then
        -- (Buckets too big for a list: the usual way.)
        state.queue, state.qi = left, 0
        nextBucket8(state)
        return
    end
    nextStream8(state)
end
local function nextWideRows(state, cursor)
    stats.pages = stats.pages + 1
    if cursor == "-" then wideNext(state); return end
    state.combatWaits = 0
    state.from = tonumber(cursor)
    request(state)
end
local function wideStart(state, queue)
    state.wideTodo, state.wideLeft, state.ownFp, state.ownHint = {}, {}, nil, nil
    -- 2.3.0: a bucket we hold nothing of is not listed: every row of it is wanted, its list would
    -- only add 5-10 bytes a row on the wire. G asks it whole after the wide round, as in 2.2.1.
    local buckets, listed = state.profile.streams[state.stream].buckets, false
    for _, i in ipairs(queue) do
        if buckets[i].n == 0 then state.wideLeft[#state.wideLeft + 1] = i
        else state.wideTodo[i], listed = true, true end
    end
    if not listed then wideNext(state); return end
    stats.wideRounds = (stats.wideRounds or 0) + 1
    wideAsk(state)
end
-- The answer to an M: headers (bucket, then its entry count, 999 for a bucket too big) and
-- entries, every unit 5 bytes. Returns false for anything that does not add up.
local function applyWideList(state, meta, blob)
    local own = state.profile.streams[state.stream]
    local a, b = saltOf(state.nonce)
    stats.pages = stats.pages + 1
    if #blob ~= meta.rows * 5 then return false end
    local pos, covered, coveredList, left, want, ordinal, previous = 1, {}, {}, {}, {}, 0, 0
    local filter, listed, headers = state.factionFilter, 0, 0
    local skipped, hintBudget = 0, wide.hintBudget
    while pos <= #blob do
        local bucket, count = tonumber(blob:sub(pos, pos + 1)), tonumber(blob:sub(pos + 2, pos + 4))
        if not bucket or not count or bucket <= previous or bucket > BUCKETS
            or not state.wideAsked[bucket] or not blob:sub(pos, pos + 4):match("^%d%d%d%d%d$") then return false end
        previous, pos, headers = bucket, pos + 5, headers + 1
        if count == 999 then
            left[#left + 1] = bucket
        else
            local hinted = state.stream == "LK" and count >= 500
            if hinted then count = count - 500 end
            local unit = hinted and 10 or 5
            if count > wide.big(state.stream) or pos + unit * count - 1 > #blob then return false end
            local ownBucket = own.buckets[bucket]
            -- (Our fingerprints of a bucket are worked out once per pull: a bucket asked again
            -- in a later list, or a long list, costs the frame nothing more.)
            local cache = state.ownFp
            if not cache then cache = {}; state.ownFp = cache end
            local mine = cache[bucket]
            if not mine then
                mine = {}
                for j = 1, ownBucket.n do mine[rowFp(ownBucket.digests[j], a, b)] = true end
                cache[bucket] = mine
            end
            local ownHints
            for _ = 1, count do
                ordinal = ordinal + 1
                local faction = blob:sub(pos + 4, pos + 4)
                local tag, theirs
                if hinted then
                    tag, theirs = wide.decode(blob:sub(pos + 5, pos + 9))
                    if not tag then return false end
                end
                if not mine[blob:sub(pos, pos + 3)] and (not filter or faction == filter or faction == "?") then
                    local ahead = false
                    if hinted and theirs < wide.killsMax then
                        if ownHints == nil then
                            -- (Past the frame's budget, the rest of the bucket is asked as before.)
                            local cached = state.ownHint and state.ownHint[bucket]
                            if cached then
                                ownHints = cached
                            elseif hintBudget >= ownBucket.n then
                                hintBudget = hintBudget - ownBucket.n
                                ownHints = wide.own(state, bucket, ownBucket, a, b)
                            else
                                ownHints = false
                            end
                        end
                        ahead = ownHints and ownHints[tag] ~= nil and ownHints[tag] > theirs or false
                    end
                    if ahead then
                        skipped = skipped + 1
                    else
                        want[#want + 1] = ordinal
                    end
                end
                pos = pos + unit
            end
            covered[bucket], coveredList[#coveredList + 1] = true, bucket
            listed = listed + count
        end
    end
    -- The answer holds, in order, exactly the asked buckets up to the last one it names; a cut
    -- (cursor) names the next asked bucket, no cut means every asked bucket was answered.
    local askedCount, askedUpTo, nextAsked = 0, 0, nil
    for i in pairs(state.wideAsked) do
        askedCount = askedCount + 1
        if i <= previous then askedUpTo = askedUpTo + 1
        elseif not nextAsked or i < nextAsked then nextAsked = i end
    end
    if previous == 0 or headers ~= askedUpTo
        or (meta.cursor == "-" and askedUpTo ~= askedCount)
        or (meta.cursor ~= "-" and tonumber(meta.cursor) ~= nextAsked) then return false end
    for i in pairs(state.wideAsked) do
        if i <= previous then state.wideTodo[i] = nil end
    end
    for _, i in ipairs(left) do state.wideLeft[#state.wideLeft + 1] = i end
    stats.listed = (stats.listed or 0) + listed
    stats.wanted = (stats.wanted or 0) + #want
    stats.hintSkipped = (stats.hintSkipped or 0) + skipped
    if #want == 0 then wideNext(state); return true end
    state.wideCovered, state.coveredBitmap = covered, encodeBitmap(coveredList)
    state.phase, state.from, state.bitmap = "N", want[1], encodeBitmap(want)
    request(state)
    return true
end

-- V and L answers: fixed-width blobs, compared with our own profile (same salt).
local function applyList8(state, meta, blob)
    if meta.op == "M" then return applyWideList(state, meta, blob) end
    local own = state.profile.streams[state.stream]
    local a, b = saltOf(state.nonce)
    stats.pages = stats.pages + 1
    if meta.op == "V" then
        if meta.rows ~= BUCKETS or #blob ~= BUCKETS * 4 then return false end
        -- A bucket the responder holds nothing of (its fingerprint is the empty
        -- one) teaches nothing: not listed. The walk starts at a random bucket, so
        -- rounds cut short (busy peer, watchdog) do not always leave the same ones.
        local queue, empty = {}, rowFp(0, a, b)
        local start = math.random and math.random(1, BUCKETS) or 1
        for k = 0, BUCKETS - 1 do
            local i = (start + k - 1) % BUCKETS + 1
            local theirs = blob:sub(4 * i - 3, 4 * i)
            if theirs ~= empty and theirs ~= bucketFp(own.buckets[i], a, b, state.factionFilter) then
                queue[#queue + 1] = i
            end
        end
        state.queue, state.qi = queue, 0
        stats.bucketsDiffering = (stats.bucketsDiffering or 0) + #queue
        -- 2.2.2: two buckets or more, from a 2.2.2 neighbour: all at once (see wideStart).
        if #queue >= 2 and wideAllowed(state.peer) then
            wideStart(state, queue)
            return true
        end
        nextBucket8(state)
        return true
    end
    if #blob ~= meta.rows * 5 then return false end
    local bucket, mine = own.buckets[state.bucket], {}
    for j = 1, bucket.n do mine[rowFp(bucket.digests[j], a, b)] = true end
    local filter, want = state.factionFilter, {}
    for i = 1, meta.rows do
        local faction = blob:sub(5 * i, 5 * i)
        if not mine[blob:sub(5 * i - 4, 5 * i - 1)]
            and (not filter or faction == filter or faction == "?") then
            want[#want + 1] = i
        end
    end
    stats.listed = (stats.listed or 0) + meta.rows
    stats.wanted = (stats.wanted or 0) + #want
    -- A list holds at most 812 rows, a bitmap up to 1200: always encodable.
    if #want == 0 then
        state.completed = (state.completed or 0) + 1
        nextBucket8(state)
        return true
    end
    state.phase, state.from, state.bitmap = "G", want[1], encodeBitmap(want)
    request(state)
    return true
end

-- ---------------------------------------------------------------------------
-- 2.5.0: the feed
-- ---------------------------------------------------------------------------
--
-- Without the channel a kill total leaves first-hand for a few contacts, and every other client
-- waits for a pull to bring it: one neighbour at a time, each side building its whole profile
-- first, a hop every 20 s to 2 min. Measured on 36 whole clients (mc_ladder_eq): everybody equal
-- 190 s (median) to 460 s after the last kill, 10 s when the channel carried; during a fight
-- hardly anyone held the true totals.
--
-- A pull now leaves a subscription behind. The requester says so in its nonce (a trailing "f",
-- only toward a peer whose own presence states MIN_RELEASE or later); the responder that takes
-- the pull keeps the requester as a subscriber and, from then on, whispers it the rows of its
-- own ranking that move: a few rows per message ("HB 8:U:<epoch>:<rows>", the pages' kind, lane
-- and byte budget), a message per subscriber every GAP at most. Whoever takes a row that way
-- passes it on to its own subscribers, so a total crosses the faction in a few hands of a few
-- seconds each; a subscriber of the other faction (a Battle.net friend) gets the rows it
-- compares with us, its own filter.
--  * Nothing new is believed. A row of the feed is taken only from a peer we asked ourselves in
--    the last SOURCE_TTL (the peers our pulls go to), through the same code as a row of a page we
--    asked for (OnReceiveLeaderboardKills / Captures under _pagedDelivery): content only, the
--    same result by any route. From anybody else it is dropped, and that sender is told once to
--    stop ("HR 8:X").
--  * A row is the one an attested copy made now would hold (Leaderboard:GetLiveNetworkRow, the
--    pages' own serializers). A player the subscriber already compared with us travels as its
--    name and total ("s"), which the subscriber completes with what it holds; an identity born
--    since travels whole ("k", a v8 kill row with its race; "c", a capture row).
--  * What does not fit (a subscriber's PENDING_MAX, the client's PER_MIN and byte budget, a lost
--    whisper, a row the subscriber cannot complete) is left to the pulls, which go on: closer
--    after a pull that brought rows, further apart once LADDER_FED_SOURCES peers feed us
--    (SyncHistoryCatchup FinishRound, sync:LadderFeedSources).
--  * Only while our channel does not carry (the directory's own rule), never in an instance.
-- A client before MIN_RELEASE never sees any of it: it is not flagged, and reads "HB 8:U" as a
-- page of no pull of its own.
local function feedActive()
    local directory = Overlord.ChannelDirectory
    return directory ~= nil and directory.IsActive ~= nil and directory:IsActive() == true
end
function feed.peerOk(peer)
    local net = Overlord.Relay
    local release = net and net.GetPeerReleaseWithin and net:GetPeerReleaseWithin(peer, feed.RELEASE_AGE)
    local x, y, z = tostring(release or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not x then return false end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    local min = feed.MIN_RELEASE
    if x ~= min[1] then return x > min[1] end
    if y ~= min[2] then return y > min[2] end
    return z >= min[3]
end
-- Do we ask this peer for its feed: it feeds us already, or fewer than SOURCES_MAX peers of our
-- own faction do. A Battle.net friend of the other faction always: it is our only source of
-- that faction's rows, whatever our own side already brings (and it is not counted among them).
function feed.wants(peer)
    if IsOtherFaction(peer) then return true end
    local at, lower, live = GetTime(), peer:lower(), 0
    for name, heardAt in pairs(feed.sources) do
        if at - heardAt <= feed.LIVE_SEC then
            if name == lower then return true end
            if not feed.enemy[name] then live = live + 1 end
        end
    end
    return live < feed.SOURCES_MAX
end
-- A small bounded book (asked, stops): the oldest rows go once it holds `limit`.
function feed.keep(book, counter, lower, at, limit, life)
    if book[lower] == nil then
        if feed[counter] >= limit then
            local count = 0
            for k, t in pairs(book) do
                if at - t > life then book[k] = nil else count = count + 1 end
            end
            if count >= limit then
                -- (The oldest gives way: wiped whole, the book forgot the peers feeding us now.)
                local oldest, oldestAt
                for k, t in pairs(book) do
                    if not oldestAt or t < oldestAt then oldest, oldestAt = k, t end
                end
                if oldest then
                    book[oldest] = nil
                    count = count - 1
                end
            end
            feed[counter] = count
        end
        feed[counter] = feed[counter] + 1
    end
    book[lower] = at
end
local function feedDrop(lower)
    if feed.subs[lower] then
        feed.subs[lower] = nil
        feed.subCount = feed.subCount - 1
    end
end
-- Everything forgotten: an instance, another campaign, the channel carrying again.
function feed.reset()
    feed.subs, feed.subCount, feed.sources, feed.enemy, feed.asked, feed.askedCount = {}, 0, {}, {}, {}, 0
    feed.sourceFights, feed.sourceFightAt = {}, {}
    feed.pinged, feed.intake = {}, {}
    -- (The hour's count of newcomers is kept: leaving an instance must not open it again.)
    feed.inbox, feed.inboxHead, feed.inboxTail, feed.from, feed.captureWaiting = {}, 1, 0, nil, nil
end
local function feedPush(sub, id, at)
    if sub.has[id] then return end
    -- 2.5.2: a killing blow row only for a subscriber that reads them, and only while its queue
    -- is three quarters empty and the feed has used less than 70 % of its messages this minute:
    -- kill rows go first (the stream LB brings the rest in its next sweep).
    local minute = feed.minute
    if id:byte(1) == 98 and (sub.count * 4 >= feed.PENDING_MAX or not carriesKB(sub.name)
        or (GetTime() - minute.at < 60 and minute.count * 10 >= feed.PER_MIN * 7)) then
        stats.feedKBSkipped = (stats.feedKBSkipped or 0) + 1
        return
    end
    if sub.count >= feed.PENDING_MAX then
        stats.feedOverflow = (stats.feedOverflow or 0) + 1
        return
    end
    sub.tail = sub.tail + 1
    sub.queue[sub.tail], sub.has[id], sub.count = id, true, sub.count + 1
    sub.firstAt = sub.firstAt or at
end
local feedArm
-- Leaderboard.OnNetworkRowMoved: the best total of an identity rose (a kill of ours, a K, a
-- page, a row of the feed). O(1) without a subscriber.
function feed.note(stream, dedupKey, born)
    -- (A catch-up pull: nothing of it is news to anybody, see PULL_PASS.)
    if feed.from == "*" then return end
    local at = GetTime()
    -- A ranking put back in one go (a login restoring its save, aliases merged): hundreds of
    -- totals "rise" in one frame and none of them is news. Past BULK_PER_FRAME in one frame the
    -- rest of that frame is not noted (live totals come a few per frame at the very most).
    if feed.bulkAt == at then
        feed.bulkCount = feed.bulkCount + 1
        if feed.bulkCount > feed.BULK_PER_FRAME then return end
    else
        feed.bulkAt, feed.bulkCount = at, 1
    end
    local id = (stream == "LC" and "c" or "k") .. dedupKey
    -- (Only while somebody is fed: a login puts thousands of identities back in one go.)
    if born and stream == "LK" and feed.subCount > 0 then
        if feed.fresh[dedupKey] == nil then
            if feed.freshCount >= feed.FRESH_MAX then feed.fresh, feed.freshCount = {}, 0 end
            feed.freshCount = feed.freshCount + 1
        end
        feed.fresh[dedupKey] = at
    end
    local slot = feed.ringAt % feed.RING + 1
    feed.ringAt = slot
    feed.ring[2 * slot - 1], feed.ring[2 * slot] = id, at
    if feed.subCount == 0 then return end
    -- (Not back to the peer it just came from.)
    local from = feed.from
    if stream == "LC" then
        -- (One timer per identity; a count that moves again meanwhile is read when it leaves.)
        local waiting = feed.captureWaiting
        if not waiting then waiting = { n = 0 }; feed.captureWaiting = waiting end
        if waiting[id] or waiting.n >= feed.CAPTURE_PENDING or not C_Timer or not C_Timer.After then return end
        waiting[id], waiting.n = true, waiting.n + 1
        C_Timer.After(feed.CAPTURE_LINGER, function()
            waiting[id], waiting.n = nil, waiting.n - 1
            if feed.captureWaiting ~= waiting or feed.subCount == 0 then return end
            local later = GetTime()
            for lower, sub in pairs(feed.subs) do
                if lower ~= from then feedPush(sub, id, later) end
            end
            feedArm()
        end)
        return
    end
    for lower, sub in pairs(feed.subs) do
        if lower ~= from then feedPush(sub, id, at) end
    end
    feedArm()
end
lb.OnNetworkRowMoved = feed.note

-- 2.5.2: a killing blow total that rose (KillingBlows: ours, a page row, a feed row). It goes as
-- a row "b" to the subscribers whose presence says capability 11 only (feedRow), never back to
-- the peer it came from, nothing of a catch-up. O(1) without a subscriber. Never in the ring:
-- its slots are the kill rows a new subscriber is handed (the stream LB covers the rest).
function feed.noteKB(dedupKey)
    if feed.from == "*" or type(dedupKey) ~= "string" then return end
    if feed.subCount == 0 then return end
    local at, id = GetTime(), "b" .. dedupKey
    local from = feed.from
    for lower, sub in pairs(feed.subs) do
        if lower ~= from then feedPush(sub, id, at) end
    end
    feedArm()
end
sync._NoteKillingBlowMoved = feed.noteKB

-- The responder's side of a pull flagged "f": its requester becomes (or stays) a subscriber.
-- create: a pull we take (a busy answer only renews).
function feed.subscribe(sender, filter, create)
    if not feedActive() then return false end
    local lower, at = sender:lower(), GetTime()
    local sub = feed.subs[lower]
    if not sub then
        if not create then return false end
        if feed.subCount >= feed.SUBS_MAX then
            -- Room is made of the subscriber renewed longest ago, once it is 5 min old; at once
            -- for a friend of the other faction (we may be its only source of our faction's rows;
            -- a subscriber of our own side has other sources), never of another such friend.
            local crossing = IsOtherFaction(sender)
            local oldest, oldestAt
            for k, row in pairs(feed.subs) do
                if (not oldestAt or row.at < oldestAt) and not (crossing and row.crossing) then oldest, oldestAt = k, row.at end
            end
            if oldest and (crossing or at - oldestAt >= 300) then feedDrop(oldest) end
        end
        if feed.subCount >= feed.SUBS_MAX then
            stats.feedFull = (stats.feedFull or 0) + 1
            return false
        end
        sub = { name = sender, has = {}, whole = {}, queue = {}, head = 1, tail = 0, count = 0, lastAt = -1000,
            crossing = IsOtherFaction(sender) or nil }
        feed.subs[lower] = sub
        feed.subCount = feed.subCount + 1
        stats.feedSubscribed = (stats.feedSubscribed or 0) + 1
        -- What moved since the copy this pull may be served from was made.
        local ring = feed.ring
        for slot = 1, feed.RING do
            local id, movedAt = ring[2 * slot - 1], ring[2 * slot]
            if id and at - movedAt <= feed.RING_SEC then feedPush(sub, id, movedAt) end
        end
    end
    sub.at, sub.epoch = at, epoch()
    if create then
        -- (The requester has just compared with a copy at most RING_SEC old; a word at once
        -- tells it we feed it, rows or not.)
        sub.filter, sub.since, sub.hello, sub.whole = filter, at - feed.RING_SEC, true, {}
        sub.firstAt = sub.firstAt or at
        -- (And the fights going on, if it has not had them from us: a login, a reload.)
        sub.fights = true
    end
    feedArm()
    return true
end

-- Where a player's last kills were made (GuildKillAlert, for a kill total heard or our own; the
-- feed itself, for a row taken with its zone): kept ZONE_SEC, FRESH_MAX players at most. Only
-- a front or a world zone map; nothing while nobody is fed.
function feed.noteZone(name, zoneRef)
    if feed.subCount == 0 or type(zoneRef) ~= "string" or type(name) ~= "string" then return end
    local ref
    if zoneRef:match("^#%d+$") then
        ref = zoneRef
    else
        local fa = Overlord.FrontActivity
        local front = fa and fa.GetFrontIdFromZoneRef and fa:GetFrontIdFromZoneRef(zoneRef)
        ref = front and ("@" .. front) or nil
    end
    if not ref or #ref > feed.ZONE_REF_MAX then return end
    local dedupKey = lb.GetNetworkRowKey and lb:GetNetworkRowKey(name)
    if not dedupKey then return end
    local at = GetTime()
    if feed.zones[dedupKey] == nil then
        if feed.zoneCount >= feed.FRESH_MAX then
            -- (The zones past their life first; emptied whole only if that frees nothing.)
            local kept = 0
            for known, seenAt in pairs(feed.zoneAt) do
                if at - seenAt > feed.ZONE_SEC then
                    feed.zones[known], feed.zoneAt[known] = nil, nil
                else
                    kept = kept + 1
                end
            end
            feed.zoneCount = kept
            if kept >= feed.FRESH_MAX then feed.zones, feed.zoneAt, feed.zoneCount = {}, {}, 0 end
        end
        feed.zoneCount = feed.zoneCount + 1
    end
    feed.zones[dedupKey], feed.zoneAt[dedupKey] = ref, at
end

-- A fight bracket this subscriber holds: we told it, or it told us (64 at most, then afresh).
local function feedFightTold(sub, bracket)
    local told = sub.fightsTold
    if not told or (sub.fightsToldCount or 0) >= 64 then
        told, sub.fightsToldCount = {}, 0
        sub.fightsTold = told
    end
    if not told[bracket] then
        told[bracket] = true
        sub.fightsToldCount = sub.fightsToldCount + 1
    end
end
-- A fight bracket a peer that feeds us holds: it told us, or we told it (64 at most per source).
local function feedSourceHolds(lower, bracket)
    local held = feed.sourceFights[lower]
    if not held or held.n >= 64 then
        held = { n = 0 }
        feed.sourceFights[lower] = held
    end
    if not held[bracket] then held[bracket], held.n = true, held.n + 1 end
end
-- Up the feed: the fresh brackets a source has not told us, to that source. One timer.
local function feedFightsUp()
    feed.upTimer = nil
    if blocked() or not feedActive() then return end
    local fa = Overlord.FrontActivity
    local ok, entries = pcall(function()
        return fa and fa.BuildKillBracketSyncEntries and fa:BuildKillBracketSyncEntries() or nil
    end)
    if not ok or type(entries) ~= "table" or not entries[1] then return end
    local at, net, wireEpoch, again = GetTime(), Overlord.Relay, epoch(), false
    for lower, heardAt in pairs(feed.sources) do
        local route = net and net.peers and net.peers[lower]
        -- (Not a source we feed too: it has them with our own messages to it, feedSend.)
        if at - heardAt <= feed.LIVE_SEC and not feed.subs[lower] and route and net:IsDirectPeer(route.name) then
            local held, untold = feed.sourceFights[lower], nil
            for _, bracket in ipairs(entries) do
                if type(bracket) == "string" and not (held and held[bracket]) and not bracket:find(",", 1, true) then
                    untold = untold or {}
                    if #untold < feed.FIGHT_ROWS then untold[#untold + 1] = bracket else again = true end
                end
            end
            if untold then
                -- (Within the feed's own count of messages a minute.)
                local minute = feed.minute
                if at - minute.at >= 60 then minute.at, minute.count = at, 0 end
                if at - (feed.sourceFightAt[lower] or -1e9) < feed.GAP or minute.count >= feed.PER_MIN then
                    again = true
                elseif sendControl("HR", "8:W:" .. tostring(wireEpoch) .. ":" .. table.concat(untold, ","), route.name) then
                    minute.count = minute.count + 1
                    feed.sourceFightAt[lower] = at
                    for _, bracket in ipairs(untold) do feedSourceHolds(lower, bracket) end
                    stats.feedFightsUp = (stats.feedFightsUp or 0) + #untold
                end
            end
        end
    end
    if again and C_Timer and C_Timer.After then
        feed.upTimer = true
        C_Timer.After(feed.GAP, function() pcall(feedFightsUp) end)
    end
end
-- FrontActivity: a bracket new to us was stored (our own, or one we took). Every subscriber gets
-- it with its next message, at the feed's own pace (GAP per subscriber); the peers that feed us
-- and did not tell it to us get it too (feedFightsUp).
function feed.noteBracket()
    if blocked() or not feedActive() then return end
    if next(feed.sources) ~= nil and not feed.upTimer and C_Timer and C_Timer.After then
        feed.upTimer = true
        C_Timer.After(feed.FIGHT_UP_LINGER, function() pcall(feedFightsUp) end)
    end
    if feed.subCount == 0 then return end
    local at = GetTime()
    for _, sub in pairs(feed.subs) do
        sub.fights = true
        sub.firstAt = sub.firstAt or at
    end
    feedArm()
end
-- "HR 8:W:<epoch>:<brackets>": a subscriber of ours tells us fight brackets. From anybody else
-- nothing is read. Taken through FrontActivity's own acceptance, like a row "f" of the feed.
function feed.fightsUp(payload, sender)
    local wireEpoch, list = payload:match("^8:W:(%d+):(.+)$")
    if not wireEpoch or tonumber(wireEpoch) ~= epoch() or blocked() or not feedActive() then return end
    local sub = feed.subs[sender:lower()]
    if not sub then return end
    -- Anybody may ask us for our ranking and so become a subscriber: a bracket coming up is read
    -- only from one the whisper chain would take a fact from (a contact), a guild mate, or a
    -- Battle.net friend of the other side (the game says who that is).
    local trusted = IsOtherFaction(sender)
    if not trusted then
        local directory, lane = Overlord.ChannelDirectory, Overlord.GuildLane
        local ok, known = pcall(function()
            return (directory and directory.IsContact and directory:IsContact(sender))
                or (lane and lane.IsGuildMate and lane:IsGuildMate(sender)) or false
        end)
        trusted = ok and known == true
    end
    if not trusted then
        stats.feedFightsRefused = (stats.feedFightsRefused or 0) + 1
        return
    end
    local fa, count = Overlord.FrontActivity, 0
    for bracket in (list .. ","):gmatch("([^,]*),") do
        count = count + 1
        if count > feed.FIGHT_ROWS then break end
        if bracket ~= "" then
            feedFightTold(sub, bracket)
            if fa and fa.OnReceiveKillBracket then
                local ok, taken = pcall(fa.OnReceiveKillBracket, fa, bracket, sender, "BETA", true)
                if ok and taken then stats.feedFights = (stats.feedFights or 0) + 1 end
            end
        end
    end
end

-- One row for one subscriber: its text, or nil (nothing to send for it), or nil, true (the
-- indexes are being rebuilt: asked again later).
local function feedRow(sub, id, wireEpoch)
    if id:sub(1, 1) == "b" then
        -- A killing blow total: only to a subscriber that reads it, of its faction when it filters.
        local blows, dedupKey = Overlord.KillingBlows, id:sub(2)
        if not blows or not carriesKB(sub.name) then return nil end
        local data = blows:Data()
        local count = data and tonumber(data.counts[dedupKey])
        if not count or count <= 0 then return nil end
        -- (Named as the ranking names it, with its metadata and within its honorable kills: the
        -- spelling a peer first sent may hold no profile, so no faction to filter on.)
        local name, hk, info = lb:GetLiveNetworkRow("LK", dedupKey)
        if not name then
            if inCombat() then return nil, true end
            return nil, lb.EnsureNetworkHotIndexesPrepared ~= nil and lb:EnsureNetworkHotIndexesPrepared() ~= true
        end
        if sub.filter then
            local faction = type(info) == "table" and info.faction
            faction = faction == "Alliance" and "A" or faction == "Horde" and "H" or "?"
            if faction ~= sub.filter and faction ~= "?" then return nil end
        end
        return "b" .. name .. ":" .. string.format("%d", math.min(count, hk))
    end
    local stream, dedupKey = id:sub(1, 1) == "c" and "LC" or "LK", id:sub(2)
    local name, count, info = lb:GetLiveNetworkRow(stream, dedupKey)
    if not name then
        -- (In a fight the indexes are not rebuilt for this: asked again once it is over.)
        if inCombat() then return nil, true end
        return nil, lb.EnsureNetworkHotIndexesPrepared ~= nil and lb:EnsureNetworkHotIndexesPrepared() ~= true
    end
    if not info then return nil end
    -- (The subscriber told us this total itself while the row waited: feedApply. Its mark goes
    -- when the row leaves the queue, consume in feedSend: a row walked and kept is walked again.)
    local told = sub.told and sub.told[id]
    if told and stream == "LK" and (tonumber(count) or math.huge) <= told then return nil end
    local faction = info.faction == "Alliance" and "A" or info.faction == "Horde" and "H" or "?"
    if sub.filter and faction ~= sub.filter and faction ~= "?" then return nil end
    local snap = feed.scratch
    snap.playerInfo[name] = info
    local payload, row
    if stream == "LK" then
        snap.kills[name] = count
        payload = sync:BuildPagedLeaderboardKillPayload(snap, name, wireEpoch)
        snap.kills[name] = nil
        local compact = payload and compactRow8("LK", payload, wireEpoch)
        if compact then
            local born = feed.fresh[dedupKey]
            if born and born >= sub.since and not sub.whole[dedupKey] then
                local race = raceField(snap, name, payload)
                row = "k" .. (race and (compact .. ":" .. race) or compact)
            else
                local short, kills = compact:match("^([^:]+):(%d+):")
                row = short and ("s" .. short .. ":" .. kills) or nil
            end
        end
    else
        snap.captureCount[name], snap.captures[name] = count, lb.captures and lb.captures[name] or nil
        payload = sync:BuildPagedLeaderboardCapturePayload(snap, name, wireEpoch)
        snap.captureCount[name], snap.captures[name] = nil, nil
        local compact = payload and compactRow8("LC", payload, wireEpoch)
        row = compact and ("c" .. compact) or nil
    end
    snap.playerInfo[name] = nil
    return row
end

-- One message to one subscriber. Rows leave the queue only once the relay took the message.
local function feedSend(sub, at)
    local minute = feed.minute
    if at - minute.at >= 60 then minute.at, minute.count = at, 0 end
    if minute.count >= feed.PER_MIN then
        stats.feedCapped = (stats.feedCapped or 0) + 1
        return false
    end
    local net = Overlord.Relay
    if net and net.CanSendLeaderboardPage and not net:CanSendLeaderboardPage() then return false end
    -- (The bytes first: a message built and then held back for want of them was built again
    -- every second under load.)
    feed.tokens = math.min(feed.BURST, feed.tokens + math.max(0, at - feed.refillAt) * feed.RATE)
    feed.refillAt = at
    if feed.tokens < 212 + feed.BLOB then return false end
    local wireEpoch = epoch()
    -- The rows fill whole whispers. Through the relay a message leaves in pieces of 200 bytes, its
    -- header in the first one: 228 bytes of rows made two whispers, the second half empty as often
    -- as not (bench, 310 whole clients: 20 second pieces for 25 messages a minute on the clients
    -- feeding 8 subscribers, two thirds of all they sent). `first` bytes of rows fit the first
    -- whisper and `piece` each further one, PIECES whispers at most; a last whisper that would
    -- leave less than FILL full is not sent, its rows wait for this subscriber's next message.
    local first, piece, limit = feed.BLOB, 0, feed.BLOB
    -- (Only what the relay takes: SendWhisper hands it the message for a peer of its own.)
    if net and net.PayloadRoom and net.IsPeer and net:IsPeer(sub.name) then
        local room, chunk = net:PayloadRoom("HB", sub.name, 1)
        room = room - (5 + #tostring(wireEpoch))
        if room >= 60 then
            first, piece = room, chunk
            limit = first + (feed.PIECES - 1) * piece
        end
    end
    local function whispers(size)
        if piece <= 0 or size <= first then return 1 end
        return 1 + math.ceil((size - first) / piece)
    end
    -- (Room kept for the fight brackets waiting for this subscriber.)
    if sub.fights and limit > 2 * feed.FIGHT_ROOM then limit = limit - feed.FIGHT_ROOM end
    local parts, bytes, index = {}, 0, sub.head
    -- (The newcomers whose whole row is in this message: their next totals travel short, once
    -- the message has left. A whole row that could not be built yet is no such thing.)
    local wholes = {}
    -- (Where the message stood before the row that opened its last whisper.)
    local cutIndex, cutParts, cutWholes, cutBytes = index, 0, 0, 0
    local rowsMax = feed.ROWS_MAX - (sub.fights and feed.FIGHT_ROWS or 0)
    -- (zoneOf: the zone of each row kept; zoneSeen: the zones whose marker is counted.)
    local zoneOf, zoneSeen, zoned = {}, {}, false
    while index <= sub.tail and #parts < rowsMax do
        local id = sub.queue[index]
        local row, wait = feedRow(sub, id, wireEpoch)
        if wait then
            sub.waits = (sub.waits or 0) + 1
            if sub.waits <= feed.WAIT_MAX then break end
            row = nil
        end
        if row then
            local encoded = tostring(#row) .. ":" .. row
            local kind, zone, marker = row:sub(1, 1), nil, 0
            if kind == "s" or kind == "k" then
                local dedupKey = id:sub(2)
                zone = feed.zones[dedupKey]
                if zone and at - (feed.zoneAt[dedupKey] or -1e9) > feed.ZONE_SEC then zone = nil end
                -- (Its marker: length prefix, "z" and the zone, once per zone in a message.)
                if zone and not zoneSeen[zone] then marker = #tostring(#zone + 1) + 2 + #zone end
            end
            -- (A row too long for any message is left to the pulls.)
            if bytes + #encoded + marker > limit then
                if #encoded + marker <= limit then break end
            else
                if bytes > 0 and whispers(bytes + #encoded + marker) > whispers(bytes) then
                    cutIndex, cutParts, cutWholes, cutBytes = index, #parts, #wholes, bytes
                end
                parts[#parts + 1], bytes = encoded, bytes + #encoded + marker
                if zone then zoneOf[#parts], zoneSeen[zone], zoned = zone, true, true end
                if kind == "k" then wholes[#wholes + 1] = id:sub(2) end
            end
        end
        index = index + 1
    end
    local pieces = whispers(bytes)
    if pieces > 1 and cutParts > 0 and bytes - first - (pieces - 2) * piece < feed.FILL * piece then
        for i = #parts, cutParts + 1, -1 do parts[i] = nil end
        for i = #wholes, cutWholes + 1, -1 do wholes[i] = nil end
        index, bytes, pieces = cutIndex, cutBytes, pieces - 1
        stats.feedHeldBack = (stats.feedHeldBack or 0) + 1
    end
    local function consume()
        for i = sub.head, index - 1 do
            local id = sub.queue[i]
            sub.queue[i], sub.has[id], sub.count = nil, nil, sub.count - 1
            if sub.told and sub.told[id] then
                sub.told[id], sub.toldCount = nil, math.max(0, (sub.toldCount or 1) - 1)
                stats.feedEchoSkipped = (stats.feedEchoSkipped or 0) + 1
            end
        end
        if index > sub.head then sub.waits = nil end
        sub.head = index
        if sub.head > sub.tail then sub.queue, sub.head, sub.tail = {}, 1, 0 end
        sub.firstAt = sub.count > 0 and at or nil
    end
    local rowCount = #parts
    -- The rows of one zone together behind its marker (those without a zone first: a marker
    -- holds for every kill row after it in the message).
    if zoned then
        local ordered, groups, order = {}, {}, {}
        for i = 1, rowCount do
            local zone = zoneOf[i]
            if not zone then
                ordered[#ordered + 1] = parts[i]
            else
                local group = groups[zone]
                if not group then
                    group = {}
                    groups[zone] = group
                    order[#order + 1] = zone
                end
                group[#group + 1] = parts[i]
            end
        end
        for _, zone in ipairs(order) do
            ordered[#ordered + 1] = tostring(#zone + 1) .. ":z" .. zone
            for _, part in ipairs(groups[zone]) do ordered[#ordered + 1] = part end
        end
        parts = ordered
    end
    -- The fights: the fresh brackets this subscriber has neither had from us nor told us.
    local fights, fightsLeft = nil, false
    if sub.fights then
        local fa = Overlord.FrontActivity
        local ok, entries = pcall(function()
            return fa and fa.BuildKillBracketSyncEntries and fa:BuildKillBracketSyncEntries() or nil
        end)
        if ok and type(entries) == "table" then
            for _, bracket in ipairs(entries) do
                if type(bracket) == "string" and not (sub.fightsTold and sub.fightsTold[bracket]) then
                    local encoded = tostring(#bracket + 1) .. ":f" .. bracket
                    local size = bytes + #encoded
                    if (fights and #fights or 0) < feed.FIGHT_ROWS and rowCount + (fights and #fights or 0) < feed.ROWS_MAX
                        and ((piece > 0 and whispers(size) <= feed.PIECES) or (piece <= 0 and size <= first)) then
                        fights = fights or {}
                        fights[#fights + 1] = bracket
                        parts[#parts + 1], bytes = encoded, size
                    else
                        fightsLeft = true
                    end
                end
            end
        end
        if not fights and not fightsLeft then sub.fights = nil end
        pieces = whispers(bytes)
    end
    if #parts == 0 and not sub.hello then
        -- Nothing of the walked rows is for this subscriber (its filter, rows gone meanwhile).
        consume()
        if sub.fights then sub.firstAt = sub.firstAt or at end
        return false
    end
    local payload = "8:U:" .. tostring(wireEpoch) .. ":" .. table.concat(parts)
    -- (Every whisper of the message is paid for: its bytes and what carries them.)
    local cost = #payload + 200 + 110 * (pieces - 1)
    if sync:SendWhisper("HB", payload, sub.name) == false then
        stats.feedSendsRefused = (stats.feedSendsRefused or 0) + 1
        -- (Offered again in a few seconds; nothing left the queue.)
        sub.lastAt = at - feed.GAP + 3
        return false
    end
    feed.tokens = feed.tokens - cost
    stats.bytes = stats.bytes + cost
    stats.feedSent = (stats.feedSent or 0) + 1
    stats.feedRowsSent = (stats.feedRowsSent or 0) + rowCount
    stats.feedWhispers = (stats.feedWhispers or 0) + pieces
    minute.count = minute.count + 1
    sub.lastAt, sub.hello = at, nil
    for _, dedupKey in ipairs(wholes) do sub.whole[dedupKey] = true end
    consume()
    if fights then
        for _, bracket in ipairs(fights) do feedFightTold(sub, bracket) end
        stats.feedFightsSent = (stats.feedFightsSent or 0) + #fights
        if not fightsLeft then sub.fights = nil end
    end
    if sub.fights then sub.firstAt = sub.firstAt or at end
    return true
end

local function feedTick()
    feed.timer = nil
    if feed.subCount == 0 then return end
    if blocked() or not feedActive() then feed.reset() return end
    local at, net, wireEpoch = GetTime(), Overlord.Relay, epoch()
    local due, waiting, unreached = nil, false, false
    for lower, sub in pairs(feed.subs) do
        if at - sub.at > feed.SUB_TTL or sub.epoch ~= wireEpoch then
            feedDrop(lower)
        elseif sub.count > 0 or sub.hello or sub.fights then
            -- A subscriber not heard for five minutes has no direct route (the relay would refuse
            -- the message): its rows wait, PENDING_MAX at most, until it speaks again or its
            -- subscription ends. (Dropped at once, it stayed unfed until its next pull came round.)
            if not (net and net.IsDirectPeer and net:IsDirectPeer(sub.name)) then
                unreached = true
            else
                waiting = true
                if at >= math.max(sub.lastAt + feed.GAP, (sub.firstAt or at) + feed.LINGER)
                    and (not due or sub.lastAt < due.lastAt) then
                    due = sub
                end
            end
        end
    end
    if due then feedSend(due, at) end
    if waiting then
        feedArm()
    elseif unreached and not feed.timer and C_Timer and C_Timer.After then
        -- (Looked at again every 15 s, not every second, while only unreached subscribers wait.)
        feed.timer = true
        C_Timer.After(15, function()
            local ok, err = pcall(feedTick)
            if not ok then
                feed.timer = nil
                stats.feedError = tostring(err)
            end
        end)
    end
end
feedArm = function()
    if feed.timer or not C_Timer or not C_Timer.After then return end
    feed.timer = true
    C_Timer.After(1, function()
        local ok, err = pcall(feedTick)
        if not ok then
            feed.timer = nil
            stats.feedError = tostring(err)
        end
    end)
end

-- "HR 8:K:<epoch>": a subscriber of ours is still there (and the relay has just heard it): its
-- subscription goes on, and a word of ours tells it so, with the rows waiting if any. From
-- anybody else nothing happens: it finds out by our silence and asks again by a pull.
function feed.kept(payload, sender)
    if tonumber(payload:match("^8:K:(%d+)$")) ~= epoch() or blocked() or not feedActive() then return end
    local sub = feed.subs[sender:lower()]
    if not sub then return end
    sub.at, sub.hello = GetTime(), true
    sub.firstAt = sub.firstAt or sub.at
    feedArm()
end
-- The subscriber's side: one word per source every KEEP_SEC, while it feeds us.
local function feedKeepTick()
    feed.keepTimer = nil
    if blocked() or not feedActive() then return end
    local at, net, wireEpoch, any = GetTime(), Overlord.Relay, epoch(), false
    for lower, heardAt in pairs(feed.sources) do
        if at - heardAt <= feed.LIVE_SEC then
            any = true
            local route = net and net.peers and net.peers[lower]
            if at - (feed.pinged[lower] or heardAt) >= feed.KEEP_SEC and route and net:IsDirectPeer(route.name) then
                feed.pinged[lower] = at
                if sendControl("HR", "8:K:" .. tostring(wireEpoch), route.name) then
                    stats.feedKeeps = (stats.feedKeeps or 0) + 1
                end
            end
        else
            feed.sources[lower], feed.enemy[lower], feed.pinged[lower], feed.intake[lower] = nil, nil, nil, nil
            feed.sourceFights[lower], feed.sourceFightAt[lower] = nil, nil
        end
    end
    if any and C_Timer and C_Timer.After then
        feed.keepTimer = true
        C_Timer.After(20, function() pcall(feedKeepTick) end)
    end
end

-- "HR 8:X:<epoch>": this peer does not take our feed (it asked nothing lately, a /reload).
function feed.stop(payload, sender)
    if tonumber(payload:match("^8:X:(%d+)$")) ~= epoch() then return end
    local lower = sender:lower()
    if feed.subs[lower] then
        feedDrop(lower)
        stats.feedStopped = (stats.feedStopped or 0) + 1
    end
end

-- One received row, through the acceptance of a page row we asked this peer for.
local function feedApply(item)
    local wireEpoch = epoch()
    local kind, body = item.row:sub(1, 1), item.row:sub(2)
    local stream, payload
    if kind == "b" then
        -- A killing blow total (2.5.2): KillingBlows' own acceptance, as a page row of the stream.
        local blows = Overlord.KillingBlows
        if not blows then return end
        local revision = blows.revision
        feed.from = item.sender:lower()
        local ok, accepted = pcall(blows.MergeRow, blows, body, item.sender)
        feed.from = nil
        if not ok then stats.feedError = tostring(accepted) return end
        if blows.revision ~= revision then stats.kbChanged = (stats.kbChanged or 0) + 1 end
        if accepted then stats.feedKB = (stats.feedKB or 0) + 1
        else stats.feedRejected = (stats.feedRejected or 0) + 1 end
        return
    end
    if kind == "f" then
        -- A fight bracket: FrontActivity's own acceptance (a known front or zone, a listed
        -- bracket, a slot of the last five minutes, its budgets per sender), as from the relay.
        -- A peer that feeds us and that we feed holds it: not told back.
        local sub = feed.subs[item.sender:lower()]
        if sub then feedFightTold(sub, body) end
        feedSourceHolds(item.sender:lower(), body)
        local fa = Overlord.FrontActivity
        if fa and fa.OnReceiveKillBracket then
            local ok, taken = pcall(fa.OnReceiveKillBracket, fa, body, item.sender, "BETA", true)
            if ok and taken then stats.feedFights = (stats.feedFights or 0) + 1 end
        end
        return
    end
    if kind == "s" then
        local name, kills = body:match("^([^:]+):(%d+)$")
        -- (A total above the global ceiling is refused, as a page row holding it is: completing
        -- the row here would otherwise clamp it to the ceiling and take it.)
        kills = integer(kills, 1, tonumber(Overlord.PLAUSIBLE_SYNC_KILL_CEILING) or 15000)
        local dedupKey = kills and lb.GetNetworkRowKey and lb:GetNetworkRowKey(name)
        if not dedupKey then stats.feedBad = (stats.feedBad or 0) + 1 return end
        local canonical, count, info = lb:GetLiveNetworkRow("LK", dedupKey)
        if not canonical then
            -- (Indexes being rebuilt: the row as it is stored.)
            count, info = tonumber(lb.kills and lb.kills[name]), lb.playerInfo and lb.playerInfo[name]
            canonical = count and type(info) == "table" and name or nil
        end
        -- Unknown here: not ours to complete. The next pull brings it whole.
        if not canonical or not info then stats.feedUnknown = (stats.feedUnknown or 0) + 1 return end
        if kills <= count then
            stats.feedKnown = (stats.feedKnown or 0) + 1
            -- This source holds the very total we hold: when it is our subscriber too (two peers
            -- that asked each other), the row waiting for it would tell it nothing (feedRow).
            local sub = kills == count and feed.subs[item.sender:lower()] or nil
            local id = sub and ("k" .. dedupKey)
            if sub and sub.has[id] then
                -- (Bounded: a row that left its queue without being read here keeps its entry.)
                if (sub.toldCount or 0) >= 2 * feed.PENDING_MAX then sub.told, sub.toldCount = nil, 0 end
                sub.told = sub.told or {}
                if sub.told[id] == nil then sub.toldCount = (sub.toldCount or 0) + 1 end
                sub.told[id] = kills
            end
            return
        end
        -- (Above what the level we hold allows: the level moved at the sender. Completed here the
        -- total would be clamped and differ from the sender's: the next pull brings the whole row.)
        if sync.MaxPlausibleKillsForLevel and kills > sync:MaxPlausibleKillsForLevel(info.level) then
            stats.feedUnknown = (stats.feedUnknown or 0) + 1
            return
        end
        local snap = feed.scratch
        snap.playerInfo[canonical], snap.kills[canonical] = info, kills
        stream, payload = "LK", sync:BuildPagedLeaderboardKillPayload(snap, canonical, wireEpoch)
        snap.playerInfo[canonical], snap.kills[canonical] = nil, nil
        if not payload then stats.feedUnknown = (stats.feedUnknown or 0) + 1 return end
    elseif kind == "k" then
        stream, payload = "LK", expandRow8("LK", body, wireEpoch)
    elseif kind == "c" then
        stream, payload = "LC", expandRow8("LC", body, wireEpoch)
    end
    local name = payload and payload:match("^([^:]+):")
    local identity = name and key(name)
    if not identity then stats.feedBad = (stats.feedBad or 0) + 1 return end
    -- A player our ranking does not hold yet: within the hour's budget (NEW_PER_SOURCE, NEW_PER_HOUR).
    if kind ~= "s" and sync.IsKnownLeaderboardSubject and not sync:IsKnownLeaderboardSubject(name) then
        local book, at, source = feed.newcomers, GetTime(), item.sender:lower()
        if at - book.at >= 3600 then book.at, book.total, book.by = at, 0, {} end
        if book.total >= feed.NEW_PER_HOUR or (book.by[source] or 0) >= feed.NEW_PER_SOURCE then
            stats.feedOverBudget = (stats.feedOverBudget or 0) + 1
            return
        end
        book.total, book.by[source] = book.total + 1, (book.by[source] or 0) + 1
    end
    if sync.SenderBurstShouldDrop and sync:SenderBurstShouldDrop(item.sender, stream) then
        stats.deferred = stats.deferred + 1
        return
    end
    local net, previous = Overlord.Relay, nil
    if net then previous = net.context; net.context = item.context end
    sync._pagedDelivery = { kind = stream, sender = item.sender, channel = item.channel, key = identity }
    local receive = stream == "LK" and sync.OnReceiveLeaderboardKills or sync.OnReceiveLeaderboardCaptures
    local revision = lb._snapshotRevision
    feed.from = item.sender:lower()
    local ok, accepted = pcall(receive, sync, payload, item.sender, item.channel)
    feed.from = nil
    sync._pagedDelivery = nil
    if net then net.context = previous end
    if not ok then stats.feedError = tostring(accepted) return end
    local changed = lb._snapshotRevision ~= revision
    if changed then stats.feedChanged = (stats.feedChanged or 0) + 1 end
    if accepted then stats.feedRows = (stats.feedRows or 0) + 1
    else stats.feedRejected = (stats.feedRejected or 0) + 1 end
    -- A kill total we took, with the zone of its kills: the size of that fight counts them (the
    -- base of a live total heard from the same player is the same one: nothing twice), and the
    -- zone goes on with the row to our own subscribers.
    if accepted and changed and stream == "LK" and item.zone then
        local total = tonumber(payload:match("^[^:]+:(%d+):"))
        -- (What our ranking took, when it took less than the row said: Sync bounds a total.)
        local ok, _, held = pcall(lb.GetLiveNetworkRow, lb, "LK", lb.GetNetworkRowKey and lb:GetNetworkRowKey(name) or identity)
        held = ok and tonumber(held) or tonumber(lb.kills and lb.kills[name])
        if total and held and held < total then total = held end
        local alerts = Overlord.GuildKillAlert
        if total and alerts and alerts.OnFedKill then
            pcall(alerts.OnFedKill, alerts, name, total, item.zone, wireEpoch)
            stats.feedZoned = (stats.feedZoned or 0) + 1
        end
        feed.noteZone(name, item.zone)
    end
end
local function feedDrain()
    feed.draining = nil
    if blocked() then feed.inbox, feed.inboxHead, feed.inboxTail = {}, 1, 0 return end
    local inbox, wireEpoch = feed.inbox, epoch()
    local sliceAt = debugprofilestop and debugprofilestop() or 0
    -- (In a fight too, like a live total: two rows a frame.)
    for _ = 1, inCombat() and 2 or 4 do
        local item = inbox[feed.inboxHead]
        if not item then feed.inbox, feed.inboxHead, feed.inboxTail = {}, 1, 0 return end
        inbox[feed.inboxHead] = nil
        feed.inboxHead = feed.inboxHead + 1
        if item.epoch == wireEpoch then feedApply(item) end
        if debugprofilestop and debugprofilestop() - sliceAt >= 1 then break end
    end
    if feed.inbox[feed.inboxHead] then
        feed.draining = true
        C_Timer.After(0.001, feed.drainSafely)
    else
        feed.inbox, feed.inboxHead, feed.inboxTail = {}, 1, 0
    end
end
-- (One function for every frame of a drain: an error ends that drain, not the feed.)
function feed.drainSafely()
    local ok, err = pcall(feedDrain)
    if not ok then
        feed.draining = nil
        stats.feedError = tostring(err)
    end
end
-- "HB 8:U:<epoch>:<rows>" from a direct neighbour (allowed() passed).
function feed.receive(payload, sender, channel)
    local wireEpoch, blob = payload:match("^8:U:(%d+):(.*)$")
    if not wireEpoch or tonumber(wireEpoch) ~= epoch() or blocked() then return end
    local lower, at = sender:lower(), GetTime()
    local asked, feeding = feed.asked[lower], feed.sources[lower]
    -- Asked lately (its first word), or feeding us now (kept alive by our own word, feedKeepTick).
    if not ((asked and at - asked <= feed.SOURCE_TTL) or (feeding and at - feeding <= feed.LIVE_SEC)) then
        stats.feedRefused = (stats.feedRefused or 0) + 1
        if at - (feed.stops[lower] or -1e9) >= feed.STOP_GAP then
            feed.keep(feed.stops, "stopCount", lower, at, 64, feed.STOP_GAP)
            sendControl("HR", "8:X:" .. tostring(epoch()), sender)
        end
        return
    end
    feed.sources[lower] = at
    feed.enemy[lower] = IsOtherFaction(sender) or nil
    feed.pinged[lower] = feed.pinged[lower] or at
    stats.feedReceived = (stats.feedReceived or 0) + 1
    if not feed.keepTimer and C_Timer and C_Timer.After then
        feed.keepTimer = true
        C_Timer.After(20, function() pcall(feedKeepTick) end)
    end
    local intake = feed.intake[lower]
    if not intake or at - intake.at >= 60 then
        intake = { at = at, rows = 0 }
        feed.intake[lower] = intake
    end
    local inbox, context = feed.inbox, Overlord.Relay and Overlord.Relay.context or nil
    local pos, rows, numericEpoch, zone = 1, 0, epoch(), nil
    while pos <= #blob and rows < feed.PARSE_MAX do
        local prefix, stop = blob:match("^(%d+)():", pos)
        local length = prefix and #prefix <= 3 and integer(prefix, 2, 250)
        if not length then break end
        local row = blob:sub(stop + 1, stop + length)
        if #row ~= length then break end
        pos, rows = stop + 1 + length, rows + 1
        local kind = row:sub(1, 1)
        if kind == "z" then
            -- The zone of the kill rows that follow in this message (anything else: none).
            local ref = row:sub(2)
            zone = #ref <= feed.ZONE_REF_MAX and (ref:match("^@[%w_%-]+$") or ref:match("^#%d+$")) or nil
        elseif length < 3 then
            break
        elseif intake.rows >= feed.ROWS_PER_MIN then
            intake.rows = intake.rows + 1
            stats.feedOverflow = (stats.feedOverflow or 0) + 1
        elseif kind == "b" and (feed.inboxTail - feed.inboxHead + 1) * 2 >= feed.INBOX_MAX then
            -- (2.5.2: a killing blow row never takes the second half of the inbox from kill rows;
            -- the stream LB brings it in its next sweep.)
            stats.feedKBSkipped = (stats.feedKBSkipped or 0) + 1
        elseif feed.inboxTail - feed.inboxHead + 1 < feed.INBOX_MAX then
            intake.rows = intake.rows + 1
            -- (Its own tail: the rows already read are emptied from the front, and # of such a
            -- table is anybody's guess. A second message arriving while the first was being read
            -- wrote its rows under the head, never read.)
            feed.inboxTail = feed.inboxTail + 1
            inbox[feed.inboxTail] = { row = row, sender = sender, channel = channel, context = context, epoch = numericEpoch,
                zone = (kind == "s" or kind == "k") and zone or nil }
        else
            intake.rows = intake.rows + 1
            stats.feedOverflow = (stats.feedOverflow or 0) + 1
        end
    end
    if inbox[feed.inboxHead] and not feed.draining then
        feed.draining = true
        C_Timer.After(0.001, feed.drainSafely)
    end
end

-- How many peers feed us now: asked lately, heard on the feed in the last LIVE_SEC, still direct
-- neighbours (SyncHistoryCatchup: the rounds rest longer with enough of them).
function sync:LadderFeedSources()
    if not feedActive() then return 0 end
    local at, net, count = GetTime(), Overlord.Relay, 0
    for lower, heardAt in pairs(feed.sources) do
        if at - heardAt > feed.LIVE_SEC then
            feed.sources[lower], feed.enemy[lower], feed.pinged[lower] = nil, nil, nil
            feed.sourceFights[lower], feed.sourceFightAt[lower] = nil, nil
        elseif net and net.peers and net.peers[lower] and net:IsDirectPeer(net.peers[lower].name) then
            count = count + 1
        end
    end
    return count
end

-- The neighbour table keeps the peer of our running pull and of the session we
-- serve (SyncRelay remember): their replies stay routed however busy the
-- channel is. lowerName is the table key (lower-case full name).
function sync:IsPagedSessionPeer(lowerName)
    if pull and type(pull.peer) == "string" and pull.peer:lower() == lowerName then return true end
    return serving ~= nil and type(serving.peer) == "string" and serving.peer:lower() == lowerName
        and GetTime() - (tonumber(serving.at) or 0) <= 300
end

function sync:IsExpectedPagedLeaderboardDelivery(kind, name, sender, channel)
    local delivery = self._pagedDelivery
    return delivery and kind == delivery.kind and delivery.sender == sender
        and delivery.channel == channel and delivery.key == key(name)
end

tryApply = function(state)
    local meta = state.meta
    if not meta or state.applying then return end
    for i = 1, meta.parts do if not state.parts[i] then return end end
    local blob = table.concat(state.parts)
    if #blob > 4064 or hash(blob) ~= meta.hash then
        -- A corrupt copy must not poison the slot and reject a correct retry.
        state.parts, state.bytes, state.partCount, state.meta = {}, 0, nil, nil
        return
    end
    local v8 = state.wire == "8"
    if v8 then
        -- A v8 answer is consumed once: a duplicate fragment arriving while the next
        -- request waits (combat) must not apply it again and skip a step.
        state.parts, state.bytes, state.partCount, state.meta = {}, 0, nil, nil
    end
    if v8 and meta.op ~= "G" and meta.op ~= "T" and meta.op ~= "N" then
        applyList8(state, meta, blob)
        return
    end
    -- v8 rows are a subset of the bucket in key order; their cursor is an index. The
    -- G pages of one bucket follow each other in key order too (gLast): a page that
    -- repeats rows already given in this bucket is refused.
    local first = ""
    if not v8 and state.cursor ~= "-" then first = state.cursor
    elseif v8 and meta.op == "G" then first = state.gLast or "" end
    local rows, pos, last = {}, 1, first
    -- (A wide page walks its buckets in index order, the keys of each in order.)
    local lastBucket, lastKey = state.nLastBucket or 0, state.nLastKey or ""
    for i = 1, meta.rows do
        local prefix, stop = blob:match("^(%d+)():", pos)
        -- Lua's ^ anchor is relative to init for string.find/match in 5.1.
        local maxRowBytes = state.extended and state.stream == "LC" and 3500 or 250
        local length = prefix and #prefix <= (maxRowBytes > 999 and 4 or 3)
            and integer(prefix, 1, maxRowBytes)
        if not length then return end
        pos = stop + 1
        local payload = blob:sub(pos, pos + length - 1)
        if #payload ~= length then return end
        pos = pos + length
        local name = payload:match("^([^:]+):")
        local identity = name and key(name)
        if meta.op == "T" then
            -- Rank order: no key order or bucket to check, but never the same player
            -- twice in the whole top (a looping responder gets nothing applied).
            if not identity or state.topSeen[identity] then return end
            for j = 1, #rows do if rows[j].key == identity then return end end
        elseif meta.op == "N" then
            -- Only the buckets listed in the answer to our M, ascending, no key twice.
            local at = identity and (hash(identity) % BUCKETS + 1)
            if not at or not state.wideCovered or not state.wideCovered[at]
                or at < lastBucket or (at == lastBucket and identity <= lastKey) then return end
            lastBucket, lastKey = at, identity
        elseif not identity or identity <= last or hash(identity) % BUCKETS + 1 ~= state.bucket then
            return
        end
        rows[#rows + 1] = { key = identity, payload = payload }
        last = identity
    end
    if pos ~= #blob + 1 or (meta.cursor ~= "-" and ((meta.rows == 0 and meta.op ~= "T") or (not v8
        and ((not state.extended and meta.rows ~= PAGE_ROWS) or meta.cursor ~= last)))) then return end
    if meta.op == "T" then
        for j = 1, #rows do state.topSeen[rows[j].key] = true end
        state.topApplied = state.topApplied + #rows
    elseif v8 and meta.op == "N" then
        state.nLastBucket, state.nLastKey = lastBucket, lastKey
    elseif v8 and #rows > 0 then
        state.gLast = rows[#rows].key
    end
    state.applying = true
    local index = 1
    local function apply()
        if pull ~= state then return end
        if state.epoch ~= epoch() then state.why = "campaign changed"; finish(state, false); return end
        if paused() then C_Timer.After(2, apply); return end
        local sliceAt = debugprofilestop and debugprofilestop() or 0
        for _ = 1, 4 do
            local row = rows[index]
            if not row then
                state.applying = nil
                if meta.op == "T" then nextTop8(state, meta.cursor)
                elseif meta.op == "N" then nextWideRows(state, meta.cursor)
                elseif v8 then nextRows8(state, meta.cursor)
                else nextPage(state, meta.cursor) end
                return
            end
            local kind = state.stream or "LK"
            if sync.SenderBurstShouldDrop and sync:SenderBurstShouldDrop(state.peer, kind) then
                -- A temporary live-traffic limit is not a rejected score. Keep
                -- this row and the bucket checkpoint until it can be applied.
                -- Bound the wait so a busy peer cannot pin this session forever.
                state.applyBlockedAt = state.applyBlockedAt or GetTime()
                stats.deferred = stats.deferred + 1
                if GetTime() - state.applyBlockedAt >= 30 then
                    state.why = "burst limit"
                    finish(state, false)
                else
                    C_Timer.After(1, apply)
                end
                return
            end
            state.applyBlockedAt = nil
            -- v8: the standard row is rebuilt with our epoch (see compactRow8);
            -- a malformed row is refused like any invalid row, the page goes on.
            local payload = row.payload
            if v8 then payload = expandRow8(kind, payload, state.epoch) end
            local ok, accepted = true, false
            if payload then
                local net, previous = Overlord.Relay, nil
                if net then previous = net.context; net.context = state.context end
                sync._pagedDelivery = { kind = kind, sender = state.peer,
                    channel = state.channel, key = row.key }
                local receive = kind == "LK" and sync.OnReceiveLeaderboardKills
                    or kind == "LC" and sync.OnReceiveLeaderboardCaptures
                    or kind == "LB" and sync._ReceiveKillingBlowRow
                    or sync.OnReceiveLeaderboardRace
                local revision = lb._snapshotRevision
                local blows = Overlord.KillingBlows
                local kbRevision = blows and blows.revision
                -- (The feed does not send a row back to the peer it came from, nor the rows of a
                -- catch-up to anybody: PULL_PASS.)
                feed.from = (state.pullChanged or 0) >= feed.PULL_PASS and "*" or state.peer:lower()
                ok, accepted = pcall(receive, sync, payload, state.peer, state.channel)
                feed.from = nil
                if lb._snapshotRevision ~= revision then
                    stats.changedRows = (stats.changedRows or 0) + 1
                    state.pullChanged = (state.pullChanged or 0) + 1
                elseif kind == "LB" and blows and blows.revision ~= kbRevision then
                    -- (Counted apart: the sync badge's "rows changed" are the ranking's own.)
                    stats.kbChanged = (stats.kbChanged or 0) + 1
                    state.pullChanged = (state.pullChanged or 0) + 1
                end
                sync._pagedDelivery = nil
                if net then net.context = previous end
            end
            if not ok then stats.error = tostring(accepted); state.why = "error"; finish(state, false); return end
            -- Local blacklist/level policy can intentionally differ. Never
            -- bypass it or describe a received sweep as identical replicas.
            if accepted then stats.rows = stats.rows + 1 else stats.rejected = stats.rejected + 1 end
            index = index + 1
            if debugprofilestop and debugprofilestop() - sliceAt >= 1 then break end
        end
        C_Timer.After(0.001, apply)
    end
    C_Timer.After(0.001, apply)
end

local function respond8(session, q)
    -- A 1.8.0 requester's race stream never matches ours (it holds no Skyborne race):
    -- it is told "same as yours" with its own totals and ends its sweep there.
    -- Nothing else is answered on that stream.
    if q.raceless and q.stream == "LR" then
        if q.op ~= "V" then
            if serving == session then serving = nil end
            return
        end
        stats.raceStreamsSkipped = (stats.raceStreamsSkipped or 0) + 1
        enqueue({ epoch = session.epoch, peer = session.peer, packets = { { "HA",
            table.concat({ "8", "S", session.epoch, session.nonce, q.seq, "LR",
                q.totalCount, q.totalHash }, ":") } },
            done = function() if serving == session then serving = nil end end })
        return
    end
    if q.op == "V" and q.whole then
        local a, b = saltOf(session.nonce)
        if profileFp(session.profile, a, b, q.filter, session.kb) == q.whole then
            enqueue({ epoch = session.epoch, peer = session.peer, packets = { { "HA",
                table.concat({ "8", "S", session.epoch, session.nonce, q.seq, "*" }, ":") } },
                done = function() if serving == session then serving = nil end end })
            return
        end
    end
    local profile = session.profile.streams[q.stream]
    local streamCount, streamHash7 = subset(profile, q.filter)
    if q.op == "V" and q.totalCount == streamCount and q.totalHash == streamHash7 then
        enqueue({ epoch = session.epoch, peer = session.peer, packets = { { "HA",
            table.concat({ "8", "S", session.epoch, session.nonce, q.seq, q.stream,
                streamCount, streamHash7 }, ":") } },
            done = function()
                if serving == session then
                    -- (The last stream of the sweep: the races, the killing blows with capability 11.)
                    if q.stream ~= (session.kb and "LB" or "LR") then session.at = GetTime() else serving = nil end
                end
            end })
        return
    end
    local a, b = saltOf(session.nonce)
    local parts, cursor, bucketIndex = {}, "-", 0
    if q.op == "T" then
        -- The best rows by rank (attested order), each found in its bucket, of the
        -- friend's faction when the requester filters; TOP_SCAN ranks per page at most.
        local order, races, bytes = session.profile.order or {}, nil, 0
        local last, r = math.min(#order, STREAM_LIMITS.LK), q.from
        local scanEnd = math.min(last, q.from + TOP_SCAN - 1)
        while r <= scanEnd and #parts < PAGE_ROWS8 do
            local identity = key(order[r])
            local bucket = identity and profile.buckets[hash(identity) % BUCKETS + 1]
            local keys = bucket and bucket.keys
            local low, high = 1, (bucket and bucket.n or 0) + 1
            while keys and low < high do
                local middle = math.floor((low + high) / 2)
                if keys[middle] < identity then low = middle + 1 else high = middle end
            end
            local faction = keys and keys[low] == identity and bucket.factions[low]
            if faction and (not q.filter or faction == q.filter or faction == "?") then
                local payload = compactRow8("LK", bucket.payloads[low], session.epoch)
                races = bucket.races
                if payload and races and races[low] then payload = payload .. ":" .. races[low] end
                local encoded = payload and (tostring(#payload) .. ":" .. payload)
                if encoded and bytes + #encoded > 4064 then break end
                if encoded then parts[#parts + 1], bytes = encoded, bytes + #encoded end
            end
            r = r + 1
        end
        if r <= last then cursor = tostring(r) end
    elseif q.op == "V" then
        for i = 1, BUCKETS do parts[i] = bucketFp(profile.buckets[i], a, b, q.filter) end
    elseif q.op == "M" then
        -- The lists of the asked buckets, in index order, as far as one answer holds: a header
        -- (bucket, entry count) and the entries, 5 bytes each (a bucket too big for a list
        -- is only named, count 999). A bucket that does not fit starts the next answer.
        local bytes = 0
        for i = 1, BUCKETS do
            if wantedAt(q.buckets, i) then
                local bucket = profile.buckets[i]
                local n = bucket.n
                local hinted = q.stream == "LK" and n <= wide.hintMax
                local unit = hinted and 10 or 5
                if bytes + (n > wide.big(q.stream) and 5 or 5 + unit * n) > wide.blob(q.stream) and #parts > 0 then
                    cursor = tostring(i)
                    break
                end
                if n > wide.big(q.stream) then
                    parts[#parts + 1], bytes = string.format("%02d999", i), bytes + 5
                else
                    parts[#parts + 1], bytes = string.format("%02d%03d", i, hinted and n + 500 or n), bytes + 5
                    for j = 1, n do
                        parts[#parts + 1] = rowFp(bucket.digests[j], a, b) .. bucket.factions[j]
                        if hinted then parts[#parts + 1] = wide.encode(bucket.keys[j], bucket.payloads[j], a, b) end
                    end
                    bytes = bytes + unit * n
                end
            end
        end
        if #parts == 0 then return end
    elseif q.op == "N" then
        -- The wanted rows (bits of the numbering along the lists M gave: the covered buckets in
        -- index order, the rows of each in key order), a page at a time like G.
        local withRace, bytes, ordinal = raced("8", q.stream), 0, 0
        local full = false
        for i = 1, BUCKETS do
            if wantedAt(q.covered, i) then
                local bucket = profile.buckets[i]
                local factions = bucket.factions
                local races = withRace and bucket.races
                for j = 1, math.min(bucket.n, wide.big(q.stream)) do
                    ordinal = ordinal + 1
                    if ordinal >= q.from and wantedAt(q.bitmap, ordinal) then
                        local payload = compactRow8(q.stream, bucket.payloads[j], session.epoch)
                        if payload then
                            if races and races[j] then payload = payload .. ":" .. races[j] end
                            local encoded = tostring(#payload) .. ":" .. payload
                            if #parts >= PAGE_ROWS8 or bytes + #encoded > 4064 then
                                cursor, full = tostring(ordinal), true
                                break
                            end
                            parts[#parts + 1] = encoded
                            bytes = bytes + #encoded
                        end
                    end
                end
                if full then break end
            end
        end
        if #parts == 0 and cursor ~= "-" then return end
    elseif q.op == "L" then
        local bucket = profile.buckets[q.bucket]
        bucketIndex = q.bucket
        for i = 1, math.min(bucket.n, LIST_MAX_ROWS) do
            parts[i] = rowFp(bucket.digests[i], a, b) .. bucket.factions[i]
        end
    else
        local bucket = profile.buckets[q.bucket]
        local withRace, bytes, i = raced("8", q.stream), 0, q.from
        bucketIndex = q.bucket
        local factions = bucket.factions
        local races = withRace and bucket.races
        while i <= bucket.n do
            if wantedAt(q.bitmap, i, factions) then
                if #parts >= PAGE_ROWS8 then break end
                -- Built by our own serializer with this epoch: never nil in practice;
                -- a row that does not fit the format is left out rather than sent long.
                local payload = compactRow8(q.stream, bucket.payloads[i], session.epoch)
                if payload then
                    if races and races[i] then payload = payload .. ":" .. races[i] end
                    local encoded = tostring(#payload) .. ":" .. payload
                    if bytes + #encoded > 4064 then break end
                    parts[#parts + 1] = encoded
                    bytes = bytes + #encoded
                end
            end
            i = i + 1
        end
        while i <= bucket.n and not wantedAt(q.bitmap, i, factions) do i = i + 1 end
        if i <= bucket.n then cursor = tostring(i) end
        if #parts == 0 and cursor ~= "-" then return end
    end
    local blob = table.concat(parts)
    local partCount = math.max(1, math.ceil(#blob / CHUNK))
    local packets = { { "HA", table.concat({ "8", "P", session.epoch, session.nonce, q.seq,
        q.op, bucketIndex, #parts, hash(blob), cursor, partCount, q.stream }, ":") } }
    for k = 1, partCount do
        packets[#packets + 1] = { "HB", table.concat({ "8", "D", session.epoch, session.nonce,
            q.seq, k, partCount, q.stream }, ":") .. ":" .. blob:sub((k - 1) * CHUNK + 1, k * CHUNK) }
    end
    enqueue({ epoch = session.epoch, peer = session.peer, packets = packets,
        valid = function() return serving == session end,
        done = function() session.at = GetTime() end })
end

local function respond(session, q)
    if serving ~= session or not session.profile or outbound then return end
    if session.wire == "8" then return respond8(session, q) end
    local profile = session.extended and session.profile.streams[q.stream] or session.profile
    local withRace = raced(session.wire, q.stream)
    if q.totalCount ~= nil and q.totalCount == profile.count
        and q.totalHash == streamHash(profile, session.wire) then
        -- Steady-state convergence costs one request and one reply, not 64 polls.
        local fields = { session.wire, "S", session.epoch,
            session.nonce, q.seq }
        if session.extended then fields[#fields + 1] = q.stream end
        fields[#fields + 1], fields[#fields + 2] = q.totalCount, q.totalHash
        enqueue({ epoch = session.epoch, peer = session.peer, packets = { { "HA",
            table.concat(fields, ":") } },
            done = function()
                if serving == session then
                    if session.extended and q.stream ~= "LR" then session.at = GetTime()
                    else serving = nil end
                end
            end })
        return
    end
    local bucket = profile.buckets[q.bucket]
    local rows, cursor = {}, "-"
    if q.cursor == "-" and bucket.n == q.count and bucketHash(bucket, session.wire) == q.hash then
        -- An empty page certifies only this matching bucket.
    else
        local keys = bucket.keys
        local low, high = 1, bucket.n + 1
        while low < high do
            local middle = math.floor((low + high) / 2)
            if keys[middle] <= q.cursor and q.cursor ~= "-" then low = middle + 1 else high = middle end
        end
        local blobBytes = 0
        for i = low, math.min(bucket.n, low + PAGE_ROWS - 1) do
            local payload = rowPayload(bucket, i, withRace)
            local encoded = tostring(#payload) .. ":" .. payload
            if blobBytes + #encoded > 4064 then break end
            rows[#rows + 1] = encoded
            blobBytes = blobBytes + #encoded
        end
        if #rows == 0 and low <= bucket.n then return end
        if #rows > 0 and low + #rows <= bucket.n then
            cursor = keys[low + #rows - 1]
        end
    end
    local blob = table.concat(rows)
    local partCount = math.max(1, math.ceil(#blob / CHUNK))
    local base = table.concat({ session.wire, "P", session.epoch,
        session.nonce, q.seq, q.bucket,
        #rows, hash(blob), cursor, partCount }, ":")
    if session.extended then base = base .. ":" .. q.stream end
    local packets = { { "HA", base } }
    for i = 1, partCount do
        local data = table.concat({ session.wire, "D", session.epoch,
            session.nonce, q.seq, i, partCount }, ":") .. ":"
        if session.extended then data = data .. q.stream .. ":" end
        packets[#packets + 1] = { "HB", data .. blob:sub((i - 1) * CHUNK + 1, i * CHUNK) }
    end
    enqueue({ epoch = session.epoch, peer = session.peer, packets = packets,
        valid = function() return serving == session end,
        done = function() session.at = GetTime() end })
end

-- Entering an instance: the session we serve is dropped (its requester gives up or
-- moves on long before we leave); resuming it later sent pages built before the
-- instance to a requester that had stopped waiting. A new request opens a new one.
function sync:DropPagedServing()
    serving, outbound = nil, nil
    feed.reset()
end

-- Abandon the running pull (scheduler watchdog). Rows already merged stay and
-- the bucket checkpoint lets the next round resume.
function sync:CancelPagedLeaderboardCatchup()
    if not pull then return false end
    pull.why = "round too long"
    finish(pull, false)
    return true
end

function sync:StartPagedLeaderboardCatchup(peer, callback, extended, withRace, diff, raceless)
    peer = self:NormalizeContributorFullName(peer)
    -- Second result: "local" when this client cannot start now (busy, combat,
    -- no campaign), "unsupported" when the peer is known to lack the protocol.
    if (unsupported[peer] or 0) > GetTime() then return false, "unsupported" end
    if pull or building or paused() or not C_Timer or not C_Timer.After or epoch() <= 0
        or not self:IsValidPlayerName(peer) or type(callback) ~= "function" then
        return false, "local"
    end
    serial = serial + 1
    local saved = progress().shared
    local savedStream = type(saved) == "table" and saved.stream or nil
    -- 2.2.2: a v8 round cut at the captures or races resumes there only soon after; later the
    -- kills are compared first again (they changed meanwhile, and were left uncompared for hours).
    if type(saved) == "table" and saved.wire8 and (savedStream == "LC" or savedStream == "LR" or savedStream == "LB")
        and GetServerTime() - (tonumber(saved.at) or 0) > 600 then
        savedStream = "LK"
    end
    -- 2.5.2: the killing blows with a peer of capability 11 (and the whole ranking), once every
    -- KB_SWEEP_SEC (a sweep cut in them resumes there, as the other streams).
    local kb = diff == true and HoldsFullLadder(peer) and carriesKB(peer)
        and (savedStream == "LB" or not kbSweepAt or GetTime() - kbSweepAt >= KB_SWEEP_SEC) or nil
    local stream = extended and (savedStream == "LC" or savedStream == "LR" or (kb and savedStream == "LB"))
        and savedStream or "LK"
    -- A sweep left at the races resumes there with a current peer only.
    if raceless and stream == "LR" then stream = "LK" end
    local resume = type(saved) == "table" and (extended or savedStream == "LK")
        and integer(saved.bucket, 1, BUCKETS) or nil
    local state = { peer = peer, callback = callback, epoch = epoch(), seq = 0,
        -- Buckets already certified in this stream count toward its end; the
        -- first request still carries the stream digest (one reply if equal).
        completed = resume and savedStream == stream and integer(saved.done, 0, BUCKETS - 1) or 0,
        extended = extended == true, stream = stream, bucket = resume or 1,
        raceless = raceless == true and diff == true or nil,
        changedAtStart = stats.changedRows or 0,
        wire = extended and (diff and "8" or withRace and "7" or "6") or "5",
        cursor = "-" }
    -- 2.4.0: the whole ranking with a peer that holds it too, our view of 5,000 with any other
    -- (and with one whose presence we have not heard: the safe side, one round).
    state.full = diff == true and HoldsFullLadder(peer) or nil
    state.kb = state.full and kb or nil
    -- (The window counts from the stream LB itself: a pull cut in the kills, captures or races
    -- leaves the next one free to reach it.)
    if state.kb and stream == "LB" then kbSweepAt = GetTime() end
    -- 2.5.0: a trailing "f" asks the responder for its feed afterwards (see "The feed").
    state.feed = state.wire == "8" and feed.peerOk(peer) and feed.wants(peer) or nil
    state.nonce = tostring(GetServerTime()) .. (state.full and "w" or "n")
        .. tostring(math.floor(GetTime() * 1000)) .. (state.kb and "b" or "n") .. tostring(serial)
        .. (state.feed and "f" or "")
    if state.wire == "8" then
        -- v8 starts each stream with its bucket fingerprints, whatever the saved bucket.
        state.phase, state.bucket, state.completed, state.qi = "V", 0, 0, 0
        local theirs = self.GetBetaPeerFaction and self:GetBetaPeerFaction(peer)
        -- Our own faction's rows are left to our allies, so only when we have one:
        -- a client whose only direct neighbour is an enemy friend pulls everything.
        if IsOtherFaction(peer) and HasDirectAlly(peer) then
            state.factionFilter = theirs == "Alliance" and "A" or "H"
        end
    end
    pull = state
    -- Leaderboard badge: a sweep runs LK -> LC -> LR and may span several pulls (a
    -- busy or silent peer hands over to the next one at the saved stream). It starts
    -- with a pull at the start of LK; the rows changed are counted from there.
    -- A sweep stays open until a pull ends it (v8 restarts LK from its fingerprints
    -- after a cut: the rows of the cut pass still count).
    state.startedAt = GetServerTime()
    if (stats.sweepBase == nil or stats.sweepEpoch ~= state.epoch) and state.stream == "LK"
        and (state.wire == "8" or (state.bucket == 1 and state.completed == 0)) then
        stats.sweepBase, stats.sweepAt, stats.sweepEpoch = stats.changedRows or 0, state.startedAt, state.epoch
        stats.sweepFiltered = state.factionFilter ~= nil
    elseif state.factionFilter then
        stats.sweepFiltered = true
    end
    stats.protocol = extended and (diff and 8 or withRace and 7 or 6) or 5
    stats.target, stats.result = peer, "preparing"
    if not prepare(function(profile)
        if pull ~= state then return end
        if not profile then
            state.why = "no local snapshot: " .. tostring(stats.profileWhy or "campaign changed")
            finish(state, false); return
        end
        stats.profileWhy = nil
        state.profile = profile
        -- Ranking size, for the badge's "quiet sweep" limit.
        stats.ladderRows = profile.streams and profile.streams.LK and profile.streams.LK.count
            or profile.count or 0
        stats.result = "awaiting reply"
        -- Cold pull (almost nothing of ours yet): the best rows first, then the sweep.
        if state.wire == "8" and state.stream == "LK"
            and (profile.streams.LK.count or 0) < COLD_PULL_ROWS then
            state.phase, state.from, state.topSeen, state.topApplied = "T", 1, {}, 0
        end
        request(state)
    end, true, not state.full) then pull = nil; return false, "local" end
    return true
end

-- Kills, captures and races in one resumable v8 sweep (1.8.1). A peer whose fresh
-- presence advertises less than ASK_PROTOCOL is not asked (update required: before
-- 1.7.0 they served forged rows, and v7 has no row lists). With capability 8
-- (1.8.0) the sweep stops after the captures: its races never match ours. An
-- unknown peer is probed in v8; an old one stays silent or answers once, and the
-- scheduler asks another direct neighbour once its presence says what it is.
function sync:StartCompletePagedLeaderboardCatchup(peer, callback)
    if type(callback) ~= "function" then return false end
    local net = Overlord.Relay
    local capability = net and net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(peer)
    if capability and capability < ASK_PROTOCOL then
        stats.peerProtocol = "beta v" .. capability .. "; not asked (update required)"
        return false, "unsupported"
    end
    local raceless = capability ~= nil and capability < PAGED_PROTOCOL
    stats.peerProtocol = raceless and ("beta v" .. capability .. "; kills and captures only (1.8.0)")
        or capability and ("beta v" .. capability .. (capability >= FULL_PROTOCOL and "; whole ranking" or "; best 5,000 rows"))
        or "capability unknown, v8 probe (best 5,000 rows)"
    return self:StartPagedLeaderboardCatchup(peer, function(ok, supported, notAsked)
        callback(ok == true, supported == true, notAsked == true)
    end, true, true, true, raceless)
end

function sync:OnPagedLeaderboardMessage(kind, payload, sender, channel)
    sender = self:NormalizeContributorFullName(sender)
    -- 2.5.0: the feed's own two messages (no pull, no step number): rows from a peer we asked,
    -- and "stop" from a peer that does not take ours.
    local head = payload:sub(1, 4)
    -- (A page is 250 bytes at most; a message of the feed fills up to three whispers.)
    if #payload > (kind == "HB" and head == "8:U:" and feed.MESSAGE_MAX or 250) or not allowed(sender, channel) then return end
    if head == "8:U:" then
        if kind == "HB" then feed.receive(payload, sender, channel) end
        return
    end
    if head == "8:X:" then
        if kind == "HR" then feed.stop(payload, sender) end
        return
    end
    if head == "8:K:" then
        if kind == "HR" then feed.kept(payload, sender) end
        return
    end
    if head == "8:W:" then
        if kind == "HR" then feed.fightsUp(payload, sender) end
        return
    end
    local version, op, epochStr, nonce, seqStr, a, b, c, d, e, f, g = strsplit(":", payload, 12)
    local wireEpoch, seq = integer(epochStr, 1, 9999999999), integer(seqStr, 1, 10000)
    -- "7" is "6" with the race at the end of each LK row; "8" sends only differing rows.
    local extended = version == "6" or version == "7" or version == "8"
    if (not extended and version ~= "5") or wireEpoch ~= epoch()
        or not seq or not nonce or #nonce > 32
        or not nonce:match("^[%w]+$") then return end
    if kind == "HR" and op == "F" then
        -- The requester counts a request before sending it: a lost last request leaves
        -- its F one step ahead of us. Same peer and pull, same or later step: release.
        if serving and serving.peer == sender and serving.nonce == nonce
            and seq >= serving.seq then serving = nil end
        return
    end
    -- Update required: a requester whose own presence advertises a ranking protocol
    -- older than ASK_PROTOCOL is not served, nor anyone asking in an exchange
    -- older than v8 (current and 1.8.0 clients only ask in v8). A session already
    -- opened for it (before its presence said what it is) is released for the
    -- others. A 1.8.0 requester gets kills and captures, not the races (raceless).
    local net = Overlord.Relay
    local raceless = false
    if kind == "HR" and net and net.GetPeerPagedProtocol then
        local theirs = net:GetPeerPagedProtocol(sender)
        if (theirs and theirs < ASK_PROTOCOL) or ((not theirs or theirs < PAGED_PROTOCOL) and version ~= "8") then
            stats.oldRequestsIgnored = (stats.oldRequestsIgnored or 0) + 1
            if serving and serving.peer == sender then serving = nil end
            return
        end
        raceless = theirs ~= nil and theirs < PAGED_PROTOCOL
    end
    local v8Request = version == "8" and (op == "V" or op == "L" or op == "G" or op == "T"
        or op == "M" or op == "N")
    if kind == "HR" and ((op == "Q" and version ~= "8") or v8Request) then
        local q, fresh
        if v8Request then
            local stream = a
            if not STREAM_LIMITS[stream] then return end
            if op == "V" then
                local totalCount = integer(b, 0, STREAM_LIMITS[stream])
                local totalHash = integer(c, 0, MOD - 1)
                if not totalCount or not totalHash or (d and d ~= "A" and d ~= "H" and d ~= "-")
                    or (e and (seq ~= 1 or not e:match("^[0-9A-Za-z_-][0-9A-Za-z_-][0-9A-Za-z_-][0-9A-Za-z_-]$")))
                    or f then return end
                q = { op = "V", stream = stream, seq = seq, totalCount = totalCount, totalHash = totalHash,
                    filter = d ~= "-" and d or nil, whole = e }
            elseif op == "T" then
                local from = integer(b, 1, STREAM_LIMITS.LK)
                if stream ~= "LK" or not from or (c ~= "-" and c ~= "A" and c ~= "H") or d then return end
                q = { op = "T", stream = "LK", seq = seq, from = from, filter = c ~= "-" and c or nil }
            elseif op == "M" then
                if not validBitmap(b) or b:sub(1, 1) == "*" or #b > 11 or c then return end
                q = { op = "M", stream = stream, seq = seq, buckets = b }
            elseif op == "N" then
                local from = integer(c, 1, wide.ordMax)
                if not validBitmap(b) or b:sub(1, 1) == "*" or #b > 11 or not from
                    or not validBitmap(d) or d:sub(1, 1) == "*" or e then return end
                q = { op = "N", stream = stream, seq = seq, covered = b, from = from, bitmap = d }
            elseif op == "L" then
                local bucket = integer(b, 1, BUCKETS)
                if not bucket or c then return end
                q = { op = "L", stream = stream, seq = seq, bucket = bucket }
            else
                local bucket, from = integer(b, 1, BUCKETS), integer(c, 1, STREAM_LIMITS[stream])
                if not bucket or not from or not validBitmap(d) or e then return end
                q = { op = "G", stream = stream, seq = seq, bucket = bucket, from = from, bitmap = d }
            end
            q.raceless = raceless or nil
            -- A v8 pull always opens with the fingerprints of its first stream.
            fresh = (op == "V" or op == "T") and seq == 1
        else
            local bucket, digest = integer(a, 1, BUCKETS), integer(d, 0, MOD - 1)
            local stream = extended and e or "LK"
            if extended and not e then return end
            local limit = STREAM_LIMITS[stream]
            local count = integer(c, 0, limit or 0)
            local rawTotalCount, rawTotalHash
            if extended then rawTotalCount, rawTotalHash = f, g
            else rawTotalCount, rawTotalHash = e, f end
            local totalCount = integer(rawTotalCount, 0, limit or 0)
            local totalHash = integer(rawTotalHash, 0, MOD - 1)
            if not bucket or not count or not digest or not validCursor(b)
                or not limit or (not extended and g)
                or ((rawTotalCount or rawTotalHash)
                    and (not totalCount or not totalHash or (not extended and seq ~= 1))) then return end
            q = { bucket = bucket, cursor = b, count = count, hash = digest, seq = seq,
                stream = stream, totalCount = totalCount, totalHash = totalHash }
            fresh = seq == 1 and b == "-"
        end
        -- (/ov network: the pulls other players opened with us, and those we took.)
        if fresh then stats.pullsAsked = (stats.pullsAsked or 0) + 1 end
        -- 2.5.0: the requester takes our feed (its nonce says so). A subscriber already ours is
        -- renewed whatever we answer; a new one is kept when its pull is taken (below).
        local flagged = fresh and version == "8" and nonce:match("^%d+[wn]%d+[nb]%d+f$") ~= nil
        if flagged then feed.subscribe(sender, q.filter, false) end
        local session = serving
        if session and (session.epoch ~= wireEpoch or GetTime() - session.at > 300) then serving = nil; session = nil end
        -- A fresh start from the same requester supersedes its own stale session
        -- (interrupted pull whose end notice was lost).
        if session and session.peer == sender and session.nonce ~= nonce
            and fresh then serving = nil; session = nil end
        -- Fair share: a fresh start from an other-faction requester takes over a
        -- same-faction session held for SESSION_SHARE_SEC. The previous requester
        -- resumes later from its shared checkpoint.
        if session and session.peer ~= sender and fresh and not building
            and GetTime() - (session.startedAt or session.at) >= SESSION_SHARE_SEC
            and IsOtherFaction(sender) and not IsOtherFaction(session.peer) then
            -- In combat the running session keeps its pages; the newcomer waits for the
            -- end of the fight ("busy: combat") and takes over then.
            if inCombat() and not blocked() then
                sendControl("HA", table.concat({ version, "R", wireEpoch, nonce, seq }, ":") .. ":C", sender)
                return
            end
            -- One small "busy" to the previous requester, in place of the page it
            -- will not get: it moves on at once instead of waiting 90 s of silence.
            sendControl("HA", table.concat({ session.wire, "R",
                session.epoch, session.nonce, session.seq }, ":"), session.peer)
            serving, session, outbound = nil, nil, nil
            stats.preempted = (stats.preempted or 0) + 1
        end
        local busyReply = table.concat({ version, "R", wireEpoch, nonce, seq }, ":")
        -- In an instance: busy, not silent (a silent peer is dropped as v6-less).
        if blocked() then sendControl("HA", busyReply, sender); return end
        if (session and (session.peer ~= sender or session.nonce ~= nonce
                or session.wire ~= version))
        or (not session and not fresh) then
            -- Busy with another requester, or a cursor from a lost session (it is
            -- meaningful only inside the original frozen profile): say so at once.
            -- Plain busy even in combat: waiting for us would not free us sooner.
            sendControl("HA", busyReply, sender)
            return
        end
        -- In combat, a session whose profile is built goes on (its pages are cheap);
        -- anything that would need building says "busy: combat" (6th field, ignored
        -- by older requesters) so the requester waits for us instead of giving up.
        if inCombat() and not (session and session.profile) then
            sendControl("HA", busyReply .. ":C", sender)
            return
        end
        if not session then
            -- A new requester while a page (or a profile) is still being produced
            -- for someone else: busy, never silent.
            if building or outbound then sendControl("HA", busyReply, sender); return end
            session = { peer = sender, nonce = nonce, epoch = wireEpoch,
                at = GetTime(), startedAt = GetTime(), seq = seq, extended = extended,
                wire = version,
                -- 2.4.0: the requester's nonce says which view it compares ("w": all of it).
                legacy = not (version == "8" and nonce:match("^%d+w%d") ~= nil),
                -- 2.5.2: "b" before the serial: the killing blows end the sweep (capability 11).
                kb = version == "8" and nonce:match("^%d+w%d+b%d+f?$") ~= nil or nil }
            serving = session
            stats.pullsTaken = (stats.pullsTaken or 0) + 1
            if flagged then feed.subscribe(sender, q.filter, true) end
        -- The previous page of this same session is still leaving: its requester
        -- asks again after its own timeout.
        elseif outbound or seq < session.seq or seq > session.seq + 1 then return end
        session.at, session.seq = GetTime(), seq
        if session.profile then respond(session, q)
        else
            prepare(function(profile)
                if serving ~= session then return end
                session.profile = profile
                if profile then respond(session, q)
                else
                    -- Nothing to serve right now: one "busy" instead of silence (a
                    -- silent peer costs the requester 270 s and a 10-min penalty).
                    serving = nil
                    sendControl("HA", busyReply, sender)
                end
            end, nil, session.legacy)
        end
        return
    end
    local state = pull
    if not state or sender ~= state.peer or nonce ~= state.nonce or seq ~= state.seq
        or wireEpoch ~= state.epoch or state.applying
        or state.wire ~= version then return end
    if kind == "HA" and op == "R" then
        state.supported = true
        -- Busy only while it fights: keep our place with this peer and ask again a
        -- little later (one small request every 30-45 s, at most 5), instead of
        -- spending an attempt and waiting two minutes for the next round.
        if a == "C" and (state.combatWaits or 0) < COMBAT_WAIT_MAX and state.lastRequest then
            state.combatWaits = (state.combatWaits or 0) + 1
            state.fragmentAt = GetTime() -- alive: the watchdog does not count this wait
            stats.combatWaits = (stats.combatWaits or 0) + 1
            local waitSeq, waitPayload = state.seq, state.lastRequest
            local function askAgain()
                -- The page already started coming: asking again would resend all of it.
                if pull ~= state or state.seq ~= waitSeq or state.applying
                    or state.replySeen then return end
                -- In our own fight: ask once it ends (a local check, nothing sent).
                if paused() then C_Timer.After(5, askAgain) return end
                state.fragmentAt = GetTime()
                sendControl("HR", waitPayload, state.peer)
            end
            C_Timer.After(COMBAT_WAIT_SEC + math.random(0, COMBAT_WAIT_JITTER), askAgain)
            return
        end
        state.why = a == "C" and "peer in combat" or "peer busy"
        -- (It did not take our pull: its feed is not asked for, unless it feeds us already.)
        if state.feed and not feed.sources[state.peer:lower()] then feed.asked[state.peer:lower()] = nil end
        finish(state, false)
        return
    end
    if kind == "HA" and op == "S" and state.wire == "8" and a == "*" then
        -- The whole ranking matched (first request only): nothing to pull, and the
        -- responder already released its session (no end notice needed).
        if state.phase ~= "V" or seq ~= 1 or b then return end
        state.supported = true
        stats.pages = stats.pages + 1
        state.stream, state.wholeMatch = "LK", true
        finish(state, true)
        return
    end
    if kind == "HA" and op == "S" then
        local stream = extended and a or "LK"
        if extended and not a then return end
        local profile = extended and state.profile.streams[state.stream] or state.profile
        local count = integer(extended and b or a, 0, STREAM_LIMITS[stream] or 0)
        local digest = integer(extended and c or b, 0, MOD - 1)
        local expectedCount, expectedHash = profile.count, streamHash(profile, state.wire)
        if state.wire == "8" then expectedCount, expectedHash = subset(profile, state.factionFilter) end
        if stream ~= state.stream or count ~= expectedCount or digest ~= expectedHash
            or (not extended and (seq ~= 1 or c)) then return end
        state.supported = true
        if state.wire == "8" then
            if state.phase ~= "V" then return end
            nextStream8(state)
        elseif extended then
            state.completed = BUCKETS - 1
            nextPage(state, "-")
        else
            state.bucket, state.completed = 1, 0
            finish(state, true)
        end
        return
    end
    if kind == "HA" and op == "P" and state.wire == "8" then
        local bucket, rows, digest = integer(b, 0, BUCKETS), integer(c, 0, LIST_MAX_ROWS), integer(d, 0, MOD - 1)
        local parts, cursor, stream = integer(f, 1, MAX_PARTS), e, g
        if a ~= state.phase or stream ~= state.stream or not bucket or not rows or not digest
            or not parts or ((a == "V" or a == "T" or a == "M" or a == "N") and bucket ~= 0)
            or (a ~= "V" and a ~= "T" and a ~= "M" and a ~= "N" and bucket ~= state.bucket)
            or ((a == "G" or a == "T" or a == "N") and rows > PAGE_ROWS8_MAX)
            -- A T cursor is the next rank to look at: always past this page.
            or (a == "T" and not (cursor == "-"
                or integer(cursor, state.from + math.max(rows, 1), STREAM_LIMITS.LK)))
            -- A G cursor is the next wanted index after the rows of this page: it
            -- must move past them (a page that never advances is refused).
            or not (cursor == "-" or a == "T"
                or (a == "M" and integer(cursor, 1, BUCKETS))
                or ((a == "G" or a == "N") and integer(cursor, state.from + rows, STREAM_LIMITS[state.stream] or 0)))
            or (state.partCount and state.partCount ~= parts) then return end
        state.meta = { op = a, rows = rows, hash = digest, cursor = cursor, parts = parts }
        state.partCount = parts
    elseif kind == "HA" and op == "P" then
        local bucket, rows, digest, parts = integer(a, 1, BUCKETS), integer(b, 0, PAGE_ROWS),
            integer(c, 0, MOD - 1), integer(e, 1, MAX_PARTS)
        local stream = extended and f or "LK"
        if extended and not f then return end
        if bucket ~= state.bucket or not rows or not digest or not parts
            or not validCursor(d) or (not extended and f) or stream ~= state.stream
            or (state.partCount and state.partCount ~= parts) then return end
        state.meta = { rows = rows, hash = digest, cursor = d, parts = parts }
        state.partCount = parts
    elseif kind == "HB" and op == "D" then
        -- Parse the opaque chunk without splitting the LK payload's colons.
        local _, _, _, _, _, partStr, partsStr, stream, chunk
        if extended then
            _, _, _, _, _, partStr, partsStr, stream, chunk = strsplit(":", payload, 9)
        else
            _, _, _, _, _, partStr, partsStr, chunk = strsplit(":", payload, 8)
            stream = "LK"
        end
        local part, parts = integer(partStr, 1, MAX_PARTS), integer(partsStr, 1, MAX_PARTS)
        if not part or not parts or part > parts or not chunk or #chunk > CHUNK
            or stream ~= state.stream or (state.partCount and state.partCount ~= parts) then return end
        if state.parts[part] and state.parts[part] ~= chunk then return end
        if not state.parts[part] then
            if state.bytes + #chunk > 4064 then return end
            state.parts[part], state.bytes = chunk, state.bytes + #chunk
        end
        state.partCount = parts
    else return end
    state.supported, state.channel = true, channel
    state.replySeen = true
    state.fragmentAt = GetTime()
    state.context = Overlord.Relay and Overlord.Relay.context or nil
    tryApply(state)
end

local function currentPullStatus()
    if not pull then return stats.result or "idle" end
    local status
    if not pull.profile then status = "preparing"
    elseif pull.applying then status = "applying page"
    elseif pull.waitingForSend then status = "waiting to queue request"
    elseif pull.replySeen then status = "receiving page"
    else status = "awaiting reply" end
    if paused() then status = status .. " (paused: combat/instance)" end
    return status
end

-- Short form for the /ov sync summary (no mutation).
-- Read-only (leaderboard badge): a pull is running, its stream (1 kills,
-- 2 captures, 3 races), and whether it is paused (combat or instance).
function sync:GetPagedPullProgress()
    local s = pull
    if not s then return false end
    return true, (s.stream == "LR" or s.stream == "LB") and 3 or s.stream == "LC" and 2 or 1, paused()
end

function sync:GetPagedLeaderboardSummary()
    return {
        status = currentPullStatus(), running = pull ~= nil,
        -- (2.3.0: seconds since the running pull last heard a page part: /ov network tells a long
        -- catch-up that still receives from one that waits on nobody.)
        lastPartAge = pull and pull.fragmentAt and math.floor(GetTime() - pull.fragmentAt) or nil,
        pages = stats.pages or 0, rows = stats.rows or 0,
        protocol = stats.protocol or 5, peer = stats.peerProtocol or "",
    }
end

function sync:GetPagedLeaderboardDiagnostics()
    local status, details = currentPullStatus(), ""
    if pull then
        local received = 0
        for _ in pairs(pull.parts or {}) do received = received + 1 end
        details = string.format("; parts=%d/%s; timeout=%ss", received,
            tostring(pull.partCount or "?"), tostring(pull.timeoutRemaining or "-"))
    end
    -- v8: current step, and since login the rows asked for out of the rows listed.
    if pull and pull.wire == "8" then
        details = details .. string.format("; v8 step %s%s", tostring(pull.phase),
            pull.factionFilter and (" (" .. pull.factionFilter .. " rows only)") or "")
    end
    if stats.listed then
        details = details .. string.format("; v8 wanted %d/%d listed, %d buckets differing",
            stats.wanted or 0, stats.listed, stats.bucketsDiffering or 0)
    end
    -- Since login: our pulls that no neighbour answered at all, the requests of old
    -- clients we left unanswered, and the answers our own relay refused to send
    -- because their requester was not one of our direct neighbours.
    local net = Overlord.Relay
    details = details .. string.format(
        "; unanswered pulls=%d; old requests ignored=%d; answers refused (requester not direct)=%d",
        stats.silentPulls or 0, stats.oldRequestsIgnored or 0,
        net and net.stats and net.stats.catchupNotDirect or 0)
    -- What this client did for the players who asked it: pulls opened with us and
    -- taken, answers queued, fully sent, given up after 240 s, cancelled, and the
    -- sends our relay refused (counted at each retry).
    details = details .. string.format(
        "; asked by others=%d taken=%d; answers queued=%d sent=%d expired=%d cancelled=%d send refusals=%d",
        stats.pullsAsked or 0, stats.pullsTaken or 0, stats.repliesQueued or 0, stats.repliesSent or 0,
        stats.repliesExpired or 0, stats.repliesCancelled or 0, stats.replySendsRefused or 0)
    -- 2.5.0, the feed: who we feed and who feeds us now; messages and rows sent; messages
    -- received, rows taken, rows that changed our ranking, rows of players unknown here (left to
    -- the pulls), messages from a peer we had not asked.
    local feeding = 0
    for _, heardAt in pairs(feed.sources) do
        if GetTime() - heardAt <= feed.LIVE_SEC then feeding = feeding + 1 end
    end
    details = details .. string.format(
        "; feed: subscribers=%d feeding us=%d; sent=%d rows=%d; received=%d rows=%d changed=%d unknown=%d refused=%d",
        feed.subCount, feeding, stats.feedSent or 0, stats.feedRowsSent or 0, stats.feedReceived or 0,
        stats.feedRows or 0, stats.feedChanged or 0, stats.feedUnknown or 0, stats.feedRefused or 0)
    return string.format("Ladder v%d: %s; pages=%d rows=%d filtered=%d retries=%d; %s bucket=%s/64%s; peer=%s; 300 B/s budget",
        stats.protocol or 5, status, stats.pages, stats.rows, stats.rejected,
        stats.retries, pull and pull.stream or "LK",
        pull and tostring(pull.bucket) or "-", details,
        stats.peerProtocol or "unspecified")
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["SyncLeaderboardPages.lua"] = function() return { sync = sync, lb = lb, PAGED_PROTOCOL = PAGED_PROTOCOL, ASK_PROTOCOL = ASK_PROTOCOL, BUCKETS = BUCKETS, PAGE_ROWS = PAGE_ROWS, CHUNK = CHUNK, MAX_PARTS = MAX_PARTS, STREAMS = STREAMS, PROFILE_STREAMS = PROFILE_STREAMS, KB_SWEEP_SEC = KB_SWEEP_SEC, kbSweepAt = kbSweepAt, STREAM_LIMITS = STREAM_LIMITS, LEGACY_LIMITS = LEGACY_LIMITS, FULL_PROTOCOL = FULL_PROTOCOL, MOD = MOD, RATE = RATE, BURST = BURST, pull = pull, serving = serving, outbound = outbound, wake = wake, building = building, SESSION_SHARE_SEC = SESSION_SHARE_SEC, profiles = profiles, legacyViews = legacyViews, legacyProfiles = legacyProfiles, unsupported = unsupported, unsupportedOrder = unsupportedOrder, serial = serial, tokens = tokens, refillAt = refillAt, stats = stats, feed = feed, COMBAT_WAIT_SEC = COMBAT_WAIT_SEC, COMBAT_WAIT_JITTER = COMBAT_WAIT_JITTER, COMBAT_WAIT_MAX = COMBAT_WAIT_MAX, PROFILE_REUSE_SEC = PROFILE_REUSE_SEC, PROFILE_DIRTY_REUSE_SEC = PROFILE_DIRTY_REUSE_SEC, PROFILE_DIRTY_ROW_SEC = PROFILE_DIRTY_ROW_SEC, FP_SPACE = FP_SPACE, LIST_MAX_ROWS = LIST_MAX_ROWS, BITMAP_MAX = BITMAP_MAX, B64 = B64, B64BYTES = B64BYTES, B64INDEX = B64INDEX, PAGE_ROWS8 = PAGE_ROWS8, PAGE_ROWS8_MAX = PAGE_ROWS8_MAX, TOP_ROWS = TOP_ROWS, COLD_PULL_ROWS = COLD_PULL_ROWS } end
Overlord.MemoryParts["SyncLeaderboardPages.lua#2"] = function() return { TOP_SCAN = TOP_SCAN, sendControl = sendControl, request = request, tryApply = tryApply, SMALL_BUCKET_ROWS = SMALL_BUCKET_ROWS, SMALL_STREAM_ROWS = SMALL_STREAM_ROWS, WIDE_MIN_RELEASE = WIDE_MIN_RELEASE, WIDE_BLOB_MAX = WIDE_BLOB_MAX, WIDE_BIG = WIDE_BIG, WIDE_RELEASE_AGE = WIDE_RELEASE_AGE, wide = wide, feedArm = feedArm } end
