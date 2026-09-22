-- ManualBountyMail.lua - COD securise avec paiement direct en solution de secours
Overlord = Overlord or {}
Overlord.ManualBountyMail = {}

local L = Overlord.L
local MODE_DIRECT = "direct"
local MODE_COD = "cod"
local pendingContractId = nil
local pendingMode = nil
local activeContractId = nil
local activeMode = nil
local activeReady = false
local fieldsPrepared = false
local infoNotified = false
local errorNotified = false
local refreshScheduled = false
local applyingMailFields = false
local inboxStatusFrame = nil
local lastInboxStatusKey = ""
local COD_SEND_LEDGER_RETENTION_SEC = 45 * 24 * 3600
local COD_SEND_LEDGER_MAX_INACTIVE = 1024
local COD_SEND_LEDGER_PRUNE_INTERVAL_SEC = 3600
local codSendLedgerMigratedRoot = nil
local codSendLedgerLastPrunedAt = setmetatable({}, { __mode = "k" })
local codSendLedgerPrep = {
    generation = 0,
    pending = false,
    valid = false,
    failures = 0,
}

local function GetLocalFullName()
    local sync = Overlord.Sync
    if sync and sync.GetPlayerFullName then return sync:GetPlayerFullName() end
    return Overlord:SafeUnitName("player", true)
end

local function NameKey(name)
    local sync = Overlord.Sync
    if sync and sync.GetCaptureContributorDedupKey then
        return sync:GetCaptureContributorDedupKey(name)
    end
    return type(name) == "string" and name:lower() or nil
end

local function NamesMatch(a, b)
    if not a or not b or a == "" or b == "" then return false end
    if a:lower() == b:lower() then return true end
    local ak = NameKey(a)
    local bk = NameKey(b)
    return ak ~= nil and bk ~= nil and ak == bk
end

-- Anti-doublon local cote chasseur. Ce registre n'accorde aucun droit de
-- paiement : le signataire revalide toujours le COD contre son propre registre.
local function CanonicalLedgerPool(pool)
    pool = type(pool) == "string" and pool:lower() or nil
    if pool == "global" or pool == "fr" or pool == "de" or pool == "eu"
        or pool == "us" or pool == "na" then return "global" end
    return nil
end

local function MergeEuCodSendLedger(root, yieldWork)
    if codSendLedgerMigratedRoot == root then return end
    local global = type(root.global) == "table" and root.global or {}
    root.global = global
    for _, legacyPool in ipairs({ "fr", "de", "eu", "us", "na" }) do
        local bucket = root[legacyPool]
        if type(bucket) == "table" then
            for characterKey, sourceLedger in pairs(bucket) do
                if yieldWork then yieldWork() end
                if type(characterKey) == "string" and characterKey ~= ""
                    and type(sourceLedger) == "table" then
                    local targetLedger = global[characterKey]
                    if type(targetLedger) ~= "table" then
                        targetLedger = {}
                        global[characterKey] = targetLedger
                    end
                    for contractId, rawTimestamp in pairs(sourceLedger) do
                        if yieldWork then yieldWork() end
                        local timestamp = tonumber(rawTimestamp) or 0
                        if timestamp > (tonumber(targetLedger[contractId]) or 0) then
                            targetLedger[contractId] = timestamp
                        end
                    end
                end
            end
        end
    end
    -- Les sources restent attachees jusqu'au commit global qui suit aussi la
    -- sanitation. Une reprise refait sans risque cette union par max timestamp.
end

local function IsProtectedCodSend(contractId)
    if contractId == pendingContractId or contractId == activeContractId then return true end
    local mb = Overlord.ManualBounty
    local contract = mb and mb.GetContract and mb:GetContract(contractId)
    return contract ~= nil and contract.status == "approved"
end

local function InactiveNewestFirst(a, b)
    if a.timestamp ~= b.timestamp then return a.timestamp > b.timestamp end
    return a.id < b.id
end

