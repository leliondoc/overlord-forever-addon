-- CaptorSpot.lua: "Capturer spotted" (Overlord Forever).
--
-- 2.7.0: a capture alert names an enemy capturer and the code of his layer (Layers OL, Core.lua).
-- The code tells from afar; this file tells on the spot: once the game itself shows us that
-- capturer, he is on our layer, and nothing proves it better.
--   * An enemy who captures a point of the front we stand on is followed by name, from the capture
--     lines the addon receives anyway (Sync.lua). Nothing is sent, nothing is asked.
--   * When his nameplate comes up, the banner of his faction is put left of his health bar and one
--     chat line says he is in sight. Our target counts too (nameplates may be turned off).
--   * Only while our own map shows his point under enemy capture, or taken moments ago: a line
--     that came late, or one that names the capturer of hours ago, marks nobody.
--   * The nameplate and target events are listened to only while a capturer is followed.
--   * Nothing in an instance, nothing off the fronts.

Overlord = Overlord or {}
local Spot = Overlord.CaptorSpot or {}
Overlord.CaptorSpot = Spot

-- Followed that long after his last capture line. The lines of the other faction reach us by the
-- relay: one per point every 15 s, every 60 s in a large event (Sync.lua, BroadcastZoneState);
-- two of those may be missed.
Spot.KEEP_SEC = 135
Spot.FINAL_SEC = 90           -- and marked that long after his point was taken
Spot.MAX = 24                 -- capturers followed at once (a front has fewer points than that)
Spot.SWEEP_SEC = 15           -- the expired ones leave at that pace, while any is followed
Spot.LOOK_DELAY = 0.2         -- one look at the nameplates for all the lines of a moment
Spot.SAY_PER_PLAYER_SEC = 180 -- one chat line per capturer per three minutes
Spot.SAY_GAP = 10             -- and never two lines within ten seconds
Spot.ICON_SIZE = 16
Spot.byKey = Spot.byKey or {}   -- name key -> { name, zoneId, at, seen }
Spot.count = Spot.count or 0
Spot.icons = Spot.icons or {}   -- nameplate unit -> our frame (40 at most, reused)
Spot.saidAt = Spot.saidAt or {} -- name key -> when its chat line was printed

