-- RealmPools.lua - Campagnes Forever : une par ruleset (1.4.0), aucun royaume ni
-- sous-pool linguistique.
Overlord = Overlord or {}
local RealmPools = {}
Overlord.RealmPools = RealmPools

-- 1.4.0: Forever has one realm per ruleset (Normal, PvP, RP, later Hardcore), and
-- each ruleset now runs its own Overlord campaign. PvP keeps the historical tag
-- "global": the whole current population plays there, so 1.3.x clients and the
-- saved PvP data stay compatible. The other rulesets get their own tag; packets,
-- Battle.net bands, the channel and saved buckets of another ruleset never mix.
-- 1.4.1: the non-PvP pools and channels were renamed. 1.4.0 Normal/RP clients
-- could serve their old 1.3.x ("global") ladder snapshot to each other, so their
-- ladders may hold PvP rows; the new tags make a clean break from them.
-- 2.1.0: Roleplay PvP (Blizzard, 2026-10-22) is a campaign of its own, with both the
-- RP and the PvP rule on. 2.0.8 counted it with RP, under the tag "rpg".
local RULESET_POOL = { pvp = "global", normal = "pve", rp = "rpg", rppvp = "rpv", hardcore = "hc" }
RealmPools.RULESET_POOLS = { pve = true, rpg = true, rpv = true, hc = true }
-- Tags used by 1.4.0 only: their saved data is dropped once (Core.lua).
RealmPools.RETIRED_POOLS = { "normal", "rp", "hardcore" }
local CHANNEL_SUFFIX = { pvp = "", normal = "E", rp = "RP", rppvp = "RPP", hardcore = "HC" }

local function GameRuleActive(rule)
    if rule == nil or not C_GameRules or type(C_GameRules.IsGameRuleActive) ~= "function" then
        return nil
    end
    local ok, active = pcall(C_GameRules.IsGameRuleActive, rule)
    -- nil = not answered yet: unknown, never "rule off".
    if not ok or active == nil then return nil end
    return active == true
end

-- Fallback when the game-rule API is missing: the realm name ("Classic Beta PvP",
-- "Classic Beta PvE 2"). A name never overrides the API.
local function RulesetFromRealmName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local lower = " " .. name:lower() .. " "
    if lower:find("hardcore", 1, true) then return "hardcore" end
    local roleplay = lower:find("roleplay", 1, true) or lower:find("[%s%-]rp[%s%-%d]")
        or lower:find("rppvp", 1, true)
    local pvp = lower:find("pvp", 1, true)
    if roleplay and pvp then return "rppvp" end
    if roleplay then return "rp" end
    if pvp then return "pvp" end
    if lower:find("pve", 1, true) or lower:find("normal", 1, true) then return "normal" end
    return nil
end
RealmPools.RulesetFromRealmName = RulesetFromRealmName

-- One reading of the rules and the realm name, kept nowhere: (ruleset or nil, what was
-- read, settled). Settled = every rule this client knows has answered (a rule missing
-- from Enum.GameRule is not waited for; no rule API at all = nothing to wait for).
local function ReadRuleset()
    local rules = Enum and Enum.GameRule
    local hc = GameRuleActive(rules and rules.HardcoreRuleset)
    local rp = GameRuleActive(rules and rules.RPRuleset)
    local pvp = GameRuleActive(rules and rules.PvPRuleset)
    local apiPresent = type(rules) == "table" and type(C_GameRules) == "table"
        and type(C_GameRules.IsGameRuleActive) == "function"
    local settled = not apiPresent
        or ((rules.HardcoreRuleset == nil or hc ~= nil) and (rules.RPRuleset == nil or rp ~= nil)
            and (rules.PvPRuleset == nil or pvp ~= nil))
    local ruleset
    if hc then ruleset = "hardcore"
    elseif rp and pvp then ruleset = "rppvp"
    elseif rp then ruleset = "rp"
    elseif pvp then ruleset = "pvp"
    elseif hc == false and rp == false and pvp == false then ruleset = "normal"
    end
    local okName, realm = pcall(function() return GetRealmName and GetRealmName() end)
    local fromName = okName and RulesetFromRealmName(realm) or nil
    -- "No rule on" read before the client knows its rules would put a PvP player
    -- in Normal and split the population: a realm name that clearly says
    -- PvP/RP/Hardcore wins over that single answer.
    if not ruleset or (ruleset == "normal" and fromName and fromName ~= "normal") then
        ruleset = fromName or ruleset
    end
    -- A realm named Roleplay PvP completes a single rule read as on: both are meant.
    if fromName == "rppvp" and (ruleset == "rp" or ruleset == "pvp") then ruleset = "rppvp" end
    return ruleset, { hc = hc, rp = rp, pvp = pvp, realm = okName and realm or nil }, settled
