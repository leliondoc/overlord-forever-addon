-- 2.2.2: our settled kill total also reaches the guild mates the relay reaches directly
-- (SyncDirectory SettleNext). Nobody greets a guild mate, so they were hardly ever contacts and
-- our guild had our total from the ranking rounds only, minutes later. Owner only, once per mate
-- and total, inside SETTLE_MAX, 2.2.2 or later only, a mate heard in the last hour only.
-- Real relay, guild lane and directory; the routes, the clock and the relay's Send are stubs.
math.randomseed(13)
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
function InCombatLockdown() return false end
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncGuild.lua"))()
assert(loadfile("SyncDirectory.lua"))()
local net, dir, lane = Overlord.Relay, Overlord.ChannelDirectory, Overlord.GuildLane
Overlord.PlayerFaction = "Alliance"
function IsInInstance() return false end
function IsInGuild() return true end
function IsInGroup() return false end
function IsInRaid() return false end
function GetGuildInfo() return "Settle Guild" end
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

dir.IsActive = function() return true end
-- Three contacts of the list, and ten guild mates heard in the guild with a direct route (no
-- contact among them: nobody greets a guild mate).
local direct = {}
for i = 1, 3 do
    local name = "Contact " .. string.char(96 + i)
    dir.names[i] = name
    dir.partners[name:lower()] = { name = name, heardAt = clock, chainAt = clock }
    direct[name:lower()] = true
end
local mates = {}
for i = 1, 10 do
    local name = "Mate " .. string.char(96 + i)
    mates[i] = name
    lane.peers[name:lower()] = clock
    net.peers[name:lower()] = { name = name, at = clock, hops = 1, via = name }
    direct[name:lower()] = true
end
lane.peerCountAt = nil
net.IsDirectPeer = function(_, name) return direct[tostring(name):lower()] == true end
local releases = {}
net.GetPeerReleaseWithin = function(_, name) return releases[tostring(name):lower()] or "2.2.2" end
local sent = {}
net.Send = function(_, kind, payload, target)
    sent[#sent + 1] = { kind = kind, payload = payload, target = target, at = clock }
    return true
end
local function packet(payload)
    return { region = "global", id = "t-" .. tostring(clock), at = GetServerTime(), target = "*",
        path = { me }, kind = "K", payload = payload }
end
local function total(n) return ("%s:elwynn:%d:WARRIOR:Alliance:1"):format(me, n) end
-- The whispers of one total (an older total may still be settling to a mate heard since).
local function told(payload)
    local out, n = {}, 0
    for _, row in ipairs(sent) do
        assert(row.kind == "K", "the settle sent something else than a K")
        if row.payload == payload then
            local key = row.target:lower()
            assert(not out[key], "told twice: " .. row.target)
            out[key], n = row.payload, n + 1
        end
    end
    return out, n
end

-- 1. The first fan, then the settle: every contact and every guild mate not in the fan, once,
-- our own total only, at SETTLE_GAP or more.
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local first = dir:ChainTargets(packet(total(12)), 1)
assert(first and #first > 0, "our total did not leave")
local fanned = {}
for _, name in ipairs(first) do fanned[name:lower()] = true end
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 200)
local got, n = told(total(12))
for _, name in ipairs(mates) do
    local key = name:lower()
    assert(fanned[key] or got[key] == total(12), "a guild mate never had our settled total: " .. name)
    assert(not (fanned[key] and got[key]), "a guild mate of the first fan was told again: " .. name)
end
assert(n <= dir.SETTLE_MAX, "past SETTLE_MAX")
for i = 2, #sent do assert(sent[i].at - sent[i - 1].at >= dir.SETTLE_GAP, "settle whispers too close") end

-- 2. A newer total: told again to every mate, once.
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
local second = dir:ChainTargets(packet(total(15)), 1)
fanned = {}
for _, name in ipairs(second or {}) do fanned[name:lower()] = true end
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 200)
got = told(total(15))
for _, name in ipairs(mates) do
    assert(fanned[name:lower()] or got[name:lower()] == total(15), "a newer total missed a guild mate: " .. name)
end

-- 3. Never to a mate on an earlier release, one not heard in the guild for an hour, one the relay
-- does not reach directly, or ourselves; never past SETTLE_MAX with a big guild.
releases[mates[1]:lower()] = "2.2.1"
lane.peers[mates[2]:lower()] = clock - lane.PEER_MEMORY - 1
direct[mates[3]:lower()] = nil
lane.peers[me:lower()] = clock
net.peers[me:lower()] = { name = me, at = clock, hops = 1, via = me }
direct[me:lower()] = true
for i = 11, 60 do
    local name = "Mate " .. string.char(96 + math.ceil(i / 26)) .. string.char(96 + (i - 1) % 26 + 1)
    lane.peers[name:lower()] = clock
    net.peers[name:lower()] = { name = name, at = clock, hops = 1, via = name }
    direct[name:lower()] = true
end
lane.peerCountAt = nil
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(18)), 1)
advance(dir.SETTLE_QUIET + dir.SETTLE_JITTER + 600)
got, n = told(total(18))
for i = 1, 3 do assert(not got[mates[i]:lower()], "a guild mate that must be left out was told: " .. mates[i]) end
assert(not got[me:lower()], "we told ourselves")
assert(n == dir.SETTLE_MAX, "a big guild was not capped at SETTLE_MAX: " .. n)

-- 4. In an instance: nothing.
sent = {}
advance(dir.RANK_GAP)
dir.chain.tokens, dir.chain.at = dir.CHAIN_BURST, clock
dir:ChainTargets(packet(total(21)), 1)
dir:Suspend()
dir.IsActive = function() return false end
advance(900)
assert(#sent == 0, "the settle went on in an instance")

print("Ladder settle to guild mates: direct mates once per total, 2.2.2+, heard lately, SETTLE_MAX, instances OK")
