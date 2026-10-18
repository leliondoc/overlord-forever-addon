-- Nemesis.lua : les cinq meilleurs ennemis de la semaine, les Némésis (ex Most Wanted) (Overlord Forever).
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
-- 2.0.4: our killing blow on one of the five Nemesis pays 10 platinum, shown like a mine's
-- gain (Ressources:AddGold). Local only and capped, as all platinum. Once per player per
-- half hour within a session (a /reload clears it; the 100 cap bounds any farming).
MW.BOUNTY = 10
MW.BOUNTY_PER_PLAYER_SEC = 1800
MW.bountyAt = MW.bountyAt or {}

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
        self._shortWalkList = nil
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
    -- Fewer than five enemies in this very view last time: the walk went to the end
    -- and would again (a ladder change builds a new view). Keep the list.
    if cache.sortedKills == self._shortWalkList and enemy == self._shortWalkEnemy then return end
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
    if #list < self.SIZE then
        self._shortWalkList, self._shortWalkEnemy = cache.sortedKills, enemy
    else
        self._shortWalkList = nil
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
    self.list, self.byKey, self.alertedAt, self.bountyAt = {}, {}, {}, {}
    self._refreshedAt, self._ensureAt, self._lastAlertAt = nil, nil, nil
    self._shortWalkList = nil
    if self.HideAllSkulls then self:HideAllSkulls() end
end

-- Lecture seule pour le classement (aucun recalcul pendant le dessin des lignes).
function MW:IsWanted(name)
    if not next(self.byKey) then return nil end
    local key = KeyOf(name)
    return key and self.byKey[key] or nil
end

-- Our killing blow (Combat:ProcessKill): the bounty if the victim wears the skull.
-- Returns the platinum really gained (0 at the 100 cap, which also shows nothing; a kill
-- at the cap does not use up that player's half hour).
function MW:PayBounty(victimName)
    if not next(self.byKey) or InInstance() then return 0 end
    local entry = self:IsWanted(victimName)
    if not entry then return 0 end
    local now = GetTime()
    local last = self.bountyAt[entry.key]
    if last and now - last < self.BOUNTY_PER_PLAYER_SEC then return 0 end
    local res = Overlord.Ressources
    if not res or not res.AddGold then return 0 end
    local gained = tonumber(res:AddGold(self.BOUNTY)) or 0
    if gained > 0 then self.bountyAt[entry.key] = now end
    return gained
end

local function ShortName(name)
    return type(name) == "string" and (name:match("^(.-)%-") or name) or "?"
end

-- Crane sur la barre de nom Blizzard, a gauche de la barre de vie. Un cadre a nous par
-- unite de nameplate (40 au plus), reutilise ; jamais en instance. 2.0.2 : le crane revient
-- a la place de la couronne (11 octobre), qu'on confondait avec les insignes de rang.
MW.SKULL_SIZE = 16
MW.skulls = MW.skulls or {}
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
-- Meme image dans une ligne de texte (chat, classement, tutoriel) : taille en parametre.
local skullMarkup = {}
function MW.SkullMarkup(size)
    local markup = skullMarkup[size]
    if not markup then
        markup = "|T" .. SKULL_TEXTURE .. ":" .. size .. ":" .. size .. "|t"
        skullMarkup[size] = markup
    end
    return markup
end

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
    local text = string.format(T("MW_ALERT", "Nemesis nearby: %s (#%d %s, %d HK this week)!"),
        ShortName(entry.name), entry.rank, factionName, entry.kills)
    if Overlord.PrintNotification then
        Overlord:PrintNotification("|cFFFF4444[Overlord]|r " .. MW.SkullMarkup(14) .. " " .. text)
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
        elseif event == "PLAYER_ENTERING_WORLD" then
            EnsureTicker()
            if not InInstance() and C_Timer and C_Timer.After then
                C_Timer.After(10, function() pcall(MW.Refresh, MW, true) end)
            end
        end
    end)
end
