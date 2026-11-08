-- 2.2.2: our settled kill total told to the rest of our contacts (SyncDirectory SettleStep).
-- Owner only, once per contact and total, bounded by SETTLE_MAX and the spare tokens, never a
-- total of somebody else, nothing in an instance. Real relay, guild lane and directory; the
-- contacts, the clock and the relay's Send are stubs.
math.randomseed(11)
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
local clock = 1000
function GetTime() return clock end
function GetServerTime() return 1790018000 + math.floor(clock) end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
local fighting = false
function InCombatLockdown() return fighting end
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncGuild.lua"))()
assert(loadfile("SyncDirectory.lua"))()
local net, dir = Overlord.Relay, Overlord.ChannelDirectory
Overlord.PlayerFaction = "Alliance"
function IsInInstance() return false end
function IsInGuild() return false end
function IsInGroup() return false end
function IsInRaid() return false end
local me = s:GetPlayerFullName()

local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        clock = math.max(clock, timer.at)
        timer.fn()
    end
    clock = stop
end

-- Forty players of the list who greeted us (contacts), and four who greeted us from outside
-- the list (leaves).
local active = true
dir.IsActive = function() return active end
local contacts = {}
for i = 1, 40 do
    local name = "Contact " .. string.char(64 + math.ceil(i / 26)) .. string.char(96 + (i - 1) % 26 + 1)
    contacts[i] = name
    dir.names[i] = name
    dir.partners[name:lower()] = { name = name, heardAt = clock, chainAt = clock }
end
for i = 1, 4 do
    local name = "Leaf " .. string.char(96 + i)
    dir.partners[name:lower()] = { name = name, heardAt = clock, chainAt = clock }
end
net.IsDirectPeer = function(_, name) return dir.partners[tostring(name):lower()] ~= nil end
-- Releases our contacts announce (2.2.2 unless set).
local releases = {}
net.GetPeerReleaseWithin = function(_, name) return releases[tostring(name):lower()] or "2.2.2" end

