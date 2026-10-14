-- Ressources.lua - Systeme de ressources joueur (or)
-- Module autonome : accumulation passive (cercle) + bonus actif (vrai node mine),
-- depense offensive (renfort -60s) et defensive (barricade +60s).
-- Core.lua n'appelle que Initialize / SaveResources / RestoreResources / ResetResources.
Overlord = Overlord or {}
Overlord.Ressources = {}

local L = Overlord.L

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
    -- Known mines only: invented ids were kept, saved and walked every second.
    if not mineId or not (Overlord.Zones and Overlord.Zones.GetMine and Overlord.Zones:GetMine(mineId)) then return end
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
            -- Saves polluted by invented ids (before 1.8.1) drop them here.
            if not (Overlord.Zones and Overlord.Zones.GetMine) or Overlord.Zones:GetMine(k) then
                mineStocks[k] = math.max(0, math.min(MINE_STOCK_MAX, tonumber(v) or MINE_STOCK_MAX))
                if mineStocks[k] < MINE_STOCK_MAX then depletedMineIds[k] = true end
            end
        end
    end
    if OverlordDB.mineStockTimers then
        if OverlordDB.mineStockTimers.fargodeep ~= nil and OverlordDB.mineStockTimers.jasperlode == nil then
            OverlordDB.mineStockTimers.jasperlode = OverlordDB.mineStockTimers.fargodeep
        end
        OverlordDB.mineStockTimers.fargodeep = nil
        for k, v in pairs(OverlordDB.mineStockTimers) do
            if not (Overlord.Zones and Overlord.Zones.GetMine) or Overlord.Zones:GetMine(k) then
                mineStockTimers[k] = math.max(0, math.min(MINE_REGEN_INTERVAL - 1, tonumber(v) or 0))
            end
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
    -- 1.4.1: the PvP flag rule is for captures only; mining income stays open.
    if Overlord.ZoneControl and Overlord.ZoneControl.IsPlayerInNonMiningStateForSync then
        return Overlord.ZoneControl:IsPlayerInNonMiningStateForSync()
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
    -- Les changements de zone relancent cette boucle via resFrame.
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

    -- Forever : pas de Warmode. L'or passif reste actif en monde ouvert.

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

-- ==================== Theme des cadres flottants ====================

local HUD_PANEL_WIDTH = 280

-- Theme et chrome de l'indicateur de zone.
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

function Overlord.Ressources:GetGoldActionState()
    return gold, GOLD_MAX, GOLD_SPEND_COST, reinforceActive, barricadeActive
end

-- Les coins et les boutons Renforcer / Attaquer sont sur la carte Prochain objectif.
function Overlord.Ressources:RefreshHUD()
    if Overlord.Popups and Overlord.Popups.RefreshFeaturedFrontCoins then
        Overlord.Popups:RefreshFeaturedFrontCoins()
    end
end

-- ==================== Initialisation ====================

-- Une seconde est necessaire uniquement sur une carte mine (gain passif et
-- sortie de cercle). Partout ailleurs, une maintenance lente suffit pour la
-- regeneration horodatee des stocks ; les changements de zone reveillent aussitot
-- la boucle. Cela retire un ticker permanent et ses lectures de carte au repos.
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
        end
        ScheduleResourceTick(resourceTickerFast and 1 or 8)
    end)
end

function Overlord.Ressources:Initialize()
    self:RestoreResources()

    self:RefreshHUD()

    resourceTickLastAt = GetTime()
    ScheduleResourceTick(0.1)

    -- Event minage actif (filtre "player" cote C pour eviter des centaines d'appels en BG/100v100)
    resFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    -- Changement de zone : relance la boucle des ressources sans attendre.
    resFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    resFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    resFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnSpellcastSucceeded(_, event, ...)
        else
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
