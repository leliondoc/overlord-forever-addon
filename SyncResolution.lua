-- SyncResolution.lua - Protocoles CR/CA et GR/GY (resolution active classes / guildes)
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

-- ========== Protocole CR / CA : resolution active des classes manquantes ==========
local CLASS_REQUEST_WINDOW = 8
local CLASS_REQUEST_COOLDOWN = 120
local CLASS_ANSWER_COOLDOWN = 30
local CLASS_REQUEST_MAX_NAMES = 6
local CLASS_REQUEST_MAX_PAYLOAD = 240
local CLASS_REQUEST_RESPONSE_JITTER_MAX = 2500
local CLASS_REQUEST_LARGE_EMIT_CHANCE = 0.15
local CLASS_ANSWER_LARGE_RESPOND_CHANCE = 0.25
-- Answers wanted per broadcast request. Every direct peer hears a channel request:
-- with a fixed 25 % chance, 500 hearers sent 125 whispers to one client (1.4.2).
local CLASS_ANSWER_TARGET_RESPONDERS = 3
local CLASS_REQUEST_MAX_PENDING = 12
local CLASS_REQUEST_MAX_BATCHES_LARGE = 2
local CLASS_HEAL_MAX_NAMES_LARGE = 8

local pendingClassRequests = {}
local pendingClassRequestsCount = 0
local outstandingClassRequests = {}
local classRequestCooldowns = {}
local classAnswerCooldowns = {}
local classRequestFlushScheduled = false
local classRequestLastPurge = 0

local pendingGuildRequests = {}
local pendingGuildRequestsCount = 0
-- Names this client asked a guild for (GR), until when a GY answer is accepted.
local outstandingGuildRequests = {}
-- Covers a GR held in the relay queue (TTL 120 s per leg) plus the answer jitter.
local GUILD_ANSWER_WINDOW = 300
local guildRequestCooldowns = {}
local guildAnswerCooldowns = {}
local guildRequestFlushScheduled = false
local guildRequestLastPurge = 0


local lastLbGuildRefreshFromGY = 0
local LB_GUILD_REFRESH_FROM_GY_INTERVAL = 1.5

-- Live hints (CA class, GY guild) answer our own request and only fill a missing
-- value. One peer alone cannot set it (2026-10-06): the first answer to arrive won,
-- and a modified client answered first. A value is applied once two distinct peers
-- gave it; each request already reaches about three answerers, so nothing is added
-- to the traffic. Only a live path: ranking pages still bring the same data to all.
local pendingHints = {}
local function ConcordantHint(kind, name, value, sender, expiresAt)
    local key = kind .. "\031" .. name
    local row = pendingHints[key]
    if not row or row.expiresAt < GetTime() then
        row = { expiresAt = tonumber(expiresAt) or GetTime(), votes = {}, voters = {}, n = 0 }
        pendingHints[key] = row
    end
    -- One identity, one vote: "Name-Realm" (whisper) and "Name" (relay) are the same
    -- player, and a voter that already named a value cannot fill the other slots.
    local voter = Overlord.Sync.GetCaptureContributorDedupKey
        and Overlord.Sync:GetCaptureContributorDedupKey(sender)
    if not voter then return false end
    voter = voter:lower()
    -- Exact value: two honest holders send the same stored spelling, and a second
    -- voter cannot choose the applied casing.
    local vote = value
    local first = row.votes[vote]
    if first and first ~= voter and not row.voters[voter] then
        pendingHints[key] = nil
        return true
    end
    if not first and not row.voters[voter] and row.n < 4 then
        row.votes[vote], row.voters[voter], row.n = voter, true, row.n + 1
    end
    return false
end
-- The answering peer itself, one hop away (a whisper, or a targeted relay dispatch).
local function IsDirectAnswer(sync, sender, channel)
    if channel ~= "WHISPER" and channel ~= "BETA" then return false end
    if sync.IsUnauthenticatedRelayOrigin and sync:IsUnauthenticatedRelayOrigin(sender) then return false end
    local net = Overlord.Relay
    if channel == "BETA" and not (net and net:IsDispatching(sender) and net:IsTargetedDispatch()) then
        return false
    end
    return true
end

local function classRequestsMaybePurge()
    local now = GetTime()
    if now - classRequestLastPurge < 60 then return end
    classRequestLastPurge = now
    for k, row in pairs(pendingHints) do
        if row.expiresAt < now then pendingHints[k] = nil end
    end
    for k, t in pairs(classRequestCooldowns) do
        if now - t > CLASS_REQUEST_COOLDOWN * 2 then classRequestCooldowns[k] = nil end
    end
    for k, t in pairs(classAnswerCooldowns) do
        if now - t > CLASS_ANSWER_COOLDOWN * 2 then classAnswerCooldowns[k] = nil end
    end
    for k, expiresAt in pairs(outstandingClassRequests) do
        if now >= expiresAt then outstandingClassRequests[k] = nil end
    end
end

