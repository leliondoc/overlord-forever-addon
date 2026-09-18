-- RealmPools.lua - Royaumes EU des pools Overlord (FR / DE / EU)
-- Source unique : communaute Battle.net, SavedVariables, export Check PvP.
-- Pool = royaume EU (onglet Blizzard), pas la locale client (frFR sur Ravencrest -> eu).
-- Cles ~ GetNormalizedRealmName() ; variante sans espaces / apostrophes / tirets acceptee.
-- Royaume manquant : /run print(GetNormalizedRealmName()) en jeu, puis ajouter la cle ici.

Overlord = Overlord or {}
local RealmPools = {}
Overlord.RealmPools = RealmPools

local connectedRealmKeys = {}
local connectedRealmsReady = false
local connectedRealmsRetryAt = 0
local CONNECTED_REALMS_RETRY_SEC = 1

-- Onglet « Francais » region EU : Normal + PvP (pas JdR ; voir FR_RP).
RealmPools.FR = {
    Arakarahm = true,
    Arathi = true,
    Archimonde = true,
    ChantsEternels = true,
    Chogall = true,
    Dalaran = true,
    DrekThar = true,
    Eitrigg = true,
    EldreThalas = true,
    Elune = true,
    Garona = true,
    Hyjal = true,
    Illidan = true,
    Kaelthas = true,
    KhazModan = true,
    Kiljaeden = true, -- PvP francophone EU
    Krasus = true,
    MarecagedeZangar = true,
    Medivh = true,
    Naxxramas = true,
    Nerzhul = true,
    Rashgarroth = true,
    Sargeras = true,
    Sinstralis = true,
    Suramar = true,
    Templenoir = true,
    ThrokFeroth = true,
    Uldaman = true,
    Varimathras = true,
    Voljin = true,
    Ysondre = true,
}

-- JdR N francophones (onglet Francais Blizzard) : pool FR + flag RP (auto-groupe front).
RealmPools.FR_RP = {
    ConfrerieduThorium = true,
    ["ConfrérieduThorium"] = true,
    ConseildesOmbres = true,
    CultedelaRivenoire = true,
    KirinTor = true,
    LaCroisadeecarlate = true,
    ["LaCroisadeécarlate"] = true,
    LaCroisadeEcarlate = true,
    LesClairvoyants = true,
    LesSentinelles = true,
}

for realmKey in pairs(RealmPools.FR_RP) do
    RealmPools.FR[realmKey] = true
end

-- Onglet « Allemand » region EU : Normal, PvP (pas JdR ; voir DE_RP).
RealmPools.DE = {
    Aegwynn = true, Alexstrasza = true, Alleria = true, Amanthul = true, Ambossar = true,
    Anetheron = true, Anubarak = true, Antonidas = true, Arthas = true, Area52 = true,
    Arygos = true, Azshara = true,
    Baelgun = true, Blackhand = true, Blackmoore = true, Blackrock = true, Blutkessel = true,
    Dalvengyr = true, DasKonsortium = true, DasSyndikat = true,
    DerAbyssischeRat = true, DerabyssischerRat = true, DerMithrilorden = true,
    DerRatvonDalaran = true, Destromath = true, Dethecus = true, DieAldor = true,
    DieArguswacht = true, DieEwigeWacht = true, DieewigeWacht = true, DieNachtwache = true,
    DieSilberneHand = true, DieTodeskrallen = true, DunMorogh = true, Durotan = true,
    Echsenkessel = true, Eredar = true, FestungderSturme = true, Forscherliga = true,
    Frostmourne = true, Frostwolf = true, Garrosh = true, Gilneas = true, Gorgonnash = true,
    Guldan = true,
    Kargath = true, KelThuzad = true, Khazgoroth = true, Kiljaeden = true, Kragjin = true,
    KultderVerdammten = true, Lordaeron = true, Lothar = true, Madmortem = true,
    Malganis = true, MalGanis = true, Malfurion = true, Malorne = true, Malygos = true,
    Mannoroth = true, Mugthol = true, Nathrezim = true, Nazjatar = true, Nefarian = true,
    Nethersturm = true, Nerathor = true, Norgannon = true, Nozdormu = true, Onyxia = true,
    Perenolde = true, Proudmoore = true,
    Rajaxx = true, Rexxar = true, Senjin = true, Shattrath = true, Taerar = true,
    Teldrassil = true, Terrordar = true, Terenas = true, Theradras = true, Thrall = true, Tichondrius = true,
    Tirion = true, Todeswache = true,
    Ulduar = true, UnGoro = true, Veklor = true, Wrathbringer = true, Ysera = true,
    ZirkeldesCenarius = true, Zuluhed = true,
}

