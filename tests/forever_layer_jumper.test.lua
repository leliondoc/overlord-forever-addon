-- Layer Jumper: one requester and one helper exchange the real protocol strings.
-- Covers the bounded reply (thinning, same zone, other layer), the invite only
-- accepted from the asked helper, the verification on a new NPC GUID and the
-- automatic group exit, plus the volunteer-only helper setting (off by default).
local now = 1000
local timers = {}
function GetTime() return now end
function time() return 1790016000 + math.floor(now) end
function strsplit(sep, value)
    local out, start = {}, 1
    while true do
        local i = value:find(sep, start, true)
        if not i then out[#out + 1] = value:sub(start); break end
        out[#out + 1] = value:sub(start, i - 1)
        start = i + 1
    end
    return unpack(out)
end
local function advance(seconds)
    local target = now + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        now = t.at
        t.fn()
    end
    now = target
end
C_Timer = {
    After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end,
    NewTicker = function(interval, fn)
        local ticker = { cancelled = false }
        local function step()
            if ticker.cancelled then return end
            fn()
            timers[#timers + 1] = { at = now + interval, fn = step }
        end
        timers[#timers + 1] = { at = now + interval, fn = step }
        function ticker:Cancel() self.cancelled = true end
        return ticker
    end,
}
local frameMethods = {}
setmetatable(frameMethods, { __index = function() return function() end end })
function CreateFrame() return setmetatable({}, { __index = frameMethods }) end

-- World state, switched between the two simulated clients.
local world = {}
local sent = {}
local function reset(client)
    world = {
        name = client.name, map = client.map or 1429, layerGuid = client.guid,
        grouped = false, leader = false, inGuild = true, combat = false,
    }
end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, msg, chatType, target)
        sent[#sent + 1] = { from = world.name, prefix = prefix, msg = msg, chatType = chatType, target = target }
        return 0
    end,
}
C_Map = {
    GetBestMapForUnit = function() return world.map end,
    GetMapInfo = function(id) return { mapID = id, mapType = 3, name = "Elwynn Forest" } end,
}
function UnitName(unit)
    if unit == "player" then return world.name end
    if unit == "party1" then return world.partyName end
    return nil
end
function UnitFactionGroup() return "Alliance" end
function UnitExists(unit) return unit == "target" and world.layerGuid ~= nil end
function UnitIsPlayer() return false end
function UnitIsVisible() return true end
function UnitGUID(unit) if unit == "target" then return world.layerGuid end end
function IsInInstance() return false end
function InCombatLockdown() return world.combat end
function UnitAffectingCombat() return world.combat end
function IsInGroup() return world.grouped end
function IsInRaid() return false end
function IsInGuild() return world.inGuild end
function GetNumGroupMembers() return world.grouped and (world.groupSize or 2) or 0 end
function UnitIsGroupLeader() return world.leader end
local accepted, invited, left, uninvited = 0, {}, 0, {}
function AcceptGroup() accepted = accepted + 1 end
C_PartyInfo = {
    InviteUnit = function(name) invited[#invited + 1] = name end,
    LeaveParty = function() left = left + 1; world.grouped = false end,
    UninviteUnit = function(name) uninvited[#uninvited + 1] = name end,
}

Overlord = { L = {}, PlayerFaction = "Alliance" }
assert(loadfile("LayerJumper.lua"))()
local LJ = Overlord.LayerJumper
assert(LJ, "module loaded")

-- Helpers answer whatever the draw in the flow tests; the 40 % ceiling has its own case.
LJ.MAX_PCT = 100

local function guid(layer) return "Creature-0-4469-0-" .. layer .. "-299-0000ABCD" end
assert(LJ.ParseLayerFromGUID(guid(1201)) == 1201, "zone UID parsed")
assert(LJ.ParseLayerFromGUID("Player-4469-0ABC") == nil, "players carry no layer")

-- Each client keeps its own module state; swap the per-client fields.
local STATE_FIELDS = { "state", "results", "seenLayers", "mine", "pctByMap", "answered", "guests",
    "inviteLog", "hop", "reqId", "resultsReq", "resultsMap", "resultsAt", "resultCount", "lastSearchAt",
    "pendingTarget", "retryPct", "queryPct", "lastReplyAt", "layerDirtyAt",
    "_myKey", "statusText", "ticker", "_lastObserveAt", "repliedTo", "answerTotal", "lateLeave",
    "hopGroupUntil", "phaseDeadline", "partners", "_zone", "_zoneAt", "_scanFailAt", "_lastObserveTry",
    "_refreshPending", "answerSeen", "querySent", "hopGroupKey", "hopEpochAt", "otherInviteAt", "hopPairSeen", "invitedAt" }
local function fresh()
    return { state = "idle", results = {}, seenLayers = {}, mine = {}, pctByMap = {}, answered = {},
        guests = {}, inviteLog = {}, repliedTo = {}, partners = {}, invitedAt = {} }
end
local clients = {
    req = { name = "Ann Requester", guid = guid(1201), mod = fresh() },
    help = { name = "Bob Helper", guid = guid(1305), mod = fresh() },
}
local active
local function use(id)
    if active then
        for _, k in ipairs(STATE_FIELDS) do active.mod[k] = LJ[k] end
        active.world = world
    end
    active = clients[id]
    for _, k in ipairs(STATE_FIELDS) do LJ[k] = active.mod[k] end
    if active.world then world = active.world else reset(active) end
end
-- Deliver every queued message addressed to the other client.
local function deliver(toId)
    local target = clients[toId]
    local batch = sent
    sent = {}
    use(toId)
    for _, m in ipairs(batch) do
        if m.from ~= target.name and (m.chatType ~= "WHISPER" or m.target == target.name) then
            local channel = m.chatType == "CHANNEL" and "CHANNEL" or m.chatType
            LJ:OnAddonMessage(m.prefix, m.msg, channel, m.from)
        end
    end
end

-- 1) Requester searches: one query on guild + channel-less (no channel joined in test).
use("req")
assert(LJ:Search(nil), "search sent")
assert(#sent == 1 and sent[1].chatType == "GUILD", "query goes to the guild")
local q = sent[1].msg
assert(q:match("^Q:1:%x+:1429:1201:%*:20:A$"), "query fields: " .. q)

-- 2) Helper with thinning at 0 % stays silent.
local zeroPct = q:gsub(":20:A$", ":0:A")
sent = {}
use("help")
LJ:OnAddonMessage(LJ.PREFIX, zeroPct, "GUILD", "Ann Requester")
advance(2)
assert(#sent == 0, "0 % query gets no answer")
LJ.answered = {}
LJ.lastReplyAt = nil

-- 3) Same layer: no answer. Different zone: no answer.
use("help")
world.layerGuid = guid(1201)
LJ.mine = {}
local fullPct = q:gsub(":20:A$", ":100:A")
LJ:OnAddonMessage(LJ.PREFIX, fullPct, "GUILD", "Ann Requester")
advance(2)
assert(#sent == 0, "helper on the same layer stays silent")
world.layerGuid = guid(1305)
world.map = 1433
LJ.mine, LJ.lastReplyAt = {}, nil
LJ:OnAddonMessage(LJ.PREFIX, fullPct, "GUILD", "Ann Requester")
advance(2)
assert(#sent == 0, "helper in another zone stays silent")
world.map = 1429
LJ.mine, LJ.lastReplyAt = {}, nil

-- 4) Eligible helper (auto mode) answers once, even if the query arrives twice.
OverlordDB = { config = { layerHelpMode = "auto" } }
LJ:OnAddonMessage(LJ.PREFIX, fullPct, "GUILD", "Ann Requester")
LJ:OnAddonMessage(LJ.PREFIX, fullPct, "CHANNEL", "Ann Requester")
advance(2)
assert(#sent == 1 and sent[1].chatType == "WHISPER" and sent[1].target == "Ann Requester",
    "one whisper answer")
assert(sent[1].msg:match("^A:%x+:1305$"), "answer fields: " .. sent[1].msg)

LJ.MAX_PCT = 40
-- The real requester query used 40 %: replay the answer against the requester's id.
local reqId = q:match("^Q:1:(%x+):")
sent[1].msg = sent[1].msg:gsub("^A:%x+:", "A:" .. reqId .. ":")
deliver("req")
assert(LJ.resultCount == 1, "requester stored the helper")
-- The shared timer queue already ran the window while the helper's state was loaded.
if LJ.state == "searching" then LJ:FinishSearch() end
assert(LJ.pctByMap[1429].pct == 40, "one answer: next search stays at the 40 % ceiling")
assert(LJ.state == "ready", "search window closed: " .. tostring(LJ.state))

-- 5) Hop to the other layer: request whisper to the helper.
assert(LJ:StartHop("any"), "hop started")
assert(LJ.state == "requesting")
assert(#sent == 1 and sent[1].msg == "R:" .. reqId and sent[1].target == "Bob Helper", "request whisper")

-- An unrelated invite is not auto-accepted.
assert(LJ:OnPartyInvite("Mallory Stranger") == false and accepted == 0, "stranger invite ignored")

-- Helper receives R (it answered this reqId with its own copy: register it).
local reqMsg = sent[1].msg
sent = {}
use("help")
LJ.answered[reqId] = { key = "ann requester", name = "Ann Requester", at = now }
LJ:OnAddonMessage(LJ.PREFIX, reqMsg, "WHISPER", "Ann Requester")
assert(invited[1] == "Ann Requester", "auto helper invites the requester")
assert(LJ:IsHopPartner("Ann Requester"), "helper: the guest gets no group trust")
assert(LJ:IsHopGroup(), "helper: the forming group belongs to the hop (no sync catch-up)")
world.grouped, world.leader = true, true

-- 6) Requester accepts only the asked helper, joins, sees the new layer, leaves.
use("req")
assert(LJ:OnPartyInvite("Bob Helper") == true and accepted == 1, "helper invite accepted")
assert(LJ:IsHopPartner("Bob Helper-Realm"), "requester: the helper gets no group trust")
world.grouped, world.partyName = true, "Bob Helper"
advance(0.5)
LJ:OnEvent("GROUP_JOINED")
assert(LJ.state == "verifying", "verifying after joining")
assert(LJ:IsHopGroup(), "requester: hop group, Sync skips its join catch-up")
advance(1)
assert(LJ.state == "verifying", "old layer seen: still waiting")
world.layerGuid = guid(1305)
advance(1.1)
assert(LJ.state == "idle", "new layer confirmed: " .. tostring(LJ.state))
advance(1.5)
assert(left == 1, "requester left the group after the switch")
assert(LJ.mine.layer == 1305, "requester now on the helper's layer")
assert(LJ:IsHopGroup(), "leaving the hop group is still ours")
advance(9)
assert(not LJ:IsHopGroup(), "grace over: later group changes sync normally")
advance(5)
assert(not LJ:IsHopPartner("Bob Helper"), "partner trust exclusion ends after the hop")
world.partyName = nil

-- 7) Volunteers only: off by default (and the old "ask" setting counts as off),
-- nobody is ever shown a popup; a request reaching a non-volunteer is declined.
use("help")
local savedConfig = OverlordDB.config
OverlordDB.config = {}
assert(LJ:GetHelpMode() == "off", "help is off by default")
OverlordDB.config.layerHelpMode = "ask"
assert(LJ:GetHelpMode() == "off", "old ask setting counts as off")
assert(LJ.ShowAskPrompt == nil and LJ.CreateAskPrompt == nil, "no popup code at all")
world.grouped, world.leader = false, false
LJ.inviteLog = {}
local invitedBefore7 = #invited
LJ.answered["abc123"] = { key = "ann requester", name = "Ann Requester", at = now }
sent = {}
LJ:OnAddonMessage(LJ.PREFIX, "R:abc123", "WHISPER", "Ann Requester")
assert(#invited == invitedBefore7 and sent[1] and sent[1].msg == "N:abc123:off", "non-volunteer declines silently")
OverlordDB.config = savedConfig

-- 8) Never mode: no answer at all.
OverlordDB.config.layerHelpMode = "off"
LJ.answered, LJ.lastReplyAt, sent = {}, nil, {}
local otherQ = "Q:1:beef01:1429:1201:*:100:A"
LJ:OnAddonMessage(LJ.PREFIX, otherQ, "GUILD", "Ann Requester")
advance(2)
assert(#sent == 0, "never mode stays silent")

-- 9) Whispered queries are ignored (only guild/channel searches are accepted).
OverlordDB.config.layerHelpMode = "auto"
LJ:OnAddonMessage(LJ.PREFIX, otherQ, "WHISPER", "Ann Requester")
advance(2)
assert(#sent == 0, "whispered query ignored")

-- 9b) Lingering guest invite: a real group joined later is not a hop group.
use("help")
LJ.guests = { ["zed late"] = { name = "Zed Late", at = now } }
world.grouped = false
assert(LJ:IsHopGroup(), "invite pending: hop group")
advance(16)
assert(not LJ:IsHopGroup(), "pending window over")
world.grouped, world.groupSize, world.partyName = true, 3, "Real Friend"
assert(not LJ:IsHopGroup(), "real group of three: normal sync catch-up")
world.grouped, world.groupSize, world.partyName = false, nil, nil
LJ.guests = {}

-- 9c) A forged 100 % query is capped at 40 % by the helper.
LJ.MAX_PCT = 40
OverlordDB.config.layerHelpMode = "auto"
local forged
for i = 1, 500 do
    local id = string.format("f%05x", i)
    if LJ.Hash100(id .. ":" .. LJ:MyKey()) >= 40 then forged = id; break end
end
LJ.mine, LJ.answered, LJ.lastReplyAt, LJ.repliedTo, sent = {}, {}, nil, {}, {}
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:" .. forged .. ":1429:1201:*:100:A", "GUILD", "Mal Forger")
advance(2)
assert(#sent == 0, "pct above the ceiling does not make every helper answer")
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:" .. forged .. "b:1429:1201:*", "GUILD", "Mal Forger")
advance(2)
assert(#sent == 0, "missing pct means nobody answers")
LJ.MAX_PCT = 100

-- 10) A helper that does not know its layer never answers.
use("help")
OverlordDB.config.layerHelpMode = "auto"
world.layerGuid = nil
LJ.mine, LJ.answered, LJ.lastReplyAt, LJ.repliedTo, sent = {}, {}, nil, {}, {}
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:cafe01:1429:1201:*:100:A", "GUILD", "Cid Other")
advance(2)
assert(#sent == 0, "unknown-layer helper stays silent")
world.layerGuid = guid(1305)

-- 11) One answer per requester per 20 s, one answer per helper per 8 s.
LJ.mine = {}
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:cafe02:1429:1201:*:100:A", "GUILD", "Cid Other")
advance(9)
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:cafe03:1429:1201:*:100:A", "GUILD", "Cid Other")
advance(2)
assert(#sent == 1, "same requester answered once within 20 s")
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:cafe04:1429:1201:*:100:A", "GUILD", "Dee Other")
advance(2)
assert(#sent == 2, "another requester is answered")
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:cafe05:1429:1201:*:100:A", "GUILD", "Eve Other")
advance(2)
assert(#sent == 2, "helper reply gap holds")

-- 12) A crowd of answers lowers the next search share (6 answers targeted).
use("req")
LJ.lastSearchAt, LJ.state, LJ.hop = nil, "idle", nil
world.grouped = false
assert(LJ:Search(nil), "second search sent")
local reqId2 = LJ.reqId
for i = 1, 30 do
    LJ:OnAddonMessage(LJ.PREFIX, "A:" .. reqId2 .. ":1305", "WHISPER", "Helper " .. i)
end
assert(LJ.resultCount == 16 and LJ.answerTotal == 30, "storage capped, every answer counted")
LJ.MAX_PCT = 40
LJ:FinishSearch()
assert(LJ.pctByMap[1429].pct == 8, "40 % x 6 / 30 = 8 %: " .. tostring(LJ.pctByMap[1429].pct))

-- 12b) "Other layer" needs a known own layer; nothing is sent otherwise.
LJ.state, LJ.hop, LJ.lastSearchAt, sent = "idle", nil, nil, {}
world.layerGuid = nil
LJ.mine, LJ.layerDirtyAt = {}, now
assert(LJ:Search("any") == false and #sent == 0, "any-layer jump refused without own layer")
world.layerGuid = guid(1201)

-- 13) Watchdog: a phase past its deadline cancels instead of staying stuck.
LJ.hop = { candidates = {}, index = 1, reqId = "dead01", current = { name = "Helper 1", key = "helper 1" } }
LJ:SetState("requesting", "LJ_STATUS_REQUESTING", "Helper 1")
now = now + 31
LJ:Tick()
assert(LJ.state == "idle" and not LJ:IsActive(), "stuck phase cancelled")

-- 14) A late invite from an abandoned helper: we leave that group, not any group.
local leftBefore = left
world.grouped, world.partyName = true, "Someone Else"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(left == leftBefore, "unrelated group kept")
world.partyName = "Helper 1"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(left == leftBefore + 1, "abandoned helper's group left")

-- 15) Sync skips its group catch-up for hop groups (source guard).
local syncSrc = assert(io.open("Sync.lua")):read("*a")
assert(syncSrc:find("if jumper and jumper.IsHopGroup and jumper:IsHopGroup%(%) then return end"), "Sync catch-up timers consult LayerJumper")

-- 16) A third player brought into the hop group: the requester leaves at once.
use("req")
world.grouped, world.groupSize, world.partyName = false, nil, nil
local function fakeHop(state)
    LJ:MarkHopEpoch()
    LJ.hop = { candidates = {}, index = 1, reqId = "beef02", originMap = 1429, originLayer = 1201,
        current = { name = "Bob Helper", key = "bob helper", layer = 1305 }, acceptedAt = now }
    LJ:SetState(state, "LJ_STATUS_JOINING", "Bob Helper")
end
fakeHop("joining")
local leftBefore16 = left
world.grouped, world.groupSize, world.partyName = true, 3, "Bob Helper"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
advance(1.5)
assert(LJ.state == "idle" and left == leftBefore16 + 1, "crowded hop group left")

-- 17) A different group accepted by hand while joining is kept; the jump is dropped.
world.grouped, world.groupSize, world.partyName = false, nil, nil
fakeHop("joining")
local leftBefore17 = left
LJ:OnEvent("PARTY_INVITE_REQUEST", "Real Friend")
world.grouped, world.groupSize, world.partyName = true, 2, "Real Friend"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
advance(2)
assert(LJ.state == "idle" and left == leftBefore17 and world.grouped, "foreign group kept")
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 18) A search that could not leave the client: no cooldown burnt, clear status.
Overlord.Sync = {
    GetChannelId = function() return 5 end,
    TakeChannelToken = function() return false end,
    IsLargeEvent = function() return false end,
}
world.inGuild = false
LJ.state, LJ.hop, LJ.lastSearchAt, LJ.resultsReq, sent = "idle", nil, nil, nil, {}
LJ.mine = {}
assert(LJ:Search(nil), "search started")
advance(5)
assert(#sent == 0, "no channel token: nothing sent, never in debt")
assert(LJ.state == "ready" and LJ.lastSearchAt == nil, "unsent search reported, no cooldown")

-- 19) In a crowd, zero answers never trigger the retry.
world.inGuild = true
Overlord.Sync.IsLargeEvent = function() return true end
LJ.state, LJ.lastSearchAt, sent = "idle", nil, {}
assert(LJ:Search(nil), "crowd search started")
advance(5)
local queries = 0
for _, m in ipairs(sent) do if m.msg:sub(1, 1) == "Q" then queries = queries + 1 end end
assert(queries == 1, "no retry in a crowd: " .. queries)
Overlord.Sync = nil

