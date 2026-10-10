-- Keep and outpost captures are claims signed by the character who made them
-- (1.7.2). Live, only that character, as the sender WoW authenticates, can state a
-- capture; a reply we asked for may carry claims we did not witness, judged by
-- content (ranked capturer, matching guild). A forged guild ("EMPIRE HACKS")
-- therefore needs a real character that announces every capture under his own
-- name, at most one per hold time. Every rule here is the same on every client.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
local mapID, guild, faction = 1418, "Fortress Guild", "Alliance"
function time() return now end
function GetServerTime() return now end
function GetTime() return now - 1790016000 end
function GetGuildInfo() return guild end
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
function UnitIsDead() return false end
function UnitIsGhost() return false end
function UnitExists(unit) return unit == "player" end
function UnitGUID(unit) return unit == "player" and "Player-1-TEST" end
function UnitFactionGroup() return faction end
function UnitIsPlayer() return true end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0 } end,
    GetPlayerMapPosition = function()
        return { GetXY = function() return 0.1, 0.1 end }
    end,
}
Overlord.ZoneControl = nil
Overlord.Fronts.ResolveFrontByOverlayMapID = function() return nil end
Overlord.Fronts.ResolveFrontByMapID = function() return nil end
Overlord.Fronts.Activate = function() end
Overlord.InActiveFront, Overlord.WaitingForSync, Overlord.InstanceSuspended = false, false, false
Overlord.IsInCatchUpPhase = function() return false end
Overlord.CanStartLocalCapture = function() return true end
Overlord.IsCaptureSyncGateActive = function() return false end
Overlord.IsCaptureSyncPending = function() return false end
Overlord.SaveState = function() end
Overlord.PlayerFaction = faction
OverlordDB = { lastResetTimestamp = 1789527600, config = {}, outposts = {} }
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("Outpost.lua"))()
assert(loadfile("GuildKeep.lua"))()
assert(loadfile("OutpostControl.lua"))()
assert(loadfile("SyncStrategicSites.lua"))()
assert(loadfile("SyncOutpost.lua"))()
assert(loadfile("SyncResolution.lua"))()
local op, sync, lb = Overlord.Outpost, Overlord.Sync, Overlord.Leaderboard
local sent = {}
for _, method in ipairs({ "Send", "SendToChannel", "BroadcastToRelay" }) do
    sync[method] = function(_, kind, data) sent[#sent + 1] = { kind, data }; return true end
end
Overlord.PrintNotification = function() end
local EPOCH = OverlordDB.lastResetTimestamp

local function code(fac) return fac == "Alliance" and "A" or "H" end
local function heldWire(siteKey, g, fac, claimedAt, capturer, holdReq, updatedAt)
    return string.format("v1:%s:held:0:%s:%s:%d:0:%d:%d:global:0:::0:0:%s",
        siteKey, g, code(fac), claimedAt, updatedAt or claimedAt, holdReq or 300, capturer or "")
end
local function loWire(siteKey, g, fac, claimedAt, capturer)
    return string.format("%s:%s:%s:%d:%d:global:%s", siteKey, g, code(fac), claimedAt, EPOCH, capturer or "")
end
local function locWire(siteKey, g, fac, events)
    local parts = {}
    for _, e in ipairs(events) do parts[#parts + 1] = e[1] .. "=" .. e[2] end
    return string.format("%s:%s:%s:%d:global:%s", siteKey, g, code(fac), EPOCH, table.concat(parts, ","))
end
local function ocWire(siteKey, g, fac, ts, capturer)
    return string.format("%s:%s:%s:%d:global:%s", siteKey, g, code(fac), ts, capturer or "")
end
local function know(name, g, kills)
    lb.kills[name] = kills or 5
    lb.playerInfo[name] = { class = "WARRIOR", faction = "Alliance", level = 30, locale = "enus",
        guild = g or "", guildAt = g and now or 0, guildAuth = g and true or nil }
end
local function count(siteKey, g)
    local row = lb:GetOutpostCaptureCountRow(siteKey, g, "global")
    return row and math.floor(tonumber(row.count) or 0) or 0
end
local function resetWorld()
    OverlordDB.outposts, OverlordDB.outpostTenants, OverlordDB.outpostCaptureCounts = {}, {}, {}
    op:EnsureDB()
end
local function tick(sec) now = now + (sec or 20) end
local function rowsFor(siteKey)
    local found = {}
    for _, row in ipairs(lb:GetSortedOutposts()) do if row.outpostSiteKey == siteKey then found[#found + 1] = row end end
    for _, row in ipairs(lb:GetSortedGuildKeeps()) do if row.keepSiteKey == siteKey then found[#found + 1] = row end end
    return found
end

-- ===== (1) the live attack: forged rows for an invented guild from the channel
resetWorld()
local fake, troll = "EMPIRE HACKS", "Troll Player-Forever"
know("Troll Player", "Real Guild")
local ts = now - 60
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", fake, "Alliance", ts, "Fake Capper"), troll, "CHANNEL")
sync:OnReceiveLeaderboardOutpostCount(locWire("silverpine", fake, "Alliance", { { ts, "Fake Capper" } }), troll, "CHANNEL")
sync:OnReceiveOutpostState(heldWire("silverpine", fake, "Alliance", ts, "Fake Capper"), troll, "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("silverpine", fake, "Alliance", ts, "Fake Capper"), troll, "CHANNEL")
assert(count("silverpine", fake) == 0 and next(OverlordDB.outpostTenants) == nil,
    "a capture announced by someone else than its capturer entered the tables")
assert(op:GetState("silverpine").status == "neutral", "a held state announced by someone else than its capturer entered the map")
assert(#rowsFor("silverpine") == 0, "the forged guild is listed")
-- The attacker's own character, but a guild the ladder does not know for him.
sync:OnReceiveOutpostState(heldWire("silverpine", fake, "Alliance", ts, "Troll Player"), troll, "CHANNEL")
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", fake, "Alliance", ts, "Troll Player"), troll, "CHANNEL")
assert(count("silverpine", fake) == 0 and op:GetState("silverpine").status == "neutral",
    "a capture credited to a guild the capturer is not known to belong to was believed")
-- Names no character can have, and the 1.7.1 wire without a capturer.
sync:OnReceiveOutpostState(heldWire("silverpine", "Real Guild", "Alliance", ts, "TROLL PLAYER"), "TROLL PLAYER-Forever", "CHANNEL")
sync:OnReceiveLeaderboardOutpostTenant(string.format("silverpine:Real Guild:A:%d:%d:global", ts, EPOCH), troll, "CHANNEL")
sync:OnReceiveLeaderboardOutpostCount(string.format("silverpine:Real Guild:A:1:%d:%d:global", ts, EPOCH), troll, "CHANNEL")
sync:OnReceiveOutpostCapture(string.format("silverpine:Real Guild:A:%d:global", ts), troll, "CHANNEL")
-- A routine held copy from someone who never learnt the capturer: refused, counted apart.
sync:OnReceiveOutpostState(heldWire("silverpine", "Real Guild", "Alliance", ts, nil), troll, "CHANNEL")
assert(count("silverpine", "Real Guild") == 0 and op:GetState("silverpine").status == "neutral",
    "a claim without a plausible capturer was believed")
local accepted, refused, _, noCapturer = sync:GetOutpostClaimStats()
assert(accepted == 0 and refused >= 8, "refusals are not counted: " .. tostring(refused))
assert(noCapturer >= 1 and noCapturer < refused, "held copies without a capturer are not told apart: " .. tostring(noCapturer))
print("Outpost claims: forged guild rows (LO, LOC, OP held, OC) refused from the channel, no capturer / wrong guild / impossible name refused")

-- ===== (2) the capturer himself: accepted live, idempotent, named in the table
tick()
local capper = "Capper Tester"
know(capper, "Fortress Guild")
ts = now - 30
sync:OnReceiveOutpostCapture(ocWire("badlands", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
local st = op:GetState("badlands")
assert(st.status == "held" and st.ownerGuild == "Fortress Guild" and st.heldCapturerName == capper,
    "the capturer's own final did not take the keep")
assert(count("badlands", "Fortress Guild") == 1, "the capture was not counted")
assert(OverlordDB.outpostTenants.badlands and OverlordDB.outpostTenants.badlands.capturer == capper,
    "the tenant row does not name the capturer")
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostState(heldWire("badlands", "Fortress Guild", "Alliance", ts, capper, 600), capper .. "-Forever", "CHANNEL")
assert(count("badlands", "Fortress Guild") == 1, "the same capture was counted twice")
-- Anyone may repeat an event we already hold (routine state), never add one.
tick(5)
local _, refusedBefore = sync:GetOutpostClaimStats()
sync:OnReceiveOutpostState(heldWire("badlands", "Fortress Guild", "Alliance", ts, capper, 600), "Observer Tester-Forever", "CHANNEL")
local _, refusedAfter = sync:GetOutpostClaimStats()
assert(st.status == "held" and count("badlands", "Fortress Guild") == 1 and refusedAfter == refusedBefore,
    "a known event repeated by a third party was refused")
sync:OnReceiveOutpostState(heldWire("badlands", "Fortress Guild", "Alliance", ts + 1, capper, 600), "Observer Tester-Forever", "CHANNEL")
assert(count("badlands", "Fortress Guild") == 1, "a third party added an event by changing its time")
local keeps = rowsFor("badlands")
assert(#keeps == 1 and keeps[1].capturer == capper and keeps[1].currentlyHeld, "the keep row does not name its capturer")
-- A character whose guild the ladder does not know yet cannot name one live...
tick()
local second = "Second Tester"
ts = now - 30
sync:OnReceiveOutpostState(heldWire("silverpine", "Night Guild", "Alliance", ts, second), second .. "-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "neutral" and count("silverpine", "Night Guild") == 0,
    "a capturer with no known guild named one live")
-- ... his own guild register (K / GI) makes him heard, no score needed.
lb.playerInfo[second] = { class = "", faction = "Alliance", level = 0, locale = "", guild = "Night Guild", guildAt = now, guildAuth = true }
sync:OnReceiveOutpostState(heldWire("silverpine", "Night Guild", "Alliance", ts, second), second .. "-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "held" and count("silverpine", "Night Guild") == 1,
    "a capturer with a known guild but no score was refused")
-- A known event is not known with the other faction code (the faction belongs to it).
local _, refusedBeforeFlip = sync:GetOutpostClaimStats()
sync:OnReceiveOutpostState(heldWire("silverpine", "Night Guild", "Horde", ts, second), "Observer Tester-Forever", "CHANNEL")
local _, refusedAfterFlip = sync:GetOutpostClaimStats()
assert(refusedAfterFlip == refusedBeforeFlip + 1 and op:GetState("silverpine").ownerFaction == "Alliance",
    "a known event with the other faction was believed")
-- Locally too, a capture without its capturer is not a capture.
assert(not op:CompleteCapture("aeythyr_lodge", "Night Guild", "Alliance", now, "global", true),
    "a capture without a capturer completed")
assert(op:GetState("aeythyr_lodge").status == "neutral")
print("Outpost claims: the capturer himself is believed live (OC, LO, OP held), once per event, and named in the tables")

-- ===== (3) a relayed copy is never the capturer, even under his name
tick()
Overlord.Relay = {
    IsRelayedOrigin = function() return true end, IsTargetedDispatch = function() return false end,
    IsPeer = function() return true end, IsDispatching = function() return true end,
    IsEcho = function() return false end, context = { hops = 1 },
}
ts = now - 30
sync:OnReceiveOutpostState(heldWire("aeythyr_lodge", "Fortress Guild", "Alliance", ts, capper), capper, "BETA")
sync:OnReceiveLeaderboardOutpostTenant(loWire("aeythyr_lodge", "Fortress Guild", "Alliance", ts, capper), capper, "BETA")
sync:OnReceiveOutpostCapture(ocWire("aeythyr_lodge", "Fortress Guild", "Alliance", ts, capper), capper, "BETA")
assert(op:GetState("aeythyr_lodge").status == "neutral" and count("aeythyr_lodge", "Fortress Guild") == 0,
    "a relayed copy written under the capturer's name was believed")
Overlord.Relay = nil
print("Outpost claims: a relayed origin is never the capturer")

-- ===== (4) one capture per hold time per character
tick()
ts = now - 30
sync:OnReceiveOutpostState(heldWire("silverpine", "Night Guild", "Alliance", ts, second), second .. "-Forever", "CHANNEL")
tick()
sync:OnReceiveOutpostState(heldWire("aeythyr_lodge", "Night Guild", "Alliance", ts + 100, second), second .. "-Forever", "CHANNEL")
assert(count("aeythyr_lodge", "Night Guild") == 0, "two captures 100 s apart by one character were believed")
tick(400)
sync:OnReceiveOutpostState(heldWire("aeythyr_lodge", "Night Guild", "Alliance", ts + 400, second), second .. "-Forever", "CHANNEL")
assert(count("aeythyr_lodge", "Night Guild") == 1, "a capture a hold time later was refused")
print("Outpost claims: a character cannot announce two captures within a hold time")

-- ===== (5) catch-up: only a reply we asked for, only ranked capturers of that guild
tick()
resetWorld()
local third, helper = "Third Tester", "Helper Tester-Forever"
know(third, "Fortress Guild")
ts = now - 30
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", ts, third), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 0, "an unrequested whisper carried a capture")
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::T"))
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", ts, third), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 1 and OverlordDB.outpostTenants.badlands.capturer == third,
    "the reply we asked for was refused")
tick(5)
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance",
    { { ts - 700, third }, { ts - 1400, third }, { ts - 2100, "Nobody Tester" } }), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 3, "the signed history of a ranked capturer was not taken: " .. count("badlands", "Fortress Guild"))
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Other Guild", "Alliance", { { ts - 2800, third } }), helper, "WHISPER")
assert(count("badlands", "Other Guild") == 0, "a capture credited to another guild than the capturer's was taken from a reply")
-- A guild register alone (no score row) does not make a capturer ranked.
lb.playerInfo["Ghost Tester"] = { class = "", faction = "Alliance", level = 0, locale = "", guild = "Fortress Guild", guildAt = now, guildAuth = true }
sync:OnReceiveLeaderboardOutpostTenant(loWire("aeythyr_lodge", "Fortress Guild", "Alliance", ts - 50, "Ghost Tester"), helper, "WHISPER")
assert(count("aeythyr_lodge", "Fortress Guild") == 0, "an unranked capturer was taken from a reply")
-- The live rule does not relax inside the window: a channel copy is still refused.
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", "Fortress Guild", "Alliance", ts - 3500, third), helper, "CHANNEL")
assert(count("silverpine", "Fortress Guild") == 0, "a channel copy was believed because its sender was asked by whisper")
tick(121)
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", "Fortress Guild", "Alliance", ts - 3500, third), helper, "WHISPER")
assert(count("silverpine", "Fortress Guild") == 0, "the reply window did not close")
print("Outpost claims: catch-up replies accepted from the peer we asked, by content (ranked capturer, same guild), inside the window")

-- ===== (6) the ledger converges whatever the order of arrival
local function replay(order)
    OverlordDB.outpostTenants, OverlordDB.outpostCaptureCounts = {}, {}
    for _, e in ipairs(order) do lb:RecordOutpostCapture("badlands", "Fortress Guild", "Alliance", e[1], "global", e[2]) end
    local row = lb:GetOutpostCaptureCountRow("badlands", "Fortress Guild", "global")
    local tenant = OverlordDB.outpostTenants.badlands
    return row.count .. "|" .. tostring(row.lastCapturer) .. "|" .. tenant.capturer .. "|" .. tenant.claimedAt
end
local a = replay({ { ts, third }, { ts - 700, capper }, { ts - 1400, third } })
local b = replay({ { ts - 1400, third }, { ts, third }, { ts - 700, capper } })
local c = replay({ { ts - 700, capper }, { ts - 1400, third }, { ts, third }, { ts, third } })
assert(a == b and b == c and a == "3|" .. third .. "|" .. third .. "|" .. ts, "order of arrival changed the ledger: " .. a .. " / " .. b .. " / " .. c)
print("Outpost claims: same events, same ledger, whatever the order")

-- ===== (7) replies carry the signed events (LO with capturer, LOC as ts=name)
local queue = {}
sync:AppendLeaderboardOutpostToSrQueue(queue)
assert(#queue == 1 and queue[1].type == "LO" and queue[1].data:find(":" .. third .. "$"), "the tenant reply does not name the capturer")
local realAfter = C_Timer.After
C_Timer.After = function(_, fn) fn() end
lb:EnsureOutpostLedgerPrepared(true)
assert(lb:EnsureOutpostLedgerPrepared(true) == true, "the ledger snapshot was not built")
C_Timer.After = realAfter
queue = {}
sync:AppendLeaderboardOutpostCountToSrQueue(queue, 0, false)
assert(#queue == 1 and queue[1].type == "LOC", "one LOC packet expected, got " .. #queue)
local events = 0
for _ in queue[1].data:gmatch("%d+=[^,]+") do events = events + 1 end
assert(events == 3 and queue[1].data:find(tostring(ts) .. "=" .. third, 1, true), "LOC does not list the signed events: " .. queue[1].data)
-- A fresh client that asked this peer takes the whole row from that one packet.
local packet = queue[1].data
resetWorld()
tick(5)
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(packet, helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 3, "the history packet was not taken by the client that asked")
print("Outpost claims: SR replies carry the capturer of every event")

-- ===== (8) saved rows of the release week are dropped once (none names its capturer)
local cutoff = lb.OUTPOST_CLAIM_MIN_TS
local oldState = { status = "held", ownerGuild = fake, ownerFaction = "Alliance", claimedAt = cutoff - 3600,
    updatedAt = cutoff - 3600, heldCapturerName = "Fake Capper", holdTimeRequired = 300, pool = "global" }
OverlordDB.outposts.silverpine = oldState
OverlordDB.outpostTenants = { silverpine = { guild = fake, guildKey = fake:lower(), faction = "Alliance", claimedAt = cutoff - 3600, pool = "global" },
    badlands = OverlordDB.outpostTenants.badlands }
OverlordDB.outpostCaptureCounts["silverpine:global:" .. fake:lower()] = { siteKey = "silverpine", guild = fake, guildKey = fake:lower(),
    faction = "Alliance", count = 7, events = { [tostring(cutoff - 3600)] = true }, locAnchors = { ["7"] = cutoff - 3600 }, pool = "global" }
OverlordDB.worldsByPool = { pve = { epoch = EPOCH, outposts = { badlands = { status = "held", ownerGuild = fake, ownerFaction = "Horde", claimedAt = cutoff - 10, updatedAt = cutoff - 10 } },
    outpostTenants = { badlands = { guild = fake, faction = "Horde", claimedAt = cutoff - 10, pool = "pve" } },
    outpostCaptureCounts = { ["badlands:pve:" .. fake:lower()] = { siteKey = "badlands", guild = fake, count = 2, events = { [tostring(cutoff - 10)] = true } } } } }
OverlordDB.outpostCapturerLedgerVersion = nil
assert(lb:EnsureOutpostCapturerLedger() == true, "the one-shot purge did not run")
assert(OverlordDB.outposts.silverpine.status == "neutral" and (OverlordDB.outposts.silverpine.ownerGuild or "") == ""
    and OverlordDB.outposts.silverpine.heldCapturerName == nil, "a held state of the release week survived")
assert(OverlordDB.outpostTenants.silverpine == nil and OverlordDB.outpostCaptureCounts["silverpine:global:" .. fake:lower()] == nil,
    "unsigned rows survived the purge")
assert(OverlordDB.outpostTenants.badlands and OverlordDB.outpostTenants.badlands.capturer == third
    and count("badlands", "Fortress Guild") == 3, "signed rows were purged")
local parked = OverlordDB.worldsByPool.pve
assert(parked.outposts.badlands.status == "neutral" and next(parked.outpostTenants) == nil and next(parked.outpostCaptureCounts) == nil,
    "the parked world kept its unsigned rows")
assert(OverlordDB.outpostCapturerLedgerVersion == 1 and lb:EnsureOutpostCapturerLedger() == false, "the purge is not one-shot")
-- A state of an older week is not touched (the fixture itself is weeks before the cut-off).
OverlordDB.outposts.badlands = { status = "held", ownerGuild = "Fortress Guild", ownerFaction = "Alliance", claimedAt = ts, updatedAt = ts, heldCapturerName = third }
OverlordDB.outpostCapturerLedgerVersion = nil
lb:EnsureOutpostCapturerLedger()
assert(OverlordDB.outposts.badlands.status == "held", "a state outside the release week was purged")
OverlordDB.worldsByPool = nil
-- On the wire, a claim of the release week is refused by everyone alike.
know("Fourth Tester", "Fortress Guild")
local ok, why = sync:AuthorizeOutpostClaim("silverpine", "Fortress Guild", "Alliance", cutoff - 10, "Fourth Tester", "Fourth Tester-Forever", "CHANNEL", "global")
assert(ok == false and why == "stale", "a release-week claim was believed: " .. tostring(why))
ok, why = sync:AuthorizeOutpostClaim("silverpine", "Fortress Guild", "Alliance", now - 10, "Fourth Tester", "Fourth Tester-Forever", "CHANNEL", "global")
assert(ok == true and why == "owner", "a claim from before the release week was refused: " .. tostring(why))
print("Outpost claims: release-week rows and states purged once, old claims refused on the wire")

-- ===== (9) a stale enemy assault is probed a few times, not forever
resetWorld()
local stale = op:GetState("silverpine")
stale.status, stale.ownerGuild, stale.ownerFaction = "in_progress", "Horde Guild", "Horde"
stale.holdTimeElapsed, stale.holdTimeRequired, stale.updatedAt, stale.pool = 10, 300, now - 1000, "global"
local polls = 0
local realPoll = sync.PollIfStaleObserverOutpost
sync.PollIfStaleObserverOutpost = function() polls = polls + 1; return true end
for _ = 1, 12 do op:TickMaintenance(); tick(30) end
assert(polls == 2, "a stale assault was probed " .. polls .. " times")
stale.updatedAt = now
op:TickMaintenance()
stale.updatedAt = now - 1000
tick(30)
op:TickMaintenance()
assert(polls == 2, "a heartbeat of the same assault re-armed the probes")
sync.PollIfStaleObserverOutpost = realPoll
print("Outpost claims: stale assault probes bounded to two per episode")
-- ===== (10) the time of a capture is its identity, even from a clock running ahead
resetWorld()
tick()
local fast = "Fast Tester"
know(fast, "Fortress Guild")
ts = now + 30
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, fast), fast .. "-Forever", "CHANNEL")
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", "Fortress Guild", "Alliance", ts, fast), fast .. "-Forever", "CHANNEL")
tick(11)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, fast), fast .. "-Forever", "CHANNEL")
tick(11)
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("silverpine", "Fortress Guild", "Alliance", { { ts, fast } }), helper, "WHISPER")
local fastRow = lb:GetOutpostCaptureCountRow("silverpine", "Fortress Guild", "global")
assert(fastRow and fastRow.count == 1 and fastRow.events[tostring(ts)] == fast,
    "a capture dated 30 s ahead was split or re-dated: " .. tostring(fastRow and fastRow.count))
assert(OverlordDB.outpostTenants.silverpine.claimedAt == ts, "the claim time was rewritten to the local clock")
assert(op:GetState("silverpine").claimedAt <= now + 5 and op:GetState("silverpine").claimedAt < ts,
    "the map ran ahead of the clock: " .. tostring(op:GetState("silverpine").claimedAt - now))
assert(sync:AuthorizeOutpostClaim("silverpine", "Fortress Guild", "Alliance", now + 301, fast, fast .. "-Forever", "CHANNEL", "global") == false,
    "a claim beyond the clock skew was believed")
print("Outpost claims: the written time is the event, never the local clock")

-- ===== (11) the pace follows the shortest contract (gold reduction)
tick()
local gold = "Gold Tester"
know(gold, "Gold Guild")
ts = now - 300
sync:OnReceiveOutpostState(heldWire("badlands", "Gold Guild", "Alliance", ts, gold, 600), gold .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostState(heldWire("silverpine", "Gold Guild", "Alliance", ts + 100, gold), gold .. "-Forever", "CHANNEL")
assert(count("silverpine", "Gold Guild") == 0, "two captures 100 s apart were believed")
sync:OnReceiveOutpostState(heldWire("silverpine", "Gold Guild", "Alliance", ts + 250, gold), gold .. "-Forever", "CHANNEL")
assert(count("silverpine", "Gold Guild") == 1, "a capture at the reduced contract (240 s) was refused")
print("Outpost claims: pace measured on the shortest contract")

-- ===== (12) the faction the transport proves, and the one the ladder knows
local okf, whyf = sync:AuthorizeOutpostClaim("aeythyr_lodge", "Horde Guild", "Horde", now - 10, "Horde Tester", "Horde Tester-Forever", "CHANNEL", "global")
assert(okf == false and whyf == "owner-faction", "a channel sender claimed a capture of the other faction: " .. tostring(whyf))
know("Red Tester", "Red Guild")
lb.playerInfo["Red Tester"].faction = "Horde"
okf, whyf = sync:AuthorizeOutpostClaim("aeythyr_lodge", "Red Guild", "Alliance", now - 10, "Red Tester", "Red Tester-Forever", "CHANNEL", "global")
assert(okf == false and whyf == "capturer-faction", "a Horde capturer was credited to an Alliance capture: " .. tostring(whyf))
print("Outpost claims: faction checked against the transport and the ladder")

-- ===== (13) defenders are warned even when the assailant does not know the tenant
resetWorld()
tick()
Overlord.L.OUTPOST_DEFENDER_UNDER_ATTACK = "%s: UNDER ATTACK (%s)"
Overlord.L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "%s: UNDER ATTACK by %s (%s)"
assert(op:CompleteCapture("silverpine", guild, "Alliance", now - 100, "global", true, capper), "fixture capture refused")
local warned = 0
Overlord.PrintNotification = function(_, text) if type(text) == "string" and text:find("UNDER ATTACK", 1, true) then warned = warned + 1 end end
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(warned == 1, "an assault naming no previous tenant did not warn the defenders: " .. warned)
Overlord.PrintNotification = function() end
print("Outpost claims: defender alert without the previous tenant in the assault")

-- ===== (14) a reply we asked for has a budget of events
resetWorld()
tick()
know(third, "Fortress Guild")
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
local base = now - 60
for packet = 0, 80 do
    local events = {}
    -- Spaced by the keep contract (the pace by content applies to replies too).
    for i = 1, 6 do events[#events + 1] = { base - (packet * 6 + i) * 540, third } end
    sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance", events), helper, "WHISPER")
end
assert(count("badlands", "Fortress Guild") == 480, "the reply budget was not applied: " .. count("badlands", "Fortress Guild"))
-- Another request right away extends the window but does not refill the budget...
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance", { { base - 490 * 540, third } }), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 480, "a second request refilled the budget at once")
-- ... a minute later it does.
tick(61)
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance", { { base - 491 * 540, third } }), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 481, "the budget was not refilled after a minute")
print("Outpost claims: at most 480 events judged per reply window")

-- ===== (15) long histories are served in slices, whole rows never starve
resetWorld()
tick()
for i = 1, 20 do lb:RecordOutpostCapture("badlands", "Fortress Guild", "Alliance", base - i * 100, "global", third) end
lb:RecordOutpostCapture("silverpine", "Night Guild", "Alliance", base - 50, "global", second)
C_Timer.After = function(_, fn) fn() end
lb:EnsureOutpostLedgerPrepared(true)
assert(lb:EnsureOutpostLedgerPrepared(true) == true)
C_Timer.After = realAfter
local seen = {}
for _, nonce in ipairs({ 0, 16, 32 }) do
    queue = {}
    sync:AppendLeaderboardOutpostCountToSrQueue(queue, nonce, true)
    local badlandsPackets = 0
    for _, item in ipairs(queue) do
        if item.data:find("^badlands:") then
            badlandsPackets = badlandsPackets + 1
            for eventTs in item.data:gmatch("(%d+)=") do seen[eventTs] = true end
        end
    end
    assert(badlandsPackets == 3, "a long row took " .. badlandsPackets .. " packets of one reply")
    assert(#queue == 4, "the other row was starved: " .. #queue)
end
local covered = 0
for _ in pairs(seen) do covered = covered + 1 end
assert(covered == 20, "successive replies did not cover the whole history: " .. covered)
print("Outpost claims: long histories sliced across replies")

-- ===== (16) a stale assault pulls one direct neighbour of the other faction first
local requests = {}
local realSendSync = sync.SendSyncRequest
sync.SendSyncRequest = function(_, opts) requests[#requests + 1] = opts; return true end
local realPeerFaction = sync.GetBetaPeerFaction
sync.GetBetaPeerFaction = function(_, name) return name == "Enemy Peer" and "Horde" or "Alliance" end
Overlord.Relay = { GetDirectPeers = function() return { "Ally Peer", "Enemy Peer" } end,
    IsRelayedOrigin = function() return false end, IsTargetedDispatch = function() return false end,
    IsPeer = function() return false end, IsDispatching = function() return false end, IsEcho = function() return false end }
tick(100)
assert(sync:PollIfStaleObserverOutpost(999, true) == true, "the probe was not sent")
assert(#requests == 1 and requests[1].betaTarget == "Enemy Peer",
    "the stale probe did not pull the enemy neighbour alone (no broadcast herd)")
-- A pull the relay refuses is not a spent probe (and is not replaced by a broadcast).
sync.SendSyncRequest = function(_, opts) requests[#requests + 1] = opts; return false end
requests = {}
tick(100)
assert(sync:PollIfStaleObserverOutpost(999, true) == false and #requests == 1 and requests[1].betaTarget,
    "a refused stale pull counted as a probe or fell back to a broadcast")
sync.SendSyncRequest = function(_, opts) requests[#requests + 1] = opts; return true end
-- Without any direct neighbour, the broadcast request is the fallback.
Overlord.Relay.GetDirectPeers = function() return {} end
requests = {}
tick(100)
assert(sync:PollIfStaleObserverOutpost(999, true) == true and #requests == 1 and requests[1].criticalChannel,
    "without a neighbour the stale probe sent no broadcast")
-- Callers without a pull (defence check, login snapshot) keep the broadcast.
requests = {}
tick(100)
assert(sync:PollIfStaleObserverOutpost(999) == true and #requests == 1 and requests[1].criticalChannel,
    "a probe without a pull lost its broadcast")
Overlord.Relay = nil
sync.SendSyncRequest, sync.GetBetaPeerFaction = realSendSync, realPeerFaction
print("Outpost claims: a stale assault probe pulls a direct neighbour, broadcast only without one")

-- ===== (17) the weekly reset rebuilds the LOC snapshot; a waiting site keeps the periodic pull
lb._outpostLedgerDirty = false
op:ResetOutpostsForCampaign()
assert(lb._outpostLedgerDirty == true, "the weekly reset left the past week in the LOC snapshot")
assert(not op:HasStateAwaitingNetwork(), "a fresh world waits for the network")
local waiting = op:GetState("silverpine")
waiting.status, waiting.ownerGuild, waiting.ownerFaction, waiting.updatedAt = "in_progress", "Horde Guild", "Horde", now
assert(not op:HasStateAwaitingNetwork(), "an observed assault keeps the periodic pull (its end is probed)")
waiting.status, waiting.ownerGuild, waiting.ownerFaction, waiting._loginSyncUnconfirmed = "held", "Horde Guild", "Horde", true
assert(op:HasStateAwaitingNetwork(), "a held site waiting for its snapshot does not keep the periodic pull")
waiting._loginSyncUnconfirmed = nil
print("Outpost claims: weekly reset and periodic pull keep the ledger fresh")

-- ===== (18) the outpost history round is confirmed by an accepted row only
resetWorld()
tick()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function sync:GetChannelId() return 5 end
local acks = 0
sync.NoteOutpostHistoryDelivery = function() acks = acks + 1; return true end
lb.playerInfo["Ghost Tester"] = { class = "", faction = "Alliance", level = 0, locale = "", guild = "Fortress Guild", guildAt = now, guildAuth = true }
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnAddonMessage("OverlordF", "LO:" .. loWire("badlands", "Fortress Guild", "Alliance", now - 30, "Ghost Tester"), "WHISPER", helper)
assert(acks == 0, "a refused history row confirmed the round")
sync:OnAddonMessage("OverlordF", "LO:" .. loWire("badlands", "Fortress Guild", "Alliance", now - 30, third), "WHISPER", helper)
assert(acks == 1 and count("badlands", "Fortress Guild") == 1, "an accepted history row did not confirm the round: " .. acks)
sync.NoteOutpostHistoryDelivery = nil
print("Outpost claims: history round confirmed by accepted rows only")
-- ===== (19) a character announces at most a game hour of captures, backdated or not
tick()
local budgetAccepted = 0
know("Budget Tester", "Budget Guild")
for i = 0, 24 do
    local okb = sync:AuthorizeOutpostClaim("silverpine", "Budget Guild", "Alliance", now - 10 - i * 300, "Budget Tester", "Budget Tester-Forever", "CHANNEL", "global")
    if okb then budgetAccepted = budgetAccepted + 1 end
end
assert(budgetAccepted == 16, "backdated claims escaped the hourly budget: " .. budgetAccepted)
print("Outpost claims: hourly budget per character holds against backdated claims")
-- ===== (20) the ledger itself is bounded (rows of invented guilds)
resetWorld()
lb:ResetOutpostLedgerCounters()
local created = 0
for i = 1, 4100 do
    if lb:RecordOutpostCapture("badlands", "Guild " .. i, "Alliance", now - 50000 - i, "global", third) then created = created + 1 end
end
assert(created == 4096, "the ledger accepted " .. created .. " rows")
assert(lb:RecordOutpostCapture("badlands", "Guild 1", "Alliance", now - 100, "global", third), "an existing row refused a new event")
resetWorld()
lb:ResetOutpostLedgerCounters()
print("Outpost claims: ledger rows bounded")
-- ===== (21) one spelling of the capturer everywhere (map and ledger agree)
resetWorld()
tick()
ts = now - 30
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper .. "-Forever"), capper .. "-Forever", "CHANNEL")
local spelled = lb:GetOutpostCaptureCountRow("silverpine", "Fortress Guild", "global")
assert(spelled and spelled.count == 1 and spelled.events[tostring(ts)] == capper, "the realm suffix reached the ledger")
assert(op:GetState("silverpine").heldCapturerName == capper, "the realm suffix reached the map")
assert(OverlordDB.outpostTenants.silverpine.capturer == capper, "the realm suffix reached the tenant")
-- A time that is not a number is not a capture, even from the capturer.
sync:OnReceiveOutpostCapture("silverpine:Fortress Guild:A:nan:global:" .. capper, capper .. "-Forever", "CHANNEL")
assert(spelled.count == 1 and op:GetState("silverpine").claimedAt == ts, "a NaN time was believed")
print("Outpost claims: capturer spelled the same in map, tenant and ledger")
-- ===== (22) one character, one second: a burst over several sites or guilds is one capture
resetWorld()
tick()
local burst = "Burst Tester"
know(burst, "Burst Guild")
ts = now - 30
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Burst Guild", "Alliance", ts, burst), burst .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("badlands", "Burst Guild", "Alliance", ts, burst), burst .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("aeythyr_lodge", "Burst Guild", "Alliance", ts, burst), burst .. "-Forever", "CHANNEL")
assert(count("silverpine", "Burst Guild") + count("badlands", "Burst Guild") + count("aeythyr_lodge", "Burst Guild") == 1,
    "a same-second burst over several sites was counted")
sync:OnReceiveOutpostState(heldWire("badlands", "Other Guild", "Alliance", ts, burst, 600), burst .. "-Forever", "CHANNEL")
assert(count("badlands", "Other Guild") == 0, "a same-second claim for another guild was believed")
print("Outpost claims: one second, one capture, whatever the site or the guild")

-- ===== (23) a reply we asked for obeys the pace by content too
resetWorld()
tick()
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance",
    { { ts, third }, { ts - 10, third }, { ts - 20, third }, { ts - 30, third }, { ts - 40, third }, { ts - 50, third } }), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 1, "six captures 10 s apart were taken from a reply: " .. count("badlands", "Fortress Guild"))
tick(5)
sync:OnReceiveLeaderboardOutpostCount(locWire("badlands", "Fortress Guild", "Alliance",
    { { ts - 600, third }, { ts - 1200, third }, { ts - 1800, third } }), helper, "WHISPER")
assert(count("badlands", "Fortress Guild") == 4, "captures a keep contract apart were refused: " .. count("badlands", "Fortress Guild"))
-- The budget of a window refills at most once a minute, not on every request.
local peerRow = nil
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
print("Outpost claims: catch-up replies paced by content")

-- ===== (24) a release never erases a tenant; an assault keeps the tenant we know
resetWorld()
tick(300) -- the capturer of the previous scenarios is paced
know("Horde Attacker", "Horde Guild")
lb.playerInfo["Horde Attacker"].faction = "Horde"
ts = now - 60
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
local held = op:GetState("silverpine")
assert(held.status == "held" and held.ownerGuild == "Fortress Guild", "fixture capture refused")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Troll Player-Forever", "CHANNEL")
assert(held.status == "held" and held.ownerGuild == "Fortress Guild", "a forged release erased a tenant")
-- An enemy assault that names no tenant keeps ours; its abandon gives the site back.
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(held.status == "in_progress" and held.previousOwnerGuild == "Fortress Guild" and held.previousClaimedAt == ts,
    "the assault lost the tenant we knew")
assert(select(1, op:GetOutpostDisplayTenant(held, "silverpine")) == "Fortress Guild", "the table lost the tenant during the assault")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Horde Attacker-Forever", "CHANNEL")
assert(held.status == "held" and held.ownerGuild == "Fortress Guild" and held.claimedAt == ts and held.heldCapturerName == capper,
    "an abandoned assault did not give the site back to its tenant")
-- The assailant putting the tenant back himself (a held state we cannot authorize) is accepted the same way.
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, capper, nil, now), "Horde Attacker-Forever", "CHANNEL")
assert(held.status == "held" and held.ownerGuild == "Fortress Guild" and held.claimedAt == ts, "the restored tenant was refused")
-- A stale copy of the tenant (older than the assault we hold) never cancels an assault.
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, capper, nil, ts), "Any Peer-Forever", "CHANNEL")
assert(held.status == "in_progress", "a stale copy of the tenant cancelled the assault")
-- A stranger cannot end a live assault, with a fresh release or a fresh copy of the tenant...
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Troll Player-Forever", "CHANNEL")
assert(held.status == "in_progress", "a stranger hid a live assault with a release")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, capper, nil, now), "Troll Player-Forever", "CHANNEL")
assert(held.status == "in_progress", "a stranger hid a live assault with a copy of the tenant")
-- ... but once the assault went quiet, anyone may put the tenant we knew back.
tick(400)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, capper, nil, now), "Any Peer-Forever", "CHANNEL")
assert(held.status == "held" and held.ownerGuild == "Fortress Guild", "a quiet assault kept the tenant away")
-- On a neutral site, an assault may not invent a previous tenant.
resetWorld()
tick(5)
sync:OnReceiveOutpostState(string.format("v1:badlands:in_progress:10:Horde Guild:H:0:0:%d:600:global:0:%s:A:%d:0:Horde Attacker", now, fake, now - 500),
    "Horde Attacker-Forever", "CHANNEL")
