-- GeneralSync.lua - Réseau Général de faction (GE claim, GP position, GX release, GD chute, GM musique duel)
Overlord = Overlord or {}
Overlord.GeneralSync = {}

local GE_DEDUP_SEC = 8
local GP_DEDUP_SEC = 5
local GX_DEDUP_SEC = 8
local GD_DEDUP_SEC = 10
local GM_DEDUP_SEC = 8
local DEDUP_PURGE_INTERVAL = 60
local lastDedupPurgeAt = 0

local recentGE = {}
local recentGP = {}
local recentGX = {}
local recentGD = {}
local recentGM = {}
local DEDUP_MAX_ENTRIES = 256
local dedupStates = {
    [recentGE] = { count = 0, ttl = GE_DEDUP_SEC },
    [recentGP] = { count = 0, ttl = GP_DEDUP_SEC },
    [recentGX] = { count = 0, ttl = GX_DEDUP_SEC },
    [recentGD] = { count = 0, ttl = GD_DEDUP_SEC },
    [recentGM] = { count = 0, ttl = GM_DEDUP_SEC },
}

local function UnlinkDedupNode(state, key)
    local node = state and state.nodes and state.nodes[key]
    if not node then return nil end
    if node.prev then node.prev.next = node.next else state.head = node.next end
    if node.next then node.next.prev = node.prev else state.tail = node.prev end
    state.nodes[key] = nil
    node.prev, node.next = nil, nil
    return node
end

local function TouchDedupNode(state, key, expiresAt)
    state.nodes = state.nodes or {}
    local node = UnlinkDedupNode(state, key) or { key = key }
    node.expiresAt = expiresAt
    node.prev, node.next = state.tail, nil
    if state.tail then state.tail.next = node else state.head = node end
    state.tail = node
    state.nodes[key] = node
end

local GE_COMMUNITY_MAX = 30
local GE_COMMUNITY_MAX_LARGE = 12
local GE_COMMUNITY_DELAY = 0.25
local GP_COMMUNITY_MAX = 12
local GP_COMMUNITY_MAX_LARGE = 6
local GP_COMMUNITY_DELAY = 0.35
local GD_COMMUNITY_MAX = 30
local GD_COMMUNITY_MAX_LARGE = 12
local GD_REPLAY_DELAY_1 = 1.0
local GD_REPLAY_DELAY_2 = 3.0
local GM_COMMUNITY_MAX = 16
local GM_COMMUNITY_MAX_LARGE = 8
local GM_COMMUNITY_DELAY = 0.5
local GM_BROADCAST_COOLDOWN = 10
local lastGmBroadcastAt = 0

local function Dbg(msg)
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print("|cFFFF8800[Overlord:GeneralSync]|r " .. tostring(msg))
    end
end

local function CampaignEpoch()
    -- Wire epoch normalise (parite avec K/LK/DM) : sur region 1, permet a un client a jour et a un
    -- ancien client de s'accepter mutuellement (couple a la tolerance IsLegacyUSResetAhead cote reception).
    if Overlord.GetCurrentCampaignWireEpoch then
        local e = Overlord:GetCurrentCampaignWireEpoch()
        if e and e > 0 then return e end
    end
    return OverlordDB and OverlordDB.lastResetTimestamp or 0
end

local function AcceptEpoch(epochStr)
    local sync = Overlord.Sync
    if sync and sync.IsCurrentCampaignEpoch then
        return sync:IsCurrentCampaignEpoch(tonumber(epochStr))
    end
    local remote = tonumber(epochStr) or 0
    local localEpoch = CampaignEpoch()
    if localEpoch <= 0 then return remote <= 0 end
    return remote == localEpoch
end

local function ForgetDedup(tbl, key)
    if tbl[key] == nil then return end
    tbl[key] = nil
    local state = dedupStates[tbl]
    if state then
        UnlinkDedupNode(state, key)
        state.count = math.max(0, state.count - 1)
        state.blockedUntil = nil
    end
end

