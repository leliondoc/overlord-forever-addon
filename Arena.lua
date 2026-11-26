-- Gurubashi Arena (Stranglethorn Vale), Waldo's idea: one capture point of its own, on every
-- realm type, outside the keep and outpost engine. The pit is free-for-all: any guild takes it
-- from any other guild, its own faction included. A guild member holds the pit for 5 minutes
-- while no player of another guild stands in it alive; it then belongs to that guild until
-- another one takes it or the weekly reset. Shown on its own board (ranking, keeps header);
-- not part of the guild rating.
--
-- Network (only through the relay, every kind new: clients before this one neither read nor
-- pass them on, "update required"). Last of all there: admitted on a quiet queue only, sent once
-- nothing else waits, the first packet a full queue gives up (SyncRelay.lua, isArena); kills,
-- captures and pages never wait for the arena. What the relay refuses comes back by catch-up.
--   AC  1:<pool>:<ts>:<A|H>:<capturer>:<guild>     one broadcast per capture, by its capturer
--   AQ  1:<pool>:<week>:<count>:<sum>:<page>        one ask to one direct neighbour (catch-up);
--                                                   page 2 and on follow the page just answered
--   AL  1:<pool>:<week>:<page>:<pages>:<count>:<sum>:<rows>   its answer, with the answerer's
--                                                   digest; rows "ts,A,capturer,guild" joined by "="
-- Trust, as for keep claims: a capture is believed on its author's word only first-hand (heard
-- from the capturer himself); relayed or caught up, it is judged by content (the guild our
-- ranking knows for the capturer, or our own roster). Otherwise it waits, kept apart, and is
-- judged again whenever the board is read (another guild than the ranking's waits too: a guild
-- change the ranking learns later; only a capturer of the other side is refused outright).
-- The ledger is a plain set of rows keyed by (date, capturer, guild); holder, counts and spacing are folded from it at read time, so every
-- client holding the same rows shows the same board whatever order they came in.
Overlord = Overlord or {}
local AR = Overlord.Arena or {}
Overlord.Arena = AR

AR.HOLD_SEC = 300
AR.FRESH_SEC = 60
AR.LIVE_SEC = 180
-- Two captures closer than this cannot both be real (5 minutes of hold each).
AR.SPACING_SEC = 240
-- Stranglethorn Vale: Classic (1434), the matching Retail ids (224, then 50/210 after the split).
AR.MAP_IDS = { [1434] = true, [224] = true, [50] = true, [210] = true }
AR.ROWS_MAX = 300
AR.PAGE_ROWS = 25
-- (The whole ledger fits in one catch-up: ROWS_MAX / PAGE_ROWS pages.)
AR.PAGES_MAX = 12
AR.RECENT_MAX = 40
AR.CATCHUP_DELAY = 90
AR.CATCHUP_EVERY = 600
AR.ASK_TIMEOUT = 20
AR.ASK_TRIES = 3
AR.ANSWER_PER_ASKER_SEC = 20
-- Pages answered a minute, in all (one full catch-up at most).
AR.ANSWERS_PER_MIN = 12
AR.LEAVE_GRACE = 3
AR.FOLD_TTL = 30
-- Chat lines (taken for us, taken from us): one of each kind every 30 minutes at most, kept
-- across /reload. A pit that changes hands every 5 minutes prints twice an hour, not twelve times.
AR.CHAT_GAP_SEC = 1800

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function ServerNow()
    return math.floor((GetServerTime and GetServerTime()) or (time and time()) or 0)
end

local function Pool()
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool() or ""
    return type(pool) == "string" and pool or ""
end

local function WeekStart()
    local lb = Overlord.Leaderboard
    return math.floor(tonumber(lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart()) or 0)
end

local function SameWeek(a, b)
    a, b = math.floor(tonumber(a) or 0), math.floor(tonumber(b) or 0)
    return a == b or (a > 0 and b > 0 and Overlord.CampaignEpochsMatch and Overlord:CampaignEpochsMatch(a, b)) or false
end

-- Strict: the ranking's 36 h tolerance (clients whose week start differs) would put last
-- Sunday's captures on the new week's board. A capture counts from the reset on.
local function InWeek(ts)
    local start = WeekStart()
    return start > 0 and ts >= start
end

-- The ranking's cleaning (length, spaces), and never our own separators whatever it does.
local function Sanitize(guild)
    local op = Overlord.Outpost
    if type(guild) ~= "string" or guild:find("[|=:,;%c]") or not (op and op.SanitizeGuildName) then return "" end
    return op:SanitizeGuildName(guild) or ""
end

local function Canonical(name)
    local sync = Overlord.Sync
    return type(name) == "string" and sync and sync.CanonicalForeverName and sync:CanonicalForeverName(name) or nil
end

local function FactionOf(code)
    if code == "A" then return "Alliance" end
    if code == "H" then return "Horde" end
    return nil
end

