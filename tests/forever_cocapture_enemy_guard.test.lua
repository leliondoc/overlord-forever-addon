-- 2.2.2: a delayed ally in-progress ZS (late joiner / co-capturer alignment) never
-- overturns a newer enemy capture, and never moves the zone's local date backwards.
-- Before, the client that took this path flipped an enemy capture back to our siege
-- while every other client (ts > localTs refused the packet) kept the enemy capture.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local sync = Overlord.Sync
local function upvalue(fn, wanted)
    for index = 1, 255 do
        local key, value = debug.getupvalue(fn, index)
        if key == nil then break end
        if key == wanted then return value end
    end
    error("missing upvalue " .. wanted)
end
local align = upvalue(sync.OnReceiveZoneState, "TryAlignAllyCoCaptureTimer")
Overlord.PlayerFaction = "Alliance"
local realDefer, realStore = sync.ShouldDeferToRemoteAllyCapturer, sync.StoreAllyOfficialCapturerFromZs
sync.ShouldDeferToRemoteAllyCapturer = function() return true end
sync.StoreAllyOfficialCapturerFromZs = function() end
local adopted = 0
local function adopt() adopted = adopted + 1; return true end

-- 1. Enemy capture newer than the ally tick: refused, nothing touched, no lease.
local zone = { id = "test", status = "captured", owner = "Horde", capturedTime = 1000, updatedAt = 1000 }
assert(align(zone, "in_progress", "Alliance", 30, 900, "Ally", "Ally", 1, nil, adopt) == false,
    "a delayed ally tick overturned a newer enemy capture")
assert(zone.status == "captured" and zone.owner == "Horde" and zone.updatedAt == 1000 and adopted == 0,
    "a refused ally tick touched the zone or materialised a lease")
-- Same second as the enemy capture: refused too.
assert(align(zone, "in_progress", "Alliance", 30, 1000, "Ally", "Ally", 1, nil, adopt) == false)

-- 2. An ally siege that started after the enemy capture still aligns.
assert(align(zone, "in_progress", "Alliance", 30, 1100, "Ally", "Ally", 1, nil, adopt) == true,
    "a fresh ally siege on an enemy zone was refused")
assert(zone.status == "in_progress" and zone.owner == "Alliance" and zone.previousOwner == "Horde"
    and zone.holdTimeElapsed == 30 and zone.updatedAt == 1100 and adopted == 1)

-- 3. Co-capturer alignment with an older tick: the timer moves, the local date does not go back.
zone = { id = "test2", status = "in_progress", owner = "Alliance", holdTimeElapsed = 10, updatedAt = 2000 }
assert(align(zone, "in_progress", "Alliance", 20, 1500, "Ally", "Ally", 1, nil, adopt) == true)
assert(zone.holdTimeElapsed == 20 and zone.updatedAt == 2000, "the co-capture alignment lowered updatedAt")

-- 4. 2.3.0: as a real client holds it: an enemy zone reads "available" or "locked" on our side.
for _, shown in ipairs({ "available", "locked" }) do
    zone = { id = "test-" .. shown, status = shown, owner = "Horde", capturedTime = 1000, updatedAt = 1000 }
    adopted = 0
    assert(align(zone, "in_progress", "Alliance", 30, 900, "Ally", "Ally", 1, nil, adopt) == false,
        "a delayed ally tick overturned a newer enemy capture shown " .. shown)
    assert(zone.status == shown and zone.owner == "Horde" and adopted == 0)
    assert(align(zone, "in_progress", "Alliance", 30, 1100, "Ally", "Ally", 1, nil, adopt) == true,
        "a fresh ally siege on an enemy zone shown " .. shown .. " was refused")
end
-- An undated enemy final (never attested) does not block a siege.
zone = { id = "test-unattested", status = "available", owner = "Horde", capturedTime = 1000,
    updatedAt = 1000, _captureFinalUnattested = true }
assert(align(zone, "in_progress", "Alliance", 30, 900, "Ally", "Ally", 1, nil, adopt) == true)

sync.ShouldDeferToRemoteAllyCapturer, sync.StoreAllyOfficialCapturerFromZs = realDefer, realStore
print("Co-capture alignment: newer enemy capture kept, local date never lowered OK")
