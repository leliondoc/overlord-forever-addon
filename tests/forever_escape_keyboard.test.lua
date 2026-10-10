-- Overlord windows close with ESC without swallowing the game's keys. Keyboard
-- propagation is protected in combat: the dialogs, the quick guide, the Hall of Fame
-- and the Discord popup changed it on every key press, even in combat (one
-- ADDON_ACTION_BLOCKED per key), and a window shown in combat with propagation off
-- swallowed movement and spells. Overlord.UI.BindEscapeClose (UIShared.lua).
local combat = false
function InCombatLockdown() return combat end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local list = timers
    timers = {}
    for _, fn in ipairs(list) do fn() end
end
local frame = { shown = false, scripts = {}, hooks = {}, keyboard = false, propagate = false }
function frame:SetScript(event, fn) self.scripts[event] = fn end
function frame:HookScript(event, fn)
    self.hooks[event] = self.hooks[event] or {}
    table.insert(self.hooks[event], fn)
end
local function fire(event, ...)
    if frame.scripts[event] then frame.scripts[event](frame, ...) end
    for _, fn in ipairs(frame.hooks[event] or {}) do fn(frame, ...) end
end
function frame:EnableKeyboard(on)
    assert(not combat, "EnableKeyboard changed in combat")
    self.keyboard = on
end
function frame:SetPropagateKeyboardInput(on)
    assert(not combat, "keyboard propagation changed in combat (ADDON_ACTION_BLOCKED)")
    self.propagate = on
end
function frame:IsShown() return self.shown end
function frame:Show() self.shown = true; fire("OnShow") end
function frame:Hide() self.shown = false; fire("OnHide") end
local function press(key) if frame.keyboard then frame.scripts.OnKeyDown(frame, key) end end

Overlord = {}
assert(loadfile("UIShared.lua"))()
local closed = 0
Overlord.UI.BindEscapeClose(frame, function(self) closed = closed + 1; self:Hide() end)
assert(frame.keyboard and frame.propagate, "an out-of-combat window did not take the keyboard with propagation on")

-- Out of combat: ESC closes and is not passed to the game menu; other keys go to the game.
frame:Show()
press("W")
assert(frame.propagate, "a movement key was swallowed")
press("ESCAPE")
assert(closed == 1 and not frame.shown and not frame.propagate, "ESC did not close the window, or reached the game menu")
runTimers()
assert(frame.propagate, "a closed window kept swallowing keys")

-- In combat: keys never touch the protected setting; ESC still closes.
frame:Show()
combat = true
press("W")
press("ESCAPE")
assert(closed == 2 and not frame.shown, "ESC did not close the window in combat")
runTimers()
-- Shown again in combat after an ESC close: propagation is still on, keys reach the game.
frame:Show()
assert(frame.propagate, "a window shown in combat swallowed the game's keys")
press("W")
frame:Hide()
combat = false
runTimers()

-- A window created in combat takes the keyboard on its first show out of combat.
local created = { shown = false, scripts = {}, hooks = {}, keyboard = false, propagate = false }
setmetatable(created, { __index = frame })
frame = created
combat = true
Overlord.UI.BindEscapeClose(frame, function(self) self:Hide() end)
assert(not frame.keyboard, "a window created in combat took the keyboard")
combat = false
frame:Show()
assert(frame.keyboard and frame.propagate, "the first show out of combat did not take the keyboard")
print("Escape keyboard: ESC closes, game keys pass, nothing protected changed in combat, combat-created windows OK")
