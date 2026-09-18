-- SettingsPanel.lua - Esc > Options > AddOns > Overlord (canvas WC3 + API Settings retail 10+)
Overlord = Overlord or {}
Overlord.SettingsPanel = {}

local L = Overlord.L

local UI = Overlord.UI

local SETTINGS_LOGO_SIZE = 46
local SETTINGS_LOGO_TEXTURE = "Interface\\AddOns\\Overlord\\Textures\\overlord"

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
Overlord.SettingsPanel.ShowMapZoneTitlesVariableName = "Overlord_ShowMapZoneTitles"
Overlord.SettingsPanel.ShowTopHudVariableName = "Overlord_ShowTopHud"
Overlord.SettingsPanel.ShowTutorialBookVariableName = "Overlord_ShowTutorialBook"
Overlord.SettingsPanel.SoundEnabledVariableName = "Overlord_SoundEnabled"
Overlord.SettingsPanel.WorldDefenseEnabledVariableName = "Overlord_WorldDefenseEnabled"

local NOTIF_CHAT_MIN = 0
local NOTIF_CHAT_STEP = 1
local DEFAULT_NOTIF_CHAT = 0

local MAP_OVERLAY_OPACITY_MIN = 0.2
local MAP_OVERLAY_OPACITY_MAX = 1.0
local MAP_OVERLAY_OPACITY_STEP = 0.1
local DEFAULT_MAP_OVERLAY_OPACITY = 1.0
local DEFAULT_MINIMAP_OVERLAY_OPACITY = 1.0

local MAP_PATH_OPACITY_MIN = 1.0
local MAP_PATH_OPACITY_MAX = 3.0
local MAP_PATH_OPACITY_STEP = 0.25
local DEFAULT_MAP_PATH_OPACITY = 1.0
local DEFAULT_AUTO_WAYPOINT = true
local DEFAULT_SHOW_MINIMAP_BUTTON = true
local DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES = true
local DEFAULT_SHOW_MAP_ZONE_TITLES = true
local DEFAULT_SHOW_TOP_HUD = true
local DEFAULT_SHOW_TUTORIAL_BOOK = true
local DEFAULT_SOUND_ENABLED = true
local DEFAULT_WORLD_DEFENSE_ENABLED = true

local ROW_H = 58
local ROW_GAP = 6
local SETTINGS_ROW_COUNT = 14
local SETTINGS_VIEWPORT_H = 536
local SETTINGS_PAD_OUTER = 32
local SETTINGS_PAD_INNER = 24
local SETTINGS_HEADER_TOP = 16
local SETTINGS_STACK_MIN_W = 460
local SETTINGS_STACK_MAX_W = 560
local SETTINGS_SCROLL_INSET = 12
local SETTINGS_CONTENT_INSET = 8

local function computeStackWidth(canvasW)
    local w = (tonumber(canvasW) or 520) - SETTINGS_PAD_OUTER * 2
    if w < SETTINGS_STACK_MIN_W then w = SETTINGS_STACK_MIN_W end
    if w > SETTINGS_STACK_MAX_W then w = SETTINGS_STACK_MAX_W end
    return math.floor(w)
end

local SETTINGS_HEADER_H = SETTINGS_HEADER_TOP + SETTINGS_LOGO_SIZE + 14
local SETTINGS_GAP_HEADER_CONTENT = 12
local SETTINGS_RESET_GAP = 14
local SETTINGS_RESET_BTN_H = 28

local function ApplySettingsLogo(texture)
    if not texture then return end
    if texture.SetAtlas then
        pcall(texture.SetAtlas, texture, nil)
    end
    texture:SetTexture(SETTINGS_LOGO_TEXTURE)
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetSize(SETTINGS_LOGO_SIZE, SETTINGS_LOGO_SIZE)
    texture:SetAlpha(1)
    texture:Show()
end

local function computeContentScrollHeight()
    return 12 + (ROW_H + ROW_GAP) * SETTINGS_ROW_COUNT + 12
end

local function computeFixedStackChromeH()
    return SETTINGS_HEADER_H
        + SETTINGS_GAP_HEADER_CONTENT
        + SETTINGS_RESET_GAP
        + SETTINGS_RESET_BTN_H
        + SETTINGS_CONTENT_INSET * 2
end

local function computeIdealStackHeight()
    return computeFixedStackChromeH() + SETTINGS_VIEWPORT_H
end

local function computeViewportHeightForStack(stackH)
    local viewport = stackH - computeFixedStackChromeH()
    if viewport < 0 then
        return 0
    end
    return math.floor(viewport)
end

local function computeRowWidth(stackW)
    return stackW - SETTINGS_SCROLL_INSET - SETTINGS_PAD_INNER * 2
end

local function scheduleActionGridActiveRefresh()
    local ui = Overlord.UI
    if ui and ui.ScheduleActionGridActiveRefresh then
        ui:ScheduleActionGridActiveRefresh()
    end
end

local settingsSuppressSideEffects = false
local minimapOpacityRefreshPending = false
local mapOpacityRefreshPending = false
local cachedNotifChatLabelKey
local cachedNotifChatLabel

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

local function flushSettingsMapSideEffects()
    if Overlord.MapMarkers then
        if Overlord.MapMarkers.RequestOverlayRefresh then
            Overlord.MapMarkers:RequestOverlayRefresh()
        end
        if Overlord.MapMarkers.RefreshMinimapOverlayOpacity then
            Overlord.MapMarkers:RefreshMinimapOverlayOpacity()
        end
        if Overlord.MapMarkers.RefreshMinimapCaptureZonesVisibility then
            Overlord.MapMarkers:RefreshMinimapCaptureZonesVisibility()
        end
    end
end

local function clampScale(v)
    v = tonumber(v) or DEFAULT_SCALE
    if v < UI_SCALE_MIN then v = UI_SCALE_MIN end
    if v > UI_SCALE_MAX then v = UI_SCALE_MAX end
    return math.floor(v * 10 + 0.5) / 10
end

local function formatScaleLabel(value)
    local v = clampScale(tonumber(value) or DEFAULT_SCALE)
    if v == math.floor(v) then
        return tostring(math.floor(v))
    end
    return string.format("%.1f", v)
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

