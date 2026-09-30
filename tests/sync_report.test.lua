-- /ov network: colored summary first (ok / watch / problem), then grey details with
-- non-zero loss or refusal counters in red. Real Commands.lua on the beta fixture.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()

local sync, net = Overlord.Sync, Overlord.BetaNetwork
SlashCmdList = {}
local lines = {}
Overlord.PrintNotification = function(_, s) lines[#lines + 1] = s end
Overlord.IsInitialized, Overlord.InstanceSuspended = true, false
Overlord.L.SYNC_REQUESTED = Overlord.L.SYNC_REQUESTED or "Sync requested."
IsInInstance = function() return false end
C_Timer.After = function(_, fn) fn() end -- the 30 s probe window closes at once
local frameStub = { RegisterEvent = function() end, SetScript = function() end,
    UnregisterAllEvents = function() end }
CreateFrame = function() return frameStub end
assert(loadfile("Commands.lua"))()

local GREEN, YELLOW, RED = "|cFF40FF40", "|cFFFFD100", "|cFFFF4040"
local function run()
    lines = {}
    sync._historyCatchupStats, sync._historyCatchupPending = nil, nil
    SlashCmdList.OVERLORD("network")
    return lines
end
local function find(list, needle)
    for _, line in ipairs(list) do
        if line:find(needle, 1, true) then return line end
    end
end

-- Healthy client: every summary row is green and the header says "all good".
sync._addonSendStats = { CHANNEL = { ok = 46, refused = 0 }, WHISPER = { ok = 915, refused = 0 } }
net.stats.sent, net.stats.received, net.stats.dropped = 934, 1040, 0
local out = run()
assert(out[1]:find("Network status:", 1, true) and out[1]:find(GREEN .. "all good", 1, true),
    "Healthy header is not green: " .. tostring(out[1]))
local blizzard = assert(find(out, "Blizzard throttle"), "No Blizzard summary row")
assert(blizzard:find("ReadyCheck-Ready", 1, true) and blizzard:find("0 refused (channel 0/46, whisper 0/915)", 1, true),
    "Blizzard row wrong: " .. blizzard)
local relay = assert(find(out, "Relay losses"), "No relay summary row")
assert(relay:find("0 lost of 934 sent (0.0%), 1040 received", 1, true), "Relay row wrong: " .. relay)
assert(find(out, "Leaderboard catch-up") and find(out, "Capture history catch-up") and find(out, "Relay queue"),
    "A summary row is missing")
local details = 0
for i, line in ipairs(out) do if line:find("Details:", 1, true) then details = i end end
assert(details == 7, "Summary must be the header plus five rows before the details, got " .. details)
assert(not find(out, "[Overlord] [Overlord]"), "Double prefix")

-- Losses: 5% of the relay sent is a problem (red), a few Blizzard refusals are worth watching.
sync._addonSendStats = { CHANNEL = { ok = 97, refused = 3 }, WHISPER = { ok = 100, refused = 0 } }
net.stats.sent, net.stats.dropped = 1000, 60
net.stats.localRejected = 40
out = run()
assert(out[1]:find(RED .. "problem", 1, true), "Header must show the worst level: " .. out[1])
assert(find(out, "Blizzard throttle"):find("ReadyCheck-Waiting", 1, true), "3% Blizzard refusals must be yellow")
local lost = find(out, "Relay losses")
assert(lost:find("ReadyCheck-NotReady", 1, true) and lost:find("60 lost of 1000 sent (6.0%)", 1, true),
    "6% relay losses must be red: " .. lost)
local outcomes = assert(find(out, "Relay outcomes since login"), "Relay outcomes detail missing")
assert(outcomes:find("local admission refused " .. RED .. "40|r", 1, true),
    "A non-zero refusal counter is not red: " .. outcomes)
assert(not outcomes:find(RED .. "0|r", 1, true), "A zero counter was painted red")
local dropped = assert(find(out, " 1000 sent, 1040 received"), "Relay detail missing")
assert(dropped:find(RED .. "60|r", 1, true), "Dropped count not red: " .. dropped)

-- A capture-history request left unanswered for more than 5 minutes is flagged.
sync._addonSendStats = { CHANNEL = { ok = 10, refused = 0 } }
net.stats.dropped = 0
lines = {}
sync.GetHistoryCatchupSummary = function()
    return { running = true, step = "paged ladder catch-up", stepAge = 655, rows = 0 }
end
SlashCmdList.OVERLORD("network")
local hr = assert(find(lines, "Capture history catch-up"), "History row missing")
assert(hr:find("ReadyCheck-Waiting", 1, true) and hr:find("waiting on one peer for 655s", 1, true),
    "Stalled history catch-up not flagged: " .. hr)
assert(lines[1]:find(YELLOW .. "worth watching", 1, true), "Header must be yellow: " .. lines[1])
print("Sync report: colored summary, worst-level header, red non-zero counters, stalled catch-up flagged OK")
