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

SlashCmdList.OVERLORD("perf stop")
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

print("Perf: heaviest frames with the calls inside them OK")
