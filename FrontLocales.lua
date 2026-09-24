-- Names for the Forever Redridge and two-point Hillsbrad fronts.
local L = Overlord.L
local locale = GetLocale() or "enUS"
local names = {
    enUS = { "Redridge Mountains", "Lakeshire", "Lakeshire", "Alther's Mill",
        "Tower of Ilgalar", "Three Corners", "Lakeridge Highway", "Stonewatch Falls",
        "Render's Valley", "Renosh Camp" },
    frFR = { "Les Carmines", "Comté-du-Lac", "Comté-du-Lac", "Moulin d'Alther",
        "Tour d'Ilgalar", "Les Trois Corners", "Route du lac", "Chutes de Guet-de-pierre",
        "Vallée de Render", "Camp de Renosh" },
    esES = { "Montañas Crestagrana", "Villa del Lago", "Villa del Lago", "Molino de Alther",
        "Torre de Ilgalar", "Tres Esquinas", "Camino del Lago", "Cascadas de Petravista",
        "Valle de Render", "Campamento de Renosh" },
    deDE = { "Rotkammgebirge", "Seenhain", "Seenhain", "Althers Mühle",
        "Turm von Ilgalar", "Drei Ecken", "Seeweg", "Steinwachfälle",
        "Renders Tal", "Renosh-Lager" },
    ruRU = { "Красногорье", "Приозерье", "Приозерье", "Мельница Алтера",
        "Башня Илгалара", "Три Угла", "Дорога у озера", "Водопад Каменной Стражи",
        "Долина Рендера", "Лагерь Реноша" },
    ptBR = { "Montanhas Cristarrubra", "Vila do Lago", "Vila do Lago", "Moinho de Alther",
        "Torre de Ilgalar", "Três Esquinas", "Estrada do Lago", "Cataratas da Vigília de Pedra",
        "Vale de Render", "Acampamento de Renosh" },
    zhCN = { "赤脊山", "湖畔镇", "湖畔镇", "阿尔瑟尔磨坊",
        "伊尔加拉之塔", "三岔路口", "湖边大道", "石堡瀑布",
        "伦德山谷", "雷诺什营地" },
}
names.esMX = names.esES
local n = names[locale] or names.enUS
local hillsbradNames = {
    enUS = { "Hillsbrad Foothills", "Southshore / Tarren Mill", "Southshore", "Tarren Mill" },
    frFR = { "Contreforts de Hautebrande", "Austrivage / Moulin-de-Tarren", "Austrivage", "Moulin-de-Tarren" },
    esES = { "Laderas de Trabalomas", "Costasur / Molino Tarren", "Costasur", "Molino Tarren" },
    deDE = { "Vorgebirge des Hügellands", "Süderstade / Tarrens Mühle", "Süderstade", "Tarrens Mühle" },
    ruRU = { "Предгорья Хилсбрада", "Южнобережье / Мельница Таррен", "Южнобережье", "Мельница Таррен" },
    ptBR = { "Contrafortes de Eira dos Montes", "Costa Sul / Moinho Tarren", "Costa Sul", "Moinho Tarren" },
    zhCN = { "希尔斯布莱德丘陵", "南海镇 / 塔伦米尔", "南海镇", "塔伦米尔" },
}
hillsbradNames.esMX = hillsbradNames.esES
local h = hillsbradNames[locale] or hillsbradNames.enUS
L.FRONT_HILLSBRAD_NAME = h[1]
L.FRONT_HILLSBRAD_DROPDOWN = h[2]
L.ZONE_NAMES.hillsbrad_southshore = h[3]
L.ZONE_NAMES.hillsbrad_tarren_mill = h[4]
local forestNames = {
    enUS = "Ashenvale Forest", frFR = "Forêt d'Orneval",
    esES = "Bosque de Vallefresno", esMX = "Bosque de Vallefresno",
    deDE = "Eschentalwald", ruRU = "Роща Ясеневого леса",
    ptBR = "Floresta de Vale Gris", zhCN = "灰谷森林",
}
L.WOOD_ZONE_ASHENVALE_FOREST = forestNames[locale] or forestNames.enUS
if locale == "ptBR" then L.WOOD_ZONE_WETLANDS_FOREST = "Floresta do Pantanal" end
L.FRONT_REDRIDGE_NAME = n[1]
L.FRONT_REDRIDGE_DROPDOWN = n[2]
L.OUTPOST_REDRIDGE_NAME = n[10]
-- Custom site name requested verbatim by the author, shared by all locales.
L.OUTPOST_AEYTHYR_LODGE_NAME = "Aeythyr Lodge"
for index, id in ipairs({ "redridge_lakeshire", "redridge_althers_mill", "redridge_ilgalar",
    "redridge_three_corners", "redridge_lakeridge_highway", "redridge_stonewatch_falls",
    "redridge_renders_valley" }) do
    L.ZONE_NAMES[id] = n[index + 2]
end

