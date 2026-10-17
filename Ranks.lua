-- Ranks.lua : les rangs d'Overlord (Overlord Forever).
-- Quinze rangs acquis a vie par personnage. Les dix premiers se paient en Gloire :
-- chaque victoire honorable et chaque capture comptees par CE client. Les cinq
-- derniers se gagnent en finissant des semaines dans le haut du classement de sa
-- faction : a la cloture, les victoires de la semaine comptees par ce client sont
-- comparees aux lignes du classement qu'il detient deja. Le quinzieme, Overlord,
-- demande plus de Gloire et des semaines finies premier de sa faction.
-- Rien ne part sur le reseau et aucun paquet n'est lu pour cela. Rien n'est lu non
-- plus sur notre propre ligne du classement, qu'un autre client peut gonfler : ni la
-- Gloire, ni le score de la semaine, ni la faction.
-- Chaque fiche porte un sceau, relu une fois par session : une fiche dont le sceau ne
-- correspond plus a son contenu est mise de cote, jamais effacee, et le personnage
-- repart d'une fiche vide.
-- La fiche du personnage connecte est aussi gardee dans la sauvegarde du personnage
-- (OverlordCharDB.rank) : si celle du compte manque ou a recule, elle est reprise de la.
Overlord = Overlord or {}
local R = Overlord.Ranks or {}
Overlord.Ranks = R

R.GLORY_PER_KILL = 1
-- Une capture vaut deux victoires. Cette valeur peut etre relevee plus tard (des joueurs
-- montent), jamais baissee (des joueurs redescendraient) : dans le doute, bas.
R.GLORY_PER_CAPTURE = 2
R.MAX_RANK = 15
R.ICON_DIR = "Interface\\PvPFrame\\Icons\\"