local function SortInactiveCodSends(rows, yieldWork)
    if #rows < 2 then return end
    if not yieldWork then
        table.sort(rows, InactiveNewestFirst)
        return
    end
    -- table.sort ne peut pas ceder depuis son comparateur. Un merge-sort
    -- bottom-up garde le meme ordre total tout en bornant chaque tranche.
    local buffer, width, count = {}, 1, #rows
    while width < count do
        local first = 1
        while first <= count do
            local middle = math.min(first + width, count + 1)
            local finish = math.min(first + 2 * width - 1, count)
            local left, right, out = first, middle, first
            while left < middle or right <= finish do
                if right > finish
                    or (left < middle and InactiveNewestFirst(rows[left], rows[right])) then
                    buffer[out], left = rows[left], left + 1
                else
                    buffer[out], right = rows[right], right + 1
                end
                out = out + 1
                yieldWork()
            end
            for index = first, finish do
                rows[index] = buffer[index]
                yieldWork()
            end
            first = first + 2 * width
        end
        width = width * 2
    end
end

local function PruneCodSendLedger(ledger, now, yieldWork)
    local inactive = {}
    for contractId, rawTimestamp in pairs(ledger) do
        if yieldWork then yieldWork() end
        local timestamp = tonumber(rawTimestamp) or 0
        local validId = type(contractId) == "string" and #contractId <= 64
            and contractId:match("^MB[%w%-]+$") ~= nil
        if not validId or timestamp <= 0 or timestamp ~= timestamp then
            ledger[contractId] = nil
        elseif IsProtectedCodSend(contractId) then
            -- Un COD approuve reste protege sans TTL ni quota : le cap ne doit
            -- jamais rendre possible un second envoi pour un contrat actif.
            ledger[contractId] = timestamp
        elseif now - timestamp > COD_SEND_LEDGER_RETENTION_SEC then
            ledger[contractId] = nil
        else
            -- Une horloge corrompue ne doit pas rendre une entree immortelle.
            if timestamp > now then
                timestamp = now
                ledger[contractId] = timestamp
            end
            inactive[#inactive + 1] = { id = contractId, timestamp = timestamp }
        end
    end
    if #inactive <= COD_SEND_LEDGER_MAX_INACTIVE then return end
    SortInactiveCodSends(inactive, yieldWork)
    for index = COD_SEND_LEDGER_MAX_INACTIVE + 1, #inactive do
        local candidate = inactive[index]
        -- Une maintenance periodique peut s'etaler pendant une interaction de
        -- courrier. Ne supprimer que le snapshot exact et revalider la protection.
        if tonumber(ledger[candidate.id]) == candidate.timestamp
            and not IsProtectedCodSend(candidate.id) then
            ledger[candidate.id] = nil
        end
        if yieldWork then yieldWork() end
    end
end

local function GetCodSendLedgerContext(create)
    if not OverlordDB then return nil end
    local pool = CanonicalLedgerPool(Overlord.GetCurrentSavedVarsPool
        and Overlord:GetCurrentSavedVarsPool() or nil)
    local characterKey = NameKey(GetLocalFullName())
    if not pool or not characterKey or characterKey == "" then return nil end
    local root = OverlordDB.manualBountyCodSendLedger
    if type(root) ~= "table" then
        if not create then return nil end
        root = {}
        OverlordDB.manualBountyCodSendLedger = root
    end
    if create then
        if type(root[pool]) ~= "table" then root[pool] = {} end
        if type(root[pool][characterKey]) ~= "table" then
            root[pool][characterKey] = {}
        end
    end
    local ledger = type(root[pool]) == "table" and root[pool][characterKey] or nil
    return root, pool, characterKey, ledger
end

local function StartCodSendLedgerPreparation(root, pool, characterKey, keepValid)
    if not C_Timer or not C_Timer.After then return false end
    local state = codSendLedgerPrep
    state.generation = state.generation + 1
    local generation = state.generation
    state.pending = true
    if not keepValid then state.valid = false end
    state.root, state.pool, state.characterKey = root, pool, characterKey
    local processed = 0
    local started = debugprofilestop and debugprofilestop() or 0
    local preparedLedger
    local worker = coroutine.create(function()
        local function YieldWork()
            processed = processed + 1
            local elapsed = debugprofilestop and (debugprofilestop() - started) or 0
            if processed >= 64 or elapsed >= 1.25 then
                processed = 0
                coroutine.yield()
                started = debugprofilestop and debugprofilestop() or 0
            end
        end
        MergeEuCodSendLedger(root, YieldWork)
        if type(root[pool]) ~= "table" then root[pool] = {} end
        if type(root[pool][characterKey]) ~= "table" then
            root[pool][characterKey] = {}
        end
        preparedLedger = root[pool][characterKey]
        local now = GetServerTime()
        PruneCodSendLedger(preparedLedger, now, YieldWork)
        return now
    end)
    local ResumeWorker
    ResumeWorker = function()
        if state.generation ~= generation or state.root ~= root
            or OverlordDB.manualBountyCodSendLedger ~= root then return end
        local ok, completedAtOrErr = coroutine.resume(worker)
        if not ok then
            state.pending = false
            state.failures = (tonumber(state.failures) or 0) + 1
            if not keepValid then state.valid = false end
            if state.failures >= 3 then
                state.failed = true
            else
                state.retryAt = GetTime() + 5 * state.failures
            end
            return
        end
        if coroutine.status(worker) ~= "dead" then
            C_Timer.After(0, ResumeWorker)
            return
        end
        -- Commit unique migration + sanitation : avant ce point, un /reload ou
        -- une exception conserve FR/DE et ne publie aucun marker partiel.
        for _, oldPool in ipairs({ "fr", "de", "eu", "us", "na" }) do
            root[oldPool] = nil
        end
        codSendLedgerMigratedRoot = root
        state.pending, state.failed, state.retryAt = false, nil, nil
        state.valid, state.failures = true, 0
        state.ledger = preparedLedger
        codSendLedgerLastPrunedAt[preparedLedger] = tonumber(completedAtOrErr)
            or GetServerTime()
    end
    ResumeWorker()
    return state.valid == true
end

function Overlord.ManualBountyMail:EnsureCodSendLedgerPrepared()
    if not OverlordDB then return "blocked" end
    -- Un joueur n'ayant jamais utilise le COD n'a rien a migrer : ne pas creer
    -- de SavedVariable vide pendant la barriere login.
    if type(OverlordDB.manualBountyCodSendLedger) ~= "table" then return true end
    if not C_Timer or not C_Timer.After then return "blocked" end
    local root, pool, characterKey, ledger = GetCodSendLedgerContext(false)
    if not root or not pool or not characterKey then return "waiting" end
    local state = codSendLedgerPrep
    local current = state.root == root and state.pool == pool
        and state.characterKey == characterKey
    if current and state.valid and state.ledger == ledger
        and codSendLedgerMigratedRoot == root then return true end
    if current and state.pending then return false end
    if current and state.failed then return "blocked" end
    local now = GetTime()
    if current and state.retryAt and now < state.retryAt then return "waiting" end
    if not current then
        state.failures, state.failed, state.retryAt = 0, nil, nil
    end
    return StartCodSendLedgerPreparation(root, pool, characterKey, false)
end

local function EnsureCodSendLedger()
    if not OverlordDB then return nil end
    local existing = type(OverlordDB.manualBountyCodSendLedger) == "table"
    local root, pool, characterKey, ledger = GetCodSendLedgerContext(not existing)
    if not root then return nil end
    local state = codSendLedgerPrep
    if not existing then
        state.root, state.pool, state.characterKey = root, pool, characterKey
        state.ledger, state.valid, state.pending = ledger, true, false
        codSendLedgerMigratedRoot = root
    elseif state.root ~= root or state.pool ~= pool or state.characterKey ~= characterKey
        or not state.valid or state.ledger ~= ledger or codSendLedgerMigratedRoot ~= root then
        if not state.pending then
            if state.root ~= root or state.pool ~= pool or state.characterKey ~= characterKey then
                state.failures, state.failed, state.retryAt = 0, nil, nil
            end
            StartCodSendLedgerPreparation(root, pool, characterKey, false)
        end
        return nil
    end
    local now = GetServerTime()
    local lastPrunedAt = tonumber(codSendLedgerLastPrunedAt[ledger]) or 0
    if not state.pending
        and not state.failed
        and (not state.retryAt or GetTime() >= state.retryAt)
        and (lastPrunedAt <= 0 or now - lastPrunedAt >= COD_SEND_LEDGER_PRUNE_INTERVAL_SEC) then
        StartCodSendLedgerPreparation(root, pool, characterKey, true)
    end
    return ledger
end

local function WasCodInvoiceSent(contractId)
    local ledger = EnsureCodSendLedger()
    if not ledger then
        -- Registre existant mais non prepare : refuser conservativement un
        -- nouvel envoi plutot que risquer un double COD pendant la migration.
        return OverlordDB and type(OverlordDB.manualBountyCodSendLedger) == "table"
    end
    return (tonumber(ledger[contractId]) or 0) > 0
end

local function RecordCodInvoiceSent(contractId)
    local ledger = EnsureCodSendLedger()
    if not ledger or (tonumber(ledger[contractId]) or 0) > 0 then return false end
    ledger[contractId] = GetServerTime()
    return true
end

local function GetSendAttachmentStats()
    if not GetSendMailItem or not ATTACHMENTS_MAX_SEND then return 0, 0 end
    local slots = 0
    local units = 0
    for index = 1, ATTACHMENTS_MAX_SEND do
        local _, itemId, _, itemCount = GetSendMailItem(index)
        if itemId then
            slots = slots + 1
            units = units + math.max(1, tonumber(itemCount) or 1)
        end
    end
    return slots, units
end

local function HasSendAttachment()
    local slots = GetSendAttachmentStats()
    return slots > 0
end

local function HasSingleUnitAttachment()
    local slots, units = GetSendAttachmentStats()
    return slots == 1 and units == 1
end

local function ClearMailMoney()
    local current = SendMailMoney and MoneyInputFrame_GetCopper
        and MoneyInputFrame_GetCopper(SendMailMoney) or 0
    local codChecked = SendMailCODButton and SendMailCODButton:GetChecked() == true
    if current == 0 and not codChecked then return false end
    if codChecked and SetSendMailCOD then SetSendMailCOD(0) end
    if current ~= 0 and SetSendMailMoney then SetSendMailMoney(0) end
    if current ~= 0 and SendMailMoney and MoneyInputFrame_SetCopper then
        MoneyInputFrame_SetCopper(SendMailMoney, 0)
    end
    if SendMailFrame_Update then SendMailFrame_Update() end
    return true
end

local function ResetActiveMail()
    activeContractId = nil
    activeMode = nil
    activeReady = false
    fieldsPrepared = false
    infoNotified = false
    errorNotified = false
    refreshScheduled = false
    applyingMailFields = false
end

local function EnsureInboxStatusFrame()
    if inboxStatusFrame or not MailFrame then return inboxStatusFrame end
    local frame = CreateFrame("Frame", nil, MailFrame, "BackdropTemplate")
    frame:SetSize(350, 98)
    frame:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 6, -42)
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel((MailFrame:GetFrameLevel() or 1) + 20)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.text:SetPoint("TOPLEFT", 12, -10)
    frame.text:SetPoint("BOTTOMRIGHT", -12, 10)
    frame.text:SetJustifyH("LEFT")
    frame.text:SetJustifyV("MIDDLE")
    frame.text:SetWordWrap(true)
    frame:Hide()
    inboxStatusFrame = frame
    return frame
