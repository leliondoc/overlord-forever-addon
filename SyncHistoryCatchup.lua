-- Anti-entropie de classement, volontairement isolee de Sync.lua.
--
-- Ce protocole ne lit jamais le classement actif pour repondre. Il attend le
-- snapshot visible tranche de Leaderboard.lua, compare un digest borne, puis
-- envoie au besoin les seules lignes du snapshot par whisper direct. Aucun
-- transport partage et aucun ticker permanent.

local Overlord = _G.Overlord
if not Overlord or not Overlord.Sync then return end

local sync = Overlord.Sync
local PROTOCOL_VERSION = "3"
local COMPAT_PROTOCOL_VERSION = "2"
local LEGACY_PROTOCOL_VERSION = "1"
local MAX_SNAPSHOT_ROWS = 200
local MAX_SNAPSHOT_QUEUE = 340
local MAX_HISTORY_QUEUE = 340
local MAX_RACE_ROWS = 40
local HASH_MOD = 2147483647
-- Anti-entropie pair-a-pair : chaque echange est borne au snapshot visible deja
-- construit en tranches. Le pull initial est suivi d'un push de l'union si les
-- digests differaient, puis un nouveau pair est choisi periodiquement. Cela
-- remplace le digest global O(N) sans laisser les replicas dormir six heures.
local RECENT_ACK_SEC = 2 * 60
local HISTORY_ACK_SEC = 6 * 60 * 60
local PERIODIC_JITTER_SEC = 60
local EXHAUSTED_RETRY_SEC = 2 * 60
local PERIODIC_ROSTER_TTL_SEC = 15 * 60
local CAMPAIGN_MIN_AGE_SEC = 30 * 60
local INITIAL_DELAY_SEC = 24
-- Fragmentation and three relay hops share 1 KB/s. A full 340-row snapshot
-- can legitimately exceed the direct-whisper timeouts, even without loss.
local ACK_TIMEOUT_SEC = Overlord.CommunityModeEnabled == false and 600 or 120
local PUSH_ACK_TIMEOUT_SEC = Overlord.CommunityModeEnabled == false and 600 or 120
local SEND_INTERVAL_SEC = 0.12
local RESPONSE_WATCHDOG_SEC = Overlord.CommunityModeEnabled == false and 570 or 110
local MAX_ATTEMPTS = 4
local REQUESTER_COOLDOWN_SEC = 120
local COMPAT_PULL_COOLDOWN_SEC = 2 * 60
local COMPAT_PULL_GLOBAL_COOLDOWN_SEC = 20
local recentRequesters = {}
local recentRequesterCount = 0
local recentCompatPulls = {}
local recentCompatPullCount = 0
local lastCompatPullAt = -COMPAT_PULL_GLOBAL_COOLDOWN_SEC
local expectedHistoryPushes = {}
local expectedHistoryPushCount = 0
local snapshotWireCache = setmetatable({}, { __mode = "k" })

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
-- Blizzard ou sur l'epoch de repli calendrier. Les transports de classement
-- ordinaires tolerent deja cet ecart ; l'anti-entropie doit utiliser la meme
-- equivalence sans jamais relacher l'identite de campagne.
local function CampaignEpochsMatch(a, b)
    if Overlord.CampaignEpochsMatch then
        return Overlord:CampaignEpochsMatch(a, b)
    end
    return math.floor(tonumber(a) or 0) == math.floor(tonumber(b) or 0)
end

local function SenderKey(sender)
    local key = sync.GetCaptureContributorDedupKey
        and sync:GetCaptureContributorDedupKey(sender) or tostring(sender or ""):lower()
    return tostring(key or ""):lower()
end

-- Les clients 9.9.10-9.9.12 savent repondre a SR:F par tranches rotatives,
-- mais leur HR v2 ne connait que l'ancien top-150. Lorsqu'un de ces clients
-- nous contacte, demander une seule tranche complete en retour permet de
-- recuperer progressivement sa longue traine sans entretenir un faux HB v2.
-- Une reservation par pair et une garde globale bornent strictement ce pont
-- temporaire pendant la migration du parc vers le protocole v3.
local function ScheduleCompatFullPull(target)
    if not C_Timer or not C_Timer.After or not sync.GetSRPayload then return false end
    -- Un pair connu uniquement via un autre club territorial europeen ne doit
    -- jamais recevoir SR:F : cette reponse transporte aussi C/ZA/ZS/GK/outposts.
    -- Les bridges cross-pool restent exclusivement sur HR nonce `p`.
    if sync.IsEuropeanLeaderboardBridgeSender
        and sync:IsEuropeanLeaderboardBridgeSender(target)
        and (not sync.IsOnlineCommunitySender
            or not sync:IsOnlineCommunitySender(target))
        and (not sync.SenderIsInOurGroup
            or not sync:SenderIsInOurGroup(target)) then
        return false
    end
    local key = SenderKey(target)
    if key == "" then return false end
    local now = GetTime()
    local previous = recentCompatPulls[key]
    if previous and now - previous < COMPAT_PULL_COOLDOWN_SEC then return false end
    if now - lastCompatPullAt < COMPAT_PULL_GLOBAL_COOLDOWN_SEC then return false end
    if recentCompatPullCount >= 32 then
        wipe(recentCompatPulls)
        recentCompatPullCount = 0
    end
    if not previous then recentCompatPullCount = recentCompatPullCount + 1 end
    recentCompatPulls[key] = now
    lastCompatPullAt = now
    C_Timer.After(1.5, function()
        if not Overlord.Sync or Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            if recentCompatPulls[key] == now then
                recentCompatPulls[key] = nil
                recentCompatPullCount = math.max(0, recentCompatPullCount - 1)
            end
            return
        end
        local payload = sync:GetSRPayload("F")
        if payload and payload ~= "" then
            local sent = sync:SendWhisper("SR", payload, target)
            if sent and sync.ExpectDirectFullLeaderboardResponse then
                sync:ExpectDirectFullLeaderboardResponse(target)
            end
        end
    end)
    return true
