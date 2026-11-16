-- Install the real system-message filter with only the current chat API.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local now, installed, registrations = 100, nil, 0
local notices = {}
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
        assert(type(callback) == "function")
        if event ~= "CHAT_MSG_SYSTEM" then notices[event] = callback; return end
        installed, registrations = callback, registrations + 1
    end,
}
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(installed, "Current ChatFrameUtil API did not install the offline whisper filter")
Overlord.Sync:InstallWhisperOfflineChatFilter()
assert(registrations == 1, "Offline filter was registered more than once")

-- 2.2.2: the game's notices about our channel and our pads are hidden from chat addons that
-- show every channel notice (Chattynator printed "left channel OvPad..." every minute).
local seat = notices.CHAT_MSG_CHANNEL_NOTICE
assert(seat and notices.CHAT_MSG_CHANNEL_NOTICE_USER == seat, "channel notice filter not installed")
local ours = Overlord.Sync:GetChannelBaseName()
assert(seat(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", "6. OvPad00018d1", "", 0, 0, 6, "OvPad00018d1"),
    "a pad's notice shown")
assert(seat(nil, "CHAT_MSG_CHANNEL_NOTICE", "NOT_ALLOWED", "", "", "9. " .. ours, "", 0, 0, 9, ours),
    "our channel's notice shown")
assert(seat(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", "7. OvPad00018d2", "", 0, 0, 7, nil),
    "a pad's notice without base name shown")
assert(not seat(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", "2. Trade - City", "", 0, 2, 2, "Trade - City"),
    "another channel's notice hidden")
assert(not seat(nil, "CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", "", "5. OvPadding", "", 0, 0, 5, "OvPadding"),
    "a player's own channel that only looks like a pad hidden")
do
    local secret = setmetatable({}, { __index = function() error("secret value read") end })
    issecretvalue = function(v) return v == secret end
    assert(not seat(nil, "CHAT_MSG_CHANNEL_NOTICE", secret, "", "", secret, "", 0, 0, 9, secret),
        "a secret notice read")
    issecretvalue = nil
end

local message = "No player named 'Massa Zug' is currently playing."
now = 200
assert(not installed(nil, "CHAT_MSG_SYSTEM", message), "Unrelated offline error was hidden")
assert(Overlord.Sync:SendWhisper("BF", "test-fragment", "Massa Zug"))
assert(installed(nil, "CHAT_MSG_SYSTEM", message), "Actual addon whisper error was not hidden")
-- 2.3.0: the player's own /w to somebody offline stays visible while the mesh whispers;
-- a corrupted target right after our whisper is still hidden.
assert(not installed(nil, "CHAT_MSG_SYSTEM", "No player named 'Ami Absent' is currently playing."),
    "the player's own offline error was hidden by a recent addon whisper")
assert(not installed(nil, "CHAT_MSG_SYSTEM", "No player named 'Ami-Realm' is currently playing."),
    "the player's own offline error (with realm) was hidden by a recent addon whisper")
assert(installed(nil, "CHAT_MSG_SYSTEM", "No player named ')g]' is currently playing."),
    "a corrupted target after our whisper was shown")
assert(not installed(nil, "CHAT_MSG_SYSTEM", "Massa Zug has come online."),
    "An unrelated system event was hidden")
now = now + 90
assert(installed(nil, "CHAT_MSG_SYSTEM", message), "A late error (90 s) for an addon target was shown")
now = now + 31
assert(not installed(nil, "CHAT_MSG_SYSTEM", message), "Expired addon target still hid errors")
-- In an instance (and on 12.x secret chat text) the filter never reads the line.
-- (The whisper only records its target for the filter: its result is not what is tested here.)
Overlord.Sync:SendWhisper("BF", "test-fragment", "Massa Zug")
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
    assert(type(callback) == "function")
    if event ~= "CHAT_MSG_SYSTEM" then notices[event] = callback; return end
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
    if event ~= "CHAT_MSG_SYSTEM" then notices[event] = callback; return end
    installed = callback
end }
table.remove(pending, 1)()
assert(installed and #pending == 0, "Late chat API did not install the filter")
-- 2.2.2: the seat filter tests a secret base name before any comparison.
do
    local f = assert(io.open("SyncAux.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local body = src:match("function Overlord%.Sync%.SuppressSeatChannelNotice(.-)\nend")
    assert(body, "seat notice filter not found")
    local secretAt = body:find("issecretvalue(baseName)", 1, true)
    local compareAt = body:find("baseName ~= nil", 1, true)
    assert(secretAt and compareAt and secretAt < compareAt, "the base name is compared before its secret test")
end
print("Offline addon whisper filter: current, legacy and late chat APIs OK")

-- 2.5.4: in an instance no chat filter of ours stays installed. A filter that reads nothing is
-- still called by the game while it handles a chat line, which taints its own handling of that
-- line (battleground report of 2026-11-16: "attempted to iterate a table that cannot be
-- accessed while tainted (execution tainted by 'Overlord')", thousands of times). Taken out on
-- the way in, back on the way out; nothing installs inside.
do
    assert(loadfile("SyncAux.lua"))()
    local sync = Overlord.Sync
    local filters, timers = {}, 0
    local function count() local n = 0 for _ in pairs(filters) do n = n + 1 end return n end
    ChatFrame_AddMessageEventFilter, Chat_AddMessageEventFilter, ChatFrame_RemoveMessageEventFilter = nil, nil, nil
    ChatFrameUtil = {
        AddMessageEventFilter = function(event, fn) filters[event] = fn end,
        RemoveMessageEventFilter = function(event, fn)
            assert(filters[event] == fn, "removed a filter that was not ours: " .. tostring(event))
            filters[event] = nil
        end,
    }
    C_Timer.After = function(delay) assert(delay == 5); timers = timers + 1 end
    function IsInInstance() return false end
    sync._seatNoticeFilter = nil
    Overlord.InstanceSuspended = false
    sync:InstallWhisperOfflineChatFilter()
    assert(filters.CHAT_MSG_SYSTEM and filters.CHAT_MSG_CHANNEL_NOTICE and filters.CHAT_MSG_CHANNEL_NOTICE_USER
        and count() == 3, "fixture: the three filters are not installed")
    -- The way in.
    Overlord.InstanceSuspended = true
    assert(sync:RemoveChatFilters() == true and count() == 0, "a chat filter of ours stayed installed in an instance")
    assert(sync:RemoveChatFilters() == true and count() == 0, "a second removal did something")
    -- (Both channel-notice filters go whatever our flag says: one installed alone would stay.)
    Overlord.InstanceSuspended = false
    sync:InstallWhisperOfflineChatFilter()
    sync._seatNoticeFilter = nil
    Overlord.InstanceSuspended = true
    assert(sync:RemoveChatFilters() == true and count() == 0, "a channel-notice filter stayed because our flag was not set")
    assert(sync:InsideInstance() == true, "suspended is not inside an instance")
    -- Inside: nothing installs, nothing is asked again (the way out does it).
    sync:InstallWhisperOfflineChatFilter()
    assert(sync:InstallSeatNoticeFilter() == false and count() == 0 and timers == 0, "a chat filter was installed inside an instance")
    -- The way out.
    Overlord.InstanceSuspended = false
    sync:InstallWhisperOfflineChatFilter()
    assert(count() == 3 and timers == 0, "the chat filters did not come back on the way out")
    -- A login or a /reload inside an instance, before our own suspension: nothing installed, asked
    -- again a few times only.
    sync:RemoveChatFilters()
    function IsInInstance() return true, "pvp" end
    for _ = 1, 10 do sync:InstallWhisperOfflineChatFilter() end
    assert(count() == 0 and timers == 6, "a login inside an instance: installed " .. count() .. ", asked again " .. timers)
    function IsInInstance() return false end
    -- A client whose chat cannot remove a filter: said, and the filter still reads nothing inside.
    sync:InstallWhisperOfflineChatFilter()
    local system = filters.CHAT_MSG_SYSTEM
    ChatFrameUtil.RemoveMessageEventFilter = nil
    assert(sync:RemoveChatFilters() == false and count() == 3, "fixture: removal without the game's function")
    Overlord.InstanceSuspended = true
    assert(system(nil, "CHAT_MSG_SYSTEM", "No player named 'Massa Zug' is currently playing.") == false,
        "the filter acted inside an instance")
    Overlord.InstanceSuspended = false
    -- The wiring: the way in removes them, the way out installs them again.
    local f = assert(io.open("Sync.lua", "rb"))
    local source = f:read("*a")
    f:close()
    local suspend = source:match("function Overlord%.Sync:Suspend%(%)(.-)\nend")
    local resume = source:match("function Overlord%.Sync:Resume%(%)(.-)\nend")
    assert(suspend and suspend:find("if self.RemoveChatFilters then pcall(self.RemoveChatFilters, self) end", 1, true), "Sync:Suspend leaves the chat filters installed")
    assert(resume and resume:find("if self.InstallWhisperOfflineChatFilter then pcall(self.InstallWhisperOfflineChatFilter, self) end", 1, true), "Sync:Resume does not install the chat filters again")
end
print("Chat filters: none of ours installed inside an instance, back on the way out OK")