local function formatNotificationChatLabel(value)
    local v = clampNotificationChat(value)
    if v <= 0 then
        return (L and L.NOTIFICATION_CHAT_DEFAULT_SHORT) or "Default"
    end
    if cachedNotifChatLabelKey == v and cachedNotifChatLabel then
        return cachedNotifChatLabel
    end
    local label = tostring(v)
    if type(FCF_GetChatWindowInfo) == "function" then
        local ok, nm = pcall(function()
            return (select(1, FCF_GetChatWindowInfo(v)))
        end)
        if ok and nm and nm ~= "" then
                label = string.format("%d : %s", v, nm)
        end
    end
    cachedNotifChatLabelKey = v
    cachedNotifChatLabel = label
    return label
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

local function notifySettingsAPI(varName, value)
    if not Settings then return end
    if Settings.SetValue then
        pcall(Settings.SetValue, varName, value, true)
    elseif Settings.NotifyUpdate then
        pcall(Settings.NotifyUpdate, varName)
    end
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
    cachedNotifChatLabelKey = nil
    cachedNotifChatLabel = nil
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

local function getShowMapZoneTitles()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showMapZoneTitles == false then
        return false
    end
    return true
end

local function setShowMapZoneTitles(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showMapZoneTitles = value == true
    if not settingsSuppressSideEffects and Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowMapZoneTitlesVariableName, OverlordDB.config.showMapZoneTitles)
end

local function getShowTopHud()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showTopHud == false then
        return false
    end
    return true
end

local function setShowTopHud(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showTopHud = value == true
    if value == true then
        OverlordDB.goldHUDHidden = false
    end
    if not settingsSuppressSideEffects and Overlord.Ressources and Overlord.Ressources.OnShowTopHudSettingChanged then
        Overlord.Ressources:OnShowTopHudSettingChanged()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowTopHudVariableName, OverlordDB.config.showTopHud)
end

local function getShowTutorialBook()
    if OverlordDB and OverlordDB.config and OverlordDB.config.showTutorialBook == false then
        return false
    end
    return true
end

local function setShowTutorialBook(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.showTutorialBook = value == true
    if not settingsSuppressSideEffects and Overlord.Ressources and Overlord.Ressources.OnShowTutorialBookSettingChanged then
        Overlord.Ressources:OnShowTutorialBookSettingChanged()
    end
    notifySettingsAPI(Overlord.SettingsPanel.ShowTutorialBookVariableName, OverlordDB.config.showTutorialBook)
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

local function getWorldDefenseEnabled()
    if OverlordDB and OverlordDB.config and OverlordDB.config.worldDefenseEnabled == false then
        return false
    end
    return true
end

local function setWorldDefenseEnabled(value)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.worldDefenseEnabled = value == true
    notifySettingsAPI(Overlord.SettingsPanel.WorldDefenseEnabledVariableName,
        OverlordDB.config.worldDefenseEnabled)
end

-- Une seule upvalue pour tous les get/set (limite Lua 60 upvalues sur EnsureFrame).
local Acc = {
    getScale = getScale,
    setScale = setScale,
    clampScale = clampScale,
    formatScaleLabel = formatScaleLabel,
    getNotificationChat = getNotificationChat,
    setNotificationChat = setNotificationChat,
    clampNotificationChat = clampNotificationChat,
    formatNotificationChatLabel = formatNotificationChatLabel,
    maxChatWindows = maxChatWindows,
    getMapOverlayOpacity = getMapOverlayOpacity,
    setMapOverlayOpacity = setMapOverlayOpacity,
    clampMapOverlayOpacity = clampMapOverlayOpacity,
    formatMapOverlayOpacityLabel = formatMapOverlayOpacityLabel,
    getMinimapOverlayOpacity = getMinimapOverlayOpacity,
    setMinimapOverlayOpacity = setMinimapOverlayOpacity,
    getMapPathOpacity = getMapPathOpacity,
    setMapPathOpacity = setMapPathOpacity,
    clampMapPathOpacity = clampMapPathOpacity,
    formatMapPathOpacityLabel = formatMapPathOpacityLabel,
    getAutoWaypoint = getAutoWaypoint,
    setAutoWaypoint = setAutoWaypoint,
    getShowMinimapButton = getShowMinimapButton,
    setShowMinimapButton = setShowMinimapButton,
    getShowMinimapCaptureZones = getShowMinimapCaptureZones,
    setShowMinimapCaptureZones = setShowMinimapCaptureZones,
    getShowMapZoneTitles = getShowMapZoneTitles,
    setShowMapZoneTitles = setShowMapZoneTitles,
    getShowTopHud = getShowTopHud,
    setShowTopHud = setShowTopHud,
    getShowTutorialBook = getShowTutorialBook,
    setShowTutorialBook = setShowTutorialBook,
    getSoundEnabled = getSoundEnabled,
    setSoundEnabled = setSoundEnabled,
    getWorldDefenseEnabled = getWorldDefenseEnabled,
    setWorldDefenseEnabled = setWorldDefenseEnabled,
}

function Overlord.SettingsPanel:RefreshControls()
    if self._scaleRow and self._scaleRow.Refresh then self._scaleRow:Refresh() end
    if self._chatRow and self._chatRow.Refresh then self._chatRow:Refresh() end
    if self._opacityRow and self._opacityRow.Refresh then self._opacityRow:Refresh() end
    if self._minimapOpacityRow and self._minimapOpacityRow.Refresh then self._minimapOpacityRow:Refresh() end
    if self._pathOpacityRow and self._pathOpacityRow.Refresh then self._pathOpacityRow:Refresh() end
    if self._autoWaypointRow and self._autoWaypointRow.Refresh then self._autoWaypointRow:Refresh() end
    if self._showTopHudRow and self._showTopHudRow.Refresh then self._showTopHudRow:Refresh() end
    if self._showTutorialBookRow and self._showTutorialBookRow.Refresh then self._showTutorialBookRow:Refresh() end
    if self._soundEnabledRow and self._soundEnabledRow.Refresh then self._soundEnabledRow:Refresh() end
    if self._worldDefenseEnabledRow and self._worldDefenseEnabledRow.Refresh then self._worldDefenseEnabledRow:Refresh() end
    if self._minimapButtonRow and self._minimapButtonRow.Refresh then self._minimapButtonRow:Refresh() end
    if self._minimapCaptureZonesRow and self._minimapCaptureZonesRow.Refresh then self._minimapCaptureZonesRow:Refresh() end
    if self._mapZoneTitlesRow and self._mapZoneTitlesRow.Refresh then self._mapZoneTitlesRow:Refresh() end
end

function Overlord.SettingsPanel:RefreshFactionChrome()
    local f = self._frame
    if not f or not UI then return end
    local P = UI.GetViewerFactionPalette and UI.GetViewerFactionPalette() or {}
    local gold = P.gold or { 0.85, 0.68, 0.20 }

    ApplySettingsLogo(f.logo)

    if f.titleFs then
        f.titleFs:SetTextColor(gold[1], gold[2], gold[3])
    end
    if f.versionFs then
        if P.bright then
            f.versionFs:SetTextColor(P.bright[1] * 0.55, P.bright[2] * 0.55, P.bright[3] * 0.55)
        else
            f.versionFs:SetTextColor(0.55, 0.55, 0.55)
        end
    end
    if f.subtitleFs and P.bright then
        f.subtitleFs:SetTextColor(P.bright[1], P.bright[2], P.bright[3])
    end
    if f.content and f.content.SetBackdropBorderColor then
        f.content:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.72)
    end
    if f._woodBackdropApplied and UI.UpdateWoodDialogBorder then
        UI.UpdateWoodDialogBorder(f, { fallbackBg = P.fallbackBg, borderColor = gold, borderAlpha = 0.88 })
    elseif UI.ApplyWoodDialogBackdrop and f.SetBackdrop then
        UI.ApplyWoodDialogBackdrop(f, { fallbackBg = P.fallbackBg, borderColor = gold, borderAlpha = 0.88 })
    end