-- JdR / JdR N / JdR PvP allemands (onglet Allemand) : pool DE + flag RP.
RealmPools.DE_RP = {
    DasKonsortium = true, DasSyndikat = true,
    DerAbyssischeRat = true, DerabyssischeRat = true, DerabyssischerRat = true,
    DerMithrilorden = true, DerRatvonDalaran = true,
    DieAldor = true, DieArguswacht = true,
    DieEwigeWacht = true, DieewigeWacht = true,
    DieNachtwache = true, DieSilberneHand = true, DieTodeskrallen = true,
    Forscherliga = true, KultderVerdammten = true,
    Todeswache = true, ZirkeldesCenarius = true,
}

for realmKey in pairs(RealmPools.DE_RP) do
    RealmPools.DE[realmKey] = true
end

-- Royaumes RP / RP-PvP region EU (toutes langues) : auto-groupe RG en front (Sync.lua).
-- FR et DE : remplis via FR_RP / DE_RP (alignes onglets Blizzard, pas de Normal ici).
-- https://wowpedia.fandom.com/wiki/Europe_region_realm_list_by_datacenter
RealmPools.RP = {
    -- EN
    ArgentDawn = true,
    DarkmoonFaire = true,
    DefiasBrotherhood = true,
    EarthenRing = true,
    Moonglade = true,
    Ravenholdt = true,
    ScarshieldLegion = true,
    Sporeggar = true,
    SteamwheedleCartel = true,
    TheShatar = true,
    TheVentureCo = true,
    -- ES
    LosErrantes = true,
    Shendralar = true,
}

for realmKey in pairs(RealmPools.FR_RP) do
    RealmPools.RP[realmKey] = true
end

for realmKey in pairs(RealmPools.DE_RP) do
    RealmPools.RP[realmKey] = true
end

local function CompactRealmKey(key)
    return key:gsub("[%s%-'']", "")
end

-- Cle normalisee selon C_AutoComplete.GetAutoCompleteRealms :
-- espaces et tirets retires, comparaison insensible a la casse.
local function NormalizeConnectedRealmKey(realmName)
    if type(realmName) ~= "string" or realmName == "" then return nil end
    local key = realmName:gsub("[%s%-]", ""):lower()
    if key == "" then return nil end
    return key
end

-- Blizzard fournit dynamiquement le groupe de royaumes connectes du joueur.
-- Ne pas maintenir de liste statique : les connexions peuvent changer.
function RealmPools:RefreshConnectedRealms()
    local now = GetTime and GetTime() or 0
    if not connectedRealmsReady and now < connectedRealmsRetryAt then return false end

    if not C_AutoComplete or not C_AutoComplete.GetAutoCompleteRealms
        or not GetNormalizedRealmName then
        connectedRealmsRetryAt = now + CONNECTED_REALMS_RETRY_SEC
        return false
    end

    local currentRealm = NormalizeConnectedRealmKey(GetNormalizedRealmName())
    if not currentRealm then
        connectedRealmsRetryAt = now + CONNECTED_REALMS_RETRY_SEC
        return false
    end

    local realms = C_AutoComplete.GetAutoCompleteRealms()
    if type(realms) ~= "table" then
        connectedRealmsRetryAt = now + CONNECTED_REALMS_RETRY_SEC
        return false
    end
    local nextKeys = { [currentRealm] = true }
    for i = 1, #realms do
        local key = NormalizeConnectedRealmKey(realms[i])
        if key then nextKeys[key] = true end
    end

    wipe(connectedRealmKeys)
    for key in pairs(nextKeys) do connectedRealmKeys[key] = true end
    connectedRealmsReady = true
    connectedRealmsRetryAt = 0
    return true
end

function RealmPools:IsPlayerConnectedRealm(realmName)
    if not connectedRealmsReady and not self:RefreshConnectedRealms() then
        return false
    end
    local key = NormalizeConnectedRealmKey(realmName)
    return key ~= nil and connectedRealmKeys[key] == true
end

