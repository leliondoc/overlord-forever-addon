-- SyncDomination.lua - barre de domination hebdo v2.
-- alliancePct = clamp(50 + (victoiresA - victoiresH), 0, 100). Une victoire de front = +1 pour le
-- vainqueur (journal VB/TV, SyncVictoryBonus.lua), union d'evenements identifies rejouee en
-- anti-entropie (SR) : tous les clients convergent sur la meme barre. Le bois (1.2.0) et
-- l'ancienne domination au temps DX (1.2.1) ont ete retires.
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}

local DM_BAR_BASE = 50

-- Emetteur canal verifie (groupe ou pair relais) : utilise par la validation des victoires.
function Overlord.Sync:IsDominationChannelSenderVerified(sender)
    if self.SenderIsInOurGroup and self:SenderIsInOurGroup(sender or "") then return true end
    if self.IsStrategicSiteCommunitySender and self:IsStrategicSiteCommunitySender(sender or "") then return true end
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
