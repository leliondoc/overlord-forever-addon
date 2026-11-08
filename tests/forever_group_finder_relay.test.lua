-- PvP group finder by hand (relay mode): the channel refuses addon messages, the
-- listings go by whisper among the channel directory's contacts. Real GroupFinder.lua,
-- several clients on one bus (one environment per client, one shared clock), a small
-- directory stand-in per client (IsActive, IsContact, partners, names, chain).
-- Covers the mode, the leader's copies and their pace, the hands (limit, dedup, gap),
-- the caps and the bucket, the pull and its bounds, expiry, withdrawal, own echoes,
-- the invitation error, the restore after a reload, the instance cut-off and the cost.

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

local function deliver()
    local guard = 0
    while bus[1] do
        guard = guard + 1
        assert(guard < 20000, "message storm on the bus")
        local msg = table.remove(bus, 1)
        for _, client in ipairs(clients) do
            -- (The guild: every member online but the sender, as the game does.)
            if client ~= msg.from and client.prefix == msg.prefix and ((msg.chatType == "WHISPER"
                and client.name:lower() == tostring(msg.target):lower())
                or (msg.chatType == "GUILD" and client.guild and client.guild == msg.from.guild)) then
                fire(client, "CHAT_MSG_ADDON", msg.prefix, msg.text, msg.chatType, msg.from.name)
            end
        end
    end
end

local function advance(seconds)
    deliver()
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
        if best.period then best.at = best.at + best.period else best.cancelled = true end
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

local zones = { stromgarde = { id = "stromgarde", name = "Stromgarde" } }
local fronts = { Registry = { arathi = { id = "arathi", mapName = "Arathi Highlands", dropdownLabel = "Arathi",
    preferredMapID = 1417, zones = { zones.stromgarde } } } }
function fronts:GetZone(id)
    if id == "stromgarde" then return zones.stromgarde, self.Registry.arathi end
    return nil
end
function fronts:IsKnownZoneId(id) return self:GetZone(id) ~= nil end

