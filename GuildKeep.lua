-- GuildKeep.lua - Guild Keep (forteresse guilde, carte separee des warfronts)
Overlord = Overlord or {}
Overlord.GuildKeep = Overlord.GuildKeep or {}

local L = Overlord.L
local KEEP_CAPTURE_SECONDS = 900
local keepStateSiteKeys = setmetatable({}, { __mode = "k" })
Overlord.GuildKeep.DEFAULT_HOLD_TIME_REQUIRED = KEEP_CAPTURE_SECONDS
local SIEGE_WINDOW_EU_START_MINUTE = 21 * 60
local SIEGE_WINDOW_US_START_MINUTE = 18 * 60 -- 18h00 Pacifique (pool us), pas GetGameTime / heure royaume
local SIEGE_WINDOW_DURATION_MINUTE = 60 -- 1h
-- Fortin neutre / non tenu (fort vide ; les warfronts utilisent Empty-Tower)
Overlord.GuildKeep.NEUTRAL_ATLAS = "Warfronts-BaseMapIcons-Empty-MainHall"
local GUILD_KEEP_NEUTRAL_ATLAS = Overlord.GuildKeep.NEUTRAL_ATLAS

local function sanitizeGuildName(name)
    if type(name) ~= "string" or name == "" then return "" end
    name = (name:gsub("[|=:,]", ""):match("^%s*(.-)%s*$") or "")
    if name == "" then return "" end
    if utf8 and utf8.len and utf8.offset and utf8.len(name) > 24 then
        local cut = utf8.offset(name, 25)
        if cut then name = name:sub(1, cut - 1) end
    elseif #name > 24 then
        name = name:sub(1, 24)
    end
    return name
end

local function normalizeGuildKeepPoolTag(pool)
    if type(pool) ~= "string" or pool == "" then return "" end
    pool = pool:lower()
    if pool == "global" or pool == "na" or pool == "us" or pool == "eu"
        or pool == "fr" or pool == "de" then return "global" end
    return ""
end

local function currentGuildKeepPoolTag()
    if Overlord.GetCurrentSavedVarsPool then
        return normalizeGuildKeepPoolTag(Overlord:GetCurrentSavedVarsPool())
    end
    return ""
end

local function resetGuildKeepStateToNeutral(st)
    if not st then return end
    st.status = "neutral"
    st.ownerGuild = ""
    st.ownerFaction = nil
    st.claimedAt = 0
    st.expiresAt = 0
    st.holdTimeElapsed = 0
    st.updatedAt = 0
    st.pool = ""
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    st.previousOwnerGuild = ""
    st.previousOwnerFaction = nil
    st.previousClaimedAt = 0
    st.previousExpiresAt = 0
    st.canonicalAssaultGuild = ""
    st.canonicalAssaultFaction = nil
    st.canonicalAssaultStartedAt = 0
    st.assaultShardId = nil
    st.assaultShardStartedAt = 0
    st.assaultGenerationAt = 0
    st.assaultShardGuild = ""
    st.assaultShardFaction = nil
    st.assaultShardPlayer = ""
    st.assaultBaseGuild = ""
    st.assaultBaseFaction = nil
    st.assaultBaseCapturedAt = 0
    st.finalAssaultShardId = nil
    st.finalAssaultStartedAt = 0
    st.finalAssaultGenerationAt = 0
    st.finalAssaultGuild = ""
    st.finalAssaultFaction = nil
    st.finalAssaultPlayer = ""
    st.finalAssaultAuthorityPlayer = ""
    st.finalAssaultCapturedAt = 0
    st.finalAssaultBaseGuild = ""
    st.finalAssaultBaseFaction = nil
    st.finalAssaultBaseCapturedAt = 0
    st.abortedAssaultShardId = nil
    st.abortedAssaultStartedAt = 0
    st.abortedAssaultGenerationAt = 0
    st.abortedAssaultGuild = ""
    st.abortedAssaultFaction = nil
    st.abortedAssaultPlayer = ""
    st.abortedAssaultAuthorityPlayer = ""
    st.abortedAssaultAt = 0
    st.abortedAssaultBaseGuild = ""
    st.abortedAssaultBaseFaction = nil
    st.abortedAssaultBaseCapturedAt = 0
    st._loginSyncUnconfirmed = nil
    st._gkDeferredLineage = nil
    st._gkLineageCatchupUntil = nil
end

local function clearCanonicalAssaultFields(st)
    if not st then return end
    st.canonicalAssaultGuild = ""
    st.canonicalAssaultFaction = nil
    st.canonicalAssaultStartedAt = 0
end

local function GetUtcEpoch()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function GregorianLeapYearsThrough(year)
    year = math.floor(tonumber(year) or 0)
    return math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
end

local UTC_MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- Conversion gregorienne arithmetique : `time(table)` interprete toujours la table dans
-- le fuseau/DST de la machine. Autour d'une bascule, une correction locale calculee deux
-- fois peut donc ajouter deux offsets differents (01:00Z -> 02:00Z sur une machine EU).
-- Les transitions CET/CEST et Pacific doivent etre identiques sur tous les clients.
local function TimeUtc(year, month, day, hour, min, sec)
    year = math.floor(tonumber(year) or 1970)
    month = math.floor(tonumber(month) or 1)
    day = math.floor(tonumber(day) or 1)
    hour = math.floor(tonumber(hour) or 0)
    min = math.floor(tonumber(min) or 0)
    sec = math.floor(tonumber(sec) or 0)
    local days = 365 * (year - 1970)
        + GregorianLeapYearsThrough(year - 1) - GregorianLeapYearsThrough(1969)
    for m = 1, month - 1 do
        days = days + (UTC_MONTH_DAYS[m] or 0)
        if m == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
            days = days + 1
        end
    end
    days = days + day - 1
    return days * 86400 + hour * 3600 + min * 60 + sec
end

local function UtcNthSundayDay(year, month, n)
    local firstWday = date("!*t", TimeUtc(year, month, 1, 12, 0, 0)).wday or 1
    local firstSunday = 1 + (8 - firstWday) % 7
    return firstSunday + (n - 1) * 7
end

local function UtcLastSundayDay(year, month)
    local nextYear, nextMonth = year, month + 1
    if nextMonth > 12 then
        nextYear, nextMonth = year + 1, 1
    end
    local last = date("!*t", TimeUtc(nextYear, nextMonth, 1, 12, 0, 0) - 86400)
    local lastDay = tonumber(last.day or last.monthDay) or 1
    local weekday = tonumber(last.wday) or 1 -- dimanche = 1
    return lastDay - ((weekday - 1) % 7)
end

-- Les royaumes EU utilisent CET/CEST. Deriver un timestamp historique depuis le
-- decalage realm/local ACTUEL casse aux changements d'heure si le joueur vit dans
-- un fuseau dont le DST ne bascule pas le meme jour. Le calendrier explicite rend
-- day-key, fenetre et cutoff identiques chez tous les clients EU.
local centralEuropeanDstYear, centralEuropeanDstStart, centralEuropeanDstEnd
local function IsCentralEuropeanDaylightTime(ts)
    ts = math.floor(tonumber(ts) or GetUtcEpoch())
    local y = tonumber(date("!%Y", ts)) or 0
    if y <= 0 then return false end
    if centralEuropeanDstYear ~= y then
        centralEuropeanDstYear = y
        centralEuropeanDstStart = TimeUtc(y, 3, UtcLastSundayDay(y, 3), 1, 0, 0)
        centralEuropeanDstEnd = TimeUtc(y, 10, UtcLastSundayDay(y, 10), 1, 0, 0)
    end
    return ts >= centralEuropeanDstStart and ts < centralEuropeanDstEnd
end

local centralEuropeanCalendarCache = { {}, {} }
local function GetCentralEuropeanCalendar(ts)
    ts = math.floor(tonumber(ts) or GetUtcEpoch())
    for i = 1, 2 do
        local cached = centralEuropeanCalendarCache[i]
        if cached.ts == ts then return cached.value end
    end
    local offset = IsCentralEuropeanDaylightTime(ts) and (2 * 3600) or 3600
    local cal = date("!*t", ts + offset)
    local slot = centralEuropeanCalendarCache[2]
    slot.ts, slot.value = ts, cal
    centralEuropeanCalendarCache[2] = centralEuropeanCalendarCache[1]
    centralEuropeanCalendarCache[1] = slot
    return cal
end

local pacificDstYear, pacificDstStart, pacificDstEnd
local function IsPacificDaylightTime(ts)
    ts = math.floor(tonumber(ts) or GetUtcEpoch())
    local y = tonumber(date("!%Y", ts)) or 0
    if y <= 0 then return false end
    if pacificDstYear ~= y then
        pacificDstYear = y
        pacificDstStart = TimeUtc(y, 3, UtcNthSundayDay(y, 3, 2), 10, 0, 0)
        pacificDstEnd = TimeUtc(y, 11, UtcNthSundayDay(y, 11, 1), 9, 0, 0)
    end
    return ts >= pacificDstStart and ts < pacificDstEnd
end

local function GetPacificOffsetSeconds(ts)
    return IsPacificDaylightTime(ts) and (7 * 3600) or (8 * 3600)
end

local pacificCalendarCache = { {}, {} }
local function GetPacificCalendar(ts)
    ts = math.floor(tonumber(ts) or GetUtcEpoch())
    for i = 1, 2 do
        local cached = pacificCalendarCache[i]
        if cached.ts == ts then return cached.value end
    end
    local cal = date("!*t", ts - GetPacificOffsetSeconds(ts))
    local slot = pacificCalendarCache[2]
    slot.ts, slot.value = ts, cal
    pacificCalendarCache[2] = pacificCalendarCache[1]
    pacificCalendarCache[1] = slot
    return cal
end

local function GetPacificMinuteOfDay(ts)
    local cal = GetPacificCalendar(ts)
    return (tonumber(cal.hour) or 0) * 60 + (tonumber(cal.min) or 0)
end

local function GetCentralEuropeanMinuteOfDay(ts)
    local cal = GetCentralEuropeanCalendar(ts)
    return (tonumber(cal.hour) or 0) * 60 + (tonumber(cal.min) or 0)
end

local function GetServerMinuteOfDay(ts)
    local gk = Overlord.GuildKeep
    if gk and gk.IsUsSiegeSchedule and gk:IsUsSiegeSchedule() then
        return GetPacificMinuteOfDay(ts)
    end
    return GetCentralEuropeanMinuteOfDay(ts)
end

local function GetServerCalendarForTimestamp(ts)
    ts = math.floor(tonumber(ts) or GetUtcEpoch())
    local gk = Overlord.GuildKeep
    if gk and gk.IsUsSiegeSchedule and gk:IsUsSiegeSchedule() then
        return GetPacificCalendar(ts)
    end
    return GetCentralEuropeanCalendar(ts)
end

function Overlord.GuildKeep:GetSiegeMinuteOfDay(ts)
    return GetServerMinuteOfDay(ts)
end

function Overlord.GuildKeep:IsUsSiegeSchedule()
    -- Forever beta is a single global population: every client must evaluate
    -- the same Retail US window (18:00-19:00 Pacific), regardless of login region.
    return true
end

function Overlord.GuildKeep:GetSiegeWindowStartMinute()
    if self:IsUsSiegeSchedule() then
        return SIEGE_WINDOW_US_START_MINUTE
    end
    return SIEGE_WINDOW_EU_START_MINUTE
end

function Overlord.GuildKeep:GetSiegeWindowEndMinute()
    return self:GetSiegeWindowStartMinute() + SIEGE_WINDOW_DURATION_MINUTE
end

function Overlord.GuildKeep:GetSiegeReminderStartMinute()
    return self:GetSiegeWindowStartMinute() - 60
end

function Overlord.GuildKeep:GetSiegeWindowStartLabel()
    if self:IsUsSiegeSchedule() then
        return (L and L.GUILD_KEEP_SIEGE_START_US) or "6:00 PM Pacific"
    end
    return (L and L.GUILD_KEEP_SIEGE_START_EU) or "21:00"
end

function Overlord.GuildKeep:GetSiegeWindowEndLabel()
    if self:IsUsSiegeSchedule() then
        return (L and L.GUILD_KEEP_SIEGE_END_US) or "7:00 PM Pacific"
    end
    return (L and L.GUILD_KEEP_SIEGE_END_EU) or "22:00"
end

function Overlord.GuildKeep:GetSiegeWindowRangeLabel()
    if self:IsUsSiegeSchedule() then
        return (L and L.GUILD_KEEP_SIEGE_RANGE_US)
            or "6:00 to 7:00 PM Pacific"
    end
    return (L and L.GUILD_KEEP_SIEGE_RANGE_EU)
        or "21:00 to 22:00 server time"
end

function Overlord.GuildKeep:GetSiegeClosedMessage()
    if self:IsUsSiegeSchedule() then
        return (L and L.GUILD_KEEP_SIEGE_CLOSED_US)
            or "Guild Keeps are attackable from 6:00 to 7:00 PM Pacific."
    end
    return (L and L.GUILD_KEEP_SIEGE_CLOSED)
        or "Guild Keeps are attackable from 21:00 to 22:00 server time."
end

function Overlord.GuildKeep:GetServerSiegeDayKey(ts)
    local cal = GetServerCalendarForTimestamp(ts or GetUtcEpoch())
    local y = tonumber(cal.year) or tonumber(cal.yearOffset) or 0
    if y > 0 and y < 100 then y = y + 2000 end
    if y <= 0 then
        local fallback = date("*t", ts or GetUtcEpoch())
        y = fallback.year
    end
    local month = tonumber(cal.month) or 1
    local day = tonumber(cal.monthDay or cal.day) or 1
    return string.format("%04d%02d%02d", y, month, day)
end

function Overlord.GuildKeep:IsSiegeWindowOpen()
    local minute = GetServerMinuteOfDay()
    local startMinute = self:GetSiegeWindowStartMinute()
    local endMinute = self:GetSiegeWindowEndMinute()
    return minute >= startMinute and minute < endMinute
end

function Overlord.GuildKeep:GetSiegeSecondsRemaining(ts)
    local cal = GetServerCalendarForTimestamp(ts or GetUtcEpoch())
    local hour = tonumber(cal.hour) or 0
    local minute = tonumber(cal.minute or cal.min) or 0
    local second = tonumber(cal.second or cal.sec) or 0
    local nowSec = hour * 3600 + minute * 60 + second
    local startSec = self:GetSiegeWindowStartMinute() * 60
    local endSec = self:GetSiegeWindowEndMinute() * 60
    if nowSec < startSec or nowSec >= endSec then return 0 end
    return math.max(0, endSec - nowSec)
end

function Overlord.GuildKeep:IsSiegeWindowClosedForToday()
    return GetServerMinuteOfDay() >= self:GetSiegeWindowEndMinute()
end

function Overlord.GuildKeep:IsSiegeTimestampInWindow(ts, graceBefore, graceAfter)
    ts = math.floor(tonumber(ts) or 0)
    if ts <= 0 then return self:IsSiegeWindowOpen() end
    local cal = GetServerCalendarForTimestamp(ts)
    local hour = tonumber(cal.hour) or 0
    local minute = tonumber(cal.minute or cal.min) or 0
    local second = tonumber(cal.second or cal.sec) or 0
    local sec = hour * 3600 + minute * 60 + second
    local startSec = self:GetSiegeWindowStartMinute() * 60 - (tonumber(graceBefore) or 0)
    local endSec = self:GetSiegeWindowEndMinute() * 60 + (tonumber(graceAfter) or 0)
    return sec >= startSec and sec < endSec
end

-- Gameplay local : aucune grace apres la fermeture du siege.
function Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts <= 0 then return self:IsSiegeWindowOpen() end
    return self:IsSiegeTimestampInWindow(ts, 0, 0)
end

-- Une capture finale doit avoir eu lieu dans la fenetre de gameplay stricte.
function Overlord.GuildKeep:IsSiegeCaptureTimestampAllowed(ts)
    return self:IsSiegeGameplayTimestampAllowed(ts)
end

local function ensureGuildKeepOfficialTables()
    if not OverlordDB then return nil, nil end
    OverlordDB.guildKeepOfficialTenants = OverlordDB.guildKeepOfficialTenants or {}
    OverlordDB.guildKeepCutoffSnapshots = OverlordDB.guildKeepCutoffSnapshots or {}
    return OverlordDB.guildKeepOfficialTenants, OverlordDB.guildKeepCutoffSnapshots
end

local function copyOfficialTenantRow(row)
    if type(row) ~= "table" then return nil end
    local guild = sanitizeGuildName(row.guild or "")
    local faction = row.faction
    local claimedAt = math.floor(tonumber(row.claimedAt) or 0)
    local pool = normalizeGuildKeepPoolTag(row.pool)
    if guild == "" or (faction ~= "Alliance" and faction ~= "Horde")
        or claimedAt <= 0 or pool == "" then
        return nil
    end
    return {
        guild = guild,
        guildKey = guild:lower(),
        faction = faction,
        claimedAt = claimedAt,
        pool = pool,
    }
end

local function getGuildKeepCampaignStart()
    if Overlord.Leaderboard and Overlord.Leaderboard.GetCurrentCampaignStart then
        return math.floor(tonumber(Overlord.Leaderboard:GetCurrentCampaignStart()) or 0)
    end
    return math.floor(tonumber(OverlordDB and OverlordDB.lastResetTimestamp) or 0)
end

local function officialTenantRowMatchesPool(row, pool, siteKey)
    if not siteKey or not Overlord.GuildKeepSites or not Overlord.GuildKeepSites[siteKey] then
        return false
    end
    if type(row) ~= "table" then return false end
    if sanitizeGuildName(row.guild or "") == "" then return false end
    if row.faction ~= "Alliance" and row.faction ~= "Horde" then return false end
    local claimedAt = math.floor(tonumber(row.claimedAt) or 0)
    if claimedAt <= 0 then return false end
    local campaignStart = getGuildKeepCampaignStart()
    if campaignStart > 0 and claimedAt < campaignStart then return false end
    if claimedAt > GetUtcEpoch() + 300 then return false end
    return normalizeGuildKeepPoolTag(row.pool) == pool
end

function Overlord.GuildKeep:RecordOfficialKeepTenant(siteKey, guild, faction, claimedAt, poolTag, force)
    local tenants = ensureGuildKeepOfficialTables()
    if not tenants then return false end
    siteKey = tostring(siteKey or "")
    guild = sanitizeGuildName(guild or "")
    claimedAt = math.floor(tonumber(claimedAt) or 0)
    poolTag = normalizeGuildKeepPoolTag(poolTag)
    local localPool = currentGuildKeepPoolTag()
    if siteKey == "" or not Overlord.GuildKeepSites or not Overlord.GuildKeepSites[siteKey]
        or guild == "" or claimedAt <= 0 then return false end
    if faction ~= "Alliance" and faction ~= "Horde" then return false end
    if poolTag == "" or localPool == "" or poolTag ~= localPool then return false end
    local campaignStart = getGuildKeepCampaignStart()
    if campaignStart > 0 and claimedAt < campaignStart then return false end
    if not self:IsSiegeGameplayTimestampAllowed(claimedAt) then return false end
    local prev = tenants[siteKey]
    local prevTs = math.floor(tonumber(prev and prev.claimedAt) or 0)
    local guildKey = guild:lower()
    force = force == true
    if not force and prev and prevTs > claimedAt then return false end
    if not force and prev and prevTs == claimedAt and (prev.guildKey or "") == guildKey then return false end
    tenants[siteKey] = {
        guild = guild,
        guildKey = guildKey,
        faction = faction,
        claimedAt = claimedAt,
        pool = poolTag,
    }
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    if self.InvalidateOfficialKeepTenantCache then
        self:InvalidateOfficialKeepTenantCache(siteKey)
    end
    if Overlord.Leaderboard and Overlord.Leaderboard.InvalidateGuildKeepDailyAwardStable then
        Overlord.Leaderboard:InvalidateGuildKeepDailyAwardStable()
    end
    if Overlord.Leaderboard and Overlord.Leaderboard.RequestGuildKeepProofLedgerRebuild then
        Overlord.Leaderboard:RequestGuildKeepProofLedgerRebuild()
    end
    return true
end

-- Cache court : GetOfficialKeepTenant fusionne plusieurs tables ; appele souvent par
-- presentation / awards / immersion. TTL 2 s + invalidation a l'ecriture.
local OFFICIAL_TENANT_CACHE_TTL = 2.0
local officialTenantCache = {}

function Overlord.GuildKeep:InvalidateOfficialKeepTenantCache(siteKey)
    if not siteKey or siteKey == "" then
        officialTenantCache = {}
        return
    end
    officialTenantCache[tostring(siteKey)] = nil
end

function Overlord.GuildKeep:GetOfficialKeepTenant(siteKey)
    local tenants = ensureGuildKeepOfficialTables()
    if not tenants then return nil end
    siteKey = tostring(siteKey or "")
    if siteKey == "" then return nil end
    local pool = currentGuildKeepPoolTag()
    if pool == "" then return nil end
    local nowClock = GetTime and GetTime() or 0
    local cached = officialTenantCache[siteKey]
    if cached and nowClock > 0 and (nowClock - (cached.at or 0)) < OFFICIAL_TENANT_CACHE_TTL then
        return cached.row and copyOfficialTenantRow(cached.row) or nil
    end
    local best = nil
    if not self:IsSiegeWindowOpen() then
        local snapDayKey = self:IsSiegeWindowClosedForToday()
            and self:GetServerSiegeDayKey()
            or self:GetServerSiegeDayKey(GetUtcEpoch() - 86400)
        local function consider(row)
            row = copyOfficialTenantRow(row)
            if not officialTenantRowMatchesPool(row, pool, siteKey) then return end
            if not best or row.claimedAt > best.claimedAt then
                best = row
            end
        end
        consider(tenants[siteKey])
        if Overlord.Leaderboard and Overlord.Leaderboard.GetGuildKeepTenantsTable then
            consider(Overlord.Leaderboard:GetGuildKeepTenantsTable()[siteKey])
        end
        if Overlord.Leaderboard and Overlord.Leaderboard.GetCanonicalGuildKeepTenantForDay then
            consider(Overlord.Leaderboard:GetCanonicalGuildKeepTenantForDay(siteKey, snapDayKey))
        end
    else
        local function consider(row)
            row = copyOfficialTenantRow(row)
            if not officialTenantRowMatchesPool(row, pool, siteKey) then return end
            if not best or row.claimedAt > best.claimedAt then
                best = row
            end
        end
        consider(tenants[siteKey])
        if Overlord.Leaderboard and Overlord.Leaderboard.GetGuildKeepTenantsTable then
            consider(Overlord.Leaderboard:GetGuildKeepTenantsTable()[siteKey])
        end
    end
    if nowClock > 0 then
        officialTenantCache[siteKey] = {
            at = nowClock,
            row = best and copyOfficialTenantRow(best) or false,
        }
    end
    return best
end

local function keepMainHallAtlasForFaction(fac)
    if fac == "Alliance" then return "Warfronts-BaseMapIcons-Alliance-MainHall" end
    if fac == "Horde" then return "Warfronts-BaseMapIcons-Horde-MainHall" end
    return nil
end

function Overlord.GuildKeep:GetMainHallAtlasForFaction(fac)
    return keepMainHallAtlasForFaction(fac)
end

function Overlord.GuildKeep:ResetHeldHoldClock(st, captureTs)
    if not st then return end
    captureTs = math.floor(tonumber(captureTs) or 0)
    if captureTs <= 0 then captureTs = GetUtcEpoch() end
    st.claimedAt = captureTs
    st.expiresAt = 0
end

