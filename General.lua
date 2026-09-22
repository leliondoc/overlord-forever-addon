-- General.lua - Général de faction (1 slot par pool + faction, runtime uniquement)
-- Pipeline aligné sur Bounty.lua : SetActive, UpdatePosition, PruneStale, RequestMapRefresh.
Overlord = Overlord or {}
Overlord.General = {}

local L = Overlord.L

Overlord.General.GP_INTERVAL = 20
Overlord.General.GP_STALE_SEC = 60
Overlord.General.ENTRY_STALE_SEC = 90
Overlord.General.COLLISION_WINDOW_SEC = 3
Overlord.General.TOMBSTONE_SEC = 90

-- Badges Général (API Warfronts) : bannières faction carte Warfronts
Overlord.General.FACTION_BADGE_ATLAS = {
    Alliance = "AllianceWarfrontMapBanner",
    Horde    = "HordeWarfrontMapBanner",
}

function Overlord.General:GetFactionBadgeAtlas(faction)
    if not faction or faction == "" then return nil end
    return self.FACTION_BADGE_ATLAS[faction]
end

local slots = {}
local tombstones = {}
local localIsGeneral = false
local localClaimTs = nil
local localHolderFaction = nil

function Overlord.General:GetLocalHolderFaction()
    return localHolderFaction or Overlord.PlayerFaction
end

local gpTicker = nil
local generalRevision = 0
local mapRefreshPending = false
local MAP_REFRESH_DEBOUNCE = 0.25
local allyGeneralAlertKeys = {}
local lastGroupResyncAt = 0
local GROUP_RESYNC_COOLDOWN = 5
local rosterDebounceTimer = nil
local pendingLeaderClaimTimer = nil
local passivePruneTicker = nil
local lastPersistAt = 0
local lastGpBroadcastXC = nil
local lastGpBroadcastYC = nil
local lastGpBroadcastMapID = nil
local skipNextEnterFrontGp = false
local generalInitialized = false
local restoreRetryTimer = nil
local pendingDownBroadcast = nil
local lastGpHeartbeatAt = 0
local GP_HEARTBEAT_SEC = 40
local recentFallenAlerts = {}
local FALLEN_ALERT_DEDUP_SEC = 15
local ALLY_GENERAL_ALERT_DEDUP_SEC = 600
local ClearLocalGeneralState

local GENERAL_TOMBSTONE_MAX = 512
local GENERAL_TOMBSTONE_LOCAL_RESERVE = 16
local GENERAL_ALLY_ALERT_MAX = 256
local GENERAL_FALLEN_ALERT_MAX = 128

-- Registres TTL/LRU bornes : les paquets General acceptes peuvent changer de
-- claimTs plusieurs fois dans une meme fenetre. Une liste d'expiration liee garde
-- lookup/admission O(1), et la purge periodique ne visite qu'un quota de tetes.
local function NewTransientRegistry(values, maxEntries, reserve)
    return {
        values = values, nodes = {}, head = nil, tail = nil, count = 0,
        max = maxEntries, reserve = reserve or 0,
    }
end

local tombstoneState = NewTransientRegistry(
    tombstones, GENERAL_TOMBSTONE_MAX, GENERAL_TOMBSTONE_LOCAL_RESERVE)
local allyAlertState = NewTransientRegistry(allyGeneralAlertKeys, GENERAL_ALLY_ALERT_MAX)
local fallenAlertState = NewTransientRegistry(recentFallenAlerts, GENERAL_FALLEN_ALERT_MAX)

local function UnlinkTransientNode(state, node)
    if node.prev then node.prev.next = node.next else state.head = node.next end
    if node.next then node.next.prev = node.prev else state.tail = node.prev end
    node.prev, node.next = nil, nil
end

local function RemoveTransientNode(state, node)
    if not state or not node then return end
    UnlinkTransientNode(state, node)
    state.nodes[node.key] = nil
    state.values[node.key] = nil
    state.count = math.max(0, (tonumber(state.count) or 1) - 1)
end

local function PruneTransientRegistry(state, now, quota)
    local removed = 0
    while state.head and (tonumber(state.head.expiresAt) or 0) <= now
        and removed < (quota or 4) do
        RemoveTransientNode(state, state.head)
        removed = removed + 1
    end
    return removed
end

local function TransientIsRecent(state, key, now)
    local node = state.nodes[key]
    if not node then return false end
    if (tonumber(node.expiresAt) or 0) <= now then
        RemoveTransientNode(state, node)
        return false
    end
    return true
end

local function RememberTransientDedup(state, key, now, ttl, allowReserve)
    if not state or key == nil then return false end
    local expiresAt = now + ttl
    local node = state.nodes[key]
    if node then
        UnlinkTransientNode(state, node)
    else
        PruneTransientRegistry(state, now, 4)
        local limit = (tonumber(state.max) or 0)
            + (allowReserve and (tonumber(state.reserve) or 0) or 0)
        if (tonumber(state.count) or 0) >= limit then return false end
        node = { key = key }
        state.nodes[key] = node
        state.count = (tonumber(state.count) or 0) + 1
    end
    node.expiresAt = expiresAt
    node.prev, node.next = state.tail, nil
    if state.tail then state.tail.next = node else state.head = node end
    state.tail = node
    state.values[key] = expiresAt
    return true
end

local function Dbg(msg)
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFFFF8800[Overlord:General]|r " .. tostring(msg))
    end
end

local function BumpRevision()
    generalRevision = generalRevision + 1
end

local function IsWorldMapVisible()
    return WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown()
end

local function FacCode(faction)
    if faction == "Horde" then return "H" end
    return "A"
end

local function FacFromCode(code)
    if code == "H" then return "Horde" end
    if code == "A" then return "Alliance" end
    return nil
end

function Overlord.General:GetPoolTag()
    if Overlord.RealmPools and Overlord.RealmPools.GetOverlordPoolTag then
        return Overlord.RealmPools:GetOverlordPoolTag() or ""
    end
    return ""
end

local function PoolMatches(pool)
    local localPool = Overlord.General:GetPoolTag()
    if not localPool or localPool == "" then return false end
    return (pool or ""):lower() == localPool:lower()
end

local function SenderKey(sender)
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(sender)
    end
    return (sender or ""):lower()
end

local function SenderMatches(a, b)
    if not a or not b or a == "" or b == "" then return false end
    if a:lower() == b:lower() then return true end
    local ak = SenderKey(a)
    local bk = SenderKey(b)
    return ak ~= nil and bk ~= nil and ak == bk
end