local invented = op:GetState("badlands")
assert(invented.status == "in_progress" and (invented.previousOwnerGuild or "") == "", "an assault invented a previous tenant")
assert(#rowsFor("badlands") == 0, "the invented tenant is listed")
print("Outpost claims: releases and assaults never erase or invent a tenant")

-- ===== (25) an event keeps its first capturer
resetWorld()
tick(300) -- the capturer of the previous scenarios is paced
ts = now - 60
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
know("Aaa Thief", "Fortress Guild")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, "Aaa Thief"), "Aaa Thief-Forever", "CHANNEL")
assert(op:GetState("silverpine").heldCapturerName == capper and OverlordDB.outpostTenants.silverpine.capturer == capper
    and lb:GetOutpostCaptureCountRow("silverpine", "Fortress Guild", "global").events[tostring(ts)] == capper,
    "a capture was re-attributed to another character")
print("Outpost claims: an event keeps its first capturer")

-- ===== (26) a claim ahead of the clock never pins the map in the future
resetWorld()
tick()
ts = now + 29
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, fast), fast .. "-Forever", "CHANNEL")
local ahead = op:GetState("silverpine")
assert(count("silverpine", "Fortress Guild") == 1 and ahead.status == "held" and ahead.claimedAt <= now + 5,
    "the map was pinned ahead: " .. tostring(ahead.claimedAt - now))
