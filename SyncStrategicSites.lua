-- Shared strategic-site sender validation and wood-resource domination boosts.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}
local WB_COMMUNITY_MAX, WB_COMMUNITY_DELAY = 12, 0.35
local WB_COMMUNITY_MAX_LARGE, WB_COMMUNITY_DELAY_LARGE = 8, 0.4
local WB_MAX_TOTAL_PCT, WB_CHANNEL_MAX_EVENT_DELTA = 1.0, 0.02
local VALID_POOL_TAG = { global = true }
local function FactionToCode(fac)
    return fac == "Alliance" and "A" or fac == "Horde" and "H" or ""
end
local function SyncSenderIsInOurGroup(sender)
    return Overlord.Sync.SenderIsInOurGroup and Overlord.Sync:SenderIsInOurGroup(sender) or false
end

local function NetworkNow()
    if GetServerTime then return math.floor(tonumber(GetServerTime()) or 0) end
    return time()
end

function Overlord.Sync:HasCommunityClub()
    if self.FindCommunityClub then
        return self:FindCommunityClub() ~= nil
    end
    return OverlordDB and OverlordDB.inCommunity == true
end

local function IsStrategicSiteLargeEvent()
    return Overlord.Sync and Overlord.Sync.IsLargeEvent and Overlord.Sync:IsLargeEvent()
end

local function GetWbCommunityRelayLimits()
    if IsStrategicSiteLargeEvent() then
        return WB_COMMUNITY_MAX_LARGE, WB_COMMUNITY_DELAY_LARGE
    end
    return WB_COMMUNITY_MAX, WB_COMMUNITY_DELAY
end

local function StrategicSiteSyncBlocked(allowInstance)
    if Overlord.InstanceSuspended then return true end
    if allowInstance then return false end
    return IsInInstance and IsInInstance()
end

local function FactionCodeToFaction(code)
    if code == "A" then return "Alliance" end
    if code == "H" then return "Horde" end
    return nil
end

