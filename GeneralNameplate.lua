-- GeneralNameplate.lua - Tag Général au-dessus des nameplates (allié + ennemi si IsLocalHolder)
Overlord = Overlord or {}
Overlord.GeneralNameplate = {}

local frame = nil
local overlays = {}
local holderCacheRevision = -1
local allyHolderKey = nil
local enemyHolderKey = nil
local allyHolderName = nil
local enemyHolderName = nil
local allyHolderFaction = nil
local enemyHolderFaction = nil
local duelMusicActive = false
local duelStopTimer = nil
local duelMaxTimer = nil
local duelStartedAt = nil
local duelMusicCapped = false
local duelStopAt = nil
-- Unite nameplate memorisee du general ennemi (mise a jour par OnNamePlateAdded/Removed) : evite
-- de rebalayer les 40 nameplates a chaque appel de NameplateExchangesWithEnemyHolder tant que la
-- nameplate reste visible. Repli automatique sur le scan complet si l'unite disparait/ne matche plus.
local enemyHolderNameplateUnit = nil
local DUEL_STOP_DELAY = 24
local DUEL_MAX_DURATION = 110
local initialized = false
local duelMonitorArmed = false
local gmKeepaliveTicker = nil
local overlayRefreshPending = false
local lastDuelTriggerAt = 0
local DUEL_TRIGGER_DEBOUNCE = 0.5
local GM_KEEPALIVE_INTERVAL = 10
local DUEL_MONITOR_EVENTS = {
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}
-- Meme taille que le badge du bouton panel (Button.lua : 36 * 1.5).
local PANEL_BTN_SIZE = 36
local PANEL_BADGE_SCALE = 1.5
local NAMEPLATE_BADGE_SIZE = PANEL_BTN_SIZE * PANEL_BADGE_SCALE
local NAMEPLATE_BADGE_OFFSET = -2

local function NameKey(name)
    if not name or name == "" then return nil end
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(name)
    end
    return (name:match("^(.-)%-") or name):lower()
end

local function RefreshHolderCache()
    local gen = Overlord.General
    if not gen then
        allyHolderKey = nil
        enemyHolderKey = nil
        allyHolderName = nil
        enemyHolderName = nil
        return
    end
    local rev = gen.GetRevision and gen:GetRevision() or 0
    if rev == holderCacheRevision then return end
    holderCacheRevision = rev

    allyHolderKey = nil
    enemyHolderKey = nil
    allyHolderName = nil
    enemyHolderName = nil
    allyHolderFaction = nil
    enemyHolderFaction = nil
    local pf = Overlord.PlayerFaction
    local ef = gen.GetEnemyFaction and gen:GetEnemyFaction()
    -- GetSlot (pas GetDisplayEntry) : le tag nameplate ne depend pas des coords carte.
    local allySlot = gen.GetSlot and pf and gen:GetSlot(pf)
    if allySlot and allySlot.holder then
        allyHolderName = allySlot.holder
        allyHolderKey = NameKey(allySlot.holder)
        allyHolderFaction = allySlot.faction or pf
    end
    local enemySlot = gen.GetSlot and ef and gen:GetSlot(ef)
    if enemySlot and enemySlot.holder then
        enemyHolderName = enemySlot.holder
        enemyHolderKey = NameKey(enemySlot.holder)
        enemyHolderFaction = enemySlot.faction or ef
    end
end

local function HolderMatchesUnit(holderName, unitName)
    if not holderName or not unitName then return false end
    if Overlord.General and Overlord.General.SenderMatches then
        return Overlord.General.SenderMatches(holderName, unitName)
    end
    local hk = NameKey(holderName)
    local uk = NameKey(unitName)
    return hk ~= nil and uk ~= nil and hk == uk
end

function Overlord.GeneralNameplate:RefreshAllOverlays()
    for unit in pairs(overlays) do
        self:RefreshUnit(unit)
    end
end

