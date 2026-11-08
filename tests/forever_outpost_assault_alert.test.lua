-- Live, 2026-10-01: two enemy guilds alternating on the same outpost printed
-- "guild X is assaulting" on every flip. Now one assault alert per site per 5 min;
-- a guild change re-arms the alert but never resets the cooldown.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now = 1790018000
local mapID, guild, faction = 1418, "Observer Guild", "Alliance"
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
C_Map = {
    GetBestMapForUnit = function() return mapID end,
    GetMapInfo = function() return { parentMapID = 0 } end,
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
-- (2.3.0: other guilds' sites alert only with the "other guilds" option, on here.)
OverlordDB = { lastResetTimestamp = 1789527600, config = { otherGuildSiteAlerts = true }, outposts = {} }
assert(loadfile("GuildKeepSites.lua"))()
assert(loadfile("Zones.lua"))()
assert(loadfile("Outpost.lua"))()
assert(loadfile("GuildKeep.lua"))()
assert(loadfile("OutpostControl.lua"))()
assert(loadfile("SyncStrategicSites.lua"))()
assert(loadfile("SyncOutpost.lua"))()
local op, sync = Overlord.Outpost, Overlord.Sync
for _, method in ipairs({ "Send", "SendToChannel", "BroadcastToRelay" }) do
    sync[method] = function() return true end
end
local L = Overlord.L
L.OUTPOST_ENEMY_ASSAULT_VS = "ASSAULT %s %s %s"
L.OUTPOST_ENEMY_ASSAULT = "ASSAULT %s %s"
local alerts = 0
Overlord.PrintNotification = function(_, text)
    if text:find("ASSAULT", 1, true) then alerts = alerts + 1 end
end

local siteKey = "silverpine"
-- A genuine in_progress OP wire for an enemy guild at the current time, built
-- without changing the observer's own view of the site.
local function wireAt(attacker, held)
    local st = op:GetState(siteKey)
    local saved = {}
    for k, v in pairs(st) do saved[k] = v end
    st.status, st.ownerGuild, st.ownerFaction = "in_progress", attacker, "Horde"
    -- (2.3.0: past half the capture by default, so the alert is due at once.)
    st.holdTimeElapsed, st.claimedAt, st.updatedAt, st.pool = held or 160, now, now, "global"
    local payload = assert(sync:BuildOutpostPayload(siteKey))
    for k in pairs(st) do st[k] = nil end
    for k, v in pairs(saved) do st[k] = v end
    return payload
end

-- Two guilds alternate on the same site every 20 s for 3 minutes.
local guilds = { "NoMercy", "No Flying" }
for i = 1, 9 do
    now = now + 20
    sync:OnReceiveOutpostState(wireAt(guilds[(i - 1) % 2 + 1]), "Channel Mate", "CHANNEL")
end
assert(op:GetState(siteKey).status == "in_progress", "Fixture: the observer did not take the assault")
assert(alerts == 1, "Alternating guilds re-alerted within 5 min: " .. alerts)

-- After the cooldown, the next guild change alerts again.
now = now + 300
sync:OnReceiveOutpostState(wireAt("Third Guild"), "Channel Mate", "CHANNEL")
assert(alerts == 2, "A new assault after the cooldown stayed silent: " .. alerts)
-- 2.3.0: an assault heard early is told at half the capture, if it still goes on; an enemy just
-- passing through (the assault gone before the half) is never told.
local timers = {}
local savedAfter = C_Timer.After
C_Timer.After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end
now = now + 400
sync:OnReceiveOutpostState(wireAt("Fourth Guild", 10), "Channel Mate", "CHANNEL")
assert(alerts == 2, "an assault 10 s old was told at once: " .. alerts)
local half = timers[#timers]
assert(half and half.delay >= 130 and half.delay <= 150, "no wait for the half: " .. tostring(half and half.delay))
now = now + 140
half.fn()
assert(alerts == 3, "an assault still under way at its half was not told: " .. alerts)
now = now + 400
sync:OnReceiveOutpostState(wireAt("Fifth Guild", 10), "Channel Mate", "CHANNEL")
local passer = timers[#timers]
assert(passer ~= half, "fixture: the new assault waits for its half")
op:GetState(siteKey).status = "held"
now = now + 140
passer.fn()
assert(alerts == 3, "an enemy gone before the half was told: " .. alerts)
C_Timer.After = savedAfter
print("Outpost assault alert: one per site per 5 min, guild flips no longer re-alert, told at half the capture")
