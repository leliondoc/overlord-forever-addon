-- Targeted, resumable anti-entropy: v5 covers 5,000 kills; v6 also pages
-- 500 capture rows per faction and race metadata for attested contributors;
-- v7 (1.7.0) is v6 with the race at the end of each sent kill row.
-- Since 1.7.5 peers before v7 are not asked (clients before 1.7.0 are left out,
-- update required); responders still answer v5/v6 requests from old clients.
-- v8 (1.8.0) sends only the rows that differ: one fingerprint per bucket, then one
-- per row of a differing bucket, then the rows asked for (see the v8 block below).
-- Capability 9 (1.8.1) is v8 between clients that know the Skyborne race: a peer
-- advertising less is neither asked nor served (update required). Its race stream
-- never matched ours, so every round resent the same race rows both ways.
local Overlord = _G.Overlord
if not Overlord or not Overlord.Sync then return end
local sync, lb = Overlord.Sync, Overlord.Leaderboard
local PAGED_PROTOCOL = 9
sync.PAGED_PROTOCOL = PAGED_PROTOCOL
local BUCKETS, PAGE_ROWS, CHUNK, MAX_PARTS = 64, 16, 170, 24
local STREAMS = { "LK", "LC", "LR" }
local STREAM_LIMITS = { LK = 5000, LC = 1500, LR = 6500 }
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
-- PAGED_PROTOCOL) is no source, and the enemy friend's pull stays unfiltered.
local function HasDirectAlly(except)
    local net = Overlord.Relay
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    for _, name in ipairs(net and net.GetDirectPeers and net:GetDirectPeers() or {}) do
        local capability = net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(name)
        if name ~= except and name ~= me and not IsOtherFaction(name)
            and not (capability and capability < PAGED_PROTOCOL) then return true end
    end
    return false
