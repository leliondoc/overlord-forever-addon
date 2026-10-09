-- At the displayed capture threshold, ask the authenticated capper directly
-- before the sampled realm/beta request. A received reply remains subject to
-- the normal C/ZS/ZA validation; the observer never finalizes the zone itself.
assert(loadfile("tests/forever_world_kills.test.lua"))()
local sync = Overlord.Sync
local now = 1000
GetTime = function() return now end
Overlord.InstanceSuspended = false
local displayed = 480
Overlord.Zones.GetObserverHoldTimeElapsed = function() return displayed end
local calls = {}
Overlord.Relay = {
    IsPeer = function(_, name) return name == "Capper Tester" end,
}
sync.SendWhisper = function(_, kind, payload, target)
    calls[#calls + 1] = { kind = kind, payload = payload, target = target }
    return true
end
sync.Send = function(_, kind, payload)
    calls[#calls + 1] = { kind = "broadcast", messageKind = kind, payload = payload }
    return true
end
sync.SendSyncRequest = function(_, opts)
    calls[#calls + 1] = { kind = "fallback", opts = opts }
    return true
end
local zone = {
    id = "elwynn_blackrock_advance", status = "in_progress",
    owner = "Alliance", isHolding = false,
    holdTimeElapsed = 477, holdTimeRequired = 480,
    _remoteCaptureLease = {
        directValidated = true, originName = "Capper Tester",
    },
}
sync:RequestObserverCaptureConfirmationIfComplete(zone)
assert(#calls == 2 and calls[1].kind == "SR"
    and calls[1].target == "Capper Tester"
    and calls[1].payload:match(":T$")
    and calls[2].kind == "broadcast"
    and calls[2].messageKind == "SR"
    and calls[2].payload:match(":T$"),
    "Observer did not query the capper before the broad fallback")
assert(zone.status == "in_progress" and zone.holdTimeElapsed == 477,
    "Confirmation request mutated the capture without a final proof")

now = now + 100
calls = {}
zone._observerCaptureConfirmPollAt = nil
zone._remoteCaptureLease.directValidated = false
sync:RequestObserverCaptureConfirmationIfComplete(zone)
assert(#calls == 2 and calls[1].target == "Capper Tester"
    and calls[2].kind == "broadcast",
    "Known relayed lease origin was not queried read-only")

now = now + 100
calls = {}
zone._remoteCaptureLease.originName = "Unknown Tester"
sync:RequestObserverCaptureConfirmationIfComplete(zone)
assert(#calls == 1 and calls[1].kind == "broadcast",
    "Unknown peer gained a directed capper route")

-- The 7:57/8:00 case: interpolation can pause below 100% after a missing ZS.
-- Query when the last remote hold would have completed, without promoting it.
now = now + 100
calls = {}
displayed = 477
zone.holdTimeElapsed = 477
zone._remoteCaptureLease.originName = "Capper Tester"
zone._remoteCaptureLease.lastHold = 477
zone._remoteCaptureLease.lastSeen = now - 3
sync:RequestObserverCaptureConfirmationIfComplete(zone)
assert(#calls == 2 and calls[1].target == "Capper Tester"
    and calls[2].kind == "broadcast" and zone.status == "in_progress",
    "Near-final stale observer did not query without locally finalizing")

now = now + 100
calls = {}
zone._remoteCaptureLease.lastSeen = now - 1
sync:RequestObserverCaptureConfirmationIfComplete(zone)
assert(#calls == 0, "Still-fresh 7:57 hold triggered premature confirmation")

-- The stale-ZS poll is a separate UI path and must also query the known peer.
now = now + 100
calls = {}
sync:PollIfStaleObserverInProgress(60, zone)
assert(#calls == 2 and calls[1].target == "Capper Tester"
    and calls[2].kind == "fallback", "Stale observer poll missed the capper")
print("Forever observer catch-up: direct capper first, fallback retained, no local finalization")