end

function Overlord.SettingsPanel:ResetDefaults()
    settingsSuppressSideEffects = true
    setScale(DEFAULT_SCALE)
    setNotificationChat(DEFAULT_NOTIF_CHAT)
    setMapOverlayOpacity(DEFAULT_MAP_OVERLAY_OPACITY)
    setMinimapOverlayOpacity(DEFAULT_MINIMAP_OVERLAY_OPACITY)
    setMapPathOpacity(DEFAULT_MAP_PATH_OPACITY)
    setAutoWaypoint(DEFAULT_AUTO_WAYPOINT)
    setShowMinimapButton(DEFAULT_SHOW_MINIMAP_BUTTON)
    setShowTopHud(DEFAULT_SHOW_TOP_HUD)
    setShowTutorialBook(DEFAULT_SHOW_TUTORIAL_BOOK)
    setSoundEnabled(DEFAULT_SOUND_ENABLED)
    setWorldDefenseEnabled(DEFAULT_WORLD_DEFENSE_ENABLED)
    setShowMinimapCaptureZones(DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES)
    setShowMapZoneTitles(DEFAULT_SHOW_MAP_ZONE_TITLES)
    settingsSuppressSideEffects = false
    flushSettingsMapSideEffects()
    if Overlord.MapMarkers and Overlord.MapMarkers.RefreshMinimapButtonVisibility then
        Overlord.MapMarkers:RefreshMinimapButtonVisibility()
    end
    if Overlord.Ressources and Overlord.Ressources.OnShowTopHudSettingChanged then
        Overlord.Ressources:OnShowTopHudSettingChanged()
    end
    self:RefreshControls()
end

