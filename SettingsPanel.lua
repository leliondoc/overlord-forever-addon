-- SettingsPanel.lua - Esc > Options > AddOns > Overlord (Blizzard native vertical layout)
Overlord = Overlord or {}
Overlord.SettingsPanel = {}

local L = Overlord.L


local UI_SCALE_MIN = 0.8
local UI_SCALE_MAX = 1.2
local UI_SCALE_STEP = 0.1
local DEFAULT_SCALE = 1.0

Overlord.SettingsPanel.UiScaleVariableName = "Overlord_UiScale"
Overlord.SettingsPanel.NotificationChatVariableName = "Overlord_NotificationChat"
Overlord.SettingsPanel.MapOverlayOpacityVariableName = "Overlord_MapOverlayOpacity"
Overlord.SettingsPanel.MinimapOverlayOpacityVariableName = "Overlord_MinimapOverlayOpacity"
Overlord.SettingsPanel.MapPathOpacityVariableName = "Overlord_MapPathOpacity"
Overlord.SettingsPanel.AutoWaypointVariableName = "Overlord_AutoWaypointNextObjective"
Overlord.SettingsPanel.ShowMinimapButtonVariableName = "Overlord_ShowMinimapButton"
Overlord.SettingsPanel.ShowMinimapCaptureZonesVariableName = "Overlord_ShowMinimapCaptureZones"
Overlord.SettingsPanel.ShowCoinsHudVariableName = "Overlord_ShowCoinsHud"
Overlord.SettingsPanel.ShowFloatingObjectiveVariableName = "Overlord_ShowFloatingObjective"
Overlord.SettingsPanel.SoundEnabledVariableName = "Overlord_SoundEnabled"
Overlord.SettingsPanel.MapIconOpacityVariableName = "Overlord_MapIconOpacity"
Overlord.SettingsPanel.MapIconScaleVariableName = "Overlord_MapIconScale"

local NOTIF_CHAT_MIN = 0
local DEFAULT_NOTIF_CHAT = 0

local MAP_OVERLAY_OPACITY_MIN = 0.2
local MAP_OVERLAY_OPACITY_MAX = 1.0
local MAP_OVERLAY_OPACITY_STEP = 0.1
local DEFAULT_MAP_OVERLAY_OPACITY = 1.0
local DEFAULT_MINIMAP_OVERLAY_OPACITY = 0.2

local MAP_PATH_OPACITY_MIN = 1.0
local MAP_PATH_OPACITY_MAX = 3.0
local MAP_PATH_OPACITY_STEP = 0.25
local DEFAULT_MAP_PATH_OPACITY = 1.0
local DEFAULT_AUTO_WAYPOINT = true
local DEFAULT_SHOW_MINIMAP_BUTTON = true
local DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES = true
local DEFAULT_SHOW_COINS_HUD = false
local DEFAULT_SOUND_ENABLED = true
-- Icones des points de capture sur la carte du monde : a 100 % elles masquaient
-- les points d'exclamation de quete dans les villes.
local DEFAULT_MAP_ICON_OPACITY = 0.5

local function scheduleActionGridActiveRefresh()
    local ui = Overlord.UI
    if ui and ui.ScheduleActionGridActiveRefresh then
        ui:ScheduleActionGridActiveRefresh()
    end
end

local settingsSuppressSideEffects = false
local minimapOpacityRefreshPending = false
local mapOpacityRefreshPending = false

local function requestMinimapOpacityRefresh()
    if minimapOpacityRefreshPending then return end
    minimapOpacityRefreshPending = true
    C_Timer.After(0.15, function()
        minimapOpacityRefreshPending = false
        if Overlord.MapMarkers and Overlord.MapMarkers.RefreshMinimapOverlayOpacity then
            Overlord.MapMarkers:RefreshMinimapOverlayOpacity()
        end
    end)
end

-- Coalesce les +/- opacite carte/chemins (evite N rebuilds overlays).
local mapOpacityContentOnly = true
local function requestMapOpacityRefresh(contentOnly)
    if contentOnly == false then
        mapOpacityContentOnly = false
    end
    if mapOpacityRefreshPending then return end
    mapOpacityRefreshPending = true
    C_Timer.After(0.15, function()
        mapOpacityRefreshPending = false
        local onlyContent = mapOpacityContentOnly
        mapOpacityContentOnly = true
        if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
            Overlord.MapMarkers:RequestOverlayRefresh(onlyContent)
        end
    end)
