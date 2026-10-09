-- GuildKillAlert.lua : alerte chat quand une guilde ennemie enchaine les kills.
--
-- Detection : chaque client compte les K authentifies qu'il voit (Sync:OnReceiveKill)
-- et ses propres kills (Sync:BroadcastKill), pour les guildes des DEUX factions.
-- Un K n'est ni relaye de proche en proche ni accepte via Battle.net : ce sont donc
-- surtout les joueurs de la meme faction que la guilde qui voient ses kills. Chaque K
-- porte le total absolu du tueur, sa guilde, le lieu et l'epoch de score ; la
-- difference entre deux K successifs donne le nombre de kills reels.
-- Seuil fixe pour tous : 20 kills par 5 membres distincts sur 5 min glissantes.
--
-- Diffusion : le client qui detecte le raid attend 0,5 a 6 s puis emet UN message
-- GW par le relais (groupe, canal, amis Battle.net qui font le pont vers l'autre
-- faction, relais de proche en proche), sauf si un GW pour cette guilde a deja
-- circule. L'alerte s'affiche chez la faction ENNEMIE de la guilde, avec exactement
-- le contenu recu (guilde, kills, membres, lieu, layer). Depuis la 1.7.1, la faction
-- de la guilde voit aussi son carnage, en vert (option separee, meme seuil, une fois
-- par guilde toutes les 10 min) : detection locale ou GW deja recu, aucun paquet en plus.
-- GW reste hors de la file prioritaire du relais : une capture passe toujours avant.
--
-- GW : 1:guilde:A|H:kills:membres:lieu:shard:epochServeur

Overlord = Overlord or {}
Overlord.GuildKillAlert = Overlord.GuildKillAlert or {}
local GKA = Overlord.GuildKillAlert
local L = Overlord.L

local WINDOW = 300            -- fenetre de comptage (s)
local ALERT_COOLDOWN = 600    -- une alerte par guilde toutes les 10 min au plus
-- Carnage allie (1.7.1) : simple ambiance, une fois par guilde toutes les 30 min ; l'alerte
-- ennemie, utile pour se preparer, garde ses 10 min.
local ALLY_ALERT_COOLDOWN = 1800
-- Une base plus vieille que la fenetre ne permet pas de dater le saut de total :
-- au-dela, le K repart d'une base neuve et ne compte qu'un kill.
local BASELINE_TTL = WINDOW
local MAX_DELTA = 30          -- saut de total suspect : compte comme un seul kill
local EPOCH_TOLERANCE = 3 * 86400
-- Launch scale (1.8.1): 1,000-2,000 killers send a total every 30 s. At 512 the
-- previous total of a killer was evicted before his next one (~15 s), so each K
-- counted one kill instead of its real delta: rampages under-counted and fired
-- late, fight sizes in the dock too small. Evicted in insertion order (O(1)).
local MAX_PLAYERS = 4096
local MAX_GUILDS = 512
-- A threshold (20 kills, 5 members) is reached long before; bounds memory.
local MAX_EVENTS_PER_GUILD = 128
local NETWORK_MAX_AGE = 300   -- un GW relaye plus vieux que 5 min n'est plus d'actualite
local NETWORK_MAX_SKEW = 300
local NETWORK_BURST_WINDOW = 60
local NETWORK_BURST_MAX = 4   -- plafond d'alertes reseau affichees par minute (anti-flood)
local NETWORK_SEEN_MAX = 64
local BROADCAST_JITTER_MIN, BROADCAST_JITTER_MAX = 0.5, 6
-- Chemins de diffusion reels d'un GW. Un simple chuchotement n'en fait pas partie :
-- un GW recu ainsi ne vient pas du relais et n'est pas pris en compte.
local GW_TRANSPORTS = { BETA = true, CHANNEL = true, PARTY = true, RAID = true, BNET = true }

-- Seuil commun a tous les clients : c'est lui qui declenche l'envoi reseau, donc
-- il ne doit pas etre personnalisable (sinon un seuil bas alerterait tout le monde).
GKA.KILL_THRESHOLD = 20
GKA.MEMBER_THRESHOLD = 5

local players, playerCount = {}, 0   -- [nom minuscule] = { total, at, epoch, guild, slot }
-- Insertion order of players (row.slot = its index): oldest evicted first, a row
-- still inside its window is moved to the back (a few at most per eviction).
local playerOrder, playerHead, playerTail = {}, 1, 0
local guilds, guildCount = {}, 0     -- ["A|H:guilde minuscule"] = voir GetGuild
local networkShownAt = {}            -- horodatages des alertes reseau affichees (anti-flood)

