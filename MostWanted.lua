-- MostWanted.lua : les cinq meilleurs ennemis de la semaine (Overlord Forever).
-- Calcule localement depuis le cache deja trie du classement : aucun paquet, aucun
-- tri en plus. Un crane sur leur barre de nom et une alerte dans le chat quand l'un
-- d'eux apparait, avec des delais pour ne jamais inonder. Coupe en instance.
Overlord = Overlord or {}
local MW = Overlord.MostWanted or {}
Overlord.MostWanted = MW

MW.SIZE = 5
MW.REFRESH_SEC = 60
MW.ALERT_PER_PLAYER_SEC = 600
MW.ALERT_GLOBAL_GAP = 20
MW.ALERT_MEMORY_MAX = 64
MW.list = MW.list or {}
MW.byKey = MW.byKey or {}
MW.alertedAt = MW.alertedAt or {}

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function KeyOf(name)
    if type(name) ~= "string" or name == "" then return nil end
    local sync = Overlord.Sync
    local canon = sync and sync.CanonicalForeverName and sync:CanonicalForeverName(name) or name
    return type(canon) == "string" and canon ~= "" and canon:lower() or nil
end

local function EnemyFaction()
    local mine = Overlord.PlayerFaction
    if mine == "Alliance" then return "Horde" end
    if mine == "Horde" then return "Alliance" end
    return nil
end

local function InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

function MW:AlertsEnabled()
    local cfg = OverlordDB and OverlordDB.config
    return not (cfg and cfg.mostWantedAlerts == false)
end

function MW:SetAlertsEnabled(enabled)
    if not OverlordDB then return end
    OverlordDB.config = OverlordDB.config or {}
    OverlordDB.config.mostWantedAlerts = enabled and true or false
end

