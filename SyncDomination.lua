-- SyncDomination.lua - barre de domination hebdo v2 (1.1.11).
-- La barre ne bouge plus avec le temps : alliancePct = clamp(50 + (victoiresA - victoiresH),
-- 0, 100). Une victoire de front = +1 pour le vainqueur (journal VB, SyncVictoryBonus.lua),
-- union d'evenements identifies rejouee en anti-entropie (SR) : tous les clients
-- convergent sur la meme barre. Le systeme de bois a ete retire en 1.2.0.
-- DX (secondes de zone) n'est plus emis. Les DX des anciens clients (<= 1.1.10) sont
-- valides puis ignores pour la barre ; ils servent seulement a estimer le total "ancienne
-- formule" pour totalAtApply des VB (anciens recepteurs, voir GetLegacyDominationTotalForVB).
-- Fichier separe de Sync.lua pour respecter la limite WoW de 200 locals par chunk.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local DM_SECONDS_PER_WEEK = 7 * 24 * 60 * 60
local DM_SCORE_INTERVAL = 120
local DM_BAR_BASE = 50
-- Version de protocole DX des clients 1.1.9/1.1.10 : les autres versions sont ignorees.
local DM_PROTOCOL_VERSION = "11"

-- Identite de campagne pour la synchro domination : on se cale strictement sur la FENETRE
-- hebdomadaire du reset officiel Blizzard (C_DateAndTime, via GetCurrentCampaignStartTs), qui est
-- coherente pour toute la region (meme instant pour tous les clients d'un meme royaume/region).
--
-- On NE matche PLUS sur un jour calendaire (AAAAMMJJ) ni sur des tolerances "legacy mercredi" :
-- ce jour derivait selon le fuseau (mardi cote US continental, mercredi cote Oceanique) et
-- fragmentait la campagne NA -> les DX etaient rejetes entre clients -> barre figee a 50/50.
-- Le jour calendaire reste reserve a l'affichage/export (Check PvP), pas a la synchro reseau.
--
-- Un epoch distant appartient a la campagne courante s'il tombe dans la meme fenetre
-- [debut campagne ; debut + 1 semaine). EU non affecte (reset deja coherent tous fuseaux).
local function IsCurrentSyncCampaignEpoch(epoch)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local windowStart = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs())
        or (OverlordDB and tonumber(OverlordDB.lastResetTimestamp)) or 0
    if windowStart <= 0 then return false end
    return epoch >= windowStart and epoch < windowStart + DM_SECONDS_PER_WEEK
end

-- Format DX v11 : allianceTime:hordeTime:epoch:frontId:seq:source:pool:boostA:boostH:protocol
-- Le marqueur v11 coupe explicitement les clients qui materialisent encore les victoires
-- dans les buckets DX : le bonus victoire voyage desormais uniquement via VB.
-- epoch = debut de campagne officiel (reset Blizzard, region-wide coherent) : accepte si l'epoch
-- distant tombe dans la meme fenetre hebdomadaire (voir IsCurrentSyncCampaignEpoch).
-- Evite la pollution par les vieux clients (DM sans 3e champ) ou une autre campagne.

local VALID_DM_POOL_TAG = { global = true }

local function NormalizeDominationPoolTag(pool)
    if type(pool) ~= "string" then return "" end
    pool = pool:lower():match("^%s*([a-z]+)%s*$") or ""
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    if VALID_DM_POOL_TAG[pool] then return pool end
    return ""
end

local function CurrentDominationPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return NormalizeDominationPoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function ResolveDominationPayloadPool(remotePool, sender, sourceChannel)
    remotePool = NormalizeDominationPoolTag(remotePool)
    if Overlord.Sync and Overlord.Sync.ResolveDirectGroupTerritorialPool then
        return Overlord.Sync:ResolveDirectGroupTerritorialPool(
            remotePool, sender, sourceChannel)
    end
    local localPool = CurrentDominationPoolTag()
    if localPool == "" or remotePool == "" then return nil end
    return remotePool == localPool and localPool or nil
end

function Overlord.Sync:IsDominationChannelSenderVerified(sender)
    if self.SenderIsInOurGroup and self:SenderIsInOurGroup(sender or "") then return true end
    if self.IsStrategicSiteCommunitySender and self:IsStrategicSiteCommunitySender(sender or "") then return true end
    return false
end