local function GetLocalFullName()
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName then
        return sync:GetPlayerFullName()
    end
    return Overlord:SafeUnitName("player", true)
end

local function IsLocalGeneralSlot(slot)
    if not localIsGeneral or not slot or not slot.holder or not localClaimTs then return false end
    if slot.claimTs ~= localClaimTs then return false end
    return SenderMatches(slot.holder, GetLocalFullName())
end

function Overlord.General:IsRaidLeader()
    if not IsInGroup() then return false end
    return UnitIsGroupLeader("player") == true
end

local function ResolveFrontForGeneralMap(mapID)
    if not mapID or not Overlord.Fronts then return nil end
    local front = Overlord.Fronts.ResolveFrontByMapID and Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not front and Overlord.Fronts.ResolveFrontByOverlayMapID then
        front = Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
    end
    return front
end

local function CanonicalGeneralMapID(mapID)
    if not mapID or not Overlord.Fronts then return mapID end
    local front = ResolveFrontForGeneralMap(mapID)
    if not front then return mapID end
    if Overlord.Fronts.activeFrontId and front.id == Overlord.Fronts.activeFrontId then
        local activeCanon = Overlord.Fronts.GetMapID and Overlord.Fronts:GetMapID(front.id)
        if activeCanon then return activeCanon end
    end
    if front.resolvedMapID then return front.resolvedMapID end
    return mapID
end

local function NormalizeGeneralMapID(mapID)
    if not mapID or not Overlord.Fronts then return mapID end
    if Overlord.Fronts.IsActiveFrontMapID and Overlord.Fronts:IsActiveFrontMapID(mapID) then
        return CanonicalGeneralMapID(mapID)
    end
    local resolved = mapID
    local depth = 0
    while resolved and depth < 3 do
        if Overlord.Fronts.IsActiveFrontMapID and Overlord.Fronts:IsActiveFrontMapID(resolved) then
            return CanonicalGeneralMapID(resolved)
        end
        local ok, info = pcall(C_Map.GetMapInfo, resolved)
        if not ok or not info or not info.parentMapID or info.parentMapID == 0 then break end
        resolved = info.parentMapID
        depth = depth + 1
    end
    return CanonicalGeneralMapID(mapID)
end

local function GeneralMapIDsMatch(mapA, mapB)
    if not mapA or not mapB then return false end
    if NormalizeGeneralMapID(mapA) == NormalizeGeneralMapID(mapB) then return true end
    local frontA = ResolveFrontForGeneralMap(mapA)
    local frontB = ResolveFrontForGeneralMap(mapB)
    return frontA and frontB and frontA.id == frontB.id
end

function Overlord.General:GetLocalMapPosition()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return nil, nil, nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok2 or not pos then return nil, nil, NormalizeGeneralMapID(mapID) end
    local px, py = pos:GetXY()
    if not px then return nil, nil, NormalizeGeneralMapID(mapID) end
    return px * 100, py * 100, NormalizeGeneralMapID(mapID)
end

local function IsOnOverlordFrontMap()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID or not Overlord.Zones or not Overlord.Zones.IsWarFrontMapID then
        return false
    end
    return Overlord.Zones:IsWarFrontMapID(mapID)
end

local function IsGeneralFrontContext()
    return Overlord.InActiveFront or IsOnOverlordFrontMap()
end

-- Alertes Général : uniquement sur la carte physique du front.
-- Nouveau general (allie ou ennemi) : raid warning ; chute : popup WC3 conserve.
local function ShouldShowGeneralBattleAlerts()
    return IsOnOverlordFrontMap()
end

local function GetSlotTable(pool, faction)
    if not pool or pool == "" or not faction then return nil end
    slots[pool] = slots[pool] or {}
    return slots[pool][faction]
end

local function ClearSlot(pool, faction)
    if slots[pool] then
        slots[pool][faction] = nil
        BumpRevision()
    end
end

local function TombstoneKey(pool, faction, holder, claimTs)
    return tostring(pool or "") .. ":" .. tostring(faction or "") .. ":"
        .. tostring(SenderKey(holder) or "") .. ":" .. tostring(claimTs or 0)
end

local function IsTombstoned(pool, faction, holder, claimTs)
    local key = TombstoneKey(pool, faction, holder, claimTs)
    return TransientIsRecent(tombstoneState, key, GetTime())
end

local function AddTombstone(pool, faction, holder, claimTs, allowReserve)
    local key = TombstoneKey(pool, faction, holder, claimTs)
    return RememberTransientDedup(tombstoneState, key, GetTime(),
        Overlord.General.TOMBSTONE_SEC, allowReserve)
end

local function PurgeTransientDedupState(now)
    now = now or GetTime()
    PruneTransientRegistry(tombstoneState, now, 8)
    PruneTransientRegistry(allyAlertState, now, 8)
    PruneTransientRegistry(fallenAlertState, now, 8)
end

function Overlord.General:IsSlotFresh(slot)
    if not slot or not slot.lastMoveTs then return false end
    if IsLocalGeneralSlot(slot) then return true end
    return (GetTime() - slot.lastMoveTs) <= self.GP_STALE_SEC
end

function Overlord.General:GetSlot(faction)
    faction = faction or Overlord.PlayerFaction
    local pool = self:GetPoolTag()
    if pool == "" or not faction then return nil end
    local slot = GetSlotTable(pool, faction)
    if not slot then return nil end
    if IsLocalGeneralSlot(slot) then return slot end
    if (GetTime() - (slot.lastMoveTs or 0)) <= self.ENTRY_STALE_SEC then
        return slot
    end
    return nil
end

function Overlord.General:IsLocalHolder()
    return localIsGeneral
end

function Overlord.General:GetLocalClaimTs()
    return localClaimTs
end

function Overlord.General:GetRevision()
    return generalRevision
end

function Overlord.General:SetActive(holder, faction, claimTs, mapX, mapY, mapID, lastMoveTs, pool)
    pool = pool or self:GetPoolTag()
    if pool == "" or not faction or not holder then return end
    slots[pool] = slots[pool] or {}
    slots[pool][faction] = {
        holder = holder,
        claimTs = claimTs,
        mapX = mapX,
        mapY = mapY,
        mapID = NormalizeGeneralMapID(mapID),
        lastMoveTs = lastMoveTs or GetTime(),
        pool = pool,
        faction = faction,
    }
    BumpRevision()
    self:RequestMapRefresh()
end

