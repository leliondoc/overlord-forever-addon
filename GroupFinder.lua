-- PvP group finder (logic and protocol; the window is GroupFinderUI.lua).
--
-- A leader publishes one small listing on the faction addon channel under a dedicated
-- prefix: objective, place id, size, head count, minimum level. No free text travels:
-- every client words the ids in its own language. A player signs up with one addon
-- whisper to the leader, whose client invites through the game's own invitation.
--
-- Network cost, by construction:
--   - never the relay nor Battle.net (a group is same-faction, the channel is enough);
--   - a leader re-sends its listing every 60 to 300 s, the interval growing with the
--     number of listings heard: up to 120 leaders (a full board) all the re-sends
--     together stay under 0.4 message per second; beyond, each leader stays at one
--     per 300 s. A new head count waits 20 s after the previous send, up to 100 s
--     on a full board;
--   - a channel send takes a free Sync token only, never a critical one;
--   - nobody answers a listing: a fresh client fills its board from the next re-sends;
--   - a sign-up is one whisper and one or two back, plus a cancel or a "not received"
--     when needed; a client reads twenty sign-ups in a row, then two a second.
--
-- Fully cut in instances: nothing sent, read or invited (Overlord:SuspendForInstance).
Overlord = Overlord or {}
local GF = Overlord.GroupFinder or {}
Overlord.GroupFinder = GF

local securecall = securecall or function(fn, ...) return fn(...) end
local strsplit = strsplit or function(sep, text, limit)
    local out, from, n = {}, 1, 0
    while true do
        n = n + 1
        local at = (not limit or n < limit) and text:find(sep, from, true) or nil
        if not at then
            out[n] = text:sub(from)
            break
        end
        out[n] = text:sub(from, at - 1)
        from = at + 1
    end
    return unpack(out)
end

GF.PREFIX = "OverlordGF"
GF.VERSION = "1"
GF.MAX_MSG = 120
GF.LEVEL_MAX = 80

GF.INTENTS = { a = true, d = true, h = true } -- attack, defend, hunt
-- z: capture point or capital, f: a whole front, o: outpost or keep, w: anywhere.
GF.KINDS = { z = true, f = true, o = true, w = true }
GF.SIZES = { 5, 10, 20, 40 }
GF.SIZE_OK = { [5] = true, [10] = true, [20] = true, [40] = true }
GF.MIN_LEVELS = { 0, 20, 40, 60 }
-- Wire index of a class token (0 = unknown). Append only: an index never changes.
GF.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE",
    "WARLOCK", "DRUID", "DEATHKNIGHT", "MONK", "DEMONHUNTER", "EVOKER" }

GF.BOARD_MAX = 120
GF.HEARTBEAT_BASE = 45
GF.HEARTBEAT_PER_LISTING = 2.5
GF.HEARTBEAT_MIN = 60
GF.HEARTBEAT_MAX = 300
GF.TTL_MIN = 60
GF.TTL_MAX = 660
GF.CHANGE_GAP = 20            -- seconds between two sends of the own listing
GF.SENDER_GAP = 8             -- a leader's listing is read at most once per 8 s
GF.RETRY_TRIES = 4
GF.BUSY_POLLS = 15            -- looks 0.3 s apart at an empty token bucket before backing off
GF.LISTING_LIFETIME = 3600    -- without a new member
GF.TICK_SEC = 5

GF.REQUEST_GAP = 10           -- one sign-up read per player per 10 s
GF.PENDING_MAX = 20
GF.PENDING_TTL = 180
GF.DECLINE_MUTE = 300
GF.INVITE_GAP = 0.6
GF.INVITE_OUTSTANDING_TTL = 60 -- an invitation holds its place as long as the game's prompt lasts
GF.NOTIFY_GAP = 20
GF.LISTEN_SEC = 90            -- the empty board says "listening" that long after the channel is joined
GF.LISTEN_START_SEC = 150     -- ... and never longer than this after a login or an instance

GF.APPLY_TIMEOUT = 12
GF.APPLY_RETRY_GAP = 20
GF.SIGNUP_BURST = 20          -- sign-ups read in a row, then SIGNUP_RATE a second
GF.SIGNUP_RATE = 2
-- "Invited" with no invitation in sight after 45 s: the leader is told. Not sooner: on
-- a slow server the game's invitation can come long after the leader's answer, and an
-- early alarm sends the leader after a player who is fine. Not later: the alarm must
-- reach the leader while he still holds the place (INVITE_OUTSTANDING_TTL).
GF.INVITE_CHECK_SEC = 45
-- One group joined per 2 minutes: joining a group also moves you to its layer, and
-- this window is for playing together, not for hopping. The wait starts when the
-- player really enters the leader's group, not at the invitation (a declined prompt
-- or a lost invitation costs nothing).
GF.SIGNUP_COOLDOWN = 120
GF.RELOAD_RESTORE_SEC = 120

GF.REPLY_STATUS = { i = "invited", p = "pending", d = "declined", f = "full", x = "gone", l = "level" }
GF.UNPUBLISH_TEXT = {
    lead = { "GF_CHAT_LEAD", "Your listing was withdrawn: you no longer lead the group." },
    expired = { "GF_CHAT_EXPIRED", "Your listing expired after an hour without a new member." },
    afk = { "GF_CHAT_AFK", "Your listing was withdrawn: you are away." },
}

GF.board = GF.board or {}             -- [key] = listing heard on the channel
GF.boardCount = GF.boardCount or 0
GF.pending = GF.pending or {}         -- sign-ups waiting for the leader (array)
GF.pendingByKey = GF.pendingByKey or {}
GF.outstanding = GF.outstanding or {} -- [key] = { at, raw }: invited, not in the group yet
GF.outstandingCount = GF.outstandingCount or 0
GF.muted = GF.muted or {}             -- [key] = time until which a declined player is ignored
GF.declinedBy = GF.declinedBy or {}   -- [leader key] = time until which that leader's refusal stands (our side)
GF.declinedCount = GF.declinedCount or 0
GF.mutedCount = GF.mutedCount or 0
GF.invitedAt = GF.invitedAt or {}     -- [key] = last invitation: no second automatic one for 2 min
GF._invitedBy = GF._invitedBy or {}   -- [leader name] = when that leader answered "invited" (our side)
GF.invitedCount = GF.invitedCount or 0
GF.requestSeen = GF.requestSeen or {}
GF._invitesSeen = GF._invitesSeen or {} -- [key] = when the game's invitation of that player reached us
GF.requestSeenCount = GF.requestSeenCount or 0
GF.strikes = GF.strikes or {}
GF.strikeCount = GF.strikeCount or 0
GF.revision = GF.revision or 0        -- one more at each change shown (read by the tests)
GF._badge = GF._badge or 0            -- requests shown on the panel's grid button
GF._targets = GF._targets or {}
GF.Random = GF.Random or function() return math.random() end

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end
GF.InInstance = InInstance

local function ServerNow()
    return (GetServerTime and GetServerTime()) or time()
end

-- Decimal field of at most three digits within [lo, hi], else nil.
local function Int(text, lo, hi)
    if type(text) ~= "string" or #text == 0 or #text > 3 or text:find("%D") then return nil end
    local n = tonumber(text)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function IsPlaceId(id)
    return type(id) == "string" and #id <= 32 and id:find("^[a-z][a-z_]*$") ~= nil
end

local function Notify(text)
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    end
end

-- ---------------------------------------------------------------------------
-- The local player
-- ---------------------------------------------------------------------------

function GF:FactionCode()
    local faction = Overlord.PlayerFaction
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return nil
end

function GF:PlayerName()
    local sync = Overlord.Sync
    local name = sync and sync.GetPlayerFullName and sync:GetPlayerFullName() or nil
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

function GF:PlayerClassIndex()
    if self._classIndex then return self._classIndex end
    local token
    if UnitClass then
        local ok, _, file = pcall(UnitClass, "player")
        if ok then token = file end
    end
    for index, name in ipairs(self.CLASSES) do
        if name == token then
            self._classIndex = index
            return index
        end
    end
    return 0