local function CreateToggleRow(parent, opts)
    opts = opts or {}
    local gold = opts.gold or { 0.85, 0.68, 0.20 }
    local white = opts.white or { 1, 1, 1 }
    local rowW = opts.width or computeRowWidth(SETTINGS_STACK_MIN_W)
    local rowH = opts.height or ROW_H

    local row = CreateFrame("Button", nil, parent)
    row:SetSize(rowW, rowH)
    row:RegisterForClicks("LeftButtonUp")

    local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -6)
    title:SetWidth(rowW - 116)
    title:SetJustifyH("LEFT")
    title:SetText(opts.label or "")
    title:SetTextColor(gold[1], gold[2], gold[3])
    row.title = title

    local desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    desc:SetWidth(rowW - 116)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetMaxLines(2)
    desc:SetText(opts.tooltip or "")
    row.desc = desc

    local button = UI.CreateWC3Button(row, 96, 24, "", function()
        if opts.set and opts.get then
            opts.set(not opts.get())
            row:Refresh()
        end
    end, nil, { gold = gold, white = white })
    button:SetPoint("RIGHT", row, "RIGHT", 0, -2)
    row.valueButton = button

    function row:Refresh()
        local enabled = opts.get and opts.get() or false
        local text = enabled
            and ((L and L.SETTINGS_TOGGLE_ON) or "Enabled")
            or ((L and L.SETTINGS_TOGGLE_OFF) or "Disabled")
        self.valueButton.label:SetText(text)
        if UI and UI.SetWC3ButtonActive then
            UI.SetWC3ButtonActive(self.valueButton, enabled, { gold = gold, white = white })
        end
    end

    row:SetScript("OnClick", function(self)
        if opts.set and opts.get then
            opts.set(not opts.get())
            self:Refresh()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if not opts.tooltip or opts.tooltip == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(opts.label or "", gold[1], gold[2], gold[3], 1, true)
        GameTooltip:AddLine(opts.tooltip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    function row:SetLayoutWidth(w)
        rowW = w
        self:SetWidth(w)
        self.title:SetWidth(w - 116)
        self.desc:SetWidth(w - 116)
    end

    row:Refresh()
    return row
end

-- Construit les lignes de settings hors EnsureFrame (budget upvalues separe).
local function BuildSettingsRows(sp, rowParent, initialRowW, gold, white, placeRow)
    if Overlord.ActionShortcut and Overlord.ActionShortcut.CreateSettingsRow then
        sp._actionShortcutRow = Overlord.ActionShortcut:CreateSettingsRow(rowParent, {
            width = initialRowW,
            height = ROW_H,
            gold = gold,
            white = white,
        })
        placeRow(sp._actionShortcutRow)
    end

    sp._scaleRow = UI.CreateWC3StepperSlider(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.UI_SCALE_LABEL) or "Panel scale",
        tooltip = (L and L.UI_SCALE_TOOLTIP) or "",
        min = UI_SCALE_MIN,
        max = UI_SCALE_MAX,
        step = UI_SCALE_STEP,
        get = Acc.getScale,
        set = Acc.setScale,
        snap = Acc.clampScale,
        formatValue = Acc.formatScaleLabel,
        formatMin = Acc.formatScaleLabel,
        formatMax = Acc.formatScaleLabel,
        gold = gold,
        white = white,
    })
    placeRow(sp._scaleRow)

    sp._chatRow = UI.CreateWC3StepperSlider(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.NOTIFICATION_CHAT_LABEL) or "Notification chat tab",
        tooltip = (L and L.NOTIFICATION_CHAT_TOOLTIP) or "",
        min = NOTIF_CHAT_MIN,
        max = Acc.maxChatWindows(),
        step = NOTIF_CHAT_STEP,
        get = Acc.getNotificationChat,
        set = Acc.setNotificationChat,
        snap = Acc.clampNotificationChat,
        formatValue = Acc.formatNotificationChatLabel,
        formatMin = Acc.formatNotificationChatLabel,
        formatMax = function(v) return tostring(v) end,
        gold = gold,
        white = white,
    })
    placeRow(sp._chatRow)

    sp._worldDefenseEnabledRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.WORLD_DEFENSE_ENABLED_LABEL) or "World Defense relay",
        tooltip = (L and L.WORLD_DEFENSE_ENABLED_TOOLTIP) or "",
        get = Acc.getWorldDefenseEnabled,
        set = Acc.setWorldDefenseEnabled,
        gold = gold,
        white = white,
    })
    placeRow(sp._worldDefenseEnabledRow)

    sp._opacityRow = UI.CreateWC3StepperSlider(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MAP_OVERLAY_OPACITY_LABEL) or "Map capture opacity",
        tooltip = (L and L.MAP_OVERLAY_OPACITY_TOOLTIP) or "",
        min = MAP_OVERLAY_OPACITY_MIN,
        max = MAP_OVERLAY_OPACITY_MAX,
        step = MAP_OVERLAY_OPACITY_STEP,
        get = Acc.getMapOverlayOpacity,
        set = Acc.setMapOverlayOpacity,
        snap = Acc.clampMapOverlayOpacity,
        formatValue = Acc.formatMapOverlayOpacityLabel,
        formatMin = Acc.formatMapOverlayOpacityLabel,
        formatMax = Acc.formatMapOverlayOpacityLabel,
        gold = gold,
        white = white,
    })
    placeRow(sp._opacityRow)

    sp._minimapOpacityRow = UI.CreateWC3StepperSlider(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MINIMAP_OVERLAY_OPACITY_LABEL) or "Minimap capture opacity",
        tooltip = (L and L.MINIMAP_OVERLAY_OPACITY_TOOLTIP) or "",
        min = MAP_OVERLAY_OPACITY_MIN,
        max = MAP_OVERLAY_OPACITY_MAX,
        step = MAP_OVERLAY_OPACITY_STEP,
        get = Acc.getMinimapOverlayOpacity,
        set = Acc.setMinimapOverlayOpacity,
        snap = Acc.clampMapOverlayOpacity,
        formatValue = Acc.formatMapOverlayOpacityLabel,
        formatMin = Acc.formatMapOverlayOpacityLabel,
        formatMax = Acc.formatMapOverlayOpacityLabel,
        gold = gold,
        white = white,
    })
    placeRow(sp._minimapOpacityRow)

    sp._minimapCaptureZonesRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MINIMAP_CAPTURE_ZONES_LABEL) or "Minimap capture zones",
        tooltip = (L and L.MINIMAP_CAPTURE_ZONES_TOOLTIP) or "",
        get = Acc.getShowMinimapCaptureZones,
        set = Acc.setShowMinimapCaptureZones,
        gold = gold,
        white = white,
    })
    placeRow(sp._minimapCaptureZonesRow)

    sp._minimapButtonRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MINIMAP_BUTTON_LABEL) or "Minimap button",
        tooltip = (L and L.MINIMAP_BUTTON_TOOLTIP) or "",
        get = Acc.getShowMinimapButton,
        set = Acc.setShowMinimapButton,
        gold = gold,
        white = white,
    })
    placeRow(sp._minimapButtonRow)

    sp._mapZoneTitlesRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MAP_ZONE_TITLES_LABEL) or "Map zone names",
        tooltip = (L and L.MAP_ZONE_TITLES_TOOLTIP) or "",
        get = Acc.getShowMapZoneTitles,
        set = Acc.setShowMapZoneTitles,
        gold = gold,
        white = white,
    })
    placeRow(sp._mapZoneTitlesRow)

    sp._pathOpacityRow = UI.CreateWC3StepperSlider(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.MAP_PATH_OPACITY_LABEL) or "Map path opacity",
        tooltip = (L and L.MAP_PATH_OPACITY_TOOLTIP) or "",
        min = MAP_PATH_OPACITY_MIN,
        max = MAP_PATH_OPACITY_MAX,
        step = MAP_PATH_OPACITY_STEP,
        get = Acc.getMapPathOpacity,
        set = Acc.setMapPathOpacity,
        snap = Acc.clampMapPathOpacity,
        formatValue = Acc.formatMapPathOpacityLabel,
        formatMin = Acc.formatMapPathOpacityLabel,
        formatMax = Acc.formatMapPathOpacityLabel,
        gold = gold,
        white = white,
    })
    placeRow(sp._pathOpacityRow)

    sp._autoWaypointRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.AUTO_WAYPOINT_LABEL) or "Auto-pin next objective",
        tooltip = (L and L.AUTO_WAYPOINT_TOOLTIP) or "",
        get = Acc.getAutoWaypoint,
        set = Acc.setAutoWaypoint,
        gold = gold,
        white = white,
    })
    placeRow(sp._autoWaypointRow)

    sp._showTopHudRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.SHOW_TOP_HUD_LABEL) or "Top HUD",
        tooltip = (L and L.SHOW_TOP_HUD_TOOLTIP) or "",
        get = Acc.getShowTopHud,
        set = Acc.setShowTopHud,
        gold = gold,
        white = white,
    })
    placeRow(sp._showTopHudRow)

    sp._showTutorialBookRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.SHOW_TUTORIAL_BOOK_LABEL) or "Tutorial book icon",
        tooltip = (L and L.SHOW_TUTORIAL_BOOK_TOOLTIP) or "",
        get = Acc.getShowTutorialBook,
        set = Acc.setShowTutorialBook,
        gold = gold,
        white = white,
    })
    placeRow(sp._showTutorialBookRow)

    sp._soundEnabledRow = CreateToggleRow(rowParent, {
        width = initialRowW,
        height = ROW_H,
        label = (L and L.SOUND_ENABLED_LABEL) or "Overlord sounds",
        tooltip = (L and L.SOUND_ENABLED_TOOLTIP) or "",
        get = Acc.getSoundEnabled,
        set = Acc.setSoundEnabled,
        gold = gold,
        white = white,
    })
    placeRow(sp._soundEnabledRow)
