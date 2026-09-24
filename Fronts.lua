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

local GILNEAS_ALLIANCE_PREREQS = {
    gilneas_alliance_capital = {},
    gilneas_eminence = {"gilneas_alliance_capital"},
    gilneas_keel_harbor = {"gilneas_eminence"},
    gilneas_lighthouse = {"gilneas_keel_harbor"},
    gilneas_emberstone_mine = {"gilneas_lighthouse"},
    gilneas_hayward_fisheries = {"gilneas_alliance_capital"},
    gilneas_stormglen = {"gilneas_hayward_fisheries"},
    gilneas_tempest_reach = {"gilneas_stormglen"},
    gilneas_aderic_repose = {"gilneas_tempest_reach"},
    gilneas_horde_capital = {"gilneas_emberstone_mine", "gilneas_aderic_repose"},
}

local GILNEAS_HORDE_PREREQS = {
    gilneas_horde_capital = {},
    gilneas_emberstone_mine = {"gilneas_horde_capital"},
    gilneas_lighthouse = {"gilneas_emberstone_mine"},
    gilneas_keel_harbor = {"gilneas_lighthouse"},
    gilneas_eminence = {"gilneas_keel_harbor"},
    gilneas_aderic_repose = {"gilneas_horde_capital"},
    gilneas_tempest_reach = {"gilneas_aderic_repose"},
    gilneas_stormglen = {"gilneas_tempest_reach"},
    gilneas_hayward_fisheries = {"gilneas_stormglen"},
    gilneas_alliance_capital = {"gilneas_eminence", "gilneas_hayward_fisheries"},
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
    -- Meme regle que Durotar/Gilneas : les 2 sorties de la capitale adverse.
    loch_alliance_capital = {"loch_valley_of_kings", "loch_silver_stream_mine"},
}

-- Tarides du Sud : Alliance part du nord (capitale), Horde des 2 approches sud/est.
-- Ancien graphe Alliance faisait bael (sud) puis remonter vers hunters (nord) : chemin inverse.
local SB_ALLIANCE_PREREQS = {
    sb_alliance_capital = {},
    sb_hunters_hill = {"sb_alliance_capital"},
    sb_the_tangle = {"sb_alliance_capital"},
    sb_ruins_of_taurajo = {"sb_hunters_hill"},
    sb_battlescar = {"sb_ruins_of_taurajo"},
    sb_bael_modan = {"sb_battlescar"},
    sb_frazzlecraz_motherlode = {"sb_bael_modan"},
    sb_razorfen_kraul = {"sb_frazzlecraz_motherlode"},
    sb_northwatch_hold = {"sb_the_tangle"},
    sb_horde_capital = {"sb_northwatch_hold", "sb_razorfen_kraul"},
}

