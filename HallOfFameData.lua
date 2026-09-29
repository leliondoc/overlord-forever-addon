-- HallOfFameData.lua - Hall of Fame Forever : champions de la semaine terminee
-- (top 5 tueurs et top 5 guildes, par faction) et donateurs du tresor de guerre.
-- Entrees curatees a la main, affichage seulement : aucun reseau, aucun repere carte.
Overlord = Overlord or {}
Overlord.HallOfFameData = {}

local L = Overlord.L

Overlord.HallOfFameData.CATEGORIES = {
    { id = "player", labelKey = "HOF_CAT_PLAYER" },
    { id = "guild", labelKey = "HOF_CAT_GUILD" },
    { id = "alliance", labelKey = "HOF_CAT_ALLIANCE" },
    { id = "horde", labelKey = "HOF_CAT_HORDE" },
    { id = "donors", labelKey = "HOF_CAT_DONORS" },
}

-- Campagne du 22/09/2026 au 29/09/2026 : top 5 final des tueurs et des guildes.
Overlord.WeeklyChampionEntries = {
    { kind = "player", name = "Vaio Flæk", faction = "Alliance", kills = 6017 },
    { kind = "player", name = "Big Topher", faction = "Alliance", kills = 5000 },
    { kind = "player", name = "Il Blasfemo", faction = "Horde", kills = 4997 },
    { kind = "player", name = "Risky Quickie", faction = "Alliance", kills = 4182 },
    { kind = "player", name = "Imperial Constantius", faction = "Alliance", kills = 3693 },
    { kind = "guild", name = "EMPIRE", faction = "Alliance", kills = 107659 },
    { kind = "guild", name = "Elfcore", faction = "Alliance", kills = 47180 },
    { kind = "guild", name = "Kor Kron Enforcers", faction = "Horde", kills = 15084 },
    { kind = "guild", name = "jolékip", faction = "Horde", kills = 14454 },
    { kind = "guild", name = "B I G P P V P", faction = "Alliance", kills = 10919 },
}

-- Comme sur Retail : nom sans couleur, la faction se lit a l'icone.
local CHAMPION_ICON = {
    player = { Alliance = "Interface\\Icons\\Achievement_PVP_A_15",
        Horde = "Interface\\Icons\\Achievement_PVP_H_15" },
    guild = { Alliance = "Interface\\Icons\\Achievement_PVP_A_05",
        Horde = "Interface\\Icons\\Achievement_PVP_H_05" },
}
local CHAMPION_POINTS = 10

