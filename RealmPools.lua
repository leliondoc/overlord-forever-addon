-- RealmPools.lua - Regions Forever. Aucun royaume ni sous-pool linguistique.
Overlord = Overlord or {}
local RealmPools = {}
Overlord.RealmPools = RealmPools

-- Pool Overlord Forever (realmless) : uniquement NA (`us`) et EU (`eu`).
-- Plus de sous-pools FR/DE : un compte et ses alts partagent le meme bucket.
function RealmPools:NormalizeRegionPool(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "na" then pool = "us" end
    if pool == "fr" or pool == "de" then pool = "eu" end
    if pool == "us" or pool == "eu" then return pool end
    return ""
end

-- L'API courante prime. Une ancienne session ne doit pas verrouiller la region.
function RealmPools:GetOverlordPoolTag()
    local region = GetCurrentRegion and GetCurrentRegion()
    if region == 1 then return "us" end
    if region == 3 then return "eu" end
    local previous = self:NormalizeRegionPool(OverlordDB and OverlordDB.lastSessionPool)
    return previous ~= "" and previous or "eu"
end

-- Compatibilite des lecteurs historiques : un nom ne prouve jamais une region.
function RealmPools:InferPoolTagFromRealmName()
    return ""
end

-- Plus de pont FR<->EU : NA et EU restent separes.
function RealmPools:AreOutpostCrossPoolsLinked(poolA, poolB)
    poolA = self:NormalizeRegionPool(poolA)
    poolB = self:NormalizeRegionPool(poolB)
    if poolA == "" or poolB == "" then return false end
    return poolA == poolB
end
