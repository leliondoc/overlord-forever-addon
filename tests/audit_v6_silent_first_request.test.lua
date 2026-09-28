-- Real v6 control messages with deterministic wire loss and a temporarily busy
-- responder. No leaderboard rows are needed to exercise the first handshake.
local now, serial, pending = 100, 0, {}
local function later(delay, run)
    serial = serial + 1
    pending[#pending + 1] = { at = now + delay, serial = serial, run = run }
end
local function advance(seconds)
    local stop, steps = now + seconds, 0
    while #pending > 0 do
        table.sort(pending, function(a, b)
            return a.at < b.at or (a.at == b.at and a.serial < b.serial)
        end)
        if pending[1].at > stop then break end
        local item = table.remove(pending, 1)
        now = item.at
        item.run()
        steps = steps + 1
        assert(steps < 100000, "Unbounded v6 handshake work")
    end
    now = stop
end
local function client(name)
    local e = setmetatable({}, { __index = _G })
    e._G = e
    e.GetTime = function() return now end
    e.GetServerTime = function() return 1790017000 + math.floor(now) end
    e.time = e.GetServerTime
    e.InCombatLockdown = function() return e.busy == true end
    e.IsInInstance = function() return false end
    e.C_Timer = { After = later }
    e.strsplit = function(sep, value, limit)
        local fields, start = {}, 1
        while not limit or #fields < limit - 1 do
            local at = value:find(sep, start, true)
            if not at then break end
            fields[#fields + 1] = value:sub(start, at - 1)
            start = at + #sep
        end
        fields[#fields + 1] = value:sub(start)
        return unpack(fields)
    end
    e.OverlordDB = {}
    local snapshot = { kills = {}, captureCount = {}, playerInfo = {} }
    e.Overlord = {
        Sync = {}, Leaderboard = {},
        GetCurrentCampaignStartTs = function() return 1790016000 end,
    }
    local sync, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    sync.NormalizeContributorFullName = function(_, value) return value end
    sync.IsValidPlayerName = function(_, value)
        return type(value) == "string" and value:match("^%a+ %a+$") ~= nil
    end
    sync.GetCaptureContributorDedupKey = function(_, value)
        return type(value) == "string" and value:lower() or nil
    end
    sync.SenderIsInOurGroup = function() return true end
    sync.GetAttestedLeaderboardSnapshot = function() return snapshot end
    lb.SnapshotCurrentCampaignBeforeReset = function(_, callback)
        callback(true)
        return true
    end
    lb.SortNetworkRows = function(_, rows, less) table.sort(rows, less) end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("SyncLeaderboardPages.lua")()
    e.name = name
    return e
end

local function pair()
    local a, b = client("Requester Tester"), client("Responder Tester")
    for _, source in ipairs({ a, b }) do
        local destination = source == a and b or a
        source.hrSent = 0
        source.Overlord.Sync.SendWhisper = function(_, kind, payload, target)
            assert(target == destination.name)
            if source.partialFirstReply and kind == "HA" and payload:match("^6:S:") then
                local version, _, epoch, nonce, seq = payload:match(
                    "^(%d+):(%u):(%d+):(%w+):(%d+):")
                assert(version == "6" and seq)
                -- Valid HA page header, but its HB body is lost. This peer is
                -- known to support v6, so the silent-first-HR probes must stop.
                payload = table.concat({ "6", "P", epoch, nonce, seq,
                    "1", "0", "1", "-", "1", "LK" }, ":")
            end
            if kind == "HR" and payload:match("^6:Q:") then
                source.firstHR = source.firstHR or payload
                if payload == source.firstHR then
                    source.hrSent = source.hrSent + 1
                end
                if source.dropAllHR or (source.dropFirstHR and payload == source.firstHR
                    and source.hrSent == 1) then
                    return true -- accepted locally, lost before the recipient
                end
            end
            later(0.01, function()
                destination.Overlord.Sync:OnPagedLeaderboardMessage(
                    kind, payload, source.name, "WHISPER")
            end)
            return true
        end
    end
    return a, b
end

local function start(a, b)
    local done, supported
    assert(a.Overlord.Sync:StartPagedLeaderboardCatchup(b.name,
        function(ok, capable) done, supported = ok, capable end, true))
    return function() return done, supported end
end

local a, b = pair()
a.dropFirstHR = true
local result = start(a, b)
advance(80)
assert(a.hrSent == 1 and result() == nil, "First lost HR was not silent")
advance(90)
assert(a.hrSent == 2 and result() == true,
    "A lost first HR waited for the 270-second unsupported timeout")
assert(a.Overlord.Sync._leaderboardPageStats.retries == 1,
    "Lost HR retry was not recorded")

a, b = pair()
b.busy = true
later(20, function() b.busy = false end)
result = start(a, b)
advance(170)
assert(a.hrSent == 2 and result() == true,
    "A briefly busy responder silently lost the first HR for 270 seconds")

a, b = pair()
a.dropAllHR = true
result = start(a, b)
advance(269)
assert(a.hrSent == 3 and result() == nil,
    "Silent request probes were unbounded or changed the original deadline")
advance(2)
assert(result() == false and a.hrSent == 3,
    "A permanently silent peer escaped the original 270-second deadline")

a, b = pair()
result = start(a, b)
advance(100)
assert(result() == true and a.hrSent == 1,
    "A valid early response did not cancel the two silent probes")

a, b = pair()
b.partialFirstReply = true
result = start(a, b)
advance(200)
assert(result() == nil and a.hrSent == 1,
    "Valid HA with missing HB did not cancel silent-first-HR probes")

a, b = pair()
a.dropFirstHR = true
result = start(a, b)
later(70, function() a.busy = true end)
later(130, function() a.busy = false end)
advance(115)
assert(a.hrSent == 1, "Combat pause emitted a silent HR probe")
advance(120)
assert(a.hrSent == 2 and result() == true,
    "Combat pause lost the bounded probe or extended the round indefinitely")

a, b = pair()
a.dropAllHR = true
result = start(a, b)
later(70, function() a.busy = true end)
later(230, function() a.busy = false end)
advance(255)
assert(a.hrSent == 2 and result() == nil,
    "Combat pause collapsed the 90- and 180-second probes into a burst")
advance(95)
assert(a.hrSent == 3 and result() == nil,
    "Second probe did not preserve active-time spacing after combat")
print("v6 silent first HR, busy peer, bounded deadline, early reply and combat pause OK")
