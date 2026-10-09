-- Leaderboard.lua - Classement des kills et captures par joueur
Overlord = Overlord or {}
Overlord.Leaderboard = {
    KILL_RANK_LIMIT = 5000,
    CAPTURE_RANK_LIMIT = 500,
    -- The v4 catch-up protocol and older clients certify a top 500. Keep its
    -- wire budget independent from local display/storage capacity.
    NETWORK_KILL_RANK_LIMIT = 500,
    kills = {},
    captures = {},
    captureCount = {},
    bountyTimes = {},
    bountyKills = {},
    playerInfo = {},
    leaderboardDirty = false,
    targetRevision = 0,
}


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
-- While RebuildNetworkHotIndexes yields, every incremental kill/capture/name update
-- is also journaled here and replayed into the new indexes before they are published.
-- Before, any kill during the pass aborted it (and the pass restarted every 5 s,
-- forever, in big fights). dedupHardEpoch counts the changes a journal cannot
-- replay (index resets, key merges, score sanitize): those still abort the pass.
local hotRebuildJournals = {}
local dedupHardEpoch = 0

local function InvalidateDedupCanonicalIndex()
    dedupCanonicalValid = false
    dedupCanonicalGeneration = dedupCanonicalGeneration + 1
    dedupHardEpoch = dedupHardEpoch + 1
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

local function UpdateDedupKillMaxIndex(name, count)
    NoteDedupCanonicalName(Overlord.Leaderboard, name)
    local journaling = next(hotRebuildJournals) ~= nil
    if not dedupKillMaxIndex and not journaling then return end
    local dk = GetKillDedupKey(name)
    count = tonumber(count) or 0
    if journaling and dk then
        for journal in pairs(hotRebuildJournals) do
            if count > (journal.kills[dk] or 0) then journal.kills[dk] = count end
        end
    end
    if not dedupKillMaxIndex then return end
    if dk and count > (dedupKillMaxIndex[dk] or 0) then
        dedupKillMaxIndex[dk] = count
    end
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
    local journaling = next(hotRebuildJournals) ~= nil
    if not dedupCaptureMaxIndex and not journaling then return end
    local dk = GetKillDedupKey(name)
    count = tonumber(count) or 0
    if journaling and dk then
        for journal in pairs(hotRebuildJournals) do
            if count > (journal.captures[dk] or 0) then journal.captures[dk] = count end
        end
    end
    if not dedupCaptureMaxIndex then return end
    if dk and count > (dedupCaptureMaxIndex[dk] or 0) then
        dedupCaptureMaxIndex[dk] = count
    end
end

-- Max de kills sur toutes les variantes de nom d'une meme identite (index chaud
-- quand il existe, sinon la ligne brute) : les bornes anti-triche raisonnent par
-- identite, pas par orthographe.
function Overlord.Leaderboard:GetMaxKillsForDedupName(playerName)
    if not playerName or playerName == "" then return 0 end
    local raw = tonumber(self.kills and self.kills[playerName]) or 0
    local dk = GetKillDedupKey(playerName)
    if not dk or not dedupKillMaxIndex then return raw end
    return math.max(raw, tonumber(dedupKillMaxIndex[dk]) or 0)
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

local function normalizeSavedVarsPool(pool)
    if type(pool) ~= "string" or pool == "" then return "" end
    pool = pool:lower()
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    -- 1.4.0: one campaign per Forever ruleset (RealmPools.lua).
    if Overlord.RealmPools and Overlord.RealmPools.RULESET_POOLS
        and Overlord.RealmPools.RULESET_POOLS[pool] then return pool end
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


-- Retire les caracteres qui cassent le protocole LK (|:=,)
-- Drops a UTF-8 character cut in the middle by the byte limit.
local function trimUtf8Tail(name)
    for back = 0, 2 do
        local at = #name - back
        if at < 1 then break end
        local b = string.byte(name, at)
        if b >= 192 then
            local width = b >= 240 and 4 or (b >= 224 and 3 or 2)
            if at + width - 1 > #name then return name:sub(1, at - 1) end
            break
        elseif b < 128 then
            break
        end
    end
    return name
end

local function sanitizeGuildName(name)
    if type(name) ~= "string" or name == "" then return "" end
    name = (name:gsub("[|=:,%c]", ""):match("^%s*(.-)%s*$") or "")
    if name == "" then return "" end
    if #name > MAX_GUILD_NAME_LEN then
        name = trimUtf8Tail(name:sub(1, MAX_GUILD_NAME_LEN))
    end
    return name
end

-- Cache du roster de guilde du joueur local. Source LOCALE et AUTORITAIRE (donnees serveur
-- Blizzard) pour combler la guilde des contributeurs kills qui sont nos propres coequipiers
-- mais qui farment ailleurs (hors groupe / hors de vue) : le best-effort reseau GR/GY ne les
-- couvre pas toujours, donc leurs kills tombaient du total de guilde. On ne touche a aucun
-- format de payload sync ; l'enrichissement se fait uniquement a la lecture (UI / export).
local LOCAL_GUILD_ROSTER_TTL = 15
-- { [cleDedup] = { class, level } } : membres du roster local, indexes par cle dedup
-- (royaume-aware). Classe et niveau viennent du serveur Blizzard : aucun message reseau.
local localGuildRosterKeys = nil
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
    for journal in pairs(hotRebuildJournals) do journal.names[name] = true end
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
            -- 17e valeur : GUID du membre (la race passe par GetPlayerInfoByGUID).
            local ok, rosterName, _, _, rosterLevel, _, _, _, _, _, _, rosterClass,
                _, _, _, _, _, rosterGuid = pcall(GetGuildRosterInfo, state.index)
            state.index = state.index + 1
            processed = processed + 1
            if ok and type(rosterName) == "string" and rosterName ~= "" then
                -- GetGuildRosterInfo renvoie "Nom-Royaume" (royaume connecte inclus). On indexe par
                -- cle dedup (royaume-aware) : un homonyme cross-royaume d'une AUTRE guilde a une cle
                -- differente, donc il ne peut jamais etre confondu avec notre membre.
                local dk = state.getDedupKey
                    and state.getDedupKey(sync, rosterName) or rosterName:lower()
                if dk and dk ~= "" and not state.keys[dk] then
                    rosterLevel = math.floor(tonumber(rosterLevel) or 0)
                    state.keys[dk] = {
                        class = type(rosterClass) == "string" and rosterClass:match("^%u+$") or nil,
                        level = rosterLevel > 0 and rosterLevel <= 90 and rosterLevel or nil,
                        guid = type(rosterGuid) == "string" and rosterGuid:match("^Player%-") and rosterGuid or nil,
                    }
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
local function localGuildRosterEntry(name)
    if not localGuildRosterKeys or not name or name == "" then return nil end
    -- Guilde quittee en instance : le cache n'y est pas vide, il ne doit plus servir.
    if IsInGuild and not IsInGuild() then return nil end
    local sync = Overlord.Sync
    local dk = sync and sync.GetCaptureContributorDedupKey and sync:GetCaptureContributorDedupKey(name)
    if not dk or dk == "" then return nil end
    return localGuildRosterKeys[dk]
end
local function localGuildRosterMatches(name)
    return localGuildRosterEntry(name) ~= nil
end

local function isValidOutpostSite(siteKey)
    return siteKey and siteKey ~= "" and Overlord.OutpostSites and Overlord.OutpostSites[siteKey] ~= nil
end

