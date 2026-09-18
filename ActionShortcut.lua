-- ActionShortcut.lua - Raccourci Overlord glissable vers les barres d'action
Overlord = Overlord or {}
Overlord.ActionShortcut = {}

local L = Overlord.L

local ICON_TEXTURE = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
local ALLIANCE_MACRO_ICON = "Interface\\Icons\\INV_BannerPVP_02"
local HORDE_MACRO_ICON = "Interface\\Icons\\INV_BannerPVP_01"
local MACRO_BODY = "/overlord toggle"
local MACRO_NAME = "Overlord"
local MACRO_NAME_FALLBACK = "Overlord Panel"

local ACTION_BUTTON_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

local function Notify(message)
    if not message or message == "" then return end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. message)
    elseif print then
        print("Overlord: " .. message)
    end
end

local function IsInCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function NormalizeMacroBody(body)
    if type(body) ~= "string" then return "" end
    return (body:gsub("%s+$", ""))
end

local function IsShortcutMacro(name, body)
    if type(name) ~= "string" or not name:match("^Overlord") then return false end
    return NormalizeMacroBody(body) == MACRO_BODY
end

local function GetMacro(index)
    if type(GetMacroInfo) ~= "function" then return nil end
    local ok, name, icon, body = pcall(GetMacroInfo, index)
    if not ok then return nil end
    return name, icon, body
end

local shortcutMacroCacheValid = false
local shortcutMacroIndices = {}
local firstShortcutMacroIndex
local firstShortcutMacroName
local firstShortcutMacroIcon

local function InvalidateShortcutMacroCache()
    shortcutMacroCacheValid = false
end

local function RefreshShortcutMacroCache()
    if shortcutMacroCacheValid then return firstShortcutMacroIndex end
    wipe(shortcutMacroIndices)
    firstShortcutMacroIndex = nil
    firstShortcutMacroName = nil
    firstShortcutMacroIcon = nil
    local accountMax = tonumber(MAX_ACCOUNT_MACROS) or 120
    local characterMax = tonumber(MAX_CHARACTER_MACROS) or 18
    for index = 1, accountMax + characterMax do
        local name, icon, body = GetMacro(index)
        if IsShortcutMacro(name, body) then
            shortcutMacroIndices[index] = true
            if not firstShortcutMacroIndex then
                firstShortcutMacroIndex = index
                firstShortcutMacroName = name
                firstShortcutMacroIcon = icon
            end
        end
    end
    shortcutMacroCacheValid = true
    return firstShortcutMacroIndex
end

local function FindExistingShortcut()
    RefreshShortcutMacroCache()
    return firstShortcutMacroIndex, firstShortcutMacroName, firstShortcutMacroIcon
end

local function IsMacroNameAvailable(name)
    if type(GetMacroIndexByName) ~= "function" then return false end
    local ok, index = pcall(GetMacroIndexByName, name)
    return ok and (not index or index == 0)
end

local function FindAvailableMacroName()
    if IsMacroNameAvailable(MACRO_NAME) then return MACRO_NAME end
    if IsMacroNameAvailable(MACRO_NAME_FALLBACK) then return MACRO_NAME_FALLBACK end
    for suffix = 2, 99 do
        local candidate = "Overlord " .. suffix
        if IsMacroNameAvailable(candidate) then return candidate end
    end
    return nil
end

local function CanUseMacroAPI()
    return type(CreateMacro) == "function"
        and type(PickupMacro) == "function"
        and type(GetMacroInfo) == "function"
        and type(GetMacroIndexByName) == "function"
end

local function ResolveMacroIcon()
    -- Les macros n'acceptent pas de facon fiable une texture situee dans le
    -- dossier d'un addon. Un etendard Blizzard evite donc le point d'interrogation
    -- sur les barres tierces; les boutons Blizzard recoivent le logo exact plus bas.
    local faction = type(UnitFactionGroup) == "function" and UnitFactionGroup("player")
    local iconPath = faction == "Horde" and HORDE_MACRO_ICON or ALLIANCE_MACRO_ICON
    if type(GetFileIDFromPath) == "function" then
        local ok, fileID = pcall(GetFileIDFromPath, iconPath)
        if ok and type(fileID) == "number" and fileID > 0 then return fileID end
    end
    return iconPath
end

local function GetButtonIcon(button)
    if not button then return nil end
    if button.icon and button.icon.SetTexture then return button.icon end
    if button.Icon and button.Icon.SetTexture then return button.Icon end
    local name = button.GetName and button:GetName()
    local icon = name and _G[name .. "Icon"]
    if icon and icon.SetTexture then return icon end
    return nil
