-- Fronts.lua - Configuration des fronts de guerre Overlord
-- Chaque front porte ses zones, capitales, prérequis et règles de carte.
Overlord = Overlord or {}
Overlord.Fronts = Overlord.Fronts or {}

local L = Overlord.L

-- Cache mapID -> front pour overlays (evite C_Map.GetMapInfo a 60 Hz).
local overlayFrontByMapID = {}

-- Rayon de capture : -40 % par rapport aux valeurs historiques du registre.
local CAPTURE_RADIUS_SCALE = 0.60
Overlord.Fronts.CaptureRadiusScale = CAPTURE_RADIUS_SCALE

local function Zone(id, opts)
    local nominalRadius = opts.radius or 4
    return {
        id = id,
        name = L.ZONE_NAMES[id],
        center = opts.center,
        radius = nominalRadius * CAPTURE_RADIUS_SCALE,
        labelRadius = nominalRadius,
        holdTimeRequired = opts.holdTimeRequired or 120,
        prereqZones = opts.prereqZones or {},
        status = opts.status or "locked",
        killsCurrent = 0,
        holdTimeElapsed = 0,
        isHolding = false,
        capturedTime = nil,
        isCapital = opts.isCapital or nil,
    }
end

local ARATHI_ALLIANCE_PREREQS = {
    stromgarde = {},
    faldir = {"stromgarde"},
    witherbark = {"faldir"},
    goshek = {"witherbark"},
    dabyrie = {"goshek"},
    refuge = {"argorok"},
    highperch = {"stromgarde"},
    newstead = {"refuge"},
    hammerfell = {"dabyrie", "newstead"},
    argorok = {"highperch"},
}

local ARATHI_HORDE_PREREQS = {
    hammerfell = {},
    dabyrie    = {"hammerfell"},
    goshek     = {"dabyrie"},
    witherbark = {"goshek"},
    faldir     = {"witherbark"},
    newstead   = {"hammerfell"},
    refuge     = {"newstead"},
    argorok    = {"refuge"},
    highperch  = {"argorok"},
    stromgarde = {"faldir", "highperch"},
}

local LOCH_ALLIANCE_PREREQS = {
    loch_alliance_capital = {},
    loch_valley_of_kings = {"loch_alliance_capital"},
    loch_south_gate_pass = {"loch_valley_of_kings"},
    loch_silver_stream_mine = {"loch_alliance_capital"},
    loch_algaz_post = {"loch_silver_stream_mine"},
    loch_farstrider_lodge = {"loch_south_gate_pass"},
    loch_ironband = {"loch_farstrider_lodge"},
    loch_stonewrought_dam = {"loch_algaz_post"},
    loch_the_loch = {"loch_stonewrought_dam"},
    loch_horde_capital = {"loch_ironband", "loch_the_loch"},
}

local LOCH_HORDE_PREREQS = {
    loch_horde_capital = {},
    loch_ironband = {"loch_horde_capital"},
    loch_the_loch = {"loch_horde_capital"},
    loch_farstrider_lodge = {"loch_ironband"},
    loch_stonewrought_dam = {"loch_the_loch"},
    loch_south_gate_pass = {"loch_farstrider_lodge"},
    loch_algaz_post = {"loch_stonewrought_dam"},
    loch_valley_of_kings = {"loch_south_gate_pass"},
    loch_silver_stream_mine = {"loch_algaz_post"},
    -- Meme regle que Durotar : les 2 sorties de la capitale adverse.
    loch_alliance_capital = {"loch_valley_of_kings", "loch_silver_stream_mine"},
}

local DUROTAR_ALLIANCE_PREREQS = {
    durotar_tiragarde_keep = {},
    durotar_alliance_fleet = {"durotar_tiragarde_keep"},
    durotar_senjin_village = {"durotar_alliance_fleet"},
    durotar_razor_hill = {"durotar_senjin_village"},
    durotar_deadeye_shore = {"durotar_razor_hill"},
    durotar_southfury = {"durotar_tiragarde_keep"},
    durotar_spirit_rock = {"durotar_southfury"},
    durotar_thunder_ridge = {"durotar_spirit_rock"},
    durotar_drygulch_ravine = {"durotar_thunder_ridge"},
    durotar_dranosh_blockade = {"durotar_deadeye_shore", "durotar_drygulch_ravine"},
}

local DUROTAR_HORDE_PREREQS = {
    durotar_dranosh_blockade = {},
    durotar_deadeye_shore = {"durotar_dranosh_blockade"},
    durotar_drygulch_ravine = {"durotar_dranosh_blockade"},
    durotar_razor_hill = {"durotar_deadeye_shore"},
    durotar_thunder_ridge = {"durotar_drygulch_ravine"},
    durotar_senjin_village = {"durotar_razor_hill"},
    durotar_spirit_rock = {"durotar_thunder_ridge"},
    durotar_alliance_fleet = {"durotar_senjin_village"},
    durotar_southfury = {"durotar_spirit_rock"},
    durotar_tiragarde_keep = {"durotar_alliance_fleet", "durotar_southfury"},
}

-- Layout miroir Durotar : 2 branches depuis chaque capitale, graphes inversibles.
-- Branche nord : Westbrook -> Goldshire -> Azora -> Ridgepoint -> Cairn -> Val-est
-- Branche sud  : Westbrook -> Lac de Cristal -> Fondugouffre -> Jerod
local ELWYNN_ALLIANCE_PREREQS = {
    elwynn_westbrook = {},
    elwynn_goldshire = {"elwynn_westbrook"},
    elwynn_tower_of_azora = {"elwynn_goldshire"},
    elwynn_ridgepoint = {"elwynn_tower_of_azora"},
    elwynn_stone_cairn = {"elwynn_ridgepoint"},
    elwynn_eastvale = {"elwynn_stone_cairn"},
    elwynn_mirror_lake = {"elwynn_westbrook"},
    elwynn_fargodeep = {"elwynn_mirror_lake"},
    elwynn_jerods_landing = {"elwynn_fargodeep"},
    elwynn_invasion_camp = {"elwynn_eastvale", "elwynn_jerods_landing"},
}