local function ScheduleOverlayRefresh()
    if overlayRefreshPending then return end
    overlayRefreshPending = true
    C_Timer.After(0.12, function()
        overlayRefreshPending = false
        if Overlord.GeneralNameplate then
            Overlord.GeneralNameplate:RefreshAllOverlays()
        end
    end)
end

local function IsGeneralFrontContext()
    if Overlord.General and Overlord.General.IsGeneralFrontContext then
        return Overlord.General:IsGeneralFrontContext()
    end
    return Overlord.InActiveFront == true
end

local function CanMonitorGeneralDuel()
    if not IsGeneralFrontContext() or Overlord.InstanceSuspended then return false end
    local gen = Overlord.General
    return gen and gen.IsLocalHolder and gen:IsLocalHolder()
end

local function StopGmKeepalive()
    if gmKeepaliveTicker then
        gmKeepaliveTicker:Cancel()
        gmKeepaliveTicker = nil
    end
end

local function StopDuelMonitor()
    StopGmKeepalive()
    if frame then
        for i = 1, #DUEL_MONITOR_EVENTS do
            frame:UnregisterEvent(DUEL_MONITOR_EVENTS[i])
        end
        frame:UnregisterEvent("UNIT_TARGET")
    end
    duelMonitorArmed = false
end

local function NormalizeCleuName(name)
    if not name or name == "" then return nil end
    local sync = Overlord.Sync
    if sync and sync.NormalizeContributorFullName then
        return sync:NormalizeContributorFullName(name) or name
    end
    return name
end

local function TargetExchangesWithEnemyHolder()
    if not UnitExists("target") or not UnitIsPlayer("target") then return false end
    local tkey = NameKey(NormalizeCleuName(Overlord:SafeUnitName("target", true)))
    return tkey ~= nil and tkey == enemyHolderKey
end

local function UnitExchangesWithPlayer(unit)
    return UnitIsUnit(unit .. "target", "player")
        or (UnitExists("target") and UnitIsUnit(unit, "target"))
end

