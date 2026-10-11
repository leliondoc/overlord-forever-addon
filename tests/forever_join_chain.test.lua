-- The join of the realm channel, and what stops it.
-- Run from the addon root under Lua 5.1 (lua5.1 tests/forever_join_chain.test.lua).
--  (1) Open or slow channel: the join chain is the one of always (4 calls at 0, 3, 9, 18 s),
--      restarted by the 60 s ticker, and nothing new runs.
--  (2) The game answers our join with a request of its own: joining stops for the
--      session, the player is told once, the finder is told to repaint.
--  (3) The next tries are the way out of an instance and a login, never a timer.
--  (4) Wiring read in the source: one join call site, the event in both register lists,
--      its branch behind the instance barrier.
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
    if which == 1 then return 1 end           -- the game's own channels are there (no slot-1 wait)
    return channelId
end
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
    sync._joinChannelAttemptPending, sync._joinChannelDeferCount = nil, nil
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
assert(joins[1].at == 1000 and joins[2].at - joins[1].at == 3 and joins[3].at - joins[2].at == 6
    and joins[4].at - joins[3].at == 9, "the chain no longer calls at 0, 3, 9 and 18 s")
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
pump(1)
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
sync:OnChannelJoinRefused(channel)
assert(sync:IsChannelClosed())
channelId = 5
assert(not sync:IsChannelClosed(), "closed is said of a channel we are in")
sync:JoinChannel()
channelId = 0
sync:JoinChannel()
pump(1)
assert(#joins == 2, "the refusal was not forgotten once inside")

-- (3) The way out of an instance tries once more; a timer never does.
reset()
sync:JoinChannel()
sync:OnChannelJoinRefused(channel)
local before = #joins
for _, method in ipairs({ "StartChannelRetryLoop", "StartProximitySync", "StartPassiveSync",
    "ResumePendingKillBroadcast" }) do
    if sync[method] then sync[method] = function() end end
end
-- Resume registers its events on the sync frame of the fixture; only the join matters here.
local _, err = pcall(function() sync:Resume() end)
pump(1)
assert(#joins == before + 1, "leaving an instance did not try the channel again (" .. tostring(err) .. ")")
-- Inside when the 60 s ticker looks: a refusal met earlier no longer stands, so a later
-- way out of the channel is retried like any other.
reset()
sync:JoinChannel()
sync:OnChannelJoinRefused(channel)
channelId = 5
ticker.run()
channelId = 0
assert(not sync:IsChannelClosed(), "a refusal outlived a channel we were back in")
ticker.run()
pump(1)
assert(#joins == 2, "the ticker did not retry after the channel was lost again")

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

print("forever_join_chain: ok")
