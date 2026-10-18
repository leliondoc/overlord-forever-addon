-- PvP group finder window: real GroupFinderUI.lua, GroupFinder.lua and UIShared.lua on
-- stub frames. The window builds, paints the board and the card, and stays cheap:
-- nothing is built or painted while hidden, a refresh creates no frame, an unchanged
-- row is not repainted, a burst of changes costs one pass.

local now = 100
local timers = {}
local created = 0
local writes = 0

local function runTimers(seconds)
    now = now + seconds
    local due = {}
    for index = #timers, 1, -1 do
        if timers[index].at <= now then table.insert(due, 1, table.remove(timers, index)) end
    end
    for _, timer in ipairs(due) do timer.fn() end
end

-- Stub widgets: every method exists; the few the window reads back keep their value.
local function widget(kind)
    local w = { _kind = kind, _shown = true, _scripts = {}, _points = 0 }
    local methods = {}
    function methods:Show() self._shown = true; if self._scripts.OnShow then self._scripts.OnShow(self) end end
    function methods:Hide()
        local was = self._shown
        self._shown = false
        if was and self._scripts.OnHide then self._scripts.OnHide(self) end
    end
    function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
    function methods:IsShown() return self._shown end
    function methods:SetScript(name, fn) self._scripts[name] = fn end
    function methods:GetScript(name) return self._scripts[name] end
    function methods:HookScript(name, fn)
        local previous = self._scripts[name]
        self._scripts[name] = function(...)
            if previous then previous(...) end
            return fn(...)
        end
    end
    function methods:SetPoint(...)
        self._point = { ... }
        self._allPoints = self._allPoints or {}
        self._allPoints[#self._allPoints + 1] = self._point
    end
    function methods:ClearAllPoints() self._point, self._allPoints = nil, nil end
    function methods:SetTexCoord(...) self._coords = { ... } end
    function methods:SetScale(scale) self._scale = scale end
    function methods:IsOwned(owner) return self._owner == owner end
    function methods:SetOwner(owner) self._owner = owner; self._lines = {} end
    function methods:AddLine(text) self._lines[#self._lines + 1] = text end
    function methods:SetText(text) writes = writes + 1; self._text = text end
    function methods:GetText() return self._text end
    function methods:SetTexture(texture) self._texture = texture end
    function methods:SetAlpha(alpha) self._alpha = alpha end
    function methods:SetWidth(width) self._width = width end
    function methods:GetWidth() return self._width or 100 end
    function methods:GetHeight() return 100 end
    function methods:GetFrameLevel() return 1 end
    function methods:GetFont() return "font", 12, "" end
    function methods:IsMouseOver() return false end
    function methods:CreateTexture() created = created + 1; return widget("Texture") end
    function methods:CreateFontString() created = created + 1; return widget("FontString") end
    function methods:CreateAnimationGroup()
        local group = widget("AnimationGroup")
        group.CreateAnimation = function() return widget("Animation") end
        group.Play = function(self) self.playing = true end
        group.Stop = function(self) self.playing = false end
        group.IsPlaying = function(self) return self.playing == true end
        return group
    end
    return setmetatable(w, { __index = function(_, k)
        if methods[k] then return methods[k] end
        -- Any other widget method is a no-op.
        if type(k) == "string" and k:match("^%u") then return function() end end
        return nil
    end })
end

local framesByName = {}
CreateFrame = function(kind, name)
    created = created + 1
    local f = widget(kind)
    if name then framesByName[name] = f end
    return f
end
UIParent = widget("Frame")
GameTooltip = widget("GameTooltip")
GameTooltip_Hide = function() end
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
SOUNDKIT = {}
PlaySound = function() end
InCombatLockdown = function() return false end
GetTime = function() return now end
GetServerTime = function() return 1700000000 + now end
GetLocale = function() return "enUS" end
IsInInstance = function() return false end
local group = { size = 0, raid = false, leader = false }
IsInGroup = function() return group.size > 0 end
IsInRaid = function() return group.size > 0 and group.raid end
UnitIsGroupLeader = function() return group.size > 0 and group.leader end
GetNumGroupMembers = function() return group.size end
UnitClass = function() return "Warrior", "WARRIOR" end
securecall = function(fn, ...) return fn(...) end
C_Timer = {
    After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end,
    NewTimer = function(delay, fn)
        timers[#timers + 1] = { at = now + delay, fn = fn }
        return { Cancel = function() end }
    end,
    NewTicker = function() return { Cancel = function() end } end,
}
local sent = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, text, chatType, target)
        sent[#sent + 1] = { prefix = prefix, text = text, chatType = chatType, target = target }
        return 0
    end,
}
local invites = {}
C_PartyInfo = { InviteUnit = function(name) invites[#invites + 1] = name end, ConvertToRaid = function() group.raid = true end }
local menus = {}
MenuUtil = { CreateContextMenu = function(_, build)
    local function node(label, fn)
        local n = { label = label, fn = fn, children = {} }
        function n:CreateButton(childLabel, childFn)
            local child = node(childLabel, childFn)
            self.children[#self.children + 1] = child
            return child
        end
        return n
    end
    local root = node("root")
    build(nil, root)
    menus[#menus + 1] = root
end }
C_Map = { GetBestMapForUnit = function() return 1417 end }

local zone = { id = "stromgarde", name = "Stromgarde" }
local arathi = { id = "arathi", mapName = "Arathi Highlands", dropdownLabel = "Arathi", preferredMapID = 1417, zones = { zone } }
local printed = {}
local gridRefreshes, opened, closed = 0, 0, 0
local channelId, channelClosed = 5, false
Overlord = {
    PlayerFaction = "Alliance", InstanceSuspended = false, L = {},
    PrintNotification = function(_, text) printed[#printed + 1] = text end,
    PlayPanelOpenSound = function() opened = opened + 1 end,
    PlayPanelCloseSound = function() closed = closed + 1 end,
    SafeUnitLevel = function() return 60 end,
    GetPlayerContinent = function() return "EK" end,
    GetMapContinent = function() return "EK" end,
    Fronts = {
        Order = { "arathi" }, Registry = { arathi = arathi },
        GetZone = function(_, id) if id == "stromgarde" then return zone, arathi end end,
        IsKnownZoneId = function(_, id) return id == "stromgarde" end,
        ResolveFrontByMapID = function(_, mapID) return mapID == 1417 and arathi or nil end,
    },
    OutpostSites = { stonetalon = { siteKey = "stonetalon", isFortress = true } },
    Outpost = {
        GetSite = function(_, key) return key == "stonetalon" and { siteKey = key, isFortress = true } or nil end,
        GetDisplayName = function() return "Stonetalon Keep" end,
    },
    Sync = {
        GetPlayerFullName = function() return "Alice Smith" end,
        CanonicalForeverName = function(_, n) return type(n) == "string" and n:match("^%a+ %a+$") and n or nil end,
        IsSenderLocalPlayer = function(_, n) return n == "Alice Smith" end,
        IsValidWhisperTarget = function() return true end,
        GetChannelId = function() return channelId end,
        IsChannelClosed = function() return channelClosed and not channelId end,
        TakeChannelToken = function() return true end,
        NoteChannelSendKind = function() end,
        SenderIsInOurGroup = function() return false end,
    },
}
OverlordDB = {}

assert(loadfile("GroupFinderLocales.lua"))()
assert(loadfile("UIShared.lua"))()
Overlord.UI.GetEffectiveUiScale = function() return 1 end
Overlord.UI.ScheduleActionGridActiveRefresh = function() gridRefreshes = gridRefreshes + 1 end
local gridButton = { label = widget("FontString") }
Overlord.UI.groupFinderBtn = gridButton
assert(loadfile("GroupFinder.lua"))()
assert(loadfile("GroupFinderUI.lua"))()
local GF, UI = Overlord.GroupFinder, Overlord.GroupFinderUI
GF.Random = function() return 0.5 end

local function hear(text, sender)
    GF:OnAddonMessage(text, "CHANNEL", sender)
end

-- Loading the files builds nothing; the board fills with the window closed, at no cost.
assert(created <= 2, "frames built at load: " .. created)
assert(not UI:IsShown())
local base = created
hear("L:1:A:a:z:stromgarde:40:12:20:1:1:60:150", "Bob Stone")
hear("L:1:A:h:w::5:5:0:0:1:60:150", "Carl Reed")
assert(GF.boardCount == 2 and created == base and #timers == 0 and writes == 0,
    "a hidden window must cost nothing on a new listing")
UI:Refresh()
UI:RequestRefresh()
assert(created == base and #timers == 0, "refresh of a hidden window did some work")

-- Instances: the window does not open.
Overlord.InstanceSuspended = true
UI:Show()
assert(not UI:IsShown() and #printed == 1 and created == base)
Overlord.InstanceSuspended = false

-- First opening builds the window once.
UI:Show()
local frame = framesByName.OverlordGroupFinderFrame
assert(frame and UI:IsShown(), "window not shown")
assert(opened == 1 and gridRefreshes == 1)
local list, card = frame.list, frame.card
assert(#list.rows == 10 and UI.rows == 7 and list.rows[1]:IsShown() and list.rows[2]:IsShown() and not list.rows[3]:IsShown())
assert(not list.emptyTitle:IsShown())
assert(frame.subtitle:GetText() == "Groups: 2 · Players: 17", frame.subtitle:GetText())
-- Joinable first: Bob's group, then Carl's full one.
local first, second = list.rows[1], list.rows[2]
assert(first.title:GetText() == "Attack · Stromgarde", first.title:GetText())
assert(first.leader:GetText() == "Bob Stone  level 60  ·  level 20+", first.leader:GetText())
assert(first.count:GetText() == "12/40" and first.button:IsShown() and not first.status:IsShown())
assert(second.title:GetText() == "Hunt · Anywhere" and second.count:GetText() == "5/5")
assert(second.button:IsShown() and second.button._alpha == 0.45, "a full group must grey its button")
-- The form starts on the front the player stands on.
assert(card.form:IsShown() and not card.live:IsShown())
assert(UI.form.kind == "f" and UI.form.target == "arathi")
assert(card.form.place.label:GetText() == "Arathi Highlands")

-- A refresh builds nothing and repaints nothing when nothing changed.
local builtOnce = created
writes = 0
UI:Refresh()
UI:Refresh()
assert(created == builtOnce, "a refresh created " .. (created - builtOnce) .. " widget(s)")
local idle = writes
assert(idle <= 12, "an idle refresh wrote " .. idle .. " texts")
-- A burst of listings costs one pass.
runTimers(10)
local pending = #timers
for i = 1, 30 do
    hear("L:1:A:d:z:stromgarde:40:" .. (i % 30 + 1) .. ":0:1:1:60:150", "Row" .. string.char(96 + i % 26 + 1) .. " Burst")
end
assert(#timers == pending + 1, "a burst queued " .. (#timers - pending) .. " refreshes")
runTimers(1)
assert(created == builtOnce, "rows are a fixed pool")
assert(list.rows[7]:IsShown() and list.page:GetText() == "1-7 / 28", list.page:GetText())
UI:Scroll(100)
assert(list.page:GetText() == "22-28 / 28", list.page:GetText())
UI:Scroll(-100)
assert(list.page:GetText() == "1-7 / 28")

-- Sign up from a row: one whisper, the row shows the answer.
for key in pairs(GF.board) do if key ~= "bob stone" and key ~= "carl reed" then GF:RemoveEntry(key) end end
UI:Refresh()
first = list.rows[1]
assert(first.entry.key == "bob stone")
first.button:GetScript("OnClick")(first.button)
assert(#sent == 1 and sent[1].chatType == "WHISPER" and sent[1].target == "Bob Stone"
    and sent[1].text == "J:1:A:a:z:stromgarde:1:60", "sign-up whisper")
assert(first.status:IsShown() and first.status:GetText() == "Sent…" and not first.button:IsShown())
GF:OnAddonMessage("R:1:p", "WHISPER", "Bob Stone")
runTimers(1)
assert(first.status:GetText() == "Waiting")
-- A full group: the click says why and sends nothing.
second = list.rows[2]
second.button:GetScript("OnClick")(second.button)
assert(#sent == 1 and printed[#printed]:find("full", 1, true), printed[#printed])
GF.apply = nil

-- Place menu: anywhere, each front with its points, outposts and keeps.
card.form.place:GetScript("OnClick")(card.form.place)
local menu = menus[#menus]
assert(menu.children[1].label == "Anywhere" and menu.children[2].label == "Arathi")
assert(menu.children[2].children[1].label == "Whole front" and menu.children[2].children[2].label == "Stromgarde")
assert(menu.children[3].label == "Outposts and keeps" and menu.children[3].children[1].label == "Stonetalon Keep")
menu.children[2].children[2].fn()
assert(UI.form.kind == "z" and UI.form.target == "stromgarde")
assert(card.form.place.label:GetText() == "Stromgarde (Arathi)", card.form.place.label:GetText())

-- Publish from the form: the card turns into the live listing, which heads the board.
card.form.intent.buttons[2]:GetScript("OnClick")(card.form.intent.buttons[2])
card.form.size.buttons[3]:GetScript("OnClick")(card.form.size.buttons[3])
card.form.level.buttons[2]:GetScript("OnClick")(card.form.level.buttons[2])
assert(UI.form.intent == "d" and UI.form.cap == 20 and UI.form.minLevel == 20)
card.form.publish:GetScript("OnClick")(card.form.publish)
local own = GF.own
assert(own and own.intent == "d" and own.kind == "z" and own.cap == 20 and own.minLevel == 20 and own.auto == false)
assert(card.live:IsShown() and not card.form:IsShown())
assert(card.live.title:GetText() == "Defend · Stromgarde")
assert(card.live.facts:GetText() == "1/20  ·  level 20+", card.live.facts:GetText())
assert(card.live.state:GetText() == "Publishing…  ·  leader approves", card.live.state:GetText())
assert(list.rows[1].entry.isOwn and list.rows[1].status:GetText() == "Your listing")
runTimers(1)
assert(sent[#sent].chatType == "CHANNEL" and sent[#sent].text:find("^L:1:A:d:z:stromgarde:20:1:20:0:1:60:"), sent[#sent].text)
assert(card.live.state:GetText() == "Listing online  ·  leader approves", card.live.state:GetText())

-- Requests: the grid button counts them, the card lists them, a click invites.
GF:OnAddonMessage("J:1:A:d:z:stromgarde:1:60", "WHISPER", "Dan Vale")
assert(gridButton.label:GetText() == "PvP Groups (1)", tostring(gridButton.label:GetText()))
runTimers(1)
local request = card.live.rows[1]
assert(request:IsShown() and request.name:GetText() == "Dan Vale  60" and not card.live.rows[2]:IsShown())
request.accept:GetScript("OnClick")(request.accept)
assert(invites[1] == "Dan Vale" and #GF.pending == 0)
assert(gridButton.label:GetText() == "PvP Groups", "badge not cleared")
assert(not card.live.rows[1]:IsShown())
GF:OnAddonMessage("J:1:A:d:z:stromgarde:1:60", "WHISPER", "Eve Hart")
runTimers(1)
card.live.rows[1].decline:GetScript("OnClick")(card.live.rows[1].decline)
assert(#invites == 1 and #GF.pending == 0 and sent[#sent].text == "R:1:d")

-- A party of five listed for more: the convert button shows, and converts.
group.size, group.leader = 5, true
UI:Refresh()
assert(card.live.convert:IsShown())
card.live.convert:GetScript("OnClick")(card.live.convert)
assert(group.raid)
UI:Refresh()
assert(not card.live.convert:IsShown())
group.size, group.raid, group.leader = 0, false, false

-- Withdraw: back to the form, with the last choices.
card.live.unlist:GetScript("OnClick")(card.live.unlist)
assert(GF.own == nil and card.form:IsShown() and not card.live:IsShown())
assert(UI.form.intent == "d" and UI.form.cap == 20)

-- Docking: against the leftmost Overlord panel, tops level, same height. It follows
-- the side panel opening and closing, goes to the right when the left has no room,
-- and stays where the player dragged it.
assert(frame._point[1] == "CENTER", "without the main panel the window opens in the centre")
local main, side = widget("Frame"), widget("Frame")
main.GetHeight = function() return 560 end
main.GetLeft = function() return 1200 end
side.GetLeft = function() return 900 end
OverlordFeaturedFrontDialog = side
Overlord.UI.GetMainFrame = function() return main end
UI:Hide()
UI:Show()
assert(frame._point[1] == "TOPRIGHT" and frame._point[2] == side and frame._point[3] == "TOPLEFT"
    and frame._point[4] == -8 and frame._point[5] == 0, "not docked against the side panel")
assert(frame._height == 560 and UI.rows == 8, "height " .. tostring(frame._height) .. ", rows " .. tostring(UI.rows))
side:Hide()
UI:OnPanelLayoutChanged()
assert(frame._point[2] == main and frame._point[1] == "TOPRIGHT", "not re-docked against the main panel")
main.GetHeight = function() return 380 end
UI:OnPanelLayoutChanged()
assert(frame._height == 486 and UI.rows == 7, "the window must keep its minimum height")
main.GetLeft = function() return 300 end
frame._dockKey = nil
UI:OnPanelLayoutChanged()
assert(frame._point[1] == "TOPLEFT" and frame._point[3] == "TOPRIGHT" and frame._point[4] == 8, "no room on the left: right side")
frame:GetScript("OnDragStart")(frame)
frame._point = "dragged"
side:Show()
UI:Hide()
UI:Show()
assert(frame._point == "dragged", "a window the player moved was docked again")
Overlord.UI.GetMainFrame, OverlordFeaturedFrontDialog, UI._userMoved = nil, nil, nil

-- The form at the shortest window: the help text of the automatic option is held
-- between the option and the Publish button with room for three lines (36 px), the
-- reason under the button has room for two, and no block runs into the next.
do
    local K = UI.LAYOUT
    local panelH = K.H_MIN - K.BODY_TOP - K.FOOT
    local helpRoom = (panelH - K.PUBLISH_Y - K.PUBLISH_H - K.FORM_HELP_GAP) + K.FORM_HELP
    assert(helpRoom >= 36, "room for the help text at the minimum height: " .. helpRoom)
    assert(K.PUBLISH_Y - K.REASON_Y >= 26, "no room for a two-line reason under the button")
    assert(K.FORM_PITCH >= 14 + 24 + 6, "a label and its buttons do not fit in one block")
    assert(K.FORM_TOP - 3 * K.FORM_PITCH - 14 - 24 >= K.FORM_AUTO, "the option overlaps the level buttons")
    assert(K.FORM_AUTO - 22 >= K.FORM_HELP, "the help text overlaps the option")
    local points = card.form.autoHelp._allPoints
    assert(#points == 2 and points[1][1] == "TOPLEFT" and points[1][5] == K.FORM_HELP
        and points[2][1] == "BOTTOMRIGHT" and points[2][2] == card.form.publish and points[2][3] == "TOPRIGHT",
        "the help text is not held above the button")
    assert(card.form.publish._point[5] == K.PUBLISH_Y and card.form.reason._point[5] == K.REASON_Y)
end

-- Tooltips: every hover handler runs and says something; a row hidden under the
-- mouse takes its highlight and its tooltip with it.
do
    UI:Refresh()
    local row = list.rows[1]
    assert(row:IsShown() and row.entry)
    row:GetScript("OnEnter")(row)
    assert(GameTooltip._owner == row and #GameTooltip._lines >= 4 and row.hover:IsShown())
    assert(GameTooltip:IsShown())
    row:Hide()
    assert(not row.hover:IsShown(), "a hidden row keeps its highlight")
    assert(not GameTooltip:IsShown(), "a hidden row keeps its tooltip")
    row:Show()
    -- Somebody else's tooltip is left alone.
    GameTooltip:SetOwner(card)
    GameTooltip:Show()
    row:Hide()
    assert(GameTooltip:IsShown(), "a hidden row closed a tooltip that is not its own")
    row:Show()
    row.button:GetScript("OnEnter")(row.button)
    assert(GameTooltip._owner == row.button and #GameTooltip._lines >= 1)
    card.form.auto:GetScript("OnEnter")(card.form.auto)
    assert(GameTooltip._owner == card.form.auto and #GameTooltip._lines == 2
        and GameTooltip._lines[2] == card.form.autoHelp:GetText(), "the option does not repeat its help on hover")
    local accept = card.live.rows[1].accept
    accept:GetScript("OnEnter")(accept)
    assert(GameTooltip._owner == accept and GameTooltip._lines[1] == "Invite")
    -- A row click asks for the waypoint of its place.
    local shown = {}
    local showOnMap = GF.ShowOnMap
    GF.ShowOnMap = function(_, info) shown[#shown + 1] = info end
    row:GetScript("OnClick")(row)
    GF.ShowOnMap = showOnMap
    assert(#shown == 1 and shown[1] == row.entry.info)
end

-- The panel's scale changes while the window is open: it follows at once.
UI:ApplyFrameScale(1.2)
assert(frame._scale == 1.2)
UI:ApplyFrameScale(1)

-- Without the game's menu helper, the place button walks through the places.
do
    local menuUtil = MenuUtil
    MenuUtil = nil
    local seen, count = {}, 0
    for _ = 1, 6 do
        card.form.place:GetScript("OnClick")(card.form.place)
        local id = UI.form.kind .. ":" .. UI.form.target
        if not seen[id] then seen[id], count = true, count + 1 end
        assert(GF:IsValidTarget(UI.form.kind, UI.form.target), "the fallback chose an unknown place: " .. id)
    end
    -- One front in this test: the whole front, then anywhere, and round again.
    assert(count == 2 and seen["f:arathi"] and seen["w:"], "the fallback does not walk through the places")
    MenuUtil = menuUtil
end

-- An empty board says what it waits for: the channel, then the listings, and only
-- then that nobody recruits. It looks again by itself, one timer at a time.
do
    for key in pairs(GF.board) do GF:RemoveEntry(key) end
    GF._listenUntil = nil
    channelId = nil
    runTimers(10)
    UI:Refresh()
    assert(list.emptyTitle:IsShown() and list.emptyTitle:GetText() == "Connecting…", tostring(list.emptyTitle:GetText()))
    assert(frame.subtitle:GetText() == "Connecting…" and not list.emptyBody:IsShown())
    -- While it connects and listens, the crest breathes (the search is running).
    assert(list.emptyPulse and list.emptyPulse:IsPlaying(), "the crest does not pulse while connecting")
    local armed = #timers
    UI:Refresh()
    UI:Refresh()
    assert(#timers == armed, "more than one channel timer armed")
    channelId = 5
    runTimers(6)
    runTimers(1)
    assert(list.emptyTitle:GetText() == "Listening for groups…", "the board did not look again once the channel was joined: " .. tostring(list.emptyTitle:GetText()))
    assert(not list.emptyBody:IsShown())
    assert(list.emptyPulse:IsPlaying(), "the crest does not pulse while listening")
    runTimers(92)
    runTimers(1)
    assert(list.emptyTitle:GetText() == "No group is recruiting right now." and list.emptyBody:IsShown(),
        "the board did not repaint when the listening time ended")
    assert(frame.subtitle:GetText() == "No group is recruiting")
    assert(not list.emptyPulse:IsPlaying(), "the crest still pulses once the search is over")
    -- Refused by the game: said on the board and on the leader's card, publishing refused.
    channelId, channelClosed = nil, true
    UI:Refresh()
    assert(list.emptyTitle:GetText() == "Group search unavailable for now" and not list.emptyBody:IsShown())
    card.form.publish:GetScript("OnClick")(card.form.publish)
    assert(GF.own == nil and card.form.reason:GetText() == "Group search unavailable for now", tostring(card.form.reason:GetText()))
    channelId, channelClosed = 5, false
    runTimers(6)
    runTimers(1)
    assert(list.emptyTitle:GetText() == "Listening for groups…", "closed stays written on a working channel: " .. tostring(list.emptyTitle:GetText()))
    -- With a listing on the board nothing of this shows, and no timer is kept running.
    runTimers(200)
    hear("L:1:A:a:z:stromgarde:40:12:20:1:1:60:150", "Bob Stone")
    runTimers(1)
    assert(not list.emptyTitle:IsShown() and frame.subtitle:GetText() == "Groups: 1 · Players: 12")
    local idleTimers = #timers
    UI:Refresh()
    assert(#timers == idleTimers, "a channel timer armed with groups on the board")
end

-- Closing: sound, grid state, and no refresh left behind.
closed = 0
hear("L:1:A:a:w::10:2:0:1:1:60:150", "Late News")
UI:Hide()
assert(not UI:IsShown() and closed == 1 and gridRefreshes >= 2)
local built = created
runTimers(5)
hear("L:1:A:a:w::10:3:0:1:1:60:150", "Other News")
runTimers(5)
assert(created == built, "work done while hidden")
UI:Toggle()
assert(UI:IsShown())
-- The instance cut-off closes it and empties everything.
IsInInstance = function() return true end
GF:OnInstanceSuspend()
assert(not UI:IsShown() and GF.boardCount == 0 and GF.own == nil)
assert(gridButton.label:GetText() == "PvP Groups")
IsInInstance = function() return false end

-- Decoration, with the atlases readable (the passes above ran without them, on the
-- plain fallback): each faction builds its own crown and band, and no column of the
-- other faction's half of the crown is drawn (the medallion's centre is column 264).
C_Texture = { GetAtlasInfo = function(name)
    local wide = name == "perks-theme-hordevsalliance-tp-topbig"
    return { file = wide and 6438383 or 2128641, width = wide and 527 or 512, height = wide and 108 or 512,
        leftTexCoord = 0, rightTexCoord = 1, topTexCoord = 0, bottomTexCoord = 1 }
end }
for _, faction in ipairs({ "Alliance", "Horde" }) do
    Overlord.PlayerFaction = faction
    Overlord.GroupFinderUI = nil
    framesByName.OverlordGroupFinderFrame = nil
    assert(loadfile("GroupFinderUI.lua"))()
    local ui = Overlord.GroupFinderUI
    ui:Show()
    local f = framesByName.OverlordGroupFinderFrame
    assert(ui:IsShown() and f and f.crown, faction .. ": window or crown missing")
    assert(#f.crown == (faction == "Alliance" and 12 or 6), faction .. ": " .. #f.crown .. " crown pieces")
    local mirrored = 0
    for _, tex in ipairs(f.crown) do
        local c = tex._coords
        assert(tex._texture == 6438383 and c, faction .. ": a crown piece has no texture")
        local low, high = math.min(c[1], c[2]) * 527, math.max(c[1], c[2]) * 527
        if faction == "Alliance" then
            assert(high <= 264.01, "Alliance crown reads column " .. high)
        else
            assert(low >= 263.99, "Horde crown reads column " .. low)
        end
        local leftToRight = c[1] < c[2]
        if leftToRight ~= (faction == "Alliance") then mirrored = mirrored + 1 end
    end
    assert(mirrored == #f.crown / 2, faction .. ": the crown is not one half and its mirror")
    assert(f.list.emptyTitle and f.subtitle, faction .. ": window incomplete")
    ui:Hide()
end

-- Hidden prebuild: 35 s after a loading screen the window is built hidden, one block
-- per frame; a click during the build finishes it at once; combat and instances wait.
local function loadWithDriver()
    Overlord.GroupFinderUI = nil
    framesByName.OverlordGroupFinderFrame = nil
    local made, realCreate = {}, CreateFrame
    CreateFrame = function(kind, name, ...)
        local f = realCreate(kind, name, ...)
        made[#made + 1] = f
        return f
    end
    assert(loadfile("GroupFinderUI.lua"))()
    CreateFrame = realCreate
    local driver
    for _, f in ipairs(made) do
        if f._scripts.OnEvent then driver = f end
    end
    assert(driver, "no prebuild driver registered at load")
    return Overlord.GroupFinderUI, driver
end
local function drainFrames(limit)
    local steps = 0
    while #timers > 0 and steps < limit do
        runTimers(0)
        steps = steps + 1
    end
    return steps
end
timers = {}
local ui, driver = loadWithDriver()
driver._scripts.OnEvent(driver, "PLAYER_ENTERING_WORLD")
runTimers(34)
assert(framesByName.OverlordGroupFinderFrame == nil, "prebuild started before its delay")
runTimers(1)
local hidden = framesByName.OverlordGroupFinderFrame
assert(hidden and not hidden:IsShown() and not ui:IsShown(), "prebuild did not start hidden")
local steps = drainFrames(20)
assert(steps >= 3 and #timers == 0, "the build was not spread over frames: " .. steps)
assert(hidden.list and hidden.card and not hidden:IsShown(), "prebuilt window incomplete or shown")
local before = created
ui:Show()
assert(ui:IsShown() and framesByName.OverlordGroupFinderFrame == hidden and created == before,
    "opening rebuilt a window that was already prebuilt")
ui:Hide()

-- A click in the middle of the build finishes it in the click, with one window only.
timers = {}
ui, driver = loadWithDriver()
driver._scripts.OnEvent(driver, "PLAYER_ENTERING_WORLD")
runTimers(35)
local partial = framesByName.OverlordGroupFinderFrame
assert(partial and not partial.card, "the first slice built more than one block")
ui:Show()
assert(ui:IsShown() and framesByName.OverlordGroupFinderFrame == partial and partial.card and partial.list.emptyTitle,
    "a click during the prebuild did not finish the same window")
drainFrames(20)
assert(framesByName.OverlordGroupFinderFrame == partial, "the prebuild built a second window")
ui:Hide()

-- Combat holds the build until the fight ends; an instance holds it too.
timers = {}
ui, driver = loadWithDriver()
InCombatLockdown = function() return true end
driver._scripts.OnEvent(driver, "PLAYER_ENTERING_WORLD")
runTimers(35)
assert(framesByName.OverlordGroupFinderFrame == nil, "built in combat")
InCombatLockdown = function() return false end
driver._scripts.OnEvent(driver, "PLAYER_REGEN_ENABLED")
runTimers(2)
drainFrames(20)
assert(framesByName.OverlordGroupFinderFrame and framesByName.OverlordGroupFinderFrame.card,
    "the build did not resume after combat")
timers = {}
ui, driver = loadWithDriver()
IsInInstance = function() return true end
driver._scripts.OnEvent(driver, "PLAYER_ENTERING_WORLD")
runTimers(35)
drainFrames(20)
assert(framesByName.OverlordGroupFinderFrame == nil, "built in an instance")
IsInInstance = function() return false end

print("forever_group_finder_ui: ok")