end

-- Detected once per session: saved buckets and wire tags must never change while
-- the character is logged in. Unknown (no API, unreadable realm) = the historical
-- population (PvP), exactly what every client did before 1.4.0.
function RealmPools:GetRuleset()
    if self._ruleset then return self._ruleset end
    local ruleset, read, settled = ReadRuleset()
    -- Neither the game rules nor the realm name answered: PvP is assumed for the
    -- session. /ov network shows it so a wrong campaign is visible at launch.
    self._rulesetAssumed = ruleset == nil
    self._ruleset = ruleset or "pvp"
    self._rulesetRead = read
    self._rulesetSettled = settled
    return self._ruleset
end

-- 2.6.1: the campaign is chosen at ADDON_LOADED, and the client may not know its realm
-- yet (a Roleplay PvP client showed realm "" and id 0 there). A rule read before the
-- game had it put Roleplay PvP players in the PvP campaign, their guild's rows with
-- them. After the login the rules are read again: a settled answer that names another
-- campaign, read the same way twice CONFIRM_SEC apart, means this session runs in the
-- wrong campaign. Returns that ruleset (once found it stays), nil otherwise.
RealmPools.CONFIRM_SEC = 3
-- "No rule on" is also what a client answers before it knows its rules: a Normal reading that
-- no realm name backs must hold that long before a PvP session is paused for it (pausing a
-- healthy player is worse than a Normal one speaking a few seconds more in the wrong campaign).
RealmPools.NORMAL_CONFIRM_SEC = 30
RealmPools.PENDING_STALE_SEC = 60
function RealmPools:CheckSessionRuleset(now)
    if self._rulesetMismatch then return self._rulesetMismatch end
    local current = self:GetRuleset()
    local fresh, read, settled = ReadRuleset()
    if not settled or fresh == nil or fresh == current then
        self._rulesetPending = nil
        return nil
    end
    now = tonumber(now) or 0
    local pending = self._rulesetPending
    -- (A first reading heard long ago, the checks capped in between, is not a confirmation:
    -- the next one starts over.)
    if pending and pending.ruleset == fresh and now - pending.at <= pending.need + self.PENDING_STALE_SEC then
        if now - pending.at < pending.need then return nil end
        self._rulesetPending = nil
        self._rulesetMismatch = fresh
        self._rulesetMismatchRead = read
        return fresh
    end
    local need = self.CONFIRM_SEC
    if fresh == "normal" and RulesetFromRealmName(read.realm) ~= "normal" then
        need = self.NORMAL_CONFIRM_SEC
    end
    self._rulesetPending = { ruleset = fresh, at = now, need = need }
    return nil
end

-- 2026-11-26: a reading at load that the session re-check may still overturn: assumed (no
-- answer), not settled (a rule unanswered), or any reading no realm name backs. A settled
-- reading can be wrong too: a rule the client did not know yet reads off, so a Roleplay PvP
-- client may read PvP alone (2.6.1) or nothing (Normal). Such a session keeps a journal of the
-- names its bucket learns (Leaderboard:BeginCampaignJournal); on Forever no realm name says its
-- ruleset, so every session keeps one. It costs memory only: nothing waits, nothing is refused.
function RealmPools:IsLoadReadingDoubtful()
    local ruleset = self:GetRuleset()
    if self._rulesetAssumed or not self._rulesetSettled then return true end
    local read = self._rulesetRead or {}
    return RulesetFromRealmName(read.realm) ~= ruleset
end

-- 2026-11-26: the last reading of the session, at logout or /reload, long after the client
-- learnt its rules. One reading and no confirmation, so only the strong case counts: a rule
-- read ON that our campaign does not have (a rule on is never a "not known yet" answer; an
-- all-off answer, or one rule fewer, may be). Returns that ruleset, nil otherwise.
local RULES_OF = { normal = {}, pvp = { pvp = true }, rp = { rp = true },
    rppvp = { rp = true, pvp = true }, hardcore = { hc = true } }
function RealmPools:LogoutRulesetDiffers()
    local current = self:GetRuleset()
    local fresh, read, settled = ReadRuleset()
    if not settled or fresh == nil or fresh == current then return nil end
    local have = RULES_OF[current] or {}
    for _, rule in ipairs({ "hc", "rp", "pvp" }) do
        if read[rule] == true and not have[rule] then return fresh end
    end
    return nil
