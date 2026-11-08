-- Mining alerts (MN) and mine stocks (MS) only for mines this addon knows: an invented
-- id went straight into a red chat line on every listener (escape codes included),
-- left a cooldown key never pruned, and stocks kept every invented id (saved, walked
-- every second, reloaded at login).
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local sync = Overlord.Sync
local prints = {}
Overlord.PrintNotification = function(_, msg) prints[#prints + 1] = msg end
Overlord.PlayerFaction = "Alliance"
Overlord.L.ENEMY_MINING_HORDE = "The Horde is mining %s"
Overlord.L.ENEMY_MINING_ALLIANCE = "The Alliance is mining %s"
local known = { realmine = { id = "realmine", name = "Real Mine" } }
Overlord.Zones.GetMine = function(_, id) return known[id] end
C_Map = C_Map or {}
strsplit = strsplit or function(sep, value, limit)
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
-- Ressources.lua builds a small frame at load: any widget method is a no-op here.
local widgetMeta = {}
widgetMeta.__index = function() return function() return setmetatable({}, widgetMeta) end end
CreateFrame = function() return setmetatable({}, widgetMeta) end
UIParent = UIParent or setmetatable({}, widgetMeta)
assert(loadfile("Ressources.lua"))()
local res = Overlord.Ressources

-- (1) Invented ids: nothing printed, nothing remembered.
sync:OnReceiveMining("|cFFFF0000x|r|nFake:H", "Evil Doer")
for i = 1, 200 do sync:OnReceiveMining("junk" .. i .. ":H", "Evil Doer") end
assert(#prints == 0, "an invented mine id printed a chat line: " .. tostring(prints[1]))
assert(next(sync:GetPriv().mineAlertLast) == nil, "invented mine ids were remembered")
-- (2) A real mine: one line, then the usual 60 s cooldown.
sync:OnReceiveMining("realmine:H", "Horde Miner")
assert(#prints == 1 and prints[1]:find("Real Mine", 1, true), "a real mine alert was not printed")
sync:OnReceiveMining("realmine:H", "Horde Miner")
assert(#prints == 1, "the cooldown no longer holds")
-- (3) Stocks: an invented id is not kept; a real one still drains.
res:ApplyRemoteMineStock("junk", 0)
assert(res:GetMineStock("junk") == res:GetMineStockMax(), "an invented mine stock was kept")
res:ApplyRemoteMineStock("realmine", 0)
assert(res:GetMineStock("realmine") == 0, "a real mine stock no longer drains")
-- (4) A save polluted before 1.8.1 drops the invented ids at login.
OverlordDB.mineStocks = { junk = 3, realmine = 40 }
OverlordDB.mineStockTimers = { junk = 5, realmine = 7 }
res:RestoreResources()
res:SaveResources()
assert(OverlordDB.mineStockTimers.junk == nil and OverlordDB.mineStocks.junk == nil,
    "the login restore kept an invented mine id in the saved stocks or timers")
assert(res:GetMineStock("junk") == res:GetMineStockMax() and res:GetMineStock("realmine") == 40,
    "the login restore kept an invented mine id or lost a real one")
-- (5) 2.2.2: the alert names who mines and the layer the miner sent; escape codes and a
-- malformed layer are dropped; a 2.2.1 payload (no layer) still reads.
Overlord.L.SHARD_ALERT_NAME_TAG = ", layer #%s"
local mineAlerts = sync:GetPriv().mineAlertLast
prints = {}
mineAlerts.realmine = nil
sync:OnReceiveMining("realmine:H:4321", "Horde Miner-Realm")
assert(prints[1] and prints[1]:find("Real Mine (Horde Miner, layer #4321)", 1, true),
    "the alert lacks the miner or its layer: " .. tostring(prints[1]))
mineAlerts.realmine = nil
sync:OnReceiveMining("realmine:H:12|cffff0000", "Bad|cffName")
assert(prints[2] and not prints[2]:find("|cff", 1, true) and prints[2]:find("(Badcffname)", 1, true) == nil
    and prints[2]:find("Real Mine (Bad", 1, true) and not prints[2]:find("layer #12", 1, true),
    "escape codes or a malformed layer reached the alert: " .. tostring(prints[2]))
mineAlerts.realmine = nil
sync:OnReceiveMining("realmine:H", "Old Miner")
assert(prints[3] and prints[3]:find("Real Mine (Old Miner", 1, true), "a 2.2.1 alert no longer reads")
-- A Battle.net leg that could not be resolved never shows as the miner's name.
mineAlerts.realmine = nil
sync:OnReceiveMining("realmine:H", "BNet-5")
assert(prints[4] and prints[4]:find("Real Mine", 1, true) and not prints[4]:find("BNet", 1, true),
    "a Battle.net placeholder reached the alert: " .. tostring(prints[4]))
mineAlerts.realmine = nil
sync:OnReceiveMining("realmine:H", "Bridge-7")
assert(prints[5] and not prints[5]:find("Bridge", 1, true), "a bridge placeholder reached the alert: " .. tostring(prints[5]))

-- (6) 2.2.2: no PvP flag, no mining: neither alert nor platinum, a hint instead; flagged, both.
local timerFn
C_Timer = C_Timer or {}
local realNewTimer = C_Timer.NewTimer
C_Timer.NewTimer = function(_, fn) timerFn = fn; return { Cancel = function() end } end
C_Map.GetBestMapForUnit = function() return 1429 end
Overlord.Zones.IsResourceMapContext = function() return true end
Overlord.Zones.GetCurrentPlayerMine = function() return known.realmine end
Overlord.ZoneControl = Overlord.ZoneControl or {}
Overlord.ZoneControl.IsPlayerInNonMiningStateForSync = function() return false end
local flagged = false
Overlord.ZoneControl.PlayerLacksPvpFlag = function() return not flagged end
UnitIsDead = UnitIsDead or function() return false end
UnitIsGhost = UnitIsGhost or function() return false end
for _, k in ipairs({ "MINE_ENTERED", "MINE_LEFT", "MINE_DEPLETED" }) do Overlord.L[k] = Overlord.L[k] or (k .. " %s") end
Overlord.L.GOLD_FULL = Overlord.L.GOLD_FULL or "GOLD_FULL"
Overlord.L.GOLD_FCT_GAIN = Overlord.L.GOLD_FCT_GAIN or "+%d"
local mined = 0
sync.BroadcastMining = function() mined = mined + 1 end
sync.MaybeBroadcastMineStock = function() end
IsInInstance = IsInInstance or function() return false end
local mineClock = 5000
GetTime = function() return mineClock end
res:RestoreResources()
local before = res:GetGold()
res:Initialize()
prints = {}
for _ = 1, 10 do assert(timerFn, "no resource tick"); mineClock = mineClock + 1; local fn = timerFn; timerFn = nil; fn() end
assert(mined == 0 and res:GetGold() == before, "an unflagged player mined: " .. mined .. " alerts")
local hints = 0
for _, line in ipairs(prints) do if line:find("/pvp", 1, true) then hints = hints + 1 end end
assert(hints == 1, "the PvP hint is missing or repeated: " .. hints)
flagged = true
for _ = 1, 10 do mineClock = mineClock + 1; local fn = timerFn; timerFn = nil; fn() end
assert(mined >= 1 and res:GetGold() > before, "a flagged player no longer mines")
C_Timer.NewTimer = realNewTimer

-- (7) 2.2.2: a map request opens the peer's reply window only once it really left (not
-- while suspended, not when too long to send).
do
    local priv = sync:GetPriv()
    local relay, sendChecked, inInstance = Overlord.Relay, sync.SendAddonChecked, IsInInstance
    Overlord.Relay = nil
    IsInInstance = function() return false end
    local sent = 0
    sync.SendAddonChecked = function() sent = sent + 1; return true end
    priv.mapAskedAt = {}
    Overlord.InstanceSuspended = true
    sync:SendWhisper("SR", "x", "Map Asker")
    Overlord.InstanceSuspended = false
    assert(next(priv.mapAskedAt) == nil and sent == 0, "a request held back by an instance opened the window")
    sync:SendWhisper("SR", string.rep("x", 300), "Map Asker")
    assert(next(priv.mapAskedAt) == nil and sent == 0, "a request too long to leave opened the window")
    sync:SendWhisper("SR", "x", "Map Asker")
    assert(sent == 1 and next(priv.mapAskedAt) ~= nil, "a request that left did not open the window")
    Overlord.Relay, sync.SendAddonChecked, IsInInstance = relay, sendChecked, inInstance
end
print("Mine ids: invented ids neither printed, remembered nor stored; real mines unchanged; miner, layer, PvP flag OK")
