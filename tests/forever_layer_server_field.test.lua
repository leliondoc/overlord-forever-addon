-- 2.3.3: the layer is the GUID's server field (3rd), not the zone UID (5th). Players standing
-- together read different zone UIDs; the server field is shared by those who see each other.
-- Creatures of players (pets, totems) are skipped and a layer needs two NPCs that agree.
local now = 100
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return "enUS" end
function IsInGroup() return false end
function IsInRaid() return false end
local units = {}
function UnitExists(unit) return units[unit] ~= nil end
function UnitIsPlayer(unit) return units[unit] ~= nil and units[unit].player == true end
function UnitPlayerControlled(unit) return units[unit] ~= nil and units[unit].controlled == true end
function UnitIsVisible(unit) return units[unit] ~= nil end
function UnitGUID(unit) return units[unit] and units[unit].guid end
function GetUnitName(unit) return units[unit] and units[unit].name end
UnitName = GetUnitName
function UnitFactionGroup() return "Alliance" end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1)
        start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
local methods = {}
function methods:SetScript(event, fn) self.scripts = self.scripts or {}; self.scripts[event] = fn end
setmetatable(methods, { __index = function(_, key)
    if key:match("^Set") or key:match("^Register") or key == "Hide" then return function() end end
end })
local frames = {}
function CreateFrame() local f = setmetatable({}, { __index = methods }); frames[#frames + 1] = f; return f end
C_Timer = { After = function() end, NewTicker = function() return {} end,
    NewTimer = function() return { Cancel = function() end } end }
local vignettes, vignetteObjects = {}, {}
C_VignetteInfo = {
    GetVignettes = function() return vignettes end,
    GetVignetteInfo = function(g) return { objectGUID = vignetteObjects[g] } end,
}
C_NamePlate = { GetNamePlates = function()
    local list = {}
    for i = 1, 40 do
        if units["nameplate" .. i] then list[#list + 1] = { namePlateUnitToken = "nameplate" .. i } end
    end
    return list
end }
Overlord = { L = {} }
assert(loadfile("Core.lua"))()
local shard = Overlord.Shard

local function scan(set, vigs, objs)
    for k in pairs(units) do units[k] = nil end
    for k, v in pairs(set or {}) do units[k] = v end
    vignettes, vignetteObjects = vigs or {}, objs or {}
    return shard:ScanForShardID()
end

-- 1. Darnassus, two NPCs on one layer with different zone UIDs: the server field (7075).
assert(scan({
    target = { guid = "Creature-0-7075-1-20-4262-0000AAAA01" },
    nameplate1 = { guid = "Creature-0-7075-1-2-4262-0000AAAA02" },
}) == 7075, "two NPCs of one layer did not give its server field")

-- 2. One NPC alone is not enough.
assert(scan({ target = { guid = "Creature-0-7075-1-20-4262-0000AAAA01" } }) == nil,
    "a single NPC was believed")

-- 3. The same NPC seen as target and nameplate counts once.
assert(scan({
    target = { guid = "Creature-0-7075-1-20-4262-0000AAAA01" },
    nameplate1 = { guid = "Creature-0-7075-1-20-4262-0000AAAA01" },
}) == nil, "one NPC seen twice was taken as two")

-- 4. A pet or totem (player-controlled) carries another server number: skipped.
assert(scan({
    target = { guid = "Creature-0-6831-1-5-416-0000BBBB01", controlled = true },
    nameplate1 = { guid = "Creature-0-6831-1-5-416-0000BBBB02", controlled = true },
    nameplate2 = { guid = "Creature-0-7062-1-1-3100-0000CCCC01" },
    nameplate3 = { guid = "Creature-0-7062-1-9-3100-0000CCCC02" },
}) == 7062, "player-controlled creatures decided the layer")

-- 5. Two NPCs disagree, a third settles it.
assert(scan({
    target = { guid = "Creature-0-6829-1-2-3100-0000DDDD01" },
    nameplate1 = { guid = "Creature-0-7076-1-3-3100-0000DDDD02" },
    nameplate2 = { guid = "Creature-0-7076-1-8-3100-0000DDDD03" },
}) == 7076, "a disagreement was not settled by the second agreeing NPC")

-- 6. Players and non-creature GUIDs are ignored; vignettes vote once each (own GUID or object).
assert(scan({ target = { guid = "Player-7075-00ABCDEF", player = true } }) == nil,
    "a player GUID gave a layer")
assert(scan(nil, { "Vignette-0-7054-1-26-0-0000EEEE01", "Vignette-0-7054-1-13-0-0000EEEE02" }) == 7054,
    "two vignettes of one layer did not agree")
assert(scan(nil, { "Vignette-0-7054-1-26-0-0000EEEE01" },
    { ["Vignette-0-7054-1-26-0-0000EEEE01"] = "Creature-0-7054-1-26-3100-0000EEEE09" }) == nil,
    "a vignette and its own object voted twice")

-- 7. Malformed server fields give nothing.
assert(scan({
    target = { guid = "Creature-0-abc-1-20-4262-0000AAAA01" },
    nameplate1 = { guid = "Creature-0--1-2-4262-0000AAAA02" },
}) == nil, "a malformed server field gave a layer")

-- 8. Events (target, nameplate, kill) confirm the known layer from one GUID, but a new layer
-- needs a second, different NPC: a killed totem carries its owner's server number.
Overlord.InActiveFront = true
shard:Initialize()
local onEvent
for _, f in ipairs(frames) do if f.scripts and f.scripts.OnEvent then onEvent = f.scripts.OnEvent end end
assert(onEvent, "layer events not wired")
scan({ player = { guid = "Player-7075-00000001", player = true } })
shard.currentShardID = 7075
onEvent(nil, "PARTY_KILL", "Player-7075-00000001", "Creature-0-6831-1-5-2630-0000FFFF01")
assert(shard.currentShardID == 7075, "a killed totem moved the layer on its own")
onEvent(nil, "PARTY_KILL", "Player-7075-00000001", "Creature-0-6831-1-5-2630-0000FFFF12")
assert(shard.currentShardID == 7075, "two killed totems moved a known layer")
units.target = { guid = "Creature-0-7062-1-1-3100-0000FFFF02" }
onEvent(nil, "PLAYER_TARGET_CHANGED")
assert(shard.currentShardID == 7075, "one targeted NPC moved the layer on its own")
units.target = { guid = "Creature-0-7062-1-1-3100-0000FFFF02" }
onEvent(nil, "PLAYER_TARGET_CHANGED")
assert(shard.currentShardID == 7075, "the same NPC targeted twice counted as two")
units.nameplate1 = { guid = "Creature-0-7062-1-4-3100-0000FFFF03" }
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(shard.currentShardID == 7062, "two NPCs agreeing did not move the layer")
units.mouseover = { guid = "Creature-0-7062-1-9-3100-0000FFFF04" }
onEvent(nil, "UPDATE_MOUSEOVER_UNIT")
assert(shard.currentShardID == 7062, "one NPC of the known layer did not keep it")
-- A waiting layer expires after 30 s.
units.target = { guid = "Creature-0-7075-1-1-3100-0000FFFF05" }
onEvent(nil, "PLAYER_TARGET_CHANGED")
now = now + 31
units.mouseover = { guid = "Creature-0-7075-1-2-3100-0000FFFF06" }
onEvent(nil, "UPDATE_MOUSEOVER_UNIT")
assert(shard.currentShardID == 7062, "two NPCs 31 s apart moved the layer")
-- An NPC of the known layer in between contradicts the waiting one.
now = now + 31
units.target = { guid = "Creature-0-7075-1-3-3100-0000FFFF07" }
onEvent(nil, "PLAYER_TARGET_CHANGED")
units.mouseover = { guid = "Creature-0-7062-1-5-3100-0000FFFF08" }
onEvent(nil, "UPDATE_MOUSEOVER_UNIT")
units.focus = { guid = "Creature-0-7075-1-4-3100-0000FFFF09" }
onEvent(nil, "PLAYER_FOCUS_CHANGED")
assert(shard.currentShardID == 7062, "a waiting layer survived an NPC of the known layer")
-- A context change (new front) forgets the waiting layer.
units.target = { guid = "Creature-0-7075-1-6-3100-0000FFFF10" }
onEvent(nil, "PLAYER_TARGET_CHANGED")
shard:InvalidateLocalContext()
shard.currentShardID = 7062
units.mouseover = { guid = "Creature-0-7075-1-7-3100-0000FFFF11" }
onEvent(nil, "UPDATE_MOUSEOVER_UNIT")
assert(shard.currentShardID == 7062, "an NPC of the previous context validated a layer")
-- A vignette whose object already voted as a nameplate does not vote again.
assert(scan({ nameplate1 = { guid = "Creature-0-7054-1-26-3100-0000EEEE09" } },
    { "Vignette-0-7054-1-26-0-0000EEEE01" },
    { ["Vignette-0-7054-1-26-0-0000EEEE01"] = "Creature-0-7054-1-26-3100-0000EEEE09" }) == nil,
    "one NPC voted as a nameplate and again as a vignette")

print("Layer: server field, two agreeing NPCs, player creatures skipped OK")
