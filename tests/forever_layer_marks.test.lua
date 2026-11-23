-- 2.7.0 (Layers OL): the game hides the layer in creature GUIDs, so Overlord gives layers marks
-- of its own. Two players who see each other are on one layer: their marks become one. A mark
-- is tag * 1000 + number, shown "OL<number>"; same tag = same layer, different tags prove nothing.
local now = 100
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function GetServerTime() return time() end
function GetLocale() return "enUS" end
local grouped = false
function IsInGroup() return grouped end
function IsInRaid() return false end
function GetNumGroupMembers() return grouped and 2 or 0 end
local units = {}
function UnitExists(unit) return units[unit] ~= nil end
function UnitIsPlayer(unit) return units[unit] ~= nil and units[unit].player == true end
function UnitIsUnit(a, b) return a == b end
function UnitIsVisible(unit) return units[unit] ~= nil and units[unit].hidden ~= true end
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
local methods, registered = {}, {}
function methods:SetScript(event, fn) self.scripts = self.scripts or {}; self.scripts[event] = fn end
function methods:RegisterEvent(event) registered[event] = true end
function methods:UnregisterEvent(event) registered[event] = nil end
setmetatable(methods, { __index = function(_, key)
    if key:match("^Set") or key:match("^Register") or key == "Hide" then return function() end end
end })
local frames = {}
function CreateFrame() local f = setmetatable({}, { __index = methods }); frames[#frames + 1] = f; return f end
C_Timer = { After = function() end, NewTicker = function() return {} end,
    NewTimer = function() return { Cancel = function() end } end }
Overlord = { L = {} }
assert(loadfile("Core.lua"))()
local shard = Overlord.Shard
local MARK = shard.MARK
local said = {}
local function syncStub()
    return {
        CanonicalForeverNameFromUnit = function(_, unit) return units[unit] and units[unit].name end,
        GetCaptureContributorDedupKey = function(_, name) return ((name:match("^([^%-]+)") or name):lower()) end,
        BroadcastShard = function(_, id) said[#said + 1] = id end,
    }
end
Overlord.Sync = syncStub()
Overlord.InActiveFront = true

local function see(token, name, more)
    local unit = { player = true, guid = "Player-1-" .. name:gsub("%s", ""), name = name }
    for k, v in pairs(more or {}) do unit[k] = v end
    units[token] = unit
end

-- 1. The order of two marks, the same on every client: a numbered mark wins over one without a
-- number, then the smaller tag, then the higher number of one tag.
assert(shard:MarkWins(900001, 100000) and not shard:MarkWins(100000, 900001), "a numbered mark lost to one without a number")
assert(shard:MarkWins(100005, 900005) and not shard:MarkWins(900005, 100005), "the smaller tag did not win")
assert(shard:MarkWins(100000, 900000), "of two marks without a number, the smaller tag did not win")
assert(shard:MarkWins(500009, 500003) and not shard:MarkWins(500003, 500009) and not shard:MarkWins(500003, 500003),
    "of one tag, the higher number did not win")
assert(shard:SameLayer(500003, 500099) and not shard:SameLayer(500003, 600003) and not shard:SameLayer(nil, 500003)
    and not shard:SameLayer(7, 7), "same tag = same layer, and nothing else")
assert(shard:DisplayCode(4821037) == "OL37" and shard:DisplayCode(4821001) == "OL1" and shard:DisplayCode(4821337) == "OL337"
    and shard:DisplayCode(999999999) == "OL999" and shard:DisplayCode(4821000) == nil
    and shard:DisplayCode(50) == nil and shard:DisplayCode("x") == nil and shard:DisplayCode(nil) == nil
    and shard:DisplayCode(1000000000) == nil and shard:DisplayCode(4821337.5) == nil and shard:DisplayCode(999) == nil, "the code of a mark")

-- 2. On a front a mark of our own is made (no number yet) and said once.
shard:Initialize()
local onEvent
for _, f in ipairs(frames) do if f.scripts and f.scripts.OnEvent then onEvent = f.scripts.OnEvent end end
assert(onEvent, "the events of players in sight are not wired")
assert(registered.NAME_PLATE_UNIT_ADDED and registered.PLAYER_TARGET_CHANGED and registered.UPDATE_MOUSEOVER_UNIT
    and registered.GROUP_JOINED, "an event of players in sight is not listened to")
assert(not registered.VIGNETTES_UPDATED and not registered.PARTY_KILL, "the old layer reading still listens")
local mine = shard:GetCurrentShardID()
assert(mine and mine >= 1000 and mine % 1000 == 0 and mine < 1000000000 and shard:DisplayCode(mine) == nil,
    "no mark of our own on a front: " .. tostring(mine))
assert(#said == 1 and said[1] == mine, "our new mark was not said")

-- A player comes into sight, then says its mark while we see it (GUARD seconds later), and the
-- game shows it again (the pass over the nameplates, or another event).
local function meet(token, name, id, event)
    see(token, name)
    onEvent(nil, event or "NAME_PLATE_UNIT_ADDED", token)
    now = now + MARK.GUARD
    shard:SetPlayerShard(name, id)
    onEvent(nil, event or "NAME_PLATE_UNIT_ADDED", token)
end

-- 3. A mark heard BEFORE its player came into sight is not believed: it may be the mark of the
-- layer that player just left (bench 2026-11-22: such words put one mark on two layers). Said
-- again while we see the player, it becomes ours.
shard:SetMark(700000)
shard:SetPlayerShard("Ann Lee", 500037)
see("nameplate1", "Ann Lee")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate1")
now = now + MARK.GUARD
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(shard:GetCurrentShardID() == 700000, "a mark heard before its player came into sight was believed")
shard:SetPlayerShard("Ann Lee", 500037)
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(shard:GetCurrentShardID() == 700000, "the same player was read twice within the recheck gap")
now = now + MARK.RECHECK
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(shard:GetCurrentShardID() == 500037 and shard:DisplayCode(shard:GetCurrentShardID()) == "OL37",
    "the mark a player said while in sight was not taken: " .. tostring(shard:GetCurrentShardID()))
assert(shard:IsOurLayer(500037) and shard:IsOurLayer(500001), "our own tag is not our layer")
-- (The tag we left is still our layer: its other players have not seen us yet.)
assert(shard:IsOurLayer(700000), "the tag we carried a moment ago is no longer our layer")
-- (A word that came a moment after the nameplate, still on its way when the player appeared, does
-- not count either: GUARD.)
do
    local before = shard:GetCurrentShardID()
    see("nameplate9", "Zoe Quick")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate9")
    now = now + MARK.GUARD - 1
    shard:SetPlayerShard("Zoe Quick", 100001)
    now = now + MARK.RECHECK
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate9")
    assert(shard:GetCurrentShardID() == before, "a word heard right after the nameplate was believed")
    units.nameplate9 = nil
end

-- 4. A weaker mark in sight: ours stays, its tag is proven on our layer. A mark nobody saw
-- proves nothing either way.
meet("target", "Bob Stone", 900000, "PLAYER_TARGET_CHANGED")
assert(shard:GetCurrentShardID() == 500037, "a mark without a number overturned a numbered one")
assert(shard:IsOurLayer(900000) and not shard:IsPlayerOnDifferentShard("Bob Stone"), "a player we saw is not on our layer")
shard:SetPlayerShard("Cid Vale", 800012)
assert(not shard:IsOurLayer(800012) and shard:IsPlayerOnDifferentShard("Cid Vale"), "a mark nobody saw counted as our layer")
assert(not shard:IsPlayerOnDifferentShard("No Body"), "a player without a mark was said to be elsewhere")

-- 5. A stronger mark in sight (smaller tag, numbered): taken.
meet("mouseover", "Dee Moor", 300011, "UPDATE_MOUSEOVER_UNIT")
assert(shard:GetCurrentShardID() == 300011 and shard:IsOurLayer(500037), "the stronger mark in sight was not taken")

-- 6. Our own tag heard with a higher number, without sight: the number of the mark. A lower
-- number, or another tag heard, changes nothing.
-- (Only from that player itself, as the game names it: firstHand. A relayed word does not.)
shard:SetPlayerShard("Eve Hart", 300015)
assert(shard:GetCurrentShardID() == 300011, "a relayed word raised the number of our own mark")
shard:SetPlayerShard("Eve Hart", 300015, true)
assert(shard:GetCurrentShardID() == 300015, "the higher number of our own tag was not taken")
shard:SetPlayerShard("Eve Hart", 300004, true)
shard:SetPlayerShard("Far Away", 100099, true)
shard:SetPlayerShard("Eve Hart", 300567.5, true)
assert(shard:GetCurrentShardID() == 300015, "a mark heard without sight moved ours")

-- 7. Two marks without a number meet: one tag, and a number no mark we hear carries.
for k in pairs(units) do units[k] = nil end
now = now + 40
shard:Update()
shard:SetMark(700000)
meet("nameplate2", "Fay Nox", 600000)
local merged = shard:GetCurrentShardID()
local number = merged % 1000
assert((merged - number) / 1000 == 600 and number >= 1 and number <= 999, "two marks without a number did not become one numbered mark: " .. tostring(merged))
assert(number ~= 37 and number ~= 12 and number ~= 11 and number ~= 15 and number ~= 4 and number ~= 99,
    "the number drawn is one we hear on another mark: " .. number)
-- 7b. The number of a tag is read from the tag: every client that takes this tag shows the same
-- code without a word between them (no channel, no group: two neighbours hear each other
-- rarely). Past a number another tag carries, the next free one; our own tag's number is ours.
assert(number == 600 % 999 + 1, "the number is not the tag's own: " .. number)
do
    local tag = 123456
    local own = tag % 999 + 1
    assert(shard:PickMarkNumber(tag) == own, "the same tag drew another number")
    shard.knownShards["Zed One"], shard.knownShardUpdatedAt["Zed One"] = 777000 + own, now
    assert(shard:PickMarkNumber(tag) == own + 1, "a number another tag carries was drawn again")
    shard.knownShards["Zed One"], shard.knownShardUpdatedAt["Zed One"] = nil, nil
    shard.knownShards["Zed Two"], shard.knownShardUpdatedAt["Zed Two"] = tag * 1000 + own, now
    assert(shard:PickMarkNumber(tag) == own, "our own tag's number was taken for another mark's")
    shard.knownShards["Zed Two"], shard.knownShardUpdatedAt["Zed Two"] = nil, nil
    -- (A 2.6.0 client's chance number, under 100000, is no mark: it takes no number.)
    shard.knownShards["Zed Three"], shard.knownShardUpdatedAt["Zed Three"] = 36000 + own, now
    assert(shard:PickMarkNumber(tag) == own, "a 2.6.0 chance number took a number")
    shard.knownShards["Zed Three"], shard.knownShardUpdatedAt["Zed Three"] = nil, nil
end

-- 8. A player the game stops showing is out of sight: seen again later, a mark it said in
-- between does not count (it may have changed layer and come back into view on another one).
for k in pairs(units) do units[k] = nil end
see("nameplate3", "Gil Roe")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate3")
units.nameplate3 = nil
now = now + MARK.SIGHT_SEC + 1
shard:Update()
assert(next(shard.sight) == nil, "a player the game no longer shows is still in sight")
shard:SetPlayerShard("Gil Roe", 100050)
see("nameplate3", "Gil Roe")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate3")
now = now + MARK.RECHECK
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate3")
assert(shard:GetCurrentShardID() == merged, "a mark said while its player was out of sight was believed")

-- 9. Only players, visible, not ourselves; an NPC proves nothing.
for k in pairs(units) do units[k] = nil end
now = now + 60
shard:Update()
shard:SetMark(700000)
units.nameplate4 = { player = false, guid = "Creature-0-64978-0-800347-10696-9162FA3A6D", name = "Hal Orr" }
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate4")
see("nameplate5", "Hal Orr", { hidden = true })
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate5")
see("player", "Hal Orr")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "player")
now = now + MARK.GUARD
shard:SetPlayerShard("Hal Orr", 200020)
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate4")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate5")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "player")
assert(shard:GetCurrentShardID() == 700000 and next(shard.sight) == nil,
    "a creature, a hidden unit or ourselves counted as a player in sight")
assert(not io.open("Core.lua"):read("*a"):find("ParseLayerIdFromGuid"), "creature GUIDs are still read for a layer")

-- 10. Group mates in range and the players whose nameplate is still up are seen by the upkeep
-- pass, without any event (a nameplate tells us once, when it appears).
grouped = true
for k in pairs(units) do units[k] = nil end
see("party1", "Hal Orr")
now = now + MARK.GROUP_SCAN
shard:Update()
now = now + MARK.GROUP_SCAN
shard:SetPlayerShard("Hal Orr", 200020)
shard:Update()
assert(shard:GetCurrentShardID() == 200020, "a group mate in range was not seen")
grouped = false
do
    units.party1 = nil
    see("nameplate7", "Kim Low")
    C_NamePlate = { GetNamePlates = function() return { { namePlateUnitToken = "nameplate7" } } end }
    now = now + MARK.GROUP_SCAN
    shard:Update()
    now = now + MARK.GROUP_SCAN
    shard:SetPlayerShard("Kim Low", 100060)
    shard:Update()
    assert(shard:GetCurrentShardID() == 100060, "a player whose nameplate stays up was not seen by the upkeep pass")
    C_NamePlate = nil
end

-- 11. Joining a group: the game may move us. The mark is dropped, our peers are told at once
-- (SH 0), the watchers of a hop are told, and nothing is believed for a few seconds.
for k in pairs(units) do units[k] = nil end
now = now + 60
shard:Update()
said = {}
local epoch = shard.layerEpoch
onEvent(nil, "GROUP_JOINED")
assert(shard:GetCurrentShardID() == nil and shard.layerEpoch == epoch + 1, "joining a group kept the mark")
assert(#said == 1 and said[1] == 0, "our peers were not told that our mark is gone")
assert(shard:MarkForCapture() == nil, "a capture named a mark right after joining a group")
see("nameplate6", "Ian Poe")
onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate6")
assert(next(shard.sight) == nil, "a player seen right after joining a group counts as in sight")
now = now + MARK.HOP_QUIET + 0.1
shard:Update()
assert(shard:GetCurrentShardID() == nil, "a mark of our own was made before anybody could be seen")
meet("nameplate6", "Ian Poe", 400040)
assert(shard:GetCurrentShardID() == 400040, "after the quiet seconds a player in sight was not believed")

-- 11b. An Overlord player of another mark (or of none) comes into sight: our own mark is said a
-- few seconds later, so that it counts for that player; one SH for all the newcomers, SAY_GAP
-- apart, never in a large event. A newcomer already known under our tag asks for nothing.
do
    for k in pairs(units) do units[k] = nil end
    now = now + 120
    shard:Update()
    now = now + MARK.SAY_GAP
    said = {}
    for _, name in ipairs({ "Lea Mint", "Max Nord", "Nia Oak", "Pia Quill" }) do shard:SetPlayerShard(name, 0) end
    see("nameplate8", "Lea Mint")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate8")
    see("nameplate9", "Max Nord")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate9")
    shard:Update()
    assert(#said == 0, "our mark was said before it could count for the newcomer")
    now = now + MARK.GUARD + 1
    shard:Update()
    assert(#said == 1 and said[1] == shard:GetCurrentShardID(), "our mark was not said for the players who came into sight: " .. #said)
    see("nameplate10", "Nia Oak")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate10")
    now = now + MARK.GUARD + 1
    shard:Update()
    assert(#said == 1, "two SH for newcomers within the gap")
    now = now + MARK.SAY_GAP
    shard:Update()
    assert(#said == 2, "the newcomer of a moment later was never told our mark")
    shard:SetPlayerShard("Oda Pine", shard:GetCurrentShardID())
    see("nameplate11", "Oda Pine")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate11")
    now = now + MARK.SAY_GAP + 1
    shard:Update()
    assert(#said == 2, "our mark was said for a newcomer who carries it already")
    Overlord.Sync.IsLargeEvent = function() return true end
    see("nameplate12", "Pia Quill")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate12")
    now = now + MARK.SAY_GAP + 1
    shard:Update()
    assert(#said == 2, "our mark was said for a newcomer in a large event")
    Overlord.Sync.IsLargeEvent = nil
end

-- 12. Alone after a hop: a mark of our own once the wait is over; a capture numbers it at once.
for k in pairs(units) do units[k] = nil end
now = now + 60
onEvent(nil, "GROUP_JOINED")
now = now + MARK.HOP_QUIET + MARK.CREATE_WAIT + 0.1
shard:Update()
local alone = shard:GetCurrentShardID()
assert(alone and alone % 1000 == 0, "no mark of our own after the wait")
local named = shard:MarkForCapture()
assert(named and named == shard:GetCurrentShardID() and named % 1000 >= 1 and (named - named % 1000) == alone,
    "our capture does not name a numbered mark: " .. tostring(named))
assert(shard:MarkForCapture() == named, "a second line of the same capture drew another number")

-- 12b. While we capture, our mark does not change: the code the alert showed to everybody stays
-- the code of our own panel. A stronger mark in sight is noted as our layer and taken once the
-- capture is over; our own tag heard with a higher number changes nothing either.
do
    local pinned = shard:MarkForCapture()
    assert(shard:IsMarkPinned(), "our capture does not pin our mark")
    meet("nameplate13", "Rex Stout", 100037)
    assert(shard:GetCurrentShardID() == pinned, "a stronger mark in sight changed the code of our capture: " .. tostring(shard:GetCurrentShardID()))
    assert(shard:IsOurLayer(100037), "the stronger mark seen during our capture is not noted as our layer")
    shard:SetPlayerShard("Sam Tull", pinned - pinned % 1000 + 999, true)
    assert(shard:GetCurrentShardID() == pinned, "a higher number of our tag changed the code of our capture")
    -- (Each line of the capture keeps the pin; it ends PIN_SEC after the last one.)
    now = now + MARK.PIN_SEC - 1
    assert(shard:MarkForCapture() == pinned and shard:IsMarkPinned(), "a later line of the capture changed or freed its code")
    now = now + MARK.PIN_SEC + 1
    assert(not shard:IsMarkPinned(), "the pin outlived the capture")
    shard:SetPlayerShard("Rex Stout", 100037)
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate13")
    assert(shard:GetCurrentShardID() == 100037, "after the capture the stronger mark in sight was not taken")
    -- (A sign of a layer change frees the mark at once, capture or not.)
    shard:MarkForCapture()
    onEvent(nil, "GROUP_JOINED")
    assert(shard:GetCurrentShardID() == nil and not shard:IsMarkPinned(), "joining a group during a capture kept its mark")
    for k in pairs(units) do units[k] = nil end
    now = now + MARK.HOP_QUIET + MARK.CREATE_WAIT + 0.1
    shard:Update()
    shard:MarkForCapture()
end

-- 12c. What the audit of 2026-11-22 found.
do
    local function fresh(mark)
        for k in pairs(units) do units[k] = nil end
        now = now + 200
        shard:Update()
        shard:SetMark(mark)
    end
    -- A value the released 2.6.0 still sends (a creature's number, under 65536) is no mark: it
    -- would win over every real one, and only 65 tags exist down there.
    assert(shard:ValidMark(64978) == nil and shard:ValidMark(99999) == nil and shard:ValidMark(100000) == 100000
        and shard:DisplayCode(64978) == nil and not shard:SameLayer(64978, 64001), "a 2.6.0 value passes for a mark")
    fresh(700000)
    meet("nameplate20", "Old Client", 64978)
    assert(shard:GetCurrentShardID() == 700000 and not shard:IsOurLayer(64978), "a 2.6.0 value in sight was merged with")
    for _ = 1, 50 do
        local id = shard:MarkForCapture()
        assert(id >= 100000, "a mark of our own under the floor: " .. tostring(id))
        now = now + MARK.PIN_SEC + 1
        shard:SetMark(nil)
        shard:Update()
    end
    -- A relayed copy of a word said BEFORE its player came into sight, delivered after: it is
    -- judged by the time it was said, not the time it arrived.
    fresh(700000)
    see("nameplate21", "Late Word")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate21")
    now = now + 30
    shard:SetPlayerShard("Late Word", 100777, false, now - 40)
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate21")
    assert(shard:GetCurrentShardID() == 700000 and not shard:IsOurLayer(100777), "a word said before its player came into sight was believed")
    -- (An older copy of its own word never replaces a newer one.)
    shard:SetPlayerShard("Late Word", 0, false, now - 5)
    shard:SetPlayerShard("Late Word", 100777, false, now - 20)
    assert(shard.saidMarks["Late Word"] == 0 and shard:GetKnownPlayerShard("Late Word") == 0, "an older copy replaced a newer word")
    -- Somebody else's word about a player (a capture line relayed by a third player) is never
    -- merged with, and never replaces that player's own word.
    fresh(700000)
    see("nameplate22", "Third Hand")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate22")
    now = now + MARK.GUARD
    shard:SetPlayerShard("Third Hand", 100888, false, false)
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate22")
    assert(shard:GetCurrentShardID() == 700000 and not shard:IsOurLayer(100888), "somebody else's word about a player in sight was merged with")
    assert(shard:GetKnownPlayerShard("Third Hand") == 100888 and shard.saidMarks["Third Hand"] == nil, "somebody else's word is not kept apart")
    now = now + MARK.RECHECK
    shard:SetPlayerShard("Third Hand", 100555)
    shard:SetPlayerShard("Third Hand", 100888, false, false)
    assert(shard:GetKnownPlayerShard("Third Hand") == 100555, "somebody else's word replaced the player's own")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate22")
    assert(shard:GetCurrentShardID() == 100555, "the player's own word, said in sight, was not taken")
    -- A value that is not a whole number is nothing at all.
    assert(shard:SetPlayerShard("Bad Value", 100555.5) == false and shard:GetKnownPlayerShard("Bad Value") == nil, "a fraction was stored")
    -- A newcomer we never heard of asks for no SH; an Overlord player without a mark does.
    fresh(700000)
    now = now + MARK.SAY_GAP
    shard:Update()
    now = now + MARK.SAY_GAP
    said = {}
    see("nameplate23", "No Addon")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate23")
    now = now + MARK.GUARD + 1
    shard:Update()
    assert(#said == 0, "our mark was said for a newcomer we never heard of")
    shard:SetPlayerShard("Has Addon", 0)
    see("nameplate24", "Has Addon")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate24")
    now = now + MARK.GUARD + 1
    shard:Update()
    assert(#said == 1, "our mark was not said for an Overlord player who holds none")
    -- During our capture: a zone border crossed without a loading screen, a context key that
    -- flips, the first upkeep pass and a friend who accepts our invitation all keep the code
    -- the alert named. A loading screen, a phase change and being invited do not.
    fresh(700000)
    local code = shard:MarkForCapture()
    shard:InvalidateLocalContext(true)
    assert(shard:GetCurrentShardID() == code and shard:IsMarkPinned(), "a zone border crossed during our capture changed its code")
    Overlord.Fronts = { GetCurrentFront = function() return { id = "arathi" } end }
    shard:Update()
    assert(shard:GetCurrentShardID() == code and shard.localContextKey == "front:arathi", "the first upkeep pass of a capture dropped its code")
    -- (A key that flips to an outpost's map and back keeps it; another FRONT does not: that is
    -- another map, perhaps another layer.)
    shard:RefreshLocalContext("outpost:arathi_keep", true)
    shard:RefreshLocalContext("front:arathi", true)
    assert(shard:GetCurrentShardID() == code and shard:IsMarkPinned(), "a context key that flips during our capture changed its code")
    Overlord.Fronts = { GetCurrentFront = function() return { id = "hillsbrad" } end }
    said = {}
    shard:Update()
    assert(shard:GetCurrentShardID() == nil and said[1] == 0, "the pinned mark of a capture was carried to another front")
    now = now + MARK.CREATE_WAIT + 0.1
    code = shard:MarkForCapture()
    assert(code and shard.localContextKey == "front:hillsbrad", "fixture: a capture on the new front")
    Overlord.Fronts = { GetCurrentFront = function() return { id = "arathi_cave" } end }
    UnitIsGroupLeader = function() return true end
    onEvent(nil, "GROUP_JOINED")
    assert(shard:GetCurrentShardID() == code, "a friend who accepts our invitation changed the code of our capture")
    UnitIsGroupLeader = function() return false end
    said = {}
    onEvent(nil, "GROUP_JOINED")
    assert(shard:GetCurrentShardID() == nil and said[1] == 0, "being invited during a capture kept its mark")
    now = now + MARK.HOP_QUIET + 0.1
    code = shard:MarkForCapture()
    assert(code and shard.localContextKey == "front:arathi_cave", "a capture did not settle its context before naming its mark")
    -- (Our mark is said for an Overlord player of this version, never for the chance number a
    -- 2.6.0 client still sends.)
    do
        now = now + MARK.SAY_GAP + MARK.PIN_SEC
        shard:Update()
        now = now + MARK.SAY_GAP
        said = {}
        shard:SetPlayerShard("Old Number", 31234)
        see("nameplate40", "Old Number")
        onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate40")
        now = now + MARK.GUARD + 1
        shard:Update()
        assert(#said == 0, "our mark was said for the chance number of a 2.6.0 client")
        units.nameplate40 = nil
    end
    shard:InvalidateLocalContext()
    assert(shard:GetCurrentShardID() == nil and not shard:IsMarkPinned(), "a loading screen during a capture kept its mark")
    Overlord.Fronts, UnitIsGroupLeader = nil, nil
    shard:RefreshLocalContext("", true)
    -- No SH 0 at the door of an instance.
    fresh(700000)
    said = {}
    IsInInstance = function() return true end
    assert(shard:TellMarkGone() == false and #said == 0, "an SH 0 left at the door of an instance")
    IsInInstance = nil
    -- A full sight table is walked once a second at most, and a row is whole when stored.
    fresh(700000)
    for i = 1, MARK.SIGHT_MAX do shard.sight["Player-1-Fill" .. i] = { name = "Fill " .. i, at = now, since = now, checkedAt = now } end
    shard.sightCount = MARK.SIGHT_MAX
    local walks, realPrune = 0, shard.PruneSight
    shard.PruneSight = function(self, at) walks = walks + 1; return realPrune(self, at) end
    for i = 1, 20 do
        see("nameplate30", "Crowd " .. i)
        onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate30")
    end
    assert(walks == 1, "a full sight table was walked " .. walks .. " times in one second")
    shard.PruneSight = realPrune
    fresh(700000)
    see("nameplate31", "Whole Row")
    onEvent(nil, "NAME_PLATE_UNIT_ADDED", "nameplate31")
    local _, row = next(shard.sight)
    assert(row and row.checkedAt and row.since and row.at, "a sight row is stored without its times")
    -- (Back to a numbered mark of our own, as the next case expects.)
    fresh(700000)
    shard:MarkForCapture()
end

-- 13. A numbered mark nobody confirmed for a long time is dropped (peers told), then made anew.
said = {}
now = now + MARK.RELEASE_SEC + 1
shard:Update()
assert(shard:GetCurrentShardID() == nil and said[#said] == 0, "a mark nobody confirmed kept its number")
now = now + MARK.CREATE_WAIT + 0.1
shard:Update()
assert(shard:GetCurrentShardID() ~= nil and shard:GetCurrentShardID() % 1000 == 0, "no new mark after the old one was dropped")

-- 14. A phase change of the player and another front: the mark is dropped, peers told.
do
    now = now + 60
    said = {}
    shard:SetMark(500037)
    shard:NoteHop()
    assert(shard:GetCurrentShardID() == nil and said[1] == 0, "a phase change kept the mark")
    now = now + 60
    said = {}
    shard:SetMark(500037)
    shard:RefreshLocalContext("front:other", true)
    assert(shard:GetCurrentShardID() == nil and said[1] == 0 and next(shard.sight) == nil and next(shard.aliases) == nil,
        "another front kept the mark, or what was seen on the first one")
    shard:RefreshLocalContext("", true)
end

-- 15. Off the fronts no mark is carried.
now = now + 60
shard:Update()
assert(shard:GetCurrentShardID() ~= nil, "fixture: no mark on a front")
Overlord.InActiveFront = false
local active = shard:Update()
assert(active == false and shard:GetCurrentShardID() == nil and shard:MarkForCapture() == nil, "a mark was carried off the fronts")
Overlord.InActiveFront = true

-- 16. A mark changes are said at most every BROADCAST_GAP seconds, then every minute.
do
    now = now + 120
    said = {}
    shard:Update()
    local first = #said
    assert(first == 1, "a new mark was not said: " .. first)
    shard:SetMark(shard:GetCurrentShardID() + 7)
    now = now + 1
    shard:Update()
    assert(#said == first, "two SH within the gap")
    now = now + MARK.BROADCAST_GAP
    shard:Update()
    assert(#said == first + 1 and said[#said] == shard:GetCurrentShardID(), "the changed mark was not said after the gap")
    now = now + 30
    shard:Update()
    assert(#said == first + 1, "an unchanged mark was said before its minute")
    now = now + 31
    shard:Update()
    assert(#said == first + 2, "the minute's word was not said")
end

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


print("Layers OL: order of marks, merge by sight, numbers, stale words, hop, release, index of known players OK")