sync:OnReceiveOutpostCapture(ocWire("badlands", "Fortress Guild", "Alliance", now + 31, fast), fast .. "-Forever", "CHANNEL")
assert(count("badlands", "Fortress Guild") == 0, "a claim further ahead than the shared clock allows was believed")
print("Outpost claims: map time bounded by the clock")

-- ===== (27) a capture the ledger knows but the map lacks keeps the periodic pull
resetWorld()
tick()
lb:RecordOutpostCapture("badlands", "Fortress Guild", "Alliance", now - 100, "global", third)
assert(op:HasStateAwaitingNetwork(), "a held state missing from the map did not keep the periodic pull")
sync:OnReceiveOutpostState(heldWire("badlands", "Fortress Guild", "Alliance", now - 100, third, 600), "Any Peer-Forever", "CHANNEL")
assert(op:GetState("badlands").status == "held", "the known held state was not taken from any peer")
assert(not op:HasStateAwaitingNetwork(), "the map caught up but the pull goes on")
print("Outpost claims: the map follows the ledger through the periodic pull")

-- ===== (28) probes are re-armed by another assault, not by a heartbeat
resetWorld()
tick()
local probeSite = op:GetState("silverpine")
probeSite.status, probeSite.ownerGuild, probeSite.ownerFaction = "in_progress", "Horde Guild", "Horde"
probeSite.holdTimeElapsed, probeSite.holdTimeRequired, probeSite.updatedAt, probeSite.pool = 10, 300, now - 1000, "global"
local probeCalls, probePulls = 0, 0
local realProbe = sync.PollIfStaleObserverOutpost
sync.PollIfStaleObserverOutpost = function(_, _, withPull) probeCalls = probeCalls + 1; if withPull then probePulls = probePulls + 1 end; return true end
for _ = 1, 8 do op:TickMaintenance(); tick(30) end
assert(probeCalls == 2 and probePulls == 2, "probes " .. probeCalls .. ", pulls " .. probePulls)
probeSite.updatedAt = now
op:TickMaintenance()
probeSite.updatedAt = now - 1000
tick(30)
op:TickMaintenance()
assert(probeCalls == 2, "a heartbeat of the same assault re-armed the probes")
probeSite.ownerGuild = "Other Horde Guild"
op:TickMaintenance()
assert(probeCalls == 3, "a new assault did not re-arm the probes")
sync.PollIfStaleObserverOutpost = realProbe
print("Outpost claims: probes re-armed by a new assault only")

