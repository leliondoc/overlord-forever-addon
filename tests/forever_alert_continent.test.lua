-- 1.8.0: capture and outpost alerts come only from the continent the player is on.
-- Always shown: our own capital, our own guild's outposts (defended, assaulted, taken
-- or lost), and everything with the "whole world" option. An unknown continent (of
-- the place or of the player) shows the alert. A hidden alert marks no dedup state.
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
local maps = {
    [946] = { parentMapID = 0 },
    [947] = { parentMapID = 946 },
    [1414] = { parentMapID = 947 }, -- Kalimdor
    [1415] = { parentMapID = 947 }, -- Eastern Kingdoms
    [1439] = { parentMapID = 1414 }, -- Darkshore
    [1440] = { parentMapID = 1414 }, -- Ashenvale
    [1442] = { parentMapID = 1414 }, -- Stonetalon Mountains
    [1411] = { parentMapID = 1414 }, -- Durotar
    [1412] = { parentMapID = 1414 }, -- Mulgore
    [1413] = { parentMapID = 1414 }, -- The Barrens
    [1429] = { parentMapID = 1415 }, -- Elwynn Forest
    [1421] = { parentMapID = 1415 }, -- Silverpine Forest
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
OverlordDB = { lastResetTimestamp = 1789527600, config = { soundEnabled = true }, outposts = {} }
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
local defenderAlert = upvalue(sync.OnReceiveOutpostState, "TryPrintOutpostDefenderAlert")
local assaultAlert = upvalue(sync.OnReceiveOutpostState, "TryPrintOutpostAssaultAlert")
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
-- Our own capital is always announced; a front without a map is unknown: shown.
enemyAttack(zone("ash_astranaar", "ashenvale", true), "Enemy Tester", now)
assert(take("ATTACK") == 1, "An attack on our own capital in Kalimdor stayed silent")
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
assert(take("TAKEN") == 1, "The loss of our own capital in Kalimdor stayed silent")

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
defenderAlert("silverpine", held("Ally Guild"), assault("NoMercy"))
assert(take("ALLIED") == 1, "An allied outpost on the player's continent stayed silent")

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

-- Capture alert: no line, no dedup and no sound from the other continent, unless our
-- guild takes or loses the site.
sounds, addonSounds = 0, 0
sync:PrintOutpostCaptureAlert("durotar", "NoMercy", "Horde", now - 5)
assert(take() == 0 and sounds == 0, "A capture in Kalimdor reached a player in the Eastern Kingdoms")
assert(not hasKey(captureDedup, "durotar:"), "A hidden capture alert left dedup state")
sync:PrintOutpostCaptureAlert("durotar", "NoMercy", "Horde", now - 5, "observer guild")
assert(take("CAPTURED") == 1 and sounds == 1, "Losing our own guild's outpost in Kalimdor stayed silent")
sync:PrintOutpostCaptureAlert("mulgore", guild, "Alliance", now - 4)
assert(take("CAPTURED") == 1 and addonSounds == 1, "Our own guild's capture in Kalimdor stayed silent")
sync:PrintOutpostCaptureAlert("silverpine", "NoMercy", "Horde", now - 3)
assert(take("CAPTURED") == 1, "A capture on the player's continent stayed silent")

-- The network path: the assault still applies to the map while its alert is hidden.
local function wireAt(siteKey, attacker)
    local st = op:GetState(siteKey)
    local saved = {}
    for k, v in pairs(st) do saved[k] = v end
    st.status, st.ownerGuild, st.ownerFaction = "in_progress", attacker, "Horde"
    st.holdTimeElapsed, st.claimedAt, st.updatedAt, st.pool = 10, now, now, "global"
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

-- 4. The option brings back the whole world.
OverlordDB.config.worldwideAlerts = true
enemyAttack(zone("ash_bough_shadow", "ashenvale"), "Enemy Tester", now)
captureChat(zone("ash_maestra", "ashenvale"), "Horde", "Enemy Tester", now - 2)
defenderAlert("mulgore", held("Ally Guild"), assault("NoMercy"))
assaultAlert("durotar", { status = "neutral" }, assault("Ruthless", "Horde", "Ally Guild"))
sync:PrintOutpostCaptureAlert("crossroads", "NoMercy", "Horde", now - 1)
assert(take() == 5, "The worldwide option did not bring back the other continent")
OverlordDB.config.worldwideAlerts = false

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

-- 7. The option: a Chat checkbox, off by default, stored as config.worldwideAlerts.
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
        RegisterAddOnCategory = function() end,
    }
    env.Overlord = { L = { WORLDWIDE_ALERTS_TOOLTIP = "TIP" } }
    env.OverlordDB = { config = {} }
    local chunk = assert(loadfile("SettingsPanel.lua"))
    setfenv(chunk, env)
    chunk()
    env.Overlord.SettingsPanel:Register()
    local row = registered.Overlord_WorldwideAlerts
    assert(row and row.control == "checkbox" and row.kind == "boolean" and row.default == false,
        "The worldwide alerts checkbox is missing or not off by default")
    assert(row.label == "Capture alerts from the whole world" and row.tooltip == "TIP", "Checkbox texts")
    assert(row.get() == false, "The option reads on without a saved value")
    row.set(true)
    assert(env.OverlordDB.config.worldwideAlerts == true and row.get() == true, "The option was not saved")
    row.set(false)
    assert(env.OverlordDB.config.worldwideAlerts == false and row.get() == false, "The option did not turn off")
end

-- 8. Every language names the option, and the tutorial names it the same way.
local english
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
    assert(type(LL.WORLDWIDE_ALERTS_LABEL) == "string" and LL.WORLDWIDE_ALERTS_LABEL ~= ""
        and type(LL.WORLDWIDE_ALERTS_TOOLTIP) == "string" and LL.WORLDWIDE_ALERTS_TOOLTIP ~= "",
        loc .. " misses the worldwide alerts option texts")
    assert(LL.GUIDE_ALERTS_BODY:find(LL.WORLDWIDE_ALERTS_LABEL, 1, true),
        loc .. ": the tutorial does not name the worldwide alerts option")
    if loc == "enUS" then
        english = LL.WORLDWIDE_ALERTS_TOOLTIP
    else
        assert(LL.WORLDWIDE_ALERTS_TOOLTIP ~= english, loc .. " shows the English tooltip")
    end
end
print("Alert continent: other-continent capture and outpost alerts hidden without dedup state; own capital, own guild, worldwide option and unknown continents shown")
