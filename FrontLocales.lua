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
L.FRONT_HILLSBRAD_DROPDOWN = h[1]
L.ZONE_NAMES.hillsbrad_southshore = h[3]
L.ZONE_NAMES.hillsbrad_tarren_mill = h[4]
L.FRONT_REDRIDGE_NAME = n[1]
L.FRONT_REDRIDGE_DROPDOWN = n[1]
L.OUTPOST_REDRIDGE_NAME = n[10]
-- Standalone outpost names, translated per locale.
local standaloneOutpostNames = {
    enUS = { "Savix Chapel", "Aeythyr Lodge", "Lesi's Bear Cave" },
    frFR = { "Chapelle de Savix", "Pavillon d'Aeythyr", "Grotte de l'ours de Lesi" },
    esES = { "Capilla de Savix", "Pabellón de Aeythyr", "Cueva del oso de Lesi" },
    deDE = { "Kapelle von Savix", "Aeythyrs Jagdhütte", "Lesis Bärenhöhle" },
    ruRU = { "Часовня Савикса", "Охотничий домик Эйтира", "Медвежья пещера Леси" },
    ptBR = { "Capela Savix", "Pavilhão de Aeythyr", "Caverna do Urso de Lesi" },
    zhCN = { "萨维克斯教堂", "艾西尔小屋", "莱西熊洞" },
}
standaloneOutpostNames.esMX = standaloneOutpostNames.esES
local outpostNames = standaloneOutpostNames[locale] or standaloneOutpostNames.enUS
L.OUTPOST_SILVERPINE_NAME = outpostNames[1]
L.OUTPOST_AEYTHYR_LODGE_NAME = outpostNames[2]
L.OUTPOST_LESI_BEAR_CAVE_NAME = outpostNames[3]
-- World map filter toggle (Blizzard "Map Filters" menu and /ov map).
local mapFilterTexts = {
    enUS = { "Overlord zones", "World map display: on", "World map display: off" },
    frFR = { "Zones Overlord", "Affichage sur la carte : activé", "Affichage sur la carte : désactivé" },
    esES = { "Zonas de Overlord", "Mostrar en el mapa: activado", "Mostrar en el mapa: desactivado" },
    deDE = { "Overlord-Zonen", "Kartenanzeige: an", "Kartenanzeige: aus" },
    ruRU = { "Зоны Overlord", "Отображение на карте: вкл.", "Отображение на карте: выкл." },
    ptBR = { "Zonas do Overlord", "Exibição no mapa: ativada", "Exibição no mapa: desativada" },
    zhCN = { "Overlord 区域", "地图显示：开启", "地图显示：关闭" },
}
mapFilterTexts.esMX = mapFilterTexts.esES
local mapFilter = mapFilterTexts[locale] or mapFilterTexts.enUS
L.MAP_FILTER_OVERLORD, L.MAP_FILTER_SHOWN, L.MAP_FILTER_HIDDEN = mapFilter[1], mapFilter[2], mapFilter[3]
-- Settings texts that describe where things now live (coins and next objective
-- are always in the Overlord panel; floating versions are opt-in).
-- { coins label, coins tooltip, floating objective label, floating objective tooltip,
--   top HUD tooltip, tutorial book tooltip }
local settingsTexts = {
    enUS = {
        "Floating coins panel",
        "Your coins, Reinforce and Attack are always in the Overlord panel (Next Objective card). Turn on to also show them at the top of the screen near coin mines. Off by default.",
        "Floating next objective",
        "The next objective is always shown in the Overlord panel. Turn on to also show it in a small window in the middle of the screen when you are not capturing. Off by default.",
        "Auto shows the relevant top panels near coin mines, capture zones and guild keeps when the floating coins panel is on. Always shows them on eligible maps; Never hides them.",
        "Shows the tutorial book icon on the top HUD. Turn off to hide only that icon.",
    },
    frFR = {
        "Panneau des coins flottant",
        "Vos coins, Renforcer et Attaquer sont toujours dans le panneau Overlord (carte Prochain objectif). Activez pour les afficher aussi en haut de l'écran près des mines de coins. Désactivé par défaut.",
        "Prochain objectif flottant",
        "Le prochain objectif est toujours affiché dans le panneau Overlord. Activez pour l'afficher aussi dans une petite fenêtre au milieu de l'écran quand vous ne capturez pas. Désactivé par défaut.",
        "Auto affiche les panneaux du haut utiles près des mines de coins, des zones de capture et des fortins quand le panneau des coins flottant est activé. Toujours les affiche sur les cartes concernées ; Jamais les masque.",
        "Affiche l'icône livre du tutoriel sur le HUD du haut. Désactivez pour masquer uniquement cette icône.",
    },
    esES = {
        "Panel de monedas flotante",
        "Tus monedas, Reforzar y Atacar están siempre en el panel de Overlord (tarjeta Próximo objetivo). Actívalo para mostrarlos también arriba de la pantalla cerca de las minas. Desactivado por defecto.",
        "Próximo objetivo flotante",
        "El próximo objetivo se muestra siempre en el panel de Overlord. Actívalo para mostrarlo también en una pequeña ventana en el centro de la pantalla cuando no estés capturando. Desactivado por defecto.",
        "Auto muestra los paneles superiores útiles cerca de las minas, las zonas de captura y las fortalezas cuando el panel de monedas flotante está activado. Siempre los muestra en los mapas correspondientes; Nunca los oculta.",
        "Muestra el icono del libro tutorial en el HUD superior. Desactívalo para ocultar solo ese icono.",
    },
    deDE = {
        "Schwebende Münzleiste",
        "Deine Münzen, Verstärken und Angreifen sind immer im Overlord-Fenster (Karte Nächstes Ziel). Aktivieren, um sie zusätzlich oben am Bildschirm in der Nähe von Minen zu zeigen. Standardmäßig aus.",
        "Schwebendes nächstes Ziel",
        "Das nächste Ziel steht immer im Overlord-Fenster. Aktivieren, um es zusätzlich in einem kleinen Fenster in der Bildschirmmitte zu zeigen, wenn du nicht eroberst. Standardmäßig aus.",
        "Auto zeigt die passenden oberen Leisten in der Nähe von Minen, Eroberungszonen und Gildenfestungen, wenn die schwebende Münzleiste aktiv ist. Immer zeigt sie auf passenden Karten; Nie blendet sie aus.",
        "Zeigt das Tutorial-Buch-Symbol im oberen HUD. Deaktivieren, um nur dieses Symbol auszublenden.",
    },
    ruRU = {
        "Плавающая панель монет",
        "Монеты, «Укрепить» и «Атаковать» всегда есть в окне Overlord (карточка «Следующая цель»). Включите, чтобы также показывать их вверху экрана рядом с шахтами. По умолчанию выключено.",
        "Плавающая следующая цель",
        "Следующая цель всегда показана в окне Overlord. Включите, чтобы также показывать её в маленьком окне в центре экрана, когда вы не захватываете. По умолчанию выключено.",
        "«Авто» показывает нужные верхние панели рядом с шахтами, зонами захвата и крепостями гильдий, если включена плавающая панель монет. «Всегда» показывает их на подходящих картах; «Никогда» скрывает.",
        "Показывает значок книги обучения на верхнем HUD. Выключите, чтобы скрыть только этот значок.",
    },
    ptBR = {
        "Painel de moedas flutuante",
        "Suas moedas, Reforçar e Atacar estão sempre no painel do Overlord (cartão Próximo objetivo). Ative para mostrá-los também no topo da tela perto das minas. Desativado por padrão.",
        "Próximo objetivo flutuante",
        "O próximo objetivo é sempre mostrado no painel do Overlord. Ative para mostrá-lo também numa pequena janela no meio da tela quando você não estiver capturando. Desativado por padrão.",
        "Auto mostra os painéis superiores úteis perto das minas, das zonas de captura e das fortalezas quando o painel de moedas flutuante estiver ativo. Sempre os mostra nos mapas correspondentes; Nunca os oculta.",
        "Mostra o ícone do livro do tutorial no HUD superior. Desative para ocultar apenas esse ícone.",
    },
    zhCN = {
        "浮动硬币面板",
        "你的硬币、加固和进攻按钮始终在 Overlord 面板中（下一目标卡片）。开启后，在硬币矿区附近也会显示在屏幕顶部。默认关闭。",
        "浮动下一目标",
        "下一目标始终显示在 Overlord 面板中。开启后，在你未占领时也会在屏幕中央的小窗口中显示。默认关闭。",
        "自动：开启浮动硬币面板时，在硬币矿区、占领区和公会要塞附近显示相关顶部面板。始终：在相关地图上一直显示；从不：隐藏。",
        "在顶部 HUD 显示教程书图标。关闭后仅隐藏该图标。",
    },
}
settingsTexts.esMX = settingsTexts.esES
local st = settingsTexts[locale] or settingsTexts.enUS
L.COINS_HUD_LABEL, L.COINS_HUD_TOOLTIP = st[1], st[2]
L.FLOATING_OBJECTIVE_LABEL, L.FLOATING_OBJECTIVE_TOOLTIP = st[3], st[4]
L.SHOW_TOP_HUD_TOOLTIP, L.SHOW_TUTORIAL_BOOK_TOOLTIP = st[5], st[6]
local goldBonusReady = {
    enUS = "Ready", frFR = "Prêt", esES = "Listo", esMX = "Listo",
    deDE = "Bereit", ruRU = "Готово", ptBR = "Pronto", zhCN = "就绪",
}
L.GOLD_BONUS_READY = goldBonusReady[locale] or goldBonusReady.enUS
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