-- 20) Helper: a guest who stays longer than 15 s still makes the leave a hop leave.
use("help")
LJ.guests = { ["ann requester"] = { name = "Ann Requester", at = now } }
LJ.hopGroupUntil = nil
world.grouped, world.groupSize, world.partyName = true, 2, "Ann Requester"
assert(LJ:IsHopGroup(), "guest in the pair")
advance(30)
world.grouped, world.partyName = false, nil
assert(LJ:IsHopGroup(), "guest left after a long hop: still the hop group")
LJ:OnEvent("GROUP_LEFT")
assert(next(LJ.guests) == nil and LJ:IsHopGroup(), "GROUP_LEFT: guests cleared, grace running")
advance(9)
assert(not LJ:IsHopGroup(), "grace over")
world.groupSize = nil

-- 21) Older clients return 1/nil instead of true/false.
local realIsInGroup = IsInGroup
IsInGroup = function() return world.grouped and 1 or nil end
world.grouped = true
assert(LJ:IsGrouped(), "1 counts as grouped")
world.grouped = false
assert(not LJ:IsGrouped(), "nil counts as solo")
IsInGroup = realIsInGroup

-- 22) Helper: the guest pulled a third player in -> no trust, and the helper leaves.
use("help")
LJ.guests = { ["ann requester"] = { name = "Ann Requester", at = now } }
LJ.partners, LJ.hopGroupUntil, LJ.hopGroupKey = {}, nil, nil
world.grouped, world.groupSize, world.partyName = true, 2, "Ann Requester"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(LJ.guests["ann requester"].joined, "guest seen in the pair")
assert(LJ:IsHopPartner("Alt Intruder"), "nobody in the helper's hop group is trusted")
local leftBefore22 = left
world.groupSize = 3
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(left == leftBefore22 + 1 and next(LJ.guests) == nil, "helper left the crowded hop group")
world.grouped, world.groupSize, world.partyName = false, nil, nil
advance(10)

