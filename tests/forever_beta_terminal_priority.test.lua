-- Capture completion must not wait behind a full queue of timer updates.
local now, pending = 100, {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function IsInInstance() return false end
function IsInGroup() return false end
C_Timer = { After = function(delay, fn) pending[#pending + 1] = {at=now+delay, fn=fn} end }
local sent = {}
Overlord = { Version="1.1.3", PlayerFaction="Alliance", RealmPools={
    GetOverlordPoolTag=function() return "global" end,
}, Sync={} }
local sync = Overlord.Sync
function sync:CanonicalForeverName(name) return name end
function sync:ForeverIdentitiesMatch(a,b) return a == b end
function sync:GetPlayerFullName() return "Capper Tester" end
function sync:GetChannelId() return nil end
function sync:GetBetaBNetTargets() return {1} end
function sync:GetBetaBNetTargetInfo() return "Horde", "Bridge Tester" end
function sync:SendToBNet(_, kind, data)
    sent[#sent + 1] = {at=now, kind=kind, data=data}
    return true
end
assert(loadfile("SyncBetaNetwork.lua"))()
local net = Overlord.BetaNetwork
for i=1,84 do
    assert(net:Send("ZS", "zone" .. i .. ":in_progress:0:477:A:" .. time()))
end
local start = now
assert(net:Send("C", "capital:Capper Tester:A:" .. time()),
    "A full progress queue rejected the capture completion")
assert(net:Send("ZS", "capital:captured:0:0:A:" .. time()),
    "A full progress queue rejected the final zone state")
assert(net:Send("ZR", "capital:release"), "A full progress queue rejected a release")
for _, kind in ipairs({"OC", "TV", "FR"}) do
    assert(net:Send(kind, "terminal-" .. kind), "A full progress queue rejected " .. kind)
end
assert(net:Send("ZS", "capital:locked:0:0::" .. time()), "A full queue rejected a locked terminal")
local steps = 0
while #pending > 0 do
    table.sort(pending, function(a,b) return a.at < b.at end)
    local timer=table.remove(pending,1)
    now=timer.at; timer.fn()
    steps=steps+1; assert(steps < 10000, "Queue did not settle")
end
local capture, final, release, otherTerminals = nil, nil, nil, 0
for _, row in ipairs(sent) do
    if row.data:find("|C|capital:",1,true) then capture=row.at end
    if row.data:find("|ZS|capital:captured:",1,true) then final=row.at end
    if row.data:find("|ZR|capital:release",1,true) then release=row.at end
    if row.data:find("|terminal-",1,true) or row.data:find("|ZS|capital:locked:",1,true) then
        otherTerminals = otherTerminals + 1
        assert(row.at - start < 5, "Structure/victory terminal queued behind progress")
    end
end
assert(capture and final and release, "A terminal event was lost")
assert(capture <= final and final <= release, "Terminal event order changed")
assert(release - start < 2, "Capture completion queued behind old progress updates")
assert(otherTerminals == 4, "A structure/victory/reset terminal was lost")
assert(#sent == 84, "Ordinary queue bound/displacement changed")
-- Never displace route/barrier handshakes as if they were periodic progress.
assert(loadfile("SyncBetaNetwork.lua"))()
net = Overlord.BetaNetwork
for i=1,84 do assert(net:Send("CB", "barrier-commit-" .. i)) end
assert(not net:Send("C", "capital:no-room"), "Capture displaced an irreplaceable barrier commit")
print("Beta terminals: full progress queue admits and delivers C/final ZS/ZR within 2 seconds")