-- Every whisper the settle sends goes through Relay:Send (addressed to one player).
local sent = {}
net.Send = function(_, kind, payload, target)
    sent[#sent + 1] = { kind = kind, payload = payload, target = target, at = clock }
    return true
end
local function packet(payload, path, heardOn)
    return { region = "global", id = "t-" .. tostring(clock), at = GetServerTime(), target = "*",
        path = path or { me }, kind = "K", payload = payload, heardOn = heardOn }
end
local function total(n) return ("%s:elwynn:%d:WARRIOR:Alliance:1"):format(me, n) end

-- 1. Our total leaves first-hand to RANK_FAN contacts; nothing more while it keeps moving.
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local first = dir:ChainTargets(packet(total(12)), 1)
assert(first and #first == dir.RANK_FAN, "our total did not leave")
local fanned = {}
for _, name in ipairs(first) do fanned[name:lower()] = true end
advance(dir.SETTLE_QUIET - 1)
assert(#sent == 0, "the settle started before the total was quiet")

-- 2. Quiet: one whisper every SETTLE_GAP or more, to contacts and leaves not told yet, each once,
-- our own payload only, SETTLE_MAX at most, then nothing.
advance(dir.SETTLE_JITTER + 2 + 600)
assert(#sent == dir.SETTLE_MAX, "settle whispers: " .. #sent)
local seen = {}
for i, row in ipairs(sent) do
    assert(row.kind == "K" and row.payload == total(12), "the settle sent something else than our total")
    local key = row.target:lower()
    assert(not seen[key], "told twice: " .. row.target)
    assert(not fanned[key], "the settle told again a contact of the first fan: " .. row.target)
    assert(dir.partners[key], "the settle whispered a stranger: " .. row.target)
    seen[key] = true
    if i > 1 then assert(row.at - sent[i - 1].at >= dir.SETTLE_GAP, "settle whispers too close") end
end
advance(3600)
assert(#sent == dir.SETTLE_MAX, "the settle went on past SETTLE_MAX")

-- 3. A stable rotation: the order is the hash of our name and theirs, the same on every total.
local function rotation()
    local out = {}
    for _, row in ipairs(sent) do out[#out + 1] = row.target end
    return out
end
local order1 = rotation()
local prevKey
for _, name in ipairs(order1) do
    local key = net.HashFrac(me:lower() .. "|" .. name:lower())
    assert(not prevKey or key > prevKey, "the rotation is not the stable order")
    prevKey = key
end

-- 4. A newer total: told again, the told set starts over (its own first fan left out).
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local second = dir:ChainTargets(packet(total(15)), 1)
assert(second and #second == dir.RANK_FAN, "the newer total did not leave")
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 400)
assert(#sent > 0 and #sent <= dir.SETTLE_MAX, "a newer total was not settled: " .. #sent)
for _, row in ipairs(sent) do assert(row.payload == total(15), "an old total was settled") end
-- The same total again (another zone): no new settle.
local before = #sent
dir:NoteOwnTotal(("%s:westfall:15:WARRIOR:Alliance:1"):format(me))
advance(600)
assert(#sent == before, "the same total was settled twice")

-- 5. Never somebody else's total: a K passed on has no chain shape, nothing is settled.
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
assert(dir:ChainTargets(packet("Other:elwynn:40:MAGE:Alliance:1", { "Other Body", contacts[3], me }, "WHISPER"), 1) == nil,
    "a total of somebody else was passed on")
advance(600)
for _, row in ipairs(sent) do assert(not row.payload:find("^Other:"), "a total of somebody else was settled") end
-- And a receiver credits a K only from its owner (Sync:OnReceiveKill): a relayed origin is refused.
assert(s:KillSyncSenderOwnsPlayer("Other Body", "Other Body") and not s:KillSyncSenderOwnsPlayer(contacts[3], "Other Body"),
    "a K credited to somebody else than its sender")

-- 6. Only spare tokens: below SETTLE_RESERVE nothing leaves, it waits.
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(20)), 1)
local CHAIN_RATE = dir.CHAIN_RATE
dir.CHAIN_RATE = 0
dir.chain.tokens, dir.chain.at = dir.SETTLE_RESERVE, clock
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 120)
assert(#sent == 0, "the settle spent the reserve")
dir.CHAIN_RATE = CHAIN_RATE
advance(600)
assert(#sent > 0, "the settle never resumed with spare tokens")

-- 6b. Never spare tokens for SETTLE_LIFE: given up (no timer left running all evening).
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(22)), 1)
dir.CHAIN_RATE = 0
dir.chain.tokens, dir.chain.at = 0, clock
advance(dir.SETTLE_LIFE + 60)
dir.CHAIN_RATE = CHAIN_RATE
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
advance(600)
assert(#sent == 0, "a settle went on past SETTLE_LIFE")

-- 7. In an instance (Suspend) or with the chain off: nothing more.
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(25)), 1)
dir:Suspend()
advance(900)
assert(#sent == 0, "the settle went on in an instance")
dir:Resume()
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(26)), 1)
active = false
advance(900)
assert(#sent == 0, "the settle went on with the chain off")
active = true

-- 7b. A total still settling when an instance began is told once it is over; guild mates are
-- told too (the guild lane never carries a K).
local lane = Overlord.GuildLane
local laneActive, laneMate = lane.IsActive, lane.IsGuildMate
lane.IsActive, lane.IsGuildMate = function() return true end, function() return true end
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(28)), 1)
advance(5)
dir:Suspend()
advance(300)
assert(#sent == 0, "the settle went on in an instance")
dir:Resume()
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 200)
assert(#sent > 0, "a total settling when the instance began was never told")
for _, row in ipairs(sent) do assert(row.payload == total(28), "the settle after an instance sent another total") end
lane.IsActive, lane.IsGuildMate = laneActive, laneMate

-- 7c. A peer on an earlier release never gets a settled total (it would count it as a kill now).
for lower in pairs(dir.partners) do releases[lower] = "2.2.1" end
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(30)), 1)
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 200)
assert(#sent == 0, "a settled total went to a 2.2.1 peer")
releases = {}

-- 7d. A settled total is no kill made now: the rampage alert's base moves, nothing is counted.
local gka = Overlord.GuildKillAlert
if gka and gka.OnLiveKill then
    local counted = 0
    local fa = Overlord.FrontActivity
    local realRecord = fa and fa.RecordKills
    if fa then fa.RecordKills = function() counted = counted + 1 end end
    gka:OnLiveKill("Late Killer", "Alliance", "Late Guild", 10, "#1429", nil)
    gka:OnLiveKill("Late Killer", "Alliance", "Late Guild", 14, "#1429", nil, true)
    gka:OnLiveKill("Late Killer", "Alliance", "Late Guild", 15, "#1429", nil)
    if fa then fa.RecordKills = realRecord end
    assert(counted <= 2, "a settled total was counted as kills: " .. counted)
end

-- 7e. The directory idle when the step comes (channel seated again for a while): nothing sent,
-- and the rotation goes on once the directory is active again (same total, not dead for good).
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(32)), 1)
sent = {}
active = false
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 30)
assert(#sent == 0, "the settle whispered while the directory was idle")
active = true
advance(120)
assert(#sent > 0, "the settle died for good on one idle step")
for _, row in ipairs(sent) do assert(row.payload == total(32), "the settle after an idle step sent another total") end

-- 7f. A whisper the relay refuses: that contact is not lost for this total, tried again later
-- (not on every step), the others meanwhile.
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(34)), 1)
sent = {}
local refused = dir:SettleNext(dir.chain.settle).name
local accept, tries, realSend = false, 0, net.Send
net.Send = function(relay, kind, payload, target)
    if target == refused and not accept then tries = tries + 1; return false end
    return realSend(relay, kind, payload, target)
end
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 20)
assert(tries == 1, "a refused contact was tried again at once: " .. tries)
assert(#sent > 0, "a refused contact held the rotation")
accept = true
advance(dir.SETTLE_LIFE)
net.Send = realSend
local got = 0
for _, row in ipairs(sent) do if row.target == refused then got = got + 1 end end
assert(got == 1, "a refused contact was lost for this total: " .. got)

-- 7g. A settle given up before an instance (SETTLE_LIFE without spare tokens) stays given up after
-- it: the way out of an instance does not tell an old total again.
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(36)), 1)
dir.CHAIN_RATE = 0
dir.chain.tokens, dir.chain.at = 0, clock
advance(dir.SETTLE_LIFE + 60)
dir.CHAIN_RATE = CHAIN_RATE
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
sent = {}
dir:Suspend()
advance(600)
dir:Resume()
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 200)
assert(#sent == 0, "a settle given up before an instance was told again after it: " .. #sent)

-- 8. Bounded work: one step looks at the partners once (no table per partner kept), and the
-- settle never grows past the partners we have.
assert(dir.SETTLE_MAX <= 40 and dir.SETTLE_GAP >= 2, "settle bounds loosened")

print("Ladder settle: owner-only, once per contact, SETTLE_MAX, stable rotation, spare tokens, instances OK")
