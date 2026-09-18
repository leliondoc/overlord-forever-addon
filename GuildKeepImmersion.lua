-- GuildKeepImmersion.lua - Chroniques factuelles, veillée, héraut et serment
Overlord = Overlord or {}
Overlord.GuildKeepImmersion = Overlord.GuildKeepImmersion or {}

local GKI = Overlord.GuildKeepImmersion
local POST_CUTOFF_REPORT_DELAY_SEC = 180
local POST_CUTOFF_REPORT_SYNC_SETTLE_SEC = 30
-- Si le tenant canonique n'arrive jamais (GC/GK perdu), ne pas poller Publish a 1 Hz indefiniment.
local PENDING_CANONICAL_RETRY_SEC = 8
local PENDING_CANONICAL_ABANDON_SEC = 600
-- Au-dela de cette fenetre apres 22:00, bilans / heralds Keep restent silencieux (etat OK).
local POST_CUTOFF_CHAT_MAX_SEC = 900
-- Ces trois audits travaillent a la minute/jour et peuvent resoudre le tenant canonique
-- (copies, scans et tris). Les lancer a 1 Hz apres la cutoff provoquait un pic GC periodique.
local IMMERSION_TICK_INTERVAL_SEC = 15
local lastImmersionTickAt = -IMMERSION_TICK_INTERVAL_SEC
-- Historique de presentation uniquement : la convergence peut corriger plusieurs fois le
-- terminal du jour, mais une meme phrase ne doit jamais etre rejouee a chaque oscillation.
local SIEGE_REPORT_ANNOUNCED_SIGNATURES_MAX = 6

local function L()
    return Overlord.L
end

local function GetGK()
    return Overlord.GuildKeep
end

local function GetCampaignEpoch()
    if Overlord.Leaderboard and Overlord.Leaderboard.GetCurrentCampaignStart then
        return Overlord.Leaderboard:GetCurrentCampaignStart() or 0
    end
    return OverlordDB and (OverlordDB.lastResetTimestamp or 0) or 0
end

local function SanitizeGuild(guild)
    local gk = GetGK()
    if gk and gk.SanitizeGuildName then
        return gk:SanitizeGuildName(guild or "")
    end
    return guild or ""
end

local function GetSiteDisplayName(siteKey)
    local gk = GetGK()
    if not gk then return tostring(siteKey or "") end
    local site = gk.GetSite and gk:GetSite(siteKey)
    if site and gk.GetDisplayName then
        return gk:GetDisplayName(site)
    end
    return tostring(siteKey or "")
end

local function GetSiegeStartLabel()
    local gk = GetGK()
    if gk and gk.GetSiegeWindowStartLabel then
        return gk:GetSiegeWindowStartLabel()
    end
    return "21:00"
end

local function GetSiegeMinuteOfDayNow(gk)
    local minuteOfDay = gk and gk.GetSiegeMinuteOfDay and gk:GetSiegeMinuteOfDay(time()) or nil
    if not minuteOfDay and GetGameTime then
        local h, m = GetGameTime()
        if h and m then minuteOfDay = h * 60 + m end
    end
    if not minuteOfDay then
        local d = date("*t", time())
        minuteOfDay = (tonumber(d.hour) or 0) * 60 + (tonumber(d.min) or 0)
    end
    return minuteOfDay
end

local function IsCutoffReportDelayElapsed(gk)
    if not gk or not gk.GetSiegeWindowEndMinute then return true end
    local delayMinute = math.ceil(POST_CUTOFF_REPORT_DELAY_SEC / 60)
    local minuteOfDay = GetSiegeMinuteOfDayNow(gk)
    return minuteOfDay >= gk:GetSiegeWindowEndMinute() + delayMinute
end

-- Chat Keep post-siege autorise seulement pendant une courte fenetre apres la cutoff.
function GKI:IsPostCutoffKeepChatAllowed(gk)
    gk = gk or GetGK()
    if not gk or not gk.GetSiegeWindowEndMinute then return false end
    if gk.IsSiegeWindowOpen and gk:IsSiegeWindowOpen() then return true end
    if not gk.IsSiegeWindowClosedForToday or not gk:IsSiegeWindowClosedForToday() then
        return false
    end
    local minuteOfDay = GetSiegeMinuteOfDayNow(gk)
    local minutesPastEnd = minuteOfDay - gk:GetSiegeWindowEndMinute()
    if minutesPastEnd < 0 then return false end
    return (minutesPastEnd * 60) <= POST_CUTOFF_CHAT_MAX_SEC
end

local function CapturingFactionLabel(fac)
    local loc = L()
    if fac == "Alliance" then return (loc and loc.THE_ALLIANCE) or "the Alliance" end
    if fac == "Horde" then return (loc and loc.THE_HORDE) or "the Horde" end
    return fac or ""
end

local function GetServerMinuteOfDay(ts)
    local gk = Overlord.GuildKeep
    if gk and gk.GetSiegeMinuteOfDay then
        return gk:GetSiegeMinuteOfDay(ts)
    end
    if GetGameTime then
        local h, m = GetGameTime()
        if h and m then return h * 60 + m end
    end
    local d = date("*t", time())
    return (tonumber(d.hour) or 0) * 60 + (tonumber(d.min) or 0)
end

local function IsOathEnabled()
    if not OverlordDB or not OverlordDB.config then return true end
    if OverlordDB.config.guildKeepOathEnabled == false then return false end
    return true
end

