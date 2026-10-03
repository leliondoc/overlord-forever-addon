-- Ressources.lua - Systeme de ressources joueur (or)
-- Module autonome : accumulation passive (cercle) + bonus actif (vrai node mine),
-- depense offensive (renfort -60s) et defensive (barricade +60s).
-- Core.lua n'appelle que Initialize / SaveResources / RestoreResources / ResetResources.
Overlord = Overlord or {}
Overlord.Ressources = {}

local L = Overlord.L

-- Referentiel couleurs tooltip (Core.UI_TT ; defaut si chargement atypique)
local function TT()
    return Overlord.UI_TT or { HL = { 1, 0.82, 0 }, BODY = { 1, 1, 1 }, MUTED = { 0.72, 0.72, 0.72 } }
end

local GOLD_MAX = 100
local GOLD_PASSIVE_INTERVAL = 3
local GOLD_PASSIVE_AMOUNT = 1
local GOLD_NODE_BONUS = 5
local GOLD_SPEND_COST = 25
local REINFORCE_REDUCTION = 60
local BARRICADE_INCREASE = 60
-- Plancher du timer apres renfort (doit correspondre a ZoneControl StartHoldTimer)
local REINFORCE_MIN_HOLD = 30

-- Source unique pour les textes (Locales.ApplyGoldLocaleStrings) et ZoneControl
local VICTORY_DOMINATION_BONUS = 0.02

Overlord.RessourcesConstants = {
    GOLD_MAX = GOLD_MAX,
    GOLD_SPEND_COST = GOLD_SPEND_COST,
    GOLD_PASSIVE_INTERVAL = GOLD_PASSIVE_INTERVAL,
    GOLD_PASSIVE_AMOUNT = GOLD_PASSIVE_AMOUNT,
    GOLD_NODE_BONUS = GOLD_NODE_BONUS,
    REINFORCE_REDUCTION = REINFORCE_REDUCTION,
    BARRICADE_INCREASE = BARRICADE_INCREASE,
    REINFORCE_MIN_HOLD = REINFORCE_MIN_HOLD,
    VICTORY_DOMINATION_BONUS = VICTORY_DOMINATION_BONUS,
}

-- Stock des mines : reserve partagee par site (100 max), drainee par le farm passif.
-- Regeneration : ~1 stock toutes les 36s jusqu'au max.
local MINE_STOCK_MAX = 100
local MINE_REGEN_INTERVAL = 36

-- Etat local (synchronise avec OverlordDB dans Save/Restore)
local gold = 0
local reinforceActive = false
local barricadeActive = false
local mineStocks = {}          -- [mineId] = stock (0..100)
local mineStockTimers = {}     -- [mineId] = accumulateur regen (secondes fractionnaires)
-- Index creux : seuls les stocks réellement sous le maximum sont visites par le
-- ticker. La cadence et la formule de regeneration restent strictement identiques.
local depletedMineIds = {}
local resourcesRestored = false

-- Ticker de minage passif
local mineTicker = nil
local resourceTickerFast = false
local resourceTickLastAt = 0
local mineAccumulator = 0
local currentMineId = nil

-- Cooldown alerte mine (1 par mine, evite le spam)
local MINE_ALERT_COOLDOWN = 60
local lastMineAlert = {}
-- Derniere mine pour laquelle on a envoye MN a l'entree (alerte immediate a chaque visite)
local mineVisitForMn = nil

-- Frame pour les events (bonus minage actif)
local resFrame = CreateFrame("Frame")

-- ==================== Floating Combat Text (or gagne) ====================
-- Pool de FontStrings animees qui montent et disparaissent au-dessus du personnage.
local FCT_POOL_SIZE = 6
local FCT_DURATION = 1.5
local FCT_RISE = 80
local fctPool = {}
local fctIndex = 1

local fctAnchor = CreateFrame("Frame", nil, UIParent)
fctAnchor:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
fctAnchor:SetSize(1, 1)

for i = 1, FCT_POOL_SIZE do
    local fs = fctAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetFont(fs:GetFont(), 16, "OUTLINE")
    fs:SetTextColor(1, 0.84, 0)
    fs:SetAlpha(0)
    fs:SetPoint("CENTER", fctAnchor, "CENTER", 0, 0)

    local ag = fs:CreateAnimationGroup()

    local translate = ag:CreateAnimation("Translation")
    translate:SetOffset(0, FCT_RISE)
    translate:SetDuration(FCT_DURATION)
    translate:SetSmoothing("OUT")

    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(FCT_DURATION * 0.4)
    fade:SetStartDelay(FCT_DURATION * 0.6)
    fade:SetSmoothing("IN")

    ag:SetScript("OnPlay", function() fs:SetAlpha(1) end)
    ag:SetScript("OnFinished", function() fs:SetAlpha(0) end)

    fctPool[i] = { fs = fs, ag = ag }
end

local function ShowFloatingGold(amount)
    local entry = fctPool[fctIndex]
    fctIndex = (fctIndex % FCT_POOL_SIZE) + 1
    entry.ag:Stop()
    local xJitter = math.random(-20, 20)
    entry.fs:ClearAllPoints()
    entry.fs:SetPoint("CENTER", fctAnchor, "CENTER", xJitter, 0)
    entry.fs:SetText(string.format(L.GOLD_FCT_GAIN, amount))
    entry.ag:Play()
end

-- ==================== Accesseurs ====================

function Overlord.Ressources:GetGold()
    return gold
end

-- Ajoute de l'or (prime de sang, etc.) en respectant le plafond.
-- opts.fct : afficher le floating combat text (defaut true).
function Overlord.Ressources:AddGold(amount, opts)
    amount = tonumber(amount) or 0
    if amount <= 0 then return 0 end
    local gained = math.min(amount, GOLD_MAX - gold)
    if gained <= 0 then return 0 end
    gold = gold + gained
    self:SaveResources()
    self:RefreshHUD()
    opts = opts or {}
    if opts.fct ~= false then
        ShowFloatingGold(gained)
    end
    return gained
end

function Overlord.Ressources:IsBarricadeActive()
    return barricadeActive
end

function Overlord.Ressources:GetMineStock(mineId)
    return mineStocks[mineId] or MINE_STOCK_MAX
end

function Overlord.Ressources:GetMineStockMax()
    return MINE_STOCK_MAX
end

-- Consomme du stock d'une mine, retourne le montant reellement consomme
local function DrainMineStock(mineId, amount)
    local stock = mineStocks[mineId] or MINE_STOCK_MAX
    if stock <= 0 then return 0 end
    local consumed = math.min(amount, stock)
    mineStocks[mineId] = stock - consumed
    if consumed > 0 then depletedMineIds[mineId] = true end
    -- Sync reseau : les autres clients n'avaient pas notre consommation (stock etait 100% local)
    if consumed > 0 and Overlord.Sync and Overlord.Sync.MaybeBroadcastMineStock then
        Overlord.Sync:MaybeBroadcastMineStock(mineId)
    end
    return consumed
end

-- Applique le stock annonce par un autre joueur (meme reserve partagee : on ne fait qu'abaisser)
function Overlord.Ressources:ApplyRemoteMineStock(mineId, remoteStock)
    if not mineId then return end
    remoteStock = tonumber(remoteStock)
    if remoteStock == nil then return end
    remoteStock = math.max(0, math.min(MINE_STOCK_MAX, math.floor(remoteStock + 0.5)))
    local cur = mineStocks[mineId] or MINE_STOCK_MAX
    if remoteStock >= cur then return end
    mineStocks[mineId] = remoteStock
    depletedMineIds[mineId] = true
    -- Pas de SaveResources() ici : c'est une mise a jour reseau frequente (chaque drain distant).
    -- La prochaine consommation ou Save planifie persistera l'etat.
    self:RefreshHUD()
    if Overlord.MapMarkers and Overlord.MapMarkers.RequestOverlayRefresh then
        Overlord.MapMarkers:RequestOverlayRefresh(true)
    end
end

-- Regenere uniquement les mines epuisees (appele chaque seconde par le ticker).
local function RegenAllMineStocks(elapsed)
    elapsed = math.max(0, tonumber(elapsed) or 1)
    for mineId in pairs(depletedMineIds) do
        local stock = mineStocks[mineId] or MINE_STOCK_MAX
        if stock < MINE_STOCK_MAX then
            local acc = (mineStockTimers[mineId] or 0) + elapsed
            if acc >= MINE_REGEN_INTERVAL then
                local recovered = math.floor(acc / MINE_REGEN_INTERVAL)
                acc = acc - recovered * MINE_REGEN_INTERVAL
                stock = math.min(MINE_STOCK_MAX, stock + recovered)
                mineStocks[mineId] = stock
            end
            mineStockTimers[mineId] = acc
            if stock >= MINE_STOCK_MAX then
                depletedMineIds[mineId] = nil
                mineStockTimers[mineId] = nil
            end
        else
            depletedMineIds[mineId] = nil
            mineStockTimers[mineId] = nil
        end
    end
end

-- ==================== Depense d'or ====================

function Overlord.Ressources:SpendReinforce()
    if gold < GOLD_SPEND_COST then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.GOLD_NOT_ENOUGH, GOLD_SPEND_COST))
        return false
    end
    if reinforceActive then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GOLD_REINFORCE_ACTIVE)
        return false
    end
    gold = gold - GOLD_SPEND_COST
    reinforceActive = true
    self:SaveResources()
    Overlord:PrintNotification("|cFFFFD700[Overlord]|r " .. L.GOLD_REINFORCE_SPENT)
    self:RefreshHUD()
    if Overlord.PlayAddonSound then Overlord:PlayAddonSound("gold_buff") end
    return true
