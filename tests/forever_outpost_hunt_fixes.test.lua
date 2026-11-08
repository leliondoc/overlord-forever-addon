-- Five outpost/fortress fixes of the 2.2.2 hunt, each in its own block:
--  1. outnumbered on the point, a hold is not started (it was started and reverted every second);
--  2. a stale mate hold is neither resumed at its old count nor taken over;
--  3. staleness of an assault is judged with the site (fortress: 600 s, not 300 s);
--  4. the OP payload carries the site's hold time (fortress 600, gold attack 540);
--  5. the defence poll is sent once, when the enemy shows up, with one targeted pull.
assert(loadfile("tests/forever_fortress_outpost.test.lua"))()
local op, control, sync = Overlord.Outpost, Overlord.OutpostControl, Overlord.Sync
local NOW = 1790017000
function time() return NOW end
function GetServerTime() return NOW end
function GetTime() return NOW - 1790016000 end
Overlord.ServerNow = function() return NOW end
Overlord.PlayerFaction = "Alliance"
local MY_GUILD = "Hunt Guild"
function GetGuildInfo() return MY_GUILD end
Overlord.GetCurrentSavedVarsPool = function() return "global" end
Overlord.L = Overlord.L or {}
Overlord.PrintNotification = function() end
local siteKey = "badlands"
local site = op:GetSite(siteKey)
assert(site and site.holdTimeRequired == 600, "fixture: badlands is not a 600 s fortress")

-- Nameplate enemies stand on the point (the stubbed map position is the same for every unit).
local enemies = 0
local realExists, realGuid = UnitExists, UnitGUID
local function plateIndex(unit) return tonumber(tostring(unit):match("^nameplate(%d+)$")) end
function UnitExists(unit)
    local i = plateIndex(unit)
    if i then return i <= enemies end
    return realExists(unit)
end
function UnitFactionGroup(unit)
    if plateIndex(unit) then return "Horde" end
    return "Alliance"
end
function UnitGUID(unit)
    local i = plateIndex(unit)
    if i then return "Player-9-ENEMY" .. i end
    return realGuid(unit)
end
function UnitIsUnit(a, b) return a == b end

local function tick(dt)
    dt = dt or 10 -- past every 2 s cache of the scan and of the spatial sample
    NOW = NOW + dt
end
local function reset(status)
    local s = op:GetState(siteKey)
    s.status, s.ownerGuild, s.ownerFaction = status or "neutral", "", nil
    s.updatedAt, s.claimedAt, s.expiresAt, s.holdTimeElapsed = 0, 0, 0, 0
    s.isHolding, s.isPaused, s.isContested, s.holdAuthorityLocal = false, false, false, false
    s.holdStartTime, s.holdTimeRequired = nil, 600
    s.previousOwnerGuild, s.previousOwnerFaction = nil, nil
    return s
