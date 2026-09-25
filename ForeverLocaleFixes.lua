-- Preserve slash commands and Forever terminology after the general UI locale.
local L = Overlord.L
local locale = GetLocale() or "enUS"

if locale == "ptBR" then
    L.MINE_DARROW = "Colina de Darrow"
    L.GOLD_HEADER_TIP = "Ganhe coins nos círculos marcados. Contrafortes de Eira dos Montes: Mina Azurelode e Colina de Darrow. Floresta de Pinhaprata: Mina Elemgorge. Loch Modan: Mina Stonesplinter. Floresta de Elwynn: Mina Jasperlode."
    L.HELP_ZONES = "|cFFFFFF00/ov zones|r: Mostrar pontos disponíveis com coordenadas"
    L.HELP_WHERE = "|cFFFFFF00/ov where|r: Alternar indicador de zona"
    L.HELP_SYNC = "|cFFFFFF00/ov sync [Jogador]|r: Pedir sincronização a um jogador ou grupo alcançável"
    L.HELP_SCALE = "|cFFFFFF00/ov scale [0.8-1.2]|r: Ajustar a escala do painel"
    L.HELP_GUIDE = "|cFFFFFF00/ov guide|r: Abrir o guia Forever"
    L.USAGE_START = "Uso: /ov start <ponto>"
    L.UI_SCALE_TOOLTIP = "Tamanho do painel e da classificação. Também é possível usar |cffffffff/ov scale|r."
    L.GUILD_KEEP_SHARD_UNKNOWN = "Seu layer ainda não foi detectado. Mire em um PNJ próximo ou fique perto de um membro do grupo com o Overlord atualizado. Diagnóstico: /ov shard."
    L.SHARD_TOOLTIP_TITLE = "ID do layer"
    L.SHARD_TOOLTIP_CURRENT = "Layer atual: %s"
    L.SHARD_TOOLTIP_PLAYERS_HEADER = "Jogadores em outro layer:"
    L.SHARD_TOOLTIP_ALL_SAME = "Todos os jogadores sincronizados estão no mesmo layer."
elseif locale == "zhCN" then
    L.MINE_DARROW = "达罗山"
    L.GOLD_HEADER_TIP = "在标记的区域内获得 coins。希尔斯布莱德丘陵：碧玉矿洞与达罗山；银松森林：艾伦矿洞；洛克莫丹：碎石矿洞；艾尔文森林：玉石矿洞。"
    L.HELP_HEADER = "|cFF00FF00========== Overlord：命令 ==========|r"
    L.HELP_SHOW = "|cFFFFFF00/ov show|r：显示界面"
    L.HELP_TOGGLE = "|cFFFFFF00/ov toggle|r：切换界面"
    L.HELP_ZONES = "|cFFFFFF00/ov zones|r：显示可占领据点及坐标"
    L.HELP_WHERE = "|cFFFFFF00/ov where|r：切换区域指示器"
    L.HELP_SYNC = "|cFFFFFF00/ov sync [玩家]|r：向可联系的玩家或队伍请求同步"
    L.HELP_SCALE = "|cFFFFFF00/ov scale [0.8-1.2]|r：调整面板缩放"
    L.HELP_GUIDE = "|cFFFFFF00/ov guide|r：打开 Forever 指南"
    L.USAGE_START = "用法：/ov start <据点>"
    L.UI_SCALE_TOOLTIP = "调整主面板和排行榜的大小，也可以使用 |cffffffff/ov scale|r。"
    L.GUILD_KEEP_SHARD_UNKNOWN = "尚未检测到你的 layer。请选中附近的 NPC，或靠近使用最新版 Overlord 的队友。诊断命令：/ov shard。"
    L.SHARD_TOOLTIP_TITLE = "Layer ID"
    L.SHARD_TOOLTIP_CURRENT = "当前 layer：%s"
    L.SHARD_TOOLTIP_PLAYERS_HEADER = "其他 layer 上的玩家："
    L.SHARD_TOOLTIP_ALL_SAME = "所有已同步玩家都在同一 layer。"
end