local function canonical(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("%-.*$", "")
    if name:match("^%a+ %a+$") then return name end
    return nil
end

local function newClient(name, opts)
    opts = opts or {}
    local client = { name = name, faction = opts.faction or "Alliance", level = 60, guild = opts.guild,
        group = { size = 0, raid = false, leader = false, members = {} },
        invites = {}, printed = {}, frames = {}, db = opts.db or {} }
    local dir = { names = {}, partners = {}, active = true, CHAIN_BURST = 30, CHAIN_RATE = 0.75,
        chain = { tokens = 30 } }
    function dir:IsActive() return self.active end
    function dir:IsContact(n)
        local row = type(n) == "string" and self.partners[n:lower()] or nil
        return row ~= nil and row.chainAt ~= nil
    end
    for i = 1, opts.listSize or 10 do dir.names[i] = "Listed Name" end
    client.dir = dir
    local env = setmetatable({}, { __index = _G })
    env.GetTime = function() return now end
    env.GetServerTime = function() return 1700000000 + math.floor(now) end
    env.time = env.GetServerTime
    env.IsInInstance = function() return client.inInstance and true or false end
    env.IsInGuild = function() return client.guild ~= nil end
    env.IsInGroup = function() return client.group.size > 0 end
    env.IsInRaid = function() return client.group.size > 0 and client.group.raid end
    env.UnitIsGroupLeader = function() return client.group.size > 0 and client.group.leader end
    env.GetNumGroupMembers = function() return client.group.size end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.UnitIsAFK = function() return false end
    env.securecall = function(fn, ...) return fn(...) end
    env.canaccessvalue = function() return true end
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
            local entry = { from = client, prefix = prefix, text = text, chatType = chatType, target = target, at = now }
            log[#log + 1] = entry
            if client.sendResult ~= nil then
                entry.refused = true
                return client.sendResult
            end
            bus[#bus + 1] = entry
            return 0
        end,
    }
    env.C_PartyInfo = {
        InviteUnit = function(target)
            if client.inviteError then error("Invite refused by the game") end
            client.invites[#client.invites + 1] = target
        end,
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
        PlayerFaction = client.faction, InstanceSuspended = false, L = {},
        PrintNotification = function(_, text) client.printed[#client.printed + 1] = text end,
        SafeUnitLevel = function() return client.level end,
        Fronts = fronts, ChannelDirectory = dir,
        Sync = {
            GetPlayerFullName = function() return client.name end,
            CanonicalForeverName = function(_, n) return canonical(n) end,
            IsSenderLocalPlayer = function(_, sender) return canonical(sender) == client.name end,
            IsValidWhisperTarget = function(_, target) return canonical(target) ~= nil end,
            _RememberRecentAddonWhisper = function() end,
            -- The server refuses the channel: no channel id, closed.
            GetChannelId = function() return client.channelId end,
            IsChannelClosed = function() return not client.channelId end,
            TakeChannelToken = function() return true end,
            NoteChannelSendKind = function() end,
            SendAddonChecked = function(_, msg, chatType, target, prefix)
                local result = env.C_ChatInfo.SendAddonMessage(prefix, msg, chatType, target)
                return result == nil or result == true or result == 0
            end,
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
    local boot = client.frames[1]
    boot.handler(boot, "PLAYER_LOGIN")
    clients[#clients + 1] = client
    return client
end

-- Contacts both ways (each greeted the other under 2.2.0).
local function link(a, b)
    a.dir.partners[b.name:lower()] = { name = b.name, chainAt = now }
    b.dir.partners[a.name:lower()] = { name = a.name, chainAt = now }
    a.GF._contacts, b.GF._contacts = nil, nil
end

local function contactName(client, name)
    client.dir.partners[name:lower()] = { name = name, chainAt = now }
    client.GF._contacts = nil
end

local function sent(from, pattern, to)
    local list = {}
    for _, entry in ipairs(log) do
        if (not from or entry.from == from) and entry.chatType == "WHISPER" and not entry.refused
            and (not pattern or entry.text:find(pattern)) and (not to or entry.target == to.name) then
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

local function rev() return math.floor(now) % 1000000 end
local function G(hand, leader, r, count, cap)
    return string.format("G:1:%d:%s:%d:A:a:z:stromgarde:%d:%d:0:0:1:60:1140", hand, leader, r, cap or 40, count or 3)
end
local function hear(client, text, sender)
    client.GF:OnAddonMessage(text, "WHISPER", sender)
end
local function key(client) return client.name:lower() end

-- ---------------------------------------------------------------------------
-- 1. Mode: waits without a contact, publishes by hand with one, never "unavailable"
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob = newClient("Alice Smith"), newClient("Bob Stone")
    assert(alice.GF:Mode() == "wait" and alice.GF:ChannelState() == "connecting")
    assert(alice.GF:CheckPublish(), "publishing refused while the contacts are coming")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(#sent(alice) == 0 and alice.GF.own.state == "channel", "something left without a contact")
    link(alice, bob)
    assert(alice.GF:Mode() == "relay" and alice.GF:ChannelState() == "open")
    advance(15)
    local copies = sent(alice, "^G:")
    assert(#copies == 1 and copies[1].target == "Bob Stone" and copies[1].prefix == "OverlordGF")
    assert(copies[1].text == "G:1:1:Alice Smith:" .. 1015 .. ":A:a:z:stromgarde:40:1:0:0:1:60:1140",
        "wire format changed: " .. copies[1].text)
    assert(#copies[1].text <= 160)
    assert(alice.GF.own.state == "live" and alice.GF.own.spreadLive)
    local entry = bob.GF.board[key(alice)]
    assert(entry and entry.via == "hand" and entry.rev == 1015 and entry.name == "Alice Smith")
    assert(math.abs(entry.expires - (now + 1140 - 0.1)) < 0.01, "lifetime of a copy by hand: " .. tostring(entry.expires - now))
    -- Bob has no other contact: nothing is passed on, nothing answers.
    assert(#log == 1, "a listing by hand made " .. (#log - 1) .. " other message(s)")
    -- The directory switched off (the channel carries again or never failed): the channel
    -- rules come back, and "unavailable" only says the channel's own refusal.
    alice.dir.active = false
    assert(alice.GF:Mode() == "channel" and alice.GF:ChannelState() == "closed")
    alice.dir.active = true

    -- Pace: unchanged, a copy every second turn (16 min); the row never runs out meanwhile.
    advance(500)
    assert(#sent(alice, "^G:") == 1, "an unchanged listing went again after one turn")
    advance(480)
    assert(#sent(alice, "^G:") == 2, "an unchanged listing missed its second turn")
    assert(bob.GF.boardCount == 1 and bob.GF.board[key(alice)].rev > 1015)
    -- A new member waits for the next turn; full is told at once (120 s after the last copy).
    local m1 = newClient("Mia One")
    alice.group = { size = 2, raid = false, leader = true, members = { [key(m1)] = true } }
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(60)
    assert(#sent(alice, "^G:") == 2, "a head count left before its turn")
    advance(430)
    assert(#sent(alice, "^G:") == 3 and bob.GF.board[key(alice)].count == 2, "the next turn carries the new count")
    assert(alice.GF:Unpublish())
    assert(alice.GF:Publish(spec({ cap = 5 })))
    advance(1)
    local before = #sent(alice, "^G:")
    alice.group.size = 5
    fire(alice, "GROUP_ROSTER_UPDATE")
    advance(100)
    assert(#sent(alice, "^G:") == before, "full went before HAND_CHANGE_GAP")
    advance(25)
    assert(#sent(alice, "^G:") == before + 1 and bob.GF.board[key(alice)].count == 5, "full was not told")
end

-- ---------------------------------------------------------------------------
-- 2. Hands: three at most, each copy once, one copy of a leader per 120 s passed on
-- ---------------------------------------------------------------------------
do
    reset()
    local a, b, c, d, e = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Carl Reed"),
        newClient("Dina Vale"), newClient("Eric Moss")
    link(a, b); link(b, c); link(c, d); link(d, e)
    assert(a.GF:Publish(spec()))
    advance(0.3)
    assert(b.GF.board[key(a)] and c.GF.board[key(a)] and d.GF.board[key(a)], "three hands not reached")
    assert(not e.GF.board[key(a)], "a fourth hand was reached")
    assert(#sent(a, "^G:1:1:") == 1 and #sent(b, "^G:1:2:") == 1 and #sent(c, "^G:1:3:") == 1)
    assert(#sent(d, "^G:") == 0, "the third hand passed it on")
    -- A copy arriving at its last hand is never passed on, a hand past three is malformed.
    hear(e, G(3, "Lead Far", rev()), "Dina Vale")
    assert(e.GF.board["lead far"] and #sent(e) == 0)
    hear(e, G(4, "Lead Bad", rev()), "Dina Vale")
    assert(not e.GF.board["lead bad"])
    -- A new listing of the same leader within 120 s: taken by B, not passed on by B.
    local firstRev = c.GF.board[key(a)].rev
    assert(a.GF:Publish(spec({ intent = "d" })))
    advance(0.3)
    assert(b.GF.board[key(a)].intent == "d" and b.GF.board[key(a)].rev ~= firstRev)
    assert(c.GF.board[key(a)].rev == firstRev and #sent(b, "^G:") == 1, "a second copy passed on within the gap")
    advance(125)
    assert(a.GF:Publish(spec({ intent = "h" })))
    advance(0.3)
    assert(c.GF.board[key(a)].intent == "h", "the gap is over: the copy goes on")

    -- Dedup: a triangle carries one copy per contact, no echo.
    reset()
    a, b, c = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Carl Reed")
    link(a, b); link(a, c); link(b, c)
    assert(a.GF:Publish(spec()))
    advance(0.3)
    assert(#sent(nil, "^G:") == 4, "triangle: " .. #sent(nil, "^G:") .. " whispers for one listing")
    assert(b.GF.boardCount == 1 and c.GF.boardCount == 1 and a.GF.boardCount == 0)
    -- Same copy again from a contact: read once.
    local revision = c.GF.revision
    hear(c, sent(a, "^G:", c)[1].text, "Alice Smith")
    assert(c.GF.revision == revision and #sent(c, "^G:") == 1)
end

-- ---------------------------------------------------------------------------
-- 3. Caps: strangers, new rows per sender and per minute, intake, bucket, chain, refusal
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone")
    local letters = "abcdefghijklmnopqrstuvwxyz"
    local function leader(i) return "Lead X" .. letters:sub(i % 26 + 1, i % 26 + 1) .. letters:sub(math.floor(i / 26) + 1, math.floor(i / 26) + 1) end
    -- Not a contact and not the leader: nothing.
    hear(bob, G(2, "Lead Qq", rev()), "Zed Unknown")
    assert(bob.GF.boardCount == 0 and bob.GF.handStats.stranger == 1)
    -- The leader itself, first-hand, needs no contact (as on the channel).
    hear(bob, G(1, "Lead Ww", rev()), "Lead Ww")
    assert(bob.GF.boardCount == 1)
    -- Six new rows a minute from one contact.
    contactName(bob, "Carl Reed")
    for i = 1, 10 do hear(bob, G(2, leader(i), rev()), "Carl Reed") end
    assert(bob.GF.boardCount == 1 + 6, "one sender put " .. (bob.GF.boardCount - 1) .. " rows in a minute")
    advance(61)
    for i = 7, 10 do hear(bob, G(2, leader(i), rev()), "Carl Reed") end
    -- 2.2.2: eight live rows at most brought by one sender.
    assert(bob.GF.boardCount == 1 + bob.GF.HAND_ROWS_PER_GATEWAY, "rows of one sender: " .. (bob.GF.boardCount - 1))
    -- A first hand from anybody but the leader is made up; a rev well ahead of the clock too.
    contactName(bob, "Erin Fox")
    local before = bob.GF.boardCount
    hear(bob, G(1, "Lead Fake", rev()), "Erin Fox")
    hear(bob, G(2, "Lead Ahead", (rev() + 300) % bob.GF.REV_MOD), "Erin Fox")
    assert(bob.GF.boardCount == before and not bob.GF.board["lead fake"] and not bob.GF.board["lead ahead"])
    -- A withdrawal from a contact that did not bring the listing: the row stays.
    hear(bob, "X:1:2:" .. leader(1) .. ":" .. rev(), "Erin Fox")
    assert(bob.GF.board[leader(1):lower()], "a withdrawal by somebody else hid the listing")
    hear(bob, "X:1:2:" .. leader(1) .. ":" .. rev(), "Carl Reed")
    assert(not bob.GF.board[leader(1):lower()], "the hand that brought it withdraws it")
    -- Forty a minute in all.
    advance(61)
    local total = bob.GF.boardCount
    for g = 1, 8 do
        local gate = "Gate " .. ("ABCDEFGH"):sub(g, g) .. "x"
        contactName(bob, gate)
        for i = 1, 6 do hear(bob, G(2, leader(100 + g * 10 + i), rev()), gate) end
    end
    assert(bob.GF.boardCount == total + 40, "new rows in a minute: " .. (bob.GF.boardCount - total))
    -- Twenty messages a minute read from one sender.
    contactName(bob, "Dina Vale")
    for i = 1, 20 do hear(bob, "X:1:2:Lead Nn" .. letters:sub(i, i) .. ":" .. rev(), "Dina Vale") end
    advance(61)
    for i = 1, 20 do hear(bob, "X:1:2:Lead Mm" .. letters:sub(i, i) .. ":" .. rev(), "Dina Vale") end
    hear(bob, G(2, "Lead Late", rev()), "Dina Vale")
    assert(not bob.GF.board["lead late"], "a 21st message of the minute was read")
    advance(61)
    hear(bob, G(2, "Lead Late", rev()), "Dina Vale")
    assert(bob.GF.board["lead late"])
    -- A rev far from our clock is refused (it would hide the leader's next copies).
    hear(bob, G(1, "Lead Ahead", (rev() + 5000) % 1000000), "Lead Ahead")
    assert(not bob.GF.board["lead ahead"])

    -- The bucket: ten at once, then HAND_RATE a second; nothing while the chain is short.
    local GF = bob.GF
    -- (What Bob passed on above came out of it: start full.)
    assert(GF.handStats.forwarded > 0 and #sent(bob, "^G:1:3:") <= 10 + GF.HAND_RATE * 200)
    GF._handTokens, GF._handTokensAt = nil, nil
    assert(GF:TakeHandTokens(20, now) == 10 and GF:TakeHandTokens(1, now) == 0)
    assert(GF:TakeHandTokens(5, now + 8) == math.floor(8 * GF.HAND_RATE))
    advance(60)
    bob.dir.chain.tokens, bob.dir.chain.at = 10, now
    assert(GF:TakeHandTokens(1, now) == 0, "the chain's last tokens were taken")
    bob.dir.chain.at = now - 20
    assert(GF:TakeHandTokens(1, now) == 1, "the chain's refill is not read")

    -- A leader without whisper to spare waits; a refused whisper stops the bucket 30 s.
    reset()
    local alice, carl = newClient("Alice Smith"), newClient("Carl Reed")
    link(alice, carl)
    alice.dir.chain.tokens, alice.dir.chain.at = 5, now
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(#sent(alice) == 0 and alice.GF.own.state == "retry")
    alice.dir.chain.tokens = 30
    advance(31)
    assert(#sent(alice, "^G:") == 1 and alice.GF.own.state == "live")
    alice.sendResult = 3
    assert(alice.GF:Publish(spec({ intent = "d" })))
    advance(0.3)
    assert(alice.GF.handStats.refused == 1 and alice.GF:TakeHandTokens(1, now) == 0, "a refusal did not stop the bucket")
    alice.sendResult = nil
    advance(31)
    assert(alice.GF:TakeHandTokens(1, now) == 1)
end

-- ---------------------------------------------------------------------------
-- 4. Pull: one contact asked, a bounded answer, hearsay never passed on
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob, carl = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Carl Reed")
    -- Bob holds twelve listings, four of them full (heard before he had a contact).
    for i = 1, 12 do
        local name = "Lead " .. ("abcdefghijkl"):sub(i, i) .. "x"
        hear(bob, G(1, name, rev(), i <= 4 and 40 or 3), name)
    end
    assert(bob.GF.boardCount == 12 and #log == 0)
    link(alice, bob); link(alice, carl)
    -- The directory's own view, in its order (used when present).
    alice.dir.ContactView = function() return { "Bob Stone", "Carl Reed" } end
    alice.GF._contacts = nil
    advance(100)
    alice.GF.Random = function() return 0 end
    assert(alice.GF:MaybePull(), "an open window in relay mode asks a contact")
    assert(alice.GF:ChannelState() == "listening")
    assert(#sent(alice, "^Q:1$", bob) == 1)
    advance(0.01)
    local answers = sent(bob, "^B:")
    assert(#answers == 4, "answer messages: " .. #answers)
    for _, msg in ipairs(answers) do
        assert(#msg.text <= 160 and msg.target == "Alice Smith", "answer too long: " .. #msg.text)
        local _, bars = msg.text:gsub("|", "")
        assert(bars <= 1, "more than two listings in one answer")
    end
    assert(alice.GF.boardCount == 8, "rows pulled: " .. alice.GF.boardCount)
    local full = 0
    for _, entry in pairs(alice.GF.board) do
        assert(entry.hearsay and entry.via == "pull")
        assert(math.abs(entry.expires - (now - 100 + 1140)) < 1.5, "a pulled row lives ttl - age")
        if entry.count >= entry.cap then full = full + 1 end
    end
    assert(full == 0, "groups with room come first in an answer")
    assert(#sent(alice, "^G:") == 0, "a pulled row was passed on")
    assert(#sent(carl) == 0)
    -- Asked again within the minute, by a stranger, or past the per-minute cap: silence.
    hear(bob, "Q:1", "Alice Smith")
    hear(bob, "Q:1", "Zed Unknown")
    assert(#sent(bob, "^B:") == 4)
    for i = 1, 7 do
        local asker = "Ask " .. ("abcdefg"):sub(i, i) .. "x"
        contactName(bob, asker)
        hear(bob, "Q:1", asker)
    end
    assert(bob.GF.handStats.answers == 6, "answers in a minute: " .. bob.GF.handStats.answers)
    -- An answer nobody asked for, or too late, is not read.
    local stray = "B:1:Lead Zz:" .. rev() .. ":0:A:a:z:stromgarde:40:3:0:0:1:60:1140"
    hear(alice, stray, "Carl Reed")
    advance(30)
    hear(alice, stray, "Bob Stone")
    assert(not alice.GF.board["lead zz"])
    -- The next look: not within 2 minutes; with rows on the board, after 10.
    assert(not alice.GF:MaybePull())
    advance(200)
    assert(not alice.GF:MaybePull())
    advance(400)
    assert(alice.GF:MaybePull())
    -- An empty board asks again after two minutes.
    advance(121)
    for k in pairs(alice.GF.board) do alice.GF:RemoveEntry(k) end
    assert(alice.GF:MaybePull())
    -- A copy by hand of a pulled row makes it heard (and passed on).
    reset()
    alice, bob, carl = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Carl Reed")
    link(alice, bob); link(alice, carl)
    hear(alice, "B:1:Lead Yy:" .. rev() .. ":5:A:a:z:stromgarde:40:3:0:0:1:60:1140", "Bob Stone")
    assert(not alice.GF.board["lead yy"], "an answer without a question was read")
    alice.GF._pull = { key = "bob stone", at = now, msgs = 0 }
    hear(alice, "B:1:Lead Yy:" .. rev() .. ":5:A:a:z:stromgarde:40:3:0:0:1:60:1140", "Bob Stone")
    assert(alice.GF.board["lead yy"].hearsay)
    hear(alice, G(2, "Lead Yy", rev()), "Bob Stone")
    assert(not alice.GF.board["lead yy"].hearsay and #sent(alice, "^G:1:3:Lead Yy", carl) == 1)
end

-- ---------------------------------------------------------------------------
-- 5. Expiry, withdrawal, own echoes, a sign-up answered "gone"
-- ---------------------------------------------------------------------------
do
    reset()
    local a, b, c = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Carl Reed")
    link(a, b); link(b, c)
    assert(a.GF:Publish(spec()))
    advance(0.3)
    local oldRev = c.GF.board[key(a)].rev
    -- Withdrawn: B is told, B tells C; an older copy stays out.
    assert(a.GF:Unpublish())
    advance(0.1)
    assert(#sent(a, "^X:1:1:Alice Smith:") == 1 and #sent(b, "^X:1:2:Alice Smith:") == 1)
    assert(b.GF.boardCount == 0 and c.GF.boardCount == 0, "the withdrawal did not reach the second hand")
    hear(c, G(2, "Alice Smith", oldRev - 1), "Bob Stone")
    assert(c.GF.boardCount == 0, "a copy older than the withdrawal came back")
    -- Our own listing back from another hand, in a copy or in an answer: never on our board.
    hear(a, G(2, "Alice Smith", rev()), "Bob Stone")
    a.GF._pull = { key = "bob stone", at = now, msgs = 0 }
    hear(a, "B:1:Alice Smith:" .. rev() .. ":5:A:a:z:stromgarde:40:3:0:0:1:60:1140", "Bob Stone")
    assert(a.GF.boardCount == 0, "own echo on the board")

    -- Expiry: the leader gone silent (an instance), its copies die after their lifetime.
    -- (Past B's gap for this leader: the new listing goes on to C.)
    advance(121)
    assert(a.GF:Publish(spec()))
    advance(1)
    assert(c.GF.board[key(a)])
    a.inInstance = true
    advance(1100)
    assert(c.GF.board[key(a)], "a row died before its lifetime")
    advance(60)
    assert(c.GF.boardCount == 0 and b.GF.boardCount == 0, "a row outlived its lifetime")
    -- In an instance nothing is read either.
    fire(a, "CHAT_MSG_ADDON", "OverlordGF", G(1, "Lead Inst", rev()), "WHISPER", "Lead Inst")
    assert(not a.GF.board["lead inst"], "a listing was read in an instance")
    a.inInstance = false

    -- A leader whose withdrawal missed us answers "gone": the row leaves the board.
    reset()
    a, b = newClient("Alice Smith"), newClient("Bob Stone")
    link(a, b)
    assert(a.GF:Publish(spec()))
    advance(0.3)
    a.GF.own = nil
    assert(b.GF:SignUp(key(a)))
    advance(0.1)
    assert(b.GF.apply.status == "gone" and not b.GF.board[key(a)], "a gone listing stayed on the board")
end

-- ---------------------------------------------------------------------------
-- 6. The game's invitation raising an error
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob = newClient("Alice Smith"), newClient("Bob Stone")
    link(alice, bob)
    assert(alice.GF:Publish(spec({ auto = true })))
    advance(0.3)
    alice.inviteError = true
    hear(alice, "J:1:A:a:z:stromgarde:1:60", "Bob Stone")
    assert(alice.GF.outstandingCount == 0 and not alice.GF.invitedAt[key(bob)], "the failed invitation kept its place")
    local app = alice.GF.pendingByKey[key(bob)]
    assert(app and app.manual, "the request did not go back to the list")
    local replies = sent(alice, "^R:1:", bob)
    assert(#replies == 1 and replies[1].text == "R:1:p", "the player was not told to wait")
    assert(alice.printed[#alice.printed]:find("/invite Bob Stone", 1, true))
    -- From the click, failing again: no crash, the place free, the request gone.
    assert(alice.GF:Accept(key(bob)))
    assert(alice.GF.outstandingCount == 0 and #alice.GF.pending == 0)
    alice.inviteError = false
    hear(alice, "J:1:A:a:z:stromgarde:1:60", "Bob Stone")
    advance(11)
    hear(alice, "J:1:A:a:z:stromgarde:1:60", "Bob Stone")
    assert(#alice.invites == 1, "the invitation works again")
end

-- ---------------------------------------------------------------------------
-- 7. A reload: the saved listing waits until it can be published
-- ---------------------------------------------------------------------------
do
    reset()
    local db = { groupFinder = { own = { intent = "a", kind = "z", target = "stromgarde", cap = 40, minLevel = 0,
        auto = false, by = "Alice Smith", at = 1700000000 + 990 } } }
    local alice = newClient("Alice Smith", { db = db })
    local bob = newClient("Bob Stone")
    alice.dir.active = false
    fire(alice, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(not alice.GF.own and db.groupFinder.own, "a refused publish lost the saved listing")
    advance(20)
    assert(not alice.GF.own and db.groupFinder.own)
    alice.dir.active = true
    link(alice, bob)
    advance(10)
    assert(alice.GF.own, "the saved listing was not put back")
    advance(4)
    assert(bob.GF.board[key(alice)])
    -- Too old at the first look: dropped, as before.
    reset()
    db = { groupFinder = { own = { intent = "a", kind = "z", target = "stromgarde", cap = 40, minLevel = 0,
        auto = false, by = "Alice Smith", at = 1700000000 + 800 } } }
    alice = newClient("Alice Smith", { db = db })
    fire(alice, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(not alice.GF.own and db.groupFinder.own == nil)
end

-- ---------------------------------------------------------------------------
-- 8. Cost: one listing on a list of 30 with six contacts each
-- ---------------------------------------------------------------------------
do
    reset()
    local letters = "abcdefghijklmnopqrstuvwxyz"
    local list = {}
    for i = 1, 30 do
        list[i] = newClient("Pl" .. letters:sub(i % 26 + 1, i % 26 + 1) .. " Nm" .. letters:sub(math.floor(i / 26) + 1,
            math.floor(i / 26) + 1), { listSize = 30 })
    end
    -- A ring with chords: i - i+1, i+5, i+11 (six contacts each).
    for i = 1, 30 do
        for _, step in ipairs({ 1, 5, 11 }) do link(list[i], list[(i + step - 1) % 30 + 1]) end
    end
    assert(list[1].GF:Publish(spec()))
    advance(1)
    local whispers, reached = #sent(nil, "^G:"), 0
    for i = 2, 30 do if list[i].GF.boardCount == 1 then reached = reached + 1 end end
    assert(whispers <= 6 + 6 * 4 + 24 * 2, "one listing cost " .. whispers .. " whispers")
    assert(reached >= 20, "one listing reached " .. reached .. " of 29")
    for _, client in ipairs(list) do
        assert(#sent(client) <= 10, client.name .. " spent more than its bucket")
    end
    print(string.format("forever_group_finder_relay: one listing, list of 30: %d whispers, %d/29 reached", whispers, reached))
end

-- ---------------------------------------------------------------------------
-- 9. 2.2.2: players the member list does not show (ghosts) get a copy and may pull; a withdrawal
--    goes to the players that hold the listing
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob, ghost = newClient("Alice Smith"), newClient("Bob Stone"), newClient("Gina Ghost")
    link(alice, bob)
    -- Gina greeted Alice (a leaf for her: no chainAt, not in her list); Alice is a contact for Gina.
    ghost.dir.partners[alice.name:lower()] = { name = alice.name, chainAt = now }
    ghost.GF._contacts = nil
    alice.dir.partners[ghost.name:lower()] = { name = ghost.name, greetedAt = now }
    alice.dir.LeafNames = function() return { ghost.name } end
    alice.dir.IsLeaf = function(_, n) return type(n) == "string" and n:lower() == ghost.name:lower() end
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF.board[key(alice)], "the contact missed the copy")
    assert(ghost.GF.board[key(alice)] and ghost.GF.board[key(alice)].via == "hand", "a leaf got no copy")
    -- (The leaf's copy is the last hand: it keeps it and never passes it on.)
    assert(#sent(alice, "^G:1:1:") == 1 and #sent(alice, "^G:1:3:") == 1,
        "one contact and one leaf: " .. #sent(alice, "^G:1:1:") .. " + " .. #sent(alice, "^G:1:3:") .. " copies")
    -- The leaf passes nothing on to the listed (it is a stranger for them) and costs nothing more.
    bob.dir.partners[ghost.name:lower()] = { name = ghost.name, greetedAt = now }
    assert(#sent(ghost) == 0, "a leaf passed the copy on")
    -- A pull from a leaf is answered; one from a stranger is not.
    local hana = newClient("Hana Leaf")
    hana.dir.partners[alice.name:lower()] = { name = alice.name, chainAt = now }
    hana.GF._contacts = nil
    alice.dir.partners[hana.name:lower()] = { name = hana.name, greetedAt = now }
    alice.dir.IsLeaf = function(_, n) return type(n) == "string" and n:lower() == hana.name:lower() end
    -- (Alice holds a listing of Bob's, by hand.)
    bob.GF:Unpublish()
    hear(alice, G(1, "Bob Stone", rev()), "Bob Stone")
    assert(alice.GF.board["bob stone"], "the pulled listing is missing")
    assert(hana.GF:MaybePull(), "the leaf did not ask")
    advance(2)
    assert(hana.GF.board["bob stone"] and hana.GF.board["bob stone"].via == "pull", "a leaf's pull was not answered")
    local stranger = newClient("Ivan Alien")
    stranger.dir.partners[alice.name:lower()] = { name = alice.name, chainAt = now }
    stranger.GF._contacts = nil
    assert(stranger.GF:MaybePull())
    advance(2)
    assert(not stranger.GF.board["bob stone"], "a stranger's pull was answered")
end

do
    reset()
    local leader = newClient("Lena Lead")
    local others = {}
    for i = 1, 8 do
        others[i] = newClient("Pla" .. string.char(96 + i) .. " Nm" .. string.char(96 + i))
        link(leader, others[i])
    end
    assert(leader.GF:Publish(spec()))
    advance(0.3)
    local holders = {}
    for _, entry in ipairs(sent(leader, "^G:1:1:")) do holders[entry.target] = true end
    local count = 0
    for _ in pairs(holders) do count = count + 1 end
    assert(count == 6, "the first hand: " .. count)
    advance(100) -- (the bucket refills)
    assert(leader.GF:Unpublish())
    advance(0.3)
    local told = {}
    for _, entry in ipairs(sent(leader, "^X:")) do told[entry.target] = true end
    for name in pairs(holders) do assert(told[name], name .. " holds the listing and was not told it is withdrawn") end
    for name in pairs(told) do assert(holders[name], name .. " never had the listing and was told") end
    for _, client in ipairs(others) do
        if holders[client.name] then assert(not client.GF.board[key(leader)], "a holder kept the withdrawn listing") end
    end
end

-- ---------------------------------------------------------------------------
-- 10. 2.2.2: the own copy goes whole or waits (never a few contacts for a whole turn)
-- ---------------------------------------------------------------------------
do
    reset()
    local leader = newClient("Lena Lead")
    local others = {}
    for i = 1, 8 do
        others[i] = newClient("Plb" .. string.char(96 + i) .. " Nm" .. string.char(96 + i))
        link(leader, others[i])
    end
    assert(leader.GF:Publish(spec()))
    advance(0.3)
    assert(#sent(leader, "^G:1:1:Lena Lead:%d+:A:a:") == 6)
    -- An edit right after: four whispers left for a first hand of six.
    assert(leader.GF:Publish(spec({ intent = "d" })))
    advance(0.3)
    assert(#sent(leader, "^G:1:1:Lena Lead:%d+:A:d:") == 0,
        "an edited copy left to " .. #sent(leader, "^G:1:1:Lena Lead:%d+:A:d:") .. " of 6 contacts")
    assert(leader.GF.own.state == "retry")
    -- Meanwhile the bucket refills for the own copy alone (a forward or an answer waits).
    assert(leader.GF:TakeHandTokens(1, now) == 0, "the bucket was spent while the own copy waits")
    advance(60)
    local edited = 0
    for _, client in ipairs(others) do
        local entry = client.GF.board[key(leader)]
        if entry and entry.intent == "d" then edited = edited + 1 end
    end
    assert(edited == 6 and leader.GF.own.state == "live", "the edited copy reached " .. edited .. " of 6")
    assert(not leader.GF._handHoldUntil, "the hold outlived the own copy")
end

-- ---------------------------------------------------------------------------
-- 11. 2.2.2: a withdrawal reaches every holder of the last two copies, short of whispers too,
--     and a listing published right after does not stop it (nor is touched by it)
-- ---------------------------------------------------------------------------
do
    reset()
    local leader = newClient("Lena Lead")
    local others = {}
    for i = 1, 8 do
        others[i] = newClient("Plc" .. string.char(96 + i) .. " Nm" .. string.char(96 + i))
        link(leader, others[i])
    end
    assert(leader.GF:Publish(spec()))
    advance(0.3)
    local own = leader.GF.own
    local oldRev = own.rev
    -- The copy before held by five others (11 holders in all: more than 2 x WITHDRAW_FANS[1]).
    own.heldPrev = { "Hold Aa", "Hold Bb", "Hold Cc", "Hold Dd", "Hold Ee" }
    local holders = {}
    for _, name in ipairs(own.heldLast) do holders[name] = true end
    for _, name in ipairs(own.heldPrev) do holders[name] = true end
    leader.GF._handTokens, leader.GF._handTokensAt = 4, now
    assert(leader.GF:Unpublish())
    assert(leader.GF:Publish(spec({ intent = "h" })))
    advance(200)
    local told = {}
    for _, entry in ipairs(sent(leader, "^X:1:1:Lena Lead:" .. oldRev .. "$")) do
        assert(not told[entry.target], entry.target .. " was told twice")
        told[entry.target] = true
    end
    for name in pairs(holders) do assert(told[name], name .. " holds the listing and was not told it is withdrawn") end
    for name in pairs(told) do assert(holders[name], name .. " never had the listing and was told") end
    -- The new listing (newer rev) stays on the boards it reached.
    local kept = 0
    for _, client in ipairs(others) do
        local entry = client.GF.board[key(leader)]
        if entry and entry.intent == "h" then kept = kept + 1 end
    end
    assert(kept == 6, "the old rev's withdrawal hid the new listing: " .. kept)
end

-- ---------------------------------------------------------------------------
-- 12. 2.2.2: sign-ups waiting when the listing goes (withdrawn) are told "gone"; an edit keeps
-- them waiting with the leader (a "gone" would take the listing off their boards for minutes)
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob = newClient("Alice Smith"), newClient("Bob Stone")
    link(alice, bob)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    advance(0.1)
    assert(bob.GF.apply.status == "pending")
    assert(alice.GF:Publish(spec({ minLevel = 20 })))
    advance(1.5)
    assert(#sent(alice, "^R:1:x$", bob) == 0, "an edit told a waiting applicant the listing is gone")
    local entry = bob.GF.board[key(alice)]
    assert(entry and entry.minLevel == 20, "the replacement listing did not replace the old one")
    assert(bob.GF.apply.status == "pending" and #alice.GF.pending == 1, "an edit dropped the waiting sign-up")
    assert(alice.GF:Unpublish())
    advance(1.5)
    assert(#sent(alice, "^R:1:x$", bob) == 1 and bob.GF.apply.status == "gone", "a withdrawal left the player waiting")
end

-- ---------------------------------------------------------------------------
-- 12b. 2.2.2: an edit to another activity tells the waiting sign-ups "gone" (never invited
-- into a group they did not sign up for); that "gone" leaves the new listing on their boards
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob = newClient("Alice Smith"), newClient("Bob Stone")
    link(alice, bob)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF:SignUp(key(alice)))
    advance(0.1)
    assert(bob.GF.apply.status == "pending")
    assert(alice.GF:Publish(spec({ intent = "h", kind = "f", target = "arathi", cap = 10 })))
    advance(1.5)
    assert(#sent(alice, "^R:1:x$", bob) == 1, "an edit to another activity left the applicant waiting")
    assert(#alice.GF.pending == 0 and bob.GF.apply.status == "gone", "the old activity's sign-up was kept")
    local entry = bob.GF.board[key(alice)]
    assert(entry and entry.intent == "h" and entry.target == "arathi",
        "the old listing's farewell took the new listing off the board")
end

-- ---------------------------------------------------------------------------
-- 13. 2.2.2: a reload keeps the copies' holders; their withdrawal leaves without a contact
-- ---------------------------------------------------------------------------
do
    reset()
    local db = {}
    local alice = newClient("Alice Smith", { db = db })
    local bob = newClient("Bob Stone")
    link(alice, bob)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(bob.GF.board[key(alice)])
    local savedRev = db.groupFinder.own.rev
    assert(savedRev == bob.GF.board[key(alice)].rev and db.groupFinder.own.heldLast[1] == "Bob Stone")
    fire(alice, "PLAYER_LOGOUT")
    -- The reload: the old session is gone, the new one has no contact yet.
    alice.prefix = nil
    for i, client in ipairs(clients) do if client == alice then table.remove(clients, i) break end end
    advance(5)
    local again = newClient("Alice Smith", { db = db })
    fire(again, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(again.GF.own and again.GF:Mode() == "wait", "the saved listing was not put back")
    assert(again.GF:Unpublish())
    advance(1)
    assert(#sent(again, "^X:1:1:Alice Smith:" .. savedRev .. "$", bob) == 1, "the withdrawal after a reload went nowhere")
    assert(not bob.GF.board[key(alice)])
    -- Too old to be put back, still alive on the boards: its holders are told.
    reset()
    db = { groupFinder = { own = { intent = "a", kind = "z", target = "stromgarde", cap = 40, minLevel = 0,
        auto = false, by = "Alice Smith", at = 1700000000 + 700, rev = 700, heldLast = { "Bob Stone" } } } }
    bob = newClient("Bob Stone")
    hear(bob, G(1, "Alice Smith", 700), "Alice Smith")
    assert(bob.GF.board[key(alice)])
    alice = newClient("Alice Smith", { db = db })
    fire(alice, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(not alice.GF.own and db.groupFinder.own == nil)
    assert(#sent(alice, "^X:1:1:Alice Smith:700$", bob) == 1 and not bob.GF.board[key(alice)],
        "a listing dropped at the reload kept its copies")
    -- Another character of the account never withdraws it.
    reset()
    db = { groupFinder = { own = { intent = "a", kind = "z", target = "stromgarde", cap = 40, minLevel = 0,
        auto = false, by = "Alice Smith", at = 1700000000 + 700, rev = 700, heldLast = { "Bob Stone" } } } }
    local other = newClient("Otto Alt", { db = db })
    fire(other, "PLAYER_ENTERING_WORLD")
    advance(7)
    assert(#sent(other) == 0)
end

-- ---------------------------------------------------------------------------
-- 14. 2.2.2: guild mates get the leader's own copy and its withdrawal, never passed on
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith", { guild = "Wolves" })
    local bob = newClient("Bob Stone")
    local gary = newClient("Gary Mate", { guild = "Wolves" })
    local olga = newClient("Olga Other", { guild = "Bears" })
    link(alice, bob)
    contactName(gary, "Bob Stone")
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    local function guildSent(from, pattern)
        local list = {}
        for _, entry in ipairs(log) do
            if entry.from == from and entry.chatType == "GUILD" and entry.text:find(pattern) then list[#list + 1] = entry end
        end
        return list
    end
    assert(#guildSent(alice, "^G:1:3:Alice Smith:") == 1, "one guild copy per spread")
    local entry = gary.GF.board[key(alice)]
    assert(entry and entry.guild and entry.rev == bob.GF.board[key(alice)].rev, "a guild mate missed the listing")
    assert(not olga.GF.board[key(alice)])
    assert(#sent(gary) == 0 and #guildSent(gary, ".") == 0, "a guild copy was passed on")
    -- On the guild only the leader itself, at the last hand.
    gary.GF:OnAddonMessage(G(3, "Lead Fake", rev()), "GUILD", "Mallory Bad")
    gary.GF:OnAddonMessage(G(1, "Lead Ones", rev()), "GUILD", "Lead Ones")
    assert(not gary.GF.board["lead fake"] and not gary.GF.board["lead ones"])
    gary.GF:OnAddonMessage("X:1:3:Alice Smith:" .. entry.rev, "GUILD", "Bob Stone")
    assert(gary.GF.board[key(alice)], "a withdrawal on the guild from somebody else was believed")
    assert(alice.GF:Unpublish())
    advance(0.3)
    assert(#guildSent(alice, "^X:1:3:Alice Smith:") == 1 and not gary.GF.board[key(alice)], "the guild kept a withdrawn listing")
    assert(#sent(gary) == 0)
    -- A guild copy first, the same copy by whisper next: still passed on.
    reset()
    local carl, dina = newClient("Carl Reed"), newClient("Dina Vale")
    link(carl, dina)
    local r = rev()
    carl.GF:OnAddonMessage(G(3, "Lena Lead", r), "GUILD", "Lena Lead")
    assert(carl.GF.board["lena lead"] and #sent(carl) == 0)
    hear(carl, G(1, "Lena Lead", r), "Lena Lead")
    advance(0.1)
    assert(#sent(carl, "^G:1:2:Lena Lead:", dina) == 1 and dina.GF.board["lena lead"],
        "a copy heard on the guild first was not passed on")
end

-- ---------------------------------------------------------------------------
-- 15. 2.2.2: a withdrawal passed on only to those we passed the listing to
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone")
    contactName(bob, "Carl Reed"); contactName(bob, "Dina Vale"); contactName(bob, "Eric Moss")
    local r = rev()
    -- (A last hand: Bob passed it to nobody.)
    hear(bob, G(3, "Lena Lead", r), "Carl Reed")
    assert(bob.GF.board["lena lead"] and #sent(bob) == 0)
    hear(bob, "X:1:1:Lena Lead:" .. r, "Lena Lead")
    assert(not bob.GF.board["lena lead"])
    assert(#sent(bob, "^X:") == 0, "a withdrawal went to " .. #sent(bob, "^X:") .. " contacts that never had it from us")
end

-- ---------------------------------------------------------------------------
-- 16. 2.2.2: a row the leader gave us itself: one contact can neither rewrite nor withdraw it
-- (a second hand bringing the same copy can); a rev far ahead of the clock is refused
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone")
    contactName(bob, "Carl Reed"); contactName(bob, "Dina Vale"); contactName(bob, "Fred Fake")
    local r = rev()
    hear(bob, G(1, "Lena Lead", r, 3), "Lena Lead")
    assert(bob.GF.board["lena lead"] and bob.GF.board["lena lead"].rev == r)
    -- One contact's newer copy is held, its withdrawal refused.
    hear(bob, G(2, "Lena Lead", r + 5, 9), "Fred Fake")
    assert(bob.GF.board["lena lead"].rev == r, "one contact rewrote a row the leader gave us")
    hear(bob, "X:1:2:Lena Lead:" .. (r + 5), "Fred Fake")
    assert(bob.GF.board["lena lead"], "one contact withdrew a row the leader gave us")
    -- Nor in a pull answer.
    bob.GF._pull = { key = "fred fake", at = now, msgs = 0 }
    hear(bob, "B:1:Lena Lead:" .. (r + 4) .. ":5:A:a:z:stromgarde:40:9:0:0:1:60:1140", "Fred Fake")
    assert(bob.GF.board["lena lead"].rev == r, "a pull answer rewrote a row the leader gave us")
    -- The same copy by a second hand: taken (an edit the leader sent by others).
    hear(bob, G(2, "Lena Lead", r + 5, 9), "Dina Vale")
    assert(bob.GF.board["lena lead"].rev == r + 5, "an edit brought by two hands was refused")
    -- The leader's own withdrawal: always.
    hear(bob, "X:1:1:Lena Lead:" .. (r + 6), "Lena Lead")
    assert(not bob.GF.board["lena lead"], "the leader's withdrawal was refused")
    -- A rev 30 s ahead of the clock (it would hide the leader's next copies): refused.
    hear(bob, G(2, "Mia Lead", rev() + 30), "Carl Reed")
    assert(not bob.GF.board["mia lead"], "a rev far ahead of the clock was taken")
    hear(bob, G(2, "Mia Lead", rev() + 3), "Carl Reed")
    assert(bob.GF.board["mia lead"], "a rev a few seconds ahead was refused")
end

-- ---------------------------------------------------------------------------
-- 17. 2.2.2: an edited listing goes first to those holding the leader's own copy (one other
-- hand alone would not replace it on their boards)
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith")
    local others = {}
    for i = 1, 12 do
        others[i] = newClient("Mate " .. string.char(96 + i) .. "x")
        link(alice, others[i])
    end
    for i = 1, 12 do link(others[i], others[i % 12 + 1]) end
    -- (A real draw: each spread picks other contacts.)
    local seed = 7
    alice.GF.Random = function() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    assert(alice.GF:Publish(spec()))
    advance(1)
    local holders = {}
    for _, c in ipairs(others) do
        local row = c.GF.board[key(alice)]
        if row and row.firstHand then holders[#holders + 1] = c end
    end
    assert(#holders > 0 and #holders < 12, "fixture: first-hand holders " .. #holders)
    advance(60)
    assert(alice.GF:Publish(spec({ minLevel = 20 })))
    advance(60)
    for _, c in ipairs(holders) do
        local row = c.GF.board[key(alice)]
        assert(row and row.minLevel == 20, c.name .. " kept the listing before its edit")
    end
end

-- ---------------------------------------------------------------------------
-- 18. A pull answer is bounded per contact: a made-up board cannot fill ours, an honest one
-- (PULL_ROWS an answer) is taken whole, and hearsay never evicts a hand row
-- ---------------------------------------------------------------------------
do
    reset()
    local function leaderName(i)
        return "Pl" .. string.char(96 + math.floor(i / 26) % 26 + 1) .. " Qq" .. string.char(96 + i % 26 + 1)
    end
    local function pullAnswer(client, from, first)
        client.GF._pull = { key = from:lower(), at = now, msgs = 0 }
        for m = 0, client.GF.PULL_MSGS - 1 do
            local a, b = first + m * 2, first + m * 2 + 1
            hear(client, "B:1:" .. leaderName(a) .. ":" .. rev() .. ":5:A:a:z:stromgarde:40:3:0:0:1:60:1140|"
                .. leaderName(b) .. ":" .. rev() .. ":5:A:a:z:stromgarde:40:3:0:0:1:60:1140", from)
        end
    end
    -- An honest answer of normal size: all taken.
    local bob = newClient("Bob Stone")
    contactName(bob, "Fred Fake")
    pullAnswer(bob, "Fred Fake", 0)
    local n = 0
    for _ in pairs(bob.GF.board) do n = n + 1 end
    assert(n == bob.GF.PULL_ROWS, "an honest answer of " .. bob.GF.PULL_ROWS .. " rows took " .. n)
    -- The same contact, answer after answer with new leaders: bounded.
    for round = 1, 8 do pullAnswer(bob, "Fred Fake", round * 8) end
    n = 0
    for _ in pairs(bob.GF.board) do n = n + 1 end
    assert(n == bob.GF.PULL_ROWS_PER_GATEWAY, "forged answers filled the board with " .. n .. " rows")
    -- Another contact still has its own room.
    contactName(bob, "Gina Gold")
    pullAnswer(bob, "Gina Gold", 100)
    n = 0
    for _ in pairs(bob.GF.board) do n = n + 1 end
    assert(n == bob.GF.PULL_ROWS_PER_GATEWAY + bob.GF.PULL_ROWS, "a second contact's answer was refused: " .. n)
    -- A full board: hearsay takes no first-hand row's place.
    reset()
    bob = newClient("Bob Stone")
    contactName(bob, "Fred Fake"); contactName(bob, "Carl Reed")
    bob.GF.BOARD_MAX = 2
    hear(bob, G(1, "Lena Lead", rev(), 40, 40), "Lena Lead")
    hear(bob, G(1, "Mona Lead", rev(), 40, 40), "Mona Lead")
    assert(bob.GF.boardCount == 2)
    pullAnswer(bob, "Fred Fake", 0)
    assert(bob.GF.board["lena lead"] and bob.GF.board["mona lead"], "a pull answer evicted a first-hand row")
    assert(bob.GF.boardCount == 2)
end

-- ---------------------------------------------------------------------------
-- 19. 2.3.0: a withdrawal is believed from the hand that brought the row, not from the last
-- hand that sent a newer copy (it could rewrite a rev, then hide the group)
-- ---------------------------------------------------------------------------
do
    reset()
    local bob = newClient("Bob Stone")
    contactName(bob, "Carl Reed"); contactName(bob, "Dina Vale"); contactName(bob, "Fred Fake")
    local r = rev()
    hear(bob, G(2, "Lena Lead", r, 3), "Carl Reed")
    assert(bob.GF.board["lena lead"] and bob.GF.board["lena lead"].xFrom == "carl reed")
    -- A newer copy by another hand: taken (an edit), but it brings no right to withdraw.
    hear(bob, G(2, "Lena Lead", r + 3, 9), "Fred Fake")
    assert(bob.GF.board["lena lead"].rev == r + 3, "an edit by another hand was refused")
    hear(bob, "X:1:2:Lena Lead:" .. (r + 3), "Fred Fake")
    assert(bob.GF.board["lena lead"], "the last hand withdrew a row another hand brought")
    -- The hand that brought it: believed.
    hear(bob, "X:1:2:Lena Lead:" .. (r + 3), "Carl Reed")
    assert(not bob.GF.board["lena lead"], "the withdrawal of the hand that brought the row was refused")
end

-- ---------------------------------------------------------------------------
-- 20. 2.3.0: the own withdrawal finishes when the bucket comes back (a try that told some
-- holders is not one of the WITHDRAW_TRIES), and nobody beyond the holders is told
-- ---------------------------------------------------------------------------
do
    reset()
    local leader, bob = newClient("Lena Lead"), newClient("Bob Stone")
    link(leader, bob)
    assert(leader.GF:Publish(spec()))
    advance(0.3)
    local own = leader.GF.own
    assert(own and own.spreadLive and own.rev, "fixture: the listing did not go by hand")
    local r = own.rev
    -- Two copies of ten (the first hand's cap, HAND_BURST): twenty holders.
    own.heldLast, own.heldPrev = {}, {}
    local holders = {}
    for i = 1, 10 do
        own.heldLast[i] = "Last" .. string.char(96 + i) .. " Hold"
        own.heldPrev[i] = "Prev" .. string.char(96 + i) .. " Hold"
        holders[own.heldLast[i]], holders[own.heldPrev[i]] = true, true
    end
    -- The bucket just used, and the directory's chain short a while (a fight's captures).
    leader.GF._handTokens, leader.GF._handTokensAt = 0, now
    leader.dir.chain.tokens = 0
    assert(leader.GF:Unpublish())
    advance(95)
    assert(#sent(leader, "^X:") == 0, "fixture: a withdrawal left while the chain was short")
    leader.dir.chain.tokens = 30
    advance(300)
    local told, count = {}, 0
    for _, entry in ipairs(sent(leader, "^X:")) do
        assert(entry.text == "X:1:1:Lena Lead:" .. r, "an unexpected withdrawal: " .. entry.text)
        assert(not told[entry.target], entry.target .. " was told twice")
        told[entry.target] = true
        count = count + 1
    end
    for name in pairs(told) do assert(holders[name], name .. " never had the listing and was told") end
    assert(count == 20, "the withdrawal reached " .. count .. " of 20 holders")
end

-- 19b. 2.3.0: a pull answer with a newer rev over a row a hand brought gives nobody else the
-- right to withdraw it
do
    reset()
    local bob = newClient("Bob Stone")
    contactName(bob, "Carl Reed"); contactName(bob, "Fred Fake")
    local r = rev()
    hear(bob, G(2, "Lena Lead", r, 3), "Carl Reed")
    bob.GF._pull = { key = "fred fake", at = now, msgs = 0 }
    hear(bob, "B:1:Lena Lead:" .. (r + 2) .. ":5:A:a:z:stromgarde:40:9:0:0:1:60:1140", "Fred Fake")
    hear(bob, G(2, "Lena Lead", r + 4, 9), "Fred Fake")
    local row = bob.GF.board["lena lead"]
    assert(row and row.xFrom == "carl reed", "a pull then a hand copy took the withdrawal right: " .. tostring(row and row.xFrom))
end

-- ---------------------------------------------------------------------------
-- 22. 2.3.0: the unchanged copy goes first to the holders too (a holder the draw missed got it from
-- one other hand only, which never replaces a row the leader gave: its row ran out a turn early)
-- ---------------------------------------------------------------------------
do
    reset()
    local alice = newClient("Alice Smith")
    local others = {}
    for i = 1, 12 do
        others[i] = newClient("Mate " .. string.char(96 + i) .. "y")
        link(alice, others[i])
    end
    assert(alice.GF:Publish(spec()))
    advance(1)
    local first = {}
    for _, entry in ipairs(sent(alice, "^G:1:1:")) do first[entry.target] = true end
    -- (Fixture: the holders on record are the six the draw did not pick, Random being fixed: an
    -- unchanged turn that draws afresh picks the first six again.)
    local holders = {}
    for _, c in ipairs(others) do
        if not first[c.name] then holders[#holders + 1] = c.name end
    end
    assert(#holders == 6, "fixture: " .. #holders .. " contacts left out of the first hand")
    alice.GF.own.heldLast, alice.GF.own.heldPrev = holders, nil
    local mark = #log
    advance(1000)
    local turn = {}
    for i = mark + 1, #log do
        local entry = log[i]
        if entry.from == alice and entry.chatType == "WHISPER" and entry.text:find("^G:1:1:") then turn[entry.target] = true end
    end
    for _, name in ipairs(holders) do
        assert(turn[name], name .. " holds the listing and missed its unchanged copy")
    end
end

-- ---------------------------------------------------------------------------
-- 21. 2.3.0: a listing that went by hand, the channel carrying again before its next turn: the
-- withdrawal says it on the channel (the hands' withdrawal waits for relay mode, never comes)
-- ---------------------------------------------------------------------------
do
    reset()
    local alice, bob = newClient("Alice Smith"), newClient("Bob Stone")
    link(alice, bob)
    assert(alice.GF:Publish(spec()))
    advance(0.3)
    assert(alice.GF.own.spreadLive and not alice.GF.own.live and bob.GF.board[key(alice)], "fixture: no copy by hand")
    alice.dir.active, alice.channelId = false, 7
    assert(alice.GF:Mode() == "channel")
    advance(60)
    assert(not alice.GF.own.live, "fixture: the listing went on the channel before its turn")
    assert(alice.GF:Unpublish())
    advance(200)
    local farewells = 0
    for _, entry in ipairs(log) do
        if entry.from == alice and entry.chatType == "CHANNEL" and entry.text == "X:1:A" then farewells = farewells + 1 end
    end
    assert(farewells == 1, "the channel was not told the listing is withdrawn: " .. farewells)
    -- Read there, it takes the copy by hand off the board.
    bob.GF:OnAddonMessage("X:1:A", "CHANNEL", "Alice Smith")
    assert(not bob.GF.board[key(alice)], "the channel's farewell left the copy by hand")
end

-- ---------------------------------------------------------------------------
-- 2.3.0: leaves (out of the member list) get a copy at every hand, and its withdrawal reaches them
-- ---------------------------------------------------------------------------
do
    reset()
    local opts = { listSize = 60 }
    local lead, hand = newClient("Lena Lead", opts), newClient("Hope Hand", opts)
    link(lead, hand)
    local seconds = {}
    for i = 1, 6 do
        seconds[i] = newClient("Con" .. string.char(96 + i) .. " Nm", opts)
        link(hand, seconds[i])
    end
    local g1, g2 = newClient("Gina Ghost"), newClient("Gus Ghost")
    -- g1 greeted the first hand, g2 a second hand: leaves for them, contacts for the leaves.
    hand.dir.LeafNames = function() return { g1.name } end
    seconds[1].dir.LeafNames = function() return { g2.name } end
    contactName(g1, hand.name)
    contactName(g2, seconds[1].name)
    assert(lead.GF:Publish(spec()))
    advance(0.3)
    for i = 1, 6 do assert(seconds[i].GF.board[key(lead)], "a second hand missed the copy") end
    assert(g1.GF.board[key(lead)], "the first hand's leaf missed the copy")
    assert(g2.GF.board[key(lead)], "a leaf of the second hand got no copy: leaves reached by two hands only")
    advance(100)
    assert(lead.GF:Unpublish())
    advance(1)
    for i = 1, 6 do assert(not seconds[i].GF.board[key(lead)], "a second hand kept the withdrawn listing") end
    assert(not g1.GF.board[key(lead)], "the first hand's leaf kept the withdrawn listing (cut by the withdrawal's cap)")
    assert(not g2.GF.board[key(lead)], "the second hand's leaf kept the withdrawn listing")
end

print("forever_group_finder_relay: ok")