-- ===== (29) names no guild can have, on every state
resetWorld()
tick()
local _, refusedBeforeGuild = sync:GetOutpostClaimStats()
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:X\n[GM] hi:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(not (op:GetState("silverpine").ownerGuild or ""):find("\n"), "a line break reached the assault guild")
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", "Real\226\128\139Guild", "Alliance", now - 30, "Troll Player"), troll, "CHANNEL")
assert(count("silverpine", "Real\226\128\139Guild") == 0, "a look-alike guild name with an invisible character was believed")
assert(sync.IsValidGuildSyncToken and not sync:IsValidGuildSyncToken("Real\226\128\139Guild")
    and not sync:IsValidGuildSyncToken("Real\226\128\131Guild") and not sync:IsValidGuildSyncToken("Real Guild\194\160")
    and not sync:IsValidGuildSyncToken("Real\227\128\128Guild") and sync:IsValidGuildSyncToken("Real Guild"),
    "invisible characters pass the guild token")
local okf2, whyf2 = sync:AuthorizeOutpostClaim("silverpine", "Night Guild", "Alliance", now - 30, second, second .. "-Forever", "PARTY", "global")
assert(okf2 == false and whyf2 == "owner-faction", "a sender whose faction nothing proves was believed: " .. tostring(whyf2))
print("Outpost claims: guild names validated on every state, unproven factions refused")

