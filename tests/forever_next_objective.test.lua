-- Exercise the real objective presentation and HUD/waypoint transitions. Only
-- painting and the player's location are stubbed; no second objective selector.
local writes, scans, timers, placed, cleared = 0, 0, 0, 0, 0
local methods = {}
local function widget()
    return setmetatable({ shown = true }, { __index = methods })
end
function methods:IsShown() return self.shown end
methods.IsVisible = methods.IsShown
function methods:Show() self.shown = true; self.showCalls = (self.showCalls or 0) + 1 end
function methods:Hide() self.shown = false end
function methods:SetShown(shown) self.shown = shown end
function methods:SetText(text) self.text = text; writes = writes + 1 end
function methods:SetTexture(path) self.texture = path; writes = writes + 1 end
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') or key:match('^Register') or key == 'ClearAllPoints' or key == 'EnableMouse' then
        return function() end
    end
end })
function CreateFrame() return widget() end
function GetTime() return 100 end
function InCombatLockdown() return false end
C_Timer = { After = function() timers = timers + 1 end, NewTicker = function() timers = timers + 1 end }

local front = { id = 'elwynn' }
local target = { id = 'mine', name = 'Fargodeep Mine', status = 'available', center = { 40, 50 }, radius = 10 }
local pendingSync = false
local distance, blocked, stealthed, dead = 12, false, false, false
local distanceReads, observerReads = 0, 0
local observedElapsed = 43
function IsStealthed() return stealthed end
Overlord = {
    L = { NEXT_OBJECTIVE_NONE = 'No objective available', NEXT_OBJECTIVE_NO_FRONT = 'Outside a war front',
        NEXT_OBJECTIVE_OUTSIDE_FRONT = 'Enter a war front', MAP_SYNC_PENDING = 'SYNC',
        IN_THE_ZONE = 'On point', INDICATOR_TITLE = 'Capture', STATUS_IN_PROGRESS = 'Capturing',
        DISTANCE_FORMAT = 'Distance: ~%.0f yards', COORDS_FORMAT = 'Coords: %.1f, %.1f',
        UI_CONTESTED = 'CONTESTED',
        UI_PAUSED = 'PAUSED: outside zone, timer decaying',
        INDICATOR_DISMOUNT_TO_CAPTURE = 'Dismount.', INDICATOR_STEALTH_TO_CAPTURE = 'Leave stealth.' },
    InActiveFront = true, PlayerFaction = 'Alliance',
    IsPlayerDeadOrGhost = function() return dead end,
    IsLoginZoneDisplayPending = function() return pendingSync end,
    Fronts = {
        GetCurrentFront = function() return front end,
        GetFeaturedFrontId = function() error('Objective panel used the daily featured front') end,
        GetFeaturedFrontArtPath = function(_, id) return id .. '.blp' end,
        GetHomeArtPath = function() return 'home.blp' end,
        GetHomeMotto = function() return "Lok'tar ogar!" end,
        GetFeaturedFrontDisplayName = function(_, id) return id == 'elwynn' and 'Elwynn Forest' or 'Loch Modan' end,
    },
    Zones = {
        GetNextObjectiveZone = function(_, id)
            assert(id == front.id, 'Objective came from another map')
            scans = scans + 1
            return target
        end,
        GetDisplayOrderForFront = function() return target and { target } or {} end,
        GetObserverHoldTimeElapsed = function(_, zone)
            assert(zone == target)
            observerReads = observerReads + 1
            return observedElapsed
        end,
    },
    ZoneControl = { IsPlayerInNonCaptureStateForSync = function() return blocked or dead end },
    MapMarkers = {
        SetUserWaypointForFrontZone = function(_, zone, id)
            assert(zone == target and id == front.id)
            placed = placed + 1
            return true
        end,
        IsUserWaypointForFrontZone = function() return true end,
        ClearUserWaypointForFrontZone = function() cleared = cleared + 1 end,
    },
}
OverlordDB = { config = { autoWaypointNextObjective = true } }
Overlord.ZoneDatabase = { target }
assert(loadfile('Popups.lua'))()
assert(loadfile('ZoneIndicator.lua'))()

local function inject(fn, name, value)
    for i = 1, 40 do
        local found = debug.getupvalue(fn, i)
        if not found then break end
        if found == name then debug.setupvalue(fn, i, value); return end
    end
    error('Fixture could not bind ' .. name)
