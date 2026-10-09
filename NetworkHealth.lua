-- NetworkHealth.lua : etat du reseau Overlord, partage par /ov network et par le
-- voyant du panneau principal. Lecture seule de compteurs deja tenus localement :
-- aucun paquet, aucun scan, rien en instance.
Overlord = Overlord or {}
local NH = Overlord.NetworkHealth or {}
Overlord.NetworkHealth = NH

local LEVEL_RANK = { ok = 1, warn = 2, bad = 3 }
NH.REFRESH_SEC = 5

local function T(key, fallback)
    local L = Overlord.L
    return (L and L[key]) or fallback
end

local function Worst(a, b)
    return LEVEL_RANK[b] > LEVEL_RANK[a] and b or a
end
NH.Worst = Worst

-- Refus Blizzard et pertes du relais jugés sur les 10 dernières minutes, pas depuis
-- le login : une rafale (entrée dans un groupe, victoire) ne laisse plus la pastille
-- jaune toute la session. Un relevé des compteurs au plus par minute, pris quand un
-- message part (Sync:SendAddonChecked) : aucun minuteur, rien en instance.
local SAMPLE_SEC, WINDOW_SEC, WINDOW_LABEL = 60, 600, " · last 10 min"
local SEND_TYPES = { "CHANNEL", "RAID", "PARTY", "WHISPER" }
local samples = {}
local lastSampleAt

-- Copies d'autres joueurs que le relais refuse de faire suivre, volontairement :
-- destinataire sans route (parti, route de plus de 5 min ou boucle) ou budget du
-- relais. Aucune donnee du joueur n'est perdue : l'expediteur repasse par un autre
-- voisin. Comptees dans "dropped", elles ne colorent pas le voyant.
local function NotForwarded(stats)
    if not stats then return 0 end
    return (tonumber(stats.forwardNoTask) or 0) + (tonumber(stats.relayRejected) or 0)
end

local function CurrentTotals()
    local sync, net = Overlord.Sync, Overlord.Relay
    local totals = {}
    local sendStats = sync and sync._addonSendStats
    for _, chatType in ipairs(SEND_TYPES) do
        local row = sendStats and sendStats[chatType]
        totals[chatType] = row and { ok = row.ok, refused = row.refused } or { ok = 0, refused = 0 }
    end
    local relay = net and net.stats
    totals.sent = relay and relay.sent or 0
    totals.dropped = relay and relay.dropped or 0
    totals.received = relay and relay.received or 0
    totals.notForwarded = NotForwarded(relay)
    return totals
end

