-- Exercise the real contract and wire state machines through both settlement paths.
local now, serverNow, epoch = 100, 2000000000, 1999999900
local timers = {}
function GetTime() return now end
function GetServerTime() return serverNow end
function IsInInstance() return false end
function IsInGroup() return true end
function IsInRaid() return false end
function UnitGUID() return "Player-1234-ABCDEF" end
function wipe(values) for key in pairs(values) do values[key] = nil end end
function strsplit(separator, value, limit)
    local parts, offset = {}, 1
    while not limit or #parts < limit - 1 do
        local first, last = string.find(value, separator, offset, true)
        if not first then break end
        parts[#parts + 1] = value:sub(offset, first - 1)
        offset = last + 1
    end
    parts[#parts + 1] = value:sub(offset)
    return unpack(parts)
end
local function expect(condition, message)
    if not condition then error(message, 2) end
end
local function advance(seconds) now, serverNow = now + seconds, serverNow + seconds end
C_Timer = {
    After = function(_, callback) timers[#timers + 1] = callback end,
    NewTimer = function() return { Cancel = function() end } end,
}
OverlordDB = { lastResetTimestamp = epoch, config = {} }
Overlord = {
    L = setmetatable({}, { __index = function(_, key) return key end }),
    InActiveFront = true, PlayerFaction = "Alliance",
    GetCurrentSavedVarsPool = function() return "eu" end,
    GetCurrentCampaignWireEpoch = function() return epoch end,
    CampaignEpochsMatch = function(_, left, right) return left == right end,
    CommunityModeEnabled = false,
    Sync = {
        HasCompleteContributorIdentity = function(_, name) return type(name) == "string" and name:match("^%a+ %a+$") ~= nil end,
        GetPlayerFullName = function() return "Poster Tester" end,
        GetCaptureContributorDedupKey = function(_, name) return name and name:lower() end,
        Send = function() end,
    },
}
dofile("ManualBounty.lua")
dofile("ManualBountySync.lua")
local bounty, sync = Overlord.ManualBounty, Overlord.ManualBountySync
local function create(name)
    local contract, err = bounty:CreateContract(name, 250000, {
        name = name, faction = "Horde", race = "Orc", raceSex = 2,
        guild = "Guild", communityEligible = false,
    })
    expect(contract ~= nil, "contract creation failed: " .. tostring(err))
    return contract
end
local function claim(contract, proofFirst)
    local pk = sync:BuildPKPayload(contract.id, "Hunter Tester", contract.target,
        "eu", epoch, serverNow)
    local mk = sync:BuildMKPayload("Hunter Tester", contract.target, "eu", epoch, serverNow)
    expect(pk and mk, "proof payload could not be built")
    sync:OnReceiveMK(mk, "Impostor Tester")
    if proofFirst then
        sync:OnReceiveMK(mk, contract.target)
        expect(contract.status == "open", "MK alone claimed the contract")
        sync:OnReceivePK(pk, "Hunter Tester")
    else
        sync:OnReceivePK(pk, "Hunter Tester")
        expect(contract.status == "open", "PK alone or forged MK claimed the contract")
        sync:OnReceiveMK(mk, contract.target)
    end
    expect(contract.status == "claimed" and contract.claimer == "Hunter Tester",
        "PK+MK did not converge to the claimant")
    expect(bounty:GetLocalSettlementEntry(contract.id).status == "claimed",
        "proof did not update the signer settlement ledger")
    expect(not bounty:AuthorizePayment(contract.id), "payment was approved before convergence")
    advance(61)
    expect(bounty:AuthorizePayment(contract.id), "signer could not authorize converged claim")
end

local cod = create("CodTarget Tester")
expect(bounty:GetOutstandingContractCount() == 1
    and bounty:GetOutstandingExposureCopper() == 250000, "open financial exposure is incorrect")
expect(not bounty:CreateContract(cod.target, 250000, {
    name = cod.target, faction = "Horde", communityEligible = false,
}), "duplicate target contract was signed")
claim(cod, false)
expect(not bounty:ValidateCodInvoice(cod.id, "Impostor Tester", cod.amountCopper),
    "forged COD sender was accepted")
expect(not bounty:ValidateCodInvoice(cod.id, "Hunter Tester", cod.amountCopper + 1),
    "wrong COD amount was accepted")
expect(not bounty:MarkPaid(cod.id), "unpaid contract could be marked paid")
expect(bounty:RecordCodInvoiceSeen(cod.id, "Hunter Tester", cod.amountCopper),
    "first valid COD invoice could not be recorded")
expect(bounty:RecordCodInvoiceSeen(cod.id, "Hunter Tester", cod.amountCopper),
    "same valid invoice was not idempotent")
expect(not bounty:CanPreparePayment(cod), "direct payment allowed after validated COD")
expect(bounty:MarkPaid(cod.id), "signer could not confirm COD settlement")
expect(not bounty:MarkPaid(cod.id), "settlement could be confirmed twice")

local direct = create("DirectTarget Tester")
claim(direct, true)
expect(bounty:CanPreparePayment(direct), "approved direct payment was rejected")
expect(bounty:RecordPaymentMailSent(direct.id), "successful direct mail was not recorded")
expect(not bounty:RecordPaymentMailSent(direct.id), "direct mail could be recorded twice")
expect(not bounty:ValidateCodInvoice(direct.id, "Hunter Tester", direct.amountCopper),
    "COD was allowed after direct mail payment")
expect(bounty:MarkPaid(direct.id), "direct settlement could not be confirmed")

local retained = create("RetainedTarget Tester")
claim(retained, false)
local cancelled = create("CancelledTarget Tester")
expect(bounty:CancelContract(cancelled.id), "owner could not cancel an open contract")
epoch = epoch + 1000
OverlordDB.lastResetTimestamp = epoch
bounty:OnCampaignReset()
expect(bounty:GetContract(retained.id).status == "approved",
    "campaign reset lost an approved financial obligation")
expect(bounty:CanPreparePayment(bounty:GetContract(retained.id)),
    "previous-campaign approved contract became unpayable")
expect(bounty:GetContract(cancelled.id) == nil, "cancelled contract survived reset")
expect(bounty:GetOutstandingContractCount() == 1, "reset altered outstanding obligations")

-- Simulated /reload: only saved data survives and the real login barrier rebuilds it.
timers = {}
Overlord.InActiveFront = false
dofile("ManualBounty.lua")
bounty = Overlord.ManualBounty
expect(bounty:Initialize() == "waiting", "reload preparation did not use login barrier")
local iterations = 0
while not bounty._initialized do
    expect(#timers > 0, "reload lost its continuation")
    table.remove(timers, 1)()
    iterations = iterations + 1
    expect(iterations < 100, "reload did not finish")
end
expect(bounty:GetContract(retained.id).status == "approved"
    and bounty:CanPreparePayment(bounty:GetContract(retained.id)),
    "reload lost the approved signer obligation")
expect(bounty:GetLocalSettlementEntry(direct.id).paymentSentAt > 0,
    "reload lost the direct payment anti-duplicate record")
print("Forever contracts: complete names, PK+MK proof in either order, forged proofs rejected, COD/direct payment, duplicate guards, reset and reload OK")