end
local panel = widget()
panel.vignette, panel.frontNameFs, panel.bodyFs, panel.objectiveDetailsFs = widget(), widget(), widget(), widget()
local popups, indicator = Overlord.Popups, Overlord.ZoneIndicator
indicator.GetDistanceToZone = function()
    distanceReads = distanceReads + 1
    return distance
end
local function detailsContain(text)
    return panel.objectiveDetailsFs.text:find(text, 1, true)
end
inject(popups.RefreshNextObjective, 'featuredFrontFrame', panel)
popups:RefreshNextObjective()
assert(panel.vignette.texture == 'elwynn.blp' and panel.frontNameFs.text == 'Elwynn Forest')
assert(panel.bodyFs.text == 'Fargodeep Mine', 'Objective name did not replace the featured-front explanation')
assert(detailsContain('Distance: ~300 yards'), 'Travel guidance was lost')
-- 1.7.1: no "Go here" hint under the distance (its room goes to Recent activity).
assert(not detailsContain('Go here') and not detailsContain('\n'), 'The travel hint came back')
local before = writes
popups:RefreshNextObjective()
assert(writes == before and timers == 0, 'Unchanged objective repainted or started polling')

distance = nil
popups:RefreshNextObjective()
assert(detailsContain('Coords: 40.0, 50.0'), 'Missing map position must fall back to target coordinates')
distance = 0
popups:RefreshNextObjective()
assert(detailsContain('On point') and not detailsContain('Distance'), 'Arrival did not replace travel guidance')
blocked = true
popups:RefreshNextObjective()
assert(detailsContain('Dismount.') and not detailsContain('On point'), 'Blocked capture was presented as ready')
stealthed = true
popups:RefreshNextObjective()
assert(detailsContain('Leave stealth.'), 'Stealth capture instruction missing')
dead = true
popups:RefreshNextObjective()
assert(not detailsContain('Leave stealth.') and not detailsContain('On point'), 'Dead player was told to capture')
dead, blocked, stealthed, distance = false, false, false, 12

target.status, target.holdTimeElapsed, target.holdTimeRequired = 'in_progress', 30, 120
popups:RefreshNextObjective()
assert(detailsContain('0:43 / 2:00') and observerReads > 0, 'Panel did not use the existing observer clock')
target.isContested = true
popups:RefreshNextObjective()
assert(detailsContain('CONTESTED') and detailsContain('|cFFFF4444'), 'Contested capture lost its warning')
target.isContested, target.isPaused, observedElapsed = false, true, 41
popups:RefreshNextObjective()
assert(detailsContain('0:41 / 2:00') and detailsContain('PAUSED'), 'Paused capture must follow the decaying timer')

target = { id = 'tower', name = 'Tower of Azora', status = 'available', center = { 60, 40 }, radius = 10 }
popups:RefreshNextObjective()
assert(panel.bodyFs.text == target.name, 'Next capture did not refresh')
assert(not detailsContain('PAUSED') and not detailsContain(' / '), 'New objective retained the previous capture state')
pendingSync = true
local readsBefore = distanceReads
popups:RefreshNextObjective()
assert(panel.bodyFs.text == 'SYNC', 'Unconfirmed login state was presented as a capture target')
assert(not panel.objectiveDetailsFs:IsShown() and distanceReads == readsBefore, 'Pending sync displayed unconfirmed guidance')
pendingSync = false
panel:Hide()
before = scans
readsBefore = distanceReads
front = { id = 'loch_modan' }
popups:RefreshNextObjective()
assert(scans == before and distanceReads == readsBefore, 'Hidden panel scanned objective state or player position')
panel:Show()
popups:RefreshNextObjective()
assert(panel.vignette.texture == 'loch_modan.blp' and panel.frontNameFs.text == 'Loch Modan')
local available = target
target = nil
popups:RefreshNextObjective()
assert(panel.bodyFs.text == 'No objective available', 'Truce retained an obsolete objective')
assert(panel.objectiveDetailsFs.text == '' and not panel.objectiveDetailsFs:IsShown(), 'Truce retained capture details')
Overlord.InActiveFront = false
popups:RefreshNextObjective()
assert(panel.vignette.texture == 'home.blp' and panel.bodyFs.text == 'Enter a war front', 'Leaving a front did not show the homeland art')
assert(panel.frontNameFs.text == "Lok'tar ogar!", 'Leaving a front did not show the race motto')