end

-- The last campaign purge (Overlord:NoteCampaignPurge): names learnt in the wrong campaign that
-- left its ranking.
local function PurgeText()
    local p = type(OverlordDB) == "table" and OverlordDB.campaignPurge or nil
    if type(p) ~= "table" then return "" end
    local when = (date and tonumber(p.at) and tonumber(p.at) > 0) and date("%Y-%m-%d %H:%M", p.at) or "?"
    return string.format("; last campaign purge: %d names left the ranking (%s, %s)",
        tonumber(p.n) or 0, p.why == "logout" and "rules read again at logout"
            or (p.why == "pause-error" and "session paused, the purge failed") or "session paused", when)
end

-- /ov network: what the campaign was detected from, and where this client plays.
function RealmPools:DescribeDetection()
    self:GetRuleset()
    local read = self._rulesetRead or {}
    local function word(value)
        if value == nil then return "?" end
        return value and "on" or "off"
    end
    local function ask(fn)
        if type(fn) ~= "function" then return "?" end
        local ok, value = pcall(fn)
        return ok and value ~= nil and tostring(value) or "?"
    end
    return "hardcore " .. word(read.hc) .. ", RP " .. word(read.rp) .. ", PvP " .. word(read.pvp)
        .. "; realm " .. tostring(read.realm or "?") .. " (id " .. ask(GetRealmID)
        .. "), region " .. ask(GetCurrentRegionName) .. " (id " .. ask(GetCurrentRegion) .. ")"
        .. "; Battle.net realms known " .. tostring(self:CountKnownBandRealms())
        .. ", refused for their realm's campaign " .. tostring(self.bandRefused or 0)
        .. PurgeText()
end

-- 2026-11-26 (Roleplay PvP rows in the Normal ranking): a Battle.net friend says its campaign in
-- its band, and a client that read its rules wrong says the wrong one in good faith. The friend's
-- record (C_BattleNet) names its home realm, and a realm plays one ruleset. Every Battle.net
-- message notes which campaign a friend of that realm said, refused or not. Once a realm's
-- friends clearly agree (BAND_MIN different characters at least, twice as many as for any other
-- campaign), a band naming another campaign from that realm is refused. A realm without that
-- majority, or a record without a realm, changes nothing: everything passes as before. Local
-- only: nothing is sent, nobody answers more. Kept between sessions (a realm keeps its ruleset),
-- each character's word for 21 days, its latest word only (a character that read wrong and then
-- right counts once, for the right campaign). Fail safe: a realm where two campaigns each have
-- BAND_MIN characters is mixed (a shared realm id, or many misreaders): nothing is refused there;
-- our own realm is never refused (we know its campaign).
RealmPools.BAND_MIN = 3
RealmPools.BAND_KEEP_SEC = 21 * 86400
RealmPools.BAND_REALMS_MAX = 400
RealmPools.BAND_WHO_MAX = 40
RealmPools.BAND_TOUCH_SEC = 3600

local function BandNow()
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

