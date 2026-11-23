-- LayerJumper.lua: the Layers OL window (Overlord Forever).
--
-- 2.7.0: the game hides layer numbers (hotfix 1.60.1) and limits layer changes, because of the
-- addons that moved players from layer to layer. The Layers window of 2.5.0 (the players heard
-- and their layer, and asking one of them for a group invitation) is gone with them: nothing in
-- Overlord moves a player to another layer, nor asks anybody to.
-- What stands here is the explanation of Layers OL, the codes Overlord gives to layers by itself
-- (Core.lua, Overlord.Shard): players who see each other end up sharing one code, a capture
-- alert names the capturer's code, and the panel shows ours at its top left.
-- ("Capturer spotted", the banner on the nameplate of an enemy capturer the game shows us, is
-- explained here and lives in CaptorSpot.lua.)
--   * A window of text and our own code. Nothing is sent, nothing is listened to.
--   * Nothing in an instance.

Overlord = Overlord or {}
local L = Overlord.L or {}
local LJ = Overlord.LayerJumper or {}
Overlord.LayerJumper = LJ

LJ.PARAGRAPHS = { "LJ_EXPLAIN_1", "LJ_EXPLAIN_2", "LJ_EXPLAIN_3", "LJ_EXPLAIN_SPOT", "LJ_EXPLAIN_4" }
LJ.FALLBACK = {
    LJ_EXPLAIN_1 = "The game no longer lets addons read layer numbers. Overlord names layers itself: players who see each other are on the same layer, so they end up sharing one code, such as OL37.",
    LJ_EXPLAIN_2 = "When an alert adds (yours), the capture is on your layer: that is proven. Different codes prove nothing: two groups of one layer that have not met yet carry two codes, and share one once they meet. The same number without (yours) proves nothing either: two layers can draw the same number.",
    LJ_EXPLAIN_3 = "A capture alert names the capturer's code. Your code is at the top left of the Overlord panel; it can change when groups merge or when you change layer.",
    LJ_EXPLAIN_SPOT = "Capturer spotted: when the game shows you an enemy who is capturing a point of your front, Overlord puts his faction's banner next to his nameplate and tells you in chat. Seeing him is the surest proof: he is on your layer.",
    LJ_EXPLAIN_4 = "Overlord gives no way to change layer: Blizzard chose to remove that, and Overlord follows. The codes only tell where captures happen.",
}

local function Print(text)
    if not text or text == "" then return end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    elseif print then
        print("[Overlord] " .. text)
    end
end

local function T(key, fallback) return L[key] or fallback end

function LJ:InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

-- Our own code as the panel shows it: "#OL37", "#OL?" for a mark that has no number yet, or
-- "unknown" where no mark is carried (outside a front, an outpost or a keep).
function LJ:MyCode()
    local shard = Overlord.Shard
    if not shard or not shard.GetCurrentShardID then return T("LJ_LAYER_UNKNOWN", "unknown") end
    local ok, id = pcall(shard.GetCurrentShardID, shard)
    if not ok or id == nil then return T("LJ_LAYER_UNKNOWN", "unknown") end
    local okCode, code = pcall(function() return shard.DisplayCode and shard:DisplayCode(id) end)
    return "#" .. ((okCode and code) or "OL?")
end

-- An instance: like the rest of Overlord, this window closes.
function LJ:OnInstanceSuspend()
    if self.frame and self.frame:IsShown() then self.frame:Hide() end
end

function LJ:OnInstanceResume() end

function LJ:Initialize()
    self.initialized = true
end

-- ============================================================
-- Window
-- ============================================================

local GOLD = { 1, 0.82, 0 }
local WINDOW_ICON = "Interface\\Icons\\Spell_Arcane_PortalShattrath"
local FRAME_W = 400
local TEXT_TOP, TEXT_GAP, TEXT_BOTTOM = 76, 10, 22