local ELWYNN_HORDE_PREREQS = {
    elwynn_invasion_camp = {},
    elwynn_eastvale = {"elwynn_invasion_camp"},
    elwynn_jerods_landing = {"elwynn_invasion_camp"},
    elwynn_stone_cairn = {"elwynn_eastvale"},
    elwynn_ridgepoint = {"elwynn_stone_cairn"},
    elwynn_tower_of_azora = {"elwynn_ridgepoint"},
    elwynn_goldshire = {"elwynn_tower_of_azora"},
    elwynn_fargodeep = {"elwynn_jerods_landing"},
    elwynn_mirror_lake = {"elwynn_fargodeep"},
    elwynn_westbrook = {"elwynn_goldshire", "elwynn_mirror_lake"},
}

-- 1.7.1 : Orneval couvre toute la zone (l'ouest et le sud-ouest etaient vides).
-- Branche nord : Astranaar -> Maestra -> rivage de Zoram -> route de Sombrivage -> lac
-- Iris -> Bois-Raide -> Bois-Brise. Branche sud : Astranaar -> sanctuaire d'Aessina ->
-- ile de Poussiere-d'etoile -> Dor'Danil -> Bois-Brise. La Horde suit les memes chemins
-- en sens inverse. Night Run, Bloodtooth, Silverwind, Mystral et le lac du Ciel-dechu
-- disparaissent (entasses a l'est) : le front garde 10 points.
local ASHENVALE_ALLIANCE_PREREQS = {
    ash_astranaar = {},
    ash_maestra = {"ash_astranaar"},
    ash_zoram_strand = {"ash_maestra"},
    ash_darkshore_road = {"ash_zoram_strand"},
    ash_iris_lake = {"ash_darkshore_road"},
    ash_raynewood = {"ash_iris_lake"},
    ash_aessina = {"ash_astranaar"},
    ash_stardust = {"ash_aessina"},
    ash_dor_danil = {"ash_stardust"},
    ash_splintertree = {"ash_raynewood", "ash_dor_danil"},
}

local ASHENVALE_HORDE_PREREQS = {
    ash_splintertree = {},
    ash_raynewood = {"ash_splintertree"},
    ash_iris_lake = {"ash_raynewood"},
    ash_darkshore_road = {"ash_iris_lake"},
    ash_zoram_strand = {"ash_darkshore_road"},
    ash_maestra = {"ash_zoram_strand"},
    ash_dor_danil = {"ash_splintertree"},
    ash_stardust = {"ash_dor_danil"},
    ash_aessina = {"ash_stardust"},
    ash_astranaar = {"ash_maestra", "ash_aessina"},
}

local function NameMatches(infoName, needles)
    if not infoName then return false end
    local nl = infoName:lower()
    for _, needle in ipairs(needles) do
        local n = needle:lower()
        if nl:find(n, 1, true) then return true end
    end
    return false
end

--- Overlays (cercles + libelles) : uniquement la carte Zone du front (coords en % locales).
--- Cosmic / World / Continent = repères XY differents → libelles partout si on dessine la.
local function MapTypeAllowsFrontOverlay(mapType)
    if mapType == nil then return false end
    local E = Enum and Enum.UIMapType
    if not E then return false end
    return mapType == E.Zone
end

-- Positions terrestres de reference : docs/forever-capture-locations.md.
-- Les IDs historiques restent stables, y compris les anciens noms Retail.
Overlord.Fronts.Registry = {
    arathi = {
        id = "arathi",
        preferredMapID = 1417,
        mapName = L.FRONT_ARATHI_NAME or "Arathi Highlands",
        dropdownLabel = L.FRONT_ARATHI_DROPDOWN or "Arathi",
        -- Positions Vanilla / Forever ; conserver les IDs pour les captures et les bridges.
        mapIDs = { [14] = true, [1417] = true },
        excludedMapIDs = Overlord.FRONT_EXCLUDED_BATTLEGROUND_MAP_IDS or { [3358] = true, [10440] = true },
        mapNameNeedles = {"arathi"},
        excludedNameNeedles = {"basin", "bassin", "becken", "cuenca"},
        allianceCapitalId = "stromgarde",
        hordeCapitalId = "hammerfell",
        zones = {
            Zone("stromgarde", { center = {25.38, 58.36}, radius = 5, status = "captured", isCapital = true }),
            Zone("faldir", { center = {32.28, 81.38}, prereqZones = {"stromgarde"} }),
            Zone("witherbark", { center = {62.0, 74.0}, prereqZones = {"faldir"} }),
            Zone("goshek", { center = {61.88, 57.33}, radius = 3, prereqZones = {"witherbark"} }),
            Zone("dabyrie", { center = {54.18, 38.09}, radius = 3, prereqZones = {"goshek"} }),
            Zone("refuge", { center = {45.83, 47.56}, prereqZones = {"argorok"} }),
            Zone("highperch", { center = {44.0, 79.4}, radius = 3, prereqZones = {"stromgarde"} }),
            Zone("newstead", { center = {21.2, 34.0}, radius = 3, prereqZones = {"refuge"} }),
            Zone("hammerfell", { center = {74.18, 33.96}, radius = 5, prereqZones = {"dabyrie", "newstead"}, isCapital = true }),
            Zone("argorok", { center = {27.43, 31.39}, prereqZones = {"highperch"} }),
        },
        prereqs = {
            Alliance = ARATHI_ALLIANCE_PREREQS,
            Horde = ARATHI_HORDE_PREREQS,
        },
        displayOrder = {
            Alliance = {"stromgarde", "faldir", "highperch", "witherbark", "argorok", "goshek", "refuge", "dabyrie", "newstead", "hammerfell"},
            Horde = {"hammerfell", "dabyrie", "newstead", "goshek", "refuge", "witherbark", "argorok", "faldir", "highperch", "stromgarde"},
        },
    },
    loch_modan = {
        id = "loch_modan",
        preferredMapID = 1432,
        mapName = L.FRONT_LOCH_MODAN_NAME or "Loch Modan",
        dropdownLabel = L.FRONT_LOCH_MODAN_DROPDOWN or "Loch Modan",
        mapIDs = { [48] = true, [1432] = true },
        mapNameNeedles = { "loch modan" },
        allianceCapitalId = "loch_alliance_capital",
        hordeCapitalId = "loch_horde_capital",
        panelHeads = {
            Alliance = "DWARF_MALE",
            HordeIcon = 236695, -- achievement_reputation_ogre (pas sur la feuille Classic)
            faceInward = true,
            hordeMirror = false,
        },
        zones = {
            Zone("loch_alliance_capital", { center = {35.4, 46.6}, radius = 5, status = "captured", isCapital = true }),
            Zone("loch_valley_of_kings", { center = {22.07, 73.13}, prereqZones = {"loch_alliance_capital"} }),
            Zone("loch_south_gate_pass", { center = {18.18, 84.01}, prereqZones = {"loch_valley_of_kings"} }),
            Zone("loch_farstrider_lodge", { center = {82.6, 64.2}, prereqZones = {"loch_south_gate_pass"} }),
            Zone("loch_ironband", { center = {69.2, 63.8}, prereqZones = {"loch_farstrider_lodge"} }),
            Zone("loch_silver_stream_mine", { center = {34.6, 21.2}, prereqZones = {"loch_alliance_capital"} }),
            Zone("loch_algaz_post", { center = {24.5, 17.3}, prereqZones = {"loch_silver_stream_mine"} }),
            Zone("loch_stonewrought_dam", { center = {46.05, 13.61}, prereqZones = {"loch_algaz_post"} }),
            Zone("loch_the_loch", { center = {63.56, 47.92}, prereqZones = {"loch_stonewrought_dam"} }),
            Zone("loch_horde_capital", { center = {69.8, 24.1}, radius = 5, prereqZones = {"loch_ironband", "loch_the_loch"}, isCapital = true }),
        },
        prereqs = {
            Alliance = LOCH_ALLIANCE_PREREQS,
            Horde = LOCH_HORDE_PREREQS,
        },
        displayOrder = {
            Alliance = {
                "loch_alliance_capital",
                "loch_valley_of_kings", "loch_silver_stream_mine",
                "loch_south_gate_pass", "loch_algaz_post",
                "loch_farstrider_lodge", "loch_stonewrought_dam",
                "loch_ironband", "loch_the_loch",
                "loch_horde_capital",
            },
            Horde = {
                "loch_horde_capital",
                "loch_ironband", "loch_the_loch",
                "loch_farstrider_lodge", "loch_stonewrought_dam",
                "loch_south_gate_pass", "loch_algaz_post",
                "loch_valley_of_kings", "loch_silver_stream_mine",
                "loch_alliance_capital",
            },
        },
    },
    durotar = {
        id = "durotar",
        preferredMapID = 1411,
        mapName = L.FRONT_DUROTAR_NAME or "Durotar",
        dropdownLabel = L.FRONT_DUROTAR_DROPDOWN or "Durotar",
        mapIDs = { [1] = true, [1411] = true },
        mapNameNeedles = { "durotar" },
        allianceCapitalId = "durotar_tiragarde_keep",
        hordeCapitalId = "durotar_dranosh_blockade",
        panelHeads = {
            Alliance = "NIGHTELF_FEMALE",
            Horde = "ORC_FEMALE",
            faceInward = true,
            hordeMirror = false,
        },
        zones = {
            Zone("durotar_tiragarde_keep", { center = {58.4, 57.2}, radius = 5, status = "captured", isCapital = true }),
            Zone("durotar_alliance_fleet", { center = {52.08, 82.03}, prereqZones = {"durotar_tiragarde_keep"} }),
            Zone("durotar_senjin_village", { center = {54.8, 74.1}, prereqZones = {"durotar_alliance_fleet"} }),
            Zone("durotar_razor_hill", { center = {52.6, 42.5}, prereqZones = {"durotar_senjin_village"} }),
            Zone("durotar_deadeye_shore", { center = {59.4, 24.3}, prereqZones = {"durotar_razor_hill"} }),
            Zone("durotar_southfury", { center = {39.9, 36.6}, prereqZones = {"durotar_tiragarde_keep"} }),
            Zone("durotar_spirit_rock", { center = {44.63, 68.65}, prereqZones = {"durotar_southfury"} }),
            Zone("durotar_thunder_ridge", { center = {39.2, 25.4}, prereqZones = {"durotar_spirit_rock"} }),
            Zone("durotar_drygulch_ravine", { center = {49.1, 29.1}, prereqZones = {"durotar_thunder_ridge"} }),
            Zone("durotar_dranosh_blockade", { center = {46.10, 13.77}, radius = 5, prereqZones = {"durotar_deadeye_shore", "durotar_drygulch_ravine"}, isCapital = true }),
        },
        prereqs = {
            Alliance = DUROTAR_ALLIANCE_PREREQS,
            Horde = DUROTAR_HORDE_PREREQS,
        },
        displayOrder = {
            Alliance = {
                "durotar_tiragarde_keep",
                "durotar_alliance_fleet", "durotar_southfury",
                "durotar_senjin_village", "durotar_spirit_rock",
                "durotar_razor_hill", "durotar_thunder_ridge",
                "durotar_deadeye_shore", "durotar_drygulch_ravine",
                "durotar_dranosh_blockade",
            },
            Horde = {
                "durotar_dranosh_blockade",
                "durotar_deadeye_shore", "durotar_drygulch_ravine",
                "durotar_razor_hill", "durotar_thunder_ridge",
                "durotar_senjin_village", "durotar_spirit_rock",
                "durotar_alliance_fleet", "durotar_southfury",
                "durotar_tiragarde_keep",
            },
        },
    },
    ashenvale = {
        id = "ashenvale",
        preferredMapID = 1440,
        mapName = L.FRONT_ASHENVALE_NAME or "Ashenvale",
        dropdownLabel = L.FRONT_ASHENVALE_DROPDOWN or "Ashenvale",
        mapIDs = { [63] = true, [1440] = true },
        mapNameNeedles = {
            "ashenvale", "orneval", "ashenvale forest",
            "eschental", "vallefresno",
        },
        allianceCapitalId = "ash_astranaar",
        hordeCapitalId = "ash_splintertree",
        panelHeads = {
            Alliance = "NIGHTELF_FEMALE",
            Horde = "ORC_MALE",
            faceInward = true,
            hordeMirror = false,
        },
        zones = {
            Zone("ash_astranaar", { center = {35.0, 49.0}, radius = 5, status = "captured", isCapital = true }),
            -- Ouest (1.7.1, places sur la carte Classic) : poste de Maestra, milieu du rivage
            -- de Zoram, route du nord vers Sombrivage, sanctuaire d'Aessina, ile au sud d'Astranaar.
            Zone("ash_maestra", { center = {26.0, 38.5}, prereqZones = {"ash_astranaar"} }),
            Zone("ash_zoram_strand", { center = {16.0, 23.5}, prereqZones = {"ash_maestra"} }),
            Zone("ash_darkshore_road", { center = {27.0, 22.0}, prereqZones = {"ash_zoram_strand"} }),
            Zone("ash_iris_lake", { center = {45.82, 43.25}, prereqZones = {"ash_darkshore_road"} }),
            Zone("ash_raynewood", { center = {60.96, 51.84}, prereqZones = {"ash_iris_lake"} }),
            Zone("ash_aessina", { center = {22.0, 52.7}, prereqZones = {"ash_astranaar"} }),
            Zone("ash_stardust", { center = {32.9, 67.2}, prereqZones = {"ash_aessina"} }),
            Zone("ash_dor_danil", { center = {72.0, 74.0}, prereqZones = {"ash_stardust"} }),
            Zone("ash_splintertree", { center = {73.5, 61.0}, radius = 5, prereqZones = {"ash_raynewood", "ash_dor_danil"}, isCapital = true }),
        },
        prereqs = {
            Alliance = ASHENVALE_ALLIANCE_PREREQS,
            Horde = ASHENVALE_HORDE_PREREQS,
        },
        displayOrder = {
            Alliance = {
                "ash_astranaar",
                "ash_maestra", "ash_aessina",
                "ash_zoram_strand", "ash_stardust",
                "ash_darkshore_road", "ash_dor_danil",
                "ash_iris_lake", "ash_raynewood",
                "ash_splintertree",
            },
            Horde = {
                "ash_splintertree",
                "ash_raynewood", "ash_dor_danil",
                "ash_iris_lake", "ash_stardust",
                "ash_darkshore_road", "ash_aessina",
                "ash_zoram_strand", "ash_maestra",
                "ash_astranaar",
            },
        },
    },
    elwynn = {
        id = "elwynn",
        preferredMapID = 1429,
        mapName = L.FRONT_ELWYNN_NAME or "Elwynn Forest",
        dropdownLabel = L.FRONT_ELWYNN_DROPDOWN or "Elwynn",
        mapIDs = { [37] = true, [1429] = true },
        mapNameNeedles = { "elwynn", "elwyn", "艾尔文", "엘윈" },
        allianceCapitalId = "elwynn_westbrook",
        hordeCapitalId = "elwynn_invasion_camp",
        panelHeads = {
            Alliance = "HUMAN_MALE", Horde = "ORC_MALE",
            faceInward = true, hordeMirror = false,
        },
        zones = {
            Zone("elwynn_westbrook", { center = {24.2, 74.5}, radius = 5, status = "captured", isCapital = true }),
            Zone("elwynn_goldshire", { center = {42.1, 65.9}, prereqZones = {"elwynn_westbrook"} }),
            Zone("elwynn_tower_of_azora", { center = {64.7, 69.5}, prereqZones = {"elwynn_goldshire"} }),
            Zone("elwynn_ridgepoint", { center = {83.8, 78.7}, prereqZones = {"elwynn_tower_of_azora"} }),
            Zone("elwynn_stone_cairn", { center = {74.3, 51.4}, prereqZones = {"elwynn_ridgepoint"} }),
            Zone("elwynn_eastvale", { center = {82.0, 66.2}, prereqZones = {"elwynn_stone_cairn"} }),
            Zone("elwynn_mirror_lake", { center = {49.8, 68.1}, prereqZones = {"elwynn_westbrook"} }),
            Zone("elwynn_fargodeep", { center = {39.0, 82.6}, prereqZones = {"elwynn_mirror_lake"} }),
            Zone("elwynn_jerods_landing", { center = {48.4, 87.7}, prereqZones = {"elwynn_fargodeep"} }),
            Zone("elwynn_invasion_camp", { center = {90.9, 73.7}, radius = 5,
                prereqZones = {"elwynn_eastvale", "elwynn_jerods_landing"}, isCapital = true }),
        },
        prereqs = { Alliance = ELWYNN_ALLIANCE_PREREQS, Horde = ELWYNN_HORDE_PREREQS },
        displayOrder = {
            Alliance = { "elwynn_westbrook", "elwynn_goldshire", "elwynn_mirror_lake",
                "elwynn_tower_of_azora", "elwynn_fargodeep", "elwynn_ridgepoint",
                "elwynn_jerods_landing", "elwynn_stone_cairn", "elwynn_eastvale",
                "elwynn_invasion_camp" },
            Horde = { "elwynn_invasion_camp", "elwynn_eastvale", "elwynn_jerods_landing",
                "elwynn_stone_cairn", "elwynn_fargodeep", "elwynn_ridgepoint",
                "elwynn_mirror_lake", "elwynn_tower_of_azora", "elwynn_goldshire",
                "elwynn_westbrook" },
        },
    },
    redridge = {
        id = "redridge",
        preferredMapID = 1433,
        mapName = L.FRONT_REDRIDGE_NAME or "Redridge Mountains",
        dropdownLabel = L.FRONT_REDRIDGE_DROPDOWN or "Lakeshire",
        mapIDs = { [49] = true, [1433] = true },
        mapNameNeedles = { "redridge", "carmines", "crestagrana", "rotkamm", "赤脊山" },
        allianceCapitalId = "redridge_lakeshire",
        hordeCapitalId = "redridge_renders_valley",
        panelHeads = {
            Alliance = "HUMAN_MALE", Horde = "ORC_MALE",
            faceInward = true, hordeMirror = false,
        },
        -- Two land routes around Lake Everstill meet at Stonewatch Falls.
        zones = {
            Zone("redridge_lakeshire", { center = {25.0, 43.0}, radius = 5, status = "captured", isCapital = true }),
            Zone("redridge_althers_mill", { center = {53.0, 42.0}, prereqZones = {"redridge_lakeshire"} }),
            Zone("redridge_ilgalar", { center = {80.0, 49.0}, prereqZones = {"redridge_althers_mill"} }),
            Zone("redridge_three_corners", { center = {18.0, 69.0}, prereqZones = {"redridge_lakeshire"} }),
            Zone("redridge_lakeridge_highway", { center = {38.0, 73.0}, prereqZones = {"redridge_three_corners"} }),
            Zone("redridge_stonewatch_falls", { center = {75.0, 67.0},
                prereqZones = {"redridge_ilgalar", "redridge_lakeridge_highway"} }),
            Zone("redridge_renders_valley", { center = {73.0, 78.0}, radius = 5,
                prereqZones = {"redridge_stonewatch_falls"}, isCapital = true }),
        },
        prereqs = {
            Alliance = {
                redridge_lakeshire = {},
                redridge_althers_mill = {"redridge_lakeshire"},
                redridge_ilgalar = {"redridge_althers_mill"},
                redridge_three_corners = {"redridge_lakeshire"},
                redridge_lakeridge_highway = {"redridge_three_corners"},
                redridge_stonewatch_falls = {"redridge_ilgalar", "redridge_lakeridge_highway"},
                redridge_renders_valley = {"redridge_stonewatch_falls"},
            },
            Horde = {
                redridge_renders_valley = {},
                redridge_stonewatch_falls = {"redridge_renders_valley"},
                redridge_ilgalar = {"redridge_stonewatch_falls"},
                redridge_lakeridge_highway = {"redridge_stonewatch_falls"},
                redridge_althers_mill = {"redridge_ilgalar"},
                redridge_three_corners = {"redridge_lakeridge_highway"},
                redridge_lakeshire = {"redridge_althers_mill", "redridge_three_corners"},
            },
        },
        displayOrder = {
            Alliance = { "redridge_lakeshire", "redridge_althers_mill", "redridge_three_corners",
                "redridge_ilgalar", "redridge_lakeridge_highway", "redridge_stonewatch_falls",
                "redridge_renders_valley" },
            Horde = { "redridge_renders_valley", "redridge_stonewatch_falls",
                "redridge_ilgalar", "redridge_lakeridge_highway", "redridge_althers_mill",
                "redridge_three_corners", "redridge_lakeshire" },
        },
    },
    hillsbrad = {
        id = "hillsbrad",
        preferredMapID = 1424,
        mapName = L.FRONT_HILLSBRAD_NAME or "Hillsbrad Foothills",
        dropdownLabel = L.FRONT_HILLSBRAD_DROPDOWN or "Hillsbrad Foothills",
        mapIDs = { [25] = true, [1424] = true },
        excludedMapIDs = { [623] = true }, -- Southshore vs. Tarren Mill battleground
        mapNameNeedles = { "hillsbrad", "hautebrande", "laderas de trabalomas",
            "hügelland", "предгорья хилсбрада", "contrafortes de eira dos montes", "希尔斯布莱德" },
        allianceCapitalId = "hillsbrad_southshore",
        hordeCapitalId = "hillsbrad_tarren_mill",
        panelHeads = {
            Alliance = "HUMAN_MALE", Horde = "UNDEAD_MALE",
            faceInward = true, hordeMirror = false,
        },
        -- Two town circles (halved in 1.1.11). The registry's 0.60 capture scale makes radius 7.5 = 4.5 map units.
        zones = {
            Zone("hillsbrad_southshore", { center = {51.2, 58.0}, radius = 7.5,
                status = "captured", isCapital = true }),
            Zone("hillsbrad_tarren_mill", { center = {61.8, 19.0}, radius = 7.5,
                prereqZones = {"hillsbrad_southshore"}, isCapital = true }),
        },
        prereqs = {
            Alliance = {
                hillsbrad_southshore = {},
                hillsbrad_tarren_mill = {"hillsbrad_southshore"},
            },
            Horde = {
                hillsbrad_tarren_mill = {},
                hillsbrad_southshore = {"hillsbrad_tarren_mill"},
            },
        },
        displayOrder = {
            Alliance = { "hillsbrad_southshore", "hillsbrad_tarren_mill" },
            Horde = { "hillsbrad_tarren_mill", "hillsbrad_southshore" },
        },
    },
}

Overlord.Fronts.Order = {"arathi", "loch_modan", "durotar", "ashenvale", "elwynn", "redridge", "hillsbrad"}
if not Overlord.Fronts.activeFrontId then
    Overlord.Fronts.activeFrontId = "arathi"
end

local function OrderedFronts(self)
    local fronts = {}
    for _, frontId in ipairs(self.Order or {}) do
        local front = self.Registry and self.Registry[frontId]
        if front then
            table.insert(fronts, front)
        end
    end
    return fronts
end

function Overlord.Fronts:GetFront(frontId)
    return self.Registry and self.Registry[frontId or self.activeFrontId]
end

function Overlord.Fronts:GetCurrentFront()
    return self:GetFront(self.activeFrontId)
end

function Overlord.Fronts:GetZone(zoneId, frontId)
    if not zoneId then return nil end
    if frontId then
        local front = self:GetFront(frontId)
        for _, zone in ipairs((front and front.zones) or {}) do
            if zone.id == zoneId then return zone, front end
        end
        return nil
    end
    local index = self:_ZoneIndex()
    local zone = index.zone[zoneId]
    if zone then return zone, index.front[zoneId] end
    return nil
end

-- zoneId -> (zone, front) over every front in Order, first front wins (same answer
-- as the former scan). A full-map ZA apply called GetZone hundreds of times, each
-- allocating a fronts list and scanning ~70 zones (perf audit 2026-10-01). The
-- signature (each front's zones table and length) rebuilds it if a list changes.
function Overlord.Fronts:_ZoneIndex()
    local index = self._zoneIndexCache
    local order, registry = self.Order or {}, self.Registry or {}
    if index then
        local valid = index.orderLen == #order
        for i = 1, #order do
            if not valid then break end
            local front = registry[order[i]]
            local zones = front and front.zones
            valid = index.lists[i] == zones and index.lengths[i] == (zones and #zones or 0)
        end
        if valid then return index end
    end
    index = { zone = {}, front = {}, lists = {}, lengths = {}, orderLen = #order }
    for i = 1, #order do
        local front = registry[order[i]]
        local zones = front and front.zones
        index.lists[i], index.lengths[i] = zones, zones and #zones or 0
        for _, zone in ipairs(zones or {}) do
            if zone.id ~= nil and index.zone[zone.id] == nil then
                index.zone[zone.id], index.front[zone.id] = zone, front
            end
        end
    end
    self._zoneIndexCache = index
    return index
end

function Overlord.Fronts:IsKnownZoneId(zoneId)
    return self:GetZone(zoneId) ~= nil
end

-- Second retour : true quand la carte a ete validee par C_Map (resultat stable).
local function ComputeFrontMapID(front)
    -- Les coordonnees de ce registre sont celles de la carte Vanilla.
    -- Ne pas choisir au hasard un alias Retail si les deux cartes existent.
    if front.preferredMapID then
        local ok, info = pcall(C_Map.GetMapInfo, front.preferredMapID)
        if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
            return front.preferredMapID, true
        end
    end
    local function PickZoneMapID()
        local fallback = nil
        for mapID in pairs(front.mapIDs or {}) do
            fallback = fallback or mapID
            local ok, info = pcall(C_Map.GetMapInfo, mapID)
            if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
                return mapID, true
            end
        end
        return fallback, false
    end
    if front.resolvedMapID then
        local ok, info = pcall(C_Map.GetMapInfo, front.resolvedMapID)
        if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
            return front.resolvedMapID, true
        end
        -- resolvedMapID peut etre Kalimdor (1) via la hierarchie : preferer la Zone locale.
        return PickZoneMapID()
    end
    return PickZoneMapID()
end

-- Appele des milliers de fois par minute (minicarte, HUD, sync) : les cartes ne
-- changent pas en session, on memorise le resultat valide par front. Un
-- resultat non valide (donnees de carte pas encore pretes) est recalcule.
function Overlord.Fronts:GetMapID(frontId)
    local front = self:GetFront(frontId)
    if not front then return nil end
    -- Raw ids compared (up to ~400 calls/s while moving): no key string per call.
    local preferred, resolved = front.preferredMapID, front.resolvedMapID
    if front._olMapIDSet and front._olMapIDPref == preferred and front._olMapIDRes == resolved then
        return front._olMapID
    end
    local mapID, validated = ComputeFrontMapID(front)
    -- Ne figer que la carte preferee (ou une carte validee s'il n'y en a pas) :
    -- une carte de secours prise pendant que la preferee n'etait pas prete doit
    -- ceder sa place des que la preferee est disponible.
    if validated and (not front.preferredMapID or mapID == front.preferredMapID) then
        front._olMapIDSet, front._olMapIDPref, front._olMapIDRes, front._olMapID = true, preferred, resolved, mapID
    end
    return mapID
end

function Overlord.Fronts:GetMapName(frontId)
    local front = self:GetFront(frontId)
    return front and front.mapName or ""
end

function Overlord.Fronts:GetCapitalId(faction, frontId)
    local front = self:GetFront(frontId)
    if not front then return nil end
    return (faction == "Horde") and front.hordeCapitalId or front.allianceCapitalId
end

function Overlord.Fronts:GetEnemyCapitalId(attackingFaction, frontId)
    local enemy = (attackingFaction == "Horde") and "Alliance" or "Horde"
    return self:GetCapitalId(enemy, frontId)
end

-- mapID -> { front = front|false, at = resolved map id }. The registry is static and
-- the walk does not depend on the active front, so a finished walk is final. Outside
-- every front the walk (5 levels, map info and name needles of every front) ran on
-- each strategic tick and each layer event. A walk cut short by missing map data
-- (loading screen) is not remembered.
local frontByMapID = {}
function Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not mapID then return nil end
    local cached = frontByMapID[mapID]
    if cached then
        if not cached.front then return nil end
        cached.front.resolvedMapID = cached.at
        return cached.front
    end
    local function remember(front, at)
        frontByMapID[mapID] = { front = front or false, at = at }
        if front then front.resolvedMapID = at end
        return front or nil
    end
    local seen = {}
    local currentMapID = mapID
    local depth = 0
    local fronts = OrderedFronts(self)
    while currentMapID and currentMapID > 0 and not seen[currentMapID] and depth < 5 do
        seen[currentMapID] = true
        for _, front in ipairs(fronts) do
            if front.excludedMapIDs and front.excludedMapIDs[currentMapID] then
                return remember(nil)
            end
            if front.mapIDs and front.mapIDs[currentMapID] then
                return remember(front, currentMapID)
            end
        end

        local ok, info = pcall(C_Map.GetMapInfo, currentMapID)
        if not ok or not info then return nil end
        if info.name then
            for _, front in ipairs(fronts) do
                if not NameMatches(info.name, front.excludedNameNeedles or {}) and NameMatches(info.name, front.mapNameNeedles or {}) then
                    if front.mapIDs then front.mapIDs[currentMapID] = true end
                    return remember(front, currentMapID)
                end
            end
        end
        currentMapID = info.parentMapID or 0
        depth = depth + 1
    end
    return remember(nil)
end

function Overlord.Fronts:ResolveFrontByOverlayMapID(mapID)
    if not mapID then return nil end
    if overlayFrontByMapID[mapID] ~= nil then
        local cached = overlayFrontByMapID[mapID]
        return cached == false and nil or cached
    end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if not ok or not info then
        overlayFrontByMapID[mapID] = false
        return nil
    end
    if not MapTypeAllowsFrontOverlay(info.mapType) then
        overlayFrontByMapID[mapID] = false
        return nil
    end
    for _, front in ipairs(OrderedFronts(self)) do
        if front.excludedMapIDs and front.excludedMapIDs[mapID] then
            overlayFrontByMapID[mapID] = false
            return nil
        end
        if front.mapIDs and front.mapIDs[mapID] then
            overlayFrontByMapID[mapID] = front
            return front
        end
        if info.name
            and not NameMatches(info.name, front.excludedNameNeedles or {})
            and NameMatches(info.name, front.mapNameNeedles or {}) then
            overlayFrontByMapID[mapID] = front
            return front
        end
    end
    overlayFrontByMapID[mapID] = false
    return nil
end

function Overlord.Fronts:IsFrontMapID(mapID, frontId)
    local front = self:ResolveFrontByMapID(mapID)
    return front and (not frontId or front.id == frontId) or false
end

function Overlord.Fronts:IsActiveFrontMapID(mapID)
    return self:IsFrontMapID(mapID, self.activeFrontId)
end

function Overlord.Fronts:Activate(frontId)
    local front = self:GetFront(frontId)
    if not front then return nil end
    local prevId = self.activeFrontId
    local changed = prevId ~= front.id or Overlord.ZoneDatabase ~= front.zones
    if prevId ~= front.id then
        if OverlordDB and OverlordDB.config then
            OverlordDB.config.uiPanelFrontId = nil
        end
        if Overlord.IsInitialized and Overlord.UI and Overlord.UI:IsVisible() then
            C_Timer.After(0, function()
                if Overlord.UI and Overlord.UI.Refresh then
                    Overlord.UI:RequestRefresh()
                end
            end)
        end
    end
    self.activeFrontId = front.id
    Overlord.ZoneDatabase = front.zones
    if Overlord.Zones and Overlord.Zones.RebuildZoneLookup then
        Overlord.Zones:RebuildZoneLookup()
    end
    if changed and Overlord.MapMarkers then
        wipe(overlayFrontByMapID)
        if Overlord.MapMarkers.HideAllOverlays then Overlord.MapMarkers:HideAllOverlays() end
        if Overlord.MapMarkers.HideAllPaths then Overlord.MapMarkers:HideAllPaths() end
        if Overlord.MapMarkers.HideMinimapPins then Overlord.MapMarkers:HideMinimapPins() end
        if Overlord.MapMarkers.OnActiveFrontChanged then Overlord.MapMarkers:OnActiveFrontChanged() end
    end
    -- Init login : ApplyFactionConfig + RestoreZoneState dans Core:Initialize().
    -- Ici (front actif en jeu) : ne pas reset owner/status - sync inactive + passive
    -- tiennent les objets zone à jour ; un reset effaçait l'état frais et rechargeait une DB stale.
    if changed and Overlord.IsInitialized and Overlord.Zones and Overlord.PlayerFaction then
        Overlord.Zones:ApplyFrontPrereqs(Overlord.PlayerFaction, front.zones)
        Overlord.Zones:UpdateAvailableZones()
        if Overlord.UI and Overlord.UI.Refresh then
            Overlord.UI:RequestRefresh()
        end
        C_Timer.After(0.5, function()
            if not Overlord.IsInitialized or Overlord.InstanceSuspended then return end
            if Overlord.Fronts.activeFrontId ~= front.id then return end
            if Overlord.Sync and Overlord.Sync.SendSyncRequest then
                Overlord.Sync:SendSyncRequest()
            end
        end)
    end
    return front
end

Overlord.Fronts:Activate(Overlord.Fronts.activeFrontId)

-- ==================== Front du jour (rotation serveur) ====================

-- Hors rotation bonus : cartes de départ / futurs continents (pas Arathi-Gilneas-Loch-Barrens).
local FEATURED_FRONT_EXCLUDED = {
}

local FEATURED_FRONT_ART = {
    arathi = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-ArathiHighlands.blp",
    loch_modan = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-LochModan.blp",
    durotar = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-Durotar.blp",
    ashenvale = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-Ashenvale.blp",
    elwynn = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-ElwynnForest.blp",
    redridge = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-RedridgeMountains.blp",
    hillsbrad = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-HillsbradFoothills.blp",
}

-- Outside a war front: the player's homeland, same WarBoard art as the fronts.
-- There is no capital-city WarBoard; each race's starting zone holds its capital
-- (Elwynn/Stormwind, Durotar/Orgrimmar, Dun Morogh/Ironforge and Gnomeregan,
-- Teldrassil/Darnassus, Tirisfal/Undercity, Mulgore/Thunder Bluff). Forever
-- races only. Skyborne (Zephras Isle, no WarBoard art) take their faction's
-- capital: Stormwind (Elwynn) for Alliance, Orgrimmar (Durotar) for Horde.
local HOME_ART_DIR = "Interface\\QuestionFrame\\Answer-WarBoard-Classic-"
local HOME_ART_BY_RACE = {
    Human = "ElwynnForest", Dwarf = "DunMorogh", Gnome = "DunMorogh", NightElf = "Teldrassil",
    Orc = "Durotar", Troll = "Durotar", Scourge = "TirisfalGlades", Tauren = "Mulgore",
}
local HOME_ART_BY_FACTION = { Alliance = "ElwynnForest", Horde = "Durotar" }

local function HomeRaceAndFaction()
    local raceFile = UnitRace and select(2, UnitRace("player"))
    -- One token per race (any spelling of Skyborne becomes "Skyborne").
    local sync = Overlord.Sync
    if raceFile and sync and sync.NormalizeRaceFileToken then
        raceFile = sync:NormalizeRaceFileToken(raceFile) or raceFile
    end
    return raceFile, Overlord.PlayerFaction or UnitFactionGroup("player") or ""
end

function Overlord.Fronts:GetHomeArtPath()
    local raceFile, faction = HomeRaceAndFaction()
    local art = raceFile and HOME_ART_BY_RACE[raceFile] or HOME_ART_BY_FACTION[faction]
    return art and (HOME_ART_DIR .. art .. ".blp") or nil
end

-- Short race motto shown as the panel title outside a front (Locales HOME_MOTTOS).
function Overlord.Fronts:GetHomeMotto()
    local mottos = Overlord.L and Overlord.L.HOME_MOTTOS
    if type(mottos) ~= "table" then return nil end
    local raceFile, faction = HomeRaceAndFaction()
    return raceFile and mottos[raceFile] or mottos[faction]
end

local FEATURED_FRONT_NAME_KEYS = {
    arathi = "FRONT_ARATHI_NAME",
    loch_modan = "FRONT_LOCH_MODAN_NAME",
    durotar = "FRONT_DUROTAR_NAME",
    ashenvale = "FRONT_ASHENVALE_NAME",
    elwynn = "FRONT_ELWYNN_NAME",
    redridge = "FRONT_REDRIDGE_NAME",
    hillsbrad = "FRONT_HILLSBRAD_NAME",
}

local featuredFrontCacheDayKey = nil
local featuredFrontCacheId = nil

local function GetFeaturedFrontRotationIds(fronts)
    local ids = {}
    for _, frontId in ipairs(fronts.Order or {}) do
        if not FEATURED_FRONT_EXCLUDED[frontId] and fronts:GetFront(frontId) then
            ids[#ids + 1] = frontId
        end
    end
    return ids
end

local function ResolveFeaturedFrontIndex(dayKey, rotationCount)
    local n = tonumber(dayKey)
    if not n or n <= 0 or not rotationCount or rotationCount <= 0 then return nil end
    return (n % rotationCount) + 1
end

function Overlord.Fronts:GetFeaturedFrontId()
    local dayKey = date("%Y%m%d", time())
    if not dayKey or dayKey == "" then return nil end
    if featuredFrontCacheDayKey == dayKey and featuredFrontCacheId then
        return featuredFrontCacheId
    end
    local rotation = GetFeaturedFrontRotationIds(self)
    if #rotation == 0 then return nil end
    local idx = ResolveFeaturedFrontIndex(dayKey, #rotation)
    if not idx then return nil end
    local frontId = rotation[idx]
    if not frontId or not self:GetFront(frontId) then return nil end
    featuredFrontCacheDayKey = dayKey
    featuredFrontCacheId = frontId
    return frontId
end

function Overlord.Fronts:GetFeaturedFrontArtPath(frontId)
    if not frontId then return nil end
    return FEATURED_FRONT_ART[frontId]
end

function Overlord.Fronts:GetFeaturedFrontDisplayName(frontId)
    if not frontId then return nil end
    local key = FEATURED_FRONT_NAME_KEYS[frontId]
    if not key or not L then return nil end
    local name = L[key]
    if not name or name == "" then return nil end
    return name
end

-- Mini-icone identite front (panneau activite recente) : vignettes WarBoard Blizzard.
function Overlord.Fronts:GetFrontActivityIcon(frontId)
    if not frontId then return nil end
    local art = FEATURED_FRONT_ART[frontId]
    if not art then return nil end
    return {
        kind = "texture",
        path = art,
        texCoord = { 0.18, 0.82, 0.12, 0.88 },
    }
end

function Overlord.Fronts:IsFeaturedFrontActive()
    if not Overlord.InActiveFront then return false end
    local featuredId = self:GetFeaturedFrontId()
    if not featuredId then return false end
    local activeId = self.activeFrontId
    return activeId and activeId == featuredId
end
