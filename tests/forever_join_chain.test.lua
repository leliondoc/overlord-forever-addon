-- The join of the realm channel, and what stops it.
-- Run from the addon root under Lua 5.1 (lua5.1 tests/forever_join_chain.test.lua).
--  (1) Open or slow channel: the join chain is the one of always (4 calls at 0, 3, 9, 18 s),
--      restarted by the 60 s ticker, and nothing new runs.
--  (2) The game answers our join with a request of its own: joining stops for the
--      session, the player is told once, the finder is told to repaint.
--  (3) The next tries are the way out of an instance and a login, never a timer.
--  (4) Wiring read in the source: one join call site, the event in both register lists,
--      its branch behind the instance barrier.
--  (5) 2.0.8, where it lands: after 2 s of calm in the player's channel list, the free
--      numbers below their last channel are padded with hidden temporary channels for a
--      moment, so ours lands right after theirs; nothing of theirs moves.
assert(loadfile("tests/forever_beta_integration.test.lua"))()

local sync = Overlord.Sync
local now, pending, tickers = 1000, {}, {}
local function pump(seconds)
    local stop = now + (seconds or 0)
    while true do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local first = pending[1]
        if not first or first.at > stop then break end
        table.remove(pending, 1)
        now = first.at
        first.run()
    end
    now = stop
