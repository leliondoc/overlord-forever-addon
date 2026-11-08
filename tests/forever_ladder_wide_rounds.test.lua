-- 2.2.2: wide rounds. Between two 2.2.2 clients the differing buckets of a stream are listed (M)
-- and their wanted rows asked (N) in a few exchanges instead of one list and one page per
-- bucket (L, G). Same rows, same acceptance; a neighbour before 2.2.2 is asked the old way.
-- Real HR/HA/HB, relay and page acceptance; only WoW transports and the clock are simulated.
local now, serial, pending, clients = 100, 0, {}, {}
local function later(delay, run)
    serial = serial + 1
    pending[#pending + 1] = { at = now + delay, run = run, serial = serial }
end
local function advance(seconds)
    local stop, steps = now + seconds, 0
    while #pending > 0 do
        table.sort(pending, function(a, b)
            return a.at < b.at or (a.at == b.at and a.serial < b.serial)
        end)
        if pending[1].at > stop then break end
        local event = table.remove(pending, 1)
        now = event.at
        event.run()
        steps = steps + 1
        assert(steps < 200000, "Unbounded catchup work")
    end
    now = stop
    for _, c in ipairs(clients) do
        assert(not c.Overlord.Relay.stats.lastError, c.Overlord.Relay.stats.lastError)
    end
end
local function client(name, channel, faction)
    local e = setmetatable({}, { __index = _G })
    e._G, e.print = e, function() end
    e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
    e.loadfile("tests/forever_world_kills.test.lua")()
    e.loadfile("Leaderboard.lua")()
    e.name, e.channel, e.friends = name, channel, {}
    e.GetTime = function() return now end
    e.time = function() return 1790017000 + math.floor(now) end
    e.GetServerTime = e.time
    e.UnitName = function() return name end
    e.UnitFullName = function() return name, "" end
    e.GetUnitName = e.UnitName
    e.UnitFactionGroup = function() return faction end
    e.Overlord.PlayerFaction = faction
    e.InCombatLockdown = function() return false end
    e.C_Timer = {
        After = later,
        NewTicker = function(delay, callback)
            local ticker = { Cancel = function(self) self.cancelled = true end }
            local function tick()
                if ticker.cancelled then return end
                callback()
                if not ticker.cancelled then later(delay, tick) end
            end
            later(delay, tick)
            return ticker
        end,
    }
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
    e.C_Club = { GetSubscribedClubs = function() return {} end }
    e.Enum = { ClubType = { Character = 1 } }
    local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
    s.GetPlayerFullName = function() return name end
    s.GetChannelId = function() return 1 end
    s.GetBetaBNetTargets = function() return e.friends end
    s.SendToChannel = function(_, kind, fragment)
        assert(#kind + #fragment + 1 <= 255)
        for _, other in ipairs(clients) do
            if other ~= e and other.channel == channel then
                other.Overlord.Sync:OnAddonMessage("OverlordF", kind .. ":" .. fragment, "CHANNEL", name)
            end
        end
        return true
    end
    s.SendToBNet = function(_, other, kind, wire)
        if kind == "BR" then
            other.Overlord.Relay:Receive(wire, name, "BNET", e)
        else
            other.Overlord.Relay:ReceiveFragment(wire, name, "BNET", e)
        end
        return true
    end
    e.securecall = function(fn, ...) return fn(...) end
    e.C_ChatInfo = { SendAddonMessage = function(prefix, message, transport, target)
        assert(transport == "WHISPER", "Invalid direct transport")
        assert(#message <= 255, "whisper over 255 bytes")
        for _, other in ipairs(clients) do
            if other.name == target then
                local destination = other
                assert(message:sub(1, 3) == "BF:" or destination.channel == channel,
                    "Raw cross-faction reply")
                later(0.05, function()
                    destination.Overlord.Sync:OnAddonMessage(prefix, message, transport, name)
                end)
            end
        end
    end }
    lb.kills, lb.captureCount, lb.captures, lb.playerInfo = {}, {}, {}, {}
    lb._storageBound = true
    e.loadfile("SyncHistoryCatchup.lua")()
    e.loadfile("SyncLeaderboardPages.lua")()
    e.loadfile("SyncRelay.lua")()
    s.SendSyncRequest = function() return true end
    clients[#clients + 1] = e
    return e
end

local function scenario(sourceVersion, pullerName, sourceName)
    local firstClient = #clients + 1
    local PULLER = client(pullerName, "alliance", "Alliance")
    local SOURCE = client(sourceName, "alliance", "Alliance")
    PULLER.Overlord.Version, SOURCE.Overlord.Version = "2.2.2", sourceVersion
    for _, e in ipairs({ PULLER, SOURCE }) do
        e.Overlord.Relay:Broadcast("NH", e.Overlord.Version)
    end
    advance(10)
    local names = {}
    for i = 1, 300 do
        local n = i - 1
        names[i] = "Player " .. string.char(65 + math.floor(n / 676)) .. string.char(97 + math.floor(n / 26) % 26)
            .. string.char(97 + n % 26)
        for _, e in ipairs({ PULLER, SOURCE }) do
            local lb = e.Overlord.Leaderboard
            lb.kills[names[i]] = i
            lb.playerInfo[names[i]] = { class = "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
                guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
        end
    end
    -- Rows of the source that moved on: spread over most of the 64 buckets.
    local moved = {}
    for i = 3, 300, 7 do
        SOURCE.Overlord.Leaderboard:SetPlayerKills(names[i], 5000 + i, true)
        moved[#moved + 1] = names[i]
    end
    local ops = {}
    local send = PULLER.Overlord.Sync.SendWhisper
    PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HR" then
            local op = payload:match("^8:(%u):")
            if op then ops[op] = (ops[op] or 0) + 1; ops.all = (ops.all or 0) + 1 end
        end
        return send(self, kind, payload, target)
    end
    local done
    local started, why = PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end)
    assert(started, tostring(why))
    for _ = 1, 200 do advance(30); if done ~= nil then break end end
    assert(done == true, "pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    for _, name in ipairs(moved) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name],
            "a moved row did not arrive: " .. name)
    end
    for _, name in ipairs(names) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "row differs: " .. name)
    end
    return ops, PULLER.Overlord.Sync._leaderboardPageStats
end

local wideOps, wideStats = scenario("2.2.2", "Puller Tester", "Source Tester")
assert((wideOps.M or 0) >= 1 and (wideOps.N or 0) >= 1, "a 2.2.2 neighbour was not asked the wide way")
assert((wideStats.wideRounds or 0) >= 1, "no wide round counted")
assert(not wideOps.L and not wideOps.G, "buckets were still walked one by one: L=" .. tostring(wideOps.L)
    .. " G=" .. tostring(wideOps.G))
local oldOps = scenario("2.2.1", "Olden Tester", "Elder Tester")
assert(not oldOps.M and not oldOps.N, "a 2.2.1 neighbour was sent a wide request")
assert((oldOps.L or 0) + (oldOps.G or 0) >= 10, "fixture: the old way should walk the buckets")
assert(wideOps.all * 3 <= oldOps.all, "wide rounds did not cut the exchanges: " .. wideOps.all .. " against " .. oldOps.all)
print("wide rounds: " .. wideOps.all .. " requests (M " .. wideOps.M .. ", N " .. wideOps.N .. ") against "
    .. oldOps.all .. " bucket by bucket (L " .. (oldOps.L or 0) .. ", G " .. (oldOps.G or 0) .. ")")

-- ---------------------------------------------------------------------------
-- 2.2.2 follow-up: kill hints in the lists, refusals, big buckets, split lists, busy peer.
-- Fixtures below tamper with what SOURCE puts on the wire (same wire, hash and chunking
-- as the real answers) to check that a wrong answer is refused before it touches anything.
-- ---------------------------------------------------------------------------
local B64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local function bitmapSet(bitmap)
    local set = {}
    for k = 1, #bitmap do
        local value = B64:find(bitmap:sub(k, k), 1, true) - 1
        for bit = 0, 5 do
            if math.floor(value / 2 ^ bit) % 2 == 1 then set[(k - 1) * 6 + bit + 1] = true end
        end
    end
    return set
end
local function wireHash(text)
    local h = 0
    for i = 1, #text do h = (h * 31 + text:byte(i)) % 2147483647 end
    return h
end
local function bucketOf(e, name)
    return wireHash(e.Overlord.Sync:GetCaptureContributorDedupKey(name):lower()) % 64 + 1
end
local function letters(i, prefix)
    local n = i - 1
    return prefix .. " " .. string.char(65 + math.floor(n / 17576) % 26) .. string.char(97 + math.floor(n / 676) % 26)
        .. string.char(97 + math.floor(n / 26) % 26) .. string.char(97 + n % 26)
end
local pairSerial = 0
local function newPair()
    pairSerial = pairSerial + 1
    local PULLER = client("Pull" .. string.char(96 + pairSerial) .. " Hinter", "alliance", "Alliance")
    local SOURCE = client("Sour" .. string.char(96 + pairSerial) .. " Hinter", "alliance", "Alliance")
    PULLER.Overlord.Version, SOURCE.Overlord.Version = "2.2.2", "2.2.2"
    for _, e in ipairs({ PULLER, SOURCE }) do e.Overlord.Relay:Broadcast("NH", e.Overlord.Version) end
    advance(10)
    return PULLER, SOURCE
end
local function setRow(e, name, kills, class)
    local lb = e.Overlord.Leaderboard
    lb.kills[name] = kills
    lb.playerInfo[name] = { class = class or "WARRIOR", faction = "Alliance", level = 60, locale = "engb",
        guild = "Veteran Guild", guildAt = 1790016000, guildAuth = true, race = "Human", raceSex = 2, raceAt = 1 }
end
-- Wraps what SOURCE sends: an answer of this op is held until whole, handed to mutate(info),
-- and sent again (re-chunked, hash recomputed) when mutate returns changes; nil leaves it as it was.
local function tamper(SOURCE, op, mutate)
    local sync = SOURCE.Overlord.Sync
    local send = sync.SendWhisper
    local held, seen = nil, 0
    sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" then
            local fields = {}
            for part in (payload .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = part end
            if #fields == 12 and fields[2] == "P" and fields[6] == op then
                held = { fields = fields, raw = {}, chunks = {}, count = 0, payload = payload }
                return true
            end
            held = nil
        elseif kind == "HB" and held then
            local k, total, chunk = payload:match("^8:D:%d+:%w+:%d+:(%d+):(%d+):%w+:(.*)$")
            k, total = tonumber(k), tonumber(total)
            held.raw[k], held.chunks[k], held.count = payload, chunk, held.count + 1
            if held.count < total then return true end
            local mine = held
            held = nil
            seen = seen + 1
            local result = mutate({ blob = table.concat(mine.chunks), fields = mine.fields, n = seen })
            if not result then
                later(0.1, function() send(self, "HA", mine.payload, target) end)
                for i = 1, total do later(0.1 + 0.3 * i, function() send(self, "HB", mine.raw[i], target) end) end
                return true
            end
            local f = mine.fields
            local blob = result.blob or table.concat(mine.chunks)
            local parts = math.max(1, math.ceil(#blob / 170))
            f[8] = tostring(result.rows or f[8])
            f[9] = tostring(wireHash(blob))
            f[10] = result.cursor or f[10]
            f[11] = tostring(parts)
            local headerPayload = table.concat(f, ":")
            later(0.1, function() send(self, "HA", headerPayload, target) end)
            local prefix = table.concat({ "8", "D", f[3], f[4], f[5] }, ":") .. ":"
            for i = 1, parts do
                local piece = prefix .. i .. ":" .. parts .. ":" .. f[12] .. ":" .. blob:sub((i - 1) * 170 + 1, i * 170)
                later(0.1 + 0.3 * i, function() send(self, "HB", piece, target) end)
            end
            return true
        end
        return send(self, kind, payload, target)
    end
end
-- The groups of an M answer: header (bucket, count) then its entries.
local function mGroups(blob)
    local groups, pos = {}, 1
    while pos <= #blob do
        local count = tonumber(blob:sub(pos + 2, pos + 4))
        local size = 5
        if count ~= 999 then size = size + (count >= 500 and 10 or 5) * (count >= 500 and count - 500 or count) end
        groups[#groups + 1] = { bucket = tonumber(blob:sub(pos, pos + 1)), text = blob:sub(pos, pos + size - 1) }
        pos = pos + size
    end
    return groups
end
local function joinGroups(groups)
    local texts = {}
    for i, g in ipairs(groups) do texts[i] = g.text end
    return table.concat(texts)
end
-- Counts what the puller asks (and the buckets of its M requests).
local function watch(PULLER)
    local log = { ops = {}, askedM = {}, at = {} }
    local send = PULLER.Overlord.Sync.SendWhisper
    PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HR" then
            local op = payload:match("^8:(%u):")
            if op then
                log.ops[op] = (log.ops[op] or 0) + 1
                log.at[#log.at + 1] = { op = op, at = now }
                if op == "M" then
                    local bitmap = payload:match("^8:M:%d+:%w+:%d+:%w+:(.+)$")
                    log.askedM[#log.askedM + 1] = bitmapSet(bitmap)
                end
            end
        end
        return send(self, kind, payload, target)
    end
    return log
end
local function pullTo(PULLER, SOURCE, limit)
    local done
    local started, why = PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end)
    assert(started, tostring(why))
    return function(rounds)
        for _ = 1, rounds or limit or 200 do advance(30); if done ~= nil then break end end
        return done
    end
end
local function fixture(PULLER, SOURCE, count, step)
    local names, moved = {}, {}
    for i = 1, count do
        names[i] = letters(i, "Fixt")
        setRow(PULLER, names[i], i)
        setRow(SOURCE, names[i], i)
    end
    for i = 3, count, step do
        SOURCE.Overlord.Leaderboard:SetPlayerKills(names[i], 5000 + i, true)
        moved[#moved + 1] = names[i]
    end
    return names, moved
end
local function expectUnchanged(PULLER, list, was, label)
    for _, name in ipairs(list) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == was(name), label .. ": " .. name .. " changed to "
            .. tostring(PULLER.Overlord.Leaderboard.kills[name]))
    end
end
local function expectEqual(PULLER, SOURCE, names, label)
    for _, name in ipairs(names) do
        assert(PULLER.Overlord.Leaderboard.kills[name] == SOURCE.Overlord.Leaderboard.kills[name],
            label .. ": row differs " .. name .. " " .. tostring(PULLER.Overlord.Leaderboard.kills[name]) .. " / "
            .. tostring(SOURCE.Overlord.Leaderboard.kills[name]))
    end
end

-- 1. A long list is cut (cursor names the next bucket) and followed by a second M; rows all arrive.
do
    local PULLER, SOURCE = newPair()
    local names = fixture(PULLER, SOURCE, 700, 3)
    local cursors = {}
    tamper(SOURCE, "M", function(info) cursors[#cursors + 1] = info.fields[10]; return nil end)
    local log = watch(PULLER)
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "split lists: pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    expectEqual(PULLER, SOURCE, names, "split lists")
    assert((log.ops.M or 0) >= 2 and cursors[1] ~= "-", "the first list was not cut: M=" .. tostring(log.ops.M)
        .. " cursor=" .. tostring(cursors[1]))
    assert(not log.ops.L and not log.ops.G, "a cut list fell back to L/G")
    print("split lists: " .. log.ops.M .. " M, first cursor " .. cursors[1] .. ", N " .. tostring(log.ops.N))
end

-- 2. Wrong M answers are refused before anything changes: no N is asked, no row moves.
for _, kind in ipairs({ "swap", "unasked", "skip", "cursor" }) do
    local PULLER, SOURCE = newPair()
    local names, moved = fixture(PULLER, SOURCE, 700, 3)
    local log = watch(PULLER)
    local applied = false
    tamper(SOURCE, "M", function(info)
        if info.n ~= 1 then return nil end
        local groups = mGroups(info.blob)
        assert(#groups >= 3, "fixture: groups")
        if kind == "swap" then
            groups[1], groups[2] = groups[2], groups[1]
            applied = true
            return { blob = joinGroups(groups), rows = #joinGroups(groups) / 5 }
        elseif kind == "skip" then
            table.remove(groups, 1)
            applied = true
            return { blob = joinGroups(groups), rows = #joinGroups(groups) / 5 }
        elseif kind == "unasked" then
            local asked = log.askedM[#log.askedM]
            local last = groups[#groups]
            local previous = groups[#groups - 1].bucket
            for b = previous + 1, 64 do
                if not asked[b] then
                    last.text = string.format("%02d", b) .. last.text:sub(3)
                    applied = true
                    return { blob = joinGroups(groups), rows = #joinGroups(groups) / 5 }
                end
            end
            return nil
        else
            applied = true
            return { cursor = info.fields[10] == "-" and "63" or "-" }
        end
    end)
    local wait = pullTo(PULLER, SOURCE)
    for _ = 1, 40 do advance(3); if applied then break end end
    advance(6)
    if applied then
        assert(not log.ops.N, kind .. ": a refused list was followed by an N request")
        for i, name in ipairs(names) do
            local expected = i
            assert(PULLER.Overlord.Leaderboard.kills[name] == expected, kind .. ": a row moved after a refused list: " .. name)
        end
    else
        print("(refusal '" .. kind .. "' had no room in this fixture)")
    end
    assert(wait() == true, kind .. ": the pull did not recover on the clean retry")
    expectEqual(PULLER, SOURCE, names, kind)
end

-- 3. Wrong N answers: a row of a bucket not covered, rows out of order, a page repeating an earlier bucket.
do
    -- names of buckets nobody listed (no moved row there)
    local function run(kind)
        local PULLER, SOURCE = newPair()
        local names, moved = fixture(PULLER, SOURCE, 700, 3)
        local movedBucket = {}
        for _, name in ipairs(moved) do movedBucket[bucketOf(SOURCE, name)] = true end
        local outsider
        for _, name in ipairs(names) do
            if not movedBucket[bucketOf(SOURCE, name)] then outsider = name; break end
        end
        local log = watch(PULLER)
        local firstRows, pageNames, refusedAt = nil, {}, nil
        local function rowsOf(blob)
            local rows, pos = {}, 1
            while pos <= #blob do
                local len, stop = blob:match("^(%d+):()", pos)
                len = tonumber(len)
                rows[#rows + 1] = blob:sub(pos, stop + len - 1)
                pos = stop + len
            end
            return rows
        end
        tamper(SOURCE, "N", function(info)
            local rows = rowsOf(info.blob)
            if info.n == 1 then
                firstRows = rows
                if kind == "uncovered" then
                    assert(outsider, "fixture: an uncovered bucket")
                    local payload = rows[1]:match("^%d+:(.*)$")
                    local oldName = payload:match("^([^:]+):")
                    payload = outsider .. payload:sub(#oldName + 1)
                    rows[1] = #payload .. ":" .. payload
                elseif kind == "order" then
                    rows[1], rows[2] = rows[2], rows[1]
                else
                    return nil
                end
                for _, row in ipairs(rowsOf(info.blob)) do pageNames[#pageNames + 1] = row:match("^%d+:([^:]+):") end
                refusedAt = 1
                return { blob = table.concat(rows), rows = #rows }
            elseif info.n == 2 and kind == "across pages" then
                for _, row in ipairs(rows) do pageNames[#pageNames + 1] = row:match("^%d+:([^:]+):") end
                refusedAt = 2
                return { blob = firstRows[1], rows = 1, cursor = "-" }
            end
            return nil
        end)
        local wait = pullTo(PULLER, SOURCE)
        local lb = PULLER.Overlord.Leaderboard
        for _ = 1, 40 do
            advance(3)
            if refusedAt and (kind ~= "across pages" or refusedAt == 2) then break end
        end
        assert(refusedAt, kind .. ": the page was not tampered with (fixture)")
        advance(5)
        if kind == "across pages" then
            local first = {}
            for _, row in ipairs(firstRows) do first[row:match("^%d+:([^:]+):")] = true end
            for _, name in ipairs(pageNames) do
                if not first[name] then
                    assert(lb.kills[name] < 5000, kind .. ": a row of the refused page was applied: " .. name)
                end
            end
        else
            for _, name in ipairs(pageNames) do
                assert(lb.kills[name] < 5000, kind .. ": a row of the refused page was applied: " .. name)
            end
            assert(lb.kills[outsider] == SOURCE.Overlord.Leaderboard.kills[outsider], "the outsider is not ours to change")
        end
        assert(wait() == true, kind .. ": the pull did not recover on the clean retry")
        expectEqual(PULLER, SOURCE, names, kind)
    end
    run("uncovered")
    run("order")
    run("across pages")
end

-- 4. A bucket too big for a list (count 999) goes back to L and G; the rest stays wide.
do
    local PULLER, SOURCE = newPair()
    local names, big = {}, {}
    local want = 12
    local i = 0
    while #big < 420 do
        i = i + 1
        local name = letters(i, "Bulk")
        if bucketOf(SOURCE, name) == want then big[#big + 1] = name end
    end
    for _, name in ipairs(big) do names[#names + 1] = name end
    for k = 1, 90 do names[#names + 1] = letters(k, "Rest") end
    for k, name in ipairs(names) do setRow(PULLER, name, k); setRow(SOURCE, name, k) end
    local moved = {}
    for k = 5, #names, 9 do
        SOURCE.Overlord.Leaderboard:SetPlayerKills(names[k], 6000 + k, true)
        moved[#moved + 1] = names[k]
    end
    local bigMoved = 0
    for _, name in ipairs(moved) do if bucketOf(SOURCE, name) == want then bigMoved = bigMoved + 1 end end
    assert(bigMoved >= 3, "fixture: moved rows in the big bucket")
    local log = watch(PULLER)
    local wait = pullTo(PULLER, SOURCE)
    assert(wait(400) == true, "big bucket: pull failed")
    expectEqual(PULLER, SOURCE, names, "big bucket")
    assert((log.ops.M or 0) >= 1 and (log.ops.N or 0) >= 1, "the other buckets were not asked the wide way")
    assert((log.ops.L or 0) >= 1 and (log.ops.G or 0) >= 1, "the 999 bucket did not go back to L and G: L="
        .. tostring(log.ops.L) .. " G=" .. tostring(log.ops.G))
    print("big bucket: M " .. log.ops.M .. ", N " .. log.ops.N .. ", L " .. log.ops.L .. ", G " .. log.ops.G)
end

-- 5. Hints: the rows we are ahead on are not asked; the others are (missing, behind, equal total).
do
    local PULLER, SOURCE = newPair()
    local names, ahead, behind, missing, equalMeta = {}, {}, {}, {}, {}
    for i = 1, 160 do
        local name = letters(i, "Hint")
        names[i] = name
        local kind = i % 5
        if kind == 0 then
            setRow(PULLER, name, 100 + i); setRow(SOURCE, name, 100 + i)
        elseif kind == 1 then       -- the source is ahead: asked
            setRow(PULLER, name, 100 + i); setRow(SOURCE, name, 107 + i); behind[#behind + 1] = name
        elseif kind == 2 then       -- we are ahead: not asked
            setRow(PULLER, name, 107 + i); setRow(SOURCE, name, 100 + i); ahead[#ahead + 1] = name
        elseif kind == 3 then       -- we do not know it: asked
            setRow(SOURCE, name, 100 + i); missing[#missing + 1] = name
        else                        -- same total, other class: asked (nothing proves we are ahead)
            setRow(PULLER, name, 100 + i, "MAGE"); setRow(SOURCE, name, 100 + i, "WARRIOR"); equalMeta[#equalMeta + 1] = name
        end
    end
    local log = watch(PULLER)
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "hints: pull failed")
    local stats = PULLER.Overlord.Sync._leaderboardPageStats
    local lb = PULLER.Overlord.Leaderboard
    for _, name in ipairs(behind) do assert(lb.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "behind row not updated " .. name) end
    for _, name in ipairs(missing) do assert(lb.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "missing row not fetched " .. name) end
    for _, name in ipairs(ahead) do assert(lb.kills[name] > SOURCE.Overlord.Leaderboard.kills[name], "an ahead row was lowered " .. name) end
    assert((stats.hintSkipped or 0) == #ahead, "rows we are ahead on must be skipped, and only those: skipped "
        .. tostring(stats.hintSkipped) .. " of " .. #ahead)
    -- (kills: behind + missing + equal-total rows; the race stream adds the rows we lack. A row we are
    -- ahead on is never asked.)
    assert(stats.wanted >= #behind + #missing + #equalMeta and stats.wanted <= #behind + 2 * #missing + #equalMeta,
        "asked rows: " .. tostring(stats.wanted))
    print("hints: " .. #ahead .. " rows skipped of " .. stats.listed .. " listed, " .. stats.wanted .. " asked")
end

-- 5b. Past the frame's hint budget the rows are asked as before (no hint work, same result).
do
    local PULLER, SOURCE = newPair()
    local names = {}
    for i = 1, 120 do
        local name = letters(i, "Budget")
        names[i] = name
        if i % 2 == 0 then
            setRow(PULLER, name, 300 + i); setRow(SOURCE, name, 200 + i)
        else
            setRow(PULLER, name, 200 + i); setRow(SOURCE, name, 300 + i)
        end
    end
    local tuning = PULLER.Overlord.Sync._leaderboardWide
    tuning.hintBudget = 0
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "hint budget: pull failed")
    local stats = PULLER.Overlord.Sync._leaderboardPageStats
    assert((stats.hintSkipped or 0) == 0, "a hint was worked out past the frame's budget")
    local lb = PULLER.Overlord.Leaderboard
    for i, name in ipairs(names) do
        assert(lb.kills[name] == 300 + i, "hint budget: wrong total for " .. name)
    end
end

-- 5c. Key tags change with the pull: two keys sharing a tag in one pull almost never do in the next.
do
    local tuning = newPair().Overlord.Sync._leaderboardWide
    local seen, pairsFound = {}, {}
    for i = 1, 2000 do
        local key = letters(i, "Tag")
        local tag = tuning.tag(key, 12345, 678)
        assert(tag >= 0 and tag < 16384 and tag == math.floor(tag), "tag out of range")
        if seen[tag] then pairsFound[#pairsFound + 1] = { seen[tag], key } else seen[tag] = key end
    end
    assert(#pairsFound > 0, "fixture: no shared tag in 2000 keys")
    local still = 0
    for _, p in ipairs(pairsFound) do
        if tuning.tag(p[1], 98765, 4321) == tuning.tag(p[2], 98765, 4321) then still = still + 1 end
    end
    assert(still * 10 < #pairsFound, "shared tags stay shared from one pull to the next: " .. still .. " of " .. #pairsFound)
end

-- 6. A lying hint can only make us skip: it never writes a score, never hides a row we lack.
for _, claim in ipairs({ 0, 12345, 65534, 65535 }) do
    local PULLER, SOURCE = newPair()
    local names, original, missing = {}, {}, {}
    for i = 1, 120 do
        local name = letters(i, "Liar")
        names[i] = name
        if i % 4 == 0 then
            setRow(SOURCE, name, 200 + i); missing[#missing + 1] = name
        else
            setRow(PULLER, name, 150 + i); setRow(SOURCE, name, 150 + i + (i % 3 == 0 and 9 or 0))
            original[name] = 150 + i
        end
    end
    tamper(SOURCE, "M", function(info)
        local groups = mGroups(info.blob)
        for _, g in ipairs(groups) do
            local count = tonumber(g.text:sub(3, 5))
            if count ~= 999 and count >= 500 then
                local rebuilt, pos = { g.text:sub(1, 5) }, 6
                for _ = 1, count - 500 do
                    local entry = g.text:sub(pos, pos + 9)
                    local value = 0
                    for c = 6, 10 do value = value * 64 + (B64:find(entry:sub(c, c), 1, true) - 1) end
                    local tag = math.floor(value / 65536)
                    value = tag * 65536 + claim
                    local chars = {}
                    for c = 5, 1, -1 do chars[c] = B64:sub(value % 64 + 1, value % 64 + 1); value = math.floor(value / 64) end
                    rebuilt[#rebuilt + 1] = entry:sub(1, 5) .. table.concat(chars)
                    pos = pos + 10
                end
                g.text = table.concat(rebuilt)
            end
        end
        return { blob = joinGroups(groups) }
    end)
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "lying hint " .. claim .. ": pull failed")
    local lb = PULLER.Overlord.Leaderboard
    for _, name in ipairs(missing) do
        assert(lb.kills[name] == SOURCE.Overlord.Leaderboard.kills[name], "a row we lack was hidden by a hint of " .. claim .. ": " .. name)
    end
    for name, was in pairs(original) do
        local got, theirs = lb.kills[name], SOURCE.Overlord.Leaderboard.kills[name]
        assert(got == was or got == theirs, "a hint wrote a score: " .. name .. " " .. tostring(got) .. " (claim " .. claim .. ")")
        if claim >= 65534 then assert(got == theirs, "a hint of " .. claim .. " must ask every row: " .. name) end
    end
end

-- 7. A busy neighbour answers busy at once; the next pull gets through and converges.
do
    local A, SOURCE = newPair()
    local B = client("Pullz Hinter", "alliance", "Alliance")
    B.Overlord.Version = "2.2.2"
    B.Overlord.Relay:Broadcast("NH", "2.2.2")
    advance(10)
    local names = fixture(A, SOURCE, 120, 3)
    for _, name in ipairs(names) do setRow(B, name, 1) end
    local doneA, doneB
    local okA = A.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) doneA = ok end)
    local okB = B.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) doneB = ok end)
    assert(okA and okB)
    for _ = 1, 200 do advance(30); if doneA ~= nil and doneB ~= nil then break end end
    assert(doneA == true or doneB == true, "one of the two pulls must get through")
    local loser, loserDone = doneA == true and B or A, doneA == true and doneB or doneA
    if loserDone ~= true then
        local why = tostring(loser.Overlord.Sync._leaderboardPageStats.result)
        assert(why:find("busy", 1, true), "the second pull should have been told busy, got: " .. why)
        local retry
        assert(loser.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) retry = ok end))
        for _ = 1, 200 do advance(30); if retry ~= nil then break end end
        assert(retry == true, "the retry after a busy answer failed")
    end
    expectEqual(A, SOURCE, names, "busy retry A")
    expectEqual(B, SOURCE, names, "busy retry B")
end
-- 8. 2.3.0: an M asks the buckets holding at most fpBudget rows of ours (one bucket always): our
-- fingerprints of a list are worked out in the frame it arrives.
do
    local PULLER, SOURCE = newPair()
    local names = fixture(PULLER, SOURCE, 400, 3)
    local ownRows = {}
    for _, name in ipairs(names) do
        local b = bucketOf(PULLER, name)
        ownRows[b] = (ownRows[b] or 0) + 1
    end
    PULLER.Overlord.Sync._leaderboardWide.fpBudget = 40
    local asked = {}
    local send = PULLER.Overlord.Sync.SendWhisper
    PULLER.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        local stream, bitmap
        if kind == "HR" then stream, bitmap = payload:match("^8:M:%d+:%w+:%d+:(%u%u):(.+)$") end
        if stream == "LK" then asked[#asked + 1] = bitmapSet(bitmap) end
        return send(self, kind, payload, target)
    end
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "fingerprint budget: pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    expectEqual(PULLER, SOURCE, names, "fingerprint budget")
    assert(#asked >= 2, "fixture: the kills should take several lists, got " .. #asked)
    for k, set in ipairs(asked) do
        local count, rows = 0, 0
        for b in pairs(set) do count, rows = count + 1, rows + (ownRows[b] or 0) end
        assert(count == 1 or rows <= 40, "list " .. k .. " asked " .. count .. " buckets holding " .. rows
            .. " rows of ours in one frame (budget 40)")
    end
end
-- 8. (2.3.0) A bucket we hold nothing of is not listed: every row of it is wanted, G asks it whole as
-- in 2.2.1 (its list would only add 5-10 bytes a row on the wire).
do
    local PULLER, SOURCE = newPair()
    local names = {}
    for i = 1, 300 do
        names[i] = letters(i, "Cold")
        setRow(SOURCE, names[i], 1000 + i)
        if i <= 40 then setRow(PULLER, names[i], 900 + i) end
    end
    local lb, occupied, empty = PULLER.Overlord.Leaderboard, {}, 0
    local function mark(name)
        local k = PULLER.Overlord.Sync:GetCaptureContributorDedupKey(name)
        if k then occupied[wireHash(k:lower()) % 64 + 1] = true end
    end
    for name in pairs(lb.kills) do mark(name) end
    for name in pairs(lb.playerInfo) do mark(name) end
    for b = 1, 64 do if not occupied[b] then empty = empty + 1 end end
    assert(empty >= 10, "fixture: buckets we hold nothing of")
    local log = watch(PULLER)
    local wait = pullTo(PULLER, SOURCE)
    assert(wait() == true, "cold buckets: pull failed: " .. PULLER.Overlord.Sync:GetPagedLeaderboardDiagnostics())
    expectEqual(PULLER, SOURCE, names, "cold buckets")
    assert((log.ops.M or 0) >= 1, "fixture: the buckets we hold were not listed the wide way")
    for _, asked in ipairs(log.askedM) do
        for b in pairs(asked) do
            assert(occupied[b], "a list was asked for bucket " .. b .. ", where we hold nothing")
        end
    end
    assert((log.ops.G or 0) >= 1, "the buckets we hold nothing of were not asked whole")
end
-- 9. 2.3.0: a partner that stops answering in the middle of a wide round (after its list) is given
-- up as one past its first bucket: 90 s and one retry, not 180 s and two.
do
    local PULLER, SOURCE = newPair()
    fixture(PULLER, SOURCE, 120, 3)
    local send, mSeq, silentAt = SOURCE.Overlord.Sync.SendWhisper, nil, nil
    SOURCE.Overlord.Sync.SendWhisper = function(self, kind, payload, target)
        if kind == "HA" or kind == "HB" then
            local seq = tonumber(payload:match("^8:%u:%d+:%w+:(%d+):"))
            if kind == "HA" and not mSeq and payload:match("^8:P:%d+:%w+:%d+:M:") then mSeq, silentAt = seq, now end
            if mSeq and seq and seq > mSeq then return true end
        end
        return send(self, kind, payload, target)
    end
    local done
    assert(PULLER.Overlord.Sync:StartCompletePagedLeaderboardCatchup(SOURCE.name, function(ok) done = ok end))
    for _ = 1, 120 do advance(10); if done ~= nil then break end end
    assert(silentAt, "fixture: no wide list was served")
    assert(done == false, "the pull with a silent partner did not end")
    assert(now - silentAt <= 240, "a partner silent in a wide round held the pull " .. (now - silentAt) .. " s")
end
print("wide rounds: hints, refusals, big bucket, split lists, busy retry OK")