function GKI:EnsureDB()
    if not OverlordDB then return false end
    local epoch = GetCampaignEpoch()
    -- Seule une table reellement neuve est deja native v7. Une table persistante
    -- sans marqueur doit rester intacte ici : RestoreKeeps la reconnaitra comme
    -- narrative legacy et purgera une fois ses terminaux pre-v7 au prochain login.
    local created = type(OverlordDB.guildKeepImmersion) ~= "table"
    if created then
        OverlordDB.guildKeepImmersion = { protocolVersion = 7 }
    end
    local db = OverlordDB.guildKeepImmersion
    if (tonumber(db.epoch) or 0) ~= epoch then
        db.epoch = epoch
        db.chronicles = {}
        db.oathSeen = {}
        db.vigilDay = nil
        db.siegeOpenAssaultDay = nil
        db.siegeReportDay = nil
        db.siegeReportSyncDay = nil
        db.siegeReportSyncRequestedAt = nil
        db.siegeReportPendingSince = nil
        db.siegeReportPendingTryAt = nil
        db.activeSiege = {}
    end
    db.chronicles = db.chronicles or {}
    db.oathSeen = db.oathSeen or {}
    db.activeSiege = db.activeSiege or {}
    return true
end

function GKI:EnsureChronicle(siteKey)
    if not self:EnsureDB() then return nil end
    local ch = OverlordDB.guildKeepImmersion.chronicles[siteKey]
    if not ch then
        ch = {
            guild = "",
            faction = "",
            heldSince = 0,
            daysHeld = 0,
            lastSiegeDay = "",
            lastOutcome = "",
            lastAssaultGuild = "",
        }
        OverlordDB.guildKeepImmersion.chronicles[siteKey] = ch
    end
    return ch
end

function GKI:GetActiveSiege(siteKey)
    if not self:EnsureDB() then return nil end
    local gk = GetGK()
    local dayKey = gk and gk.GetServerSiegeDayKey and gk:GetServerSiegeDayKey() or ""
    local siege = OverlordDB.guildKeepImmersion.activeSiege[siteKey]
    if not siege or siege.dayKey ~= dayKey then
        siege = {
            dayKey = dayKey,
            assaultGuild = "",
            assaultFaction = nil,
            defenderGuild = "",
            inProgress = false,
            outcome = nil,
        }
        OverlordDB.guildKeepImmersion.activeSiege[siteKey] = siege
    end
    return siege
end

local function ResolveSiegeDefenderGuild(st, siteKey)
    if not st then return "" end
    local gk = GetGK()
    if gk and gk.GetKeepDisplayTenant then
        local official = SanitizeGuild(select(1, gk:GetKeepDisplayTenant(st, siteKey)) or "")
        if official ~= "" then return official end
    end
    if st.status == "in_progress" then
        local prev = SanitizeGuild(st.previousOwnerGuild or "")
        if prev ~= "" then return prev end
    elseif st.status == "held" then
        local holder = SanitizeGuild(st.ownerGuild or "")
        if holder ~= "" then return holder end
    end
    return ""
end

local function NormalizeReportFaction(faction)
    if faction == "Alliance" or faction == "Horde" then return faction end
    return ""
end

local function BuildSiegeReportVisibleSignature(outcome, guild)
    if outcome ~= "captured" and outcome ~= "defended" and outcome ~= "neutral" then
        outcome = "defended"
    end
    -- La guilde n'apparait que dans la phrase de capture. La faction n'apparait jamais :
    -- ses enrichissements/corrections reseau ne doivent donc pas rouvrir le meme chat.
    local visibleGuild = outcome == "captured" and SanitizeGuild(guild):lower() or ""
    return outcome .. "\31" .. visibleGuild
end

local function RememberAnnouncedSiegeReport(siege, outcome, guild)
    if type(siege) ~= "table" then return false end
    local signature = BuildSiegeReportVisibleSignature(outcome, guild)
    local announced = siege.reportAnnouncedSignatures
    if type(announced) ~= "table" then
        announced = {}
        siege.reportAnnouncedSignatures = announced
    end
    if announced[signature] then return false end
    if siege.reportAnnouncementsSaturated then return false end
    local count = 0
    for _, seen in pairs(announced) do
        if seen then count = count + 1 end
    end
    if count >= SIEGE_REPORT_ANNOUNCED_SIGNATURES_MAX then
        siege.reportAnnouncementsSaturated = true
        return false
    end
    announced[signature] = true
    return true
end

local function RememberPublishedSiegeReport(siege, outcome, guild, faction)
    if type(siege) ~= "table" or not siege.reportPublished then return false end
    if outcome ~= "captured" and outcome ~= "defended" and outcome ~= "neutral" then
        outcome = "defended"
    end
    guild = SanitizeGuild(guild)
    faction = NormalizeReportFaction(faction)
    local changed = siege.reportPublishedOutcome ~= outcome
        or SanitizeGuild(siege.reportPublishedGuild or "") ~= guild
        or NormalizeReportFaction(siege.reportPublishedFaction) ~= faction
    siege.reportPublishedOutcome = outcome
    siege.reportPublishedGuild = guild
    siege.reportPublishedFaction = faction
    return changed
end

