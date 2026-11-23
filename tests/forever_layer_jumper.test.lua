-- 2.7.0 (Layers OL): the Layers window of 2.5.0 (the players heard, their layer, and asking one of
-- them for a group invitation) is gone. What its button opens now explains the codes Overlord
-- gives to layers and shows ours. Nothing is sent, nothing is listened to, and nothing anywhere
-- in the addon moves a player to another layer.
local now = 1000
function GetTime() return now end
function GetLocale() return "enUS" end
local inInstance = false
function IsInInstance() return inInstance end
function tinsert(t, v) t[#t + 1] = v end
UISpecialFrames, UIParent = {}, {}

local made = {}
local function widget(kind)
    local w = { kind = kind, shown = true, scripts = {} }
    function w:SetText(text) self.text = text end
    function w:GetStringHeight() return 30 end
    function w:SetHeight(h) self.height = h end
    function w:SetSize(width, h) self.width, self.height = width, h end
    function w:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
    function w:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    function w:IsShown() return self.shown end
    function w:SetScript(name, fn) self.scripts[name] = fn end
    function w:CreateFontString() local s = widget("text"); local list = rawget(self, "strings") or {}; self.strings = list; list[#list + 1] = s; return s end
    function w:CreateTexture() return widget("texture") end
    return setmetatable(w, { __index = function() return function() end end })
end
function CreateFrame(kind, name)
    local f = widget(kind)
    f.name = name
    made[#made + 1] = f
    return f
end
local tickers = 0
C_Timer = { NewTicker = function() tickers = tickers + 1; return { Cancel = function() end } end }

local printed = {}
local mark
Overlord = {
    L = {},
    PrintNotification = function(_, text) printed[#printed + 1] = text end,
    Shard = {
        GetCurrentShardID = function() return mark end,
        DisplayCode = function(_, id) local n = id % 100; return n >= 1 and ("OL" .. n) or nil end,
    },
}
assert(loadfile("Locales.lua"))()
local L = Overlord.L
assert(loadfile("LayerJumper.lua"))()
local LJ = Overlord.LayerJumper

-- 1. Our own code, as the panel shows it.
assert(LJ:MyCode() == L.LJ_LAYER_UNKNOWN, "no mark: " .. tostring(LJ:MyCode()))
mark = 482100
assert(LJ:MyCode() == "#OL?", "a mark without a number: " .. tostring(LJ:MyCode()))
mark = 482137
assert(LJ:MyCode() == "#OL37", "a numbered mark: " .. tostring(LJ:MyCode()))

-- 2. The window: a title, our code, the paragraphs of the explanation; no button but Close.
LJ:HandleCommand({ "layer" })
local window = LJ.frame
assert(window and LJ:IsShown() and window.name == "OverlordLayerJumperFrame", "/ov layer opened nothing")
local texts = {}
for _, s in ipairs(window.strings) do texts[#texts + 1] = s.text end
local all = table.concat(texts, "\n")
assert(all:find(L.LJ_TITLE, 1, true) and all:find("#OL37", 1, true), "the window lacks its title or our code: " .. all)
for i = 1, 4 do
    local text = L["LJ_EXPLAIN_" .. i]
    assert(type(text) == "string" and #text > 40 and all:find(text, 1, true), "paragraph " .. i .. " is not in the window")
end
-- (The capturer in sight is explained too, and the window still ends on "no way to change layer".)
assert(#L.LJ_EXPLAIN_SPOT > 40 and all:find(L.LJ_EXPLAIN_SPOT, 1, true), "the window does not explain the capturer in sight")
assert(LJ.PARAGRAPHS[#LJ.PARAGRAPHS] == "LJ_EXPLAIN_4" and texts[#texts] == L.LJ_EXPLAIN_4, "the window no longer ends on its last word")
assert(L.LJ_EXPLAIN_4:find("no way to change layer", 1, true) and L.LJ_EXPLAIN_4:find("Blizzard", 1, true),
    "the window does not say that no way to change layer is offered")
assert(window.height and window.height > 4 * 30, "the window did not take the height of its text")
for _, f in ipairs(made) do
    assert(f == window or f.kind == "Button", "an unexpected frame was made: " .. tostring(f.kind))
end
local buttons = 0
for _, f in ipairs(made) do if f.kind == "Button" then buttons = buttons + 1 end end
assert(buttons <= 1, "the window has other buttons than Close: " .. buttons)
-- (Our code is repainted while the window is shown.)
mark = 482199
LJ:RefreshUI()
assert(window.mineText.text:find("#OL99", 1, true) and tickers == 1, "our code is not kept up to date in the window")
LJ:HandleCommand({ "layer", "help", "on" })
assert(not LJ:IsShown(), "/ov layer did not close the window")
assert(LJ.GetHelpMode == nil and LJ.Join == nil and LJ.ChatLink == nil and LJ.OnRequest == nil and LJ.NoteLayer == nil,
    "a piece of the way to another layer is still there")

-- 3. Nothing in an instance: said, nothing opened; an open window closes.
inInstance = true
LJ:Show()
assert(not LJ:IsShown() and #printed == 1 and printed[1]:find(L.LJ_ERR_INSTANCE, 1, true), "the window opened in an instance")
inInstance = false
LJ:Show()
assert(LJ:IsShown(), "fixture: the window did not open again")
LJ:OnInstanceSuspend()
assert(not LJ:IsShown(), "the window stayed open in an instance")
LJ:OnInstanceResume()

-- 4. Nothing in the addon asks for, sends or accepts a group invitation for a layer, and no
-- alert carries a layer link.
local function read(path) local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text end
local lj = read("LayerJumper.lua")
for _, word in ipairs({ "SendAddonMessage", "RegisterAddonMessagePrefix", "InviteUnit", "AcceptGroup", "LeaveParty",
    "UninviteUnit", "CHAT_MSG_ADDON", "PARTY_INVITE_REQUEST", "RegisterEvent", "OverlordLJ" }) do
    assert(not lj:find(word, 1, true), "LayerJumper.lua still holds " .. word)
end
for _, path in ipairs({ "Sync.lua", "SyncAux.lua", "SyncOutpost.lua", "GuildKillAlert.lua", "UI.lua", "Core.lua" }) do
    local text = read(path)
    assert(not text:find("Overlord:layer:", 1, true) and not text:find("jumper.ChatLink", 1, true)
        and not text:find("jumper:Join", 1, true), path .. " still makes or follows a layer link")
end
assert(not read("SettingsPanel.lua"):find("LayerHelp", 1, true), "the options still offer to help others change layer")
local core = read("Core.lua")
assert(core:find("OverlordDB.layerHelpEra, OverlordDB.layerJumperHop = nil, nil", 1, true)
    and core:find('OverlordDB.config.layerHelpMode = nil', 1, true), "the saved jump and helper choice are not cleared")

-- 5. The wiring: the file is loaded, /ov layer exists, the panel's button and badge open the
-- window, an instance stops it and the events of players in sight.
assert(read("Overlord.toc"):find("\nLayerJumper%.lua\r?\n"), "the module is not loaded")
assert(read("Commands.lua"):find('cmd == "layer" or cmd == "layers"', 1, true), "/ov layer is missing")
local ui = read("UI.lua")
assert(ui:find('L.LJ_TITLE or "Layers"', 1, true) and ui:find("if jumper and jumper.Toggle then jumper:Toggle() end", 1, true),
    "the panel's button does not open the window")
assert(ui:find('return "#" .. (code or "OL?")', 1, true) and ui:find("self.shardText:SetText(BuildShardDisplayTag(shardID))", 1, true),
    "the badge at the top left of the panel does not show the code with its #")
assert(core:find("self%.LayerJumper%.OnInstanceSuspend"), "an instance does not stop the module")
assert(core:find("pcall%(self%.Shard%.SetPulseEvents, self%.Shard, false%)")
    and core:find("pcall%(self%.GeneralNameplate%.SetNameplateEvents, self%.GeneralNameplate, false%)"),
    "the shard pulse or the nameplate badges stay in the event stream in an instance")
assert(core:find("pcall%(Overlord%.Shard%.SetPulseEvents, Overlord%.Shard, true%)")
    and core:find("pcall%(Overlord%.GeneralNameplate%.SetNameplateEvents, Overlord%.GeneralNameplate, true%)")
    and core:find("pcall%(Overlord%.LayerJumper%.OnInstanceResume, Overlord%.LayerJumper%)"),
    "an event frame left in an instance is not registered again on resume")

-- 6. Every text exists in seven languages, with the marks its format needs; the texts of the
-- old window are gone.
do
    local wanted = { LJ_TITLE = 0, LJ_EXPLAIN_1 = 0, LJ_EXPLAIN_2 = 0, LJ_EXPLAIN_3 = 0, LJ_EXPLAIN_4 = 0, LJ_YOUR_LAYER = 1,
        LJ_CLICK_HINT = 0, LJ_LAYER_UNKNOWN = 0, LJ_ERR_INSTANCE = 0, SHARD_TOOLTIP_TITLE = 0, SHARD_TOOLTIP_CURRENT = 1,
        SHARD_TOOLTIP_UNDETECTED = 0, SHARD_TOOLTIP_HINT = 0, SHARD_TOOLTIP_PLAYERS_HEADER = 0, SHARD_ALERT_TAG = 1,
        SHARD_ALERT_NAME_TAG = 1, SHARD_ALERT_NAME_TAG_OURS = 1, DEFENSE_UNSEEN_ATTACKER_INFO = 2 }
    local gone = { "LJ_JOIN", "LJ_CANCEL", "LJ_HELP_MODE", "LJ_HELP_OPTION_LABEL", "LJ_HELP_MODE_TOOLTIP", "LJ_EXPLAIN",
        "LJ_STATUS_REQUESTING", "LJ_HELPERS_KNOWN", "LJ_LIST_EMPTY", "SHARD_TOOLTIP_ALL_SAME", "SHARD_BADGE_REFERENCE" }
    local seen = {}
    for _, path in ipairs({ "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua", "ForeverLocaleFixes.lua" }) do
        local text = read(path)
        for key, marks in pairs(wanted) do
            for line in text:gmatch("\n%s*L%." .. key .. "%s*=%s*(\"[^\n]+\")") do
                seen[key] = (seen[key] or 0) + 1
                local value = assert(loadstring("return " .. line))()
                local _, count = value:gsub("%%[sd]", "")
                assert(count == marks and #value > 0, key .. " in " .. path .. ": " .. value)
            end
        end
        for _, key in ipairs(gone) do
            assert(not text:find("\n%s*L%." .. key .. "%s*="), key .. " is still in " .. path)
        end
    end
    for key in pairs(wanted) do assert(seen[key] == 7, key .. " in seven languages: " .. tostring(seen[key])) end
    -- The tutorial says the same, in its seven languages: codes, no way to change layer.
    local guide = read("GuideLocales.lua")
    local _, codes = guide:gsub("OL37", "")
    assert(codes == 7, "the tutorial explains the codes in " .. codes .. " languages")
    assert(not guide:find("Help others is off by default", 1, true) and not guide:find("join their layer to fight", 1, true),
        "the tutorial still explains the way to another layer")
end

print("Layers OL window: our code, the explanation, no way to another layer anywhere, instance, wiring, seven languages OK")
