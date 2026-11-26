-- A player who captures keeps and outposts without killing has no kill row, the only ranking row
-- that carried his guild. His claims stayed refused ("catch-up-guild", "owner-guild-unknown")
-- wherever the ranking did not know it: late arrivals kept the old allied tenant on a keep the
-- enemy held, then saw another allied guild "take" it. His page capture row now carries his
-- guild ("=<guildAt>=<guild>", last item of the zone list), under the kill row's rules.
math.randomseed(17)
assert(loadfile("tests/forever_world_kills.test.lua"))()
function GetChannelName() return 5 end
function securecall(fn, ...) return fn(...) end
function strsplit(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1); start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return (unpack or table.unpack)(fields)
end
C_Club = { GetSubscribedClubs = function() return {} end }
Enum = Enum or {}; Enum.ClubType = Enum.ClubType or { Character = 1 }
local s, lb = Overlord.Sync, Overlord.Leaderboard
assert(loadfile("SyncRelay.lua"))()
assert(loadfile("SyncHistoryCatchup.lua"))()
assert(loadfile("SyncLeaderboardPages.lua"))()
Overlord.PlayerFaction = "Alliance"
Overlord.InstanceSuspended = false
function s:GetChannelId() return 5 end
function s:SendAddonChecked() return true end
function s:SendToBNet() return true end
function s:GetBetaBNetTargets() return {} end

local EPOCH = OverlordDB.lastResetTimestamp
local AT = EPOCH + 3600
local function snapshotOf(name, info, kills)
    return { captureCount = { [name] = 2 }, captures = { [name] = {} },
        playerInfo = { [name] = info }, kills = kills or {} }
end
local function strong(guild, at)
    return { class = "WARRIOR", faction = "Horde", level = 30, locale = "enus",
        guild = guild, guildAt = at, guildAuth = true }
end

-- 1. Served: a capture-only player's strong guild, last in the list.
local row = assert(s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", strong("Guild Black", AT)),
    "Kurt Three", EPOCH), "a capture row was not built")
assert(row:find(":=" .. AT .. "=Guild Black:", 1, true), "the guild did not ride the capture row: " .. row)
-- Not with a kill row (it carries the guild), nor a second-hand hint, nor a guild a peer cannot read.
assert(not s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", strong("Guild Black", AT),
    { ["Kurt Three"] = 4 }), "Kurt Three", EPOCH):find("=Guild Black", 1, true), "a ranked player's capture row carried a guild")
local hint = strong("Guild Black", 0); hint.guildAuth = nil
assert(not s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", hint), "Kurt Three", EPOCH)
    :find("=", 1, true), "a second-hand guild hint was served")
local replica = strong("Guild Black", AT); replica.guildAuth = nil; replica.guildReplica = true
assert(s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", replica), "Kurt Three", EPOCH)
    :find("=Guild Black", 1, true), "a guild learnt from a page was not passed on")

-- 2. Taken from a page we asked for, as a page register; never as a zone.
local function paged(name, fn)
    s._pagedDelivery = { kind = "LC", sender = "Page Peer", channel = "WHISPER",
        key = s:GetCaptureContributorDedupKey(name):lower() }
    local ok, err = pcall(fn)
    s._pagedDelivery = nil
    assert(ok, err)
end
paged("Kurt Three", function()
    assert(s:OnReceiveLeaderboardCaptures(row, "Page Peer", "WHISPER") ~= false, "the capture row was refused")
end)
assert(lb.captureCount["Kurt Three"] == 2, "the capture count was not taken")
local guild, guildAt = lb:GetHotPlayerGuildState("Kurt Three")
assert(guild == "Guild Black" and guildAt == AT, "the guild of a capture-only player was not learnt: " .. tostring(guild))
assert(lb.playerInfo["Kurt Three"].guildReplica == true, "the guild was not held as a page register")
for _, z in ipairs(lb.captures["Kurt Three"] or {}) do assert(z:sub(1, 1) ~= "=", "the guild item was stored as a zone") end
-- Passed on in turn (a third client learns it from this one).
local again = assert(s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", lb.playerInfo["Kurt Three"]),
    "Kurt Three", EPOCH))
assert(again:find("=" .. AT .. "=Guild Black", 1, true), "a learnt guild was not served again")

-- 3. An older page never replaces a newer register; a newer one does.
local older = row:gsub("=" .. AT .. "=Guild Black", "=" .. (AT - 600) .. "=Guild Gone")
paged("Kurt Three", function() s:OnReceiveLeaderboardCaptures(older, "Page Peer", "WHISPER") end)
assert(lb:GetHotPlayerGuildState("Kurt Three") == "Guild Black", "an older page replaced the guild")
local newer = row:gsub("=" .. AT .. "=Guild Black", "=" .. (AT + 600) .. "=Guild Moved")
paged("Kurt Three", function() s:OnReceiveLeaderboardCaptures(newer, "Page Peer", "WHISPER") end)
assert(lb:GetHotPlayerGuildState("Kurt Three") == "Guild Moved", "a newer page did not move the guild")

