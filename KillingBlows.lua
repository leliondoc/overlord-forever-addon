-- KillingBlows.lua - 2.5.2: killing blows of the week, one more column of the player table.
-- (Never the guild table, never the guild rating, never a score: honorable kills stay the
-- ranking, its default sort and everything computed from it.)
--
-- Our own count: a killing blow of ours on a player (CombatTracker ProcessKill, the very proof
-- the Most Wanted bounty pays on) counts only with an honorable kill Blizzard credits us within
-- PAIR_SEC after it (the counter trails the blow), or HONOR_FIRST_SEC before it. On Forever the
-- honorable kill of every kill around goes to everyone near: one of another player's kills, just
-- before a blow of ours on a grey player, would otherwise pair with it. So an honorable kill
-- waits a moment only, and HONOR_WAIT_MAX of them at most. A blow on a grey player (no honor) or
-- one Overlord does not credit (an instance, a counter catching up at login) counts nothing, and
-- our killing blows can never pass our honorable kills. A pet's blow is the pet's (the PARTY_KILL
-- attacker is not us). A counter later than PAIR_SEC loses that blow: we count fewer, never more.
--
-- Everybody else's: rows "Name:count" that travel apart from the kill totals (whose rows older
-- versions read field by field and would refuse with one more field): a stream "LB" at the end
-- of a ranking sweep and a row "b" in the ranking feed, between clients whose presence says
-- "~lb" (capability 11, SyncRelay). Older clients are never asked and never sent any of it.
-- A row is taken when it raises what we hold and stays within that player's honorable kills
-- as our ranking holds them (a row ahead of its kill total comes again with the next round).
--
-- Kept per ranking pool (region) and campaign week: another week, or another pool, starts
-- from nothing. Saved in OverlordDB.killingBlows, never in the ranking's own buckets.
Overlord = Overlord or {}
local KB = { PAIR_SEC = 6, HONOR_FIRST_SEC = 1.5, HONOR_WAIT_MAX = 2, QUEUE_MAX = 40, revision = 0 }
Overlord.KillingBlows = KB
-- Ranking capability that carries killing blows (presence "~lb", SyncRelay).
KB.PROTOCOL = 11

local function now() return GetTime and GetTime() or 0 end
local function epoch()
    return math.floor(tonumber(Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs()) or 0)
end
local function pool()
    local tag = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool()
    return type(tag) == "string" and tag or ""
end
local function keyOf(name)
    local lb = Overlord.Leaderboard
    local key = type(name) == "string" and name ~= "" and lb and lb.GetNetworkRowKey and lb:GetNetworkRowKey(name)
    return type(key) == "string" and key ~= "" and key or nil
end

