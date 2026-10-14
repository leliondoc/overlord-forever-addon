-- 2.0: an enemy capture learnt from a map page instead of its live final. Seen in
-- game on 2026-10-11: Hammerfall retaken by the Horde changed colour on an Alliance
-- map minutes later without a word (a front the player was not standing on), and
-- nothing in /ov network told how the capture had come. Such a capture is now counted
-- and said in chat as a catch-up, with its time: one line per map. Real Sync code;
-- only the clock is simulated.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
Overlord.L.SYNC_CAPTURED_FRIENDLY = "Captured"
Overlord.L.SYNC_CAPTURED_ENEMY = "TAKEN %s %s"
Overlord.L.SYNC_CAPTURED_ENEMY_BY = "TAKEN %s %s (%s)"
Overlord.L.SYNC_CATCHUP_ENEMY = "CATCHUP %s: %s"
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync = Overlord.Sync
local clock, wall = 1000, time()
function GetTime() return clock end
function time() return wall end
function GetServerTime() return wall end
Overlord.ServerNow = function() return wall end
local function advance(seconds) clock, wall = clock + seconds, wall + seconds end
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
Overlord:RestoreZoneState()
local chat = {}
Overlord.PrintNotification = function(_, text) chat[#chat + 1] = tostring(text) end
Overlord.SaveState = function() end

local zones, byId = {}, {}
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zones[#zones + 1] = zone; byId[zone.id] = zone end
end
local function set(id, owner, at)
    local zone = assert(byId[id], id)
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = owner, "captured", at, at
    zone.previousOwner, zone._loginSyncUnconfirmed = nil, nil
end
local function save()
    OverlordDB.zones = {}
    for _, zone in ipairs(zones) do
        OverlordDB.zones[zone.id] = { owner = zone.owner, status = zone.status,
            capturedTime = zone.capturedTime, updatedAt = zone.updatedAt,
            killsCurrent = 0, holdTimeElapsed = 0 }
    end
end
local function login()
    for _, zone in ipairs(zones) do
        zone.owner, zone.capturedTime, zone.updatedAt, zone.status = nil, nil, nil, "locked"
    end
    Overlord.Zones:ApplyFactionConfig(Overlord.PlayerFaction)
    Overlord:RequireCaptureSync("login")
    Overlord:RestoreZoneState()
end
local function branches(front)
    local out = {}
    for _, zone in ipairs(front.zones) do
        if zone.id ~= front.allianceCapitalId and zone.id ~= front.hordeCapitalId then out[#out + 1] = zone.id end
    end
    return out
end
local function hour(at) return os.date("%H:%M", at) end
local function lines(what)
    local n = 0
    for _, line in ipairs(chat) do if line:find(what, 1, true) then n = n + 1 end end
    return n
end
local function report() return table.concat(sync:GetCrossFactionDiagnostics(), " | ") end
local function feed(pages, sender, only)
    for index, page in ipairs(pages) do
        if not only or index <= only then sync:OnReceiveZoneAll(page, sender) end
    end
end
for _, zone in ipairs(zones) do zone._loginSyncUnconfirmed = nil end
if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived(true) end

local elwynn, arathi = Overlord.Fronts:GetFront("elwynn"), Overlord.Fronts:GetFront("arathi")
local here, there = branches(elwynn), branches(arathi)
local T = wall
assert(T - 20000 > Overlord:GetCurrentCampaignStartTs(), "Fixture clock before the campaign")

-- Nothing yet.
assert(report() == "Whole maps from the other faction: started 0, complete 0, expired 0, accepted 0, refused 0, identical 0."
    .. " | Whole maps from our faction: started 0, complete 0, expired 0, accepted 0, refused 0, identical 0."
    .. " | Enemy captures learnt by map instead of live: none.", report())

-- (1) In session. Our map: six points of ours. A neighbour's map holds three Horde
-- captures we never heard of: two on another front, one on the front we stand on.
for _, id in ipairs({ there[1], there[2], there[3], here[1], here[2] }) do set(id, "Alliance", T - 20000) end
local mine = { [there[1]] = true, [there[2]] = true, [here[1]] = true }
set(there[1], "Horde", T - 240); set(there[2], "Horde", T - 600); set(here[1], "Horde", T - 300)
local neighbour = sync:BuildZoneAllSnapshotPages(zones, "G")
assert(#neighbour > 1 and neighbour[1]:match("^@G%-"), "The neighbour served no paged global map")
for id in pairs(mine) do set(id, "Alliance", T - 20000) end
feed(neighbour, "Mate Tester")
for id in pairs(mine) do
    assert(byId[id].owner == "Horde", "fixture: the map did not teach " .. id)
end
assert(#chat == 1, "a map that taught three enemy captures printed " .. #chat .. " lines: " .. table.concat(chat, " / "))
local line = chat[1]
assert(line:find("CATCHUP", 1, true) and not line:find("TAKEN", 1, true), "not said as a catch-up: " .. line)
for id, at in pairs({ [there[1]] = T - 240, [there[2]] = T - 600, [here[1]] = T - 300 }) do
    assert(line:find((byId[id].name or id) .. " (", 1, true) and line:find(hour(at), 1, true),
        "the catch-up line lacks " .. id .. " or its time: " .. line)
end
-- Newest first.
assert(line:find(byId[there[1]].name or there[1], 1, true) < line:find(byId[there[2]].name or there[2], 1, true),
    "the newest capture is not named first: " .. line)
assert(report():find("our faction: started 1, complete 1, expired 0, accepted 1, refused 0, identical 0.", 1, true)
    and report():find("by map instead of live: 3 in session (last ", 1, true)
    and report():find("worst 10 min), 0 at login.", 1, true), report())
-- 2.0.2: why they came late. No relay here: nothing is known of who was heard.
assert(report():find("was heard shortly before and after 0 of them", 1, true)
    and report():find("none was for 0, 3 date from before this session. Last: ", 1, true)
    and report():find(here[1] .. " 5 min (before this session)", 1, true), report())

-- A late copy of the live final of one of them, and the same map again: silence.
sync:OnReceiveCapture(table.concat({ here[1], "Horde Alpha|WARRIOR", "Horde", T - 300, "wA", "Player-1-0000AAAA", 120 }, ":"),
    "Horde Alpha")
sync:OnReceiveZoneState(table.concat({ here[1], "captured", 0, 0, "H", T - 300, 0, 120, "Horde Alpha", 1, "wA",
    "Player-1-0000AAAA", 120 }, ":"), "Horde Alpha", "CHANNEL")
advance(5)
feed(neighbour, "Mate Tester")
assert(#chat == 1, "a late final or a second copy of the map spoke again: " .. table.concat(chat, " / "))

-- (2) More than four at once: four named, the rest counted.
chat = {}
advance(60)
for i = 1, 6 do set(there[i], "Alliance", T - 20000) end
for i = 1, 6 do set(there[i], "Horde", wall - 60 * i) end
local burst = sync:BuildZoneAllSnapshotPages(zones, "G")
for i = 1, 6 do set(there[i], "Alliance", T - 20000) end
feed(burst, "Mate Tester")
assert(#chat == 1 and chat[1]:find(" +2", 1, true), "six captures were not one line naming four: " .. table.concat(chat, " / "))

-- 2.0.2: with a friend of the other faction heard around the capture, it is counted
-- apart (its end should have come live) and named so; four are named at most.
do
    local realRelay = Overlord.Relay
    local asked = {}
    -- This session has been listening for half an hour: older captures are "before
    -- this session", the others are sorted by a friend heard around them or not.
    Overlord.Relay = setmetatable({ bnetWatchFrom = GetTime() - 1800, EnemyBridgeHeardAround = function(_, secondsAgo)
        asked[#asked + 1] = secondsAgo
        return secondsAgo < 200
    end }, { __index = realRelay or {} })
    local before = sync._enemyByMapStats.session
    sync:NoteEnemyCaptureByMap(wall - 120, false, "zone_near")
    sync:NoteEnemyCaptureByMap(wall - 900, false, "zone_far")
    sync:NoteEnemyCaptureByMap(wall - 7200, false, "zone_old")
    Overlord.Relay = realRelay
    local why = sync._enemyByMapStats.why
    assert(sync._enemyByMapStats.session == before + 3 and why["friend heard"] == 1 and why["no friend heard"] == 1
        and #asked == 2 and math.abs(asked[1] - 120) <= 1 and math.abs(asked[2] - 900) <= 1,
        "late captures are not sorted by a friend heard around them")
    local text = report()
    assert(text:find("heard shortly before and after 1 of them", 1, true) and text:find("none was for 1, ", 1, true)
        and text:find("Last: zone_old 120 min (before this session), zone_far 15 min (no friend heard), "
            .. "zone_near 2 min (friend heard), ", 1, true), text)
    local _, names = text:match("Last: ([^|]+)"):gsub(" min %(", "")
    assert(names == 4, "the report names " .. tostring(names) .. " late captures, four expected: " .. text)
    -- At login nothing is asked: captures made while we were away are expected.
    asked = {}
    sync:NoteEnemyCaptureByMap(wall - 120, true, "zone_login")
    assert(#asked == 0 and not report():find("zone_login", 1, true), "a login capture was sorted as a late one")
    sync._enemyByMapStats.login = sync._enemyByMapStats.login - 1 -- the synthetic row
end

-- (3) A friendly capture learnt by map on another front: silent, not counted.
chat = {}
advance(60)
local before = report()
set(there[1], "Alliance", wall - 30)
local friendly = sync:BuildZoneAllSnapshotPages(zones, "G")
set(there[1], "Horde", wall - 400)
feed(friendly, "Mate Tester")
assert(byId[there[1]].owner == "Alliance" and #chat == 0, "a friendly capture by map spoke: " .. table.concat(chat, " / "))
assert(report():match("by map instead of live: (%d+) in session") == before:match("by map instead of live: (%d+) in session"),
    "a friendly capture was counted as an enemy one")

-- (4) At login: only the captures of the last half hour are told; both are counted apart.
chat = {}
advance(60)
set(there[1], "Alliance", wall - 9000); set(there[2], "Alliance", wall - 9000)
save()
set(there[1], "Horde", wall - 600); set(there[2], "Horde", wall - 7200)
local away = sync:BuildZoneAllSnapshotPages(zones, "G")
login()
feed(away, "Mate Tester")
assert(byId[there[1]].owner == "Horde" and byId[there[2]].owner == "Horde", "fixture: the login map was not taken")
assert(#chat == 1 and chat[1]:find(hour(wall - 600), 1, true) and not chat[1]:find(hour(wall - 7200), 1, true),
    "login: the recent capture alone must be told: " .. table.concat(chat, " / "))
assert(report():find(", 2 at login.", 1, true), report())

-- (5) Whole maps by side of their sender. From a Battle.net friend of the other
-- faction: one complete, one whose pages stop coming.
for _, zone in ipairs(zones) do zone._loginSyncUnconfirmed = nil end
sync.GetResolvedBNetPlayerFaction = function(_, name) return name == "Horde Friend" and "Horde" or nil end
advance(60)
set(there[3], "Horde", wall - 20)
local theirs = sync:BuildZoneAllSnapshotPages(zones, "G")
set(there[3], "Alliance", T - 20000)
feed(theirs, "Horde Friend")
assert(byId[there[3]].owner == "Horde", "fixture: the friend's map was not taken")
assert(report():find("the other faction: started 1, complete 1, expired 0, accepted 1, refused 0, identical 0.", 1, true), report())
advance(60)
set(there[4], "Horde", wall - 20)
local lost = sync:BuildZoneAllSnapshotPages(zones, "G")
set(there[4], "Alliance", T - 20000)
feed(lost, "Horde Friend", #lost - 1)
assert(byId[there[4]].owner == "Alliance", "an incomplete map changed an owner")
-- Still coming for 45 s, then counted as never applied.
assert(report():find("the other faction: started 2, complete 1, expired 0,", 1, true), report())
advance(46)
assert(report():find("the other faction: started 2, complete 1, expired 1, accepted 1, refused 0, identical 0.", 1, true), report())
-- (6) A chat output that raises (another addon's chat frame) never cuts the map being
-- applied: every zone of the batch is taken, on the immediate line (capturer known from
-- a relayed assault) as on the grouped one.
for _, zone in ipairs(zones) do zone._loginSyncUnconfirmed = nil end
advance(120)
for i = 1, 3 do set(there[i], "Alliance", T - 20000) end
for i = 1, 3 do set(there[i], "Horde", wall - 100 * i) end
local loud = sync:BuildZoneAllSnapshotPages(zones, "G")
for i = 1, 3 do set(there[i], "Alliance", T - 20000) end
byId[there[1]].zsRelayCapturerName = "Horde Alpha"
local say = Overlord.PrintNotification
Overlord.PrintNotification = function() error("another addon's chat frame raised") end
local raised
for _, page in ipairs(loud) do
    local ok, err = pcall(sync.OnReceiveZoneAll, sync, page, "Mate Tester")
    if not ok then raised = err end
end
Overlord.PrintNotification = say
assert(not raised, "a raising chat output left the map handler: " .. tostring(raised))
for i = 1, 3 do
    assert(byId[there[i]].owner == "Horde", "a raising chat output cut the map: zone " .. i .. " was not applied")
end
byId[there[1]].zsRelayCapturerName = nil
print("Forever map catch-up: an enemy capture learnt by map is counted and told once, as a catch-up with its time "
    .. "(four named, login limited to half an hour); whole maps counted by side, incomplete ones included")
