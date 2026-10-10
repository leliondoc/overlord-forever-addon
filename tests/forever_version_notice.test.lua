-- The "newer version available" notice prints the version field of a received sync
-- request. It used to accept anything starting with digits, so a forged request
-- could put a multi-line, official-looking [Overlord] notice (escape codes, a link)
-- on every channel listener. Only a plain x.y.z is accepted now.
assert(loadfile("tests/forever_leaderboard.test.lua"))()
local sync = Overlord.Sync
local prints = {}
Overlord.PrintNotification = function(_, msg) prints[#prints + 1] = msg end
Overlord.Version = "1.8.1"
Overlord.L.VERSION_OUTDATED = "A newer version (%s) is available. Please update!"
IsInInstance = function() return false end
strsplit = strsplit or function(sep, value, limit)
    local fields, start = {}, 1
    while not limit or #fields < limit - 1 do
        local at = value:find(sep, start, true)
        if not at then break end
        fields[#fields + 1] = value:sub(start, at - 1)
        start = at + #sep
    end
    fields[#fields + 1] = value:sub(start)
    return unpack(fields)
end
Overlord.InstanceSuspended = false
local function notices()
    local n = 0
    for _, msg in ipairs(prints) do if msg:find("newer version", 1, true) then n = n + 1 end end
    return n
end
pcall(sync.OnSyncRequest, sync, "Evil Doer", "Horde:9.9.9|n|cFFFF0000[Overlord]|r get the fix at evil", "CHANNEL")
pcall(sync.OnSyncRequest, sync, "Evil Doer", "Horde:12.0", "CHANNEL")
assert(notices() == 0, "a forged version field printed a notice: " .. tostring(prints[1]))
pcall(sync.OnSyncRequest, sync, "Honest Player", "Horde:1.9.0", "CHANNEL")
assert(notices() == 1 and prints[#prints]:find("(1.9.0)", 1, true), "an honest newer version was not announced")
print("Version notice: only a plain x.y.z is announced")