end

local function GetButtonAction(button)
    if not button then return nil end
    if type(ActionButton_GetPagedID) == "function" then
        local ok, action = pcall(ActionButton_GetPagedID, button)
        if ok and type(action) == "number" then return action end
    end
    local action = tonumber(button.action)
    if not action and button.GetAttribute then
        action = tonumber(button:GetAttribute("action"))
    end
    return action
end

local function IsShortcutActionButton(button)
    if not button or type(GetActionInfo) ~= "function" then return end
    if not RefreshShortcutMacroCache() then return end
    local action = GetButtonAction(button)
    if type(action) ~= "number" then return end

    local ok, actionType, macroIndex = pcall(GetActionInfo, action)
    if not ok or actionType ~= "macro" or type(macroIndex) ~= "number" then return end
    return shortcutMacroIndices[macroIndex] == true
end

local function SetOverlordTexture(icon)
    if not icon or icon._overlordSettingTexture then return end
    icon._overlordSettingTexture = true
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0, 1, 0, 1)
    icon._overlordSettingTexture = nil
end

local function ApplyShortcutIconToActionButton(button)
    if not IsShortcutActionButton(button) then return end

    local icon = GetButtonIcon(button)
    if not icon then return end
    SetOverlordTexture(icon)
end

local function SafeApplyShortcutIcon(button)
    if not RefreshShortcutMacroCache() then return end
    pcall(ApplyShortcutIconToActionButton, button)
end

local function RefreshActionButtonIcons()
    if not RefreshShortcutMacroCache() then return end
    for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
        for index = 1, 12 do
            SafeApplyShortcutIcon(_G[prefix .. index])
        end
    end
end

function Overlord.ActionShortcut:GetIconTexture()
    return ICON_TEXTURE
end

function Overlord.ActionShortcut:GetMacroBody()
    return MACRO_BODY
end

function Overlord.ActionShortcut:EnsureMacro()
    if IsInCombat() then
        Notify((L and L.ACTION_SHORTCUT_COMBAT) or "The action bar shortcut cannot be created during combat.")
        return nil
    end
    if not CanUseMacroAPI() then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return nil
    end

    local index, name, icon = FindExistingShortcut()
    if index then
        if icon ~= ResolveMacroIcon() and type(EditMacro) == "function" then
            pcall(EditMacro, index, name, ResolveMacroIcon(), MACRO_BODY)
        end
        return index
    end

    name = FindAvailableMacroName()
    if not name then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return nil
    end

    -- Macro propre au personnage : elle n'encombre pas les macros generales du compte.
    local ok, createdIndex = pcall(CreateMacro, name, ResolveMacroIcon(), MACRO_BODY, true)
    if not ok or not createdIndex then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return nil
    end
    InvalidateShortcutMacroCache()
    RefreshShortcutMacroCache()
    return createdIndex
end

local function RepairExistingShortcutMacroIcon()
    if IsInCombat() or type(EditMacro) ~= "function" then return false end
    local index, name, icon = FindExistingShortcut()
    if not index then return false end

    local desiredIcon = ResolveMacroIcon()
    if icon == desiredIcon then return true end
    local ok, editedIndex = pcall(EditMacro, index, name, desiredIcon, MACRO_BODY)
    if not ok or not editedIndex then return false end

    InvalidateShortcutMacroCache()
    RefreshShortcutMacroCache()
    return true
end

function Overlord.ActionShortcut:Pickup()
    local index = self:EnsureMacro()
    if not index then return false end

    local ok = pcall(PickupMacro, index)
    if not ok then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return false
    end
    return true
end

