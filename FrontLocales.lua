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
        "Долина Рендера", "Лагерь Renosh" },
    ptBR = { "Montanhas Cristarrubra", "Vila do Lago", "Vila do Lago", "Moinho de Alther",
        "Torre de Ilgalar", "Três Esquinas", "Estrada do Lago", "Cataratas da Vigília de Pedra",
        "Vale de Render", "Acampamento de Renosh" },
    zhCN = { "赤脊山", "湖畔镇", "湖畔镇", "阿尔瑟尔磨坊",
        "伊尔加拉之塔", "三岔路口", "湖边大道", "石堡瀑布",
        "伦德山谷", "Renosh 营地" },
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
    ruRU = { "Часовня Savix", "Охотничий домик Aeythyr", "Медвежья пещера Lesi" },
    ptBR = { "Capela Savix", "Pavilhão de Aeythyr", "Caverna do Urso de Lesi" },
    zhCN = { "Savix 教堂", "Aeythyr 小屋", "Lesi 的熊洞" },
}
standaloneOutpostNames.esMX = standaloneOutpostNames.esES
local outpostNames = standaloneOutpostNames[locale] or standaloneOutpostNames.enUS
L.OUTPOST_SILVERPINE_NAME = outpostNames[1]
L.OUTPOST_AEYTHYR_LODGE_NAME = outpostNames[2]
L.OUTPOST_LESI_BEAR_CAVE_NAME = outpostNames[3]
-- World map display modes: map corner button, Blizzard "Map Filters" and minimap
-- tracking menus, options dropdown and /ov map.
-- { filters title, full, compact, hidden, options tooltip, button click hint, chat/status line }
local mapModeTexts = {
    enUS = { "Overlord zones", "Full", "Compact (names on hover)", "Hidden",
        "Full: a name banner on every point. Compact: circles and icons only; a point's name shows under the mouse and while it is being taken. Hidden: nothing from Overlord on the world map.\nAlso from the Overlord button in the corner of the world map, the map's Filters menu, the minimap tracking menu and /ov map.",
        "Click: %s", "World map display: %s" },
    frFR = { "Zones Overlord", "Complet", "Compact (noms au survol)", "Masqué",
        "Complet : un bandeau avec le nom sur chaque point. Compact : cercles et icônes seulement ; le nom d'un point apparaît sous la souris et pendant sa prise. Masqué : rien d'Overlord sur la carte du monde.\nAussi avec le bouton Overlord dans le coin de la carte du monde, le menu Filtres de la carte, le menu de suivi de la minicarte et /ov map.",
        "Clic : %s", "Carte du monde : %s" },
    esES = { "Zonas de Overlord", "Completo", "Compacto (nombres al pasar el ratón)", "Oculto",
        "Completo: un cartel con el nombre en cada punto. Compacto: solo círculos e iconos; el nombre de un punto aparece bajo el ratón y mientras se está tomando. Oculto: nada de Overlord en el mapa del mundo.\nTambién con el botón de Overlord en la esquina del mapa del mundo, el menú Filtros del mapa, el menú de seguimiento del minimapa y /ov map.",
        "Clic: %s", "Mapa del mundo: %s" },
    deDE = { "Overlord-Zonen", "Vollständig", "Kompakt (Namen bei Mouseover)", "Ausgeblendet",
        "Vollständig: ein Namensbanner auf jedem Punkt. Kompakt: nur Kreise und Symbole; der Name eines Punktes erscheint unter der Maus und während er erobert wird. Ausgeblendet: nichts von Overlord auf der Weltkarte.\nAuch über den Overlord-Knopf in der Ecke der Weltkarte, das Filtermenü der Karte, das Verfolgungsmenü der Minimap und /ov map.",
        "Klick: %s", "Weltkarte: %s" },
    ruRU = { "Зоны Overlord", "Полный", "Компактный (названия при наведении)", "Скрыт",
        "Полный: лента с названием на каждой точке. Компактный: только круги и значки; название точки видно под курсором и во время захвата. Скрыт: ничего от Overlord на карте мира.\nТакже кнопкой Overlord в углу карты мира, в меню фильтров карты, в меню отслеживания мини-карты и командой /ov map.",
        "Щелчок: %s", "Карта мира: %s" },
    ptBR = { "Zonas do Overlord", "Completo", "Compacto (nomes ao passar o mouse)", "Oculto",
        "Completo: um banner com o nome em cada ponto. Compacto: só círculos e ícones; o nome de um ponto aparece sob o mouse e enquanto ele é tomado. Oculto: nada do Overlord no mapa-múndi.\nTambém pelo botão do Overlord no canto do mapa-múndi, no menu Filtros do mapa, no menu de rastreamento do minimapa e com /ov map.",
        "Clique: %s", "Mapa-múndi: %s" },
    zhCN = { "Overlord 区域", "完整", "紧凑（悬停显示名称）", "隐藏",
        "完整：每个据点都显示名称横幅。紧凑：只显示圆圈和图标；鼠标悬停或据点正在被占领时显示名称。隐藏：世界地图上不显示任何 Overlord 内容。\n也可通过世界地图角落的 Overlord 按钮、地图的过滤菜单、小地图追踪菜单和 /ov map 切换。",
        "点击：%s", "世界地图：%s" },
}
mapModeTexts.esMX = mapModeTexts.esES
local mapMode = mapModeTexts[locale] or mapModeTexts.enUS
L.MAP_FILTER_OVERLORD, L.MAP_MODE_FULL, L.MAP_MODE_COMPACT, L.MAP_MODE_HIDDEN = mapMode[1], mapMode[2], mapMode[3], mapMode[4]
L.MAP_MODE_TOOLTIP, L.MAP_MODE_BUTTON_NEXT, L.MAP_MODE_STATUS = mapMode[5], mapMode[6], mapMode[7]
-- Settings texts that describe where things now live (coins and next objective
-- are always in the Overlord panel; floating versions are opt-in).
-- { coins label, coins tooltip, floating objective label, floating objective tooltip }
local settingsTexts = {
    enUS = {
        "Floating coins panel",
        "Your coins, Reinforce and Attack are always in the Overlord panel (Next Objective card). Turn on to also show them at the top of the screen near coin mines. Off by default.",
        "Floating next objective",
        "The next objective is always shown in the Overlord panel. Turn on to also show it in a small window in the middle of the screen when you are not capturing. Off by default.",
    },
    frFR = {
        "Panneau des coins flottant",
        "Vos coins, Renforcer et Attaquer sont toujours dans le panneau Overlord (carte Prochain objectif). Activez pour les afficher aussi en haut de l'écran près des mines de coins. Désactivé par défaut.",
        "Prochain objectif flottant",
        "Le prochain objectif est toujours affiché dans le panneau Overlord. Activez pour l'afficher aussi dans une petite fenêtre au milieu de l'écran quand vous ne capturez pas. Désactivé par défaut.",
    },
    esES = {
        "Panel de monedas flotante",
        "Tus monedas, Reforzar y Atacar están siempre en el panel de Overlord (tarjeta Próximo objetivo). Actívalo para mostrarlos también arriba de la pantalla cerca de las minas. Desactivado por defecto.",
        "Próximo objetivo flotante",
        "El próximo objetivo se muestra siempre en el panel de Overlord. Actívalo para mostrarlo también en una pequeña ventana en el centro de la pantalla cuando no estés capturando. Desactivado por defecto.",
    },
    deDE = {
        "Schwebende Münzleiste",
        "Deine Münzen, Verstärken und Angreifen sind immer im Overlord-Fenster (Karte Nächstes Ziel). Aktivieren, um sie zusätzlich oben am Bildschirm in der Nähe von Minen zu zeigen. Standardmäßig aus.",
        "Schwebendes nächstes Ziel",
        "Das nächste Ziel steht immer im Overlord-Fenster. Aktivieren, um es zusätzlich in einem kleinen Fenster in der Bildschirmmitte zu zeigen, wenn du nicht eroberst. Standardmäßig aus.",
    },
    ruRU = {
        "Плавающая панель монет",
        "Монеты, «Укрепить» и «Атаковать» всегда есть в окне Overlord (карточка «Следующая цель»). Включите, чтобы также показывать их вверху экрана рядом с шахтами. По умолчанию выключено.",
        "Плавающая следующая цель",
        "Следующая цель всегда показана в окне Overlord. Включите, чтобы также показывать её в маленьком окне в центре экрана, когда вы не захватываете. По умолчанию выключено.",
    },
    ptBR = {
        "Painel de moedas flutuante",
        "Suas moedas, Reforçar e Atacar estão sempre no painel do Overlord (cartão Próximo objetivo). Ative para mostrá-los também no topo da tela perto das minas. Desativado por padrão.",
        "Próximo objetivo flutuante",
        "O próximo objetivo é sempre mostrado no painel do Overlord. Ative para mostrá-lo também numa pequena janela no meio da tela quando você não estiver capturando. Desativado por padrão.",
    },
    zhCN = {
        "浮动硬币面板",
        "你的硬币、加固和进攻按钮始终在 Overlord 面板中（下一目标卡片）。开启后，在硬币矿区附近也会显示在屏幕顶部。默认关闭。",
        "浮动下一目标",
        "下一目标始终显示在 Overlord 面板中。开启后，在你未占领时也会在屏幕中央的小窗口中显示。默认关闭。",
    },
}
settingsTexts.esMX = settingsTexts.esES
local st = settingsTexts[locale] or settingsTexts.enUS
L.COINS_HUD_LABEL, L.COINS_HUD_TOOLTIP = st[1], st[2]
L.FLOATING_OBJECTIVE_LABEL, L.FLOATING_OBJECTIVE_TOOLTIP = st[3], st[4]
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
        highperch = "Ponte Thandol", newstead = "Muralha de Thoradin",
        hammerfell = "Martelo da Ruína", argorok = "Círculo de União Ocidental",
        loch_alliance_capital = "Thelsamar", loch_horde_capital = "Fortaleza Mo'grosh",
        loch_valley_of_kings = "Vale dos Reis", loch_south_gate_pass = "Passagem do Portão Sul",
        loch_silver_stream_mine = "Mina do Riacho Prateado", loch_algaz_post = "Posto Algaz",
        loch_farstrider_lodge = "Refúgio dos Andarilhos", loch_ironband = "Escavação de Ferronato",
        loch_the_loch = "O Lago", loch_stonewrought_dam = "Represa de Pedraforja",
        durotar_tiragarde_keep = "Forte Tiragarde", durotar_alliance_fleet = "Penhasco Kolkar",
        durotar_senjin_village = "Vila Sen'jin", durotar_razor_hill = "Monte Navalha",
        durotar_deadeye_shore = "Praia do Olho Morto", durotar_southfury = "Rio Fúria do Sul",
        durotar_spirit_rock = "Vale das Provações", durotar_thunder_ridge = "Serra do Trovão",
        durotar_drygulch_ravine = "Ravina Seca", durotar_dranosh_blockade = "Acesso a Orgrimmar",
        ash_astranaar = "Astranaar", ash_iris_lake = "Lago Íris",
        ash_raynewood = "Retiro de Raynewood", ash_night_run = "Trilha Noturna",
        ash_bloodtooth_camp = "Acampamento Dentessangue", ash_silverwind = "Refúgio Ventoprata",
        ash_mystral_lake = "Lago Mystral", ash_fallen_sky_lake = "Lago Céu Caído",
        ash_dor_danil = "Covil de Dor'Danil", ash_splintertree = "Posto Lenhatriz",
        ash_maestra = "Posto de Maestra", ash_zoram_strand = "Praia de Zoram",
        ash_darkshore_road = "Estrada da Costa Negra", ash_aessina = "Santuário de Aessina",
        ash_stardust = "Ruínas de Poeira Estelar",
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
        highperch = "萨多尔大桥", newstead = "索拉丁之墙", hammerfell = "落锤镇",
        argorok = "西部禁锢法阵", loch_alliance_capital = "塞尔萨玛",
        loch_horde_capital = "莫格罗什要塞", loch_valley_of_kings = "国王谷",
        loch_south_gate_pass = "南门小径", loch_silver_stream_mine = "银泉矿洞",
        loch_algaz_post = "奥加兹岗哨", loch_farstrider_lodge = "远行者小屋",
        loch_ironband = "铁环挖掘场", loch_the_loch = "洛克湖",
        loch_stonewrought_dam = "巨石水坝", durotar_tiragarde_keep = "提拉加德城堡",
        durotar_alliance_fleet = "科尔卡峭壁", durotar_senjin_village = "森金村",
        durotar_razor_hill = "剃刀岭", durotar_deadeye_shore = "死眼海岸",
        durotar_southfury = "怒水河", durotar_spirit_rock = "试炼谷",
        durotar_thunder_ridge = "雷霆山脊", durotar_drygulch_ravine = "枯水谷",
        durotar_dranosh_blockade = "奥格瑞玛入口", ash_astranaar = "阿斯特兰纳",
        ash_iris_lake = "伊瑞斯湖", ash_raynewood = "林中树居",
        ash_night_run = "夜道谷", ash_bloodtooth_camp = "血牙营地",
        ash_silverwind = "银风避难所", ash_mystral_lake = "密斯特拉湖",
        ash_fallen_sky_lake = "坠星湖", ash_dor_danil = "朵丹尼尔兽穴",
        ash_splintertree = "碎木岗哨", ash_maestra = "迈斯特拉哨站",
        ash_zoram_strand = "佐拉姆海岸", ash_darkshore_road = "黑海岸之路",
        ash_aessina = "艾森娜神殿", ash_stardust = "星尘废墟",
    }
    for id, name in pairs(zones) do L.ZONE_NAMES[id] = name end
    local elwynn = { "西泉要塞", "闪金镇", "阿祖拉之塔", "山脊塔楼", "水晶湖",
        "法戈第矿洞", "杰罗德码头", "石碑湖", "东谷伐木场", "黑石前哨" }
    for index, id in ipairs({ "elwynn_westbrook", "elwynn_goldshire", "elwynn_tower_of_azora",
        "elwynn_ridgepoint", "elwynn_mirror_lake", "elwynn_fargodeep",
        "elwynn_jerods_landing", "elwynn_stone_cairn", "elwynn_eastvale",
        "elwynn_invasion_camp" }) do L.ZONE_NAMES[id] = elwynn[index] end