-- ===== (30) the history round is confirmed with its freshness
resetWorld()
tick()
local freshSeen = {}
sync.NoteOutpostHistoryDelivery = function(_, _, fresh) freshSeen[#freshSeen + 1] = fresh == true end
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", now - 30, third), helper, "WHISPER")
tick(13)
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", now - 43, third), helper, "WHISPER")
assert(#freshSeen == 2 and freshSeen[1] == true and freshSeen[2] == false, "freshness of the history reply not reported")
sync.NoteOutpostHistoryDelivery = nil
print("Outpost claims: history round confirmed with its freshness")
-- ===== (31) keep then outpost 300 s later is honest, in both orders of arrival
resetWorld()
tick()
local pairOne, pairTwo = "Pair Tester", "Pair Two"
know(pairOne, "Pair Guild")
know(pairTwo, "Pair Guild")
ts = now - 600
sync:OnReceiveOutpostCapture(ocWire("badlands", "Pair Guild", "Alliance", ts, pairOne), pairOne .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Pair Guild", "Alliance", ts + 300, pairOne), pairOne .. "-Forever", "CHANNEL")
assert(count("badlands", "Pair Guild") == 1 and count("silverpine", "Pair Guild") == 1, "keep then outpost 300 s later refused live")
resetWorld()
tick(5)
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Pair Guild", "Alliance", ts + 300, pairTwo), pairTwo .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("badlands", "Pair Guild", "Alliance", ts, pairTwo), pairTwo .. "-Forever", "CHANNEL")
assert(count("badlands", "Pair Guild") == 1 and count("silverpine", "Pair Guild") == 1,
    "keep then outpost refused when the outpost arrived first: " .. count("badlands", "Pair Guild") .. "/" .. count("silverpine", "Pair Guild"))
-- The same pair as a reply (newest first) to a client that asked.
resetWorld()
tick(5)
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostTenant(loWire("silverpine", "Pair Guild", "Alliance", ts + 300, pairOne), helper, "WHISPER")
sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Pair Guild", "Alliance", ts, pairOne), helper, "WHISPER")
assert(count("badlands", "Pair Guild") == 1 and count("silverpine", "Pair Guild") == 1, "the pair was refused from a newest-first reply")
-- Outpost then keep 300 s later is impossible (the keep takes 540 s at least), in both orders.
resetWorld()
tick(5)
local pairBad = "Pair Bad"
know(pairBad, "Pair Guild")
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Pair Guild", "Alliance", ts, pairBad), pairBad .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("badlands", "Pair Guild", "Alliance", ts + 300, pairBad), pairBad .. "-Forever", "CHANNEL")
assert(count("badlands", "Pair Guild") == 0, "outpost then keep 300 s later was believed")
resetWorld()
tick(5)
local pairBadTwo = "Pair Worse"
know(pairBadTwo, "Pair Guild")
sync:OnReceiveOutpostCapture(ocWire("badlands", "Pair Guild", "Alliance", ts + 300, pairBadTwo), pairBadTwo .. "-Forever", "CHANNEL")
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Pair Guild", "Alliance", ts, pairBadTwo), pairBadTwo .. "-Forever", "CHANNEL")
assert(count("silverpine", "Pair Guild") == 0, "outpost then keep 300 s later was believed when the keep arrived first")
print("Outpost claims: the pace of a pair follows its later capture, whatever the order")

-- ===== (32) a tenant the map refuses for good stops the periodic pull after a few tries
resetWorld()
tick()
lb:RecordOutpostCapture("badlands", "Fortress Guild", "Alliance", now - 100, "global", third)
local kept = 0
for _ = 1, 6 do if op:HasStateAwaitingNetwork() then kept = kept + 1 end end
assert(kept == 4, "the ledger-ahead pull is not bounded: " .. kept)
print("Outpost claims: ledger-ahead pulls bounded")

-- ===== (33) a same-faction retake after a missed enemy capture follows the ledger
resetWorld()
tick(300)
ts = now - 1500 -- far enough from the previous capture of the same character
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
local retaken = op:GetState("silverpine")
assert(retaken.status == "in_progress" and retaken.previousOwnerGuild == "Fortress Guild", "fixture assault not observed")
-- The Horde capture itself is missed live, learned later from a reply; then an
-- Alliance guild takes the site back.
tick(700)
know("Horde Capper", "Horde Guild")
lb.playerInfo["Horde Capper"].faction = "Horde"
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("silverpine", "Horde Guild", "Horde", { { now - 400, "Horde Capper" } }), helper, "WHISPER")
assert(count("silverpine", "Horde Guild") == 1, "the missed enemy capture was not learned from the reply")
local retaker = "Retake Tester"
know(retaker, "Night Guild")
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Night Guild", "Alliance", now - 10, retaker), retaker .. "-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Night Guild", "Alliance", now - 15, retaker, nil, now), retaker .. "-Forever", "CHANNEL")
assert(retaken.status == "held" and retaken.ownerGuild == "Night Guild",
    "the map stayed on a missed enemy capture: " .. tostring(retaken.status) .. " " .. tostring(retaken.ownerGuild))
print("Outpost claims: the map follows the ledger after a missed capture")
-- ===== (34) a same-faction swap of a held site is not adopted without a missed enemy capture
resetWorld()
tick(300)
ts = now - 1500
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
local swapSite = op:GetState("silverpine")
assert(swapSite.status == "held" and swapSite.ownerGuild == "Fortress Guild", "fixture capture refused")
local rival = "Rival One"
know(rival, "Rival Guild")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Rival Guild", "Alliance", ts + 600, rival, nil, now), rival .. "-Forever", "CHANNEL")
assert(swapSite.ownerGuild == "Fortress Guild", "an allied guild swapped a held site by a signed claim")
assert(count("silverpine", "Rival Guild") == 1, "the signed claim left the ledger")
-- With the enemy capture the map missed (known from a reply), the retake is adopted.
local hordeCapper = "Horde Capper"
know(hordeCapper, "Horde Guild")
lb.playerInfo[hordeCapper].faction = "Horde"
tick(5)
assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
sync:OnReceiveLeaderboardOutpostCount(locWire("silverpine", "Horde Guild", "Horde", { { ts + 300, hordeCapper } }), helper, "WHISPER")
assert(count("silverpine", "Horde Guild") == 1, "the missed enemy capture was not taken from the reply")
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Rival Guild", "Alliance", ts + 600, rival, nil, now), "Any Peer-Forever", "CHANNEL")
assert(swapSite.status == "held" and swapSite.ownerGuild == "Rival Guild", "the retake after a missed enemy capture was not adopted")
print("Outpost claims: a swap between allied guilds needs the missed enemy capture")

-- ===== (35) the local final waits for the pace of its own signature
resetWorld()
tick(300)
if not UnitClass then function UnitClass() return "Warrior", "WARRIOR" end end
local me = sync:GetPlayerFullName()
lb:RecordOutpostCapture("silverpine", guild, "Alliance", now - 100, "global", me)
local localSite = op:GetSite("aeythyr_lodge")
local localState = op:GetState("aeythyr_lodge")
localState.status, localState.ownerGuild, localState.ownerFaction, localState.pool = "in_progress", guild, "Alliance", "global"
localState.holdAuthorityLocal, localState.isHolding, localState.holdTimeElapsed, localState.holdTimeRequired = true, true, 300, 300
Overlord.OutpostControl:CompleteCapture("aeythyr_lodge", localState, localSite)
assert(localState.status == "in_progress", "a final signed 100 s after another capture of the same character went out")
tick(300)
Overlord.OutpostControl:CompleteCapture("aeythyr_lodge", localState, localSite)
assert(localState.status == "held" and localState.heldCapturerName == me, "the paced final never completed")
print("Outpost claims: the local final respects the pace of its signature")

-- ===== (36) alerts are re-armed after a restored tenant
resetWorld()
tick(300)
ts = now - 1500
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
local warnedAgain = 0
Overlord.PrintNotification = function(_, text) if type(text) == "string" and text:find("UNDER ATTACK", 1, true) then warnedAgain = warnedAgain + 1 end end
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(warnedAgain == 1, "fixture assault did not warn: " .. warnedAgain)
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Horde Attacker-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "held", "fixture abandon did not restore the tenant")
tick(400)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(warnedAgain == 2, "the defenders were not warned of the next assault: " .. warnedAgain)
-- Same when the assailant ends it by putting the tenant back himself.
tick(5)
sync:OnReceiveOutpostState(heldWire("silverpine", "Fortress Guild", "Alliance", ts, capper, nil, now), "Horde Attacker-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "held", "the assailant's own tenant copy did not end his assault")
tick(400)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
assert(warnedAgain == 3, "the defenders were not warned after a tenant copy: " .. warnedAgain)
Overlord.PrintNotification = function() end
print("Outpost claims: alerts re-armed after a restored tenant")

-- ===== (37) an observer copy naming nobody keeps the assailant we know
resetWorld()
tick(300)
ts = now - 1500
sync:OnReceiveOutpostCapture(ocWire("silverpine", "Fortress Guild", "Alliance", ts, capper), capper .. "-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Horde Guild:H:0:0:%d:300:global:0:::0:0:Horde Attacker", now), "Horde Attacker-Forever", "CHANNEL")
tick(1)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:12:Horde Guild:H:0:0:%d:300:global:0:::0:0:", now), "Observer Tester-Forever", "CHANNEL")
assert(op:GetState("silverpine").opRelayCapturerName == "Horde Attacker", "an observer copy erased the assailant")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Horde Attacker-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "held", "the assailant could not end his assault after an observer copy")
-- A stranger naming himself assailant of another guild ends nothing.
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:in_progress:10:Other Horde:H:0:0:%d:300:global:0:::0:0:Troll Player", now), "Troll Player-Forever", "CHANNEL")
tick(5)
sync:OnReceiveOutpostState(string.format("v1:silverpine:neutral:0:::0:0:%d:300:global:0", now), "Troll Player-Forever", "CHANNEL")
assert(op:GetState("silverpine").status == "in_progress", "a stranger naming himself assailant hid an assault")
print("Outpost claims: the assailant we know is kept, a self-named stranger is not one")

