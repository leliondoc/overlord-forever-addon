-- Leaderboard.lua - Classement des kills et captures par joueur
Overlord = Overlord or {}
Overlord.Leaderboard = {
    KILL_RANK_LIMIT = 500,
    kills = {},
    captures = {},
    captureCount = {},
    bountyTimes = {},
    bountyKills = {},
    playerInfo = {},
    leaderboardDirty = false,
    targetRevision = 0,
}

local function isGuildKeepSiegeKey(key)
    if type(key) ~= "string" or not key:match("^%d+$") then return false end
    if #key == 8 then return true end -- historical daily proofs
    local hour = #key == 10 and tonumber(key:sub(9, 10))
    return hour == 3 or hour == 9 or hour == 15 or hour == 21
end

-- Plafond de plausibilite du compteur de captures d'un avant-poste par (site, guilde).
-- Un avant-poste ne peut etre repris qu'apres expiration du hold (>= 5 min) : le maximum
-- theorique sur une campagne hebdomadaire est ~2016 captures (1 toutes les 5 min, 7 jours).
-- On fixe le plafond bien au-dessus (5000) pour NE JAMAIS rejeter un total legitime (ce qui
-- creerait une divergence), tout en attrapant l'absurde (injection / corruption a 6+ chiffres)
-- qui, fusionne en max(), resterait fige partout sans jamais redescendre.
local PLAUSIBLE_OUTPOST_CAPTURE_COUNT = 5000

-- table.sort est monolithique. Les registres persistes peuvent atteindre plusieurs
-- milliers de lignes ; ce merge-sort coopératif est la primitive commune des builders
-- login/UI/reseau qui ne doivent jamais monopoliser une frame.
local function sortRowsWithYield(rows, less, yieldWork)
    if #rows < 2 then return rows end
    if not yieldWork then
        table.sort(rows, less)
        return rows
    end
    local source, target, width, count = rows, {}, 1, #rows
    while width < count do
        local first = 1
        while first <= count do
            local middle = math.min(first + width, count + 1)
            local finish = math.min(first + 2 * width - 1, count)
            local left, right, out = first, middle, first
            while left < middle or right <= finish do
                if right > finish
                    or (left < middle and (less(source[left], source[right])
                        or not less(source[right], source[left]))) then
                    target[out], left = source[left], left + 1
                else
                    target[out], right = source[right], right + 1
                end
                out = out + 1
                yieldWork()
            end
            first = first + 2 * width
        end
        source, target = target, source
        width = width * 2
    end
    if source ~= rows then
        for i = 1, count do rows[i] = source[i]; yieldWork() end
    end
    return rows
end

-- Les preuves terrain GK utilisent GetServerTime. Toutes leurs bornes de plausibilite et
-- leurs day keys doivent lire la meme horloge, sans quoi un PC decale peut afficher la capture
-- tout en rejetant son tenant ou sa victoire.
local function leaderboardServerNow()
    return (GetServerTime and GetServerTime()) or time()
end

-- Index inverse dedupKey -> nom canonique : evite les scans O(N) dans les fusions lecture.
-- Invalidé par MarkDirty / MergeDuplicateLeaderboardKeysByDedup.
local dedupCanonicalIndex = {}
local dedupCanonicalValid = false
local dedupCanonicalGeneration = 0
local dedupKillMaxIndex = nil
local dedupCaptureMaxIndex = nil
local NoteDedupCanonicalName

local function InvalidateDedupCanonicalIndex()
    dedupCanonicalValid = false
    dedupCanonicalGeneration = dedupCanonicalGeneration + 1
end

local function EnsureDedupCanonicalIndex(lb)
    return dedupCanonicalValid and dedupCanonicalIndex or nil
end

local function GetKillDedupKey(name)
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(name) or name
    return dk and dk:lower() or nil
end

local function EnsureDedupKillMaxIndex(lb)
    if dedupKillMaxIndex then return dedupKillMaxIndex end
    dedupKillMaxIndex = {}
    for name, count in pairs(lb.kills or {}) do
        local dk = GetKillDedupKey(name)
        count = tonumber(count) or 0
        if dk and count > (dedupKillMaxIndex[dk] or 0) then
            dedupKillMaxIndex[dk] = count
        end
    end
    return dedupKillMaxIndex
end

local function UpdateDedupKillMaxIndex(name, count)
    NoteDedupCanonicalName(Overlord.Leaderboard, name)
    if not dedupKillMaxIndex then return end
    local dk = GetKillDedupKey(name)
    count = tonumber(count) or 0
    if dk and count > (dedupKillMaxIndex[dk] or 0) then
        dedupKillMaxIndex[dk] = count
    end
end

function Overlord.Leaderboard:GetMaxKillsForDedupName(playerName)
    if not playerName or playerName == "" then return 0 end
    local dk = GetKillDedupKey(playerName)
    if not dk then return tonumber(self.kills and self.kills[playerName]) or 0 end
    local index = EnsureDedupKillMaxIndex(self)
    return tonumber(index[dk]) or 0
end

-- Index inverse dedupKey -> max captures : miroir de dedupKillMaxIndex. Obligatoire car
-- GetMaxCapturesForDedupName est appele par ligne LC entrante (SanitizeSyncedCaptureCount) :
-- un scan O(N) de captureCount par message serait le pattern interdit n°3 (spikes en event massif).
local function EnsureDedupCaptureMaxIndex(lb)
    if dedupCaptureMaxIndex then return dedupCaptureMaxIndex end
    dedupCaptureMaxIndex = {}
    for name, count in pairs(lb.captureCount or {}) do
        local dk = GetKillDedupKey(name)
        count = tonumber(count) or 0
        if dk and count > (dedupCaptureMaxIndex[dk] or 0) then
            dedupCaptureMaxIndex[dk] = count
        end
    end
    return dedupCaptureMaxIndex
end

local function UpdateDedupCaptureMaxIndex(name, count)
    NoteDedupCanonicalName(Overlord.Leaderboard, name)
    if not dedupCaptureMaxIndex then return end
    local dk = GetKillDedupKey(name)
    count = tonumber(count) or 0
    if dk and count > (dedupCaptureMaxIndex[dk] or 0) then
        dedupCaptureMaxIndex[dk] = count
    end
end

function Overlord.Leaderboard:GetMaxCapturesForDedupName(playerName)
    if not playerName or playerName == "" then return 0 end
    local dk = GetKillDedupKey(playerName)
    if not dk then return tonumber(self.captureCount and self.captureCount[playerName]) or 0 end
    local index = EnsureDedupCaptureMaxIndex(self)
    return tonumber(index[dk]) or 0
end

-- Table de lookup des zoneIds valides.
-- Ne pas construire depuis ZoneDatabase seule : au chargement elle suit le front actif alors que
-- le classement doit accepter tous les IDs de tous les fronts (Registry).
local VALID_ZONE_IDS = {}
local VALID_SPECIAL_OBJECTIVE_IDS = {}
local validGuildKeepRegistrySource
local validOutpostRegistrySource
local function RebuildValidZoneIds()
    wipe(VALID_ZONE_IDS)
    if Overlord.Fronts and Overlord.Fronts.Registry then
        for _, front in pairs(Overlord.Fronts.Registry) do
            for _, zone in ipairs(front.zones or {}) do
                VALID_ZONE_IDS[zone.id] = true
            end
        end
    else
        for _, zone in ipairs(Overlord.ZoneDatabase or {}) do
            VALID_ZONE_IDS[zone.id] = true
        end
    end
end

local function RefreshValidSpecialObjectiveIds()
    local guildKeeps, outposts = Overlord.GuildKeepSites, Overlord.OutpostSites
    if validGuildKeepRegistrySource == guildKeeps
        and validOutpostRegistrySource == outposts then return end
    validGuildKeepRegistrySource, validOutpostRegistrySource = guildKeeps, outposts
    wipe(VALID_SPECIAL_OBJECTIVE_IDS)
    for _, registry in ipairs({ guildKeeps or {}, outposts or {} }) do
        for _, site in pairs(registry) do
            if site and site.id then VALID_SPECIAL_OBJECTIVE_IDS[site.id] = true end
        end
    end
end

local function IsValidLeaderboardZone(zoneId)
    if not zoneId then return false end
    if not next(VALID_ZONE_IDS) then RebuildValidZoneIds() end
    if VALID_ZONE_IDS[zoneId] == true then return true end
    -- GuildKeep.lua et Outpost.lua sont charges apres Leaderboard.lua. Valider leurs
    -- IDs dynamiquement permet de conserver l'objectif unique dans `captures` sans
    -- figer un registre incomplet au chargement.
    RefreshValidSpecialObjectiveIds()
    return VALID_SPECIAL_OBJECTIVE_IDS[zoneId] == true
end

function Overlord.Leaderboard:IsValidCaptureObjectiveId(objectiveId)
    return IsValidLeaderboardZone(objectiveId)
end

RebuildValidZoneIds()

-- Tag locale sync (frfr, ptbr, esmx...) ou legacy 2 lettres (fr, en).
local function sanitizeLocaleTag(tag)
    if type(tag) ~= "string" or tag == "" then return "" end
    tag = tag:lower():match("^([a-z][a-z][a-z]?[a-z]?[a-z]?)$")
    return tag or ""
end

local MAX_GUILD_NAME_LEN = 24

local VALID_SAVED_VARS_POOLS = { global = true }

-- Tags locale sync explicitement EU (front du jour / export : eviter les fantomes cross-region).
local EU_EXPLICIT_LOCALE_TAGS = {
    engb = true, frfr = true, dede = true, eses = true, esmx = true,
    itit = true, ruru = true, ptpt = true, ptbr = true,
    fr = true, de = true, es = true, it = true, ru = true, pt = true,
}

local function normalizeSavedVarsPool(pool)
    if type(pool) ~= "string" or pool == "" then return "" end
    pool = pool:lower()
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if VALID_SAVED_VARS_POOLS[pool] then return pool end
    return ""
end

local function currentSavedVarsPool()
    if Overlord.GetCurrentSavedVarsPool then
        local pool = normalizeSavedVarsPool(Overlord:GetCurrentSavedVarsPool() or "")
        if pool ~= "" then return pool end
    end
    return "global"
end

local function guildKeepLbPoolMatchesCurrent(pool)
    pool = normalizeSavedVarsPool(pool)
    if pool == "" then return false end
    return pool == currentSavedVarsPool()
end

-- Ladder outpost : pool local ou lien FR<->EU (aligne sync OP/OC/LO/LOC).
local function outpostLbPoolMatchesCurrent(pool)
    pool = normalizeSavedVarsPool(pool)
    if pool == "" then return false end
    local localPool = currentSavedVarsPool()
    if localPool == "" then return false end
    if pool == localPool then return true end
    local rp = Overlord.RealmPools
    if rp and rp.AreOutpostCrossPoolsLinked then
        return rp:AreOutpostCrossPoolsLinked(localPool, pool)
    end
    return false
end

local function resolveOutpostLbPoolTag(stPool)
    local pool = normalizeSavedVarsPool(stPool)
    if pool == "" then
        pool = currentSavedVarsPool()
    end
    return pool
end

local function outpostCaptureRowKey(siteKey, guildKey, poolTag)
    siteKey = tostring(siteKey or "")
    guildKey = tostring(guildKey or ""):lower()
    poolTag = resolveOutpostLbPoolTag(poolTag)
    if siteKey == "" or guildKey == "" or poolTag == "" then return "" end
    return siteKey .. ":" .. poolTag .. ":" .. guildKey
end

local function ensureGuildKeepLeaderboardTables(lb)
    if not OverlordDB then return 0 end
    local epoch = lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart() or 0
    OverlordDB.guildKeepSiegeWinAwards = OverlordDB.guildKeepSiegeWinAwards or {}
    OverlordDB.guildKeepTenants = OverlordDB.guildKeepTenants or {}
    OverlordDB.guildKeepOfficialTenants = OverlordDB.guildKeepOfficialTenants or {}
    OverlordDB.guildKeepCutoffSnapshots = OverlordDB.guildKeepCutoffSnapshots or {}
    return epoch
end

-- Royaumes francophones EU mal classes (ex. Vol'jin) : retag eu -> fr avant purge login.
function Overlord.Leaderboard:MigrateGuildKeepDataPoolTag(fromPool, toPool)
    fromPool = normalizeSavedVarsPool(fromPool)
    toPool = normalizeSavedVarsPool(toPool)
    if fromPool == "" or toPool == "" or fromPool == toPool then return false end
    local changed = false
    local function retagPool(row)
        if type(row) ~= "table" then return end
        if normalizeSavedVarsPool(row.pool) == fromPool then
            row.pool = toPool
            changed = true
        end
    end
    for _, row in pairs(self:GetGuildKeepTenantsTable()) do
        retagPool(row)
    end
    for _, row in pairs(self:GetGuildKeepSiegeWinAwardsTable()) do
        retagPool(row)
    end
    if OverlordDB and OverlordDB.guildKeepOfficialTenants then
        for _, row in pairs(OverlordDB.guildKeepOfficialTenants) do
            retagPool(row)
        end
    end
    if OverlordDB and OverlordDB.guildKeepCutoffSnapshots then
        for _, snapshot in pairs(OverlordDB.guildKeepCutoffSnapshots) do
            if type(snapshot) == "table" then
                for _, row in pairs(snapshot) do
                    retagPool(row)
                    if type(row) == "table" and type(row.byBase) == "table" then
                        for _, candidate in pairs(row.byBase) do retagPool(candidate) end
                    end
                end
            end
        end
    end
    if changed then self:MarkDirty() end
    return changed
end

-- Retire du disque les projections de fortins d'un autre pool (changement multi-compte).
function Overlord.Leaderboard:PurgeGuildKeepLbForeignPoolData()
    local changed = false
    local tenants = self:GetGuildKeepTenantsTable()
    for siteKey, t in pairs(tenants) do
        if type(t) == "table" and not guildKeepLbPoolMatchesCurrent(t.pool) then
            tenants[siteKey] = nil
            changed = true
        end
    end
    local awards = self:GetGuildKeepSiegeWinAwardsTable()
    for key, award in pairs(awards) do
        if type(award) == "table" and not guildKeepLbPoolMatchesCurrent(award.pool) then
            awards[key] = nil
            changed = true
        end
    end
    local official = OverlordDB and OverlordDB.guildKeepOfficialTenants
    if type(official) == "table" then
        for siteKey, tenant in pairs(official) do
            if type(tenant) ~= "table" or not guildKeepLbPoolMatchesCurrent(tenant.pool) then
                official[siteKey] = nil
                changed = true
            end
        end
    end
    local snapshots = OverlordDB and OverlordDB.guildKeepCutoffSnapshots
    if type(snapshots) == "table" then
        for dayKey, snapshot in pairs(snapshots) do
            if type(snapshot) ~= "table" then
                snapshots[dayKey] = nil
                changed = true
            else
                for siteKey, row in pairs(snapshot) do
                    if type(row) ~= "table" or not guildKeepLbPoolMatchesCurrent(row.pool) then
                        snapshot[siteKey] = nil
                        changed = true
                    elseif type(row.byBase) == "table" then
                        for baseKey, candidate in pairs(row.byBase) do
                            if type(candidate) ~= "table"
                                or not guildKeepLbPoolMatchesCurrent(candidate.pool) then
                                row.byBase[baseKey] = nil
                                changed = true
                            end
                        end
                    end
                end
                if not next(snapshot) then snapshots[dayKey] = nil end
            end
        end
    end
    if changed then self:MarkDirty() end
    return changed
end

-- Retire les caracteres qui cassent le protocole LK (|:=,)
local function sanitizeGuildName(name)
    if type(name) ~= "string" or name == "" then return "" end
    name = (name:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or "")
    if name == "" then return "" end
    if #name > MAX_GUILD_NAME_LEN then
        name = name:sub(1, MAX_GUILD_NAME_LEN)
    end
    return name
end

-- Cache du roster de guilde du joueur local. Source LOCALE et AUTORITAIRE (donnees serveur
-- Blizzard) pour combler la guilde des contributeurs kills qui sont nos propres coequipiers
-- mais qui farment ailleurs (hors groupe / hors de vue) : le best-effort reseau GR/GY ne les
-- couvre pas toujours, donc leurs kills tombaient du total de guilde. On ne touche a aucun
-- format de payload sync ; l'enrichissement se fait uniquement a la lecture (UI / export).
local LOCAL_GUILD_ROSTER_TTL = 15
local localGuildRosterKeys = nil   -- { [cleDedup] = true } : membres du roster local, indexes par cle dedup (royaume-aware)
local localGuildRosterKeyCount = 0
local localGuildRosterCacheAt = 0
local localGuildRosterCacheFresh = false
local localGuildRosterGuild = ""
local localGuildRosterEventAt = 0
local localGuildRosterRetryBudget = 0
local localGuildRosterGeneration = 0
local localGuildRosterBuild = nil
local localGuildRosterMembershipChangePending = false
local LOCAL_GUILD_ROSTER_ROWS_PER_SLICE = 64
local LOCAL_GUILD_ROSTER_MS_PER_SLICE = 1.25
local LOCAL_GUILD_ROSTER_SELF_ECHO_WINDOW = 3
local localGuildRosterSelfRequestAt = -LOCAL_GUILD_ROSTER_SELF_ECHO_WINDOW

local function invalidateLocalGuildRosterCache()
    -- L'ancien snapshot reste lisible pendant la reconstruction. Seul le commit
    -- atomique publie les nouvelles cles ; une generation plus recente annule
    -- immediatement le worker sans exposer son prefixe partiel.
    localGuildRosterCacheAt = 0
    localGuildRosterCacheFresh = false
    localGuildRosterGeneration = localGuildRosterGeneration + 1
    localGuildRosterBuild = nil
end

-- Mutation O(1) d'une cle nouvelle. Si l'index est froid, la generation suffit
-- a faire abandonner une construction asynchrone concurrente.
NoteDedupCanonicalName = function(lb, name)
    if not name or name == "" then return end
    local dk = GetKillDedupKey(name)
    if not dk then return end
    local previous = dedupCanonicalIndex[dk]
    local canonical = previous and lb:ChooseRicherPlayerName(previous, name) or name
    -- Un compteur qui augmente sous le meme nom ne change pas l'index : ne pas
    -- annuler/starver un worker UI ou login a chaque kill d'un joueur connu.
    if canonical == previous then return end
    dedupCanonicalGeneration = dedupCanonicalGeneration + 1
    dedupCanonicalIndex[dk] = canonical
    if not dedupCanonicalValid then return end
    lb._networkHotCanonicalGeneration = dedupCanonicalGeneration
end

local function refreshLocalGuildRosterCache(onBuildFinished)
    if Overlord.InstanceSuspended or IsInInstance() then return false, false end
    if not IsInGuild or not IsInGuild() then
        local hadRoster = localGuildRosterKeys ~= nil
        localGuildRosterGeneration = localGuildRosterGeneration + 1
        localGuildRosterBuild = nil
        localGuildRosterKeys = nil
        localGuildRosterKeyCount = 0
        localGuildRosterCacheAt = 0
        localGuildRosterCacheFresh = false
        localGuildRosterGuild = ""
        localGuildRosterMembershipChangePending = false
        return true, hadRoster
    end
    local now = GetTime()
    if localGuildRosterCacheFresh and localGuildRosterKeys
        and (now - localGuildRosterCacheAt) < LOCAL_GUILD_ROSTER_TTL then
        local membershipChanged = localGuildRosterMembershipChangePending
        localGuildRosterMembershipChangePending = false
        return true, membershipChanged
    end
    if localGuildRosterBuild then return false, false end
    -- Demande asynchrone du roster (resultat dispo au prochain passage) ; le client throttle en interne.
    if now - localGuildRosterEventAt > 2 then
        local requested = false
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            localGuildRosterSelfRequestAt = now
            requested = pcall(C_GuildInfo.GuildRoster)
        elseif GuildRoster then
            localGuildRosterSelfRequestAt = now
            requested = pcall(GuildRoster)
        end
        -- GuildRoster() peut emettre son evenement avant meme le retour de pcall :
        -- le marqueur est donc pose avant l'appel, puis annule uniquement sur echec.
        if not requested then
            localGuildRosterSelfRequestAt = -LOCAL_GUILD_ROSTER_SELF_ECHO_WINDOW
        end
    end
    local myGuild = sanitizeGuildName((Overlord.SafeGetGuildInfo and Overlord:SafeGetGuildInfo("player")) or "")
    if myGuild == "" then return false, false end
    local num = (GetNumGuildMembers and GetNumGuildMembers()) or 0
    if num <= 0 then return false, false end -- roster pas encore charge : retenter au prochain refresh
    local sync = Overlord.Sync
    local state = {
        generation = localGuildRosterGeneration,
        guild = myGuild,
        num = num,
        index = 1,
        keys = {},
        keyCount = 0,
        previousKeys = localGuildRosterKeys,
        previousCount = localGuildRosterKeyCount,
        previousGuild = localGuildRosterGuild,
        getDedupKey = sync and sync.GetCaptureContributorDedupKey,
        onFinished = onBuildFinished,
    }
    state.membershipChanged = state.previousKeys == nil
        or state.previousGuild:lower() ~= myGuild:lower()
    localGuildRosterBuild = state

    local RunSlice
    RunSlice = function()
        if localGuildRosterBuild ~= state
            or localGuildRosterGeneration ~= state.generation then
            return
        end
        if Overlord.InstanceSuspended or IsInInstance()
            or not IsInGuild or not IsInGuild() then
            localGuildRosterBuild = nil
            return
        end
        local processed = 0
        local startedAt = debugprofilestop and debugprofilestop() or 0
        while state.index <= state.num and processed < LOCAL_GUILD_ROSTER_ROWS_PER_SLICE do
            local ok, rosterName = pcall(GetGuildRosterInfo, state.index)
            state.index = state.index + 1
            processed = processed + 1
            if ok and type(rosterName) == "string" and rosterName ~= "" then
                -- GetGuildRosterInfo renvoie "Nom-Royaume" (royaume connecte inclus). On indexe par
                -- cle dedup (royaume-aware) : un homonyme cross-royaume d'une AUTRE guilde a une cle
                -- differente, donc il ne peut jamais etre confondu avec notre membre.
                local dk = state.getDedupKey
                    and state.getDedupKey(sync, rosterName) or rosterName:lower()
                if dk and dk ~= "" and not state.keys[dk] then
                    state.keys[dk] = true
                    state.keyCount = state.keyCount + 1
                    if state.previousKeys and not state.previousKeys[dk] then
                        state.membershipChanged = true
                    end
                end
            end
            if debugprofilestop
                and (debugprofilestop() - startedAt) >= LOCAL_GUILD_ROSTER_MS_PER_SLICE then
                break
            end
        end
        if state.index <= state.num then
            C_Timer.After(0, RunSlice)
            return
        end
        if state.previousKeys and state.keyCount ~= state.previousCount then
            state.membershipChanged = true
        end
        local currentGuild = sanitizeGuildName(
            (Overlord.SafeGetGuildInfo and Overlord:SafeGetGuildInfo("player")) or "")
        if currentGuild == "" or currentGuild:lower() ~= state.guild:lower() then
            invalidateLocalGuildRosterCache()
            if state.onFinished then state.onFinished() end
            return
        end
        -- Publication atomique : jusque-la les lecteurs ont conserve le snapshot
        -- precedent, jamais la table en construction.
        localGuildRosterBuild = nil
        localGuildRosterKeys = state.keys
        localGuildRosterKeyCount = state.keyCount
        localGuildRosterCacheAt = GetTime()
        localGuildRosterCacheFresh = true
        localGuildRosterGuild = state.guild
        localGuildRosterGeneration = state.generation + 1
        if state.membershipChanged then
            localGuildRosterMembershipChangePending = true
        end
        if state.onFinished then state.onFinished() end
    end
    RunSlice()
    return false, false
end

-- Vrai si le contributeur correspond a un membre du roster local, compare par CLE DEDUP
-- (royaume-aware, cf GetCaptureContributorDedupKey). Un nom court nu prend le royaume LOCAL,
-- donc un membre meme-royaume reste couvert SANS confondre un homonyme d'un autre royaume.
-- L'ancienne heuristique "nom court unique" attribuait a tort la guilde locale a ces homonymes
-- et VOLAIT leurs kills a leur vraie guilde (MDGA / WiH disparaissaient du classement).
local function localGuildRosterMatches(name)
    if not localGuildRosterKeys or not name or name == "" then return false end
    local sync = Overlord.Sync
    local dk = sync and sync.GetCaptureContributorDedupKey and sync:GetCaptureContributorDedupKey(name)
    if not dk or dk == "" then return false end
    return localGuildRosterKeys[dk] == true
end

local function isValidGuildKeepSite(siteKey)
    return siteKey ~= "" and Overlord.GuildKeepSites and Overlord.GuildKeepSites[siteKey] ~= nil
end

local function isGuildKeepWinDayClosed(gk, dayKey)
    if not gk or not gk.GetServerSiegeDayKey then return false end
    dayKey = tostring(dayKey or "")
    if not isGuildKeepSiegeKey(dayKey) then return false end
    local today = gk:GetServerSiegeDayKey()
    if dayKey > today then return false end
    if dayKey == today and gk.IsSiegeWindowClosedForToday
        and not gk:IsSiegeWindowClosedForToday() then
        return false
    end
    return true
end

-- Le reset protocole v8 arme GH sur la campagne courante ; aucun mode historique ne coexiste.
local function isGuildKeepDailyProofCampaignActive(lb)
    if not OverlordDB or not lb or not lb.GetCurrentCampaignStart then return false end
    local campaignStart = math.floor(tonumber(lb:GetCurrentCampaignStart()) or 0)
    local proofEpoch = math.floor(tonumber(OverlordDB.guildKeepDailyProofEpoch) or 0)
    if campaignStart <= 0 or proofEpoch <= 0 then return false end
    if campaignStart == proofEpoch then return true end
    return Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(campaignStart, proofEpoch) or false
end

function Overlord.Leaderboard:IsGuildKeepDailyProofCampaignActive()
    return isGuildKeepDailyProofCampaignActive(self)
end

local function getValidGuildKeepAward(lb, awardKey, award)
    if type(award) ~= "table" or not guildKeepLbPoolMatchesCurrent(award.pool) then return nil end
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey then return nil end
    local siteKey = tostring(award.siteKey or "")
    if not isValidGuildKeepSite(siteKey) then return nil end
    local guild = sanitizeGuildName(award.guild or "")
    local guildKey = guild:lower()
    local faction = award.faction or ""
    local dayKey = tostring(awardKey or ""):match("^([^:]+):") or ""
    local keyedSite = tostring(awardKey or ""):match("^[^:]+:(.+)$") or ""
    if guild == "" or guildKey == "" or (faction ~= "Alliance" and faction ~= "Horde")
        or not isGuildKeepSiegeKey(dayKey) or keyedSite ~= siteKey then
        return nil
    end
    if not isGuildKeepWinDayClosed(gk, dayKey) then return nil end
    local canonical = lb and lb.GetGuildKeepDailyProofForDay
        and lb:GetGuildKeepDailyProofForDay(siteKey, dayKey) or nil
    if not canonical or canonical.status ~= "held"
        or canonical.resultGuildKey ~= guildKey
        or canonical.resultFaction ~= faction then return nil end
    local winTs = math.floor(tonumber(award.winTs) or tonumber(canonical.eventAt) or 0)
    local campaignStart = lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart() or 0
    if winTs <= 0 or not lb:IsTimestampInCurrentCampaign(winTs, campaignStart)
        or winTs > leaderboardServerNow() + 300 then return nil end
    local captureClaimedAt = math.floor(tonumber(canonical.claimedAt) or 0)
    if captureClaimedAt <= 0 then return nil end
    -- Jamais de substitution par winTs : l'heure de score/cloture n'est pas une capture
    -- et ne peut donc ni elire ni rajeunir le tenant du fort.
    local claimedAt = captureClaimedAt
    return {
        siteKey = siteKey,
        guild = guild,
        guildKey = guildKey,
        faction = faction,
        winTs = winTs,
        claimedAt = claimedAt,
        captureClaimedAt = captureClaimedAt,
        pool = award.pool,
    }
end

local function getValidGuildKeepTenantRow(lb, siteKey, row)
    siteKey = tostring(siteKey or "")
    if not isValidGuildKeepSite(siteKey) or type(row) ~= "table" then return nil end
    local guild = sanitizeGuildName(row.guild or "")
    local faction = row.faction or ""
    local claimedAt = math.floor(tonumber(row.claimedAt) or 0)
    if guild == "" or (faction ~= "Alliance" and faction ~= "Horde") or claimedAt <= 0 then
        return nil
    end
    if not guildKeepLbPoolMatchesCurrent(row.pool) then return nil end
    local campaignStart = lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart() or 0
    if not lb:IsTimestampInCurrentCampaign(claimedAt, campaignStart) then return nil end
    if claimedAt > leaderboardServerNow() + 300 then return nil end
    return {
        siteKey = siteKey,
        guild = guild,
        guildKey = guild:lower(),
        faction = faction,
        claimedAt = claimedAt,
        pool = row.pool,
    }
end

local function isValidOutpostSite(siteKey)
    return siteKey and siteKey ~= "" and Overlord.OutpostSites and Overlord.OutpostSites[siteKey] ~= nil
end

local function ensureOutpostLeaderboardTables(lb)
    if not OverlordDB then return end
    OverlordDB.outpostTenants = OverlordDB.outpostTenants or {}
    OverlordDB.outpostCaptureCounts = OverlordDB.outpostCaptureCounts or {}
    -- Les migrations historiques etaient ici et transformaient chaque getter en scan
    -- SavedVariables potentiel. Elles sont maintenant executees par la barriere coopérative
    -- EnsureOutpostLedgerPrepared avant l'activation de Sync.
end

local function getValidOutpostTenantRow(lb, siteKey, row)
    siteKey = tostring(siteKey or "")
    if not isValidOutpostSite(siteKey) or type(row) ~= "table" then return nil end
    local guild = sanitizeGuildName(row.guild or "")
    local faction = row.faction or ""
    local claimedAt = math.floor(tonumber(row.claimedAt) or 0)
    if guild == "" or (faction ~= "Alliance" and faction ~= "Horde") or claimedAt <= 0 then
        return nil
    end
    if not outpostLbPoolMatchesCurrent(resolveOutpostLbPoolTag(row.pool)) then return nil end
    local campaignStart = lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart() or 0
    if not lb:IsTimestampInCurrentCampaign(claimedAt, campaignStart) then return nil end
    return {
        siteKey = siteKey,
        guild = guild,
        guildKey = guild:lower(),
        faction = faction,
        claimedAt = claimedAt,
        pool = row.pool,
    }
end

-- Marque le leaderboard comme modifie (sauvegarde differee, evite ecritures disque a chaque kill).
-- Chemin kills/captures : invalide UNIQUEMENT le cache d'affichage trie, PAS l'index meta.
-- Les kills n'affectent ni la classe, ni la faction, ni la guilde, ni la locale : rescanner
-- l'index meta a chaque kill etait la cause n1 des pics CPU en evenement massif (80v80).
function Overlord.Leaderboard:MarkDirty()
    self.leaderboardDirty = true
    -- Le snapshot anti-perte est couteux sur un gros ladder. Le garder invalide
    -- jusqu'a la prochaine passe periodique evite de rescanner un etat inchange.
    self._snapshotDirty = true
    self._snapshotRevision = (self._snapshotRevision or 0) + 1
    self:InvalidateDisplayCache()
    if Overlord.CharacterStats and Overlord.CharacterStats.RequestRefresh then
        Overlord.CharacterStats:RequestRefresh()
    end
end

function Overlord.Leaderboard:GetTargetRevision()
    return self.targetRevision or 0
end

-- Invalide le cache d'affichage trie (kills/captures). NE touche PAS l'index meta.
function Overlord.Leaderboard:InvalidateDisplayCache()
    -- Conserver la derniere vue publiee pendant la reconstruction asynchrone. L'epoch
    -- la rend obsolete sans imposer un ecran vide (ni un rebuild O(N)) a l'appelant.
    self._displayCacheEpoch = (self._displayCacheEpoch or 0) + 1
end

local function lbClassRank(c)
    if not c or c == "" then return 0 end
    if c == "UNKNOWN" then return 1 end
    return 2
end

-- Effets de bord d'une mutation metadata deja appliquee a un index chaud.
-- L'index reste valide, mais toutes ses vues derivees et sa persistance doivent suivre.
local function markIndexedMetaMutation(self)
    self.leaderboardDirty = true
    self._snapshotDirty = true
    self._snapshotRevision = (self._snapshotRevision or 0) + 1
    -- La vue precedente reste affichable jusqu'a la publication atomique de la suivante.
    self._displayMetaCache = nil
    self._displayCacheEpoch = (self._displayCacheEpoch or 0) + 1
    self._dedupMetaEpoch = (self._dedupMetaEpoch or 0) + 1
    self.targetRevision = (self.targetRevision or 0) + 1
    self.guildFactionCache = nil
    if Overlord.ManualBountyUI and Overlord.ManualBountyUI.RequestRefresh then
        Overlord.ManualBountyUI:RequestRefresh()
    end
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end
end

-- Mise a jour legere de l'index dedup quand seule la classe change (nameplate).
-- Evite MarkMetaDirty + RebuildDedupMetaIndex O(N) a chaque joueur visible.
function Overlord.Leaderboard:PatchDedupMetaClassForPlayer(playerName, normClass)
    if not playerName or playerName == "" or not normClass or normClass == "" then return false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return false end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = (getDK and getDK(sync, playerName)) or playerName
    if not dk or dk == "" then return false end
    -- Chemin chaud nameplate/LK : ne jamais reconstruire ici l'index O(N).
    -- S'il est froid, le setter invalide simplement les caches et la prochaine
    -- lecture lourde explicite le reconstruira une seule fois.
    local index = self._dedupMetaIndex
    if type(index) ~= "table" then return false end
    local b = index[dk:lower()]
    if not b then
        return false
    end
    if lbClassRank(normClass) <= lbClassRank(b.class) then
        return false
    end
    b.class = normClass
    if not playerName:find("-", 1, true) and type(self._dedupLegacyShortMetaIndex) == "table" then
        local legacy = self._dedupLegacyShortMetaIndex[playerName:lower()]
        if legacy and lbClassRank(normClass) > lbClassRank(legacy.class) then
            legacy.class = normClass
        end
    end
    markIndexedMetaMutation(self)
    return true
end

-- Invalide l'index meta (classe/faction/guilde/locale) + le cache d'affichage (couleurs de
-- classe, regroupement faction). A appeler quand playerInfo change vraiment (pas sur un kill).
-- Les sorties autoritaires (export Check PvP, payloads SR, UI) reconstruisent de toute facon
-- via PrepareForHeavyRead / EnsureDisplayCache : un index legerement en retard sur le chemin
-- chaud (demande de guilde/classe opportuniste) est sans impact sur l'etat reseau.
function Overlord.Leaderboard:MarkMetaDirty()
    markIndexedMetaMutation(self)
    self._dedupMetaIndex = nil
    self._dedupLegacyShortMetaIndex = nil
    self._guildFactionVoteIndex = nil
end

-- Priorite d'alias dedup : DETERMINISTE inter-clients. Nom complet > nom court.
-- On NE tient PLUS compte de lb.kills[nameKey] : ce compteur est LOCAL (chaque client a observe un
-- nombre de kills different pour un meme joueur), donc l'inclure dans le rang rendait le tie-break
-- DIVERGENT entre clients ("tout le monde ne voyait pas la meme guilde"). La valeur de guilde
-- elle-meme est departagee par son registre LWW ; ce rang ne sert qu'aux alias equivalents.
-- Le parametre lb est conserve pour la compatibilite des appelants (desormais inutilise).
local function guildAliasRank(nameKey, lb)
    local rank = 0
    if nameKey and nameKey:find("-", 1, true) then
        rank = rank + 1000000
    end
    return rank
end

-- Departage deterministe ET non biaise entre deux noms de guilde a rang dedup egal.
-- L'ancienne regle (nom le plus petit en lexicographique gagne) penalisait STRUCTURELLEMENT
-- les guildes dont le nom trie tard dans l'alphabet (W, X, Y, Z) : "WoW is Hard" perdait
-- quasiment tous ses conflits d'attribution et finissait par disparaitre du classement. On
-- departage donc sur un hash stable du nom (identique sur tous les clients -> la convergence
-- reste garantie), avec repli lexicographique seulement en cas de collision de hash. Aucune
-- guilde n'est ainsi avantagee ou penalisee par son rang alphabetique.
local function guildNameHash(name)
    local h = 0
    for i = 1, #name do
        -- 2147483647 = 2^31-1 (premier) ; h*31 + octet reste < 2^53, donc exact en double.
        h = (h * 31 + name:byte(i)) % 2147483647
    end
    return h
end

local function guildNameTieWins(newGuild, curGuild)
    local a = (newGuild or ""):lower()
    local b = (curGuild or ""):lower()
    local ha, hb = guildNameHash(a), guildNameHash(b)
    if ha ~= hb then return ha < hb end
    return a < b
end

-- Horodatage d'affirmation de guilde (proprietaire K/GI ou hint LK). Fusion deterministe :
-- le timestamp le plus recent gagne (comme max() pour les kills), repli hash si egalite.
local function normalizeGuildAt(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts < 0 then return 0 end
    return ts
end

-- Ordre temporel entre declarations de meme provenance.
-- A date egale, un tombstone gagne, puis le tie-break stable existant departage les guildes.
local function guildLwwValueWins(newGuild, newAt, curGuild, curAt)
    newGuild = sanitizeGuildName(newGuild or "")
    curGuild = sanitizeGuildName(curGuild or "")
    newAt = normalizeGuildAt(newAt)
    curAt = normalizeGuildAt(curAt)
    if curGuild == "" and curAt <= 0 then
        return newGuild ~= "" or newAt > 0
    end
    if newGuild == "" and newAt <= 0 then return false end
    if newAt ~= curAt then return newAt > curAt end
    if newGuild == curGuild then return false end
    if newGuild:lower() == curGuild:lower() then return newGuild < curGuild end
    if newGuild == "" then return true end
    if curGuild == "" then return false end
    return guildNameTieWins(newGuild, curGuild)
end

local function guildRecordWins(newGuild, newAt, newAuth, curGuild, curAt, curAuth)
    if (newAuth == true) ~= (curAuth == true) then return newAuth == true end
    return guildLwwValueWins(newGuild, newAt, curGuild, curAt)
end

-- Les anciennes versions persistaient GetTime() (uptime du client) dans factionAt. Ces petites
-- valeurs ne sont comparables ni entre clients ni apres /reload ; elles valent donc "date inconnue".
local function normalizeMetadataEpoch(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts > 0 and ts < 1000000000 then return 0 end
    return ts
end

-- Mise a jour legere de l'index dedup guilde (evite MarkMetaDirty O(N) sur chaque K/GY).
function Overlord.Leaderboard:PatchDedupMetaGuildForPlayer(playerName, guild, force, preferSync, guildAtOpt)
    guild = sanitizeGuildName(guild)
    if guild == "" then return false end
    local guildAt = normalizeGuildAt(guildAtOpt)
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return false end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = (getDK and getDK(sync, playerName)) or playerName
    if not dk or dk == "" then return false end
    -- Chemin froid uniquement : ne jamais construire l'index global depuis une
    -- arrivee K/GI. S'il n'existe pas encore, la prochaine lecture lourde le
    -- reconstruira depuis playerInfo.
    if type(self._dedupMetaIndex) ~= "table" then return false end
    local key = dk:lower()
    local b = self._dedupMetaIndex[key]
    if not b then
        b = {
            class = "", faction = "", factionAt = -1, factionKey = "",
            locale = "", localeAt = -1, localeKey = "",
            guild = "", guildRank = 0, guildAt = 0,
            pool = "", poolAt = -1, poolKey = "",
            race = "", raceSex = 0, raceAt = -1, raceKey = "",
        }
        self._dedupMetaIndex[key] = b
    end
    local newRank = guildAliasRank(playerName, self)
    if force then
        newRank = newRank + 2000000
    elseif preferSync then
        newRank = newRank + 500000
    end
    local previousGuild = sanitizeGuildName(b.guild or "")
    local previousAt = normalizeGuildAt(b.guildAt)
    local sameValue = previousGuild:lower() == guild:lower()
    if force and b.guildAuth ~= true then
        -- Une observation directe corrige meme un hint relaye plus recent.
    elseif sameValue then
        if guildAt < previousAt then return false end
        if guildAt == previousAt and guild >= previousGuild then return false end
    elseif not guildLwwValueWins(guild, guildAt, previousGuild, previousAt) then
        return false
    end
    b.guild = guild
    b.guildRank = newRank
    b.guildAuth = (sameValue and b.guildAuth == true) or force == true or nil
    b.guildAt = guildAt
    b._guildSeen = true
    -- Le vote de faction est derive des lignes playerInfo, pas de l'alias LWW.
    -- Une mutation de guilde rend cette vue froide; le getter GK demandera la
    -- reconstruction tranchee au lieu de rescanner playerInfo dans le handler.
    self._guildFactionVoteIndex = nil
    markIndexedMetaMutation(self)
    return true
end

-- Timestamp d'affirmation de guilde connu pour un contributeur (dedup meta ou playerInfo).
function Overlord.Leaderboard:GetPlayerGuildAt(playerName)
    if not playerName or playerName == "" then return 0 end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and getDK(sync, playerName)
    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b and normalizeGuildAt(b.guildAt) > 0 then
            return normalizeGuildAt(b.guildAt)
        end
    end
    local info = self:GetPlayerInfo(playerName)
    return normalizeGuildAt(info and info.guildAt)
end

function Overlord.Leaderboard:GetHotPlayerClass(playerName)
    if not playerName or playerName == "" then return "" end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "" end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and getDK(sync, playerName)
    local index = self._dedupMetaIndex
    local bucket = type(index) == "table" and dk and index[dk:lower()] or nil
    local cls = bucket and bucket.class or ""
    if cls ~= "" and cls ~= "UNKNOWN" then return cls end
    local direct = self.playerInfo and self.playerInfo[playerName]
    cls = direct and direct.class or ""
    return (cls ~= "UNKNOWN" and cls) or ""
end

-- Lecture reseau O(1) : utilise l'alias agrege seulement si l'index est deja chaud.
-- Un appelant CR/GR/GY ne doit jamais pouvoir declencher le scan global de playerInfo.
function Overlord.Leaderboard:GetHotPlayerGuildState(playerName)
    if not playerName or playerName == "" then return "", 0, false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "", 0, false end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and getDK(sync, playerName)
    local index = self._dedupMetaIndex
    local bucket = type(index) == "table" and dk and index[dk:lower()] or nil
    if bucket then
        local guild = sanitizeGuildName(bucket.guild or "")
        local guildAt = normalizeGuildAt(bucket.guildAt)
        if guild ~= "" or guildAt > 0 then
            return guild, guildAt, bucket.guildAuth == true
        end
    end
    local direct = self.playerInfo and self.playerInfo[playerName]
    return sanitizeGuildName((direct and direct.guild) or ""),
        normalizeGuildAt(direct and direct.guildAt),
        direct and direct.guildAuth == true or false
end

-- Un relais peut renseigner une guilde inconnue, pas changer une affiliation.
-- Seul le personnage concerne (GI/K) confirme un changement ou un depart.
function Overlord.Leaderboard:ShouldAcceptSyncedGuild(playerName, incomingGuild, incomingGuildAt)
    incomingGuild = sanitizeGuildName(incomingGuild)
    if incomingGuild == "" then return false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return false end
    local existing, _, authoritative = self:GetHotPlayerGuildState(playerName)
    return existing == "" and not authoritative
end

function Overlord.Leaderboard:IsLocalPlayerGuildTarget(playerName)
    if not playerName or playerName == "" then return false end
    if self:IsLocalDisplayName(playerName) then return true end
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName and sync.GetCaptureContributorDedupKey then
        local myFull = sync:GetPlayerFullName()
        if myFull and myFull ~= "" then
            local myK = sync:GetCaptureContributorDedupKey(myFull)
            local dk = sync:GetCaptureContributorDedupKey(playerName)
            if myK and dk and myK:lower() == dk:lower() then return true end
        end
    end
    return false
end

-- Guilde confirmee par K (proprietaire) ou perso local : GY ne doit pas l'ecraser.
function Overlord.Leaderboard:HasAuthoritativeGuildForPlayer(playerName)
    local _, _, authoritative = self:GetHotPlayerGuildState(playerName)
    return authoritative == true
end

-- Index O(n) sur playerInfo : evite de rescanner toutes les cles a chaque GetExportPlayerMeta.
function Overlord.Leaderboard:RebuildDedupMetaIndex(yieldWork, onName)
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local index = {}
    local legacyShortIndex = {}
    local guildFactionVoteIndex = {}

    local function bucketFor(dk)
        if not dk or dk == "" then return nil end
        local k = dk:lower()
        local b = index[k]
        if not b then
            b = {
                class = "",
                level = 0,
                faction = "",
                factionAt = -1,
                factionKey = "",
                locale = "",
                localeAt = -1,
                localeKey = "",
                guild = "",
                guildRank = 0,
                guildAt = 0,
                pool = "",
                poolAt = -1,
                poolKey = "",
                race = "",
                raceSex = 0,
                raceAt = -1,
                raceKey = "",
            }
            index[k] = b
        end
        return b
    end

    for n, inf in pairs(self.playerInfo or {}) do
        if yieldWork then yieldWork() end
        if onName then onName(n) end
        if inf then
            local observedGuild = sanitizeGuildName(inf.guild or "")
            local observedFaction = inf.faction
            if observedGuild ~= ""
                and (observedFaction == "Alliance" or observedFaction == "Horde") then
                local guildVotes = guildFactionVoteIndex[observedGuild:lower()]
                if not guildVotes then
                    guildVotes = { Alliance = 0, Horde = 0 }
                    guildFactionVoteIndex[observedGuild:lower()] = guildVotes
                end
                guildVotes[observedFaction] = guildVotes[observedFaction] + 1
            end
            local dk = (getDK and getDK(sync, n)) or n
            local b = bucketFor(dk)
            if b then
                -- Une declaration directe prime sur un ancien hint relaye.
                local g = sanitizeGuildName(inf.guild or "")
                local ts = normalizeGuildAt(inf.guildAt)
                if g ~= "" or ts > 0 then
                    local r = guildAliasRank(n, self)
                    local candidateAuth = inf.guildAuth == true
                    local previousGuild = sanitizeGuildName(b.guild or "")
                    local previousAt = normalizeGuildAt(b.guildAt)
                    local sameValue = previousGuild:lower() == g:lower()
                    local accept = not b._guildSeen
                        or guildRecordWins(g, ts, candidateAuth,
                            previousGuild, previousAt, b.guildAuth)
                    if accept then
                        b.guild = g
                        b.guildRank = r
                        b.guildAt = ts
                        b.guildAuth = candidateAuth or nil
                        b._guildSeen = true
                    elseif sameValue and ts == previousAt then
                        b.guildAuth = (b.guildAuth == true or candidateAuth) or nil
                        if r > (b.guildRank or 0) then b.guildRank = r end
                        b._guildSeen = true
                    end
                end
                if inf.class and inf.class ~= "" then
                    local ic = inf.class
                    if lbClassRank(ic) > lbClassRank(b.class)
                        or (lbClassRank(ic) == lbClassRank(b.class) and ic < (b.class or "")) then
                        b.class = ic
                    end
                end
                local level = math.floor(tonumber(inf.level) or 0)
                if level > (tonumber(b.level) or 0) then b.level = level end
                if inf.race and inf.race ~= "" then
                    local ts = normalizeMetadataEpoch(inf.raceAt)
                    local sk = tostring(n)
                    local candidateSex = math.floor(tonumber(inf.raceSex) or 0)
                    local currentSex = math.floor(tonumber(b.raceSex) or 0)
                    if candidateSex ~= 2 and candidateSex ~= 3 then candidateSex = 0 end
                    if currentSex ~= 2 and currentSex ~= 3 then currentSex = 0 end
                    if b.race == "" or b.race == nil or ts > (b.raceAt or -1)
                        or (ts == (b.raceAt or -1)
                            and (inf.race < b.race or (inf.race == b.race
                                and (candidateSex > 0 and currentSex == 0
                                    or (candidateSex == currentSex and sk < b.raceKey)
                                    or (candidateSex > 0 and currentSex > 0
                                        and candidateSex < currentSex))))) then
                        b.race = inf.race
                        b.raceSex = candidateSex
                        b.raceAt = ts
                        b.raceKey = sk
                    end
                end
                if inf.faction and inf.faction ~= "" then
                    local ts = normalizeMetadataEpoch(inf.factionAt)
                    local sk = tostring(n)
                    if b.faction == "" or inf.faction < b.faction then
                        b.factionAt = ts
                        b.factionKey = sk
                        b.faction = inf.faction
                    elseif inf.faction == b.faction then
                        if ts > b.factionAt or (ts == b.factionAt and sk > b.factionKey) then
                            b.factionAt = ts
                            b.factionKey = sk
                        end
                    end
                end
                if inf.locale and inf.locale ~= "" then
                    local loc = sanitizeLocaleTag(inf.locale)
                    if loc ~= "" then
                        local ts = normalizeMetadataEpoch(inf.factionAt)
                        local sk = tostring(n)
                        if b.locale == "" or loc < b.locale then
                            b.localeAt = ts
                            b.localeKey = sk
                            b.locale = loc
                        elseif loc == b.locale then
                            if ts > b.localeAt or (ts == b.localeAt and sk > b.localeKey) then
                                b.localeAt = ts
                                b.localeKey = sk
                            end
                        end
                    end
                end
                -- Pool SavedVariables : meme choix deterministe que l'ancien scan par lecture,
                -- mais calcule une seule fois pendant la construction de l'index. Les lignes
                -- sans pool explicite peuvent toujours etre classees par leur locale sync hors US.
                local pool = normalizeSavedVarsPool(inf.pool)
                if pool == "" and inf.locale and inf.locale ~= ""
                    and Overlord.SavedVarsPoolFromLocaleTag
                    and not (GetCurrentRegion and GetCurrentRegion() == 1) then
                    pool = normalizeSavedVarsPool(Overlord:SavedVarsPoolFromLocaleTag(inf.locale) or "")
                end
                if pool ~= "" then
                    local ts = tonumber(inf.factionAt) or 0
                    local sk = tostring(n)
                    if ts > (b.poolAt or -1) or (ts == (b.poolAt or -1) and sk > (b.poolKey or "")) then
                        b.pool = pool
                        b.poolAt = ts
                        b.poolKey = sk
                    end
                end
            end
            -- Compatibilite des tres anciennes SV : une ligne sans royaume pouvait
            -- completer classe/faction d'un nom complet de meme base. Indexer ce cas
            -- une seule fois conserve ce comportement sans scan par ligne exportee.
            if type(n) == "string" and not n:find("-", 1, true) then
                local legacyKey = n:lower()
                local legacy = legacyShortIndex[legacyKey]
                if not legacy then
                    legacy = { class = "", faction = "" }
                    legacyShortIndex[legacyKey] = legacy
                end
                local ic = inf.class or ""
                if lbClassRank(ic) > lbClassRank(legacy.class)
                    or (lbClassRank(ic) == lbClassRank(legacy.class) and ic ~= ""
                        and (legacy.class == "" or ic < legacy.class)) then
                    legacy.class = ic
                end
                local faction = inf.faction or ""
                if faction ~= "" and (legacy.faction == "" or faction < legacy.faction) then
                    legacy.faction = faction
                end
            end
        end
    end

    for _, b in pairs(index) do
        if yieldWork then yieldWork() end
        if b.class ~= "" and b.class ~= "UNKNOWN" then
            local n = self:NormalizeClassTokenForDisplay(b.class)
            b.class = n or ""
        end
    end

    self._dedupMetaIndex = index
    self._dedupLegacyShortMetaIndex = legacyShortIndex
    self._guildFactionVoteIndex = guildFactionVoteIndex
end

function Overlord.Leaderboard:EnsureDedupMetaIndex()
    if type(self._dedupMetaIndex) == "table" then return self._dedupMetaIndex end
    -- Getter/UI/handler hot path : ne jamais transformer une invalidation en
    -- scan global synchrone. La meme preparation tranchee que la barriere login
    -- republie atomiquement metadata + index reseau ; entre-temps les getters
    -- utilisent seulement la ligne exacte de playerInfo.
    if C_Timer and C_Timer.After and self.EnsureNetworkHotIndexesPrepared then
        self:EnsureNetworkHotIndexesPrepared()
    end
    return nil
end

-- Construit les trois index susceptibles d'etre consultes depuis les handlers reseau.
-- `yieldWork` rend cette operation reutilisable par la barriere login sans exposer
-- un index partiel : kill/capture ne sont publies qu'apres la derniere tranche.
function Overlord.Leaderboard:RebuildNetworkHotIndexes(yieldWork)
    local killsSource = self.kills or {}
    local captureSource = self.captureCount or {}
    local capturesSource = self.captures or {}
    local playerInfoSource = self.playerInfo or {}
    local scoreRevision = self._snapshotRevision or 0
    local metaEpoch = self._dedupMetaEpoch or 0
    local canonicalGeneration = dedupCanonicalGeneration
    local killIndex, captureIndex, canonicalIndex = {}, {}, {}
    local function RegisterCanonical(name)
        if not name or name == "" then return end
        local dk = GetKillDedupKey(name)
        if not dk then return end
        local previous = canonicalIndex[dk]
        canonicalIndex[dk] = previous
            and self:ChooseRicherPlayerName(previous, name) or name
    end
    for name, count in pairs(killsSource) do
        if yieldWork then yieldWork() end
        RegisterCanonical(name)
        local dk = GetKillDedupKey(name)
        count = tonumber(count) or 0
        if dk and count > (killIndex[dk] or 0) then killIndex[dk] = count end
    end
    for name, count in pairs(captureSource) do
        if yieldWork then yieldWork() end
        RegisterCanonical(name)
        local dk = GetKillDedupKey(name)
        count = tonumber(count) or 0
        if dk and count > (captureIndex[dk] or 0) then captureIndex[dk] = count end
    end
    for name in pairs(capturesSource) do
        if yieldWork then yieldWork() end
        RegisterCanonical(name)
    end
    self:RebuildDedupMetaIndex(yieldWork, RegisterCanonical)
    if self.kills ~= killsSource or self.captureCount ~= captureSource
        or self.captures ~= capturesSource or self.playerInfo ~= playerInfoSource
        or (self._snapshotRevision or 0) ~= scoreRevision
        or (self._dedupMetaEpoch or 0) ~= metaEpoch
        or dedupCanonicalGeneration ~= canonicalGeneration then
        self._dedupMetaIndex = nil
        self._dedupLegacyShortMetaIndex = nil
        return false
    end
    dedupKillMaxIndex = killIndex
    dedupCaptureMaxIndex = captureIndex
    dedupCanonicalIndex = canonicalIndex
    dedupCanonicalValid = true
    self._networkHotKillsSource = killsSource
    self._networkHotCaptureSource = captureSource
    self._networkHotCapturesSource = capturesSource
    self._networkHotPlayerInfoSource = playerInfoSource
    self._networkHotCanonicalGeneration = canonicalGeneration
    return true
end

-- Barriere login : aucune initialisation Sync avant que les lectures LK/LC/CR/GR
-- aient leurs index complets. Le travail est borne a 64 lignes ou 1,25 ms/frame.
function Overlord.Leaderboard:EnsureNetworkHotIndexesPrepared()
    if dedupKillMaxIndex and dedupCaptureMaxIndex and dedupCanonicalValid
        and self._dedupMetaIndex and self._guildFactionVoteIndex
        and self._networkHotKillsSource == self.kills
        and self._networkHotCaptureSource == self.captureCount
        and self._networkHotCapturesSource == self.captures
        and self._networkHotPlayerInfoSource == self.playerInfo then
        return true
    end
    if self._networkHotIndexPrepFailed then return "blocked" end
    if self._networkHotIndexPrepRetryScheduled then return "waiting" end
    if self._networkHotIndexPrepPending then
        return self._networkHotIndexPrepBackoff and "waiting" or false
    end

    self._networkHotIndexPrepPending = true
    local generation = (tonumber(self._networkHotIndexPrepGeneration) or 0) + 1
    self._networkHotIndexPrepGeneration = generation
    local retryCount = 0
    local worker
    local ResumeWorker
    local function StartWorker()
        if self._networkHotIndexPrepGeneration ~= generation then return end
        self._networkHotIndexPrepBackoff = nil
        local processed = 0
        local started = debugprofilestop and debugprofilestop() or 0
        worker = coroutine.create(function()
            local function YieldWork()
                processed = processed + 1
                local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
                if processed >= 64 or elapsed >= 1.25 then
                    processed = 0
                    coroutine.yield()
                    started = debugprofilestop and debugprofilestop() or 0
                end
            end
            if not self:RebuildNetworkHotIndexes(YieldWork) then
                error("leaderboard bucket changed while preparing network indexes")
            end
        end)
        C_Timer.After(0, ResumeWorker)
    end
    ResumeWorker = function()
        if not self._networkHotIndexPrepPending
            or self._networkHotIndexPrepGeneration ~= generation then return end
        local ok, err = coroutine.resume(worker)
        if not ok then
            retryCount = retryCount + 1
            if retryCount < 3 then
                self._networkHotIndexPrepBackoff = true
                C_Timer.After(retryCount * 5, StartWorker)
            elseif Overlord._deferredModuleInitDone then
                -- Une construction UI en combat peut etre invalidee par des kills
                -- continus. Garder la vue stale et reessayer lentement, sans empoisonner
                -- la barriere de la prochaine session ni boucler chaque frame.
                self._networkHotIndexPrepPending = false
                self._networkHotIndexPrepBackoff = nil
                self._networkHotIndexPrepRetryScheduled = true
                C_Timer.After(5, function()
                    if not Overlord.Leaderboard then return end
                    self._networkHotIndexPrepRetryScheduled = nil
                    self:EnsureNetworkHotIndexesPrepared()
                end)
            else
                self._networkHotIndexPrepPending = false
                self._networkHotIndexPrepBackoff = nil
                self._networkHotIndexPrepFailed = true
                print("|cFFFF4444[Overlord]|r Leaderboard index preparation failed; /reload required: "
                    .. tostring(err))
            end
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        self._networkHotIndexPrepPending = false
        self._networkHotIndexPrepBackoff = nil
        self._networkHotIndexPrepRetryScheduled = nil
        self._networkHotIndexPrepFailed = nil
    end
    StartWorker()
    return false
end

-- Merge dedup throttle (sync SR) : force=true pour export / login / prep lourde.
local LB_MERGE_DEDUP_INTERVAL = 5

function Overlord.Leaderboard:MaybeMergeDuplicateKeysByDedup(force)
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    if not getDK or not self.MergeDuplicateLeaderboardKeysByDedup then
        return false
    end
    local now = GetTime()
    if not force and self._lastMergeDedupAt and (now - self._lastMergeDedupAt) < LB_MERGE_DEDUP_INTERVAL then
        return false
    end
    self:MergeDuplicateLeaderboardKeysByDedup()
    self._lastMergeDedupAt = now
    return true
end

-- Scan raid + merge + index + nameplates (export Check PvP, prep lourde classement).
function Overlord.Leaderboard:PrepareForHeavyRead(forceMerge)
    if self.ScanRaidInfo then
        self:ScanRaidInfo()
    end
    if self.MaybeMergeDuplicateKeysByDedup then
        self:MaybeMergeDuplicateKeysByDedup(forceMerge == true)
    elseif forceMerge and self.MergeDuplicateLeaderboardKeysByDedup then
        self:MergeDuplicateLeaderboardKeysByDedup()
    end
    if self.HealPropagateGuildAcrossDedupAliases then
        self:HealPropagateGuildAcrossDedupAliases()
    end
    self:RebuildDedupMetaIndex()
    if self.EnrichGuildFromLocalRoster then
        self:EnrichGuildFromLocalRoster()
    end
    if self.EnrichMissingClassesFromVisibleUnits then
        self:EnrichMissingClassesFromVisibleUnits()
    end
    if self.EnrichMissingRacesFromVisibleUnits then
        self:EnrichMissingRacesFromVisibleUnits()
    end
    if self.MaybeAwardGuildKeepDailyWins then
        self:MaybeAwardGuildKeepDailyWins()
    end
end

function Overlord.Leaderboard:IsDedupKeyForLocalPlayer(dk)
    if not dk or dk == "" then return false end
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    if getDK and sync.GetPlayerFullName then
        local myFull = sync:GetPlayerFullName()
        if myFull then
            local myK = getDK(sync, myFull)
            if myK and myK:lower() == dk:lower() then return true end
        end
    end
    return false
end

local DISPLAY_KILL_RANK_LIMIT = Overlord.Leaderboard.KILL_RANK_LIMIT
local DISPLAY_CAPTURE_RANK_LIMIT = 25
-- Au-dela de ce nombre de couples (creneau, fortin), la reparation des victoires de
-- fortin est decoupee sur plusieurs images au lieu d'un seul bloc.
Overlord.Leaderboard.GK_AWARD_REPAIR_SYNC_MAX = 16
-- Filet de securite de la passe complete une fois stable (fin de siege et mutations
-- la relancent immediatement).
Overlord.Leaderboard.GK_AWARD_SAFETY_RECHECK_SEC = 600
-- Fortins = priorite la plus basse (sieges toutes les 6 h, peu de joueurs) : une
-- operation au plus toutes les 0,1 s, rien en combat ni en gros event, et les
-- preuves recues sont regroupees 10 s avant reconciliation. Resultats identiques.
Overlord.Leaderboard.GK_WORK_STEP_INTERVAL = 0.1
Overlord.Leaderboard.GK_WORK_POSTPONE_RETRY = 2
Overlord.Leaderboard.GK_RECONCILE_DEBOUNCE_SEC = 10
-- Champ (pas de local) : ecart minimal entre deux builds quand une vue est affichee.
Overlord.Leaderboard.DISPLAY_CACHE_MIN_REBUILD_SEC = 3
local DISPLAY_CACHE_WORK_PER_SLICE = 64
local DISPLAY_CACHE_SLICE_BUDGET_MS = 1

local function displayCacheRowIsBetter(a, b)
    local aCount, bCount = tonumber(a and a.count) or 0, tonumber(b and b.count) or 0
    if aCount ~= bCount then return aCount > bCount end
    return tostring(a and a.name or "") < tostring(b and b.name or "")
end

-- Tas borne dont la racine est la pire ligne retenue. positions ne contient au
-- maximum que K cles : aucune map temporaire proportionnelle au ladder.
local function newDisplayTopK(limit)
    return { limit = limit, rows = {}, positions = {} }
end

local function displayHeapSwap(top, a, b)
    local rows = top.rows
    rows[a], rows[b] = rows[b], rows[a]
    top.positions[rows[a].key] = a
    top.positions[rows[b].key] = b
end

local function displayHeapSiftUp(top, index)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not displayCacheRowIsBetter(top.rows[parent], top.rows[index]) then break end
        displayHeapSwap(top, parent, index)
        index = parent
    end
    return index
end

local function displayHeapSiftDown(top, index)
    local rows = top.rows
    while true do
        local left, right = index * 2, index * 2 + 1
        if left > #rows then return index end
        local worse = left
        if right <= #rows and displayCacheRowIsBetter(rows[left], rows[right]) then
            worse = right
        end
        if not displayCacheRowIsBetter(rows[index], rows[worse]) then return index end
        displayHeapSwap(top, index, worse)
        index = worse
    end
end

local function offerDisplayTopK(lb, top, key, name, count)
    count = tonumber(count) or 0
    if not key or key == "" or not name or name == "" or count <= 0 then return end
    key = tostring(key):lower()
    local position = top.positions[key]
    if position then
        local row = top.rows[position]
        local previousCount, previousName = row.count, row.name
        if count > row.count then row.count = count end
        row.name = lb:ChooseRicherPlayerName(row.name, name)
        if row.count ~= previousCount or row.name ~= previousName then
            position = displayHeapSiftUp(top, position)
            displayHeapSiftDown(top, position)
        end
        return
    end

    if #top.rows < top.limit then
        local candidate = { key = key, name = name, count = count }
        top.rows[#top.rows + 1] = candidate
        top.positions[key] = #top.rows
        displayHeapSiftUp(top, #top.rows)
    else
        local worst = top.rows[1]
        local better = count > worst.count
            or (count == worst.count and tostring(name) < tostring(worst.name or ""))
        if not better then return end
        -- Recycler la ligne evincee : meme sur 10k scores croissants, le build
        -- n'alloue que K lignes de tas au total.
        top.positions[worst.key] = nil
        worst.key, worst.name, worst.count = key, name, count
        top.positions[key] = 1
        displayHeapSiftDown(top, 1)
    end
end

local function displayCacheSourcesMatch(cache, lb)
    return cache
        and lb:IsDisplayCacheScopeCurrent(cache)
        and cache.killSource == lb.kills
        and cache.captureCountSource == lb.captureCount
        and cache.capturesSource == lb.captures
        and cache.playerInfoSource == lb.playerInfo
end

function Overlord.Leaderboard:StartDisplayCacheBuild()
    if self._storageBound ~= true then return false end
    if self._displayCacheBuildPending then return false end
    if not C_Timer or not C_Timer.After then return false end

    local state = {
        epoch = self._displayCacheEpoch or 0,
        campaignStart = self:GetCurrentCampaignStart(),
        pool = Overlord.GetCurrentLeaderboardSavedVarsPool
            and Overlord:GetCurrentLeaderboardSavedVarsPool() or "",
        scoreBucketEpoch = OverlordDB and OverlordDB.leaderboardScoreBucketEpoch,
        metaEpoch = self._dedupMetaEpoch or 0,
        killSource = self.kills,
        captureCountSource = self.captureCount,
        capturesSource = self.captures,
        playerInfoSource = self.playerInfo,
        allianceTop = newDisplayTopK(DISPLAY_CAPTURE_RANK_LIMIT),
        hordeTop = newDisplayTopK(DISPLAY_CAPTURE_RANK_LIMIT),
        sliceWork = 0,
        sliceStarted = 0,
    }
    self._displayCacheBuildPending = state

    local function yieldWork()
        state.sliceWork = state.sliceWork + 1
        local timedOut = debugprofilestop
            and (debugprofilestop() - state.sliceStarted) >= DISPLAY_CACHE_SLICE_BUDGET_MS
        if state.sliceWork >= DISPLAY_CACHE_WORK_PER_SLICE or timedOut then
            coroutine.yield()
        end
    end

    local function forEach(source, visit)
        local cursor = nil
        while true do
            local ok, key, value = pcall(next, source or {}, cursor)
            if not ok then
                state.aborted = true
                return false
            end
            cursor = key
            if key == nil then return true end
            visit(key, value)
            yieldWork()
        end
    end

    local function dedupKey(name)
        local sync = Overlord.Sync
        local getDK = sync and sync.GetCaptureContributorDedupKey
        return (getDK and getDK(sync, name)) or name
    end

    local function canonicalName(name)
        local dk = dedupKey(name)
        return (dk and state.canonicalIndex
            and state.canonicalIndex[tostring(dk):lower()]) or name
    end

    local function indexedMeta(name)
        local dk = dedupKey(name)
        local bucket = dk and state.metaIndex and state.metaIndex[tostring(dk):lower()]
        if bucket then
            return bucket.class or "", bucket.faction or "", bucket.guild or "",
                bucket.race or "", tonumber(bucket.raceSex) or 0,
                bucket.locale or "", bucket.pool or ""
        end
        local shortName = type(name) == "string" and name:match("^([^-]+)") or nil
        if shortName and shortName ~= name then
            local legacy = state.legacyMetaIndex
                and state.legacyMetaIndex[shortName:lower()]
            if legacy then
                return legacy.class or "", legacy.faction or "", "", "", 0, "", ""
            end
        end
        return "", "", "", "", 0, "", ""
    end

    local function captureTopFor(name)
        local _, faction = indexedMeta(name)
        if faction == "Alliance" then return state.allianceTop end
        if faction == "Horde" then return state.hordeTop end
        return nil
    end

    state.worker = coroutine.create(function()
        if not dedupCanonicalValid or not dedupKillMaxIndex then
            -- La barriere login construit cet index en tranches. S'il a ete invalide
            -- ensuite, demander sa preparation asynchrone et conserver la vue stale.
            self:EnsureNetworkHotIndexesPrepared()
            state.waitingCanonical = true
            state.aborted = true
            return
        end
        state.canonicalIndex = dedupCanonicalIndex
        state.canonicalGeneration = dedupCanonicalGeneration
        if not self._dedupMetaIndex then
            self:RebuildDedupMetaIndex(yieldWork)
            if state.metaEpoch ~= (self._dedupMetaEpoch or 0) then
                -- Une mutation pendant le scan invalide la publication partielle de l'index.
                self._dedupMetaIndex = nil
                self._dedupLegacyShortMetaIndex = nil
                state.aborted = true
                return
            end
        end
        state.metaIndex = self._dedupMetaIndex
        state.legacyMetaIndex = self._dedupLegacyShortMetaIndex

        if not forEach(state.captureCountSource, function(name, count)
            local top = captureTopFor(name)
            if top then
                offerDisplayTopK(self, top, dedupKey(name), canonicalName(name), count)
            end
        end) then return end
        if not forEach(state.capturesSource, function(name, zones)
            if not state.captureCountSource[name] and type(zones) == "table" and #zones > 0 then
                local top = captureTopFor(name)
                if top then
                    offerDisplayTopK(self, top, dedupKey(name), canonicalName(name), #zones)
                end
            end
        end) then return end

        -- Le nom canonique est fixe avant l'admission. Si une cle est evincee, K cles
        -- deja meilleures la precedent; elle ne peut revenir que sur un compteur plus
        -- eleve, que la passe unique reoffrira. Le top-K reste donc exact sans seconde
        -- passe ni map de lignes complete.

        local sync = Overlord.Sync
        local function cleanName(name)
            if sync and sync.StripPipeLeakFromContributorName then
                return sync:StripPipeLeakFromContributorName(name)
            end
            return name
        end
        local sortedKills = {}
        local killTop = newDisplayTopK(DISPLAY_KILL_RANK_LIMIT)
        -- L'index contient deja un maximum par joueur, sans doublonner ses alias.
        if not forEach(dedupKillMaxIndex, function(key, count)
            offerDisplayTopK(self, killTop, key,
                cleanName(state.canonicalIndex[key] or key), count)
        end) then return end
        for _, row in ipairs(killTop.rows) do
            sortedKills[#sortedKills + 1] = { name = row.name, kills = row.count }
            yieldWork()
        end
        sortRowsWithYield(sortedKills, function(a, b)
            if a.kills ~= b.kills then return a.kills > b.kills end
            return (a.name or "") < (b.name or "")
        end, yieldWork)

        local function captureRows(top, faction)
            local rows = {}
            for _, row in ipairs(top.rows) do
                local name = cleanName(row.name)
                local class = select(1, indexedMeta(name))
                if type(class) ~= "string" or class == "" then class = "UNKNOWN" end
                rows[#rows + 1] = {
                    name = name, count = row.count, class = class, faction = faction,
                }
                yieldWork()
            end
            table.sort(rows, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return (a.name or "") < (b.name or "")
            end)
            return rows
        end
        local byFaction = {
            Alliance = captureRows(state.allianceTop, "Alliance"),
            Horde = captureRows(state.hordeTop, "Horde"),
        }

        -- Guildes et totaux affiches portent sur les memes joueurs que le reseau.
        local guildBuckets = {}
        local alliKills, hordeKills = 0, 0
        for _, row in ipairs(sortedKills) do
            local name, count = row.name, row.kills
            local _, faction, guild = indexedMeta(name)
            if faction == "Alliance" then alliKills = alliKills + count
            elseif faction == "Horde" then hordeKills = hordeKills + count end
            if guild and guild ~= "" then
                local key = guild:lower()
                local bucket = guildBuckets[key]
                if not bucket then
                    bucket = {
                        guild = guild, kills = 0, faction = "", _facHorde = 0, _facAlliance = 0,
                    }
                    guildBuckets[key] = bucket
                elseif guild < bucket.guild then
                    bucket.guild = guild
                end
                bucket.kills = bucket.kills + count
                if faction == "Horde" then bucket._facHorde = bucket._facHorde + count
                elseif faction == "Alliance" then
                    bucket._facAlliance = bucket._facAlliance + count
                end
            end
            yieldWork()
        end
        local sortedGuilds = {}
        for _, bucket in pairs(guildBuckets) do
            local voted = ""
            if bucket._facHorde > bucket._facAlliance then voted = "Horde"
            elseif bucket._facAlliance > bucket._facHorde then voted = "Alliance" end
            bucket.faction = self:GetGuildDisplayFaction(bucket.guild, voted)
            bucket._facHorde, bucket._facAlliance = nil, nil
            sortedGuilds[#sortedGuilds + 1] = bucket
            yieldWork()
        end
        sortRowsWithYield(sortedGuilds, function(a, b)
            if a.kills ~= b.kills then return a.kills > b.kills end
            return (a.guild or "") < (b.guild or "")
        end, yieldWork)

        if self._dedupMetaIndex ~= state.metaIndex then
            state.aborted = true
            return
        end
        -- Vue meta bornee aux lignes publiees. Reutiliser les valeurs du cache
        -- precedent, mais ne jamais y accumuler tous les anciens top-K au fil du temps.
        local previousDisplayMeta = self._displayMetaCache or { meta = {}, locale = {} }
        local displayMeta = { meta = {}, locale = {} }
        local meta, locale = displayMeta.meta, displayMeta.locale
        local function touch(name)
            if not name or name == "" or meta[name] then return end
            if previousDisplayMeta.meta and previousDisplayMeta.meta[name] then
                meta[name] = previousDisplayMeta.meta[name]
                locale[name] = previousDisplayMeta.locale
                    and previousDisplayMeta.locale[name] or ""
                return
            end
            local class, faction, _, race, raceSex, localeTag, pool = indexedMeta(name)
            -- Le cache roster communaute deja pret peut enrichir la race sans jamais
            -- lancer le scan hors-ligne; sinon le snapshot replique reste le fallback.
            local syncNow = Overlord.Sync
            local community = syncNow and syncNow.GetCommunityMemberCharacterIfFresh
                and syncNow:GetCommunityMemberCharacterIfFresh(name, 30) or nil
            if community and community.race and community.race ~= "" then
                local communitySex = math.floor(tonumber(community.raceSex) or 0)
                if communitySex ~= 2 and communitySex ~= 3 then communitySex = 0 end
                if communitySex == 0 and community.race == race then communitySex = raceSex end
                race, raceSex = community.race, communitySex
            end
            meta[name] = { class, faction, race, raceSex }
            localeTag = sanitizeLocaleTag(localeTag)
            if localeTag ~= "" then
                pool = normalizeSavedVarsPool(pool)
                if pool == "" and Overlord.RealmPools
                    and Overlord.RealmPools.InferPoolTagFromRealmName then
                    pool = normalizeSavedVarsPool(
                        Overlord.RealmPools:InferPoolTagFromRealmName(name) or "")
                end
                if Overlord.FormatLocaleTagForDisplay then
                    locale[name] = Overlord:FormatLocaleTagForDisplay(localeTag, pool)
                else
                    locale[name] = localeTag:upper()
                end
            else
                locale[name] = ""
            end
        end
        for _, row in ipairs(sortedKills) do touch(row.name); yieldWork() end
        for _, row in ipairs(byFaction.Alliance) do touch(row.name); yieldWork() end
        for _, row in ipairs(byFaction.Horde) do touch(row.name); yieldWork() end

        local duplicateShortNames = {}
        for _, row in ipairs(sortedKills) do
            local name = type(row.name) == "string" and row.name or ""
            local short = name:match("^(.-)%-") or name
            if short ~= "" then
                local key = short:lower()
                duplicateShortNames[key] = (duplicateShortNames[key] or 0) + 1
            end
            yieldWork()
        end

        state.result = {
            sortedKills = sortedKills,
            byFaction = byFaction,
            sortedGuilds = sortedGuilds,
            alliKills = alliKills,
            hordeKills = hordeKills,
            meta = meta,
            locale = locale,
            duplicateShortNames = duplicateShortNames,
            epoch = state.epoch,
            campaignStart = state.campaignStart,
            pool = state.pool,
            scoreBucketEpoch = state.scoreBucketEpoch,
            ready = true,
            killSource = state.killSource,
            captureCountSource = state.captureCountSource,
            capturesSource = state.capturesSource,
            playerInfoSource = state.playerInfoSource,
        }
        state.displayMeta = displayMeta
    end)

    local function requestConsumerRefresh()
        local ui = Overlord.LeaderboardUI
        if ui and ui.RequestRefresh then ui:RequestRefresh() end
    end

    local function scheduleCanonicalReadyRefresh()
        if self._displayCanonicalWaitPending then return end
        self._displayCanonicalWaitPending = true
        local attempts = 0
        local function poll()
            if not self._displayCanonicalWaitPending then return end
            attempts = attempts + 1
            if dedupCanonicalValid then
                self._displayCanonicalWaitPending = nil
                requestConsumerRefresh()
                return
            end
            if self._networkHotIndexPrepFailed or attempts >= 120 then
                self._displayCanonicalWaitPending = nil
                return
            end
            C_Timer.After(0.25, poll)
        end
        C_Timer.After(0.25, poll)
    end

    local function runSlice()
        if self._displayCacheBuildPending ~= state then return end
        if self.kills ~= state.killSource or self.captureCount ~= state.captureCountSource
            or self.captures ~= state.capturesSource or self.playerInfo ~= state.playerInfoSource
            or (self._dedupMetaEpoch or 0) ~= state.metaEpoch
            or (state.canonicalGeneration and (not dedupCanonicalValid
                or dedupCanonicalGeneration ~= state.canonicalGeneration)) then
            state.aborted = true
        end
        if state.aborted then
            self._displayCacheBuildPending = nil
            requestConsumerRefresh()
            return
        end
        state.sliceWork = 0
        state.sliceStarted = debugprofilestop and debugprofilestop() or 0
        local ok, err = coroutine.resume(state.worker)
        if not ok then
            self._displayCacheBuildPending = nil
            if geterrorhandler then geterrorhandler()(err) end
            return
        end
        if coroutine.status(state.worker) == "dead" then
            self._displayCacheBuildPending = nil
            if state.waitingCanonical then
                -- Ne pas reconstruire/re-aborter le worker a chaque refresh UI pendant
                -- la prep login : un unique poll borne reveille les consommateurs au commit.
                scheduleCanonicalReadyRefresh()
                return
            end
            local metaUnchanged = (self._dedupMetaEpoch or 0) == state.metaEpoch
                and self._dedupMetaIndex == state.metaIndex
            local canonicalUnchanged = dedupCanonicalValid
                and dedupCanonicalIndex == state.canonicalIndex
                and dedupCanonicalGeneration == state.canonicalGeneration
            -- Une mutation de score peut survenir pendant le build : publier cette vue stale
            -- reste utile, son ancien epoch declenchera simplement la passe de rattrapage.
            local scoreEpochChanged = (self._displayCacheEpoch or 0) ~= state.epoch
            if not state.aborted and metaUnchanged and canonicalUnchanged and state.result
                and displayCacheSourcesMatch(state.result, self) then
                self._displayMetaCache = state.displayMeta
                self._displayCache = state.result
                self:SaveDisplayCache(state.result)
            end
            state.scoreEpochChanged = scoreEpochChanged
            self._displayCacheLastBuildAt = GetTime()
            requestConsumerRefresh()
            return
        end
        C_Timer.After(0, runSlice)
    end

    C_Timer.After(0, runSlice)
    return true
end

-- Retourne immediatement la vue precedente pendant qu'une nouvelle vue est
-- construite en tranches, puis la remplace atomiquement une fois complete.
function Overlord.Leaderboard:EnsureDisplayCache()
    local epoch = self._displayCacheEpoch or 0
    local cache = self._displayCache
    if displayCacheSourcesMatch(cache, self) and cache.epoch == epoch then return cache end
    if not displayCacheSourcesMatch(cache, self) then
        cache = self:RestoreDisplayCache()
        self._displayCache = cache
    end
    -- Sous un flux continu de kills, chaque build publiait une vue deja perimee qui
    -- relancait aussitot le suivant : ~1 ms par image tant que le panneau restait
    -- ouvert. Une vue valide deja affichee est gardee au plus quelques secondes ;
    -- un build differe unique publie ensuite l'etat le plus recent.
    local lastBuildAt = self._displayCacheLastBuildAt
    local minGap = self.DISPLAY_CACHE_MIN_REBUILD_SEC or 3
    if displayCacheSourcesMatch(cache, self) and lastBuildAt
        and GetTime() - lastBuildAt < minGap and C_Timer and C_Timer.After then
        if not self._displayCacheDeferredBuild then
            self._displayCacheDeferredBuild = true
            C_Timer.After(math.max(0, minGap - (GetTime() - lastBuildAt)), function()
                self._displayCacheDeferredBuild = false
                self:StartDisplayCacheBuild()
            end)
        end
        return cache
    end
    self:StartDisplayCacheBuild()
    if displayCacheSourcesMatch(cache, self) then return cache end

    local empty = self._emptyDisplayCache
    if not displayCacheSourcesMatch(empty, self) then
        empty = {
            sortedKills = {}, byFaction = { Alliance = {}, Horde = {} }, sortedGuilds = {},
            alliKills = 0, hordeKills = 0, meta = {}, locale = {}, duplicateShortNames = {},
            ready = false,
            campaignStart = self:GetCurrentCampaignStart(),
            pool = Overlord.GetCurrentLeaderboardSavedVarsPool
                and Overlord:GetCurrentLeaderboardSavedVarsPool() or "",
            scoreBucketEpoch = OverlordDB and OverlordDB.leaderboardScoreBucketEpoch,
            killSource = self.kills, captureCountSource = self.captureCount,
            capturesSource = self.captures, playerInfoSource = self.playerInfo,
        }
        self._emptyDisplayCache = empty
    end
    empty.epoch = epoch
    return empty
end

local function LeaderboardBucketHasScores(bucket)
    if not bucket then return false end
    if bucket.kills and next(bucket.kills) then return true end
    if bucket.captureCount and next(bucket.captureCount) then return true end
    if bucket.bountyTimes and next(bucket.bountyTimes) then return true end
    if bucket.bountyKills and next(bucket.bountyKills) then return true end
    if bucket.captures then
        for _, zones in pairs(bucket.captures) do
            if type(zones) == "table" and #zones > 0 then return true end
        end
    end
    return false
end

local function GetLeaderboardResetEpoch()
    return (OverlordDB and tonumber(OverlordDB.leaderboardResetEpoch)) or 0
end

local function LeaderboardCampaignEpochsMatch(a, b)
    a = math.floor(tonumber(a) or 0)
    b = math.floor(tonumber(b) or 0)
    if a <= 0 or b <= 0 then return false end
    return a == b or (Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(a, b)) or false
end

-- Une sauvegarde locale de scores n'est restaurable que si elle provient d'un bucket
-- atteste. Cela empeche un snapshot/historique ancien simplement re-estampille "courant"
-- de devenir relayable apres sa restauration.
local function GetMatchingLeaderboardScoreBucketEpoch(campaignStart)
    local attestedEpoch = OverlordDB
        and math.floor(tonumber(OverlordDB.leaderboardScoreBucketEpoch) or 0) or 0
    if LeaderboardCampaignEpochsMatch(attestedEpoch, campaignStart) then
        return attestedEpoch
    end
    return 0
end

-- Presentation only: never merge this saved view into scores or relay it.
-- It contains at most 500 kills/guilds and 25 captures per faction, without
-- references to the unbounded live score/metadata tables.
function Overlord.Leaderboard:IsDisplayCacheScopeCurrent(cache)
    if type(cache) ~= "table" or not OverlordDB then return false end
    local campaign = self:GetCurrentCampaignStart()
    local bucket = OverlordDB.leaderboard
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool
        and Overlord:GetCurrentLeaderboardSavedVarsPool() or ""
    return type(bucket) == "table" and cache.pool == pool
        and LeaderboardCampaignEpochsMatch(cache.campaignStart, campaign)
        and LeaderboardCampaignEpochsMatch(bucket.campaignStart, campaign)
        and LeaderboardCampaignEpochsMatch(cache.scoreBucketEpoch, campaign)
        and GetMatchingLeaderboardScoreBucketEpoch(campaign) > 0
end

function Overlord.Leaderboard:SaveDisplayCache(cache)
    if self._storageBound ~= true or not cache.ready or cache.fromSavedCache
        or not self:IsDisplayCacheScopeCurrent(cache) then return false end
    OverlordDB.leaderboardDisplayCache = {
        version = 1, killLimit = self.KILL_RANK_LIMIT,
        campaignStart = cache.campaignStart, scoreBucketEpoch = cache.scoreBucketEpoch,
        pool = cache.pool, at = (GetServerTime and GetServerTime()) or time(),
        sortedKills = cache.sortedKills, sortedGuilds = cache.sortedGuilds,
        byFaction = cache.byFaction, meta = cache.meta, locale = cache.locale,
        alliKills = cache.alliKills, hordeKills = cache.hordeKills,
    }
    return true
end

function Overlord.Leaderboard:RestoreDisplayCache()
    local saved = OverlordDB and OverlordDB.leaderboardDisplayCache
    if type(saved) ~= "table" or saved.version ~= 1
        or saved.killLimit ~= self.KILL_RANK_LIMIT
        or not self:IsDisplayCacheScopeCurrent(saved) then return nil end
    -- Validate only bounded visible rows, never traverse arbitrary saved maps.
    local function text(value, maximum)
        return type(value) == "string" and #value <= maximum
    end
    local function count(value)
        return type(value) == "number" and value >= 0 and value < math.huge
            and value == math.floor(value)
    end
    if type(saved.sortedKills) ~= "table" or #saved.sortedKills > self.KILL_RANK_LIMIT
        or type(saved.sortedGuilds) ~= "table" or #saved.sortedGuilds > self.KILL_RANK_LIMIT
        or type(saved.byFaction) ~= "table" or type(saved.meta) ~= "table"
        or type(saved.locale) ~= "table"
        or not count(saved.alliKills) or not count(saved.hordeKills) then return nil end
    local cache = {
        sortedKills = {}, sortedGuilds = {}, byFaction = { Alliance = {}, Horde = {} },
        meta = {}, locale = {}, duplicateShortNames = {},
        alliKills = saved.alliKills, hordeKills = saved.hordeKills,
        campaignStart = saved.campaignStart, scoreBucketEpoch = saved.scoreBucketEpoch,
        pool = saved.pool, savedAt = saved.at,
        ready = true, fromSavedCache = true, epoch = -1,
        killSource = self.kills, captureCountSource = self.captureCount,
        capturesSource = self.captures, playerInfoSource = self.playerInfo,
    }
    local function copyMeta(name)
        if not text(name, 160) or name == "" then return false end
        local meta, locale = saved.meta[name], saved.locale[name]
        if type(meta) ~= "table" or not text(meta[1], 32) or not text(meta[2], 16)
            or not text(meta[3], 64) or not count(meta[4]) or meta[4] > 3
            or not text(locale, 32) then return false end
        cache.meta[name] = { meta[1], meta[2], meta[3], meta[4] }
        cache.locale[name] = locale
        return true
    end
    for i = 1, #saved.sortedKills do
        local row = saved.sortedKills[i]
        if type(row) ~= "table" or not count(row.kills) or not copyMeta(row.name)
            or (Overlord.Sync and Overlord.Sync.IsDeniedKillContributor
                and Overlord.Sync:IsDeniedKillContributor(row.name)) then return nil end
        cache.sortedKills[i] = { name = row.name, kills = row.kills }
        local short = (row.name:match("^(.-)%-") or row.name):lower()
        cache.duplicateShortNames[short] = (cache.duplicateShortNames[short] or 0) + 1
    end
    for _, faction in ipairs({"Alliance", "Horde"}) do
        local rows = saved.byFaction[faction]
        if type(rows) ~= "table" or #rows > DISPLAY_CAPTURE_RANK_LIMIT then return nil end
        for i = 1, #rows do
            local row = rows[i]
            if type(row) ~= "table" or not count(row.count) or row.faction ~= faction
                or not text(row.class, 32) or not copyMeta(row.name) then return nil end
            cache.byFaction[faction][i] = {
                name = row.name, count = row.count, class = row.class, faction = faction,
            }
        end
    end
    for i = 1, #saved.sortedGuilds do
        local row = saved.sortedGuilds[i]
        if type(row) ~= "table" or not text(row.guild, 128) or not count(row.kills)
            or not text(row.faction, 16) then return nil end
        cache.sortedGuilds[i] = { guild = row.guild, kills = row.kills, faction = row.faction }
    end
    return cache
end

-- Aligne le marqueur de reset LB sur lastResetTimestamp (bucket considere cohérent avec la semaine DB).
local function MarkLeaderboardResetEpochSynced()
    if not OverlordDB then return end
    local ts = tonumber(OverlordDB.lastResetTimestamp) or 0
    if ts <= 0 and Overlord.Leaderboard and Overlord.Leaderboard.GetCurrentCampaignStart then
        ts = Overlord.Leaderboard:GetCurrentCampaignStart()
    end
    if ts > 0 then
        OverlordDB.leaderboardResetEpoch = ts
    end
end

-- Preuve locale distincte de bucket.campaignStart : ce marqueur n'est avance qu'apres un wipe
-- effectif des tables de score. StampCurrentCampaignBucket peut legitiment reparer un stamp sans
-- effacer les scores en milieu de semaine ; il ne doit donc jamais suffire a autoriser K/LK/LC.
local function MarkLeaderboardScoreBucketAttested(bucket)
    if not OverlordDB then return end
    bucket = bucket or OverlordDB.leaderboard
    local epoch = bucket and math.floor(tonumber(bucket.campaignStart) or 0) or 0
    if epoch > 0 then
        OverlordDB.leaderboardScoreBucketEpoch = epoch
    end
end

local function GuildKeepCampaignHasData()
    if not OverlordDB then return false end
    for _, field in ipairs({
        "guildKeepSiegeWinAwards", "guildKeepTenants",
        "guildKeepOfficialTenants", "guildKeepCutoffSnapshots",
    }) do
        local rows = OverlordDB[field]
        if type(rows) == "table" and next(rows) ~= nil then return true end
    end
    for siteKey in pairs(Overlord.GuildKeepSites or {}) do
        local st = type(OverlordDB.guildKeeps) == "table"
            and OverlordDB.guildKeeps[siteKey] or nil
        if type(st) == "table" and (st.status ~= "neutral"
            or (st.ownerGuild or "") ~= ""
            or (tonumber(st.finalAssaultCapturedAt) or 0) > 0
            or (tonumber(st.abortedAssaultAt) or 0) > 0) then return true end
    end
    return false
end

function Overlord.Leaderboard:GuildKeepCampaignNeedsReset(campaignStart)
    if not OverlordDB or not GuildKeepCampaignHasData() then return false end
    campaignStart = math.floor(tonumber(campaignStart) or self:GetCurrentCampaignStart() or 0)
    if campaignStart <= 0 then return false end
    local proofEpoch = math.floor(tonumber(OverlordDB.guildKeepDailyProofEpoch) or 0)
    if proofEpoch > 0 and not LeaderboardCampaignEpochsMatch(proofEpoch, campaignStart) then
        return true
    end
    for siteKey in pairs(Overlord.GuildKeepSites or {}) do
        local st = type(OverlordDB.guildKeeps) == "table"
            and OverlordDB.guildKeeps[siteKey] or nil
        if type(st) == "table" then
            local terminalAt = math.max(
                tonumber(st.claimedAt) or 0,
                tonumber(st.finalAssaultCapturedAt) or 0,
                tonumber(st.abortedAssaultAt) or 0)
            if terminalAt > 0 and terminalAt < campaignStart
                and not LeaderboardCampaignEpochsMatch(terminalAt, campaignStart) then return true end
        end
    end
    return false
end

-- Frontiere GK unique utilisee par le reset normal et les deux recoveries de login.
-- Sans ce helper, un crash entre ResetAll et Leaderboard:Reset pouvait garder un ancien
-- tenant/award tout en estampillant deja le bucket generique sur la nouvelle semaine.
function Overlord.Leaderboard:ResetGuildKeepCampaignData()
    if not OverlordDB then return end
    OverlordDB.guildKeepLbTenure = nil
    OverlordDB.guildKeepLbTenureEpoch = nil
    OverlordDB.guildKeepLbPeaks = nil
    OverlordDB.guildKeepLbPeaksEpoch = nil
    OverlordDB.guildKeepSiegeWinAwards = {}
    OverlordDB.guildKeepTenants = {}
    OverlordDB.guildKeepOfficialTenants = {}
    OverlordDB.guildKeepCutoffSnapshots = {}
    self._guildKeepProofLedgerPrepared = false
    self._guildKeepProofLedgerDirty = true
    self._guildKeepProofLedgerSource = nil
    self._guildKeepProofDaysBySite = nil
    self._guildKeepProofSyncRows = nil
    OverlordDB.dominationBoostPct = { Alliance = 0, Horde = 0 }
    OverlordDB.dominationBoostEvents = nil
    local proofEpoch = math.floor(tonumber(self:GetCurrentCampaignStart()) or 0)
    OverlordDB.guildKeepDailyProofEpoch = proofEpoch > 0 and proofEpoch or nil
    if Overlord.GuildKeep and Overlord.GuildKeep.ResetKeepsForCampaign then
        Overlord.GuildKeep:ResetKeepsForCampaign()
        if Overlord.GuildKeep.InvalidateOfficialKeepTenantCache then
            Overlord.GuildKeep:InvalidateOfficialKeepTenantCache()
        end
    else
        -- Leaderboard.lua est charge avant GuildKeep.lua ; ce fallback reste valide si une
        -- recovery exceptionnelle s'execute pendant l'initialisation des modules.
        OverlordDB.guildKeeps = {}
    end
    if self.InvalidateGuildKeepDailyAwardStable then
        self:InvalidateGuildKeepDailyAwardStable()
    end
end

-- Reset hebdo manque (crash entre lastResetTimestamp et Leaderboard:Reset) : archive puis wipe.
function Overlord.Leaderboard:RecoverMissedWeeklyResetIfNeeded(bucket)
    bucket = bucket or (OverlordDB and OverlordDB.leaderboard)
    if not OverlordDB or (tonumber(OverlordDB.pendingWeeklyResetAt) or 0) > 0 then
        return false
    end
    if not bucket then return false end
    local calendarReset = (Overlord.GetLastResetTimestamp and Overlord:GetLastResetTimestamp()) or 0
    local lastCampaign = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if calendarReset <= 0 or lastCampaign < calendarReset then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    local hasScores = LeaderboardBucketHasScores(bucket)
    local staleGuildKeep = self:GuildKeepCampaignNeedsReset(campaignStart)
    if not hasScores and not staleGuildKeep then return false end
    local bucketStart = tonumber(bucket.campaignStart) or 0
    local resetEpoch = GetLeaderboardResetEpoch()
    local archiveEpoch = nil
    if bucketStart > 0 and campaignStart > 0 and bucketStart < campaignStart then
        local epochGap = math.abs(bucketStart - campaignStart)
        if epochGap < (604800 - 86400) then
            self:StampCurrentCampaignBucket()
            self:Save()
            return false
        end
        archiveEpoch = bucketStart
    elseif resetEpoch > 0 and resetEpoch < lastCampaign then
        -- Bucket deja estampille sur la campagne courante : marqueur seul en retard, pas de wipe.
        if bucketStart > 0 and campaignStart > 0 and bucketStart >= campaignStart then
            MarkLeaderboardResetEpochSynced()
            self:Save()
            return false
        end
        archiveEpoch = lastCampaign - 604800
        if archiveEpoch <= 0 then archiveEpoch = lastCampaign end
    elseif staleGuildKeep then
        archiveEpoch = bucketStart > 0 and bucketStart or (lastCampaign - 604800)
        if archiveEpoch <= 0 then archiveEpoch = lastCampaign end
    else
        return false
    end
    OverlordDB.pendingWeeklyResetAt = campaignStart
    local campaignId = Overlord.TimestampToCampaignId
        and Overlord:TimestampToCampaignId(campaignStart) or 0
    self:Reset(archiveEpoch, campaignStart, campaignId)
    -- Ce chemin repare un reset Core deja applique avant le crash/login.
    self:MarkWeeklyResetCoreSideEffectsApplied(campaignStart)
    return true
end

-- Delegue entierement a Core.lua (Overlord:GetCurrentCampaignStartTs), charge avant Leaderboard.lua
-- dans le .toc : c'est l'UNIQUE source de verite pour l'epoch de campagne courante. Un repli local
-- duplique ici recalculerait la meme chose sans le cas particulier IsLegacyUSResetAhead et pourrait
-- diverger en silence d'un futur refactor de Core.lua.
function Overlord.Leaderboard:GetCurrentCampaignStart()
    return Overlord:GetCurrentCampaignStartTs()
end

-- Les migrations d'epoch regionales peuvent laisser deux debuts equivalant a la meme
-- campagne a moins de la tolerance Core. Une ligne situee entre ces deux ancres ne doit
-- pas etre acceptee par un replica et rejetee par l'autre.
function Overlord.Leaderboard:IsTimestampInCurrentCampaign(ts, campaignStart)
    ts = math.floor(tonumber(ts) or 0)
    campaignStart = math.floor(tonumber(campaignStart) or self:GetCurrentCampaignStart() or 0)
    if ts <= 0 then return false end
    if campaignStart <= 0 or ts >= campaignStart then return true end
    return Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(ts, campaignStart) or false
end

function Overlord.Leaderboard:IsCurrentCampaignBucket(bucket)
    local campaignStart = self:GetCurrentCampaignStart()
    if campaignStart <= 0 then return true end
    bucket = bucket or (OverlordDB and OverlordDB.leaderboard)
    if not bucket then return false end
    local bucketStart = tonumber(bucket.campaignStart) or 0
    -- Bucket legacy sans epoch : estamper sur la campagne courante (scores conserves).
    if bucketStart <= 0 then
        if LeaderboardBucketHasScores(bucket) then
            if (tonumber(OverlordDB and OverlordDB.pendingWeeklyResetAt) or 0) > 0 then
                return false
            end
            local calendarReset = (Overlord.GetLastResetTimestamp and Overlord:GetLastResetTimestamp()) or 0
            local lastCampaign = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
            local resetEpoch = GetLeaderboardResetEpoch()
            if calendarReset > 0 and lastCampaign >= calendarReset
                and resetEpoch > 0 and resetEpoch < lastCampaign then
                return false
            end
            bucket.campaignStart = campaignStart
            if Overlord.TimestampToCampaignId then
                bucket.campaignId = Overlord:TimestampToCampaignId(campaignStart)
            end
        end
        return true
    end
    return bucketStart == campaignStart
        or (Overlord.CampaignEpochsMatch
            and Overlord:CampaignEpochsMatch(bucketStart, campaignStart))
end

-- Garde tres bon marche placee avant chaque mutation de score. Jusqu'a la
-- prochaine frontiere theorique, aucun appel calendrier n'est necessaire.
-- A la frontiere, CheckWeeklyReset effectue le swap + ResetAll dans la meme pile
-- avant que l'ecriture appelante ne reprenne sur le nouveau bucket.
function Overlord.Leaderboard:EnsureWritableCampaignBucket()
    if not OverlordDB then return false end
    local bucket = OverlordDB.leaderboard
    local bucketEpoch = math.floor(tonumber(bucket and bucket.campaignStart) or 0)
    local now = (GetServerTime and GetServerTime()) or time()
    local nextCheck = tonumber(self._nextWritableCampaignCheckAt) or 0
    if bucketEpoch > 0 and now < nextCheck then return true end
    -- Six premiers jours : aucun appel calendrier sur le chemin chaud. La
    -- derniere journee utilise ensuite l'echeance Blizzard exacte (DST inclus).
    if bucketEpoch > 0 and now < (bucketEpoch + 518400) then
        self._nextWritableCampaignCheckAt = bucketEpoch + 518400
        return true
    end

    local campaignStart = math.floor(tonumber(self:GetCurrentCampaignStart()) or 0)
    if campaignStart > 0 and LeaderboardCampaignEpochsMatch(bucketEpoch, campaignStart) then
        local globalReset = Overlord.GetLastResetTimestamp
            and (Overlord:GetLastResetTimestamp() + 604800) or 0
        self._nextWritableCampaignCheckAt = globalReset > now and globalReset or now + 60
        return true
    end
    if Overlord.CheckWeeklyReset then
        local ok = pcall(Overlord.CheckWeeklyReset, Overlord)
        if not ok then return false end
    end
    bucket = OverlordDB.leaderboard
    bucketEpoch = math.floor(tonumber(bucket and bucket.campaignStart) or 0)
    campaignStart = math.floor(tonumber(self:GetCurrentCampaignStart()) or 0)
    local writable = campaignStart <= 0
        or LeaderboardCampaignEpochsMatch(bucketEpoch, campaignStart)
    if writable then
        self._nextWritableCampaignCheckAt = now + 60
    end
    return writable
end

function Overlord.Leaderboard:StampCurrentCampaignBucket(bucket)
    bucket = bucket or (OverlordDB and OverlordDB.leaderboard)
    if not bucket then return end
    local campaignStart = self:GetCurrentCampaignStart()
    if campaignStart <= 0 then return end
    bucket.campaignStart = campaignStart
    if Overlord.TimestampToCampaignId then
        bucket.campaignId = Overlord:TimestampToCampaignId(campaignStart)
    end
    MarkLeaderboardResetEpochSynced()
end

local function ScheduleLocalGuildRosterEnrich(delaySec)
    local lb = Overlord.Leaderboard
    if not lb or lb._guildRosterEnrichPending then return end
    lb._guildRosterEnrichPending = true
    C_Timer.After(math.max(0, tonumber(delaySec) or 0), function()
        local current = Overlord.Leaderboard
        if not current then return end
        current._guildRosterEnrichPending = false
        if current.EnrichGuildForKillRows then
            current:EnrichGuildForKillRows()
        end
        -- Le roster Blizzard peut encore etre vide apres l'evenement. Retenter de facon
        -- bornee sans remettre le scan lourd dans l'ouverture du leaderboard.
        if current._guildRosterKillEnrichPending then
            -- Le worker courant possede deja le restart demande par l'evenement.
            -- Ne pas armer en parallele un retry roster vide a +2.5 s.
            return
        end
        if localGuildRosterBuild then
            -- Le worker tranche possede son rappel de fin ; ne pas lancer un
            -- watchdog concurrent pendant qu'il progresse normalement.
            return
        end
        local now = GetTime()
        if localGuildRosterCacheFresh and localGuildRosterKeys ~= nil
            and (now - localGuildRosterCacheAt) < LOCAL_GUILD_ROSTER_TTL then
            localGuildRosterRetryBudget = 0
        elseif localGuildRosterRetryBudget > 0 and IsInGuild and IsInGuild() then
            localGuildRosterRetryBudget = localGuildRosterRetryBudget - 1
            ScheduleLocalGuildRosterEnrich(2.5)
        end
    end)
end

local LEGACY_SCORE_SANITIZE_VERSION = 5

-- Migration de securite globale, executee avant Sync mais repartie sur plusieurs
-- frames. Les SavedVariables visees peuvent justement etre anormalement grosses :
-- une migration one-shot synchrone recréerait le spike qu'elle tente de reparer.
function Overlord.Leaderboard:EnsureLegacyScoreSanitized()
    if not OverlordDB then return true end
    if (tonumber(OverlordDB.leaderboardScoreSanitizeVersion) or 0)
        >= LEGACY_SCORE_SANITIZE_VERSION then
        return true
    end
    if self._legacyScoreSanitizeFailed then return false end
    if (tonumber(self._legacyScoreSanitizeRetryAt) or 0) > GetTime() then return false end
    if self._legacyScoreSanitizePending then return false end

    local buckets, seenBuckets = {}, {}
    local function AddBucket(bucket)
        if type(bucket) ~= "table" or seenBuckets[bucket] then return end
        seenBuckets[bucket] = true
        buckets[#buckets + 1] = bucket
    end
    AddBucket(OverlordDB.leaderboard)
    for _, bucket in pairs(OverlordDB.leaderboardsByPool or {}) do AddBucket(bucket) end
    -- Le snapshot peut restaurer un score retire du bucket au login suivant.
    AddBucket(OverlordDB.leaderboardSnapshot)

    local captureCeiling = Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING
    local killCeiling = Overlord.PLAUSIBLE_SYNC_KILL_CEILING
    local changed = false
    local processed = 0
    local sliceStartedAt = debugprofilestop and debugprofilestop() or 0
    local function YieldWork()
        processed = processed + 1
        local elapsed = debugprofilestop and (debugprofilestop() - sliceStartedAt) or 0
        if processed >= 64 or elapsed >= 1.25 then
            processed = 0
            coroutine.yield()
            sliceStartedAt = debugprofilestop and debugprofilestop() or 0
        end
    end
    local function IsLocalName(name)
        if not self.IsLocalDisplayName then return false end
        local ok, result = pcall(self.IsLocalDisplayName, self, name)
        return ok and result == true
    end

    -- Supprime sans jamais reprendre next() avec une cle deja effacee : la cle
    -- courante n'est retiree qu'apres avoir obtenu la suivante. Cette propriete
    -- reste vraie lorsque la coroutine cede entre deux tranches.
    local function SanitizeMap(rows, shouldRemove, companion)
        if type(rows) ~= "table" then return end
        local cursor, pendingDelete
        while true do
            local key, value = next(rows, cursor)
            if pendingDelete ~= nil then
                rows[pendingDelete] = nil
                if type(companion) == "table" then companion[pendingDelete] = nil end
                pendingDelete = nil
                changed = true
            end
            if key == nil then break end
            cursor = key
            local ok, remove = pcall(shouldRemove, key, value)
            if ok and remove == true then pendingDelete = key end
            YieldWork()
        end
    end

    self._legacyScoreSanitizePending = true
    local worker = coroutine.create(function()
        for i = 1, #buckets do
            local bucket = buckets[i]
            SanitizeMap(bucket.kills, function(name)
                return Overlord.Sync and Overlord.Sync.IsDeniedKillContributor
                    and Overlord.Sync:IsDeniedKillContributor(name) or false
            end, bucket.bountyKills)
            SanitizeMap(bucket.captureCount, function(name, count)
                return captureCeiling
                    and (tonumber(count) or 0) >= captureCeiling
                    and not IsLocalName(name)
            end, bucket.captures)
            SanitizeMap(bucket.kills, function(name, count)
                return killCeiling
                    and (tonumber(count) or 0) > killCeiling
                    and not IsLocalName(name)
            end)
        end
    end)
    self._legacyScoreSanitizeCoroutine = worker

    local function ResumeWorker()
        if not self._legacyScoreSanitizePending
            or self._legacyScoreSanitizeCoroutine ~= worker then return end
        local ok, err = coroutine.resume(worker)
        if not ok then
            self._legacyScoreSanitizePending = false
            self._legacyScoreSanitizeCoroutine = nil
            self._legacyScoreSanitizeRetryCount =
                (tonumber(self._legacyScoreSanitizeRetryCount) or 0) + 1
            if self._legacyScoreSanitizeRetryCount >= 3 then
                -- Fail closed : ne jamais lancer Sync avec une migration de
                -- securite inachevee, ni boucler chaque frame sur la meme erreur.
                self._legacyScoreSanitizeFailed = true
                print("|cFFFF4444[Overlord]|r Leaderboard migration failed; /reload required: "
                    .. tostring(err))
            else
                self._legacyScoreSanitizeRetryAt = GetTime()
                    + math.min(30, self._legacyScoreSanitizeRetryCount * 5)
                if OverlordDB.config and OverlordDB.config.debug then
                    print("|cFFFF4444[Overlord:dbg]|r Leaderboard sanitize: " .. tostring(err))
                end
            end
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        self._legacyScoreSanitizePending = false
        self._legacyScoreSanitizeCoroutine = nil
        self._legacyScoreSanitizeRetryAt = nil
        self._legacyScoreSanitizeRetryCount = nil
        if changed then
            dedupKillMaxIndex = nil
            dedupCaptureMaxIndex = nil
            self:MarkDirty()
        end
        OverlordDB.leaderboardScoreSanitizeVersion = LEGACY_SCORE_SANITIZE_VERSION
    end
    C_Timer.After(0, ResumeWorker)
    return false
end

-- loadFromDB : false si changement de faction (ne pas charger des donnees d'un autre perso)
function Overlord.Leaderboard:Initialize(loadFromDB)
    if self._legacyScoreSanitizeFailed or self._networkHotIndexPrepFailed then return "blocked" end
    if self._legacyScoreSanitizePending then return false end
    if (tonumber(self._legacyScoreSanitizeRetryAt) or 0) > GetTime() then return "waiting" end
    if self._networkHotIndexPrepPending then
        return self._networkHotIndexPrepBackoff and "waiting" or false
    end
    local resumeAfterNetworkPrep = self._networkHotIndexPrepResumeInitialize == true
    if resumeAfterNetworkPrep then self._networkHotIndexPrepResumeInitialize = nil end
    if not resumeAfterNetworkPrep then
    -- Les tables declarees au chargement ne sont que des placeholders. Tant que
    -- le bucket persistant n'est pas lie, un /reload ne doit jamais les sauver.
    self._storageBound = false
    -- Une passe bornee au debut de session remet le filet anti-perte a niveau.
    -- Les suivantes ne tourneront que si un score ou une meta change reellement.
    self._snapshotDirty = true
    self._snapshotRevision = (self._snapshotRevision or 0) + 1
    local loadedBucket = loadFromDB ~= false and OverlordDB and OverlordDB.leaderboard
    if loadedBucket then
        self.kills = loadedBucket.kills or {}
        self.captures = loadedBucket.captures or {}
        self.captureCount = loadedBucket.captureCount or {}
        self.bountyTimes = loadedBucket.bountyTimes or {}
        self.bountyKills = loadedBucket.bountyKills or {}
        self.playerInfo = loadedBucket.playerInfo or {}
        self._storageBound = true

        -- La migration globale est une barriere : Initialize retourne false et
        -- le runner de login rejoue ce stage jusqu'au commit de la version.
        if self:EnsureLegacyScoreSanitized() == false then return false end
        local pendingReset = (tonumber(OverlordDB.pendingWeeklyResetAt) or 0) > 0
        if not pendingReset then
        if not self:RecoverMissedWeeklyResetIfNeeded(loadedBucket) then
        if not self:IsCurrentCampaignBucket(loadedBucket) then
            local campaignStart = self:GetCurrentCampaignStart()
            local archivingStart = tonumber(loadedBucket.campaignStart) or 0
            if archivingStart <= 0 then
                local lastCampaign = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
                if lastCampaign > 0 then
                    archivingStart = lastCampaign
                end
            end
            local SECONDS_PER_WEEK = 604800
            local isMidWeekStampMigration = false
            if archivingStart > 0 and campaignStart > 0 then
                local epochGap = math.abs(archivingStart - campaignStart)
                -- Ecart < 6 j : migration/stamp incoherent mid-week, pas vrai reset hebdo.
                isMidWeekStampMigration = epochGap < (SECONDS_PER_WEEK - 86400)
            end
            if isMidWeekStampMigration then
                -- Re-estampage sans archive ni wipe : scores de la semaine conserves tels quels.
                self:StampCurrentCampaignBucket()
                self:Save()
            else
                -- Reset hebdo en attente : CheckWeeklyReset archive/wipe (evite double archive au login).
                -- Reset manque (crash) : DB deja sur la nouvelle semaine mais bucket encore ancien.
                local calendarReset = (Overlord.GetLastResetTimestamp and Overlord:GetLastResetTimestamp()) or 0
                local lastCampaign = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
                local dbAlreadyNewWeek = calendarReset > 0 and lastCampaign >= calendarReset
                if dbAlreadyNewWeek and archivingStart > 0 and campaignStart > 0 and archivingStart < campaignStart then
                    OverlordDB.pendingWeeklyResetAt = campaignStart
                    local campaignId = Overlord.TimestampToCampaignId
                        and Overlord:TimestampToCampaignId(campaignStart) or 0
                    self:Reset(archivingStart, campaignStart, campaignId)
                    self:MarkWeeklyResetCoreSideEffectsApplied(campaignStart)
                end
            end
        end
        end
        end
        if not pendingReset and GetLeaderboardResetEpoch() <= 0 and OverlordDB then
            local lastCampaign = tonumber(OverlordDB.lastResetTimestamp) or 0
            local bucketStart = tonumber(loadedBucket.campaignStart) or 0
            local campaignStart = self:GetCurrentCampaignStart()
            if lastCampaign > 0 and campaignStart > 0
                and bucketStart == campaignStart
                and LeaderboardBucketHasScores(loadedBucket) then
                MarkLeaderboardResetEpochSynced()
            end
        end
    else
        self.kills = {}
        self.captures = {}
        self.captureCount = {}
        self.bountyTimes = {}
        self.bountyKills = {}
        self.playerInfo = {}
        self._storageBound = true
    end
    -- Attestation du bucket courant. Un marqueur absent OU reste sur une autre campagne
    -- ne doit jamais laisser un ladder local visible mais impossible a relayer.
    if OverlordDB then
        local bucket = OverlordDB.leaderboard
        -- Premier lancement : publier le bucket vide AVANT l'attestation et les
        -- premieres captures. Sinon Save() pose campaignStart plus tard, sans
        -- preuve, et le login suivant efface les scores pourtant acquis localement.
        -- Ne jamais re-estampiller ici un ancien bucket qui contient des scores.
        if not bucket or ((tonumber(bucket.campaignStart) or 0) <= 0
            and not LeaderboardBucketHasScores(bucket)) then
            self:Save()
            bucket = OverlordDB.leaderboard
        end
        local bucketEpoch = bucket and tonumber(bucket.campaignStart) or 0
        local attestedBucketEpoch = tonumber(OverlordDB.leaderboardScoreBucketEpoch) or 0
        if not LeaderboardCampaignEpochsMatch(attestedBucketEpoch, bucketEpoch) then
            local currentEpoch = self:GetCurrentCampaignStart()
            local lastResetAt = tonumber(OverlordDB.lastLeaderboardResetAt) or 0
            local hasScores = LeaderboardBucketHasScores(bucket)
            local hasPlayerInfo = bucket and type(bucket.playerInfo) == "table"
                and next(bucket.playerInfo) ~= nil
            local hasLocalKillMarks = type(OverlordDB.leaderboardLocalKillKeys) == "table"
                and next(OverlordDB.leaderboardLocalKillKeys) ~= nil
            local hasBucketState = hasScores or hasPlayerInfo or hasLocalKillMarks
            local matches = bucketEpoch > 0 and currentEpoch > 0
                and (bucketEpoch == currentEpoch
                    or (Overlord.CampaignEpochsMatch
                        and Overlord:CampaignEpochsMatch(bucketEpoch, currentEpoch)))
            -- Un bucket non vide n'est conserve que si un reset effectif a ete journalise dans cette
            -- campagne. Sinon on le vide maintenant : le laisser visible mais non relayable creerait
            -- precisement un classement local different, et l'attester restaurerait de vieilles donnees.
            local hasResetProof = not hasBucketState or lastResetAt >= (currentEpoch - 3600)
            if matches and hasResetProof then
                OverlordDB.leaderboardScoreBucketEpoch = math.floor(bucketEpoch)
            elseif matches and hasBucketState then
                self.kills = {}
                self.captures = {}
                self.captureCount = {}
                self.bountyTimes = {}
                self.bountyKills = {}
                self.playerInfo = {}
                OverlordDB.leaderboardLocalKillKeys = {}
                self:StampCurrentCampaignBucket(bucket)
                MarkLeaderboardScoreBucketAttested(bucket)
                self:Save()
            end
        end
    end
    end
    -- Barriere avant les modules Sync : sans elle, le premier LC/CR/GR de la
    -- session pouvait construire un index O(N) dans le handler du message.
    self._networkHotIndexPrepResumeInitialize = true
    local networkPrepared = self:EnsureNetworkHotIndexesPrepared()
    if networkPrepared ~= true then return networkPrepared end
    self._networkHotIndexPrepResumeInitialize = nil
    -- A panel opened before binding may already show the saved preview.
    -- Wake it once the real sources are ready, without waiting for a peer.
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end

    -- Migrations / dedup lourdes : +5 s au login pour ne pas empiler avec UI / sync / carte.
    -- Chaque operation est ensuite executee sur une frame distincte. Les anciennes
    -- passes etaient lineaires pour la plupart, mais leur accumulation dans un seul
    -- callback restait visible comme un pic CPU sur les grosses SavedVariables.
    C_Timer.After(5, function()
        if not Overlord.IsInitialized or not Overlord.Leaderboard then return end
        local lb = Overlord.Leaderboard
        local sync = Overlord.Sync
        local function _dedupKey(n)
            return (sync and sync.GetCaptureContributorDedupKey) and sync:GetCaptureContributorDedupKey(n) or n
        end

        local loginRepairStages = {}
        local heavyRepairFailed = false
        local activeBucket = OverlordDB and OverlordDB.leaderboard
        local function AddLoginRepairStage(callback, isHeavy)
            loginRepairStages[#loginRepairStages + 1] = {
                callback = callback,
                heavy = isHeavy == true,
            }
        end
        local function NewRepairYieldWork()
            local processed = 0
            local started = debugprofilestop and debugprofilestop() or 0
            return function()
                processed = processed + 1
                local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
                if processed >= 64 or elapsed >= 1.25 then
                    coroutine.yield()
                    processed = 0
                    started = debugprofilestop and debugprofilestop() or 0
                end
            end
        end
        local function AddSlicedLoginRepairStage(worker)
            local thread = coroutine.create(worker)
            AddLoginRepairStage(function()
                if activeBucket ~= (OverlordDB and OverlordDB.leaderboard) then
                    heavyRepairFailed = true
                    return true
                end
                local ok, err = coroutine.resume(thread)
                if not ok then error(err) end
                if coroutine.status(thread) ~= "dead" then return false end
                return true
            end, true)
        end
        local needsHeavyRepair = (tonumber(
            activeBucket and activeBucket.repairVersion) or 0) < 3

        if needsHeavyRepair then
        -- Reparations historiques versionnees : les ingress actuels maintiennent
        -- ensuite ces invariants, donc un /reload ne refait plus dix scans globaux.
        AddSlicedLoginRepairStage(function()
            lb:CleanCorruptedCaptures(NewRepairYieldWork())
        end)
        AddSlicedLoginRepairStage(function()
            local yieldWork = NewRepairYieldWork()
            local countedCaptureKeys = {}
            for existingName in pairs(lb.captureCount) do
                yieldWork()
                local dk = _dedupKey(existingName)
                if dk then countedCaptureKeys[dk:lower()] = true end
            end
            for name, zones in pairs(lb.captures) do
                yieldWork()
                if type(zones) == "table" then
                    local dk = _dedupKey(name)
                    local dkKey = dk and dk:lower()
                    if dkKey and not countedCaptureKeys[dkKey] then
                        lb.captureCount[name] = #zones
                        UpdateDedupCaptureMaxIndex(name, #zones)
                        countedCaptureKeys[dkKey] = true
                    end
                end
            end
        end)
        AddSlicedLoginRepairStage(function()
            lb:MergeDuplicateLeaderboardKeysByDedup(NewRepairYieldWork())
        end)
        AddSlicedLoginRepairStage(function()
            local yieldWork = NewRepairYieldWork()
            for name, count in pairs(lb.kills) do
                yieldWork()
                if count and count > 0 and lb:IsLocalDisplayName(name) then
                    lb:MarkLocalKillCredit(name)
                end
            end
        end)
        AddSlicedLoginRepairStage(function()
            lb:HealPropagateClassAcrossDedupAliases(NewRepairYieldWork())
        end)
        AddSlicedLoginRepairStage(function()
            lb:HealPropagateGuildAcrossDedupAliases(NewRepairYieldWork())
        end)
        AddSlicedLoginRepairStage(function()
            lb:NormalizePlayerInfoClassTokens(NewRepairYieldWork())
        end)
        AddSlicedLoginRepairStage(function()
            lb:PropagateLocalFactionToAllKeys(NewRepairYieldWork())
        end)
        -- Les etapes precedentes invalident metadata/canonical. Republier hors
        -- handler, toujours tranche, afin que l'UI suivante reste hot-only.
        AddSlicedLoginRepairStage(function()
            for attempt = 1, 3 do
                if lb:RebuildNetworkHotIndexes(NewRepairYieldWork()) then return end
                coroutine.yield()
            end
            error("leaderboard changed repeatedly while rebuilding repaired indexes")
        end)
        AddLoginRepairStage(function()
            if not heavyRepairFailed and activeBucket == (OverlordDB and OverlordDB.leaderboard) then
                activeBucket.repairVersion = 3
            end
        end)
        end
        AddLoginRepairStage(function()
            local fullName = Overlord.Sync and Overlord.Sync.GetPlayerFullName
                and Overlord.Sync:GetPlayerFullName() or ""
            local _, myClass = UnitClass("player")
            local myFaction = UnitFactionGroup("player")
            if fullName ~= "" then
                lb:ForceUpdateLocalPlayer(fullName, myClass, myFaction)
            end
        end)
        AddLoginRepairStage(function()
            if not Overlord.LifetimeStats then return end
            if Overlord.LifetimeStats.ReconcileWithHistoryAndCampaign then
                Overlord.LifetimeStats:ReconcileWithHistoryAndCampaign()
            end
        end)

        local loginRepairStageIndex = 0
        local RunNextLoginRepairStage
        RunNextLoginRepairStage = function()
            if not Overlord.IsInitialized or not Overlord.Leaderboard then return end
            loginRepairStageIndex = loginRepairStageIndex + 1
            local stage = loginRepairStages[loginRepairStageIndex]
            if not stage then return end
            local ok, completedOrErr = pcall(stage.callback)
            if ok and completedOrErr == false then
                loginRepairStageIndex = loginRepairStageIndex - 1
                C_Timer.After(0, RunNextLoginRepairStage)
                return
            end
            if not ok and stage.heavy then heavyRepairFailed = true end
            if not ok and OverlordDB and OverlordDB.config and OverlordDB.config.debug then
                print("|cFFFF4444[Overlord:dbg]|r Leaderboard login repair: "
                    .. tostring(completedOrErr))
            end
            C_Timer.After(0, RunNextLoginRepairStage)
        end
        RunNextLoginRepairStage()
    end)

    -- GetGuildInfo peut etre vide au ADDON_LOADED : reessayer apres PLAYER_GUILD_UPDATE / login.
    if not self._guildEventFrame then
        self._guildEventFrame = CreateFrame("Frame")
        self._guildEventFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
        self._guildEventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
        self._guildEventFrame:SetScript("OnEvent", function(_, event)
            local lb = Overlord.Leaderboard
            local now = GetTime()
            -- C_GuildInfo.GuildRoster() produit lui-meme cet evenement. Le callback
            -- qui a lance la requete gere deja le resultat et les retries roster vide ;
            -- son echo ne doit surtout pas recreer un entretien periodique idle.
            if event == "GUILD_ROSTER_UPDATE"
                and now - localGuildRosterSelfRequestAt >= 0
                and now - localGuildRosterSelfRequestAt
                    <= LOCAL_GUILD_ROSTER_SELF_ECHO_WINDOW then
                localGuildRosterEventAt = now
                return
            end
            localGuildRosterSelfRequestAt = -LOCAL_GUILD_ROSTER_SELF_ECHO_WINDOW
            -- Un evenement est une invalidation autoritaire, meme pendant le TTL. L'ancien
            -- early-return consommait un join/kick/rename sans jamais programmer de retry.
            local hadCompleteRoster = localGuildRosterKeys ~= nil
            invalidateLocalGuildRosterCache()
            localGuildRosterEventAt = now
            -- Un appel GuildRoster() peut lui-meme emettre GUILD_ROSTER_UPDATE. Ne pas
            -- recharger le budget a chaque echo, sinon le retry pretendument borne devient
            -- une boucle permanente quand l'API continue de renvoyer un roster vide.
            if event == "PLAYER_GUILD_UPDATE" or hadCompleteRoster then
                localGuildRosterRetryBudget = 6
            end
            if event == "PLAYER_GUILD_UPDATE" then
                if lb and lb.UpdateLocalPlayerGuild then lb:UpdateLocalPlayerGuild() end
                if Overlord.Sync and Overlord.Sync.BroadcastGuildIdentity then
                    Overlord.Sync:BroadcastGuildIdentity(true)
                end
            end
            -- Les vrais changements sont debounces. Les seuls rappels ulterieurs
            -- viennent du budget borne quand Blizzard renvoie encore un roster vide.
            ScheduleLocalGuildRosterEnrich(1)
        end)
    end
    localGuildRosterRetryBudget = math.max(localGuildRosterRetryBudget, 6)
    ScheduleLocalGuildRosterEnrich(1)
end

-- Le perso local peut avoir plusieurs cles en base (Nom, Nom-Royaume, encodage) : la faction client s'applique a toutes.
function Overlord.Leaderboard:PropagateLocalFactionToAllKeys(yieldWork)
    local fac = UnitFactionGroup("player")
    if fac ~= "Horde" and fac ~= "Alliance" then return end
    local sync = Overlord.Sync
    local myK = nil
    if sync and sync.GetCaptureContributorDedupKey and sync.GetPlayerFullName then
        local mf = sync:GetPlayerFullName()
        if mf then myK = sync:GetCaptureContributorDedupKey(mf) end
    end
    local function shouldUpdate(name)
        if not name or name == "" then return false end
        if self:IsLocalDisplayName(name) then return true end
        if myK and sync and sync.GetCaptureContributorDedupKey then
            return sync:GetCaptureContributorDedupKey(name) == myK
        end
        return false
    end
    local function touch(t)
        if not t then return end
        for n in pairs(t) do
            if yieldWork then yieldWork() end
            if shouldUpdate(n) then
                self:SetPlayerFaction(n, fac, true)
            end
        end
    end
    touch(self.playerInfo)
    touch(self.kills)
    touch(self.captureCount)
    touch(self.captures)
    self:MarkMetaDirty()
end

-- True si ce nom designe le perso local (secours si cle dedup != cle d'affichage du classement).
-- WoW 12.0.5 : SafeUnitName et SafeStringEquals gerent les secret values
function Overlord.Leaderboard:IsLocalDisplayName(displayName)
    if not displayName or displayName == "" then return false end
    local sync = Overlord.Sync
    local me = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or Overlord:SafeUnitName("player")
    if not me or me == "" then return false end
    if Overlord:SafeStringEquals(displayName, me) then return true end
    if sync and sync.ForeverIdentitiesMatch then
        return sync:ForeverIdentitiesMatch(displayName, me)
    end
    return false
end

-- Lifetime : credit uniquement sur la cle canonique Nom-Royaume (evite double Nom + Nom-Royaume).
function Overlord.Leaderboard:ShouldCreditLocalLifetime(playerName)
    if not playerName or playerName == "" then return false end
    if not self:IsLocalDisplayName(playerName) then return false end
    local sync = Overlord.Sync
    local canonical = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    if not canonical or canonical == "" then return true end
    return playerName == canonical
end

function Overlord.Leaderboard:CreditLocalLifetime(field, amount, playerName)
    if not Overlord.LifetimeStats or not self:ShouldCreditLocalLifetime(playerName) then return false end
    Overlord.LifetimeStats:Increment(field, amount or 1)
    return true
end

-- Sync LK/LC sur alias : realigne le lifetime sur le total LB fusionne (debounce).
function Overlord.Leaderboard:RequestLifetimeFloorSyncForLocal()
    if Overlord.LifetimeStats and Overlord.LifetimeStats.RequestFloorSyncFromLeaderboard then
        Overlord.LifetimeStats:RequestFloorSyncFromLeaderboard()
    end
end

-- Met a jour les infos du joueur local en ecrasant la faction existante.
-- Necessaire car SetPlayerInfo ne met pas a jour si l'entree existe deja,
-- ce qui cause le bug "Horde affiche cote Alliance" apres un swap de faction.
function Overlord.Leaderboard:ForceUpdateLocalPlayer(playerName, class, faction)
    if not playerName then return end
    local prev = self.playerInfo[playerName]
    local previousFaction = prev and prev.faction or ""
    -- factionAt : derniere info connue (swap milieu de campagne + sync)
    local locTag = (Overlord.GetClientLocaleTag and Overlord:GetClientLocaleTag()) or ""
    local identity = Overlord:GetLocalGuildIdentity()
    local guildTag = identity == nil and sanitizeGuildName(prev and prev.guild)
        or sanitizeGuildName(identity)
    local poolTag = normalizeSavedVarsPool(Overlord:GetCurrentSavedVarsPool() or "")
    local guildAt = identity == nil and normalizeGuildAt(prev and prev.guildAt) or time()
    local raceFile = (prev and prev.race) or ""
    local raceSex = (prev and tonumber(prev.raceSex)) or 0
    local raceAt = (prev and tonumber(prev.raceAt)) or 0
    if UnitRace then
        local _, localRace = UnitRace("player")
        local sync = Overlord.Sync
        if sync and sync.NormalizeRaceFileToken then
            localRace = sync:NormalizeRaceFileToken(localRace) or ""
        end
        if localRace and localRace ~= "" then
            raceFile = localRace
            local sex = UnitSex and UnitSex("player") or 0
            raceSex = (sex == 2 or sex == 3) and sex or raceSex
            raceAt = leaderboardServerNow()
        end
    end
    self.playerInfo[playerName] = {
        class = class or "",
        level = Overlord.SafeUnitLevel and (Overlord:SafeUnitLevel("player") or 0) or 0,
        faction = faction or "",
        factionAt = leaderboardServerNow(),
        locale = locTag,
        guild = guildTag,
        guildAuth = identity ~= nil or (prev and prev.guildAuth == true) or nil,
        guildAt = guildAt,
        pool = poolTag,
        race = raceFile,
        raceSex = raceSex,
        raceAt = raceAt,
    }
    if not prev then NoteDedupCanonicalName(self, playerName) end
    if previousFaction ~= (faction or "") and self:IsLocalFactionAlias(playerName) then
        self._localFactionAliasRevision =
            (tonumber(self._localFactionAliasRevision) or 0) + 1
    end
    -- Changement meta (classe/faction/guilde/locale du perso local) : invalider l'index meta.
    self:MarkMetaDirty()
end

function Overlord.Leaderboard:Save()
    if not OverlordDB or self._storageBound ~= true then return end
    if not OverlordDB.leaderboard then OverlordDB.leaderboard = {} end
    OverlordDB.leaderboard.kills = self.kills
    OverlordDB.leaderboard.captures = self.captures
    OverlordDB.leaderboard.captureCount = self.captureCount
    OverlordDB.leaderboard.bountyTimes = self.bountyTimes
    OverlordDB.leaderboard.bountyKills = self.bountyKills
    OverlordDB.leaderboard.playerInfo = self.playerInfo
    self:StampCurrentCampaignBucket(OverlordDB.leaderboard)
    if Overlord.GetCurrentLeaderboardSavedVarsPool then
        local pool = Overlord:GetCurrentLeaderboardSavedVarsPool()
        if pool and pool ~= "" then
            OverlordDB.leaderboardsByPool = OverlordDB.leaderboardsByPool or {}
            OverlordDB.leaderboardsByPool[pool] = OverlordDB.leaderboard
        end
    end
    self.leaderboardDirty = false
end

-- Priorite classe lors des fusions : vide < UNKNOWN < vraie classe (aligne GetExportPlayerMeta).
local function lbPickMergedClass(classCanonical, classOther)
    local function rank(c)
        if not c or c == "" then return 0 end
        if c == "UNKNOWN" then return 1 end
        return 2
    end
    local cT, cO = classCanonical or "", classOther or ""
    local rT, rO = rank(cT), rank(cO)
    if rO > rT then return cO end
    if rT > rO then return cT end
    if cT == "" then return cO end
    if cO == "" then return cT end
    return (cO < cT) and cO or cT
end

-- Fusionne playerInfo[otherKey] dans playerInfo[bestKey] (dedup leaderboard).
local function lbMergeTwoPlayerInfoRows(self, bestKey, otherKey)
    local iT = self.playerInfo[bestKey] or {}
    local iO = self.playerInfo[otherKey] or {}
    if not next(iO) and not next(iT) then return end
    local fT = normalizeMetadataEpoch(iT.factionAt)
    local fO = normalizeMetadataEpoch(iO.factionAt)
    local factionT = (iT.faction == "Alliance" or iT.faction == "Horde") and iT.faction or ""
    local factionO = (iO.faction == "Alliance" or iO.faction == "Horde") and iO.faction or ""
    local mergedFaction = factionT
    if mergedFaction == "" or (factionO ~= "" and factionO < mergedFaction) then
        mergedFaction = factionO
    end
    local mergedFactionAt = math.max(fT, fO)
    local localeT = sanitizeLocaleTag((iT.locale and tostring(iT.locale)) or "")
    local localeO = sanitizeLocaleTag((iO.locale and tostring(iO.locale)) or "")
    local mergedLocale = localeT
    if mergedLocale == "" or (localeO ~= "" and localeO < mergedLocale) then
        mergedLocale = localeO
    end
    local mergedClass = lbPickMergedClass(iT.class, iO.class)
    local mergedLevel = math.max(math.floor(tonumber(iT.level) or 0),
        math.floor(tonumber(iO.level) or 0))
    local raceT, raceO = iT.race or "", iO.race or ""
    local raceAtT = normalizeMetadataEpoch(iT.raceAt)
    local raceAtO = normalizeMetadataEpoch(iO.raceAt)
    local raceSexT, raceSexO = math.floor(tonumber(iT.raceSex) or 0),
        math.floor(tonumber(iO.raceSex) or 0)
    if raceSexT ~= 2 and raceSexT ~= 3 then raceSexT = 0 end
    if raceSexO ~= 2 and raceSexO ~= 3 then raceSexO = 0 end
    local takeOtherRace = raceO ~= "" and (raceT == "" or raceAtO > raceAtT
        or (raceAtO == raceAtT and (raceO < raceT or (raceO == raceT
            and raceSexO > 0 and (raceSexT == 0 or raceSexO < raceSexT)))))
    local mergedRace = takeOtherRace and raceO or raceT
    local mergedRaceAt = takeOtherRace and raceAtO or raceAtT
    local mergedRaceSex = takeOtherRace and raceSexO or raceSexT
    local gT = sanitizeGuildName(iT.guild or "")
    local gO = sanitizeGuildName(iO.guild or "")
    local gAtT, gAtO = normalizeGuildAt(iT.guildAt), normalizeGuildAt(iO.guildAt)
    local mergedGuild, mergedGuildAuth, mergedGuildAt
    if guildRecordWins(gO, gAtO, iO.guildAuth, gT, gAtT, iT.guildAuth) then
        mergedGuild = gO
        mergedGuildAt = gAtO
        mergedGuildAuth = iO.guildAuth == true or nil
    else
        mergedGuild = gT
        mergedGuildAt = gAtT
        mergedGuildAuth = iT.guildAuth == true or nil
    end
    local pT = normalizeSavedVarsPool(iT.pool)
    local pO = normalizeSavedVarsPool(iO.pool)
    local mergedPool = ""
    if pO ~= "" and pT ~= "" then
        mergedPool = (pO < pT) and pO or pT
    elseif pO ~= "" then
        mergedPool = pO
    else
        mergedPool = pT
    end
    if mergedPool == "" and mergedLocale ~= "" and Overlord.SavedVarsPoolFromLocaleTag then
        mergedPool = normalizeSavedVarsPool(Overlord:SavedVarsPoolFromLocaleTag(mergedLocale) or "")
    end
    self.playerInfo[bestKey] = {
        class = mergedClass,
        level = mergedLevel,
        faction = mergedFaction,
        factionAt = mergedFactionAt,
        locale = mergedLocale or "",
        guild = mergedGuild,
        guildAuth = mergedGuildAuth or nil,
        guildAt = mergedGuildAt,
        pool = mergedPool,
        race = mergedRace or "",
        raceSex = mergedRaceSex,
        raceAt = mergedRaceAt,
    }
    self.playerInfo[otherKey] = nil
end

-- Deplace captureCount / captures / kills / playerInfo des cles dans aliases vers canonical.
local function lbCollapseKeysIntoCanonical(self, canonical, aliases, yieldWork)
    for n in pairs(aliases) do
        if yieldWork then yieldWork() end
        if n ~= canonical then
            if self.captureCount and self.captureCount[n] then
                self.captureCount[canonical] = math.max(self.captureCount[canonical] or 0, self.captureCount[n] or 0)
                self.captureCount[n] = nil
                UpdateDedupCaptureMaxIndex(canonical, self.captureCount[canonical])
            end
            if self.captures and self.captures[n] then
                if not self.captures[canonical] then self.captures[canonical] = {} end
                local seen = {}
                for _, z in ipairs(self.captures[canonical]) do
                    if yieldWork then yieldWork() end
                    seen[z] = true
                end
                for _, z in ipairs(self.captures[n]) do
                    if yieldWork then yieldWork() end
                    if not seen[z] then
                        self.captures[canonical][#self.captures[canonical] + 1] = z
                        seen[z] = true
                    end
                end
                self.captures[n] = nil
            end
            if self.kills and self.kills[n] then
                self.kills[canonical] = math.max(self.kills[canonical] or 0, self.kills[n] or 0)
                self.kills[n] = nil
                UpdateDedupKillMaxIndex(canonical, self.kills[canonical])
            end
            if self.bountyTimes and self.bountyTimes[n] then
                self.bountyTimes[canonical] = math.max(self.bountyTimes[canonical] or 0, self.bountyTimes[n] or 0)
                self.bountyTimes[n] = nil
            end
            if self.bountyKills and self.bountyKills[n] then
                self.bountyKills[canonical] = math.max(self.bountyKills[canonical] or 0, self.bountyKills[n] or 0)
                self.bountyKills[n] = nil
            end
            if self.playerInfo and (self.playerInfo[n] or self.playerInfo[canonical]) then
                lbMergeTwoPlayerInfoRows(self, canonical, n)
            end
            self:MarkMetaDirty()
        end
    end
end

function Overlord.Leaderboard:SetPlayerLocale(playerName, localeTag)
    if not playerName or playerName == "" then return end
    local tag = sanitizeLocaleTag(localeTag)
    if tag == "" then return end
    local prev = self.playerInfo[playerName]
    if not prev then
        self.playerInfo[playerName] = {
            class = "", faction = "", factionAt = 0, locale = tag, guild = "", pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
    else
        -- Locale inchangee : ne pas invalider l'index meta (appele sur quasi chaque K/LK/LC,
        -- une invalidation systematique force des rebuilds O(N) en rafale d'event massif).
        if prev.locale == tag and prev.pool ~= nil then return end
        -- Deux affirmations contradictoires valides doivent produire le meme resultat
        -- quel que soit leur ordre d'arrivee.
        if prev.locale and prev.locale ~= "" and prev.locale ~= tag and tag >= prev.locale then return end
        prev.locale = tag
        if prev.pool == nil then prev.pool = "" end
    end
    self:MarkMetaDirty()
end

-- Guilde connue (sync K/GY autoritaire, perso local via GetGuildInfo).
function Overlord.Leaderboard:SetPlayerGuild(playerName, guild, fromSync, authoritative, guildAtOpt, verifiedOwner)
    if not playerName or playerName == "" then return end
    guild = sanitizeGuildName(guild)
    if guild == "" then return end
    local sync = Overlord.Sync
    if fromSync and authoritative and not verifiedOwner and sync and sync.IsObservedPlayerGuild
        and not sync:IsObservedPlayerGuild(playerName, guild) then
        return
    end
    local incAt = normalizeGuildAt(guildAtOpt)
    if fromSync and incAt > leaderboardServerNow() + 300 then return end
    if authoritative and incAt <= 0 then
        incAt = time()
    end
    -- Bootstrap local : perso uniquement (les tiers passent par K/GY/GI reseau).
    if not fromSync and not authoritative then
        if not self:IsLocalPlayerGuildTarget(playerName) then return end
    end
    if fromSync and not authoritative and self.ShouldAcceptSyncedGuild then
        if not self:ShouldAcceptSyncedGuild(playerName, guild, incAt) then return end
    end
    local prev = self.playerInfo[playerName]
    local prevGuild = sanitizeGuildName((prev and prev.guild) or "")
    local prevAt = normalizeGuildAt(prev and prev.guildAt)
    if fromSync and authoritative and prev and prevGuild == "" and prevAt > 0
        and incAt > 0 and incAt <= prevAt then
        return
    end
    if prevGuild == guild then
        if authoritative then
            if not prev then
                self.playerInfo[playerName] = {
                    class = "", faction = "", factionAt = 0, locale = "",
                    guild = guild, guildAuth = true, guildAt = incAt, pool = "",
                }
                NoteDedupCanonicalName(self, playerName)
            else
                if not prev.guildAuth or incAt >= prevAt then prev.guildAt = incAt end
                prev.guildAuth = true
            end
            if self:PatchDedupMetaGuildForPlayer(playerName, guild, true, false, incAt) then
                return
            end
            self:MarkMetaDirty()
            return
        end
        if incAt <= prevAt then return end
    end
    if prev and prevGuild ~= guild
        and not ((authoritative or prevGuild == "") and not prev.guildAuth)
        and not guildLwwValueWins(guild, incAt, prevGuild, prevAt) then
        return
    end
    if not prev then
        self.playerInfo[playerName] = {
            class = "", faction = "", factionAt = 0, locale = "",
            guild = guild, guildAuth = authoritative == true, guildAt = incAt, pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
    else
        prev.guild = guild
        prev.guildAuth = authoritative == true or nil
        prev.guildAt = incAt
        if prev.pool == nil then prev.pool = "" end
    end
    local force = authoritative == true
    local preferSync = fromSync and not force
    if self:PatchDedupMetaGuildForPlayer(playerName, guild, force, preferSync, incAt) then
        return
    end
    self:MarkMetaDirty()
end

-- Tombstone de guilde emis par le proprietaire (GI avec champ vide). Evite que les
-- autres clients conservent indefiniment une ancienne guilde apres un depart/kick.
function Overlord.Leaderboard:ClearPlayerGuild(playerName, fromSync, verifiedOwner, guildAtOpt)
    if not playerName or playerName == "" then return false end
    if fromSync and not verifiedOwner then return false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName) or playerName
    end
    local clearedAt = normalizeGuildAt(guildAtOpt)
    if fromSync and clearedAt > leaderboardServerNow() + 300 then return false end
    if clearedAt <= 0 then clearedAt = time() end
    local targetKey = sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(playerName)
    local row = self.playerInfo and self.playerInfo[playerName]
    local previousAt = normalizeGuildAt(type(row) == "table" and row.guildAt)
    local changed = type(row) ~= "table"
        or (row.guild or "") ~= "" or row.guildAuth or clearedAt ~= previousAt
    if type(row) ~= "table" then
        self.playerInfo[playerName] = {
            class = "", faction = "", factionAt = 0, locale = "", guild = "",
            guildAt = clearedAt, guildAuth = true, pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
    elseif row.guildAuth == true and clearedAt < previousAt then
        return false
    else
        if (row.guild or "") == "" and row.guildAuth == true and clearedAt == previousAt then
            return false
        end
        row.guild = ""
        row.guildAuth = true
        row.guildAt = clearedAt
        if row.pool == nil then row.pool = "" end
    end

    local hotIndex = self._dedupMetaIndex
    if type(hotIndex) == "table" and targetKey and targetKey ~= "" then
        local bucketKey = targetKey:lower()
        local bucket = hotIndex[bucketKey]
        if not bucket then
            bucket = {
                class = "", faction = "", factionAt = -1, factionKey = "",
                locale = "", localeAt = -1, localeKey = "",
                guild = "", guildRank = 0, guildAt = 0,
                pool = "", poolAt = -1, poolKey = "",
                race = "", raceSex = 0, raceAt = -1, raceKey = "",
            }
            hotIndex[bucketKey] = bucket
        end
        local bucketGuild = sanitizeGuildName(bucket.guild or "")
        local bucketAt = normalizeGuildAt(bucket.guildAt)
        if bucket.guildAuth ~= true or (bucketGuild == "" and clearedAt >= bucketAt)
            or guildLwwValueWins("", clearedAt, bucketGuild, bucketAt) then
            bucket.guild = ""
            bucket.guildAuth = true
            bucket.guildAt = clearedAt
            bucket._guildSeen = true
        end
        markIndexedMetaMutation(self)
    else
        self:MarkMetaDirty()
    end
    return changed
end

function Overlord.Leaderboard:UpdateLocalPlayerGuild()
    if Overlord.InstanceSuspended or not Overlord.SafeGetGuildInfo then return end
    local identity = Overlord:GetLocalGuildIdentity()
    if identity == nil then return end
    local guild = sanitizeGuildName(identity)
    local sync = Overlord.Sync
    local fullName = (sync and sync.GetPlayerFullName and sync:GetPlayerFullName()) or nil
    if not fullName or fullName == "" then return end
    if guild == "" then
        -- Debarrasser guilde obsolete apres demission / kick (evite guilde fantome au ladder).
        local previousGuild = self:GetHotPlayerGuildState(fullName)
        if previousGuild ~= "" then
            self:ClearPlayerGuild(fullName, false, true, time())
        end
        return
    end
    -- Appele a chaque kill local (RegisterKill) : si la guilde connue est deja celle-ci et deja
    -- authoritative, SetPlayerGuild ne ferait que rebumper guildAt a l'instant present et invalider
    -- le cache d'affichage (PatchDedupMetaGuildForPlayer + MarkMetaDirty) sans rien changer de reel.
    -- Skip complet dans ce cas : meme resultat final, juste sans le travail meta/cache repete.
    local prevInfo = self.playerInfo[fullName]
    if prevInfo and prevInfo.guild == guild and prevInfo.guildAuth == true then
        return
    end
    self:SetPlayerGuild(fullName, guild, false, true, time())
end

-- Sync K/LK et combat : ne pas faire confiance a UNKNOWN comme classe reelle (voir entete GetExportPlayerMeta).
function Overlord.Leaderboard:SetPlayerInfo(playerName, class, faction, localeOpt, fromSync)
    if not playerName or not class then return end
    if faction ~= nil and faction ~= "" and faction ~= "Alliance" and faction ~= "Horde" then
        faction = nil
    end
    local normClass = self:NormalizeClassTokenForDisplay(class)
    -- Si la classe est invalide ou UNKNOWN, on garde "" (vide) pour permettre l'enrichissement futur
    if not normClass or normClass == "UNKNOWN" then
        normClass = ""
    end
    class = normClass
    local prev = self.playerInfo[playerName]
    if fromSync and prev then
        local prevClass = self:NormalizeClassTokenForDisplay(prev.class)
        if class ~= "" and prevClass and prevClass ~= "UNKNOWN" and prevClass ~= class then
            -- Merge pur : la meme paire de claims donne le meme resultat sur chaque receveur.
            if class >= prevClass then
                class = prevClass
            end
        end
        local prevFaction = prev.faction or ""
        if faction and faction ~= "" and prevFaction ~= "" and prevFaction ~= faction then
            if faction >= prevFaction then
                faction = prevFaction
            end
        end
    end
    -- Ne jamais ecraser une vraie classe par une classe vide/inconnue
    if class == "" and prev and prev.class and prev.class ~= "" and prev.class ~= "UNKNOWN" then
        class = prev.class
    end
    local newFaction
    if faction and faction ~= "" then
        newFaction = faction
    else
        newFaction = (prev and prev.faction) or ""
    end
    local factionAt = (prev and prev.factionAt) or 0
    if faction and faction ~= "" then
        factionAt = leaderboardServerNow()
    end
    local locKeep = ""
    if localeOpt and localeOpt ~= "" then
        locKeep = sanitizeLocaleTag(localeOpt)
    end
    if locKeep == "" and prev and prev.locale then
        locKeep = prev.locale
    end
    local guildKeep = sanitizeGuildName((prev and prev.guild) or "")
    local guildAtKeep = normalizeGuildAt(prev and prev.guildAt)
    local prevAuth = prev and prev.guildAuth == true
    local poolKeep = normalizeSavedVarsPool((prev and prev.pool) or "")
    -- Locale seule : inference pool uniquement hors Americas (cf. SavedVarsPoolFromLocaleTag).
    if poolKeep == "" and locKeep ~= "" and Overlord.SavedVarsPoolFromLocaleTag then
        local inferred = Overlord:SavedVarsPoolFromLocaleTag(locKeep)
        if inferred then poolKeep = normalizeSavedVarsPool(inferred) end
    end
    self.playerInfo[playerName] = {
        class = class,
        level = (prev and math.floor(tonumber(prev.level) or 0)) or 0,
        faction = newFaction,
        factionAt = factionAt,
        locale = locKeep,
        guild = guildKeep,
        guildAuth = prevAuth or nil,
        guildAt = guildAtKeep,
        pool = poolKeep,
        race = (prev and prev.race) or "",
        raceSex = (prev and tonumber(prev.raceSex)) or 0,
        raceAt = (prev and tonumber(prev.raceAt)) or 0,
    }
    if not prev then NoteDedupCanonicalName(self, playerName) end
    if ((not prev and newFaction ~= "")
        or (prev and prev.faction ~= newFaction))
        and self:IsLocalFactionAlias(playerName) then
        self._localFactionAliasRevision =
            (tonumber(self._localFactionAliasRevision) or 0) + 1
    end
    -- Invalider l'index meta uniquement si une valeur meta a reellement change (evite de
    -- rescanner sur un re-ajout de nameplate ou un LK qui reapporte la meme classe/faction).
    if not prev or prev.class ~= class or prev.faction ~= newFaction or prev.locale ~= locKeep
        or prev.guild ~= guildKeep or (prev.guildAuth == true) ~= prevAuth then
        self:MarkMetaDirty()
    end
end

-- Normalise le token de classe (trim + majuscules ASCII) et valide contre la liste Sync.
-- Sinon RAID_CLASS_COLORS[class] echoue (casse / espaces) -> UI grise "inconnue".
function Overlord.Leaderboard:NormalizeClassTokenForDisplay(class)
    if not class or type(class) ~= "string" then return nil end
    class = (class:match("^%s*(.-)%s*$") or class)
    if class == "" then return nil end
    class = string.upper(class)
    if class == "UNKNOWN" then return "UNKNOWN" end
    local sync = Overlord.Sync
    if sync and sync.IsValidCaptureClassToken then
        if sync:IsValidCaptureClassToken(class) then return class end
        return nil
    end
    return class
end

-- Migration : tokens de classe mal formates en SavedVariables (casse, espaces, import).
function Overlord.Leaderboard:NormalizePlayerInfoClassTokens(yieldWork)
    for _, info in pairs(self.playerInfo or {}) do
        if yieldWork then yieldWork() end
        if info and info.class and info.class ~= "" then
            local c = self:NormalizeClassTokenForDisplay(info.class)
            if c and c ~= "UNKNOWN" then
                if c ~= info.class then
                    info.class = c
                    self:MarkMetaDirty()
                end
            else
                -- Classe invalide : vider pour permettre l'enrichissement futur
                info.class = ""
                self:MarkMetaDirty()
            end
        end
    end
end

-- Migration 3.2.14 : nettoie les UNKNOWN persistes en DB
-- UNKNOWN etait ecrit a tort dans les anciennes versions, bloquant l'enrichissement
function Overlord.Leaderboard:CleanupUnknownClassesInDB()
    local cleaned = 0
    for name, info in pairs(self.playerInfo or {}) do
        if info and info.class == "UNKNOWN" then
            info.class = ""
            cleaned = cleaned + 1
        end
    end
    if cleaned > 0 then
        self:MarkMetaDirty()
    end
end

function Overlord.Leaderboard:IsLocalFactionAlias(playerName)
    if not playerName or playerName == "" then return false end
    if self:IsLocalDisplayName(playerName) then return true end
    local sync = Overlord.Sync
    if not sync or not sync.GetCaptureContributorDedupKey
        or not sync.GetPlayerFullName then return false end
    local localName = sync:GetPlayerFullName()
    if not localName or localName == "" then return false end
    return sync:GetCaptureContributorDedupKey(playerName)
        == sync:GetCaptureContributorDedupKey(localName)
end

-- Met a jour uniquement la faction d'un joueur (ex. a la reception d'un message C, on connait la faction du capteur).
-- forceLocal est reserve au service de changement de faction et reste revalide
-- contre l'identite/dedup locale; aucun paquet reseau ne contourne le join.
function Overlord.Leaderboard:SetPlayerFaction(playerName, faction, forceLocal)
    if not playerName or not faction or faction == "" then return end
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    local prev = self.playerInfo[playerName]
    local authoritativeLocal = forceLocal == true and self:IsLocalFactionAlias(playerName)
    if not authoritativeLocal and prev and prev.faction
        and prev.faction ~= "" and prev.faction ~= faction then
        -- Faction n'a pas de timestamp wire dans LK/LC : join lexical stable, jamais une
        -- observation propre au receveur qui ferait diverger deux copies du meme paquet.
        if faction >= prev.faction then return end
    end
    if not prev then
        self.playerInfo[playerName] = {
            class = "", faction = faction, factionAt = leaderboardServerNow(), locale = "", guild = "", pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
        -- Nouvelle entree meta : invalider l'index.
        self:MarkMetaDirty()
        if self:IsLocalFactionAlias(playerName) then
            self._localFactionAliasRevision =
                (tonumber(self._localFactionAliasRevision) or 0) + 1
        end
    else
        local changed = (prev.faction ~= faction)
        -- Une repetition de la meme valeur n'apporte aucune information au join lexical.
        -- Ne pas rebattre factionAt : ce champ departage aussi le pool dedup et rendrait
        -- un index chaud obsolete sur chaque LC/nameplate identique.
        if not changed then return end
        prev.faction = faction
        prev.factionAt = leaderboardServerNow()
        if prev.locale == nil then prev.locale = "" end
        if prev.guild == nil then prev.guild = "" end
        if prev.pool == nil then prev.pool = "" end
        self:MarkMetaDirty()
        if self:IsLocalFactionAlias(playerName) then
            self._localFactionAliasRevision =
                (tonumber(self._localFactionAliasRevision) or 0) + 1
        end
    end
end

-- Classe depuis la sync LC (token anglais, ex. WARRIOR) : complete l'export Check PvP et l'UI captures.
-- Bug fix : refuse d'ecrire "UNKNOWN" en DB - c'est un placeholder d'affichage, pas une vraie classe.
-- Ecrire UNKNOWN bloquait indefiniment l'enrichissement via nameplates / vraie sync.
function Overlord.Leaderboard:SetPlayerClassFromSync(playerName, classToken)
    if not playerName or not classToken or classToken == "" then return end
    local norm = self:NormalizeClassTokenForDisplay(classToken)
    if not norm then return end
    -- Ne jamais persister UNKNOWN en DB : ca bloque l'enrichissement
    if norm == "UNKNOWN" then return end
    local prev = self.playerInfo[playerName]
    if prev and prev.class and prev.class ~= "" and prev.class ~= "UNKNOWN"
        and prev.class ~= norm then
        if norm >= prev.class then return end
    end
    if not prev then
        self.playerInfo[playerName] = {
            class = norm, faction = "", factionAt = 0, locale = "", guild = "", pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
        self:MarkMetaDirty()
    else
        local changed = (prev.class ~= norm)
        prev.class = norm
        if prev.locale == nil then prev.locale = "" end
        if prev.guild == nil then prev.guild = "" end
        if prev.pool == nil then prev.pool = "" end
        if changed then
            if not self:PatchDedupMetaClassForPlayer(playerName, norm) then
                self:MarkMetaDirty()
            end
        end
    end
end

-- Efface UNKNOWN persiste quand un message sync n'apporte pas de classe (ex. LK avec champ vide).
-- Sinon le placeholder bloque indefiniment l'enrichissement (nameplates / vraie sync).
function Overlord.Leaderboard:AllowClassRefetchFromSync(playerName)
    if not playerName or playerName == "" then return end
    local row = self.playerInfo and self.playerInfo[playerName]
    if row and row.class == "UNKNOWN" then
        row.class = ""
        self:MarkMetaDirty()
    end
end

-- Niveau d'eligibilite du ladder kills. Il est conserve dans playerInfo afin
-- que les snapshots LK ne puissent relayer que des lignes deja attestees 90.
function Overlord.Leaderboard:SetPlayerLevel(playerName, level)
    if not playerName or playerName == "" then return false end
    level = math.floor(tonumber(level) or 0)
    if level < 1 or level > 90 then return false end
    local prev = self.playerInfo[playerName]
    if not prev then
        self.playerInfo[playerName] = {
            class = "", level = level, faction = "", factionAt = 0,
            locale = "", guild = "", pool = "",
        }
        NoteDedupCanonicalName(self, playerName)
    else
        if math.floor(tonumber(prev.level) or 0) == level then return true end
        prev.level = level
    end
    self:MarkMetaDirty()
    return true
end

-- Fusion atomique des metadonnees portees par une ligne LK. Les anciens setters
-- invalidaient puis reconstruisaient l'index dedup plusieurs fois par paquet
-- (niveau -> classe -> guilde), soit O(lignes * playerInfo) pendant une rafale.
-- Cette voie n'effectue aucun scan global et n'invalide qu'une fois.
function Overlord.Leaderboard:MergeLeaderboardKillMetadata(
    playerName, level, classToken, faction, localeTag, guild, guildAt, hasGuildRegister,
    raceFile, raceSexOpt, raceAtOpt, guildAuthoritative)
    if not playerName or playerName == "" then return false end
    level = math.floor(tonumber(level) or 0)
    if level < 1 or level > 90 then return false end

    local row = self.playerInfo[playerName]
    local changed = false
    local factionChanged = false
    if type(row) ~= "table" then
        row = {
            class = "", level = 0, faction = "", factionAt = 0,
            locale = "", guild = "", guildAt = 0, pool = "",
        }
        self.playerInfo[playerName] = row
        NoteDedupCanonicalName(self, playerName)
        changed = true
    end

    if math.floor(tonumber(row.level) or 0) ~= level then
        row.level = level
        changed = true
    end

    local normClass = self:NormalizeClassTokenForDisplay(classToken)
    if normClass and normClass ~= "UNKNOWN" then
        local currentClass = row.class or ""
        if currentClass == "" or currentClass == "UNKNOWN"
            or currentClass == normClass or normClass < currentClass then
            if currentClass ~= normClass then
                row.class = normClass
                changed = true
            end
        end
    end

    if faction == "Alliance" or faction == "Horde" then
        local currentFaction = row.faction or ""
        if currentFaction == "" or currentFaction == faction or guildAuthoritative == true then
            if currentFaction ~= faction then
                row.faction = faction
                row.factionAt = leaderboardServerNow()
                changed = true
                factionChanged = true
            end
        end
    end

    local locale = sanitizeLocaleTag(localeTag)
    if locale ~= "" then
        local currentLocale = row.locale or ""
        if currentLocale == "" or currentLocale == locale or locale < currentLocale then
            if currentLocale ~= locale then
                row.locale = locale
                changed = true
            end
        end
    end

    if hasGuildRegister and (guildAuthoritative == true
        or (sanitizeGuildName(row.guild or "") == "" and row.guildAuth ~= true
            and sanitizeGuildName(guild or "") ~= "")) then
        local incomingGuild = sanitizeGuildName(guild or "")
        local incomingAt = normalizeGuildAt(guildAt)
        if incomingAt <= leaderboardServerNow() + 300 then
            local currentGuild = sanitizeGuildName(row.guild or "")
            local currentAt = normalizeGuildAt(row.guildAt)
            local wins = false
            if row.guildAuth ~= true
                and (guildAuthoritative == true or currentGuild == "") then
                wins = true
            elseif incomingGuild:lower() == currentGuild:lower() then
                wins = incomingAt > currentAt
                    or (incomingAt == currentAt and incomingGuild < currentGuild)
            else
                wins = guildLwwValueWins(incomingGuild, incomingAt, currentGuild, currentAt)
            end
            if wins then
                row.guild = incomingGuild
                row.guildAt = incomingAt
                row.guildAuth = guildAuthoritative == true or nil
                changed = true
            elseif incomingGuild:lower() == currentGuild:lower()
                and guildAuthoritative == true and row.guildAuth ~= true then
                row.guildAuth = true
                changed = true
            end
        end
    end

    local sync = Overlord.Sync
    local normRace = sync and sync.NormalizeRaceFileToken
        and sync:NormalizeRaceFileToken(raceFile)
    if normRace and normRace ~= "" then
        local sex = math.floor(tonumber(raceSexOpt) or 0)
        if sex ~= 2 and sex ~= 3 then sex = 0 end
        local observedAt = math.floor(tonumber(raceAtOpt) or 0)
        local now = leaderboardServerNow()
        if observedAt < 0 or observedAt > now + 300 then observedAt = 0 end
        local previousRace = row.race or ""
        local previousSex = math.floor(tonumber(row.raceSex) or 0)
        local previousAt = math.floor(tonumber(row.raceAt) or 0)
        local wins = previousRace == ""
        if previousRace == normRace then
            wins = observedAt > previousAt
                or (observedAt == previousAt and sex > 0
                    and (previousSex == 0 or sex < previousSex))
        elseif previousRace ~= "" then
            wins = observedAt > previousAt
                or (observedAt == previousAt and normRace < previousRace)
        end
        if wins then
            row.race = normRace
            if sex > 0 or previousSex == 0 then row.raceSex = sex end
            row.raceAt = observedAt
            changed = true
        end
    end

    if row.class == nil then row.class = "" end
    if row.faction == nil then row.faction = "" end
    if row.factionAt == nil then row.factionAt = 0 end
    if row.locale == nil then row.locale = "" end
    if row.guild == nil then row.guild = "" end
    if row.guildAt == nil then row.guildAt = 0 end
    if row.race == nil then row.race = "" end
    if row.raceSex == nil then row.raceSex = 0 end
    if row.raceAt == nil then row.raceAt = 0 end
    if row.pool == nil then row.pool = "" end
    if factionChanged and self:IsLocalFactionAlias(playerName) then
        self._localFactionAliasRevision =
            (tonumber(self._localFactionAliasRevision) or 0) + 1
    end
    if changed then self:MarkMetaDirty() end
    return changed
end

-- Fusion O(1) d'une declaration de guilde emise par le proprietaire du personnage.
-- Elle partage les memes regles LWW que K/LK, sans passer par les alias ni l'index
-- dedup global : un heartbeat GI ne peut donc plus provoquer un scan de tout le ladder.
function Overlord.Leaderboard:MergeOwnedGuildMetadata(playerName, guild, guildAt)
    if not playerName or playerName == "" then return false end
    local incomingGuild = sanitizeGuildName(guild or "")
    local incomingAt = normalizeGuildAt(guildAt)
    if incomingAt > leaderboardServerNow() + 300 then return false end
    local row = self.playerInfo[playerName]
    if type(row) ~= "table" then
        row = {
            class = "", level = 0, faction = "", factionAt = 0,
            locale = "", guild = "", guildAt = 0, pool = "",
            race = "", raceSex = 0, raceAt = 0,
        }
        self.playerInfo[playerName] = row
        NoteDedupCanonicalName(self, playerName)
    end
    local currentGuild = sanitizeGuildName(row.guild or "")
    local currentAt = normalizeGuildAt(row.guildAt)
    local sameGuild = incomingGuild:lower() == currentGuild:lower()
    local valueWins
    if row.guildAuth ~= true then
        valueWins = true
    elseif sameGuild then
        valueWins = incomingAt > currentAt
            or (incomingAt == currentAt and incomingGuild < currentGuild)
    else
        valueWins = guildLwwValueWins(incomingGuild, incomingAt, currentGuild, currentAt)
    end
    local authorityOnly = sameGuild and row.guildAuth ~= true
    if not valueWins and not authorityOnly then return false end
    if valueWins then
        row.guild = incomingGuild
        row.guildAt = incomingAt
    end
    row.guildAuth = true
    self:MarkMetaDirty()
    return true
end

function Overlord.Leaderboard:GetExportPlayerLevel(playerName)
    if not playerName or playerName == "" then return 0 end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return 0 end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName
    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b then return math.floor(tonumber(b.level) or 0) end
    end
    local info = self:GetPlayerInfo(playerName)
    return math.floor(tonumber(info and info.level) or 0)
end

-- Race connue pour export UI / SR : Communaute en priorite, LR/K legacy en fallback.
function Overlord.Leaderboard:GetExportPlayerRace(playerName, allowCommunityRefresh)
    if not playerName or playerName == "" then return "", 0 end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "", 0 end
    -- Le roster Blizzard porte un raceID meme pour de nombreux membres hors ligne.
    -- Il constitue donc la source locale la plus fraiche lorsqu'il connait le personnage.
    local communityMeta = nil
    if sync then
        if allowCommunityRefresh == false and sync.GetCommunityMemberCharacterIfFresh then
            communityMeta = sync:GetCommunityMemberCharacterIfFresh(playerName, 30)
        elseif allowCommunityRefresh ~= false and sync.GetCommunityMemberCharacter then
            communityMeta = sync:GetCommunityMemberCharacter(playerName, false, 30)
        end
    end
    local communityRace = communityMeta and communityMeta.race or ""
    local communitySex = math.floor(tonumber(communityMeta and communityMeta.raceSex) or 0)
    if communitySex ~= 2 and communitySex ~= 3 then communitySex = 0 end

    -- Les metadonnees repliquees restent indispensables entre joueurs qui ne partagent
    -- pas les memes communautes. Elles peuvent aussi completer le sexe absent du roster.
    local fallbackRace, fallbackSex = "", 0
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName
    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b and b.race and b.race ~= "" then
            fallbackRace = b.race
            fallbackSex = tonumber(b.raceSex) or 0
        end
    end
    local pi = self:GetPlayerInfo(playerName)
    if fallbackRace == "" and pi and pi.race and pi.race ~= "" then
        fallbackRace = pi.race
        fallbackSex = tonumber(pi.raceSex) or 0
    end
    if communityRace ~= "" then
        if communitySex == 0 and fallbackRace == communityRace then
            communitySex = fallbackSex
        end
        return communityRace, communitySex
    end
    return fallbackRace, fallbackSex
end

-- Communaute/LR (et K legacy) : n'ecrase pas une race connue par un champ vide.
function Overlord.Leaderboard:SetPlayerRace(
    playerName, raceFile, raceSexOpt, fromSync, observedAtOpt, verifiedOwner)
    if not playerName then return end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return end
    local normRace = (sync and sync.NormalizeRaceFileToken and sync:NormalizeRaceFileToken(raceFile)) or nil
    if not normRace or normRace == "" then return end
    local sex = math.floor(tonumber(raceSexOpt) or 0)
    if sex ~= 2 and sex ~= 3 then sex = 0 end
    local observedAt = math.floor(tonumber(observedAtOpt) or 0)
    if not fromSync and observedAt <= 0 then
        observedAt = (GetServerTime and GetServerTime()) or time()
    elseif fromSync then
        local now = (GetServerTime and GetServerTime()) or time()
        if observedAt < 0 or observedAt > now + 300 then observedAt = 0 end
    end
    local prev = self.playerInfo[playerName]
    local previousAt = prev and math.floor(tonumber(prev.raceAt) or 0) or 0
    if prev and prev.race and prev.race ~= "" and prev.race == normRace then
        if sex == 0 or (tonumber(prev.raceSex) or 0) == sex then
            if observedAt > previousAt then
                prev.raceAt = observedAt
                -- raceAt participe au tie-break de l'index et doit etre persiste.
                self:MarkMetaDirty()
            end
            return
        end
        if fromSync and observedAt < previousAt then return end
        if fromSync and observedAt == previousAt then
            local prevSex = tonumber(prev.raceSex) or 0
            if sex == 0 or (prevSex > 0 and sex >= prevSex) then return end
        end
    elseif prev and prev.race and prev.race ~= "" and prev.race ~= normRace then
        if fromSync and observedAt < previousAt then return end
        if fromSync and observedAt == previousAt and normRace >= prev.race then return end
    end
    if not prev then
        self.playerInfo[playerName] = {
            class = "", faction = "", factionAt = 0, locale = "", guild = "", pool = "",
            race = normRace, raceSex = sex,
            raceAt = observedAt,
        }
        NoteDedupCanonicalName(self, playerName)
    else
        prev.race = normRace
        if sex > 0 then prev.raceSex = sex end
        prev.raceAt = observedAt
    end
    self:MarkMetaDirty()
    if not fromSync and sync and sync.MaybeBroadcastObservedLeaderboardRace then
        sync:MaybeBroadcastObservedLeaderboardRace(playerName, normRace, sex, observedAt)
    end
end

function Overlord.Leaderboard:SetPlayerRaceFromSync(
    playerName, raceFile, raceSexOpt, observedAtOpt)
    self:SetPlayerRace(playerName, raceFile, raceSexOpt, true, observedAtOpt)
end

-- Complete la race depuis nameplates / groupe (affichage local, hors chemin chaud sync).
function Overlord.Leaderboard:EnrichMissingRacesFromVisibleUnits()
    local sync = Overlord.Sync
    if not sync or not sync.NormalizeRaceFileToken then return end
    local byFull = {}
    local shortFirst = {}
    local shortAmbiguous = {}
    local neededFull = {}
    local neededShort = {}

    local function needsRace(pname)
        -- Cette routine inspecte les unites deja visibles. Elle ne doit pas declencher en plus
        -- un scan asynchrone de toutes les communautes hors ligne.
        local r = select(1, self:GetExportPlayerRace(pname, false))
        return r == nil or r == ""
    end

    local function registerNeeded(pname)
        if not pname or pname == "" or not needsRace(pname) then return end
        neededFull[pname] = true
        local norm = sync.NormalizeContributorFullName
            and sync:NormalizeContributorFullName(pname)
        if norm and norm ~= "" then neededFull[norm] = true end
        if not pname:find("-", 1, true) then
            neededShort[pname] = true
        end
    end
    for pname, k in pairs(self.kills or {}) do
        if (k or 0) > 0 then registerNeeded(pname) end
    end
    for pname in pairs(self.playerInfo or {}) do
        registerNeeded(pname)
    end
    if next(neededFull) == nil and next(neededShort) == nil then return end

    local function ingestNameRace(full, raceFile, raceSex)
        if not full or full == "" or not raceFile or raceFile == "" then return end
        local norm = sync.NormalizeContributorFullName
            and sync:NormalizeContributorFullName(full)
        local short = full:match("^(.-)%-") or full
        if not neededFull[full] and not (norm and neededFull[norm])
            and not neededShort[short] then
            return
        end
        byFull[full] = { raceFile, raceSex or 0 }
        if norm and norm ~= full then
            byFull[norm] = { raceFile, raceSex or 0 }
        end
        if short and short ~= "" then
            if shortFirst[short] == nil then
                shortFirst[short] = { raceFile, raceSex or 0, norm or full }
            elseif shortFirst[short][3] ~= (norm or full)
                or shortFirst[short][1] ~= raceFile
                or shortFirst[short][2] ~= (raceSex or 0) then
                shortAmbiguous[short] = true
            end
        end
    end

    local function ingestUnit(unit)
        if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
        local full = Overlord:SafeGetUnitName(unit, true)
        local _, raceFile = UnitRace(unit)
        raceFile = sync:NormalizeRaceFileToken(raceFile)
        if not raceFile then return end
        local sex = UnitSex(unit) or 0
        if sex ~= 2 and sex ~= 3 then sex = 0 end
        ingestNameRace(full, raceFile, sex)
    end

    for i = 1, 40 do ingestUnit("nameplate" .. i) end
    ingestUnit("target")
    ingestUnit("focus")
    local grpPrefix, grpCount
    if IsInRaid() then grpPrefix, grpCount = "raid", 40
    elseif IsInGroup() then grpPrefix, grpCount = "party", 4 end
    if grpPrefix then
        for i = 1, grpCount do ingestUnit(grpPrefix .. i) end
    end
    if Overlord.Combat and Overlord.Combat.ForEachCachedPlayerRace then
        Overlord.Combat:ForEachCachedPlayerRace(ingestNameRace)
    end

    local function tryEnrich(pname)
        if not pname or pname == "" or not needsRace(pname) then return false end
        local hit = byFull[pname]
        if not hit and sync.NormalizeContributorFullName then
            hit = byFull[sync:NormalizeContributorFullName(pname)]
        end
        if not hit and not pname:find("-", 1, true) then
            local ps = pname:match("^(.-)%-") or pname
            if not shortAmbiguous[ps] then hit = shortFirst[ps] end
        end
        if hit then
            self:SetPlayerRace(pname, hit[1], hit[2], false)
            return true
        end
        return false
    end

    local updated = false
    for pname, k in pairs(self.kills or {}) do
        if (k or 0) > 0 and tryEnrich(pname) then updated = true end
    end
    for pname in pairs(self.playerInfo or {}) do
        if tryEnrich(pname) then updated = true end
    end
    if updated then
        self:MarkMetaDirty()
    end
end

-- Au chargement : propage la meilleure classe (token valide) sur toutes les lignes playerInfo
-- et les cles kills/captures actives qui partagent la meme cle dedup Sync.
-- Repare les SV ou la classe ne reste que sur une variante de nom apres fusion / sync.
function Overlord.Leaderboard:HealPropagateClassAcrossDedupAliases(yieldWork)
    local sync = Overlord.Sync
    if not (self.playerInfo and sync and sync.GetCaptureContributorDedupKey) then return end
    local function classRank(c)
        if not c or c == "" then return 0 end
        if c == "UNKNOWN" then return 1 end
        return 2
    end
    local bestByDk = {}
    for k, inf in pairs(self.playerInfo) do
        if yieldWork then yieldWork() end
        if k and k ~= "" and inf and inf.class then
            local dkk = sync:GetCaptureContributorDedupKey(k)
            if dkk then
                local dkKey = dkk:lower()
                local c = inf.class
                local prev = bestByDk[dkKey]
                if classRank(c) > classRank(prev) then
                    bestByDk[dkKey] = c
                end
            end
        end
    end
    local updated = false
    -- Une seconde passe indexee suffit. L'ancien parcours faisait une passe
    -- playerInfo complete pour chaque cle dedup (O(N^2) au login).
    for k, inf in pairs(self.playerInfo) do
        if yieldWork then yieldWork() end
        if k and inf then
            local dkk = sync:GetCaptureContributorDedupKey(k)
            local rawBest = dkk and bestByDk[dkk:lower()]
            if classRank(rawBest) >= 2 then
                local norm = self:NormalizeClassTokenForDisplay(rawBest)
                if norm and classRank(inf.class) < classRank(norm) then
                    inf.class = norm
                    if inf.locale == nil then inf.locale = "" end
                    updated = true
                end
            end
        end
    end
    local function bumpActive(name)
        if not name or name == "" then return end
        local dk = sync:GetCaptureContributorDedupKey(name)
        if not dk then return end
        local rawBest = bestByDk[dk:lower()]
        if not rawBest or classRank(rawBest) < 2 then return end
        local norm = self:NormalizeClassTokenForDisplay(rawBest)
        if not norm then return end
        local row = self.playerInfo[name]
        if not row then
            self:SetPlayerClassFromSync(name, norm)
            updated = true
        elseif classRank(row.class) < classRank(norm) then
            row.class = norm
            if row.locale == nil then row.locale = "" end
            updated = true
        end
    end
    for n in pairs(self.kills or {}) do if yieldWork then yieldWork() end; bumpActive(n) end
    for n in pairs(self.captureCount or {}) do if yieldWork then yieldWork() end; bumpActive(n) end
    for n in pairs(self.captures or {}) do if yieldWork then yieldWork() end; bumpActive(n) end
    if updated then self:MarkMetaDirty() end
end

-- Au chargement : aligne la guilde (priorite nom complet + kills) sur tous les alias dedup playerInfo.
-- Repare les SV ou la guilde ne reste que sur une variante de nom apres raid / enrichissement local.
function Overlord.Leaderboard:HealPropagateGuildAcrossDedupAliases(yieldWork)
    local sync = Overlord.Sync
    if not (self.playerInfo and sync and sync.GetCaptureContributorDedupKey) then return end
    local bestByDk = {}
    for k, inf in pairs(self.playerInfo) do
        if yieldWork then yieldWork() end
        if k and k ~= "" and inf then
            local g = sanitizeGuildName(inf.guild or "")
            local guildAt = normalizeGuildAt(inf.guildAt)
            if g ~= "" or guildAt > 0 then
                local dkk = sync:GetCaptureContributorDedupKey(k)
                if dkk then
                    local dkKey = dkk:lower()
                    local candidate = {
                        guild = g,
                        guildAt = guildAt,
                        guildAuth = inf.guildAuth == true,
                        rank = guildAliasRank(k, self),
                    }
                    local previous = bestByDk[dkKey]
                    local sameValue = previous
                        and previous.guild:lower() == candidate.guild:lower()
                        and previous.guildAt == candidate.guildAt
                    if not previous or guildRecordWins(
                        candidate.guild, candidate.guildAt, candidate.guildAuth,
                        previous.guild, previous.guildAt, previous.guildAuth) then
                        bestByDk[dkKey] = candidate
                    elseif sameValue then
                        previous.guildAuth = previous.guildAuth or candidate.guildAuth
                        previous.rank = math.max(previous.rank or 0, candidate.rank or 0)
                    end
                end
            end
        end
    end
    local updated = false
    for k, inf in pairs(self.playerInfo) do
        if yieldWork then yieldWork() end
        if k and inf then
            local dkk = sync:GetCaptureContributorDedupKey(k)
            if dkk then
                local dkKey = dkk:lower()
                local best = bestByDk[dkKey]
                if best then
                    local cur = sanitizeGuildName(inf.guild or "")
                    local curAt = normalizeGuildAt(inf.guildAt)
                    local curAuth = inf.guildAuth == true
                    if cur:lower() ~= best.guild:lower()
                        or curAt ~= best.guildAt or curAuth ~= best.guildAuth then
                        inf.guild = best.guild
                        inf.guildAt = best.guildAt
                        inf.guildAuth = best.guildAuth or nil
                        if inf.pool == nil then inf.pool = "" end
                        updated = true
                    end
                end
            end
        end
    end
    if updated then self:MarkMetaDirty() end
end

-- Retourne les infos joueur ; essaie plusieurs variantes de nom (exact, +royaume, nom court si "Nom-Realm").
function Overlord.Leaderboard:GetPlayerInfo(playerName)
    if not playerName or playerName == "" then return nil end
    local syncN = Overlord.Sync
    if syncN and syncN.NormalizeContributorFullName then
        playerName = syncN:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return nil end
    local info = self.playerInfo[playerName]
    if info then return info end
    local canon = syncN and syncN.CanonicalForeverName and syncN:CanonicalForeverName(playerName)
    if canon and canon ~= playerName then
        info = self.playerInfo[canon]
        if info then return info end
    end
    return nil
end

-- Classe + faction pour export Check PvP et classement (kills / captures UI).
--
-- GARDE-FOUS (regression 2026 : classement + export Check PvP tout "Unknown") :
-- 1) UNKNOWN ici est un placeholder d'affichage / dernier recours - jamais l'envoyer sur le reseau
--    comme si c'etait un token WoW (voir Sync LK : champ classe vide si inconnu).
-- 2) L'index dedup est autoritaire apres sa construction complete. Une absence de bucket signifie
--    qu'aucune variante dedup n'a de metadata ; ne jamais rescanner/trier tout playerInfo par ligne.
-- 3) Joueurs encore UNKNOWN en disque : souvent playerInfo deja pollue par d'anciens LK, ou aucune
--    source classe jamais reçue ; HealPropagateClassAcrossDedupAliases aide si une autre cle dedup a le token.
-- IMPORTANT faction : ne pas utiliser pairs() sans ordre - apres swap Alliance/Horde, plusieurs
-- lignes peuvent coexister ; on garde la plus recente (factionAt).
-- Le join exporte reste volontairement independant des horloges et observations du receveur.
function Overlord.Leaderboard:GetExportPlayerMeta(playerName)
    if not playerName or playerName == "" then return "", "" end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "", "" end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName

    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b and (b.faction == "Alliance" or b.faction == "Horde") then
            local bestClass, bestFaction = b.class or "", b.faction or ""
            if bestClass == "" then
                return "", bestFaction
            elseif bestClass ~= "UNKNOWN" then
                local n = self:NormalizeClassTokenForDisplay(bestClass)
                if not n then return "", bestFaction end
                bestClass = n
            end
            return bestClass, bestFaction
        end
        -- Compat SV tres anciennes : GetExportPlayerMeta associait une ligne courte sans
        -- royaume a un nom complet de meme base. Ce repli O(1) conserve ce comportement sans
        -- recreer et trier toutes les cles playerInfo a chaque ligne score-only.
        local shortName = playerName:match("^([^-]+)")
        if shortName and shortName ~= playerName then
            local legacy = self._dedupLegacyShortMetaIndex
                and self._dedupLegacyShortMetaIndex[shortName:lower()]
            if legacy then
                local bestClass = legacy.class or ""
                local bestFaction = legacy.faction or ""
                if bestClass ~= "" and bestClass ~= "UNKNOWN" then
                    bestClass = self:NormalizeClassTokenForDisplay(bestClass) or ""
                end
                return bestClass, bestFaction
            end
        end
        -- Index pas encore reconstruit apres le chargement du bucket :
        -- ne pas jeter la ligne, la faction est dans playerInfo.
    end

    local info = self:GetPlayerInfo(playerName)
    local bestClass, bestFaction = (info and info.class) or "", (info and info.faction) or ""
    if bestClass ~= "" and bestClass ~= "UNKNOWN" then
        bestClass = self:NormalizeClassTokenForDisplay(bestClass) or ""
    end
    return bestClass, bestFaction
end

-- Locale client (sync K/LK) agregee comme la faction : entree la plus recente (factionAt) avec locale non vide.
-- Join lexical stable entre alias equivalents.
function Overlord.Leaderboard:GetExportPlayerLocale(playerName)
    if not playerName or playerName == "" then return "" end
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName

    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b and b.locale and b.locale ~= "" then
            return b.locale
        end
        return ""
    end

    local info = self:GetPlayerInfo(playerName)
    return sanitizeLocaleTag((info and info.locale) or "")
end

local function InferContributorPoolHintForLocale(playerName)
    local pool = normalizeSavedVarsPool(
        Overlord.Leaderboard:GetContributorSavedVarsPool(playerName) or "")
    if pool ~= "" then return pool end
    if not playerName or playerName == "" then return "" end
    local rp = Overlord.RealmPools
    if rp and rp.InferPoolTagFromRealmName then
        return normalizeSavedVarsPool(rp:InferPoolTagFromRealmName(playerName) or "")
    end
    return ""
end

function Overlord.Leaderboard:GetLeaderboardDisplayTag(playerName)
    if not playerName or playerName == "" then return "" end
    local localeTag = sanitizeLocaleTag(self:GetExportPlayerLocale(playerName))
    if localeTag == "" then return "" end
    if Overlord.FormatLocaleTagForDisplay then
        return Overlord:FormatLocaleTagForDisplay(localeTag, InferContributorPoolHintForLocale(playerName))
    end
    return localeTag:upper()
end

-- Guilde agregee comme locale : premiere entree non vide sur les cles dedup ; perso local via GetGuildInfo.
function Overlord.Leaderboard:GetExportPlayerGuild(playerName)
    if not playerName or playerName == "" then return "" end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "" end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName

    if dk and self:EnsureDedupMetaIndex() then
        local b = self._dedupMetaIndex[dk:lower()]
        if b then
            if b.guild and b.guild ~= "" then
                return b.guild
            end
        end
        return ""
    end

    local info = self:GetPlayerInfo(playerName)
    return sanitizeGuildName((info and info.guild) or "")
end

-- Demande aux pairs (GR/GY) les guildes manquantes pour le classement guildes.
function Overlord.Leaderboard:RequestMissingGuildsForKillRows()
    local sync = Overlord.Sync
    if not sync or not sync.MaybeRequestMissingGuild then return end
    if Overlord.InstanceSuspended then return end
    local maxAsk = 32
    local missing = {}
    for name, kills in pairs(self.kills or {}) do
        if (kills or 0) > 0 then
            local guild = self:GetExportPlayerGuild(name)
            if not guild or guild == "" then
                missing[#missing + 1] = { name = name, kills = kills }
            end
        end
    end
    table.sort(missing, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        return (a.name or "") < (b.name or "")
    end)
    for i = 1, math.min(#missing, maxAsk) do
        sync:MaybeRequestMissingGuild(missing[i].name)
    end
end

-- Rafraichit la guilde du perso local avant agregation (pas d'inference tierce depuis le groupe).
function Overlord.Leaderboard:EnrichGuildForKillRows()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    self:UpdateLocalPlayerGuild()
    self:EnrichGuildFromLocalRoster()
end

-- Chemin incremental pour les nouveaux scores apres chargement du roster. O(1) par joueur :
-- il remplace le scan complet qui etait auparavant declenche par chaque lecture du panneau.
function Overlord.Leaderboard:MaybeEnrichGuildForKillRow(playerName)
    if not localGuildRosterKeys or localGuildRosterGuild == ""
        or not localGuildRosterMatches(playerName) then
        return false
    end
    local row = self.playerInfo[playerName]
    if type(row) == "table" then
        local currentGuild = sanitizeGuildName(row.guild or "")
        if currentGuild:lower() == localGuildRosterGuild:lower() then return false end
        -- Le roster local n'est qu'un hint a timestamp nul : ne jamais ecraser
        -- un fait proprietaire GI/K plus recent.
        if currentGuild ~= "" or normalizeGuildAt(row.guildAt) > 0 then return false end
    else
        row = {
            class = "", level = 0, faction = "", factionAt = 0,
            locale = "", guild = "", guildAt = 0, pool = "",
            race = "", raceSex = 0, raceAt = 0,
        }
        self.playerInfo[playerName] = row
        NoteDedupCanonicalName(self, playerName)
    end
    row.guild = localGuildRosterGuild
    row.guildAt = 0
    row.guildAuth = nil
    self:MarkMetaDirty()
    return true
end

-- Attribue la guilde du joueur local a tous les contributeurs kills presents dans son roster
-- de guilde. Lecture seule cote reseau : on n'envoie pas de nouveau message, on pose juste une
-- guilde autoritaire localement (comme UpdateLocalPlayerGuild pour le perso, etendu aux membres).
-- Effet de bord positif : cette autorite locale alimente ensuite les bits d'autorite GY, donc
-- ameliore la convergence du total de guilde chez les autres clients au lieu de la degrader.
function Overlord.Leaderboard:EnrichGuildFromLocalRoster()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    -- Un second evenement peut arriver pendant le scan tranche precedent. Ne
    -- pas consommer son nouveau roster avant que l'ancien worker ait rendu son
    -- slot, sinon membershipChanged serait perdu au prochain passage chaud.
    if self._guildRosterKillEnrichPending then
        self._guildRosterKillEnrichRestartRequested = true
        return
    end
    local ready, membershipChanged = refreshLocalGuildRosterCache(function()
        ScheduleLocalGuildRosterEnrich(0)
    end)
    if not ready or not membershipChanged then return end
    local myGuild = localGuildRosterGuild
    if not localGuildRosterKeys or myGuild == "" then return end
    local generation = localGuildRosterGeneration
    self._guildRosterKillEnrichPending = true
    local killRows = self.kills or {}
    local cursor
    local cursorRestartCount = 0
    local function FinishScan()
        self._guildRosterKillEnrichPending = false
        if self._guildRosterKillEnrichRestartRequested then
            self._guildRosterKillEnrichRestartRequested = nil
            ScheduleLocalGuildRosterEnrich(0)
        end
    end
    local function RunSlice()
        if generation ~= localGuildRosterGeneration or Overlord.InstanceSuspended
            or self.kills ~= killRows then
            FinishScan()
            return
        end
        local processed = 0
        local startedAt = debugprofilestop and debugprofilestop() or 0
        while processed < 64 do
            local okNext, name, kills = pcall(next, killRows, cursor)
            if not okNext then
                -- Une fusion dedup peut retirer la cle cursor entre deux
                -- tranches. Repartir de la tete reste idempotent et borne.
                cursorRestartCount = cursorRestartCount + 1
                cursor = nil
                if cursorRestartCount <= 8 then
                    C_Timer.After(0, RunSlice)
                else
                    FinishScan()
                end
                return
            end
            if name == nil then
                FinishScan()
                return
            end
            cursor = name
            if (kills or 0) > 0 then
                -- Hint deterministe : remplit l'absence, sans timestamp local ni
                -- autorite capable d'ecraser un fait proprietaire GI/K/LK.
                self:MaybeEnrichGuildForKillRow(name)
            end
            processed = processed + 1
            if debugprofilestop and (debugprofilestop() - startedAt) >= 1.25 then break end
        end
        C_Timer.After(0, RunSlice)
    end
    RunSlice()
end

-- Totaux kills par faction (meme logique que LeaderboardUI, pour ecran de victoire aligne)
function Overlord.Leaderboard:GetFactionKillTotals()
    local alliKills, hordeKills = 0, 0
    for name, kills in pairs(self.kills or {}) do
        local _, fac = self:GetExportPlayerMeta(name)
        if fac == "Horde" then
            hordeKills = hordeKills + kills
        elseif fac == "Alliance" then
            alliKills = alliKills + kills
        end
    end
    return alliKills, hordeKills
end

-- Scanne le raid/groupe pour recuperer classe et faction de chaque membre
-- WoW 12.0.5 : SafeUnitName gere les secret values
function Overlord.Leaderboard:ScanRaidInfo()
    if Overlord.InstanceSuspended or IsInInstance() then
        self:UpdateLocalPlayerGuild()
        return
    end
    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", 40
    elseif IsInGroup() then
        prefix, count = "party", 4
    else
        self:UpdateLocalPlayerGuild()
        return
    end

    local changed = false
    local sync = Overlord.Sync
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            -- WoW 12.0.5 : SafeUnitName gere les secret values
            local name = Overlord:SafeUnitName(unit)
            if name then
                local fullName = sync and sync.CanonicalForeverName
                    and sync:CanonicalForeverName(name) or nil
                if fullName then
                local _, className = UnitClass(unit)
                local faction = UnitFactionGroup(unit)
                if className then
                    local prev = self.playerInfo[fullName]
                    self:SetPlayerInfo(fullName, className, faction)
                    local now = self.playerInfo[fullName]
                    if not prev or (now and (prev.class ~= now.class or prev.faction ~= now.faction)) then
                        changed = true
                    end
                end
                end
            end
        end
    end
    self:UpdateLocalPlayerGuild()
    if changed then
        self:MarkMetaDirty()
    end
end

-- Complete la classe (token anglais) depuis nameplates + target/focus pour les lignes kills sans classe.
-- Hors groupe, ScanRaidInfo ne tourne pas ; LK peut n'apporter que la faction - icone / couleur nom restent vides.
-- WoW 12.0.5 : SafeGetUnitName gere les secret values
function Overlord.Leaderboard:EnrichMissingClassesFromVisibleUnits()
    local byFull = {}
    local shortFirst = {}
    local shortAmbiguous = {}

    local function ingestNameClass(full, classToken)
        if not full or full == "" then return end
        if not classToken or classToken == "" then return end
        byFull[full] = classToken
        local syncN = Overlord.Sync
        if syncN and syncN.NormalizeContributorFullName then
            local norm = syncN:NormalizeContributorFullName(full)
            if norm and norm ~= full then
                byFull[norm] = classToken
            end
        end
        local short = full:match("^(.-)%-") or full
        if short and short ~= "" then
            if shortFirst[short] == nil then
                shortFirst[short] = classToken
            elseif shortFirst[short] ~= classToken then
                shortAmbiguous[short] = true
            end
        end
    end

    local function ingestUnit(unit)
        if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
        local full = Overlord.Sync and Overlord.Sync.CanonicalForeverNameFromUnit
            and Overlord.Sync:CanonicalForeverNameFromUnit(unit) or nil
        local _, classToken = UnitClass(unit)
        ingestNameClass(full, classToken)
    end

    for i = 1, 40 do
        ingestUnit("nameplate" .. i)
    end
    ingestUnit("target")
    ingestUnit("focus")
    -- Groupe / raid : enrichit les allies presents dans le groupe (classes toujours visibles)
    local grpPrefix, grpCount
    if IsInRaid() then grpPrefix, grpCount = "raid", 40
    elseif IsInGroup() then grpPrefix, grpCount = "party", 4 end
    if grpPrefix then
        for i = 1, grpCount do
            ingestUnit(grpPrefix .. i)
        end
    end
    if Overlord.Combat and Overlord.Combat.ForEachCachedPlayerInfo then
        Overlord.Combat:ForEachCachedPlayerInfo(ingestNameClass)
    end

    local function needsEnrichFromWorld(cls)
        return cls == nil or cls == "" or cls == "UNKNOWN"
    end
    local function tryEnrichPlayerName(pname)
        if not pname or pname == "" then return false end
        local cls = select(1, self:GetExportPlayerMeta(pname))
        if not needsEnrichFromWorld(cls) then return false end
        local token = byFull[pname]
        if not token and Overlord.Sync and Overlord.Sync.NormalizeContributorFullName then
            token = byFull[Overlord.Sync:NormalizeContributorFullName(pname)]
        end
        if not token then
            local ps = pname:match("^(.-)%-") or pname
            if not shortAmbiguous[ps] then
                token = shortFirst[ps]
            end
        end
        if token then
            self:SetPlayerClassFromSync(pname, token)
            return true
        end
        return false
    end

    local updated = false
    for pname, k in pairs(self.kills or {}) do
        if (k or 0) > 0 and tryEnrichPlayerName(pname) then
            updated = true
        end
    end
    for pname, c in pairs(self.captureCount or {}) do
        if (c or 0) > 0 and tryEnrichPlayerName(pname) then
            updated = true
        end
    end
    for pname, zones in pairs(self.captures or {}) do
        if type(zones) == "table" and #zones > 0 and tryEnrichPlayerName(pname) then
            updated = true
        end
    end
    if updated then
        self:MarkMetaDirty()
    end
end

-- Ouvre atomiquement le bucket de la nouvelle campagne. L'ancien bucket reste
-- detache et persiste dans pendingWeeklyArchive ; son archivage top-N est repris
-- en tranches apres la frame de reset.
function Overlord.Leaderboard:Reset(archivingStartOverride, resetEpochOverride, campaignIdOverride)
    local MIN_RESET_GAP = 518400 -- 6 jours : filet anti-boucle 8.0.6
    if OverlordDB then
        local pending = tonumber(OverlordDB.pendingWeeklyResetAt) or 0
        local lastAt = tonumber(OverlordDB.lastLeaderboardResetAt) or 0
        if pending <= 0 and lastAt > 0 then
            local now = (GetServerTime and GetServerTime()) or time()
            if (now - lastAt) < MIN_RESET_GAP then
                if OverlordDB.config and OverlordDB.config.debug then
                    print("|cFFFF4444[Overlord:dbg]|r Leaderboard:Reset refuse (intervalle < 6 j).")
                end
                return
            end
        end
    end
    local archivingStart = tonumber(archivingStartOverride) or 0
    if archivingStart <= 0 then
        archivingStart = tonumber(OverlordDB and OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0
    end
    if archivingStart <= 0 then
        archivingStart = self:GetCurrentCampaignStart()
    end

    local resetEpoch = math.floor(tonumber(resetEpochOverride) or 0)
    if resetEpoch <= 0 then
        resetEpoch = math.floor(tonumber(OverlordDB and OverlordDB.pendingWeeklyResetAt) or 0)
    end
    if resetEpoch <= 0 then resetEpoch = math.floor(tonumber(self:GetCurrentCampaignStart()) or 0) end
    local campaignId = math.floor(tonumber(campaignIdOverride) or 0)
    if campaignId <= 0 and Overlord.TimestampToCampaignId then
        campaignId = Overlord:TimestampToCampaignId(resetEpoch)
    end

    local opened = self:OpenAtomicWeeklyBucket(archivingStart, resetEpoch, campaignId)
    if not opened then
        local marker = OverlordDB and OverlordDB.pendingWeeklyArchive
        if type(marker) == "table"
            and tonumber(marker.resetEpoch) == resetEpoch
            and marker.leaderboardSideEffectsApplied ~= true then
            self:ResetGuildKeepCampaignData()
            self:Save()
            OverlordDB.lastLeaderboardResetAt = (GetServerTime and GetServerTime()) or time()
            marker.leaderboardSideEffectsApplied = true
        end
        self:ResumePendingWeeklyArchive()
        return false
    end

    -- Donnees campagne fixes/petites : elles basculent dans la meme frame logique
    -- que le bucket afin qu'une capture post-frontiere ne puisse jamais etre effacee.
    self:ResetGuildKeepCampaignData()
    self:Save()
    if OverlordDB then
        OverlordDB.lastLeaderboardResetAt = (GetServerTime and GetServerTime()) or time()
        local marker = OverlordDB.pendingWeeklyArchive
        if type(marker) == "table" and marker.resetEpoch == resetEpoch then
            marker.leaderboardSideEffectsApplied = true
        end
    end
    if Overlord.CharacterStats and Overlord.CharacterStats.Refresh then
        Overlord.CharacterStats:Refresh()
    end
    self:ResumePendingWeeklyArchive()
    return true
end

-- Tenants fortin projetes depuis les terminaux GK v8 acceptes.
function Overlord.Leaderboard:GetGuildKeepTenantsTable()
    if not OverlordDB then return {} end
    ensureGuildKeepLeaderboardTables(self)
    return OverlordDB.guildKeepTenants
end

-- Projection classement du terminal v8 deja valide par GuildKeep.
function Overlord.Leaderboard:ApplyGuildKeepTenant(siteKey, guild, faction, claimedAt, poolTag, force)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    claimedAt = math.floor(tonumber(claimedAt) or 0)
    poolTag = normalizeSavedVarsPool(poolTag) or ""
    if poolTag == "" then return false end
    if not guildKeepLbPoolMatchesCurrent(poolTag) then return false end
    if siteKey == "" or not Overlord.GuildKeepSites or not Overlord.GuildKeepSites[siteKey] then
        return false
    end
    if guild == "" or claimedAt <= 0 then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if not self:IsTimestampInCurrentCampaign(claimedAt, campaignStart) then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    local gk = Overlord.GuildKeep
    if gk and gk.IsSiegeGameplayTimestampAllowed and not gk:IsSiegeGameplayTimestampAllowed(claimedAt) then
        return false
    end
    force = force == true
    if not force then
        local st = gk and gk.GetState and gk:GetState(siteKey)
        local heldGuild = st and sanitizeGuildName(st.ownerGuild or "") or ""
        local heldClaimedAt = math.floor(tonumber(st and st.claimedAt) or 0)
        -- Sans force, seule une projection exacte de l'etat terrain est acceptee.
        if not st or st.status ~= "held" or heldGuild:lower() ~= guild:lower()
            or st.ownerFaction ~= faction or heldClaimedAt ~= claimedAt then return false end
    end
    local tenants = self:GetGuildKeepTenantsTable()
    local prev = tenants[siteKey]
    local prevTs = prev and math.floor(tonumber(prev.claimedAt) or 0) or 0
    local guildKey = guild:lower()
    if not force and prev and prevTs > claimedAt then return false end
    if not force and prev and prevTs == claimedAt and (prev.guildKey or "") == guildKey then
        return false
    end
    tenants[siteKey] = {
        guild = guild,
        guildKey = guildKey,
        faction = faction,
        claimedAt = claimedAt,
        pool = poolTag,
    }
    if gk and gk.RecordOfficialKeepTenant then
        gk:RecordOfficialKeepTenant(siteKey, guild, faction, claimedAt, poolTag, force)
    end
    if self.InvalidateGuildKeepDailyAwardStable then
        self:InvalidateGuildKeepDailyAwardStable()
    end
    self:MarkDirty()
    if self.RequestGuildKeepProofLedgerRebuild then
        self:RequestGuildKeepProofLedgerRebuild()
    end
    -- CompleteCapture local ne recoit pas son propre GC. Invalider aussi la liste de sites
    -- (cache UI independant 30 s), sinon un panneau ouvert pouvait garder l'ancien tenant.
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    return true
end

-- Capture locale : ecrit le tenant classement avant emission GC/GK.
function Overlord.Leaderboard:SetGuildKeepTenantLocal(siteKey, guild, faction, claimedAt, force)
    return self:ApplyGuildKeepTenant(
        siteKey, guild, faction, claimedAt, currentSavedVarsPool(), force)
end

function Overlord.Leaderboard:ClearGuildKeepTenantLocal(siteKey)
    siteKey = tostring(siteKey or "")
    if not isValidGuildKeepSite(siteKey) then return false end
    ensureGuildKeepLeaderboardTables(self)
    local previous = OverlordDB.guildKeepTenants[siteKey]
    OverlordDB.guildKeepTenants[siteKey] = nil
    local changed = previous ~= nil
    local gk = Overlord.GuildKeep
    if gk and gk.ClearOfficialKeepTenant then
        changed = gk:ClearOfficialKeepTenant(siteKey) or changed
    end
    local claimedAt = math.floor(tonumber(previous and previous.claimedAt) or 0)
    local dayKey = claimedAt > 0 and gk and gk.GetServerSiegeDayKey
        and gk:GetServerSiegeDayKey(claimedAt) or nil
    if dayKey then
        local awardKey = dayKey .. ":" .. siteKey
        local award = OverlordDB.guildKeepSiegeWinAwards[awardKey]
        if award then
            OverlordDB.guildKeepSiegeWinAwards[awardKey] = nil
            changed = true
        end
    end
    if changed then
        if self.InvalidateGuildKeepDailyAwardStable then
            self:InvalidateGuildKeepDailyAwardStable()
        end
        self:MarkDirty()
        if self.RequestGuildKeepProofLedgerRebuild then
            self:RequestGuildKeepProofLedgerRebuild()
        end
        if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
    end
    return changed
end

-- Lignes LO pour reponses SR (tenants avant-postes, max 4 sites).
function Overlord.Leaderboard:BuildOutpostTenantSyncRows()
    local epoch = OverlordDB and tonumber(OverlordDB.lastResetTimestamp) or 0
    if epoch <= 0 then return {} end
    local rows = {}
    local tenants = self:GetOutpostTenantsTable()
    for siteKey in pairs(Overlord.OutpostSites or {}) do
        local t = getValidOutpostTenantRow(self, siteKey, tenants[siteKey])
        if t and self:IsTimestampInCurrentCampaign(t.claimedAt, epoch) then
            rows[#rows + 1] = {
                siteKey = siteKey,
                guild = t.guild,
                faction = t.faction or "",
                claimedAt = t.claimedAt,
                epoch = epoch,
                pool = t.pool,
            }
        end
    end
    table.sort(rows, function(a, b)
        local ta, tb = a.claimedAt or 0, b.claimedAt or 0
        if ta ~= tb then return ta > tb end
        if (a.siteKey or "") ~= (b.siteKey or "") then
            return (a.siteKey or "") < (b.siteKey or "")
        end
        return (a.guild or "") < (b.guild or "")
    end)
    return rows
end

-- CRDT compact des captures d'avant-poste :
--   - events = IDs temporels OC/LO explicites observes localement ;
--   - locAnchors = total confirme -> plus ancien latestTs confirme pour ce total.
-- Le total est max(anchor.total + events posterieurs a anchor.ts, nombre d'events).
-- Cette forme rend LOC->OC et OC->LOC strictement commutatifs.
local function ensureOutpostEventLedgerV2(row, yieldWork)
    if not row then return false end
    if row.eventLedgerPreparedV1 == true
        and type(row.events) == "table" and type(row.locAnchors) == "table" then
        row.eventCount = math.max(0, math.floor(tonumber(row.eventCount) or 0))
        row.newestEventTs = math.max(0, math.floor(tonumber(row.newestEventTs) or 0))
        row.newestAnchorTs = math.max(0, math.floor(tonumber(row.newestAnchorTs) or 0))
        return false
    end
    local changed = false
    if type(row.events) ~= "table" then row.events, changed = {}, true end
    if type(row.locAnchors) ~= "table" then row.locAnchors, changed = {}, true end
    local newestKnownTs = math.max(
        math.floor(tonumber(row.lastTs) or 0),
        math.floor(tonumber(row.floorTs) or 0))
    local eventCount, newestEvent = 0, 0
    local eventKey, eventValue = next(row.events)
    while eventKey ~= nil do
        local okNext, nextKey, nextValue = pcall(next, row.events, eventKey)
        if not okNext then error(nextKey) end
        local eventTs = math.floor(tonumber(eventKey) or 0)
        if eventTs <= 0 then
            row.events[eventKey], changed = nil, true
        else
            eventCount = eventCount + 1
            newestEvent = math.max(newestEvent, eventTs)
            newestKnownTs = math.max(newestKnownTs, eventTs)
        end
        eventKey, eventValue = nextKey, nextValue
        if yieldWork then yieldWork() end
    end
    if (row.faction == "Alliance" or row.faction == "Horde")
        and math.floor(tonumber(row.factionAt) or 0) <= 0 then
        row.factionAt = newestKnownTs
    end
    if row.eventLedgerVersion ~= 2 then
        local legacyTotal = math.min(PLAUSIBLE_OUTPOST_CAPTURE_COUNT,
            math.max(0, math.floor(tonumber(row.count) or 0)))
        -- Le total legacy inclut deja ses events explicites. L'ancrer en entier au dernier
        -- timestamp connu preserve exactement le score ; soustraire #events faisait baisser
        -- count lors de la premiere recomposition (ex. 5 + event(t5) devenait 4).
        local baseTs = newestKnownTs
        if baseTs <= 0 then
            baseTs = math.floor(tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0)
        end
        if legacyTotal > 0 and baseTs > 0 then
            local anchorKey = tostring(legacyTotal)
            local previous = math.floor(tonumber(row.locAnchors[anchorKey]) or 0)
            if previous <= 0 or baseTs < previous then row.locAnchors[anchorKey] = baseTs end
        end
        row.eventLedgerVersion, changed = 2, true
    end
    local newestAnchor = 0
    if not row.eventLedgerBoundsV1 then
        local totalKey, anchorValue = next(row.locAnchors)
        while totalKey ~= nil do
            local okNext, nextKey, nextValue = pcall(next, row.locAnchors, totalKey)
            if not okNext then error(nextKey) end
            local anchorTs = anchorValue
            local total = math.floor(tonumber(totalKey) or 0)
            anchorTs = math.floor(tonumber(anchorTs) or 0)
            if total <= 0 or total > PLAUSIBLE_OUTPOST_CAPTURE_COUNT or anchorTs <= 0 then
                row.locAnchors[totalKey], changed = nil, true
            else
                newestAnchor = math.max(newestAnchor, anchorTs)
            end
            totalKey, anchorValue = nextKey, nextValue
            if yieldWork then yieldWork() end
        end
        if eventCount > PLAUSIBLE_OUTPOST_CAPTURE_COUNT then
            -- Etat deja contamine avant le garde courant : compacter en une ancre bornee.
            local total = math.min(PLAUSIBLE_OUTPOST_CAPTURE_COUNT,
                math.max(0, math.floor(tonumber(row.count) or 0)))
            row.events = {}
            if total > 0 and newestEvent > 0 then
                row.locAnchors[tostring(total)] = newestEvent
            end
            eventCount = 0
            changed = true
        end
        row.eventLedgerBoundsV1, changed = true, true
    else
        local totalKey, anchorTs = next(row.locAnchors)
        while totalKey ~= nil do
            local okNext, nextKey, nextValue = pcall(next, row.locAnchors, totalKey)
            if not okNext then error(nextKey) end
            newestAnchor = math.max(newestAnchor, math.floor(tonumber(anchorTs) or 0))
            totalKey, anchorTs = nextKey, nextValue
            if yieldWork then yieldWork() end
        end
    end
    row.eventCount = eventCount
    row.newestEventTs = newestEvent
    row.newestAnchorTs = newestAnchor
    row.eventLedgerPreparedV1 = true
    return changed
end

local function recomputeOutpostEventLedger(row, yieldWork)
    ensureOutpostEventLedgerV2(row, yieldWork)
    local events = row.events or {}
    local eventTimes = {}
    local latest = 0
    local eventKey = next(events)
    while eventKey ~= nil do
        local okNext, nextKey = pcall(next, events, eventKey)
        if not okNext then error(nextKey) end
        local eventTs = eventKey
        eventTs = math.floor(tonumber(eventTs) or 0)
        if eventTs > 0 then
            eventTimes[#eventTimes + 1] = eventTs
            latest = math.max(latest, eventTs)
        end
        eventKey = nextKey
        if yieldWork then yieldWork() end
    end
    sortRowsWithYield(eventTimes, function(a, b) return a < b end, yieldWork)
    local function countEventsAfter(anchorTs)
        local lo, hi = 1, #eventTimes
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if eventTimes[mid] <= anchorTs then lo = mid + 1 else hi = mid - 1 end
        end
        return #eventTimes - lo + 1
    end
    local best, newestAnchor = #eventTimes, 0
    local anchorKey, anchorValue = next(row.locAnchors or {})
    while anchorKey ~= nil do
        local okNext, nextKey, nextValue = pcall(next, row.locAnchors, anchorKey)
        if not okNext then error(nextKey) end
        local totalKey, anchorTs = anchorKey, anchorValue
        local anchorTotal = math.max(0, math.floor(tonumber(totalKey) or 0))
        anchorTs = math.floor(tonumber(anchorTs) or 0)
        best = math.max(best, anchorTotal + countEventsAfter(anchorTs))
        latest = math.max(latest, anchorTs)
        newestAnchor = math.max(newestAnchor, anchorTs)
        anchorKey, anchorValue = nextKey, nextValue
        if yieldWork then yieldWork() end
    end
    row.count = math.min(best, PLAUSIBLE_OUTPOST_CAPTURE_COUNT)
    row.lastTs = math.max(math.floor(tonumber(row.lastTs) or 0), latest)
    row.eventCount = #eventTimes
    row.newestEventTs = eventTimes[#eventTimes] or 0
    row.newestAnchorTs = newestAnchor
    row.eventLedgerPreparedV1 = true
    return row.count
end

local function countOutpostEvents(row)
    return math.max(0, math.floor(tonumber(row and row.eventCount) or 0))
end

local function noteOutpostEventAdded(row, eventTs)
    local previous = math.max(0, math.floor(tonumber(row.count) or 0))
    row.eventCount = math.min(PLAUSIBLE_OUTPOST_CAPTURE_COUNT,
        math.max(0, math.floor(tonumber(row.eventCount) or 0)) + 1)
    row.newestEventTs = math.max(
        math.floor(tonumber(row.newestEventTs) or 0), eventTs)
    -- Cas courant et prouvable : un evenement posterieur a toutes les ancres LOC
    -- ne pouvait pas deja etre inclus dans leur total. Le chemin des paquets retardes
    -- garde un plancher sûr puis laisse le builder coopératif recomposer exactement.
    if eventTs > math.floor(tonumber(row.newestAnchorTs) or 0) then
        row.count = math.min(PLAUSIBLE_OUTPOST_CAPTURE_COUNT, previous + 1)
    else
        row.count = math.max(previous, row.eventCount)
    end
    row.lastTs = math.max(math.floor(tonumber(row.lastTs) or 0), eventTs)
    return row.count > previous
end

local function mergeOutpostRowFaction(row, faction, observedAt)
    if not row or (faction ~= "Alliance" and faction ~= "Horde") then return false end
    observedAt = math.floor(tonumber(observedAt) or 0)
    local current = row.faction or ""
    -- Une guilde WoW peut etre cross-faction. Le compteur est volontairement indexe par
    -- guilde (pas par faction) : la faction de transport doit donc etre un join commutatif.
    -- Le minimum lexical est stable quel que soit l'ordre A/H ; le tenant courant, lui,
    -- conserve sa faction horodatee dans outpostTenants.
    if current ~= "Alliance" and current ~= "Horde"
        or faction < current then
        row.faction = faction
        row.factionAt = observedAt
        return true
    end
    return false
end

local function outpostSyncStableKey(row)
    return table.concat({ tostring(row.siteKey or ""),
        tostring(row.guild or ""):lower(),
        resolveOutpostLbPoolTag(row.pool) }, ":")
end

function Overlord.Leaderboard:RequestOutpostLedgerRebuild()
    self._outpostLedgerRevision = (tonumber(self._outpostLedgerRevision) or 0) + 1
    self._outpostLedgerDirty = true
    if not self._outpostLedgerPrepared or self._outpostLedgerPrepPending
        or self._outpostLedgerPrepRetryScheduled or self._outpostLedgerPrepWakePending
        or not C_Timer or not C_Timer.After then return end
    self._outpostLedgerPrepWakePending = true
    C_Timer.After(0, function()
        if not Overlord.Leaderboard then return end
        Overlord.Leaderboard._outpostLedgerPrepWakePending = nil
        Overlord.Leaderboard:EnsureOutpostLedgerPrepared(false)
    end)
end

-- Barriere/cached snapshot du registre LOC. Le premier build est requis avant Sync ;
-- les rebuilds suivants gardent le dernier snapshot convergent lisible et publient
-- atomiquement une generation complete. Aucun handler reseau ne parcourt les SV.
function Overlord.Leaderboard:EnsureOutpostLedgerPrepared(requireCurrent)
    if not OverlordDB then return "blocked" end
    ensureOutpostLeaderboardTables(self)
    local source = OverlordDB.outpostCaptureCounts
    if self._outpostLedgerSource ~= source then
        self._outpostLedgerDirty = true
        self._outpostLedgerPrepared = false
        self._outpostLedgerPrepFailed = nil
    end
    if self._outpostLedgerPrepFailed then return "blocked" end
    if self._outpostLedgerPrepPending then
        if self._outpostLedgerPrepared and not requireCurrent then return true end
        return self._outpostLedgerPrepBackoff and "waiting" or false
    end
    if self._outpostLedgerPrepRetryScheduled then
        if self._outpostLedgerPrepared and not requireCurrent then return true end
        return "waiting"
    end
    if self._outpostLedgerPrepared and not self._outpostLedgerDirty then return true end
    if not C_Timer or not C_Timer.After or not coroutine or not coroutine.create then
        self._outpostLedgerPrepFailed = true
        return "blocked"
    end

    self._outpostLedgerPrepPending = true
    self._outpostLedgerPrepBackoff = nil
    local generation = (tonumber(self._outpostLedgerPrepGeneration) or 0) + 1
    local buildRevision = tonumber(self._outpostLedgerRevision) or 0
    self._outpostLedgerPrepGeneration = generation
    local initialBuild = not self._outpostLedgerPrepared
    local buildSource = source
    local budgetOps, budgetStarted = 0, 0
    local function clockMs()
        if debugprofilestop then return debugprofilestop() end
        return ((GetTime and GetTime()) or 0) * 1000
    end
    local function yieldWork()
        budgetOps = budgetOps + 1
        if budgetOps < 64 and (clockMs() - budgetStarted) < 1.25 then return end
        coroutine.yield()
        budgetOps, budgetStarted = 0, clockMs()
    end
    local worker = coroutine.create(function()
        budgetStarted = clockMs()
        local changed = false
        local localPool = currentSavedVarsPool()
        local tenantNeedsPool = (tonumber(OverlordDB.outpostTenantPoolVersion) or 0) < 1
        if tenantNeedsPool then
            local tenants, cursor = OverlordDB.outpostTenants, nil
            while true do
                local okNext, key, row = pcall(next, tenants, cursor)
                if not okNext then error(key) end
                cursor = key
                if key == nil then break end
                if type(row) == "table" and normalizeSavedVarsPool(row.pool) == "" then
                    row.pool, changed = localPool, true
                end
                yieldWork()
            end
        end

        local keyMigration = (tonumber(OverlordDB.outpostCaptureCountsKeyVersion) or 0) < 2
        local counts = buildSource
        if keyMigration then
            local migrated, cursor = {}, nil
            while true do
                local okNext, _, row = pcall(next, counts, cursor)
                if not okNext then error(_) end
                cursor = _
                if cursor == nil then break end
                if type(row) == "table" then
                    local siteKey = tostring(row.siteKey or "")
                    local guild = sanitizeGuildName(row.guild or "")
                    local guildKey = (row.guildKey and tostring(row.guildKey):lower()) or guild:lower()
                    local pool = resolveOutpostLbPoolTag(row.pool)
                    local key = outpostCaptureRowKey(siteKey, guildKey, pool)
                    if key ~= "" then
                        local current = migrated[key]
                        if not current then
                            migrated[key] = row
                            current = row
                        else
                            current.events = type(current.events) == "table" and current.events or {}
                            if type(row.events) == "table" then
                                for eventKey, value in pairs(row.events) do
                                    if value then current.events[eventKey] = true end
                                    yieldWork()
                                end
                            end
                            current.locAnchors = type(current.locAnchors) == "table"
                                and current.locAnchors or {}
                            if type(row.locAnchors) == "table" then
                                for totalKey, anchorTs in pairs(row.locAnchors) do
                                    local previous = tonumber(current.locAnchors[totalKey])
                                    anchorTs = tonumber(anchorTs)
                                    if anchorTs and (not previous or anchorTs < previous) then
                                        current.locAnchors[totalKey] = anchorTs
                                    end
                                    yieldWork()
                                end
                            end
                            current.count = math.max(math.floor(tonumber(current.count) or 0),
                                math.floor(tonumber(row.count) or 0))
                            current.lastTs = math.max(math.floor(tonumber(current.lastTs) or 0),
                                math.floor(tonumber(row.lastTs) or 0))
                            current.floorTs = math.max(math.floor(tonumber(current.floorTs) or 0),
                                math.floor(tonumber(row.floorTs) or 0))
                            current.eventLedgerPreparedV1 = nil
                        end
                        current.siteKey, current.guild = siteKey, guild
                        current.guildKey, current.pool = guildKey, pool
                    end
                end
                yieldWork()
            end
            counts = migrated
            -- Le marqueur reste ancien jusqu'au succes total. Une erreur/reload rejoue
            -- donc l'union idempotente sur cette nouvelle racine sans perdre un alias.
            OverlordDB.outpostCaptureCounts = counts
            changed = true
        end

        local seedLastTs = not OverlordDB._locLastTsSeeded
        local seedTs = time()
        local epoch = math.floor(tonumber(OverlordDB.lastResetTimestamp) or 0)
        local rows, cursor = {}, nil
        while true do
            local okNext, rowKey, row = pcall(next, counts, cursor)
            if not okNext then error(rowKey) end
            cursor = rowKey
            if rowKey == nil then break end
            if type(row) == "table" then
                if seedLastTs and (tonumber(row.count) or 0) > 0 and row.lastTs == nil then
                    row.lastTs, changed = seedTs, true
                end
                local beforeCount = math.floor(tonumber(row.count) or 0)
                if ensureOutpostEventLedgerV2(row, yieldWork) then changed = true end
                if recomputeOutpostEventLedger(row, yieldWork) ~= beforeCount then changed = true end
                local siteKey = tostring(row.siteKey or "")
                local guild = sanitizeGuildName(row.guild or "")
                local faction = row.faction or ""
                local count = math.floor(tonumber(row.count) or 0)
                if epoch > 0 and isValidOutpostSite(siteKey) and guild ~= "" and count > 0
                    and (faction == "Alliance" or faction == "Horde")
                    and outpostLbPoolMatchesCurrent(resolveOutpostLbPoolTag(row.pool)) then
                    local syncRow = {
                        siteKey = siteKey, guild = guild, faction = faction, count = count,
                        lastTs = math.floor(tonumber(row.lastTs) or 0), epoch = epoch, pool = row.pool,
                    }
                    syncRow._syncKey = outpostSyncStableKey(syncRow)
                    rows[#rows + 1] = syncRow
                end
            end
            yieldWork()
        end
        sortRowsWithYield(rows, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            if a.siteKey ~= b.siteKey then return a.siteKey < b.siteKey end
            if a.guild ~= b.guild then return a.guild < b.guild end
            return tostring(a.pool or "") < tostring(b.pool or "")
        end, yieldWork)

        local blocks, subPages = {}, {}
        local function stableBucket(value, bucketCount)
            local h = 5381
            value = tostring(value or "")
            for i = 1, #value do
                h = (h * 33 + string.byte(value, i)) % 2147483647
                yieldWork()
            end
            return h % bucketCount
        end
        for rowIndex, row in ipairs(rows) do
            -- Les 16 premieres lignes sont toujours emises et ne doivent pas etre
            -- recomptees dans les pages de rattrapage.
            if rowIndex > 16 then
                local bucket = stableBucket(row._syncKey, 256)
                local blockIndex = math.floor(bucket / 16) + 1
                local secondary = math.floor(stableBucket(row._syncKey, 4096) / 256) % 16 + 1
                blocks[blockIndex] = blocks[blockIndex] or {}
                subPages[blockIndex] = subPages[blockIndex] or {}
                subPages[blockIndex][secondary] = subPages[blockIndex][secondary] or {}
                blocks[blockIndex][#blocks[blockIndex] + 1] = row
                local page = subPages[blockIndex][secondary]
                page[#page + 1] = row
            end
            yieldWork()
        end
        local function lexical(a, b) return a._syncKey < b._syncKey end
        for i = 1, 16 do
            blocks[i] = blocks[i] or {}
            subPages[i] = subPages[i] or {}
            sortRowsWithYield(blocks[i], lexical, yieldWork)
            for j = 1, 16 do
                subPages[i][j] = subPages[i][j] or {}
                sortRowsWithYield(subPages[i][j], lexical, yieldWork)
            end
        end
        return { rows = rows, blocks = blocks, subPages = subPages }, counts, changed,
            tenantNeedsPool, keyMigration, seedLastTs
    end)

    local function finishFailure(err)
        if self._outpostLedgerPrepGeneration ~= generation then return end
        self._outpostLedgerPrepPending = false
        self._outpostLedgerPrepBackoff = nil
        local attempts = (tonumber(self._outpostLedgerPrepAttempts) or 0) + 1
        self._outpostLedgerPrepAttempts = attempts
        if attempts < 3 then
            self._outpostLedgerPrepRetryScheduled = true
            local delay = attempts * 5
            C_Timer.After(delay, function()
                if not Overlord.Leaderboard
                    or Overlord.Leaderboard._outpostLedgerPrepGeneration ~= generation then return end
                Overlord.Leaderboard._outpostLedgerPrepRetryScheduled = nil
                Overlord.Leaderboard:EnsureOutpostLedgerPrepared(initialBuild)
            end)
        elseif initialBuild then
            self._outpostLedgerPrepFailed = true
        else
            self._outpostLedgerMaintenanceFailed = tostring(err or "OUTPOST_LEDGER_BUILD_FAILED")
        end
    end
    local function resumeWorker()
        if self._outpostLedgerPrepGeneration ~= generation then return end
        budgetStarted = clockMs()
        local result = { coroutine.resume(worker) }
        if not result[1] then finishFailure(result[2]); return end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, resumeWorker)
            return
        end
        local snapshot, committedSource, changed = result[2], result[3], result[4]
        if type(snapshot) ~= "table" or type(committedSource) ~= "table" then
            finishFailure("OUTPOST_LEDGER_EMPTY_COMMIT")
            return
        end
        if result[5] then OverlordDB.outpostTenantPoolVersion = 1 end
        if result[6] then OverlordDB.outpostCaptureCountsKeyVersion = 2 end
        if result[7] then OverlordDB._locLastTsSeeded = true end
        self._outpostSyncSnapshot = snapshot
        self._outpostLedgerSource = committedSource
        self._outpostLedgerPrepared = true
        self._outpostLedgerPrepPending = false
        self._outpostLedgerPrepBackoff = nil
        self._outpostLedgerPrepRetryScheduled = nil
        self._outpostLedgerPrepAttempts = 0
        self._outpostLedgerMaintenanceFailed = nil
        self._outpostLedgerDirty = (tonumber(self._outpostLedgerRevision) or 0) ~= buildRevision
        if changed then self:MarkDirty() end
        if self._outpostLedgerDirty then self:RequestOutpostLedgerRebuild() end
    end
    C_Timer.After(0, resumeWorker)
    if self._outpostLedgerPrepared and not requireCurrent then return true end
    return false
end

-- Lignes LOC pour reponses SR : compteur de captures par couple (avant-poste, guilde).
-- Le compteur d'outpost n'a longtemps ete qu'additif local (OC one-shot) ; sans total sur
-- le reseau, un retardataire / cross-faction restait bloque a 0 ou 1. LOC propage le total
-- (fusionne en max() a la reception), alignant les outposts sur le modele kills (convergent).
function Overlord.Leaderboard:BuildOutpostCaptureCountSyncRows()
    local prepared = self:EnsureOutpostLedgerPrepared()
    local snapshot = self._outpostSyncSnapshot
    if prepared ~= true or type(snapshot) ~= "table" then return {}, {}, {} end
    -- Lecture handler strictement O(1). Les pages sont construites/sorties par la
    -- coroutine de preparation, jamais par la reponse SR.
    return snapshot.rows or {}, snapshot.blocks or {}, snapshot.subPages or {}
end

-- Fusion monotone d'un compteur LOC valide.
function Overlord.Leaderboard:ApplyOutpostCaptureCountSync(siteKey, guild, faction, count, latestTs, poolTag)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    count = math.floor(tonumber(count) or 0)
    latestTs = math.floor(tonumber(latestTs) or 0)
    poolTag = normalizeSavedVarsPool(poolTag) or ""
    if poolTag == "" or not outpostLbPoolMatchesCurrent(poolTag) then return false end
    if not isValidOutpostSite(siteKey) then return false end
    if guild == "" or count <= 0 or latestTs <= 0 then return false end
    -- Plafond de plausibilite (calque sur PLAUSIBLE_SYNC_KILL_CEILING des kills) : un total LOC
    -- absurde (bug local, corruption SavedVars, emetteur falsifie) serait fige partout par max()
    -- sans jamais redescendre. Un avant-poste ne peut etre capture qu'apres expiration du hold
    -- (>= 5 min), donc meme une campagne longue reste tres en dessous de ce plafond.
    if count > PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    ensureOutpostLeaderboardTables(self)
    local guildKey = guild:lower()
    local rowKey = outpostCaptureRowKey(siteKey, guildKey, poolTag)
    if rowKey == "" then return false end
    local counts = self:GetOutpostCaptureCountsTable()
    local row = counts[rowKey]
    if not row then
        row = {
            siteKey = siteKey,
            guild = guild,
            guildKey = guildKey,
            faction = faction,
            factionAt = latestTs,
            count = 0,
            lastTs = 0,
            floorTs = 0,
            events = {},
            locAnchors = {},
            eventLedgerVersion = 2,
            eventLedgerBoundsV1 = true,
            eventLedgerPreparedV1 = true,
            eventCount = 0,
            newestEventTs = 0,
            newestAnchorTs = 0,
            pool = poolTag,
        }
        counts[rowKey] = row
    end
    ensureOutpostEventLedgerV2(row)
    local current = math.floor(tonumber(row.count) or 0)
    local anchorKey = tostring(count)
    local previousAnchor = tonumber(row.locAnchors[anchorKey])
    local anchorChanged = false
    if not previousAnchor or latestTs < previousAnchor then
        row.locAnchors[anchorKey] = latestTs
        row.newestAnchorTs = math.max(
            math.floor(tonumber(row.newestAnchorTs) or 0), latestTs)
        anchorChanged = true
    end
    local mergedCount = math.max(current, count)
    row.count = mergedCount
    row.floorTs = math.max(math.floor(tonumber(row.floorTs) or 0), latestTs)
    row.lastTs = math.max(math.floor(tonumber(row.lastTs) or 0), latestTs)
    row.guild = guild
    local factionChanged = mergeOutpostRowFaction(row, faction, latestTs)
    row.pool = poolTag
    if anchorChanged or mergedCount > current or factionChanged then
        self:MarkDirty()
        self:RequestOutpostLedgerRebuild()
    end
    return anchorChanged or mergedCount > current or factionChanged
end

-- Applique un identifiant CRDT OE deja confirme par trois expediteurs distincts.
-- kind="E" : captureTs ; kind="A" : total + latestTs de l'ancre.
function Overlord.Leaderboard:ApplyOutpostLedgerProofSync(
    siteKey, guild, faction, poolTag, kind, value, proofTs)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    poolTag = normalizeSavedVarsPool(poolTag) or ""
    value = math.floor(tonumber(value) or 0)
    proofTs = math.floor(tonumber(proofTs) or 0)
    if not isValidOutpostSite(siteKey) or guild == "" or poolTag == ""
        or not outpostLbPoolMatchesCurrent(poolTag)
        or (faction ~= "Alliance" and faction ~= "Horde") then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if proofTs <= 0 or not self:IsTimestampInCurrentCampaign(proofTs, campaignStart)
        or proofTs > leaderboardServerNow() + 300 then return false end
    if kind == "A" and (value <= 0 or value > PLAUSIBLE_OUTPOST_CAPTURE_COUNT) then return false end
    if kind == "E" then value = proofTs end
    if kind ~= "A" and kind ~= "E" then return false end

    ensureOutpostLeaderboardTables(self)
    local guildKey = guild:lower()
    local rowKey = outpostCaptureRowKey(siteKey, guildKey, poolTag)
    if rowKey == "" then return false end
    local counts = self:GetOutpostCaptureCountsTable()
    local row = counts[rowKey]
    if not row then
        row = {
            siteKey = siteKey, guild = guild, guildKey = guildKey, faction = faction,
            factionAt = proofTs,
            count = 0, lastTs = 0, floorTs = 0, events = {}, locAnchors = {},
            eventLedgerVersion = 2, eventLedgerBoundsV1 = true,
            eventLedgerPreparedV1 = true, eventCount = 0,
            newestEventTs = 0, newestAnchorTs = 0, pool = poolTag,
        }
        counts[rowKey] = row
    end
    ensureOutpostEventLedgerV2(row)
    local previousCount = math.floor(tonumber(row.count) or 0)
    local changed = false
    if kind == "E" then
        local eventKey = tostring(proofTs)
        if not row.events[eventKey] then
            if math.floor(tonumber(row.count) or 0) >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
            if countOutpostEvents(row) >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
            row.events[eventKey], changed = true, true
            noteOutpostEventAdded(row, proofTs)
        end
    else
        local anchorKey = tostring(value)
        local previousTs = tonumber(row.locAnchors[anchorKey])
        if not previousTs or proofTs < previousTs then
            row.locAnchors[anchorKey], changed = proofTs, true
            row.newestAnchorTs = math.max(
                math.floor(tonumber(row.newestAnchorTs) or 0), proofTs)
            row.count = math.max(math.floor(tonumber(row.count) or 0), value)
        end
    end
    local mergedCount = math.floor(tonumber(row.count) or 0)
    row.guild, row.guildKey, row.pool = guild, guildKey, poolTag
    local factionChanged = mergeOutpostRowFaction(row, faction, proofTs)
    if changed or mergedCount > previousCount or factionChanged then
        self:MarkDirty()
        self:RequestOutpostLedgerRebuild()
    end
    return changed or mergedCount > previousCount or factionChanged
end

function Overlord.Leaderboard:GetGuildKeepSiegeWinAwardsTable()
    if not OverlordDB then return {} end
    ensureGuildKeepLeaderboardTables(self)
    return OverlordDB.guildKeepSiegeWinAwards
end

local function normalizeGuildKeepDailyProof(lb, siteKey, dayKey, row)
    if type(row) ~= "table" then return nil end
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey or not gk.AssaultIdentityWins
        or not gk.GetAssaultAttemptStartedAt then return nil end
    siteKey, dayKey = tostring(siteKey or ""), tostring(dayKey or "")
    if not isValidGuildKeepSite(siteKey)
        or not isGuildKeepSiegeKey(dayKey) then return nil end
    local kind = row.kind
    local guild = sanitizeGuildName(row.guild or "")
    local faction = row.faction
    local shard = tonumber(row.shard)
    local rawStartedAt = tonumber(row.startedAt)
    local rawGenerationAt = tonumber(row.generationAt)
    local rawEventAt = tonumber(row.eventAt)
    local startedAt = math.floor(rawStartedAt or 0)
    local generationAt = math.floor(rawGenerationAt or -1)
    local player = tostring(row.player or ""):match("^%s*(.-)%s*$") or ""
    local eventAt = math.floor(rawEventAt or 0)
    local baseGuild = sanitizeGuildName(row.baseGuild or "")
    local baseFaction = row.baseFaction
    local rawBaseCapturedAt = tonumber(row.baseCapturedAt)
    local baseCapturedAt = math.floor(rawBaseCapturedAt or 0)
    local pool = normalizeSavedVarsPool(row.pool) or ""
    local campaignStart = lb and lb.GetCurrentCampaignStart and lb:GetCurrentCampaignStart() or 0
    local site = gk.GetSite and gk:GetSite(siteKey) or nil
    local required = gk.GetDefaultHoldTimeRequired
        and math.floor(tonumber(gk:GetDefaultHoldTimeRequired(nil, site)) or 900) or 900
    local maxTimestamp = leaderboardServerNow() + 300
    if (kind ~= "GC" and kind ~= "GA")
        or not shard or shard ~= math.floor(shard)
        or rawStartedAt ~= startedAt or rawGenerationAt ~= generationAt
        or rawEventAt ~= eventAt or rawBaseCapturedAt ~= baseCapturedAt
        or startedAt <= 0 or startedAt > maxTimestamp
        or generationAt < 0 or generationAt > 1000000
        or eventAt <= 0 or eventAt > maxTimestamp
        or baseCapturedAt < 0 or baseCapturedAt > maxTimestamp then return nil end
    local attemptStartedAt = math.floor(tonumber(
        gk:GetAssaultAttemptStartedAt(startedAt, generationAt)) or 0)
    local startedDay = gk:GetServerSiegeDayKey(startedAt)
    local eventDay = gk:GetServerSiegeDayKey(eventAt)
    local validIdentity = gk:AssaultIdentityWins(
        guild, faction, shard, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        "", nil, nil, 0, 0, "", "", nil, 0)
    if not validIdentity or attemptStartedAt <= 0 or eventAt < attemptStartedAt
        or not lb:IsTimestampInCurrentCampaign(startedAt, campaignStart)
        or not lb:IsTimestampInCurrentCampaign(attemptStartedAt, campaignStart)
        or not lb:IsTimestampInCurrentCampaign(eventAt, campaignStart)
        or (baseCapturedAt > 0
            and not lb:IsTimestampInCurrentCampaign(baseCapturedAt, campaignStart))
        or (gk.IsSiegeGameplayTimestampAllowed
            and not gk:IsSiegeGameplayTimestampAllowed(startedAt))
        or (kind == "GC" and ((eventAt - attemptStartedAt) < math.max(0, required - 1)
            or (gk.IsSiegeCaptureTimestampAllowed
                and not gk:IsSiegeCaptureTimestampAllowed(eventAt))))
        or startedDay ~= eventDay or startedDay > dayKey or eventDay > dayKey
        or pool == "" or not guildKeepLbPoolMatchesCurrent(pool) then return nil end

    local status, resultGuild, resultFaction, claimedAt
    if kind == "GC" then
        status, resultGuild, resultFaction, claimedAt = "held", guild, faction, eventAt
    elseif baseGuild ~= "" then
        status, resultGuild, resultFaction, claimedAt =
            "held", baseGuild, baseFaction, baseCapturedAt
    else
        status, resultGuild, resultFaction, claimedAt = "neutral", "", nil, 0
    end
    return {
        kind = kind, eventAt = eventAt, guild = guild, faction = faction,
        shard = shard, startedAt = startedAt, generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction, baseCapturedAt = baseCapturedAt,
        status = status, resultGuild = resultGuild,
        resultGuildKey = resultGuild:lower(), resultFaction = resultFaction,
        claimedAt = claimedAt, pool = pool,
    }
end

local function guildKeepDailyProofWins(candidate, current)
    if not candidate then return false end
    if not current then return true end
    local gk = Overlord.GuildKeep
    return gk and gk.AssaultResolutionWins and gk:AssaultResolutionWins({
        kind = candidate.kind, eventAt = candidate.eventAt,
        guild = candidate.guild, faction = candidate.faction,
        shard = candidate.shard, startedAt = candidate.startedAt,
        generationAt = candidate.generationAt, player = candidate.player,
        baseGuild = candidate.baseGuild, baseFaction = candidate.baseFaction,
        baseCapturedAt = candidate.baseCapturedAt,
    }, {
        kind = current.kind, eventAt = current.eventAt,
        guild = current.guild, faction = current.faction,
        shard = current.shard, startedAt = current.startedAt,
        generationAt = current.generationAt, player = current.player,
        baseGuild = current.baseGuild, baseFaction = current.baseFaction,
        baseCapturedAt = current.baseCapturedAt,
    }) or false
end

local function guildKeepDailyProofMatches(a, b)
    if not a or not b then return false end
    return a.kind == b.kind and a.eventAt == b.eventAt
        and a.guild:lower() == b.guild:lower() and a.faction == b.faction
        and a.shard == b.shard and a.startedAt == b.startedAt
        and a.generationAt == b.generationAt
        and a.player:lower() == b.player:lower()
        and a.baseGuild:lower() == b.baseGuild:lower()
        and a.baseFaction == b.baseFaction
        and a.baseCapturedAt == b.baseCapturedAt and a.pool == b.pool
end

-- Registre brut GH : un seul winner total-order par keep/jour. Il ne doit jamais etre
-- reecrit par une correction d'un autre jour, sinon un GA J1 arrive apres coup ne peut plus
-- restaurer le vrai GC J2 qui avait ete ecrase. Les pairs echangent toujours cette forme.
local function getRawGuildKeepDailyProofForDay(lb, siteKey, dayKey)
    if not isGuildKeepDailyProofCampaignActive(lb) then return nil end
    local snapshots = OverlordDB and OverlordDB.guildKeepCutoffSnapshots
    local snapByDay = type(snapshots) == "table" and snapshots[tostring(dayKey or "")]
    local row = type(snapByDay) == "table" and snapByDay[tostring(siteKey or "")] or nil
    return normalizeGuildKeepDailyProof(lb, siteKey, dayKey, row)
end

local function guildKeepTenureKey(guild, faction, capturedAt)
    guild = sanitizeGuildName(guild or "")
    capturedAt = math.floor(tonumber(capturedAt) or 0)
    if guild == "" or capturedAt <= 0
        or (faction ~= "Alliance" and faction ~= "Horde") then return "" end
    return guild:lower() .. "\31" .. faction .. "\31" .. tostring(capturedAt)
end

local GK_DAILY_PROOF_BASES_MAX = 6

local function guildKeepDailyProofBaseKey(proof)
    if not proof then return nil end
    if proof.baseGuild == "" and proof.baseCapturedAt == 0 then return "_neutral" end
    local key = guildKeepTenureKey(
        proof.baseGuild, proof.baseFaction, proof.baseCapturedAt)
    return key ~= "" and key or nil
end

-- Le meme tri est utilise a l'ecriture et pour les projections hypothetiques. Sans cette
-- frontiere commune, une septieme branche rejetee du disque pouvait encore influencer
-- WouldGuildKeepCaptureWinOwnDay, puis produire un terrain different apres Apply.
local function pruneGuildKeepDailyProofCandidatesByBase(byBase)
    local keys = {}
    for baseKey in pairs(byBase or {}) do keys[#keys + 1] = baseKey end
    table.sort(keys, function(a, b)
        local ar, br = byBase[a], byBase[b]
        local at = math.floor(tonumber(ar and ar.baseCapturedAt) or 0)
        local bt = math.floor(tonumber(br and br.baseCapturedAt) or 0)
        if at ~= bt then return at < bt end
        return a < b
    end)
    for i = GK_DAILY_PROOF_BASES_MAX + 1, #keys do
        byBase[keys[i]] = nil
    end
    return keys
end

local function copyGuildKeepDailyProofRow(proof)
    if not proof then return nil end
    return {
        kind = proof.kind, eventAt = proof.eventAt,
        guild = proof.guild, faction = proof.faction,
        shard = proof.shard, startedAt = proof.startedAt,
        generationAt = proof.generationAt, player = proof.player,
        baseGuild = proof.baseGuild, baseFaction = proof.baseFaction,
        baseCapturedAt = proof.baseCapturedAt, pool = proof.pool,
    }
end

-- Frontiere publique unique pour le wire GH : un transport historique approuve ne doit
-- jamais contourner les memes validations root+offset que le registre persistant.
function Overlord.Leaderboard:NormalizeGuildKeepDailyProof(siteKey, dayKey, row)
    return normalizeGuildKeepDailyProof(self, siteKey, dayKey, row)
end

-- Un winner pur PAR tenure de depart. Garder uniquement le winner global perdait une
-- branche valide E(base X) derriere une branche D(base C) ensuite invalidee par le fold.
-- Six bases couvrent les quatre recaptures physiques possibles dans l'heure plus deux
-- branches concurrentes. Le pire cas campagne (6 keeps x 7 jours x 6) reste aussi sous
-- le cache GH de 256 entre les deux vagues, tout en
-- bornant SavedVariables et les reponses SR.
local function getRawGuildKeepDailyProofCandidatesForDay(
    lb, siteKey, dayKey, snapshotsOverride, yieldWork)
    if not isGuildKeepDailyProofCampaignActive(lb) then return {} end
    siteKey, dayKey = tostring(siteKey or ""), tostring(dayKey or "")
    local snapshots = snapshotsOverride or (OverlordDB and OverlordDB.guildKeepCutoffSnapshots)
    local snapshot = type(snapshots) == "table" and snapshots[dayKey] or nil
    local stored = type(snapshot) == "table" and snapshot[siteKey] or nil
    if type(stored) ~= "table" then return {} end
    local byBase = {}
    local function consider(raw)
        local proof = normalizeGuildKeepDailyProof(lb, siteKey, dayKey, raw)
        local baseKey = guildKeepDailyProofBaseKey(proof)
        local current = baseKey and byBase[baseKey] or nil
        if baseKey and (not current or guildKeepDailyProofWins(proof, current)) then
            byBase[baseKey] = proof
        end
    end
    consider(stored)
    if type(stored.byBase) == "table" then
        for _, raw in pairs(stored.byBase) do
            consider(raw)
            if yieldWork then yieldWork() end
        end
    end
    pruneGuildKeepDailyProofCandidatesByBase(byBase)
    local keys = {}
    for baseKey in pairs(byBase) do
        keys[#keys + 1] = baseKey
        if yieldWork then yieldWork() end
    end
    table.sort(keys)
    local rows = {}
    for _, baseKey in ipairs(keys) do rows[#rows + 1] = byBase[baseKey] end
    return rows
end

-- Projection reversible des registres bruts. Le fold est minuscule (au plus les jours de
-- la campagne pour un keep) et resout le cas partitionne sans nouveau protocole :
--   A=GC J1 rend C=GC J2 sur l'ancienne base impossible ;
--   si B=GA J1, ancre gagnante, remplace ensuite A dans le registre brut J1, C redevient
--   automatiquement valide puisque le brut J2 n'a jamais ete detruit.
local function getGuildKeepDailyProofForDay(
    lb, siteKey, dayKey, overlay, snapshotsOverride, dayIndexOverride, yieldWork)
    if not isGuildKeepDailyProofCampaignActive(lb) then return nil end
    siteKey, dayKey = tostring(siteKey or ""), tostring(dayKey or "")
    local snapshots = snapshotsOverride or (OverlordDB and OverlordDB.guildKeepCutoffSnapshots)
    if type(snapshots) ~= "table" then return nil end
    local dayIndex = dayIndexOverride or lb._guildKeepProofDaysBySite
    if not dayIndexOverride and (not lb._guildKeepProofLedgerPrepared
        or type(dayIndex) ~= "table") then
        if lb.EnsureGuildKeepProofLedgerPrepared then
            lb:EnsureGuildKeepProofLedgerPrepared(false)
        end
        return nil
    end
    local days, daySeen, targetHasProof = {}, {}, false
    for _, candidateDay in ipairs(dayIndex[siteKey] or {}) do
        if candidateDay <= dayKey then
            days[#days + 1] = candidateDay
            daySeen[candidateDay] = true
        end
    end
    if overlay and overlay.dayKey and overlay.dayKey <= dayKey
        and not daySeen[overlay.dayKey] then
        days[#days + 1] = overlay.dayKey
        daySeen[overlay.dayKey] = true
        -- Index campagne borne (7 jours) : insertion stable sans table.sort.
        local insertAt = #days
        while insertAt > 1 and days[insertAt] < days[insertAt - 1] do
            days[insertAt], days[insertAt - 1] = days[insertAt - 1], days[insertAt]
            insertAt = insertAt - 1
        end
    end

    local current
    local currentProofDay = ""
    local overlayConsumed = false
    local function currentTenureKey()
        if current and current.status == "held" then
            local key = guildKeepTenureKey(
                current.resultGuild, current.resultFaction, current.claimedAt)
            if key ~= "" then return key end
        end
        return "_neutral"
    end
    for _, candidateDay in ipairs(days) do
        local candidates = getRawGuildKeepDailyProofCandidatesForDay(
            lb, siteKey, candidateDay, snapshotsOverride, yieldWork)
        if overlay and overlay.dayKey == candidateDay and overlay.proof then
            local byBase = {}
            for _, proof in ipairs(candidates) do
                local baseKey = guildKeepDailyProofBaseKey(proof)
                if baseKey then byBase[baseKey] = proof end
            end
            local overlayKey = guildKeepDailyProofBaseKey(overlay.proof)
            local previous = overlayKey and byBase[overlayKey] or nil
            if overlayKey and (not previous
                or guildKeepDailyProofWins(overlay.proof, previous)) then
                byBase[overlayKey] = overlay.proof
            end
            pruneGuildKeepDailyProofCandidatesByBase(byBase)
            candidates = {}
            for _, proof in pairs(byBase) do candidates[#candidates + 1] = proof end
        end
        if #candidates > 0 then
            if candidateDay == dayKey then targetHasProof = true end
            local remaining = {}
            for _, candidate in ipairs(candidates) do
                local baseKey = guildKeepDailyProofBaseKey(candidate)
                -- Un assaut ancre avant le terminal effectif courant ne peut plus etre
                -- son descendant. Le filtrer ici evite qu'un paquet stale consomme une
                -- iteration du petit fold et masque une branche intermediaire valide.
                if baseKey and (not current
                    or guildKeepDailyProofMatches(candidate, current)
                    or candidate.startedAt >= current.eventAt) then
                    remaining[baseKey] = candidate
                end
            end

            -- Le snapshot quotidien peut contenir le terminal de defense (A, base X)
            -- et une nouvelle attaque (B, base A). Consommer d'abord la repetition exacte,
            -- puis suivre la chaine de bases, une capture a la fois.
            if current then
                for baseKey, candidate in pairs(remaining) do
                    if guildKeepDailyProofMatches(candidate, current) then
                        if overlay and overlay.proof
                            and guildKeepDailyProofMatches(candidate, overlay.proof) then
                            overlayConsumed = true
                        end
                        remaining[baseKey] = nil
                        break
                    end
                end
            end

            local transitioned = false
            for _ = 1, GK_DAILY_PROOF_BASES_MAX do
                local baseKey = currentTenureKey()
                local candidate = remaining[baseKey]
                if not candidate then
                    -- Rattrapage d'une tenure intermediaire dont aucun cutoff n'est connu.
                    -- Des qu'un jour deja scelle contredit cette base, elle n'est plus
                    -- admissible. Ne faire ce saut qu'avant toute transition explicite du jour.
                    if transitioned then break end
                    for candidateKey, possible in pairs(remaining) do
                        local baseDay = possible.baseCapturedAt > 0
                            and Overlord.GuildKeep:GetServerSiegeDayKey(
                                possible.baseCapturedAt) or ""
                        local contradiction = baseDay ~= "" and currentProofDay ~= ""
                            and currentProofDay >= baseDay and candidateKey ~= baseKey
                        if not contradiction and (not candidate
                            or guildKeepDailyProofWins(possible, candidate)) then
                            candidate, baseKey = possible, candidateKey
                        end
                    end
                end
                if not candidate then break end
                remaining[baseKey] = nil
                if not current or candidate.startedAt >= current.eventAt then
                    current = candidate
                    transitioned = true
                    if overlay and overlay.proof
                        and guildKeepDailyProofMatches(candidate, overlay.proof) then
                        overlayConsumed = true
                    end
                    if candidate.kind ~= "GC" then break end
                end
            end
            currentProofDay = candidateDay
        end
        if yieldWork then yieldWork() end
    end
    return targetHasProof and current or nil, overlayConsumed
end

function Overlord.Leaderboard:GetGuildKeepDailyProofForDay(siteKey, dayKey)
    return getGuildKeepDailyProofForDay(self, siteKey, dayKey)
end

function Overlord.Leaderboard:GetRawGuildKeepDailyProofForDay(siteKey, dayKey)
    return getRawGuildKeepDailyProofForDay(self, siteKey, dayKey)
end

function Overlord.Leaderboard:GetRawGuildKeepDailyProofCandidatesForDay(siteKey, dayKey)
    return getRawGuildKeepDailyProofCandidatesForDay(self, siteKey, dayKey)
end

function Overlord.Leaderboard:WouldGuildKeepCaptureWinOwnDay(siteKey, capture)
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey or type(capture) ~= "table" then return false end
    local dayKey = gk:GetServerSiegeDayKey(capture.eventAt)
    local candidate = normalizeGuildKeepDailyProof(self, siteKey, dayKey, capture)
    if not candidate then return false end
    local candidateBase = guildKeepDailyProofBaseKey(candidate)
    local byBase = {}
    for _, raw in ipairs(getRawGuildKeepDailyProofCandidatesForDay(
        self, siteKey, dayKey)) do
        local baseKey = guildKeepDailyProofBaseKey(raw)
        if baseKey then byBase[baseKey] = raw end
    end
    local previous = candidateBase and byBase[candidateBase] or nil
    if not candidateBase or (previous
        and not guildKeepDailyProofMatches(candidate, previous)
        and not guildKeepDailyProofWins(candidate, previous)) then return false end
    byBase[candidateBase] = candidate
    pruneGuildKeepDailyProofCandidatesByBase(byBase)
    if not byBase[candidateBase] then return false end
    local projected, candidateConsumed = getGuildKeepDailyProofForDay(self, siteKey, dayKey, {
        dayKey = dayKey, proof = candidate,
    })
    -- Une correction intermediaire A peut etre indispensable a la chaine A -> B tout en
    -- n'etant pas le terminal final B du jour. Ce qui compte pour le rebase live est que A
    -- ait reellement ete consommee par la projection bornee, pas qu'elle soit la derniere.
    return projected ~= nil and candidateConsumed
end

local function getGuildKeepCanonicalTenantForDay(lb, siteKey, dayKey)
    local sealed = getGuildKeepDailyProofForDay(lb, siteKey, dayKey)
    if sealed and sealed.status == "held" then
        return {
            guild = sealed.resultGuild, guildKey = sealed.resultGuildKey,
            faction = sealed.resultFaction, claimedAt = sealed.claimedAt, pool = sealed.pool,
            proof = sealed,
        }
    end
    return nil
end

function Overlord.Leaderboard:GetCanonicalGuildKeepTenantForDay(siteKey, dayKey)
    return getGuildKeepCanonicalTenantForDay(self, tostring(siteKey or ""), tostring(dayKey or ""))
end

function Overlord.Leaderboard:ApplyGuildKeepDailyProofSync(
    siteKey, dayKey, kind, eventAt, guild, faction, shard, startedAt,
    generationAt, player, baseGuild, baseFaction, baseCapturedAt, poolTag)
    if not isGuildKeepDailyProofCampaignActive(self) then return false end
    local candidate = normalizeGuildKeepDailyProof(self, siteKey, dayKey, {
        kind = kind, eventAt = eventAt, guild = guild, faction = faction,
        shard = shard, startedAt = startedAt, generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt, pool = poolTag,
    })
    local gk = Overlord.GuildKeep
    if not candidate or not isGuildKeepWinDayClosed(gk, tostring(dayKey or "")) then return false end

    ensureGuildKeepLeaderboardTables(self)
    local snapshots = OverlordDB.guildKeepCutoffSnapshots
    local snap = snapshots[dayKey]
    if type(snap) ~= "table" then
        snap = {}
        snapshots[dayKey] = snap
    end
    local byBase, baseCount = {}, 0
    for _, raw in ipairs(getRawGuildKeepDailyProofCandidatesForDay(
        self, siteKey, dayKey)) do
        local baseKey = guildKeepDailyProofBaseKey(raw)
        if baseKey and not byBase[baseKey] then
            byBase[baseKey] = copyGuildKeepDailyProofRow(raw)
            baseCount = baseCount + 1
        end
    end
    local candidateBase = guildKeepDailyProofBaseKey(candidate)
    if not candidateBase then return false end
    local previousBase = normalizeGuildKeepDailyProof(
        self, siteKey, dayKey, byBase[candidateBase])
    if previousBase and not guildKeepDailyProofWins(candidate, previousBase) then
        return false
    end
    if not previousBase then baseCount = baseCount + 1 end
    byBase[candidateBase] = copyGuildKeepDailyProofRow(candidate)

    if baseCount > GK_DAILY_PROOF_BASES_MAX then
        pruneGuildKeepDailyProofCandidatesByBase(byBase)
        if not byBase[candidateBase] then return false end
    end

    local winner
    for _, raw in pairs(byBase) do
        local proof = normalizeGuildKeepDailyProof(self, siteKey, dayKey, raw)
        if proof and (not winner or guildKeepDailyProofWins(proof, winner)) then
            winner = proof
        end
    end
    if not winner then return false end
    local storedWinner = copyGuildKeepDailyProofRow(winner)
    storedWinner.byBase = byBase
    snap[siteKey] = storedWinner
    self:MarkDirty()
    if self.RequestGuildKeepProofLedgerRebuild then
        self:RequestGuildKeepProofLedgerRebuild(siteKey, tostring(dayKey or ""))
    end
    if self.InvalidateGuildKeepDailyAwardStable then
        self:InvalidateGuildKeepDailyAwardStable()
    end
    if gk.InvalidateOfficialKeepTenantCache then
        gk:InvalidateOfficialKeepTenantCache(siteKey)
    end

    return true
end

function Overlord.Leaderboard:BuildGuildKeepDailyProofForState(siteKey, dayKey)
    local gk = Overlord.GuildKeep
    local st = gk and gk.GetState and gk:GetState(siteKey)
    local terminal = st and gk.GetCurrentTerminalProof and gk:GetCurrentTerminalProof(st)
    if not terminal then return nil end
    terminal.pool = terminal.pool ~= "" and terminal.pool or currentSavedVarsPool()
    return normalizeGuildKeepDailyProof(self, siteKey, dayKey, terminal)
end

-- Une correction live tardive scelle le GC dans le registre brut de SON jour. La projection
-- ci-dessus recalcule les jours suivants sans les ecraser : elle reste donc reversible si le
-- vrai winner concurrent de J1 (par exemple un GA) arrive ensuite.
function Overlord.Leaderboard:RepairGuildKeepDailyProofsAfterLineageCorrection(siteKey)
    if not isGuildKeepDailyProofCampaignActive(self) then return false end
    local gk = Overlord.GuildKeep
    local st = gk and gk.GetState and gk:GetState(siteKey)
    local terminal = st and gk.GetCurrentTerminalProof and gk:GetCurrentTerminalProof(st)
    if not terminal or terminal.kind ~= "GC" then return false end
    terminal.pool = terminal.pool ~= "" and terminal.pool or currentSavedVarsPool()
    local terminalDay = gk.GetServerSiegeDayKey
        and gk:GetServerSiegeDayKey(terminal.eventAt) or ""
    local applied = self:ApplyGuildKeepDailyProofSync(
        siteKey, terminalDay, terminal.kind, terminal.eventAt,
        terminal.guild, terminal.faction, terminal.shard,
        terminal.startedAt, terminal.generationAt, terminal.player,
        terminal.baseGuild, terminal.baseFaction,
        terminal.baseCapturedAt, terminal.pool)
    local changed = applied
    if self.ReconcileGuildKeepDailyAwardsFromDay
        and self:ReconcileGuildKeepDailyAwardsFromDay(siteKey, terminalDay) then
        changed = true
    end
    local terminalProof = normalizeGuildKeepDailyProof(
        self, siteKey, terminalDay, terminal)
    local hasTerminal = false
    for _, raw in ipairs(getRawGuildKeepDailyProofCandidatesForDay(
        self, siteKey, terminalDay)) do
        if guildKeepDailyProofMatches(raw, terminalProof) then
            hasTerminal = true
            break
        end
    end
    if hasTerminal
        and self.ShouldBroadcastLocalGuildKeepProof
        and self:ShouldBroadcastLocalGuildKeepProof(terminalProof, siteKey)
        and Overlord.Sync and Overlord.Sync.BroadcastGuildKeepDailyProof then
        Overlord.Sync:BroadcastGuildKeepDailyProof(siteKey, terminalDay, applied)
    end
    return changed
end

function Overlord.Leaderboard:BuildGuildKeepDailyProofSyncRows()
    local prepared = self:EnsureGuildKeepProofLedgerPrepared(false)
    if prepared ~= true then return {} end
    return self._guildKeepProofSyncRows or {}
end

function Overlord.Leaderboard:RequestGuildKeepProofLedgerRebuild(siteKey, dayKey)
    self._guildKeepProofLedgerRevision =
        (tonumber(self._guildKeepProofLedgerRevision) or 0) + 1
    self._guildKeepProofLedgerDirty = true
    -- L'index de jours deja publie peut etre complete en O(7) sans scanner la racine.
    local index = self._guildKeepProofDaysBySite
    siteKey, dayKey = tostring(siteKey or ""), tostring(dayKey or "")
    if self._guildKeepProofLedgerPrepared and type(index) == "table"
        and isValidGuildKeepSite(siteKey) and isGuildKeepSiegeKey(dayKey) then
        local days = index[siteKey]
        if not days then days = {}; index[siteKey] = days end
        local seen = false
        for _, existing in ipairs(days) do if existing == dayKey then seen = true; break end end
        if not seen then
            local insertAt = #days + 1
            while insertAt > 1 and days[insertAt - 1] > dayKey do
                days[insertAt] = days[insertAt - 1]
                insertAt = insertAt - 1
            end
            days[insertAt] = dayKey
        end
    end
    if not self._guildKeepProofLedgerPrepared or self._guildKeepProofLedgerPrepPending
        or self._guildKeepProofLedgerRetryScheduled or self._guildKeepProofLedgerWakePending
        or not C_Timer or not C_Timer.After then return end
    self._guildKeepProofLedgerWakePending = true
    C_Timer.After(0, function()
        if not Overlord.Leaderboard then return end
        Overlord.Leaderboard._guildKeepProofLedgerWakePending = nil
        Overlord.Leaderboard:EnsureGuildKeepProofLedgerPrepared(false)
    end)
end

-- Sanitation/index GH requise avant Sync. Les quatre racines sont reconstruites hors
-- handlers, puis publiees ensemble ; une mutation concurrente annule le commit afin de
-- ne jamais perdre un terminal ou un award arrive pendant une tranche.
function Overlord.Leaderboard:EnsureGuildKeepProofLedgerPrepared(requireCurrent)
    if not OverlordDB or not Overlord.GuildKeep then return "blocked" end
    ensureGuildKeepLeaderboardTables(self)
    local sourceSnapshots = OverlordDB.guildKeepCutoffSnapshots
    local sourceLegacySnapshots = OverlordDB.guildKeepProtocol7SnapshotsPending
    local sourceTenants = OverlordDB.guildKeepTenants
    local sourceOfficial = OverlordDB.guildKeepOfficialTenants
    local sourceAwards = OverlordDB.guildKeepSiegeWinAwards
    if self._guildKeepProofLedgerSource ~= sourceSnapshots
        or self._guildKeepProofLegacySource ~= sourceLegacySnapshots then
        self._guildKeepProofLedgerPrepared = false
        self._guildKeepProofLedgerDirty = true
        self._guildKeepProofLedgerFailed = nil
    end
    if self._guildKeepProofLedgerFailed then return "blocked" end
    if self._guildKeepProofLedgerPrepPending then
        if self._guildKeepProofLedgerPrepared and not requireCurrent then return true end
        return false
    end
    if self._guildKeepProofLedgerRetryScheduled then
        if self._guildKeepProofLedgerPrepared and not requireCurrent then return true end
        return "waiting"
    end
    if self._guildKeepProofLedgerPrepared and not self._guildKeepProofLedgerDirty then return true end
    if not C_Timer or not C_Timer.After or not coroutine or not coroutine.create then
        self._guildKeepProofLedgerFailed = true
        return "blocked"
    end

    self._guildKeepProofLedgerPrepPending = true
    local generation = (tonumber(self._guildKeepProofLedgerGeneration) or 0) + 1
    local buildRevision = tonumber(self._guildKeepProofLedgerRevision) or 0
    local initialBuild = not self._guildKeepProofLedgerPrepared
    self._guildKeepProofLedgerGeneration = generation
    local budgetOps, budgetStarted = 0, 0
    local function clockMs()
        if debugprofilestop then return debugprofilestop() end
        return ((GetTime and GetTime()) or 0) * 1000
    end
    local function yieldWork()
        budgetOps = budgetOps + 1
        if budgetOps < 64 and (clockMs() - budgetStarted) < 1.25 then return end
        coroutine.yield()
        budgetOps, budgetStarted = 0, clockMs()
    end
    local worker = coroutine.create(function()
        budgetStarted = clockMs()
        local migrationFrom = normalizeSavedVarsPool(
            self._guildKeepLbMigrationFrom
                or (OverlordDB and OverlordDB.guildKeepLbMigrationFrom))
        local currentPool = currentSavedVarsPool()
        local function filterSiteRoot(source)
            local target = {}
            for key in pairs(Overlord.GuildKeepSites or {}) do
                local row = source[key]
                if type(row) == "table" then
                    local pool = normalizeSavedVarsPool(row.pool)
                    if migrationFrom ~= "" and pool == migrationFrom then
                        row.pool = currentPool
                        pool = currentPool
                    end
                    local valid = getValidGuildKeepTenantRow(self, key, row)
                    if valid and guildKeepLbPoolMatchesCurrent(pool) then target[key] = row end
                end
                yieldWork()
            end
            return target
        end
        local tenants = filterSiteRoot(sourceTenants)
        local official = filterSiteRoot(sourceOfficial)

        local compact, daysBySite, syncRows = {}, {}, {}
        local epoch = math.floor(tonumber(OverlordDB.lastResetTimestamp) or 0)
        local allowedDays = {}
        local nowTs = leaderboardServerNow()
        for dayOffset = 0, 36 do
            local key = Overlord.GuildKeep:GetServerSiegeDayKey(nowTs - dayOffset * 21600)
            if type(key) == "string" and isGuildKeepSiegeKey(key) then
                allowedDays[key] = true
            end
        end
        local snapshotSources = { { root = sourceSnapshots, legacy = false } }
        if type(sourceLegacySnapshots) == "table"
            and sourceLegacySnapshots ~= sourceSnapshots then
            snapshotSources[#snapshotSources + 1] = {
                root = sourceLegacySnapshots, legacy = true,
            }
        end
        for _, snapshotSource in ipairs(snapshotSources) do
        local snapshotRoot, legacyOnly = snapshotSource.root, snapshotSource.legacy
        local dayCursor = nil
        while true do
            local okDay, dayKey, snapshot = pcall(next, snapshotRoot, dayCursor)
            if not okDay then error(dayKey) end
            dayCursor = dayKey
            if dayKey == nil then break end
            dayKey = tostring(dayKey or "")
            if allowedDays[dayKey] and type(snapshot) == "table" then
                local siteCursor = nil
                while true do
                    local okSite, siteKey, stored = pcall(next, snapshot, siteCursor)
                    if not okSite then error(siteKey) end
                    siteCursor = siteKey
                    if siteKey == nil then break end
                    siteKey = tostring(siteKey or "")
                    if siteKey == "elwynn" then siteKey = "redridge"
                    elseif siteKey == "echo_isles" then siteKey = "crossroads" end
                    if isValidGuildKeepSite(siteKey) and type(stored) == "table" then
                        local byBase, baseCount = {}, 0
                        local function retainedBefore(aKey, a, bKey, b)
                            local at = math.floor(tonumber(a and a.baseCapturedAt) or 0)
                            local bt = math.floor(tonumber(b and b.baseCapturedAt) or 0)
                            return at ~= bt and at < bt or (at == bt and aKey < bKey)
                        end
                        local function consider(raw, requireGenerationZero)
                            if type(raw) ~= "table" then return end
                            if requireGenerationZero and tonumber(raw.generationAt) ~= 0 then return end
                            if migrationFrom ~= ""
                                and normalizeSavedVarsPool(raw.pool) == migrationFrom then
                                raw = copyGuildKeepDailyProofRow(raw)
                                raw.pool = currentPool
                            end
                            local proof = normalizeGuildKeepDailyProof(self, siteKey, dayKey, raw)
                            local baseKey = guildKeepDailyProofBaseKey(proof)
                            if not baseKey then return end
                            local previous = byBase[baseKey]
                            if previous then
                                if guildKeepDailyProofWins(proof, previous) then byBase[baseKey] = proof end
                                return
                            end
                            if baseCount < GK_DAILY_PROOF_BASES_MAX then
                                byBase[baseKey], baseCount = proof, baseCount + 1
                                return
                            end
                            local worstKey, worst
                            for candidateKey, candidate in pairs(byBase) do
                                if not worst or retainedBefore(worstKey, worst, candidateKey, candidate) then
                                    worstKey, worst = candidateKey, candidate
                                end
                            end
                            if retainedBefore(baseKey, proof, worstKey, worst) then
                                byBase[worstKey] = nil
                                byBase[baseKey] = proof
                            end
                        end
                        local previousStored = compact[dayKey] and compact[dayKey][siteKey]
                        if type(previousStored) == "table" then
                            consider(previousStored, false)
                            if type(previousStored.byBase) == "table" then
                                for _, raw in pairs(previousStored.byBase) do
                                    consider(raw, false)
                                    yieldWork()
                                end
                            end
                        end
                        consider(stored, legacyOnly)
                        if type(stored.byBase) == "table" then
                            local baseCursor = nil
                            while true do
                                local okBase, baseKey, raw = pcall(next, stored.byBase, baseCursor)
                                if not okBase then error(baseKey) end
                                baseCursor = baseKey
                                if baseKey == nil then break end
                                consider(raw, legacyOnly)
                                yieldWork()
                            end
                        end
                        local winner, storedByBase = nil, {}
                        for baseKey, proof in pairs(byBase) do
                            storedByBase[baseKey] = copyGuildKeepDailyProofRow(proof)
                            if not winner or guildKeepDailyProofWins(proof, winner) then winner = proof end
                            yieldWork()
                        end
                        if winner then
                            compact[dayKey] = compact[dayKey] or {}
                            local storedWinner = copyGuildKeepDailyProofRow(winner)
                            storedWinner.byBase = storedByBase
                            compact[dayKey][siteKey] = storedWinner
                        end
                    end
                    yieldWork()
                end
            end
            yieldWork()
        end
        end
        for compactDay, snapshot in pairs(compact) do
            for compactSite, stored in pairs(snapshot) do
                daysBySite[compactSite] = daysBySite[compactSite] or {}
                daysBySite[compactSite][#daysBySite[compactSite] + 1] = compactDay
                if epoch > 0 and isGuildKeepWinDayClosed(Overlord.GuildKeep, compactDay) then
                    for _, proof in pairs(stored.byBase or {}) do
                        syncRows[#syncRows + 1] = {
                            siteKey = compactSite, dayKey = compactDay, guild = proof.guild,
                            faction = proof.faction, kind = proof.kind, eventAt = proof.eventAt,
                            shard = proof.shard, startedAt = proof.startedAt,
                            generationAt = proof.generationAt, player = proof.player,
                            baseGuild = proof.baseGuild, baseFaction = proof.baseFaction,
                            baseCapturedAt = proof.baseCapturedAt, epoch = epoch, pool = proof.pool,
                        }
                        yieldWork()
                    end
                end
                yieldWork()
            end
        end
        for _, days in pairs(daysBySite) do
            sortRowsWithYield(days, function(a, b) return a < b end, yieldWork)
        end
        sortRowsWithYield(syncRows, function(a, b)
            if a.dayKey ~= b.dayKey then return a.dayKey < b.dayKey end
            if a.siteKey ~= b.siteKey then return a.siteKey < b.siteKey end
            if a.baseCapturedAt ~= b.baseCapturedAt then return a.baseCapturedAt < b.baseCapturedAt end
            return a.guild < b.guild
        end, yieldWork)
        local awards = {}
        if type(sourceLegacySnapshots) == "table" then
            -- v7 ne transporte pas ses awards comme autorite. Les reconstruire depuis la
            -- projection gen0 valide conserve le score historique sans faire de scan login.
            for siteKey, days in pairs(daysBySite) do
                for _, dayKey in ipairs(days) do
                    if isGuildKeepWinDayClosed(Overlord.GuildKeep, dayKey) then
                        local canonical = getGuildKeepDailyProofForDay(
                            self, siteKey, dayKey, nil, compact, daysBySite, yieldWork)
                        if canonical and canonical.status == "held" then
                            awards[dayKey .. ":" .. siteKey] = {
                                siteKey = siteKey, guild = canonical.resultGuild,
                                guildKey = canonical.resultGuildKey,
                                faction = canonical.resultFaction,
                                winTs = canonical.eventAt, claimedAt = canonical.claimedAt,
                                pool = canonical.pool,
                            }
                        end
                    end
                    yieldWork()
                end
            end
        end
        local awardCursor = nil
        while true do
            local okAward, awardKey, award = pcall(next, sourceAwards, awardCursor)
            if not okAward then error(awardKey) end
            awardCursor = awardKey
            if awardKey == nil then break end
            local dayKey, rawSiteKey = tostring(awardKey or ""):match("^(%d+):(.+)$")
            local siteKey = rawSiteKey
            if siteKey == "elwynn" then siteKey = "redridge"
            elseif siteKey == "echo_isles" then siteKey = "crossroads" end
            local proofRow = dayKey and siteKey and compact[dayKey] and compact[dayKey][siteKey]
            if isGuildKeepSiegeKey(dayKey) and type(award) == "table" and proofRow then
                local pool = normalizeSavedVarsPool(award.pool)
                if migrationFrom ~= "" and pool == migrationFrom then
                    pool = currentPool
                end
                local guild = sanitizeGuildName(award.guild or "")
                local faction = award.faction
                local winTs = math.floor(tonumber(award.winTs) or 0)
                local storedSiteKey = tostring(award.siteKey or rawSiteKey or "")
                if storedSiteKey == "elwynn" then storedSiteKey = "redridge"
                elseif storedSiteKey == "echo_isles" then storedSiteKey = "crossroads" end
                if guild ~= "" and storedSiteKey == siteKey
                    and (faction == "Alliance" or faction == "Horde")
                    and guildKeepLbPoolMatchesCurrent(pool) and winTs > 0
                    and self:IsTimestampInCurrentCampaign(winTs, epoch) then
                    local canonical = getGuildKeepDailyProofForDay(
                        self, siteKey, dayKey, nil, compact, daysBySite, yieldWork)
                    if canonical and canonical.status == "held"
                        and canonical.resultGuildKey == guild:lower()
                        and canonical.resultFaction == faction then
                        local canonicalKey = dayKey .. ":" .. siteKey
                        local candidate = {
                            siteKey = siteKey, guild = canonical.resultGuild,
                            guildKey = canonical.resultGuildKey,
                            faction = canonical.resultFaction, winTs = winTs,
                            claimedAt = canonical.claimedAt, pool = canonical.pool,
                        }
                        local previous = awards[canonicalKey]
                        if not previous or candidate.winTs < previous.winTs
                            or (candidate.winTs == previous.winTs
                                and candidate.guildKey < previous.guildKey) then
                            awards[canonicalKey] = candidate
                        end
                    end
                end
            end
            yieldWork()
        end
        return compact, daysBySite, syncRows, tenants, official, awards
    end)

    local function fail(err)
        if self._guildKeepProofLedgerGeneration ~= generation then return end
        self._guildKeepProofLedgerPrepPending = false
        local attempts = (tonumber(self._guildKeepProofLedgerAttempts) or 0) + 1
        self._guildKeepProofLedgerAttempts = attempts
        if attempts < 3 then
            self._guildKeepProofLedgerRetryScheduled = true
            C_Timer.After(attempts * 5, function()
                if not Overlord.Leaderboard
                    or Overlord.Leaderboard._guildKeepProofLedgerGeneration ~= generation then return end
                Overlord.Leaderboard._guildKeepProofLedgerRetryScheduled = nil
                Overlord.Leaderboard:EnsureGuildKeepProofLedgerPrepared(initialBuild)
            end)
        elseif initialBuild then
            self._guildKeepProofLedgerFailed = true
        else
            self._guildKeepProofLedgerMaintenanceFailed = tostring(err or "GK_PROOF_BUILD_FAILED")
        end
    end
    local function resumeWorker()
        if self._guildKeepProofLedgerGeneration ~= generation then return end
        budgetStarted = clockMs()
        local result = { coroutine.resume(worker) }
        if not result[1] then fail(result[2]); return end
        if coroutine.status(worker) ~= "dead" then C_Timer.After(0, resumeWorker); return end
        if (tonumber(self._guildKeepProofLedgerRevision) or 0) ~= buildRevision
            or OverlordDB.guildKeepCutoffSnapshots ~= sourceSnapshots
            or OverlordDB.guildKeepTenants ~= sourceTenants
            or OverlordDB.guildKeepOfficialTenants ~= sourceOfficial
            or OverlordDB.guildKeepSiegeWinAwards ~= sourceAwards
            or OverlordDB.guildKeepProtocol7SnapshotsPending ~= sourceLegacySnapshots then
            self._guildKeepProofLedgerPrepPending = false
            self._guildKeepProofLedgerDirty = true
            C_Timer.After(0, function()
                if Overlord.Leaderboard then
                    Overlord.Leaderboard:EnsureGuildKeepProofLedgerPrepared(initialBuild)
                end
            end)
            return
        end
        OverlordDB.guildKeepCutoffSnapshots = result[2]
        OverlordDB.guildKeepTenants = result[5]
        OverlordDB.guildKeepOfficialTenants = result[6]
        OverlordDB.guildKeepSiegeWinAwards = result[7]
        OverlordDB.guildKeepProofSanitizeVersion = 1
        self._guildKeepProofDaysBySite = result[3]
        self._guildKeepProofSyncRows = result[4]
        self._guildKeepProofLedgerSource = result[2]
        self._guildKeepProofLegacySource = nil
        self._guildKeepProofLedgerPrepared = true
        self._guildKeepProofLedgerDirty = false
        self._guildKeepProofLedgerPrepPending = false
        self._guildKeepProofLedgerRetryScheduled = nil
        self._guildKeepProofLedgerAttempts = 0
        self._guildKeepProofLedgerMaintenanceFailed = nil
        self._guildKeepLbMigrationFrom = nil
        OverlordDB.guildKeepLbMigrationFrom = nil
        OverlordDB.guildKeepProtocol7SnapshotsPending = nil
        self:MarkDirty()
    end
    C_Timer.After(0, resumeWorker)
    if self._guildKeepProofLedgerPrepared and not requireCurrent then return true end
    return false
end

function Overlord.Leaderboard:ReconcileGuildKeepDailyAward(siteKey, dayKey)
    local proof = getGuildKeepDailyProofForDay(self, siteKey, dayKey)
    if not proof then return false end
    local awards = self:GetGuildKeepSiegeWinAwardsTable()
    local awardKey = tostring(dayKey) .. ":" .. tostring(siteKey)
    if proof.status == "held" then
        return self:RecordGuildKeepSiegeWin(
            proof.resultGuild, proof.resultFaction, siteKey, dayKey,
            proof.eventAt, proof.pool)
    end
    local previous = awards[awardKey]
    if type(previous) ~= "table" then return false end
    awards[awardKey] = nil
    self:MarkDirty()
    if self.InvalidateGuildKeepDailyAwardStable then
        self:InvalidateGuildKeepDailyAwardStable()
    end
    return true
end

-- Une mutation brute ancienne peut changer la projection de tous les jours suivants du
-- meme keep. Six sites x sept jours au maximum : une passe ciblee est moins couteuse et
-- beaucoup plus lisible qu'un cache d'invalidation supplementaire.
-- Creneaux (ordre croissant) de ce fortin a partir de fromDayKey.
function Overlord.Leaderboard:CollectGuildKeepAwardDaysFrom(siteKey, fromDayKey)
    local days = {}
    for dayKey, snapshot in pairs(OverlordDB and OverlordDB.guildKeepCutoffSnapshots or {}) do
        dayKey = tostring(dayKey or "")
        if dayKey >= fromDayKey and type(snapshot) == "table"
            and snapshot[siteKey] ~= nil then
            days[#days + 1] = dayKey
        end
    end
    table.sort(days)
    return days
end

function Overlord.Leaderboard:ReconcileGuildKeepDailyAwardsFromDay(siteKey, fromDayKey)
    if not OverlordDB then return false end
    siteKey, fromDayKey = tostring(siteKey or ""), tostring(fromDayKey or "")
    local changed = false
    for _, dayKey in ipairs(self:CollectGuildKeepAwardDaysFrom(siteKey, fromDayKey)) do
        if self:ReconcileGuildKeepDailyAward(siteKey, dayKey) then changed = true end
    end
    return changed
end

-- Reception GH : /ov perf mesurait ~19 ms par preuve (tous les creneaux suivants du
-- fortin) dans le handler reseau, et une rafale s'additionnait dans une seule image.
-- Demandes coalescees par fortin (creneau le plus ancien, qui couvre les suivants),
-- puis memes reconciliations dans le meme ordre, ~1 ms par image.
function Overlord.Leaderboard:RequestGuildKeepAwardsReconcileFromDay(siteKey, fromDayKey)
    siteKey, fromDayKey = tostring(siteKey or ""), tostring(fromDayKey or "")
    if siteKey == "" or not OverlordDB then return end
    if not (C_Timer and C_Timer.After) then
        self:ReconcileGuildKeepDailyAwardsFromDay(siteKey, fromDayKey)
        return
    end
    local pending = self._gkReconcilePending or {}
    self._gkReconcilePending = pending
    if not pending[siteKey] or fromDayKey < pending[siteKey] then pending[siteKey] = fromDayKey end
    if self._gkReconcileScheduled then return end
    self._gkReconcileScheduled = true
    C_Timer.After(self.GK_RECONCILE_DEBOUNCE_SEC or 10, function() self:RunPendingGuildKeepAwardReconciles() end)
end

function Overlord.Leaderboard:RunPendingGuildKeepAwardReconciles()
    if self:ShouldPostponeGuildKeepWork() then
        C_Timer.After(self.GK_WORK_POSTPONE_RETRY or 2, function() self:RunPendingGuildKeepAwardReconciles() end)
        return
    end
    local queue = self._gkReconcileQueue
    if not queue or queue.index > #queue.items then
        queue = { items = {}, index = 1 }
        local pending = self._gkReconcilePending or {}
        self._gkReconcilePending = nil
        local sites = {}
        for siteKey in pairs(pending) do sites[#sites + 1] = siteKey end
        table.sort(sites)
        for _, siteKey in ipairs(sites) do
            for _, dayKey in ipairs(self:CollectGuildKeepAwardDaysFrom(siteKey, pending[siteKey])) do
                queue.items[#queue.items + 1] = { siteKey = siteKey, dayKey = dayKey }
            end
        end
        self._gkReconcileQueue = queue
    end
    local steps, changed = 0, false
    while queue.index <= #queue.items do
        local item = queue.items[queue.index]
        queue.index = queue.index + 1
        steps = steps + 1
        if self:ReconcileGuildKeepDailyAward(item.siteKey, item.dayKey) then changed = true end
        if steps >= 1 then break end
    end
    if changed and Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
    if queue.index <= #queue.items or self._gkReconcilePending then
        C_Timer.After(self.GK_WORK_STEP_INTERVAL or 0.1, function() self:RunPendingGuildKeepAwardReconciles() end)
        return
    end
    self._gkReconcileQueue = nil
    self._gkReconcileScheduled = false
end

-- Enregistre uniquement le score couvert par la preuve quotidienne causale GH.
function Overlord.Leaderboard:RecordGuildKeepSiegeWin(
    guildName, faction, siteKey, dayKey, winTs, poolTag)
    local gk = Overlord.GuildKeep
    guildName = sanitizeGuildName(guildName)
    siteKey = tostring(siteKey or "")
    poolTag = normalizeSavedVarsPool(poolTag) or ""
    if poolTag == "" or not guildKeepLbPoolMatchesCurrent(poolTag) then return false end
    if guildName == "" or not isValidGuildKeepSite(siteKey)
        or not gk or not gk.GetServerSiegeDayKey then return false end
    dayKey = tostring(dayKey or "")
    winTs = math.floor(tonumber(winTs) or 0)
    local campaignStart = self:GetCurrentCampaignStart()
    if not isGuildKeepSiegeKey(dayKey) or winTs <= 0
        or not self:IsTimestampInCurrentCampaign(winTs, campaignStart)
        or winTs > leaderboardServerNow() + 300 then return false end
    if not isGuildKeepWinDayClosed(gk, dayKey) then return false end

    local canonical = getGuildKeepDailyProofForDay(self, siteKey, dayKey)
    if not canonical or canonical.status ~= "held"
        or canonical.resultGuildKey ~= guildName:lower() then return false end
    guildName = canonical.resultGuild
    faction = canonical.resultFaction
    poolTag = canonical.pool ~= "" and canonical.pool or poolTag
    if not guildKeepLbPoolMatchesCurrent(poolTag) then return false end
    local canonicalClaimedAt = math.floor(tonumber(canonical.claimedAt) or 0)
    if canonicalClaimedAt <= 0 then return false end

    local awards = self:GetGuildKeepSiegeWinAwardsTable()
    local awardKey = dayKey .. ":" .. siteKey
    local guildKey = canonical.resultGuildKey
    local previous = awards[awardKey]
    local previousGuildKey = previous and (previous.guildKey
        or sanitizeGuildName(previous.guild or ""):lower()) or ""
    local previousWinTs = math.floor(tonumber(previous and previous.winTs) or 0)
    local storedWinTs = winTs
    if previousWinTs > 0 then storedWinTs = math.min(previousWinTs, winTs) end

    local unchanged = previousGuildKey == guildKey
        and math.floor(tonumber(previous and previous.claimedAt) or 0) == canonicalClaimedAt
        and (previous and previous.faction or "") == faction
        and normalizeSavedVarsPool(previous and previous.pool) == normalizeSavedVarsPool(poolTag)
        and previousWinTs == storedWinTs
    if unchanged then return false end

    awards[awardKey] = {
        guildKey = guildKey,
        guild = guildName,
        faction = faction,
        siteKey = siteKey,
        pool = poolTag,
        winTs = storedWinTs,
        claimedAt = canonicalClaimedAt,
    }
    self:MarkDirty()
    if self.RequestGuildKeepProofLedgerRebuild then
        self:RequestGuildKeepProofLedgerRebuild(siteKey, dayKey)
    end
    if self.InvalidateGuildKeepDailyAwardStable then
        self:InvalidateGuildKeepDailyAwardStable()
    end
    return true
end

-- Apres convergence post-cloture, eviter le scan Repair/Award a 1 Hz pendant ~23 h.
local GK_DAILY_AWARD_RECHECK_SEC = 30

function Overlord.Leaderboard:InvalidateGuildKeepDailyAwardStable()
    -- Compteur lu par la passe decoupee : une mutation pendant la passe l'empeche
    -- de se declarer stable pour 30 s, le tick suivant la relance.
    self._gkAwardInvalidations = (self._gkAwardInvalidations or 0) + 1
    self._gkAwardStable = false
    self._gkAwardStableDayKey = nil
    self._gkAwardNextCheckAt = nil
end

-- Au plus deux emetteurs GH : l'autorite terminale exacte (Anchor en fallback) et le leader.
-- Le second couvre les raids mixtes ou l'autorite encore en ligne utilise un ancien patch ;
-- le dedup payload absorbe son doublon. L'ancien fanout par guilde faisait emettre chaque membre.
local function shouldBroadcastLocalGuildKeepProof(proof, siteKey)
    local gk, sync = Overlord.GuildKeep, Overlord.Sync
    if not proof or not gk or not sync or not sync.GetPlayerFullName
        or not sync.GetCaptureContributorDedupKey then return false end
    local st = gk.GetState and gk:GetState(siteKey)
    local emitter = proof.player or ""
    if st and proof.kind == "GC" and st.finalAssaultAuthorityPlayer
        and st.finalAssaultAuthorityPlayer ~= "" then
        emitter = st.finalAssaultAuthorityPlayer
    elseif st and proof.kind == "GA" and st.abortedAssaultAuthorityPlayer
        and st.abortedAssaultAuthorityPlayer ~= "" then
        emitter = st.abortedAssaultAuthorityPlayer
    end
    local selfName = sync:GetPlayerFullName() or ""
    local selfKey = sync:GetCaptureContributorDedupKey(selfName)
    local emitterKey = sync:GetCaptureContributorDedupKey(emitter)
    if not selfKey or selfKey == "" or not emitterKey or emitterKey == "" then return false end
    if selfKey == emitterKey then return true end

    -- Le roster ne prouve ni la version de l'addon ni meme sa presence. Une autorite 9.9.1
    -- encore en ligne faisait donc taire le seul client capable d'emettre GH 9.9.2. Le leader
    -- reste un second relais borne ; le dedup payload absorbe le doublon de l'autorite a jour.
    return type(IsInGroup) == "function" and IsInGroup()
        and type(UnitIsGroupLeader) == "function" and UnitIsGroupLeader("player") == true
end

function Overlord.Leaderboard:ShouldBroadcastLocalGuildKeepProof(proof, siteKey)
    return shouldBroadcastLocalGuildKeepProof(proof, siteKey)
end

-- Un fortin a la fois (~10 ms chacun en fin de semaine) : la passe decoupee les
-- enchaine image par image ; le chemin court les appelle d'affilee comme avant.
function Overlord.Leaderboard:AwardHeldGuildKeepWinForSite(siteKey, dayKey, winTs)
    local lb = self
    local changed = false
    do
        local localProof = lb.BuildGuildKeepDailyProofForState
            and lb:BuildGuildKeepDailyProofForState(siteKey, dayKey) or nil
        if localProof then
            local proofApplied = lb:ApplyGuildKeepDailyProofSync(
                siteKey, dayKey, localProof.kind, localProof.eventAt,
                localProof.guild, localProof.faction, localProof.shard,
                localProof.startedAt, localProof.generationAt, localProof.player,
                localProof.baseGuild, localProof.baseFaction,
                localProof.baseCapturedAt, localProof.pool)
            local proof = getGuildKeepDailyProofForDay(lb, siteKey, dayKey)
            local rawProof = getRawGuildKeepDailyProofForDay(lb, siteKey, dayKey)
            local awardChanged = proof and lb:ReconcileGuildKeepDailyAward(
                siteKey, dayKey) or false
            if proofApplied or awardChanged then changed = true end
            if rawProof and localProof
                and shouldBroadcastLocalGuildKeepProof(localProof, siteKey)
                and Overlord.Sync and Overlord.Sync.BroadcastGuildKeepDailyProof then
                Overlord.Sync:BroadcastGuildKeepDailyProof(siteKey, dayKey, false)
            end
            if proof and proof.status == "held"
                and Overlord.GuildKeepImmersion and Overlord.GuildKeepImmersion.OnDailyDefense then
                local tenant = getGuildKeepCanonicalTenantForDay(lb, siteKey, dayKey)
                if tenant then
                    Overlord.GuildKeepImmersion:OnDailyDefense(siteKey, tenant.guild,
                        tenant.faction, winTs, tenant.claimedAt, proof.kind)
                end
            end
        end
    end
    return changed
end

-- Etat de la fenetre de siege : change a l'ouverture et a la fermeture de chaque siege.
function Overlord.Leaderboard:GetGuildKeepAwardWindowSignature()
    local gk = Overlord.GuildKeep
    if not gk or not gk.IsSiegeWindowOpen or not gk.IsSiegeWindowClosedForToday then return "" end
    return (gk:IsSiegeWindowOpen() and "open" or "shut") .. ":"
        .. (gk:IsSiegeWindowClosedForToday() and "done" or "pending")
end

-- Taches (fortin, jour) de la fin de passe, dans l'ordre de l'ancien corps :
-- rattrapage de la veille d'abord, puis la cloture du jour.
function Overlord.Leaderboard:CollectHeldGuildKeepAwardTasks()
    local gk = Overlord.GuildKeep
    local tasks = {}
    if not gk or not Overlord.GuildKeepSites or not gk.GetServerSiegeDayKey then return tasks end
    local now = leaderboardServerNow()
    local function addAll(winTs)
        local dayKey = gk:GetServerSiegeDayKey(winTs)
        for siteKey in pairs(Overlord.GuildKeepSites) do
            tasks[#tasks + 1] = { siteKey = siteKey, dayKey = dayKey, winTs = winTs }
        end
    end
    -- Rattrapage login : avant le siege du jour, le tenant courant est encore
    -- celui qui devait recevoir la victoire de defense de la veille.
    if gk.IsSiegeWindowOpen and not gk:IsSiegeWindowOpen() and not gk:IsSiegeWindowClosedForToday() then
        local prevTs = now - 86400
        if prevTs >= (self:GetCurrentCampaignStart() or 0) then addAll(prevTs) end
    end
    if gk:IsSiegeWindowClosedForToday() then addAll(now) end
    return tasks
end

-- Reprojette chaque registre causal GH vers l'award additif correspondant. Un GA neutral
-- retire aussi un ancien award fantome deja recu.
local function RepairGuildKeepAwardsFromDailyProofs(lb)
    local gk = Overlord.GuildKeep
    if not lb or not gk or not gk.GetServerSiegeDayKey then return false end
    local repaired = false
    for dayKey, snapshot in pairs(OverlordDB.guildKeepCutoffSnapshots or {}) do
        if type(snapshot) == "table" and isGuildKeepWinDayClosed(gk, dayKey) then
            for siteKey in pairs(snapshot) do
                local proof = getGuildKeepDailyProofForDay(lb, siteKey, dayKey)
                if proof then
                    if lb:ReconcileGuildKeepDailyAward(siteKey, dayKey) then
                        repaired = true
                    end
                end
            end
        end
    end
    return repaired
end

function Overlord.Leaderboard:MaybeAwardGuildKeepDailyWins()
    if not self._guildKeepProofLedgerPrepared then
        if self.EnsureGuildKeepProofLedgerPrepared then
            self:EnsureGuildKeepProofLedgerPrepared(false)
        end
        return false
    end
    -- Ne jamais sceller une preuve depuis les SavedVariables avant le catch-up login.
    -- La passe 1 Hz reprendra automatiquement des que la gate est levee.
    if Overlord.WaitingForSync
        or (Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending()) then return false end
    local gk = Overlord.GuildKeep
    if not gk or not Overlord.GuildKeepSites or not gk.IsSiegeWindowClosedForToday then return false end
    local nowClock = GetTime and GetTime() or 0
    -- Garde monotone avant tout calcul calendaire : GetServerSiegeDayKey traverse les
    -- conversions DST et allouait plusieurs tables date() sur le ticker global 1 Hz.
    if nowClock > 0 and self._gkAwardNextCheckAt and nowClock < self._gkAwardNextCheckAt then
        return false
    end
    -- Sieges toutes les 6 h : une fois stable, la passe complete (~170 reconciliations
    -- en fin de semaine) ne repart qu'a la fin d'un siege (ouverture/fermeture de la
    -- fenetre), sur mutation reelle (invalidation) ou apres le filet de securite.
    -- Le coup d'oeil toutes les 30 s ne lit que l'etat de la fenetre de siege.
    if self._gkAwardStable and nowClock > 0 and self._gkAwardSafetyAt
        and nowClock < self._gkAwardSafetyAt
        and self._gkAwardWindowSignature == self:GetGuildKeepAwardWindowSignature() then
        self._gkAwardNextCheckAt = nowClock + GK_DAILY_AWARD_RECHECK_SEC
        return false
    end
    local dayKey = gk.GetServerSiegeDayKey and gk:GetServerSiegeDayKey() or ""
    -- Une passe propre suffit dans toutes les phases de la journee. Les mutations terrain
    -- invalident explicitement ce cache, donc le ticker 1 Hz reste reactif sans rescanner
    -- les preuves et les six fortins chaque seconde pendant des heures.
    -- Une passe de reparation deja decoupee sur plusieurs images est en cours : attendre.
    if self._gkAwardRepairJob then return false end
    -- Priorite basse : pas de nouvelle passe en combat ni en gros event (tick suivant).
    if self:ShouldPostponeGuildKeepWork() then return false end
    -- Fin de campagne : ~28 creneaux x 6 fortins, ~3,7 ms par reconciliation, soit
    -- ~350 ms dans une seule image (mesure en jeu via /ov perf). Au-dela d'un petit
    -- lot, la reparation est decoupee (~1 ms par image) puis la passe se termine ici.
    local repairPairs = self:CollectGuildKeepAwardRepairPairs()
    if #repairPairs > (self.GK_AWARD_REPAIR_SYNC_MAX or 16) and C_Timer and C_Timer.After then
        self:StartGuildKeepAwardRepairJob(repairPairs, dayKey)
        return false
    end
    local changed = self:RunGuildKeepAwardRepairPairs(repairPairs, 1, #repairPairs)
    return self:FinishGuildKeepDailyAwardPass(dayKey, changed)
end

-- Combat ou gros event : le travail fortin attend (il sera refait a l'identique).
function Overlord.Leaderboard:ShouldPostponeGuildKeepWork()
    if InCombatLockdown and InCombatLockdown() then return true end
    local sync = Overlord.Sync
    if not sync or not sync.IsLargeEvent then return false end
    local ok, large = pcall(sync.IsLargeEvent, sync)
    return ok and large == true
end

-- Couples (creneau ferme, fortin) dont la preuve du jour existe. Lecture seule, rapide.
function Overlord.Leaderboard:CollectGuildKeepAwardRepairPairs()
    local gk = Overlord.GuildKeep
    local pairsList = {}
    for dayKey, snapshot in pairs(OverlordDB.guildKeepCutoffSnapshots or {}) do
        if type(snapshot) == "table" and isGuildKeepWinDayClosed(gk, dayKey) then
            for siteKey in pairs(snapshot) do
                pairsList[#pairsList + 1] = { dayKey = dayKey, siteKey = siteKey }
            end
        end
    end
    return pairsList
end

-- Meme travail que RepairGuildKeepAwardsFromDailyProofs, sur une tranche de la liste.
-- Chaque couple est reverifie au moment de son traitement (la table peut changer).
function Overlord.Leaderboard:RunGuildKeepAwardRepairPairs(repairPairs, first, last)
    local repaired = false
    local snapshots = OverlordDB.guildKeepCutoffSnapshots or {}
    for i = first, last do
        local item = repairPairs[i]
        local snapshot = item and snapshots[item.dayKey]
        if type(snapshot) == "table" and snapshot[item.siteKey] ~= nil
            and getGuildKeepDailyProofForDay(self, item.siteKey, item.dayKey)
            and self:ReconcileGuildKeepDailyAward(item.siteKey, item.dayKey) then
            repaired = true
        end
    end
    return repaired
end

function Overlord.Leaderboard:StartGuildKeepAwardRepairJob(repairPairs, dayKey)
    local job = { pairs = repairPairs, index = 1, changed = false, dayKey = dayKey,
        invalidations = self._gkAwardInvalidations or 0 }
    self._gkAwardRepairJob = job
    local lb = self
    local function slice()
        if lb._gkAwardRepairJob ~= job then return end
        if lb:ShouldPostponeGuildKeepWork() then
            C_Timer.After(lb.GK_WORK_POSTPONE_RETRY or 2, slice)
            return
        end
        local steps = 0
        repeat
            steps = steps + 1
            if job.index <= #job.pairs then
                if lb:RunGuildKeepAwardRepairPairs(job.pairs, job.index, job.index) then
                    job.changed = true
                end
                job.index = job.index + 1
            else
                -- Fin de passe : taches collectees apres la reparation, comme avant.
                job.tasks = job.tasks or lb:CollectHeldGuildKeepAwardTasks()
                job.taskIndex = job.taskIndex or 1
                local task = job.tasks[job.taskIndex]
                if not task then break end
                if lb:AwardHeldGuildKeepWinForSite(task.siteKey, task.dayKey, task.winTs) then
                    job.changed = true
                end
                job.taskIndex = job.taskIndex + 1
            end
        until steps >= 1
        if job.index <= #job.pairs or not job.tasks or job.tasks[job.taskIndex] then
            C_Timer.After(lb.GK_WORK_STEP_INTERVAL or 0.1, slice)
            return
        end
        lb._gkAwardRepairJob = nil
        local mutatedDuringPass = (lb._gkAwardInvalidations or 0) ~= job.invalidations
        lb:CompleteGuildKeepDailyAwardPass(job.dayKey, job.changed, mutatedDuringPass)
    end
    C_Timer.After(0, slice)
end

-- Suite de la passe apres la reparation des preuves (identique a l'ancien corps).
function Overlord.Leaderboard:FinishGuildKeepDailyAwardPass(dayKey, changed, mutatedDuringPass)
    if not Overlord.GuildKeep then return changed end
    for _, task in ipairs(self:CollectHeldGuildKeepAwardTasks()) do
        changed = self:AwardHeldGuildKeepWinForSite(task.siteKey, task.dayKey, task.winTs) or changed
    end
    return self:CompleteGuildKeepDailyAwardPass(dayKey, changed, mutatedDuringPass)
end

function Overlord.Leaderboard:CompleteGuildKeepDailyAwardPass(dayKey, changed, mutatedDuringPass)
    local nowClock = GetTime and GetTime() or 0
    -- Plus de backfill multi-jours depuis la tenure (RepairHeldGuildKeepWinsSinceTenure) :
    -- c'etait la source des victoires fantomes (il creditait CHAQUE jour entre la capture et
    -- aujourd'hui en supposant une tenure continue, meme jamais observee a la cloture). Un
    -- jour de victoire n'est desormais credite QUE pour le fort reellement tenu a la cloture
    -- de CE jour (award du jour ci-dessus + rattrapage login d'un seul jour, lui-meme borne
    -- par claimedAt <= jour). Modele convergent identique aux outposts.
    if changed then
        self:InvalidateGuildKeepDailyAwardStable()
        -- Le ticker de cloture peut creer/reparer un award sans paquet GH entrant.
        -- Dans ce cas aucun handler sync ne demandera le repaint : invalider aussi
        -- la liste de sites cachee, meme si le panneau est actuellement ferme.
        if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
            Overlord.LeaderboardUI:RefreshIfVisible()
        end
    elseif dayKey ~= "" and nowClock > 0 and not mutatedDuringPass then
        self._gkAwardStable = true
        self._gkAwardStableDayKey = dayKey
        self._gkAwardNextCheckAt = nowClock + GK_DAILY_AWARD_RECHECK_SEC
        self._gkAwardSafetyAt = nowClock + (self.GK_AWARD_SAFETY_RECHECK_SEC or 600)
        self._gkAwardWindowSignature = self:GetGuildKeepAwardWindowSignature()
    end
    return changed
end

-- Victoires de siege par couple fort+guilde : l'award elu est la source de verite
-- unique pour le jour. Les compteurs additifs legacy ne pilotent plus l'affichage,
-- sinon un ancien tenant cross-faction continue a gagner chez les clients deja corriges.
local function BuildGuildKeepWinCountsFromAwards(lb, yieldWork)
    local counts = {}
    local awards, cursor = lb:GetGuildKeepSiegeWinAwardsTable(), nil
    while true do
        local ok, awardKey, award = pcall(next, awards, cursor)
        if not ok then error(awardKey) end
        cursor = awardKey
        if awardKey == nil then break end
        local valid = getValidGuildKeepAward(lb, awardKey, award)
        if valid then
            local rowKey = valid.siteKey .. ":" .. valid.guildKey
            local bucket = counts[rowKey]
            if not bucket then
                bucket = {
                    count = 0,
                    guild = valid.guild,
                    faction = valid.faction,
                    siteKey = valid.siteKey,
                }
                counts[rowKey] = bucket
            end
            bucket.count = bucket.count + 1
            if valid.guild < bucket.guild then bucket.guild = valid.guild end
            if valid.faction < bucket.faction then bucket.faction = valid.faction end
        end
        if yieldWork then yieldWork() end
    end
    -- Convergence calquee sur les kills : les wins ne sortent QUE des awards derives de GH
    -- (additifs, un par couple jour+fort, rejoues dans chaque SR). On ne rajoute plus
    -- de projection locale basee sur le tenant cru localement : c'etait la source de
    -- divergence (chaque client inventait un nombre, voire une ligne, selon SON
    -- detenteur). Les awards du jour sont de toute facon generes avant lecture par
    -- MaybeAwardGuildKeepDailyWins (PrepareForHeavyRead), donc aucun sous-comptage pour
    -- un fort reellement tenu, et tout le monde voit pareil.
    return counts
end

-- Classement fortins : terminal v8 pour l'icone, preuve GH pour les wins.
function Overlord.Leaderboard:GetSortedGuildKeeps(sortedGuildKillsForNames, yieldWork)
    local gk = Overlord.GuildKeep
    local winCounts = BuildGuildKeepWinCountsFromAwards(self, yieldWork)
    local tenants = self:GetGuildKeepTenantsTable()
    local sorted = {}
    local rowKeys = {}

    if Overlord.GuildKeepSites then
        for siteKey in pairs(Overlord.GuildKeepSites) do
            if yieldWork then yieldWork() end
            local t = getValidGuildKeepTenantRow(self, siteKey, tenants[siteKey])
            local guild = t and t.guild or ""
            local fac = t and (t.faction or "") or ""
            local tenantClaimedAt = math.floor(tonumber(t and t.claimedAt) or 0)
            if gk then
                local function preferTenant(row)
                    if not row then return end
                    local claimedAt = math.floor(tonumber(row.claimedAt) or 0)
                    if claimedAt <= 0 then return end
                    if guild == "" or claimedAt >= tenantClaimedAt then
                        guild = row.guild
                        fac = row.faction or ""
                        tenantClaimedAt = claimedAt
                    end
                end
                -- Le tenant officiel est ecrit au moment exact de la capture et evite
                -- qu'une projection stale affiche une autre guilde pendant le fight suivant.
                local official = gk.GetOfficialKeepTenant and gk:GetOfficialKeepTenant(siteKey)
                if official then
                    official = getValidGuildKeepTenantRow(self, siteKey, official)
                end
                preferTenant(official)
                -- Le score quotidien reste absent de cette election : il ajoute des wins,
                -- mais ne peut jamais changer l'icone de tenant du ladder.
            end
            if guild ~= "" and (fac == "Alliance" or fac == "Horde") then
                local key = guild:lower()
                local rowKey = siteKey .. ":" .. key
                rowKeys[rowKey] = true
                local bucket = winCounts[rowKey]
                local wins = bucket and bucket.count or 0
                sorted[#sorted + 1] = {
                    guild = guild,
                    faction = fac,
                    keepAtlas = gk and gk.GetMainHallAtlasForFaction
                        and gk:GetMainHallAtlasForFaction(fac),
                    keepSiteKey = siteKey,
                    wins = wins,
                    currentlyHeld = true,
                }
            end
        end
    end

    for rowKey, bucket in pairs(winCounts) do
        if yieldWork then yieldWork() end
        if not rowKeys[rowKey] and bucket.count > 0 and bucket.guild ~= "" then
            rowKeys[rowKey] = true
            sorted[#sorted + 1] = {
                guild = bucket.guild,
                faction = bucket.faction or "",
                keepAtlas = nil,
                keepSiteKey = bucket.siteKey,
                wins = bucket.count,
                currentlyHeld = false,
            }
        end
    end

    sortRowsWithYield(sorted, function(a, b)
        local wa, wb = a.wins or 0, b.wins or 0
        if wa ~= wb then return wa > wb end
        if (a.currentlyHeld and 1 or 0) ~= (b.currentlyHeld and 1 or 0) then
            return a.currentlyHeld and not b.currentlyHeld
        end
        if (a.guild or "") ~= (b.guild or "") then
            return (a.guild or "") < (b.guild or "")
        end
        return (a.keepSiteKey or "") < (b.keepSiteKey or "")
    end, yieldWork)
    return sorted
end

function Overlord.Leaderboard:GetOutpostTenantsTable()
    if not OverlordDB then return {} end
    ensureOutpostLeaderboardTables(self)
    return OverlordDB.outpostTenants
end

function Overlord.Leaderboard:GetOutpostCaptureCountsTable()
    if not OverlordDB then return {} end
    ensureOutpostLeaderboardTables(self)
    return OverlordDB.outpostCaptureCounts
end

function Overlord.Leaderboard:GetOutpostCaptureCountRow(siteKey, guild, poolTag)
    guild = sanitizeGuildName(guild or "")
    poolTag = resolveOutpostLbPoolTag(poolTag)
    local key = outpostCaptureRowKey(siteKey, guild:lower(), poolTag)
    if key == "" then return nil end
    return self:GetOutpostCaptureCountsTable()[key]
end

function Overlord.Leaderboard:ApplyOutpostTenantSync(siteKey, guild, faction, claimedAt, poolTag)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    claimedAt = math.floor(tonumber(claimedAt) or 0)
    poolTag = normalizeSavedVarsPool(poolTag) or ""
    if poolTag == "" then return false end
    if not outpostLbPoolMatchesCurrent(poolTag) then return false end
    if siteKey == "" or not isValidOutpostSite(siteKey) then return false end
    if guild == "" or claimedAt <= 0 then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if not self:IsTimestampInCurrentCampaign(claimedAt, campaignStart) then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    local tenants = self:GetOutpostTenantsTable()
    local prev = tenants[siteKey]
    local prevTs = prev and math.floor(tonumber(prev.claimedAt) or 0) or 0
    local guildKey = guild:lower()
    local prevGuildKey = prev and (prev.guildKey or "") or ""
    local prevPool = prev and resolveOutpostLbPoolTag(prev.pool) or ""
    local tieKey = guildKey .. ":" .. poolTag .. ":" .. faction
    local prevTieKey = prev and (prevGuildKey .. ":" .. prevPool .. ":" .. (prev.faction or "")) or ""
    if prev and prevTs > claimedAt then return false end
    if prev and prevTs == claimedAt then
        if prevTieKey == tieKey or tieKey >= prevTieKey then return false end
    end
    -- Ne pas crediter implicitement l'ancien tenant : cet effet dependait de l'ordre
    -- d'arrivee T1/T2. Le score vient de OC/LOC, ou du LO courant valide juste apres.
    tenants[siteKey] = {
        guild = guild,
        guildKey = guildKey,
        faction = faction,
        claimedAt = claimedAt,
        pool = poolTag,
    }
    self:MarkDirty()
    return true
end

-- Credite une premiere capture manquante sans re-appliquer le tenant (evite la recursion avec ApplyOutpostTenantSync).
function Overlord.Leaderboard:EnsureOutpostCaptureCounted(siteKey, guild, faction, captureTs, poolTag)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    captureTs = math.floor(tonumber(captureTs) or 0)
    if siteKey == "" or guild == "" or captureTs <= 0 then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    poolTag = normalizeSavedVarsPool(poolTag)
    if poolTag == "" then poolTag = currentSavedVarsPool() end
    if poolTag == "" or not outpostLbPoolMatchesCurrent(poolTag) then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if not self:IsTimestampInCurrentCampaign(captureTs, campaignStart) then return false end
    ensureOutpostLeaderboardTables(self)
    local guildKey = guild:lower()
    local rowKey = outpostCaptureRowKey(siteKey, guildKey, poolTag)
    if rowKey == "" then return false end
    local counts = self:GetOutpostCaptureCountsTable()
    local row = counts[rowKey]
    if row then ensureOutpostEventLedgerV2(row) end
    if not row then
        row = {
            siteKey = siteKey,
            guild = guild,
            guildKey = guildKey,
            faction = faction,
            count = 0,
            floorTs = 0,
            events = {},
            locAnchors = {},
            eventLedgerVersion = 2,
            eventLedgerBoundsV1 = true,
            eventLedgerPreparedV1 = true,
            eventCount = 0,
            newestEventTs = 0,
            newestAnchorTs = 0,
            pool = poolTag,
        }
        counts[rowKey] = row
    end
    local previousCount = math.floor(tonumber(row.count) or 0)
    row.events = row.events or {}
    local eventKey = tostring(captureTs)
    local eventChanged = not row.events[eventKey]
    if eventChanged and previousCount >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
    if eventChanged and countOutpostEvents(row) >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
    if eventChanged then row.events[eventKey] = true end
    -- L'ID temporel rend le OC correspondant idempotent.
    local incremented = eventChanged and noteOutpostEventAdded(row, captureTs) or false
    row.guild = guild
    local factionChanged = mergeOutpostRowFaction(row, faction, captureTs)
    row.pool = poolTag
    if eventChanged or incremented or factionChanged then
        self:MarkDirty()
        self:RequestOutpostLedgerRebuild()
    end
    return incremented
end

function Overlord.Leaderboard:RecordOutpostCapture(siteKey, guild, faction, captureTs, poolTag)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    captureTs = math.floor(tonumber(captureTs) or 0)
    if siteKey == "" or guild == "" or captureTs <= 0 then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    poolTag = normalizeSavedVarsPool(poolTag)
    if poolTag == "" then poolTag = currentSavedVarsPool() end
    if poolTag == "" or not outpostLbPoolMatchesCurrent(poolTag) then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if not self:IsTimestampInCurrentCampaign(captureTs, campaignStart) then return false end
    ensureOutpostLeaderboardTables(self)
    local guildKey = guild:lower()
    local rowKey = outpostCaptureRowKey(siteKey, guildKey, poolTag)
    if rowKey == "" then return false end
    local counts = self:GetOutpostCaptureCountsTable()
    local row = counts[rowKey]
    if not row then
        row = {
            siteKey = siteKey,
            guild = guild,
            guildKey = guildKey,
            faction = faction,
            factionAt = captureTs,
            count = 0,
            floorTs = 0,
            events = {},
            locAnchors = {},
            eventLedgerVersion = 2,
            eventLedgerBoundsV1 = true,
            eventLedgerPreparedV1 = true,
            eventCount = 0,
            newestEventTs = 0,
            newestAnchorTs = 0,
            pool = poolTag,
        }
        counts[rowKey] = row
    end
    ensureOutpostEventLedgerV2(row)
    row.events = row.events or {}
    local eventKey = tostring(captureTs)
    local previousCount = math.floor(tonumber(row.count) or 0)
    local eventChanged = not row.events[eventKey]
    if eventChanged and previousCount >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
    if eventChanged and countOutpostEvents(row) >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false end
    if eventChanged then
        row.events[eventKey] = true
    end
    local incremented = eventChanged and noteOutpostEventAdded(row, captureTs) or false
    row.guild = guild
    local factionChanged = mergeOutpostRowFaction(row, faction, captureTs)
    row.pool = poolTag
    self:ApplyOutpostTenantSync(siteKey, guild, faction, captureTs, poolTag)
    if eventChanged or incremented or factionChanged then
        self:MarkDirty()
        self:RequestOutpostLedgerRebuild()
    end
    return incremented
end

function Overlord.Leaderboard:GetSortedOutposts(sortedGuildKillsForNames, yieldWork)
    local op = Overlord.Outpost
    local captureCounts = self:GetOutpostCaptureCountsTable()
    local tenants = self:GetOutpostTenantsTable()
    local sorted = {}
    local rowKeys = {}

    if Overlord.OutpostSites then
        for siteKey in pairs(Overlord.OutpostSites) do
            if yieldWork then yieldWork() end
            -- La carte et le classement doivent projeter le meme tenant canonique.
            -- LO reste un registre de rattrapage et LOC le compteur historique ; aucun
            -- des deux ne peut marquer un ancien tenant comme encore present si OP a avance.
            local st = op and op.GetState and op:GetState(siteKey) or nil
            local guild, fac = "", nil
            if st and op.GetOutpostDisplayTenant then
                guild, fac = op:GetOutpostDisplayTenant(st, siteKey)
            end
            guild = sanitizeGuildName(guild or "")
            local statePool = st and ((st.status == "in_progress" and st.previousOwnerPool)
                or st.pool) or ""
            local rowPool = resolveOutpostLbPoolTag(statePool)
            -- Un observateur arrive parfois pendant un assaut, avant d'avoir le pool
            -- stable precedent dans OP. LO peut alors completer le pool, jamais l'identite.
            local t = getValidOutpostTenantRow(self, siteKey, tenants[siteKey])
            if st and st.status == "in_progress" and normalizeSavedVarsPool(statePool) == ""
                and t and t.guildKey == guild:lower() and t.faction == fac then
                rowPool = resolveOutpostLbPoolTag(t.pool)
            end
            local currentlyHeld = guild ~= ""
            if guild ~= "" and (fac == "Alliance" or fac == "Horde") then
                local key = guild:lower()
                local rowKey = outpostCaptureRowKey(siteKey, key, rowPool)
                rowKeys[rowKey] = true
                local bucket = captureCounts[rowKey]
                local captures = bucket and math.floor(tonumber(bucket.count) or 0) or 0
                sorted[#sorted + 1] = {
                    guild = guild,
                    faction = fac,
                    outpostAtlas = op and op.GetMainHallAtlasForFaction
                        and op:GetMainHallAtlasForFaction(fac),
                    outpostSiteKey = siteKey,
                    captures = captures,
                    currentlyHeld = currentlyHeld,
                    pool = rowPool,
                }
            end
        end
    end

    local captureCursor = nil
    while true do
        local ok, rowKey, bucket = pcall(next, captureCounts, captureCursor)
        if not ok then error(rowKey) end
        captureCursor = rowKey
        if rowKey == nil then break end
        if type(bucket) == "table" and not rowKeys[rowKey] then
            local captures = math.floor(tonumber(bucket.count) or 0)
            if captures > 0 and sanitizeGuildName(bucket.guild or "") ~= ""
                and outpostLbPoolMatchesCurrent(resolveOutpostLbPoolTag(bucket.pool)) then
                rowKeys[rowKey] = true
                sorted[#sorted + 1] = {
                    guild = bucket.guild,
                    faction = bucket.faction or "",
                    outpostAtlas = nil,
                    outpostSiteKey = bucket.siteKey,
                    captures = captures,
                    currentlyHeld = false,
                    pool = resolveOutpostLbPoolTag(bucket.pool),
                }
            end
        end
        if yieldWork then yieldWork() end
    end

    sortRowsWithYield(sorted, function(a, b)
        local ca, cb = a.captures or 0, b.captures or 0
        if ca ~= cb then return ca > cb end
        if (a.currentlyHeld and 1 or 0) ~= (b.currentlyHeld and 1 or 0) then
            return a.currentlyHeld and not b.currentlyHeld
        end
        if (a.guild or "") ~= (b.guild or "") then
            return (a.guild or "") < (b.guild or "")
        end
        return (a.outpostSiteKey or "") < (b.outpostSiteKey or "")
    end, yieldWork)
    return sorted
end

-- Nombre max de campagnes archivees (au-dela, les plus anciennes sont supprimees)
local MAX_HISTORY_ENTRIES = 12
-- Top N joueurs conserves par archive : l'historique est un souvenir compact, pas une
-- copie integrale du bucket (une archive complete pesait ~100 Ko en event massif et
-- l'historique etait le premier poste de taille du fichier SavedVariables).
local MAX_HISTORY_PLAYERS = 100

function Overlord.Leaderboard:ArchiveCampaign(campaignStartOverride)
    if not OverlordDB then return end
    if not OverlordDB.history then
        OverlordDB.history = {}
    end

    local hasData = false
    for _ in pairs(self.kills) do hasData = true; break end
    if not hasData then
        for _ in pairs(self.captures) do hasData = true; break end
    end
    if not hasData then
        for _ in pairs(self.bountyTimes or {}) do hasData = true; break end
    end
    if not hasData then
        for _ in pairs(self.bountyKills or {}) do hasData = true; break end
    end
    if not hasData then return end

    local archivedCampaignStart = tonumber(campaignStartOverride) or 0
    if archivedCampaignStart <= 0 then
        archivedCampaignStart = tonumber(OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0
    end
    if archivedCampaignStart <= 0 then
        local lastCampaign = (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
        if lastCampaign > 0 then
            archivedCampaignStart = lastCampaign
        else
            archivedCampaignStart = self:GetCurrentCampaignStart()
        end
    end
    local scoreBucketEpoch = GetMatchingLeaderboardScoreBucketEpoch(archivedCampaignStart)

    local dateKey = date("%Y-%m-%d_%H%M%S")
    local entry = {
        kills = {},
        captureCounts = {},
        bountyTimes = {},
        bountyKills = {},
        totalZonesCaptured = Overlord.Zones:GetCapturedCount(),
        campaignStart = archivedCampaignStart,
        scoreBucketEpoch = scoreBucketEpoch > 0 and scoreBucketEpoch or nil,
    }
    OverlordDB.history[dateKey] = entry

    local killRows = {}
    for k, v in pairs(self.kills) do
        killRows[#killRows + 1] = { name = k, kills = tonumber(v) or 0 }
    end
    table.sort(killRows, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        return (a.name or "") < (b.name or "")
    end)
    for i = 1, math.min(#killRows, MAX_HISTORY_PLAYERS) do
        entry.kills[killRows[i].name] = killRows[i].kills
    end

    -- Compte de captures par joueur : les listes completes de zoneIds n'etaient
    -- lues nulle part et dominaient le poids de l'archive.
    local capRows = {}
    for k, v in pairs(self.captureCount or {}) do
        local n = tonumber(v) or 0
        if n > 0 then capRows[#capRows + 1] = { name = k, count = n } end
    end
    if #capRows == 0 then
        for k, v in pairs(self.captures) do
            local n = (type(v) == "table") and #v or (tonumber(v) or 0)
            if n > 0 then capRows[#capRows + 1] = { name = k, count = n } end
        end
    end
    table.sort(capRows, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    for i = 1, math.min(#capRows, MAX_HISTORY_PLAYERS) do
        entry.captureCounts[capRows[i].name] = capRows[i].count
    end

    local bountyTimeRows = {}
    for k, v in pairs(self.bountyTimes or {}) do
        local n = tonumber(v) or 0
        if n > 0 then bountyTimeRows[#bountyTimeRows + 1] = { name = k, count = n } end
    end
    table.sort(bountyTimeRows, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    for i = 1, math.min(#bountyTimeRows, MAX_HISTORY_PLAYERS) do
        entry.bountyTimes[bountyTimeRows[i].name] = bountyTimeRows[i].count
    end

    local bountyKillRows = {}
    for k, v in pairs(self.bountyKills or {}) do
        local n = tonumber(v) or 0
        if n > 0 then bountyKillRows[#bountyKillRows + 1] = { name = k, count = n } end
    end
    table.sort(bountyKillRows, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    for i = 1, math.min(#bountyKillRows, MAX_HISTORY_PLAYERS) do
        entry.bountyKills[bountyKillRows[i].name] = bountyKillRows[i].count
    end

    -- Rotation : supprime les campagnes les plus anciennes pour eviter que OverlordDB.history
    -- croisse indefiniment et remplisse le disque des joueurs.
    local keys = {}
    for k in pairs(OverlordDB.history) do keys[#keys + 1] = k end
    if #keys > MAX_HISTORY_ENTRIES then
        table.sort(keys)
        for i = 1, #keys - MAX_HISTORY_ENTRIES do
            OverlordDB.history[keys[i]] = nil
        end
    end
end

-- True si ce nom (ou sa cle dedup) a ete credite en local (combat), pas seulement via sync.
function Overlord.Leaderboard:HasLocalKillCredit(playerName)
    if not playerName or playerName == "" then return false end
    if self:IsLocalDisplayName(playerName) then return true end
    local keys = OverlordDB and OverlordDB.leaderboardLocalKillKeys
    if not keys then return false end
    if keys[playerName] then return true end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(playerName)
        if dk and keys["#dk:" .. dk] then return true end
    end
    return false
end

-- Marque persistee en SavedVariables (sans inferer depuis le perso connecte).
function Overlord.Leaderboard:HasPersistedLocalKillMark(playerName)
    if not playerName or playerName == "" then return false end
    local keys = OverlordDB and OverlordDB.leaderboardLocalKillKeys
    if not keys then return false end
    if keys[playerName] then return true end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(playerName)
        if dk and keys["#dk:" .. dk] then return true end
    end
    return false
end

-- Extrait les kills locaux d'un bucket avant wipe campagne (perso + MarkLocalKillCredit).
function Overlord.Leaderboard:SalvageLocalKillRowsFromBucket(bucket)
    local out = {}
    if not bucket or type(bucket.kills) ~= "table" then return out end
    for name, count in pairs(bucket.kills) do
        local n = tonumber(count) or 0
        if n > 0 and self:HasLocalKillCredit(name) then
            out[name] = n
        end
    end
    return out
end

-- Reinjecte les kills salves (max) dans le bucket courant apres wipe ou resync asymetrique.
function Overlord.Leaderboard:MergeSalvagedLocalKills(salvaged)
    if not salvaged or not next(salvaged) then return false end
    local dirty = false
    for name, count in pairs(salvaged) do
        local n = tonumber(count) or 0
        if n > 0 and name and name ~= "" then
            if n > (self.kills[name] or 0) then
                self.kills[name] = n
                UpdateDedupKillMaxIndex(name, n)
                dirty = true
            end
            self:MarkLocalKillCredit(name)
        end
    end
    if dirty then self:MarkDirty() end
    return dirty
end

-- Rattrapage : archive de la campagne courante si kills locaux absents ou sous-estimes.
function Overlord.Leaderboard:RestoreLocalKillsFromLatestHistoryIfNeeded()
    if not OverlordDB or not OverlordDB.history then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if campaignStart <= 0 then return false end
    if GetMatchingLeaderboardScoreBucketEpoch(campaignStart) <= 0 then return false end
    local keys = {}
    for k in pairs(OverlordDB.history) do keys[#keys + 1] = k end
    if #keys == 0 then return false end
    table.sort(keys)
    local salvaged = {}
    for i = #keys, 1, -1 do
        local entry = OverlordDB.history[keys[i]]
        if type(entry) == "table" and type(entry.kills) == "table" then
            local entryStart = tonumber(entry.campaignStart) or 0
            if entryStart == campaignStart and LeaderboardCampaignEpochsMatch(
                entry.scoreBucketEpoch, entryStart) then
                for name, count in pairs(entry.kills) do
                    local n = tonumber(count) or 0
                    if n > 0 and (self:HasPersistedLocalKillMark(name) or self:IsLocalDisplayName(name)) then
                        local prev = salvaged[name] or 0
                        if n > prev then salvaged[name] = n end
                    end
                end
                break
            end
        end
    end
    if not next(salvaged) then return false end
    local dirty = false
    for name, count in pairs(salvaged) do
        local n = tonumber(count) or 0
        if n > (self.kills[name] or 0) then
            dirty = true
            break
        end
    end
    if not dirty then return false end
    return self:MergeSalvagedLocalKills(salvaged)
end

-- Slot unique de snapshot complet du classement RECU (pas seulement les kills locaux).
-- Filet anti-perte : si un wipe accidentel (bug reset) ou un crash vide le bucket, on restaure
-- localement la vue complete au login. Keye sur le campaignStart du BUCKET (les donnees
-- appartiennent a cette campagne), pas sur GetCurrentCampaignStart : ainsi un vrai reset hebdo
-- (snapshot = ancienne semaine) ne ressuscite jamais d'anciennes donnees, alors qu'un faux
-- reset mid-week (snapshot = semaine courante) reste recuperable.
local LADDER_SNAPSHOT_MAX_KILL_PLAYERS = Overlord.Leaderboard.KILL_RANK_LIMIT
local LADDER_SNAPSHOT_MAX_CAPTURE_PLAYERS_PER_FACTION = 25
local LADDER_SNAPSHOT_WORK_PER_SLICE = 80
local LADDER_SNAPSHOT_SLICE_BUDGET_MS = 1
local LADDER_SNAPSHOT_MAX_ZONES_PER_PLAYER = 32
local LADDER_SNAPSHOT_MAX_ZONE_BYTES_PER_PLAYER = 120

local function SnapshotRowIsBetter(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return (a.name or "") < (b.name or "")
end

local function SnapshotRowIsWorse(a, b)
    return SnapshotRowIsBetter(b, a)
end

local function SnapshotHeapSiftUp(rows, index)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not SnapshotRowIsWorse(rows[index], rows[parent]) then break end
        rows[index], rows[parent] = rows[parent], rows[index]
        index = parent
    end
end

local function SnapshotHeapSiftDown(rows, heapSize, index)
    while true do
        local left = index * 2
        if left > heapSize then break end
        local right = left + 1
        local worst = left
        if right <= heapSize and SnapshotRowIsWorse(rows[right], rows[left]) then
            worst = right
        end
        if not SnapshotRowIsWorse(rows[worst], rows[index]) then break end
        rows[index], rows[worst] = rows[worst], rows[index]
        index = worst
    end
end

function Overlord.Leaderboard:NewTopSnapshotHeap(maxRows)
    return { rows = {}, size = 0, maxRows = maxRows }
end

-- Offre une ligne au tas borne. Cette fonction ne parcourt jamais le score source :
-- SnapshotCurrentCampaignFull l'appelle avec un quota strict entre deux frames.
function Overlord.Leaderboard:OfferTopSnapshotRow(heapState, name, value)
    local rows = heapState and heapState.rows
    if not rows then return end
    local count = tonumber(value) or 0
    if count <= 0 then return end
    local heapSize = heapState.size or 0
    local maxRows = heapState.maxRows or LADDER_SNAPSHOT_MAX_KILL_PLAYERS

    if heapSize < maxRows then
        heapSize = heapSize + 1
        rows[heapSize] = { name = name, count = count }
        heapState.size = heapSize
        SnapshotHeapSiftUp(rows, heapSize)
    elseif count > rows[1].count
        or (count == rows[1].count and (name or "") < (rows[1].name or "")) then
        -- Reutiliser la racine : aucune allocation apres les premieres lignes bornees.
        rows[1].name = name
        rows[1].count = count
        SnapshotHeapSiftDown(rows, heapSize, 1)
    end
end

local WEEKLY_ARCHIVE_WORK_PER_SLICE = 80
local WEEKLY_ARCHIVE_SLICE_BUDGET_MS = 1

local function NewEmptyWeeklyLeaderboardBucket(resetEpoch, campaignId)
    return {
        kills = {},
        captures = {},
        captureCount = {},
        bountyTimes = {},
        bountyKills = {},
        playerInfo = {},
        campaignStart = resetEpoch,
        campaignId = campaignId,
        -- Ne pas rejouer les migrations historiques au premier login de
        -- chaque nouvelle campagne hebdomadaire.
        repairVersion = 3,
    }
end

local function WeeklyArchiveMarkerCanClear(marker)
    return type(marker) == "table"
        and marker.archiveComplete == true
        and marker.leaderboardSideEffectsApplied == true
        and marker.coreSideEffectsApplied == true
end

local function TryClearWeeklyArchiveMarker(marker)
    if not OverlordDB or OverlordDB.pendingWeeklyArchive ~= marker
        or not WeeklyArchiveMarkerCanClear(marker) then return false end
    OverlordDB.pendingWeeklyArchive = nil
    if tonumber(OverlordDB.pendingWeeklyResetAt) == tonumber(marker.resetEpoch) then
        OverlordDB.pendingWeeklyResetAt = nil
    end
    return true
end

-- Etape atomique de la frontiere : le bucket actif devient immediatement un
-- nouveau bucket vide. Aucune iteration du ladder n'a lieu ici.
function Overlord.Leaderboard:OpenAtomicWeeklyBucket(archiveEpoch, resetEpoch, campaignId)
    if not OverlordDB then return false end
    archiveEpoch = math.floor(tonumber(archiveEpoch) or 0)
    resetEpoch = math.floor(tonumber(resetEpoch) or 0)
    campaignId = math.floor(tonumber(campaignId) or 0)
    if resetEpoch <= 0 then return false end

    local existing = OverlordDB.pendingWeeklyArchive
    local activeEpoch = math.floor(tonumber(
        OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0)
    if type(existing) == "table"
        and tonumber(existing.resetEpoch) == resetEpoch
        and LeaderboardCampaignEpochsMatch(activeEpoch, resetEpoch) then
        self:ResumePendingWeeklyArchive()
        return false
    end
    -- Un archivage hebdo finit en quelques tranches. Ne jamais ecraser son
    -- unique crash-marker par une seconde transition incoherente.
    if type(existing) == "table" then
        self:ResumePendingWeeklyArchive()
        return false
    end

    if archiveEpoch <= 0 then
        archiveEpoch = math.floor(tonumber(
            OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0)
    end
    if archiveEpoch <= 0 then archiveEpoch = resetEpoch - 604800 end
    if campaignId <= 0 and Overlord.TimestampToCampaignId then
        campaignId = Overlord:TimestampToCampaignId(resetEpoch)
    end

    local oldBucket = {
        kills = self.kills or {},
        captures = self.captures or {},
        captureCount = self.captureCount or {},
        bountyTimes = self.bountyTimes or {},
        bountyKills = self.bountyKills or {},
        playerInfo = self.playerInfo or {},
        campaignStart = archiveEpoch,
        campaignId = tonumber(OverlordDB.leaderboard and OverlordDB.leaderboard.campaignId) or 0,
    }
    local oldScoreBucketEpoch = GetMatchingLeaderboardScoreBucketEpoch(archiveEpoch)
    -- Keep one complete, detached campaign per region as a recovery checkpoint.
    -- The compact history drops metadata and lower ranks; the periodic snapshot
    -- will soon belong to the new week. Never import this checkpoint into scores
    -- automatically: a real weekly reset must remain a reset.
    local recoveryPool = Overlord.GetCurrentLeaderboardSavedVarsPool
        and Overlord:GetCurrentLeaderboardSavedVarsPool() or nil
    if recoveryPool == "global" then
        OverlordDB.leaderboardPreviousCampaigns = OverlordDB.leaderboardPreviousCampaigns or {}
        OverlordDB.leaderboardPreviousCampaigns[recoveryPool] = {
            bucket = oldBucket,
            scoreBucketEpoch = oldScoreBucketEpoch > 0 and oldScoreBucketEpoch or nil,
            resetEpoch = resetEpoch,
            savedAt = (GetServerTime and GetServerTime()) or time(),
        }
    end
    local marker = {
        version = 1,
        resetEpoch = resetEpoch,
        archiveEpoch = archiveEpoch,
        historyKey = date("%Y-%m-%d_%H%M%S", resetEpoch),
        scoreBucketEpoch = oldScoreBucketEpoch > 0 and oldScoreBucketEpoch or nil,
        totalZonesCaptured = Overlord.Zones and Overlord.Zones.GetCapturedCount
            and Overlord.Zones:GetCapturedCount() or 0,
        bucket = oldBucket,
        archiveComplete = false,
        leaderboardSideEffectsApplied = false,
        coreSideEffectsApplied = false,
    }

    -- Le marker est pose avant de detacher l'ancien bucket. Sauve a la deconnexion,
    -- il suffit a reprendre l'archive sans jamais melanger les deux campagnes.
    OverlordDB.pendingWeeklyArchive = marker
    OverlordDB.pendingWeeklyResetAt = resetEpoch
    OverlordDB.lastResetTimestamp = resetEpoch
    OverlordDB.campaignId = campaignId

    local newBucket = NewEmptyWeeklyLeaderboardBucket(resetEpoch, campaignId)
    self.kills = newBucket.kills
    self.captures = newBucket.captures
    self.captureCount = newBucket.captureCount
    self.bountyTimes = newBucket.bountyTimes
    self.bountyKills = newBucket.bountyKills
    self.playerInfo = newBucket.playerInfo
    OverlordDB.leaderboard = newBucket
    OverlordDB.leaderboardDisplayCache = nil
    OverlordDB.leaderboardLocalKillKeys = {}
    OverlordDB.leaderboardResetEpoch = resetEpoch
    OverlordDB.leaderboardScoreBucketEpoch = resetEpoch

    if Overlord.GetCurrentLeaderboardSavedVarsPool then
        local pool = Overlord:GetCurrentLeaderboardSavedVarsPool()
        if pool and pool ~= "" then
            OverlordDB.leaderboardsByPool = OverlordDB.leaderboardsByPool or {}
            OverlordDB.leaderboardsByPool[pool] = newBucket
        end
    end

    dedupKillMaxIndex = {}
    dedupCaptureMaxIndex = {}
    dedupCanonicalIndex = {}
    dedupCanonicalValid = true
    dedupCanonicalGeneration = dedupCanonicalGeneration + 1
    self._networkHotKillsSource = self.kills
    self._networkHotCaptureSource = self.captureCount
    self._networkHotCapturesSource = self.captures
    self._networkHotPlayerInfoSource = self.playerInfo
    self._networkHotCanonicalGeneration = dedupCanonicalGeneration
    self._nextWritableCampaignCheckAt = resetEpoch + 518400
    self._snapshotBuildGeneration = (self._snapshotBuildGeneration or 0) + 1
    self._snapshotBuildPending = nil
    self:ResolveSnapshotCompletion(false)
    self:MarkMetaDirty()
    if Overlord.LifetimeStats and Overlord.LifetimeStats.OnAtomicWeeklyBucketOpened then
        Overlord.LifetimeStats:OnAtomicWeeklyBucketOpened()
    end
    C_Timer.After(0, function()
        if Overlord and Overlord.Leaderboard then
            Overlord.Leaderboard:ResumePendingWeeklyArchive()
        end
    end)
    return true
end

function Overlord.Leaderboard:MarkWeeklyResetCoreSideEffectsApplied(resetEpoch)
    local marker = OverlordDB and OverlordDB.pendingWeeklyArchive
    if type(marker) ~= "table"
        or tonumber(marker.resetEpoch) ~= tonumber(resetEpoch) then return false end
    marker.coreSideEffectsApplied = true
    TryClearWeeklyArchiveMarker(marker)
    return true
end

-- Reprend (login/crash inclus) l'archive compacte de l'ancien bucket. Les quatre
-- sources sont immuables car elles ont ete detachees avant la premiere tranche.
function Overlord.Leaderboard:ResumePendingWeeklyArchive()
    local marker = OverlordDB and OverlordDB.pendingWeeklyArchive
    if type(marker) ~= "table" then return false end
    if marker.archiveComplete == true then
        TryClearWeeklyArchiveMarker(marker)
        return true
    end
    if self._weeklyArchiveBuildPending then return true end
    local bucket = marker.bucket
    if type(bucket) ~= "table" then return false end

    local state = {
        marker = marker,
        phase = "kills",
        key = nil,
        killHeap = self:NewTopSnapshotHeap(MAX_HISTORY_PLAYERS),
        capHeap = self:NewTopSnapshotHeap(MAX_HISTORY_PLAYERS),
        bountyTimeHeap = self:NewTopSnapshotHeap(MAX_HISTORY_PLAYERS),
        bountyKillHeap = self:NewTopSnapshotHeap(MAX_HISTORY_PLAYERS),
        captureCountFallback = not next(bucket.captureCount or {}),
    }
    self._weeklyArchiveBuildPending = state

    local function finishMarker()
        if self._weeklyArchiveBuildPending ~= state
            or OverlordDB.pendingWeeklyArchive ~= marker then return end
        marker.bucket = nil
        marker.archiveComplete = true
        self._weeklyArchiveBuildPending = nil
        TryClearWeeklyArchiveMarker(marker)
        if Overlord.MarkDirty then Overlord:MarkDirty() end
    end

    local function publishArchive()
        if self._weeklyArchiveBuildPending ~= state
            or OverlordDB.pendingWeeklyArchive ~= marker then return end
        local heaps = {
            state.killHeap, state.capHeap, state.bountyTimeHeap, state.bountyKillHeap,
        }
        local hasData = false
        for i = 1, #heaps do
            if (heaps[i].size or 0) > 0 then
                hasData = true
                table.sort(heaps[i].rows, SnapshotRowIsBetter)
            end
        end
        if hasData then
            OverlordDB.history = OverlordDB.history or {}
            local entry = {
                kills = {},
                captureCounts = {},
                bountyTimes = {},
                bountyKills = {},
                totalZonesCaptured = tonumber(marker.totalZonesCaptured) or 0,
                campaignStart = tonumber(marker.archiveEpoch) or 0,
                scoreBucketEpoch = tonumber(marker.scoreBucketEpoch) or nil,
            }
            local targets = {
                entry.kills, entry.captureCounts, entry.bountyTimes, entry.bountyKills,
            }
            for hi = 1, #heaps do
                local rows = heaps[hi].rows
                for i = 1, #rows do
                    targets[hi][rows[i].name] = rows[i].count
                end
            end
            -- Cle deterministe : une reprise apres crash remplace la meme archive.
            OverlordDB.history[marker.historyKey] = entry
            state.newestHistory = {}
            state.phase = "history"
            state.key = nil
            return
        end
        finishMarker()
    end

    local function runSlice()
        if self._weeklyArchiveBuildPending ~= state
            or OverlordDB.pendingWeeklyArchive ~= marker then return end
        local budget = WEEKLY_ARCHIVE_WORK_PER_SLICE
        local processed = 0
        local sliceStarted = debugprofilestop and debugprofilestop() or nil
        while budget > 0 do
            if state.phase == "history" then
                local key, value = next(OverlordDB.history or {}, state.key)
                if key == nil then
                    local compactHistory = {}
                    for i = 1, #(state.newestHistory or {}) do
                        local row = state.newestHistory[i]
                        compactHistory[row.key] = row.value
                    end
                    OverlordDB.history = compactHistory
                    finishMarker()
                    return
                end
                state.key = key
                local newest = state.newestHistory
                local insertAt = #newest + 1
                for i = 1, #newest do
                    if key > newest[i].key then
                        insertAt = i
                        break
                    end
                end
                if insertAt <= MAX_HISTORY_ENTRIES then
                    table.insert(newest, insertAt, { key = key, value = value })
                    if #newest > MAX_HISTORY_ENTRIES then newest[#newest] = nil end
                end
                budget = budget - 1
                processed = processed + 1
                if sliceStarted and processed % 8 == 0
                    and (debugprofilestop() - sliceStarted) >= WEEKLY_ARCHIVE_SLICE_BUDGET_MS then
                    break
                end
            else
            local source, heap
            if state.phase == "kills" then
                source, heap = bucket.kills, state.killHeap
            elseif state.phase == "captures" then
                source = state.captureCountFallback and bucket.captures or bucket.captureCount
                heap = state.capHeap
            elseif state.phase == "bountyTimes" then
                source, heap = bucket.bountyTimes, state.bountyTimeHeap
            elseif state.phase == "bountyKills" then
                source, heap = bucket.bountyKills, state.bountyKillHeap
            else
                publishArchive()
                if self._weeklyArchiveBuildPending ~= state then return end
            end

            if state.phase ~= "history" then
                local key, value = next(source or {}, state.key)
                if key == nil then
                    state.key = nil
                    if state.phase == "kills" then state.phase = "captures"
                    elseif state.phase == "captures" then state.phase = "bountyTimes"
                    elseif state.phase == "bountyTimes" then state.phase = "bountyKills"
                    else state.phase = "finish" end
                else
                    state.key = key
                    if state.captureCountFallback and state.phase == "captures"
                        and type(value) == "table" then value = #value end
                    self:OfferTopSnapshotRow(heap, key, value)
                    budget = budget - 1
                    processed = processed + 1
                    if sliceStarted and processed % 8 == 0
                        and (debugprofilestop() - sliceStarted) >= WEEKLY_ARCHIVE_SLICE_BUDGET_MS then
                        break
                    end
                end
            end
            end
        end
        C_Timer.After(0, runSlice)
    end

    C_Timer.After(0, runSlice)
    return true
end

function Overlord.Leaderboard:ResolveSnapshotCompletion(success)
    local callbacks = self._snapshotCompletionCallbacks
    self._snapshotCompletionCallbacks = nil
    if type(callbacks) ~= "table" then return end
    for i = 1, #callbacks do
        pcall(callbacks[i], success == true)
    end
end

-- Le reset hebdomadaire doit attendre une tranche complete, sans refaire le scan
-- en une seule frame. Les callbacks sont rares (une fois par semaine) et partagent
-- le build deja lance par l'autosave.
function Overlord.Leaderboard:SnapshotCurrentCampaignBeforeReset(callback)
    if type(callback) ~= "function" then return false end
    self._snapshotCompletionCallbacks = self._snapshotCompletionCallbacks or {}
    self._snapshotCompletionCallbacks[#self._snapshotCompletionCallbacks + 1] = callback
    self:SnapshotCurrentCampaignFull()
    return true
end

function Overlord.Leaderboard:SnapshotCurrentCampaignFull()
    if not OverlordDB or self._storageBound ~= true then
        self:ResolveSnapshotCompletion(false)
        return
    end
    if self._snapshotDirty == false then
        self:ResolveSnapshotCompletion(true)
        return true
    end
    if self._snapshotBuildPending then return true end
    -- Share the login index builder, so aliases cannot occupy two of the 500 slots.
    if self:EnsureNetworkHotIndexesPrepared() ~= true then
        if self._networkHotIndexPrepFailed or (self._snapshotIndexWaitAttempts or 0) >= 120 then
            self._snapshotIndexWaitAttempts = nil
            self:ResolveSnapshotCompletion(false)
            return false
        end
        if not self._snapshotIndexWaitPending then
            self._snapshotIndexWaitPending = true
            self._snapshotIndexWaitAttempts = (self._snapshotIndexWaitAttempts or 0) + 1
            C_Timer.After(0.25, function()
                self._snapshotIndexWaitPending = nil
                self:SnapshotCurrentCampaignFull()
            end)
        end
        return true
    end
    self._snapshotIndexWaitAttempts = nil
    local campaignStart = tonumber(OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0
    if campaignStart <= 0 then campaignStart = self:GetCurrentCampaignStart() end
    if campaignStart <= 0 then
        self:ResolveSnapshotCompletion(false)
        return
    end
    local scoreBucketEpoch = GetMatchingLeaderboardScoreBucketEpoch(campaignStart)
    if scoreBucketEpoch <= 0 then
        self:ResolveSnapshotCompletion(false)
        return
    end

    self._snapshotBuildGeneration = (self._snapshotBuildGeneration or 0) + 1
    local state = {
        generation = self._snapshotBuildGeneration,
        revision = self._snapshotRevision or 0,
        phase = "kills",
        key = nil,
        campaignStart = campaignStart,
        scoreBucketEpoch = scoreBucketEpoch,
        killHeap = newDisplayTopK(LADDER_SNAPSHOT_MAX_KILL_PLAYERS),
        killIndex = dedupKillMaxIndex,
        canonicalIndex = dedupCanonicalIndex,
        canonicalGeneration = dedupCanonicalGeneration,
        metaIndex = self._dedupMetaIndex,
        capHeapAlliance = self:NewTopSnapshotHeap(
            LADDER_SNAPSHOT_MAX_CAPTURE_PLAYERS_PER_FACTION),
        capHeapHorde = self:NewTopSnapshotHeap(
            LADDER_SNAPSHOT_MAX_CAPTURE_PLAYERS_PER_FACTION),
        capHeapUnknown = self:NewTopSnapshotHeap(
            LADDER_SNAPSHOT_MAX_CAPTURE_PLAYERS_PER_FACTION),
        -- Conserver l'identite des tables. Les mises a jour monotones de scores
        -- peuvent continuer pendant les tranches; un swap de campagne, lui, annule.
        killSource = self.kills,
        captureSource = self.captureCount,
        playerInfoSource = self.playerInfo,
        capturesSource = self.captures,
    }
    self._snapshotBuildPending = state

    local finalWork, finalStarted = 0, 0
    local function yieldFinalWork()
        finalWork = finalWork + 1
        if finalWork >= LADDER_SNAPSHOT_WORK_PER_SLICE
            or (debugprofilestop and debugprofilestop() - finalStarted >= LADDER_SNAPSHOT_SLICE_BUDGET_MS) then
            coroutine.yield()
        end
    end

    local function finishSnapshot()
        local liveCampaignStart = tonumber(
            OverlordDB.leaderboard and OverlordDB.leaderboard.campaignStart) or 0
        if liveCampaignStart <= 0 then liveCampaignStart = self:GetCurrentCampaignStart() end
        if self._snapshotBuildPending ~= state
            or self.kills ~= state.killSource
            or self.captureCount ~= state.captureSource
            or self.playerInfo ~= state.playerInfoSource
            or self.captures ~= state.capturesSource
            or not LeaderboardCampaignEpochsMatch(liveCampaignStart, state.campaignStart) then
            self._snapshotBuildPending = nil
            self:ResolveSnapshotCompletion(false)
            return
        end
        local changedDuringBuild = state.revision ~= (self._snapshotRevision or 0)
        local killRows = state.killHeap.rows
        local capRows = {}
        local function appendCaptureHeap(heap)
            local rows = heap and heap.rows or {}
            for i = 1, #rows do capRows[#capRows + 1] = rows[i] end
        end
        appendCaptureHeap(state.capHeapAlliance)
        appendCaptureHeap(state.capHeapHorde)
        appendCaptureHeap(state.capHeapUnknown)
        sortRowsWithYield(killRows, SnapshotRowIsBetter, yieldFinalWork)
        sortRowsWithYield(capRows, SnapshotRowIsBetter, yieldFinalWork)
        -- Preserve a recoverable snapshot, but publish an attested empty bucket
        -- on a fresh install so two empty peers can finish their handshake.
        local previous = OverlordDB.leaderboardSnapshot
        if #killRows == 0 and #capRows == 0 and type(previous) == "table"
            and previous.campaignStart == state.campaignStart
            and previous.scoreBucketEpoch == state.scoreBucketEpoch then
            self._snapshotDirty = changedDuringBuild
            self._snapshotBuildPending = nil
            self:ResolveSnapshotCompletion(true)
            return
        end

        local snapKills, snapCaps, snapInfo, snapCaptures, kept = {}, {}, {}, {}, {}
        local killOrder, captureOrder = {}, {}
        for i = 1, #killRows do
            local r = killRows[i]
            snapKills[r.name] = r.count
            killOrder[#killOrder + 1] = r.name
            kept[r.name] = true
            yieldFinalWork()
        end
        for i = 1, #capRows do
            local r = capRows[i]
            snapCaps[r.name] = r.count
            captureOrder[#captureOrder + 1] = r.name
            kept[r.name] = true
            yieldFinalWork()
        end
        -- Copy metadata in slices as well as sorting, even at the 500-player cap.
        for name in pairs(kept) do
            local info = state.metaIndex[GetKillDedupKey(name)]
                or (state.playerInfoSource and state.playerInfoSource[name])
            if type(info) == "table" then
                snapInfo[name] = {
                    class = info.class or "",
                    faction = info.faction or "",
                    factionAt = tonumber(info.factionAt) or 0,
                    locale = info.locale or "",
                    guild = info.guild or "",
                    guildAuth = info.guildAuth == true or nil,
                    guildAt = tonumber(info.guildAt) or 0,
                    pool = info.pool or "",
                    race = info.race or "",
                    raceSex = tonumber(info.raceSex) or 0,
                    raceAt = tonumber(info.raceAt) or 0,
                    level = math.floor(tonumber(info.level) or 0),
                }
            end
            yieldFinalWork()
        end
        -- Seules les zones des meilleurs capteurs visibles de chaque faction sont utiles.
        -- Chaque joueur est borne a la fois en nombre et en octets pour que le
        -- snapshot et les futurs LC restent independants de l'historique complet.
        for i = 1, #captureOrder do
            local name = captureOrder[i]
            local zones = state.capturesSource and state.capturesSource[name]
            if type(zones) == "table" then
                local copy, selected = {}, {}
                for j = 1, #zones do
                    local zoneId = tostring(zones[j] or "")
                    if zoneId ~= "" and IsValidLeaderboardZone(zoneId)
                        and not selected[zoneId] then
                        local insertAt = #copy + 1
                        for k = 1, #copy do
                            if zoneId < copy[k] then insertAt = k; break end
                        end
                        if insertAt <= LADDER_SNAPSHOT_MAX_ZONES_PER_PLAYER then
                            table.insert(copy, insertAt, zoneId)
                            selected[zoneId] = true
                            if #copy > LADDER_SNAPSHOT_MAX_ZONES_PER_PLAYER then
                                local removed = table.remove(copy)
                                selected[removed] = nil
                            end
                        end
                    end
                    yieldFinalWork()
                end
                local bytes, keep = 0, 0
                for j = 1, #copy do
                    local extra = #copy[j] + (j > 1 and 1 or 0)
                    if bytes + extra > LADDER_SNAPSHOT_MAX_ZONE_BYTES_PER_PLAYER then break end
                    bytes = bytes + extra
                    keep = j
                end
                for j = #copy, keep + 1, -1 do copy[j] = nil end
                if #copy > 0 then snapCaptures[name] = copy end
            end
            yieldFinalWork()
        end

        local pool = (Overlord.GetCurrentLeaderboardSavedVarsPool
            and Overlord:GetCurrentLeaderboardSavedVarsPool()) or ""
        OverlordDB.leaderboardSnapshot = {
            campaignStart = state.campaignStart,
            scoreBucketEpoch = state.scoreBucketEpoch,
            pool = pool,
            at = (GetServerTime and GetServerTime()) or time(),
            kills = snapKills,
            captureCount = snapCaps,
            captures = snapCaptures,
            playerInfo = snapInfo,
            killOrder = killOrder,
            captureOrder = captureOrder,
        }
        -- Une mutation de valeur pendant l'iteration ne doit pas jeter tout le
        -- travail. Publier ce snapshot monotone puis laisser dirty=true garantit
        -- qu'une passe ulterieure rattrape les dernieres valeurs sans starvation.
        self._snapshotDirty = changedDuringBuild or state.revision ~= (self._snapshotRevision or 0)
        self._snapshotBuildPending = nil
        self:ResolveSnapshotCompletion(true)
    end

    local function runSlice()
        if self._snapshotBuildPending ~= state then return end
        if self.kills ~= state.killSource or self.captureCount ~= state.captureSource
            or self.playerInfo ~= state.playerInfoSource or self.captures ~= state.capturesSource
            or not dedupCanonicalValid or state.canonicalGeneration ~= dedupCanonicalGeneration then
            self._snapshotBuildPending = nil
            self:ResolveSnapshotCompletion(false)
            return
        end
        if state.finalizer then
            finalWork, finalStarted = 0, debugprofilestop and debugprofilestop() or 0
            local ok = coroutine.resume(state.finalizer)
            if not ok then
                self._snapshotBuildPending = nil
                self:ResolveSnapshotCompletion(false)
            elseif coroutine.status(state.finalizer) ~= "dead" then
                C_Timer.After(0, runSlice)
            end
            return
        end
        local budget = LADDER_SNAPSHOT_WORK_PER_SLICE
        local processed = 0
        local sliceStarted = debugprofilestop and debugprofilestop() or nil
        while budget > 0 do
            local source = state.phase == "kills" and state.killIndex or state.captureSource
            -- Une compaction exceptionnelle peut retirer le curseur entre deux
            -- frames. Elle annule proprement cette passe; les simples increments
            -- et insertions, eux, ne provoquent plus d'abandon systematique.
            local ok, key, value = pcall(next, source or {}, state.key)
            if not ok then
                self._snapshotBuildPending = nil
                self:ResolveSnapshotCompletion(false)
                return
            end
            if key == nil then
                if state.phase == "kills" then
                    state.phase = "captures"
                    state.key = nil
                else
                    state.finalizer = coroutine.create(finishSnapshot)
                    C_Timer.After(0, runSlice)
                    return
                end
            else
                state.key = key
                if state.phase == "kills" then
                    local name = state.canonicalIndex[key] or key
                    if Overlord.Sync and Overlord.Sync.StripPipeLeakFromContributorName then
                        name = Overlord.Sync:StripPipeLeakFromContributorName(name)
                    end
                    offerDisplayTopK(self, state.killHeap, key, name, value)
                else
                    local info = self.playerInfo and self.playerInfo[key]
                    local faction = type(info) == "table" and info.faction or ""
                    local heap = faction == "Alliance" and state.capHeapAlliance
                        or faction == "Horde" and state.capHeapHorde
                        or state.capHeapUnknown
                    self:OfferTopSnapshotRow(heap, key, value)
                end
                budget = budget - 1
                processed = processed + 1
                if sliceStarted and processed % 8 == 0
                    and (debugprofilestop() - sliceStarted) >= LADDER_SNAPSHOT_SLICE_BUDGET_MS then
                    break
                end
            end
        end
        C_Timer.After(0, runSlice)
    end

    C_Timer.After(0, runSlice)
    return true
end

-- Restaure le snapshot complet dans le bucket courant si (et seulement si) il appartient a la
-- campagne en cours. Fusion max() uniquement (jamais de retour en arriere) et meta seulement pour
-- les noms absents (ne pas ecraser une meta plus fraiche). Aucun rebroadcast autoritaire ici : la
-- donnee re-circulera, si besoin, par les chemins SR/LK existants (deja plafonnes / anti-spoof).
function Overlord.Leaderboard:RestoreFullLadderFromSnapshotIfNeeded()
    if not OverlordDB then return false end
    local snap = OverlordDB.leaderboardSnapshot
    if type(snap) ~= "table" then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if campaignStart <= 0 then return false end
    if GetMatchingLeaderboardScoreBucketEpoch(campaignStart) <= 0 then return false end
    if (tonumber(snap.campaignStart) or 0) ~= campaignStart then return false end
    if not LeaderboardCampaignEpochsMatch(
        snap.scoreBucketEpoch, snap.campaignStart) then return false end
    local snapPool = normalizeSavedVarsPool(tostring(snap.pool or ""))
    local curPool = (Overlord.GetCurrentLeaderboardSavedVarsPool
        and Overlord:GetCurrentLeaderboardSavedVarsPool()) or ""
    curPool = normalizeSavedVarsPool(curPool)
    if snapPool ~= "" and curPool ~= "" and snapPool ~= curPool then return false end

    -- Un snapshot est une SavedVariable et peut donc provenir d'une ancienne
    -- version ou avoir ete edite/corrompu. Ne jamais laisser un scalaire ou une
    -- cle non textuelle interrompre la restauration apres quelques mutations.
    local snapshotKills = type(snap.kills) == "table" and snap.kills or {}
    local snapshotCaptureCount = type(snap.captureCount) == "table" and snap.captureCount or {}
    local snapshotPlayerInfo = type(snap.playerInfo) == "table" and snap.playerInfo or {}
    local dirty = false
    for name, count in pairs(snapshotKills) do
        local n = tonumber(count) or 0
        if type(name) == "string" and name ~= "" and n > 0
            and not (Overlord.Sync and Overlord.Sync.IsDeniedKillContributor
                and Overlord.Sync:IsDeniedKillContributor(name))
            and n > (tonumber(self.kills[name]) or 0) then
            self.kills[name] = n
            dirty = true
            -- L'index sera de toute facon reconstruit par NetworkIndexes apres
            -- MarkMetaDirty ; ce patch garde seulement le chemin nominal O(1).
            pcall(UpdateDedupKillMaxIndex, name, n)
        end
    end
    for name, count in pairs(snapshotCaptureCount) do
        local n = tonumber(count) or 0
        if type(name) == "string" and name ~= "" and n > 0
            and n > (tonumber(self.captureCount[name]) or 0) then
            self.captureCount[name] = n
            dirty = true
            pcall(UpdateDedupCaptureMaxIndex, name, n)
        end
    end
    for name, info in pairs(snapshotPlayerInfo) do
        if type(name) == "string" and name ~= "" and type(info) == "table" then
            local snapshotClass = type(info.class) == "string"
                and (self:NormalizeClassTokenForDisplay(info.class) or "") or ""
            local snapshotFaction = (info.faction == "Alliance" or info.faction == "Horde")
                and info.faction or ""
            local snapshotLocale = sanitizeLocaleTag(info.locale)
            local snapshotGuild = sanitizeGuildName(info.guild)
            local snapshotGuildAt = type(info.guild) == "string"
                and normalizeGuildAt(info.guildAt) or 0
            local snapshotPool = normalizeSavedVarsPool(info.pool)
            local snapshotRace = ""
            if type(info.race) == "string" then
                local sync = Overlord.Sync
                snapshotRace = sync and sync.NormalizeRaceFileToken
                    and (sync:NormalizeRaceFileToken(info.race) or "") or info.race
            end
            local snapshotRaceSex = math.floor(tonumber(info.raceSex) or 0)
            if snapshotRaceSex ~= 2 and snapshotRaceSex ~= 3 then snapshotRaceSex = 0 end
            local snapshotRaceAt = math.max(0, math.floor(tonumber(info.raceAt) or 0))
            local snapshotLevel = math.floor(tonumber(info.level) or 0)
            if snapshotLevel < 0 or snapshotLevel > 90 then snapshotLevel = 0 end
            local current = self.playerInfo[name]
            if not current then
                self.playerInfo[name] = {
                class = snapshotClass,
                faction = snapshotFaction,
                factionAt = math.max(0, math.floor(tonumber(info.factionAt) or 0)),
                locale = snapshotLocale,
                guild = snapshotGuild,
                guildAuth = info.guildAuth == true or nil,
                guildAt = snapshotGuildAt,
                pool = snapshotPool,
                race = snapshotRace,
                raceSex = snapshotRaceSex,
                raceAt = snapshotRaceAt,
                level = snapshotLevel,
                }
                dirty = true
                pcall(NoteDedupCanonicalName, self, name)
            else
                if (current.class or "") == "" and snapshotClass ~= "" then
                    current.class, dirty = snapshotClass, true
                end
                if (current.race or "") == "" and snapshotRace ~= "" then
                    current.race = snapshotRace
                    current.raceSex = snapshotRaceSex
                    current.raceAt = snapshotRaceAt
                    dirty = true
                end
                local currentGuild = sanitizeGuildName(current.guild or "")
                local currentGuildAt = normalizeGuildAt(current.guildAt)
                if type(info.guild) == "string" and guildRecordWins(
                    snapshotGuild, snapshotGuildAt, info.guildAuth,
                    currentGuild, currentGuildAt, current.guildAuth) then
                    current.guild = snapshotGuild
                    current.guildAuth = info.guildAuth == true or nil
                    current.guildAt = snapshotGuildAt
                    dirty = true
                end
                if (current.locale or "") == "" and snapshotLocale ~= "" then
                    current.locale, dirty = snapshotLocale, true
                end
                if (current.pool or "") == "" and snapshotPool ~= "" then
                    current.pool, dirty = snapshotPool, true
                end
                if (tonumber(current.level) or 0) <= 0
                    and snapshotLevel > 0 then
                    current.level = snapshotLevel
                    dirty = true
                end
            end
        end
    end

    if dirty then
        self:MarkMetaDirty()
        self:Save()
    end
    return dirty
end

-- Marque qu'un kill a ete credite en local (combat), pas seulement via sync reseau.
function Overlord.Leaderboard:MarkLocalKillCredit(playerName)
    if not playerName or playerName == "" or not OverlordDB then return end
    OverlordDB.leaderboardLocalKillKeys = OverlordDB.leaderboardLocalKillKeys or {}
    OverlordDB.leaderboardLocalKillKeys[playerName] = true
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(playerName)
        if dk and dk ~= "" then
            OverlordDB.leaderboardLocalKillKeys["#dk:" .. dk] = true
        end
    end
end

-- Compat API legacy. Un nom complet Nom-Royaume est une identite distincte et doit etre
-- replique pareil par tous les clients ; une decision basee sur le personnage local divergeait.
function Overlord.Leaderboard:ShouldRejectSyncKillCreditForAltRealm(playerName)
    return false
end

-- Conservee pour les anciens appelants : aucune purge receiver-local n'est convergente.
function Overlord.Leaderboard:PurgeUnplayedAltRealmKillRows()
    return false
end

-- Pool SavedVariables (us/fr/eu) connu pour ce contributeur (champ pool ou locale sync).
function Overlord.Leaderboard:GetContributorSavedVarsPool(playerName)
    if not playerName or playerName == "" then return "" end
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = getDK and sync:GetCaptureContributorDedupKey(playerName) or playerName

    local bestPool = ""
    if dk and self:EnsureDedupMetaIndex() then
        local bucket = self._dedupMetaIndex[dk:lower()]
        bestPool = normalizeSavedVarsPool(bucket and bucket.pool)
    else
        -- Mode degrade sans normaliseur dedup : consultation exacte uniquement.
        local info = self:GetPlayerInfo(playerName)
        bestPool = normalizeSavedVarsPool(info and info.pool)
        if bestPool == "" and info and info.locale and info.locale ~= ""
            and Overlord.SavedVarsPoolFromLocaleTag
            and not (GetCurrentRegion and GetCurrentRegion() == 1) then
            bestPool = normalizeSavedVarsPool(Overlord:SavedVarsPoolFromLocaleTag(info.locale) or "")
        end
    end
    if bestPool == "" then
        local rp = Overlord.RealmPools
        if rp and rp.InferPoolTagFromRealmName then
            bestPool = normalizeSavedVarsPool(rp:InferPoolTagFromRealmName(playerName) or "")
        end
    end
    return bestPool
end

-- Export Check PvP : sur region EU Blizzard, pools SV fr/de et eu = meme campagne (raid multilingue).
local function ExportSavedVarsPoolsCompatible(current, other)
    if current == "" or other == "" then return true end
    return normalizeSavedVarsPool(current) == normalizeSavedVarsPool(other)
end

-- Export Check PvP uniquement : ce contributeur appartient-il au pool actif ?
function Overlord.Leaderboard:ContributorBelongsToCurrentPool(playerName)
    if not playerName or playerName == "" then return true end
    if self:IsLocalDisplayName(playerName) then return true end

    local current = normalizeSavedVarsPool(Overlord:GetCurrentSavedVarsPool() or "")
    if current == "" then return true end

    local contributor = self:GetContributorSavedVarsPool(playerName)
    if contributor ~= "" then return ExportSavedVarsPoolsCompatible(current, contributor) end

    local loc = self:GetExportPlayerLocale(playerName)
    local locLower = (loc ~= "" and loc:lower()) or ""

    if locLower ~= "" and Overlord.SavedVarsPoolFromLocaleTag then
        local fromLoc = normalizeSavedVarsPool(Overlord:SavedVarsPoolFromLocaleTag(locLower) or "")
        if fromLoc ~= "" then return ExportSavedVarsPoolsCompatible(current, fromLoc) end
    end

    local keys = OverlordDB and OverlordDB.leaderboardLocalKillKeys
    local sync = Overlord.Sync
    local hasLocalKill = keys and keys[playerName]
    if not hasLocalKill and keys and sync and sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(playerName)
        hasLocalKill = dk and keys["#dk:" .. dk]
    end

    if hasLocalKill then return true end
    return true
end

-- Enregistre un kill pour un joueur, retourne le nouveau total
-- fromSync : true pour EK reseau (ne pas marquer credit local ni pool du receveur).
function Overlord.Leaderboard:RegisterKill(playerName, fromSync)
    if not self:EnsureWritableCampaignBucket() then return 0 end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return 0 end
    if sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(playerName) then
        return 0
    end
    -- Defense en profondeur anti-triche : le chemin additif (EK) ne peut pas pousser un
    -- nom au-dela du plafond plausible (source des totaux > 9999 observes).
    if fromSync and Overlord.PLAUSIBLE_SYNC_KILL_CEILING
        and (self.kills[playerName] or 0) >= Overlord.PLAUSIBLE_SYNC_KILL_CEILING then
        return self.kills[playerName] or 0
    end
    local isLocal = self:IsLocalDisplayName(playerName)
    local localPoolChanged = false
    if isLocal then
        local localLevel = Overlord.SafeUnitLevel and (Overlord:SafeUnitLevel("player") or 0) or 0
        if sync and sync.IsEligibleKillContributorLevel
            and not sync:IsEligibleKillContributorLevel(localLevel) then return 0 end
        if self.SetPlayerLevel then self:SetPlayerLevel(playerName, localLevel) end
        self:MarkLocalKillCredit(playerName)
        local poolTag = normalizeSavedVarsPool(Overlord:GetCurrentSavedVarsPool() or "")
        if poolTag ~= "" then
            local prev = self.playerInfo[playerName]
            if not prev then
                self.playerInfo[playerName] = {
                    class = "", faction = "", factionAt = 0, locale = "", guild = "", pool = poolTag,
                }
                localPoolChanged = true
            else
                if normalizeSavedVarsPool(prev.pool) ~= poolTag then
                    prev.pool = poolTag
                    localPoolChanged = true
                end
            end
        end
    end
    self.kills[playerName] = (self.kills[playerName] or 0) + 1
    UpdateDedupKillMaxIndex(playerName, self.kills[playerName])
    self:MaybeEnrichGuildForKillRow(playerName)
    if isLocal then
        if not self:CreditLocalLifetime("kills", 1, playerName) then
            self:RequestLifetimeFloorSyncForLocal()
        end
    end
    if self:IsLocalDisplayName(playerName) then
        self:UpdateLocalPlayerGuild()
    end
    -- SetPlayerLevel invalide normalement l'index, sauf niveau secret/indisponible ou
    -- niveau deja identique. Le pool reste une metadata et ne doit jamais laisser un
    -- bucket existant incomplet apres la creation/mutation locale de playerInfo.
    if localPoolChanged then self:MarkMetaDirty() end
    self:MarkDirty()
    return self.kills[playerName]
end

-- Ajoute N kills (prime de sang, sync reseau).
function Overlord.Leaderboard:AddKills(playerName, count, fromSync)
    if not self:EnsureWritableCampaignBucket() then return 0 end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    count = tonumber(count) or 0
    if not playerName or playerName == "" or count <= 0 then return 0 end
    if sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(playerName) then
        return 0
    end
    if self:IsLocalDisplayName(playerName) and sync and sync.IsEligibleKillContributorLevel
        and not sync:IsEligibleKillContributorLevel(
            Overlord.SafeUnitLevel and (Overlord:SafeUnitLevel("player") or 0) or 0) then
        return self.kills[playerName] or 0
    end
    -- Defense en profondeur anti-triche : ne pas depasser le plafond plausible en sync.
    if fromSync and Overlord.PLAUSIBLE_SYNC_KILL_CEILING then
        local ceiling = Overlord.PLAUSIBLE_SYNC_KILL_CEILING
        local current = self.kills[playerName] or 0
        if current >= ceiling then return current end
        if current + count > ceiling then count = ceiling - current end
    end
    self.kills[playerName] = (self.kills[playerName] or 0) + count
    UpdateDedupKillMaxIndex(playerName, self.kills[playerName])
    self:MaybeEnrichGuildForKillRow(playerName)
    if self:IsLocalDisplayName(playerName) then
        if not self:CreditLocalLifetime("kills", count, playerName) then
            self:RequestLifetimeFloorSyncForLocal()
        end
    end
    self:MarkDirty()
    return self.kills[playerName]
end

-- Met a jour le compteur de kills (sync : prend le max pour eviter les retours en arriere)
-- fromSync : true pour K/LK reseau (merge monotone du nom complet).
function Overlord.Leaderboard:SetPlayerKills(playerName, count, fromSync)
    if not self:EnsureWritableCampaignBucket() then return end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return end
    if sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(playerName) then return end
    -- Defense en profondeur anti-triche : un total sync ne peut pas depasser le plafond
    -- plausible (Sync l'a normalement deja filtre ; garde tout autre appelant fromSync).
    if fromSync and Overlord.PLAUSIBLE_SYNC_KILL_CEILING
        and (tonumber(count) or 0) > Overlord.PLAUSIBLE_SYNC_KILL_CEILING then
        return
    end
    if count > (self.kills[playerName] or 0) then
        self.kills[playerName] = count
        UpdateDedupKillMaxIndex(playerName, count)
        self:MaybeEnrichGuildForKillRow(playerName)
        if self:IsLocalDisplayName(playerName) then
            self:RequestLifetimeFloorSyncForLocal()
        end
        self:MarkDirty()
    end
end

function Overlord.Leaderboard:AddPlayerCapture(playerName, zoneId, fromSync)
    if not self:EnsureWritableCampaignBucket() then return end
    if not IsValidLeaderboardZone(zoneId) then return end
    if fromSync and Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING
        and (tonumber(self.captureCount[playerName]) or 0) >= Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING - 1 then
        return
    end
    -- Ecriture paresseuse : stocke le nom brut sans merge dedup.
    -- La fusion Nom / Nom-Royaume se fait a la lecture (UI, SR, Export).
    if not self.captures[playerName] then
        self.captures[playerName] = {}
    end
    local found = false
    for _, z in ipairs(self.captures[playerName]) do
        if z == zoneId then found = true; break end
    end
    if not found then
        table.insert(self.captures[playerName], zoneId)
    end
    self.captureCount[playerName] = (self.captureCount[playerName] or 0) + 1
    UpdateDedupCaptureMaxIndex(playerName, self.captureCount[playerName])
    if self:IsLocalDisplayName(playerName) then
        if not self:CreditLocalLifetime("captures", 1, playerName) then
            self:RequestLifetimeFloorSyncForLocal()
        end
    end
    self:MarkDirty()
end

-- Point d'entree commun aux zones, avant-postes et fortins de guilde. Le timestamp
-- terminal rend les replays multi-canaux idempotents via le dedup deja partage par C/ZS.
function Overlord.Leaderboard:CreditPlayerObjectiveCapture(
    playerName, objectiveId, faction, eventTs, fromSync, classToken)
    if type(playerName) ~= "string" or playerName == ""
        or not IsValidLeaderboardZone(objectiveId) then return false end
    eventTs = math.floor(tonumber(eventTs) or 0)
    if eventTs <= 0 then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    local sync = Overlord.Sync
    if sync and sync.ShouldSkipDuplicateLbCaptureBatch
        and sync:ShouldSkipDuplicateLbCaptureBatch(objectiveId, eventTs, playerName) then
        return false
    end
    self:SetPlayerFaction(playerName, faction)
    if classToken and classToken ~= "" and sync and sync.IsValidCaptureClassToken
        and sync:IsValidCaptureClassToken(classToken) then
        self:SetPlayerClassFromSync(playerName, classToken)
    end
    local before = tonumber(self.captureCount[playerName]) or 0
    self:AddPlayerCapture(playerName, objectiveId, fromSync)
    if (tonumber(self.captureCount[playerName]) or 0) <= before then return false end
    if sync and sync.MarkLbCaptureBatchCredited then
        sync:MarkLbCaptureBatchCredited(objectiveId, eventTs, playerName)
    end
    if fromSync and sync and sync.MarkFreshCaptureLeaderboardRow then
        sync:MarkFreshCaptureLeaderboardRow(playerName)
    end
    return true
end

function Overlord.Leaderboard:AddBountyActivation(playerName)
    if not self:EnsureWritableCampaignBucket() then return end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return end
    if not self.IsLocalDisplayName or not self:IsLocalDisplayName(playerName) then return end
    self.bountyTimes[playerName] = (self.bountyTimes[playerName] or 0) + 1
    self:CreditLocalLifetime("bountyTimes", 1, playerName)
    self:MarkDirty()
end

function Overlord.Leaderboard:AddBountyKill(playerName)
    if not self:EnsureWritableCampaignBucket() then return end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return end
    if not self.IsLocalDisplayName or not self:IsLocalDisplayName(playerName) then return end
    self.bountyKills[playerName] = (self.bountyKills[playerName] or 0) + 1
    self:CreditLocalLifetime("bountyKills", 1, playerName)
    self:MarkDirty()
end

-- Sync : prend le max pour eviter les retours en arriere (meme logique que SetPlayerKills)
function Overlord.Leaderboard:SetPlayerCaptureCount(playerName, count, fromSync)
    if not self:EnsureWritableCampaignBucket() then return end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return end
    -- Defense en profondeur : aucun appelant reseau ne peut contourner le filtre LC.
    if fromSync and Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING
        and (tonumber(count) or 0) >= Overlord.PLAUSIBLE_SYNC_CAPTURE_CEILING then
        return
    end
    if count > (self.captureCount[playerName] or 0) then
        self.captureCount[playerName] = count
        UpdateDedupCaptureMaxIndex(playerName, count)
        if self:IsLocalDisplayName(playerName) then
            self:RequestLifetimeFloorSyncForLocal()
        end
        self:MarkDirty()
    end
end

-- Nom d'affichage Forever : prefere Prenom Nom, jamais un suffixe -Royaume.
function Overlord.Leaderboard:ChooseRicherPlayerName(prev, new)
    if not prev then return new end
    if not new then return prev end
    local function hasPipe(s)
        return s and s:find("|", 1, true)
    end
    if hasPipe(prev) and not hasPipe(new) then return new end
    if hasPipe(new) and not hasPipe(prev) then return prev end
    local sync = Overlord.Sync
    if sync and sync.CanonicalForeverName then
        local prevCanon = sync:CanonicalForeverName(prev)
        local newCanon = sync:CanonicalForeverName(new)
        if newCanon and not prevCanon then return newCanon end
        if prevCanon and not newCanon then return prevCanon end
        if newCanon and prevCanon then
            if #newCanon > #prevCanon then return newCanon end
            if #newCanon == #prevCanon and newCanon < prevCanon then return newCanon end
            return prevCanon
        end
    end
    if #new > #prev then return new end
    if #new == #prev and new < prev then return new end
    return prev
end

local function countRowIsBetter(a, b)
    local aCount, bCount = tonumber(a and a.count) or 0, tonumber(b and b.count) or 0
    if aCount ~= bCount then return aCount > bCount end
    return tostring(a and a.name or "") < tostring(b and b.name or "")
end

-- Selection top-K par tas dont la racine est la pire ligne retenue. Le panneau ne
-- materialise ainsi jamais les milliers de lignes qu'il ne peut pas afficher.
local function selectTopCountRows(rowsByKey, limit)
    limit = math.max(0, math.floor(tonumber(limit) or 0))
    if limit <= 0 then return {} end
    local heap = {}
    local function siftUp(index)
        while index > 1 do
            local parent = math.floor(index / 2)
            if not countRowIsBetter(heap[parent], heap[index]) then break end
            heap[parent], heap[index] = heap[index], heap[parent]
            index = parent
        end
    end
    local function siftDown(index)
        while true do
            local left, right = index * 2, index * 2 + 1
            if left > #heap then return end
            local worse = left
            if right <= #heap and countRowIsBetter(heap[left], heap[right]) then worse = right end
            if not countRowIsBetter(heap[index], heap[worse]) then return end
            heap[index], heap[worse] = heap[worse], heap[index]
            index = worse
        end
    end
    for _, row in pairs(rowsByKey or {}) do
        if #heap < limit then
            heap[#heap + 1] = row
            siftUp(#heap)
        elseif countRowIsBetter(row, heap[1]) then
            heap[1] = row
            siftDown(1)
        end
    end
    return heap
end

-- Une meme personne peut avoir deux cles en base (ex. "Toto" et "Toto-Hyjal") : fusion pour affichage et export.
-- Evite que Check PvP somme deux lignes puis deduplique a l'import (totaux de guilde qui baissent).
function Overlord.Leaderboard:MergeNameCountRowsForDisplay(nameCountTable, maxRows)
    local merged = {}
    local sync = Overlord.Sync
    for name, count in pairs(nameCountTable or {}) do
        if name and name ~= "" and count and count > 0 then
            local key = (sync and sync.GetCaptureContributorDedupKey) and sync:GetCaptureContributorDedupKey(name) or name
            local e = merged[key]
            if not e then
                merged[key] = { name = name, count = count }
            else
                e.count = math.max(e.count, count)
                e.name = self:ChooseRicherPlayerName(e.name, name)
            end
        end
    end
    local list = maxRows and selectTopCountRows(merged, maxRows) or {}
    if not maxRows then
        for _, e in pairs(merged) do list[#list + 1] = e end
    end
    for _, e in ipairs(list) do
        if sync and sync.StripPipeLeakFromContributorName and e.name then
            e.name = sync:StripPipeLeakFromContributorName(e.name)
        end
    end
    return list
end

-- Fusionne les doublons Nom / Nom-Royaume dans les tables brutes (kills, captureCount, captures, playerInfo).
-- Appele une seule fois par Initialize ; rend OverlordDB canonique avant toute lecture ou export.
-- Regles : compteur = max des deux entrees ; nom conserve = forme la plus complete (Nom-Royaume).
function Overlord.Leaderboard:ConsolidateDuplicates()
    InvalidateDedupCanonicalIndex()
    local sync = Overlord.Sync
    local function dk(name)
        if not name or name == "" then return nil end
        return (sync and sync.GetCaptureContributorDedupKey) and sync:GetCaptureContributorDedupKey(name) or name
    end
    local rich = function(a, b) return self:ChooseRicherPlayerName(a, b) end
    local dirty = false

    -- Kills
    local killBucket = {}
    for name, count in pairs(self.kills) do
        local key = dk(name)
        if key then
            local e = killBucket[key]
            if not e then
                killBucket[key] = { canonical = name, count = count }
            else
                local best = rich(e.canonical, name)
                local merged = math.max(e.count, count)
                local other = (best == name) and e.canonical or name
                self.kills[other] = nil
                self.kills[best] = merged
                UpdateDedupKillMaxIndex(best, merged)
                killBucket[key] = { canonical = best, count = merged }
                dirty = true
            end
        end
    end

    -- captureCount
    local capBucket = {}
    for name, count in pairs(self.captureCount) do
        local key = dk(name)
        if key then
            local e = capBucket[key]
            if not e then
                capBucket[key] = { canonical = name, count = count }
            else
                local best = rich(e.canonical, name)
                local merged = math.max(e.count, count)
                local other = (best == name) and e.canonical or name
                self.captureCount[other] = nil
                self.captureCount[best] = merged
                UpdateDedupCaptureMaxIndex(best, merged)
                capBucket[key] = { canonical = best, count = merged }
                dirty = true
            end
        end
    end

    -- captures (listes de zones uniques)
    local zoneBucket = {}
    for name, zones in pairs(self.captures) do
        if type(zones) == "table" then
            local key = dk(name)
            if key then
                local e = zoneBucket[key]
                if not e then
                    zoneBucket[key] = { canonical = name }
                else
                    local best = rich(e.canonical, name)
                    local other = (best == name) and e.canonical or name
                    -- Fusionne la liste de zones sous le nom canonique
                    local targetZones = self.captures[best] or {}
                    local otherZones = self.captures[other] or {}
                    local seen = {}
                    for _, z in ipairs(targetZones) do seen[z] = true end
                    for _, z in ipairs(otherZones) do
                        if not seen[z] then
                            targetZones[#targetZones + 1] = z
                            seen[z] = true
                        end
                    end
                    self.captures[best] = targetZones
                    self.captures[other] = nil
                    zoneBucket[key] = { canonical = best }
                    dirty = true
                end
            end
        end
    end

    -- playerInfo : fusionne classe/faction (prefere valeurs non vides)
    local infoBucket = {}
    for name, info in pairs(self.playerInfo) do
        local key = dk(name)
        if key then
            local e = infoBucket[key]
            if not e then
                infoBucket[key] = { canonical = name }
            else
                local best = rich(e.canonical, name)
                local other = (best == name) and e.canonical or name
                -- Une seule implementation de fusion : elle conserve aussi guildAt/race/raceAt.
                lbMergeTwoPlayerInfoRows(self, best, other)
                infoBucket[key] = { canonical = best }
                dirty = true
            end
        end
    end

    if dirty then self:MarkMetaDirty() end
end

-- Fusionne toutes les cles (captureCount, captures, kills, playerInfo) qui partagent la meme cle dedup Sync.
-- Repare les doublons "Nom" vs "Nom-Royaume" / LC sans royaume apres changement de regle dedup.
function Overlord.Leaderboard:MergeDuplicateLeaderboardKeysByDedup(yieldWork)
    InvalidateDedupCanonicalIndex()
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    if not getDK then return end
    local nameSet = {}
    for n in pairs(self.captureCount or {}) do if yieldWork then yieldWork() end; if n and n ~= "" then nameSet[n] = true end end
    for n in pairs(self.captures or {}) do if yieldWork then yieldWork() end; if n and n ~= "" then nameSet[n] = true end end
    for n in pairs(self.kills or {}) do if yieldWork then yieldWork() end; if n and n ~= "" then nameSet[n] = true end end
    for n in pairs(self.playerInfo or {}) do if yieldWork then yieldWork() end; if n and n ~= "" then nameSet[n] = true end end
    -- Regroupe toutes les variantes en une seule passe. L'ancien code appelait
    -- MergeLeaderboardGroupForName (fallback O(N)) pour chaque groupe dont la
    -- premiere cle rencontree n'etait pas canonique : O(N^2) au pire au login.
    local groupsByDedup = {}
    for n in pairs(nameSet) do
        if yieldWork then yieldWork() end
        local dk = getDK(sync, n)
        if dk then
            local dkKey = dk:lower()
            local group = groupsByDedup[dkKey]
            if not group then
                group = { canonical = n, aliases = {}, count = 0 }
                groupsByDedup[dkKey] = group
            else
                group.canonical = self:ChooseRicherPlayerName(group.canonical, n)
            end
            if not group.aliases[n] then
                group.aliases[n] = true
                group.count = group.count + 1
            end
        end
    end

    local merged = false
    for _, group in pairs(groupsByDedup) do
        if yieldWork then yieldWork() end
        if group.count > 1 then
            lbCollapseKeysIntoCanonical(self, group.canonical, group.aliases, yieldWork)
            merged = true
        end
    end
    -- Filet perso local : "Tromyr" + "Tromyr-Royaume" si getDK ne les a pas alignes.
    if self:_MergeLocalPlayerLeaderboardAliases(yieldWork) then
        merged = true
    end
    if merged then
        self._dedupMetaIndex = nil
    end
end

--- Regroupe toutes les lignes leaderboard partageant la cle dedup de playerName sous un seul nom canonique.
--- Retourne le nom cle a utiliser pour la suite (ex. AddPlayerCapture).
--- Chemin rapide O(1) via dedupCanonicalIndex ; fallback O(N) si doublons detectes.
function Overlord.Leaderboard:MergeLeaderboardGroupForName(playerName)
    if not playerName or playerName == "" then return playerName, false end
    local sync = Overlord.Sync
    if sync and sync.StripPipeLeakFromContributorName then
        playerName = sync:StripPipeLeakFromContributorName(playerName)
    end
    if not playerName or playerName == "" then return playerName, false end
    local getDK = sync and sync.GetCaptureContributorDedupKey
    if not getDK then return playerName, false end
    local dk0 = getDK(sync, playerName)
    if not dk0 then return playerName, false end

    -- Lecture strictement hot-only. La consolidation lourde est une migration
    -- tranchee ; cette compat API ne doit jamais rescanner quatre SavedVariables.
    local idx = EnsureDedupCanonicalIndex(self)
    if not idx then return playerName, false end
    local dkl = dk0:lower()
    local cached = idx[dkl]
    return cached or playerName, false
end

-- Perso local : fusion uniquement si la cle dedup Sync est identique (pas les alts meme prenom autre royaume).
function Overlord.Leaderboard:_MergeLocalPlayerLeaderboardAliases(yieldWork)
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    if not getDK then return end
    local seed = (sync and sync.GetPlayerFullName) and sync:GetPlayerFullName() or nil
    if not seed or seed == "" then return end
    local dk0 = getDK(sync, seed)
    if not dk0 then return end
    local aliases = {}
    local function mark(n)
        if yieldWork then yieldWork() end
        if not n or n == "" then return end
        local dkn = getDK(sync, n)
        if dkn and dkn:lower() == dk0:lower() then aliases[n] = true end
    end
    for n in pairs(self.captureCount or {}) do mark(n) end
    for n in pairs(self.captures or {}) do mark(n) end
    for n in pairs(self.kills or {}) do mark(n) end
    for n in pairs(self.playerInfo or {}) do mark(n) end
    local nAlias = 0
    for _ in pairs(aliases) do nAlias = nAlias + 1 end
    if nAlias <= 1 then return false end
    local canonical = seed
    for n in pairs(aliases) do
        if yieldWork then yieldWork() end
        canonical = self:ChooseRicherPlayerName(canonical, n)
    end
    lbCollapseKeysIntoCanonical(self, canonical, aliases, yieldWork)
    return true
end

-- Supprime les zoneIds invalides des captures existantes
function Overlord.Leaderboard:CleanCorruptedCaptures(yieldWork)
    local dirty = false
    for name, zones in pairs(self.captures) do
        if yieldWork then yieldWork() end
        if type(zones) == "table" then
            local originalCount = #zones
            local writeIndex = 1
            local seen = {}
            for readIndex = 1, originalCount do
                if yieldWork then yieldWork() end
                local zoneId = zones[readIndex]
                if IsValidLeaderboardZone(zoneId) and not seen[zoneId] then
                    seen[zoneId] = true
                    if writeIndex ~= readIndex then
                        zones[writeIndex] = zoneId
                    end
                    writeIndex = writeIndex + 1
                else
                    dirty = true
                end
            end
            if writeIndex <= originalCount then
                for i = writeIndex, originalCount do zones[i] = nil end
            end
        else
            -- Une ancienne/corrompue SavedVariable peut contenir une valeur
            -- scalaire a la place de la liste. La retirer evite qu'elle soit
            -- rescanee a chaque migration et que les lecteurs tentent de
            -- l'iterer comme une table.
            self.captures[name] = nil
            dirty = true
        end
    end
    if dirty then self:MarkDirty() end
end

function Overlord.Leaderboard:GetSortedKills(maxRows)
    local rows = self:MergeNameCountRowsForDisplay(self.kills, maxRows)
    local sorted = {}
    for _, e in ipairs(rows) do
        sorted[#sorted + 1] = { name = e.name, kills = e.count }
    end
    table.sort(sorted, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        return (a.name or "") < (b.name or "")
    end)
    return sorted
end

-- Faction a AFFICHER pour une guilde : uniquement le vote des membres du registre replique.
-- Une memoire locale de semaines precedentes colorait la meme ligne differemment selon le client.
function Overlord.Leaderboard:GetGuildDisplayFaction(guild, votedFaction)
    if votedFaction == "Alliance" or votedFaction == "Horde" then
        return votedFaction
    end
    return ""
end

-- Classement guildes : somme des tués par guilde (joueurs sans guilde exclus).
function Overlord.Leaderboard:GetSortedGuildKills(sortedKillRows, maxRows)
    local rows = type(sortedKillRows) == "table"
        and sortedKillRows or self:MergeNameCountRowsForDisplay(self.kills)
    local buckets = {}
    local rowCount = math.min(#rows, self.KILL_RANK_LIMIT,
        math.max(0, math.floor(tonumber(maxRows) or #rows)))

    for i = 1, rowCount do
        local e = rows[i]
        local rowKills = math.floor(tonumber(e.count or e.kills) or 0)
        local guild = self:GetExportPlayerGuild(e.name)
        if guild and guild ~= "" and rowKills > 0 then
            local key = guild:lower()
            local b = buckets[key]
            if not b then
                b = { guild = guild, kills = 0, faction = "", _facHorde = 0, _facAlliance = 0 }
                buckets[key] = b
            elseif guild < b.guild then
                -- Meme cle logique, casing legacy different : libelle canonique independant
                -- de l'ordre de pairs() afin de stabiliser aussi les egalites au classement.
                b.guild = guild
            end
            b.kills = b.kills + rowKills
            local _, faction = self:GetExportPlayerMeta(e.name)
            if faction == "Horde" then
                b._facHorde = b._facHorde + rowKills
            elseif faction == "Alliance" then
                b._facAlliance = b._facAlliance + rowKills
            end
        end
    end

    local sorted = {}
    for _, b in pairs(buckets) do
        local voted = ""
        if (b._facHorde or 0) > (b._facAlliance or 0) then
            voted = "Horde"
        elseif (b._facAlliance or 0) > (b._facHorde or 0) then
            voted = "Alliance"
        end
        -- En cas d'egalite, tous les clients affichent la meme faction vide plutot que
        -- de consulter une memoire locale non repliquee.
        b.faction = self:GetGuildDisplayFaction(b.guild, voted)
        b._facHorde = nil
        b._facAlliance = nil
        sorted[#sorted + 1] = b
    end
    table.sort(sorted, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        return (a.guild or "") < (b.guild or "")
    end)
    return sorted
end

-- Retourne les captures triees par faction (Alliance, Horde)
-- Utilise captureCount (total captures) au lieu de #zones (zones uniques)
function Overlord.Leaderboard:GetSortedCapturesByFaction(maxRowsPerFaction)
    local sync = Overlord.Sync
    local function dedupKey(name)
        return (sync and sync.GetCaptureContributorDedupKey) and sync:GetCaptureContributorDedupKey(name) or name
    end
    -- Par faction et cle dedup : une seule ligne par joueur (aligne export Check PvP).
    local buckets = { Alliance = {}, Horde = {} }

    local function absorb(faction, name, count)
        if faction ~= "Horde" and faction ~= "Alliance" then return end
        local dk = dedupKey(name)
        local b = buckets[faction]
        local e = b[dk]
        if not e then
            b[dk] = { name = name, count = count }
        else
            e.count = math.max(e.count, count)
            e.name = self:ChooseRicherPlayerName(e.name, name)
        end
    end

    for name, count in pairs(self.captureCount) do
        if count > 0 then
            local _, faction = self:GetExportPlayerMeta(name)
            if faction ~= "Horde" and faction ~= "Alliance" then
                faction = ""
            end
            absorb(faction, name, count)
        end
    end
    -- Joueurs legacy : dans captures mais pas dans captureCount (migration incomplete)
    for name, zones in pairs(self.captures) do
        if not self.captureCount[name] and type(zones) == "table" and #zones > 0 then
            local _, faction = self:GetExportPlayerMeta(name)
            if faction ~= "Horde" and faction ~= "Alliance" then
                faction = ""
            end
            absorb(faction, name, #zones)
        end
    end

    -- Classe affichee : registre replique uniquement. Un lookup nameplate/groupe local
    -- rendait l'icone differente chez deux receveurs ayant pourtant les memes scores.
    local function classForCaptureUI(eName)
        local cls = select(1, self:GetExportPlayerMeta(eName))
        if type(cls) == "string" and cls ~= "" then
            return cls
        end
        return "UNKNOWN"
    end

    local allianceRows = maxRowsPerFaction
        and selectTopCountRows(buckets.Alliance, maxRowsPerFaction) or buckets.Alliance
    local hordeRows = maxRowsPerFaction
        and selectTopCountRows(buckets.Horde, maxRowsPerFaction) or buckets.Horde
    local alli, horde = {}, {}
    for _, e in pairs(allianceRows) do
        local classRow = classForCaptureUI(e.name)
        table.insert(alli, { name = e.name, count = e.count, class = classRow, faction = "Alliance" })
    end
    for _, e in pairs(hordeRows) do
        local classRow = classForCaptureUI(e.name)
        table.insert(horde, { name = e.name, count = e.count, class = classRow, faction = "Horde" })
    end
    table.sort(alli, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    table.sort(horde, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return (a.name or "") < (b.name or "")
    end)
    return { Alliance = alli, Horde = horde }
end

-- Lignes captures fusionnees pour Sync LC (evite deux messages LC pour "Toto" et "Toto-Royaume").
function Overlord.Leaderboard:BuildMergedCaptureSyncRows()
    local sync = Overlord.Sync
    local function dedupKey(name)
        if not name or name == "" then return nil end
        return (sync and sync.GetCaptureContributorDedupKey) and sync:GetCaptureContributorDedupKey(name) or name
    end
    local buckets = {}

    local function touch(pname)
        local dk = dedupKey(pname)
        if not dk then return nil end
        local b = buckets[dk]
        if not b then
            b = { capCount = 0, name = pname, zonesOrder = {}, zonesSeen = {} }
            buckets[dk] = b
        else
            b.name = self:ChooseRicherPlayerName(b.name, pname)
        end
        return b
    end

    for pname, zones in pairs(self.captures or {}) do
        local b = touch(pname)
        if b and type(zones) == "table" then
            for _, zid in ipairs(zones) do
                if not b.zonesSeen[zid] then
                    b.zonesSeen[zid] = true
                    b.zonesOrder[#b.zonesOrder + 1] = zid
                end
            end
        end
    end

    for pname, count in pairs(self.captureCount or {}) do
        local b = touch(pname)
        if b and count and count > 0 then
            b.capCount = math.max(b.capCount, count)
        end
    end

    local rows = {}
    for _, b in pairs(buckets) do
        table.sort(b.zonesOrder)
        local classMeta, faction = self:GetExportPlayerMeta(b.name)
        do -- score-only autorise : faction vide relayee avec le code LC "U"
            -- Meme regle qu'avant : capCount ou nombre de zones uniques (legacy).
            local cc = b.capCount
            if cc <= 0 then
                cc = #b.zonesOrder
            end
            if cc > 0 then
                -- Ne pas propager UNKNOWN en LC : les receveurs feraient SetPlayerClassFromSync(UNKNOWN).
                local classOut = (classMeta and classMeta ~= "UNKNOWN") and classMeta or ""
                -- Locale : propagee en LC pour que les joueurs sans kills (uniquement captures)
                -- obtiennent aussi le tag (fr/en/...) - sinon locale transmise uniquement via LK.
                local localeOut = self:GetExportPlayerLocale(b.name) or ""
                rows[#rows + 1] = {
                    name = b.name,
                    zones = b.zonesOrder,
                    faction = (faction == "Alliance" or faction == "Horde") and faction or "",
                    capCount = cc,
                    class = classOut,
                    locale = localeOut,
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.capCount ~= b.capCount then return a.capCount > b.capCount end
        return (a.name or "") < (b.name or "")
    end)
    return rows
end
