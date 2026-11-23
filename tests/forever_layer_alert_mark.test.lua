-- 2.7.0 (Layers OL): the code a capture alert prints is the one the capture's own line carried
-- for its capturer, on every client, and never a lookup by name (the last word heard about a
-- player differs from client to client and may be minutes old). Real relay dispatch -> capture
-- handler -> chat, as in forever_enemy_live_alerts.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("ZoneCaptureLease.lua"))()
local sync, net = Overlord.Sync, Overlord.Relay
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
local L = Overlord.L
L.SYNC_CAPTURED_ENEMY_BY = "%s captured by %s (%s)"
L.SYNC_CAPTURED_ENEMY = "%s captured by %s"
L.SHARD_ALERT_NAME_TAG = ", layer #%s"
L.SHARD_ALERT_NAME_TAG_OURS = ", layer #%s (yours)"
local shard = Overlord.Shard
assert(shard and shard.ValidMark and shard.DisplayCode, "fixture: the real layer module is not loaded")

local zones = {}
for _, id in ipairs({ "loch_valley_of_kings", "loch_stonewrought_dam", "loch_farstrider_lodge", "loch_ironband", "loch_algaz_post" }) do
    zones[id] = { id = id, name = id, owner = "Alliance", status = "captured",
        capturedTime = time() - 300, holdTimeRequired = 120 }
