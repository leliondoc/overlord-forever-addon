-- Deliver production DX/VB across three real BetaNetwork forwarding hops into
-- the production handlers. Duplicate envelopes must not inflate either ledger.
assert(loadfile("tests/forever_event_replay_audit.test.lua"))()

local receiver = Overlord
local receiverNet = receiver.BetaNetwork
local receiverSync = receiver.Sync
local startTime = time()
local now, pending = 100, {}
function GetTime() return now end
function time() return startTime + math.floor(now - 100) end
function GetServerTime() return time() end
C_Timer.After = function(delay, callback)
    pending[#pending + 1] = { at = now + delay, run = callback }
end

local nodes = {}
local function node(name, faction)
    local addon = {
        Version = "1.0.0", BetaNetworkEnabled = true,
        PlayerFaction = faction, name = name, Sync = {},
        RealmPools = {
            GetOverlordPoolTag = function() return "global" end,
            NormalizeRegionPool = function(_, pool)
                return pool == "global" and pool or ""
            end,
        },
    }
    local sync = addon.Sync
    function sync:CanonicalForeverName(value)
        return type(value) == "string" and value:match("^%a+ %a+$") and value or nil
    end
    function sync:ForeverIdentitiesMatch(a, b)
        return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
    end
    function sync:GetPlayerFullName() return name end
    function sync:GetChannelId() return nil end
    function sync:SendToGroup() return false end
    function sync:SendToChannel() return false end
    function sync:GetBetaBNetTargets() return { 1 } end
    function sync:GetBetaBNetTargetInfo()
        return addon.nextFaction, addon.nextName
    end
    function sync:SendToBNet(_, kind, data)
        if addon.nextIsProduction then
            -- The final hop enters through the real Battle.net dispatcher,
            -- which resolves the authenticated gateway before BetaNetwork.
            receiverSync:OnBNetMessage("R2:Forever_eu_A:" .. kind .. ":" .. data, 123)
            return true
        end
        local nextNet = assert(addon.nextNet)
        if kind == "BR" then
            return nextNet:Receive(data, name, "BNET", 1)
        elseif kind == "BF" then
            return nextNet:ReceiveFragment(data, name, "BNET", 1)
        end
        return false
    end
    function sync:OnAddonMessage() end
    Overlord = addon
    assert(loadfile("SyncBetaNetwork.lua"))()
    nodes[#nodes + 1] = addon
    return addon
end

local origin = node("Origin Tester", "Alliance")
local relay = node("Relay Tester", "Horde")
local bridge = node("Bridge Tester", "Alliance")
Overlord = receiver
origin.nextNet, origin.nextName, origin.nextFaction = relay.BetaNetwork, relay.name, relay.PlayerFaction
relay.nextNet, relay.nextName, relay.nextFaction = bridge.BetaNetwork, bridge.name, bridge.PlayerFaction
bridge.nextNet, bridge.nextName, bridge.nextFaction = receiverNet,
    receiverSync:GetPlayerFullName(), receiver.PlayerFaction
bridge.nextIsProduction = true

local frontId = "redridge"
receiver.Fronts.Registry[frontId] = { zones = { one = {}, two = {} } }
local campaign = OverlordDB.lastResetTimestamp
local dx = assert(receiverSync:BuildDominationPayload(frontId, { Alliance = 730, Horde = 270 }))
local victoryTs = time() - 100
OverlordDB.frontVictories = OverlordDB.frontVictories or {}
OverlordDB.frontVictories[frontId] = { faction = "Alliance", timestamp = victoryTs }
local vb = assert(receiverSync:BuildVictoryBonusPayload({ {
    frontId = frontId, faction = "Alliance", victoryTs = victoryTs,
    rangeMaxTs = victoryTs, bonusSeconds = 20, totalAtApply = 1000,
    campaignEpoch = campaign,
} }, campaign, "global"))
local beforeBonus = select(1, receiver:GetDominationVictoryBonusTotals())

assert(origin.BetaNetwork:Broadcast("DX", dx, { { type = "VB", payload = vb } }) == 1)
local function drain()
    local ticks = 0
    while #pending > 0 do
        ticks = ticks + 1
        assert(ticks < 10000, "Three-hop event relay did not settle")
        table.sort(pending, function(a, b) return a.at < b.at end)
        local nextTimer = table.remove(pending, 1)
        now = nextTimer.at
        nextTimer.run()
    end
end
drain()
assert(not receiverNet.stats.lastError, receiverNet.stats.lastError)
local bucket = assert(OverlordDB.frontDominationTime[frontId], "Three-hop DX was lost")
assert(bucket.Alliance == 730 and bucket.Horde == 270,
    "Three-hop DX changed the absolute domination snapshot")
local firstBonus = select(1, receiver:GetDominationVictoryBonusTotals())
assert(firstBonus == beforeBonus + 20, "Three-hop VB was lost")
assert(receiverNet.peers["origin tester"] and receiverNet.peers["origin tester"].hops == 3,
    "Receiver did not learn the three-hop origin route")

-- New packet ids with the same payload exercise handler idempotence after
-- relay dedup; an identical envelope alone would be stopped in BetaNetwork.
local firstReceived = receiverNet.stats.received
now = now + 3 -- exceed the sender's two-second identical-broadcast coalescing
assert(origin.BetaNetwork:Broadcast("DX", dx, { { type = "VB", payload = vb } }) == 1)
drain()
assert(receiverNet.stats.received == firstReceived + 2,
    "Duplicate DX/VB payloads did not traverse the relay as new envelopes")
assert(bucket.Alliance == 730 and bucket.Horde == 270,
    "Repeated three-hop DX inflated domination time")
assert(select(1, receiver:GetDominationVictoryBonusTotals()) == firstBonus,
    "Repeated three-hop VB applied the bonus twice")
print("Forever event multihop: production DX/VB survive three relay hops and duplicate replay")
