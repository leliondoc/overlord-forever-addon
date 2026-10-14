-- 2.0.2: a capture the losing faction dates after a victory cannot disprove that victory.
-- 2026-10-13, Elwynn: the Alliance won at 21:05:04; Horde players who had not heard it
-- took two points 54 s and 3 min later. A client that had not yet accepted the victory
-- (its map lacked one capture when the announcement came) then never could: the proof
-- asks for every point of the front to be the winner's, and those two were not any more.
-- Such a client had no truce, kept taking the loser's captures, and the two factions
-- played half an hour on two maps. Real Sync.lua, Zones.lua, Fronts.lua.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "Captured by enemy"
Overlord.L.TOTAL_VICTORY_MSG = "%s won a front"
Overlord.L.VICTORY_FACTION_ALLIANCE, Overlord.L.VICTORY_FACTION_HORDE = "Alliance", "Horde"
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
local sync, zones = Overlord.Sync, Overlord.Zones
local clock = Overlord:GetCurrentCampaignStartTs() + 200000
time = function() return clock end
GetServerTime = function() return clock end
Overlord.InstanceSuspended = false
Overlord.SaveState = function() end
Overlord.MarkDirty = function() end
Overlord.PrintNotification = function() end
Overlord.UI = Overlord.UI or {}
Overlord.UI.ShowVictoryScreen = function() end
Overlord.UI.RequestRefresh = Overlord.UI.RequestRefresh or function() end
Overlord.GetLatestDominationVictoryForFront = function() return nil end
C_Timer.After = function() end -- the timed retries are played by hand below

local function fresh(faction)
    Overlord.PlayerFaction = faction
    OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
    OverlordDB.lastVictoryTimestamp, OverlordDB.lastVictoryFaction, OverlordDB.lastVictoryFrontId = nil, nil, nil
    Overlord.Fronts:Activate("elwynn")
    zones:ApplyFactionConfig(faction)
    if sync.ResetVictoryFlagForFront then sync:ResetVictoryFlagForFront("elwynn") end
    for _, front in pairs(Overlord.Fronts.Registry) do
        for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil end
    end
    if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived(true) end
end
local elwynn = Overlord.Fronts:GetFront("elwynn")
local function zone(id) return (Overlord.Fronts:GetZone(id, "elwynn")) end
local function set(id, owner, at)
    local z = zone(id)
    z.owner, z.status, z.capturedTime, z.updatedAt = owner, "captured", at, at
    z.previousOwner, z.holdTimeElapsed = nil, 0
end
local function allExcept(owner, at, skip)
    for _, z in ipairs(elwynn.zones) do
        if not (skip and skip[z.id]) then set(z.id, owner, at) end
    end
end
local function truce() return OverlordDB.frontVictories.elwynn end

-- The two ways a waiting announcement is tried again: the map check of a client standing
-- on the front (every map change), and the timed retry of any client.
local TV
local function again(way)
    if way == "map" then
        Overlord.InActiveFront = true
        sync:CheckTotalVictoryFromSync()
        Overlord.InActiveFront = false
    else
        sync:OnReceiveTotalVictory(TV, "Capturer Tester", "CHANNEL", true)
    end
end
local late, missing = "elwynn_stone_cairn", "elwynn_tower_of_azora"
local function announced(side, lateAt, missingOwner, capitalOwner)
    fresh(side)
    local V = clock
    TV = "Alliance:" .. V .. ":0:0:elwynn"
    -- The Alliance holds the front except the Horde capital; this client's map lacks one
    -- of its captures (still Horde here).
    allExcept("Alliance", V - 3000, { [elwynn.hordeCapitalId] = true })
    set(missing, "Horde", V - 4000)
    -- The capital falls, the capturer announces the victory: no proof yet here.
    set(elwynn.hordeCapitalId, capitalOwner or "Alliance", V)
    sync:OnReceiveTotalVictory(TV, "Capturer Tester", "CHANNEL")
    assert(not truce(), side .. ": a victory was believed with a point still Horde from before it")
    -- A Horde player who has not heard the victory finishes a capture later.
    clock = V + 60
    if lateAt then set(late, "Horde", V + lateAt) end
    -- The capturer's map then brings the point this client lacked, dated at the victory.
    if missingOwner ~= "Horde" then set(missing, "Alliance", V) end
    return V