-- 23) Partner name not resolved yet: still the hop pair (no sync catch-up).
use("req")
world.grouped, world.groupSize, world.partyName = false, nil, nil
fakeHop("joining")
world.grouped, world.groupSize, world.partyName = true, 2, nil
assert(LJ:HopPairStatus("bob helper") == "pending", "unresolved partner is pending")
assert(LJ:IsHopGroup(), "pending pair is the hop group")
LJ:Cancel()
advance(2)
world.grouped, world.groupSize = false, nil
advance(10)

-- 24) A real group joined while requesting cancels the jump; the group is kept.
fakeHop("requesting")
local leftBefore24 = left
world.grouped, world.groupSize, world.partyName = true, 4, "Guild Mate"
LJ:OnEvent("GROUP_JOINED")
assert(LJ.state == "idle" and left == leftBefore24 and world.grouped, "jump dropped, real group kept")
assert(not LJ:IsHopGroup(), "a real group of four is not a hop group")
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 25) Locales: every Layer Jumper key in all 7 locales, same format specifiers.
local function localeBlocks(path)
    local src = assert(io.open(path)):read("*a")
    local blocks, current = {}, nil
    for line in src:gmatch("[^\n]+") do
        local key, value = line:match('^L%.([A-Z_]+) = "(.*)"$')
        if key == "LAYER_JUMPER_BUTTON" then
            current = {}
            blocks[#blocks + 1] = current
        elseif not key then
            current = nil
        end
        if current and key and (key:find("^LJ_") or key:find("^LAYER_JUMPER_") or key == "HELP_LAYER") then
            current[key] = value
        end
    end
    return blocks
end
local all = {}
for _, b in ipairs(localeBlocks("Locales.lua")) do all[#all + 1] = b end
for _, b in ipairs(localeBlocks("Locales_ptBR.lua")) do all[#all + 1] = b end
for _, b in ipairs(localeBlocks("Locales_zhCN.lua")) do all[#all + 1] = b end
assert(#all == 7, "7 locale blocks: " .. #all)
local function specs(v) local t = {}; for x in v:gmatch("%%(%a)") do t[#t + 1] = x end; return table.concat(t) end
local en = all[1]
for i = 2, 7 do
    for key, value in pairs(en) do
        assert(all[i][key], "locale " .. i .. " misses " .. key)
        assert(specs(all[i][key]) == specs(value), "locale " .. i .. " format differs for " .. key)
    end
    for key in pairs(all[i]) do assert(en[key], "locale " .. i .. " has extra " .. key) end
end
local code = assert(io.open("LayerJumper.lua")):read("*a")
for key in code:gmatch('T%("([A-Z_]+)"') do assert(en[key], "code uses missing key " .. key) end

-- 26) Helper: a guest still in the pair after 120 s is released.
use("help")
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
OverlordDB.config.layerHelpMode = "auto"
LJ.guests, LJ.inviteLog, LJ.hop, LJ.state = {}, {}, nil, "idle"
LJ:InviteGuest("Kim Guest", "kim001")
world.grouped, world.groupSize, world.partyName, world.leader = true, 2, "Kim Guest", true
LJ:OnEvent("GROUP_ROSTER_UPDATE")
advance(121)
assert(uninvited[#uninvited] == "Kim Guest", "stale guest released after 120 s")
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
advance(10)

-- 27) The requester never leaves a group that is not the hop pair.
use("req")
LJ.hopEpochAt = now
LJ:OnEvent("PARTY_INVITE_REQUEST", "Stranger Friend")
world.grouped, world.groupSize, world.partyName = true, 2, "Stranger Friend"
local leftBefore27 = left
LJ:LeaveHopGroup("bob helper")
assert(left == leftBefore27, "foreign group kept")
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 28) Verifying, a third player joins: leave with a clear status.
local function fakeVerify()
    fakeHop("joining")
    world.grouped, world.groupSize, world.partyName = true, 2, "Bob Helper"
    LJ:OnEvent("GROUP_JOINED")
    assert(LJ.state == "verifying", "verifying")
end
fakeVerify()
local leftBefore28 = left
world.groupSize = 3
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(LJ.state == "idle" and LJ.statusText == "LJ_STATUS_CROWDED", "crowded status")
advance(1.5)
assert(left == leftBefore28 + 1, "left after the crowd")
world.grouped, world.groupSize, world.partyName = false, nil, nil
advance(10)

-- 29) Verifying, removed from the group: the jump ends.
fakeVerify()
world.grouped, world.groupSize, world.partyName = false, nil, nil
LJ:OnEvent("GROUP_LEFT")
assert(LJ.state == "idle", "GROUP_LEFT during verifying ends the jump")
advance(10)

-- 30) A loading screen during verifying does not abort; leaving the zone does.
fakeVerify()
LJ:OnEvent("PLAYER_ENTERING_WORLD")
assert(LJ.state == "verifying", "PEW keeps verifying")
world.map = 1433
LJ:OnEvent("ZONE_CHANGED_NEW_AREA")
assert(LJ.state == "idle", "another zone ends the jump")
world.map = 1429
advance(2)
world.grouped, world.groupSize, world.partyName = false, nil, nil
advance(10)

-- 31) Inside an instance nothing is sent and addon messages are ignored.
Overlord.InstanceSuspended = true
sent = {}
assert(LJ:Send("Q:x", "GUILD") == false and #sent == 0, "no send in instance")
local answersBefore = LJ.answerTotal
LJ:OnEvent("CHAT_MSG_ADDON", LJ.PREFIX, "A:" .. tostring(LJ.resultsReq) .. ":1305", "WHISPER", "Iz Instance")
assert(LJ.answerTotal == answersBefore, "messages ignored in instance")
Overlord.InstanceSuspended = nil

-- 32) Zero answers in a calm zone: one retry at x4 (capped at 40 %).
LJ.state, LJ.hop, LJ.lastSearchAt, LJ.pctByMap, sent = "idle", nil, nil, {}, {}
LJ.mine = {}
assert(LJ:Search(nil), "search for the retry case")
advance(9)
local pcts = {}
for _, m in ipairs(sent) do
    local pct = m.msg:match("^Q:1:%x+:%d+:[^:]*:[^:]*:(%d+):")
    if pct and m.chatType == "GUILD" then pcts[#pcts + 1] = tonumber(pct) end
end
assert(#pcts == 2 and pcts[2] == math.min(40, pcts[1] * 4), "single retry at x4: " .. table.concat(pcts, ","))
advance(30)

-- 33) A volunteer who never invites: no extra whisper, the next one is asked.
LJ.state, LJ.hop, sent = "ready", nil, {}
LJ.resultsReq, LJ.resultsMap, LJ.resultsAt = "r33", 1429, now
LJ.results = {
    ["h one"] = { name = "H One", key = "h one", layer = 1305, roll = 0.1 },
    ["h two"] = { name = "H Two", key = "h two", layer = 1305, roll = 0.2 },
}
assert(LJ:StartHop(1305), "hop started on 1305")
assert(sent[#sent].msg == "R:r33" and sent[#sent].target == "H One", "first helper asked")
advance(12.5)
local sawX, sawR2 = false, false
for _, m in ipairs(sent) do
    if m.msg:sub(1, 1) == "X" then sawX = true end
    if m.msg == "R:r33" and m.target == "H Two" then sawR2 = true end
end
assert(not sawX and sawR2 and LJ.state == "requesting", "timeout: no extra whisper, R to the next")
LJ:Cancel()

-- 34) Partner swap: the helper brings an alt in then leaves; no invite was received.
use("req")
world.grouped, world.groupSize, world.partyName = false, nil, nil
LJ.otherInviteAt = nil
fakeHop("joining")
LJ.hopEpochAt = now
world.grouped, world.groupSize, world.partyName = true, 2, "Bob Helper"
LJ:OnEvent("GROUP_JOINED")
assert(LJ.state == "verifying", "verifying with the helper")
local leftBefore34 = left
world.partyName = "Alt Swapped"
assert(LJ:HopPairStatus("bob helper") == "hijacked", "swap detected")
assert(LJ:IsHopPartner("Alt Swapped"), "swapped alt never trusted")
LJ:OnEvent("GROUP_ROSTER_UPDATE")
advance(1.5)
assert(LJ.state == "idle" and left == leftBefore34 + 1, "hijacked hop group left")
world.grouped, world.groupSize, world.partyName = false, nil, nil
advance(10)

-- 35) A /reload in the middle of a hop: partner untrusted, its group left on return.
OverlordDB.layerJumperHop = { key = "bob helper", at = time() - 20 }
LJ.partners, LJ.initialized = {}, nil
world.grouped, world.groupSize, world.partyName = true, 2, "Bob Helper"
local leftBefore35 = left
LJ:RestoreHopAfterReload()
assert(OverlordDB.layerJumperHop == nil, "record consumed")
assert(LJ:IsHopPartner("Bob Helper"), "partner still untrusted after reload")
advance(6)
assert(left == leftBefore35 + 1, "hop group left after reload")
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 36) A stale hop record after a reload never makes us leave a friends' group.
advance(10) -- the previous case's 8 s leave grace is over
OverlordDB.layerJumperHop = { key = "bob helper", at = time() - 30 }
world.grouped, world.groupSize, world.partyName = true, 2, "Best Friend"
local leftBefore36 = left
LJ:RestoreHopAfterReload()
advance(6)
assert(left == leftBefore36, "friends' group kept after reload")
assert(not LJ:IsHopPartner("Best Friend"), "friend trusted")
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 37) Helper: an unresolved name in a friends' duo never marks the stale guest as joined.
use("help")
LJ.guests = { ["gus ghost"] = { name = "Gus Ghost", at = now - 30 } }
LJ.hopGroupUntil, LJ.hopGroupKey, LJ.partners = nil, nil, {}
world.grouped, world.groupSize, world.partyName = true, 2, nil
LJ:IsHopGroup()
assert(not LJ.guests["gus ghost"].joined, "pending name does not mean the guest joined")
local leftBefore37 = left
world.partyName = "Pal Friend"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(left == leftBefore37, "helper keeps the friends' duo")
LJ.guests = {}
world.grouped, world.groupSize, world.partyName = false, nil, nil

-- 38) Helper: invite from an alt after the epoch, then a swap -> still hijacked, left.
use("help")
OverlordDB.config.layerHelpMode = "auto"
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
LJ.guests, LJ.inviteLog, LJ.hop, LJ.state, LJ.partners = {}, {}, nil, "idle", {}
LJ:InviteGuest("Rex Stranger", "rex001")
LJ:OnEvent("PARTY_INVITE_REQUEST", "Alt Two")
world.grouped, world.groupSize, world.partyName, world.leader = true, 2, "Rex Stranger", true
LJ:OnEvent("GROUP_ROSTER_UPDATE")
local leftBefore38 = left
world.partyName = "Alt Three"
assert(LJ:HopPairStatus("rex stranger") == "hijacked", "swap after the pair was seen is hijacked")
assert(LJ:IsHopPartner("Alt Three"), "swapped alt untrusted")
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(left == leftBefore38 + 1, "helper left the swapped group")
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
LJ:OnEvent("GROUP_LEFT")
advance(10)

