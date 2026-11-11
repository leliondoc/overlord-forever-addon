-- 2.5.0: big battles in the chat. The shared bracket of a fight (the "Recent activity" panel's)
-- reaching 50 kills in five minutes is said once, anywhere in the world; the same fight is said
-- again only when its bracket doubles. On by default, nothing in an instance.
local serverNow = 1789530000
local maps = { [1437] = { name = "Wetlands", mapType = 3 } }
local inInstance = false
local env = setmetatable({}, { __index = _G })
env._G = env
env.Enum = { UIMapType = { Zone = 3, Dungeon = 4 } }
env.C_Map = { GetMapInfo = function(id) return maps[id] end }
env.GetServerTime = function() return serverNow end
env.GetTime = function() return serverNow end
env.time = function() return serverNow end
env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
env.IsInInstance = function() return inInstance end
env.C_Timer = { After = function() end }
local lines = {}
env.Overlord = { L = setmetatable({ FIGHT_ALERT = "Battle at %s: %d+ kills" }, { __index = function(_, k) return k end }),
    PrintNotification = function(_, text) lines[#lines + 1] = text end,
    Relay = { Broadcast = function() return 1 end } }
env.OverlordDB = {}
for _, file in ipairs({ "Fronts.lua", "FrontActivity.lua" }) do
    setfenv(assert(loadfile(file)), env)()
end
local fa = env.Overlord.FrontActivity
assert(fa.FIGHT_ALERT_MIN == 50, "the threshold he chose is 50")

local sender = 0
local function hear(key, bracket)
    sender = sender + 1
    serverNow = serverNow + 31
    return fa:OnReceiveKillBracket("1:" .. key .. ":" .. bracket .. ":" .. math.floor(serverNow / 30), "Peer N" .. sender, "BETA")
end
local function said(pattern)
    local count = 0
    for _, text in ipairs(lines) do if text:find(pattern) then count = count + 1 end end
    return count
end

-- 1. Below 50 nothing; at 50 one line naming the front and the bracket.
assert(hear("hillsbrad", 20) and hear("hillsbrad", 40), "fixture: brackets refused")
assert(#lines == 0, "a fight under 50 was said in the chat: " .. tostring(lines[1]))
assert(hear("hillsbrad", 50))
assert(#lines == 1 and lines[1]:find("50%+ kills") and lines[1]:find("Battle at "), "no line at 50: " .. tostring(lines[1]))
assert(not lines[1]:find("Battle at %?") and not lines[1]:find("Battle at hillsbrad"), "the front has no name: " .. lines[1])
-- 2. The same fight: again only when the bracket doubles.
assert(hear("hillsbrad", 50) ~= nil and hear("hillsbrad", 75))
assert(#lines == 1, "the same fight was said again at 75")
assert(hear("hillsbrad", 100))
assert(#lines == 2 and lines[2]:find("100%+ kills"), "no line when the fight doubled")
hear("hillsbrad", 150)
assert(#lines == 2, "said again at 150")
hear("hillsbrad", 200)
assert(#lines == 3 and lines[3]:find("200%+ kills"), "no line at 200")
-- A weaker reminder of the same fight says nothing.
hear("hillsbrad", 50)
assert(#lines == 3)
-- 3. A zone outside the fronts, anywhere in the world (no reach setting involved).
env.OverlordDB.config = { alertScope = "zone" }
-- (Three lines were said in the last minutes: a new battle waits for the window, see 8.)
assert(hear("#1437", 75))
assert(#lines == 3, "a fourth battle line in five minutes for a new battle")
serverNow = serverNow + fa.FIGHT_ALERT_WINDOW
assert(hear("#1437", 75))
-- (A bracket between two steps is said as the step it has reached: 75 reads 50+.)
assert(#lines == 4 and lines[4]:find("Battle at Wetlands: 50%+ kills"), "a zone's battle was not said: " .. tostring(lines[4]))
-- 4. Unticked: nothing. Ticked again: the next doubling is said.
env.OverlordDB.config.fightAlerts = false
hear("#1437", 150)
assert(#lines == 4, "said with the option off")
env.OverlordDB.config.fightAlerts = true
hear("#1437", 300)
assert(#lines == 5 and lines[5]:find("200%+"), "the option ticked again says nothing: " .. tostring(lines[5]))
-- 5. An instance, or the login map still awaited: nothing.
inInstance = true
hear("hillsbrad", 500)
inInstance = false
env.Overlord.WaitingForSync = true
hear("hillsbrad", 750)
env.Overlord.WaitingForSync = nil
assert(#lines == 5, "said in an instance or before the login map")
-- 6. The fight over for ten minutes: the next one at 50 is a new battle.
serverNow = serverNow + fa.FIGHT_ALERT_QUIET + 400
hear("hillsbrad", 50)
assert(#lines == 6 and lines[6]:find("50%+ kills"), "a new battle on the same front was not said")
-- 6b. The same lines whatever the order the brackets come in (they do not reach everyone in the
--     same order): one client hears 50, 75, 100, 150, 200, 300, another 75, 50, 150, 100, 300, 200,
--     a third only 300. The first two read 50+, 100+, 200+; the third 200+.
do
    local function heardIn(order)
        serverNow = serverNow + fa.FIGHT_ALERT_QUIET + 400
        fa:ResetForCampaign()
        local from = #lines
        for _, bracket in ipairs(order) do hear("arathi", bracket) end
        local out = {}
        for i = from + 1, #lines do out[#out + 1] = lines[i]:match("(%d+)%+ kills") end
        return table.concat(out, ",")
    end
    local inOrder = heardIn({ 50, 75, 100, 150, 200, 300 })
    local shuffled = heardIn({ 75, 50, 150, 100, 300, 200 })
    assert(inOrder == "50,100,200", "the lines of a battle heard in order: " .. inOrder)
    assert(shuffled == inOrder, "another order of the same brackets reads " .. shuffled .. ", not " .. inOrder)
    assert(heardIn({ 300 }) == "200", "a battle first heard at 300")
    assert(heardIn({ 2000 }) == "2000" and heardIn({ 750 }) == "500", "the top steps")
    -- A battle that grows fast: every step is said, the fourth and fifth line in five minutes
    -- too (the five-minute limit is for new battles), by every client alike.
    assert(heardIn({ 50, 100, 200, 300, 500, 750, 1000 }) == "50,100,200,500,1000", "the steps of a battle growing fast")
    -- Made-up brackets on every step of several battles at once: six lines in the window, no more.
    do
        serverNow = serverNow + fa.FIGHT_ALERT_QUIET + 400
        fa:ResetForCampaign()
        local from = #lines
        for _, bracket in ipairs({ 50, 100, 200, 500, 1000, 2000 }) do
            -- (At the same second: `hear` moves the clock by a slot each time.)
            for _, place in ipairs({ "arathi", "hillsbrad", "#1437" }) do fa:MaybeAnnounceFight(place, bracket, serverNow) end
        end
        assert(#lines - from == fa.FIGHT_ALERT_PER_WINDOW_ALL, "lines in one window for made-up battles: " .. (#lines - from))
    end
    serverNow = serverNow + fa.FIGHT_ALERT_QUIET + 400
    fa:ResetForCampaign()
    lines = {}
    for i = 1, 6 do lines[i] = "kept" end
end
-- 7. A new week forgets the fights said.
fa:ResetForCampaign()
hear("hillsbrad", 50)
assert(#lines == 7, "the weekly reset kept the fights already said")
-- The option exists in every language, with its tooltip and the line itself.
for _, file in ipairs({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua" }) do
    local text = assert(io.open(file, "rb")):read("*a")
    local _, labels = text:gsub("\nL%.FIGHT_ALERTS_LABEL = ", "")
    local _, tips = text:gsub("\nL%.FIGHT_ALERTS_TOOLTIP = ", "")
    local _, alerts = text:gsub('\nL%.FIGHT_ALERT = "[^"\n]*%%s[^"\n]*%%d%+[^"\n]*"', "")
    local want = file == "Locales.lua" and 5 or 1
    assert(labels == want and tips == want and alerts == want, file .. ": " .. labels .. "/" .. tips .. "/" .. alerts)
end
-- 8. Whatever the brackets say: three lines per five minutes, twelve an hour.
do
    fa:ResetForCampaign()
    lines = {}
    local saidAt = {}
    env.Overlord.PrintNotification = function(_, text) lines[#lines + 1] = text; saidAt[#saidAt + 1] = serverNow end
    local keys = { "hillsbrad", "#1437", "elwynn", "arathi", "ashenvale", "barrens", "redridge" }
    local known = 0
    for _, key in ipairs(keys) do
        if hear(key, 50) then known = known + 1 end
    end
    assert(known >= 5, "fixture: fronts known to this client: " .. known)
    assert(#lines == fa.FIGHT_ALERT_PER_WINDOW, "lines in five minutes whatever the fights: " .. #lines)
    -- A fight held back is said once there is room, if it still runs.
    serverNow = serverNow + fa.FIGHT_ALERT_WINDOW
    local before = #lines
    for _, key in ipairs(keys) do hear(key, 75) end
    assert(#lines > before and #lines - before <= fa.FIGHT_ALERT_PER_WINDOW, "after the window: " .. (#lines - before))
    -- An hour of made-up brackets on every front: twelve lines, no more.
    for round = 1, 30 do
        serverNow = serverNow + 100
        for _, key in ipairs(keys) do hear(key, ({ 100, 200, 500, 1000, 2000 })[round % 5 + 1]) end
    end
    assert(#saidAt >= fa.FIGHT_ALERT_PER_HOUR, "fixture: the made-up brackets said too little: " .. #saidAt)
    -- (A battle's first line: the first one naming its place since the reset above; these
    -- battles are heard again every 100 s, they never end.)
    local named, first = {}, {}
    for i = 1, #lines do
        local place = lines[i]:match("Battle at (.-): %d+%+")
        assert(place, "fixture: the place of a line: " .. lines[i])
        first[i] = not named[place]
        named[place] = true
    end
    for i = 1, #saidAt do
        local inHour, newInWindow, inWindow = 0, 0, 0
        for j = i, #saidAt do
            if saidAt[j] - saidAt[i] < 3600 then inHour = inHour + 1 end
            if saidAt[j] - saidAt[i] < fa.FIGHT_ALERT_WINDOW then
                inWindow = inWindow + 1
                if first[j] then newInWindow = newInWindow + 1 end
            end
        end
        assert(inHour <= fa.FIGHT_ALERT_PER_HOUR, "lines in one hour: " .. inHour)
        assert(newInWindow <= fa.FIGHT_ALERT_PER_WINDOW, "new battles in one window: " .. newInWindow)
        assert(inWindow <= fa.FIGHT_ALERT_PER_WINDOW_ALL, "lines in one window: " .. inWindow)
    end
end

-- The checkbox: on by default, read the same way as the line is.
do
    local f = assert(io.open("SettingsPanel.lua", "rb")); local panel = f:read("*a"); f:close()
    -- 2.5.0: the floating "+N platinum" text is off by default, an option turns it on.
    local function read(path) local fh = assert(io.open(path, "rb")); local text = fh:read("*a"); fh:close(); return text end
    local platinum = panel:match('var = "Overlord_PlatinumText".-end },')
    assert(platinum and platinum:find('label = "PLATINUM_TEXT_LABEL"', 1, true)
        and platinum:find('tooltip = "PLATINUM_TEXT_TOOLTIP"', 1, true) and platinum:find("default = false", 1, true)
        and platinum:find("cfg.platinumText == true", 1, true)
        and platinum:find("OverlordDB.config.platinumText = value == true", 1, true), "the options row of the floating platinum text")
    local resources = read("Ressources.lua")
    assert(resources:find("local function ShowFloatingGold%(amount%)%s+local cfg = OverlordDB and OverlordDB%.config%s+"
        .. "if not %(cfg and cfg%.platinumText == true%) then return end"), "the floating platinum text is not off by default")
    local labels, tips = 0, 0
    for _, path in ipairs({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua" }) do
        local text = read(path)
        local _, a = text:gsub("\nL%.PLATINUM_TEXT_LABEL = \"[^\"\n]+\"", "")
        local _, b = text:gsub("\nL%.PLATINUM_TEXT_TOOLTIP = \"[^\"\n]+\"", "")
        labels, tips = labels + a, tips + b
    end
    assert(labels == 7 and tips == 7, "the floating platinum option in seven languages: " .. labels .. " and " .. tips)
    local row = panel:match('var = "Overlord_FightAlerts".-end },')
    assert(row and row:find('label = "FIGHT_ALERTS_LABEL"', 1, true) and row:find('tooltip = "FIGHT_ALERTS_TOOLTIP"', 1, true)
        and row:find("default = true", 1, true) and row:find("cfg.fightAlerts == false", 1, true)
        and row:find("OverlordDB.config.fightAlerts = value == true", 1, true), "the options row of the battle alerts")
end
print("Fight alert: 50 and more, once per battle then when it doubles, world zones, option, instance, seven languages OK")