end
for _, side in ipairs({ "Alliance", "Horde" }) do
    -- The hearer is of either faction: the winner's own side (his client that evening) and
    -- the loser's side (the Horde players who went on capturing) are the same case.
    for _, way in ipairs({ "map", "timer" }) do
        local label = side .. ", " .. way .. ": "
        -- Control: nothing late, the map completes, the victory is believed.
        local V = announced(side)
        again(way)
        assert(truce() and truce().timestamp == V, label .. "fixture: a victory with its whole front was not believed")
        -- 54 s after the victory (Elwynn): believed, and the point goes back to the winner.
        V = announced(side, 54)
        again(way)
        assert(truce() and truce().faction == "Alliance" and truce().timestamp == V,
            label .. "a capture the loser dated after the victory kept this client out of the truce")
        assert(zone(late).owner == "Alliance" and zone(late).status ~= "in_progress",
            label .. "the capture made after the victory was kept on the map: " .. tostring(zone(late).owner))
        -- What still refuses a victory: a point the loser holds from BEFORE it (the map
        -- does not show a whole front) ...
        announced(side, 54, "Horde")
        again(way)
        assert(not truce(), label .. "a victory was believed with a point the loser held from before it")
        -- ... a capital that is not the winner's ...
        announced(side, nil, nil, "Horde")
        again(way)
        assert(not truce(), label .. "a victory was believed without the capital")
        -- ... a loser's capture of the very second of the victory (only strictly later
        -- ones are set aside) ...
        announced(side, 0)
        again(way)
        assert(not truce(), label .. "a loser's capture of the very second of the victory was set aside")
        -- ... and one dated after the truce that follows the victory (fifteen minutes).
        announced(side, 901)
        again(way)
        assert(not truce(), label .. "a loser's capture dated after the truce was set aside")
        -- Once that truce is over, an announcement replayed gets the plain proof.
        V = announced(side, 54)
        clock = V + 901
        again(way)
        assert(not truce(), label .. "a late capture was set aside for a victory whose truce is over")
        -- A front the loser retook entirely after the capital fell is not a victory.
        V = announced(side, 54)
        for _, z in ipairs(elwynn.zones) do
            if z.id ~= elwynn.hordeCapitalId then set(z.id, "Horde", V + 30) end
        end
        again(way)
        assert(not truce(), label .. "a front the loser retook entirely was believed a victory")
        clock = clock + 100000
    end