end

local function IsOverlordSubject(subject)
    return type(subject) == "string"
        and subject:lower():find("overlord", 1, true) ~= nil
end

local function ExtractCodContractId(subject)
    if type(subject) ~= "string" then return nil end
    return subject:match("^Overlord COD (MB[%w%-]+)$")
end

-- La validation repose sur l'expediteur Blizzard et le registre local du
-- signataire, jamais sur le seul sujet du courrier ni sur un payload distant.
local function ScanOverlordCodInbox()
    local status = EnsureInboxStatusFrame()
    if not status or not MailFrame or not MailFrame:IsShown()
        or not GetInboxNumItems or not GetInboxHeaderInfo then
        if status then status:Hide() end
        return
    end

    local candidatesById = {}
    local invalidCount = 0
    local okCount, inboxCount = pcall(GetInboxNumItems)
    inboxCount = okCount and tonumber(inboxCount) or 0
    for index = 1, inboxCount do
        local values = { pcall(GetInboxHeaderInfo, index) }
        if values[1] then
            local sender = values[4]
            local subject = values[5]
            local codAmount = tonumber(values[7]) or 0
            local itemCount = tonumber(values[9]) or 0
            if codAmount > 0 and IsOverlordSubject(subject) then
                local id = ExtractCodContractId(subject)
                if not id then
                    invalidCount = invalidCount + 1
                else
                    local bucket = candidatesById[id]
                    if not bucket then
                        bucket = {}
                        candidatesById[id] = bucket
                    end
                    bucket[#bucket + 1] = {
                        sender = sender,
                        amountCopper = codAmount,
                        itemCount = itemCount,
                    }
                end
            end
        end
    end

    local validCount = 0
    local mb = Overlord.ManualBounty
    for id, bucket in pairs(candidatesById) do
        if #bucket ~= 1 then
            -- Deux factures pour le meme contrat sont toutes marquees invalides.
            invalidCount = invalidCount + #bucket
        else
            local invoice = bucket[1]
            local valid = invoice.itemCount == 1 and mb and mb.ValidateCodInvoice
                and mb:ValidateCodInvoice(id, invoice.sender, invoice.amountCopper)
            if valid then
                validCount = validCount + 1
                if mb.RecordCodInvoiceSeen then
                    mb:RecordCodInvoiceSeen(id, invoice.sender, invoice.amountCopper)
                end
            else
                invalidCount = invalidCount + 1
            end
        end
    end

    if validCount <= 0 and invalidCount <= 0 then
        status:Hide()
        lastInboxStatusKey = ""
        return
    end

    local message
    if invalidCount > 0 and validCount > 0 then
        message = string.format(L.MB_MAIL_COD_MIXED, validCount, invalidCount)
    elseif invalidCount > 0 then
        message = string.format(L.MB_MAIL_COD_INVALID, invalidCount)
    else
        message = string.format(L.MB_MAIL_COD_VALID, validCount)
    end
    if invalidCount > 0 then
        status:SetBackdropColor(0.12, 0.015, 0.015, 0.96)
        status:SetBackdropBorderColor(0.95, 0.16, 0.10, 0.95)
        status.text:SetTextColor(1, 0.30, 0.22)
    else
        status:SetBackdropColor(0.015, 0.10, 0.025, 0.96)
        status:SetBackdropBorderColor(0.18, 0.85, 0.28, 0.95)
        status.text:SetTextColor(0.35, 1, 0.42)
    end
    status.text:SetText(message)
    status:Show()

    local statusKey = validCount .. ":" .. invalidCount
    if statusKey ~= lastInboxStatusKey and Overlord.PrintNotification then
        Overlord:PrintNotification((invalidCount > 0 and "|cFFFF2222" or "|cFF44FF55")
            .. "[Overlord]|r " .. message)
    end
    lastInboxStatusKey = statusKey