-- Keep literal slash commands intact when translating help text.
if locale == "ptBR" or locale == "zhCN" then
    local commands = {
        HELP_SHOW = "/ov show", HELP_HIDE = "/ov hide", HELP_TOGGLE = "/ov toggle",
        HELP_HUD = "/ov hud [auto|on|off|toggle]", HELP_STATUS = "/ov status",
        HELP_ZONES = "/ov zones", HELP_WHERE = "/ov where",
        HELP_START = "/ov start <zone>", HELP_LB = "/ov lb",
        HELP_SYNC = "/ov sync [PlayerName]", HELP_EXPORT = "/ov export",
        HELP_DOM = "/ov dom", HELP_SCALE = "/ov scale [0.8-1.2]",
        HELP_GUIDE = "/ov guide",
    }
    for key, command in pairs(commands) do
        if type(L[key]) == "string" then
            L[key] = L[key]:gsub("|cFFFFFF00.-|r", "|cFFFFFF00" .. command .. "|r", 1)
        end
    end
end

local communityButtonUnavailable = {
    enUS = "Community button temporarily unavailable during the beta.",
    frFR = "Bouton Communauté temporairement indisponible pendant la bêta.",
    esES = "Botón Comunidad temporalmente no disponible durante la beta.",
    deDE = "Community-Schaltfläche während der Beta vorübergehend nicht verfügbar.",
    ruRU = "Кнопка сообщества временно недоступна во время бета-тестирования.",
    ptBR = "Botão Comunidade temporariamente indisponível durante o beta.",
    zhCN = "社区按钮在测试期间暂时不可用。",
}
L.COMMUNITY_BUTTON_UNAVAILABLE = communityButtonUnavailable[locale]
    or (locale == "esMX" and communityButtonUnavailable.esES) or communityButtonUnavailable.enUS

local networkNotice = {
    enUS = {
        "Please read this",
        "Communities and Battle.net are temporarily unavailable. Data transfer between the Horde and Alliance will be unreliable during this period.",
    },
    frFR = {
        "Lisez ça, s'il vous plaît",
        "Les communautés et Battle.net sont désactivés pour l'instant. Le transfert de données entre la Horde et l'Alliance sera peu fiable durant ce laps de temps.",
    },
    esES = {
        "Por favor, lee esto",
        "Las comunidades y Battle.net están desactivados por ahora. La transferencia de datos entre la Horda y la Alianza será poco fiable durante este periodo.",
    },
    deDE = {
        "Bitte lest dies",
        "Communitys und Battle.net sind vorübergehend deaktiviert. Die Datenübertragung zwischen Horde und Allianz kann in dieser Zeit unzuverlässig sein.",
    },
    ruRU = {
        "Пожалуйста, прочитайте это",
        "Сообщества и Battle.net временно отключены. Передача данных между Ордой и Альянсом в это время может работать ненадёжно.",
    },
    ptBR = {
        "Leia isto, por favor",
        "Comunidades e Battle.net estão desativados por enquanto. A transferência de dados entre a Horda e a Aliança pode ser instável nesse período.",
    },
    zhCN = {
        "请阅读此通知",
        "社区和战网目前暂不可用。在此期间，部落与联盟之间的数据传输可能不稳定。",
    },
}
local notice = networkNotice[locale]
    or (locale == "esMX" and networkNotice.esES) or networkNotice.enUS
L.FOREVER_NETWORK_NOTICE_TITLE = notice[1]
L.FOREVER_NETWORK_NOTICE_BODY = notice[2]

local replacements = {
    enUS = { { "Shard", "Layer" }, { "shard", "layer" } },
    enGB = { { "Shard", "Layer" }, { "shard", "layer" } },
    frFR = { { "Shards", "Layers" }, { "shards", "layers" }, { "shard", "layer" } },
    esES = { { "Shards", "Layers" }, { "shards", "layers" }, { "shard", "layer" } },
    esMX = { { "Shards", "Layers" }, { "shards", "layers" }, { "shard", "layer" } },
    deDE = { { "Shards", "Layer" }, { "Shard", "Layer" }, { "shard", "layer" } },
    ruRU = { { "шардах", "слоях" }, { "шарда", "слоя" }, { "шард", "слой" } },
    ptBR = { { "fragmentos", "layers" }, { "fragmento", "layer" }, { "Shard", "Layer" }, { "shard", "layer" } },
    zhCN = { { "分片", "layer" }, { "碎片", "layer" }, { "Shard", "Layer" }, { "shard", "layer" } },
}
for key, value in pairs(L) do
    if type(key) == "string" and key:find("SHARD", 1, true) and type(value) == "string" then
        for _, pair in ipairs(replacements[locale] or replacements.enUS) do
            value = value:gsub(pair[1], pair[2])
        end
        value = value:gsub("/ov layer", "/ov shard")
        L[key] = value
    end
end