end
GetTime = function() return now end
C_Timer = {
    After = function(delay, callback) pending[#pending + 1] = { at = now + delay, run = callback } end,
    NewTicker = function(period, callback)
        local ticker = { period = period, run = callback, Cancel = function(self) self.cancelled = true end }
        tickers[#tickers + 1] = ticker
        return ticker
    end,
}
IsInInstance = function() return false end
Overlord.InstanceSuspended = false
Overlord.IsInitialized = true

local channelId, joins, printed, touched = 0, {}, {}, 0
local onJoin
GetChannelName = function(which)
    if which == 1 then return 1 end           -- the game's own channels are there
    return channelId
end
-- A calm list (2.0.8: the join waits for it, 2 s); no temporary channels here, so no pads.
GetChannelList = function() return 1, "General", false end
JoinChannelByName = function(name, password, frame, voice)
    joins[#joins + 1] = { name = name, password = password, frame = frame, at = now }
    if onJoin then onJoin(name) end
end
securecall = function(fn, ...) return fn(...) end
canaccessvalue = nil
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
Overlord.GroupFinder = { Touch = function() touched = touched + 1 end }
sync.SendSyncRequest = function() end

local function reset()
    pending, joins, printed, touched, onJoin = {}, {}, {}, 0, nil
    channelId = 0
    sync._joinChannelAttemptPending = nil
    -- A login: the latch only lives in memory, cleared here the way Resume does it.
    channelId = 1
    sync:JoinChannel()
    channelId = 0
    pending, joins = {}, {}
end
local function name() return joins[1] and joins[1].name end

-- (1) The chain of always, and the ticker.
reset()
sync:JoinChannel()
pump(40)
assert(#joins == 4, "an unanswered join chain makes " .. #joins .. " calls, expected 4")
assert(joins[1].at == 1002 and joins[2].at - joins[1].at == 3 and joins[3].at - joins[2].at == 6
    and joins[4].at - joins[3].at == 9, "the chain no longer calls at 2, 5, 11 and 20 s (after the 2 s calm)")
assert(joins[1].password == nil and joins[1].frame == 0, "the join must stay hidden and plain")
local channel = name()
assert(type(channel) == "string" and channel:find("^OverlordF"), "unexpected channel name " .. tostring(channel))
assert(not sync:IsChannelClosed() and #printed == 0)
sync:StartChannelRetryLoop()
local ticker = tickers[#tickers]
assert(ticker and ticker.period == 60)
ticker.run()
pump(40)
assert(#joins == 8, "the ticker no longer restarts a chain while outside")
-- A join that works: one call, and the chain ends.
reset()
onJoin = function() channelId = 5 end
sync:JoinChannel()
pump(40)
assert(#joins == 1 and sync:GetChannelId() == 5)
sync:JoinChannel()
ticker.run()
pump(40)
assert(#joins == 1, "a client inside the channel joined again")

-- (2) The game answers our join with a request of its own.
reset()
sync:JoinChannel()
pump(3)
assert(#joins == 1)
-- Somebody else's channel, an unreadable value, nothing at all: none of our business.
sync:OnChannelJoinRefused("SomeOtherChannel")
sync:OnChannelJoinRefused(nil)
sync:OnChannelJoinRefused(42)
canaccessvalue = function() return false end
sync:OnChannelJoinRefused(channel)
canaccessvalue = nil
assert(not sync:IsChannelClosed() and #printed == 0 and touched == 0, "a foreign request closed our channel")
pump(3)
assert(#joins == 2, "a foreign request stopped the chain")
-- Ours, whatever the letter case the game hands back.
sync:OnChannelJoinRefused(channel:upper())
assert(sync:IsChannelClosed(), "the request for our channel was not taken")
assert(#printed == 1 and touched == 1, "the player or the finder was not told")
sync:OnChannelJoinRefused(channel:lower())
sync:OnChannelJoinRefused(channel)
assert(#printed == 1 and touched == 1, "told more than once")
-- Nothing joins any more: not the chain in flight, not the ticker, not the direct callers.
pump(60)
ticker.run()
sync:JoinChannel()
sync:JoinChannel(1)
pump(120)
assert(#joins == 2, "a join left after the refusal: " .. #joins .. " calls")
-- The request raised inside the join call itself (same frame) stops the chain as well.
reset()
onJoin = function(joined) sync:OnChannelJoinRefused(joined) end
sync:JoinChannel()
pump(120)
assert(#joins == 1 and sync:IsChannelClosed(), "a synchronous request let the chain go on: " .. #joins)
assert(#printed == 0, "the chat line is said once per session")
-- A request that arrives after a join that worked changes nothing.
reset()
channelId = 5
sync:OnChannelJoinRefused(channel)
assert(not sync:IsChannelClosed() and touched == 0)
-- Inside after all: no longer closed, and the
-- next call forgets the refusal for good.
reset()
sync:JoinChannel()
pump(3)
sync:OnChannelJoinRefused(channel)
assert(sync:IsChannelClosed())
channelId = 5
assert(not sync:IsChannelClosed(), "closed is said of a channel we are in")
sync:JoinChannel()
channelId = 0
sync:JoinChannel()
pump(3)
assert(#joins == 2, "the refusal was not forgotten once inside")

-- (3) The way out of an instance tries once more; a timer never does.
reset()
sync:JoinChannel()
pump(3)
sync:OnChannelJoinRefused(channel)
local before = #joins
for _, method in ipairs({ "StartChannelRetryLoop", "StartProximitySync", "StartPassiveSync",
    "ResumePendingKillBroadcast" }) do
    if sync[method] then sync[method] = function() end end
end
-- Resume registers its events on the sync frame of the fixture; only the join matters here.
local _, err = pcall(function() sync:Resume() end)
pump(3)
assert(#joins == before + 1, "leaving an instance did not try the channel again (" .. tostring(err) .. ")")
-- Inside when the 60 s ticker looks: a refusal met earlier no longer stands, so a later
-- way out of the channel is retried like any other.
reset()
sync:JoinChannel()
pump(3)
sync:OnChannelJoinRefused(channel)
channelId = 5
ticker.run()
channelId = 0
assert(not sync:IsChannelClosed(), "a refusal outlived a channel we were back in")
ticker.run()
pump(3)
assert(#joins == 2, "the ticker did not retry after the channel was lost again")

-- (3b) The map requests that follow a join (at once, then 15 and 35 s): broadcast before
-- the truce's retirement; from that day one neighbour heard as updated instead (2.0.2).
for _, cut in ipairs({ false, true }) do
    reset()
    local broadcasts, targeted = 0, 0
    sync.SendSyncRequest = function() broadcasts = broadcasts + 1 end
    local realPeer = sync.SendLoginMapPeerRequest
    sync.SendLoginMapPeerRequest = function() if cut then targeted = targeted + 1 end return cut end
    onJoin = function() channelId = 5 end
    sync:JoinChannel()
    pump(40)
    assert(sync:GetChannelId() == 5, "fixture: the join did not work")
    if cut then
        assert(broadcasts == 0 and targeted == 3, "after the cut a join still broadcast: " .. broadcasts .. " / " .. targeted)
    else
        assert(broadcasts == 3 and targeted == 0, "before the cut a join lost its requests: " .. broadcasts .. " / " .. targeted)
    end
    sync.SendSyncRequest, sync.SendLoginMapPeerRequest = function() end, realPeer
end

-- (4) Wiring, read in the source.
local function read(path) return assert(io.open(path, "r")):read("*a") end
local source = read("Sync.lua")
local _, sites = source:gsub("JoinChannelByName", "")
assert(sites == 1, "Sync.lua must hold one join call site, found " .. sites)
for _, path in ipairs({ "Core.lua", "SyncAux.lua", "SyncRelay.lua", "GroupFinder.lua", "GroupFinderUI.lua" }) do
    assert(not read(path):find("JoinChannelByName", 1, true), path .. " joins a channel by itself")
end
local _, registrations = source:gsub('RegisterEvent, syncFrame, "CHANNEL_PASSWORD_REQUEST"', "")
assert(registrations == 2, "the event must be registered at start and on leaving an instance, found " .. registrations)
local barrier = source:find("if Overlord.InstanceSuspended or IsInInstance() then return end", 1, true)
local branch = source:find('elseif event == "CHANNEL_PASSWORD_REQUEST" then', 1, true)
assert(barrier and branch and branch > barrier, "the event branch must sit behind the instance barrier")
local gate = source:find("function Overlord.Sync:JoinChannel%(attempt, generation%)%s*%-%-[^\n]*\n[^\n]*\n%s*if priv.channelClosed then")
assert(gate, "the refusal must be the first test of JoinChannel")
local resume = source:find("function Overlord.Sync:Resume()", 1, true)
local cleared = source:find("priv.channelClosed = nil\n    self:JoinChannel()", resume, true)
    or source:find("priv.channelClosed = nil\r\n    self:JoinChannel()", resume, true)
assert(cleared, "leaving an instance must forget the refusal just before joining")
-- The addon only ever joins: it administers nothing and closes no dialog of the game.
for _, word in ipairs({ "SetChannel", "ChannelBan", "ChannelKick", "LeaveChannelByName", "StaticPopup_Hide" }) do
    assert(not source:find(word, 1, true), "Sync.lua must not use " .. word)
end
-- At start the event is only registered outside instances, like the four others.
local guard = source:find("if not Overlord.InstanceSuspended and not IsInInstance() then", 1, true)
local firstRegistration = source:find('RegisterEvent, syncFrame, "CHANNEL_PASSWORD_REQUEST"', 1, true)
local guardEnd = guard and source:find("\n    end", guard)
assert(guard and firstRegistration and guardEnd and firstRegistration > guard and firstRegistration < guardEnd,
    "the event must be registered inside the 'not in an instance' block at start")
for _, workflow in ipairs({ ".github/workflows/validate.yml", ".github/workflows/release.yml" }) do
    assert(read(workflow):find("lua5.1 tests/forever_join_chain.test.lua", 1, true), workflow .. " misses this test")
end

-- (5) Where it lands. A small model of the game: a join takes the lowest number that is
-- neither held nor kept for a server channel not joined now (Trade outside a city), as
-- measured on 2026-10-21; temporary channels behave the same and say nothing.
local held, kept, tempJoins, left
local function model(channels, reserved)
    held, kept, tempJoins, left = {}, {}, {}, {}
    for n, nm in pairs(channels) do held[n] = nm end
    for n, nm in pairs(reserved or {}) do kept[n] = nm end
end
local function lowestFree()
    local n = 1
    while held[n] or kept[n] do n = n + 1 end
    return n
end
local function numberOf(nm)
    for n, v in pairs(held) do if v:upper() == nm:upper() then return n end end
    return 0
end
GetChannelName = function(which)
    if type(which) == "number" then return held[which] and which or 0 end
    return numberOf(which)
end
GetChannelList = function()
    local out, ids = {}, {}
    for n in pairs(held) do ids[#ids + 1] = n end
    for n in pairs(kept) do ids[#ids + 1] = n end
    table.sort(ids)
    for _, n in ipairs(ids) do
        out[#out + 1] = n; out[#out + 1] = held[n] or kept[n]; out[#out + 1] = held[n] == nil
    end
    return unpack(out)
end
GetNumDisplayChannels = function() return 0 end
JoinChannelByName = function(nm) joins[#joins + 1] = { name = nm, at = now }; held[lowestFree()] = nm end
JoinTemporaryChannel = function(nm) tempJoins[#tempJoins + 1] = nm; held[lowestFree()] = nm end
LeaveChannelByName = function(nm)
    local n = numberOf(nm)
    if n > 0 then held[n] = nil; left[#left + 1] = nm end
end
local function seat(channels, reserved, seconds)
    pending, joins, printed = {}, {}, {}
    sync._joinChannelAttemptPending, sync._channelSeat, sync._channelPads = nil, nil, nil
    model(channels, reserved)
    local startedAt = now
    sync:JoinChannel()
    pump(seconds or 20)
    return GetChannelName(channel), startedAt
end
-- His character on the beta: a hole at /4 (and /3, /5 kept for Trade and Local Trade).
-- (9 s: joined and confirmed, the 15 s safety release not reached: the confirmation leaves them.)
local at, startedAt = seat({ [1] = "LocalDefense", [2] = "General" }, { [3] = "Trade", [5] = "TradeLocal" }, 9)
assert(at == 6, "ours did not land after the player's channels: /" .. at)
assert(held[1] == "LocalDefense" and held[2] == "General" and kept[3] and kept[5], "a channel of the player moved")
assert(#tempJoins == 1 and #left == 1 and left[1] == tempJoins[1],
    "the pads were not all left: " .. #tempJoins .. "/" .. #left)
assert(#joins == 1 and joins[1].at >= startedAt + 2, "our join did not wait for the calm list")
for n, nm in pairs(held) do assert(not sync:IsChannelPad(nm), "a pad is still held at /" .. n) end
-- A new character: General, Trade kept, LocalDefense; ours after the five first numbers.
at = seat({ [1] = "General", [3] = "LocalDefense" }, { [2] = "Trade" })
assert(at == 6 and held[1] == "General" and held[3] == "LocalDefense", "a new character's channels moved: /" .. at)
-- Every number up to the player's last one taken: no pad at all.
at = seat({ [1] = "General", [2] = "LocalDefense", [3] = "A", [4] = "B", [5] = "C", [6] = "Mine" })
assert(at == 7 and #tempJoins == 0, "pads joined with no hole to fill")
-- Too many holes (a single channel far down): no pads, the join of always.
at = seat({ [12] = "Mine" })
assert(#tempJoins == 0 and at == 1, "more than six pads were joined")
-- Already in (a /reload): nothing moves, nothing is padded.
model({ [1] = "LocalDefense", [2] = "General", [4] = channel }, { [3] = "Trade" })
pending, joins = {}, {}
sync._joinChannelAttemptPending = nil
sync:JoinChannel()
pump(20)
assert(#joins == 0 and #tempJoins == 0 and GetChannelName(channel) == 4, "a joined channel was moved")
-- An instance in the middle of the seat: pads left, no join.
model({ [1] = "LocalDefense", [2] = "General" }, { [3] = "Trade", [5] = "TradeLocal" })
pending, joins = {}, {}
sync._joinChannelAttemptPending, sync._channelSeat, sync._channelPads = nil, nil, nil
sync:JoinChannel()
pump(2.2)
assert(#tempJoins == 1, "fixture: the pads were not joined before the instance")
Overlord.InstanceSuspended = true
pump(20)
Overlord.InstanceSuspended = false
assert(#joins == 0 and #left == 1 and GetChannelName(channel) == 0, "an instance let the seat join or keep its pads")
-- A slow server: our join is only numbered 4 s later. The pads stay until it is confirmed,
-- so ours still lands behind the player's channels, and they go at the confirmation.
model({ [1] = "LocalDefense", [2] = "General" }, { [3] = "Trade", [5] = "TradeLocal" })
pending, joins = {}, {}
sync._joinChannelAttemptPending, sync._channelSeat, sync._channelPads = nil, nil, nil
local quickJoin = JoinChannelByName
JoinChannelByName = function(nm)
    joins[#joins + 1] = { name = nm, at = now }
    if numberOf(nm) > 0 then return end
    C_Timer.After(4, function() if numberOf(nm) == 0 then held[lowestFree()] = nm end end)
end
local joinStart = now
sync:JoinChannel()
pump(5.6)   -- calm 2 s, pads 0.5 s, our join, its first check at +3 s: not numbered yet
assert(#left == 0 and #tempJoins == 1, "the pads were left before our join was confirmed")
pump(20)
JoinChannelByName = quickJoin
assert(GetChannelName(channel) == 6 and #left == 1, "a slow join landed in the hole or kept its pads: /"
    .. GetChannelName(channel) .. ", left " .. #left)
assert(now > joinStart, "fixture: time did not move")
-- Pads left behind by a /reload are swept at start.
model({ [1] = "LocalDefense", [2] = "General", [4] = "OvPadabc1231" })
sync:ReleaseChannelPads(true)
assert(not held[4] and left[1] == "OvPadabc1231", "a pad left by a /reload was not swept")
-- An unexpected error in the seat: the join goes plainly, nothing stays pending.
model({ [1] = "LocalDefense", [2] = "General" }, { [3] = "Trade" })
pending, joins = {}, {}
sync._joinChannelAttemptPending, sync._channelSeat, sync._channelPads = nil, nil, nil
local realRead = sync.ReadPlayerChannels
sync.ReadPlayerChannels = function() error("unexpected") end
sync:JoinChannel()
pump(10)
sync.ReadPlayerChannels = realRead
assert(#joins == 1 and GetChannelName(channel) > 0 and not sync._joinChannelAttemptPending,
    "an error in the seat held the join")
-- Only the exact pad names are pads; a protected name is never read.
assert(not sync:IsChannelPad("OvPadabc") and not sync:IsChannelPad("OvPadzzzzzz1") and sync:IsChannelPad("OvPad0a1b2c3"))
canaccessvalue = function(v) return v ~= "OvPad0a1b2c3" end
assert(not sync:IsChannelPad("OvPad0a1b2c3"), "a protected name was read")
canaccessvalue = nil
-- A pad name somebody else holds with a password: pads left, our channel is not closed.
model({ [1] = "LocalDefense" })
sync._channelPads = { "OvPadabc1231" }
held[2] = "OvPadabc1231"
sync:OnChannelJoinRefused("OvPadabc1231")
assert(not held[2] and not sync:IsChannelClosed(), "a refused pad closed our channel or stayed")

print("forever_join_chain: ok")