local function guildRequestsMaybePurge()
    local now = GetTime()
    if now - guildRequestLastPurge < 60 then return end
    guildRequestLastPurge = now
    for k, t in pairs(guildRequestCooldowns) do
        if now - t > CLASS_REQUEST_COOLDOWN * 2 then guildRequestCooldowns[k] = nil end
    end
    for k, t in pairs(guildAnswerCooldowns) do
        if now - t > CLASS_ANSWER_COOLDOWN * 2 then guildAnswerCooldowns[k] = nil end
    end
    for k, expiresAt in pairs(outstandingGuildRequests) do
        if now >= expiresAt then outstandingGuildRequests[k] = nil end
    end
    for k, row in pairs(pendingHints) do
        if row.expiresAt < now then pendingHints[k] = nil end
    end
end

-- Live hints from other files (a third party's race): same agreement rule as GY/CA.
function Overlord.Sync:ConcordantLiveHint(kind, name, value, sender, expiresAt)
    guildRequestsMaybePurge()
    return ConcordantHint(kind, name, value, sender, expiresAt)
end

local function resolutionCanBroadcast()
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if Overlord.Sync and Overlord.Sync.GetChannelId and Overlord.Sync:GetChannelId() then return true end
    if IsInRaid() or IsInGroup() then return true end
    return false
end

-- GR/GY circulent sur le relais ; rien en instance.
local function guildResolutionCanBroadcast()
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    return Overlord.Relay ~= nil
end

local function MaybeLeaderboardGuildRefreshFromSync()
    local now = GetTime()
    if now - lastLbGuildRefreshFromGY < LB_GUILD_REFRESH_FROM_GY_INTERVAL then return end
    lastLbGuildRefreshFromGY = now
    if Overlord.LeaderboardUI and Overlord.LeaderboardUI.RefreshIfVisible then
        Overlord.LeaderboardUI:RefreshIfVisible()
    end
end

function Overlord.Sync:MaybeRequestMissingClass(playerName)
    if type(playerName) ~= "string" or playerName == "" then return end
    if not self:IsValidPlayerName(playerName) then return end
    playerName = self:NormalizeContributorFullName(playerName) or playerName
    if playerName == "" then return end
    if not resolutionCanBroadcast() then return end

    local lb = Overlord.Leaderboard
    if lb then
        local direct = lb.playerInfo and lb.playerInfo[playerName]
        local cls = direct and direct.class or ""
        if cls and cls ~= "" and cls ~= "UNKNOWN" then return end
        -- Une rafale LK invalide volontairement l'index. Ne jamais le reconstruire
        -- depuis le chemin de resolution par ligne ; si un index chaud existe,
        -- il peut encore fournir un alias connu en O(1).
        if lb.GetHotPlayerClass then
            cls = lb:GetHotPlayerClass(playerName)
            if cls and cls ~= "" and cls ~= "UNKNOWN" then return end
        end
    end

    local now = GetTime()
    local last = classRequestCooldowns[playerName]
    if last and (now - last) < CLASS_REQUEST_COOLDOWN then return end

    if pendingClassRequests[playerName] then return end
    -- A member of our own guild: the Blizzard roster already gives the class.
    if lb and lb.GetLocalGuildRosterClass and lb:GetLocalGuildRosterClass(playerName) then
        if lb.MaybeEnrichGuildForKillRow then lb:MaybeEnrichGuildForKillRow(playerName) end
        return
    end
    if pendingClassRequestsCount >= CLASS_REQUEST_MAX_PENDING then return end
    pendingClassRequests[playerName] = now
    pendingClassRequestsCount = pendingClassRequestsCount + 1
    self:ScheduleClassRequestFlush()
end

function Overlord.Sync:ScheduleClassRequestFlush()
    if classRequestFlushScheduled then return end
    classRequestFlushScheduled = true
    C_Timer.After(CLASS_REQUEST_WINDOW, function()
        classRequestFlushScheduled = false
        if Overlord.Sync then
            Overlord.Sync:FlushClassRequests()
        end
    end)
end

function Overlord.Sync:FlushClassRequests()
    classRequestsMaybePurge()

    if not resolutionCanBroadcast() then
        pendingClassRequests = {}
        pendingClassRequestsCount = 0
        return
    end

    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    if isLarge and math.random() > CLASS_REQUEST_LARGE_EMIT_CHANCE then
        pendingClassRequests = {}
        pendingClassRequestsCount = 0
        return
    end

    local now = GetTime()
    local names = {}
    local lb = Overlord.Leaderboard
    for name, _ in pairs(pendingClassRequests) do
        local stillMissing = true
        if lb and lb.GetHotPlayerClass then
            local cls = lb:GetHotPlayerClass(name)
            if cls and cls ~= "" and cls ~= "UNKNOWN" then stillMissing = false end
        end
        if stillMissing and lb and lb.GetLocalGuildRosterClass
            and lb:GetLocalGuildRosterClass(name) then
            stillMissing = false
            if lb.MaybeEnrichGuildForKillRow then lb:MaybeEnrichGuildForKillRow(name) end
        end
        if stillMissing then
            names[#names + 1] = name
        end
    end
    pendingClassRequests = {}
    pendingClassRequestsCount = 0
    if #names == 0 then return end

    local batchesEmitted = 0
    local maxBatches = isLarge and CLASS_REQUEST_MAX_BATCHES_LARGE or math.huge
    local batch, batchLen = {}, 0
    local function emit(b)
        if #b == 0 then return end
        if batchesEmitted >= maxBatches then return end
        local payload = table.concat(b, ",")
        if #payload > 0 and #payload <= CLASS_REQUEST_MAX_PAYLOAD then
            self:SendToGroup("CR", payload)
            self:SendToChannel("CR", payload)
            for _, n in ipairs(b) do
                classRequestCooldowns[n] = now
                outstandingClassRequests[n] = now + CLASS_ANSWER_COOLDOWN
            end
            batchesEmitted = batchesEmitted + 1
        end
    end
    for _, n in ipairs(names) do
        if batchesEmitted >= maxBatches then break end
        local add = (#batch == 0) and #n or (#n + 1)
        if #batch >= CLASS_REQUEST_MAX_NAMES or (batchLen + add) > CLASS_REQUEST_MAX_PAYLOAD then
            emit(batch)
            batch, batchLen = {}, 0
            if batchesEmitted >= maxBatches then break end
        end
        batch[#batch + 1] = n
        batchLen = batchLen + ((#batch == 1) and #n or (#n + 1))
    end
    emit(batch)
end

-- Probability of answering a broadcast request: about CLASS_ANSWER_TARGET_RESPONDERS
-- answers network-wide whatever the population (SR uses the same rule), never more
-- than the large-event share. A request addressed to this client alone is always
-- answered.
local function BroadcastAnswerChance(sync, channel)
    local net = Overlord.Relay
    if channel == "WHISPER" or (channel == "BETA" and net and net.IsTargetedDispatch
        and net:IsTargetedDispatch()) then return 1 end
    local population = net and net.CountDirectPeers and net:CountDirectPeers() or 0
    local chance = math.min(1, CLASS_ANSWER_TARGET_RESPONDERS / math.max(1, population))
    if sync.IsLargeEvent and sync:IsLargeEvent() then
        chance = math.min(chance, CLASS_ANSWER_LARGE_RESPOND_CHANCE)
    end
    return chance
end

function Overlord.Sync:OnReceiveClassRequest(payload, sender, channel)
    if type(payload) ~= "string" or payload == "" then return end
    -- Point to point (1.2.4): a request that crossed a relay is not answered.
    local net = Overlord.Relay
    if net and net.IsRelayedOrigin and net:IsRelayedOrigin(sender) then return end
    if #payload > CLASS_REQUEST_MAX_PAYLOAD then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if not sender or sender == "" then return end
    if self:IsSenderLocalPlayer(sender) then return end

    classRequestsMaybePurge()

    if math.random() > BroadcastAnswerChance(self, channel) then return end

    local lb = Overlord.Leaderboard
    if not lb or not lb.GetHotPlayerClass then return end

    local answers = {}
    local now = GetTime()
    local count = 0
    for name in string.gmatch(payload, "[^,]+") do
        count = count + 1
        if count > CLASS_REQUEST_MAX_NAMES then break end
        local trimmed = name:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" and self:IsValidPlayerName(trimmed) then
            trimmed = self:NormalizeContributorFullName(trimmed) or trimmed
            local answerKey = tostring(sender) .. ":" .. trimmed
            local lastAnswer = classAnswerCooldowns[answerKey]
            if not (lastAnswer and (now - lastAnswer) < CLASS_ANSWER_COOLDOWN) then
                local cls = lb:GetHotPlayerClass(trimmed)
                if cls and cls ~= "" and cls ~= "UNKNOWN" and self:IsValidCaptureClassToken(cls) then
                    local entry = trimmed .. "|" .. cls
                    local projected = (#answers == 0) and #entry or (#entry + 1)
                    local currentLen = 0
                    for _, e in ipairs(answers) do currentLen = currentLen + #e + 1 end
                    if currentLen + projected <= CLASS_REQUEST_MAX_PAYLOAD then
                        answers[#answers + 1] = entry
                        classAnswerCooldowns[answerKey] = now
                    end
                end
            end
        end
    end
    if #answers == 0 then return end

    local out = table.concat(answers, ",")
    local jitterMs = math.random(100, CLASS_REQUEST_RESPONSE_JITTER_MAX)
    C_Timer.After(jitterMs / 1000, function()
        if not Overlord.Sync then return end
        if Overlord.InstanceSuspended or IsInInstance() then return end
        Overlord.Sync:SendWhisper("CA", out, sender)
    end)
end

function Overlord.Sync:OnReceiveClassAnswer(payload, sender, channel)
    if not IsDirectAnswer(self, sender, channel) then return end
    if type(payload) ~= "string" or payload == "" then return end
    if #payload > CLASS_REQUEST_MAX_PAYLOAD then return end
    classRequestsMaybePurge()
    local lb = Overlord.Leaderboard
    if not lb or not lb.SetPlayerClassFromSync then return end

    local count = 0
    for entry in string.gmatch(payload, "[^,]+") do
        count = count + 1
        if count > CLASS_REQUEST_MAX_NAMES then break end
        local pipePos = entry:find("|", 1, true)
        if pipePos then
            local name = entry:sub(1, pipePos - 1):match("^%s*(.-)%s*$") or ""
            local cls = entry:sub(pipePos + 1):match("^%s*(.-)%s*$") or ""
            if name ~= "" and cls ~= "" and self:IsValidPlayerName(name)
                and self:IsValidCaptureClassToken(cls) then
                name = self:NormalizeContributorFullName(name) or name
                if name ~= "" and outstandingClassRequests[name]
                    and GetTime() <= outstandingClassRequests[name]
                    and (not self.IsKnownLeaderboardSubject or self:IsKnownLeaderboardSubject(name))
                    and ConcordantHint("C", name, cls, sender, outstandingClassRequests[name]) then
                    -- CA ne porte qu'une meta d'affichage et repond a une requete locale
                    -- explicite, confirmee par deux pairs (voir ConcordantHint).
                    lb:SetPlayerClassFromSync(name, cls)
                    outstandingClassRequests[name] = nil
                end
            end
        end
    end
end

-- ========== Protocole GR / GY : resolution active des guildes manquantes ==========
function Overlord.Sync:IsValidGuildSyncToken(guild)
    if type(guild) ~= "string" or guild == "" then return false end
    -- Invisible or format characters would make a second, look-alike guild name
    -- (no-break space, soft hyphen, zero-width and bidi marks, word joiners, BOM).
    -- Checked before the trim: a locale-aware %s may eat half of such a character.
    if guild:find("\194[\133\160\173]") or guild:find("\216\156") or guild:find("\225\160\142")
        or guild:find("\226\128[\128-\143\168-\175]") or guild:find("\226\129[\159-\175]")
        or guild:find("\227\128\128") or guild:find("\239\187\191") then return false end
    guild = guild:match("^%s*(.-)%s*$") or ""
    if guild == "" or #guild > 24 then return false end
    if guild:find("|", 1, true) or guild:find(",", 1, true) or guild:find(":", 1, true) then return false end
    if guild:find("[%c%%]") then return false end
    -- A lone lead or continuation byte is never a letter.
    if guild:find("[\192-\255]$") or guild:find("^[\128-\191]") then return false end
    return true
end

-- Compatibilite des chemins de verification gameplay. Le registre de guilde du ladder
-- converge, lui, via GI/K/LK horodates et les hints GY deterministes ci-dessous.
function Overlord.Sync:IsObservedPlayerGuild(playerName, claimedGuild)
    if not playerName or not claimedGuild or not self:IsValidGuildSyncToken(claimedGuild) then return false end
    local row = self.GetObservedPlayerIdentity and self:GetObservedPlayerIdentity(playerName)
    return row and row.guild ~= "" and Overlord:SafeStringEquals(row.guild, claimedGuild) or false
end

-- Token d'autorite GY : autorite = observation WoW locale du joueur ;
-- une meta relayee sans observation reste non autoritaire et exige trois sources exactes.
local GY_AUTH_TOKEN_PREFIX = "~"

local function buildGuildAuthToken(authBits)
    if not authBits or #authBits == 0 then return nil end
    if not authBits:find("1", 1, true) then return nil end -- aucune autorite : token inutile
    return GY_AUTH_TOKEN_PREFIX .. authBits
end

function Overlord.Sync:MaybeRequestMissingGuild(playerName)
    if type(playerName) ~= "string" or playerName == "" then return end
    if not self:IsValidPlayerName(playerName) then return end
    playerName = self:NormalizeContributorFullName(playerName) or playerName
    if playerName == "" then return end
    if not guildResolutionCanBroadcast() then return end

    -- Checks cheap d'abord (cooldown / pending / budget) avant la lecture O(1) :
    -- en event massif, un joueur a guilde inconnue ne declenche ainsi la resolution
    -- qu'une fois par fenetre de cooldown au lieu de la relancer a chaque LK/K recu.
    local now = GetTime()
    local last = guildRequestCooldowns[playerName]
    if last and (now - last) < CLASS_REQUEST_COOLDOWN then return end
    if pendingGuildRequests[playerName] then return end
    if pendingGuildRequestsCount >= CLASS_REQUEST_MAX_PENDING then return end

    local lb = Overlord.Leaderboard
    if lb then
        local direct = lb.playerInfo and lb.playerInfo[playerName]
        -- Seul un depart confirme par le personnage bloque le rattrapage.
        -- Les anciens tombstones de relais pouvaient etre de fausses absences.
        if direct and direct.guildAuth == true then return end
        if lb.GetHotPlayerGuildState then
            local _, _, authoritative = lb:GetHotPlayerGuildState(playerName)
            if authoritative then return end
        end
    end

    pendingGuildRequests[playerName] = now
    pendingGuildRequestsCount = pendingGuildRequestsCount + 1
    self:ScheduleGuildRequestFlush()
end

function Overlord.Sync:ScheduleGuildRequestFlush()
    if guildRequestFlushScheduled then return end
    guildRequestFlushScheduled = true
    C_Timer.After(CLASS_REQUEST_WINDOW, function()
        guildRequestFlushScheduled = false
        if Overlord.Sync then
            Overlord.Sync:FlushGuildRequests()
        end
    end)
end

function Overlord.Sync:FlushGuildRequests()
    guildRequestsMaybePurge()

    if not guildResolutionCanBroadcast() then
        pendingGuildRequests = {}
        pendingGuildRequestsCount = 0
        return
    end

    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    if isLarge and math.random() > CLASS_REQUEST_LARGE_EMIT_CHANCE then
        pendingGuildRequests = {}
        pendingGuildRequestsCount = 0
        return
    end

    local now = GetTime()
    local names = {}
    local lb = Overlord.Leaderboard
    for name, _ in pairs(pendingGuildRequests) do
        local stillMissing = true
        local direct = lb and lb.playerInfo and lb.playerInfo[name]
        if direct and direct.guildAuth == true then
            stillMissing = false
        end
        if lb and lb.GetHotPlayerGuildState then
            local _, _, authoritative = lb:GetHotPlayerGuildState(name)
            if authoritative then stillMissing = false end
        end
        -- A member of our own guild: the Blizzard roster already names the guild.
        if stillMissing and lb and lb.IsLocalGuildRosterMember
            and lb:IsLocalGuildRosterMember(name) then
            stillMissing = false
            if lb.MaybeEnrichGuildForKillRow then lb:MaybeEnrichGuildForKillRow(name) end
        end
        if stillMissing then
            names[#names + 1] = name
        end
    end
    pendingGuildRequests = {}
    pendingGuildRequestsCount = 0
    if #names == 0 then return end

    local batchesEmitted = 0
    local maxBatches = isLarge and CLASS_REQUEST_MAX_BATCHES_LARGE or math.huge
    local batch, batchLen = {}, 0
    local function emit(b)
        if #b == 0 then return end
        if batchesEmitted >= maxBatches then return end
        local payload = table.concat(b, ",")
        if #payload > 0 and #payload <= CLASS_REQUEST_MAX_PAYLOAD then
            if self.SendToNamedPeers then
                self:SendToNamedPeers("GR", payload, b, nil, nil, true)
            end
            local needsPeerHints = false
            for _, n in ipairs(b) do
                local info = lb and lb.playerInfo and lb.playerInfo[n]
                if not info or not info.guild or info.guild == "" then needsPeerHints = true; break end
            end
            -- Une guilde deja renseignee se verifie aupres du proprietaire. Un
            -- broadcast de toutes les lignes non verifiees saturerait le rattrapage.
            if needsPeerHints and self.BroadcastToRelay then
                self:BroadcastToRelay("GR", payload)
            end
            for _, n in ipairs(b) do
                guildRequestCooldowns[n] = now
                outstandingGuildRequests[n] = now + GUILD_ANSWER_WINDOW
            end
            batchesEmitted = batchesEmitted + 1
        end
    end
    for _, n in ipairs(names) do
        if batchesEmitted >= maxBatches then break end
        local add = (#batch == 0) and #n or (#n + 1)
        if #batch >= CLASS_REQUEST_MAX_NAMES or (batchLen + add) > CLASS_REQUEST_MAX_PAYLOAD then
            emit(batch)
            batch, batchLen = {}, 0
            if batchesEmitted >= maxBatches then break end
        end
        batch[#batch + 1] = n
        batchLen = batchLen + ((#batch == 1) and #n or (#n + 1))
    end
    emit(batch)
end

function Overlord.Sync:OnReceiveGuildRequest(payload, sender, channel)
    if (channel ~= "WHISPER" and channel ~= "BETA") then return end
    -- Point to point (1.2.4): a request that crossed a relay is not answered.
    local net = channel == "BETA" and Overlord.Relay
    if net and (tonumber(net.context and net.context.hops) or 0) > 0 then return end
    if type(payload) ~= "string" or payload == "" then return end
    if #payload > CLASS_REQUEST_MAX_PAYLOAD then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if not sender or sender == "" then return end
    if self:IsSenderLocalPlayer(sender) then return end

    guildRequestsMaybePurge()

    if math.random() > BroadcastAnswerChance(self, channel) then return end

    local lb = Overlord.Leaderboard
    if not lb or not lb.GetHotPlayerGuildState then return end

    local answers = {}
    local answersAuth = {}
    local now = GetTime()
    local count = 0
    -- Marge reservee pour le token d'autorite final (prefixe + 1 bit/entree + virgule).
    local maxPayload = CLASS_REQUEST_MAX_PAYLOAD - (CLASS_REQUEST_MAX_NAMES + 2)
    for name in string.gmatch(payload, "[^,]+") do
        count = count + 1
        if count > CLASS_REQUEST_MAX_NAMES then break end
        local trimmed = name:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" and self:IsValidPlayerName(trimmed) then
            trimmed = self:NormalizeContributorFullName(trimmed) or trimmed
            local lastAnswer = guildAnswerCooldowns[trimmed]
            if not (lastAnswer and (now - lastAnswer) < CLASS_ANSWER_COOLDOWN) then
                if self:IsSenderLocalPlayer(trimmed) and self.BuildLocalGuildIdentityPayload then
                    local identityPayload = self:BuildLocalGuildIdentityPayload()
                    if identityPayload then
                        guildAnswerCooldowns[trimmed] = now
                        C_Timer.After(math.random(100, CLASS_REQUEST_RESPONSE_JITTER_MAX) / 1000, function()
                            if Overlord.Sync and not Overlord.InstanceSuspended then
                                Overlord.Sync:SendWhisper("GI", identityPayload, sender)
                            end
                        end)
                    end
                else
                    local guild, _, guildAuth = lb:GetHotPlayerGuildState(trimmed)
                    -- Answer only with a confirmed register (the player's own, or one
                    -- received in a page), never with a hint we got the same way.
                    local held = lb.playerInfo and lb.playerInfo[trimmed]
                    local strong = guildAuth or (type(held) == "table" and held.guildReplica == true)
                    if strong and guild and guild ~= "" and self:IsValidGuildSyncToken(guild) then
                        local entry = trimmed .. "|" .. guild
                        local projected = (#answers == 0) and #entry or (#entry + 1)
                        local currentLen = 0
                        for _, e in ipairs(answers) do currentLen = currentLen + #e + 1 end
                        if currentLen + projected <= maxPayload then
                            answers[#answers + 1] = entry
                            answersAuth[#answers] = guildAuth and "1" or "0"
                            guildAnswerCooldowns[trimmed] = now
                        end
                    end
                end
            end
        end
    end
    if #answers == 0 then return end

    local out = table.concat(answers, ",")
    local authToken = buildGuildAuthToken(table.concat(answersAuth))
    if authToken then out = out .. "," .. authToken end
    local jitterMs = math.random(100, CLASS_REQUEST_RESPONSE_JITTER_MAX)
    C_Timer.After(jitterMs / 1000, function()
        if not Overlord.Sync then return end
        if Overlord.InstanceSuspended or IsInInstance() then return end
        Overlord.Sync:SendWhisper("GY", out, sender)
    end)
end

function Overlord.Sync:OnReceiveGuildAnswer(payload, sender, channel)
    -- GY is only ever the whispered answer to our own GR (2026-10-06). The channel and
    -- group copies had no honest sender left (the SR guild metadata appender is gone)
    -- and let anyone create a ladder entry for any name: one GY on the channel,
    -- then one LK, put "EMPIRE SUCKS" on every ranking. A relayed origin is a name
    -- written by a gateway, never the answering peer.
    if not IsDirectAnswer(self, sender, channel) then return end
    if type(payload) ~= "string" or payload == "" then return end
    if #payload > CLASS_REQUEST_MAX_PAYLOAD then return end
    guildRequestsMaybePurge()
    local lb = Overlord.Leaderboard
    if not lb or not lb.SetPlayerGuild then return end

    -- 1er passage : collecter les entrees name|guild (dans l'ordre) et le token d'autorite final
    -- "~<bits>" (sans "|", donc ignore par les anciens clients). bit i = autorite de l'entree i.
    local parsed = {}
    local authBits
    for token in string.gmatch(payload, "[^,]+") do
        local pipePos = token:find("|", 1, true)
        if pipePos then
            if #parsed < CLASS_REQUEST_MAX_NAMES then
                parsed[#parsed + 1] = {
                    name = token:sub(1, pipePos - 1):match("^%s*(.-)%s*$") or "",
                    guild = token:sub(pipePos + 1):match("^%s*(.-)%s*$") or "",
                }
            end
        elseif not authBits then
            authBits = token:match("^~([01]+)$")
        end
    end

    local updated = false
    for i, e in ipairs(parsed) do
        local name, guild = e.name, e.guild
        local clearAt = guild and guild:match("^~0@(%d+)$")
        if name ~= "" and self:IsValidPlayerName(name)
            and ((clearAt and tonumber(clearAt))
                or (guild ~= "" and self:IsValidGuildSyncToken(guild))) then
            name = self:NormalizeContributorFullName(name) or name
            if name ~= "" then
                if clearAt then
                    local clearTs = math.floor(tonumber(clearAt) or 0)
                    local owned = self.KillSyncSenderOwnsPlayer
                        and self:KillSyncSenderOwnsPlayer(sender, name)
                    if owned and clearTs > 0 and lb.ClearPlayerGuild then
                        if lb:ClearPlayerGuild(name, true, true, clearTs) then updated = true end
                    end
                else
                    -- GY est un hint : remplir une absence non confirmee uniquement,
                    -- pour un nom que nous avons demande et qui a deja un score ici.
                    local asked = outstandingGuildRequests[name]
                    if asked and GetTime() < asked
                        and self.IsKnownLeaderboardSubject and self:IsKnownLeaderboardSubject(name)
                        and lb.ShouldAcceptSyncedGuild
                        and lb:ShouldAcceptSyncedGuild(name, guild, 0)
                        and ConcordantHint("G", name, guild, sender, asked) then
                        lb:SetPlayerGuild(name, guild, true, false, 0, false)
                        updated = true
                    end
                end
            end
        end
    end
    if updated then
        MaybeLeaderboardGuildRefreshFromSync()
    end
end

local IDENTITY_HEAL_SCAN_ROWS_PER_SLICE = 64
local IDENTITY_HEAL_SCAN_MS_PER_SLICE = 1.25

-- Les plafonds de requetes bornaient le trafic, pas le scan : si toutes les
-- metadonnees etaient deja connues, une entree de front parcourait le classement
-- entier dans une seule frame. Cette continuation garde l'ordre des sources et les
-- memes criteres, mais distribue la recherche. Une nouvelle invocation annule la
-- precedente afin que deux entrees rapides ne doublent jamais le travail.
local function StartMissingIdentityHeal(sync, tokenField, sources, maxAsked,
    canBroadcast, isMissing, requestMissing)
    local token = (tonumber(sync[tokenField]) or 0) + 1
    sync[tokenField] = token
    local sourceIndex, cursor, asked = 1, nil, 0
    local runSlice
    runSlice = function()
        if sync[tokenField] ~= token or Overlord.InActiveFront == false
            or not canBroadcast() then return end
        local processed = 0
        local started = debugprofilestop and debugprofilestop() or nil
        while sourceIndex <= #sources and asked < maxAsked do
            local source = sources[sourceIndex]
            -- Une fusion dedup peut supprimer la cle courante entre deux frames.
            -- `next(source, cursor)` serait alors invalide en Lua 5.1. Ce heal est
            -- opportuniste : l'abandonner est plus sur qu'un restart O(N), et la
            -- prochaine entree de front le rejouera depuis la table canonique.
            if cursor ~= nil and source[cursor] == nil then return end
            local name, count = next(source, cursor)
            if name == nil then
                sourceIndex, cursor = sourceIndex + 1, nil
            else
                cursor = name
                processed = processed + 1
                if (tonumber(count) or 0) > 0 and name ~= "" and isMissing(name) then
                    requestMissing(sync, name)
                    asked = asked + 1
                end
                local elapsed = started and (debugprofilestop() - started) or 0
                if processed >= IDENTITY_HEAL_SCAN_ROWS_PER_SLICE
                    or elapsed >= IDENTITY_HEAL_SCAN_MS_PER_SLICE then
                    C_Timer.After(0, runSlice)
                    return
                end
            end
        end
    end
    runSlice()
end

function Overlord.Sync:HealRequestMissingGuildsFromDB()
    if not guildResolutionCanBroadcast() then return end
    local lb = Overlord.Leaderboard
    if not lb or not lb.GetHotPlayerGuildState then return end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local maxAsked = isLarge and CLASS_HEAL_MAX_NAMES_LARGE or 24
    StartMissingIdentityHeal(self, "_missingGuildHealToken", { lb.kills or {} }, maxAsked,
        guildResolutionCanBroadcast,
        function(name)
            local _, _, authoritative = lb:GetHotPlayerGuildState(name)
            return not authoritative
        end,
        Overlord.Sync.MaybeRequestMissingGuild)
end

function Overlord.Sync:HealRequestMissingClassesFromDB()
    if not resolutionCanBroadcast() then return end
    local lb = Overlord.Leaderboard
    if not lb or not lb.GetHotPlayerClass then return end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local maxAsked = isLarge and CLASS_HEAL_MAX_NAMES_LARGE or 24
    StartMissingIdentityHeal(self, "_missingClassHealToken",
        { lb.captureCount or {}, lb.kills or {} }, maxAsked, resolutionCanBroadcast,
        function(name)
            local cls = lb:GetHotPlayerClass(name)
            return not cls or cls == "" or cls == "UNKNOWN"
        end,
        Overlord.Sync.MaybeRequestMissingClass)
end

-- PLAYER_GUILD_UPDATE est la voie principale. Ce battement tres lent et desynchronise
-- ne sert que de filet apres une longue session : il ne doit jamais former une vague
-- M clients x 12/20 whispers lors d'un reload collectif.
local GI_IDENTITY_INTERVAL = 900
local GI_IDENTITY_INITIAL_DELAY = 25
local GI_IDENTITY_MIN_GAP = 600
local lastGuildIdentityBroadcastAt = 0
local guildIdentityHeartbeatActive = false

function Overlord.Sync:BuildLocalGuildIdentityPayload()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local lb = Overlord.Leaderboard
    if not lb or not Overlord.SafeGetGuildInfo then return end
    local identity = Overlord:GetLocalGuildIdentity()
    if identity == nil then return end
    local guild = identity:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or ""
    if #guild > 24 then return end
    if guild ~= "" and (not self.IsValidGuildSyncToken or not self:IsValidGuildSyncToken(guild)) then return end
    local playerName = self.GetPlayerFullName and self:GetPlayerFullName()
    if not playerName or playerName == "" then return end
    if not self:AcceptSyncedContributorName(playerName) then return end
    local startTs = tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0
    local epoch = (startTs > 0 and Overlord.TimestampToCampaignId)
        and Overlord:TimestampToCampaignId(startTs) or 0
    if epoch <= 0 then return end
    local guildAt = (GetServerTime and GetServerTime()) or time()
    if lb.GetPlayerInfo then
        local info = lb:GetPlayerInfo(playerName)
        local storedGuild = info and (info.guild or "") or ""
        local storedAt = info and math.floor(tonumber(info.guildAt) or 0) or 0
        -- guildAt date un CHANGEMENT d'appartenance, pas chaque heartbeat. Le conserver
        -- stabilise les tombstones et evite des digests differents selon les paquets manques.
        if storedGuild == guild and storedAt > 0 then
            guildAt = storedAt
        end
    end
    if lb.MergeOwnedGuildMetadata then
        -- Un seul merge direct O(1), y compris pour le tombstone sans guilde.
        lb:MergeOwnedGuildMetadata(playerName, guild, guildAt)
    end
    local payload = string.format("%s:%s:%s:%s", playerName, guild, epoch, math.floor(guildAt))
    if #payload > CLASS_REQUEST_MAX_PAYLOAD then return end
    return payload
end

function Overlord.Sync:BroadcastGuildIdentity(force)
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if not resolutionCanBroadcast() then return end
    local now = GetTime()
    if not force and lastGuildIdentityBroadcastAt > 0
        and (now - lastGuildIdentityBroadcastAt) < GI_IDENTITY_MIN_GAP then return end
    local payload = self:BuildLocalGuildIdentityPayload()
    if not payload then return end
    lastGuildIdentityBroadcastAt = now
    if self.Send then self:Send("GI", payload) end
    self:BroadcastToRelay("GI", payload)
end

-- Format GI : name:guild:epoch:guildAt (autoritaire, emis par le proprietaire uniquement).
function Overlord.Sync:OnReceiveGuildIdentity(payload, sender, channel)
    if not payload or payload == "" then return end
    if Overlord.InstanceSuspended then return end
    if (channel ~= "WHISPER" and channel ~= "BETA") and channel ~= "CHANNEL" and channel ~= "RAID" and channel ~= "PARTY" then
        return
    end
    local rawName, guildTag, epochStr, guildAtStr = strsplit(":", payload, 4)
    if not rawName or rawName == "" or guildTag == nil then return end
    local remoteEpoch = tonumber(epochStr)
    local startTs = tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0
    local curEpoch = (startTs > 0 and Overlord.TimestampToCampaignId)
        and Overlord:TimestampToCampaignId(startTs) or 0
    if not remoteEpoch or remoteEpoch ~= curEpoch then return end
    local playerName = self:NormalizeContributorFullName(rawName)
    if not playerName or playerName == "" then return end
    if not self:AcceptSyncedContributorName(playerName) then return end
    if guildTag ~= "" and not self:IsValidGuildSyncToken(guildTag) then return end
    local isBNetRelay = type(sender) == "string" and sender:sub(1, 5) == "BNet-"
    if isBNetRelay then return end
    local owned = sender and sender ~= "" and self.KillSyncSenderOwnsPlayer
        and self:KillSyncSenderOwnsPlayer(sender, playerName)
    if not owned then return end
    local lb = Overlord.Leaderboard
    if lb and lb.MergeOwnedGuildMetadata then
        -- sender==playerName est deja prouve ci-dessus : merge direct, autoritaire
        -- et borne, sans reconstruction de l'index dedup du classement.
        lb:MergeOwnedGuildMetadata(playerName, guildTag, guildAtStr)
        MaybeLeaderboardGuildRefreshFromSync()
    end
end

function Overlord.Sync:StartGuildIdentityHeartbeat()
    if guildIdentityHeartbeatActive then return end
    guildIdentityHeartbeatActive = true
    local function scheduleNext(delay)
        C_Timer.After(delay, function()
            if not Overlord.Sync or not guildIdentityHeartbeatActive then return end
            if Overlord.InstanceSuspended then
                scheduleNext(GI_IDENTITY_INTERVAL)
                return
            end
            Overlord.Sync:BroadcastGuildIdentity(false)
            scheduleNext(GI_IDENTITY_INTERVAL + math.random(-120, 120))
        end)
    end
    C_Timer.After(GI_IDENTITY_INITIAL_DELAY + math.random(0, 15), function()
        if Overlord.Sync then
            Overlord.Sync:BroadcastGuildIdentity(true)
        end
        scheduleNext(GI_IDENTITY_INTERVAL)
    end)
end
