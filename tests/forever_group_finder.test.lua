-- PvP group finder, real GroupFinder.lua, several clients on one bus (one environment
-- per client, one shared clock). Covers the protocol, the cadence and its cost, the
-- sign-up paths, the abuse guards, the instance cut-off, the texts of the 7 languages
-- and the wiring into the rest of the addon.

local now, timers, timerSeq, bus, log, clients

local function reset()
    now, timers, timerSeq, bus, log, clients = 1000, {}, 0, {}, {}, {}
end
reset()

local function addTimer(delay, fn, period)
    timerSeq = timerSeq + 1
    local timer = { at = now + delay, fn = fn, period = period, id = timerSeq }
    timers[#timers + 1] = timer
    return timer
end

local function fire(client, event, ...)
    local frame = client.GF.frame
    if frame and frame.events[event] and frame.handler then frame.handler(frame, event, ...) end
end

-- Channel: every other client hears it. Whisper: the named client only.
local function deliver()
    local guard = 0
    while bus[1] do
        guard = guard + 1
        assert(guard < 5000, "message storm on the bus")
        local msg = table.remove(bus, 1)
        for _, client in ipairs(clients) do
            if client ~= msg.from and client.prefix == msg.prefix then
                if msg.chatType == "CHANNEL"
                    or (msg.chatType == "WHISPER" and client.name:lower() == tostring(msg.target):lower()) then
                    fire(client, "CHAT_MSG_ADDON", msg.prefix, msg.text, msg.chatType, msg.from.rawName)
                end
            end
        end
    end
end

local function advance(seconds)
    local target = now + seconds
    while true do
        local best
        for _, timer in ipairs(timers) do
            if not timer.cancelled and timer.at <= target
                and (not best or timer.at < best.at or (timer.at == best.at and timer.id < best.id)) then
                best = timer
            end
        end
        if not best then break end
        now = math.max(now, best.at)
        if best.period then
            best.at = best.at + best.period
        else
            best.cancelled = true
        end
        best.fn()
        deliver()
    end
    now = target
    local kept = {}
    for _, timer in ipairs(timers) do
        if not timer.cancelled then kept[#kept + 1] = timer end
    end
    timers = kept
end

local zones = {
    stromgarde = { id = "stromgarde", name = "Stromgarde" },
    ash_outpost_east = { id = "ash_outpost_east", name = "East Post" },
}
local fronts = {
    Order = { "arathi", "ashenvale" },
    Registry = {
        arathi = { id = "arathi", mapName = "Arathi Highlands", dropdownLabel = "Arathi",
            preferredMapID = 1417, zones = { zones.stromgarde } },
        ashenvale = { id = "ashenvale", mapName = "Ashenvale", dropdownLabel = "Ashenvale",
            preferredMapID = 1440, zones = { zones.ash_outpost_east } },
    },
}
function fronts:GetZone(id)
    if id == "stromgarde" then return zones.stromgarde, self.Registry.arathi end
    if id == "ash_outpost_east" then return zones.ash_outpost_east, self.Registry.ashenvale end
    return nil
end
function fronts:IsKnownZoneId(id) return self:GetZone(id) ~= nil end
local sites = { stonetalon = { siteKey = "stonetalon", isFortress = true, mapID = 1442 } }
local outposts = {
    GetSite = function(_, key) return sites[key] end,
    GetDisplayName = function(_, site) return "Keep of " .. site.siteKey end,
}

local function canonical(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("%-.*$", "")
    if name:match("^%a+ %a+$") then return name end
    return nil
end

local function newClient(name, faction, opts)
    opts = opts or {}
    local client = {
        name = name, rawName = opts.rawName or name, faction = faction, level = opts.level or 60,
        group = { size = 0, raid = false, leader = false, members = {} },
        channelId = 5, token = true, invites = {}, printed = {}, frames = {}, remembered = {},
        tokensTaken = 0, kinds = {}, banned = {}, db = opts.db or {},
    }
    local env = setmetatable({}, { __index = _G })
    env.GetTime = function() return now end
    env.GetServerTime = function() return 1700000000 + math.floor(now) end
    env.time = env.GetServerTime
    env.IsInInstance = function() return client.inInstance and true or false end
    env.IsInGroup = function() return client.group.size > 0 end
    env.IsInRaid = function() return client.group.size > 0 and client.group.raid end
    env.UnitIsGroupLeader = function() return client.group.size > 0 and client.group.leader end
    env.GetNumGroupMembers = function() return client.group.size end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.UnitIsAFK = function() return client.afk and true or false end
    env.securecall = function(fn, ...) return fn(...) end
    -- client.secret: every value the game hands over is protected (not to be read).
    env.canaccessvalue = function() return not client.secret end
    env.C_Timer = {
        After = function(delay, fn) addTimer(delay, fn) end,
        NewTimer = function(delay, fn)
            local timer = addTimer(delay, fn)
            return { Cancel = function() timer.cancelled = true end }
        end,
        NewTicker = function(period, fn)
            local timer = addTimer(period, fn, period)
            return { Cancel = function() timer.cancelled = true end }
        end,
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix) client.prefix = prefix end,
        SendAddonMessage = function(prefix, text, chatType, target)
            local entry = { from = client, prefix = prefix, text = text, chatType = chatType,
                target = target, at = now, refused = client.sendResult ~= nil }
            log[#log + 1] = entry
            if client.sendResult ~= nil then return client.sendResult end
            bus[#bus + 1] = entry
            return 0
        end,
    }
    env.C_PartyInfo = {
        -- The game's invitation reaches the named client, unless this client's
        -- invitations are dropped without a word (invitesDropped).
        InviteUnit = function(target)
            client.invites[#client.invites + 1] = target
            if client.invitesDropped then return end
            for _, other in ipairs(clients) do
                if other.name == canonical(target) then fire(other, "PARTY_INVITE_REQUEST", client.name) end
            end
        end,
        ConvertToRaid = function() client.group.raid = true end,
    }
    env.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:UnregisterEvent(event) self.events[event] = nil end
        function frame:UnregisterAllEvents() self.events = {} end
        function frame:SetScript(_, fn) self.handler = fn end
        client.frames[#client.frames + 1] = frame
        return frame
    end
    env.OverlordDB = client.db
    env.Overlord = {
        PlayerFaction = faction, InstanceSuspended = false, L = {},
        PrintNotification = function(_, text) client.printed[#client.printed + 1] = text end,
        SafeUnitLevel = function() return client.level end,
        GetPlayerContinent = function() return client.continent end,
        GetMapContinent = function(_, mapID) return mapID == 1440 and "K" or "EK" end,
        Fronts = fronts, Outpost = outposts, OutpostSites = sites,
        Sync = {
            CHANNEL_KILL_INTERVAL = 30,
            GetPlayerFullName = function() return client.nameUnknown and "" or client.name end,
            CanonicalForeverName = function(_, n) return canonical(n) end,
            IsSenderLocalPlayer = function(_, sender) return canonical(sender) == client.name end,
            IsValidWhisperTarget = function(_, target) return canonical(target) ~= nil end,
            _RememberRecentAddonWhisper = function(_, target) client.remembered[#client.remembered + 1] = target end,
            GetChannelId = function() return client.channelId end,
            IsChannelClosed = function() return client.channelClosed == true and not client.channelId end,
            TakeChannelToken = function(_, critical)
                assert(critical == false, "a listing must never take a critical channel token")
                if not client.token then return false end
                client.tokensTaken = client.tokensTaken + 1
                return true
            end,
            NoteChannelSendKind = function(_, kind) client.kinds[kind] = (client.kinds[kind] or 0) + 1 end,
            IsDeniedKillContributor = function(_, n) return client.banned[n] == true end,
            SenderIsInOurGroup = function(_, sender)
                local key = canonical(sender)
                return key ~= nil and client.group.members[key:lower()] == true
            end,
        },
    }
    client.env = env
    local chunk = assert(loadfile("GroupFinder.lua"))
    setfenv(chunk, env)
    chunk()
    client.GF = env.Overlord.GroupFinder
    client.GF.Random = function() return 0.5 end
    -- The module boots itself on PLAYER_LOGIN.
    local boot = client.frames[1]
    assert(boot and boot.events.PLAYER_LOGIN, "the module must wait for PLAYER_LOGIN")
    boot.handler(boot, "PLAYER_LOGIN")
    assert(client.GF.frame and client.prefix == "OverlordGF", "prefix or event frame missing")
    clients[#clients + 1] = client
    return client
end

local function join(leader, member)
    local group = leader.group
    if group.size == 0 then group.size = 1 end
    group.size = group.size + 1
    group.leader = true
    group.members[member.name:lower()] = true
    member.group = { size = group.size, raid = group.raid, leader = false, members = {} }
    fire(leader, "GROUP_ROSTER_UPDATE")
    fire(member, "GROUP_ROSTER_UPDATE")
end

local function sentBy(client, chatType, pattern)
    local list = {}
    for _, entry in ipairs(log) do
        if entry.from == client and (not chatType or entry.chatType == chatType)
            and (not pattern or entry.text:find(pattern)) then
            list[#list + 1] = entry
        end
    end
    return list
end

local function spec(over)
    local s = { intent = "a", kind = "z", target = "stromgarde", cap = 40, minLevel = 0, auto = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

local function key(client) return client.name:lower() end

-- ---------------------------------------------------------------------------
-- 1. A listing reaches the faction, and nobody answers it
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    local carl = newClient("Carl Reed", "Alliance", { rawName = "Carl Reed-Forever" })
    local horde = newClient("Gor Mash", "Horde")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    local sends = sentBy(alice, "CHANNEL")
    assert(#sends == 1, "one channel message for a new listing")
    assert(sends[1].text == "L:1:A:a:z:stromgarde:40:1:0:0:1:60:150", "wire format changed: " .. sends[1].text)
    assert(sends[1].target == 5 and sends[1].prefix == "OverlordGF")
    assert(alice.tokensTaken == 1 and alice.kinds.GF == 1, "token or /ov network counter missing")
    for _, client in ipairs({ bob, carl }) do
        local entry = client.GF.board[key(alice)]
        assert(entry and client.GF.boardCount == 1, client.name .. " did not hear the listing")
        assert(entry.intent == "a" and entry.kind == "z" and entry.target == "stromgarde")
        assert(entry.cap == 40 and entry.count == 1 and entry.minLevel == 0)
        assert(entry.auto == false and entry.raid == false and entry.class == 1 and entry.level == 60)
        assert(entry.info.name == "Stromgarde" and entry.info.frontName == "Arathi")
        assert(entry.name == "Alice Smith")
    end
    assert(horde.GF.boardCount == 0, "the other faction must not list it")
    assert(alice.GF.boardCount == 0, "the own listing is not read back from the channel")
    -- No reply amplifier: the only message of the whole exchange is the listing.
    assert(#log == 1, "a listing made " .. (#log - 1) .. " other message(s)")
    assert(alice.GF.own.state == "live")
end

-- ---------------------------------------------------------------------------
-- 2. Cadence: 60 s alone, slower as the board grows, never critical
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:HeartbeatInterval() == 60)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    advance(600)
    assert(#sentBy(alice, "CHANNEL") == 11, "alone: one send per minute, got " .. #sentBy(alice, "CHANNEL"))

    reset()
    alice = newClient("Alice Smith", "Alliance")
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 40 do
        local a, b = (i - 1) % 26 + 1, math.floor((i - 1) / 26) + 1
        local name = "Lead" .. letters:sub(b, b) .. " Ray" .. letters:sub(a, a)
        alice.GF:OnListing("L:1:A:h:w::10:3:0:1:2:60:600", name)
    end
    assert(alice.GF.boardCount == 40)
    assert(alice.GF:HeartbeatInterval() == 147.5, "40 listings heard: 147.5 s")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(sentBy(alice, "CHANNEL")[1].text:match(":(%d+)$") == "325", "lifetime follows the interval")
    advance(590)
    assert(#sentBy(alice, "CHANNEL") == 5, "crowded board: one send per 147.5 s")
    -- Whatever the size of the board, the whole board stays under 0.4 message/s.
    for n = 1, alice.GF.BOARD_MAX do
        local interval = math.max(alice.GF.HEARTBEAT_MIN, math.min(alice.GF.HEARTBEAT_MAX,
            alice.GF.HEARTBEAT_BASE + alice.GF.HEARTBEAT_PER_LISTING * n))
        assert(n / interval <= 0.4, "board of " .. n .. " listings costs " .. n / interval .. " msg/s")
    end
end

-- ---------------------------------------------------------------------------
-- 3. A burst of joins costs one send, 20 s after the previous one at the earliest
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    local m1, m2, m3 = newClient("Mia One", "Alliance"), newClient("Mia Two", "Alliance"), newClient("Mia Tri", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    advance(5)
    local before = #sentBy(alice, "CHANNEL")
    join(alice, m1); join(alice, m2); join(alice, m3)
    for _ = 1, 6 do fire(alice, "GROUP_ROSTER_UPDATE") end
    advance(14)
    assert(#sentBy(alice, "CHANNEL") == before, "the new head count waits for the 20 s gap")
    advance(3)
    local sends = sentBy(alice, "CHANNEL")
    assert(#sends == before + 1, "one send for the whole burst")
    assert(sends[#sends].text:find("^L:1:A:a:z:stromgarde:40:4:"), "head count not updated: " .. sends[#sends].text)
    assert(sends[#sends].at - sends[#sends - 1].at >= 19.99)
    assert(bob.GF.board[key(alice)].count == 4)
end

-- ---------------------------------------------------------------------------
-- 4. A listing dies of its lifetime; a withdrawal removes it at once
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF.boardCount == 1)
    -- Alice enters an instance: nothing more is sent, not even a farewell.
    alice.inInstance = true
    alice.GF:OnInstanceSuspend()
    local sent = #log
    advance(140)
    assert(bob.GF.boardCount == 1, "still inside its 150 s lifetime")
    advance(20)
    assert(bob.GF.boardCount == 0, "expired listing still on the board")
    assert(#log == sent, "something was sent from an instance")
    assert(not bob.GF.ticker, "idle client keeps a ticker")

    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(alice.GF:Unpublish("user"))
    deliver()
    assert(sentBy(alice, "CHANNEL", "^X:1:A$")[1], "no withdrawal message")
    assert(bob.GF.boardCount == 0, "withdrawn listing still on the board")
    advance(600)
    assert(#sentBy(alice, "CHANNEL") == 2, "a withdrawn listing keeps sending")

    -- No free token at the withdrawal: the farewell is tried again a few seconds later.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.token = false
    assert(alice.GF:Unpublish("user"))
    deliver()
    assert(bob.GF.boardCount == 1 and not sentBy(alice, "CHANNEL", "^X:1:A$")[1])
    alice.token = true
    advance(4)
    assert(sentBy(alice, "CHANNEL", "^X:1:A$")[1], "the withdrawal was never tried again")
    assert(bob.GF.boardCount == 0)
    -- Blizzard refused the farewell: tried again too.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.sendResult = 8
    assert(alice.GF:Unpublish("user"))
    deliver()
    assert(bob.GF.boardCount == 1)
    alice.sendResult = nil
    advance(4)
    assert(bob.GF.boardCount == 0, "a refused withdrawal was never tried again")
    -- Channel left meanwhile: nothing to try again (the listing ends with its lifetime).
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.channelId = nil
    assert(alice.GF:Unpublish("user"))
    local before = #log
    alice.channelId = 5
    advance(30)
    assert(#log == before, "a farewell was retried for a channel that was not joined")
    -- A new listing published meanwhile: the old farewell must not remove it.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(20)     -- past the 8 s a client waits between two listings of one sender
    alice.token = false
    assert(alice.GF:Unpublish("user"))
    alice.token = true
    assert(alice.GF:Publish(spec({ intent = "d" })))
    advance(10)
    assert(#sentBy(alice, "CHANNEL", "^X:") == 0 and bob.GF.boardCount == 1
        and bob.GF.board[key(alice)].intent == "d", "the farewell of the old listing removed the new one")
    -- Never tried without end.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.token = false
    assert(alice.GF:Unpublish("user"))
    local taken = #log
    advance(60)
    alice.token = true
    advance(60)
    assert(#log == taken, "a farewell is still tried a minute later")
end

-- ---------------------------------------------------------------------------
-- 5. Sign-up approved by the leader
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance", { rawName = "Bob Stone-Forever" })
    local carl = newClient("Carl Reed", "Alliance")
    assert(alice.GF:Publish(spec()))
    assert(carl.GF:Publish(spec({ intent = "h", kind = "f", target = "arathi", cap = 10 })))
    advance(0.3)
    assert(bob.GF.boardCount == 2)
    assert(bob.GF:SignUp(key(alice)))
    local whisper = sentBy(bob, "WHISPER")[1]
    assert(whisper.text == "J:1:A:a:z:stromgarde:1:60" and whisper.target == "Alice Smith", whisper.text)
    assert(bob.remembered[1] == "Alice Smith", "whisper target not recorded for the offline filter")
    deliver()
    assert(#alice.GF.pending == 1 and alice.GF.pending[1].name == "Bob Stone")
    assert(#alice.invites == 0, "manual mode must not invite by itself")
    assert(bob.GF:GetApplyStatus(key(alice)) == "pending")
    assert(alice.printed[1] and alice.printed[1]:find("Bob Stone", 1, true), "leader not told")
    -- Second click while waiting: refused locally, nothing sent.
    local sent = #log
    local ok, reason = bob.GF:SignUp(key(alice))
    assert(not ok and reason == "GF_ERR_WAIT" and #log == sent)
    assert(alice.GF:Accept(key(bob)))
    deliver()
    assert(alice.invites[1] == "Bob Stone-Forever", "invite must use the sender as received")
    assert(#alice.GF.pending == 0)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited")
    -- One accepted sign-up per five minutes, kept across a reload.
    local left = bob.GF:SignupCooldownRemaining()
    assert(left > 295 and left <= 300, "cooldown " .. left)
    ok, reason = bob.GF:CanSignUp(bob.GF.board[key(carl)])
    assert(not ok and reason == "GF_ERR_COOLDOWN")
    assert(bob.db.groupFinder.signups["Bob Stone"], "the wait is not saved")
    bob.GF._signupAt = nil
    assert(bob.GF:SignupCooldownRemaining() > 295, "cooldown lost on reload")
    join(alice, bob)
    advance(1)
    assert(bob.GF.apply == nil, "request kept after joining")
    ok, reason = bob.GF:CanSignUp(bob.GF.board[key(carl)])
    assert(not ok and reason == "GF_ERR_GROUPED")
    advance(301)
    bob.group = { size = 0, raid = false, leader = false, members = {} }
    assert(bob.GF:SignupCooldownRemaining() == 0)
end

-- ---------------------------------------------------------------------------
-- 6. Automatic invitation, a party of five waiting for the raid, a full group
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(alice.invites[1] == "Bob Stone" and #alice.GF.pending == 0)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited")
    assert(#alice.printed == 0, "automatic mode needs no chat line")

    -- Party of five, size 10, not a raid yet: the sixth waits, then goes in.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    local six = newClient("Sam Six", "Alliance")
    alice.group = { size = 5, raid = false, leader = true, members = {} }
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(six.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 0 and #alice.GF.pending == 1, "a full party cannot invite")
    assert(six.GF:GetApplyStatus(key(alice)) == "pending")
    assert(alice.GF:ConvertToRaid() and alice.group.raid)
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(1)
    assert(alice.invites[1] == "Sam Six" and #alice.GF.pending == 0, "not invited after the conversion")
    assert(six.GF:GetApplyStatus(key(alice)) == "invited")

    -- Size 5 and five members: full, on the row and for a forged request.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.group = { size = 4, raid = false, leader = true, members = {} }
    assert(alice.GF:Publish(spec({ cap = 5, auto = true })))
    advance(0.3)
    alice.group.size = 5
    local ok, reason = alice.GF:Publish(spec({ cap = 5 }))
    assert(not ok and reason == "GF_ERR_GROUP_FULL")
    advance(9)
    fire(bob, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:z:stromgarde:5:5:0:1:1:60:150", "CHANNEL", "Alice Smith")
    ok, reason = bob.GF:CanSignUp(bob.GF.board[key(alice)])
    assert(not ok and reason == "GF_ERR_FULL")
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Bob Stone")
    assert(sentBy(alice, "WHISPER", "^R:1:f$")[1] and #alice.invites == 0)
end

-- ---------------------------------------------------------------------------
-- 6b. The game drops the invitation: the leader is told, the click takes over
-- ---------------------------------------------------------------------------
do
    -- Delivered: nothing more is said, the cooldown stands.
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(46)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and bob.GF:SignupCooldownRemaining() > 0)
    assert(#sentBy(bob, "WHISPER", "^N:") == 0)
    assert(#sentBy(alice, "WHISPER") + #sentBy(bob, "WHISPER") == 2, "a delivered invitation costs two whispers")

    -- Dropped: one "not received" whisper, the request is back for a click, the five
    -- minutes are given back. It concerns its author only: the next player is still
    -- invited automatically.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    local carl = newClient("Carl Reed", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 1 and bob.GF:GetApplyStatus(key(alice)) == "invited")
    -- Not before 45 s: the game's invitation can be that late on a slow server.
    advance(40)
    assert(bob.GF.apply.status == "invited" and #sentBy(bob, "WHISPER", "^N:") == 0 and #alice.printed == 0,
        "the alarm was raised too early")
    advance(6)
    assert(bob.GF.apply and bob.GF.apply.status == "lost", "a lost invitation still reads 'invited'")
    assert(bob.GF:SignupCooldownRemaining() == 0 and bob.db.groupFinder.signups["Bob Stone"] == nil)
    assert(#sentBy(bob, "WHISPER", "^N:1$") == 1)
    assert(#alice.GF.pending == 1 and alice.GF.pending[1].manual and alice.GF.outstandingCount == 0)
    assert(alice.printed[1] and alice.printed[1]:find("Bob Stone", 1, true), "leader not told")
    alice.invitesDropped = false
    assert(carl.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 2 and alice.invites[2] == "Carl Reed", "one lost invitation stopped automatic invitation")
    assert(#alice.GF.pending == 1, "the request sent back must wait for the click")
    -- A second "not received" for the same invitation, or from a stranger, is ignored.
    local told = #alice.printed
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "N:1", "WHISPER", "Bob Stone")
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "N:1", "WHISPER", "Eve Dark")
    assert(#alice.GF.pending == 1 and #alice.printed == told)
    -- A roster change never re-invites the request kept for the click.
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(1)
    assert(#alice.invites == 2 and #alice.GF.pending == 1)
    -- The click works: the player reads "invited" again and his five minutes start.
    -- Here the leader's answer comes first and the game's invitation a little later.
    alice.invitesDropped = true
    assert(alice.GF:Accept(key(bob)))
    deliver()
    assert(#alice.invites == 3 and #alice.GF.pending == 0)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and bob.GF.apply.retried, "the second 'invited' was not read")
    assert(bob.GF:SignupCooldownRemaining() > 290)
    advance(10)
    fire(bob, "PARTY_INVITE_REQUEST", "Alice Smith")
    advance(40)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and #sentBy(bob, "WHISPER", "^N:1$") == 1,
        "an invitation seen since the click raised a second alarm")
    assert(#sentBy(bob, "WHISPER", "^C:") == 0)

    -- Same click, the game's invitation first and the answer after it: the invitation
    -- is in hand, one "forget my request" goes out, the leader keeps the place.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(46)
    assert(bob.GF.apply.status == "lost" and #alice.GF.pending == 1)
    alice.invitesDropped = false
    assert(alice.GF:Accept(key(bob)))
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and bob.GF:SignupCooldownRemaining() > 290)
    deliver()
    assert(#sentBy(bob, "WHISPER", "^C:1$") == 1 and bob.GF:GetApplyStatus(key(alice)) == "invited")
    assert(alice.GF.outstanding[key(bob)] and alice.GF.outstandingCount == 1, "the cancel undid the invitation of the click")
    advance(50)
    assert(#sentBy(bob, "WHISPER", "^N:1$") == 1, "a second alarm for an invitation in hand")

    -- The click fails too: the leader is given the game's own command, without the
    -- player having to sign up again, and the exchange stops there.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10 })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(alice.GF:Accept(key(bob)))
    deliver()
    advance(46)
    assert(#alice.GF.pending == 1 and alice.GF.pending[1].manual)
    assert(alice.GF:Accept(key(bob)))
    deliver()
    advance(46)
    assert(#alice.GF.pending == 0, "a request refused twice by the game must leave the list")
    assert(alice.printed[#alice.printed]:find("/invite Bob Stone", 1, true), alice.printed[#alice.printed])
    assert(bob.GF.apply.status == "lost" and bob.GF:SignupCooldownRemaining() == 0)
    assert(#sentBy(bob, "WHISPER", "^N:1$") == 2)
    -- A third "invited" is not read any more: no ping-pong.
    fire(bob, "CHAT_MSG_ADDON", "OverlordGF", "R:1:i", "WHISPER", "Alice Smith")
    assert(bob.GF.apply.status == "lost")

    -- A second click on a leader who already invited us gets "invited" with no new
    -- prompt: the invitation seen before that click still counts.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    bob.GF.apply = nil                      -- the answer was missed (a reload)
    bob.GF:ClearSignupCooldown()
    advance(30)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 1 and bob.GF:GetApplyStatus(key(alice)) == "invited")
    advance(46)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and #sentBy(bob, "WHISPER", "^N:") == 0)

    -- A slow server: the game's invitation comes half a minute after the leader's
    -- answer. Nothing is said to anybody, the place stays held, the five minutes stand.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(30)
    fire(bob, "PARTY_INVITE_REQUEST", "Alice Smith")
    advance(20)
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and bob.GF:SignupCooldownRemaining() > 0)
    assert(#sentBy(bob, "WHISPER", "^N:") == 0 and #sentBy(bob, "WHISPER", "^C:") == 0 and #alice.printed == 0,
        "an invitation that was only slow raised the alarm")
    alice.GF:PruneOutstanding(now)
    assert(alice.GF.outstandingCount == 1 and #alice.GF.pending == 0, "the place was given up before the alarm could come")

    -- Somebody else's invitation does not hide a lost one: the alarm still goes out.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    advance(5)
    fire(bob, "PARTY_INVITE_REQUEST", "Eve Dark")     -- a friend, just before the click
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(20)
    fire(bob, "PARTY_INVITE_REQUEST", "Eve Dark")     -- and again while we wait
    advance(26)
    assert(bob.GF.apply.status == "lost" and #sentBy(bob, "WHISPER", "^N:1$") == 1,
        "a stranger's invitation was taken for the leader's")
    -- An invitation whose sender the game does not name counts by its moment.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(20)
    fire(bob, "PARTY_INVITE_REQUEST")
    advance(26)
    assert(bob.GF.apply.status == "invited" and #sentBy(bob, "WHISPER", "^N:") == 0)
    -- Same for a name handed over as a protected value: it is never read.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(46)
    assert(bob.GF.apply.status == "lost")
    bob.secret = true
    fire(bob, "PARTY_INVITE_REQUEST", "Alice Smith")
    bob.secret = false
    assert(bob.GF.apply.status == "lost" and #sentBy(bob, "WHISPER", "^C:") == 0 and next(bob.GF._invitesSeen) == nil,
        "a protected name was read")

    -- Slower than our wait: the alarm went out, then the invitation comes. It is in
    -- hand after all: the row says "invited" again, the five minutes start again and
    -- the leader's list forgets the request it had taken back.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(46)
    assert(bob.GF.apply.status == "lost" and #alice.GF.pending == 1 and bob.GF:SignupCooldownRemaining() == 0)
    -- Somebody else's invitation, or one without a name, changes nothing.
    fire(bob, "PARTY_INVITE_REQUEST", "Eve Dark")
    fire(bob, "PARTY_INVITE_REQUEST")
    assert(bob.GF.apply.status == "lost" and #sentBy(bob, "WHISPER", "^C:") == 0)
    fire(bob, "PARTY_INVITE_REQUEST", "Alice Smith")
    deliver()
    assert(bob.GF:GetApplyStatus(key(alice)) == "invited" and bob.GF:SignupCooldownRemaining() > 290,
        "a late invitation was not taken as received")
    assert(#sentBy(bob, "WHISPER", "^C:1$") == 1 and #alice.GF.pending == 0, "the leader still holds the request")
    -- Known limit: the leader gave the place up when the alarm came, it is not taken back.
    assert(alice.GF.outstandingCount == 0)
    advance(50)
    assert(#sentBy(bob, "WHISPER", "^N:1$") == 1, "a late invitation raised a second alarm")

    -- The player's client did not tell (an older version): the request goes away by
    -- itself once he is in the group.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    advance(46)
    assert(#alice.GF.pending == 1 and alice.GF.pending[1].manual)
    join(alice, bob)
    advance(1)
    assert(#alice.GF.pending == 0 and alice.GF.pendingByKey[key(bob)] == nil,
        "a request stays in the list for a player who is in the group")
end

-- ---------------------------------------------------------------------------
-- 6c. The leader's side keeps its own count: five minutes, arrival order, clicks
-- ---------------------------------------------------------------------------
do
    -- A player invited minutes ago who left (or whose client lies about its wait) is
    -- not invited automatically again: the leader decides.
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 1)
    advance(70)
    bob.GF.apply = nil
    bob.GF:ClearSignupCooldown()
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 1 and #alice.GF.pending == 1 and alice.GF.pending[1].held,
        "re-invited automatically within five minutes")
    assert(bob.GF:GetApplyStatus(key(alice)) == "pending")
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(6)
    assert(#alice.invites == 1, "a held request was drained")
    assert(alice.GF:Accept(key(bob)) and #alice.invites == 2)
    -- After five minutes the automatic path is open again.
    advance(301)
    bob.GF.apply = nil
    bob.GF:ClearSignupCooldown()
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.invites == 3)

    -- An invitation nobody answers frees its place after a minute, without a roster
    -- event, and nobody overtakes the player who waited.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    local names = { "Ann One", "Ben Two", "Cat Tri", "Dan For", "Eli Fiv", "Fay Six" }
    local players = {}
    for i, name in ipairs(names) do players[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 5 do assert(players[i].GF:SignUp(key(alice))) end
    deliver()
    advance(4)
    assert(#alice.invites == 4 and #alice.GF.pending == 1, "a solo leader invites four, the fifth waits")
    assert(alice.GF.pending[1].name == "Eli Fiv")
    advance(50)
    assert(#alice.invites == 4)
    advance(15)
    assert(#alice.invites == 5 and alice.invites[5] == "Eli Fiv", "the waiting player was not invited when a place freed")
    -- With someone waiting, a newcomer queues behind him.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    players = {}
    for i, name in ipairs(names) do players[i] = newClient(name, "Alliance") end
    alice.group = { size = 5, raid = false, leader = true, members = {} }
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    assert(players[1].GF:SignUp(key(alice)))
    deliver()
    alice.group.raid = true
    assert(players[2].GF:SignUp(key(alice)))
    deliver()
    advance(2)
    assert(alice.invites[1] == "Ann One" and alice.invites[2] == "Ben Two", "arrival order lost")

    -- Two clicks in the same half second both invite inside their click.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    local bob2, carl2 = newClient("Bob Stone", "Alliance"), newClient("Carl Reed", "Alliance")
    assert(alice.GF:Publish(spec({ cap = 10 })))
    advance(0.3)
    assert(bob2.GF:SignUp(key(alice)) and carl2.GF:SignUp(key(alice)))
    deliver()
    assert(alice.GF:Accept(key(bob2)) and alice.GF:Accept(key(carl2)))
    assert(#alice.invites == 2, "a clicked invitation was left to a timer")

    -- The leader's memory is bounded without forgetting whom it just invited: at its
    -- cap the entries older than five minutes go first.
    assert(alice.GF.invitedAt[key(bob2)] and alice.GF.invitedAt[key(carl2)])
    for i = 1, 300 do
        if not alice.GF.invitedAt["old " .. i] then alice.GF.invitedCount = alice.GF.invitedCount + 1 end
        alice.GF.invitedAt["old " .. i] = now - 400
        if alice.GF.invitedCount >= 256 then break end
    end
    local dan = newClient("Dan Vale", "Alliance")
    advance(61)
    assert(dan.GF:SignUp(key(alice)))
    deliver()
    assert(alice.GF:Accept(key(dan)))
    assert(alice.GF.invitedAt[key(bob2)] and alice.GF.invitedAt[key(dan)], "the five-minute memory was wiped")
    assert(alice.GF.invitedCount == 3 and not alice.GF.invitedAt["old 1"], "stale entries kept: " .. alice.GF.invitedCount)

    -- An empty token bucket: the listing looks again every 0.3 s for a few seconds and
    -- takes the first free token, instead of leaving them all to a relay with a backlog.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.token = false
    assert(alice.GF:Publish(spec()))
    advance(2)
    assert(#log == 0 and alice.GF.own.state == "sending", "a short wait must not read as a busy channel")
    alice.token = true
    advance(0.4)
    assert(#sentBy(alice, "CHANNEL") == 1, "the first free token was not taken")

    -- A reply goes to someone who just whispered: his name is not put in Sync's table
    -- of offline-whisper names; a sign-up to a leader heard on the channel is.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob2 = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob2.GF:SignUp(key(alice)))
    deliver()
    assert(#bob2.remembered == 1 and #alice.remembered == 0, "a reply filled the offline-whisper table")
    -- The answer that leaves later (the leader's click) is recorded: the player may
    -- have logged off meanwhile, and the game's "No player named" line stays hidden.
    advance(30)
    assert(alice.GF:Accept(key(bob2)))
    assert(#alice.remembered == 1 and alice.remembered[1] == "Bob Stone", "a late answer was not recorded")

    -- An invitation waiting for its turn (0.6 s apart) is dropped when the listing is
    -- withdrawn or replaced meanwhile.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 5, raid = true, leader = true, members = {} }
    local three = {}
    for i, name in ipairs({ "Ann One", "Ben Two", "Cat Tri" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 3 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    assert(#alice.invites == 1, "invitations must leave one at a time")
    assert(alice.GF:Unpublish("user"))
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(3)
    assert(#alice.invites == 1, "an invitation left under a listing its player did not sign up to")
    assert(alice.GF.outstandingCount == 0)
    -- The timer of a request replaced by a newer one from the same player does nothing.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 5, raid = true, leader = true, members = {} }
    three = {}
    for i, name in ipairs({ "Ann One", "Ben Two", "Cat Tri" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 3 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    local slot = alice.GF.outstanding["ben two"]
    assert(slot and not slot.sent and alice.GF.outstanding["ann one"].sent)
    slot.app = { key = "ben two", name = "Ben Two", raw = "Ben Two", class = 1, level = 60, at = now }
    advance(3)
    assert(#alice.invites == 2 and alice.invites[2] == "Cat Tri", "a stale timer invited")
    -- The player signs up elsewhere while his invitation waits: it is given up, his
    -- place is free and the five-minute memory forgets him. One that left stays.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 5, raid = true, leader = true, members = {} }
    three = {}
    for i, name in ipairs({ "Ann One", "Ben Two", "Cat Tri" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 3 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    assert(alice.GF.outstandingCount == 3 and alice.GF.invitedCount == 3)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "C:1", "WHISPER", "Ben Two")
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "C:1", "WHISPER", "Ann One")
    assert(alice.GF.outstandingCount == 2 and alice.GF.outstanding["ann one"], "a cancel undid an invitation that left")
    assert(alice.GF.invitedAt["ben two"] == nil and alice.GF.invitedCount == 2)
    advance(3)
    assert(#alice.invites == 2 and alice.invites[2] == "Cat Tri", "a cancelled request was invited")
    -- ... and refused when the group filled up by another way.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 8, raid = true, leader = true, members = {} }
    three = {}
    for i, name in ipairs({ "Ann One", "Ben Two" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 2 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    assert(#alice.invites == 1 and alice.GF.outstandingCount == 2)
    alice.group.size = 10
    advance(1)
    assert(#alice.invites == 1, "a full group still invited")
    assert(three[2].GF:GetApplyStatus(key(alice)) == "full" and alice.GF.outstandingCount == 1)
    assert(alice.GF.invitedAt["ben two"] == nil and alice.GF.invitedCount == 1,
        "a player who was never invited is remembered as invited")
    assert(alice.remembered[#alice.remembered] == "Ben Two", "an answer sent from a timer was not recorded")
    -- The minute of a place starts when its invitation leaves, not when it queued: the
    -- "not received" of the last player of a burst still finds his place.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 5, raid = true, leader = true, members = {} }
    alice.invitesDropped = true
    three = {}
    for i, name in ipairs({ "Ann One", "Ben Two", "Cat Tri" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 40, auto = true })))
    advance(0.3)
    for i = 1, 3 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    local queuedAt = now
    advance(2)
    assert(#alice.invites == 3)
    assert(math.abs(alice.GF.outstanding["cat tri"].at - (queuedAt + 1.2)) < 0.01, "a place is dated from its turn in the queue")
    assert(alice.GF.outstanding["ann one"].at == queuedAt)
    -- Without either, the queued invitation leaves at its turn.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 5, raid = true, leader = true, members = {} }
    three = {}
    for i, name in ipairs({ "Ann One", "Ben Two" }) do three[i] = newClient(name, "Alliance") end
    assert(alice.GF:Publish(spec({ cap = 10, auto = true })))
    advance(0.3)
    for i = 1, 2 do assert(three[i].GF:SignUp(key(alice))) end
    deliver()
    advance(1)
    assert(#alice.invites == 2 and three[2].GF:GetApplyStatus(key(alice)) == "invited")

    -- "Not received" with a waiting list already full: the request cannot come back,
    -- so the leader is not told to invite from the window.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob2 = newClient("Bob Stone", "Alliance")
    alice.invitesDropped = true
    assert(alice.GF:Publish(spec({ cap = 40, auto = true })))
    advance(0.3)
    assert(bob2.GF:SignUp(key(alice)))
    deliver()
    for i = 1, alice.GF.PENDING_MAX do
        local app = { key = "dummy " .. i, name = "Dummy Row", raw = "Dummy Row", class = 1, level = 60,
            at = now, manual = true }
        alice.GF.pending[i], alice.GF.pendingByKey[app.key] = app, app
    end
    advance(46)
    assert(#sentBy(bob2, "WHISPER", "^N:1$") == 1 and alice.GF.outstandingCount == 0)
    assert(#alice.GF.pending == alice.GF.PENDING_MAX and #alice.printed == 0,
        "the leader was sent to a request that is not in the window")

    -- The +-10 % on a re-send: both ends of the draw stay inside it.
    for _, draw in ipairs({ 0, 1 }) do
        reset()
        alice = newClient("Alice Smith", "Alliance")
        alice.GF.Random = function() return draw end
        assert(alice.GF:Publish(spec()))
        advance(0.3)
        local first = sentBy(alice, "CHANNEL")[1].at
        advance(80)
        local sends = sentBy(alice, "CHANNEL")
        assert(#sends == 2, "one re-send expected in 80 s, got " .. (#sends - 1))
        local gap = sends[2].at - first
        local expected = alice.GF.HEARTBEAT_MIN * (0.9 + 0.2 * draw)
        assert(math.abs(gap - expected) < 0.6, "re-send after " .. gap .. " s, expected " .. expected)
    end

    -- One chat line per player and per listing, whatever he cancels and asks again.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    for _ = 1, 4 do
        fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
        fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "C:1", "WHISPER", "Eve Dark")
        advance(25)
    end
    assert(#alice.printed == 1, "the same player made " .. #alice.printed .. " chat lines")

    -- The wait is kept per character: another character of the account neither
    -- inherits it nor erases it.
    reset()
    local db = {}
    local main = newClient("Bob Stone", "Alliance", { db = db })
    main.GF:StartSignupCooldown()
    clients = {}
    local alt = newClient("Zed Other", "Alliance", { db = db })
    assert(alt.GF:SignupCooldownRemaining() == 0)
    alt.GF:StartSignupCooldown()
    alt.GF:ClearSignupCooldown()
    clients = {}
    local back = newClient("Bob Stone", "Alliance", { db = db })
    assert(back.GF:SignupCooldownRemaining() > 290, "another character erased the wait")

    -- The fullest groups come first, and a row moves up as its group fills.
    reset()
    local bob3 = newClient("Bob Stone", "Alliance")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:39:0:1:1:60:600", "CHANNEL", "Ghost Row")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:2:0:1:1:60:600", "CHANNEL", "Real One")
    local out = {}
    bob3.GF:FillBoard(out)
    assert(out[1].name == "Ghost Row" and out[2].name == "Real One", "the fullest group is not first")
    advance(9)
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:2:0:1:1:60:600", "CHANNEL", "Ghost Row")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:39:0:1:1:60:600", "CHANNEL", "Real One")
    bob3.GF:FillBoard(out)
    assert(out[1].name == "Real One" and out[2].name == "Ghost Row", "a group that filled up did not move up")
    local top, second = out[1], out[2]
    -- Same head count: the smaller group is the fuller one; then the leader's name.
    local before = bob3.GF.CompareEntries
    assert(before({ rank = 0, count = 4, cap = 5, key = "b" }, { rank = 0, count = 4, cap = 40, key = "a" }))
    assert(not before({ rank = 0, count = 4, cap = 40, key = "a" }, { rank = 0, count = 4, cap = 5, key = "b" }))
    assert(before({ rank = 0, count = 4, cap = 5, key = "a" }, { rank = 0, count = 4, cap = 5, key = "b" }))
    -- A group the player cannot join never passes one he can, however full.
    assert(before({ rank = 0, count = 2, cap = 40, key = "a" }, { rank = 2, count = 39, cap = 40, key = "b" }))

    -- A leader who never answers goes to the end of this player's board.
    assert(bob3.GF:SignUp(top.key))
    advance(13)
    assert(bob3.GF:GetApplyStatus(top.key) == "timeout")
    bob3.GF:FillBoard(out)
    assert(out[1] == second and out[2] == top, "a silent leader keeps the top of the board")
    -- His invitation waited for its turn in a crowd and comes after our wait ran out:
    -- "invited" is still read (nothing else is), and the row is no longer silent.
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "R:1:p", "WHISPER", top.name)
    assert(bob3.GF:GetApplyStatus(top.key) == "timeout")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "R:1:i", "WHISPER", top.name)
    assert(bob3.GF:GetApplyStatus(top.key) == "invited" and bob3.GF:SignupCooldownRemaining() > 0)
    assert(not top.silent, "a leader who answered late stays ranked as silent")
    -- No invitation follows: "not received" goes out, to a name recorded for the
    -- offline filter (the leader may be gone).
    local recorded = #bob3.remembered
    advance(46)
    assert(bob3.GF:GetApplyStatus(top.key) == "lost" and #sentBy(bob3, "WHISPER", "^N:1$") == 1)
    assert(#bob3.remembered == recorded + 1 and bob3.remembered[#bob3.remembered] == top.name)

    -- Signing up elsewhere after a wait that ran out still tells the first leader: he
    -- may hold our request in his queue.
    reset()
    bob3 = newClient("Bob Stone", "Alliance")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:3:0:1:1:60:600", "CHANNEL", "Ghost Row")
    fire(bob3, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:2:0:1:1:60:600", "CHANNEL", "Real One")
    assert(bob3.GF:SignUp("ghost row"))
    advance(13)
    assert(bob3.GF:GetApplyStatus("ghost row") == "timeout")
    advance(10)
    assert(bob3.GF:SignUp("real one"))
    local cancels = sentBy(bob3, "WHISPER", "^C:1$")
    assert(#cancels == 1 and cancels[1].target == "Ghost Row", "the first leader was not told")
end

-- ---------------------------------------------------------------------------
-- 7. Refusals: declined, level, changed listing, no answer
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    local low = newClient("Tim Low", "Alliance", { level = 20 })
    assert(alice.GF:Publish(spec({ minLevel = 40 })))
    advance(0.3)
    local ok, reason, arg = low.GF:CanSignUp(low.GF.board[key(alice)])
    assert(not ok and reason == "GF_ERR_LEVEL" and arg == 40)
    -- A client that lies about the check still gets the leader's answer.
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:20", "WHISPER", "Tim Low")
    assert(sentBy(alice, "WHISPER", "^R:1:l$")[1] and #alice.GF.pending == 0)

    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(alice.GF:Decline(key(bob)))
    deliver()
    assert(bob.GF:GetApplyStatus(key(alice)) == "declined")
    assert(bob.GF:SignupCooldownRemaining() == 0, "a refusal must not start the cooldown")
    -- Declined: the leader's client ignores him for five minutes (a sign-up sent
    -- anyway gets no answer) ...
    local replies = #sentBy(alice, "WHISPER")
    advance(11)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Bob Stone")
    assert(#sentBy(alice, "WHISPER") == replies and #alice.GF.pending == 0, "a declined player was read again")
    -- ... and his own client knows it: no whisper into the void, the row keeps saying
    -- "Declined" with the time left, and goes to the end of his board.
    local whispers = #sentBy(bob, "WHISPER")
    local okNow, why, left = bob.GF:CanSignUp(bob.GF.board[key(alice)])
    assert(not okNow and why == "GF_ERR_COOLDOWN" and left > 280 and left <= 300, "refusal reason right after a decline: " .. tostring(why))
    advance(25)
    okNow, why, left = bob.GF:SignUp(key(alice))
    assert(not okNow and why == "GF_ERR_COOLDOWN" and left > 250, "a declined player could sign up again at once")
    assert(#sentBy(bob, "WHISPER") == whispers, "a refused click still whispered")
    assert(bob.GF.apply == nil and bob.GF:GetApplyStatus(key(alice)) == "declined", "the refusal is forgotten after 20 s")
    -- Same size and head count as Alice's listing, a name that sorts after hers: only
    -- the refusal can put her below.
    fire(bob, "CHAT_MSG_ADDON", "OverlordGF", "L:1:A:a:w::40:1:0:1:1:60:600", "CHANNEL", "Real One")
    local shown = {}
    bob.GF:FillBoard(shown)
    assert(#shown == 2 and shown[1].name == "Real One" and shown[2].key == key(alice),
        "a leader who declined us must rank after an equal listing")
    -- A withdraw and a new listing of the same leader do not erase it.
    assert(alice.GF:Unpublish("user"))
    advance(20)
    assert(alice.GF:Publish(spec({ minLevel = 40 })))
    advance(1)
    assert(bob.GF.board[key(alice)] and bob.GF:GetApplyStatus(key(alice)) == "declined")
    -- After the five minutes the row is free again, repainted without any message.
    local revision = bob.GF.revision
    advance(260)
    assert(bob.GF:GetApplyStatus(key(alice)) == nil and bob.GF.declinedCount == 0, "the refusal outlived its five minutes")
    assert(bob.GF.revision > revision, "the row was not repainted when the refusal ended")
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.GF.pending == 1)
    -- An instance wipes it with the rest.
    bob.GF.declinedBy["someone else"], bob.GF.declinedCount = now + 300, 1
    bob.inInstance = true
    bob.GF:OnInstanceSuspend()
    assert(next(bob.GF.declinedBy) == nil and bob.GF.declinedCount == 0)

    -- The listing changed between the board and the click.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(alice.GF:Publish(spec({ intent = "d" })))
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(bob.GF:GetApplyStatus(key(alice)) == "gone" and #alice.GF.pending == 0)

    -- A second request elsewhere tells the first leader to forget ours.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    local carl = newClient("Carl Reed", "Alliance")
    assert(alice.GF:Publish(spec()))
    assert(carl.GF:Publish(spec({ intent = "h" })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    deliver()
    assert(#alice.GF.pending == 1)
    assert(bob.GF:SignUp(key(carl)))
    deliver()
    assert(#alice.GF.pending == 0 and #carl.GF.pending == 1, "first request not cancelled")
end

-- ---------------------------------------------------------------------------
-- 8. Leadership, absence, lifetime
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.group = { size = 3, raid = false, leader = false, members = {} }
    fire(alice, "PARTY_LEADER_CHANGED")
    advance(1)
    assert(alice.GF.own == nil and #alice.printed == 1, "listing kept without the lead")
    local ok, reason = alice.GF:Publish(spec())
    assert(not ok and reason == "GF_ERR_NOT_LEADER")

    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.afk = true
    fire(alice, "PLAYER_FLAGS_CHANGED", "target")
    assert(alice.GF.own, "another unit's flag must not matter")
    fire(alice, "PLAYER_FLAGS_CHANGED", "player")
    assert(alice.GF.own == nil, "listing kept while away")

    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(3590)
    assert(alice.GF.own, "expired too early")
    advance(20)
    assert(alice.GF.own == nil and #alice.printed == 1, "an idle listing must expire after an hour")

    -- An automatic invitation nobody accepts is not "a new member": the hour still ends.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec({ auto = true })))
    advance(3000)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
    assert(#alice.invites == 1)
    advance(620)
    assert(alice.GF.own == nil, "an unaccepted invitation kept a forgotten listing alive")
    -- The leader's own click is a sign of life.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(3000)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
    assert(alice.GF:Accept("eve dark"))
    advance(620)
    assert(alice.GF.own, "the leader's click did not restart the hour")
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(3000)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
    assert(alice.GF:Decline("eve dark"))
    advance(620)
    assert(alice.GF.own, "the leader's refusal did not restart the hour")
    -- A member who leaves and is replaced before the head count was sent again: the
    -- count sent did not change, the group still got a new member.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 3, raid = false, leader = true, members = {} }
    assert(alice.GF:Publish(spec()))
    advance(3500)
    alice.group.size = 2
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(0.6)
    alice.group.size = 3
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(0.6)
    assert(alice.GF.own.sentCount == 3, "the test needs the head count not to have been sent in between")
    advance(200)
    assert(alice.GF.own, "a replaced member did not restart the hour")
    advance(3500)
    assert(alice.GF.own == nil, "the hour never ends")
end

-- ---------------------------------------------------------------------------
-- 9. Abuse guards
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone", "Alliance")
    local function hear(text, sender, channel)
        fire(bob, "CHAT_MSG_ADDON", "OverlordGF", text, channel or "CHANNEL", sender or "Eve Dark")
    end
    local good = "L:1:A:a:z:stromgarde:40:3:0:1:1:60:150"
    -- Wrong transport, foreign prefix, own echo, oversize.
    hear(good, "Eve Dark", "WHISPER")
    hear(good, "Eve Dark", "RAID")
    fire(bob, "CHAT_MSG_ADDON", "OverlordF", good, "CHANNEL", "Eve Dark")
    hear(good, "Bob Stone")
    hear(good .. string.rep("x", 200))
    assert(bob.GF.boardCount == 0, "a listing was read from the wrong place")
    -- Not a character name.
    hear(good, "Eve")
    hear(good, "BNet-12345")
    assert(bob.GF.boardCount == 0)
    -- Banned.
    bob.banned["Eve Dark"] = true
    hear(good)
    assert(bob.GF.boardCount == 0, "banned sender listed")
    bob.banned["Eve Dark"] = nil
    -- Another protocol version or a place this client does not know: dropped, no blame.
    hear("L:2:A:a:z:stromgarde:40:3:0:1:1:60:150")
    hear("L:1:A:a:z:future_point:40:3:0:1:1:60:150")
    hear("L:1:H:a:z:stromgarde:40:3:0:1:1:60:150")
    assert(bob.GF.boardCount == 0 and bob.GF.strikeCount == 0)
    -- Malformed fields.
    local bad = {
        "L:1:A:q:z:stromgarde:40:3:0:1:1:60:150", "L:1:A:a:y:stromgarde:40:3:0:1:1:60:150",
        "L:1:A:a:z:Strom garde:40:3:0:1:1:60:150", "L:1:A:a:z:stromgarde:41:3:0:1:1:60:150",
        "L:1:A:a:z:stromgarde:40:0:0:1:1:60:150", "L:1:A:a:z:stromgarde:40:3:99:1:1:60:150",
        "L:1:A:a:z:stromgarde:40:3:0:9:1:60:150", "L:1:A:a:z:stromgarde:40:3:0:1:99:60:150",
        "L:1:A:a:z:stromgarde:40:3:0:1:1:0:150", "L:1:A:a:z:stromgarde:40:3:0:1:1:60:150:extra",
        "L:1:A:a:z:stromgarde:40:3:0:1:1:60", "L:1:X:a:z:stromgarde:40:3:0:1:1:60:150",
        "L:1:A:a:w:stromgarde:40:3:0:1:1:60:150", "L:1:A:a:z:stromgarde:4e1:3:0:1:1:60:150",
        "L:1:A:a:z:stromgarde:40:-3:0:1:1:60:150",
    }
    for index, text in ipairs(bad) do
        local sender = "Bad" .. string.char(96 + index) .. " Guy"
        hear(text, sender)
        assert(bob.GF.boardCount == 0, "accepted: " .. text)
        assert(bob.GF.strikes[sender:lower()], "no strike for: " .. text)
    end
    -- Three strikes silence a sender for ten minutes, even with a valid message.
    hear(bad[1]); hear(bad[2]); hear(bad[3])
    hear(good)
    assert(bob.GF.boardCount == 0, "a struck sender was listed")
    advance(601)
    hear(good)
    assert(bob.GF.boardCount == 1)
    -- Rate guard: a second listing within 8 s is not even parsed.
    hear("L:1:A:d:z:stromgarde:40:9:0:1:1:60:150")
    assert(bob.GF.board["eve dark"].intent == "a" and bob.GF.board["eve dark"].count == 3)
    advance(9)
    hear("L:1:A:d:z:stromgarde:40:9:0:1:1:60:150")
    assert(bob.GF.board["eve dark"].intent == "d" and bob.GF.board["eve dark"].count == 9)
    -- A lifetime is clamped.
    hear("L:1:A:a:w::10:3:0:1:1:60:999", "Long Life")
    assert(bob.GF.board["long life"].expires - now == 660)
    hear("L:1:A:a:w::10:3:0:1:1:60:1", "Short Life")
    assert(bob.GF.board["short life"].expires - now == 60)
    -- Bounded board: full means closed, never evicting a live listing.
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 200 do
        local a, b = (i - 1) % 26 + 1, math.floor((i - 1) / 26) + 1
        hear("L:1:A:h:w::10:3:0:1:2:60:600", "Fake" .. letters:sub(b, b) .. " Row" .. letters:sub(a, a))
    end
    assert(bob.GF.boardCount == bob.GF.BOARD_MAX, "board holds " .. bob.GF.boardCount)
    assert(bob.GF.board["eve dark"], "a live listing was evicted")
    -- A withdrawal only removes its sender's own listing.
    hear("X:1:A", "Mal Lory")
    assert(bob.GF.boardCount == bob.GF.BOARD_MAX)
    hear("X:1:A", "Eve Dark")
    assert(bob.GF.board["eve dark"] == nil)
    -- Nothing of the above made this client send anything.
    assert(#log == 0, "receiving made the client send " .. #log .. " message(s)")

    -- Sign-ups: one read per player per 10 s, malformed ones strike, no listing = "gone".
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local function ask(text, sender)
        fire(alice, "CHAT_MSG_ADDON", "OverlordGF", text, "WHISPER", sender or "Eve Dark")
    end
    ask("J:1:A:a:z:stromgarde:1:60")
    assert(#sentBy(alice, "WHISPER", "^R:1:x$") == 1, "no listing: the answer is 'gone'")
    ask("J:1:A:a:z:stromgarde:1:60")
    ask("J:1:A:a:z:stromgarde:1:60")
    assert(#sentBy(alice, "WHISPER") == 1, "one answer per player per 10 s")
    assert(alice.GF:Publish(spec()))
    advance(11)
    ask("J:1:A:a:z:stromgarde:1:60", "Eve Dark")
    assert(#alice.GF.pending == 1)
    ask("J:1:A:a:z:stromgarde:99:60", "Odd One")
    ask("J:1:A:a:z:stromgarde:1:60:more", "Odd Two")
    ask("J:1:H:a:z:stromgarde:1:60", "Other Side")
    ask("J:1:A:a:z:stromgarde:1:60", "Eve Dark")
    assert(#alice.GF.pending == 1, "a malformed or foreign request was queued")
    -- A sign-up on the channel, or an answer nobody asked for, changes nothing.
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "CHANNEL", "Loud Guy")
    ask("R:1:i", "Loud Guy")
    assert(#alice.GF.pending == 1 and alice.GF.apply == nil and alice.GF:SignupCooldownRemaining() == 0)
    -- Bounded waiting list.
    local function crowd(i)
        return "Queue" .. letters:sub(i % 26 + 1, i % 26 + 1) .. " Up" .. letters:sub(math.floor(i / 26) + 1, math.floor(i / 26) + 1)
    end
    for i = 1, 40 do
        ask("J:1:A:a:z:stromgarde:1:60", crowd(i))
        advance(1.1)
    end
    assert(#alice.GF.pending == alice.GF.PENDING_MAX, "waiting list holds " .. #alice.GF.pending)
    -- A crowd in the same second: twenty sign-ups are read, the rest gets no answer
    -- (two more a second afterwards), whether a listing is up or not.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    for i = 1, 50 do ask("J:1:A:a:z:stromgarde:1:60", crowd(i)) end
    assert(alice.GF.SIGNUP_BURST == 20 and alice.GF.SIGNUP_RATE == 2)
    assert(#alice.GF.pending == 20 and #sentBy(alice, "WHISPER") == 20,
        "read in one second: " .. #sentBy(alice, "WHISPER"))
    advance(3.6)
    for i = 51, 70 do ask("J:1:A:a:z:stromgarde:1:60", crowd(i)) end
    assert(#sentBy(alice, "WHISPER") == 27, "after 3.6 s: " .. #sentBy(alice, "WHISPER"))
    assert(#sentBy(alice, "WHISPER", "^R:1:f$") == 7, "a full waiting list must still say so")
    assert(alice.GF:Unpublish("user"))
    advance(60)
    local answered = #sentBy(alice, "WHISPER")
    for i = 1, 50 do ask("J:1:A:a:z:stromgarde:1:60", crowd(i)) end
    assert(#sentBy(alice, "WHISPER") - answered == 20, "no listing: the answers must be bounded too")
    assert(#sentBy(alice, "WHISPER", "^R:1:x$") == 20)
    -- An answer from someone else than the leader we asked is ignored.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    local bob2 = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob2.GF:SignUp(key(alice)))
    fire(bob2, "CHAT_MSG_ADDON", "OverlordGF", "R:1:i", "WHISPER", "Eve Dark")
    assert(bob2.GF:GetApplyStatus(key(alice)) == "sent" and bob2.GF:SignupCooldownRemaining() == 0)
end

-- ---------------------------------------------------------------------------
-- 10. Channel not joined, budget spent, Blizzard refusal
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    alice.channelId = nil
    assert(alice.GF:Publish(spec()))
    advance(25)
    assert(#log == 0 and alice.GF.own.state == "channel")
    alice.channelId = 7
    advance(11)
    assert(#sentBy(alice, "CHANNEL") == 1 and alice.GF.own.state == "live")

    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.token = false
    assert(alice.GF:Publish(spec()))
    advance(60)
    assert(#log == 0, "sent without a channel token")
    assert(alice.GF.own.state == "retry" and alice.GF.own.live == nil)
    alice.token = true
    advance(31)
    assert(#sentBy(alice, "CHANNEL") == 1 and alice.GF.own.state == "live")

    -- Our own kill total due within 2 s goes first.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.env.Overlord.Sync._channelKillPending = "x"
    alice.env.Overlord.Sync._channelKillAt = now - 29
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(#log == 0 and alice.tokensTaken == 0, "the kill total must go first")
    alice.env.Overlord.Sync._channelKillPending = nil
    advance(10)
    assert(#sentBy(alice, "CHANNEL") == 1)

    -- Refused by Blizzard (code 8): not published, tried again, never in a tight loop.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.sendResult = 8
    assert(alice.GF:Publish(spec()))
    advance(120)
    assert(alice.GF.own.live == nil)
    local attempts = #log
    assert(attempts >= 5 and attempts <= 12, attempts .. " attempts in two minutes")
    alice.sendResult = nil
    advance(31)
    assert(alice.GF.own.live == true and alice.GF.own.state == "live")
end

-- ---------------------------------------------------------------------------
-- 10b. Head-count changes: no retry storm, slower on a busy board; a full board
-- ---------------------------------------------------------------------------
do
    -- Refused while the roster keeps moving: the backoff holds (never one try per event).
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    assert(alice.GF:Publish(spec()))
    advance(25)
    alice.sendResult = 8
    alice.group = { size = 2, raid = false, leader = true, members = {} }
    local before = #log
    for _ = 1, 60 do
        alice.group.size = alice.group.size % 30 + 2
        fire(alice, "GROUP_ROSTER_UPDATE")
        advance(2)
    end
    local attempts = #log - before
    assert(attempts >= 4 and attempts <= 12, attempts .. " refused attempts in two minutes of roster changes")

    -- A new head count waits a third of the re-send interval on a busy board.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 1, 60 do
        local a, b = (i - 1) % 26 + 1, math.floor((i - 1) / 26) + 1
        alice.GF:OnListing("L:1:A:h:w::10:3:0:1:2:60:600", "Lead" .. letters:sub(b, b) .. " Ray" .. letters:sub(a, a))
    end
    assert(alice.GF:HeartbeatInterval() == 197.5)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    alice.group = { size = 3, raid = false, leader = true, members = {} }
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(60)
    assert(#sentBy(alice, "CHANNEL") == 1, "busy board: the head count left after 20 s")
    advance(8)
    local sends = sentBy(alice, "CHANNEL")
    assert(#sends == 2 and sends[2].text:find(":40:3:", 1, true), "head count not sent after a third of the interval")

    -- Full board: a group with room takes the row of a full one, a full group waits,
    -- and the row the player signed up to is never the one taken.
    reset()
    local bob = newClient("Bob Stone", "Alliance")
    local function hear(text, sender) fire(bob, "CHAT_MSG_ADDON", "OverlordGF", text, "CHANNEL", sender) end
    hear("L:1:A:a:w::5:5:0:1:1:60:600", "Full One")
    hear("L:1:A:a:w::5:5:0:1:1:60:600", "Full Two")
    for i = 1, bob.GF.BOARD_MAX - 2 do
        local a, b = (i - 1) % 26 + 1, math.floor((i - 1) / 26) + 1
        hear("L:1:A:h:w::10:3:0:1:2:60:600", "Open" .. letters:sub(b, b) .. " Row" .. letters:sub(a, a))
    end
    assert(bob.GF.boardCount == bob.GF.BOARD_MAX)
    bob.GF.apply = { key = "full one", name = "Full One", at = now, sentAt = now, status = "pending" }
    hear("L:1:A:a:w::5:5:0:1:1:60:600", "Late Full")
    assert(not bob.GF.board["late full"] and bob.GF.boardCount == bob.GF.BOARD_MAX, "a full group took a row")
    hear("L:1:A:a:w::10:2:0:1:1:60:600", "Late Open")
    assert(bob.GF.board["late open"] and bob.GF.boardCount == bob.GF.BOARD_MAX)
    assert(bob.GF.board["full one"] and not bob.GF.board["full two"], "the wrong row was taken")
    hear("L:1:A:a:w::10:2:0:1:1:60:600", "Late Again")
    assert(not bob.GF.board["late again"], "an open group or the signed-up row was evicted")
end

-- ---------------------------------------------------------------------------
-- 11. Instances: nothing sent, read, invited or scheduled
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", "Alliance")
    local bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ auto = true })))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    -- Bob walks into an instance before the answer.
    bob.inInstance = true
    bob.GF:OnInstanceSuspend()
    assert(bob.GF.apply == nil and bob.GF.boardCount == 0 and not bob.GF.ticker)
    for _, event in ipairs(bob.GF.EVENTS) do
        assert(not bob.GF.frame.events[event], event .. " still registered in an instance")
    end
    deliver()
    assert(bob.GF.boardCount == 0, "a message was read in an instance")
    local ok, reason = bob.GF:Publish(spec())
    assert(not ok and reason == "GF_ERR_INSTANCE")
    assert(not bob.GF:SignUp(key(alice)))
    -- The flag alone (set by Core after the hook) is enough too.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    assert(alice.GF:Publish(spec({ auto = true })))
    advance(0.3)
    local sent = #log
    alice.env.Overlord.InstanceSuspended = true
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Bob Stone")
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(400)
    assert(#log == sent and #alice.invites == 0, "the leader acted from an instance")
    -- Out again: events back, the board refills from the next re-send.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    bob = newClient("Bob Stone", "Alliance")
    bob.inInstance = true
    bob.GF:OnInstanceSuspend()
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF.boardCount == 0)
    bob.inInstance = false
    bob.GF:OnInstanceResume()
    advance(61)
    assert(bob.GF.boardCount == 1, "board not refilled after the instance")
end

-- ---------------------------------------------------------------------------
-- 12. Reload: the listing comes back within two minutes, not after
-- ---------------------------------------------------------------------------
do
    reset()
    local db = {}
    local alice = newClient("Alice Smith", "Alliance", { db = db })
    assert(alice.GF:Publish(spec({ cap = 20, minLevel = 40, auto = true })))
    advance(100)
    fire(alice, "PLAYER_LOGOUT")
    assert(db.groupFinder.own and db.groupFinder.own.by == "Alice Smith")
    clients = {}
    local again = newClient("Alice Smith", "Alliance", { db = db })
    advance(30)
    fire(again, "PLAYER_ENTERING_WORLD")
    advance(10)
    local own = again.GF.own
    assert(own and own.cap == 20 and own.minLevel == 40 and own.auto == true and own.intent == "a",
        "listing not restored after a reload")
    assert(#sentBy(again, "CHANNEL") == 1)
    local form = again.GF:GetForm()
    assert(form.cap == 20 and form.target == "stromgarde" and form.auto == true, "last choices not kept")

    fire(again, "PLAYER_LOGOUT")
    clients = {}
    local late = newClient("Alice Smith", "Alliance", { db = db })
    advance(200)
    fire(late, "PLAYER_ENTERING_WORLD")
    advance(10)
    assert(late.GF.own == nil and db.groupFinder.own == nil, "a stale listing was restored")
    -- The full name is not readable yet after the loading screen: the restore looks again.
    db.groupFinder.own = { intent = "a", kind = "w", target = "", cap = 10, minLevel = 0,
        by = "Alice Smith", at = 1700000000 + math.floor(now) }
    clients = {}
    local slow = newClient("Alice Smith", "Alliance", { db = db })
    slow.nameUnknown = true
    fire(slow, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(slow.GF.own == nil and db.groupFinder.own, "restored, or dropped, without knowing who plays")
    slow.nameUnknown = false
    advance(7)
    assert(slow.GF.own and slow.GF.own.cap == 10, "the listing was not restored at the second look")
    assert(slow.GF:Unpublish("user"))
    -- Never readable: three looks, then the record is dropped.
    db.groupFinder.own = { intent = "a", kind = "w", target = "", cap = 10, minLevel = 0,
        by = "Alice Smith", at = 1700000000 + math.floor(now) }
    clients = {}
    local blind = newClient("Alice Smith", "Alliance", { db = db })
    blind.nameUnknown = true
    fire(blind, "PLAYER_ENTERING_WORLD")
    advance(13)
    assert(db.groupFinder.own, "given up before the third look")
    advance(7)
    assert(blind.GF.own == nil and db.groupFinder.own == nil, "a record nobody can claim was kept")
    -- Another character of the account never inherits it.
    db.groupFinder.own = { intent = "a", kind = "w", target = "", cap = 10, minLevel = 0,
        by = "Alice Smith", at = 1700000000 + math.floor(now) }
    clients = {}
    local alt = newClient("Zed Other", "Alliance", { db = db })
    fire(alt, "PLAYER_ENTERING_WORLD")
    advance(10)
    assert(alt.GF.own == nil)
end

-- ---------------------------------------------------------------------------
-- 12b. What the window is told about the channel; the stalled automatic listing
-- ---------------------------------------------------------------------------
do
    -- Not inside yet: connecting. Inside: listening for a minute and a half, then open.
    reset()
    local bob = newClient("Bob Stone", "Alliance")
    bob.channelId = nil
    assert(bob.GF:ChannelState() == "connecting")
    advance(40)
    assert(bob.GF:ChannelState() == "connecting")
    bob.channelId = 5
    local state, left = bob.GF:ChannelState()
    assert(state == "listening" and left == 90, "listening must start when the channel is joined: " .. tostring(left))
    advance(89)
    assert(bob.GF:ChannelState() == "listening")
    advance(2)
    assert(bob.GF:ChannelState() == "open")
    -- Already inside at login: bounded, a window opened late does not start a new wait.
    reset()
    bob = newClient("Bob Stone", "Alliance")
    advance(100)
    state, left = bob.GF:ChannelState()
    assert(state == "listening" and left == 50, "a window opened late listens for " .. tostring(left))
    advance(51)
    assert(bob.GF:ChannelState() == "open")
    advance(600)
    assert(bob.GF:ChannelState() == "open", "an old session started listening again")
    -- Out and in again: listens again; an instance too.
    bob.channelId = nil
    assert(bob.GF:ChannelState() == "connecting")
    bob.channelId = 5
    assert(bob.GF:ChannelState() == "listening")
    bob.inInstance = true
    bob.GF:OnInstanceSuspend()
    assert(bob.GF._listenUntil == nil)
    bob.inInstance = false
    bob.GF:OnInstanceResume()
    state, left = bob.GF:ChannelState()
    assert(state == "listening" and left == 150)
    -- Refused by the game: closed comes first, and nothing is published into it.
    bob.channelId, bob.channelClosed = nil, true
    assert(bob.GF:ChannelState() == "closed")
    local okPublish, whyNot = bob.GF:Publish(spec())
    assert(not okPublish and whyNot == "GF_LIVE_CLOSED" and bob.GF.own == nil, "a listing was published into a closed channel")
    bob.channelId = 5            -- inside after all: the refusal no longer counts
    assert(bob.GF:ChannelState() ~= "closed" and bob.GF:Publish(spec()))
    -- A Sync without the accessor (another build of the fixture) is simply "not closed".
    bob.env.Overlord.Sync.IsChannelClosed = nil
    assert(bob.GF:ChannelState() ~= "closed")

    -- An automatic listing stalled at five: the leader reads what unblocks it, once.
    local function stalled(size, raid, auto)
        reset()
        local alice = newClient("Alice Smith", "Alliance")
        alice.group = { size = size, raid = raid, leader = true, members = {} }
        assert(alice.GF:Publish(spec({ cap = 40, auto = auto })))
        advance(0.3)
        fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
        return alice
    end
    local alice = stalled(5, false, true)
    assert(#alice.GF.pending == 1 and #alice.printed == 1)
    assert(alice.printed[1]:find("convert to raid", 1, true), "the leader is not told to convert: " .. alice.printed[1])
    advance(25)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Zed Other")
    assert(#alice.printed == 2 and alice.printed[2]:find("Zed Other", 1, true), "the raid sentence was said twice")
    -- Not for a party below five, a raid, or a leader who approves by hand.
    alice = stalled(5, false, false)
    assert(#alice.printed == 1 and alice.printed[1]:find("Eve Dark", 1, true))
    alice = stalled(5, true, true)
    assert(#alice.printed == 0 and #alice.invites == 1)
    alice = stalled(3, false, true)
    assert(#alice.printed == 0 and #alice.invites == 1)
    -- Four members and one invitation still open: the request waits, but the party is
    -- not five yet, so the usual line is said.
    reset()
    alice = newClient("Alice Smith", "Alliance")
    alice.group = { size = 4, raid = false, leader = true, members = {} }
    assert(alice.GF:Publish(spec({ cap = 40, auto = true })))
    advance(0.3)
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Eve Dark")
    fire(alice, "CHAT_MSG_ADDON", "OverlordGF", "J:1:A:a:z:stromgarde:1:60", "WHISPER", "Zed Other")
    assert(#alice.invites == 1 and #alice.GF.pending == 1)
    assert(#alice.printed == 1 and alice.printed[1]:find("Zed Other", 1, true), "the raid sentence for a party of four")
    -- Never in a raid, whatever made the request wait.
    alice = stalled(5, false, true)
    alice.printed = {}
    alice.GF.own.raidTold, alice.GF._notifiedAt = nil, nil
    alice.group.raid = true
    alice.GF:NotifyApplicant({ key = "new one", name = "New One", level = 60 }, now + 100)
    assert(#alice.printed == 1 and alice.printed[1]:find("New One", 1, true), "the raid sentence in a raid")
end

-- ---------------------------------------------------------------------------
-- 13. Views: order of the board, places
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone", "Alliance", { level = 30 })
    bob.continent = "EK"
    local function hear(text, sender)
        fire(bob, "CHAT_MSG_ADDON", "OverlordGF", text, "CHANNEL", sender)
    end
    hear("L:1:A:a:z:stromgarde:40:12:0:1:1:60:150", "Near Open")
    hear("L:1:A:a:z:ash_outpost_east:40:30:0:1:1:60:150", "Far Open")
    hear("L:1:A:a:z:stromgarde:5:5:0:1:1:60:150", "Near Full")
    hear("L:1:A:d:f:arathi:40:20:40:1:1:60:150", "Near High")
    hear("L:1:A:h:w::10:2:0:1:1:60:150", "Any Where")
    hear("L:1:A:a:o:stonetalon:20:6:0:0:1:60:150", "Keep Raid")
    local out = { "stale", "stale", "stale", "stale", "stale", "stale", "stale", "stale" }
    local count, players = bob.GF:FillBoard(out)
    assert(count == 6 and #out == 6 and players == 75)
    local order = {}
    for i, entry in ipairs(out) do order[i] = entry.name end
    -- Joinable on my continent (fullest first), joinable elsewhere, then the closed ones.
    assert(table.concat(order, ",") == "Near Open,Keep Raid,Any Where,Far Open,Near High,Near Full",
        table.concat(order, ","))
    assert(bob.GF.board["keep raid"].info.name == "Keep of stonetalon" and bob.GF.board["keep raid"].info.site)
    assert(bob.GF.board["any where"].info.name == "Anywhere")
    -- A click on a row: the waypoint is set, never toggled, and nothing is said in chat
    -- (points and outposts alike); "anywhere" and a whole front have no waypoint.
    local calls = {}
    bob.env.Overlord.MapMarkers = {
        SetUserWaypointForFrontZone = function(_, zone, frontId, opts)
            calls[#calls + 1] = { "zone", zone, frontId, opts }
            return true
        end,
        SetUserWaypointForOutpostSite = function(_, site, opts)
            calls[#calls + 1] = { "site", site, nil, opts }
            return true
        end,
    }
    assert(bob.GF:ShowOnMap(bob.GF.board["near open"].info) and bob.GF:ShowOnMap(bob.GF.board["keep raid"].info))
    assert(not bob.GF:ShowOnMap(bob.GF.board["any where"].info) and not bob.GF:ShowOnMap(bob.GF.board["near high"].info))
    assert(#calls == 2 and calls[1][1] == "zone" and calls[1][3] == "arathi" and calls[2][1] == "site")
    for _, call in ipairs(calls) do
        assert(call[4] and call[4].noToggle and call[4].silent, "a row click toggles the waypoint or speaks in chat")
    end
    assert(bob.GF.board["near high"].info.name == "Arathi Highlands")
    -- An unchanged re-send changes nothing the window would repaint.
    advance(10)
    local revision = bob.GF.revision
    hear("L:1:A:a:z:stromgarde:40:12:0:1:1:60:150", "Near Open")
    assert(bob.GF.revision == revision, "an unchanged listing asked for a repaint")
    hear("L:1:A:a:z:stromgarde:40:13:0:1:1:60:150", "Far Open")
    assert(bob.GF.revision == revision + 1)
end

-- ---------------------------------------------------------------------------
-- 14. Transport stays the faction channel and whispers, on its own prefix
-- ---------------------------------------------------------------------------
do
    local source = assert(io.open("GroupFinder.lua", "r")):read("*a")
    for _, word in ipairs({ "Relay", "BroadcastToRelay", "SendToBNet", "BNSend", "SendToGroup",
        "SendSyncRequest", "SendToNamedPeers", '"RAID"', '"PARTY"', '"GUILD"', '"SAY"', '"YELL"',
        "TakeChannelToken%(true%)", "AcceptGroup", "LeaveParty", "UninviteUnit" }) do
        assert(not source:find(word), "GroupFinder.lua must not use " .. word)
    end
    assert(source:find('GF.PREFIX = "OverlordGF"', 1, true))
    assert(source:find("securecall(C_ChatInfo.SendAddonMessage, self.PREFIX", 1, true))
end

-- ---------------------------------------------------------------------------
-- 15. Texts: 7 languages, same keys, same format slots, really translated
-- ---------------------------------------------------------------------------
do
    local function load(loc)
        Overlord = { L = {} }
        GetLocale = function() return loc end
        assert(loadfile("GroupFinderLocales.lua"))()
        return Overlord.L
    end
    local function slots(text)
        local list = {}
        for slot in text:gmatch("%%[ds]") do list[#list + 1] = slot end
        return table.concat(list)
    end
    local english = load("enUS")
    local keyCount = 0
    for k, v in pairs(english) do
        keyCount = keyCount + 1
        assert(k:match("^[A-Z_]+$"), "key name " .. k)
        assert(type(v) == "string" and v ~= "", "empty " .. k)
    end
    assert(keyCount >= 70, "only " .. keyCount .. " keys")
    for _, loc in ipairs({ "frFR", "esES", "esMX", "deDE", "ruRU", "ptBR", "zhCN", "zhTW" }) do
        local L = load(loc)
        local same = 0
        for k, v in pairs(english) do
            assert(type(L[k]) == "string" and L[k] ~= "", loc .. " misses " .. k)
            assert(slots(L[k]) == slots(v), loc .. ": format slots of " .. k .. " differ")
            if L[k] == v then same = same + 1 end
        end
        for k in pairs(L) do assert(english[k], loc .. " has an extra key " .. k) end
        assert(same <= 2, loc .. " still shows " .. same .. " English lines")
        assert(L.HELP_GROUPS:find("/ov groups", 1, true), loc .. ": help line lost its command")
        assert(L.GF_CHAT_APPLICANT:find("/ov groups", 1, true))
    end
    -- Every text key the code asks for exists.
    for _, file in ipairs({ "GroupFinder.lua", "GroupFinderUI.lua" }) do
        local source = assert(io.open(file, "r")):read("*a")
        for k in source:gmatch('"(GF_[A-Z_]+)"') do
            assert(english[k], file .. " uses the unknown text key " .. k)
        end
    end
    Overlord, GetLocale = nil, nil
end

-- ---------------------------------------------------------------------------
-- 16. Wiring: manifest, instance cut-off, command, panel button, CI lists
-- ---------------------------------------------------------------------------
do
    local function read(path) return assert(io.open(path, "r")):read("*a"):gsub("\r", "") end
    local toc = read("Overlord.toc")
    local function at(name) return assert(toc:find("\n" .. name .. "\n", 1, true), name .. " not in the manifest") end
    assert(at("FrontLocales.lua") < at("GroupFinderLocales.lua"))
    assert(at("GroupFinderLocales.lua") < at("Core.lua"))
    assert(at("UIShared.lua") < at("GroupFinder.lua") and at("GroupFinder.lua") < at("GroupFinderUI.lua"))
    assert(at("GroupFinderUI.lua") < at("Commands.lua"))

    local core = read("Core.lua")
    local hook = core:find("pcall(self.GroupFinder.OnInstanceSuspend, self.GroupFinder)", 1, true)
    local flag = core:find("\n    self.InstanceSuspended = true\n    -- Remet le flag de zone", 1, true)
    assert(hook and flag and hook < flag, "the finder must be cut before the instance flag is set")
    assert(core:find("pcall(Overlord.GroupFinder.OnInstanceResume, Overlord.GroupFinder)", 1, true))
    assert(core:find("self.GroupFinderUI:IsShown() then self.GroupFinderUI:Hide() end", 1, true))

    local commands = read("Commands.lua")
    assert(commands:find('cmd == "groups" or cmd == "group"', 1, true))
    assert(commands:find("if L.HELP_GROUPS then Overlord:PrintNotification(L.HELP_GROUPS) end", 1, true))

    local ui = read("UI.lua")
    assert(ui:find('groupsBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 4, ActionGridRowY(1))', 1, true))
    assert(ui:find("if Overlord.GroupFinderUI then Overlord.GroupFinderUI:Toggle() end", 1, true))
    assert(ui:find("panelOpen(zoneListFrame.groupsBtn, nextState.groups)", 1, true))

    for _, workflow in ipairs({ ".github/workflows/validate.yml", ".github/workflows/release.yml" }) do
        local text = read(workflow)
        assert(text:find("lua5.1 tests/forever_group_finder.test.lua", 1, true), workflow .. " misses the finder test")
        assert(text:find("lua5.1 tests/forever_group_finder_ui.test.lua", 1, true), workflow .. " misses the window test")
        assert(text:find("lua5.1 tests/forever_join_chain.test.lua", 1, true), workflow .. " misses the join test")
    end
end

print("forever_group_finder: ok")