local function MaxPlausibleDominationTotal(front, campaignEpoch)
    if not front or type(front.zones) ~= "table" then return 0 end
    local zoneCount = 0
    for _ in pairs(front.zones) do zoneCount = zoneCount + 1 end
    if zoneCount <= 0 then return 0 end
    local elapsed = math.max(0, math.min(
        DM_SECONDS_PER_WEEK, ((GetServerTime and GetServerTime()) or (time and time()) or 0) - campaignEpoch + 300))
    -- Le socle territorial vaut zoneCount * secondes. Les bonus bois de 1 % se
    -- composent sur le total multi-front ; x64 couvre plus de 400 depenses sans
    -- rejeter une campagne legitime, tout en gardant le plafond absolu a 50 M.
    return math.min(
        (Overlord.DOMINATION_PLAUSIBLE_MAX or 500000000) - 1,
        math.max(100000, zoneCount * elapsed * 64 + 500000))
end

-- Total DX le plus haut observe par front chez les anciens clients (memoire seulement).
function Overlord.Sync:NoteObservedLegacyDominationTotal(frontId, total)
    local epoch = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs()) or 0
    if self._legacyDxEpoch ~= epoch or type(self._legacyDxByFront) ~= "table" then
        self._legacyDxEpoch, self._legacyDxByFront = epoch, {}
    end
    if (self._legacyDxByFront[frontId] or 0) < total then
        self._legacyDxByFront[frontId] = total
    end
end

function Overlord.Sync:GetObservedLegacyDominationTotal()
    local epoch = (Overlord.GetCurrentCampaignStartTs and Overlord:GetCurrentCampaignStartTs()) or 0
    if self._legacyDxEpoch ~= epoch or type(self._legacyDxByFront) ~= "table" then return 0 end
    local total = 0
    for _, value in pairs(self._legacyDxByFront) do total = total + value end
    return total
end

-- DX d'un ancien client : conserve les memes gardes qu'avant (protocole, pool, epoch, seq,
-- plausibilite, source verifiee) mais ne modifie plus aucun etat de la barre.
function Overlord.Sync:OnReceiveDomination(payload, sender, sourceChannel)
    if not payload or not OverlordDB then return end
    local aStr, hStr, epochStr, frontId, seqStr, sourceStr, poolStr, _, _, protocolStr =
        strsplit(":", payload, 10)
    if protocolStr ~= DM_PROTOCOL_VERSION then return end
    local effectivePool = ResolveDominationPayloadPool(poolStr, sender, sourceChannel)
    if not effectivePool then return end
    local remoteAlly  = tonumber(aStr) or 0
    local remoteHorde = tonumber(hStr) or 0
    if remoteAlly < 0 or remoteHorde < 0 then return end
    local corruptLimit = Overlord.DOMINATION_PLAUSIBLE_MAX or 500000000
    if remoteAlly >= corruptLimit or remoteHorde >= corruptLimit then return end
    local remoteEpoch = tonumber(epochStr)
    if not IsCurrentSyncCampaignEpoch(remoteEpoch) then return end
    local remoteSeq = math.floor(tonumber(seqStr) or 0)
    local currentSeq = math.floor(((GetServerTime and GetServerTime()) or (time and time()) or 0) / DM_SCORE_INTERVAL)
    local campaignFirstSeq = math.floor(remoteEpoch / DM_SCORE_INTERVAL) - 1
    if remoteSeq < campaignFirstSeq or remoteSeq > currentSeq + 1 then return end
    local remoteSource = tostring(sourceStr or sender or "")
    if remoteSource == "" or #remoteSource > 80 then return end
    local front = frontId and frontId ~= "" and Overlord.Fronts
        and Overlord.Fronts.Registry and Overlord.Fronts.Registry[frontId] or nil
    if not front then return end
    local remoteTotal = remoteAlly + remoteHorde
    if remoteTotal > MaxPlausibleDominationTotal(front, remoteEpoch) then return end
    if not self:IsDominationChannelSenderVerified(sender or "") then return end
    self:NoteObservedLegacyDominationTotal(frontId, remoteTotal)
end

-- DX n'est plus emis par aucun producteur (ticker, SR, communaute/BNet/canal, depense
-- de bois). Conserve uniquement pour qu'un appelant tiers ne provoque pas d'erreur.
function Overlord.Sync:BroadcastDomination()
    return false
end

-- Valeur de la barre v2 : 50 +/- 1 par victoire de front ; pourcentages puis compteurs.
function Overlord:GetDominationBarScore()
    local victoriesA, victoriesH = 0, 0
    if self.GetDominationVictoryCounts then
        victoriesA, victoriesH = self:GetDominationVictoryCounts()
    end
    local alliancePct = DM_BAR_BASE + (victoriesA - victoriesH)
    if alliancePct < 0 then alliancePct = 0 elseif alliancePct > 100 then alliancePct = 100 end
    return alliancePct, 100 - alliancePct, victoriesA, victoriesH
end