end

local function FillCommonFields(contract, recipient, subject, body, selectSendTab)
    if not contract or not recipient or recipient == ""
        or not SendMailNameEditBox or not SendMailSubjectEditBox then
        return false
    end
    if selectSendTab and MailFrameTab2 then MailFrameTab2:Click() end
    if not NamesMatch(SendMailNameEditBox:GetText(), recipient) then
        SendMailNameEditBox:SetText(recipient)
    end
    if SendMailSubjectEditBox:GetText() ~= subject then
        SendMailSubjectEditBox:SetText(subject)
    end
    if SendMailBodyEditBox and SendMailBodyEditBox:GetText() ~= body then
        SendMailBodyEditBox:SetText(body)
    end
    return true
end

local function FillDirectPaymentFields(contract, selectSendTab)
    if not contract or not contract.id or contract.id == ""
        or not contract.target or contract.target == ""
        or not contract.claimer or contract.claimer == ""
        or not contract.amountCopper or not SendMailMoney
        or not MoneyInputFrame_SetCopper or not SetSendMailCOD
        or not SetSendMailMoney then
        return false
    end
    local subject = string.format(L.MB_MAIL_SUBJECT, contract.id)
    local body = string.format(
        L.MB_MAIL_BODY, contract.id, contract.target, GetLocalFullName() or "")
    if not FillCommonFields(contract, contract.claimer, subject, body, selectSendTab) then
        return false
    end
    local changed = false
    if SendMailRadioButton_OnClick and SendMailSendMoneyButton
        and SendMailSendMoneyButton:GetChecked() ~= true then
        if SendMailCODButton and SendMailCODButton:GetChecked() == true then
            SetSendMailCOD(0)
        end
        SetSendMailMoney(0)
        SendMailRadioButton_OnClick(1)
        changed = true
    end
    if not MoneyInputFrame_GetCopper
        or MoneyInputFrame_GetCopper(SendMailMoney) ~= contract.amountCopper then
        MoneyInputFrame_SetCopper(SendMailMoney, contract.amountCopper)
        changed = true
    end
    if changed and SendMailFrame_Update then SendMailFrame_Update() end
    return true
