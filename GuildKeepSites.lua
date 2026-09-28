-- Fortress locations. All gameplay and synchronization use the Outpost engine.
Overlord = Overlord or {}
Overlord.FortressUsesOutposts = true
Overlord.GuildKeepSites = {
    stonetalon = {
        id = "stonetalon_guild_keep",
        siteKey = "stonetalon",
        displayNameKey = "GUILD_KEEP_STONETALON",
        mapID = 1442,
        mapIDs = { [406] = true, [1442] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "stonetalon", "serres-rocheuses", "sierra espuela", "steinkrall" },
        -- Retraite de Roche-Soleil (village Horde, terre).
        center = { 47.2, 61.2 },
        halfSize = 1.35,
        holdTimeRequired = 600,
    },
    wetlands = {
        id = "wetlands_guild_keep",
        siteKey = "wetlands",
        displayNameKey = "GUILD_KEEP_WETLANDS",
        mapID = 1437,
        mapIDs = { [56] = true, [1437] = true },
        mapNameNeedles = { "wetlands", "paluns", "les paluns", "sumpfland", "humedales", "болотина" },
        -- Donjon de Menethil. 21.4, 68.0 = baie (eau) sur la carte vanilla.
        center = { 10.6, 59.6 },
        halfSize = 1.35,
        holdTimeRequired = 600,
    },
    badlands = {
        id = "badlands_guild_keep",
        siteKey = "badlands",
        displayNameKey = "GUILD_KEEP_BADLANDS",
        mapID = 1418,
        mapIDs = { [15] = true, [1418] = true },
        mapNameNeedles = {
            "badlands", "badland", "terres ingrat", "terres ingrates",
            "tierras inhóspitas", "tierras inhospitas", "ödland", "odland",
        },
        -- Forteresse d'Angor.
        center = { 43.0, 30.8 },
        halfSize = 1.9,
        holdTimeRequired = 600,
    },
    crossroads = {
        id = "crossroads_guild_keep",
        siteKey = "crossroads",
        displayNameKey = "GUILD_KEEP_CROSSROADS",
        mapID = 1413,
        mapIDs = { [10] = true, [1413] = true },
        -- Pin Kalimdor continent (Retail 12 / Classic 1414).
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = {
            "barrens", "tarides", "brachland", "baldíos", "baldios",
            "northern barrens", "barrens du nord", "les tarides du nord",
            "crossroads", "la croisée", "la croisee", "el cruce", "wegekreuz",
            "степ", "перекресток",
        },
        -- La Croisee sur Les Tarides vanilla (49.2, 58.8 = Camp Taurajo / carte Retail).
        center = { 51.5, 30.2 },
        halfSize = 1.35,
        holdTimeRequired = 600,
    },
    mulgore = {
        id = "mulgore_guild_keep",
        siteKey = "mulgore",
        displayNameKey = "GUILD_KEEP_MULGORE",
        mapID = 1412,
        mapIDs = { [7] = true, [1412] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "mulgore" },
        -- Village de Sabot-de-Sang.
        center = { 47.5, 60.2 },
        halfSize = 1.35,
        holdTimeRequired = 600,
    },
}

for _, site in pairs(Overlord.GuildKeepSites) do
    site.isFortress = true
    site.standaloneOpenWorld = true
    site.includeChildMaps = false
end