end

function Overlord.SettingsPanel:EnsureFrame()
    if self._frame then return self._frame end
    if not UI or not UI.ApplyWoodDialogBackdrop or not UI.CreateWC3SubPanel or not UI.CreateWC3StepperSlider then
        return nil
    end

    local P = UI.GetViewerFactionPalette and UI.GetViewerFactionPalette() or {}
    local gold = P.gold or { 0.85, 0.68, 0.20 }
    local white = P.white or { 0.925, 0.937, 0.969 }

    local initialStackW = computeStackWidth(520)
    local initialRowW = computeRowWidth(initialStackW)

    local f = CreateFrame("Frame", "OverlordSettingsCanvas", nil, "BackdropTemplate")
    local idealStackH = computeIdealStackHeight()
    f:SetSize(initialStackW + SETTINGS_PAD_OUTER * 2, idealStackH + SETTINGS_PAD_OUTER * 2)
    UI.ApplyWoodDialogBackdrop(f, { fallbackBg = P.fallbackBg, borderColor = gold, borderAlpha = 0.88 })

    local contentScrollH = computeContentScrollHeight()

    f.stack = CreateFrame("Frame", nil, f)
    f.stack:SetHeight(idealStackH)
    f.stack:SetPoint("TOPLEFT", f, "TOPLEFT", SETTINGS_PAD_OUTER, -SETTINGS_PAD_OUTER)
    f.stack:SetPoint("TOPRIGHT", f, "TOPRIGHT", -SETTINGS_PAD_OUTER, -SETTINGS_PAD_OUTER)

    f._settingsRows = {}

    function f:RefreshSettingsLayout()
        local pw = self:GetWidth() or 520
        local ph = self:GetHeight() or (computeIdealStackHeight() + SETTINGS_PAD_OUTER * 2)
        local stackW = self.stack and self.stack:GetWidth()
        if not stackW or stackW < 100 then
            stackW = computeStackWidth(pw)
        end
        local maxStackH = ph - SETTINGS_PAD_OUTER * 2
        local stackH = math.min(computeIdealStackHeight(), maxStackH)
        local viewportH = computeViewportHeightForStack(stackH)
        local rowW = computeRowWidth(stackW)

        self.stack:SetHeight(stackH)
        if self.content then
            self.content:SetHeight(viewportH + SETTINGS_CONTENT_INSET * 2)
        end
        if self._scrollChild then
            self._scrollChild:SetWidth(rowW + SETTINGS_PAD_INNER * 2)
        end
        for _, row in ipairs(self._settingsRows) do
            if row.SetLayoutWidth then
                row:SetLayoutWidth(rowW)
            end
        end
        if self.RefreshSettingsScroll then
            self:RefreshSettingsScroll()
        end
    end

    local settingsLayoutRefreshPending = false
    function f:QueueRefreshSettingsLayout()
        if settingsLayoutRefreshPending then return end
        settingsLayoutRefreshPending = true
        C_Timer.After(0, function()
            settingsLayoutRefreshPending = false
            if f.RefreshSettingsLayout and f:IsShown() then
                f:RefreshSettingsLayout()
            end
        end)
    end

    f:SetScript("OnShow", function(self)
        local parent = self:GetParent()
        if parent and parent.GetWidth and parent:GetWidth() > 0 then
            self:SetAllPoints(parent)
        end
        self:QueueRefreshSettingsLayout()
        if Overlord.SettingsPanel.RefreshFactionChrome then
            Overlord.SettingsPanel:RefreshFactionChrome()
        end
        if Overlord.SettingsPanel.RefreshControls then
            Overlord.SettingsPanel:RefreshControls()
        end
        scheduleActionGridActiveRefresh()
    end)

    f:SetScript("OnHide", scheduleActionGridActiveRefresh)

    f:SetScript("OnSizeChanged", function(self)
        self:QueueRefreshSettingsLayout()
    end)

    f.logo = f.stack:CreateTexture(nil, "ARTWORK")
    f.logo:SetDrawLayer("ARTWORK", 2)
    f.logo:SetSize(SETTINGS_LOGO_SIZE, SETTINGS_LOGO_SIZE)
    f.logo:SetPoint("TOPLEFT", f.stack, "TOPLEFT", 8, -SETTINGS_HEADER_TOP)

    f.titleFs = f.stack:CreateFontString(nil, "OVERLAY", "Fancy24Font")
    f.titleFs:SetPoint("LEFT", f.logo, "RIGHT", 10, 2)
    f.titleFs:SetText("Overlord")
    f.titleFs:SetTextColor(gold[1], gold[2], gold[3])
    f.titleFs:SetShadowOffset(2, -2)

    f.versionFs = f.stack:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.versionFs:SetPoint("RIGHT", f.stack, "RIGHT", -12, 0)
    f.versionFs:SetPoint("BOTTOM", f.titleFs, "BOTTOM", 0, -1)
    f.versionFs:SetJustifyH("RIGHT")
    local addonVer = Overlord and Overlord.Version
    f.versionFs:SetText(addonVer and ("v" .. addonVer) or "")

    f.subtitleFs = f.stack:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.subtitleFs:SetPoint("TOPLEFT", f.titleFs, "BOTTOMLEFT", 0, -2)
    local playerName = Overlord and Overlord.SafeUnitName and select(1, Overlord:SafeUnitName("player"))
    if not playerName or playerName == "" then
        playerName = (L and L.POPUP_WELCOME_NAME_FALLBACK) or "Champion"
    end
    local subFmt = (L and L.SETTINGS_SUBTITLE) or "%s"
    f.subtitleFs:SetText(string.format(subFmt, playerName))
    if P.bright then
        f.subtitleFs:SetTextColor(P.bright[1], P.bright[2], P.bright[3])
    end

    f.content = UI.CreateWC3SubPanel(f.stack, initialStackW, SETTINGS_VIEWPORT_H + SETTINGS_CONTENT_INSET * 2, {
        panelBg = P.panelBg,
        borderColor = gold,
        borderAlpha = 0.72,
        insets = {
            left = SETTINGS_CONTENT_INSET,
            right = SETTINGS_CONTENT_INSET,
            top = SETTINGS_CONTENT_INSET,
            bottom = SETTINGS_CONTENT_INSET,
        },
    })
    f.content:SetPoint("TOP", f.subtitleFs, "BOTTOM", 0, -SETTINGS_GAP_HEADER_CONTENT)
    f.content:SetPoint("LEFT", f.stack, "LEFT", 0, 0)
    f.content:SetPoint("RIGHT", f.stack, "RIGHT", 0, 0)

    local scroll, scrollChild, scrollIndUp, scrollIndDown
    if UI.CreateWC3WheelScroll then
        scroll, scrollChild, scrollIndUp, scrollIndDown = UI:CreateWC3WheelScroll(
            f.content, initialRowW + SETTINGS_PAD_INNER * 2, ROW_H + ROW_GAP)
    end
    f._scrollChild = scrollChild
    local rowParent = scrollChild or f.content

    function f:RefreshSettingsScroll()
        if not scroll or not UI.UpdateWheelScrollIndicators then return end
        if scrollChild then
            scrollChild:SetHeight(contentScrollH)
        end
        scroll:UpdateScrollChildRect()
        UI:UpdateWheelScrollIndicators(scroll, scrollIndUp, scrollIndDown)
    end

    local anchor = rowParent
    local first = true
    local function placeRow(row)
        row:SetParent(rowParent)
        if first then
            row:SetPoint("TOPLEFT", anchor, "TOPLEFT", SETTINGS_PAD_INNER, -12)
            first = false
        else
            row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -ROW_GAP)
        end
        tinsert(f._settingsRows, row)
        anchor = row
    end

    BuildSettingsRows(self, rowParent, initialRowW, gold, white, placeRow)

    if scrollChild then
        scrollChild:SetHeight(contentScrollH)
    end

    f.resetBtn = UI.CreateWC3Button(f.stack, 160, 28,
        (L and L.SETTINGS_DEFAULTS_BUTTON) or "Reset to defaults",
        function()
            Overlord.SettingsPanel:ResetDefaults()
        end,
        nil,
        { gold = gold, white = white })
    f.resetBtn:SetPoint("TOP", f.content, "BOTTOM", 0, -SETTINGS_RESET_GAP)
    f.resetBtn:SetPoint("LEFT", f.stack, "CENTER", -80, 0)

    ApplySettingsLogo(f.logo)

    f:RefreshSettingsLayout()

    self._frame = f
    return f