local function NameplateExchangesWithEnemyHolder()
    -- Chemin rapide : unite deja identifiee comme le general ennemi tant qu'elle reste affichee.
    -- Evite un balayage O(40) + SafeUnitName par nameplate a chaque appel (jusqu'a 2/s en duel General).
    if enemyHolderNameplateUnit and UnitExists(enemyHolderNameplateUnit) then
        local ukey = NameKey(NormalizeCleuName(Overlord:SafeUnitName(enemyHolderNameplateUnit, true)))
        if ukey == enemyHolderKey then
            return UnitExchangesWithPlayer(enemyHolderNameplateUnit)
        end
    end
    enemyHolderNameplateUnit = nil

    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local ukey = NameKey(NormalizeCleuName(Overlord:SafeUnitName(unit, true)))
            if ukey == enemyHolderKey then
                enemyHolderNameplateUnit = unit
                if UnitExchangesWithPlayer(unit) then
                    return true
                end
            end
        end
    end
    return false
end

local function IsGeneralDuelExchange()
    RefreshHolderCache()
    if not allyHolderKey or not enemyHolderKey then return false end
    if not UnitAffectingCombat or not UnitAffectingCombat("player") then return false end
    if TargetExchangesWithEnemyHolder() then return true end
    return NameplateExchangesWithEnemyHolder()
end

local function StartGmKeepalive()
    StopGmKeepalive()
    if not CanMonitorGeneralDuel() then return end
    if not duelMusicActive and (GetTime() - lastDuelTriggerAt) > 15 then return end
    -- Relais GM lent (10 s) pour le front, uniquement pendant le duel actif.
    gmKeepaliveTicker = C_Timer.NewTicker(GM_KEEPALIVE_INTERVAL, function()
        if not CanMonitorGeneralDuel() then
            StopGmKeepalive()
            return
        end
        if not duelMusicActive and (GetTime() - lastDuelTriggerAt) > 15 then
            StopGmKeepalive()
            return
        end
        if not UnitAffectingCombat or not UnitAffectingCombat("player") then
            StopGmKeepalive()
            return
        end
        RefreshHolderCache()
        if TargetExchangesWithEnemyHolder() then
            Overlord.GeneralNameplate:OnDuelMusicPulse(true)
            return
        end
        local now = GetTime()
        if now - lastDuelTriggerAt < 12 then
            Overlord.GeneralNameplate:OnDuelMusicPulse(true)
            return
        end
        if IsGeneralDuelExchange() then
            Overlord.GeneralNameplate:OnDuelMusicPulse(true)
        else
            StopGmKeepalive()
        end
    end)
end

function Overlord.GeneralNameplate:TryTriggerDuelMusic(knownEnemyUnit)
    if not duelMonitorArmed or not CanMonitorGeneralDuel() then return end
    local now = GetTime()
    if now - lastDuelTriggerAt < DUEL_TRIGGER_DEBOUNCE then return end
    RefreshHolderCache()
    if not allyHolderKey or not enemyHolderKey then return end
    if not UnitAffectingCombat or not UnitAffectingCombat("player") then return end
    local exchanged = TargetExchangesWithEnemyHolder()
    if not exchanged and knownEnemyUnit and UnitExists(knownEnemyUnit) then
        if UnitIsUnit(knownEnemyUnit .. "target", "player")
            or (UnitExists("target") and UnitIsUnit(knownEnemyUnit, "target")) then
            exchanged = true
        end
    end
    if not exchanged then
        exchanged = NameplateExchangesWithEnemyHolder()
    end
    if not exchanged then return end
    lastDuelTriggerAt = now
    self:OnDuelMusicPulse(true)
    StartGmKeepalive()
end

function Overlord.GeneralNameplate:UpdateCombatLogSubscription()
    local shouldArm = CanMonitorGeneralDuel()
    if shouldArm and not duelMonitorArmed then
        duelMonitorArmed = true
        if frame then
            for i = 1, #DUEL_MONITOR_EVENTS do
                frame:RegisterEvent(DUEL_MONITOR_EVENTS[i])
            end
            frame:RegisterUnitEvent("UNIT_TARGET", "player")
        end
    elseif not shouldArm and duelMonitorArmed then
        StopDuelMonitor()
    end
end

function Overlord.GeneralNameplate:InvalidateHolderCache()
    holderCacheRevision = -1
    RefreshHolderCache()
    ScheduleOverlayRefresh()
    self:UpdateCombatLogSubscription()
end

function Overlord.GeneralNameplate:StopDuelMusic()
    StopGmKeepalive()
    duelStopAt = nil
    if duelStopTimer then
        duelStopTimer:Cancel()
        duelStopTimer = nil
    end
    if duelMaxTimer then
        duelMaxTimer:Cancel()
        duelMaxTimer = nil
    end
    duelStartedAt = nil
    duelMusicCapped = false
    duelMusicActive = false
    if Overlord.StopGeneralDuelMusic then
        Overlord:StopGeneralDuelMusic()
    end
end

local function ResolveTagFaction(unitName)
    RefreshHolderCache()
    if not unitName or unitName == "" then return nil end

    if allyHolderName and HolderMatchesUnit(allyHolderName, unitName) then
        return allyHolderFaction
    end
    if enemyHolderName and HolderMatchesUnit(enemyHolderName, unitName) then
        local gen = Overlord.General
        if gen and gen.IsLocalHolder and gen:IsLocalHolder() then
            return enemyHolderFaction
        end
    end
    return nil
end

local function ApplyBadgeToOverlay(overlay, faction)
    if not overlay or not faction then return false end
    local gen = Overlord.General
    if not gen or not gen.GetFactionBadgeAtlas then return false end
    local atlas = gen:GetFactionBadgeAtlas(faction)
    if not atlas or not overlay.icon or not overlay.icon.SetAtlas then return false end

    if overlay._olFaction ~= faction or overlay._olAtlas ~= atlas then
        overlay._olFaction = faction
        overlay._olAtlas = atlas
        if overlay.icon.SetTexture then
            pcall(overlay.icon.SetTexture, overlay.icon, nil)
        end
        if overlay.icon.SetTexCoord then
            overlay.icon:SetTexCoord(0, 1, 0, 1)
        end
        pcall(overlay.icon.SetAtlas, overlay.icon, atlas)
    end
    overlay:Show()
    return true
end

local function EnsureOverlay(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return nil end
    local parent = plate.UnitFrame or plate
    if not parent then return nil end

    local overlay = overlays[unit]
    if not overlay then
        overlay = CreateFrame("Frame", nil, parent)
        overlay:SetSize(NAMEPLATE_BADGE_SIZE, NAMEPLATE_BADGE_SIZE)
        overlay:SetPoint("BOTTOM", parent, "TOP", 0, NAMEPLATE_BADGE_OFFSET)
        overlay.icon = overlay:CreateTexture(nil, "OVERLAY")
        overlay.icon:SetAllPoints()
        overlays[unit] = overlay
    elseif overlay:GetParent() ~= parent then
        overlay:SetParent(parent)
        overlay:ClearAllPoints()
        overlay:SetPoint("BOTTOM", parent, "TOP", 0, NAMEPLATE_BADGE_OFFSET)
    end
    overlay:SetSize(NAMEPLATE_BADGE_SIZE, NAMEPLATE_BADGE_SIZE)
    return overlay
end

local function HideOverlay(unit)
    local overlay = overlays[unit]
    if overlay then
        overlay:Hide()
        overlay._olFaction = nil
        overlay._olAtlas = nil
    end
end

function Overlord.GeneralNameplate:RefreshUnit(unit)
    if not unit or unit == "" then return end
    if not IsGeneralFrontContext() or Overlord.InstanceSuspended then
        HideOverlay(unit)
        return
    end

    RefreshHolderCache()
    if not allyHolderKey and not enemyHolderKey then
        HideOverlay(unit)
        return
    end

    -- Filtre bon marche avant SafeUnitName (pcall UnitName) : les PNJ (montures, familiers, mobs)
    -- ne peuvent jamais matcher un holder General et representent la majorite des nameplates hors
    -- combat de masse. Evite un appel API inutile a chaque NAME_PLATE_UNIT_ADDED pour ces unites.
    if not UnitIsPlayer(unit) then
        HideOverlay(unit)
        return
    end

    local unitName = Overlord:SafeUnitName(unit, true)
    if not unitName or unitName == "" or unitName == "Unknown" then
        HideOverlay(unit)
        return
    end

    local faction = ResolveTagFaction(unitName)
    if not faction then
        HideOverlay(unit)
        return
    end

    local overlay = EnsureOverlay(unit)
    if not overlay then return end
    ApplyBadgeToOverlay(overlay, faction)
end

function Overlord.GeneralNameplate:OnNamePlateAdded(unit)
    if not unit or unit == "" or not UnitIsPlayer(unit) then return end
    self:RefreshUnit(unit)
    if not duelMonitorArmed or not CanMonitorGeneralDuel() then return end
    if not UnitAffectingCombat or not UnitAffectingCombat("player") then return end
    RefreshHolderCache()
    if not enemyHolderKey then return end
    local unitName = Overlord:SafeUnitName(unit, true)
    if not unitName or unitName == "" or unitName == "Unknown" then return end
    local ukey = NameKey(NormalizeCleuName(unitName))
    if ukey ~= enemyHolderKey then return end
    enemyHolderNameplateUnit = unit
    self:TryTriggerDuelMusic(unit)
end

function Overlord.GeneralNameplate:OnNamePlateRemoved(unit)
    HideOverlay(unit)
    -- Les Frames WoW ne sont pas garbage-collectees. Conserver la reference par unit token
    -- permet a EnsureOverlay de reparent/reutiliser la meme frame a la prochaine apparition.
    if unit == enemyHolderNameplateUnit then
        enemyHolderNameplateUnit = nil
    end
end

local function CancelDuelMaxTimer()
    if duelMaxTimer then
        duelMaxTimer:Cancel()
        duelMaxTimer = nil
    end
end

local function ResetDuelMusicSession()
    duelStopAt = nil
    duelStartedAt = nil
    duelMusicCapped = false
    CancelDuelMaxTimer()
end

local function ScheduleDuelMusicStop()
    local now = GetTime()
    if duelStopTimer then
        duelStopTimer:Cancel()
        duelStopTimer = nil
    end
    duelStopAt = now + DUEL_STOP_DELAY
    duelStopTimer = C_Timer.NewTimer(DUEL_STOP_DELAY, function()
        duelStopAt = nil
        duelStopTimer = nil
        StopGmKeepalive()
        if Overlord.StopGeneralDuelMusic then
            Overlord:StopGeneralDuelMusic()
        end
        duelMusicActive = false
        ResetDuelMusicSession()
    end)
end

local function CapDuelMusic()
    CancelDuelMaxTimer()
    StopGmKeepalive()
    duelMusicActive = false
    duelMusicCapped = true
    if Overlord.StopGeneralDuelMusic then
        Overlord:StopGeneralDuelMusic()
    end
    -- Le cap reste actif tant que le duel continue à envoyer des pulses.
    ScheduleDuelMusicStop()
end

local function ScheduleDuelMaxStop()
    CancelDuelMaxTimer()
    duelMaxTimer = C_Timer.NewTimer(DUEL_MAX_DURATION, function()
        duelMaxTimer = nil
        CapDuelMusic()
    end)
end

function Overlord.GeneralNameplate:OnDuelMusicPulse(shouldBroadcast)
    if not IsGeneralFrontContext() or Overlord.InstanceSuspended then return end
    if OverlordDB and OverlordDB.config and OverlordDB.config.soundEnabled == false then
        if duelMusicActive then
            self:StopDuelMusic()
        end
        ScheduleDuelMusicStop()
        if shouldBroadcast and Overlord.GeneralSync and Overlord.GeneralSync.BroadcastDuelMusicPulse then
            Overlord.GeneralSync:BroadcastDuelMusicPulse()
        end
        return
    end
    if duelMusicCapped then
        ScheduleDuelMusicStop()
        if shouldBroadcast and Overlord.GeneralSync and Overlord.GeneralSync.BroadcastDuelMusicPulse then
            Overlord.GeneralSync:BroadcastDuelMusicPulse()
        end
        return
    end
    local now = GetTime()
    if not duelMusicActive and Overlord.PlayGeneralDuelMusic then
        -- Réserver avant PlaySoundFile : deux pulses (local + GM) peuvent arriver la même frame.
        duelMusicActive = true
        local played = Overlord:PlayGeneralDuelMusic()
        if played then
            duelStartedAt = now
            ScheduleDuelMaxStop()
        else
            duelMusicActive = false
        end
    elseif duelStartedAt and (now - duelStartedAt) >= DUEL_MAX_DURATION then
        CapDuelMusic()
        return
    end
    if duelMusicActive then
        ScheduleDuelMusicStop()
    end
    if shouldBroadcast and Overlord.GeneralSync and Overlord.GeneralSync.BroadcastDuelMusicPulse then
        Overlord.GeneralSync:BroadcastDuelMusicPulse()
    end
end

function Overlord.GeneralNameplate:Initialize()
    if initialized then return end
    initialized = true

    frame = CreateFrame("Frame")
    frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            Overlord.GeneralNameplate:OnNamePlateAdded(unit)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            Overlord.GeneralNameplate:OnNamePlateRemoved(unit)
        elseif event == "PLAYER_REGEN_DISABLED" or event == "UNIT_TARGET" then
            Overlord.GeneralNameplate:TryTriggerDuelMusic()
        elseif event == "PLAYER_REGEN_ENABLED" then
            StopGmKeepalive()
        end
    end)
    RefreshHolderCache()
    -- Réarmement après création du frame (InvalidateHolderCache peut arriver avant Initialize).
    duelMonitorArmed = false
    Overlord.GeneralNameplate:UpdateCombatLogSubscription()
end
