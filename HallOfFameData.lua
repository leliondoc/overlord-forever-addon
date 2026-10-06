-- HallOfFameData.lua - Hall of Fame Forever : champions de chaque semaine terminee
-- (top 5 tueurs, top 5 guildes, top 5 capteurs) et donateurs du tresor de guerre.
-- Entrees curatees a la main, affichage seulement : aucun reseau, aucun repere carte.
Overlord = Overlord or {}
Overlord.HallOfFameData = {}

local L = Overlord.L

-- Joueurs/guildes/Alliance/Horde ne montrent que les semaines du lancement et restent
-- masques tant qu'elles sont vides. La beta a sa propre categorie (simple pour une
-- semaine, une sous-categorie par semaine sinon, la plus recente en haut) : ses entrees
-- ne sont listees nulle part ailleurs.
Overlord.HallOfFameData.CATEGORIES = {
    { id = "player", labelKey = "HOF_CAT_PLAYER", hideWhenEmpty = true },
    { id = "guild", labelKey = "HOF_CAT_GUILD", hideWhenEmpty = true },
    { id = "alliance", labelKey = "HOF_CAT_ALLIANCE", hideWhenEmpty = true },
    { id = "horde", labelKey = "HOF_CAT_HORDE", hideWhenEmpty = true },
    { id = "beta", labelKey = "HOF_CAT_BETA", betaWeeks = true },
    { id = "donors", labelKey = "HOF_CAT_DONORS" },
}

-- Champions des semaines du lancement (meme forme que les entrees beta). A remplir
-- avec des lignes de rang propres au lancement : RANK_LINE ecrit "Beta week".
Overlord.WeeklyChampionEntries = {}

-- Beta : top 5 final des tueurs (kills), des guildes (kills) et des capteurs (captures).
-- Seule la semaine 1 reste en jeu, l'historique complet est sur le site. Avec une seule
-- semaine, la beta est une categorie simple ; plusieurs semaines deviennent des
-- sous-categories.
Overlord.BetaChampionEntries = {
    -- Semaine 1, campagne du 22/09/2026 au 29/09/2026.
    { week = 1, kind = "player", name = "Vaio Flæk", faction = "Alliance", kills = 6017 },
    { week = 1, kind = "player", name = "Big Topher", faction = "Alliance", kills = 5000 },
    { week = 1, kind = "player", name = "Il Blasfemo", faction = "Horde", kills = 4997 },
    { week = 1, kind = "player", name = "Risky Quickie", faction = "Alliance", kills = 4182 },
    { week = 1, kind = "player", name = "Imperial Constantius", faction = "Alliance", kills = 3693 },
    { week = 1, kind = "guild", name = "EMPIRE", faction = "Alliance", kills = 107659 },
    { week = 1, kind = "guild", name = "Elfcore", faction = "Alliance", kills = 47180 },
    { week = 1, kind = "guild", name = "Kor Kron Enforcers", faction = "Horde", kills = 15084 },
    { week = 1, kind = "guild", name = "jolékip", faction = "Horde", kills = 14454 },
    { week = 1, kind = "guild", name = "B I G P P V P", faction = "Alliance", kills = 10919 },
    { week = 1, kind = "capture", name = "Sllayer Menethil", faction = "Alliance", captures = 31 },
    { week = 1, kind = "capture", name = "Archdruid Thazung", faction = "Horde", captures = 28 },
    { week = 1, kind = "capture", name = "Rusty Nutz", faction = "Alliance", captures = 24 },
    { week = 1, kind = "capture", name = "Vaio Flæk", faction = "Alliance", captures = 24 },
    { week = 1, kind = "capture", name = "Jesinia Brightsky", faction = "Alliance", captures = 23 },
}

-- Comme sur Retail : nom sans couleur, la faction se lit a l'icone.
local CHAMPION_ICON = {
    player = { Alliance = "Interface\\Icons\\Achievement_PVP_A_15",
        Horde = "Interface\\Icons\\Achievement_PVP_H_15" },
    guild = { Alliance = "Interface\\Icons\\Achievement_PVP_A_05",
        Horde = "Interface\\Icons\\Achievement_PVP_H_05" },
    capture = { Alliance = "Interface\\Icons\\INV_BannerPVP_02",
        Horde = "Interface\\Icons\\INV_BannerPVP_01" },
}
local CHAMPION_POINTS = 10
-- Dans une semaine : tueurs, puis guildes, puis capteurs.
local KIND_ORDER = { player = 1, guild = 2, capture = 3 }
local RANK_LINE = {
    player = { key = "HOF_WEEKLY_PLAYER_RANK_LINE", fallback = "Beta week %d, killers: rank %d" },
    guild = { key = "HOF_WEEKLY_GUILD_RANK_LINE", fallback = "Beta week %d, guilds: rank %d" },
    capture = { key = "HOF_WEEKLY_CAPTURE_RANK_LINE", fallback = "Beta week %d, captures: rank %d" },
}

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

-- Semaine et position dans le classement final (tueurs, guildes ou capteurs).
local function ChampionSubtitle(kind, week, rank)
    local line = RANK_LINE[kind] or RANK_LINE.player
    local fmt = L and L[line.key]
    local specs = 0
    if type(fmt) == "string" then
        specs = select(2, fmt:gsub("%%", ""))
    end
    -- Exactement deux %d (semaine, rang) et aucun autre % : sinon format() casserait.
    if specs ~= 2 or select(2, fmt:gsub("%%d", "")) ~= 2 then
        fmt = line.fallback
    end
    return string.format(fmt, week, rank)
