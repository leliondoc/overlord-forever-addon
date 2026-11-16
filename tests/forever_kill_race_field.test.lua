-- Races had holes on Forever: communities (which gave every member's race) are off,
-- leaving the weekly race beacon and the slow LR catch-up. The owner's K now carries
-- its race and sex at most every 10 minutes, in the 13-field layout every client
-- (1.3.4 included) still parses. ~10 bytes, dropped first if the K is too long.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local s = Overlord.Sync
local EPOCH = 1789527600

-- 1. With a race: 13 fields, parsed back as race + sex, bucket and level intact.
local withRace = s:BuildKillBroadcastPayload("Grok Smash", "", 120, "WARRIOR", "Horde", EPOCH,
    "Iron Wolves", "enus", 0, EPOCH, 30, "Orc", 2)
assert(withRace, "fixture: no K built")
local name, _, kills, class, faction, epoch, guild, loc, _, race, sex, bucket, level =
    s:ParseKillPayload(withRace)
assert(name == "Grok Smash" and kills == "120" and class == "WARRIOR" and faction == "Horde")
assert(guild == "Iron Wolves" and loc == "enus")
assert(race == "Orc" and sex == 2, "race not parsed back: " .. tostring(race) .. "/" .. tostring(sex))
assert(bucket and bucket:match("^B%d+$") and tonumber(level) == 30, "bucket/level shifted by the race fields")

-- 2. Without a race: the usual 11-field K, unchanged.
local plain = s:BuildKillBroadcastPayload("Grok Smash", "", 120, "WARRIOR", "Horde", EPOCH,
    "Iron Wolves", "enus", 0, EPOCH, 30)
local _, _, _, _, _, _, _, _, _, race2, _, bucket2, level2 = s:ParseKillPayload(plain)
assert(race2 == "" and bucket2 and tonumber(level2) == 30, "plain K changed")
assert(#withRace - #plain <= 12, "race costs more than ~10 bytes: " .. (#withRace - #plain))

-- 3. Too long with the race: the race is dropped first, the score still goes out.
local longGuild = string.rep("G", 24)
local longName = "Averyveryverylongname Withaverylongsurname"
local fallback = s:BuildKillBroadcastPayload(longName, string.rep("z", 120), 120, "WARRIOR", "Horde",
    EPOCH, longGuild, "enus", 0, EPOCH, 30, "Orc", 2)
assert(fallback and #fallback <= 250, "oversized K not shrunk")
-- 4. Skyborne (Forever's ninth race, a token per faction): carried like any race,
-- and stored for its owner when his K is received.
local sky = s:BuildKillBroadcastPayload("Sky Walker", "", 40, "MAGE", "Alliance", EPOCH,
    "", "engb", 0, EPOCH, 30, "SkyborneAlliance", 3)
local _, _, _, _, _, _, _, _, _, skyRace, skySex = s:ParseKillPayload(sky)
assert(skyRace == "Skyborne" and skySex == 3, "Skyborne race not carried in K: " .. tostring(skyRace))
s:OnReceiveKill(sky, "Sky Walker")
local skyInfo = Overlord.Leaderboard.playerInfo["Sky Walker"]
assert(skyInfo and skyInfo.race == "Skyborne", "Skyborne race not stored from its owner's K: "
    .. tostring(skyInfo and skyInfo.race))

-- 5. 2.5.4: which of our own totals carry the race (Sync:BroadcastKill). With the channel: the
-- first one, then one every 10 minutes. Without it (the member-list directory carries our
-- totals by whisper, one per half minute, the latest only): every one. The single total of
-- ten minutes was often never told there (no contact yet after a login, or replaced while it
-- waited), and its owner stayed ranked everywhere with no race.
do
    -- (The fixture replaced BroadcastKill by a recorder: the real one again, as it loads it.)
    assert(loadfile("Sync.lua"))()
    local clock, timers, sent = 5000, {}, {}
    GetTime = function() return clock end
    C_Timer = C_Timer or {}
    C_Timer.After = function(_, run) timers[#timers + 1] = run end
    IsInInstance = function() return false end
    GetChannelName = function() return 1 end
    IsInRaid, IsInGroup = function() return false end, function() return false end
    UnitRace = function() return "Orc", "Orc" end
    UnitSex = function() return 2 end
    Overlord.InstanceSuspended = false
    s.SendKillBroadcast = function(_, payload) sent[#sent + 1] = payload end
    s.SendToChannel, s.SendToBNetFriends, s.BroadcastToRelay = function() end, function() end, function() end
    s.MaybeBroadcastLeaderboardRaceBeacon = function() end
    local directoryActive, directoryBroken = false, false
    Overlord.ChannelDirectory = { IsActive = function()
        if directoryBroken then error("directory broken") end
        return directoryActive
    end }
    local total = 10
    local function kill(after)
        clock = clock + after
        total = total + 1
        s:BroadcastKill("", total, true)
        local run = timers
        timers = {}
        for _, fn in ipairs(run) do fn() end
        local payload = sent[#sent]
        assert(payload, "fixture: no K left for a kill")
        local _, _, _, _, _, _, _, _, _, race = s:ParseKillPayload(payload)
        return race == "Orc"
    end
    s._lastRaceInKillAt = nil
    assert(kill(1) == true, "the first total of a session has no race")
    assert(kill(5) == false and kill(5) == false, "with the channel, the race rides more than once per 10 min")
    assert(kill(600) == true and kill(5) == false, "with the channel, the race no longer rides every 10 min")
    directoryActive = true
    assert(kill(5) == true and kill(5) == true and kill(5) == true,
        "without the channel, a total of ours left without its race")
    directoryActive = false
    assert(kill(5) == false, "the channel back, every total still carries the race")
    -- (A directory that raises never costs a total: asked under pcall, read as "not active".)
    directoryBroken = true
    assert(kill(5) == false and #sent == 10, "a directory that raised lost a total or gave it the race")
    directoryBroken = false
    -- (A directory that cannot answer never stops a total.)
    Overlord.ChannelDirectory = nil
    assert(kill(5) == false and #sent == 11, "no directory: a total was lost or carried the race")
end

-- 6. 2.5.4 (same file: the real Sync.lua is loaded here). A layer said in an SH is its sender's
-- own word only when the game names that sender: the origin of a relayed copy is whatever its
-- relay wrote, and a Battle.net or bridge label is no character. The Layers window keeps an own
-- word ten minutes and anything else three (LayerJumper NoteLayer, Shard:SetPlayerShard).
do
    local said = {}
    local savedShard, savedRelay = Overlord.Shard, Overlord.Relay
    Overlord.Shard = { SetPlayerShard = function(_, who, sid, first) said[#said + 1] = { who, sid, first } end }
    Overlord.Relay = { IsRelayedOrigin = function(_, who) return who == "Relayed Origin" end }
    -- (By whisper only a player of the channel's member list, as for the layer of a presence.)
    local savedDirectory = Overlord.ChannelDirectory
    Overlord.ChannelDirectory = { Known = function(_, who) return who == "Direct Sender" end }
    s:OnReceiveShard("6860", "Unlisted Whisperer", "WHISPER")
    s:OnReceiveShard("6861", "Unlisted Whisperer", "PARTY")
    assert(#said == 2 and said[1][3] == false and said[2][3] == true,
        "a whispered SH of a player outside the member list is an own word, or a group SH is not")
    Overlord.ChannelDirectory = nil
    s:OnReceiveShard("6862", "Direct Sender", "WHISPER")
    assert(said[3][3] == false, "a whispered SH is an own word without any member list")
    Overlord.ChannelDirectory = { Known = function(_, who) return who == "Direct Sender" end }
    said = {}
    s:OnReceiveShard("6868", "Direct Sender", "WHISPER")
    s:OnReceiveShard("6869", "Relayed Origin", "WHISPER")
    s:OnReceiveShard("6870", "BNet-1234", "BNET")
    s:OnReceiveShard("6871", "Bridge-Someone", "BNET")
    s:OnReceiveShard("not a layer", "Direct Sender", "WHISPER")
    assert(#said == 4, "layers taken from SH: " .. #said)
    assert(said[1][1] == "Direct Sender" and said[1][2] == 6868 and said[1][3] == true, "a direct SH is not its sender's own word")
    assert(said[2][3] == false, "a relayed SH counts as its origin's own word")
    assert(said[3][3] == false and said[4][3] == false, "a Battle.net or bridge label counts as a player's own word")
    -- An SH of the relay is handed over as "BETA": its real transport is the relay's own. By
    -- whisper, a player the directory knows only; over Battle.net, the other faction unless the
    -- game shows that character in ours (never an own word for the window, and marked for it).
    local marked = {}
    local savedJumper, savedResolved = Overlord.LayerJumper, s.GetResolvedBNetPlayerFaction
    Overlord.LayerJumper = { NoteEnemy = function(_, who) marked[#marked + 1] = who end }
    s.GetResolvedBNetPlayerFaction = function(_, who) return who == "Friend Ours" and Overlord.PlayerFaction or nil end
    said = {}
    Overlord.Relay.context = { transport = "WHISPER", hops = 0 }
    s:OnReceiveShard("6880", "Unlisted Whisperer", "BETA")
    s:OnReceiveShard("6881", "Direct Sender", "BETA")
    Overlord.Relay.context = { transport = "CHANNEL", hops = 0 }
    s:OnReceiveShard("6882", "Unlisted Whisperer", "BETA")
    Overlord.Relay.context = { transport = "BNET", hops = 0 }
    s:OnReceiveShard("6883", "Friend Theirs", "BETA")
    s:OnReceiveShard("6884", "Friend Ours", "BETA")
    Overlord.Relay.context = nil
    assert(said[1][3] == false and said[2][3] == true, "a relayed-as-BETA whisper: only a player the directory knows is an own word")
    assert(said[3][3] == true, "an SH heard on the channel is no longer its sender's own word")
    assert(said[4][3] == false and said[5][3] == true and #marked == 1 and marked[1] == "Friend Theirs",
        "an SH over Battle.net: the other faction is not an own word and is marked, a friend of ours is")
    Overlord.LayerJumper, s.GetResolvedBNetPlayerFaction = savedJumper, savedResolved
    said = { {}, {}, {}, {} }
    Overlord.Relay = nil
    s:OnReceiveShard("6872", "Direct Sender", "WHISPER")
    assert(said[5][3] == true, "without the relay a direct SH is no longer an own word")
    Overlord.Shard, Overlord.Relay, Overlord.ChannelDirectory = savedShard, savedRelay, savedDirectory
end
print("K race field: 13-field layout parsed back, ~10 bytes, dropped first when too long, Skyborne carried, every total without the channel; SH own word OK")
