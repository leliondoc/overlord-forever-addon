-- Exercise the real objective presentation and HUD/waypoint transitions. Only
-- painting and the player's location are stubbed; no second objective selector.
local writes, scans, timers, placed, cleared = 0, 0, 0, 0, 0
local methods = {}
local function widget()
    return setmetatable({ shown = true }, { __index = methods })
end
function methods:IsShown() return self.shown end
methods.IsVisible = methods.IsShown
function methods:Show() self.shown = true end
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
        NEXT_OBJECTIVE_GO = 'Stand in the zone to capture.', UI_CONTESTED = 'CONTESTED',
        UI_PAUSED = 'PAUSED: outside zone, timer decaying',
        INDICATOR_DISMOUNT_TO_CAPTURE = 'Dismount.', INDICATOR_STEALTH_TO_CAPTURE = 'Leave stealth.' },
    InActiveFront = true, PlayerFaction = 'Alliance',
    IsPlayerDeadOrGhost = function() return dead end,
    IsLoginZoneDisplayPending = function() return pendingSync end,
    Fronts = {
        GetCurrentFront = function() return front end,
        GetFeaturedFrontId = function() error('Objective panel used the daily featured front') end,
        GetFeaturedFrontArtPath = function(_, id) return id .. '.blp' end,
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
assert(detailsContain('Distance: ~300 yards') and detailsContain('Stand in the zone'), 'Travel guidance was lost')
local before = writes
popups:RefreshNextObjective()
assert(writes == before and timers == 0, 'Unchanged objective repainted or started polling')

distance = nil
popups:RefreshNextObjective()
assert(detailsContain('Coords: 40.0, 50.0'), 'Missing map position must fall back to target coordinates')
distance = 0
popups:RefreshNextObjective()
assert(detailsContain('On point') and not detailsContain('Stand in the zone'), 'Arrival did not replace travel guidance')
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
assert(panel.vignette.texture == nil and panel.bodyFs.text == 'Enter a war front', 'Leaving a front retained stale map guidance')

-- Removing the guidance banner must preserve the automatic map waypoint and
-- the actual capture timer, including direct/manual UpdateIndicator callers.
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
assert(hud:IsShown() and hud.timer.text == '0:30 / 2:00', 'Capture timer was removed with the guidance banner')

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
print('Next objective: travel/arrival instructions, observer timer, contested/paused state, visible UI tick, hidden idle and capture HUD OK')