local function BackfillPublishedSiegeReport(siege)
    if type(siege) ~= "table" or not siege.reportPublished then return false end
    local outcome = siege.reportPublishedOutcome
    if outcome ~= "captured" and outcome ~= "defended" and outcome ~= "neutral" then
        if siege.outcome == "captured" or siege.outcome == "neutral" then
            outcome = siege.outcome
        else
            outcome = "defended"
        end
    end
    local guild = SanitizeGuild(siege.reportPublishedGuild or "")
    local faction = NormalizeReportFaction(siege.reportPublishedFaction)
    if guild == "" then
        if outcome == "captured" then
            guild = SanitizeGuild(siege.assaultGuild or "")
        else
            guild = SanitizeGuild(siege.defenderGuild or "")
        end
    end
    if faction == "" and outcome == "captured" then
        faction = NormalizeReportFaction(siege.assaultFaction)
    end
    local changed = RememberPublishedSiegeReport(siege, outcome, guild, faction)
    -- Migration transparente des rapports 9.9.6 deja affiches : si une correction les
    -- rouvre apres /reload, leur phrase reste one-shot.
    if RememberAnnouncedSiegeReport(siege, outcome, guild) then changed = true end
    return changed
end

local function PublishedSiegeReportDiffers(siege, outcome, guild)
    if type(siege) ~= "table" or not siege.reportPublished then return false end
    local publishedOutcome = siege.reportPublishedOutcome
    local publishedGuild = SanitizeGuild(siege.reportPublishedGuild or "")
    guild = SanitizeGuild(guild)
    if publishedOutcome ~= "" and publishedOutcome ~= outcome then return true end
    -- Seule une difference visible justifie une nouvelle phrase. Les variantes de casse
    -- de guilde et les corrections de faction continuent a converger dans les metadonnees.
    return outcome == "captured" and publishedGuild ~= ""
        and publishedGuild:lower() ~= guild:lower()
end

local function ReopenPublishedSiegeReport(siege)
    if type(siege) ~= "table" or not siege.reportPublished then return false end
    siege.reportPublished = false
    siege.reportPublishedOutcome = nil
    siege.reportPublishedGuild = nil
    siege.reportPublishedFaction = nil
    local db = OverlordDB and OverlordDB.guildKeepImmersion
    if type(db) == "table" then
        db.siegeReportDay = nil
        db.siegeReportSyncDay = nil
        db.siegeReportSyncRequestedAt = nil
        db.siegeReportPendingSince = nil
        db.siegeReportPendingTryAt = nil
    end
    return true
end

function GKI:OnSiegeAssaultBegan(siteKey, assaultGuild, assaultFaction)
    if not siteKey then return end
    local siege = self:GetActiveSiege(siteKey)
    if not siege then return end
    siege.inProgress = true
    siege.outcome = nil
    assaultGuild = SanitizeGuild(assaultGuild)
    if assaultGuild ~= "" then
        siege.assaultGuild = assaultGuild
    end
    if assaultFaction then siege.assaultFaction = assaultFaction end
    local gk = GetGK()
    local st = gk and gk.GetState and gk:GetState(siteKey)
    local defender = ResolveSiegeDefenderGuild(st, siteKey)
    if defender ~= "" then
        siege.defenderGuild = defender
    end
end

function GKI:OnKeepCaptured(siteKey, guild, faction, prevGuild, prevFaction, captureTs)
    local gk = GetGK()
    if not gk or not siteKey then return end
    guild = SanitizeGuild(guild)
    if guild == "" then return end
    captureTs = tonumber(captureTs) or time()
    local captureDay = gk:GetServerSiegeDayKey(captureTs)
    local currentDay = gk:GetServerSiegeDayKey()
    local ch = self:EnsureChronicle(siteKey)
    if not ch then return end
    -- Une correction de lignee historique peut rejouer CompleteCapture aujourd'hui.
    -- Elle peut enrichir la chronique dans l'ordre, jamais creer l'activeSiege du jour
    -- ni faire reculer une chronique plus recente.
    if ch.lastSiegeDay ~= "" and captureDay < ch.lastSiegeDay then return false end
    ch.guild = guild
    ch.faction = faction or ""
    ch.heldSince = captureTs
    ch.daysHeld = 1
    ch.lastOutcome = "captured"
    ch.lastSiegeDay = captureDay
    ch.lastAssaultGuild = SanitizeGuild(prevGuild)
    if captureDay ~= currentDay then
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        return true
    end
    local siege = self:GetActiveSiege(siteKey)
    if siege then
        -- Un GC plus tardif est la verite canonique, meme si ce client avait suivi
        -- auparavant l'assaillant d'un autre shard.
        BackfillPublishedSiegeReport(siege)
        local reportChanged = PublishedSiegeReportDiffers(
            siege, "captured", guild)
        siege.assaultGuild = guild
        siege.assaultFaction = NormalizeReportFaction(faction)
        siege.inProgress = false
        siege.outcome = "captured"
        local prevG = SanitizeGuild(prevGuild)
        if prevG ~= "" then
            siege.defenderGuild = prevG
        end
        if reportChanged then
            ReopenPublishedSiegeReport(siege)
        elseif siege.reportPublished then
            RememberPublishedSiegeReport(siege, "captured", guild, faction)
        end
    end
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    return true
end