function Overlord.General:UpdatePosition(mapX, mapY, mapID, lastMoveTs)
    if not localIsGeneral or not localClaimTs then return end
    local pool = self:GetPoolTag()
    local faction = self:GetLocalHolderFaction()
    if pool == "" or not faction then return end
    local slot = GetSlotTable(pool, faction)
    if not slot or not IsLocalGeneralSlot(slot) then return end
    mapID = NormalizeGeneralMapID(mapID)
    if not mapX or not mapY or not mapID then return end
    slot.mapX = mapX
    slot.mapY = mapY
    slot.mapID = mapID
    slot.lastMoveTs = lastMoveTs or GetTime()
    slot.lastPosTs = time()
    BumpRevision()
    self:RequestMapRefresh()
    self:MaybePersistSession(false)
end

function Overlord.General:GetDisplayEntry()
    local pool = self:GetPoolTag()
    local faction = Overlord.PlayerFaction
    if pool == "" or not faction then return nil end
    return self:BuildDisplayEntryFromSlot(GetSlotTable(pool, faction))
end

function Overlord.General:BuildDisplayEntryFromSlot(slot)
    if not slot or not slot.holder then return nil end
    local now = GetTime()
    if not IsLocalGeneralSlot(slot)
        and (now - (slot.lastMoveTs or 0)) > self.ENTRY_STALE_SEC then
        return nil
    end
    if not slot.mapX or not slot.mapY or not slot.mapID then return nil end
    return {
        name = slot.holder,
        faction = slot.faction,
        mapX = slot.mapX,
        mapY = slot.mapY,
        mapID = slot.mapID,
        updatedAt = slot.lastMoveTs,
        claimTs = slot.claimTs,
    }
end

function Overlord.General:GetEnemyFaction()
    if Overlord.PlayerFaction == "Horde" then return "Alliance" end
    return "Horde"
end

