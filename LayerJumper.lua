-- LayerJumper.lua: the layers of the players we hear, and joining one of them (Overlord Forever).
--
-- 2.5.0: back in a smaller form (the module of 1.5.0 was removed in 1.6.1). The list shows every
-- player whose layer we already know (Overlord.Shard: their presence and their "SH", no new
-- data), and a click on one of them, or on the layer named in a capture alert, asks that player
-- for a group invitation: out of combat the game moves us to the layer of the group's leader
-- within a few seconds, then Overlord leaves the group.
--   * Nothing happens until somebody clicks.
--   * Volunteers only: "Help others" is off by default. A volunteer invites automatically, with
--     no window on either side; anybody else answers "off" and nothing more.
--   * Invisible addon whispers on a prefix of our own, to one named player at a time: no
--     search, nothing broadcast, nothing through the relay (the 1.5.0 search went by the
--     channel, which carries nothing any more).
--   * The partner of a jump (a stranger for a few seconds) earns no group trust from the sync,
--     and the two-player group of a jump starts no catch-up (IsHopGroup, IsHopPartner).
--   * Nothing in an instance; a real group is never left nor disturbed.
--
-- Wire (prefix OverlordLJ, WHISPER only, fields split by ":"):
--   R:2:<req>:<our layer|->     "invite me" (to a player known on the wanted layer)
--   N:<req>:<reason>            refused: off, instance, combat, queue, full, busy, same

Overlord = Overlord or {}
local L = Overlord.L or {}
local LJ = Overlord.LayerJumper or {}
Overlord.LayerJumper = LJ

local securecall = securecall or function(fn, ...) return fn(...) end

LJ.PREFIX = "OverlordLJ"
LJ.PROTOCOL = "2"
LJ.INVITE_WAIT = 12            -- s waiting for the invitation of the player asked
LJ.JOIN_WAIT = 10              -- s between accepting and being in the group
LJ.VERIFY_TIMEOUT = 40         -- s out of combat to read the new layer
LJ.VERIFY_BLIND = 12           -- s in the group when our own layer cannot be read here
LJ.MAX_ATTEMPTS = 4            -- players asked per jump
LJ.REQUEST_GAP = 5             -- s between two jumps asked
LJ.HOP_GROUP_GRACE = 8         -- s after a jump while group events are still "ours"
LJ.HOP_PENDING = 15            -- s an invitation of ours counts as pending
LJ.GUEST_INVITE_TTL = 70       -- s: past it an invitation never accepted is over
LJ.HELPER_PER_SENDER_GAP = 20  -- helper: one answer per requester every 20 s
LJ.HELPER_INVITE_GAP = 15      -- helper: one invitation every 15 s
LJ.HELPER_INVITES_PER_HOUR = 20
LJ.HELPER_SAME_REQUESTER_GAP = 600 -- helper: one invitation per requester every 10 min
LJ.GUEST_KICK_AFTER = 120      -- net: a guest still in the group made for it
LJ.ROWS = 12                   -- rows of the list shown at once
LJ.LIST_MAX = 400              -- players listed at most

LJ.state = LJ.state or "idle"  -- idle | requesting | joining | verifying
LJ.guests = LJ.guests or {}
LJ.inviteLog = LJ.inviteLog or {}
LJ.repliedTo = LJ.repliedTo or {}
LJ.partners = LJ.partners or {}
LJ.invitedAt = LJ.invitedAt or {}

local function Now() return GetTime() end

local function Print(text)
    if not text or text == "" then return end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    elseif print then
        print("[Overlord] " .. text)
    end
end

local function T(key, fallback) return L[key] or fallback end
local GroupHasMember -- defined with the helper's side

-- "First Last-Realm" or "First Last" -> "first last" (comparison key).
local function NameKey(name)
    if type(name) ~= "string" then return nil end
    local base = name:match("^([^%-]+)") or name
    base = base:gsub("^%s+", ""):gsub("%s+$", "")
    if base == "" or #base > 60 or base:find("[%c:|]") then return nil end
    return base:lower()
end
LJ.NameKey = NameKey

local function SameName(a, b)
    if NameKey(a) == nil or NameKey(a) ~= NameKey(b) then return false end
    local ra, rb = a:match("%-(.+)$"), b:match("%-(.+)$")
    if not (ra and rb) then return true end
    return ra:gsub("[%s%-']", ""):lower() == rb:gsub("[%s%-']", ""):lower()
end
LJ.SameName = SameName

local function SafeBool(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, ...)
    return (ok and value) and true or false
end

function LJ:MyKey()
    if not self._myKey and UnitName then
        local ok, name = pcall(UnitName, "player")
        self._myKey = ok and NameKey(name) or nil
    end
    return self._myKey
end

-- ============================================================
-- Setting
-- ============================================================

-- "auto" = volunteer (invites automatically), "off" = never.
local HELP_MODES = { auto = true, off = true }

function LJ:GetHelpMode()
    local cfg = OverlordDB and OverlordDB.config
    local mode = cfg and cfg.layerHelpMode
    if HELP_MODES[mode] then return mode end
    return "off"
end

function LJ:SetHelpMode(mode)
    if not HELP_MODES[mode] then return end
    if OverlordDB then
        OverlordDB.config = OverlordDB.config or {}
        OverlordDB.config.layerHelpMode = mode
    end
    self:RefreshUI()
end

function LJ:HelpModeLabel(mode)
    mode = mode or self:GetHelpMode()
    if mode == "auto" then return T("LJ_HELP_MODE_AUTO", "on") end
    return T("LJ_HELP_MODE_OFF", "off")
end

-- ============================================================
-- Context: instance, combat, group, layers
-- ============================================================

function LJ:InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

function LJ:InCombat()
    return SafeBool(InCombatLockdown) or SafeBool(UnitAffectingCombat, "player")
end

function LJ:InBattlegroundQueue()
    if not GetMaxBattlefieldID or not GetBattlefieldStatus then return false end
    local ok, maxId = pcall(GetMaxBattlefieldID)
    for i = 1, (ok and tonumber(maxId) or 0) do
        local okS, status = pcall(GetBattlefieldStatus, i)
        if okS and (status == "queued" or status == "confirm") then return true end
    end
    return false
end

function LJ:IsGrouped()
    return SafeBool(IsInGroup) or SafeBool(IsInRaid)
