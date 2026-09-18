-- SyncDomination.lua - fusion/reception/emission DM (domination hebdo par front).
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local DM_SECONDS_PER_WEEK = 7 * 24 * 60 * 60
local DM_SCORE_INTERVAL = 120
-- v11 est volontairement incompatible avec les anciens mergeurs max(A)+max(H) :
-- ils pourraient sinon regonfler une photo canonique corrigee par un client neuf.
local DM_PROTOCOL_VERSION = "11"

-- Identite de campagne pour la synchro domination : on se cale strictement sur la FENETRE
-- hebdomadaire du reset officiel Blizzard (C_DateAndTime, via GetCurrentCampaignStartTs), qui est
-- coherente pour toute la region (meme instant pour tous les clients d'un meme royaume/region).
--
-- On NE matche PLUS sur un jour calendaire (AAAAMMJJ) ni sur des tolerances "legacy mercredi" :
-- ce jour derivait selon le fuseau (mardi cote US continental, mercredi cote Oceanique) et
-- fragmentait la campagne NA -> les DX etaient rejetes entre clients -> barre figee a 50/50.
-- Le jour calendaire reste reserve a l'affichage/export (Check PvP), pas a la synchro reseau.
--
-- Un epoch distant appartient a la campagne courante s'il tombe dans la meme fenetre
-- [debut campagne ; debut + 1 semaine). EU non affecte (reset deja coherent tous fuseaux).
local function IsCurrentSyncCampaignEpoch(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local windowStart = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if windowStart <= 0 then return false end
    return epoch >= windowStart and epoch < windowStart + DM_SECONDS_PER_WEEK
end

-- Format DX v11 : allianceTime:hordeTime:epoch:frontId:seq:source:pool:boostA:boostH:protocol
-- Le marqueur v11 coupe explicitement les clients qui materialisent encore les victoires
-- dans les buckets DX : le bonus victoire voyage desormais uniquement via VB.
-- epoch = debut de campagne officiel (reset Blizzard, region-wide coherent) : accepte si l'epoch
-- distant tombe dans la meme fenetre hebdomadaire (voir IsCurrentSyncCampaignEpoch).
-- Evite la pollution par les vieux clients (DM sans 3e champ) ou une autre campagne.

-- Fusion DM : snapshot complet. Les paquets 6.5.11+ portent une sequence de score
-- par front. La source tranche a sequence egale pour converger, sans laisser
-- un total local gonfle par double tick gagner indefiniment.
Overlord.Sync._dmSanityCap = Overlord.DOMINATION_SANITY_CAP or 2147483647
Overlord.Sync._dmChannelMaxStep = 2400
Overlord.Sync._dmChannelSnapshotCooldown = 90
Overlord.Sync._dmWeakChannelSnapshotAt = Overlord.Sync._dmWeakChannelSnapshotAt or {}
local DM_COMMUNITY_COOLDOWN = 55
local DM_COMMUNITY_MAX = 12
local DM_COMMUNITY_MAX_LARGE = 8
local DM_COMMUNITY_DELAY = 0.35
local DM_COMMUNITY_DELAY_LARGE = 0.4
local VALID_DM_POOL_TAG = { fr = true, eu = true, de = true, us = true }

local function NormalizeDominationPoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if VALID_DM_POOL_TAG[pool] then return pool end
    return ""
end

local function CurrentDominationPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizeDominationPoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function ResolveDominationPayloadPool(remotePool, sender, sourceChannel)
    remotePool = NormalizeDominationPoolTag(remotePool)
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        return Overlord.Sync:ResolveDirectGroupTerritorialPool(
            remotePool, sender, sourceChannel)
    end
    local localPool = CurrentDominationPoolTag()
    if localPool == "" or remotePool == "" then return nil end
    return remotePool == localPool and localPool or nil
end

function Overlord.Sync:NormalizeDominationSyncValue(n)
    n = tonumber(n) or 0
    if n ~= n or n == math.huge or n == -math.huge then return 0 end
    n = math.floor(n)
    if n < 0 then return 0 end
    local DM_SANITY_CAP = self._dmSanityCap or Overlord.DOMINATION_SANITY_CAP or 2147483647
    if n > DM_SANITY_CAP then return DM_SANITY_CAP end
    return n
end

function Overlord.Sync:ApplyDominationSnapshot(bucket, remoteAlly, remoteHorde, remoteSeq, remoteSource)
    bucket.Alliance = remoteAlly
    bucket.Horde = remoteHorde
    bucket.scoreSeq = remoteSeq
    bucket.scoreSource = remoteSource or ""
    bucket.allowLowerDominationSnapshot = nil
    bucket.dominationMergeVersion = 6
    return true
end

local function NormalizeDominationBoostSnapshotValue(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    if v < 0 then return nil end
    if v > 1 then return nil end
    return math.floor(v * 10000) / 10000
end

function Overlord.Sync:ApplyDominationBoostSnapshot(remoteBoostA, remoteBoostH)
    -- Obsolete depuis 7.1.13 : la barre suit les secondes zone, pas dominationBoostPct.
    return false
end

function Overlord.Sync:BuildDominationPayload(frontId, bucket)
    if not frontId or not bucket then return nil end
    local pool = CurrentDominationPoolTag()
    if pool == "" then return nil end
    local a = math.floor(bucket.Alliance or 0)
    local h = math.floor(bucket.Horde or 0)
    if a + h <= 0 then return nil end
    -- On emet le debut de campagne OFFICIEL (reset Blizzard, region-wide coherent), pas un epoch
    -- "legacy mercredi" : la reception (IsCurrentSyncCampaignEpoch) compare desormais par fenetre
    -- hebdomadaire, donc tous les clients a jour d'une meme region convergent sans ambiguite de jour.
    local epoch = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    local currentSeq = math.floor((time and time() or 0) / DM_SCORE_INTERVAL)
    local seq = math.floor(tonumber(bucket.scoreSeq) or 0)
    if seq <= 0 or seq > currentSeq + 1 then seq = currentSeq end
    local source = tostring(bucket.scoreSource or "")
    if source == "" and self.GetPlayerFullName then
        source = tostring(self:GetPlayerFullName() or "")
    end
    local boostA = 0
    local boostH = 0
    return a .. ":" .. h .. ":" .. epoch .. ":" .. frontId .. ":" .. seq .. ":" .. source
        .. ":" .. pool .. ":" .. boostA .. ":" .. boostH .. ":" .. DM_PROTOCOL_VERSION
end

function Overlord.Sync:BroadcastDominationToCommunity(payloads, forceTargets)
    if not payloads or #payloads == 0 or not self.BroadcastToCommunity then return end
    if Overlord.InstanceSuspended or IsInInstance() then return end
    local isLarge = self.IsLargeEvent and self:IsLargeEvent()
    local maxMembers = isLarge and DM_COMMUNITY_MAX_LARGE or DM_COMMUNITY_MAX
    local delay = isLarge and DM_COMMUNITY_DELAY_LARGE or DM_COMMUNITY_DELAY
    local firstPayload = payloads[1]
    local extraWhispers
    if #payloads > 1 then
        extraWhispers = {}
        for i = 2, #payloads do
            extraWhispers[#extraWhispers + 1] = { type = "DX", payload = payloads[i] }
        end
    end
    self:BroadcastToCommunity("DX", firstPayload, maxMembers, delay, forceTargets, extraWhispers)
end

local function DominationSourceWins(remoteSource, localSource)
    remoteSource = tostring(remoteSource or "")
    localSource = tostring(localSource or "")
    if remoteSource == "" then return false end
    if localSource == "" then return true end
    return remoteSource > localSource
end

function Overlord.Sync:MergeDominationBucket(bucket, remoteAlly, remoteHorde, remoteSeq, remoteSource, opts)
    if not bucket then return false end
    opts = opts or {}
    remoteAlly = self:NormalizeDominationSyncValue(remoteAlly)
    remoteHorde = self:NormalizeDominationSyncValue(remoteHorde)
    local localAlly = bucket.Alliance or 0
    local localHorde = bucket.Horde or 0
    local remoteTotal = remoteAlly + remoteHorde
    local localTotal = localAlly + localHorde
    remoteSeq = math.floor(tonumber(remoteSeq) or 0)
    remoteSource = tostring(remoteSource or "")
    local localSeq = math.floor(tonumber(bucket.scoreSeq) or 0)

    -- Anciens snapshots sans sequence : compat interne seulement. Le protocole v11
    -- emis sur le reseau porte toujours une sequence bornee a l'horloge courante.
    if remoteSeq <= 0 then
        if localSeq > 0 then return false end
        local mergedAlly = (remoteAlly > localAlly) and remoteAlly or localAlly
        local mergedHorde = (remoteHorde > localHorde) and remoteHorde or localHorde
        if mergedAlly ~= localAlly or mergedHorde ~= localHorde then
            return self:ApplyDominationSnapshot(bucket, mergedAlly, mergedHorde, localSeq, bucket.scoreSource)
        end
        return false
    end

    -- Ordre total convergent : total, sequence, source, puis Alliance. Le total
    -- ne baisse jamais, mais une composante peut baisser a total constant afin
    -- d'eviter l'inflation max(A)+max(H). Deux clients qui voient les memes DX
    -- choisissent donc toujours exactement la meme photo, quel que soit l'ordre.
    if remoteTotal < localTotal then return false end
    if remoteTotal == localTotal then
        if remoteSeq < localSeq then return false end
        if remoteSeq == localSeq then
            local localSource = tostring(bucket.scoreSource or "")
            if remoteSource < localSource then return false end
            if remoteSource == localSource and remoteAlly <= localAlly then
                return false
            end
        end
    end
    return self:ApplyDominationSnapshot(
        bucket, remoteAlly, remoteHorde, remoteSeq, remoteSource)
end

function Overlord.Sync:ScheduleDominationSnapshotRefresh()
    if self._dmRefreshScheduled then return end
    self._dmRefreshScheduled = true
    local function flush()
        if not Overlord.Sync then return end
        Overlord.Sync._dmRefreshScheduled = nil
        if Overlord.RecalculateDominationTotals then
            Overlord:RecalculateDominationTotals()
        end
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, flush)
    else
        flush()
    end
end

function Overlord.Sync:IsDominationChannelSenderVerified(sender)
    if self.SenderIsInOurGroup and self:SenderIsInOurGroup(sender or "") then return true end
    if self.IsGuildKeepCommunitySender and self:IsGuildKeepCommunitySender(sender or "") then return true end
    return false
end

local function MaxPlausibleDominationTotal(front, campaignEpoch)
    if not front or type(front.zones) ~= "table" then return 0 end
    local zoneCount = 0
    for _ in pairs(front.zones) do zoneCount = zoneCount + 1 end
    if zoneCount <= 0 then return 0 end
    local elapsed = math.max(0, math.min(
        DM_SECONDS_PER_WEEK, (time and time() or 0) - campaignEpoch + 300))
    -- Le socle territorial vaut zoneCount * secondes. Les bonus bois de 1 % se
    -- composent sur le total multi-front ; x64 couvre plus de 400 depenses sans
    -- rejeter une campagne legitime, tout en gardant le plafond absolu a 50 M.
    return math.min(
        (Overlord.DOMINATION_PLAUSIBLE_MAX or 500000000) - 1,
        math.max(100000, zoneCount * elapsed * 64 + 500000))
end

function Overlord.Sync:OnReceiveDomination(payload, sender, sourceChannel)
    if not payload or not OverlordDB then return end
    local aStr, hStr, epochStr, frontId, seqStr, sourceStr, poolStr, boostAStr, boostHStr, protocolStr =
        strsplit(":", payload, 10)
    if protocolStr ~= DM_PROTOCOL_VERSION then return end
    local effectivePool = ResolveDominationPayloadPool(poolStr, sender, sourceChannel)
    if not effectivePool then return end
    local remoteAlly  = tonumber(aStr) or 0
    local remoteHorde = tonumber(hStr) or 0
    if remoteAlly < 0 or remoteHorde < 0 then return end
    -- Rejet des valeurs corrompues / gonflees (cap 2^31-1, timestamp ayant fuite, ou ancien bug
    -- d'amplification du bonus qui poussait les buckets a des centaines de millions). Les adopter
    -- via le max() du CRDT figerait/fausserait la barre sans retour possible (bug US, Nemy/Croquette).
    -- Seuil = plausible / front / faction (~50 M). Le pair concerne guerit de son cote (migrations 8/9).
    local corruptLimit = Overlord.DOMINATION_PLAUSIBLE_MAX or 500000000
    if remoteAlly >= corruptLimit or remoteHorde >= corruptLimit then return end
    -- Epoch obligatoire et alignee sur la campagne locale.
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    local remoteSeq = math.floor(tonumber(seqStr) or 0)
    local currentSeq = math.floor((time and time() or 0) / DM_SCORE_INTERVAL)
    local campaignFirstSeq = math.floor(remoteEpoch / DM_SCORE_INTERVAL) - 1
    if remoteSeq < campaignFirstSeq or remoteSeq > currentSeq + 1 then return end
    local remoteSource = tostring(sourceStr or sender or "")
    if remoteSource == "" or #remoteSource > 80 then return end
    local front = frontId and frontId ~= "" and Overlord.Fronts
        and Overlord.Fronts.Registry and Overlord.Fronts.Registry[frontId] or nil
    if not front then return end
    local remoteTotal = remoteAlly + remoteHorde
    if remoteTotal > MaxPlausibleDominationTotal(front, remoteEpoch) then return end
    OverlordDB.frontDominationTime = OverlordDB.frontDominationTime or {}
    local changed = false
    if frontId and frontId ~= "" then
        local bucket = OverlordDB.frontDominationTime[frontId]
        local localTotal = bucket
            and ((tonumber(bucket.Alliance) or 0) + (tonumber(bucket.Horde) or 0)) or 0
        local senderVerified = self:IsDominationChannelSenderVerified(sender or "")
        -- Une photo DM valide vient d'une identite de groupe/communaute connue.
        -- Les relais anonymes sont ignores : un vote local sur trois paquets
        -- rendait la barre differente selon les messages recus par chaque client.
        if not senderVerified then return end
        if not bucket then
            bucket = { Alliance = 0, Horde = 0 }
            OverlordDB.frontDominationTime[frontId] = bucket
        end
        local adoptedDomination = self:MergeDominationBucket(
            bucket, remoteAlly, remoteHorde, remoteSeq, remoteSource)
        if adoptedDomination then
            changed = true
        end
        local remoteSeqNum = remoteSeq
        local localSeqNum = math.floor(tonumber(bucket.scoreSeq) or 0)
        if boostAStr and boostHStr and senderVerified
            and (adoptedDomination or remoteSeqNum >= localSeqNum)
            and self.ApplyDominationBoostSnapshot
            and self:ApplyDominationBoostSnapshot(boostAStr, boostHStr) then
            changed = true
        end
    else
        -- Depuis 6.5.11, DM est obligatoirement par front : A:H:epoch:frontId:seq:source.
        return
    end
    if changed then
        self:ScheduleDominationSnapshotRefresh()
    end
end

function Overlord.Sync:BroadcastDomination(opts)
    opts = opts or {}
    if not OverlordDB then return end
    if Overlord.RecalculateDominationTotals then
        Overlord:RecalculateDominationTotals()
    end
    local communityPayloads = {}
    for frontId, bucket in pairs(OverlordDB.frontDominationTime or {}) do
        local payload = self:BuildDominationPayload(frontId, bucket)
        if payload then
            if IsInGroup() or IsInRaid() then
                self:Send("DX", payload)
            end
            -- Canal royaume meme en solo : chemin primaire pour les observateurs cross-faction.
            -- DX est faible debit mais essentiel a la convergence : ne pas le laisser tomber
            -- derriere les rafales ZS, sinon une barre stale peut rester plusieurs jours.
            self:SendToChannel("DX", payload, true)
            communityPayloads[#communityPayloads + 1] = payload
        end
    end
    local allowCommunity = #communityPayloads > 0
        and (Overlord.InActiveFront or opts.passiveOffFront == true)
    if allowCommunity then
        -- passiveOffFront : l'appelant (ticker passif) a deja passe ShouldRunPassiveStateBundle.
        local runCommunity = opts.passiveOffFront == true
        if not runCommunity and self.ShouldRunPassiveStateBundle then
            runCommunity = self:ShouldRunPassiveStateBundle({
                cooldown = DM_COMMUNITY_COOLDOWN,
                largeElectionPct = 15,
                smallElectionPct = 35,
            })
        end
        if runCommunity then
            self:BroadcastDominationToCommunity(communityPayloads, true)
        end
    end
end