end
local sent = {}
for _, method in ipairs({ "Send", "SendToChannel", "BroadcastToRelay" }) do
    sync[method] = function(_, kind) sent[#sent + 1] = kind; return true end
end
-- Every case runs on its own: a failing one does not hide the others.
local failures = {}
local function run(case)
    local ok, err = pcall(case)
    if not ok then failures[#failures + 1] = tostring(err); print("FAILED " .. tostring(err)) end
end

-- (1) Outnumbered on the point: no hold started.
run(function()
    local s = reset("neutral")
    enemies = 2 -- 2 enemies against the player alone
    tick(); sent = {}
    control:CheckPosition(1)
    assert(s.status == "neutral" and not s.isHolding,
        "Case 1: a hold started while the player was outnumbered on the point")
    assert(#sent == 0, "Case 1: outnumbered, OP traffic still left (" .. #sent .. " messages)")
    enemies = 1 -- 1 against 1: the hold starts
    tick()
    control:CheckPosition(1)
    assert(s.status == "in_progress" and s.isHolding,
        "Case 1: an even fight (1 against 1) must still start the hold")
    enemies = 0
    print("Case 1 OK: outnumbered, no hold; even, hold")
end)

-- (2) Stale mate hold: not resumed, not taken over; fresh hold from 0. Non-stale still resumes.
run(function()
    enemies = 0
    local function mateHold(updatedAt)
        local s = reset("in_progress")
        s.ownerGuild, s.ownerFaction = MY_GUILD, "Alliance"
        s.holdTimeElapsed, s.holdTimeRequired, s.updatedAt = 100, 600, updatedAt
        return s
    end
    -- over for the network: unheard 5000 s, 500 s left
    local s = mateHold(NOW - 5000)
    assert(op:IsObserverOutpostCaptureStale(s, site), "Case 2: fixture hold is not stale")
    tick()
    control:CheckPosition(1)
    assert(not (s.isHolding and s.holdTimeElapsed >= 100),
        "Case 2: a stale mate hold was resumed at its old count (" .. tostring(s.holdTimeElapsed) .. ")")
    assert(s.holdTimeElapsed < 20, "Case 2: a stale hold must restart near 0, got " .. tostring(s.holdTimeElapsed))
    -- StartHold alone, stale
    s = mateHold(NOW - 5000)
    tick()
    control:StartHold(siteKey, s, site)
    assert(s.holdTimeElapsed == 0, "Case 2: StartHold took over a stale mate hold at "
        .. tostring(s.holdTimeElapsed))
    -- not stale: still resumed
    s = mateHold(NOW - 5)
    tick(1)
    control:CheckPosition(1)
    assert(s.isHolding and s.holdTimeElapsed >= 100,
        "Case 2: a live mate hold must still be resumed at its count (got " .. tostring(s.holdTimeElapsed) .. ")")
    s = mateHold(NOW - 5)
    control:StartHold(siteKey, s, site)
    assert(s.holdTimeElapsed >= 100, "Case 2: StartHold must still take over a live mate hold")
    print("Case 2 OK: stale mate hold restarts at 0, live one resumes")
end)

-- (3) Fortress assault 400/600 updated 35 s ago is not stale; the player cannot start over it.
run(function()
    local s = reset("in_progress")
    s.ownerGuild, s.ownerFaction = "Enemy Guild", "Horde"
    s.holdTimeElapsed, s.holdTimeRequired, s.updatedAt = 400, 600, NOW - 35
    assert(not op:IsObserverOutpostCaptureStale(s, site), "Case 3: fixture is stale on 600 s")
    assert(op:CanPlayerAssaultOutpostState(s, site) == false,
        "Case 3: CanPlayerAssaultOutpostState judged a live fortress assault stale")
    assert(op:CanPlayerStartCapture(s, site) == false,
        "Case 3: CanPlayerStartCapture let the player start over a live fortress assault")
    s.updatedAt = NOW - 5000
    assert(op:CanPlayerStartCapture(s, site) == true, "Case 3: a really stale assault must be open")
    print("Case 3 OK: staleness judged with the fortress hold time")
end)

-- (4) The OP payload carries the site's hold time.
run(function()
    local function holdReqOf(required)
        local s = reset("in_progress")
        s.ownerGuild, s.ownerFaction = MY_GUILD, "Alliance"
        s.holdTimeElapsed, s.holdTimeRequired, s.updatedAt, s.pool = 50, required, NOW, "global"
        local payload = assert(sync:BuildOutpostPayload(siteKey), "Case 4: no payload built")
        local f = {}
        for part in (payload .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end
        return tonumber(f[10])
    end
    assert(holdReqOf(600) == 600, "Case 4: fortress payload hold time is not 600")
    assert(holdReqOf(540) == 540, "Case 4: gold attack payload hold time is not 540")
    print("Case 4 OK: payload hold time 600 / 540")
end)

-- (5) Defence: one stale poll, when the enemy first shows up, with a targeted pull.
run(function()
    local s = reset("held")
    s.ownerGuild, s.ownerFaction, s.claimedAt, s.updatedAt = MY_GUILD, "Alliance", NOW - 9000, NOW - 9000
    local polls = {}
    sync.PollIfStaleObserverOutpost = function(_, age, withPull) polls[#polls + 1] = { age, withPull } end
    enemies = 1
    for _ = 1, 4 do tick(); control:CheckPosition(1) end
    assert(#polls == 1, "Case 5: expected one poll while the enemy stays, got " .. #polls)
    assert(polls[1][2] == true, "Case 5: the poll must ask for one targeted pull (withPull=true)")
    enemies = 0
    print("Case 5 OK: one targeted poll when the enemy shows up")
end)
assert(#failures == 0, #failures .. " case(s) failed: " .. table.concat(failures, " | "))
print("Outpost hunt fixes: 5 cases OK")
