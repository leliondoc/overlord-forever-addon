-- SyncVictoryBonus.lua - journal persistant et transport VB (bonus victoire totale).
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local VB_SECONDS_PER_WEEK = 7 * 24 * 60 * 60
local VB_TRUCE_SECONDS = 15 * 60
local VB_MAX_PAYLOAD = 220
local VB_CHANNEL_REPLAY_BATCHES = 2
local VB_DEDUP_WINDOW = 60
local VB_MAX_FUTURE_SKEW = 300
local VB_VICTORY_BONUS = 0.02
local VB_PENDING_SECONDS = 2 * 60 * 60
local VB_PENDING_LIMIT = 64
-- Plancher de totalAtApply pour les VB emis/synthetises par un client v2 (voir
-- Overlord:GetLegacyDominationTotalForVB). Le compte de victoires ne depend plus de ce champ.
local VB_MIN_TOTAL_AT_APPLY = 2500

local VALID_VB_POOL = { global = true }
local victoryTransportEvidence = {}
local pendingVictoryBonuses = {}
local vbSrPayloadCache = nil
local validatedVictoryStores = setmetatable({}, { __mode = "k" })
local victoryProjectionStates = setmetatable({}, { __mode = "k" })

local function NormalizeFiniteInteger(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n)
end

local function NormalizeVictoryPoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    -- 1.4.0: one campaign per Forever ruleset (RealmPools.lua).
    if Overlord.RealmPools and Overlord.RealmPools.RULESET_POOLS
        and Overlord.RealmPools.RULESET_POOLS[pool] then return pool end
    if VALID_VB_POOL[pool] then return pool end
    return ""
end

local function CurrentVictoryPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizeVictoryPoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function GetCurrentVictoryCampaignStart()
    return (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and NormalizeFiniteInteger(OverlordDB.lastResetTimestamp)) or 0
end

local function IsCurrentVictoryCampaignEpoch(epoch)
    epoch = NormalizeFiniteInteger(epoch)
    local windowStart = GetCurrentVictoryCampaignStart()
    if not epoch or epoch <= 0 or windowStart <= 0 then return false end
    return epoch >= windowStart and epoch < windowStart + VB_SECONDS_PER_WEEK
end

local function SanitizeVictoryFrontId(frontId)
    frontId = tostring(frontId or ""):gsub("[^%w_%-]", "")
    if #frontId > 48 then return "" end
    return frontId
end

local function IsKnownVictoryFront(frontId)
    return frontId ~= ""
        and Overlord.Fronts
        and Overlord.Fronts.Registry
        and Overlord.Fronts.Registry[frontId] ~= nil
end

local function FactionCodeToFaction(code)
    if code == "A" then return "Alliance" end
    if code == "H" then return "Horde" end
    return nil
end

local function FactionToVictoryCode(faction)
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return ""
end

local function BuildVictoryEventId(frontId, victoryTs)
    return "front-victory-" .. frontId .. "-" .. victoryTs
end

local function ExpectedVictoryBonusSeconds(totalAtApply)
    if totalAtApply <= 0 then return 0 end
    local bonusSeconds = math.floor(VB_VICTORY_BONUS * totalAtApply + 0.5)
    if bonusSeconds > totalAtApply then bonusSeconds = totalAtApply end
    if bonusSeconds <= 0 then return 0 end
    return bonusSeconds
end

local function GetVictoryEventLimit()
    local frontCount = 0
    for _ in pairs((Overlord.Fronts and Overlord.Fronts.Registry) or {}) do
        frontCount = frontCount + 1
    end
    if frontCount <= 0 then frontCount = 1 end
    -- Maximum theorique : une victoire par front et par treve de 15 minutes.
    return frontCount * (math.floor((VB_SECONDS_PER_WEEK - 1) / VB_TRUCE_SECONDS) + 1)
end

local function GetVictoryRawEventLimit()
    -- Jusqu'a quatre rapports concurrents par victoire theorique.
    return GetVictoryEventLimit() * 4
end

local function NormalizeVictoryEvent(ev)
    if type(ev) ~= "table" then return nil end
    local frontId = SanitizeVictoryFrontId(ev.frontId)
    local faction = ev.faction
    local victoryTs = NormalizeFiniteInteger(ev.victoryTs)
    local rangeMaxTs = NormalizeFiniteInteger(ev.rangeMaxTs) or victoryTs
    local totalAtApply = NormalizeFiniteInteger(ev.totalAtApply)
    local bonusSeconds = NormalizeFiniteInteger(ev.bonusSeconds)
    local campaignEpoch = NormalizeFiniteInteger(ev.campaignEpoch)
    if faction ~= "Alliance" and faction ~= "Horde" then return nil end
    if not IsKnownVictoryFront(frontId) or not victoryTs or victoryTs <= 0
        or not rangeMaxTs or rangeMaxTs < victoryTs then return nil end
    if rangeMaxTs - victoryTs >= VB_TRUCE_SECONDS then return nil end
    if not totalAtApply or not bonusSeconds or totalAtApply <= 0 or bonusSeconds <= 0 then return nil end
    local cap = Overlord.DOMINATION_SANITY_CAP or 2147483647
    if totalAtApply > cap or bonusSeconds > totalAtApply then return nil end
    if bonusSeconds ~= ExpectedVictoryBonusSeconds(totalAtApply) then return nil end
    if not campaignEpoch or not IsCurrentVictoryCampaignEpoch(campaignEpoch) then return nil end
    local campaignStart = GetCurrentVictoryCampaignStart()
    if victoryTs < campaignStart or rangeMaxTs >= campaignStart + VB_SECONDS_PER_WEEK then return nil end
    if rangeMaxTs > time() + VB_MAX_FUTURE_SKEW then return nil end
    return {
        eventId = BuildVictoryEventId(frontId, victoryTs),
        frontId = frontId,
        faction = faction,
        victoryTs = victoryTs,
        rangeMaxTs = rangeMaxTs,
        bonusSeconds = bonusSeconds,
        totalAtApply = totalAtApply,
        campaignEpoch = campaignEpoch,
        source = tostring(ev.source or ""),
        appliedAt = NormalizeFiniteInteger(ev.appliedAt) or time(),
    }
