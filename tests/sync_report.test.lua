-- /ov network: colored summary first (ok / watch / problem), then grey details with
-- non-zero loss or refusal counters in red. Real Commands.lua on the beta fixture.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()

local sync, net = Overlord.Sync, Overlord.Relay
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
assert(loadfile("NetworkHealth.lua"))() -- summary shared with the panel indicator
assert(loadfile("Commands.lua"))()

local GREEN, YELLOW, RED = "|cFF00FF00", "|cFFFFD100", "|cFFFF4444"
local function run(command)
    lines = {}
    sync._historyCatchupStats, sync._historyCatchupPending = nil, nil
    SlashCmdList.OVERLORD(command or "network")
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
assert(find(out, "Leaderboard catch-up") and find(out, "Capture history catch-up") and find(out, "Relay queue")
    and find(out, "Keep/outpost captures"), "A summary row is missing")
local details = 0
for i, line in ipairs(out) do if line:find("Details:", 1, true) then details = i end end
assert(details == 8, "Summary must be the header plus six rows before the details, got " .. details)
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
-- 2.0.2: the relay's own counters and the ranking catch-up are in /ov relay; /ov network
-- keeps the summary and the map, and says where the rest is.
assert(not find(out, "Relay outcomes since login") and not find(out, "Relay by type since login")
    and not find(out, "Ladder v8") and not find(out, "Incoming Overlord packets"),
    "/ov network still prints the relay details")
assert(find(out, "Battle.net bridges") and find(out, "Map pulls on a neighbour's presence")
    and find(out, "Enemy capture finals"), "/ov network lost a map or bridge line")