end

local function PeriodicDelay(base)
    local jitter = math.random and math.random(0, PERIODIC_JITTER_SEC) or 0
    return math.max(30, math.floor(tonumber(base) or RECENT_ACK_SEC) + jitter)
end

-- Un C_Timer.After possede par generation : aucune boucle OnUpdate, aucun scan
-- synchrone et jamais plus d'un reveil anti-entropie arme par client.
local function ArmNextHistoryCatchup(delay)
    sync._historyCatchupWakeGeneration =
        math.floor(tonumber(sync._historyCatchupWakeGeneration) or 0) + 1
    local generation = sync._historyCatchupWakeGeneration
    C_Timer.After(PeriodicDelay(delay), function()
        if not Overlord.Sync
            or Overlord.Sync._historyCatchupWakeGeneration ~= generation then return end
        if Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            ArmNextHistoryCatchup(EXHAUSTED_RETRY_SEC)
            return
        end
        if Overlord.Sync.ScheduleLoginLeaderboardHistoryCatchUp then
            Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true)
        end
    end)
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
    local text = tostring(value or ""):gsub("[:\r\n]", "")
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
    return snapshot
end

local function AppendSnapshotNames(result, seen, order, values)
    if type(order) == "table" then
        for i = 1, math.min(#order, MAX_SNAPSHOT_ROWS) do
            local name = tostring(order[i] or "")
            if name ~= "" and not seen[name] and tonumber(values and values[name]) then
                result[#result + 1] = name
                seen[name] = true
            end
        end
    end
end

local function SnapshotNameLists(snapshot)
    local kills, captures, killSeen, captureSeen = {}, {}, {}, {}
    AppendSnapshotNames(kills, killSeen, snapshot and snapshot.killOrder,
        snapshot and snapshot.kills)
    AppendSnapshotNames(captures, captureSeen, snapshot and snapshot.captureOrder,
        snapshot and snapshot.captureCount)
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
    local guild = SafeWireField(info.guild, 96)
    if guild ~= "" and sync.IsValidGuildSyncToken
        and not sync:IsValidGuildSyncToken(guild) then guild = "" end
    local fields = {
        SafeWireField(name, 80),
        tostring(math.floor(tonumber(snapshot.kills and snapshot.kills[name]) or 0)),
        SafeWireField(info.class == "UNKNOWN" and "" or info.class, 24),
        SafeWireField(info.faction, 12),
        tostring(wireEpoch),
        SafeWireField(info.locale, 8),
        guild,
        tostring(math.floor(tonumber(info.guildAt) or 0)),
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

local function BuildSnapshotCapturePayload(snapshot, name, wireEpoch)
    if not ContributorCanRelay(name) then return nil end
    local info = type(snapshot.playerInfo) == "table" and snapshot.playerInfo[name] or nil
    info = type(info) == "table" and info or {}
    local zones, safeZones = snapshot.captures and snapshot.captures[name], {}
    if type(zones) == "table" then
        for i = 1, math.min(#zones, 32) do
            local zoneId = SafeWireField(zones[i], 32)
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
    while #safeZones > 0
        and #(prefix .. table.concat(safeZones, ",") .. suffix) > 250 do
        safeZones[#safeZones] = nil
    end
    local payload = prefix .. table.concat(safeZones, ",") .. suffix
    return #payload <= 250 and payload or nil
end

-- Seule source des pages LK/LC/LR du protocole HR. La file est plafonnee a
-- 340 paquets et ne trie, fusionne ni repare le classement actif.
function sync:BuildHistoryCatchupSnapshotQueue(snapshot, wireEpoch)
    local queue, raceSeen = {}, {}
    if type(snapshot) ~= "table" then return queue end
    local killNames, captureNames = SnapshotNameLists(snapshot)
    for i = 1, #killNames do
        local name = killNames[i]
        AppendPacket(queue, "LK", BuildSnapshotKillPayload(snapshot, name, wireEpoch))
    end
    for i = 1, #captureNames do
        local name = captureNames[i]
        AppendPacket(queue, "LC", BuildSnapshotCapturePayload(snapshot, name, wireEpoch))
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
    for i = 1, #killNames do appendRace(killNames[i]) end
    for i = 1, #captureNames do appendRace(captureNames[i]) end
    return queue
end

-- Page legacy SR:F construite uniquement depuis le snapshot visible borne.
-- Les premieres lignes restent prioritaires et la longue traine tourne entre
-- les demandes, comme l'ancien export actif, sans heal/merge/tri du bucket live.
function sync:BuildBoundedFullSrLeaderboardQueue(snapshot, wireEpoch, isLargeEvent)
    local source = self:BuildHistoryCatchupSnapshotQueue(snapshot, wireEpoch)
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
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(success)
        if settled then return end
        local campaignStart = CurrentCampaign()
        local snapshot = success and SnapshotForCampaign(campaignStart) or nil
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

function sync:ComputeHistoryCatchupSnapshotDigest(snapshot, wireEpoch)
    local cached = type(snapshot) == "table" and snapshotWireCache[snapshot] or nil
    if cached and cached.wireEpoch == wireEpoch then
        return cached.count, cached.hash, cached.queue
    end
    local queue = self:BuildHistoryCatchupSnapshotQueue(snapshot, wireEpoch)
    local hash = 0
    for i = 1, #queue do
        hash = (hash + HashPacket(queue[i].type, queue[i].data)) % HASH_MOD
    end
    if type(snapshot) == "table" then
        snapshotWireCache[snapshot] = {
            wireEpoch = wireEpoch,
            count = #queue,
            hash = hash,
            queue = queue,
        }
    end
    return #queue, hash, queue
end

local function BuildHistoricalQueue()
    local queue = {}
    if sync.AppendLeaderboardGuildKeepDailyProofsToSrQueue then
        pcall(sync.AppendLeaderboardGuildKeepDailyProofsToSrQueue, sync, queue)
    end
    if sync.AppendLeaderboardOutpostToSrQueue then
        pcall(sync.AppendLeaderboardOutpostToSrQueue, sync, queue)
    end
    if sync.AppendLeaderboardOutpostCountToSrQueue then
        pcall(sync.AppendLeaderboardOutpostCountToSrQueue, sync, queue, 0, true)
    end
    while #queue > MAX_HISTORY_QUEUE do queue[#queue] = nil end
    return queue
end

local function TerminalAckData(state)
    return table.concat({
        tostring(state.protocolVersion or PROTOCOL_VERSION),
        tostring(state.campaignId), state.nonce,
        state.status, tostring(state.digestCount), tostring(state.digestHash),
    }, ":")
end

local function ClearResponse(state)
    if sync._historyCatchupResponse ~= state then return end
    if state.ticker and state.ticker.Cancel then state.ticker:Cancel() end
    state.ticker = nil
    sync._historyCatchupResponse = nil
end

local function FinishResponse(state)
    if sync._historyCatchupResponse ~= state then return end
    -- A refused enqueue is not a delivered ACK. Retry on the next tick before
    -- releasing the response or authorizing the return push.
    if sync:SendWhisper("HA", TerminalAckData(state), state.target) ~= true then return end
    -- Si les ladders differaient, le demandeur va d'abord fusionner notre
    -- snapshot puis nous repousser cette union. N'accepter HB que pour ce nonce
    -- precis empeche un membre de la communaute d'ouvrir un flux arbitraire.
    if state.status == "D" and state.supportsPushPull then
        local targetKey = SenderKey(state.target)
        if targetKey ~= "" then
            local now = GetTime()
            for staleKey, row in pairs(expectedHistoryPushes) do
                if now > (tonumber(row.expiresAt) or 0) then
                    expectedHistoryPushes[staleKey] = nil
                    expectedHistoryPushCount = math.max(0, expectedHistoryPushCount - 1)
                end
            end
            if expectedHistoryPushCount >= 16 then
                wipe(expectedHistoryPushes)
                expectedHistoryPushCount = 0
            end
            local key = targetKey .. ":" .. tostring(state.nonce or "")
            if not expectedHistoryPushes[key] then
                expectedHistoryPushCount = expectedHistoryPushCount + 1
            end
            expectedHistoryPushes[key] = {
                targetKey = targetKey,
                campaignId = state.campaignId,
                nonce = state.nonce,
                expiresAt = now + PUSH_ACK_TIMEOUT_SEC,
            }
        end
    end
    local compatPullTarget = state.compatibilityPull and state.target or nil
    ClearResponse(state)
    if compatPullTarget then ScheduleCompatFullPull(compatPullTarget) end
end

local function SendResponseTick(state)
    if sync._historyCatchupResponse ~= state then return end
    local packet = state.queue and state.queue[state.index]
    if packet then
        if sync:SendWhisper(packet.type, packet.data, state.target) == true then
            state.index = state.index + 1
        end
        return
    end
    if state.phase == "ladder" then
        state.phase = state.includeHistory and "history" or "done"
        state.queue = state.includeHistory and BuildHistoricalQueue() or {}
        state.index = 1
        return
    end
    FinishResponse(state)
end

local function StartResponse(
    target, campaignId, nonce, status, count, hash, ladderQueue, includeHistory,
    protocolVersion, supportsPushPull, compatibilityPull)
    local state = {
        target = target,
        campaignId = campaignId,
        nonce = nonce,
        protocolVersion = protocolVersion,
        supportsPushPull = supportsPushPull == true,
        compatibilityPull = compatibilityPull == true,
        status = status,
        digestCount = count,
        digestHash = hash,
        includeHistory = includeHistory == true,
        phase = ladderQueue and "ladder" or (includeHistory and "history" or "done"),
        queue = ladderQueue or (includeHistory and BuildHistoricalQueue() or {}),
        index = 1,
    }
    sync._historyCatchupResponse = state
    state.ticker = C_Timer.NewTicker(SEND_INTERVAL_SEC, function()
        SendResponseTick(state)
    end)
    C_Timer.After(RESPONSE_WATCHDOG_SEC, function()
        ClearResponse(state)
    end)
end

local function BusyAck(target, campaignId, nonce, protocolVersion)
    sync:SendWhisper("HA", table.concat({
        tostring(protocolVersion or PROTOCOL_VERSION),
        tostring(campaignId), nonce, "B", "0", "0",
    }, ":"), target)
end

local function RequesterAllowed(sender, ladderOnly)
    if sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender) then return true end
    if sync.IsOnlineCommunitySender and sync:IsOnlineCommunitySender(sender) then return true end
    -- Un membre d'un club FR/DE/EU hors pool local n'est autorise que pour le
    -- nonce periodique `p`, qui exclut toutes les preuves territoriales.
    return ladderOnly == true and sync.IsEuropeanLeaderboardBridgeSender
        and sync:IsEuropeanLeaderboardBridgeSender(sender) or false
end

local function AcceptRequesterRate(senderKey)
    local now = GetTime()
    local previous = recentRequesters[senderKey]
    if previous and now - previous < REQUESTER_COOLDOWN_SEC then return false end
    if recentRequesterCount >= 32 then
        recentRequesters = {}
        recentRequesterCount = 0
    end
    if not previous then recentRequesterCount = recentRequesterCount + 1 end
    recentRequesters[senderKey] = now
    return true
end

function sync:OnHistoryCatchupRequest(payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") or type(payload) ~= "string"
        or not sender or sender == "" then return false end
    local version, campaignIdStr, startStr, nonce, countStr, hashStr =
        strsplit(":", payload, 6)
    local campaignId = math.floor(tonumber(campaignIdStr) or 0)
    local campaignStart = math.floor(tonumber(startStr) or 0)
    local remoteCount = math.floor(tonumber(countStr) or -1)
    local remoteHash = math.floor(tonumber(hashStr) or -1)
    local ladderOnly = type(nonce) == "string" and nonce:sub(1, 1) == "p"
    if not RequesterAllowed(sender, ladderOnly) then return false end
    local currentStart, currentId = CurrentCampaign()
    local supportsPushPull = version == PROTOCOL_VERSION
    local compatibilityV2 = version == COMPAT_PROTOCOL_VERSION
    if (not supportsPushPull and not compatibilityV2
            and version ~= LEGACY_PROTOCOL_VERSION) or campaignId <= 0
        or campaignId ~= currentId or not CampaignEpochsMatch(campaignStart, currentStart)
        or type(nonce) ~= "string" or not nonce:match("^[%w]+$")
        or #nonce < 6 or #nonce > 24
        or remoteCount < 0 or remoteCount > MAX_SNAPSHOT_QUEUE
        or remoteHash < 0 or remoteHash >= HASH_MOD then return false end
    if self._historyCatchupResponse then
        BusyAck(sender, campaignId, nonce, version)
        return false
    end
    local senderKey = SenderKey(sender)
    if senderKey == "" or not AcceptRequesterRate(senderKey) then
        BusyAck(sender, campaignId, nonce, version)
        return false
    end
    local lb = Overlord.Leaderboard
    if not lb or not lb.SnapshotCurrentCampaignBeforeReset then
        BusyAck(sender, campaignId, nonce, version)
        return false
    end
    -- Reserve le responder avant le callback asynchrone afin que deux HR recus
    -- dans la meme frame ne lancent pas deux snapshots/reponses.
    local reservation = { target = sender, campaignId = campaignId, nonce = nonce }
    self._historyCatchupResponse = reservation
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(success)
        if sync._historyCatchupResponse ~= reservation then return end
        sync._historyCatchupResponse = nil
        local startNow, idNow = CurrentCampaign()
        local snapshot = success and idNow == campaignId
            and CampaignEpochsMatch(startNow, campaignStart)
            and SnapshotForCampaign(startNow) or nil
        if not snapshot then
            BusyAck(sender, campaignId, nonce, version)
            return
        end
        local localCount, localHash, ladderQueue =
            sync:ComputeHistoryCatchupSnapshotDigest(snapshot, campaignStart)
        -- HR v2 avait deux scopes differents sous le meme numero : ancien
        -- top-150 global contre nouveau top-200/per-faction. Envoyer notre vue
        -- visible reste utile aux anciens receveurs, mais leur demander HB ne
        -- peut jamais produire le meme digest. HA:S reprend donc leur propre
        -- preuve et termine proprement ce pull unidirectionnel ; SR:F rotatif
        -- recupere ensuite leur tranche en retour, sans boucle bulk impossible.
        if compatibilityV2 then
            StartResponse(sender, campaignId, nonce, "S",
                remoteCount, remoteHash, ladderQueue, not ladderOnly,
                version, false, true)
            return
        end
        local same = localCount == remoteCount and localHash == remoteHash
        StartResponse(sender, campaignId, nonce, same and "S" or "D",
            localCount, localHash, same and nil or ladderQueue, not ladderOnly,
            version, supportsPushPull)
    end)
    if accepted ~= true then
        self._historyCatchupResponse = nil
        BusyAck(sender, campaignId, nonce, version)
        return false
    end
    C_Timer.After(RESPONSE_WATCHDOG_SEC, function()
        ClearResponse(reservation)
    end)
    return true
end

local function AttemptDelay(attempt)
    if attempt <= 1 then return 0 end
    if attempt == 2 then return 12 end
    if attempt == 3 then return 30 end
    return 60
end

local function RestartHistoryCatchupForCurrentCampaign(pending)
    if pending and sync._historyCatchupPending == pending then
        local push = pending.pushOutbound
        if push and push.ticker and push.ticker.Cancel then push.ticker:Cancel() end
        if push then push.ticker = nil end
        pending.terminal = true
        sync._historyCatchupPending = nil
    end
    if sync.ScheduleLoginLeaderboardHistoryCatchUp then
        sync:ScheduleLoginLeaderboardHistoryCatchUp(true, true)
    else
        ArmNextHistoryCatchup(EXHAUSTED_RETRY_SEC)
    end
end

local function ScheduleAttempt(generation, campaignId, attempt)
    if attempt > MAX_ATTEMPTS then
        local exhausted = sync._historyCatchupPending
        local compatTarget = nil
        if exhausted and exhausted.generation == generation
            and exhausted.campaignId == campaignId and not exhausted.terminal then
            compatTarget = exhausted.target
            sync._historyCatchupPending = nil
        end
        -- Un parc encore entierement v2 ignore HR v3. Apres les essais normaux,
        -- une seule page SR:F vers le dernier pair joignable evite qu'un client
        -- 9.9.13 neuf reste vide en attendant qu'un ancien l'interroge lui-meme.
        if compatTarget then ScheduleCompatFullPull(compatTarget) end
        ArmNextHistoryCatchup(EXHAUSTED_RETRY_SEC)
        return false
    end
    if not C_Timer or not C_Timer.After then return false end
    local owner = sync._historyCatchupPending
    if not owner or owner.generation ~= generation
        or owner.campaignId ~= campaignId or owner.terminal then return false end
    -- Un ACK tardif et le watchdog peuvent tous deux demander le retry de la
    -- meme tentative. Ce jeton invalide l'ancien callback : un seul HR pourra
    -- etre emis, meme dans cette course.
    owner.attemptTimerGeneration =
        math.floor(tonumber(owner.attemptTimerGeneration) or 0) + 1
    local attemptTimerGeneration = owner.attemptTimerGeneration
    C_Timer.After(AttemptDelay(attempt), function()
        local pending = sync._historyCatchupPending
        if not pending or pending.generation ~= generation
            or pending.campaignId ~= campaignId or pending.terminal
            or pending.attemptTimerGeneration ~= attemptTimerGeneration then return end
        local startNow, idNow = CurrentCampaign()
        if idNow ~= campaignId then
            RestartHistoryCatchupForCurrentCampaign(pending)
            return
        end
        if not OverlordDB then return end
        if Overlord.InstanceSuspended or IsInInstance()
            or (InCombatLockdown and InCombatLockdown()) then
            ScheduleAttempt(generation, campaignId, attempt + 1)
            return
        end
        local lb = Overlord.Leaderboard
        if not lb or not lb.SnapshotCurrentCampaignBeforeReset then
            ScheduleAttempt(generation, campaignId, attempt + 1)
            return
        end
        lb:SnapshotCurrentCampaignBeforeReset(function(success)
            local active = sync._historyCatchupPending
            if not active or active.generation ~= generation or active.terminal then return end
            local currentStart, currentId = CurrentCampaign()
            if currentId ~= campaignId or currentStart ~= startNow then
                RestartHistoryCatchupForCurrentCampaign(active)
                return
            end
            local snapshot = success and SnapshotForCampaign(currentStart) or nil
            local count, hash = sync:ComputeHistoryCatchupSnapshotDigest(snapshot, currentStart)
            -- Les rondes periodiques reutilisent le dernier roster complet. Un
            -- candidat stale qui ne repond plus force un vrai refresh au retry,
            -- au lieu de rescanner tous les clubs toutes les deux minutes.
            local periodicRound = active.ladderOnly == true
            local forceRosterRefresh = periodicRound and attempt > 1
            local rosterTtl = periodicRound and PERIODIC_ROSTER_TTL_SEC or 30
            -- Lorsqu'un compte est membre de plusieurs clubs FR/DE/EU, les
            -- rondes ladder-only choisissent d'abord un pair d'un AUTRE pool.
            -- Le roster territorial normal reste le fallback et n'est jamais
            -- elargi par cette voie.
            local online = periodicRound
                and sync.GetOnlineEuropeanLeaderboardBridgeMembers
                and sync:GetOnlineEuropeanLeaderboardBridgeMembers(
                    forceRosterRefresh, rosterTtl) or {}
            if #online == 0 then
                online = sync.GetOnlineCommunityMembers
                    and sync:GetOnlineCommunityMembers(forceRosterRefresh, rosterTtl) or {}
            end
            local total, target = #online, nil
            local identity = sync.GetPlayerFullName and sync:GetPlayerFullName() or ""
            if total > 0 then
                local seed = HashString(identity)
                local rotation = math.max(0, math.floor(tonumber(
                    OverlordDB.leaderboardHistoryCatchupTargetRotation) or 0))
                local startIndex = ((seed + rotation) % total) + 1
                for offset = 0, total - 1 do
                    local candidate = online[((startIndex + offset - 1) % total) + 1]
                    if candidate and candidate ~= ""
                        and (not sync.IsSenderLocalPlayer
                            or not sync:IsSenderLocalPlayer(candidate)) then
                        target = candidate
                        break
                    end
                end
            end
            if not target then
                ScheduleAttempt(generation, campaignId, attempt + 1)
                return
            end
            local nonceSeed = HashString(table.concat({
                tostring(identity or ""), tostring(NowServer()),
                tostring(generation), tostring(attempt), tostring(GetTime()),
            }, ":"))
            local nonce = (active.ladderOnly and "p" or "h")
                .. string.format("%x%x", NowServer() % 0x7fffffff, nonceSeed)
            local request = table.concat({
                PROTOCOL_VERSION, tostring(campaignId), tostring(currentStart),
                nonce, tostring(count), tostring(hash),
            }, ":")
            local targetKey = SenderKey(target)
            if targetKey == "" or sync:SendWhisper("HR", request, target) ~= true then
                ScheduleAttempt(generation, campaignId, attempt + 1)
                return
            end
            active.attempt = attempt
            active.target = target
            active.targetKey = targetKey
            active.nonce = nonce
            active.awaitingAck = true
            active.requestedCount = count
            active.requestedHash = hash
            active.deliveryCount = 0
            active.deliveryHash = 0
            OverlordDB.leaderboardHistoryCatchupTargetRotation =
                math.max(0, math.floor(tonumber(
                    OverlordDB.leaderboardHistoryCatchupTargetRotation) or 0)) + 1
            C_Timer.After(ACK_TIMEOUT_SEC, function()
                local expected = sync._historyCatchupPending
                if not expected or expected.generation ~= generation
                    or expected.nonce ~= nonce or expected.terminal
                    or not expected.awaitingAck then return end
                expected.awaitingAck = false
                ScheduleAttempt(generation, campaignId, attempt + 1)
            end)
        end)
    end)
    return true
end

local function ClearOutboundPush(pending)
    local push = pending and pending.pushOutbound
    if push and push.ticker and push.ticker.Cancel then push.ticker:Cancel() end
    if push then push.ticker = nil end
    if pending then
        pending.pushOutbound = nil
        pending.preparingPush = nil
        pending.awaitingPushAck = nil
    end
end

local function RetryHistoryCatchup(pending)
    if not pending or sync._historyCatchupPending ~= pending then return false end
    ClearOutboundPush(pending)
    pending.awaitingAck = false
    local nextAttempt = math.floor(tonumber(pending.attempt) or 1) + 1
    return ScheduleAttempt(pending.generation, pending.campaignId, nextAttempt)
end

local function CompleteHistoryCatchup(pending, count, hash)
    if not pending or sync._historyCatchupPending ~= pending then return false end
    local _, currentId = CurrentCampaign()
    if currentId ~= pending.campaignId then
        RestartHistoryCatchupForCurrentCampaign(pending)
        return false
    end
    ClearOutboundPush(pending)
    pending.awaitingAck = false
    pending.terminal = true
    if OverlordDB then
        local now = NowServer()
        local previous = OverlordDB.leaderboardHistoryCatchupAck
        local previousCampaign = type(previous) == "table"
            and math.floor(tonumber(previous.campaignId) or 0) or 0
        local historyAt = previousCampaign == pending.campaignId
            and math.floor(tonumber(previous.historyAt or previous.at) or 0) or 0
        if not pending.ladderOnly then historyAt = now end
        OverlordDB.leaderboardHistoryCatchupAck = {
            campaignId = pending.campaignId,
            at = now,
            historyAt = historyAt,
            count = math.floor(tonumber(count) or 0),
            hash = math.floor(tonumber(hash) or 0),
        }
    end
    sync._historyCatchupPending = nil
    ArmNextHistoryCatchup(RECENT_ACK_SEC)
    return true
end

local function ReturnCommitData(pending, push)
    return table.concat({
        PROTOCOL_VERSION, tostring(pending.campaignId), tostring(pending.nonce),
        tostring(push.count), tostring(push.hash),
    }, ":")
end

-- Deuxieme moitie du push-pull. Apres avoir importe le snapshot du repondeur,
-- le demandeur reconstruit en tranches son snapshot fusionne et le repousse au
-- meme pair. Les deux replicas terminent donc avec la meme union monotone.
local function StartReturnPush(pending, target)
    if not pending or sync._historyCatchupPending ~= pending
        or pending.preparingPush or pending.pushOutbound then return false end
    local lb = Overlord.Leaderboard
    if not lb or not lb.SnapshotCurrentCampaignBeforeReset then
        return RetryHistoryCatchup(pending)
    end
    pending.preparingPush = true
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(success)
        if sync._historyCatchupPending ~= pending or pending.terminal then return end
        pending.preparingPush = nil
        local campaignStart, campaignId = CurrentCampaign()
        if campaignId ~= pending.campaignId then
            RestartHistoryCatchupForCurrentCampaign(pending)
            return
        end
        if not success then
            RetryHistoryCatchup(pending)
            return
        end
        local snapshot = SnapshotForCampaign(campaignStart)
        local count, hash, queue =
            sync:ComputeHistoryCatchupSnapshotDigest(snapshot, campaignStart)
        local begin = table.concat({
            PROTOCOL_VERSION, tostring(campaignId), tostring(campaignStart),
            tostring(pending.nonce), tostring(count), tostring(hash),
        }, ":")
        if sync:SendWhisper("HB", begin, target) ~= true then
            RetryHistoryCatchup(pending)
            return
        end
        local push = {
            target = target,
            targetKey = SenderKey(target),
            queue = queue,
            index = 1,
            count = count,
            hash = hash,
        }
        pending.pushOutbound = push
        local pushDeadline = GetTime() + RESPONSE_WATCHDOG_SEC
        push.ticker = C_Timer.NewTicker(SEND_INTERVAL_SEC, function()
            if sync._historyCatchupPending ~= pending
                or pending.pushOutbound ~= push then
                if push.ticker and push.ticker.Cancel then push.ticker:Cancel() end
                return
            end
            if GetTime() > pushDeadline then
                RetryHistoryCatchup(pending)
                return
            end
            local packet = push.queue and push.queue[push.index]
            if packet then
                if sync:SendWhisper(packet.type, packet.data, push.target) ~= true then
                    return
                end
                push.index = push.index + 1
                return
            end
            if sync:SendWhisper("HC", ReturnCommitData(pending, push), push.target) ~= true then
                return
            end
            if push.ticker and push.ticker.Cancel then push.ticker:Cancel() end
            push.ticker = nil
            pending.awaitingPushAck = true
            C_Timer.After(PUSH_ACK_TIMEOUT_SEC, function()
                if sync._historyCatchupPending == pending
                    and pending.pushOutbound == push
                    and pending.awaitingPushAck and not pending.terminal then
                    RetryHistoryCatchup(pending)
                end
            end)
        end)
    end)
    if accepted ~= true then
        pending.preparingPush = nil
        return RetryHistoryCatchup(pending)
    end
    return true
end

function sync:OnHistoryPushBegin(payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") or type(payload) ~= "string" then return false end
    local version, campaignIdStr, startStr, nonce, countStr, hashStr =
        strsplit(":", payload, 6)
    local campaignId = math.floor(tonumber(campaignIdStr) or 0)
    local campaignStart = math.floor(tonumber(startStr) or 0)
    local count = math.floor(tonumber(countStr) or -1)
    local hash = math.floor(tonumber(hashStr) or -1)
    local currentStart, currentId = CurrentCampaign()
    local senderKey = SenderKey(sender)
    local expectedKey = senderKey .. ":" .. tostring(nonce or "")
    local expected = expectedHistoryPushes[expectedKey]
    local now = GetTime()
    for key, row in pairs(expectedHistoryPushes) do
        if now > (tonumber(row.expiresAt) or 0) then
            expectedHistoryPushes[key] = nil
            expectedHistoryPushCount = math.max(0, expectedHistoryPushCount - 1)
        end
    end
    if version ~= PROTOCOL_VERSION or campaignId <= 0
        or campaignId ~= currentId or not CampaignEpochsMatch(campaignStart, currentStart)
        or not expected or expected.targetKey ~= senderKey
        or expected.campaignId ~= campaignId or expected.nonce ~= nonce
        or now > (tonumber(expected.expiresAt) or 0)
        or count < 0 or count > MAX_SNAPSHOT_QUEUE
        or hash < 0 or hash >= HASH_MOD then return false end
    local active = self._historyCatchupPushInbound
    if active and (active.senderKey ~= senderKey or active.nonce ~= nonce) then
        BusyAck(sender, campaignId, nonce)
        return false
    end
    expectedHistoryPushes[expectedKey] = nil
    expectedHistoryPushCount = math.max(0, expectedHistoryPushCount - 1)
    local state = {
        sender = sender,
        senderKey = senderKey,
        campaignId = campaignId,
        campaignStart = campaignStart,
        nonce = nonce,
        expectedCount = count,
        expectedHash = hash,
        deliveryCount = 0,
        deliveryHash = 0,
    }
    self._historyCatchupPushInbound = state
    C_Timer.After(PUSH_ACK_TIMEOUT_SEC, function()
        if sync._historyCatchupPushInbound == state then
            sync._historyCatchupPushInbound = nil
        end
    end)
    return true
end

local function SendPushTerminal(target, campaignId, nonce, status, count, hash)
    sync:SendWhisper("HA", table.concat({
        PROTOCOL_VERSION, tostring(campaignId), tostring(nonce), tostring(status),
        tostring(math.floor(tonumber(count) or 0)),
        tostring(math.floor(tonumber(hash) or 0)),
    }, ":"), target)
end

function sync:OnHistoryPushCommit(payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") or type(payload) ~= "string" then return false end
    local version, campaignIdStr, nonce, countStr, hashStr = strsplit(":", payload, 5)
    local campaignId = math.floor(tonumber(campaignIdStr) or 0)
    local count = math.floor(tonumber(countStr) or -1)
    local hash = math.floor(tonumber(hashStr) or -1)
    local state = self._historyCatchupPushInbound
    local senderKey = SenderKey(sender)
    local _, currentCampaignId = CurrentCampaign()
    if state and state.senderKey == senderKey and state.campaignId == campaignId
        and state.nonce == nonce and state.committing then return false end
    if version ~= PROTOCOL_VERSION or not state
        or state.senderKey ~= senderKey or state.campaignId ~= campaignId
        or campaignId ~= currentCampaignId
        or state.nonce ~= nonce or count ~= state.expectedCount
        or hash ~= state.expectedHash
        or count ~= state.deliveryCount or hash ~= state.deliveryHash then
        -- Un commit correspondant mais incomplet/corrompu termine cette
        -- tentative immediatement. Sans cela, son verrou occupait le recepteur
        -- jusqu'au watchdog et retardait inutilement la prochaine reconciliation.
        if state and state.senderKey == senderKey
            and state.campaignId == campaignId and state.nonce == nonce then
            self._historyCatchupPushInbound = nil
        end
        if campaignId > 0 and nonce and nonce ~= "" then
            SendPushTerminal(sender, campaignId, nonce, "E", 0, 0)
        end
        return false
    end
    -- La preuve transport ne suffit pas : LK/LC/LR peuvent etre rejetes par les
    -- gardes locales. Recalculer le snapshot applique et ne certifier C que si
    -- son digest final est exactement celui annonce par le demandeur.
    state.committing = true
    local lb = Overlord.Leaderboard
    if not lb or not lb.SnapshotCurrentCampaignBeforeReset then
        self._historyCatchupPushInbound = nil
        SendPushTerminal(sender, campaignId, nonce, "E", 0, 0)
        return false
    end
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(success)
        if sync._historyCatchupPushInbound ~= state then return end
        local campaignStart, verifiedCampaignId = CurrentCampaign()
        local snapshot = success and verifiedCampaignId == campaignId
            and CampaignEpochsMatch(campaignStart, state.campaignStart)
            and SnapshotForCampaign(campaignStart) or nil
        local finalCount, finalHash = -1, -1
        if snapshot then
            finalCount, finalHash =
                sync:ComputeHistoryCatchupSnapshotDigest(snapshot, state.campaignStart)
        end
        sync._historyCatchupPushInbound = nil
        if finalCount == count and finalHash == hash then
            SendPushTerminal(sender, campaignId, nonce, "C", count, hash)
        else
            SendPushTerminal(sender, campaignId, nonce, "E", 0, 0)
        end
    end)
    if accepted ~= true then
        self._historyCatchupPushInbound = nil
        SendPushTerminal(sender, campaignId, nonce, "E", 0, 0)
        return false
    end
    return true
end

-- Preuve de livraison des deux moities de l'echange. Le digest est commutatif :
-- le rythme de dispatch local n'a aucune incidence, mais chaque paquet LK/LC/LR
-- doit avoir effectivement traverse le whisper avant HA:D puis HA:C.
function sync:NoteHistoryCatchupDelivery(msgType, payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") or type(payload) ~= "string"
        or (msgType ~= "LK" and msgType ~= "LC" and msgType ~= "LR") then
        return false
    end
    local senderKey = SenderKey(sender)
    local recorded = false
    local pending = self._historyCatchupPending
    if pending and pending.awaitingAck and not pending.terminal
        and senderKey == pending.targetKey
        and math.floor(tonumber(pending.deliveryCount) or 0) < MAX_SNAPSHOT_QUEUE then
        pending.deliveryCount = math.floor(tonumber(pending.deliveryCount) or 0) + 1
        pending.deliveryHash = (
            math.floor(tonumber(pending.deliveryHash) or 0) + HashPacket(msgType, payload)
        ) % HASH_MOD
        recorded = true
    end
    local inbound = self._historyCatchupPushInbound
    if inbound and not inbound.committing and inbound.senderKey == senderKey
        and math.floor(tonumber(inbound.deliveryCount) or 0) < MAX_SNAPSHOT_QUEUE then
        inbound.deliveryCount = math.floor(tonumber(inbound.deliveryCount) or 0) + 1
        inbound.deliveryHash = (
            math.floor(tonumber(inbound.deliveryHash) or 0) + HashPacket(msgType, payload)
        ) % HASH_MOD
        recorded = true
    end
    return recorded
end

-- Gate d'admission appele avant toute mutation LK/LC/LR. Le compteur et le
-- digest restent mis a jour par NoteHistoryCatchupDelivery seulement apres que
-- le handler a accepte la ligne ; cette fonction ne consomme donc aucun budget.
function sync:IsExpectedHistoryCatchupDelivery(msgType, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA")
        or (msgType ~= "LK" and msgType ~= "LC" and msgType ~= "LR") then
        return false
    end
    local senderKey = SenderKey(sender)
    if senderKey == "" then return false end
    local pending = self._historyCatchupPending
    if pending and pending.awaitingAck and not pending.terminal
        and senderKey == pending.targetKey
        and math.floor(tonumber(pending.deliveryCount) or 0) < MAX_SNAPSHOT_QUEUE then
        return true
    end
    local inbound = self._historyCatchupPushInbound
    if inbound and not inbound.committing and inbound.senderKey == senderKey then
        local delivered = math.floor(tonumber(inbound.deliveryCount) or 0)
        local expected = math.floor(tonumber(inbound.expectedCount) or 0)
        return delivered < expected and delivered < MAX_SNAPSHOT_QUEUE
    end
    return false
end

function sync:OnHistoryCatchupAck(payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") or type(payload) ~= "string" then return false end
    local version, campaignIdStr, nonce, status, countStr, hashStr =
        strsplit(":", payload, 6)
    local campaignId = math.floor(tonumber(campaignIdStr) or 0)
    local count = math.floor(tonumber(countStr) or -1)
    local hash = math.floor(tonumber(hashStr) or -1)
    local pending = self._historyCatchupPending
    if version ~= PROTOCOL_VERSION or not pending or pending.terminal
        or (channel ~= "WHISPER" and channel ~= "BETA") or campaignId ~= pending.campaignId
        or nonce ~= pending.nonce or SenderKey(sender) ~= pending.targetKey
        or count < 0 or count > MAX_SNAPSHOT_QUEUE
        or hash < 0 or hash >= HASH_MOD then return false end
    if status == "B" or status == "E" then
        RetryHistoryCatchup(pending)
        return true
    end
    if status == "C" then
        local push = pending.pushOutbound
        if not pending.awaitingPushAck or not push
            or count ~= push.count or hash ~= push.hash then return false end
        return CompleteHistoryCatchup(pending, count, hash)
    end
    if not pending.awaitingAck then return false end
    if status ~= "S" and status ~= "D" then return false end
    local proofComplete = status == "S"
        and count == math.floor(tonumber(pending.requestedCount) or -1)
        and hash == math.floor(tonumber(pending.requestedHash) or -1)
        or status == "D"
        and count == math.floor(tonumber(pending.deliveryCount) or -1)
        and hash == math.floor(tonumber(pending.deliveryHash) or -1)
    if not proofComplete then
        RetryHistoryCatchup(pending)
        return false
    end
    pending.awaitingAck = false
    local _, currentId = CurrentCampaign()
    if currentId ~= campaignId then
        RestartHistoryCatchupForCurrentCampaign(pending)
        return false
    end
    if not OverlordDB then return false end
    if status == "S" then
        return CompleteHistoryCatchup(pending, count, hash)
    end
    -- D prouve que tout le snapshot du repondeur est arrive. Ne persister le
    -- succes qu'apres HA:C, lorsque le repondeur aura recu l'union en retour.
    return StartReturnPush(pending, sender)
end

function sync:ScheduleLoginLeaderboardHistoryCatchUp(force, ladderOnly)
    if not C_Timer or not C_Timer.After or not OverlordDB then return false end
    local campaignStart, campaignId = CurrentCampaign()
    if campaignStart <= 0 or campaignId <= 0 then return false end
    local age = NowServer() - campaignStart
    if age < CAMPAIGN_MIN_AGE_SEC then
        if self._historyCatchupNotBeforeCampaignId == campaignId and not force then
            return false
        end
        self._historyCatchupNotBeforeCampaignId = campaignId
        C_Timer.After(math.max(1, CAMPAIGN_MIN_AGE_SEC - age + 5), function()
            if Overlord.Sync then
                Overlord.Sync._historyCatchupNotBeforeCampaignId = nil
                Overlord.Sync:ScheduleLoginLeaderboardHistoryCatchUp(
                    force == true, ladderOnly == true)
            end
        end)
        return true
    end
    local ack = OverlordDB.leaderboardHistoryCatchupAck
    local ackCampaign = type(ack) == "table"
        and math.floor(tonumber(ack.campaignId) or 0) or 0
    local ackAt = type(ack) == "table" and math.floor(tonumber(ack.at) or 0) or 0
    local ackAge = ackAt > 0 and NowServer() - ackAt or RECENT_ACK_SEC
    local historyAt = ackCampaign == campaignId and type(ack) == "table"
        and math.floor(tonumber(ack.historyAt or ack.at) or 0) or 0
    local historyAge = historyAt > 0 and NowServer() - historyAt or HISTORY_ACK_SEC
    -- Un /reload recent doit verifier le ladder sans retransmettre les preuves
    -- GK/Outpost. Leur propre rattrapage complet reste cadence a six heures.
    if not force and not ladderOnly and ackCampaign == campaignId
        and historyAge >= 0 and historyAge < HISTORY_ACK_SEC then
        ladderOnly = true
    end
    if not force and type(ack) == "table"
        and ackCampaign == campaignId
        and ackAge >= 0 and ackAge < RECENT_ACK_SEC then
        ArmNextHistoryCatchup(RECENT_ACK_SEC - ackAge)
        return true
    end
    local existing = self._historyCatchupPending
    if existing and existing.campaignId == campaignId and not existing.terminal then
        return false
    end
    -- Invalide le reveil periodique qui nous a eventuellement lances. Un seul
    -- handshake peut rester actif et son succes rearmera le prochain pair.
    self._historyCatchupWakeGeneration =
        math.floor(tonumber(self._historyCatchupWakeGeneration) or 0) + 1
    self._historyCatchupGeneration =
        math.floor(tonumber(self._historyCatchupGeneration) or 0) + 1
    local generation = self._historyCatchupGeneration
    self._historyCatchupPending = {
        generation = generation,
        campaignId = campaignId,
        ladderOnly = ladderOnly == true,
        terminal = false,
    }
    C_Timer.After(INITIAL_DELAY_SEC, function()
        ScheduleAttempt(generation, campaignId, 1)
    end)
    return true
end
