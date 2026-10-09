-- Classement : rattrapage v6 entre voisins directs (1.2.4).
--
-- Le classement se rattrape uniquement par le protocole pagine v6
-- (SyncLeaderboardPages.lua), avec un voisin direct : meme canal, groupe,
-- chuchotement ou ami Battle.net. L'ancien echange v4 (615 lignes a chaque
-- ecart, retour de l'union, relaye sur plusieurs etapes) est retire : il
-- saturait le relais a chaque vague de connexions. L'historique des
-- avant-postes et forteresses (LO + LOC) passe par une demande SR "H" dediee.
--
-- Ce fichier conserve aussi le snapshot atteste du classement et sa
-- serialisation, partages par les pages v6 et par la reponse manuelle SR:F.

local Overlord = _G.Overlord
if not Overlord or not Overlord.Sync then return end

local sync = Overlord.Sync
local MAX_SNAPSHOT_ROWS = Overlord.Leaderboard.NETWORK_KILL_RANK_LIMIT or 500
local MAX_SNAPSHOT_QUEUE = MAX_SNAPSHOT_ROWS + 75 + 40
local MAX_RACE_ROWS = 40
local HASH_MOD = 2147483647
-- Un tour v6 reussi rearme le suivant apres deux minutes ; un tour sans voisin
-- ou sans reponse reessaie apres deux minutes aussi.
local RECENT_ACK_SEC = 2 * 60
local EXHAUSTED_RETRY_SEC = 2 * 60
local PERIODIC_JITTER_SEC = 60
-- Historique avant-postes/forteresses : une demande toutes les six heures, une
-- fois des lignes reellement recues ; sinon une nouvelle tentative apres 15 min.
local HISTORY_ACK_SEC = 6 * 60 * 60
local HISTORY_LEASE_SEC = 15 * 60
-- A reply that brought new captures is followed by another round soon: a long
-- history is served in slices.
local HISTORY_FRESH_RETRY_SEC = 30 * 60
-- Un voisin occupe ou interrompu cede sa place quelques instants aux autres.
local BUSY_PEER_SEC = 45
local CAMPAIGN_MIN_AGE_SEC = 30 * 60
local INITIAL_DELAY_SEC = 24
-- On the affected Forever beta, the client can omit every account SavedVariable
-- at login. Let the territorial burst finish first, then seek a peer sooner.
local EMPTY_SAVE_INITIAL_DELAY_SEC = 16
local MAX_ATTEMPTS = 4
-- In combat or an instance, look again after this delay without spending an attempt.
local COMBAT_RECHECK_SEC = 15
-- Un voisin muet (sans reponse v6) est ecarte du choix pendant ce delai.
local PEER_PENALTY_SEC = 10 * 60
-- Garde-fou : un tour plus long que ceci est abandonne (rien n'est perdu, la
-- reprise se fait depuis le point de controle du bucket).
local ROUND_WATCHDOG_SEC = 15 * 60
local peerPenaltyUntil = {}
local ENEMY_FACTION = { Alliance = "Horde", Horde = "Alliance" }
local snapshotWireCache = setmetatable({}, { __mode = "k" })
local PrepareSnapshotForNetwork

local function NowServer()
    return (GetServerTime and GetServerTime()) or time()
end

local function CurrentCampaign()
    local start = math.floor(tonumber(
        Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs()) or 0)
    local campaignId = math.floor(tonumber(OverlordDB and OverlordDB.campaignId) or 0)
    if campaignId <= 0 and start > 0 and Overlord.TimestampToCampaignId then
        campaignId = math.floor(tonumber(Overlord:TimestampToCampaignId(start)) or 0)
    end
    return start, campaignId
end

-- Deux clients NA peuvent ancrer le meme reset hebdomadaire sur l'epoch API
-- Blizzard ou sur l'epoch de repli calendrier : meme equivalence que le reste.
local function CampaignEpochsMatch(a, b)
    if Overlord.CampaignEpochsMatch then
        return Overlord:CampaignEpochsMatch(a, b)
    end
    return math.floor(tonumber(a) or 0) == math.floor(tonumber(b) or 0)
end

local function PenalizePeer(name, seconds)
    if type(name) == "string" and name ~= "" then
        local untilAt = GetTime() + (seconds or PEER_PENALTY_SEC)
        if untilAt > (peerPenaltyUntil[name:lower()] or 0) then
            peerPenaltyUntil[name:lower()] = untilAt
        end
    end
end

local function ForgivePeer(name)
    if type(name) == "string" and name ~= "" then peerPenaltyUntil[name:lower()] = nil end
end

local function PeerFaction(name)
    -- Faction Battle.net (amis/ponts) ; la faction du classement n'est que ce que le
    -- pair dit de lui-meme : GetBetaPeerFaction ne la retient que si c'est la notre.
    if sync.GetBetaPeerFaction then
        local known = sync:GetBetaPeerFaction(name)
        if known == "Alliance" or known == "Horde" then return known end
    end
    return nil
end

