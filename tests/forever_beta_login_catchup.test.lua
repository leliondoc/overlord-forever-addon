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
Overlord.BetaNetworkEnabled = true
Overlord.BetaNetwork = {
    Broadcast = function(_, kind) if kind == "SR" then broadcasts = broadcasts + 1 end return 1 end,
    GetPeers = function() return peers end,
    IsPeer = function() return true end,
}
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

-- No peer known yet: at most three spaced attempts, then stop.
sync:SendLoginCatchupSyncToCommunity()
assert(broadcasts == 1, "Bounded broadcast fallback removed")
drain()
assert(#whispers == 0 and not sync._betaLoginCatchupScheduled, "Empty peer list retried forever")

-- Five same-faction and three enemy peers: three targeted requests, two enemies.
for i = 1, 5 do local n = "Horde Peer" .. string.char(64 + i); peers[#peers + 1] = n; factions[n] = "Horde" end
for i = 1, 3 do local n = "Ally Peer" .. string.char(64 + i); peers[#peers + 1] = n; factions[n] = "Alliance" end
sync:SendLoginCatchupSyncToCommunity()
assert(#timers == 1 and timers[1].delay == sync.BETA_LOGIN_CATCHUP_FIRST_DELAY,
    "Login catch-up was not delayed until peers are heard")
assert(sync:SendLoginCatchupSyncToCommunity() == 1 and #timers == 1,
    "A second login call stacked another catch-up")
drain()
assert(#whispers == 3, "Expected three targeted requests, got " .. #whispers)
local enemies = 0
for _, w in ipairs(whispers) do
    assert(w.kind == "SR" and w.payload:match(":T$"), "Not a territorial request: " .. tostring(w.payload))
    if factions[w.target] == "Alliance" then enemies = enemies + 1 end
end
assert(enemies == 2, "Opposite-faction peers not preferred: " .. enemies)
assert(not sync._betaLoginCatchupScheduled)
print("Forever beta login catch-up: targeted territorial requests, 2 opposite-faction peers, bounded retries OK")