local function Now() return GetTime() end

local function ServerNow()
    local now = GetServerTime and tonumber(GetServerTime()) or nil
    if now and now > 0 then return math.floor(now) end
    return time()
end

local function Config()
    OverlordDB = OverlordDB or {}
    OverlordDB.config = OverlordDB.config or {}
    return OverlordDB.config
end

function GKA:IsEnabled()
    local cfg = OverlordDB and OverlordDB.config
    return not (cfg and cfg.guildKillAlertEnabled == false)
end

function GKA:SetEnabled(value)
    Config().guildKillAlertEnabled = value == true
end

-- Carnages des guildes de notre faction (1.7.1), actives par defaut.
function GKA:IsAllyEnabled()
    local cfg = OverlordDB and OverlordDB.config
    return not (cfg and cfg.guildKillAllyAlertEnabled == false)
end

function GKA:SetAllyEnabled(value)
    Config().guildKillAllyAlertEnabled = value == true
end

function GKA:ResetDefaults()
    Config().guildKillAlertEnabled = nil
    Config().guildKillAllyAlertEnabled = nil
end

local function FactionCode(faction)
    return faction == "Horde" and "H" or faction == "Alliance" and "A" or nil
end

local function EpochsMatch(a, b)
    a, b = tonumber(a), tonumber(b)
    if not a or not b or a <= 0 or b <= 0 then return a == b end
    return math.abs(a - b) <= EPOCH_TOLERANCE
end

-- Nombre de kills reellement nouveaux apportes par ce K. La base retient aussi la
-- guilde : un saut de total mesure pendant un changement de guilde n'est pas
-- attribuable a la nouvelle, seul un kill l'est.
local function TrackPlayer(key, row)
    if playerTail - playerHead + 1 > MAX_PLAYERS * 2 then
        -- Compact the order (stale entries of cleared or replaced rows).
        local order, n = {}, 0
        for i = playerHead, playerTail do
            local k = playerOrder[i]
            local r = k and players[k]
            if r and r.slot == i then n = n + 1; order[n] = k; r.slot = n end
        end
        playerOrder, playerHead, playerTail = order, 1, n
    end
    playerTail = playerTail + 1
    playerOrder[playerTail] = key
    row.slot = playerTail
end

local function EvictOldestPlayer(now)
    local rotated = 0
    while playerHead <= playerTail do
        local index, key = playerHead, playerOrder[playerHead]
        playerOrder[index] = nil
        playerHead = playerHead + 1
        local row = key and players[key]
        if row and row.slot == index then
            if now - row.at <= BASELINE_TTL and rotated < 8 then
                rotated = rotated + 1
                TrackPlayer(key, row)
            else
                players[key] = nil
                playerCount = playerCount - 1
                return
            end
        end
    end
end

local function ConsumeKillDelta(playerKey, total, epoch, guildKey, now)
    local row = players[playerKey]
    if row and now - row.at <= BASELINE_TTL and EpochsMatch(row.epoch, epoch)
        and row.guild == guildKey then
        local delta = total - row.total
        if delta <= 0 then return 0 end -- copie en double ou K plus ancien relaye en retard
        row.total, row.at = total, now
        if delta > MAX_DELTA then return 1 end
        return delta
    end
    if not row then
        if playerCount >= MAX_PLAYERS then EvictOldestPlayer(now) end
        playerCount = playerCount + 1
    end
    -- Base absente, perimee, d'une autre semaine de score ou d'une autre guilde :
    -- un K n'est emis qu'apres au moins un kill, et c'est tout ce qu'on peut dater.
    -- Une copie en retard (total inferieur) ne remplace pas une base plus haute.
    if row and total < row.total and EpochsMatch(row.epoch, epoch) and row.guild == guildKey then
        return 0
    end
    local fresh = { total = total, at = now, epoch = epoch, guild = guildKey }
    players[playerKey] = fresh
    if row and row.slot then fresh.slot = row.slot else TrackPlayer(playerKey, fresh) end
    return 1
end

local function ClearPlayerBaseline(playerKey)
    if players[playerKey] ~= nil then
        players[playerKey] = nil
        playerCount = math.max(0, playerCount - 1)
    end
end

local function PruneEvents(guild, now)
    local events = guild.events
    local keep = 1
    for i = 1, #events do
        local e = events[i]
        if now - e.at <= WINDOW then
            events[keep] = e
            keep = keep + 1
        end
    end
    for i = #events, keep, -1 do events[i] = nil end
