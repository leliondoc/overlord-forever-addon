-- 2.2.2: a whole map is taken atomically (14 to 17 pages, two whispers each): one lost whisper
-- voids it. An answer still incomplete 30 s after its first page is asked again, once, of the
-- same sender; bounded in a row and per window; a complete answer arms nothing.
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
local priv = upvalue(sync.WatchMapBatch, "priv")
local clock, timers, whispers, inInstance = 1000, {}, {}, false
function GetTime() return clock end
function IsInInstance() return inInstance end
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end,
    NewTicker = function() return {} end }
sync.SendWhisper = function(_, kind, payload, target) whispers[#whispers + 1] = { kind, payload, target }; return true end
local function advance(seconds)
    local stop = clock + seconds
    repeat
        table.sort(timers, function(a, b) return a.at < b.at end)
        local nextTimer = timers[1]
        if not nextTimer or nextTimer.at > stop then break end
        table.remove(timers, 1)
        clock = math.max(clock, nextTimer.at)
        nextTimer.fn()
    until false
    clock = stop
end
local function batch(received, count)
    local b = { createdAt = clock, lastAt = clock, pageCount = count or 15, receivedCount = received, pages = {} }
    for i = 1, received do b.pages[i] = "body" .. i end
    return b
end
-- Releases the senders announce (2.2.2 unless set): only 2.2.2 knows the repair mode.
local releases = {}
Overlord.ChannelDirectory = Overlord.ChannelDirectory or {}
Overlord.ChannelDirectory.PeerSettles = function(_, name) return (releases[name] or "2.2.2") == "2.2.2" end
local function watch(key, b, sender)
    priv.pendingZaSnapshotPages[key] = b
    sync:WatchMapBatch(sender or "Peer Ally", key, b, "G-1790000000-" .. key)
end

-- 1. Incomplete after 30 s: one SR to the same sender, a few seconds later; nothing before.
local b = batch(11)
watch("k1", b)
advance(29)
assert(#whispers == 0, "asked again before the answer had time to arrive")
advance(12)
assert(#whispers == 1 and whispers[1][1] == "SR" and whispers[1][3] == "Peer Ally"
    and whispers[1][2]:match(":RG%-1790000000%-k1%.12,13,14,15$"),
    "an incomplete map was not repaired with its missing pages: " .. tostring(whispers[1] and whispers[1][2]))
assert(sync._mapRetried == 1)

for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 1b. A sender on 2.2.1 would answer a whole map: never asked for a repair.
whispers = {}
releases["Old Ally"] = "2.2.1"
watch("k1b", batch(11), "Old Ally")
advance(60)
assert(#whispers == 0, "a 2.2.1 sender was asked for a map repair")
for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 2. Complete (or no longer pending): nothing.
whispers = {}
local done = batch(15)
watch("k2", done)
local gone = batch(3)
watch("k3", gone)
priv.pendingZaSnapshotPages.k3 = nil
advance(60)
assert(#whispers == 0, "a complete or dropped batch armed a retry")

for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 3. Pages still arriving at 30 s: one more look 12 s later, retry only if still stuck.
local slow = batch(10)
watch("k4", slow)
advance(25)
slow.lastAt = clock
advance(8)
assert(#whispers == 0, "asked again while pages were still arriving")
advance(20)
assert(#whispers == 1 and whispers[1][2]:match("%.11,12,"), "a stuck batch was not repaired after the second look")

for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 4. At most MAP_RETRY_CHAIN in a row; a complete map starts the count again.
whispers = {}
sync._mapRetryChain, sync._mapRetryWindow = 0, nil
for i = 1, 4 do
    watch("c" .. i, batch(12))
    advance(60)
end
assert(#whispers == sync.MAP_RETRY_CHAIN, "retries in a row were not bounded: " .. #whispers)
sync._mapRetryChain = 0
sync:NoteFullMapReceived("Peer Ally")
assert(sync._mapRetryChain == 0)
watch("c5", batch(12))
advance(60)
assert(#whispers == sync.MAP_RETRY_CHAIN + 1, "a complete map did not allow a new retry")

for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 5. The window budget bounds them even when maps complete in between.
whispers = {}
sync._mapRetryChain, sync._mapRetryWindow = 0, nil
for i = 1, 10 do
    watch("w" .. i, batch(12))
    advance(40)
    sync._mapRetryChain = 0
end
assert(#whispers == sync.MAP_RETRY_BUDGET, "the window budget did not hold: " .. #whispers)
advance(sync.MAP_RETRY_WINDOW)
watch("w11", batch(12))
advance(60)
assert(#whispers == sync.MAP_RETRY_BUDGET + 1, "the budget did not renew with the window")

for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
-- 6. Nothing in an instance.
whispers = {}
sync._mapRetryChain, sync._mapRetryWindow = 0, nil
inInstance = true
watch("i1", batch(12))
advance(60)
assert(#whispers == 0, "a retry left from inside an instance")
inInstance = false

-- 6b. (Judge, 2.2.2) More than a third missing: a congested lane, left to the next round; a
-- batch gone quiet past the drop is dropped, never repaired; a complete map of that side that
-- came meanwhile leaves the batch alone; only peers we asked ourselves are watched.
for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
whispers = {}
sync._mapRetryChain, sync._mapRetryWindow = 0, nil
watch("t1", batch(3))
advance(60)
assert(#whispers == 0, "a batch missing most of its pages was repaired")
local quiet = batch(12)
quiet.lastAt = clock - 20
watch("t2", quiet)
advance(60)
assert(#whispers == 0 and priv.pendingZaSnapshotPages.t2 == nil, "a batch gone quiet was repaired or kept")
watch("t3", batch(12))
advance(5)
sync:NoteFullMapReceived("Peer Ally")
advance(60)
assert(#whispers == 0, "a batch was repaired after a complete map of its side arrived")
assert(not sync:WasMapAsked("Never Asked"), "a peer we never asked is watched")
sync:NoteMapAsked("Asked Peer")
assert(sync:WasMapAsked("Asked Peer"), "a peer we asked is not watched")
advance(91)
assert(not sync:WasMapAsked("Asked Peer"), "an old request still arms the watch")

-- 7. Responder: keeps the pages it served, sends only the missing ones, paced, twice at most.
local pages = {}
for i = 1, 15 do pages[i] = "@G-1790000000-77:" .. i .. ":15|body" .. i end
sync:NoteServedMap("Peer Ally", pages)
whispers = {}
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.3,9,3,99") == true)
advance(10)
assert(#whispers == 2 and whispers[1][1] == "ZA" and whispers[1][2] == pages[3] and whispers[2][2] == pages[9]
    and whispers[1][3] == "Peer Ally", "the repair did not send exactly the missing pages once each")
-- another requester, another id, an unknown id, a third round: nothing.
whispers = {}
assert(sync:RespondMapRepair("Other Player", "RG-1790000000-77.3") == false, "a repair for a map never served")
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-78.3") == false, "a repair for another snapshot")
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.4") == true)
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.5") == false, "more repair rounds than allowed")
advance(10)
assert(#whispers == 1)
-- too old, or in an instance
sync:NoteServedMap("Peer Ally", pages)
advance(sync.MAP_SERVED_SEC + 1)
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.3") == false, "a repair from an expired snapshot")
sync:NoteServedMap("Peer Ally", pages)
inInstance = true
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.3") == false, "a repair from inside an instance")
inInstance = false
-- an answer queue still busy: no repair beside it
sync:NoteServedMap("Peer Ally", pages)
priv.syncResponseDeadline = clock + 30
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.3") == false, "a repair beside a busy answer queue")
priv.syncResponseDeadline = 0
-- a bad mode never answers
assert(sync:RespondMapRepair("Peer Ally", "RG-1790000000-77.") == false)
assert(sync:RespondMapRepair("Peer Ally", "R" .. ("x"):rep(50) .. ".1") == false)
-- 8. One requester cannot multiply page answers by asking for a new whole map: a budget over a window.
priv.syncResponseDeadline = 0
whispers = {}
sync:NoteServedMap("Budget Peer", pages)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.3") == true)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.4") == true)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.5") == false)
sync:NoteServedMap("Budget Peer", pages)          -- a new map request: the snapshot's count starts over
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.3") == true)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.4") == true)
sync:NoteServedMap("Budget Peer", pages)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.3") == false,
    "a requester multiplied repairs by asking for a new map")
-- Another requester has its own budget; the first one's comes back after the window.
sync:NoteServedMap("Honest Peer", pages)
assert(sync:RespondMapRepair("Honest Peer", "RG-1790000000-77.3") == true)
advance(sync.MAP_REPAIR_WINDOW + 1)
sync:NoteServedMap("Budget Peer", pages)
assert(sync:RespondMapRepair("Budget Peer", "RG-1790000000-77.3") == true, "the budget never came back")
-- The table of budgets stays bounded.
for i = 1, 60 do
    local who = "Flood Peer" .. string.char(96 + i % 26 + 1) .. string.char(96 + math.floor(i / 26) + 1)
    sync:NoteServedMap(who, pages)
    sync:RespondMapRepair(who, "RG-1790000000-77.3")
end
local rowsKept = 0
for _ in pairs(priv.zaRepairBudget) do rowsKept = rowsKept + 1 end
assert(rowsKept <= sync.MAP_REPAIR_BUDGET_ROWS, "repair budgets grew to " .. rowsKept)
advance(10)

-- 9. A repair page our own relay queue refuses (nothing left the client) is offered again, a few
-- times at most.
priv.syncResponseDeadline = 0
whispers = {}
local refusals = 2
sync.SendWhisper = function(_, kind, payload, target)
    if kind == "ZA" and refusals > 0 then refusals = refusals - 1; return false end
    whispers[#whispers + 1] = { kind, payload, target }; return true
end
sync:NoteServedMap("Queue Peer", pages)
assert(sync:RespondMapRepair("Queue Peer", "RG-1790000000-77.6") == true)
advance(10)
assert(#whispers == 1 and whispers[1][2] == pages[6] and whispers[1][3] == "Queue Peer",
    "a repair page refused by our own queue was lost")
local offersSeen = 0
sync.SendWhisper = function() offersSeen = offersSeen + 1; return false end
sync:NoteServedMap("Stuck Peer", pages)
assert(sync:RespondMapRepair("Stuck Peer", "RG-1790000000-77.6") == true)
advance(30)
assert(offersSeen == sync.MAP_REPAIR_OFFERS, "a refused repair page was offered " .. offersSeen .. " times")
sync.SendWhisper = function(_, kind, payload, target) whispers[#whispers + 1] = { kind, payload, target }; return true end

-- 10. A repair that brought nothing back (the sender's queue was busy, or its pages were lost on
-- the way): the batch is kept from the repair on and asked once more, within the chain.
for key in pairs(priv.pendingZaSnapshotPages) do priv.pendingZaSnapshotPages[key] = nil end
advance(120)
whispers = {}
sync._mapRetryChain, sync._mapRetryWindow = 0, nil
local unanswered = batch(13)
watch("r1", unanswered)
advance(35)
assert(#whispers == 1, "the first repair was not asked")
advance(40)
assert(priv.pendingZaSnapshotPages.r1 == unanswered, "the batch was dropped while its repair was in flight")
assert(#whispers == 2 and whispers[2][1] == "SR" and whispers[2][3] == "Peer Ally"
    and whispers[2][2]:match(":RG%-1790000000%-r1%.14,15$"),
    "a repair that brought nothing back was never asked again")
advance(60)
assert(#whispers == 2, "repairs of one batch went past the chain")

print("Map batch repair: missing pages only, bounded, only for an incomplete answer OK")
