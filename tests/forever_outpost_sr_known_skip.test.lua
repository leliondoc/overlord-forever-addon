-- A map answer leaves out the keeps and outposts the requester already holds (2.0.2).
-- A third of every answer's rows were keeps the requester had (2026-10-13: 14 sites, 11
-- held, sent back in every answer). The request now lists one 3-character mark per held
-- site the requester holds whole (tenant with its signed capturer, capture in its ledger,
-- same sync date), salted by the request's nonce; an answer to that requester alone skips
-- the held rows whose mark matches. A capture it missed still arrives (its mark cannot
-- match), and older answerers read the list as part of a territorial request.
assert(loadfile("tests/forever_fortress_outpost.test.lua"))()
local op, sync, lb = Overlord.Outpost, Overlord.Sync, Overlord.Leaderboard
local NOW = 1790017000
for key in pairs(Overlord.OutpostSites) do
    local st = op:GetState(key)
    st.status, st.ownerGuild, st.ownerFaction, st.heldCapturerName, st.heldCapturerGuild = "neutral", "", nil, nil, nil
    st.updatedAt, st.claimedAt, st.holdTimeElapsed, st.expiresAt = 0, 0, 0, 0
end
local function hold(key, guild, capturer, claimedAt, updatedAt)
    local st = op:GetState(key)
    st.status, st.ownerGuild, st.ownerFaction = "held", guild, "Alliance"
    st.claimedAt, st.updatedAt = claimedAt, updatedAt or claimedAt
    st.heldCapturerName, st.heldCapturerGuild = capturer, guild
    return st
end
-- The ledger knows the capture of every held site but "silverpine" (a capture missed).
local ledger = { badlands = true, arathi = true, wetlands = true }
lb.HasOutpostEvent = function(_, siteKey) return ledger[siteKey] == true end
hold("badlands", "Keep Guild", "Given Family", NOW - 5000)
hold("arathi", "Hill Guild", "Other Person", NOW - 4000)
hold("wetlands", "Marsh Guild", "Third Person", NOW - 3000)
local function heldRows(queue)
    local found = {}
    for _, item in ipairs(queue) do
        local site, status = item.data:match("^v%d+:([^:]+):([^:]+):")
        if status == "held" then found[site] = true end
    end
    return found
end