end

-- Layout vertical Blizzard (repli si canvas indisponible)
local function RegisterVerticalFallback()
    local category = Settings.RegisterVerticalLayoutCategory("Overlord")
    local Lbl = MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label

    local setting = Settings.RegisterProxySetting(
        category,
        Overlord.SettingsPanel.UiScaleVariableName,
        type(DEFAULT_SCALE),
        (L and L.UI_SCALE_LABEL) or "Panel scale",
        DEFAULT_SCALE,
        getScale,
        setScale
    )
    local options = Settings.CreateSliderOptions(UI_SCALE_MIN, UI_SCALE_MAX, UI_SCALE_STEP)
    if options and options.SetLabelFormatter and Lbl then
        pcall(function()
            options:SetLabelFormatter(Lbl.Min, function() return formatScaleLabel(UI_SCALE_MIN) end)
            options:SetLabelFormatter(Lbl.Max, function() return formatScaleLabel(UI_SCALE_MAX) end)
            options:SetLabelFormatter(Lbl.Right, formatScaleLabel)
        end)
    end
    Settings.CreateSlider(category, setting, options, (L and L.UI_SCALE_TOOLTIP) or "")

    local ncSetting = Settings.RegisterProxySetting(
        category,
        Overlord.SettingsPanel.NotificationChatVariableName,
        type(DEFAULT_NOTIF_CHAT),
        (L and L.NOTIFICATION_CHAT_LABEL) or "Notification chat tab",
        DEFAULT_NOTIF_CHAT,
        getNotificationChat,
        setNotificationChat
    )
    local ncOptions = Settings.CreateSliderOptions(NOTIF_CHAT_MIN, maxChatWindows(), NOTIF_CHAT_STEP)
    if ncOptions and ncOptions.SetLabelFormatter and Lbl then
        pcall(function()
            ncOptions:SetLabelFormatter(Lbl.Min, function()
                return (L and L.NOTIFICATION_CHAT_DEFAULT_SHORT) or "Default"
            end)
            ncOptions:SetLabelFormatter(Lbl.Max, function() return tostring(maxChatWindows()) end)
            ncOptions:SetLabelFormatter(Lbl.Right, formatNotificationChatLabel)
        end)
    end
    Settings.CreateSlider(category, ncSetting, ncOptions, (L and L.NOTIFICATION_CHAT_TOOLTIP) or "")

    local moSetting = Settings.RegisterProxySetting(
        category,
        Overlord.SettingsPanel.MapOverlayOpacityVariableName,
        type(DEFAULT_MAP_OVERLAY_OPACITY),
        (L and L.MAP_OVERLAY_OPACITY_LABEL) or "Map capture opacity",
        DEFAULT_MAP_OVERLAY_OPACITY,
        getMapOverlayOpacity,
        setMapOverlayOpacity
    )
    local moOptions = Settings.CreateSliderOptions(
        MAP_OVERLAY_OPACITY_MIN, MAP_OVERLAY_OPACITY_MAX, MAP_OVERLAY_OPACITY_STEP)
    if moOptions and moOptions.SetLabelFormatter and Lbl then
        pcall(function()
            moOptions:SetLabelFormatter(Lbl.Min, function()
                return formatMapOverlayOpacityLabel(MAP_OVERLAY_OPACITY_MIN)
            end)
            moOptions:SetLabelFormatter(Lbl.Max, function()
                return formatMapOverlayOpacityLabel(MAP_OVERLAY_OPACITY_MAX)
            end)
            moOptions:SetLabelFormatter(Lbl.Right, formatMapOverlayOpacityLabel)
        end)
    end
    Settings.CreateSlider(category, moSetting, moOptions, (L and L.MAP_OVERLAY_OPACITY_TOOLTIP) or "")

    local mmoSetting = Settings.RegisterProxySetting(
        category,
        Overlord.SettingsPanel.MinimapOverlayOpacityVariableName,
        type(DEFAULT_MINIMAP_OVERLAY_OPACITY),
        (L and L.MINIMAP_OVERLAY_OPACITY_LABEL) or "Minimap capture opacity",
        DEFAULT_MINIMAP_OVERLAY_OPACITY,
        getMinimapOverlayOpacity,
        setMinimapOverlayOpacity
    )
    local mmoOptions = Settings.CreateSliderOptions(
        MAP_OVERLAY_OPACITY_MIN, MAP_OVERLAY_OPACITY_MAX, MAP_OVERLAY_OPACITY_STEP)
    if mmoOptions and mmoOptions.SetLabelFormatter and Lbl then
        pcall(function()
            mmoOptions:SetLabelFormatter(Lbl.Min, function()
                return formatMapOverlayOpacityLabel(MAP_OVERLAY_OPACITY_MIN)
            end)
            mmoOptions:SetLabelFormatter(Lbl.Max, function()
                return formatMapOverlayOpacityLabel(MAP_OVERLAY_OPACITY_MAX)
            end)
            mmoOptions:SetLabelFormatter(Lbl.Right, formatMapOverlayOpacityLabel)
        end)
    end
    Settings.CreateSlider(category, mmoSetting, mmoOptions, (L and L.MINIMAP_OVERLAY_OPACITY_TOOLTIP) or "")

    local poSetting = Settings.RegisterProxySetting(
        category,
        Overlord.SettingsPanel.MapPathOpacityVariableName,
        type(DEFAULT_MAP_PATH_OPACITY),
        (L and L.MAP_PATH_OPACITY_LABEL) or "Map path opacity",
        DEFAULT_MAP_PATH_OPACITY,
        getMapPathOpacity,
        setMapPathOpacity
    )
    local poOptions = Settings.CreateSliderOptions(
        MAP_PATH_OPACITY_MIN, MAP_PATH_OPACITY_MAX, MAP_PATH_OPACITY_STEP)
    if poOptions and poOptions.SetLabelFormatter and Lbl then
        pcall(function()
            poOptions:SetLabelFormatter(Lbl.Min, function()
                return formatMapPathOpacityLabel(MAP_PATH_OPACITY_MIN)
            end)
            poOptions:SetLabelFormatter(Lbl.Max, function()
                return formatMapPathOpacityLabel(MAP_PATH_OPACITY_MAX)
            end)
            poOptions:SetLabelFormatter(Lbl.Right, formatMapPathOpacityLabel)
        end)
    end
    Settings.CreateSlider(category, poSetting, poOptions, (L and L.MAP_PATH_OPACITY_TOOLTIP) or "")
    if Settings.CreateCheckbox then
        local mbSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMinimapButtonVariableName,
            type(DEFAULT_SHOW_MINIMAP_BUTTON),
            (L and L.MINIMAP_BUTTON_LABEL) or "Minimap button",
            DEFAULT_SHOW_MINIMAP_BUTTON,
            getShowMinimapButton,
            setShowMinimapButton
        )
        Settings.CreateCheckbox(category, mbSetting, (L and L.MINIMAP_BUTTON_TOOLTIP) or "")
        local mmcSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMinimapCaptureZonesVariableName,
            type(DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES),
            (L and L.MINIMAP_CAPTURE_ZONES_LABEL) or "Minimap capture zones",
            DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES,
            getShowMinimapCaptureZones,
            setShowMinimapCaptureZones
        )
        Settings.CreateCheckbox(category, mmcSetting, (L and L.MINIMAP_CAPTURE_ZONES_TOOLTIP) or "")
        local mztSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMapZoneTitlesVariableName,
            type(DEFAULT_SHOW_MAP_ZONE_TITLES),
            (L and L.MAP_ZONE_TITLES_LABEL) or "Map zone names",
            DEFAULT_SHOW_MAP_ZONE_TITLES,
            getShowMapZoneTitles,
            setShowMapZoneTitles
        )
        Settings.CreateCheckbox(category, mztSetting, (L and L.MAP_ZONE_TITLES_TOOLTIP) or "")
        local awSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.AutoWaypointVariableName,
            type(DEFAULT_AUTO_WAYPOINT),
            (L and L.AUTO_WAYPOINT_LABEL) or "Auto-pin next objective",
            DEFAULT_AUTO_WAYPOINT,
            getAutoWaypoint,
            setAutoWaypoint
        )
        Settings.CreateCheckbox(category, awSetting, (L and L.AUTO_WAYPOINT_TOOLTIP) or "")
        local thSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowTopHudVariableName,
            type(DEFAULT_SHOW_TOP_HUD),
            (L and L.SHOW_TOP_HUD_LABEL) or "Top HUD",
            DEFAULT_SHOW_TOP_HUD,
            getShowTopHud,
            setShowTopHud
        )
        Settings.CreateCheckbox(category, thSetting, (L and L.SHOW_TOP_HUD_TOOLTIP) or "")
        local tbSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowTutorialBookVariableName,
            type(DEFAULT_SHOW_TUTORIAL_BOOK),
            (L and L.SHOW_TUTORIAL_BOOK_LABEL) or "Tutorial book icon",
            DEFAULT_SHOW_TUTORIAL_BOOK,
            getShowTutorialBook,
            setShowTutorialBook
        )
        Settings.CreateCheckbox(category, tbSetting, (L and L.SHOW_TUTORIAL_BOOK_TOOLTIP) or "")
        local seSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.SoundEnabledVariableName,
            type(DEFAULT_SOUND_ENABLED),
            (L and L.SOUND_ENABLED_LABEL) or "Overlord sounds",
            DEFAULT_SOUND_ENABLED,
            getSoundEnabled,
            setSoundEnabled
        )
        Settings.CreateCheckbox(category, seSetting, (L and L.SOUND_ENABLED_TOOLTIP) or "")
        local wdSetting = Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.WorldDefenseEnabledVariableName,
            type(DEFAULT_WORLD_DEFENSE_ENABLED),
            (L and L.WORLD_DEFENSE_ENABLED_LABEL) or "World Defense relay",
            DEFAULT_WORLD_DEFENSE_ENABLED,
            getWorldDefenseEnabled,
            setWorldDefenseEnabled
        )
        Settings.CreateCheckbox(category, wdSetting,
            (L and L.WORLD_DEFENSE_ENABLED_TOOLTIP) or "")
    end
    Settings.RegisterAddOnCategory(category)
    Overlord.SettingsPanel._category = category