end

local function DirectPaymentFieldsAreSafe(contract)
    if not contract or not SendMailNameEditBox or not SendMailSubjectEditBox
        or not SendMailMoney or not MoneyInputFrame_GetCopper
        or not SendMailSendMoneyButton or not SendMailCODButton then
        return false
    end
    return not HasSendAttachment()
        and NamesMatch(SendMailNameEditBox:GetText(), contract.claimer)
        and SendMailSubjectEditBox:GetText() == string.format(L.MB_MAIL_SUBJECT, contract.id)
        and SendMailSendMoneyButton:GetChecked() == true
        and SendMailCODButton:GetChecked() ~= true
        and MoneyInputFrame_GetCopper(SendMailMoney) == contract.amountCopper
end

local function FillCodFields(contract, selectSendTab)
    if not contract or not contract.id or contract.id == ""
        or not contract.target or contract.target == ""
        or not contract.poster or contract.poster == ""
        or not contract.amountCopper or not SendMailMoney
        or not MoneyInputFrame_SetCopper or not SetSendMailCOD
        or not SetSendMailMoney then
        return false
    end
    local subject = string.format(L.MB_COD_SUBJECT, contract.id)
    local body = string.format(L.MB_COD_BODY, contract.id, contract.target)
    if not FillCommonFields(contract, contract.poster, subject, body, selectSendTab) then
        return false
    end
    if not HasSingleUnitAttachment() then
        ClearMailMoney()
        return true
    end
    if not SendMailRadioButton_OnClick or not SendMailCODButton
        or not SendMailSendMoneyButton or not MoneyInputFrame_GetCopper then
        ClearMailMoney()
        return false
    end
    local changed = false
    if SendMailCODButton:GetChecked() ~= true then
        SendMailRadioButton_OnClick(2)
        changed = true
    end
    if MoneyInputFrame_GetCopper(SendMailMoney) ~= contract.amountCopper then
        MoneyInputFrame_SetCopper(SendMailMoney, contract.amountCopper)
        changed = true
    end
    if changed and SendMailFrame_Update then SendMailFrame_Update() end
    return true
