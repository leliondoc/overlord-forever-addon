-- A direct Battle.net author's K reaches the local guild raid alert, while a
-- relayed origin remains excluded from the owner-authenticated kill path.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("GuildKillAlert.lua"))()

local sync = Overlord.Sync
local alert = Overlord.GuildKillAlert
local printed = {}
Overlord.PrintNotification = function(_, message) printed[#printed + 1] = message end
Overlord.PlayerFaction = "Alliance"
alert:_ResetState()
alert:SetEnabled(true)

local function payload(name, total)
    return sync:BuildKillBroadcastPayload(name, "", total, "WARRIOR",
        "Horde", 1789527600, "Empire", "enus", 1789527600, 1789527600, 2)
end

-- DispatchBNetMessage resolves a real Forever friend's character name before
-- the same owner check used by the group/channel receiver.
local originalGameAccountInfo = C_BattleNet.GetGameAccountInfoByID
local directAuthors = { "Bridge Tester", "Raider Two", "Raider Three",
    "Raider Four", "Raider Five" }
C_BattleNet.GetGameAccountInfoByID = function(id)
    if id >= 124 and id <= 127 then
        return { gameAccountID = id, characterName = directAuthors[id - 122],
            clientProgram = "WoW", wowProjectID = 18, factionName = "Horde",
            isInCurrentRegion = true, isOnline = true }
    end
    return originalGameAccountInfo(id)
end
local observed = {}
local originalOnLiveKill = alert.OnLiveKill
alert.OnLiveKill = function(self, name, ...)
    local args = { ... }
    observed[#observed + 1] = name .. "/" .. tostring(args[2]) .. "/" .. tostring(args[3])
    return originalOnLiveKill(self, name, ...)
end
for index, name in ipairs(directAuthors) do
    local id = 122 + index
    if index == 1 then
        -- The integration fixture already accepted this author's total of 4.
        sync:DispatchBNetMessage("K", payload(name, 8), "BNet-" .. id, id)
        sync:DispatchBNetMessage("K", payload(name, 11), "BNet-" .. id, id)
    else
        sync:DispatchBNetMessage("K", payload(name, 1), "BNet-" .. id, id)
        sync:DispatchBNetMessage("K", payload(name, 4), "BNet-" .. id, id)
    end
end
alert.OnLiveKill = originalOnLiveKill
C_BattleNet.GetGameAccountInfoByID = originalGameAccountInfo
assert(#observed >= 5, "Direct Battle.net K did not reach the alert detector: " .. #observed)
local alerts = 0
for _, message in ipairs(printed) do
    if message:find("Empire", 1, true) then alerts = alerts + 1 end
end
assert(alerts == 1, "Direct Battle.net K did not reach the guild alert: "
    .. table.concat(observed, ",") .. " :: " .. table.concat(printed, ","))

alert:_ResetState()
printed = {}
local relay = "eu|audit-relay-1|" .. time() .. "|*|Bridge Tester,Remote Tester|K|"
    .. payload("Bridge Tester", 13)
sync:OnBNetMessage("R2:Forever_eu_H:BR:" .. relay, 123)
assert(#printed == 0, "Relayed K was treated as owner-authenticated")

-- The diagnostic simulation must not consume slots from the bounded live-K
-- baseline table after each run.
local function upvalue(fn, wanted)
    for index = 1, 64 do
        local key, value = debug.getupvalue(fn, index)
        if key == nil then break end
        if key == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end
local consume = upvalue(alert.OnLiveKill, "ConsumeKillDelta")
local function baselineCount() return upvalue(consume, "playerCount") end
local before = baselineCount()
for _ = 1, 120 do alert:Simulate() end
assert(baselineCount() == before,
    "Repeated alert simulation leaked player baseline slots")

alert:ResetDefaults()
print("Forever alert transport: direct BNet K alerts; relayed K cannot spoof alerts")
