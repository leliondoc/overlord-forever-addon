-- Mail preparation uses the same globals as Forever's Blizzard_MailFrame.
-- Sending stays a player action; no payment is recorded before MAIL_SEND_SUCCESS.
local onEvent, paid, automaticSends = nil, 0, 0
local contract = { id = "MBMAIL-1", poster = "Poster Tester", target = "Victim Tester",
    claimer = "Hunter Tester", amountCopper = 10000 }
OverlordDB = {}
Overlord = {
    L = { MB_MAIL_SUBJECT = "Overlord %s", MB_MAIL_BODY = "%s %s %s", MB_ERR_MAIL_UI = "Unavailable" },
    Sync = {
        GetPlayerFullName = function() return contract.poster end,
        GetCaptureContributorDedupKey = function(_, name) return name:lower() end,
    },
    ManualBounty = {
        GetContract = function() return contract end,
        CanPreparePayment = function() return true end,
        FormatCopper = function(_, value) return tostring(value) end,
        RecordPaymentMailSent = function() paid = paid + 1; return true end,
    },
}
function GetTime() return 100 end
function GetServerTime() return 1790017000 end
function InCombatLockdown() return false end
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end }
end
local function box()
    return { text = "", GetText = function(self) return self.text end,
        SetText = function(self, text) self.text = text end, HookScript = function() end }
end
MailFrame = { IsShown = function() return true end }
MailFrameTab2 = { Click = function() end }
SendMailNameEditBox, SendMailSubjectEditBox, SendMailBodyEditBox = box(), box(), box()
SendMailMoney = { copper = 0 }
SendMailSendMoneyButton = { GetChecked = function() return true end }
SendMailCODButton = { GetChecked = function() return false end }
ATTACHMENTS_MAX_SEND = 12
function GetSendMailItem() return nil end
function SetSendMailCOD() end
function SetSendMailMoney() end
function MoneyInputFrame_GetCopper(frame) return frame.copper end
function MoneyInputFrame_SetCopper(frame, copper) frame.copper = copper end
function SendMailRadioButton_OnClick() end
function SendMail() automaticSends = automaticSends + 1 end
assert(loadfile("ManualBountyMail.lua"))()
local mail = Overlord.ManualBountyMail
mail:Initialize()
assert(mail:IsMailAPIAvailable())
local ok, err = mail:PreparePayment(contract.id)
assert(ok, err)
assert(SendMailNameEditBox:GetText() == "Hunter Tester", "Surname was lost from the recipient")
assert(SendMailMoney.copper == contract.amountCopper, "Prepared amount differs from the contract")
assert(automaticSends == 0 and paid == 0, "Preparation sent gold or recorded a payment")
onEvent(nil, "MAIL_SEND_SUCCESS")
assert(paid == 1 and automaticSends == 0)
onEvent(nil, "MAIL_SEND_SUCCESS")
assert(paid == 1, "Duplicate mail event paid twice")
SetSendMailCOD = nil
assert(not mail:IsMailAPIAvailable())
assert(not mail:PreparePayment(contract.id), "Unavailable beta mail API was accepted")
print("Forever mail: complete recipient, exact amount, manual send, success-only accounting, duplicate and missing-API guards OK")
