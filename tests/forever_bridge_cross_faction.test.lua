-- 1.3.2 cross-faction live totals. A Horde client with an Alliance Battle.net
-- friend passes the Horde totals it hears first-hand on its channel to that
-- friend; the Alliance client puts an enemy total received over Battle.net once
-- on its own channel. Same bounds as the live bridge (one row per subject per
-- 60 s, 6 rows/min, jump guard), no loop, and a copy another bridge already put
-- on the channel is not repeated.
math.randomseed(3)
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
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
net.BridgeChannelHold = { 0, 0 } -- exact timings below
Overlord.BetaNetworkEnabled = true
function s:GetChannelId() return 5 end

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

local channelRows, bnetRows = {}, {}
function s:SendAddonChecked(msg, chatType, target)
    if msg:sub(1, 3) == "LK:" and chatType == "CHANNEL" then channelRows[#channelRows + 1] = msg end
    return true
end
function s:SendToBNet(id, kind, payload)
    if kind == "LK" then bnetRows[#bnetRows + 1] = { id = id, payload = payload } end
    return true
end
local friends = {}
function s:GetBetaBNetTargets() return friends end
function s:GetBetaBNetTargetInfo(id)
    for _, f in ipairs(friends) do if f == id then return friends.faction[id], "Friend " .. id end end
    return nil
end

local EPOCH = 1789527600
local function know(name, total, faction)
    Overlord.Leaderboard.kills[name] = total
    Overlord.Leaderboard.playerInfo[name] = { class = "WARRIOR", faction = faction, level = 60, locale = "enus", guild = "", guildAt = 0 }
end
local serial = 0
local function kOnChannel(name, total, faction)
    serial = serial + 1
    local payload = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 60)
    net:Receive("eu|x-" .. serial .. "|" .. time() .. "|*|" .. name .. "|K|" .. payload, name, "CHANNEL")
end
local function lkRow(name, total, faction)
    local bucket = s:BuildKillBroadcastPayload(name, "", total, "WARRIOR", faction, EPOCH, "", "enus", 0, EPOCH, 60)
        :match(":(B%d+)")
    return table.concat({ name, tostring(total), "WARRIOR", faction, tostring(EPOCH), "enus", "", "0",
        bucket or "B0", "60" }, ":")
end

-- ===== Stage 1: a Horde client passes its channel's Horde totals to its Alliance friend.
Overlord.PlayerFaction = "Horde"
know("Horde Killer", 200, "Horde")
-- No opposite-faction friend: nothing leaves.
kOnChannel("Horde Killer", 203, "Horde")
advance(2)
assert(Overlord.Leaderboard.kills["Horde Killer"] == 203, "fixture: the owner's K is accepted")
assert(#bnetRows == 0, "a total was sent without any opposite-faction friend")
-- With an Alliance friend: one row to that friend.
friends = { 7, faction = { [7] = "Alliance" } }
advance(70)
kOnChannel("Horde Killer", 206, "Horde")
advance(2)
assert(#bnetRows == 1 and bnetRows[1].id == 7, "the Horde total did not reach the Alliance friend")
assert(bnetRows[1].payload:match("^Horde Killer:206:"), "wrong outbound row: " .. bnetRows[1].payload)
-- 60 s per subject: a burst of kills gives one trailing row with the newest total.
for step = 1, 5 do advance(5); kOnChannel("Horde Killer", 206 + step, "Horde") end
assert(#bnetRows == 1, "a second row left inside the 60 s gap")
advance(40)
assert(#bnetRows == 2 and bnetRows[2].payload:match("^Horde Killer:211:"), "trailing outbound row missing")
-- 6 rows/min across subjects.
advance(120)
local before = #bnetRows
for i = 1, 9 do
    local name = "Horde Extra" .. string.char(96 + i)
    know(name, 50, "Horde")
    kOnChannel(name, 53, "Horde")
end
advance(30)
assert(#bnetRows - before <= 6, "more than 6 outbound rows in a minute: " .. (#bnetRows - before))
advance(90)
assert(#bnetRows - before == 9, "delayed outbound rows were lost: " .. (#bnetRows - before))
-- An Alliance total heard by this Horde client is never sent back out by stage 1.
advance(120)
before = #bnetRows
know("Ally Visitor", 10, "Alliance")
s:OnReceiveLeaderboardKills(lkRow("Ally Visitor", 12, "Alliance"), "Peer Horde", "CHANNEL")
advance(70)
assert(#bnetRows == before, "a received total was passed on as if heard from its owner")

-- ===== Stage 2: an Alliance client puts an enemy total from its Horde friend on its channel.
Overlord.PlayerFaction = "Alliance"
friends = { 9, faction = { [9] = "Horde" } }
channelRows = {}
know("Horde Far", 300, "Horde")
s:OnReceiveLeaderboardKills(lkRow("Horde Far", 305, "Horde"), "BNet-9", "BNET")
advance(2)
assert(Overlord.Leaderboard.kills["Horde Far"] == 305, "fixture: the friend's row is accepted")
assert(#channelRows == 1 and channelRows[1]:match("^LK:Horde Far:305:"), "enemy total not put on the channel")
-- Unknown subject, own-faction subject, or a total that did not grow: nothing.
s:OnReceiveLeaderboardKills(lkRow("Horde Unknown", 50, "Horde"), "BNet-9", "BNET")
know("Ally Mate", 40, "Alliance")
s:OnReceiveLeaderboardKills(lkRow("Ally Mate", 45, "Alliance"), "BNet-9", "BNET")
s:OnReceiveLeaderboardKills(lkRow("Horde Far", 305, "Horde"), "BNet-9", "BNET")
advance(70)
assert(#channelRows == 1, "a row went on the channel for an unknown, own-faction or unchanged total")
-- A row heard on the channel never triggers a channel send (no loop).
s:OnReceiveLeaderboardKills(lkRow("Horde Far", 309, "Horde"), "Other Bridge", "CHANNEL")
advance(70)
assert(#channelRows == 1, "a channel row was echoed back on the channel")
assert(Overlord.Leaderboard.kills["Horde Far"] == 309, "fixture: channel rows are still accepted")
-- Jump guard: an implausible unsolicited total is clamped to 30 kills + 1/s since the
-- last total retained for that subject (1.4.2); the full 5000 never reaches the ladder
-- nor the channel, only the bounded value may.
advance(10)
s:OnReceiveLeaderboardKills(lkRow("Horde Far", 5000, "Horde"), "BNet-9", "BNET")
advance(70)
assert(Overlord.Leaderboard.kills["Horde Far"] <= 309 + 30 + 80 + 10,
    "an implausible jump was accepted locally: " .. tostring(Overlord.Leaderboard.kills["Horde Far"]))
for _, row in ipairs(channelRows) do
    assert(not row:match(":5000:"), "an implausible jump was put on the channel")
end

-- ===== Coverage: another bridge already put the same total on the channel.
know("Horde Busy", 100, "Horde")
s:OnReceiveLeaderboardKills(lkRow("Horde Busy", 102, "Horde"), "BNet-9", "BNET")
advance(2)
local sentBusy = #channelRows
assert(channelRows[sentBusy]:match("^LK:Horde Busy:102:"), "first busy row missing")
advance(10)
s:OnReceiveLeaderboardKills(lkRow("Horde Busy", 104, "Horde"), "BNet-9", "BNET") -- waits for the 60 s gap
s:OnReceiveLeaderboardKills(lkRow("Horde Busy", 104, "Horde"), "Other Bridge", "CHANNEL")
advance(80)
assert(#channelRows == sentBusy, "a total another bridge already sent was repeated on the channel")
assert((net.stats.bridgeLKCovered or 0) >= 1)
-- ===== Random hold: with the real 2-15 s wait, a copy another bridge puts on the
-- channel during our wait cancels ours, so bridges do not all send the same row.
net.BridgeChannelHold = { 2, 15 }
advance(120)
know("Horde Race", 70, "Horde")
local beforeRace = #channelRows
s:OnReceiveLeaderboardKills(lkRow("Horde Race", 72, "Horde"), "BNet-9", "BNET")
advance(1)
assert(#channelRows == beforeRace, "the channel copy left without the random hold")
s:OnReceiveLeaderboardKills(lkRow("Horde Race", 72, "Horde"), "Other Bridge", "CHANNEL")
advance(30)
assert(#channelRows == beforeRace, "a copy heard during the hold was repeated")
-- Alone, the row still goes out within the hold (fixed 10 s here for exact timings).
net.BridgeChannelHold = { 10, 10 }
know("Horde Alone", 80, "Horde")
s:OnReceiveLeaderboardKills(lkRow("Horde Alone", 82, "Horde"), "BNet-9", "BNET")
advance(16)
assert(#channelRows == beforeRace + 1 and channelRows[#channelRows]:match("^LK:Horde Alone:82:"),
    "a row with no other bridge did not leave after its hold")
-- The next total of the same subject waits past its 60 s gap plus a new random
-- hold: bridges that all sent together do not all send again in the same second.
local sentAlone = #channelRows
s:OnReceiveLeaderboardKills(lkRow("Horde Alone", 84, "Horde"), "BNet-9", "BNET")
advance(61)
assert(#channelRows == sentAlone, "the next copy left right at the end of the 60 s gap")
s:OnReceiveLeaderboardKills(lkRow("Horde Alone", 84, "Horde"), "Other Bridge", "CHANNEL")
advance(30)
assert(#channelRows == sentAlone, "a copy another bridge sent after the gap was repeated")
-- Two active subjects: a row with a near hold is not kept waiting behind the
-- long timer of another subject (the timer moves earlier).
advance(120)
know("Horde First", 20, "Horde")
know("Horde Second", 30, "Horde")
s:OnReceiveLeaderboardKills(lkRow("Horde First", 22, "Horde"), "BNet-9", "BNET")
advance(11)
local firstSent = #channelRows
assert(channelRows[firstSent]:match("^LK:Horde First:22:"), "first subject not sent after its hold")
s:OnReceiveLeaderboardKills(lkRow("Horde First", 24, "Horde"), "BNet-9", "BNET") -- long wait (gap + hold)
advance(1)
s:OnReceiveLeaderboardKills(lkRow("Horde Second", 32, "Horde"), "BNet-9", "BNET") -- 10 s hold
advance(11)
assert(#channelRows == firstSent + 1 and channelRows[#channelRows]:match("^LK:Horde Second:32:"),
    "a near row waited behind another subject's long timer")
-- /ov network shows where enemy totals came from and what our bridge did.
assert((net.stats.enemyTotalsFromFriends or 0) >= 1, "enemy totals from friends not counted")
assert((net.stats.enemyTotalsFromChannel or 0) >= 1, "enemy totals from the channel not counted")
local report = table.concat(net:GetKindDiagnostics(12), " ")
assert(report:find("Enemy live totals received:", 1, true), "cross-faction line missing from /ov network")
print("Forever cross-faction bridge: own-faction totals to enemy friends, enemy totals to the channel, bounds, no loop, no duplicate OK")