end

function GF:PlayerLevel()
    local level
    if Overlord.SafeUnitLevel then
        level = Overlord:SafeUnitLevel("player")
    elseif UnitLevel then
        level = UnitLevel("player")
    end
    level = math.floor(tonumber(level) or 1)
    return math.max(1, math.min(self.LEVEL_MAX, level))
end

-- Home group only: an instance group never reaches this module.
function GF:IsGrouped()
    return IsInGroup and IsInGroup(LE_PARTY_CATEGORY_HOME) and true or false
end

function GF:IsRaid()
    return IsInRaid and IsInRaid(LE_PARTY_CATEGORY_HOME) and true or false
end

function GF:IsLeader()
    return UnitIsGroupLeader and UnitIsGroupLeader("player", LE_PARTY_CATEGORY_HOME) and true or false
end

function GF:GroupSize()
    if not self:IsGrouped() then return 1 end
    local n = GetNumGroupMembers and GetNumGroupMembers(LE_PARTY_CATEGORY_HOME) or 1
    return math.max(1, math.min(40, tonumber(n) or 1))
end

function GF:CanLead()
    return not self:IsGrouped() or self:IsLeader()
end

function GF:DB()
    if type(OverlordDB) ~= "table" then return nil end
    if type(OverlordDB.groupFinder) ~= "table" then OverlordDB.groupFinder = {} end
    return OverlordDB.groupFinder
end

-- ---------------------------------------------------------------------------
-- Places
-- ---------------------------------------------------------------------------

function GF:IsValidTarget(kind, id)
    if kind == "w" then return id == "" end
    if not IsPlaceId(id) then return false end
    if kind == "z" then
        local fronts = Overlord.Fronts
        return fronts and fronts.IsKnownZoneId and fronts:IsKnownZoneId(id) and true or false
    elseif kind == "f" then
        local registry = Overlord.Fronts and Overlord.Fronts.Registry
        return registry ~= nil and registry[id] ~= nil
    elseif kind == "o" then
        local outpost = Overlord.Outpost
        return outpost and outpost.GetSite and outpost:GetSite(id) ~= nil or false
    end
    return false
end

-- Display facts of a place, built once per place (names are fixed at load).
function GF:DescribeTarget(kind, id)
    id = id or ""
    local cacheKey = kind .. ":" .. id
    local info = self._targets[cacheKey]
    if info then return info end
    info = { kind = kind, id = id, name = "", frontName = "" }
    local fronts = Overlord.Fronts
    if kind == "z" and fronts and fronts.GetZone then
        local zone, front = fronts:GetZone(id)
        if zone then
            info.zone = zone
            info.name = zone.name or id
        end
        if front then
            info.frontId = front.id
            info.frontName = front.dropdownLabel or front.mapName or ""
            info.mapID = front.preferredMapID
        end
    elseif kind == "f" and fronts and fronts.Registry then
        local front = fronts.Registry[id]
        if front then
            info.frontId = front.id
            info.name = front.mapName or front.dropdownLabel or id
            info.mapID = front.preferredMapID
        end
    elseif kind == "o" and Overlord.Outpost and Overlord.Outpost.GetSite then
        local site = Overlord.Outpost:GetSite(id)
        if site then
            info.site = site
            info.name = Overlord.Outpost.GetDisplayName and Overlord.Outpost:GetDisplayName(site) or id
            info.frontId = site.frontId
            info.mapID = site.mapID
            local front = site.frontId and fronts and fronts.Registry and fronts.Registry[site.frontId]
            if front then info.frontName = front.dropdownLabel or front.mapName or "" end
        end
    else
        info.name = T("GF_TARGET_ANYWHERE", "Anywhere")
    end
    if info.name == "" then info.name = id end
    self._targets[cacheKey] = info
    return info
end

-- "EK" / "K", nil while unknown (then nothing is filtered on it).
function GF:TargetContinent(info)
    if not info then return nil end
    if info.continent then return info.continent end
    if not info.mapID or not Overlord.GetMapContinent then return nil end
    local continent = Overlord:GetMapContinent(info.mapID)
    if continent then info.continent = continent end
    return continent
end

-- A row click sets the waypoint: a second click leaves it, and nothing is said in chat.
GF.WAYPOINT_OPTS = { noToggle = true, silent = true }

function GF:ShowOnMap(info)
    local markers = Overlord.MapMarkers
    if not info or not markers or InInstance() then return false end
    if info.kind == "z" and info.zone and markers.SetUserWaypointForFrontZone then
        return markers:SetUserWaypointForFrontZone(info.zone, info.frontId, self.WAYPOINT_OPTS)
    elseif info.kind == "o" and info.site and markers.SetUserWaypointForOutpostSite then
        return markers:SetUserWaypointForOutpostSite(info.site, self.WAYPOINT_OPTS)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