end

local function BuildVictoryRawEventId(ev)
    return table.concat({
        ev.frontId,
        ev.faction,
        tostring(ev.victoryTs),
    }, ":")
end

local BeginVictoryProjection

local function ScheduleVictoryProjection(store)
    if type(store) ~= "table" then return end
    local state = victoryProjectionStates[store]
    if not state then
        state = { generation = 0, running = false, requestedRevision = nil }
        victoryProjectionStates[store] = state
    end
    local revision = NormalizeFiniteInteger(store.revision) or 0
    if state.running and state.requestedRevision == revision then return end
    state.requestedRevision = revision
    state.generation = state.generation + 1
    if state.running then return end
    state.running = true
    C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
end

BeginVictoryProjection = function(store, state)
    local generation = state.generation
    local source = type(store.rawById) == "table" and store.rawById or store.byEventId
    local normalized, rawKeys = {}, {}
    local sourceKey = nil
    local budget = 512

    local function Expired(startedAt)
        return startedAt and debugprofilestop
            and debugprofilestop() - startedAt >= 1.25
    end

    local function Continue(step)
        if state.generation ~= generation then
            C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
            return false
        end
        C_Timer.After(0, step)
        return true
    end

    local function StartMergeSort(rows, lessOrEqual, done)
        local scratch = {}
        local sourceRows, targetRows = rows, scratch
        local width, left = 1, 1
        local mergeI, mergeJ, mergeIEnd, mergeJEnd, mergeOut

        local function Step()
            if state.generation ~= generation then
                C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
                return
            end
            local total, work = #sourceRows, 0
            local startedAt = debugprofilestop and debugprofilestop() or nil
            if total <= 1 or width >= total then done(sourceRows) return end
            while work < budget and not Expired(startedAt) do
                if not mergeI then
                    if left > total then
                        sourceRows, targetRows = targetRows, sourceRows
                        width = width * 2
                        left = 1
                        if width >= total then done(sourceRows) return end
                    end
                    mergeI = left
                    mergeIEnd = math.min(left + width - 1, total)
                    mergeJ = mergeIEnd + 1
                    mergeJEnd = math.min(left + width * 2 - 1, total)
                    mergeOut = left
                end
                while work < budget and not Expired(startedAt)
                    and (mergeI <= mergeIEnd or mergeJ <= mergeJEnd) do
                    local takeLeft = mergeJ > mergeJEnd
                    if not takeLeft and mergeI <= mergeIEnd then
                        takeLeft = lessOrEqual(sourceRows[mergeI], sourceRows[mergeJ])
                    end
                    if takeLeft then
                        targetRows[mergeOut] = sourceRows[mergeI]
                        mergeI = mergeI + 1
                    else
                        targetRows[mergeOut] = sourceRows[mergeJ]
                        mergeJ = mergeJ + 1
                    end
                    mergeOut = mergeOut + 1
                    work = work + 1
                end
                if mergeI > mergeIEnd and mergeJ > mergeJEnd then
                    left = left + width * 2
                    mergeI, mergeJ, mergeIEnd, mergeJEnd, mergeOut = nil, nil, nil, nil, nil
                end
            end
            Continue(Step)
        end

        Step()
    end

    local function Publish(rawById, rawCount, accepted, acceptedRows, byFront, latestByFront,
        totals, payloads, factionPayloads)
        if state.generation ~= generation then
            C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
            return
        end
        store.rawById = rawById
        store.rawCount = rawCount
        store.byEventId = accepted
        store.projectedByFront = byFront
        store.latestByFront = latestByFront
        store.totals = totals
        store.count = #acceptedRows
        store.cacheVersion = 4
        store.revision = (NormalizeFiniteInteger(store.revision) or 0) + 1
        validatedVictoryStores[store] = true
        state.running = false
        local pool = CurrentVictoryPoolTag()
        if pool ~= "" and NormalizeFiniteInteger(store.epoch) == GetCurrentVictoryCampaignStart() then
            vbSrPayloadCache = {
                revision = store.revision,
                epoch = store.epoch,
                pool = pool,
                payloads = payloads,
                factionPayloads = factionPayloads,
            }
        end
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
    end

    local function BuildSrPayloadsAsync(rawById, rawCount, accepted, acceptedRows, byFront,
        latestByFront, totals)
        StartMergeSort(acceptedRows, function(a, b)
            if a.victoryTs ~= b.victoryTs then return a.victoryTs <= b.victoryTs end
            return a.eventId <= b.eventId
        end, function(sortedAccepted)
            local pool = CurrentVictoryPoolTag()
            local prefix = tostring(store.epoch) .. ":" .. pool .. ":"
            local payloads, batch, batchLen = {}, {}, 0
            -- 1.3.6: the same rows packed per winning faction, for the opposite-faction
            -- Battle.net friends (AppendOwnFactionVictoriesForEnemyFriend).
            local factionPayloads = { Alliance = {}, Horde = {} }
            local factionBatches = { Alliance = { len = 0 }, Horde = { len = 0 } }
            local cursor = 1
            local function FlushBatch()
                if #batch == 0 then return end
                payloads[#payloads + 1] = prefix .. table.concat(batch, "|")
                batch, batchLen = {}, 0
            end
            local function FlushFaction(faction)
                local fb = factionBatches[faction]
                if #fb == 0 then return end
                local list = factionPayloads[faction]
                list[#list + 1] = prefix .. table.concat(fb, "|")
                factionBatches[faction] = { len = 0 }
            end
            local function PackStep()
                if state.generation ~= generation then
                    C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
                    return
                end
                local work = 0
                local startedAt = debugprofilestop and debugprofilestop() or nil
                while cursor <= #sortedAccepted and work < budget and not Expired(startedAt) do
                    local ev = sortedAccepted[cursor]
                    local encoded = table.concat({
                        FactionToVictoryCode(ev.faction), ev.frontId,
                        tostring(ev.victoryTs), tostring(ev.rangeMaxTs),
                        tostring(ev.bonusSeconds), tostring(ev.totalAtApply),
                    }, ",")
                    local addLen = (#batch > 0) and (#encoded + 1) or #encoded
                    if batchLen + addLen > (VB_MAX_PAYLOAD - #prefix) then FlushBatch() end
                    batch[#batch + 1] = encoded
                    batchLen = batchLen + ((#batch > 1) and (#encoded + 1) or #encoded)
                    local fb = factionBatches[ev.faction]
                    if fb then
                        if fb.len + ((#fb > 0) and (#encoded + 1) or #encoded)
                            > (VB_MAX_PAYLOAD - #prefix) then
                            FlushFaction(ev.faction)
                            fb = factionBatches[ev.faction]
                        end
                        fb[#fb + 1] = encoded
                        fb.len = fb.len + ((#fb > 1) and (#encoded + 1) or #encoded)
                    end
                    cursor = cursor + 1
                    work = work + 1
                end
                if cursor <= #sortedAccepted then Continue(PackStep) return end
                FlushBatch()
                FlushFaction("Alliance")
                FlushFaction("Horde")
                Publish(rawById, rawCount, accepted, sortedAccepted, byFront,
                    latestByFront, totals, payloads, factionPayloads)
            end
            PackStep()
        end)
    end

    local function ProjectSorted(rawRows, rawById, rawCount)
        local accepted, acceptedRows = {}, {}
        local byFront, latestByFront = {}, {}
        local totals = { Alliance = 0, Horde = 0 }
        local cursor = 1
        local function Step()
            if state.generation ~= generation then
                C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
                return
            end
            local work = 0
            local startedAt = debugprofilestop and debugprofilestop() or nil
            while cursor <= #rawRows and work < budget and not Expired(startedAt) do
                local ev = rawRows[cursor]
                local current = latestByFront[ev.frontId]
                if not current or ev.victoryTs >= current.victoryTs + VB_TRUCE_SECONDS then
                    local projected = {
                        eventId = BuildVictoryEventId(ev.frontId, ev.victoryTs),
                        frontId = ev.frontId,
                        faction = ev.faction,
                        victoryTs = ev.victoryTs,
                        rangeMaxTs = ev.rangeMaxTs,
                        bonusSeconds = ev.bonusSeconds,
                        totalAtApply = ev.totalAtApply,
                        campaignEpoch = ev.campaignEpoch,
                        source = ev.source,
                        appliedAt = ev.appliedAt,
                    }
                    accepted[projected.eventId] = projected
                    acceptedRows[#acceptedRows + 1] = projected
                    byFront[projected.frontId] = byFront[projected.frontId] or {}
                    byFront[projected.frontId][#byFront[projected.frontId] + 1] = projected
                    latestByFront[projected.frontId] = projected
                    totals[projected.faction] = totals[projected.faction] + projected.bonusSeconds
                elseif ev.victoryTs <= current.rangeMaxTs + VB_DEDUP_WINDOW
                    and math.max(current.rangeMaxTs, ev.rangeMaxTs) - current.victoryTs
                        < VB_TRUCE_SECONDS then
                    current.rangeMaxTs = math.max(current.rangeMaxTs, ev.rangeMaxTs)
                    if ev.victoryTs == current.victoryTs and ev.faction == current.faction
                        and ev.totalAtApply > current.totalAtApply then
                        totals[current.faction] = totals[current.faction]
                            - current.bonusSeconds + ev.bonusSeconds
                        current.totalAtApply = ev.totalAtApply
                        current.bonusSeconds = ev.bonusSeconds
                    end
                end
                cursor = cursor + 1
                work = work + 1
            end
            if cursor <= #rawRows then Continue(Step) return end
            BuildSrPayloadsAsync(rawById, rawCount, accepted, acceptedRows,
                byFront, latestByFront, totals)
        end
        Step()
    end

    local function BuildRaw(sorted)
        local rawById, uniqueRows, rawCount = {}, {}, 0
        local cursor = 1
        local limit = GetVictoryRawEventLimit()
        local function Step()
            if state.generation ~= generation then
                C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
                return
            end
            local work = 0
            local startedAt = debugprofilestop and debugprofilestop() or nil
            while cursor <= #sorted and rawCount < limit
                and work < budget and not Expired(startedAt) do
                local ev = sorted[cursor]
                local rawId = rawKeys[ev]
                local existing = rawById[rawId]
                if not existing then
                    rawById[rawId] = ev
                    uniqueRows[#uniqueRows + 1] = ev
                    rawCount = rawCount + 1
                elseif ev.totalAtApply > existing.totalAtApply then
                    rawById[rawId] = ev
                    uniqueRows[#uniqueRows] = ev
                end
                cursor = cursor + 1
                work = work + 1
            end
            if cursor <= #sorted and rawCount < limit then Continue(Step) return end
            StartMergeSort(uniqueRows, function(a, b)
                if a.frontId ~= b.frontId then return a.frontId <= b.frontId end
                if a.victoryTs ~= b.victoryTs then return a.victoryTs <= b.victoryTs end
                return a.faction <= b.faction
            end, function(projectRows) ProjectSorted(projectRows, rawById, rawCount) end)
        end
        Step()
    end

    local function Collect()
        if state.generation ~= generation then
            C_Timer.After(0, function() BeginVictoryProjection(store, state) end)
            return
        end
        local work = 0
        local startedAt = debugprofilestop and debugprofilestop() or nil
        while work < budget and not Expired(startedAt) do
            local key, rawEvent = next(type(source) == "table" and source or {}, sourceKey)
            sourceKey = key
            if key == nil then
                StartMergeSort(normalized, function(a, b)
                    return rawKeys[a] <= rawKeys[b]
                end, BuildRaw)
                return
            end
            local ev = NormalizeVictoryEvent(rawEvent)
            if ev then
                normalized[#normalized + 1] = ev
                rawKeys[ev] = BuildVictoryRawEventId(ev)
            end
            work = work + 1
        end
        Continue(Collect)
    end

    Collect()
end

local function ProjectVictoryRawEvents(store)
    ScheduleVictoryProjection(store)
end

local function RebuildVictoryEventCache(store)
    ScheduleVictoryProjection(store)
end

local function EnsureVictoryEventsDB()
    if not OverlordDB then return nil end
    local pool = CurrentVictoryPoolTag()
    local epoch = GetCurrentVictoryCampaignStart()
    if pool == "" or epoch <= 0 then return nil end
    OverlordDB.dominationVictoryEvents = OverlordDB.dominationVictoryEvents or {}
    local root = OverlordDB.dominationVictoryEvents
    if type(root.byPool) ~= "table" then root.byPool = {} end
    if not root.globalPoolUnified then
        local global = type(root.byPool.global) == "table" and root.byPool.global or nil
        if global and NormalizeFiniteInteger(global.epoch) ~= epoch then
            root.legacyByPool = type(root.legacyByPool) == "table" and root.legacyByPool or {}
            root.legacyByPool["global:" .. tostring(global.epoch or 0)] = global
            global = nil
        end
        for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
            local legacy = root.byPool[oldPool]
            if type(legacy) == "table" and NormalizeFiniteInteger(legacy.epoch) == epoch then
                if not global then
                    global = legacy
                elseif global ~= legacy then
                    global.rawById = type(global.rawById) == "table" and global.rawById or {}
                    for eventId, event in pairs(type(legacy.rawById) == "table"
                        and legacy.rawById or {}) do
                        if global.rawById[eventId] == nil then global.rawById[eventId] = event end
                    end
                    global.byEventId = type(global.byEventId) == "table" and global.byEventId or {}
                    for eventId, event in pairs(type(legacy.byEventId) == "table"
                        and legacy.byEventId or {}) do
                        if global.byEventId[eventId] == nil then global.byEventId[eventId] = event end
                    end
                end
            elseif type(legacy) == "table" then
                root.legacyByPool = type(root.legacyByPool) == "table" and root.legacyByPool or {}
                root.legacyByPool[oldPool .. ":" .. tostring(legacy.epoch or 0)] = legacy
            end
        end
        if global then
            root.byPool.global = global
            global.rawCount = nil
            validatedVictoryStores[global] = nil
        end
        for _, oldPool in ipairs({ "us", "eu", "fr", "de", "na" }) do
            root.byPool[oldPool] = nil
        end
        root.globalPoolUnified = true
    end
    local store = root.byPool[pool]
    if type(store) ~= "table" or NormalizeFiniteInteger(store.epoch) ~= epoch then
        store = {
            epoch = epoch,
            rawById = {},
            rawCount = 0,
            byEventId = {},
            totals = { Alliance = 0, Horde = 0 },
            count = 0,
            revision = 1,
            cacheVersion = 4,
            projectedByFront = {},
            latestByFront = {},
        }
        root.byPool[pool] = store
        validatedVictoryStores[store] = true
        vbSrPayloadCache = nil
    end
    if not validatedVictoryStores[store] then
        RebuildVictoryEventCache(store)
    end
    local totalsValid = type(store.totals) == "table"
        and NormalizeFiniteInteger(store.totals.Alliance) ~= nil
        and NormalizeFiniteInteger(store.totals.Horde) ~= nil
    local count = NormalizeFiniteInteger(store.count)
    local rawCount = NormalizeFiniteInteger(store.rawCount)
    if type(store.rawById) ~= "table" or not rawCount
        or rawCount < 0 or rawCount > GetVictoryRawEventLimit()
        or type(store.byEventId) ~= "table" or not totalsValid or not count
        or count < 0 or count > GetVictoryEventLimit()
        or type(store.projectedByFront) ~= "table"
        or type(store.latestByFront) ~= "table"
        or store.cacheVersion ~= 4 then
        RebuildVictoryEventCache(store)
    end
    -- Le worker valide/repare l'integralite hors du handler. Les lecteurs gardent
    -- entre-temps le dernier snapshot structurellement sûr, jamais une demi-projection.
    if type(store.byEventId) ~= "table" then store.byEventId = {} end
    if type(store.projectedByFront) ~= "table" then store.projectedByFront = {} end
    if type(store.latestByFront) ~= "table" then store.latestByFront = {} end
    if type(store.totals) ~= "table" then store.totals = { Alliance = 0, Horde = 0 } end
    store.totals.Alliance = NormalizeFiniteInteger(store.totals.Alliance) or 0
    store.totals.Horde = NormalizeFiniteInteger(store.totals.Horde) or 0
    store.count = math.max(0, NormalizeFiniteInteger(store.count) or 0)
    store.rawCount = math.max(0, NormalizeFiniteInteger(store.rawCount) or 0)
    return store, pool, epoch
end

local function FindVictoryComponent(store, probe)
    local minTs = probe.victoryTs
    local maxTs = probe.rangeMaxTs or probe.victoryTs
    local selected = {}
    local direct = store.byEventId
        and store.byEventId[BuildVictoryEventId(probe.frontId, probe.victoryTs)]
    if direct then
        selected[direct.eventId] = direct
        return selected
    end
    local rows = store.projectedByFront and store.projectedByFront[probe.frontId]
    if type(rows) ~= "table" or #rows == 0 then return selected end

    -- Les projections d'un front sont espacees d'au moins une treve. Une recherche
    -- binaire suivie de deux voisins remplace l'ancien while-changed qui rescannait
    -- toute la campagne jusqu'au point fixe pour chaque simple lookup.
    local low, high = 1, #rows
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if rows[mid].victoryTs < minTs then low = mid + 1 else high = mid - 1 end
    end
    for i = math.max(1, low - 2), math.min(#rows, low + 1) do
        local existing = rows[i]
        if existing.rangeMaxTs >= minTs - VB_DEDUP_WINDOW
            and existing.victoryTs <= maxTs + VB_DEDUP_WINDOW then
            selected[existing.eventId] = existing
        end
    end
    return selected
end

local function ApplyVictoryProjectionFast(store, ev, hadRawEvent)
    if store.cacheVersion ~= 4 or type(store.latestByFront) ~= "table"
        or type(store.projectedByFront) ~= "table" then return nil, "pending" end
    local current = store.latestByFront[ev.frontId]
    if current and ev.victoryTs < current.victoryTs then return nil, "pending" end

    if not current or ev.victoryTs >= current.victoryTs + VB_TRUCE_SECONDS then
        local projected = {
            eventId = BuildVictoryEventId(ev.frontId, ev.victoryTs),
            frontId = ev.frontId,
            faction = ev.faction,
            victoryTs = ev.victoryTs,
            rangeMaxTs = ev.rangeMaxTs,
            bonusSeconds = ev.bonusSeconds,
            totalAtApply = ev.totalAtApply,
            campaignEpoch = ev.campaignEpoch,
            source = ev.source,
            appliedAt = ev.appliedAt,
        }
        store.byEventId[projected.eventId] = projected
        local rows = store.projectedByFront[projected.frontId]
        if type(rows) ~= "table" then
            rows = {}
            store.projectedByFront[projected.frontId] = rows
        end
        rows[#rows + 1] = projected
        store.latestByFront[projected.frontId] = projected
        store.totals[projected.faction] =
            (NormalizeFiniteInteger(store.totals[projected.faction]) or 0) + projected.bonusSeconds
        store.count = (NormalizeFiniteInteger(store.count) or 0) + 1
        return projected, hadRawEvent and "updated" or "applied"
    end

    if ev.victoryTs == current.victoryTs and ev.faction ~= current.faction then
        -- Le tri canonique par faction doit arbitrer ce conflit rare.
        return nil, "pending"
    end
    if ev.victoryTs <= current.rangeMaxTs + VB_DEDUP_WINDOW
        and math.max(current.rangeMaxTs, ev.rangeMaxTs) - current.victoryTs
            < VB_TRUCE_SECONDS then
        current.rangeMaxTs = math.max(current.rangeMaxTs, ev.rangeMaxTs)
        if ev.victoryTs == current.victoryTs and ev.faction == current.faction
            and ev.totalAtApply > current.totalAtApply then
            store.totals[current.faction] = store.totals[current.faction]
                - current.bonusSeconds + ev.bonusSeconds
            current.totalAtApply = ev.totalAtApply
            current.bonusSeconds = ev.bonusSeconds
            return current, "updated"
        end
        return current, "duplicate_alias"
    end
    return false, "pending"
end

local function HasMatchingVictoryEvidence(ev)
    local victories = OverlordDB and OverlordDB.frontVictories
    local victory = victories and victories[ev.frontId]
    if type(victory) ~= "table" or victory.faction ~= ev.faction then return false end
    local localTs = NormalizeFiniteInteger(victory.timestamp)
    return localTs and math.abs(localTs - ev.victoryTs) <= VB_MAX_FUTURE_SKEW
end

local function EvidenceKey(frontId, faction, victoryTs, sender, sourceChannel)
    return table.concat({
        frontId,
        faction,
        tostring(victoryTs),
        tostring(sender or ""):lower(),
        tostring(sourceChannel or ""),
    }, ":")
end

local function PrunePendingVictoryBonuses(now)
    local count, oldestKey, oldestAt = 0, nil, math.huge
    for key, pending in pairs(pendingVictoryBonuses) do
        if now - pending.at > VB_PENDING_SECONDS then
            pendingVictoryBonuses[key] = nil
        else
            count = count + 1
            if pending.at < oldestAt then
                oldestKey, oldestAt = key, pending.at
            end
        end
    end
    return count, oldestKey
end

local function QueuePendingVictoryBonus(ev, payload, sender, sourceChannel)
    local now = GetTime()
    local count, oldestKey = PrunePendingVictoryBonuses(now)
    local key = EvidenceKey(ev.frontId, ev.faction, ev.victoryTs, sender, sourceChannel)
    local previous = pendingVictoryBonuses[key]
    if previous and previous.totalAtApply >= ev.totalAtApply then return end
    if not previous and count >= VB_PENDING_LIMIT and oldestKey then
        pendingVictoryBonuses[oldestKey] = nil
    end
    pendingVictoryBonuses[key] = {
        at = previous and previous.at or now,
        frontId = ev.frontId, faction = ev.faction,
        victoryTs = ev.victoryTs, totalAtApply = ev.totalAtApply,
        rawId = BuildVictoryRawEventId(ev),
        payload = payload, sender = sender, sourceChannel = sourceChannel,
    }
end

local HasVictoryTransportEvidence
local pendingRetryWorker = { running = false, scheduled = false, dirty = false }

-- Retry after TV proof. Re-run the original VB validation with its original
-- sender, in small slices.
function Overlord.Sync:RetryPendingVictoryBonusForVictory()
    if Overlord.InstanceSuspended then return end
    local worker = pendingRetryWorker
    worker.dirty = true
    if worker.running then return end
    worker.running = true
    local retry, index
    local function Snapshot()
        PrunePendingVictoryBonuses(GetTime())
        retry, index = {}, 1
        for key, pending in pairs(pendingVictoryBonuses) do
            retry[#retry + 1] = { key = key, pending = pending }
        end
        worker.dirty = false
    end
    local Step
    local function Schedule()
        if worker.scheduled then return end
        worker.scheduled = true
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                worker.scheduled = false
                Step()
            end)
        else
            worker.scheduled = false
            Step()
        end
    end
    Step = function()
        if Overlord.InstanceSuspended then
            worker.running = false
            return
        end
        local processed = 0
        while index <= #retry and processed < 4 do
            local row = retry[index]
            index = index + 1
            processed = processed + 1
            local pending = row.pending
            if pendingVictoryBonuses[row.key] == pending
                and (HasVictoryTransportEvidence(
                    pending, pending.sender, pending.sourceChannel)
                    or HasMatchingVictoryEvidence(pending)) then
                pendingVictoryBonuses[row.key] = nil
                local accepted = self:OnReceiveVictoryBonus(
                    pending.payload, pending.sender, pending.sourceChannel)
                if not (accepted and accepted[pending.rawId]) then
                    -- Rejected for a reason other than missing proof (journal
                    -- full, no store yet). Keep the original expiry, including
                    -- when the replay re-queued the same event.
                    local requeued = pendingVictoryBonuses[row.key]
                    if requeued == nil then
                        pendingVictoryBonuses[row.key] = pending
                    else
                        requeued.at = math.min(requeued.at, pending.at)
                    end
                end
            end
        end
        if index <= #retry then
            Schedule()
        elseif worker.dirty then
            -- A TV arrived during this pass. Rebuild once after yielding;
            -- never create a second independent callback chain.
            Snapshot()
            Schedule()
        else
            worker.running = false
        end
    end
    Snapshot()
    Step()
end

function Overlord.Sync:RecordVictoryBonusTransportEvidence(
    frontId, faction, victoryTs, sender, sourceChannel)
    frontId = SanitizeVictoryFrontId(frontId)
    victoryTs = NormalizeFiniteInteger(victoryTs)
    if not IsKnownVictoryFront(frontId) or not victoryTs then return end
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    local key = EvidenceKey(frontId, faction, victoryTs, sender, sourceChannel)
    local now = GetTime()
    local evidenceCount, oldestKey, oldestAt = 0, nil, math.huge
    for evidenceKey, seenAt in pairs(victoryTransportEvidence) do
        if now - seenAt > 2 * 60 * 60 then
            victoryTransportEvidence[evidenceKey] = nil
        else
            evidenceCount = evidenceCount + 1
            if seenAt < oldestAt then
                oldestKey, oldestAt = evidenceKey, seenAt
            end
        end
    end
    if not victoryTransportEvidence[key] and evidenceCount >= 128 and oldestKey then
        victoryTransportEvidence[oldestKey] = nil
    end
    victoryTransportEvidence[key] = now
    self:RetryPendingVictoryBonusForVictory()
end

HasVictoryTransportEvidence = function(ev, sender, sourceChannel)
    local key = EvidenceKey(ev.frontId, ev.faction, ev.victoryTs, sender, sourceChannel)
    local seenAt = victoryTransportEvidence[key]
    if not seenAt then return false end
    if GetTime() - seenAt > 2 * 60 * 60 then
        victoryTransportEvidence[key] = nil
        return false
    end
    return true
end

local function IsHistoricalReplaySenderTrusted(sync, sender, sourceChannel)
    if (sourceChannel == "WHISPER" or sourceChannel == "BETA") then
        return (sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender or ""))
            or (sync.IsStrategicSiteCommunitySender and sync:IsStrategicSiteCommunitySender(sender or ""))
    end
    if sourceChannel == "RAID" or sourceChannel == "PARTY" then
        return sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender or "")
    end
    return false
end

function Overlord:GetDominationVictoryBonusTotals()
    local store = EnsureVictoryEventsDB()
    if not store then return 0, 0 end
    return NormalizeFiniteInteger(store.totals.Alliance) or 0,
        NormalizeFiniteInteger(store.totals.Horde) or 0
end

-- Barre v2 : nombre de victoires DISTINCTES par faction pour la campagne courante.
-- byEventId est la projection dedupliquee du journal (un composant par victoire, meme
-- si plusieurs rapports concurrents ou alias existent) ; le store est par epoch, donc
-- aucune victoire de la semaine precedente ne peut etre comptee. Mis en cache par revision.
local victoryCountCache = setmetatable({}, { __mode = "k" })
function Overlord:GetDominationVictoryCounts()
    local store = EnsureVictoryEventsDB()
    if not store then return 0, 0 end
    local revision = NormalizeFiniteInteger(store.revision) or 0
    local rows = store.byEventId
    local cached = victoryCountCache[store]
    if not cached or cached.revision ~= revision or cached.rows ~= rows then
        cached = { revision = revision, rows = rows, Alliance = 0, Horde = 0 }
        for _, ev in pairs(type(rows) == "table" and rows or {}) do
            if type(ev) == "table" and (ev.faction == "Alliance" or ev.faction == "Horde") then
                cached[ev.faction] = cached[ev.faction] + 1
            end
        end
        victoryCountCache[store] = cached
    end
    return cached.Alliance, cached.Horde
end

-- totalAtApply des VB emis par un client v2. Il ne compte pas pour la barre ; il reste un
-- champ du format VB (valide par les recepteurs). Valeur fixe, plausible pour tout recepteur.
function Overlord:GetLegacyDominationTotalForVB()
    return VB_MIN_TOTAL_AT_APPLY
end

function Overlord:GetDominationVictoryEventNear(frontId, faction, victoryTs)
    local store = EnsureVictoryEventsDB()
    if not store then return nil end
    local probe = {
        frontId = SanitizeVictoryFrontId(frontId),
        faction = faction,
        victoryTs = NormalizeFiniteInteger(victoryTs) or 0,
    }
    local component = FindVictoryComponent(store, probe)
    if not component then return nil end
    for _, ev in pairs(component) do return ev end
    return nil
end

function Overlord:ApplyDominationVictoryBonusEvent(rawEv, opts)
    if not OverlordDB then return false, "no_db" end
    opts = opts or {}
    local ev = NormalizeVictoryEvent(rawEv)
    if not ev then return false, "invalid" end
    local evidence = HasMatchingVictoryEvidence(ev) or opts.transportEvidence == true
    local historicalReplay = opts.allowHistorical == true
        and time() - ev.victoryTs >= VB_TRUCE_SECONDS
    if not evidence and not historicalReplay then return false, "no_victory_evidence" end

    local store = EnsureVictoryEventsDB()
    if not store then return false, "no_store" end
    local rawId = BuildVictoryRawEventId(ev)
    local existing = store.rawById[rawId]
    if existing and opts.localEmitter then return true, "duplicate" end
    if existing and existing.totalAtApply >= ev.totalAtApply
        and existing.rangeMaxTs >= ev.rangeMaxTs then
        return true, "duplicate"
    end
    if not existing and store.rawCount >= GetVictoryRawEventLimit() then
        return false, "full"
    end
    if existing then
        if existing.totalAtApply > ev.totalAtApply then
            ev.totalAtApply = existing.totalAtApply
            ev.bonusSeconds = existing.bonusSeconds
        end
        ev.rangeMaxTs = math.max(ev.rangeMaxTs, existing.rangeMaxTs)
    else
        store.rawCount = store.rawCount + 1
    end
    store.rawById[rawId] = ev
    local projected, applyReason = ApplyVictoryProjectionFast(store, ev, existing ~= nil)
    if not projected and store.cacheVersion ~= 4 and opts.localEmitter then
        -- Migration/validation en cours : une vraie victoire locale ne peut attendre
        -- le worker, car Core doit construire puis diffuser VB dans le meme handler.
        -- Publier seulement cette ligne autoritaire ; le prochain swap atomique la
        -- recalcule avec tout le journal et elimine tout alias eventuel.
        projected = {
            eventId = BuildVictoryEventId(ev.frontId, ev.victoryTs),
            frontId = ev.frontId,
            faction = ev.faction,
            victoryTs = ev.victoryTs,
            rangeMaxTs = ev.rangeMaxTs,
            bonusSeconds = ev.bonusSeconds,
            totalAtApply = ev.totalAtApply,
            campaignEpoch = ev.campaignEpoch,
            source = ev.source,
            appliedAt = ev.appliedAt,
        }
        store.byEventId[projected.eventId] = projected
        store.totals[projected.faction] =
            (NormalizeFiniteInteger(store.totals[projected.faction]) or 0) + projected.bonusSeconds
        store.count = (NormalizeFiniteInteger(store.count) or 0) + 1
        applyReason = "applied"
    end
    store.revision = (NormalizeFiniteInteger(store.revision) or 0) + 1
    if not opts.deferProjection then ProjectVictoryRawEvents(store) end
    if not opts.deferRefresh then
        self:MarkDirty()
        if self.UI and self.UI.RefreshDomination then self.UI:RefreshDomination() end
    end
    if projected and projected ~= false and projected.faction == ev.faction then
        return true, applyReason
    end
    return true, applyReason or "pending"
end

local function EncodeVictoryEvent(ev)
    ev = NormalizeVictoryEvent(ev)
    if not ev then return nil end
    return table.concat({
        FactionToVictoryCode(ev.faction),
        ev.frontId,
        tostring(ev.victoryTs),
        tostring(ev.rangeMaxTs),
        tostring(ev.bonusSeconds),
        tostring(ev.totalAtApply),
    }, ",")
end

local function DecodeVictoryEventPart(part, campaignEpoch)
    if not part or part == "" then return nil end
    local facCode, frontId, victoryTsStr, rangeMaxTsStr, bonusStr, totalStr =
        strsplit(",", part, 6)
    local faction = FactionCodeToFaction(facCode)
    if not faction then return nil end
    return NormalizeVictoryEvent({
        frontId = frontId,
        faction = faction,
        victoryTs = victoryTsStr,
        rangeMaxTs = rangeMaxTsStr,
        bonusSeconds = bonusStr,
        totalAtApply = totalStr,
        campaignEpoch = campaignEpoch,
        source = "vb_network",
    })
end

function Overlord.Sync:BuildVictoryBonusPayload(events, epoch, pool)
    if type(events) ~= "table" or #events == 0 then return nil end
    epoch = NormalizeFiniteInteger(epoch)
    pool = NormalizeVictoryPoolTag(pool)
    if not epoch or epoch <= 0 or pool == "" then return nil end
    local parts = {}
    for _, ev in ipairs(events) do
        local encoded = EncodeVictoryEvent(ev)
        if encoded then parts[#parts + 1] = encoded end
    end
    if #parts == 0 then return nil end
    local payload = tostring(epoch) .. ":" .. pool .. ":" .. table.concat(parts, "|")
    if #payload > VB_MAX_PAYLOAD then return nil end
    return payload
end

local function ParseVictoryBonusPayload(payload, sender, sourceChannel)
    if not payload or payload == "" or #payload > VB_MAX_PAYLOAD then return nil end
    local epochStr, poolStr, eventsStr = strsplit(":", payload, 3)
    local epoch = NormalizeFiniteInteger(epochStr)
    if not epoch or not eventsStr or eventsStr == "" then return nil end
    local effectivePool
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        effectivePool = Overlord.Sync:ResolveDirectGroupTerritorialPool(
            NormalizeVictoryPoolTag(poolStr), sender, sourceChannel)
    else
        local remotePool = NormalizeVictoryPoolTag(poolStr)
        effectivePool = remotePool == CurrentVictoryPoolTag() and remotePool or nil
    end
    if not effectivePool then return nil end
    if not IsCurrentVictoryCampaignEpoch(epoch) then return nil end
    local out = {}
    for part in string.gmatch(eventsStr, "[^|]+") do
        local ev = DecodeVictoryEventPart(part, epoch)
        if not ev then return nil end
        out[#out + 1] = ev
    end
    if #out == 0 then return nil end
    return out
end

function Overlord.Sync:OnReceiveVictoryBonus(payload, sender, sourceChannel)
    if not payload or not OverlordDB or Overlord.InstanceSuspended then return end
    local events = ParseVictoryBonusPayload(payload, sender, sourceChannel)
    if not events then return end
    local changed = false
    local accepted = {}
    for _, ev in ipairs(events) do
        local transportEvidence = HasVictoryTransportEvidence(ev, sender, sourceChannel)
        local localEvidence = HasMatchingVictoryEvidence(ev)
        local historicalTrusted = time() - ev.victoryTs >= VB_TRUCE_SECONDS
            and IsHistoricalReplaySenderTrusted(self, sender, sourceChannel)
        if not historicalTrusted and sourceChannel == "CHANNEL"
            and time() - ev.victoryTs >= VB_TRUCE_SECONDS
            and self.IsDominationChannelSenderVerified
            and self:IsDominationChannelSenderVerified(sender or "") then
            -- Une source de groupe/communaute deja verifiee suffit. Un second
            -- paquet identique ne doit pas conditionner la recompense locale.
            historicalTrusted = true
        end
        if transportEvidence or localEvidence or historicalTrusted then
            local ok, reason = Overlord:ApplyDominationVictoryBonusEvent(ev, {
                transportEvidence = transportEvidence,
                allowHistorical = historicalTrusted,
                deferProjection = true,
                deferRefresh = true,
            })
            if ok then
                accepted[BuildVictoryRawEventId(ev)] = true
                if reason ~= "duplicate" then changed = true end
            end
        elseif self.IsDominationChannelSenderVerified
            and self:IsDominationChannelSenderVerified(sender or "") then
            -- The TV may follow this VB over another route. Keep only a small,
            -- short-lived candidate; it earns no bonus until TV validates it.
            QueuePendingVictoryBonus(ev, payload, sender, sourceChannel)
        end
    end
    if changed then
        local store = EnsureVictoryEventsDB()
        if store then ProjectVictoryRawEvents(store) end
        Overlord:MarkDirty()
        if Overlord.UI and Overlord.UI.RefreshDomination then
            Overlord.UI:RefreshDomination()
        end
    end
    return accepted
end

function Overlord.Sync:BuildVictoryBonusPayloadForVictory(frontId, faction, victoryTs)
    if not Overlord.GetDominationVictoryEventNear then return nil end
    local ev = Overlord:GetDominationVictoryEventNear(frontId, faction, victoryTs)
    if not ev then return nil end
    return self:BuildVictoryBonusPayload(
        { ev },
        ev.campaignEpoch,
        CurrentVictoryPoolTag())
end

-- 1.3.6: each faction logs all of its own victories (its channel replays them), but
-- learnt the other faction's only live, with local proof: a victory nobody on the
-- other side saw was never counted there, and both bars drifted apart (live:
-- Alliance 49/38 vs Horde 48/39). A direct opposite-faction Battle.net friend that
-- pulls our state now gets our faction's victories; it already trusts a direct
-- peer's historical replay, and its own channel then spreads them. Only what this
-- friend has not had yet in this session: packets are compared one by one with the
-- last ones sent to it and resent from the first that changed (rows are sorted by
-- date: a new victory changes the last packet, a late-learnt older one the packet
-- it falls in). recordOnly: the response already carries the whole journal.
function Overlord.Sync:FirstChangedVictoryPacket(previous, list)
    for i = 1, #list do
        if previous[i] ~= list[i] then return i end
    end
    return nil
end

function Overlord.Sync:AppendOwnFactionVictoriesForEnemyFriend(queue, friendKey, recordOnly)
    local mine = Overlord.PlayerFaction
    if not queue or type(friendKey) ~= "string" or (mine ~= "Alliance" and mine ~= "Horde") then
        return 0
    end
    local store, pool, epoch = EnsureVictoryEventsDB()
    local cache = vbSrPayloadCache
    if not store or not cache or not cache.factionPayloads or cache.revision ~= store.revision
        or cache.epoch ~= epoch or cache.pool ~= pool then return 0 end
    local list = cache.factionPayloads[mine]
    if not list or #list == 0 then return 0 end
    self._vbEnemyFriendSent = self._vbEnemyFriendSent or {}
    local sent = self._vbEnemyFriendSent[friendKey]
    local from = 1
    if sent and sent.epoch == epoch then
        from = self:FirstChangedVictoryPacket(sent.packets, list)
        if not from then return 0 end
    end
    -- The packet strings are shared with the cache: keeping them costs one array.
    local packets = {}
    for i = 1, #list do packets[i] = list[i] end
    self._vbEnemyFriendSent[friendKey] = { epoch = epoch, packets = packets }
    if recordOnly then return 0 end
    for i = from, #list do
        queue[#queue + 1] = { type = "VB", data = list[i] }
    end
    return #list - from + 1
end

function Overlord.Sync:AppendVictoryBonusToSrQueue(queue, minimalResponseOnly, directSR)
    if not queue or not OverlordDB then return end
    local store, pool, epoch = EnsureVictoryEventsDB()
    if not store or store.count <= 0 then return end
    local revision = NormalizeFiniteInteger(store.revision) or 0
    if not vbSrPayloadCache or vbSrPayloadCache.revision ~= revision
        or vbSrPayloadCache.epoch ~= epoch or vbSrPayloadCache.pool ~= pool then
        -- La construction et le tri du journal peuvent couvrir plusieurs milliers
        -- d'evenements. Le handler SR reutilise l'ancien snapshot sûr pendant que le
        -- worker prepare le nouveau ; au premier chargement il differe simplement VB.
        ProjectVictoryRawEvents(store)
        if not vbSrPayloadCache or vbSrPayloadCache.epoch ~= epoch
            or vbSrPayloadCache.pool ~= pool then return end
    end
    local payloads = vbSrPayloadCache.payloads
    local totalBatches = #payloads
    if totalBatches == 0 then return end
    if directSR and not minimalResponseOnly then
        for _, payload in ipairs(payloads) do
            queue[#queue + 1] = { type = "VB", data = payload }
        end
        return
    end
    local start = ((self._vbSrCursor or 0) % totalBatches) + 1
    local sent = math.min(VB_CHANNEL_REPLAY_BATCHES, totalBatches)
    for offset = 0, sent - 1 do
        local idx = ((start + offset - 1) % totalBatches) + 1
        queue[#queue + 1] = { type = "VB", data = payloads[idx] }
    end
    self._vbSrCursor = ((start - 1 + sent) % totalBatches)
end