-- 4. Only from a page or feed row we asked for: an SR:F reply or an unsolicited row teach nothing.
local other = row:gsub("Kurt Three", "Lena Four")
local full, subject = s.HasExpectedFullLeaderboardResponse, s.AuthorizeLeaderboardSubject
s.HasExpectedFullLeaderboardResponse = function() return true end
s.AuthorizeLeaderboardSubject = function() return true end
s:OnReceiveLeaderboardCaptures(other, "Reply Peer", "WHISPER")
s.HasExpectedFullLeaderboardResponse, s.AuthorizeLeaderboardSubject = full, subject
assert(lb.captureCount["Lena Four"] == 2, "the SR:F row itself was refused")
assert(lb:GetHotPlayerGuildState("Lena Four") == "", "an SR:F reply set a capture row's guild")
local stray = row:gsub("Kurt Three", "Mira Five")
s:OnReceiveLeaderboardCaptures(stray, "Troll Player", "WHISPER")
assert(lb.captureCount["Mira Five"] == nil and lb:GetHotPlayerGuildState("Mira Five") == "",
    "an unsolicited capture row was taken")

-- 5. A page never overrides the player's own word (a strong register of his).
lb.playerInfo["Nora Six"] = strong("Own Guild", AT + 50)
local forged = row:gsub("Kurt Three", "Nora Six"):gsub("=" .. AT .. "=Guild Black", "=" .. AT .. "=Fake Guild")
paged("Nora Six", function() s:OnReceiveLeaderboardCaptures(forged, "Page Peer", "WHISPER") end)
assert(lb:GetHotPlayerGuildState("Nora Six") == "Own Guild", "a page replaced the player's own guild")

-- 6. An unreadable guild is dropped (and never taken for a zone).
local bad = row:gsub("Kurt Three", "Olga Seven"):gsub("=" .. AT .. "=Guild Black", "=" .. AT .. "=" .. string.rep("x", 30))
paged("Olga Seven", function() s:OnReceiveLeaderboardCaptures(bad, "Page Peer", "WHISPER") end)
assert(lb:GetHotPlayerGuildState("Olga Seven") == "", "an unreadable guild was taken")

-- 7. Digests: the guild counts (a peer without it pulls the row), its date does not (each client
-- dates a membership itself, as in a kill row), and the in-place hash agrees with the digest.
local digest, digestHash = s._PagedRowDigest, s._PagedDigestHash
local redated = row:gsub("=" .. AT .. "=", "=" .. (AT + 37) .. "=")
local bare = row:gsub(":=" .. AT .. "=Guild Black:", "::")
assert(digest("LC", row) == digest("LC", redated), "the guild's date entered the capture digest")
assert(digestHash("LC", row) == digestHash("LC", redated), "the guild's date entered the capture hash")
assert(digestHash("LC", row) ~= digestHash("LC", bare), "a capture row without the guild hashed as one with it")
assert(digestHash("LC", row) == s._PagedDigestHash("LC", digest("LC", row)), "hash and digest disagree")
assert(digestHash("LC", bare) == digestHash("LC", digest("LC", bare)), "a plain capture row's hash changed")

-- 8. A dated departure travels too ("=<guildAt>=", as a kill row's): a peer holding the old
-- guild learns it left. Undated, nothing; for a player nobody knows, no row is made.
local left = strong("", AT + 900)
local leftRow = assert(s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", left), "Kurt Three", EPOCH))
assert(leftRow:find(":=" .. (AT + 900) .. "=:", 1, true), "a strong departure did not ride the capture row: " .. leftRow)
assert(not s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", strong("", 0)), "Kurt Three", EPOCH)
    :find("=", 1, true), "an undated empty guild was served")
paged("Kurt Three", function() s:OnReceiveLeaderboardCaptures(leftRow, "Page Peer", "WHISPER") end)
assert(lb:GetHotPlayerGuildState("Kurt Three") == "", "a departure on a page did not clear the old guild")
for _, z in ipairs(lb.captures["Kurt Three"] or {}) do assert(z:sub(1, 1) ~= "=", "the departure was stored as a zone") end
local ghost = leftRow:gsub("Kurt Three", "Pia Eight")
paged("Pia Eight", function() s:OnReceiveLeaderboardCaptures(ghost, "Page Peer", "WHISPER") end)
-- (Its row is made by the capture row itself; the departure then reads as a kill row's would.)
assert(lb.captureCount["Pia Eight"] == 2 and (lb.playerInfo["Pia Eight"].guild or "") == "",
    "a departure gave an unknown player a guild")
assert(lb:MergeCaptureRowGuild("Quin Nine", "Horde", "", AT + 900, false) == false
    and lb.playerInfo["Quin Nine"] == nil, "a departure alone made a player row")
assert(lb:MergeCaptureRowGuild("Quin Nine", "Horde", "Guild Black", AT, false) == true
    and lb:GetHotPlayerGuildState("Quin Nine") == "Guild Black", "a guild alone made no player row")

-- 9. A kill row that cannot be served (outside the ranking's levels or classes) leaves the guild
-- to the capture row.
local realKill = s.BuildPagedLeaderboardKillPayload
s.BuildPagedLeaderboardKillPayload = function() return nil end
assert(s:BuildPagedLeaderboardCapturePayload(snapshotOf("Kurt Three", strong("Guild Black", AT),
    { ["Kurt Three"] = 4 }), "Kurt Three", EPOCH):find("=Guild Black", 1, true),
    "a kill row that is not served kept the guild off the capture row")
s.BuildPagedLeaderboardKillPayload = realKill

print("Capture rows carry the guild of a capture-only player: served, learnt, passed on, dated, gated OK")
