-- Gurubashi Arena (Arena.lua): its own small engine. Free-for-all: any guild takes it from any
-- other, its own faction included; 5 minutes in the pit with no player of another guild alive
-- in it. A plain set of rows folded at read time (same rows, same board, whatever the order);
-- believed first-hand from the capturer, by content otherwise; a bounded point-to-point
-- catch-up; gone in instances. Real Sync + Relay on the beta fixture.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
assert(loadfile("Arena.lua"))()

local AR, s, lb = Overlord.Arena, Overlord.Sync, Overlord.Leaderboard
-- A week that began two days ago.
local server = 1790300000
local campaign = server - 200000
Overlord.GetCurrentCampaignStartTs = function() return campaign end
assert(lb:GetCurrentCampaignStart() == campaign, "fixture: campaign start")
GetServerTime = function() return server end
local clock = 1000
GetTime = function() return clock end
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
local POOL = Overlord:GetCurrentLeaderboardSavedVarsPool()

local function reset()
    OverlordDB.arena = nil
    AR._fold, AR.ask, AR.tried, AR.caughtUpAt, AR.answered, AR.answerBudget = nil, nil, nil, nil, nil, nil
    AR:Store()
end
local function know(name, guild, faction)
    lb.kills[name] = 5
    lb.playerInfo[name] = { class = "WARRIOR", faction = faction or "Alliance", level = 30, locale = "enus",
        guild = guild or "", guildAt = guild and server or 0, guildAuth = guild and true or nil }
end
local function board()
    AR._fold = nil
    return AR:GetBoard()
