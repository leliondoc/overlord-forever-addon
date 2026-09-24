-- Exercise real UI initialization, drag handlers and restoration. Only painting
-- and the unrelated panel sections are mocked. The client layout cache is
-- restored between file loading and the deferred UI initialization.
local noop = function() end
local methods = {}
local function widget(name, parent)
    local frame = setmetatable({ name = name, parent = parent, scripts = {}, scale = 1,
        width = 1, height = 1, shown = true, userPlaced = false }, { __index = methods })
    if name then _G[name] = frame end
    return frame
end
function CreateFrame(_, name, parent) return widget(name, parent) end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetScale(s) self.scale = s end
function methods:GetScale() return self.scale end
function methods:GetEffectiveScale() return self.scale * (self.parent and self.parent:GetEffectiveScale() or 1) end
function methods:SetUserPlaced(v) self.userPlaced = v end
function methods:IsUserPlaced() return self.userPlaced end
function methods:SetDontSavePosition(v) self.dontSavePosition = v end
function methods:SetMovable(v) self.movable = v end
function methods:Hide() self.shown = false end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown end
function methods:SetScript(event, handler) self.scripts[event] = handler end
function methods:SetPoint(...) self.point = { ... } end
function methods:GetPoint() return (unpack or table.unpack)(self.point or {}) end
function methods:ClearAllPoints() self.point = nil end
function methods:StartMoving() self.moving = true; self:SetUserPlaced(true) end
function methods:StopMovingOrSizing() self.moving = false end
local offsets = { BOTTOMLEFT = {0, 0}, RIGHT = {1, 0.5}, LEFT = {0, 0.5} }
function methods:GetLeft()
    if not self.point then return nil end
    local point, _, relative, x = self:GetPoint()
    return (UIParent.width * offsets[relative][1] + x * self.scale
        - self.width * self.scale * offsets[point][1]) / self.scale
end
function methods:GetBottom()
    if not self.point then return nil end
    local point, _, relative, _, y = self:GetPoint()
    return (UIParent.height * offsets[relative][2] + y * self.scale
        - self.height * self.scale * offsets[point][2]) / self.scale
end
function methods:CreateTexture() return widget() end
methods.CreateFontString = methods.CreateTexture
methods.CreateMaskTexture = methods.CreateTexture
function methods:GetFont() return "font", 12 end
setmetatable(methods, { __index = function(_, key)
    if key:match("^Set") or key:match("^Register") or key:match("^Unregister")
        or key:match("^Enable") or key == "AddMaskTexture" or key == "HookScript" then
        return noop
    end
end })
UIParent = widget(nil)
UIParent.width, UIParent.height, UIParent.scale = 1920, 1080, 0.8
C_Timer = { After = noop }
hooksecurefunc, GameTooltip_Hide = noop, noop
local function close(a, b) assert(math.abs(a - b) < 0.00001, tostring(a) .. " != " .. tostring(b)) end
local function loadSession(db, cachedPoint)
    Overlord = { L = {}, PlayerFaction = "Alliance", UI = {
        ApplyWoodDialogBackdrop = noop, ApplyPerksHordeVsAllianceChrome = noop,
        CreateWC3CloseButton = function() return widget() end,
    } }
    OverlordDB, WorldMapFrame = db, nil
    assert(loadfile("UI.lua"))()
    local frame = assert(OverlordMainFrame, "Panel must exist before PLAYER_LOGIN")
    assert(frame.movable and not frame.shown and frame.dontSavePosition == false)
    if cachedPoint then
        frame:SetPoint((unpack or table.unpack)(cachedPoint))
        frame:SetUserPlaced(true)
    end
    local ui = Overlord.UI
    for _, method in ipairs({ "CreateZoneListSection", "CreateActiveZoneSection",
        "SyncFrontPickerButtonText", "SyncHeaderLayout", "ApplyCommunityHintLayout" }) do
        ui[method] = noop
    end
    ui:Initialize()
    return ui, frame
end

-- User drags left. Map hooks during the drag and after release must not snap it back.
local ui, frame = loadSession({ config = {} })
assert(not frame:IsUserPlaced() and not OverlordDB.panelAnchor)
frame.scripts.OnDragStart(frame)
frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 240, 130)
ui:UpdatePanelAnchor()
close(frame:GetLeft(), 240)
frame.scripts.OnDragStop(frame)
assert(frame:IsUserPlaced())
close(OverlordDB.panelAnchor.left, 240)
local nativeCache = { frame:GetPoint() }

-- Simulate the beta losing all addon SavedVariables, but retaining WoW layout.
ui, frame = loadSession({ config = {} }, nativeCache)
close(frame:GetLeft(), 240)
close(frame:GetBottom(), 130)
close(OverlordDB.panelAnchor.left, 240)
WorldMapFrame = widget()
ui:UpdatePanelAnchor()
close(frame:GetLeft(), 240)
ui:PersistPanelPosition()
close(OverlordDB.panelAnchor.left, 240)

-- Valid SavedVariables take precedence; repeated reloads must not multiply offsets.
for _, scale in ipairs({ 0.8, 1, 1.2 }) do
    local db = { config = { uiScale = scale }, panelAnchor = { left = 240, bottom = 130 } }
    for _ = 1, 3 do
        ui, frame = loadSession(db, nativeCache)
        close(frame:GetLeft() * scale, 240)
        close(frame:GetBottom() * scale, 130)
        ui:PersistPanelPosition()
        close(db.panelAnchor.left, 240)
        close(db.panelAnchor.bottom, 130)
    end
end

-- An explicit reset clears both persistence paths and restores the default anchor.
ui:ResetPosition()
assert(not frame:IsUserPlaced() and not OverlordDB.panelAnchor)
local point, relativeFrame, relative, x = frame:GetPoint()
assert(point == "RIGHT" and relativeFrame == UIParent and relative == "RIGHT" and x == -120)
ui:PersistPanelPosition()
assert(not OverlordDB.panelAnchor)
print("Panel position: early native cache, missing saves, leftward drag, map hooks, reloads and reset OK")