local function CanRememberDedup(tbl, key, now)
    local state = dedupStates[tbl]
    if not state then return false end
    if tbl[key] ~= nil or state.count < DEDUP_MAX_ENTRIES then return true end
    now = tonumber(now) or GetTime()
    if state.blockedUntil and now < state.blockedUntil then return false end
    local oldest = state.head
    if oldest and now >= (tonumber(oldest.expiresAt) or 0) then
        ForgetDedup(tbl, oldest.key)
        return true
    end
    -- Une rafale au plafond ne doit pas rescanner 256 lignes pour chaque paquet.
    state.blockedUntil = oldest and oldest.expiresAt or (now + state.ttl)
    return false
end

local function PruneDedupTables(now)
    if now - lastDedupPurgeAt < DEDUP_PURGE_INTERVAL then return end
    lastDedupPurgeAt = now
    -- Une seule tete par cache : cout fixe (5), jamais 5 x 256 dans le handler.
    for cache, state in pairs(dedupStates) do
        local oldest = state.head
        if oldest and now >= (tonumber(oldest.expiresAt) or 0) then
            ForgetDedup(cache, oldest.key)
        end
    end
end

local function RememberDedup(tbl, key, now)
    local state = dedupStates[tbl]
    if not state or not CanRememberDedup(tbl, key, now) then return false end
    if tbl[key] == nil then state.count = state.count + 1 end
    tbl[key] = now
    TouchDedupNode(state, key, now + state.ttl)
    return true
end

local function IsSenderLocal(sender)
    local sync = Overlord.Sync
    if sync and sync.IsSenderLocalPlayer then
        return sync:IsSenderLocalPlayer(sender)
    end
    local gen = Overlord.General
    if gen and gen.GetLocalFullName and gen.SenderMatches then
        return gen.SenderMatches(sender, gen.GetLocalFullName())
    end
    return false
end

local function PoolTag()
    if Overlord.General and Overlord.General.GetPoolTag then
        return Overlord.General:GetPoolTag() or ""
    end
    return ""
end

local function ResolveAcceptedPool(pool, sender, sourceChannel)
    local sync = Overlord.Sync
    if sync and sync.ResolveDirectGroupTerritorialPool then
        return sync:ResolveDirectGroupTerritorialPool(pool, sender, sourceChannel)
    end
    local localPool = PoolTag()
    if not localPool or localPool == "" then return nil end
    return (pool or ""):lower() == localPool:lower() and localPool or nil
end

local function DedupSenderKey(sender)
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(sender) or (sender or ""):lower()
    end
    return (sender or ""):lower()
end

local function NameDedupKey(name)
    if not name or name == "" then return nil end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(name)
    end
    return (name:match("^(.-)%-") or name):lower()
end

local function SenderMatchesName(sender, name)
    if not sender or sender == "" or not name or name == "" then return false end
    if sender:sub(1, 5) == "BNet-" then return false end
    local sk = NameDedupKey(sender)
    local nk = NameDedupKey(name)
    return sk ~= nil and nk ~= nil and sk == nk
end

local function GetSenderCommunityFaction(sender)
    local sync = Overlord.Sync
    if not sync or not sync.GetOnlineCommunityMemberFaction then return nil end
    local fac = sync:GetOnlineCommunityMemberFaction(sender)
    if fac then return fac end
    if sync.NormalizeContributorFullName then
        local full = sync:NormalizeContributorFullName(sender)
        if full and full ~= sender then
            fac = sync:GetOnlineCommunityMemberFaction(full)
            if fac then return fac end
        end
    end
    if sync.GetCaptureContributorDedupKey then
        local dk = sync:GetCaptureContributorDedupKey(sender)
        if dk and dk ~= "" then
            fac = sync:GetOnlineCommunityMemberFaction(dk)
            if fac then return fac end
        end
    end
    return nil
end

local function IsKnownCommunitySender(sender)
    local sync = Overlord.Sync
    if not sync or not sender or sender == "" then return false end
    if sync.IsGuildKeepCommunitySender then
        return sync:IsGuildKeepCommunitySender(sender)
    end
    return GetSenderCommunityFaction(sender) ~= nil
end