Overlord.DonorHonorEntries = {
    anadora = {
        entryKey = "anadora",
        sortOrder = 1,
        playerDisplay = "Anadora",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    aeythyr = {
        entryKey = "aeythyr",
        sortOrder = 2,
        playerDisplay = "Aeythyr",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    warchief = {
        entryKey = "warchief",
        sortOrder = 3,
        playerDisplay = "Warchief",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    duls = {
        entryKey = "duls",
        sortOrder = 4,
        playerDisplay = "Duls",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    antor = {
        entryKey = "antor",
        sortOrder = 5,
        playerDisplay = "Antor",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    servo = {
        entryKey = "servo",
        sortOrder = 6,
        playerDisplay = "Servo",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    sledgeaxe = {
        entryKey = "sledgeaxe",
        sortOrder = 7,
        playerDisplay = "Sledgeaxe",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    jim = {
        entryKey = "jim",
        sortOrder = 8,
        playerDisplay = "Jim",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
    lesi = {
        entryKey = "lesi",
        sortOrder = 9,
        playerDisplay = "Lesi",
        displayPoints = 10,
        statLineKey = "HOF_DONOR_LINE",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
    },
}

local donorRows = nil

local function DonorSubtitle(entry)
    if not entry then return "" end
    local key = entry.statLineKey or "HOF_DONOR_LINE"
    local fmt = L and L[key]
    if type(fmt) == "string" and not fmt:find("%%", 1, true) then
        return fmt
    end
    return ""
end

local function BuildDonorRows()
    local entries = Overlord.DonorHonorEntries or {}
    local keys = {}
    for key in pairs(entries) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local oa = tonumber(entries[a] and entries[a].sortOrder) or 999
        local ob = tonumber(entries[b] and entries[b].sortOrder) or 999
        if oa ~= ob then return oa < ob end
        return a < b
    end)

    local rows = {}
    local totalPoints = 0
    for i = 1, #keys do
        local entry = entries[keys[i]]
        if entry then
            local title = entry.playerDisplay or ""
            local subtitle = DonorSubtitle(entry)
            local points = tonumber(entry.displayPoints) or 0
            totalPoints = totalPoints + points
            rows[#rows + 1] = {
                kind = "donor",
                data = entry,
                sortOrder = entry.sortOrder or i,
                points = points,
                title = title,
                subtitle = subtitle,
                icon = entry.icon,
                earned = true,
                earnedAt = -(entry.sortOrder or i),
                searchHaystack = (title .. " " .. subtitle):lower(),
            }
        end
    end
    donorRows = {
        rows = rows,
        stats = {
            totalCount = #rows,
            earnedCount = #rows,
            totalPoints = totalPoints,
            donorCount = #rows,
        },
    }
end

local championRows = nil

-- Position dans le classement final de la semaine (joueurs ou guildes).
local function ChampionSubtitle(kind, rank)
    local key = kind == "guild" and "HOF_WEEKLY_GUILD_RANK_LINE" or "HOF_WEEKLY_PLAYER_RANK_LINE"
    local fmt = L and L[key]
    if type(fmt) ~= "string" or not fmt:find("%d", 1, true) then
        fmt = kind == "guild" and "Beta, weekly guilds: rank %d" or "Beta, weekly killers: rank %d"
    end
    return string.format(fmt, rank)
end

-- Joueurs puis guildes, chacun par VH decroissantes.
local function BuildChampionRows()
    local sorted = {}
    for _, entry in ipairs(Overlord.WeeklyChampionEntries or {}) do
        sorted[#sorted + 1] = entry
    end
    table.sort(sorted, function(a, b)
        if a.kind ~= b.kind then return a.kind == "player" end
        if a.kills ~= b.kills then return a.kills > b.kills end
        return a.name < b.name
    end)
    championRows = {}
    local rankByKind = {}
    for i, entry in ipairs(sorted) do
        rankByKind[entry.kind] = (rankByKind[entry.kind] or 0) + 1
        local subtitle = ChampionSubtitle(entry.kind, rankByKind[entry.kind])
        championRows[#championRows + 1] = {
            kind = entry.kind,
            data = entry,
            faction = entry.faction,
            sortOrder = i,
            points = CHAMPION_POINTS,
            title = entry.name,
            subtitle = subtitle,
            icon = CHAMPION_ICON[entry.kind] and CHAMPION_ICON[entry.kind][entry.faction]
                or "Interface\\Icons\\Achievement_PVP_A_15",
            earned = true,
            isCurated = true,
            earnedAt = -i,
            searchHaystack = (entry.name .. " " .. subtitle .. " "
                .. tostring(entry.faction)):lower(),
        }
    end
end

local function EnsureRows()
    if not donorRows then
        BuildDonorRows()
    end
    return donorRows
end

local function EnsureChampionRows()
    if not championRows then BuildChampionRows() end
    return championRows
end

local function ChampionsFor(categoryId)
    local out = {}
    for _, row in ipairs(EnsureChampionRows()) do
        if (categoryId == "player" and row.kind == "player")
            or (categoryId == "guild" and row.kind == "guild")
            or (categoryId == "alliance" and row.faction == "Alliance")
            or (categoryId == "horde" and row.faction == "Horde") then
            out[#out + 1] = row
        end
    end
    return out
end

local function FilterRows(rows, searchText)
    if not searchText or searchText == "" then
        return rows
    end
    local needle = searchText:lower()
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        if row.searchHaystack and row.searchHaystack:find(needle, 1, true) then
            out[#out + 1] = row
        end
    end
    return out
end

function Overlord.HallOfFameData:GetHonorView(categoryId, searchText)
    local cache = EnsureRows()
    if categoryId == "player" or categoryId == "guild"
        or categoryId == "alliance" or categoryId == "horde" then
        local rows = FilterRows(ChampionsFor(categoryId), searchText)
        return {
            rows = rows,
            stats = { totalCount = #rows, earnedCount = #rows,
                totalPoints = #rows * CHAMPION_POINTS, donorCount = 0 },
        }
    end
    if categoryId and categoryId ~= "donors" and categoryId ~= "summary" then
        return {
            rows = {},
            stats = { totalCount = 0, earnedCount = 0, totalPoints = 0, donorCount = 0 },
        }
    end
    local rows = FilterRows(cache.rows, searchText)
    if rows == cache.rows then
        return cache
    end
    local points = 0
    for i = 1, #rows do
        points = points + (rows[i].points or 0)
    end
    return {
        rows = rows,
        stats = {
            totalCount = #rows,
            earnedCount = #rows,
            totalPoints = points,
            donorCount = #rows,
        },
    }
end

function Overlord.HallOfFameData:GetRecentHonorRows(limit, searchText)
    local view = self:GetHonorView("donors", searchText)
    limit = limit or #view.rows
    local out = {}
    local count = math.min(limit, #view.rows)
    for i = 1, count do
        out[i] = view.rows[i]
    end
    return out
end
