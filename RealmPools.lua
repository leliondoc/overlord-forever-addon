-- RealmPools.lua - Regions Forever. Aucun royaume ni sous-pool linguistique.
Overlord = Overlord or {}
local RealmPools = {}
Overlord.RealmPools = RealmPools

-- Forever beta is one global population. Accept old tags so 1.0.3 packets and
-- SavedVariables converge into the same bucket during the rolling update.
function RealmPools:NormalizeRegionPool(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    return ""
end

function RealmPools:GetOverlordPoolTag()
    return "global"
end

-- Compatibilite des lecteurs historiques : un nom ne prouve jamais une region.
function RealmPools:InferPoolTagFromRealmName()
    return ""
end

-- All historical region tags refer to the same Forever beta population.
function RealmPools:AreOutpostCrossPoolsLinked(poolA, poolB)
    poolA = self:NormalizeRegionPool(poolA)
    poolB = self:NormalizeRegionPool(poolB)
    if poolA == "" or poolB == "" then return false end
    return poolA == poolB
end