end


local function clampScale(v)
    v = tonumber(v) or DEFAULT_SCALE
    if v < UI_SCALE_MIN then v = UI_SCALE_MIN end
    if v > UI_SCALE_MAX then v = UI_SCALE_MAX end
    return math.floor(v * 10 + 0.5) / 10
end

local function formatScaleLabel(value)
    -- En pourcentage, comme la taille des icones de la carte.
    local v = clampScale(tonumber(value) or DEFAULT_SCALE)
    return string.format("%d%%", math.floor(v * 100 + 0.5))
end

local function maxChatWindows()
    local n = NUM_CHAT_WINDOWS
    if type(n) == "number" and n > 0 then return n end
    return 10
end

local function clampNotificationChat(v)
    v = math.floor(tonumber(v) or DEFAULT_NOTIF_CHAT)
    local hi = maxChatWindows()
    if v < NOTIF_CHAT_MIN then v = NOTIF_CHAT_MIN end
    if v > hi then v = hi end
    return v
end

local function clampMapOverlayOpacity(v)
    v = tonumber(v) or DEFAULT_MAP_OVERLAY_OPACITY
    if v < MAP_OVERLAY_OPACITY_MIN then v = MAP_OVERLAY_OPACITY_MIN end
    if v > MAP_OVERLAY_OPACITY_MAX then v = MAP_OVERLAY_OPACITY_MAX end
    return math.floor(v * 10 + 0.5) / 10
end

local function formatMapOverlayOpacityLabel(value)
    local v = clampMapOverlayOpacity(value)
    return string.format("%d%%", math.floor(v * 100 + 0.5))
end

local function clampMapPathOpacity(v)
    v = tonumber(v) or DEFAULT_MAP_PATH_OPACITY
    if v < MAP_PATH_OPACITY_MIN then v = MAP_PATH_OPACITY_MIN end
    if v > MAP_PATH_OPACITY_MAX then v = MAP_PATH_OPACITY_MAX end
    return math.floor(v * 100 + 0.5) / 100
end

local function formatMapPathOpacityLabel(value)
    local v = clampMapPathOpacity(value)
    if v == math.floor(v) then
        return string.format("%.0f×", v)
    end
    return string.format("%.2g×", v)
end

-- Pushes a value into the Settings control. Blizzard's proxy SetValue calls the
-- registered setter again; while notifying, that call is ignored (see addRow),
-- otherwise every click re-ran the setter and its side effects in a loop.
local settingsNotifying = false
local function notifySettingsAPI(varName, value)
    if not Settings or settingsNotifying then return end
    settingsNotifying = true
    if Settings.SetValue then
        pcall(Settings.SetValue, varName, value, true)
    elseif Settings.NotifyUpdate then
        pcall(Settings.NotifyUpdate, varName)
    end
    settingsNotifying = false
end

local function getScale()
    return clampScale(OverlordDB and OverlordDB.config and OverlordDB.config.uiScale)
end

