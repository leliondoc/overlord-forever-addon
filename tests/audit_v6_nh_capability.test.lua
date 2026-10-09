-- Protocol hints come only from first-hand NH; peers older than 1.7.0 (v5, v6) are
-- not asked, v7 peers get the complete paged sweep. Production parsers and
-- timers run here; only WoW transports and the empty attested roster are faked.
local now, serial, pending = 100, 0, {}
local function later(delay, callback)
    serial = serial + 1
    pending[#pending + 1] = { at = now + delay, id = serial, callback = callback }
end
local function advance(seconds)
    local stop, steps = now + seconds, 0
    while #pending > 0 do
        table.sort(pending, function(a, b)
            return a.at < b.at or (a.at == b.at and a.id < b.id)
        end)
        if pending[1].at > stop then break end
        local item = table.remove(pending, 1)
        now = item.at
        item.callback()
        steps = steps + 1
        assert(steps < 100000, "Unbounded capability handshake")
    end
    now = stop
end
local e = setmetatable({}, { __index = _G })
e._G, e.OverlordDB = e, {}
e.GetTime = function() return now end
e.GetServerTime = function() return 1790017000 + math.floor(now) end
e.time = e.GetServerTime
e.IsInInstance = function() return false end
e.IsInGroup = function() return false end
e.InCombatLockdown = function() return false end
e.C_Timer = { After = later, NewTicker = function() return { Cancel = function() end } end }
e.strsplit = function(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1], start = value:sub(start, at - 1), at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
e.Overlord = {
    Version = "1.1.3", RelayEnabled = true,
    RealmPools = {
        GetOverlordPoolTag = function() return "EU" end,
        NormalizeRegionPool = function(_, value) return value end,
    },
    GetCurrentCampaignStartTs = function() return 1790016000 end,
    Sync = {}, Leaderboard = {},
}
local s, lb = e.Overlord.Sync, e.Overlord.Leaderboard
s.CanonicalForeverName = function(_, value) return value end
s.ForeverIdentitiesMatch = function(_, a, b)
    return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
end
s.GetPlayerFullName = function() return "Analyst Tester" end
s.NormalizeContributorFullName = function(_, value) return value end
s.IsValidPlayerName = function(_, value)
    return type(value) == "string" and value:match("^%a+ %a+$") ~= nil
end
s.GetCaptureContributorDedupKey = function(_, value) return value:lower() end
s.SenderIsInOurGroup = function() return true end
s.SendSyncRequest = function() return true end
s.OnAddonMessage = function() end
s.GetAttestedLeaderboardSnapshot = function()
    return { kills = {}, captureCount = {}, playerInfo = {} }
end
lb.SnapshotCurrentCampaignBeforeReset = function(_, callback)
    callback(true)
    return true
end
lb.SortNetworkRows = function(_, rows, less) table.sort(rows, less) end
e.loadfile = function(path) return setfenv(assert(loadfile(path)), e) end
e.loadfile("SyncLeaderboardPages.lua")()
e.loadfile("SyncRelay.lua")()
local net = e.Overlord.Relay

-- Both startup and community scan call Broadcast("NH", addon.Version).
local queued, normalQueue = nil, net.Queue
net.Queue = function(_, packet) queued = packet; return true end
net:Start()
advance(3.1)
assert(queued and queued.kind == "NH" and queued.payload == "1.1.3~ld~lr~lp6",
    "Startup hello did not advertise lp6")
advance(2.1) -- distinct community scan, outside NH duplicate suppression
queued = nil
assert(net:Broadcast("NH", e.Overlord.Version) == 1)
assert(queued and queued.payload == "1.1.3~ld~lr~lp6",
    "Plain-version NH from the community scan lacked lp6")
net.Queue = normalQueue

local packetSerial = 0
local function receive(origin, kind, payload, originAt)
    packetSerial = packetSerial + 1
    -- First-hand presence on the channel: since 1.2.4 the ranking is only asked
    -- from direct neighbours (and presence is never relayed).
    local wire = table.concat({ "EU", "audit-" .. packetSerial,
        tostring(originAt or e.time()), "*", origin, kind, payload }, "|")
    assert(net:Receive(wire, origin, "CHANNEL"))
end
receive("Old Tester", "NH", "1.1.3")
receive("New Tester", "NH", "1.1.3~lp6")
assert(net:IsPeer("Old Tester") and net:GetPeerPagedProtocol("Old Tester") == 5)
assert(net:IsPeer("New Tester") and net:GetPeerPagedProtocol("New Tester") == 6)
receive("New Tester", "NH", "1.1.3", e.time() - 30)
assert(net:GetPeerPagedProtocol("New Tester") == 6,
    "Delayed older NH downgraded a fresh lp6 announcement")
-- 1.7.0: "~lr" (race in ranking rows) sits before the suffix that 1.6.3 reads.
assert(("1.1.3~lr~lp6"):match("~lp(%d+)$") == "6", "1.6.3 clients would no longer see lp6")
receive("Raced Tester", "NH", "1.1.3~lr~lp6")
assert(net:GetPeerPagedProtocol("Raced Tester") == 7, "~lr~lp6 was not read as v7")

-- 512 first-hand capabilities are kept (1.7.5): with 128, most direct neighbours of a
-- busy channel looked "unknown" and an old client cost a silent probe.
for i = 1, 200 do
    receive("Crowd" .. string.char(97 + math.floor(i / 26) % 26) .. string.char(97 + i % 26) .. " Tester",
        "NH", "1.1.3~lr~lp6")
end
assert(net:GetPeerPagedProtocol("Raced Tester") == 7, "a crowd of neighbours evicted an announced capability")

local sent = {}
s.SendWhisper = function(_, kind, payload, target)
    if kind == "HR" and payload:match("^[567]:Q:") then
        local fields = { e.strsplit(":", payload) }
        sent[#sent + 1] = { version = fields[1], target = target,
            nonce = fields[4], seq = fields[5], stream = fields[10] }
        local response = table.concat({ fields[1], "S", fields[3], fields[4],
            fields[5], fields[10], "0", "0" }, ":")
        later(0.01, function()
            s:OnPagedLeaderboardMessage("HA", response, target, "WHISPER")
        end)
    end
    return true
end

-- v7 only (1.7.5): a peer whose fresh presence announces v5 or v6 (a client older
-- than 1.7.0, still open to forged rows) is not asked at all.
assert(not s:StartCompletePagedLeaderboardCatchup("Old Tester", function()
    error("an old peer was asked")
end), "An old beta peer was asked for a ranking sweep")
advance(15)
assert(#sent == 0, "An old beta peer received a ranking request")
assert(s:GetPagedLeaderboardDiagnostics():find("beta v5; not asked (v7 only)", 1, true),
    "Diagnostics omit the v7-only choice")
assert(not s:StartCompletePagedLeaderboardCatchup("New Tester", function()
    error("a 1.6 peer was asked")
end), "A peer announcing only lp6 was asked for a ranking sweep")
advance(15)
assert(#sent == 0, "A peer announcing only lp6 received a ranking request")
assert(s:GetPagedLeaderboardDiagnostics():find("beta v6; not asked (v7 only)", 1, true),
    "Diagnostics omit the v6 refusal")

sent = {}
local newResult, newSupported
assert(s:StartCompletePagedLeaderboardCatchup("Raced Tester", function(ok, full)
    newResult, newSupported = ok, full
end))
advance(15)
assert(newResult == true and newSupported == true,
    "A v7 peer did not complete the LK/LC/LR sweep")
assert(#sent == 3 and sent[1].version == "7" and sent[1].stream == "LK"
    and sent[2].stream == "LC" and sent[3].stream == "LR",
    "Advertised ~lr~lp6 did not select all three typed v7 streams")

-- 1.7.5: only the peer's own presence states its capability. A relay that writes a
-- presence "Raced Tester,Gateway Tester" without the suffix used to make the honest
-- neighbour look old, so it was never asked and the relay stayed the only source.
local forged = table.concat({ "EU", "audit-forged-nh", tostring(e.time() + 25), "*",
    "Raced Tester,Gateway Tester", "NH", "1.0.0" }, "|")
net:Receive(forged, "Gateway Tester", "CHANNEL")
assert(net:GetPeerPagedProtocol("Raced Tester") == 7,
    "A relayed presence downgraded a neighbour's announced capability")

-- A new generic message may refresh the route, but cannot refresh NH's cap.
advance(301)
receive("Raced Tester", "GY", "test")
assert(net:IsPeer("Raced Tester") and net:GetPeerPagedProtocol("Raced Tester") == nil,
    "Non-NH traffic extended a stale capability")
assert(s:IsExpectedPagedLeaderboardDelivery("LK", "Victim Tester",
    "Raced Tester", "BETA") == nil,
    "NH capability opened unsolicited row-delivery authority")
-- A known peer whose capability is not known (yet or any more) is probed in v7: an
-- old client stays silent and ends the round unsupported.
sent = {}
local probeResult, probeSupported
assert(s:StartCompletePagedLeaderboardCatchup("Raced Tester", function(ok, full)
    probeResult, probeSupported = ok, full
end))
advance(15)
assert(sent[1] and sent[1].version == "7",
    "A peer with unknown capability was not probed in v7")
assert(probeResult == true and probeSupported == true,
    "The v7 probe of a capable peer did not complete the sweep")
assert(s:GetPagedLeaderboardDiagnostics():find("capability unknown, v7 probe", 1, true),
    "Diagnostics omit the v7 probe of an unknown-capability peer")
-- A peer whose route became relayed (no longer a direct neighbour) ends the
-- pull at once, without sending, instead of retrying until the 15 min watchdog.
advance(301)
local wire = table.concat({ "EU", "audit-far", tostring(e.time()), "*",
    "Far Tester,Gateway Tester", "GY", "far" }, "|")
assert(net:Receive(wire, "Gateway Tester", "CHANNEL"))
assert(net:IsPeer("Far Tester") and not net:IsDirectPeer("Far Tester"))
sent = {}
local farResult
s:StartCompletePagedLeaderboardCatchup("Far Tester", function(ok) farResult = ok end)
advance(5)
assert(#sent == 0, "A ranking request went toward a peer behind relays")
assert(farResult == false, "A pull toward a peer behind relays did not end promptly")
print("NH capability: v5/v6 peers not asked, typed v7, relayed presence ignored, unknown-capability v7 probe, capability TTL and relayed-peer early end OK")