function GF:Send(msg, chatType, target)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    if InInstance() or #msg > 255 then return false end
    local result = securecall(C_ChatInfo.SendAddonMessage, self.PREFIX, msg, chatType, target)
    local ok = result == nil or result == true or result == 0
    if chatType == "CHANNEL" then
        local sync = Overlord.Sync
        if sync and sync.NoteChannelSendKind then sync:NoteChannelSendKind("GF", ok, #msg) end
    end
    return ok
end

-- One message on the faction channel. Returns true once Blizzard took it, else false
-- and why: "channel" (not joined yet), "busy" (no free token, or our own kill total
-- goes first: nothing was sent) or "refused" (Blizzard said no).
function GF:SendToChannel(msg)
    if InInstance() then return false end
    local sync = Overlord.Sync
    local channelId = sync and sync.GetChannelId and sync:GetChannelId() or nil
    if not channelId then return false, "channel" end
    -- Our own kill total waiting for its slot goes first: Blizzard refuses two channel
    -- messages about a second apart (same courtesy as the live-score bridge).
    if sync._channelKillPending
        and (tonumber(sync._channelKillAt) or 0) + (sync.CHANNEL_KILL_INTERVAL or 30) - GetTime() < 2 then
        return false, "busy"
    end
    if sync.TakeChannelToken and not sync:TakeChannelToken(false) then return false, "busy" end
    if self:Send(msg, "CHANNEL", channelId) then return true end
    return false, "refused"
end

-- known = the player whispered us a moment ago: he is online, so the name is not
-- put in Sync's table of names whose "No player named ..." line is hidden (a leader
-- answering a crowd would push Sync's own entries out of it).
function GF:Whisper(target, msg, known)
    if InInstance() then return false end
    local sync = Overlord.Sync
    if not sync or not sync.IsValidWhisperTarget or not sync:IsValidWhisperTarget(target) then
        return false
    end
    -- Recorded first: the offline filter then hides "No player named ..." for a leader
    -- who logged off between the listing and the click.
    if not known and sync._RememberRecentAddonWhisper then
        sync:_RememberRecentAddonWhisper(target, GetTime())
    end
    return self:Send(msg, "WHISPER", target)
end

-- late = the answer does not leave in the frame the request arrived (a click, an
-- invitation that waited for its turn): the player may have logged off meanwhile.
function GF:Reply(target, code, late)
    return self:Whisper(target, "R:" .. self.VERSION .. ":" .. code, not late)
end

-- Sign-ups a client reads: twenty in a row, then two a second (each one costs a
-- whisper back, and an invitation when it is automatic): room for a crowd answering a
-- new listing, a ceiling for characters sent to make a leader whisper. The rest is
-- dropped unread: the player's window says "no answer" and offers the sign-up again.
function GF:TakeSignupToken(now)
    local tokens = math.min(self.SIGNUP_BURST,
        (self._signupTokens or self.SIGNUP_BURST) + (now - (self._signupTokensAt or now)) * self.SIGNUP_RATE)
    self._signupTokensAt = now
    if tokens < 1 then
        self._signupTokens = tokens
        return false
    end
    self._signupTokens = tokens - 1
    return true
end

-- A bounded table of times is about to take one more entry: at its cap the entries
-- past their use go first, and the whole table only if that frees nothing.
local function MakeRoom(entries, count, cap, isStale, now)
    if count < cap then return entries, count end
    for key, value in pairs(entries) do
        if isStale(value, now) then
            entries[key] = nil
            count = count - 1
        end
    end
    if count >= cap then return {}, 0 end
    return entries, count
end

function GF.IsInviteStale(at, now) return now - at >= GF.SIGNUP_COOLDOWN end
function GF.IsRequestStale(at, now) return now - at >= GF.REQUEST_GAP end
function GF.IsPast(untilTime, now) return untilTime <= now end
-- A sender who is not silenced any more (his count towards the next silence restarts).
function GF.IsStrikeStale(strike, now) return strike.mutedUntil <= now and strike.n == 0 end

-- ---------------------------------------------------------------------------
-- State changes seen by the window
-- ---------------------------------------------------------------------------

function GF:Touch()
    self.revision = self.revision + 1
    local ui = Overlord.GroupFinderUI
    if not ui then return end
    local waiting = #self.pending
    if waiting ~= self._badge then
        self._badge = waiting
        if ui.UpdateGridBadge then ui:UpdateGridBadge(waiting) end
    end
    if ui.RequestRefresh then ui:RequestRefresh() end
end

function GF:EnsureTicker()
    if self.ticker or not C_Timer or not C_Timer.NewTicker then return end
    self.ticker = C_Timer.NewTicker(self.TICK_SEC, function() pcall(GF.OnTick, GF) end)
end

function GF:StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- ---------------------------------------------------------------------------
-- The own listing (leader)
-- ---------------------------------------------------------------------------

function GF:HeartbeatInterval()
    local interval = self.HEARTBEAT_BASE + self.HEARTBEAT_PER_LISTING * (self.boardCount + 1)
    return math.max(self.HEARTBEAT_MIN, math.min(self.HEARTBEAT_MAX, interval))
end

function GF:ScheduleSend(delay)
    self._sendGen = (self._sendGen or 0) + 1
    local own = self.own
    if not own then return end
    local gen = self._sendGen
    own.nextSendAt = GetTime() + delay
    C_Timer.After(delay, function()
        if GF._sendGen ~= gen then return end
        GF:TrySend()
    end)
end

function GF:TrySend()
    local own = self.own
    if not own or InInstance() then return end
    local faction = self:FactionCode()
    if not faction then return self:ScheduleSend(5) end
    local now = GetTime()
    local interval = self:HeartbeatInterval()
    local count, raid = self:GroupSize(), self:IsRaid()
    local msg = string.format("L:%s:%s:%s:%s:%s:%d:%d:%d:%d:%d:%d:%d", self.VERSION, faction,
        own.intent, own.kind, own.target, own.cap, count, own.minLevel,
        (own.auto and 1 or 0) + (raid and 2 or 0), self:PlayerClassIndex(), self:PlayerLevel(),
        math.floor(interval * 2 + 30))
    local ok, why = self:SendToChannel(msg)
    if ok then
        own.tries, own.polls, own.refusals = 0, 0, 0
        own.sentAt, own.sentCount, own.sentRaid, own.live = now, count, raid, true
        if own.state ~= "live" then
            own.state = "live"
            self:Touch()
        end
        -- A draw around the interval: leaders heard at the same moment drift apart.
        self:ScheduleSend(interval * (0.9 + 0.2 * self.Random()))
        return
    end
    -- tries > 0 = a retry is pending (a roster change must not pull it forward).
    own.tries = (own.tries or 0) + 1
    local delay, state
    if why == "channel" then
        delay, state = 10, "channel"
    elseif why == "busy" and (own.polls or 0) < self.BUSY_POLLS then
        -- No free token, nothing was sent: look again shortly for a few seconds. A
        -- relay with a backlog looks every 0.1 s and would otherwise take every
        -- token before a listing that only looked every few seconds.
        own.polls = (own.polls or 0) + 1
        delay = 0.3
    elseif why == "busy" then
        own.polls = 0
        delay, state = 20 + 10 * self.Random(), "retry"
    else
        -- Refused by Blizzard: a few spaced tries, then a slow pace.
        own.refusals = (own.refusals or 0) + 1
        state = "retry"
        if own.refusals <= self.RETRY_TRIES then
            delay = 2 + 4 * self.Random() + own.refusals
        else
            delay = 20 + 10 * self.Random()
        end
    end
    if state and own.state ~= state then
        own.state = state
        self:Touch()
    end
    self:ScheduleSend(delay)
end

function GF:CheckPublish()
    if InInstance() then return false, "GF_ERR_INSTANCE" end
    if not self:FactionCode() or not self:PlayerName() then return false, "GF_ERR_NOT_READY" end
    if not self:CanLead() then return false, "GF_ERR_NOT_LEADER" end
    if self:ChannelState() == "closed" then return false, "GF_LIVE_CLOSED" end
    return true
end

-- What the window says about the channel the listings travel on: "closed" (the game
-- refuses our join), "connecting" (not inside yet), "listening" (inside for less than
-- a minute and a half: the listings already published have not all been heard yet,
-- nobody is asked for them) or "open". Second value: seconds of listening left.
function GF:ChannelState()
    local sync = Overlord.Sync
    if sync and sync.IsChannelClosed and sync:IsChannelClosed() then
        self._listenUntil = nil
        return "closed"
    end
    if not (sync and sync.GetChannelId and sync:GetChannelId()) then
        self._listenUntil = nil
        return "connecting"
    end
    local now = GetTime()
    if not self._listenUntil then self._listenUntil = now + self.LISTEN_SEC end
    if now < self._listenUntil then return "listening", self._listenUntil - now end
    return "open"
end

function GF:SaveOwn()
    local db = self:DB()
    if not db then return end
    local own = self.own
    if not own then
        db.own = nil
        return
    end
    db.form = { intent = own.intent, kind = own.kind, target = own.target, cap = own.cap,
        minLevel = own.minLevel, auto = own.auto }
    db.own = { intent = own.intent, kind = own.kind, target = own.target, cap = own.cap,
        minLevel = own.minLevel, auto = own.auto, by = self:PlayerName(), at = ServerNow() }
end

-- spec = { intent, kind, target, cap, minLevel, auto }
function GF:Publish(spec, restored)
    local ok, err = self:CheckPublish()
    if not ok then return false, err end
    if type(spec) ~= "table" or not self.INTENTS[spec.intent] or not self.KINDS[spec.kind]
        or not self.SIZE_OK[spec.cap] or not self:IsValidTarget(spec.kind, spec.target or "") then
        return false, "GF_ERR_FORM"
    end
    if self:GroupSize() >= spec.cap then return false, "GF_ERR_GROUP_FULL" end
    local minLevel = math.floor(tonumber(spec.minLevel) or 0)
    minLevel = math.max(0, math.min(self.LEVEL_MAX, minLevel))
    local now = GetTime()
    self:ClearPending()
    self.own = { intent = spec.intent, kind = spec.kind, target = spec.target or "", cap = spec.cap,
        minLevel = minLevel, auto = spec.auto == true, activityAt = now,
        seenCount = self:GroupSize(), state = "sending", tries = 0 }
    self.own.info = self:DescribeTarget(spec.kind, self.own.target)
    self:SaveOwn()
    self:EnsureTicker()
    self:ScheduleSend(restored and 3 or 0.2)
    self:Touch()
    return true
end

-- The farewell is best effort: a listing dies of its own on every board once its
-- lifetime (sent with it) runs out, which is all an instance or a logout leaves.
function GF:SendTombstone(attempt)
    if self.own or InInstance() then return end
    local faction = self:FactionCode()
    if not faction then return end
    local ok, why = self:SendToChannel("X:" .. self.VERSION .. ":" .. faction)
    if not ok and (why == "busy" or why == "refused") and attempt < 3 then
        C_Timer.After(2.5 + attempt, function() GF:SendTombstone(attempt + 1) end)
    end
end

function GF:Unpublish(reason)
    local own = self.own
    if not own then return false end
    self.own = nil
    self._sendGen = (self._sendGen or 0) + 1
    self:ClearPending()
    self:SaveOwn()
    if own.live and not InInstance() then self:SendTombstone(1) end
    local text = self.UNPUBLISH_TEXT[reason]
    if text then Notify(T(text[1], text[2])) end
    self:Touch()
    return true
end

function GF:ConvertToRaid()
    if InInstance() or not self:IsGrouped() or self:IsRaid() or not self:IsLeader() then return false end
    local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if not convert then return false end
    securecall(convert)
    return true
end

-- ---------------------------------------------------------------------------
-- Sign-ups received (leader)
-- ---------------------------------------------------------------------------

function GF:RemovePending(key)
    local app = self.pendingByKey[key]
    if not app then return nil end
    self.pendingByKey[key] = nil
    for index, other in ipairs(self.pending) do
        if other == app then
            table.remove(self.pending, index)
            break
        end
    end
    return app
end

function GF:ClearPending()
    for index = #self.pending, 1, -1 do self.pending[index] = nil end
    for key in pairs(self.pendingByKey) do self.pendingByKey[key] = nil end
    for key in pairs(self.outstanding) do self.outstanding[key] = nil end
    self.outstandingCount = 0
    self._inviteSlot = nil
end

-- Invited players leave the count once they are in the group, or after a minute.
function GF:PruneOutstanding(now)
    if self.outstandingCount == 0 then return end
    local sync = Overlord.Sync
    for key, slot in pairs(self.outstanding) do
        if now - slot.at > self.INVITE_OUTSTANDING_TTL
            or (sync and sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(slot.raw)) then
            self.outstanding[key] = nil
            self.outstandingCount = self.outstandingCount - 1
        end
    end
end

-- A party of five takes nobody else until it is a raid.
function GF:CanInviteNow()
    return self:IsRaid() or self:GroupSize() + self.outstandingCount < 5
end

function GF:HasRoom()
    local own = self.own
    return own ~= nil and self:GroupSize() + self.outstandingCount < own.cap
end

function GF:DoInvite(app, late)
    if not self.own or InInstance() then return end
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if not invite then return end
    local slot = self.outstanding[app.key]
    if slot and slot.app == app then
        -- The minute of its place starts when the invitation leaves, not when it queued.
        slot.sent, slot.at = true, GetTime()
    end
    securecall(invite, app.raw)
    self:Reply(app.name, "i", late)
end

-- An invitation given up before it left (refused at its turn, cancelled by the
-- player): its place is free again and the two-minute memory forgets it.
function GF:DropQueuedInvite(key)
    self.outstanding[key] = nil
    self.outstandingCount = self.outstandingCount - 1
    if self.invitedAt[key] then
        self.invitedAt[key] = nil
        self.invitedCount = self.invitedCount - 1
    end
end

-- An invitation that waited for its turn: dropped if the listing was withdrawn or
-- replaced meanwhile, refused if the group filled up by another way.
function GF:DoQueuedInvite(app)
    local slot = self.outstanding[app.key]
    if not slot or slot.app ~= app then return end
    local own = self.own
    if own and self:GroupSize() >= own.cap then
        self:DropQueuedInvite(app.key)
        self:Reply(app.name, "f", true)
        return self:Touch()
    end
    self:DoInvite(app, true)
end

function GF:Invite(app, fromClick)
    local own = self.own
    if not own or InInstance() then return false end
    local now = GetTime()
    self:RemovePending(app.key)
    if not self.outstanding[app.key] then self.outstandingCount = self.outstandingCount + 1 end
    self.outstanding[app.key] = { at = now, raw = app.raw, app = app }
    -- Remembered for two minutes: no second automatic invitation to the same player
    -- (see OnSignup), whatever his own client says about its wait.
    if not self.invitedAt[app.key] then
        self.invitedAt, self.invitedCount = MakeRoom(self.invitedAt, self.invitedCount, 256,
            GF.IsInviteStale, now)
        self.invitedCount = self.invitedCount + 1
    end
    self.invitedAt[app.key] = now
    -- Invitations leave one at a time, 0.6 s apart. One asked by a click leaves inside
    -- that click, never from a timer.
    local slot = math.max(now, self._inviteSlot or 0)
    self._inviteSlot = slot + self.INVITE_GAP
    if fromClick or slot <= now then
        self:DoInvite(app, fromClick or now - app.at > 2)
    else
        C_Timer.After(slot - now, function() GF:DoQueuedInvite(app) end)
    end
    self:Touch()
    return true
end

-- The leader's click on a request.
function GF:Accept(key)
    local app = self.pendingByKey[key]
    if not app or not self.own then return false end
    if InInstance() then return false, "GF_ERR_INSTANCE" end
    if not self:CanLead() then return false, "GF_ERR_NOT_LEADER" end
    self:PruneOutstanding(GetTime())
    if not self:HasRoom() then return false, "GF_ERR_GROUP_FULL" end
    if not self:CanInviteNow() then return false, "GF_NEED_RAID" end
    -- The leader is at the window: the listing's hour starts again (an automatic
    -- invitation nobody accepts does not restart it).
    self.own.activityAt = GetTime()
    return self:Invite(app, true)
