-- ActionShortcut.lua - Raccourci Overlord glissable vers les barres d'action
Overlord = Overlord or {}
Overlord.ActionShortcut = {}

local L = Overlord.L

local ICON_TEXTURE = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
-- 2.5.1: the macro's own icon, the one the game draws on the cursor while the shortcut is
-- dragged and in its macro window: crossed swords, the same for both factions. It was the
-- player's faction banner, which read as a bug during the drag. The game refuses an addon's
-- texture here: EditMacro with our logo leaves the macro without icon (checked in game on
-- 2026-11-11: GetMacroInfo returned nil for it).
local MACRO_ICON = "Interface\\Icons\\Ability_DualWield"
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
    -- Les macros n'acceptent pas une texture situee dans le dossier d'un addon. Une icone
    -- de Blizzard evite donc le point d'interrogation sur les barres tierces et pendant le
    -- glisser; les boutons Blizzard recoivent le logo exact plus bas.
    local iconPath = MACRO_ICON
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
-- Kept per desired icon: a macro made by an earlier version (a faction banner) is repaired once.
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

-- 2.5.1: the logo is a texture of our own laid over the button's icon, shown while the button
-- holds the shortcut. Before, the logo was written into the game's own icon: the game repaints
-- that icon whenever the mouse passes over the button (and when its bar is shown), without any
-- event, so the macro's own icon (one of the game's: a macro cannot hold an addon's texture)
-- came back until the next event. Our layer is not the game's to repaint. Kept in a table of
-- ours (weak keys), nothing is written on the game's buttons.
local shortcutLayers = setmetatable({}, { __mode = "k" })

local function ShortcutLayer(button, create)
    local layer = shortcutLayers[button]
    if layer or not create then return layer end
    local icon = GetButtonIcon(button)
    if not icon or type(button.CreateTexture) ~= "function" then return nil end
    -- (Just above the icon, in its own draw layer: the cooldown, the border, the key text and
    -- the glow of the button stay above, as they are above the icon.)
    local drawLayer, sub = "BACKGROUND", 0
    if icon.GetDrawLayer then
        local ok, name, level = pcall(icon.GetDrawLayer, icon)
        if ok and type(name) == "string" then drawLayer, sub = name, tonumber(level) or 0 end
    end
    local ok, made = pcall(button.CreateTexture, button, nil, drawLayer, nil, math.min(7, sub + 1))
    if not ok or not made then return nil end
    layer = made
    layer:SetTexture(ICON_TEXTURE)
    layer:SetTexCoord(0, 1, 0, 1)
    layer:SetAllPoints(icon)
    -- (Where the game rounds the icon with a mask, ours is rounded by the same one.)
    local mask = button.IconMask
    if mask and layer.AddMaskTexture then pcall(layer.AddMaskTexture, layer, mask) end
    layer:Hide()
    shortcutLayers[button] = layer
    return layer
end

local function ApplyShortcutIconToActionButton(button)
    if IsShortcutActionButton(button) then
        local layer = ShortcutLayer(button, true)
        if layer then layer:Show() end
    else
        -- (The slot now holds something else, or nothing: its own icon shows again.)
        local layer = ShortcutLayer(button, false)
        if layer then layer:Hide() end
    end
end

-- Button names built once; _G is still read per sweep so lazily created bars are found.
local ACTION_BUTTON_NAMES = {}
for _, prefix in ipairs(ACTION_BUTTON_PREFIXES) do
    for index = 1, 12 do
        ACTION_BUTTON_NAMES[#ACTION_BUTTON_NAMES + 1] = prefix .. index
    end
end

local function RefreshActionButtonIcons()
    if not RefreshShortcutMacroCache() then
        -- (No shortcut macro any more: no button shows our layer.)
        for _, layer in pairs(shortcutLayers) do layer:Hide() end
        return
    end
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
-- macro montrait alors sa propre icone, jamais un point d'interrogation, jusqu'a
-- l'evenement suivant. Comme en 1.9.1.

local actionIconEventFrame = CreateFrame("Frame")
actionIconEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
actionIconEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
actionIconEventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
actionIconEventFrame:RegisterEvent("UPDATE_MACROS")
actionIconEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Les autres changements de ce qu'un bouton tient : changement de forme ou de barre,
-- grille montree pendant un glisser. (2.5.1 : plus SPELL_UPDATE_ICON. Le logo est une
-- texture a nous, qu'une icone de sort repeinte ne touche pas, et cet evenement tombe
-- sans cesse en combat : un balayage de 96 boutons a presque chaque image.)
-- (pcall : un evenement absent de ce client ne doit pas empecher les autres.)
for _, event in ipairs({ "UPDATE_SHAPESHIFT_FORM", "UPDATE_BONUS_ACTIONBAR", "UPDATE_VEHICLE_ACTIONBAR",
    "UPDATE_OVERRIDE_ACTIONBAR", "ACTIONBAR_SHOWGRID", "ACTIONBAR_HIDEGRID" }) do
    pcall(actionIconEventFrame.RegisterEvent, actionIconEventFrame, event)
end

local actionIconRefreshPending = false
local actionIconRepairPending = false

-- Runs one frame after the event. Every feature stops in instances: no macro edit (it
-- wakes every addon with UPDATE_MACROS) and no sweep of the bars. Only the buttons that
-- already carry our layer are looked at, to hide it where the slot now holds something
-- else (the layer is ours: the game's repaint no longer covers it, as it did before
-- 2.5.1). OnInstanceResume (also after a delayed resume) asks for the rest on exit.
local function RunActionButtonIconRefresh()
    actionIconRefreshPending = false
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then
        actionIconRepairPending = false
        for button, layer in pairs(shortcutLayers) do
            if layer:IsShown() and not IsShortcutActionButton(button) then layer:Hide() end
        end
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