end

local function Recent(at, now, cooldown) return at ~= nil and now - at < (cooldown or ALERT_COOLDOWN) end

-- Delai d'affichage d'une cle "A:guilde" : 30 min pour une guilde de notre faction.
local function CooldownForKey(key)
    local mine = FactionCode and Overlord.PlayerFaction and FactionCode(Overlord.PlayerFaction)
    return (mine and type(key) == "string" and key:sub(1, 2) == mine .. ":") and ALLY_ALERT_COOLDOWN
        or ALERT_COOLDOWN
end

-- Un vrai nom de guilde n'a ni espace en bord ni espaces doubles : " Foo", "Foo " ou
-- "Foo  Bar" contourneraient le delai par guilde (refuses a l'envoi comme a la reception).
local function IsCleanGuildName(name)
    return type(name) == "string" and name == name:match("^%s*(.-)%s*$") and not name:find("%s%s")
end

-- Priorite de conservation d'une guilde : une guilde en cooldown passe apres toutes
-- les autres (math.huge), sinon on garde la plus recemment active.
local function GuildActivityAt(guild, now)
    if Recent(guild.detectedAt, now) or Recent(guild.shownAt, now)
        or (guild.networkSeen and Recent(guild.networkSeen.at, now)) then
        return math.huge
    end
    return guild.events[#guild.events] and guild.events[#guild.events].at or 0
end

local function GetGuild(guildName, faction, now)
    local key = FactionCode(faction) .. ":" .. guildName:lower()
    local guild = guilds[key]
    if guild then
        guild.name = guildName
        return guild
    end
    if guildCount >= MAX_GUILDS then
        local oldestKey, oldestAt
        for otherKey, other in pairs(guilds) do
            -- Events are appended in time order: the last one tells whether any is
            -- still inside the window (no need to prune 128 guilds' events here).
            local lastAt = GuildActivityAt(other, now)
            if lastAt ~= math.huge and now - lastAt > WINDOW then lastAt = 0 end
            if lastAt == 0 then
                guilds[otherKey] = nil
                guildCount = guildCount - 1
            elseif not oldestAt or lastAt < oldestAt then
                oldestKey, oldestAt = otherKey, lastAt
            end
        end
        if guildCount >= MAX_GUILDS and oldestKey then
            guilds[oldestKey] = nil
            guildCount = guildCount - 1
        end
    end
    -- detectedAt : seuil franchi localement ; shownAt : alerte affichee ;
    -- networkSeen : dernier GW recu pour cette guilde { at, zone, kills }.
    guild = { name = guildName, faction = faction, events = {} }
    guilds[key] = guild
    guildCount = guildCount + 1
    return guild
end

-- Shard connu d'un joueur (meme source que les alertes de capture), en nombre.
local function KnownShardOf(playerName)
    local sync = Overlord.Sync
    local tag = sync and sync.GetShardAlertTagForPlayer and sync:GetShardAlertTagForPlayer(playerName)
    return tonumber(type(tag) == "string" and tag:match("(%d+)") or nil)
end

-- Totaux de la fenetre : kills, membres distincts, lieu le plus frequent (pondere
-- par les kills) et detail par joueur.
local function Summarize(guild)
    local byPlayer, memberCount, kills = {}, 0, 0
    local locWeight, bestLoc, bestLocWeight = {}, nil, 0
    for _, e in ipairs(guild.events) do
        kills = kills + e.kills
        if e.zref then
            locWeight[e.zref] = (locWeight[e.zref] or 0) + e.kills
            if locWeight[e.zref] > bestLocWeight then bestLoc, bestLocWeight = e.zref, locWeight[e.zref] end
        end
        local row = byPlayer[e.key]
        if not row then
            row = { name = e.name, kills = 0 }
            byPlayer[e.key] = row
            memberCount = memberCount + 1
        end
        row.kills = row.kills + e.kills
    end
    return kills, memberCount, bestLoc, byPlayer
end

-- Layer de la guilde : shard connu le plus represente parmi ses tueurs, pondere
-- par leurs kills. nil si aucun tueur n'a de shard connu.
local function GuildShard(byPlayer)
    local weight, best, bestWeight = {}, nil, 0
    for _, row in pairs(byPlayer) do
        local shard = KnownShardOf(row.name)
        if shard then
            weight[shard] = (weight[shard] or 0) + row.kills
            if weight[shard] > bestWeight or (weight[shard] == bestWeight and shard < best) then
                best, bestWeight = shard, weight[shard]
            end
        end
    end
    return best
end

local function GetMapInfo(mapID)
    if not (C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    return ok and type(info) == "table" and info or nil
end

-- Remonte une sous-carte (grotte, quartier) jusqu'a sa zone. Au-dela (continent,
-- monde), le lieu serait trop vague : nil.
local ZONE_MAP_TYPE = 3
local function ResolveZoneMap(mapID)
    local info = GetMapInfo(mapID)
    for _ = 1, 4 do
        if not info then return nil end
        local mapType = tonumber(info.mapType)
        if mapType == ZONE_MAP_TYPE then return mapID, info end
        if not mapType or mapType < ZONE_MAP_TYPE then return nil end
        mapID = tonumber(info.parentMapID)
        if not mapID or mapID <= 0 then return nil end
        info = GetMapInfo(mapID)
    end
    return nil
end

-- Marqueur emis dans le champ zone du K quand le kill a lieu hors front.
function GKA:GetLocalMapRef()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    mapID = ok and tonumber(mapID) or nil
    if not mapID then return nil end
    local zoneMapID = ResolveZoneMap(mapID)
    return zoneMapID and ("#" .. math.floor(zoneMapID)) or nil
end

local function IsValidZoneRef(zoneRef)
    return type(zoneRef) == "string" and zoneRef ~= "" and #zoneRef <= 40
        and zoneRef:match("^[#@]?[%w_%-]+$") ~= nil
end

-- Nom lisible d'un lieu, dans la langue du joueur : zone de capture, front, ou
-- carte "#uiMapID".
local function ResolveLocationLabel(zoneRef)
    if not IsValidZoneRef(zoneRef) then return nil end
    local mapID = zoneRef:match("^#(%d+)$")
    if mapID then
        local _, info = ResolveZoneMap(tonumber(mapID))
        return info and info.name ~= "" and info.name or nil
    end
    local zones = Overlord.Zones
    local zone = zones and zones.GetZone and zoneRef:sub(1, 1) ~= "@" and zones:GetZone(zoneRef)
    if zone and zone.name and zone.name ~= "" then return zone.name end
    local fa = Overlord.FrontActivity
    local frontId = fa and fa.GetFrontIdFromZoneRef and fa:GetFrontIdFromZoneRef(zoneRef)
    local fronts = Overlord.Fronts
    local front = frontId and fronts and fronts.GetFront and fronts:GetFront(frontId)
    return front and (front.dropdownLabel or front.mapName) or nil
end

-- "<Guild> crest" instead of "Guild (the Horde)" (player feedback, 2026-10-02).
local function GuildTag(guildName, faction)
    if Overlord.GuildChatTag then return Overlord:GuildChatTag(guildName, faction) end
    return "<" .. tostring(guildName) .. ">"
end

-- Texte identique pour le detecteur et pour chaque receveur du GW.
function GKA:BuildAlertText(guildName, faction, kills, members, zoneRef, shard, ally)
    local shardSuffix = ""
    if shard then
        local tag = string.format((L and L.SHARD_ALERT_TAG) or " #%s", tostring(shard))
        shardSuffix = " (" .. (tag:match("^%s*(.-)%s*$") or tag) .. ")"
    end
    local location = ResolveLocationLabel(zoneRef)
    if ally then
        if location then
            return string.format(L.GUILD_KILL_ALLY_ALERT_FRONT
                or "Allied guild %s on a rampage: %d+ HK by %d+ members in %s%s!",
                GuildTag(guildName, faction), kills, members, location, shardSuffix)
        end
        return string.format(L.GUILD_KILL_ALLY_ALERT
            or "Allied guild %s on a rampage: %d+ HK by %d+ members%s!",
            GuildTag(guildName, faction), kills, members, shardSuffix)
    end
    if location then
        return string.format(L.GUILD_KILL_ALERT_FRONT
            or "Guild %s: %d+ HK by %d+ members in %s%s!",
            GuildTag(guildName, faction), kills, members, location, shardSuffix)
    end
    return string.format(L.GUILD_KILL_ALERT
        or "Guild %s: %d+ HK by %d+ members%s!",
        GuildTag(guildName, faction), kills, members, shardSuffix)
end

-- Memoire persistante du dernier affichage par guilde (heure serveur) : apres un
-- /reload, les 10 min d'anti-doublon continuent, quel que soit le GW recu.
local function AlreadyShownPersisted(key, serverNow)
    local seen = OverlordDB and OverlordDB.guildKillAlertSeen
    if type(seen) ~= "table" then return false end
    local at = tonumber(seen[key])
    return at ~= nil and serverNow - at < CooldownForKey(key)
end

local function RememberShownPersisted(key, serverNow)
    OverlordDB = OverlordDB or {}
    local seen = type(OverlordDB.guildKillAlertSeen) == "table" and OverlordDB.guildKillAlertSeen or {}
    local count = 0
    for k, at in pairs(seen) do
        if serverNow - (tonumber(at) or 0) >= CooldownForKey(k) then seen[k] = nil else count = count + 1 end
    end
    if count < NETWORK_SEEN_MAX or seen[key] then seen[key] = serverNow end
    OverlordDB.guildKillAlertSeen = seen
end

local function Show(text, ally)
    Overlord:PrintNotification((ally and "|cFF33FF66[Overlord]|r " or "|cFFFF4444[Overlord]|r ") .. text)
end

-- Appele apres toutes les validations d'un K recu (Sync:OnReceiveKill) et pour nos
-- propres kills (Sync:BroadcastKill). guildName vide = guilde inconnue ou aucune :
-- jamais de reprise d'une guilde en cache, qui pourrait etre ancienne.
function GKA:OnLiveKill(playerName, faction, guildName, totalKills, zoneId, scoreEpoch)
    if type(playerName) ~= "string" or playerName == "" then return end
    if not FactionCode(faction) then return end
    local total = tonumber(totalKills)
    if not total or total <= 0 then return end
    local sync = Overlord.Sync
    local hasGuild = type(guildName) == "string" and guildName ~= ""
        and not (sync and sync.IsValidGuildSyncToken and not sync:IsValidGuildSyncToken(guildName))
    local guildKey = hasGuild and (FactionCode(faction) .. ":" .. guildName:lower()) or ""

    -- La base avance pour tout K authentifie, meme sans guilde, pour qu'un saut
    -- de total ne soit jamais credite plus tard a une autre guilde.
    local now = Now()
    local delta = ConsumeKillDelta(playerName:lower(), math.floor(total), tonumber(scoreEpoch), guildKey, now)
    -- Taille des combats du dock : les memes kills, avec ou sans guilde (aucun paquet).
    local fa = Overlord.FrontActivity
    if delta > 0 and not self._simulating and fa and fa.RecordKills and IsValidZoneRef(zoneId) then
        pcall(fa.RecordKills, fa, zoneId, delta)
    end
    if delta <= 0 or not hasGuild then return end

    local guild = GetGuild(guildName, faction, now)
    PruneEvents(guild, now)
    local events = guild.events
    events[#events + 1] = { at = now, key = playerName:lower(), name = playerName, kills = delta,
        zref = IsValidZoneRef(zoneId) and zoneId or nil }
    if #events > MAX_EVENTS_PER_GUILD then table.remove(events, 1) end

    self:Evaluate(guild, now)
end

function GKA:Evaluate(guild, now)
    if Overlord.InstanceSuspended then return false end
    local enemyOn, allyOn = self:IsEnabled(), self:IsAllyEnabled()
    if not enemyOn and not allyOn then return false end
    if Recent(guild.detectedAt, now) then return false end
    -- Cheap bound first (no allocation, on every kill): fewer events than members
    -- needed, or fewer kills than needed, cannot reach the threshold.
    local events = guild.events
    if #events < self.MEMBER_THRESHOLD then return false end
    local windowKills = 0
    for i = 1, #events do windowKills = windowKills + events[i].kills end
    if windowKills < self.KILL_THRESHOLD then return false end
    local kills, members, zoneRef, byPlayer = Summarize(guild)
    if kills < self.KILL_THRESHOLD or members < self.MEMBER_THRESHOLD then return false end
    local shard = GuildShard(byPlayer)
    guild.detectedAt = now
    -- Les kills suivants doivent reconstituer un nouveau seuil complet.
    guild.events = {}
    -- Detection locale corroboree : affichee meme si un GW (peut-etre forge) a deja
    -- ete montre pour cette guilde ; seul un affichage local recent la retient.
    local seenKey = FactionCode(guild.faction) .. ":" .. guild.name:lower()
    if guild.faction ~= Overlord.PlayerFaction then
        if enemyOn and not Recent(guild.localShownAt, now) then
            guild.localShownAt, guild.shownAt = now, now
            RememberShownPersisted(seenKey, ServerNow())
            Show(self:BuildAlertText(guild.name, guild.faction, kills, members, zoneRef, shard))
        end
    elseif allyOn and not Recent(guild.shownAt, now, ALLY_ALERT_COOLDOWN)
        and not AlreadyShownPersisted(seenKey, ServerNow()) then
        -- Notre faction : en vert, une fois par guilde toutes les 30 min (detection locale
        -- ou GW recu, le premier des deux).
        guild.localShownAt, guild.shownAt = now, now
        RememberShownPersisted(seenKey, ServerNow())
        Show(self:BuildAlertText(guild.name, guild.faction, kills, members, zoneRef, shard, true), true)
    end
    -- L'envoi pour l'autre faction reste lie a l'alerte ennemie (comme avant).
    if not self._simulating and enemyOn then
        self:ScheduleBroadcast(guild, kills, members, zoneRef, shard)
    end
    return true
end

function GKA:BuildNetworkPayload(guildName, faction, kills, members, zoneRef, shard, ts)
    local sync = Overlord.Sync
    if not (sync and sync.IsValidGuildSyncToken and sync:IsValidGuildSyncToken(guildName)) then return nil end
    if not IsCleanGuildName(guildName) then return nil end
    if not FactionCode(faction) then return nil end
    return table.concat({ "1", guildName, FactionCode(faction),
        tostring(math.floor(kills)), tostring(math.floor(members)),
        IsValidZoneRef(zoneRef) and zoneRef or "", shard and tostring(math.floor(shard)) or "",
        tostring(ts or ServerNow()) }, ":")
end

-- Un seul envoi : le relais copie deja le paquet au groupe, sur le canal et aux amis
-- Battle.net (pont vers l'autre faction), puis le fait suivre de proche en proche.
-- Sans relais, repli sur les copies directes groupe + canal.
function GKA:Broadcast(guildName, faction, kills, members, zoneRef, shard)
    local sync = Overlord.Sync
    if not sync or Overlord.InstanceSuspended or not self:IsEnabled() then return false end
    local payload = self:BuildNetworkPayload(guildName, faction, kills, members, zoneRef, shard)
    if not payload then return false end
    local net = Overlord.Relay
    if net and net.Broadcast and (net:Broadcast("GW", payload) or 0) > 0 then return true end
    local sent = false
    if sync.SendToGroup and sync:SendToGroup("GW", payload) then sent = true end
    if sync.SendToChannel and sync:SendToChannel("GW", payload, true) then sent = true end
    return sent
end

-- Un GW recu ne rend notre envoi inutile que s'il couvre notre observation : meme
-- lieu et au moins autant de kills. Un GW forge ailleurs ou plus faible ne peut
-- donc pas faire taire une vraie detection.
local function NetworkCovers(guild, zoneRef, kills, now)
    local seen = guild.networkSeen
    return seen ~= nil and Recent(seen.at, now) and seen.zone == (zoneRef or "")
        and seen.kills >= kills
end

-- Plusieurs joueurs franchissent souvent le seuil dans la meme seconde. Chacun
-- attend un delai aleatoire et renonce si un GW couvrant le meme raid a circule
-- entre-temps, ou si l'option a ete coupee : une alerte = en general un paquet.
function GKA:ScheduleBroadcast(guild, kills, members, zoneRef, shard)
    if NetworkCovers(guild, zoneRef, kills, Now()) then return end
    local delay = BROADCAST_JITTER_MIN + math.random() * (BROADCAST_JITTER_MAX - BROADCAST_JITTER_MIN)
    local after = self._After or (C_Timer and C_Timer.After)
    local function fire()
        if NetworkCovers(guild, zoneRef, kills, Now()) then return end
        if not self:IsEnabled() or Overlord.InstanceSuspended then return end
        self:Broadcast(guild.name, guild.faction, kills, members, zoneRef, shard)
    end
    if after then after(delay, fire) else fire() end
end

local function NetworkBurstAllows(now)
    local keep = {}
    for _, at in ipairs(networkShownAt) do
        if now - at < NETWORK_BURST_WINDOW then keep[#keep + 1] = at end
    end
    networkShownAt = keep
    return #keep < NETWORK_BURST_MAX
end


-- Reception d'un GW : afficher tel quel chez la faction ennemie de la guilde, une
-- fois par guilde et par 10 min. Chez la faction de la guilde, il annule nos propres
-- envois en attente et, depuis 1.7.1, s'affiche en vert si les carnages allies sont actifs.
function GKA:OnReceiveNetworkAlert(payload, sender, channel)
    if type(payload) ~= "string" or payload == "" or #payload > 200 then return false end
    if not GW_TRANSPORTS[channel or ""] then return false end
    if Overlord.InstanceSuspended then return false end
    local enemyOn, allyOn = self:IsEnabled(), self:IsAllyEnabled()
    if not enemyOn and not allyOn then return false end
    local version, guildName, facCode, killsStr, membersStr, zoneRef, shardStr, tsStr =
        strsplit(":", payload, 8)
    if version ~= "1" then return false end
    local faction = facCode == "H" and "Horde" or facCode == "A" and "Alliance" or nil
    local myFaction = Overlord.PlayerFaction
    if not faction or not myFaction then return false end
    local sync = Overlord.Sync
    if not (sync and sync.IsValidGuildSyncToken and sync:IsValidGuildSyncToken(guildName)) then return false end
    if not IsCleanGuildName(guildName) then return false end
    local kills, members = tonumber(killsStr), tonumber(membersStr)
    if not kills or not members or kills ~= math.floor(kills) or members ~= math.floor(members)
        or kills < self.KILL_THRESHOLD or kills > 9999
        or members < self.MEMBER_THRESHOLD or members > 999 then return false end
    zoneRef = zoneRef or ""
    if zoneRef ~= "" and not IsValidZoneRef(zoneRef) then return false end
    local shard = nil
    if shardStr and shardStr ~= "" then
        shard = tonumber(shardStr)
        if not shard or shard ~= math.floor(shard) or shard < 0 or shard > 99999999 then return false end
    end
    local ts = tonumber(tsStr)
    local serverNow = ServerNow()
    if not ts or ts ~= ts or ts > serverNow + NETWORK_MAX_SKEW or serverNow - ts > NETWORK_MAX_AGE then return false end

    local now = Now()
    local guild = GetGuild(guildName, faction, now)
    -- Memorise l'annonce pour eviter de renvoyer le meme raid, sans toucher a
    -- notre propre detection : seules nos observations la font avancer.
    guild.networkSeen = { at = now, zone = zoneRef, kills = kills }
    -- Notre faction : affichee en vert seulement si l'option alliee est active ; l'alerte
    -- rouge reste pour l'ennemi.
    local ally = faction == myFaction
    if (ally and not allyOn) or (not ally and not enemyOn) then return false end
    local seenKey = facCode .. ":" .. guildName:lower()
    if Recent(guild.shownAt, now, ally and ALLY_ALERT_COOLDOWN or nil)
        or AlreadyShownPersisted(seenKey, serverNow) then return false end
    if not NetworkBurstAllows(now) then return false end
    networkShownAt[#networkShownAt + 1] = now
    guild.shownAt = now
    RememberShownPersisted(seenKey, serverNow)
    Show(self:BuildAlertText(guildName, faction, kills, members, zoneRef ~= "" and zoneRef or nil, shard, ally), ally)
    return true
end

function GKA:PrintDiagnostics()
    local now = Now()
    local out = function(text) Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text) end
    out(string.format(L.GUILD_KILL_DIAG_HEADER
        or "Enemy guild raid alert: %s, threshold %d HK and %d members in 5 min.",
        self:IsEnabled() and (L.SETTINGS_TOGGLE_ON or "Enabled") or (L.SETTINGS_TOGGLE_OFF or "Disabled"),
        self.KILL_THRESHOLD, self.MEMBER_THRESHOLD))
    out(string.format(L.GUILD_KILL_DIAG_ALLY or "Allied guild rampages: %s.",
        self:IsAllyEnabled() and (L.SETTINGS_TOGGLE_ON or "Enabled") or (L.SETTINGS_TOGGLE_OFF or "Disabled")))
    local rows = {}
    for _, guild in pairs(guilds) do
        PruneEvents(guild, now)
        if #guild.events > 0 then
            local kills, members = Summarize(guild)
            rows[#rows + 1] = { guild = guild, kills = kills, members = members }
        end
    end
    table.sort(rows, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        return a.guild.name < b.guild.name
    end)
    if #rows == 0 then
        out(L.GUILD_KILL_DIAG_EMPTY or "No guild HK received in the last 5 minutes.")
        return
    end
    for i = 1, math.min(#rows, 10) do
        local r = rows[i]
        out(string.format(L.GUILD_KILL_DIAG_ROW or "%s (%s): %d HK, %d members",
            r.guild.name, r.guild.faction, r.kills, r.members))
    end
end

-- Simulation locale : rejoue un raid fictif dans le vrai circuit (OnLiveKill ->
-- Evaluate -> chat), sans rien envoyer et sans toucher au classement.
local SIM_GUILD = "Empire [TEST]"
local SIM_NAMES = { "Sima", "Simb", "Simc", "Simd", "Sime" }
-- Layer fictif de la guilde simulee (jamais celui du joueur) ; un membre isole
-- sur un autre layer montre que la majorite l'emporte.
local SIM_GUILD_SHARD, SIM_STRAY_SHARD = 143, 87
local SIM_ZONE_REF = "#1417"

local function ForgetGuild(guildName, faction)
    local key = FactionCode(faction) .. ":" .. guildName:lower()
    if guilds[key] then guilds[key] = nil; guildCount = guildCount - 1 end
end

function GKA:Simulate()
    local myFaction = Overlord.PlayerFaction or "Horde"
    local enemy = myFaction == "Horde" and "Alliance" or "Horde"
    local perMember = math.ceil(self.KILL_THRESHOLD / #SIM_NAMES)
    ForgetGuild(SIM_GUILD, enemy)
    local sync = Overlord.Sync
    local realTag = sync and sync.GetShardAlertTagForPlayer
    if sync then
        sync.GetShardAlertTagForPlayer = function(_, name)
            local simName = name:match("^(.-)%-Simulation$")
            if simName then
                local shard = simName == SIM_NAMES[1] and SIM_STRAY_SHARD or SIM_GUILD_SHARD
                return string.format((L and L.SHARD_ALERT_TAG) or " #%s", tostring(shard))
            end
            return realTag and realTag(sync, name) or ""
        end
    end
    -- Lieu d'exemple : Hautes-terres d'Arathi, sinon la carte courante du joueur.
    local simZone = SIM_ZONE_REF
    if not ResolveLocationLabel(simZone) then simZone = self:GetLocalMapRef() or "" end
    local cfg = Config()
    local savedEnabled = cfg.guildKillAlertEnabled
    self._simulating = true
    local ok, err = pcall(function()
        cfg.guildKillAlertEnabled = true
        for m = 1, #SIM_NAMES do
            local name = SIM_NAMES[m] .. "-Simulation"
            ClearPlayerBaseline(name:lower())
            -- Premier K : 1 kill ; second K : le reste, comme un envoi regroupe.
            self:OnLiveKill(name, enemy, SIM_GUILD, 1000, simZone)
            self:OnLiveKill(name, enemy, SIM_GUILD, 1000 + perMember - 1, simZone)
            ClearPlayerBaseline(name:lower())
        end
    end)
    self._simulating = nil
    if sync then sync.GetShardAlertTagForPlayer = realTag end
    cfg.guildKillAlertEnabled = savedEnabled
    ForgetGuild(SIM_GUILD, enemy)
    if not ok then error(err) end
end

-- /ov guildkills [on|off|allies on|allies off|test]
function GKA:HandleCommand(args)
    local action = args[2] and args[2]:lower() or nil
    local sub = args[3] and args[3]:lower() or nil
    if action == "test" then
        self:Simulate()
        return
    elseif action == "allies" and (sub == "on" or sub == "off") then
        self:SetAllyEnabled(sub == "on")
        if Overlord.SettingsPanel and Overlord.SettingsPanel.RefreshControls then
            Overlord.SettingsPanel:RefreshControls()
        end
    elseif action == "on" or action == "off" then
        self:SetEnabled(action == "on")
        if Overlord.SettingsPanel and Overlord.SettingsPanel.RefreshControls then
            Overlord.SettingsPanel:RefreshControls()
        end
    elseif action ~= nil then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r "
            .. (L.GUILD_KILL_HELP or "/ov guildkills on, off, allies on, allies off, test"))
        return
    end
    self:PrintDiagnostics()
end

-- Tests : nombre de joueurs suivis et taille de l'ordre d'eviction.
function GKA:_TrackedPlayers()
    local live = 0
    for _ in pairs(players) do live = live + 1 end
    return playerCount, live, playerTail - playerHead + 1
end

-- Tests : remet l'etat memoire a zero (keepPersisted simule un /reload).
function GKA:_ResetState(keepPersisted)
    players, playerCount = {}, 0
    playerOrder, playerHead, playerTail = {}, 1, 0
    guilds, guildCount = {}, 0
    networkShownAt = {}
    if OverlordDB and not keepPersisted then OverlordDB.guildKillAlertSeen = nil end
end
