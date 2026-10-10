-- Terminal capture events keep their way to the other faction under channel pressure.
-- (1) A lease release (ZR) sent synchronously before a loading screen: the direct ZR
--     has just spent the channel token, and the relay's channel copy used to stop the
--     synchronous loop, leaving the Battle.net copies to a pump the loading screen may
--     suspend. They now leave at once; the channel copy waits for its token.
-- (2) A relay whose urgent lane is full: the deferred channel copy of a capture used
--     to be dropped, fragment after fragment, so channel hearers never assembled it.
--     It now waits in its item and both fragments go out once tokens are back.
math.randomseed(5)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s = Overlord.Sync
assert(loadfile("SyncRelay.lua"))()
local net = Overlord.Relay
net.BridgeChannelHold = { 0, 0 }
Overlord.RelayEnabled = true
Overlord.PlayerFaction = "Horde"
function s:GetChannelId() return 5 end
function IsInInstance() return false end
function IsInGroup() return false end

local clock = 1000
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = timer.at
        timer.fn()
    end
    clock = stop
end

local channel, bnet, refuse, group, refuseGroup = {}, {}, nil, {}, nil
function s:SendAddonChecked(msg, chatType, target)
    if chatType == "CHANNEL" and refuse and msg:find(refuse, 1, true) then
        refuse = nil -- Blizzard refuses this one attempt
        return false
    end
    if chatType == "PARTY" then
        if refuseGroup and msg:find(refuseGroup, 1, true) then
            refuseGroup = nil -- Blizzard refuses this one attempt
            return false
        end
        group[#group + 1] = msg
    end
    if chatType == "CHANNEL" then channel[#channel + 1] = msg end
    return true
end
function s:SendToBNet(id, kind, payload)
    bnet[#bnet + 1] = { id = id, kind = kind, payload = payload }
    return true
end
local friends = { faction = {} }
function s:GetBetaBNetTargets() return friends end
function s:GetBetaBNetTargetInfo(id)
    for _, f in ipairs(friends) do if f == id then return friends.faction[id], "Friend " .. id end end
    return nil
end
local function channelHas(marker)
    for _, msg in ipairs(channel) do if msg:find(marker, 1, true) then return true end end
    return false
end

-- (1) One live Alliance friend; the direct ZR has just taken the channel token.
friends[1], friends.faction[777] = 777, "Alliance"
net:NoteBNetHeard(777)
s._channelTokens, s._channelTokensAt = nil, nil
assert(s:TakeChannelToken(true))
assert(net:Send("ZR", "elwynn_goldshire:wave1:Origin Tester:RELEASEMARK", nil, true), "the release was not queued")
assert(#bnet >= 1 and bnet[1].id == 777, "the release's Battle.net copy waited for the pump (none sent at once)")
assert(not channelHas("RELEASEMARK"), "the channel copy went out without a token")
local skipped = net.stats.channelSkipped
advance(3)
assert(channelHas("RELEASEMARK"), "the release's channel copy was never sent once the token came back")
assert(net.stats.channelSkipped == skipped, "the release's channel copy was dropped")
print("Relay terminals: an immediate release crosses to Battle.net at once, its channel copy follows")

-- (1b) Same release from a grouped capturer whose relay group copy Blizzard refuses
-- (the direct ZR just used the shared group/channel quota): Battle.net still at once.
advance(10)
bnet, group = {}, {}
IsInGroup = function() return true end
IsInRaid = IsInRaid or function() return false end
refuseGroup = "GROUPMARK"
s._channelTokens, s._channelTokensAt = nil, nil
assert(s:TakeChannelToken(true))
assert(net:Send("ZR", "elwynn_goldshire:wave2:Origin Tester:GROUPMARK", nil, true), "the grouped release was not queued")
assert(refuseGroup == nil, "the group copy was never tried (vacuous case)")
assert(#bnet >= 1 and bnet[1].id == 777, "a refused group copy held the release's Battle.net copy")
advance(5)
local groupCopies = 0
for _, msg in ipairs(group) do if msg:find("GROUPMARK", 1, true) then groupCopies = groupCopies + 1 end end
assert(groupCopies == 1, "the refused group copy was not retried exactly once: " .. groupCopies)
assert(channelHas("GROUPMARK"), "the grouped release's channel copy was never sent")
IsInGroup = function() return false end
friends[1], friends.faction[777] = nil, nil
print("Relay terminals: a refused group copy does not hold an immediate release's Battle.net copies")

-- (2) Urgent lane full of unsent siege updates (no pump tick yet), channel in debt.
advance(10)
channel, bnet = {}, {}
for i = 1, 90 do
    net:Send("ZS", "fakezone" .. i .. ":in_progress:Horde:" .. (1000 + i) .. ":10", nil)
end
s._channelTokens, s._channelTokensAt = nil, nil
assert(s:TakeChannelToken(true)); assert(s:TakeChannelToken(true))
-- A capture whose wire needs two fragments (the second one carries ENDMARK).
local payload = "CAPTUREMARK:" .. string.rep("x", 200) .. ":ENDMARK"
assert(net:Send("C", payload, nil), "the capture was not admitted")
local skippedBefore = net.stats.channelSkipped or 0
advance(30)
assert(channelHas("CAPTUREMARK"), "the capture's first channel fragment was never sent")
assert(channelHas("ENDMARK"), "the capture's second channel fragment was dropped (nobody can assemble it)")
local _ = skippedBefore --
print("Relay terminals: a full lane keeps both channel fragments of a capture")

-- (3) Same full lane, and Blizzard refuses the capture's channel copy once: it is
-- retried from its item instead of being abandoned.
advance(60)
channel = {}
for i = 1, 90 do
    net:Send("ZS", "otherzone" .. i .. ":in_progress:Horde:" .. (2000 + i) .. ":10", nil)
end
-- One token, so the capture's copy is tried (and refused) while the lane is full.
s._channelTokens, s._channelTokensAt = 1, clock
refuse = "REFUSEMARK"
assert(net:Send("C", "REFUSEMARK:short", nil), "the second capture was not admitted")
advance(30)
assert(refuse == nil, "the refusal was never exercised (vacuous case)")
assert(channelHas("REFUSEMARK"), "a capture's refused channel copy was abandoned under a full lane")
print("Relay terminals: a refused channel copy of a capture is retried under a full lane")