end
-- The catch-up of a victory (VF, VT, the header of a map request) records it without
-- repainting the front: its proof stays the plain one. Believed with a whole front,
-- not with a point the loser took afterwards (the announcement's own retries do that).
for _, lateAt in ipairs({ false, 54 }) do
    fresh("Horde")
    local V = clock
    allExcept("Alliance", V - 3000)
    set(elwynn.hordeCapitalId, "Alliance", V)
    if lateAt then set(late, "Horde", V + lateAt) end
    clock = V + 60
    sync:OnReceiveVictoryFaction(V .. ":A:elwynn")
    if lateAt then
        assert(not truce(), "the catch-up of a victory set a late capture aside without repainting the front")
    else
        assert(truce() and truce().timestamp == V, "fixture: the catch-up of a victory with its whole front was not believed")
    end
    clock = clock + 100000
end
-- Without an announced moment the count is the old one: a kept capital and points its
-- faction retook later are not "a whole front".
fresh("Alliance")
allExcept("Alliance", clock - 3000)
set(late, "Horde", clock - 2000)
assert(zones:CountZonesNotOwnedByOnFront("elwynn", "Alliance") == 1
    and not zones:LocalStateSupportsVictoryTruce("elwynn", "Alliance"),
    "a point of the other faction is not counted any more when no victory is being proven")
-- 2.0.2 victory news: a client that accepts a victory learnt first-hand from a friend of
-- the other faction (the TV row of the map answer it asked for) says it once on its
-- faction's channel, twenty seconds later, so its channel mates do not each have to ask
-- for a map to enter the truce. Not for a victory heard on the channel or relayed.
do
    local timers, said = {}, {}
    C_Timer.After = function(delay, run) timers[#timers + 1] = { delay = delay, run = run } end
    local function fire()
        local due = timers
        timers = {}
        for _, t in ipairs(due) do
            if t.delay >= 15 and t.delay <= 35 and t.delay ~= 15 and t.delay ~= 30 then t.run() else timers[#timers + 1] = t end
        end
    end
    local realChannel, realRelay, realFaction = sync.SendToChannel, Overlord.Relay, sync.GetBetaPeerFaction
    sync.SendToChannel = function(_, kind, payload, critical)
        said[#said + 1] = kind .. ":" .. payload .. (critical and ":critical" or "")
        return true
    end
    local targeted = true
    Overlord.Relay = setmetatable({ IsTargetedDispatch = function() return targeted end }, { __index = realRelay or {} })
    sync.GetBetaPeerFaction = function(_, name) return name == "Alliance Friend" and "Alliance" or "Horde" end
    local realUnauth = sync.IsUnauthenticatedRelayOrigin
    sync.IsUnauthenticatedRelayOrigin = function() return false end
    -- The same answer taught us captures we are telling our faction (map news under way).
    local realUnderWay, teaching = sync.MapNewsUnderWay, true
    sync.MapNewsUnderWay = function() return teaching end
    local function won(sender, channel, lateAt)
        fresh("Horde")
        timers, said = {}, {}
        local V = clock
        allExcept("Alliance", V - 3000)
        set(elwynn.hordeCapitalId, "Alliance", V)
        if lateAt then set(late, "Horde", V + lateAt) end
        clock = V + 60
        TV = "Alliance:" .. V .. ":3:4:elwynn"
        sync:OnReceiveTotalVictory(TV, sender, channel)
        return V
    end
    -- From the friend's answer: believed (late capture set aside), then said once.
    local V = won("Alliance Friend", "BNET", 54)
    assert(truce() and truce().timestamp == V, "fixture: the victory of the friend's answer was not believed")
    assert(#said == 0, "the victory was said before the map news could leave")
    fire()
    assert(#said == 1 and said[1] == "TV:Alliance:" .. V .. ":3:4:elwynn:critical",
        "a victory learnt from a friend of the other faction was not said once to our faction: " .. table.concat(said, " | "))
    sync:OnReceiveTotalVictory(TV, "Alliance Friend", "BNET")
    sync:SayVictoryNews("elwynn", "Alliance", V, "3", "4")
    fire()
    assert(#said == 1, "the same victory was said twice")
    -- The kill totals passed on are plain numbers, whatever the friend wrote.
    fresh("Horde")
    timers, said = {}, {}
    V = clock
    allExcept("Alliance", V - 3000)
    set(elwynn.hordeCapitalId, "Alliance", V)
    clock = V + 60
    sync:OnReceiveTotalVictory("Alliance:" .. V .. ":x9:-4:elwynn", "Alliance Friend", "BNET")
    fire()
    assert(#said == 1 and said[1] == "TV:Alliance:" .. V .. ":0:0:elwynn:critical",
        "the totals of a victory news are not plain numbers: " .. table.concat(said, " | "))
    -- The answer taught us nothing to tell (our faction was up to date): believed, not said.
    teaching = false
    V = won("Alliance Friend", "BNET")
    fire()
    assert(truce() and #said == 0, "a victory was said although the answer taught us no capture to tell")
    teaching = true
    -- Heard on our channel meanwhile: someone said it, we keep quiet. First-hand, or a
    -- copy the relay delivered from the channel; not a victory of the other side's name.
    V = won("Alliance Friend", "BNET")
    sync:OnReceiveTotalVictory(TV, "Horde Mate", "CHANNEL")
    fire()
    assert(#said == 0, "a victory already said on our channel was said again")
    V = won("Alliance Friend", "BNET")
    Overlord.Relay.context = { transport = "CHANNEL", hops = 1 }
    sync:OnReceiveTotalVictory(TV, "Horde Mate", "BETA")
    Overlord.Relay.context = nil
    fire()
    assert(#said == 0, "a victory the relay delivered from our channel was said again")
    V = won("Alliance Friend", "BNET")
    Overlord.Relay.context = { transport = "BNET", hops = 1 }
    sync:OnReceiveTotalVictory(TV, "Horde Mate", "BETA")
    Overlord.Relay.context = nil
    sync:OnReceiveTotalVictory("Horde:" .. V .. ":0:0:elwynn", "Horde Mate", "CHANNEL")
    fire()
    assert(#said == 1, "a copy that did not come from our channel, or a victory of the other faction, silenced ours")
    -- An announcement of another moment heard on our channel (forged: nobody can prove it)
    -- does not keep us quiet; only one of the same moment (+-5 s) does.
    V = won("Alliance Friend", "BNET")
    sync:OnReceiveTotalVictory("Alliance:" .. (V + 50) .. ":0:0:elwynn", "Forger Mate", "CHANNEL")
    fire()
    assert(#said == 1, "an announcement of another moment heard on our channel silenced ours")
    V = won("Alliance Friend", "BNET")
    sync:OnReceiveTotalVictory("Alliance:" .. (V + 4) .. ":0:0:elwynn", "Horde Mate", "CHANNEL")
    fire()
    assert(#said == 0, "an announcement of the same moment (4 s apart) did not keep us quiet")
    -- Its truce is over when our turn comes: nothing to say.
    V = won("Alliance Friend", "BNET")
    clock = V + 901
    fire()
    assert(#said == 0, "a victory whose truce is over was said")
    -- In an instance: nothing leaves.
    V = won("Alliance Friend", "BNET")
    Overlord.InstanceSuspended = true
    fire()
    Overlord.InstanceSuspended = false
    assert(#said == 0, "a victory was said from an instance")
    -- Heard on the channel, or relayed (not a reply addressed to us): believed, never said again.
    V = won("Horde Mate", "CHANNEL")
    assert(truce(), "fixture: the channel victory was not believed")
    fire()
    assert(#said == 0, "a victory heard on our channel was said again")
    targeted = false
    V = won("Alliance Friend", "BNET")
    fire()
    assert(truce() and #said == 0, "a relayed victory (not a reply we asked for) was said again")
    targeted = true
    -- The friend's announcement first waits for its proof, then the timed retry accepts it
    -- (outside the dispatch of his reply): still said.
    fresh("Horde")
    timers, said = {}, {}
    V = clock
    allExcept("Alliance", V - 3000)
    set(missing, "Horde", V - 4000)
    set(elwynn.hordeCapitalId, "Alliance", V)
    TV = "Alliance:" .. V .. ":0:0:elwynn"
    sync:OnReceiveTotalVictory(TV, "Alliance Friend", "BNET")
    assert(not truce(), "fixture: a victory without its proof was believed")
    set(missing, "Alliance", V)
    targeted = false
    sync:OnReceiveTotalVictory(TV, "Alliance Friend", "BNET", true)
    targeted = true
    assert(truce(), "fixture: the retry did not accept the victory")
    fire()
    assert(#said == 1, "a friend's victory accepted at a retry was not said: " .. #said)
    -- Same wait, ended by the map check of a client standing on the front: said too.
    clock = clock + 1000 -- another victory, later
    fresh("Horde")
    timers, said = {}, {}
    V = clock
    allExcept("Alliance", V - 3000)
    set(missing, "Horde", V - 4000)
    set(elwynn.hordeCapitalId, "Alliance", V)
    TV = "Alliance:" .. V .. ":0:0:elwynn"
    sync:OnReceiveTotalVictory(TV, "Alliance Friend", "BNET")
    set(missing, "Alliance", V)
    again("map")
    assert(truce(), "fixture: the map check did not accept the waiting victory")
    fire()
    assert(#said == 1, "a friend's victory accepted by the map check was not said: " .. #said)
    sync.SendToChannel, Overlord.Relay, sync.GetBetaPeerFaction = realChannel, realRelay, realFaction
    sync.IsUnauthenticatedRelayOrigin = realUnauth
    sync.MapNewsUnderWay = realUnderWay
    C_Timer.After = function() end
end
print("Forever victory: a capture the loser dates after a victory does not keep a client out of the truce")
