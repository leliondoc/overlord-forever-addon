-- Install the real system-message filter with only the current chat API.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now, installed, registrations = 100, nil, 0
function GetTime() return now end
function IsInInstance() return false end
function securecall(fn, ...) return fn(...) end
C_ChatInfo = { SendAddonMessage = function() return true end }
Overlord.InstanceSuspended = false
Overlord.Relay = nil
ChatFrame_AddMessageEventFilter = nil
Chat_AddMessageEventFilter = nil
ChatFrameUtil = {
    AddMessageEventFilter = function(event, callback)
        assert(event == "CHAT_MSG_SYSTEM" and type(callback) == "function")
        installed, registrations = callback, registrations + 1
    end,
}
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(installed, "Current ChatFrameUtil API did not install the offline whisper filter")
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(registrations == 1, "Offline filter was registered more than once")

local message = "No player named 'Massa Zug' is currently playing."
now = 200
assert(not installed(nil, "CHAT_MSG_SYSTEM", message), "Unrelated offline error was hidden")
assert(Overlord.Sync:SendWhisper("BF", "test-fragment", "Massa Zug"))
assert(installed(nil, "CHAT_MSG_SYSTEM", message), "Actual addon whisper error was not hidden")
assert(not installed(nil, "CHAT_MSG_SYSTEM", "Massa Zug has come online."),
    "An unrelated system event was hidden")
now = now + 90
assert(installed(nil, "CHAT_MSG_SYSTEM", message), "A late error (90 s) for an addon target was shown")
now = now + 31
assert(not installed(nil, "CHAT_MSG_SYSTEM", message), "Expired addon target still hid errors")
-- In an instance (and on 12.x secret chat text) the filter never reads the line.
assert(Overlord.Sync:SendWhisper("BF", "test-fragment", "Massa Zug") ~= nil or true)
Overlord.InstanceSuspended = true
assert(not installed(nil, "CHAT_MSG_SYSTEM", message), "Filter acted inside an instance")
Overlord.InstanceSuspended = false
local secret = setmetatable({}, { __index = function() error("secret value read") end })
issecretvalue = function(v) return v == secret end
assert(not installed(nil, "CHAT_MSG_SYSTEM", secret), "Filter touched a secret value")
issecretvalue = nil

-- Older clients still expose the global registration function.
assert(loadfile("SyncAux.lua"))()
ChatFrameUtil = nil
installed, registrations = nil, 0
ChatFrame_AddMessageEventFilter = function(event, callback)
    assert(event == "CHAT_MSG_SYSTEM" and type(callback) == "function")
    installed, registrations = callback, registrations + 1
end
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(installed and registrations == 1, "Legacy chat API stopped installing the filter")

-- A chat module loaded after the addon is picked up by the existing bounded retry.
assert(loadfile("SyncAux.lua"))()
ChatFrame_AddMessageEventFilter = nil
installed = nil
local pending = {}
C_Timer.After = function(delay, callback)
    assert(delay == 5)
    pending[#pending + 1] = callback
end
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(#pending == 1 and not installed)
ChatFrameUtil = { AddMessageEventFilter = function(event, callback)
    assert(event == "CHAT_MSG_SYSTEM")
    installed = callback
end }
table.remove(pending, 1)()
assert(installed and #pending == 0, "Late chat API did not install the filter")
print("Offline addon whisper filter: current, legacy and late chat APIs OK")