-- Etat du rattrapage pour /ov sync (memoire de session uniquement).
local function NoteHr(field, value, extra)
    local stats = sync._historyCatchupStats or { requests = 0, completed = 0, rows = 0 }
    sync._historyCatchupStats = stats
    if field == "requests" or field == "completed" or field == "rows" then
        stats[field] = (stats[field] or 0) + value
    elseif field == "target" then
        stats.target, stats.targetFaction, stats.targetAt = value, extra, GetTime()
        stats.result = "waiting"
    else
        stats[field] = value
        if field == "step" then stats.stepAt = GetTime() end
    end
end

local function HashString(value)
    value = tostring(value or "")
    local hash = 5381
    for i = 1, #value do
        hash = (hash * 33 + value:byte(i)) % HASH_MOD
    end
    return hash
end

local function HashPacket(msgType, data)
    return HashString(tostring(msgType or "") .. "\31" .. tostring(data or ""))
end

local function SafeWireField(value, maxBytes)
    -- Fast path: almost no field carries a separator; skip the gsub copy then.
    local text = tostring(value or "")
    if text:find("[:\r\n]") then text = text:gsub("[:\r\n]", "") end
    if maxBytes and #text > maxBytes then text = text:sub(1, maxBytes) end
    return text
end

local function SnapshotForCampaign(campaignStart)
    local snapshot = OverlordDB and OverlordDB.leaderboardSnapshot
    if type(snapshot) ~= "table"
        or math.floor(tonumber(snapshot.campaignStart) or 0) ~= campaignStart then
        return nil
    end
    local snapshotBucket = math.floor(tonumber(snapshot.scoreBucketEpoch) or 0)
    local localBucket = math.floor(tonumber(
        OverlordDB and OverlordDB.leaderboardScoreBucketEpoch) or 0)
    if snapshotBucket <= 0 or localBucket <= 0 or snapshotBucket ~= localBucket then
        return nil
    end
    -- 1.4.1: never serve another ruleset's ladder (a snapshot without a pool
    -- predates 1.4.0 and belongs to the PvP campaign).
    local pools = Overlord.RealmPools
    local snapPool = pools and pools:NormalizeRegionPool(snapshot.pool or "global") or "global"
    local localPool = Overlord.GetCurrentLeaderboardSavedVarsPool
        and Overlord:GetCurrentLeaderboardSavedVarsPool() or "global"
    if snapPool ~= localPool then return nil end
    return snapshot
end