end
local function boardText(b)
    local parts = { "holder=" .. (b.holder and b.holder.guild or "-") }
    for _, g in ipairs(b.guilds) do parts[#parts + 1] = g.guild .. "=" .. g.captures end
    for _, r in ipairs(b.recent) do parts[#parts + 1] = r.ts .. ":" .. r.guild .. "<" .. tostring(r.previous) end
    return table.concat(parts, " ")
end

-- 1. The fold: same rows in any order, same board. Spacing and a guild's own re-take skipped.
local rows = {
    { server - 5000, "Alliance", "Ann Alpha", "Guild One" },
    { server - 4000, "Alliance", "Bob Beta", "Guild Two" },        -- same faction: takes it
    { server - 3900, "Horde", "Hal Gamma", "Guild Three" },        -- 100 s later: impossible, skipped
    { server - 3000, "Alliance", "Bob Beta", "Guild Two" },        -- already theirs: skipped
    { server - 2000, "Horde", "Hal Gamma", "Guild Three" },
    { server - 1000, "Alliance", "Ann Alpha", "Guild One" },
}
local orders = { { 1, 2, 3, 4, 5, 6 }, { 6, 5, 4, 3, 2, 1 }, { 3, 6, 1, 5, 2, 4 } }
local expected
for _, order in ipairs(orders) do
    reset()
    for _, i in ipairs(order) do
        local r = rows[i]
        assert(AR:AddRow(r[1], r[2], r[3], r[4], "own"), "fixture row refused")
    end
    local text = boardText(board())
    expected = expected or text
    assert(text == expected, "the board depends on the order rows came in:\n" .. expected .. "\n" .. text)
end
local b = board()
assert(b.holder.guild == "Guild One" and b.count == 4, "wrong holder or count: " .. boardText(b))
assert(b.guilds[1].guild == "Guild One" and b.guilds[1].captures == 2, "Guild One should lead with 2: " .. boardText(b))
assert(b.recent[1].previous == "Guild Three" and b.recent[3].guild == "Guild Two"
    and b.recent[3].previous == "Guild One", "a same-faction take was not shown as one: " .. boardText(b))
assert(not AR:AddRow(server - 1000, "Alliance", "Ann Alpha", "Guild One", "own"), "a known row counted twice")

-- 2. Trust. Relayed / caught up: judged by content; first-hand: the author's word.
reset()
know("Cara Delta", "Guild Four")
assert(AR:AddRow(server - 600, "Alliance", "Cara Delta", "Guild Four", "content"), "a row the ranking backs was refused")
know("Dan Epsilon", "Guild Five")
-- Another guild than the ranking's: kept waiting (never on the board), not dropped.
assert(AR:AddRow(server - 300, "Alliance", "Dan Epsilon", "Forged Guild", "content")
    and board().holder.guild == "Guild Four", "a row naming another guild than the ranking's was believed")
assert(not AR:AddRow(server - 300, "Alliance", "Dan Epsilon", "Forged Guild", "author")
    and board().holder.guild == "Guild Four", "the author's word beat the guild the ranking knows for him")
know("Eve Zeta", "Guild Six", "Horde")
assert(not AR:AddRow(server - 300, "Alliance", "Eve Zeta", "Guild Six", "content"), "a row of the wrong side was believed")
-- Nobody knows Fay's guild: relayed, the row waits off the board; known later, it shows.
assert(AR:AddRow(server - 300, "Horde", "Fay Eta", "Guild Seven", "content"), "a waiting row was not kept")
assert(board().holder.guild == "Guild Four", "a waiting row reached the board")
know("Fay Eta", "Guild Seven", "Horde")
assert(board().holder.guild == "Guild Seven", "a waiting row was not judged again once the ranking knew him")
-- First-hand while nobody knows his guild: believed (as his own kill row would be).
assert(AR:AddRow(server - 10, "Horde", "Gus Theta", "Guild Eight", "author"), "the capturer's own word was refused")
assert(board().holder.guild == "Guild Eight", "a first-hand capture is not on the board")
-- Dan's guild was stale in the ranking: once it knows his new guild, his waiting row is believed.
know("Dan Epsilon", "Forged Guild")
local danBelieved = false
for _, row in ipairs(board().believed) do if row.capturer == "Dan Epsilon" then danBelieved = true end end
assert(danBelieved, "a row waiting for the ranking's guild was dropped instead of judged again")
-- A relayed copy naming another guild never takes the real row's place: same date and capturer,
-- the real guild still comes in and is believed.
know("Ivy Iota", "Real Guild")
assert(AR:AddRow(server - 5, "Alliance", "Ivy Iota", "Copy Guild", "content"), "the altered copy was not kept waiting")
assert(AR:AddRow(server - 5, "Alliance", "Ivy Iota", "Real Guild", "content"), "an altered copy blocked the real capture")
local ivy
for _, row in ipairs(board().believed) do if row.capturer == "Ivy Iota" then ivy = row.guild end end
assert(ivy == "Real Guild", "the real capture is not believed: " .. tostring(ivy))
-- Bad rows: future, before the week, bad side, not a character name, guild needing cleaning.
assert(not AR:AddRow(server + 120, "Alliance", "Cara Delta", "Guild Four", "own"), "a future capture was taken")
assert(not AR:AddRow(campaign - 3 * 86400, "Alliance", "Cara Delta", "Guild Four", "own"), "last week's capture was taken")
assert(not AR:AddRow(campaign - 60, "Alliance", "Cara Delta", "Guild Four", "own"), "a capture one minute before the reset was taken")
assert(not AR:AddRow(server - 50, "Neutral", "Cara Delta", "Guild Four", "own"), "a capture without a side was taken")
assert(not AR:AddRow(server - 50, "Alliance", "Nobody", "Guild Four", "own"), "a non-character name was taken")
assert(not AR:AddRow(server - 50, "Alliance", "Cara Delta", "Guild:Four", "own"), "a guild name with a separator was taken")

-- 3. Through the real relay: first-hand from the capturer (believed), relayed for an unknown
-- capturer (waits), another realm type (ignored).
reset()
local function relayed(id, path, payload)
    s:OnBNetMessage("R2:Forever_eu_A:BR:eu|arena-" .. id .. "|" .. server .. "|*|" .. path .. "|AC|" .. payload, 123)
end
-- The fixture's ranking knows Bridge Tester as an Alliance player: a Horde capture in his name is refused.
relayed(1, "Bridge Tester", string.format("1:%s:%d:H:Bridge Tester:Bridge Guild", POOL, server - 900))
assert(not Overlord.Relay.stats.lastError, tostring(Overlord.Relay.stats.lastError))
assert(OverlordDB.arena[POOL].n == 0,
    "a first-hand capture by a player the ranking knows on the other side was taken")
-- Unknown to the ranking (no kill this week): first-hand believed, relayed kept waiting.
local savedHot, savedInfo = lb.GetHotPlayerGuildState, lb.playerInfo["Bridge Tester"]
lb.GetHotPlayerGuildState = function(self, name)
    if name == "Bridge Tester" or name == "Remote Tester" then return "", 0, false end
    return savedHot(self, name)
end
lb.playerInfo["Bridge Tester"] = nil
local savedRemote = lb.playerInfo["Remote Tester"]; lb.playerInfo["Remote Tester"] = nil
relayed(4, "Bridge Tester", string.format("1:%s:%d:H:Bridge Tester:Bridge Guild", POOL, server - 30))
assert(board().holder and board().holder.guild == "Bridge Guild", "a capture heard from its capturer was not believed")
relayed(2, "Remote Tester,Bridge Tester", string.format("1:%s:%d:A:Remote Tester:Remote Guild", POOL, server - 100))
assert(board().holder.guild == "Bridge Guild", "a relayed capture of an unknown capturer was believed on its word")
assert(OverlordDB.arena[POOL].n == 2, "the relayed row was not kept to be judged later")
relayed(3, "Bridge Tester", string.format("1:%s:%d:H:Bridge Tester:Bridge Guild", "otherpool", server - 100))
assert(OverlordDB.arena[POOL].n == 2, "another realm type's capture was taken")
Overlord.InstanceSuspended = true
assert(AR:OnReceive("AC", string.format("1:%s:%d:H:Bridge Tester:Bridge Guild", POOL, server - 50), "Bridge Tester", "BETA") == nil
    and OverlordDB.arena[POOL].n == 2, "a capture was read inside an instance")
Overlord.InstanceSuspended = nil
-- First-hand but dated 2 min ago: catch-up content, it waits like a relayed row (a back-dated
-- row in the capturer's own word would push the real holder out of the fold).
relayed(5, "Bridge Tester", string.format("1:%s:%d:H:Bridge Tester:Other Guild", POOL, server - 120))
assert(OverlordDB.arena[POOL].n == 3 and board().holder.guild == "Bridge Guild",
    "a back-dated capture was believed on its author's word")
Overlord.InstanceSuspended = true
Overlord.InstanceSuspended = false
lb.GetHotPlayerGuildState, lb.playerInfo["Bridge Tester"] = savedHot, savedInfo
lb.playerInfo["Remote Tester"] = savedRemote

-- 3b. Full ledger: a believed row leaves only for a believed row dated after it; a live
-- announce is dated now; a believed copy fixes a waiting row put on the other side.
reset()
do
    local savedMax = AR.ROWS_MAX
    AR.ROWS_MAX = 2
    assert(AR:AddRow(server - 50, "Alliance", "Ann Alpha", "Guild One", "own"))
    assert(AR:AddRow(server - 40, "Horde", "Bob Bravo", "Guild Two", "own"))
    assert(not AR:AddRow(server - 100, "Alliance", "Cid Charlie", "Guild Three", "own"),
        "an older row pushed a believed capture out of the full ledger")
    assert(not AR:AddRow(server - 5, "Alliance", "Zed Unknown", "Guild Nine", "content"),
        "a waiting row pushed a believed capture out of the full ledger")
    assert(not AR:AddRow(server - 4, "Alliance", "Zed Unknown", "Guild Ten", "author"),
        "an author's word with an unknown guild pushed a believed capture out of the full ledger")
    assert(AR:AddRow(server - 10, "Alliance", "Dan Delta", "Guild Four", "own"), "a newer capture found no room")
    assert(OverlordDB.arena[POOL].n == 2 and not OverlordDB.arena[POOL].rows[(server - 50) .. "|ann alpha|guild one"],
        "the oldest believed capture did not make room")
    -- A waiting row pushed out by another is counted too.
    AR:Store().rows[(server - 50) .. "|wai ting|guild w"] = { ts = server - 50, faction = "Alliance",
        capturer = "Wai Ting", guild = "Guild W" }
    AR:Store().n = 3
    AR:Evict(AR:Store(), server - 1, false)
    assert(AR.stats.evictedWaiting >= 1 and not AR:Store().rows[(server - 50) .. "|wai ting|guild w"],
        "a waiting row was pushed out without a count")
    local kept, waiting, refused, evicted = AR:GetStats()
    assert(kept == 2 and waiting == 0 and refused.full == 3 and evicted >= 1,
        "the full ledger's refusals or evictions are not counted")
    AR.ROWS_MAX = savedMax
    reset()
    local n0 = OverlordDB.arena[POOL].n or 0
    AR:OnCapture(string.format("1:%s:%d:A:Eve Echo:Guild Five", POOL, server - 400), "Eve Echo")
    assert((OverlordDB.arena[POOL].n or 0) == n0, "a live announce dated 400 s ago was kept")
    assert((AR.stats.refused.stale or 0) >= 1, "a stale live announce was dropped without a count")
    assert(AR:AddRow(server - 20, "Horde", "Fay Foxtrot", "Guild Six", "content") ~= nil)
    assert(AR:AddRow(server - 20, "Alliance", "Fay Foxtrot", "Guild Six", "own"), "the believed copy was refused")
    local fay = OverlordDB.arena[POOL].rows[(server - 20) .. "|fay foxtrot|guild six"]
    assert(fay and fay.trusted and fay.faction == "Alliance", "a waiting row on the other side blocked the real capture")
end

-- 3c. A flood of announces from one sender: the ninth in 5 s is dropped before the arena reads it.
do
    local dropped = 0
    for _ = 1, 9 do
        if s:SenderBurstShouldDrop("Flood Sender", "AC") then dropped = dropped + 1 end
    end
    assert(dropped == 1, "a flood of arena announces from one sender went through: " .. dropped)
end

-- 2b. An author's word alone (his guild unknown): believed once per spacing, for one guild.
reset()
local function believedOf(name)
    local n = 0
    for _, row in ipairs(board().believed) do if row.capturer == name then n = n + 1 end end
    return n
end
AR:AddRow(server - 3000, "Horde", "Hal Kappa", "Guild Nine", "author")
assert(believedOf("Hal Kappa") == 1, "an author's first word was not believed")
AR:AddRow(server - 2500, "Horde", "Hal Kappa", "Guild Ten", "author")
assert(believedOf("Hal Kappa") == 1, "an author's word naming a second guild was believed")
AR:AddRow(server - 2000, "Horde", "Hal Kappa", "Guild Nine", "author")
assert(believedOf("Hal Kappa") == 2, "the author's next capture of the same guild was refused")
AR:AddRow(server - 1900, "Horde", "Hal Kappa", "Guild Nine", "author")
assert(believedOf("Hal Kappa") == 2, "an author's word inside the spacing was believed")
-- (The rows not believed wait: the ranking knowing his guild judges them again.)
know("Hal Kappa", "Guild Ten", "Horde")
local tens = 0
for _, row in ipairs(board().believed) do if row.guild == "Guild Ten" then tens = tens + 1 end end
assert(tens == 1, "a waiting author row was not judged again once the ranking knew his guild")

-- 2c. Catch-up asks and pages only from a direct neighbour: relayed ones are refused.
reset()
do
    local net = Overlord.Relay
    local sent = 0
    local savedSend, savedContext = net.Send, net.context
    net.Send = function() sent = sent + 1; return true end
    local ask = string.format("1:%s:%d:0:0:1", POOL, campaign)
    net.context = { hops = 1 }
    AR:OnReceive("AQ", ask, "Relayed Asker", "BETA")
    assert(sent == 0, "a relayed catch-up ask was answered")
    net.context = nil
    AR:OnReceive("AQ", ask, "Contextless Asker", "BETA")
    assert(sent == 0, "an ask without a relay context was answered")
    net.context = { hops = 0 }
    AR:OnReceive("AQ", ask, "Direct Asker", "BETA")
    assert(sent == 1, "a direct neighbour's catch-up ask was refused")
    net.Send, net.context = savedSend, savedContext
end

-- 4. Catch-up: one neighbour asked, answers bounded, equal ledgers answer empty.
reset()
local net = Overlord.Relay
local sends = {}
local savedSend, savedPeers = net.Send, net.GetDirectPeers
net.Send = function(_, kind, payload, target) sends[#sends + 1] = { kind = kind, payload = payload, target = target }; return true end
net.GetDirectPeers = function() return { "Peer One" } end
for i = 1, 30 do
    know("Cap" .. string.char(96 + (i % 26) + 1) .. " Row", "Guild " .. i)
    assert(AR:AddRow(server - 90000 + i * 600, "Alliance", "Cap" .. string.char(96 + (i % 26) + 1) .. " Row", "Guild " .. i, "own"))
end
local n, sum = AR:Digest()
AR:OnAsk(string.format("1:%s:%d:%d:%d:1", POOL, campaign, n, sum), "Asker One")
assert(#sends == 1 and sends[1].kind == "AL" and sends[1].payload:match("^1:[^:]+:%d+:1:0:%d+:%d+:$"),
    "an equal ledger was not answered empty: " .. tostring(sends[1] and sends[1].payload))
clock = clock + 5
AR:OnAsk(string.format("1:%s:%d:0:0:1", POOL, campaign), "Asker One")
assert(#sends == 1, "the same asker was answered twice within 20 s")
AR:OnAsk(string.format("1:%s:%d:0:0:1", POOL, campaign), "Asker Two")
assert(#sends == 2, "a second asker was not answered")
local page = sends[2].payload
local pages = tonumber(page:match("^1:[^:]+:%d+:1:(%d+):"))
local _, count = page:gsub("=", "")
assert(pages == 2 and count + 1 == AR.PAGE_ROWS, "first page wrong: pages " .. tostring(pages) .. ", rows " .. (count + 1))
assert(page:find(tostring(server - 90000 + 30 * 600), 1, true), "the newest capture is not on the first page")
-- Its next page follows at once (the 20 s per asker is for a new catch-up); a page out of turn does not.
clock = clock + 1
AR:OnAsk(string.format("1:%s:%d:0:0:2", POOL, campaign), "Asker Two")
assert(#sends == 3 and sends[3].payload:match("^1:[^:]+:%d+:2:2:"), "the second page of a catch-up was refused")
AR:OnAsk(string.format("1:%s:%d:0:0:5", POOL, campaign), "Asker Two")
AR:OnAsk(string.format("1:%s:%d:0:0:2", POOL, campaign), "Asker Nobody")
assert(#sends == 3, "a page out of turn was answered")
-- The next page may come 25 s after the last answer (two relay queues in between).
clock = clock + 25
AR:OnAsk(string.format("1:%s:%d:0:0:3", POOL, campaign), "Asker Two")
assert(#sends == 4, "the next page 25 s after the last answer was refused")
for i = 3, 12 do AR:OnAsk(string.format("1:%s:%d:0:0:1", POOL, campaign), "Asker " .. string.rep("x", i)) end
assert(#sends == 12, "not twelve pages a minute in all: " .. #sends)
-- The whole ledger fits in one catch-up (else two clients could never hold the same rows).
assert(AR.PAGES_MAX * AR.PAGE_ROWS >= AR.ROWS_MAX, "a full ledger does not fit in one catch-up")
-- The asker's side: asks one neighbour; an answer from someone else is ignored; pages follow.
local answer = page
reset()
sends = {}
assert(AR:CatchUp(true) and sends[1].kind == "AQ" and sends[1].target == "Peer One", "no ask sent")
AR:OnAnswer(answer, "Stranger Peer")
assert(OverlordDB.arena[POOL].n == 0, "an answer from someone we did not ask was taken")
local savedUI = Overlord.LeaderboardUI
local refreshes = 0
Overlord.LeaderboardUI = { RefreshArena = function() refreshes = refreshes + 1 end }
AR:OnAnswer(answer, "Peer One")
Overlord.LeaderboardUI = savedUI
assert(OverlordDB.arena[POOL].n == AR.PAGE_ROWS, "the answer's rows were not taken")
assert(refreshes == 1, "a catch-up page repainted the board once per row: " .. refreshes)
assert(#sends == 2 and sends[2].kind == "AQ" and sends[2].payload:match(":2$"), "the second page was not asked")
-- Caught-up rows are judged by content: these capturers are known (above), so believed.
assert(board().count == AR.PAGE_ROWS, "caught-up rows the ranking backs are not on the board")
-- A page that teaches nothing new: while our ledger differs from the answerer's, the next page is
-- asked (a missing older row sits behind pages we know).
local theirN, theirSum = answer:match("^1:[^:]+:%d+:1:%d+:(%d+):(%d+):")
assert(theirN == "30", "the answer does not carry the answerer's digest")
AR.caughtUpAt, AR.tried, AR.ask = nil, nil, nil
assert(AR:CatchUp(true))
local asked = #sends
AR:OnAnswer(answer, "Peer One")
assert(#sends == asked + 1 and sends[#sends].payload:match(":2$") and AR.ask,
    "a known first page ended the round while the ledgers differ")
-- The last page ends the round; a ledger walked to its end that still differs is not walked
-- again (its known first page ends the next round: no whole ledger pulled at every catch-up).
AR:OnAnswer(string.format("1:%s:%d:2:2:%s:%s:", POOL, campaign, theirN, theirSum), "Peer One")
assert(AR.caughtUpAt and AR.tried == nil and AR.ask == nil, "the last page did not end the catch-up round")
AR.caughtUpAt, AR.tried, AR.ask = nil, nil, nil
assert(AR:CatchUp(true))
asked = #sends
AR:OnAnswer(answer, "Peer One")
assert(#sends == asked and AR.caughtUpAt and AR.ask == nil, "a ledger that differs for good was walked again")
-- A newer answerer ledger is walked again.
AR.caughtUpAt, AR.tried, AR.ask = nil, nil, nil
assert(AR:CatchUp(true))
asked = #sends
AR:OnAnswer((answer:gsub("^(1:[^:]+:%d+:1:%d+:)%d+:", "%131:")), "Peer One")
assert(#sends == asked + 1, "a changed answerer ledger was not walked")
-- A page after which both ledgers are equal asks nothing more (pages left or not).
reset(); AR.walked = nil
assert(AR:CatchUp(true))
AR:OnAnswer(answer, "Peer One")
local equalN, equalSum = AR:Digest()
reset(); AR.walked = nil
assert(AR:CatchUp(true))
asked = #sends
AR:OnAnswer((answer:gsub("^(1:[^:]+:%d+:1:%d+:)%d+:%d+:", "%1" .. equalN .. ":" .. equalSum .. ":")), "Peer One")
assert(#sends == asked and AR.caughtUpAt, "a page that made both ledgers equal asked for the next one")
AR.caughtUpAt, AR.tried, AR.ask, AR.walked = nil, nil, nil, nil
-- An ask the relay refuses (sent last, busy queue): the neighbour is not spent, tried again
-- 30 s later, ASK_TRIES times, then the round ends.
do
    local savedAfter, later = C_Timer.After, {}
    C_Timer.After = function(delay, fn) later[#later + 1] = { delay = delay, fn = fn } end
    net.Send = function() return false end
    assert(not AR:CatchUp(true) and AR.tried["Peer One"] == nil and #later == 1 and later[1].delay == 30,
        "a refused ask spent the neighbour or was never tried again")
    later[1].fn(); later[2].fn()
    assert(AR.caughtUpAt and AR.tried == nil and #later == 2, "a refused ask was retried for ever")
    C_Timer.After = savedAfter
    net.Send = function(_, kind, payload, target) sends[#sends + 1] = { kind = kind, payload = payload, target = target }; return true end
    AR.caughtUpAt, AR.tried, AR.ask, AR.askFails = nil, nil, nil, 0
end
assert(AR:CatchUp(true) and sends[#sends].payload:match(":1$"))
AR.ask.page = 2
AR:OnAnswer(string.format("1:%s:%d:2:2:0:0:", POOL, campaign), "Peer One")
assert(AR.caughtUpAt and AR.tried == nil and AR.ask == nil, "the last page did not end the catch-up round")
-- Every neighbour tried, none answered: the round ends too (the next one later), never stuck.
AR.caughtUpAt, AR.tried = nil, { ["Peer One"] = true }
assert(not AR:CatchUp(false) and AR.caughtUpAt and AR.tried == nil, "a failed round stopped the catch-up for good")
net.Send, net.GetDirectPeers = savedSend, savedPeers

-- 5. The pit: 5 minutes uncontested; another guild in the pit (even our faction) pauses it.
reset()
local ticker
C_Timer.NewTicker = function(_, fn) ticker = { fn = fn, Cancel = function(t) t.cancelled = true end }; return ticker end
local mapID, ffa, units, notices, broadcasts = 1434, { player = true }, {}, {}, {}
C_Map = C_Map or {}
C_Map.GetBestMapForUnit = function() return mapID end
UnitIsPVPFreeForAll = function(u) return ffa[u] == true end
UnitIsDeadOrGhost = function() return false end
UnitExists = function(u) return units[u] ~= nil end
UnitIsPlayer = function(u) return units[u] ~= nil end
UnitIsUnit = function(a, b) return a == b end
UnitGUID = function(u) return u end
local guildName = "Pit Guild"
GetGuildInfo = function(u) if u == "player" then return guildName end return units[u] end
IsInGuild = function() return guildName ~= nil end
Overlord.Outpost.GetLocalPlayerGuild = function() return guildName or "" end
UIErrorsFrame = { AddMessage = function(_, text) notices[#notices + 1] = text end }
net.Broadcast = function(_, kind, payload) broadcasts[#broadcasts + 1] = { kind = kind, payload = payload }; return 1 end
local function tick(n) for _ = 1, n do clock = clock + 1; server = server + 1; ticker.fn() end end
mapID = 1429
AR:CheckZone()
assert(not ticker, "the arena clock ran away from Stranglethorn")
mapID = 1434
AR:CheckZone()
assert(ticker, "no clock on the Stranglethorn map")
tick(120)
assert(AR.hold.elapsed >= 119, "the pit hold did not run")
units.nameplate1 = "Rival Guild"            -- an Alliance player of another guild: free-for-all
ffa.nameplate1 = true
local paused = AR.hold.elapsed
tick(30)
assert(AR.hold.elapsed == paused, "another guild in the pit did not pause the capture")
units.nameplate2 = "Pit Guild"              -- a guild mate changes nothing
ffa.nameplate2 = true
ffa.nameplate1 = false                      -- the rival left the pit
tick(1)
assert(AR.hold.elapsed > paused, "the capture stayed paused after the rival left")
tick(200)
assert(#broadcasts == 1 and broadcasts[1].kind == "AC", "the capture was not broadcast")
assert(broadcasts[1].payload:find(":A:", 1, true) and broadcasts[1].payload:find(":Pit Guild", 1, true),
    "wrong capture payload: " .. broadcasts[1].payload)
assert(board().holder.guild == "Pit Guild", "our capture is not on the board")
local function saidTaken() for _, t in ipairs(notices) do if t:find("taken for your guild", 1, true) then return true end end end
assert(saidTaken(), "our capture was not announced to us")
tick(400)
assert(#broadcasts == 1, "a guild that holds the arena took it again")
-- Leaving the pit for more than 3 s starts over.
guildName = "Second Guild"
ffa.nameplate2 = false                      -- the Pit Guild player left: no rival for Second Guild
tick(100)
assert(AR.hold.elapsed >= 99, "the second guild's hold did not run")
ffa.player = false
tick(2)
ffa.player = true
tick(1)
assert(AR.hold.elapsed >= 100, "a 2 s step out of the pit reset the progress")
ffa.player = false
tick(5)
ffa.player = true
tick(1)
assert(AR.hold.elapsed <= 1, "leaving the pit kept the progress")
-- No guild: nothing.
guildName = nil
tick(400)
assert(#broadcasts == 1, "a player without a guild took the arena")
-- Two guilds out of sight of each other both finish: the earlier capture holds, the later
-- one is sent (the fold is the same everywhere) but not announced as won.
guildName = "Late Guild"
know("Hal Gamma", "Rival Guild", "Horde")
assert(AR:AddRow(server - 30, "Horde", "Hal Gamma", "Rival Guild", "content"))
for i = #notices, 1, -1 do notices[i] = nil end
AR:Complete("Late Guild")
assert(board().holder.guild == "Rival Guild" and not saidTaken(), "a capture the fold skipped was announced as won")
-- Our announce refused by the relay: tried once more 30 s later (still first-hand), only then.
do
    local savedAfter, savedBroadcast = C_Timer.After, net.Broadcast
    local later, tries = {}, 0
    C_Timer.After = function(delay, fn) later[#later + 1] = { delay = delay, fn = fn } end
    net.Broadcast = function() tries = tries + 1; return 0 end
    reset()
    AR:Complete("Retry Guild")
    assert(tries == 1 and #later == 1 and later[1].delay == 30 and later[1].delay < AR.FRESH_SEC,
        "a refused announce was not tried again within the first-hand window")
    later[1].fn()
    assert(tries == 2 and #later == 1, "the retry was not sent, or retried again")
    net.Broadcast = function() tries = tries + 1; return 1 end
    reset()
    AR:Complete("Retry Guild")
    assert(tries == 3 and #later == 1, "an announce that went out was sent again")
    C_Timer.After, net.Broadcast = savedAfter, savedBroadcast
    reset()
end
guildName = "Pit Guild"
-- Instance: the clock stops, nothing runs.
AR:OnInstanceSuspend()
assert(ticker.cancelled and AR.ticker == nil, "the arena clock ran in an instance")

-- 6. Chat lines: only for the guilds concerned, each kind at most every 30 minutes.
local lines = {}
Overlord.PrintNotification = function(_, text) lines[#lines + 1] = text end
OverlordDB.arenaChatAt = nil
local before = { guild = "Pit Guild", faction = "Alliance", capturer = "Ann Alpha" }
local lost = { guild = "Other Guild", faction = "Horde", capturer = "Hal Gamma" }
AR:TellGuild(before, lost)
assert(#lines == 1 and lines[1]:find("Other Guild", 1, true), "losing the arena was not told to the guild")
-- Taken back 5 minutes later: told (another kind); lost again: held back.
server = server + 300
AR:TellGuild(lost, before)
assert(#lines == 2 and lines[2]:find("for your guild", 1, true), "taking it back was not told")
server = server + 300
AR:TellGuild(before, lost)
server = server + 300
AR:TellGuild(lost, before)
assert(#lines == 2, "the arena changing hands every 5 minutes printed a line each time: " .. #lines)
-- Past 30 minutes: told again. A date ahead of the clock never holds a line back.
server = server + AR.CHAT_GAP_SEC
AR:TellGuild(before, lost)
assert(#lines == 3, "a loss 30 minutes later was not told")
OverlordDB.arenaChatAt.took = server + 99999
AR:TellGuild(lost, before)
assert(#lines == 4, "a date ahead of the clock held a line back")
guildName = "Bystanders"
AR:TellGuild(before, lost)
assert(#lines == 4, "an arena change was told to a guild not concerned")

-- 7. Wiring.
local function read(path) local f = assert(io.open(path, "rb")); local t = f:read("*a"); f:close(); return t end
assert(read("Overlord.toc"):find("\nArena%.lua\r?\n"), "Arena.lua is not loaded")
local relay = read("SyncRelay.lua")
assert(relay:find("GX GD GM AC AQ AL\"", 1, true) and relay:find("GR CR AQ AL\"", 1, true),
    "the relay does not carry the arena kinds (AQ/AL point to point)")
assert(read("Sync.lua"):find('msgType == "AC" or msgType == "AQ" or msgType == "AL"', 1, true), "no dispatch to the arena")
-- The guild lane never carries the arena (it would take the captures' rank and share there).
assert(not read("SyncGuild.lua"):find("AC =", 1, true), "the guild lane carries the arena")
do
    local lane = Overlord.GuildLane
    if lane and lane.Carries then
        assert(not lane:Carries({ kind = "AC", payload = "1:x:1:H:A B:G", path = { "Arena Tester" }, target = "*" }, 1),
            "the guild lane carries the arena")
    end
end
local core = read("Core.lua")
local _, suspends = core:gsub("pcall%(self%.Arena%.OnInstanceSuspend, self%.Arena%)", "")
assert(suspends == 2 and core:find("pcall(Overlord.Arena.OnInstanceResume, Overlord.Arena)", 1, true),
    "the arena is not cut in instances")
local lbui = read("LeaderboardUI.lua")
assert(lbui:find("function Overlord.LeaderboardUI:PlaceArenaView()", 1, true)
    and lbui:find("    self:CreateArenaView(P)\r\n", 1, true) and not lbui:find("ToggleArena", 1, true),
    "the arena board is not always shown under the keeps and outposts")
local function count(text, pat) local k = 0; for _ in text:gmatch(pat) do k = k + 1 end; return k end
for _, key in ipairs({ "ARENA_TIP_TITLE", "ARENA_TIP_BODY", "ARENA_COL_GUILDS", "ARENA_COL_WHEN", "ARENA_COL_TAKEN",
    "ARENA_EMPTY", "ARENA_HELD_BY", "ARENA_NEED_GUILD", "ARENA_ALREADY_OURS", "ARENA_CONTESTED", "ARENA_HOLD_START",
    "ARENA_HOLD_LEFT", "ARENA_TAKEN", "ARENA_TAKEN_BY_US", "ARENA_TAKEN_FROM_US" }) do
    assert(count(read("Locales.lua"), "\nL%." .. key .. " = ") == 5
        and count(read("Locales_ptBR.lua"), "\nL%." .. key .. " = ") == 1
        and count(read("Locales_zhCN.lua"), "\nL%." .. key .. " = ") == 1, key .. " is not in the 7 languages")
end
local guide = read("GuideLocales.lua")
assert(guide:find("Gurubashi Arena (Stranglethorn Vale)", 1, true) and guide:find("Arène de Gurubashi (Strangleronce)", 1, true),
    "the tutorial does not tell the arena")
-- 8. The holder on the Stranglethorn map: name and holder (or Free) at the pit, repainted only on
-- a new holder or a driver pass, hidden elsewhere and in instances.
do
    local function obj()
        return setmetatable({ shown = true }, { __index = function(_, k)
            if k:sub(1, 1) == "_" then return nil end
            if k == "Show" then return function(s) s.shown = true end end
            if k == "Hide" then return function(s) s.shown = false end end
            if k == "IsShown" then return function(s) return s.shown end end
            if k == "SetText" then return function(s, v) s.text = v end end
            if k == "SetTextColor" then return function(s, r, g, b) s.color = { r, g, b } end end
            if k == "SetPoint" then return function(s, ...) s.point = { ... } end end
            if k == "SetAtlas" then return function(s, a) s.atlas = a end end
            if k == "CreateTexture" or k == "CreateFontString" then return function() return obj() end end
            if k == "GetParent" then return function(s) return s.parent end end
            if k == "GetFrameLevel" then return function() return 10 end end
            if k == "GetFrameStrata" then return function() return "HIGH" end end
            if k == "SetScript" then return function(s, n, f) s.scripts = rawget(s, "scripts") or {}; s.scripts[n] = f end end
            return function() end
        end })
    end
    local AR = Overlord.Arena
    local canvas, parent = obj(), obj()
    canvas.GetWidth = function() return 1000 end
    canvas.GetHeight = function() return 700 end
    canvas.GetEffectiveScale = function() return 1 end
    parent.GetEffectiveScale = function() return 1 end
    local saved = { Overlord.MapMarkers, AR.GetBoard, Overlord.UI, GameTooltip, Overlord.InstanceSuspended }
    local holder = nil
    AR.GetBoard = function() return { holder = holder } end
    Overlord.UI = nil
    Overlord.MapMarkers = {
        NewFrame = function(_, p) local f = obj(); f.parent = p; return f end,
        GetWorldMapCanvas = function() return canvas, parent end,
        -- (Every map projects the pit: only the arena's own map ids may draw it.)
        GetMinePositionOnContinentMap = function(_, site) return site.center[1] / 100, site.center[2] / 100 end,
        GetWorldMapOverlayPoint = function(_, _, _, x, y) return x, y end,
        GetMapIconOpacity = function() return 1 end,
    }
    local pin = Overlord.MemoryParts["Arena.lua"]().mapPin
    AR:RefreshMapPin(1415, true, true)
    assert(pin.frame == nil, "the arena was drawn off the Stranglethorn map")
    AR:RefreshMapPin(1434, false, false)
    local f = assert(pin.frame, "no arena on the Stranglethorn map")
    local L = Overlord.L or {}
    assert(f.shown and f.point[1] == "CENTER" and f.point[2] == parent and f.point[4] == 306 and f.point[5] == 331,
        "the arena is not at the pit")
    assert(f.icon.atlas == AR.MAP_ICON and f.title.text == (L.ARENA_TIP_TITLE or "Gurubashi Arena")
        and f.sub.text == (L.ARENA_UNCLAIMED or "Unclaimed"), "a free arena does not say so on the map")
    holder = { guild = "Iron Watch", faction = "Horde", capturer = "Rok", ts = 1 }
    AR:RefreshMapPin(1434, false, false)
    assert(f.sub.text == "Iron Watch" and f.sub.color[1] == 1.0 and f.sub.color[2] == 0.40,
        "a new holder is not shown on the map at once, in its faction's colour")
    f.sub.text = "unchanged"
    AR:RefreshMapPin(1434, false, false)
    assert(f.sub.text == "unchanged", "the map pin is repainted at every tick")
    AR:RefreshMapPin(1434, true, false)
    assert(f.sub.text == "Iron Watch", "a zoom or a resize does not repaint the map pin")
    local tip = { lines = {} }
    function tip:SetOwner() self.lines = {} end
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:Show() end
    function tip:Hide() end
    GameTooltip = tip
    f.scripts.OnEnter(f)
    assert(tip.lines[2] and tip.lines[2]:find("<Iron Watch>", 1, true) and tip.lines[3]:find("Rok", 1, true),
        "the map tooltip does not name the holder and its capturer")
    AR:RefreshMapPin(1440, true, true)
    assert(not f.shown, "the arena stayed on another map")
    AR:RefreshMapPin(1434, true, true)
    Overlord.InstanceSuspended = true
    AR:RefreshMapPin(1434, true, true)
    assert(not f.shown, "the arena map pin is not cut in instances")
    Overlord.MapMarkers, AR.GetBoard, Overlord.UI, GameTooltip, Overlord.InstanceSuspended =
        saved[1], saved[2], saved[3], saved[4], saved[5]
    assert(read("MapMarkers.lua"):find("Overlord.Arena:RefreshMapPin(mapID, layoutChanged, contentRefresh)", 1, true),
        "the world map driver does not draw the arena")
end
print("Forever arena: free-for-all guild captures, order-free board, trust by content, bounded catch-up, instance cut OK")