end

function Overlord.Ressources:SpendBarricade()
    if gold < GOLD_SPEND_COST then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.GOLD_NOT_ENOUGH, GOLD_SPEND_COST))
        return false
    end
    if barricadeActive then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. L.GOLD_BARRICADE_ACTIVE)
        return false
    end
    gold = gold - GOLD_SPEND_COST
    barricadeActive = true
    self:SaveResources()
    Overlord:PrintNotification("|cFFFFD700[Overlord]|r " .. L.GOLD_BARRICADE_SPENT)
    self:RefreshHUD()
    if Overlord.PlayAddonSound then Overlord:PlayAddonSound("gold_buff") end
    return true
end

-- Consomme le bonus offensif (appele par ZoneControl:StartHoldTimer)
function Overlord.Ressources:ConsumeReinforce()
    if not reinforceActive then return 0 end
    reinforceActive = false
    self:SaveResources()
    self:RefreshHUD()
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.GOLD_REINFORCE_USED)
    return REINFORCE_REDUCTION
end

-- Applique l'attaque d'or a un contrat de capture au moment exact ou il est cree.
-- Les moteurs de zones / avant-postes / fortins appellent ce helper une seule fois :
-- aucune verification n'est ajoutee a leurs ticks ni a leurs scans de joueurs.
function Overlord.Ressources:ConsumeCaptureReduction(required, minimum)
    required = math.max(1, tonumber(required) or 1)
    minimum = math.max(1, tonumber(minimum) or REINFORCE_MIN_HOLD)
    if not reinforceActive then return required, false end
    local reduction = self:ConsumeReinforce()
    if reduction <= 0 then return required, false end
    return math.max(minimum, required - reduction), true
end

-- Consomme le bonus defensif (appele quand l'ennemi commence a capturer)
function Overlord.Ressources:ConsumeBarricade()
    if not barricadeActive then return 0 end
    barricadeActive = false
    self:SaveResources()
    self:RefreshHUD()
    Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. L.GOLD_BARRICADE_USED)
    return BARRICADE_INCREASE
end

-- ==================== Persistance ====================

function Overlord.Ressources:SaveResources()
    if not OverlordDB then return end
    -- Evite qu'un SaveState trop tot au login ecrase les SavedVariables avec l'etat local initial (0).
    if not resourcesRestored then return end
    OverlordDB.gold = gold
    OverlordDB.goldReinforceActive = reinforceActive
    OverlordDB.goldBarricadeActive = barricadeActive
    -- Copie shallow : decouple l'etat runtime des SavedVariables
    local stocks = {}
    for k, v in pairs(mineStocks) do stocks[k] = v end
    OverlordDB.mineStocks = stocks
    local timers = {}
    for k, v in pairs(mineStockTimers) do timers[k] = v end
    OverlordDB.mineStockTimers = timers
    -- Systeme de bois retire (1.2.0) : purge des anciennes cles.
    OverlordDB.wood, OverlordDB.woodStocks, OverlordDB.woodStockTimers = nil, nil, nil
end

function Overlord.Ressources:RestoreResources()
    if not OverlordDB then return end
    gold = tonumber(OverlordDB.gold) or 0
    gold = math.max(0, math.min(GOLD_MAX, gold))
    reinforceActive = OverlordDB.goldReinforceActive or false
    barricadeActive = OverlordDB.goldBarricadeActive or false
    if OverlordDB.mineStocks then
        -- Migration id mine Elwynn : fargodeep (faux nom) -> jasperlode.
        if OverlordDB.mineStocks.fargodeep ~= nil and OverlordDB.mineStocks.jasperlode == nil then
            OverlordDB.mineStocks.jasperlode = OverlordDB.mineStocks.fargodeep
        end
        OverlordDB.mineStocks.fargodeep = nil
        for k, v in pairs(OverlordDB.mineStocks) do
            mineStocks[k] = math.max(0, math.min(MINE_STOCK_MAX, tonumber(v) or MINE_STOCK_MAX))
            if mineStocks[k] < MINE_STOCK_MAX then depletedMineIds[k] = true end
        end
    end
    if OverlordDB.mineStockTimers then
        if OverlordDB.mineStockTimers.fargodeep ~= nil and OverlordDB.mineStockTimers.jasperlode == nil then
            OverlordDB.mineStockTimers.jasperlode = OverlordDB.mineStockTimers.fargodeep
        end
        OverlordDB.mineStockTimers.fargodeep = nil
        for k, v in pairs(OverlordDB.mineStockTimers) do
            mineStockTimers[k] = math.max(0, math.min(MINE_REGEN_INTERVAL - 1, tonumber(v) or 0))
        end
    end
    resourcesRestored = true
end

function Overlord.Ressources:ResetResources()
    resourcesRestored = true
    gold = 0
    reinforceActive = false
    barricadeActive = false
    mineStocks = {}
    mineStockTimers = {}
    depletedMineIds = {}
    self:SaveResources()
end

-- ==================== Detection de minage actif (vrai node) ====================
-- Listener UNIT_SPELLCAST_SUCCEEDED : si le joueur mine un vrai node dans un cercle mine,
-- bonus +5 or. Detection par spellID (independant de la langue du client).

-- SpellIDs de minage connus (couvre toutes les expansions)
local MINING_SPELL_IDS = {
    [2575]   = true,  -- Mining (rank 1)
    [2576]   = true,  -- Mining (rank 2)
    [3564]   = true,  -- Mining (rank 3)
    [10248]  = true,  -- Mining (rank 4)
    [29354]  = true,  -- Mining (rank 5)
    [32606]  = true,  -- Mining (rank 6)
    [195122] = true,  -- Mining (Legion+)
    [366260] = true,  -- Mining (Dragonflight)
    [423393] = true,  -- Mining (TWW)
}

local function OnSpellcastSucceeded(_, _, unit, _, spellID)
    -- No mine in an instance; never index a table with a 12.x secret spell ID.
    if Overlord.InstanceSuspended then return end
    if issecretvalue and (issecretvalue(unit) or issecretvalue(spellID)) then return end
    if unit ~= "player" then return end
    if not MINING_SPELL_IDS[spellID] then return end
    if gold >= GOLD_MAX then return end
    if not Overlord.Zones then return end

    local mine = Overlord.Zones:GetCurrentPlayerMine()
    if not mine then return end

    -- Verifie le stock de la mine
    local available = DrainMineStock(mine.id, GOLD_NODE_BONUS)
    if available <= 0 then return end

    local gained = math.min(available, GOLD_MAX - gold)
    gold = gold + gained
    Overlord.Ressources:SaveResources()
    Overlord.Ressources:RefreshHUD()
    ShowFloatingGold(gained)
    Overlord:PrintNotification("|cFFFFD700[Overlord]|r " .. string.format(L.GOLD_NODE_BONUS, gained))
end

-- ==================== Ticker de minage passif ====================
-- Accumule 1 or toutes les GOLD_PASSIVE_INTERVAL secondes dans un cercle mine.
-- Conditions : War Mode actif, pas monte/vol/furtif/mort.

-- Spell ID du buff druide Mount Form (cerf montable, vitesse sol)
local DRUID_MOUNT_FORM_SPELL_ID = 210053

-- La classe du joueur ne change jamais en session : calcule une seule fois plutot qu'a chaque
-- appel (ticker de minage, ~1 Hz sur front actif) pour ne pas interroger AuraUtil/GetShapeshiftFormID
-- (formes de voyage druide) pour les 90%+ de joueurs non-druides.
local playerIsDruid = select(2, UnitClass("player")) == "DRUID"

local function IsPlayerInNonMiningState()
    -- Les memes etats que la capture bloquent la recolte. Ce helper partage le
    -- cache local et les gardes d'auras 12.x ; AuraUtil.FindAuraBySpellID n'existe
    -- plus en Retail et laissait passer les formes de voyage / Lorewalking.
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonCaptureStateForSync then
        return Overlord.ZoneControl:IsPlayerInNonCaptureStateForSync()
    end
    if UnitInVehicle and UnitInVehicle("player") then return true end
    if UnitOnTaxi and UnitOnTaxi("player") then return true end
    if IsMounted and IsMounted() then return true end
    if IsFlying and IsFlying() then return true end
    if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
        local ok, isGliding = pcall(C_PlayerInfo.GetGlidingInfo)
        if ok and isGliding then return true end
    end
    if playerIsDruid then
        -- Druide Travel Form en vol : bloque le minage (coherence avec la capture)
        -- Methode 1 : verification par formID (27 = Travel Form, 29 = Flight Form) + zone volable
        if GetShapeshiftFormID and IsFlyableArea then
            local formID = GetShapeshiftFormID()
            if formID and (formID == 27 or formID == 29) and IsFlyableArea() then return true end
        end
        -- Buff druide Mount Form au sol (IsFlying() a deja ete verifie plus haut ; Travel Form en
        -- vol declenche toujours IsFlying donc deja couvert, pas besoin de re-tester ici).
        if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
            local ok, present = pcall(function()
                if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret
                    and C_Secrets.ShouldSpellAuraBeSecret(DRUID_MOUNT_FORM_SPELL_ID) then
                    return false
                end
                local aura = C_UnitAuras.GetPlayerAuraBySpellID(DRUID_MOUNT_FORM_SPELL_ID)
                if canaccessvalue and not canaccessvalue(aura) then return false end
                return aura ~= nil
            end)
            if ok and present then return true end
        end
    end
    if IsStealthed and IsStealthed() then return true end
    if UnitIsDead("player") or UnitIsGhost("player") then return true end
    return false