function GKI:OnDailyDefense(siteKey, guild, faction, defenseTs, tenantClaimedAt, resolutionKind)
    local gk = GetGK()
    if not gk or not siteKey then return end
    guild = SanitizeGuild(guild)
    if guild == "" then return end
    local ch = self:EnsureChronicle(siteKey)
    if not ch then return end
    defenseTs = math.floor(tonumber(defenseTs) or time())
    local dayKey = gk:GetServerSiegeDayKey(defenseTs)
    if ch.lastSiegeDay ~= "" and ch.lastSiegeDay > dayKey then return false end
    local siege = OverlordDB and OverlordDB.guildKeepImmersion
        and OverlordDB.guildKeepImmersion.activeSiege
        and OverlordDB.guildKeepImmersion.activeSiege[siteKey] or nil
    local matchingSiege = siege and siege.dayKey == dayKey and siege or nil
    local alreadyCapturedToday = ch.lastSiegeDay == dayKey and ch.lastOutcome == "captured"
    tenantClaimedAt = math.floor(tonumber(tenantClaimedAt) or 0)
    local tenantWasCapturedToday = tenantClaimedAt > 0
        and gk:GetServerSiegeDayKey(tenantClaimedAt) == dayKey
    -- Le claimedAt de la base peut etre aujourd'hui : un GA qui la restaure reste une
    -- defense, pas une seconde capture. Le kind vient de la preuve GH canonique.
    if tenantWasCapturedToday and resolutionKind ~= "GA" then
        local sameCapturedChronicle = alreadyCapturedToday
            and SanitizeGuild(ch.guild or ""):lower() == guild:lower()
            and math.floor(tonumber(ch.heldSince) or 0) == tenantClaimedAt
        local sameCapturedSiege = matchingSiege
            and matchingSiege.outcome == "captured" and not matchingSiege.inProgress
            and SanitizeGuild(matchingSiege.assaultGuild or ""):lower() == guild:lower()
        -- MaybeAward repasse toutes les 30 s. Ne pas reinitialiser chronique, morts et
        -- rapport si ce GC exact a deja ete projete ; une narrative absente reste reparable.
        if sameCapturedChronicle and sameCapturedSiege then return false end
        local prevGuild = matchingSiege and SanitizeGuild(matchingSiege.defenderGuild or "") or ""
        self:OnKeepCaptured(siteKey, guild, faction, prevGuild, nil, tenantClaimedAt)
        return true
    end
    -- Un GA tardif peut annuler une capture deja chroniquee et restaurer exactement
    -- le defenseur de la tenure attaquee. Les autres doublons de cutoff restent ignores.
    local defenderGuild = matchingSiege and SanitizeGuild(matchingSiege.defenderGuild or "") or ""
    local revertedCapture = alreadyCapturedToday and (resolutionKind == "GA"
        or (defenderGuild ~= "" and guild == defenderGuild))
    if alreadyCapturedToday and resolutionKind ~= "GA" and not revertedCapture then return false end
    local reportBackfilled = matchingSiege
        and BackfillPublishedSiegeReport(matchingSiege) or false
    local alreadyDefendedToday = ch.lastSiegeDay == dayKey and ch.lastOutcome == "defended"
    local changed = reportBackfilled
    if not alreadyDefendedToday then
        if ch.guild == guild then
            -- Une capture puis sa restauration causale le meme jour ne vaut pas deux jours.
            if not revertedCapture then
                ch.daysHeld = math.max(1, (tonumber(ch.daysHeld) or 0) + 1)
            end
        else
            ch.guild = guild
            ch.faction = faction or ""
            ch.daysHeld = 1
            ch.heldSince = tenantClaimedAt > 0 and tenantClaimedAt or defenseTs
        end
        ch.lastSiegeDay = dayKey
        ch.lastOutcome = "defended"
        changed = true
    end
    -- Ne poser "defended" / reopen que si le tenant officiel est deja le defenseur.
    -- Sinon un GH premature desarme outcome et force une boucle de republish.
    local official = gk.GetOfficialKeepTenant and gk:GetOfficialKeepTenant(siteKey) or nil
    local holderGuild = SanitizeGuild(official and official.guild or "")
    local officialIsDefender = holderGuild ~= "" and holderGuild == guild
    if matchingSiege and officialIsDefender
        and (matchingSiege.outcome ~= "defended" or matchingSiege.inProgress) then
        matchingSiege.outcome = "defended"
        matchingSiege.inProgress = false
        changed = true
    end
    if matchingSiege and officialIsDefender and PublishedSiegeReportDiffers(
        matchingSiege, "defended", guild) then
        ReopenPublishedSiegeReport(matchingSiege)
        changed = true
    elseif matchingSiege and officialIsDefender and matchingSiege.reportPublished then
        if RememberPublishedSiegeReport(matchingSiege, "defended", guild, faction) then
            changed = true
        end
    end
    if not alreadyDefendedToday then
        ch.lastAssaultGuild = matchingSiege and matchingSiege.assaultGuild or ""
    end
    if changed and Overlord.MarkDirty then Overlord:MarkDirty() end
    return changed
end

function GKI:BuildRumorLine(siteKey, st)
    local loc = L()
    if not loc or not loc.GUILD_KEEP_RUMOR_ENEMY then return nil end
    local pf = Overlord.PlayerFaction
    local gk = GetGK()
    local official = gk and gk.GetOfficialKeepTenant and gk:GetOfficialKeepTenant(siteKey)
    -- Aucun fallback narratif vers le cache held : seul un terminal v8 accepté peut
    -- affirmer quelle faction contrôle réellement le keep.
    if not pf or not official then return nil end
    local holderFac = official.faction
    if not holderFac or holderFac == pf then return nil end
    return string.format(loc.GUILD_KEEP_RUMOR_ENEMY, GetSiteDisplayName(siteKey))
end

