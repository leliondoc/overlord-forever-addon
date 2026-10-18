-- RankProof.lua : the top Overlord ranks (11 to 15) seen by other players.
--
-- A rank is earned and kept locally (Ranks.lua). From rank 11 on (Dragon Lord, Warmaster,
-- Crown Prince, Sovereign, Overlord) the other players of the same faction show its badge
-- left of the name, in the ranking and on nameplates, but only once THIS client has checked
-- it by itself, against its own ranking and the game server. Nothing another client says is
-- believed, so neither a modified client nor a crowd of alts can raise a badge:
--   1. Claim: the player's own presence says his rank ("~q<rank>", first-hand only). The
--      badge never shows more than the claim.
--   2. Server anchor: our own inspect reading of that player (Blizzard's lifetime honorable
--      kills, a server value no addon can change) reaches 75 % of the rank's Glory.
--   3. Weeks, from our own weekly closes: a week is proven when our close of it put him in
--      the top (Ranks' rules) and it lies between two of our readings at most three weeks
--      apart whose difference covers what our ranking gave him between them (a ranking row
--      inflated beyond the server's count proves nothing). Everything our ranking ever gave
--      him must also fit in the server's count.
--   4. Other weeks can complete a rank, never start one (one week at that very top proven
--      by us first): his top weeks seen before our first reading, then weeks we did not see
--      (not playing, or not yet installed), which the server's count must hold beyond all
--      we saw.
-- A rank fully proven once stays shown (ranks are for life), for that same character.
-- So a badge shows on a client that read the player in different weeks around one of his
-- top weeks: a holder who no longer reaches his top stays hidden from clients that did not
-- read him while he did.
--
-- Players of the other faction cannot be inspected: their ranks are told from our own weekly
-- closes alone (every kill and top week our ranking gave them), as the Nemesis skull is.
--
-- Residual, stated: the server count also holds battleground kills. A player who really
-- earns a top volume of kills anywhere and declares it as world kills is shown at that rank;
-- one who earned the Glory and one real top week can have the other weeks of that rank
-- shown on clients that did not read him before them.
--
-- Costs, by construction: a few bytes in the presence of a claimant only, no message of
-- its own, one inspect every 30 s at most (out of combat, never while the player inspects
-- someone), a 30 s tick, nothing per frame. Fully cut in instances.
Overlord = Overlord or {}
local RP = Overlord.RankProof or {}
Overlord.RankProof = RP

RP.MIN_RANK = 11
-- A Tuesday 08:00 UTC reset (2020-01-07): week indexes are rounded from it (any region's
-- reset lands within a day of it, the ladder's own slack is 36 h).
RP.WEEK_REF = 1578384000
RP.WEEK_SEC = 604800
RP.TOPS = { 1, 3, 10, 25, 100 }
-- First weeks that can hold a rank week: the beta's from the ranks' release (2.0.0, the
-- week of Tuesday 2026-10-06), the game's from its launch (week of Tuesday 2026-11-03).
-- Weeks before are never "weeks we did not see" (see RankFromProof).
RP.ERA_BETA = 1791273600
RP.ERA_LAUNCH = 1793692800
-- Lifetime honorable kills (server) needed, as a share of the rank's Glory (Glory also
-- counts captures, two each).
RP.ANCHOR = 0.75
-- Readings: one inspect per 30 s, the same player again after 6 h once read, after 5 min
-- when nothing came back; the target is inspected after it stayed 3 s.
RP.INSPECT_GAP = 30
RP.INSPECT_AGAIN = 6 * 3600
RP.INSPECT_RETRY = 300
RP.INSPECT_TIMEOUT = 8
RP.INSPECT_SETTLE = 2
RP.TARGET_DELAY = 3
RP.FOREIGN_QUIET = 2
-- Bounds.
RP.CLAIMS_MAX = 1000
-- Claims not heard for half a year go (a holder back from a long break keeps his claim);
-- one heard again after four weeks of silence waits, like a new one, until we see the
-- character we read (another character may have taken the name meanwhile).
RP.CLAIM_DAYS = 182 * 86400
RP.CLAIM_QUIET = 28 * 86400
RP.READING_WEEKS = 16
RP.READ_KEYS = 1200
RP.CLOSE_WEEKS = 52
RP.CLOSE_TOP = 100
-- A tie group at the 100th place that would hold more rows than this is left out whole
-- (rows injected at one value must not bloat the saved file; every client drops the same).
RP.CLOSE_CAP = 150
-- A week is proven by two of our readings at most this many whole weeks apart around it:
-- the server's growth over a long stretch cannot be poured into one forged top week.
RP.BRACKET_WEEKS = 2
RP.CANDIDATE_WEEKS = 8
RP.LIST_MAX = 600
RP.SHOWN_MAX = 20000
-- Names kept per side in the other faction's running totals (the lowest go first).
RP.LS_MAX = 3000
-- His own word: weeks kept per name (heard), and in our own log (said).
RP.WORD_WEEKS = 60
-- Weeks from which a doubtful week needs his word to be excused (the game's launch: every
-- client logs its word from its first kill). Before, a doubtful week is excused without it.
RP.WORD_FROM = 1793692800

local session = math.floor((GetTime and GetTime() or 0) * 1000) % 2147483647
local badge = {}
local enemyBadge = {}
local pending -- the inspect in flight
local lastInspectAt, lastMouseoverAt = -1e9, -1e9
local lastForeignReadyAt = -1e9
local readAt = {}
local candidates, candidatesFor = nil, nil
RP.generation = 0

local function InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

local function ServerNow()
    return math.floor((GetServerTime and GetServerTime()) or (time and time()) or 0)
end

local function Count(value)
    value = math.floor(tonumber(value) or 0)
    return value > 0 and value or 0
end

local function Canon(name)
    if type(name) ~= "string" or name == "" or #name > 60 then return nil end
    local sync = Overlord.Sync
    local canon = sync and sync.CanonicalForeverName and sync:CanonicalForeverName(name) or nil
    if type(canon) ~= "string" or canon == "" then return nil end
    -- The game's own case only, as the ranking: "fOO bAR" is no other player.
    if sync.HasForeverNameCase and not sync:HasForeverNameCase(canon) then return nil end
    return canon
end
RP.Canon = Canon

local function MyName()
    local sync = Overlord.Sync
    local name = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    return type(name) == "string" and name ~= "" and name or nil
end

local function MyFaction()
    local faction = Overlord.PlayerFaction
    return (faction == "Alliance" or faction == "Horde") and faction or nil
end

local function PoolKey()
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool()
    return type(pool) == "string" and pool ~= "" and pool or "-"
end

local function Accessible(value)
    return not canaccessvalue or canaccessvalue(value)
end

local function UnitValue(fn, unit)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, unit)
    if not ok or not Accessible(a) or not Accessible(b) then return nil end
    return a, b
end

local function UnitName(unit)
    local sync = Overlord.Sync
    return sync and sync.CanonicalForeverNameFromUnit and sync:CanonicalForeverNameFromUnit(unit) or nil
end

function RP.WeekIndex(start)
    start = tonumber(start)
    if not start or start <= 0 then return nil end
    return math.floor((start - RP.WEEK_REF) / RP.WEEK_SEC + 0.5)
end

function RP:CurrentWeek()
    local start = Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs()
    return self.WeekIndex(start)
end

local function Table(parent, key)
    local value = parent[key]
    if type(value) ~= "table" then
        value = {}
        parent[key] = value
    end
    return value
end

local function Size(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- A keyed table over its cap loses its oldest entries (age read by at(value)); keys that
-- keep(key) protects are never dropped.
local function TrimOldest(t, cap, at, keep)
    local size = Size(t)
    if size <= cap then return end
    local list = {}
    for key, value in pairs(t) do
        if not (keep and keep(key)) then list[#list + 1] = { k = key, a = at(value) } end
    end
    table.sort(list, function(a, b) return a.a < b.a end)
    for index = 1, math.min(size - cap, #list) do t[list[index].k] = nil end
end

-- Account store of this ranking. claims: rank claims heard; rd: our inspect readings (one
-- per week: lifetime l, today t, time a); gd: the character (GUID) those readings belong
-- to; gf: his faction as the game showed it when we read him; low: a reading lower than
-- the kept ones, waiting for a second one; vw: weeks proven once (week -> top); dw: weeks
-- found doubtful once (kept even when the readings that caught them are gone); close: our
-- own weekly closes (each faction's top 100); cw: every week we closed, with its flags
-- (kept after the close itself is pruned); shown: ranks shown once; ls: per side and name,
-- every kill and every top week our closes ever gave him (the other faction's ranks); ow:
-- his own word, the kills his own client counted each week (heard first-hand from him);
-- lw: weeks where his own word went beyond what the server counted (his lie, remembered). Read for every ranking row painted: the table found last
-- time is reused while it is still the one saved.
local poolCache = {}
local POOL_TABLES = { "claims", "rd", "gd", "gf", "low", "vw", "dw", "close", "cw", "shown", "ls", "ow", "lw", "park" }
function RP:Pool()
    if type(OverlordDB) ~= "table" then return nil end
    local key = PoolKey()
    local root = OverlordDB.rankProof
    local cached = poolCache.pool
    if cached and poolCache.key == key and poolCache.db == OverlordDB and type(root) == "table"
        and root[key] == cached then
        return cached
    end
    root = Table(OverlordDB, "rankProof")
    local pool = Table(root, key)
    for _, name in ipairs(POOL_TABLES) do Table(pool, name) end
    poolCache.pool, poolCache.key, poolCache.db = pool, key, OverlordDB
    candidates = nil
    for name in pairs(badge) do badge[name] = nil end
    for name in pairs(enemyBadge) do enemyBadge[name] = nil end
    return pool
end

local function Invalidate(key)
    if key then
        badge[key] = nil
    else
        for k in pairs(badge) do badge[k] = nil end
        for k in pairs(enemyBadge) do enemyBadge[k] = nil end
    end
    RP.generation = RP.generation + 1
    if RP.RefreshPlates then RP:RefreshPlates(key) end
end
RP.Invalidate = Invalidate

-- Everything known about a name goes (another character took it, or our readings of it
-- were not his).
local PARK_KEYS = { "rd", "gf", "vw", "dw", "ow", "lw", "shown" }
function RP:ForgetCharacter(pool, name)
    -- What a holder had is set aside under his character (GUID), never thrown away: it
    -- comes back when we meet that character again, under any name (StoreReading).
    local guid = pool.gd[name]
    if guid and pool.shown[name] then
        local entry = { at = ServerNow() }
        for _, key in ipairs(PARK_KEYS) do entry[key] = pool[key][name] end
        pool.park[guid] = entry
        TrimOldest(pool.park, 300, function(e) return type(e) == "table" and Count(e.at) or 0 end)
    end
    pool.rd[name], pool.gd[name], pool.low[name], pool.vw[name], pool.shown[name] = nil, nil, nil, nil, nil
    pool.gf[name], pool.dw[name], pool.ow[name], pool.lw[name] = nil, nil, nil, nil
    Invalidate(name)
end

-- ------------------------------------------------------------------ presence and claims

function RP:LocalRank()
    local ranks = Overlord.Ranks
    if not ranks or not ranks.GetState then return 0 end
    local ok, state = pcall(ranks.GetState, ranks)
    local rank = ok and type(state) == "table" and Count(state.rank) or 0
    return rank >= self.MIN_RANK and rank or 0
end

local function B36(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return "0" end
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    while n > 0 do
        local d = n % 36
        out = digits:sub(d + 1, d + 1) .. out
        n = (n - d) / 36
    end
    return out
end

-- Our own word: the kills our own client counted in each recent week (Ranks' record:
-- server counter deltas outside instances, never the ranking's merged row), kept in the
-- character's own save. Others compare it with what the server counted: a ranking row
-- inflated by someone else never counts against us, a word beyond the server would be ours.
function RP:OwnWords()
    local ranks = Overlord.Ranks
    local ok, rec = pcall(function() return ranks and ranks.GetRecord and ranks:GetRecord(false) end)
    if type(OverlordCharDB) ~= "table" then return nil end
    local log = OverlordCharDB.rankWord
    if type(log) ~= "table" then
        log = {}
        OverlordCharDB.rankWord = log
    end
    local era = self:Era()
    if ok and type(rec) == "table" then
        for _, pair in ipairs({ { rec.we, rec.wk }, { rec.pe, rec.pk } }) do
            local week, kills = self.WeekIndex(pair[1]), Count(pair[2])
            if week and week >= era and kills > 0 and kills > Count(log[week]) then log[week] = kills end
        end
    end
    local weeks, said = {}, {}
    for week in pairs(log) do
        if type(week) ~= "number" or week < era then log[week] = nil else weeks[#weeks + 1] = week end
    end
    table.sort(weeks, function(a, b) return a > b end)
    for index = self.WORD_WEEKS + 1, #weeks do log[weeks[index]] = nil end
    -- Said in turn: the weeks that can hold a place (a week counts from 100 kills).
    local floor = Overlord.Ranks and Overlord.Ranks.WEEK_MIN_KILLS or 100
    for index = 1, math.min(#weeks, self.WORD_WEEKS) do
        if Count(log[weeks[index]]) >= floor then said[#said + 1] = weeks[index] end
    end
    return log, said
end

-- Appended to our own presence from rank 11 on ("~q11".."~q15"), with one week of our own
-- word in turn (".<week>-<kills>", base 36): about eight bytes, every week said again
-- within a few presences. Nothing below rank 11.
function RP:PresenceToken()
    -- (Our word is logged whatever our rank: the weeks that make a top rank come before it.)
    local ok, log, weeks = pcall(self.OwnWords, self)
    local rank = self:LocalRank()
    if rank <= 0 then return "" end
    if not ok or not log or not weeks or #weeks == 0 then return "~q" .. rank end
    -- (One week per presence interval, not per call: a repeated presence stays identical.)
    self.wordTurn = math.floor((GetTime and GetTime() or 0) / 120) % #weeks + 1
    local week = weeks[self.wordTurn]
    return "~q" .. rank .. "." .. B36(week) .. "-" .. B36(log[week])
end

-- A presence heard first-hand from a same-faction neighbour (SyncRelay). token: the digits
-- after "~q", nil when its presence carries none (no top rank, or an older client).
function RP:OnPresence(origin, token)
    if InInstance() then return end
    local name = Canon(origin)
    if not name or name == MyName() then return end
    local pool = self:Pool()
    if not pool then return end
    local claims = pool.claims
    local claim = claims[name]
    local rankText, wordWeek, wordKills = nil, nil, nil
    if type(token) == "string" then
        rankText, wordWeek, wordKills = token:match("^(%d%d?)%.(%w+)%-(%w+)$")
        if not rankText then rankText = token:match("^(%d%d?)$") end
    end
    local rank = tonumber(rankText) or 0
    if rank < self.MIN_RANK or rank > 15 or rank ~= math.floor(rank) then rank = 0 end
    -- No top rank said: no news. Ranks are for life, and a presence that failed to read
    -- the rank once must not take a badge away from every neighbour; a claim not heard for
    -- four weeks shows nothing until said again (half a year: it goes). Three in a row (about six minutes) is another
    -- character under that name: a rank shown before waits until we see the character we
    -- read (SameCharacter).
    if rank == 0 then
        -- (Not while we saw the character we read in the last day: the same player on a
        -- computer without his rank data.)
        if claim and ServerNow() - Count(claim.seen) > 86400 then
            claim.none = (claim.none or 0) + 1
            local shown = pool.shown[name]
            if claim.none >= 3 and type(shown) == "table" and not shown.wait then
                shown.wait = "none"
                Invalidate(name)
            end
        end
        return
    end
    local now, faction = ServerNow(), MyFaction()
    if not claim then
        self:MakeRoomForClaim(pool, now)
        claims[name] = { r = rank, at = now, f = faction }
        -- The name was not claimed for a while: another character may have taken it. A
        -- rank shown before waits until we see the character we read (SameCharacter).
        local shown = pool.shown[name]
        if type(shown) == "table" and rank < Count(shown.r) then shown.wait = true end
        -- A name we know nothing about shows nothing: no repaint for it.
        if type(shown) == "table" or pool.rd[name] then Invalidate(name) end
    else
        local quiet = now - Count(claim.at) > self.CLAIM_QUIET
        local changed = claim.r ~= rank or claim.f ~= faction
        claim.r, claim.f, claim.none = rank, faction, nil
        if changed or quiet or now - Count(claim.at) > 86400 then claim.at = now end
        -- His rank is said again: a wait that only came from presences without it ends (a
        -- plain client under a reused name never says a rank). After four weeks of silence
        -- a lower rank than the one shown waits until we see the character we read.
        local shown = pool.shown[name]
        local waitBefore = type(shown) == "table" and shown.wait or nil
        if type(shown) == "table" then
            if quiet and rank < Count(shown.r) then
                shown.wait = true
            elseif shown.wait == "none" then
                shown.wait = nil
            end
        end
        if changed or quiet or (type(shown) == "table" and shown.wait ~= waitBefore) then Invalidate(name) end
    end
    if wordWeek then self:NoteWord(pool, name, tonumber(wordWeek, 36), tonumber(wordKills, 36)) end
end

-- Claims not heard for half a year go (what was read and proven stays). A full table drops
-- first the oldest claim we know nothing about, so free claims cannot push out the ones we
-- read.
function RP:MakeRoomForClaim(pool, now)
    local claims = pool.claims
    local count, oldest, oldestAt, bare, bareAt = 0, nil, math.huge, nil, math.huge
    for name, claim in pairs(claims) do
        local at = type(claim) == "table" and Count(claim.at) or 0
        if at < now - self.CLAIM_DAYS then
            claims[name] = nil
        else
            count = count + 1
            if at < oldestAt then oldest, oldestAt = name, at end
            if not pool.rd[name] and not pool.shown[name] and at < bareAt then bare, bareAt = name, at end
        end
    end
    if count >= self.CLAIMS_MAX then
        -- First a claim we know nothing about, then one without a rank shown, then the oldest.
        local unshown, unshownAt = nil, math.huge
        if not bare then
            for name, claim in pairs(claims) do
                local at = type(claim) == "table" and Count(claim.at) or 0
                if not pool.shown[name] and at < unshownAt then unshown, unshownAt = name, at end
            end
        end
        local drop = bare or unshown or oldest
        if drop then claims[drop] = nil end
    end
end

-- His own word for one week (heard first-hand: the caller makes sure). The highest
-- heard for a week is kept (the running week grows), within the reading window.
function RP:NoteWord(pool, name, week, kills)
    local current = self:CurrentWeek()
    week, kills = tonumber(week), tonumber(kills)
    if not current or not week or not kills or week ~= math.floor(week) or kills < 0 then return end
    if week > current or week < current - 60 or week < (self:Era()) then return end
    kills = math.min(math.floor(kills), 1000000)
    local words = Table(pool.ow, name)
    if kills <= Count(words[week]) then return end
    words[week] = kills
    local weeks = {}
    for kept in pairs(words) do
        if type(kept) == "number" then weeks[#weeks + 1] = kept end
    end
    table.sort(weeks, function(a, b) return a > b end)
    for index = self.WORD_WEEKS + 1, #weeks do words[weeks[index]] = nil end
    -- (Only a finished week changes a proof.)
    if week < current then Invalidate(name) end
end

-- ------------------------------------------------------------------ weekly close

-- Called by the ladder's weekly archive (same marker as Ranks): our view of each faction's
-- top 100 of the finished week. f = 1: ranking compared in the week's last day; 0: played
-- then; -1: neither (its kills still count in the sums, it gives no top).
function RP:BeginClose(marker)
    local ranks = Overlord.Ranks
    if type(marker) ~= "table" or not ranks or not ranks.GetWeekCloseWindow then return nil end
    local epoch, fresh, weekEnd = ranks:GetWeekCloseWindow(marker)
    local flag = fresh and 1 or 0
    local reset = Count(marker.resetEpoch)
    if not epoch then
        epoch = Count(marker.archiveEpoch)
        if epoch == 0 or reset - epoch < (ranks.WEEK_MIN_SEC or 518400) then return nil end
        if reset > ServerNow() + 3600 then return nil end
        flag = -1
    end
    local week = self.WeekIndex(epoch)
    if not week then return nil end
    -- Each faction's view is only as good as the play of that faction's characters: a
    -- view fed through the other faction's eyes (an account with characters on both
    -- sides) is second-hand and partial. A ranking compared in full holds both.
    weekEnd = Count(weekEnd)
    if weekEnd == 0 then weekEnd = epoch + self.WEEK_SEC end
    local fresh24 = (ranks.WEEK_FRESH_SEC or 86400)
    -- Stamps that began after the week's last day began (the update came since): which
    -- side played is unknown; the side of the character closing the week is taken.
    local pool = self:Pool()
    local since = pool and Count(pool.onSince) or 0
    local unknown = since == 0 or since > weekEnd - fresh24
    local ff = {}
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local played = self:OnlineAtOrBefore(faction, weekEnd) >= weekEnd - fresh24
            or (unknown and faction == MyFaction())
        -- (Compared in full: the wider tops hold for both sides; a top 3 or a first only
        -- for a side we played.)
        if flag == 1 then ff[faction] = played and 1 or 0 else ff[faction] = (flag == 0 and played) and 0 or -1 end
    end
    return { week = week, f = flag, ff = ff, Alliance = {}, Horde = {} }
end

-- Presence of a character of this faction in game (outside instances), per ranking pool:
-- a = the last stamp, p = the last stamp of an earlier week (a login just after the reset
-- must not wipe the proof of having played the day before). Stamped at login and on the
-- 30 s tick. Local, nothing is sent.
function RP:NoteOnline()
    local faction = MyFaction()
    if not faction or InInstance() then return end
    local pool = self:Pool()
    if not pool then return end
    local now = ServerNow()
    if now == 0 then return end
    if not pool.onSince then pool.onSince = now end
    local row = Table(Table(pool, "on"), faction)
    local last = Count(row.a)
    if last > now + 3600 then last = 0 end
    local weekStart = Count(Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
    if last > 0 and weekStart > 0 and last < weekStart then row.p = last end
    row.a = now
end

-- The last presence stamp of that faction at or before limit (0: none).
function RP:OnlineAtOrBefore(faction, limit)
    local pool = self:Pool()
    local on = pool and type(pool.on) == "table" and pool.on[faction]
    if type(on) ~= "table" then return 0 end
    local a, p = Count(on.a), Count(on.p)
    if a > 0 and a <= limit then return a end
    if p > 0 and p <= limit then return p end
    return 0
end

local function IsDenied(name)
    local sync = Overlord.Sync
    return sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name) or false
end


-- One row of the finished week: kept in its faction's top 100 (sorted, most kills first).
-- Names set aside by the ladder never take a place.
function RP:OfferCloseRow(close, name, kills, playerInfo)
    if type(kills) ~= "number" or kills <= 0 or type(name) ~= "string" then return end
    local info = type(playerInfo) == "table" and playerInfo[name]
    if type(info) ~= "table" then return end
    -- The row's side by its label, as the holder's own client places him (Ranks): both
    -- sides count the same rows. A label is set once, by the first word heard of a name;
    -- a race can be rewritten later by any page, so it decides nothing here.
    local faction = info.faction
    if (faction ~= "Alliance" and faction ~= "Horde") or not self:Accepts(close, faction, kills) then return end
    if IsDenied(name) then return end
    self:OfferToView(close, faction, name, kills)
end

-- Whether a row with these kills can still enter that view (cheap, checked before the
-- name's own checks: most rows of a week are far below the 100th place).
function RP:Accepts(close, faction, kills)
    local list = close[faction]
    if type(list) ~= "table" then return false end
    local floor = type(close.floor) == "table" and close.floor[faction]
    if floor and kills <= floor then return false end
    return #list < self.CLOSE_TOP or kills >= list[self.CLOSE_TOP].k
end

-- One row into a faction's view (most kills first). Full: below the 100th place's kills,
-- out; a tie with it stays (the whole tie group, whatever order the rows come in). A tie
-- group that would make the view hold more than CLOSE_CAP rows is left out whole, and so
-- is anything at or below its kills from then on (the same names on every client).
function RP:OfferToView(close, faction, name, kills)
    local list = close[faction]
    if type(list) ~= "table" then return end
    local floor = type(close.floor) == "table" and close.floor[faction]
    if floor and kills <= floor then return end
    local size = #list
    if size >= self.CLOSE_TOP and kills < list[self.CLOSE_TOP].k then return end
    local row = { n = name, k = kills }
    local at = size + 1
    while at > 1 and list[at - 1].k < kills do
        list[at] = list[at - 1]
        at = at - 1
    end
    list[at] = row
    -- Rows pushed beyond the 100th place by a better one go, unless tied with it.
    local cut = list[self.CLOSE_TOP]
    while cut and #list > self.CLOSE_TOP and list[#list].k < cut.k do list[#list] = nil end
    if #list > self.CLOSE_CAP then
        local value = list[self.CLOSE_TOP].k
        close.floor = close.floor or {}
        close.floor[faction] = value
        while #list > 0 and list[#list].k <= value do list[#list] = nil end
    end
end

-- End of the walk: both factions' top 100 stored for this week (each name with its kills
-- and its place, ties sharing a place), kept half a year; old data is pruned and every badge
-- checked again.
function RP:FinishClose(close)
    local pool = type(close) == "table" and self:Pool()
    if not pool then return end
    self:CheckEra(pool)
    -- A week from before the era (the beta's last week closed after the launch) is not kept.
    if close.week < (self:Era()) then
        candidates = nil
        Invalidate()
        return
    end
    pool.cw[close.week] = { f = close.f, ff = close.ff }
    local entry = { f = close.f, ff = close.ff, c = {} }
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local view = {}
        local place, previous = 0, nil
        for index, row in ipairs(close[faction]) do
            if row.k ~= previous then place, previous = index, row.k end
            local name = Canon(row.n)
            -- (A variant spelling of the same name never overwrites its best row.)
            if name and view[name] == nil then view[name] = place * 65536 + math.min(row.k, 65535) end
        end
        entry[faction] = view
        -- The kills it took to finish in each top (the last place of that top).
        local cut = {}
        for index, top in ipairs(self.TOPS) do
            local row = close[faction][top]
            cut[index] = row and math.min(row.k, 65535) or 0
        end
        entry.c[faction] = cut
    end
    pool.close[close.week] = entry
    self:AddLadderStats(pool, close.week, entry)
    for week in pairs(pool.close) do
        if type(week) ~= "number" or week <= close.week - self.CLOSE_WEEKS then pool.close[week] = nil end
    end
    candidates = nil
    -- (Pruning waits for the next frame: the weekly close stays light.)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() pcall(RP.Prune, RP, pool) end)
    else
        self:Prune(pool)
    end
    Invalidate()
end

-- A stored place and kills (place * 65536 + kills).
local function Unpack(value)
    value = Count(value)
    return math.floor(value / 65536), value % 65536
end

-- Each side's running totals, from our closes alone: every kill and every top week (its
-- narrowest top, by the close's own flag) of each name. Counted once per week. Players of
-- the other faction cannot be inspected: this is how their ranks are told (the same
-- ranking the Nemesis skull reads).
function RP:AddLadderStats(pool, week, entry)
    if week <= (tonumber(pool.lsWeek) or -math.huge) then return end
    -- (A week dated beyond the current one is no real close: it would freeze the totals.)
    if week > (self:CurrentWeek() or week) then return end
    pool.lsWeek = week
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local side = Table(pool.ls, faction)
        for name, value in pairs(entry[faction] or {}) do
            local place, kills = Unpack(value)
            local stats = side[name]
            if type(stats) ~= "table" then
                stats = {}
                side[name] = stats
            end
            stats.k = Count(stats.k) + kills
            local top = self:TopFor(place, kills, tonumber(entry.f) or -1)
            if top then stats[top] = Count(stats[top]) + 1 end
        end
        -- (Trimmed in steps, not a sort at every close once full.)
        if Size(side) > self.LS_MAX * 1.1 then TrimOldest(side, self.LS_MAX, function(stats) return type(stats) == "table" and Count(stats.k) or 0 end) end
    end
end

-- The rank a player of the other faction reaches in our closes alone (0 = none): the kills
-- our closes ever gave him reach the rank's whole Glory (they are the same open-world kills
-- as his own Glory, so the badge never shows more than he has), and enough weeks at its
-- top. Never for a name the ranking set aside. Cached until the next close.
function RP:EnemyRank(pool, name, faction)
    local cached = enemyBadge[name]
    if cached ~= nil then return cached end
    local rank = 0
    local side = type(pool.ls) == "table" and pool.ls[faction]
    local stats = type(side) == "table" and side[name]
    local tiers = Overlord.Ranks and Overlord.Ranks.TIERS
    if type(stats) == "table" and tiers and not IsDenied(name) then
        for r = 15, self.MIN_RANK, -1 do
            local tier = tiers[r]
            if tier and tier.top and Count(stats.k) >= tier.glory then
                local counted = 0
                for _, top in ipairs(self.TOPS) do
                    if top <= tier.top then counted = counted + Count(stats[top]) end
                end
                if counted >= (tier.weeks or 0) then
                    rank = r
                    break
                end
            end
        end
    end
    enemyBadge[name] = rank
    return rank
end

-- The other faction, when our ranking labels that name with it.
function RP:EnemySide(rawName)
    local mine, lb = MyFaction(), Overlord.Leaderboard
    if not mine or not (lb and lb.GetPlayerInfo) then return nil end
    local ok, info = pcall(lb.GetPlayerInfo, lb, rawName)
    local label = ok and type(info) == "table" and info.faction or nil
    if (label == "Alliance" or label == "Horde") and label ~= mine then return label end
    return nil
end

-- Whether our close of a week can tell that top, by Ranks' own rule: the wider tops need
-- us in game during the week's last day (flag 0), a top 3 or a first needs the ranking
-- also compared then (flag 1). A close made days later holds a ranking frozen before the
-- end of the week: it places nobody (that week is one we did not see), its kills still
-- count against the server's.
local function Usable(flag, top)
    flag = tonumber(flag) or -1
    local ranks = Overlord.Ranks
    if top <= (ranks and ranks.WEEK_STRICT_TOP or 3) then return flag >= 1 end
    return flag >= 0
end

-- Our flag for that faction's view of a close (older closes carry one flag for both).
local function FlagOf(close, faction)
    local ff = type(close.ff) == "table" and close.ff[faction]
    return tonumber(ff) or tonumber(close.f) or -1
end

-- The narrowest top a place reaches (Ranks' rules: a week counts from 100 kills, a first
-- place needs 1,000 kills, and each top needs a close that can tell it; see Usable).
function RP:TopFor(place, kills, flag)
    local ranks = Overlord.Ranks
    local weekMin = ranks and ranks.WEEK_MIN_KILLS or 100
    local firstMin = ranks and ranks.WEEK_FIRST_MIN_KILLS or 1000
    if kills < weekMin then return nil end
    for _, top in ipairs(self.TOPS) do
        if place <= top and (top > 1 or kills >= firstMin) and Usable(flag, top) then
            return top
        end
    end
    return nil
end

-- Old data goes at each weekly close: readings of players not read for a year, then the
-- oldest entries of any table over its cap.
function RP:Prune(pool)
    local yearAgo = ServerNow() - 52 * self.WEEK_SEC
    local function newest(readings)
        local at = 0
        for _, reading in pairs(readings) do
            if type(reading) == "table" then at = math.max(at, Count(reading.a)) end
        end
        return at
    end
    for name, readings in pairs(pool.rd) do
        if newest(readings) < yearAgo and not pool.shown[name] then pool.rd[name] = nil end
    end
    TrimOldest(pool.rd, self.READ_KEYS, function(readings)
        return newest(readings)
    end, function(name) return pool.claims[name] ~= nil or pool.shown[name] ~= nil end)
    for name in pairs(pool.gd) do
        if not pool.rd[name] and not pool.shown[name] then pool.gd[name] = nil end
    end
    local function stamp(value) return type(value) == "table" and Count(value.at) or 0 end
    for name, value in pairs(pool.low) do
        if stamp(value) < yearAgo then pool.low[name] = nil end
    end
    TrimOldest(pool.low, self.LIST_MAX, stamp)
    -- A rank shown is for life: never aged out; only a very large table loses its oldest.
    TrimOldest(pool.shown, self.SHOWN_MAX, stamp)
    for name in pairs(pool.vw) do
        if not pool.rd[name] and not pool.shown[name] then pool.vw[name] = nil end
    end
    for name in pairs(pool.gf) do
        if not pool.gd[name] then pool.gf[name] = nil end
    end
    local oldest = (self:CurrentWeek() or 0) - 60
    for _, key in ipairs({ "ow", "lw" }) do
        for name, weeks in pairs(pool[key]) do
            if not pool.claims[name] and not pool.rd[name] and not pool.shown[name] then
                pool[key][name] = nil
            elseif type(weeks) == "table" then
                for week in pairs(weeks) do
                    if type(week) ~= "number" or week < oldest then weeks[week] = nil end
                end
            end
        end
    end
    for name, weeks in pairs(pool.dw) do
        if not pool.rd[name] and not pool.shown[name] then
            pool.dw[name] = nil
        elseif type(weeks) == "table" then
            for week in pairs(weeks) do
                if type(week) ~= "number" or week < oldest then weeks[week] = nil end
            end
        end
    end
end

-- ------------------------------------------------------------------ proof

-- Our readings of a player, oldest week first: { week, l (lifetime), t (today), at, ss }.
local function Readings(pool, name)
    local out = {}
    local current = RP:CurrentWeek() or 0
    for week, reading in pairs(pool.rd[name] or {}) do
        if type(week) == "number" and type(reading) == "table" and week <= current + 1
            and week >= current - 60 and week == math.floor(week) then
            out[#out + 1] = { week = week, l = Count(reading.l), t = Count(reading.t), at = Count(reading.a) }
        end
    end
    table.sort(out, function(a, b) return a.week < b.week end)
    return out
end
RP.Readings = Readings

-- The server count at a reading. Whether the lifetime figure already holds today's kills
-- is not known: "high" adds today's, which only ever helps the player.
local function Total(reading, high)
    return reading.l + (high and reading.t or 0)
end

local function Slack(kills)
    return math.max(50, math.ceil(0.03 * kills))
end

-- Our ranking's word on one week for this player: its top (nil if none), his kills (0 when
-- he is not in our top 100 that week, or we have no close of it) and our close (nil: none).
function RP:WeekOf(pool, name, week, faction)
    local close = pool.close[week]
    if type(close) ~= "table" then return nil, 0, nil end
    -- His kills count wherever a view holds him: a row moved to the other side hides
    -- nothing from the server's count.
    local other = close[faction == "Alliance" and "Horde" or "Alliance"]
    local elsewhere = type(other) == "table" and other[name]
    local kills = 0
    if elsewhere then
        local _, count = Unpack(elsewhere)
        kills = count
    end
    local view = close[faction]
    local value = type(view) == "table" and view[name]
    if not value then return nil, kills, close end
    local place, own = Unpack(value)
    return self:TopFor(place, own, FlagOf(close, faction)), math.max(own, kills), close
end

-- What our closes and readings say of a player. A week is proven when our own close of it
-- put him in a top, it lies between two of our readings (the server counted it), and no
-- reading of ours contradicts it. A contradiction: the server counted fewer kills between
-- two of our readings, or before one (from zero), than our ranking gave him in the weeks
-- between, even counted the most favourable way for him: those weeks are doubtful. A top
-- week before our first reading is only unverified: the server's count holds its kills but
-- says nothing of when they were made. Weeks after our last reading wait for the next one.
-- Returns proven (week -> top), doubtful (week -> true), readings, his kills in our closes
-- before a week (prior(week)), unverified (week -> top), final (week -> true: doubt that can
-- no longer change) and kills (week -> his kills in our close of it).
function RP:Evidence(pool, name, faction)
    local readings = Readings(pool, name)
    local proven, doubtful = {}, {}
    local weeks, kills, tops = {}, {}, {}
    for week in pairs(pool.close) do
        if type(week) == "number" then weeks[#weeks + 1] = week end
    end
    table.sort(weeks)
    for _, week in ipairs(weeks) do
        tops[week], kills[week] = self:WeekOf(pool, name, week, faction)
    end
    -- upTo[i]: his kills over our first i closes; below(week): how many closes come before it.
    local upTo = { [0] = 0 }
    for index, week in ipairs(weeks) do upTo[index] = upTo[index - 1] + kills[week] end
    local function below(week)
        local count = 0
        for _, closed in ipairs(weeks) do
            if closed < week then count = count + 1 else break end
        end
        return count
    end
    local function prior(week) return upTo[below(week)] end
    local unverified = {}
    if #readings == 0 then return proven, doubtful, readings, prior, unverified, {}, kills, {}, {} end
    -- For each reading: the closes before its week, and those up to it.
    local before, through = {}, {}
    for index, reading in ipairs(readings) do
        before[index] = below(reading.week)
        through[index] = below(reading.week + 1)
    end
    -- Whether the server counted fewer kills from reading a (0: from zero) to reading b
    -- than our closes gave him strictly between them, counted his way (b's today added).
    local function fails(a, b)
        local sum = upTo[before[b]] - (a > 0 and upTo[math.min(through[a], before[b])] or 0)
        local growth = Total(readings[b], true) - (a > 0 and Total(readings[a], false) or 0)
        return sum > 0 and growth < sum - Slack(sum)
    end
    local n = #readings
    -- Doubt from a reading of the week still running can change with its next reading
    -- (the same week's reading is replaced): only doubt from finished weeks is final.
    local current = self:CurrentWeek() or 0
    local final = {}
    local function mark(week, closing)
        doubtful[week] = true
        if closing < current and tops[week] then final[week] = true end
    end
    -- Each stretch between two readings next to each other (before the first one, from
    -- zero): when it fails, its weeks are doubtful. A later reading never reopens an
    -- earlier stretch, so a row inflated later cannot undo weeks proven before.
    for b = 1, n do
        if fails(b - 1, b) then
            local from = b > 1 and readings[b - 1].week or -math.huge
            for _, week in ipairs(weeks) do
                if week > from and week < readings[b].week then mark(week, readings[b].week) end
            end
        end
    end
    -- A reading's own week lies in neither stretch: it is judged between its neighbours.
    for i = 1, n - 1 do
        if fails(i - 1, i + 1) then mark(readings[i].week, readings[i + 1].week) end
    end
    -- His own word judged the same way: the kills his own client said it counted, against
    -- the server's count, his way. Beyond it, the lie is his (an honest word comes from the
    -- server's own counter): those weeks are refused. Within it, a doubtful week for which
    -- we hold his word is someone else's row: it is excused (unverified). A doubtful week
    -- without his word waits for it.
    local words = type(pool.ow) == "table" and pool.ow[name] or nil
    local lied, liedFinal, wordLoose = {}, {}, {}
    -- What we remember of him: weeks found doubtful, and his lies.
    for week in pairs(type(pool.dw) == "table" and pool.dw[name] or {}) do doubtful[week] = true end
    for week in pairs(type(pool.lw) == "table" and pool.lw[name] or {}) do lied[week] = true end
    if type(words) == "table" and next(words) then
        local function said(from, to)
            local sum = 0
            for week, count in pairs(words) do
                if type(week) == "number" and week > from and week < to then sum = sum + Count(count) end
            end
            return sum
        end
        -- (A wider margin than for the rows: a word is never judged a lie on one reading
        -- that may lag the server by a few hours of kills.)
        local function lies(a, b)
            local from = a > 0 and readings[a].week or -math.huge
            local sum = said(from, readings[b].week)
            local growth = Total(readings[b], true) - (a > 0 and Total(readings[a], false) or 0)
            return sum > 0 and growth < sum - math.max(150, math.ceil(0.1 * sum)), from
        end
        -- Within the lie margin but beyond the rows' slack: not a lie, but too loose to
        -- prove a week by his word alone (it may still complete a rank).
        local function loose(a, b)
            local from = a > 0 and readings[a].week or -math.huge
            local sum = said(from, readings[b].week)
            local growth = Total(readings[b], true) - (a > 0 and Total(readings[a], false) or 0)
            return sum > 0 and growth < sum - Slack(sum), from
        end
        for b = 1, n do
            local bad, from = loose(b - 1, b)
            if bad then
                for week in pairs(words) do
                    if type(week) == "number" and week > from and week < readings[b].week then wordLoose[week] = true end
                end
            end
        end
        for i = 1, n - 1 do
            if loose(i - 1, i + 1) then wordLoose[readings[i].week] = true end
        end
        -- A week our close gives him kills for but he gave no word for cannot clear a lie:
        -- its real kills would pay for the lie.
        local function silent(week) return Count(kills[week]) > 0 and Count(words[week]) == 0 end
        local function blame(week, closing)
            lied[week] = true
            if closing < current then liedFinal[week] = true end
        end
        -- A lie is final only when the next reading confirms it (the wider stretch still
        -- falls short): one reading that lags the server only holds while it lasts.
        for b = 1, n do
            local bad, from = lies(b - 1, b)
            local sure = bad and b < n and lies(b - 1, b + 1)
            -- (Only a reading of the very next week can clear it: a later one would let kills
            -- made since pay for the lie. Otherwise it stays open, refused, not remembered.)
            local nearNext = b < n and readings[b + 1].week - readings[b].week <= 1 and not silent(readings[b].week)
            if bad and (sure or not nearNext) then
                for week, count in pairs(words) do
                    if type(week) == "number" and Count(count) > 0 and week > from and week < readings[b].week then
                        blame(week, sure and readings[b].week or current)
                    end
                end
            end
        end
        for i = 1, n - 1 do
            if lies(i - 1, i + 1) and Count(words[readings[i].week]) > 0 then
                local sure = i + 2 <= n and lies(i - 1, i + 2)
                local nearNext = i + 2 <= n and readings[i + 2].week - readings[i + 1].week <= 1
                    and not silent(readings[i + 1].week)
                if sure or not nearNext then blame(readings[i].week, sure and readings[i + 1].week or current) end
            end
        end
    end
    -- Proven: between two readings at most BRACKET_WEEKS whole weeks apart, and not doubtful.
    -- Further apart, before our first reading, or doubtful, the week is only unverified: it
    -- can complete a rank, never start one (a player who really made his weeks is never
    -- refused a rank because a ranking row of his was wrong somewhere). After our last
    -- reading: nothing yet.
    -- A doubtful week excused by his word counts only at the top his word reaches in our
    -- close (a low true word never keeps the place of an inflated row).
    local wordFrom = self.WeekIndex(self.WORD_FROM) or math.huge
    local function excusedTop(week)
        local word = type(words) == "table" and Count(words[week]) or 0
        if word == 0 then return week < wordFrom and tops[week] or nil end
        local close = pool.close[week]
        local view = type(close) == "table" and close[faction]
        if type(view) ~= "table" then return nil end
        local above = 0
        for other, value in pairs(view) do
            if other ~= name then
                local _, count = Unpack(value)
                if count > word then above = above + 1 end
            end
        end
        local top = self:TopFor(above + 1, word, FlagOf(close, faction))
        if top and tops[week] and tops[week] > top then top = tops[week] end
        return top
    end
    for _, week in ipairs(weeks) do
        local byWord = doubtful[week] and type(words) == "table" and Count(words[week]) > 0 and not wordLoose[week]
        if tops[week] and not lied[week] and doubtful[week] then tops[week] = excusedTop(week) end
        if tops[week] and not lied[week] then
            local earlier, later
            for _, reading in ipairs(readings) do
                if reading.week < week then
                    earlier = reading
                elseif reading.week > week and not later then
                    later = reading
                end
            end
            -- (His own word, within the server's count, proves the week as well as the row:
            -- a rival inflating his rows never keeps him from starting a rank.)
            if (not doubtful[week] or byWord) and earlier and later
                and later.week - earlier.week - 1 <= self.BRACKET_WEEKS then
                proven[week] = tops[week]
            elseif later then
                unverified[week] = tops[week]
            end
        end
    end
    return proven, doubtful, readings, prior, unverified, final, kills, lied, liedFinal
end

-- A new era (the game's launch after the beta): what was read, closed and proven before
-- belongs to characters of another world. Only when the current week is known.
function RP:CheckEra(pool)
    if not pool or not self:CurrentWeek() then return end
    local era = self:Era()
    local kept = tonumber(pool.era)
    if kept and kept < era then
        for _, key in ipairs(POOL_TABLES) do pool[key] = {} end
        pool.on, pool.onSince, pool.lsWeek = nil, nil, nil
        candidates = nil
        Invalidate()
    end
    pool.era = era
end

-- The era's first week (weeks before it can hold no rank week) and the current week.
function RP:Era()
    local current = self:CurrentWeek() or 0
    local launch = self.WeekIndex(self.ERA_LAUNCH)
    return current >= launch and launch or self.WeekIndex(self.ERA_BETA), current
end

-- The fewest kills one of our usable closes needed for that top in this faction, never
-- below Ranks' floors (100 a week, 1,000 for a first place).
function RP:TopCut(pool, faction, top)
    local ranks = Overlord.Ranks
    local floor = top == 1 and (ranks and ranks.WEEK_FIRST_MIN_KILLS or 1000)
        or (ranks and ranks.WEEK_MIN_KILLS or 100)
    local index
    for i, value in ipairs(self.TOPS) do
        if value == top then index = i end
    end
    local best
    for _, close in pairs(pool.close) do
        local cut = index and type(close) == "table" and type(close.c) == "table" and close.c[faction]
        local value = type(cut) == "table" and tonumber(cut[index]) or 0
        if value >= floor and Usable(FlagOf(close, faction), top) and (not best or value < best) then best = value end
    end
    return best or floor
end

-- Weeks of the era before that week (our reading's: the server's count could not hold the
-- kills of later weeks) that we cannot tell for that top: never closed by us (and no week
-- kept for him), or closed in a way that cannot tell that top (Usable). A week we closed
-- stays known after its close was pruned.
function RP:UnseenWeeks(pool, faction, kept, untilWeek, top)
    local era, current = self:Era()
    local unseen, list = 0, {}
    for week = era, math.min(current, untilWeek) - 1 do
        local close = pool.close[week]
        local known
        local closed = type(close) == "table" and close or pool.cw[week]
        if type(closed) == "table" then
            known = Usable(FlagOf(closed, faction), top) or (kept and kept[week] ~= nil)
        else
            known = kept and kept[week] ~= nil
        end
        if not known then
            unseen = unseen + 1
            list[#list + 1] = week
        end
    end
    return unseen, list
end

-- The rank a player's proof reaches (0 = none), never above his claim: the server's lifetime
-- count (our reading) reaches 75 % of the rank's Glory and enough weeks are proven at that
-- top (strict). When they are not, open(top, missing) may give the missing weeks (see
-- ProvenRank). Returns rank, strict.
function RP:RankFromProof(claimed, lifetime, weeks, open)
    local tiers = Overlord.Ranks and Overlord.Ranks.TIERS
    if not tiers then return 0, false end
    for rank = math.min(Count(claimed), 15), self.MIN_RANK, -1 do
        local tier = tiers[rank]
        local top = tier and tier.top
        if top and lifetime >= self.ANCHOR * tier.glory then
            local counted = 0
            for _, weekTop in pairs(weeks) do
                if weekTop <= top then counted = counted + 1 end
            end
            local need = tier.weeks or 0
            if counted >= need then return rank, true end
            if open and counted >= 1 and open(top, need - counted) then return rank, false end
        end
    end
    return 0, false
end

-- The rank this client shows for that player (0 = none), never above his claim. Weeks
-- proven are kept, and so is a rank once fully proven, for that same character. Other
-- weeks may complete a rank, never start one: he must have reached that very top in a week
-- proven by us. They are first his unverified top weeks (before our first reading, between
-- readings too far apart, or doubtful), then weeks of the era before our last
-- reading that we cannot tell (we were not playing, or not yet), for which the server's
-- count must hold that many weeks at that top (at the fewest kills our closes saw it take)
-- beyond all our closes gave him. Cached until something changes.
function RP:ProvenRank(name)
    local cached = badge[name]
    if cached ~= nil then return cached end
    local rank = 0
    local pool, faction = self:Pool(), MyFaction()
    local claim = pool and pool.claims[name]
    -- A rank shown before under a name claimed anew waits until we see the character we
    -- read (SameCharacter): another character may have taken the name.
    local waiting = claim and type(pool.shown[name]) == "table" and pool.shown[name].wait
    if claim and faction and (claim.f == nil or claim.f == faction) and not waiting then
        local _, doubtful, readings, prior, unverified, kept, kills, lied = self:Record(pool, name, faction)
        local lifetime, newest = 0, readings[#readings]
        for _, reading in ipairs(readings) do lifetime = math.max(lifetime, reading.l) end
        local proved = 0
        if newest and kept then
            proved = self:RankFromProof(claim.r, lifetime, kept)
            rank = proved
            -- (A player caught lying about his own count completes nothing on this client.)
            if proved < Count(claim.r) and not next(lied) then
                local spare = Total(newest, true) - prior(newest.week)
                local open = function(top, missing)
                    for week, weekTop in pairs(unverified) do
                        -- (A week proven before, now ahead of our oldest kept reading, counts once.)
                        if weekTop <= top and not kept[week] then missing = missing - 1 end
                    end
                    if missing <= 0 then return true end
                    local unseen, unseenWeeks = self:UnseenWeeks(pool, faction, kept, newest.week, top)
                    if missing > unseen then return false end
                    -- (A week closed without telling his place already counts his kills in
                    -- prior: it is not charged twice.)
                    local refund = 0
                    for _, week in ipairs(unseenWeeks) do refund = refund + (kills[week] or 0) end
                    return missing * self:TopCut(pool, faction, top) <= spare + refund
                end
                rank = math.max(rank, (self:RankFromProof(claim.r, lifetime, kept, open)))
            end
        end
        -- What is shown is kept for life, a rank completed by other weeks too (never above
        -- his claim): a holder must never lose a badge he was shown with.
        local shown = pool.shown[name]
        local keep = math.min(rank, Count(claim.r))
        if keep > 0 and (type(shown) ~= "table" or Count(shown.r) < keep) then
            pool.shown[name] = { r = keep, at = ServerNow() }
            shown = nil
        end
        if type(shown) == "table" then
            rank = math.max(rank, Count(shown.r))
            if ServerNow() - Count(shown.at) > 86400 then shown.at = ServerNow() end
        end
        -- Never above his claim, unless we showed him higher before (a rank is for life: an
        -- older client or a second computer saying less takes nothing away).
        local shownRec = pool.shown[name]
        local floor = (type(shownRec) == "table" and not shownRec.wait) and Count(shownRec.r) or 0
        rank = math.min(rank, math.max(Count(claim.r), floor))
    end
    if pool and faction then badge[name] = rank end
    return rank
end

-- What our closes and readings prove of a player, merged into what we keep of him. Final
-- doubt is remembered (trimming the readings that caught a top week never makes it proven);
-- a week proven once stays proven; doubt from the week still running only holds while it
-- lasts. Run for any player we read, claim or not: what is kept never depends on when
-- his claim was first heard. Returns proven, doubtful, readings, prior, unverified, kept,
-- kills (as Evidence).
function RP:Record(pool, name, faction)
    local proven, doubtful, readings, prior, unverified, final, kills, lied, liedFinal =
        self:Evidence(pool, name, faction)
    -- His lies are remembered and refused: never proven, never unverified, and a week he
    -- lied about leaves what we kept of him.
    local lies = pool.lw[name]
    for week in pairs(liedFinal) do
        lies = lies or Table(pool.lw, name)
        lies[week] = true
    end
    for week in pairs(lies or {}) do lied[week] = true end
    local words = type(pool.ow) == "table" and pool.ow[name] or nil
    local remembered = pool.dw[name]
    for week in pairs(final) do
        remembered = remembered or Table(pool.dw, name)
        remembered[week] = true
    end
    -- (A week remembered doubtful is never proven again, only unverified; a week proven once
    -- stays proven.)
    for week in pairs(lied) do proven[week], unverified[week] = nil, nil end
    -- (A week proven once stays proven: a lie refuses it from the count, never from what is kept.)
    local kept = pool.vw[name]
    for week, top in pairs(proven) do
        kept = kept or Table(pool.vw, name)
        if not kept[week] or top < kept[week] then kept[week] = top end
    end
    -- (A lie found by a reading of the running week holds while it lasts: those weeks are
    -- left out of what counts, not out of what is kept.)
    local counted = kept
    if kept and next(lied) then
        counted = {}
        for week, top in pairs(kept) do
            if not lied[week] then counted[week] = top end
        end
    end
    return proven, doubtful, readings, prior, unverified, counted, kills, lied
end

-- What the ranking and nameplates show next to a name: the proven rank of another player
-- of our faction (0 = no badge). Our own rank is in the character sheet, not here: a badge
-- on our own name would suggest the others see it too.
-- side: the faction the game shows him in (a unit), when known.
function RP:GetBadgeRank(rawName, side)
    if InInstance() then return 0 end
    local name = Canon(rawName)
    if not name or name == MyName() or IsDenied(name) then return 0 end
    local pool = self:Pool()
    if not pool then return 0 end
    -- A player of the other faction: from our own closes alone, as the Nemesis skull.
    -- (A claim is heard first-hand on our faction's channel: a claimant is ours, whatever
    -- label the ranking holds.)
    local enemy = side
    if enemy == MyFaction() then
        enemy = nil
    elseif not enemy then
        local heard = pool.claims[name]
        local ours = (type(heard) == "table" and (heard.f == nil or heard.f == MyFaction()))
            or pool.gf[name] == MyFaction()
        if not ours then enemy = self:EnemySide(rawName) end
    end
    if enemy then
        local ok, rank = pcall(self.EnemyRank, self, pool, name, enemy)
        return ok and rank or 0
    end
    local claim = pool.claims[name]
    if not claim then return 0 end
    -- A claim not heard for four weeks shows nothing (the name may have changed hands):
    -- it shows again as soon as his rank is said again.
    if ServerNow() - Count(claim.at) > self.CLAIM_QUIET then return 0 end
    -- The character we read was on the other side (an account with characters on both):
    -- no badge here. The game said it when we read him, nothing another client can push.
    local side = pool.gf[name]
    if side and side ~= MyFaction() then return 0 end
    -- Never an error into the ranking's painting: a damaged entry shows no badge.
    local ok, rank = pcall(self.ProvenRank, self, name)
    if not ok then
        badge[name] = 0
        return 0
    end
    return rank
end

-- A unit seen: if it is another character than the one our readings of that name belong
-- to, everything known about the name goes. Returns false then.
function RP:SameCharacter(pool, name, unit)
    local known = pool.gd[name]
    if not known then return true end
    local guid = UnitValue(UnitGUID, unit)
    if type(guid) ~= "string" then return true end
    if guid == known then
        local claim = pool.claims[name]
        if type(claim) == "table" then claim.none, claim.seen = nil, ServerNow() end
        local shown = pool.shown[name]
        if type(shown) == "table" and shown.wait then
            shown.wait = nil
            Invalidate(name)
        end
        return true
    end
    self:ForgetCharacter(pool, name)
    return false
end

-- ------------------------------------------------------------------ inspect readings

local staleInspectSince, staleInspectKey
-- guid: the player we are about to inspect.
local function InspectBusy(guid)
    local inspect = InspectFrame
    if inspect and inspect.IsShown and inspect:IsShown() then
        staleInspectSince, staleInspectKey = nil, nil
        return true
    end
    -- The game's inspect sent and not answered yet (its window shows on the answer). Never
    -- the player it waits for: our answer would open the game's window. Anyone else after
    -- ten seconds of the same wait (one never answered leaves its unit set).
    if inspect and inspect.unit ~= nil then
        local waited = UnitValue(UnitGUID, inspect.unit)
        if guid and waited == guid then return true end
        local key = tostring(inspect.unit) .. "|" .. tostring(waited)
        if staleInspectKey ~= key then staleInspectSince, staleInspectKey = GetTime(), key end
        if GetTime() - staleInspectSince < 10 then return true end
    else
        staleInspectSince, staleInspectKey = nil, nil
    end
    local spells = PlayerSpellsFrame
    if spells and spells.IsInspecting then
        local ok, busy = pcall(spells.IsInspecting, spells)
        if ok and busy then return true end
    end
    return false
end

local function InCombat()
    if InCombatLockdown and InCombatLockdown() then return true end
    local busy = UnitValue(UnitAffectingCombat, "player")
    return busy == true
end

-- Players worth a reading: our faction's claimants, and the names of our faction in our
-- last closes' top 100 (their top weeks can only be proven if they were read before and
-- after them). Rebuilt after a close.
function RP:IsCandidate(pool, name)
    local claim = pool.claims[name]
    if claim and (claim.f == nil or claim.f == MyFaction()) then return true end
    return self:InCloses(pool, name)
end

-- A name of our faction in our last closes' top 100.
function RP:InCloses(pool, name)
    local faction = MyFaction()
    if candidatesFor ~= faction or not candidates then
        candidates, candidatesFor = {}, faction
        local current = self:CurrentWeek() or 0
        for week, close in pairs(pool.close) do
            local view = type(week) == "number" and week >= current - self.CANDIDATE_WEEKS
                and type(close) == "table" and faction and close[faction]
            if type(view) == "table" then
                for who in pairs(view) do candidates[who] = true end
            end
        end
    end
    return candidates[name] == true
end

-- A player whose reading is due, seen as this unit: inspected (one at a time, out of
-- combat, never while the player inspects someone himself, never right after another
-- inspect's answer). diagnose (/ov proof): any same-faction player, now, and the value read
-- is printed. claimants: only a player whose claim we hold (the badges come first; the
-- others are read on the 30 s tick when no claimant is due). Returns nil when an inspect
-- was sent, else why not.
function RP:TryInspect(unit, diagnose, claimants)
    if pending then return "busy" end
    local now = GetTime()
    if now - lastInspectAt < self.INSPECT_GAP then return "wait" end
    if InInstance() or not unit then return "instance" end
    local pool = self:Pool()
    if not pool then return "none" end
    if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return "unit" end
    if UnitValue(UnitFactionGroup, unit) ~= MyFaction() then return "faction" end
    local name = UnitName(unit)
    if not name or (not diagnose and not self:IsCandidate(pool, name)) then return "unit" end
    -- Claimants first, but only those our closes or readings give a reason to read: a
    -- free claim (nobody of our top) waits for the tick's second pass with the others.
    if claimants and not diagnose then
        local claim = pool.claims[name]
        if not claim or (claim.f ~= nil and claim.f ~= MyFaction()) then return "unit" end
        if not pool.rd[name] and not self:InCloses(pool, name) then return "unit" end
    end
    if not self:SameCharacter(pool, name, unit) and not diagnose then return "unit" end
    if not diagnose and readAt[name] and now < readAt[name] then return "wait" end
    if now - lastForeignReadyAt < self.FOREIGN_QUIET then return "busy" end
    if InCombat() or UnitValue(UnitAffectingCombat, unit) == true then return "combat" end
    if InspectBusy(UnitValue(UnitGUID, unit)) then return "busy" end
    if UnitValue(CanInspect, unit) ~= true then return "range" end
    if type(CheckInteractDistance) == "function" then
        local ok, near = pcall(CheckInteractDistance, unit, 1)
        if ok and Accessible(near) and near == false then return "range" end
    end
    local guid = UnitValue(UnitGUID, unit)
    if type(guid) ~= "string" or guid == "" or type(NotifyInspect) ~= "function" then return "unit" end
    lastInspectAt = now
    -- Nothing back: the same player is tried again after five minutes.
    readAt[name] = now + self.INSPECT_RETRY
    pending = { guid = guid, unit = unit, name = name, at = now, diagnose = diagnose }
    pcall(self.RegisterHonorEvent, self, true)
    if not pcall(NotifyInspect, unit) then
        self:EndInspect()
        return "refused"
    end
    local mine = pending
    if C_Timer and C_Timer.After then
        C_Timer.After(self.INSPECT_TIMEOUT, function()
            if pending ~= mine or mine.settling then return end
            RP:EndInspect()
            if mine.diagnose then
                RP:Say(string.format("%s: no honor data within %d s (ready: %s, early honor: %s, other inspect: %s)",
                    mine.name, RP.INSPECT_TIMEOUT, tostring(mine.ready == true), tostring(mine.early ~= nil),
                    tostring(mine.foreign == true)))
            end
        end)
    end
    return nil
end

function RP:EndInspect()
    pending = nil
    pcall(self.RegisterHonorEvent, self, false)
end

-- The honor data now held by the client, or nil.
local function HonorData()
    if type(GetInspectHonorData) ~= "function" then return nil end
    local ok, today, _, _, _, lifetime = pcall(GetInspectHonorData)
    if not ok or type(lifetime) ~= "number" or not Accessible(lifetime) then return nil end
    lifetime = math.floor(lifetime)
    if lifetime <= 0 or lifetime >= 10000000 then return nil end
    today = (type(today) == "number" and Accessible(today)) and math.max(0, math.min(math.floor(today), 100000)) or 0
    return lifetime, today
end

-- An inspect answer. Another player's answer (anyone's inspect) spoils ours and holds the
-- next one back for two seconds. Ours: honor data that came just before it is taken (the
-- game's own inspect window reads it from the inspect alone); when the client can ask for
-- the honor data, it is asked as well, and any update that follows must match.
function RP:OnInspectReady(guid)
    local current = pending
    if not current or guid ~= current.guid then
        lastForeignReadyAt = GetTime()
        if current then current.foreign = true end
        return
    end
    current.ready = true
    if type(RequestInspectHonorData) == "function" then pcall(RequestInspectHonorData) end
    if current.early then
        current.value, current.today = current.early, current.earlyToday
        self:SettleInspect(current)
    end
end

-- The honor update carries no unit: it is ours while the unit, when still known, is the
-- player we asked for, no other inspect answer came, and every update agrees.
function RP:OnInspectHonor()
    local current = pending
    if not current or current.foreign then return end
    local guid = current.unit ~= "mouseover" and UnitValue(UnitGUID, current.unit) or nil
    if guid ~= nil and guid ~= current.guid then
        current.foreign = true
        return
    end
    local lifetime, today = HonorData()
    if not lifetime then return end
    local seen = current.value or current.early
    if seen and seen ~= lifetime then
        current.foreign = true
        return
    end
    if not current.ready then
        current.early, current.earlyToday = lifetime, today
        return
    end
    current.value, current.today = lifetime, today
    self:SettleInspect(current)
end

-- Kept after two quiet seconds (a foreign answer meanwhile spoils it).
function RP:SettleInspect(current)
    if not current.ready or not current.value or current.settling then return end
    current.settling = true
    local function finish()
        if pending ~= current then return end
        RP:EndInspect()
        -- Still the same honor data at the end (another addon's inspect would have changed it).
        local again = HonorData()
        if again and again ~= current.value then current.foreign = true end
        if not current.foreign then
            readAt[current.name] = GetTime() + RP.INSPECT_AGAIN
            local pool = RP:Pool()
            if current.diagnose and pool and not RP:IsCandidate(pool, current.name) then
                -- A diagnostic read of a player we follow for nothing: printed, not kept.
            else
                RP:StoreReading(current.name, current.value, current.today, current.guid)
            end
        end
        if current.diagnose then
            RP:Say(string.format("%s: lifetime honorable kills %s, today %s%s", current.name, tostring(current.value),
                tostring(current.today), current.foreign and " (spoiled by another inspect, not kept)" or ""))
        end
    end
    if C_Timer and C_Timer.After then C_Timer.After(self.INSPECT_SETTLE, finish) else finish() end
end

-- A reading kept (one per week, the latest). Another character under the same name
-- (another GUID) starts afresh. A reading lower than a kept one is held apart: a second
-- lower one from another session and another week drops the readings above it (they were
-- not his) and the weeks they proved.
function RP:StoreReading(name, lifetime, today, guid)
    local pool = self:Pool()
    local week = self:CurrentWeek()
    if not pool or not week or InInstance() then return end
    lifetime, today = Count(lifetime), Count(today)
    if lifetime == 0 then return end
    if guid and pool.gd[name] and pool.gd[name] ~= guid then self:ForgetCharacter(pool, name) end
    if guid and type(pool.shown[name]) == "table" then pool.shown[name].wait = nil end
    -- A new name for a character we read before (a rename): what we knew follows him.
    if guid and not pool.gd[name] then
        for old, known in pairs(pool.gd) do
            if known == guid and old ~= name then
                for _, key in ipairs({ "rd", "gf", "vw", "dw", "ow", "lw", "shown" }) do
                    if pool[key][name] == nil then pool[key][name] = pool[key][old] end
                    pool[key][old] = nil
                end
                pool.gd[old] = nil
                if type(pool.shown[name]) == "table" then pool.shown[name].wait = nil end
                Invalidate(old)
                break
            end
        end
        local parked = not pool.gd[name] and pool.park[guid]
        if type(parked) == "table" then
            for _, key in ipairs(PARK_KEYS) do
                if pool[key][name] == nil then pool[key][name] = parked[key] end
            end
            pool.park[guid] = nil
            if type(pool.shown[name]) == "table" then pool.shown[name].wait = nil end
        end
    end
    local readings = Table(pool.rd, name)
    if guid then pool.gd[name] = guid end
    pool.gf[name] = MyFaction()
    local server = ServerNow()
    local highest = 0
    for _, reading in pairs(readings) do
        if type(reading) == "table" then highest = math.max(highest, Count(reading.l)) end
    end
    if lifetime < highest then
        local low = pool.low[name]
        if type(low) == "table" and low.ss ~= session and Count(low.w) ~= week and lifetime >= Count(low.l) then
            for kept, reading in pairs(readings) do
                if type(reading) ~= "table" or Count(reading.l) > lifetime then readings[kept] = nil end
            end
        else
            pool.low[name] = { l = lifetime, ss = session, w = week, at = server }
            return
        end
    end
    pool.low[name] = nil
    readings[week] = { l = lifetime, t = today, a = server }
    local weeks = {}
    for kept in pairs(readings) do weeks[#weeks + 1] = kept end
    table.sort(weeks)
    for index = 1, #weeks - self.READING_WEEKS do readings[weeks[index]] = nil end
    Invalidate(name)
    -- Evaluated at once: what is proven never depends on whether a row was painted, nor on
    -- whether he claims a rank yet.
    local faction = MyFaction()
    if faction and not pool.claims[name] and self:InCloses(pool, name) then pcall(self.Record, self, pool, name, faction) end
    pcall(self.ProvenRank, self, name)
end

function RP:RegisterHonorEvent(on)
    local frame = self.frame
    if not frame then return end
    if on then frame:RegisterEvent("INSPECT_HONOR_UPDATE") else frame:UnregisterEvent("INSPECT_HONOR_UPDATE") end
end

-- Every 30 s: the target, then group mates, then nameplates, for a reading that is due
-- (stopping at the first inspect sent): claimants first, then the other candidates.
function RP:SampleUnits()
    if pending or InInstance() then return end
    if GetTime() - lastInspectAt < self.INSPECT_GAP then return end
    local units = { "target" }
    if IsInGroup and IsInGroup() then
        local prefix, size = "party", 4
        if IsInRaid and IsInRaid() then prefix, size = "raid", 40 end
        for index = 1, size do
            local unit = prefix .. index
            if UnitExists(unit) then units[#units + 1] = unit end
        end
    end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then units[#units + 1] = unit end
        end
    end
    for pass = 1, 2 do
        for _, unit in ipairs(units) do
            if self:TryInspect(unit, false, pass == 1) == nil or pending then return end
        end
    end
end

-- A new player targeted: inspected once he stayed three seconds (a quick click-through, or
-- the player's own inspect, is left alone).
function RP:OnTargetChanged()
    if not UnitIsPlayer("target") then return end
    local guid = UnitValue(UnitGUID, "target")
    if type(guid) ~= "string" or not (C_Timer and C_Timer.After) then return end
    C_Timer.After(self.TARGET_DELAY, function()
        if UnitValue(UnitGUID, "target") == guid then pcall(RP.TryInspect, RP, "target") end
    end)
end

-- ------------------------------------------------------------------ diagnostics

function RP:Say(text)
    if Overlord.PrintNotification then Overlord:PrintNotification("|cFFFFD100[Overlord:proof]|r " .. text) end
end

-- /ov proof: what this client holds, and the target read now (the in-game check that the
-- server answers an inspect with its lifetime honorable kills).
function RP:HandleCommand()
    local pool = self:Pool()
    if not pool then return end
    local claims, shown = 0, 0
    for name in pairs(pool.claims) do
        claims = claims + 1
        if (badge[name] or 0) > 0 or type(pool.shown[name]) == "table" then shown = shown + 1 end
    end
    self:Say(string.format("claims %d, badges known %d, players read %d, weeks closed %d; our rank %d",
        claims, shown, Size(pool.rd), Size(pool.close), self:LocalRank()))
    local name = UnitExists("target") and UnitName("target")
    if not name then
        self:Say("target a player of your faction, out of combat, close by, to read his lifetime honorable kills")
        return
    end
    local claim = pool.claims[name]
    local _, doubtful, readings, _, unverified = self:Evidence(pool, name, MyFaction() or "")
    local badgeRank = self:GetBadgeRank(name)
    -- Weeks proven at each top (1/3/10/25/100), kept for life.
    local tops = {}
    for index, top in ipairs(self.TOPS) do
        local count = 0
        for _, weekTop in pairs(pool.vw[name] or {}) do
            if weekTop <= top then count = count + 1 end
        end
        tops[index] = count
    end
    local newest = readings[#readings]
    self:Say(string.format("%s: claim %s, readings %d (last %s), weeks proven top 1/3/10/25/100 %s, "
        .. "unverified %d, doubtful %d, badge %d", name, claim and tostring(claim.r) or "none", #readings,
        newest and tostring(newest.l) or "-", table.concat(tops, "/"), Size(unverified), Size(doubtful), badgeRank))
    local why = self:TryInspect("target", true)
    if why then self:Say(name .. ": no inspect now (" .. why .. ")") end
end

-- ------------------------------------------------------------------ nameplates

RP.BADGE_SIZE = 14
RP.badges = RP.badges or {}

function RP:HidePlate(unit)
    local frame = unit and self.badges[unit]
    if frame then frame:Hide() end
end

function RP:HideAllPlates()
    for _, frame in pairs(self.badges) do frame:Hide() end
end

-- Left of the name's text. Blizzard's name field often spans the whole bar with the text
-- centred, so the badge goes where the text starts; without a readable name, left of the
-- health bar (where the Nemesis skull sits on enemies).
local function PlaceBadge(frame, parent)
    frame:ClearAllPoints()
    local name = parent.name
    if name and name.GetStringWidth and name.IsShown and name:IsShown() then
        local okText, text = pcall(name.GetStringWidth, name)
        local okField, field = pcall(name.GetWidth, name)
        local okJustify, justify = pcall(name.GetJustifyH, name)
        if okText and okField and type(text) == "number" and type(field) == "number"
            and Accessible(text) and Accessible(field) and text > 0 then
            local inset = 0
            if field > text and okJustify then
                if justify == "CENTER" then inset = (field - text) / 2
                elseif justify == "RIGHT" then inset = field - text end
            end
            frame:SetPoint("RIGHT", name, "LEFT", inset - 2, 0)
            return
        end
    end
    -- (Left of the Nemesis skull when it is there.)
    local mw = Overlord.MostWanted
    local skull = mw and mw.skulls and frame.unit and mw.skulls[frame.unit]
    local beside = skull and skull.IsShown and skull:IsShown() and (mw.SKULL_SIZE or 16) + 2 or 0
    frame:SetPoint("RIGHT", parent.healthBar or parent, "LEFT", -3 - beside, 0)
end

function RP:ShowPlate(unit, rank)
    local icon = Overlord.Ranks and Overlord.Ranks.GetRankIcon and Overlord.Ranks:GetRankIcon(rank)
    local plate = icon and C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    local parent = plate and (plate.UnitFrame or plate)
    if not parent or not CreateFrame then return end
    local frame = self.badges[unit]
    if not frame then
        frame = CreateFrame("Frame", nil, parent)
        frame:SetSize(self.BADGE_SIZE, self.BADGE_SIZE)
        frame.icon = frame:CreateTexture(nil, "OVERLAY")
        frame.icon:SetAllPoints()
        self.badges[unit] = frame
    end
    if frame:GetParent() ~= parent then frame:SetParent(parent) end
    frame.unit = unit
    PlaceBadge(frame, parent)
    frame.icon:SetTexture(icon)
    frame:Show()
    -- The game may write the name after us: placed again once it did.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.2, function()
            if frame:IsShown() and frame:GetParent() == parent then pcall(PlaceBadge, frame, parent) end
        end)
    end
end

-- The badge for a friendly player's unit (0 = none): never for another character than the
-- one we read under that name.
function RP:UnitBadge(pool, unit)
    if not UnitIsPlayer(unit) then return 0, nil end
    local side, mine = UnitValue(UnitFactionGroup, unit), MyFaction()
    if side ~= mine then
        if mine and (side == "Alliance" or side == "Horde") then
            local name = UnitName(unit)
            return name and self:GetBadgeRank(name, side) or 0, name
        end
        return 0, nil
    end
    local name = UnitName(unit)
    if not name or not pool.claims[name] then return 0, name end
    if not self:SameCharacter(pool, name, unit) then return 0, name end
    return self:GetBadgeRank(name, mine), name
end

-- A friendly player's nameplate: its badge, and an inspect if its reading is due.
function RP:OnPlate(unit)
    self:HidePlate(unit)
    -- (Creatures first: most plates, and the cheapest test.)
    if not unit or not UnitIsPlayer(unit) or InInstance() then return end
    local pool = self:Pool()
    if not pool then return end
    local rank = self:UnitBadge(pool, unit)
    if rank >= self.MIN_RANK then self:ShowPlate(unit, rank) end
    self:TryInspect(unit, false, true)
end

-- Something changed: badges are repainted (at most once a second). With a name, only that
-- player's plate: a presence heard re-checks its sender's badge, and on a busy channel
-- (one every second or so) repainting every plate each time cost a badge check per
-- player in sight every second. Without a name, every plate.
function RP:RefreshPlates(name)
    if name == nil then
        self._platesDirty = true
    elseif self._platesDirty ~= true then
        self._platesDirty = self._platesDirty or {}
        self._platesDirty[name] = true
    end
    if self._platesQueued or not (C_Timer and C_Timer.After) then return end
    self._platesQueued = true
    C_Timer.After(1, function()
        RP._platesQueued = nil
        local dirty = RP._platesDirty
        RP._platesDirty = nil
        pcall(RP.RepaintPlates, RP, dirty)
    end)
end

-- dirty: a set of names (only their plates), or nil / true for every plate.
function RP:RepaintPlates(dirty)
    local every = type(dirty) ~= "table"
    if every or InInstance() then self:HideAllPlates() end
    if InInstance() or not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local pool = self:Pool()
    if not pool then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local name = unit and not every and UnitName(unit)
        if unit and (every or (name and (dirty[name] or dirty[Canon(name) or ""]))) then
            local rank = self:UnitBadge(pool, unit)
            if rank >= self.MIN_RANK then self:ShowPlate(unit, rank) else self:HidePlate(unit) end
        end
    end
end

-- ------------------------------------------------------------------ events

RP.EVENTS = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT", "INSPECT_READY" }

function RP:RegisterLiveEvents(on)
    local frame = self.frame
    if not frame then return end
    for _, event in ipairs(self.EVENTS) do
        if on then pcall(frame.RegisterEvent, frame, event)
        else pcall(frame.UnregisterEvent, frame, event) end
    end
end

function RP:OnInstanceSuspend()
    self:RegisterLiveEvents(false)
    self:EndInspect()
    self:HideAllPlates()
end

function RP:OnInstanceResume()
    self:RegisterLiveEvents(true)
    self:RefreshPlates()
end

function RP:OnEvent(event, ...)
    if event == "NAME_PLATE_UNIT_REMOVED" then
        self:HidePlate((...))
        return
    end
    if event == "UPDATE_MOUSEOVER_UNIT" then
        -- Frequent: the cheapest gates first (sweeping frames fires it many times a second).
        local now = GetTime()
        if pending or now - lastInspectAt < self.INSPECT_GAP or now - lastMouseoverAt < 0.3 then return end
        lastMouseoverAt = now
        local pool = self:Pool()
        if not pool or not next(pool.claims) or InInstance() then return end
        pcall(self.TryInspect, self, "mouseover", false, true)
        return
    end
    if InInstance() then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        pcall(self.OnPlate, self, (...))
    elseif event == "PLAYER_TARGET_CHANGED" then
        pcall(self.OnTargetChanged, self)
    elseif event == "INSPECT_READY" then
        pcall(self.OnInspectReady, self, (...))
    elseif event == "INSPECT_HONOR_UPDATE" then
        pcall(self.OnInspectHonor, self)
    end
end

function RP:Initialize()
    if self.initialized or not CreateFrame then return end
    self.initialized = true
    local frame = CreateFrame("Frame")
    self.frame = frame
    if not InInstance() then self:RegisterLiveEvents(true) end
    frame:SetScript("OnEvent", function(_, event, ...) RP:OnEvent(event, ...) end)
    pcall(self.CheckEra, self, self:Pool())
    pcall(self.NoteOnline, self)
    if C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(30, function()
            pcall(RP.NoteOnline, RP)
            pcall(RP.SampleUnits, RP)
        end)
    end
end

if CreateFrame then
    local boot = CreateFrame("Frame")
    boot:RegisterEvent("PLAYER_LOGIN")
    boot:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        RP:Initialize()
    end)
end
