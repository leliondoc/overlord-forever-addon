-- Protocol hints come only from NH; old beta peers get LK v5 promptly while
-- peers advertising lp6 get the complete paged sweep. Production parsers and
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
    Version = "1.1.3", BetaNetworkEnabled = true,
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
e.loadfile("SyncBetaNetwork.lua")()
local net = e.Overlord.BetaNetwork

-- Both startup and community scan call Broadcast("NH", addon.Version).
local queued, normalQueue = nil, net.Queue
net.Queue = function(_, packet) queued = packet; return true end
net:Start()
advance(3.1)
assert(queued and queued.kind == "NH" and queued.payload == "1.1.3~lp6",
    "Startup hello did not advertise lp6")
advance(2.1) -- distinct community scan, outside NH duplicate suppression
queued = nil
assert(net:Broadcast("NH", e.Overlord.Version) == 1)
assert(queued and queued.payload == "1.1.3~lp6",
    "Plain-version NH from the community scan lacked lp6")
net.Queue = normalQueue

local packetSerial = 0
local function receive(origin, kind, payload, originAt)
    packetSerial = packetSerial + 1
    -- A four-node path exercises the real old/new NH decoder while avoiding
    -- unrelated forwarding work in this focused test.
    local path = origin .. ",First Tester,Second Tester,Gateway Tester"
    local wire = table.concat({ "EU", "audit-" .. packetSerial,
        tostring(originAt or e.time()), "*", path, kind, payload }, "|")
    assert(net:Receive(wire, "Gateway Tester", "CHANNEL"))
end
receive("Old Tester", "NH", "1.1.3")
receive("New Tester", "NH", "1.1.3~lp6")
assert(net:IsPeer("Old Tester") and net:GetPeerPagedProtocol("Old Tester") == 5)
assert(net:IsPeer("New Tester") and net:GetPeerPagedProtocol("New Tester") == 6)
receive("New Tester", "NH", "1.1.3", e.time() - 30)
assert(net:GetPeerPagedProtocol("New Tester") == 6,
    "Delayed older NH downgraded a fresh lp6 announcement")

local sent = {}
s.SendWhisper = function(_, kind, payload, target)
    if kind == "HR" and payload:match("^[56]:Q:") then
        local fields = { e.strsplit(":", payload) }
        sent[#sent + 1] = { version = fields[1], target = target,
            nonce = fields[4], seq = fields[5], stream = fields[10] }
        local response
        if fields[1] == "6" then
            response = table.concat({ "6", "S", fields[3], fields[4],
                fields[5], fields[10], "0", "0" }, ":")
        else
            response = table.concat({ "5", "S", fields[3], fields[4],
                fields[5], "0", "0" }, ":")
        end
        later(0.01, function()
            s:OnPagedLeaderboardMessage("HA", response, target, "WHISPER")
        end)
    end
    return true
end

-- v6 only (1.2.4): a peer whose fresh presence lacks lp6 is not asked at all.
assert(not s:StartCompletePagedLeaderboardCatchup("Old Tester", function()
    error("an old peer was asked")
end), "An old beta peer was asked for a ranking sweep")
advance(15)
assert(#sent == 0, "An old beta peer received a ranking request")
assert(s:GetPagedLeaderboardDiagnostics():find("beta v5; not asked (v6 only)", 1, true),
    "Diagnostics omit the v6-only choice")

sent = {}
local newResult, newSupported
assert(s:StartCompletePagedLeaderboardCatchup("New Tester", function(ok, full)
    newResult, newSupported = ok, full
end))
advance(15)
assert(newResult == true and newSupported == true,
    "New beta peer did not complete the v6 LK/LC/LR sweep")
assert(#sent == 3 and sent[1].version == "6" and sent[1].stream == "LK"
    and sent[2].stream == "LC" and sent[3].stream == "LR",
    "Advertised lp6 did not select all three typed streams")

-- A new generic message may refresh the route, but cannot refresh NH's cap.
advance(301)
receive("New Tester", "GY", "test")
assert(net:IsPeer("New Tester") and net:GetPeerPagedProtocol("New Tester") == nil,
    "Non-NH traffic extended a stale lp6 capability")
assert(s:IsExpectedPagedLeaderboardDelivery("LK", "Victim Tester",
    "New Tester", "BETA") == nil,
    "NH capability opened unsolicited row-delivery authority")
-- A known peer whose capability is not known (yet or any more) is probed with v6
-- first instead of being served the partial v5 sweep straight away.
sent = {}
local probeResult, probeSupported
assert(s:StartCompletePagedLeaderboardCatchup("New Tester", function(ok, full)
    probeResult, probeSupported = ok, full
end))
advance(15)
assert(sent[1] and sent[1].version == "6",
    "A peer with unknown capability was not probed with v6 first")
assert(probeResult == true and probeSupported == true,
    "The v6 probe of a capable peer did not complete the sweep")
assert(s:GetPagedLeaderboardDiagnostics():find("capability unknown, v6 probe", 1, true),
    "Diagnostics omit the v6 probe of an unknown-capability peer")
print("NH lp6 negotiation, old peers not asked, typed v6, unknown-capability v6 probe and capability TTL OK")