function GKI:AppendKeepTooltipLines(st, site, siteKey)
    if not st or not siteKey then return end
    local loc = L()
    local tp = Overlord.UI and Overlord.UI.TooltipPalette and Overlord.UI.TooltipPalette()
    local mr, mg, mb = 0.55, 0.55, 0.6
    if tp and tp.MUTED then
        mr, mg, mb = tp.MUTED[1], tp.MUTED[2], tp.MUTED[3]
    end
    local gk = GetGK()
    if st.status == "in_progress" and gk and loc
        and gk.IsSiegeWindowOpen and gk:IsSiegeWindowOpen() then
        local summary = gk.GetKeepSiegeSummary and gk:GetKeepSiegeSummary(st, siteKey) or nil
        local defenderGuild = summary and summary.defenderGuild or ""
        local assaultGuild = (summary and summary.assaultGuild) or SanitizeGuild(st.ownerGuild or "")
        GameTooltip:AddLine(" ")
        if defenderGuild ~= "" and loc.GUILD_KEEP_TOOLTIP_DEFENDER then
            GameTooltip:AddLine(string.format(loc.GUILD_KEEP_TOOLTIP_DEFENDER, defenderGuild),
                tp and tp.BODY and tp.BODY[1] or 1, tp and tp.BODY and tp.BODY[2] or 1,
                tp and tp.BODY and tp.BODY[3] or 1)
        end
        if assaultGuild ~= "" and loc.GUILD_KEEP_TOOLTIP_ASSAULT_GUILD then
            GameTooltip:AddLine(string.format(loc.GUILD_KEEP_TOOLTIP_ASSAULT_GUILD, assaultGuild),
                1, 0.55, 0.2)
        end
        local capturer = gk.GetEffectiveCapturerName and gk:GetEffectiveCapturerName(st) or ""
        if capturer ~= "" and loc.GUILD_KEEP_TOOLTIP_CAPTURER then
            local shard = gk.GetEffectiveCapturerShard and gk:GetEffectiveCapturerShard(st)
            local label = capturer
            if shard and loc.SHARD_ALERT_TAG then
                label = capturer .. string.format(loc.SHARD_ALERT_TAG, tostring(shard))
            end
            GameTooltip:AddLine(string.format(loc.GUILD_KEEP_TOOLTIP_CAPTURER, label),
                tp and tp.BODY and tp.BODY[1] or 1, tp and tp.BODY and tp.BODY[2] or 1,
                tp and tp.BODY and tp.BODY[3] or 1)
        end
        return
    elseif st.status == "held" and gk and gk.IsSiegeWindowOpen and gk:IsSiegeWindowOpen()
        and gk.CanPlayerContestKeep and gk:CanPlayerContestKeep(st, siteKey) and loc
        and loc.GUILD_KEEP_SIEGE_OPEN_HINT then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(loc.GUILD_KEEP_SIEGE_OPEN_HINT, 1, 0.82, 0.2)
    end
    -- Plus de chronique locale au tooltip : source divergente du tenant live et du ladder.
    local rumor = self:BuildRumorLine(siteKey, st)
    if rumor and rumor ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(rumor, mr, mg, mb, true)
    end
end

function GKI:PrintHeraldCapture(siteKey, guild, faction)
    local loc = L()
    if not loc or not Overlord.PrintNotification then return end
    local where = GetSiteDisplayName(siteKey)
    guild = SanitizeGuild(guild)
    if guild == "" then return end
    local pf = Overlord.PlayerFaction
    if pf and faction == pf and loc.GUILD_KEEP_HERALD_FRIENDLY then
        Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. loc.GUILD_KEEP_HERALD_FRIENDLY,
            where, guild))
    elseif loc.GUILD_KEEP_HERALD_ENEMY then
        local facLabel = CapturingFactionLabel(faction)
        Overlord:PrintNotification(string.format("|cFFFF4444[Overlord]|r " .. loc.GUILD_KEEP_HERALD_ENEMY,
            where, guild, facLabel))
    end
end

local function ShowOathRaidWarning(siteKey)
    local loc = L()
    if not loc or not loc.GUILD_KEEP_OATH then return false end
    local msg = string.format(loc.GUILD_KEEP_OATH, GetSiteDisplayName(siteKey))
    if Overlord.PrintRaidWarning then
        Overlord:PrintRaidWarning(msg)
        return true
    end
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. msg)
        return true
    end
    return false
end

function GKI:TryOathOnKeepEntry(siteKey, site, st)
    if not IsOathEnabled() or not siteKey or not site then return end
    local gk = GetGK()
    if not gk or not gk.IsPlayerKeepAssailant or not gk:IsPlayerKeepAssailant(st) then return end
    if st.status ~= "in_progress" then return end
    if not self:EnsureDB() then return end
    local oathKey = tostring(GetCampaignEpoch()) .. ":" .. siteKey
    if OverlordDB.guildKeepImmersion.oathSeen[oathKey] then return end
    OverlordDB.guildKeepImmersion.oathSeen[oathKey] = true
    ShowOathRaidWarning(siteKey)
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

local lastOathInGeom = {}

function GKI:OnKeepPositionCheck(siteKey, site, st, inGeometry)
    local wasIn = lastOathInGeom[siteKey] and true or false
    if inGeometry and not wasIn then
        self:TryOathOnKeepEntry(siteKey, site, st)
    end
    lastOathInGeom[siteKey] = inGeometry and true or false
end

