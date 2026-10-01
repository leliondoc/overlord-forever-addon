-- Options page (1.3.5): Blizzard's native vertical layout instead of the custom
-- canvas, chat destination picked by tab NAME, and a button that creates an
-- "Overlord" chat tab. The Settings API is simulated; registration, the chat
-- dropdown entries and the tab creation run through the real SettingsPanel.lua.
local values, settings, dropdowns, inits, printed = {}, {}, {}, {}, {}
local windows = {
    [1] = { name = "General", shown = true, docked = true },
    [2] = { name = "Combat Log", shown = false, docked = true },
    [4] = { name = "Old Tab", shown = false, docked = false }, -- closed window
}
NUM_CHAT_WINDOWS = 10
function GetChatWindowInfo(i)
    local w = windows[i]
    if not w then return "", 14, 0, 0, 0, 0, false, false, nil end
    return w.name, 14, 0, 0, 0, 0, w.shown, false, w.docked
end
function FCF_OpenNewWindow(name)
    for i = 1, NUM_CHAT_WINDOWS do
        if not windows[i] or (not windows[i].shown and not windows[i].docked) then
            windows[i] = { name = name, shown = false, docked = true }
            return
        end
    end
end
function securecall(fn, ...) return fn(...) end
function hooksecurefunc(owner, method, hook)
    local original = owner[method]
    owner[method] = function(...) local r = original(...); hook(...); return r end
end
local title = { SetText = function(self, text) self.text = text end }
SettingsPanel = { Container = { SettingsList = { Header = { Title = title } } },
    HookScript = function() end,
    DisplayCategory = function(_, category) title:SetText(category.name) end }
C_Timer = { After = function() end }
local function container()
    local c = { data = {} }
    function c:Add(value, label) self.data[#self.data + 1] = { value = value, label = label } end
    function c:GetData() return self.data end
    return c
end
local layout = { AddInitializer = function(_, init) inits[#inits + 1] = init end }
Settings = {
    RegisterVerticalLayoutCategory = function(name) return { name = name }, layout end,
    RegisterProxySetting = function(_, var, kind, label, default, get, set)
        local s = { var = var, kind = kind, label = label, default = default, get = get, set = set }
        settings[var] = s
        return s
    end,
    CreateCheckbox = function(_, s) s.control = "checkbox" end,
    CreateSlider = function(_, s) s.control = "slider" end,
    CreateSliderOptions = function() return {} end,
    CreateDropdown = function(_, s, options) s.control = "dropdown"; dropdowns[s.var] = options end,
    CreateControlTextContainer = container,
    RegisterAddOnCategory = function() end,
    -- Like Blizzard's proxy settings: SetValue calls the registered setter back.
    SetValue = function(var, value)
        values[var] = value
        if settings[var] then settings[var].set(value) end
    end,
}
function CreateSettingsListSectionHeaderInitializer(name) return { header = name } end
function CreateSettingsButtonInitializer(name, button, click) return { button = button, name = name, click = click } end

local scaleApplied = 0
Overlord = { UI = { ApplyUiScale = function() scaleApplied = scaleApplied + 1 end },
    L = {}, PrintNotification = function(_, text) printed[#printed + 1] = text end,
    GuildKillAlert = { enabled = true,
        IsEnabled = function(self) return self.enabled end,
        SetEnabled = function(self, v) self.enabled = v end } }
OverlordDB = { config = {} }
assert(loadfile("SettingsPanel.lua"))()
local SP = Overlord.SettingsPanel
SP:Register()
assert(SP._registered, "Native options page was not registered")

-- 1. Every option has a native control; sections and buttons are present.
local expected = { "Overlord_UiScale", "Overlord_NotificationChat", "Overlord_GuildKillAlert",
    "Overlord_MapOverlayOpacity", "Overlord_MapIconOpacity", "Overlord_MapPathOpacity",
    "Overlord_MinimapOverlayOpacity", "Overlord_ShowMinimapButton", "Overlord_ShowMinimapCaptureZones",
    "Overlord_ShowMapZoneTitles", "Overlord_AutoWaypointNextObjective", "Overlord_TopHudMode",
    "Overlord_ShowCoinsHud", "Overlord_ShowFloatingObjective", "Overlord_ShowTutorialBook",
    "Overlord_SoundEnabled" }
for _, var in ipairs(expected) do
    assert(settings[var] and settings[var].control, "Missing native control: " .. var)
end
local headers, buttons = 0, {}
for _, init in ipairs(inits) do
    if init.header then headers = headers + 1 end
    if init.button then buttons[#buttons + 1] = init end
end
assert(headers == 4 and #buttons == 2, "Sections or buttons missing")

-- 2. The chat destination lists tabs by name, never a closed window.
local options = dropdowns["Overlord_NotificationChat"]()
local labels = {}
for _, o in ipairs(options) do labels[#labels + 1] = o.value .. "=" .. o.label end
assert(table.concat(labels, ",") == "0=Main chat (default),1=General,2=Combat Log",
    "Unexpected chat entries: " .. table.concat(labels, ","))

-- 3. "Create tab" opens an Overlord tab and routes messages there; a second click reuses it.
local createTab
for _, b in ipairs(buttons) do if b.name == "Overlord chat tab" then createTab = b.click end end
assert(createTab, "Chat tab button missing")
createTab()
assert(windows[3] and windows[3].name == "Overlord", "Overlord tab was not created")
assert(OverlordDB.config.notificationChatFrame == 3, "Messages were not routed to the new tab")
assert(values["Overlord_NotificationChat"] == 3, "Dropdown not refreshed after creating the tab")
createTab()
local count = 0
for _, w in pairs(windows) do if w.name == "Overlord" then count = count + 1 end end
assert(count == 1, "A second click created another Overlord tab")

-- 4. Guild raid alerts are now a native checkbox wired to GuildKillAlert.
settings["Overlord_GuildKillAlert"].set(false)
assert(Overlord.GuildKillAlert.enabled == false)
SP:RefreshControls()
assert(values["Overlord_GuildKillAlert"] == false, "RefreshControls did not push the alert state")
-- 5. Our page title carries the Overlord logo; other categories are untouched.
SettingsPanel:DisplayCategory(SP._category)
assert(title.text:find("overlord:22:22", 1, true) and title.text:find("Overlord$"), "Logo missing: " .. tostring(title.text))
SettingsPanel:DisplayCategory({ name = "BugSack" })
assert(title.text == "BugSack", "Logo leaked onto another addon page")

-- 6. A click runs the setter (and its side effect) once: the setter's own
--    Settings.SetValue notification must not call it back in a loop.
settings["Overlord_UiScale"].set(1.1)
assert(scaleApplied == 1, "Setter re-entered through Settings.SetValue: " .. scaleApplied)
assert(OverlordDB.config.uiScale == 1.1 and values["Overlord_UiScale"] == 1.1)

print("Settings panel: native layout, chat tab by name, Overlord tab creation OK")