end
local profiles = setmetatable({}, { __mode = "k" })
local unsupported, unsupportedOrder = {}, {}
local serial, tokens, refillAt = 0, BURST, 0
local stats = { pages = 0, rows = 0, rejected = 0, deferred = 0, retries = 0, bytes = 0 }
sync._leaderboardPageStats = stats

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
local function hash(value)
    local h, n, i = 0, #value, 1
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
        if job.epoch ~= epoch() or (job.valid and not job.valid()) then outbound = nil; return end
        if blocked() then job.at = GetTime(); wake = true; C_Timer.After(2, pump); return end
        if GetTime() - job.at > 240 then outbound = nil; return end
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
            if sync:SendWhisper(packet[1], packet[2], job.peer) ~= false then
                job.index = job.index + 1
                stats.bytes = stats.bytes + cost
                if job.index > #job.packets then
                    outbound = nil
                    if job.done then job.done() end
                    return
                end
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
local PROFILE_REUSE_SEC = 120
-- own: the profile is for our own pull. It is not reused once rows were applied
-- since it was built (1.8.0: rounds every 45-105 s after a v8 round would otherwise
-- list and fetch again the rows the previous round just brought).
local function prepare(callback, own)
    if building then return false end
    local wanted = epoch()
    local recent = sync.GetAttestedLeaderboardSnapshot and sync:GetAttestedLeaderboardSnapshot()
    local cached = type(recent) == "table" and profiles[recent] or nil
    local age = cached and (((GetServerTime and GetServerTime()) or time()) - (tonumber(recent.at) or 0)) or nil
    if cached and cached.epoch == wanted and age and age >= 0 and age < PROFILE_REUSE_SEC
        and not (own and cached.builtRows ~= (stats.changedRows or 0)) then
        stats.profileReused = (stats.profileReused or 0) + 1
        C_Timer.After(0.001, function()
            if wanted ~= epoch() then callback(nil); return end
            callback(cached)
        end)
        return true
    end
    building = true
    -- Rows that really changed our ranking so far (taken before the copy is made).
    local builtRows = stats.changedRows or 0
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(ok)
        local snapshot = ok and sync:GetAttestedLeaderboardSnapshot()
        if not snapshot or wanted ~= epoch() then building = nil; callback(nil); return end
        if profiles[snapshot] then building = nil; callback(profiles[snapshot]); return end
        local result = { epoch = wanted, streams = {}, builtRows = builtRows }
        for _, kind in ipairs(STREAMS) do
            result.streams[kind] = { buckets = {}, count = 0, hash = 0, hash7 = 0,
                countA = 0, hashA = 0, countH = 0, hashH = 0 }
        end
        result.buckets = result.streams.LK.buckets
        local units, sliceAt = 0, 0
        local function work()
            units = units + 1
            if units >= 32 or (debugprofilestop and debugprofilestop() - sliceAt >= 1) then
                coroutine.yield()
            end
        end
        local co = coroutine.create(function()
            local sources = { LK = snapshot.kills, LC = snapshot.captureCount,
                LR = snapshot.playerInfo }
            local serializers = {
                LK = sync.BuildPagedLeaderboardKillPayload,
                LC = sync.BuildPagedLeaderboardCapturePayload,
                LR = sync.BuildPagedLeaderboardRacePayload,
            }
            for _, kind in ipairs(STREAMS) do
                local profile, source, count = result.streams[kind], sources[kind] or {}, 0
                local isKills = kind == "LK"
                -- Rows are gathered and sorted as small tables, then kept as arrays.
                local pending = {}
                for i = 1, BUCKETS do pending[i] = {}; work() end
                for name in pairs(source) do
                    count = count + 1
                    if count > STREAM_LIMITS[kind] then error("oversized attested snapshot") end
                    local serialize = serializers[kind]
                    local payload = serialize and serialize(sync, snapshot, name, wanted)
                    local identity = payload and key(name)
                    if identity and validCursor(identity) then
                        local rows = pending[hash(identity) % BUCKETS + 1]
                        rows[#rows + 1] = { key = identity, payload = payload, name = name }
                    end
                    work()
                end
                for i = 1, BUCKETS do
                    local rows = pending[i]
                    lb:SortNetworkRows(rows, function(a, b) return a.key < b.key end, work)
                    local bucket = { hash = 0, hash7 = 0, n = #rows, keys = {}, payloads = {},
                        digests = {}, factions = {}, races = isKills and {} or nil,
                        nA = 0, hashA = 0, nH = 0, hashH = 0 }
                    for j = 1, #rows do
                        local row = rows[j]
                        local h = hash(rowDigest(kind, row.payload))
                        local faction, mixed = factionChar(snapshot, row.name), mixRow(h)
                        bucket.keys[j], bucket.payloads[j], bucket.digests[j] = row.key, row.payload, h
                        bucket.factions[j] = faction
                        if isKills then bucket.races[j] = raceField(snapshot, row.name, row.payload) or false end
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
            if not success then stats.error = tostring(err); building = nil; callback(nil); return end
            if coroutine.status(co) ~= "dead" then C_Timer.After(0.001, step); return end
            profiles[snapshot] = result
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
local function profileFp(profile, a, b, filter)
    local acc = 0
    for _, kind in ipairs(STREAMS) do
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
        saved.shared = { stream = state.stream or "LK", bucket = 1, done = 0, at = GetServerTime() }
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
    state.callback(success, state.supported == true)
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
                fields[#fields + 1] = profileFp(state.profile, a, b, state.factionFilter)
            elseif state.factionFilter then
                fields[#fields + 1] = state.factionFilter
            end
        elseif state.phase == "T" then
            fields = { "8", "T", state.epoch, state.nonce, state.seq, "LK", state.from,
                state.factionFilter or "-" }
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
    end
    sendRequest()
    -- Two relay TTLs plus margin also cover a congested first request/reply.
    -- A peer that already answered pages in this pull and then goes silent has
    -- most likely left or zoned in: give up sooner (rows already merged stay).
    local answered = state.completed > 0 or state.replySeen
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
local function nextStream8(state)
    state.combatWaits = 0
    if state.stream ~= "LR" then
        state.stream = state.stream == "LK" and "LC" or "LR"
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
local function nextBucket8(state)
    state.combatWaits = 0
    state.qi = state.qi + 1
    local bucketIndex = state.queue and state.queue[state.qi]
    if not bucketIndex then nextStream8(state); return end
    state.bucket, state.gLast = bucketIndex, nil
    local own = state.profile.streams[state.stream].buckets[bucketIndex]
    -- Nothing of ours in this bucket: every row is wanted (of the friend's faction
    -- when it is of the other faction), no list needed.
    if own.n == 0 then
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

-- V and L answers: fixed-width blobs, compared with our own profile (same salt).
local function applyList8(state, meta, blob)
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
    if v8 and meta.op ~= "G" and meta.op ~= "T" then
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
                    or sync.OnReceiveLeaderboardRace
                local revision = lb._snapshotRevision
                ok, accepted = pcall(receive, sync, payload, state.peer, state.channel)
                if lb._snapshotRevision ~= revision then stats.changedRows = (stats.changedRows or 0) + 1 end
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
    if q.op == "V" and q.whole then
        local a, b = saltOf(session.nonce)
        if profileFp(session.profile, a, b, q.filter) == q.whole then
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
                    if q.stream ~= "LR" then session.at = GetTime() else serving = nil end
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

-- Abandon the running pull (scheduler watchdog). Rows already merged stay and
-- the bucket checkpoint lets the next round resume.
function sync:CancelPagedLeaderboardCatchup()
    if not pull then return false end
    pull.why = "round too long"
    finish(pull, false)
    return true
end

function sync:StartPagedLeaderboardCatchup(peer, callback, extended, withRace, diff)
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
    local stream = extended and (savedStream == "LC" or savedStream == "LR")
        and savedStream or "LK"
    local resume = type(saved) == "table" and (extended or savedStream == "LK")
        and integer(saved.bucket, 1, BUCKETS) or nil
    local state = { peer = peer, callback = callback, epoch = epoch(), seq = 0,
        -- Buckets already certified in this stream count toward its end; the
        -- first request still carries the stream digest (one reply if equal).
        completed = resume and savedStream == stream and integer(saved.done, 0, BUCKETS - 1) or 0,
        extended = extended == true, stream = stream, bucket = resume or 1,
        changedAtStart = stats.changedRows or 0,
        wire = extended and (diff and "8" or withRace and "7" or "6") or "5",
        cursor = "-", nonce = tostring(GetServerTime()) .. "n"
            .. tostring(math.floor(GetTime() * 1000)) .. "n" .. tostring(serial) }
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
        if not profile then state.why = "no local snapshot"; finish(state, false); return end
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
    end, true) then pull = nil; return false, "local" end
    return true
end

-- Kills, captures and races in one resumable v8 sweep (1.8.1). A peer whose fresh
-- presence advertises less than PAGED_PROTOCOL is not asked (update required:
-- before 1.7.0 they served forged rows, before 1.8.1 their races never match). An
-- unknown peer is probed in v8; an old one stays silent or answers once, and the
-- scheduler asks another direct neighbour once its presence says what it is.
function sync:StartCompletePagedLeaderboardCatchup(peer, callback)
    if type(callback) ~= "function" then return false end
    local net = Overlord.Relay
    local capability = net and net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(peer)
    if capability and capability < PAGED_PROTOCOL then
        stats.peerProtocol = "beta v" .. capability .. "; not asked (update required)"
        return false, "unsupported"
    end
    stats.peerProtocol = capability and ("beta v" .. capability .. "; l9+ld+lr+lp6 NH")
        or "capability unknown, v8 probe"
    return self:StartPagedLeaderboardCatchup(peer, function(ok, supported)
        callback(ok == true, supported == true)
    end, true, true, true)
end

function sync:OnPagedLeaderboardMessage(kind, payload, sender, channel)
    sender = self:NormalizeContributorFullName(sender)
    if #payload > 250 or not allowed(sender, channel) then return end
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
    -- Update required: a requester whose own presence advertises an older ranking
    -- protocol is not served (see PAGED_PROTOCOL), nor an unknown one asking in an
    -- older exchange (a current client only asks in v8). A session already opened
    -- for it (before its presence said what it is) is released for the others.
    local net = Overlord.Relay
    if kind == "HR" and net and net.GetPeerPagedProtocol then
        local theirs = net:GetPeerPagedProtocol(sender)
        if (theirs and theirs < PAGED_PROTOCOL) or (not theirs and version ~= "8") then
            stats.oldRequestsIgnored = (stats.oldRequestsIgnored or 0) + 1
            if serving and serving.peer == sender then serving = nil end
            return
        end
    end
    local v8Request = version == "8" and (op == "V" or op == "L" or op == "G" or op == "T")
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
            elseif op == "L" then
                local bucket = integer(b, 1, BUCKETS)
                if not bucket or c then return end
                q = { op = "L", stream = stream, seq = seq, bucket = bucket }
            else
                local bucket, from = integer(b, 1, BUCKETS), integer(c, 1, STREAM_LIMITS[stream])
                if not bucket or not from or not validBitmap(d) or e then return end
                q = { op = "G", stream = stream, seq = seq, bucket = bucket, from = from, bitmap = d }
            end
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
                wire = version }
            serving = session
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
            end)
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
            or not parts or ((a == "V" or a == "T") and bucket ~= 0)
            or (a ~= "V" and a ~= "T" and bucket ~= state.bucket)
            or ((a == "G" or a == "T") and rows > PAGE_ROWS8_MAX)
            -- A T cursor is the next rank to look at: always past this page.
            or (a == "T" and not (cursor == "-"
                or integer(cursor, state.from + math.max(rows, 1), STREAM_LIMITS.LK)))
            -- A G cursor is the next wanted index after the rows of this page: it
            -- must move past them (a page that never advances is refused).
            or not (cursor == "-" or a == "T"
                or (a == "G" and integer(cursor, state.from + rows, STREAM_LIMITS[state.stream] or 0)))
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
    return true, s.stream == "LR" and 3 or s.stream == "LC" and 2 or 1, paused()
end

function sync:GetPagedLeaderboardSummary()
    return {
        status = currentPullStatus(), running = pull ~= nil,
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
    return string.format("Ladder v%d: %s; pages=%d rows=%d filtered=%d retries=%d; %s bucket=%s/64%s; peer=%s; 300 B/s budget",
        stats.protocol or 5, status, stats.pages, stats.rows, stats.rejected,
        stats.retries, pull and pull.stream or "LK",
        pull and tostring(pull.bucket) or "-", details,
        stats.peerProtocol or "unspecified")
end