end

local function ClearResourceCircleState()
    mineVisitForMn = nil
    if currentMineId then
        local prevMine = Overlord.Zones:GetMine(currentMineId)
        if prevMine then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.MINE_LEFT, prevMine.name))
        end
        currentMineId = nil
        mineAccumulator = 0
    end
end

local function MineTickerFunc(elapsed)
    if not Overlord.Zones then return end
    elapsed = math.max(0, tonumber(elapsed) or 1)
    -- Regeneration des stocks des mines (meme si le joueur n'est pas dedans)
    RegenAllMineStocks(elapsed)

    -- Hors carte mine, aucun scan de position, War Mode, aura ou monture.
    -- Les changements de zone continuent de rafraichir le HUD via resFrame.
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or not mapID or not Overlord.Zones:IsResourceMapContext(mapID) then
        resourceTickerFast = false
        ClearResourceCircleState()
        return
    end
    resourceTickerFast = true

    -- Demontage auto dans le cercle mine : actif meme sans WM (le reste du ticker exige le WM).
    local mineForDismount = Overlord.Zones:GetCurrentPlayerMine()
    if Overlord.ZoneControl and Overlord.ZoneControl.TickAutoDismountMineCircle then
        Overlord.ZoneControl:TickAutoDismountMineCircle(elapsed, mineForDismount)
    end

    -- Forever : pas de Warmode. L'or passif et le HUD mine restent actifs en monde ouvert.

    -- Sortie du cercle : a evaluer AVANT IsPlayerInNonMiningState.
    -- Sinon en monture / furtif / vol on return sans jamais appeler GetCurrentPlayerMine :
    -- currentMineId reste fige jusqu'a ce que l'etat minable revienne (ex. capturer a pied).
    local mineNow = Overlord.Zones:GetCurrentPlayerMine()
    if not mineNow then
        mineVisitForMn = nil
    end
    if currentMineId then
        if not mineNow or mineNow.id ~= currentMineId then
            local prevMine = Overlord.Zones:GetMine(currentMineId)
            if prevMine then
                Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.MINE_LEFT, prevMine.name))
            end
            currentMineId = nil
            mineAccumulator = 0
        end
    end
    if IsPlayerInNonMiningState() then return end

    local mine = mineNow

    if mine then
        -- Entree dans la mine
        if currentMineId ~= mine.id then
            if currentMineId then
                local prevMine = Overlord.Zones:GetMine(currentMineId)
                if prevMine then
                    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.MINE_LEFT, prevMine.name))
                end
            end
            currentMineId = mine.id
            mineAccumulator = 0
            Overlord:PrintNotification("|cFF00FF00[Overlord]|r " .. string.format(L.MINE_ENTERED, mine.name))
        end

        -- Alerte MN (mode guerre deja verifie plus haut) : immediate a l'entree, puis cooldown
        local now = GetTime()
        if mineVisitForMn ~= mine.id then
            mineVisitForMn = mine.id
            lastMineAlert[mine.id] = now
            if Overlord.Sync and Overlord.Sync.BroadcastMining then
                Overlord.Sync:BroadcastMining(mine.id)
            end
        else
            local lastAlert = lastMineAlert[mine.id] or 0
            if now - lastAlert >= MINE_ALERT_COOLDOWN then
                lastMineAlert[mine.id] = now
                if Overlord.Sync and Overlord.Sync.BroadcastMining then
                    Overlord.Sync:BroadcastMining(mine.id)
                end
            end
        end

        -- Accumulation passive (consomme le stock de la mine)
        if gold < GOLD_MAX then
            local stock = mineStocks[mine.id] or MINE_STOCK_MAX
            if stock <= 0 then
                -- Mine epuisee : notifie une seule fois a l'entree ou quand elle se vide
                if not mine._depletedNotified then
                    mine._depletedNotified = true
                    Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. string.format(L.MINE_DEPLETED, mine.name))
                end
            else
                mine._depletedNotified = nil
            mineAccumulator = mineAccumulator + elapsed
                if mineAccumulator >= GOLD_PASSIVE_INTERVAL then
                    mineAccumulator = 0
                    local available = DrainMineStock(mine.id, GOLD_PASSIVE_AMOUNT)
                    if available > 0 then
                        local gained = math.min(available, GOLD_MAX - gold)
                        gold = gold + gained
                        Overlord.Ressources:SaveResources()
                        Overlord.Ressources:RefreshHUD()
                        ShowFloatingGold(gained)
                        if gold >= GOLD_MAX then
                            Overlord:PrintNotification("|cFFFFD700[Overlord]|r " .. L.GOLD_FULL)
                        end
                    end
                end
            end
        end
    end
    -- Sortie deja traitee plus haut (mineNow vs currentMineId) pour couvrir monture/furtif.
end