local function SenderFactionMatches(sender, faction, strict)
    if not sender or not faction then return true end
    local memberFaction = GetSenderCommunityFaction(sender)
    if memberFaction == nil and strict then
        if not IsKnownCommunitySender(sender) then return false end
        local sync = Overlord.Sync
        if sync and sync.GetOnlineCommunityMembersIfFresh then
            sync:GetOnlineCommunityMembersIfFresh(15)
        end
        memberFaction = GetSenderCommunityFaction(sender)
        if memberFaction == nil then return false end
    elseif memberFaction == nil then
        return true
    end
    local FA = Enum.PvPFaction
    if not FA then return true end
    if faction == "Horde" then
        return memberFaction == FA.Horde
    end
    if faction == "Alliance" then
        return memberFaction == FA.Alliance
    end
    return true
end

-- Faction de l'expediteur via raid/groupe (duel General cross-faction).
local function GetRaidUnitFactionForSender(sender)
    if not sender or sender == "" or not IsInGroup() then return nil end
    local sync = Overlord.Sync
    return sync and sync.GetGroupMemberFaction
        and sync:GetGroupMemberFaction(sender) or nil
end

-- Accepte GE/GP/GX/GD : communaute stricte OU raid/groupe avec faction WoW coherente.
local function AcceptGeneralSender(sender, faction)
    if not sender or not faction then return true end
    -- Forever has no club roster. A beta envelope retains the claiming player
    -- as author; the gateway must never become the commander instead.
    if Overlord.CommunityModeEnabled == false and Overlord.BetaNetwork
        and Overlord.BetaNetwork:IsDispatching(sender) then
        return faction == "Alliance" or faction == "Horde"
    end
    local sync = Overlord.Sync
    if sync and sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender) then
        local raidFac = GetRaidUnitFactionForSender(sender)
        if raidFac == faction then return true end
        if raidFac and raidFac ~= faction then return false end
        -- Membre du groupe sans match faction explicite (dedup nom) : faire confiance au roster.
        return true
    end
    return SenderFactionMatches(sender, faction, true)
end

local function NormalizeName(name)
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        return sync:NormalizeContributorFullName(name) or name
    end
    return name
end

local function AcceptName(name)
    local sync = Overlord.Sync
    if sync and sync.AcceptSyncedContributorName then
        return sync:AcceptSyncedContributorName(name)
    end
    return name and name ~= "" and #name <= 50
end

local function IsLargeEvent()
    local sync = Overlord.Sync
    return sync and sync.IsLargeEvent and sync:IsLargeEvent()
end

local function FacCode(faction)
    if Overlord.General and Overlord.General.FacCode then
        return Overlord.General.FacCode(faction or Overlord.PlayerFaction)
    end
    return (faction == "Horde") and "H" or "A"
end

function Overlord.GeneralSync:BuildGEPayload(mapX, mapY, mapID, claimTs)
    local gen = Overlord.General
    local faction = (gen and gen.GetLocalHolderFaction and gen:GetLocalHolderFaction()) or Overlord.PlayerFaction
    local xC = math.floor((tonumber(mapX) or 0) * 100 + 0.5)
    local yC = math.floor((tonumber(mapY) or 0) * 100 + 0.5)
    return string.format("%s:%s:%d:%d:%d:%d:%d",
        FacCode(faction), PoolTag(), xC, yC, tonumber(mapID) or 0, claimTs or time(), CampaignEpoch())
end

function Overlord.GeneralSync:BuildGPPayload(mapX, mapY, mapID, claimTs)
    local gen = Overlord.General
    local faction = (gen and gen.GetLocalHolderFaction and gen:GetLocalHolderFaction()) or Overlord.PlayerFaction
    local xC = math.floor((tonumber(mapX) or 0) * 100 + 0.5)
    local yC = math.floor((tonumber(mapY) or 0) * 100 + 0.5)
    return string.format("%s:%s:%d:%d:%d:%d:%d:%d",
        FacCode(faction), PoolTag(), xC, yC, tonumber(mapID) or 0, claimTs or 0, time(), CampaignEpoch())
end

function Overlord.GeneralSync:BuildGXPayload(claimTs, faction)
    return string.format("%s:%s:%d:%d",
        FacCode(faction), PoolTag(), claimTs or 0, CampaignEpoch())
