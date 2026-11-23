-- 2.7.0 ("Capturer spotted", CaptorSpot.lua): an enemy who captures a point of the front we stand
-- on is followed by name from the capture lines received; once the game shows him, his faction's
-- banner is put on his nameplate and one chat line says he is in sight. Nothing is sent, the
-- nameplate events are listened to only while a capturer is followed, nothing in an instance, and
-- our own map decides whether there is a capture to show.
local now = 1000
function GetTime() return now end
local inInstance = false
function IsInInstance() return inInstance end
function GetLocale() return "enUS" end

local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end }
-- (Time passes: the timers due run, in order.)
local function advance(sec)
    local target = now + sec
    while true do
        local best
        for i, t in ipairs(timers) do
            if t.at <= target and (not best or t.at < timers[best].at) then best = i end
        end
        if not best then break end
        local t = table.remove(timers, best)
        now = math.max(now, t.at)
        t.fn()
    end
    now = target
end
local function pending(short)
    local count = 0
    for _, t in ipairs(timers) do
        if (t.at - now < 1) == short then count = count + 1 end
    end
    return count
end

local function stubFrame(parent)
    local f = { parent = parent, events = {} }
    function f:SetSize() end
    function f:SetPoint(point, anchor, rel, x) self.point, self.anchor, self.rel, self.x = point, anchor, rel, x end
    function f:ClearAllPoints() self.anchor = nil end
    function f:SetParent(p) self.parent = p end
    function f:GetParent() return self.parent end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown == true end
    function f:SetScript(name, fn) self[name] = fn end
    function f:RegisterEvent(event) self.events[event] = true end
    function f:UnregisterEvent(event) self.events[event] = nil end
    function f:CreateTexture()
        local tex = {}
        function tex:SetAllPoints() end
        function tex:SetTexCoord() end
        function tex:SetTexture(path) f.texture = path end
        return tex
    end
    return f
end
function CreateFrame(_, _, parent) return stubFrame(parent) end

local printed = {}
local units, plates, shownPlates = {}, {}, {}
function UnitIsPlayer(unit) return units[unit] ~= nil and units[unit].player ~= false end
function UnitFactionGroup(unit) return units[unit] and units[unit].faction end
C_NamePlate = {
    GetNamePlateForUnit = function(unit) return plates[unit] end,
    GetNamePlates = function() return shownPlates end,
}
local nameReads = 0
local frontZones = {
    arathi_a = { id = "arathi_a", name = "Stromgarde", status = "in_progress", owner = "Horde" },
    arathi_b = { id = "arathi_b", name = "Hammerfall", status = "in_progress", owner = "Horde" },
}
-- (As Sync.lua: "First Last", whatever follows a hyphen or an escape character is dropped.)
local function canon(_, name)
    if type(name) ~= "string" then return nil end
    local base = (name:match("^([^|%-]*)") or ""):match("^%s*(.-)%s*$")
    if not base:find("^%S+ %S+$") then return nil end
    return base