assert(out[#out]:find("More:", 1, true) and out[#out]:find("/ov relay", 1, true),
    "/ov network does not end by naming /ov relay: " .. out[#out])
assert(#out <= 22, "/ov network is long again: " .. #out .. " lines")
out = run("relay")
assert(not find(out, "Network status:") and not find(out, "Battle.net bridges"),
    "/ov relay repeats the summary or the bridge lines")
assert(find(out, "Relay by type since login") and find(out, "VB relay") and find(out, "Bridge election")
    and find(out, "Incoming Overlord packets"), "/ov relay lost a relay line")
local outcomes = assert(find(out, "Relay outcomes since login"), "Relay outcomes detail missing")
assert(outcomes:find("local admission refused " .. RED .. "40|r", 1, true),
    "A non-zero refusal counter is not red: " .. outcomes)
assert(not outcomes:find(RED .. "0|r", 1, true), "A zero counter was painted red")
local dropped = assert(find(out, " 1000 sent, 1040 received"), "Relay detail missing")
assert(dropped:find(RED .. "60|r", 1, true), "Dropped count not red: " .. dropped)
-- The French aliases.
assert(find(run("relais"), "Relay outcomes since login") and find(run("reseau"), "Network status:"),
    "/ov relais or /ov reseau is not understood")

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
-- The indicator judges the last 10 minutes, not the session: a burst of refusals
-- (joining a group) turns green again once it leaves the window, and a lone refusal
-- or 1 % at most is normal.
do
    local NH = Overlord.NetworkHealth
    NH:_ResetWindow()
    sync.GetHistoryCatchupSummary = nil
    net.stats.sent, net.stats.dropped, net.stats.received = 1000, 30, 1000
    sync._addonSendStats = { PARTY = { ok = 175, refused = 17 }, WHISPER = { ok = 900, refused = 0 } }
    NH:NoteSend(1000)
    local level = NH:IndicatorLevel()
    assert(level == "ok", "The window base must hide refusals older than the window, got " .. level)
    sync._addonSendStats.PARTY = { ok = 175 + 100, refused = 17 + 1 }
    net.stats.sent = 2000
    assert(NH:IndicatorLevel() == "ok", "A lone refusal turned the indicator yellow")
    sync._addonSendStats.PARTY = { ok = 175 + 100, refused = 17 + 6 }
    net.stats.dropped = 30 + 40
    local _, rows = NH:IndicatorLevel()
    local throttle
    for _, row in ipairs(rows) do if row.id == "throttle" then throttle = row end end
    assert(throttle.level ~= "ok" and throttle.text:find("6 refused (party 6/106", 1, true)
        and throttle.text:find("last 10 min", 1, true), "Recent refusals not counted: " .. throttle.text)
    -- Ten minutes later the base moves forward and the burst is forgotten.
    NH:NoteSend(1000 + 300)
    assert(NH:IndicatorLevel() ~= "ok", "Refusals inside the window were forgotten too early")
    NH:NoteSend(1000 + 900)
    assert(NH:IndicatorLevel() == "ok", "A burst older than ten minutes kept the indicator yellow")
    NH:_ResetWindow()
end
-- Copies of other players' packets the relay refuses to forward (no route to the
-- target, loop, relay budget) lose none of the player's data: they are reported
-- apart and never color the indicator (2026-10-06: 65 of 1230, all without a
-- route, turned the header red). The player's own losses still do.
do
    local NH = Overlord.NetworkHealth
    NH:_ResetWindow()
    sync._addonSendStats = { CHANNEL = { ok = 73, refused = 0 }, WHISPER = { ok = 1061, refused = 0 } }
    net.stats.sent, net.stats.received, net.stats.dropped = 1230, 2317, 65
    net.stats.localRejected, net.stats.relayRejected = 0, 0
    net.stats.forwardNoTask, net.stats.forwardNoTaskMissing, net.stats.forwardNoTaskLoop = 65, 57, 8
    local level, rows = NH:IndicatorLevel()
    local relayRow
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(level == "ok" and relayRow.level == "ok", "Unforwarded copies for others colored the indicator")
    assert(relayRow.text:find("0 lost of 1230 sent (0.0%), 2317 received, 65 copies for others not forwarded", 1, true),
        "Relay row must report copies for others apart: " .. relayRow.text)
    -- Relay budget refusals of copies for others count apart too.
    net.stats.dropped, net.stats.relayRejected = 65 + 30, 30
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.level == "ok" and relayRow.text:find("0 lost of 1230", 1, true)
        and relayRow.text:find("95 copies for others", 1, true), "Relay budget refusals: " .. relayRow.text)
    -- 70 own messages refused on top: red again.
    net.stats.dropped, net.stats.localRejected = 95 + 70, 70
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.level == "bad" and relayRow.text:find("70 lost of 1230 sent (5.7%)", 1, true),
        "Own losses must still turn the row red: " .. relayRow.text)
    -- 2.0.2: own rows for one peer that the queue refused are offered again by their
    -- sender (a map answer's row, a ranking page): reported apart, never a loss.
    net.stats.dropped, net.stats.localRejected, net.stats.localRetried = 95 + 70 + 300, 70 + 300, 300
    net.stats.localRowsRefused = 300
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.text:find("70 lost of 1230 sent (5.7%)", 1, true)
        and relayRow.text:find("300 own rows offered again", 1, true), "Rows offered again: " .. relayRow.text)
    -- Never more credit than the rows refused in the window: rows refused before it and
    -- offered again inside it do not hide the window's real losses.
    net.stats.localRowsRefused = 100
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.text:find("270 lost of 1230", 1, true), "Credit beyond the window's refusals: " .. relayRow.text)
    net.stats.dropped, net.stats.localRejected, net.stats.localRetried, net.stats.localRowsRefused = 95 + 70, 70, 0, 0
    -- Rows for others that reached us without a route from here: said, never a loss.
    net.stats.addressedNoRoute = 12
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.text:find("70 lost of 1230 sent", 1, true)
        and relayRow.text:find("12 copies for others without a route from here", 1, true), "No route: " .. relayRow.text)
    net.stats.addressedNoRoute = 0
    -- Inside the 10-minute window, earlier unforwarded copies are subtracted from the base.
    NH:NoteSend(5000)
    net.stats.dropped, net.stats.forwardNoTask = net.stats.dropped + 40, net.stats.forwardNoTask + 40
    net.stats.sent = 1230 + 500
    _, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.level == "ok" and relayRow.text:find("0 lost of 500 sent", 1, true)
        and relayRow.text:find("40 copies for others not forwarded", 1, true), "Windowed: " .. relayRow.text)
    NH:_ResetWindow()
    net.stats.dropped, net.stats.localRejected, net.stats.relayRejected = 0, 0, 0
    net.stats.forwardNoTask, net.stats.forwardNoTaskMissing, net.stats.forwardNoTaskLoop = 0, 0, 0
    net.stats.localRetried = 0