-- The table of this pool and week (created, or emptied when the week changed). nil without a
-- campaign or saved variables (nothing is counted then).
function KB:Data()
    local week = epoch()
    if week <= 0 or type(OverlordDB) ~= "table" then return nil end
    local all = OverlordDB.killingBlows
    if type(all) ~= "table" then all = {}; OverlordDB.killingBlows = all end
    local tag = pool()
    local data = all[tag]
    if type(data) ~= "table" or data.epoch ~= week or type(data.counts) ~= "table" then
        data = { epoch = week, counts = {} }
        all[tag] = data
        -- (Another pool's table of an older week is never read again.)
        for other, old in pairs(all) do
            if type(old) ~= "table" or (tonumber(old.epoch) or 0) < week then all[other] = nil end
        end
        self.revision = self.revision + 1
        self.served = nil
    end
    -- (Rows travel under the ranking's own spelling: no name is kept here, only the counts.)
    if data.names ~= nil then data.names = nil end
    return data
end

-- Killing blows of this player this week (0 when none).
function KB:Get(name)
    local data, key = self:Data(), keyOf(name)
    return data and key and tonumber(data.counts[key]) or 0
end
-- The counts by identity (the ranking's dedup keys), read only.
function KB:Counts()
    local data = self:Data()
    return data and data.counts or nil
end

local function changed(key)
    -- (The profiles' label stays: KB:ProfileRevision moves it once it is old enough.)
    KB.revision = KB.revision + 1
    local lb = Overlord.Leaderboard
    if lb and lb.InvalidateDisplayCache then lb:InvalidateDisplayCache() end
    -- (The ranking feed passes it on: SyncLeaderboardPages.)
    local sync = Overlord.Sync
    if sync and type(sync._NoteKillingBlowMoved) == "function" then pcall(sync._NoteKillingBlowMoved, key) end
    -- (The window's own throttled refresh, only while it is open: RefreshIfVisible is the
    -- path of the site registries and would mark their lists dirty for nothing.)
    local ui = Overlord.LeaderboardUI
    if ui and ui.IsShown and ui.RequestRefresh and ui:IsShown() then pcall(ui.RequestRefresh, ui) end
end

-- Which revision of the counts a ranking profile is labelled with. The profile reads the
-- live counts by key while it is built (sliced; a copy of every count was about 3 ms in one
-- frame at 10,000 players), so its rows may be newer than its label: harmless, every row is
-- a max-wins count. The label moves at most once per PROFILE_REV_SEC: rows arrive every few
-- seconds in a big fight and each move rebuilds the profile's killing blows (the feed passes
-- each change on live meanwhile).
local PROFILE_REV_SEC = 30
function KB:ProfileRevision()
    if not self:Data() then return nil end
    local served, tag = self.served, pool()
    local now = GetTime and GetTime() or 0
    if served and served.pool == tag then
        if served.revision == self.revision then return served.revision end
        if now >= served.at and now - served.at < PROFILE_REV_SEC then return served.revision end
    end
    -- (Another pool's table this session: a new revision, so no profile of the other is reused.)
    if served and served.pool ~= tag then self.revision = self.revision + 1 end
    self.served = { revision = self.revision, at = now, pool = tag }
    return self.revision
end

-- ---------- Our own count ----------
local blows, honors = {}, {}
local function prune(queue, at, wait)
    while queue[1] and at - queue[1] > wait do table.remove(queue, 1) end
end
local function push(queue, at, max)
    if #queue >= max then table.remove(queue, 1) end
    queue[#queue + 1] = at
end

function KB:CreditOwn(count)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return 0 end
    local sync = Overlord.Sync
    local name = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    if sync and sync.CanonicalForeverName and type(name) == "string" and name ~= "" then
        name = sync:CanonicalForeverName(name) or name
    end
    local key, data = keyOf(name), self:Data()
    if not key or not data then return 0 end
    local total = (tonumber(data.counts[key]) or 0) + count
    -- (Within our own honorable kills, as every other client checks it.)
    local lb = Overlord.Leaderboard
    local hk = lb and lb.GetMaxKillsForDedupName and tonumber(lb:GetMaxKillsForDedupName(name)) or total
    if total > hk then total = hk end
    if total <= (tonumber(data.counts[key]) or 0) then return 0 end
    data.counts[key] = total
    changed(key)
    return total
end

-- A killing blow of ours on a player, outside instances (CombatTracker ProcessKill).
function KB:NoteOwnBlow()
    local at = now()
    prune(honors, at, self.HONOR_FIRST_SEC)
    if honors[1] then
        table.remove(honors, 1)
        self:CreditOwn(1)
    else
        prune(blows, at, self.PAIR_SEC)
        push(blows, at, self.QUEUE_MAX)
    end
end

-- Honorable kills Blizzard just credited us (CombatTracker CreditHonorableKills).
function KB:NoteOwnHonorable(count)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return end
    local at, credit = now(), 0
    prune(blows, at, self.PAIR_SEC)
    prune(honors, at, self.HONOR_FIRST_SEC)
    for _ = 1, math.min(count, self.QUEUE_MAX) do
        if blows[1] then
            table.remove(blows, 1)
            credit = credit + 1
        else
            push(honors, at, self.HONOR_WAIT_MAX)
        end
    end
    if credit > 0 then self:CreditOwn(credit) end
end

-- Leaving the world for an instance, a reload of the baselines: nothing waits for a partner.
function KB:ResetPairing()
    blows, honors = {}, {}
end

-- ---------- Rows of the network ----------
KB.stats = { taken = 0, known = 0, refused = 0, overHK = 0 }

-- "Name:count". True when the row is valid (taken, or holding no more than we do); second
-- result true when it changed our count. Nothing else is read from it.
function KB:MergeRow(payload, sender)
    local stats = self.stats
    if type(payload) ~= "string" or #payload > 250 then stats.refused = stats.refused + 1 return false end
    local name, countText = payload:match("^([^:]+):(%d+)$")
    local count = tonumber(countText)
    local ceiling = tonumber(Overlord.PLAUSIBLE_SYNC_KILL_CEILING) or 15000
    local sync, lb = Overlord.Sync, Overlord.Leaderboard
    if not name or not count or count < 1 or count > ceiling or #countText > 6
        or not (sync and sync.IsValidPlayerName and sync:IsValidPlayerName(name))
        or (sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name))
        or (sync.KillAntiSpoofIsBlacklisted and sync:KillAntiSpoofIsBlacklisted(name)) then
        stats.refused = stats.refused + 1
        return false
    end
    local key, data = keyOf(name), self:Data()
    if not key or not data then stats.refused = stats.refused + 1 return false end
    local held = tonumber(data.counts[key]) or 0
    if count <= held then stats.known = stats.known + 1 return true, false end
    -- Never more killing blows than honorable kills, as our ranking holds them now.
    local hk = lb and lb.GetMaxKillsForDedupName and tonumber(lb:GetMaxKillsForDedupName(name)) or 0
    if count > hk then stats.overHK = stats.overHK + 1 return false end
    data.counts[key] = count
    stats.taken = stats.taken + 1
    changed(key)
    return true, true
end

-- A peer we may send or ask killing blows (its presence said "~lb" in the last five minutes).
function KB:PeerCarries(peer)
    local net = Overlord.Relay
    local capability = net and net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(peer)
    return capability ~= nil and capability >= self.PROTOCOL
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["KillingBlows.lua"] = function() return { KB = KB, blows = blows, honors = honors } end