-- (1) The requester's marks: one per held site it holds whole.
local NONCE = 4242
local marks = sync:BuildOutpostKnownMarks(NONCE)
assert(type(marks) == "string" and #marks == 9 and not marks:find("[^0-9a-z]"), "Not three marks: " .. tostring(marks))
local set = sync:ParseOutpostKnownMarks("k" .. marks)
local n = 0
for _ in pairs(set) do n = n + 1 end
assert(n == 3, "The marks did not parse back: " .. n)
-- A site whose capture is not in the ledger, or whose capturer is not signed, is not listed.
hold("silverpine", "Night Guild", "Fourth Person", NOW - 2000)
local unsigned = hold("stonetalon", "Wind Guild", "Fifth Person", NOW - 1000)
unsigned.heldCapturerGuild = "Another Guild"
ledger.stonetalon = true
assert(#sync:BuildOutpostKnownMarks(NONCE) == 9, "A site missing from the ledger or without a signed capturer was listed")
assert(sync:BuildOutpostKnownMarks(NONCE + 1) ~= sync:BuildOutpostKnownMarks(NONCE), "The marks are not salted by the nonce")
print("Keep marks: one per keep held whole, salted by the request")

-- (2) The answer to that requester alone leaves out exactly those rows.
local queue = {}
sync:AppendOutpostToSrQueue(queue, true, { set = set, nonce = NONCE })
local rows = heldRows(queue)
assert(not rows.badlands and not rows.arathi and not rows.wetlands, "A keep the requester holds was sent back")
assert(rows.silverpine and rows.stonetalon, "A keep the requester does not hold whole was left out")
assert(sync:GetOutpostKnownSkipped() >= 3, "The rows left out were not counted")
-- Without a list, or with another nonce: every row, as before.
queue = {}
sync:AppendOutpostToSrQueue(queue, true)
rows = heldRows(queue)
assert(rows.badlands and rows.arathi and rows.wetlands and rows.silverpine, "An answer without a list lost a row")
queue = {}
sync:AppendOutpostToSrQueue(queue, true, { set = set, nonce = NONCE + 7 })
rows = heldRows(queue)
assert(rows.badlands and rows.arathi and rows.wetlands, "Marks matched under another nonce")
-- The answerer's state is newer (a failed assault restored, a later sync date): that row goes.
op:GetState("arathi").updatedAt = NOW - 100
queue = {}
sync:AppendOutpostToSrQueue(queue, true, { set = set, nonce = NONCE })
rows = heldRows(queue)
assert(rows.arathi and not rows.badlands, "A keep whose sync date moved was left out")
op:GetState("arathi").updatedAt = NOW - 4000
-- Another tenant on the same site (a capture the requester missed): its row goes.
op:GetState("wetlands").ownerGuild, op:GetState("wetlands").heldCapturerGuild = "Swamp Guild", "Swamp Guild"
queue = {}
sync:AppendOutpostToSrQueue(queue, true, { set = set, nonce = NONCE })
assert(heldRows(queue).wetlands, "A capture the requester missed was left out")
op:GetState("wetlands").ownerGuild, op:GetState("wetlands").heldCapturerGuild = "Marsh Guild", "Marsh Guild"
-- Sites in progress are always sent.
local siege = op:GetState("crossroads")
if siege then
    siege.status, siege.ownerGuild, siege.ownerFaction, siege.updatedAt = "in_progress", "Raid Guild", "Horde", NOW - 30
    queue = {}
    sync:AppendOutpostToSrQueue(queue, true, { set = set, nonce = NONCE })
    local seen = false
    for _, item in ipairs(queue) do if item.data:find("^v%d+:crossroads:in_progress:") then seen = true end end
    assert(seen, "A site in progress was left out")
    siege.status, siege.ownerGuild, siege.ownerFaction, siege.updatedAt = "neutral", "", nil, 0
end
print("Keep marks: the answer leaves out exactly the keeps held whole, never a missed capture or a siege")

-- (3) Malformed lists are ignored (every row).
for _, bad in ipairs({ "k", "kab", "kABC", "k12!", "x123", "k" .. string.rep("abc", 13) }) do
    assert(sync:ParseOutpostKnownMarks(bad) == nil, "A malformed list was taken: " .. bad)
end

-- (4) The request: "k<marks>" before the mode of a territorial request only; older
-- answerers split it into six fields and read a territorial request ending in ":T".
local payload = sync:GetSRPayload("T")
local f = {}
for part in (payload .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end
assert(#f == 7 and f[6]:sub(1, 1) == "k" and f[7] == "T", "Not a territorial request with marks: " .. payload)
for _, mode in ipairs({ "F", "S", "H" }) do
    assert(sync:GetSRPayload(mode):match(":" .. mode .. "$") and not sync:GetSRPayload(mode):find(":k", 1, true),
        "A " .. mode .. " request carries marks")
end
local _, _, _, _, _, oldMode = strsplit(":", payload, 6)
assert(oldMode ~= "F" and oldMode ~= "S" and oldMode ~= "H" and payload:match(":T$"),
    "An older answerer would not read a territorial request: " .. tostring(oldMode))

-- (5) The answer honours the list only when it goes to the requester alone. Each ask
-- comes 10 min after the last (past every answer cooldown) and wins the answer draw, so
-- an answer is built every time: false means built without the list.
local captured = {}
local realAppend = sync.AppendOutpostToSrQueue
sync.AppendOutpostToSrQueue = function(self, q, minimal, known) captured[#captured + 1] = known or false end
local realAfter, realTicker, realTime, realRandom = C_Timer.After, C_Timer.NewTicker, GetTime, math.random
C_Timer.After = function(_, fn) fn() end
C_Timer.NewTicker = function() return { Cancel = function() end } end
local clock = realTime()
GetTime = function() return clock end
math.random = function() return 0 end
Overlord.InActiveFront = true
local function ask(sender, channel, replyTo)
    captured = {}
    clock = clock + 600
    sync:OnSyncRequest(sender, sync:GetSRPayload("T"), channel, replyTo)
    return captured[1]
end
local whispered = ask("Whisper Tester", "WHISPER")
assert(type(whispered) == "table" and whispered.set and whispered.nonce > 0, "A whispered request's marks were not honoured")
local friend = ask("Friend Tester", "BNET")
assert(type(friend) == "table" and friend.set, "A Battle.net request's marks were not honoured")
-- A relay broadcast is answered to its requester alone (SendWhisper's route).
local relayed = ask("Relay Tester", "CHANNEL", "Relay Tester")
assert(type(relayed) == "table" and relayed.set, "A relay broadcast request's marks were not honoured")
for _, heard in ipairs({ "CHANNEL", "RAID", "PARTY" }) do
    local got = ask(heard .. " Tester", heard)
    assert(got == false, "Marks were honoured, or no answer built, on a " .. heard .. " request: " .. tostring(got))
end
sync.AppendOutpostToSrQueue, C_Timer.After, C_Timer.NewTicker = realAppend, realAfter, realTicker
GetTime, math.random = realTime, realRandom
print("Keep marks: honoured on an answer to the requester alone (whisper, Battle.net, relay), never group or channel")

-- (6) Group and channel copies of a request leave the list out (their answers are heard
-- by all); the relay dedup still sees the marked payload first (Sync:Send, SendToChannel).
local marked = sync:GetSRPayload("T")
assert(marked:find(":k", 1, true), "No marks to leave out: " .. marked)
local plain = sync:WithoutKeepMarks(marked)
assert(not plain:find(":k", 1, true) and plain:match(":T$") and select(6, strsplit(":", plain, 6)) == "T",
    "The marks were not left out: " .. plain)
assert(sync:WithoutKeepMarks(plain) == plain, "A request without marks was changed")
local full = sync:GetSRPayload("F")
assert(sync:WithoutKeepMarks(full) == full, "A full request was changed")
print("Keep marks: left out of group and channel copies")
