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

-- Icon value the client reported right after our own EditMacro. If the client stores
-- the icon in another form than the one we pass (fileID vs path), the plain compare
-- would stay unequal and rewrite the macro at every combat end; a macro still holding
-- this value is already repaired. A hand-set icon differs from both and is repaired once.
-- Kept per desired icon: a faction read late at login still gets its own banner.
local repairedMacroIcon, repairedForIcon

local function MacroIconNeedsRepair(icon, desiredIcon)
    if icon == desiredIcon then return false end
    return repairedMacroIcon == nil or repairedForIcon ~= desiredIcon or icon ~= repairedMacroIcon
end

-- Rescans after our own edit (as before) and remembers the value the client now reports.
local function RememberRepairedMacroIcon(desiredIcon)
    InvalidateShortcutMacroCache()
    RefreshShortcutMacroCache()
    if firstShortcutMacroIcon ~= nil then
        repairedMacroIcon, repairedForIcon = firstShortcutMacroIcon, desiredIcon
    end
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

-- Button names built once; _G is still read per sweep so lazily created bars are found.
local ACTION_BUTTON_NAMES = {}
for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
    for index = 1, 12 do
        ACTION_BUTTON_NAMES[#ACTION_BUTTON_NAMES + 1] = prefix .. index
    end
end

local function RefreshActionButtonIcons()
    if not RefreshShortcutMacroCache() then return end
    for i = 1, #ACTION_BUTTON_NAMES do
        local button = _G[ACTION_BUTTON_NAMES[i]]
        if button then pcall(ApplyShortcutIconToActionButton, button) end
    end
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
        local desiredIcon = ResolveMacroIcon()
        if MacroIconNeedsRepair(icon, desiredIcon) and type(EditMacro) == "function" then
            local ok, editedIndex = pcall(EditMacro, index, name, desiredIcon, MACRO_BODY)
            if ok and editedIndex then RememberRepairedMacroIcon(desiredIcon) end
        end
        return index
    end

    name = FindAvailableMacroName()
    if not name then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return nil
    end

    -- Macro propre au personnage : elle n'encombre pas les macros generales du compte.
    local desiredIcon = ResolveMacroIcon()
    local ok, createdIndex = pcall(CreateMacro, name, desiredIcon, MACRO_BODY, true)
    if not ok or not createdIndex then
        Notify((L and L.ACTION_SHORTCUT_FAILED) or "Unable to create the action bar shortcut.")
        return nil
    end
    -- No shortcut existed before: the first one found now is the macro just created.
    RememberRepairedMacroIcon(desiredIcon)
    return createdIndex
end

local function RepairExistingShortcutMacroIcon()
    if Overlord.InstanceSuspended or IsInCombat() or type(EditMacro) ~= "function" then return false end
    local index, name, icon = FindExistingShortcut()
    if not index then return false end

    local desiredIcon = ResolveMacroIcon()
    if not MacroIconNeedsRepair(icon, desiredIcon) then return true end
    local ok, editedIndex = pcall(EditMacro, index, name, desiredIcon, MACRO_BODY)
    if not ok or not editedIndex then return false end

    RememberRepairedMacroIcon(desiredIcon)
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

-- 2.0 : plus de hooksecurefunc sur la methode Update des boutons d'action de Blizzard.
-- Sur ce client, une methode d'un objet de Blizzard enveloppee par un addon peut se
-- mettre a lever « attempt to call a nil value » dans l'appelant de Blizzard jusqu'a
-- la relance du jeu (vu sur la carte du monde les 11 et 12 octobre 2026) : dans le code
-- des barres d'action, ce serait une erreur a chaque repeint. (Ce crochet ne servait
-- d'ailleurs a rien : les boutons de Blizzard recoivent leur propre copie de Update au
-- chargement, avant nous.) Le logo est repose sur les evenements ci-dessous. Blizzard
-- repeint aussi un bouton au survol et quand sa barre s'affiche, sans evenement : la
-- macro montre alors son icone d'etendard, jamais un point d'interrogation, jusqu'a
-- l'evenement suivant. Comme en 1.9.1.

local actionIconEventFrame = CreateFrame("Frame")
actionIconEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
actionIconEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
actionIconEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
actionIconEventFrame:RegisterEvent("UPDATE_MACROS")
actionIconEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Les autres repeints d'un bouton par Blizzard : changement de forme ou de barre,
-- grille montree pendant un glisser, icone d'un sort ou d'une macro qui change.
-- (pcall : un evenement absent de ce client ne doit pas empecher les autres.)
for _, event in ipairs({ "UPDATE_SHAPESHIFT_FORM", "UPDATE_BONUS_ACTIONBAR", "UPDATE_VEHICLE_ACTIONBAR",
    "UPDATE_OVERRIDE_ACTIONBAR", "ACTIONBAR_SHOWGRID", "ACTIONBAR_HIDEGRID", "SPELL_UPDATE_ICON" }) do
    pcall(actionIconEventFrame.RegisterEvent, actionIconEventFrame, event)
end

local actionIconRefreshPending = false
local actionIconRepairPending = false

-- Runs one frame after the event. Every feature stops in instances: no macro edit (it
-- wakes every addon with UPDATE_MACROS) and no button sweep; the texture already on the
-- buttons stays. OnInstanceResume (also after a delayed resume) asks for both on exit.
local function RunActionButtonIconRefresh()
    actionIconRefreshPending = false
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        actionIconRepairPending = false
        return
    end
    if actionIconRepairPending then
        actionIconRepairPending = false
        RepairExistingShortcutMacroIcon()
    end
    RefreshActionButtonIcons()
end

local function ScheduleActionButtonIconRefresh()
    if actionIconRefreshPending then return end
    actionIconRefreshPending = true
    C_Timer.After(0, RunActionButtonIconRefresh)
end

function Overlord.ActionShortcut:OnInstanceResume()
    InvalidateShortcutMacroCache()
    actionIconRepairPending = true
    ScheduleActionButtonIconRefresh()
end

actionIconEventFrame:SetScript("OnEvent", function(_, event)
    if event == "UPDATE_MACROS" or event == "PLAYER_ENTERING_WORLD" then
        InvalidateShortcutMacroCache()
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
        actionIconRepairPending = true
    end
    ScheduleActionButtonIconRefresh()
end)
