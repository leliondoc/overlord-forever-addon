-- 2.0.3: a map answer to the requester alone leaves the map pages out when the
-- requester's own last presence shows the very map we would serve (content digest and
-- date sum, "~z"). The blind periodic catch-up asked one neighbour a whole map every
-- 2.5-3 min, most of the time an identical one. Sieges, keeps and outposts and the
-- victory journal still go: they are not in the digest. Final college (same night): only
-- for a targeted request of the same relay session as that presence (a /reload starts a
-- new session; broadcast requests are the login and instance-exit asks whose gate only
-- a whole map closes), presence fresh by its own clock too, our stamp read fresh.

-- (1) The relay keeps what each neighbour's own presence says of its map.
do
    local now = 100
    GetTime = function() return now end
    time = function() return 1790016000 + math.floor(now) end
    IsInInstance = function() return false end
    IsInGroup = function() return false end
    strsplit = strsplit or function(sep, value, limit)
        local fields, start = {}, 1
        while not limit or #fields < limit - 1 do
            local at = value:find(sep, start, true)
            if not at then break end
            fields[#fields + 1] = value:sub(start, at - 1)
            start = at + #sep
        end
        fields[#fields + 1] = value:sub(start)
        return (unpack or table.unpack)(fields)
    end
    C_Timer = C_Timer or { After = function() end, NewTicker = function() return {} end }
    local zones = {
        { id = "z_one", owner = "Alliance", capturedTime = 1790000100, status = "captured" },
        { id = "z_two", owner = "Horde", capturedTime = 1790000200, status = "captured" },
        { id = "z_three", status = "available" },
    }
    local a = { Version = "2.0.3", RelayEnabled = true, PlayerFaction = "Alliance",
        Fronts = { Registry = { one = { zones = zones } } },
        RealmPools = { GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, p) return p == "global" and p or "" end }, Sync = {} }
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x, y) return type(x) == "string" and type(y) == "string" and x:lower() == y:lower() end
    function s:GetPlayerFullName() return "Local Tester" end
    function s:GetChannelId() return 1 end
    function s:SendToGroup() return false end
    function s:SendToChannel() return true end
    function s:GetBetaBNetTargets() return {} end
    function s:SendWhisper() return true end
    function s:OnAddonMessage() end
    local pullsAsked = 0
    function s:SendSyncRequest() pullsAsked = pullsAsked + 1; return true end
    local saved = Overlord
    Overlord = a
    assert(loadfile("SyncRelay.lua"))()
    local net = a.Relay
    local queued
    local realQueue = net.Queue
    net.Queue = function(_, packet) queued = packet; return true end
    net:Send("NH", "2.0.3")
    net.Queue = realQueue
    local ours = queued and queued.payload:match("~z(%w+)~")
    assert(ours and #ours > 6, "our presence has no content stamp: " .. tostring(queued and queued.payload))
    -- Until our login map has come, our presence vouches for nothing (empty stamp).
    a.IsCaptureSyncPending = function() return true end
    s.GetOutpostMapStamps = function() return 5 end -- a held keep or outpost
    queued = nil
    net.Queue = function(_, packet) queued = packet; return true end
    net:Send("NH", "2.0.3")
    net.Queue = realQueue
    a.IsCaptureSyncPending, s.GetOutpostMapStamps = nil, nil
    assert(queued and queued.payload:find("~o0~z0000000~", 1, true),
        "a client waiting for its login map showed its map or its sites: " .. tostring(queued and queued.payload))
    -- The login map comes (zones confirmed, gate lifted) a second later: the next presence
    -- shows the real map at once, not the quarantine view cached a moment ago.
    for _, z in ipairs(zones) do z._loginSyncUnconfirmed = true end
    a.IsCaptureSyncPending = function() return true end
    net.Queue = function(_, packet) queued = packet; return true end
    now = now + 6 -- past the stamp cache: this presence computes the quarantine view
    net:Send("NH", "2.0.3") -- caches the quarantine view (every zone waiting)
    for _, z in ipairs(zones) do z._loginSyncUnconfirmed = nil end
    a.IsCaptureSyncPending = nil
    now = now + 3 -- inside the 5 s stamp cache, past the 2 s duplicate window
    queued = nil
    net:Send("NH", "2.0.3")
    net.Queue = realQueue
    assert(queued and queued.payload:find("~z" .. ours .. "~", 1, true),
        "the first presence after the login map still showed the quarantine view: " .. tostring(queued and queued.payload))
    local serial = 0
    local function presence(who, z, path, session, at)
        serial = serial + 1
        return net:Receive(table.concat({ "global", (session or "sessA") .. "-" .. serial, at or time(), "*",
            path or who, "NH", "2.0.3~t0~y" .. net.LocalMapLayout() .. "~m1~o0~z" .. z .. "~l9~ld~lr~lp6" }, "|"), who, "CHANNEL")
    end
    presence("Same Tester", ours)
    assert(net:PeerHoldsOurMap("Same Tester", "sessA"), "a neighbour showing our map is not seen as holding it")
    -- Another session (the same player after a /reload), or none (a raw whisper): no.
    assert(not net:PeerHoldsOurMap("Same Tester", "sessB"), "a request of another session was taken as the presence's map")
    assert(not net:PeerHoldsOurMap("Same Tester"), "a request without a session was taken as the presence's map")
    presence("Other Tester", "000001" .. ours:sub(7))
    assert(not net:PeerHoldsOurMap("Other Tester", "sessA"), "another digest was taken as our map")
    presence("Sum Tester", ours:sub(1, 6) .. "1")
    assert(not net:PeerHoldsOurMap("Sum Tester", "sessA"), "another date sum was taken as our map")
    assert(not net:PeerHoldsOurMap("Never Heard", "sessA"), "a neighbour never heard holds our map")
    -- Only its own presence counts, not one passed on by somebody else.
    presence("Gate Tester", ours, "Far Tester,Gate Tester")
    assert(not net:PeerHoldsOurMap("Far Tester", "sessA"), "a relayed presence was taken as the neighbour's map")
    -- A presence that waited in a queue: heard 60 s ago by our clock, said 160 s ago.
    presence("Late Tester", ours, nil, nil, time() - 100)
    assert(net:PeerHoldsOurMap("Late Tester", "sessA"), "fixture: a presence said 100 s ago was not kept")
    now = now + 60
    assert(not net:PeerHoldsOurMap("Late Tester", "sessA"), "a presence said 160 s ago still counts")
    -- A sender whose clock runs ahead: fresh by its own date, old by when we heard it.
    presence("Clock Tester", ours, nil, nil, time() + 20)
    assert(net:PeerHoldsOurMap("Clock Tester", "sessA"), "fixture: a presence dated 20 s ahead was not kept")
    now = now + 151
    assert(not net:PeerHoldsOurMap("Clock Tester", "sessA"), "a presence heard 151 s ago still counts")
    -- A request coming through the relay carries its session to the answer.
    local seenSession
    s.OnAddonMessage = function() seenSession = net.context and net.context.session end
    serial = serial + 1
    net:Receive(table.concat({ "global", "sessQ-" .. serial, time(), "Local Tester", "Asker Tester", "SR",
        "A:2.0.3:0:::T" }, "|"), "Asker Tester", "WHISPER")
    s.OnAddonMessage = function() end
    assert(seenSession == "sessQ", "a relayed request does not carry its session: " .. tostring(seenSession))
    -- Old news: past 150 s it no longer counts.
    now = now + 151
    assert(not net:PeerHoldsOurMap("Same Tester", "sessA"), "a presence older than 150 s still counts")
    presence("Same Tester", ours)
    assert(net:PeerHoldsOurMap("Same Tester", "sessA"), "a fresh presence does not count again")
    -- Our map changes (a capture): the neighbour no longer holds it, at once (no cache).
    zones[3].owner, zones[3].capturedTime, zones[3].status = "Alliance", 1790000300, "captured"
    assert(not net:PeerHoldsOurMap("Same Tester", "sessA"), "our map changed but the neighbour still holds it")
    -- An empty stamp proves nothing: every zone waiting for a login map on both sides.
    for _, z in ipairs(zones) do z._loginSyncUnconfirmed = true end
    now = now + 6
    presence("Empty Tester", "0000000")
    assert(not net:PeerHoldsOurMap("Empty Tester", "sessA"), "two empty stamps were taken as the same map")
    for _, z in ipairs(zones) do z._loginSyncUnconfirmed = nil end
    -- A neighbour still waiting for its login map (empty stamp) is not pulled: it holds
    -- nothing we lack, and its answer would carry no map.
    now = now + 400
    local before = pullsAsked
    local function diffRows() local c = 0; for _ in pairs(net.mapDiffs or {}) do c = c + 1 end; return c end
    local rowsBefore = diffRows()
    presence("Waiting Tester", "0000000")
    assert(pullsAsked == before, "a neighbour showing an empty stamp was pulled for its map")
    assert(diffRows() == rowsBefore, "an empty stamp was kept as a map difference to pull later")
    Overlord = saved
    print("Equal map skip: the relay keeps each neighbour's own map stamp and session, 150 s, any change breaks it")
end

-- (2) The answer: pages left out only for the requester alone, everything else kept.
assert(loadfile("tests/forever_fortress_outpost.test.lua"))()
local sync = Overlord.Sync
-- The victory journal rows of an answer (SyncVictoryBonus) must still go without the map.
if not sync.AppendVictoryBonusToSrQueue then assert(loadfile("SyncVictoryBonus.lua"))() end
assert(sync.AppendVictoryBonusToSrQueue, "fixture: the victory journal is not loaded")
Overlord.Relay = Overlord.Relay or {}
local relay = Overlord.Relay
local holders = { ["Same Tester"] = "sessA" }
local realHolds, realDispatching, realTargeted = relay.PeerHoldsOurMap, relay.IsDispatching, relay.IsTargetedDispatch
relay.PeerHoldsOurMap = function(_, name, session) return session ~= nil and holders[name] == session end
relay.IsDispatching = function(_, who) return relay.context ~= nil and relay.context.origin == who end
relay.IsTargetedDispatch = function() return relay.context ~= nil and relay.context.targeted == true end
local built, appended, journal = 0, 0, 0
local realBuild, realAppend, realJournal = sync.BuildZoneAllSnapshotPages, sync.AppendOutpostToSrQueue, sync.AppendVictoryBonusToSrQueue
sync.BuildZoneAllSnapshotPages = function(self, ...) built = built + 1; return realBuild(self, ...) end
sync.AppendOutpostToSrQueue = function(self, ...) appended = appended + 1; return realAppend(self, ...) end
if realJournal then
    sync.AppendVictoryBonusToSrQueue = function(self, ...) journal = journal + 1; return realJournal(self, ...) end
end
local realAfter, realTicker, realTime, realRandom = C_Timer.After, C_Timer.NewTicker, GetTime, math.random
C_Timer.After = function(_, fn) fn() end
C_Timer.NewTicker = function() return { Cancel = function() end } end
local clock = realTime()
GetTime = function() return clock end
math.random = function() return 0 end
Overlord.InActiveFront = true
local function ask(sender, channel, replyTo)
    built, appended, journal = 0, 0, 0
    clock = clock + 600
    sync:OnSyncRequest(sender, sync:GetSRPayload("T"), channel, replyTo)
    return built, appended
end
-- A request that came through the relay, first hand: targeted or broadcast, with its session.
local function askRelayed(sender, targeted, session)
    relay.context = { origin = sender, gateway = sender, hops = 0, targeted = targeted,
        session = session, transport = "WHISPER" }
    local ok, err = pcall(ask, sender, "BETA")
    relay.context = nil
    assert(ok, err)
    return built, appended
end
local b, a = askRelayed("Same Tester", true, "sessA")
assert(b == 0 and a == 1, "a targeted request from a holder of our map got map pages, or lost its keep rows: " .. b .. "/" .. a)
assert(journal == 1, "the victory journal rows were left out with the map pages")
b = askRelayed("Same Tester", true, "sessB")
assert(b == 1, "a request of another session (after a /reload) got no map pages")
b = askRelayed("Same Tester", false, "sessA")
assert(b == 1, "a broadcast request (login, instance exit) answered to the holder got no map pages")
b, a = ask("Same Tester", "WHISPER")
assert(b == 1 and a == 1, "a raw whisper (no session) got no map pages: " .. b .. "/" .. a)
b = ask("Same Tester", "BNET")
assert(b == 1, "a raw Battle.net request (no session) got no map pages")
b, a = askRelayed("Other Tester", true, "sessA")
assert(b == 1 and a == 1, "a requester with another map got no map pages: " .. b .. "/" .. a)
for _, heard in ipairs({ "CHANNEL", "RAID", "PARTY" }) do
    b = ask("Same Tester", heard)
    assert(b == 1, "map pages left out of an answer heard by others (" .. heard .. ")")
end
sync.BuildZoneAllSnapshotPages, sync.AppendOutpostToSrQueue, sync.AppendVictoryBonusToSrQueue = realBuild, realAppend, realJournal
relay.PeerHoldsOurMap, relay.IsDispatching, relay.IsTargetedDispatch = realHolds, realDispatching, realTargeted
C_Timer.After, C_Timer.NewTicker, GetTime, math.random = realAfter, realTicker, realTime, realRandom
print("Equal map skip: pages left out only for a targeted request of the same session, keep and journal rows kept")