-- The friend's home realm and character: the realm id of its character's GUID, else the
-- record's realm id or name. A record heard once with its GUID keeps it for the session (a later
-- record without one gives the same realm and the same character, never a second word).
local bandGuidRealm = {}     -- friend GUID -> realm key, false (one entry per friend heard)
local bandAccountGuid = {}   -- game account id -> its character's last GUID
local function BandIdentity(info)
    if type(info) ~= "table" then return nil end
    local guid, account = info.playerGuid, info.gameAccountID
    if type(guid) ~= "string" or guid == "" then
        guid = account and bandAccountGuid[account] or nil
    elseif account then
        bandAccountGuid[account] = guid
    end
    if guid then
        local key = bandGuidRealm[guid]
        if key == nil then
            local id = guid:match("^Player%-(%d+)%-")
            -- ("g<id>": a GUID's server id and a record's realm id may not be the same numbers,
            -- so they never share a key. A shared one could have put two realms in one tally,
            -- and a friend of the smaller one would have been refused for the other's campaign.)
            key = id and id ~= "0" and ("g" .. id) or false
            bandGuidRealm[guid] = key
        end
        -- (The character's GUID: a game account id is a session handle, never saved.)
        if key then return key, guid end
    end
    local who = guid
    if not who then
        local name = info.characterName
        who = type(name) == "string" and name ~= "" and name:lower() or nil
    end
    local id = tonumber(info.realmID)
    if id and id > 0 then return "r" .. math.floor(id), who end
    local name = info.realmName
    if type(name) == "string" and name ~= "" then return "n" .. name:lower(), who end
    return nil
end

-- Our own realm's keys, by our GUID's server id and by the game's realm id (a friend heard
-- without its GUID gives the record's realm id): never refused, we know its campaign.
-- (Read once our GUID is known: a key test per Battle.net message, no garbage.)
local function IsOwnBandKey(self, key)
    local ownBandKeys = self._ownBandKey
    if not ownBandKeys then
        local guid = UnitGUID and UnitGUID("player")
        local id = type(guid) == "string" and guid:match("^Player%-(%d+)%-") or nil
        if not id or id == "0" then return false end
        ownBandKeys = { ["g" .. id] = true }
        self._ownBandKey = ownBandKeys
        local ok, realmID = false, nil
        if type(GetRealmID) == "function" then ok, realmID = pcall(GetRealmID) end
        realmID = ok and tonumber(realmID) or nil
        if realmID and realmID > 0 then ownBandKeys["r" .. math.floor(realmID)] = true end
    end
    return ownBandKeys[key] == true
end

-- (Bands are a handful of strings: read once each, not at every message.)
function RealmPools:BandPool(band)
    if type(band) ~= "string" then return "" end
    self._bandPools = self._bandPools or {}
    local known = self._bandPools[band]
    if known then return known end
    local pool = band:match("^Forever_([a-z]+)_[AH]$")
    pool = pool and self:NormalizeRegionPool(pool) or ""
    if pool ~= "" then self._bandPools[band] = pool end
    return pool
end

function RealmPools:BandStore()
    if type(OverlordDB) ~= "table" then return nil end
    local store = OverlordDB.bnetRealmBands
    if type(store) ~= "table" then
        store = {}
        OverlordDB.bnetRealmBands = store
    end
    if not self._bandPruned then
        -- Once a session: words older than BAND_KEEP_SEC leave, then empty realms.
        self._bandPruned = true
        local old = BandNow() - self.BAND_KEEP_SEC
        for key, realm in pairs(store) do
            local any = false
            if type(realm) == "table" and type(realm.bands) == "table" then
                for pool, list in pairs(realm.bands) do
                    local keep = false
                    if type(list) == "table" then
                        for who, at in pairs(list) do
                            if (tonumber(at) or 0) < old then list[who] = nil else keep = true end
                        end
                    end
                    if keep then any = true else realm.bands[pool] = nil end
                end
            end
            if not any then store[key] = nil end
        end
    end
    return store
end

function RealmPools:CountKnownBandRealms()
    local store = type(OverlordDB) == "table" and OverlordDB.bnetRealmBands
    local n = 0
    if type(store) == "table" then for _ in pairs(store) do n = n + 1 end end
    return n
end

-- The campaign a realm's friends agree on, or nil. Cached until a new word for that realm (it is
-- read only when one of them speaks, and a speaker renews its word hourly: an hour old at most).
function RealmPools:RealmBandVerdict(key)
    local now = BandNow()
    self._bandVerdict = self._bandVerdict or {}
    local cached = self._bandVerdict[key]
    if cached ~= nil then return cached or nil end
    local store = self:BandStore()
    local realm = store and store[key]
    local verdict = false
    if type(realm) == "table" and type(realm.bands) == "table" then
        local old = now - self.BAND_KEEP_SEC
        local best, bestN, secondN = nil, 0, 0
        for pool, list in pairs(realm.bands) do
            local n = 0
            if type(list) == "table" then
                for _, at in pairs(list) do
                    if (tonumber(at) or 0) >= old then n = n + 1 end
                end
            end
            if n > bestN then
                best, secondN, bestN = pool, bestN, n
            elseif n > secondN then
                secondN = n
            end
        end
        -- (Two campaigns with BAND_MIN characters each: a mixed realm, never decided.)
        if best and bestN >= self.BAND_MIN and bestN >= 2 * secondN and secondN < self.BAND_MIN then
            verdict = best
        end
    end
    self._bandVerdict[key] = verdict
    return verdict or nil
end

-- Notes the friend's word; returns its realm key (nil: the record names no realm).
function RealmPools:NoteBNetBand(info, band)
    local key, who = BandIdentity(info)
    if not key then return nil end
    local pool = self:BandPool(band)
    if not who or pool == "" then return key end
    local store = self:BandStore()
    if not store then return key end
    local now = BandNow()
    local realm = store[key]
    if type(realm) ~= "table" or type(realm.bands) ~= "table" then
        -- Room for one more realm: the one heard longest ago leaves.
        if self:CountKnownBandRealms() >= self.BAND_REALMS_MAX then
            local oldKey, oldAt
            for k, r in pairs(store) do
                local at = type(r) == "table" and tonumber(r.at) or 0
                if not oldAt or at < oldAt then oldKey, oldAt = k, at end
            end
            if oldKey then
                store[oldKey] = nil
                if self._bandVerdict then self._bandVerdict[oldKey] = nil end
            end
        end
        realm = { at = now, bands = {} }
        store[key] = realm
    end
    local list = realm.bands[pool]
    if type(list) ~= "table" then
        list = {}
        realm.bands[pool] = list
    end
    local last = tonumber(list[who])
    if last and now - last < self.BAND_TOUCH_SEC then return key end
    if not last then
        local n, oldWho, oldAt = 0, nil, nil
        for w, at in pairs(list) do
            n = n + 1
            at = tonumber(at) or 0
            if not oldAt or at < oldAt then oldWho, oldAt = w, at end
        end
        if n >= self.BAND_WHO_MAX and oldWho then list[oldWho] = nil end
        -- (Its latest word only: a word for another campaign leaves.)
        for other, words in pairs(realm.bands) do
            if other ~= pool and type(words) == "table" then words[who] = nil end
        end
    end
    list[who] = now
    realm.at = now
    if self._bandVerdict then self._bandVerdict[key] = nil end
    return key
end

-- The rules each band campaign names. A misread client misses rules ("no rule on" at load: a
-- Roleplay PvP client says Normal or PvP), it never invents one: a band is refused only when it
-- names fewer rules than its realm's campaign, all of them in it (a band with a rule the
-- verdict lacks is never refused: the verdict may be the misreaders' own majority).
local BAND_RULES = { global = RULES_OF.pvp, pve = RULES_OF.normal, rpg = RULES_OF.rp,
    rpv = RULES_OF.rppvp, hc = RULES_OF.hardcore }
local function FewerRules(pool, verdict)
    local have, full = BAND_RULES[pool], BAND_RULES[verdict]
    if not have or not full then return false end
    local n, m = 0, 0
    for rule in pairs(have) do
        if not full[rule] then return false end
        n = n + 1
    end
    for _ in pairs(full) do m = m + 1 end
    return n < m
end

-- Called for every Battle.net message (direct and relay envelope), before the band check:
-- true = refused, its band names fewer rules than the campaign its realm's friends agree on.
function RealmPools:IsBNetBandRefused(info, band)
    local key = self:NoteBNetBand(info, band)
    if not key then return false end
    if IsOwnBandKey(self, key) then return false end
    local pool = self:BandPool(band)
    -- (A band that names no campaign is the band check's to refuse, not this rule's.)
    if pool == "" then return false end
    local verdict = self:RealmBandVerdict(key)
    if not verdict or pool == verdict or not FewerRules(pool, verdict) then return false end
    -- (Counted only when it changes something: another campaign's band is refused anyway.)
    if pool == self:GetOverlordPoolTag() then self.bandRefused = (self.bandRefused or 0) + 1 end
    return true
end

function RealmPools:GetChannelSuffix()
    return CHANNEL_SUFFIX[self:GetRuleset()] or ""
end

-- Forever beta is one population per ruleset. Accept old region tags so 1.0.3
-- packets and SavedVariables converge into the PvP bucket ("global").
function RealmPools:NormalizeRegionPool(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if self.RULESET_POOLS[pool] then return pool end
    return ""
end

function RealmPools:GetOverlordPoolTag()
    return RULESET_POOL[self:GetRuleset()] or "global"
end

-- Outposts are never linked across rulesets.
function RealmPools:AreOutpostCrossPoolsLinked(poolA, poolB)
    poolA = self:NormalizeRegionPool(poolA)
    poolB = self:NormalizeRegionPool(poolB)
    if poolA == "" or poolB == "" then return false end
    return poolA == poolB
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["RealmPools.lua"] = function() return { RealmPools = RealmPools, RULESET_POOL = RULESET_POOL, CHANNEL_SUFFIX = CHANNEL_SUFFIX, RULES_OF = RULES_OF, bandGuidRealm = bandGuidRealm, bandAccountGuid = bandAccountGuid, bnetRealmBands = OverlordDB and OverlordDB.bnetRealmBands } end
