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
-- When the server refuses addon messages on the channel (ChannelDirectory:IsActive), the
-- listings go from hand to hand by whisper among the directory's contacts ("relay"
-- mode, see the Hands section): the leader whispers its listing to a few contacts, each
-- passes it on to a few of its own, three hands at most, each copy once. A window that
-- opens asks one contact for the best listings it holds. Every whisper of this comes out
-- of a small bucket of its own, and none while the directory's chain is short of tokens
-- (captures first). With no contact yet the listing waits ("connecting").
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
GF.MAX_MSG = 160
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
GF.RESTORE_TRIES = 12         -- a listing put back after a reload waits that many looks 10 s apart

-- Hands (relay mode). Wire, whisper only, prefix OverlordGF:
--   G:1:<hand>:<leader>:<rev>:<fields of L from the faction on>   a listing
--   X:1:<hand>:<leader>:<rev>                                     its withdrawal
--   Q:1                                                           "your best listings?"
--   B:1:<leader>:<rev>:<age>:<fields>|...                         the answer, 2 per message
-- rev: the leader's server time when it sent (mod 10^6, one more when two fall in the
-- same second): a newer copy of a listing always has a newer rev, across reloads too.
GF.HANDS = 3
-- Contacts whispered at each hand, by size of the member list (1: the leader's own).
-- Modelled on lists where each client greeted 6 others, 15 % in instances: a list of 260
-- gets about 320 whispers per copy for about 72 % of it reached (a window that opens
-- asks a contact for the rest); 40: 50 whispers, 76 %; 120: 160, 76 %; 500: 520, 65 %.
-- (The leader's own hand goes whole and within HAND_BURST, see SpreadOwn: the 12 of the last
-- row is 10 contacts in fact, and from a fan of 10 no leaf copy goes with it. The 260 and 500
-- figures were modelled with those copies: a little fewer whispers and players reached in fact.)
GF.HAND_FANS = {
    { 45, { 6, 4, 2 } }, { 125, { 8, 6, 4 } }, { 330, { 10, 8, 5 } }, { math.huge, { 12, 10, 6 } },
}
GF.WITHDRAW_FANS = { 4, 3, 2 }   -- passed on only by those who held the listing
GF.WITHDRAW_TRIES = 6         -- a withdrawal short of whispers: the rest 10, 20 ... 50 s later
GF.WITHDRAW_RETRY = 10
GF.FAREWELL_GAP = 1           -- "gone" answers to the waiting sign-ups, one a second after the withdrawal's burst
GF.HAND_INTERVAL = 480        -- the own listing again every 8 min when it changed, 16 when not
GF.HAND_TTL = 1140            -- lifetime sent with it: two intervals and the hands' delay
GF.HAND_TTL_MAX = 1200
GF.HAND_CHANGE_GAP = 120      -- full / open again: told at once, one listing per 120 s at most
GF.HAND_FORWARD_GAP = 120     -- one copy of a leader passed on per 120 s at most
GF.HAND_PER_GATEWAY = 6       -- new rows a minute from one sender
GF.HAND_PER_MIN = 40          -- new rows a minute in all
GF.HAND_INTAKE = 20           -- messages of the hands read a minute from one sender
GF.HAND_RATE = 0.15           -- the bucket: whispers a second, BURST at once (on top of the chain's)
GF.HAND_BURST = 10
GF.HAND_CHAIN_RESERVE = 20    -- nothing while the directory's chain holds fewer tokens
GF.HAND_REFUSED_PAUSE = 30    -- a refused whisper stops the bucket that long
GF.HAND_HOLD = 35             -- the own copy short of whispers: the bucket is kept for it that long
GF.HAND_REV_SKEW = 600        -- a rev older than its life and this is refused
GF.HAND_REV_AHEAD = 10        -- a rev ahead of our clock by more than this is refused (one server clock)
GF.HAND_ROWS_PER_GATEWAY = 8  -- live rows of the board one sender brought at most
GF.REV_MOD = 1000000
GF.CONTACTS_CACHE_SEC = 5
GF.PULL_GAP = 120             -- an empty board asks again after 2 min, a full one after 10
GF.PULL_FRESH = 600
GF.PULL_WAIT = 20             -- answers read that long after the question
GF.PULL_LISTEN = 15           -- the empty board says "listening" that long after it
GF.PULL_ROWS = 8
GF.PULL_PER_MSG = 2
GF.PULL_ROWS_PER_GATEWAY = 24 -- new rows one contact's pull answers bring onto the board at most (three full answers)
GF.PULL_MSGS = 4
GF.PULL_BYTES = 160
-- Players kept out of the member list (ghosts) also get a copy, at every hand (2.3.0), in what the
-- contacts leave of the bucket (HAND_BURST): none with a fan of 10 or more (the leader's own
-- above 125 listed, the second hand above 330).
GF.LEAF_COPIES = 1
GF.PULL_ANSWER_GAP = 60       -- one answer per asker a minute, PULL_ANSWERS_PER_MIN in all
GF.PULL_ANSWERS_PER_MIN = 6

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

-- Small bounded books of the hands: rows = { [key] = { at = time, ... } }, forgotten
-- after `life`; at its cap a book drops what is past, and everything if that frees nothing.
local function NewBook(cap, life) return { rows = {}, count = 0, cap = cap, life = life } end
GF.books = GF.books or {
    seen = NewBook(512, GF.HAND_TTL_MAX),       -- [leader|rev]: copies already read
    withdrawn = NewBook(128, GF.HAND_TTL_MAX),  -- [leader] = { rev }: withdrawals heard
    forwarded = NewBook(128, GF.HAND_FORWARD_GAP), -- [leader]: last copy passed on
    intake = NewBook(64, 60),                   -- [sender] = { count }: messages read this minute
    gateway = NewBook(64, 60),                  -- [sender] = { count }: new rows this minute
    answered = NewBook(64, GF.PULL_ANSWER_GAP), -- [asker]: last answer
}
GF.handStats = GF.handStats or { own = 0, forwarded = 0, whispers = 0, stranger = 0, capped = 0,
    pulls = 0, answers = 0, pulledRows = 0, withdrawn = 0, refused = 0 }

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

-- Decimal field of at most `digits` digits (three by default) within [lo, hi], else nil.
local function Int(text, lo, hi, digits)
    if type(text) ~= "string" or #text == 0 or #text > (digits or 3) or text:find("%D") then return nil end
    local n = tonumber(text)
    if not n or n < lo or n > hi then return nil end
    return n
end

-- Rev a is newer than rev b (both mod REV_MOD, half the circle ahead).
local function RevNewer(a, b)
    local d = (a - b) % GF.REV_MOD
    return d > 0 and d < GF.REV_MOD / 2
end
GF.RevNewer = RevNewer

local function BookGet(book, key, now)
    local row = book.rows[key]
    if row and now - row.at < book.life then return row end
    return nil
end

local function BookPut(book, key, row, now)
    row.at = row.at or now
    if not book.rows[key] then
        if book.count >= book.cap then
            for other, old in pairs(book.rows) do
                if now - old.at >= book.life then
                    book.rows[other] = nil
                    book.count = book.count - 1
                end
            end
            if book.count >= book.cap then
                -- (The oldest gives way: a whole wipe let a flood erase real withdrawals.)
                local oldestKey, oldestAt = nil, math.huge
                for other, old in pairs(book.rows) do
                    if old.at < oldestAt then oldestKey, oldestAt = other, old.at end
                end
                if oldestKey then
                    book.rows[oldestKey] = nil
                    book.count = book.count - 1
                end
            end
        end
        book.count = book.count + 1
    end
    book.rows[key] = row
    return row
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

-- Every send goes through Sync's checked send (under our prefix): a refusal is counted
-- with the others (/ov network, the channel's refusal watch, the whisper throttle).
function GF:Send(msg, chatType, target)
    local sync = Overlord.Sync
    if not sync or not sync.SendAddonChecked then return false end
    if InInstance() or #msg > 255 then return false end
    local kind = sync._channelSendKind
    if chatType == "CHANNEL" then sync._channelSendKind = "GF" end
    local called, ok = pcall(sync.SendAddonChecked, sync, msg, chatType, target, self.PREFIX)
    if chatType == "CHANNEL" then sync._channelSendKind = kind end
    ok = called and ok == true
    if not ok and chatType == "WHISPER" then
        -- The server's throttle: the hands' bucket stops a while.
        self._handTokens, self._handTokensAt = 0, GetTime()
        self._handStopUntil = GetTime() + self.HAND_REFUSED_PAUSE
        self.handStats.refused = self.handStats.refused + 1
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

-- One message to the guild (relay mode: the leader's own copy and its withdrawal, at the
-- last hand: read by the guild mates online, never passed on).
function GF:SendGuild(msg)
    if InInstance() or not IsInGuild then return false end
    local ok, inGuild = pcall(IsInGuild)
    if not ok or not inGuild then return false end
    return self:Send(msg, "GUILD")
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

-- The listing's fields from the faction on (L and G share them).
function GF:OwnBody(faction, count, raid, ttl)
    local own = self.own
    return string.format("%s:%s:%s:%s:%d:%d:%d:%d:%d:%d:%d", faction,
        own.intent, own.kind, own.target, own.cap, count, own.minLevel,
        (own.auto and 1 or 0) + (raid and 2 or 0), self:PlayerClassIndex(), self:PlayerLevel(), ttl)
end

function GF:TrySend()
    local own = self.own
    if not own or InInstance() then return end
    local faction = self:FactionCode()
    if not faction then return self:ScheduleSend(5) end
    local mode = self:Mode()
    if mode ~= "channel" then return self:TrySpread(own, faction, mode) end
    local now = GetTime()
    local interval = self:HeartbeatInterval()
    local count, raid = self:GroupSize(), self:IsRaid()
    local msg = "L:" .. self.VERSION .. ":" .. self:OwnBody(faction, count, raid, math.floor(interval * 2 + 30))
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

-- What the window says about the way the listings travel: "closed" (the game refuses
-- our join or our messages and nothing else carries them), "connecting" (not inside
-- yet, or no contact yet in relay mode), "listening" (inside for less than a minute and
-- a half: the listings already published have not all been heard yet; in relay mode, a
-- few seconds after asking a contact) or "open". Second value: seconds of listening left.
function GF:ChannelState()
    local mode = self:Mode()
    if mode == "wait" then return "connecting" end
    if mode == "relay" then
        local untilAt, now = self._pullListenUntil, GetTime()
        if untilAt and now < untilAt then return "listening", untilAt - now end
        return "open"
    end
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
    -- (The copies by hand too: after a reload their withdrawal still reaches who holds them.)
    db.own = { intent = own.intent, kind = own.kind, target = own.target, cap = own.cap,
        minLevel = own.minLevel, auto = own.auto, by = self:PlayerName(), at = ServerNow(),
        rev = own.spreadLive and own.rev or nil, heldLast = own.spreadLive and own.heldLast or nil,
        heldPrev = own.spreadLive and own.heldPrev or nil }
end

-- A saved list of holders, checked (the saved variables are only ours, but a bad edit must not
-- break the withdrawal): names only, 16 at most.
local function SavedNames(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, name in ipairs(list) do
        if #out >= 16 then break end
        if type(name) == "string" and name ~= "" then out[#out + 1] = name end
    end
    return out[1] and out or nil
end

-- The copies of a listing saved before a reload: its rev and holders come back with it.
function GF:RestoreSpread(own, saved)
    local rev = tonumber(saved.rev)
    if not own or not rev or rev ~= math.floor(rev) or rev < 0 or rev >= self.REV_MOD then return end
    own.rev, own.spreadLive = rev, true
    own.heldLast, own.heldPrev = SavedNames(saved.heldLast), SavedNames(saved.heldPrev)
    if not self._lastRev or RevNewer(rev, self._lastRev) then self._lastRev = rev end
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
    local old = self.own
    -- 2.2.2: an edit of the size, level or auto keeps the sign-ups waiting (the same leader and
    -- activity). Another activity: those who signed up for the old one are told "gone" (one a
    -- second, see FarewellPending), never invited into it.
    if not old then
        self:ClearPending()
    elseif old.intent ~= spec.intent or old.kind ~= spec.kind or old.target ~= (spec.target or "") then
        self:FarewellPending()
        self:ClearPending()
    end
    -- A listing that went from hand to hand and is replaced: its copies give way to the
    -- new one (a newer rev), nothing to withdraw.
    self.own = { intent = spec.intent, kind = spec.kind, target = spec.target or "", cap = spec.cap,
        minLevel = minLevel, auto = spec.auto == true, activityAt = now,
        seenCount = self:GroupSize(), state = "sending", tries = 0 }
    self.own.info = self:DescribeTarget(spec.kind, self.own.target)
    -- ... until the new copy has left: a withdrawal meanwhile still reaches the old copy's
    -- holders (kept across a replacement and, saved, across a reload).
    if old and old.spreadLive and old.rev then
        self.own.rev, self.own.spreadLive, self.own.heldLast, self.own.heldPrev =
            old.rev, true, old.heldLast, old.heldPrev
    elseif restored then
        self:RestoreSpread(self.own, spec)
    end
    self:SaveOwn()
    self:EnsureTicker()
    self:ScheduleSend(restored and 3 or 0.2)
    self:Touch()
    return true
end

-- The names a spread really whispered (WhisperList goes in order and stops at a refusal).
local function Whispered(picked, leaves, toPicked, toLeaves)
    local a, b = {}, {}
    for i = 1, toPicked do a[i] = picked[i] end
    for i = 1, toLeaves do b[i] = leaves[i] end
    return a, b
end

-- The names of two lists, once each, the names given left out (lowercase); at most cap names.

local function MergeNames(a, b, skipA, skipB, cap)
    local out, seen = {}, {}
    for _, list in ipairs({ a or {}, b or {} }) do
        for _, name in ipairs(list) do
            local lower = name:lower()
            if cap and #out >= cap then break end
            if not seen[lower] and lower ~= skipA and lower ~= skipB then
                seen[lower] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

-- A saved listing not put back: its copies by hand still live a while, their holders are told.
function GF:WithdrawSaved(saved)
    local rev, me = tonumber(saved.rev), self:PlayerName()
    if not rev or rev ~= math.floor(rev) or rev < 0 or rev >= self.REV_MOD or saved.by ~= me then return end
    local age = ServerNow() - (tonumber(saved.at) or 0)
    if age < 0 or age > self.HAND_TTL_MAX then return end
    local held = MergeNames(SavedNames(saved.heldLast), SavedNames(saved.heldPrev))
    if held[1] then self:SpreadWithdraw(rev, 1, held) end
end

-- The sign-ups still waiting when the listing goes (withdrawn, expired, replaced): each
-- player is told "gone" once, FAREWELL_GAP apart, so that his window does not wait for an
-- answer that will never come. One who signed up again meanwhile is left alone.
function GF:FarewellPending()
    local apps = {}
    for i = 1, math.min(#self.pending, self.PENDING_MAX) do apps[i] = self.pending[i] end
    for i, app in ipairs(apps) do
        C_Timer.After(self.FAREWELL_GAP * i, function()
            if InInstance() or GF.pendingByKey[app.key] or GF.outstanding[app.key] then return end
            GF:Reply(app.name, "x", true)
        end)
    end
end

-- The farewell is best effort: a listing dies of its own on every board once its
-- lifetime (sent with it) runs out, which is all an instance or a logout leaves.
function GF:SendTombstone(attempt)
    if self.own or InInstance() or self:Mode() ~= "channel" then return end
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
    self._handHoldUntil = nil
    self:FarewellPending()
    self:ClearPending()
    self:SaveOwn()
    -- 2.3.0: copies by hand and the channel carrying again before the next turn: the channel's
    -- farewell takes them off the boards too (the hands' withdrawal waits for relay mode).
    if (own.live or own.spreadLive) and not InInstance() then self:SendTombstone(1) end
    if own.spreadLive and own.rev and not InInstance() then
        -- Every holder of the last two copies (up to 20: two first hands of HAND_BURST; the bucket
        -- spreads them, see SpreadWithdraw).
        self:SpreadWithdraw(own.rev, 1, MergeNames(own.heldLast, own.heldPrev))
        local me = self:PlayerName()
        if me then self:SendGuild("X:" .. self.VERSION .. ":" .. self.HANDS .. ":" .. me .. ":" .. own.rev) end
    end
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
    if not pcall(securecall, invite, app.raw) then return self:InviteFailed(app) end
    self:Reply(app.name, "i", late)
end

-- The game's invitation raised an error: no invitation left. Its place is free again; a
-- request taken automatically goes back to the list for the leader's click (the player
-- is told to wait), one that failed from the click leaves only the game's /invite.
function GF:InviteFailed(app)
    local key = app.key
    if self.outstanding[key] then self:DropQueuedInvite(key) end
    if not app.manual then
        app.manual = true
        app.at = GetTime()
        if not self.pendingByKey[key] and #self.pending < self.PENDING_MAX then
            self.pending[#self.pending + 1] = app
            self.pendingByKey[key] = app
            self:Reply(app.name, "p", true)
        end
    end
    Notify(string.format(T("GF_CHAT_INVITE_FAILED", "The game refused the invitation. Type: /invite %s"),
        app.name))
    self:Touch()
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
    -- (One below a raised minimum level waits for a click: not queued for the automatic one.)
    local floor = (self.own and self.own.minLevel) or 0
    for _, app in ipairs(self.pending) do
        if IsAutoRequest(app) and (tonumber(app.level) or 0) >= floor then return true end
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
        -- (2.3.0: one who signed up before the leader raised the minimum level waits for a click.)
        if IsAutoRequest(app) and (tonumber(app.level) or 0) >= (own.minLevel or 0) then
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

-- The fields of a listing from the faction on (L, G and B share them), checked: a table
-- of values, or nil when malformed. ttlMax: 999 on the channel, HAND_TTL_MAX by hand.
function GF:ParseBody(fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra, ttlMax)
    cap, count, minLevel = Int(cap, 5, 40), Int(count, 1, 40), Int(minLevel, 0, self.LEVEL_MAX)
    flags, class = Int(flags, 0, 3), Int(class, 0, #self.CLASSES)
    level, ttl = Int(level, 1, self.LEVEL_MAX), Int(ttl, 1, ttlMax, ttlMax > 999 and 4 or 3)
    if extra or not (cap and count and minLevel and flags and class and level and ttl)
        or not self.SIZE_OK[cap] or not self.INTENTS[intent] or not self.KINDS[kind]
        or (fac ~= "A" and fac ~= "H")
        or (kind == "w" and target ~= "") or (kind ~= "w" and not IsPlaceId(target)) then
        return nil
    end
    return { fac = fac, intent = intent, kind = kind, target = target, cap = cap, count = count,
        minLevel = minLevel, flags = flags, class = class, level = level, ttl = ttl }
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
    local p = self:ParseBody(fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra, 999)
    if not p then return self:Strike(key, now) end
    if p.fac ~= self:FactionCode() then return end
    -- A place this version does not know cannot be worded: no row, no blame.
    if not self:IsValidTarget(p.kind, p.target) then return end
    local changed
    entry, changed = self:PutEntry(key, canon, sender, p, now,
        now + math.max(self.TTL_MIN, math.min(self.TTL_MAX, p.ttl)))
    if not entry then return end
    -- Heard on the channel: first-hand, no rev.
    entry.via, entry.rev, entry.hearsay, entry.gateway, entry.xFrom = nil, nil, nil, nil, nil
    entry.handBrought = nil
    entry.firstHand, entry.claim = nil, nil
    if changed then self:Touch() end
end

-- A row of the board for this leader, made or brought up to date. Returns the row (nil
-- when there is no room or the leader is banned) and whether the window must repaint.
function GF:PutEntry(key, canon, raw, p, now, expires, hearsayOnly)
    local entry = self.board[key]
    local changed = false
    local count, cap, kind, target = p.count, p.cap, p.kind, p.target
    if not entry then
        local sync = Overlord.Sync
        if sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(canon) then return nil end
        if self.boardCount >= self.BOARD_MAX then
            self:SweepBoard(now)
            if self.boardCount >= self.BOARD_MAX then
                -- Full board: a group with room takes the row of a full one (never the
                -- one the player signed up to); a full group waits for a free row.
                if count >= cap then return nil end
                local applied, victim = self.apply and self.apply.key, nil
                for otherKey, other in pairs(self.board) do
                    -- (A pull answer may only take the place of another hearsay row.)
                    if other.count >= other.cap and otherKey ~= applied and (not hearsayOnly or other.hearsay) then
                        victim = otherKey
                        break
                    end
                end
                if not victim then return nil end
                self:RemoveEntry(victim)
            end
        end
        entry = { key = key, name = canon }
        self.board[key] = entry
        self.boardCount = self.boardCount + 1
        changed = true
    end
    local intent, minLevel, class, level = p.intent, p.minLevel, p.class, p.level
    local auto, raid = p.flags % 2 == 1, p.flags >= 2
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
    entry.raw = raw
    entry.heardAt = now
    entry.sentAt = now
    entry.ttl = p.ttl
    entry.expires = expires
    self:EnsureTicker()
    return entry, changed
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
    -- The leader himself says the listing we signed up to is gone: that row, if it came by
    -- hand (its withdrawal may have missed us), leaves the board and its copies stay out.
    -- A newer copy that already reached us is the leader's next listing: left alone.
    if status == "gone" and entry and entry.rev and entry.rev == apply.rev then
        BookPut(self.books.withdrawn, apply.key, { rev = entry.rev }, apply.at)
        self:RemoveEntry(apply.key)
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
    -- A listing is read from the channel (L) or by hand (G, B); a sign-up only from a whisper.
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
        elseif tag == 71 then
            self:OnSpreadListing(text, sender)
        elseif tag == 88 then
            self:OnSpreadWithdraw(text, sender)
        elseif tag == 81 then
            self:OnPull(text, sender)
        elseif tag == 66 then
            self:OnBundle(text, sender)
        end
    elseif channel == "GUILD" then
        -- 2.2.2: a guild mate's own listing and its withdrawal (the leader itself only).
        if tag == 71 then
            self:OnSpreadListing(text, sender, true)
        elseif tag == 88 then
            self:OnSpreadWithdraw(text, sender, true)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Hands (relay mode: the channel does not carry, the directory's contacts do)
-- ---------------------------------------------------------------------------

-- "channel": the channel carries (everything above); "relay": it does not and at least
-- one contact is reached; "wait": it does not and no contact yet.
function GF:Mode()
    local dir = Overlord.ChannelDirectory
    if not dir or not dir.IsActive then return "channel" end
    local ok, active = pcall(dir.IsActive, dir)
    if not ok or not active then return "channel" end
    return self:Contacts()[1] and "relay" or "wait"
end

function GF:IsContactName(name)
    local dir = Overlord.ChannelDirectory
    if not dir or not dir.IsContact or type(name) ~= "string" then return false end
    local ok, yes = pcall(dir.IsContact, dir, name)
    return ok and yes == true
end

-- The directory's contacts (players that greeted us, listed, reached directly), names
-- as the directory writes them; looked up again after CONTACTS_CACHE_SEC.
function GF:Contacts()
    local now = GetTime()
    if self._contacts and now - (self._contactsAt or -1e9) < self.CONTACTS_CACHE_SEC then return self._contacts end
    local list, dir = {}, Overlord.ChannelDirectory
    if dir and dir.IsContact then
        local partners = type(dir.partners) == "table" and dir.partners or {}
        local source = partners
        if dir.ContactView then
            local ok, view = pcall(dir.ContactView, dir)
            if ok and type(view) == "table" then source = view end
        end
        local me, seen = (self:PlayerName() or ""):lower(), {}
        for k, v in pairs(source) do
            local name = (type(v) == "string" and v) or (type(v) == "table" and v.name)
                or (type(k) == "string" and k) or nil
            if type(name) == "string" and not (source == partners and type(v) == "table" and not v.chainAt) then
                local lower = name:lower()
                local row = partners[lower]
                if row and type(row.name) == "string" then name = row.name end
                if not seen[lower] and lower ~= me and self:IsContactName(name) then
                    seen[lower] = true
                    list[#list + 1] = name
                end
            end
        end
    end
    self._contacts, self._contactsAt = list, now
    return list
end

-- Contacts whispered at a hand (1: the leader's own copy), by size of the member list.
function GF:FanFor(hand)
    local dir = Overlord.ChannelDirectory
    local size = dir and type(dir.names) == "table" and #dir.names or 0
    local fans = self.HAND_FANS[#self.HAND_FANS][2]
    for _, row in ipairs(self.HAND_FANS) do
        if size < row[1] then
            fans = row[2]
            break
        end
    end
    return fans[math.min(math.max(hand, 1), #fans)]
end

-- Whispers granted out of the hands' bucket: none while it is stopped after a refusal,
-- none while the directory's chain is short (its tokens are the captures'). all: every
-- whisper wanted or none (the leader's own copy): short, the bucket refills for it alone
-- HAND_HOLD seconds (copies and withdrawals of others are not passed on meanwhile: that hop is
-- skipped, others carry them), so that a busy client's forwards cannot starve its own listing.
function GF:TakeHandTokens(wanted, now, all)
    if wanted <= 0 or (self._handStopUntil or 0) > now then return 0 end
    local dir = Overlord.ChannelDirectory
    local chain = dir and dir.chain
    if type(chain) == "table" then
        local tokens = tonumber(chain.tokens) or 0
        if chain.at then
            tokens = math.min(tonumber(dir.CHAIN_BURST) or 30,
                tokens + math.max(0, now - chain.at) * (tonumber(dir.CHAIN_RATE) or 0.75))
        end
        if tokens < self.HAND_CHAIN_RESERVE then
            self.handStats.capped = self.handStats.capped + 1
            return 0
        end
    end
    if not all and (self._handHoldUntil or 0) > now then return 0 end
    local tokens = math.min(self.HAND_BURST,
        (self._handTokens or self.HAND_BURST) + math.max(0, now - (self._handTokensAt or now)) * self.HAND_RATE)
    self._handTokensAt = now
    local granted = math.min(wanted, math.floor(tokens))
    if all then
        if granted < wanted then granted = 0 end
        self._handHoldUntil = granted == 0 and now + self.HAND_HOLD or nil
    end
    self._handTokens = tokens - granted
    if granted < wanted then self.handStats.capped = self.handStats.capped + 1 end
    return granted
end

-- n names of view at random; those in `prefer` (a lowercase set) drawn first.
local function Draw(view, n, prefer, random)
    local groups = { view }
    if prefer then
        local first, rest = {}, {}
        for _, name in ipairs(view) do
            local into = prefer[name:lower()] and first or rest
            into[#into + 1] = name
        end
        groups = { first, rest }
    end
    local out = {}
    for _, group in ipairs(groups) do
        for i = 1, #group do
            if #out >= n then return out end
            local j = i + math.floor(random() * (#group - i + 1))
            if j > #group then j = #group end
            group[i], group[j] = group[j], group[i]
            out[#out + 1] = group[i]
        end
    end
    return out
end

-- Up to n contacts at random, the two names given left out (prefer: drawn first).
function GF:PickContacts(n, skipA, skipB, prefer)
    local view = {}
    for _, name in ipairs(self:Contacts()) do
        local lower = name:lower()
        if lower ~= skipA and lower ~= skipB then view[#view + 1] = name end
    end
    return Draw(view, n, prefer, self.Random)
end

-- Up to n players that greeted us and the member list does not show (SyncDirectory LeafNames), at
-- random, the two names given left out. They hold no contact's place in the hands: a copy they
-- get is theirs alone (what they pass on is a stranger's for the listed clients).
function GF:PickLeaves(n, skipA, skipB, prefer)
    local dir = Overlord.ChannelDirectory
    if n <= 0 or not dir or not dir.LeafNames then return {} end
    local ok, names = pcall(dir.LeafNames, dir)
    if not ok or type(names) ~= "table" then return {} end
    local view = {}
    for _, name in ipairs(names) do
        local lower = name:lower()
        if lower ~= skipA and lower ~= skipB and lower ~= (self:PlayerName() or ""):lower() then view[#view + 1] = name end
    end
    return Draw(view, n, prefer, self.Random)
end

-- The first `granted` names of the list get the message; a refusal stops there.
function GF:WhisperList(names, granted, msg)
    local sent = 0
    for i = 1, math.min(granted, #names) do
        if not self:Whisper(names[i], msg) then break end
        sent = sent + 1
    end
    self.handStats.whispers = self.handStats.whispers + sent
    return sent
end

-- The leader's server time as a rev, always newer than the previous one.
function GF:NextRev()
    local rev = ServerNow() % self.REV_MOD
    local last = self._lastRev
    if last and not RevNewer(rev, last) then rev = (last + 1) % self.REV_MOD end
    self._lastRev = rev
    return rev
end

-- A rev about now: at most HAND_REV_AHEAD ahead of our clock, at most a lifetime and
-- HAND_REV_SKEW behind (a made-up rev far ahead would hide the leader's next copies).
function GF:RevFresh(rev)
    local age = (ServerNow() - rev) % self.REV_MOD
    if age > self.REV_MOD / 2 then age = age - self.REV_MOD end
    return age >= -self.HAND_REV_AHEAD and age <= self.HAND_TTL_MAX + self.HAND_REV_SKEW
end

-- TrySend in relay mode. Without a contact the listing waits ("connecting"); a listing
-- that did not change since its last copy waits for its second turn (its lifetime
-- covers two); full or open again, it goes at once (OnRosterSettled, forceSpread).
function GF:TrySpread(own, faction, mode)
    local now = GetTime()
    if mode == "wait" then
        own.tries = (own.tries or 0) + 1
        if own.state ~= "channel" then
            own.state = "channel"
            self:Touch()
        end
        return self:ScheduleSend(15)
    end
    local count, raid = self:GroupSize(), self:IsRaid()
    local changed = not own.spreadAt or count ~= own.sentCount or raid ~= own.sentRaid
    if not changed and not own.forceSpread and now - own.spreadAt < 2 * self.HAND_INTERVAL - 90 then
        own.tries = 0
        return self:ScheduleSend(self.HAND_INTERVAL * (0.95 + 0.1 * self.Random()))
    end
    if self:SpreadOwn(own, faction, count, raid, now, changed or own.forceSpread) then
        own.tries, own.polls, own.refusals, own.forceSpread = 0, 0, 0, nil
        own.sentAt, own.sentCount, own.sentRaid, own.spreadAt, own.spreadLive = now, count, raid, now, true
        self:SaveOwn()
        if own.state ~= "live" then
            own.state = "live"
            self:Touch()
        end
        return self:ScheduleSend(self.HAND_INTERVAL * (0.95 + 0.1 * self.Random()))
    end
    -- No whisper to spare now: a little later.
    own.tries = (own.tries or 0) + 1
    if own.state ~= "retry" and own.state ~= "live" then
        own.state = "retry"
        self:Touch()
    end
    self:ScheduleSend(20 + 10 * self.Random())
end

function GF:SpreadOwn(own, faction, count, raid, now, changed)
    local me = self:PlayerName()
    if not me then return false end
    -- Every copy goes first to those holding the last ones: theirs came from us, and a copy from one
    -- other hand alone does not replace it (OnSpreadListing). 2.3.0: the unchanged copy too (drawn
    -- afresh, a holder it missed kept the old row until it ran out, then had none for a turn).
    local prefer
    if own.heldLast or own.heldPrev then
        prefer = {}
        for _, name in ipairs(MergeNames(own.heldLast, own.heldPrev)) do prefer[name:lower()] = true end
    end
    local picked = self:PickContacts(self:FanFor(1), nil, nil, prefer)
    -- (Leaves get the last hand: they keep it and never pass it on, their contacts do not list them.)
    local leaves = self:PickLeaves(self.LEAF_COPIES, nil, nil, prefer)
    -- 2.2.2: the whole first hand or nothing (TrySpread looks again 20-30 s later): a copy
    -- that reached a few contacts would stand for the listing until its next turn.
    -- (At most HAND_BURST: a fan of 12 goes to 10 contacts, and the leaf only gets what the
    -- contacts leave, none from a fan of 10.)
    local granted = self:TakeHandTokens(math.min(#picked + #leaves, self.HAND_BURST), now, true)
    if granted == 0 then return false end
    local rev = self:NextRev()
    local body = me .. ":" .. rev .. ":" .. self:OwnBody(faction, count, raid, self.HAND_TTL)
    local toContacts = math.min(granted, #picked)
    local toPicked = self:WhisperList(picked, toContacts, "G:" .. self.VERSION .. ":1:" .. body)
    local toLeaves = 0
    if granted > toContacts then
        toLeaves = self:WhisperList(leaves, granted - toContacts, "G:" .. self.VERSION .. ":" .. self.HANDS .. ":" .. body)
    end
    local sent = toPicked + toLeaves
    if sent == 0 then return false end
    own.rev = rev
    -- Who holds the listing: the last two copies' receivers, told again when it is withdrawn.
    own.heldPrev, own.heldLast = own.heldLast, MergeNames(Whispered(picked, leaves, toPicked, toLeaves))
    -- The guild mates online get the leader's copy too, at the last hand (never passed on).
    self:SendGuild("G:" .. self.VERSION .. ":" .. self.HANDS .. ":" .. body)
    self.handStats.own = self.handStats.own + 1
    -- (spreadLive is set by TrySpread right after: the copies are saved from there.)
    return true
end


-- Unpublish in relay mode: a few contacts are told, and those who held it tell a few.
-- (A newer listing published meanwhile is not touched: a withdrawal only takes copies up to
-- its own rev, see OnSpreadWithdraw.)
function GF:SpreadWithdraw(rev, attempt, held)
    if InInstance() then return end
    local me = self:PlayerName()
    if not me then return end
    -- 2.2.2: the players that hold the listing are told (the receivers of its last copies), not
    -- contacts drawn at random: most of those never had it. Holders known: the directory being
    -- on is enough (no contact needed to whisper them, after a reload too).
    local picked = held and #held > 0 and held or nil
    local mode = self:Mode()
    if mode == "channel" or (not picked and mode ~= "relay") then
        if attempt < self.WITHDRAW_TRIES then
            C_Timer.After(self.WITHDRAW_RETRY * attempt, function() GF:SpreadWithdraw(rev, attempt + 1, held) end)
        end
        return
    end
    if not picked then
        picked = self:PickContacts(self.WITHDRAW_FANS[1])
        for _, name in ipairs(self:PickLeaves(self.LEAF_COPIES)) do picked[#picked + 1] = name end
    end
    local granted = self:TakeHandTokens(#picked, GetTime())
    local sent = granted > 0 and self:WhisperList(picked, granted, "X:" .. self.VERSION .. ":1:" .. me .. ":" .. rev) or 0
    -- Short of whispers (the bucket, a refusal): the others later. 2.3.0: a try that told some of
    -- them is not one of the WITHDRAW_TRIES (the bucket gives one whisper per ~7 s: 20 holders
    -- could outlast six tries, the last ones kept the row until it expired); only tries that told
    -- nobody are counted. Bounded: each uncounted try tells one more holder at least.
    if sent < #picked and (sent > 0 or attempt < self.WITHDRAW_TRIES) then
        local rest, nextTry = {}, sent > 0 and attempt or attempt + 1
        for i = sent + 1, #picked do rest[#rest + 1] = picked[i] end
        C_Timer.After(self.WITHDRAW_RETRY * attempt, function() GF:SpreadWithdraw(rev, nextTry, rest) end)
    end
end

-- Messages of the hands read per sender and per minute.
function GF:TakeIntake(key, now)
    local books = self.books
    local row = BookGet(books.intake, key, now) or BookPut(books.intake, key, { count = 0, at = now }, now)
    if row.count >= self.HAND_INTAKE then return false end
    row.count = row.count + 1
    return true
end

-- A new row on the board by hand: PER_GATEWAY a minute per sender, PER_MIN in all.
function GF:TakeNewRow(gatewayKey, now)
    local minute = self._newRowsMinute
    if not minute or now - minute.at >= 60 then
        minute = { at = now, count = 0 }
        self._newRowsMinute = minute
    end
    local books = self.books
    local row = BookGet(books.gateway, gatewayKey, now)
        or BookPut(books.gateway, gatewayKey, { count = 0, at = now }, now)
    if minute.count >= self.HAND_PER_MIN or row.count >= self.HAND_PER_GATEWAY then
        self.handStats.capped = self.handStats.capped + 1
        return false
    end
    minute.count, row.count = minute.count + 1, row.count + 1
    return true
end

-- The sender of a message of the hands: a contact, or the leader itself first-hand.
-- Returns key, canon of the sender and of the leader, or nil.
function GF:HandSources(sender, leader, now)
    local key, canon = self:SenderKey(sender)
    if not key or self:IsStruck(key, now) or not self:TakeIntake(key, now) then return nil end
    local sync0 = Overlord.Sync
    if sync0 and sync0.IsDeniedKillContributor and sync0:IsDeniedKillContributor(canon) then return nil end
    local leaderKey, leaderCanon = self:SenderKey(leader)
    if not leaderKey then
        self:Strike(key, now)
        return nil
    end
    if leaderKey ~= key and not self:IsContactName(canon) then
        self.handStats.stranger = self.handStats.stranger + 1
        return nil
    end
    -- Our own listing, back from another hand.
    local sync = Overlord.Sync
    if sync.IsSenderLocalPlayer and sync:IsSenderLocalPlayer(leaderCanon) then return nil end
    return key, canon, leaderKey, leaderCanon
end

-- Live rows of the board a sender brought (by hand or in a pull answer).
function GF:GatewayRows(key)
    local count = 0
    for _, entry in pairs(self.board) do
        if entry.gateway == key then count = count + 1 end
    end
    return count
end

-- "G": a listing by hand. Read once per copy (leader|rev), a newer copy only; passed on
-- while hands are left, once per copy and one copy of a leader per HAND_FORWARD_GAP.
function GF:OnSpreadListing(text, sender, viaGuild)
    local now = GetTime()
    local _, ver, hand, leader, rev, fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra =
        strsplit(":", text, 17)
    if ver ~= self.VERSION then return end
    local key, _, leaderKey, leaderCanon = self:HandSources(sender, leader, now)
    if not key then return end
    local handN = hand and #hand == 1 and Int(hand, 1, self.HANDS) or nil
    rev = Int(rev, 0, self.REV_MOD - 1, 6)
    local p = self:ParseBody(fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra,
        self.HAND_TTL_MAX)
    if not (handN and rev and p) then return self:Strike(key, now) end
    -- The first hand is the leader's own copy: from anybody else it is made up.
    if handN == 1 and key ~= leaderKey then return self:Strike(key, now) end
    -- On the guild: the leader's own copy at the last hand only.
    if viaGuild and (key ~= leaderKey or handN ~= self.HANDS) then return end
    if p.fac ~= self:FactionCode() or not self:IsValidTarget(p.kind, p.target) or not self:RevFresh(rev) then return end
    local books = self.books
    local seenKey = leaderKey .. "|" .. rev
    if BookGet(books.seen, seenKey, now) then return end
    local gone = BookGet(books.withdrawn, leaderKey, now)
    if gone and not RevNewer(rev, gone.rev) then return end
    local entry = self.board[leaderKey]
    -- An older copy, or the same: nothing new (a row only heard of in a pull is now heard; one
    -- heard on the guild is now passed on).
    if entry and entry.rev and not RevNewer(rev, entry.rev)
        and not ((entry.hearsay or (entry.guild and not viaGuild)) and rev == entry.rev) then
        return
    end
    if not entry and (self:GatewayRows(key) >= self.HAND_ROWS_PER_GATEWAY or not self:TakeNewRow(key, now)) then
        self.handStats.capped = self.handStats.capped + 1
        return
    end
    -- A row the leader gave us itself is replaced by somebody else's copy only once a second
    -- hand brings the same copy (one client could otherwise rewrite, then withdraw, any group).
    if entry and entry.firstHand and key ~= leaderKey then
        local claim = entry.claim
        if not (claim and claim.rev == rev and claim.from ~= key) then
            entry.claim = { rev = rev, from = key }
            self.handStats.held = (self.handStats.held or 0) + 1
            return
        end
    end
    -- (Seen only once taken: a copy refused by the caps may still come by another hand. Not a
    -- guild copy: the same copy by whisper is still passed on.)
    if not viaGuild then BookPut(books.seen, seenKey, { at = now }, now) end
    -- (A row new to us, or only heard of in a pull: this hand is the one its withdrawal is
    -- believed from. A newer copy by another hand changes the row, not who may withdraw it.)
    -- (A pull with a newer rev over a row a hand brought keeps that hand's right.)
    local firstBringer = not entry or not entry.handBrought
    local changed
    entry, changed = self:PutEntry(leaderKey, leaderCanon, leaderCanon, p, now, now + math.max(self.TTL_MIN, p.ttl))
    if not entry then return end
    entry.via, entry.rev, entry.hearsay, entry.gateway, entry.guild = "hand", rev, nil, key, viaGuild or nil
    entry.firstHand, entry.claim = key == leaderKey or nil, nil
    if key == leaderKey then entry.xFrom = nil elseif firstBringer then entry.xFrom = key end
    entry.handBrought = true
    if changed then self:Touch() end
    if handN < self.HANDS and self:Mode() == "relay" then self:ForwardSpread(text, handN, key, leaderKey, now) end
end

function GF:ForwardSpread(text, hand, gatewayKey, leaderKey, now)
    local books = self.books
    if BookGet(books.forwarded, leaderKey, now) then return end
    local picked = self:PickContacts(self:FanFor(hand + 1), gatewayKey, leaderKey)
    -- (2.3.0: a leaf at every hand. From the first two only, the players out of the member list (about
    -- a third, no contact's place in the hands) got ~9 copies for ~25 of them: 64/83 boards.)
    local leaves = self:PickLeaves(self.LEAF_COPIES, gatewayKey, leaderKey)
    local granted = self:TakeHandTokens(#picked + #leaves, now)
    if granted == 0 then return end
    BookPut(books.forwarded, leaderKey, { at = now }, now)
    local head = "G:" .. self.VERSION .. ":"
    local rest = text:sub(#head + 2)
    local toContacts = math.min(granted, #picked)
    local toPicked = self:WhisperList(picked, toContacts, head .. (hand + 1) .. rest)
    local toLeaves = 0
    -- (Leaves get the last hand: kept, never passed on.)
    if granted > toContacts then toLeaves = self:WhisperList(leaves, granted - toContacts, head .. self.HANDS .. rest) end
    local sent = toPicked + toLeaves
    if sent > 0 then
        self.handStats.forwarded = self.handStats.forwarded + 1
        -- Who holds it after us, for its withdrawal (the last two copies' receivers).
        local held = self.board[leaderKey]
        if held then held.passedPrev, held.passedTo = held.passedTo, MergeNames(Whispered(picked, leaves, toPicked, toLeaves)) end
    end
end

-- "X": a listing withdrawn. Its copies up to that rev stay out; passed on only by those
-- who held it (the others' contacts mostly never had it from them).
function GF:OnSpreadWithdraw(text, sender, viaGuild)
    local now = GetTime()
    local _, ver, hand, leader, rev, extra = strsplit(":", text, 6)
    if ver ~= self.VERSION then return end
    local key, _, leaderKey = self:HandSources(sender, leader, now)
    if not key then return end
    local handN = hand and #hand == 1 and Int(hand, 1, self.HANDS) or nil
    rev = Int(rev, 0, self.REV_MOD - 1, 6)
    if extra or not handN or not rev then return self:Strike(key, now) end
    if viaGuild and (key ~= leaderKey or handN ~= self.HANDS) then return end
    if not self:RevFresh(rev) then return end
    local books = self.books
    local entry = self.board[leaderKey]
    -- Believed from the leader itself, or from the hand that brought us its listing: anybody
    -- else could hide any group from the whole network.
    -- (A row the leader gave us itself is withdrawn by the leader only: it whispers its holders.
    -- 2.3.0: the hand that first brought the row, not the last one that sent a newer copy: that
    -- one could rewrite a rev and then withdraw any group.)
    if key ~= leaderKey and not (entry and entry.xFrom == key and not entry.firstHand) then return end
    local gone = BookGet(books.withdrawn, leaderKey, now)
    if gone and not RevNewer(rev, gone.rev) then return end
    BookPut(books.withdrawn, leaderKey, { rev = rev, at = now }, now)
    -- A row of the channel, or a newer listing of the same leader: kept.
    if not entry or not entry.rev or RevNewer(entry.rev, rev) then return end
    -- (2.3.0: the cap covers what we really passed the copy to, contacts then the leaf: 2 x
    -- WITHDRAW_FANS cut the leaf, last in passedTo, which kept a withdrawn listing for its lifetime.)
    local passed = MergeNames(entry.passedTo, entry.passedPrev, key, leaderKey,
        2 * (self:FanFor(handN + 1) + self.LEAF_COPIES))
    self:RemoveEntry(leaderKey)
    self.handStats.withdrawn = self.handStats.withdrawn + 1
    self:Touch()
    if handN < self.HANDS and self:Mode() == "relay" then
        -- The players we passed it to (they hold it). Nobody: nothing to pass on (a contact drawn
        -- at random would refuse it: we did not bring it the listing).
        local granted = #passed > 0 and self:TakeHandTokens(#passed, now) or 0
        local head = "X:" .. self.VERSION .. ":"
        if granted > 0 then self:WhisperList(passed, granted, head .. (handN + 1) .. text:sub(#head + 2)) end
    end
end

-- The window opens in relay mode: one contact is asked for the best listings it holds.
-- An empty board asks again after PULL_GAP, one with rows after PULL_FRESH.
function GF:MaybePull()
    if InInstance() or self:Mode() ~= "relay" then return false end
    local now = GetTime()
    local last = self._pullAt
    if last and (now - last < self.PULL_GAP or (self.boardCount > 0 and now - last < self.PULL_FRESH)) then
        return false
    end
    local picked = self:PickContacts(1)
    if not picked[1] or self:TakeHandTokens(1, now) == 0 then return false end
    self._pullAt = now
    if not self:Whisper(picked[1], "Q:" .. self.VERSION) then return false end
    self._pull = { key = picked[1]:lower(), at = now, msgs = 0 }
    self._pullListenUntil = now + self.PULL_LISTEN
    self.handStats.pulls = self.handStats.pulls + 1
    return true
end

-- One listing of a pull answer: leader:rev:age:fields.
function GF:BundleItem(name, rev, age, body)
    return name .. ":" .. rev .. ":" .. math.max(0, math.floor(age)) .. ":" .. body
end

function GF.CompareForPull(a, b)
    if a.open ~= b.open then return a.open end
    return a.sentAt > b.sentAt
end

-- "Q": a contact asks for our best listings (our own first, then those with room, the
-- newest first). Answered once a minute per contact, PULL_ANSWERS_PER_MIN in all, only
-- with a live listing in hand; PULL_ROWS rows at most, two per whisper.
function GF:OnPull(text, sender)
    if text ~= "Q:" .. self.VERSION or self:Mode() ~= "relay" then return end
    local key, canon = self:SenderKey(sender)
    local now = GetTime()
    if not key or self:IsStruck(key, now) then return end
    -- (A player the member list does not show asks too: its window is as good as any.)
    if not self:IsContactName(canon) then
        local dir = Overlord.ChannelDirectory
        local okLeaf, leaf = pcall(function() return dir and dir.IsLeaf and dir:IsLeaf(canon) end)
        if not (okLeaf and leaf) then return end
    end
    local books = self.books
    if BookGet(books.answered, key, now) then return end
    local minute = self._answersMinute
    if not minute or now - minute.at >= 60 then
        minute = { at = now, count = 0 }
        self._answersMinute = minute
    end
    if minute.count >= self.PULL_ANSWERS_PER_MIN then return end
    local faction = self:FactionCode()
    if not faction then return end
    local rows = {}
    for leaderKey, entry in pairs(self.board) do
        local age = now - (entry.sentAt or now)
        -- (Rows heard in a pull answer are never served again: their withdrawal may have missed us.)
        if entry.rev and not entry.hearsay and leaderKey ~= key and entry.expires > now
            and age < (entry.ttl or 0) - 30 then
            rows[#rows + 1] = { open = entry.count < entry.cap, sentAt = entry.sentAt,
                text = self:BundleItem(entry.name, entry.rev, age, string.format("%s:%s:%s:%s:%d:%d:%d:%d:%d:%d:%d",
                    faction, entry.intent, entry.kind, entry.target, entry.cap, entry.count, entry.minLevel,
                    (entry.auto and 1 or 0) + (entry.raid and 2 or 0), entry.class, entry.level, entry.ttl)) }
        end
    end
    table.sort(rows, GF.CompareForPull)
    local own, me = self.own, self:PlayerName()
    if own and own.spreadLive and own.rev and me and now - (own.spreadAt or -1e9) < self.HAND_TTL - 30 then
        table.insert(rows, 1, { text = self:BundleItem(me, own.rev, now - own.spreadAt,
            self:OwnBody(faction, own.sentCount, own.sentRaid, self.HAND_TTL)) })
    end
    if not rows[1] then return end
    BookPut(books.answered, key, { at = now }, now)
    minute.count = minute.count + 1
    local head = "B:" .. self.VERSION .. ":"
    local messages, current, inCurrent = {}, nil, 0
    for i = 1, math.min(#rows, self.PULL_ROWS) do
        local item = rows[i].text
        if current and inCurrent < self.PULL_PER_MSG and #current + 1 + #item <= self.PULL_BYTES then
            current, inCurrent = current .. "|" .. item, inCurrent + 1
        else
            if current then messages[#messages + 1] = current end
            if #messages >= self.PULL_MSGS then
                current = nil
                break
            end
            current, inCurrent = head .. item, 1
        end
    end
    if current and #messages < self.PULL_MSGS then messages[#messages + 1] = current end
    local granted = self:TakeHandTokens(#messages, now)
    for i = 1, granted do
        if not self:Whisper(canon, messages[i], true) then break end
        self.handStats.whispers = self.handStats.whispers + 1
    end
    self.handStats.answers = self.handStats.answers + 1
end

-- "B": the answer to our own question, from the contact asked, PULL_MSGS messages at
-- most within PULL_WAIT. Its rows are hearsay: shown, never passed on; they die when the
-- leader's copy would (ttl - age), and a newer copy or a withdrawal takes them over.
function GF:OnBundle(text, sender)
    local pull = self._pull
    local now = GetTime()
    local key, canon = self:SenderKey(sender)
    if not pull or not key or pull.key ~= key or now - pull.at > self.PULL_WAIT or pull.msgs >= self.PULL_MSGS then
        return
    end
    if not self:IsContactName(canon) then return end
    pull.msgs = pull.msgs + 1
    local head = "B:" .. self.VERSION .. ":"
    if text:sub(1, #head) ~= head then return end
    local faction, books, sync = self:FactionCode(), self.books, Overlord.Sync
    local items, changedAny = 0, false
    -- Rows this contact already brought (hand copies and earlier answers): a made-up board is
    -- bounded across answers, a real one (PULL_ROWS an answer) fits several times over.
    local held = self:GatewayRows(key)
    for item in (text:sub(#head + 1) .. "|"):gmatch("([^|]*)|") do
        items = items + 1
        if items > self.PULL_PER_MSG then break end
        local leader, rev, age, fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra =
            strsplit(":", item, 15)
        local leaderKey, leaderCanon = self:SenderKey(leader)
        -- (An age past the lifetime is an old row, skipped below: no blame for an honest contact.)
        rev, age = Int(rev, 0, self.REV_MOD - 1, 6), Int(age, 0, 9999, 4)
        local p = self:ParseBody(fac, intent, kind, target, cap, count, minLevel, flags, class, level, ttl, extra,
            self.HAND_TTL_MAX)
        if not (leaderKey and rev and age and p) then return self:Strike(key, now) end
        local gone = BookGet(books.withdrawn, leaderKey, now)
        local entry = self.board[leaderKey]
        if age < p.ttl and p.fac == faction and self:IsValidTarget(p.kind, p.target) and self:RevFresh(rev)
            and not (sync.IsSenderLocalPlayer and sync:IsSenderLocalPlayer(leaderCanon))
            and not (gone and not RevNewer(rev, gone.rev))
            and not (entry and (not entry.rev or not RevNewer(rev, entry.rev)))
            and not (entry and entry.firstHand and leaderKey ~= key) then
            local sentAt = now - age
            local changed
            local isNew = not entry
            -- (The contact's own listing is one row, outside the cap.)
            if isNew and leaderKey ~= key and held >= self.PULL_ROWS_PER_GATEWAY then
                self.handStats.capped = self.handStats.capped + 1
                entry = nil
            else
                entry, changed = self:PutEntry(leaderKey, leaderCanon, leaderCanon, p, now,
                    sentAt + math.max(self.TTL_MIN, p.ttl), true)
            end
            if entry then
                if isNew and leaderKey ~= key then held = held + 1 end
                entry.via, entry.rev, entry.hearsay, entry.sentAt, entry.gateway = "pull", rev, true, sentAt, key
                entry.firstHand, entry.claim = leaderKey == key or nil, nil
                if leaderKey == key then entry.xFrom = nil elseif isNew then entry.xFrom = key end
                self.handStats.pulledRows = self.handStats.pulledRows + 1
                changedAny = changedAny or changed
            end
        end
    end
    if changedAny then self:Touch() end
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
    local apply = { key = key, name = entry.name, at = GetTime(), sentAt = GetTime(), status = "sent", rev = entry.rev }
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
        local mode = self:Mode()
        if mode == "relay" and own.spreadLive then
            -- By hand a new head count waits for the next turn; full or open again is told
            -- at once, HAND_CHANGE_GAP after the previous copy at the earliest.
            if (count >= own.cap) ~= ((own.sentCount or 0) >= own.cap) and (own.tries or 0) == 0 then
                own.forceSpread = true
                local due = math.max(1, (own.spreadAt or 0) + self.HAND_CHANGE_GAP - now)
                if not own.nextSendAt or own.nextSendAt - now > due then self:ScheduleSend(due) end
            end
        elseif mode == "channel" and own.live and (count ~= own.sentCount or raid ~= own.sentRaid) then
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
    -- The age is judged at the first look that reads the name: later looks only wait for
    -- the search to be reachable.
    if not self._restoreTries then
        local age = ServerNow() - (tonumber(saved.at) or 0)
        if saved.by ~= name or age < 0 or age > self.RELOAD_RESTORE_SEC then
            db.own = nil
            -- (Its copies by hand may still live: their holders are told.)
            self:WithdrawSaved(saved)
            return
        end
        self._restoreTries = 0
    end
    local ok, err = self:Publish(saved, true)
    if ok then return end
    -- Refused for now (the search not reachable yet, the player not readable): the saved
    -- listing stays and is tried again, RESTORE_TRIES times 10 s apart.
    if (err == "GF_LIVE_CLOSED" or err == "GF_ERR_NOT_READY") and self._restoreTries < self.RESTORE_TRIES then
        self._restoreTries = self._restoreTries + 1
        C_Timer.After(10, function() GF:RestoreAfterReload(attempt) end)
        return
    end
    db.own = nil
    self:WithdrawSaved(saved)
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
    self._pull, self._pullListenUntil, self._contacts = nil, nil, nil
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
        -- (A bad packet never stops the board; the error is kept for /ov network.)
        local ok, err = pcall(self.OnAddonMessage, self, text, channel, sender)
        if not ok then
            self.messageErrors = (self.messageErrors or 0) + 1
            self.lastMessageError = tostring(err)
        end
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
