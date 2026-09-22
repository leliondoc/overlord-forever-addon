-- Beta transport: bounded store-and-forward over group/channel and Battle.net.
-- The last hop is authenticated by WoW/BNet. Earlier authors are vouched for by
-- that peer, not cryptographically authenticated by Blizzard. Keep the original
-- author when dispatching so relays never manufacture additional witnesses.
local addon = Overlord
local sync = addon.Sync
local net = { peers = {}, stats = { sent = 0, received = 0, dropped = 0 } }
addon.BetaNetwork = net
local allowed = {}
for kind in ("NH SR K EK C ZS ZR ZA CB NR NC NA FA LK LR LC LO LOC OE TV VT VF FR DX VB MN MS WN WS GK GC GA G7 GH OP OC WB SH HR HB HC HA LD CR CA GR GY GI FC GE GP GX GD GM BQ BR PB PK MK PX PP PM"):gmatch("%S+") do
    allowed[kind] = true
end
local MAX_PACKET, MAX_PATH, TTL = 3600, 4, 120
local queue, head, pumping = {}, 1, false
local seen, recent, assemblies = {}, {}, {}
local seenOrder, recentOrder, assemblyOrder, peerOrder = {}, {}, {}, {}
local serial = 0
local session = tostring(time()) .. "-" .. tostring(math.random(1, 2147483646))
local function enabled() return addon.CommunityModeEnabled == false end
local function active() return enabled() and not addon.InstanceSuspended and not IsInInstance() end
local function region() return addon.RealmPools:GetOverlordPoolTag() end
local function canonical(name) return sync:CanonicalForeverName(name) end
local function same(a, b) return sync:ForeverIdentitiesMatch(a, b) end
local function remember(values, order, key, value, limit)
    if values[key] == nil then
        if #order >= limit then values[table.remove(order, 1)] = nil end
        order[#order + 1] = key
    end
    values[key] = value
end
local function encode(p)
    return table.concat({ p.region, p.id, tostring(p.at), p.target,
        table.concat(p.path, ","), p.kind, p.payload }, "|")
end
local function decode(wire)
    if type(wire) ~= "string" or #wire > MAX_PACKET then return nil end
    local pool, id, at, target, path, kind, payload = strsplit("|", wire, 7)
    at = tonumber(at)
    if pool ~= region() or not id or #id > 64 or not id:match("^[%w%-]+$")
        or not at or at ~= math.floor(at) or time() - at > TTL or at - time() > 30
        or not allowed[kind] or not payload or payload:find("[%c]")
        or (target ~= "*" and canonical(target) ~= target) then return nil end
    local nodes, unique = {}, {}
    for name in tostring(path):gmatch("[^,]+") do
        if canonical(name) ~= name or unique[name:lower()] then return nil end
        nodes[#nodes + 1] = name
        unique[name:lower()] = true
    end
    if #nodes < 1 or #nodes > MAX_PATH or table.concat(nodes, ",") ~= path then return nil end
    return { region = pool, id = id, at = at, target = target, path = nodes, kind = kind, payload = payload }
end
function net:IsPeer(name)
    local key = canonical(name)
    local row = key and self.peers[key:lower()]
    return row ~= nil and GetTime() - row.at <= 300
end
function net:GetPeers()
    local names = {}
    for _, row in pairs(self.peers) do
        if GetTime() - row.at <= 300 then names[#names + 1] = row.name end
    end
    table.sort(names)
    return names
end
function net:IsDispatching(sender)
    return self.context ~= nil and same(self.context.origin, sender)
end
function net:IsTargetedDispatch()
    return self.context ~= nil and self.context.targeted == true
end
function net:IsEcho(kind, payload)
    return self.context and self.context.kind == kind and self.context.payload == payload
end
local pump
local function schedule()
    if pumping then return end
    pumping = true
    C_Timer.After(0.1, pump)
end
-- One budget for all beta packets, including each BNet recipient and each
-- group/channel copy. Never use one independent budget per gateway.
local tokens, budgetAt = 500, GetTime()
local function spend(bytes)
    local now = GetTime()
    tokens = math.min(500, tokens + math.max(0, now - budgetAt) * 1000)
    budgetAt = now
    if bytes > tokens then return false end
    tokens = tokens - bytes
    return true
end
local function tasksFor(p, wire)
    local tasks, fragments = {}, {}
    local count = math.ceil(#wire / 170)
    for i = 1, count do
        fragments[i] = p.id .. ":" .. i .. ":" .. count .. ":" .. wire:sub((i - 1) * 170 + 1, i * 170)
    end
    local route = p.target ~= "*" and net.peers[p.target:lower()] or nil
    if route and GetTime() - route.at > 300 then route = nil end
    if route then
        for _, name in ipairs(p.path) do if same(name, route.via) then route = nil; break end end
    end
    local function add(transport, data, kind, target)
        tasks[#tasks + 1] = { transport = transport, data = data, kind = kind, target = target, bytes = #data + 64 }
    end
    local function bnet(id)
        if #wire <= 430 then add("BNET", wire, "BR", id)
        else for _, fragment in ipairs(fragments) do add("BNET", fragment, "BF", id) end end
    end
    if route and route.bnet then
        bnet(route.bnet)
    elseif route and (route.transport == "CHANNEL" or route.transport == "WHISPER") then
        for _, fragment in ipairs(fragments) do add("WHISPER", fragment, "BF", route.via) end
    else
        for _, fragment in ipairs(fragments) do
            if not p.skipGroup then add("GROUP", fragment, "BF") end
            if not p.skipChannel then add("CHANNEL", fragment, "BF") end
        end
        local friends = sync.GetBetaBNetTargets and sync:GetBetaBNetTargets() or {}
        local total = #friends
        local cursor = net.friendCursor or 0
        for i = 1, math.min(3, total) do bnet(friends[(cursor + i - 1) % total + 1]) end
        if total > 0 then net.friendCursor = (cursor + math.min(3, total)) % total end
        -- R1 fallback to a known gateway when there is no local broadcast path.
        if sync.FindBridgeForEnemyFaction and sync.GetChannelId and not sync:GetChannelId()
            and not IsInGroup() then
            local bridge, band = sync:FindBridgeForEnemyFaction()
            if bridge and band then
                local prefix = band .. ":" .. sync:GetPlayerFullName() .. ":BF:" .. p.id .. ":"
                local size = math.min(170, 255 - 3 - #prefix - 6)
                if size > 0 and math.ceil(#wire / size) <= 64 then
                    local n = math.ceil(#wire / size)
                    for i = 1, n do
                        local r1 = prefix .. i .. ":" .. n .. ":" .. wire:sub((i - 1) * size + 1, i * size)
                        add("WHISPER", r1, "R1", bridge)
                    end
                end
            end
        end
    end
    return tasks
end
local function emit(task)
    -- Missing optional local paths are not send failures; a throttled channel
    -- that is present must, however, retry the same fragment.
    if task.transport == "GROUP" and not IsInGroup() then return true end
    if task.transport == "CHANNEL" and not sync:GetChannelId() then return true end
    if not spend(task.bytes) then return false end
    local sent
    if task.transport == "BNET" then sent = sync:SendToBNet(task.target, task.kind, task.data)
    elseif task.transport == "WHISPER" then sent = sync:SendWhisper(task.kind, task.data, task.target)
    elseif task.transport == "GROUP" then sent = sync:SendToGroup(task.kind, task.data)
    else sent = sync:SendToChannel(task.kind, task.data, false) end
    if sent ~= true then
        -- A BNet recipient can log out after route selection. There is no
        -- throttling retry here; let catchup rediscover a path instead of
        -- blocking every other peer behind a dead friend for the full TTL.
        if task.transport == "BNET" then
            net.stats.dropped = net.stats.dropped + 1
            return true
        end
        return false
    end
    net.stats.sent = net.stats.sent + 1
    net.stats.bytes = (net.stats.bytes or 0) + task.bytes
    return true
end
function net:Queue(p, immediate)
    if #queue - head + 1 >= 128 then self.stats.dropped = self.stats.dropped + 1; return false end
    local wire = encode(p)
    if #wire > MAX_PACKET then return false end
    local item = { p = p, tasks = tasksFor(p, wire), index = 1 }
    -- A lease release may use the currently available budget synchronously before
    -- entering an instance, but never bypasses that budget.
    if immediate and p.kind == "ZR" then
        while item.tasks[item.index] and emit(item.tasks[item.index]) do item.index = item.index + 1 end
        if not item.tasks[item.index] then return true end
        table.insert(queue, head, item)
    else queue[#queue + 1] = item end
    schedule()
    return true
end
pump = function()
    pumping = false
    if not active() then
        if enabled() and #queue >= head then C_Timer.After(2, schedule) end
        return
    end
    local item = queue[head]
    if not item then queue, head = {}, 1; return end
    -- Drain the available shared byte budget, not just one fragment per tick.
    -- The old 10-fragment/s ceiling unnecessarily backed up full snapshots.
    for _ = 1, 16 do
        local task = item.tasks[item.index]
        if time() - item.p.at > TTL or not task then
            item.index = #item.tasks + 1
            break
        end
        if not emit(task) then break end
        item.index = item.index + 1
    end
    if item.index > #item.tasks then queue[head] = false; head = head + 1 end
    if head > #queue then queue, head = {}, 1 end
    if head > 128 then
        local remaining = {}
        for i = head, #queue do remaining[#remaining + 1] = queue[i] end
        queue, head = remaining, 1
    end
    if queue[head] then schedule() end
end
function net:Send(kind, payload, target, immediate)
    if not active() or not allowed[kind] or type(payload) ~= "string"
        or payload:find("[%c]") then return false end
    -- Handlers may rebroadcast received snapshots. The existing packet is already
    -- forwarded below; do not give that replay a fresh author or hop budget.
    if self:IsEcho(kind, payload) and not target then return false end
    local name = sync:GetPlayerFullName()
    if canonical(name) ~= name or name == "" then return false end
    target = target or "*"
    if target ~= "*" and canonical(target) ~= target then return false end
    local key = kind .. "|" .. target .. "|" .. payload
    local now = GetTime()
    if recent[key] and now - recent[key] < 2 then return true end
    serial = serial + 1
    local p = { region = region(), id = session .. "-" .. serial, at = time(),
        target = target, path = { name }, kind = kind, payload = payload }
    if not self:Queue(p, immediate) then return false end
    remember(recent, recentOrder, key, now, 512)
    remember(seen, seenOrder, name:lower() .. ":" .. p.id, now, 2048)
    return true
end
function net:Broadcast(kind, payload, extras)
    local sent = self:Send(kind, payload or "")
    -- Community producers bundle further fronts, victory bonuses and resource
    -- stocks with the first message. Preserve every payload on the beta route.
    for _, extra in ipairs(extras or {}) do
        if extra.type and extra.payload then
            if not self:Send(extra.type, extra.payload) then sent = false end
        end
    end
    return sent and 1 or 0
end
function net:Receive(wire, sender, transport, bnetID)
    if not active() then return false end
    local p = decode(wire)
    if not p or not sender or not same(p.path[#p.path], sender) then return false end
    local me = sync:GetPlayerFullName()
    for _, node in ipairs(p.path) do if same(node, me) then return false end end
    local origin = p.path[1]
    local key = origin:lower() .. ":" .. p.id
    if seen[key] then return false end
    remember(seen, seenOrder, key, GetTime(), 2048)
    local previousRoute = self.peers[origin:lower()]
    if not previousRoute or GetTime() - previousRoute.at > 60 or #p.path <= previousRoute.hops then
        remember(self.peers, peerOrder, origin:lower(), {
            name = origin, at = GetTime(), via = sender, transport = transport, bnet = bnetID, hops = #p.path,
        }, 128)
    end
    self.stats.received = self.stats.received + 1
    local addressed = p.target == "*" or same(p.target, me)
    if addressed and p.kind ~= "NH" then
        local previous = self.context
        self.context = { origin = origin, gateway = sender, hops = #p.path - 1,
            kind = p.kind, payload = p.payload, targeted = p.target ~= "*" }
        -- BETA is explicit: do not masquerade the relay as a direct WoW whisper.
        local ok, err = pcall(sync.OnAddonMessage, sync, "OverlordF",
            p.kind .. ":" .. p.payload, "BETA", origin)
        self.context = previous
        if not ok then self.stats.lastError = tostring(err) end
    elseif p.kind == "NH" then
        -- At most two full pulls per minute. No roster/club required for discovery.
        local now = GetTime()
        if not self.pullWindow or now - self.pullWindow >= 60 then self.pullWindow, self.pulls = now, 0 end
        self.requested = self.requested or {}
        local last = self.requested[origin:lower()] or -300
        if self.pulls < 2 and now - last >= 300 then
            self.pulls = self.pulls + 1
            -- Bound this cache by the same live peer population.
            self.requested = self.requested or {}
            if not self.requestOrder then self.requestOrder = {} end
            if sync:SendSyncRequest({ fullResponse = true, betaTarget = origin }) then
                remember(self.requested, self.requestOrder, origin:lower(), now, 128)
            end
        end
    end
    if #p.path < MAX_PATH and (p.target == "*" or not addressed) then
        p.path[#p.path + 1] = me
        p.skipChannel = transport == "CHANNEL"
        p.skipGroup = transport == "RAID" or transport == "PARTY"
        self:Queue(p)
    end
    return true
end
function net:ReceiveFragment(payload, sender, transport, bnetID)
    if not active() or type(payload) ~= "string" or #payload > 252 then return false end
    local id, part, count, chunk = strsplit(":", payload, 4)
    part, count = tonumber(part), tonumber(count)
    local name = canonical(sender)
    if not name or not id or #id > 64 or not id:match("^[%w%-]+$") or not chunk
        or #chunk > 170 or not part or not count or count < 1 or count > 64
        or part < 1 or part > count or part ~= math.floor(part) or count ~= math.floor(count) then return false end
    local key = name:lower() .. ":" .. id
    local a = assemblies[key]
    if not a or GetTime() - a.at > 15 then
        a = { at = GetTime(), count = count, got = 0, chunks = {} }
        remember(assemblies, assemblyOrder, key, a, 64)
    end
    if a.count ~= count then return false end
    if a.chunks[part] and a.chunks[part] ~= chunk then return false end
    if not a.chunks[part] then a.chunks[part] = chunk; a.got = a.got + 1 end
    if a.got ~= count then return true end
    local wire = table.concat(a.chunks)
    local p = decode(wire)
    if not p or p.id ~= id then return false end
    return self:Receive(wire, name, transport, bnetID)
end
function net:Start()
    if not enabled() or self.started then return end
    self.started = true
    local function hello()
        if active() then net:Broadcast("NH", addon.Version) end
    end
    C_Timer.After(3, hello)
    self.ticker = C_Timer.NewTicker(45, hello)
end