end

local function ChampionScore(entry)
    return tonumber(entry.kind == "capture" and entry.captures or entry.kills) or 0
end

-- Semaine la plus recente d'abord ; dans une semaine, tueurs, guildes puis capteurs,
-- chacun par score decroissant. Les lignes de sous-titre sont celles de la beta : les
-- semaines du lancement auront les leurs quand WeeklyChampionEntries se remplira.
local function BuildChampionRows(entries)
    local sorted = {}
    for _, entry in ipairs(entries or {}) do
        sorted[#sorted + 1] = entry
    end
    table.sort(sorted, function(a, b)
        local wa, wb = tonumber(a.week) or 0, tonumber(b.week) or 0
        if wa ~= wb then return wa > wb end
        local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
        if ka ~= kb then return ka < kb end
        local sa, sb = ChampionScore(a), ChampionScore(b)
        if sa ~= sb then return sa > sb end
        return a.name < b.name
    end)
    local rows = {}
    local rankBySlot = {}
    for i, entry in ipairs(sorted) do
        local week = tonumber(entry.week) or 0
        local slot = week .. ":" .. entry.kind
        rankBySlot[slot] = (rankBySlot[slot] or 0) + 1
        local subtitle = ChampionSubtitle(entry.kind, week, rankBySlot[slot])
        -- Un meme nom revient d'une semaine a l'autre : identite de carte distincte.
        entry.id = entry.id or ("w" .. slot .. ":" .. entry.name)
        rows[#rows + 1] = {
            kind = entry.kind,
            week = week,
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
    return rows
end

local function EnsureRows()
    if not donorRows then
        BuildDonorRows()
    end
    return donorRows
end

local function EnsureChampionRows()
    if not championRows then championRows = BuildChampionRows(Overlord.WeeklyChampionEntries) end
    return championRows
end

local betaRows, betaWeeks = nil, nil

local function EnsureBetaRows()
    if not betaRows then
        betaRows = BuildChampionRows(Overlord.BetaChampionEntries)
        betaWeeks = {}
        for _, row in ipairs(betaRows) do
            -- Lignes deja triees par semaine decroissante.
            if betaWeeks[#betaWeeks] ~= row.week then betaWeeks[#betaWeeks + 1] = row.week end
        end
    end
    return betaRows, betaWeeks
end

local BETA_WEEK_PREFIX = "beta:"

local function BetaWeekOf(categoryId)
    if type(categoryId) ~= "string" then return nil end
    return tonumber(categoryId:match("^beta:(%d+)$"))
end

local function BetaWeekRows(week)
    local out = {}
    for _, row in ipairs((EnsureBetaRows())) do
        if row.week == week then out[#out + 1] = row end
    end
    return out
end

local function ChampionsFor(categoryId)
    local out = {}
    for _, row in ipairs(EnsureChampionRows()) do
        if (categoryId == "player" and (row.kind == "player" or row.kind == "capture"))
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

-- Une categorie parente de la beta ouvre sa semaine la plus recente.
function Overlord.HallOfFameData:ResolveCategory(categoryId)
    if categoryId == "beta" then
        local _, weeks = EnsureBetaRows()
        if weeks[1] then return BETA_WEEK_PREFIX .. weeks[1] end
    end
    return categoryId
end

-- Premiere categorie visible a l'ouverture.
function Overlord.HallOfFameData:GetDefaultCategory()
    local entries = self:GetSidebarEntries(false)
    return self:ResolveCategory(entries[1] and entries[1].id or "donors")
end

function Overlord.HallOfFameData:IsBetaWeek(categoryId)
    return BetaWeekOf(categoryId) ~= nil
end

-- Boutons de la barre laterale : categories non vides ; les semaines beta (enfants
-- indentes) seulement quand la beta est depliee, comme sur Retail.
function Overlord.HallOfFameData:GetSidebarEntries(betaOpen)
    local out = {}
    for _, def in ipairs(self.CATEGORIES) do
        if def.betaWeeks then
            local _, weeks = EnsureBetaRows()
            if weeks[1] then
                out[#out + 1] = { id = def.id, label = L and L[def.labelKey] or def.id }
                if betaOpen and weeks[2] then
                    local fmt = L and L.HOF_CAT_BETA_WEEK
                    if type(fmt) ~= "string" or select(2, fmt:gsub("%%", "")) ~= 1
                        or not fmt:find("%d", 1, true) then
                        fmt = "Week %d"
                    end
                    for _, week in ipairs(weeks) do
                        out[#out + 1] = { id = BETA_WEEK_PREFIX .. week, isChild = true,
                            label = string.format(fmt, week) }
                    end
                end
            end
        elseif not def.hideWhenEmpty or #ChampionsFor(def.id) > 0 then
            out[#out + 1] = { id = def.id, label = L and L[def.labelKey] or def.id }
        end
    end
    return out
end

function Overlord.HallOfFameData:GetHonorView(categoryId, searchText)
    local cache = EnsureRows()
    local betaWeek = BetaWeekOf(categoryId)
    if betaWeek then
        local rows = FilterRows(BetaWeekRows(betaWeek), searchText)
        return {
            rows = rows,
            stats = { totalCount = #rows, earnedCount = #rows,
                totalPoints = #rows * CHAMPION_POINTS, donorCount = 0 },
        }
    end
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
