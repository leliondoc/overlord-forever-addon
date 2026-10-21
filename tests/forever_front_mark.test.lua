-- 2.0.8: front mark. A client on another layout of a front (other point ids there:
-- Hillsbrad had 2 points before 2.0.3, 10 since) saw sieges that are impossible on the
-- current map, and its capture painted every current map (a capital taken while half its
-- front was still enemy, reported on Discord 2026-10-20). Captures (C) and zone states
-- (ZS) now end with ":~f<mark>", the mark of the sender's front (its point ids, as the
-- map layout "~y"). A marked message from another layout of that front is ignored, and
-- so is an unmarked one: 2.0.8 is the launch floor (the beta closed on 2026-10-21, the
-- game opened on 2026-11-04 with fresh installs), and 2.0.7 and older (the 2.0.2 of that
-- report included) also leave the map exchange (Relay MAP_LAYOUT_SALT). Every C and ZS we
-- send carries the mark; a copy it would not fit is not sent. Real Sync and lease code.
assert(loadfile("tests/forever_world_kills.test.lua"))()
Overlord.L.ZONE_NAMES = {}
setmetatable(Overlord.L, { __index = function(_, key) return tostring(key) end })
Overlord.PlayerFaction = "Alliance"
UnitIsDead = UnitIsDead or function() return false end
UnitIsDeadOrGhost = UnitIsDeadOrGhost or function() return false end
UnitIsGhost = UnitIsGhost or function() return false end
assert(loadfile("Fronts.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync = Overlord.Sync
local clock, wall = 1000, time()
function GetTime() return clock end
function time() return wall end
function GetServerTime() return wall end
Overlord.ServerNow = function() return wall end
local timers = {}
C_Timer.After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end
C_Timer.NewTimer = function(delay, fn)
    local timer = { at = clock + delay, fn = fn, Cancel = function(self) self.cancelled = true end }
    timers[#timers + 1] = timer
    return timer
end
local function advance(seconds)
    local stop = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > stop then break end
        table.remove(timers, 1)
        wall, clock = wall + (timer.at - clock), timer.at
        if not timer.cancelled then timer.fn() end
    end
    wall, clock = wall + (stop - clock), stop
end
OverlordDB.zones, OverlordDB.frontVictories, OverlordDB.frontTruceResetEpoch = {}, {}, {}
Overlord.Fronts:Activate("elwynn")
Overlord.Zones:ApplyFactionConfig("Alliance")
Overlord:RestoreZoneState()
Overlord.PrintNotification = function() end
Overlord.SaveState = function() end
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do zone._loginSyncUnconfirmed = nil end
end
if Overlord.MarkCaptureSyncReceived then Overlord:MarkCaptureSyncReceived(true) end

local function zoneOf(id) return (select(1, Overlord.Fronts:GetZone(id))) end
local function set(id, owner, at)
    local zone = zoneOf(id)
    zone.owner, zone.status, zone.capturedTime, zone.updatedAt = owner, owner and "captured" or "locked", at, at
end
local function tail(mark) return mark and (":~f" .. mark) or "" end
local function progress(id, code, who, wave, guid, hold, mark)
    sync:OnReceiveZoneState(table.concat({ id, "in_progress", 0, hold, code, wall, 0, 120, who, 1, wave, guid }, ":")
        .. tail(mark), who, "CHANNEL")
end
local function finalC(id, faction, who, wave, guid, mark)
    sync:OnReceiveCapture(table.concat({ id, who .. "|WARRIOR", faction, wall, wave, guid, 120 }, ":")
        .. tail(mark), who)
end
local function finalZS(id, code, who, wave, guid, mark)
    sync:OnReceiveZoneState(table.concat({ id, "captured", 0, 0, code, wall, 0, 120, who, 1, wave, guid, 120 }, ":")
        .. tail(mark), who, "CHANNEL")
end
local function counted(what) return sync:GetEnemyCaptureFinalDiagnostics():find(what, 1, true) ~= nil end

-- (1) The mark: four characters, one per front, stable, order-free, and it moves with
-- the point ids of its front or with FRONT_RULES, never with routes or another front.
local elwynn, hillsbrad = sync:GetFrontMark("goshek"), sync:GetFrontMark("hillsbrad_tarren_mill")
local hillsbradFront = select(2, Overlord.Fronts:GetZone("hillsbrad_tarren_mill"))
assert(hillsbradFront and hillsbradFront.id == "hillsbrad", "fixture: Tarren Mill is not on the Hillsbrad front")
assert(type(elwynn) == "string" and elwynn:match("^%w%w%w%w$"), "no mark for Elwynn: " .. tostring(elwynn))
assert(type(hillsbrad) == "string" and hillsbrad ~= elwynn, "two fronts share one mark")
assert(sync:GetFrontMark("goshek") == elwynn, "the mark of a front is not stable")
assert(sync:GetFrontMark("unknown_zone_id") == nil, "a zone on no front got a mark")
local function freshMark(id)
    sync._frontMarks = {}
    return sync:GetFrontMark(id)
end
local zones = hillsbradFront.zones
local saved = {}
for i = 1, #zones do saved[i] = zones[i] end
-- Order-free: the same points listed in another order give the same mark.
for i = 1, math.floor(#zones / 2) do zones[i], zones[#zones + 1 - i] = zones[#zones + 1 - i], zones[i] end
assert(freshMark("hillsbrad_tarren_mill") == hillsbrad, "the mark depends on the order of the points")
-- The 2.0.2 layout (Southshore and Tarren Mill only) is another Hillsbrad.
for i = #zones, 1, -1 do zones[i] = nil end
for _, zone in ipairs(saved) do
    if zone.id == "hillsbrad_tarren_mill" or zone.id == "hillsbrad_southshore" then zones[#zones + 1] = zone end
end
assert(#zones == 2, "fixture: the two capitals of Hillsbrad are not found")
local oldHillsbrad = freshMark("hillsbrad_tarren_mill")
assert(oldHillsbrad ~= hillsbrad, "the two-point Hillsbrad has the ten-point mark")
assert(sync:GetFrontMark("goshek") == elwynn, "a change on Hillsbrad moved the Elwynn mark")
for i = #zones, 1, -1 do zones[i] = nil end
for i = 1, #saved do zones[i] = saved[i] end
assert(freshMark("hillsbrad_tarren_mill") == hillsbrad, "fixture: Hillsbrad not restored")
-- Another route on the same points keeps the mark, as it keeps "~y": its maps still
-- cross, so its live captures must too.
local route = hillsbradFront.prereqs.Alliance.hillsbrad_tarren_mill
hillsbradFront.prereqs.Alliance.hillsbrad_tarren_mill = { "hillsbrad_bridge" }
assert(freshMark("hillsbrad_tarren_mill") == hillsbrad, "a route change moved the mark (maps would still cross)")
hillsbradFront.prereqs.Alliance.hillsbrad_tarren_mill = route
sync.FRONT_RULES = sync.FRONT_RULES + 1
assert(freshMark("hillsbrad_tarren_mill") ~= hillsbrad, "FRONT_RULES does not move the mark")
sync.FRONT_RULES = sync.FRONT_RULES - 1
assert(freshMark("hillsbrad_tarren_mill") == hillsbrad, "fixture: FRONT_RULES not restored")
-- Every front of the registry has its own mark.
local seenMarks = {}
for id, front in pairs(Overlord.Fronts.Registry) do
    local m = front.zones and front.zones[1] and sync:GetFrontMark(front.zones[1].id)
    assert(type(m) == "string" and m:match("^%w%w%w%w$"), "front without a mark: " .. tostring(id))
    assert(not seenMarks[m], "two fronts share a mark: " .. tostring(id) .. " and " .. tostring(seenMarks[m]))
    seenMarks[m] = id
end

-- (2) Wire: the mark goes last and comes off whole; no copy without it (nil when it would
-- not fit, or for a zone on no front).
-- As BroadcastZoneState builds it: 13 fields, the last (final requirement) empty in progress.
local body = "goshek:in_progress:0:5:H:" .. wall .. ":0:120:Horde Alpha:1:wA:Player-1-0000AAAA:"
local marked = sync:WithFrontMark("goshek", body)
assert(marked == body .. ":~f" .. elwynn, "the mark is not the last field")
local back, mark = sync:TakeFrontMark(marked)
assert(back == body and mark == elwynn, "the mark does not come off whole")
local plain, none = sync:TakeFrontMark(body)
assert(plain == body and none == nil, "an unmarked payload was changed")
assert(sync:WithFrontMark("goshek", body, #body + 3) == nil, "a copy whose mark does not fit is still sent")
assert(sync:WithFrontMark("unknown_zone_id", body) == nil, "a zone on no front still gets a copy")
-- After the witness fields (W slot, route), as the heartbeat sends it.
local witness = sync:WithFrontMark("goshek", body .. ":W2:r1")
back, mark = sync:TakeFrontMark(witness)
assert(back == body .. ":W2:r1" and mark == elwynn, "a witness heartbeat lost its W fields")
-- An older reader (2.0.7) reads at most 17 ZS fields: the mark lands in a slot it ignores.
local fields = { strsplit(":", marked) }
assert(fields[14] == "~f" .. elwynn and not fields[14]:match("^Q([0-9a-f]+)$")
    and not fields[14]:match("^W[1-5]$") and tonumber(fields[14]) == nil,
    "an older reader could take the mark for a probe, a witness or a number")

-- (3) Another front layout: the siege is not shown, the final changes nothing, in
-- C and in ZS; the refusals are counted.
local T0 = wall
set("goshek", "Alliance", T0 - 40000)
set("witherbark", "Alliance", T0 - 40000)
local goshek, witherbark = zoneOf("goshek"), zoneOf("witherbark")
sync._enemyFinalStats, sync._frontMarkRefused = nil, nil
progress("goshek", "H", "Horde Old", "wO", "Player-1-0000OOOO", 5, oldHillsbrad)
assert(goshek.status == "captured" and goshek.owner == "Alliance" and not goshek._remoteCaptureLease,
    "a siege from another front layout is shown")
advance(120)
finalC("goshek", "Horde", "Horde Old", "wO", "Player-1-0000OOOO", oldHillsbrad)
assert(goshek.owner == "Alliance" and goshek.capturedTime == T0 - 40000,
    "a capture from another front layout took the point")
finalZS("witherbark", "H", "Horde Old", "wO2", "Player-1-0000OOOO", oldHillsbrad)
assert(witherbark.owner == "Alliance" and witherbark.capturedTime == T0 - 40000,
    "a state final from another front layout took the point")
assert(counted("C otherFront 1") and counted("ZS otherFront 1")
    and counted("Copies from another version or front layout ignored: 3"), sync:GetEnemyCaptureFinalDiagnostics())

-- (4) Our own layout, marked: taken.
advance(60)
progress("goshek", "H", "Horde Alpha", "wA", "Player-1-0000AAAA", 5, elwynn)
assert(goshek.status == "in_progress" and goshek._remoteCaptureLease, "a siege marked with our layout is not shown")
advance(115)
local takenAt = wall
finalC("goshek", "Horde", "Horde Alpha", "wA", "Player-1-0000AAAA", elwynn)
assert(goshek.owner == "Horde" and goshek.capturedTime == takenAt, "a capture marked with our layout was refused")

-- (5) Unmarked (2.0.7 and older): ignored like another layout, siege and finals.
advance(60)
local witherbarkBefore = witherbark.capturedTime
progress("witherbark", "H", "Horde Bravo", "wB", "Player-1-0000BBBB", 5)
assert(witherbark.status == "captured" and not witherbark._remoteCaptureLease, "an unmarked siege is shown")
advance(115)
finalZS("witherbark", "H", "Horde Bravo", "wB", "Player-1-0000BBBB")
finalC("witherbark", "Horde", "Horde Bravo", "wB", "Player-1-0000BBBB")
assert(witherbark.owner == "Alliance" and witherbark.capturedTime == witherbarkBefore,
    "an unmarked final took the point")
assert(counted("C unmarked 1") and counted("ZS unmarked 1") and counted("Copies from another version or front layout ignored: 6"),
    sync:GetEnemyCaptureFinalDiagnostics())
-- Our own layout, marked, still takes it.
advance(60)
progress("witherbark", "H", "Horde Bravo", "wB2", "Player-1-0000BBBB", 5, elwynn)
advance(115)
takenAt = wall
finalZS("witherbark", "H", "Horde Bravo", "wB2", "Player-1-0000BBBB", elwynn)
assert(witherbark.owner == "Horde" and witherbark.capturedTime == takenAt, "a marked state final was refused")

-- (6) What we send: the zone state copies end with our mark; a capture too.
local sent = {}
local function keep(kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } return true end
local realGroup, realChannel, realRelay, realBNet = sync.SendToGroup, sync.SendToChannel,
    sync.BroadcastToRelay, sync.SendToBNetFriends
sync.SendToGroup = function(_, kind, payload) return keep(kind, payload) end
sync.SendToChannel = function(_, kind, payload) return keep(kind, payload) end
sync.BroadcastToRelay = function(_, kind, payload) return keep(kind, payload) end
sync.SendToBNetFriends = function(_, kind, payload) return keep(kind, payload) end
-- On the front (relay and Battle.net copies too).
local wasInFront = Overlord.InActiveFront
Overlord.InActiveFront = true
sync:BroadcastZoneState(zoneOf("goshek"), true)
Overlord.InActiveFront = wasInFront
local zsSeen = 0
for _, copy in ipairs(sent) do
    if copy.kind == "ZS" then
        zsSeen = zsSeen + 1
        local stripped, m = sync:TakeFrontMark(copy.payload)
        assert(m == elwynn and select("#", strsplit(":", stripped)) == 13,
            "a zone state copy left without our mark, or with another field count: " .. copy.payload)
    end
end
assert(zsSeen >= 4, "fixture: group, channel, relay and Battle.net copies not all sent: " .. zsSeen)
-- A capture final of ours: every C copy carries the mark too.
sent = {}
sync:BroadcastCapture("goshek", 120)
local cSeen = 0
for _, copy in ipairs(sent) do
    if copy.kind == "C" then
        cSeen = cSeen + 1
        local stripped, m = sync:TakeFrontMark(copy.payload)
        assert(m == elwynn and select("#", strsplit(":", stripped)) == 7,
            "a capture copy left without our mark, or with another field count: " .. copy.payload)
    end
end
assert(cSeen >= 2, "fixture: no capture copy sent")
sync.SendToGroup, sync.SendToChannel, sync.BroadcastToRelay, sync.SendToBNetFriends =
    realGroup, realChannel, realRelay, realBNet

-- (8) Sizes: with the mark required, a copy too long for it is lost. Longest real
-- payloads (longest point id of every front, a 50-byte Name-Realm, the class with the
-- longest token, the widest wave id, GUID, tokens and numbers) keep a margin under 250.
local longestZone = ""
for _, front in pairs(Overlord.Fronts.Registry) do
    for _, zone in ipairs(front.zones) do
        if #zone.id > #longestZone then longestZone = zone.id end
    end
end
local name = string.rep("\195\169", 12) .. "-" .. string.rep("R", 25)          -- 50 bytes
assert(#name == 50, "fixture: name length")
local wave = string.format("w%x_%x_%x", 4294967295, 999999999, 999999)
local guid = "Player-99999-FFFFFFFF"
local token = string.rep("f", 16)
local ts = "1893456000"
local zsBase = table.concat({ longestZone, "in_progress", 9999, 600, "H", ts, 3, 600, name, 99999, wave, guid, 600 }, ":")
local worst = {
    C = table.concat({ longestZone, name .. "|DEATHKNIGHT", "Alliance", ts, wave, guid, 600 }, ":"),
    ZS = zsBase,
    probe = zsBase .. ":Q" .. token .. ":499",
    witness = zsBase .. ":W3:" .. "R" .. token,
    SR = table.concat({ longestZone, "in_progress", 9999, 600, "H", ts, 0, 600, name, 99999, wave }, ":")
        .. ":::::600:" .. ts,
}
for kind, payload in pairs(worst) do
    local wire = sync:WithFrontMark(longestZone, payload)
    assert(wire and #wire <= 240, kind .. ": the longest payload does not keep a 10-byte margin with its mark: "
        .. tostring(wire and #wire or #payload + 7))
end
-- Relay fragments (200 bytes since 2.0.8): "BF:<id>:<part>:<count>:" + 200 stays under the
-- 255 bytes of an addon message, the session id being 11 characters and the serial 7 digits.
assert(#("BF:" .. string.rep("z", 11) .. "-9999999" .. ":18:18:" .. string.rep("x", 200)) <= 255,
    "a 200-byte relay fragment no longer fits an addon message")

-- (7) Golden values, frozen from the 2.0.8 release on. A mark is a protocol constant:
-- clients of different marks ignore each other's live captures on that front. It may
-- only move together with the map layout "~y" (Relay LocalMapLayout: MAP_LAYOUT_SALT
-- or the zone ids), in the same change, never alone (FRONT_RULES included).
sync._frontMarks = {}
local GOLDEN = { arathi = "jdmc", ashenvale = "xi4b", durotar = "u15r", elwynn = "w9up",
    hillsbrad = "6kdm", loch_modan = "ro3u", redridge = "zorv" }
assert(sync.FRONT_RULES == 1, "FRONT_RULES moved: every front mark moves, and \"~y\" must move with it")
local frontCount = 0
for id, front in pairs(Overlord.Fronts.Registry) do
    frontCount = frontCount + 1
    assert(GOLDEN[id], "new front " .. tostring(id) .. ": add its mark here, together with a \"~y\" change")
    local m = sync:GetFrontMark(front.zones[1].id)
    assert(m == GOLDEN[id], "the mark of " .. id .. " moved (" .. tostring(m) .. "): live captures would be cut "
        .. "between versions; move \"~y\" in the same change and update both golden values")
end
assert(frontCount == 7, "a front left the registry: update the golden marks with \"~y\"")
assert(loadfile("SyncRelay.lua"))()
assert(Overlord.Relay and Overlord.Relay.LocalMapLayout and Overlord.Relay.LocalMapLayout() == "9rpf",
    "the map layout \"~y\" moved: update the golden front marks in the same change")

print("Forever front mark: one mark per front, last on the wire; another layout's sieges and captures "
    .. "ignored on that front only, unmarked ones too (2.0.8 floor); our layout taken; sizes and golden values pinned")