local function IsCurrentSyncCampaignEpoch(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local localStart = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if localStart <= 0 then return false end
    if Overlord.CampaignEpochsMatch
        and Overlord:CampaignEpochsMatch(epoch, localStart) then
        return true
    end
    return epoch >= localStart and epoch < localStart + 604800
end

local function NormalizePoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if VALID_POOL_TAG[pool] then return pool end
    return ""
end

local function CurrentStrategicPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizePoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function StrategicPayloadPoolMatchesLocal(remotePool)
    remotePool = NormalizePoolTag(remotePool)
    if remotePool == "" then return false end
    local localPool = CurrentStrategicPoolTag()
    return localPool ~= "" and remotePool == localPool
end

local function ResolveStrategicPayloadPool(remotePool, sender, sourceChannel)
    remotePool = NormalizePoolTag(remotePool)
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        return Overlord.Sync:ResolveDirectGroupTerritorialPool(
            remotePool, sender, sourceChannel)
    end
    return StrategicPayloadPoolMatchesLocal(remotePool) and remotePool or nil
end

local function StrategicPayloadHasExplicitLocalPool(remotePool)
    remotePool = NormalizePoolTag(remotePool)
    if remotePool == "" then return false end
    return StrategicPayloadPoolMatchesLocal(remotePool)
end

local function GetGroupSenderFaction(sender)
    return Overlord.Sync and Overlord.Sync.GetGroupMemberFaction
        and Overlord.Sync:GetGroupMemberFaction(sender) or nil
end

function Overlord.Sync:IsStrategicSiteSenderTrusted(sender, remoteFaction, sourceChannel, msgType, remoteStatus)
    if not sender or sender == "" then return false end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return false end
    local pf = Overlord.PlayerFaction
    if not pf or pf == "" then return false end

    if self.IsStrategicSiteCommunitySender and self:IsStrategicSiteCommunitySender(sender) then
        return true
    end

    -- Le canal est par faction, mais un defenseur peut relayer un etat ennemi.
    -- Les recepteurs valident site, pool, campagne et timestamps avant application.
    if sourceChannel == "CHANNEL" and (msgType == "WB"
        or msgType == "LO" or msgType == "LOC" or msgType == "OE"
        or msgType == "OP" or msgType == "OC") then
        return true
    end

    -- Les etats actifs et terminaux circulent aussi dans les groupes mixtes.
    -- Les snapshots de routine conservent la verification de faction du groupe.
    if SyncSenderIsInOurGroup(sender) then
        if msgType == "LO"
            or msgType == "LOC" or msgType == "OE" or msgType == "OC" then
            return true
        end
        if msgType == "OP" and remoteStatus == "in_progress" then
            return true
        end
        local sf = GetGroupSenderFaction(sender)
        return sf and sf == pf
    end
    return false
end

local DOMINATION_BOOST_EVENT_MAX = 1024
local DOMINATION_BOOST_EVENT_TTL = 86400
local DOMINATION_BOOST_MAINTENANCE_INTERVAL = 60
local DOMINATION_BOOST_MAINTENANCE_WORK = 64
local DOMINATION_BOOST_MAINTENANCE_MS = 1.25
local dominationBoostLedgerState = {
    source = nil, epoch = 0, count = 0, valid = false, pending = false,
    generation = 0, lastBuiltAt = -DOMINATION_BOOST_MAINTENANCE_INTERVAL,
}

local function StartDominationBoostLedgerMaintenance(epoch)
    if not OverlordDB or not C_Timer or not C_Timer.After then return false end
    local source = OverlordDB.dominationBoostEvents
    if type(source) ~= "table" then
        source = {}
        OverlordDB.dominationBoostEvents = source
    end
    local state = dominationBoostLedgerState
    if state.pending and state.source == source and state.epoch == epoch then
        return state.valid
    end
    local initialBuild = not (state.source == source and state.epoch == epoch and state.valid)
    state.generation = state.generation + 1
    local generation = state.generation
    state.source, state.epoch = source, epoch
    if initialBuild then state.valid = false end
    state.pending = true
    local count = 0
    local processed = 0
    local started = debugprofilestop and debugprofilestop() or 0
    local worker = coroutine.create(function()
        local now = GetTime()
        local cursor, pendingDeleteKey = nil, nil
        while true do
            -- Garder `cursor` present jusqu'a l'appel next suivant : supprimer la
            -- cle courante avant un yield rend la continuation indefinie en Lua.
            local ok, key, seen = pcall(next, source, cursor)
            if not ok then error(key) end
            if pendingDeleteKey ~= nil then
                source[pendingDeleteKey] = nil
                if not initialBuild then
                    state.count = math.max(0, state.count - 1)
                end
                pendingDeleteKey = nil
            end
            if key == nil then break end
            cursor = key
            local evEpoch = tonumber(tostring(key):match("^(%d+):")) or 0
            local seenAt = type(seen) == "number" and seen or now
            if (epoch > 0 and evEpoch > 0 and evEpoch ~= epoch)
                or now - seenAt > DOMINATION_BOOST_EVENT_TTL then
                pendingDeleteKey = key
            elseif initialBuild then
                count = count + 1
            end
            processed = processed + 1
            local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
            if processed >= DOMINATION_BOOST_MAINTENANCE_WORK
                or elapsed >= DOMINATION_BOOST_MAINTENANCE_MS then
                processed = 0
                coroutine.yield()
                started = debugprofilestop and debugprofilestop() or 0
            end
        end
    end)
    local ResumeWorker
    ResumeWorker = function()
        if state.generation ~= generation or state.source ~= source
            or OverlordDB.dominationBoostEvents ~= source then return end
        local ok = coroutine.resume(worker)
        if not ok then
            state.pending = false
            if initialBuild then
                state.valid, state.failed = false, true
            end
            state.retryAt = GetTime() + 5
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        if initialBuild then state.count, state.valid = count, true end
        state.pending, state.failed = false, nil
        state.lastBuiltAt, state.retryAt = GetTime(), nil
        -- Un evenement peut etre admis entre deux tranches d'une maintenance
        -- periodique. Cette insertion peut reordonner la table parcourue par
        -- `next` en Lua 5.1 ; refaire une passe cooperative garantit qu'aucune
        -- ancienne entree expiree n'est sautee, sans scanner dans le handler WB.
        local restartRequested = state.restartRequested
        state.restartRequested = nil
        if restartRequested then
            StartDominationBoostLedgerMaintenance(epoch)
        end
    end
    ResumeWorker()
    return state.valid == true
end

function Overlord.Sync:EnsureDominationBoostEventLedgerPrepared(epoch)
    if not OverlordDB then return false end
    epoch = math.floor(tonumber(epoch) or tonumber(OverlordDB.lastResetTimestamp) or 0)
    OverlordDB.dominationBoostEvents = type(OverlordDB.dominationBoostEvents) == "table"
        and OverlordDB.dominationBoostEvents or {}
    local state = dominationBoostLedgerState
    local source = OverlordDB.dominationBoostEvents
    local now = GetTime()
    local currentValid = state.source == source and state.epoch == epoch and state.valid
    if currentValid then
        if not state.pending
            and (not state.retryAt or now >= state.retryAt)
            and now - state.lastBuiltAt >= DOMINATION_BOOST_MAINTENANCE_INTERVAL then
            StartDominationBoostLedgerMaintenance(epoch)
        end
        -- La maintenance periodique ne rend pas l'index partiel : son compteur
        -- reste exact au fil des suppressions et insertions cooperatives.
        return true
    end
    if state.pending and state.source == source and state.epoch == epoch then return false end
    if state.failed and state.source == source and state.epoch == epoch then return "blocked" end
    if state.retryAt and now < state.retryAt then return false end
    return StartDominationBoostLedgerMaintenance(epoch)
end

local function NormalizeDominationBoostEventId(eventId)
    if type(eventId) ~= "string" then return "" end
    eventId = eventId:match("^%s*([%w_%-%.]+)%s*$") or ""
    if #eventId > 80 then eventId = eventId:sub(1, 80) end
    return eventId
end

function Overlord.Sync:BuildDominationBoostEventId(faction)
    local name = (Overlord.SafeUnitName and select(1, Overlord:SafeUnitName("player"))) or UnitName("player") or "player"
    name = tostring(name):gsub("[^%w_%-]", "")
    local facCode = FactionToCode(faction) or "X"
    return string.format("%s-%s-%d-%d-%d", facCode, name, NetworkNow(), math.floor(GetTime() * 1000), math.random(1000, 9999))
end

function Overlord.Sync:MarkDominationBoostEventSeen(faction, eventId, epoch)
    if not OverlordDB then return false end
    eventId = NormalizeDominationBoostEventId(eventId)
    if eventId == "" then return false end
    local facCode = FactionToCode(faction) or tostring(faction or "")
    if facCode == "" then return false end
    epoch = math.floor(tonumber(epoch) or tonumber(OverlordDB.lastResetTimestamp) or 0)
    OverlordDB.dominationBoostEvents = OverlordDB.dominationBoostEvents or {}
    local key = string.format("%d:%s:%s", epoch, facCode, eventId)
    -- Exact avant toute maintenance : les replays restent O(1), meme pendant
    -- une reconstruction tranchee ou lorsque le ledger est sature.
    if OverlordDB.dominationBoostEvents[key] then return false end
    if not self:EnsureDominationBoostEventLedgerPrepared(epoch) then return false end
    local state = dominationBoostLedgerState
    if state.source ~= OverlordDB.dominationBoostEvents or not state.valid
        or state.count >= DOMINATION_BOOST_EVENT_MAX then return false end
    if state.pending and state.source == OverlordDB.dominationBoostEvents then
        state.restartRequested = true
    end
    OverlordDB.dominationBoostEvents[key] = GetTime()
    state.count = state.count + 1
    return true
end

local function BroadcastBoostToGroup(kind, payload)
    if IsInGroup and IsInGroup() then return Overlord.Sync:Send(kind, payload) end
    return false
end
local function BroadcastBoostToCommunity(kind, payload, maxMembers, delay, force)
    return Overlord.Sync:BroadcastToCommunity(kind, payload, maxMembers, delay, force)
end

function Overlord.Sync:BroadcastDominationBoost(faction, boostPct, siteKey, eventId, eventDelta)
    if not faction or not OverlordDB or StrategicSiteSyncBlocked() then return end
    local epoch = OverlordDB.lastResetTimestamp or 0
    local facCode = FactionToCode(faction)
    if facCode == "" then return end
    local pct = math.floor((boostPct or 0) * 10000) / 10000
    local pool = CurrentStrategicPoolTag()
    if pool == "" then return end
    local poolSuffix = ":" .. pool
    if siteKey ~= "wood_resource" then return end
    local eventSuffix = ""
    eventId = NormalizeDominationBoostEventId(eventId)
    eventDelta = math.floor((tonumber(eventDelta) or 0) * 10000) / 10000
    if eventId ~= "" and eventDelta > 0 then
        eventSuffix = ":" .. eventId .. ":" .. eventDelta
    end
    local payload = facCode .. ":" .. pct .. ":" .. epoch .. ":" .. siteKey .. ":_" .. poolSuffix .. eventSuffix
    BroadcastBoostToGroup("WB", payload)
    self:SendToChannel("WB", payload)
    -- Cross-realm / cross-faction : communaute (canal Overlord = realm-only).
    local maxM, delay = GetWbCommunityRelayLimits()
    BroadcastBoostToCommunity("WB", payload, maxM, delay, true)
    C_Timer.After(2.5, function()
        if Overlord.Sync and not Overlord.InstanceSuspended and payload and payload ~= "" then
            BroadcastBoostToCommunity("WB", payload, maxM, delay, true)
        end
    end)
end

function Overlord.Sync:OnReceiveDominationBoost(payload, sender, sourceChannel)
    if not payload or not OverlordDB or StrategicSiteSyncBlocked() then return end
    local facCode, pctStr, epochStr, siteKey, guildStr, remotePool, eventId, deltaStr = strsplit(":", payload, 8)
    local wirePool = NormalizePoolTag(remotePool)
    remotePool = ResolveStrategicPayloadPool(wirePool, sender, sourceChannel)
    if not remotePool then return end
    local fac = FactionCodeToFaction(facCode)
    if not self:IsStrategicSiteSenderTrusted(sender or "", fac, sourceChannel, "WB") then return end
    local epoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(epoch) then return end
    local pct = tonumber(pctStr) or 0
    if pct > WB_MAX_TOTAL_PCT then return end
    if not fac or pct <= 0 then return end
    if siteKey ~= "wood_resource" then return end
    -- Boost global bois : pas de lien fortin ; pas de proximite addon seule (spoof)
    if sourceChannel ~= "CHANNEL" and sender and self.IsNearbyAddonSender and self:IsNearbyAddonSender(sender) then
        if not SyncSenderIsInOurGroup(sender) then
            return
        end
    end
    -- Boost public : les deux factions doivent voir la meme domination (via secondes zone).
    eventId = NormalizeDominationBoostEventId(eventId)
    local isWoodSpendEvent = siteKey == "wood_resource" and eventId ~= ""
    local channelSenderVerified = sourceChannel == "CHANNEL"
        and (SyncSenderIsInOurGroup(sender or "")
            or (self.IsStrategicSiteCommunitySender and self:IsStrategicSiteCommunitySender(sender or "")))
    local weakChannelSender = sourceChannel == "CHANNEL" and not channelSenderVerified
    if isWoodSpendEvent then
        local delta = math.floor((tonumber(deltaStr) or 0) * 10000) / 10000
        if delta <= 0 then return end
        if weakChannelSender then return end
        if delta > WB_CHANNEL_MAX_EVENT_DELTA then return end
        if not self:MarkDominationBoostEventSeen(fac, eventId, epoch) then return end
        -- Canal/groupe : le DX emis au spend porte les secondes exactes (merge max).
        -- Whisper/BNet : relais communaute sans DX dedie ; completer seulement jusqu'au ratio cible.
        local secondsViaWbOnly = (sourceChannel == "WHISPER" or sourceChannel == "BETA") or sourceChannel == "BNET"
        if secondsViaWbOnly and Overlord.ApplyWoodDominationBonusSeconds then
            local applyDelta = delta
            if Overlord.GetDominationDisplayFractions then
                local allyPct, hordePct = Overlord:GetDominationDisplayFractions()
                local currentPct = (fac == "Alliance") and allyPct or hordePct
                local missing = pct - currentPct
                if missing <= 0.000001 then
                    applyDelta = 0
                elseif missing < applyDelta then
                    applyDelta = missing
                end
            end
            if applyDelta > 0 then
                Overlord:ApplyWoodDominationBonusSeconds(fac, applyDelta)
            end
        end
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
        if (sourceChannel ~= "WHISPER" and sourceChannel ~= "BETA") and payload and payload ~= ""
            and StrategicPayloadHasExplicitLocalPool(wirePool) then
            local relayPl, relayKey = payload, "WB:" .. payload
            C_Timer.After(0.5, function()
                if Overlord.Sync and Overlord.Sync.RelayDominationBoostToCommunitySafe then
                    Overlord.Sync:RelayDominationBoostToCommunitySafe(relayPl, relayKey, remotePool)
                end
            end)
        end
        return
    end
    -- Snapshots WB legacy sans eventId/delta : ignores (7.1.13+, barre = secondes).
end