-- Les cinq premiers ennemis du cache d'affichage (deja trie par kills). Le cache est
-- construit par tranches par le classement lui-meme ; ici une simple lecture.
function MW:Refresh(force)
    if InInstance() then return end
    local now = GetTime()
    if not force and self._refreshedAt and now - self._refreshedAt < self.REFRESH_SEC then return end
    self._refreshedAt = now
    local lb = Overlord.Leaderboard
    local enemy = EnemyFaction()
    if not lb or not enemy then return end
    -- Le dernier cache construit par le classement ou le dock (jamais de reconstruction
    -- ici) ; sans aucun cache, le demander au plus une fois par 10 min.
    local cache = lb._displayCache
    -- Un cache d'une autre campagne (reset hebdo) ou d'un autre ruleset ne compte pas :
    -- jamais les joueurs de la semaine passee. On vide la liste et on redemande la vue.
    local current = type(cache) == "table" and type(cache.sortedKills) == "table"
        and cache.killSource == lb.kills
        and (not lb.IsDisplayCacheScopeCurrent or lb:IsDisplayCacheScopeCurrent(cache))
    if not current then
        self.list, self.byKey = {}, {}
        self:HideAllSkulls()
        local stale = type(cache) == "table" and type(cache.sortedKills) == "table"
            and #cache.sortedKills > 0
        local gap = stale and 60 or 600
        if lb.EnsureDisplayCache and now - (self._ensureAt or -1e9) >= gap then
            self._ensureAt = now
            pcall(lb.EnsureDisplayCache, lb)
        end
        return
    end
    local meta = type(cache.meta) == "table" and cache.meta or {}
    local list, byKey, rank = {}, {}, 0
    for i = 1, #cache.sortedKills do
        local row = cache.sortedKills[i]
        local info = row and meta[row.name]
        if info and info[2] == enemy and (tonumber(row.kills) or 0) > 0 then
            rank = rank + 1
            local key = KeyOf(row.name)
            if key then
                local entry = { name = row.name, key = key, kills = tonumber(row.kills) or 0, rank = rank }
                list[#list + 1] = entry
                byKey[key] = entry
            end
            if #list >= self.SIZE then break end
        end
    end
    -- Barres de nom deja visibles repeintes seulement si les cinq noms ont change.
    local changed = #list ~= #self.list
    for i = 1, #list do
        if not changed and list[i].key ~= self.list[i].key then changed = true end
    end
    self.list, self.byKey = list, byKey
    if changed and self.RefreshPlates then self:RefreshPlates() end
end

-- Reset hebdo (Overlord:ResetAll) : la liste de la semaine passee disparait tout de
-- suite ; la prochaine lecture repart du cache de la nouvelle campagne.
function MW:ResetForCampaign()
    self.list, self.byKey, self.alertedAt = {}, {}, {}
    self._refreshedAt, self._ensureAt, self._lastAlertAt = nil, nil, nil
    if self.HideAllSkulls then self:HideAllSkulls() end
end

-- Lecture seule pour le classement (aucun recalcul pendant le dessin des lignes).
function MW:IsWanted(name)
    if not next(self.byKey) then return nil end
    local key = KeyOf(name)
    return key and self.byKey[key] or nil
end

local function ShortName(name)
    return type(name) == "string" and (name:match("^(.-)%-") or name) or "?"
end

-- Crane sur la barre de nom Blizzard, a gauche de la barre de vie. Un cadre a nous par
-- unite de nameplate (40 au plus), reutilise ; jamais en instance.
MW.SKULL_SIZE = 16
MW.skulls = MW.skulls or {}
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"

function MW:HideSkull(unit)
    local skull = unit and self.skulls[unit]
    if skull then skull:Hide() end
end

function MW:HideAllSkulls()
    for _, skull in pairs(self.skulls) do skull:Hide() end
end

function MW:ShowSkull(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    local parent = plate and (plate.UnitFrame or plate)
    if not parent or not CreateFrame then return end
    local anchor = parent.healthBar or parent
    local skull = self.skulls[unit]
    if not skull then
        skull = CreateFrame("Frame", nil, parent)
        skull:SetSize(self.SKULL_SIZE, self.SKULL_SIZE)
        skull.icon = skull:CreateTexture(nil, "OVERLAY")
        skull.icon:SetAllPoints()
        skull.icon:SetTexture(SKULL_TEXTURE)
        self.skulls[unit] = skull
    end
    if skull:GetParent() ~= parent or skull._anchor ~= anchor then
        skull:SetParent(parent)
        skull:ClearAllPoints()
        skull:SetPoint("RIGHT", anchor, "LEFT", -3, 0)
        skull._anchor = anchor
    end
    skull:Show()
end

-- Le Most Wanted affiche sur cette barre de nom, ou nil.
local function WantedEntryForUnit(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local enemy = EnemyFaction()
    if not enemy or UnitFactionGroup(unit) ~= enemy then return nil end
    local name = Overlord.SafeGetUnitName and Overlord:SafeGetUnitName(unit, true)
    local key = KeyOf(name)
    return key and MW.byKey[key] or nil
end

-- Liste changee (toutes les 60 s au plus) : repeindre les barres de nom deja visibles.
function MW:RefreshPlates()
    self:HideAllSkulls()
    if InInstance() or not self:AlertsEnabled() or not next(self.byKey) then return end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if unit and WantedEntryForUnit(unit) then self:ShowSkull(unit) end
    end
end

function MW:OnNameplateAdded(unit)
    self:HideSkull(unit)
    if InInstance() or not self:AlertsEnabled() or not next(self.byKey) then return end
    local entry = WantedEntryForUnit(unit)
    if not entry then return end
    self:ShowSkull(unit)
    local key = entry.key
    local now = GetTime()
    if now - (self._lastAlertAt or -1e9) < self.ALERT_GLOBAL_GAP then return end
    if now - (self.alertedAt[key] or -1e9) < self.ALERT_PER_PLAYER_SEC then return end
    self._lastAlertAt = now
    local count = 0
    for k, at in pairs(self.alertedAt) do
        if now - at >= self.ALERT_PER_PLAYER_SEC then self.alertedAt[k] = nil else count = count + 1 end
    end
    if count >= self.ALERT_MEMORY_MAX then return end
    self.alertedAt[key] = now
    local factionName = Overlord.Zones and Overlord.Zones.GetEnemyFactionName
        and Overlord.Zones:GetEnemyFactionName() or EnemyFaction() or "?"
    local text = string.format(T("MW_ALERT", "Most Wanted nearby: %s (#%d %s, %d kills this week)!"),
        ShortName(entry.name), entry.rank, factionName, entry.kills)
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFF4040[Overlord]|r |T" .. SKULL_TEXTURE .. ":14|t " .. text)
    end
end

-- Instance : plus aucun evenement lu (voir Overlord:SuspendForInstance).
function MW:OnInstanceSuspend()
    if self.frame then
        self.frame:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
        self.frame:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
    end
    self:HideAllSkulls()
end

local function EnsureTicker()
    if MW.ticker or not C_Timer or not C_Timer.NewTicker then return end
    MW.ticker = C_Timer.NewTicker(MW.REFRESH_SEC, function() pcall(MW.Refresh, MW, true) end)
end
MW.EnsureTicker = EnsureTicker

function MW:OnInstanceResume()
    if self.frame then
        self.frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self.frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    end
    EnsureTicker()
    self:Refresh(true)
end

-- /ov wanted test : apercu sur la cible (un loup suffit), 20 s, purement local.
MW.TEST_SEC = 20
function MW:RunTest()
    local plate = not InInstance() and UnitExists and UnitExists("target")
        and C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("target")
    if not plate then
        if Overlord.PrintNotification then
            Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. T("MW_TEST_NO_TARGET",
                "Target a unit with a visible nameplate (a wolf will do), then type /ov wanted test."))
        end
        return false
    end
    self:ShowSkull("target")
    local skull = self.skulls["target"]
    self._testToken = (self._testToken or 0) + 1
    local token = self._testToken
    if skull and C_Timer and C_Timer.After then
        C_Timer.After(self.TEST_SEC, function()
            if MW._testToken == token then skull:Hide() end
        end)
    end
    local name = Overlord.SafeGetUnitName and Overlord:SafeGetUnitName("target", true) or "?"
    local factionName = Overlord.Zones and Overlord.Zones.GetEnemyFactionName
        and Overlord.Zones:GetEnemyFactionName() or EnemyFaction() or "?"
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFF4040[Overlord]|r |T" .. SKULL_TEXTURE .. ":14|t " .. string.format(
            T("MW_ALERT", "Most Wanted nearby: %s (#%d %s, %d kills this week)!"),
            ShortName(name), 1, factionName, 999))
    end
    return true