end

function Overlord.SettingsPanel:Register()
    if self._registered then return end
    if not Settings or not Settings.RegisterProxySetting then
        return
    end

    securecall(function()
        local category
        if Settings.RegisterCanvasLayoutCategory then
            local frame = Overlord.SettingsPanel:EnsureFrame()
            if frame then
                category = Settings.RegisterCanvasLayoutCategory(frame, "Overlord")
            end
        end

        if not category and Settings.RegisterVerticalLayoutCategory and Settings.CreateSlider then
            RegisterVerticalFallback()
            Overlord.SettingsPanel._registered = true
            return
        end
        if not category then return end

        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.UiScaleVariableName,
            type(DEFAULT_SCALE),
            (L and L.UI_SCALE_LABEL) or "Panel scale",
            DEFAULT_SCALE,
            getScale,
            setScale
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.NotificationChatVariableName,
            type(DEFAULT_NOTIF_CHAT),
            (L and L.NOTIFICATION_CHAT_LABEL) or "Notification chat tab",
            DEFAULT_NOTIF_CHAT,
            getNotificationChat,
            setNotificationChat
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.MapOverlayOpacityVariableName,
            type(DEFAULT_MAP_OVERLAY_OPACITY),
            (L and L.MAP_OVERLAY_OPACITY_LABEL) or "Map capture opacity",
            DEFAULT_MAP_OVERLAY_OPACITY,
            getMapOverlayOpacity,
            setMapOverlayOpacity
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.MinimapOverlayOpacityVariableName,
            type(DEFAULT_MINIMAP_OVERLAY_OPACITY),
            (L and L.MINIMAP_OVERLAY_OPACITY_LABEL) or "Minimap capture opacity",
            DEFAULT_MINIMAP_OVERLAY_OPACITY,
            getMinimapOverlayOpacity,
            setMinimapOverlayOpacity
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.MapPathOpacityVariableName,
            type(DEFAULT_MAP_PATH_OPACITY),
            (L and L.MAP_PATH_OPACITY_LABEL) or "Map path opacity",
            DEFAULT_MAP_PATH_OPACITY,
            getMapPathOpacity,
            setMapPathOpacity
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMinimapButtonVariableName,
            type(DEFAULT_SHOW_MINIMAP_BUTTON),
            (L and L.MINIMAP_BUTTON_LABEL) or "Minimap button",
            DEFAULT_SHOW_MINIMAP_BUTTON,
            getShowMinimapButton,
            setShowMinimapButton
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMinimapCaptureZonesVariableName,
            type(DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES),
            (L and L.MINIMAP_CAPTURE_ZONES_LABEL) or "Minimap capture zones",
            DEFAULT_SHOW_MINIMAP_CAPTURE_ZONES,
            getShowMinimapCaptureZones,
            setShowMinimapCaptureZones
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowMapZoneTitlesVariableName,
            type(DEFAULT_SHOW_MAP_ZONE_TITLES),
            (L and L.MAP_ZONE_TITLES_LABEL) or "Map zone names",
            DEFAULT_SHOW_MAP_ZONE_TITLES,
            getShowMapZoneTitles,
            setShowMapZoneTitles
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.AutoWaypointVariableName,
            type(DEFAULT_AUTO_WAYPOINT),
            (L and L.AUTO_WAYPOINT_LABEL) or "Auto-pin next objective",
            DEFAULT_AUTO_WAYPOINT,
            getAutoWaypoint,
            setAutoWaypoint
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowTopHudVariableName,
            type(DEFAULT_SHOW_TOP_HUD),
            (L and L.SHOW_TOP_HUD_LABEL) or "Top HUD",
            DEFAULT_SHOW_TOP_HUD,
            getShowTopHud,
            setShowTopHud
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.ShowTutorialBookVariableName,
            type(DEFAULT_SHOW_TUTORIAL_BOOK),
            (L and L.SHOW_TUTORIAL_BOOK_LABEL) or "Tutorial book icon",
            DEFAULT_SHOW_TUTORIAL_BOOK,
            getShowTutorialBook,
            setShowTutorialBook
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.SoundEnabledVariableName,
            type(DEFAULT_SOUND_ENABLED),
            (L and L.SOUND_ENABLED_LABEL) or "Overlord sounds",
            DEFAULT_SOUND_ENABLED,
            getSoundEnabled,
            setSoundEnabled
        )
        Settings.RegisterProxySetting(
            category,
            Overlord.SettingsPanel.WorldDefenseEnabledVariableName,
            type(DEFAULT_WORLD_DEFENSE_ENABLED),
            (L and L.WORLD_DEFENSE_ENABLED_LABEL) or "World Defense relay",
            DEFAULT_WORLD_DEFENSE_ENABLED,
            getWorldDefenseEnabled,
            setWorldDefenseEnabled
        )

        Settings.RegisterAddOnCategory(category)
        Overlord.SettingsPanel._category = category
        Overlord.SettingsPanel._registered = true
    end)
end

function Overlord.SettingsPanel:SyncUiScaleWithSettingsAPI()
    if not Settings then return end
    local v = Overlord.UI and Overlord.UI.GetEffectiveUiScale and Overlord.UI:GetEffectiveUiScale()
    if not v then return end
    notifySettingsAPI(self.UiScaleVariableName, clampScale(v))
    self:RefreshControls()
end

function Overlord.SettingsPanel:IsOpen()
    local panel = _G.SettingsPanel
    if not panel or not panel.IsShown or not panel:IsShown() then
        return false
    end
    local f = self._frame
    return f and f.IsShown and f:IsShown()
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