function GKI:TryVigilMessages()
    local gk = GetGK()
    local loc = L()
    if not gk or not loc or not gk.GetSiegeReminderStartMinute then return end
    if Overlord.InstanceSuspended then return end
    local minute = GetServerMinuteOfDay()
    if minute < gk:GetSiegeReminderStartMinute() or minute >= gk:GetSiegeWindowStartMinute() then
        return
    end
    if not self:EnsureDB() then return end
    local dayKey = gk:GetServerSiegeDayKey()
    if OverlordDB.guildKeepImmersion.vigilDay == dayKey then return end

    local pf = Overlord.PlayerFaction
    local localGuild = gk.GetLocalPlayerGuild and gk:GetLocalPlayerGuild() or ""
    local siegeStart = GetSiegeStartLabel()
    local sent = false

    -- Une alerte par fortin concerne. L'ancien verrou global `sentFaction` ne gardait
    -- que le premier site d'un parcours `pairs` non deterministe (Badlands disparaissait
    -- donc regulierement des annonces au profit d'un autre fortin allie).
    for _, site in ipairs(gk:GetSortedSiteList()) do
        local siteKey = site.siteKey
        local st = gk:GetState(siteKey)
        if st and st.status == "held" then
            local holderGuild, holderFaction = "", nil
            if gk.GetKeepDisplayTenant then
                holderGuild, holderFaction = gk:GetKeepDisplayTenant(st, siteKey)
                holderGuild = SanitizeGuild(holderGuild or "")
            end
            local where = GetSiteDisplayName(siteKey)
            if holderGuild ~= "" and localGuild ~= "" and holderGuild == localGuild
                and loc.GUILD_KEEP_VIGIL_HOLDER and Overlord.PrintNotification then
                Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. loc.GUILD_KEEP_VIGIL_HOLDER,
                    where, siegeStart))
                sent = true
            elseif pf and holderFaction == pf
                and loc.GUILD_KEEP_VIGIL_FACTION and Overlord.PrintNotification then
                Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r " .. loc.GUILD_KEEP_VIGIL_FACTION,
                    where, holderGuild))
                sent = true
            end
        end
    end
    if sent then
        OverlordDB.guildKeepImmersion.vigilDay = dayKey
        if Overlord.MarkDirty then Overlord:MarkDirty() end
    end
end

local function HasSiegeReportActivity(siege)
    if type(siege) ~= "table" then return false end
    if siege.inProgress or siege.outcome then return true end
    return SanitizeGuild(siege.assaultGuild or "") ~= ""
end

local function IsExactNeutralAbortForSiege(gk, st, siege)
    if not gk or not st or type(siege) ~= "table"
        or not gk.GetCurrentTerminalProof or not gk.GetServerSiegeDayKey then return false end
    local terminal = gk:GetCurrentTerminalProof(st)
    if not terminal or terminal.kind ~= "GA"
        or SanitizeGuild(terminal.baseGuild or "") ~= "" then return false end
    local eventAt = math.floor(tonumber(terminal.eventAt) or 0)
    return eventAt > 0 and gk:GetServerSiegeDayKey(eventAt) == siege.dayKey
end

function GKI:ResolveSiegeReportOutcome(siteKey, st, siege)
    local gk = GetGK()
    -- Une absence de tenant n'est normalement pas une preuve. L'exception est un terminal
    -- GA exact du meme jour restaurant explicitement la base neutre.
    if IsExactNeutralAbortForSiege(gk, st, siege) then
        return false, "", "", true
    end
    local holderGuild = ""
    local holderFaction = ""
    if gk and gk.GetOfficialKeepTenant then
        local official = gk:GetOfficialKeepTenant(siteKey)
        holderGuild = SanitizeGuild(official and official.guild or "")
        holderFaction = NormalizeReportFaction(official and official.faction)
    end
    -- Pas de bilan tant que le terminal terrain v8 n'a pas converge. Une chronique
    -- locale ou un cache held ne doit jamais nommer le vainqueur a sa place.
    if holderGuild == "" then return nil, "", "" end
    local assaultGuild = siege and SanitizeGuild(siege.assaultGuild or "") or ""
    local defenderGuild = siege and SanitizeGuild(siege.defenderGuild or "") or ""
    if defenderGuild == "" and st and st.status == "in_progress" then
        defenderGuild = SanitizeGuild(st.previousOwnerGuild or "")
    end
    local outcome = siege and siege.outcome or nil
    if outcome == "captured" then
        -- Une capture locale/GC connue mais pas encore visible dans l'officiel doit
        -- attendre la projection v8, jamais etre renommee avec l'ancien tenant.
        if assaultGuild ~= "" and holderGuild ~= assaultGuild then return nil, "", "" end
        return true, holderGuild, holderFaction
    end
    -- Une defense settled vient de la preuve quotidienne GA canonique, posee seulement
    -- quand l'officiel est deja le defenseur. Elle prime donc sur les champs narratifs
    -- assault/defender, qui peuvent encore decrire un autre shard. Sinon un assaultGuild
    -- stale egal au tenant reclassait le GA en capture toutes les 15 s et rouvrait le chat.
    if outcome == "defended" and not (siege and siege.inProgress) then
        return false, holderGuild, holderFaction
    end
    if defenderGuild ~= "" then
        if holderGuild ~= defenderGuild then return true, holderGuild, holderFaction end
        -- L'ancien defenseur encore officiel n'est pas une preuve de defense : un
        -- GC de capture peut simplement etre en retard.
        return nil, "", ""
    end
    if assaultGuild ~= "" and assaultGuild == holderGuild then
        return true, holderGuild, holderFaction
    end
    return nil, "", ""
end