end

function MW:HandleCommand(args)
    local word = args and args[2] and args[2]:lower() or ""
    if word == "test" then return self:RunTest() end
    if word == "on" then self:SetAlertsEnabled(true)
    elseif word == "off" then self:SetAlertsEnabled(false) end
    self:RefreshPlates()
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFFD100[Overlord]|r " .. (self:AlertsEnabled()
            and T("MW_STATE_ON", "Most Wanted alerts: on") or T("MW_STATE_OFF", "Most Wanted alerts: off")))
    end
end

if CreateFrame then
    local frame = CreateFrame("Frame")
    MW.frame = frame
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    frame:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            -- Le plus courant et le moins cher d'abord ; jamais d'unite lue en instance.
            -- Une barre recyclee ne garde jamais le crane de l'unite precedente.
            if unit and MW.skulls[unit] then MW.skulls[unit]:Hide() end
            if not next(MW.byKey) or not MW:AlertsEnabled() or InInstance() then return end
            pcall(MW.OnNameplateAdded, MW, unit)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            if unit and MW.skulls[unit] then MW.skulls[unit]:Hide() end
            -- Apercu /ov wanted test : il part avec la barre de nom de la cible.
            local preview = MW.skulls["target"]
            if unit and preview and preview:IsShown() and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
                local plate = C_NamePlate.GetNamePlateForUnit(unit)
                if plate and preview:GetParent() == (plate.UnitFrame or plate) then preview:Hide() end
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            EnsureTicker()
            if not InInstance() and C_Timer and C_Timer.After then
                C_Timer.After(10, function() pcall(MW.Refresh, MW, true) end)
            end
        end
    end)
end
