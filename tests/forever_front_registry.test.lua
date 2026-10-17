-- Every front's structure and names, in every client language (2.0.3, Hillsbrad
-- redrawn on 10 points): zones, both factions' prerequisites and the panel order
-- name the same points; every prerequisite exists; each capital is its own faction's
-- start and needs points of the other side; every point and every site has a name.
local files = { "Locales.lua", "GuideLocales.lua", "Locales_ptBR.lua", "Locales_zhCN.lua",
    "ForeverLocaleFixes.lua", "FrontLocales.lua" }

local function readAll(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function idSet(list)
    local set, n = {}, 0
    for _, id in ipairs(list) do
        assert(not set[id], "duplicate id " .. tostring(id))
        set[id] = true
        n = n + 1
    end
    return set, n
end

local function sameKeys(a, b, what)
    for k in pairs(a) do assert(b[k], what .. ": " .. k .. " missing") end
    for k in pairs(b) do assert(a[k], what .. ": " .. k .. " unexpected") end
end

-- Site name keys, read from the site tables without loading their engines.
local siteKeys = {}
for _, file in ipairs({ "Outpost.lua", "GuildKeepSites.lua" }) do
    for key in readAll(file):gmatch('displayNameKey%s*=%s*"([%w_]+)"') do siteKeys[#siteKeys + 1] = key end
end
-- 2.0.5: 11 outposts (one per front, plus four open-world sites) and 5 keeps.
assert(#siteKeys == 16, "expected 16 site name keys, found " .. #siteKeys)

for _, loc in ipairs({ "enUS", "frFR", "esES", "esMX", "deDE", "ruRU", "ptBR", "zhCN", "zhTW" }) do
    Overlord = { L = {} }
    Enum = { UIMapType = { Zone = 3, Continent = 2 } }
    GetLocale = function() return loc end
    for _, file in ipairs(files) do assert(loadfile(file))() end
    assert(loadfile("Fronts.lua"))()
    local L = Overlord.L
    local fronts = 0
    for _, frontId in ipairs(Overlord.Fronts.Order) do
        local front = assert(Overlord.Fronts.Registry[frontId], "unknown front " .. frontId)
        fronts = fronts + 1
        local ids = {}
        for _, zone in ipairs(front.zones) do
            ids[#ids + 1] = zone.id
            assert(type(zone.name) == "string" and zone.name ~= "" and zone.name ~= zone.id,
                loc .. ": " .. zone.id .. " has no name")
        end
        local zones = idSet(ids)
        assert(zones[front.allianceCapitalId] and zones[front.hordeCapitalId], frontId .. ": capital missing")
        for _, faction in ipairs({ "Alliance", "Horde" }) do
            local prereqs = front.prereqs[faction]
            sameKeys(zones, prereqs, frontId .. " " .. faction .. " prereqs")
            sameKeys(zones, (idSet(front.displayOrder[faction])), frontId .. " " .. faction .. " panel order")
            local own = faction == "Alliance" and front.allianceCapitalId or front.hordeCapitalId
            local enemy = faction == "Alliance" and front.hordeCapitalId or front.allianceCapitalId
            assert(#prereqs[own] == 0, frontId .. ": " .. faction .. " capital is not its start")
            assert(#prereqs[enemy] > 0, frontId .. ": " .. faction .. " reaches the enemy capital for free")
            assert(front.displayOrder[faction][1] == own, frontId .. ": " .. faction .. " panel does not start home")
            for id, list in pairs(prereqs) do
                for _, need in ipairs(list) do
                    assert(zones[need] and need ~= id, frontId .. " " .. faction .. ": " .. id .. " needs " .. tostring(need))
                end
            end
        end
        -- Each faction reaches every point from its capital, the enemy capital last, with
        -- no cycle (a point opens once all its prerequisites are held).
        for _, faction in ipairs({ "Alliance", "Horde" }) do
            local prereqs = front.prereqs[faction]
            local enemy = faction == "Alliance" and front.hordeCapitalId or front.allianceCapitalId
            local held, count = {}, 0
            for _ = 1, #ids do
                local opened = false
                for _, id in ipairs(ids) do
                    if not held[id] and (id ~= enemy or count == #ids - 1) then
                        local ready = true
                        for _, need in ipairs(prereqs[id]) do if not held[need] then ready = false end end
                        if ready then held[id], count, opened = true, count + 1, true end
                    end
                end
                if not opened then break end
            end
            assert(count == #ids, frontId .. ": " .. faction .. " cannot reach every point (" .. count .. "/" .. #ids .. ")")
        end
        -- The Horde walks the Alliance routes backwards: a point needs, for the Horde, the
        -- points that need it for the Alliance.
        local needers = {}
        for id, list in pairs(front.prereqs.Alliance) do
            for _, need in ipairs(list) do
                needers[need] = needers[need] or {}
                needers[need][id] = true
            end
        end
        for _, id in ipairs(ids) do
            local horde = {}
            for _, need in ipairs(front.prereqs.Horde[id]) do horde[need] = true end
            sameKeys(needers[id] or {}, horde, frontId .. " Horde mirror of " .. id)
        end
        -- Names are unique within a front.
        local seenNames = {}
        for _, zone in ipairs(front.zones) do
            assert(not seenNames[zone.name], loc .. ": " .. frontId .. " has two points named " .. zone.name)
            seenNames[zone.name] = true
        end
        -- The map's own prerequisites are the Alliance ones (same convention on every front).
        for _, zone in ipairs(front.zones) do
            local a = front.prereqs.Alliance[zone.id]
            assert(#zone.prereqZones == #a, frontId .. ": " .. zone.id .. " map prereqs differ from the Alliance ones")
            for i = 1, #a do assert(zone.prereqZones[i] == a[i], frontId .. ": " .. zone.id .. " map prereqs differ") end
        end
    end
    assert(fronts == 7, "seven fronts expected, got " .. fronts)
    local hillsbrad = Overlord.Fronts.Registry.hillsbrad
    assert(#hillsbrad.zones == 10, "Hillsbrad is a 10-point front")
    -- Each name on its own point (a shifted index in FrontLocales would still give
    -- unique, non-empty names).
    if loc == "enUS" then
        for id, name in pairs({ hillsbrad_southshore = "Southshore", hillsbrad_tarren_mill = "Tarren Mill",
            hillsbrad_fields = "Hillsbrad Fields", hillsbrad_bridge = "Hillsbrad Bridge",
            hillsbrad_nethander = "Nethander Stead", hillsbrad_durnholde = "Durnholde Keep",
            hillsbrad_western_strand = "Western Strand", hillsbrad_internment_camp = "Lordamere Camp",
            hillsbrad_dun_garok = "Dun Garok", hillsbrad_thoradin_gate = "Thoradin's Gate" }) do
            assert(L.ZONE_NAMES[id] == name, id .. " is named " .. tostring(L.ZONE_NAMES[id]))
        end
        assert(L.OUTPOST_HILLSBRAD_NAME == "Lordaeron Watch", "outpost named " .. tostring(L.OUTPOST_HILLSBRAD_NAME))
    end
    for _, key in ipairs(siteKeys) do
        assert(type(L[key]) == "string" and L[key] ~= "", loc .. ": site name " .. key .. " missing")
    end
    assert(L.OUTPOST_HILLSBRAD_NAME and L.OUTPOST_HILLSBRAD_NAME ~= "", loc .. ": no Hillsbrad outpost name")
end
print("Forever front registry: structure, panel order and names of 7 fronts and every site in 9 languages OK")