-- Both guidance and regular capture progress belong to the side panel. Keep
-- the waypoint, but never resurrect the floating HUD through capture/manual calls.
target, Overlord.InActiveFront = available, true
local hud = widget()
hud.title, hud.zoneName, hud.distance, hud.timer = widget(), widget(), widget(), widget()
inject(indicator.Hide, 'indicatorFrame', hud)
indicator:RefreshHud()
assert(not hud:IsShown() and placed == 1 and cleared == 0, 'Guidance banner remained or waypoint was lost')
hud:Show()
indicator:UpdateIndicator(target)
assert(not hud:IsShown(), 'Manual update resurrected the removed banner')
target.status, target.isHolding = 'in_progress', true
target.holdTimeElapsed, target.holdTimeRequired = 30, 120
distance, observedElapsed = 0, 30
hud:Show()
indicator:UpdateIndicator(target)
assert(not hud:IsShown(), 'Capture update resurrected the floating zone HUD')
popups:RefreshNextObjective()
assert(detailsContain('0:30 / 2:00'), 'Capture progress disappeared from the side panel')
indicator.FindActiveZone = function() return target end
Overlord.Zones.GetCurrentPlayerZone = function() return target end
local beforeShows = hud.showCalls
indicator:RefreshHud()
indicator:Show()
assert(not hud:IsShown() and hud.showCalls == beforeShows, 'Automatic/manual show recreated the zone HUD')
for _, field in ipairs({ 'isContested', 'isPaused' }) do
    target[field] = true
    indicator:RefreshHud()
    indicator:Show()
    assert(not hud:IsShown() and hud.showCalls == beforeShows, 'Capture state recreated the zone HUD: ' .. field)
    target[field] = nil
end
-- Fortresses and outposts share _outpost and retain the capture HUD. Its explicit
-- display path must still reach UpdateIndicator.
local update = indicator.UpdateIndicator
local squareSeen
indicator.UpdateIndicator = function(_, zone) squareSeen = zone end
for _, field in ipairs({ '_outpost' }) do
    target[field] = true
    indicator:Show()
    assert(hud:IsShown() and squareSeen == target, 'Structure HUD was removed: ' .. field)
    target[field] = nil
    indicator:Hide()
end
indicator.UpdateIndicator = update

-- The existing UI heartbeat refreshes distance and capture progress, even when
-- no sync event or activity-list refresh occurs. No additional ticker is used.
assert(loadfile('UI.lua'))()
local ui, main = Overlord.UI, widget()
inject(ui.UpdateTick, 'mainFrame', main)
for _, name in ipairs({ 'RefreshActiveZone', 'UpdateZoneListTimers', 'RefreshForces', 'RefreshCommunityButton' }) do
    ui[name] = function() end
end
observedElapsed = 31
ui:Update()
assert(detailsContain('0:31 / 2:00') and timers == 0, 'Visible UI tick did not refresh objective progress')
main:Hide()
before, readsBefore = scans, distanceReads
ui:Update()
assert(scans == before and distanceReads == readsBefore, 'Hidden main panel polled objective details')
print('Next objective: panel guidance/progress, no floating zone HUD, manual/automatic paths, structure HUD and hidden idle OK')

-- Exercise production layout with actual anchor arithmetic. Southshore/Tarren
-- Mill have short main panels; long localized instructions must still fit.
local function upvalue(fn, name)
    for i = 1, 60 do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then return value end
    end
    error('Missing layout upvalue: ' .. name)
end
local applyContent = upvalue(popups.RefreshNextObjective, 'ApplyFeaturedFrontContent')
local layout = upvalue(applyContent, 'ApplyFeaturedFrontActivityLayout')
local layoutWrites = 0
local function box(height, fixedTop)
    local w = widget()
    w.height, w.fixedTop = height, fixedTop
    function w:GetHeight() return self.height end
    function w:GetStringHeight() return self.height end
    function w:SetHeight(h) self.height = h; layoutWrites = layoutWrites + 1 end
    function w:GetTop()
        if self.fixedTop then return self.fixedTop end
        if self.bottomAnchor then return self.bottomAnchor:GetBottom() + self.offset + self.height end
        return self.topAnchor:GetBottom() + self.offset
    end
    function w:GetBottom() return self:GetTop() - self.height end
    function w:ClearAllPoints() self.bottomAnchor, self.topAnchor = nil,nil end
    function w:SetPoint(point, relative, relativePoint, x, y)
        if point == 'BOTTOM' then self.bottomAnchor,self.offset = relative,y end
    end
    function w:SetTexCoord(...) self.crop = {...}; layoutWrites = layoutWrites + 1 end
    return w