function Overlord.General:GetActiveList()
    local pool = self:GetPoolTag()
    if pool == "" then return {} end
    local list = {}
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local entry = self:BuildDisplayEntryFromSlot(GetSlotTable(pool, faction))
        if entry then
            list[#list + 1] = entry
        end
    end
    return list
end

function Overlord.General:GetEnemyDisplayEntry()
    local pool = self:GetPoolTag()
    local faction = self:GetEnemyFaction()
    if pool == "" or not faction then return nil end
    return self:BuildDisplayEntryFromSlot(GetSlotTable(pool, faction))
end

function Overlord.General:IsHolderName(name, faction)
    if not name or name == "" then return false end
    faction = faction or Overlord.PlayerFaction
    local slot = self:GetSlot(faction)
    if not slot or not slot.holder then return false end
    return SenderMatches(slot.holder, name)
end

function Overlord.General:GetHolderFactionForName(name)
    if not name or name == "" then return nil end
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        if self:IsHolderName(name, faction) then
            return faction
        end
    end
    return nil
end

function Overlord.General:ValidateDuelMusicPulse(sender, claimTs)
    if not sender or not claimTs then return false end
    local pool = self:GetPoolTag()
    if pool == "" then return false end
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local slot = GetSlotTable(pool, faction)
        if slot and slot.holder and slot.claimTs == claimTs
            and SenderMatches(slot.holder, sender)
            and not IsTombstoned(pool, faction, sender, claimTs) then
            return true
        end
    end
    return false
end

function Overlord.General:GetEntriesForMap(mapID)
    if not mapID then return {} end
    local list = {}
    local entries = self:GetActiveList()
    for i = 1, #entries do
        local entry = entries[i]
        if entry.mapX and entry.mapY and entry.mapID
            and GeneralMapIDsMatch(entry.mapID, mapID) then
            list[#list + 1] = entry
        end
    end
    return list
end

local function InvalidateNameplateCache()
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.InvalidateHolderCache then
        Overlord.GeneralNameplate:InvalidateHolderCache()
    end
end

function Overlord.General:PruneStale()
    local now = GetTime()
    PurgeTransientDedupState(now)
    local pool = self:GetPoolTag()
    if pool == "" then return end
    local changed = false
    for _, faction in ipairs({ "Alliance", "Horde" }) do
        local slot = GetSlotTable(pool, faction)
        if slot then
            local age = now - (slot.lastMoveTs or 0)
            if IsLocalGeneralSlot(slot) then
                if age > self.GP_STALE_SEC then
                    slot.lastMoveTs = now
                end
            elseif age > self.ENTRY_STALE_SEC then
                ClearSlot(pool, faction)
                changed = true
            end
        end
    end
    if changed then
        BumpRevision()
        InvalidateNameplateCache()
        self:RequestMapRefresh()
    end
end

function Overlord.General:RequestMapRefresh()
    if mapRefreshPending then return end
    mapRefreshPending = true
    C_Timer.After(MAP_REFRESH_DEBOUNCE, function()
        mapRefreshPending = false
        if Overlord.GeneralMap and IsWorldMapVisible() then
            if Overlord.GeneralMap.Refresh then Overlord.GeneralMap:Refresh() end
            if Overlord.GeneralMap.RefreshContinent then Overlord.GeneralMap:RefreshContinent() end
        end
        -- La minimap est deja rafraichie par son driver 20 Hz ; ne pas doubler le travail ici.
    end)
end

function Overlord.General:RefreshWorldMapPins()
    if Overlord.GeneralMap then
        if Overlord.GeneralMap.Refresh then Overlord.GeneralMap:Refresh() end
        if Overlord.GeneralMap.RefreshContinent then Overlord.GeneralMap:RefreshContinent() end
    end
end

local function ResolveFrontNameFromMapID(mapID)
    if not mapID or not Overlord.Fronts then return "" end
    local front = ResolveFrontForGeneralMap(mapID)
    if front and front.mapName then return front.mapName end
    return ""
end

local function OnGeneralSlotCleared()
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.StopDuelMusic then
        Overlord.GeneralNameplate:StopDuelMusic()
    end
    InvalidateNameplateCache()
end

local function NotifyGeneralFallen(victimName, killerName, victimFaction, claimTs)
    if not L then return end
    if claimTs and victimFaction then
        local key = tostring(claimTs) .. ":" .. tostring(victimFaction)
        local now = GetTime()
        if TransientIsRecent(fallenAlertState, key, now) then return end
        -- A saturation, supprimer seulement cette alerte visuelle. Evincer une cle
        -- encore vive rejouerait au contraire une notification deja montree.
        if not RememberTransientDedup(
            fallenAlertState, key, now, FALLEN_ALERT_DEDUP_SEC) then return end
    end
    local victimShort = (victimName or "?"):match("^(.-)%-") or victimName or "?"
    local killerShort = (killerName or "?"):match("^(.-)%-") or killerName or "?"
    if killerShort == "" then killerShort = "?" end
    local chatLine
    if victimFaction and victimFaction ~= Overlord.PlayerFaction
        and L.GENERAL_COUNTERPART_SLAIN then
        chatLine = "|cFFFFD100[Overlord]|r "
            .. string.format(L.GENERAL_COUNTERPART_SLAIN, victimShort, killerShort)
    elseif L.GENERAL_FALLEN then
        chatLine = "|cFFFFD100[Overlord]|r "
            .. string.format(L.GENERAL_FALLEN, victimShort, killerShort)
    else
        return
    end
    if Overlord.PrintNotification then
        Overlord:PrintNotification(chatLine)
    end
    if ShouldShowGeneralBattleAlerts() and Overlord.PrintRaidWarning then
        Overlord:PrintRaidWarning(chatLine)
    end
    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("general_fallen")
    end
end

local function NotifyGeneralReceived(senderName, frontName)
    if not L or not L.GENERAL_RECEIVED then return end
    local short = (senderName or "?"):match("^(.-)%-") or senderName
    local chatLine = "|cFFFFD100[Overlord]|r " .. string.format(L.GENERAL_RECEIVED, short, frontName or "")
    if Overlord.PrintNotification then
        Overlord:PrintNotification(chatLine)
    end
    if ShouldShowGeneralBattleAlerts() and Overlord.PrintRaidWarning then
        Overlord:PrintRaidWarning(chatLine)
    end
end

local function NotifyEnemyGeneralClaimed(senderName, frontName, claimTs, faction)
    if not L or not L.GENERAL_ENEMY_ASSUMED then return end
    local short = (senderName or "?"):match("^(.-)%-") or senderName or "?"
    local chatLine = "|cFFFFD100[Overlord]|r "
        .. string.format(L.GENERAL_ENEMY_ASSUMED, short, frontName or "")
    if Overlord.PrintNotification then
        Overlord:PrintNotification(chatLine)
    end
    if ShouldShowGeneralBattleAlerts() and Overlord.PrintRaidWarning then
        Overlord:PrintRaidWarning(chatLine)
    end
end

-- Nouveau general allie : alerte raid (pas de popup WC3 a fermer).
local function TryNotifyAllyGeneralAssumed(senderName, faction, frontName, claimTs)
    if not ShouldShowGeneralBattleAlerts() then return end
    local pool = Overlord.General:GetPoolTag()
    local dedupKey = pool .. ":" .. tostring(faction or "") .. ":" .. tostring(SenderKey(senderName) or "")
        .. ":" .. tostring(claimTs or 0)
    local now = GetTime()
    if TransientIsRecent(allyAlertState, dedupKey, now) then return end
    if not RememberTransientDedup(
        allyAlertState, dedupKey, now, ALLY_GENERAL_ALERT_DEDUP_SEC) then return end
    NotifyGeneralReceived(senderName, frontName)
end

local function IsNameInOurGroup(name)
    if not name or name == "" or not IsInGroup() then return false end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and 40 or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            local full = Overlord:SafeGetUnitName(unit, true)
            if SenderMatches(name, full) then return true end
        end
    end
    return false
end

local function IsNameGroupLeader(name)
    if not name or name == "" or not IsInGroup() then return false end
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and 40 or 4
    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) and UnitIsGroupLeader(unit) == true then
            local full = Overlord:SafeGetUnitName(unit, true)
            if SenderMatches(name, full) then return true end
        end
    end
    return false
end

local function TryClearStaleLocalSlotForFormerLeader(faction)
    local pool = Overlord.General:GetPoolTag()
    if pool == "" or not faction then return false end
    local slot = GetSlotTable(pool, faction)
    if not slot or not slot.holder then return false end
    if SenderMatches(slot.holder, GetLocalFullName()) then return false end
    if IsNameGroupLeader(slot.holder) then return false end
    -- Ne pas effacer un general communautaire absent du roster local.
    if not IsNameInOurGroup(slot.holder) then return false end
    ClearSlot(pool, faction)
    InvalidateNameplateCache()
    Overlord.General:RequestMapRefresh()
    return true
end

local function CompareClaimWinner(a, b)
    if a.claimTs ~= b.claimTs then
        return a.claimTs > b.claimTs
    end
    local ak = SenderKey(a.holder) or ""
    local bk = SenderKey(b.holder) or ""
    return ak > bk
end

local function SnapCoordCenti(v)
    return math.floor((tonumber(v) or 0) * 100 + 0.5)
end

function Overlord.General:CanAcceptClaim(faction, holder, claimTs, pool)
    if not PoolMatches(pool) then return false end
    if not faction then return false end
    if IsTombstoned(pool, faction, holder, claimTs) then return false end
    local slot = GetSlotTable(pool, faction)
    if slot and SenderMatches(slot.holder, holder) then
        return claimTs >= (tonumber(slot.claimTs) or 0)
    end
    if not slot or not self:IsSlotFresh(slot) then return true end
    local age = time() - (slot.claimTs or 0)
    if age <= self.COLLISION_WINDOW_SEC then
        return CompareClaimWinner({ holder = holder, claimTs = claimTs }, slot)
    end
    return false
end

function Overlord.General:ApplyRemoteClaim(sender, faction, pool, mapX, mapY, mapID, claimTs, showPopup)
    if not self:CanAcceptClaim(faction, sender, claimTs, pool) then return false end
    mapID = NormalizeGeneralMapID(mapID)
    if not mapID or mapID == 0 then return false end
    local myName = GetLocalFullName()
    local existingSlot = GetSlotTable(pool, faction)
    local sameClaimResync = existingSlot
        and SenderMatches(existingSlot.holder, sender)
        and existingSlot.claimTs == claimTs
    if sameClaimResync and existingSlot.lastPosTs then
        -- GE ne porte aucune horloge de position : une copie ancienne ne doit
        -- ni reculer le pin ni effacer l'horloge du dernier GP accepte.
        existingSlot.lastMoveTs = GetTime()
        return true
    end
    if faction == Overlord.PlayerFaction
        and localIsGeneral and not SenderMatches(sender, myName) and ClearLocalGeneralState then
        ClearLocalGeneralState()
        OnGeneralSlotCleared()
    end
    self:SetActive(sender, faction, claimTs, mapX, mapY, mapID, GetTime(), pool)

    local frontName = ResolveFrontNameFromMapID(mapID)
    if showPopup and faction == Overlord.PlayerFaction and not sameClaimResync then
        if myName and not SenderMatches(sender, myName) then
            TryNotifyAllyGeneralAssumed(sender, faction, frontName, claimTs)
        end
    elseif faction ~= Overlord.PlayerFaction and not sameClaimResync then
        NotifyEnemyGeneralClaimed(sender, frontName, claimTs, faction)
    end
    InvalidateNameplateCache()
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    return true
end

function Overlord.General:ApplyRemotePosition(sender, faction, pool, mapX, mapY, mapID, claimTs, posTs)
    if not PoolMatches(pool) then return false end
    if not faction then return false end
    mapID = NormalizeGeneralMapID(mapID)
    if not mapID or mapID == 0 or not mapX or not mapY then return false end
    if (tonumber(posTs) or 0) <= 0 then return false end

    local slot = GetSlotTable(pool, faction)
    if not slot then
        if IsTombstoned(pool, faction, sender, claimTs) then return false end
        if not self:ApplyRemoteClaim(sender, faction, pool, mapX, mapY, mapID, claimTs, false) then
            return false
        end
        slot = GetSlotTable(pool, faction)
        if slot then slot.lastPosTs = posTs end
        return true
    end
    if not SenderMatches(slot.holder, sender) or slot.claimTs ~= claimTs then return false end
    if posTs and slot.lastPosTs and posTs < slot.lastPosTs then return false end

    local moved = SnapCoordCenti(slot.mapX) ~= SnapCoordCenti(mapX)
        or SnapCoordCenti(slot.mapY) ~= SnapCoordCenti(mapY)
        or (tonumber(slot.mapID) or 0) ~= (tonumber(mapID) or 0)
    slot.mapX = mapX
    slot.mapY = mapY
    slot.mapID = mapID
    slot.lastMoveTs = GetTime()
    slot.lastPosTs = posTs or slot.lastPosTs
    if moved then
        BumpRevision()
        self:RequestMapRefresh()
    end
    return true
end

local function ShouldBroadcastGp(mx, my, mapID)
    local xC = SnapCoordCenti(mx)
    local yC = SnapCoordCenti(my)
    local mid = tonumber(mapID) or 0
    if lastGpBroadcastXC == xC and lastGpBroadcastYC == yC and lastGpBroadcastMapID == mid then
        return false
    end
    lastGpBroadcastXC = xC
    lastGpBroadcastYC = yC
    lastGpBroadcastMapID = mid
    return true
end

local function ResetGpBroadcastCache()
    lastGpBroadcastXC = nil
    lastGpBroadcastYC = nil
    lastGpBroadcastMapID = nil
    lastGpHeartbeatAt = 0
end

ClearLocalGeneralState = function()
    localIsGeneral = false
    localClaimTs = nil
    localHolderFaction = nil
    ResetGpBroadcastCache()
    Overlord.General:ClearPersistedSession()
    Overlord.General:StopPositionTicker()
end

function Overlord.General:MaybePersistSession(force)
    if not localIsGeneral or not localClaimTs then return end
    local now = GetTime()
    if not force and (now - lastPersistAt) < 60 then return end
    lastPersistAt = now
    self:PersistSession()
end

function Overlord.General:ApplyRemoteDown(sender, faction, pool, claimTs, killerName, killerClass, zoneId)
    if not PoolMatches(pool) then return false end
    if not faction then return false end
    local slot = GetSlotTable(pool, faction)
    local alreadyTombstoned = IsTombstoned(pool, faction, sender, claimTs)
    if not slot and alreadyTombstoned then
        return true
    end
    if slot and (not SenderMatches(slot.holder, sender) or slot.claimTs ~= claimTs) then
        return AddTombstone(pool, faction, sender, claimTs) == true
    end

    if not AddTombstone(pool, faction, sender, claimTs) then return false end
    if slot then
        ClearSlot(pool, faction)
    end
    if SenderMatches(sender, GetLocalFullName()) and localClaimTs == claimTs then
        localIsGeneral = false
        localClaimTs = nil
        localHolderFaction = nil
        ResetGpBroadcastCache()
        self:StopPositionTicker()
        self:ClearPersistedSession()
    end
    NotifyGeneralFallen(sender, killerName, faction, claimTs)
    OnGeneralSlotCleared()
    if faction == Overlord.PlayerFaction and self:IsRaidLeader() and not self:IsLocalHolder() then
        C_Timer.After(0, function()
            if not Overlord.General then return end
            if Overlord.General:IsRaidLeader() and not Overlord.General:IsLocalHolder()
                and not Overlord.General:GetSlot(faction) then
                Overlord.General:TryClaim(true)
            end
        end)
    end
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    return true
end

function Overlord.General:ClearLocalOnDeath()
    if not localIsGeneral or not localClaimTs then return false end
    local claimTs = localClaimTs
    local victimName = GetLocalFullName()
    local faction = localHolderFaction or Overlord.PlayerFaction
    pendingDownBroadcast = {
        claimTs = claimTs,
        victimName = victimName,
        faction = faction,
    }
    local pool = self:GetPoolTag()
    localIsGeneral = false
    localClaimTs = nil
    localHolderFaction = nil
    ResetGpBroadcastCache()
    self:ClearPersistedSession()
    self:StopPositionTicker()
    if pool ~= "" and faction and victimName and claimTs then
        AddTombstone(pool, faction, victimName, claimTs, true)
        ClearSlot(pool, faction)
    end
    OnGeneralSlotCleared()
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    return true
end

function Overlord.General:EmitPendingDown(killerName, killerClass, zoneId)
    local pending = pendingDownBroadcast
    if not pending then return false end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return false end
    if not Overlord.GeneralSync or not pending.victimName or pending.victimName == "" then
        return false
    end
    Overlord.GeneralSync:BroadcastDown(
        pending.claimTs, killerName, killerClass, zoneId, pending.victimName, pending.faction)
    NotifyGeneralFallen(pending.victimName, killerName, pending.faction, pending.claimTs)
    pendingDownBroadcast = nil
    return true
end

function Overlord.General:OnLocalDeath(killerName, killerClass, zoneId)
    if pendingDownBroadcast then
        return self:EmitPendingDown(killerName, killerClass, zoneId)
    end
    if not localIsGeneral or not localClaimTs then return end
    local claimTs = localClaimTs
    local victimName = GetLocalFullName()
    local faction = localHolderFaction or Overlord.PlayerFaction
    if Overlord.GeneralSync and victimName and victimName ~= "" then
        Overlord.GeneralSync:BroadcastDown(
            claimTs, killerName, killerClass, zoneId, victimName, faction)
    end
    NotifyGeneralFallen(victimName, killerName, faction, claimTs)
    local pool = self:GetPoolTag()
    localIsGeneral = false
    localClaimTs = nil
    localHolderFaction = nil
    ResetGpBroadcastCache()
    self:ClearPersistedSession()
    self:StopPositionTicker()
    if pool ~= "" and faction and victimName and claimTs then
        AddTombstone(pool, faction, victimName, claimTs, true)
        ClearSlot(pool, faction)
    end
    OnGeneralSlotCleared()
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
end

function Overlord.General:ApplyRemoteRelease(sender, faction, pool, claimTs)
    if not PoolMatches(pool) then return false end
    if not faction then return false end
    local slot = GetSlotTable(pool, faction)
    if slot and (not SenderMatches(slot.holder, sender) or slot.claimTs ~= claimTs) then
        return AddTombstone(pool, faction, sender, claimTs) == true
    end
    if not AddTombstone(pool, faction, sender, claimTs) then return false end
    if slot then
        ClearSlot(pool, faction)
    end
    if SenderMatches(sender, GetLocalFullName()) and localClaimTs == claimTs then
        localIsGeneral = false
        localClaimTs = nil
        localHolderFaction = nil
        ResetGpBroadcastCache()
        self:StopPositionTicker()
        self:ClearPersistedSession()
    end
    OnGeneralSlotCleared()
    -- Handoff : apres GX, le nouveau chef de raid local reprend le slot libere (faction locale).
    if faction == Overlord.PlayerFaction and self:IsRaidLeader() and not self:IsLocalHolder() then
        C_Timer.After(0, function()
            if not Overlord.General then return end
            if Overlord.General:IsRaidLeader() and not Overlord.General:IsLocalHolder()
                and not Overlord.General:GetSlot(faction) then
                Overlord.General:TryClaim(true)
            end
        end)
    end
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    return true
end

function Overlord.General:StopPositionTicker()
    if gpTicker then
        gpTicker:Cancel()
        gpTicker = nil
    end
end

function Overlord.General:StartPositionTicker()
    self:StopPositionTicker()
    gpTicker = C_Timer.NewTicker(self.GP_INTERVAL, function()
        if not localIsGeneral or not IsGeneralFrontContext() or Overlord.InstanceSuspended then
            Overlord.General:StopPositionTicker()
            return
        end
        if not Overlord.General:IsRaidLeader() then
            Overlord.General:TryRelease(true)
            Overlord.General:StopPositionTicker()
            return
        end
        local now = GetTime()
        local mx, my, mapID = Overlord.General:GetLocalMapPosition()
        local forceHeartbeat = (now - lastGpHeartbeatAt) >= GP_HEARTBEAT_SEC
        if mx and my and mapID then
            local moved = ShouldBroadcastGp(mx, my, mapID)
            if moved or forceHeartbeat then
                Overlord.General:UpdatePosition(mx, my, mapID, now)
                if Overlord.GeneralSync then
                    Overlord.GeneralSync:BroadcastPosition(mx, my, mapID)
                end
                if forceHeartbeat or moved then
                    lastGpHeartbeatAt = now
                end
            end
        end
    end)
end

local function CampaignEpoch()
    return OverlordDB and tonumber(OverlordDB.lastResetTimestamp) or 0
end

function Overlord.General:ClearPersistedSession()
    if OverlordDB then
        OverlordDB.generalSession = nil
    end
end

function Overlord.General:PersistSession()
    if not OverlordDB then return end
    if not localIsGeneral or not localClaimTs then
        self:ClearPersistedSession()
        return
    end
    local pool = self:GetPoolTag()
    local faction = localHolderFaction or Overlord.PlayerFaction
    local slot = GetSlotTable(pool, faction)
    OverlordDB.generalSession = {
        claimTs = localClaimTs,
        pool = pool,
        faction = faction,
        mapX = slot and slot.mapX,
        mapY = slot and slot.mapY,
        mapID = slot and slot.mapID,
        campaignEpoch = CampaignEpoch(),
    }
end

function Overlord.General:ResyncToGroup(force)
    if not localIsGeneral or not localClaimTs then return end
    if not IsInGroup() then return end
    local now = GetTime()
    if not force and (now - lastGroupResyncAt) < GROUP_RESYNC_COOLDOWN then return end
    lastGroupResyncAt = now
    local mx, my, mapID = self:GetLocalMapPosition()
    if not mx or not my or not mapID then
        local pool = self:GetPoolTag()
        local slot = GetSlotTable(pool, self:GetLocalHolderFaction())
        if slot then
            mx, my, mapID = slot.mapX, slot.mapY, slot.mapID
        end
    end
    if not mx or not my or not mapID then return end
    if Overlord.GeneralSync and Overlord.GeneralSync.BroadcastGroupResync then
        Overlord.GeneralSync:BroadcastGroupResync(mx, my, mapID, localClaimTs)
    end
end

function Overlord.General:TryRestoreLocalGeneral()
    if localIsGeneral then return true end
    if not OverlordDB or not OverlordDB.generalSession then return false end
    if Overlord.ManualBounty and Overlord.ManualBounty.IsLocalPlayerTargeted
        and Overlord.ManualBounty:IsLocalPlayerTargeted() then
        self:ClearPersistedSession()
        return false
    end
    -- Pas de restauration solo : evite les annonces fantomes a chaque invitation.
    if not IsInGroup() then return false end
    if Overlord.IsCaptureSyncPending and Overlord:IsCaptureSyncPending() then
        if not restoreRetryTimer then
            restoreRetryTimer = true
            C_Timer.After(3, function()
                restoreRetryTimer = nil
                if Overlord.General and not Overlord.InstanceSuspended then
                    Overlord.General:TryRestoreLocalGeneral()
                end
            end)
        end
        return false
    end

    local sess = OverlordDB.generalSession
    if (sess.campaignEpoch or 0) ~= CampaignEpoch() then
        self:ClearPersistedSession()
        return false
    end

    local pool = self:GetPoolTag()
    if pool == "" or (sess.pool or ""):lower() ~= pool:lower() then return false end
    if sess.faction ~= Overlord.PlayerFaction then
        self:ClearPersistedSession()
        return false
    end
    if Overlord.InstanceSuspended or IsInInstance() then return false end
    if not self:IsRaidLeader() then return false end
    -- Restauration uniquement sur la carte du front (pas InActiveFront global hors zone).
    if not IsOnOverlordFrontMap() then return false end
    if Overlord.CommunityModeEnabled ~= false
        and (not Overlord.Sync or not Overlord.Sync.FindCommunityClub or not Overlord.Sync:FindCommunityClub()) then
        return false
    end

    local claimTs = tonumber(sess.claimTs) or 0
    if claimTs <= 0 then
        self:ClearPersistedSession()
        return false
    end

    local myName = GetLocalFullName()
    if IsTombstoned(pool, sess.faction, myName, claimTs) then
        self:ClearPersistedSession()
        return false
    end

    local existing = self:GetSlot(sess.faction)
    if existing and not SenderMatches(existing.holder, GetLocalFullName()) then
        self:ClearPersistedSession()
        return false
    end

    local mx, my, mapID = self:GetLocalMapPosition()
    if not mx or not my or not mapID then
        mx, my, mapID = sess.mapX, sess.mapY, sess.mapID
    end
    if not mx or not my or not mapID then return false end

    local myName = GetLocalFullName()
    localIsGeneral = true
    localClaimTs = claimTs
    localHolderFaction = sess.faction
    self:SetActive(myName, sess.faction, claimTs, mx, my, mapID, GetTime(), pool)

    if Overlord.GeneralSync then
        ResetGpBroadcastCache()
        -- Restauration silencieuse : pas de GE/GP global, resync raid/groupe seulement.
        Overlord.GeneralSync:BroadcastGroupResync(mx, my, mapID, claimTs)
    end
    skipNextEnterFrontGp = true
    self:StartPositionTicker()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    InvalidateNameplateCache()
    self:PersistSession()
    Dbg("general restaure claimTs=" .. tostring(claimTs))
    return true
end

function Overlord.General:TryRelease(silent)
    if not localIsGeneral then return false end
    local claimTs = localClaimTs
    local faction = localHolderFaction or Overlord.PlayerFaction
    if Overlord.GeneralSync and claimTs then
        Overlord.GeneralSync:BroadcastRelease(claimTs, faction)
    end
    localIsGeneral = false
    localClaimTs = nil
    localHolderFaction = nil
    ResetGpBroadcastCache()
    self:ClearPersistedSession()
    self:StopPositionTicker()
    local pool = self:GetPoolTag()
    if pool ~= "" and faction and claimTs then
        AddTombstone(pool, faction, GetLocalFullName(), claimTs, true)
        ClearSlot(pool, faction)
        self:RequestMapRefresh()
    end
    if not silent and L and L.GENERAL_RELEASED_SELF and Overlord.PrintNotification then
        Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.GENERAL_RELEASED_SELF)
    end
    if not silent and Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("general_release")
    end
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    OnGeneralSlotCleared()
    return true