end
local scope = true
Overlord = {
    PlayerFaction = "Alliance",
    InActiveFront = true,
    InstanceSuspended = false,
    L = {},
    ServerNow = function() return 1700000000 + math.floor(now) end,
    PrintNotification = function(_, text) printed[#printed + 1] = text end,
    EnemyFactionChatIcon = function() return "<H> " end,
    ShouldShowZoneAlert = function() return scope end,
    Zones = { GetZone = function(_, id) return frontZones[id] end },
    Sync = {
        CanonicalForeverName = canon,
        CanonicalForeverNameFromUnit = function(_, unit)
            nameReads = nameReads + 1
            return units[unit] and units[unit].name
        end,
    },
}
assert(loadfile("Locales.lua"))()
local L = Overlord.L
assert(loadfile("CaptorSpot.lua"))()
local Spot = Overlord.CaptorSpot
local frame = Spot.frame
local function fire(event, unit) frame.OnEvent(frame, event, unit) end
local function listening() return next(frame.events) ~= nil end
local function plate(unit, name, faction, player)
    units[unit] = { name = name, faction = faction, player = player }
    plates[unit] = plates[unit] or { namePlateUnitToken = unit, UnitFrame = { healthBar = {} } }
end

-- 1. Nobody followed: no event is listened to, a nameplate reads no name.
assert(frame and not listening() and Spot.count == 0, "events are listened to with nobody followed")
plate("nameplate1", "Gerard Capturer", "Horde")
Spot:OnUnit("nameplate1", true)
assert(nameReads == 0 and #printed == 0 and Spot.icons.nameplate1 == nil, "a name was read with nobody followed")

-- 2. An enemy capture line on our front: he is followed, the events come in. His nameplate comes
-- up: the Horde banner left of his health bar, one chat line with his name and the point.
assert(Spot:Note("arathi_a", "Gerard Capturer") == true and Spot.count == 1 and listening(), "an enemy capturer is not followed")
assert(frame.events.NAME_PLATE_UNIT_ADDED and frame.events.NAME_PLATE_UNIT_REMOVED and frame.events.PLAYER_TARGET_CHANGED,
    "an event is missing while a capturer is followed")
fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local icon = Spot.icons.nameplate1
assert(icon and icon.shown and icon.parent == plates.nameplate1.UnitFrame and icon.anchor == plates.nameplate1.UnitFrame.healthBar
    and icon.point == "RIGHT" and icon.rel == "LEFT" and icon.x == -3, "no banner next to the health bar of the capturer in sight")
assert(icon.texture == "Interface\\Icons\\INV_BannerPVP_01", "not the banner of his faction: " .. tostring(icon.texture))
assert(#printed == 1 and printed[1]:find(string.format(L.CAPTOR_SPOTTED, "Gerard Capturer", "Stromgarde"), 1, true),
    "the chat does not say the capturer is in sight: " .. tostring(printed[1]))
assert(printed[1]:find("on your layer", 1, true), "the line does not say he is on our layer")

-- 3. Never a flood: the same capturer coming back into sight prints nothing for three minutes,
-- while his banner comes back every time; a nameplate given to another unit loses the banner.
fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
assert(not icon.shown, "the banner stayed on a nameplate that left")
advance(20)
Spot:Note("arathi_a", "Gerard Capturer")
fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(icon.shown and #printed == 1, "the line was printed again for the same capturer")
plate("nameplate1", "Some Bystander", "Horde")
fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
assert(not icon.shown and #printed == 1, "a bystander took the banner of the capturer")
-- (A creature, a player of our side with the same name: nothing, and no name read for a creature.)
local readsBefore = nameReads
plate("nameplate2", "Gerard Capturer", "Horde", false)
fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
assert(nameReads == readsBefore and Spot.icons.nameplate2 == nil, "a creature's name was read")
plate("nameplate2", "Gerard Capturer", "Alliance")
fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
assert(Spot.icons.nameplate2 == nil, "a player of our side was marked")

-- 4. Two capturers coming into sight within ten seconds: two banners, one line, and the one that
-- line did not name stays silent at the later looks (a raid of capturers is one line).
plate("nameplate3", "Second Capturer", "Horde")
plate("nameplate1", "Gerard Capturer", "Horde")
advance(200)
assert(Spot.count == 0 and not listening(), "fixture: the first capturer should have expired")
Spot:Note("arathi_a", "Gerard Capturer")
Spot:Note("arathi_b", "Second Capturer")
fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
assert(Spot.icons.nameplate1.shown and Spot.icons.nameplate3.shown and #printed == 2,
    "two capturers within ten seconds: " .. #printed .. " lines")
assert(printed[2]:find("Gerard Capturer", 1, true), "the second line names the wrong capturer")
shownPlates = { plates.nameplate1, plates.nameplate3 }
advance(32)
assert(Spot.icons.nameplate1.shown and Spot.icons.nameplate3.shown and #printed == 2,
    "the capturer the line did not name was announced at a later look: " .. #printed)

-- 5. He stands in front of us before his first line: the nameplates are looked at once, shortly
-- after (the capture sync applies the line to the map in between), and once for all the lines of
-- that moment. Our target counts too, without any nameplate.
Spot:Clear()
assert(Spot.count == 0 and not listening() and not Spot.icons.nameplate1.shown, "Clear left something")
advance(600)
assert(#timers == 0, "a timer keeps running with nobody followed: " .. #timers)
printed = {}
plate("nameplate4", "Early Capturer", "Horde")
shownPlates = { plates.nameplate4, plates.nameplate3 }
Spot:Note("arathi_a", "Early Capturer")
Spot:Note("arathi_b", "Other Capturer")
assert(Spot.icons.nameplate4 == nil and pending(true) == 1, "the nameplates are not looked at once for the lines of a moment: " .. pending(true))
advance(0.3)
assert(Spot.icons.nameplate4 and Spot.icons.nameplate4.shown and #printed == 1 and printed[1]:find("Early Capturer", 1, true),
    "a capturer already in sight is not marked after his first line")
assert(not Spot.icons.nameplate3.shown, "a capturer no longer followed kept his banner")
advance(0.5)
readsBefore = nameReads
Spot:Note("arathi_a", "Early Capturer")
assert(nameReads == readsBefore and pending(true) == 0, "the nameplates are walked again at every line of a followed capturer")
shownPlates = {}
advance(300)
Spot:Note("arathi_b", "Target Capturer")
units.target = { name = "Target Capturer", faction = "Horde" }
fire("PLAYER_TARGET_CHANGED")
assert(#printed == 2 and printed[2]:find(string.format(L.CAPTOR_SPOTTED, "Target Capturer", "Hammerfall"), 1, true)
    and Spot.icons.target == nil, "a capturer we target is not announced, or a banner was made without a nameplate")
units.target = nil

-- 6. A Nemesis who captures wears both: the banner goes left of the skull, whichever came first,
-- and takes its place back when the skull leaves.
do
    local skullShown = false
    Overlord.MostWanted = { SKULL_SIZE = 16, skulls = { nameplate4 = { IsShown = function() return skullShown end } } }
    shownPlates = { plates.nameplate4 }
    Spot:Note("arathi_a", "Early Capturer")
    fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
    assert(Spot.icons.nameplate4.shown and Spot.icons.nameplate4.x == -3, "fixture: the banner alone is not next to the bar")
    skullShown = true
    advance(0.3)
    assert(Spot.icons.nameplate4.x == -3 - 18, "the banner is drawn over a skull shown just after it: " .. tostring(Spot.icons.nameplate4.x))
    skullShown = false
    advance(16)
    assert(Spot.icons.nameplate4.shown and Spot.icons.nameplate4.x == -3, "the banner kept the gap of a skull that left")
    Overlord.MostWanted = nil
end

-- 7. Without a line for 135 seconds he is no longer followed (the other faction's lines come
-- every 15 s per point, every 60 s in a large event): his banner leaves, and with nobody left the
-- events leave too. One sweep timer at a time while somebody is followed, none after.
Spot:Clear()
advance(600)
assert(#timers == 0, "a timer keeps running after Clear: " .. #timers)
shownPlates = { plates.nameplate4 }
Spot:Note("arathi_a", "Early Capturer")
assert(pending(false) == 1, "one sweep timer while a capturer is followed: " .. pending(false))
advance(0.3)
assert(Spot.icons.nameplate4.shown, "fixture: the capturer in sight is not marked")
advance(100)
Spot:Note("arathi_a", "Early Capturer")
advance(120)
assert(Spot.count == 1 and Spot.icons.nameplate4.shown and listening() and pending(false) == 1,
    "a capturer whose lines come once a minute was let go")
advance(30)
assert(Spot.count == 0 and not Spot.icons.nameplate4.shown and not listening(), "a capturer silent for 135 seconds is still followed")
advance(120)
assert(#timers == 0, "a timer keeps running with nobody followed: " .. #timers)
plate("nameplate5", "Early Capturer", "Horde")
fire("NAME_PLATE_UNIT_ADDED", "nameplate5")
assert(Spot.icons.nameplate5 == nil, "a capturer no longer followed was marked")

-- 8. Our own map decides whether there is a capture to show: a line that came late (the point is
-- ours again), the capturer of hours ago named by a map answer, a capture given up, the front
-- left: nobody is marked. The man who took the point moments ago still is.
do
    local a = frontZones.arathi_a
    local before = #printed
    a.status, a.owner, a.capturedTime = "captured", "Alliance", Overlord.ServerNow() - 5
    assert(Spot:Note("arathi_a", "Early Capturer") == true, "fixture: the line is not followed")
    advance(0.3)
    assert(not Spot.icons.nameplate4.shown and #printed == before, "a late line marked a capturer on a point that is ours again")
    a.owner, a.capturedTime = "Horde", Overlord.ServerNow() - 20
    advance(16)
    assert(Spot.icons.nameplate4.shown, "the man who took the point moments ago is not marked")
    a.capturedTime = Overlord.ServerNow() - 7200
    advance(16)
    assert(not Spot.icons.nameplate4.shown, "the capturer of two hours ago is marked")
    a.status, a.capturedTime = "in_progress", nil
    advance(16)
    assert(Spot.icons.nameplate4.shown, "fixture: the capture in progress is not marked")
    a.status, a.owner = "available", nil
    advance(16)
    assert(not Spot.icons.nameplate4.shown, "a capture given up keeps its banner")
    a.status, a.owner = "in_progress", "Horde"
    advance(16)
    assert(Spot.icons.nameplate4.shown, "fixture: the capture in progress is not marked again")
    Overlord.InActiveFront = false
    fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
    assert(not Spot.icons.nameplate4.shown, "a capturer is marked off the fronts")
    Overlord.InActiveFront = true
end

-- 9. Only where he can be seen: a point of another front, off the fronts, a name that is nobody's,
-- an instance. Never more than MAX capturers followed; a name the game never showed gives way to
-- a new one when the table is full, a name it showed does not; the expired ones leave.
Spot:Clear()
assert(Spot:Note("tanaris_a", "Far Capturer") == false, "a capturer of another front is followed")
Overlord.InActiveFront = false
assert(Spot:Note("arathi_a", "Far Capturer") == false, "a capturer is followed off the fronts")
Overlord.InActiveFront = true
assert(Spot:Note("arathi_a", "Nobody") == false and Spot:Note("arathi_a", nil) == false and Spot:Note(nil, "Far Capturer") == false,
    "a line without a usable name or point is followed")
inInstance = true
assert(Spot:Note("arathi_a", "Far Capturer") == false and Spot.count == 0, "a capturer is followed in an instance")
inInstance = false
for i = 1, Spot.MAX do Spot:Note("arathi_a", "Crowd " .. string.char(64 + i) .. "x") end
assert(Spot.count == Spot.MAX, "fixture: the table is not full: " .. Spot.count)
assert(Spot:Note("arathi_a", "Late Capturer") == true and Spot.count == Spot.MAX and Spot.byKey["late capturer"],
    "names the game never showed keep a new capturer out")
for _, row in pairs(Spot.byKey) do row.seen = true end
assert(Spot:Note("arathi_a", "Another Capturer") == false and Spot.count == Spot.MAX, "a capturer the game showed gave way, or the cap was passed")
advance(Spot.KEEP_SEC + 16)
assert(Spot.count == 0 and not listening(), "expired capturers are still followed")
assert(Spot:Note("arathi_a", "Early Capturer") == true and Spot.count == 1, "fixture: nobody followed again")
-- (The door of an instance: the events are still there, no unit is read.)
inInstance = true
readsBefore = nameReads
fire("NAME_PLATE_UNIT_ADDED", "nameplate4")
units.target = { name = "Early Capturer", faction = "Horde" }
fire("PLAYER_TARGET_CHANGED")
units.target = nil
assert(nameReads == readsBefore and not Spot.icons.nameplate4.shown, "a unit was read at the door of an instance")
inInstance = false
Spot:OnInstanceSuspend()
assert(Spot.count == 0 and not listening(), "an instance left a capturer followed or an event listened to")
for _, f in pairs(Spot.icons) do assert(not f.shown, "a banner stayed visible in an instance") end
Spot:OnInstanceResume()
assert(not listening(), "the events came back with nobody followed")

-- 10. Only the canonical name is kept and printed: whatever a sender wrote around it never
-- reaches the chat, and an escape character could open no colour nor link there.
do
    advance(600)
    printed = {}
    Spot:Note("arathi_a", "Bad Name-Buy gold at example dot com")
    Spot:Note("arathi_b", "Other Name|cFFFF0000 junk")
    assert(Spot.byKey["bad name"] and Spot.byKey["bad name"].name == "Bad Name" and Spot.byKey["other name"]
        and Spot.byKey["other name"].name == "Other Name", "a name is kept as its sender wrote it")
    units.target = { name = "Bad Name", faction = "Horde" }
    fire("PLAYER_TARGET_CHANGED")
    assert(#printed == 1 and printed[1]:find(string.format(L.CAPTOR_SPOTTED, "Bad Name", "Stromgarde"), 1, true)
        and not printed[1]:find("gold", 1, true), "text written around a name reached the chat: " .. tostring(printed[1]))
    Overlord.Sync.CanonicalForeverName = function(_, name) return name end
    Spot:Note("arathi_b", "Pipe |cFFFF0000Name")
    advance(11)
    units.target = { name = "Pipe |cFFFF0000Name", faction = "Horde" }
    fire("PLAYER_TARGET_CHANGED")
    assert(#printed == 2 and printed[2]:find("Pipe ||cFFFF0000Name", 1, true), "an escape character of a name reached the chat: " .. tostring(printed[2]))
    Overlord.Sync.CanonicalForeverName = canon
    units.target = nil
    Spot:Clear()
end

-- 11. The chat line stays within the alert scope the player chose; hidden, it marks nothing and
-- comes once the scope allows it. The banner does not depend on it.
do
    advance(600)
    printed = {}
    scope = false
    shownPlates = { plates.nameplate4 }
    Spot:Note("arathi_a", "Early Capturer")
    advance(0.3)
    assert(Spot.icons.nameplate4.shown and #printed == 0, "the line ignores the alert scope, or the banner follows it")
    scope = true
    advance(16)
    assert(#printed == 1, "a line hidden by the scope never came back")
    Spot:Clear()
end

-- 12. A Horde player sees the Alliance banner on an Alliance capturer.
do
    Overlord.PlayerFaction = "Horde"
    frontZones.arathi_b.owner = "Alliance"
    plate("nameplate6", "Ally Capturer", "Alliance")
    Spot:Note("arathi_b", "Ally Capturer")
    fire("NAME_PLATE_UNIT_ADDED", "nameplate6")
    assert(Spot.icons.nameplate6 and Spot.icons.nameplate6.shown and Spot.icons.nameplate6.texture == "Interface\\Icons\\INV_BannerPVP_02",
        "not the Alliance banner for a Horde player")
    Overlord.PlayerFaction = "Alliance"
    frontZones.arathi_b.owner = "Horde"
    Spot:Clear()
end

-- 12b. (Audit 2026-11-23) Anybody may relay a line with any name in it. While our map holds the
-- capturer of the point, a line naming somebody else marks nobody; a final line never brings in
-- a name the capture's lines under way did not name.
do
    advance(600)
    printed = {}
    frontZones.arathi_a.zsRelayCapturerName = "Real Capturer"
    plate("nameplate7", "Innocent Bystander", "Horde")
    assert(Spot:Note("arathi_a", "Innocent Bystander") == true, "fixture: the line is not followed")
    fire("NAME_PLATE_UNIT_ADDED", "nameplate7")
    assert(not (Spot.icons.nameplate7 and Spot.icons.nameplate7.shown) and #printed == 0,
        "a player our map does not name as the capturer was marked")
    plate("nameplate8", "Real Capturer-Some Realm", "Horde")
    units.nameplate8.name = "Real Capturer"
    Spot:Note("arathi_a", "Real Capturer")
    fire("NAME_PLATE_UNIT_ADDED", "nameplate8")
    assert(Spot.icons.nameplate8 and Spot.icons.nameplate8.shown and #printed == 1, "the capturer our map names is not marked")
    frontZones.arathi_a.zsRelayCapturerName = nil
    assert(Spot:Note("arathi_a", "Final Stranger", true) == false and Spot.byKey["final stranger"] == nil,
        "a final line brought in a new name")
    assert(Spot:Note("arathi_a", "Real Capturer", true) == true, "the final line of a followed capturer is dropped")
    Spot:Clear()
end

-- 13. The wiring: the file is loaded, Sync hands over the enemy capture lines that passed its
-- gates (behind a pcall), an instance and leaving the front stop it, the rank badge makes room,
-- nothing is sent, no method of the game is hooked.
local function read(path) local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text end
assert(read("Overlord.toc"):find("\nCaptorSpot%.lua\r?\n"), "the module is not loaded")
local sync = read("Sync.lua")
local hook = sync:find("pcall(Overlord.CaptorSpot.Note, Overlord.CaptorSpot, zoneId, zsCapturerName,\n", 1, true)
    or sync:find("pcall(Overlord.CaptorSpot.Note, Overlord.CaptorSpot, zoneId, zsCapturerName,\r\n", 1, true)
assert(sync:find('wireStatus == "captured")', hook or 1, true), "the final line is not told apart")
local gate = sync:find("priv.NoteLineMark(zoneId, zsCapturerName, zsCapturerShard, sender, sourceChannel, ts,", 1, true)
assert(hook and gate and hook > gate and hook - gate < 900, "the capture lines are not handed over where they passed the gates")
assert(sync:find("if Overlord.CaptorSpot and owner and owner == Overlord.Zones:GetEnemyFaction() then", 1, true),
    "a capturer of our own side is handed over")
local core = read("Core.lua")
assert(core:find("pcall%(self%.CaptorSpot%.OnInstanceSuspend, self%.CaptorSpot%)")
    and core:find("pcall%(Overlord%.CaptorSpot%.OnInstanceResume, Overlord%.CaptorSpot%)"), "an instance does not stop the module")
assert(core:find("pcall%(self%.CaptorSpot%.Clear, self%.CaptorSpot%)"), "leaving the front does not stop the module")
assert(read("RankProof.lua"):find("spot.icons[frame.unit]", 1, true), "the rank badge does not make room for the banner")
local own = read("CaptorSpot.lua")
for _, word in ipairs({ "SendAddonMessage", "SendChatMessage", "RegisterAddonMessagePrefix", "hooksecurefunc", "HookScript",
    "OnUpdate", "NewTicker", "COMBAT_LOG", "UPDATE_MOUSEOVER_UNIT" }) do
    assert(not own:find(word, 1, true), "CaptorSpot.lua holds " .. word)
end

-- 14. Its texts exist in seven languages with the marks their format needs, the window of Layers
-- OL explains it, and so does the tutorial, in its seven languages.
do
    local wanted = { CAPTOR_SPOTTED = 2, LJ_EXPLAIN_SPOT = 0 }
    local seen = {}
    for _, path in ipairs({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua", "ForeverLocaleFixes.lua" }) do
        local text = read(path)
        for key, marks in pairs(wanted) do
            for line in text:gmatch("\n%s*L%." .. key .. "%s*=%s*(\"[^\n]+\")") do
                seen[key] = (seen[key] or 0) + 1
                local value = assert(loadstring("return " .. line))()
                local _, count = value:gsub("%%s", "")
                assert(count == marks and #value > 20 and not value:find("%%[^s]"), key .. " in " .. path .. ": " .. value)
            end
        end
    end
    for key in pairs(wanted) do assert(seen[key] == 7, key .. " in seven languages: " .. tostring(seen[key])) end
    assert(read("LayerJumper.lua"):find('"LJ_EXPLAIN_3", "LJ_EXPLAIN_SPOT", "LJ_EXPLAIN_4"', 1, true),
        "the Layers OL window does not explain the capturer in sight")
    local guide = read("GuideLocales.lua")
    for _, words in ipairs({ "his nameplate wears his faction's banner", "sa barre de nom porte la bannière de sa faction",
        "su placa de nombre lleva el estandarte", "trägt seine Namensplakette das Banner", "появляется знамя его фракции",
        "a placa de nome dele recebe o estandarte", "他的姓名板上会出现其阵营的旗帜" }) do
        assert(guide:find(words, 1, true), "the tutorial does not explain the capturer in sight: " .. words)
    end
end

print("Capturer spotted: banner on the nameplate, one chat line, no flood, the map decides, events only while followed, instance, wiring, seven languages OK")
