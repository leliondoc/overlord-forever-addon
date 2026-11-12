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

-- 2.5.1: the layer of a player asked by name is three lookups in an index of the known layers
-- (lowered name, dedup key, base name), not a pass over all of them: a name that was not there
-- cost 1 ms with 512 known layers, and a guild rampage asked for every killer in one frame.
do
    local savedSync = Overlord.Sync
    Overlord.Sync = { GetCaptureContributorDedupKey = function(_, name) return ((name:match("^([^%-]+)") or name):lower()) end }
    shard:SetPlayerShard("Ann Lee-Realm", 7)
    shard:SetPlayerShard("Bob Stone", 8)
    local who, layer = shard:ResolveKnownShardPlayer("Bob Stone", true)
    assert(who == "Bob Stone" and layer == 8, "a player asked by its exact name")
    who, layer = shard:ResolveKnownShardPlayer("bob stone", true)
    assert(who == "Bob Stone" and layer == 8, "a player asked in another case")
    -- The key holds the realm, the question does not: found by the dedup key, strict or not.
    who, layer = shard:ResolveKnownShardPlayer("Ann Lee", true)
    assert(who == "Ann Lee-Realm" and layer == 7, "a player known with its realm, asked without: " .. tostring(who))
    -- Without a dedup key (a short capturer name): only the loose question finds the base name.
    Overlord.Sync = nil
    shard._resolveIndex = nil
    assert(shard:ResolveKnownShardPlayer("Ann Lee", true) == nil, "the strict question matched a base name")
    who, layer = shard:ResolveKnownShardPlayer("Ann Lee", false)
    assert(who == "Ann Lee-Realm" and layer == 7, "the loose question did not find the base name")
    -- A name nobody holds: nothing, and the index is not built again for it.
    local index = shard._resolveIndex
    assert(index and shard:ResolveKnownShardPlayer("No Body", false) == nil and shard._resolveIndex == index,
        "a name that is not there built the index again")
    -- A player added or removed: the next question sees it, and the index is not built again
    -- (a newcomer joins it in place, a departure is dropped where it is met).
    shard:SetPlayerShard("Cid Vale", 9)
    who, layer = shard:ResolveKnownShardPlayer("cid vale", true)
    assert(who == "Cid Vale" and layer == 9 and shard._resolveIndex == index, "a player added after the index was built")
    shard:RemoveKnownShardPeer("Ann Lee-Realm")
    assert(shard:ResolveKnownShardPlayer("Ann Lee", false) == nil, "a removed player is still found")
    -- Past its life: not found (and dropped).
    shard:ResolveKnownShardPlayer("cid vale", true)
    local built = shard._resolveIndex
    now = now + 100000
    assert(shard:ResolveKnownShardPlayer("Bob Stone", true) == nil and shard.knownShards["Bob Stone"] == nil,
        "a layer past its life was returned")
    -- (Dropped from the index in place: a rampage asking for many stale killers in one frame built
    -- it again for each of them.)
    assert(shard._resolveIndex == built and built.byLower["bob stone"] == nil
        and built.byBase["bob stone"] == nil,
        "a layer past its life built the index again, or stayed in it")
    assert(shard:ResolveKnownShardPlayer("Cid Vale", true) == nil and shard._resolveIndex == built,
        "a second stale player built the index again")
    shard:SetPlayerShard("Dee Moor", 4)
    who, layer = shard:ResolveKnownShardPlayer("Dee Moor", true)
    assert(who == "Dee Moor" and layer == 4 and shard._resolveIndex == built, "a player added after a drop")
    who, layer = shard:ResolveKnownShardPlayer("Dee Moor-Elsewhere", false)
    assert(who == "Dee Moor" and layer == 4 and shard._resolveIndex == built, "a newcomer's base name is not in the index")
    -- Two players of the same base: the one who leaves does not hide the other, and the index
    -- loses nothing at a departure.
    shard:SetPlayerShard("Dee Moor-Faraway", 6)
    shard:RemoveKnownShardPeer("Dee Moor")
    assert(built.byLower["dee moor"] == nil, "a departure stayed in the index")
    who, layer = shard:ResolveKnownShardPlayer("Dee Moor-Elsewhere", false)
    assert(who == "Dee Moor-Faraway" and layer == 6 and shard._resolveIndex == built,
        "a known player of the same base was hidden by one who left: " .. tostring(who))
    shard:SetPlayerShard("Dee Moor", 4)
    now = now + 100000
    shard:SetPlayerShard("Dee Moor-Faraway", 6)
    who, layer = shard:ResolveKnownShardPlayer("Dee Moor-Elsewhere", false)
    assert(who == "Dee Moor-Faraway" and layer == 6 and shard.knownShards["Dee Moor"] == nil,
        "a stale player of the same base hid a live one: " .. tostring(who))
    -- Another table of players (a reset): built again.
    local savedKnown = shard.knownShards
    shard.knownShards = { ["Eve Hart"] = 5 }
    shard:ResolveIndex()
    assert(shard._resolveIndex ~= built and shard._resolveIndex.byLower["eve hart"]
        and shard._resolveIndex.byLower["eve hart"]["Eve Hart"], "a new table of players was not read")
    shard.knownShards = savedKnown
    shard._resolveIndex = nil
    Overlord.Sync = savedSync
end

-- 2.5.1: the players whose presence says they help ("Help others" on). Kept 15 min, taken back
-- by a presence without the mark, bounded.
do
    assert(not shard:IsPlayerHelper("Hal Helper"), "a helper nobody told us of")
    shard:SetPlayerHelper("Hal Helper", true)
    assert(shard:IsPlayerHelper("Hal Helper") and shard.knownHelperCount == 1, "a helper told by its presence")
    shard:SetPlayerHelper("Hal Helper", true)
    assert(shard.knownHelperCount == 1, "the same helper counted twice")
    shard:SetPlayerHelper("Hal Helper", false)
    assert(not shard:IsPlayerHelper("Hal Helper") and shard.knownHelperCount == 0, "the mark was not taken back")
    shard:SetPlayerHelper("", true); shard:SetPlayerHelper(nil, true); shard:SetPlayerHelper("Not There", false)
    assert(shard.knownHelperCount == 0, "an empty name was kept")
    shard:SetPlayerHelper("Hal Helper", true)
    now = now + 901
    assert(not shard:IsPlayerHelper("Hal Helper"), "a helper mark outlived its 15 minutes")
    -- Full: the lapsed ones leave first (Hal), the table never passes its bound.
    for i = 1, 599 do shard:SetPlayerHelper("Helper " .. i, true) end
    assert(shard.knownHelperCount == 600, "600 names: " .. tostring(shard.knownHelperCount))
    shard:SetPlayerHelper("Helper 600", true)
    assert(shard.knownHelperCount == 600 and shard.knownHelpers["Hal Helper"] == nil and shard:IsPlayerHelper("Helper 600")
        and shard:IsPlayerHelper("Helper 1"), "the lapsed helper did not leave first: " .. tostring(shard.knownHelperCount))
    shard:SetPlayerHelper("Helper 601", true)
    local held = 0
    for _ in pairs(shard.knownHelpers) do held = held + 1 end
    assert(held == 1 and shard.knownHelperCount == 1 and shard:IsPlayerHelper("Helper 601"), "the table passed its bound: " .. held)
end

print("Layer: server field, two agreeing NPCs, player creatures skipped, helper marks OK")