end

function Overlord.GeneralSync:BuildGDPayload(claimTs, killerName, killerClass, zoneId, victimName, victimFaction)
    return string.format("%s:%s:%d:%s:%s:%s:%d:%s",
        FacCode(victimFaction), PoolTag(), claimTs or 0,
        killerName or "", killerClass or "", zoneId or "",
        CampaignEpoch(), victimName or "")
end

function Overlord.GeneralSync:BuildGMPayload(claimTs)
    return string.format("%s:%d:%d:%d",
        PoolTag(), claimTs or 0, time(), CampaignEpoch())
end

local function EmitCommunity(msgType, payload, opts)
    if opts.community == false then return end
    if IsLargeEvent() and opts.communityInLarge == false then return end
    local sync = Overlord.Sync
    if not sync or not payload or payload == "" then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end

    local maxM = opts.communityMax or 16
    local delay = opts.communityDelay or 0.3
    local force = opts.communityForce == true

    local function once()
        if opts.enemyFactionOnly and sync.BroadcastToEnemyFactionCommunity then
            sync:BroadcastToEnemyFactionCommunity(msgType, payload, maxM, delay, force)
        elseif opts.allyFactionOnly and sync.BroadcastGeneralToFactionCommunity then
            sync:BroadcastGeneralToFactionCommunity(msgType, payload, maxM, delay, force)
        elseif sync.BroadcastToCommunity then
            sync:BroadcastToCommunity(msgType, payload, maxM, delay, force)
        end
    end
    once()
    if opts.replay then
        C_Timer.After(GD_REPLAY_DELAY_1, once)
        C_Timer.After(GD_REPLAY_DELAY_2, once)
    end
end

local function EmitAll(msgType, payload, opts)
    opts = opts or {}
    local sync = Overlord.Sync
    if not sync or not payload or payload == "" then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end

    if IsInGroup() or IsInRaid() then
        sync:Send(msgType, payload)
    end
    if opts.channel ~= false and sync.SendToChannel then
        sync:SendToChannel(msgType, payload, opts.critical == true)
    end
    if opts.allyCommunity ~= false then
        EmitCommunity(msgType, payload, {
            allyFactionOnly = true,
            communityMax = opts.communityMax,
            communityDelay = opts.communityDelay,
            communityForce = opts.communityForce,
            communityInLarge = opts.communityInLarge,
            replay = opts.allyReplay ~= nil and opts.allyReplay or opts.replay,
        })
    end
    if opts.enemyCommunity then
        EmitCommunity(msgType, payload, {
            enemyFactionOnly = true,
            communityMax = opts.enemyCommunityMax or opts.communityMax,
            communityDelay = opts.enemyCommunityDelay or opts.communityDelay,
            communityForce = opts.communityForce,
            communityInLarge = opts.communityInLarge,
            replay = opts.enemyReplay ~= nil and opts.enemyReplay or opts.replay,
        })
    end
end

function Overlord.GeneralSync:BroadcastGroupResync(mapX, mapY, mapID, claimTs)
    if not IsInGroup() then return end
    local sync = Overlord.Sync
    if not sync or not sync.Send then return end
    local ge = self:BuildGEPayload(mapX, mapY, mapID, claimTs)
    local gp = self:BuildGPPayload(mapX, mapY, mapID, claimTs)
    if ge and ge ~= "" then
        sync:Send("GE", ge)
    end
    if gp and gp ~= "" then
        sync:Send("GP", gp)
    end
    Dbg("resync groupe GE/GP claimTs=" .. tostring(claimTs))
end

function Overlord.GeneralSync:BroadcastClaim(mapX, mapY, mapID, claimTs)
    local payload = self:BuildGEPayload(mapX, mapY, mapID, claimTs)
    local isLarge = IsLargeEvent()
    EmitAll("GE", payload, {
        critical = true,
        communityForce = true,
        communityInLarge = true,
        communityMax = isLarge and GE_COMMUNITY_MAX_LARGE or GE_COMMUNITY_MAX,
        communityDelay = GE_COMMUNITY_DELAY,
        enemyCommunity = true,
        enemyCommunityMax = isLarge and GE_COMMUNITY_MAX_LARGE or GE_COMMUNITY_MAX,
        enemyCommunityDelay = GE_COMMUNITY_DELAY,
        allyReplay = true,
        enemyReplay = true,
    })
    Dbg("GE claim " .. tostring(claimTs))
