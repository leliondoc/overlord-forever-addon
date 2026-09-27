-- Exercise the real coin panel and spending transitions with painting stubs.
local methods = {}
local writes, timers = 0, 0
local function widget(parent)
    return setmetatable({ parent = parent, scripts = {}, shown = true, points = {} }, { __index = methods })
end
function CreateFrame(_, _, parent) return widget(parent) end
function UnitClass() return 'Warrior', 'WARRIOR' end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetHeight(h) self.height = h end
function methods:SetPoint(...) self.points[#self.points + 1] = {...} end
function methods:ClearAllPoints() self.points = {} end
function methods:CreateTexture() return widget(self) end
methods.CreateFontString = methods.CreateTexture
methods.CreateAnimationGroup = methods.CreateTexture
methods.CreateAnimation = methods.CreateTexture
function methods:GetFont() return 'font', 12 end
function methods:SetScript(event, fn) self.scripts[event] = fn end
function methods:GetScript(event) return self.scripts[event] end
function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function methods:Hide() self.shown = false end
function methods:Show()
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:SetText(text) self.text = text; writes = writes + 1 end
function methods:SetDesaturated(value) self.desaturated = value end
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') then return function() end end
end })
GameTooltip = {
    IsOwned = function() return false end,
    SetOwner = function() end, AddLine = function() end,
    Show = function() end, Hide = function() end,
}
C_Timer = { After = function() timers = timers + 1 end, NewTicker = function() timers = timers + 1 end }
Overlord = { L = {
    GOLD_COUNTER = "Coins : %d / %d", GOLD_BONUS_READY = "Prêt",
    GOLD_REINFORCE = "Attaquer", GOLD_BARRICADE = "Renforcer",
    GOLD_REINFORCE_SPENT = "Attack bought", GOLD_BARRICADE_SPENT = "Reinforce bought",
    GOLD_REINFORCE_ACTIVE = "Attack ready", GOLD_BARRICADE_ACTIVE = "Reinforce ready",
    GOLD_REINFORCE_USED = "Attack used", GOLD_BARRICADE_USED = "Reinforce used",
    GOLD_NOT_ENOUGH = "Need %d coins",
}, PrintNotification = function() end }
OverlordDB = { gold = 100 }
assert(loadfile('UIShared.lua'))()
assert(loadfile('Ressources.lua'))()
assert(loadfile('Popups.lua'))()
local res, popups = Overlord.Ressources, Overlord.Popups
res:RestoreResources()
local panel = popups:CreateFeaturedFrontCoinsPanel(widget())
panel:Show()
local reinforce, attack = panel.buttons[1], panel.buttons[2]
assert(panel.coinText.text:find('100 / 100', 1, true))
assert(reinforce._olCanSpend and attack._olCanSpend)
-- Both actions fit below the counter with a gap between the buttons.
assert(panel.width >= reinforce.width + attack.width + 8)
assert(panel.height >= attack.height + panel.coinText.height + 12)
assert(reinforce.points[1][1] == 'BOTTOMLEFT' and attack.points[1][1] == 'BOTTOMRIGHT')
attack.scripts.OnClick(attack)
assert(res:GetGold() == 75 and attack._olBonusActive and not attack._olCanSpend)
assert(attack.label.text:find('ReadyCheck-Ready', 1, true))
attack.scripts.OnClick(attack)
assert(res:GetGold() == 75, 'Ready bonus charged twice')
reinforce.scripts.OnClick(reinforce)
assert(res:GetGold() == 50 and reinforce._olBonusActive)
res:ConsumeReinforce()
popups:RefreshFeaturedFrontCoins(panel)
assert(attack._olCanSpend and not attack._olBonusActive and reinforce._olBonusActive,
    'Bonus consumed without changing gold left stale button state')
local unchanged = writes
for _ = 1, 100 do popups:RefreshFeaturedFrontCoins(panel) end
assert(writes == unchanged and timers == 0, 'Unchanged coins triggered painting or polling')
panel:Hide()
res:ResetResources()
popups:RefreshFeaturedFrontCoins(panel)
assert(writes == unchanged, 'Hidden coin panel was repainted')
panel:Show()
assert(not attack._olCanSpend and not reinforce._olCanSpend)
assert(panel.coinText.text:find('0 / 100', 1, true), 'Reopening did not refresh balance')
attack.scripts.OnClick(attack)
assert(res:GetGold() == 0, 'Unavailable action spent coins')
print('Featured coins: separate balance/actions, real purchases, consumption, hidden refresh and no polling OK')
