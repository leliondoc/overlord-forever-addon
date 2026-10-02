-- Run the production filter and UI against 5,000 players + 5,000 guilds.
-- Bound work/timers/frames, rather than claiming machine-independent FPS.
local timers, now, callbacks = {}, 0, 0
local function pending()
    local n = 0
    for _, timer in ipairs(timers) do if not timer.cancelled then n = n + 1 end end
    return n
end
C_Timer = {}
function C_Timer.NewTimer(delay, callback)
    local timer = { at = now + delay, callback = callback }
    function timer:Cancel() self.cancelled = true end
    timers[#timers + 1] = timer
    return timer
end
function C_Timer.After(delay, callback) C_Timer.NewTimer(delay, callback) end
function GetTime() return now end
function debugprofilestop() return os.clock() * 1000 end
local lower, reads, maxReads, maxMs = string.lower, 0, 0, 0
string.lower = function(s) reads = reads + 1; return lower(s) end
local function tick()
    table.sort(timers, function(a,b) return a.at < b.at end)
    local timer = table.remove(timers, 1)
    if not timer then return false end
    if not timer.cancelled then
        now, reads = math.max(now, timer.at), 0
        local start = debugprofilestop()
        timer.callback()
        maxMs = math.max(maxMs, debugprofilestop() - start)
        maxReads = math.max(maxReads, reads)
        callbacks = callbacks + 1
        assert(reads <= 256, 'Unbounded population scan in one callback')
    end
    return true
end
local function drain()
    local guard = 0
    while tick() do guard = guard + 1; assert(guard < 10000, 'Search failed to settle') end
end
Overlord = {}
assert(loadfile('LeaderboardSearch.lua'))()
local source = { sortedKills = {}, sortedGuilds = {}, sortedGuildKeeps = {}, sortedOutposts = {},
    byFaction = { Alliance = {}, Horde = {} }, meta = {}, locale = {}, duplicateShortNames = {} }
for i = 1, 5000 do
    source.sortedKills[i] = { name = 'Player ' .. i, kills = 5001 - i }
    source.sortedGuilds[i] = { guild = 'Guild ' .. i, kills = 6001 - i }
end
source.sortedKills[4321].name = 'Éléa Test[100%]'
source.sortedGuilds[4000].guild = 'Test[100%]'
source.sortedGuilds[3999].guild = 'Äther'
source.sortedGuilds[3998].guild = 'ЖУК'
source.byFaction.Alliance[1] = source.sortedKills[4321]
source.sortedGuildKeeps[1] = { guild = 'Test[100%]' }
source.sortedOutposts[1] = { guild = 'Test[100%]' }
local shown, published, commits = true, nil, 0
local search = Overlord.LeaderboardSearch:New(function() return shown end, function(view)
    published, commits = view, commits + 1
end)
assert(search:Request(source, '') == source and pending() == 0 and reads == 1)
for _, query in ipairs({ 'T', 'Te', 'Tes', 'Test', 'Test[' }) do
    search:Request(source, query)
    assert(pending() == 1, 'Typing accumulated simultaneous searches')
end
search:Request(source, '  TEST[100%]  ')
assert(not published, 'Query scanned synchronously while typing')
drain()
assert(commits == 1 and #published.sortedKills == 1 and #published.sortedGuilds == 1)
assert(published.sortedKills[1] == source.sortedKills[4321] and published.ranks.sortedKills[1] == 4321)
assert(published.ranks.sortedGuilds[1] == 4000 and #published.sortedGuildKeeps == 1
    and #published.sortedOutposts == 1 and #published.byFaction.Alliance == 1)
assert(source.sortedKills[4321].rank == nil and #source.sortedKills == 5000, 'Search mutated scores/ranks')
for _ = 1, 100 do assert(search:Request(source, 'test[100%]') == published) end
assert(pending() == 0, 'Repeated refresh rebuilt an unchanged search')
search:Request(source, 'éléa'); drain()
assert(#published.sortedKills == 1 and published.ranks.sortedKills[1] == 4321,
    'An accented uppercase player name did not match lowercase input')
search:Request(source, 'äTHER'); drain()
assert(#published.sortedGuilds == 1 and published.ranks.sortedGuilds[1] == 3999,
    'An accented uppercase guild name did not match mixed-case input')
search:Request(source, 'жук'); drain()
assert(#published.sortedGuilds == 1 and published.ranks.sortedGuilds[1] == 3998,
    'A Cyrillic uppercase guild name did not match lowercase input')
search:Request(source, 'no matches'); drain()
assert(#published.sortedKills == 0 and #published.sortedGuilds == 0)
search:Request(source, 'player'); tick()
local before = commits
search:Request(source, 'guild 4999'); drain()
assert(commits == before + 1 and #published.sortedGuilds == 1 and published.ranks.sortedGuilds[1] == 4999,
    'An older query overwrote newer results')
-- Cache source replacement during work cannot publish mixed generations.
search:Request(source, 'player'); tick()
local previous = source.sortedKills
source.sortedKills = { { name = 'Player new', kills = 1 } }
search:Request(source, 'player'); drain()
assert(#published.sortedKills == 1 and published.sortedKills[1].name == 'Player new')
source.sortedKills = previous
search:Request(source, 'player'); tick()
shown = false; search:Cancel(); before = commits; drain()
assert(commits == before and pending() == 0, 'Closing left search work running')
shown = true; search:Request(source, 'player'); drain()
assert(#published.sortedKills == 4999)
assert(search:Request(source, '') == source and search.result == nil and pending() == 0)
print(string.format('Search worker: 5000 players + 5000 guilds; max %d rows/slice, %.3f ms/callback (local Lua 5.1)',
    maxReads, maxMs))

-- Actual UI: input, painting, scrolling, original ranks, totals and frame pool.
string.lower = lower
local methods, frames, mutations = {}, {}, 0
local function widget(kind, name, parent)
    local w = setmetatable({ shown = true, scripts = {}, width = 400, height = 260,
        parent = parent, kind = kind, nameId = name }, { __index = methods })
    if kind then frames[#frames + 1] = w end
    if name then _G[name] = w end
    return w
end
function methods:CreateFontString() return widget() end
function methods:CreateTexture() return widget() end
function methods:SetScript(key, callback) self.scripts[key] = callback end
function methods:GetScript(key) return self.scripts[key] end
function methods:HookScript(key, callback)
    local old = self.scripts[key]
    self.scripts[key] = function(...) if old then old(...) end; callback(...) end
end
function methods:SetSize(w,h) self.width,self.height = w,h end
function methods:SetWidth(w) self.width = w end
function methods:SetHeight(h) self.height = h end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:GetParent() return self.parent end
function methods:GetScale() return 1 end
function methods:GetTop() return nil end
function methods:GetBottom() return nil end
function methods:GetFrameLevel() return 50 end
function methods:GetVerticalScroll() return self.scroll or 0 end
function methods:GetVerticalScrollRange() return math.max(0, (self.child and self.child.height or 0) - self.height) end
function methods:SetScrollChild(child) self.child = child end
function methods:SetVerticalScroll(n)
    self.scroll = n
    if self.scripts.OnVerticalScroll then self.scripts.OnVerticalScroll() end
end
function methods:IsShown() return self.shown and (not self.parent or self.parent:IsShown()) end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:SetText(text)
    self.text = text; mutations = mutations + 1
    if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
end
function methods:GetText() return self.text or '' end
function methods:GetStringWidth() return #tostring(self.text or '') * 6 end
function methods:GetStringHeight() return 12 end
function methods:SetPoint(...) self.point = {...} end
setmetatable(methods, { __index = function(_, key)
    if key:match('^Set') or key:match('^Register') or key:match('^Enable') or key == 'ClearAllPoints'
        or key == 'ClearFocus' then return function() end end
end })
CreateFrame = widget
UIParent = widget(); UIParent:SetSize(1920,1080)
function InCombatLockdown() return false end
Overlord.L = { LB_TITLE = 'LEADERBOARD', LB_TOTAL_FORMAT = 'Alliance %d Horde %d', LB_CAMPAIGN_DATE = '%s - %s' }
function Overlord:GetCampaignDateRange() return 'start','end' end
Overlord.UI = { CreateWC3CloseButton = function(parent, callback)
    local button = widget('Button',nil,parent); button:SetScript('OnClick',callback); return button
end, CreateOfficialIconHolder = function(parent)
    local holder = widget('Frame',nil,parent); holder.icon = widget(); return holder
end }
local ensureCalls = 0
source.alliKills,source.hordeKills = 123456,654321
Overlord.Leaderboard = {
    EnsureDisplayCache = function() ensureCalls = ensureCalls + 1; return source end,
    GetExportPlayerMeta = function() return '', '' end,
}
-- No network API exists in this fixture: any attempted send fails the test.
assert(loadfile('LeaderboardUI.lua'))()
local ui = Overlord.LeaderboardUI
ui:Show(); drain()
local frame = OverlordLeaderboardFrame
assert(frame.searchBox and frame.searchBox.point[1] == 'BOTTOMRIGHT')
local frameCount, readsBefore = #frames, ensureCalls
frame.searchBox:SetText('  player 4999  '); drain()
assert(ensureCalls == readsBefore, 'Typing requested/rebuilt the display cache')
assert(#frame._lbView.sortedKills == 1 and frame._lbView.ranks.sortedKills[1] == 4999)
assert(frame.totalText.text:find('Alliance 123456 Horde 654321', 1, true), 'Filter changed global totals')
local row
for _, w in ipairs(frames) do if w.rank and w.name and w:IsShown() and w.rank.text == 4999 then row = w end end
assert(row and row.name.text == 'Player 4999', 'Filtered UI renumbered rank to #1')
frame.searchBox:SetText('éléa'); drain()
assert(#frame._lbView.sortedKills == 1 and frame._lbView.ranks.sortedKills[1] == 4321,
    'The real search box did not apply Unicode case folding')
frame.scrollKills:SetVerticalScroll(1000)
frame.searchBox:SetText('Test[100%]'); drain()
assert(frame.scrollKills:GetVerticalScroll() == 0 and frame._lbView.ranks.sortedKills[1] == 4321)
frame.searchBox:SetText('missing'); drain()
assert(frame.searchStatus.text == 'No matches' and not row:IsShown())
assert(not frame.guildEmptyHint:IsShown(), 'An empty search was presented as a guild data loss')
frame.searchClear.scripts.OnClick(); drain()
assert(#frame._lbView.sortedKills == 5000 and not frame.searchClear:IsShown())
assert(#frames == frameCount, 'Search created frames per matching row')
frame.searchBox:SetText('player'); ui:Hide(); drain()
assert(not frame.search.job, 'Hidden leaderboard continued filtering')
ui:Show(); drain()
assert(#frame._lbView.sortedKills == 4999, 'Reopening lost pending query')
frame.searchBox.scripts.OnEscapePressed(frame.searchBox); drain()
assert(frame._lbView == frame._lbSource and pending() == 0)
-- Expanding from 25 to 500 captures must reuse the same visible row pool.
for _, faction in ipairs({ 'Alliance', 'Horde' }) do
    source.byFaction[faction] = {}
    for i = 1, 25 do
        source.byFaction[faction][i] = { name = faction .. ' Capturer ' .. i,
            count = 501 - i, class = 'UNKNOWN', faction = faction }
    end
end
ui:Refresh(); drain()
local captureFrameCount = #frames
local alliancePool, hordePool = #frame.alliLines, #frame.hordeLines
for _, faction in ipairs({ 'Alliance', 'Horde' }) do
    for i = 26, 500 do
        source.byFaction[faction][i] = { name = faction .. ' Capturer ' .. i,
            count = 501 - i, class = 'UNKNOWN', faction = faction }
    end
end
ui:Refresh(); drain()
assert(#frames == captureFrameCount and #frame.alliLines == alliancePool and #frame.hordeLines == hordePool,
    'Top 500 allocated frames beyond the visible capture rows')
for _, scroll in ipairs({ frame.scrollAlli, frame.scrollHorde }) do
    scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
end
local function hasLast(pool, faction)
    for _, r in ipairs(pool) do
        if r:IsShown() and r.name.text == faction .. ' Capturer 500' and r.count.text == 1 then return true end
    end
    return false
end
assert(hasLast(frame.alliLines, 'Alliance') and hasLast(frame.hordeLines, 'Horde'),
    'Scrolling cannot reach the 500th capture row')
assert(#frames == captureFrameCount, 'Scrolling allocated more capture frames')
frame.searchBox:SetText('Capturer 500'); drain()
assert(#frame._lbView.byFaction.Alliance == 1 and #frame._lbView.byFaction.Horde == 1,
    'Search missed captures outside the old top 25')
frame.searchClear.scripts.OnClick(); drain()
assert(pending() == 0 and #frames == captureFrameCount)
-- Hovering a player row shows the known guild, read from memory (same source as
-- guild totals), and never sends anything. The mouse wheel still scrolls.
local tip = { lines = {} }
function tip:SetOwner(owner) self.owner, self.lines = owner, {} end
function tip:AddLine(text) self.lines[#self.lines + 1] = text end
function tip:Show() self.shown = true end
function tip:Hide() self.shown = false end
function tip:IsOwned(owner) return self.owner == owner end
GameTooltip = tip
local guildLookups = 0
Overlord.Leaderboard.GetHotPlayerGuildState = function(_, name)
    guildLookups = guildLookups + 1
    if name == 'Player 1' then return 'Iron Watch', 0, false end
    return '', 0, false
end
frame.scrollKills:SetVerticalScroll(0); drain()
local killRow
for _, w in ipairs(frames) do
    if w.rank and w.name and w.kills and w:IsShown() and w._olPlayerName == 'Player 1' then killRow = w end
end
assert(killRow and killRow.scripts.OnEnter, 'Player row has no hover handler')
killRow.scripts.OnEnter(killRow)
assert(tip.shown and tip.owner == killRow and tip.lines[1] == 'Player 1', 'Hover did not name the player')
assert(tip.lines[2] == 'Guild: Iron Watch', 'Hover did not show the guild: ' .. tostring(tip.lines[2]))
local otherRow
for _, w in ipairs(frames) do
    if w.rank and w.kills and w:IsShown() and w._olPlayerName and w._olPlayerName ~= 'Player 1' then otherRow = w; break end
end
otherRow.scripts.OnEnter(otherRow)
assert(tip.lines[2] == 'Guild unknown', 'Unknown guild was not stated')
-- Wheel on a row scrolls the ranking, and a reused row refreshes its open tooltip.
killRow.scripts.OnEnter(killRow)
local lookupsBefore = guildLookups
killRow.scripts.OnMouseWheel(killRow, -1); drain()
assert(frame.scrollKills:GetVerticalScroll() > 0, 'Mouse wheel over a row no longer scrolls')
if killRow._olPlayerName ~= 'Player 1' then
    assert(guildLookups > lookupsBefore and tip.lines[1] ~= 'Player 1',
        'Tooltip kept the previous player after the row was reused')
end
-- 1.4.0: hovering a guild row lists its ranked members (top 10 + how many more)
-- from the display cache; nothing is computed or sent on hover.
function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. " = " .. right end
local guildRow
for _, w in ipairs(frames) do
    if w._olGuildEntry and w:IsShown() then guildRow = w; break end
end
assert(guildRow and guildRow.scripts.OnEnter, "Guild rows do not react to the mouse")
local asked
Overlord.Leaderboard.GetGuildMembersSummary = function(_, guild)
    asked = guild
    return { count = 12, names = { "Ana Bel", "Bo Rin" }, kills = { 40, 30 } }
end
guildRow.scripts.OnEnter(guildRow)
assert(asked == guildRow._olGuildEntry.guild, "Tooltip looked up another guild")
assert(tip.lines[1] == "<" .. asked .. ">", "Guild name missing: " .. tostring(tip.lines[1]))
assert(tip.lines[2]:find("12", 1, true), "Ranked member count missing: " .. tostring(tip.lines[2]))
assert(tip.lines[3] == "1. Ana Bel = 40" and tip.lines[4] == "2. Bo Rin = 30", "Top members wrong")
assert(tip.lines[5] and tip.lines[5]:find("10", 1, true), "Remaining members not stated")
assert(guildRow.scripts.OnMouseWheel, "Mouse wheel over a guild row no longer scrolls")
print('Search UI: actual edit box/clear/Escape, bounded frames, original rank, scroll reset, totals, no data reads on typing, guild hover OK')
