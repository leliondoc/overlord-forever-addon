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
local RULESET_POOL = { pvp = "global", normal = "normal", rp = "rp", hardcore = "hardcore" }
RealmPools.RULESET_POOLS = { normal = true, rp = true, hardcore = true }
local CHANNEL_SUFFIX = { pvp = "", normal = "N", rp = "R", hardcore = "H" }

local function GameRuleActive(rule)
    if rule == nil or not C_GameRules or type(C_GameRules.IsGameRuleActive) ~= "function" then
        return nil
    end
    local ok, active = pcall(C_GameRules.IsGameRuleActive, rule)
    if not ok then return nil end
    return active == true
end

-- Fallback when the game-rule API is missing: the realm name ("Classic Beta PvP",
-- "Classic Beta PvE 2"). A name never overrides the API.
local function RulesetFromRealmName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local lower = " " .. name:lower() .. " "
    if lower:find("hardcore", 1, true) then return "hardcore" end
    if lower:find("roleplay", 1, true) or lower:find("[%s%-]rp[%s%-%d]") then return "rp" end
    if lower:find("pvp", 1, true) then return "pvp" end
    if lower:find("pve", 1, true) or lower:find("normal", 1, true) then return "normal" end
    return nil
end
RealmPools.RulesetFromRealmName = RulesetFromRealmName

-- Detected once per session: saved buckets and wire tags must never change while
-- the character is logged in. Unknown (no API, unreadable realm) = the historical
-- population (PvP), exactly what every client did before 1.4.0.
function RealmPools:GetRuleset()
    if self._ruleset then return self._ruleset end
    local rules = Enum and Enum.GameRule
    local hc = GameRuleActive(rules and rules.HardcoreRuleset)
    local rp = GameRuleActive(rules and rules.RPRuleset)
    local pvp = GameRuleActive(rules and rules.PvPRuleset)
    local ruleset
    if hc then ruleset = "hardcore"
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
    self._ruleset = ruleset or "pvp"
    return self._ruleset
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

-- Compatibilite des lecteurs historiques : un nom ne prouve jamais une region.
function RealmPools:InferPoolTagFromRealmName()
    return ""
end

-- Outposts are never linked across rulesets.
function RealmPools:AreOutpostCrossPoolsLinked(poolA, poolB)
    poolA = self:NormalizeRegionPool(poolA)
    poolB = self:NormalizeRegionPool(poolB)
    if poolA == "" or poolB == "" then return false end
    return poolA == poolB
end