local function ensureOutpostLeaderboardTables(lb)
    if not OverlordDB then return end
    OverlordDB.outpostTenants = OverlordDB.outpostTenants or {}
    OverlordDB.outpostCaptureCounts = OverlordDB.outpostCaptureCounts or {}
    -- Aucune migration ici (un getter ne doit jamais scanner les SavedVariables) :
    -- la purge unique 1.7.2 et le snapshot LOC sont faits par EnsureOutpostLedgerPrepared
    -- avant l'activation de Sync.
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
    -- 1.7.2: a tenant without the character who took the site is not a tenant.
    local capturer = type(row.capturer) == "string" and (row.capturer:match("^%s*(.-)%s*$") or "") or ""
    if #capturer < 2 or #capturer > 50 or capturer:find("[:|,=%c]") then return nil end
    return {
        siteKey = siteKey,
        guild = guild,
        guildKey = guild:lower(),
        faction = faction,
        claimedAt = claimedAt,
        capturer = capturer,
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

-- Names whose index entry changed while a meta index rebuild is running: the
-- rebuild re-derives them before publishing (an entry it had already passed
-- would otherwise come back stale and cost another full rebuild 90 s later).
-- Weak keys: a pass abandoned mid-way (display build aborted, worker error) drops
-- its journal with its coroutine instead of keeping it registered forever.
local metaRebuildJournals = setmetatable({}, { __mode = "k" })
local copyPublishedMeta -- defined with the other entry helpers below

-- Effets de bord d'une mutation metadata deja appliquee a un index chaud.
-- L'index reste valide, mais toutes ses vues derivees et sa persistance doivent suivre.
-- With a player name, an index entry was re-derived in place: builds that read the
-- index (display, snapshot) keep going, a running rebuild replays that name. Without
-- one, the change cannot be replayed and counts as a structural change (as before).
local function markIndexedMetaMutation(self, playerName)
    self.leaderboardDirty = true
    self._snapshotDirty = true
    self._snapshotRevision = (self._snapshotRevision or 0) + 1
    -- La vue precedente reste affichable jusqu'a la publication atomique de la suivante.
    self._displayMetaCache = nil
    self._displayCacheEpoch = (self._displayCacheEpoch or 0) + 1
    if playerName then
        for journal in pairs(metaRebuildJournals) do journal[playerName] = true end
    else
        self._dedupMetaEpoch = (self._dedupMetaEpoch or 0) + 1
    end
    self.targetRevision = (self.targetRevision or 0) + 1
    self.guildFactionCache = nil
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RequestRefresh then
        Overlord.LeaderboardUI:RequestRefresh()
    end
end

-- Mise a jour legere de l'index dedup quand seule la classe change (nameplate).
-- Evite MarkMetaDirty + RebuildDedupMetaIndex O(N) a chaque joueur visible.
function Overlord.Leaderboard:PatchDedupMetaClassForPlayer(playerName, normClass)
    if not playerName or playerName == "" or not normClass or normClass == "" then return false end
    if self:RefreshIndexedMetaForName(playerName) then return true end
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
    b = copyPublishedMeta(index, dk:lower(), b)
    b.class = normClass
    markIndexedMetaMutation(self, playerName)
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
end

-- One player's row changed: re-derive its index entry from that row instead of
-- dropping the whole index (a rebuild over 10,000 rows left ~25 MB of garbage
-- and ran again after every new name). Same values as a rebuild, see
-- RefreshIndexedMetaForName; otherwise the whole index is rebuilt as before.
function Overlord.Leaderboard:MarkPlayerMetaDirty(playerName)
    if not self:RefreshIndexedMetaForName(playerName) then self:MarkMetaDirty() end
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
    -- "nan" passe tonumber et faisait echouer toute comparaison de date ensuite (une
    -- guilde figee pour la semaine) ; "inf" n'est pas une date non plus.
    if ts ~= ts or ts < 0 or ts == math.huge then return 0 end
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

local function guildRecordWins(newGuild, newAt, newAuth, curGuild, curAt, curAuth,
    newReplica, curReplica)
    local newStrong = newAuth == true or newReplica == true
    local curStrong = curAuth == true or curReplica == true
    if newStrong ~= curStrong then return newStrong end
    -- Un snapshot LK sollicite est une replique admise, pas une preuve directe
    -- d'identite. Entre cette replique et une observation proprietaire, la date
    -- prime pour eviter qu'un ancien heartbeat ressuscite une ancienne guilde.
    if newStrong and curStrong then
        newAt, curAt = normalizeGuildAt(newAt), normalizeGuildAt(curAt)
        if newAt ~= curAt then return newAt > curAt end
    end
    return guildLwwValueWins(newGuild, newAt, curGuild, curAt)
end

-- Les anciennes versions persistaient GetTime() (uptime du client) dans factionAt. Ces petites
-- valeurs ne sont comparables ni entre clients ni apres /reload ; elles valent donc "date inconnue".
local function normalizeMetadataEpoch(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts ~= ts or ts == math.huge or ts == -math.huge then return 0 end
    if ts > 0 and ts < 1000000000 then return 0 end
    return ts
end

-- Meta index entries. A rebuild merges every row of an identity into a work entry
-- (values plus tie-break scratch: factionAt/Key, localeAt/Key, poolAt/Key,
-- guildRank, _guildSeen), then publishes only the values, 14 fields at most
-- (16 hash slots instead of 32: about half the memory of the old entries). src is
-- the identity's only row name, or false when several rows were merged; a single
-- row's entry can then be re-derived from that row alone (RefreshIndexedMetaForName).
local function resetMetaWork(b)
    b.class, b.level = "", 0
    b.faction, b.factionAt, b.factionKey = "", -1, ""
    b.locale, b.localeAt, b.localeKey = "", -1, ""
    b.guild, b.guildRank, b.guildAt = "", 0, 0
    b.guildAuth, b.guildReplica, b._guildSeen = nil, nil, nil
    b.pool, b.poolAt, b.poolKey = "", -1, ""
    b.race, b.raceSex, b.raceAt, b.raceKey = "", 0, -1, ""
    return b
end

local function newPublishedMeta()
    return {
        class = "", level = 0, faction = "", locale = "",
        guild = "", guildAt = 0, guildAuth = nil, guildReplica = nil,
        race = "", raceSex = 0, raceAt = -1, raceKey = "", pool = "", src = false,
    }
end

-- Published entries are never written in place (the ladder snapshot shares them):
-- the few patch paths left for multi-row identities write a copy. Such a patch is
-- reached only when the entry cannot be re-derived from one row, so the copy no
-- longer names a single source row (a later update rebuilds the whole identity).
copyPublishedMeta = function(index, key, b)
    local c = {
        class = b.class, level = b.level, faction = b.faction, locale = b.locale,
        guild = b.guild, guildAt = b.guildAt, guildAuth = b.guildAuth,
        guildReplica = b.guildReplica, race = b.race, raceSex = b.raceSex,
        raceAt = b.raceAt, raceKey = b.raceKey, pool = b.pool, src = false,
    }
    index[key] = c
    return c
end

local function publishMeta(self, w, src)
    local class = w.class
    if class ~= "" and class ~= "UNKNOWN" then
        class = self:NormalizeClassTokenForDisplay(class) or ""
    end
    -- Guild register only (a GI heartbeat of an Overlord user never ranked): 3 to 5
    -- fields instead of 14 (4-8 hash slots, about 500 B less per such player). Every
    -- reader takes a missing field as its empty value; guild stays even when "".
    if class == "" and w.level == 0 and w.faction == "" and w.locale == ""
        and w.race == "" and w.pool == "" then
        local entry = { guild = w.guild, guildAt = w.guildAt, src = src }
        if w.guildAuth then entry.guildAuth = true end
        if w.guildReplica then entry.guildReplica = true end
        return entry
    end
    return {
        class = class, level = w.level, faction = w.faction, locale = w.locale,
        guild = w.guild, guildAt = w.guildAt, guildAuth = w.guildAuth,
        guildReplica = w.guildReplica, race = w.race, raceSex = w.raceSex,
        raceAt = w.raceAt, raceKey = w.raceKey, pool = w.pool, src = src,
    }
end

-- One row into a work entry: the deterministic joins of every identity field
-- (order of the rows does not matter, every client gets the same entry).
local function mergeMetaRow(self, b, n, inf)
    -- Une declaration directe prime sur un ancien hint relaye.
    local g = sanitizeGuildName(inf.guild or "")
    local ts = normalizeGuildAt(inf.guildAt)
    if g ~= "" or ts > 0 then
        local r = guildAliasRank(n, self)
        local candidateAuth = inf.guildAuth == true
        local candidateReplica = inf.guildReplica == true
        local previousGuild = sanitizeGuildName(b.guild or "")
        local previousAt = normalizeGuildAt(b.guildAt)
        local sameValue = previousGuild:lower() == g:lower()
        local accept = not b._guildSeen
            or guildRecordWins(g, ts, candidateAuth,
                previousGuild, previousAt, b.guildAuth,
                candidateReplica, b.guildReplica)
        if accept then
            b.guild = g
            b.guildRank = r
            b.guildAt = ts
            b.guildAuth = candidateAuth or nil
            b.guildReplica = candidateReplica or nil
            b._guildSeen = true
        elseif sameValue and ts == previousAt then
            b.guildAuth = (b.guildAuth == true or candidateAuth) or nil
            b.guildReplica = (b.guildReplica == true or candidateReplica) or nil
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
        local raceTs = normalizeMetadataEpoch(inf.raceAt)
        local sk = tostring(n)
        local candidateSex = math.floor(tonumber(inf.raceSex) or 0)
        local currentSex = math.floor(tonumber(b.raceSex) or 0)
        if candidateSex ~= 2 and candidateSex ~= 3 then candidateSex = 0 end
        if currentSex ~= 2 and currentSex ~= 3 then currentSex = 0 end
        if b.race == "" or b.race == nil or raceTs > (b.raceAt or -1)
            or (raceTs == (b.raceAt or -1)
                and (inf.race < b.race or (inf.race == b.race
                    and (candidateSex > 0 and currentSex == 0
                        or (candidateSex == currentSex and sk < b.raceKey)
                        or (candidateSex > 0 and currentSex > 0
                            and candidateSex < currentSex))))) then
            b.race = inf.race
            b.raceSex = candidateSex
            b.raceAt = raceTs
            b.raceKey = sk
        end
    end
    if inf.faction and inf.faction ~= "" then
        local factionTs = normalizeMetadataEpoch(inf.factionAt)
        local sk = tostring(n)
        if b.faction == "" or inf.faction < b.faction then
            b.factionAt = factionTs
            b.factionKey = sk
            b.faction = inf.faction
        elseif inf.faction == b.faction then
            if factionTs > b.factionAt or (factionTs == b.factionAt and sk > b.factionKey) then
                b.factionAt = factionTs
                b.factionKey = sk
            end
        end
    end
    if inf.locale and inf.locale ~= "" then
        local loc = sanitizeLocaleTag(inf.locale)
        if loc ~= "" then
            local localeTs = normalizeMetadataEpoch(inf.factionAt)
            local sk = tostring(n)
            if b.locale == "" or loc < b.locale then
                b.localeAt = localeTs
                b.localeKey = sk
                b.locale = loc
            elseif loc == b.locale then
                if localeTs > b.localeAt or (localeTs == b.localeAt and sk > b.localeKey) then
                    b.localeAt = localeTs
                    b.localeKey = sk
                end
            end
        end
    end
    -- Pool SavedVariables : meme choix deterministe que l'ancien scan par lecture,
    -- mais calcule une seule fois pendant la construction de l'index. Les lignes
    -- sans pool explicite peuvent toujours etre classees par leur locale sync hors US.
    local pool = normalizeSavedVarsPool(inf.pool)
    if pool ~= "" then
        local poolTs = tonumber(inf.factionAt) or 0
        local sk = tostring(n)
        if poolTs > (b.poolAt or -1) or (poolTs == (b.poolAt or -1) and sk > (b.poolKey or "")) then
            b.pool = pool
            b.poolAt = poolTs
            b.poolKey = sk
        end
    end
end

local metaRefreshWork = resetMetaWork({})

-- Re-derive one identity's entry from its row, when that row is the identity's
-- only one (src): exactly what a rebuild would publish for it. Returns false when
-- the index is cold, the row is gone, or the identity merges several rows (the
-- caller then drops the whole index, as before). While a rebuild runs, the name
-- is journaled and re-derived on the new index before it is published.
function Overlord.Leaderboard:RefreshIndexedMetaForName(playerName)
    if type(playerName) ~= "string" or playerName == "" then return false end
    local index = self._dedupMetaIndex
    if type(index) ~= "table" then
        if next(metaRebuildJournals) == nil then return false end
        markIndexedMetaMutation(self, playerName)
        return true
    end
    local inf = self.playerInfo and self.playerInfo[playerName]
    if type(inf) ~= "table" then return false end
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = (getDK and getDK(sync, playerName)) or playerName
    if not dk or dk == "" then return false end
    local key = dk:lower()
    local current = index[key]
    if current and current.src ~= playerName then return false end
    mergeMetaRow(self, resetMetaWork(metaRefreshWork), playerName, inf)
    index[key] = publishMeta(self, metaRefreshWork, playerName)
    if not current then NoteDedupCanonicalName(self, playerName) end
    markIndexedMetaMutation(self, playerName)
    return true
end

-- Mise a jour legere de l'index dedup guilde (evite MarkMetaDirty O(N) sur chaque K/GY).
function Overlord.Leaderboard:PatchDedupMetaGuildForPlayer(playerName, guild, force, preferSync, guildAtOpt)
    if self:RefreshIndexedMetaForName(playerName) then return true end
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
        b = newPublishedMeta()
        self._dedupMetaIndex[key] = b
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
    b = copyPublishedMeta(self._dedupMetaIndex, key, b)
    b.guild = guild
    b.guildAuth = (sameValue and b.guildAuth == true) or force == true or nil
    b.guildReplica = force ~= true and self.playerInfo and self.playerInfo[playerName]
        and self.playerInfo[playerName].guildReplica == true or nil
    b.guildAt = guildAt
    markIndexedMetaMutation(self, playerName)
    return true
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

-- Un relais peut renseigner ou mettre a jour une guilde de seconde main (la date la
-- plus recente gagne, comme sur Retail), jamais ecraser une guilde confirmee par le
-- personnage (GI/K) ou par une page de rattrapage sollicitee, ni propager un depart.
function Overlord.Leaderboard:ShouldAcceptSyncedGuild(playerName, incomingGuild, incomingGuildAt)
    incomingGuild = sanitizeGuildName(incomingGuild)
    if incomingGuild == "" then return false end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return false end
    local existing, existingAt, authoritative = self:GetHotPlayerGuildState(playerName)
    if authoritative then return false end
    local direct = self.playerInfo and self.playerInfo[playerName]
    if direct and direct.guildReplica == true then return false end
    if existing == "" then return true end
    return guildLwwValueWins(incomingGuild, normalizeGuildAt(incomingGuildAt), existing, existingAt)
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

-- Index O(n) sur playerInfo : evite de rescanner toutes les cles a chaque GetExportPlayerMeta.
function Overlord.Leaderboard:RebuildDedupMetaIndex(yieldWork, onName)
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local playerInfo = self.playerInfo or {}
    local index = {}
    -- Work entries only for identities with several rows (rare on Forever).
    local work = {}
    local scratch = resetMetaWork({})
    local journal = {}
    metaRebuildJournals[journal] = true

    -- A sliced pass walks a frozen key list (taken without yielding): resuming
    -- pairs() after an insertion is undefined in Lua 5.1 (rows skipped or seen
    -- twice once the table grows). Rows added meanwhile are in the journal.
    local names
    if yieldWork then
        names = {}
        for n in pairs(playerInfo) do names[#names + 1] = n end
    end
    local cursor, n, inf = 0, nil, nil
    while true do
        if names then
            cursor = cursor + 1
            n = names[cursor]
            inf = n ~= nil and playerInfo[n] or nil
        else
            n, inf = next(playerInfo, n)
        end
        if n == nil then break end
        if yieldWork then yieldWork() end
        if onName and inf then onName(n) end
        if inf then
            local dk = (getDK and getDK(sync, n)) or n
            if dk and dk ~= "" then
                local k = dk:lower()
                local w = work[k]
                if w then
                    mergeMetaRow(self, w, n, inf)
                else
                    local published = index[k]
                    if not published then
                        mergeMetaRow(self, resetMetaWork(scratch), n, inf)
                        index[k] = publishMeta(self, scratch, n)
                    else
                        -- Second row of this identity: replay the first one into a
                        -- full work entry, its tie-break scratch is needed from now on.
                        w = resetMetaWork({})
                        local first = published.src and playerInfo[published.src]
                        if type(first) == "table" then mergeMetaRow(self, w, published.src, first) end
                        mergeMetaRow(self, w, n, inf)
                        work[k] = w
                    end
                end
            end
        end
    end
    names = nil

    for k, w in pairs(work) do
        if yieldWork then yieldWork() end
        index[k] = publishMeta(self, w, false)
    end

    -- Rows re-derived while this pass yielded: the pass may already have read
    -- their old values. Single-row identities are re-derived here; a changed
    -- identity with several rows cannot be, it counts as a structural change.
    -- The replay is sliced too: names changed during it go to a fresh journal,
    -- replayed in turn, until none is left.
    while next(journal) ~= nil do
        local batch = journal
        journal = {}
        metaRebuildJournals[batch] = nil
        metaRebuildJournals[journal] = true
        for name in pairs(batch) do
            if yieldWork then yieldWork() end
            local row = playerInfo[name]
            local dk = (getDK and getDK(sync, name)) or name
            local k = dk and dk ~= "" and dk:lower()
            local current = k and index[k]
            if type(row) == "table" and k and (not current or current.src == name) then
                mergeMetaRow(self, resetMetaWork(scratch), name, row)
                index[k] = publishMeta(self, scratch, name)
            elseif k then
                self._dedupMetaEpoch = (self._dedupMetaEpoch or 0) + 1
            end
        end
    end
    metaRebuildJournals[journal] = nil

    self._dedupMetaIndex = index
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
-- /ov network: how often index rebuilds finish versus restart (and why), to tell
-- in game whether new player rows still keep them from finishing.
local function noteHotIndexOutcome(self, outcome)
    local stats = self._hotIndexStats
    if not stats then
        stats = { completed = 0, metaOnly = 0, abortedMeta = 0, abortedOther = 0 }
        self._hotIndexStats = stats
    end
    stats[outcome] = (stats[outcome] or 0) + 1
end

function Overlord.Leaderboard:GetHotIndexStats()
    return self._hotIndexStats or { completed = 0, metaOnly = 0, abortedMeta = 0, abortedOther = 0 }
end

-- A change during a pass that the pass cannot replay (since 1.7.8 only an identity
-- with several rows, or a dropped index; single rows are re-derived from the
-- journal): the index built from the other rows is still valid, so publish it and
-- refresh once, 90 s later (never in combat or a large event), instead of
-- restarting the whole pass. Under a stream of new names (launch day) the rebuild
-- used to never finish: every pass was aborted and the hot index stayed cold.
local META_REFRESH_DELAY = 90
local function scheduleMetaRefresh(self)
    if self._metaRefreshScheduled then return end
    self._metaRefreshScheduled = true
    C_Timer.After(META_REFRESH_DELAY, function()
        local lb = Overlord.Leaderboard
        if lb ~= self then return end
        self._metaRefreshScheduled = nil
        -- A crowd keeps naming new players: each refresh is ~80 sliced frames.
        -- Never start one in combat or a large event; try again later.
        local sync = Overlord.Sync
        if (UnitAffectingCombat and UnitAffectingCombat("player"))
            or (sync and sync.IsLargeEvent and sync:IsLargeEvent()) then
            scheduleMetaRefresh(self)
            return
        end
        -- The current index stays readable while the fresh one is built.
        self._dedupMetaStale = true
        self:EnsureNetworkHotIndexesPrepared()
    end)
end

function Overlord.Leaderboard:RebuildNetworkHotIndexes(yieldWork, owner)
    local killsSource = self.kills or {}
    local captureSource = self.captureCount or {}
    local capturesSource = self.captures or {}
    local playerInfoSource = self.playerInfo or {}
    local metaEpoch = self._dedupMetaEpoch or 0
    local hardEpoch = dedupHardEpoch
    local function sourcesChanged()
        return self.kills ~= killsSource or self.captureCount ~= captureSource
            or self.captures ~= capturesSource or self.playerInfo ~= playerInfoSource
            or (self._dedupMetaEpoch or 0) ~= metaEpoch
            or dedupHardEpoch ~= hardEpoch
    end

    -- Scores and canonical names are maintained incrementally once built: when
    -- only the meta index went cold (new player rows, guild/faction changes),
    -- rebuild just that, a quarter of the work.
    if dedupKillMaxIndex and dedupCaptureMaxIndex and dedupCanonicalValid
        and self._networkHotKillsSource == killsSource
        and self._networkHotCaptureSource == captureSource
        and self._networkHotCapturesSource == capturesSource then
        self:RebuildDedupMetaIndex(yieldWork, function(name) NoteDedupCanonicalName(self, name) end)
        local metaDrift = (self._dedupMetaEpoch or 0) ~= metaEpoch
        if sourcesChanged() and not (metaDrift and self.kills == killsSource
            and self.captureCount == captureSource and self.captures == capturesSource
            and self.playerInfo == playerInfoSource and dedupHardEpoch == hardEpoch) then
            noteHotIndexOutcome(self, "abortedOther")
            self._dedupMetaIndex = nil
            return false
        end
        self._networkHotPlayerInfoSource = playerInfoSource
        self._dedupMetaStale = nil
        if metaDrift then
            noteHotIndexOutcome(self, "metaDrift")
            scheduleMetaRefresh(self)
        end
        noteHotIndexOutcome(self, "metaOnly")
        return true
    end

    local killIndex, captureIndex, canonicalIndex = {}, {}, {}
    local function RegisterCanonical(name)
        if not name or name == "" then return end
        local dk = GetKillDedupKey(name)
        if not dk then return end
        local previous = canonicalIndex[dk]
        canonicalIndex[dk] = previous
            and self:ChooseRicherPlayerName(previous, name) or name
    end
    -- One journal per running pass (the login repair and the network worker can
    -- overlap). Every slice marks progress; a pass that stopped progressing for
    -- 5 minutes (failed or abandoned coroutine) is dropped by the next pass, and
    -- a pass whose journal was dropped never publishes (see below).
    local now = GetTime and GetTime() or 0
    for stale in pairs(hotRebuildJournals) do
        if now - stale.progressAt > 300 then hotRebuildJournals[stale] = nil end
    end
    local journal = { kills = {}, captures = {}, names = {}, progressAt = now }
    hotRebuildJournals[journal] = true
    if owner then owner.journal = journal end
    local function step()
        if GetTime then journal.progressAt = GetTime() end
        if yieldWork then yieldWork() end
    end
    -- Frozen key lists, each taken right before its loop (no yield while
    -- copying): kills keep arriving while this rebuild yields, and resuming
    -- pairs() after an insertion is undefined in Lua (existing rows may be
    -- skipped). Keys added after a copy are covered by the journal.
    local function keysOf(source)
        local list = {}
        for name in pairs(source) do list[#list + 1] = name end
        return list
    end
    local killNames = keysOf(killsSource)
    for i = 1, #killNames do
        step()
        local name = killNames[i]
        local count = killsSource[name]
        if count ~= nil then
            RegisterCanonical(name)
            local dk = GetKillDedupKey(name)
            count = tonumber(count) or 0
            if dk and count > (killIndex[dk] or 0) then killIndex[dk] = count end
        end
    end
    local captureNames = keysOf(captureSource)
    for i = 1, #captureNames do
        step()
        local name = captureNames[i]
        local count = captureSource[name]
        if count ~= nil then
            RegisterCanonical(name)
            local dk = GetKillDedupKey(name)
            count = tonumber(count) or 0
            if dk and count > (captureIndex[dk] or 0) then captureIndex[dk] = count end
        end
    end
    local captureListNames = keysOf(capturesSource)
    for i = 1, #captureListNames do
        step()
        if capturesSource[captureListNames[i]] ~= nil then RegisterCanonical(captureListNames[i]) end
    end
    self:RebuildDedupMetaIndex(step, RegisterCanonical)
    local journalKept = hotRebuildJournals[journal] == true
    hotRebuildJournals[journal] = nil
    if owner then owner.journal = nil end
    local metaDrift = (self._dedupMetaEpoch or 0) ~= metaEpoch
    local onlyMetaDrift = journalKept and metaDrift and self.kills == killsSource
        and self.captureCount == captureSource and self.captures == capturesSource
        and self.playerInfo == playerInfoSource and dedupHardEpoch == hardEpoch
    if not journalKept or (sourcesChanged() and not onlyMetaDrift) then
        noteHotIndexOutcome(self, "abortedOther")
        self._dedupMetaIndex = nil
        return false
    end
    if onlyMetaDrift then
        noteHotIndexOutcome(self, "metaDrift")
        scheduleMetaRefresh(self)
    end
    -- Replay what arrived during the pass (max semantics, like the live updaters).
    for dk, count in pairs(journal.kills) do
        if count > (killIndex[dk] or 0) then killIndex[dk] = count end
    end
    for dk, count in pairs(journal.captures) do
        if count > (captureIndex[dk] or 0) then captureIndex[dk] = count end
    end
    for name in pairs(journal.names) do RegisterCanonical(name) end
    dedupKillMaxIndex = killIndex
    dedupCaptureMaxIndex = captureIndex
    dedupCanonicalIndex = canonicalIndex
    dedupCanonicalValid = true
    self._networkHotKillsSource = killsSource
    self._networkHotCaptureSource = captureSource
    self._networkHotCapturesSource = capturesSource
    self._networkHotPlayerInfoSource = playerInfoSource
    self._networkHotCanonicalGeneration = dedupCanonicalGeneration
    self._dedupMetaStale = nil
    noteHotIndexOutcome(self, "completed")
    return true
end

-- An abandoned or failed pass must not leave its journal registered.
function Overlord.Leaderboard:_DropHotRebuildJournal(owner)
    if owner and owner.journal then
        hotRebuildJournals[owner.journal] = nil
        owner.journal = nil
    end
end

-- Barriere login : aucune initialisation Sync avant que les lectures LK/LC/CR/GR
-- aient leurs index complets. Le travail est borne a 64 lignes ou 1,25 ms/frame.
function Overlord.Leaderboard:EnsureNetworkHotIndexesPrepared()
    if dedupKillMaxIndex and dedupCaptureMaxIndex and dedupCanonicalValid
        and self._dedupMetaIndex and not self._dedupMetaStale
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
    local owner = {}
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
            if not self:RebuildNetworkHotIndexes(YieldWork, owner) then
                error("leaderboard bucket changed while preparing network indexes")
            end
        end)
        C_Timer.After(0, ResumeWorker)
    end
    ResumeWorker = function()
        if not self._networkHotIndexPrepPending
            or self._networkHotIndexPrepGeneration ~= generation then
            self:_DropHotRebuildJournal(owner)
            return
        end
        local ok, err = coroutine.resume(worker)
        if not ok then
            self:_DropHotRebuildJournal(owner)
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
end

local DISPLAY_KILL_RANK_LIMIT = Overlord.Leaderboard.KILL_RANK_LIMIT
local DISPLAY_PREVIEW_ROW_LIMIT = 500
function Overlord.Leaderboard:SortNetworkRows(rows, less, yieldWork)
    return sortRowsWithYield(rows, less, yieldWork)
end
local DISPLAY_CAPTURE_RANK_LIMIT = Overlord.Leaderboard.CAPTURE_RANK_LIMIT
local DISPLAY_CAPTURE_PREVIEW_LIMIT = 25
-- Au-dela de ce nombre de couples (creneau, fortin), la reparation des victoires de
-- fortin est decoupee sur plusieurs images au lieu d'un seul bloc.
Overlord.Leaderboard.GK_AWARD_REPAIR_SYNC_MAX = 16
-- Fortins = priorite la plus basse (sieges toutes les 6 h, peu de joueurs) : une
-- operation au plus toutes les 0,1 s, rien en combat ni en gros event, et les
-- preuves recues sont regroupees 10 s avant reconciliation. Resultats identiques.
Overlord.Leaderboard.GK_WORK_STEP_INTERVAL = 0.1
Overlord.Leaderboard.GK_WORK_POSTPONE_RETRY = 2
Overlord.Leaderboard.GK_RECONCILE_DEBOUNCE_SEC = 10
-- Champ (pas de local) : ecart minimal entre deux builds quand une vue est affichee.
-- 1.7.8: 10 s (was 3). With live kills the view is stale almost all the time, so an
-- open panel rebuilt every 3 s plus the build time (~6 MB of garbage per build at
-- 10,000 players); the ranking now refreshes within ~15 s instead of ~10 s.
Overlord.Leaderboard.DISPLAY_CACHE_MIN_REBUILD_SEC = 10
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
    -- An incoming LK can invalidate metadata before a sliced build finishes.
    -- Pace attempts as well as completed builds while an older view is usable;
    -- otherwise each UI refresh can restart the full scan after an abort.
    local cache = self._displayCache
    if displayCacheSourcesMatch(cache, self) and cache.ready then
        local last = math.max(tonumber(self._displayCacheLastBuildAt) or -math.huge,
            tonumber(self._displayCacheLastAttemptAt) or -math.huge)
        local gap = (self.DISPLAY_CACHE_MIN_REBUILD_SEC or 10) - (GetTime() - last)
        if gap > 0 then
            if not self._displayCacheDeferredBuild then
                self._displayCacheDeferredBuild = true
                C_Timer.After(gap, function()
                    self._displayCacheDeferredBuild = nil
                    local current = self._displayCache
                    if not displayCacheSourcesMatch(current, self)
                        or current.epoch ~= (self._displayCacheEpoch or 0) then
                        self:StartDisplayCacheBuild()
                    end
                end)
            end
            return false
        end
    end
    self._displayCacheLastAttemptAt = GetTime()

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
                state.aborted = true
                return
            end
        end
        state.metaIndex = self._dedupMetaIndex

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
            sortRowsWithYield(rows, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return (a.name or "") < (b.name or "")
            end, yieldWork)
            return rows
        end
        local byFaction = {
            Alliance = captureRows(state.allianceTop, "Alliance"),
            Horde = captureRows(state.hordeTop, "Horde"),
        }

        -- Count every known member once, including players outside the visible
        -- top. A rival entering the ranking must never subtract a guild's HKs.
        local guildBuckets = {}
        -- 1.4.0 guild tooltip: ranked members and their top 10, gathered in this
        -- same sliced pass (no extra scan, no table per player). Kept in memory
        -- only: SaveDisplayCache never writes it to SavedVariables.
        local guildMembers = {}
        local alliKills, hordeKills = 0, 0
        if not forEach(dedupKillMaxIndex, function(key, count)
            local name = state.canonicalIndex[key] or key
            local _, faction, guild = indexedMeta(name)
            if faction == "Alliance" then alliKills = alliKills + count
            elseif faction == "Horde" then hordeKills = hordeKills + count end
            if guild and guild ~= "" then
                local key = guild:lower()
                local bucket = guildBuckets[key]
                if not bucket then
                    -- _fac: Horde kills minus Alliance kills (4 fields, 4 hash slots).
                    bucket = { guild = guild, kills = 0, faction = "", _fac = 0 }
                    guildBuckets[key] = bucket
                elseif guild < bucket.guild then
                    bucket.guild = guild
                end
                bucket.kills = bucket.kills + count
                if faction == "Horde" then bucket._fac = bucket._fac + count
                elseif faction == "Alliance" then bucket._fac = bucket._fac - count end
                if count > 0 then
                    local m = guildMembers[key]
                    if not m then
                        m = { count = 0, names = {}, kills = {} }
                        guildMembers[key] = m
                    end
                    m.count = m.count + 1
                    local names, kills = m.names, m.kills
                    local n = #kills
                    if n < 10 or count > kills[n] then
                        local pos = (n < 10) and (n + 1) or n
                        while pos > 1 and kills[pos - 1] < count do
                            kills[pos], names[pos] = kills[pos - 1], names[pos - 1]
                            pos = pos - 1
                        end
                        kills[pos], names[pos] = count, name
                    end
                end
            end
        end) then return end
        local sortedGuilds = {}
        for _, bucket in pairs(guildBuckets) do
            local voted = ""
            if bucket._fac > 0 then voted = "Horde"
            elseif bucket._fac < 0 then voted = "Alliance" end
            bucket.faction = self:GetGuildDisplayFaction(bucket.guild, voted)
            bucket._fac = nil
            sortedGuilds[#sortedGuilds + 1] = bucket
            yieldWork()
        end
        sortRowsWithYield(sortedGuilds, function(a, b)
            if a.kills ~= b.kills then return a.kills > b.kills end
            return (a.guild or "") < (b.guild or "")
        end, yieldWork)
        for i = #sortedGuilds, DISPLAY_KILL_RANK_LIMIT + 1, -1 do
            sortedGuilds[i] = nil
            yieldWork()
        end

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
            meta[name] = { class, faction, race, raceSex }
            localeTag = sanitizeLocaleTag(localeTag)
            if localeTag ~= "" then
                pool = normalizeSavedVarsPool(pool)
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
            guildMembers = guildMembers,
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
    -- StartDisplayCacheBuild owns the single cooldown timer, including when a
    -- previous attempt was aborted by metadata arriving during its scan.
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
-- It contains at most 5000 kills/guilds and 25 captures per faction, without
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

-- Ranked members of a guild for the leaderboard tooltip: { count, names, kills }
-- (top 10, highest first), from the last display build. Nil until one finished.
function Overlord.Leaderboard:GetGuildMembersSummary(guild)
    local cache = self._displayCache
    local members = cache and cache.guildMembers
    if type(members) ~= "table" or type(guild) ~= "string" or guild == "" then return nil end
    return members[guild:lower()]
end

function Overlord.Leaderboard:SaveDisplayCache(cache)
    if self._storageBound ~= true or not cache.ready or cache.fromSavedCache
        or not self:IsDisplayCacheScopeCurrent(cache) then return false end
    -- RestoreDisplayCache ne lit que l'apercu de login (500 lignes kills/guildes,
    -- 25 capteurs par faction) : persister les 5000 lignes et toutes les
    -- metadonnees ajoutait ~20 000 lignes de fichier pour rien.
    local function head(rows, limit)
        local out = {}
        for i = 1, math.min(#rows, limit) do out[i] = rows[i] end
        return out
    end
    local sortedKills = head(cache.sortedKills, DISPLAY_PREVIEW_ROW_LIMIT)
    local byFaction = {}
    for faction, rows in pairs(cache.byFaction) do
        byFaction[faction] = head(rows, DISPLAY_CAPTURE_PREVIEW_LIMIT)
    end
    local meta, locale = {}, {}
    local function keep(name)
        if name ~= nil and cache.meta[name] ~= nil then
            meta[name] = cache.meta[name]
            locale[name] = cache.locale[name]
        end
    end
    for _, row in ipairs(sortedKills) do keep(row.name) end
    for _, rows in pairs(byFaction) do
        for _, row in ipairs(rows) do keep(row.name) end
    end
    OverlordDB.leaderboardDisplayCache = {
        version = 2, killLimit = self.KILL_RANK_LIMIT,
        campaignStart = cache.campaignStart, scoreBucketEpoch = cache.scoreBucketEpoch,
        pool = cache.pool, at = (GetServerTime and GetServerTime()) or time(),
        sortedKills = sortedKills, sortedGuilds = head(cache.sortedGuilds, DISPLAY_PREVIEW_ROW_LIMIT),
        byFaction = byFaction, meta = meta, locale = locale,
        alliKills = cache.alliKills, hordeKills = cache.hordeKills,
    }
    return true
end

function Overlord.Leaderboard:RestoreDisplayCache()
    local saved = OverlordDB and OverlordDB.leaderboardDisplayCache
    if type(saved) ~= "table" or saved.version ~= 2
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
    -- Paint a bounded preview at login. The sliced builder fills the full 5000
    -- rows once storage is bound, without copying 5000 metadata rows in one frame.
    for i = 1, math.min(#saved.sortedKills, DISPLAY_PREVIEW_ROW_LIMIT) do
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
        -- Keep login work at the old 25-row preview; the sliced builder fills 500.
        for i = 1, math.min(#rows, DISPLAY_CAPTURE_PREVIEW_LIMIT) do
            local row = rows[i]
            if type(row) ~= "table" or not count(row.count) or row.faction ~= faction
                or not text(row.class, 32) or not copyMeta(row.name) then return nil end
            cache.byFaction[faction][i] = {
                name = row.name, count = row.count, class = row.class, faction = faction,
            }
        end
    end
    for i = 1, math.min(#saved.sortedGuilds, DISPLAY_PREVIEW_ROW_LIMIT) do
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

-- Fortress captures share the outpost campaign and event ledger.
function Overlord.Leaderboard:ResetStrategicSiteCampaignData()
    if not OverlordDB then return end
    OverlordDB.dominationBoostEvents = nil
    if Overlord.Outpost then Overlord.Outpost:ResetOutpostsForCampaign() end
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
    if not hasScores then return false end
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
    if not bucket then return false end
    local campaignStart = self:GetCurrentCampaignStart()
    if campaignStart <= 0 then return false end
    -- Jamais de re-etiquetage d'une AUTRE semaine : seul le reset (archive + bucket vide)
    -- peut faire passer ces scores a la campagne suivante. Les migrations legitimes
    -- (mid-week, ancien decalage US) restent sous 6 jours d'ecart.
    local bucketStart = math.floor(tonumber(bucket.campaignStart) or 0)
    if bucketStart > 0 and math.abs(bucketStart - campaignStart) >= (604800 - 86400)
        and LeaderboardBucketHasScores(bucket) then
        return false
    end
    bucket.campaignStart = campaignStart
    if Overlord.TimestampToCampaignId then
        bucket.campaignId = Overlord:TimestampToCampaignId(campaignStart)
    end
    MarkLeaderboardResetEpochSynced()
    return true
end

local function ScheduleLocalGuildRosterEnrich(delaySec)
    local lb = Overlord.Leaderboard
    if not lb then return end
    local delay = math.max(0, tonumber(delaySec) or 0)
    -- Un rappel plus proche (join/kick apres une rafale de GUILD_ROSTER_UPDATE
    -- differee de 10 s) remplace le rappel en attente au lieu d'attendre derriere.
    local due = GetTime() + delay
    if lb._guildRosterEnrichPending and (lb._guildRosterEnrichDue or 0) <= due then return end
    local token = (lb._guildRosterEnrichToken or 0) + 1
    lb._guildRosterEnrichToken, lb._guildRosterEnrichDue = token, due
    lb._guildRosterEnrichPending = true
    C_Timer.After(delay, function()
        local current = Overlord.Leaderboard
        if not current or current._guildRosterEnrichToken ~= token then return end
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

-- v9 (1.7.4) : repasse une fois pour purger une ligne refusee sur toutes les campagnes.
-- v10 (1.7.5) : graphies non canoniques et sosies, lignes sans classe ou au-dela du
-- niveau 60, et fiches playerInfo des noms refuses (guilde fantome).
local LEGACY_SCORE_SANITIZE_VERSION = 10

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
        if processed >= 256 or elapsed >= 1.25 then
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
            local sync = Overlord.Sync
            SanitizeMap(bucket.kills, function(name)
                if sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name) then
                    return true
                end
                -- v10: the same content rules as the network (no class, level above 60).
                -- Never one of this account's own characters (credited here this week),
                -- even before the local name resolves at login.
                if not sync or not sync.IsLadderRowClass or IsLocalName(name) then return false end
                local localKeys = OverlordDB.leaderboardLocalKillKeys
                if type(localKeys) == "table" then
                    local dk = sync.GetCaptureContributorDedupKey and sync:GetCaptureContributorDedupKey(name)
                    if localKeys[name] or (dk and localKeys["#dk:" .. dk]) then return false end
                end
                local info = type(bucket.playerInfo) == "table" and bucket.playerInfo[name] or nil
                if type(info) ~= "table" then return false end
                -- An old save may hold "Warrior" or " MAGE": the login repair fixes the
                -- token later, so judge the normalized one (an honest row stays).
                local class = Overlord.Leaderboard:NormalizeClassTokenForDisplay(info.class)
                return not sync:IsLadderRowClass(class)
                    or (tonumber(info.level) or 0) > (sync.MAX_LADDER_LEVEL or 60)
            end, bucket.bountyKills)
            SanitizeMap(bucket.playerInfo, function(name)
                return sync and sync.IsDeniedKillContributor
                    and sync:IsDeniedKillContributor(name) or false
            end)
            SanitizeMap(bucket.captureCount, function(name, count)
                -- v8: names no character can have (and removed rows) leave the
                -- capture column too, not only the kill column.
                if Overlord.Sync and Overlord.Sync.IsDeniedKillContributor
                    and Overlord.Sync:IsDeniedKillContributor(name) then return true end
                return captureCeiling
                    and (tonumber(count) or 0) >= captureCeiling
                    and not IsLocalName(name)
            end, bucket.captures)
            SanitizeMap(bucket.kills, function(name, count)
                if not killCeiling or IsLocalName(name) then return false end
                if (tonumber(count) or 0) > killCeiling then return true end
                -- Above the level ceiling: clamp like the network does, never delete.
                local info = type(bucket.playerInfo) == "table" and bucket.playerInfo[name] or nil
                local level = info and tonumber(info.level) or 0
                if level > 0 and Overlord.Sync and Overlord.Sync.MaxPlausibleKillsForLevel then
                    local ceiling = Overlord.Sync:MaxPlausibleKillsForLevel(level)
                    if (tonumber(count) or 0) > ceiling then
                        bucket.kills[name] = ceiling
                        changed = true
                    end
                end
                return false
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
            dedupHardEpoch = dedupHardEpoch + 1
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
    -- 1.7.8: the copy of the previous week (no reader) leaves old saves.
    if OverlordDB then OverlordDB.leaderboardPreviousCampaigns = nil end
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
            -- Une grande guilde emet GUILD_ROSTER_UPDATE a chaque connexion : avec un
            -- roster deja complet (toujours lisible), une reconstruction toutes les 10 s suffit.
            ScheduleLocalGuildRosterEnrich((event == "GUILD_ROSTER_UPDATE" and hadCompleteRoster) and 10 or 1)
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
    local guildAt = identity == nil and normalizeGuildAt(prev and prev.guildAt) or leaderboardServerNow()
    local keepReplica = prev and prev.guildReplica == true
        and guildAt < normalizeGuildAt(prev.guildAt)
    if keepReplica then
        guildTag = sanitizeGuildName(prev.guild)
        guildAt = normalizeGuildAt(prev.guildAt)
    end
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
        guildAuth = not keepReplica
            and (identity ~= nil or (prev and prev.guildAuth == true)) or nil,
        guildReplica = keepReplica or (identity == nil and prev
            and prev.guildReplica == true) or nil,
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
    self:MarkPlayerMetaDirty(playerName)
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
    -- StampCurrentCampaignBucket refuse de re-etiqueter les scores d'une autre semaine.
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
    local mergedGuildReplica
    if guildRecordWins(gO, gAtO, iO.guildAuth, gT, gAtT, iT.guildAuth,
        iO.guildReplica, iT.guildReplica) then
        mergedGuild = gO
        mergedGuildAt = gAtO
        mergedGuildAuth = iO.guildAuth == true or nil
        mergedGuildReplica = iO.guildReplica == true or nil
    else
        mergedGuild = gT
        mergedGuildAt = gAtT
        mergedGuildAuth = iT.guildAuth == true or nil
        mergedGuildReplica = iT.guildReplica == true or nil
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
    self.playerInfo[bestKey] = {
        class = mergedClass,
        level = mergedLevel,
        faction = mergedFaction,
        factionAt = mergedFactionAt,
        locale = mergedLocale or "",
        guild = mergedGuild,
        guildAuth = mergedGuildAuth or nil,
        guildReplica = mergedGuildReplica or nil,
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
        if prev.locale == tag then return end
        -- Deux affirmations contradictoires valides doivent produire le meme resultat
        -- quel que soit leur ordre d'arrivee.
        if prev.locale and prev.locale ~= "" and prev.locale ~= tag and tag >= prev.locale then return end
        prev.locale = tag
    end
    self:MarkPlayerMetaDirty(playerName)
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
        incAt = leaderboardServerNow()
    end
    -- Bootstrap local : perso uniquement (les tiers passent par K/GY/GI reseau).
    if not fromSync and not authoritative then
        if not self:IsLocalPlayerGuildTarget(playerName) then return end
    end
    if fromSync and not authoritative and self.ShouldAcceptSyncedGuild then
        if not self:ShouldAcceptSyncedGuild(playerName, guild, incAt) then return end
    end
    local prev = self.playerInfo[playerName]
    -- A second-hand guild hint only completes a player already in the ladder; it
    -- never creates one (a forged hint made any name "known", 2026-10-06).
    if fromSync and not authoritative and not prev then return end
    local prevGuild = sanitizeGuildName((prev and prev.guild) or "")
    local prevAt = normalizeGuildAt(prev and prev.guildAt)
    if prev and prev.guildReplica == true then
        if fromSync and not authoritative then return end
        if authoritative and incAt < prevAt then return end
    end
    if fromSync and authoritative and prev and prevGuild == "" and prevAt > 0
        and incAt > 0 and incAt <= prevAt then
        return
    end
    if prevGuild == guild then
        -- A groupmate's every PvP kill re-confirms the same guild: refreshing its
        -- date each time invalidated the dedup meta index and kept the network
        -- index rebuild from ever finishing in raids. Once a minute is enough to
        -- keep first-hand observations ahead of older relayed claims.
        if authoritative and not fromSync and prev and prev.guildAuth and not prev.guildReplica
            and incAt >= prevAt and incAt - prevAt < 60 then
            return
        end
        if authoritative then
            if not prev then
                -- A guild register only (other fields come with a score).
                self.playerInfo[playerName] = { guild = guild, guildAuth = true, guildAt = incAt }
                NoteDedupCanonicalName(self, playerName)
            else
                if not prev.guildAuth or incAt >= prevAt then prev.guildAt = incAt end
                prev.guildAuth = true
                prev.guildReplica = nil
            end
            if self:PatchDedupMetaGuildForPlayer(playerName, guild, true, false, incAt) then
                return
            end
            self:MarkPlayerMetaDirty(playerName)
            return
        end
        if incAt <= prevAt then return end
    end
    if prev and prevGuild ~= guild
        and not ((authoritative or prevGuild == "") and not prev.guildAuth
            and not prev.guildReplica)
        and not guildLwwValueWins(guild, incAt, prevGuild, prevAt) then
        return
    end
    if not prev then
        self.playerInfo[playerName] = {
            guild = guild, guildAuth = authoritative == true or nil, guildAt = incAt,
        }
        NoteDedupCanonicalName(self, playerName)
    else
        prev.guild = guild
        prev.guildAuth = authoritative == true or nil
        prev.guildReplica = nil
        prev.guildAt = incAt
    end
    local force = authoritative == true
    local preferSync = fromSync and not force
    if self:PatchDedupMetaGuildForPlayer(playerName, guild, force, preferSync, incAt) then
        return
    end
    self:MarkPlayerMetaDirty(playerName)
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
    if clearedAt <= 0 then clearedAt = leaderboardServerNow() end
    local targetKey = sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(playerName)
    local row = self.playerInfo and self.playerInfo[playerName]
    local previousAt = normalizeGuildAt(type(row) == "table" and row.guildAt)
    local changed = type(row) ~= "table"
        or (row.guild or "") ~= "" or row.guildAuth or clearedAt ~= previousAt
    if type(row) ~= "table" then
        self.playerInfo[playerName] = { guild = "", guildAt = clearedAt, guildAuth = true }
        NoteDedupCanonicalName(self, playerName)
    elseif (row.guildAuth == true or row.guildReplica == true)
        and clearedAt < previousAt then
        return false
    else
        if (row.guild or "") == "" and row.guildAuth == true and clearedAt == previousAt then
            return false
        end
        row.guild = ""
        row.guildAuth = true
        row.guildReplica = nil
        row.guildAt = clearedAt
    end

    local hotIndex = self._dedupMetaIndex
    if self:RefreshIndexedMetaForName(playerName) then
        return changed
    elseif type(hotIndex) == "table" and targetKey and targetKey ~= "" then
        local bucketKey = targetKey:lower()
        local bucket = hotIndex[bucketKey]
        if not bucket then
            bucket = newPublishedMeta()
            hotIndex[bucketKey] = bucket
        end
        local bucketGuild = sanitizeGuildName(bucket.guild or "")
        local bucketAt = normalizeGuildAt(bucket.guildAt)
        if bucket.guildAuth ~= true or (bucketGuild == "" and clearedAt >= bucketAt)
            or guildLwwValueWins("", clearedAt, bucketGuild, bucketAt) then
            bucket = copyPublishedMeta(hotIndex, bucketKey, bucket)
            bucket.guild = ""
            bucket.guildAuth = true
            bucket.guildReplica = nil
            bucket.guildAt = clearedAt
        end
        markIndexedMetaMutation(self, playerName)
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
            self:ClearPlayerGuild(fullName, false, true, leaderboardServerNow())
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
    self:SetPlayerGuild(fullName, guild, false, true, leaderboardServerNow())
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
    local prevReplica = prev and prev.guildReplica == true
    local poolKeep = normalizeSavedVarsPool((prev and prev.pool) or "")
    self.playerInfo[playerName] = {
        class = class,
        level = (prev and math.floor(tonumber(prev.level) or 0)) or 0,
        faction = newFaction,
        factionAt = factionAt,
        locale = locKeep,
        guild = guildKeep,
        guildAuth = prevAuth or nil,
        guildReplica = prevReplica or nil,
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
    if not prev or (prev.class or "") ~= class or (prev.faction or "") ~= newFaction
        or (prev.locale or "") ~= locKeep or (prev.guild or "") ~= guildKeep
        or (prev.guildAuth == true) ~= prevAuth then
        self:MarkPlayerMetaDirty(playerName)
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
        self:MarkPlayerMetaDirty(playerName)
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
        self:MarkPlayerMetaDirty(playerName)
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
        self:MarkPlayerMetaDirty(playerName)
    else
        local changed = (prev.class ~= norm)
        prev.class = norm
        if prev.locale == nil then prev.locale = "" end
        if prev.guild == nil then prev.guild = "" end
        if prev.pool == nil then prev.pool = "" end
        if changed then
            if not self:PatchDedupMetaClassForPlayer(playerName, norm) then
                self:MarkPlayerMetaDirty(playerName)
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
        self:MarkPlayerMetaDirty(playerName)
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
        -- Monotone dans une campagne : un niveau ne baisse pas en une semaine, et
        -- une ligne tierce perimee (ou forgee) ne doit pas abaisser le plafond.
        if level <= math.floor(tonumber(prev.level) or 0) then return true end
        prev.level = level
    end
    self:MarkPlayerMetaDirty(playerName)
    return true
end

-- Fusion atomique des metadonnees portees par une ligne LK. Les anciens setters
-- invalidaient puis reconstruisaient l'index dedup plusieurs fois par paquet
-- (niveau -> classe -> guilde), soit O(lignes * playerInfo) pendant une rafale.
-- Cette voie n'effectue aucun scan global et n'invalide qu'une fois.
function Overlord.Leaderboard:MergeLeaderboardKillMetadata(
    playerName, level, classToken, faction, localeTag, guild, guildAt, hasGuildRegister,
    raceFile, raceSexOpt, raceAtOpt, guildAuthoritative, guildSnapshot)
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

    if level > math.floor(tonumber(row.level) or 0) then
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

    -- Registres forts : confirmation du personnage (guildAuth) ou page LK sollicitee
    -- (guildReplica). Un LK tiers spontane ne peut jamais ecraser un registre fort ni
    -- propager un depart ; entre deux informations de seconde main, la date la plus
    -- recente gagne (regle Retail). Sinon la premiere guilde recue restait figee chez
    -- l'autre faction, qui ne voit jamais le K direct du joueur (ecart EMPIRE).
    -- guildSnapshot doit provenir du gate HR/pagination attendu, jamais d'un bit du paquet.
    local guildFactionCompatible = faction ~= "Alliance" and faction ~= "Horde"
        or (row.faction or "") == "" or row.faction == faction
    local snapshot = guildSnapshot == true and guildAuthoritative ~= true
    if hasGuildRegister and (guildAuthoritative == true
        or (snapshot and guildFactionCompatible)
        or (row.guildAuth ~= true and row.guildReplica ~= true
            and sanitizeGuildName(guild or "") ~= "" and guildFactionCompatible)) then
        local incomingGuild = sanitizeGuildName(guild or "")
        local incomingAt = normalizeGuildAt(guildAt)
        if incomingAt <= leaderboardServerNow() + 300 then
            local currentGuild = sanitizeGuildName(row.guild or "")
            local currentAt = normalizeGuildAt(row.guildAt)
            local wins = false
            if guildAuthoritative ~= true and not snapshot and incomingGuild == "" then
                wins = false
            elseif guildAuthoritative == true and row.guildAuth ~= true
                and row.guildReplica ~= true then
                wins = true
            elseif not snapshot and guildAuthoritative ~= true then
                -- Seconde main contre seconde main (le filtre ci-dessus exclut un
                -- registre fort) : une guilde vide (inconnue ou ancien faux depart
                -- relaye) se remplit toujours ; entre deux guildes, la date la plus
                -- recente gagne.
                wins = incomingGuild ~= "" and (currentGuild == ""
                    or guildLwwValueWins(incomingGuild, incomingAt, currentGuild, currentAt))
            elseif row.guildAuth == true or row.guildReplica == true or snapshot then
                wins = guildRecordWins(incomingGuild, incomingAt,
                    guildAuthoritative == true, currentGuild, currentAt,
                    row.guildAuth == true, snapshot, row.guildReplica == true)
            elseif incomingGuild:lower() == currentGuild:lower() then
                wins = incomingAt > currentAt
                    or (incomingAt == currentAt and incomingGuild < currentGuild)
            else
                wins = guildLwwValueWins(incomingGuild, incomingAt, currentGuild, currentAt)
            end
            -- An owner's K re-dates its unchanged guild on every broadcast: applying
            -- each one bumped the meta epoch and kept the meta index rebuild from
            -- finishing (Sonnet audit 1.3.5). Same strong guild within a minute: no-op,
            -- like SetPlayerGuild's re-confirmation rule.
            if wins and guildAuthoritative == true and not snapshot and row.guildAuth == true
                and row.guildReplica ~= true and incomingGuild:lower() == currentGuild:lower()
                and incomingAt >= currentAt and incomingAt - currentAt < 60 then
                wins = false
            end
            if wins then
                row.guild = incomingGuild
                row.guildAt = incomingAt
                row.guildAuth = guildAuthoritative == true or nil
                row.guildReplica = snapshot or nil
                changed = true
            elseif incomingGuild:lower() == currentGuild:lower()
                and guildAuthoritative == true and row.guildAuth ~= true
                and (row.guildReplica ~= true or incomingAt >= currentAt) then
                row.guildAuth = true
                row.guildReplica = nil
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
        if not (observedAt >= 0 and observedAt <= now + 300) then observedAt = 0 end
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
    if changed then self:MarkPlayerMetaDirty(playerName) end
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
        -- Filled below with the guild register only (3 fields, 4 hash slots instead
        -- of 16): most such rows belong to Overlord users who never score.
        row = {}
        self.playerInfo[playerName] = row
        NoteDedupCanonicalName(self, playerName)
    end
    local currentGuild = sanitizeGuildName(row.guild or "")
    local currentAt = normalizeGuildAt(row.guildAt)
    local sameGuild = incomingGuild:lower() == currentGuild:lower()
    local valueWins
    if row.guildAuth ~= true and row.guildReplica ~= true then
        valueWins = true
    elseif row.guildReplica == true then
        valueWins = guildRecordWins(incomingGuild, incomingAt, true,
            currentGuild, currentAt, row.guildAuth, false, true)
    elseif sameGuild then
        valueWins = incomingAt > currentAt
            or (incomingAt == currentAt and incomingGuild < currentGuild)
    else
        valueWins = guildLwwValueWins(incomingGuild, incomingAt, currentGuild, currentAt)
    end
    local authorityOnly = sameGuild and row.guildAuth ~= true
        and (row.guildReplica ~= true or incomingAt >= currentAt)
    if not valueWins and not authorityOnly then return false end
    if valueWins then
        row.guild = incomingGuild
        row.guildAt = incomingAt
    end
    row.guildAuth = true
    row.guildReplica = nil
    self:MarkPlayerMetaDirty(playerName)
    return true
end

-- Race connue pour export UI / SR : Communaute en priorite, LR/K legacy en fallback.
function Overlord.Leaderboard:GetExportPlayerRace(playerName)
    if not playerName or playerName == "" then return "", 0 end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        playerName = sync:NormalizeContributorFullName(playerName)
    end
    if not playerName or playerName == "" then return "", 0 end
    -- La race vient des K/LR repliques et des unites observees (index chaud, puis
    -- la ligne playerInfo).
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
    return fallbackRace, fallbackSex
end

-- Communaute/LR (et K legacy) : n'ecrase pas une race connue par un champ vide.
-- Meme race simplement re-datee (flux LR apres la ligne LK v7) : si cette identite porte
-- deja la race de son entree d'index, seule la date avance. Patcher l'entree evite de jeter
-- l'index et de le reconstruire en entier (O(N), ~16 Mo de dechets pour 10 000 lignes).
local function PatchIndexedRaceDate(self, playerName, race, observedAt)
    if self:RefreshIndexedMetaForName(playerName) then return true end
    local index = self._dedupMetaIndex
    if type(index) ~= "table" then return false end
    local sync = Overlord.Sync
    local getDK = sync and sync.GetCaptureContributorDedupKey
    local dk = (getDK and getDK(sync, playerName)) or playerName
    local b = dk and dk ~= "" and index[dk:lower()]
    if not b or b.race ~= race or b.raceKey ~= tostring(playerName) then return false end
    local ts = normalizeMetadataEpoch(observedAt)
    if ts > (b.raceAt or -1) then
        b = copyPublishedMeta(index, dk:lower(), b)
        b.raceAt = ts
    end
    markIndexedMetaMutation(self, playerName)
    return true
end

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
        if not (observedAt >= 0 and observedAt <= now + 300) then observedAt = 0 end
    end
    local prev = self.playerInfo[playerName]
    local previousAt = prev and math.floor(tonumber(prev.raceAt) or 0) or 0
    if prev and prev.race and prev.race ~= "" and prev.race == normRace then
        if sex == 0 or (tonumber(prev.raceSex) or 0) == sex then
            -- Our own unchanged race is re-observed at every kill broadcast: re-date
            -- it at most hourly, each re-date bumped the meta epoch (audit 1.3.5).
            if observedAt > previousAt and (fromSync or observedAt - previousAt >= 3600) then
                prev.raceAt = observedAt
                -- raceAt participe au tie-break de l'index et doit etre persiste.
                if not PatchIndexedRaceDate(self, playerName, normRace, observedAt) then
                    self:MarkPlayerMetaDirty(playerName)
                end
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
    self:MarkPlayerMetaDirty(playerName)
    if not fromSync and sync and sync.MaybeBroadcastObservedLeaderboardRace then
        sync:MaybeBroadcastObservedLeaderboardRace(playerName, normRace, sex, observedAt)
    end
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
        local r = select(1, self:GetExportPlayerRace(pname))
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

    -- SetPlayerRace re-derives each changed index entry itself.
    for pname, k in pairs(self.kills or {}) do
        if (k or 0) > 0 then tryEnrich(pname) end
    end
    for pname in pairs(self.playerInfo or {}) do
        tryEnrich(pname)
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
                        guildReplica = inf.guildReplica == true,
                        rank = guildAliasRank(k, self),
                    }
                    local previous = bestByDk[dkKey]
                    local sameValue = previous
                        and previous.guild:lower() == candidate.guild:lower()
                        and previous.guildAt == candidate.guildAt
                    if not previous or guildRecordWins(
                        candidate.guild, candidate.guildAt, candidate.guildAuth,
                        previous.guild, previous.guildAt, previous.guildAuth,
                        candidate.guildReplica, previous.guildReplica) then
                        bestByDk[dkKey] = candidate
                    elseif sameValue then
                        previous.guildAuth = previous.guildAuth or candidate.guildAuth
                        previous.guildReplica = previous.guildReplica or candidate.guildReplica
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
                    local curReplica = inf.guildReplica == true
                    if cur:lower() ~= best.guild:lower()
                        or curAt ~= best.guildAt or curAuth ~= best.guildAuth
                        or curReplica ~= best.guildReplica then
                        inf.guild = best.guild
                        inf.guildAt = best.guildAt
                        inf.guildAuth = best.guildAuth or nil
                        inf.guildReplica = best.guildReplica or nil
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

-- Rafraichit la guilde du perso local avant agregation (pas d'inference tierce depuis le groupe).
function Overlord.Leaderboard:EnrichGuildForKillRows()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    self:UpdateLocalPlayerGuild()
    self:EnrichGuildFromLocalRoster()
end

-- Chemin incremental pour les nouveaux scores apres chargement du roster. O(1) par joueur :
-- il remplace le scan complet qui etait auparavant declenche par chaque lecture du panneau.
-- Le roster local donne aussi la classe et le niveau des membres : de simples
-- indices qui ne remplissent qu'une valeur absente, jamais un fait deja connu.
-- deferDirty: the sliced roster scan marks metadata dirty once at its end
-- (one invalidation per row relaunched the dedup rebuild ~500 times).
function Overlord.Leaderboard:MaybeEnrichGuildForKillRow(playerName, deferDirty)
    local entry = localGuildRosterGuild ~= "" and localGuildRosterEntry(playerName) or nil
    if not entry then return false end
    local row = self.playerInfo[playerName]
    local changed = false
    if type(row) ~= "table" then
        row = {
            class = "", level = 0, faction = "", factionAt = 0,
            locale = "", guild = "", guildAt = 0, pool = "",
            race = "", raceSex = 0, raceAt = 0,
        }
        self.playerInfo[playerName] = row
        NoteDedupCanonicalName(self, playerName)
        changed = true
    end
    -- Le roster local n'est qu'un hint a timestamp nul : ne jamais ecraser
    -- un fait proprietaire GI/K plus recent.
    if sanitizeGuildName(row.guild or "") == "" and normalizeGuildAt(row.guildAt) <= 0 then
        row.guild = localGuildRosterGuild
        row.guildAt = 0
        row.guildAuth = nil
        changed = true
    end
    if entry.class and (row.class == nil or row.class == "" or row.class == "UNKNOWN") then
        row.class = entry.class
        changed = true
    end
    if entry.level and (tonumber(row.level) or 0) <= 0 then
        row.level = entry.level
        changed = true
    end
    -- Race : le roster ne la donne pas, mais le GUID du membre oui. Date nulle :
    -- toute race reellement observee (kill, GUID, communaute) l'emporte ensuite.
    if (row.race == nil or row.race == "") and entry.guid and GetPlayerInfoByGUID then
        local ok, _, _, _, raceFile, raceSex = pcall(GetPlayerInfoByGUID, entry.guid)
        local sync = Overlord.Sync
        local race = ok and sync and sync.NormalizeRaceFileToken
            and sync:NormalizeRaceFileToken(raceFile) or nil
        if race and race ~= "" then
            raceSex = math.floor(tonumber(raceSex) or 0)
            row.race = race
            row.raceSex = (raceSex == 2 or raceSex == 3) and raceSex or 0
            row.raceAt = 0
            changed = true
        end
    end
    if changed and not deferDirty then self:MarkPlayerMetaDirty(playerName) end
    return changed
end

-- Membre de notre propre guilde (roster Blizzard) : sa guilde et sa classe sont
-- connues localement, inutile de les demander au reseau.
function Overlord.Leaderboard:IsLocalGuildRosterMember(playerName)
    return localGuildRosterGuild ~= "" and localGuildRosterMatches(playerName)
end

function Overlord.Leaderboard:GetLocalGuildRosterClass(playerName)
    local entry = localGuildRosterEntry(playerName)
    return entry and entry.class or nil
end

-- Complete la guilde, la classe et le niveau des contributeurs presents dans le roster de
-- guilde local, seulement quand ils manquent. Simple indice local (guildAt = 0, pas
-- d'autorite) : rien n'est envoye au reseau et aucun fait connu n'est ecrase.
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
                -- Each completed row re-derives its own index entry, inside this
                -- budgeted slice (a guild of a few hundred members no longer drops
                -- and rebuilds the whole index).
                if self:MaybeEnrichGuildForKillRow(name, true) then
                    self:MarkPlayerMetaDirty(name)
                end
            end
            processed = processed + 1
            if debugprofilestop and (debugprofilestop() - startedAt) >= 1.25 then break end
        end
        C_Timer.After(0, RunSlice)
    end
    RunSlice()
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
                    -- SetPlayerInfo re-derives the index entry when a value changed.
                    self:SetPlayerInfo(fullName, className, faction)
                end
                end
            end
        end
    end
    self:UpdateLocalPlayerGuild()
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

    -- SetPlayerClassFromSync re-derives each changed index entry itself.
    for pname, k in pairs(self.kills or {}) do
        if (k or 0) > 0 then tryEnrichPlayerName(pname) end
    end
    for pname, c in pairs(self.captureCount or {}) do
        if (c or 0) > 0 then tryEnrichPlayerName(pname) end
    end
    for pname, zones in pairs(self.captures or {}) do
        if type(zones) == "table" and #zones > 0 then tryEnrichPlayerName(pname) end
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
            self:ResetStrategicSiteCampaignData()
            self:Save()
            OverlordDB.lastLeaderboardResetAt = (GetServerTime and GetServerTime()) or time()
            marker.leaderboardSideEffectsApplied = true
        end
        self:ResumePendingWeeklyArchive()
        return false
    end

    -- Donnees campagne fixes/petites : elles basculent dans la meme frame logique
    -- que le bucket afin qu'une capture post-frontiere ne puisse jamais etre effacee.
    self:ResetStrategicSiteCampaignData()
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

-- ===== Keep and outpost ledger (1.7.2) =====
-- A capture is one event (site, guild, faction, timestamp) that names the character
-- who made it. A row (site, guild, pool) is the set of its events and its count is
-- the size of that set: sets merge by union, so two clients that accept the same
-- events end with the same count whatever the order of arrival. The tenant of a
-- site is its newest accepted event. Which events a client accepts is decided by
-- SyncOutpost.lua (the capturer speaks for himself, catch-up by content).
local OUTPOST_CAPTURER_LEDGER_VERSION = 1
-- Growth bounds of the ledger (a week of real play stays far below): rows are
-- (site, guild) pairs, events are captures. Beyond them a claim is refused, which
-- every client decides alike. A rebuild of the SR snapshot waits a few seconds so
-- a catch-up reply (hundreds of events) triggers a handful of rebuilds, not one per event.
local OUTPOST_LEDGER_ROWS_MAX = 512
local OUTPOST_LEDGER_EVENTS_MAX = 20000
local OUTPOST_LEDGER_REBUILD_DEBOUNCE = 3
-- Rows and site states of the release week (the 7 days up to this time) carry no
-- capturer: they are dropped once at login and refused on the wire, on every client
-- alike (2026-10-08 14:39 UTC, the 1.7.2 release).
local OUTPOST_LEDGER_PURGE_TS = 1791470340
Overlord.Leaderboard.OUTPOST_CLAIM_MIN_TS = OUTPOST_LEDGER_PURGE_TS

local function normalizeOutpostCapturer(name)
    if type(name) ~= "string" then return nil end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t < 2 or #t > 50 or t:find("[:|,=%c]") then return nil end
    return t
end

local function outpostCapturerKey(name)
    local sync = Overlord.Sync
    local key = sync and sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(name) or nil
    if key and key ~= "" then return key end
    return tostring(name or ""):lower()
end

local function mergeOutpostRowFaction(row, faction)
    if not row or (faction ~= "Alliance" and faction ~= "Horde") then return false end
    local current = row.faction or ""
    -- Une guilde WoW peut etre cross-faction. Le compteur est volontairement indexe par
    -- guilde (pas par faction) : la faction de transport doit donc etre un join commutatif.
    -- Le minimum lexical est stable quel que soit l'ordre A/H ; le tenant courant, lui,
    -- conserve sa faction horodatee dans outpostTenants.
    if current ~= "Alliance" and current ~= "Horde"
        or faction < current then
        row.faction = faction
        return true
    end
    return false
end

local function outpostSyncStableKey(row)
    return table.concat({ tostring(row.siteKey or ""),
        tostring(row.guild or ""):lower(),
        resolveOutpostLbPoolTag(row.pool) }, ":")
end


-- One-shot migration to the signed ledger (judged by content, so a row written by
-- this version is never touched): tenants and events that name no capturer are
-- dropped in every world, and the site states of the release week restart neutral.
-- Tables keep their identity so caches keyed on them stay valid.
function Overlord.Leaderboard:EnsureOutpostCapturerLedger()
    if not OverlordDB then return false end
    if (tonumber(OverlordDB.outpostCapturerLedgerVersion) or 0)
        >= OUTPOST_CAPTURER_LEDGER_VERSION then
        return false
    end
    local function purgeWorld(world)
        if type(world) ~= "table" then return end
        if type(world.outpostTenants) ~= "table" then world.outpostTenants = {} end
        for siteKey, row in pairs(world.outpostTenants) do
            if type(row) ~= "table" or not normalizeOutpostCapturer(row.capturer) then
                world.outpostTenants[siteKey] = nil
            end
        end
        if type(world.outpostCaptureCounts) ~= "table" then world.outpostCaptureCounts = {} end
        for rowKey, row in pairs(world.outpostCaptureCounts) do
            local signed = type(row) == "table" and type(row.events) == "table"
            if signed then
                for _, capturer in pairs(row.events) do
                    if not normalizeOutpostCapturer(capturer) then signed = false; break end
                end
            end
            if not signed then world.outpostCaptureCounts[rowKey] = nil end
        end
        if Overlord.Outpost and Overlord.Outpost.PurgeStatesForCapturerLedger then
            Overlord.Outpost:PurgeStatesForCapturerLedger(world.outposts, OUTPOST_LEDGER_PURGE_TS)
        end
    end
    purgeWorld(OverlordDB)
    for _, world in pairs(type(OverlordDB.worldsByPool) == "table" and OverlordDB.worldsByPool or {}) do
        purgeWorld(world)
    end
    OverlordDB.outpostCapturerLedgerVersion = OUTPOST_CAPTURER_LEDGER_VERSION
    self:ResetOutpostLedgerCounters()
    self:MarkDirty()
    if Overlord.Outpost and Overlord.Outpost.RefreshOutpostPresentation then
        pcall(Overlord.Outpost.RefreshOutpostPresentation, Overlord.Outpost, nil, true)
    end
    return true
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


-- True when this exact event (same second, same capturer) is already in the ledger:
-- a repeat of it needs no authority (routine state, SR replay).
function Overlord.Leaderboard:IsOutpostClaimAccepted(siteKey, guild, faction, captureTs, capturer, poolTag)
    captureTs = math.floor(tonumber(captureTs) or 0)
    capturer = normalizeOutpostCapturer(capturer)
    if captureTs <= 0 or not capturer then return false end
    local row = self:GetOutpostCaptureCountRow(siteKey, guild, poolTag)
    local stored = type(row) == "table" and type(row.events) == "table"
        and row.events[tostring(captureTs)] or nil
    -- The faction belongs to the event too: a copy with the other code is not it.
    return type(stored) == "string" and row.faction == faction
        and outpostCapturerKey(stored) == outpostCapturerKey(capturer)
end

local function applyOutpostTenant(lb, siteKey, guild, faction, claimedAt, poolTag, capturer)
    local tenants = lb:GetOutpostTenantsTable()
    local prev = tenants[siteKey]
    local prevTs = prev and math.floor(tonumber(prev.claimedAt) or 0) or 0
    local guildKey = guild:lower()
    local prevGuildKey = prev and (prev.guildKey or "") or ""
    local prevPool = prev and resolveOutpostLbPoolTag(prev.pool) or ""
    local tieKey = guildKey .. ":" .. poolTag .. ":" .. faction
    local prevTieKey = prev and (prevGuildKey .. ":" .. prevPool .. ":" .. (prev.faction or "")) or ""
    if prev and prevTs > claimedAt then return false end
    if prev and prevTs == claimedAt then
        if prevTieKey == tieKey then
            -- Same event: the tenant keeps the capturer it was first accepted with.
            if normalizeOutpostCapturer(prev.capturer) then return false end
            prev.capturer = capturer
            return true
        end
        if tieKey >= prevTieKey then return false end
    end
    tenants[siteKey] = {
        guild = guild,
        guildKey = guildKey,
        faction = faction,
        claimedAt = claimedAt,
        pool = poolTag,
        capturer = capturer,
    }
    return true
end

-- Shortest time a character needs before completing a capture of this site (the
-- gold-reduced contract minus a little clock skew), the same on every client.
local function outpostSiteGap(siteKey)
    local OP = Overlord.Outpost
    local site = OP and OP.GetSite and OP:GetSite(siteKey) or nil
    local minimum = OP and OP.GetMinimumHoldTimeRequired and OP:GetMinimumHoldTimeRequired(site) or 240
    return math.max(1, math.floor(tonumber(minimum) or 240) - 5)
end
Overlord.Leaderboard.GetOutpostSiteGap = function(_, siteKey) return outpostSiteGap(siteKey) end

local function outpostIndexInsert(list, ts, gap)
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if list[mid].ts < ts then lo = mid + 1 else hi = mid - 1 end
    end
    table.insert(list, lo, { ts = ts, gap = gap })
end

-- Rows and events held, counted once per table (O(rows + events)) then kept
-- incrementally, with the sorted capture times of every capturer (the pace by
-- content: a character captures at most once per contract, on every path).
local function ensureOutpostLedgerCounters(lb, counts)
    if lb._outpostLedgerCountersSource == counts and lb._outpostLedgerRows then return end
    local rows, events, index = 0, 0, {}
    for _, row in pairs(counts) do
        if type(row) == "table" then
            rows = rows + 1
            events = events + math.max(0, math.floor(tonumber(row.count) or 0))
            if type(row.events) == "table" then
                local gap = outpostSiteGap(row.siteKey)
                for eventKey, capturer in pairs(row.events) do
                    local ts = math.floor(tonumber(eventKey) or 0)
                    if ts > 0 and type(capturer) == "string" then
                        local key = outpostCapturerKey(capturer)
                        local list = index[key]
                        if not list then list = {}; index[key] = list end
                        list[#list + 1] = { ts = ts, gap = gap }
                    end
                end
            end
        end
    end
    for _, list in pairs(index) do table.sort(list, function(a, b) return a.ts < b.ts end) end
    lb._outpostLedgerCountersSource = counts
    lb._outpostLedgerRows, lb._outpostLedgerEvents = rows, events
    lb._outpostCapturerIndex = index
end

-- After a wipe in place (weekly reset, purge) the counters are recounted lazily.
function Overlord.Leaderboard:ResetOutpostLedgerCounters()
    self._outpostLedgerCountersSource = nil
    self._outpostLedgerRows, self._outpostLedgerEvents = nil, nil
    self._outpostCapturerIndex = nil
end

-- True when this character could have made a capture at claimTs on a site whose
-- contract is claimGap, given his other captures in the ledger: between two
-- captures he had to hold the LATER site for its contract, so a pair is checked
-- with the gap of its later event, whatever the order of arrival (the ledger
-- decides, so every client that holds the same events decides alike).
function Overlord.Leaderboard:IsOutpostCapturerPaced(capturer, claimTs, claimGap)
    claimTs = math.floor(tonumber(claimTs) or 0)
    claimGap = math.floor(tonumber(claimGap) or 0)
    if claimTs <= 0 or claimGap <= 0 then return true end
    capturer = normalizeOutpostCapturer(capturer)
    if not capturer then return false end
    ensureOutpostLedgerCounters(self, self:GetOutpostCaptureCountsTable())
    local list = self._outpostCapturerIndex and self._outpostCapturerIndex[outpostCapturerKey(capturer)]
    if not list or #list == 0 then return true end
    local lo, hi = 1, #list
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if list[mid].ts < claimTs then lo = mid + 1 else hi = mid - 1 end
    end
    -- list[hi] is the newest earlier capture, list[lo] the oldest later one.
    local earlier, later = list[hi], list[lo]
    if earlier and claimTs - earlier.ts < claimGap then return false end
    if later and later.ts - claimTs < later.gap then return false end
    return true
end

-- The event (site, guild, faction, second) is in the ledger, whoever made it.
function Overlord.Leaderboard:HasOutpostEvent(siteKey, guild, faction, captureTs, poolTag)
    captureTs = math.floor(tonumber(captureTs) or 0)
    if captureTs <= 0 then return false end
    local row = self:GetOutpostCaptureCountRow(siteKey, guild, poolTag)
    return type(row) == "table" and row.faction == faction and type(row.events) == "table"
        and type(row.events[tostring(captureTs)]) == "string"
end

-- The character the ledger credited with this event (the first one accepted).
function Overlord.Leaderboard:GetOutpostEventCapturer(siteKey, guild, faction, captureTs, poolTag)
    captureTs = math.floor(tonumber(captureTs) or 0)
    if captureTs <= 0 then return nil end
    local row = self:GetOutpostCaptureCountRow(siteKey, guild, poolTag)
    if type(row) ~= "table" or row.faction ~= faction or type(row.events) ~= "table" then return nil end
    return normalizeOutpostCapturer(row.events[tostring(captureTs)])
end

-- The ledger knows a capture of this site newer than anything the map holds: the
-- held state is still to be fetched (a targeted pull brings it as a known event).
function Overlord.Leaderboard:OutpostLedgerAheadOfMap(siteKey, st)
    if type(st) ~= "table" then return nil end
    local tenants = self:GetOutpostTenantsTable()
    local t = getValidOutpostTenantRow(self, siteKey, tenants and tenants[siteKey])
    if not t then return nil end
    local mapTs = math.max(math.floor(tonumber(st.claimedAt) or 0),
        math.floor(tonumber(st.previousClaimedAt) or 0))
    if t.claimedAt > mapTs then return t.claimedAt end
    return nil
end

-- The ledger holds a capture of this faction on the site newer than afterTs
-- (the capture the map missed between two tenants of the other faction).
function Overlord.Leaderboard:HasOutpostEventOfFactionSince(siteKey, faction, afterTs)
    afterTs = math.floor(tonumber(afterTs) or 0)
    for _, row in pairs(self:GetOutpostCaptureCountsTable()) do
        if type(row) == "table" and row.siteKey == siteKey and row.faction == faction
            and math.floor(tonumber(row.lastTs) or 0) > afterTs then
            return true
        end
    end
    return false
end

-- This capture is the newest tenant the ledger holds for the site.
function Overlord.Leaderboard:IsOutpostLedgerTenant(siteKey, guild, faction, claimedAt)
    local tenants = self:GetOutpostTenantsTable()
    local t = getValidOutpostTenantRow(self, siteKey, tenants and tenants[siteKey])
    if not t then return false end
    return t.guildKey == sanitizeGuildName(guild or ""):lower() and t.faction == faction
        and t.claimedAt == math.floor(tonumber(claimedAt) or 0)
end

-- Records one accepted capture event. Returns (newEvent, tenantChanged).
function Overlord.Leaderboard:RecordOutpostCapture(siteKey, guild, faction, captureTs, poolTag, capturer)
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    captureTs = math.floor(tonumber(captureTs) or 0)
    capturer = normalizeOutpostCapturer(capturer)
    if siteKey == "" or guild == "" or captureTs <= 0 or not capturer then return false, false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false, false end
    if not isValidOutpostSite(siteKey) then return false, false end
    poolTag = normalizeSavedVarsPool(poolTag)
    if poolTag == "" then poolTag = currentSavedVarsPool() end
    if poolTag == "" or not outpostLbPoolMatchesCurrent(poolTag) then return false, false end
    local campaignStart = self:GetCurrentCampaignStart()
    if not self:IsTimestampInCurrentCampaign(captureTs, campaignStart) then return false, false end
    ensureOutpostLeaderboardTables(self)
    local guildKey = guild:lower()
    local rowKey = outpostCaptureRowKey(siteKey, guildKey, poolTag)
    if rowKey == "" then return false, false end
    local counts = self:GetOutpostCaptureCountsTable()
    ensureOutpostLedgerCounters(self, counts)
    local row = counts[rowKey]
    local eventKey = tostring(captureTs)
    local stored = row and type(row.events) == "table" and row.events[eventKey] or nil
    if type(stored) ~= "string" and (self._outpostLedgerEvents or 0) >= OUTPOST_LEDGER_EVENTS_MAX then
        return false, false
    end
    if not row then
        if (self._outpostLedgerRows or 0) >= OUTPOST_LEDGER_ROWS_MAX then return false, false end
        row = {
            siteKey = siteKey,
            guild = guild,
            guildKey = guildKey,
            faction = faction,
            pool = poolTag,
            events = {},
            count = 0,
            lastTs = 0,
        }
        counts[rowKey] = row
        self._outpostLedgerRows = (self._outpostLedgerRows or 0) + 1
    end
    if type(row.events) ~= "table" then row.events = {} end
    local count = math.max(0, math.floor(tonumber(row.count) or 0))
    local incremented, changed = false, false
    if type(stored) ~= "string" then
        if count >= PLAUSIBLE_OUTPOST_CAPTURE_COUNT then return false, false end
        row.events[eventKey] = capturer
        row.count = count + 1
        self._outpostLedgerEvents = (self._outpostLedgerEvents or 0) + 1
        local index = self._outpostCapturerIndex
        if index then
            local key = outpostCapturerKey(capturer)
            local list = index[key]
            if not list then list = {}; index[key] = list end
            outpostIndexInsert(list, captureTs, outpostSiteGap(siteKey))
        end
        incremented, changed = true, true
    elseif outpostCapturerKey(stored) ~= outpostCapturerKey(capturer) then
        -- An event keeps the first capturer it was accepted with, never a rename.
        return false, false
    end
    local lastTs = math.floor(tonumber(row.lastTs) or 0)
    if captureTs > lastTs or (captureTs == lastTs and row.lastCapturer ~= row.events[eventKey]) then
        row.lastTs = captureTs
        row.lastCapturer = row.events[eventKey]
        changed = true
    end
    row.guild = guild
    if mergeOutpostRowFaction(row, faction) then changed = true end
    row.pool = poolTag
    local tenantChanged = applyOutpostTenant(self, siteKey, guild, faction, captureTs, poolTag, capturer)
    if changed or tenantChanged then
        self:MarkDirty()
        self:RequestOutpostLedgerRebuild()
    end
    return incremented, tenantChanged
end

-- Lignes LO pour reponses SR (tenants avant-postes et fortins, un par site).
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
                capturer = t.capturer,
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

function Overlord.Leaderboard:RequestOutpostLedgerRebuild()
    self._outpostLedgerRevision = (tonumber(self._outpostLedgerRevision) or 0) + 1
    self._outpostLedgerDirty = true
    if not self._outpostLedgerPrepared or self._outpostLedgerPrepPending
        or self._outpostLedgerPrepRetryScheduled or self._outpostLedgerPrepWakePending
        or not C_Timer or not C_Timer.After then return end
    self._outpostLedgerPrepWakePending = true
    C_Timer.After(OUTPOST_LEDGER_REBUILD_DEBOUNCE, function()
        if not Overlord.Leaderboard then return end
        Overlord.Leaderboard._outpostLedgerPrepWakePending = nil
        Overlord.Leaderboard:EnsureOutpostLedgerPrepared(false)
    end)
end

-- LOC packets of one snapshot row: "site:guild:fac:epoch:pool:ts=Given Family,...",
-- newest first, a few events per packet, built once per snapshot (never in a reply).
local OUTPOST_EVENTS_PER_PACKET = 6
Overlord.Leaderboard.OUTPOST_EVENTS_PER_PACKET = OUTPOST_EVENTS_PER_PACKET
local function buildOutpostEventPackets(syncRow, yieldWork)
    local facCode = syncRow.faction == "Alliance" and "A" or "H"
    local head = string.format("%s:%s:%s:%d:%s:", syncRow.siteKey, syncRow.guild, facCode,
        syncRow.epoch, resolveOutpostLbPoolTag(syncRow.pool))
    local packets, parts, bytes = {}, {}, 0
    for i = 1, #syncRow.events do
        local e = syncRow.events[i]
        local part = e.ts .. "=" .. e.capturer
        if #parts >= OUTPOST_EVENTS_PER_PACKET
            or (#parts > 0 and #head + bytes + 1 + #part > 240) then
            packets[#packets + 1] = head .. table.concat(parts, ",")
            parts, bytes = {}, 0
        end
        parts[#parts + 1] = part
        bytes = bytes + #part + (#parts > 1 and 1 or 0)
        if yieldWork then yieldWork() end
    end
    if #parts > 0 then packets[#packets + 1] = head .. table.concat(parts, ",") end
    return packets
end

-- Barriere/cached snapshot du registre LOC. Le premier build est requis avant Sync ;
-- les rebuilds suivants gardent le dernier snapshot convergent lisible et publient
-- atomiquement une generation complete. Aucun handler reseau ne parcourt les SV.
function Overlord.Leaderboard:EnsureOutpostLedgerPrepared(requireCurrent)
    if not OverlordDB then return "blocked" end
    ensureOutpostLeaderboardTables(self)
    self:EnsureOutpostCapturerLedger()
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
        local epoch = math.floor(tonumber(OverlordDB.lastResetTimestamp) or 0)
        local rows, cursor = {}, nil
        -- A row mutated while this pass runs (a handler inserts between two slices)
        -- may be traversed out of order: its counters are repaired at the end, and
        -- only when nothing changed during the pass (otherwise the next pass does it).
        local repairs = {}
        while true do
            local okNext, rowKey, row = pcall(next, buildSource, cursor)
            if not okNext then error(rowKey) end
            cursor = rowKey
            if rowKey == nil then break end
            if type(row) == "table" then
                local events = {}
                local lastTs, lastCapturer = 0, nil
                if type(row.events) == "table" then
                    local eventKey, capturer = next(row.events)
                    while eventKey ~= nil do
                        local okEvent, nextKey, nextValue = pcall(next, row.events, eventKey)
                        if not okEvent then error(nextKey) end
                        local eventTs = math.floor(tonumber(eventKey) or 0)
                        capturer = normalizeOutpostCapturer(capturer)
                        if eventTs > 0 and capturer then
                            events[#events + 1] = { ts = eventTs, capturer = capturer }
                            if eventTs > lastTs then lastTs, lastCapturer = eventTs, capturer end
                        else
                            row.events[eventKey], changed = nil, true
                        end
                        eventKey, capturer = nextKey, nextValue
                        yieldWork()
                    end
                end
                sortRowsWithYield(events, function(a, b)
                    if a.ts ~= b.ts then return a.ts > b.ts end
                    return a.capturer < b.capturer
                end, yieldWork)
                local count = math.min(#events, PLAUSIBLE_OUTPOST_CAPTURE_COUNT)
                if math.floor(tonumber(row.count) or 0) ~= count
                    or math.floor(tonumber(row.lastTs) or 0) ~= lastTs
                    or row.lastCapturer ~= lastCapturer then
                    repairs[#repairs + 1] = { row = row, count = count, lastTs = lastTs, lastCapturer = lastCapturer }
                end
                local siteKey = tostring(row.siteKey or "")
                local guild = sanitizeGuildName(row.guild or "")
                local faction = row.faction or ""
                if epoch > 0 and isValidOutpostSite(siteKey) and guild ~= "" and count > 0
                    and (faction == "Alliance" or faction == "Horde")
                    and outpostLbPoolMatchesCurrent(resolveOutpostLbPoolTag(row.pool)) then
                    local syncRow = {
                        siteKey = siteKey, guild = guild, faction = faction, count = count,
                        lastTs = lastTs, epoch = epoch, pool = row.pool, events = events,
                    }
                    syncRow._syncKey = outpostSyncStableKey(syncRow)
                    syncRow.packets = buildOutpostEventPackets(syncRow, yieldWork)
                    syncRow.events = nil
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
        return { rows = rows, blocks = blocks, subPages = subPages }, buildSource, changed, repairs
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
        local snapshot, committedSource, changed, repairs = result[2], result[3], result[4], result[5]
        if type(snapshot) ~= "table" or type(committedSource) ~= "table" then
            finishFailure("OUTPOST_LEDGER_EMPTY_COMMIT")
            return
        end
        if type(repairs) == "table" and #repairs > 0
            and (tonumber(self._outpostLedgerRevision) or 0) == buildRevision then
            for i = 1, #repairs do
                local r = repairs[i]
                r.row.count, r.row.lastTs, r.row.lastCapturer = r.count, r.lastTs, r.lastCapturer
            end
            self:ResetOutpostLedgerCounters()
            changed = true
        end
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

-- Lignes LOC pour reponses SR : chaque couple (site, guilde) avec la liste de ses
-- captures signees, du plus recent au plus ancien. Un retardataire ou un client de
-- l'autre faction recoit les evenements eux-memes, jamais un total a croire sur parole.
function Overlord.Leaderboard:BuildOutpostCaptureCountSyncRows()
    local prepared = self:EnsureOutpostLedgerPrepared()
    local snapshot = self._outpostSyncSnapshot
    if prepared ~= true or type(snapshot) ~= "table" then return {}, {}, {} end
    -- Lecture handler strictement O(1). Les pages sont construites/sorties par la
    -- coroutine de preparation, jamais par la reponse SR.
    return snapshot.rows or {}, snapshot.blocks or {}, snapshot.subPages or {}
end

-- Separate presentation column; the storage, scoring and tie-breaks are shared.
function Overlord.Leaderboard:GetSortedGuildKeeps(sortedGuildKillsForNames, yieldWork)
    local rows = self:GetSortedOutposts(sortedGuildKillsForNames, yieldWork, true)
    for _, row in ipairs(rows) do
        row.keepSiteKey, row.keepAtlas, row.wins = row.outpostSiteKey, row.outpostAtlas, row.captures
    end
    return rows
end

function Overlord.Leaderboard:GetSortedOutposts(sortedGuildKillsForNames, yieldWork, fortressOnly)
    local op = Overlord.Outpost
    local captureCounts = self:GetOutpostCaptureCountsTable()
    local tenants = self:GetOutpostTenantsTable()
    local sorted = {}
    local rowKeys = {}
    local function includeSite(key)
        local site = Overlord.OutpostSites and Overlord.OutpostSites[key]
        return site and (site.isFortress == true) == (fortressOnly == true)
    end

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
            -- 1.4.0: a tenant stamped by another ruleset's campaign is not ours.
            if includeSite(siteKey) and guild ~= "" and (fac == "Alliance" or fac == "Horde")
                and outpostLbPoolMatchesCurrent(rowPool) then
                local key = guild:lower()
                local rowKey = outpostCaptureRowKey(siteKey, key, rowPool)
                rowKeys[rowKey] = true
                local bucket = captureCounts[rowKey]
                local captures = bucket and math.floor(tonumber(bucket.count) or 0) or 0
                -- Who took it: the held state names its capturer; the tenant row or the
                -- newest event of the row otherwise.
                local capturer = nil
                if st and st.status == "held" and st.heldCapturerName
                    and sanitizeGuildName(st.heldCapturerGuild or "") == guild then
                    capturer = normalizeOutpostCapturer(st.heldCapturerName)
                end
                if not capturer and t and t.guildKey == key and t.faction == fac then
                    capturer = t.capturer
                end
                if not capturer and bucket then
                    capturer = normalizeOutpostCapturer(bucket.lastCapturer)
                end
                sorted[#sorted + 1] = {
                    guild = guild,
                    faction = fac,
                    outpostAtlas = op and op.GetMainHallAtlasForFaction
                        and op:GetMainHallAtlasForFaction(fac, op:GetSite(siteKey)),
                    outpostSiteKey = siteKey,
                    captures = captures,
                    currentlyHeld = currentlyHeld,
                    capturer = capturer,
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
        if type(bucket) == "table" and includeSite(bucket.siteKey) and not rowKeys[rowKey] then
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
                    capturer = normalizeOutpostCapturer(bucket.lastCapturer),
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

-- Preneurs et rivalites de la semaine, lus dans le registre des prises signees (fiefs
-- et avant-postes de la campagne courante). Le registre converge par union
-- d'evenements : tous les clients a jour voient les memes chiffres, sans aucun paquet
-- de plus. Une rivalite = deux prises successives d'un meme site par des guildes de
-- factions opposees (« A a pris a B »). Recalcule quand le registre change, au plus
-- toutes les 3 s : pendant un rattrapage, le volet garde un instant l'etat precedent.
-- Pas de table par prise : chaque prise est un nombre ts * 1024 + numero de ligne,
-- trie par le tri natif (registre plafonne a 512 lignes et 20 000 prises).
local OUTPOST_WEEKLY_STATS_MIN_INTERVAL = 3

function Overlord.Leaderboard:GetOutpostWeeklyStats()
    local counts = self:GetOutpostCaptureCountsTable()
    local stamp = tostring(counts) .. ":" .. (tonumber(self._outpostLedgerRevision) or 0)
        .. ":" .. (tonumber(self._outpostLedgerEvents) or 0)
    local cache = self._outpostWeeklyStats
    if cache and cache.stamp == stamp then return cache end
    local now = GetTime and GetTime() or 0
    -- Second retour vrai : resultat en retard, l'appelant relit apres l'intervalle.
    if cache and now - (cache.builtAt or 0) < OUTPOST_WEEKLY_STATS_MIN_INTERVAL then return cache, true end
    -- Lignes retenues, numerotees dans l'ordre (site, guilde) : meme ordre sur tous les clients.
    local rows = {}
    for _, row in pairs(counts) do
        local site = type(row) == "table" and Overlord.OutpostSites and Overlord.OutpostSites[row.siteKey]
        local guild = site and sanitizeGuildName(row.guild or "") or ""
        if guild ~= "" and type(row.events) == "table" and (row.faction == "Alliance" or row.faction == "Horde")
            and outpostLbPoolMatchesCurrent(resolveOutpostLbPoolTag(row.pool)) then
            rows[#rows + 1] = { row = row, siteKey = row.siteKey, guild = guild, key = guild:lower(),
                isKeep = site.isFortress == true }
        end
    end
    table.sort(rows, function(a, b)
        if a.siteKey ~= b.siteKey then return a.siteKey < b.siteKey end
        return a.key < b.key
    end)
    local byCapturer, bySite, capturerKeys = {}, {}, {}
    for index = 1, math.min(#rows, 1023) do
        local info = rows[index]
        local faction = info.row.faction
        local list = bySite[info.siteKey]
        if not list then list = {}; bySite[info.siteKey] = list end
        for tsKey, capturer in pairs(info.row.events) do
            local ts = tonumber(tsKey)
            local key = capturerKeys[capturer]
            if key == nil then
                local name = normalizeOutpostCapturer(capturer)
                key = name and outpostCapturerKey(name) or false
                capturerKeys[capturer] = key
            end
            -- ts * 1024 reste exact (< 2^53) pour toute date jusqu'a 1e12 s.
            if key and ts and ts > 0 and ts < 1e12 then
                local c = byCapturer[key]
                if not c then
                    c = { name = normalizeOutpostCapturer(capturer), faction = faction,
                        keeps = 0, outposts = 0, total = 0 }
                    byCapturer[key] = c
                end
                if info.isKeep then c.keeps = c.keeps + 1 else c.outposts = c.outposts + 1 end
                c.total = c.total + 1
                list[#list + 1] = math.floor(ts) * 1024 + index
            end
        end
    end
    local capturers = {}
    for _, c in pairs(byCapturer) do capturers[#capturers + 1] = c end
    table.sort(capturers, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        if a.keeps ~= b.keeps then return a.keeps > b.keeps end
        return a.name < b.name
    end)
    local byPair = {}
    for _, list in pairs(bySite) do
        table.sort(list)
        for i = 2, #list do
            local prev, cur = rows[list[i - 1] % 1024], rows[list[i] % 1024]
            local pf, cf = prev.row.faction, cur.row.faction
            if cf ~= pf and cur.key ~= prev.key then
                local pairKey = cur.key .. "\001" .. prev.key
                local r = byPair[pairKey]
                if not r then
                    r = { taker = cur.guild, takerFaction = cf, victim = prev.guild, victimFaction = pf, count = 0 }
                    byPair[pairKey] = r
                end
                r.count = r.count + 1
            end
        end
    end
    local rivalries = {}
    for _, r in pairs(byPair) do rivalries[#rivalries + 1] = r end
    table.sort(rivalries, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.taker ~= b.taker then return a.taker < b.taker end
        return a.victim < b.victim
    end)
    cache = { stamp = stamp, builtAt = now, capturers = capturers, rivalries = rivalries }
    self._outpostWeeklyStats = cache
    return cache
end

-- Nombre max de campagnes archivees (au-dela, les plus anciennes sont supprimees)
local MAX_HISTORY_ENTRIES = 12
-- Top N joueurs conserves par archive : l'historique est un souvenir compact, pas une
-- copie integrale du bucket (une archive complete pesait ~100 Ko en event massif et
-- l'historique etait le premier poste de taille du fichier SavedVariables).
local MAX_HISTORY_PLAYERS = 100

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
local LADDER_SNAPSHOT_MAX_CAPTURE_PLAYERS_PER_FACTION = Overlord.Leaderboard.CAPTURE_RANK_LIMIT
local LADDER_SNAPSHOT_WORK_PER_SLICE = 80
local LADDER_SNAPSHOT_SLICE_BUDGET_MS = 1
local LADDER_SNAPSHOT_MAX_ZONES_PER_PLAYER = 128
local LADDER_SNAPSHOT_MAX_ZONE_BYTES_PER_PLAYER = 3000

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
    -- L'archive d'un reset plus ancien bloquait l'ouverture du bucket d'un reset plus
    -- recent (absence couvrant deux resets) : l'ancienne semaine restait affichee
    -- jusqu'au filet de 60 s. Ce reset en attente part des que la voie est libre.
    local waiting = tonumber(OverlordDB.pendingWeeklyResetAt) or 0
    if waiting > 0 and waiting ~= tonumber(marker.resetEpoch) and Overlord.CheckWeeklyReset then
        C_Timer.After(0, function() pcall(Overlord.CheckWeeklyReset, Overlord) end)
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
    -- Point de reprise : scores complets, mais metadonnees (classe/guilde/niveau/race)
    -- seulement pour les 500 meilleurs. Le bucket complet est deja dans le marker
    -- d'archive ; une copie integrale de playerInfo doublait 26 000 lignes de fichier.
    -- Sans table par ligne ni tri des lignes (gel de 100 ms et plus a 20 000 lignes,
    -- chez tous les clients a la seconde du reset) : seuil du top 500 par histogramme
    -- des totaux, puis une passe. Les ex aequo au seuil ne sont gardes que dans la limite.
    local oldScoreBucketEpoch = GetMatchingLeaderboardScoreBucketEpoch(archiveEpoch)
    -- 1.7.8: no copy of the finished week is kept any more (it held the whole
    -- previous ladder in memory and in the save for 7 days, read by no code; the
    -- full history is archived outside the game). The compact history stays.
    OverlordDB.leaderboardPreviousCampaigns = nil
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
    dedupHardEpoch = dedupHardEpoch + 1
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
    -- Share the login index builder, so aliases cannot occupy two ranking slots.
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
        captureIndex = dedupCaptureMaxIndex,
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
        zoneNamesByDedup = {},
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
        -- 1.4.1: an empty ladder never keeps another ruleset's snapshot.
        local previousPool = normalizeSavedVarsPool(type(previous) == "table"
            and tostring(previous.pool or "global") or "")
        if #killRows == 0 and #capRows == 0 and type(previous) == "table"
            and previous.campaignStart == state.campaignStart
            and previous.scoreBucketEpoch == state.scoreBucketEpoch
            and previousPool == currentSavedVarsPool() then
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
        -- Copy metadata in slices as well as sorting at the 5000-player cap.
        -- 1.7.8: a meta index entry is never written in place (a change publishes a
        -- new entry), so the snapshot shares it instead of copying 13 fields per
        -- player (~4.6 MB per build at 5,000 players). Same values for every reader:
        -- the entry holds them already normalized. Entries carry no factionAt: a row
        -- restored from the snapshot gets 0 there (an older date, the safe side of the
        -- pool tie-break); src and raceKey are saved along, unused by every reader.
        for name in pairs(kept) do
            local entry = state.metaIndex[GetKillDedupKey(name)]
            local info = entry or (state.playerInfoSource and state.playerInfoSource[name])
            if entry then
                snapInfo[name] = entry
            elseif type(info) == "table" then
                snapInfo[name] = {
                    class = info.class or "",
                    faction = info.faction or "",
                    factionAt = tonumber(info.factionAt) or 0,
                    locale = info.locale or "",
                    guild = info.guild or "",
                    guildAuth = info.guildAuth == true or nil,
                    guildReplica = info.guildReplica == true or nil,
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
        -- Les scores sont dedupes: les zones peuvent encore vivre sous plusieurs
        -- alias. La phase "zones" a construit leur index en tranches une seule fois.
        for i = 1, #captureOrder do
            local name = captureOrder[i]
            local sourceNames = state.zoneNamesByDedup[GetKillDedupKey(name)]
            if sourceNames then
                local copy, selected = {}, {}
                for sourceIndex = 1, #sourceNames do
                    local zones = state.capturesSource[sourceNames[sourceIndex]]
                    if type(zones) == "table" then
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
                    end
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
            local source = state.phase == "kills" and state.killIndex
                or state.phase == "captures" and state.captureIndex
                or state.capturesSource
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
                elseif state.phase == "captures" then
                    state.phase = "zones"
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
                elseif state.phase == "captures" then
                    local name = state.canonicalIndex[key] or key
                    local info = state.metaIndex[key]
                    local faction = type(info) == "table" and info.faction or ""
                    local heap = faction == "Alliance" and state.capHeapAlliance
                        or faction == "Horde" and state.capHeapHorde
                        or state.capHeapUnknown
                    self:OfferTopSnapshotRow(heap, name, value)
                else
                    if type(value) == "table" then
                        local dedup = GetKillDedupKey(key)
                        if dedup then
                            local names = state.zoneNamesByDedup[dedup]
                            if not names then
                                names = {}
                                state.zoneNamesByDedup[dedup] = names
                            end
                            names[#names + 1] = key
                        end
                    end
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
    -- No pool = written before 1.4 = the PvP campaign (same rule as the responder).
    local snapPool = normalizeSavedVarsPool(tostring(snap.pool or "global"))
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
        -- Cheap comparison first: almost no saved row is above the live one, and the
        -- denylist (name-case walk) is then evaluated only for rows really written.
        if type(name) == "string" and name ~= "" and n > 0
            and n > (tonumber(self.kills[name]) or 0)
            and not (Overlord.Sync and Overlord.Sync.IsDeniedKillContributor
                and Overlord.Sync:IsDeniedKillContributor(name)) then
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
                guildReplica = info.guildReplica == true or nil,
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
                    currentGuild, currentGuildAt, current.guildAuth,
                    info.guildReplica, current.guildReplica) then
                    current.guild = snapshotGuild
                    current.guildAuth = info.guildAuth == true or nil
                    current.guildReplica = info.guildReplica == true or nil
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
        -- 1.7.5 : apres un reset hebdomadaire en ligne, notre fiche recreee restait sans
        -- classe jusqu'au login suivant, et une ligne sans classe n'est plus servie.
        local mine = self.playerInfo[playerName]
        if sync and sync.IsLadderRowClass and UnitClass
            and not (type(mine) == "table" and sync:IsLadderRowClass(mine.class)) then
            local _, classFile = UnitClass("player")
            if sync:IsLadderRowClass(classFile) then
                self:ForceUpdateLocalPlayer(playerName, classFile,
                    UnitFactionGroup and UnitFactionGroup("player") or nil)
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
    if localPoolChanged then self:MarkPlayerMetaDirty(playerName) end
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
-- (Called for every row of an index rebuild: no closure per call.)
local function nameHasPipe(s)
    return s and s:find("|", 1, true)
end
function Overlord.Leaderboard:ChooseRicherPlayerName(prev, new)
    if not prev then return new end
    if not new then return prev end
    local hasPipe = nameHasPipe
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
    local rowCount = math.min(#rows,
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
