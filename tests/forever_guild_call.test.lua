-- Guild call to arms: the guild horn sends one GUILD addon message, anywhere outside
-- instances, once every 10 minutes for the whole guild; guild mates get a raid warning naming
-- the caller, the map (in their own language), the Overlord point and the position. Read only
-- on GUILD, never relayed. Real Sync + SyncAux on the beta fixture.
assert(loadfile("tests/forever_beta_integration.test.lua"))()

local sync = Overlord.Sync
local PREFIX = "OverlordF"
local server = 1790200000
GetServerTime = function() return server end
local inInstance = false
IsInInstance = function() return inInstance end
local guildName = "Fight The Power"
IsInGuild = function() return guildName ~= nil end
GetGuildInfo = function() return guildName end
Overlord.InstanceSuspended = false
Overlord.PlayerFaction = "Alliance"
OverlordDB.guildCallAt = nil
Overlord.L.GUILD_CALL_RECEIVED = Overlord.L.GUILD_CALL_RECEIVED or "%s calls the guild to arms: %s!"
Overlord.L.GUILD_CALL_RECEIVED_GENERIC = Overlord.L.GUILD_CALL_RECEIVED_GENERIC or "%s calls the guild to arms!"

-- The map and the point are named by this client, never from the text received.
C_Map = C_Map or {}
C_Map.GetBestMapForUnit = function() return 1437 end
C_Map.GetPlayerMapPosition = function()
    return { GetXY = function() return 0.4512, 0.6249 end }
end
C_Map.GetMapInfo = function(id) if id == 1437 then return { name = "Wetlands" } end end
local savedGetZone = Overlord.Zones.GetZone
Overlord.Zones.GetZone = function(_, id)
    if id == "wetlands_menethil_keep" then return { id = id, name = "Menethil Keep" } end
end
Overlord.Zones.GetCurrentPlayerZone = function() return { id = "wetlands_menethil_keep" } end