-- ==================== Cadre autonome WC3 (haut de l'ecran, centre) ====================

local goldHUD = nil
local guildKeepHUD = nil
local goldHudRoot = nil
local hudTutorialPanel = nil
local HUD_STACK_GAP = 6
local HUD_PANEL_WIDTH = 280
local TUTORIAL_PANEL_W = 52
-- Livre ouvert : aide / guide (texture client vanilla, toujours presente)
local TUTORIAL_ICON = "Interface\\Icons\\INV_Misc_Book_09"

-- Theme et chrome partages : panneau or, barre tutoriel, indicateur de zone.
-- Cache par faction : la faction du joueur ne change jamais en session (hors service de
-- changement de faction, qui force un relog) ; ApplyTopHudChrome est appele a chaque refresh HUD
-- (jusqu'a plusieurs fois/s), une allocation de table + sous-tables a chaque appel est evitable.
local topHudThemeCache = {}

function Overlord.Ressources:GetTopHudTheme()
    local isHorde = (Overlord.PlayerFaction == "Horde")
    local cacheKey = isHorde and "Horde" or "Alliance"
    local cached = topHudThemeCache[cacheKey]
    if cached then return cached end

    local borderR, borderG, borderB = 0.85, 0.68, 0.20
    local bgR, bgG, bgB = 0.10, 0.10, 0.16
    local accentR, accentG, accentB = 1, 0.82, 0
    local activeGreen = { 0.29, 0.87, 0.50 }
    local activeBlue = { 0.43, 0.70, 0.95 }
    local dimGray = { 0.50, 0.48, 0.46 }
    if isHorde then
        borderR, borderG, borderB = 0.82, 0.22, 0.12
        bgR, bgG, bgB = 0.14, 0.08, 0.06
        accentR, accentG, accentB = 0.82, 0.22, 0.12
        activeGreen = { 0.80, 0.55, 0.10 }
        activeBlue = { 1.0, 0.40, 0.27 }
    end
    local theme = {
        borderR = borderR, borderG = borderG, borderB = borderB,
        bgR = bgR, bgG = bgG, bgB = bgB,
        accentR = accentR, accentG = accentG, accentB = accentB,
        activeGreen = activeGreen, activeBlue = activeBlue, dimGray = dimGray,
    }
    topHudThemeCache[cacheKey] = theme
    return theme
end

local topHudBackdropCache = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 20,
    insets = { left = 5, right = 5, top = 5, bottom = 5 },
}

function Overlord.Ressources:GetTopHudBackdrop()
    return topHudBackdropCache
end

function Overlord.Ressources:ApplyTopHudChrome(frame, borderAlpha)
    local theme = self:GetTopHudTheme()
    frame:SetBackdrop(self:GetTopHudBackdrop())
    frame:SetBackdropColor(theme.bgR, theme.bgG, theme.bgB, 0.92)
    frame:SetBackdropBorderColor(theme.borderR, theme.borderG, theme.borderB, borderAlpha or 0.9)
end

function Overlord.Ressources:GetHudPanelWidth()
    return HUD_PANEL_WIDTH
end

-- Ancre sous laquelle empiler l'indicateur de zone (cluster tutoriel + ressources + fortin).
function Overlord.Ressources:GetGoldHUDStackBottom()
    -- Un enfant peut rester IsShown() alors que son parent est masque.
    -- Seul le cluster visible doit servir d'ancre ; sinon l'indicateur se recentre.
    if goldHudRoot and goldHudRoot:IsVisible() then return goldHudRoot end
    return nil
end

-- Zones mines hors front (Hillsbrad / Silverpine).
-- Cartes Overlord ou les kills PvP doivent compter au classement (aligne HUD ressources).
function Overlord.Ressources:IsOverlordKillZoneMap(mapID)
    if not mapID then return false end
    if Overlord.Zones and Overlord.Zones:IsWarFrontMapID(mapID) then return true end
    if Overlord.Zones and Overlord.Zones.IsMineMapID and Overlord.Zones:IsMineMapID(mapID) then
        return true
    end
    if Overlord.GuildKeep and Overlord.GuildKeep:ResolveSiteByMapID(mapID) then return true end
    return false
end

function Overlord.Ressources:IsInOverlordKillZone()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return false end
    local gk = Overlord.GuildKeep
    if gk and gk.ResolveSiteByMapID then
        local site = gk:ResolveSiteByMapID(mapID)
        if site then
            if not gk.IsPlayerInKeepGeometry or not gk:IsPlayerInKeepGeometry(site) then return false end
            return true
        end
    end
    if Overlord.Zones and Overlord.Zones:IsWarFrontMapID(mapID) then return true end
    if Overlord.Zones and Overlord.Zones.IsMineMapID and Overlord.Zones:IsMineMapID(mapID) then
        return true
    end
    return false
end

local function IsResourceHudZone(mapID, instanceAlreadyChecked)
    if not mapID then
        local ok
        ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if not ok or not mapID then return false end
    end
    if not instanceAlreadyChecked then
        if Overlord.InstanceSuspended then return false end
        if IsInInstance() then return false end
        local okInst, _, instType = pcall(GetInstanceInfo)
        if okInst and instType and instType ~= "none" and instType ~= "" then
            return false
        end
    end
    -- L'avant-poste de l'Ile Annelee existe sans front actif. Son HUD d'or
    -- suit sa carte exterieure et les memes gardes que sa capture.
    local outpost = Overlord.Outpost
    if outpost and outpost.ResolveSiteByMapID and outpost.IsGameplayContextActive then
        local site = outpost:ResolveSiteByMapID(mapID)
        if site and site.standaloneOpenWorld and outpost:IsGameplayContextActive(site) then
            return true
        end
    end
    if Overlord.Ressources and Overlord.Ressources.IsOverlordKillZoneMap then
        return Overlord.Ressources:IsOverlordKillZoneMap(mapID)
    end
    return false
end

-- Fortin icone HUD (carte / selection).
local function GetHudKeepContext()
    if not Overlord.GuildKeep then return nil, nil end
    return Overlord.GuildKeep:GetHudSite()
end

-- Couleurs faction menus / HUD (meme hex que Popups FormatFactionColoredName).
local function FormatKeepTenantColorCode(faction)
    if faction == "Alliance" then return "|cFF4488FF" end
    if faction == "Horde" then return "|cFFFF4444" end
    return "|cFFFFFFFF"
end

function Overlord.Ressources:ShouldShowGuildKeepHUD(mapID, resourceZoneKnown)
    if not Overlord.GuildKeep or Overlord.InstanceSuspended then return false end
    if resourceZoneKnown == false then return false end
    if resourceZoneKnown == nil and not IsResourceHudZone(mapID) then return false end
    local _, site = GetHudKeepContext()
    return site ~= nil
end

local function GetKeepHudWarfrontAtlas(st, mapID, site)
    if not Overlord.GuildKeep then
        return "Warfronts-BaseMapIcons-Empty-MainHall"
    end
    return Overlord.GuildKeep:GetKeepMapIconAtlas(st, site, mapID)
end

local function NotifyHudStackLayout()
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RepositionInStack then
        Overlord.ZoneIndicator:RepositionInStack()
    end
end

-- Position du cluster haut : totalement libre (point/ancre/x/y tels quels apres un drag).
-- goldHudRoot reste toujours ancre a UIParent (jamais a un autre frame Overlord), donc
-- GetPoint() apres StopMovingOrSizing() renvoie directement une position exploitable.
-- LayoutHudTopRow (rejoue toutes les ~2s par HUDZoneCheck) ne doit jamais reancrer
-- goldHudRoot, sinon un relayout en pleine manipulation coupait le drag ("il se remet tout
-- seul en haut").
local function SaveGoldHudPosition()
    if not goldHudRoot or not OverlordDB then return end
    local point, _, relPoint, x, y = goldHudRoot:GetPoint(1)
    if not point then return end
    OverlordDB.goldHUDPos = { point = point, relPoint = relPoint or "TOP", x = x or 0, y = y or -4 }
end

local function OnTopHudClusterDragStop()
    if not goldHudRoot then return end
    goldHudRoot:StopMovingOrSizing()
    SaveGoldHudPosition()
    NotifyHudStackLayout()
end

-- Reancre les panneaux du cluster haut.
local lastHudTopLayoutKey = nil
local function LayoutHudTopRow(showKeep, showGold, showTutorial)
    if not goldHudRoot or not goldHUD or not hudTutorialPanel then return end
    local clusterH = 62
    if showTutorial == nil then showTutorial = true end
    local layoutKey = (showKeep and "1" or "0")
        .. (showGold and "1" or "0")
        .. (showTutorial and "1" or "0")
    if layoutKey == lastHudTopLayoutKey
        and goldHudRoot._hudLayoutW and goldHudRoot:GetWidth() == goldHudRoot._hudLayoutW then
        return
    end
    lastHudTopLayoutKey = layoutKey

    if showTutorial then
        hudTutorialPanel:ClearAllPoints()
        hudTutorialPanel:SetPoint("TOPLEFT", goldHudRoot, "TOPLEFT", 0, 0)
        hudTutorialPanel:Show()
    else
        hudTutorialPanel:Hide()
    end

    if guildKeepHUD then guildKeepHUD:Hide() end

    local anchor = showTutorial and hudTutorialPanel or goldHudRoot
    local fromPoint = showTutorial and "TOPRIGHT" or "TOPLEFT"

    goldHUD:ClearAllPoints()
    if showGold then
        goldHUD:SetPoint("TOPLEFT", anchor, fromPoint, showTutorial and HUD_STACK_GAP or 0, 0)
        goldHUD:Show()
        anchor = goldHUD
        fromPoint = "TOPRIGHT"
    else
        goldHUD:Hide()
    end


    if showKeep and guildKeepHUD then
        guildKeepHUD:ClearAllPoints()
        local gap = (anchor == goldHudRoot) and 0 or HUD_STACK_GAP
        guildKeepHUD:SetPoint("TOPLEFT", anchor, fromPoint, gap, 0)
        guildKeepHUD:Show()
    end

    local totalW = 0
    if showTutorial then
        totalW = TUTORIAL_PANEL_W
    end
    if showGold then
        if totalW > 0 then totalW = totalW + HUD_STACK_GAP end
        totalW = totalW + HUD_PANEL_WIDTH
    end
    if showKeep and guildKeepHUD and guildKeepHUD:IsShown() then
        if totalW > 0 then totalW = totalW + HUD_STACK_GAP end
        totalW = totalW + TUTORIAL_PANEL_W
    end
    if totalW < 1 then totalW = TUTORIAL_PANEL_W end
    goldHudRoot:SetSize(totalW, clusterH)
    goldHudRoot._hudLayoutW = totalW
    -- Ne jamais reancrer goldHudRoot ici : ce relayout tourne toutes les ~2s (HUDZoneCheck),
    -- y compris pendant un drag en cours ("il se remet tout seul en haut"). L'ancre TOP
    -- existante centre deja la largeur autour du point fixe ; un SetSize seul suffit.
    NotifyHudStackLayout()
end

local function HideTopHudManually()
    if OverlordDB then OverlordDB.goldHUDHidden = true end
    if goldHudRoot then goldHudRoot:Hide() end
end

local function CreateGoldHUD()
    if goldHUD then return end

    local theme = Overlord.Ressources:GetTopHudTheme()
    local borderR, borderG, borderB = theme.borderR, theme.borderG, theme.borderB
    local accentR, accentG, accentB = theme.accentR, theme.accentG, theme.accentB
    local activeGreen, activeBlue, dimGray = theme.activeGreen, theme.activeBlue, theme.dimGray

    local clusterH = 62
    goldHudRoot = CreateFrame("Frame", "OverlordGoldHudRoot", UIParent)
    goldHudRoot:SetSize(HUD_PANEL_WIDTH * 2 + TUTORIAL_PANEL_W + HUD_STACK_GAP * 2, clusterH)
    goldHudRoot:SetPoint("TOP", UIParent, "TOP", 0, -4)
    goldHudRoot:SetFrameStrata("HIGH")
    goldHudRoot:EnableMouse(true)
    goldHudRoot:SetMovable(true)
    goldHudRoot:RegisterForDrag("LeftButton", "RightButton")
    goldHudRoot:SetScript("OnDragStart", function(self) self:StartMoving() end)
    goldHudRoot:SetScript("OnDragStop", function(self)
        OnTopHudClusterDragStop()
    end)
    goldHudRoot:SetClampedToScreen(true)

    -- Bloc tutoriel (gauche) : icone livre seule, tooltip au survol
    local tutorialPanel = CreateFrame("Button", nil, goldHudRoot, "BackdropTemplate")
    hudTutorialPanel = tutorialPanel
    tutorialPanel:SetSize(TUTORIAL_PANEL_W, clusterH)
    tutorialPanel:SetPoint("TOPLEFT", goldHudRoot, "TOPLEFT", 0, 0)
    Overlord.Ressources:ApplyTopHudChrome(tutorialPanel, 0.9)
    local tutorialGlow = tutorialPanel:CreateTexture(nil, "HIGHLIGHT")
    tutorialGlow:SetAllPoints()
    tutorialGlow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    tutorialGlow:SetTexCoord(0, 0.625, 0, 0.6875)
    tutorialGlow:SetBlendMode("ADD")
    tutorialGlow:SetAlpha(0.12)
    local tutorialIcon = tutorialPanel:CreateTexture(nil, "ARTWORK")
    tutorialIcon:SetSize(40, 40)
    tutorialIcon:SetPoint("CENTER", tutorialPanel, "CENTER", 0, 0)
    tutorialIcon:SetTexture(TUTORIAL_ICON)
    tutorialIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tutorialPanel.icon = tutorialIcon
    tutorialPanel:SetScript("OnClick", function()
        if Overlord.Popups then Overlord.Popups:ShowQuickGuide() end
    end)
    tutorialPanel:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.GUIDE_BAR_LABEL or "Tutorial", 1, 0.82, 0.2)
        GameTooltip:AddLine(L.GUIDE_BTN_TOOLTIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tutorialPanel:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tutorialPanel:RegisterForDrag("LeftButton", "RightButton")
    tutorialPanel:SetScript("OnDragStart", function() goldHudRoot:StartMoving() end)
    tutorialPanel:SetScript("OnDragStop", OnTopHudClusterDragStop)

    -- --- Bloc Guild Keep (meme taille que le tutoriel) ---
    guildKeepHUD = CreateFrame("Frame", "OverlordGuildKeepHUD", goldHudRoot, "BackdropTemplate")
    guildKeepHUD:SetSize(TUTORIAL_PANEL_W, clusterH)
    guildKeepHUD:SetPoint("TOPLEFT", tutorialPanel, "TOPRIGHT", HUD_STACK_GAP, 0)
    -- Position finale : geree par LayoutHudTopRow
    Overlord.Ressources:ApplyTopHudChrome(guildKeepHUD, 0.9)
    guildKeepHUD:EnableMouse(true)
    guildKeepHUD:RegisterForDrag("LeftButton", "RightButton")
    guildKeepHUD:SetScript("OnDragStart", function() goldHudRoot:StartMoving() end)
    guildKeepHUD:SetScript("OnDragStop", OnTopHudClusterDragStop)

    local gkIcon = guildKeepHUD:CreateTexture(nil, "ARTWORK")
    gkIcon:SetSize(34, 34)
    gkIcon:SetPoint("TOP", guildKeepHUD, "TOP", 0, -5)
    guildKeepHUD.icon = gkIcon

    local gkGuild = guildKeepHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gkGuild:SetPoint("TOP", gkIcon, "BOTTOM", 0, -1)
    gkGuild:SetWidth(TUTORIAL_PANEL_W - 6)
    gkGuild:SetJustifyH("CENTER")
    gkGuild:SetMaxLines(1)
    guildKeepHUD.guildLabel = gkGuild

    local gkActivity = guildKeepHUD:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gkActivity:SetPoint("BOTTOM", guildKeepHUD, "BOTTOM", 0, 3)
    gkActivity:SetWidth(TUTORIAL_PANEL_W - 4)
    gkActivity:SetJustifyH("CENTER")
    gkActivity:SetMaxLines(1)
    gkActivity:Hide()
    guildKeepHUD.activityLabel = gkActivity

    -- Fleches jaunes gauche/droite (texture flyout Blizzard, comme portails mage)
    local function CreateKeepFlyoutArrow(side)
        local tex = guildKeepHUD:CreateTexture(nil, "OVERLAY")
        tex:SetSize(11, 11)
        if side == "LEFT" then
            tex:SetPoint("LEFT", guildKeepHUD, "LEFT", 0, 0)
        else
            tex:SetPoint("RIGHT", guildKeepHUD, "RIGHT", 0, 0)
        end
        Overlord.UI.ApplyFlyoutArrowStyle(tex, side, Overlord.UI.GetBlizzardFlyoutArrowSource())
        return tex
    end
    guildKeepHUD.dropArrowLeft = CreateKeepFlyoutArrow("LEFT")
    guildKeepHUD.dropArrowRight = CreateKeepFlyoutArrow("RIGHT")
    -- Barre d'action parfois pas encore chargee a l'init du HUD
    C_Timer.After(0, function()
        if not guildKeepHUD or not guildKeepHUD.dropArrowLeft then return end
        local src = Overlord.UI.GetBlizzardFlyoutArrowSource()
        if not src then return end
        Overlord.UI.ApplyFlyoutArrowStyle(guildKeepHUD.dropArrowLeft, "LEFT", src)
        Overlord.UI.ApplyFlyoutArrowStyle(guildKeepHUD.dropArrowRight, "RIGHT", src)
    end)

    -- Selecteur de fortin (dropdown au clic sur l'icone, inhibe si drag)
    local gkDragActive = false
    guildKeepHUD:HookScript("OnDragStart", function() gkDragActive = true end)
    guildKeepHUD:HookScript("OnDragStop", function() gkDragActive = false end)

    local keepSelectMenu = CreateFrame("Frame", "OverlordKeepSelectMenu", UIParent, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(keepSelectMenu, function(frame, level)
        if not Overlord.GuildKeep or not Overlord.GuildKeep.GetSortedSiteList then return end
        local sites = Overlord.GuildKeep:GetSortedSiteList()
        local currentKey = Overlord.GuildKeep:GetSelectedKeepSiteKey()
        for _, site in ipairs(sites) do
            local st = Overlord.GuildKeep:GetState(site.siteKey)
            local name = Overlord.GuildKeep:GetDisplayName(site)
            local statusTag = ""
            if st.status == "held" then
                local dg, df = Overlord.GuildKeep:GetKeepDisplayTenant(st, site and site.siteKey)
                if dg ~= "" then
                    statusTag = "  " .. FormatKeepTenantColorCode(df) .. dg .. "|r"
                end
            elseif st.status == "in_progress" and Overlord.GuildKeep.IsKeepCaptureInProgress
                and Overlord.GuildKeep:IsKeepCaptureInProgress(st) then
                statusTag = "  |cFFFF8800...|r"
            end
            local info = UIDropDownMenu_CreateInfo()
            info.text = name .. statusTag
            info.checked = (currentKey ~= nil and site.siteKey == currentKey)
            info.func = function()
                Overlord.GuildKeep:SetSelectedKeepSite(site.siteKey)
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
        -- Option Auto
        local autoInfo = UIDropDownMenu_CreateInfo()
        autoInfo.text = (L.GUILD_KEEP_SELECT_AUTO or "Auto")
        autoInfo.checked = (currentKey == nil)
        autoInfo.func = function()
            Overlord.GuildKeep:SetSelectedKeepSite(nil)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(autoInfo, level)
    end, "MENU")

    guildKeepHUD:SetScript("OnMouseUp", function(self, btn)
        if gkDragActive then gkDragActive = false return end
        if btn ~= "LeftButton" and btn ~= "RightButton" then return end
        if not Overlord.GuildKeep or not Overlord.GuildKeep.GetSortedSiteList then return end
        local sites = Overlord.GuildKeep:GetSortedSiteList()
        if #sites < 2 then return end
        GameTooltip:Hide()
        ToggleDropDownMenu(1, nil, keepSelectMenu, "cursor", 0, 0)
    end)

    guildKeepHUD:SetScript("OnEnter", function(self)
        if not Overlord.GuildKeep then return end
        local st, site = GetHudKeepContext()
        if not st or not site then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local t = TT()
        GameTooltip:AddLine(Overlord.GuildKeep:GetDisplayName(site), t.HL[1], t.HL[2], t.HL[3])
        local dg = select(1, Overlord.GuildKeep:GetKeepDisplayTenant(st, site and site.siteKey))
        local siegeActive = Overlord.GuildKeep.IsKeepCaptureInProgress
            and Overlord.GuildKeep:IsKeepCaptureInProgress(st, site.siteKey)
        if siegeActive then
            local siegeLabel = Overlord.GuildKeep.GetKeepCaptureMapLabel
                and Overlord.GuildKeep:GetKeepCaptureMapLabel(st, site and site.siteKey)
                or (L.GUILD_KEEP_CAPTURING or "Capturing...")
            GameTooltip:AddLine(siegeLabel, 1, 0.55, 0.2)
        elseif dg ~= "" then
            GameTooltip:AddLine(string.format(L.GUILD_KEEP_PANEL_HELD or "%s", dg),
                t.BODY[1], t.BODY[2], t.BODY[3])
        else
            GameTooltip:AddLine(L.GUILD_KEEP_NEUTRAL or "Unclaimed", t.BODY[1], t.BODY[2], t.BODY[3])
            if Overlord.GuildKeep.IsKeepNeutralForDisplay
                and Overlord.GuildKeep:IsKeepNeutralForDisplay(st, site and site.siteKey) then
                local hint = Overlord.GuildKeep:GetKeepCaptureAvailableHint()
                if hint and hint ~= "" then
                    GameTooltip:AddLine(hint, t.MUTED[1], t.MUTED[2], t.MUTED[3])
                end
            end
        end
        -- Hint selecteur si plus d'un fortin
        local sites = Overlord.GuildKeep.GetSortedSiteList and Overlord.GuildKeep:GetSortedSiteList()
        if sites and #sites > 1 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L.GUILD_KEEP_SELECT_TITLE or "Select Keep", t.MUTED[1], t.MUTED[2], t.MUTED[3])
        end
        GameTooltip:Show()
    end)
    guildKeepHUD:SetScript("OnLeave", function() GameTooltip:Hide() end)
    guildKeepHUD:Hide()

    -- --- Panneau or ---
    goldHUD = CreateFrame("Frame", "OverlordGoldHUD", goldHudRoot, "BackdropTemplate")
    goldHUD:SetSize(HUD_PANEL_WIDTH, clusterH)
    goldHUD:SetPoint("TOPLEFT", tutorialPanel, "TOPRIGHT", HUD_STACK_GAP, 0)
    Overlord.Ressources:ApplyTopHudChrome(goldHUD, 0.9)
    goldHUD:EnableMouse(true)
    goldHUD:RegisterForDrag("LeftButton", "RightButton")
    goldHUD:SetScript("OnDragStart", function() goldHudRoot:StartMoving() end)
    goldHUD:SetScript("OnDragStop", OnTopHudClusterDragStop)
    goldHUD.tutorialPanel = tutorialPanel

    -- --- Ligne 1 : icone monnaie WoW (sac) - inchangée, nette a cette taille
    local coinIcon = goldHUD:CreateTexture(nil, "ARTWORK", nil, 1)
    coinIcon:SetSize(16, 16)
    coinIcon:SetPoint("TOP", goldHUD, "TOP", -36, -8)
    coinIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    goldHUD.coinIcon = coinIcon

    local goldText = goldHUD:CreateFontString(nil, "OVERLAY")
    goldText:SetFont(Overlord.UI.ResolveLocalizedFontPath(GameFontNormal, "Fonts\\MORPHEUS.TTF"), 14)
    goldText:SetPoint("LEFT", coinIcon, "RIGHT", 5, 0)
    goldText:SetTextColor(1, 0.85, 0.3)
    goldText:SetShadowOffset(1, -1)
    goldHUD.goldText = goldText

    -- Zone souris piece + compteur : tooltip (sans bloquer le drag sur le reste du cadre)
    local goldHeaderHit = CreateFrame("Frame", nil, goldHUD)
    goldHeaderHit:SetSize(210, 22)
    goldHeaderHit:SetPoint("TOP", goldHUD, "TOP", 0, -6)
    goldHeaderHit:EnableMouse(true)
    goldHeaderHit:SetFrameLevel(goldHUD:GetFrameLevel() + 2)
    -- Permet le drag meme sur cette zone (passe les events au parent)
    goldHeaderHit:RegisterForDrag("LeftButton", "RightButton")
    goldHeaderHit:SetScript("OnDragStart", function() goldHudRoot:StartMoving() end)
    goldHeaderHit:SetScript("OnDragStop", OnTopHudClusterDragStop)
    goldHeaderHit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        local t = TT()
        GameTooltip:AddLine(L.GOLD_LABEL, t.HL[1], t.HL[2], t.HL[3])
        if L.GOLD_HEADER_TIP then
            GameTooltip:AddLine(L.GOLD_HEADER_TIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
        end
        GameTooltip:Show()
    end)
    goldHeaderHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    goldHUD.goldHeaderHit = goldHeaderHit

    -- --- Barre de progression fine (centree dans le cadre) ---
    local barBg = CreateFrame("Frame", nil, goldHUD)
    barBg:SetSize(250, 3)
    barBg:SetPoint("CENTER", goldHUD, "CENTER", 0, 2)
    local barBgTex = barBg:CreateTexture(nil, "BACKGROUND")
    barBgTex:SetAllPoints()
    barBgTex:SetColorTexture(0.15, 0.12, 0.10, 0.8)

    local barFill = barBg:CreateTexture(nil, "ARTWORK")
    barFill:SetPoint("TOPLEFT")
    barFill:SetPoint("BOTTOMLEFT")
    barFill:SetWidth(1)
    barFill:SetColorTexture(accentR, accentG, accentB, 0.85)
    goldHUD.barBg = barBg
    goldHUD.barFill = barFill

    -- --- Ligne 2 : boutons Barricade (gauche) et Renfort (droite) ---
    local btnW, btnH = 120, 20

    -- Bouton Barricade (defensif) - gauche
    local barricadeBtn = CreateFrame("Button", nil, goldHUD, "BackdropTemplate")
    barricadeBtn:SetSize(btnW, btnH)
    barricadeBtn:SetPoint("BOTTOMLEFT", goldHUD, "BOTTOMLEFT", 10, 7)
    barricadeBtn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    barricadeBtn:SetBackdropColor(0.12, 0.12, 0.18, 0.9)
    barricadeBtn:SetBackdropBorderColor(borderR, borderG, borderB, 0.5)

    -- Conteneur centre pour icone + texte
    local bContent = CreateFrame("Frame", nil, barricadeBtn)
    bContent:SetPoint("CENTER", barricadeBtn, "CENTER", 0, 0)

    local bIcon = bContent:CreateTexture(nil, "ARTWORK")
    bIcon:SetSize(14, 14)
    bIcon:SetPoint("LEFT", bContent, "LEFT", 0, 0)
    bIcon:SetTexture("Interface\\Icons\\Ability_Defend")
    bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local bLabel = bContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bLabel:SetPoint("LEFT", bIcon, "RIGHT", 3, 0)
    bLabel:SetText(L.GOLD_BARRICADE)
    bLabel:SetTextColor(accentR, accentG, accentB)

    -- Ajuste la taille du conteneur pour centrer le tout
    local bLabelWidth = bLabel:GetStringWidth() or 60
    bContent:SetSize(14 + 3 + bLabelWidth, 14)
    barricadeBtn.label = bLabel
    barricadeBtn.icon = bIcon

    local bGlow = barricadeBtn:CreateTexture(nil, "HIGHLIGHT")
    bGlow:SetAllPoints()
    bGlow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    bGlow:SetTexCoord(0, 0.625, 0, 0.6875)
    bGlow:SetBlendMode("ADD")
    bGlow:SetAlpha(0.15)

    barricadeBtn:SetScript("OnClick", function()
        if Overlord.Ressources then Overlord.Ressources:SpendBarricade() end
    end)
    barricadeBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        local t = TT()
        GameTooltip:AddLine(L.GOLD_BARRICADE, t.HL[1], t.HL[2], t.HL[3])
        if barricadeActive and L.GOLD_BARRICADE_ACTIVE then
            GameTooltip:AddLine(L.GOLD_BARRICADE_ACTIVE, t.BODY[1], t.BODY[2], t.BODY[3], true)
        else
            GameTooltip:AddLine(L.GOLD_BARRICADE_TIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
            if L.GOLD_TOOLTIP_COST then
                GameTooltip:AddLine(string.format(L.GOLD_TOOLTIP_COST, GOLD_SPEND_COST), t.MUTED[1], t.MUTED[2], t.MUTED[3])
            end
            local g = Overlord.Ressources and Overlord.Ressources:GetGold() or 0
            if g < GOLD_SPEND_COST then
                GameTooltip:AddLine(string.format(L.GOLD_NOT_ENOUGH, GOLD_SPEND_COST), t.HL[1], t.HL[2], t.HL[3])
            end
        end
        GameTooltip:Show()
    end)
    barricadeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    goldHUD.barricadeBtn = barricadeBtn

    -- Bouton Renfort (offensif) - droite
    local reinforceBtn = CreateFrame("Button", nil, goldHUD, "BackdropTemplate")
    reinforceBtn:SetSize(btnW, btnH)
    reinforceBtn:SetPoint("BOTTOMRIGHT", goldHUD, "BOTTOMRIGHT", -10, 7)
    reinforceBtn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    reinforceBtn:SetBackdropColor(0.12, 0.12, 0.18, 0.9)
    reinforceBtn:SetBackdropBorderColor(borderR, borderG, borderB, 0.5)

    -- Conteneur centre pour icone + texte
    local rContent = CreateFrame("Frame", nil, reinforceBtn)
    rContent:SetPoint("CENTER", reinforceBtn, "CENTER", 0, 0)

    local rIcon = rContent:CreateTexture(nil, "ARTWORK")
    rIcon:SetSize(14, 14)
    rIcon:SetPoint("LEFT", rContent, "LEFT", 0, 0)
    rIcon:SetTexture("Interface\\Icons\\Ability_Warrior_OffensiveStance")
    rIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local rLabel = rContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rLabel:SetPoint("LEFT", rIcon, "RIGHT", 3, 0)
    rLabel:SetText(L.GOLD_REINFORCE)
    rLabel:SetTextColor(accentR, accentG, accentB)

    -- Ajuste la taille du conteneur pour centrer le tout
    local rLabelWidth = rLabel:GetStringWidth() or 60
    rContent:SetSize(14 + 3 + rLabelWidth, 14)

    reinforceBtn.label = rLabel
    reinforceBtn.icon = rIcon

    local rGlow = reinforceBtn:CreateTexture(nil, "HIGHLIGHT")
    rGlow:SetAllPoints()
    rGlow:SetTexture("Interface\\BUTTONS\\UI-Panel-Button-Highlight")
    rGlow:SetTexCoord(0, 0.625, 0, 0.6875)
    rGlow:SetBlendMode("ADD")
    rGlow:SetAlpha(0.15)

    reinforceBtn:SetScript("OnClick", function()
        if Overlord.Ressources then Overlord.Ressources:SpendReinforce() end
    end)
    reinforceBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        local t = TT()
        GameTooltip:AddLine(L.GOLD_REINFORCE, t.HL[1], t.HL[2], t.HL[3])
        if reinforceActive and L.GOLD_REINFORCE_ACTIVE then
            GameTooltip:AddLine(L.GOLD_REINFORCE_ACTIVE, t.BODY[1], t.BODY[2], t.BODY[3], true)
        else
            GameTooltip:AddLine(L.GOLD_REINFORCE_TIP, t.BODY[1], t.BODY[2], t.BODY[3], true)
            if L.GOLD_TOOLTIP_COST then
                GameTooltip:AddLine(string.format(L.GOLD_TOOLTIP_COST, GOLD_SPEND_COST), t.MUTED[1], t.MUTED[2], t.MUTED[3])
            end
            local g = Overlord.Ressources and Overlord.Ressources:GetGold() or 0
            if g < GOLD_SPEND_COST then
                GameTooltip:AddLine(string.format(L.GOLD_NOT_ENOUGH, GOLD_SPEND_COST), t.HL[1], t.HL[2], t.HL[3])
            end
        end
        GameTooltip:Show()
    end)
    reinforceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    goldHUD.reinforceBtn = reinforceBtn

    -- Couleurs pour le refresh
    goldHUD._accent = { accentR, accentG, accentB }
    goldHUD._green = activeGreen
    goldHUD._blue = activeBlue
    goldHUD._gray = dimGray

    -- Bouton fermer (X)
    Overlord.UI.CreateWC3CloseButton(goldHUD, HideTopHudManually, { size = 20 })
        :SetPoint("TOPRIGHT", -2, -2)

    -- Position sauvegardee (cluster entier, librement deplacable, n'importe ou a l'ecran)
    if OverlordDB and OverlordDB.goldHUDPos then
        local p = OverlordDB.goldHUDPos
        goldHudRoot:ClearAllPoints()
        goldHudRoot:SetPoint(p.point or "TOP", UIParent, p.relPoint or "TOP", p.x or 0, p.y or -4)
    end

    -- Demarre cache, la visibilite est geree par le ticker de zone
    goldHudRoot:Hide()
end

local GK_HUD_ORANGE = { 1.0, 0.82, 0.0 }
local GK_HUD_GRAY = { 0.55, 0.55, 0.58 }
-- Memes teintes que Popups FormatFactionColoredName (|cFF4488FF| / |cFFFF4444|)
local GK_FACTION_ALLIANCE = { 0.27, 0.53, 1.0 }
local GK_FACTION_HORDE = { 1.0, 0.27, 0.27 }
local lastGkHudBarKey = nil

local function SetGuildKeepHudLabelFactionColor(lr, lg, lb, faction)
    if faction == "Alliance" then
        return GK_FACTION_ALLIANCE[1], GK_FACTION_ALLIANCE[2], GK_FACTION_ALLIANCE[3]
    end
    if faction == "Horde" then
        return GK_FACTION_HORDE[1], GK_FACTION_HORDE[2], GK_FACTION_HORDE[3]
    end
    return lr, lg, lb
end

function Overlord.Ressources:RefreshGuildKeepHUD(force)
    if not guildKeepHUD or not Overlord.GuildKeep then return end
    if force then lastGkHudBarKey = nil end
    local st, site = GetHudKeepContext()
    if not st or not site then return end

    local orangeC = GK_HUD_ORANGE
    local grayC = GK_HUD_GRAY
    local mapID = site.mapID
    if not mapID and Overlord.GuildKeep.GetPlayerMapID then
        mapID = Overlord.GuildKeep:GetPlayerMapID()
    end

    local atlas = GetKeepHudWarfrontAtlas(st, mapID, site)
    local shortName = Overlord.GuildKeep:GetShortDisplayName(site)
    local label = Overlord.GuildKeep:GetKeepHudLabel(st, site, mapID)
    local activity = nil
    local siegeActive = Overlord.GuildKeep.IsKeepCaptureInProgress
        and Overlord.GuildKeep:IsKeepCaptureInProgress(st, site.siteKey)
    if siegeActive and Overlord.GuildKeep.GetKeepCaptureMapLabel then
        activity = Overlord.GuildKeep:GetKeepCaptureMapLabel(st, site and site.siteKey)
        label = shortName
    end
    local dg, df = Overlord.GuildKeep:GetKeepDisplayTenant(st, site and site.siteKey)
    local lr, lg, lb = grayC[1], grayC[2], grayC[3]
    if siegeActive then
        lr, lg, lb = orangeC[1], orangeC[2], orangeC[3]
    elseif st.status == "held" and dg ~= "" then
        lr, lg, lb = SetGuildKeepHudLabelFactionColor(lr, lg, lb, df or st.ownerFaction)
    end
    if label == shortName then
        lr, lg, lb = grayC[1], grayC[2], grayC[3]
    end
    local vr, vg, vb = Overlord.GuildKeep:GetKeepIconVertexColor(st, site, mapID)
    -- Cle de dirty-check : 9 valeurs pour 9 specificateurs, et couleurs en %.2f - l'ancienne
    -- cle (%d, 9 args pour 8 %s) tronquait les composantes float a 0 et ignorait df, donc un
    -- changement de couleur/faction ne rafraichissait pas le HUD.
    local barKey = string.format("%s|%s|%s|%s|%.2f|%.2f|%.2f|%d|%d|%d|%s", site.siteKey, atlas, label,
        activity or "", lr, lg, lb, math.floor(vr * 100), math.floor(vg * 100),
        math.floor(vb * 100), df or "")
    if barKey == lastGkHudBarKey then return end
    lastGkHudBarKey = barKey
    if guildKeepHUD.icon.SetAtlas then
        guildKeepHUD.icon:SetAtlas(atlas)
        guildKeepHUD.icon:SetVertexColor(vr, vg, vb)
    end
    guildKeepHUD.guildLabel:SetText(label)
    guildKeepHUD.guildLabel:SetTextColor(lr, lg, lb)
    if guildKeepHUD.activityLabel then
        if activity and activity ~= "" and activity ~= label then
            guildKeepHUD.activityLabel:SetText(activity)
            guildKeepHUD.activityLabel:Show()
        else
            guildKeepHUD.activityLabel:Hide()
        end
    end
    -- Fleches visibles seulement si plusieurs fortins (style portail mage)
    if guildKeepHUD.dropArrowLeft and guildKeepHUD.dropArrowRight then
        local count = 0
        for _ in pairs(Overlord.GuildKeepSites or {}) do count = count + 1 end
        local showArrows = count > 1
        guildKeepHUD.dropArrowLeft:SetShown(showArrows)
        guildKeepHUD.dropArrowRight:SetShown(showArrows)
    end
end



-- Dirty-check (meme principe que RefreshGuildKeepHUD) : SetText/couleurs boutons sautes si rien
-- n'a change depuis le dernier refresh (or inchange + etats renfort/barricade identiques).
local lastGoldHudKey = nil

-- Les coins sont aussi affiches dans le panneau Overlord (carte Front du jour).
function Overlord.Ressources:GetGoldMax() return GOLD_MAX end
function Overlord.Ressources:GetGoldSpendCost() return GOLD_SPEND_COST end
function Overlord.Ressources:GetGoldActionState()
    return gold, GOLD_MAX, GOLD_SPEND_COST, reinforceActive, barricadeActive
end

function Overlord.Ressources:ApplyCombatFade()
    if not goldHudRoot then return end
    local alpha = Overlord.HudInCombat and 0.4 or 1
    if goldHudRoot._olCombatAlpha ~= alpha then
        goldHudRoot._olCombatAlpha = alpha
        goldHudRoot:SetAlpha(alpha)
    end
end

function Overlord.Ressources:RefreshHUD()
    if Overlord.Popups and Overlord.Popups.RefreshFeaturedFrontCoins then
        Overlord.Popups:RefreshFeaturedFrontCoins()
    end
    if not goldHUD then return end

    local g = gold
    local pct = g / GOLD_MAX

    -- Barre de progression : recalculee a chaque appel (cout negligeable, evite toute barre
    -- perimee si la largeur du panneau change entre deux refresh de texte/couleurs).
    local barWidth = goldHUD.barBg:GetWidth() * pct
    goldHUD.barFill:SetWidth(math.max(1, barWidth))

    local canSpend = g >= GOLD_SPEND_COST
    local key = g .. "|" .. (reinforceActive and 1 or 0) .. "|" .. (barricadeActive and 1 or 0)
        .. "|" .. (canSpend and 1 or 0)
    if key == lastGoldHudKey then return end
    lastGoldHudKey = key

    goldHUD.goldText:SetText(string.format(L.GOLD_COUNTER, g, GOLD_MAX))

    local ac = goldHUD._accent
    local gy = goldHUD._gray

    -- Bouton Renfort
    local rBtn = goldHUD.reinforceBtn
    if reinforceActive then
        rBtn.label:SetText(L.GOLD_REINFORCE)
        rBtn.label:SetTextColor(gy[1], gy[2], gy[3])
        rBtn:SetBackdropBorderColor(gy[1], gy[2], gy[3], 0.5)
        if rBtn.icon then rBtn.icon:SetDesaturated(true) end
    elseif g >= GOLD_SPEND_COST then
        rBtn.label:SetText(L.GOLD_REINFORCE)
        rBtn.label:SetTextColor(ac[1], ac[2], ac[3])
        rBtn:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.6)
        if rBtn.icon then rBtn.icon:SetDesaturated(false) end
    else
        rBtn.label:SetText(L.GOLD_REINFORCE)
        rBtn.label:SetTextColor(gy[1], gy[2], gy[3])
        rBtn:SetBackdropBorderColor(gy[1], gy[2], gy[3], 0.4)
        if rBtn.icon then rBtn.icon:SetDesaturated(true) end
    end

    -- Bouton Barricade
    local bBtn = goldHUD.barricadeBtn
    if barricadeActive then
        bBtn.label:SetText(L.GOLD_BARRICADE)
        bBtn.label:SetTextColor(gy[1], gy[2], gy[3])
        bBtn:SetBackdropBorderColor(gy[1], gy[2], gy[3], 0.5)
        if bBtn.icon then bBtn.icon:SetDesaturated(true) end
    elseif g >= GOLD_SPEND_COST then
        bBtn.label:SetText(L.GOLD_BARRICADE)
        bBtn.label:SetTextColor(ac[1], ac[2], ac[3])
        bBtn:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.6)
        if bBtn.icon then bBtn.icon:SetDesaturated(false) end
    else
        bBtn.label:SetText(L.GOLD_BARRICADE)
        bBtn.label:SetTextColor(gy[1], gy[2], gy[3])
        bBtn:SetBackdropBorderColor(gy[1], gy[2], gy[3], 0.4)
        if bBtn.icon then bBtn.icon:SetDesaturated(true) end
    end
end

-- ==================== Visibilite du HUD par zone ====================
-- HUD sur tout front configure dans Fronts.lua (depenser Renfort / Barricade sur la carte) ;
-- aussi Hillsbrad (25) et Silverpine (21) pour gagner de l'or dans les cercles des mines EK.
-- Si le joueur l'a ferme manuellement, il reste cache tant qu'il ne change pas de zone.

local lastHUDZoneCheck = 0
local lastHUDMapID = nil
local AUTO_HUD_GRACE_SECONDS = 15
local autoGoldLastRelevantAt = nil
local autoKeepLastRelevantAt = nil

-- Masque le HUD or pendant les instances (CdB, donjon, etc.) - appele depuis Core:SuspendForInstance.
function Overlord.Ressources:HideGoldHUDForInstance()
    if goldHudRoot and goldHudRoot:IsShown() then
        goldHudRoot:Hide()
    end
    if guildKeepHUD then guildKeepHUD:Hide() end
end

local function IsInHUDZone()
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not mapID then return false, nil end
    -- CdB / arene : une carte peut partager un UiMapID avec un front (ex. Gilneas) ou IsInInstance()
    -- rester faux un instant au chargement - on aligne sur Core.lua (GetInstanceInfo en secours).
    if Overlord.InstanceSuspended then return false, mapID end
    if IsInInstance() then return false, mapID end
    local okInst, _, instType = pcall(GetInstanceInfo)
    if okInst and instType and instType ~= "none" and instType ~= "" then
        return false, mapID
    end
    -- Perimetre carte (front, fortin, mine) : pas le carre de siege requis (reserve a
    -- IsInOverlordKillZone pour le classement kills fortin).
    if IsResourceHudZone(mapID, true) then
        return true, mapID
    end
    return false, mapID
end

local function GetAutoHudContext(mapID)
    local zones = Overlord.Zones
    local inCapture = zones and zones.GetCurrentPlayerZone and zones:GetCurrentPlayerZone() ~= nil
    local inMine = zones and zones.GetCurrentPlayerMine and zones:GetCurrentPlayerMine() ~= nil

    local inKeep = false
    local keep = Overlord.GuildKeep
    if keep and keep.ResolveSiteByMapID and keep.IsPlayerInKeepGeometryForHud then
        local site = keep:ResolveSiteByMapID(mapID)
        inKeep = site and keep:IsPlayerInKeepGeometryForHud(site) or false
    end

    local inOutpost = false
    local outpost = Overlord.Outpost
    if outpost and outpost.ResolveSiteByMapID and outpost.IsPlayerInOutpostGeometry then
        local site = outpost:ResolveSiteByMapID(mapID)
        inOutpost = site and outpost:IsPlayerInOutpostGeometry(site) or false
    end

    return inCapture or inMine or inKeep or inOutpost, inKeep
end

local function HUDZoneCheck(force)
    if not force then
        local now = GetTime()
        if now - lastHUDZoneCheck < 2 then return end
        lastHUDZoneCheck = now
    else
        lastHUDZoneCheck = GetTime()
    end

    if Overlord:IsPlayerDeadOrGhost() then
        if goldHudRoot and goldHudRoot:IsShown() then
            goldHudRoot:Hide()
        end
        return
    end

    if not goldHudRoot or not goldHUD then return end

    local inZone, mapID = IsInHUDZone()
    if mapID ~= lastHUDMapID then
        lastHUDMapID = mapID
        autoGoldLastRelevantAt = nil
        autoKeepLastRelevantAt = nil
    end

    local cfg = OverlordDB and OverlordDB.config
    local hudMode = cfg and cfg.topHudMode or "auto"
    local settingsHidden = hudMode == "never"
        or (cfg and cfg.topHudMode == nil and cfg.showTopHud == false)
    local hudHidden = settingsHidden or (OverlordDB and OverlordDB.goldHUDHidden)
    local showTutorial = cfg and cfg.showTutorialBook == true or false
    local showGold, showKeep = false, false
    if inZone and not hudHidden then
        if hudMode == "auto" then
            local relevantGold, relevantKeep = GetAutoHudContext(mapID)
            local now = GetTime()
            if relevantGold then autoGoldLastRelevantAt = now end
            if relevantKeep then autoKeepLastRelevantAt = now end
            showGold = autoGoldLastRelevantAt and now - autoGoldLastRelevantAt <= AUTO_HUD_GRACE_SECONDS or false
            showKeep = autoKeepLastRelevantAt and now - autoKeepLastRelevantAt <= AUTO_HUD_GRACE_SECONDS or false
        else
            showGold = true
            showKeep = true
        end
    end
    -- Panneau des pieces : desactive par defaut (genant a l'ecran, stream) ;
    -- le joueur le reactive dans les reglages.
    showGold = showGold and cfg ~= nil and cfg.showCoinsHud == true
    showKeep = showKeep and showGold
        and Overlord.Ressources:ShouldShowGuildKeepHUD(mapID, inZone)
    local showCluster = showGold
    if showCluster then
        Overlord.Ressources:ApplyCombatFade()
        if not goldHudRoot:IsShown() then
            goldHudRoot:Show()
        end
        LayoutHudTopRow(showKeep, showGold, showTutorial)
        if showGold then Overlord.Ressources:RefreshHUD() end
        if showKeep then Overlord.Ressources:RefreshGuildKeepHUD() end
    else
        if goldHudRoot:IsShown() then
            goldHudRoot:Hide()
        end
        if guildKeepHUD then guildKeepHUD:Hide() end
        lastHudTopLayoutKey = nil
        NotifyHudStackLayout()
    end
end

function Overlord.Ressources:OnShowTopHudSettingChanged()
    HUDZoneCheck(true)
end

function Overlord.Ressources:OnShowTutorialBookSettingChanged()
    HUDZoneCheck(true)
end

local ghostTopHudWasShown = false

-- Cache le cluster haut pendant mort/fantome (bouton Blizzard « Retour au cimetiere »).
function Overlord.Ressources:SuppressForGhost()
    if not goldHudRoot then return end
    ghostTopHudWasShown = goldHudRoot:IsShown()
    if ghostTopHudWasShown then
        goldHudRoot:Hide()
    end
end

function Overlord.Ressources:RestoreAfterGhost()
    ghostTopHudWasShown = false
    HUDZoneCheck(true)
end

-- ==================== Initialisation ====================

-- Une seconde est necessaire uniquement sur une carte mine (gain passif et
-- sortie de cercle). Partout ailleurs, une maintenance lente suffit pour la
-- regeneration horodatee des stocks ; les changements de zone reveillent aussitot
-- la boucle. Cela retire un ticker permanent et ses lectures carte/HUD au repos.
local function ScheduleResourceTick(delay)
    if mineTicker then mineTicker:Cancel() end
    mineTicker = C_Timer.NewTimer(delay, function()
        mineTicker = nil
        local now = GetTime()
        local elapsed = resourceTickLastAt > 0 and (now - resourceTickLastAt) or 1
        resourceTickLastAt = now
        if Overlord.InstanceSuspended then
            resourceTickerFast = false
        else
            MineTickerFunc(elapsed)
            HUDZoneCheck()
        end
        ScheduleResourceTick(resourceTickerFast and 1 or 8)
    end)
end

function Overlord.Ressources:Initialize()
    self:RestoreResources()

    -- Cadre HUD autonome (haut de l'ecran)
    CreateGoldHUD()
    self:RefreshHUD()
    self:RefreshGuildKeepHUD()

    resourceTickLastAt = GetTime()
    ScheduleResourceTick(0.1)

    -- Event minage actif (filtre "player" cote C pour eviter des centaines d'appels en BG/100v100)
    resFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    -- Changement de zone : masque/affiche le HUD immediatement (pas d'attente ticker 2s)
    resFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    resFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    resFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnSpellcastSucceeded(_, event, ...)
        else
            HUDZoneCheck(true)
            -- Le joueur peut entrer dans un cercle juste apres le changement de
            -- carte : ne pas attendre le prochain entretien lent hors zone.
            resourceTickLastAt = GetTime()
            ScheduleResourceTick(0.1)
        end
    end)

    -- Textes d'or / renfort alignes sur les constantes ci-dessus (evite derapage vs Locales)
    if Overlord.ApplyGoldLocaleStrings then
        Overlord.ApplyGoldLocaleStrings()
    end
end

-- Fin initialisation ressources