end

function GF:Decline(key)
    local app = self:RemovePending(key)
    if not app then return false end
    local now = GetTime()
    if not self.muted[key] then
        self.muted, self.mutedCount = MakeRoom(self.muted, self.mutedCount, 128, GF.IsPast, now)
        self.mutedCount = self.mutedCount + 1
    end
    self.muted[key] = now + self.DECLINE_MUTE
    if self.own then self.own.activityAt = now end
    self:Reply(app.name, "d", true)
    self:Touch()
    return true
end

-- A request the automatic invitation may take by itself: not one sent back by the
-- player ("not received": manual) nor one from a player invited minutes ago (held).
local function IsAutoRequest(app)
    return not app.manual and not app.held
end

function GF:HasQueuedAuto()
    for _, app in ipairs(self.pending) do
        if IsAutoRequest(app) then return true end
    end
    return false
end

-- Automatic invitation: whoever waited (raid conversion, an invitation that lapsed)
-- goes in now, in arrival order. Requests kept for the leader's click stay.
function GF:DrainPending()
    local own = self.own
    if not own or not own.auto then return end
    local index = 1
    while self.pending[index] and self:CanInviteNow() and self:HasRoom() do
        local app = self.pending[index]
        if IsAutoRequest(app) then
            self:Invite(app)
        else
            index = index + 1
        end
    end
end

-- One chat line per player and per listing, 20 s apart at most.
function GF:NotifyApplicant(app, now)
    local ui = Overlord.GroupFinderUI
    if ui and ui.IsShown and ui:IsShown() then return end
    local own = self.own
    if not own then return end
    if not own.told or own.toldCount >= 64 then own.told, own.toldCount = {}, 0 end
    if own.told[app.key] then return end
    if self._notifiedAt and now - self._notifiedAt < self.NOTIFY_GAP then return end
    self._notifiedAt = now
    own.told[app.key] = true
    own.toldCount = own.toldCount + 1
    -- An automatic listing stalled at five: the leader is told what unblocks it, once.
    if own.auto and not own.raidTold and IsAutoRequest(app)
        and not self:IsRaid() and self:GroupSize() >= 5 then
        own.raidTold = true
        Notify(T("GF_NEED_RAID", "Group of five: convert to raid to keep inviting."))
        return
    end
    Notify(string.format(T("GF_CHAT_APPLICANT", "%s (level %d) asks to join your group. /ov groups"),
        app.name, app.level))