function GKI:PublishSiegeReport(siteKey, st, guild, faction)
    local loc = L()
    if not loc or not Overlord.PrintNotification then return false end
    local siege = self:GetActiveSiege(siteKey)
    if not siege then return false end
    if siege.reportPublished then return false end
    if not HasSiegeReportActivity(siege) then return false end
    local where = GetSiteDisplayName(siteKey)
    local wasCapture, reportGuild, reportFaction, wasNeutral =
        self:ResolveSiegeReportOutcome(siteKey, st, siege)
    if wasCapture == nil or (not wasNeutral and reportGuild == "") then return nil end
    if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
        print(string.format(
            "|cFFFF4444[Overlord:dbg]|r PublishSiegeReport %s: st.status=%s st.ownerGuild=%s st.updatedAt=%s "
            .. "siege.outcome=%s siege.assaultGuild=%s -> wasCapture=%s reportGuild=%s",
            tostring(siteKey), tostring(st and st.status), tostring(st and st.ownerGuild),
            tostring(st and st.updatedAt), tostring(siege.outcome), tostring(siege.assaultGuild),
            tostring(wasCapture), tostring(reportGuild)))
    end
    local msg
    local publishedOutcome
    if wasNeutral then
        publishedOutcome = "neutral"
        msg = string.format("%s: %s.", where,
            (loc and loc.GUILD_KEEP_NEUTRAL) or "Unclaimed")
    elseif wasCapture then
        publishedOutcome = "captured"
        msg = string.format(loc.GUILD_KEEP_SIEGE_REPORT_CAPTURED or "%s captured by %s.",
            where, reportGuild)
    else
        publishedOutcome = "defended"
        msg = string.format(loc.GUILD_KEEP_SIEGE_REPORT_DEFENDED or "%s held the walls.",
            where)
    end
    -- Toujours aligner outcome local sur ce qui est annonce (evite reopen/spam 1 Hz).
    siege.outcome = publishedOutcome
    siege.inProgress = false
    -- Hors fenetre post-cutoff : sceller sans chat (login / sync 1 h plus tard).
    if self:IsPostCutoffKeepChatAllowed(GetGK())
        and RememberAnnouncedSiegeReport(siege, publishedOutcome, reportGuild) then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. msg)
    end
    siege.reportPublished = true
    RememberPublishedSiegeReport(siege, publishedOutcome, reportGuild, reportFaction)
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    return true
end

function GKI:TrySiegeBattleReports()
    local gk = GetGK()
    if not gk or not gk.IsSiegeWindowClosedForToday or not gk:IsSiegeWindowClosedForToday() then return end
    -- Attendre la grace GC post-fenetre avant le bilan : sinon un GC tardif
    -- laisse "defendu" alors que le tenant a deja change.
    if not IsCutoffReportDelayElapsed(gk) then return end
    if Overlord.InstanceSuspended then return end
    if not self:EnsureDB() then return end
    local dayKey = gk:GetServerSiegeDayKey()
    local immersionDb = OverlordDB.guildKeepImmersion
    if immersionDb.siegeReportDay == dayKey then
        local needsReopen = false
        local reportMetadataChanged = false
        for siteKey, siege in pairs(immersionDb.activeSiege or {}) do
            if siege and siege.dayKey == dayKey and HasSiegeReportActivity(siege)
                and not siege.reportPublished then
                needsReopen = true
            end
            if siege and siege.reportPublished and siege.dayKey == dayKey then
                if BackfillPublishedSiegeReport(siege) then
                    reportMetadataChanged = true
                end
                -- Une capture deja annoncee ne reste valide que tant que le terminal
                -- officiel nomme encore la meme guilde. Cela couvre aussi un GA qui
                -- restaure le defenseur et un GC concurrent arrive apres le cutoff.
                local official = gk:GetOfficialKeepTenant(siteKey)
                local holderGuild = SanitizeGuild(official and official.guild or "")
                local holderFaction = NormalizeReportFaction(official and official.faction)
                local publishedGuild = SanitizeGuild(siege.reportPublishedGuild or "")
                local defenderGuild = SanitizeGuild(siege.defenderGuild or "")
                if siege.reportPublishedOutcome == "captured"
                    and publishedGuild ~= "" and holderGuild ~= ""
                    and (holderGuild ~= publishedGuild
                        or (holderFaction ~= "" and NormalizeReportFaction(
                            siege.reportPublishedFaction) ~= holderFaction)) then
                    if defenderGuild ~= "" and holderGuild == defenderGuild then
                        siege.outcome = "defended"
                        siege.inProgress = false
                    else
                        siege.outcome = "captured"
                        siege.assaultGuild = holderGuild
                        siege.assaultFaction = holderFaction
                    end
                end
                local st = gk:GetState(siteKey)
                local wasCapture, reportGuild, reportFaction, wasNeutral =
                    self:ResolveSiegeReportOutcome(siteKey, st, siege)
                local outcome
                if wasNeutral then
                    outcome = "neutral"
                elseif wasCapture ~= nil then
                    outcome = wasCapture and "captured" or "defended"
                end
                local reportChanged = outcome and PublishedSiegeReportDiffers(
                    siege, outcome, reportGuild)
                if reportChanged then
                    -- Signature chat vraiment differente (autre guilde / outcome) : republier.
                    if ReopenPublishedSiegeReport(siege) then
                        needsReopen = true
                    end
                else
                    -- Signature deja correcte : coller outcome local sans republier
                    -- (evite la boucle captured publie + outcome defended force-reopen).
                    if outcome and siege.outcome ~= outcome then
                        siege.outcome = outcome
                        siege.inProgress = false
                        reportMetadataChanged = true
                    end
                    if outcome and RememberPublishedSiegeReport(
                        siege, outcome, reportGuild, reportFaction) then
                        reportMetadataChanged = true
                    end
                end
            end
        end
        if not needsReopen then
            if reportMetadataChanged and Overlord.MarkDirty then Overlord:MarkDirty() end
            return
        end
        immersionDb.siegeReportDay = nil
        if Overlord.MarkDirty then Overlord:MarkDirty() end
    end
    local hasAnyReport = false
    for _, siege in pairs(immersionDb.activeSiege or {}) do
        if siege and siege.dayKey == dayKey and HasSiegeReportActivity(siege) then
            hasAnyReport = true
            break
        end
    end
    if not hasAnyReport then
        immersionDb.siegeReportDay = dayKey
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        return
    end

    local syncNow = time()
    -- Borne le poll pendingCanonical : retry ~8 s, abandon ~10 min.
    local pendingSince = tonumber(immersionDb.siegeReportPendingSince) or 0
    if pendingSince > 0 then
        if syncNow - pendingSince >= PENDING_CANONICAL_ABANDON_SEC then
            immersionDb.siegeReportDay = dayKey
            immersionDb.siegeReportPendingSince = nil
            immersionDb.siegeReportPendingTryAt = nil
            if Overlord.MarkDirty then Overlord:MarkDirty() end
            return
        end
        local lastTry = tonumber(immersionDb.siegeReportPendingTryAt) or 0
        if syncNow - lastTry < PENDING_CANONICAL_RETRY_SEC then
            return
        end
    end

    -- Le terminal est normalement deja canonique apres la grace de cutoff. Publier
    -- d'abord evite que chaque client sain declenche la meme SR complete a 22 h.
    local pendingCanonicalTenant = false
    for siteKey in pairs(Overlord.GuildKeepSites or {}) do
        local st = gk:GetState(siteKey)
        local siege = OverlordDB.guildKeepImmersion.activeSiege[siteKey]
        if siege and siege.dayKey == dayKey then
            local published = self:PublishSiegeReport(siteKey, st)
            if published == nil then
                pendingCanonicalTenant = true
            end
        end
    end
    if not pendingCanonicalTenant then
        immersionDb.siegeReportPendingSince = nil
        immersionDb.siegeReportPendingTryAt = nil
        immersionDb.siegeReportDay = dayKey
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        return
    end

    -- Uniquement si une chronique reste sans tenant canonique : petite SR territoriale
    -- (ZA/GK/GC/GA), jamais la file leaderboard/GH complete.
    if immersionDb.siegeReportSyncDay ~= dayKey then
        immersionDb.siegeReportSyncDay = dayKey
        immersionDb.siegeReportSyncRequestedAt = syncNow
        if Overlord.Sync and Overlord.Sync.SendSyncRequest then
            Overlord.Sync:SendSyncRequest({
                includeCommunity = true,
                allowCommunityInLargeEvent = true,
                criticalChannel = true,
                territorialOnly = true,
            })
        end
        if Overlord.MarkDirty then Overlord:MarkDirty() end
        return
    end
    local syncRequestedAt = tonumber(immersionDb.siegeReportSyncRequestedAt) or 0
    if syncRequestedAt > 0 and syncNow - syncRequestedAt < POST_CUTOFF_REPORT_SYNC_SETTLE_SEC then
        return
    end

    immersionDb.siegeReportPendingSince = pendingSince > 0 and pendingSince or syncNow
    immersionDb.siegeReportPendingTryAt = syncNow
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