-- (The faction banners the panel's button already wears: Button.lua.)
local BANNER = {
    Alliance = "Interface\\Icons\\INV_BannerPVP_02",
    Horde = "Interface\\Icons\\INV_BannerPVP_01",
}

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function EnemyFaction()
    local mine = Overlord.PlayerFaction
    if mine == "Alliance" then return "Horde" end
    if mine == "Horde" then return "Alliance" end
    return nil
end

local function InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

-- A name from the network: its key (the one capture lines are compared by, Sync.lua) and the
-- name to show. Only the canonical "First Last" is kept: whatever a sender wrote around it
-- (a suffix, text after an escape character) is never stored nor printed.
local function KeyOfName(name)
    local sync = Overlord.Sync
    if type(name) ~= "string" or name == "" or not sync or not sync.CanonicalForeverName then return nil end
    local canon = sync:CanonicalForeverName(name)
    if type(canon) ~= "string" or canon == "" then return nil end
    return canon:lower(), canon
end

-- What our own map says of his point now: under capture by the enemy, or taken by the enemy
-- moments ago. The capture lines only say whom to look for; the map, which went through every
-- gate of the capture sync, says whether there is a capture to show.
local function PointStillTaken(row, enemy)
    if Overlord.InActiveFront ~= true then return false end
    local zones = Overlord.Zones
    local zone = zones and zones.GetZone and zones:GetZone(row.zoneId)
    if not zone or zone.owner ~= enemy then return false end
    if zone.status == "in_progress" then
        -- (The name our map took from the capture's lines, when it holds one, must be his: a
        -- line naming somebody else never marks that player.)
        local mapName = zone.zsRelayCapturerName
        if type(mapName) == "string" and mapName ~= "" then
            local mapKey = KeyOfName(mapName)
            return mapKey ~= nil and mapKey == row.key
        end
        return true
    end
    if zone.status ~= "captured" then return false end
    local taken = tonumber(zone.capturedTime) or 0
    local nowServer = Overlord.ServerNow and Overlord.ServerNow() or time()
    return taken > 0 and nowServer - taken <= Spot.FINAL_SEC
end

-- The followed capturer this unit is, or nil. The cheapest checks first: most nameplates are
-- creatures, and no name is read for them.
local function RowForUnit(unit)
    if Spot.count == 0 or not unit or not UnitIsPlayer or not UnitIsPlayer(unit) then return nil end
    local enemy = EnemyFaction()
    if not enemy or not UnitFactionGroup or UnitFactionGroup(unit) ~= enemy then return nil end
    local sync = Overlord.Sync
    local name = sync and sync.CanonicalForeverNameFromUnit and sync:CanonicalForeverNameFromUnit(unit)
    if type(name) ~= "string" or name == "" then return nil end
    local key = name:lower()
    local row = Spot.byKey[key]
    if not row or GetTime() - row.at > Spot.KEEP_SEC or not PointStillTaken(row, enemy) then return nil end
    -- (A name the game has shown us: never the one that gives way when the table is full.)
    row.seen = true
    return row, key
end

-- ============================================================
-- The banner on the nameplate
-- ============================================================

-- Left of the health bar, and left of the Nemesis skull when this capturer wears one. (The rank
-- badge of RankProof.lua goes left of both when it sits there.)
local function PlaceIcon(icon, parent)
    local anchor = parent.healthBar or parent
    local mw = Overlord.MostWanted
    local skull = mw and mw.skulls and icon.unit and mw.skulls[icon.unit]
    local beside = skull and skull.IsShown and skull:IsShown() and (mw.SKULL_SIZE or 16) + 2 or 0
    icon:ClearAllPoints()
    icon:SetPoint("RIGHT", anchor, "LEFT", -3 - beside, 0)
end

local function PlaceIconAgain(icon)
    icon._againArmed = nil
    local parent = icon.IsShown and icon:IsShown() and icon:GetParent()
    if parent then pcall(PlaceIcon, icon, parent) end
end

function Spot:ShowIcon(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    local parent = plate and (plate.UnitFrame or plate)
    if not parent or not CreateFrame then return end
    local icon = self.icons[unit]
    if not icon then
        icon = CreateFrame("Frame", nil, parent)
        icon:SetSize(self.ICON_SIZE, self.ICON_SIZE)
        icon.art = icon:CreateTexture(nil, "OVERLAY")
        icon.art:SetAllPoints()
        icon.art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon.unit = unit
        -- (One function per nameplate unit, made once: no closure per appearance.)
        icon.again = function() PlaceIconAgain(icon) end
        self.icons[unit] = icon
    end
    if icon:GetParent() ~= parent then icon:SetParent(parent) end
    local texture = BANNER[EnemyFaction() or ""]
    if icon._texture ~= texture then
        icon.art:SetTexture(texture)
        icon._texture = texture
    end
    PlaceIcon(icon, parent)
    icon:Show()
    -- The Nemesis skull of the same nameplate may be shown after us: placed again once it is
    -- (one timer pending per banner; every look at the nameplates places it again too).
    if not icon._againArmed and C_Timer and C_Timer.After then
        icon._againArmed = true
        C_Timer.After(0.2, icon.again)
    end
end

function Spot:HideAll()
    for _, icon in pairs(self.icons) do icon:Hide() end
end

-- ============================================================
-- The chat line
-- ============================================================

-- One line per capturer per three minutes, never two within ten seconds: capturers coming into
-- sight together are one line, and the ones that line did not name stay silent like him.
function Spot:Say(row, key)
    local now = GetTime()
    if now - (self.saidAt[key] or -1e9) < self.SAY_PER_PLAYER_SEC then return false end
    local zones = Overlord.Zones
    local zone = zones and zones.GetZone and zones:GetZone(row.zoneId)
    -- (Within the alert scope the player chose, like the capture alerts; a hidden line marks nothing.)
    if zone and Overlord.ShouldShowZoneAlert and not Overlord:ShouldShowZoneAlert(zone) then return false end
    self.saidAt[key] = now
    if now - (self._lastSayAt or -1e9) < self.SAY_GAP then return false end
    self._lastSayAt = now
    local L = Overlord.L
    local where = (zone and zone.name) or (L and L.ZONE_NAMES and L.ZONE_NAMES[row.zoneId]) or row.zoneId
    -- (A name from the network goes into a chat line: its escape character is doubled.)
    local name = row.name
    if name:find("|", 1, true) then name = name:gsub("|", "||") end
    if Overlord.PrintNotification then
        local crest = Overlord.EnemyFactionChatIcon and Overlord:EnemyFactionChatIcon() or ""
        Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. crest
            .. string.format(T("CAPTOR_SPOTTED", "Capturer spotted: %s (%s) is in sight, on your layer."), name, tostring(where)))
    end
    return true
end

-- ============================================================
-- Who is followed, who is seen
-- ============================================================

-- A unit the game shows: when it is a followed capturer, its banner (a nameplate) and its line.
function Spot:OnUnit(unit, isPlate)
    local row, key = RowForUnit(unit)
    if not row then return false end
    if isPlate then self:ShowIcon(unit) end
    self:Say(row, key)
    return true
end

-- Every nameplate shown and our target, looked at: shortly after a capturer starts being followed
-- (he may stand in front of us already) and at every sweep while somebody is followed (a banner
-- leaves when its capture is over, and takes its place again next to a skull that came or went).
function Spot:LookAround()
    self:HideAll()
    if self.count == 0 or InInstance() then return end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        local ok, plates = pcall(C_NamePlate.GetNamePlates)
        if ok and type(plates) == "table" then
            for _, plate in ipairs(plates) do
                local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
                if unit then self:OnUnit(unit, true) end
            end
        end
    end
    self:OnUnit("target", false)
end

local function LookTick()
    Spot._lookArmed = nil
    pcall(Spot.LookAround, Spot)
end

-- One look for all the capture lines of a moment, and after the line that asked for it was
-- applied to the map (the capture sync hands a line over before it applies it).
function Spot:AskLook()
    if self._lookArmed then return end
    if C_Timer and C_Timer.After then
        self._lookArmed = true
        C_Timer.After(self.LOOK_DELAY, LookTick)
    else
        self:LookAround()
    end
end

function Spot:SetEvents(on)
    local frame = self.frame
    on = on and true or false
    if not frame or self._events == on then return end
    self._events = on
    if on then
        frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    else
        frame:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        frame:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
        frame:UnregisterEvent("PLAYER_TARGET_CHANGED")
    end
end

-- The capturers whose last line is too old leave; with nobody left the banners and the events
-- leave too, otherwise the nameplates are looked at again (40 at most, every fifteen seconds).
function Spot:Sweep(now, noLook)
    now = now or GetTime()
    for key, row in pairs(self.byKey) do
        if now - row.at > self.KEEP_SEC then
            self.byKey[key] = nil
            self.count = self.count - 1
        end
    end
    for key, at in pairs(self.saidAt) do
        if now - at >= self.SAY_PER_PLAYER_SEC then self.saidAt[key] = nil end
    end
    if self.count <= 0 then
        self.count = 0
        self:HideAll()
        self:SetEvents(false)
    elseif not noLook then
        self:LookAround()
    end
end

local function SweepTick()
    Spot._sweepArmed = nil
    pcall(Spot.Sweep, Spot, GetTime())
    if Spot.count > 0 then Spot:ArmSweep() end
end

-- One timer at a time, and only while a capturer is followed: nothing runs every frame.
function Spot:ArmSweep()
    if self._sweepArmed or not C_Timer or not C_Timer.After then return end
    self._sweepArmed = true
    C_Timer.After(self.SWEEP_SEC, SweepTick)
end

-- The table is full: the oldest name the game never showed us gives way (a name anybody can
-- write in a line must not keep a capturer who is really there out).
function Spot:DropUnseen()
    local oldestKey, oldestAt
    for key, row in pairs(self.byKey) do
        if not row.seen and (not oldestAt or row.at < oldestAt) then oldestKey, oldestAt = key, row.at end
    end
    if not oldestKey then return false end
    self.byKey[oldestKey] = nil
    self.count = self.count - 1
    return true
end

-- A capture line of an enemy passed the gates of Sync.lua (in progress, or the final one: the man
-- who just took the point is still there). Followed only on the front we stand on: nobody is
-- seen from another map. final: the line that ends the capture. Anybody may relay one, with any
-- name in it, so it only keeps following a capturer whose lines under way named him already.
function Spot:Note(zoneId, capturerName, final)
    if type(zoneId) ~= "string" or Overlord.InActiveFront ~= true or InInstance() then return false end
    local zones = Overlord.Zones
    if not zones or not zones.GetZone or not zones:GetZone(zoneId) then return false end
    local key, canon = KeyOfName(capturerName)
    if not key then return false end
    local now = GetTime()
    local row = self.byKey[key]
    local known = row ~= nil and now - row.at <= self.KEEP_SEC and row.zoneId == zoneId
    if final and not known then return false end
    if not row then
        -- (Full: only the names gone stale leave here; the nameplates are looked at by the sweep.)
        if self.count >= self.MAX then self:Sweep(now, true) end
        if self.count >= self.MAX and not self:DropUnseen() then return false end
        row = {}
        self.byKey[key] = row
        self.count = self.count + 1
    end
    row.name, row.zoneId, row.at, row.key = canon, zoneId, now, key
    self:SetEvents(true)
    self:ArmSweep()
    if not known then self:AskLook() end
    return true
end

function Spot:Clear()
    for key in pairs(self.byKey) do self.byKey[key] = nil end
    self.count = 0
    self:HideAll()
    self:SetEvents(false)
end

-- An instance: nobody followed, no banner, no event (see Overlord:SuspendForInstance). The same
-- when the front is left (Overlord:OnLeaveFront).
function Spot:OnInstanceSuspend()
    self:Clear()
end

-- (Nothing to bring back: the capture lines received on a front follow their capturers again.)
function Spot:OnInstanceResume() end

if CreateFrame then
    local frame = CreateFrame("Frame")
    Spot.frame = frame
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_TARGET_CHANGED" then
            if Spot.count > 0 and not InInstance() then pcall(Spot.OnUnit, Spot, "target", false) end
            return
        end
        -- A nameplate given to another unit never keeps the banner of the one before.
        local icon = unit and Spot.icons[unit]
        if icon then icon:Hide() end
        -- (Never a unit read in an instance, the door included: the suspension may come a moment
        -- after the first nameplates.)
        if event == "NAME_PLATE_UNIT_ADDED" and Spot.count > 0 and not InInstance() then
            pcall(Spot.OnUnit, Spot, unit, true)
        end
    end)
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["CaptorSpot.lua"] = function() return { Spot = Spot, BANNER = BANNER } end