end

function Overlord.General:TryClaim(silentFail)
    if Overlord.InstanceSuspended or IsInInstance() then
        if not silentFail and L and L.GENERAL_INSTANCE and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_INSTANCE)
        end
        return false
    end
    if InCombatLockdown() then
        if not silentFail and L and L.GENERAL_COMBAT and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_COMBAT)
        end
        return false
    end
    if Overlord.ManualBounty and Overlord.ManualBounty.IsLocalPlayerTargeted
        and Overlord.ManualBounty:IsLocalPlayerTargeted() then
        if not silentFail and L and L.GENERAL_BOUNTY_BLOCKED and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_BOUNTY_BLOCKED)
        end
        return false
    end
    if not self:IsRaidLeader() then
        if not silentFail and L and L.GENERAL_NOT_LEADER and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_NOT_LEADER)
        end
        return false
    end
    if not IsGeneralFrontContext() then
        if not silentFail and L and L.GENERAL_NOT_ON_FRONT and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_NOT_ON_FRONT)
        end
        return false
    end
    if Overlord.CommunityModeEnabled ~= false
        and (not Overlord.Sync or not Overlord.Sync.FindCommunityClub or not Overlord.Sync:FindCommunityClub()) then
        if not silentFail and L and L.GENERAL_NOT_COMMUNITY and Overlord.PrintNotification then
            Overlord:PrintNotification("|cffff6600[Overlord]|r " .. L.GENERAL_NOT_COMMUNITY)
        end
        return false
    end

    local pool = self:GetPoolTag()
    local faction = Overlord.PlayerFaction
    if pool == "" or not faction then return false end

    local existing = self:GetSlot(faction)
    if existing and not SenderMatches(existing.holder, GetLocalFullName()) then
        if not silentFail then
            local short = (existing.holder or "?"):match("^(.-)%-") or existing.holder
            if L and L.GENERAL_SLOT_TAKEN and Overlord.PrintNotification then
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.GENERAL_SLOT_TAKEN, short))
            end
        end
        return false
    end

    local mx, my, mapID = self:GetLocalMapPosition()
    if not mx or not my or not mapID then
        if not silentFail and L and L.GENERAL_NOT_ON_FRONT and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GENERAL_NOT_ON_FRONT)
        end
        return false
    end

    local claimTs = time()
    local myName = GetLocalFullName()
    localIsGeneral = true
    localClaimTs = claimTs
    localHolderFaction = faction
    ResetGpBroadcastCache()
    self:SetActive(myName, faction, claimTs, mx, my, mapID, GetTime(), pool)

    if Overlord.GeneralSync then
        Overlord.GeneralSync:BroadcastClaim(mx, my, mapID, claimTs)
        Overlord.GeneralSync:BroadcastPosition(mx, my, mapID)
    end
    self:StartPositionTicker()

    if Overlord.PlayAddonSound then
        Overlord:PlayAddonSound("general_claim")
    end

    local frontName = ResolveFrontNameFromMapID(mapID)
    if faction == "Horde" then
        if L and L.GENERAL_ASSUMED_SELF_HORDE and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. string.format(L.GENERAL_ASSUMED_SELF_HORDE, frontName))
        end
    else
        if L and L.GENERAL_ASSUMED_SELF and Overlord.PrintNotification then
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. string.format(L.GENERAL_ASSUMED_SELF, frontName))
        end
    end
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
    InvalidateNameplateCache()
    self:PersistSession()
    self:ResyncToGroup(true)
    return true
