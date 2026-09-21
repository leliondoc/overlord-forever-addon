-- HallOfFameData.lua - Donateurs du Hall of Fame.
-- Forever ne reprend que les joueurs qui ont versé de l'or au trésor de guerre.
Overlord = Overlord or {}
Overlord.HallOfFameData = {}

local L = Overlord.L

Overlord.HallOfFameData.CATEGORIES = {
    { id = "donors", labelKey = "HOF_CAT_DONORS" },
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

local function EnsureRows()
    if not donorRows then
        BuildDonorRows()
    end
    return donorRows
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

function Overlord.HallOfFameData:InvalidateCache()
    donorRows = nil
end

function Overlord.HallOfFameData:GetHonorView(categoryId, searchText)
    local cache = EnsureRows()
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

function Overlord.HallOfFameData:GetProgressStats()
    return EnsureRows().stats
end

function Overlord.HallOfFameData:GetTotalPoints()
    return EnsureRows().stats.totalPoints
end

function Overlord.HallOfFameData:GetDonorEntries()
    local cache = EnsureRows()
    local out = {}
    for i = 1, #cache.rows do
        local row = cache.rows[i]
        if row.data then
            out[#out + 1] = row.data
        end
    end
    return out
end
