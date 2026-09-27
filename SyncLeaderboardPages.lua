-- Targeted, resumable anti-entropy for 5,000 kills. HR/HB/HA stay routable
-- through v4 bridges; old endpoints ignore version 5 and use the v4 fallback.
local Overlord = _G.Overlord
if not Overlord or not Overlord.Sync then return end
local sync, lb = Overlord.Sync, Overlord.Leaderboard
local BUCKETS, PAGE_ROWS, CHUNK, MAX_PARTS = 64, 16, 170, 24
local MOD, RATE, BURST = 2147483647, 300, 500
local pull, serving, outbound, wake, building
local profiles = setmetatable({}, { __mode = "k" })
local unsupported, unsupportedOrder = {}, {}
local serial, tokens, refillAt = 0, BURST, 0
local stats = { pages = 0, rows = 0, rejected = 0, retries = 0, bytes = 0 }
sync._leaderboardPageStats = stats

local function epoch()
    return math.floor(tonumber(Overlord.GetCurrentCampaignStartTs
        and Overlord:GetCurrentCampaignStartTs()) or 0)
end
local function paused()
    return Overlord.InstanceSuspended or (InCombatLockdown and InCombatLockdown())
        or (IsInInstance and IsInInstance())
end
local function hash(value)
    local h = 0
    for i = 1, #value do h = (h * 31 + value:byte(i)) % MOD end
    return h
end
local function key(name)
    local result = sync:GetCaptureContributorDedupKey(name)
    return result and result:lower()
end
local function integer(value, lo, hi)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= lo and n <= hi and n or nil
end
local function validCursor(value)
    return value == "-" or (type(value) == "string" and #value > 0 and #value <= 100
        and not value:find("[:|%c]"))
end
local function allowed(sender, channel)
    if not sync:IsValidPlayerName(sender) then return false end
    if sync.KillAntiSpoofIsBlacklisted and sync:KillAntiSpoofIsBlacklisted(sender) then return false end
    local net = Overlord.BetaNetwork
    if channel == "BETA" then
        return net and net:IsDispatching(sender) and net:IsTargetedDispatch()
    end
    return channel == "WHISPER" and (
        (sync.SenderIsInOurGroup and sync:SenderIsInOurGroup(sender))
        or (sync.IsOnlineCommunitySender and sync:IsOnlineCommunitySender(sender))
        or (sync.IsEuropeanLeaderboardBridgeSender and sync:IsEuropeanLeaderboardBridgeSender(sender)))
end

-- A single producer queue, paced in estimated wire bytes, also respects live
-- traffic in the relay. No broadcast, no per-peer multiplication of this budget.
local function enqueue(job)
    if outbound then return false end
    outbound = job
    job.at, job.index = GetTime(), 1
    local function pump()
        wake = nil
        if outbound ~= job then return end
        if job.epoch ~= epoch() or (job.valid and not job.valid()) then outbound = nil; return end
        if paused() then job.at = GetTime(); wake = true; C_Timer.After(2, pump); return end
        if GetTime() - job.at > 240 then outbound = nil; return end
        local packet = job.packets[job.index]
        if not packet then outbound = nil; if job.done then job.done() end; return end
        local now, net = GetTime(), Overlord.BetaNetwork
        tokens = math.min(BURST, tokens + math.max(0, now - refillAt) * RATE)
        refillAt = now
        -- Envelope + fragmentation overhead is deliberately charged as well.
        local cost = #packet[2] + 200
        if tokens >= cost and (not net or not net.CanSendLeaderboardPage or net:CanSendLeaderboardPage()) then
            tokens = tokens - cost
            if sync:SendWhisper(packet[1], packet[2], job.peer) ~= false then
                job.index = job.index + 1
                stats.bytes = stats.bytes + cost
                if job.index > #job.packets then
                    outbound = nil
                    if job.done then job.done() end
                    return
                end
            end
        end
        wake = true
        C_Timer.After(0.5, pump)
    end
    if not wake then wake = true; C_Timer.After(0.01, pump) end
    return true
end