end

-- Help lines, floating coins panel messages and the domination bar tooltip.
-- { /ov map, /ov network, /ov hud, coins panel on, coins panel off,
--   domination rule, victories header, no victory, "%s ago", reset line }
local uiTexts = {
    enUS = { "|cFFFFFF00/ov map [full|compact|off]|r: World map display (also the Overlord button in the map's corner)",
        "|cFFFFFF00/ov network|r: Network report",
        "|cFFFFFF00/ov hud [on|off|toggle]|r: Floating coins panel",
        "|cFF00FF00[Overlord]|r Floating coins panel on.", "|cFF00FF00[Overlord]|r Floating coins panel off.",
        "Taking the enemy capital wins a front: +1% for the winning faction.",
        "Front victories this week", "No front victory yet this week.", "%s ago",
        "Resets in %s (every Tuesday, 08:00 UTC)." },
    frFR = { "|cFFFFFF00/ov map [full|compact|off]|r : affichage de la carte du monde (aussi le bouton Overlord dans le coin de la carte)",
        "|cFFFFFF00/ov network|r : rapport réseau",
        "|cFFFFFF00/ov hud [on|off|toggle]|r : panneau des coins flottant",
        "|cFF00FF00[Overlord]|r Panneau des coins flottant activé.", "|cFF00FF00[Overlord]|r Panneau des coins flottant désactivé.",
        "Prendre la capitale ennemie remporte un front : +1 % pour la faction gagnante.",
        "Victoires de front cette semaine", "Aucune victoire de front cette semaine pour l'instant.", "il y a %s",
        "Remise à zéro dans %s (chaque mardi, 08:00 UTC)." },
    esES = { "|cFFFFFF00/ov map [full|compact|off]|r: visualización del mapa del mundo (también el botón de Overlord en la esquina del mapa)",
        "|cFFFFFF00/ov network|r: informe de red",
        "|cFFFFFF00/ov hud [on|off|toggle]|r: panel de monedas flotante",
        "|cFF00FF00[Overlord]|r Panel de monedas flotante activado.", "|cFF00FF00[Overlord]|r Panel de monedas flotante desactivado.",
        "Tomar la capital enemiga gana un frente: +1 % para la facción ganadora.",
        "Victorias de frente esta semana", "Aún no hay victorias de frente esta semana.", "hace %s",
        "Se reinicia en %s (cada martes, 08:00 UTC)." },
    deDE = { "|cFFFFFF00/ov map [full|compact|off]|r: Weltkartenanzeige (auch der Overlord-Knopf in der Kartenecke)",
        "|cFFFFFF00/ov network|r: Netzwerkbericht",
        "|cFFFFFF00/ov hud [on|off|toggle]|r: Schwebende Münzleiste",
        "|cFF00FF00[Overlord]|r Schwebende Münzleiste an.", "|cFF00FF00[Overlord]|r Schwebende Münzleiste aus.",
        "Die Einnahme der feindlichen Hauptstadt gewinnt eine Front: +1 % für die siegreiche Fraktion.",
        "Frontsiege diese Woche", "Diese Woche noch kein Frontsieg.", "vor %s",
        "Zurückgesetzt in %s (jeden Dienstag, 08:00 UTC)." },
    ruRU = { "|cFFFFFF00/ov map [full|compact|off]|r: отображение карты мира (также кнопка Overlord в углу карты)",
        "|cFFFFFF00/ov network|r: отчёт о сети",
        "|cFFFFFF00/ov hud [on|off|toggle]|r: плавающая панель монет",
        "|cFF00FF00[Overlord]|r Плавающая панель монет включена.", "|cFF00FF00[Overlord]|r Плавающая панель монет выключена.",
        "Взятие вражеской столицы приносит победу на фронте: +1 % победившей фракции.",
        "Победы на фронтах на этой неделе", "На этой неделе побед на фронтах пока нет.", "%s назад",
        "Сброс через %s (каждый вторник, 08:00 UTC)." },
    ptBR = { "|cFFFFFF00/ov map [full|compact|off]|r: exibição do mapa-múndi (também o botão do Overlord no canto do mapa)",
        "|cFFFFFF00/ov network|r: relatório de rede",
        "|cFFFFFF00/ov hud [on|off|toggle]|r: painel de moedas flutuante",
        "|cFF00FF00[Overlord]|r Painel de moedas flutuante ativado.", "|cFF00FF00[Overlord]|r Painel de moedas flutuante desativado.",
        "Tomar a capital inimiga vence uma frente: +1 % para a facção vencedora.",
        "Vitórias de frente nesta semana", "Nenhuma vitória de frente nesta semana ainda.", "há %s",
        "Reinicia em %s (toda terça-feira, 08:00 UTC)." },
    zhCN = { "|cFFFFFF00/ov map [full|compact|off]|r：世界地图显示（也可用地图角落的 Overlord 按钮）",
        "|cFFFFFF00/ov network|r：网络报告",
        "|cFFFFFF00/ov hud [on|off|toggle]|r：浮动硬币面板",
        "|cFF00FF00[Overlord]|r 浮动硬币面板已开启。", "|cFF00FF00[Overlord]|r 浮动硬币面板已关闭。",
        "攻下敌方主城即赢得该战线：获胜阵营 +1%。",
        "本周战线胜利", "本周尚无战线胜利。", "%s前",
        "%s后重置（每周二 08:00 UTC）。" },
}
uiTexts.esMX = uiTexts.esES
local ut = uiTexts[locale] or uiTexts.enUS
L.HELP_MAP, L.HELP_NETWORK, L.HELP_HUD, L.HUD_SHOWN, L.HUD_HIDDEN = ut[1], ut[2], ut[3], ut[4], ut[5]
L.DOM_TIP_RULE, L.DOM_TIP_VICTORIES, L.DOM_TIP_NONE, L.DOM_TIP_AGO, L.DOM_TIP_RESET =
    ut[6], ut[7], ut[8], ut[9], ut[10]