-- 39) Helper: an unanswered invite expires; the same player invited by hand later
-- is a real group: synced normally and never kicked.
LJ.guests, LJ.inviteLog = {}, {}
LJ:InviteGuest("Gil Guildmate", "gil001")
advance(80)
world.grouped, world.groupSize, world.partyName, world.leader = true, 2, "Gil Guildmate", true
LJ:OnEvent("GROUP_ROSTER_UPDATE")
assert(not LJ:IsHopGroup(), "expired invite: real group")
assert(not LJ.guests["gil guildmate"].joined, "not marked as our guest")
local kicksBefore = #uninvited
advance(45)
assert(#uninvited == kicksBefore, "guildmate not kicked")
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
LJ.guests = {}

-- 40) ParseLayerFromGUID edge cases.
assert(LJ.ParseLayerFromGUID("Pet-0-4469-0-1201-299-00AB") == nil, "pets carry no layer")
assert(LJ.ParseLayerFromGUID("GameObject-0-4469-0-1305-1731-00AB") == 1305, "game objects carry the layer")
assert(LJ.ParseLayerFromGUID("Vehicle-0-4469-0-77-28781-00AB") == 77, "vehicles carry the layer")
assert(LJ.ParseLayerFromGUID("Creature-1-4469-0-1201-299-00AB") == nil, "non-zero second field rejected")
assert(LJ.ParseLayerFromGUID("Creature-0-4469-0-0-299-00AB") == nil, "zone UID 0 rejected")
assert(LJ.ParseLayerFromGUID("Creature-0-4469-0") == nil, "truncated GUID rejected")
assert(LJ.ParseLayerFromGUID(nil) == nil and LJ.ParseLayerFromGUID(42) == nil, "non-strings rejected")

