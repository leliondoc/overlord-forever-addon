-- 2.5.1: the action bar shortcut shows the Overlord logo as a layer of our own over the button's
-- icon. Before, the logo was written into the game's own icon texture: the game repaints that
-- icon when the mouse passes over the button, and the macro's own icon (a faction banner) came
-- back until the next event.
local now = 100
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end; return t end
function InCombatLockdown() return false end
function IsInInstance() return false end
function UnitFactionGroup() return "Alliance" end
MAX_ACCOUNT_MACROS, MAX_CHARACTER_MACROS = 4, 2
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end
local onEvent
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end }
end

-- The macros and the action slots of the game.
local macros = {}
function GetMacroInfo(index)
    local m = macros[index]
    if m then return m.name, m.icon, m.body end
end
function GetMacroIndexByName(name)
    for index, m in pairs(macros) do if m.name == name then return index end end
    return 0
end
function CreateMacro(name, icon, body) macros[5] = { name = name, icon = icon, body = body }; return 5 end
function EditMacro(index, name, icon, body)
    macros[index] = { name = name or macros[index].name, icon = icon, body = body or macros[index].body }
    return index
end
local picked
function PickupMacro(index) picked = index end
local slots = {}
function GetActionInfo(slot)
    local held = slots[slot]
    if held then return held[1], held[2] end
end

-- An action button of the game: its own icon texture, and the textures an addon creates on it.
local function texture(owner)
    local t = { shown = true, owner = owner }
    function t:SetTexture(value) self.texture = value end
    function t:SetTexCoord() end
    function t:SetAllPoints(region) self.over = region end
    function t:GetDrawLayer() return "BACKGROUND", 0 end
    function t:AddMaskTexture(mask) self.mask = mask end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:IsShown() return self.shown end
    return t
end
local function actionButton(name, slot)
    local button = { action = slot, made = {} }
    button.icon = texture(button)
    button.IconMask = { mask = true }
    function button:CreateTexture(_, layer, _, sub)
        local t = texture(self)
        t.layer, t.sub = layer, sub
        self.made[#self.made + 1] = t
        return t
    end
    function button:GetName() return name end
    _G[name] = button
    return button
end
local one, two = actionButton("ActionButton1", 1), actionButton("ActionButton2", 2)

Overlord = { L = {}, PrintNotification = function() end }
assert(loadfile("ActionShortcut.lua"))()
local shortcut = Overlord.ActionShortcut
local LOGO = "Interface\\AddOns\\Overlord\\Textures\\overlord_minimap"
local function keysOf(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local keysBefore = keysOf(one)

-- 1. Picking the shortcut up creates its macro; the macro's own icon is a banner of the game.
assert(shortcut:Pickup() == true and picked == 5 and macros[5].body == "/overlord toggle", "the shortcut was not picked up")
assert(macros[5].icon == "Interface\\Icons\\Ability_DualWield", "the macro's own icon is not the crossed swords: " .. tostring(macros[5].icon))
-- A macro made by an earlier version holds a faction banner: repaired to the swords, once.
macros[5].icon = "Interface\\Icons\\INV_BannerPVP_02"
local edits, realEdit = 0, EditMacro
EditMacro = function(...) edits = edits + 1 return realEdit(...) end
onEvent(nil, "PLAYER_ENTERING_WORLD")
runTimers()
assert(macros[5].icon == "Interface\\Icons\\Ability_DualWield" and edits == 1, "an older macro's banner was not replaced once")
onEvent(nil, "PLAYER_REGEN_ENABLED")
runTimers()
assert(edits == 1, "the macro was written again without need")
EditMacro = realEdit

-- 2. Dropped on a button: our layer shows the logo over the button's icon; the icon is the game's.
slots[1] = { "macro", 5 }
one.icon:SetTexture("the macro's banner")
onEvent(nil, "ACTIONBAR_SLOT_CHANGED")
runTimers()
assert(#one.made == 1 and one.made[1].texture == LOGO and one.made[1].shown, "no logo layer on the button holding the shortcut")
assert(one.made[1].over == one.icon and one.made[1].layer == "BACKGROUND" and one.made[1].sub == 1
    and one.made[1].mask == one.IconMask, "the layer is not laid just over the icon, under its mask")
assert(one.icon.texture == "the macro's banner", "the game's own icon texture was written")
assert(keysOf(one) == keysBefore, "a field was written on the game's button")
assert(#two.made == 0, "a button that does not hold the shortcut got a layer")

-- 3. The game repaints its icon (the mouse passes over the button): the logo is still there.
one.icon:SetTexture("the macro's banner, repainted")
assert(one.made[1].shown and one.made[1].texture == LOGO, "the logo left when the game repainted its icon")
-- Another event: no second layer on the same button.
onEvent(nil, "ACTIONBAR_SHOWGRID")
runTimers()
assert(#one.made == 1 and one.made[1].shown, "a second layer was made, or the layer was hidden")

-- 4. The shortcut moves to the other button: the layer follows it.
slots[1], slots[2] = { "spell", 133 }, { "macro", 5 }
onEvent(nil, "ACTIONBAR_SLOT_CHANGED")
runTimers()
assert(not one.made[1].shown, "the logo stayed on a button that holds something else")
assert(#two.made == 1 and two.made[1].shown, "the logo did not follow the shortcut")

-- 5. The macro is deleted: no button shows the logo.
macros[5] = nil
onEvent(nil, "UPDATE_MACROS")
runTimers()
assert(not two.made[1].shown and not one.made[1].shown, "the logo stayed after the macro was deleted")

-- 6. In an instance nothing is touched.
macros[5] = { name = "Overlord", icon = 1, body = "/overlord toggle" }
IsInInstance = function() return true end
onEvent(nil, "UPDATE_MACROS")
runTimers()
assert(not two.made[1].shown, "the buttons were swept in an instance")
IsInInstance = function() return false end
shortcut:OnInstanceResume()
runTimers()
assert(two.made[1].shown, "the logo did not come back after the instance")

-- 7. In an instance the slot gets something else: our layer leaves (the game's repaint does not cover it).
IsInInstance = function() return true end
slots[2] = { "spell", 133 }
onEvent(nil, "ACTIONBAR_SLOT_CHANGED")
runTimers()
assert(not two.made[1].shown, "the logo stayed over another action in an instance")
assert(#one.made == 1 and not one.made[1].shown, "an instance event showed a layer")
IsInInstance = function() return false end

print("Action shortcut: the logo is our own layer over the button, kept through the game's repaints")