-- Leaderboard: weekly capturers and rivalries view (keeps and outposts).
-- { button title, button text, back, capturers column, rivalries column,
--   no capturer, no rivalry }
local sitesWeekTexts = {
    enUS = { "Capturers and rivalries",
        "This week's keep and outpost captures: who took the most, and which guild took sites from which.",
        "Back to keeps and outposts", "Capturers this week", "Rivalries this week",
        "No keep or outpost taken this week yet.", "No site has changed faction this week yet." },
    frFR = { "Preneurs et rivalités",
        "Les prises de forts et d'avant-postes de la semaine : qui en a pris le plus, et quelle guilde a pris des sites à quelle autre.",
        "Retour aux forts et avant-postes", "Preneurs de la semaine", "Rivalités de la semaine",
        "Aucun fort ni avant-poste pris cette semaine pour l'instant.", "Aucun site n'a encore changé de faction cette semaine." },
    esES = { "Conquistadores y rivalidades",
        "Las tomas de fortalezas y avanzadas de la semana: quién tomó más y qué hermandad arrebató sitios a cuál.",
        "Volver a fortalezas y avanzadas", "Conquistadores de la semana", "Rivalidades de la semana",
        "Aún no se ha tomado ninguna fortaleza ni avanzada esta semana.", "Ningún sitio ha cambiado de facción esta semana." },
    deDE = { "Eroberer und Rivalitäten",
        "Die Festungs- und Außenposteneroberungen der Woche: wer am meisten erobert hat und welche Gilde wem Orte abgenommen hat.",
        "Zurück zu Festungen und Außenposten", "Eroberer der Woche", "Rivalitäten der Woche",
        "Diese Woche wurde noch keine Festung und kein Außenposten erobert.", "Diese Woche hat noch kein Ort die Fraktion gewechselt." },
    ruRU = { "Захватчики и соперничество",
        "Захваты крепостей и аванпостов за неделю: кто захватил больше всех и какая гильдия отбирала точки у какой.",
        "Назад к крепостям и аванпостам", "Захватчики недели", "Соперничество недели",
        "На этой неделе ещё не захвачено ни одной крепости или аванпоста.", "На этой неделе ни одна точка ещё не сменила фракцию." },
    ptBR = { "Conquistadores e rivalidades",
        "As tomadas de fortalezas e postos avançados da semana: quem tomou mais e qual guilda tomou locais de qual.",
        "Voltar a fortalezas e postos avançados", "Conquistadores da semana", "Rivalidades da semana",
        "Nenhuma fortaleza ou posto avançado tomado nesta semana ainda.", "Nenhum local mudou de facção nesta semana ainda." },
    zhCN = { "占领者与宿敌",
        "本周要塞和前哨的占领情况：谁占领得最多，以及哪个公会从哪个公会手中夺走了据点。",
        "返回要塞和前哨", "本周占领者", "本周宿敌",
        "本周尚无要塞或前哨被占领。", "本周尚无据点易主。" },
}
sitesWeekTexts.esMX = sitesWeekTexts.esES
local sw = sitesWeekTexts[locale] or sitesWeekTexts.enUS
L.SITES_WEEK_TIP_TITLE, L.SITES_WEEK_TIP_BODY, L.SITES_WEEK_BACK = sw[1], sw[2], sw[3]
L.SITES_WEEK_COL_CAPTURERS, L.SITES_WEEK_COL_RIVALRIES = sw[4], sw[5]
L.SITES_WEEK_EMPTY_CAPTURERS, L.SITES_WEEK_EMPTY_RIVALRIES = sw[6], sw[7]