end

local function CodFieldsAreSafe(contract)
    if not contract or not SendMailNameEditBox or not SendMailSubjectEditBox
        or not SendMailMoney or not MoneyInputFrame_GetCopper
        or not SendMailSendMoneyButton or not SendMailCODButton then
        return false
    end
    return HasSingleUnitAttachment()
        and NamesMatch(SendMailNameEditBox:GetText(), contract.poster)
        and SendMailSubjectEditBox:GetText() == string.format(L.MB_COD_SUBJECT, contract.id)
        and SendMailCODButton:GetChecked() == true
        and SendMailSendMoneyButton:GetChecked() ~= true
        and MoneyInputFrame_GetCopper(SendMailMoney) == contract.amountCopper
end

local function GetActiveContract()
    local mb = Overlord.ManualBounty
    if not mb or not activeContractId then return nil end
    local contract = mb:GetContract(activeContractId)
    local ok
    if activeMode == MODE_COD then
        ok = contract and mb.CanPrepareCodPayment
            and not WasCodInvoiceSent(activeContractId)
            and mb:CanPrepareCodPayment(contract)
    else
        ok = contract and mb.CanPreparePayment and mb:CanPreparePayment(contract)
    end
    return ok and contract or nil
end

local function ClearPreparedFields(contract)
    ClearMailMoney()
    if not fieldsPrepared or not contract then return end
    local expectedSubject = activeMode == MODE_COD
        and string.format(L.MB_COD_SUBJECT, contract.id)
        or string.format(L.MB_MAIL_SUBJECT, contract.id)
    if SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() == expectedSubject then
        SendMailSubjectEditBox:SetText("")
        if SendMailBodyEditBox then SendMailBodyEditBox:SetText("") end
    end
end