function LJ:CreateWindow()
    if self.frame then return self.frame end
    local UI = Overlord.UI or {}
    local f = CreateFrame("Frame", "OverlordLayerJumperFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, 320)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    if UI.ApplyWoodDialogBackdrop then UI.ApplyWoodDialogBackdrop(f) end
    if UI.AttachOpenFade then UI.AttachOpenFade(f) end
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    -- (The panel's Layers OL button lights while this window is open, however it was closed.)
    local function gridButton()
        local ui = Overlord.UI
        if ui and ui.ScheduleActionGridActiveRefresh then ui:ScheduleActionGridActiveRefresh() end
    end
    f:SetScript("OnShow", gridButton)
    f:SetScript("OnHide", gridButton)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
    f:Hide()
    if UISpecialFrames then tinsert(UISpecialFrames, "OverlordLayerJumperFrame") end

    local close = UI.CreateWC3CloseButton and UI.CreateWC3CloseButton(f, function() LJ:Hide() end)
        or CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
    icon:SetTexture(WINDOW_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(T("LJ_TITLE", "Layers OL"))
    title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

    local mine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mine:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -50)
    mine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -50)
    mine:SetJustifyH("LEFT")
    mine:SetWordWrap(false)
    f.mineText = mine

    -- The explanation, one paragraph under the other (placed by LayoutText once shown).
    f.paragraphs = {}
    for i, key in ipairs(self.PARAGRAPHS) do
        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetWidth(FRAME_W - 40)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        text:SetWordWrap(true)
        if text.SetSpacing then text:SetSpacing(2) end
        text:SetText(T(key, self.FALLBACK[key]))
        -- (The last paragraph, "no way to change layer", in the title's gold.)
        if i == #self.PARAGRAPHS then text:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end
        f.paragraphs[i] = text
    end

    self.frame = f
    self:LayoutText(f)
    return f
end

-- The paragraphs one under the other, the window as tall as they are. Run again once the window
-- is shown: a text never drawn may answer a height of 0, and the paragraphs would overlap.
function LJ:LayoutText(f)
    local y = TEXT_TOP
    for _, text in ipairs(f.paragraphs) do
        local height = math.ceil(tonumber(text:GetStringHeight()) or 0)
        if height < 12 then height = 48 end
        text:ClearAllPoints()
        text:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -y)
        y = y + height + TEXT_GAP
    end
    f:SetHeight(y - TEXT_GAP + TEXT_BOTTOM)
end

-- A display must never break what calls it.
function LJ:RefreshUI()
    local f = self.frame
    if not f or not f:IsShown() then return end
    local ok, err = pcall(self.PaintWindow, self, f)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

function LJ:PaintWindow(f)
    f.mineText:SetText(string.format(T("LJ_YOUR_LAYER", "Your layer: %s"), self:MyCode()))
    self:LayoutText(f)
end

function LJ:Show()
    -- (Not in an instance, like the rest of the addon: said, nothing opened.)
    if self:InInstance() then
        Print(T("LJ_ERR_INSTANCE", "Not available in instances and battlegrounds."))
        return
    end
    if not CreateFrame then return end
    local f = self:CreateWindow()
    if Overlord.UI and Overlord.UI.GetEffectiveUiScale then
        f:SetScale(Overlord.UI:GetEffectiveUiScale())
    end
    f:Show()
    if Overlord.PlayPanelOpenSound then Overlord:PlayPanelOpenSound() end
    self:RefreshUI()
    -- (Our code moves as players are met: repainted every 5 s while shown, no OnUpdate.)
    if not self.listTicker and C_Timer and C_Timer.NewTicker then
        self.listTicker = C_Timer.NewTicker(5, function()
            if LJ.frame and LJ.frame:IsShown() then
                LJ:RefreshUI()
            elseif LJ.listTicker then
                LJ.listTicker:Cancel()
                LJ.listTicker = nil
            end
        end)
    end
end

function LJ:Hide()
    if self.frame and self.frame:IsShown() then
        if Overlord.PlayPanelCloseSound then Overlord:PlayPanelCloseSound() end
        self.frame:Hide()
    end
end

function LJ:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
end

function LJ:IsShown()
    return self.frame ~= nil and self.frame:IsShown() == true
end

-- Command: /ov layer
function LJ:HandleCommand()
    self:Toggle()
end

-- (/ov perf mem: this file's own tables, out of reach of a walk from Overlord otherwise.)
Overlord.MemoryParts = Overlord.MemoryParts or {}
Overlord.MemoryParts["LayerJumper.lua"] = function() return { LJ = LJ, GOLD = GOLD, WINDOW_ICON = WINDOW_ICON, FRAME_W = FRAME_W } end
