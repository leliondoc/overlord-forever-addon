-- Multi-hop route survival under a saturated relay (audit 2026-09-28):
-- Origin -> R1 -> R2 -> R3 -> R4. R2/R3 are flooded with ordinary GW traffic.
-- An unbounded bulk anti-starvation rule inverted priorities there, relayed NH
-- stopped being admitted and R4 lost its route (and ~lp6 capability) for good.
local REPO = ""
local now, pending, seq = 100, {}, 0
local function after(delay, fn) seq = seq + 1; pending[#pending+1] = {at = now+delay, run=fn, seq=seq} end
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields+1] = value:sub(start, at-1)
        start = at + #sep
    end
    fields[#fields+1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Timer = { After = after, NewTicker = function() return { Cancel = function() end } end }
local nodes = {}
local function makeNode(nm)
    local a = { Version = "1.1.5", BetaNetworkEnabled = true, PlayerFaction = "Alliance", name = nm,
        RealmPools = { GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, p) return p == "global" and p or "" end }, Sync = {} }
    local s = a.Sync
    function s:CanonicalForeverName(n) return type(n)=="string" and n:match("^%a+ %a+$") and n or nil end
    function s:ForeverIdentitiesMatch(x,y) return type(x)=="string" and type(y)=="string" and x:lower()==y:lower() end
    function s:GetPlayerFullName() return nm end
    function s:GetChannelId() return nil end
    function s:SendToGroup() return false end
    function s:SendToChannel() return true end
    function s:GetBetaBNetTargets() return a.friends or {} end
    function s:GetBetaBNetTargetInfo(friend) return friend.PlayerFaction, friend.name end
    function s:SendToBNet(friend, kind, wire)
        if kind == "BR" then friend.BetaNetwork:Receive(wire, nm, "BNET", a)
        else friend.BetaNetwork:ReceiveFragment(wire, nm, "BNET", a) end
        return true
    end
    function s:SendWhisper(kind, fragment, target)
        for _, other in ipairs(nodes) do
            if other.name == target then other.BetaNetwork:ReceiveFragment(fragment, nm, "WHISPER"); return true end
        end
        return true
    end
    function s:SendSyncRequest() return false end
    function s:OnAddonMessage() end
    Overlord = a
    assert(loadfile(REPO .. "SyncBetaNetwork.lua"))()
    nodes[#nodes+1] = a
    return a
end
local origin = makeNode("Origin Tester")
local r1 = makeNode("Relay One")
local r2 = makeNode("Relay Two")
local r3 = makeNode("Relay Three")
local r4 = makeNode("Relay Four")
origin.friends = { r1 }
r1.friends = { origin, r2 }
r2.friends = { r1, r3 }
r3.friends = { r2, r4 }
r4.friends = { r3 }

-- Heavy background bulk load (ordinary GW alerts) at R2 and R3 to model busy
-- intermediate relays: enough to keep their global 128-queue near/at capacity.
local function floodBulk(node, label)
    local i = 0
    local function tick()
        if now > 100 + 900 then return end
        i = i + 1
        node.BetaNetwork:Send("GW", ("1:Empire:A:20:5:#%d:143:%d"):format(i % 5000, math.floor(time())))
        after(0.05, tick)
    end
    tick()
end
floodBulk(r2, "R2")
floodBulk(r3, "R3")

-- Origin heartbeats every 120 s, as net:Start() would.
local function heartbeat()
    if now > 100 + 900 then return end
    origin.BetaNetwork:Broadcast("NH", origin.Version)
    after(120, heartbeat)
end
after(3, heartbeat)

local established, samples, lost = false, 0, 0
local function sample()
    if now > 100 + 900 then return end
    local row = r4.BetaNetwork.peers["origin tester"]
    local cap = nil
    if r4.BetaNetwork.GetPeerPagedProtocol then cap = r4.BetaNetwork:GetPeerPagedProtocol("Origin Tester") end
    local haveRoute = row ~= nil and GetTime() - row.at <= 300
    if row then established = true end
    if established then
        samples = samples + 1
        if not haveRoute then lost = lost + 1 end
    end
    after(15, sample)
end
after(5, sample)

local steps = 0
while #pending > 0 do
    steps = steps + 1
    assert(steps < 400000, "sim did not settle")
    table.sort(pending, function(a,b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
    local ev = table.remove(pending, 1)
    now = ev.at
    ev.run()
end
assert(established and samples > 40, "Route to the origin was never established at R4")
assert(lost == 0, ("R4 lost its route to the origin in %d of %d samples"):format(lost, samples))
assert(r4.BetaNetwork:GetPeerPagedProtocol("Origin Tester") == 6, "R4 lost the origin v6 capability")
for _, relay in ipairs({ r2, r3 }) do
    local nh = relay.BetaNetwork.kindStats.NH or {}
    assert((nh.queued or 0) >= 7, relay.name .. " stopped admitting relayed presence: " .. tostring(nh.queued))
end
print(("Beta multi-hop presence: route kept at 4 hops through saturated relays (%d samples)"):format(samples))
