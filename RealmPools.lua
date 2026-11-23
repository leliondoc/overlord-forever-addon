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
    if pending and pending.ruleset == fresh then
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
Overlord.MemoryParts["RealmPools.lua"] = function() return { RealmPools = RealmPools, RULESET_POOL = RULESET_POOL, CHANNEL_SUFFIX = CHANNEL_SUFFIX } end