end

-- ---------------------------------------------------------------------------
-- Receive
-- ---------------------------------------------------------------------------

function GF:SenderKey(sender)
    local sync = Overlord.Sync
    local canon = sync and sync.CanonicalForeverName and sync:CanonicalForeverName(sender) or nil
    if type(canon) ~= "string" or canon == "" then return nil end
    return canon:lower(), canon
end

-- Three malformed messages silence a sender for ten minutes.
function GF:Strike(key, now)
    local strike = self.strikes[key]
    if not strike then
        self.strikes, self.strikeCount = MakeRoom(self.strikes, self.strikeCount, 64, GF.IsStrikeStale, now)
        strike = { n = 0, mutedUntil = 0 }
        self.strikes[key] = strike
        self.strikeCount = self.strikeCount + 1
    end
    strike.n = strike.n + 1
    if strike.n >= 3 then
        strike.n = 0
        strike.mutedUntil = now + 600
    end
end

function GF:IsStruck(key, now)
    local strike = self.strikes[key]
    return strike ~= nil and strike.mutedUntil > now
end

function GF:RemoveEntry(key)
    if not self.board[key] then return false end
    self.board[key] = nil
    self.boardCount = self.boardCount - 1
    local apply = self.apply
    if apply and apply.key == key and (apply.status == "sent" or apply.status == "pending") then
        apply.status = "gone"
        apply.at = GetTime()
    end
    return true
end

function GF:SweepBoard(now)
    local removed = false
    for key, entry in pairs(self.board) do
        if entry.expires <= now then
            self:RemoveEntry(key)
            removed = true
        end
    end
    return removed
end

