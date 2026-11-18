-- 2.6.0: the game's "no player named" line for one of our whispers is hidden in any language.
-- A Ukrainian line («Name», rewritten by a translation addon before our filter) was not read:
-- the offline partner was never noted and was whispered for minutes (report 2026-11-18).
assert(loadfile("tests/forever_world_kills.test.lua"))()
local s = Overlord.Sync
local clock = 9000
function GetTime() return clock end
function IsInInstance() return false end
Overlord.InstanceSuspended = false

local filters = {}
ChatFrameUtil = ChatFrameUtil or {}
ChatFrameUtil.AddMessageEventFilter = function(event, fn) filters[event] = fn end
ChatFrameUtil.RemoveMessageEventFilter = function(event) filters[event] = nil end
s:RemoveChatFilters()
s:InstallWhisperOfflineChatFilter()
local filter = filters.CHAT_MSG_SYSTEM
assert(type(filter) == "function", "fixture: the offline filter was not installed")

ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
local noted = {}
local directory = Overlord.ChannelDirectory
local realNote = directory and directory.NoteUnreachable
Overlord.ChannelDirectory = Overlord.ChannelDirectory or {}
Overlord.ChannelDirectory.NoteUnreachable = function(_, name) noted[#noted + 1] = name; return true end

s:_RememberRecentAddonWhisper("Asylum Demon", clock)
clock = clock + 20

local ukrainian = "Гравця на ім'я «Asylum Demon» зараз немає в грі."
assert(filter(nil, "CHAT_MSG_SYSTEM", ukrainian) == true, "the Ukrainian line for our whisper was shown")
assert(noted[#noted] == "Asylum Demon", "the Ukrainian line did not note the partner offline")

local russian = "Персонаж по имени \"Asylum Demon\" сейчас не в игре."
assert(filter(nil, "CHAT_MSG_SYSTEM", russian) == true, "a line with straight double quotes was shown")

assert(filter(nil, "CHAT_MSG_SYSTEM", "No player named 'Asylum Demon' is currently playing.") == true,
    "the game's own line for our whisper was shown")

-- Not ours: a name we never whispered, a line with a link, a whisper older than two minutes.
assert(filter(nil, "CHAT_MSG_SYSTEM", "Гравця на ім'я «Other Player» зараз немає в грі.") == false,
    "a line about a player we did not whisper was hidden")
assert(filter(nil, "CHAT_MSG_SYSTEM", "|Hplayer:Asylum Demon|h[Asylum Demon]|h «Asylum Demon» joined.") == false,
    "a system line with a link was hidden")
-- Right after a whisper, a quoted token that is no name (digits) in a line the game's string
-- does not give is not ours either (the 8 s window only covers the game's own line).
s:_RememberRecentAddonWhisper("Asylum Demon", clock)
assert(filter(nil, "CHAT_MSG_SYSTEM", "Канал «Raid 12» зараз недоступний.") == false,
    "an unrelated quoted line right after a whisper was hidden")
clock = clock + 121
assert(filter(nil, "CHAT_MSG_SYSTEM", ukrainian) == false, "a line two minutes after the whisper was hidden")

if directory then directory.NoteUnreachable = realNote; Overlord.ChannelDirectory = directory end
print("Whisper offline filter: any language's quotes, our recent whisper targets only")