end

function Overlord.General:OnPlayerFactionChanged()
    if self:IsLocalHolder() then
        self:TryRelease(true)
    else
        self:ClearPersistedSession()
    end
    pendingDownBroadcast = nil
    BumpRevision()
    InvalidateNameplateCache()
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
end

function Overlord.General:ToggleRole()
    if self:IsLocalHolder() then
        return self:TryRelease(false)
    end
    return self:TryClaim()
end

function Overlord.General:OnLeaveFront()
    self:StopPositionTicker()
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.StopDuelMusic then
        Overlord.GeneralNameplate:StopDuelMusic()
    end
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.UpdateCombatLogSubscription then
        Overlord.GeneralNameplate:UpdateCombatLogSubscription()
    end
end

function Overlord.General:OnEnterFront()
    if pendingDownBroadcast and self.EmitPendingDown then
        self:EmitPendingDown(nil, nil, "")
    end
    if not localIsGeneral then
        self:TryRestoreLocalGeneral()
    end
    if not localIsGeneral or Overlord.InstanceSuspended then return end
    if not self:IsRaidLeader() then
        self:TryRelease(true)
        return
    end
    local mx, my, mapID = self:GetLocalMapPosition()
    if mx and my and mapID then
        self:UpdatePosition(mx, my, mapID, GetTime())
        if Overlord.GeneralSync and not skipNextEnterFrontGp and ShouldBroadcastGp(mx, my, mapID) then
            Overlord.GeneralSync:BroadcastPosition(mx, my, mapID)
        end
    end
    skipNextEnterFrontGp = false
    self:StartPositionTicker()
    if IsInGroup() then
        self:ResyncToGroup(true)
    end
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.UpdateCombatLogSubscription then
        Overlord.GeneralNameplate:UpdateCombatLogSubscription()
    end