end

function Overlord.GeneralSync:BroadcastPosition(mapX, mapY, mapID)
    local gen = Overlord.General
    if not gen or not gen.IsLocalHolder or not gen:IsLocalHolder() then return end
    local claimTs = gen.GetLocalClaimTs and gen:GetLocalClaimTs()
    if not claimTs then return end
    local payload = self:BuildGPPayload(mapX, mapY, mapID, claimTs)
    local isLarge = IsLargeEvent()
    EmitAll("GP", payload, {
        critical = false,
        forceTargets = false,
        communityForce = true,
        communityInLarge = true,
        communityMax = isLarge and GP_COMMUNITY_MAX_LARGE or GP_COMMUNITY_MAX,
        communityDelay = GP_COMMUNITY_DELAY,
        allyCommunity = true,
        enemyCommunity = true,
        enemyCommunityMax = isLarge and GP_COMMUNITY_MAX_LARGE or GP_COMMUNITY_MAX,
        enemyCommunityDelay = GP_COMMUNITY_DELAY,
    })
end

function Overlord.GeneralSync:BroadcastRelease(claimTs, faction)
    local payload = self:BuildGXPayload(claimTs, faction)
    local isLarge = IsLargeEvent()
    EmitAll("GX", payload, {
        critical = true,
        communityForce = true,
        communityInLarge = true,
        communityMax = isLarge and GE_COMMUNITY_MAX_LARGE or GE_COMMUNITY_MAX,
        communityDelay = GE_COMMUNITY_DELAY,
        allyReplay = true,
        enemyCommunity = true,
        enemyCommunityMax = isLarge and GE_COMMUNITY_MAX_LARGE or GE_COMMUNITY_MAX,
        enemyCommunityDelay = GE_COMMUNITY_DELAY,
        enemyReplay = true,
    })
    Dbg("GX release " .. tostring(claimTs))
end

function Overlord.GeneralSync:BroadcastDown(claimTs, killerName, killerClass, zoneId, victimName, victimFaction)
    local payload = self:BuildGDPayload(claimTs, killerName, killerClass, zoneId, victimName, victimFaction)
    local isLarge = IsLargeEvent()
    EmitAll("GD", payload, {
        critical = true,
        communityForce = true,
        communityInLarge = true,
        communityMax = isLarge and GD_COMMUNITY_MAX_LARGE or GD_COMMUNITY_MAX,
        communityDelay = GE_COMMUNITY_DELAY,
        allyReplay = true,
        enemyCommunity = true,
        enemyCommunityMax = isLarge and GD_COMMUNITY_MAX_LARGE or GD_COMMUNITY_MAX,
        enemyCommunityDelay = GE_COMMUNITY_DELAY,
        enemyReplay = true,
    })
    Dbg("GD down " .. tostring(victimName))
end

function Overlord.GeneralSync:BroadcastDuelMusicPulse()
    local gen = Overlord.General
    if not gen or not gen.IsLocalHolder or not gen:IsLocalHolder() then return end
    local onFront = gen.IsGeneralFrontContext and gen:IsGeneralFrontContext()
    if not onFront or Overlord.InstanceSuspended then return end
    local now = GetTime()
    if now - lastGmBroadcastAt < GM_BROADCAST_COOLDOWN then return end
    lastGmBroadcastAt = now

    local claimTs = gen.GetLocalClaimTs and gen:GetLocalClaimTs()
    if not claimTs then return end
    local payload = self:BuildGMPayload(claimTs)
    local isLarge = IsLargeEvent()
    EmitAll("GM", payload, {
        critical = false,
        communityForce = false,
        communityInLarge = true,
        communityMax = isLarge and GM_COMMUNITY_MAX_LARGE or GM_COMMUNITY_MAX,
        communityDelay = GM_COMMUNITY_DELAY,
        enemyCommunity = true,
        enemyCommunityMax = isLarge and GM_COMMUNITY_MAX_LARGE or GM_COMMUNITY_MAX,
        enemyCommunityDelay = GM_COMMUNITY_DELAY,
    })
    Dbg("GM duel music pulse")