local function AppendSnapshotNames(result, seen, order, values, limit, yieldWork)
    if type(order) == "table" then
        for i = 1, math.min(#order, limit) do
            local name = tostring(order[i] or "")
            if name ~= "" and not seen[name] and tonumber(values and values[name]) then
                result[#result + 1] = name
                seen[name] = true
            end
            if yieldWork then yieldWork() end
        end
    end
end

local function SnapshotNameLists(snapshot, killLimit, yieldWork)
    local kills, captures, killSeen, captureSeen = {}, {}, {}, {}
    AppendSnapshotNames(kills, killSeen, snapshot and snapshot.killOrder,
        snapshot and snapshot.kills, killLimit or MAX_SNAPSHOT_ROWS, yieldWork)
    AppendSnapshotNames(captures, captureSeen, snapshot and snapshot.captureOrder,
        snapshot and snapshot.captureCount, 75, yieldWork)
    return kills, captures
end

local function FactionCode(value)
    value = tostring(value or "")
    if value == "Alliance" or value == "A" then return "A" end
    if value == "Horde" or value == "H" then return "H" end
    return "U"
end

local function ContributorCanRelay(name)
    return sync.HasCompleteContributorIdentity
        and sync:HasCompleteContributorIdentity(name) or false
end

local function AppendPacket(queue, msgType, data)
    if #queue >= MAX_SNAPSHOT_QUEUE or not data or data == "" then return false end
    if #(tostring(msgType or "") .. ":" .. data) > 255 then return false end
    queue[#queue + 1] = { type = msgType, data = data }
    return true
end

local function BuildSnapshotKillPayload(snapshot, name, wireEpoch)
    local info = type(snapshot.playerInfo) == "table" and snapshot.playerInfo[name] or nil
    info = type(info) == "table" and info or {}
    local level = math.floor(tonumber(info.level) or 0)
    if not sync.IsEligibleKillContributorLevel
        or not sync:IsEligibleKillContributorLevel(level)
        or (sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name))
        or not ContributorCanRelay(name) then
        return nil
    end
    -- 1.7.5 : une ligne sans classe n'est ni acceptee ni servie (IsLadderRowClass).
    if sync.IsLadderRowClass and not sync:IsLadderRowClass(info.class) then return nil end
    local kills = math.floor(tonumber(snapshot.kills and snapshot.kills[name]) or 0)
    -- Same per-level ceiling as the receivers (1.4.2): serve the clamped value, so
    -- every client holds the same number and bucket digests match on both sides.
    if sync.MaxPlausibleKillsForLevel then
        kills = math.min(kills, sync:MaxPlausibleKillsForLevel(level))
    end
    -- 1.7.6 : same campaign envelope as the receivers (Sync:CampaignKillEnvelope).
    local envelope = sync.CampaignKillEnvelope and sync:CampaignKillEnvelope()
    if envelope then kills = math.min(kills, envelope) end
    local guild = SafeWireField(info.guild, 96)
    if guild ~= "" and sync.IsValidGuildSyncToken
        and not sync:IsValidGuildSyncToken(guild) then guild = "" end
    -- Only a strong register goes out: confirmed by the player himself (K/GI, our
    -- guild roster, our group) or received in a page. A second-hand hint (GY answer)
    -- stays local: the first, possibly forged, answer was otherwise re-served as a
    -- page register and spread a fake guild (2026-10-06).
    local strongGuild = info.guildAuth == true or info.guildReplica == true
    if not strongGuild then guild = "" end
    local fields = {
        SafeWireField(name, 80),
        tostring(kills),
        SafeWireField(info.class == "UNKNOWN" and "" or info.class, 24),
        SafeWireField(info.faction, 12),
        tostring(wireEpoch),
        SafeWireField(info.locale, 8),
        guild,
        tostring(strongGuild and math.floor(tonumber(info.guildAt) or 0) or 0),
        "B" .. tostring(wireEpoch),
        tostring(level),
    }
    local payload = table.concat(fields, ":")
    if #payload <= 250 then return payload end
    fields[7], fields[8] = "", "0"
    payload = table.concat(fields, ":")
    if #payload <= 250 then return payload end
    fields[6] = ""
    payload = table.concat(fields, ":")
    return #payload <= 250 and payload or nil
end

local function BuildSnapshotCapturePayload(snapshot, name, wireEpoch, full)
    if not ContributorCanRelay(name)
        or (sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name)) then return nil end
    local info = type(snapshot.playerInfo) == "table" and snapshot.playerInfo[name] or nil
    info = type(info) == "table" and info or {}
    local zones, safeZones = snapshot.captures and snapshot.captures[name], {}
    if type(zones) == "table" then
        for i = 1, math.min(#zones, full and 128 or 32) do
            local zoneId = SafeWireField(zones[i], full and 80 or 32)
            if zoneId ~= "" then safeZones[#safeZones + 1] = zoneId end
        end
    end
    -- L'union LC conserve volontairement l'ordre local d'insertion. Trier ici
    -- rend le payload et son digest independants de cet ordre, sinon deux pairs
    -- possedant exactement les memes zones pouvaient echouer HA:C en boucle.
    table.sort(safeZones)
    local uniqueCount = 0
    for i = 1, #safeZones do
        if i == 1 or safeZones[i] ~= safeZones[i - 1] then
            uniqueCount = uniqueCount + 1
            safeZones[uniqueCount] = safeZones[i]
        end
    end
    for i = #safeZones, uniqueCount + 1, -1 do safeZones[i] = nil end
    local prefix = table.concat({
        SafeWireField(name, 80),
        FactionCode(info.faction),
        SafeWireField(info.class == "UNKNOWN" and "" or info.class, 24),
        tostring(math.floor(tonumber(snapshot.captureCount
            and snapshot.captureCount[name]) or 0)),
        tostring(wireEpoch),
    }, ":") .. ":"
    local suffix = ":" .. SafeWireField(info.locale, 8)
        .. ":B" .. tostring(wireEpoch)
    local maxBytes = full and 3500 or 250
    if not full then
        while #safeZones > 0
            and #(prefix .. table.concat(safeZones, ",") .. suffix) > maxBytes do
            safeZones[#safeZones] = nil
        end
    end
    local payload = prefix .. table.concat(safeZones, ",") .. suffix
    return #payload <= maxBytes and payload or nil
end

-- v6 pages read the full attested capture/race view. The v4 queue above remains
-- fixed at 615 packets for clients that cannot understand typed pages.
function sync:BuildPagedLeaderboardCapturePayload(snapshot, name, wireEpoch)
    local captures = snapshot and snapshot.captureCount and snapshot.captureCount[name]
    if not self.SanitizeSyncedCaptureCount
        or self:SanitizeSyncedCaptureCount(captures) == nil then return nil end
    return BuildSnapshotCapturePayload(snapshot, name, wireEpoch, true)
end

function sync:BuildPagedLeaderboardRacePayload(snapshot, name, wireEpoch)
    local info = snapshot and snapshot.playerInfo and snapshot.playerInfo[name]
    if type(info) ~= "table" or not ContributorCanRelay(name) then return nil end
    if self.IsDeniedKillContributor and self:IsDeniedKillContributor(name) then return nil end
    if not self.BuildLeaderboardRacePayload then return nil end
    return self:BuildLeaderboardRacePayload(
        name, info.race, info.raceSex, wireEpoch, info.raceAt)
end

-- The paged protocol reuses the exact LK serializer and attested snapshot.
function sync:BuildPagedLeaderboardKillPayload(snapshot, name, wireEpoch)
    -- Only garbage is refused here; the serializer clamps to the level ceiling, so
    -- an owner above it is still served (at the ceiling) and digests stay equal.
    local kills = tonumber(snapshot and snapshot.kills and snapshot.kills[name])
    if not kills or kills ~= kills or kills < 0 then return nil end
    return BuildSnapshotKillPayload(snapshot, name, wireEpoch)
end

function sync:GetAttestedLeaderboardSnapshot()
    return SnapshotForCampaign(CurrentCampaign())
end

-- Seule source des pages LK/LC/LR du protocole HR. La file est plafonnee a
-- 615 paquets et ne trie, fusionne ni repare le classement actif.
function sync:BuildHistoryCatchupSnapshotQueue(snapshot, wireEpoch, killLimit, yieldWork)
    local queue, raceSeen = {}, {}
    if type(snapshot) ~= "table" then return queue end
    local killNames, captureNames = SnapshotNameLists(snapshot, killLimit, yieldWork)
    for i = 1, #killNames do
        local name = killNames[i]
        AppendPacket(queue, "LK", BuildSnapshotKillPayload(snapshot, name, wireEpoch))
        if yieldWork then yieldWork() end
    end
    for i = 1, #captureNames do
        local name = captureNames[i]
        AppendPacket(queue, "LC", BuildSnapshotCapturePayload(snapshot, name, wireEpoch))
        if yieldWork then yieldWork() end
    end
    local raceSent = 0
    local function appendRace(name)
        if raceSent >= MAX_RACE_ROWS or #queue >= MAX_SNAPSHOT_QUEUE
            or raceSeen[name] then return end
        raceSeen[name] = true
        local info = type(snapshot.playerInfo) == "table" and snapshot.playerInfo[name] or nil
        if type(info) ~= "table" or not ContributorCanRelay(name) then return end
        local payload = self.BuildLeaderboardRacePayload
            and self:BuildLeaderboardRacePayload(
                name, info.race, info.raceSex, wireEpoch, info.raceAt)
        if AppendPacket(queue, "LR", payload) then raceSent = raceSent + 1 end
    end
    for i = 1, #killNames do
        appendRace(killNames[i]); if yieldWork then yieldWork() end
    end
    for i = 1, #captureNames do
        appendRace(captureNames[i]); if yieldWork then yieldWork() end
    end
    return queue
end

-- Page legacy SR:F construite uniquement depuis le snapshot visible borne.
-- Les premieres lignes restent prioritaires et la longue traine tourne entre
-- les demandes, comme l'ancien export actif, sans heal/merge/tri du bucket live.
function sync:BuildBoundedFullSrLeaderboardQueue(snapshot, wireEpoch, isLargeEvent)
    local _, _, source = self:ComputeHistoryCatchupSnapshotDigest(snapshot, wireEpoch)
    local byType = { LK = {}, LR = {}, LC = {} }
    for i = 1, #source do
        local packet = source[i]
        local rows = packet and byType[packet.type]
        if rows then rows[#rows + 1] = packet end
    end
    local page = {}
    local function appendRotating(msgType, maximum, fixed, cursorField)
        local rows = byType[msgType]
        local total = #rows
        fixed = math.min(fixed, maximum, total)
        for i = 1, fixed do page[#page + 1] = rows[i] end
        if total <= fixed or maximum <= fixed then return end
        local pool = total - fixed
        local cursor = math.max(0, math.floor(tonumber(self[cursorField]) or 0))
        local start = (cursor % pool) + 1
        local sent = math.min(maximum - fixed, pool)
        for offset = 0, sent - 1 do
            local index = fixed + ((start + offset - 1) % pool) + 1
            page[#page + 1] = rows[index]
        end
        self[cursorField] = (cursor + sent) % pool
    end
    appendRotating("LK", isLargeEvent and 40 or 50,
        isLargeEvent and 10 or 25, "_srSnapshotKillCursor")
    appendRotating("LR", isLargeEvent and 20 or 30,
        isLargeEvent and 8 or 20, "_srSnapshotRaceCursor")
    appendRotating("LC", 20,
        isLargeEvent and 5 or 10, "_srSnapshotCaptureCursor")
    return page
end

-- Lance/rejoint le snapshot tranche de Leaderboard.lua puis publie exactement
-- une page SR:F bornee. Le callback peut etre synchrone si le snapshot est deja
-- propre ; `settled` garantit une terminaison unique dans les deux modes.
function sync:PrepareBoundedFullSrLeaderboardQueue(isLargeEvent, callback)
    if type(callback) ~= "function" then return false end
    local lb = Overlord.Leaderboard
    if not lb or not lb.SnapshotCurrentCampaignBeforeReset then
        callback(false, {})
        return false
    end
    local settled = false
    local function finish(success, page)
        if settled then return end
        settled = true
        callback(success == true, type(page) == "table" and page or {})
    end
    local accepted = PrepareSnapshotForNetwork(lb, function(success, preparedSnapshot)
        if settled then return end
        local campaignStart = CurrentCampaign()
        local snapshot = success and preparedSnapshot or nil
        if not snapshot then
            finish(false, {})
            return
        end
        -- La finalisation du snapshot est appelee sous pcall par Leaderboard.lua.
        -- Capturer aussi localement une erreur de serialisation garantit que le
        -- pump SR:F quitte immediatement son etat preparing au lieu d'attendre
        -- son deadline de securite sans son tail classement.
        local built, page = pcall(sync.BuildBoundedFullSrLeaderboardQueue,
            sync, snapshot, campaignStart, isLargeEvent == true)
        finish(built, built and page or {})
    end)
    if accepted ~= true then finish(false, {}) end
    return accepted == true
end

function sync:ComputeHistoryCatchupSnapshotDigest(snapshot, wireEpoch, killLimit, yieldWork)
    killLimit = killLimit or MAX_SNAPSHOT_ROWS
    local profiles = type(snapshot) == "table" and snapshotWireCache[snapshot] or nil
    local cached = profiles and profiles[killLimit]
    if cached and cached.wireEpoch == wireEpoch then
        return cached.count, cached.hash, cached.queue
    end
    local queue = self:BuildHistoryCatchupSnapshotQueue(snapshot, wireEpoch, killLimit, yieldWork)
    local hash = 0
    for i = 1, #queue do
        hash = (hash + HashPacket(queue[i].type, queue[i].data)) % HASH_MOD
        if yieldWork then yieldWork() end
    end
    if type(snapshot) == "table" then
        snapshotWireCache[snapshot] = profiles or {}
        snapshotWireCache[snapshot][killLimit] = {
            wireEpoch = wireEpoch,
            count = #queue,
            hash = hash,
            queue = queue,
        }
    end
    return #queue, hash, queue
end

-- Serialization and hashing also yield; callers only read a finished immutable cache.
local snapshotWireBuilds = setmetatable({}, { __mode = "k" })
PrepareSnapshotForNetwork = function(lb, callback, killLimit, requestedWireEpoch)
    killLimit = killLimit or MAX_SNAPSHOT_ROWS
    return lb:SnapshotCurrentCampaignBeforeReset(function(success)
        local campaignStart = CurrentCampaign()
        local snapshot = success and SnapshotForCampaign(campaignStart)
        if not snapshot then callback(false); return end
        local wireEpoch = requestedWireEpoch or campaignStart
        if not CampaignEpochsMatch(wireEpoch, campaignStart) then callback(false); return end
        local profiles = snapshotWireCache[snapshot]
        local cached = profiles and profiles[killLimit]
        if cached and cached.wireEpoch == wireEpoch then callback(true, snapshot); return end
        local builds = snapshotWireBuilds[snapshot] or {}
        snapshotWireBuilds[snapshot] = builds
        local active = builds[killLimit]
        if active and active.wireEpoch == wireEpoch then
            active.callbacks[#active.callbacks + 1] = callback
            return
        end
        local state = { wireEpoch = wireEpoch, callbacks = { callback } }
        builds[killLimit] = state
        local work, started = 0, 0
        local function yieldWork()
            work = work + 1
            if work >= 32 or (debugprofilestop and debugprofilestop() - started >= 1) then
                coroutine.yield()
            end
        end
        local worker = coroutine.create(function()
            sync:ComputeHistoryCatchupSnapshotDigest(snapshot, wireEpoch, killLimit, yieldWork)
        end)
        local function resume()
            work, started = 0, debugprofilestop and debugprofilestop() or 0
            local ok = coroutine.resume(worker)
            if ok and coroutine.status(worker) ~= "dead" then C_Timer.After(0, resume); return end
            if builds[killLimit] == state then builds[killLimit] = nil end
            ok = ok and CurrentCampaign() == campaignStart
            for _, done in ipairs(state.callbacks) do pcall(done, ok, snapshot) end
        end
        C_Timer.After(0, resume)
    end)
end

-- 1.7.5 : un voisin qui annonce moins que v7 (client d'avant 1.7.0) n'est plus
-- interroge : il acceptait encore les lignes forgees (indice de guilde puis LK sur
-- le canal) et les servait en pages. Mise a jour requise, aucun repli.
local function IsOldPagedPeer(net, name)
    local capability = net.GetPeerPagedProtocol and net:GetPeerPagedProtocol(name)
    return capability ~= nil and capability < 7
end

-- Voisins directs utilisables : ni nous-memes, ni penalises, ni annonces sans v7.
local function DirectCandidates()
    local net = Overlord.BetaNetwork
    if not net or not net.GetDirectPeers then return {} end
    local me = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
    local now, out = GetTime(), {}
    for _, name in ipairs(net:GetDirectPeers()) do
        if type(name) == "string" and name ~= ""
            and not (sync.ForeverIdentitiesMatch and sync:ForeverIdentitiesMatch(name, me))
            and (peerPenaltyUntil[name:lower()] or 0) <= now
            and not IsOldPagedPeer(net, name) then
            out[#out + 1] = name
        end
    end
    return out
end

-- Rotation entre voisins ; deux tours sur trois, un voisin de l'autre faction
-- (ami Battle.net) d'abord : il detient ce que notre faction ne voit pas en direct.
-- Chaque groupe a son propre compteur : un compteur commun au modulo 3 revenait
-- toujours sur les memes index et ignorait un voisin (ex. 3 voisins, 1 ennemi).
local function PickDirectPeer()
    local candidates = DirectCandidates()
    if #candidates == 0 then return nil end
    -- A fresh client starts its rotation at a random place: the candidates are sorted
    -- by name, and every new installation starting at 0 asked the same first peers
    -- (all of them busy, at a launch). Persisted, so the walk itself is unchanged.
    if OverlordDB and tonumber(OverlordDB.leaderboardHistoryCatchupTargetRotation) == nil then
        OverlordDB.leaderboardHistoryCatchupTargetRotation = math.random and math.random(0, 999999) or 0
    end
    local rotation = math.max(0, math.floor(tonumber(OverlordDB
        and OverlordDB.leaderboardHistoryCatchupTargetRotation) or 0))
    local enemyFaction = ENEMY_FACTION[Overlord.PlayerFaction]
    local enemies, allies = {}, {}
    for _, name in ipairs(candidates) do
        if enemyFaction and PeerFaction(name) == enemyFaction then
            enemies[#enemies + 1] = name
        else
            allies[#allies + 1] = name
        end
    end
    local sameRounds = math.floor(rotation / 3)
    local pool, index
    if #enemies == 0 then
        pool, index = allies, rotation
    elseif rotation % 3 == 2 and #allies > 0 then
        pool, index = allies, sameRounds
    else
        pool, index = enemies, rotation - sameRounds
    end
    return pool[(index % #pool) + 1]
end

local function RotatePeers()
    if OverlordDB then
        OverlordDB.leaderboardHistoryCatchupTargetRotation =
            math.max(0, math.floor(tonumber(OverlordDB.leaderboardHistoryCatchupTargetRotation) or 0)) + 1
    end
end

-- Historique avant-postes/forteresses : au plus une demande toutes les six heures.
local function MaybeRequestOutpostHistory(target, force)
    if not OverlordDB or not sync.RequestOutpostHistory then return false end
    local _, campaignId = CurrentCampaign()
    local ack = OverlordDB.leaderboardHistoryCatchupAck
    local historyAt = type(ack) == "table"
        and math.floor(tonumber(ack.campaignId) or 0) == campaignId
        and math.floor(tonumber(ack.historyAt) or 0) or 0
    if not force and historyAt > 0 and NowServer() - historyAt < HISTORY_ACK_SEC then return false end
    target = target or PickDirectPeer()
    if not target or not sync:RequestOutpostHistory(target) then return false end
    ack = type(ack) == "table" and ack.campaignId == campaignId and ack
        or { campaignId = campaignId, at = 0 }
    -- Short lease: the six hours only start once rows arrive from this peer
    -- (NoteOutpostHistoryDelivery). A silent or old (1.2.3) peer is retried soon.
    ack.historyAt = NowServer() - HISTORY_ACK_SEC + HISTORY_LEASE_SEC
    OverlordDB.leaderboardHistoryCatchupAck = ack
    sync._outpostHistoryRequest = { peer = target:lower(), at = GetTime(), campaignId = campaignId }
    NoteHr("step", "outpost history requested")
    return true
end

-- An accepted LO/LOC row from the peer we asked confirms the history round: for
-- six hours when the reply brought nothing new, for HISTORY_FRESH_RETRY_SEC when
-- it did (the next round fetches the rest of a long history).
function sync:NoteOutpostHistoryDelivery(sender, fresh)
    -- A live row relayed from the same player is not the answer we asked for.
    local context = Overlord.BetaNetwork and Overlord.BetaNetwork.context
    if context and (tonumber(context.hops) or 0) > 0 then return false end
    local request = self._outpostHistoryRequest
    if not request or type(sender) ~= "string" or sender:lower() ~= request.peer
        or not OverlordDB then return false end
    if GetTime() - request.at > 300 then
        self._outpostHistoryRequest = nil
        return false
    end
    local ack = OverlordDB.leaderboardHistoryCatchupAck
    if type(ack) ~= "table" or ack.campaignId ~= request.campaignId then return false end
    request.fresh = request.fresh or fresh == true
    ack.historyAt = request.fresh and (NowServer() - HISTORY_ACK_SEC + HISTORY_FRESH_RETRY_SEC) or NowServer()
    return true
end

local ScheduleAttempt

-- Un C_Timer.After possede par generation : jamais plus d'un reveil arme.
local function ArmNextHistoryCatchup(delay)
    sync._historyCatchupWakeGeneration =
        math.floor(tonumber(sync._historyCatchupWakeGeneration) or 0) + 1
    local generation = sync._historyCatchupWakeGeneration
    local jitter = math.random and math.random(0, PERIODIC_JITTER_SEC) or 0
    C_Timer.After(math.max(30, math.floor(tonumber(delay) or RECENT_ACK_SEC) + jitter), function()
        if not Overlord.Sync
            or Overlord.Sync._historyCatchupWakeGeneration ~= generation then return end
        if Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            ArmNextHistoryCatchup(EXHAUSTED_RETRY_SEC)
            return
        end
        Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true)
    end)
end

local function AttemptDelay(attempt)
    if attempt <= 1 then return 0 end
    if attempt == 2 then return 12 end
    if attempt == 3 then return 30 end
    return 60
end

local function FinishRound(pending, success, target)
    if sync._historyCatchupPending ~= pending then return end
    pending.terminal = true
    sync._historyCatchupPending = nil
    RotatePeers()
    if success and OverlordDB then
        local ack = OverlordDB.leaderboardHistoryCatchupAck
        ack = type(ack) == "table" and ack.campaignId == pending.campaignId and ack
            or { campaignId = pending.campaignId, historyAt = 0 }
        ack.at = NowServer()
        OverlordDB.leaderboardHistoryCatchupAck = ack
        OverlordDB.leaderboardRankFirstCompletedCampaignId = pending.campaignId
        NoteHr("completed", 1)
    end
    -- The pull records why it stopped (peer busy, no reply, ...): show it here too.
    local pageStats = sync._leaderboardPageStats
    local why = not success and type(pageStats) == "table" and type(pageStats.result) == "string"
        and pageStats.result:match("^interrupted (%b())") or ""
    NoteHr("result", success and "paged sweep received"
        or ("paged sweep interrupted" .. (why ~= "" and (" " .. why) or "")))
    -- Re-arm first: a failure in the history request must never stop the rounds.
    ArmNextHistoryCatchup(success and RECENT_ACK_SEC or EXHAUSTED_RETRY_SEC)
    pcall(MaybeRequestOutpostHistory, success and target or nil, pending.forceHistory)
end

ScheduleAttempt = function(pending, attempt)
    if sync._historyCatchupPending ~= pending or pending.terminal then return false end
    if attempt > MAX_ATTEMPTS then
        NoteHr("step", "all attempts used, next round in 2 min")
        FinishRound(pending, false)
        return false
    end
    pending.attemptToken = (pending.attemptToken or 0) + 1
    local token = pending.attemptToken
    local function attemptBody()
        if sync._historyCatchupPending ~= pending or pending.terminal
            or pending.attemptToken ~= token then return end
        local _, campaignId = CurrentCampaign()
        if campaignId ~= pending.campaignId then
            NoteHr("step", "campaign changed, restarting")
            pending.terminal = true
            sync._historyCatchupPending = nil
            sync:ScheduleLoginLeaderboardHistoryCatchUp(true)
            return
        end
        if Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            -- Not an attempt: nobody was asked. Look again shortly, same attempt (a
            -- fighter used to spend all four in a minute and wait for the next round).
            NoteHr("step", "waiting (combat or instance)")
            C_Timer.After(COMBAT_RECHECK_SEC, function()
                if sync._historyCatchupPending == pending and not pending.terminal
                    and pending.attemptToken == token then
                    local ok, err = pcall(attemptBody)
                    if not ok and sync._historyCatchupPending == pending and not pending.terminal then
                        NoteHr("step", "error: " .. tostring(err))
                        FinishRound(pending, false)
                    end
                end
            end)
            return
        end
        local target = PickDirectPeer()
        if not target then
            NoteHr("step", "no direct neighbour")
            ScheduleAttempt(pending, attempt + 1)
            return
        end
        local started, refusal = false, "local"
        if sync.StartCompletePagedLeaderboardCatchup then
            started, refusal = sync:StartCompletePagedLeaderboardCatchup(target, function(success, supported)
                if sync._historyCatchupPending ~= pending or pending.terminal then return end
                if success then
                    ForgivePeer(target)
                    FinishRound(pending, true, target)
                    return
                end
                -- A silent peer (no v6 answer) is set aside for ten minutes. A busy
                -- or interrupted one only yields briefly to the other neighbours; the
                -- next attempt with it resumes from the bucket checkpoint.
                PenalizePeer(target, not supported and PEER_PENALTY_SEC or BUSY_PEER_SEC)
                ScheduleAttempt(pending, attempt + 1)
            end)
        end
        if not started then
            -- A local refusal (this client busy building, in combat...) says
            -- nothing about the peer: no penalty.
            if refusal ~= "local" then PenalizePeer(target) end
            NoteHr("step", "request not sent to " .. tostring(target))
            ScheduleAttempt(pending, attempt + 1)
            return
        end
        NoteHr("requests", 1)
        NoteHr("target", target, PeerFaction(target) or "?")
        NoteHr("step", "paged ladder catch-up")
        C_Timer.After(ROUND_WATCHDOG_SEC, function()
            if sync._historyCatchupPending ~= pending or pending.terminal
                or pending.attemptToken ~= token then return end
            NoteHr("step", "round took too long, abandoned")
            -- Cancelling the pull ends the attempt through its callback; with no
            -- pull left to cancel, end the round here.
            if not (sync.CancelPagedLeaderboardCatchup and sync:CancelPagedLeaderboardCatchup()) then
                FinishRound(pending, false)
            end
        end)
    end
    C_Timer.After(AttemptDelay(attempt), function()
        -- An unexpected error must end the round, never leave it pending forever.
        local ok, err = pcall(attemptBody)
        if not ok and sync._historyCatchupPending == pending and not pending.terminal then
            NoteHr("step", "error: " .. tostring(err))
            FinishRound(pending, false)
        end
    end)
    return true
end

-- Point d'entree du rattrapage de classement (login, /ov sync, reveil periodique).
-- force : ignore le delai depuis le dernier tour reussi ; forceHistory : redemande
-- aussi l'historique avant-postes/forteresses a la fin du tour.
function sync:ScheduleLoginLeaderboardHistoryCatchUp(force, forceHistory)
    if not C_Timer or not C_Timer.After or not OverlordDB then return false end
    local campaignStart, campaignId = CurrentCampaign()
    if campaignStart <= 0 or campaignId <= 0 then return false end
    local age = NowServer() - campaignStart
    if age < CAMPAIGN_MIN_AGE_SEC then
        if self._historyCatchupNotBeforeCampaignId == campaignId and not force then
            return false
        end
        self._historyCatchupNotBeforeCampaignId = campaignId
        -- Spread over a minute: every client online at the weekly reset reached
        -- this line in the same second (a burst of requests and busy replies).
        local spread = math.random and math.random(0, 60) or 0
        C_Timer.After(math.max(1, CAMPAIGN_MIN_AGE_SEC - age + 5 + spread), function()
            if Overlord.Sync then
                Overlord.Sync._historyCatchupNotBeforeCampaignId = nil
                Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(force == true, forceHistory == true)
            end
        end)
        return true
    end
    local ack = OverlordDB.leaderboardHistoryCatchupAck
    local ackAt = type(ack) == "table" and math.floor(tonumber(ack.campaignId) or 0) == campaignId
        and math.floor(tonumber(ack.at) or 0) or 0
    local ackAge = ackAt > 0 and NowServer() - ackAt or RECENT_ACK_SEC
    if not force and ackAge >= 0 and ackAge < RECENT_ACK_SEC then
        ArmNextHistoryCatchup(RECENT_ACK_SEC - ackAge)
        return true
    end
    local existing = self._historyCatchupPending
    if existing and existing.campaignId == campaignId and not existing.terminal then
        if forceHistory then existing.forceHistory = true end
        NoteHr("step", "round already running")
        return false
    end
    -- Invalide le reveil periodique eventuel : un seul tour actif a la fois.
    self._historyCatchupWakeGeneration =
        math.floor(tonumber(self._historyCatchupWakeGeneration) or 0) + 1
    local pending = { campaignId = campaignId, terminal = false, forceHistory = forceHistory == true }
    self._historyCatchupPending = pending
    local initialDelay = Overlord.SavedVariablesLoadedAtLogin == false
        and EMPTY_SAVE_INITIAL_DELAY_SEC or INITIAL_DELAY_SEC
    C_Timer.After(initialDelay, function()
        ScheduleAttempt(pending, 1)
    end)
    return true
end

-- Forme courte pour le resume /ov sync. Aucune mutation.
function sync:GetHistoryCatchupSummary()
    local stats = self._historyCatchupStats
    local pending = self._historyCatchupPending
    return {
        running = pending ~= nil and not pending.terminal,
        step = stats and stats.step or nil,
        stepAge = stats and stats.stepAt and math.floor(GetTime() - stats.stepAt) or 0,
        rows = stats and stats.rows or 0,
    }
end

-- Ligne /ov network : les voisins directs du rattrapage, par faction, avec ceux
-- mis de cote (penalite) ou trop anciens (v5) et le tour de rotation. Repond a
-- "pourquoi pas mon ami Horde ?" sans deviner. Aucune mutation.
function sync:GetCatchupNeighbourDiagnostics()
    local net = Overlord.BetaNetwork
    if not net or not net.GetDirectPeers then return "Catch-up neighbours: relay inactive." end
    local me = self.GetPlayerFullName and self:GetPlayerFullName() or ""
    local now = GetTime()
    local enemyFaction = ENEMY_FACTION[Overlord.PlayerFaction]
    local enemies, allies, aside, old = {}, {}, {}, {}
    for _, name in ipairs(net:GetDirectPeers()) do
        if type(name) == "string" and name ~= ""
            and not (self.ForeverIdentitiesMatch and self:ForeverIdentitiesMatch(name, me)) then
            local penalty = (peerPenaltyUntil[name:lower()] or 0) - now
            if penalty > 0 then
                aside[#aside + 1] = string.format("%s %ds", name, math.floor(penalty))
            elseif IsOldPagedPeer(net, name) then
                old[#old + 1] = name
            elseif enemyFaction and PeerFaction(name) == enemyFaction then
                enemies[#enemies + 1] = name
            else
                allies[#allies + 1] = name
            end
        end
    end
    local rotation = math.max(0, math.floor(tonumber(OverlordDB
        and OverlordDB.leaderboardHistoryCatchupTargetRotation) or 0))
    local nextPool = (#enemies > 0 and (rotation % 3 ~= 2 or #allies == 0)) and "enemy" or "ally"
    local function list(t)
        if #t == 0 then return "none" end
        if #t <= 6 then return table.concat(t, ", ") end
        return table.concat(t, ", ", 1, 6) .. " +" .. (#t - 6)
    end
    return string.format("Catch-up neighbours: enemy %d (%s); ally %d (%s); set aside %d (%s); before 1.7 %d (%s); next round: %s.",
        #enemies, list(enemies), #allies, list(allies), #aside, list(aside), #old, list(old), nextPool)
end

-- Lignes /ov network : dernier voisin, resultat. Aucune mutation.
function sync:GetHistoryCatchupDiagnostics()
    local stats = self._historyCatchupStats
    if not stats then return { "Ladder rounds: none yet this session (v7, direct neighbours only)." } end
    local age = stats.targetAt and math.floor(GetTime() - stats.targetAt) or 0
    return {
        string.format("Ladder rounds: %d started, %d complete (v7, direct neighbours only).",
            stats.requests or 0, stats.completed or 0),
        string.format("Last peer: %s (%s), %ds ago: %s.",
            tostring(stats.target or "?"), tostring(stats.targetFaction or "?"), age,
            tostring(stats.result or "?")),
        string.format("Last step: %s, %ds ago. Round running: %s.",
            tostring(stats.step or "?"),
            stats.stepAt and math.floor(GetTime() - stats.stepAt) or 0,
            (self._historyCatchupPending and not self._historyCatchupPending.terminal) and "yes" or "no"),
    }
end