-- All scans and sorting yield after 32 work units and a ~1 ms slice.
-- Only complete immutable profiles are published; a snapshot has at most 5,000 rows.
local function prepare(callback)
    if building then return false end
    building = true
    local wanted = epoch()
    local accepted = lb:SnapshotCurrentCampaignBeforeReset(function(ok)
        local snapshot = ok and sync:GetAttestedLeaderboardSnapshot()
        if not snapshot or wanted ~= epoch() then building = nil; callback(nil); return end
        if profiles[snapshot] then building = nil; callback(profiles[snapshot]); return end
        local result = { epoch = wanted, buckets = {}, count = 0, hash = 0 }
        local units, sliceAt = 0, 0
        local function work()
            units = units + 1
            if units >= 32 or (debugprofilestop and debugprofilestop() - sliceAt >= 1) then
                coroutine.yield()
            end
        end
        local co = coroutine.create(function()
            for i = 1, BUCKETS do result.buckets[i] = { hash = 0 }; work() end
            local count = 0
            for name in pairs(snapshot.kills or {}) do
                count = count + 1
                if count > 5000 then error("oversized attested snapshot") end
                local payload = sync:BuildPagedLeaderboardKillPayload(snapshot, name, wanted)
                local identity = payload and key(name)
                if identity and validCursor(identity) then
                    local bucket = result.buckets[hash(identity) % BUCKETS + 1]
                    bucket[#bucket + 1] = { key = identity, payload = payload }
                end
                work()
            end
            for i = 1, BUCKETS do
                local bucket = result.buckets[i]
                lb:SortNetworkRows(bucket, function(a, b) return a.key < b.key end, work)
                for j = 1, #bucket do
                    bucket.hash = (bucket.hash + hash(bucket[j].payload)) % MOD
                    work()
                end
                result.count = result.count + #bucket
                result.hash = (result.hash + bucket.hash) % MOD
            end
        end)
        local function step()
            if wanted ~= epoch() then building = nil; callback(nil); return end
            if paused() then C_Timer.After(2, step); return end
            units, sliceAt = 0, debugprofilestop and debugprofilestop() or 0
            local success, err = coroutine.resume(co)
            if not success then stats.error = tostring(err); building = nil; callback(nil); return end
            if coroutine.status(co) ~= "dead" then C_Timer.After(0.001, step); return end
            profiles[snapshot] = result
            building = nil
            callback(result)
        end
        C_Timer.After(0.001, step)
    end)
    if accepted == false then building = nil; return false end
    return true
end

local function checkpoints()
    local saved = OverlordDB.leaderboardPageProgress
    if type(saved) ~= "table" or saved.epoch ~= epoch() or type(saved.peers) ~= "table" then
        saved = { epoch = epoch(), peers = {} }
        OverlordDB.leaderboardPageProgress = saved
    end
    return saved.peers
end
local function checkpoint(state)
    local peers, count, oldest, oldestAt = checkpoints(), 0, nil, math.huge
    for name, row in pairs(peers) do
        count = count + 1
        local at = type(row) == "table" and tonumber(row.at) or 0
        if (at or 0) < oldestAt then oldest, oldestAt = name, at or 0 end
    end
    if not peers[state.peer] and count >= 8 and oldest then peers[oldest] = nil end
    -- Restart the current bucket after reload: a new snapshot may have changed
    -- its order. Persisting its cursor would silently skip inserted identities.
    peers[state.peer] = { bucket = state.bucket, at = GetServerTime() }
end
local function finish(state, success, unsupportedPeer)
    if pull ~= state then return end
    checkpoint(state)
    pull = nil
    stats.result = success and "sweep received" or "interrupted; bucket retained"
    if unsupportedPeer then
        if not unsupported[state.peer] then
            unsupportedOrder[#unsupportedOrder + 1] = state.peer
            if #unsupportedOrder > 8 then unsupported[table.remove(unsupportedOrder, 1)] = nil end
        end
        unsupported[state.peer] = GetTime() + 600
    end
    state.callback(success, state.supported == true)
end

local request, tryApply
request = function(state, retry)
    if pull ~= state then return end
    if state.epoch ~= epoch() then finish(state, false); return end
    if paused() or outbound then C_Timer.After(2, function() request(state, retry) end); return end
    if not retry then
        state.seq = state.seq + 1
        state.tries, state.parts, state.meta, state.partCount, state.bytes = 0, {}, nil, nil, 0
    end
    state.tries = state.tries + 1
    local bucket = state.profile.buckets[state.bucket]
    local fields = { "5", "Q", state.epoch, state.nonce, state.seq,
        state.bucket, state.cursor, #bucket, bucket.hash }
    if state.seq == 1 then
        fields[#fields + 1], fields[#fields + 2] = state.profile.count, state.profile.hash
    end
    local payload = table.concat(fields, ":")
    local seq, tries = state.seq, state.tries
    enqueue({ epoch = state.epoch, peer = state.peer, packets = { { "HR", payload } },
        valid = function() return pull == state and state.seq == seq end })
    -- Two relay TTLs plus margin also cover a congested first request/reply.
    local remaining = state.supported and 180 or 270
    local function timeout()
        if pull ~= state or state.seq ~= seq or state.tries ~= tries or state.applying then return end
        if state.epoch ~= epoch() then finish(state, false); return end
        if not paused() then remaining = remaining - 2 end
        if remaining > 0 then C_Timer.After(2, timeout); return end
        if state.supported and state.tries < 3 then
            stats.retries = stats.retries + 1
            request(state, true)
        else finish(state, false, not state.supported) end
    end
    C_Timer.After(2, timeout)
end
local function nextPage(state, cursor)
    stats.pages = stats.pages + 1
    if cursor == "-" then
        state.bucket, state.completed = state.bucket % BUCKETS + 1, state.completed + 1
        checkpoint(state)
    end
    state.cursor = cursor
    if state.completed == BUCKETS then
        if not outbound then
            enqueue({ epoch = state.epoch, peer = state.peer, packets = { { "HR",
                table.concat({ "5", "F", state.epoch, state.nonce, state.seq }, ":") } } })
        end
        finish(state, true)
        return
    end
    request(state)
end

function sync:IsExpectedPagedLeaderboardDelivery(kind, name, sender, channel)
    local delivery = self._pagedDelivery
    return kind == "LK" and delivery and delivery.sender == sender
        and delivery.channel == channel and delivery.key == key(name)
end

tryApply = function(state)
    local meta = state.meta
    if not meta or state.applying then return end
    for i = 1, meta.parts do if not state.parts[i] then return end end
    local blob = table.concat(state.parts)
    if #blob > 4064 or hash(blob) ~= meta.hash then
        -- A corrupt copy must not poison the slot and reject a correct retry.
        state.parts, state.bytes, state.partCount, state.meta = {}, 0, nil, nil
        return
    end
    local rows, pos, last = {}, 1, state.cursor == "-" and "" or state.cursor
    for i = 1, meta.rows do
        local prefix, stop = blob:match("^(%d+)():", pos)
        -- Lua's ^ anchor is relative to init for string.find/match in 5.1.
        local length = prefix and #prefix <= 3 and integer(prefix, 1, 250)
        if not length then return end
        pos = stop + 1
        local payload = blob:sub(pos, pos + length - 1)
        if #payload ~= length then return end
        pos = pos + length
        local name = payload:match("^([^:]+):")
        local identity = name and key(name)
        if not identity or identity <= last or hash(identity) % BUCKETS + 1 ~= state.bucket then return end
        rows[#rows + 1] = { key = identity, payload = payload }
        last = identity
    end
    if pos ~= #blob + 1 or (meta.cursor ~= "-" and (meta.rows ~= PAGE_ROWS or meta.cursor ~= last)) then return end
    state.applying = true
    local index = 1
    local function apply()
        if pull ~= state then return end
        if state.epoch ~= epoch() then finish(state, false); return end
        if paused() then C_Timer.After(2, apply); return end
        local sliceAt = debugprofilestop and debugprofilestop() or 0
        for _ = 1, 4 do
            local row = rows[index]
            if not row then
                state.applying = nil
                nextPage(state, meta.cursor)
                return
            end
            local net, previous = Overlord.BetaNetwork, nil
            if net then previous = net.context; net.context = state.context end
            sync._pagedDelivery = { sender = state.peer, channel = state.channel, key = row.key }
            local ok, accepted = true, false
            if not sync.SenderBurstShouldDrop or not sync:SenderBurstShouldDrop(state.peer, "LK") then
                ok, accepted = pcall(sync.OnReceiveLeaderboardKills, sync, row.payload, state.peer, state.channel)
            end
            sync._pagedDelivery = nil
            if net then net.context = previous end
            if not ok then stats.error = tostring(accepted); finish(state, false); return end
            -- Local blacklist/level policy can intentionally differ. Never
            -- bypass it or describe a received sweep as identical replicas.
            if accepted then stats.rows = stats.rows + 1 else stats.rejected = stats.rejected + 1 end
            index = index + 1
            if debugprofilestop and debugprofilestop() - sliceAt >= 1 then break end
        end
        C_Timer.After(0.001, apply)
    end
    C_Timer.After(0.001, apply)
end

local function respond(session, q)
    if serving ~= session or not session.profile or outbound then return end
    if q.seq == 1 and q.totalCount == session.profile.count and q.totalHash == session.profile.hash then
        -- Steady-state convergence costs one request and one reply, not 64 polls.
        enqueue({ epoch = session.epoch, peer = session.peer, packets = { { "HA",
            table.concat({ "5", "S", session.epoch, session.nonce, q.seq,
                q.totalCount, q.totalHash }, ":") } },
            done = function() if serving == session then serving = nil end end })
        return
    end
    local bucket = session.profile.buckets[q.bucket]
    local rows, cursor = {}, "-"
    if q.cursor == "-" and #bucket == q.count and bucket.hash == q.hash then
        -- An empty page certifies only this matching bucket.
    else
        local low, high = 1, #bucket + 1
        while low < high do
            local middle = math.floor((low + high) / 2)
            if bucket[middle].key <= q.cursor and q.cursor ~= "-" then low = middle + 1 else high = middle end
        end
        for i = low, math.min(#bucket, low + PAGE_ROWS - 1) do
            local row = bucket[i]
            rows[#rows + 1] = tostring(#row.payload) .. ":" .. row.payload
        end
        if low + PAGE_ROWS <= #bucket then cursor = bucket[low + PAGE_ROWS - 1].key end
    end
    local blob = table.concat(rows)
    local partCount = math.max(1, math.ceil(#blob / CHUNK))
    local base = table.concat({ "5", "P", session.epoch, session.nonce, q.seq, q.bucket,
        #rows, hash(blob), cursor, partCount }, ":")
    local packets = { { "HA", base } }
    for i = 1, partCount do
        packets[#packets + 1] = { "HB", table.concat({ "5", "D", session.epoch,
            session.nonce, q.seq, i, partCount, blob:sub((i - 1) * CHUNK + 1, i * CHUNK) }, ":") }
    end
    enqueue({ epoch = session.epoch, peer = session.peer, packets = packets,
        valid = function() return serving == session end,
        done = function() session.at = GetTime() end })
end

function sync:StartPagedLeaderboardCatchup(peer, callback)
    peer = self:NormalizeContributorFullName(peer)
    if pull or building or paused() or not C_Timer or not C_Timer.After or epoch() <= 0
        or not self:IsValidPlayerName(peer) or type(callback) ~= "function"
        or (unsupported[peer] or 0) > GetTime() then return false end
    serial = serial + 1
    local saved = checkpoints()[peer]
    local state = { peer = peer, callback = callback, epoch = epoch(), seq = 0, completed = 0,
        bucket = type(saved) == "table" and integer(saved.bucket, 1, BUCKETS) or 1,
        cursor = "-", nonce = tostring(GetServerTime()) .. "n"
            .. tostring(math.floor(GetTime() * 1000)) .. "n" .. tostring(serial) }
    pull = state
    stats.target, stats.result = peer, "preparing"
    if not prepare(function(profile)
        if pull ~= state then return end
        if not profile then finish(state, false); return end
        state.profile = profile
        stats.result = "receiving"
        request(state)
    end) then pull = nil; return false end
    return true
end

function sync:OnPagedLeaderboardMessage(kind, payload, sender, channel)
    sender = self:NormalizeContributorFullName(sender)
    if #payload > 250 or not allowed(sender, channel) then return end
    local version, op, epochStr, nonce, seqStr, a, b, c, d, e, f, g = strsplit(":", payload, 12)
    local wireEpoch, seq = integer(epochStr, 1, 9999999999), integer(seqStr, 1, 10000)
    if version ~= "5" or wireEpoch ~= epoch() or not seq or not nonce or #nonce > 32
        or not nonce:match("^[%w]+$") then return end
    if kind == "HR" and op == "F" then
        if serving and serving.peer == sender and serving.nonce == nonce
            and serving.seq == seq then serving = nil end
        return
    end
    if kind == "HR" and op == "Q" then
        local bucket, count, digest = integer(a, 1, BUCKETS), integer(c, 0, 5000), integer(d, 0, MOD - 1)
        local totalCount, totalHash = integer(e, 0, 5000), integer(f, 0, MOD - 1)
        if not bucket or not count or not digest or not validCursor(b) or g
            or ((e or f) and (seq ~= 1 or not totalCount or not totalHash)) then return end
        local session = serving
        if session and (session.epoch ~= wireEpoch or GetTime() - session.at > 300) then serving = nil; session = nil end
        if paused() or outbound then return end
        if (session and (session.peer ~= sender or session.nonce ~= nonce))
        or (not session and (seq ~= 1 or b ~= "-")) then
            -- A cursor is meaningful only inside the original frozen profile.
            -- Never continue it against a rebuilt snapshot after disconnection.
            enqueue({ epoch = wireEpoch, peer = sender, packets = { { "HA",
                table.concat({ "5", "R", wireEpoch, nonce, seq }, ":") } } })
            return
        end
        if not session then
            if building then return end
            session = { peer = sender, nonce = nonce, epoch = wireEpoch, at = GetTime(), seq = seq }
            serving = session
        elseif seq < session.seq or seq > session.seq + 1 then return end
        session.at, session.seq = GetTime(), seq
        local q = { bucket = bucket, cursor = b, count = count, hash = digest, seq = seq,
            totalCount = totalCount, totalHash = totalHash }
        if session.profile then respond(session, q)
        else
            prepare(function(profile)
                if serving ~= session then return end
                session.profile = profile
                if profile then respond(session, q) else serving = nil end
            end)
        end
        return
    end
    local state = pull
    if not state or sender ~= state.peer or nonce ~= state.nonce or seq ~= state.seq
        or wireEpoch ~= state.epoch or state.applying then return end
    if kind == "HA" and op == "R" then
        state.supported = true
        finish(state, false)
        return
    end
    if kind == "HA" and op == "S" then
        if seq ~= 1 or integer(a, 0, 5000) ~= state.profile.count
            or integer(b, 0, MOD - 1) ~= state.profile.hash or c then return end
        state.supported, state.bucket = true, 1
        finish(state, true)
        return
    end
    if kind == "HA" and op == "P" then
        local bucket, rows, digest, parts = integer(a, 1, BUCKETS), integer(b, 0, PAGE_ROWS),
            integer(c, 0, MOD - 1), integer(e, 1, MAX_PARTS)
        if bucket ~= state.bucket or not rows or not digest or not parts or not validCursor(d) or f
            or (state.partCount and state.partCount ~= parts) then return end
        state.meta = { rows = rows, hash = digest, cursor = d, parts = parts }
        state.partCount = parts
    elseif kind == "HB" and op == "D" then
        -- Parse the opaque chunk without splitting the LK payload's colons.
        local _, _, _, _, _, partStr, partsStr, chunk = strsplit(":", payload, 8)
        local part, parts = integer(partStr, 1, MAX_PARTS), integer(partsStr, 1, MAX_PARTS)
        if not part or not parts or part > parts or not chunk or #chunk > CHUNK
            or (state.partCount and state.partCount ~= parts) then return end
        if state.parts[part] and state.parts[part] ~= chunk then return end
        if not state.parts[part] then
            if state.bytes + #chunk > 4064 then return end
            state.parts[part], state.bytes = chunk, state.bytes + #chunk
        end
        state.partCount = parts
    else return end
    state.supported, state.channel = true, channel
    state.context = Overlord.BetaNetwork and Overlord.BetaNetwork.context or nil
    tryApply(state)
end

function sync:GetPagedLeaderboardDiagnostics()
    return string.format("Ladder v5: %s; pages=%d rows=%d filtered=%d retries=%d; bucket=%s/64; 300 B/s budget",
        stats.result or "idle", stats.pages, stats.rows, stats.rejected, stats.retries,
        pull and tostring(pull.bucket) or "-")
end