-- 41) Same player: realms must match when both names carry one.
assert(LJ.SameName("Bob Helper-RealmA", "Bob Helper"), "realm on one side only")
assert(not LJ.SameName("Bob Helper-RealmA", "Bob Helper-RealmB"), "different realms")

-- 42) A volunteer invites the same requester at most once per 10 minutes.
use("help")
OverlordDB.config.layerHelpMode = "auto"
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
LJ.guests, LJ.inviteLog, LJ.hop, LJ.state, LJ.invitedAt = {}, {}, nil, "idle", {}
LJ.answered, LJ.lastReplyAt, LJ.repliedTo, sent = {}, nil, {}, {}
LJ:InviteGuest("Spam Requester", "sp0001")
advance(30)
LJ.mine, LJ.guests = {}, {}
LJ:OnAddonMessage(LJ.PREFIX, "Q:1:sp0002:1429:1201:*:40:A", "GUILD", "Spam Requester")
advance(2)
assert(#sent == 0, "no answer to a requester invited less than 10 min ago")

-- 43) The helper moved to another layer between its answer and the request: decline.
LJ.invitedAt = {}
LJ.answered["mv0001"] = { key = "mo requester", name = "Mo Requester", at = now, layer = 9999 }
local invitedBefore43 = #invited
sent = {}
LJ:OnAddonMessage(LJ.PREFIX, "R:mv0001", "WHISPER", "Mo Requester")
assert(#invited == invitedBefore43 and sent[1] and sent[1].msg == "N:mv0001:moved", "moved helper declines")

-- 44) The requester cannot jump while queued for a battleground.
use("req")
GetMaxBattlefieldID = function() return 1 end
GetBattlefieldStatus = function() return "queued" end
LJ.state, LJ.hop, LJ.lastSearchAt, sent = "idle", nil, nil, {}
assert(LJ:Search("any") == false and #sent == 0, "no jump while queued")
GetMaxBattlefieldID, GetBattlefieldStatus = nil, nil

-- 45) An invite that was never accepted does not lock the requester out for 10 min,
-- and a volunteer with an invite in flight declines a second request.
use("help")
OverlordDB.config.layerHelpMode = "auto"
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
LJ.guests, LJ.inviteLog, LJ.hop, LJ.state, LJ.invitedAt = {}, {}, nil, "idle", {}
LJ:InviteGuest("Ned Lost", "ned001")
LJ.answered["sec001"] = { key = "sue second", name = "Sue Second", at = now, layer = nil }
sent = {}
advance(16)
LJ:OnAddonMessage(LJ.PREFIX, "R:sec001", "WHISPER", "Sue Second")
assert(sent[1] and sent[1].msg == "N:sec001:busy", "one invite in flight at a time")
advance(110)
assert(LJ.invitedAt["ned lost"] == nil, "unaccepted invite: requester may ask again")