-- Paliers de place hebdomadaire, du plus large au plus etroit. Une semaine finie
-- premier compte pour les cinq.
R.PLACE_TIERS = { 100, 25, 10, 3, 1 }
-- Les dernieres 24 heures de la semaine decident si elle compte. Pour une semaine dans
-- le top 3 ou finie premier (WEEK_STRICT_TOP), le classement local doit y avoir ete
-- compare en entier avec un voisin : une place lue sur une vue plus vieille serait
-- flatteuse (deux jours suffisent a se faire depasser). Pour les tops plus larges
-- (100, 25, 10) il suffit que ce client y ait ete en jeu, hors instance : il recoit
-- alors en direct le total de quiconque fait une victoire, et une comparaison entiere
-- aboutit trop rarement sur le reseau reel pour etre exigee de tous (2.0, mesure du
-- 12 octobre 2026 : une seule en quatre heures de jeu). Pas moins de 24 heures : le
-- reset tombe le mardi a 8 h UTC, soit en plein apres-midi en Asie, et la derniere
-- soiree de jeu doit rester dans la fenetre dans les trois regions.
R.WEEK_FRESH_SEC = 24 * 3600
R.WEEK_STRICT_TOP = 3
-- Ecart entre deux releves de presence en jeu (un nombre ecrit, rien d'autre).
R.ONLINE_STAMP_SEC = 300
R.WEEK_SEC = 7 * 86400
-- Marge apres le reset pour un joueur en ligne a ce moment-la. Plus courte que les
-- 30 minutes pendant lesquelles une nouvelle semaine ne lance aucun echange : un
-- constat de la semaine suivante ne peut pas passer pour un constat de celle-ci.
R.WEEK_CLOSE_GRACE_SEC = 900
-- Ecart minimal entre deux semaines comptees, et duree minimale d'une semaine close.
R.WEEK_MIN_SEC = 6 * 86400
-- Ecart tolere entre deux ancrages du meme reset (debut de semaine note au credit,
-- debut de l'archive) : celui du classement, 36 heures.
R.WEEK_EPOCH_SLACK_SEC = 36 * 3600
-- Personnages du compte suivis a une cloture.
R.WEEK_MAX_PROBES = 16
-- Fiches mises de cote gardees dans la sauvegarde (les plus recentes).
R.SET_ASIDE_MAX = 8
-- Victoires comptees ici dans la semaine pour qu'elle puisse donner une place : sur une
-- faction peu peuplee, une poignee de victoires vaudrait sinon un top 100.
R.WEEK_MIN_KILLS = 100
-- Victoires comptees ici dans la semaine pour qu'une premiere place vaille une semaine
-- finie premier : etre seul sur un classement presque vide ne suffit pas. (Sur les
-- archives de la beta, le centieme de la semaine en fait de 600 a 1 000, le premier
-- plus de 5 000.)
R.WEEK_FIRST_MIN_KILLS = 1000

-- Gloire requise et insigne de chaque rang, du premier au quinzieme. A partir du
-- onzieme : weeks semaines finies dans les top premiers de sa faction. Le dernier,
-- Overlord, porte le diamant de prestige (la seule gemme) : plus de Gloire que les
-- autres et cinq semaines finies premier de sa faction, sans devoir se suivre.
-- Un seuil se baisse sans mal (des joueurs montent), il ne se releve pas (des joueurs
-- redescendraient) : dans le doute, haut.
-- points : la valeur du haut fait de ce rang au Pantheon (Vos exploits).
R.TIERS = {
    { glory = 15,     icon = "prestige-icon-1", points = 5 },
    { glory = 150,    icon = "prestige-icon-2", points = 5 },
    { glory = 500,    icon = "prestige-icon-3", points = 5 },
    { glory = 1500,   icon = "prestige-icon-4", points = 5 },
    { glory = 4000,   icon = "prestige-icon-2-1", points = 10 },
    { glory = 8000,   icon = "prestige-icon-2-3", points = 10 },
    { glory = 15000,  icon = "prestige-icon-6-2", points = 10 },
    { glory = 30000,  icon = "prestige-icon-6-3", points = 10 },
    { glory = 60000,  icon = "prestige-icon-5-2", points = 15 },
    { glory = 100000, icon = "prestige-icon-5-4", points = 15 },
    { glory = 100000, icon = "prestige-icon-3-5", top = 100, weeks = 3, points = 20 },
    { glory = 100000, icon = "prestige-icon-2-5", top = 25,  weeks = 3, points = 20 },
    { glory = 100000, icon = "prestige-icon-7-2", top = 10,  weeks = 3, points = 25 },
    { glory = 100000, icon = "prestige-icon-7-4", top = 3,   weeks = 3, points = 25 },
    { glory = 150000, icon = "prestige-icon-8-4", top = 1,   weeks = 5, points = 50 },
}

local state = {}

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function LocalName()
    local sync = Overlord.Sync
    local name = sync and sync.GetPlayerFullName and sync:GetPlayerFullName()
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

local function Count(value)
    value = math.floor(tonumber(value) or 0)
    return value > 0 and value or 0
end

local function IsFaction(value)
    return value == "Alliance" or value == "Horde"
end

local function Num(value)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(value) end
    return tostring(value)
end

-- Identifiant du personnage connecte : il suit un renommage et distingue deux
-- personnages qui ont porte le meme nom.
local function LocalGuid()
    if type(UnitGUID) ~= "function" then return nil end
    local ok, guid = pcall(UnitGUID, "player")
    if ok and type(guid) == "string" and guid ~= "" then return guid end
    return nil
end

-- Le classement est tenu par regle de royaume (un classement par « pool ») alors que
-- la sauvegarde est par compte : le constat ci-dessous est range par pool, pour qu'un
-- personnage d'une autre regle ne date pas le classement de celui-ci.
local function PoolKey()
    local pool = Overlord.GetCurrentLeaderboardSavedVarsPool and Overlord:GetCurrentLeaderboardSavedVarsPool()
    return type(pool) == "string" and pool ~= "" and pool or "-"
end

-- Derniere fois ou les victoires du classement local (celui du personnage connecte) ont
-- ete comparees en entier avec un voisin : la date que le rattrapage nous donne
-- (NoteLadderSeen). Elle ne recule jamais.
local function LadderSeenAt()
    local store = OverlordDB.ranksLadderSeenAt
    local kept = type(store) == "table" and Count(store[PoolKey()]) or 0
    -- Une date dans le futur (sauvegarde abimee, horloge avancee) ne vaut rien : gardee,
    -- elle refuserait toutes les semaines suivantes puisque le constat ne recule jamais.
    local now = Count(GetServerTime and GetServerTime() or (time and time()))
    if now > 0 and kept > now + 3600 then kept = 0 end
    return kept
end

function R:GetLadderSeenAt()
    return type(OverlordDB) == "table" and LadderSeenAt() or 0
end

-- Appelee par le rattrapage du classement : des que les victoires d'un tour ont ete
-- comparees en entier (SyncLeaderboardPages), et a la fin de chaque tour reussi
-- (SyncHistoryCatchup). at : l'heure de cette comparaison si elle portait sur tout le
-- classement (pas seulement les lignes de la faction adverse), quoi qu'elle ait
-- rapporte ; nil sinon. Sur un classement anime aucun tour n'est jamais calme, et un
-- tour peut caler longtemps sur les captures ou les races, alors que le haut du
-- classement, lui, est connu depuis longtemps : exiger un tour calme, ou meme un tour
-- fini, rendrait les places hebdomadaires inaccessibles.
function R:NoteLadderSeen(at)
    if type(OverlordDB) ~= "table" then return end
    at = Count(at)
    -- (Une heure de serveur tient sous 2^32 ; au-dela ce n'est pas une date.)
    if at == 0 or at >= 4294967296 then return end
    local now = Count(GetServerTime and GetServerTime() or (time and time()))
    if now > 0 and at > now + 3600 then return end
    if at > LadderSeenAt() then
        local store = OverlordDB.ranksLadderSeenAt
        if type(store) ~= "table" then
            store = {}
            OverlordDB.ranksLadderSeenAt = store
        end
        store[PoolKey()] = at
    end
end

-- Presence en jeu de ce client (hors instance), par pool comme le constat ci-dessus :
-- a = le dernier releve, p = le dernier releve d'une semaine d'avant. Garder p evite
-- qu'une connexion juste apres le reset n'efface la preuve d'avoir joue la veille, et
-- qu'elle ne passe elle-meme pour une presence dans la semaine finie.
-- Releve a la connexion, toutes les ONLINE_STAMP_SEC et a la deconnexion ; jamais en
-- instance. Local, rien n'est envoye.
function R:NoteOnline()
    if type(OverlordDB) ~= "table" then return end
    if Overlord.InstanceSuspended or (IsInInstance and IsInInstance()) then return end
    local now = Count(GetServerTime and GetServerTime() or (time and time()))
    if now == 0 then return end
    local all = OverlordDB.ranksOnlineAt
    if type(all) ~= "table" then
        all = {}
        OverlordDB.ranksOnlineAt = all
    end
    local key = PoolKey()
    local row = all[key]
    if type(row) ~= "table" then
        row = {}
        all[key] = row
    end
    local last = Count(row.a)
    -- Un releve dans le futur (sauvegarde abimee, horloge avancee) ne vaut rien.
    if last > now + 3600 then last = 0 end
    local weekStart = Count(Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
    if last > 0 and weekStart > 0 and last < weekStart then row.p = last end
    if now > last or Count(row.a) ~= last then row.a = now end
end

-- Dernier releve de presence au plus tard a limit (0 s'il n'y en a pas).
local function OnlineAtOrBefore(limit)
    local all = OverlordDB.ranksOnlineAt
    local row = type(all) == "table" and all[PoolKey()] or nil
    if type(row) ~= "table" then return 0 end
    local a, p = Count(row.a), Count(row.p)
    if a > 0 and a <= limit then return a end
    if p > 0 and p <= limit then return p end
    return 0
end

-- ------------------------------------------------------------------ sceau de fiche
-- Le sceau est un nombre tire de tout ce qui fait le rang : le nom sous lequel la fiche
-- est rangee, l'identifiant qu'elle porte, les victoires, les captures, la faction, la
-- semaine en cours et son compte, la derniere semaine comptee, les cinq compteurs de
-- semaines, puis la semaine d'avant et son compte (pe, pk). Il est recalcule a chaque
-- ecriture de la fiche et verifie a sa premiere lecture de la session.
-- NE JAMAIS CHANGER ce calcul, ces constantes ni l'ordre des champs : toutes les fiches
-- existantes seraient refusees. Un nouveau format de fiche aurait un nouveau sceau, lu
-- a cote de celui-ci (tests/forever_ranks_seal.test.lua en fige des valeurs).
local SEAL_MOD = 2147483647
local SEAL_CHUNK = 16777216                  -- 2^24
local SEAL_LIMIT = SEAL_CHUNK * SEAL_CHUNK   -- 2^48
local SEAL_TIERS = { 100, 25, 10, 3, 1 }
-- Longueur maximale, en octets, d'un nom ou d'un identifiant de personnage scelle.
local SEAL_TEXT_MAX = 96
local seeds = {}
-- Fiches deja verifiees dans cette session (cles faibles : une fiche retiree s'oublie).
local trusted = setmetatable({}, { __mode = "k" })

-- Un pas du melange, pour une valeur entiere de 0 a 2^24 - 1. Deux temps : un pas
-- lineaire, puis un produit par un facteur tire de l'etat lui-meme, pour que deux
-- champs ne puissent pas se compenser l'un l'autre par une simple difference.
-- h < 2^31, facteurs < 2^16 puis < 2^15 : chaque produit reste exact dans un nombre Lua.
local function Mix(h, value)
    h = (h * 48271 + value + 11) % SEAL_MOD
    return (h * (h % 32749 + 2) + 918273) % SEAL_MOD
end

-- Un nombre entier de 0 a 2^48 - 1 entre en deux moities de 24 bits : aucune partie
-- du nombre n'est perdue (pas de reduction qui rendrait deux valeurs equivalentes).
local function MixNumber(h, value)
    h = Mix(h, value % SEAL_CHUNK)
    return Mix(h, math.floor(value / SEAL_CHUNK))
end

-- Un champ de la fiche. Une valeur de 2^48 ou plus n'existe dans aucune fiche honnete
-- (des centaines de milliers de milliards) : elle n'a pas de sceau.
local function MixField(h, raw)
    local value = Count(raw)
    if not h or not (value < SEAL_LIMIT) then return nil end
    return MixNumber(h, value)
end

-- Graine d'un texte (nom ou identifiant), majuscules ASCII repliees, calculee une fois.
local function Seed(text)
    if type(text) ~= "string" then return 7 end
    local h = seeds[text]
    if h then return h end
    h = 40507
    for index = 1, #text do
        local byte = string.byte(text, index)
        if byte >= 65 and byte <= 90 then byte = byte + 32 end
        h = Mix(h, byte)
    end
    seeds[text] = h
    return h
end

-- Le sceau (un entier de 1 a 2^31 - 1), ou nil si la fiche ne peut pas en avoir.
local function ComputeSeal(rec, name)
    local weeks = type(rec.t) == "table" and rec.t or nil
    local h = MixNumber(Seed(name), Seed(rec.g))
    h = MixField(h, rec.k)
    h = MixField(h, rec.c)
    if h then h = Mix(h, rec.f == "Alliance" and 1 or rec.f == "Horde" and 2 or 0) end
    h = MixField(h, rec.we)
    h = MixField(h, rec.wk)
    h = MixField(h, rec.lw)
    for index = 1, #SEAL_TIERS do
        h = MixField(h, weeks and weeks[SEAL_TIERS[index]])
    end
    h = MixField(h, rec.pe)
    h = MixField(h, rec.pk)
    if not h then return nil end
    return Mix(h, 65521) % (SEAL_MOD - 1) + 1
end

local function SealMatches(rec, name)
    local seal = ComputeSeal(rec, name)
    return seal ~= nil and rec.s == seal
end

-- A appeler apres TOUTE ecriture d'un champ scelle (k, c, f, g, we, wk, lw, t, pe, pk) et apres
-- un changement du nom sous lequel la fiche est rangee.
local function Reseal(rec, name)
    rec.s = ComputeSeal(rec, name)
    trusted[rec] = true
end

-- Vrai si la fiche porte le sceau de son contenu sous ce nom (lecture seule).
function R:IsSealed(rec, name)
    return type(rec) == "table" and type(name) == "string" and SealMatches(rec, name)
end

-- Fiche refusee : retiree des fiches, gardee de cote avec son nom et sa date pour
-- pouvoir etre rendue si le refus etait une erreur. Le personnage connecte est prevenu.
local function SetAside(self, all, key, rec, quiet)
    all[key] = nil
    if type(rec) ~= "table" then return end
    local list = OverlordDB.ranksSetAside
    if type(list) ~= "table" then
        list = {}
        OverlordDB.ranksSetAside = list
    end
    list[#list + 1] = { n = key, a = Count(GetServerTime and GetServerTime() or (time and time())), r = rec }
    -- (En un seul passage : une liste demesuree, sauvegarde abimee, ne coute qu'un parcours.)
    local surplus = #list - self.SET_ASIDE_MAX
    if surplus > 0 then
        local count = #list
        for index = 1, count do
            list[index] = list[index + surplus]
        end
    end
    if not quiet and key == LocalName() and not Overlord.InstanceSuspended and Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. T("RANK_RECORD_RESET",
            "Your Overlord Rank record could not be read back: it starts again from zero."))
    end
end

-- Vrai si cette table est une fiche au sceau juste pour ce nom. Un nom ou un identifiant
-- demesure ne vient pas du jeu : il n'est meme pas lu (le sceau le parcourt octet par
-- octet).
local function SealOk(rec, key)
    if type(rec) ~= "table" or type(key) ~= "string" or #key > SEAL_TEXT_MAX then return false end
    local guid = rec.g
    if type(guid) == "string" and #guid > SEAL_TEXT_MAX then return false end
    return SealMatches(rec, key)
end

-- La fiche rangee sous ce nom si elle est utilisable, sinon nil apres l'avoir mise de
-- cote (le second retour vaut alors true). Une fiche n'est verifiee qu'une fois par
-- session.
local function Usable(self, all, key)
    local rec = all[key]
    if rec == nil then return nil, false end
    if type(rec) == "table" then
        if trusted[rec] then return rec end
        if SealOk(rec, key) then
            trusted[rec] = true
            return rec
        end
    end
    SetAside(self, all, key, rec)
    return nil, true
end

-- ------------------------------------------------------------------ copie par personnage
-- La sauvegarde du compte peut se perdre (un client qui ne la recharge pas a la
-- connexion la recrit vide a la deconnexion) : le classement se repare par le reseau,
-- un rang jamais. La fiche du personnage connecte est donc aussi rangee dans la
-- sauvegarde du PERSONNAGE, un autre fichier. C'est la meme table : chaque ecriture y
-- est, sans copie. A la premiere lecture d'une session, la copie est reprise si elle
-- porte un sceau juste pour ce nom et que la fiche du compte manque, est refusee ou est
-- moins avancee (un rang ne recule jamais : la plus avancee des deux est la bonne).
-- Limite : si les deux fichiers manquent a la meme connexion, rien ne distingue ce cas
-- d'une premiere installation.
local copyTried

local function RestorableCopy(name)
    if copyTried == name then return nil end
    copyTried = name
    local store = OverlordCharDB
    local copy = type(store) == "table" and store.rank or nil
    if SealOk(copy, name) then return copy end
    return nil
end

-- Vrai si la fiche a est plus avancee que la fiche b. Un ordre sans egalite cachee :
-- les victoires, puis les captures, puis la derniere semaine comptee, puis le total
-- des semaines par palier (aucun de ces nombres ne recule jamais sur une fiche).
local function Further(a, b)
    local x, y = Count(a.k), Count(b.k)
    if x ~= y then return x > y end
    x, y = Count(a.c), Count(b.c)
    if x ~= y then return x > y end
    x, y = Count(a.lw), Count(b.lw)
    if x ~= y then return x > y end
    x, y = 0, 0
    local weeksA, weeksB = type(a.t) == "table" and a.t or nil, type(b.t) == "table" and b.t or nil
    for index = 1, #SEAL_TIERS do
        local top = SEAL_TIERS[index]
        x, y = x + Count(weeksA and weeksA[top]), y + Count(weeksB and weeksB[top])
    end
    return x > y
end

local function Mirror(rec)
    local store = OverlordCharDB
    if type(store) ~= "table" then
        store = {}
        OverlordCharDB = store
    end
    if store.rank ~= rec then store.rank = rec end
    return rec
end

function R:GetRankIcon(rank)
    local tier = self.TIERS[rank]
    return tier and (self.ICON_DIR .. tier.icon) or nil
end

function R:GetRankName(rank)
    if not rank or rank <= 0 then return T("RANK_NAME_0", "Unranked") end
    return T("RANK_NAME_" .. rank, "Rank " .. rank)
end

function R:GetGlory(kills, captures)
    return Count(kills) * self.GLORY_PER_KILL + Count(captures) * self.GLORY_PER_CAPTURE
end

-- Semaines finies dans les top premiers, lues sur la fiche (0 sans fiche).
function R:GetTopWeeks(rec, top)
    local weeks = rec and rec.t
    return Count(type(weeks) == "table" and weeks[top])
end

-- Les rangs se montent dans l'ordre : le premier palier manque arrete la montee.
function R:GetRankFor(glory, rec)
    local rank = 0
    local tiers = self.TIERS
    for index = 1, #tiers do
        local tier = tiers[index]
        if glory < tier.glory then break end
        if tier.top and self:GetTopWeeks(rec, tier.top) < tier.weeks then break end
        rank = index
    end
    return rank
end

-- Fiche du personnage connecte : k victoires et c captures a vie, f sa faction, g son
-- identifiant, we et wk le debut et les victoires de la semaine en cours, t les
-- semaines par palier, lw la derniere semaine comptee, pe et pk le debut et les
-- victoires de la semaine d'avant. Une fiche nait vide : elle ne
-- reprend rien du classement. Rangee sous le nom (le classement est par nom) ; un
-- personnage renomme retrouve la sienne par son identifiant.
function R:GetRecord(create)
    if type(OverlordDB) ~= "table" then return nil end
    local name = LocalName()
    if not name then return nil end
    local all = OverlordDB.ranksByCharacter
    local copy = RestorableCopy(name)
    if type(all) ~= "table" then
        if not create and not copy then return nil end
        all = {}
        OverlordDB.ranksByCharacter = all
    end
    local guid = LocalGuid()
    -- La copie du personnage est bonne : une fiche du compte au sceau faux lui cede la
    -- place sans rien annoncer (rien n'est perdu), et reste gardee de cote.
    if copy then
        local raw = all[name]
        if raw ~= nil and raw ~= copy and not trusted[raw] and not SealOk(raw, name) then
            SetAside(self, all, name, raw, true)
        end
    end
    local rec = Usable(self, all, name)
    if copy and copy ~= rec and (not rec or Further(copy, rec)) then
        all[name] = copy
        trusted[copy] = true
        rec = copy
    end
    -- Une fiche valide sous notre nom est la notre, quel que soit l'identifiant qu'elle
    -- porte : un transfert peut le changer, et jeter un rang a vie pour cela serait
    -- bien pire que d'heriter de celui d'un personnage supprime du meme nom.
    if rec then
        if guid and rec.g ~= guid then
            rec.g = guid
            Reseal(rec, name)
        end
        return Mirror(rec)
    end
    -- Pas de fiche a nous sous ce nom : la notre est peut-etre sous notre ancien nom.
    -- Elle est verifiee sous cet ancien nom, puis rescellee sous le nouveau.
    if guid then
        for oldName, other in pairs(all) do
            if oldName ~= name and type(other) == "table" and other.g == guid then
                local moved = Usable(self, all, oldName)
                if moved then
                    all[oldName] = nil
                    all[name] = moved
                    Reseal(moved, name)
                    return Mirror(moved)
                end
                break
            end
        end
    end
    if not create then return nil end
    rec = { k = 0, c = 0, g = guid }
    Reseal(rec, name)
    all[name] = rec
    return Mirror(rec)
end

-- Etat courant dans une table reutilisee (aucune allocation par appel).
function R:GetState()
    local rec = self:GetRecord(false)
    local kills = rec and Count(rec.k) or 0
    local captures = rec and Count(rec.c) or 0
    local glory = self:GetGlory(kills, captures)
    local rank = self:GetRankFor(glory, rec)
    local floor = rank > 0 and self.TIERS[rank].glory or 0
    local nextTier = self.TIERS[rank + 1]
    state.kills, state.captures, state.glory, state.rank = kills, captures, glory, rank
    state.floor = floor
    -- Vers le rang suivant : de la Gloire tant qu'elle manque, puis des semaines.
    state.nextAt, state.gateTop, state.gateNeed, state.gateHave = nil, nil, nil, nil
    if not nextTier then
        state.progress = 1
    elseif glory < nextTier.glory then
        state.nextAt = nextTier.glory
        state.progress = (glory - floor) / (nextTier.glory - floor)
    else
        state.gateTop, state.gateNeed = nextTier.top, nextTier.weeks
        state.gateHave = self:GetTopWeeks(rec, nextTier.top)
        state.progress = state.gateHave / nextTier.weeks
    end
    return state
end

-- Les quinze rangs comme hauts faits du Pantheon (categorie Vos exploits) : obtenu
-- ou non, avec la progression vers le suivant. Les lignes et la vue sont reutilisees
-- d'un appel a l'autre, leurs textes ecrits une fois (la langue ne change pas en cours
-- de session) ; elles ne sont demandees que Pantheon ouvert sur cette categorie.
local featRows, featView = {}, { stats = {} }

function R:GetFeatView()
    local state = self:GetState()
    local rank, glory = state.rank, state.glory
    local rec = self:GetRecord(false)
    local earnedCount, earnedPoints = 0, 0
    for index = 1, #self.TIERS do
        local tier = self.TIERS[index]
        local row = featRows[index]
        if not row then
            -- iconShaped : un insigne detoure, que le Pantheon montre entier dans son cadre.
            row = { kind = "lifetime", data = { id = "rank_" .. index }, sortOrder = index,
                icon = self:GetRankIcon(index), iconShaped = true, points = tier.points }
            row.title = self:GetRankName(index)
            if tier.top == 1 then
                row.subtitle = string.format(T("RANK_FEAT_FIRST", "%s Glory and %d weeks finished first of your faction."),
                    Num(tier.glory), tier.weeks)
            elseif tier.top then
                row.subtitle = string.format(T("RANK_FEAT_TOP", "After rank 10, finish %d weeks in the top %d of your faction."),
                    tier.weeks, tier.top)
            else
                row.subtitle = string.format(T("RANK_FEAT_GLORY", "Reach %s Glory."), Num(tier.glory))
            end
            row.searchHaystack = (row.title .. " " .. row.subtitle):lower()
            featRows[index] = row
        end
        -- La Gloire d'abord, puis les semaines : une barre pleine de semaines sur un
        -- rang dont la Gloire manque encore ferait croire qu'il est acquis.
        if tier.top and glory >= tier.glory then
            row.progressTotal = tier.weeks
            row.progressCurrent = math.min(self:GetTopWeeks(rec, tier.top), tier.weeks)
        else
            row.progressTotal = tier.glory
            row.progressCurrent = math.min(glory, tier.glory)
        end
        row.earned = rank >= index
        if row.earned then
            earnedCount = earnedCount + 1
            earnedPoints = earnedPoints + tier.points
        end
    end
    local stats = featView.stats
    stats.totalCount, stats.earnedCount, stats.totalPoints, stats.donorCount = #featRows, earnedCount, earnedPoints, 0
    stats.lifetimeEarnedCount, stats.lifetimeTotalCount = earnedCount, #featRows
    featView.rows = featRows
    return featView
end

-- Le Pantheon, s'il est ouvert, suit la Gloire et les rangs (appel sans effet ferme).
local function RefreshHallOfFame()
    local hall = Overlord.HallOfFameUI
    if hall and hall.RequestFeatsRefresh then hall:RequestFeatsRefresh() end
end

-- Un rang atteint : une ligne dans le chat, le bandeau a l'ecran, le Pantheon a jour.
-- Toujours appelee sous pcall, apres le sceau.
local function AnnounceRank(rank)
    local icon = R:GetRankIcon(rank)
    local text = string.format(T("RANK_UP_CHAT", "New Overlord rank: %s"), R:GetRankName(rank))
    if icon then text = "|T" .. icon .. ":16:16:0:0|t " .. text end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    end
    local toast = Overlord.RankToast
    if toast and toast.Show then toast:Show(rank) end
end

local function AnnounceWeek(place, reached, before, after, kills, fresh)
    if Overlord.PrintNotification then
        local text = string.format(
            T("RANK_WEEK_CHAT", "Week finished in place %d of your faction: a top %d week."), place, reached)
        -- Dans les trois premiers, mais le classement n'avait pas ete compare a temps : la
        -- semaine compte pour les tops plus larges, et le joueur sait pourquoi.
        if place <= R.WEEK_STRICT_TOP and not fresh then
            text = text .. " " .. T("RANK_WEEK_NOT_COMPARED",
                "A top 3 week needs your ranking to have been compared with other players during the week's last 24 hours.")
        -- Premier, mais sous le plancher d'une semaine finie premier : le joueur sait pourquoi.
        elseif place == 1 and reached ~= 1 then
            text = text .. " " .. string.format(
                T("RANK_WEEK_FIRST_FLOOR", "A week finished first counts from %s honorable kills (you had %s)."),
                Num(R.WEEK_FIRST_MIN_KILLS), Num(Count(kills)))
        end
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. text)
    end
    if after > before then AnnounceRank(after) end
end

-- Credit d'une victoire ou d'une capture du joueur local, appele par le classement sur
-- ses seuls chemins locaux. Par credit : quelques lectures de table, trois additions
-- et une boucle de quinze comparaisons au plus. Les victoires alimentent aussi le
-- compteur de la semaine en cours, seul score utilise a la cloture.
function R:CreditLocal(field, amount)
    amount = Count(amount)
    if amount == 0 or (field ~= "kills" and field ~= "captures") then return end
    if Overlord.InstanceSuspended then return end
    -- Le nom sous lequel la fiche est rangee, lu une fois : c'est aussi celui du sceau.
    local name = LocalName()
    local rec = name and self:GetRecord(true)
    if not rec then return end
    local before = self:GetRankFor(self:GetGlory(rec.k, rec.c), rec)
    if field == "kills" then
        rec.k = Count(rec.k) + amount
        local ladder = OverlordDB.leaderboard
        local week = Count(type(ladder) == "table" and ladder.campaignStart)
        -- La semaine du classement est la semaine en cours : elle a commence il y a
        -- sept jours au plus et jamais dans le futur. Les marges sont larges (au pire
        -- honnete : 8,5 jours en arriere, 36 heures en avant ; ici 10 jours et 72 h).
        -- Une autre date ne vient pas du jeu ; la victoire compte pour la Gloire, pas
        -- pour une semaine.
        local now = Count(GetServerTime and GetServerTime() or (time and time()))
        if now > 0 and (week > now + 2 * self.WEEK_EPOCH_SLACK_SEC or week < now - self.WEEK_SEC - 3 * 86400) then
            week = 0
        end
        if week > 0 then
            -- Le debut de semaine peut etre recale de quelques heures en cours de
            -- semaine (ancienne sauvegarde) : c'est la meme semaine, le compte reste.
            local known = Count(rec.we)
            if known ~= week then
                if known == 0 or math.abs(known - week) > self.WEEK_EPOCH_SLACK_SEC then
                    -- Une autre semaine commence. Le compte de celle qui finit est garde
                    -- (pe, pk) : sa cloture peut passer apres cette victoire (un
                    -- rechargement, une deconnexion ou un plantage pendant l'archive : ses
                    -- sondes sont alors refaites depuis la fiche) et doit encore y trouver
                    -- le score de la semaine. (Au reset lui-meme l'archive demarre avant
                    -- que la victoire qui l'a declenche soit creditee.)
                    if known > 0 and Count(rec.wk) > 0 then
                        rec.pe, rec.pk = known, Count(rec.wk)
                    end
                    rec.wk = 0
                end
                rec.we = week
            end
            rec.wk = Count(rec.wk) + amount
        end
    else
        rec.c = Count(rec.c) + amount
    end
    local faction = Overlord.PlayerFaction
    if IsFaction(faction) and rec.f ~= faction then rec.f = faction end
    Reseal(rec, name)
    local after = self:GetRankFor(self:GetGlory(rec.k, rec.c), rec)
    if after > before then pcall(AnnounceRank, after) end
    pcall(RefreshHallOfFame)
    local ui = Overlord.RanksUI
    if ui and ui.selected and ui.Refresh then ui:Refresh() end
end

-- ------------------------------------------------------------------ cloture de semaine
-- Le classement detache la semaine finie et la parcourt par tranches pour son archive ;
-- la place de chaque personnage du compte se compte au passage, sans parcours ni tri en
-- plus. Les donnees sont par compte : le personnage connecte a la cloture n'est pas
-- forcement celui qui a joue la semaine, d'ou une sonde par personnage qui y a des
-- victoires comptees par ce client.

local function IsDeniedName(name)
    local sync = Overlord.Sync
    return sync and sync.IsDeniedKillContributor and sync:IsDeniedKillContributor(name) or false
end

-- Victoires comptees ici pour la semaine qui commence a epoch, ou nil si la fiche n'en
-- porte pas : le compteur de la semaine en cours, ou celui de la semaine d'avant si
-- une victoire a deja ouvert la suivante. Jamais la ligne du classement.
local function WeekKills(self, rec, epoch)
    if math.abs(Count(rec.we) - epoch) <= self.WEEK_EPOCH_SLACK_SEC then return Count(rec.wk) end
    if math.abs(Count(rec.pe) - epoch) <= self.WEEK_EPOCH_SLACK_SEC then return Count(rec.pk) end
    return nil
end

local function AddWeekProbe(self, probes, bucket, epoch, name, rec, localName)
    if #probes >= self.WEEK_MAX_PROBES or type(rec) ~= "table" then return end
    local kills = WeekKills(self, rec, epoch)
    if not kills or kills < self.WEEK_MIN_KILLS then return end
    -- La ligne doit seulement exister : c'est bien le classement ou ce personnage joue.
    if Count(bucket.kills[name]) == 0 then return end
    -- Deux semaines comptees sont distantes d'au moins six jours : une meme semaine
    -- archivee deux fois (restauration, reprise) ne paie qu'une fois.
    local last = Count(rec.lw)
    if last > 0 and epoch < last + self.WEEK_MIN_SEC then return end
    local faction = name == localName and Overlord.PlayerFaction or nil
    if not IsFaction(faction) then faction = rec.f end
    if not IsFaction(faction) then return end
    probes[#probes + 1] = { name = name, kills = kills, faction = faction, above = 0,
        isLocal = name == localName }
end

-- Sondes de la semaine finie, ou nil si elle ne peut pas compter : pas une vraie
-- semaine, ni classement compare ni presence en jeu sur sa derniere journee, ou aucun
-- personnage du compte n'y a de victoire comptee ici.
function R:BeginWeekClose(marker)
    local bucket = type(marker) == "table" and marker.bucket
    if type(bucket) ~= "table" or type(bucket.kills) ~= "table" or type(OverlordDB) ~= "table" then
        return nil
    end
    local all = OverlordDB.ranksByCharacter
    if type(all) ~= "table" then return nil end
    local epoch, fresh = self:GetWeekCloseWindow(marker)
    if not epoch then return nil end
    -- Le personnage connecte d'abord : le plafond de sondes ne l'ecarte jamais.
    local probes, localName = {}, LocalName()
    if localName then
        AddWeekProbe(self, probes, bucket, epoch, localName, Usable(self, all, localName), localName)
    end
    -- (Mettre une fiche de cote pendant ce parcours efface une cle existante, ce que
    -- le parcours d'une table permet.) Le parcours s'arrete apres quelques fiches
    -- refusees : une sauvegarde honnete n'en contient aucune, et une sauvegarde bourree
    -- de fausses fiches ne doit pas en faire verifier des milliers.
    local refused = 0
    for name in pairs(all) do
        if name ~= localName then
            local rec, failed = Usable(self, all, name)
            AddWeekProbe(self, probes, bucket, epoch, name, rec, localName)
            if failed then
                refused = refused + 1
                if refused >= self.SET_ASIDE_MAX then break end
            end
        end
    end
    if #probes == 0 then return nil end
    -- fresh : le classement avait ete compare a temps, les trois premieres places comptent.
    return { epoch = epoch, limit = self.PLACE_TIERS[1], probes = probes, fresh = fresh }
end

-- Fenetre de la semaine finie : son debut (epoch) et si le classement avait ete compare
-- a temps (fresh), ou nil si elle ne peut pas compter (pas une vraie semaine, ni
-- classement compare ni presence en jeu sur sa derniere journee). Partagee avec les
-- rangs du haut vus par les autres (RankProof), qui suivent la meme regle.
function R:GetWeekCloseWindow(marker)
    if type(marker) ~= "table" or type(OverlordDB) ~= "table" then return nil end
    local epoch = Count(marker.archiveEpoch)
    local resetEpoch = Count(marker.resetEpoch)
    if epoch == 0 or resetEpoch - epoch < self.WEEK_MIN_SEC then return nil end
    -- Une semaine ne se ferme qu'apres son reset (le classement tire ce reset de la meme
    -- horloge) : une archive datee dans le futur ne vient pas du jeu.
    local now = Count(GetServerTime and GetServerTime() or (time and time()))
    if now > 0 and resetEpoch > now + 3600 then return nil end
    -- Fin de la semaine que contient l'archive. Apres une semaine d'absence l'archive
    -- est fermee deux resets plus tard, mais elle ne contient que la semaine jouee :
    -- toute connexion plus tardive l'aurait fermee avant.
    local weekEnd = resetEpoch
    if resetEpoch - epoch > self.WEEK_SEC + self.WEEK_EPOCH_SLACK_SEC then
        weekEnd = epoch + self.WEEK_SEC
    end
    -- Derniere fois ou le classement local a ete constate a jour (un tour encore en
    -- rattrapage ne compte pas, il manquerait des joueurs devant nous). Elle doit
    -- tomber dans les dernieres WEEK_FRESH_SEC de cette semaine-la
    -- (WEEK_CLOSE_GRACE_SEC de marge apres sa fin).
    -- Lue une seule fois et gardee sur le marqueur : une archive reprise plus tard ne
    -- doit pas se fier a un constat de la semaine suivante.
    local syncedAt = Count(marker.rankSyncedAt)
    if syncedAt == 0 then
        syncedAt = LadderSeenAt()
        syncedAt = syncedAt > 0 and syncedAt or 1
        marker.rankSyncedAt = syncedAt
    end
    local fresh = not (syncedAt < weekEnd - self.WEEK_FRESH_SEC or syncedAt > weekEnd + self.WEEK_CLOSE_GRACE_SEC)
    -- Presence en jeu dans ces memes 24 heures (aucune marge apres la fin : une
    -- connexion juste apres le reset n'est pas avoir joue la veille). Lue une seule
    -- fois et gardee sur le marqueur, comme le constat.
    local playedAt = Count(marker.rankPlayedAt)
    if playedAt == 0 then
        playedAt = OnlineAtOrBefore(weekEnd)
        playedAt = playedAt > 0 and playedAt or 1
        marker.rankPlayedAt = playedAt
    end
    -- (Une semaine qui ne compte pas ne dit rien dans le chat : rien qui harcele les
    -- joueurs. L'infobulle de la jauge montre quand le classement a ete compare.)
    if not fresh and playedAt < weekEnd - self.WEEK_FRESH_SEC then return nil end
    return epoch, fresh, weekEnd
end

-- Une ligne de la semaine finie. Pour chaque sonde, seules les lignes de sa faction
-- avec plus de victoires qu'elle comptent, et le compte s'arrete au palier le plus
-- large : au-dela la semaine est deja hors course. La fiche de la ligne et la liste
-- des noms ecartes ne sont lues que pour une ligne qui passe devant quelqu'un.
function R:ProbeWeekRow(session, name, kills, playerInfo)
    if type(kills) ~= "number" then return end
    local probes, limit = session.probes, session.limit
    local info, denied
    for index = 1, #probes do
        local probe = probes[index]
        if kills > probe.kills and probe.above < limit and name ~= probe.name then
            if info == nil then info = type(playerInfo) == "table" and playerInfo[name] or false end
            if type(info) == "table" and info.faction == probe.faction then
                if denied == nil then denied = IsDeniedName(name) end
                local lb = Overlord.Leaderboard
                if not denied and not (probe.isLocal and lb and lb.IsLocalDisplayName
                    and lb:IsLocalDisplayName(name)) then
                    probe.above = probe.above + 1
                end
            end
        end
    end
end

-- Fin du parcours : pour chaque sonde la semaine est marquee comptee (une reprise
-- apres coupure ne la recompte pas) et credite chaque palier atteint. Seul le
-- personnage connecte est prevenu dans le chat, et jamais en instance.
-- Une premiere place ne vaut une semaine finie premier qu'avec assez de victoires, et
-- les trois premieres places ne comptent que classement compare a temps (session.fresh).
function R:FinishWeekClose(session)
    if type(session) ~= "table" or type(session.probes) ~= "table" or type(OverlordDB) ~= "table" then
        return
    end
    local all = OverlordDB.ranksByCharacter
    if type(all) ~= "table" then return end
    local localName = LocalName()
    for index = 1, #session.probes do
        local probe = session.probes[index]
        local rec = Usable(self, all, probe.name)
        local last = rec and Count(rec.lw) or 0
        if rec and not (last > 0 and session.epoch < last + self.WEEK_MIN_SEC) then
            -- Toutes les ecritures, puis le sceau, et seulement ensuite le chat : rien de ce
            -- qui peut echouer (un addon de chat qui leve une erreur) ne doit se trouver
            -- entre une ecriture et le sceau.
            local before = self:GetRankFor(self:GetGlory(rec.k, rec.c), rec)
            local place, reached
            rec.lw = session.epoch
            if probe.above < session.limit then
                place = probe.above + 1
                if type(rec.t) ~= "table" then rec.t = {} end
                for _, top in ipairs(self.PLACE_TIERS) do
                    if place <= top and (top > 1 or probe.kills >= self.WEEK_FIRST_MIN_KILLS)
                        and (session.fresh or top > self.WEEK_STRICT_TOP) then
                        rec.t[top] = Count(rec.t[top]) + 1
                        reached = top
                    end
                end
            end
            Reseal(rec, probe.name)
            if reached and probe.isLocal and probe.name == localName and not Overlord.InstanceSuspended then
                pcall(AnnounceWeek, place, reached, before,
                    self:GetRankFor(self:GetGlory(rec.k, rec.c), rec), probe.kills, session.fresh)
            end
        end
    end
    pcall(RefreshHallOfFame)
    local ui = Overlord.RanksUI
    if ui and ui.selected and ui.Refresh then ui:Refresh() end
end

-- A la connexion, la fiche du personnage est relue une fois : son identifiant est mis a
-- jour (transfert) et un renommage est suivi tout de suite, sans attendre une victoire
-- ou l'ouverture de l'onglet. Un transfert et un renommage faits l'un apres l'autre
-- restent ainsi rattaches ; les deux a la fois, sans connexion entre eux, ne peuvent
-- pas l'etre (la fiche reste dans la sauvegarde sous l'ancien nom).
--
-- A la deconnexion (et au rechargement), juste avant que le jeu n'ecrive la sauvegarde,
-- chaque fiche verifiee dans cette session est scellee une derniere fois. Filet de
-- securite : une ecriture qui aurait echappe au sceau, ou qu'une erreur aurait
-- interrompue, ne laisse jamais dans le fichier une fiche honnete au sceau perime.
function R:SealForSave()
    local all = type(OverlordDB) == "table" and OverlordDB.ranksByCharacter
    if type(all) ~= "table" then return end
    for name, rec in pairs(all) do
        if type(name) == "string" and type(rec) == "table" and trusted[rec] then
            rec.s = ComputeSeal(rec, name)
        end
    end
end

if CreateFrame then
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGOUT" then
            pcall(R.NoteOnline, R)
            pcall(R.SealForSave, R)
        else
            pcall(R.GetRecord, R, false)
            -- Presence en jeu : maintenant, puis un releve toutes les cinq minutes (un
            -- nombre ecrit par passage ; rien en instance).
            pcall(R.NoteOnline, R)
            if not R._onlineTicker and C_Timer and C_Timer.NewTicker then
                R._onlineTicker = C_Timer.NewTicker(R.ONLINE_STAMP_SEC, function() pcall(R.NoteOnline, R) end) or true
            end
        end
    end)
end