end

local function IsValidGeneralTimestamp(value)
    return value > 0 and value < math.huge and value == math.floor(value)
end

local function ParseCoords(xCStr, yCStr, mapIDStr)
    local mapID = tonumber(mapIDStr) or 0
    local xC, yC = tonumber(xCStr), tonumber(yCStr)
    if mapID ~= mapID or mapID <= 0 or mapID == math.huge
        or mapID ~= math.floor(mapID)
        or not xC or not yC or xC ~= xC or yC ~= yC
        or xC < 0 or xC > 10000 or yC < 0 or yC > 10000 then
        return nil, nil, nil
    end
    return xC / 100, yC / 100, mapID
end

function Overlord.GeneralSync:OnReceiveGE(payload, sender, sourceChannel)
    if not payload or not sender or not Overlord.General then return end
    if IsSenderLocal(sender) then return end

    local facCode, pool, xCStr, yCStr, mapIDStr, claimTsStr, epochStr = strsplit(":", payload, 8)
    if not AcceptEpoch(epochStr) then return end
    local faction = Overlord.General.FacFromCode(facCode)
    pool = ResolveAcceptedPool(pool, sender, sourceChannel)
    if not faction or not pool then return end
    if not AcceptGeneralSender(sender, faction) then return end

    local claimTs = tonumber(claimTsStr) or 0
    if not IsValidGeneralTimestamp(claimTs) then return end
    local mapX, mapY, mapID = ParseCoords(xCStr, yCStr, mapIDStr)
    if not mapX then return end

    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = DedupSenderKey(sender) .. ":" .. tostring(claimTs)
    if recentGE[dedupKey] and (now - recentGE[dedupKey]) < GE_DEDUP_SEC then return end
    if not CanRememberDedup(recentGE, dedupKey, now) then return end

    local showPopup = (faction == Overlord.PlayerFaction)
    if Overlord.General:ApplyRemoteClaim(sender, faction, pool, mapX, mapY, mapID, claimTs, showPopup) then
        RememberDedup(recentGE, dedupKey, now)
    end
end

function Overlord.GeneralSync:OnReceiveGP(payload, sender, sourceChannel)
    if not payload or not sender or not Overlord.General then return end
    if IsSenderLocal(sender) then return end

    local facCode, pool, xCStr, yCStr, mapIDStr, claimTsStr, posTsStr, epochStr = strsplit(":", payload, 9)
    if not AcceptEpoch(epochStr) then return end
    local faction = Overlord.General.FacFromCode(facCode)
    pool = ResolveAcceptedPool(pool, sender, sourceChannel)
    if not faction or not pool then return end
    if not AcceptGeneralSender(sender, faction) then return end

    local claimTs = tonumber(claimTsStr) or 0
    local posTs = tonumber(posTsStr) or 0
    if not IsValidGeneralTimestamp(claimTs) or not IsValidGeneralTimestamp(posTs) then return end
    local mapX, mapY, mapID = ParseCoords(xCStr, yCStr, mapIDStr)
    if not mapX then return end

    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = DedupSenderKey(sender) .. ":" .. tostring(claimTs) .. ":"
        .. tostring(xCStr) .. ":" .. tostring(yCStr) .. ":" .. tostring(mapIDStr)
    if recentGP[dedupKey] and (now - recentGP[dedupKey]) < GP_DEDUP_SEC then return end
    if not CanRememberDedup(recentGP, dedupKey, now) then return end

    if Overlord.General:ApplyRemotePosition(sender, faction, pool, mapX, mapY, mapID, claimTs, posTs) then
        RememberDedup(recentGP, dedupKey, now)
    end
end