-- ===== (38) a guild name cut by the byte limit stays a valid name
local cyrillic = "a" .. string.rep("\208\177", 12)
local cut = op:SanitizeGuildName(cyrillic)
assert(#cut <= 24 and #cut >= 20, "the cut name has an odd length: " .. #cut)
assert(sync:IsValidGuildSyncToken(cut), "a guild name cut in the middle of a character is refused: " .. #cut)
print("Outpost claims: byte-limited guild names stay valid")

-- ===== (39) a history reply that moves the ledger past the map moves the map too
do
    local function hordeHeld(site, at)
        local st = op:GetState(site)
        st.status, st.ownerGuild, st.ownerFaction, st.claimedAt, st.updatedAt = "held", "Horde Guild", "Horde", at, at
        st.holdAuthorityLocal, st.isHolding = false, false
        return st
    end
    local follower = "Follow Tester"
    know(follower, "Fortress Guild")
    -- (a) LO caught up: an Alliance capture newer than the Horde tenant the map shows.
    resetWorld()
    tick(4000)
    local st = hordeHeld("badlands", now - 3000)
    assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
    sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", now - 100, follower), helper, "WHISPER")
    assert(count("badlands", "Fortress Guild") == 1, "fixture: the caught-up capture was refused")
    assert(st.status == "held" and st.ownerGuild == "Fortress Guild" and st.ownerFaction == "Alliance"
        and st.claimedAt == now - 100 and st.heldCapturerName == follower,
        "the map kept the old tenant after a caught-up capture: " .. tostring(st.ownerGuild))
    assert(not op:HasStateAwaitingNetwork(), "the map follows the ledger yet still pulls")
    -- (b) Same as (a) through LOC.
    resetWorld()
    tick(4000)
    st = hordeHeld("silverpine", now - 3000)
    assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
    sync:OnReceiveLeaderboardOutpostCount(locWire("silverpine", "Fortress Guild", "Alliance", { { now - 100, follower } }), helper, "WHISPER")
    assert(st.ownerGuild == "Fortress Guild" and st.claimedAt == now - 100, "a caught-up LOC did not move the map")
    -- (c) An allied swap without a missed enemy capture is not adopted.
    resetWorld()
    tick(4000)
    st = hordeHeld("badlands", now - 3000)
    st.ownerGuild, st.ownerFaction = "Old Guild", "Alliance"
    assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
    sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", now - 100, follower), helper, "WHISPER")
    assert(st.ownerGuild == "Old Guild", "an allied swap was adopted without a missed enemy capture")
    -- (d) A local capture and (e) a live assault on the map are left alone.
    for _, case in ipairs({ "local", "assault" }) do
        resetWorld()
        tick(4000)
        st = hordeHeld("badlands", now - 3000)
        if case == "local" then
            st.holdAuthorityLocal, st.isHolding = true, true
        else
            st.status, st.previousOwnerGuild, st.previousOwnerFaction, st.previousClaimedAt = "in_progress", "Horde Guild", "Horde", now - 3000
            st.ownerGuild, st.ownerFaction, st.claimedAt = "Assault Guild", "Alliance", 0
        end
        assert(sync:NoteOutpostClaimPeer("Helper Tester", "A:1.7.2:0::H"))
        sync:OnReceiveLeaderboardOutpostTenant(loWire("badlands", "Fortress Guild", "Alliance", now - 100, follower), helper, "WHISPER")
        assert(count("badlands", "Fortress Guild") == 1, "fixture: the caught-up capture was refused (" .. case .. ")")
        assert(st.ownerGuild ~= "Fortress Guild", "a caught-up capture overrode the map during a " .. case .. " capture")
    end
end
print("Outpost claims: a caught-up capture moves the map, never over a local capture or a live assault")
-- ===== (40) keep/outpost stamps for the map pulls (1.8.2): what a reply of ours
-- states with its capturer, and what our own map already holds
do
    tick(6) -- (stamps cached 5 s)
    local served0, known0 = sync:GetOutpostMapStamps()
    local st = op:GetState("silverpine")
    local saved = {}
    for k, v in pairs(st) do saved[k] = v end
    local newest = math.max(known0, now) + 1000
    st.status, st.ownerGuild, st.ownerFaction, st.claimedAt, st.updatedAt = "held", "Stamp Guild", "Alliance", newest, newest
    st.heldCapturerName, st.heldCapturerGuild, st._loginSyncUnconfirmed = nil, nil, nil
    local cachedServed, cachedKnown = sync:GetOutpostMapStamps()
    assert(cachedServed == served0 and cachedKnown == known0, "the stamps are rebuilt on every presence")
    tick(6)
    local served, known = sync:GetOutpostMapStamps()
    assert(known == newest, "a held site is not in our own stamp: " .. tostring(known))
    assert(served < newest, "a held site without its capturer is advertised (no reply could state it)")
    st.heldCapturerName, st.heldCapturerGuild = "Capper Tester", "Stamp Guild"
    tick(6)
    served, known = sync:GetOutpostMapStamps()
    assert(served == newest and known == newest, "a held site with its capturer is not advertised")
    -- A site still waiting for its login snapshot is neither served nor known.
    st._loginSyncUnconfirmed = true
    tick(6)
    served, known = sync:GetOutpostMapStamps()
    assert(served < newest and known < newest, "an unconfirmed login state is advertised")
    st._loginSyncUnconfirmed = nil
    -- Under assault: the besieged tenant is still what we know, but no reply states it.
    st.status, st.previousOwnerGuild, st.previousOwnerFaction, st.previousClaimedAt = "in_progress", "Stamp Guild", "Alliance", newest
    st.ownerGuild, st.ownerFaction, st.claimedAt = "Assault Guild", "Horde", 0
    tick(6)
    served, known = sync:GetOutpostMapStamps()
    assert(known == newest and served < newest, "an observed assault hid its tenant from our stamp, or advertised it")
    for k in pairs(st) do st[k] = nil end
    for k, v in pairs(saved) do st[k] = v end
    tick(6)
end
print("Outpost claims: keep/outpost stamps (served with capturer, known with the besieged tenant)")
-- ===== Ledger catch-up pages: every row past the first 16 sits in the block and
-- sub-page of its key's djb2 hash (the bucketing every client shares), and the
-- build no longer yields once per character of each key.
do
    local letters = "abcdefghijklmnopqrst"
    local stamp = EPOCH + 3600
    for i = 0, 99 do
        local first, second = math.floor(i / 20) + 1, i % 20 + 1
        local g = "Longnamed Guild " .. letters:sub(first, first) .. letters:sub(second, second)
        lb:RecordOutpostCapture("badlands", g, "Alliance", stamp + i, "global", third)
        lb:RecordOutpostCapture("silverpine", g, "Alliance", stamp + 200 + i, "global", third)
    end
    local slices = 0
    local realAfterTimer = C_Timer.After
    C_Timer.After = function(_, fn) slices = slices + 1; fn() end
    lb._outpostLedgerPrepared = false
    lb:EnsureOutpostLedgerPrepared(true)
    assert(lb:EnsureOutpostLedgerPrepared(true) == true, "the ledger snapshot was not rebuilt")
    C_Timer.After = realAfterTimer
    local snap = assert(lb._outpostSyncSnapshot, "no ledger snapshot")
    local function djb2(v)
        local h = 5381
        for i = 1, #v do h = (h * 33 + v:byte(i)) % 2147483647 end
        return h
    end
    local checked, keyBytes = 0, 0
    for i, row in ipairs(snap.rows) do
        if i > 16 then
            local h = djb2(row._syncKey)
            local b, sp = math.floor((h % 256) / 16) + 1, math.floor((h % 4096) / 256) % 16 + 1
            local inBlock, inPage = false, false
            for _, r in ipairs(snap.blocks[b]) do if r == row then inBlock = true end end
            for _, r in ipairs(snap.subPages[b][sp]) do if r == row then inPage = true end end
            assert(inBlock and inPage, "a ledger row left its hash bucket: " .. row._syncKey)
            checked, keyBytes = checked + 1, keyBytes + #row._syncKey
        end
    end
    assert(checked >= 20, "fixture: too few ledger rows past the first 16: " .. checked)
    -- Hashing alone used to cost 2 yields per key byte (64 per slice).
    assert(slices < keyBytes / 32, "the ledger build still yields inside key hashing: " .. slices .. " slices for "
        .. keyBytes .. " key bytes")
end
print("Forever outpost capturer claims: forged rows refused, capturer believed live, catch-up by content, convergent ledger, purge, bounded probes, ledger buckets")