local function RefreshActiveMail()
    refreshScheduled = false
    if applyingMailFields or not activeContractId
        or not MailFrame or not MailFrame:IsShown() then return end
    local mb = Overlord.ManualBounty
    local previous = mb and mb:GetContract(activeContractId)
    local contract = GetActiveContract()
    if not contract then
        ClearPreparedFields(previous)
        ResetActiveMail()
        return
    end

    applyingMailFields = true
    local prepared
    if activeMode == MODE_COD then
        prepared = FillCodFields(contract, not fieldsPrepared)
        activeReady = prepared and CodFieldsAreSafe(contract)
        if activeReady then
            if not infoNotified and Overlord.PrintNotification then
                Overlord:PrintNotification(L.MB_COD_READY)
            end
            infoNotified = true
            errorNotified = false
        elseif not HasSingleUnitAttachment() then
            if not infoNotified and Overlord.PrintNotification then
                Overlord:PrintNotification(L.MB_COD_WAIT_ITEM)
            end
            infoNotified = true
        elseif not errorNotified and Overlord.PrintNotification then
            Overlord:PrintNotification(L.MB_ERR_COD_AMOUNT)
            errorNotified = true
        end
    else
        prepared = FillDirectPaymentFields(contract, not fieldsPrepared)
        activeReady = prepared and DirectPaymentFieldsAreSafe(contract)
        if HasSendAttachment() then
            ClearMailMoney()
            activeReady = false
            if not errorNotified and Overlord.PrintNotification then
                Overlord:PrintNotification(L.MB_ERR_PAYMENT_ATTACHMENT)
            end
            errorNotified = true
        elseif activeReady then
            if not infoNotified and Overlord.PrintNotification then
                Overlord:PrintNotification(L.MB_MAIL_READY)
            end
            infoNotified = true
            errorNotified = false
        elseif not errorNotified and Overlord.PrintNotification then
            ClearMailMoney()
            Overlord:PrintNotification(L.MB_ERR_PAYMENT_AMOUNT)
            errorNotified = true
        end
    end
    fieldsPrepared = prepared and true or fieldsPrepared
    if not prepared then
        ClearPreparedFields(contract)
        applyingMailFields = false
        ResetActiveMail()
        if Overlord.PrintNotification then Overlord:PrintNotification(L.MB_ERR_MAIL_UI) end
        return
    end
    applyingMailFields = false
end

local function ScheduleActiveMailRefresh(delay)
    if refreshScheduled then return end
    refreshScheduled = true
    C_Timer.After(delay or 0, RefreshActiveMail)
end

local function AttachActiveMailFieldHooks()
    local boxes = { SendMailNameEditBox, SendMailSubjectEditBox, SendMailBodyEditBox }
    for i = 1, #boxes do
        local box = boxes[i]
        if box and box.HookScript and not box._overlordManualBountyHooked then
            box._overlordManualBountyHooked = true
            box:HookScript("OnTextChanged", function()
                if activeContractId and not applyingMailFields then
                    ScheduleActiveMailRefresh(0.05)
                end
            end)
        end
    end
end

local function BeginActiveMail(contractId, mode)
    ResetActiveMail()
    activeContractId = contractId
    activeMode = mode
    AttachActiveMailFieldHooks()
    RefreshActiveMail()
end

local function PrepareAtMailbox(contractId, mode)
    if MailFrame and MailFrame:IsShown() then
        if not Overlord.ManualBountyMail:IsMailAPIAvailable() then
            return false, L.MB_ERR_MAIL_UI
        end
        pendingContractId = nil
        pendingMode = nil
        BeginActiveMail(contractId, mode)
        return activeContractId ~= nil, activeContractId and nil or L.MB_ERR_MAIL_UI
    end
    pendingContractId = contractId
    pendingMode = mode
    if Overlord.PrintNotification then Overlord:PrintNotification(L.MB_MAIL_GO_MAILBOX) end
    return true, L.MB_MAIL_GO_MAILBOX
end

-- Check the loaded mailbox on the running client too. API presence in the
-- Forever source does not guarantee that every beta build exposes the UI.
function Overlord.ManualBountyMail:IsMailAPIAvailable()
    return type(GetSendMailItem) == "function"
        and type(SetSendMailCOD) == "function"
        and type(SetSendMailMoney) == "function"
        and type(MoneyInputFrame_GetCopper) == "function"
        and type(MoneyInputFrame_SetCopper) == "function"
        and type(SendMailRadioButton_OnClick) == "function"
        and SendMailNameEditBox ~= nil and SendMailSubjectEditBox ~= nil
        and SendMailMoney ~= nil and SendMailCODButton ~= nil
        and SendMailSendMoneyButton ~= nil