end
local f = box(500, 1000)
f.artFrame = box(112, 800)
f.vignette = box(104)
f.bodyFs = box(20); f.bodyFs.topAnchor,f.bodyFs.offset = f.artFrame,-16
f.objectiveDetailsFs = box(45); f.objectiveDetailsFs.topAnchor,f.objectiveDetailsFs.offset = f.bodyFs,-8
f.activityPanel, f.activityFooter = box(100), box(64)
f.coinsRow = f.activityFooter
f.activityScroll, f.activityRowsContent = box(1), box(1)
function f.activityScroll:GetHeight() return f.activityPanel:GetHeight() - 36 end
function f.activityScroll:GetWidth() return 228 end
function f.activityScroll:GetVerticalScroll() return self.scroll or 0 end
function f.activityScroll:SetVerticalScroll(value) self.scroll = value end
function f.activityScroll:RefreshCleanRail() self.railShown = self._overlordHasOverflow end
local smallMain = box(500, 1000)
Overlord.UI.GetMainFrame = function() return smallMain end
Overlord.UI.actionsCard = box(169)
Overlord.UI.activeZoneFrame = nil
local firstArt
for _, height in ipairs({ 650, 480, 420, 350, 650 }) do
    for _, textHeight in ipairs({ 28, 60, 110 }) do
        for _, count in ipairs({ 0, 1, 8 }) do
            smallMain.height, f.height, f.objectiveDetailsFs.height = height,height,textHeight
            f._activityLayoutKey = nil
            layout(f, count)
            assert(f.activityPanel:GetTop() <= f.objectiveDetailsFs:GetBottom() - 10 + 0.001,
                'Recent activity overlaps objective guidance in a short panel')
            -- 1.4.2: the dock keeps the main panel's height; a short front shows fewer
            -- activity rows (never under two) instead of growing past the main panel.
            assert(f.activityPanel:GetHeight() >= 78,
                'Short front compressed the activity viewport under two rows')
            assert(f.activityFooter:GetTop() <= f.activityPanel:GetBottom() - 10 + 0.001,
                'Coins overlap activity')
            assert(f.activityFooter:GetBottom() >= f:GetBottom() + 16, 'Coins escape panel bottom')
            assert(f.artFrame:GetHeight() == 112, 'Short front shrank the objective map picture')
            assert(f.activityScroll:GetHeight() >= 42, 'Short front squeezed the activity scrollbar')
            local overflow = count * 21 - 3 > f.activityScroll:GetHeight() + 1
            assert(f.activityScroll.railShown == overflow, 'Activity rail disagrees with visible/content height')
            assert((f.activityScroll:GetVerticalScroll() or 0)
                <= math.max(0, f.activityRowsContent:GetHeight() - f.activityScroll:GetHeight()),
                'Activity scroll offset exceeded its actual content')
            if height == 650 and textHeight == 28 then
                firstArt = firstArt or f.artFrame:GetHeight()
                assert(f.artFrame:GetHeight() == firstArt, 'Returning to a tall front retained a cropped map')
            end
            layout(f, count) -- settle changed minimum height in cache key
            local beforeLayout = layoutWrites
            layout(f, count)
            assert(layoutWrites == beforeLayout, 'Unchanged panel reapplied layout/texture coordinates')
        end
    end
end
assert(firstArt == 112)
-- A main-panel resize alone must invalidate the dock's cached geometry, without
-- reopening it, changing text or manually clearing the layout key.
smallMain.height, f.height, f.objectiveDetailsFs.height = 380, 380, 28
f._activityLayoutKey = nil
layout(f, 8); layout(f, 8)
local minimum = f:GetHeight()
smallMain.height = 800
layout(f, 8)
assert(f:GetHeight() == 800, 'Main-panel growth did not invalidate cached dock layout')
smallMain.height = 380
layout(f, 8)
assert(f:GetHeight() == minimum, 'Main-panel shrink left stale dock geometry')
-- Opt-in floating guide (settings, off by default): an available objective can
-- again appear in the small window; turning the option off removes it.
indicator.UpdateIndicator = update
target._guildKeep, target._outpost = nil, nil
target.status, target.isHolding = 'available', nil
OverlordDB.config.showFloatingObjective = true
hud:Show()
indicator:UpdateIndicator(target)
assert(hud:IsShown() and hud.zoneName.text == target.name, 'Opt-in floating guide did not show the objective')
OverlordDB.config.showFloatingObjective = false
indicator:UpdateIndicator(target)
assert(not hud:IsShown(), 'Floating guide stayed after the option was turned off')
print('Next objective layout: 45 short/tall/long-text/activity cases; normal image + five-row viewport, no overlap, cached idle OK')