function Overlord.GeneralSync:OnReceiveGX(payload, sender, sourceChannel)
    if not payload or not sender or not Overlord.General then return end
    if IsSenderLocal(sender) then return end

    local facCode, pool, claimTsStr, epochStr = strsplit(":", payload, 5)
    if not AcceptEpoch(epochStr) then return end
    local faction = Overlord.General.FacFromCode(facCode)
    pool = ResolveAcceptedPool(pool, sender, sourceChannel)
    if not faction or not pool then return end
    if not AcceptGeneralSender(sender, faction) then return end

    local claimTs = tonumber(claimTsStr) or 0
    if not IsValidGeneralTimestamp(claimTs) then return end

    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = DedupSenderKey(sender) .. ":" .. tostring(claimTs)
    if recentGX[dedupKey] and (now - recentGX[dedupKey]) < GX_DEDUP_SEC then return end
    if not CanRememberDedup(recentGX, dedupKey, now) then return end

    if Overlord.General:ApplyRemoteRelease(sender, faction, pool, claimTs) then
        RememberDedup(recentGX, dedupKey, now)
    end
end

function Overlord.GeneralSync:OnReceiveGD(payload, sender, sourceChannel)
    if not payload or not sender or not Overlord.General then return end
    if IsSenderLocal(sender) then return end

    local facCode, pool, claimTsStr, killerName, killerClass, zoneId, epochStr, victimName
        = strsplit(":", payload, 8)
    if not AcceptEpoch(epochStr) then return end
    local faction = Overlord.General.FacFromCode(facCode)
    pool = ResolveAcceptedPool(pool, sender, sourceChannel)
    if not faction or not pool then return end
    if not AcceptGeneralSender(sender, faction) then return end

    killerName = NormalizeName(killerName)
    victimName = NormalizeName(victimName)
    if not AcceptName(victimName) then return end
    if not killerName or killerName == "" then
        killerName = "?"
    elseif not AcceptName(killerName) then
        killerName = "?"
    end
    if not SenderMatchesName(sender, victimName) then return end

    local claimTs = tonumber(claimTsStr) or 0
    if not IsValidGeneralTimestamp(claimTs) then return end

    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = DedupSenderKey(victimName) .. ":" .. tostring(claimTs)
    if recentGD[dedupKey] and (now - recentGD[dedupKey]) < GD_DEDUP_SEC then return end
    if not CanRememberDedup(recentGD, dedupKey, now) then return end

    if Overlord.General:ApplyRemoteDown(victimName, faction, pool, claimTs, killerName, killerClass, zoneId) then
        RememberDedup(recentGD, dedupKey, now)
    end
end

function Overlord.GeneralSync:OnReceiveGM(payload, sender, sourceChannel)
    if not payload or not sender or not Overlord.General then return end
    if IsSenderLocal(sender) then return end
    local onFront = Overlord.General.IsGeneralFrontContext
        and Overlord.General:IsGeneralFrontContext()
    if not onFront or Overlord.InstanceSuspended then return end

    local pool, claimTsStr, pulseTsStr, epochStr = strsplit(":", payload, 5)
    if not AcceptEpoch(epochStr) then return end
    pool = ResolveAcceptedPool(pool, sender, sourceChannel)
    if not pool then return end

    local claimTs = tonumber(claimTsStr) or 0
    local pulseTs = tonumber(pulseTsStr) or 0
    if not IsValidGeneralTimestamp(claimTs) or not IsValidGeneralTimestamp(pulseTs) then return end
    if not Overlord.General.ValidateDuelMusicPulse
        or not Overlord.General:ValidateDuelMusicPulse(sender, claimTs) then
        return
    end

    local now = GetTime()
    PruneDedupTables(now)
    local dedupKey = DedupSenderKey(sender) .. ":" .. tostring(claimTs) .. ":" .. tostring(pulseTs)
    if recentGM[dedupKey] and (now - recentGM[dedupKey]) < GM_DEDUP_SEC then return end
    if not CanRememberDedup(recentGM, dedupKey, now) then return end

    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.OnDuelMusicPulse then
        Overlord.GeneralNameplate:OnDuelMusicPulse(false)
    end
    RememberDedup(recentGM, dedupKey, now)
end