function GKI:TrySiegeOpenAssaultMessages()
    local gk = GetGK()
    local loc = L()
    if not gk or not loc or not gk.IsSiegeWindowOpen or not gk:IsSiegeWindowOpen() then return end
    if Overlord.InstanceSuspended then return end
    local minute = GetServerMinuteOfDay()
    local startMinute = gk:GetSiegeWindowStartMinute()
    if minute < startMinute or minute >= startMinute + 3 then return end
    if not self:EnsureDB() then return end
    local dayKey = gk:GetServerSiegeDayKey()
    if OverlordDB.guildKeepImmersion.siegeOpenAssaultDay == dayKey then return end

    local pf = Overlord.PlayerFaction
    if not pf then return end
    local sent = false
    for siteKey in pairs(Overlord.GuildKeepSites or {}) do
        local st = gk:GetState(siteKey)
        local holder, holderFaction = "", nil
        if st and gk.GetKeepDisplayTenant then
            holder, holderFaction = gk:GetKeepDisplayTenant(st, siteKey)
            holder = SanitizeGuild(holder or "")
        end
        local contestView = { status = "held", ownerGuild = holder, ownerFaction = holderFaction }
        if st and st.status == "held" and holderFaction and holderFaction ~= pf
            and gk.CanPlayerContestKeep and gk:CanPlayerContestKeep(contestView, siteKey)
            and loc.GUILD_KEEP_SIEGE_OPEN_ASSAULT then
            local where = GetSiteDisplayName(siteKey)
            if holder ~= "" then
                Overlord:PrintNotification(string.format("|cFFFFD100[Overlord]|r "
                    .. loc.GUILD_KEEP_SIEGE_OPEN_ASSAULT, where, holder))
                sent = true
            end
        end
    end
    if sent then
        OverlordDB.guildKeepImmersion.siegeOpenAssaultDay = dayKey
        if Overlord.MarkDirty then Overlord:MarkDirty() end
    end
end

function GKI:Tick(force)
    local now = GetTime()
    if not force and now - lastImmersionTickAt < IMMERSION_TICK_INTERVAL_SEC then return end
    lastImmersionTickAt = now
    self:TryVigilMessages()
    self:TrySiegeOpenAssaultMessages()
    self:TrySiegeBattleReports()
end
