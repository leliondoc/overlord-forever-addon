-- Shared strategic-site sender validation (the wood-resource domination boost was removed in 1.2.0).
Overlord = Overlord or {}
Overlord.Sync = Overlord.Sync or {}
local function SyncSenderIsInOurGroup(sender)
    return Overlord.Sync.SenderIsInOurGroup and Overlord.Sync:SenderIsInOurGroup(sender) or false
end

function Overlord.Sync:HasCommunityClub()
    if self.FindCommunityClub then
        return self:FindCommunityClub() ~= nil
    end
    return OverlordDB and OverlordDB.inCommunity == true
end

local function GetGroupSenderFaction(sender)
    return Overlord.Sync and Overlord.Sync.GetGroupMemberFaction
        and Overlord.Sync:GetGroupMemberFaction(sender) or nil
end

function Overlord.Sync:IsStrategicSiteSenderTrusted(sender, remoteFaction, sourceChannel, msgType, remoteStatus)
    if not sender or sender == "" then return false end
    if sender:find("^BNet%-", 1) or sender:find("^Bridge%-", 1) then return false end
    local pf = Overlord.PlayerFaction
    if not pf or pf == "" then return false end

    if self.IsStrategicSiteCommunitySender and self:IsStrategicSiteCommunitySender(sender) then
        return true
    end

    -- Le canal est par faction, mais un defenseur peut relayer un etat ennemi.
    -- Les recepteurs valident site, pool, campagne et timestamps avant application.
    if sourceChannel == "CHANNEL" and (msgType == "LO" or msgType == "LOC" or msgType == "OE"
        or msgType == "OP" or msgType == "OC") then
        return true
    end

    -- Les etats actifs et terminaux circulent aussi dans les groupes mixtes.
    -- Les snapshots de routine conservent la verification de faction du groupe.
    if SyncSenderIsInOurGroup(sender) then
        if msgType == "LO"
            or msgType == "LOC" or msgType == "OE" or msgType == "OC" then
            return true
        end
        if msgType == "OP" and remoteStatus == "in_progress" then
            return true
        end
        local sf = GetGroupSenderFaction(sender)
        return sf and sf == pf
    end
    return false
end