local sent = {}
local sendResult = true
sync.SendAddonChecked = function(_, msg, chatType)
    sent[#sent + 1] = { msg = msg, chatType = chatType }
    return sendResult
end
local warnings = {}
Overlord.PrintRaidWarning = function(_, text) warnings[#warnings + 1] = text end
Overlord.PrintNotification = function() end

-- 1. The payload: map id, Overlord point, whole percents.
local payload = sync:BuildGuildCallPayload()
assert(payload == "1437:wetlands_menethil_keep:45:62", "unexpected guild call payload: " .. payload)

-- 2. One GUILD message, then 10 minutes of cooldown for this guild.
assert(sync:BroadcastGuildCall(payload) == true, "the guild call was refused")
assert(#sent == 1 and sent[1].chatType == "GUILD" and sent[1].msg == "CG:" .. payload,
    "the guild call did not leave as one GUILD message")
local rem = sync:GetGuildCallCooldownRemaining()
assert(rem > 600 - 5 and rem <= 600, "guild cooldown is not 10 minutes: " .. rem)
assert(sync:BroadcastGuildCall(payload) == false and #sent == 1, "a second call passed within 10 minutes")
server = server + 601
assert(sync:GetGuildCallCooldownRemaining() == 0, "the guild cooldown outlived 10 minutes")

-- 3. No guild, an instance or a refused send: nothing, and no cooldown taken.
guildName = nil
assert(sync:BroadcastGuildCall(payload) == false and #sent == 1, "a call left without a guild")
guildName = "Fight The Power"
inInstance = true
assert(sync:BroadcastGuildCall(payload) == false and #sent == 1, "a call left from an instance")
inInstance = false
sendResult = false
assert(sync:BroadcastGuildCall(payload) == false, "a refused send counted as a call")
assert(sync:GetGuildCallCooldownRemaining() == 0, "a refused send started the cooldown")
sendResult = true

-- 4. Another guild's cooldown is not ours (an alt in another guild).
assert(sync:BroadcastGuildCall(payload) == true, "fixture: call")
guildName = "Ganked and Confused"
assert(sync:GetGuildCallCooldownRemaining() == 0, "one guild's call blocked another guild")
-- The alt calls his own guild: ours keeps its delay (one row per guild).
server = server + 30
assert(sync:BroadcastGuildCall(payload) == true, "the alt's guild call was refused")
guildName = "Fight The Power"
assert(sync:GetGuildCallCooldownRemaining() > 500, "an alt's call in another guild erased our guild's delay")
-- Rows whose delay is over go at the next write; a date beyond the delay blocks nothing.
OverlordDB.guildCallAt["old guild"] = server - 700
server = server + 601
assert(sync:BroadcastGuildCall(payload) == true, "fixture: call after the delay")
assert(OverlordDB.guildCallAt["old guild"] == nil and OverlordDB.guildCallAt["ganked and confused"] == nil,
    "finished delays were kept")
OverlordDB.guildCallAt["fight the power"] = server + 5000
assert(sync:GetGuildCallCooldownRemaining() == 0, "a date set in the far future blocked the horn")
OverlordDB.guildCallAt = nil

-- 5. Guild name not known yet (just after login): a call heard is not shown (no delay kept).
guildName = nil
sync:OnAddonMessage(PREFIX, "CG:1437::50:50", "GUILD", "Early Member")
assert(#warnings == 0, "a guild call was shown before our guild was known")
guildName = "Fight The Power"

-- Received on GUILD: a raid warning with the caller, point, map and position.
sync:OnAddonMessage(PREFIX, "CG:1437:wetlands_menethil_keep:45:62", "GUILD", "Starbux Skyfire")
assert(#warnings == 1, "a guild call heard on GUILD was not shown")
assert(warnings[1] == "Starbux Skyfire calls the guild to arms: Menethil Keep, Wetlands (45, 62)!",
    "unexpected warning: " .. tostring(warnings[1]))
assert(sync:GetGuildCallCooldownRemaining() > 600 - 5, "receiving a call did not start the guild cooldown")

-- 6. During that cooldown nothing else is shown, the same caller or another.
sync:OnAddonMessage(PREFIX, "CG:1437::50:50", "GUILD", "Other Member")
sync:OnAddonMessage(PREFIX, "CG:1437::50:50", "GUILD", "Starbux Skyfire")
assert(#warnings == 1, "a second call within the guild cooldown was shown")

-- 7. Never read anywhere but GUILD.
OverlordDB.guildCallAt = nil
server = server + 700
for _, channel in ipairs({ "CHANNEL", "WHISPER", "PARTY", "RAID" }) do
    sync:OnAddonMessage(PREFIX, "CG:1437::50:50", channel, "Stranger " .. channel)
end
assert(#warnings == 1, "a guild call was read outside the guild")

-- 8. Nothing from the text is shown raw: unknown point and map, made-up coordinates.
sync:OnAddonMessage(PREFIX, "CG:999999:|cFFFF0000evil|r:500:-3", "GUILD", "Prank Member")
assert(#warnings == 2 and warnings[2] == "Prank Member calls the guild to arms!",
    "made-up fields reached the warning: " .. tostring(warnings[2]))

-- 9. Our own copy coming back, and anything inside an instance, is not shown.
OverlordDB.guildCallAt = nil
local me = sync:GetPlayerFullName()
sync:OnAddonMessage(PREFIX, "CG:1437::50:50", "GUILD", me)
assert(#warnings == 2, "our own guild call was shown to us")
Overlord.InstanceSuspended = true
sync:OnAddonMessage(PREFIX, "CG:1437::50:50", "GUILD", "Dungeon Member")
assert(#warnings == 2, "a guild call was shown inside an instance")
Overlord.InstanceSuspended = false

Overlord.Zones.GetZone = savedGetZone
print("Forever guild call: one GUILD message, 10 min per guild, read on GUILD only, place named locally OK")