local SB_HORDE_PREREQS = {
    sb_horde_capital = {},
    sb_northwatch_hold = {"sb_horde_capital"},
    sb_razorfen_kraul = {"sb_horde_capital"},
    sb_the_tangle = {"sb_northwatch_hold"},
    sb_frazzlecraz_motherlode = {"sb_razorfen_kraul"},
    sb_bael_modan = {"sb_frazzlecraz_motherlode"},
    sb_battlescar = {"sb_bael_modan"},
    sb_ruins_of_taurajo = {"sb_battlescar"},
    sb_hunters_hill = {"sb_ruins_of_taurajo"},
    sb_alliance_capital = {"sb_hunters_hill", "sb_the_tangle"},
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

local ASHENVALE_ALLIANCE_PREREQS = {
    ash_astranaar = {},
    ash_iris_lake = {"ash_astranaar"},
    ash_raynewood = {"ash_iris_lake"},
    ash_night_run = {"ash_raynewood"},
    ash_bloodtooth_camp = {"ash_night_run"},
    ash_silverwind = {"ash_astranaar"},
    ash_mystral_lake = {"ash_silverwind"},
    ash_fallen_sky_lake = {"ash_mystral_lake"},
    ash_dor_danil = {"ash_fallen_sky_lake"},
    ash_splintertree = {"ash_bloodtooth_camp", "ash_dor_danil"},
}

local ASHENVALE_HORDE_PREREQS = {
    ash_splintertree = {},
    ash_bloodtooth_camp = {"ash_splintertree"},
    ash_dor_danil = {"ash_splintertree"},
    ash_night_run = {"ash_bloodtooth_camp"},
    ash_fallen_sky_lake = {"ash_dor_danil"},
    ash_raynewood = {"ash_night_run"},
    ash_mystral_lake = {"ash_fallen_sky_lake"},
    ash_iris_lake = {"ash_raynewood"},
    ash_silverwind = {"ash_mystral_lake"},
    ash_astranaar = {"ash_iris_lake", "ash_silverwind"},
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
            Zone("highperch", { center = {25.19, 40.13}, radius = 3, prereqZones = {"stromgarde"} }),
            Zone("newstead", { center = {18.04, 47.22}, radius = 3, prereqZones = {"refuge"} }),
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
            Zone("ash_iris_lake", { center = {45.82, 43.25}, prereqZones = {"ash_astranaar"} }),
            Zone("ash_raynewood", { center = {60.96, 51.84}, prereqZones = {"ash_iris_lake"} }),
            Zone("ash_night_run", { center = {66.6, 56.0}, prereqZones = {"ash_raynewood"} }),
            Zone("ash_bloodtooth_camp", { center = {54.75, 79.62}, prereqZones = {"ash_night_run"} }),
            Zone("ash_silverwind", { center = {50.5, 66.0}, prereqZones = {"ash_astranaar"} }),
            Zone("ash_mystral_lake", { center = {50.84, 75.08}, prereqZones = {"ash_silverwind"} }),
            Zone("ash_fallen_sky_lake", { center = {65.88, 80.30}, prereqZones = {"ash_mystral_lake"} }),
            Zone("ash_dor_danil", { center = {72.0, 74.0}, prereqZones = {"ash_fallen_sky_lake"} }),
            Zone("ash_splintertree", { center = {73.5, 61.0}, radius = 5, prereqZones = {"ash_bloodtooth_camp", "ash_dor_danil"}, isCapital = true }),
        },
        prereqs = {
            Alliance = ASHENVALE_ALLIANCE_PREREQS,
            Horde = ASHENVALE_HORDE_PREREQS,
        },
        displayOrder = {
            Alliance = {
                "ash_astranaar",
                "ash_iris_lake", "ash_silverwind",
                "ash_raynewood", "ash_mystral_lake",
                "ash_night_run", "ash_fallen_sky_lake",
                "ash_bloodtooth_camp", "ash_dor_danil",
                "ash_splintertree",
            },
            Horde = {
                "ash_splintertree",
                "ash_bloodtooth_camp", "ash_dor_danil",
                "ash_night_run", "ash_fallen_sky_lake",
                "ash_raynewood", "ash_mystral_lake",
                "ash_iris_lake", "ash_silverwind",
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
}

Overlord.Fronts.Order = {"arathi", "loch_modan", "durotar", "ashenvale", "elwynn", "redridge"}
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
    for _, front in ipairs(OrderedFronts(self)) do
        for _, zone in ipairs(front.zones or {}) do
            if zone.id == zoneId then return zone, front end
        end
    end
    return nil
end

function Overlord.Fronts:IsKnownZoneId(zoneId)
    return self:GetZone(zoneId) ~= nil
end

function Overlord.Fronts:GetMapID(frontId)
    local front = self:GetFront(frontId)
    if not front then return nil end
    -- Les coordonnees de ce registre sont celles de la carte Vanilla.
    -- Ne pas choisir au hasard un alias Retail si les deux cartes existent.
    if front.preferredMapID then
        local ok, info = pcall(C_Map.GetMapInfo, front.preferredMapID)
        if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
            return front.preferredMapID
        end
    end
    local function PickZoneMapID()
        local fallback = nil
        for mapID in pairs(front.mapIDs or {}) do
            fallback = fallback or mapID
            local ok, info = pcall(C_Map.GetMapInfo, mapID)
            if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
                return mapID
            end
        end
        return fallback
    end
    if front.resolvedMapID then
        local ok, info = pcall(C_Map.GetMapInfo, front.resolvedMapID)
        if ok and info and MapTypeAllowsFrontOverlay(info.mapType) then
            return front.resolvedMapID
        end
        -- resolvedMapID peut etre Kalimdor (1) via la hierarchie : preferer la Zone locale.
        return PickZoneMapID()
    end
    return PickZoneMapID()
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

function Overlord.Fronts:ResolveFrontByMapID(mapID)
    if not mapID then return nil end
    local seen = {}
    local currentMapID = mapID
    local depth = 0
    while currentMapID and currentMapID > 0 and not seen[currentMapID] and depth < 5 do
        seen[currentMapID] = true
        for _, front in ipairs(OrderedFronts(self)) do
            if front.excludedMapIDs and front.excludedMapIDs[currentMapID] then
                return nil
            end
            if front.mapIDs and front.mapIDs[currentMapID] then
                front.resolvedMapID = currentMapID
                return front
            end
        end

        local ok, info = pcall(C_Map.GetMapInfo, currentMapID)
        if not ok or not info then return nil end
        if info.name then
            for _, front in ipairs(OrderedFronts(self)) do
                if not NameMatches(info.name, front.excludedNameNeedles or {}) and NameMatches(info.name, front.mapNameNeedles or {}) then
                    front.resolvedMapID = currentMapID
                    if front.mapIDs then front.mapIDs[currentMapID] = true end
                    return front
                end
            end
        end
        currentMapID = info.parentMapID or 0
        depth = depth + 1
    end
    return nil
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
}

local FEATURED_FRONT_NAME_KEYS = {
    arathi = "FRONT_ARATHI_NAME",
    loch_modan = "FRONT_LOCH_MODAN_NAME",
    durotar = "FRONT_DUROTAR_NAME",
    ashenvale = "FRONT_ASHENVALE_NAME",
    elwynn = "FRONT_ELWYNN_NAME",
    redridge = "FRONT_REDRIDGE_NAME",
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
    local gk = Overlord.GuildKeep
    if not gk or not gk.GetServerSiegeDayKey then return nil end
    local dayKey = gk.GetServerCalendarDayKey and gk:GetServerCalendarDayKey()
        or gk:GetServerSiegeDayKey()
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
