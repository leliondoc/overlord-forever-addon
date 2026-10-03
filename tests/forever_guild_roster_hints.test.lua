-- Guild roster hints (1.2.4): the Blizzard guild roster already gives the guild,
-- class and level of our own guild members. Use them locally (only to fill what is
-- missing) and never ask the network (GR/CR) about those members.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local lb = Overlord.Leaderboard
local timers = {}
C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
local function drain()
    local guard = 0
    while #timers > 0 do
        guard = guard + 1
        assert(guard < 1000, "Roster work did not settle")
        table.remove(timers, 1)()
    end
end
function IsInInstance() return false end
function IsInGroup() return false end
function IsInRaid() return false end
function IsInGuild() return true end
function GetChannelName() return 1 end
function GetGuildInfo() return "French Guild" end
local roster = {
    { "Roster Mage", "Member", 1, 42, "Mage", "Elwynn", "", "", true, 0, "MAGE", 0, 0, false, false, 0, "Player-1-0000000A" },
    { "Roster Priest", "Member", 1, 60, "Priest", "Elwynn", "", "", false, 0, "PRIEST", 0, 0, false, false, 0, "Player-1-0000000B" },
    { "Roster Rogue", "Officer", 0, 25, "Rogue", "Durotar", "", "", true, 0, "ROGUE", 0, 0, false, false, 0, "Player-1-0000000C" },
}
local guidRace = { ["Player-1-0000000A"] = { "Gnome", 3 }, ["Player-1-0000000B"] = { "Dwarf", 2 },
    ["Player-1-0000000C"] = { "Human", 2 } }
function GetPlayerInfoByGUID(guid)
    local r = guidRace[guid]
    if not r then return nil end
    return "Class", "CLASS", r[1], r[1], r[2], "Name", ""
end
Overlord.Sync = Overlord.Sync or {}
Overlord.Sync.NormalizeRaceFileToken = Overlord.Sync.NormalizeRaceFileToken
    or function(_, race) return type(race) == "string" and race:match("^%a+$") or nil end
function GetNumGuildMembers() return #roster end
function GetGuildRosterInfo(index) return unpack(roster[index] or {}) end
C_GuildInfo = { GuildRoster = function() end }

-- Members: one unknown row, one with a known class, one with an owner-confirmed guild.
lb.kills["Roster Mage"] = 5
lb.playerInfo["Roster Mage"] = nil
lb.kills["Roster Priest"] = 7
lb.playerInfo["Roster Priest"] = { class = "WARLOCK", guild = "", guildAt = 0, level = 0 }
lb.kills["Roster Rogue"] = 9
lb.playerInfo["Roster Rogue"] = { class = "", guild = "Other Guild", guildAt = time(), level = 30,
    race = "Orc", raceSex = 2, raceAt = time() }
lb.kills["Outside Player"] = 11
lb.playerInfo["Outside Player"] = { class = "", guild = "", guildAt = 0, level = 0 }

lb:EnrichGuildFromLocalRoster()
drain()
lb:EnrichGuildFromLocalRoster()
drain()

local mage = lb.playerInfo["Roster Mage"]
assert(mage and mage.guild == "French Guild" and mage.class == "MAGE" and mage.level == 42,
    "An unknown guild member was not filled from the roster")
local priest = lb.playerInfo["Roster Priest"]
assert(priest.class == "WARLOCK", "The roster overwrote a class already known")
assert(priest.guild == "French Guild" and priest.level == 60, "Missing guild or level not filled")
local rogue = lb.playerInfo["Roster Rogue"]
assert(rogue.guild == "Other Guild" and rogue.level == 30,
    "The roster overwrote a dated guild or a known level")
assert(rogue.class == "ROGUE", "A missing class was not filled")
assert(mage.race == "Gnome" and mage.raceSex == 3 and mage.raceAt == 0,
    "A guild member's race was not read from its roster GUID")
assert(priest.race == "Dwarf", "A missing race was not filled from the roster GUID")
assert(rogue.race == "Orc", "The roster GUID overwrote a race already observed")
local outside = lb.playerInfo["Outside Player"]
assert(outside.guild == "" and outside.class == "", "A non-member received roster data")

assert(lb:IsLocalGuildRosterMember("Roster Mage") and not lb:IsLocalGuildRosterMember("Outside Player"))
assert(lb:GetLocalGuildRosterClass("Roster Rogue") == "ROGUE")
assert(lb:GetLocalGuildRosterClass("Outside Player") == nil)

-- No network request is sent about a guild member; outsiders still are.
assert(loadfile("SyncResolution.lua"))()
local sync = Overlord.Sync
local sent = {}
sync.SendToGroup = function(_, kind, payload) sent[#sent + 1] = { kind, payload } end
sync.SendToChannel = function(_, kind, payload) sent[#sent + 1] = { kind, payload } end
sync.BroadcastToRelay = function(_, kind, payload) sent[#sent + 1] = { kind, payload } end
sync.SendToNamedPeers = function(_, kind, payload)
    sent[#sent + 1] = { kind, payload }
end
lb.playerInfo["Roster Mage"].class = ""
sync:MaybeRequestMissingClass("Roster Mage")
sync:MaybeRequestMissingClass("Outside Player")
sync:FlushClassRequests()
drain()
sync:MaybeRequestMissingGuild("Roster Mage")
sync:MaybeRequestMissingGuild("Outside Player")
sync:FlushGuildRequests()
drain()
for _, packet in ipairs(sent) do
    assert(not packet[2]:find("Roster Mage", 1, true),
        "A guild member was asked about on the network: " .. packet[1])
end
local outsiderAsked = false
for _, packet in ipairs(sent) do
    if packet[2]:find("Outside Player", 1, true) then outsiderAsked = true end
end
assert(outsiderAsked, "Test setup: a non-member was not asked on the network")
assert(lb.playerInfo["Roster Mage"].class == "MAGE", "The class request did not use the roster")
print("Guild roster hints: guild, class, level and race (via GUID) of members filled locally, known facts kept, no GR/CR for members")