end

function Overlord.General:OnInstanceSuspend()
    if pendingLeaderClaimTimer then
        pendingLeaderClaimTimer:Cancel()
        pendingLeaderClaimTimer = nil
    end
    if self:IsLocalHolder() then
        self:TryRelease(true)
    end
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.StopDuelMusic then
        Overlord.GeneralNameplate:StopDuelMusic()
    end
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.UpdateCombatLogSubscription then
        Overlord.GeneralNameplate:UpdateCombatLogSubscription()
    end
end

function Overlord.General:OnCampaignReset()
    if pendingLeaderClaimTimer then
        pendingLeaderClaimTimer:Cancel()
        pendingLeaderClaimTimer = nil
    end
    wipe(slots)
    -- Vider les index lies avec les valeurs : sinon les tombstones et quotas
    -- de la campagne precedente restent actifs apres le reset visible.
    for _, state in ipairs({ tombstoneState, allyAlertState, fallenAlertState }) do
        wipe(state.values)
        wipe(state.nodes)
        state.head, state.tail, state.count = nil, nil, 0
    end
    pendingDownBroadcast = nil
    localIsGeneral = false
    localClaimTs = nil
    localHolderFaction = nil
    ResetGpBroadcastCache()
    self:ClearPersistedSession()
    self:StopPositionTicker()
    BumpRevision()
    OnGeneralSlotCleared()
    self:RequestMapRefresh()
    if Overlord.Button and Overlord.Button.RefreshGeneralButton then
        Overlord.Button:RefreshGeneralButton()
    end