end
-- 2.0.1: copies that expired in the relay queue are reported, and a capture's end among
-- them is worth watching (2026-10-12: a bridge said "all good" with 233 expired copies,
-- three capture finals included, while the other faction's map stayed behind).
do
    local NH = Overlord.NetworkHealth
    NH:_ResetWindow()
    sync._addonSendStats = { CHANNEL = { ok = 152, refused = 0 }, WHISPER = { ok = 622, refused = 0 } }
    net.stats.sent, net.stats.received, net.stats.dropped = 1582, 2790, 8
    net.stats.expired, net.stats.expiredFinals = 162, 0
    local level, rows = NH:IndicatorLevel()
    local relayRow
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.text:find("8 lost of 1582 sent (0.5%), 2790 received, 162 expired in the queue", 1, true)
        and not relayRow.text:find("capture ends", 1, true), "Expired copies must be reported: " .. relayRow.text)
    assert(level == "ok" and relayRow.level == "ok", "Routine copies that expired colored the indicator")
    net.stats.expired, net.stats.expiredFinals = 233, 3
    level, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(relayRow.level == "warn" and level == "warn"
        and relayRow.text:find("233 expired in the queue (3 capture ends)", 1, true),
        "An expired capture end must be worth watching: " .. relayRow.text)
    -- Ten minutes later, with nothing new, the window forgets them.
    NH:NoteSend(9000)
    NH:NoteSend(9000 + 900)
    level, rows = NH:IndicatorLevel()
    for _, row in ipairs(rows) do if row.id == "relay" then relayRow = row end end
    assert(level == "ok" and not relayRow.text:find("expired", 1, true),
        "Expired copies older than the window still showed: " .. relayRow.text)
    -- The relay counts a capture's end apart when it expires, and only those.
    net.stats.expiredFinals = 0
    net.NoteExpiredFinal({ kind = "C", payload = "zone:Name:Horde:1" })
    net.NoteExpiredFinal({ kind = "ZS", payload = "zone:captured:0:0:H:1" })
    net.NoteExpiredFinal({ kind = "ZR", payload = "zone:wave:Name:x" })
    net.NoteExpiredFinal({ kind = "ZS", payload = "zone:in_progress:0:5:H:1" })
    net.NoteExpiredFinal({ kind = "FK", payload = "x" })
    assert(net.stats.expiredFinals == 3, "Capture ends counted: " .. tostring(net.stats.expiredFinals))
    -- A capture (not a release) that expired is handed to the map news of Sync.
    local again, realNews = {}, sync.NoteMapNews
    sync.NoteMapNews = function(_, zoneId) again[#again + 1] = zoneId end
    net.NoteExpiredFinal({ kind = "C", payload = "zone_c:Name:Horde:1" })
    net.NoteExpiredFinal({ kind = "ZS", payload = "zone_s:captured:0:0:H:1" })
    net.NoteExpiredFinal({ kind = "ZS", payload = "zone_a:available:0:0::1" })
    net.NoteExpiredFinal({ kind = "ZR", payload = "zone_r:wave:Name:x" })
    sync.NoteMapNews = realNews
    assert(#again == 2 and again[1] == "zone_c" and again[2] == "zone_s",
        "Expired capture ends handed to the map news: " .. table.concat(again, ","))
    -- Only when a channel copy is among the copies that did not leave (a Battle.net
    -- copy lost alone leaves our channel informed), and counted once per packet (its
    -- two channel fragments wait, and expire, apart).
    do
        local told, real = {}, sync.NoteMapNews
        sync.NoteMapNews = function(_, zoneId) told[#told + 1] = zoneId end
        local before = net.stats.expiredFinals
        local packet = { kind = "C", payload = "zone_t:Name:Horde:1" }
        net.NoteExpiredFinal(packet, { { transport = "BNET" }, { transport = "WHISPER" } }, 1)
        assert(#told == 0, "A capture end whose channel copy had left was announced again")
        net.NoteExpiredFinal(packet, { { transport = "CHANNEL" }, { transport = "BNET" } }, 2)
        assert(#told == 0, "A channel copy already sent counted as lost")
        net.NoteExpiredFinal(packet, { { transport = "BNET" }, { transport = "CHANNEL" } }, 1)
        net.NoteExpiredFinal(packet, { { transport = "CHANNEL" } }, 1)
        sync.NoteMapNews = real
        assert(#told == 2 and told[1] == "zone_t", "A lost channel copy was not handed to the map news")
        assert(net.stats.expiredFinals == before + 1,
            "One packet's fragments counted as several capture ends: " .. (net.stats.expiredFinals - before))
    end
    -- A news page is live traffic for the relay, a whole-map page is not.
    assert(net:IsUrgentPacket("ZA", "@P-1790017000-7:1:1|zone_c:H:5:5"), "A map news page is not served as live traffic")
    assert(not net:IsUrgentPacket("ZA", "@G-1790017000-7:1:14|zone_c:H:5:5"), "A whole-map page is served as live traffic")
    -- One shape for the news on both sides: what the relay serves as news is what Sync
    -- lets on the channel (one to three pages), and nothing else.
    for _, header in ipairs({ "@P-1790017000-7:1:1|", "@P-1790017000-7:3:3|", "@P-1790017000-7:2:4|",
        "@P-1790017000-7:5:17|", "@G-1790017000-7:1:3|", "@P-x:1:1|" }) do
        local page = header .. "zone_c:H:5:5"
        assert(net.IsMapNews({ kind = "ZA", target = "*", payload = page }) == sync:ChannelCarries("ZA", page, true),
            "The relay and the channel rule disagree on what a news page is: " .. header)
    end
    assert(not net.IsMapNews({ kind = "ZA", target = "Someone", payload = "@P-1790017000-7:1:1|zone_c:H:5:5" }),
        "An addressed partial map counts as news")
    NH:_ResetWindow()
    net.stats.dropped, net.stats.expired, net.stats.expiredFinals = 0, 0, 0
end
print("Sync report: colored summary, worst-level header, red non-zero counters, stalled catch-up flagged OK")
