-- 1.8.0: capture and outpost alerts come only from the continent the player is on.
-- 2.3.2: by default only from the zone the player is in (mines too); the option widens them to the
-- continent or the whole world, and our own capital follows the same rule. Always shown: our own
-- guild's outposts (defended, assaulted, taken or lost). An unknown continent or zone (of the place
-- or of the player) shows the alert. A hidden alert marks no dedup state.
-- Sections 1 to 6 run with the continent setting; 6b tests the zone default.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
local guild, faction = "Observer Guild", "Alliance"
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
local sounds = 0
function PlaySound() sounds = sounds + 1 end
GetInstanceInfo = nil

-- Classic map tree: zones under Kalimdor (1414) or the Eastern Kingdoms (1415).
-- (mapType: 0 cosmic, 1 world, 2 continent, 3 zone, 5 micro.)
local maps = {
    [946] = { parentMapID = 0, mapType = 0 },
    [947] = { parentMapID = 946, mapType = 1 },
    [1414] = { parentMapID = 947, mapType = 2 }, -- Kalimdor
    [1415] = { parentMapID = 947, mapType = 2 }, -- Eastern Kingdoms
    [13] = { parentMapID = 947, mapType = 2 }, -- Eastern Kingdoms (Retail id)
    [1439] = { parentMapID = 1414, mapType = 3 }, -- Darkshore
    [1440] = { parentMapID = 1414, mapType = 3 }, -- Ashenvale
    [1442] = { parentMapID = 1414, mapType = 3 }, -- Stonetalon Mountains
    [1411] = { parentMapID = 1414, mapType = 3 }, -- Durotar
    [1412] = { parentMapID = 1414, mapType = 3 }, -- Mulgore
    [1413] = { parentMapID = 1414, mapType = 3 }, -- The Barrens
    [1429] = { parentMapID = 1415, mapType = 3 }, -- Elwynn Forest
    [37] = { parentMapID = 13, mapType = 3 }, -- Elwynn Forest (Retail id)
    [9001] = { parentMapID = 1429, mapType = 5 }, -- a cave in Elwynn
    [1453] = { parentMapID = 1415, mapType = 3 }, -- Stormwind City (its own zone map)
    [1421] = { parentMapID = 1415, mapType = 3 }, -- Silverpine Forest
}
local EK, KALIMDOR = 1429, 1440
local playerMap = EK
C_Map = {
    GetBestMapForUnit = function() return playerMap end,
    GetMapInfo = function(id) return maps[id] end,
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
OverlordDB = { lastResetTimestamp = 1789527600, config = { soundEnabled = true, alertScope = "continent" }, outposts = {} }
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("Outpost.lua"))()
assert(loadfile("GuildKeep.lua"))()
assert(loadfile("OutpostControl.lua"))()
assert(loadfile("SyncStrategicSites.lua"))()
assert(loadfile("SyncOutpost.lua"))()
local op, sync, L = Overlord.Outpost, Overlord.Sync, Overlord.L
for _, method in ipairs({ "Send", "SendToChannel", "BroadcastToRelay" }) do
    sync[method] = function() return true end
