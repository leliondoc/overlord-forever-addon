-- ManualBounty.lua - Contrats en or manuels avec paiement sortant verifie
Overlord = Overlord or {}
Overlord.ManualBounty = {}

local L = Overlord.L

Overlord.ManualBounty.MIN_COPPER = 10000
Overlord.ManualBounty.MAX_COPPER = 100000000
Overlord.ManualBounty.MAX_OPEN_PER_POSTER = 15
Overlord.ManualBounty.CONTRACT_STALE_SEC = 7 * 24 * 3600
Overlord.ManualBounty.CLAIM_SETTLEMENT_SEC = 60
Overlord.ManualBounty.FINANCIAL_HISTORY_SEC = 30 * 24 * 3600
Overlord.ManualBounty.POSITION_INTERVAL = 20
Overlord.ManualBounty.POSITION_STALE_SEC = 90
Overlord.ManualBounty.MAX_REMOTE_CATALOG_CONTRACTS = 1024
Overlord.ManualBounty.MAX_REMOTE_PARTICIPANT_RESERVE = 256
Overlord.ManualBounty.REVISION = 0
Overlord.ManualBounty.POSITION_REVISION = 0

local contractsById = {}
local openContractsByTarget = {}
local indexedTargetByContract = {}
-- Resume persistant par cible : les lecteurs carte/minimap ne doivent jamais
-- reparcourir un bucket pouvant contenir tout le catalogue distant.
local targetSummaryState = {
    byTarget = {},
    byContract = {},
    revision = 0,
    contextReady = false,
    hunterName = "",
    hunterKey = "",
    hunterFaction = "",
    pool = nil,
    epoch = 0,
    claimableValid = false,
    rebuildPending = false,
    rebuildGeneration = 0,
}
local targetPositions = {}
local remoteCatalogContractIds = {}
local remoteCatalogContractCount = 0
local openContractCount = 0
local migratedDbRoot = nil
local migratedSettlementRoot = nil
local nextLocalId = 0
local srContractCursor = 0
local positionTicker = nil
local RefreshLocalTargetTracking
local ArmMaintenance
local maintenanceTimer = nil
local maintenanceContractIds = {}
local maintenanceContractPositions = {}
local ownedActiveContractIds = {}
local ownedActiveContractPositions = {}
local knownSyncContractIds = {}
local knownSyncContractPositions = {}
local srRelevantContractIds = {}
local srRelevantContractPositions = {}
local knownSyncCursor = 0
local maintenancePositionKeys = {}
local maintenancePositionKeyPositions = {}
local maintenanceContractCursor = 1
local maintenancePositionCursor = 1
local maintenanceContractSweepRemaining = 0
local maintenancePositionSweepRemaining = 0
local maintenanceSweepActive = false
local maintenanceRunning = false
local MAINTENANCE_INTERVAL_SEC = 60
local MAINTENANCE_SLICE_DELAY_SEC = 0.2
local MAINTENANCE_CONTRACT_QUOTA = 32
local MAINTENANCE_POSITION_QUOTA = 16
local DEBUG_CONTRACT_ID = "MBDEBUG-LOCAL"
local MAP_REFRESH_DEBOUNCE = 0.25
local mapRefreshPending = false
local POSITION_REVISION_DEBOUNCE = 0.10
local positionRevisionTimer = nil
local positionMapRefreshPending = false
local TARGET_SUMMARY_REBUILD_QUOTA = 64
local StartTargetSummaryRebuild

local function IsWorldMapVisible()
    return WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown()
end

local function ServerNow()
    return GetServerTime()
end

local function NormalizePool(pool)
    pool = type(pool) == "string" and pool:lower() or ""
    if pool == "global" or pool == "us" or pool == "na" or pool == "fr"
        or pool == "de" or pool == "eu" then
        return "global"
    end
    return nil
end

local function CurrentPool()
    if not Overlord.GetCurrentSavedVarsPool then return nil end
    return NormalizePool(Overlord:GetCurrentSavedVarsPool())
end

local function MergeLegacyContractPoolBuckets(root, pool, yieldWork)
    root[pool] = type(root[pool]) == "table" and root[pool] or {}
    local target = root[pool]
    for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
        local source = root[oldPool]
        if type(source) == "table" and source ~= target then
            for key, value in pairs(source) do
                local current = target[key]
                if current == nil or (type(value) == "table" and type(current) == "table"
                    and (tonumber(value.updatedAt) or 0) > (tonumber(current.updatedAt) or 0)) then
                    if type(value) == "table" then value.pool = pool end
                    target[key] = value
                end
                if yieldWork then yieldWork() end
            end
        end
        root[oldPool] = nil
    end
    return target
end

local function MergeLegacySettlementPoolBuckets(root, pool, yieldWork)
    root[pool] = type(root[pool]) == "table" and root[pool] or {}
    local target = root[pool]
    for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
        local source = root[oldPool]
        if type(source) == "table" and source ~= target then
            for characterKey, ledger in pairs(source) do
                if yieldWork then yieldWork() end
                if type(ledger) == "table" then
                    target[characterKey] = type(target[characterKey]) == "table"
                        and target[characterKey] or {}
                    for contractId, value in pairs(ledger) do
                        if yieldWork then yieldWork() end
                        local current = target[characterKey][contractId]
                        if current == nil or (type(value) == "table" and type(current) == "table"
                            and (tonumber(value.updatedAt) or 0)
                                > (tonumber(current.updatedAt) or 0)) then
                            target[characterKey][contractId] = value
                        end
                    end
                end
            end
        end
        root[oldPool] = nil
    end
end

local function CurrentCampaignEpoch()
    if Overlord.GetCurrentCampaignWireEpoch then
        local epoch = tonumber(Overlord:GetCurrentCampaignWireEpoch()) or 0
        if epoch > 0 then return epoch end
    end
    return tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0
end

local function IsCurrentCampaignEpoch(epoch)
    return Overlord:CampaignEpochsMatch(epoch, CurrentCampaignEpoch())
end

local function Dbg(msg)
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFFFF8800[Overlord:ManualBounty]|r " .. tostring(msg))
    end
end

-- Plusieurs PM peuvent arriver dans la meme frame. Une revision par paquet faisait
-- reconstruire les trois caches carte/minimap autant de fois ; une seule revision
-- apres la rafale suffit car targetPositions contient deja le dernier etat par cible.
local function QueuePositionRevision(refreshWorldMap)
    positionMapRefreshPending = positionMapRefreshPending or refreshWorldMap == true
    if positionRevisionTimer then return end
    positionRevisionTimer = C_Timer.NewTimer(POSITION_REVISION_DEBOUNCE, function()
        positionRevisionTimer = nil
        Overlord.ManualBounty.POSITION_REVISION =
            Overlord.ManualBounty.POSITION_REVISION + 1
        local refreshMap = positionMapRefreshPending
        positionMapRefreshPending = false
        if refreshMap and Overlord.ManualBounty.RefreshWorldMapPins then
            Overlord.ManualBounty:RefreshWorldMapPins()
        end
    end)
end

local function CancelQueuedPositionRevision()
    if positionRevisionTimer then
        positionRevisionTimer:Cancel()
        positionRevisionTimer = nil
    end
    positionMapRefreshPending = false
end

local function BumpRevision(refreshFeaturedPopup)
    Overlord.ManualBounty.REVISION = Overlord.ManualBounty.REVISION + 1
    -- La visibilite d'une position depend aussi des contrats ouverts compatibles
    -- avec le chasseur local. Toute transition contractuelle invalide donc les
    -- caches carte/continent/minimap, meme si les coordonnees n'ont pas bouge.
    QueuePositionRevision(true)
    if refreshFeaturedPopup
        and Overlord.Popups
        and Overlord.Popups.RefreshFeaturedFrontBountyButton then
        Overlord.Popups:RefreshFeaturedFrontBountyButton()
    end
end

local function EnsureDb()
    if not OverlordDB then return nil end
    if type(OverlordDB.manualBountyContracts) ~= "table" then
        OverlordDB.manualBountyContracts = {}
    end
    local root = OverlordDB.manualBountyContracts
    local pool = CurrentPool()
    if not pool then return nil end

    if migratedDbRoot ~= root then
        MergeLegacyContractPoolBuckets(root, pool)
        -- Migration unique du stockage plat 9.0 vers un compartiment par pool.
        local legacy = {}
        local hasLegacy = false
        for key, value in pairs(root) do
            if type(value) == "table" and (value.id or value.status or value.target) then
                legacy[key] = value
                hasLegacy = true
            end
        end
        if hasLegacy then
            root[pool] = type(root[pool]) == "table" and root[pool] or {}
            for key, value in pairs(legacy) do
                value.pool = NormalizePool(value.pool) or pool
                root[pool][key] = value
                root[key] = nil
            end
        end
        migratedDbRoot = root
    end
    if type(root[pool]) ~= "table" then
        root[pool] = {}
    end
    return root[pool]
end

local function GetLocalFullName()
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName then
        return sync:GetPlayerFullName()
    end
    return Overlord:SafeUnitName("player", true)
end

-- Forever identities contain both names and no realm. Contracts are already
-- scoped by their validated region/campaign; never invent a realm suffix.
local function IsCompleteName(name)
    local sync = Overlord.Sync
    return sync and sync.HasCompleteContributorIdentity
        and sync:HasCompleteContributorIdentity(name) or false
end

local function PaymentIdentitiesValid(a, b)
    return IsCompleteName(a) and IsCompleteName(b)
end

local function NameDedupKey(name)
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(name)
    end
    return (name or ""):lower()
end