Overlord.GuildKeepSites = {
    stonetalon = {
        id = "stonetalon_guild_keep",
        siteKey = "stonetalon",
        displayNameKey = "GUILD_KEEP_STONETALON",
        mapID = 1442,
        mapIDs = { [406] = true, [1442] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "stonetalon", "serres-rocheuses", "sierra espuela", "steinkrall" },
        -- Retraite de Roche-Soleil (village Horde, terre).
        center = { 47.2, 61.2 },
        halfSize = 1.35,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
    wetlands = {
        id = "wetlands_guild_keep",
        siteKey = "wetlands",
        displayNameKey = "GUILD_KEEP_WETLANDS",
        mapID = 1437,
        mapIDs = { [56] = true, [1437] = true },
        mapNameNeedles = { "wetlands", "paluns", "les paluns", "sumpfland", "humedales", "болотина" },
        -- Donjon de Menethil. 21.4, 68.0 = baie (eau) sur la carte vanilla.
        center = { 10.6, 59.6 },
        halfSize = 1.35,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
    badlands = {
        id = "badlands_guild_keep",
        siteKey = "badlands",
        displayNameKey = "GUILD_KEEP_BADLANDS",
        mapID = 1418,
        mapIDs = { [15] = true, [1418] = true },
        mapNameNeedles = {
            "badlands", "badland", "terres ingrat", "terres ingrates",
            "tierras inhóspitas", "tierras inhospitas", "ödland", "odland",
        },
        -- Forteresse d'Angor.
        center = { 43.0, 30.8 },
        halfSize = 1.9,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
    crossroads = {
        id = "crossroads_guild_keep",
        siteKey = "crossroads",
        displayNameKey = "GUILD_KEEP_CROSSROADS",
        mapID = 1413,
        mapIDs = { [10] = true, [1413] = true },
        -- Pin Kalimdor continent (Retail 12 / Classic 1414).
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = {
            "barrens", "tarides", "brachland", "baldíos", "baldios",
            "northern barrens", "barrens du nord", "les tarides du nord",
            "crossroads", "la croisée", "la croisee", "el cruce", "wegekreuz",
            "степ", "перекресток",
        },
        -- La Croisee sur Les Tarides vanilla (49.2, 58.8 = Camp Taurajo / carte Retail).
        center = { 51.5, 30.2 },
        halfSize = 1.35,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
    redridge = {
        id = "redridge_guild_keep",
        siteKey = "redridge",
        displayNameKey = "GUILD_KEEP_REDRIDGE",
        mapID = 1433,
        mapIDs = { [49] = true, [1433] = true },
        mapNameNeedles = {
            "redridge", "redridge mountains", "les carmines", "carmines",
            "montañas crestagrana", "montanas crestagrana", "crestagrana",
            "rotkammgebirge", "rotkamm",
        },
        -- Donjon de Guet-de-pierre.
        center = { 67.4, 55.6 },
        halfSize = 1.35,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
    mulgore = {
        id = "mulgore_guild_keep",
        siteKey = "mulgore",
        displayNameKey = "GUILD_KEEP_MULGORE",
        mapID = 1412,
        mapIDs = { [7] = true, [1412] = true },
        regionalMapIDs = { [12] = true, [1414] = true },
        mapNameNeedles = { "mulgore" },
        -- Village de Sabot-de-Sang.
        center = { 47.5, 60.2 },
        halfSize = 1.35,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
    },
}

local siteByKey = {}
local siteByMapID = {}
for key, site in pairs(Overlord.GuildKeepSites) do
    site.siteKey = site.siteKey or key
    siteByKey[key] = site
    if site.mapID then
        siteByMapID[site.mapID] = site
    end
    if site.mapIDs then
        for id in pairs(site.mapIDs) do
            siteByMapID[id] = site
        end
    end
end

-- Helper : cle du site par defaut (ordre alphabetique, deterministe)
local function GetDefaultSiteKey()
    if not Overlord.GuildKeepSites then return nil end
    local bestKey
    for key in pairs(Overlord.GuildKeepSites) do
        if not bestKey or key < bestKey then
            bestKey = key
        end
    end
    return bestKey
end

local function defaultState()
    return {
        status = "neutral",
        ownerGuild = "",
        ownerFaction = nil,
        claimedAt = 0,
        expiresAt = 0,
        holdTimeElapsed = 0,
        updatedAt = 0,
        holdTimeRequired = KEEP_CAPTURE_SECONDS,
        isHolding = false,
        isPaused = false,
        isContested = false,
        holdAuthorityLocal = false,
        holdStartTime = nil,
        previousOwnerGuild = "",
        previousOwnerFaction = nil,
        previousClaimedAt = 0,
        previousExpiresAt = 0,
        gkRelayCapturerName = nil,
        gkRelayCapturerShard = nil,
        gkOfficialCapturerName = nil,
        -- Shard Blizzard elue par (debut, shard) : les autres couches ne progressent pas ce timer.
        assaultShardId = nil,
        assaultShardStartedAt = 0,
        assaultGenerationAt = 0,
        assaultShardGuild = "",
        assaultShardFaction = nil,
        assaultShardPlayer = "",
        assaultBaseGuild = "",
        assaultBaseFaction = nil,
        assaultBaseCapturedAt = 0,
        -- Dernier final ancre accepte. Il survit au passage held afin que deux partitions
        -- qui se reconnectent choisissent encore le meme vainqueur.
        finalAssaultShardId = nil,
        finalAssaultStartedAt = 0,
        finalAssaultGenerationAt = 0,
        finalAssaultGuild = "",
        finalAssaultFaction = nil,
        finalAssaultPlayer = "",
        finalAssaultAuthorityPlayer = "",
        finalAssaultCapturedAt = 0,
        finalAssaultBaseGuild = "",
        finalAssaultBaseFaction = nil,
        finalAssaultBaseCapturedAt = 0,
        -- Dernier abandon ancre, republie dans les snapshots v8.
        abortedAssaultShardId = nil,
        abortedAssaultStartedAt = 0,
        abortedAssaultGenerationAt = 0,
        abortedAssaultGuild = "",
        abortedAssaultFaction = nil,
        abortedAssaultPlayer = "",
        abortedAssaultAuthorityPlayer = "",
        abortedAssaultAt = 0,
        abortedAssaultBaseGuild = "",
        abortedAssaultBaseFaction = nil,
        abortedAssaultBaseCapturedAt = 0,
        canonicalAssaultGuild = "",
        canonicalAssaultFaction = nil,
        canonicalAssaultStartedAt = 0,
        pool = "",
    }
end

-- Nom capteur affiche (alertes, tooltip, popup shard) : paquet courant ou dernier relais GK.
function Overlord.GuildKeep:GetEffectiveCapturerName(st)
    if not st then return "" end
    if st.holdAuthorityLocal and st.isHolding and st.ownerFaction == Overlord.PlayerFaction then
        if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
            return Overlord.Sync:GetPlayerFullName() or ""
        end
    end
    local official = st.gkOfficialCapturerName
    if official and type(official) == "string" then
        local t = official:match("^%s*(.-)%s*$") or ""
        if t ~= "" and #t >= 2 and #t <= 50 then return t end
    end
    local relay = st.gkRelayCapturerName
    if relay and type(relay) == "string" then
        local t = relay:match("^%s*(.-)%s*$") or ""
        if t ~= "" and #t >= 2 and #t <= 50 then return t end
    end
    return ""
end

function Overlord.GuildKeep:GetEffectiveCapturerShard(st)
    if not st then return nil end
    local lock = tonumber(st.assaultShardId)
    if lock then return lock end
    local sid = tonumber(st.gkRelayCapturerShard)
    if sid then return sid end
    local name = self:GetEffectiveCapturerName(st)
    if name ~= "" and Overlord.Shard and Overlord.Shard.ResolveKnownShardPlayer then
        local _, resolvedSid = Overlord.Shard:ResolveKnownShardPlayer(name, true)
        return tonumber(resolvedSid)
    end
    return nil
end

local function normalizeAssaultShardId(shardId)
    shardId = tonumber(shardId)
    if not shardId or shardId ~= shardId or shardId == math.huge or shardId == -math.huge then
        return nil
    end
    if shardId < 0 or shardId >= 100000000 or shardId ~= math.floor(shardId) then return nil end
    return shardId
end

local function clearFinalAssaultFields(st)
    if not st then return end
    st.finalAssaultShardId = nil
    st.finalAssaultStartedAt = 0
    st.finalAssaultGenerationAt = 0
    st.finalAssaultGuild = ""
    st.finalAssaultFaction = nil
    st.finalAssaultPlayer = ""
    st.finalAssaultAuthorityPlayer = ""
    st.finalAssaultCapturedAt = 0
    st.finalAssaultBaseGuild = ""
    st.finalAssaultBaseFaction = nil
    st.finalAssaultBaseCapturedAt = 0
end

local function clearAbortedAssaultFields(st)
    if not st then return end
    st.abortedAssaultShardId = nil
    st.abortedAssaultStartedAt = 0
    st.abortedAssaultGenerationAt = 0
    st.abortedAssaultGuild = ""
    st.abortedAssaultFaction = nil
    st.abortedAssaultPlayer = ""
    st.abortedAssaultAuthorityPlayer = ""
    st.abortedAssaultAt = 0
    st.abortedAssaultBaseGuild = ""
    st.abortedAssaultBaseFaction = nil
    st.abortedAssaultBaseCapturedAt = 0
end

local function normalizeAssaultShardPlayer(name)
    if type(name) ~= "string" then return "" end
    local player = name:match("^%s*(.-)%s*$") or ""
    if #player < 2 or #player > 50 then return "" end
    if player:find("^BNet%-", 1) or player:find("^Bridge%-", 1) then return "" end
    return player
end

-- L'Anchor est le fallback. Des porteurs de timer directs peuvent ensuite le promouvoir ;
-- si plusieurs terminent le meme tuple exact, le minimum lexical rend le choix independant
-- de l'ordre des paquets au lieu de garder arbitrairement le premier/dernier recu.
function Overlord.GuildKeep:ChooseTerminalAuthority(anchorPlayer, currentPlayer, candidatePlayer)
    anchorPlayer = normalizeAssaultShardPlayer(anchorPlayer)
    currentPlayer = normalizeAssaultShardPlayer(currentPlayer)
    candidatePlayer = normalizeAssaultShardPlayer(candidatePlayer)
    local anchorKey = anchorPlayer:lower()
    local currentKey = currentPlayer:lower()
    local candidateKey = candidatePlayer:lower()
    if currentKey == "" then currentPlayer, currentKey = anchorPlayer, anchorKey end
    if candidateKey == "" then return currentPlayer end
    if currentKey == "" or currentKey == anchorKey then return candidatePlayer end
    if candidateKey == anchorKey or candidateKey == currentKey then return currentPlayer end
    return candidateKey < currentKey and candidatePlayer or currentPlayer
end

-- Une tenure de depart distingue une vraie recapture successive de deux attaques
-- concurrentes sur des shards differentes. L'ordre est total et associatif :
-- tenure la plus recente, puis premier debut, shard, guilde, faction et joueur.
local function normalizeAssaultBase(guild, faction, capturedAt)
    guild = sanitizeGuildName(guild or "")
    capturedAt = math.floor(tonumber(capturedAt) or 0)
    if guild == "" then
        if capturedAt ~= 0 or (faction ~= nil and faction ~= "") then return "", nil, 0, false end
        return "", nil, 0, true
    end
    if capturedAt <= 0 or (faction ~= "Alliance" and faction ~= "Horde") then
        return "", nil, 0, false
    end
    return guild, faction, capturedAt, true
end

-- v8: `startedAt` est la racine immuable du premier tag de l'Anchor shard et
-- `generationAt` l'offset (en secondes) du debut de la tentative courante.
-- Garder ce calcul unique evite que timer, terminaux et classement donnent trois
-- sens differents au meme tuple wire.
local function assaultAttemptStartedAt(startedAt, generationAt)
    startedAt = math.floor(tonumber(startedAt) or 0)
    generationAt = math.floor(tonumber(generationAt) or -1)
    if startedAt <= 0 or generationAt < 0 or generationAt > 1000000 then return 0 end
    local attemptStartedAt = startedAt + generationAt
    if attemptStartedAt < startedAt then return 0 end
    if Overlord.GuildKeep.GetServerSiegeDayKey
        and Overlord.GuildKeep:GetServerSiegeDayKey(startedAt)
            ~= Overlord.GuildKeep:GetServerSiegeDayKey(attemptStartedAt) then
        return 0
    end
    return attemptStartedAt
end

local function normalizeAssaultIdentity(
    guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    guild = sanitizeGuildName(guild or "")
    shardId = normalizeAssaultShardId(shardId)
    startedAt = math.floor(tonumber(startedAt) or 0)
    generationAt = math.floor(tonumber(generationAt) or -1)
    player = normalizeAssaultShardPlayer(player)
    local baseValid
    baseGuild, baseFaction, baseCapturedAt, baseValid =
        normalizeAssaultBase(baseGuild, baseFaction, baseCapturedAt)
    local attemptStartedAt = assaultAttemptStartedAt(startedAt, generationAt)
    local valid = guild ~= "" and (faction == "Alliance" or faction == "Horde")
        and shardId ~= nil and startedAt > 0 and generationAt >= 0
        and generationAt <= 1000000 and player ~= "" and baseValid
        and attemptStartedAt > 0
        and (baseCapturedAt == 0 or baseCapturedAt <= startedAt)
        and (baseGuild == "" or (guild:lower() ~= baseGuild:lower()
            and faction ~= baseFaction))
    return guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt, valid
end

local function assaultIdentityWins(
    candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
    candidateGenerationAt, candidatePlayer,
    candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt,
    currentGuild, currentFaction, currentShard, currentStartedAt,
    currentGenerationAt, currentPlayer,
    currentBaseGuild, currentBaseFaction, currentBaseCapturedAt)
    local candidateValid, currentValid
    candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
        candidateGenerationAt, candidatePlayer,
        candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt, candidateValid =
        normalizeAssaultIdentity(
            candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
            candidateGenerationAt, candidatePlayer,
            candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt)
    currentGuild, currentFaction, currentShard, currentStartedAt,
        currentGenerationAt, currentPlayer,
        currentBaseGuild, currentBaseFaction, currentBaseCapturedAt, currentValid =
        normalizeAssaultIdentity(
            currentGuild, currentFaction, currentShard, currentStartedAt,
            currentGenerationAt, currentPlayer,
            currentBaseGuild, currentBaseFaction, currentBaseCapturedAt)
    if not candidateValid then return false end
    if not currentValid then return true end
    if candidateBaseCapturedAt ~= currentBaseCapturedAt then
        return candidateBaseCapturedAt > currentBaseCapturedAt
    end
    local candidateBaseKey, currentBaseKey =
        candidateBaseGuild:lower(), currentBaseGuild:lower()
    if candidateBaseKey ~= currentBaseKey then return candidateBaseKey < currentBaseKey end
    local candidateBaseFac, currentBaseFac =
        candidateBaseFaction or "", currentBaseFaction or ""
    if candidateBaseFac ~= currentBaseFac then return candidateBaseFac < currentBaseFac end
    -- Une nouvelle fenetre de siege doit toujours battre les GK/GC/GA retardes de la veille.
    -- Dans une meme fenetre, la racine puis le shard elisent l'Anchor immuable. Seulement
    -- ensuite l'offset de tentative departage ses retries. Mettre la generation avant le
    -- shard permettrait au shard perdant d'un tie a la seconde de voler l'Anchor en retry.
    local candidateDay = Overlord.GuildKeep:GetServerSiegeDayKey(candidateStartedAt)
    local currentDay = Overlord.GuildKeep:GetServerSiegeDayKey(currentStartedAt)
    if candidateDay ~= currentDay then return candidateDay > currentDay end
    if candidateStartedAt ~= currentStartedAt then
        return candidateStartedAt < currentStartedAt
    end
    if candidateShard ~= currentShard then return candidateShard < currentShard end
    if candidateGenerationAt ~= currentGenerationAt then
        return candidateGenerationAt > currentGenerationAt
    end
    local candidateGuildKey, currentGuildKey = candidateGuild:lower(), currentGuild:lower()
    if candidateGuildKey ~= currentGuildKey then return candidateGuildKey < currentGuildKey end
    if candidateFaction ~= currentFaction then return candidateFaction < currentFaction end
    return candidatePlayer:lower() < currentPlayer:lower()
end

local function assaultIdentityMatches(
    candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
    candidateGenerationAt, candidatePlayer,
    candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt,
    currentGuild, currentFaction, currentShard, currentStartedAt,
    currentGenerationAt, currentPlayer,
    currentBaseGuild, currentBaseFaction, currentBaseCapturedAt)
    local candidateValid, currentValid
    candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
        candidateGenerationAt, candidatePlayer,
        candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt, candidateValid =
        normalizeAssaultIdentity(
            candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
            candidateGenerationAt, candidatePlayer,
            candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt)
    currentGuild, currentFaction, currentShard, currentStartedAt,
        currentGenerationAt, currentPlayer,
        currentBaseGuild, currentBaseFaction, currentBaseCapturedAt, currentValid =
        normalizeAssaultIdentity(
            currentGuild, currentFaction, currentShard, currentStartedAt,
            currentGenerationAt, currentPlayer,
            currentBaseGuild, currentBaseFaction, currentBaseCapturedAt)
    return candidateValid and currentValid
        and candidateGuild:lower() == currentGuild:lower()
        and candidateFaction == currentFaction and candidateShard == currentShard
        and candidateStartedAt == currentStartedAt
        and candidateGenerationAt == currentGenerationAt
        and candidatePlayer:lower() == currentPlayer:lower()
        and candidateBaseGuild:lower() == currentBaseGuild:lower()
        and candidateBaseFaction == currentBaseFaction
        and candidateBaseCapturedAt == currentBaseCapturedAt
end

function Overlord.GuildKeep:AssaultIdentityWins(...)
    return assaultIdentityWins(...)
end

-- Horloge des identites et terminaux distribues. `time()` peut suivre l'horloge OS du
-- joueur ; GetServerTime est commune aux shards et empeche un tag tardif au PC en retard
-- de voler l'Anchor au vrai premier tagueur.
function Overlord.GuildKeep:GetNetworkTimestamp()
    return math.floor(tonumber(GetUtcEpoch()) or 0)
end

local function normalizeAssaultResolutionKind(kind)
    if kind == "GC" or kind == "held" then return "GC" end
    if kind == "GA" or kind == "aborted" then return "GA" end
    if kind == "GK" or kind == "in_progress" then return "GK" end
    return nil
end

-- Si un GC a remplace une tenure, aucun episode d'un jour ulterieur ne peut encore citer
-- cette meme tenure comme base. Cette relation de predecesseur passe avant l'ordre des jours ;
-- un GA ancien, lui, ne change pas la tenure et laisse donc le lendemain parfaitement valide.
local function captureCausallyPrecedesSameBase(
    captureKind, captureAt, captureStartedAt,
    captureBaseGuild, captureBaseFaction, captureBaseCapturedAt,
    successorStartedAt, successorBaseGuild, successorBaseFaction,
    successorBaseCapturedAt)
    if captureKind ~= "GC" then return false end
    captureAt = math.floor(tonumber(captureAt) or 0)
    captureStartedAt = math.floor(tonumber(captureStartedAt) or 0)
    successorStartedAt = math.floor(tonumber(successorStartedAt) or 0)
    if captureAt < captureStartedAt or captureAt >= successorStartedAt then return false end
    if captureBaseCapturedAt ~= successorBaseCapturedAt
        or captureBaseFaction ~= successorBaseFaction
        or captureBaseGuild:lower() ~= successorBaseGuild:lower() then return false end
    local captureDay = Overlord.GuildKeep:GetServerSiegeDayKey(captureAt)
    return captureDay == Overlord.GuildKeep:GetServerSiegeDayKey(captureStartedAt)
        and captureDay < Overlord.GuildKeep:GetServerSiegeDayKey(successorStartedAt)
end

-- Ordre convergent d'un episode de siege. Il reste volontairement un ordre TOTAL pur :
-- l'identite immuable passe d'abord, puis GC > GA > GK pour cette identite exacte.
-- La relation « un GC J1 invalide une base J2 » est contextuelle, pas un tie-breaker :
-- l'injecter ici creerait un cycle entre GC perdant J1, GA gagnant J1 et GC valide J2.
local function assaultResolutionWins(candidate, current)
    if type(candidate) ~= "table" then return false end
    local candidateKind = normalizeAssaultResolutionKind(candidate.kind or candidate.status)
    if not candidateKind then return false end

    local candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
        candidateGenerationAt, candidatePlayer, candidateBaseGuild,
        candidateBaseFaction, candidateBaseCapturedAt, candidateValid =
        normalizeAssaultIdentity(
            candidate.guild, candidate.faction, candidate.shard or candidate.anchorShard,
            candidate.startedAt or candidate.anchorStartedAt,
            candidate.generationAt or candidate.anchorGenerationAt,
            candidate.player or candidate.anchorPlayer,
            candidate.baseGuild, candidate.baseFaction, candidate.baseCapturedAt)
    if not candidateValid then return false end

    if type(current) ~= "table" then return true end
    local currentKind = normalizeAssaultResolutionKind(current.kind or current.status)
    if not currentKind then return true end
    local currentGuild, currentFaction, currentShard, currentStartedAt,
        currentGenerationAt, currentPlayer, currentBaseGuild,
        currentBaseFaction, currentBaseCapturedAt, currentValid =
        normalizeAssaultIdentity(
            current.guild, current.faction, current.shard or current.anchorShard,
            current.startedAt or current.anchorStartedAt,
            current.generationAt or current.anchorGenerationAt,
            current.player or current.anchorPlayer,
            current.baseGuild, current.baseFaction, current.baseCapturedAt)
    if not currentValid then return true end

    if assaultIdentityWins(
        candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
        candidateGenerationAt, candidatePlayer,
        candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt,
        currentGuild, currentFaction, currentShard, currentStartedAt,
        currentGenerationAt, currentPlayer,
        currentBaseGuild, currentBaseFaction, currentBaseCapturedAt) then return true end
    if assaultIdentityWins(
        currentGuild, currentFaction, currentShard, currentStartedAt,
        currentGenerationAt, currentPlayer,
        currentBaseGuild, currentBaseFaction, currentBaseCapturedAt,
        candidateGuild, candidateFaction, candidateShard, candidateStartedAt,
        candidateGenerationAt, candidatePlayer,
        candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt) then return false end

    local rank = { GK = 1, GA = 2, GC = 3 }
    if rank[candidateKind] ~= rank[currentKind] then
        return rank[candidateKind] > rank[currentKind]
    end
    return math.floor(tonumber(candidate.eventAt) or 0)
        > math.floor(tonumber(current.eventAt) or 0)
end

function Overlord.GuildKeep:AssaultResolutionWins(candidate, current)
    return assaultResolutionWins(candidate, current)
end

function Overlord.GuildKeep:AssaultProofMatches(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local aKind = normalizeAssaultResolutionKind(a.kind or a.status)
    local bKind = normalizeAssaultResolutionKind(b.kind or b.status)
    if not aKind or aKind ~= bKind
        or math.floor(tonumber(a.eventAt) or 0)
            ~= math.floor(tonumber(b.eventAt) or 0) then return false end
    return assaultIdentityMatches(
        a.guild, a.faction, a.shard or a.anchorShard,
        a.startedAt or a.anchorStartedAt,
        a.generationAt or a.anchorGenerationAt,
        a.player or a.anchorPlayer,
        a.baseGuild, a.baseFaction, a.baseCapturedAt,
        b.guild, b.faction, b.shard or b.anchorShard,
        b.startedAt or b.anchorStartedAt,
        b.generationAt or b.anchorGenerationAt,
        b.player or b.anchorPlayer,
        b.baseGuild, b.baseFaction, b.baseCapturedAt)
end

-- Un rebase historique peut rester ouvert plusieurs jours. Les assauts reellement acceptes
-- ensuite forment alors une branche descendante de la correction. Conserver seulement sa
-- tete suffit : si le winner ancien change, on sait exactement si le live courant appartient
-- encore a cette branche et peut etre rembobine sans toucher un etat independant.
function Overlord.GuildKeep:DeferredLineageOwnsCurrentState(st, marker)
    marker = marker or (st and st._gkDeferredLineage)
    if not st or type(marker) ~= "table" then return false end
    local current = self:GetCurrentTerminalProof(st)
    if self:AssaultProofMatches(current, marker.correction)
        or self:AssaultProofMatches(current, marker.liveDescendant) then
        return true
    end
    local head = marker.liveDescendant
    return type(head) == "table" and head.kind == "GK" and st.status == "in_progress"
        and self:ActiveAssaultAnchorMatches(
            st, head.guild, head.faction, head.shard, head.startedAt,
            head.generationAt, head.player,
            head.baseGuild, head.baseFaction, head.baseCapturedAt)
end

function Overlord.GuildKeep:RememberDeferredLineageCurrentAssault(st, ownedBefore)
    local marker = st and st._gkDeferredLineage
    if type(marker) ~= "table" then return end
    if not ownedBefore or st.status ~= "in_progress" or not self:HasAssaultShardAnchor(st) then
        st._gkDeferredLineage = nil
        return
    end
    marker.liveDescendant = {
        kind = "GK", eventAt = math.floor(tonumber(st.updatedAt) or 0),
        guild = sanitizeGuildName(st.assaultShardGuild or st.ownerGuild or ""),
        faction = st.assaultShardFaction or st.ownerFaction,
        shard = self:GetAssaultShardId(st),
        startedAt = self:GetAssaultShardStartedAt(st),
        generationAt = self:GetAssaultGenerationAt(st),
        player = self:GetAssaultShardPlayer(st),
        baseGuild = sanitizeGuildName(st.assaultBaseGuild or ""),
        baseFaction = st.assaultBaseFaction,
        baseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0),
    }
    st._gkDeferredLineage = marker
end

function Overlord.GuildKeep:RememberDeferredLineageTerminal(st, proof, ownedBefore)
    local marker = st and st._gkDeferredLineage
    if type(marker) ~= "table" then return end
    if self:AssaultProofMatches(proof, marker.correction) then return end
    if not ownedBefore then
        st._gkDeferredLineage = nil
        return
    end
    marker.liveDescendant = proof
    st._gkDeferredLineage = marker
end

function Overlord.GuildKeep:IsCaptureCausalPredecessor(candidate, current)
    if type(candidate) ~= "table" or type(current) ~= "table" then return false end
    local candidateKind = normalizeAssaultResolutionKind(candidate.kind or candidate.status)
    local candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt, candidateBaseValid =
        normalizeAssaultBase(candidate.baseGuild, candidate.baseFaction, candidate.baseCapturedAt)
    local currentBaseGuild, currentBaseFaction, currentBaseCapturedAt, currentBaseValid =
        normalizeAssaultBase(current.baseGuild, current.baseFaction, current.baseCapturedAt)
    if not candidateBaseValid or not currentBaseValid then return false end
    return captureCausallyPrecedesSameBase(
        candidateKind, candidate.eventAt, candidate.startedAt,
        candidateBaseGuild, candidateBaseFaction, candidateBaseCapturedAt,
        current.startedAt, currentBaseGuild, currentBaseFaction, currentBaseCapturedAt)
end

function Overlord.GuildKeep:IsCaptureCausalPredecessorOfAbortedAssault(st, candidate)
    if not st or not self:HasAbortedAssaultAnchor(st) then return false end
    return self:IsCaptureCausalPredecessor(candidate, {
        kind = "GA", eventAt = st.abortedAssaultAt,
        guild = st.abortedAssaultGuild, faction = st.abortedAssaultFaction,
        shard = st.abortedAssaultShardId, startedAt = st.abortedAssaultStartedAt,
        generationAt = st.abortedAssaultGenerationAt, player = st.abortedAssaultPlayer,
        baseGuild = st.abortedAssaultBaseGuild,
        baseFaction = st.abortedAssaultBaseFaction,
        baseCapturedAt = st.abortedAssaultBaseCapturedAt,
    })
end

function Overlord.GuildKeep:WouldAdoptAssaultAnchor(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not st then return false end
    if self.IsAssaultCandidateBlockedByAbort and self:IsAssaultCandidateBlockedByAbort(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt) then return false end
    return assaultIdentityWins(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
        st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
end

function Overlord.GuildKeep:AdoptAssaultAnchor(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not st or not self:WouldAdoptAssaultAnchor(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt) then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player, baseGuild, baseFaction,
        baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    if not valid then return false end
    st.assaultShardId = shardId
    st.assaultShardStartedAt = startedAt
    st.assaultGenerationAt = generationAt
    st.assaultShardGuild = guild
    st.assaultShardFaction = faction
    st.assaultShardPlayer = player
    st.assaultBaseGuild = baseGuild
    st.assaultBaseFaction = baseFaction
    st.assaultBaseCapturedAt = baseCapturedAt
    if not tonumber(st.gkRelayCapturerShard) then st.gkRelayCapturerShard = shardId end
    return true
end

function Overlord.GuildKeep:ClearOfficialKeepTenant(siteKey)
    local tenants = ensureGuildKeepOfficialTables()
    siteKey = tostring(siteKey or "")
    if not tenants or siteKey == "" or not Overlord.GuildKeepSites
        or not Overlord.GuildKeepSites[siteKey] then return false end
    local previous = tenants[siteKey]
    tenants[siteKey] = nil
    if self.InvalidateOfficialKeepTenantCache then
        self:InvalidateOfficialKeepTenantCache(siteKey)
    end
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    if previous and Overlord.Leaderboard
        and Overlord.Leaderboard.RequestGuildKeepProofLedgerRebuild then
        Overlord.Leaderboard:RequestGuildKeepProofLedgerRebuild()
    end
    return previous ~= nil
end

function Overlord.GuildKeep:GetAssaultShardId(st)
    return normalizeAssaultShardId(st and st.assaultShardId)
end

function Overlord.GuildKeep:GetAssaultShardStartedAt(st)
    return math.max(0, math.floor(tonumber(st and st.assaultShardStartedAt) or 0))
end

function Overlord.GuildKeep:GetAssaultGenerationAt(st)
    return math.max(0, math.floor(tonumber(st and st.assaultGenerationAt) or 0))
end

function Overlord.GuildKeep:GetAssaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
    return assaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
end

function Overlord.GuildKeep:GetCurrentAssaultAttemptStartedAt(st)
    return assaultAttemptStartedAt(
        self:GetAssaultShardStartedAt(st), self:GetAssaultGenerationAt(st))
end

-- v8 : retourne l'offset de la prochaine tentative puis la racine immuable. Un nil est un
-- blocage fail-closed (mauvais shard ou deux retries dans la meme seconde), jamais un gen0
-- frais. Le tick suivant retentera naturellement quand l'horloge serveur aura avance.
function Overlord.GuildKeep:GetNextAssaultGenerationAt(
    st, baseGuild, baseFaction, baseCapturedAt, localShardId, attemptNow)
    attemptNow = math.floor(tonumber(attemptNow) or self:GetNetworkTimestamp())
    if not self:HasAbortedAssaultAnchor(st) then return 0, attemptNow end
    -- La generation ne departage que les retries d'une meme fenetre et de la meme tenure.
    if self:GetServerSiegeDayKey(st.abortedAssaultStartedAt)
        ~= self:GetServerSiegeDayKey(attemptNow) then return 0, attemptNow end
    baseGuild = sanitizeGuildName(baseGuild or "")
    baseCapturedAt = math.floor(tonumber(baseCapturedAt) or 0)
    if baseGuild:lower() ~= sanitizeGuildName(st.abortedAssaultBaseGuild or ""):lower()
        or baseFaction ~= st.abortedAssaultBaseFaction
        or baseCapturedAt ~= math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0) then
        return 0, attemptNow
    end
    local rootShard = self.GetRequiredRetryShardInfo
        and self:GetRequiredRetryShardInfo(
            st, baseGuild, baseFaction, baseCapturedAt, attemptNow) or nil
    if not rootShard then return 0, attemptNow end
    local rootStartedAt = math.floor(tonumber(st.abortedAssaultStartedAt) or 0)
    local localShard = normalizeAssaultShardId(localShardId)
    if rootStartedAt <= 0 or not rootShard or localShard ~= rootShard then return nil end
    local previousGeneration = math.floor(tonumber(st.abortedAssaultGenerationAt) or 0)
    local abortedAt = math.floor(tonumber(st.abortedAssaultAt) or 0)
    local nextGeneration = attemptNow - rootStartedAt
    if attemptNow <= abortedAt or nextGeneration <= previousGeneration
        or nextGeneration > 1000000
        or assaultAttemptStartedAt(rootStartedAt, nextGeneration) ~= attemptNow then
        return nil
    end
    return nextGeneration, rootStartedAt
end

function Overlord.GuildKeep:GetAssaultShardPlayer(st)
    if not st then return "" end
    return normalizeAssaultShardPlayer(st.assaultShardPlayer)
end

function Overlord.GuildKeep:HasAssaultShardAnchor(st)
    if not st then return false end
    local _, _, _, _, _, _, _, _, _, valid = normalizeAssaultIdentity(
        st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
        st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
    return valid
end

function Overlord.GuildKeep:ActiveAssaultAnchorMatches(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    return st and st.status == "in_progress" and assaultIdentityMatches(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
        st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
end

-- Un paquet ne peut ouvrir/resoudre un assaut depuis une tenure que ce client sait deja
-- remplacee. L'exception "meme base + meme jour" conserve l'arbitrage des vrais tags
-- concurrents : ils ont tous observe le meme tenant avant que le premier GC arrive.
function Overlord.GuildKeep:IsAssaultBaseCompatibleWithHeldState(
    st, baseGuild, baseFaction, baseCapturedAt, candidateStartedAt)
    if not st or st.status ~= "held" then return true end
    local valid
    baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultBase(
        baseGuild, baseFaction, baseCapturedAt)
    candidateStartedAt = math.floor(tonumber(candidateStartedAt) or 0)
    if not valid or candidateStartedAt <= 0 then return false end

    local ownerGuild = sanitizeGuildName(st.ownerGuild or "")
    local ownerCapturedAt = math.floor(tonumber(st.claimedAt) or 0)
    if ownerGuild:lower() == baseGuild:lower()
        and st.ownerFaction == baseFaction and ownerCapturedAt == baseCapturedAt then
        return true
    end
    -- Rattrapage sans l'etape intermediaire : une tenure de base plus recente que celle
    -- connue localement prouve que le recepteur a simplement manque la capture precedente.
    if baseCapturedAt > ownerCapturedAt then return true end

    local finalStartedAt = math.floor(tonumber(st.finalAssaultStartedAt) or 0)
    return finalStartedAt > 0
        and sanitizeGuildName(st.finalAssaultBaseGuild or ""):lower() == baseGuild:lower()
        and st.finalAssaultBaseFaction == baseFaction
        and math.floor(tonumber(st.finalAssaultBaseCapturedAt) or 0) == baseCapturedAt
        and self:GetServerSiegeDayKey(finalStartedAt)
            == self:GetServerSiegeDayKey(candidateStartedAt)
end

-- Rattrapage causal tres borne : si un client a manque le GC de J1, son nettoyage local
-- peut restaurer l'ancienne tenure puis laisser commencer J2 dessus. Le GC J1 prouve alors
-- qu'il est le predecesseur de l'assaut actif J2 ; il ferme cet assaut invalide au lieu de
-- perdre artificiellement contre la priorite "jour le plus recent" du total order.
function Overlord.GuildKeep:IsPriorCaptureCorrectionForCurrentLineage(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt, capturedAt, siteKey)
    if not st then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    capturedAt = math.floor(tonumber(capturedAt) or 0)
    local successorStartedAt, successorBaseGuild, successorBaseFaction,
        successorBaseCapturedAt
    if st.status == "in_progress" and self:HasAssaultShardAnchor(st) then
        successorStartedAt = self:GetAssaultShardStartedAt(st)
        successorBaseGuild = sanitizeGuildName(st.assaultBaseGuild or "")
        successorBaseFaction = st.assaultBaseFaction
        successorBaseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0)
    elseif self.GetCurrentTerminalProof then
        local terminal = self:GetCurrentTerminalProof(st)
        if terminal then
            successorStartedAt = math.floor(tonumber(terminal.startedAt) or 0)
            successorBaseGuild = sanitizeGuildName(terminal.baseGuild or "")
            successorBaseFaction = terminal.baseFaction
            successorBaseCapturedAt = math.floor(tonumber(terminal.baseCapturedAt) or 0)
        end
    end
    successorStartedAt = math.floor(tonumber(successorStartedAt) or 0)
    local attemptStartedAt = assaultAttemptStartedAt(startedAt, generationAt)
    if not valid or capturedAt < attemptStartedAt or capturedAt <= baseCapturedAt
        or successorStartedAt <= 0 then return false end
    local causalPredecessor = captureCausallyPrecedesSameBase(
        "GC", capturedAt, startedAt, baseGuild, baseFaction, baseCapturedAt,
        successorStartedAt, successorBaseGuild or "", successorBaseFaction,
        successorBaseCapturedAt or 0)
    if not causalPredecessor then return false end
    -- Le rebase live n'est autorise que si le registre brut du propre jour a deja elu
    -- ce GC. Un GA/GC concurrent gagnant connu bloque donc la correction avant mutation.
    local lb = Overlord.Leaderboard
    return lb and lb.WouldGuildKeepCaptureWinOwnDay
        and lb:WouldGuildKeepCaptureWinOwnDay(siteKey, {
            kind = "GC", eventAt = capturedAt, guild = guild, faction = faction,
            shard = shardId, startedAt = startedAt, generationAt = generationAt,
            player = player, baseGuild = baseGuild, baseFaction = baseFaction,
            baseCapturedAt = baseCapturedAt, pool = currentGuildKeepPoolTag(),
        }) or false
end

function Overlord.GuildKeep:IsAssaultCandidateNewerThanFinal(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not st then return false end
    return assaultResolutionWins({
        kind = "GK", eventAt = startedAt,
        guild = guild, faction = faction, shard = shardId, startedAt = startedAt,
        generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }, {
        kind = "GC", eventAt = st.finalAssaultCapturedAt,
        guild = st.finalAssaultGuild, faction = st.finalAssaultFaction,
        shard = st.finalAssaultShardId, startedAt = st.finalAssaultStartedAt,
        generationAt = st.finalAssaultGenerationAt, player = st.finalAssaultPlayer,
        baseGuild = st.finalAssaultBaseGuild, baseFaction = st.finalAssaultBaseFaction,
        baseCapturedAt = st.finalAssaultBaseCapturedAt,
    })
end

function Overlord.GuildKeep:IsFinalAssaultCandidatePreferred(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt, capturedAt)
    if not st then return false end
    capturedAt = math.floor(tonumber(capturedAt) or 0)
    if capturedAt <= 0 then return false end
    return assaultResolutionWins({
        kind = "GC", eventAt = capturedAt,
        guild = guild, faction = faction, shard = shardId, startedAt = startedAt,
        generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }, {
        kind = "GC", eventAt = st.finalAssaultCapturedAt,
        guild = st.finalAssaultGuild, faction = st.finalAssaultFaction,
        shard = st.finalAssaultShardId, startedAt = st.finalAssaultStartedAt,
        generationAt = st.finalAssaultGenerationAt, player = st.finalAssaultPlayer,
        baseGuild = st.finalAssaultBaseGuild, baseFaction = st.finalAssaultBaseFaction,
        baseCapturedAt = st.finalAssaultBaseCapturedAt,
    })
end

function Overlord.GuildKeep:FinalAssaultAnchorMatches(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    return st and assaultIdentityMatches(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.finalAssaultGuild, st.finalAssaultFaction, st.finalAssaultShardId,
        st.finalAssaultStartedAt, st.finalAssaultGenerationAt, st.finalAssaultPlayer,
        st.finalAssaultBaseGuild, st.finalAssaultBaseFaction,
        st.finalAssaultBaseCapturedAt)
end

function Overlord.GuildKeep:RecordFinalAssaultAnchor(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt, capturedAt)
    if not self:IsFinalAssaultCandidatePreferred(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt, capturedAt) then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player, baseGuild, baseFaction,
        baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    if not valid then return false end
    st.finalAssaultShardId = shardId
    st.finalAssaultStartedAt = startedAt
    st.finalAssaultGenerationAt = generationAt
    st.finalAssaultGuild = guild
    st.finalAssaultFaction = faction
    st.finalAssaultPlayer = player
    st.finalAssaultCapturedAt = math.floor(tonumber(capturedAt) or 0)
    st.finalAssaultBaseGuild = baseGuild
    st.finalAssaultBaseFaction = baseFaction
    st.finalAssaultBaseCapturedAt = baseCapturedAt
    return true
end

function Overlord.GuildKeep:HasAbortedAssaultAnchor(st)
    if not st then return false end
    local _, _, _, startedAt, _, _, _, _, _, valid = normalizeAssaultIdentity(
        st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
        st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt)
    local abortedAt = math.floor(tonumber(st.abortedAssaultAt) or 0)
    return valid and abortedAt >= assaultAttemptStartedAt(
        startedAt, st.abortedAssaultGenerationAt)
        and self:GetServerSiegeDayKey(startedAt) == self:GetServerSiegeDayKey(abortedAt)
end

function Overlord.GuildKeep:AbortedAssaultAnchorMatches(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    return self:HasAbortedAssaultAnchor(st) and assaultIdentityMatches(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
        st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt)
end

-- Un retry v8 garde racine, shard et tenure de base ; seule sa tentative (offset),
-- sa guilde et son porteur peuvent changer. Exiger un debut STRICTEMENT posterieur au GA
-- exclut les retries ambigus fabriques dans la meme seconde que leur terminal parent.
function Overlord.GuildKeep:IsAssaultRetryDescendantOfAbortedAnchor(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not self:HasAbortedAssaultAnchor(st) then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player, baseGuild, baseFaction,
        baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    if not valid then return false end
    local abortedGeneration = math.floor(tonumber(st.abortedAssaultGenerationAt) or -1)
    local attemptStartedAt = assaultAttemptStartedAt(startedAt, generationAt)
    return startedAt == math.floor(tonumber(st.abortedAssaultStartedAt) or 0)
        and shardId == normalizeAssaultShardId(st.abortedAssaultShardId)
        and generationAt > abortedGeneration
        and attemptStartedAt > math.floor(tonumber(st.abortedAssaultAt) or 0)
        and baseGuild:lower()
            == sanitizeGuildName(st.abortedAssaultBaseGuild or ""):lower()
        and baseFaction == st.abortedAssaultBaseFaction
        and baseCapturedAt
            == math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0)
end

-- Si le GC exact du GA a finalement ete prouve, ce GA etait un faux terminal emis par
-- un co-capteur parti trop tot. Les retries qui en descendent n'ont alors jamais eu de
-- base causale et doivent rester invalides, meme si leur generation est superieure.
function Overlord.GuildKeep:HasCaptureDisprovedAbortedAnchor(st)
    if not st or st.status ~= "held" or not self:HasAbortedAssaultAnchor(st) then
        return false
    end
    local finalAt = math.floor(tonumber(st.finalAssaultCapturedAt) or 0)
    if finalAt <= 0 or sanitizeGuildName(st.ownerGuild or ""):lower()
        ~= sanitizeGuildName(st.abortedAssaultGuild or ""):lower()
        or st.ownerFaction ~= st.abortedAssaultFaction
        or math.floor(tonumber(st.claimedAt) or 0) ~= finalAt then return false end
    return self:FinalAssaultAnchorMatches(
        st, st.abortedAssaultGuild, st.abortedAssaultFaction,
        st.abortedAssaultShardId, st.abortedAssaultStartedAt,
        st.abortedAssaultGenerationAt, st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt)
end

function Overlord.GuildKeep:IsAssaultRetryInvalidatedByPriorCapture(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    return self:HasCaptureDisprovedAbortedAnchor(st)
        and self:IsAssaultRetryDescendantOfAbortedAnchor(
            st, guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
end

-- Exception stateful minimale au total order : GA0 est deja stocke, GK1 est son retry
-- direct encore actif, puis le GC0 exact arrive en retard. GC0 bat uniquement SON GA0 ;
-- aucun GC perdant d'une autre identite/generation ne gagne cette exception.
function Overlord.GuildKeep:IsCaptureRepairForActiveRetry(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not st or st.status ~= "in_progress" or not self:AbortedAssaultAnchorMatches(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt) then return false end
    return self:IsAssaultRetryDescendantOfAbortedAnchor(
        st, st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
        st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
end

-- Un GA ferme son identite et les candidats perdants de sa generation. Un retry causal
-- transporte une generation superieure et bat donc les anciens GK meme si le GA fut perdu.
function Overlord.GuildKeep:IsAssaultCandidateBlockedByAbort(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt)
    if not self:HasAbortedAssaultAnchor(st) then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player, baseGuild, baseFaction,
        baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    if not valid then return true end
    if self:IsAssaultRetryInvalidatedByPriorCapture(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt) then return true end
    local exact = self:AbortedAssaultAnchorMatches(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt)
    if exact then return true end
    -- Un candidat qui bat le tombstone appartient a une tenure/generation plus recente,
    -- ou etait le vrai gagnant concurrent dont le GA perdant arriva en premier.
    return not assaultIdentityWins(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
        st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt)
end

-- Une capture GC complete peut reparer un GA concurrent/reordonne du meme episode.
-- Une tenure plus recente ou un retry de generation superieure conserve toutefois sa
-- priorite causale et continue de bloquer les anciens GC retardes.
function Overlord.GuildKeep:IsCaptureCandidateBlockedByAbort(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt, capturedAt)
    if not self:HasAbortedAssaultAnchor(st) then return false end
    if self:IsAssaultRetryInvalidatedByPriorCapture(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt) then return true end
    return not assaultResolutionWins({
        kind = "GC", eventAt = capturedAt,
        guild = guild, faction = faction, shard = shardId, startedAt = startedAt,
        generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }, {
        kind = "GA", eventAt = st.abortedAssaultAt,
        guild = st.abortedAssaultGuild, faction = st.abortedAssaultFaction,
        shard = st.abortedAssaultShardId, startedAt = st.abortedAssaultStartedAt,
        generationAt = st.abortedAssaultGenerationAt, player = st.abortedAssaultPlayer,
        baseGuild = st.abortedAssaultBaseGuild,
        baseFaction = st.abortedAssaultBaseFaction,
        baseCapturedAt = st.abortedAssaultBaseCapturedAt,
    })
end

function Overlord.GuildKeep:RecordAbortedAssaultAnchor(
    st, guild, faction, shardId, startedAt, generationAt, player,
    baseGuild, baseFaction, baseCapturedAt, abortedAt)
    if not st then return false end
    local valid
    guild, faction, shardId, startedAt, generationAt, player, baseGuild, baseFaction,
        baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shardId, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    abortedAt = math.floor(tonumber(abortedAt) or 0)
    if not valid or abortedAt < assaultAttemptStartedAt(startedAt, generationAt)
        or self:GetServerSiegeDayKey(startedAt) ~= self:GetServerSiegeDayKey(abortedAt) then
        return false
    end
    local exact = self:AbortedAssaultAnchorMatches(
        st, guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt)
    if self:HasAbortedAssaultAnchor(st) and not exact and not assaultIdentityWins(
        guild, faction, shardId, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt,
        st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
        st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt) then return false end
    if exact and abortedAt < math.floor(tonumber(st.abortedAssaultAt) or 0) then return false end
    st.abortedAssaultShardId = shardId
    st.abortedAssaultStartedAt = startedAt
    st.abortedAssaultGenerationAt = generationAt
    st.abortedAssaultGuild = guild
    st.abortedAssaultFaction = faction
    st.abortedAssaultPlayer = player
    st.abortedAssaultAt = abortedAt
    st.abortedAssaultBaseGuild = baseGuild
    st.abortedAssaultBaseFaction = baseFaction
    st.abortedAssaultBaseCapturedAt = baseCapturedAt
    return true
end

function Overlord.GuildKeep:IsAbortedAssaultTerminalCurrent(st)
    if not self:HasAbortedAssaultAnchor(st) or st.status == "in_progress" then return false end
    local restored = (sanitizeGuildName(st.abortedAssaultBaseGuild or "") == ""
            and st.status == "neutral")
        or (st.status == "held"
            and sanitizeGuildName(st.ownerGuild or ""):lower()
                == sanitizeGuildName(st.abortedAssaultBaseGuild or ""):lower()
            and st.ownerFaction == st.abortedAssaultBaseFaction
            and math.floor(tonumber(st.claimedAt) or 0)
                == math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0))
    if not restored then return false end
    return assaultResolutionWins({
        kind = "GA", eventAt = st.abortedAssaultAt,
        guild = st.abortedAssaultGuild, faction = st.abortedAssaultFaction,
        shard = st.abortedAssaultShardId, startedAt = st.abortedAssaultStartedAt,
        generationAt = st.abortedAssaultGenerationAt, player = st.abortedAssaultPlayer,
        baseGuild = st.abortedAssaultBaseGuild,
        baseFaction = st.abortedAssaultBaseFaction,
        baseCapturedAt = st.abortedAssaultBaseCapturedAt,
    }, {
        kind = "GC", eventAt = st.finalAssaultCapturedAt,
        guild = st.finalAssaultGuild, faction = st.finalAssaultFaction,
        shard = st.finalAssaultShardId, startedAt = st.finalAssaultStartedAt,
        generationAt = st.finalAssaultGenerationAt, player = st.finalAssaultPlayer,
        baseGuild = st.finalAssaultBaseGuild,
        baseFaction = st.finalAssaultBaseFaction,
        baseCapturedAt = st.finalAssaultBaseCapturedAt,
    })
end

-- Expose uniquement le verrou de retry encore causal. Un vieux GA conserve dans les
-- SavedVariables ne doit jamais alimenter un prompt de shard ni bloquer une nouvelle tenure.
function Overlord.GuildKeep:GetRequiredRetryShardInfo(
    st, baseGuild, baseFaction, baseCapturedAt, attemptNow)
    if not st or not self:IsAbortedAssaultTerminalCurrent(st) then return nil end
    attemptNow = math.floor(tonumber(attemptNow) or self:GetNetworkTimestamp())
    local rootStartedAt = math.floor(tonumber(st.abortedAssaultStartedAt) or 0)
    if rootStartedAt <= 0 or self:GetServerSiegeDayKey(rootStartedAt)
        ~= self:GetServerSiegeDayKey(attemptNow) then return nil end
    if self.IsSiegeGameplayTimestampAllowed
        and not self:IsSiegeGameplayTimestampAllowed(attemptNow) then return nil end
    local validBase
    baseGuild, baseFaction, baseCapturedAt, validBase = normalizeAssaultBase(
        baseGuild, baseFaction, baseCapturedAt)
    if not validBase
        or baseGuild:lower() ~= sanitizeGuildName(st.abortedAssaultBaseGuild or ""):lower()
        or baseFaction ~= st.abortedAssaultBaseFaction
        or baseCapturedAt ~= math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0) then
        return nil
    end
    local shard = normalizeAssaultShardId(st.abortedAssaultShardId)
    if not shard then return nil end
    local contact = normalizeAssaultShardPlayer(st.abortedAssaultAuthorityPlayer)
    if contact == "" then contact = normalizeAssaultShardPlayer(st.abortedAssaultPlayer) end
    return shard, contact, st.abortedAssaultFaction
end

function Overlord.GuildKeep:GetCurrentTerminalProof(st)
    if not st then return nil end
    local kind, guild, faction, shard, startedAt, generationAt, player
    local eventAt, baseGuild, baseFaction, baseCapturedAt
    if self:IsAbortedAssaultTerminalCurrent(st) then
        kind = "GA"
        guild, faction = st.abortedAssaultGuild, st.abortedAssaultFaction
        shard, startedAt = st.abortedAssaultShardId, st.abortedAssaultStartedAt
        generationAt, player = st.abortedAssaultGenerationAt, st.abortedAssaultPlayer
        eventAt = st.abortedAssaultAt
        baseGuild, baseFaction = st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction
        baseCapturedAt = st.abortedAssaultBaseCapturedAt
    elseif st.status == "held" then
        kind = "GC"
        guild, faction = st.finalAssaultGuild, st.finalAssaultFaction
        shard, startedAt = st.finalAssaultShardId, st.finalAssaultStartedAt
        generationAt, player = st.finalAssaultGenerationAt, st.finalAssaultPlayer
        eventAt = st.finalAssaultCapturedAt
        baseGuild, baseFaction = st.finalAssaultBaseGuild, st.finalAssaultBaseFaction
        baseCapturedAt = st.finalAssaultBaseCapturedAt
    else
        return nil
    end
    local valid
    guild, faction, shard, startedAt, generationAt, player,
        baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, shard, startedAt, generationAt, player,
            baseGuild, baseFaction, baseCapturedAt)
    eventAt = math.floor(tonumber(eventAt) or 0)
    if not valid or eventAt < assaultAttemptStartedAt(startedAt, generationAt)
        or self:GetServerSiegeDayKey(startedAt) ~= self:GetServerSiegeDayKey(eventAt) then
        return nil
    end
    local status = st.status
    local resultGuild = status == "held" and sanitizeGuildName(st.ownerGuild or "") or ""
    local resultFaction = status == "held" and st.ownerFaction or nil
    local resultClaimedAt = status == "held" and math.floor(tonumber(st.claimedAt) or 0) or 0
    if status == "held" and (resultGuild == ""
        or (resultFaction ~= "Alliance" and resultFaction ~= "Horde")
        or resultClaimedAt <= 0) then return nil end
    if kind == "GC" and (resultGuild:lower() ~= guild:lower()
        or resultFaction ~= faction or resultClaimedAt ~= eventAt) then return nil end
    return {
        kind = kind, eventAt = eventAt, guild = guild, faction = faction,
        shard = shard, startedAt = startedAt, generationAt = generationAt, player = player,
        baseGuild = baseGuild, baseFaction = baseFaction, baseCapturedAt = baseCapturedAt,
        status = status, resultGuild = resultGuild, resultFaction = resultFaction,
        resultClaimedAt = resultClaimedAt, pool = normalizeGuildKeepPoolTag(st.pool),
    }
end

-- Une Anchor reste l'identite causale immuable de l'assaut, mais pas un verrou de
-- disponibilite infini. Si son heartbeat n'a plus avance depuis plusieurs cadences GK,
-- un joueur allie physiquement present sur une autre shard peut reprendre le timer
-- existant pour la guilde deja creditee. Le tuple wire ne change pas : seuls l'autorite runtime et son
-- heartbeat direct changent, ce qui garde GC/GA compatibles avec les clients v8.
local KEEP_CROSS_SHARD_TAKEOVER_STALE_SEC = 45

function Overlord.GuildKeep:ClearLocalCrossShardTakeover(st)
    if not st then return end
    st._gkTakeoverLocalShard = nil
    st._gkTakeoverAnchorShard = nil
    st._gkTakeoverAnchorStartedAt = nil
    st._gkTakeoverAnchorGenerationAt = nil
    st._gkTakeoverAnchorPlayer = nil
    st._gkTakeoverGrantedAt = nil
end

function Overlord.GuildKeep:HasLocalCrossShardTakeover(st, localShardId)
    if not st or st.status ~= "in_progress" then return false end
    localShardId = normalizeAssaultShardId(localShardId)
    if not localShardId
        or localShardId ~= normalizeAssaultShardId(st._gkTakeoverLocalShard) then return false end
    return normalizeAssaultShardId(st._gkTakeoverAnchorShard) == self:GetAssaultShardId(st)
        and math.floor(tonumber(st._gkTakeoverAnchorStartedAt) or 0)
            == self:GetAssaultShardStartedAt(st)
        and math.floor(tonumber(st._gkTakeoverAnchorGenerationAt) or -1)
            == self:GetAssaultGenerationAt(st)
        and normalizeAssaultShardPlayer(st._gkTakeoverAnchorPlayer):lower()
            == self:GetAssaultShardPlayer(st):lower()
end

function Overlord.GuildKeep:CanTakeOverStaleCrossShardAssault(st, localShardId, now)
    if not st or st.status ~= "in_progress" or st.holdAuthorityLocal or st.isHolding
        or not self:IsCurrentKeepSiegeState(st) or not self:HasAssaultShardAnchor(st) then
        return false
    end
    localShardId = normalizeAssaultShardId(localShardId)
    local anchorShard = self:GetAssaultShardId(st)
    if not localShardId or not anchorShard or localShardId == anchorShard then return false end
    local guild = self:GetLocalPlayerGuild()
    local assaultGuild, assaultFaction = self:GetCanonicalAssaultGuild(st)
    if assaultGuild == "" then
        assaultGuild = sanitizeGuildName(st.assaultShardGuild or st.ownerGuild or "")
        assaultFaction = st.assaultShardFaction or st.ownerFaction
    end
    -- Une guilde alliee peut servir de capteur de secours, mais l'Anchor conserve
    -- integralement la guilde creditee. Une faction adverse ne peut jamais reprendre
    -- cette autorite et devra attendre/reprendre l'assaut selon le terminal normal.
    if guild == "" or assaultGuild == "" or not Overlord.PlayerFaction
        or assaultFaction ~= Overlord.PlayerFaction then return false end
    now = math.floor(tonumber(now) or self:GetNetworkTimestamp())
    local lastHeartbeatAt = math.floor(tonumber(st.updatedAt) or 0)
    return lastHeartbeatAt > 0
        and now - lastHeartbeatAt >= KEEP_CROSS_SHARD_TAKEOVER_STALE_SEC
end

function Overlord.GuildKeep:GrantLocalCrossShardTakeover(st, localShardId, now)
    if not self:CanTakeOverStaleCrossShardAssault(st, localShardId, now) then return false end
    st._gkTakeoverLocalShard = normalizeAssaultShardId(localShardId)
    st._gkTakeoverAnchorShard = self:GetAssaultShardId(st)
    st._gkTakeoverAnchorStartedAt = self:GetAssaultShardStartedAt(st)
    st._gkTakeoverAnchorGenerationAt = self:GetAssaultGenerationAt(st)
    st._gkTakeoverAnchorPlayer = self:GetAssaultShardPlayer(st)
    st._gkTakeoverGrantedAt = math.floor(tonumber(now) or self:GetNetworkTimestamp())
    return true
end

-- Assaut deja ancre sur une autre couche (ou shard locale inconnue) : pas de progression locale.
function Overlord.GuildKeep:IsLocalShardBlockedFromKeepAssault(st, siteKey)
    local lock = self:GetAssaultShardId(st)
    if not lock then return false end
    siteKey = tostring(siteKey or keepStateSiteKeys[st] or "")
    local shard = Overlord.Shard
    local my
    if siteKey ~= "" and shard and shard.GetCaptureLocalShardID then
        my = shard:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8)
    else
        my = shard and shard.GetFreshLocalShardID and shard:GetFreshLocalShardID(8) or nil
    end
    if my ~= nil then
        if my ~= lock and self.HasLocalCrossShardTakeover
            and self:HasLocalCrossShardTakeover(st, my) then return false end
        return my ~= lock
    end
    -- Compatibilite pour les anciens appels sans siteKey : seul le porteur deja actif
    -- peut alors exploiter le contexte. Les chemins de capture normaux passent le site
    -- exact a GetCaptureLocalShardID ci-dessus.
    if siteKey == "" and st and st.holdAuthorityLocal and (st.isHolding or st.isPaused)
        and shard and shard.GetContextLocalShardID then
        my = shard:GetContextLocalShardID()
    end
    if my == nil then return true end
    if my ~= lock and self.HasLocalCrossShardTakeover
        and self:HasLocalCrossShardTakeover(st, my) then return false end
    return my ~= lock
end

function Overlord.GuildKeep:StripLocalAuthorityIfWrongAssaultShard(st, siteKey)
    if not st or not self:IsLocalShardBlockedFromKeepAssault(st, siteKey) then return false end
    if not (st.holdAuthorityLocal or st.isHolding or st.isPaused) then return false end
    st.holdAuthorityLocal = false
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st._gkContestStreak = nil
    st.holdStartTime = nil
    return true
end

-- Normalise un nom capteur GK pour comparaison defer (meme regles que SyncGuildKeep).
local function normalizeGkCapturerNameDefer(name)
    if not name or type(name) ~= "string" then return "" end
    local t = name:match("^%s*(.-)%s*$") or ""
    if #t < 2 or #t > 50 then return "" end
    return t
end

local function getSelfGkCapturerFullName()
    if Overlord.Sync and Overlord.Sync.GetPlayerFullName then
        return Overlord.Sync:GetPlayerFullName() or ""
    end
    return ""
end

-- Ordre total stable pour elire UN porteur du timer parmi plusieurs co-capteurs du meme
-- raid. Sans cet ordre, A deferait a B pendant que B deferait a A : les deux perdaient
-- holdAuthorityLocal et le timer ne repartait qu'en quittant le raid.
local function getGkCapturerElectionKey(name)
    name = normalizeGkCapturerNameDefer(name)
    if name == "" then return "" end
    if Overlord.Sync and Overlord.Sync.NormalizeContributorFullName then
        name = Overlord.Sync:NormalizeContributorFullName(name) or name
    end
    return string.lower(name)
end

-- Une preuve directe recente d'un AUTRE co-capteur sert uniquement de court filet avant
-- un faux GA local. Elle ne transfere pas l'Anchor et expire apres deux cadences GK.
function Overlord.GuildKeep:HasFreshRemoteDirectCapturer(st, maxAge)
    if not st or type(st._gkVerifiedCapturerKeys) ~= "table" then return false end
    maxAge = math.max(1, tonumber(maxAge) or 12)
    local selfName = getSelfGkCapturerFullName()
    local selfKey = Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey
        and Overlord.Sync:GetCaptureContributorDedupKey(selfName)
        or getGkCapturerElectionKey(selfName)
    selfKey = string.lower(tostring(selfKey or ""))
    local now = GetTime()
    for key, seenAt in pairs(st._gkVerifiedCapturerKeys) do
        if tostring(key):lower() ~= selfKey
            and now - (tonumber(seenAt) or 0) <= maxAge then return true end
    end
    return false
end

-- Capteur officiel GK : un autre assaillant sur le meme fort porte le timer (comme ZS zones).
function Overlord.GuildKeep:ShouldDeferToRemoteKeepCapturer(st, localEligible)
    if not st then return false end
    local selfName = getSelfGkCapturerFullName()
    if selfName == "" then return false end

    -- Garde cross-shard : ne jamais ceder holdAuthorityLocal a un capteur d'une autre
    -- shard Blizzard. Deux joueurs sur des shards differentes sont en phasing et voient
    -- des etats paralleles ; defer a une shard distante laissait celle-ci prendre le pas
    -- sur la capture locale (takeover cross-shard). On ne cede l'autorite que si le
    -- capteur distant est confirme sur la MEME shard que le joueur local par une source
    -- TRUSTED : l'appartenance au groupe local (un coequipier WoW est forcement sur ta
    -- shard, infalsifiable). Le cache SH (knownShards) est alimente par des payloads
    -- distants (SetPlayerShard) et n'est pas trusted pour une decision de defer ; un GK
    -- forge pouvait empoisonner le cache puis forcer un defer. Si le capteur n'est pas
    -- groupe, on ne defer pas : l'autorite locale prime et le timer co-capture converge
    -- via le max() monotone de ShouldApplyRemoteKeepHold. S'il est groupe, cette preuve le
    -- rend seulement ELIGIBLE a l'election stable ci-dessous ; elle ne suffit plus a faire
    -- deferer les deux joueurs l'un a l'autre.
    local selfKey = getGkCapturerElectionKey(selfName)
    if selfKey == "" then return false end
    local electedKey
    if localEligible ~= false then electedKey = selfKey end

    -- Seul l'officiel issu d'un heartbeat DIRECT participe a l'election. Le relay est
    -- utile comme contact affiche, mais ne doit jamais pouvoir faire ceder un timer local.
    local nameHint = normalizeGkCapturerNameDefer(st.gkOfficialCapturerName)
    local key = getGkCapturerElectionKey(nameHint)
    if key ~= "" and key ~= selfKey then
        local eligible, inGroup
        if Overlord.GuildKeepControl
            and Overlord.GuildKeepControl.IsGroupedCapturerEligibleForKeep then
            eligible, inGroup = Overlord.GuildKeepControl:IsGroupedCapturerEligibleForKeep(
                nameHint, keepStateSiteKeys[st])
        elseif Overlord.Shard and Overlord.Shard.IsPlayerAlreadyGrouped then
            inGroup = Overlord.Shard:IsPlayerAlreadyGrouped(nameHint)
        end
        -- Une position inconnue conserve l'election lexicale commune : les trous C_Map
        -- transitoires ne doivent pas recreer plusieurs timers. Seule une sortie distante
        -- confirmee exclut le pair. Si le porteur local est confirme hors point, il sort
        -- lui-meme de l'election et tout successeur admissible peut reprendre le timer.
        if inGroup and eligible ~= false
            and (not electedKey or key < electedKey) then electedKey = key end
    end
    return electedKey ~= nil and electedKey ~= selfKey
end

function Overlord.GuildKeep:StoreGkOfficialCapturerFromRemote(
    st, remoteCapturerName, remoteCapturerShard, sender, capturerSourceVerified)
    if not st then return end
    -- Pas de fallback sur "sender" : c'est l'expediteur du paquet (relais communaute, simple
    -- observateur repondant a un SR), pas forcement le vrai capteur. Le deviner accusait a tort
    -- un relais actif (ex. "Zzarna-Sargeras" credite comme assaillant sur deux fortins differents
    -- le meme soir, alors qu'elle ne faisait que relayer). Sans capturerName explicite dans le
    -- payload, on prefere ne rien afficher plutot qu'afficher un nom faux.
    local n = normalizeGkCapturerNameDefer(remoteCapturerName)
    -- Le nom transporte sert de contact et peut etre retransmis. Il ne devient candidat
    -- officiel/continuite de confiance qu'apres un heartbeat direct du meme joueur.
    if n == "" then return end
    st.gkRelayCapturerName = n
    local sid = tonumber(remoteCapturerShard)
    if sid and Overlord.Shard and Overlord.Shard.SetPlayerShard then
        st.gkRelayCapturerShard = sid
        if capturerSourceVerified == true then Overlord.Shard:SetPlayerShard(n, sid) end
    end
    if capturerSourceVerified ~= true then return end
    local selfName = getSelfGkCapturerFullName()
    if n ~= selfName then
        local now = GetTime()
        st._gkVerifiedCapturerKeys = st._gkVerifiedCapturerKeys or {}
        local verifiedKey = Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey
            and Overlord.Sync:GetCaptureContributorDedupKey(n) or getGkCapturerElectionKey(n)
        verifiedKey = string.lower(tostring(verifiedKey or ""))
        if verifiedKey ~= "" then st._gkVerifiedCapturerKeys[verifiedKey] = now end
        local current = normalizeGkCapturerNameDefer(st.gkOfficialCapturerName)
        local currentEligible, currentInGroup
        if current ~= "" and Overlord.GuildKeepControl
            and Overlord.GuildKeepControl.IsGroupedCapturerEligibleForKeep then
            currentEligible, currentInGroup =
                Overlord.GuildKeepControl:IsGroupedCapturerEligibleForKeep(
                    current, keepStateSiteKeys[st])
        end
        local currentVerifiedKey = Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey
            and Overlord.Sync:GetCaptureContributorDedupKey(current)
            or getGkCapturerElectionKey(current)
        currentVerifiedKey = string.lower(tostring(currentVerifiedKey or ""))
        local currentSeenAt = currentVerifiedKey ~= ""
            and tonumber(st._gkVerifiedCapturerKeys[currentVerifiedKey]) or 0
        local currentFresh = currentSeenAt > 0 and now - currentSeenAt <= 12
        -- Election persistante : l'absence du capteur dans NOTRE groupe n'est pas une
        -- preuve de depart. La 9.9.17 remplacait alors l'officiel a chaque heartbeat
        -- communautaire direct, ce qui faisait alterner plusieurs chronos. On ne remplace
        -- qu'un candidat confirme sorti, devenu silencieux, ou lexicalement perdant.
        if current == "" or not currentFresh
            or (currentInGroup == true and currentEligible == false)
            or getGkCapturerElectionKey(n) < getGkCapturerElectionKey(current) then
            st.gkOfficialCapturerName = n
        end
        st._gkOfficialCapturerSeenAt = now
    end
end

-- Enregistrer le joueur local comme candidat sans ecraser un gagnant deja elu. Cette
-- fonction est la seule voie locale autorisee a toucher gkOfficialCapturerName pendant
-- un siege : StartHold peut etre rappele par un co-capteur qui reprend un etat existant.
function Overlord.GuildKeep:RememberLocalGkCapturerCandidate(st)
    if not st then return end
    local selfName = getSelfGkCapturerFullName()
    local selfKey = getGkCapturerElectionKey(selfName)
    if selfKey == "" then return end
    -- La presence locale est une preuve plus forte qu'un heartbeat recu.
    st._gkVerifiedCapturerKeys = st._gkVerifiedCapturerKeys or {}
    local verifiedSelfKey = Overlord.Sync and Overlord.Sync.GetCaptureContributorDedupKey
        and Overlord.Sync:GetCaptureContributorDedupKey(selfName) or selfKey
    if verifiedSelfKey and verifiedSelfKey ~= "" then
        st._gkVerifiedCapturerKeys[string.lower(verifiedSelfKey)] = GetTime()
    end
    local current = normalizeGkCapturerNameDefer(st.gkOfficialCapturerName)
    local currentKey = getGkCapturerElectionKey(current)
    if currentKey == "" or currentKey == selfKey then
        st.gkOfficialCapturerName = selfName
        return
    end
    local currentEligible, currentInGroup
    if Overlord.GuildKeepControl
        and Overlord.GuildKeepControl.IsGroupedCapturerEligibleForKeep then
        currentEligible, currentInGroup =
            Overlord.GuildKeepControl:IsGroupedCapturerEligibleForKeep(
                current, keepStateSiteKeys[st])
    end
    -- Minimum lexical persistant. Un candidat connu sorti du groupe/point est remplace ;
    -- une position inconnue conserve l'election commune et ne depend d'aucun timer local.
    if currentInGroup == false or currentEligible == false or selfKey < currentKey then
        st.gkOfficialCapturerName = selfName
    end
end

function Overlord.GuildKeep:IsCurrentKeepSiegeState(st)
    if not st or st.status ~= "in_progress" then return false end
    if st._gkStaleObserver then return false end
    if self.IsSiegeWindowOpen and not self:IsSiegeWindowOpen() then return false end
    local updatedAt = math.floor(tonumber(st.updatedAt) or 0)
    if updatedAt <= 0 then return false end
    if self.GetServerSiegeDayKey and self:GetServerSiegeDayKey(updatedAt) ~= self:GetServerSiegeDayKey() then
        return false
    end
    return true
end

function Overlord.GuildKeep:GetKeepSiegeSummary(st, siteKey)
    if not st or st.status ~= "in_progress" then return nil end
    if not self:IsCurrentKeepSiegeState(st) then return nil end
    if self.ResolveCanonicalAssaultGuild then
        self:ResolveCanonicalAssaultGuild(st)
    end
    local defenderGuild = sanitizeGuildName(st.previousOwnerGuild or "")
    local defenderFaction = st.previousOwnerFaction
    if defenderGuild == "" and siteKey and self.GetOfficialKeepTenant then
        local official = self:GetOfficialKeepTenant(siteKey)
        if official then
            defenderGuild = sanitizeGuildName(official.guild or "")
            defenderFaction = official.faction or defenderFaction
        end
    end
    local assaultGuild, assaultFaction = self:GetCanonicalAssaultGuild(st)
    if assaultGuild == "" then
        assaultGuild = sanitizeGuildName(st.ownerGuild or "")
        assaultFaction = st.ownerFaction
    end
    local capturer = self:GetEffectiveCapturerName(st)
    return {
        defenderGuild = defenderGuild,
        defenderFaction = defenderFaction,
        assaultGuild = assaultGuild,
        assaultFaction = assaultFaction,
        capturer = capturer,
    }
end

function Overlord.GuildKeep:GetKeepSiegeMapLabel(st, siteKey)
    local summary = self:GetKeepSiegeSummary(st, siteKey)
    if not summary then return nil end
    if summary.defenderGuild ~= "" and summary.assaultGuild ~= "" then
        if summary.defenderGuild == summary.assaultGuild then
            return summary.assaultGuild
        end
        local fmt = (L and L.GUILD_KEEP_SIEGE_MAP_LABEL) or "%s vs %s"
        return string.format(fmt, summary.defenderGuild, summary.assaultGuild)
    end
    if summary.assaultGuild ~= "" then
        return summary.assaultGuild
    end
    return (L and L.GUILD_KEEP_CAPTURING) or "Capturing..."
end

function Overlord.GuildKeep:ClearGkCapturerFields(st)
    if not st then return end
    self:ClearLocalCrossShardTakeover(st)
    st.gkRelayCapturerName = nil
    st.gkRelayCapturerShard = nil
    st.gkOfficialCapturerName = nil
    st.assaultShardId = nil
    st.assaultShardStartedAt = 0
    st.assaultGenerationAt = 0
    st.assaultShardGuild = ""
    st.assaultShardFaction = nil
    st.assaultShardPlayer = ""
    st.assaultBaseGuild = ""
    st.assaultBaseFaction = nil
    st.assaultBaseCapturedAt = 0
    st._gkOfficialCapturerSeenAt = nil
    st._gkVerifiedCapturerKeys = nil
    clearCanonicalAssaultFields(st)
    -- L'assaut se termine (capture / revert / held distant) : la preuve d'assaut ennemi vivant
    -- n'a plus de sens. La nettoyer evite qu'un stamp residuel retarde la detection d'un nouvel
    -- assaut abandonne juste apres (coherent avec _gkStaleObserver).
    st._lastEnemyInProgressGkAt = nil
end

function Overlord.GuildKeep:GetSite(siteKey)
    return siteByKey[siteKey]
end

function Overlord.GuildKeep:GetDefaultSiteKey()
    return GetDefaultSiteKey()
end

function Overlord.GuildKeep:GetDefaultSite()
    local key = GetDefaultSiteKey()
    if not key then return nil end
    return siteByKey[key]
end

-- Vrai si le nom de la carte courante correspond aux aiguilles du site (ex. « paluns »),
-- pas si seul un parent zone matche (ex. Camp Narache dont le parent est Mulgore).
local function MapNameMatchesSiteNeedles(mapID, site)
    if not mapID or not site then return false end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if not ok or not info or not info.name then return false end
    local nl = info.name:lower()
    for _, needle in ipairs(site.mapNameNeedles or {}) do
        if nl:find(needle:lower(), 1, true) then return true end
    end
    return false
end

function Overlord.GuildKeep:ResolveSiteByMapID(mapID)
    if not mapID then return nil end
    local cached = siteByMapID[mapID]
    -- La carte monde appelle ce resolver a chaque frame. Memoriser aussi les echecs :
    -- sans sentinelle, une carte non-fortin recreait seen, remontait cinq parents C_Map
    -- et rescannait les six sites a 60-144 Hz tant que la carte restait ouverte.
    if cached == false then return nil end
    if cached then
        if mapID == cached.mapID or MapNameMatchesSiteNeedles(mapID, cached) then
            return cached
        end
        siteByMapID[mapID] = nil
    end
    local seen = {}
    local current = mapID
    local depth = 0
    local sourceMapKnown = false
    while current and current > 0 and not seen[current] and depth < 5 do
        seen[current] = true
        local site = siteByMapID[current]
        if site and (current == mapID or MapNameMatchesSiteNeedles(mapID, site)) then
            siteByMapID[mapID] = site
            return site
        end
        local ok, info = pcall(C_Map.GetMapInfo, current)
        if not ok or not info then break end
        if current == mapID then sourceMapKnown = true end
        current = info.parentMapID
        depth = depth + 1
    end
    for _, site in pairs(Overlord.GuildKeepSites) do
        if MapNameMatchesSiteNeedles(mapID, site) then
            siteByMapID[mapID] = site
            return site
        end
    end
    -- Pendant un chargement C_Map peut momentanement ne rien renvoyer. Ne pas rendre
    -- cet echec transitoire permanent ; les cartes effectivement resolues, elles, sont stables.
    if sourceMapKnown then siteByMapID[mapID] = false end
    return nil
end

-- Cache chaud strictement borne : deux GetTime() successifs ne sont pas tenus d'etre identiques,
-- meme pendant une seule fusion GK. Cette micro-fenetre couvre les 4-8 lectures C_Map redondantes
-- sans modifier le ticker gameplay 1 Hz. Le contexte shard invalide aussi le cache immediatement.
local KEEP_SPATIAL_SAMPLE_CACHE_SEC = 0.05

local function GetKeepSpatialCacheContext()
    local shard = Overlord.Shard
    return tostring(shard and shard.localContextKey or ""),
        tonumber(shard and shard.localContextStartedAt) or 0
end

local keepOnMapCache = {
    at = -1, contextKey = "", contextAt = -1,
    onMap = false, site = nil, known = false,
}

local function ReadPlayerKeepMapID()
    local mapID = C_Map.GetBestMapForUnit("player")
    if type(mapID) == "number" and mapID > 0 then return mapID end
    return nil
end

function Overlord.GuildKeep:IsPlayerOnKeepMap()
    if Overlord.InstanceSuspended then return false, nil, true end
    local now = GetTime()
    local contextKey, contextAt = GetKeepSpatialCacheContext()
    local cacheAge = now - keepOnMapCache.at
    if cacheAge >= 0 and cacheAge <= KEEP_SPATIAL_SAMPLE_CACHE_SEC
        and keepOnMapCache.contextKey == contextKey
        and keepOnMapCache.contextAt == contextAt then
        return keepOnMapCache.onMap, keepOnMapCache.site, keepOnMapCache.known
    end
    local ok, mapID = pcall(ReadPlayerKeepMapID)
    local onMap, site, sampleKnown = false, nil, false
    if ok and mapID then
        sampleKnown = true
        site = self:ResolveSiteByMapID(mapID)
        onMap = site ~= nil
    end
    -- Gameplay strict du 9 juillet : aucune grace de carte ici. Les trous C_Map sont
    -- exposes comme unknown au troisieme retour ; seul GetPlayerKeepSiteForHud les lisse.
    keepOnMapCache.at = now
    keepOnMapCache.contextKey = contextKey
    keepOnMapCache.contextAt = contextAt
    keepOnMapCache.onMap = onMap
    keepOnMapCache.site = site
    keepOnMapCache.known = sampleKnown
    return onMap, site, sampleKnown
end

local keepHudSiteLastConfirmed = { at = 0, site = nil }
local KEEP_HUD_SAMPLE_GRACE_SEC = 10

-- Variante affichage : le HUD tolere plus longtemps une absence de sample C_Map, mais une
-- carte connue differente le masque immediatement. La grace n'autorise aucun gameplay.
function Overlord.GuildKeep:GetPlayerKeepSiteForHud()
    local onMap, site, sampleKnown = self:IsPlayerOnKeepMap()
    local now = GetTime()
    if onMap and site then
        if sampleKnown then
            keepHudSiteLastConfirmed.at = now
            keepHudSiteLastConfirmed.site = site
        end
        return true, site
    end
    if sampleKnown then
        keepHudSiteLastConfirmed.at = 0
        keepHudSiteLastConfirmed.site = nil
        return false, nil
    end
    if keepHudSiteLastConfirmed.site
        and now - keepHudSiteLastConfirmed.at <= KEEP_HUD_SAMPLE_GRACE_SEC then
        return true, keepHudSiteLastConfirmed.site
    end
    return false, nil
end

function Overlord.GuildKeep:GetPlayerMapID()
    if Overlord.InstanceSuspended then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if ok and mapID then return mapID end
    return nil
end

-- Carte de geometrie : celle du joueur si c'est bien le site, sinon un mapID vivant.
function Overlord.GuildKeep:GetGeometryMapID(site)
    if not site then return nil end
    local playerMap = self.GetPlayerMapID and self:GetPlayerMapID()
    if playerMap and self:IsKeepSiteDisplayMap(playerMap, site) then
        return playerMap
    end
    local function mapExists(id)
        if not id then return false end
        local ok, info = pcall(C_Map.GetMapInfo, id)
        return ok and info ~= nil
    end
    if mapExists(site.mapID) then return site.mapID end
    if site.mapIDs then
        for id in pairs(site.mapIDs) do
            if mapExists(id) then return id end
        end
    end
    return site.mapID
end

-- Carte affichee = zone du site (mapID / mapIDs) ou sous-carte nommee (ex. Les Paluns), pas les
-- micro-zones starter dont le parent zone matche (ex. Camp Narache / Mulgore).
function Overlord.GuildKeep:IsKeepSiteDisplayMap(mapID, site)
    if not site or not mapID then return false end
    if mapID == site.mapID then return true end
    if site.mapIDs and site.mapIDs[mapID] then return true end
    return MapNameMatchesSiteNeedles(mapID, site)
end

-- Pin projete sur carte parente (ex. Durotar) ou continent (EK / Kalimdor), pas sur la carte detail du site.
function Overlord.GuildKeep:ShouldProjectPinOnMap(site, projectionMapID)
    if not site or not projectionMapID or not site.mapID then return false end
    if projectionMapID == site.mapID then return false end
    if site.mapIDs and site.mapIDs[projectionMapID] then return false end
    if site.regionalMapIDs and site.regionalMapIDs[projectionMapID] then return true end
    local MM = Overlord.MapMarkers
    if not MM then return false end
    local kalID = MM.ResolveKalimdorMapID and MM:ResolveKalimdorMapID()
    if kalID and projectionMapID == kalID and site.regionalMapIDs then return true end
    if MM.IsEKMap and MM:IsEKMap(projectionMapID) and not site.regionalMapIDs then return true end
    return false
end

-- in_progress : gameplay + affichage capture sur la carte du site (y compris sous-cartes Paluns)
function Overlord.GuildKeep:ShouldShowInProgressOnMap(st, site, mapID)
    if not st or st.status ~= "in_progress" then return false end
    site = site or self:GetDefaultSite()
    mapID = mapID or self:GetPlayerMapID()
    return self:IsKeepSiteDisplayMap(mapID, site)
end

-- Capture locale en cours (assaillant) : ownerGuild vaut notre guilde, pas le tenant affiche.
function Overlord.GuildKeep:IsLocalKeepCaptureActive(st)
    return st and st.status == "in_progress" and st.isHolding and st.holdAuthorityLocal
end

-- Notre guilde est l'assaillant (in_progress) meme si le sync a cede holdAuthorityLocal un tick.
function Overlord.GuildKeep:IsPlayerKeepAssailant(st)
    if not st or st.status ~= "in_progress" then return false end
    local guild = self:GetLocalPlayerGuild()
    if guild == "" then return false end
    local assaultGuild = select(1, self:GetCanonicalAssaultGuild(st))
    if assaultGuild == "" then
        assaultGuild = sanitizeGuildName(st.ownerGuild or "")
    end
    if assaultGuild ~= guild then return false end
    if st.ownerFaction and Overlord.PlayerFaction and st.ownerFaction ~= Overlord.PlayerFaction then
        return false
    end
    return true
end

-- Etat restaure depuis SavedVariables mais pas encore confirme par GK/GC au login.
function Overlord.GuildKeep:IsKeepStateAwaitingNetworkSnapshot(st)
    if not st or st.status ~= "held" then return false end
    if sanitizeGuildName(st.ownerGuild or "") == "" then return false end
    if st._loginSyncUnconfirmed then return true end
    local updatedAt = tonumber(st.updatedAt) or 0
    if updatedAt > 0 then return false end
    -- Capture locale validee (claimedAt) sans updatedAt : afficher/emettre, pas login disque stale.
    local claimedAt = math.floor(tonumber(st.claimedAt) or 0)
    if claimedAt > 0 then return false end
    return true
end

-- Fort tenu confirme reseau (equivalent Zones:IsNetworkConfirmedCapture).
function Overlord.GuildKeep:IsNetworkConfirmedKeep(st, siteKey)
    if not st or st.status ~= "held" then return false end
    local guild = sanitizeGuildName(st.ownerGuild or "")
    if guild == "" then return false end
    if st.ownerFaction ~= "Alliance" and st.ownerFaction ~= "Horde" then return false end
    if self:IsKeepStateAwaitingNetworkSnapshot(st) then return false end
    local claimedAt = math.floor(tonumber(st.claimedAt) or 0)
    if claimedAt <= 0 then return false end
    local pool = normalizeGuildKeepPoolTag(st.pool)
    local localPool = currentGuildKeepPoolTag()
    if localPool == "" then return false end
    if pool ~= "" and pool ~= localPool then return false end
    if siteKey and self.GetOfficialKeepTenant then
        local official = self:GetOfficialKeepTenant(siteKey)
        if official then
            local og = sanitizeGuildName(official.guild or "")
            local oca = math.floor(tonumber(official.claimedAt) or 0)
            if og ~= "" and oca > 0 then
                if og == guild and oca == claimedAt then
                    return true
                end
                -- Held local plus recent que le tenant officiel (login / reload avant GC/GK).
                if claimedAt > oca and not st._loginSyncUnconfirmed then
                    return true
                end
                return false
            end
        end
    end
    -- Capture locale validee (claimedAt) : meme regle que IsKeepStateAwaitingNetworkSnapshot.
    if not st._loginSyncUnconfirmed then
        return true
    end
    return math.floor(tonumber(st.updatedAt) or 0) > 0
end

function Overlord.GuildKeep:GetLocalKeepContestState(site)
    if not site or not self:IsPlayerInKeepGeometry(site) then return nil end
    if not Overlord.GuildKeepControl or not Overlord.GuildKeepControl.GetNearbyKeepPlayerCounts then
        return nil
    end
    local friendlyCount, enemyCount = Overlord.GuildKeepControl:GetNearbyKeepPlayerCounts(site)
    friendlyCount = tonumber(friendlyCount)
    enemyCount = tonumber(enemyCount)
    if not friendlyCount or not enemyCount then return nil end
    local contested
    if Overlord.ZoneControl and Overlord.ZoneControl.EvaluateCaptureForces then
        contested = Overlord.ZoneControl:EvaluateCaptureForces(
            friendlyCount, enemyCount, false)
    else
        contested = enemyCount > 0 and enemyCount >= friendlyCount
    end
    return contested, friendlyCount, enemyCount
end

function Overlord.GuildKeep:IsLocalDefenseBlockingRemoteKeepCapture(siteKey, st, incomingFaction)
    if not siteKey or not st
        or (st.status ~= "held" and st.status ~= "in_progress") then return false end
    if st.status == "held" and self:IsKeepStateAwaitingNetworkSnapshot(st) then return false end
    local pf = Overlord.PlayerFaction
    if not pf or pf == "" then return false end
    local heldFaction
    if st.status == "in_progress" then
        -- La presence locale ne tranche que sur la shard Anchor effectivement observee.
        -- Un defenseur situe sur une autre couche Blizzard ne doit pas veto une vraie capture.
        if self:IsLocalShardBlockedFromKeepAssault(st, siteKey) then return false end
        local assaultFaction = select(2, self:GetCanonicalAssaultGuild(st))
        if assaultFaction ~= "Alliance" and assaultFaction ~= "Horde" then
            assaultFaction = incomingFaction or st.ownerFaction
        end
        -- Sur un fortin neutre il n'existe aucune faction tenante : toute faction opposee
        -- a l'assaut reste pourtant une force contestataire physique valide.
        if pf == assaultFaction or (incomingFaction and pf == incomingFaction) then return false end
        heldFaction = pf
    else
        local heldGuild
        heldGuild, heldFaction = self:GetEffectiveHeldTenant(st, siteKey)
        heldGuild = sanitizeGuildName(heldGuild or "")
        if heldGuild == "" then
            -- Faction stockee d'abord, vote heuristique en secours (anti-homonymie).
            heldFaction = (st.ownerFaction == "Alliance" or st.ownerFaction == "Horde")
                and st.ownerFaction or self:GetKnownGuildFaction(st.ownerGuild or "")
        end
    end
    if heldFaction ~= pf then return false end
    if incomingFaction and incomingFaction == heldFaction then return false end
    local site = self:GetSite(siteKey)
    local _, friendlyCount, enemyCount = self:GetLocalKeepContestState(site)
    if not friendlyCount or not enemyCount then return false end
    friendlyCount = tonumber(friendlyCount) or 0
    enemyCount = tonumber(enemyCount) or 0
    if friendlyCount <= 0 then return false end
    local defenseBlocks
    if Overlord.ZoneControl and Overlord.ZoneControl.EvaluateCaptureForces then
        -- Inverser les camps : ici l'assaillant porte le timer et nos defenseurs sont
        -- le camp contestataire. La formule reste donc exactement celle des zones.
        defenseBlocks = Overlord.ZoneControl:EvaluateCaptureForces(
            enemyCount, friendlyCount, false)
    else
        defenseBlocks = friendlyCount >= enemyCount
    end
    if not defenseBlocks then return false end
    -- Sans assaut actif, 0 ennemi peut seulement etre une capture d'une autre phase.
    -- Pendant l'assaut Anchor local, 0 signifie au contraire que l'assaillant est mort/parti.
    return st.status == "in_progress" or enemyCount > 0
end

function Overlord.GuildKeep:GetBaseHoldTimeRequired(site)
    return math.max(1, math.floor(tonumber(site and site.holdTimeRequired)
        or KEEP_CAPTURE_SECONDS))
end

function Overlord.GuildKeep:GetMinimumHoldTimeRequired(site)
    local base = self:GetBaseHoldTimeRequired(site)
    local constants = Overlord.RessourcesConstants or {}
    local reduction = math.max(0, tonumber(constants.REINFORCE_REDUCTION) or 60)
    local minimum = math.max(1, tonumber(constants.REINFORCE_MIN_HOLD) or 30)
    return math.max(minimum, base - reduction)
end

-- Seules les deux durees signables par le client officiel sont admises. La duree
-- reduite voyage dans GK ; toute valeur arbitraire retombe sur les 15 minutes.
function Overlord.GuildKeep:NormalizeHoldTimeRequired(value, site)
    local base = self:GetBaseHoldTimeRequired(site)
    local reduced = self:GetMinimumHoldTimeRequired(site)
    value = tonumber(value)
    if value and value == math.floor(value) and value == reduced then return reduced end
    return base
end

function Overlord.GuildKeep:GetDefaultHoldTimeRequired(st, site)
    return self:NormalizeHoldTimeRequired(st and st.holdTimeRequired, site)
end

-- Meme regles que Sync.lua / ZoneControl pour holdTimeElapsed (CAPTURING vs LOSING).
function Overlord.GuildKeep:ShouldApplyRemoteKeepHold(
    st, siteKey, ht, remoteTs, directCapturerVerified)
    if not st then return false, ht end
    ht = tonumber(ht) or 0
    remoteTs = tonumber(remoteTs) or 0
    local localTs = tonumber(st.updatedAt) or 0
    if remoteTs > 0 and localTs > 0 and remoteTs < localTs then
        return false, ht
    end
    -- Hors shard ancree : pas d'autorite locale ; accepter le timer distant pour l'affichage.
    if self:IsLocalShardBlockedFromKeepAssault(st, siteKey) then
        self:StripLocalAuthorityIfWrongAssaultShard(st, siteKey)
        return true, ht
    end
    -- Co-captureur : ceder le timer au capteur distant nomme (comme zones ZS).
    if st.holdAuthorityLocal and self:ShouldDeferToRemoteKeepCapturer(st) then
        return true, ht
    end
    -- CONTESTE : la presence locale reste l'autorite absolue. LOSING est different :
    -- un co-capteur direct du meme tuple peut encore progresser dans le carre apres notre
    -- sortie. Son hold strictement superieur empeche notre decay de fabriquer un faux GA.
    if st.holdAuthorityLocal and st.isContested then
        return false, ht
    end
    if st.holdAuthorityLocal and st.isPaused then
        if directCapturerVerified == true
            and ht > (tonumber(st.holdTimeElapsed) or 0) then return true, ht end
        return false, ht
    end
    local site = self:GetSite(siteKey)
    -- CAPTURING dans le carre : monotone math.max (evite ZS en retard)
    if st.holdAuthorityLocal and st.isHolding and site and self:IsPlayerInKeepGeometry(site) then
        local req = self:GetDefaultHoldTimeRequired(st, site)
        local timeInZone = st.holdStartTime and (GetTime() - st.holdStartTime) or 0
        if timeInZone < 1 then timeInZone = 5 end
        local maxAllowed = math.min(timeInZone + 15, math.max(req - 1, 0))
        return true, math.max(tonumber(st.holdTimeElapsed) or 0, math.min(ht, maxAllowed))
    end
    -- Defenseur sur le carre non submerge (parite Outpost) : ne pas laisser le timer
    -- assaillant distant avancer tant que la contestation locale n'est pas perdante.
    local assaultFac = select(2, self:GetCanonicalAssaultGuild(st))
    if assaultFac ~= "Alliance" and assaultFac ~= "Horde" then
        assaultFac = st.ownerFaction
    end
    if site and st.status == "in_progress" and assaultFac and Overlord.PlayerFaction
        and assaultFac ~= Overlord.PlayerFaction then
        local localContested, friendlyCount, enemyCount = self:GetLocalKeepContestState(site)
        local localHold = tonumber(st.holdTimeElapsed) or 0
        -- La defense interdit uniquement une HAUSSE distante. Un heartbeat autoritaire qui
        -- recule deja le chrono doit converger ici aussi, sinon le defenseur reste fige sur
        -- une ancienne valeur haute jusqu'a la fin de la contestation.
        if localContested ~= nil and (friendlyCount or 0) >= (enemyCount or 0)
            and ht > localHold then
            return false, ht
        end
    end
    -- Un co-capteur du meme guild/shard qui a cede l'autorite locale devient observateur.
    -- Le heartbeat DIRECT de l'autorite elue peut donc rafraichir tout son timer partage ;
    -- les relais restent bornes par la garde anti-spoof ci-dessous.
    if not st.holdAuthorityLocal and directCapturerVerified == true then
        return true, ht
    end
    if not self:IsPlayerKeepAssailant(st) then
        return true, ht
    end
    local req = self:GetDefaultHoldTimeRequired(st, site)
    local timeInZone = st.holdStartTime and (GetTime() - st.holdStartTime) or 0
    if timeInZone < 1 then timeInZone = 5 end
    local maxAllowed = math.min(timeInZone + 15, math.max(req - 1, 0))
    return true, math.max(tonumber(st.holdTimeElapsed) or 0, math.min(ht, maxAllowed))
end

-- Fort « capture » sur la carte detail (MainHall, pas la tour warfront).
function Overlord.GuildKeep:ShouldUseAssaultKeepMapVisual(st, site, displayMapID)
    if self:IsLocalKeepCaptureActive(st) then return true end
    if not st or st.status ~= "in_progress" then return false end
    site = site or self:GetDefaultSite()
    if not site then return false end
    displayMapID = displayMapID or self:GetPlayerMapID() or site.mapID
    if not self:IsKeepSiteDisplayMap(displayMapID, site) then return false end
    if self:IsPlayerKeepAssailant(st) then return true end
    -- Observateur : assaut confirme par GK (updatedAt > 0) pendant la fenetre de siege.
    if self:CanPlayerObserveKeepSiege(st) then return true end
    return false
end

-- Tenant visible carte / HUD : source officielle si le site est connu, sinon held confirme.
-- Priorite affichage : assaut in_progress (previousOwner/official) > held effectif > official seul.
function Overlord.GuildKeep:GetKeepDisplayTenant(st, siteKey)
    if st and st.status == "in_progress" and self:IsSiegeWindowOpen() then
        local prevGuild = sanitizeGuildName(st.previousOwnerGuild or "")
        if prevGuild ~= "" and st.previousOwnerFaction then
            return prevGuild, st.previousOwnerFaction
        end
        if siteKey and self.GetOfficialKeepTenant then
            local official = self:GetOfficialKeepTenant(siteKey)
            if official then
                return official.guild or "", official.faction
            end
        end
    end
    if siteKey and st and st.status == "held" then
        if self:IsNetworkConfirmedKeep(st, siteKey) then
            local dg, df = self:GetEffectiveHeldTenant(st, siteKey)
            dg = sanitizeGuildName(dg or "")
            if dg ~= "" and df then return dg, df end
            return sanitizeGuildName(st.ownerGuild or ""), st.ownerFaction
        end
    end
    if siteKey and (not self:IsSiegeWindowOpen() or not st or st.status ~= "in_progress") then
        local official = self:GetOfficialKeepTenant(siteKey)
        if official then
            return official.guild or "", official.faction
        end
    end
    if not st or st.status ~= "held" then return "", nil end
    if siteKey then
        local official = self:GetOfficialKeepTenant(siteKey)
        if official then
            return official.guild or "", official.faction
        end
    end
    return "", nil
end

function Overlord.GuildKeep:GetKeepMapIconAtlas(st, site, displayMapID)
    if not st then return GUILD_KEEP_NEUTRAL_ATLAS end
    local siteKey = site and site.siteKey
    local _, officialFaction = self:GetKeepDisplayTenant(st, siteKey)
    if st.status == "in_progress" and not self:IsSiegeWindowOpen() then
        if officialFaction then
            return keepMainHallAtlasForFaction(officialFaction) or GUILD_KEEP_NEUTRAL_ATLAS
        end
        return GUILD_KEEP_NEUTRAL_ATLAS
    end
    if self:ShouldUseAssaultKeepMapVisual(st, site, displayMapID) then
        local atlas = keepMainHallAtlasForFaction(st.ownerFaction)
            or keepMainHallAtlasForFaction(Overlord.PlayerFaction)
        return atlas or GUILD_KEEP_NEUTRAL_ATLAS
    end
    if officialFaction then
        return keepMainHallAtlasForFaction(officialFaction) or GUILD_KEEP_NEUTRAL_ATLAS
    end
    if st.status == "held" then
        local _, df = self:GetKeepDisplayTenant(st, siteKey)
        local atlas = keepMainHallAtlasForFaction(df)
        if atlas then return atlas end
    end
    if st.status == "in_progress" and self:IsCurrentKeepSiegeState(st) then
        local atlas = keepMainHallAtlasForFaction(st.ownerFaction)
        if atlas then return atlas end
    end
    return GUILD_KEEP_NEUTRAL_ATLAS
end

function Overlord.GuildKeep:GetKeepIconVertexColor(st, site, displayMapID)
    local siteKey = site and site.siteKey
    local _, officialFaction = self:GetKeepDisplayTenant(st, siteKey)
    if st and st.status == "in_progress" and not self:IsSiegeWindowOpen() then
        if officialFaction then return 1, 1, 1 end
        return 0.65, 0.65, 0.7
    end
    if self:ShouldUseAssaultKeepMapVisual(st, site, displayMapID) then
        if st and st.isContested then
            return 1, 0.35, 0.15
        end
        return 1, 0.82, 0
    end
    if st and st.status == "in_progress" and self:IsCurrentKeepSiegeState(st) then
        -- Conteste (rouge) vs capture qui progresse (or) : visible sur la carte.
        if st.isContested then
            return 1, 0.35, 0.15
        end
        return 1, 0.82, 0
    end
    if officialFaction then return 1, 1, 1 end
    local _, df = self:GetKeepDisplayTenant(st, siteKey)
    if not st or st.status == "neutral" or not df then
        return 0.65, 0.65, 0.7
    end
    return 1, 1, 1
end

local function PollIfKeepStateNeedsCatchup(st, siteKey)
    if not st or not Overlord.Sync or not Overlord.Sync.PollIfStaleObserverKeep then return end
    local ts = tonumber(st.updatedAt) or 0
    if st.status == "in_progress" then
        if ts <= 0 then
            Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
        end
        return
    end
    if st.status == "held" and Overlord.GuildKeep:IsKeepStateAwaitingNetworkSnapshot(st) then
        Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
        return
    end
    if st.status ~= "neutral" then return end
    if ts > 0 or (st.ownerGuild or "") ~= "" or (tonumber(st.claimedAt) or 0) > 0 then return end
    Overlord.Sync:PollIfStaleObserverKeep(999, siteKey)
end

-- Fortin sans tenant affiche (neutral ou held vide).
function Overlord.GuildKeep:IsKeepNeutralForDisplay(st, siteKey)
    if not st then return true end
    if st.status == "in_progress" then
        if not self:IsCurrentKeepSiegeState(st) then
            return (select(1, self:GetKeepDisplayTenant(st, siteKey)) or "") == ""
        end
        if self:IsSiegeWindowOpen() then return false end
        return (select(1, self:GetKeepDisplayTenant(st, siteKey)) or "") == ""
    end
    if st.status == "held" then
        return (select(1, self:GetKeepDisplayTenant(st, siteKey)) or "") == ""
    end
    return st.status == "neutral"
end

function Overlord.GuildKeep:GetKeepSiegeAvailableHint()
    local fmt = (L and L.GUILD_KEEP_SIEGE_AVAILABLE_FMT) or "Siege available at %s"
    return string.format(fmt, self:GetSiegeWindowStartLabel())
end

-- Sous-titre carte monde / boite HUD fortin
function Overlord.GuildKeep:GetKeepMapSubtitle(st, site, displayMapID)
    if not st then return (L and L.GUILD_KEEP_NEUTRAL) or "Unclaimed" end
    if st.status == "in_progress" then
        if not self:IsCurrentKeepSiegeState(st) then
            local dg = select(1, self:GetKeepDisplayTenant(st, site and site.siteKey))
            if dg ~= "" then return dg end
            return (L and L.GUILD_KEEP_NEUTRAL) or "Unclaimed"
        end
        return self:GetKeepSiegeMapLabel(st, site and site.siteKey)
            or (L and L.GUILD_KEEP_CAPTURING) or "Capturing..."
    end
    if st.status == "held" then
        local dg = select(1, self:GetKeepDisplayTenant(st, site and site.siteKey))
        if dg ~= "" then return dg end
        return (L and L.GUILD_KEEP_NEUTRAL) or "Unclaimed"
    end
    local dg = select(1, self:GetKeepDisplayTenant(st, site and site.siteKey))
    if dg ~= "" then return dg end
    return (L and L.GUILD_KEEP_NEUTRAL) or "Unclaimed"
end

local VALID_KEEP_STATUS = {
    neutral = true,
    in_progress = true,
    held = true,
}

local function sanitizeKeepState(st, site)
    if not st then return end
    local req = Overlord.GuildKeep:GetDefaultHoldTimeRequired(st, site)
    if not VALID_KEEP_STATUS[st.status] then st.status = "neutral" end
    st.claimedAt = tonumber(st.claimedAt) or 0
    st.expiresAt = tonumber(st.expiresAt) or 0
    st.holdTimeElapsed = math.max(0, tonumber(st.holdTimeElapsed) or 0)
    st.updatedAt = tonumber(st.updatedAt) or 0
    st.isContested = st.isContested and true or false
    if st.status ~= "in_progress" then
        st.isContested = false
    end
    st.ownerGuild = sanitizeGuildName(st.ownerGuild or "")
    st.previousOwnerGuild = sanitizeGuildName(st.previousOwnerGuild or "")
    st.previousClaimedAt = tonumber(st.previousClaimedAt) or 0
    st.previousExpiresAt = tonumber(st.previousExpiresAt) or 0
    if st.ownerFaction ~= "Alliance" and st.ownerFaction ~= "Horde" then
        st.ownerFaction = nil
    end
    if st.previousOwnerFaction ~= "Alliance" and st.previousOwnerFaction ~= "Horde" then
        st.previousOwnerFaction = nil
    end
    st.holdTimeRequired = req
    if st.status == "in_progress" then
        local valid
        st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
            st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
            st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt, valid =
            normalizeAssaultIdentity(
                st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
                st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
                st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
        if not valid then
            resetGuildKeepStateToNeutral(st)
            return
        end
    else
        st.assaultShardId = nil
        st.assaultShardStartedAt = 0
        st.assaultGenerationAt = 0
        st.assaultShardGuild = ""
        st.assaultShardFaction = nil
        st.assaultShardPlayer = ""
        st.assaultBaseGuild = ""
        st.assaultBaseFaction = nil
        st.assaultBaseCapturedAt = 0
    end
    local finalValid
    st.finalAssaultGuild, st.finalAssaultFaction, st.finalAssaultShardId,
        st.finalAssaultStartedAt, st.finalAssaultGenerationAt, st.finalAssaultPlayer,
        st.finalAssaultBaseGuild, st.finalAssaultBaseFaction,
        st.finalAssaultBaseCapturedAt, finalValid = normalizeAssaultIdentity(
            st.finalAssaultGuild, st.finalAssaultFaction, st.finalAssaultShardId,
            st.finalAssaultStartedAt, st.finalAssaultGenerationAt, st.finalAssaultPlayer,
            st.finalAssaultBaseGuild, st.finalAssaultBaseFaction,
            st.finalAssaultBaseCapturedAt)
    st.finalAssaultCapturedAt = math.floor(tonumber(st.finalAssaultCapturedAt) or 0)
    local finalAttemptStartedAt = assaultAttemptStartedAt(
        st.finalAssaultStartedAt, st.finalAssaultGenerationAt)
    if not finalValid or st.finalAssaultCapturedAt - finalAttemptStartedAt
        < math.max(0, req - 1)
        or Overlord.GuildKeep:GetServerSiegeDayKey(st.finalAssaultStartedAt)
            ~= Overlord.GuildKeep:GetServerSiegeDayKey(st.finalAssaultCapturedAt) then
        clearFinalAssaultFields(st)
    else
        st.finalAssaultAuthorityPlayer = normalizeAssaultShardPlayer(
            st.finalAssaultAuthorityPlayer)
        if st.finalAssaultAuthorityPlayer == "" then
            st.finalAssaultAuthorityPlayer = st.finalAssaultPlayer
        end
    end
    local abortedValid
    st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
        st.abortedAssaultPlayer,
        st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
        st.abortedAssaultBaseCapturedAt, abortedValid = normalizeAssaultIdentity(
            st.abortedAssaultGuild, st.abortedAssaultFaction, st.abortedAssaultShardId,
            st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt,
            st.abortedAssaultPlayer,
            st.abortedAssaultBaseGuild, st.abortedAssaultBaseFaction,
            st.abortedAssaultBaseCapturedAt)
    st.abortedAssaultAt = math.floor(tonumber(st.abortedAssaultAt) or 0)
    if not abortedValid or st.abortedAssaultAt < assaultAttemptStartedAt(
        st.abortedAssaultStartedAt, st.abortedAssaultGenerationAt)
        or Overlord.GuildKeep:GetServerSiegeDayKey(st.abortedAssaultStartedAt)
            ~= Overlord.GuildKeep:GetServerSiegeDayKey(st.abortedAssaultAt) then
        clearAbortedAssaultFields(st)
    else
        st.abortedAssaultAuthorityPlayer = normalizeAssaultShardPlayer(
            st.abortedAssaultAuthorityPlayer)
        if st.abortedAssaultAuthorityPlayer == "" then
            st.abortedAssaultAuthorityPlayer = st.abortedAssaultPlayer
        end
    end
    -- Un keep v8 tenu possede toujours un timestamp de capture explicite.
    if st.status == "held" and st.ownerGuild ~= "" then
        local ca = math.floor(tonumber(st.claimedAt) or 0)
        st.claimedAt = ca
        st.expiresAt = 0
        local heldByFinal = finalValid and st.finalAssaultCapturedAt == ca
            and sanitizeGuildName(st.finalAssaultGuild or ""):lower() == st.ownerGuild:lower()
            and st.finalAssaultFaction == st.ownerFaction
        local heldByAbort = abortedValid
            and sanitizeGuildName(st.abortedAssaultBaseGuild or ""):lower()
                == st.ownerGuild:lower()
            and st.abortedAssaultBaseFaction == st.ownerFaction
            and math.floor(tonumber(st.abortedAssaultBaseCapturedAt) or 0) == ca
        if ca <= 0 or normalizeGuildKeepPoolTag(st.pool) == ""
            or not (heldByFinal or heldByAbort) then
            resetGuildKeepStateToNeutral(st)
        end
    end
end

-- Ancres de possession du tenant sortant pour revert.
function Overlord.GuildKeep:ResolvePreviousTenantAnchors(st, prevGuild, siteKey)
    local prevCa = math.floor(tonumber(st and st.previousClaimedAt) or 0)
    local prevEx = math.floor(tonumber(st and st.previousExpiresAt) or 0)
    if prevCa > 0 then
        return prevCa, prevEx
    end
    return 0, 0
end

local GUILD_KEEP_SITE_KEY_MIGRATION_VERSION = 1
local initializedGuildKeepDb
local initializedGuildKeepRows

local function savedGuildKeepRowTimestamp(row)
    if type(row) ~= "table" then return 0 end
    return math.max(
        tonumber(row.claimedAt) or 0,
        tonumber(row.updatedAt) or 0,
        tonumber(row.winTs) or 0,
        tonumber(row.latestTs) or 0
    )
end

local function migrateGuildKeepMapEntry(tbl, oldKey, newKey)
    if type(tbl) ~= "table" then return false end
    local old = tbl[oldKey]
    local current = tbl[newKey]
    if old == nil then
        if type(current) == "table" and current.siteKey ~= nil then current.siteKey = newKey end
        return false
    end
    if current == nil or savedGuildKeepRowTimestamp(old) > savedGuildKeepRowTimestamp(current) then
        tbl[newKey] = old
        current = old
    end
    tbl[oldKey] = nil
    if type(current) == "table" and current.siteKey ~= nil then current.siteKey = newKey end
    return true
end

-- Renommage physique des sites, y compris les index du ladder. Cette migration est
-- volontairement faite avant de creer les etats neutres canoniques : un ancien tenant
-- ne doit jamais etre masque par un nouvel enregistrement vide.
function Overlord.GuildKeep:MigrateLegacySiteKeys()
    if not OverlordDB then return false end
    if (tonumber(OverlordDB.guildKeepSiteKeyMigrationVersion) or 0)
        >= GUILD_KEEP_SITE_KEY_MIGRATION_VERSION then return false end

    local keyRenames = {
        elwynn = "redridge",
        echo_isles = "crossroads",
    }
    local changed = false
    for oldKey, newKey in pairs(keyRenames) do
        changed = migrateGuildKeepMapEntry(OverlordDB.guildKeeps, oldKey, newKey) or changed
        changed = migrateGuildKeepMapEntry(OverlordDB.guildKeepOfficialTenants, oldKey, newKey) or changed
        changed = migrateGuildKeepMapEntry(OverlordDB.guildKeepTenants, oldKey, newKey) or changed

        local immersion = OverlordDB.guildKeepImmersion
        if type(immersion) == "table" then
            changed = migrateGuildKeepMapEntry(immersion.chronicles, oldKey, newKey) or changed
            changed = migrateGuildKeepMapEntry(immersion.activeSiege, oldKey, newKey) or changed
            for _, field in ipairs({ "fallenSeen", "oathSeen" }) do
                if type(immersion[field]) == "table" then
                    -- Cache narratif non autoritaire : le reconstruire evite un scan/allocation
                    -- non borne avant les barrieres de sanitation.
                    immersion[field] = {}
                    changed = true
                end
            end
        end

    end

    local selected = keyRenames[OverlordDB.selectedKeepSiteKey] or OverlordDB.selectedKeepSiteKey
    if selected ~= "" and selected ~= OverlordDB.selectedKeepSiteKey then
        OverlordDB.selectedKeepSiteKey = selected
        changed = true
    end
    OverlordDB.guildKeepSiteKeyMigrationVersion = GUILD_KEEP_SITE_KEY_MIGRATION_VERSION
    if changed and Overlord.MarkDirty then Overlord:MarkDirty() end
    return changed
end

function Overlord.GuildKeep:EnsureDB()
    OverlordDB = OverlordDB or {}
    if type(OverlordDB.guildKeeps) ~= "table" then OverlordDB.guildKeeps = {} end
    if initializedGuildKeepDb == OverlordDB
        and initializedGuildKeepRows == OverlordDB.guildKeeps then return end
    self:MigrateLegacySiteKeys()
    OverlordDB.dominationBoostPct = OverlordDB.dominationBoostPct or { Alliance = 0, Horde = 0 }
    for _, fac in ipairs({ "Alliance", "Horde" }) do
        local pct = tonumber(OverlordDB.dominationBoostPct[fac]) or 0
        OverlordDB.dominationBoostPct[fac] = math.max(0, pct)
    end
    for key in pairs(Overlord.GuildKeepSites) do
        local st = OverlordDB.guildKeeps[key]
        if type(st) ~= "table" then
            st = defaultState()
            OverlordDB.guildKeeps[key] = st
        end
        local site = siteByKey[key]
        keepStateSiteKeys[st] = key
        st.holdTimeRequired = self:NormalizeHoldTimeRequired(
            st.holdTimeRequired, site)
        -- Frontiere de confiance SavedVariables : une sanitation unique par identite de DB
        -- remplace l'ancien travail repetitif effectue par chaque GetState du ticker.
        sanitizeKeepState(st, site)
    end
    initializedGuildKeepDb = OverlordDB
    initializedGuildKeepRows = OverlordDB.guildKeeps
end

function Overlord.GuildKeep:GetState(siteKey)
    self:EnsureDB()
    local st = OverlordDB.guildKeeps[siteKey]
    if not st then
        st = defaultState()
        OverlordDB.guildKeeps[siteKey] = st
    end
    local site = siteByKey[siteKey]
    keepStateSiteKeys[st] = siteKey
    st.holdTimeRequired = self:NormalizeHoldTimeRequired(
        st.holdTimeRequired, site)
    return st
end

-- Fortin tenu par la guilde du joueur selon le tenant canonique GC/GK v8
-- (claimedAt le plus recent si plusieurs). Le cache brut `st.ownerGuild` peut rester
-- en retard apres une capture cross-shard et ne doit jamais piloter popup/HUD.
function Overlord.GuildKeep:GetGuildHeldSiteForPlayer()
    local guild = self:GetLocalPlayerGuild()
    if guild == "" then return nil, nil end
    local bestSt, bestSite, bestClaimed = nil, nil, -1
    for key, site in pairs(Overlord.GuildKeepSites) do
        local st = self:GetState(key)
        local heldGuild, _, heldClaimed = self:GetEffectiveHeldTenant(st, key)
        if sanitizeGuildName(heldGuild or "") == guild then
            local ca = tonumber(heldClaimed) or 0
            if ca > bestClaimed then
                bestClaimed = ca
                bestSt = st
                bestSite = site
            end
        end
    end
    return bestSt, bestSite
end

-- HUD fortin : selection manuelle, sinon Auto (fortin tenu par la guilde, puis carte locale, defaut).
function Overlord.GuildKeep:GetHudSite()
    local selKey = OverlordDB and OverlordDB.selectedKeepSiteKey
    if selKey and siteByKey[selKey] then
        return self:GetState(selKey), siteByKey[selKey]
    end
    local st, heldSite = self:GetGuildHeldSiteForPlayer()
    if st and heldSite then
        return st, heldSite
    end
    local onMap, site = self:IsPlayerOnKeepMap()
    if onMap and site then
        return self:GetState(site.siteKey), site
    end
    local defKey = GetDefaultSiteKey()
    local fallbackSite = defKey and siteByKey[defKey]
    if fallbackSite then
        return self:GetState(fallbackSite.siteKey), fallbackSite
    end
    return nil, nil
end

-- Libelle panneau fortin : capture en cours pendant contestation, guilde proprietaire une fois tenu.
function Overlord.GuildKeep:GetKeepHudLabel(st, site, displayMapID)
    displayMapID = displayMapID or self:GetPlayerMapID()
    if not st or not site then
        return (L and L.GUILD_KEEP_NEUTRAL) or "Unclaimed"
    end
    return self:GetKeepMapSubtitle(st, site, displayMapID)
end

-- Choix du joueur pour le selecteur de fortin HUD
function Overlord.GuildKeep:SetSelectedKeepSite(siteKey)
    if not OverlordDB then return end
    if siteKey and not siteByKey[siteKey] then return end
    OverlordDB.selectedKeepSiteKey = siteKey
    if Overlord.MarkDirty then Overlord:MarkDirty() end
    if Overlord.Ressources then
        if Overlord.Ressources.RefreshGuildKeepHUD then
            Overlord.Ressources:RefreshGuildKeepHUD(true)
        end
    end
end

function Overlord.GuildKeep:GetSelectedKeepSiteKey()
    local selKey = OverlordDB and OverlordDB.selectedKeepSiteKey
    if selKey and siteByKey[selKey] then return selKey end
    return nil
end

-- Liste ordonnee des sites (pour le dropdown, cache car GuildKeepSites ne change pas en runtime)
local cachedSortedSites = nil
function Overlord.GuildKeep:GetSortedSiteList()
    if cachedSortedSites then return cachedSortedSites end
    local list = {}
    for key, site in pairs(Overlord.GuildKeepSites) do
        table.insert(list, site)
    end
    table.sort(list, function(a, b) return (a.siteKey or "") < (b.siteKey or "") end)
    cachedSortedSites = list
    return list
end

function Overlord.GuildKeep:MarkDirty()
    if Overlord.MarkDirty then Overlord:MarkDirty() end
end

function Overlord.GuildKeep:SaveKeeps()
    if not OverlordDB then return end
    self:EnsureDB()
    for key in pairs(Overlord.GuildKeepSites) do
        local st = self:GetState(key)
        -- MUTATION EN PLACE, jamais de remplacement de table : GetState sert CETTE table comme
        -- etat vivant. L'ancien `OverlordDB.guildKeeps[key] = { ... }` detruisait a chaque
        -- autosave (30 s) tous les champs transitoires du capteur (holdAuthorityLocal,
        -- isHolding, isContested, _gkContestStreak, gkOfficialCapturerName, ancres _gk*...).
        -- Consequences observees : perte d'autorite en plein decay (toast fige chez les
        -- observateurs, jamais de RevertCapture), hysteresis anti-clignotement sabotee, GK de
        -- debut de siege emis sans nom de capturant. Les champs transitoires sont neutralises
        -- au login par RestoreKeeps, pas a la sauvegarde.
        st.ownerGuild = st.ownerGuild or ""
        st.claimedAt = st.claimedAt or 0
        st.expiresAt = st.expiresAt or 0
        st.holdTimeElapsed = st.holdTimeElapsed or 0
        st.updatedAt = st.updatedAt or 0
        st.holdTimeRequired = self:GetDefaultHoldTimeRequired(st, self:GetSite(key))
        st.previousOwnerGuild = st.previousOwnerGuild or ""
        st.previousClaimedAt = st.previousClaimedAt or 0
        st.previousExpiresAt = st.previousExpiresAt or 0
        st.pool = st.pool or ""
    end
end

function Overlord.GuildKeep:ExpirePostCutoffAssault(siteKey, st)
    if not st or st.status ~= "in_progress" then return false end
    local startedAt = self:GetAssaultShardStartedAt(st)
    local secondsToCutoff = self:GetSiegeSecondsRemaining(startedAt)
    if startedAt <= 0 or secondsToCutoff <= 0 then return false end
    local cutoffAt = startedAt + secondsToCutoff
    if GetUtcEpoch() < cutoffAt then return false end
    if not self:HasAssaultShardAnchor(st) then return false end
    local hadLocalAuthority = st.holdAuthorityLocal == true or st.isHolding == true
    local guild = sanitizeGuildName(st.assaultShardGuild or st.ownerGuild or "")
    local faction = st.assaultShardFaction or st.ownerFaction
    local shard = self:GetAssaultShardId(st)
    local generationAt = self:GetAssaultGenerationAt(st)
    local player = self:GetAssaultShardPlayer(st)
    local baseGuild = sanitizeGuildName(st.assaultBaseGuild or "")
    local baseFaction = st.assaultBaseFaction
    local baseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0)
    -- Tous les temoins produisent le meme terminal, meme si le client se reveille apres
    -- minuit : l'heure du cutoff de CET assaut, pas l'heure de son prochain tick.
    local abortedAt = cutoffAt
    local selfName = getSelfGkCapturerFullName()
    local terminalAuthority = hadLocalAuthority and selfName or player
    if not self:AbortAssault(siteKey, guild, faction, abortedAt, shard, startedAt,
        generationAt, player, baseGuild, baseFaction, baseCapturedAt,
        terminalAuthority, true) then return false end
    local selfIsAnchor = normalizeAssaultShardPlayer(selfName):lower()
        == normalizeAssaultShardPlayer(player):lower()
    local shouldBroadcast = hadLocalAuthority or selfIsAnchor
        or (IsInGroup and IsInGroup()
            and UnitIsGroupLeader and UnitIsGroupLeader("player"))
    if shouldBroadcast and Overlord.Sync and Overlord.Sync.BroadcastGuildKeepAbort then
        Overlord.Sync:BroadcastGuildKeepAbort(
            siteKey, guild, faction, abortedAt, shard, startedAt, generationAt,
            player, baseGuild, baseFaction, baseCapturedAt)
    end
    if Overlord.Sync and Overlord.Sync.PublishGuildKeepDailyProofAfterTerminal then
        Overlord.Sync:PublishGuildKeepDailyProofAfterTerminal(siteKey)
    end
    return true
end

-- Apres /reload, le registre GK reste un observateur du meme assaut immuable. Le chrono
-- partage ne doit ni avancer hors ligne, ni etre recalcule par le moteur local des warfronts :
-- chaque membre a un temps de reload different et produirait sinon une valeur divergente.
local function RestoreInterruptedKeepCapture(st, site)
    if not st then return end
    local req = Overlord.GuildKeep:GetDefaultHoldTimeRequired(st, site)
    local elapsed = st.holdTimeElapsed or 0

    st.isHolding = false
    st.isPaused = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil

    if st.status ~= "in_progress" then return end

    -- Un snapshot plein sans GC reste a une seconde du seuil : seul un joueur de nouveau
    -- physiquement eligible peut produire la seconde finale. Conserver updatedAt tel quel
    -- permet au merge monotone de reprendre sur le meilleur GK recu pendant le reload.
    st.holdTimeElapsed = math.max(0, math.min(tonumber(elapsed) or 0, math.max(req - 1, 0)))
    st.isContested = false
    st._gkContestSampleAt = nil
    local updatedAt = math.floor(tonumber(st.updatedAt) or 0)
    local currentWindow = Overlord.GuildKeep:IsSiegeWindowOpen()
        and updatedAt > 0
        and Overlord.GuildKeep:GetServerSiegeDayKey(updatedAt)
            == Overlord.GuildKeep:GetServerSiegeDayKey()
        and (not Overlord.GuildKeep.IsSiegeGameplayTimestampAllowed
            or Overlord.GuildKeep:IsSiegeGameplayTimestampAllowed(updatedAt))
    st._gkStaleObserver = currentWindow and nil or true
    if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
        Overlord.Sync:PollIfStaleObserverKeep(999, site and site.siteKey)
    end
    if currentWindow and st.holdTimeElapsed >= math.max(req - 1, 0) and site and Overlord.Sync
        and Overlord.Sync.RequestObserverKeepCaptureConfirmationIfComplete then
        Overlord.Sync:RequestObserverKeepCaptureConfirmationIfComplete(site.siteKey, st, site)
    end
end

local function copyProtocol7KeepRow(row)
    if type(row) ~= "table" then return nil end
    local copy = {}
    for key, value in pairs(row) do copy[key] = value end
    return copy
end

-- v7 utilisait generationAt comme compteur de retry ; v8 l'utilise comme offset en
-- secondes depuis une racine immuable. Seule la generation zero a donc exactement le
-- meme sens des deux cotes. Cette migration passe quand meme par les validateurs v8 :
-- elle ne transforme jamais un retry v7 en ancre v8 et ne fait confiance a aucune
-- projection (tenant/award) depourvue de son tuple causal.
local function migrateProtocol7GenerationZeroState(raw, site)
    if type(raw) ~= "table" or not site then return nil end
    local candidate = defaultState()
    for key, value in pairs(raw) do candidate[key] = value end
    candidate._gkDeferredLineage = nil
    candidate._gkLineageCatchupUntil = nil
    candidate.holdTimeRequired = site.holdTimeRequired or KEEP_CAPTURE_SECONDS
    keepStateSiteKeys[candidate] = site.siteKey

    -- Un ancien terminal ambigu ne doit pas rester cache derriere un autre terminal
    -- gen0 compatible puis gagner plus tard une election v8.
    if tonumber(candidate.finalAssaultGenerationAt) ~= 0 then
        clearFinalAssaultFields(candidate)
    end
    if tonumber(candidate.abortedAssaultGenerationAt) ~= 0 then
        clearAbortedAssaultFields(candidate)
    end
    sanitizeKeepState(candidate, site)

    local pool = normalizeGuildKeepPoolTag(candidate.pool)
    local localPool = currentGuildKeepPoolTag()
    local lb = Overlord.Leaderboard
    if pool == "" or localPool == "" or pool ~= localPool or not lb
        or not lb.NormalizeGuildKeepDailyProof then return nil end

    if raw.status == "in_progress" then
        -- Une capture en cours gen0 est elle aussi root+offset(0). La conserver evite
        -- qu'une mise a jour simultanee du raid detruise l'unique Anchor en plein siege.
        if tonumber(raw.assaultGenerationAt) ~= 0 or candidate.status ~= "in_progress"
            or not Overlord.GuildKeep:HasAssaultShardAnchor(candidate) then return nil end
        local startedAt = Overlord.GuildKeep:GetAssaultShardStartedAt(candidate)
        local updatedAt = math.floor(tonumber(candidate.updatedAt) or 0)
        local secondsToCutoff = Overlord.GuildKeep:GetSiegeSecondsRemaining(startedAt)
        local cutoffAt = startedAt + secondsToCutoff
        if startedAt <= 0 or updatedAt <= 0 or secondsToCutoff <= 0
            or updatedAt > cutoffAt then return nil end
        local dayKey = Overlord.GuildKeep:GetServerSiegeDayKey(startedAt)
        local currentDayKey = Overlord.GuildKeep:GetServerSiegeDayKey()
        local savedAuthority = candidate.holdAuthorityLocal == true
            or candidate.isHolding == true
        if dayKey ~= currentDayKey and not savedAuthority then return nil end
        local validated = lb:NormalizeGuildKeepDailyProof(site.siteKey, dayKey, {
            kind = "GA", eventAt = updatedAt,
            guild = candidate.assaultShardGuild,
            faction = candidate.assaultShardFaction,
            shard = candidate.assaultShardId,
            startedAt = candidate.assaultShardStartedAt,
            generationAt = candidate.assaultGenerationAt,
            player = candidate.assaultShardPlayer,
            baseGuild = candidate.assaultBaseGuild,
            baseFaction = candidate.assaultBaseFaction,
            baseCapturedAt = candidate.assaultBaseCapturedAt,
            pool = pool,
        })
        if not validated or validated.generationAt ~= 0 then return nil end
        candidate.ownerGuild = validated.guild
        candidate.ownerFaction = validated.faction
        candidate.claimedAt = 0
        candidate.expiresAt = 0
        candidate.previousOwnerGuild = validated.baseGuild
        candidate.previousOwnerFaction = validated.baseFaction
        candidate.previousClaimedAt = validated.baseCapturedAt
        candidate.previousExpiresAt = 0
        candidate.pool = validated.pool
        return candidate, true
    end

    local terminal = Overlord.GuildKeep:GetCurrentTerminalProof(candidate)
    if not terminal or tonumber(terminal.generationAt) ~= 0 then return nil end
    terminal.pool = pool
    local dayKey = Overlord.GuildKeep:GetServerSiegeDayKey(terminal.eventAt)
    local validated = lb:NormalizeGuildKeepDailyProof(site.siteKey, dayKey, terminal)
    if not validated or validated.generationAt ~= 0
        or candidate.status ~= validated.status then return nil end
    if validated.status == "held" then
        if sanitizeGuildName(candidate.ownerGuild or ""):lower()
                ~= validated.resultGuild:lower()
            or candidate.ownerFaction ~= validated.resultFaction
            or math.floor(tonumber(candidate.claimedAt) or 0)
                ~= validated.claimedAt then return nil end
    elseif sanitizeGuildName(candidate.ownerGuild or "") ~= ""
        or math.floor(tonumber(candidate.claimedAt) or 0) ~= 0 then
        return nil
    end
    candidate.pool = validated.pool
    return candidate, false, validated
end

local function migrateProtocol7GenerationZeroProofs(legacySnapshots, migratedTerminals)
    local lb = Overlord.Leaderboard
    if not lb or not lb.NormalizeGuildKeepDailyProof
        or not lb.ApplyGuildKeepDailyProofSync then return end
    local earliestDayBySite = {}
    local function apply(siteKey, dayKey, raw)
        if type(raw) ~= "table" or tonumber(raw.generationAt) ~= 0 then return end
        local proof = lb:NormalizeGuildKeepDailyProof(siteKey, dayKey, raw)
        if not proof or proof.generationAt ~= 0 then return end
        local applied = lb:ApplyGuildKeepDailyProofSync(
            siteKey, dayKey, proof.kind, proof.eventAt,
            proof.guild, proof.faction, proof.shard,
            proof.startedAt, proof.generationAt, proof.player,
            proof.baseGuild, proof.baseFaction, proof.baseCapturedAt, proof.pool)
        if applied and (not earliestDayBySite[siteKey]
            or tostring(dayKey) < earliestDayBySite[siteKey]) then
            earliestDayBySite[siteKey] = tostring(dayKey)
        end
    end

    for dayKey, snapshot in pairs(legacySnapshots or {}) do
        if type(snapshot) == "table" then
            for siteKey, stored in pairs(snapshot) do
                apply(siteKey, dayKey, stored)
                if type(stored) == "table" and type(stored.byBase) == "table" then
                    for _, raw in pairs(stored.byBase) do apply(siteKey, dayKey, raw) end
                end
            end
        end
    end
    for siteKey, proof in pairs(migratedTerminals or {}) do
        local dayKey = Overlord.GuildKeep:GetServerSiegeDayKey(proof.eventAt)
        apply(siteKey, dayKey, proof)
        if proof.status == "held" and lb.ApplyGuildKeepTenant then
            lb:ApplyGuildKeepTenant(
                siteKey, proof.resultGuild, proof.resultFaction,
                proof.claimedAt, proof.pool, true)
        end
    end
    if lb.ReconcileGuildKeepDailyAwardsFromDay then
        for siteKey, dayKey in pairs(earliestDayBySite) do
            lb:ReconcileGuildKeepDailyAwardsFromDay(siteKey, dayKey)
        end
    end
end

-- La rupture v7->v8 reinitialise toutes les racines ladder/narratives. Renommer ici
-- uniquement les six etats terrain autoritaires evite que EnsureDB parcoure avant les
-- barrieres des snapshots/awards SavedVariables potentiellement arbitraires.
local function migrateProtocol7FixedSiteKeys()
    local keeps = type(OverlordDB.guildKeeps) == "table" and OverlordDB.guildKeeps or {}
    migrateGuildKeepMapEntry(keeps, "elwynn", "redridge")
    migrateGuildKeepMapEntry(keeps, "echo_isles", "crossroads")
    local selected = OverlordDB.selectedKeepSiteKey
    if selected == "elwynn" then OverlordDB.selectedKeepSiteKey = "redridge"
    elseif selected == "echo_isles" then OverlordDB.selectedKeepSiteKey = "crossroads" end
    OverlordDB.guildKeepSiteKeyMigrationVersion = GUILD_KEEP_SITE_KEY_MIGRATION_VERSION
end

local function rebuildProtocol7GenerationZeroNarrative(migratedActiveSites, migratedTerminals)
    local gki = Overlord.GuildKeepImmersion
    local immersion = OverlordDB and OverlordDB.guildKeepImmersion
    if not gki or not immersion or not gki.GetActiveSiege then return end
    local currentDayKey = Overlord.GuildKeep:GetServerSiegeDayKey()
    -- Le bilan a deja ete affiche : conserver ce marqueur sans recreer une activite qui
    -- provoquerait une seconde annonce au prochain tick.
    if immersion.siegeReportDay == currentDayKey then return end

    local function rebuildTerminal(siteKey, proof)
        if not proof or tonumber(proof.generationAt) ~= 0
            or Overlord.GuildKeep:GetServerSiegeDayKey(proof.eventAt)
                ~= currentDayKey then return end
        local siege = gki:GetActiveSiege(siteKey)
        if not siege then return end
        siege.assaultGuild = sanitizeGuildName(proof.guild or "")
        siege.assaultFaction = proof.faction
        siege.defenderGuild = sanitizeGuildName(proof.baseGuild or "")
        siege.inProgress = false
        if proof.kind == "GC" then
            siege.outcome = "captured"
        elseif proof.kind == "GA" and siege.defenderGuild ~= "" then
            siege.outcome = "defended"
        elseif proof.kind == "GA" then
            siege.outcome = "neutral"
        else
            return
        end
        -- Aucune donnee de combat narrative v7 n'est une preuve v8.
        siege.fallen = {}
        siege.repelledKills = 0
        siege.reportPublished = nil
        siege.reportPublishedOutcome = nil
        siege.reportPublishedGuild = nil
        siege.reportPublishedFaction = nil
    end

    for siteKey, proof in pairs(migratedTerminals or {}) do
        rebuildTerminal(siteKey, proof)
    end
    for siteKey in pairs(migratedActiveSites or {}) do
        local st = OverlordDB.guildKeeps[siteKey]
        if st and Overlord.GuildKeep:IsCurrentKeepSiegeState(st)
            and Overlord.GuildKeep:HasAssaultShardAnchor(st)
            and gki.OnSiegeAssaultBegan then
            gki:OnSiegeAssaultBegan(
                siteKey, st.assaultShardGuild, st.assaultShardFaction)
        elseif st then
            -- Une autorite restauree exactement au cutoff peut avoir produit son GA
            -- deterministe avant cette reconstruction.
            local proof = Overlord.GuildKeep:GetCurrentTerminalProof(st)
            if proof then
                proof.pool = normalizeGuildKeepPoolTag(st.pool)
                local dayKey = Overlord.GuildKeep:GetServerSiegeDayKey(proof.eventAt)
                local lb = Overlord.Leaderboard
                proof = lb and lb.NormalizeGuildKeepDailyProof
                    and lb:NormalizeGuildKeepDailyProof(siteKey, dayKey, proof) or nil
            end
            rebuildTerminal(siteKey, proof)
        end
    end
end

function Overlord.GuildKeep:RestoreKeeps()
    local legacyProtocolVersion = tonumber(OverlordDB and OverlordDB.guildKeepProtocolVersion)
    local legacyKeeps, legacySnapshots
    if legacyProtocolVersion == 7 then
        -- Renommer les sites avant de figer la source v7, mais ne pas la passer par la
        -- sanitation v8 avant d'avoir filtre explicitement ses generations.
        migrateProtocol7FixedSiteKeys()
        legacyKeeps = {}
        for siteKey in pairs(Overlord.GuildKeepSites) do
            legacyKeeps[siteKey] = copyProtocol7KeepRow(OverlordDB.guildKeeps[siteKey])
        end
        legacySnapshots = OverlordDB.guildKeepCutoffSnapshots
    end
    self:EnsureDB()
    -- Ancien cache d'affichage jamais relu depuis la convergence du classement.
    -- Le supprimer ici evite de conserver indefiniment une cle par guilde connue.
    OverlordDB.guildFactionMemory = nil
    -- Migration narrative independante : les premiers clients 9.9 ont deja pu
    -- estamper le registre narratif v7 tout en gardant un activeSiege pre-v7. Leur
    -- prochain /reload doit donc nettoyer ce reliquat une seule fois, sans attendre
    -- une nouvelle rupture du protocole terrain et sans toucher aux chroniques.
    local immersion = OverlordDB.guildKeepImmersion
    if type(immersion) == "table" and immersion.protocolVersion ~= 7 then
        immersion.protocolVersion = 7
        immersion.activeSiege = {}
        immersion.fallenSeen = {}
        immersion.siegeOpenAssaultDay = nil
        immersion.siegeReportDay = nil
        immersion.siegeReportSyncDay = nil
        immersion.siegeReportSyncRequestedAt = nil
        immersion.siegeReportPendingSince = nil
        immersion.siegeReportPendingTryAt = nil
        self:MarkDirty()
    end
    local migratedActiveSites, migratedTerminals
    if OverlordDB.guildKeepProtocolVersion ~= 8 then
        -- La rupture reste fail-closed : tables neuves d'abord, puis reimport exclusif des
        -- tuples v7 gen0 qui passent integralement les validateurs v8 ci-dessus.
        OverlordDB.guildKeeps = {}
        for key in pairs(Overlord.GuildKeepSites) do
            OverlordDB.guildKeeps[key] = defaultState()
        end
        OverlordDB.guildKeepTenants = {}
        OverlordDB.guildKeepSiegeWinAwards = {}
        OverlordDB.guildKeepOfficialTenants = {}
        OverlordDB.guildKeepCutoffSnapshots = {}
        if legacyProtocolVersion == 7 and type(legacySnapshots) == "table" then
            -- Source persistante reprise par la barriere GH tranchee. Un /reload au milieu
            -- conserve donc toutes les preuves gen0 sans jamais scanner cette racine ici.
            OverlordDB.guildKeepProtocol7SnapshotsPending = legacySnapshots
        end
        OverlordDB.guildKeepCaptureCounts = nil
        OverlordDB.guildKeepCaptureCountsVersion = nil
        OverlordDB.guildKeepAwardsPurgeVersion = nil
        OverlordDB.guildKeepSiegeWins = nil
        OverlordDB.guildKeepSiegeWinsEpoch = nil
        local proofEpoch = getGuildKeepCampaignStart()
        OverlordDB.guildKeepDailyProofEpoch = proofEpoch > 0 and proofEpoch or nil
        OverlordDB.dominationBoostEvents = nil
        OverlordDB.guildKeepLbTenure = nil
        OverlordDB.guildKeepLbTenureEpoch = nil
        OverlordDB.guildKeepLbPeaks = nil
        OverlordDB.guildKeepLbPeaksEpoch = nil
        OverlordDB.guildKeepProtocolVersion = 8
        if type(immersion) == "table" then
            -- Aucun cache narratif brut ne traverse la rupture. Un siege courant sera
            -- reconstruit plus bas depuis le seul etat terrain gen0 valide.
            immersion.activeSiege = {}
            immersion.fallenSeen = {}
        end
        if legacyProtocolVersion == 7 then
            migratedActiveSites, migratedTerminals = {}, {}
            for siteKey, site in pairs(Overlord.GuildKeepSites) do
                local migrated, active, terminal =
                    migrateProtocol7GenerationZeroState(legacyKeeps[siteKey], site)
                if migrated then
                    OverlordDB.guildKeeps[siteKey] = migrated
                    if active then
                        migratedActiveSites[siteKey] = true
                    elseif terminal then
                        migratedTerminals[siteKey] = terminal
                    end
                end
            end
            migrateProtocol7GenerationZeroProofs(nil, migratedTerminals)
        end
        self:MarkDirty()
    end
    local loginSyncUnconfirmed = Overlord.IsCaptureSyncGateActive and Overlord:IsCaptureSyncGateActive()
    for key in pairs(Overlord.GuildKeepSites) do
        local saved = OverlordDB.guildKeeps[key]
        if type(saved) == "table" then
            if saved.status ~= "in_progress" and saved.status ~= "held" then
                saved.updatedAt = 0
            elseif saved.status == "held" and sanitizeGuildName(saved.ownerGuild or "") == "" then
                saved.updatedAt = 0
            end
        end
        local site = siteByKey[key]
        local st = self:GetState(key)
        local wasInProgress = saved and saved.status == "in_progress"
        if saved then
            for k, v in pairs(saved) do
                if k ~= "isHolding" and k ~= "isPaused" and k ~= "holdAuthorityLocal" and k ~= "holdStartTime" then
                    st[k] = v
                end
            end
        end
        -- Un /reload au moment exact de 22 h ne doit pas effacer l'unique autorite avant
        -- qu'elle ait emis GA. Le flag disque n'est utilise qu'une fois pour sceller au cutoff
        -- deterministe ; avant le cutoff, le client redevient bien simple observateur.
        local savedLocalAuthority = saved and saved.status == "in_progress"
            and saved.holdAuthorityLocal == true
        if savedLocalAuthority then
            st.holdAuthorityLocal = true
            st.isHolding = saved.isHolding == true
            self:ExpirePostCutoffAssault(key, st)
        end
        st.isHolding = false
        st.isPaused = false
        st.holdAuthorityLocal = false
        st.holdStartTime = nil
        -- SaveKeeps ne purge plus les champs transitoires (mutation en place) : ils peuvent
        -- donc survivre en SavedVariables. Les neutraliser ici - les ancres GetTime() d'une
        -- session precedente sont invalides (uptime client). Le nom d'autorite, lui, reste
        -- utile pour relayer un siege courant et sera remplace si ce joueur n'est plus eligible.
        st.isContested = false
        st._gkContestStreak = nil
        st._gkContestSampleAt = nil
        st._gkInGeometrySeenAt = nil
        st.gkLocalDefenseSeenAt = nil
        st._gkOfficialCapturerSeenAt = nil
        st._gkVerifiedCapturerKeys = nil
        self:ClearLocalCrossShardTakeover(st)
        st._lastEnemyInProgressGkAt = nil
        st._gkStaleObserver = nil
        st._observerKeepFinalStatePollCount = nil
        st._observerKeepFinalStatePollAt = nil
        if not wasInProgress and st.status ~= "in_progress" then
            st.gkOfficialCapturerName = nil
            st.gkRelayCapturerName = nil
            st.gkRelayCapturerShard = nil
        end
        clearCanonicalAssaultFields(st)
        -- held : conserve le tenant ; in_progress : filet comme ZoneControl (pas tout effacer)
        if wasInProgress or st.status == "in_progress" then
            RestoreInterruptedKeepCapture(st, site)
        end
        sanitizeKeepState(st, site)
        local claimedAt = math.floor(tonumber(st.claimedAt) or 0)
        local campaignStart = Overlord.Leaderboard and Overlord.Leaderboard.GetCurrentCampaignStart
            and Overlord.Leaderboard:GetCurrentCampaignStart() or (OverlordDB.lastResetTimestamp or 0)
        local confirmedClaim = claimedAt > 0
            and claimedAt >= (tonumber(campaignStart) or 0)
            and self:IsSiegeGameplayTimestampAllowed(claimedAt)
        if loginSyncUnconfirmed and st.status == "held" and sanitizeGuildName(st.ownerGuild or "") ~= ""
            and not confirmedClaim then
            -- Donnee disque provisoire : garder le tenant pour merger, mais ne pas l'afficher ni l'emettre.
            st._loginSyncUnconfirmed = true
            st.updatedAt = 0
        else
            st._loginSyncUnconfirmed = nil
        end
    end
    -- On ne copie ni fallen, ni compteurs, ni timers narratifs v7. La fiche minimale
    -- provient uniquement de l'etat/proof gen0 valide, y compris un terminal deja tombe
    -- avant l'installation afin que son bilan de 22 h ne disparaisse pas.
    if migratedActiveSites or migratedTerminals then
        rebuildProtocol7GenerationZeroNarrative(migratedActiveSites, migratedTerminals)
    end
end

function Overlord.GuildKeep:ResetKeepsForCampaign()
    self:EnsureDB()
    for key in pairs(Overlord.GuildKeepSites) do
        OverlordDB.guildKeeps[key] = defaultState()
    end
    OverlordDB.dominationBoostPct = { Alliance = 0, Horde = 0 }
    OverlordDB.dominationBoostEvents = nil
    OverlordDB.guildKeepOfficialTenants = {}
    OverlordDB.guildKeepCutoffSnapshots = {}
    if Overlord.Leaderboard and Overlord.Leaderboard.RequestGuildKeepProofLedgerRebuild then
        Overlord.Leaderboard:RequestGuildKeepProofLedgerRebuild()
    end
end

local KEEP_MAP_METRICS_RETRY_SEC = 2
local KEEP_WORLD_SQUARE_RETRY_SEC = 2
local keepMapMetrics = {}
local keepMapMetricsRetry = {}
local function GetKeepMapMetrics(mapID)
    if not mapID then return nil end
    if keepMapMetrics[mapID] then return keepMapMetrics[mapID] end
    local now = GetTime()
    local contextKey, contextAt = GetKeepSpatialCacheContext()
    local retry = keepMapMetricsRetry[mapID]
    if retry and retry.contextKey == contextKey and retry.contextAt == contextAt
        and now < (tonumber(retry.at) or 0) then return nil end
    local ok, metrics = pcall(function()
        if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return end
        -- Echantillon interieur : certaines cartes refusent ponctuellement leurs bords exacts
        -- (0/1), surtout pendant un changement de phase. Le ratio reste identique.
        local _, w0 = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.25, 0.25))
        local _, wX = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.75, 0.25))
        local _, wY = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.25, 0.75))
        if w0 and wX and wY then
            local dX = math.sqrt((wX.x - w0.x) ^ 2 + (wX.y - w0.y) ^ 2)
            local dY = math.sqrt((wY.x - w0.x) ^ 2 + (wY.y - w0.y) ^ 2)
            if dX > 0 and dY > 0 then
                return { aspectRatio = dY / dX }
            end
        end
    end)
    if ok and metrics then
        keepMapMetrics[mapID] = metrics
        keepMapMetricsRetry[mapID] = nil
        return metrics
    end
    -- Important : IsMapPointInKeepGeometry est appele pour chaque membre du raid.
    -- Sans cache negatif, un trou C_Map recreait trois vecteurs + un pcall par unite
    -- toutes les deux secondes, puis provoquait de gros passages periodiques du GC.
    keepMapMetricsRetry[mapID] = {
        at = now + KEEP_MAP_METRICS_RETRY_SEC,
        contextKey = contextKey,
        contextAt = contextAt,
    }
    return nil
end

local function GetKeepMapAspectRatio(mapID)
    local metrics = GetKeepMapMetrics(mapID)
    return metrics and metrics.aspectRatio or 1
end

function Overlord.GuildKeep:GetMapAspectRatio(siteOrMapID)
    local mapID = type(siteOrMapID) == "table" and siteOrMapID.mapID or siteOrMapID
    return GetKeepMapAspectRatio(mapID)
end

local function GetConfiguredKeepCaptureHalfSizePercent(site)
    -- Taille historique du point : `halfSize` est la demi-largeur corrigee par l'aspect.
    return math.max(0.01,
        tonumber(site and site.captureHalfSize)
        or tonumber(site and site.halfSize)
        or 1.35)
end

local function GetKeepMapCaptureBounds(site, halfSize, aspect)
    if not site or not site.center or not halfSize or not aspect or aspect <= 0 then return nil end
    local halfY = halfSize / aspect
    return site.center[1] - halfSize, site.center[1] + halfSize,
        site.center[2] - halfY, site.center[2] + halfY
end

function Overlord.GuildKeep:GetKeepCaptureHalfSizePercent(site)
    if not site then return nil end
    return GetConfiguredKeepCaptureHalfSizePercent(site)
end

-- La forme du point reste independante du moteur de contestation partage avec les zones.
-- On conserve ici le carre historique, corrige par l'aspect pour avoir la meme largeur
-- physique sur X et Y.
function Overlord.GuildKeep:IsMapPointInKeepGeometry(site, px, py)
    px, py = tonumber(px), tonumber(py)
    if not site or not site.center or not px or not py then return false, false end
    local halfSize = self:GetKeepCaptureHalfSizePercent(site)
    local metrics = GetKeepMapMetrics(self:GetGeometryMapID(site) or site.mapID)
    if not halfSize then return false, false end
    -- La 9.9.17 gelait tout le gameplay tant que GetWorldPosFromMapPos ne livrait pas
    -- ses trois projections. Or GetPlayerMapPosition peut rester parfaitement exploitable
    -- pendant ce trou (chargement, phasing, resurrection). Reprendre provisoirement le
    -- secours 1:1 de 9.9.16 maintient le timer vivant ; le cache negatif borne toujours
    -- les projections CPU et l'aspect mesure reprend automatiquement au prochain succes.
    local aspect = metrics and metrics.aspectRatio or 1
    local minX, maxX, minY, maxY = GetKeepMapCaptureBounds(
        site, halfSize, aspect)
    if not minX then return false, false end
    -- Comparer aux bornes fermees evite que la soustraction IEEE-754 rejette un bord
    -- decimal exact (par ex. abs(51.35 - 50) > 1.35 en Lua 5.1).
    return px >= minX and px <= maxX and py >= minY and py <= maxY, true
end

function Overlord.GuildKeep:GetKeepWorldCaptureSquare(site)
    if not site or not site.center or not site.mapID or not C_Map
        or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then return nil end
    if site._keepWorldCaptureSquareCache then return site._keepWorldCaptureSquareCache end
    local now = GetTime()
    local contextKey, contextAt = GetKeepSpatialCacheContext()
    local retry = site._keepWorldCaptureSquareRetry
    if retry and retry.contextKey == contextKey and retry.contextAt == contextAt
        and now < (tonumber(retry.at) or 0) then return nil end
    local ok, square = pcall(function()
        local halfSize = self:GetKeepCaptureHalfSizePercent(site)
        -- Ne jamais mettre en cache un carre calcule avec l'aspect de secours : si C_Map
        -- devient disponible ensuite, positions carte et nameplates divergeraient.
        local geomMapID = self:GetGeometryMapID(site)
        if not geomMapID then return nil end
        local metrics = GetKeepMapMetrics(geomMapID)
        local aspect = metrics and metrics.aspectRatio
        if not halfSize or not aspect or aspect <= 0 then return nil end
        local mapMinX, mapMaxX, mapMinY, mapMaxY = GetKeepMapCaptureBounds(
            site, halfSize, aspect)
        if not mapMinX then return nil end
        local minX, maxX, minY, maxY, continentID
        for _, corner in ipairs({
            { mapMinX, mapMinY },
            { mapMinX, mapMaxY },
            { mapMaxX, mapMinY },
            { mapMaxX, mapMaxY },
        }) do
            local cid, world = C_Map.GetWorldPosFromMapPos(
                geomMapID, CreateVector2D(corner[1] / 100, corner[2] / 100))
            local wx, wy = world and tonumber(world.x), world and tonumber(world.y)
            cid = tonumber(cid)
            if not cid or not wx or not wy then return nil end
            if continentID and cid ~= continentID then return nil end
            continentID = cid
            minX, maxX = math.min(minX or wx, wx), math.max(maxX or wx, wx)
            minY, maxY = math.min(minY or wy, wy), math.max(maxY or wy, wy)
        end
        return {
            continentID = continentID,
            minX = minX,
            maxX = maxX,
            minY = minY,
            maxY = maxY,
        }
    end)
    if ok and square then
        site._keepWorldCaptureSquareCache = square
        site._keepWorldCaptureSquareRetry = nil
    else
        -- Meme protection pour les quatre projections de coins : leur echec ne doit
        -- jamais devenir une allocation recurrente dans ScanNearbyKeepPlayers.
        retry = retry or {}
        retry.at = now + KEEP_WORLD_SQUARE_RETRY_SEC
        retry.contextKey = contextKey
        retry.contextAt = contextAt
        site._keepWorldCaptureSquareRetry = retry
    end
    return ok and square or nil
end

-- Meme micro-cache pour la geometrie. La cle du site empeche toute reutilisation entre fortins ;
-- le contexte shard ferme le cache des qu'un hop/chargement est signale.
local keepGeomCache = {
    at = -1, contextKey = "", contextAt = -1, siteKey = nil,
    result = false, known = false,
}

function Overlord.GuildKeep:IsPlayerInKeepGeometry(site)
    site = site or select(2, self:IsPlayerOnKeepMap())
    if not site or not site.center then return false, false end
    local siteKey = site.siteKey or site.id
    local now = GetTime()
    local contextKey, contextAt = GetKeepSpatialCacheContext()
    local cacheAge = now - keepGeomCache.at
    if cacheAge >= 0 and cacheAge <= KEEP_SPATIAL_SAMPLE_CACHE_SEC
        and keepGeomCache.contextKey == contextKey
        and keepGeomCache.contextAt == contextAt
        and keepGeomCache.siteKey == siteKey then
        return keepGeomCache.result, keepGeomCache.known
    end
    local result, sampleKnown = false, false
    -- Meme carte que GetDistanceToGuildKeep : GetBestMapForUnit peut etre une sous-carte
    -- dont les coords ne correspondent pas au centre du site (faux « dans la zone »).
    local onMap, currentSite, mapSampleKnown = self:IsPlayerOnKeepMap()
    local currentSiteKey = currentSite and (currentSite.siteKey or currentSite.id)
    if onMap and currentSiteKey and currentSiteKey ~= siteKey then
        -- Le joueur est sur un autre fortin connu : sortie certaine pour ce site.
        onMap = false
        sampleKnown = true
    elseif not onMap and mapSampleKnown then
        -- Carte connue differente du fortin : vraie sortie, jamais une grace de position.
        sampleKnown = true
    end
    if onMap then
        local mapID = self:GetGeometryMapID(site)
        if not mapID then
            local ok, mid = pcall(C_Map.GetBestMapForUnit, "player")
            if ok and mid then mapID = mid end
        end
        if mapID then
            -- Tout reste dans le pcall : en 12.x, GetXY peut livrer des secret values
            -- qui ne deviennent fautives qu'a la comparaison, conversion ou multiplication.
            local ok2, inside, positionKnown = pcall(function()
                local pos = C_Map.GetPlayerMapPosition(mapID, "player")
                if not pos then return false, false end
                local px, py = pos:GetXY()
                -- (0,0) est le sentinel Blizzard quand la position n'est pas disponible
                -- pendant certains changements de phase/raid ; ce n'est pas une position
                -- reelle hors du carre.
                if px == nil or py == nil or (px == 0 and py == 0) then return false, false end
                return self:IsMapPointInKeepGeometry(site, px * 100, py * 100)
            end)
            if ok2 and positionKnown then
                result = inside and true or false
                sampleKnown = true
            end
        end
    end
    -- Aucune grace gameplay : nil/0,0 arrete la progression ce tick. La grace de dix
    -- secondes reste exclusivement dans IsPlayerInKeepGeometryForHud.
    keepGeomCache.at = now
    keepGeomCache.contextKey = contextKey
    keepGeomCache.contextAt = contextAt
    keepGeomCache.siteKey = siteKey
    keepGeomCache.result = result
    keepGeomCache.known = sampleKnown
    return result, sampleKnown
end

local keepHudGeomLastConfirmed = { at = 0, siteKey = nil }

function Overlord.GuildKeep:IsPlayerInKeepGeometryForHud(site)
    local inGeom, sampleKnown = self:IsPlayerInKeepGeometry(site)
    local siteKey = site and (site.siteKey or site.id)
    local now = GetTime()
    if inGeom then
        -- Seule une vraie coordonnee confirme a nouveau l'ancre HUD.
        if sampleKnown then
            keepHudGeomLastConfirmed.at = now
            keepHudGeomLastConfirmed.siteKey = siteKey
        end
        return true
    end
    if sampleKnown then
        if keepHudGeomLastConfirmed.siteKey == siteKey then
            keepHudGeomLastConfirmed.at = 0
            keepHudGeomLastConfirmed.siteKey = nil
        end
        return false
    end
    return siteKey and keepHudGeomLastConfirmed.siteKey == siteKey
        and now - keepHudGeomLastConfirmed.at <= KEEP_HUD_SAMPLE_GRACE_SEC or false
end

function Overlord.GuildKeep:GetLocalPlayerGuild()
    -- Cache TTL court : appele par message GK in_progress (hot path en siege). SafeGetGuildInfo
    -- alloue une closure pcall(function()) a chaque appel ; la guilde du joueur ne change qu'au
    -- gquit/gjoin (rare), donc un cache 10s evite N closures/sec sans risque de staleness gameplay.
    if not Overlord.SafeGetGuildInfo then return "" end
    local now = GetTime()
    if self._localGuildCache ~= nil and (now - (self._localGuildCacheAt or 0)) < 10 then
        return self._localGuildCache
    end
    local g = sanitizeGuildName(Overlord:SafeGetGuildInfo("player") or "")
    self._localGuildCache = g
    self._localGuildCacheAt = now
    return g
end

-- Faction connue d'une guilde GK. Les seules projections de classement ne suffisent pas :
-- il faut une majorite de membres observes dans le leaderboard courant.
function Overlord.GuildKeep:GetKnownGuildFaction(guild)
    guild = sanitizeGuildName(guild or "")
    if guild == "" then return nil end
    local guildKey = guild:lower()

    -- Cache O(1) memoise par guilde, invalide par Leaderboard:MarkMetaDirty (tout changement
    -- de faction/guilde dans playerInfo). Les votes complets sont construits par la meme
    -- coroutine budgetee que l'index meta; ce getter gameplay ne scanne jamais playerInfo.
    local lb = Overlord.Leaderboard
    if lb then
        local cache = lb.guildFactionCache
        if cache then
            local cached = cache[guildKey]
            if cached == "Alliance" or cached == "Horde" then return cached end
            if cached == false then return nil end
        end
    end

    local voteIndex = lb and lb._guildFactionVoteIndex
    if type(voteIndex) ~= "table" then
        if lb and lb.EnsureNetworkHotIndexesPrepared then
            lb:EnsureNetworkHotIndexesPrepared()
        end
        return nil
    end
    local memberVotes = voteIndex[guildKey] or { Alliance = 0, Horde = 0 }

    local result = nil
    if memberVotes.Alliance >= 2 and memberVotes.Alliance > memberVotes.Horde then
        result = "Alliance"
    elseif memberVotes.Horde >= 2 and memberVotes.Horde > memberVotes.Alliance then
        result = "Horde"
    end

    if lb then
        if not lb.guildFactionCache then lb.guildFactionCache = {} end
        lb.guildFactionCache[guildKey] = result or false
    end
    return result
end

function Overlord.GuildKeep:GetEffectiveGuildFaction(guild, fallbackFaction)
    local known = self:GetKnownGuildFaction(guild)
    if known then return known end
    if fallbackFaction == "Alliance" or fallbackFaction == "Horde" then return fallbackFaction end
    return nil
end

function Overlord.GuildKeep:GetEffectiveHeldTenant(st, siteKey)
    siteKey = tostring(siteKey or "")
    local function readLocalHeld()
        if not st or st.status ~= "held" then return nil end
        if self:IsKeepStateAwaitingNetworkSnapshot(st) then return nil end
        local guild = sanitizeGuildName(st.ownerGuild or "")
        if guild == "" then return nil end
        -- Faction STOCKEE d'abord (payload declare, fiable), heuristique de vote en secours
        -- seulement : le vote par nom de guilde est empoisonnable par homonymie cross-royaume
        -- et faisait afficher/arbitrer la mauvaise faction malgre un etat correct.
        local faction = (st.ownerFaction == "Alliance" or st.ownerFaction == "Horde")
            and st.ownerFaction or self:GetKnownGuildFaction(guild)
        if faction ~= "Alliance" and faction ~= "Horde" then return nil end
        return guild, faction, math.floor(tonumber(st.claimedAt) or 0),
            math.floor(tonumber(st.expiresAt) or 0), st.pool, false
    end
    local function readOfficial()
        if siteKey == "" or not self.GetOfficialKeepTenant then return nil end
        local official = self:GetOfficialKeepTenant(siteKey)
        if not official then return nil end
        local guild = sanitizeGuildName(official.guild or "")
        local faction = official.faction
        if guild == "" or (faction ~= "Alliance" and faction ~= "Horde") then return nil end
        local oca = math.floor(tonumber(official.claimedAt) or 0)
        local captureAt = oca
        return guild, faction, oca, 0, official.pool, true, captureAt
    end
    local localGuild, localFaction, localClaimedAt, localExpiresAt, localPool = readLocalHeld()
    local og, of, oca, _, op, _, oCaptureAt = readOfficial()
    -- Une ligne officielle est la projection locale d'un terminal v8 accepte.
    -- Elle prime toujours sur le cache local held, meme si ce cache porte un timestamp
    -- plus recent (reload ou rattrapage). Le cache n'est qu'un secours quand
    -- aucune preuve terrain canonique n'est encore disponible.
    if og and of then
        return og, of, math.floor(tonumber(oCaptureAt) or oca or 0), 0, op or "", true
    end
    if localGuild and localFaction then
        return localGuild, localFaction, localClaimedAt,
            localExpiresAt or 0, localPool or "", false
    end
    return "", nil, 0, 0, "", false
end

function Overlord.GuildKeep:CanPlayerContestKeep(st, siteKey)
    if not st then return true end
    if st.status ~= "held" then return true end
    local playerGuild = self:GetLocalPlayerGuild()
    -- La faction du joueur local est CERTAINE (client WoW) : jamais surchargee par le vote.
    local guildFaction = Overlord.PlayerFaction
        or self:GetKnownGuildFaction(playerGuild)
    if not guildFaction then
        if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
            print(string.format(
                "|cFFFF4444[Overlord:dbg]|r CanPlayerContestKeep %s: bloque, faction joueur inconnue (guilde=%s)",
                tostring(siteKey), tostring(playerGuild)))
        end
        return false
    end
    -- Tenant officiel prime ; sinon held local (login / snapshot GK en attente).
    local ownerGuild, ownerFaction = self:GetEffectiveHeldTenant(st, siteKey)
    if ownerGuild == "" then
        ownerGuild = sanitizeGuildName(st.ownerGuild or "")
        ownerFaction = (st.ownerFaction == "Alliance" or st.ownerFaction == "Horde")
            and st.ownerFaction or self:GetKnownGuildFaction(ownerGuild)
    end
    if ownerGuild == "" then return false end
    if playerGuild ~= "" and ownerGuild == playerGuild then return false end
    if not ownerFaction then
        if OverlordDB and OverlordDB.config and OverlordDB.config.debug then
            print(string.format(
                "|cFFFF4444[Overlord:dbg]|r CanPlayerContestKeep %s: bloque, faction du tenant '%s' non resolue (st.ownerFaction=%s)",
                tostring(siteKey), tostring(ownerGuild), tostring(st.ownerFaction)))
        end
        return false
    end
    return guildFaction ~= ownerFaction
end

-- Defenseur allie dans le carre (fortin tenu par notre faction, pas d'attaque en cours).
function Overlord.GuildKeep:IsPlayerDefendingHeldKeep(st, siteKey)
    if not st or st.status ~= "held" then return false end
    local pf = Overlord.PlayerFaction
    local ownerGuild, ownerFaction = self:GetEffectiveHeldTenant(st, siteKey)
    if ownerGuild == "" then
        -- Faction stockee d'abord, vote heuristique en secours (anti-homonymie).
        ownerFaction = (st.ownerFaction == "Alliance" or st.ownerFaction == "Horde")
            and st.ownerFaction or self:GetKnownGuildFaction(st.ownerGuild or "")
    end
    if not pf or not ownerFaction or pf ~= ownerFaction then return false end
    return true
end

-- Siege ouvert + etat attaquable (neutre ou tenu ennemi).
function Overlord.GuildKeep:CanPlayerAssaultKeepState(st, siteKey)
    if not st then return false end
    if self.IsSiegeWindowOpen and not self:IsSiegeWindowOpen() then return false end
    local guild = self:GetLocalPlayerGuild()
    local pf = Overlord.PlayerFaction
    if guild == "" or not pf then return false end
    -- Neutre local : assaut sauf si le tenant affiché est déjà le nôtre ou notre faction.
    if st.status == "neutral" then
        if siteKey and self.GetKeepDisplayTenant then
            local dg, df = self:GetKeepDisplayTenant(st, siteKey)
            dg = sanitizeGuildName(dg or "")
            if dg ~= "" and dg == guild then return false end
            if dg ~= "" and df and df == pf then return false end
        end
        return true
    end
    if st.status == "held" then return self:CanPlayerContestKeep(st, siteKey) end
    return false
end

-- Peut demarrer une capture locale : neutre, ou fortin tenu par l'ennemi.
function Overlord.GuildKeep:CanPlayerStartCapture(st, notify, siteKey)
    return self:CanPlayerAssaultKeepState(st, siteKey)
end

-- Observateur : assaut recu par GK (updatedAt > 0) pendant la fenetre de siege.
function Overlord.GuildKeep:CanPlayerObserveKeepSiege(st)
    return self:IsCurrentKeepSiegeState(st)
end

-- Rafraichit carte, HUD capture et panneaux fortin apres changement d'etat.
-- Throttle 2 s par site pour eviter les cascades UI en capture active (50 GK/30s).
local lastPresentationRefresh = {}
local PRESENTATION_THROTTLE = 2
function Overlord.GuildKeep:RefreshKeepPresentation(siteKey, force)
    local now = GetTime()
    local key = siteKey or ""
    if not force and lastPresentationRefresh[key]
        and (now - lastPresentationRefresh[key]) < PRESENTATION_THROTTLE then
        return
    end
    lastPresentationRefresh[key] = now
    if Overlord.MapMarkers and Overlord.MapMarkers.RefreshGuildKeepMapIfOpen then
        Overlord.MapMarkers:RefreshGuildKeepMapIfOpen()
    end
    if Overlord.MapMarkers and Overlord.MapMarkers.CheckGuildKeepMinimap then
        Overlord.MapMarkers:CheckGuildKeepMinimap()
    end
    if Overlord.ZoneIndicator and Overlord.ZoneIndicator.RefreshHud then
        Overlord.ZoneIndicator:RefreshHud()
    end
    if Overlord.Ressources and Overlord.Ressources.RefreshGuildKeepHUD then
        Overlord.Ressources:RefreshGuildKeepHUD()
    elseif Overlord.UI and Overlord.UI.RefreshGuildKeepRow then
        Overlord.UI:RefreshGuildKeepRow()
    end
end

-- L'identite canonique est exactement celle de l'ancre elue, toutes factions confondues.
function Overlord.GuildKeep:GetCanonicalAssaultGuild(st)
    if not st or st.status ~= "in_progress" then return "", nil end
    local g = sanitizeGuildName(st.canonicalAssaultGuild or "")
    if g == "" then return "", nil end
    return g, st.canonicalAssaultFaction
end

function Overlord.GuildKeep:ResolveCanonicalAssaultGuild(st)
    if not st then return "", nil, 0 end
    if st.status ~= "in_progress" or not self:IsCurrentKeepSiegeState(st)
        or not self:HasAssaultShardAnchor(st) then
        clearCanonicalAssaultFields(st)
        return "", nil, 0
    end
    local winnerGuild = sanitizeGuildName(st.assaultShardGuild or "")
    local winnerFaction = st.assaultShardFaction
    local winnerStartedAt = self:GetAssaultShardStartedAt(st)
    st.canonicalAssaultGuild = winnerGuild
    st.canonicalAssaultFaction = winnerFaction
    st.canonicalAssaultStartedAt = winnerStartedAt
    st.ownerGuild = winnerGuild
    st.ownerFaction = winnerFaction
    return winnerGuild, winnerFaction, winnerStartedAt
end

function Overlord.GuildKeep:ApplyRemoteState(siteKey, remote, suppressPresentation)
    local st = self:GetState(siteKey)
    if not st or not remote or not VALID_KEEP_STATUS[remote.status] then return false end
    local deferredLineageOwnedBefore = self:DeferredLineageOwnsCurrentState(st)

    local beforeStatus = st.status
    local beforeGuild = sanitizeGuildName(st.ownerGuild or "")
    local beforeFaction = st.ownerFaction
    local beforeHold = math.floor(tonumber(st.holdTimeElapsed) or 0)
    local beforeContested = st.isContested and true or false
    local beforeAuthority = normalizeGkCapturerNameDefer(self:GetEffectiveCapturerName(st))
    local beforeShard = normalizeAssaultShardId(st.assaultShardId)

    local remoteTs = math.floor(tonumber(remote.updatedAt) or 0)
    if remote.status == "held" then
        -- Les finals v8 passent exclusivement par GC/CompleteCapture.
        return false
    end
    if remote.status == "neutral" then
        -- Un snapshot neutre ne peut jamais annuler un siege ou une possession.
        if st.status ~= "neutral" then return false end
        if remoteTs > (tonumber(st.updatedAt) or 0) then
            st.updatedAt = remoteTs
            st._loginSyncUnconfirmed = nil
        end
        return false
    end

    local remoteGuild = sanitizeGuildName(remote.ownerGuild or "")
    local remoteFaction = remote.assaultShardFaction or remote.ownerFaction
    local remoteShard = normalizeAssaultShardId(remote.assaultShardId)
    local remoteStartedAt = math.floor(tonumber(remote.assaultShardStartedAt) or 0)
    local remoteGenerationAt = math.floor(tonumber(remote.assaultGenerationAt) or 0)
    local remotePlayer = normalizeAssaultShardPlayer(remote.assaultShardPlayer)
    local remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt, remoteBaseValid =
        normalizeAssaultBase(remote.assaultBaseGuild, remote.assaultBaseFaction,
            remote.assaultBaseCapturedAt)
    if remote.assaultAnchorVerified ~= true or remoteTs <= 0 or remoteGuild == ""
        or (remoteFaction ~= "Alliance" and remoteFaction ~= "Horde")
        or not remoteShard or remoteStartedAt <= 0 or remoteGenerationAt < 0
        or remoteGenerationAt > 1000000 or remotePlayer == ""
        or not remoteBaseValid then
        return false
    end
    if not self:IsAssaultBaseCompatibleWithHeldState(
        st, remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt,
        remoteStartedAt) then return false end

    local sameAnchor = self:ActiveAssaultAnchorMatches(
        st, remoteGuild, remoteFaction, remoteShard, remoteStartedAt,
        remoteGenerationAt, remotePlayer,
        remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt)
    local remoteWins = self:WouldAdoptAssaultAnchor(
        st, remoteGuild, remoteFaction, remoteShard, remoteStartedAt,
        remoteGenerationAt, remotePlayer,
        remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt)
    if not sameAnchor and not remoteWins then
        -- Un candidat perdant ne touche ni le timer, ni le tenant, ni le contact actif.
        return false
    end
    if st.status ~= "in_progress" and not self:IsAssaultCandidateNewerThanFinal(
        st, remoteGuild, remoteFaction, remoteShard, remoteStartedAt,
        remoteGenerationAt, remotePlayer,
        remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt) then
        -- Un heartbeat retarde de l'episode deja finalise ne peut pas rouvrir le keep.
        return false
    end
    local localTs = math.floor(tonumber(st.updatedAt) or 0)
    local authorityPlayer = normalizeGkCapturerNameDefer(remote.gkRelayCapturerName)
    if sameAnchor and remote.capturerSourceVerified == true then
        -- Une heartbeat directe peut rafraichir l'autorite meme si son timer arrive en retard.
        self:StoreGkOfficialCapturerFromRemote(
            st, authorityPlayer, remoteShard, remote.gkRelaySenderFallback, true)
    end
    if sameAnchor and localTs > 0 and remoteTs < localTs then return false end
    if sameAnchor and localTs > 0 and remoteTs == localTs then
        -- GetServerTime a une resolution d'une seconde : deux relais du meme assaut peuvent
        -- porter le meme timestamp avec des chronos differents. Sans tie-break, le dernier
        -- paquet gagne et les observateurs divergent. Le hold le plus haut gagne ; a egalite,
        -- contested=true est le choix conservateur et deterministe.
        local req = self:GetDefaultHoldTimeRequired(st, self:GetSite(siteKey))
        local cap = math.max(req - 1, 0)
        local localHold = math.max(0, math.min(
            math.floor(tonumber(st.holdTimeElapsed) or 0), cap))
        local remoteHold = math.max(0, math.min(
            math.floor(tonumber(remote.holdTimeElapsed) or 0), cap))
        if remoteHold < localHold then return false end
        if remoteHold == localHold and st.isContested and not remote.isContested then
            return false
        end
    end
    local resolvesConcurrentFinal = st.status ~= "in_progress"
        and sanitizeGuildName(st.finalAssaultBaseGuild or ""):lower() == remoteBaseGuild:lower()
        and st.finalAssaultBaseFaction == remoteBaseFaction
        and math.floor(tonumber(st.finalAssaultBaseCapturedAt) or 0) == remoteBaseCapturedAt
    -- Le receveur peut avoir manque toute la tenure intermediaire. L'identite distante
    -- prouve alors une base plus recente et, par construction, une faction assaillante
    -- opposee a CETTE base. Ne pas la comparer a la faction du vieux tenant local : dans
    -- une chaine H -> A -> H cela rejetait justement le heartbeat H valide.
    local catchesUpNewerBase = st.status ~= "in_progress"
        and remoteBaseCapturedAt > math.floor(tonumber(st.claimedAt) or 0)
    if not resolvesConcurrentFinal and not catchesUpNewerBase
        and not self:IsCaptureTakeoverAllowed(st, remoteGuild, remoteFaction, siteKey) then
        return false
    end

    local prevGuild, prevFaction, prevClaimedAt, prevExpiresAt =
        remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt, 0

    local changedAnchor = not sameAnchor
    if changedAnchor then
        -- Le gagnant de l'ordre total remplace atomiquement toute l'identite precedente.
        st.holdAuthorityLocal = false
        st.isHolding = false
        st.isPaused = false
        st.isContested = false
        st._gkContestStreak = nil
        st.holdStartTime = nil
        st.holdTimeElapsed = 0
        st.updatedAt = 0
        self:ClearGkCapturerFields(st)
        if not self:AdoptAssaultAnchor(
            st, remoteGuild, remoteFaction, remoteShard, remoteStartedAt,
            remoteGenerationAt, remotePlayer,
            remoteBaseGuild, remoteBaseFaction, remoteBaseCapturedAt) then
            return false
        end
    end

    st.status = "in_progress"
    st.ownerGuild = remoteGuild
    st.ownerFaction = remoteFaction
    st.claimedAt = 0
    st.expiresAt = 0
    st.previousOwnerGuild = prevGuild
    st.previousOwnerFaction = prevFaction
    st.previousClaimedAt = prevClaimedAt
    st.previousExpiresAt = prevExpiresAt
    local site = self:GetSite(siteKey)
    local remoteRequirement = self:NormalizeHoldTimeRequired(
        remote.holdTimeRequired, site)
    local localRequirement = self:GetDefaultHoldTimeRequired(st, site)
    st.holdTimeRequired = changedAnchor
        and remoteRequirement or math.min(localRequirement, remoteRequirement)
    st.pool = normalizeGuildKeepPoolTag(remote.pool)
    st._loginSyncUnconfirmed = nil
    st._gkStaleObserver = nil

    self:ResolveCanonicalAssaultGuild(st)
    self:StoreGkOfficialCapturerFromRemote(
        st, authorityPlayer, remoteShard, remote.gkRelaySenderFallback,
        remote.capturerSourceVerified == true)

    if st.holdAuthorityLocal and self:ShouldDeferToRemoteKeepCapturer(st) then
        st.holdAuthorityLocal = false
        st.isHolding = false
        st.isPaused = false
        st.isContested = false
        st._gkContestStreak = nil
        st.holdStartTime = nil
    end
    self:StripLocalAuthorityIfWrongAssaultShard(st, siteKey)

    local applyHold, remoteHold = self:ShouldApplyRemoteKeepHold(
        st, siteKey, tonumber(remote.holdTimeElapsed) or 0, remoteTs,
        remote.capturerSourceVerified == true)
    if applyHold then
        local req = self:GetDefaultHoldTimeRequired(st, self:GetSite(siteKey))
        st.holdTimeElapsed = math.max(0, math.min(
            tonumber(remoteHold) or 0, math.max(req - 1, 0)))
    end
    if not st.holdAuthorityLocal then
        st.isHolding = false
        st.isPaused = false
        st.isContested = remote.isContested and true or false
        st.holdStartTime = nil
    end
    st.updatedAt = changedAnchor and remoteTs or math.max(localTs, remoteTs)

    self:RememberDeferredLineageCurrentAssault(st, deferredLineageOwnedBefore)
    self:MarkDirty()
    local presentationChanged = beforeStatus ~= st.status
        or beforeGuild ~= sanitizeGuildName(st.ownerGuild or "")
        or beforeFaction ~= st.ownerFaction
        or beforeHold ~= math.floor(tonumber(st.holdTimeElapsed) or 0)
        or beforeContested ~= (st.isContested and true or false)
        or beforeAuthority ~= normalizeGkCapturerNameDefer(self:GetEffectiveCapturerName(st))
        or beforeShard ~= normalizeAssaultShardId(st.assaultShardId)
    local recoveryAdvanced = changedAnchor or remoteTs > localTs or presentationChanged
    -- Un echo exact du meme in_progress ne constitue pas une progression vers le final.
    -- Conserver les compteurs dans ce cas empeche un pair observateur stale de rearmer
    -- indefiniment les deux backoffs de recuperation.
    if recoveryAdvanced then
        st._observerKeepFinalStatePollCount = nil
        st._observerKeepFinalStatePollAt = nil
    end
    if presentationChanged and not suppressPresentation then
        self:RefreshKeepPresentation(siteKey)
    end
    return true, recoveryAdvanced
end

-- Royaumes francophones EU mal classes : retag eu -> fr sur l'etat fortin local.
function Overlord.GuildKeep:MigrateKeepStatesPoolTag(fromPool, toPool)
    fromPool = normalizeGuildKeepPoolTag(fromPool)
    toPool = normalizeGuildKeepPoolTag(toPool)
    if fromPool == "" or toPool == "" or fromPool == toPool then return false end
    local changed = false
    for key in pairs(Overlord.GuildKeepSites or {}) do
        local st = self:GetState(key)
        if st and normalizeGuildKeepPoolTag(st.pool) == fromPool then
            st.pool = toPool
            changed = true
        end
    end
    if changed then
        self:SaveKeeps()
        self:MarkDirty()
    end
    return changed
end

-- Changement de pool SavedVariables : aucune capture/tenure de l'ancien pool ne doit
-- etre reetiquetee puis emise dans le nouveau. Les in_progress sans tag viennent des
-- premiers builds 9.9.1 et sont donc eux aussi neutralises pendant ce changement explicite.
function Overlord.GuildKeep:ClearForeignPoolHeldStates()
    local localPool = currentGuildKeepPoolTag()
    if localPool == "" then return end
    local changed = false
    for key in pairs(Overlord.GuildKeepSites or {}) do
        local st = self:GetState(key)
        local neutralTerminal = st and st.status == "neutral"
            and ((tonumber(st.abortedAssaultAt) or 0) > 0
                or (tonumber(st.finalAssaultCapturedAt) or 0) > 0)
        if st and (st.status == "held" or st.status == "in_progress" or neutralTerminal) then
            local pool = normalizeGuildKeepPoolTag(st.pool)
            if pool == "" or pool ~= localPool then
                resetGuildKeepStateToNeutral(st)
                changed = true
            end
        end
    end
    if changed then
        self:SaveKeeps()
        self:MarkDirty()
    end
end

-- Valide une prise de fortin (locale ou GC) : pas de vol allie ni auto-vol cross-faction.
function Overlord.GuildKeep:IsCaptureTakeoverAllowed(st, guild, faction, siteKey)
    if not st or not faction then return false end
    guild = sanitizeGuildName(guild or "")
    if guild == "" then return false end
    -- Faction declaree du capturant d'abord (il connait sa propre guilde avec certitude) ;
    -- l'heuristique de vote, empoisonnable par homonymie cross-royaume, n'est qu'un secours.
    local effectiveFaction = (faction == "Alliance" or faction == "Horde")
        and faction or self:GetKnownGuildFaction(guild)
    if not effectiveFaction then return false end
    local tg, tf = self:GetEffectiveHeldTenant(st, siteKey)
    if st.status == "held" or (st.status == "neutral" and tg ~= "") then
        if tg ~= "" and guild == tg then
            return false
        end
        if tg ~= "" and tf == effectiveFaction and guild ~= tg then
            return false
        end
    elseif st.status == "in_progress" then
        local pg = sanitizeGuildName(st.previousOwnerGuild or "")
        local pf = st.previousOwnerFaction
        if pg == "" and tg ~= "" then
            pg = tg
            pf = tf
        end
        if pg ~= "" and guild == pg then
            return false
        end
        if pg ~= "" and pf == effectiveFaction and guild ~= pg then
            return false
        end
        if st.ownerFaction == effectiveFaction and pg ~= "" and pf == effectiveFaction then
            return false
        end
    end
    return true
end

-- Preflight strictement non-mutant des memes regles causales qu'AbortAssault.
-- Le sync peut ainsi rejeter un terminal relaye avant toute mutation locale.
function Overlord.GuildKeep:CanAcceptGuildKeepAbort(
    st, guild, faction, abortedAt, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt)
    abortedAt = math.floor(tonumber(abortedAt) or 0)
    local valid
    guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    local attemptStartedAt = assaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
    if not st or not valid or abortedAt < attemptStartedAt
        or self:GetServerSiegeDayKey(anchorStartedAt)
            ~= self:GetServerSiegeDayKey(abortedAt) then return false end
    if self:IsAssaultRetryInvalidatedByPriorCapture(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt) then return false end

    local exactActive = self:ActiveAssaultAnchorMatches(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt)
    local hasActive = st.status == "in_progress" and self:HasAssaultShardAnchor(st)
    local beatsActive = assaultIdentityWins(
        guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt,
        st.assaultShardGuild, st.assaultShardFaction, st.assaultShardId,
        st.assaultShardStartedAt, st.assaultGenerationAt, st.assaultShardPlayer,
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
    local alreadyRestored = (baseGuild == "" and st.status == "neutral")
        or (baseGuild ~= "" and st.status == "held"
            and sanitizeGuildName(st.ownerGuild or ""):lower() == baseGuild:lower()
            and st.ownerFaction == baseFaction
            and math.floor(tonumber(st.claimedAt) or 0) == baseCapturedAt)
    local abortCandidate = {
        kind = "GA", eventAt = abortedAt,
        guild = guild, faction = faction, shard = anchorShard,
        startedAt = anchorStartedAt, generationAt = anchorGenerationAt,
        player = anchorPlayer, baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }
    local currentFinal = {
        kind = "GC", eventAt = st.finalAssaultCapturedAt,
        guild = st.finalAssaultGuild, faction = st.finalAssaultFaction,
        shard = st.finalAssaultShardId, startedAt = st.finalAssaultStartedAt,
        generationAt = st.finalAssaultGenerationAt, player = st.finalAssaultPlayer,
        baseGuild = st.finalAssaultBaseGuild, baseFaction = st.finalAssaultBaseFaction,
        baseCapturedAt = st.finalAssaultBaseCapturedAt,
    }
    local beatsCurrentFinal = assaultResolutionWins(abortCandidate, currentFinal)
    local finalBeatsAbort = assaultResolutionWins(currentFinal, abortCandidate)
    -- Un etat legacy peut avoir ete rouvert tout en conservant son GC exact. Cette
    -- preuve finale reste prioritaire meme si un vieux GK a recree status=in_progress.
    if finalBeatsAbort then return false end
    if not hasActive and not self:IsAssaultBaseCompatibleWithHeldState(
        st, baseGuild, baseFaction, baseCapturedAt, anchorStartedAt) then return false end
    if hasActive then
        if not exactActive and not beatsActive then return false end
    elseif not alreadyRestored and not beatsCurrentFinal then
        return false
    end

    if self:HasAbortedAssaultAnchor(st) and not assaultResolutionWins(abortCandidate, {
        kind = "GA", eventAt = st.abortedAssaultAt,
        guild = st.abortedAssaultGuild, faction = st.abortedAssaultFaction,
        shard = st.abortedAssaultShardId, startedAt = st.abortedAssaultStartedAt,
        generationAt = st.abortedAssaultGenerationAt, player = st.abortedAssaultPlayer,
        baseGuild = st.abortedAssaultBaseGuild,
        baseFaction = st.abortedAssaultBaseFaction,
        baseCapturedAt = st.abortedAssaultBaseCapturedAt,
    }) then return false end
    return true
end

-- Termine uniquement l'assaut explicitement nomme. Un abandon retarde d'une ancienne
-- ancre ne peut donc jamais annuler un nouveau siege ou une capture finale.
function Overlord.GuildKeep:AbortAssault(
    siteKey, guild, faction, abortedAt, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt, terminalAuthorityPlayer,
    suppressPresentation)
    local st = self:GetState(siteKey)
    local deferredLineageOwnedBefore = self:DeferredLineageOwnsCurrentState(st)
    abortedAt = math.floor(tonumber(abortedAt) or 0)
    local preservedTerminalAuthority = ""
    local valid
    guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    local attemptStartedAt = assaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
    if not st or not valid or abortedAt < attemptStartedAt
        or self:GetServerSiegeDayKey(anchorStartedAt)
            ~= self:GetServerSiegeDayKey(abortedAt) then return false end
    if self:AbortedAssaultAnchorMatches(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt) then
        preservedTerminalAuthority = normalizeAssaultShardPlayer(
            st.abortedAssaultAuthorityPlayer)
    end
    if not self:CanAcceptGuildKeepAbort(
        st, guild, faction, abortedAt, anchorShard, anchorStartedAt,
        anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt) then return false end
    if not self:RecordAbortedAssaultAnchor(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, abortedAt) then return false end
    terminalAuthorityPlayer = normalizeAssaultShardPlayer(terminalAuthorityPlayer)
    -- Un GC/GA nu ne prouve pas le successeur observe localement par CE recepteur. Utiliser
    -- l'Anchor comme fallback deterministe ; le GK terminal enrichi pourra ensuite le promouvoir.
    st.abortedAssaultAuthorityPlayer = self:ChooseTerminalAuthority(
        anchorPlayer, preservedTerminalAuthority, terminalAuthorityPlayer)
    local finalIsBase = baseGuild ~= ""
        and sanitizeGuildName(st.finalAssaultGuild or ""):lower() == baseGuild:lower()
        and st.finalAssaultFaction == baseFaction
        and math.floor(tonumber(st.finalAssaultCapturedAt) or 0) == baseCapturedAt

    self:ClearGkCapturerFields(st)
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    st.holdTimeElapsed = 0
    st.previousOwnerGuild = ""
    st.previousOwnerFaction = nil
    st.previousClaimedAt = 0
    st.previousExpiresAt = 0
    st.updatedAt = abortedAt
    st._gkStaleObserver = nil
    if baseGuild ~= "" then
        st.status = "held"
        st.ownerGuild = baseGuild
        st.ownerFaction = baseFaction
        st.claimedAt = baseCapturedAt
        st.expiresAt = 0
        st.pool = currentGuildKeepPoolTag()
        if not finalIsBase then clearFinalAssaultFields(st) end
        self:RecordOfficialKeepTenant(
            siteKey, baseGuild, baseFaction, baseCapturedAt, st.pool, true)
        if Overlord.Leaderboard and Overlord.Leaderboard.SetGuildKeepTenantLocal then
            Overlord.Leaderboard:SetGuildKeepTenantLocal(
                siteKey, baseGuild, baseFaction, baseCapturedAt, true)
        end
    else
        st.status = "neutral"
        st.ownerGuild = ""
        st.ownerFaction = nil
        st.claimedAt = 0
        st.expiresAt = 0
        -- Neutral visuel, mais terminal GA causal : garder le pool qui l'a produit.
        st.pool = currentGuildKeepPoolTag()
        clearFinalAssaultFields(st)
        self:ClearOfficialKeepTenant(siteKey)
        if Overlord.Leaderboard and Overlord.Leaderboard.ClearGuildKeepTenantLocal then
            Overlord.Leaderboard:ClearGuildKeepTenantLocal(siteKey)
        end
    end
    self:RememberDeferredLineageTerminal(st, {
        kind = "GA", eventAt = abortedAt, guild = guild, faction = faction,
        shard = anchorShard, startedAt = anchorStartedAt,
        generationAt = anchorGenerationAt, player = anchorPlayer,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }, deferredLineageOwnedBefore)
    self:MarkDirty()
    if not suppressPresentation then self:RefreshKeepPresentation(siteKey, true) end
    return true
end

function Overlord.GuildKeep:CompleteCapture(
    siteKey, guild, faction, captureTs, anchorShard, anchorStartedAt,
    anchorGenerationAt, anchorPlayer,
    baseGuild, baseFaction, baseCapturedAt, terminalAuthorityPlayer,
    suppressCaptureAlerts, suppressPresentation)
    local st = self:GetState(siteKey)
    if not st then return false end
    local deferredLineageOwnedBefore = self:DeferredLineageOwnsCurrentState(st)
    captureTs = math.floor(tonumber(captureTs) or GetUtcEpoch())
    local preservedTerminalAuthority = ""
    local valid
    guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, valid = normalizeAssaultIdentity(
            guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
    local attemptStartedAt = assaultAttemptStartedAt(anchorStartedAt, anchorGenerationAt)
    if not valid
        or captureTs < attemptStartedAt
        or (self.GetServerSiegeDayKey
            and self:GetServerSiegeDayKey(anchorStartedAt) ~= self:GetServerSiegeDayKey(captureTs)) then
        return false
    end
    if self:FinalAssaultAnchorMatches(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt) then
        preservedTerminalAuthority = normalizeAssaultShardPlayer(
            st.finalAssaultAuthorityPlayer)
    end
    -- Un terminal peut legalement provenir d'une attaque d'or (-60 s), y compris
    -- chez un observateur froid qui a manque le premier heartbeat GK.
    local req = self:GetMinimumHoldTimeRequired(self:GetSite(siteKey))
    if captureTs - attemptStartedAt < math.max(0, req - 1) then return false end
    if not self:IsSiegeGameplayTimestampAllowed(captureTs) then return false end
    local repairsPriorBase = self:IsPriorCaptureCorrectionForCurrentLineage(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, captureTs, siteKey)
    local deferredSuccessor = repairsPriorBase and self:GetCurrentTerminalProof(st) or nil
    local deferredActiveSuccessor
    if repairsPriorBase and not deferredSuccessor and st.status == "in_progress"
        and self:HasAssaultShardAnchor(st) then
        local activeGuild, activeFaction = self:GetCanonicalAssaultGuild(st)
        if activeGuild == "" then
            activeGuild = sanitizeGuildName(st.assaultShardGuild or st.ownerGuild or "")
            activeFaction = st.assaultShardFaction or st.ownerFaction
        end
        deferredActiveSuccessor = {
            status = "in_progress",
            ownerGuild = activeGuild,
            ownerFaction = activeFaction,
            holdTimeElapsed = math.max(0, math.floor(tonumber(st.holdTimeElapsed) or 0)),
            updatedAt = math.max(
                math.floor(tonumber(st.updatedAt) or 0),
                self:GetAssaultShardStartedAt(st)),
            isContested = st.isContested and true or false,
            assaultShardId = self:GetAssaultShardId(st),
            assaultShardStartedAt = self:GetAssaultShardStartedAt(st),
            assaultGenerationAt = self:GetAssaultGenerationAt(st),
            assaultShardPlayer = self:GetAssaultShardPlayer(st),
            assaultShardFaction = activeFaction,
            assaultBaseGuild = sanitizeGuildName(st.assaultBaseGuild or ""),
            assaultBaseFaction = st.assaultBaseFaction,
            assaultBaseCapturedAt = math.floor(tonumber(st.assaultBaseCapturedAt) or 0),
            assaultAnchorVerified = true,
            -- Une restauration causale n'est qu'un snapshot observateur. Si le joueur est
            -- encore present, StartHold pourra re-elire normalement le porteur du timer.
            capturerSourceVerified = false,
            gkRelayCapturerName = self:GetEffectiveCapturerName(st),
            gkRelayCapturerShard = self:GetAssaultShardId(st),
            gkRelaySenderFallback = "",
            pool = normalizeGuildKeepPoolTag(st.pool),
        }
    end
    local captureCandidate = {
        kind = "GC", eventAt = captureTs, guild = guild, faction = faction,
        shard = anchorShard, startedAt = anchorStartedAt,
        generationAt = anchorGenerationAt, player = anchorPlayer,
        baseGuild = baseGuild, baseFaction = baseFaction,
        baseCapturedAt = baseCapturedAt,
    }
    local deferredMarker = type(st._gkDeferredLineage) == "table"
        and st._gkDeferredLineage or nil
    local replaysDeferredCorrection = deferredMarker
        and self:AssaultProofMatches(deferredMarker.correction, captureCandidate) or false
    local repairsAbortedDescendant = repairsPriorBase
        and self:IsCaptureCausalPredecessorOfAbortedAssault(st, captureCandidate)
    local repairsAbortedRetry = self:IsCaptureRepairForActiveRetry(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt)
    if not repairsAbortedDescendant and not repairsAbortedRetry
        and self:IsCaptureCandidateBlockedByAbort(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, captureTs) then return false end
    if st.status == "held" and not repairsPriorBase
        and not self:IsAssaultBaseCompatibleWithHeldState(
        st, baseGuild, baseFaction, baseCapturedAt, anchorStartedAt) then return false end
    if st.status == "in_progress" then
        local exact = self:ActiveAssaultAnchorMatches(
            st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt)
        if not exact and not repairsPriorBase and not repairsAbortedRetry
            and not self:WouldAdoptAssaultAnchor(
            st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
            baseGuild, baseFaction, baseCapturedAt) then return false end
    end
    local exactRecordedFinal = self:FinalAssaultAnchorMatches(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt)
        and math.floor(tonumber(st.finalAssaultCapturedAt) or 0) == captureTs
    -- Exception strictement stateful : le helper vient de prouver que CE GC est le
    -- predecesseur direct du terminal/assaut J2 actuellement affiche. Le comparateur
    -- global doit rester transitif, donc on retire ici seulement ce descendant impossible
    -- avant d'enregistrer le GC. Les snapshots GH bruts conservent, eux, les deux jours et
    -- pourront restaurer J2 si un GA J1 gagnant arrive ensuite.
    if repairsPriorBase and not exactRecordedFinal then
        clearFinalAssaultFields(st)
    end
    if repairsAbortedDescendant then clearAbortedAssaultFields(st) end
    if not exactRecordedFinal and not self:RecordFinalAssaultAnchor(
        st, guild, faction, anchorShard, anchorStartedAt, anchorGenerationAt, anchorPlayer,
        baseGuild, baseFaction, baseCapturedAt, captureTs) then return false end
    terminalAuthorityPlayer = normalizeAssaultShardPlayer(terminalAuthorityPlayer)
    st.finalAssaultAuthorityPlayer = self:ChooseTerminalAuthority(
        anchorPlayer, preservedTerminalAuthority, terminalAuthorityPlayer)
    if repairsPriorBase and ((deferredSuccessor
        and not self:AssaultProofMatches(deferredSuccessor, captureCandidate))
        or deferredActiveSuccessor) then
        -- Conserver le descendant brut avant le rebase. Si le GC reparateur perd ensuite
        -- son propre jour contre un GA/GC concurrent, GH pourra restaurer ce descendant
        -- sans attendre qu'un autre pair soit encore en ligne.
        st._gkDeferredLineage = {
            correction = captureCandidate,
            projectionDay = self:GetServerSiegeDayKey(captureCandidate.eventAt),
            successor = deferredSuccessor,
            activeSuccessor = deferredActiveSuccessor,
            -- Corrections historiques imbriquees : restaurer A doit aussi restaurer le
            -- filet A -> C qui existait avant la correction plus ancienne P -> A.
            prior = deferredMarker,
        }
    elseif not repairsPriorBase and not replaysDeferredCorrection then
        self:RememberDeferredLineageTerminal(
            st, captureCandidate, deferredLineageOwnedBefore)
    end
    -- Le terminal porte la tenure attaquee. `st.ownerGuild` vaut deja l'assaillant pendant
    -- in_progress et produisait donc des chroniques "X a pris le fort a X".
    local prevGuild, prevFaction = baseGuild, baseFaction
    local now = captureTs
    st.status = "held"
    st.ownerGuild = guild
    st.ownerFaction = faction
    self:ClearGkCapturerFields(st)
    self:ResetHeldHoldClock(st, now)
    st.holdTimeElapsed = 0
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    st.previousOwnerGuild = ""
    st.previousOwnerFaction = nil
    st.previousClaimedAt = 0
    st.previousExpiresAt = 0
    st._loginSyncUnconfirmed = nil
    st._gkStaleObserver = nil
    st._observerKeepFinalStatePollCount = nil
    st._observerKeepFinalStatePollAt = nil
    st.pool = currentGuildKeepPoolTag()
    st.updatedAt = now
    self:SaveKeeps()
    self:MarkDirty()
    -- Publier d'abord la capture canonique : RefreshKeepPresentation lit desormais
    -- exclusivement le terminal v8 et ne doit pas repeindre l'ancien tenant pendant un tick.
    if Overlord.Leaderboard and Overlord.Leaderboard.SetGuildKeepTenantLocal then
        Overlord.Leaderboard:SetGuildKeepTenantLocal(
            siteKey, st.ownerGuild, faction, st.claimedAt or now, true)
    end
    if repairsPriorBase and not suppressCaptureAlerts and Overlord.Leaderboard
        and Overlord.Leaderboard.RepairGuildKeepDailyProofsAfterLineageCorrection then
        Overlord.Leaderboard:RepairGuildKeepDailyProofsAfterLineageCorrection(siteKey)
    end
    self:RecordOfficialKeepTenant(
        siteKey, st.ownerGuild, faction, st.claimedAt or now, st.pool, true)
    if not suppressPresentation then self:RefreshKeepPresentation(siteKey, true) end
    if not suppressCaptureAlerts and Overlord.GuildKeepImmersion
        and Overlord.GuildKeepImmersion.OnKeepCaptured then
        Overlord.GuildKeepImmersion:OnKeepCaptured(siteKey, st.ownerGuild, faction, prevGuild, prevFaction, now)
    end
    if not suppressCaptureAlerts and Overlord.Sync and Overlord.Sync.PrintGuildKeepCaptureAlert then
        Overlord.Sync:PrintGuildKeepCaptureAlert(siteKey, st.ownerGuild, faction, now)
    end
    return true
end

-- GH n'a jamais le droit de creer arbitrairement un terrain live. Cette exception ne peut
-- agir que sur le GC de correction que CE client avait lui-meme applique et dont il a garde
-- le descendant exact. Le registre quotidien effectif peut alors annuler la correction et
-- rejouer le descendant devenu valide (A GC J1 -> B GA J1 -> C GC J2).
function Overlord.GuildKeep:ReconcileDeferredLineageAfterDailyProofChange(siteKey, dayKey, depth)
    depth = math.floor(tonumber(depth) or 0)
    if depth >= 8 then return false end
    local st = self:GetState(siteKey)
    local marker = st and st._gkDeferredLineage
    local correction = type(marker) == "table" and marker.correction or nil
    local successor = type(marker) == "table" and marker.successor or nil
    local activeSuccessor = type(marker) == "table" and marker.activeSuccessor or nil
    if not correction or (not successor and not activeSuccessor)
        or not self.AssaultProofMatches then return false end
    local correctionDay = tostring(marker.projectionDay or "")
    if correctionDay == "" then
        correctionDay = self:GetServerSiegeDayKey(correction.eventAt)
    end
    local changedDay = tostring(dayKey or "")
    -- Un changement ancien peut modifier retroactivement la projection du jour de la
    -- correction. Un changement posterieur ne peut pas l'affecter.
    if changedDay == "" or changedDay > correctionDay then return false end
    local current = self:GetCurrentTerminalProof(st)
    local lb = Overlord.Leaderboard
    local effective = lb and lb.GetGuildKeepDailyProofForDay
        and lb:GetGuildKeepDailyProofForDay(siteKey, correctionDay) or nil
    if self:AssaultProofMatches(effective, correction) then return false end
    local function forceCatchup()
        if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
            local recoveryKey = table.concat({
                "lineage", correctionDay, tostring(effective and effective.kind or "none"),
                tostring(effective and effective.eventAt or 0),
                tostring(effective and effective.startedAt or 0),
                tostring(effective and effective.shard or ""),
                tostring(effective and effective.generationAt or 0),
                tostring(effective and effective.guild or ""):lower(),
                tostring(effective and effective.player or ""):lower(),
                tostring(effective and effective.baseCapturedAt or 0),
            }, ":")
            Overlord.Sync:PollIfStaleObserverKeep(
                999, siteKey, true, recoveryKey)
        end
    end
    if not effective then
        forceCatchup()
        return false
    end
    local function applyTerminal(proof)
        if proof.kind == "GC" then
            return self:CompleteCapture(
                siteKey, proof.guild, proof.faction, proof.eventAt,
                proof.shard, proof.startedAt, proof.generationAt, proof.player,
                proof.baseGuild, proof.baseFaction, proof.baseCapturedAt,
                proof.player, true, true)
        end
        if proof.kind == "GA" then
            return self:AbortAssault(
                siteKey, proof.guild, proof.faction, proof.eventAt,
                proof.shard, proof.startedAt, proof.generationAt, proof.player,
                proof.baseGuild, proof.baseFaction, proof.baseCapturedAt,
                proof.player, true)
        end
        return false
    end
    local correctionIsLive = self:AssaultProofMatches(current, correction)
    local effectiveIsLive = self:AssaultProofMatches(current, effective)
    local liveDescendant = marker.liveDescendant
    local liveDescendantIsLive = self:AssaultProofMatches(current, liveDescendant)
    if type(liveDescendant) == "table" and liveDescendant.kind == "GK"
        and st.status == "in_progress" then
        liveDescendantIsLive = self:ActiveAssaultAnchorMatches(
            st, liveDescendant.guild, liveDescendant.faction,
            liveDescendant.shard, liveDescendant.startedAt,
            liveDescendant.generationAt, liveDescendant.player,
            liveDescendant.baseGuild, liveDescendant.baseFaction,
            liveDescendant.baseCapturedAt)
    end
    local successorIsLive = successor and self:AssaultProofMatches(current, successor) or false
    if activeSuccessor and st.status == "in_progress" then
        successorIsLive = self:ActiveAssaultAnchorMatches(
            st, activeSuccessor.ownerGuild, activeSuccessor.ownerFaction,
            activeSuccessor.assaultShardId, activeSuccessor.assaultShardStartedAt,
            activeSuccessor.assaultGenerationAt, activeSuccessor.assaultShardPlayer,
            activeSuccessor.assaultBaseGuild, activeSuccessor.assaultBaseFaction,
            activeSuccessor.assaultBaseCapturedAt)
    end
    if successorIsLive then
        st._gkDeferredLineage = marker.prior
        self:SaveKeeps()
        self:MarkDirty()
        if marker.prior then
            self:ReconcileDeferredLineageAfterDailyProofChange(
                siteKey, marker.prior.projectionDay or changedDay, depth + 1)
        end
        return true
    end
    if not correctionIsLive and not effectiveIsLive and not liveDescendantIsLive then
        forceCatchup()
        return false
    end

    if liveDescendantIsLive and not effectiveIsLive then
        -- La branche live a pu continuer plusieurs jours (GK/GA/GC) depuis la correction.
        -- Revenir silencieusement a sa racine rend les preflights ordinaires de nouveau
        -- applicables, sans donner a GH un pouvoir arbitraire sur un etat independant.
        resetGuildKeepStateToNeutral(st)
        st._gkDeferredLineage = marker
        if not applyTerminal(correction) then
            st._gkDeferredLineage = marker
            forceCatchup()
            return false
        end
        marker.liveDescendant = nil
        st = self:GetState(siteKey)
        st._gkDeferredLineage = marker
        current = self:GetCurrentTerminalProof(st)
        correctionIsLive = self:AssaultProofMatches(current, correction)
        if not correctionIsLive then
            forceCatchup()
            return false
        end
    end

    if correctionIsLive and not applyTerminal(effective) then
        forceCatchup()
        return false
    end
    local afterState = self:GetState(siteKey)
    local afterEffective = self:GetCurrentTerminalProof(afterState)
    local successorBaseGuild = successor and successor.baseGuild
        or activeSuccessor and activeSuccessor.assaultBaseGuild
    local successorBaseFaction = successor and successor.baseFaction
        or activeSuccessor and activeSuccessor.assaultBaseFaction
    local successorBaseCapturedAt = successor and successor.baseCapturedAt
        or activeSuccessor and activeSuccessor.assaultBaseCapturedAt
    local successorStartedAt = successor and successor.startedAt
        or activeSuccessor and activeSuccessor.assaultShardStartedAt
    local successorCompatible = self:IsAssaultBaseCompatibleWithHeldState(
        afterState, successorBaseGuild, successorBaseFaction,
        successorBaseCapturedAt, successorStartedAt)
    local restored
    if not successorCompatible then
        -- Le winner effectif est lui-meme une capture qui a change la tenure : l'ancien
        -- descendant n'est plus causal. Rester sur ce winner est la convergence correcte.
        restored = false
    elseif successor then
        restored = self:AssaultProofMatches(afterEffective, successor)
            or applyTerminal(successor)
    elseif activeSuccessor then
        restored = self:ApplyRemoteState(siteKey, activeSuccessor, true)
    end
    local after = self:GetState(siteKey)
    if after then
        if restored then
            after._gkDeferredLineage = marker.prior
        elseif not successorCompatible then
            -- Le winner D peut encore etre remplace plus tard par un GA B qui rend le
            -- descendant valide. Avancer l'undo vers D conserve cette reversibilite.
            marker.correction = effective
            marker.projectionDay = correctionDay
            marker.liveDescendant = nil
            after._gkDeferredLineage = marker
        else
            after._gkDeferredLineage = marker
        end
    end
    -- Derouler toute correction imbriquee avant d'exposer l'etat. Sinon l'UI pouvait
    -- afficher le successeur intermediaire avant le resultat final.
    if restored and marker.prior then
        self:ReconcileDeferredLineageAfterDailyProofChange(
            siteKey, marker.prior.projectionDay or changedDay, depth + 1)
    end
    self:SaveKeeps()
    self:MarkDirty()
    -- GH est deja le transport causal et ses handlers relaient groupe/canal. Ne pas lancer
    -- ici un fan-out communautaire par receveur : 40 markers donnaient 40 vagues identiques.
    self:RefreshKeepPresentation(siteKey, true)
    if successorCompatible and not restored then forceCatchup() end
    return true
end

-- Observateur : poll SR si etat stale, sans jamais ecrire status/owner en SavedVariables.
local KEEP_OBSERVER_STALE_BUFFER = 60

-- Un in_progress restaure reste volontairement observateur pendant sa propre fenetre : seul
-- un terminal reseau peut alors le trancher. A l'ouverture d'une NOUVELLE journee de siege,
-- cette ancienne ancre ne doit toutefois pas bloquer le keep pour toujours si tous ses temoins
-- sont hors ligne. On revient uniquement a la tenure de depart attestee, ou a neutral ; aucune
-- capture/victoire/GA n'est creee par ce nettoyage local.
function Overlord.GuildKeep:DiscardStaleObserverFromPreviousSiege(siteKey, st)
    -- Le flag est pose au /reload, mais un client reste connecte peut lui aussi manquer le
    -- terminal de 22 h. L'identite de jour est la preuve suffisante : des qu'une nouvelle
    -- fenetre est ouverte, un ancien observateur sans autorite ne doit plus bloquer le keep.
    if not st or st.status ~= "in_progress"
        or st.holdAuthorityLocal or st.isHolding or not self:IsSiegeWindowOpen() then return false end
    local anchorAt = self:GetAssaultShardStartedAt(st)
    if anchorAt <= 0 then anchorAt = math.floor(tonumber(st.updatedAt) or 0) end
    if anchorAt > 0 and self:GetServerSiegeDayKey(anchorAt) == self:GetServerSiegeDayKey() then
        return false
    end

    local baseGuild, baseFaction, baseCapturedAt, baseValid = normalizeAssaultBase(
        st.assaultBaseGuild, st.assaultBaseFaction, st.assaultBaseCapturedAt)
    if not baseValid then baseGuild, baseFaction, baseCapturedAt = "", nil, 0 end
    self:ClearGkCapturerFields(st)
    st.isHolding = false
    st.isPaused = false
    st.isContested = false
    st.holdAuthorityLocal = false
    st.holdStartTime = nil
    st.holdTimeElapsed = 0
    st.previousOwnerGuild = ""
    st.previousOwnerFaction = nil
    st.previousClaimedAt = 0
    st.previousExpiresAt = 0
    st._gkStaleObserver = nil
    st._observerKeepFinalStatePollCount = nil
    st._observerKeepFinalStatePollAt = nil
    st.updatedAt = 0
    if baseGuild ~= "" then
        st.status = "held"
        st.ownerGuild = baseGuild
        st.ownerFaction = baseFaction
        st.claimedAt = baseCapturedAt
        st.expiresAt = 0
        st.pool = currentGuildKeepPoolTag()
        self:RecordOfficialKeepTenant(
            siteKey, baseGuild, baseFaction, baseCapturedAt, st.pool, true)
    else
        resetGuildKeepStateToNeutral(st)
    end
    -- Laisser une courte fenetre au SR pour restituer GH puis GK avant qu'un nouveau
    -- contact local ne devienne par erreur la premiere ancre de la journee.
    st._gkLineageCatchupUntil = GetUtcEpoch() + 8
    if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
        Overlord.Sync:PollIfStaleObserverKeep(999, siteKey, true)
    end
    return true
end

function Overlord.GuildKeep:TickMaintenance()
    local now = GetUtcEpoch()
    local anyChanged = false
    for key in pairs(Overlord.GuildKeepSites) do
        local st = self:GetState(key)
        if self:ExpirePostCutoffAssault(key, st) then
            anyChanged = true
        elseif self:DiscardStaleObserverFromPreviousSiege(key, st) then
            anyChanged = true
        elseif st.status == "held" and (tonumber(st.expiresAt) or 0) ~= 0 then
            st.expiresAt = 0
            anyChanged = true
        elseif st.status == "in_progress" and not st.holdAuthorityLocal and not st.isHolding then
            local site = self:GetSite(key)
            local req = self:GetDefaultHoldTimeRequired(st, site)
            local stored = tonumber(st.holdTimeElapsed) or 0
            local observed = self.GetObserverHoldTimeElapsed
                and self:GetObserverHoldTimeElapsed(st, site) or stored
            local atThreshold = math.max(stored, tonumber(observed) or 0) >= req - 1
            if Overlord.Sync and Overlord.Sync.RequestObserverKeepCaptureConfirmationIfComplete then
                Overlord.Sync:RequestObserverKeepCaptureConfirmationIfComplete(key, st, site)
            end
            -- Un co-assaillant ayant cede l'autorite est lui aussi un observateur reseau.
            -- L'exclure parce que sa guilde porte l'assaut le laissait sans rattrapage si le
            -- GK/GC final du porteur elu etait perdu : son ancien timer restait in_progress,
            -- puis repartait en recap. Le poll est deja borne a 22/45 s dans SyncGuildKeep.
            local age = now - (tonumber(st.updatedAt) or 0)
            if not atThreshold then
                if age > req + KEEP_OBSERVER_STALE_BUFFER then
                    if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
                        Overlord.Sync:PollIfStaleObserverKeep(age, key)
                    end
                else
                    PollIfKeepStateNeedsCatchup(st, key)
                    -- Observateur d'un siege ACTIF (ts>0, pas juste "jamais recu de GK") qui
                    -- decroche du rythme du relais communaute (cross-royaume, rotation partagee
                    -- avec tout le monde en ligne, cf. retours joueurs Mulgore 2 obs. figes
                    -- ~1-2 min). PollIfStaleObserverKeep a son propre throttle interne : cet
                    -- appel reste gratuit tant que l'etat n'est pas reellement stale.
                    if Overlord.Sync and Overlord.Sync.PollIfStaleObserverKeep then
                        Overlord.Sync:PollIfStaleObserverKeep(age, key)
                    end
                end
            end
        elseif st.status == "held" and self:IsKeepStateAwaitingNetworkSnapshot(st) then
            PollIfKeepStateNeedsCatchup(st, key)
        end
    end
    if anyChanged then
        self:MarkDirty()
        self:SaveKeeps()
        -- Les trois consommateurs rafraichissent deja l'ensemble des keeps ; un seul appel
        -- suffit meme si plusieurs sites ont bascule au cutoff dans le meme tick.
        self:RefreshKeepPresentation(nil, true)
    end
end

function Overlord.GuildKeep:GetObserverHoldTimeElapsed(st, site, inGeometryOverride)
    if not st or not site or st.status ~= "in_progress" then
        return tonumber(st and st.holdTimeElapsed) or 0
    end
    -- Capteur local CAPTURING / LOSING : comme zone.isHolding / isPaused (pas d'interpolation)
    if st.holdAuthorityLocal and (st.isHolding or st.isPaused) then
        return tonumber(st.holdTimeElapsed) or 0
    end
    -- Defense physique sur la shard Anchor : ne jamais extrapoler le chrono assaillant
    -- pendant une parite/majorite locale, ni apres la mort ou le depart du dernier ennemi.
    -- ShouldApplyRemoteKeepHold bloque deja les nouveaux ticks ; cette garde couvre aussi
    -- les secondes situees entre deux GK, qui continuaient auparavant jusqu'a 45 s.
    local assaultFac = select(2, self:GetCanonicalAssaultGuild(st))
    if assaultFac ~= "Alliance" and assaultFac ~= "Horde" then
        assaultFac = st.ownerFaction
    end
    if assaultFac and Overlord.PlayerFaction and assaultFac ~= Overlord.PlayerFaction
        and self:IsLocalDefenseBlockingRemoteKeepCapture(
            site.siteKey or site.id, st, assaultFac) then
        return tonumber(st.holdTimeElapsed) or 0
    end
    -- Un membre de la guilde assaillante sans autorite locale est un observateur comme
    -- les autres. Le figer sur holdTimeElapsed faisait sauter son HUD uniquement aux GK
    -- recus et pouvait donner l'impression que la capture entiere etait bloquee.
    -- La geometrie et l'etat de monture du RECEPTEUR ne disent rien sur le porteur
    -- distant du timer. Un observateur parti a Crossroads doit donc conserver la meme
    -- interpolation d'affichage qu'un observateur reste a Redridge. Le parametre
    -- inGeometryOverride reste accepte pour les appels HUD historiques, mais il ne peut
    -- plus figer un siege distant.
    local ts = tonumber(st.updatedAt) or 0
    if ts <= 0 then
        local mem = self._obsHoldDisplayMem
        local siteKey = site and (site.siteKey or site.id) or "keep"
        local m = mem and mem[siteKey]
        if m and (m.hold or 0) > 0 then
            return m.hold
        end
        return tonumber(st.holdTimeElapsed) or 0
    end
    local age = GetUtcEpoch() - ts
    -- Extrapolation AFFICHAGE SEUL entre deux GK : sans elle, le timer observateur fige puis
    -- saute a chaque GK recu (0:00 -> 0:10 etc.). GK ne transporte pas CAPTURING vs LOSING,
    -- donc on n'extrapole que si les deux derniers GK montraient une progression et que le
    -- dernier etat n'est pas CONTESTE. Aucun champ d'etat n'est modifie ni envoye.
    local hold = tonumber(st.holdTimeElapsed) or 0
    local mem = self._obsHoldDisplayMem
    if not mem then
        mem = {}
        self._obsHoldDisplayMem = mem
    end
    local siteKey = site and (site.siteKey or site.id) or "keep"
    local m = mem[siteKey]
    if not m then
        m = { ts = 0, hold = 0, rising = false }
        mem[siteKey] = m
    end
    if ts ~= m.ts then
        m.rising = (m.ts > 0) and (ts > m.ts) and (hold > m.hold)
        m.ts = ts
        m.hold = hold
    end
    if st.isContested or not m.rising then
        return hold
    end
    local OBS_HOLD_EXTRAP_MAX = 45
    local extra = math.min(age, OBS_HOLD_EXTRAP_MAX)
    if extra <= 0 then return hold end
    local req = self:GetDefaultHoldTimeRequired(st, site)
    -- Jamais atteindre req par extrapolation : la fin de capture vient du GC / GK reel.
    return math.min(hold + extra, math.max(req - 1, hold))
end

function Overlord.GuildKeep:GetDisplayName(site)
    if site and site.displayNameKey and L and L[site.displayNameKey] then
        return L[site.displayNameKey]
    end
    return (L and L.GUILD_KEEP_SHORT) or (site and site.id) or "Guild Keep"
end

-- Popup shard helper cross-shard keep : notifie la guilde capturante qu'un evenement
-- (conteste ou capture deja effectuee) s'est produit sur une autre shard. Reutilise le
-- popup d'invite shard (OpenShardMismatchPopup) pour permettre de hop sur la shard via
-- les joueurs connus present la-bas. Dedup pour ne pas spammer (un par keep/type/fenetre).
local CROSS_SHARD_POPUP_DEDUP_SEC = 60
local CROSS_SHARD_POPUP_DEDUP_MAX = 32

local function EnsureCrossShardKeepPopupCombatDefer(gk)
    if gk._crossShardKeepCombatDeferFrame then return end
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        local pending = gk._pendingCrossShardKeepPopup
        if not pending or InCombatLockdown() then return end
        gk._pendingCrossShardKeepPopup = nil
        gk:ShowCrossShardKeepPopup(pending)
    end)
    gk._crossShardKeepCombatDeferFrame = f
end

function Overlord.GuildKeep:ShowCrossShardKeepPopup(payload)
    if not payload or not (Overlord.UI and Overlord.UI.OpenShardMismatchPopup) then return end
    Overlord.UI:OpenShardMismatchPopup(nil, {
        zoneEntry = true,
        nonBlocking = true,
        zoneName = payload.keepName,
        title = payload.title,
        subText = payload.subText,
        rows = payload.rows,
        requestInvite = true,
        targetShard = payload.targetShard,
    })
end

function Overlord.GuildKeep:FireCrossShardKeepPopup(info)
    if not info or not info.siteKey then return end
    if not (Overlord.UI and Overlord.UI.OpenShardMismatchPopup) then return end
    if not (Overlord.IsShardHelperActive and Overlord:IsShardHelperActive()) then return end
    local kind = info.kind or "already_captured"
    local siteKey = info.siteKey
    local mem = self._crossShardPopupMem
    if not mem then mem = {}; self._crossShardPopupMem = mem end
    local dedupKey = siteKey .. ":" .. kind .. ":" .. tostring(info.guild or "")
    local now = GetTime()
    local last = tonumber(mem[dedupKey]) or 0
    if last > 0 and (now - last) < CROSS_SHARD_POPUP_DEDUP_SEC then return end
    local isNewDedupKey = mem[dedupKey] == nil
    if isNewDedupKey
        and (tonumber(self._crossShardPopupMemCount) or 0) >= CROSS_SHARD_POPUP_DEDUP_MAX then
        if now < (tonumber(self._crossShardPopupMemBlockedUntil) or 0) then return end
        local count, earliestExpiry = 0, math.huge
        for key, seenAt in pairs(mem) do
            seenAt = tonumber(seenAt) or 0
            if now - seenAt > CROSS_SHARD_POPUP_DEDUP_SEC * 4 then
                mem[key] = nil
            else
                count = count + 1
                earliestExpiry = math.min(
                    earliestExpiry, seenAt + CROSS_SHARD_POPUP_DEDUP_SEC * 4)
            end
        end
        self._crossShardPopupMemCount = count
        if count >= CROSS_SHARD_POPUP_DEDUP_MAX then
            -- Mieux vaut omettre une nouvelle alerte de rafale qu'oublier une cle
            -- vivante puis recreer une avalanche de popups identiques.
            self._crossShardPopupMemBlockedUntil = earliestExpiry + 0.01
            return
        end
        self._crossShardPopupMemBlockedUntil = 0
    end

    local site = self:GetSite(siteKey)
    local keepName = self:GetDisplayName(site)
    local st = self:GetState(siteKey)
    -- Preferer l'ancre d'assaut (stable) au cache SH du sender.
    local anchoredShardId = normalizeAssaultShardId(info.shardId)
        or (st and self:GetAssaultShardId(st) or nil)
    local knownSenderShard = nil
    if info.sender and info.sender ~= "" and Overlord.Shard
        and Overlord.Shard.GetKnownPlayerShard then
        knownSenderShard = Overlord.Shard:GetKnownPlayerShard(info.sender)
    end
    local shardId = anchoredShardId or knownSenderShard
    local currentShardId = Overlord.Shard and Overlord.Shard.GetCaptureLocalShardID
        and Overlord.Shard:GetCaptureLocalShardID("keep:" .. tostring(siteKey), 8) or nil
    if currentShardId and tonumber(shardId) == currentShardId then return end
    local shardLabel = (shardId ~= nil and shardId ~= "") and tostring(shardId) or "?"
    if shardId ~= nil and shardId ~= "" and Overlord.Shard and Overlord.Shard.GetShardReference then
        local _, referenceRealm = Overlord.Shard:GetShardReference(shardId)
        if referenceRealm and referenceRealm ~= "" then
            local referenceFmt = (L and L.SHARD_BADGE_REFERENCE) or "via %s"
            shardLabel = shardLabel .. " (" .. string.format(referenceFmt, referenceRealm) .. ")"
        end
    end

    -- Rows : capteur/sender d'abord (hop utile), sinon peers connus sur la shard ancree.
    local rows = {}
    local capturer = info.sender
    local senderMatchesAnchor = anchoredShardId == nil
        or info.senderIsCapturer == true
        or (tonumber(knownSenderShard) and tonumber(knownSenderShard) == tonumber(anchoredShardId))
    if capturer and capturer ~= "" and Overlord.Shard and Overlord.Shard.PartyInviteTargetIsUsable
        and senderMatchesAnchor
        and Overlord.Shard:PartyInviteTargetIsUsable(capturer)
        and not (Overlord.Shard.IsPlayerAlreadyGrouped and Overlord.Shard:IsPlayerAlreadyGrouped(capturer)) then
        rows[#rows + 1] = { player = capturer, shard = shardId or "?" }
    elseif shardId ~= nil and shardId ~= "" and Overlord.Shard
        and type(Overlord.Shard.knownShards) == "table" then
        local shard = Overlord.Shard
        rows = {
            _overlordShardRowSource = true,
            source = shard.knownShards,
            targetShard = shardId,
            getRevision = function() return tonumber(shard._gkPromptPeerRevision) or 0 end,
        }
    end

    local timeStr = ""
    if info.remoteTs and tonumber(info.remoteTs) then
        timeStr = date("%H:%M", tonumber(info.remoteTs))
    end
    local guildLabel = info.guild or ""
    local title, subText
    if kind == "already_captured" then
        title = (L and L.SHARD_POPUP_KEEP_ALREADY_CAPTURED_TITLE) or "Keep deja capture"
        subText = (L and L.SHARD_POPUP_KEEP_ALREADY_CAPTURED_SUB)
            and string.format(L.SHARD_POPUP_KEEP_ALREADY_CAPTURED_SUB, keepName, guildLabel, timeStr, shardLabel)
            or string.format("%s : capture par %s a %s sur shard %s", keepName, guildLabel, timeStr, shardLabel)
    else
        title = (L and L.SHARD_POPUP_KEEP_CONTEST_TITLE) or "Keep conteste (autre shard)"
        subText = (L and L.SHARD_POPUP_KEEP_CONTEST_SUB)
            and string.format(L.SHARD_POPUP_KEEP_CONTEST_SUB, keepName, guildLabel, shardLabel)
            or string.format("%s : %s conteste sur shard %s", keepName, guildLabel, shardLabel)
    end

    mem[dedupKey] = now
    if isNewDedupKey then
        self._crossShardPopupMemCount = (tonumber(self._crossShardPopupMemCount) or 0) + 1
    end

    local payload = {
        keepName = keepName,
        title = title,
        subText = subText,
        rows = rows,
        targetShard = shardId,
    }

    if InCombatLockdown() then
        self._pendingCrossShardKeepPopup = payload
        EnsureCrossShardKeepPopupCombatDefer(self)
        if Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. subText)
        end
        return
    end

    self:ShowCrossShardKeepPopup(payload)
end

function Overlord.GuildKeep:GetShortDisplayName(site)
    if site and site.displayNameKey and L and L[site.displayNameKey] then
        return L[site.displayNameKey]
    end
    return (L and L.GUILD_KEEP_SHORT) or "Keep"
end

function Overlord.GuildKeep:SanitizeGuildName(name)
    return sanitizeGuildName(name)
end