if locale == "ptBR" then
    local zones = {
        stromgarde = "Bastilha de Stromgarde", faldir = "Enseada de Faldir",
        witherbark = "Vila Cascasseca", goshek = "Fazenda de Go'Shek",
        dabyrie = "Fazenda de Dabyrie", refuge = "Ponta do Refúgio",
        highperch = "Planalto Ocidental", newstead = "Muralha de Thoradin",
        hammerfell = "Martelo da Ruína", argorok = "Círculo de União Ocidental",
        loch_alliance_capital = "Thelsamar", loch_horde_capital = "Fortaleza Mo'grosh",
        loch_valley_of_kings = "Vale dos Reis", loch_south_gate_pass = "Passagem do Portão Sul",
        loch_silver_stream_mine = "Mina do Riacho Prateado", loch_algaz_post = "Posto Algaz",
        loch_farstrider_lodge = "Refúgio dos Andarilhos", loch_ironband = "Escavação de Ferronato",
        loch_the_loch = "Lago — margem leste", loch_stonewrought_dam = "Represa de Pedraforja",
        durotar_tiragarde_keep = "Forte Tiragarde", durotar_alliance_fleet = "Penhasco Kolkar",
        durotar_senjin_village = "Vila Sen'jin", durotar_razor_hill = "Monte Navalha",
        durotar_deadeye_shore = "Praia do Olho Morto", durotar_southfury = "Rio Fúria do Sul",
        durotar_spirit_rock = "Vale das Provações", durotar_thunder_ridge = "Serra do Trovão",
        durotar_drygulch_ravine = "Ravina Seca", durotar_dranosh_blockade = "Acesso a Orgrimmar",
        ash_astranaar = "Astranaar", ash_iris_lake = "Lago Íris",
        ash_raynewood = "Retiro de Raynewood", ash_night_run = "Trilha Noturna",
        ash_bloodtooth_camp = "Acampamento Dentessangue", ash_silverwind = "Refúgio Ventoprata",
        ash_mystral_lake = "Lago Mystral — margem sul", ash_fallen_sky_lake = "Lago Céu Caído",
        ash_dor_danil = "Covil de Dor'Danil", ash_splintertree = "Posto Lenhatriz",
    }
    for id, name in pairs(zones) do L.ZONE_NAMES[id] = name end
    local elwynn = { "Guarnição Riach'Oeste", "Vila D'Ouro", "Torre de Azora",
        "Torre da Serra", "Lago Cristal", "Mina Vailafundo", "Pouso de Jerod",
        "Lago da Pedra", "Acampamento de Lenhadores de Valest", "Avanço Rocha Negra" }
    for index, id in ipairs({ "elwynn_westbrook", "elwynn_goldshire", "elwynn_tower_of_azora",
        "elwynn_ridgepoint", "elwynn_mirror_lake", "elwynn_fargodeep",
        "elwynn_jerods_landing", "elwynn_stone_cairn", "elwynn_eastvale",
        "elwynn_invasion_camp" }) do L.ZONE_NAMES[id] = elwynn[index] end
elseif locale == "zhCN" then
    local zones = {
        stromgarde = "激流堡", faldir = "法迪尔海湾", witherbark = "枯木村",
        goshek = "格沙克农场", dabyrie = "达比雷农场", refuge = "避难谷地",
        highperch = "西部高地", newstead = "索拉丁之墙", hammerfell = "落锤镇",
        argorok = "西部禁锢法阵", loch_alliance_capital = "塞尔萨玛",
        loch_horde_capital = "莫格罗什要塞", loch_valley_of_kings = "国王谷",
        loch_south_gate_pass = "南门小径", loch_silver_stream_mine = "银泉矿洞",
        loch_algaz_post = "奥加兹岗哨", loch_farstrider_lodge = "远行者小屋",
        loch_ironband = "铁环挖掘场", loch_the_loch = "洛克湖东岸",
        loch_stonewrought_dam = "巨石水坝", durotar_tiragarde_keep = "提拉加德城堡",
        durotar_alliance_fleet = "科尔卡峭壁", durotar_senjin_village = "森金村",
        durotar_razor_hill = "剃刀岭", durotar_deadeye_shore = "死眼海岸",
        durotar_southfury = "怒水河", durotar_spirit_rock = "试炼谷",
        durotar_thunder_ridge = "雷霆山脊", durotar_drygulch_ravine = "枯水谷",
        durotar_dranosh_blockade = "奥格瑞玛入口", ash_astranaar = "阿斯特兰纳",
        ash_iris_lake = "伊瑞斯湖", ash_raynewood = "林中树居",
        ash_night_run = "夜道谷", ash_bloodtooth_camp = "血牙营地",
        ash_silverwind = "银风避难所", ash_mystral_lake = "密斯特拉湖—南岸",
        ash_fallen_sky_lake = "坠星湖", ash_dor_danil = "朵丹尼尔兽穴",
        ash_splintertree = "碎木岗哨",
    }
    for id, name in pairs(zones) do L.ZONE_NAMES[id] = name end
    local elwynn = { "西泉要塞", "闪金镇", "阿祖拉之塔", "山脊塔楼", "水晶湖",
        "法戈第矿洞", "杰罗德码头", "石碑湖", "东谷伐木场", "黑石前哨" }
    for index, id in ipairs({ "elwynn_westbrook", "elwynn_goldshire", "elwynn_tower_of_azora",
        "elwynn_ridgepoint", "elwynn_mirror_lake", "elwynn_fargodeep",
        "elwynn_jerods_landing", "elwynn_stone_cairn", "elwynn_eastvale",
        "elwynn_invasion_camp" }) do L.ZONE_NAMES[id] = elwynn[index] end
end