end

-- Solution de secours : le signataire envoie directement l'or.
function Overlord.ManualBountyMail:PreparePayment(contractId)
    if InCombatLockdown and InCombatLockdown() then return false, L.CANNOT_IN_COMBAT end
    local mb = Overlord.ManualBounty
    if not mb then return false, L.MB_ERR_MODULE end
    local contract = mb:GetContract(contractId)
    if not contract or not mb.CanPreparePayment then return false, L.MB_ERR_NOT_APPROVED end
    local ok, err = mb:CanPreparePayment(contract)
    if not ok then return false, err end
    return PrepareAtMailbox(contractId, MODE_DIRECT)
end

-- Parcours principal : le chasseur approuve adresse une facture COD au signataire.
function Overlord.ManualBountyMail:PrepareCodPayment(contractId)
    if InCombatLockdown and InCombatLockdown() then return false, L.CANNOT_IN_COMBAT end
    local mb = Overlord.ManualBounty
    if not mb then return false, L.MB_ERR_MODULE end
    local contract = mb:GetContract(contractId)
    if not contract or not mb.CanPrepareCodPayment then return false, L.MB_ERR_NOT_APPROVED end
    local ok, err = mb:CanPrepareCodPayment(contract)
    if not ok then return false, err end
    if WasCodInvoiceSent(contractId) then return false, L.MB_ERR_COD_ALREADY_SENT end
    return PrepareAtMailbox(contractId, MODE_COD)
end

function Overlord.ManualBountyMail:WasCodInvoiceSent(contractId)
    return WasCodInvoiceSent(contractId)
end

function Overlord.ManualBountyMail:Initialize()
    if self._initialized then return end
    self._initialized = true
    -- La barriere login a deja prepare un registre existant par tranches. Le
    -- getter reste fail-closed si Initialize est invoque hors de ce pipeline.
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("MAIL_SHOW")
    frame:RegisterEvent("MAIL_INBOX_UPDATE")
    frame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
    frame:RegisterEvent("MAIL_SEND_SUCCESS")
    frame:RegisterEvent("MAIL_CLOSED")
    frame:SetScript("OnEvent", function(_, event)
        if event == "MAIL_SHOW" then
            ScanOverlordCodInbox()
            if pendingContractId then
                local contractId = pendingContractId
                local mode = pendingMode
                pendingContractId = nil
                pendingMode = nil
                BeginActiveMail(contractId, mode)
                ScheduleActiveMailRefresh(0.1)
            end
        elseif event == "MAIL_INBOX_UPDATE" then
            ScanOverlordCodInbox()
        elseif event == "MAIL_SEND_INFO_UPDATE" then
            if activeContractId and not applyingMailFields then ScheduleActiveMailRefresh(0) end
        elseif event == "MAIL_SEND_SUCCESS" then
            local sentId = activeContractId
            local sentMode = activeMode
            local ready = activeReady
            pendingContractId = nil
            pendingMode = nil
            ResetActiveMail()
            if sentId and ready then
                if sentMode == MODE_COD then
                    if RecordCodInvoiceSent(sentId) and Overlord.PrintNotification then
                        Overlord:PrintNotification(L.MB_COD_SENT)
                    end
                elseif Overlord.ManualBounty
                    and Overlord.ManualBounty.RecordPaymentMailSent then
                    local ok = Overlord.ManualBounty:RecordPaymentMailSent(sentId)
                    if ok and Overlord.PrintNotification then
                        Overlord:PrintNotification(L.MB_MAIL_SENT)
                    end
                end
                if Overlord.ManualBountyUI and Overlord.ManualBountyUI.RequestRefresh then
                    Overlord.ManualBountyUI:RequestRefresh()
                end
            end
        elseif event == "MAIL_CLOSED" then
            pendingContractId = nil
            pendingMode = nil
            ResetActiveMail()
            if inboxStatusFrame then inboxStatusFrame:Hide() end
            lastInboxStatusKey = ""
        end
    end)
end