function RealmPools:IsPlayerConnectedCharacter(fullName)
    if type(fullName) ~= "string" or fullName == "" then return false end
    local realm = fullName:match("^.-%-(.+)$")
    return realm ~= nil and self:IsPlayerConnectedRealm(realm)
end

-- La liste Blizzard peut ne pas etre finalisee au chargement des fichiers.
-- On la recharge a chaque entree en monde, sans appel repete dans les boucles UI.
local connectedRealmRefreshFrame = CreateFrame("Frame")
local connectedRealmBountyReplayPending = false
connectedRealmRefreshFrame:RegisterEvent("PLAYER_LOGIN")
connectedRealmRefreshFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
connectedRealmRefreshFrame:SetScript("OnEvent", function()
    -- Le pipeline Core reste l'unique proprietaire de l'initialisation et de sa
    -- barriere SavedVariables. L'evenement ne fait que rafraichir la vue Blizzard;
    -- le stage ManualBounty en attente la rejouera au prochain tick de 1 s.
    local ready = RealmPools:RefreshConnectedRealms()
    if ready and Overlord._deferredModuleInitDone and Overlord.ManualBounty
        and Overlord.ManualBounty._initialized
        and Overlord.ManualBounty.OnPlayerIdentityChanged
        and not connectedRealmBountyReplayPending then
        connectedRealmBountyReplayPending = true
        C_Timer.After(0, function()
            connectedRealmBountyReplayPending = false
            if Overlord._deferredModuleInitDone and Overlord.ManualBounty
                and Overlord.ManualBounty._initialized
                and Overlord.ManualBounty.OnPlayerIdentityChanged then
                Overlord.ManualBounty:OnPlayerIdentityChanged()
            end
        end)
    end
end)

function RealmPools:KeyInPool(pool, realmKey)
    if type(pool) ~= "table" or not realmKey or realmKey == "" then return false end
    if pool[realmKey] then return true end
    return pool[CompactRealmKey(realmKey)] == true
end

-- Cle royaume joueur (alignee GetPlayerFullName / bridges). Core.lua fournit SafeGetRealmName.
function RealmPools:GetPlayerRealmKey()
    if Overlord.SafeGetRealmName then
        local r = Overlord:SafeGetRealmName()
        if r and r ~= "" then return r end
    end
    return ""
end

function RealmPools:IsFrenchEURealm(realmKey)
    return self:KeyInPool(self.FR, realmKey or self:GetPlayerRealmKey())
end

function RealmPools:IsGermanEURealm(realmKey)
    return self:KeyInPool(self.DE, realmKey or self:GetPlayerRealmKey())
end

function RealmPools:IsRPRealm(realmKey)
    return self:KeyInPool(self.RP, realmKey or self:GetPlayerRealmKey())
end

-- Pool Overlord (communaute BNet, SavedVariables, export) : us | fr | de | eu.
-- Base sur la region Blizzard et le royaume EU, pas la locale client (frFR sur Ravencrest = eu).
function RealmPools:GetOverlordPoolTag(realmKey)
    if not GetCurrentRegion then return nil end
    local region = GetCurrentRegion()
    if region == 1 then return "us" end
    if region == 3 then return "eu" end
    return nil
end

-- Deduit le pool depuis un nom complet Nom-Royaume (classement / export distant).
function RealmPools:InferPoolTagFromRealmName(fullName)
    if not fullName or fullName == "" then return "" end
    if not GetCurrentRegion or GetCurrentRegion() ~= 3 then return "" end
    local realm = fullName:match("^.-%-(.+)$")
    if not realm or realm == "" then return "" end
    if self:IsFrenchEURealm(realm) then return "fr" end
    if self:IsGermanEURealm(realm) then return "de" end
    return "eu"
end

-- Pools lies pour tout le systeme Outpost (etats, captures, tenants et ladder FR <-> EU).
function RealmPools:AreOutpostCrossPoolsLinked(poolA, poolB)
    if type(poolA) ~= "string" or type(poolB) ~= "string" then return false end
    poolA = poolA:lower():match("^%s*([a-z]+)%s*$") or ""
    poolB = poolB:lower():match("^%s*([a-z]+)%s*$") or ""
    if poolA == "" or poolB == "" then return false end
    if poolA == poolB then return true end
    return (poolA == "fr" and poolB == "eu") or (poolA == "eu" and poolB == "fr")
end