end

function Overlord.General:OnGroupRosterUpdate()
    if Overlord.InstanceSuspended or IsInInstance() then return end
    if rosterDebounceTimer then
        rosterDebounceTimer:Cancel()
        rosterDebounceTimer = nil
    end
    -- After() ne renvoie pas de handle annulable : sous une rafale roster, chaque
    -- event armait donc sa propre closure malgre le Cancel ci-dessus.
    rosterDebounceTimer = C_Timer.NewTimer(0.5, function()
        rosterDebounceTimer = nil
        if not Overlord.General or Overlord.InstanceSuspended or IsInInstance() then return end
        if Overlord.General:IsLocalHolder() and not Overlord.General:IsRaidLeader() then
            Overlord.General:TryRelease(true)
        end
        if pendingLeaderClaimTimer then
            pendingLeaderClaimTimer:Cancel()
            pendingLeaderClaimTimer = nil
        end
        if Overlord.General:IsRaidLeader() and not Overlord.General:IsLocalHolder() then
            TryClearStaleLocalSlotForFormerLeader(Overlord.PlayerFaction)
        end
        if Overlord.General:IsLocalHolder() then
            Overlord.General:ResyncToGroup(true)
        end
        if Overlord.Button and Overlord.Button.RefreshGeneralButton then
            Overlord.Button:RefreshGeneralButton()
        end
    end)
end

function Overlord.General:AppendToSrQueue(queue, minimalResponseOnly)
    if not queue or not Overlord.GeneralSync or not localIsGeneral or not localClaimTs then return end
    local mx, my, mapID = self:GetLocalMapPosition()
    if not mx or not my or not mapID then
        local pool = self:GetPoolTag()
        local slot = GetSlotTable(pool, self:GetLocalHolderFaction())
        if slot then
            mx, my, mapID = slot.mapX, slot.mapY, slot.mapID
        end
    end
    if not mx or not my or not mapID then return end
    local ge = Overlord.GeneralSync:BuildGEPayload(mx, my, mapID, localClaimTs)
    local gp = Overlord.GeneralSync:BuildGPPayload(mx, my, mapID, localClaimTs)
    if ge and ge ~= "" then
        table.insert(queue, { type = "GE", data = ge })
    end
    if gp and gp ~= "" then
        table.insert(queue, { type = "GP", data = gp })
    end
end

function Overlord.General:Initialize()
    if generalInitialized then return end
    generalInitialized = true
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:SetScript("OnEvent", function(_, event)
        if event == "GROUP_ROSTER_UPDATE" then
            Overlord.General:OnGroupRosterUpdate()
        end
    end)
    if not passivePruneTicker then
        passivePruneTicker = C_Timer.NewTicker(15, function()
            if Overlord.InstanceSuspended then return end
            if Overlord.General and Overlord.General.PruneStale then
                Overlord.General:PruneStale()
            end
        end)
    end
    C_Timer.After(2, function()
        if not Overlord.General or Overlord.InstanceSuspended then return end
        Overlord.General:TryRestoreLocalGeneral()
    end)
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.Initialize then
        Overlord.GeneralNameplate:Initialize()
    end
end

Overlord.General.FacCode = FacCode
Overlord.General.FacFromCode = FacFromCode
Overlord.General.SenderMatches = SenderMatches
Overlord.General.GetLocalFullName = GetLocalFullName
Overlord.General.NormalizeGeneralMapID = NormalizeGeneralMapID
Overlord.General.MapIDsMatchForDisplay = GeneralMapIDsMatch
Overlord.General.IsGeneralFrontContext = IsGeneralFrontContext