function GF:OnListing(text, sender)
    local key, canon = self:SenderKey(sender)
    if not key then return end
    local now = GetTime()
    local entry = self.board[key]
    -- Rate guard before any parsing.
    if entry and now - entry.heardAt < self.SENDER_GAP then return end
    if self:IsStruck(key, now) then return end
    local _, ver, fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra =
        strsplit(":", text, 14)
    -- Another protocol version is not ours to judge.
    if ver ~= self.VERSION then return end
    cap, count, minLevel = Int(cap, 5, 40), Int(count, 1, 40), Int(minLevel, 0, self.LEVEL_MAX)
    flags, class = Int(flags, 0, 3), Int(class, 0, #self.CLASSES)
    level, ttl = Int(level, 1, self.LEVEL_MAX), Int(ttl, 1, 999)
    if extra or not (cap and count and minLevel and flags and class and level and ttl)
        or not self.SIZE_OK[cap] or not self.INTENTS[intent] or not self.KINDS[kind]
        or (fac ~= "A" and fac ~= "H")
        or (kind == "w" and target ~= "") or (kind ~= "w" and not IsPlaceId(target)) then
        return self:Strike(key, now)
    end
    if fac ~= self:FactionCode() then return end
    -- A place this version does not know cannot be worded: no row, no blame.
    if not self:IsValidTarget(kind, target) then return end
    local changed = false
    if not entry then
        local sync = Overlord.Sync
        if sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(canon) then return end
        if self.boardCount >= self.BOARD_MAX then
            self:SweepBoard(now)
            if self.boardCount >= self.BOARD_MAX then
                -- Full board: a group with room takes the row of a full one (never the
                -- one the player signed up to); a full group waits for a free row.
                if count >= cap then return end
                local applied, victim = self.apply and self.apply.key, nil
                for otherKey, other in pairs(self.board) do
                    if other.count >= other.cap and otherKey ~= applied then
                        victim = otherKey
                        break
                    end
                end
                if not victim then return end
                self:RemoveEntry(victim)
            end
        end
        entry = { key = key, name = canon }
        self.board[key] = entry
        self.boardCount = self.boardCount + 1
        changed = true
    end
    local auto, raid = flags % 2 == 1, flags >= 2
    if entry.kind ~= kind or entry.target ~= target then
        entry.kind, entry.target = kind, target
        entry.info = self:DescribeTarget(kind, target)
        changed = true
    end
    if entry.intent ~= intent or entry.cap ~= cap or entry.count ~= count
        or entry.minLevel ~= minLevel or entry.auto ~= auto or entry.raid ~= raid
        or entry.class ~= class or entry.level ~= level then
        entry.intent, entry.cap, entry.count, entry.minLevel = intent, cap, count, minLevel
        entry.auto, entry.raid, entry.class, entry.level = auto, raid, class, level
        changed = true
    end
    entry.raw = sender
    entry.heardAt = now
    entry.expires = now + math.max(self.TTL_MIN, math.min(self.TTL_MAX, ttl))
    self:EnsureTicker()
    if changed then self:Touch() end
end

function GF:OnTombstone(text, sender)
    if text ~= "X:" .. self.VERSION .. ":A" and text ~= "X:" .. self.VERSION .. ":H" then return end
    local key = self:SenderKey(sender)
    if key and self:RemoveEntry(key) then self:Touch() end
end

-- Whisper "J:<ver>:<A|H>:<intent>:<kind>:<target>:<class>:<level>" to a leader.
function GF:OnSignup(text, sender)
    local key, canon = self:SenderKey(sender)
    if not key then return end
    local now = GetTime()
    local seen = self.requestSeen[key]
    if seen and now - seen < self.REQUEST_GAP then return end
    if self:IsStruck(key, now) then return end
    if not seen then
        self.requestSeen, self.requestSeenCount = MakeRoom(self.requestSeen, self.requestSeenCount,
            256, GF.IsRequestStale, now)
        self.requestSeenCount = self.requestSeenCount + 1
    end
    self.requestSeen[key] = now
    if not self:TakeSignupToken(now) then return end
    local _, ver, fac, intent, kind, target, class, level, extra = strsplit(":", text, 9)
    if ver ~= self.VERSION then return end
    class, level = Int(class, 0, #self.CLASSES), Int(level, 1, self.LEVEL_MAX)
    if extra or not class or not level or (fac ~= "A" and fac ~= "H")
        or not self.INTENTS[intent] or not self.KINDS[kind]
        or (kind == "w" and target ~= "") or (kind ~= "w" and not IsPlaceId(target)) then
        return self:Strike(key, now)
    end
    if fac ~= self:FactionCode() then return end
    local sync = Overlord.Sync
    if sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(canon) then return end
    local mutedUntil = self.muted[key]
    if mutedUntil and mutedUntil > now then return end
    local own = self.own
    -- The listing the player saw is gone or changed.
    if not own or own.intent ~= intent or own.kind ~= kind or own.target ~= target
        or not self:CanLead() then
        return self:Reply(canon, "x")
    end
    if sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender) then return end
    if level < own.minLevel then return self:Reply(canon, "l") end
    self:PruneOutstanding(now)
    -- Whoever already waits goes first (arrival order).
    self:DrainPending()
    if self.outstanding[key] then return self:Reply(canon, "i") end
    if not self:HasRoom() then return self:Reply(canon, "f") end
    local app = self.pendingByKey[key]
    if app then
        app.at = now
        return self:Reply(canon, "p")
    end
    app = { key = key, name = canon, raw = sender, class = class, level = level, at = now }
    -- Invited less than two minutes ago (left again, or was removed): the leader
    -- decides this time. The two-minute rule holds here, not only on the player's side.
    local invitedAt = self.invitedAt[key]
    if invitedAt and now - invitedAt < self.SIGNUP_COOLDOWN then app.held = true end
    if own.auto and not app.held and not self:HasQueuedAuto() and self:CanInviteNow() then
        return self:Invite(app)
    end
    if #self.pending >= self.PENDING_MAX then return self:Reply(canon, "f") end
    self.pending[#self.pending + 1] = app
    self.pendingByKey[key] = app
    self:Reply(canon, "p")
    self:NotifyApplicant(app, now)
    self:Touch()
end

-- "C": the player signed up elsewhere. His request leaves the list, and so does an
-- invitation still waiting for its turn (one that left is the game's business).
function GF:OnCancel(text, sender)
    if text ~= "C:" .. self.VERSION then return end
    local key = self:SenderKey(sender)
    if not key then return end
    local changed = self:RemovePending(key) ~= nil
    local slot = self.outstanding[key]
    if slot and not slot.sent then
        self:DropQueuedInvite(key)
        changed = true
    end
    if changed then self:Touch() end
end

-- "N": a player we invited saw no invitation arrive (the game can drop an invitation
-- without a word, and he may simply have another prompt open). Read once per
-- invitation, and it only concerns its author: his request goes back to the list for
-- an invitation from the leader's click; after a click that failed too, only the
-- game's own /invite is left. Everyone else is still invited automatically.
function GF:OnNotReceived(text, sender)
    if text ~= "N:" .. self.VERSION then return end
    local key = self:SenderKey(sender)
    local slot = key and self.outstanding[key]
    if not slot or not self.own then return end
    self.outstanding[key] = nil
    self.outstandingCount = self.outstandingCount - 1
    local app = slot.app
    if app.manual then
        Notify(string.format(T("GF_CHAT_INVITE_TYPE",
            "The game refused the invitation again. Type: /invite %s"), app.name))
    else
        app.manual = true
        app.at = GetTime()
        if not self.pendingByKey[key] and #self.pending < self.PENDING_MAX then
            self.pending[#self.pending + 1] = app
            self.pendingByKey[key] = app
            Notify(string.format(T("GF_CHAT_INVITE_LOST",
                "%s did not receive the invitation. Invite from the window (/ov groups)."), app.name))
        end
    end
    self:Touch()
end

function GF:OnReply(text, sender)
    local apply = self.apply
    if not apply then return end
    -- A lost invitation is tried again from the leader's click: "invited" is read once
    -- more (once only: two "not received" per sign-up at most).
    local lost = apply.status == "lost"
    -- An automatic invitation waits for its turn (0.6 s apart): in a crowd it can come
    -- after our own wait for an answer ran out. "Invited" is still read then.
    local overdue = apply.status == "timeout"
    if not lost and not overdue and apply.status ~= "sent" and apply.status ~= "pending" then return end
    if #text ~= 5 or text:sub(1, 4) ~= "R:" .. self.VERSION .. ":" then return end
    local status = self.REPLY_STATUS[text:sub(5, 5)]
    if not status or self:SenderKey(sender) ~= apply.key then return end
    if lost then
        if status ~= "invited" or apply.retried then return end
        apply.retried = true
    elseif overdue and status ~= "invited" then
        return
    end
    -- This leader answers: his row is no longer ranked as silent.
    local entry = self.board[apply.key]
    if entry then entry.silent = nil end
    apply.status = status
    apply.at = GetTime()
    if status == "declined" then
        -- Remembered as long as the leader's client ignores us: a new click would be
        -- a whisper into the void and a false "no answer".
        if not self.declinedBy[apply.key] then
            self.declinedBy, self.declinedCount = MakeRoom(self.declinedBy, self.declinedCount, 64,
                GF.IsPast, apply.at)
            self.declinedCount = self.declinedCount + 1
        end
        self.declinedBy[apply.key] = apply.at + self.DECLINE_MUTE
    end
    if status == "invited" then
        self:NoteInvitedBy(apply.name)
        C_Timer.After(self.INVITE_CHECK_SEC, function() GF:CheckInviteArrived(apply) end)
    end
    self:Touch()
end

-- The leader's client says "invited": the game's invitation must have reached us
-- (PARTY_INVITE_REQUEST from him since the click, or while he still counted it: a
-- second click on a leader who already invited us gets "invited" with no new prompt),
-- or we are already in the group. Somebody else's invitation does not count; one whose
-- sender the game does not name counts by its moment. If not, the leader is told.
function GF:CheckInviteArrived(apply)
    if self.apply ~= apply or apply.status ~= "invited" or InInstance() then return end
    -- After a first loss the same test only passes for an invitation seen since.
    local since = apply.sentAt - self.INVITE_OUTSTANDING_TTL
    if self:IsGrouped() or (self._invitesSeen[apply.key] or 0) >= since
        or (self._inviteSeenAt or 0) >= since then
        return
    end
    apply.status = "lost"
    apply.at = GetTime()
    self:Whisper(apply.name, "N:" .. self.VERSION)
    self:Touch()
end

-- An invitation of the game reached us (PARTY_INVITE_REQUEST). It is remembered under
-- its sender's name for CheckInviteArrived; a name the game hides or does not give in
-- full only leaves its moment.
-- If it is the leader's and we had already told him it was lost (a server slower than
-- our wait), it is in hand after all: our row says so and the leader's client forgets
-- the request it had taken back.
function GF:OnInviteSeen(inviter)
    local now = GetTime()
    local key
    -- The game can hand the name back as a protected value: never tested then.
    if (not canaccessvalue or canaccessvalue(inviter)) and type(inviter) == "string" then
        key = self:SenderKey(inviter)
    end
    if not key then
        self._inviteSeenAt = now
        return
    end
    -- A handful of names at most: what is older than any request still open goes.
    local seen, count = self._invitesSeen, 0
    for name, at in pairs(seen) do
        if now - at > self.SIGNUP_COOLDOWN then seen[name] = nil else count = count + 1 end
    end
    if count >= 16 then
        seen = {}
        self._invitesSeen = seen
    end
    seen[key] = now
    local apply = self.apply
    if not apply or apply.status ~= "lost" or apply.key ~= key then return end
    apply.status = "invited"
    apply.at = now
    self:NoteInvitedBy(apply.name)
    self:Whisper(apply.name, "C:" .. self.VERSION)
    self:Touch()
end

function GF:OnAddonMessage(text, channel, sender)
    if type(text) ~= "string" or type(sender) ~= "string" then return end
    if #text < 3 or #text > self.MAX_MSG or text:byte(2) ~= 58 then return end
    local sync = Overlord.Sync
    if not sync or not self:FactionCode() then return end
    if sync.IsSenderLocalPlayer and sync:IsSenderLocalPlayer(sender) then return end
    local tag = text:byte(1)
    -- A listing is only read from the channel, a sign-up only from a whisper.
    if channel == "CHANNEL" then
        if tag == 76 then
            self:OnListing(text, sender)
        elseif tag == 88 then
            self:OnTombstone(text, sender)
        end
    elseif channel == "WHISPER" then
        if tag == 74 then
            self:OnSignup(text, sender)
        elseif tag == 82 then
            self:OnReply(text, sender)
        elseif tag == 67 then
            self:OnCancel(text, sender)
        elseif tag == 78 then
            self:OnNotReceived(text, sender)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Signing up (player)
-- ---------------------------------------------------------------------------

-- The wait is kept per character (the saved variables are shared by the account), and
-- across a reload.
function GF:StartSignupCooldown()
    self._signupAt = ServerNow()
    local db, name = self:DB(), self:PlayerName()
    if not db or not name then return end
    if type(db.signups) ~= "table" then db.signups = {} end
    for who, at in pairs(db.signups) do
        if self._signupAt - (tonumber(at) or 0) >= self.SIGNUP_COOLDOWN then db.signups[who] = nil end
    end
    db.signups[name] = self._signupAt
end

function GF:ClearSignupCooldown()
    self._signupAt = 0
    local db, name = self:DB(), self:PlayerName()
    if db and name and type(db.signups) == "table" then db.signups[name] = nil end
end

function GF:SignupCooldownRemaining()
    local at = self._signupAt
    if not at then
        local name = self:PlayerName()
        if not name then return 0 end
        local db = self:DB()
        at = (db and type(db.signups) == "table" and tonumber(db.signups[name])) or 0
        self._signupAt = at
    end
    local left = self.SIGNUP_COOLDOWN - (ServerNow() - at)
    if left <= 0 or left > self.SIGNUP_COOLDOWN then return 0 end
    return left
end

function GF:GetApplyStatus(key)
    local apply = self.apply
    if apply and apply.key == key then return apply.status end
    local declinedUntil = self.declinedBy[key]
    if declinedUntil and declinedUntil > GetTime() then return "declined" end
    return nil
end

-- ok, reasonKey, reasonArg
function GF:CanSignUp(entry)
    if not entry then return false, "GF_ERR_FULL" end
    if InInstance() then return false, "GF_ERR_INSTANCE" end
    if self:IsGrouped() then return false, "GF_ERR_GROUPED" end
    if entry.count >= entry.cap then return false, "GF_ERR_FULL" end
    if self:PlayerLevel() < entry.minLevel then return false, "GF_ERR_LEVEL", entry.minLevel end
    local declinedUntil = self.declinedBy[entry.key]
    if declinedUntil then
        local left = declinedUntil - GetTime()
        if left > 0 then return false, "GF_ERR_COOLDOWN", left end
    end
    local apply = self.apply
    if apply and apply.key == entry.key then
        if apply.status == "sent" or apply.status == "pending" or apply.status == "invited" then
            return false, "GF_ERR_WAIT"
        end
        if GetTime() - apply.at < self.APPLY_RETRY_GAP then return false, "GF_ERR_WAIT" end
    end
    local left = self:SignupCooldownRemaining()
    if left > 0 then return false, "GF_ERR_COOLDOWN", left end
    return true
end

function GF:SignUp(key)
    local entry = self.board[key]
    local ok, reason, arg = self:CanSignUp(entry)
    if not ok then return false, reason, arg end
    local faction = self:FactionCode()
    if not faction then return false, "GF_ERR_NOT_READY" end
    -- One request at a time: the previous leader is told to forget ours.
    local previous = self.apply
    -- An invitation not taken counts too (its queued turn is given up; the wait only
    -- starts in a group, see StartCooldownIfJoined).
    if previous and previous.key ~= key and (previous.status == "pending" or previous.status == "sent"
        or previous.status == "lost" or previous.status == "timeout" or previous.status == "invited") then
        self:Whisper(previous.name, "C:" .. self.VERSION)
    end
    local msg = string.format("J:%s:%s:%s:%s:%s:%d:%d", self.VERSION, faction, entry.intent,
        entry.kind, entry.target, self:PlayerClassIndex(), self:PlayerLevel())
    if not self:Whisper(entry.name, msg) then return false, "GF_ERR_SEND" end
    local apply = { key = key, name = entry.name, at = GetTime(), sentAt = GetTime(), status = "sent" }
    self.apply = apply
    self:EnsureTicker()
    C_Timer.After(self.APPLY_TIMEOUT, function()
        if GF.apply == apply and apply.status == "sent" then
            apply.status = "timeout"
            apply.at = GetTime()
            -- A leader who does not answer goes to the end of this player's board.
            local silent = GF.board[apply.key]
            if silent then silent.silent = true end
            GF:Touch()
        end
    end)
    self:Touch()
    return true
end

-- ---------------------------------------------------------------------------
-- Views for the window
-- ---------------------------------------------------------------------------

-- Among equals the fullest groups come first, as in the game's own group finder:
-- more members, then the smaller size (4/5 before 4/40), then the leader's name.
function GF.CompareEntries(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.count ~= b.count then return a.count > b.count end
    if a.cap ~= b.cap then return a.cap < b.cap end
    return a.key < b.key
end

-- Fills `out` (reused by the caller) with the live listings: those the player can
-- join first, then the player's continent, then the fullest groups (a row moves up
-- as its group fills); a leader who left this player's request unanswered goes last.
function GF:FillBoard(out)
    local now = GetTime()
    local level = self:PlayerLevel()
    local continent = Overlord.GetPlayerContinent and Overlord:GetPlayerContinent() or nil
    local n, players = 0, 0
    for _, entry in pairs(self.board) do
        if entry.expires > now then
            n = n + 1
            out[n] = entry
            players = players + entry.count
            local place = self:TargetContinent(entry.info)
            local far = continent ~= nil and place ~= nil and place ~= continent
            local open = entry.count < entry.cap and level >= entry.minLevel
            local declinedUntil = self.declinedBy[entry.key]
            entry.rank = (open and 0 or 2) + (far and 1 or 0)
                + ((entry.silent or (declinedUntil and declinedUntil > now)) and 4 or 0)
        end
    end
    for index = #out, n + 1, -1 do out[index] = nil end
    table.sort(out, self.CompareEntries)
    return n, players
end

function GF:GetForm()
    local db = self:DB()
    local saved = db and db.form
    local form = { intent = "a", kind = "w", target = "", cap = 10, minLevel = 0, auto = false }
    if type(saved) == "table" and self.INTENTS[saved.intent] and self.KINDS[saved.kind]
        and self.SIZE_OK[saved.cap] and self:IsValidTarget(saved.kind, saved.target or "") then
        form.intent, form.kind, form.target, form.cap = saved.intent, saved.kind, saved.target or "", saved.cap
        form.minLevel = math.max(0, math.min(self.LEVEL_MAX, math.floor(tonumber(saved.minLevel) or 0)))
        form.auto = saved.auto == true
    end
    return form
end

-- ---------------------------------------------------------------------------
-- Clock, roster, lifecycle
-- ---------------------------------------------------------------------------

function GF:OnTick()
    if InInstance() then return end
    local now = GetTime()
    local changed = self:SweepBoard(now)
    local own = self.own
    if own and now - own.activityAt > self.LISTING_LIFETIME then
        self:Unpublish("expired")
        own = nil
    end
    if own then
        for index = #self.pending, 1, -1 do
            local app = self.pending[index]
            if now - app.at > self.PENDING_TTL then
                table.remove(self.pending, index)
                self.pendingByKey[app.key] = nil
                changed = true
            end
        end
        -- An invitation nobody answered frees its place after a minute: whoever
        -- waits behind it is invited without waiting for a roster event.
        if self.pending[1] then
            self:PruneOutstanding(now)
            self:DrainPending()
        end
    end
    local apply = self.apply
    if apply then
        if apply.status == "pending" and now - apply.at > self.PENDING_TTL + 20 then
            apply.status = "timeout"
            apply.at = now
            changed = true
        elseif apply.status ~= "sent" and apply.status ~= "pending"
            and now - apply.at > (apply.status == "invited" and 90
                or apply.status == "lost" and self.PENDING_TTL or self.APPLY_RETRY_GAP) then
            -- A settled answer stays on its row until a new request is allowed; an
            -- invitation, a minute and a half (longer than INVITE_CHECK_SEC, whose
            -- look needs the request still there); a lost one, as long as the leader
            -- keeps the request for his click.
            self.apply = nil
            changed = true
        end
    end
    if self.declinedCount > 0 then
        for key, untilTime in pairs(self.declinedBy) do
            if untilTime <= now then
                self.declinedBy[key] = nil
                self.declinedCount = self.declinedCount - 1
                changed = true
            end
        end
    end
    if changed then self:Touch() end
    if self.boardCount == 0 and not self.own and not self.apply and self.declinedCount == 0 then
        self:StopTicker()
    end
end

function GF:OnRosterSettled()
    if InInstance() then return end
    local now = GetTime()
    local grouped = self:IsGrouped()
    if grouped then self:StartCooldownIfJoined(now) end
    if grouped and self.apply then self.apply = nil end
    local own = self.own
    if own then
        if grouped and not self:IsLeader() then
            self:Unpublish("lead")
            return
        end
        self:PruneOutstanding(now)
        local count, raid = self:GroupSize(), self:IsRaid()
        -- A new member restarts the listing's hour (counted against the last head count
        -- seen, not the last one sent: a member replaced between two sends counts).
        if count > own.seenCount then own.activityAt = now end
        own.seenCount = count
        if own.live and (count ~= own.sentCount or raid ~= own.sentRaid) then
            -- The new head count leaves 20 s after the previous send at the earliest,
            -- later on a busy board (a third of the re-send interval). A refused send
            -- already waits for its retry, which reads the head count as it leaves.
            local gap = math.max(self.CHANGE_GAP, self:HeartbeatInterval() / 3)
            local due = math.max(1, (own.sentAt or 0) + gap - now)
            if (own.tries or 0) == 0 and (not own.nextSendAt or own.nextSendAt - now > due) then
                self:ScheduleSend(due)
            end
        end
        -- A request sent back by a player whose invitation was only late: he is in the
        -- group now, nothing is left to click.
        local sync = Overlord.Sync
        if self.pending[1] and sync and sync.SenderIsInOurGroup then
            for index = #self.pending, 1, -1 do
                local app = self.pending[index]
                if sync:SenderIsInOurGroup(app.raw) then
                    table.remove(self.pending, index)
                    self.pendingByKey[app.key] = nil
                end
            end
        end
        self:DrainPending()
    end
    self:Touch()
end

-- A leader answered "invited": remembered two minutes, so that entering his group
-- starts the wait even after a sign-up elsewhere.
function GF:NoteInvitedBy(name)
    if type(name) ~= "string" or name == "" then return end
    local now = GetTime()
    for who, at in pairs(self._invitedBy) do
        if now - at >= self.SIGNUP_COOLDOWN then self._invitedBy[who] = nil end
    end
    self._invitedBy[name] = now
end

-- In the group of a leader who invited us (the request still open, or one answered
-- "invited" in the last two minutes): the two-minute wait starts now. Not for a group
-- joined some other way.
function GF:StartCooldownIfJoined(now)
    local apply, sync = self.apply, Overlord.Sync
    if not (sync and sync.SenderIsInOurGroup) then
        if apply and apply.status == "invited" then self:StartSignupCooldown() end
        return
    end
    local joined = apply and sync:SenderIsInOurGroup(apply.name)
    if not joined then
        for name, at in pairs(self._invitedBy) do
            if now - at < self.SIGNUP_COOLDOWN and sync:SenderIsInOurGroup(name) then
                joined = true
                break
            end
        end
    end
    if joined then
        self:StartSignupCooldown()
        self._invitedBy = {}
    end
end

-- A join fires a burst of roster events: one pass half a second after the first.
function GF:OnRosterEvent()
    if self._rosterTimer then return end
    local function settle()
        GF._rosterTimer = nil
        GF:OnRosterSettled()
    end
    if C_Timer.NewTimer then
        self._rosterTimer = C_Timer.NewTimer(0.5, settle)
    else
        self._rosterTimer = true
        C_Timer.After(0.5, settle)
    end
end

function GF:RestoreAfterReload(attempt)
    local db = self:DB()
    local saved = db and db.own
    if type(saved) ~= "table" or self.own then return end
    if InInstance() then
        db.own = nil
        return
    end
    local name = self:PlayerName()
    if not name or not self:FactionCode() then
        -- The full name is not readable yet: twice more, then give up.
        if (attempt or 1) < 3 then
            C_Timer.After(6, function() GF:RestoreAfterReload((attempt or 1) + 1) end)
        else
            db.own = nil
        end
        return
    end
    db.own = nil
    local age = ServerNow() - (tonumber(saved.at) or 0)
    if saved.by ~= name or age < 0 or age > self.RELOAD_RESTORE_SEC then return end
    self:Publish(saved, true)
end

GF.EVENTS = { "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PARTY_INVITE_REQUEST" }

function GF:RegisterLiveEvents(on)
    local frame = self.frame
    if not frame then return end
    for _, event in ipairs(self.EVENTS) do
        if on then
            pcall(frame.RegisterEvent, frame, event)
        else
            pcall(frame.UnregisterEvent, frame, event)
        end
    end
    -- Only the player's own AFK flag is read: filtered on the client side so the flag
    -- flips of every visible player stay out of Lua. Plain registration if refused.
    if on then
        local unitOk = frame.RegisterUnitEvent
            and pcall(frame.RegisterUnitEvent, frame, "PLAYER_FLAGS_CHANGED", "player")
        if not unitOk then pcall(frame.RegisterEvent, frame, "PLAYER_FLAGS_CHANGED") end
    else
        pcall(frame.UnregisterEvent, frame, "PLAYER_FLAGS_CHANGED")
    end
end

-- Instance: the listing, the sign-ups and the board are dropped without a word (a
-- listing dies of its lifetime on the other boards) and no event is read any more.
function GF:OnInstanceSuspend()
    local ui = Overlord.GroupFinderUI
    if ui and ui.IsShown and ui:IsShown() then ui:Hide() end
    self:RegisterLiveEvents(false)
    self:StopTicker()
    self._sendGen = (self._sendGen or 0) + 1
    if self._rosterTimer and type(self._rosterTimer) == "table" and self._rosterTimer.Cancel then
        self._rosterTimer:Cancel()
    end
    self._rosterTimer = nil
    self.own, self.apply = nil, nil
    self._listenUntil = nil
    self.declinedBy, self.declinedCount = {}, 0
    self._invitesSeen, self._inviteSeenAt = {}, nil
    self._invitedBy = {}
    self:ClearPending()
    for key in pairs(self.board) do self.board[key] = nil end
    self.boardCount = 0
    local db = self:DB()
    if db then db.own = nil end
    self._badge = 0
    if ui and ui.UpdateGridBadge then ui:UpdateGridBadge(0) end
end

function GF:OnInstanceResume()
    self._listenUntil = GetTime() + self.LISTEN_START_SEC
    self:RegisterLiveEvents(true)
end

function GF:OnEvent(event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix = ...
        -- A protected value cannot be ours (and comparing it may raise).
        if canaccessvalue and not canaccessvalue(prefix) then return end
        if prefix ~= self.PREFIX then return end
        if InInstance() then return end
        local _, text, channel, sender = ...
        pcall(self.OnAddonMessage, self, text, channel, sender)
        return
    end
    if event == "PLAYER_LOGOUT" then
        -- A reload within two minutes puts the listing back.
        local db = self.own and self:DB()
        if db and db.own then db.own.at = ServerNow() end
        return
    end
    if InInstance() then return end
    if event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LEADER_CHANGED" then
        self:OnRosterEvent()
    elseif event == "PARTY_INVITE_REQUEST" then
        -- Whatever the game hands us as a name, the moment at least is kept.
        if not pcall(self.OnInviteSeen, self, (...)) then self._inviteSeenAt = GetTime() end
    elseif event == "PLAYER_FLAGS_CHANGED" then
        local unit = ...
        if unit == "player" and self.own and UnitIsAFK then
            -- The game can hand this flag back as a protected value: never tested then.
            local ok, afk = pcall(UnitIsAFK, "player")
            if ok and (not canaccessvalue or canaccessvalue(afk)) and afk then
                self:Unpublish("afk")
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not self._restoreTried then
            self._restoreTried = true
            C_Timer.After(6, function() GF:RestoreAfterReload(1) end)
        end
    end
end

function GF:Initialize()
    if self.initialized or not CreateFrame then return end
    self.initialized = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    end
    local frame = CreateFrame("Frame")
    self.frame = frame
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_LOGOUT")
    -- Registered whatever the place: a login inside an instance may get no resume call,
    -- and every handler returns before reading anything there.
    self:RegisterLiveEvents(true)
    frame:SetScript("OnEvent", function(_, event, ...) GF:OnEvent(event, ...) end)
    self._listenUntil = GetTime() + self.LISTEN_START_SEC
end

function GF:HandleCommand()
    local ui = Overlord.GroupFinderUI
    if ui and ui.Toggle then ui:Toggle() end
end

if CreateFrame then
    local boot = CreateFrame("Frame")
    boot:RegisterEvent("PLAYER_LOGIN")
    boot:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        GF:Initialize()
    end)
end