end
local addonSounds = 0
Overlord.PlayAddonSound = function() addonSounds = addonSounds + 1 end
L.THE_HORDE, L.THE_ALLIANCE = "the Horde", "the Alliance"
L.ENEMY_CAPTURING_BY, L.ENEMY_CAPTURING = "ATTACK %s %s (%s)", "ATTACK %s %s"
L.SYNC_CAPTURED_ENEMY_BY, L.SYNC_CAPTURED_ENEMY = "TAKEN %s %s (%s)", "TAKEN %s %s"
L.OUTPOST_DEFENDER_UNDER_ATTACK = "DEFEND %s (%s)"
L.OUTPOST_DEFENDER_UNDER_ATTACK_BY = "DEFEND %s %s (%s)"
L.OUTPOST_ALLIED_UNDER_ATTACK = "ALLIED %s %s (%s)"
L.OUTPOST_ENEMY_ASSAULT_VS, L.OUTPOST_ENEMY_ASSAULT = "ASSAULT %s %s %s", "ASSAULT %s %s"
L.OUTPOST_ALLY_ASSAULT_VS, L.OUTPOST_ALLY_ASSAULT = "ASSAULT %s %s %s", "ASSAULT %s %s"
L.OUTPOST_CAPTURE_ALERT_FRIENDLY = "CAPTURED %s %s"
L.OUTPOST_CAPTURE_ALERT_ENEMY = "CAPTURED %s %s (%s)"
local printed = {}
Overlord.PrintNotification = function(_, text) printed[#printed + 1] = text end
local raidWarnings = {}
Overlord.PrintRaidWarning = function(_, text, silent) raidWarnings[#raidWarnings + 1] = { text = text, silent = silent } end
local function take(word)
    local n = 0
    for _, text in ipairs(printed) do
        if not word or text:find(word, 1, true) then n = n + 1 end
    end
    printed = {}
    return n
end

local function upvalue(fn, wanted)
    for index = 1, 255 do
        local key, value = debug.getupvalue(fn, index)
        if key == nil then break end
        if key == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end
local enemyAttack = upvalue(sync.OnReceiveZoneState, "TryPrintEnemyCapturingAlert")
local captureChat = upvalue(sync.OnReceiveZoneState, "PrintCaptureChatOnce")
local priv = upvalue(enemyAttack, "priv")
-- (2.3.0: both alerts wait for half the capture, AlertAtHalfCapture; their rules are tested here.)
local halfAlert = upvalue(sync.OnReceiveOutpostState, "AlertAtHalfCapture")
local defenderAlert = upvalue(halfAlert, "TryPrintOutpostDefenderAlert")
local assaultAlert = upvalue(halfAlert, "TryPrintOutpostAssaultAlert")
local defenderLast = upvalue(defenderAlert, "opDefenderAlertLast")
local defenderEmitted = upvalue(defenderAlert, "opDefenderAlertEmitted")
local defenderWaves = upvalue(defenderAlert, "opDefenderAlertWaveKey")
local assaultLast = upvalue(assaultAlert, "opAssaultAlertLast")
local assaultEmitted = upvalue(assaultAlert, "opAssaultAlertEmitted")
local assaultWaves = upvalue(assaultAlert, "opAssaultAlertWaveKey")
local captureDedup = upvalue(sync.PrintOutpostCaptureAlert, "opCaptureAlertDedup")
local function hasKey(t, prefix)
    for k in pairs(t) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- Fronts: Ashenvale (Kalimdor), Elwynn (Eastern Kingdoms), one front with no map.
local fronts = {
    ashenvale = { id = "ashenvale", mapName = "Ashenvale", preferredMapID = 1440,
        allianceCapitalId = "ash_astranaar", hordeCapitalId = "ash_splintertree" },
    elwynn = { id = "elwynn", mapName = "Elwynn Forest", preferredMapID = 1429,
        allianceCapitalId = "elwynn_westbrook", hordeCapitalId = "elwynn_invasion_camp" },
    nowhere = { id = "nowhere", mapName = "Nowhere" },
}
local zoneFront = {}
local function zone(id, frontId, isCapital)
    local z = { id = id, name = id, isCapital = isCapital, status = "in_progress", owner = "Horde",
        previousOwner = "Alliance", updatedAt = now }
    zoneFront[id] = { z, fronts[frontId] }
    return z
end
Overlord.Fronts.GetZone = function(_, id)
    local entry = zoneFront[id]
    if entry then return entry[1], entry[2] end
end
Overlord.Fronts.GetCapitalId = function(_, fac, frontId)
    local front = fronts[frontId]
    if not front then return nil end
    return fac == "Horde" and front.hordeCapitalId or front.allianceCapitalId
end

-- 1. "Under attack": hidden from the other continent, and nothing remembered.
local raynewood = zone("ash_raynewood", "ashenvale")
enemyAttack(raynewood, "Enemy Tester", now)
assert(take() == 0, "An attack in Kalimdor reached a player in the Eastern Kingdoms")
assert(priv.enemyAlertEmitted[raynewood.id] == nil and priv.enemyAlertLast[raynewood.id] == nil
    and not hasKey(priv.enemyAlertWaveKey, raynewood.id .. ":"), "A hidden attack alert left dedup state")
-- The same wave reaches the player once in Kalimdor.
playerMap = KALIMDOR
enemyAttack(raynewood, "Enemy Tester", now)
assert(take("ATTACK") == 1, "The attack stayed silent once the player reached Kalimdor")
assert(priv.enemyAlertEmitted[raynewood.id] == true, "A shown attack alert was not deduplicated")
playerMap = EK
enemyAttack(zone("elwynn_goldshire", "elwynn"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "An attack on the player's continent stayed silent")
-- 2.3.2: our own capital follows the same rule; a front without a map is unknown: shown.
enemyAttack(zone("ash_astranaar", "ashenvale", true), "Enemy Tester", now)
assert(take() == 0, "An attack on our own capital in Kalimdor reached a player in the Eastern Kingdoms")
enemyAttack(zone("ash_splintertree", "ashenvale", true), "Enemy Tester", now)
assert(take() == 0, "The enemy capital counted as our own capital")
enemyAttack(zone("nowhere_camp", "nowhere"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "An attack on a front without a map was hidden")

-- 2. "Taken by the Horde": same rules, the dedup untouched while hidden.
local dorDanil = zone("ash_dor_danil", "ashenvale")
captureChat(dorDanil, "Horde", "Enemy Tester", now - 30)
assert(take() == 0, "A capture in Kalimdor reached a player in the Eastern Kingdoms")
assert(priv.captureChatDedup[dorDanil.id .. ":Horde"] == nil
    and not hasKey(priv.captureChatDedupTs, dorDanil.id .. ":"), "A hidden capture alert left dedup state")
playerMap = KALIMDOR
captureChat(dorDanil, "Horde", "Enemy Tester", now - 30)
assert(take("TAKEN") == 1, "The capture stayed silent once the player reached Kalimdor")
playerMap = EK
captureChat(zone("elwynn_eastvale", "elwynn"), "Horde", "Enemy Tester", now - 20)
assert(take("TAKEN") == 1, "A capture on the player's continent stayed silent")
captureChat(zone("ash_astranaar", "ashenvale", true), "Horde", "Enemy Tester", now - 10)
assert(take() == 0, "The loss of our own capital in Kalimdor reached a player in the Eastern Kingdoms")

-- 3. Outposts. The defender alert: an allied guild's site on the other continent is
-- hidden (nothing remembered), our own guild's always alerts.
local function held(owner)
    return { status = "held", ownerGuild = owner, ownerFaction = "Alliance", claimedAt = now - 600,
        updatedAt = now - 600 }
end
local function assault(attacker, attackerFaction, previous)
    return { status = "in_progress", ownerGuild = attacker, ownerFaction = attackerFaction or "Horde",
        claimedAt = now, updatedAt = now, holdTimeElapsed = 10, previousOwnerGuild = previous or "" }
end
defenderAlert("stonetalon", held("Ally Guild"), assault("NoMercy"))
assert(take() == 0, "An allied outpost in Kalimdor reached a player in the Eastern Kingdoms")
assert(defenderLast.stonetalon == nil and defenderEmitted.stonetalon == nil
    and not hasKey(defenderWaves, "stonetalon:"), "A hidden defender alert left dedup state")
defenderAlert("stonetalon", held(guild), assault("NoMercy"))
assert(take("DEFEND") == 1, "Our own guild's outpost in Kalimdor stayed silent")
-- 2.0.4: our guild's site also shows the red line mid-screen, without the raid sound.
assert(#raidWarnings == 1 and raidWarnings[1].silent == true and raidWarnings[1].text:find("DEFEND", 1, true),
    "Our own guild's outpost under attack showed no silent red line mid-screen")
-- 2.3.0: keeps and outposts of other guilds stay silent unless the "other guilds" option is
-- on (defence, assault and capture alike); a hidden alert leaves no dedup state.
defenderAlert("silverpine", held("Ally Guild"), assault("NoMercy"))
assert(take() == 0, "An allied guild's outpost alerted with the other-guilds option off")
assert(defenderLast.silverpine == nil and defenderEmitted.silverpine == nil, "A hidden defence left dedup state")
assaultAlert("silverpine", { status = "neutral" }, assault("NoMercy", "Horde", "Ally Guild"))
assert(take() == 0, "Two other guilds' assault alerted with the other-guilds option off")
Overlord.Sync:PrintOutpostCaptureAlert("silverpine", "NoMercy", "Horde", now - 5, "Ally Guild")
assert(take() == 0, "Two other guilds' capture alerted with the other-guilds option off")
OverlordDB.config.otherGuildSiteAlerts = true
defenderAlert("silverpine", held("Ally Guild"), assault("NoMercy"))
assert(take("ALLIED") == 1, "An allied outpost on the player's continent stayed silent")
assert(#raidWarnings == 1, "An allied guild's outpost showed the red line meant for our own guild's sites")

-- Assault alert: unrelated guilds hidden, our own guild assaulting always shown.
assaultAlert("ashenvale", { status = "neutral" }, assault("NoMercy", "Horde", "Ally Guild"))
assert(take() == 0, "An assault in Kalimdor reached a player in the Eastern Kingdoms")
assert(assaultLast.ashenvale == nil and assaultEmitted.ashenvale == nil
    and not hasKey(assaultWaves, "ashenvale:"), "A hidden assault alert left dedup state")
assaultAlert("crossroads", { status = "neutral" }, assault(guild:upper(), "Alliance"))
assert(take("ASSAULT") == 1, "Our own guild's assault in Kalimdor stayed silent (case-insensitive)")
playerMap = 1439
assaultAlert("ashenvale", { status = "neutral" }, assault("NoMercy", "Horde", "Ally Guild"))
assert(take("ASSAULT") == 1, "The assault stayed silent once the player reached Kalimdor")
playerMap = EK
-- 2.2.2: an abandoned assault a relay still serves (Savix Chapel, every login) is silent
-- and leaves no dedup state; a live one on the same site still alerts.
local abandoned = assault("Loves You", "Alliance", "Les cames")
abandoned.updatedAt = now - 3600
assaultAlert("silverpine", held("Les cames"), abandoned)
assert(take() == 0, "An abandoned assault served by a relay printed an alert")
assert(assaultLast.silverpine == nil and assaultEmitted.silverpine == nil
    and not hasKey(assaultWaves, "silverpine:"), "A stale assault left dedup state")
assaultAlert("silverpine", held("Les cames"), assault("Loves You", "Alliance", "Les cames"))
assert(take("ASSAULT") == 1, "A live assault stayed silent")

-- Capture alert: no line and no dedup from the other continent, unless our guild takes
-- or loses the site. Never a sound (2.0.4: every capture rang a raid warning).
sounds, addonSounds = 0, 0
sync:PrintOutpostCaptureAlert("durotar", "NoMercy", "Horde", now - 5)
assert(take() == 0 and sounds == 0, "A capture in Kalimdor reached a player in the Eastern Kingdoms")
assert(not hasKey(captureDedup, "durotar:"), "A hidden capture alert left dedup state")
sync:PrintOutpostCaptureAlert("durotar", "NoMercy", "Horde", now - 5, "observer guild")
assert(take("CAPTURED") == 1, "Losing our own guild's outpost in Kalimdor stayed silent")
sync:PrintOutpostCaptureAlert("mulgore", guild, "Alliance", now - 4)
assert(take("CAPTURED") == 1, "Our own guild's capture in Kalimdor stayed silent")
assert(sounds == 0 and addonSounds == 0, "A keep or outpost capture alert played a sound")
sync:PrintOutpostCaptureAlert("silverpine", "NoMercy", "Horde", now - 3)
assert(take("CAPTURED") == 1, "A capture on the player's continent stayed silent")

-- The network path: the assault still applies to the map while its alert is hidden.
local function wireAt(siteKey, attacker)
    local st = op:GetState(siteKey)
    local saved = {}
    for k, v in pairs(st) do saved[k] = v end
    st.status, st.ownerGuild, st.ownerFaction = "in_progress", attacker, "Horde"
    -- (2.3.0: past half the capture, so the alert is due at once.)
    st.holdTimeElapsed, st.claimedAt, st.updatedAt, st.pool = 160, now, now, "global"
    local payload = assert(sync:BuildOutpostPayload(siteKey))
    for k in pairs(st) do st[k] = nil end
    for k, v in pairs(saved) do st[k] = v end
    return payload
end
now = now + 20
sync:OnReceiveOutpostState(wireAt("lesi_bear_cave", "NoMercy"), "Channel Mate", "CHANNEL")
assert(op:GetState("lesi_bear_cave").status == "in_progress", "Fixture: the hidden assault did not apply")
assert(take() == 0, "A relayed assault in Kalimdor reached a player in the Eastern Kingdoms")
playerMap = 1439
now = now + 20
sync:OnReceiveOutpostState(wireAt("lesi_bear_cave", "No Flying"), "Channel Mate", "CHANNEL")
assert(take("ASSAULT") == 1, "The next assault stayed silent once the player reached Kalimdor")
playerMap = EK

-- 2.3.0: our guild losing its keep or outpost to a capture final (OC, or any path through
-- Outpost:CompleteCapture) is our guild's matter: told with the other-guilds option off.
OverlordDB.config.otherGuildSiteAlerts = false
do
    local lost = op:GetState("silverpine")
    lost.status, lost.ownerGuild, lost.ownerFaction = "held", guild, "Alliance"
    lost.claimedAt, lost.updatedAt, lost.pool, lost.holdTimeElapsed = now - 900, now - 900, "global", 0
    assert(op:CompleteCapture("silverpine", "NoMercy", "Horde", now, "global", true, "Enemy Tester"),
        "Fixture: the enemy capture final was refused")
    assert(take("CAPTURED") == 1, "Our own guild's outpost lost to a capture final stayed silent")
end
OverlordDB.config.otherGuildSiteAlerts = true

-- 4. The option brings back the whole world.
OverlordDB.config.alertScope = "world"
enemyAttack(zone("ash_bough_shadow", "ashenvale"), "Enemy Tester", now)
captureChat(zone("ash_maestra", "ashenvale"), "Horde", "Enemy Tester", now - 2)
defenderAlert("mulgore", held("Ally Guild"), assault("NoMercy"))
assaultAlert("durotar", { status = "neutral" }, assault("Ruthless", "Horde", "Ally Guild"))
sync:PrintOutpostCaptureAlert("crossroads", "NoMercy", "Horde", now - 1)
assert(take() == 5, "The worldwide option did not bring back the other continent")
OverlordDB.config.alertScope = "continent"

-- 5. Unknown continent of the player: everything shows. Without a map, the open-world
-- instance id still tells the continent (0 = Eastern Kingdoms, 1 = Kalimdor).
playerMap = nil
assert(Overlord:GetPlayerContinent() == nil, "No map and no instance gave a continent")
enemyAttack(zone("ash_silverwind", "ashenvale"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "An unknown player continent hid the alert")
local instanceID = 1
GetInstanceInfo = function() return "Kalimdor", "none", 0, "", 5, 0, false, instanceID end
assert(Overlord:GetPlayerContinent() == "K", "Instance 1 is not Kalimdor")
instanceID = 0
assert(Overlord:GetPlayerContinent() == "EK", "Instance 0 is not the Eastern Kingdoms")
enemyAttack(zone("ash_forest_song", "ashenvale"), "Enemy Tester", now)
assert(take() == 0, "The instance fallback did not place the player")
instanceID = 530
assert(Overlord:GetPlayerContinent() == nil, "Another continent was taken for a known one")
GetInstanceInfo = nil
playerMap = EK

-- 6. Map data missing while loading: nothing is cached, the next call resolves.
Overlord.alertContinentCache = {}
local saved = maps
maps = {}
assert(Overlord:GetMapContinent(1440) == nil and Overlord:ShouldShowPlaceAlert(1440), "Unloaded map hid an alert")
maps = saved
assert(Overlord:GetMapContinent(1440) == "K" and not Overlord:ShouldShowPlaceAlert(1440),
    "The map stayed unknown once loaded")
assert(Overlord:GetMapContinent(13) == "EK" and Overlord:GetMapContinent(12) == "K",
    "Retail continent ids are not recognised")
local savedMap = C_Map
C_Map = nil
Overlord.alertContinentCache = {}
assert(Overlord:ShouldShowPlaceAlert(1440), "No map API hid an alert")
C_Map = savedMap

-- 6b. 2.3.2: the default is the player's zone. A cave climbs to its zone; a front, an outpost or a
-- mine with two map ids (Classic and Retail) is one zone; our own capital and the mines follow the
-- same rule. Another zone of the same continent is hidden, with nothing remembered.
OverlordDB.config.alertScope = nil
assert(Overlord:GetAlertScope() == "zone", "The default is not the player's zone")
fronts.elwynn.mapIDs = { [37] = true, [1429] = true }
playerMap = EK
enemyAttack(zone("elwynn_fargodeep", "elwynn"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "An attack in the player's zone stayed silent")
playerMap = 1421
local jerod = zone("elwynn_jerod", "elwynn")
enemyAttack(jerod, "Enemy Tester", now)
assert(take() == 0, "An attack in another zone of the continent reached the player")
assert(priv.enemyAlertEmitted[jerod.id] == nil, "A hidden zone alert left dedup state")
enemyAttack(zone("elwynn_westbrook", "elwynn", true), "Enemy Tester", now)
assert(take() == 0, "Our own capital in another zone reached the player")
playerMap = 9001
enemyAttack(jerod, "Enemy Tester", now)
assert(take("ATTACK") == 1, "An attack in the zone around the player's cave stayed silent")
playerMap = 37
enemyAttack(zone("elwynn_stonecairn", "elwynn"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "The Retail id of the same zone counted as another zone")
playerMap = 1453
enemyAttack(zone("elwynn_brackwell", "elwynn"), "Enemy Tester", now)
assert(take("ATTACK") == 1, "A player in Stormwind did not hear Elwynn")
playerMap = 1421
assaultAlert("elwynn", { status = "neutral" }, assault("NoMercy", "Horde", "Ally Guild"))
assert(take() == 0 and assaultLast.elwynn == nil, "An outpost assault in another zone reached the player")
playerMap = EK
assaultAlert("elwynn", { status = "neutral" }, assault("NoMercy", "Horde", "Ally Guild"))
assert(take("ASSAULT") == 1, "An outpost assault in the player's zone stayed silent")
-- Mines (2.3.2: they were announced from the whole world).
L.ENEMY_MINING_HORDE = "MINING %s"
local minePriv = sync:GetPriv()
playerMap = 1421
sync:OnReceiveMining("jasperlode:H", "Enemy Miner")
assert(take() == 0 and minePriv.mineAlertLast.jasperlode == nil, "A mine in another zone reached the player")
playerMap = 37
sync:OnReceiveMining("jasperlode:H", "Enemy Miner")
assert(take("MINING") == 1, "A mine in the player's zone stayed silent")
OverlordDB.config.alertScope = "continent"
playerMap = 1421
sync:OnReceiveMining("elemgorge:H", "Enemy Miner")
assert(take("MINING") == 1, "The continent setting hid a mine of the continent")
-- 2.5.0: the layer written by the miner's client can be clicked (the link names nobody: the
-- miner is of the other faction), and stays plain text without the layer window's module.
do
    minePriv.mineAlertLast = {}
    sync:OnReceiveMining("elemgorge:H:6846", "Enemy Miner")
    assert(#printed == 1 and printed[1]:find("(Enemy Miner, layer #6846)", 1, true), "the mine's plain layer: " .. tostring(printed[1]))
    printed = {}
    local asked
    Overlord.LayerJumper = { ChatLink = function(_, name, layer, text)
        asked = { name = name, layer = layer, text = text }
        return ", <" .. tostring(layer) .. ">"
    end }
    minePriv.mineAlertLast = {}
    sync:OnReceiveMining("elemgorge:H:6846", "Enemy Miner")
    assert(asked and asked.name == nil and tostring(asked.layer) == "6846" and asked.text == ", layer #6846",
        "the mine alert did not ask for its layer link")
    assert(#printed == 1 and printed[1]:find("(Enemy Miner, <6846>)", 1, true), "the mine's layer link: " .. tostring(printed[1]))
    printed = {}
    Overlord.LayerJumper = nil
end
playerMap = EK

-- 7. The option: a menu of three (zone, continent, world), the zone by default, stored as
-- config.alertScope. The 1.8.0 "whole world" box ticked reads as the whole world.
do
    local registered = {}
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.securecall = function(fn, ...) return fn(...) end
    env.Settings = {
        RegisterVerticalLayoutCategory = function(name) return { name = name }, { AddInitializer = function() end } end,
        RegisterProxySetting = function(_, var, kind, label, default, get, set)
            local s = { kind = kind, label = label, default = default, get = get, set = set }
            registered[var] = s
            return s
        end,
        CreateCheckbox = function(_, s, tooltip) s.control, s.tooltip = "checkbox", tooltip end,
        CreateDropdown = function(_, s, options, tooltip) s.control, s.options, s.tooltip = "dropdown", options, tooltip end,
        CreateControlTextContainer = function()
            local data = {}
            return { Add = function(_, value, text) data[#data + 1] = { value = value, text = text } end,
                GetData = function() return data end }
        end,
        RegisterAddOnCategory = function() end,
    }
    env.Overlord = { L = { ALERT_SCOPE_TOOLTIP = "TIP" }, GetAlertScope = Overlord.GetAlertScope,
        ALERT_SCOPES = Overlord.ALERT_SCOPES }
    env.OverlordDB = OverlordDB
    local chunk = assert(loadfile("SettingsPanel.lua"))
    setfenv(chunk, env)
    chunk()
    env.Overlord.SettingsPanel:Register()
    local row = registered.Overlord_AlertScope
    assert(row and row.control == "dropdown" and row.kind == "string" and row.default == "zone",
        "The alert scope menu is missing or not on the zone by default")
    assert(row.label == "Capture alerts" and row.tooltip == "TIP", "Menu texts")
    local values = {}
    for _, option in ipairs(row.options()) do values[#values + 1] = option.value end
    assert(table.concat(values, ",") == "zone,continent,world", "Menu choices")
    local cfg = OverlordDB.config
    cfg.alertScope, cfg.worldwideAlerts = nil, nil
    assert(row.get() == "zone", "The option reads another scope without a saved value")
    cfg.worldwideAlerts = true
    assert(row.get() == "world", "The 1.8.0 whole-world box was not kept")
    row.set("continent")
    assert(cfg.alertScope == "continent" and cfg.worldwideAlerts == nil and row.get() == "continent",
        "The option was not saved")
    row.set("nowhere")
    assert(cfg.alertScope == "continent", "An unknown scope was saved")
    -- 2.3.0: other guilds' keeps and outposts, off by default.
    cfg.otherGuildSiteAlerts = nil
    local other = registered.Overlord_OtherGuildSiteAlerts
    assert(other and other.control == "checkbox" and other.default == false and other.get() == false,
        "The other-guilds site alerts checkbox is missing or not off by default")
    other.set(true)
    assert(env.OverlordDB.config.otherGuildSiteAlerts == true and other.get() == true, "Other-guilds option not saved")
end

-- 8. Every language names the option, and the tutorial names it the same way.
local english, otherEnglish
for _, loc in ipairs({ "enUS", "frFR", "esES", "deDE", "ruRU", "ptBR", "zhCN" }) do
    local env = setmetatable({ GetLocale = function() return loc end }, { __index = _G })
    env.Overlord = { L = {} }
    for _, file in ipairs({ "Locales.lua", "GuideLocales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua",
        "ForeverLocaleFixes.lua", "FrontLocales.lua" }) do
        local chunk = assert(loadfile(file))
        setfenv(chunk, env)
        chunk()
    end
    local LL = env.Overlord.L
    for _, key in ipairs({ "ALERT_SCOPE_LABEL", "ALERT_SCOPE_TOOLTIP", "ALERT_SCOPE_ZONE",
        "ALERT_SCOPE_CONTINENT", "ALERT_SCOPE_WORLD" }) do
        assert(type(LL[key]) == "string" and LL[key] ~= "", loc .. " misses " .. key)
    end
    assert(LL.GUIDE_ALERTS_BODY:find(LL.ALERT_SCOPE_LABEL, 1, true),
        loc .. ": the tutorial does not name the alert scope option")
    assert(type(LL.OTHER_GUILD_SITE_ALERTS_LABEL) == "string" and LL.OTHER_GUILD_SITE_ALERTS_LABEL ~= ""
        and type(LL.OTHER_GUILD_SITE_ALERTS_TOOLTIP) == "string"
        and LL.GUIDE_ALERTS_BODY:find(LL.OTHER_GUILD_SITE_ALERTS_LABEL, 1, true),
        loc .. ": the other-guilds site alerts option is missing or not named by the tutorial")
    if loc ~= "enUS" then
        assert(LL.OTHER_GUILD_SITE_ALERTS_TOOLTIP ~= otherEnglish, loc .. " shows the English other-guilds tooltip")
    else
        otherEnglish = LL.OTHER_GUILD_SITE_ALERTS_TOOLTIP
    end
    if loc == "enUS" then
        english = LL.ALERT_SCOPE_TOOLTIP
    else
        assert(LL.ALERT_SCOPE_TOOLTIP ~= english, loc .. " shows the English tooltip")
    end
end
print("Alert scope: zone by default (caves, Retail ids, outposts, mines), continent and world settings; own guild and unknown places shown; hidden alerts leave no dedup state")
