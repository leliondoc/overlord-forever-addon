-- Without a Community, the login state request used to reach every peer (answer
-- storm across Battle.net bridges). Like the Retail community catch-up, it now
-- sends a few targeted territorial requests to peers found by the beta relay.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync = Overlord.Sync
local timers = {}
C_Timer.After = function(delay, callback) timers[#timers + 1] = { delay = delay, run = callback } end
local function drain()
    local guard = 0
    while #timers > 0 do
        guard = guard + 1
        assert(guard < 100, "Login catch-up never settled")
        table.remove(timers, 1).run()
    end
end
local peers = {}
local broadcasts = 0
Overlord.RelayEnabled = true
Overlord.Relay = {
    Broadcast = function(_, kind) if kind == "SR" then broadcasts = broadcasts + 1 end return 1 end,
    GetPeers = function() return peers end,
    GetDirectPeers = function() return peers end,
    IsPeer = function() return true end,
}
local outdated = {}
Overlord.Relay.IsOutdatedMapPeer = function(_, name) return outdated[name] == true end
Overlord.PlayerFaction = "Horde"
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
securecall = securecall or function(fn, ...) return fn(...) end
local whispers = {}
sync.SendWhisper = function(_, kind, payload, target)
    whispers[#whispers + 1] = { kind = kind, payload = payload, target = target }
    return true
end
local factions = {}
sync.GetBetaPeerFaction = function(_, name) return factions[name] end
-- The periodic map catch-up re-arms forever; observe it separately below.
local realScheduleMapCatchup = sync.SchedulePeriodicMapCatchup
local mapCatchupStarts = 0
sync.SchedulePeriodicMapCatchup = function() mapCatchupStarts = mapCatchupStarts + 1 end

-- No peer known yet: at most three spaced attempts, then stop.
sync:SendLoginCatchupSync()
assert(broadcasts == 1, "Bounded broadcast fallback removed")
drain()
assert(#whispers == 0 and not sync._betaLoginCatchupScheduled, "Empty peer list retried forever")

-- Five same-faction and three enemy direct neighbours: two targeted requests, one enemy.
for i = 1, 5 do local n = "Horde Peer" .. string.char(64 + i); peers[#peers + 1] = n; factions[n] = "Horde" end
for i = 1, 3 do local n = "Ally Peer" .. string.char(64 + i); peers[#peers + 1] = n; factions[n] = "Alliance" end
sync:SendLoginCatchupSync()
assert(#timers == 1 and timers[1].delay == sync.BETA_LOGIN_CATCHUP_FIRST_DELAY,
    "Login catch-up was not delayed until peers are heard")
assert(sync:SendLoginCatchupSync() == 1 and #timers == 1,
    "A second login call stacked another catch-up")
drain()
assert(#whispers == 2, "Expected two targeted requests, got " .. #whispers)
local enemies = 0
for _, w in ipairs(whispers) do
    assert(w.kind == "SR" and w.payload:match(":T$"), "Not a territorial request: " .. tostring(w.payload))
    if factions[w.target] == "Alliance" then enemies = enemies + 1 end
end
assert(enemies == 1, "Opposite-faction peer not preferred: " .. enemies)
assert(not sync._betaLoginCatchupScheduled)
assert(mapCatchupStarts > 0, "Periodic map catch-up was not started with the login catch-up")
-- Periodic map catch-up: one targeted territorial request per round, alternating
-- the other faction first, armed only once.
whispers = {}
sync._mapCatchupRound = 0
assert(sync:RunPeriodicMapCatchup() and sync:RunPeriodicMapCatchup())
assert(#whispers == 2 and whispers[1].kind == "SR" and whispers[1].payload:match(":T$"))
assert(factions[whispers[1].target] == "Alliance" and factions[whispers[2].target] == "Horde",
    "Map catch-up did not alternate factions")
-- 1.8.2: a map of our own side received within the interval skips our own side's
-- turn, never the other faction's (on a busy channel such maps arrive all the time,
-- and the enemy friend, the only way to the other faction's map, was never asked).
whispers = {}
sync._mapCatchupRound = 0
sync._lastFullZaAt, sync._lastOwnFullZaAt, sync._lastEnemyFullZaAt = GetTime(), GetTime(), nil
assert(sync:RunPeriodicMapCatchup() and factions[whispers[1].target] == "Alliance",
    "A map of our own side skipped the pull toward the other faction")
assert(not sync:RunPeriodicMapCatchup() and #whispers == 1,
    "A map received within the interval did not skip our own side's turn")
-- A skipped turn is served (that side's map came another way): the next tick is the
-- other faction's again. The skipped turn used to be tried again forever, so the
-- other faction was asked once per session while maps of our side kept arriving.
assert(sync._mapCatchupRound == 2, "A skipped turn was not counted as served")
assert(sync:RunPeriodicMapCatchup() and #whispers == 2 and factions[whispers[2].target] == "Alliance",
    "The other faction was never asked again while maps of our own side kept arriving")
-- A map from the other faction within the interval does skip the other faction's turn.
sync._mapCatchupRound = 0
sync._lastFullZaAt, sync._lastOwnFullZaAt, sync._lastEnemyFullZaAt = GetTime(), nil, GetTime()
assert(not sync:RunPeriodicMapCatchup() and #whispers == 2 and sync._mapCatchupRound == 1,
    "A fresh map of the other faction did not skip the pull toward it")
-- That same map (the other faction's reply to its own turn) does not hold our own
-- side's turn back: each turn only waits for maps of the side it asks. Our own
-- side used never to be asked while the other faction kept answering.
assert(sync:RunPeriodicMapCatchup() and #whispers == 3 and factions[whispers[3].target] == "Horde",
    "The other faction's reply held back the pull toward our own side")
-- With nobody of our own side to ask, the turn goes to the other faction and waits
-- for its maps like its own turn (no pull twice as often).
do
    local kept = peers
    peers = {}
    for _, name in ipairs(kept) do if factions[name] == "Alliance" then peers[#peers + 1] = name end end
    sync._mapCatchupRound = 1
    assert(not sync:RunPeriodicMapCatchup() and #whispers == 3,
        "Without a neighbour of our own side the other faction was asked right after its map")
    peers = kept
end
-- An accepted map says which side it came from.
sync._lastFullZaAt, sync._lastEnemyFullZaAt = nil, nil
sync._lastOwnFullZaAt = nil
sync:NoteFullMapReceived("Horde PeerA")
assert(sync._lastFullZaAt and sync._lastOwnFullZaAt and not sync._lastEnemyFullZaAt,
    "A map of our own side counted as the other faction's")
sync._lastOwnFullZaAt = nil
sync:NoteFullMapReceived("Ally PeerA")
assert(sync._lastEnemyFullZaAt and not sync._lastOwnFullZaAt, "A map of the other faction was not noted as such")
sync._lastFullZaAt, sync._lastOwnFullZaAt, sync._lastEnemyFullZaAt = nil, nil, nil
-- 1.8.2: a client from before 1.7.0 is never asked for its map, at login or later
-- (update required). Here every neighbour of the other faction is one.
do
    for name, faction in pairs(factions) do outdated[name] = faction == "Alliance" end
    whispers = {}
    assert(sync:RunBetaPeerLoginCatchup(1) > 0, "Login catch-up found no updated neighbour")
    drain()
    assert(#whispers > 0)
    for _, w in ipairs(whispers) do
        assert(factions[w.target] == "Horde", "The login catch-up asked a client from before 1.7.0: " .. w.target)
    end
    whispers = {}
    sync._mapCatchupRound = 0
    assert(sync:RunPeriodicMapCatchup() and sync:RunPeriodicMapCatchup() and #whispers == 2)
    for _, w in ipairs(whispers) do
        assert(factions[w.target] == "Horde", "The periodic map pull asked a client from before 1.7.0: " .. w.target)
    end
    for name in pairs(outdated) do outdated[name] = nil end
    whispers = {}
    sync._mapCatchupRound = 0
    assert(sync:RunPeriodicMapCatchup() and factions[whispers[1].target] == "Alliance",
        "fixture: updated neighbours of the other faction are asked")
    sync._lastFullZaAt, sync._lastEnemyFullZaAt = nil, nil
end
timers = {}
sync.SchedulePeriodicMapCatchup = realScheduleMapCatchup
sync._mapCatchupArmed = nil
assert(sync:SchedulePeriodicMapCatchup() and not sync:SchedulePeriodicMapCatchup() and #timers == 1,
    "Map catch-up armed twice")
assert(timers[1].delay >= sync.BETA_MAP_CATCHUP_INTERVAL)
-- A login inside an instance skipped the login stage: leaving the instance arms the
-- periodic map pull and the guild identity heartbeat once.
timers = {}
sync._mapCatchupArmed = nil
local wasSuspended, wasWaiting = Overlord.InstanceSuspended, Overlord.WaitingForSync
Overlord.InstanceSuspended, Overlord.WaitingForSync = false, true
local heartbeats = 0
local realHeartbeat = sync.StartGuildIdentityHeartbeat
sync.StartGuildIdentityHeartbeat = function() heartbeats = heartbeats + 1 end
sync:FlushStateAfterInstance()
sync:FlushStateAfterInstance()
local mapTimers = 0
for _, t in ipairs(timers) do
    if t.delay >= sync.BETA_MAP_CATCHUP_INTERVAL then mapTimers = mapTimers + 1 end
end
assert(sync._mapCatchupArmed and mapTimers == 1, "leaving an instance did not arm the map pull exactly once")
assert(heartbeats >= 1, "leaving an instance did not start the guild identity heartbeat")
sync.StartGuildIdentityHeartbeat = realHeartbeat
Overlord.InstanceSuspended, Overlord.WaitingForSync = wasSuspended, wasWaiting
print("Forever beta login catch-up: 2 targeted territorial requests to direct neighbours, 1 opposite-faction, bounded retries, instance exit arms the map pull OK")