end
Overlord.ZoneDatabase = {}
for _, zone in pairs(zones) do Overlord.ZoneDatabase[#Overlord.ZoneDatabase + 1] = zone end
Overlord.Fronts.GetZone = function(_, id)
    if zones[id] then return zones[id], { id = "loch_modan", mapName = "Loch Modan" } end
end
Overlord.Zones.GetZone = function(_, id) return zones[id] end
Overlord.Zones.GetEnemyFaction = function() return "Horde" end
Overlord.Zones.GetEnemyFactionName = function() return "Horde" end
Overlord.Zones.GetFactionName = function() return "Alliance" end
Overlord.Zones.IsOnVictoryCooldown = function() return false end
local messages = {}
Overlord.PrintNotification = function(_, message) messages[#messages + 1] = message end
local serial = 0
local function capture(zoneId, who)
    serial = serial + 1
    local payload = table.concat({ zoneId, who .. "|WARRIOR", "Horde", time(), "wave" .. serial, "Player-1-ENEMY" .. serial, "120" }, ":")
    local wire = table.concat({ "global", "alert-mark-" .. serial, tostring(time()), "*",
        who .. ",Relay Tester,Bridge Tester", "C", payload }, "|")
    sync:OnBNetMessage("R2:Forever_eu_H:BR:" .. wire, 123)
    assert(not net.stats.lastError, net.stats.lastError)
    assert(zones[zoneId].owner == "Horde", "fixture: the capture did not apply")
end
local p = sync:GetPriv()
assert(type(p.NoteLineMark) == "function" and type(p.AlertMarkFor) == "function", "the alert mark is not kept per point")

-- 1. The capturer's own line says its mark: kept for the point, and known as its own word.
local a, b, c = zones.loch_valley_of_kings, zones.loch_stonewrought_dam, zones.loch_farstrider_lodge
p.NoteLineMark(a.id, "Enemy Tester", 482100137, "Enemy Tester", "BNET")
assert(p.AlertMarkFor(a, "Enemy Tester") == 482100137 and p.AlertMarkFor(a, "Somebody Else") == nil
    and p.AlertMarkFor(b, "Enemy Tester") == nil, "the mark of the capture's line is not kept for its point and its capturer")
assert(shard.saidMarks["Enemy Tester"] == 482100137, "the capturer's own line is not its own word about its mark")

-- 2. A line relayed by a third player: with no mark it changes nothing; it is never that
-- capturer's own word.
p.NoteLineMark(a.id, "Enemy Tester", "", "Ally Relay", "BNET")
assert(p.AlertMarkFor(a, "Enemy Tester") == 482100137, "a relayed line without a mark wiped the capture's code")
p.NoteLineMark(b.id, "Enemy Two", 482200200, "Ally Relay", "BNET")
assert(p.AlertMarkFor(b, "Enemy Two") == 482200200 and shard.saidMarks["Enemy Two"] == nil,
    "a relayed line passes for the capturer's own word")
-- Another capturer takes the wave over, its line without a mark: it never inherits the code.
p.NoteLineMark(b.id, "Enemy Three", "", "Ally Relay", "BNET")
assert(p.AlertMarkFor(b, "Enemy Three") == nil and p.AlertMarkFor(b, "Enemy Two") == nil,
    "a new capturer inherited the code of the one before")

-- 3. Values that are no mark: what the released 2.6.0 still sends, a fraction, a huge number.
for _, junk in ipairs({ 64978, 12.5, 1e30, 0, "abc" }) do
    p.NoteLineMark(c.id, "Enemy Four", junk, "Enemy Four", "BNET")
    assert(p.AlertMarkFor(c, "Enemy Four") == nil, "a value that is no mark was kept: " .. tostring(junk))
end

-- 4. "Captured by": the code of the capture's line, the same text on every client; "(yours)"
-- only when that mark is proven on our layer.
shard.currentShardID = nil
capture(a.id, "Enemy Tester")
assert(#messages == 1 and messages[1]:find("Enemy Tester, layer #OL137", 1, true) and not messages[1]:find("yours", 1, true),
    "the capture alert does not print the code of its line: " .. tostring(messages[1]))
shard.currentShardID = 482200555
p.NoteLineMark(b.id, "Enemy Two", 482200200, "Enemy Two", "BNET")
capture(b.id, "Enemy Two")
assert(#messages == 2 and messages[2]:find("Enemy Two, layer #OL200 (yours)", 1, true),
    "a capture proven on our layer does not say so: " .. tostring(messages[2]))

-- 5. No line carried a mark: no code, whatever was last heard about that player.
shard:SetPlayerShard("Enemy Four", 482300300)
capture(c.id, "Enemy Four")
assert(#messages == 3 and messages[3]:find("Enemy Four", 1, true) and not messages[3]:find("layer", 1, true),
    "an alert printed a code looked up by name: " .. tostring(messages[3]))
assert(sync:GetShardAlertTagForPlayer("Enemy Four") == "", "a layer tag is still looked up by name")

-- 6. The capturer's own line with an empty field: it holds no mark now (it changed layer).
p.NoteLineMark(a.id, "Enemy Tester", "", "Enemy Tester", "BNET")
assert(p.AlertMarkFor(a, "Enemy Tester") == nil and shard.saidMarks["Enemy Tester"] == 0,
    "the capturer's own line without a mark did not clear its code")

-- 6b. An older line of the same capturer, delivered late by a relay, never replaces what a newer
-- one said; and a mark is kept three minutes at most (never for a later capture of the point).
do
    p.NoteLineMark(a.id, "Enemy Tester", 482100137, "Enemy Tester", "BNET", 5000)
    p.NoteLineMark(a.id, "Enemy Tester", 482100999, "Enemy Tester", "BNET", 4000)
    p.NoteLineMark(a.id, "Enemy Tester", "", "Enemy Tester", "BNET", 4500)
    assert(p.AlertMarkFor(a, "Enemy Tester") == 482100137, "an older line replaced the code of a newer one")
    p.NoteLineMark(a.id, "Enemy Tester", 482100555, "Enemy Tester", "BNET", 5005)
    assert(p.AlertMarkFor(a, "Enemy Tester") == 482100555, "a newer line of the capturer was not taken")
    local held = p.alertMarks[a.id]
    held.at = GetTime() - 181
    assert(p.AlertMarkFor(a, "Enemy Tester") == nil, "a code is kept for a later capture of the point")
    held.at = GetTime()
end
-- 6c. (Audit 2026-11-23) What the capturer said himself is never overwritten by somebody else's
-- word: not the code of his capture, nor his name by another capturer's in the next half minute.
-- A line dated ahead of the clock does not hold the slot.
do
    local function serverNow() return Overlord.ServerNow and Overlord.ServerNow() or time() end
    p.alertMarks[c.id] = nil
    p.NoteLineMark(c.id, "Enemy Five", 482500137, "Enemy Five", "BNET", 7000)
    p.NoteLineMark(c.id, "Enemy Five", 482900999, "Forger Relay", "BNET", 7005)
    assert(p.AlertMarkFor(c, "Enemy Five") == 482500137, "a third party rewrote the code the capturer said")
    p.NoteLineMark(c.id, "Somebody Else", 482900999, "Forger Relay", "BNET", 7006)
    assert(p.AlertMarkFor(c, "Enemy Five") == 482500137, "another name from a third party wiped the capturer's code")
    p.alertMarks[c.id].at = GetTime() - 31
    p.NoteLineMark(c.id, "Next Capturer", 482700001, "Ally Relay", "BNET", 7100)
    assert(p.AlertMarkFor(c, "Next Capturer") == 482700001, "a later capture of the point is kept out")
    p.alertMarks[c.id] = nil
    p.NoteLineMark(c.id, "Enemy Six", 482600137, "Ally Relay", "BNET", serverNow() + 100000)
    p.NoteLineMark(c.id, "Enemy Six", 482600555, "Ally Relay", "BNET", serverNow() + 6)
    assert(p.AlertMarkFor(c, "Enemy Six") == 482600555, "a line dated ahead of the clock held the slot")
    p.alertMarks[c.id] = nil
end
-- The final line of a capture never replaces the code its lines carried (a sign of a layer change
-- in its last seconds gives the final another mark, or none): "has been taken" prints the code
-- "is capturing" printed, on every client. With nothing held, the final's own mark is taken.
do
    p.NoteLineMark(a.id, "Enemy Tester", 482100137, "Enemy Tester", "BNET", 6000)
    p.NoteLineMark(a.id, "Enemy Tester", 482100888, "Enemy Tester", "BNET", 6005, true)
    assert(p.AlertMarkFor(a, "Enemy Tester") == 482100137, "a final line replaced the code of the capture's lines")
    p.NoteLineMark(a.id, "Enemy Tester", "", "Enemy Tester", "BNET", 6006, true)
    assert(p.AlertMarkFor(a, "Enemy Tester") == 482100137, "a final line without a mark wiped the code of the capture's lines")
    p.alertMarks[a.id] = nil
    p.NoteLineMark(a.id, "Enemy Tester", 482100888, "Enemy Tester", "BNET", 6010, true)
    assert(p.AlertMarkFor(a, "Enemy Tester") == 482100888, "a final line heard alone does not give its code")
    -- The chance number of a 2.6.0 capturer is no word of his: nothing is written for it.
    local before = shard.saidMarks["Old Capturer"]
    p.NoteLineMark(b.id, "Old Capturer", 31234, "Old Capturer", "BNET", 6020)
    assert(before == nil and shard.saidMarks["Old Capturer"] == nil and shard:GetKnownPlayerShard("Old Capturer") == nil,
        "a row was written for the chance number of a 2.6.0 capturer")
    p.NoteLineMark(b.id, "Old Capturer", "", "Old Capturer", "BNET", 6021)
    assert(shard.saidMarks["Old Capturer"] == 0, "an empty field of the capturer's own line is not its word that it holds no mark")
end
-- The capturer's own final line keeps the mark it carries (it was wiped with the gameplay values
-- of a final, and "has been taken" printed no code on clients that handled it before the C).
do
    local text = (function() local f = assert(io.open("Sync.lua", "rb")); local t = f:read("*a"); f:close(); return t end)()
    assert(text:find("kills, holdTime, remoteSiegePhase, remoteHoldParsed = 0, 0, 0, nil", 1, true)
        and not text:find("remoteHoldParsed, zsCapturerShard = 0, 0, 0, nil, nil", 1, true),
        "a final capture line loses its capturer's mark before the alert reads it")
    assert(text:find("priv.NoteLineMark(zoneId, zsCapturerName, zsCapturerShard, sender, sourceChannel, ts,", 1, true),
        "a capture line is not dated when its mark is noted")
end

-- 6c. The same through the real receive path: the capturer's own final line (ZS "captured"),
-- relayed from the other faction, with no "is capturing" line and no C heard before. The alert
-- prints the code that line carries.
do
    local d = zones.loch_ironband
    shard.currentShardID = nil
    serial = serial + 1
    local payload = table.concat({ d.id, "captured", "0", "0", "H", tostring(time()), "0", "120", "Enemy Six", "482100137",
        "wave" .. serial, "Player-1-ENEMY" .. serial, "120" }, ":")
    local wire = table.concat({ "global", "alert-final-" .. serial, tostring(time()), "*",
        "Enemy Six,Relay Tester,Bridge Tester", "ZS", payload }, "|")
    local before = #messages
    -- ("Capturer spotted", CaptorSpot.lua: the enemy capturer of that line is handed over, once.)
    local spotted = {}
    Overlord.CaptorSpot = { Note = function(_, zoneId, name) spotted[#spotted + 1] = tostring(zoneId) .. "/" .. tostring(name) end }
    sync:OnBNetMessage("R2:Forever_eu_H:BR:" .. wire, 123)
    Overlord.CaptorSpot = nil
    assert(not net.stats.lastError, net.stats.lastError)
    assert(#spotted == 1 and spotted[1] == d.id .. "/Enemy Six", "the enemy capturer of a line is not handed over: " .. table.concat(spotted, " "))
    assert(d.owner == "Horde" and d.status == "captured", "fixture: the final line did not apply")
    assert(#messages == before + 1 and messages[#messages]:find("(Enemy Six, layer #OL137)", 1, true),
        "the final line of a capture printed no code, or another: " .. tostring(messages[#messages]))
    assert(shard.saidMarks["Enemy Six"] == 482100137, "the capturer's final line cleared the word we hold of its mark")
end

-- 7. A word is dated by when it was said: the relay hands over the stamp of its packet.
do
    local saved = net.context
    net.context = nil
    assert(sync:WordSaidAt("BETA") == GetTime() and sync:WordSaidAt("CHANNEL") == GetTime(), "a direct word is not said now")
    net.context = { at = Overlord.ServerNow() - 30 }
    assert(sync:WordSaidAt("BETA") == GetTime() - 30, "a relayed word is not dated by its packet: " .. tostring(sync:WordSaidAt("BETA")))
    assert(sync:WordSaidAt("WHISPER") == GetTime(), "a direct word took the date of a relay packet")
    net.context = { at = Overlord.ServerNow() + 500 }
    assert(sync:WordSaidAt("BETA") == GetTime(), "a packet stamped in the future dates a word after now")
    net.context = saved
end

-- 7b. Only the name itself goes into a capture alert: text a sender wrote after it (a hyphen and
-- anything, within the 50 characters a name may take) is never printed. Through the real receive
-- path, for "has been taken"; the helper for the other printers.
do
    assert(p.NameForChat("Enemy Seven-Buy gold at example dot com") == "Enemy Seven" and p.NameForChat("Enemy Seven") == "Enemy Seven",
        "a name is not cut to the name itself: " .. tostring(p.NameForChat("Enemy Seven-Buy gold at example dot com")))
    assert(p.NameForChat("-only junk") == "" and p.NameForChat("") == "" and p.NameForChat(nil) == nil, "junk passes for a name")
    local e = zones.loch_algaz_post
    shard.currentShardID = nil
    serial = serial + 1
    local payload = table.concat({ e.id, "captured", "0", "0", "H", tostring(time()), "0", "120", "Enemy Seven-Buy gold at example",
        "482100137", "wave" .. serial, "Player-1-ENEMY" .. serial, "120" }, ":")
    local wire = table.concat({ "global", "alert-name-" .. serial, tostring(time()), "*",
        "Enemy Seven,Relay Tester,Bridge Tester", "ZS", payload }, "|")
    local before = #messages
    sync:OnBNetMessage("R2:Forever_eu_H:BR:" .. wire, 123)
    assert(not net.stats.lastError, net.stats.lastError)
    assert(e.owner == "Horde" and e.status == "captured", "fixture: the final line did not apply")
    assert(#messages == before + 1 and messages[#messages]:find("(Enemy Seven, layer #OL137)", 1, true)
        and not messages[#messages]:find("gold", 1, true), "text written after a name reached the capture alert: " .. tostring(messages[#messages]))
    local syncText = assert(io.open("Sync.lua", "rb")):read("*a")
    local _, cuts = syncText:gsub("capturerName = priv%.NameForChat%(capturerName%)", "")
    local _, effective = syncText:gsub("return priv%.NameForChat%(", "")
    assert(cuts == 2 and effective == 2, "a capture alert prints a name as it was sent: " .. cuts .. " " .. effective)
end

-- 8. The wiring, read in the code: the relay hands the stamp over, an SH is dated by it, the SR
-- answer of our own capture names its pinned code, no alert looks a mark up by name.
local function read(path) local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text end
local syncLua, relayLua = read("Sync.lua"), read("SyncRelay.lua")
assert(relayLua:find('session = tostring(p.id or ""):match("^(.-)%-"), at = p.at }', 1, true), "the relay context does not carry the packet's stamp")
assert(syncLua:find("Overlord.Shard:SetPlayerShard(sender, shardID, own, self:WordSaidAt(channel))", 1, true), "an SH is not dated by when it was said")
assert(syncLua:find("priv.NoteLineMark(zoneId, zsCapturerName, zsCapturerShard, sender, sourceChannel, ts,", 1, true), "a capture line does not note its mark")
local _, printers = syncLua:gsub("AppendShardTagToPlayerName%(capturerName, priv%.AlertMarkFor%(zone, capturerName%), true%)", "")
assert(printers == 2, "capture alerts that print the mark of their line: " .. printers)
assert(not syncLua:find("zone and zone.zsRelayCapturerShard, true", 1, true) and not syncLua:find("LearnCapturerShardFromZsSender", 1, true),
    "an alert still reads a mark that is wiped or looked up")
assert(syncLua:find("shardMod.IsMarkPinned and shardMod:IsMarkPinned()", 1, true), "the SR answer of our own capture does not name its code")

print("Layers OL alerts: the code of the capture's own line, same on every client, no lookup by name, words dated when said OK")