function Overlord.ActionShortcut:CreateSettingsRow(parent, opts)
    opts = opts or {}
    local rowW = opts.width or 460
    local rowH = opts.height or 58
    local gold = opts.gold or { 0.85, 0.68, 0.20 }
    local white = opts.white or { 1, 1, 1 }

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(rowW, rowH)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -6)
    row.title:SetWidth(rowW - 62)
    row.title:SetJustifyH("LEFT")
    row.title:SetText((L and L.ACTION_SHORTCUT_LABEL) or "Action bar shortcut")
    row.title:SetTextColor(gold[1], gold[2], gold[3])

    row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.desc:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
    row.desc:SetWidth(rowW - 62)
    row.desc:SetJustifyH("LEFT")
    row.desc:SetWordWrap(true)
    row.desc:SetMaxLines(2)
    row.desc:SetText((L and L.ACTION_SHORTCUT_DESC)
        or "Press and drag the Overlord icon onto an action bar to open or close the panel.")

    local button = CreateFrame("Button", nil, row, "BackdropTemplate")
    button:SetSize(42, 42)
    button:SetPoint("RIGHT", row, "RIGHT", -2, -1)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    button:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
    button:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.95)
    button:EnableMouse(true)
    if button.SetMouseClickEnabled then button:SetMouseClickEnabled(true) end
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 5, -5)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -5, 5)
    icon:SetTexture(ICON_TEXTURE)
    icon:SetTexCoord(0, 1, 0, 1)
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(icon)
    highlight:SetColorTexture(white[1], white[2], white[3], 0.18)

    -- La prise au MouseDown est immediate et reste fiable dans le ScrollFrame des options.
    -- OnDragStart reste en secours pour les clients qui ne propagent pas MouseDown ici.
    button:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        self._olPickupAttempted = true
        Overlord.ActionShortcut:Pickup()
    end)
    button:SetScript("OnMouseUp", function(self, mouseButton)
        if mouseButton == "LeftButton" then self._olPickupAttempted = false end
    end)
    button:SetScript("OnDragStart", function(self)
        if not self._olPickupAttempted then
            self._olPickupAttempted = true
            Overlord.ActionShortcut:Pickup()
        end
    end)
    button:SetScript("OnDragStop", function(self)
        self._olPickupAttempted = false
    end)
    button:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(white[1], white[2], white[3], 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((L and L.ACTION_SHORTCUT_LABEL) or "Action bar shortcut",
            gold[1], gold[2], gold[3], 1, true)
        GameTooltip:AddLine((L and L.ACTION_SHORTCUT_TOOLTIP)
            or "Press and drag this icon to an action bar. A click also picks it up. This creates one character-specific macro named Overlord.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(gold[1], gold[2], gold[3], 0.95)
        GameTooltip:Hide()
    end)

    row.shortcutButton = button
    function row:SetLayoutWidth(width)
        rowW = width
        self:SetWidth(width)
        self.title:SetWidth(width - 62)
        self.desc:SetWidth(width - 62)
    end

    return row
end

-- Depuis Midnight, la barre Blizzard repeint ses boutons via la methode du mixin
-- et non plus necessairement via les anciennes fonctions globales. Une seule fin
-- de chaine suffit; les clients plus anciens gardent le repli historique.
local actionButtonUpdateHookTarget
local actionButtonUpdateHookName
if type(ActionBarActionButtonMixin) == "table"
    and type(ActionBarActionButtonMixin.Update) == "function" then
    actionButtonUpdateHookTarget = ActionBarActionButtonMixin
    actionButtonUpdateHookName = "Update"
elseif type(ActionButton_UpdateIcon) == "function" then
    actionButtonUpdateHookName = "ActionButton_UpdateIcon"
elseif type(ActionButton_UpdateAction) == "function" then
    actionButtonUpdateHookName = "ActionButton_UpdateAction"
elseif type(ActionButton_Update) == "function" then
    actionButtonUpdateHookName = "ActionButton_Update"
end
if actionButtonUpdateHookName and type(hooksecurefunc) == "function" then
    local hookArgs
    if actionButtonUpdateHookTarget then
        hookArgs = { actionButtonUpdateHookTarget, actionButtonUpdateHookName, SafeApplyShortcutIcon }
    else
        hookArgs = { actionButtonUpdateHookName, SafeApplyShortcutIcon }
    end
    hooksecurefunc(unpack(hookArgs))
end

local actionIconEventFrame = CreateFrame("Frame")
actionIconEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
actionIconEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
actionIconEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
actionIconEventFrame:RegisterEvent("UPDATE_MACROS")
actionIconEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local actionIconRefreshPending = false
local function ScheduleActionButtonIconRefresh()
    if actionIconRefreshPending then return end
    actionIconRefreshPending = true
    C_Timer.After(0, function()
        actionIconRefreshPending = false
        RefreshActionButtonIcons()
    end)
end

actionIconEventFrame:SetScript("OnEvent", function(_, event)
    if event == "UPDATE_MACROS" or event == "PLAYER_ENTERING_WORLD" then
        InvalidateShortcutMacroCache()
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
        RepairExistingShortcutMacroIcon()
    end
    ScheduleActionButtonIconRefresh()
end)
