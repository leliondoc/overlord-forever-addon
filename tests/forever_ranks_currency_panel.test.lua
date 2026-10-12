-- Overlord Rank tab over Blizzard's Currency panel: real RanksUI.lua on stub frames.
-- The Currency panel's own hide script resets the selected currency. Run from an addon
-- it would mark those fields, which the currency transfer between characters (a
-- function reserved to Blizzard's code) reads later: the game would refuse the transfer
-- until a reload. So the tab never hides nor shows that panel: it stays shown under our
-- panes, made invisible, its panes moved below the sheet so they stop answering the
-- mouse. Display settings only; every other panel is still hidden and put back.

local function check(cond, msg) if not cond then error(msg, 2) end end

Overlord = { L = {} }
GetLocale = function() return "enUS" end
dofile("RankLocales.lua")
Overlord.Sync = { GetPlayerFullName = function() return "Aldric Vane" end }
Overlord.PrintNotification = function() end
Overlord.PlayerFaction = "Alliance"
OverlordDB = {}
dofile("Ranks.lua")

-- Who is running: Blizzard's own code (its switch function, the sheet closing) or ours.
local blizzard = 0
local function asBlizzard(fn, ...)
    blizzard = blizzard + 1
    local ok, err = pcall(fn, ...)
    blizzard = blizzard - 1
    if not ok then error(err, 0) end
end

local function widget(kind, parent)
    local w = { _kind = kind, _shown = true, _scripts = {}, _alpha = 1, _strata = "MEDIUM", _fixed = false,
        _ignore = false, _kids = {}, _addonHides = 0, _addonShows = 0, _scriptRuns = 0 }
    if parent then parent._kids[#parent._kids + 1] = w end
    local methods = {}
    function methods:Show()
        if blizzard == 0 then self._addonShows = self._addonShows + 1 end
        local was = self._shown
        self._shown = true
        if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
    end
    function methods:Hide()
        if blizzard == 0 then self._addonHides = self._addonHides + 1 end
        local was = self._shown
        self._shown = false
        if was and self._scripts.OnHide then self._scripts.OnHide(self) end
    end
    function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
    function methods:IsShown() return self._shown end
    function methods:IsProtected() return false end
    function methods:SetScript(name, fn) self._scripts[name] = fn end
    function methods:HookScript(name, fn)
        local before = self._scripts[name]
        self._scripts[name] = function(...)
            if before then before(...) end
            return fn(...)
        end
    end
    function methods:GetChildren() return unpack(self._kids) end
    function methods:GetAlpha() return self._alpha end
    function methods:SetAlpha(alpha) self._alpha = alpha end
    function methods:GetFrameStrata() return self._strata end
    function methods:SetFrameStrata(strata)
        if self._refuseStrata then error("strata refused") end
        self._strata, self._fixed = strata, true
    end
    function methods:HasFixedFrameStrata() return self._fixed end
    function methods:SetFixedFrameStrata(fixed) self._unfixed = true; self._fixed = fixed end
    function methods:EnableMouseWheel(on) self._wheel = on end
    function methods:IsToplevel() return self._toplevel == true end
    function methods:IsIgnoringParentAlpha() return self._ignore end
    function methods:SetIgnoreParentAlpha(ignore) self._ignore = ignore end
    function methods:GetFrameLevel() return 1 end
    function methods:SetTexture(texture) self._texture = texture end
    function methods:SetText(text) self._text = text end
    function methods:CreateTexture() return widget("Texture") end
    function methods:CreateFontString() return widget("FontString") end
    function methods:CreateAnimationGroup() return widget("AnimationGroup") end
    return setmetatable(w, { __index = function(_, key)
        if methods[key] then return methods[key] end
        if type(key) == "string" and key:match("^%u") then return function() end end
        return nil
    end })
end

local login
CreateFrame = function(kind, _, _, template)
    local f = widget(kind)
    if template == "LargeSideTabButtonTemplate" then
        f.Icon = widget("Texture")
        f.SetChecked = function(self, checked) self._checked = checked end
        f.SetCustomOnMouseUpHandler = function(self, fn) self._click = fn end
    end
    f.RegisterEvent = function(self) login = self end
    return f
end
GameTooltip, UIParent = widget("GameTooltip"), widget("Frame")
GetTime = function() return 100 end
C_Timer = { After = function() end }
GameTooltip_Hide = function() end
NORMAL_FONT_COLOR, GameFontNormal = {}, {}
InCombatLockdown = function() return false end
UnitFactionGroup = function() return "Alliance" end
hooksecurefunc = function(_, name) error("a method of Blizzard's sheet was hooked: " .. tostring(name)) end

-- Blizzard's Currency panel as its XML builds it: the list, its bar and the detail pane
-- sit above the sheet (strata HIGH, fixed), the spinner follows its parent, and the
-- transfer log is a window of its own.
PaperDollFrame, ReputationFrame, TokenFrame = widget("Frame"), widget("Frame"), widget("Frame")
PaperDollFrame._shown, ReputationFrame._shown = false, false
local list, bar, detail = widget("Frame", TokenFrame), widget("Frame", TokenFrame), widget("Frame", TokenFrame)
for _, pane in ipairs({ list, bar, detail }) do pane._strata, pane._fixed = "HIGH", true end
local spinner, log = widget("Frame", TokenFrame), widget("Frame", TokenFrame)
log._toplevel, log._shown = true, false
-- Its hide script is the one that must never run from our code.
TokenFrame._scripts.OnHide = function(self) self._scriptRuns = self._scriptRuns + (blizzard == 0 and 1 or 0) end
TokenFrame._scripts.OnShow = TokenFrame._scripts.OnHide

CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "ReputationFrame", "TokenFrame" }
local function blizzardTab(frameName)
    local tab = widget("Frame")
    tab.frameName, tab.SelectedTexture = frameName, widget("Texture")
    return tab
end
CharacterFrame = widget("Frame")
CharacterFrame._shown = false
CharacterFrame.ModeTabs = widget("Frame")
CharacterFrame.ModeTabs.Tabs = { blizzardTab("PaperDollFrame"), blizzardTab("ReputationFrame"), blizzardTab("TokenFrame") }
CharacterFrame.LeftPaneHost, CharacterFrame.RightPaneHost = widget("Frame"), widget("Frame")
CharacterFrame.RightPaneHost.StoneBg = widget("Texture")
CharacterFrame.RightPaneToggleButton = widget("Button")
CharacterFrame.activeSubframe = "TokenFrame"
local portrait = widget("Texture")
CharacterFrame.GetPortrait = function() return portrait end
-- Blizzard's switch: it hides and shows its own panels itself.
CharacterFrame.ShowSubFrame = function(self, name)
    self.activeSubframe = name
    asBlizzard(function()
        for _, sub in ipairs(CHARACTERFRAME_SUBFRAMES) do if sub ~= name then _G[sub]:Hide() end end
        _G[name]:Show()
    end)
end

dofile("RanksUI.lua")
local UIR = Overlord.RanksUI
login._scripts.OnEvent(login)
asBlizzard(CharacterFrame.Show, CharacterFrame)
local tab = UIR.tab
check(tab and UIR.attached, "the tab comes with the sheet")

local function untouched(label)
    check(TokenFrame._addonHides == 0 and TokenFrame._addonShows == 0 and TokenFrame._scriptRuns == 0,
        label .. ": the Currency panel was hidden or shown by the addon")
end
local function restored(label)
    check(UIR.covered == nil and TokenFrame._alpha == 1, label .. ": the Currency panel is visible again")
    for name, pane in pairs({ list = list, bar = bar, detail = detail }) do
        check(pane._strata == "HIGH" and pane._fixed == true, label .. ": " .. name .. " is back above the sheet")
    end
    check(spinner._strata == "MEDIUM", label .. ": the spinner is back at its strata")
    -- Whatever the engine calls a "fixed" strata, nothing is ever made inherited again:
    -- a pane un-fixed by mistake would fall under the sheet.
    for _, pane in ipairs({ list, bar, detail, spinner, log }) do
        check(not pane._unfixed, label .. ": a pane's strata was made inherited")
    end
    check(UIR.left._wheel == false and UIR.right._wheel == false, label .. ": our panes still take the mouse wheel")
    check(log._ignore == false and log._strata == "MEDIUM" and log._fixed == false, label .. ": the transfer log as it was")
    untouched(label)
end

-- 1. Our tab over the Currency panel: covered, never hidden.
tab._click(tab, "LeftButton", true)
check(UIR.selected and UIR.left._shown and UIR.right._shown, "the rank panes open")
check(TokenFrame._shown and TokenFrame._alpha == 0, "the Currency panel stays shown, invisible")
check(list._strata == "BACKGROUND" and bar._strata == "BACKGROUND" and detail._strata == "BACKGROUND"
    and spinner._strata == "BACKGROUND", "its panes are below the sheet: deaf to the mouse")
check(log._strata == "MEDIUM" and log._ignore == true, "a window of its own is left as it is, visible")
check(UIR.left._wheel == true and UIR.right._wheel == true, "the wheel does not reach the invisible list under our panes")
untouched("selected")

-- 2. Blizzard switches to another panel by its own path: ours closes, everything is back.
CharacterFrame:ShowSubFrame("ReputationFrame")
check(not UIR.selected and not UIR.left._shown and ReputationFrame._shown and not TokenFrame._shown,
    "another panel closes ours; Blizzard hid its Currency panel itself")
restored("after Blizzard's switch")

-- 3. Back on Currency, our tab again, then a click on Blizzard's Currency tab: its panel
--    is already shown, so Blizzard shows nothing; ours closes and the panel reappears.
CharacterFrame:ShowSubFrame("TokenFrame")
tab._click(tab, "LeftButton", true)
check(UIR.selected and TokenFrame._alpha == 0, "covered again")
local currencyTab = CharacterFrame.ModeTabs.Tabs[3]
currencyTab._scripts.OnMouseUp(currencyTab, "LeftButton", true)
check(not UIR.selected and TokenFrame._shown, "a click on the Currency tab closes ours")
restored("after the Currency tab")

-- 4. The sheet closes on our tab: the panel is put back as it was, without a Show.
tab._click(tab, "LeftButton", true)
check(UIR.selected and TokenFrame._alpha == 0, "covered a third time")
asBlizzard(CharacterFrame.Hide, CharacterFrame)
check(not UIR.selected, "closing the sheet closes ours")
restored("after the sheet closed")

-- 5. An instance begins with our tab open over it.
asBlizzard(CharacterFrame.Show, CharacterFrame)
tab._click(tab, "LeftButton", true)
check(UIR.selected and TokenFrame._alpha == 0, "covered a fourth time")
Overlord.InstanceSuspended = true
UIR:OnInstanceSuspend()
check(not UIR.selected, "cut in an instance")
restored("in an instance")
Overlord.InstanceSuspended = false
UIR:OnInstanceResume()

-- 6. Every other panel is still hidden by its own Hide and put back when the sheet closes.
CharacterFrame:ShowSubFrame("ReputationFrame")
tab._click(tab, "LeftButton", true)
check(UIR.selected and not ReputationFrame._shown and ReputationFrame._addonHides == 1 and UIR.covered == nil,
    "the reputation panel is hidden, nothing is covered")
asBlizzard(CharacterFrame.Hide, CharacterFrame)
check(ReputationFrame._shown, "and it is put back")
untouched("over another panel")

-- 7. Safety net: a cover left behind is undone when the sheet opens with our tab closed.
UIR.covered = { frame = TokenFrame, alpha = 1, kids = { { frame = list, strata = "HIGH", fixed = true } } }
TokenFrame._alpha, list._strata = 0, "BACKGROUND"
asBlizzard(CharacterFrame.Show, CharacterFrame)
restored("safety net")

-- 8. A display setting refused: everything is put back and the panel is hidden like the
--    others (the tab must still open over an empty sheet).
CharacterFrame:ShowSubFrame("TokenFrame")
detail._refuseStrata = true
tab._click(tab, "LeftButton", true)
check(UIR.selected and UIR.covered == nil and not TokenFrame._shown and TokenFrame._alpha == 1
    and list._strata == "HIGH" and spinner._strata == "MEDIUM" and log._ignore == false,
    "a refused setting falls back to hiding, with nothing left changed")
detail._refuseStrata = nil

print("forever_ranks_currency_panel: ok")