local function DenseIndexAdd(rows, positions, key)
    if not key or positions[key] then return false end
    rows[#rows + 1] = key
    positions[key] = #rows
    return true
end

local function DenseIndexRemove(rows, positions, key)
    local index = key and positions[key]
    if not index then return false end
    local lastIndex = #rows
    local lastKey = rows[lastIndex]
    rows[index] = lastKey
    rows[lastIndex] = nil
    positions[key] = nil
    if lastKey and lastKey ~= key then positions[lastKey] = index end
    return true
end

local function RemoveMaintenancePositionKey(key)
    return DenseIndexRemove(
        maintenancePositionKeys, maintenancePositionKeyPositions, key)
end

local function CaptureTargetSummaryContext()
    local hunterName = GetLocalFullName() or ""
    local hunterKey = NameDedupKey(hunterName) or ""
    local hunterFaction = Overlord.PlayerFaction or ""
    local pool = CurrentPool()
    local epoch = CurrentCampaignEpoch()
    local changed = not targetSummaryState.contextReady
        or targetSummaryState.hunterName ~= hunterName
        or targetSummaryState.hunterKey ~= hunterKey
        or targetSummaryState.hunterFaction ~= hunterFaction
        or targetSummaryState.pool ~= pool
        or targetSummaryState.epoch ~= epoch
    targetSummaryState.contextReady = true
    targetSummaryState.hunterName = hunterName
    targetSummaryState.hunterKey = hunterKey
    targetSummaryState.hunterFaction = hunterFaction
    targetSummaryState.pool = pool
    targetSummaryState.epoch = epoch
    return changed
end

local function BuildTargetSummaryContribution(contract, hunterName, hunterKey,
        hunterFaction, pool, epoch)
    if not contract or not contract.id or contract.status ~= "open"
        or NormalizePool(contract.pool) ~= pool
        or not Overlord:CampaignEpochsMatch(contract.epoch, epoch) then
        return nil
    end
    local key = NameDedupKey(contract.target)
    local faction = contract.targetFaction
    if not key or key == ""
        or (faction ~= "Alliance" and faction ~= "Horde") then
        return nil
    end
    local claimable = hunterName ~= "" and hunterKey ~= ""
        and (hunterFaction == "Alliance" or hunterFaction == "Horde")
        and key ~= hunterKey and faction ~= hunterFaction
        and PaymentIdentitiesValid(contract.poster, hunterName)
    return key, faction, claimable
end

local function AddTargetSummaryContribution(byTarget, byContract, contractId,
        key, faction, claimable)
    local summary = byTarget[key]
    if not summary then
        summary = { total = 0, Alliance = 0, Horde = 0, claimable = 0 }
        byTarget[key] = summary
    end
    summary.total = summary.total + 1
    summary[faction] = summary[faction] + 1
    if claimable then summary.claimable = summary.claimable + 1 end
    byContract[contractId] = {
        key = key,
        faction = faction,
        claimable = claimable == true,
    }
end

local function RemoveTargetSummaryContribution(contractId)
    local contribution = targetSummaryState.byContract[contractId]
    if not contribution then return false end
    targetSummaryState.byContract[contractId] = nil
    local summary = targetSummaryState.byTarget[contribution.key]
    if summary then
        summary.total = math.max(0, summary.total - 1)
        summary[contribution.faction] = math.max(
            0, (summary[contribution.faction] or 0) - 1)
        if contribution.claimable then
            summary.claimable = math.max(0, summary.claimable - 1)
        end
        if summary.total == 0 then
            targetSummaryState.byTarget[contribution.key] = nil
        end
    end
    targetSummaryState.revision = targetSummaryState.revision + 1
    return true
end

local function ResetTargetSummaryIndex()
    targetSummaryState.rebuildGeneration = targetSummaryState.rebuildGeneration + 1
    targetSummaryState.rebuildPending = false
    targetSummaryState.byTarget = {}
    targetSummaryState.byContract = {}
    targetSummaryState.revision = targetSummaryState.revision + 1
    CaptureTargetSummaryContext()
    targetSummaryState.claimableValid = targetSummaryState.hunterName ~= ""
        and targetSummaryState.hunterKey ~= ""
        and (targetSummaryState.hunterFaction == "Alliance"
            or targetSummaryState.hunterFaction == "Horde")
        and targetSummaryState.pool ~= nil
end

StartTargetSummaryRebuild = function()
    if not targetSummaryState.contextReady then CaptureTargetSummaryContext() end
    if targetSummaryState.rebuildPending or not C_Timer or not C_Timer.After then
        return false
    end
    if openContractCount == 0 then
        targetSummaryState.byTarget = {}
        targetSummaryState.byContract = {}
        targetSummaryState.claimableValid = true
        return true
    end

    targetSummaryState.rebuildGeneration = targetSummaryState.rebuildGeneration + 1
    local generation = targetSummaryState.rebuildGeneration
    local sourceRevision = targetSummaryState.revision
    local hunterName = targetSummaryState.hunterName
    local hunterKey = targetSummaryState.hunterKey
    local hunterFaction = targetSummaryState.hunterFaction
    local pool = targetSummaryState.pool
    local epoch = targetSummaryState.epoch
    local nextByTarget, nextByContract = {}, {}
    local cursor = nil
    targetSummaryState.rebuildPending = true

    local function contextStillMatches()
        return generation == targetSummaryState.rebuildGeneration
            and sourceRevision == targetSummaryState.revision
            and hunterName == targetSummaryState.hunterName
            and hunterKey == targetSummaryState.hunterKey
            and hunterFaction == targetSummaryState.hunterFaction
            and pool == targetSummaryState.pool
            and epoch == targetSummaryState.epoch
    end

    local function retryIfCurrent()
        if generation ~= targetSummaryState.rebuildGeneration then return end
        targetSummaryState.rebuildPending = false
        C_Timer.After(0.10, function()
            if generation == targetSummaryState.rebuildGeneration then
                StartTargetSummaryRebuild()
            end
        end)
    end

    local runSlice
    runSlice = function()
        if not contextStillMatches() then
            retryIfCurrent()
            return
        end
        local work = 0
        while work < TARGET_SUMMARY_REBUILD_QUOTA do
            local contractId, contract = next(contractsById, cursor)
            cursor = contractId
            if not contractId then
                if not contextStillMatches() then
                    retryIfCurrent()
                    return
                end
                targetSummaryState.byTarget = nextByTarget
                targetSummaryState.byContract = nextByContract
                targetSummaryState.claimableValid = true
                targetSummaryState.rebuildPending = false
                QueuePositionRevision(true)
                if Overlord.ManualBounty._initialized and RefreshLocalTargetTracking then
                    RefreshLocalTargetTracking()
                end
                return
            end
            local key, faction, claimable = BuildTargetSummaryContribution(
                contract, hunterName, hunterKey, hunterFaction, pool, epoch)
            if key then
                AddTargetSummaryContribution(
                    nextByTarget, nextByContract, contractId, key, faction, claimable)
            end
            work = work + 1
        end
        C_Timer.After(0, runSlice)
    end
    C_Timer.After(0, runSlice)
    return true
end

local function RemoveFromOpenTargetIndex(contractId)
    RemoveTargetSummaryContribution(contractId)
    local key = indexedTargetByContract[contractId]
    if not key then return end
    indexedTargetByContract[contractId] = nil
    openContractCount = math.max(0, openContractCount - 1)
    local bucket = openContractsByTarget[key]
    if not bucket then return end
    bucket[contractId] = nil
    if not next(bucket) then
        openContractsByTarget[key] = nil
        if targetPositions[key] then
            targetPositions[key] = nil
            RemoveMaintenancePositionKey(key)
            QueuePositionRevision(true)
        end
    end
end

local function ReindexContract(contract)
    if not contract or not contract.id then return end
    local hadContext = targetSummaryState.contextReady
    local contextChanged = CaptureTargetSummaryContext()
    if contextChanged then
        targetSummaryState.claimableValid = not hadContext
            and targetSummaryState.hunterName ~= ""
            and targetSummaryState.hunterKey ~= ""
            and (targetSummaryState.hunterFaction == "Alliance"
                or targetSummaryState.hunterFaction == "Horde")
            and targetSummaryState.pool ~= nil
    end
    local desiredKey, faction, claimable = BuildTargetSummaryContribution(
        contract,
        targetSummaryState.hunterName,
        targetSummaryState.hunterKey,
        targetSummaryState.hunterFaction,
        targetSummaryState.pool,
        targetSummaryState.epoch)
    local previous = targetSummaryState.byContract[contract.id]
    if desiredKey and indexedTargetByContract[contract.id] == desiredKey
        and previous and previous.faction == faction
        and previous.claimable == (claimable == true) then
        if contextChanged and hadContext then StartTargetSummaryRebuild() end
        return
    end
    RemoveFromOpenTargetIndex(contract.id)
    if not desiredKey then
        if contextChanged and hadContext then StartTargetSummaryRebuild() end
        return
    end
    local bucket = openContractsByTarget[desiredKey]
    if not bucket then
        bucket = {}
        openContractsByTarget[desiredKey] = bucket
    end
    bucket[contract.id] = true
    indexedTargetByContract[contract.id] = desiredKey
    openContractCount = openContractCount + 1
    AddTargetSummaryContribution(
        targetSummaryState.byTarget,
        targetSummaryState.byContract,
        contract.id,
        desiredKey,
        faction,
        claimable)
    targetSummaryState.revision = targetSummaryState.revision + 1
    if contextChanged and hadContext then StartTargetSummaryRebuild() end
end

local function NamesMatch(a, b)
    if not a or not b or a == "" or b == "" then return false end
    if a:lower() == b:lower() then return true end
    local ak = NameDedupKey(a)
    local bk = NameDedupKey(b)
    return ak ~= nil and bk ~= nil and ak == bk
end

local function ShortName(name)
    return type(name) == "string" and (name:match("^(.-)%-") or name) or ""
end

local function TargetMatchesKill(contractTarget, victimName)
    -- A first name alone can identify another Forever character. Both parts
    -- must match for the victim proof to settle a contract.
    return IsCompleteName(contractTarget) and IsCompleteName(victimName)
        and NamesMatch(contractTarget, victimName)
end

local function NormalizeAmount(copper)
    local n = math.floor(tonumber(copper) or 0)
    if n < Overlord.ManualBounty.MIN_COPPER then return nil end
    if n > Overlord.ManualBounty.MAX_COPPER then return nil end
    return n
end

local function IsRemoteCatalogContract(contract)
    if not contract then return false end
    local me = GetLocalFullName()
    return me ~= nil and me ~= ""
        and not NamesMatch(contract.poster, me)
end

local function GetRemoteContractLimit(contract)
    local limit = Overlord.ManualBounty.MAX_REMOTE_CATALOG_CONTRACTS
    local me = GetLocalFullName()
    if me and me ~= "" and contract
        and (NamesMatch(contract.target, me) or NamesMatch(contract.claimer, me)) then
        limit = limit + Overlord.ManualBounty.MAX_REMOTE_PARTICIPANT_RESERVE
    end
    return limit
end

local function TrackRemoteCatalogContract(contract)
    if not contract or not contract.id then return end
    local tracked = remoteCatalogContractIds[contract.id] == true
    local shouldTrack = IsRemoteCatalogContract(contract)
    if shouldTrack and not tracked then
        remoteCatalogContractIds[contract.id] = true
        remoteCatalogContractCount = remoteCatalogContractCount + 1
    elseif tracked and not shouldTrack then
        remoteCatalogContractIds[contract.id] = nil
        remoteCatalogContractCount = math.max(0, remoteCatalogContractCount - 1)
    end
end

local function ForgetRemoteCatalogContract(contractId)
    if remoteCatalogContractIds[contractId] then
        remoteCatalogContractIds[contractId] = nil
        remoteCatalogContractCount = math.max(0, remoteCatalogContractCount - 1)
    end
end

-- Le registre de reglement est local au personnage signataire. Il n'est jamais
-- cree depuis un paquet reseau : seul CreateContract peut ouvrir une entree.
local function EnsureSettlementLedger(yieldWork)
    if not OverlordDB then return nil end
    local pool = CurrentPool()
    local me = GetLocalFullName()
    local characterKey = me and NameDedupKey(me)
    if not pool or not characterKey or characterKey == "" then return nil end
    if type(OverlordDB.manualBountySettlementLedger) ~= "table" then
        OverlordDB.manualBountySettlementLedger = {}
    end
    local root = OverlordDB.manualBountySettlementLedger
    if migratedSettlementRoot ~= root then
        MergeLegacySettlementPoolBuckets(root, pool, yieldWork)
        migratedSettlementRoot = root
    end
    if type(root[pool]) ~= "table" then root[pool] = {} end
    if type(root[pool][characterKey]) ~= "table" then
        root[pool][characterKey] = {}
    end
    return root[pool][characterKey]
end

local function CopySettlementFields(source, destination)
    destination = destination or {}
    destination.id = source.id
    destination.poster = source.poster
    destination.posterRealm = source.posterRealm
    destination.target = source.target
    destination.targetRealm = source.targetRealm
    destination.targetRace = source.targetRace or ""
    destination.targetRaceSex = tonumber(source.targetRaceSex) or 0
    destination.targetGuild = source.targetGuild or ""
    destination.targetFaction = source.targetFaction
    destination.amountCopper = source.amountCopper
    destination.status = source.status
    destination.claimer = source.claimer or ""
    destination.createdAt = source.createdAt
    destination.claimedAt = source.claimedAt
    destination.approvedAt = source.approvedAt
    destination.paymentSentAt = source.paymentSentAt
    destination.codInvoiceSeenAt = source.codInvoiceSeenAt
    destination.paidAt = source.paidAt
    destination.updatedAt = source.updatedAt
    destination.epoch = source.epoch
    destination.pool = source.pool
    destination.versionActor = source.versionActor
    destination.role = "poster"
    return destination
end

local function SettlementIdentityMatches(entry, contract)
    return type(entry) == "table" and type(contract) == "table"
        and entry.id == contract.id
        and NamesMatch(entry.poster, contract.poster)
        and NamesMatch(entry.target, contract.target)
        and tonumber(entry.amountCopper) == tonumber(contract.amountCopper)
        and NormalizePool(entry.pool) == NormalizePool(contract.pool)
end

local function GetSettlementEntry(id)
    local ledger = EnsureSettlementLedger()
    local entry = ledger and ledger[id]
    if type(entry) ~= "table" or entry.role ~= "poster" then return nil end
    return entry
end

local function RegisterLocalSignedContract(contract)
    local me = GetLocalFullName()
    local ledger = EnsureSettlementLedger()
    if not ledger or not contract or not NamesMatch(contract.poster, me) then return false end
    if ledger[contract.id] then return false end
    ledger[contract.id] = CopySettlementFields(contract, {})
    return true
end

local function UpdateSettlementEntry(contract, allowedStatus)
    local entry = contract and GetSettlementEntry(contract.id)
    if not entry or not SettlementIdentityMatches(entry, contract)
        or (allowedStatus and contract.status ~= allowedStatus) then
        return false
    end
    CopySettlementFields(contract, entry)
    return true
end

local function IsValidSettlementEntry(entry)
    if type(entry) ~= "table" or entry.role ~= "poster"
        or type(entry.id) ~= "string" or not entry.id:match("^MB[%w%-]+$")
        or type(entry.poster) ~= "string" or not IsCompleteName(entry.poster)
        or type(entry.target) ~= "string" or not IsCompleteName(entry.target)
        or not NamesMatch(entry.poster, GetLocalFullName()) then
        return false
    end
    if entry.status ~= "open" and entry.status ~= "claimed"
        and entry.status ~= "approved" and entry.status ~= "paid"
        and entry.status ~= "cancelled" then
        return false
    end
    if (entry.status == "claimed" or entry.status == "approved" or entry.status == "paid")
        and (type(entry.claimer) ~= "string" or entry.claimer == "") then
        return false
    end
    entry.amountCopper = NormalizeAmount(entry.amountCopper)
    entry.createdAt = math.floor(tonumber(entry.createdAt) or 0)
    entry.updatedAt = math.floor(tonumber(entry.updatedAt) or 0)
    entry.claimedAt = math.floor(tonumber(entry.claimedAt) or 0)
    entry.approvedAt = math.floor(tonumber(entry.approvedAt) or 0)
    entry.paymentSentAt = math.floor(tonumber(entry.paymentSentAt) or 0)
    entry.codInvoiceSeenAt = math.floor(tonumber(entry.codInvoiceSeenAt) or 0)
    entry.paidAt = math.floor(tonumber(entry.paidAt) or 0)
    if entry.status == "claimed" and entry.claimedAt <= 0 then
        entry.claimedAt = entry.updatedAt
    end
    entry.epoch = math.floor(tonumber(entry.epoch) or 0)
    entry.pool = NormalizePool(entry.pool)
    return entry.amountCopper ~= nil and entry.createdAt > 0
        and entry.updatedAt >= entry.createdAt and entry.pool == CurrentPool()
end

local function IsEnemyFaction(faction)
    local mine = Overlord.PlayerFaction
    if mine ~= "Alliance" and mine ~= "Horde" then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    return faction ~= mine
end

local function SortContracts(a, b)
    local sa = a.status or ""
    local sb = b.status or ""
    if sa ~= sb then
        if sa == "open" then return true end
        if sb == "open" then return false end
        if sa == "claimed" then return true end
        if sb == "claimed" then return false end
        if sa == "approved" then return true end
        if sb == "approved" then return false end
    end
    return (a.updatedAt or 0) > (b.updatedAt or 0)
end

local function SortTargets(a, b)
    return (a.name or "") < (b.name or "")
end

local function SortRowsWithYield(rows, less, yieldWork)
    if not yieldWork then
        table.sort(rows, less)
        return rows
    end
    local count = #rows
    if count < 2 then return rows end
    local buffer = {}
    local width = 1
    while width < count do
        local left = 1
        while left <= count do
            local middle = math.min(left + width - 1, count)
            local right = math.min(left + width * 2 - 1, count)
            local i, j, out = left, middle + 1, left
            while i <= middle and j <= right do
                if less(rows[j], rows[i]) then
                    buffer[out], j = rows[j], j + 1
                else
                    buffer[out], i = rows[i], i + 1
                end
                out = out + 1
                yieldWork()
            end
            while i <= middle do
                buffer[out], i, out = rows[i], i + 1, out + 1
                yieldWork()
            end
            while j <= right do
                buffer[out], j, out = rows[j], j + 1, out + 1
                yieldWork()
            end
            left = right + 1
        end
        for index = 1, count do
            rows[index] = buffer[index]
            yieldWork()
        end
        width = width * 2
    end
    return rows
end

local function SanitizeGuild(guild)
    if not guild or guild == "" then return "" end
    guild = guild:gsub("^%s+", ""):gsub("%s+$", "")
    if guild == "" then return "" end
    local sync = Overlord.Sync
    if sync and sync.IsValidGuildSyncToken and not sync:IsValidGuildSyncToken(guild) then
        return ""
    end
    return guild
end

local function SanitizeRace(raceFile)
    local sync = Overlord.Sync
    if sync and sync.NormalizeRaceFileToken then
        return sync:NormalizeRaceFileToken(raceFile) or ""
    end
    return raceFile or ""
end

local function IsValidStoredContract(contract)
    if type(contract) ~= "table" or type(contract.id) ~= "string"
        or #contract.id == 0 or #contract.id > 64
        or not contract.id:match("^MB[%w%-]+$") then
        return false
    end
    if type(contract.poster) ~= "string" or not IsCompleteName(contract.poster)
        or type(contract.target) ~= "string" or not IsCompleteName(contract.target) then
        return false
    end
    if contract.targetFaction ~= "Alliance" and contract.targetFaction ~= "Horde" then
        return false
    end
    if contract.status ~= "open" and contract.status ~= "claimed"
        and contract.status ~= "approved" and contract.status ~= "paid"
        and contract.status ~= "cancelled" then
        return false
    end
    if (contract.status == "claimed" or contract.status == "approved"
        or contract.status == "paid")
        and (type(contract.claimer) ~= "string" or contract.claimer == "") then
        return false
    end
    contract.amountCopper = NormalizeAmount(contract.amountCopper)
    contract.createdAt = math.floor(tonumber(contract.createdAt) or 0)
    contract.updatedAt = math.floor(tonumber(contract.updatedAt) or 0)
    contract.claimedAt = math.floor(tonumber(contract.claimedAt) or 0)
    contract.approvedAt = math.floor(tonumber(contract.approvedAt) or 0)
    contract.paymentSentAt = math.floor(tonumber(contract.paymentSentAt) or 0)
    contract.codInvoiceSeenAt = math.floor(tonumber(contract.codInvoiceSeenAt) or 0)
    contract.paidAt = math.floor(tonumber(contract.paidAt) or 0)
    if contract.status == "claimed" and contract.claimedAt <= 0 then
        contract.claimedAt = contract.updatedAt
    end
    contract.epoch = math.floor(tonumber(contract.epoch) or 0)
    contract.pool = NormalizePool(contract.pool)
    return contract.amountCopper ~= nil
        and contract.createdAt > 0
        and contract.updatedAt >= contract.createdAt
        and IsCurrentCampaignEpoch(contract.epoch)
        and contract.pool == CurrentPool()
end

function Overlord.ManualBounty:GetRevision()
    return self.REVISION
end

function Overlord.ManualBounty:GetPositionRevision()
    return self.POSITION_REVISION
end

-- Source live reservee aux lecteurs cooperatifs (carte/minimap). Ne pas exposer
-- une copie materialisee ici : le registre peut contenir 1024 positions et les
-- vues doivent pouvoir les parcourir par tranches. La revision permet au lecteur
-- de publier une vue complete legerement stale puis de demander un rattrapage.
function Overlord.ManualBounty:GetTargetPositionsSourceForSlicedRead()
    return targetPositions, self.POSITION_REVISION
end

function Overlord.ManualBounty:FormatCopper(copper)
    copper = math.floor(tonumber(copper) or 0)
    if GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    return string.format("%dg", math.floor(copper / 10000))
end

function Overlord.ManualBounty:GetContract(id)
    if not id or id == "" then return nil end
    return contractsById[id]
end

function Overlord.ManualBounty:GetLocalSettlementEntry(id)
    return GetSettlementEntry(id)
end

function Overlord.ManualBounty:GetOutstandingExposureCopper()
    local ledger = EnsureSettlementLedger()
    local total = 0
    if not ledger then return total end
    for _, entry in pairs(ledger) do
        if IsValidSettlementEntry(entry)
            and (entry.status == "open" or entry.status == "claimed"
                or entry.status == "approved") then
            total = total + (tonumber(entry.amountCopper) or 0)
        end
    end
    return total
end

function Overlord.ManualBounty:GetOutstandingContractCount()
    local ledger = EnsureSettlementLedger()
    local count = 0
    if not ledger then return count end
    for _, entry in pairs(ledger) do
        if IsValidSettlementEntry(entry)
            and (entry.status == "open" or entry.status == "claimed"
                or entry.status == "approved") then
            count = count + 1
        end
    end
    return count
end

function Overlord.ManualBounty:GetClaimSettlementRemaining(contract)
    if not contract or contract.status ~= "claimed" then return 0 end
    local claimedAt = tonumber(contract.claimedAt) or tonumber(contract.updatedAt) or 0
    return math.max(0, claimedAt + self.CLAIM_SETTLEMENT_SEC - ServerNow())
end

function Overlord.ManualBounty:CanPreparePayment(contract)
    if not contract or contract.status ~= "approved" then
        return false, L.MB_ERR_NOT_APPROVED
    end
    local me = GetLocalFullName()
    if not NamesMatch(contract.poster, me) then return false, L.MB_ERR_NOT_OWNER end
    if not contract.claimer or contract.claimer == ""
        or not PaymentIdentitiesValid(contract.poster, contract.claimer) then
        return false, L.MB_ERR_PAYMENT_REALM
    end
    local entry = GetSettlementEntry(contract.id)
    if not entry or not SettlementIdentityMatches(entry, contract)
        or entry.status ~= "approved"
        or not NamesMatch(entry.claimer, contract.claimer) then
        return false, L.MB_ERR_LEDGER
    end
    if (tonumber(entry.paymentSentAt) or 0) > 0 then
        return false, L.MB_ERR_PAYMENT_ALREADY_SENT
    end
    if (tonumber(entry.codInvoiceSeenAt) or 0) > 0 then
        return false, L.MB_ERR_PAYMENT_ALREADY_SENT
    end
    return true, nil
end

-- Le chasseur ne possede jamais le registre financier du signataire. Il peut
-- seulement preparer une facture pour un snapshot approuve et signe par celui-ci.
-- La boite du signataire revalide ensuite la facture contre son registre local.
function Overlord.ManualBounty:CanPrepareCodPayment(contract)
    if not contract or contract.status ~= "approved" then
        return false, L.MB_ERR_NOT_APPROVED
    end
    local me = GetLocalFullName()
    if not NamesMatch(contract.claimer, me) then return false, L.MB_ERR_NOT_CLAIMER end
    if not contract.poster or contract.poster == ""
        or not PaymentIdentitiesValid(contract.poster, me) then
        return false, L.MB_ERR_PAYMENT_REALM
    end
    return true, nil
end

-- Validation autoritaire cote signataire. Un sujet qui ressemble a Overlord ne
-- suffit jamais : identite, montant, gagnant, statut et registre doivent concorder.
function Overlord.ManualBounty:ValidateCodInvoice(id, sender, amountCopper)
    local c = contractsById[id]
    if not c or c.status ~= "approved" then return false, L.MB_ERR_NOT_APPROVED end
    local poster = GetLocalFullName()
    if not NamesMatch(c.poster, poster) then return false, L.MB_ERR_NOT_OWNER end
    local entry = GetSettlementEntry(id)
    if not entry or not SettlementIdentityMatches(entry, c)
        or entry.status ~= "approved"
        or not NamesMatch(entry.claimer, c.claimer) then
        return false, L.MB_ERR_LEDGER
    end
    if not NamesMatch(sender, entry.claimer)
        or tonumber(amountCopper) ~= tonumber(entry.amountCopper) then
        return false, L.MB_ERR_COD_INVALID
    end
    if not PaymentIdentitiesValid(entry.poster, entry.claimer) then
        return false, L.MB_ERR_PAYMENT_REALM
    end
    if (tonumber(entry.paymentSentAt) or 0) > 0 then
        return false, L.MB_ERR_PAYMENT_ALREADY_SENT
    end
    return true, c
end

function Overlord.ManualBounty:RecordClaimCandidate(contract)
    if not contract or contract.status ~= "claimed" then return false end
    local entry = GetSettlementEntry(contract.id)
    if not entry or not SettlementIdentityMatches(entry, contract)
        or entry.status == "approved" or entry.status == "paid" then
        return false
    end
    CopySettlementFields(contract, entry)
    return true
end

local function RestoreLocalSettlementLedger(yieldWork)
    local ledger = EnsureSettlementLedger(yieldWork)
    if not ledger then return end
    local now = ServerNow()
    for id, entry in pairs(ledger) do
        if not IsValidSettlementEntry(entry) then
            ledger[id] = nil
        elseif entry.status == "open" and not IsCurrentCampaignEpoch(entry.epoch) then
            ledger[id] = nil
        elseif entry.status == "cancelled" then
            ledger[id] = nil
        elseif entry.status == "paid"
            and now - (tonumber(entry.paidAt) or tonumber(entry.updatedAt) or now)
                > Overlord.ManualBounty.FINANCIAL_HISTORY_SEC then
            ledger[id] = nil
        elseif entry.status == "claimed" or entry.status == "approved"
            or entry.status == "paid" or IsCurrentCampaignEpoch(entry.epoch) then
            local restored = CopySettlementFields(entry, {})
            restored.role = nil
            contractsById[id] = restored
            ReindexContract(restored)
        end
        if yieldWork then yieldWork() end
    end
end

function Overlord.ManualBounty:HasOpenContracts()
    return openContractCount > 0
end

function Overlord.ManualBounty:IsHunterPaymentCompatible(contract, hunterName)
    if not contract or not contract.poster or contract.poster == ""
        or not hunterName or hunterName == "" then
        return false
    end
    return PaymentIdentitiesValid(contract.poster, hunterName)
end

function Overlord.ManualBounty:GetOpenContractsForTarget(targetName)
    local out = {}
    if not targetName or targetName == "" then return out end
    if IsCompleteName(targetName) then
        local key = NameDedupKey(targetName)
        local bucket = key and openContractsByTarget[key]
        if bucket then
            for id in pairs(bucket) do
                local c = contractsById[id]
                if c and IsCurrentCampaignEpoch(c.epoch)
                    and c.status == "open" and TargetMatchesKill(c.target, targetName) then
                    out[#out + 1] = c
                end
            end
        end
        return out
    end

    -- Le journal d'honneur peut omettre le royaume. On n'accepte le nom court
    -- que s'il designe une seule cible parmi les royaumes connectes.
    local matchedTargetKey
    for contractId in pairs(indexedTargetByContract) do
        local c = contractsById[contractId]
        if c and c.status == "open" and IsCurrentCampaignEpoch(c.epoch)
            and TargetMatchesKill(c.target, targetName) then
            local targetKey = NameDedupKey(c.target)
            if matchedTargetKey and matchedTargetKey ~= targetKey then
                wipe(out)
                return out
            end
            matchedTargetKey = targetKey
            out[#out + 1] = c
        end
    end
    return out
end

function Overlord.ManualBounty:IsLocalPlayerTargeted()
    local name = GetLocalFullName()
    if not name or name == "" then return false end
    local key = NameDedupKey(name)
    local summary = key and targetSummaryState.byTarget[key]
    return summary ~= nil and summary.total > 0
end

function Overlord.ManualBounty:GetTargetFaction(targetName)
    local key = NameDedupKey(targetName)
    local bucket = key and openContractsByTarget[key]
    local summary = key and targetSummaryState.byTarget[key]
    if summary then
        -- Etat incoherent ancien : choix stable, independant de l'ordre de pairs().
        if summary.Alliance > 0 then return "Alliance" end
        if summary.Horde > 0 then return "Horde" end
    end
    if bucket or (type(targetName) == "string"
        and IsCompleteName(targetName)) then
        return nil
    end
    -- Compatibilite uniquement pour les anciens noms courts ambigus. Les PM de
    -- position acceptes ont deja un bucket exact et ne passent jamais par ce scan.
    local contracts = self:GetOpenContractsForTarget(targetName)
    for i = 1, #contracts do
        local faction = contracts[i] and contracts[i].targetFaction
        if faction == "Alliance" or faction == "Horde" then
            return faction
        end
    end
    return nil
end

function Overlord.ManualBounty:HasLocalClaimableContractForTarget(targetName)
    if not targetName or targetName == "" then
        return false
    end

    -- Chemin carte/minimap : lecture O(1), sans allocation ni parcours du bucket.
    local key = NameDedupKey(targetName)
    local bucket = key and openContractsByTarget[key]
    if bucket then
        local summary = targetSummaryState.byTarget[key]
        return targetSummaryState.claimableValid
            and summary ~= nil and summary.claimable > 0
    end
    if type(targetName) == "string" and IsCompleteName(targetName) then
        return false
    end
    -- Repli pour un ancien paquet sans royaume (ambiguite inter-royaumes).
    local hunterName = GetLocalFullName()
    local hunterFaction = Overlord.PlayerFaction
    if not hunterName or hunterName == ""
        or NamesMatch(hunterName, targetName)
        or (hunterFaction ~= "Alliance" and hunterFaction ~= "Horde") then
        return false
    end
    local contracts = self:GetOpenContractsForTarget(targetName)
    for i = 1, #contracts do
        local contract = contracts[i]
        if contract and contract.targetFaction ~= hunterFaction
            and self:IsHunterPaymentCompatible(contract, hunterName) then return true end
    end
    return false
end

function Overlord.ManualBounty:OnPlayerIdentityChanged()
    local changed = CaptureTargetSummaryContext()
    if not changed and targetSummaryState.claimableValid then return false end
    targetSummaryState.claimableValid = false
    if not StartTargetSummaryRebuild() and openContractCount == 0 then
        targetSummaryState.claimableValid = true
    end
    return true
end

local function IsOwnedActiveContract(contract)
    if not contract or not contract.id then return false end
    local me = GetLocalFullName()
    return me ~= nil and me ~= ""
        and NamesMatch(contract.poster, me)
        and IsCurrentCampaignEpoch(contract.epoch)
        and NormalizePool(contract.pool) == CurrentPool()
        and (contract.status == "open" or contract.status == "claimed"
            or contract.status == "approved")
end

local function IsKnownSyncContract(contract)
    if not contract or not contract.id then return false end
    local me = GetLocalFullName()
    return me ~= nil and me ~= ""
        and not NamesMatch(contract.poster, me)
        and IsCurrentCampaignEpoch(contract.epoch)
        and NormalizePool(contract.pool) == CurrentPool()
        and (contract.status == "open" or contract.status == "claimed"
            or contract.status == "approved")
end

local function IsSrRelevantContract(contract)
    if not contract or not contract.id then return false end
    local me = GetLocalFullName()
    if not me or me == "" or not IsCurrentCampaignEpoch(contract.epoch)
        or NormalizePool(contract.pool) ~= CurrentPool() then return false end
    return NamesMatch(contract.poster, me)
        or (contract.status == "claimed" and NamesMatch(contract.claimer, me))
end

local function ReindexMaintenanceContract(contract)
    if not contract or not contract.id then return end
    DenseIndexAdd(maintenanceContractIds, maintenanceContractPositions, contract.id)
    if IsOwnedActiveContract(contract) then
        DenseIndexAdd(
            ownedActiveContractIds, ownedActiveContractPositions, contract.id)
    else
        DenseIndexRemove(
            ownedActiveContractIds, ownedActiveContractPositions, contract.id)
    end
    if IsKnownSyncContract(contract) then
        DenseIndexAdd(knownSyncContractIds, knownSyncContractPositions, contract.id)
    else
        DenseIndexRemove(knownSyncContractIds, knownSyncContractPositions, contract.id)
    end
    if IsSrRelevantContract(contract) then
        DenseIndexAdd(srRelevantContractIds, srRelevantContractPositions, contract.id)
    else
        DenseIndexRemove(srRelevantContractIds, srRelevantContractPositions, contract.id)
    end
    if ArmMaintenance and Overlord.ManualBounty._initialized then
        ArmMaintenance(MAINTENANCE_INTERVAL_SEC)
    end
end

local function ForgetMaintenanceContract(contractId)
    DenseIndexRemove(
        maintenanceContractIds, maintenanceContractPositions, contractId)
    DenseIndexRemove(
        ownedActiveContractIds, ownedActiveContractPositions, contractId)
    DenseIndexRemove(knownSyncContractIds, knownSyncContractPositions, contractId)
    DenseIndexRemove(srRelevantContractIds, srRelevantContractPositions, contractId)
end

function Overlord.ManualBounty:GetTargetPositions(rows)
    rows = rows or {}
    wipe(rows)
    local now = GetTime()
    for key, entry in pairs(targetPositions) do
        local age = now - (entry.receivedAt or 0)
        if age <= self.POSITION_STALE_SEC and openContractsByTarget[key]
            and self:HasLocalClaimableContractForTarget(entry.name) then
            rows[#rows + 1] = entry
        end
    end
    return rows
end

function Overlord.ManualBounty:ApplyTargetPosition(name, mapX, mapY, mapID, sentAt)
    local key = NameDedupKey(name)
    if not key or not openContractsByTarget[key] then return false end
    mapX = tonumber(mapX)
    mapY = tonumber(mapY)
    mapID = tonumber(mapID)
    sentAt = tonumber(sentAt)
    if not mapX or not mapY or not mapID or not sentAt then return false end
    if mapX < 0 or mapX > 100 or mapY < 0 or mapY > 100 or mapID <= 0 then return false end
    local previous = targetPositions[key]
    if previous and sentAt < (previous.sentAt or 0) then return false end
    local faction = self:GetTargetFaction(name)
    if not faction then return false end
    local changed = not previous
        or previous.mapX ~= mapX
        or previous.mapY ~= mapY
        or previous.mapID ~= mapID
        or previous.faction ~= faction
        or previous.name ~= name
    local entry = previous or {}
    entry.name = name
    entry.faction = faction
    entry.mapX = mapX
    entry.mapY = mapY
    entry.mapID = mapID
    entry.sentAt = sentAt
    entry.receivedAt = GetTime()
    targetPositions[key] = entry
    DenseIndexAdd(maintenancePositionKeys, maintenancePositionKeyPositions, key)
    if ArmMaintenance and self._initialized then
        ArmMaintenance(MAINTENANCE_INTERVAL_SEC)
    end
    if changed then
        QueuePositionRevision(true)
    end
    return true
end

function Overlord.ManualBounty:GetSortedContracts(yieldWork)
    local rows = {}
    local ledger = EnsureSettlementLedger()
    for _, c in pairs(contractsById) do
        if yieldWork then yieldWork() end
        local entry = c and ledger and ledger[c.id]
        if entry and entry.role ~= "poster" then entry = nil end
        local historicalFinancial = entry and SettlementIdentityMatches(entry, c)
            and (c.status == "claimed" or c.status == "approved" or c.status == "paid")
        if c and c.status ~= "cancelled"
            and (IsCurrentCampaignEpoch(c.epoch) or historicalFinancial) then
            rows[#rows + 1] = c
        end
    end
    return SortRowsWithYield(rows, SortContracts, yieldWork)
end

function Overlord.ManualBounty:GetTargetRevision()
    local lb = Overlord.Leaderboard
    local leaderboardRevision = lb and lb.GetTargetRevision
        and lb:GetTargetRevision() or -1
    local sync = Overlord.Sync
    -- Ne jamais scanner C_Club pendant OnShow : la revision courante est lisible
    -- immediatement et le rafraichissement atomique notifiera l'UI une fois termine.
    if sync and sync.RequestCommunityMemberCharactersRefresh then
        sync:RequestCommunityMemberCharactersRefresh(false, 30)
    end
    local communityRevision = sync and sync.GetCommunityMemberCharactersRevision
        and sync:GetCommunityMemberCharactersRevision() or -1
    return tostring(leaderboardRevision) .. ":" .. tostring(communityRevision)
end

function Overlord.ManualBounty:GetKnownEnemyTargets(yieldWork)
    local lb = Overlord.Leaderboard
    local sync = Overlord.Sync
    local rows = {}
    local candidateNames = {}
    local communityCandidates = {}
    local function RegisterCandidate(name, communityMeta)
        if not name or name == "" then return end
        local dk = NameDedupKey(name)
        if not dk then return end
        local previous = candidateNames[dk]
        if previous and lb and lb.ChooseRicherPlayerName then
            candidateNames[dk] = lb:ChooseRicherPlayerName(previous, name)
        elseif not previous then
            candidateNames[dk] = name
        end
        if communityMeta then communityCandidates[dk] = communityMeta end
    end

    -- La liste n'a besoin ni des totaux tries ni du classement guildes. Lire les cles
    -- brutes evite de reconstruire tout EnsureDisplayCache a l'ouverture du panneau.
    if lb then
        for name, kills in pairs(lb.kills or {}) do
            if yieldWork then yieldWork() end
            if (tonumber(kills) or 0) > 0 then RegisterCandidate(name) end
        end
        for name, count in pairs(lb.captureCount or {}) do
            if yieldWork then yieldWork() end
            if (tonumber(count) or 0) > 0 then RegisterCandidate(name) end
        end
        for name, zones in pairs(lb.captures or {}) do
            if yieldWork then yieldWork() end
            if type(zones) == "table" and #zones > 0 then RegisterCandidate(name) end
        end
    end

    local communityCharacters = sync and sync.GetCommunityMemberCharacters
        and sync:GetCommunityMemberCharacters(false, 30) or {}
    for i = 1, #communityCharacters do
        if yieldWork then yieldWork() end
        local entry = communityCharacters[i]
        RegisterCandidate(entry and entry.name, entry)
    end

    -- Un seul index O(P) pour toute la liste. Les anciens GetExportPlayerMeta/Guild
    -- pouvaient chacun rescanner et retrier playerInfo pour chaque membre de Communaute.
    local metaIndex = lb and lb.EnsureDedupMetaIndex and lb:EnsureDedupMetaIndex() or nil
    local function IndexedMeta(name, dk)
        local indexed = metaIndex and dk and metaIndex[dk:lower()] or nil
        if indexed then
            return indexed.class or "", indexed.faction or "", indexed.race or "",
                tonumber(indexed.raceSex) or 0, indexed.guild or ""
        end
        local info = lb and lb.GetPlayerInfo and lb:GetPlayerInfo(name) or nil
        if not info then return "", "", "", 0, "" end
        return info.class or "", info.faction or "", info.race or "",
            tonumber(info.raceSex) or 0, info.guild or ""
    end

    for _, name in pairs(candidateNames) do
        if yieldWork then yieldWork() end
        local dk = NameDedupKey(name)
        local communityMeta = dk and communityCandidates[dk]
        local class, faction, race, raceSex, guild = IndexedMeta(name, dk)
        if communityMeta and communityMeta.faction then
            faction = communityMeta.faction
            local communityRace = communityMeta.race or ""
            local communitySex = math.floor(tonumber(communityMeta.raceSex) or 0)
            if communityRace ~= "" then
                if communityRace ~= race then raceSex = 0 end
                race = communityRace
            end
            if communitySex == 2 or communitySex == 3 then
                raceSex = communitySex
            end
        end
        local realm = ""
        if IsEnemyFaction(faction) and IsCompleteName(name) then
            rows[#rows + 1] = {
                name = name,
                class = class or "",
                faction = faction,
                race = SanitizeRace(race),
                raceSex = raceSex or 0,
                guild = SanitizeGuild(guild),
                realm = realm,
                communityEligible = communityMeta ~= nil,
            }
        end
    end
    return SortRowsWithYield(rows, SortTargets, yieldWork)
end

-- Vue bornee reservee au protocole. L'index est maintenu sur StoreContract :
-- ni scan du catalogue distant, ni tri global sur le heartbeat de maintenance.
function Overlord.ManualBounty:GetOwnedActiveContractsForSync(maxContracts)
    local rows = {}
    local limit = math.min(32, math.max(1, math.floor(tonumber(maxContracts) or 32)))
    for i = 1, math.min(limit, #ownedActiveContractIds) do
        local contract = contractsById[ownedActiveContractIds[i]]
        if contract and IsOwnedActiveContract(contract) then
            rows[#rows + 1] = contract
        end
    end
    return rows
end

-- Contrats distants susceptibles d'etre devenus annules/payes pendant notre
-- absence. Le panneau en demande l'etat exact a leur signataire, sans replay global.
function Overlord.ManualBounty:GetKnownContractsForSync(maxContracts)
    local rows = {}
    local limit = math.min(32, math.max(1, math.floor(tonumber(maxContracts) or 32)))
    local count = #knownSyncContractIds
    if count == 0 then
        knownSyncCursor = 0
        return rows
    end
    local start = (knownSyncCursor % count) + 1
    local scanned = 0
    while scanned < count and #rows < limit do
        local index = ((start + scanned - 1) % count) + 1
        local contract = contractsById[knownSyncContractIds[index]]
        if contract and IsKnownSyncContract(contract) then rows[#rows + 1] = contract end
        scanned = scanned + 1
    end
    knownSyncCursor = (start - 1 + math.max(1, scanned)) % count
    return rows
end

function Overlord.ManualBounty:BuildTargetMeta(name, confirmedTarget)
    local lb = Overlord.Leaderboard
    local sync = Overlord.Sync
    if not name or name == "" then return nil, L.MB_ERR_INCOMPLETE_META end
    if sync and sync.NormalizeContributorFullName then
        name = sync:NormalizeContributorFullName(name)
    end
    if not IsCompleteName(name) then
        return nil, L.MB_ERR_NO_REALM
    end
    local confirmedMeta = type(confirmedTarget) == "table"
        and NamesMatch(confirmedTarget.name, name) and confirmedTarget or nil
    local communityMeta = sync and sync.GetCommunityMemberCharacter
        and sync:GetCommunityMemberCharacter(name, false, 30) or nil
    local class, faction = "", nil
    local race, raceSex = "", 0
    if lb and lb.GetExportPlayerMeta then
        class, faction = lb:GetExportPlayerMeta(name)
    end
    if communityMeta and communityMeta.faction then
        faction = communityMeta.faction
        name = communityMeta.name or name
    end
    if confirmedMeta then
        if class == "" then class = confirmedMeta.class or "" end
        if not faction or faction == "" then faction = confirmedMeta.faction end
    end
    if lb and lb.GetExportPlayerRace then
        race, raceSex = lb:GetExportPlayerRace(name)
    end
    -- Communaute gagne toujours si elle connait la race (evite BloodElf/Orc stales
    -- quand le roster n'avait pas encore resolu Haranir au moment du fallback LB).
    if communityMeta and communityMeta.race and communityMeta.race ~= "" then
        race = communityMeta.race
        local communitySex = math.floor(tonumber(communityMeta.raceSex) or 0)
        if communitySex == 2 or communitySex == 3 then
            raceSex = communitySex
        end
    elseif communityMeta then
        if (tonumber(raceSex) or 0) == 0 then
            raceSex = communityMeta.raceSex or 0
        end
    end
    if confirmedMeta then
        if not race or race == "" then race = confirmedMeta.race or "" end
        if (tonumber(raceSex) or 0) == 0 then
            raceSex = confirmedMeta.raceSex or 0
        end
    end
    local guild = lb and lb.GetExportPlayerGuild and lb:GetExportPlayerGuild(name) or ""
    if guild == "" and confirmedMeta then guild = confirmedMeta.guild or "" end
    race = SanitizeRace(race)
    guild = SanitizeGuild(guild)
    local realm = ""
    if not IsEnemyFaction(faction) then
        return nil, L.MB_ERR_NOT_ENEMY
    end
    return {
        name = name,
        class = class or "",
        faction = faction or "",
        race = race,
        raceSex = raceSex or 0,
        guild = guild,
        realm = realm,
    }, nil
end

local function StoreContract(contract)
    if not contract or not contract.id then return end
    local hadOpen = openContractCount > 0
    contractsById[contract.id] = contract
    TrackRemoteCatalogContract(contract)
    ReindexContract(contract)
    ReindexMaintenanceContract(contract)
    local db = EnsureDb()
    if db then
        db[contract.id] = contract
    end
    BumpRevision((openContractCount > 0) ~= hadOpen)
    if Overlord.ManualBounty._initialized and RefreshLocalTargetTracking then
        RefreshLocalTargetTracking()
    end
    if Overlord.ManualBounty._initialized
        and Overlord.ManualBounty:IsLocalPlayerTargeted()
        and Overlord.General and Overlord.General.IsLocalHolder
        and Overlord.General:IsLocalHolder()
        and Overlord.General.TryRelease then
        Overlord.General:TryRelease(false)
    end
end

-- Defini apres StoreContract pour capturer son local, pas un global inexistant.
function Overlord.ManualBounty:RecordCodInvoiceSeen(id, sender, amountCopper)
    local ok, contractOrError = self:ValidateCodInvoice(id, sender, amountCopper)
    if not ok then return false, contractOrError end
    local c = contractOrError
    local entry = GetSettlementEntry(id)
    if (tonumber(entry.codInvoiceSeenAt) or 0) > 0 then return true, nil end
    local now = ServerNow()
    c.codInvoiceSeenAt = now
    entry.codInvoiceSeenAt = now
    StoreContract(c)
    return true, nil
end

local function NotifyLocalTargetedContract(contract)
    local localName = GetLocalFullName()
    if not localName or not NamesMatch(contract.target, localName) then return end
    if Overlord.PrintNotification and L.MB_TARGETED then
        Overlord:PrintNotification(string.format(
            L.MB_TARGETED,
            Overlord.ManualBounty:FormatCopper(contract.amountCopper),
            ShortName(contract.poster)
        ))
    end
    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("gold_buff")
    end
end

function Overlord.ManualBounty:CreateContract(targetName, amountCopper, confirmedTarget)
    if not Overlord.InActiveFront then
        return nil, L.MB_ERR_NOT_ON_FRONT
    end
    local poster = GetLocalFullName()
    if not poster or poster == "" then
        return nil, L.MB_ERR_POSTER
    end
    if not IsCompleteName(poster) then
        return nil, L.MB_ERR_NO_REALM
    end
    local amount = NormalizeAmount(amountCopper)
    if not amount then
        return nil, L.MB_ERR_AMOUNT
    end
    local meta, err = self:BuildTargetMeta(targetName, confirmedTarget)
    if not meta then
        return nil, err or L.MB_ERR_INCOMPLETE_META
    end
    local ledger = EnsureSettlementLedger()
    for _, contract in pairs(ledger or {}) do
        if contract and (contract.status == "open" or contract.status == "claimed"
            or contract.status == "approved")
            and NamesMatch(contract.target, meta.name) then
            return nil, L.MB_ERR_DUPLICATE
        end
    end
    if self:GetOutstandingContractCount() >= self.MAX_OPEN_PER_POSTER then
        return nil, L.MB_ERR_MAX_OPEN
    end
    local playerGuid = UnitGUID and UnitGUID("player")
    if not playerGuid or playerGuid == "" then
        return nil, L.MB_ERR_POSTER
    end
    nextLocalId = nextLocalId + 1
    local id = string.format(
        "MB%s-%d-%d",
        playerGuid:gsub("[^%w]", ""),
        ServerNow(),
        nextLocalId
    )
    local now = ServerNow()
    local pool = CurrentPool()
    if not pool then return nil, L.MB_ERR_SYNC_UNAVAILABLE end
    local contract = {
        id = id,
        poster = poster,
        posterRealm = "",
        target = meta.name,
        targetRealm = meta.realm,
        targetRace = meta.race,
        targetRaceSex = meta.raceSex,
        targetGuild = meta.guild,
        targetFaction = meta.faction,
        amountCopper = amount,
        status = "open",
        claimer = "",
        createdAt = now,
        updatedAt = now,
        epoch = CurrentCampaignEpoch(),
        pool = pool,
        versionActor = poster,
    }
    if not Overlord.ManualBountySync
        or not Overlord.ManualBountySync.CanBroadcast
        or not Overlord.ManualBountySync:CanBroadcast() then
        return nil, L.MB_ERR_SYNC_UNAVAILABLE
    end
    if not Overlord.ManualBountySync.BuildPBPayload
        or not Overlord.ManualBountySync:BuildPBPayload(contract) then
        return nil, L.MB_ERR_SYNC_PAYLOAD
    end
    if not RegisterLocalSignedContract(contract) then
        return nil, L.MB_ERR_LEDGER
    end
    StoreContract(contract)
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastPost then
        Overlord.ManualBountySync:BroadcastPost(contract)
    end
    if Overlord.PrintNotification and L.MB_POSTED then
        Overlord:PrintNotification(string.format(L.MB_POSTED, meta.name, self:FormatCopper(amount)))
    end
    Dbg("post " .. id .. " -> " .. meta.name)
    return contract, nil
end

function Overlord.ManualBounty:ApplyRemoteContract(contract, allowOverwrite)
    if not contract or not contract.id then return false end
    if NormalizePool(contract.pool) ~= CurrentPool()
        or not IsCurrentCampaignEpoch(contract.epoch) then
        return false
    end
    local prev = contractsById[contract.id]
    if prev and not allowOverwrite then return false end
    if prev and contract.status == "open" and prev.status ~= "open" then return false end
    if not prev and IsRemoteCatalogContract(contract)
        and remoteCatalogContractCount >= GetRemoteContractLimit(contract) then
        return false
    end
    StoreContract(contract)
    if not prev and contract.status == "open" then
        NotifyLocalTargetedContract(contract)
    end
    return true
end

function Overlord.ManualBounty:CancelContract(id)
    local c = contractsById[id]
    if not c or (c.status ~= "open" and c.status ~= "claimed")
        or (c.status == "open" and not IsCurrentCampaignEpoch(c.epoch)) then
        return false, L.MB_ERR_NOT_OPEN
    end
    local poster = GetLocalFullName()
    if not NamesMatch(c.poster, poster) then
        return false, L.MB_ERR_NOT_OWNER
    end
    local entry = GetSettlementEntry(id)
    if not entry or not SettlementIdentityMatches(entry, c) then
        return false, L.MB_ERR_LEDGER
    end
    c.status = "cancelled"
    c.claimer = ""
    c.updatedAt = ServerNow()
    c.versionActor = poster
    StoreContract(c)
    UpdateSettlementEntry(c, "cancelled")
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastCancel then
        if IsCurrentCampaignEpoch(c.epoch) then
            Overlord.ManualBountySync:BroadcastCancel(c)
        end
    end
    if Overlord.PrintNotification and L.MB_CANCELLED then
        Overlord:PrintNotification(string.format(L.MB_CANCELLED, c.target))
    end
    return true, nil
end

function Overlord.ManualBounty:AuthorizePayment(id)
    local c = contractsById[id]
    if not c or c.status ~= "claimed" then
        return false, L.MB_ERR_NOT_CLAIMED
    end
    local poster = GetLocalFullName()
    if not NamesMatch(c.poster, poster) then return false, L.MB_ERR_NOT_OWNER end
    local entry = GetSettlementEntry(id)
    if not entry or not SettlementIdentityMatches(entry, c)
        or entry.status ~= "claimed" or not NamesMatch(entry.claimer, c.claimer) then
        return false, L.MB_ERR_LEDGER
    end
    local remaining = self:GetClaimSettlementRemaining(c)
    if remaining > 0 then
        return false, string.format(L.MB_ERR_CLAIM_SETTLING, math.ceil(remaining))
    end
    local now = ServerNow()
    c.status = "approved"
    c.approvedAt = now
    c.paymentSentAt = nil
    c.codInvoiceSeenAt = nil
    c.updatedAt = now
    c.versionActor = poster
    StoreContract(c)
    UpdateSettlementEntry(c, "approved")
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastPost then
        if IsCurrentCampaignEpoch(c.epoch) then
            Overlord.ManualBountySync:BroadcastPost(c)
        end
    end
    if Overlord.PrintNotification and L.MB_APPROVED then
        Overlord:PrintNotification(string.format(L.MB_APPROVED, c.claimer, c.target))
    end
    return true, nil
end

function Overlord.ManualBounty:RecordPaymentMailSent(id)
    local c = contractsById[id]
    if not c then return false, L.MB_ERR_NOT_APPROVED end
    local ok, err = self:CanPreparePayment(c)
    if not ok then return false, err end
    local now = ServerNow()
    c.paymentSentAt = now
    StoreContract(c)
    UpdateSettlementEntry(c, "approved")
    return true, nil
end

function Overlord.ManualBounty:MarkPaid(id)
    local c = contractsById[id]
    if not c or c.status ~= "approved" then
        return false, L.MB_ERR_NOT_APPROVED
    end
    local poster = GetLocalFullName()
    if not NamesMatch(c.poster, poster) then
        return false, L.MB_ERR_NOT_OWNER
    end
    local entry = GetSettlementEntry(id)
    if not entry or not SettlementIdentityMatches(entry, c)
        or entry.status ~= "approved" then
        return false, L.MB_ERR_LEDGER
    end
    if (tonumber(entry.paymentSentAt) or 0) <= 0
        and (tonumber(entry.codInvoiceSeenAt) or 0) <= 0 then
        return false, L.MB_ERR_PAYMENT_NOT_SENT
    end
    c.status = "paid"
    c.paidAt = ServerNow()
    c.updatedAt = c.paidAt
    c.versionActor = poster
    StoreContract(c)
    UpdateSettlementEntry(c, "paid")
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastPaid then
        if IsCurrentCampaignEpoch(c.epoch) then
            Overlord.ManualBountySync:BroadcastPaid(c)
        end
    end
    if Overlord.PrintNotification and L.MB_PAID then
        Overlord:PrintNotification(string.format(L.MB_PAID, c.target))
    end
    return true, nil
end

function Overlord.ManualBounty:ClaimContract(id, claimerName, victimName)
    local c = contractsById[id]
    if not c or c.status ~= "open" then return false end
    if not IsCurrentCampaignEpoch(c.epoch) then return false end
    if not TargetMatchesKill(c.target, victimName) then return false end
    if not claimerName or claimerName == "" then return false end
    if NamesMatch(claimerName, c.target) then return false end
    if not PaymentIdentitiesValid(c.poster, claimerName) then return false end
    c.status = "claimed"
    c.claimer = claimerName
    c.claimedAt = ServerNow()
    c.approvedAt = nil
    c.paymentSentAt = nil
    c.codInvoiceSeenAt = nil
    c.updatedAt = c.claimedAt
    c.versionActor = claimerName
    StoreContract(c)
    return true
end

function Overlord.ManualBounty:OnLocalKill(killerName, victimName)
    -- Un contrat n'est lie ni au front ni a la zone ou il a ete signe : toute
    -- carte de front Overlord active peut fournir le kill de reclamation.
    if not Overlord.InActiveFront then return end
    if not victimName or victimName == "?" then return end
    local claimerName = GetLocalFullName()
    if not claimerName or claimerName == "" or not IsCompleteName(claimerName) then
        Dbg("claim refuse: nom local canonique indisponible")
        return
    end
    local open = self:GetOpenContractsForTarget(victimName)
    if #open == 0 then return end
    local selected
    local blockedByRealm = false
    for i = 1, #open do
        local c = open[i]
        if c then
            if not PaymentIdentitiesValid(c.poster, claimerName) then
                blockedByRealm = true
            elseif not selected
                or (c.amountCopper or 0) > (selected.amountCopper or 0)
                or ((c.amountCopper or 0) == (selected.amountCopper or 0)
                    and (c.createdAt or 0) < (selected.createdAt or 0))
                or ((c.amountCopper or 0) == (selected.amountCopper or 0)
                    and (c.createdAt or 0) == (selected.createdAt or 0)
                    and (c.id or "") < (selected.id or "")) then
                selected = c
            end
        end
    end

    -- Un kill ne reclame qu'un contrat. La plus grosse prime compatible passe
    -- d'abord, puis la plus ancienne, pour eviter un paiement cumule inattendu.
    local claimed = selected and self:ClaimContract(selected.id, claimerName, victimName)
    if claimed and Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastClaim then
        Overlord.ManualBountySync:BroadcastClaim(selected.id, claimerName, selected.target)
    end
    if claimed and Overlord.PrintNotification and L.MB_CLAIMED then
        Overlord:PrintNotification(string.format(
            L.MB_CLAIMED, claimerName, selected.target, self:FormatCopper(selected.amountCopper)))
    end
    if claimed and Overlord.LifetimeStats
        and Overlord.LifetimeStats.AddManualBountyContracts then
        Overlord.LifetimeStats:AddManualBountyContracts(1)
    end
    if claimed and Overlord.ManualBountyUI and Overlord.ManualBountyUI.RequestRefresh then
        Overlord.ManualBountyUI:RequestRefresh()
    elseif not selected and blockedByRealm and Overlord.PrintNotification then
        Overlord:PrintNotification(L.MB_ERR_COD_REALM)
    end
end

function Overlord.ManualBounty:GetLocalPosition()
    if not Overlord.InActiveFront or Overlord.InstanceSuspended then return nil end
    local sourceMapID = C_Map.GetBestMapForUnit("player")
    if not sourceMapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(sourceMapID, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or not y then return nil end
    local mapID = sourceMapID
    if Overlord.General and Overlord.General.NormalizeGeneralMapID then
        mapID = Overlord.General.NormalizeGeneralMapID(sourceMapID)
    end
    if mapID ~= sourceMapID then
        local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, sourceMapID, mapID)
        if not ok or not minX or not maxX or not minY or not maxY
            or maxX <= minX or maxY <= minY then
            return nil
        end
        x = minX + (maxX - minX) * x
        y = minY + (maxY - minY) * y
    end
    return x * 100, y * 100, mapID
end

function Overlord.ManualBounty:BroadcastLocalTargetPosition()
    if not self:IsLocalPlayerTargeted() then return end
    local name = GetLocalFullName()
    local mapX, mapY, mapID = self:GetLocalPosition()
    if not name or not mapX or not mapY or not mapID then return end
    local sentAt = ServerNow()
    local pool = CurrentPool()
    if not pool then return end
    self:ApplyTargetPosition(name, mapX, mapY, mapID, sentAt)
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastPosition then
        Overlord.ManualBountySync:BroadcastPosition(name, mapX, mapY, mapID, pool, sentAt)
    end
end

function Overlord.ManualBounty:StartPositionTicker()
    if positionTicker then return end
    self:BroadcastLocalTargetPosition()
    positionTicker = C_Timer.NewTicker(self.POSITION_INTERVAL, function()
        if not Overlord.InActiveFront or Overlord.InstanceSuspended
            or not Overlord.ManualBounty:IsLocalPlayerTargeted() then
            Overlord.ManualBounty:StopPositionTicker()
            return
        end
        Overlord.ManualBounty:BroadcastLocalTargetPosition()
    end)
end

function Overlord.ManualBounty:StopPositionTicker()
    if positionTicker then
        positionTicker:Cancel()
        positionTicker = nil
    end
end

RefreshLocalTargetTracking = function()
    if Overlord.InActiveFront and not Overlord.InstanceSuspended
        and Overlord.ManualBounty:IsLocalPlayerTargeted() then
        Overlord.ManualBounty:StartPositionTicker()
    else
        Overlord.ManualBounty:StopPositionTicker()
    end
    Overlord.ManualBounty:RefreshWorldMapPins()
end

function Overlord.ManualBounty:OnEnterFront()
    C_Timer.After(0, function()
        if Overlord.ManualBounty then
            RefreshLocalTargetTracking()
        end
        if Overlord.ManualBountySync and Overlord.ManualBountySync.ResumeContractQueue then
            Overlord.ManualBountySync:ResumeContractQueue()
        end
    end)
end

function Overlord.ManualBounty:OnLeaveFront()
    self:StopPositionTicker()
end

function Overlord.ManualBounty:OnCampaignReset()
    self:StopPositionTicker()
    if maintenanceTimer then
        maintenanceTimer:Cancel()
        maintenanceTimer = nil
    end
    CancelQueuedPositionRevision()
    wipe(contractsById)
    wipe(remoteCatalogContractIds)
    wipe(openContractsByTarget)
    wipe(indexedTargetByContract)
    wipe(targetPositions)
    wipe(maintenanceContractIds)
    wipe(maintenanceContractPositions)
    wipe(ownedActiveContractIds)
    wipe(ownedActiveContractPositions)
    wipe(knownSyncContractIds)
    wipe(knownSyncContractPositions)
    wipe(srRelevantContractIds)
    wipe(srRelevantContractPositions)
    wipe(maintenancePositionKeys)
    wipe(maintenancePositionKeyPositions)
    maintenanceContractCursor = 1
    maintenancePositionCursor = 1
    maintenanceContractSweepRemaining = 0
    maintenancePositionSweepRemaining = 0
    maintenanceSweepActive = false
    maintenanceRunning = false
    openContractCount = 0
    remoteCatalogContractCount = 0
    srContractCursor = 0
    knownSyncCursor = 0
    ResetTargetSummaryIndex()
    local db = EnsureDb()
    if db then wipe(db) end
    -- Les caches de campagne repartent de zero, mais les reglements locaux
    -- reclames ou autorises sont restaures depuis le registre du signataire.
    RestoreLocalSettlementLedger()
    self.REVISION = self.REVISION + 1
    self.POSITION_REVISION = self.POSITION_REVISION + 1
    self:RefreshWorldMapPins()
    if self._initialized and RefreshLocalTargetTracking then
        RefreshLocalTargetTracking()
    end
end

function Overlord.ManualBounty:RefreshWorldMapPins()
    if mapRefreshPending then return end
    mapRefreshPending = true
    C_Timer.After(MAP_REFRESH_DEBOUNCE, function()
        mapRefreshPending = false
        local map = Overlord.ManualBountyMap
        if not map or not IsWorldMapVisible() then return end
        if map.Refresh then map:Refresh() end
        if map.RefreshContinent then map:RefreshContinent() end
    end)
end

-- PLAYER_DEAD fournit l'attestation independante qui manque au PK du chasseur.
-- Elle ne change aucun contrat localement : les receveurs attendent les deux messages.
function Overlord.ManualBounty:OnLocalDeath(killerName)
    if not Overlord.InActiveFront or not killerName or killerName == "" then return end
    local victimName = GetLocalFullName()
    if not victimName or victimName == "" or NamesMatch(killerName, victimName) then return end
    local open = self:GetOpenContractsForTarget(victimName)
    if #open == 0 then return end
    local posters = {}
    local seen = {}
    for i = 1, #open do
        local poster = open[i] and open[i].poster
        local key = poster and NameDedupKey(poster)
        if key and not seen[key] then
            seen[key] = true
            posters[#posters + 1] = poster
        end
    end
    if Overlord.ManualBountySync and Overlord.ManualBountySync.BroadcastDeathProof then
        Overlord.ManualBountySync:BroadcastDeathProof(killerName, victimName, posters)
    end
end

function Overlord.ManualBounty:DebugPlaceTest()
    local name = GetLocalFullName()
    if not name or name == "" then return false end
    local now = ServerNow()
    StoreContract({
        id = DEBUG_CONTRACT_ID,
        poster = "Debug-Overlord",
        posterRealm = "Overlord",
        target = name,
        targetRealm = "",
        targetRace = "Human",
        targetRaceSex = 2,
        targetGuild = "Overlord",
        targetFaction = Overlord.PlayerFaction,
        amountCopper = 10000,
        status = "open",
        claimer = "",
        createdAt = now,
        updatedAt = now,
        epoch = CurrentCampaignEpoch(),
        pool = CurrentPool(),
        versionActor = "Debug-Overlord",
    })
    self:BroadcastLocalTargetPosition()
    return true
end

function Overlord.ManualBounty:DebugClear()
    RemoveFromOpenTargetIndex(DEBUG_CONTRACT_ID)
    ForgetRemoteCatalogContract(DEBUG_CONTRACT_ID)
    contractsById[DEBUG_CONTRACT_ID] = nil
    ForgetMaintenanceContract(DEBUG_CONTRACT_ID)
    local db = EnsureDb()
    if db then db[DEBUG_CONTRACT_ID] = nil end
    local name = GetLocalFullName()
    local key = name and NameDedupKey(name)
    if key and targetPositions[key] then
        targetPositions[key] = nil
        RemoveMaintenancePositionKey(key)
        QueuePositionRevision(true)
    end
    BumpRevision(true)
    RefreshLocalTargetTracking()
end

function Overlord.ManualBounty:PruneStale(contractQuota, positionQuota)
    local now = ServerNow()
    local runtimeNow = GetTime()
    local contractChanged = false
    local positionChanged = false
    local ledger = EnsureSettlementLedger()
    contractQuota = math.max(0, math.floor(
        tonumber(contractQuota) or MAINTENANCE_CONTRACT_QUOTA))
    positionQuota = math.max(0, math.floor(
        tonumber(positionQuota) or MAINTENANCE_POSITION_QUOTA))

    local contractWork = 0
    local contractBudget = math.min(contractQuota, #maintenanceContractIds)
    while contractWork < contractBudget and #maintenanceContractIds > 0 do
        if maintenanceContractCursor > #maintenanceContractIds then
            maintenanceContractCursor = 1
        end
        local id = maintenanceContractIds[maintenanceContractCursor]
        local c = contractsById[id]
        local removed = false
        if not c then
            ForgetMaintenanceContract(id)
            removed = true
        else
            local age = now - (c.updatedAt or c.createdAt or now)
            local settlement = ledger and ledger[id]
            if settlement and settlement.role ~= "poster" then settlement = nil end
            local localFinancial = settlement and SettlementIdentityMatches(settlement, c)
                and (c.status == "claimed" or c.status == "approved" or c.status == "paid")
            if not IsCurrentCampaignEpoch(c.epoch) and not localFinancial then
                RemoveFromOpenTargetIndex(id)
                ForgetRemoteCatalogContract(id)
                contractsById[id] = nil
                ForgetMaintenanceContract(id)
                local db = EnsureDb()
                if db then db[id] = nil end
                contractChanged = true
                removed = true
            elseif c.status == "paid"
                and age > (localFinancial
                    and self.FINANCIAL_HISTORY_SEC or self.CONTRACT_STALE_SEC) then
                RemoveFromOpenTargetIndex(id)
                ForgetRemoteCatalogContract(id)
                contractsById[id] = nil
                ForgetMaintenanceContract(id)
                local db = EnsureDb()
                if db then db[id] = nil end
                if localFinancial and ledger then ledger[id] = nil end
                contractChanged = true
                removed = true
            elseif c.status == "cancelled" and age > self.CONTRACT_STALE_SEC then
                RemoveFromOpenTargetIndex(id)
                ForgetRemoteCatalogContract(id)
                contractsById[id] = nil
                ForgetMaintenanceContract(id)
                local db = EnsureDb()
                if db then db[id] = nil end
                if ledger then ledger[id] = nil end
                contractChanged = true
                removed = true
            elseif c.status == "open" and age > self.CONTRACT_STALE_SEC then
                c.status = "cancelled"
                c.updatedAt = now
                c.versionActor = c.poster
                StoreContract(c)
                UpdateSettlementEntry(c, "cancelled")
                local me = GetLocalFullName()
                if NamesMatch(c.poster, me)
                    and Overlord.ManualBountySync
                    and Overlord.ManualBountySync.BroadcastCancel then
                    Overlord.ManualBountySync:BroadcastCancel(c)
                end
            end
        end
        if not removed then maintenanceContractCursor = maintenanceContractCursor + 1 end
        contractWork = contractWork + 1
    end

    local positionWork = 0
    local positionBudget = math.min(positionQuota, #maintenancePositionKeys)
    while positionWork < positionBudget and #maintenancePositionKeys > 0 do
        if maintenancePositionCursor > #maintenancePositionKeys then
            maintenancePositionCursor = 1
        end
        local key = maintenancePositionKeys[maintenancePositionCursor]
        local entry = targetPositions[key]
        local removed = false
        if not entry
            or runtimeNow - (entry.receivedAt or 0) > self.POSITION_STALE_SEC
            or not openContractsByTarget[key] then
            targetPositions[key] = nil
            RemoveMaintenancePositionKey(key)
            positionChanged = true
            removed = true
        end
        if not removed then maintenancePositionCursor = maintenancePositionCursor + 1 end
        positionWork = positionWork + 1
    end
    if contractChanged then BumpRevision(true) end
    if positionChanged then
        QueuePositionRevision(true)
    end
    return contractWork, positionWork
end

local function MaintenanceHasWork()
    return #maintenanceContractIds > 0
        or #maintenancePositionKeys > 0
        or #ownedActiveContractIds > 0
end

ArmMaintenance = function(delay)
    if maintenanceTimer or maintenanceRunning
        or not Overlord.ManualBounty._initialized
        or not MaintenanceHasWork()
        or not C_Timer or not C_Timer.NewTimer then return false end
    maintenanceTimer = C_Timer.NewTimer(
        math.max(0.1, tonumber(delay) or MAINTENANCE_INTERVAL_SEC), function()
            maintenanceTimer = nil
            maintenanceRunning = true
            if Overlord.InstanceSuspended then
                maintenanceContractSweepRemaining = 0
                maintenancePositionSweepRemaining = 0
                maintenanceSweepActive = false
                maintenanceRunning = false
                ArmMaintenance(MAINTENANCE_INTERVAL_SEC)
                return
            end

            if not maintenanceSweepActive then
                maintenanceContractSweepRemaining = #maintenanceContractIds
                maintenancePositionSweepRemaining = #maintenancePositionKeys
                maintenanceSweepActive = true
            end
            local contractQuota = math.min(
                MAINTENANCE_CONTRACT_QUOTA, maintenanceContractSweepRemaining)
            local positionQuota = math.min(
                MAINTENANCE_POSITION_QUOTA, maintenancePositionSweepRemaining)
            local contractWork, positionWork = Overlord.ManualBounty:PruneStale(
                contractQuota, positionQuota)
            maintenanceContractSweepRemaining = math.max(
                0, maintenanceContractSweepRemaining - contractWork)
            maintenancePositionSweepRemaining = math.max(
                0, maintenancePositionSweepRemaining - positionWork)

            local sweepPending = maintenanceContractSweepRemaining > 0
                or maintenancePositionSweepRemaining > 0
            if not sweepPending then
                maintenanceSweepActive = false
                if Overlord.ManualBountySync
                    and Overlord.ManualBountySync.QueueDirectContractMaintenance then
                    Overlord.ManualBountySync:QueueDirectContractMaintenance(1, false)
                end
            end
            maintenanceRunning = false
            if MaintenanceHasWork() then
                ArmMaintenance(sweepPending
                    and MAINTENANCE_SLICE_DELAY_SEC or MAINTENANCE_INTERVAL_SEC)
            end
        end)
    return true
end

function Overlord.ManualBounty:AppendToSrQueue(queue, minimalResponseOnly)
    if not queue or not Overlord.ManualBountySync then return end
    local me = GetLocalFullName()
    if not me or me == "" then return end
    local maxN = minimalResponseOnly and 3 or 4
    local positionPayload = nil
    if self:IsLocalPlayerTargeted() then
        local name = GetLocalFullName()
        local key = NameDedupKey(name)
        local position = key and targetPositions[key]
        if position and GetTime() - (position.receivedAt or 0) <= self.POSITION_STALE_SEC then
            positionPayload = Overlord.ManualBountySync:BuildPMPayload(
                name, position.mapX, position.mapY, position.mapID,
                CurrentPool(), position.sentAt)
        end
    end
    local contractCount = #srRelevantContractIds
    local candidateCount = contractCount + (positionPayload and 1 or 0)
    if candidateCount == 0 then
        srContractCursor = 0
        return
    end
    local start = (srContractCursor % candidateCount) + 1
    local scanned, emitted = 0, 0
    -- Les index sont maintenus sur chaque StoreContract. La petite marge de scan
    -- tolere une entree transitoirement invalide sans jamais retomber sur un tour
    -- complet du catalogue depuis le callback SR.
    local scanCap = math.min(candidateCount, maxN * 4)
    while scanned < scanCap and emitted < maxN do
        local index = ((start + scanned - 1) % candidateCount) + 1
        local msgType, payload, critical
        if index <= contractCount then
            local contract = contractsById[srRelevantContractIds[index]]
            if contract and IsSrRelevantContract(contract) then
                if NamesMatch(contract.poster, me) then
                    msgType = "PB"
                    payload = Overlord.ManualBountySync:BuildPBPayload(contract)
                    critical = false
                elseif contract.status == "claimed" and NamesMatch(contract.claimer, me) then
                    msgType = "PK"
                    payload = Overlord.ManualBountySync:BuildPKPayload(
                        contract.id, contract.claimer, contract.target, contract.pool,
                        contract.epoch, contract.updatedAt)
                    critical = true
                end
            end
        else
            msgType, payload, critical = "PM", positionPayload, false
        end
        if payload then
            queue[#queue + 1] = { type = msgType, data = payload, critical = critical }
            emitted = emitted + 1
        end
        scanned = scanned + 1
    end
    srContractCursor = (start - 1 + math.max(1, scanned)) % candidateCount
end

local function ResetManualBountyRuntimeIndexes()
    wipe(contractsById)
    wipe(remoteCatalogContractIds)
    wipe(openContractsByTarget)
    wipe(indexedTargetByContract)
    wipe(maintenanceContractIds)
    wipe(maintenanceContractPositions)
    wipe(ownedActiveContractIds)
    wipe(ownedActiveContractPositions)
    wipe(knownSyncContractIds)
    wipe(knownSyncContractPositions)
    wipe(srRelevantContractIds)
    wipe(srRelevantContractPositions)
    openContractCount, remoteCatalogContractCount = 0, 0
    srContractCursor, knownSyncCursor = 0, 0
    ResetTargetSummaryIndex()
end

local function PrepareManualBountyDbForLogin(yieldWork)
    if not OverlordDB then return nil end
    if type(OverlordDB.manualBountyContracts) ~= "table" then
        OverlordDB.manualBountyContracts = {}
    end
    local root = OverlordDB.manualBountyContracts
    local pool = CurrentPool()
    if not pool then return nil end
    if migratedDbRoot ~= root then
        MergeLegacyContractPoolBuckets(root, pool, yieldWork)
        local legacy = {}
        for key, value in pairs(root) do
            if type(value) == "table" and (value.id or value.status or value.target) then
                legacy[#legacy + 1] = { key = key, value = value }
            end
            yieldWork()
        end
        root[pool] = type(root[pool]) == "table" and root[pool] or {}
        for i = 1, #legacy do
            local row = legacy[i]
            row.value.pool = NormalizePool(row.value.pool) or pool
            root[pool][row.key] = row.value
            root[row.key] = nil
            yieldWork()
        end
        migratedDbRoot = root
    end
    if type(root[pool]) ~= "table" then root[pool] = {} end
    return root[pool]
end

function Overlord.ManualBounty:Initialize()
    if self._initialized then return true end
    if self._initFailed then return "blocked" end
    if self._initPending or self._initRetryPending then return "waiting" end
    -- Wait for the realmless local identity, not a Retail connected-realm list.
    if not IsCompleteName(GetLocalFullName()) then return "waiting" end
    if not C_Timer or not C_Timer.After or not coroutine or not coroutine.create then
        self._initFailed = true
        return "blocked"
    end

    ResetManualBountyRuntimeIndexes()
    self._initPending = true
    self._initGeneration = (tonumber(self._initGeneration) or 0) + 1
    local generation = self._initGeneration
    local work, started = 0, 0
    local worker = coroutine.create(function()
        local function yieldWork()
            work = work + 1
            if work >= 64 or (debugprofilestop and debugprofilestop() - started >= 1.25) then
                coroutine.yield()
            end
        end
        local db = PrepareManualBountyDbForLogin(yieldWork)
        local discardedIds = {}
        if db then
            local cursor = nil
            while true do
                local ok, id, contract = pcall(next, db, cursor)
                if not ok then error(id) end
                cursor = id
                if id == nil then break end
                if type(contract) == "table" then contract.id = contract.id or id end
                if IsValidStoredContract(contract)
                    and (not IsRemoteCatalogContract(contract)
                        or remoteCatalogContractCount < GetRemoteContractLimit(contract)) then
                    contractsById[contract.id] = contract
                    TrackRemoteCatalogContract(contract)
                    ReindexContract(contract)
                    ReindexMaintenanceContract(contract)
                    if NamesMatch(contract.poster, GetLocalFullName()) then
                        RegisterLocalSignedContract(contract)
                    end
                else
                    discardedIds[#discardedIds + 1] = id
                end
                yieldWork()
            end
            for i = 1, #discardedIds do db[discardedIds[i]] = nil; yieldWork() end
        end
        RestoreLocalSettlementLedger(yieldWork)
        return true
    end)

    local function retry()
        if self._initGeneration ~= generation then return end
        self._initPending = nil
        ResetManualBountyRuntimeIndexes()
        self._initAttempts = (tonumber(self._initAttempts) or 0) + 1
        if self._initAttempts >= 3 then self._initFailed = true; return end
        self._initRetryPending = true
        C_Timer.After(self._initAttempts, function()
            if self._initGeneration ~= generation then return end
            self._initRetryPending = nil
            self:Initialize()
        end)
    end
    local function runSlice()
        if self._initGeneration ~= generation then return end
        work, started = 0, debugprofilestop and debugprofilestop() or 0
        local ok = coroutine.resume(worker)
        if not ok then retry(); return end
        if coroutine.status(worker) ~= "dead" then C_Timer.After(0, runSlice); return end
        self._initPending = nil
        self._initAttempts = 0
        self._initialized = true
        ArmMaintenance(8)
        RefreshLocalTargetTracking()
    end
    C_Timer.After(0, runSlice)
    return "waiting"
end