local function CodeOf(faction)
    return faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
end

local function OwnGuild()
    local op = Overlord.Outpost
    return op and op.GetLocalPlayerGuild and op:GetLocalPlayerGuild() or ""
end

-- ---------------------------------------------------------------- ledger

function AR:Store()
    if not OverlordDB then return nil end
    OverlordDB.arena = type(OverlordDB.arena) == "table" and OverlordDB.arena or {}
    local pool, week = Pool(), WeekStart()
    local s = OverlordDB.arena[pool]
    if type(s) ~= "table" or type(s.rows) ~= "table" or not SameWeek(s.week, week) then
        -- A new week (or another realm type's first visit): the board starts empty.
        s = { week = week, rows = {}, n = 0 }
        OverlordDB.arena[pool] = s
        self:Changed()
    end
    return s, pool, week
end

function AR:Changed()
    self.version = (self.version or 0) + 1
    self._fold = nil
    -- (A catch-up page adds up to 25 rows: the board is folded and painted once, after it.)
    if self._batch then
        self._batch.changed = true
        return
    end
    local ui = Overlord.LeaderboardUI
    if ui and ui.RefreshArena then pcall(ui.RefreshArena, ui) end
end

-- The guild our ranking knows for this capturer, and his faction ("" / nil when unknown).
local function LadderOf(capturer)
    local lb = Overlord.Leaderboard
    local guild = lb and lb.GetHotPlayerGuildState and lb:GetHotPlayerGuildState(capturer) or ""
    local info = lb and type(lb.playerInfo) == "table" and lb.playerInfo[capturer] or nil
    local faction = info and info.faction
    if faction ~= "Alliance" and faction ~= "Horde" then faction = nil end
    return Sanitize(guild or ""), faction
end

-- Judged by content: "yes" (the ranking or our roster says so), "no" (the ranking names
-- another guild), "side" (the ranking knows him on the other side), "wait" (nobody knows the
-- capturer's guild yet).
function AR:JudgeContent(row)
    local guild, faction = LadderOf(row.capturer)
    if faction and faction ~= row.faction then return "side" end
    if guild ~= "" then return guild:lower() == row.guild:lower() and "yes" or "no" end
    local lb = Overlord.Leaderboard
    if row.faction == Overlord.PlayerFaction and OwnGuild():lower() == row.guild:lower()
        and lb and lb.IsLocalGuildRosterMember and lb:IsLocalGuildRosterMember(row.capturer) then
        return "yes"
    end
    return "wait"
end

-- Rows refused (by cause) and believed rows evicted from a full ledger, this session: shown in
-- the network health panel (AR:GetStats), nothing dropped unseen.
AR.stats = { refused = {}, evicted = 0, evictedWaiting = 0 }
function AR:Refused(why)
    self.stats.refused[why] = (self.stats.refused[why] or 0) + 1
    return false, why
end

function AR:GetStats()
    local s = self:Store()
    local kept, waiting = 0, 0
    for _, row in pairs(s and s.rows or {}) do
        kept = kept + 1
        if not row.trusted then waiting = waiting + 1 end
    end
    return kept, waiting, self.stats.refused, self.stats.evicted, self.stats.evictedWaiting
end

-- how: "own" (our capture), "author" (heard from the capturer himself), "content" (relayed or
-- caught up). Returns true when the row is new or newly believed.
function AR:AddRow(ts, faction, capturer, guild, how)
    ts = math.floor(tonumber(ts) or 0)
    if ts <= 0 or ts > ServerNow() + 60 or not InWeek(ts) then return self:Refused("date") end
    if faction ~= "Alliance" and faction ~= "Horde" then return self:Refused("faction") end
    local canon = Canonical(capturer)
    if not canon or canon ~= capturer then return self:Refused("name") end
    local clean = Sanitize(guild)
    if clean == "" or clean ~= guild then return self:Refused("guild") end
    local s = self:Store()
    if not s then return self:Refused("store") end
    -- (Keyed with the guild too: a relayed copy naming another guild waits beside the real row,
    -- never in its place. Two believed rows of one capture fold as one: the spacing.)
    local key = ts .. "|" .. canon:lower() .. "|" .. clean:lower()
    local old = s.rows[key]
    -- (The mesh brings the same capture several times: a believed row is not judged again.)
    if old and old.trusted then return false, "known" end
    local row = { ts = ts, faction = faction, capturer = canon, guild = clean }
    -- strong: our own capture or one the ranking confirms. Only such a row may push a believed
    -- row out of a full ledger (an author's word with an unknown guild may not: a sender naming
    -- a new guild each time would flush the week's history on his neighbours).
    local trusted, strong
    if how == "own" then
        trusted, strong = true, true
    else
        local verdict = self:JudgeContent(row)
        if verdict == "side" then return self:Refused("content") end
        -- First-hand, the author's own word stands while nobody knows his guild (as a K row).
        -- Another guild than the ranking's waits, judged again on every read.
        trusted = verdict == "yes" or (how == "author" and verdict == "wait")
        strong = verdict == "yes"
        -- (An author's word alone, his guild unknown: believed once per spacing and for one guild
        -- a week. A modified client naming a new guild at each capture fills no ledger; the other
        -- rows wait for the ranking, as relayed ones.)
        if trusted and not strong then
            for _, r in pairs(s.rows) do
                if r.authorOnly and r.trusted and r.capturer == canon
                    and (r.guild ~= clean or math.abs(r.ts - ts) < self.SPACING_SEC) then
                    trusted = false
                    break
                end
            end
        end
    end
    if old then
        if not trusted then return false, "known" end
        old.faction, old.trusted = faction, true
        self:Changed()
        return true
    end
    if (s.n or 0) >= self.ROWS_MAX and not self:Evict(s, ts, strong) then return self:Refused("full") end
    row.trusted = trusted or nil
    row.authorOnly = (trusted and not strong) or nil
    s.rows[key] = row
    s.n = (s.n or 0) + 1
    self:Changed()
    return true
end

-- Full ledger: a waiting row goes first (oldest), then the oldest capture. A believed row only
-- leaves for a strong row dated after it (false: the incoming row is not kept). Both counted.
function AR:Evict(s, ts, strong)
    local victim, victimRow
    for key, row in pairs(s.rows) do
        if not victimRow or (not row.trusted and victimRow.trusted)
            or ((not row.trusted) == (not victimRow.trusted) and row.ts < victimRow.ts) then
            victim, victimRow = key, row
        end
    end
    if not victim then return false end
    if victimRow.trusted and not (strong and (ts or 0) > victimRow.ts) then return false end
    if victimRow.trusted then
        self.stats.evicted = self.stats.evicted + 1
    else
        self.stats.evictedWaiting = self.stats.evictedWaiting + 1
    end
    s.rows[victim] = nil
    s.n = math.max(0, (s.n or 1) - 1)
    return true
end

local function RowBefore(a, b)
    if a.ts ~= b.ts then return a.ts < b.ts end
    if a.capturer ~= b.capturer then return a.capturer < b.capturer end
    return a.guild < b.guild
end

-- Holder, counts per guild and the latest captures, from the rows believed (waiting rows are
-- judged again first). Same rows, same board, whatever order they came in.
function AR:Fold()
    local now = GetTime and GetTime() or 0
    local f = self._fold
    if f and f.version == self.version and now - f.at < self.FOLD_TTL then return f end
    local s = self:Store()
    local list = {}
    local promoted = false
    for _, row in pairs(s and s.rows or {}) do
        if not row.trusted and self:JudgeContent(row) == "yes" then
            row.trusted = true
            promoted = true
        end
        if row.trusted then list[#list + 1] = row end
    end
    table.sort(list, RowBefore)
    local holder, lastTs = nil, nil
    local byGuild, guilds, taken = {}, {}, {}
    for _, row in ipairs(list) do
        local key = row.guild:lower()
        if not (lastTs and row.ts - lastTs < self.SPACING_SEC)
            and not (holder and holder.guild:lower() == key) then
            taken[#taken + 1] = { ts = row.ts, guild = row.guild, faction = row.faction, capturer = row.capturer,
                previous = holder and holder.guild or nil, previousFaction = holder and holder.faction or nil }
            holder, lastTs = row, row.ts
            local g = byGuild[key]
            if not g then
                g = { guild = row.guild, faction = row.faction, captures = 0, lastTs = 0 }
                byGuild[key] = g
                guilds[#guilds + 1] = g
            end
            g.captures = g.captures + 1
            g.lastTs = row.ts
        end
    end
    table.sort(guilds, function(a, b)
        if a.captures ~= b.captures then return a.captures > b.captures end
        if a.lastTs ~= b.lastTs then return a.lastTs > b.lastTs end
        return a.guild < b.guild
    end)
    local recent = {}
    for i = #taken, math.max(1, #taken - self.RECENT_MAX + 1), -1 do recent[#recent + 1] = taken[i] end
    if promoted then self.version = (self.version or 0) + 1 end
    f = { version = self.version, at = now, holder = holder, guilds = guilds, recent = recent,
        count = #taken, believed = list }
    self._fold = f
    return f
end

function AR:GetBoard()
    return self:Fold()
end

-- Count and checksum of the rows believed: two clients holding the same rows stay silent.
function AR:Digest()
    local f = self:Fold()
    local sum = 0
    for _, row in ipairs(f.believed) do
        local h = row.ts % 1000003
        for i = 1, #row.capturer do h = (h * 31 + row.capturer:byte(i)) % 2147483629 end
        for i = 1, #row.guild do h = (h * 31 + row.guild:byte(i)) % 2147483629 end
        sum = (sum + h) % 2147483629
    end
    return #f.believed, sum
end

-- ---------------------------------------------------------------- network

local function Net()
    local net = Overlord.Relay
    if net and net.IsEnabled and not net:IsEnabled() then return nil end
    return net
end

function AR:Broadcast(row)
    local net = Net()
    if not net or not net.Broadcast then return false end
    local payload = string.format("1:%s:%d:%s:%s:%s", Pool(), row.ts, CodeOf(row.faction), row.capturer, row.guild)
    return (net:Broadcast("AC", payload) or 0) > 0
end

local function RelayHops()
    local net = Overlord.Relay
    local ctx = net and net.context
    return ctx and tonumber(ctx.hops) or nil
end

function AR:OnReceive(kind, payload, sender, channel)
    if Overlord.InstanceSuspended or channel ~= "BETA" or type(payload) ~= "string" then return end
    if kind == "AC" then return self:OnCapture(payload, sender) end
    -- (Catch-up is between direct neighbours only: a relayed ask or page names an origin nobody
    -- checked.)
    if (kind == "AQ" or kind == "AL") and RelayHops() ~= 0 then return self:Refused("hops") end
    if kind == "AQ" then return self:OnAsk(payload, sender) end
    if kind == "AL" then return self:OnAnswer(payload, sender) end
end

function AR:OnCapture(payload, sender)
    local version, pool, ts, code, capturer, guild = strsplit(":", payload, 6)
    if version ~= "1" or pool ~= Pool() then return end
    local faction = FactionOf(code)
    if not faction or type(capturer) ~= "string" then return end
    local before = self:Fold().holder
    -- First-hand word only for a capture dated now: an older date is catch-up content, judged
    -- like any relayed row (a back-dated row must not push a real capture out of the fold).
    local tsNum = tonumber(ts)
    if not tsNum or math.abs(tsNum - ServerNow()) > self.LIVE_SEC then
        self:Refused("stale")
        return
    end
    local firstHand = RelayHops() == 0 and Canonical(sender) == capturer
        and tsNum ~= nil and math.abs(tsNum - ServerNow()) <= self.FRESH_SEC
    local added = self:AddRow(ts, faction, capturer, guild or "", firstHand and "author" or "content")
    if added then self:TellGuild(before, self:Fold().holder) end
end

-- One chat line, only for the guilds concerned (the taker, the one that lost it): an arena that
-- changes hands every 5 minutes is not news for everybody. Each kind at most every CHAT_GAP_SEC.
function AR:TellGuild(before, after)
    if not after or after == before then return end
    local own = OwnGuild():lower()
    if own == "" then return end
    local tookIt = after.guild:lower() == own
    local lostIt = before and before.guild:lower() == own and not tookIt
    if not tookIt and not lostIt then return end
    if not OverlordDB then return end
    local said = type(OverlordDB.arenaChatAt) == "table" and OverlordDB.arenaChatAt or {}
    OverlordDB.arenaChatAt = said
    local kind, now = tookIt and "took" or "lost", ServerNow()
    local last = tonumber(said[kind]) or 0
    -- (A date ahead of the clock, a changed clock: never a line held back for ever.)
    if last <= now and now - last < self.CHAT_GAP_SEC then return end
    said[kind] = now
    local who = after.capturer:match("^(%S+)") or after.capturer
    local text = tookIt and string.format(T("ARENA_TAKEN_BY_US", "%s took the Gurubashi Arena for your guild."), who)
        or string.format(T("ARENA_TAKEN_FROM_US", "%s (%s) took the Gurubashi Arena from your guild."), after.guild, who)
    if Overlord.PrintNotification then Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text) end
end

-- Catch-up: one direct neighbour asked at a time, a few tries, each answer checked against the ask.
function AR:CatchUp(force)
    if Overlord.InstanceSuspended or self.ask then return false end
    local now = GetTime and GetTime() or 0
    if not force and self.caughtUpAt and now - self.caughtUpAt < self.CATCHUP_EVERY then return false end
    local net = Net()
    if not net or not net.GetDirectPeers or not net.Send then return false end
    self.tried = (self.tried and not force) and self.tried or {}
    local peers, pick = net:GetDirectPeers(), nil
    local candidates = {}
    for _, name in ipairs(peers) do if not self.tried[name] then candidates[#candidates + 1] = name end end
    if #candidates == 0 then
        -- Every neighbour tried, none answered: this round ends; the next one comes with the next
        -- login, instance exit or board open, CATCHUP_EVERY apart.
        if next(self.tried) then self:EndRound() end
        return false
    end
    pick = candidates[math.random(1, #candidates)]
    self.tried[pick] = true
    if self:Ask(pick, 1) then
        self.askFails = 0
        return true
    end
    -- (Refused here: the relay sends the arena last, after everything else. The neighbour is
    -- not spent; tried again 30 s later, ASK_TRIES times, then the round ends.)
    self.tried[pick] = nil
    self.askFails = (self.askFails or 0) + 1
    if self.askFails >= self.ASK_TRIES then
        self.askFails = 0
        self:EndRound()
    elseif C_Timer and C_Timer.After then
        C_Timer.After(30, function() AR:CatchUp(false) end)
    end
    return false
end

function AR:EndRound()
    self.caughtUpAt = GetTime and GetTime() or 0
    self.tried = nil
end

function AR:Ask(peer, page)
    local net = Net()
    if not net then return false end
    local count, sum = self:Digest()
    local s, pool, week = self:Store()
    if not s then return false end
    local payload = string.format("1:%s:%d:%d:%d:%d", pool, week, count, sum, page)
    if not net:Send("AQ", payload, peer) then return false end
    local ask = { peer = peer, page = page, at = GetTime and GetTime() or 0 }
    self.ask = ask
    if C_Timer and C_Timer.After then
        C_Timer.After(self.ASK_TIMEOUT, function()
            if self.ask ~= ask then return end
            self.ask = nil
            -- Silent (an older client, gone): the next neighbour, a few times per round.
            local tries = 0
            for _ in pairs(self.tried or {}) do tries = tries + 1 end
            if page == 1 and tries < self.ASK_TRIES then
                self:CatchUp(false)
            else
                -- (A later page unanswered, or the tries spent: the rows taken so far stay.)
                self:EndRound()
            end
        end)
    end
    return true
end

function AR:OnAsk(payload, sender)
    local version, pool, week, count, sum, page = strsplit(":", payload, 6)
    if version ~= "1" or pool ~= Pool() then return end
    local asker = Canonical(sender)
    if not asker or not SameWeek(week, WeekStart()) then return end
    page = math.floor(tonumber(page) or 0)
    if page < 1 or page > self.PAGES_MAX then return self:Refused("ask-page") end
    -- Bounded answers: one catch-up per asker every 20 s (its next pages follow the page just
    -- answered), twelve pages a minute in all.
    local now = GetTime and GetTime() or 0
    self.answered, self.answeredPage = self.answered or {}, self.answeredPage or {}
    local last = self.answered[asker]
    -- (The next page follows the answer through two relay queues, ours and the asker's.)
    local follows = page > 1 and last and self.answeredPage[asker] == page - 1 and now - last < 2 * self.ASK_TIMEOUT
    if page > 1 and not follows then return self:Refused("ask-turn") end
    if not follows and last and now - last < self.ANSWER_PER_ASKER_SEC then return self:Refused("ask-asker") end
    local budget = self.answerBudget
    if not budget or now - budget.at >= 60 then budget = { at = now, n = 0 }; self.answerBudget = budget end
    if budget.n >= self.ANSWERS_PER_MIN then return self:Refused("ask-budget") end
    local n, digest = self:Digest()
    local rows = {}
    local pages = 0
    if not (tonumber(count) == n and tonumber(sum) == digest) then
        local believed = self:Fold().believed
        pages = math.min(self.PAGES_MAX, math.ceil(#believed / self.PAGE_ROWS))
        -- Newest first: a client that missed the last captures has them on the first page.
        local first = #believed - (page - 1) * self.PAGE_ROWS
        for i = first, math.max(1, first - self.PAGE_ROWS + 1), -1 do
            local row = believed[i]
            rows[#rows + 1] = string.format("%d,%s,%s,%s", row.ts, CodeOf(row.faction), row.capturer, row.guild)
        end
    end
    local net = Net()
    if not net then return end
    -- Equal ledgers: an empty answer, so the asker stops instead of trying someone else.
    local reply = string.format("1:%s:%d:%d:%d:%d:%d:%s", Pool(), WeekStart(), page, pages, n, digest,
        table.concat(rows, "="))
    if net:Send("AL", reply, sender) then
        if not self.answered[asker] then
            self.answeredN = (self.answeredN or 0) + 1
            if self.answeredN > 64 then
                local keep, keepPage, n = {}, {}, 0
                for who, at in pairs(self.answered) do
                    if now - at < math.max(self.ANSWER_PER_ASKER_SEC, 2 * self.ASK_TIMEOUT) then
                        keep[who], keepPage[who], n = at, self.answeredPage[who], n + 1
                    end
                end
                self.answered, self.answeredPage, self.answeredN = keep, keepPage, n + 1
            end
        end
        self.answered[asker], self.answeredPage[asker] = now, page
        budget.n = budget.n + 1
    end
end

function AR:OnAnswer(payload, sender)
    local ask = self.ask
    if not ask or Canonical(sender) ~= ask.peer then return end
    local version, pool, week, page, pages, count, sum, rows = strsplit(":", payload, 8)
    if version ~= "1" or pool ~= Pool() or not SameWeek(week, WeekStart()) then return end
    page, pages = math.floor(tonumber(page) or 0), math.floor(tonumber(pages) or 0)
    if page ~= ask.page then return end
    self.ask = nil
    local batch = {}
    self._batch = batch
    local added = 0
    local ok, err = pcall(function()
        local taken = 0
        for entry in tostring(rows or ""):gmatch("[^=]+") do
            taken = taken + 1
            if taken > self.PAGE_ROWS then break end
            local ts, code, capturer, guild = strsplit(",", entry, 4)
            local faction = FactionOf(code)
            if faction and self:AddRow(ts, faction, capturer, guild or "", "content") then added = added + 1 end
        end
    end)
    self._batch = nil
    if batch.changed then self:Changed() end
    if not ok then error(err, 0) end
    -- The next page while ours still differs from the answerer's ledger: a missing older row
    -- sits behind pages we know. A ledger walked to its end that still differs (a row believed
    -- on one side only) is not walked again: its known first page then ends the round.
    local theirs = tostring(tonumber(count) or 0) .. ":" .. tostring(tonumber(sum) or 0)
    local myN, mySum = self:Digest()
    local differs = theirs ~= (myN .. ":" .. mySum)
    if pages > page and page < self.PAGES_MAX and differs and (added > 0 or self.walked ~= theirs) then
        if not self:Ask(ask.peer, page + 1) then self:EndRound() end
    else
        if differs and pages <= page then self.walked = theirs end
        self:EndRound()
    end
end

-- ---------------------------------------------------------------- the pit

local unitTokens = {}
for i = 1, 40 do unitTokens[#unitTokens + 1] = "nameplate" .. i end
for i = 1, 40 do unitTokens[#unitTokens + 1] = "raid" .. i end
for i = 1, 4 do unitTokens[#unitTokens + 1] = "party" .. i end

function AR:OnArenaMap()
    if not (C_Map and C_Map.GetBestMapForUnit) then return false end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    return ok and self.MAP_IDS[mapID] == true or false
end

-- In the pit: on the Stranglethorn map and flagged free-for-all by the game (only the arena's
-- pit is, there). Alive.
function AR:PlayerInPit()
    if not (UnitIsPVPFreeForAll and UnitIsPVPFreeForAll("player")) then return false end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    return true
end

-- Anybody alive in the pit who is not of our guild (any faction, or no guild) stops the clock.
local contestSeen = {}
function AR:Contested(ownKey)
    local seen = contestSeen
    for k in pairs(seen) do seen[k] = nil end
    for _, unit in ipairs(unitTokens) do
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player")
            and not UnitIsDeadOrGhost(unit) and UnitIsPVPFreeForAll(unit) then
            local guid = UnitGUID and UnitGUID(unit) or unit
            if not seen[guid] then
                seen[guid] = true
                local guild = GetGuildInfo(unit)
                if type(guild) ~= "string" or Sanitize(guild):lower() ~= ownKey then return true end
            end
        end
    end
    return false
end

local function Notice(text)
    if not text then return end
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
    elseif Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    end
end

local function Minutes(sec)
    sec = math.max(0, math.ceil(sec))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function AR:ResetHold()
    self.hold = { elapsed = 0, lastMinute = nil, contested = false, said = {} }
end

function AR:Tick()
    local now = GetTime and GetTime() or 0
    local dt = math.min(2, math.max(0, now - (self.lastTick or now)))
    self.lastTick = now
    if Overlord.InstanceSuspended or not self:OnArenaMap() then return self:StopTicker() end
    local hold = self.hold or self:ResetHold() or self.hold
    if not self:PlayerInPit() then
        hold.outSince = hold.outSince or now
        if now - hold.outSince > self.LEAVE_GRACE and (hold.elapsed > 0 or next(hold.said)) then self:ResetHold() end
        return
    end
    hold.outSince = nil
    local guild = OwnGuild()
    if guild == "" or not Overlord.PlayerFaction then
        if not hold.said.noGuild then
            hold.said.noGuild = true
            Notice(T("ARENA_NEED_GUILD", "Gurubashi Arena: join a guild to take it."))
        end
        return
    end
    local holder = self:Fold().holder
    if holder and holder.guild:lower() == guild:lower() then
        if not hold.said.held then
            hold.said.held = true
            Notice(T("ARENA_ALREADY_OURS", "Your guild holds the Gurubashi Arena."))
        end
        hold.elapsed = 0
        return
    end
    if self:Contested(guild:lower()) then
        if not hold.contested then
            hold.contested = true
            Notice(T("ARENA_CONTESTED", "Gurubashi Arena: a player outside your guild is in the pit, the capture is paused."))
        end
        return
    end
    hold.contested = false
    if hold.elapsed == 0 then
        Notice(string.format(T("ARENA_HOLD_START", "Gurubashi Arena: hold the pit for %s to take it."), Minutes(self.HOLD_SEC)))
    end
    hold.elapsed = hold.elapsed + dt
    local left = self.HOLD_SEC - hold.elapsed
    if left <= 0 then return self:Complete(guild) end
    local minute = math.ceil(left / 60)
    if hold.lastMinute and minute < hold.lastMinute then
        Notice(string.format(T("ARENA_HOLD_LEFT", "Gurubashi Arena: %s left."), Minutes(left)))
    end
    hold.lastMinute = minute
end

function AR:Complete(guild)
    self:ResetHold()
    local sync = Overlord.Sync
    local capturer = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    local before = self:Fold().holder
    local row = { ts = ServerNow(), faction = Overlord.PlayerFaction, capturer = capturer, guild = Sanitize(guild) }
    if not self:AddRow(row.ts, row.faction, row.capturer, row.guild, "own") then return false end
    if not self:Broadcast(row) and C_Timer and C_Timer.After then
        -- (Within FRESH_SEC: the retry is still the capturer's own word.)
        C_Timer.After(30, function()
            if not Overlord.InstanceSuspended then AR:Broadcast(row) end
        end)
    end
    -- (Two guilds out of sight of each other can both finish: the fold keeps the first, and the
    -- second hears nothing it did not win.)
    local after = self:Fold().holder
    if after and after.guild:lower() == row.guild:lower() then
        Notice(T("ARENA_TAKEN", "Gurubashi Arena taken for your guild!"))
    end
    self:TellGuild(before, after)
    return true
end

function AR:StartTicker()
    if self.ticker or not (C_Timer and C_Timer.NewTicker) then return end
    self:ResetHold()
    self.lastTick = GetTime and GetTime() or 0
    self.ticker = C_Timer.NewTicker(1, function() AR:Tick() end)
end

function AR:StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
    self.hold = nil
end

-- Zone changes only: a 1 s clock runs while we are on the Stranglethorn map, nothing elsewhere.
function AR:CheckZone()
    if Overlord.InstanceSuspended or not self:OnArenaMap() then return self:StopTicker() end
    self:StartTicker()
end

function AR:OnInstanceSuspend()
    self:StopTicker()
    self.ask = nil
end

function AR:OnInstanceResume()
    self:CheckZone()
    if C_Timer and C_Timer.After then
        C_Timer.After(self.CATCHUP_DELAY, function() AR:CatchUp(false) end)
    end
end

if CreateFrame then
    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_LOGIN")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    events:RegisterEvent("ZONE_CHANGED")
    events:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            if C_Timer and C_Timer.After then
                C_Timer.After(AR.CATCHUP_DELAY, function() AR:CatchUp(false) end)
            end
            return
        end
        pcall(AR.CheckZone, AR)
    end)
    AR.events = events
end

-- ---------------------------------------------------------------- map
-- The pit on the Stranglethorn map: crossed swords, the arena's name and the guild holding it
-- (its faction's colour) or "Free". Called by the world map driver after its chain, like the
-- continent emblems: off Stranglethorn one table lookup; a repaint only on a layout or content
-- pass of the driver, or a new holder. Nothing sent: the board's own fold.
AR.MAP_SITE = { mapID = 1434, center = { 30.6, 47.3 } }
AR.MAP_ICON = "Warfronts-BaseMapIcons-Empty-Barracks"
AR.MAP_RGB = { Alliance = { 0.427, 0.702, 0.949 }, Horde = { 1.0, 0.40, 0.27 } }
local mapPin = { painted = false, shown = false }

function AR:HideMapPin()
    mapPin.painted, mapPin.shown, mapPin.sig, mapPin.holder = false, false, nil, nil
    if mapPin.frame then mapPin.frame:Hide() end
end

function AR:ShowMapTooltip(owner)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:AddLine(T("ARENA_TIP_TITLE", "Gurubashi Arena"), 1, 0.82, 0)
    local holder = self:GetBoard().holder
    if holder then
        local c = self.MAP_RGB[holder.faction] or { 1, 1, 1 }
        GameTooltip:AddLine(string.format(T("LB_SITE_HELD_BY", "Held by %s"), "<" .. holder.guild .. ">"), c[1], c[2], c[3])
        if holder.capturer and holder.capturer ~= "" then
            GameTooltip:AddLine(string.format(T("LB_OUTPOST_CAPTURED_BY", "Taken by %s"), holder.capturer), 0.4, 1, 0.4)
        end
    else
        GameTooltip:AddLine(T("ARENA_UNCLAIMED", "Unclaimed"), 0.7, 0.7, 0.7)
    end
    local body = T("ARENA_TIP_BODY", nil)
    if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function MapPinFrame(parent)
    local f = mapPin.frame
    if not f then
        f = Overlord.MapMarkers.NewFrame("Frame", parent)
        f:SetClipsChildren(false)
        f.icon = f:CreateTexture(nil, "OVERLAY", nil, 2)
        f.icon:SetPoint("CENTER")
        f.title = f:CreateFontString(nil, "OVERLAY")
        f.title:SetPoint("TOP", f, "BOTTOM", 0, -1)
        f.title:SetShadowOffset(2, -2)
        f.sub = f:CreateFontString(nil, "OVERLAY")
        f.sub:SetPoint("TOP", f.title, "BOTTOM", 0, -2)
        f.sub:SetShadowOffset(2, -2)
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self) AR:ShowMapTooltip(self) end)
        f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        mapPin.frame = f
    elseif f:GetParent() ~= parent then
        f:SetParent(parent)
    end
    -- Above the keep and outpost pins of the map (+29).
    f:SetFrameStrata(parent:GetFrameStrata())
    f:SetFrameLevel((parent:GetFrameLevel() or 0) + 30)
    return f
end

local function FontPath(object, fallback)
    local ui = Overlord.UI
    return ui and ui.ResolveLocalizedFontPath and ui.ResolveLocalizedFontPath(object, fallback) or fallback
end

function AR:RefreshMapPin(mapID, layoutChanged, contentRefresh)
    if not mapID or not self.MAP_IDS[mapID] or Overlord.InstanceSuspended then
        if mapPin.shown or mapPin.painted then self:HideMapPin() end
        return
    end
    local holder = self:GetBoard().holder
    if mapPin.painted and not layoutChanged and not contentRefresh and mapPin.holder == holder then return end
    local sig = holder and (holder.guild .. "|" .. tostring(holder.faction)) or ""
    if mapPin.painted and not layoutChanged and not contentRefresh and mapPin.sig == sig then
        mapPin.holder = holder
        return
    end
    local MM = Overlord.MapMarkers
    if not (MM and MM.GetWorldMapCanvas and MM.NewFrame) then return end
    local canvas, parent = MM:GetWorldMapCanvas()
    local cw, ch = canvas and canvas:GetWidth(), canvas and canvas:GetHeight()
    if not parent or not cw or cw <= 0 or not ch or ch <= 0 then
        self:HideMapPin()
        return
    end
    local site = self.MAP_SITE
    local nx, ny = MM:GetMinePositionOnContinentMap(site, mapID)
    if not nx and mapID == site.mapID then nx, ny = site.center[1] / 100, site.center[2] / 100 end
    local ox, oy
    if nx and ny then ox, oy = MM:GetWorldMapOverlayPoint(canvas, parent, nx * cw, ny * ch) end
    local alpha = MM.GetMapIconOpacity and MM.GetMapIconOpacity() or 1
    if not ox or not oy or alpha <= 0 then
        -- Canvas not anchored yet: tried again at the next tick. Icons at 0 %: nothing shown.
        self:HideMapPin()
        if alpha <= 0 then mapPin.painted, mapPin.sig = true, sig end
        return
    end
    local scaleRatio = 1
    local cs, ps = canvas:GetEffectiveScale(), parent:GetEffectiveScale()
    if cs and cs > 0 and ps and ps > 0 then scaleRatio = cs / ps end
    local sizeRatio = MM.CapMarkerScaleRatio and MM.CapMarkerScaleRatio(canvas, parent, scaleRatio) or scaleRatio
    local scale = MM.GetMapIconScale and MM.GetMapIconScale() or 1
    local size = math.floor(math.max(28, math.min(44, cw * 0.035 * sizeRatio)) * scale + 0.5)
    local f = MapPinFrame(parent)
    f:SetSize(size, size)
    f.icon:SetSize(size, size)
    if not f._atlasSet then
        f.icon:SetAtlas(self.MAP_ICON)
        f._atlasSet = true
    end
    f:SetAlpha(alpha)
    f:EnableMouse(true)
    local titleSz = math.floor(math.max(13, math.min(18, size * 0.42)) + 0.5)
    if f._titleSz ~= titleSz then
        f.title:SetFont(FontPath(Fancy24Font, "Fonts\\MORPHEUS.TTF"), titleSz, "")
        f.sub:SetFont(FontPath(GameFontNormalSmall, "Fonts\\FRIZQT__.TTF"),
            math.floor(math.max(11, math.min(15, size * 0.34)) + 0.5), "")
        f._titleSz = titleSz
    end
    f.title:SetTextColor(0.85, 0.75, 0.45)
    f.title:SetText(T("ARENA_TIP_TITLE", "Gurubashi Arena"))
    if holder then
        local c = self.MAP_RGB[holder.faction] or { 1, 1, 1 }
        f.sub:SetText(holder.guild)
        f.sub:SetTextColor(c[1], c[2], c[3])
    else
        f.sub:SetText(T("ARENA_UNCLAIMED", "Unclaimed"))
        f.sub:SetTextColor(0.7, 0.7, 0.7)
    end
    f:ClearAllPoints()
    f:SetPoint("CENTER", parent, "TOPLEFT", math.floor(ox + 0.5), math.floor(oy + 0.5))
    f:Show()
    mapPin.painted, mapPin.shown, mapPin.sig, mapPin.holder = true, true, sig, holder
end

-- (/ov perf mem: this file's own tables.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["Arena.lua"] = function() return { AR = AR, unitTokens = unitTokens, contestSeen = contestSeen, mapPin = mapPin } end
