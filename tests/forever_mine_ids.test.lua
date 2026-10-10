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
print("Mine ids: invented ids neither printed, remembered nor stored; real mines unchanged")