-- 46) Entering an instance mid-hop (queue pop, summon): the jump is dropped WITHOUT
-- touching the group, no group event is handled and no pending timer leaves or kicks.
use("req")
world.grouped, world.groupSize, world.partyName = false, nil, nil
fakeHop("verifying")
world.grouped, world.groupSize, world.partyName = true, 2, "Bob Helper"
local leftBefore46, uninvitedBefore46 = left, #uninvited
Overlord.InstanceSuspended = true
LJ:OnInstanceSuspend()
assert(LJ.state == "idle" and LJ.hop == nil and LJ.ticker == nil, "instance drops the jump and its ticker")
world.groupSize = 5
LJ:OnEvent("GROUP_ROSTER_UPDATE")
LJ:OnEvent("GROUP_LEFT")
LJ:OnEvent("PARTY_INVITE_REQUEST", "Bob Helper")
LJ:LeaveHopGroup("bob helper")
advance(130)
assert(left == leftBefore46 and world.grouped, "an instance group is never left")
-- Helper side: a guest's release timer never kicks inside an instance.
use("help")
Overlord.InstanceSuspended = nil
OverlordDB.config.layerHelpMode = "auto"
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, true
LJ.guests, LJ.inviteLog, LJ.hop, LJ.state, LJ.invitedAt = {}, {}, nil, "idle", {}
LJ:InviteGuest("Ivy Instance", "ivy001")
world.grouped, world.groupSize, world.partyName = true, 2, "Ivy Instance"
LJ:OnEvent("GROUP_ROSTER_UPDATE")
Overlord.InstanceSuspended = true
LJ:OnInstanceSuspend()
advance(130)
assert(#uninvited == uninvitedBefore46 and left == leftBefore46, "no kick or leave in an instance")
Overlord.InstanceSuspended = nil
world.grouped, world.groupSize, world.partyName, world.leader = false, nil, nil, false
-- Core suspends the Layer Jumper with the rest of Overlord.
local coreSrc = assert(io.open("Core.lua")):read("*a")
assert(coreSrc:find("self.LayerJumper.OnInstanceSuspend", 1, true), "Core suspends the Layer Jumper in instances")

print("forever_layer_jumper: ok")
