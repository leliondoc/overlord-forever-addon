-- /ov perf (2026-10-18): the addon list showed Overlord peaks no single slow call
-- explained. A peak can be many small calls in one frame (a burst of messages): the
-- report now lists the three heaviest frames, each with the calls that ran in it.
-- Real Commands.lua, stub game. Run from the addon root with Lua 5.1.
local frames = {}
function CreateFrame()
    local f = { scripts = {} }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    frames[#frames + 1] = f
    return f
end
local clock = 0
function debugprofilestop() return clock end
local now = 100
function GetTime() return now end
function GetAddOnMemoryUsage(name) return name == "Overlord" and 20480 or 0 end
function UpdateAddOnMemoryUsage() end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
SlashCmdList = {}
local printed = {}
Overlord = { L = setmetatable({}, { __index = function(_, k) return k end }) }
function Overlord:PrintNotification(text) printed[#printed + 1] = text end
assert(loadfile("Commands.lua"))()

-- Two module functions: one is a cheap message handler, the other a slow refresh.
Overlord.Sync = {}
function Overlord.Sync:OnAddonMessage() clock = clock + 0.5 end
Overlord.UI = {}
function Overlord.UI:Update() clock = clock + 3 end

Overlord.IsInitialized = true
SlashCmdList.OVERLORD("perf 10")
local perfFrame = frames[#frames]
assert(perfFrame.scripts.OnUpdate, "no frame hook for the profiler")
local function frameEnd() perfFrame.scripts.OnUpdate(perfFrame, 0.016) end

-- Frame 1: one refresh (3 ms). Frame 2: a burst of 20 messages (10 ms, each 0.5 ms).
-- Frame 3: nothing. Frame 4: a refresh and 4 messages (5 ms).
Overlord.UI:Update(); frameEnd()
for _ = 1, 20 do Overlord.Sync:OnAddonMessage() end; frameEnd()
frameEnd()
Overlord.UI:Update(); for _ = 1, 4 do Overlord.Sync:OnAddonMessage() end; frameEnd()
-- (A fifth, light frame never pushes out a heavier one.)
Overlord.Sync:OnAddonMessage(); frameEnd()

now = 110
SlashCmdList.OVERLORD("perf stop")
-- 2.3.0: a report like /ov network: header, one verdict per line, then the details.
local function line(text)
    for _, l in ipairs(printed) do if l:find(text, 1, true) then return l end end
end
assert(line("===== Performance:") and line("all good"), "no performance header:\n" .. table.concat(printed, "\n"))
assert(line("ReadyCheck-Ready") and line("Freezes") and line("0 calls over 50 ms in 10s; slowest 3.0 ms (UI:Update)"),
    "freezes line: " .. tostring(line("Freezes")))
assert(line("10.0 ms of Overlord in one frame"), "heaviest frame line missing")
assert(line("1.9 ms per second"), "average load: " .. tostring(line("Average load")))
assert(line("20.0 MB right now"), "addon memory line missing")
local header
for i, line in ipairs(printed) do
    if line:find("Heaviest frames", 1, true) then header = i end
end
assert(header, "no heaviest frames section:\n" .. table.concat(printed, "\n"))
local first, second, third = printed[header + 1], printed[header + 2], printed[header + 3]
assert(first and first:find("10.0 ms", 1, true) and first:find("Sync:OnAddonMessage 10.0 x20", 1, true),
    "the burst is not the heaviest frame: " .. tostring(first))
assert(second and second:find("5.0 ms", 1, true) and second:find("UI:Update 3.0 x1", 1, true)
    and second:find("Sync:OnAddonMessage 2.0 x4", 1, true), "second frame: " .. tostring(second))
assert(third and third:find("3.0 ms", 1, true), "third frame: " .. tostring(third))
assert(not printed[header + 4] or not printed[header + 4]:find("0.5 ms", 1, true), "more than three frames kept")
-- Restored: the module functions are the originals again.
clock = 0
Overlord.UI:Update()
assert(clock == 3, "profiler not removed")

-- A profiler started outside an instance can be stopped inside one: it times every call.
printed = {}
SlashCmdList.OVERLORD("perf 10")
Overlord.InstanceSuspended = true
SlashCmdList.OVERLORD("perf stop")
Overlord.InstanceSuspended = nil
assert(line("===== Performance:") and not line("DISABLED_IN_INSTANCE"),
    "/ov perf stop refused inside an instance:\n" .. table.concat(printed, "\n"))
clock = 0
Overlord.UI:Update()
assert(clock == 3, "profiler left running inside an instance")

-- 2.3.0: the whisper mesh and the guild lane carry the traffic while the channel is refused:
-- /ov perf must time them too.
Overlord.ChannelDirectory, Overlord.GuildLane = {}, {}
function Overlord.ChannelDirectory:Tick() clock = clock + 2 end
function Overlord.GuildLane:Pump() clock = clock + 1 end
printed = {}
SlashCmdList.OVERLORD("perf 10")
Overlord.ChannelDirectory:Tick()
Overlord.GuildLane:Pump()
now = 120
SlashCmdList.OVERLORD("perf stop")
assert(line("ChannelDirectory:Tick") and line("GuildLane:Pump"),
    "the whisper mesh and the guild lane are not timed:\n" .. table.concat(printed, "\n"))

print("Perf: heaviest frames with the calls inside them OK")