end

function LJ:GroupSize()
    if not self:IsGrouped() then return 1 end
    local ok, n = pcall(GetNumGroupMembers)
    return ok and tonumber(n) or 1
end

-- A helper alone only: the group made for a jump holds two players.
function LJ:CanHostGuest()
    return not self:IsGrouped()
end

-- Our own layer as Overlord.Shard reads it (nil where it cannot be read: outside a front, an
-- outpost or a keep), and when it was read.
function LJ:MyLayer()
    local shard = Overlord.Shard
    if not shard or not shard.GetCurrentShardID then return nil, 0 end
    local ok, id = pcall(shard.GetCurrentShardID, shard)
    id = ok and tonumber(id) or nil
    return id, tonumber(shard.lastUpdateAt) or 0
end

-- A player of the other side, as far as we know: the game or Battle.net shows it there, or the
-- ranking holds it there (an enemy miner or capturer named in an alert is in neither's sight).
-- A wrong label only keeps us from asking that player; nothing is trusted from it.
function LJ:IsEnemy(name)
    local mine = Overlord.PlayerFaction
    local function other(faction)
        return (faction == "Alliance" or faction == "Horde") and faction ~= mine
    end
    local sync = Overlord.Sync
    if sync and sync.GetLivePlayerFaction then
        local ok, faction = pcall(sync.GetLivePlayerFaction, sync, name)
        if ok and (faction == "Alliance" or faction == "Horde") then return other(faction) end
    end
    local lb = Overlord.Leaderboard
    if lb and lb.GetPlayerInfo then
        local ok, info = pcall(lb.GetPlayerInfo, lb, name)
        if ok and type(info) == "table" and other(info.faction) then return true end
    end
    return false
end

function LJ:FormatLayer(layer)
    if layer == nil then return T("LJ_LAYER_UNKNOWN", "unknown") end
    return "#" .. tostring(layer)
end

-- The players whose layer we know now (Overlord.Shard's own table, newest first), ours left
-- out: { name, key, layer }. Read only, bounded.
function LJ:KnownPlayers()
    local shard = Overlord.Shard
    local out = {}
    if not shard or type(shard.knownShards) ~= "table" then return out end
    local now, me = Now(), self:MyKey()
    local node, walked = shard.peerTail, 0
    while node and walked < 600 and #out < self.LIST_MAX do
        walked = walked + 1
        local name = node.key
        local layer = name and tonumber(shard.knownShards[name])
        if layer and (tonumber(node.expiresAt) or 0) > now
            and (not shard.PartyInviteTargetIsUsable or shard:PartyInviteTargetIsUsable(name)) then
            local key = NameKey(name)
            if key and key ~= me then
                out[#out + 1] = { name = name, key = key, layer = layer, enemy = self:IsEnemy(name) or nil }
            end
        end
        node = node.prev
    end
    return out
end

-- ============================================================
-- Wire
-- ============================================================

function LJ:Whisper(target, msg)
    if self:InInstance() or type(target) ~= "string" or target == "" then return false end
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    -- (A player gone offline meanwhile: the game's "no player named" line for this whisper is
    -- hidden like the sync's own, SyncAux.)
    local sync = Overlord.Sync
    if sync and sync._RememberRecentAddonWhisper then pcall(sync._RememberRecentAddonWhisper, sync, target, Now()) end
    local ok = pcall(C_ChatInfo.SendAddonMessage, self.PREFIX, msg, "WHISPER", target)
    return ok
end

local function NewRequestId()
    local t = math.floor((time and time() or 0) % 65536)
    return string.format("%x%04x", t, math.random(0, 65535))
end

-- ============================================================
-- State
-- ============================================================

-- No active phase may stay stuck (buttons greyed for good).
local PHASE_LIMIT = { requesting = 60, joining = 15 }

function LJ:SetState(state, statusKey, ...)
    self.state = state
    self.phaseDeadline = PHASE_LIMIT[state] and (Now() + PHASE_LIMIT[state]) or nil
    if statusKey then
        self.statusText = string.format(T(statusKey, statusKey), ...)
    end
    self:UpdateTicker()
    self:RefreshUI()
end

function LJ:IsActive()
    return self.state == "requesting" or self.state == "joining" or self.state == "verifying"
end

-- A group formed or left for a jump (either side). The sync draws no catch-up from it.
-- Strict: a real group (more than two players, or without the partner expected) keeps its
-- ordinary life, even during a jump or a pending invitation.
function LJ:IsHopGroup()
    local now = Now()
    local grouped = self:IsGrouped()
    if grouped and self:GroupSize() > 2 then return false end
    if now < (self.hopGroupUntil or 0) then
        if not grouped then return true end
        local st = self.hopGroupKey and self:HopPairStatus(self.hopGroupKey)
        if st == "pair" or st == "pending" then return true end
    end
    local hop = self.hop
    if hop and hop.current and (self.state == "joining" or self.state == "verifying") then
        if not grouped then return true end
        local st = self:HopPairStatus(hop.current.key)
        return st == "pair" or st == "pending"
    end
    for key, guest in pairs(self.guests) do
        if guest.joined or now - guest.at < self.GUEST_INVITE_TTL then
            if not grouped then
                if guest.joined or now - guest.at < self.HOP_PENDING then return true end
            else
                local st = self:HopPairStatus(key)
                if st == "pair" then
                    guest.joined = true
                    self.hopPairSeen = true
                end
                if st == "pair" or st == "pending" then return true end
            end
        end
    end
    return false
end

-- The group seen from the jump: "none", "pair" (us + partner), "pending" (two players, the
-- partner's name not known yet), "crowded" (partner + others), "foreign" (a group without the
-- partner, joined by ANOTHER invitation received since the jump began), "hijacked" (without the
-- partner and without another invitation).
function LJ:HopPairStatus(key)
    if not self:IsGrouped() then return "none" end
    local size = self:GroupSize()
    if key and GroupHasMember(key) then return size <= 2 and "pair" or "crowded" end
    if size <= 2 then
        local ok, name = pcall(UnitName, "party1")
        if not ok or name == nil or name == "" or name == UNKNOWNOBJECT then return "pending" end
    end
    -- (An invitation received shortly before the jump may still be on screen and be accepted
    -- during it: the game keeps its window open about a minute.)
    if not self.hopPairSeen and (self.otherInviteAt or -1e9) >= (self.hopEpochAt or 0) - self.OTHER_INVITE_OPEN then
        return "foreign"
    end
    return "hijacked"
end

LJ.OTHER_INVITE_OPEN = 90
function LJ:MarkHopEpoch()
    self.hopEpochAt = Now()
    self.hopPairSeen = false
end

-- The partner of a jump is never a trusted group member for the sync (Sync.lua
-- SyncSenderIsInOurGroup, SyncOutpost OpSenderIsInOurGroup).
function LJ:IsHopPartner(name)
    local hop = self.hop
    if hop and (self.state == "joining" or self.state == "verifying") then
        return not hop.current or self:HopPairStatus(hop.current.key) ~= "foreign"
    end
    if next(self.guests) ~= nil then
        local now = Now()
        for key, guest in pairs(self.guests) do
            if (guest.joined or now - guest.at < self.HOP_PENDING)
                and self:HopPairStatus(key) ~= "foreign" then
                return true
            end
        end
    end
    if Now() < (self.hopGroupUntil or 0) and self:IsGrouped()
        and self:HopPairStatus(self.hopGroupKey) ~= "foreign" then
        return true
    end
    if next(self.partners) == nil then return false end
    local now = Now()
    for k, untilAt in pairs(self.partners) do
        if now > untilAt then self.partners[k] = nil end
    end
    local key = NameKey(name)
    local untilAt = key and self.partners[key]
    return untilAt ~= nil and now <= untilAt
end

function LJ:MarkPartner(key, seconds)
    if not key then return end
    local now = Now()
    for k, untilAt in pairs(self.partners) do
        if now > untilAt then self.partners[k] = nil end
    end
    self.partners[key] = now + seconds
end

function LJ:MarkHopGroupEnding(partnerKey)
    self.hopGroupUntil = Now() + self.HOP_GROUP_GRACE
    if partnerKey then self.hopGroupKey = partnerKey end
    if OverlordDB then OverlordDB.layerJumperHop = nil end
end

-- A /reload in the middle of a jump wipes the state: just enough is kept to distrust the
-- partner and to leave its group on the way back (3 min at most).
function LJ:RememberHop(key)
    if OverlordDB and key and time then
        OverlordDB.layerJumperHop = { key = key, at = time() }
    end
end

function LJ:RestoreHopAfterReload()
    local rec = OverlordDB and OverlordDB.layerJumperHop
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    if type(rec) ~= "table" or type(rec.key) ~= "string" or not time then return end
    local left = 180 - (time() - (tonumber(rec.at) or 0))
    if left <= 0 or left > 180 then return end
    self:MarkPartner(rec.key, left)
    C_Timer.After(5, function()
        -- Only if the partner is really there: a group of friends stays as it is.
        if Overlord.InstanceSuspended or LJ:InInstance() then return end
        if LJ:IsGrouped() and LJ:GroupSize() <= 2 and GroupHasMember(rec.key) then LJ:LeaveHopGroup(rec.key) end
    end)
end

-- ============================================================
-- Requester
-- ============================================================

function LJ:CheckRequesterBlocked()
    if self:InInstance() then return T("LJ_ERR_INSTANCE", "Not available in instances and battlegrounds.") end
    if self:InBattlegroundQueue() then
        return T("LJ_ERR_QUEUE", "Not available while queued for a battleground.")
    end
    if self:IsGrouped() then return T("LJ_ERR_GROUPED", "Leave your group first: the helper must invite you.") end
    return nil
end

-- The players to ask for a layer: the one named first, then the others known on that layer.
-- Never a player of the other side (an addon whisper does not cross): the layer of an enemy
-- capturer is joined through a player of ours standing on it.
function LJ:CandidatesFor(layer, first)
    local list, seen = {}, {}
    local firstKey = NameKey(first)
    if firstKey and firstKey ~= self:MyKey() and not self:IsEnemy(first) then
        list[1] = { name = first, key = firstKey, layer = layer }
        seen[firstKey] = true
    end
    if layer ~= nil then
        for _, row in ipairs(self:KnownPlayers()) do
            if row.layer == layer and not row.enemy and not seen[row.key] and #list < self.MAX_ATTEMPTS then
                seen[row.key] = true
                list[#list + 1] = row
            end
        end
    end
    return list
end

-- Asks to join the layer of `name` (and, failing that player, of the others known on `layer`).
-- name or layer may be nil, not both. say: tell the first step in the chat too (a click in the
-- chat, the window may be closed).
function LJ:Join(name, layer, say)
    self:Initialize()
    layer = tonumber(layer)
    if self:IsActive() then return false end
    local blocked = self:CheckRequesterBlocked()
    local myLayer = self:MyLayer()
    if not blocked and layer ~= nil and myLayer ~= nil and layer == myLayer then
        blocked = T("LJ_ERR_SAME_LAYER", "You are already on this layer.")
    end
    if not blocked and Now() - (self.lastJoinAt or -100) < self.REQUEST_GAP then return false end
    if blocked then
        self.statusText = blocked
        self:RefreshUI()
        Print(blocked)
        return false
    end
    if layer == nil and name then
        local shard = Overlord.Shard
        local _, known = nil, nil
        if shard and shard.ResolveKnownShardPlayer then
            local ok, _, sid = pcall(shard.ResolveKnownShardPlayer, shard, name, true)
            known = ok and tonumber(sid) or nil
        end
        layer = known
    end
    local candidates = self:CandidatesFor(layer, name)
    if #candidates == 0 then
        self.statusText = T("LJ_STATUS_FAILED", "No helper invited you. Try again in a moment.")
        self:RefreshUI()
        Print(self.statusText)
        return false
    end
    self.lastJoinAt = Now()
    self:MarkHopEpoch()
    self.hop = { target = layer, originLayer = myLayer, candidates = candidates, index = 0, reqId = NewRequestId() }
    local started = self:NextCandidate()
    if started and say and not self:IsShown() then Print(self.statusText) end
    return started
end

-- An invitation accepted too late (or by hand) from a helper given up: left as soon as joined.
function LJ:ArmLateJoinLeave(cand)
    if not cand or not cand.key then return end
    if self.partners[cand.key] then self:MarkPartner(cand.key, self.HOP_GROUP_GRACE + 5) end
    self.lateLeave = self.lateLeave or {}
    self.lateLeave[cand.key] = { untilAt = Now() + 15, name = cand.name }
end

function LJ:NextCandidate(reason)
    local hop = self.hop
    if not hop then return false end
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    hop.index = hop.index + 1
    local cand = hop.candidates[hop.index]
    if not cand or hop.index > self.MAX_ATTEMPTS then
        self.hop = nil
        if hop.acceptedAt and hop.current then self:ArmLateJoinLeave(hop.current) end
        -- (The only player asked does not help: said so, by name.)
        if reason == "off" and hop.index == 2 and hop.current then
            self:SetState("idle", "LJ_DECLINED_OFF", hop.current.name)
        else
            self:SetState("idle", "LJ_STATUS_FAILED")
        end
        Print(self.statusText)
        return false
    end
    hop.current = cand
    hop.acceptedAt = nil
    local index = hop.index
    C_Timer.After(self.INVITE_WAIT, function()
        if LJ.hop == hop and hop.index == index and LJ.state == "requesting" then
            cand.failed = true
            LJ:ArmLateJoinLeave(cand)
            LJ:NextCandidate()
        end
    end)
    self:SetState("requesting", "LJ_STATUS_REQUESTING", cand.name)
    self:Whisper(cand.name, "R:" .. self.PROTOCOL .. ":" .. hop.reqId .. ":" .. tostring(hop.originLayer or "-"))
    return true
end

function LJ:OnDecline(sender, reqId, reason)
    local hop = self.hop
    if not hop or hop.reqId ~= reqId or self.state ~= "requesting" then return end
    if not hop.current or NameKey(sender) ~= hop.current.key then return end
    hop.current.failed = true
    self:NextCandidate(reason)
end

local function AcceptHopInvite()
    -- Closing the window without accepting would decline the invitation.
    if not AcceptGroup then return end
    AcceptGroup()
    local dialog = StaticPopup_FindVisible and StaticPopup_FindVisible("PARTY_INVITE")
    if dialog then dialog.inviteAccepted = 1 end
    if StaticPopup_Hide then StaticPopup_Hide("PARTY_INVITE") end
end

-- Only the invitation of the player we asked is accepted by itself.
function LJ:OnPartyInvite(inviter)
    local hop = self.hop
    if not hop or self.state ~= "requesting" or not hop.current then return false end
    if type(inviter) ~= "string" or not SameName(inviter, hop.current.name) then return false end
    pcall(AcceptHopInvite)
    hop.acceptedAt = Now()
    local cand = hop.current
    self:MarkHopEpoch()
    self:RememberHop(cand.key)
    self:MarkPartner(cand.key, self.JOIN_WAIT + 120 + self.HOP_GROUP_GRACE)
    C_Timer.After(self.JOIN_WAIT, function()
        if LJ.hop == hop and hop.current == cand and LJ.state == "joining" then
            if LJ:IsGrouped() then return LJ:OnGroupJoined() end
            cand.failed = true
            LJ:ArmLateJoinLeave(cand)
            LJ:NextCandidate()
        end
    end)
    self:SetState("joining", "LJ_STATUS_JOINING", hop.current.name)
    return true
end

function LJ:OnGroupJoined()
    local hop = self.hop
    if not hop or self.state ~= "joining" or not hop.current then return end
    local pair = self:HopPairStatus(hop.current.key)
    if pair == "none" then return end
    if pair == "foreign" then
        -- Another group, accepted by hand: kept, and the jump is given up.
        self.hop = nil
        if OverlordDB then OverlordDB.layerJumperHop = nil end
        self:ArmLateJoinLeave(hop.current)
        self:SetState("idle", "LJ_STATUS_CANCELLED")
        return
    end
    if pair == "crowded" or pair == "hijacked" then
        self.state = "verifying"
        return self:FinishHop(false, "LJ_STATUS_CROWDED")
    end
    if pair == "pair" then self.hopPairSeen = true end
    hop.joinedAt = Now()
    -- (Where our own layer cannot be read, nothing can be confirmed: a short stay.)
    local readable = Overlord.IsShardHelperActive and SafeBool(Overlord.IsShardHelperActive, Overlord)
    hop.verifyLeft = readable and self.VERIFY_TIMEOUT or self.VERIFY_BLIND
    hop.hardDeadline = hop.joinedAt + 120
    self.state = "verifying"
    self.phaseDeadline = nil
    self:UpdateTicker()
    self:UpdateVerifyStatus()
    self:CheckVerify()
end

function LJ:UpdateVerifyStatus()
    local hop = self.hop
    if not hop then return end
    local left = math.max(0, math.ceil(hop.verifyLeft or 0))
    if self:InCombat() then
        self.statusText = string.format(T("LJ_STATUS_VERIFY_COMBAT", "In combat: the switch waits (%ds)."), left)
    else
        self.statusText = string.format(T("LJ_STATUS_VERIFYING", "Switching layer... (%ds)"), left)
    end
    self:RefreshUI()
end

-- Proof: our layer, read again after we entered the group, is the one asked for (or, without
-- one, another than the layer we came from).
function LJ:CheckVerify()
    local hop = self.hop
    if not hop or self.state ~= "verifying" then return false end
    local layer, readAt = self:MyLayer()
    if layer == nil or readAt <= (hop.joinedAt or 0) then return false end
    local done
    if hop.target ~= nil then
        done = layer == hop.target
    elseif hop.originLayer ~= nil then
        done = layer ~= hop.originLayer
    end
    if not done then return false end
    self:FinishHop(true)
    return true
end

-- Never leaves a group that is not the one of the jump (key = the partner expected).
function LJ:LeaveHopGroup(key)
    if Overlord.InstanceSuspended or self:InInstance() then return end
    if not self:IsGrouped() then return end
    if key and self:HopPairStatus(key) == "foreign" then return end
    self:MarkHopGroupEnding(key)
    if C_PartyInfo and C_PartyInfo.LeaveParty then
        pcall(C_PartyInfo.LeaveParty)
    elseif LeaveParty then
        pcall(LeaveParty)
    end
end

function LJ:FinishHop(confirmed, failKey)
    local hop = self.hop
    self.hop = nil
    if not hop then return end
    local partnerKey = hop.current and hop.current.key
    self:MarkHopGroupEnding(partnerKey)
    if partnerKey then self:MarkPartner(partnerKey, self.HOP_GROUP_GRACE + 5) end
    if confirmed then
        self:SetState("idle", "LJ_STATUS_SUCCESS", self:FormatLayer((self:MyLayer())))
    else
        self:SetState("idle", failKey or "LJ_STATUS_UNCONFIRMED")
    end
    Print(self.statusText)
    -- One second of margin: the server ends the transfer before we leave the group.
    C_Timer.After(1, function() LJ:LeaveHopGroup(partnerKey) end)
end

function LJ:Cancel()
    local hop = self.hop
    if hop and hop.current and self.state == "requesting" then
        hop.current.failed = true
        self:ArmLateJoinLeave(hop.current)
    end
    local wasInHopGroup = hop and (self.state == "joining" or self.state == "verifying")
    if hop and hop.acceptedAt and hop.current then self:ArmLateJoinLeave(hop.current) end
    self.hop = nil
    if wasInHopGroup then self:MarkHopGroupEnding(hop.current and hop.current.key) end
    if hop and hop.acceptedAt and hop.current then
        self:MarkPartner(hop.current.key, self.HOP_GROUP_GRACE + 5)
    end
    self:SetState("idle", "LJ_STATUS_CANCELLED")
    if wasInHopGroup then self:LeaveHopGroup(hop.current and hop.current.key) end
end

-- A 1 s beat only during an operation (countdown and proof).
function LJ:Tick()
    if self.phaseDeadline and Now() > self.phaseDeadline then
        self:Cancel()
        return
    end
    if self.state == "verifying" then
        local hop = self.hop
        if not hop then return self:SetState("idle") end
        local shard = Overlord.Shard
        if shard and shard.Update and not self:InCombat() then pcall(shard.Update, shard) end
        if self:CheckVerify() then return end
        if self.state ~= "verifying" then return end
        if not self:InCombat() then hop.verifyLeft = (hop.verifyLeft or 0) - 1 end
        if hop.verifyLeft <= 0 or Now() > (hop.hardDeadline or math.huge) then
            self:FinishHop(false)
            return
        end
        self:UpdateVerifyStatus()
    elseif self:IsActive() then
        self:RefreshUI()
    end
end

function LJ:UpdateTicker()
    local active = self:IsActive()
    if active and not self.ticker and C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(1, function() LJ:Tick() end)
    elseif not active and self.ticker then
        if self.ticker.Cancel then self.ticker:Cancel() end
        self.ticker = nil
    end
end

-- ============================================================
-- Helper's side
-- ============================================================

local function PruneByAge(map, field, ttl, cap)
    local now, count, oldestId, oldestAt = Now(), 0, nil, nil
    for id, rec in pairs(map) do
        local at = field and rec[field] or rec
        if now - at > ttl then
            map[id] = nil
        else
            count = count + 1
            if not oldestAt or at < oldestAt then oldestId, oldestAt = id, at end
        end
    end
    if count > cap and oldestId then map[oldestId] = nil end
end

-- Why this client cannot help now (nil = available).
function LJ:HelperUnavailableReason()
    if self:InInstance() then return "instance" end
    if self:InCombat() then return "combat" end
    if self:InBattlegroundQueue() then return "queue" end
    if not self:CanHostGuest() then return "full" end
    if self.hop then return "busy" end
    local now = Now()
    for _, guest in pairs(self.guests) do
        if not guest.joined and now - guest.at < self.GUEST_INVITE_TTL then return "busy" end
    end
    return nil
end

function LJ:InviteBudgetOk()
    local now, recent = Now(), 0
    local log = self.inviteLog
    for i = #log, 1, -1 do
        if now - log[i] > 3600 then table.remove(log, i) else recent = recent + 1 end
    end
    if recent >= self.HELPER_INVITES_PER_HOUR then return false end
    return now - (log[#log] or -1000) >= self.HELPER_INVITE_GAP
end

-- "R": a player asks us for an invitation. Answered once per requester every
-- HELPER_PER_SENDER_GAP, whatever the answer; nothing at all past that (no reply to a flood).
function LJ:OnRequest(sender, proto, reqId, theirLayerText)
    if proto ~= self.PROTOCOL or type(reqId) ~= "string" or #reqId > 12 or reqId:find("[^%w]") then return end
    local key = NameKey(sender)
    if not key or key == self:MyKey() then return end
    local now = Now()
    if now - (self.repliedTo[key] or -100) < self.HELPER_PER_SENDER_GAP then return end
    self.repliedTo[key] = now
    PruneByAge(self.repliedTo, nil, self.HELPER_PER_SENDER_GAP, 64)
    local reason = self:GetHelpMode() ~= "auto" and "off" or self:HelperUnavailableReason()
    if not reason and not self:InviteBudgetOk() then reason = "busy" end
    if not reason and now - (self.invitedAt[key] or -1e9) < self.HELPER_SAME_REQUESTER_GAP then reason = "busy" end
    -- Already on our layer: joining us would change nothing.
    local mine = self:MyLayer()
    if not reason and mine ~= nil and tonumber(theirLayerText) == mine then reason = "same" end
    if reason then
        self:Whisper(sender, "N:" .. reqId .. ":" .. reason)
        return
    end
    self:InviteGuest(sender, reqId)
end

function LJ:InviteGuest(name, reqId)
    if self:HelperUnavailableReason() then
        self:Whisper(name, "N:" .. reqId .. ":busy")
        return false
    end
    local key = NameKey(name)
    self.inviteLog[#self.inviteLog + 1] = Now()
    PruneByAge(self.invitedAt, nil, self.HELPER_SAME_REQUESTER_GAP, 64)
    self.invitedAt[key] = Now()
    -- Recorded BEFORE the invitation: the two-player group about to form is "ours".
    self.guests[key] = { name = name, at = Now() }
    self:MarkHopEpoch()
    self:RememberHop(key)
    self:MarkPartner(key, self.GUEST_KICK_AFTER + self.HOP_GROUP_GRACE)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        securecall(C_PartyInfo.InviteUnit, name)
    elseif InviteUnit then
        securecall(InviteUnit, name)
    end
    local invitedAt = self.guests[key].at
    C_Timer.After(self.GUEST_KICK_AFTER, function() LJ:ReleaseGuest(key, invitedAt) end)
    return true
end

local function MemberKey(unit) return NameKey((UnitName(unit))) end

GroupHasMember = function(key)
    local n = LJ:GroupSize()
    local prefix = SafeBool(IsInRaid) and "raid" or "party"
    local last = prefix == "raid" and n or math.max(0, n - 1)
    for i = 1, last do
        local ok, memberKey = pcall(MemberKey, prefix .. i)
        if ok and memberKey == key then return true end
    end
    return false
end

-- Net: the guest's client leaves by itself; if it has not after 2 min in the two-player
-- group made for it, it is released.
function LJ:ReleaseGuest(key, invitedAt)
    local guest = self.guests[key]
    if not guest or (invitedAt and guest.at ~= invitedAt) then return end
    if Overlord.InstanceSuspended or self:InInstance() then return end
    self.guests[key] = nil
    self:MarkHopGroupEnding(key)
    self:MarkPartner(key, self.HOP_GROUP_GRACE)
    if not guest.joined then
        self.invitedAt[key] = nil
        return
    end
    local st = self:HopPairStatus(key)
    if st == "crowded" or st == "hijacked" then return self:LeaveHopGroup(key) end
    if self:GroupSize() ~= 2 or not SafeBool(UnitIsGroupLeader, "player") or not GroupHasMember(key) then
        return
    end
    if C_PartyInfo and C_PartyInfo.UninviteUnit then
        securecall(C_PartyInfo.UninviteUnit, guest.name)
    elseif UninviteUnit then
        securecall(UninviteUnit, guest.name)
    end
    Print(string.format(T("LJ_GUEST_REMOVED", "%s removed from the group (layer change over)."), guest.name))
end

-- Entering a group outside a jump: if it is the group of a helper we gave up on (its
-- invitation came too late), we leave it. True when such a group has just been left.
function LJ:CheckLateJoin()
    local late = self.lateLeave
    if not late or self.state == "joining" then return false end
    local now = Now()
    for key, entry in pairs(late) do
        if now > entry.untilAt then late[key] = nil end
    end
    if next(late) == nil then
        self.lateLeave = nil
        return false
    end
    if not self:IsGrouped() or self:GroupSize() > 5 then return false end
    for key, entry in pairs(late) do
        if GroupHasMember(key) then
            late[key] = nil
            self:LeaveHopGroup(key)
            Print(string.format(T("LJ_LATE_LEAVE", "Left %s's group: that layer jump was cancelled."),
                (entry.name or key):match("^([^%-]+)") or key))
            return true
        end
    end
    return false
end

-- ============================================================
-- Reception
-- ============================================================

function LJ:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX or type(text) ~= "string" or #text > 80 then return end
    if type(sender) ~= "string" or Overlord.InstanceSuspended then return end
    if channel ~= "WHISPER" then return end
    local kind, a, b, c = strsplit(":", text)
    if kind == "R" then
        self:OnRequest(sender, a, b, c)
    elseif kind == "N" then
        self:OnDecline(sender, a, b)
    end
end

-- An instance: like the rest of Overlord, this module stops. The jump under way is given up
-- WITHOUT touching the group (a dungeon's or a battleground's group is never left nor read).
function LJ:OnInstanceSuspend()
    if self.frame and self.frame:IsShown() then self.frame:Hide() end
    self.hop, self.lateLeave = nil, nil
    for key in pairs(self.guests) do self.guests[key] = nil end
    if OverlordDB then OverlordDB.layerJumperHop = nil end
    if self.state ~= "idle" then
        self:SetState("idle", "LJ_STATUS_CANCELLED")
    else
        self:UpdateTicker()
    end
end

function LJ:OnEvent(event, ...)
    -- (Every addon's messages come by here: the prefix first.)
    if event == "CHAT_MSG_ADDON" and (...) ~= self.PREFIX then return end
    if self:InInstance() then return end
    if event == "CHAT_MSG_ADDON" then
        self:OnAddonMessage(...)
    elseif event == "PARTY_INVITE_REQUEST" then
        if not self:OnPartyInvite((...)) then self.otherInviteAt = Now() end
    elseif event == "GROUP_JOINED" or event == "GROUP_ROSTER_UPDATE" then
        if self.state == "joining" then
            self:OnGroupJoined()
            return
        end
        local verifyStatus = self.state == "verifying" and self.hop and self.hop.current
            and self:HopPairStatus(self.hop.current.key)
        if verifyStatus == "pair" then self.hopPairSeen = true end
        if verifyStatus == "crowded" or verifyStatus == "hijacked" then
            -- A third player entered the group of the jump: we leave it.
            return self:FinishHop(false, "LJ_STATUS_CROWDED")
        end
        if self.state == "requesting" and self:IsGrouped() and self.hop and self.hop.current then
            if self.lateLeave and self:CheckLateJoin() then return end
            -- Another group joined during the request: the helper can no longer invite us.
            local st = self:HopPairStatus(self.hop.current.key)
            if st == "foreign" or st == "crowded" or st == "hijacked" then return self:Cancel() end
        end
        if next(self.guests) ~= nil and self:IsGrouped() and self:GroupSize() <= 2 then
            local now = Now()
            for key, guest in pairs(self.guests) do
                if not guest.joined and now - guest.at < self.GUEST_INVITE_TTL and GroupHasMember(key) then
                    guest.joined = true
                    self.hopPairSeen = true
                end
            end
        end
        if next(self.guests) ~= nil and self:IsGrouped() then
            -- Helper: the guest brought other players in, or was replaced after it entered.
            for key, guest in pairs(self.guests) do
                local st = self:HopPairStatus(key)
                if guest.joined and (st == "crowded" or st == "hijacked") then
                    for k in pairs(self.guests) do self.guests[k] = nil end
                    self:MarkPartner(key, self.HOP_GROUP_GRACE)
                    return self:LeaveHopGroup(key)
                end
            end
        end
        if self.lateLeave then self:CheckLateJoin() end
    elseif event == "GROUP_LEFT" then
        self.hopPairSeen = false
        if next(self.guests) ~= nil then
            for key in pairs(self.guests) do
                self:MarkHopGroupEnding(key)
                self:MarkPartner(key, self.HOP_GROUP_GRACE)
                self.guests[key] = nil
            end
        end
        if self.state == "joining" and self.hop and self.hop.current then
            self.hop.current.failed = true
            self:ArmLateJoinLeave(self.hop.current)
            self:NextCandidate()
        elseif self.state == "verifying" then
            -- Removed from the group (the helper's net, a disconnection) before the proof.
            self:FinishHop(false)
        end
        self:RefreshUI()
    end
end

-- ============================================================
-- The layer named in a chat alert
-- ============================================================

-- An "addon" link is the game's own kind for an addon's link: its click is handed to the addon
-- through EventRegistry ("SetItemRef"), no hook on the chat frames. Where the game has no
-- EventRegistry the alerts keep their plain text.
function LJ:CanLink()
    return type(EventRegistry) == "table" and type(EventRegistry.RegisterCallback) == "function"
end

-- text: the layer tag of an alert (" layer #1234", ", layer #1234"): the same text, its layer
-- part made a link that asks `name` for an invitation. nil: no link. name may be nil (an alert
-- about the other faction, or without a player: a mine, a rampage): the link then asks the
-- players of ours known on that layer.
function LJ:ChatLink(name, layer, text)
    if not self:CanLink() then return nil end
    layer = tonumber(layer)
    if not layer or type(text) ~= "string" then return nil end
    if name == nil then
        name = ""
    elseif not NameKey(name) or name:find("[|:%[%]]") then
        return nil
    end
    self:Initialize()
    if not self.linkReady then return nil end
    local lead, body = text:match("^([,%s]*)(.-)$")
    -- (The comma of the Chinese tag is three bytes wide: left out of the link like the others.)
    local wide = "，"
    if body and body:sub(1, #wide) == wide then
        local rest = body:sub(#wide + 1)
        local space = rest:match("^%s*") or ""
        lead, body = lead .. wide .. space, rest:sub(#space + 1)
    end
    if not body or body == "" or body:find("[|%[%]]") then return nil end
    return lead .. "|cff71d5ff|Haddon:Overlord:layer:" .. name .. ":" .. string.format("%d", layer)
        .. "|h[" .. body .. "]|h|r"
end

function LJ:OnChatLink(link, button)
    if type(link) ~= "string" then return end
    local kind, addon, what, name, layer = strsplit(":", link)
    if kind ~= "addon" or addon ~= "Overlord" or what ~= "layer" then return end
    if button and button ~= "LeftButton" then return end
    if not tonumber(layer) then return end
    if name == "" then name = nil end
    if name ~= nil and not NameKey(name) then return end
    self:Join(name, tonumber(layer), true)
end

function LJ:Initialize()
    if self.initialized then return end
    self.initialized = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    end
    if self:CanLink() then
        self.linkReady = pcall(EventRegistry.RegisterCallback, EventRegistry, "SetItemRef",
            function(_, link, _, button) pcall(LJ.OnChatLink, LJ, link, button) end, LJ)
    end
    self:RestoreHopAfterReload()
    if not CreateFrame then return end
    local f = CreateFrame("Frame")
    self.eventFrame = f
    for _, event in ipairs({ "CHAT_MSG_ADDON", "PARTY_INVITE_REQUEST", "GROUP_JOINED",
        "GROUP_ROSTER_UPDATE", "GROUP_LEFT" }) do
        pcall(f.RegisterEvent, f, event)
    end
    f:SetScript("OnEvent", function(_, event, ...) LJ:OnEvent(event, ...) end)
end

-- ============================================================
-- Window: the layers of the players we hear
-- ============================================================

local GOLD = { 1, 0.82, 0 }
local FRAME_W = 380
local ROW_H = 20

local function SetButtonEnabled(btn, enabled)
    if not btn then return end
    if enabled then btn:Enable() else btn:Disable() end
    btn:SetAlpha(enabled and 1 or 0.45)
end

local function MakeButton(parent, w, h, text, onClick)
    local UI = Overlord.UI
    if UI and UI.CreateWC3Button then
        return UI.CreateWC3Button(parent, w, h, text, onClick)
    end
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(w, h)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function SetButtonText(btn, text)
    if btn.label then btn.label:SetText(text) elseif btn.SetText then btn:SetText(text) end
end

-- The rows: our layer's players last, the others by layer then by name (the same order at
-- every repaint: a list that reshuffles under the pointer cannot be clicked).
function LJ:BuildRows()
    local myLayer = self:MyLayer()
    local rows = self:KnownPlayers()
    for _, row in ipairs(rows) do row.here = myLayer ~= nil and row.layer == myLayer end
    table.sort(rows, function(a, b)
        if a.here ~= b.here then return b.here end
        if a.layer ~= b.layer then return a.layer < b.layer end
        return a.key < b.key
    end)
    return rows, myLayer
end

function LJ:CreateWindow()
    if self.frame then return self.frame end
    local UI = Overlord.UI or {}
    local frameH = 150 + self.ROWS * ROW_H
    local f = CreateFrame("Frame", "OverlordLayerJumperFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, frameH)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    if UI.ApplyWoodDialogBackdrop then UI.ApplyWoodDialogBackdrop(f) end
    if UI.AttachOpenFade then UI.AttachOpenFade(f) end
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    -- (The panel's Layers button lights while this window is open, however it was closed.)
    local function gridButton()
        local ui = Overlord.UI
        if ui and ui.ScheduleActionGridActiveRefresh then ui:ScheduleActionGridActiveRefresh() end
    end
    f:SetScript("OnShow", gridButton)
    f:SetScript("OnHide", gridButton)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "OverlordLayerJumperFrame") end

    local close = UI.CreateWC3CloseButton and UI.CreateWC3CloseButton(f, function() LJ:Hide() end)
        or CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
    icon:SetTexture("Interface\\Icons\\Spell_Arcane_PortalShattrath")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(T("LJ_TITLE", "Layers"))
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    local mine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mine:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -50)
    mine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -50)
    mine:SetJustifyH("LEFT")
    mine:SetWordWrap(false)
    f.mineText = mine

    local listH = self.ROWS * ROW_H + 10
    local list = UI.CreateWC3SubPanel and UI.CreateWC3SubPanel(f, FRAME_W - 36, listH) or CreateFrame("Frame", nil, f)
    list:SetSize(FRAME_W - 36, listH)
    list:SetPoint("TOP", f, "TOP", 0, -70)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        LJ.scroll = math.max(0, (LJ.scroll or 0) - delta * 3)
        LJ:RefreshUI()
    end)
    f.list = list
    f.rows = {}
    for i = 1, self.ROWS do
        local row = CreateFrame("Frame", nil, list)
        row:SetSize(FRAME_W - 52, ROW_H - 2)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -5 - (i - 1) * ROW_H)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", row, "LEFT", 2, 0)
        label:SetWidth(170)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        local info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        info:SetPoint("LEFT", row, "LEFT", 178, 0)
        info:SetJustifyH("LEFT")
        local join = MakeButton(row, 84, ROW_H - 2, T("LJ_JOIN", "Join"), function(btn)
            if btn._name then LJ:Join(btn._name, btn._layer) end
        end)
        join:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.label, row.info, row.join = label, info, join
        row:Hide()
        f.rows[i] = row
    end
    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -10)
    empty:SetPoint("TOPRIGHT", list, "TOPRIGHT", -10, -10)
    empty:SetJustifyH("LEFT")
    empty:SetText(T("LJ_LIST_EMPTY", "No player's layer is known yet. They show up as Overlord players around you are heard."))
    f.emptyText = empty

    local count = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("BOTTOMRIGHT", list, "TOPRIGHT", -4, 3)
    f.countText = count

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 2, -6)
    status:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", -2, -6)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("TOP")
    status:SetHeight(26)
    f.statusLine = status

    local btnW = math.floor((FRAME_W - 36 - 6) / 2)
    local help = MakeButton(f, btnW, 22, "", function()
        LJ:SetHelpMode(LJ:GetHelpMode() == "auto" and "off" or "auto")
    end)
    help:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -36)
    help:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText(T("LJ_HELP_MODE_TOOLTIP", ""), 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    help:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.helpBtn = help
    local cancel = MakeButton(f, btnW, 22, T("LJ_CANCEL", "Cancel"), function() LJ:Cancel() end)
    cancel:SetPoint("LEFT", help, "RIGHT", 6, 0)
    f.cancelBtn = cancel

    self.frame = f
    return f
end

-- A display must never break the logic (state, timers) that calls it.
function LJ:RefreshUI()
    local f = self.frame
    if not f or not f:IsShown() then return end
    local ok, err = pcall(self.PaintWindow, self, f)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

local function FactionColor(name)
    local sync = Overlord.Sync
    local ok, faction = pcall(function()
        return sync and sync.GetLivePlayerFaction and sync:GetLivePlayerFaction(name) or nil
    end)
    faction = ok and faction or nil
    if faction == "Horde" then return "|cffff6644" end
    if faction == "Alliance" then return "|cff6db3f2" end
    return "|cffb8b8b8"
end

function LJ:PaintWindow(f)
    local rows, myLayer = self:BuildRows()
    f.mineText:SetText(string.format(T("LJ_YOUR_LAYER", "Your layer: %s"), self:FormatLayer(myLayer)))
    local maxScroll = math.max(0, #rows - self.ROWS)
    self.scroll = math.min(math.max(0, self.scroll or 0), maxScroll)
    local active = self:IsActive()
    for i = 1, self.ROWS do
        local row, data = f.rows[i], rows[i + self.scroll]
        if data then
            row.label:SetText(FactionColor(data.name) .. data.name .. "|r")
            row.info:SetText(data.here and T("LJ_HERE", "you are here") or self:FormatLayer(data.layer))
            row.join._name, row.join._layer = data.name, data.layer
            row.join:SetShown(not data.here)
            SetButtonEnabled(row.join, not active)
            row:Show()
        else
            row:Hide()
        end
    end
    f.emptyText:SetShown(#rows == 0)
    if #rows > self.ROWS then
        f.countText:SetText(string.format("%d-%d / %d", self.scroll + 1, math.min(#rows, self.scroll + self.ROWS), #rows))
    else
        f.countText:SetText(#rows > 0 and tostring(#rows) or "")
    end
    f.statusLine:SetText(self.statusText or T("LJ_EXPLAIN", ""))
    SetButtonEnabled(f.cancelBtn, active)
    SetButtonText(f.helpBtn, string.format(T("LJ_HELP_MODE", "Help others: %s"), self:HelpModeLabel()))
end

function LJ:Show()
    self:Initialize()
    if not CreateFrame then return end
    local f = self:CreateWindow()
    if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
        f:SetScale(Overlord.UI:GetEffectiveUiScale())
    end
    if not self:IsActive() then self.statusText = nil end
    f:Show()
    if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
    self:RefreshUI()
    -- (The list moves as presences come: repainted every 5 s while shown, no OnUpdate.)
    if not self.listTicker and C_Timer and C_Timer.NewTicker then
        self.listTicker = C_Timer.NewTicker(5, function()
            if LJ.frame and LJ.frame:IsShown() then
                LJ:RefreshUI()
            elseif LJ.listTicker then
                LJ.listTicker:Cancel()
                LJ.listTicker = nil
            end
        end)
    end
end

function LJ:Hide()
    if self.frame and self.frame:IsShown() then
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        self.frame:Hide()
    end
end

function LJ:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
end

function LJ:IsShown()
    return self.frame ~= nil and self.frame:IsShown() == true
end

-- Commands: /ov layer [help on|off]
function LJ:HandleCommand(args)
    local sub = args and args[2] and args[2]:lower() or nil
    if sub == "help" or sub == "aide" then
        local arg = args[3] and args[3]:lower()
        local mode = (arg == "on" or arg == "auto") and "auto" or (arg == "off" and "off") or nil
        if mode then
            self:SetHelpMode(mode)
        elseif arg then
            Print(T("LJ_USAGE", "/ov layer [help on|off]"))
        end
        Print(string.format(T("LJ_HELP_MODE", "Help others: %s"), self:HelpModeLabel()))
        return
    end
    self:Toggle()
end

if CreateFrame then
    local boot = CreateFrame("Frame")
    boot:RegisterEvent("PLAYER_LOGIN")
    boot:SetScript("OnEvent", function(frame)
        frame:UnregisterAllEvents()
        LJ:Initialize()
    end)
end