function NH:NoteSend(now)
    if lastSampleAt and now - lastSampleAt < SAMPLE_SEC then return end
    lastSampleAt = now
    samples[#samples + 1] = { at = now, totals = CurrentTotals() }
    -- Garder un seul relevé antérieur au début de la fenêtre : c'est la base.
    while #samples > 1 and samples[2].at <= now - WINDOW_SEC do table.remove(samples, 1) end
end

-- Base de la fenêtre : le relevé le plus ancien encore utile (nil = tout depuis le login).
local function WindowBase()
    return samples[1] and samples[1].totals or nil, samples[1] and samples[1].at or nil
end

function NH:_ResetWindow()
    samples, lastSampleAt = {}, nil
end

-- Lignes de resume : { id, level, title, text }, et le pire niveau, partagees avec
-- /ov network. Refus Blizzard et pertes du relais : 10 dernieres minutes ; un refus
-- isole ou 1 % au plus reste vert.
function NH:Compute()
    local sync, net = Overlord.Sync, Overlord.Relay
    local rows, overall = {}, "ok"
    local function add(id, level, title, text)
        rows[#rows + 1] = { id = id, level = level, title = title, text = text }
        overall = Worst(overall, level)
    end
    local base, baseAt = WindowBase()
    local label = base and WINDOW_LABEL or ""
    local sendStats = sync and sync._addonSendStats
    if sendStats then
        local refused, attempts, parts = 0, 0, {}
        for _, chatType in ipairs(SEND_TYPES) do
            local row = sendStats[chatType]
            if row then
                local b = base and base[chatType]
                local rowRefused = math.max(0, row.refused - (b and b.refused or 0))
                local rowAttempts = math.max(rowRefused, row.ok + row.refused - (b and (b.ok + b.refused) or 0))
                refused, attempts = refused + rowRefused, attempts + rowAttempts
                -- Blizzard's last refusal code, to tell a throttle from a channel not joined yet.
                local code = rowRefused > 0 and row.lastCode ~= nil
                    and (not baseAt or (tonumber(row.lastCodeAt) or 0) >= baseAt)
                    and (" code " .. tostring(row.lastCode)) or ""
                parts[#parts + 1] = string.format("%s %d/%d%s", chatType:lower(), rowRefused,
                    rowAttempts, code)
            end
        end
        -- Un refus isolé ou 1 % au plus : normal (Blizzard ne laisse qu'environ un
        -- message par seconde au groupe, au raid et au canal réunis).
        local ratio = attempts > 0 and refused / attempts or 0
        local level = (refused <= 1 or ratio <= 0.01) and "ok"
            or ((ratio < 0.05 or refused < 3) and "warn" or "bad")
        add("throttle", level, "Blizzard throttle",
            string.format("%d refused (%s)%s", refused, table.concat(parts, ", "), label))
    end
    local relayStats = net and net.stats
    if relayStats then
        local sent = math.max(0, (relayStats.sent or 0) - (base and base.sent or 0))
        local notForwarded = math.max(0, NotForwarded(relayStats) - (base and base.notForwarded or 0))
        -- Pertes du joueur seulement : les copies d'autrui non relayees sont a part.
        local dropped = math.max(0, (relayStats.dropped or 0) - (base and base.dropped or 0) - notForwarded)
        local received = math.max(0, (relayStats.received or 0) - (base and base.received or 0))
        local pct = sent > 0 and dropped * 100 / sent or 0
        local others = notForwarded > 0
            and string.format(", %d copies for others not forwarded", notForwarded) or ""
        add("relay", (dropped <= 1 or pct < 1) and "ok" or ((pct < 5 or sent < 500) and "warn" or "bad"),
            "Relay losses", string.format("%d lost of %d sent (%.1f%%), %d received%s%s",
                dropped, sent, pct, received, others, label))
    end
    if sync and sync.GetPagedLeaderboardSummary then
        local lb = sync:GetPagedLeaderboardSummary()
        local stuck = lb.status:find("interrupted", 1, true) ~= nil
        add("ladder", stuck and "warn" or "ok", "Leaderboard catch-up",
            string.format("%s, %d pages / %d rows (v%d)", lb.status, lb.pages, lb.rows, lb.protocol))
    end
    if sync and sync.GetHistoryCatchupSummary then
        local hr = sync:GetHistoryCatchupSummary()
        local waiting = hr.running and hr.step == "paged ladder catch-up" and hr.stepAge > 600
        local text = hr.running and string.format("%s, %ds ago", tostring(hr.step or "?"), hr.stepAge) or "idle"
        add("history", waiting and "warn" or "ok", "Capture history catch-up",
            waiting and string.format("waiting on one peer for %ds", hr.stepAge) or text)
    end
    if sync and sync.GetOutpostClaimStats then
        local accepted, refused, last = sync:GetOutpostClaimStats()
        add("claims", "ok", "Keep/outpost captures",
            string.format("%d accepted, %d refused%s", accepted, refused,
                last and (" (last: " .. last .. ")") or ""))
    end
    if net and net.GetQueueSummary then
        local q = net:GetQueueSummary()
        add("queue", q.catchup >= q.catchupMax and "warn" or "ok", "Relay queue",
            string.format("%d waiting (catch-up %d/%d, domination %d/%d)", q.total, q.catchup, q.catchupMax,
                q.state, q.stateMax))
    end
    return overall, rows
end

-- Niveau du voyant : seulement ce qui touche le joueur (refus Blizzard, pertes du
-- relais, file saturee). Un tour de rattrapage interrompu est normal (un voisin
-- part en instance) et ne doit pas inquieter : il reste visible dans l'infobulle.
local INDICATOR_IDS = { throttle = true, relay = true, queue = true }
function NH:IndicatorLevel()
    local ok, overall, rows = pcall(self.Compute, self)
    if not ok then return "ok", {} end
    local level = "ok"
    for _, row in ipairs(rows or {}) do
        if INDICATOR_IDS[row.id] then level = Worst(level, row.level) end
    end
    return level, rows or {}, overall
end

local TEXTURE = {
    ok = "Interface\\COMMON\\Indicator-Green",
    warn = "Interface\\COMMON\\Indicator-Yellow",
    bad = "Interface\\COMMON\\Indicator-Red",
}
local WORD_KEY = { ok = "NET_HEALTH_OK", warn = "NET_HEALTH_WARN", bad = "NET_HEALTH_BAD" }
local WORD_FALLBACK = { ok = "All good", warn = "Worth watching", bad = "Problem" }
local COLOR = { ok = { 0.55, 0.82, 0.55 }, warn = { 0.92, 0.76, 0.42 }, bad = { 0.88, 0.48, 0.45 } }

-- Pastille Blizzard desaturee puis teintee : couleurs douces, meme forme.
local function Tint(icon, level)
    icon:SetTexture(TEXTURE[level] or TEXTURE.ok)
    if icon.SetDesaturated then icon:SetDesaturated(true) end
    local c = COLOR[level] or COLOR.ok
    icon:SetVertexColor(c[1], c[2], c[3], 0.9)
end

local function InInstance()
    if Overlord.InstanceSuspended then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end

local function Paint(button)
    if InInstance() then return end
    local level = NH:IndicatorLevel()
    button._level = level
    Tint(button.icon, level)
end

local function ShowTooltip(button)
    if InInstance() or not GameTooltip then return end
    local level, rows = NH:IndicatorLevel()
    GameTooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(T("NET_HEALTH_TITLE", "Overlord network"), 1, 0.82, 0)
    local c = COLOR[level] or COLOR.ok
    GameTooltip:AddLine(T(WORD_KEY[level], WORD_FALLBACK[level]), c[1], c[2], c[3])
    for _, row in ipairs(rows) do
        local rc = COLOR[row.level] or COLOR.ok
        GameTooltip:AddDoubleLine(row.title, row.text, rc[1], rc[2], rc[3], 0.8, 0.8, 0.8)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(T("NET_HEALTH_HINT", "Type /ov network for details."), 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- Voyant du panneau principal : un point colore, repeint toutes les 5 s seulement
-- quand le panneau est visible (aucun minuteur sinon).
function NH:AttachIndicator(parent, anchor)
    if not parent or self.indicator or not CreateFrame then return self.indicator end
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(12, 12)
    if anchor then
        button:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    else
        button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -40, -36)
    end
    local icon = button:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    Tint(icon, "ok")
    button.icon = icon
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    local function stopTicker()
        if button.ticker then button.ticker:Cancel(); button.ticker = nil end
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
    end
    local function startTicker()
        stopTicker()
        Paint(button)
        if C_Timer and C_Timer.NewTicker then
            button.ticker = C_Timer.NewTicker(NH.REFRESH_SEC, function()
                if not parent:IsShown() then stopTicker(); return end
                Paint(button)
            end)
        end
    end
    if parent.HookScript then
        parent:HookScript("OnShow", startTicker)
        parent:HookScript("OnHide", stopTicker)
    end
    if parent.IsShown and parent:IsShown() then startTicker() end
    self.indicator = button
    return button
end
