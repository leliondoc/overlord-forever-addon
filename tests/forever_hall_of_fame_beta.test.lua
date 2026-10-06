-- Hall of Fame: beta weeks stay in their own category (a plain category for one
-- week, one sub-category per week otherwise, newest first), never in the
-- player/guild/Alliance/Horde categories, which stay hidden while the launch has no
-- champion. Every locale formats the week lines.
local files = { "Locales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua", "HallOfFameData.lua" }

local function load(loc)
    Overlord = { L = {} }
    GetLocale = function() return loc end
    for _, file in ipairs(files) do dofile(file) end
    return Overlord.HallOfFameData
end

local function ids(entries)
    local out = {}
    for i, entry in ipairs(entries) do out[i] = (entry.isChild and ">" or "") .. entry.id end
    return table.concat(out, ",")
end

local TRANSLATED_KEYS = { "HOF_WEEKLY_PLAYER_RANK_LINE", "HOF_WEEKLY_GUILD_RANK_LINE",
    "HOF_WEEKLY_CAPTURE_RANK_LINE", "HOF_CAT_BETA_WEEK" }
load("enUS")
local english = {}
for _, key in ipairs(TRANSLATED_KEYS) do english[key] = Overlord.L[key] end

for _, loc in ipairs({ "enUS", "frFR", "esES", "deDE", "ruRU", "ptBR", "zhCN" }) do
    local data = load(loc)
    local L = Overlord.L

    -- Translated in every language (English is the base table, so a missing key
    -- would silently fall back to it).
    if loc ~= "enUS" then
        for _, key in ipairs(TRANSLATED_KEYS) do
            assert(L[key] ~= english[key], loc .. " not translated: " .. key)
        end
    end

    -- Week lines: exactly two %d.
    for _, key in ipairs({ "HOF_WEEKLY_PLAYER_RANK_LINE", "HOF_WEEKLY_GUILD_RANK_LINE",
        "HOF_WEEKLY_CAPTURE_RANK_LINE" }) do
        local text = L[key]
        assert(type(text) == "string", loc .. " missing " .. key)
        local _, slots = text:gsub("%%d", "")
        local _, percents = text:gsub("%%", "")
        assert(slots == 2 and percents == 2, loc .. " " .. key .. " needs two %d: " .. text)
    end
    assert(type(L.HOF_CAT_BETA) == "string", loc .. " missing HOF_CAT_BETA")
    assert(select(2, L.HOF_CAT_BETA_WEEK:gsub("%%d", "")) == 1, loc .. " HOF_CAT_BETA_WEEK")

    -- Shipped data: week 1 only (the full history is on the website), so the beta is
    -- a plain category without sub-categories, expanded or not.
    assert(ids(data:GetSidebarEntries(false)) == "beta,donors", loc .. " " .. ids(data:GetSidebarEntries(false)))
    assert(ids(data:GetSidebarEntries(true)) == "beta,donors", "a single week shows no sub-category")
    assert(data:GetDefaultCategory() == "beta:1", "default opens the beta week")
    assert(data:ResolveCategory("beta") == "beta:1")
    assert(data:IsBetaWeek("beta:1") and not data:IsBetaWeek("beta") and not data:IsBetaWeek("donors"))

    -- No beta row anywhere else.
    for _, cat in ipairs({ "player", "guild", "alliance", "horde" }) do
        assert(#data:GetHonorView(cat, "").rows == 0, cat .. " shows beta rows")
    end

    -- Week 1: 15 cards, killers then guilds then capturers, ranks 1-5 each, distinct ids.
    local view = data:GetHonorView("beta:1", "")
    assert(#view.rows == 15 and view.stats.totalPoints == 150, "week 1 size")
    local seen = {}
    for i, row in ipairs(view.rows) do
        local kind = ({ "player", "guild", "capture" })[math.floor((i - 1) / 5) + 1]
        assert(row.kind == kind and row.week == 1, "week 1 order at " .. i)
        local rankLine = ({ player = L.HOF_WEEKLY_PLAYER_RANK_LINE,
            guild = L.HOF_WEEKLY_GUILD_RANK_LINE, capture = L.HOF_WEEKLY_CAPTURE_RANK_LINE })[kind]
        assert(row.subtitle == string.format(rankLine, 1, (i - 1) % 5 + 1), loc .. " subtitle " .. row.subtitle)
        assert(not seen[row.data.id], "duplicate card id " .. row.data.id)
        seen[row.data.id] = true
    end
    -- The 24-capture tie is ordered by name; the killer and the capturer are two cards.
    assert(view.rows[13].title == "Rusty Nutz" and view.rows[14].title == "Vaio Flæk")
    assert(#data:GetHonorView("beta:1", "vaio").rows == 2, "search week 1 (killer + capturer)")
    assert(#data:GetHonorView("beta:2", "").rows == 0, "no second week shipped")
end

-- Several beta weeks (later milestones): one sub-category per week, newest first,
-- only once expanded; the same player keeps one card identity per week.
do
    local data = load("frFR")
    local L = Overlord.L
    local week2 = {}
    for _, entry in ipairs(Overlord.BetaChampionEntries) do
        local copy = {}
        for k, v in pairs(entry) do copy[k] = v end
        copy.week = 2
        week2[#week2 + 1] = copy
    end
    for _, entry in ipairs(week2) do Overlord.BetaChampionEntries[#Overlord.BetaChampionEntries + 1] = entry end
    assert(ids(data:GetSidebarEntries(false)) == "beta,donors")
    assert(ids(data:GetSidebarEntries(true)) == "beta,>beta:2,>beta:1,donors", ids(data:GetSidebarEntries(true)))
    assert(data:GetSidebarEntries(true)[2].label == string.format(L.HOF_CAT_BETA_WEEK, 2), "week label")
    assert(data:GetDefaultCategory() == "beta:2" and data:ResolveCategory("beta") == "beta:2")
    local w1, w2 = data:GetHonorView("beta:1", ""), data:GetHonorView("beta:2", "")
    assert(#w1.rows == 15 and #w2.rows == 15, "one week per sub-category")
    assert(w2.rows[1].subtitle == string.format(L.HOF_WEEKLY_PLAYER_RANK_LINE, 2, 1))
    assert(w1.rows[1].data.id ~= w2.rows[1].data.id, "same player, two weeks, one card identity each")
    assert(#data:GetHonorView("beta:2", "vaio").rows == 2, "search stays inside the week")
end

-- A launch champion makes its categories appear; beta stays apart. Rows are built
-- lazily, so the entry is set on a fresh load before the first query.
local data = load("enUS")
Overlord.WeeklyChampionEntries = {
    { week = 1, kind = "guild", name = "Launch Guild", faction = "Horde", kills = 10 },
    { week = 1, kind = "capture", name = "Launch Capturer", faction = "Horde", captures = 3 },
}
assert(ids(data:GetSidebarEntries(false)) == "player,guild,horde,beta,donors", ids(data:GetSidebarEntries(false)))
assert(data:GetDefaultCategory() == "player")
assert(#data:GetHonorView("player", "").rows == 1, "capturers are player honors")
assert(#data:GetHonorView("guild", "").rows == 1 and #data:GetHonorView("horde", "").rows == 2)

print("Hall of Fame beta: own category, one sub-category per week, launch categories hidden while empty OK")