local function setScale(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.uiScale = clampScale(value)
    if Overlord.UI and Overlord.UI.ApplyUiScale then
        Overlord.UI:ApplyUiScale()
    end
    notifySettingsAPI(Overlord.SettingsPanel.UiScaleVariableName, OverlordDB.config.uiScale)
end

local function getNotificationChat()
    return clampNotificationChat(OverlordDB and OverlordDB.config and OverlordDB.config.notificationChatFrame)
end

local function setNotificationChat(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.notificationChatFrame = clampNotificationChat(value)
    notifySettingsAPI(Overlord.SettingsPanel.NotificationChatVariableName, OverlordDB.config.notificationChatFrame)
end

local function getMapOverlayOpacity()
    return clampMapOverlayOpacity(OverlordDB and OverlordDB.config and OverlordDB.config.mapOverlayOpacity)
end

local function setMapOverlayOpacity(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.mapOverlayOpacity = clampMapOverlayOpacity(value)
    if not settingsSuppressSideEffects then
        requestMapOpacityRefresh(true)
    end
    notifySettingsAPI(Overlord.SettingsPanel.MapOverlayOpacityVariableName, OverlordDB.config.mapOverlayOpacity)
end

local function getMinimapOverlayOpacity()
    return clampMapOverlayOpacity(OverlordDB and OverlordDB.config and OverlordDB.config.minimapOverlayOpacity)
end

local function setMinimapOverlayOpacity(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.minimapOverlayOpacity = clampMapOverlayOpacity(value)
    if not settingsSuppressSideEffects then
        requestMinimapOpacityRefresh()
    end
    notifySettingsAPI(Overlord.SettingsPanel.MinimapOverlayOpacityVariableName, OverlordDB.config.minimapOverlayOpacity)
end

-- 0 = icones masquees ; sinon 10 a 100 % par pas de 10 %.
local function clampMapIconOpacity(v)
    v = tonumber(v) or DEFAULT_MAP_ICON_OPACITY
    if v < 0 then v = 0 end
    if v > MAP_OVERLAY_OPACITY_MAX then v = MAP_OVERLAY_OPACITY_MAX end
    return math.floor(v * 10 + 0.5) / 10
end

local function formatMapIconOpacityLabel(value)
    local v = clampMapIconOpacity(value)
    if v <= 0 then return (L and L.SETTINGS_TOGGLE_OFF) or "Disabled" end
    return formatMapOverlayOpacityLabel(v)
end

local function getMapIconOpacity()
    local cfg = OverlordDB and OverlordDB.config
    local v = cfg and cfg.mapIconOpacity
    if v == nil then v = DEFAULT_MAP_ICON_OPACITY end
    return clampMapIconOpacity(v)
end

local function setMapIconOpacity(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.mapIconOpacity = clampMapIconOpacity(value)
    if not settingsSuppressSideEffects then
        requestMapOpacityRefresh(true)
    end
    notifySettingsAPI(Overlord.SettingsPanel.MapIconOpacityVariableName, OverlordDB.config.mapIconOpacity)
end

-- Taille des icones de carte : 50 a 150 % par pas de 10 %.
local function getMapIconScale()
    local v = tonumber(OverlordDB and OverlordDB.config and OverlordDB.config.mapIconScale) or 1
    v = math.floor(v * 10 + 0.5) / 10
    if v < 0.5 then v = 0.5 elseif v > 1.5 then v = 1.5 end
    return v
end

local function setMapIconScale(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    local v = math.floor((tonumber(value) or 1) * 10 + 0.5) / 10
    if v < 0.5 then v = 0.5 elseif v > 1.5 then v = 1.5 end
    OverlordDB.config.mapIconScale = v
    if not settingsSuppressSideEffects then
        requestMapOpacityRefresh(false)
    end
    notifySettingsAPI(Overlord.SettingsPanel.MapIconScaleVariableName, v)
end

local function getMapPathOpacity()
    return clampMapPathOpacity(OverlordDB and OverlordDB.config and OverlordDB.config.mapPathOpacity)
end

local function setMapPathOpacity(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.mapPathOpacity = clampMapPathOpacity(value)
    if not settingsSuppressSideEffects then
        -- Chemins : contenu seul suffit (pas de ResetMapLayoutKey).
        requestMapOpacityRefresh(true)
    end
    notifySettingsAPI(Overlord.SettingsPanel.MapPathOpacityVariableName, OverlordDB.config.mapPathOpacity)
end

local function getAutoWaypoint()
    return OverlordDB and OverlordDB.config
        and OverlordDB.config.autoWaypointNextObjective == true
end

local function setAutoWaypoint(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.autoWaypointNextObjective = value == true
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.OnAutoWaypointSettingChanged then
        Overlord.ZoneIndicator:OnAutoWaypointSettingChanged(OverlordDB.config.autoWaypointNextObjective)
    end
    notifySettingsAPI(Overlord.SettingsPanel.AutoWaypointVariableName, OverlordDB.config.autoWaypointNextObjective)
end

local function getShowMinimapCaptureZones()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showMinimapCaptureZones == false then
        return false
    end
    return true
end

local function getShowMinimapButton()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showMinimapButton == false then
        return false
    end
    return true
end

local function setShowMinimapButton(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showMinimapButton = value == true
    if not settingsSuppressSideEffects and Overlord.MapMarkers
        and Overlord.MapMarkers.RefreshMinimapButtonVisibility then
        Overlord.MapMarkers:RefreshMinimapButtonVisibility()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowMinimapButtonVariableName,
        OverlordDB.config.showMinimapButton)
end

local function setShowMinimapCaptureZones(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showMinimapCaptureZones = value == true
    if not settingsSuppressSideEffects and Overlord.MapMarkers and Overlord.MapMarkers.RefreshMinimapCaptureZonesVisibility then
        Overlord.MapMarkers:RefreshMinimapCaptureZonesVisibility()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowMinimapCaptureZonesVariableName, OverlordDB.config.showMinimapCaptureZones)
end

-- Menu « Suivi » de la minicarte (MapMarkers).
function Overlord.SettingsPanel:SetShowMinimapCaptureZones(value)
    setShowMinimapCaptureZones(value)
end

local function getShowCoinsHud()
    return OverlordDB and OverlordDB.config and OverlordDB.config.showCoinsHud == true or false
end

local function setShowCoinsHud(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showCoinsHud = value == true
    if not settingsSuppressSideEffects and Overlord.Ressources and Overlord.Ressources.OnShowTopHudSettingChanged then
        Overlord.Ressources:OnShowTopHudSettingChanged()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowCoinsHudVariableName, OverlordDB.config.showCoinsHud)
end

Overlord.SettingsPanel.GetShowCoinsHud = getShowCoinsHud
Overlord.SettingsPanel.SetShowCoinsHud = setShowCoinsHud

-- Fenetre flottante « Prochain objectif » (desactivee par defaut). Accesseurs
-- exposes par champs : les fonctions d'enregistrement sont a la limite d'upvalues.
function Overlord.SettingsPanel.GetShowFloatingObjective()
    return OverlordDB and OverlordDB.config and OverlordDB.config.showFloatingObjective == true or false
end

function Overlord.SettingsPanel.SetShowFloatingObjective(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showFloatingObjective = value == true
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RefreshHud then
        pcall(Overlord.ZoneIndicator.RefreshHud, Overlord.ZoneIndicator)
    end
    if Settings and Settings.GetSetting then
        local setting = Settings.GetSetting(Overlord.SettingsPanel.ShowFloatingObjectiveVariableName)
        if setting and setting.GetValue and setting:GetValue() ~= OverlordDB.config.showFloatingObjective
            and setting.SetValue then
            pcall(setting.SetValue, setting, OverlordDB.config.showFloatingObjective)
        end
    end
end

local function getSoundEnabled()
    if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled == false then
        return false
    end
    return true
end

local function stopActiveOverlordSounds()
    if Overlord.StopGeneralDuelMusic then
        Overlord:StopGeneralDuelMusic()
    end
    if Overlord.GeneralNameplate and Overlord.GeneralNameplate.StopDuelMusic then
        Overlord.GeneralNameplate:StopDuelMusic()
    end
end

local function setSoundEnabled(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.soundEnabled = value == true
    if not value then
        stopActiveOverlordSounds()
    end
    notifySettingsAPI(Overlord.SettingsPanel.SoundEnabledVariableName, OverlordDB.config.soundEnabled)
end

-- ==================== Native options page ====================
-- Esc > Options > AddOns > Overlord uses Blizzard's own vertical layout, like most
-- addons: checkboxes, sliders and dropdowns drawn by the game, one short tooltip
-- on hover, Blizzard's "Defaults" button. Rows are declared as data so no single
-- function approaches Lua 5.1's 60-upvalue limit.

local SP = Overlord.SettingsPanel
SP.GuildKillAlertVariableName = "Overlord_GuildKillAlert"
SP.GuildKillAllyAlertVariableName = "Overlord_GuildKillAllyAlert"
SP.MostWantedAlertsVariableName = "Overlord_MostWantedAlerts"
SP.WorldMapModeVariableName = "Overlord_WorldMapMode"
local CHAT_TAB_NAME = "Overlord"
local SETTINGS_TITLE_LOGO = "|TInterface\\AddOns\\Overlord\\Textures\\overlord:22:22:0:2|t"

local function Lx(key, fallback)
    return (L and L[key]) or fallback
end

-- A chat window the player can see: a docked tab or a shown floating window.
local function chatWindowInUse(index)
    if type(GetChatWindowInfo) ~= "function" then return false end
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(index)
    return name ~= nil and name ~= "" and (shown or docked) and true or false
end

local function findChatTab(name)
    for i = 1, maxChatWindows() do
        if chatWindowInUse(i) and GetChatWindowInfo(i) == name then return i end
    end
    return nil
end

-- Dropdown entries: the main chat, then every visible tab by its own name.
local function chatWindowOptions()
    local container = Settings.CreateControlTextContainer()
    container:Add(0, Lx("NOTIFICATION_CHAT_DEFAULT", "Main chat (default)"))
    local current = getNotificationChat()
    for i = 1, maxChatWindows() do
        if chatWindowInUse(i) or i == current then
            local name = type(GetChatWindowInfo) == "function" and GetChatWindowInfo(i) or nil
            container:Add(i, (name and name ~= "") and name or tostring(i))
        end
    end
    return container:GetData()
end

-- Opens (or reuses) a chat tab named "Overlord" and routes Overlord messages there.
-- The player then moves, hides or closes it like any other chat tab.
function SP:CreateOverlordChatTab()
    local index = findChatTab(CHAT_TAB_NAME)
    if not index and type(FCF_OpenNewWindow) == "function" then
        pcall(FCF_OpenNewWindow, CHAT_TAB_NAME, true)
        index = findChatTab(CHAT_TAB_NAME)
    end
    if not index then
        Overlord:PrintNotification("|cFFFF4444[Overlord]|r "
            .. Lx("CHAT_TAB_FAILED", "No free chat tab. Close one, then try again."))
        return false
    end
    setNotificationChat(index)
    Overlord:PrintNotification("|cFFFFD100[Overlord]|r "
        .. Lx("CHAT_TAB_READY", "Overlord messages now appear in this tab."))
    return true
end

local function getGuildKillAlert()
    local gka = Overlord.GuildKillAlert
    return gka and gka.IsEnabled and gka:IsEnabled() or false
end

local function setGuildKillAlert(value)
    local gka = Overlord.GuildKillAlert
    if gka and gka.SetEnabled then gka:SetEnabled(value == true) end
end

local function getMostWantedAlerts()
    local mw = Overlord.MostWanted
    return mw and mw.AlertsEnabled and mw:AlertsEnabled() or false
end

local function setMostWantedAlerts(value)
    local mw = Overlord.MostWanted
    if mw and mw.SetAlertsEnabled then
        mw:SetAlertsEnabled(value == true)
        if mw.RefreshPlates then pcall(mw.RefreshPlates, mw) end
    end
end

-- Carte du monde : complet, compact (noms au survol) ou masque (MapMarkers).
local function getWorldMapMode()
    local mm = Overlord.MapMarkers
    return mm and mm.GetWorldMapDisplayMode and mm:GetWorldMapDisplayMode() or "full"
end

local function setWorldMapMode(value)
    local mm = Overlord.MapMarkers
    if mm and mm.SetWorldMapDisplayMode then mm:SetWorldMapDisplayMode(value) end
end

local function getGuildKillAllyAlert()
    local gka = Overlord.GuildKillAlert
    return gka and gka.IsAllyEnabled and gka:IsAllyEnabled() or false
end

local function setGuildKillAllyAlert(value)
    local gka = Overlord.GuildKillAlert
    if gka and gka.SetAllyEnabled then gka:SetAllyEnabled(value == true) end
end

local function sliderOptions(minValue, maxValue, step, formatter)
    local options = Settings.CreateSliderOptions(minValue, maxValue, step)
    local labels = MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label
    if options and options.SetLabelFormatter and labels and formatter then
        pcall(options.SetLabelFormatter, options, labels.Right, formatter)
    end
    return options
end

-- kind: "header" | "button" | "checkbox" | "slider" | "dropdown".
local ROWS = {
    { kind = "header", label = "SETTINGS_SECTION_GENERAL", fallback = "General" },
    { kind = "button", label = "ACTION_SHORTCUT_LABEL", fallback = "Action bar shortcut",
        button = "ACTION_SHORTCUT_BUTTON", buttonFallback = "Pick up",
        tooltip = "ACTION_SHORTCUT_TOOLTIP",
        click = function()
            if Overlord.ActionShortcut and Overlord.ActionShortcut.Pickup then
                Overlord.ActionShortcut:Pickup()
            end
        end },
    { kind = "slider", var = SP.UiScaleVariableName, label = "UI_SCALE_LABEL", fallback = "Panel scale",
        tooltip = "UI_SCALE_TOOLTIP", default = DEFAULT_SCALE, get = getScale, set = setScale,
        min = UI_SCALE_MIN, max = UI_SCALE_MAX, step = UI_SCALE_STEP, format = formatScaleLabel },
    { kind = "checkbox", var = SP.SoundEnabledVariableName, label = "SOUND_ENABLED_LABEL",
        fallback = "Overlord sounds", tooltip = "SOUND_ENABLED_TOOLTIP",
        default = DEFAULT_SOUND_ENABLED, get = getSoundEnabled, set = setSoundEnabled },

    { kind = "header", label = "SETTINGS_SECTION_CHAT", fallback = "Chat" },
    { kind = "dropdown", var = SP.NotificationChatVariableName, label = "NOTIFICATION_CHAT_LABEL",
        fallback = "Overlord messages", tooltip = "NOTIFICATION_CHAT_TOOLTIP",
        default = DEFAULT_NOTIF_CHAT, get = getNotificationChat, set = setNotificationChat,
        options = chatWindowOptions },
    { kind = "button", label = "CHAT_TAB_LABEL", fallback = "Overlord chat tab",
        button = "CHAT_TAB_BUTTON", buttonFallback = "Create tab", tooltip = "CHAT_TAB_TOOLTIP",
        -- Next frame, outside Blizzard's Settings click path: FCF chat-frame code
        -- run from that path is the usual chat taint source.
        click = function()
            if C_Timer and C_Timer.After then
                C_Timer.After(0, function() SP:CreateOverlordChatTab() end)
            else
                SP:CreateOverlordChatTab()
            end
        end },
    { kind = "checkbox", var = SP.GuildKillAlertVariableName, label = "GUILD_KILL_ALERT_ENABLED_LABEL",
        fallback = "Enemy guild raid alerts", tooltip = "GUILD_KILL_ALERT_ENABLED_TOOLTIP",
        default = true, get = getGuildKillAlert, set = setGuildKillAlert },
    { kind = "checkbox", var = SP.GuildKillAllyAlertVariableName, label = "GUILD_KILL_ALLY_ENABLED_LABEL",
        fallback = "Allied guild rampages", tooltip = "GUILD_KILL_ALLY_ENABLED_TOOLTIP",
        default = true, get = getGuildKillAllyAlert, set = setGuildKillAllyAlert },
    { kind = "checkbox", var = SP.MostWantedAlertsVariableName, label = "MW_ALERTS_LABEL",
        fallback = "Most Wanted alerts", tooltip = "MW_ALERTS_TOOLTIP",
        default = true, get = getMostWantedAlerts, set = setMostWantedAlerts },
    { kind = "checkbox", var = "Overlord_KillChatLine", label = "KILL_CHAT_LABEL",
        fallback = "Chat line on each honorable kill", tooltip = "KILL_CHAT_TOOLTIP",
        default = false,
        get = function()
            local cfg = OverlordDB and OverlordDB.config
            return cfg ~= nil and cfg.killChatLine == true
        end,
        set = function(value)
            if not OverlordDB then return end
            OverlordDB.config = OverlordDB.config or {}
            OverlordDB.config.killChatLine = value == true
        end },

    { kind = "header", label = "SETTINGS_SECTION_MAP", fallback = "Map and minimap" },
    { kind = "dropdown", var = SP.WorldMapModeVariableName, label = "MAP_WORLD_OVERLAYS_LABEL",
        fallback = "Overlord on the world map", tooltip = "MAP_MODE_TOOLTIP",
        default = "full", get = getWorldMapMode, set = setWorldMapMode,
        choices = { { "full", "MAP_MODE_FULL", "Full" }, { "compact", "MAP_MODE_COMPACT", "Compact" },
            { "hidden", "MAP_MODE_HIDDEN", "Hidden" } } },
    { kind = "slider", var = SP.MapOverlayOpacityVariableName, label = "MAP_OVERLAY_OPACITY_LABEL",
        fallback = "Map capture opacity", tooltip = "MAP_OVERLAY_OPACITY_TOOLTIP",
        default = DEFAULT_MAP_OVERLAY_OPACITY, get = getMapOverlayOpacity, set = setMapOverlayOpacity,
        min = MAP_OVERLAY_OPACITY_MIN, max = MAP_OVERLAY_OPACITY_MAX, step = MAP_OVERLAY_OPACITY_STEP,
        format = formatMapOverlayOpacityLabel },
    { kind = "slider", var = SP.MapIconOpacityVariableName, label = "MAP_ICON_OPACITY_LABEL",
        fallback = "Map icon opacity", tooltip = "MAP_ICON_OPACITY_TOOLTIP",
        default = DEFAULT_MAP_ICON_OPACITY, get = getMapIconOpacity, set = setMapIconOpacity,
        min = 0, max = MAP_OVERLAY_OPACITY_MAX, step = MAP_OVERLAY_OPACITY_STEP,
        format = formatMapIconOpacityLabel },
    { kind = "slider", var = SP.MapIconScaleVariableName, label = "MAP_ICON_SCALE_LABEL",
        fallback = "Map icon size", tooltip = "MAP_ICON_SCALE_TOOLTIP",
        default = 1, get = getMapIconScale, set = setMapIconScale,
        min = 0.5, max = 1.5, step = 0.1,
        format = function(v) return string.format("%d%%", math.floor((tonumber(v) or 1) * 100 + 0.5)) end },
    { kind = "slider", var = SP.MapPathOpacityVariableName, label = "MAP_PATH_OPACITY_LABEL",
        fallback = "Map path opacity", tooltip = "MAP_PATH_OPACITY_TOOLTIP",
        default = DEFAULT_MAP_PATH_OPACITY, get = getMapPathOpacity, set = setMapPathOpacity,
        min = MAP_PATH_OPACITY_MIN, max = MAP_PATH_OPACITY_MAX, step = MAP_PATH_OPACITY_STEP,
        format = formatMapPathOpacityLabel },
    { kind = "checkbox", var = SP.AutoWaypointVariableName, label = "AUTO_WAYPOINT_LABEL",
        fallback = "Auto-pin next objective", tooltip = "AUTO_WAYPOINT_TOOLTIP",
        default = DEFAULT_AUTO_WAYPOINT, get = getAutoWaypoint, set = setAutoWaypoint },
    { kind = "slider", var = SP.MinimapOverlayOpacityVariableName, label = "MINIMAP_OVERLAY_OPACITY_LABEL",
        fallback = "Minimap capture opacity", tooltip = "MINIMAP_OVERLAY_OPACITY_TOOLTIP",
        default = DEFAULT_MINIMAP_OVERLAY_OPACITY, get = getMinimapOverlayOpacity,
        set = setMinimapOverlayOpacity, min = MAP_OVERLAY_OPACITY_MIN, max = MAP_OVERLAY_OPACITY_MAX,
        step = MAP_OVERLAY_OPACITY_STEP, format = formatMapOverlayOpacityLabel },
    { kind = "checkbox", var = SP.ShowMinimapCaptureZonesVariableName, label = "MINIMAP_CAPTURE_ZONES_LABEL",
        fallback = "Minimap icons", tooltip = "MINIMAP_CAPTURE_ZONES_TOOLTIP",
        default = DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES, get = getShowMinimapCaptureZones,
        set = setShowMinimapCaptureZones },
    { kind = "checkbox", var = SP.ShowMinimapButtonVariableName, label = "MINIMAP_BUTTON_LABEL",
        fallback = "Minimap button", tooltip = "MINIMAP_BUTTON_TOOLTIP",
        default = DEFAULT_SHOW_MINIMAP_BUTTON, get = getShowMinimapButton, set = setShowMinimapButton },

    { kind = "header", label = "SETTINGS_SECTION_HUD", fallback = "On-screen panels" },
    { kind = "checkbox", var = SP.ShowCoinsHudVariableName, label = "COINS_HUD_LABEL",
        fallback = "Coins panel", tooltip = "COINS_HUD_TOOLTIP",
        default = DEFAULT_SHOW_COINS_HUD, get = getShowCoinsHud, set = setShowCoinsHud },
    { kind = "checkbox", var = SP.ShowFloatingObjectiveVariableName, label = "FLOATING_OBJECTIVE_LABEL",
        fallback = "Floating next objective", tooltip = "FLOATING_OBJECTIVE_TOOLTIP", default = false,
        get = SP.GetShowFloatingObjective, set = SP.SetShowFloatingObjective },
}

local function choiceOptions(choices)
    return function()
        local container = Settings.CreateControlTextContainer()
        for _, choice in ipairs(choices) do container:Add(choice[1], Lx(choice[2], choice[3])) end
        return container:GetData()
    end
end

local function addRow(category, layout, row)
    local label = Lx(row.label, row.fallback)
    local tooltip = row.tooltip and Lx(row.tooltip, "") or ""
    if row.kind == "header" then
        if layout and layout.AddInitializer and CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(label))
        end
        return
    end
    if row.kind == "button" then
        if layout and layout.AddInitializer and CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer(
                label, Lx(row.button, row.buttonFallback), row.click, tooltip, true))
        end
        return
    end
    local set = row.set
    local setting = Settings.RegisterProxySetting(category, row.var, type(row.default), label,
        row.default, row.get, function(value)
            if not settingsNotifying then set(value) end
        end)
    if row.kind == "checkbox" and Settings.CreateCheckbox then
        Settings.CreateCheckbox(category, setting, tooltip)
    elseif row.kind == "slider" and Settings.CreateSlider then
        Settings.CreateSlider(category, setting,
            sliderOptions(row.min, row.max, row.step, row.format), tooltip)
    elseif row.kind == "dropdown" and Settings.CreateDropdown and Settings.CreateControlTextContainer then
        Settings.CreateDropdown(category, setting, row.options or choiceOptions(row.choices), tooltip)
    end
end

-- Pushes current values into the Settings controls (e.g. after /ov guildkills off).
function SP:RefreshControls()
    if not Settings or not self._registered then return end
    for _, row in ipairs(ROWS) do
        if row.var and row.get then notifySettingsAPI(row.var, row.get()) end
    end
end

function SP:Register()
    if self._registered then return end
    if not Settings or not Settings.RegisterVerticalLayoutCategory or not Settings.RegisterProxySetting then
        return
    end
    securecall(function()
        local category, layout = Settings.RegisterVerticalLayoutCategory("Overlord")
        for _, row in ipairs(ROWS) do
            -- One unsupported control (older client API) must not hide the others.
            pcall(addRow, category, layout, row)
        end
        Settings.RegisterAddOnCategory(category)
        SP._category = category
        SP._registered = true
    end)
    -- The main panel's Options button lights up while this page is open.
    local panel = _G.SettingsPanel
    if SP._registered and panel and panel.HookScript and not SP._panelHooked then
        SP._panelHooked = true
        panel:HookScript("OnShow", scheduleActionGridActiveRefresh)
        panel:HookScript("OnHide", scheduleActionGridActiveRefresh)
        -- Overlord logo left of the page title. Blizzard rewrites the title on
        -- every category change, so only our page carries the inline icon.
        local function addLogo(_, category)
            if category ~= SP._category then return end
            local list = (panel.GetSettingsList and panel:GetSettingsList())
                or (panel.Container and panel.Container.SettingsList)
            local title = list and list.Header and list.Header.Title
            if title and title.SetText then
                title:SetText(SETTINGS_TITLE_LOGO .. " Overlord")
            end
        end
        for _, method in ipairs({ "DisplayCategory", "SelectCategory" }) do
            if hooksecurefunc and type(panel[method]) == "function" then
                hooksecurefunc(panel, method, addLogo)
            end
        end
    end
end

function SP:SyncUiScaleWithSettingsAPI()
    if not Settings then return end
    local v = Overlord.UI and Overlord.UI.GetEffectiveUiScale and Overlord.UI:GetEffectiveUiScale()
    if not v then return end
    notifySettingsAPI(self.UiScaleVariableName, clampScale(v))
end

function SP:IsOpen()
    local panel = _G.SettingsPanel
    if not panel or not panel.IsShown or not panel:IsShown() then return false end
    local category = self._category
    if category and panel.GetCurrentCategory then
        local ok, current = pcall(panel.GetCurrentCategory, panel)
        if ok and current ~= nil then return current == category end
    end
    return true
end

function Overlord.SettingsPanel:Close()
    local panel = _G.SettingsPanel
    if not panel or not panel.IsShown or not panel:IsShown() then
        return false
    end
    -- panel.Close() appelle ExitWithCommit -> ToggleGameMenu -> SpellStopCasting() (protégé hors code sécurisé).
    if HideUIPanel then
        HideUIPanel(panel)
    elseif panel.Hide then
        panel:Hide()
    else
        return false
    end
    local gameMenu = _G.GameMenuFrame
    if gameMenu and gameMenu.IsShown and gameMenu:IsShown() and HideUIPanel then
        HideUIPanel(gameMenu)
    end
    return not panel:IsShown()
end

function Overlord.SettingsPanel:Toggle()
    if self:IsOpen() then
        return self:Close()
    end
    return self:Open()
end

function Overlord.SettingsPanel:Open()
    if not Settings or not Settings.OpenToCategory then
        if Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. ((L and L.SETTINGS_OPEN_UNAVAILABLE) or "Options unavailable."))
        end
        return false
    end
    if not self._registered then
        pcall(function() self:Register() end)
    end
    local category = self._category
    if not category or not category.GetID then
        if Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. ((L and L.SETTINGS_OPEN_UNAVAILABLE) or "Options unavailable."))
        end
        return false
    end
    local ok = pcall(Settings.OpenToCategory, category:GetID())
    return ok == true
end
