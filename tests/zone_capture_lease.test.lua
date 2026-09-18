-- Regression tests for ZoneCaptureLease.lua.
-- Run with a Lua 5.1-compatible runtime (the local validation uses Fengari).

local mono = 0
local wallBase = 1800000000
function GetTime() return mono end
function time() return wallBase + math.floor(mono) end

function strsplit(separator, value)
    local fields, start = {}, 1
    while true do
        local pos = string.find(value, separator, start, true)
        if not pos then
            fields[#fields + 1] = string.sub(value, start)
            break
        end
        fields[#fields + 1] = string.sub(value, start, pos - 1)
        start = pos + #separator
    end
    return (unpack or table.unpack)(fields)
end

Enum = { PvPFaction = { Alliance = 1, Horde = 0 } }
local scheduled = {}
C_Timer = {
    NewTicker = function() return { Cancel = function() end } end,
    After = function(_, callback) scheduled[#scheduled + 1] = callback end,
}

local physicalEnabled = false
local physicalName = "Alice"
local physicalFaction = "Alliance"
C_Map = {
    GetBestMapForUnit = function() return 1 end,
    GetPlayerMapPosition = function(_, unit)
        if not physicalEnabled or unit ~= "party1" then return nil end
        return { GetXY = function() return 0.50, 0.50 end }
    end,
}
function UnitExists(unit) return physicalEnabled and unit == "party1" end
function UnitIsPlayer(unit) return UnitExists(unit) end
function UnitFactionGroup(unit) return UnitExists(unit) and physicalFaction or nil end
function UnitIsDead() return false end
function UnitIsGhost() return false end
function UnitIsConnected(unit) return UnitExists(unit) end
function UnitInPhase(unit) return UnitExists(unit) end
function UnitIsVisible(unit) return UnitExists(unit) end
function UnitGUID(unit)
    if unit == "player" then return "Player-1-LOCALHERO" end
    return UnitExists(unit) and ("Player-1-" .. string.upper(physicalName)) or nil
end

local function runScheduled()
    local pending = scheduled
    scheduled = {}
    for _, callback in ipairs(pending) do callback() end
end

local sent, refreshes, mapRefreshes, consumed, availabilityRefreshes = {}, 0, 0, 0, 0
local barricadeActive = true
local observedFaction = {
    alice = "Alliance",
    bob = "Horde",
    charlie = "Horde",
    localhero = "Alliance",
}

local zone = {
    id = "test_zone", status = "captured", owner = "Alliance",
    capturedTime = wallBase - 50, updatedAt = wallBase - 50,
    killsCurrent = 4, allyKillsCurrent = 3, enemyKillsCurrent = 1,
    holdTimeElapsed = 0, holdTimeRequired = 120, isCapital = false,
    center = { 50, 50 }, radius = 5,
}

Overlord = {
    PlayerFaction = "Alliance",
    InActiveFront = true,
    UI = { RequestRefresh = function() refreshes = refreshes + 1 end },
    MapMarkers = { RequestOverlayRefresh = function() mapRefreshes = mapRefreshes + 1 end },
    Ressources = {
        IsBarricadeActive = function() return barricadeActive end,
        ConsumeBarricade = function()
            consumed = consumed + 1
            return 60
        end,
    },
}
function Overlord:SafeGetUnitName(unit)
    return UnitExists(unit) and physicalName or nil
end

Overlord.Sync = {
    GetCaptureContributorDedupKey = function(_, name)
        if type(name) ~= "string" or name == "" then return nil end
        return string.lower(name)
    end,
    CaptureContributorMatchesSender = function(self, contributor, sender)
        return self:GetCaptureContributorDedupKey(contributor)
            == self:GetCaptureContributorDedupKey(sender)
    end,
    IsObservedPlayerFaction = function(_, name, faction)
        return observedFaction[string.lower(name or "")] == faction
    end,
    GetOnlineCommunityMemberFactionIfFresh = function(_, name)
        local faction = observedFaction[string.lower(name or "")]
        return faction and Enum.PvPFaction[faction] or nil
    end,
    GetPlayerFullName = function() return "LocalHero" end,
    ResolveCaptureNetworkWitnessRoute = function(
        _, zoneId, owner, origin, wave, guid, candidate, routeId)
        if candidate ~= "LocalHero" or type(routeId) ~= "string"
            or not routeId:match("^[0-9a-f]+$") then return nil end
        if wave == "wopeningretry" then
            return {
                seed = table.concat({ zoneId, owner, origin, wave, guid }, "|"),
                routeId = routeId,
                slot = 3, size = 3,
                baseline = 0,
                openedAt = wave == "wsecondround" and GetTime() - 6 or GetTime(),
                targets = { "WitnessOne", "WitnessTwo", "LocalHero" },
                keySet = { witnessone = true, witnesstwo = true, localhero = true },
                predecessorName = "WitnessTwo", predecessorKey = "witnesstwo",
                successorName = "WitnessOne", successorKey = "witnessone",
            }
        end
        return {
            seed = table.concat({ zoneId, owner, origin, wave, guid }, "|"),
            routeId = routeId,
            slot = 1, size = 2,
            baseline = 0,
            openedAt = wave == "wsecondround" and GetTime() - 6 or GetTime(),
            targets = { "LocalHero", "WitnessTwo" },
            keySet = { localhero = true, witnesstwo = true },
            predecessorName = "WitnessTwo", predecessorKey = "witnesstwo",
            successorName = "WitnessTwo", successorKey = "witnesstwo",
        }
    end,
    Send = function(_, kind, payload) sent[#sent + 1] = kind .. ":" .. payload return true end,
    SendToChannel = function(_, kind, payload) sent[#sent + 1] = kind .. ":" .. payload return true end,
    BroadcastToCommunity = function(_, kind, payload) sent[#sent + 1] = kind .. ":" .. payload return true end,
    BroadcastZoneState = function() sent[#sent + 1] = "ZS" end,
    BroadcastCaptureBarrier = function(_, _, _, origin, wave, guid, required)
        sent[#sent + 1] = table.concat({ "CB", origin, wave, guid, required }, ":")
    end,
    OnRemoteCaptureLeaseEnded = function() end,
}

Overlord.Zones = {
    GetZone = function(_, id) return id == zone.id and zone or nil end,
    GetBaseZoneFixedOwner = function() return nil end,
    GetCurrentPlayerZone = function() return physicalEnabled and zone or nil end,
    GetMapAspectRatio = function() return 1 end,
    UpdateAvailableZones = function() availabilityRefreshes = availabilityRefreshes + 1 end,
}
Overlord.Fronts = {
    Order = { "test" },
    GetFront = function() return { zones = { zone } } end,
    GetZone = function(_, id)
        if id == zone.id then return zone, { id = "test" } end
        return nil
    end,
    GetMapID = function() return 1 end,
}
Overlord.ZoneControl = {
    IsPlayerInNonCaptureStateForSync = function() return false end,
    ScanNearbyPlayers = function() return 2, 0 end,
}

local function expect(condition, message)
    if not condition then error(message or "expectation failed", 2) end
end

local function resetZone()
    zone.status = "captured"
    zone.owner = "Alliance"
    zone.capturedTime = wallBase - 50
    zone.updatedAt = wallBase - 50
    zone.killsCurrent = 4
    zone.allyKillsCurrent = 3
    zone.enemyKillsCurrent = 1
    zone.holdTimeElapsed = 0
    zone.holdTimeRequired = 120
    zone.previousOwner = nil
    zone._assaultFromAvailable = nil
    zone.isHolding = false
    zone.isPaused = false
    zone.isContested = false
    zone.holdStartTime = nil
    zone.holdAuthorityLocal = nil
    zone._remoteCaptureLease = nil
    zone._localCaptureWaveId = nil
    zone._localCaptureOpenedAt = nil
    zone._localCaptureBase = nil
    zone._captureReleaseSentWave = nil
    zone._loginSyncUnconfirmed = nil
end

dofile("ZoneCaptureLease.lua")
local Lease = Overlord.CaptureLease

-- Le sender direct est canonique sans dependre d'un cache de faction local.
local wrongFaction = Lease:ValidateProgress(
    zone.id, "Horde", "Alice", "wfaction", wallBase, 5, 0, 120, nil, "Alice")
expect(wrongFaction and wrongFaction.direct,
    "direct packet depended on receiver-local faction evidence")

-- Le capteur direct correctement lie au sender et a sa faction ouvre le bail.
local direct = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wdirect", wallBase, 10, 2, 120, 7, "Bob")
expect(direct and direct.direct, "valid direct progress rejected")
expect(direct.kills == 0 and direct.holdReq == 120 and direct.proofRequired == 120,
    "direct packet did not keep normalized gameplay fields")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", direct), "direct lease was not adopted")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 10, wallBase
local persisted = Lease:GetPersistableView(zone)
expect(persisted.status == "captured" and persisted.owner == "Alliance",
    "remote overlay leaked into persistable state")

-- Soft expiry fige l'affichage ; hard expiry restaure exactement le snapshot, local-only.
mono = 21
expect(Lease:IsSoftExpired(zone), "soft expiry missing")
-- Trois relais d'une version identique ne renouvellent ni le TTL ni l'autorite.
mono = 50
local echoOne = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wdirect", wallBase, 10, 2, 120, 7, "EchoOne")
local echoTwo = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wdirect", wallBase, 10, 2, 120, 7, "EchoTwo")
local echoThree = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wdirect", wallBase, 10, 2, 120, 7, "EchoThree")
expect(echoOne == nil and echoTwo == nil and echoThree == nil,
    "a relayed ZS entered the direct lease")
expect(zone._remoteCaptureLease.lastSeen == 0,
    "identical replay renewed lease liveness")
mono = 91
local sentBeforeExpire = #sent
expect(Lease:MaybeExpire(zone), "hard expiry missing")
expect(zone.status == "captured" and zone.owner == "Alliance" and zone.killsCurrent == 4,
    "hard expiry did not restore the confirmed snapshot")
expect(#sent == sentBeforeExpire, "hard expiry broadcast a state")
expect(refreshes > 0 and mapRefreshes > 0, "hard expiry did not refresh visuals")
local availabilityBefore = availabilityRefreshes
runScheduled()
expect(availabilityRefreshes == availabilityBefore + 1,
    "hard expiry did not recompute dependent availability")
expect(not Lease:AdoptRemote(zone, "Horde", "Bob", direct), "expired wave resurrected")

-- Aucun nombre de relais frais ne peut fabriquer une autorite receiver-local.
mono = 100
local relay1 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wrelay", wallBase + 100, 90, 9, 180, 3, "RelayOne")
local relay2 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wrelay", wallBase + 99, 80, 8, 180, 3, "RelayTwo")
local relay3 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wrelay", wallBase + 98, 70, 7, 180, 3, "RelayThree")
expect(relay1 == nil and relay2 == nil, "relay quorum accepted too early")
expect(relay3 == nil, "third relay fabricated a local quorum")

-- Le capteur direct reste canonique meme apres deux relais ignores.
local thirdDirect1 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wthird", wallBase + 110, 40, 4, 180, 4, "RelayFour")
local thirdDirect2 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wthird", wallBase + 109, 30, 3, 180, 4, "RelayFive")
local thirdDirect3 = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wthird", wallBase + 999, 999, 99, 900, 9, "Bob")
expect(thirdDirect1 == nil and thirdDirect2 == nil, "third-direct quorum accepted too early")
expect(thirdDirect3 and thirdDirect3.direct,
    "direct origin was blocked by ignored relays")
expect(thirdDirect3.hold == 999 and thirdDirect3.kills == 0
    and thirdDirect3.holdReq == nil and thirdDirect3.shard == 9,
    "direct origin did not apply deterministic field sanitization")

-- Trois transports du meme fait ne sont pas trois identites independantes.
local syntheticBNet = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wtransport", wallBase + 111, 10, 0, 120, nil, "BNet-42")
local syntheticBridge = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wtransport", wallBase + 111, 10, 0, 120, nil, "Bridge-43")
local transportDirect = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wtransport", wallBase + 111, 10, 0, 120, nil, "Bob")
expect(syntheticBNet == nil and syntheticBridge == nil
    and transportDirect and transportDirect.direct,
    "synthetic transports bypassed direct origin identity")

-- Une meme wave ne melange jamais les observations Alliance/Horde.
local mix1 = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wmixed", wallBase + 101, 10, 0, 120, nil, "MixOne")
local mix2 = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wmixed", wallBase + 101, 10, 0, 120, nil, "MixTwo")
local mix3 = Lease:ValidateProgress(
    zone.id, "Horde", "Alice", "wmixed", wallBase + 101, 10, 0, 120, nil, "MixThree")
expect(mix1 == nil and mix2 == nil and mix3 == nil, "owner observations were mixed")

-- Un ZR doit correspondre a la fois a l'origine et a la wave.
resetZone()
mono = 200
local releaseDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wrelease", wallBase + 200, 12, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", releaseDecision), "release lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
expect(not Lease:ReceiveRelease(zone.id .. ":wrelease:Bob", "Mallory"), "forged ZR accepted")
expect(zone.status == "in_progress", "forged ZR changed state")
expect(Lease:ReceiveRelease(zone.id .. ":wrelease:Bob", "Bob"), "valid ZR rejected")
expect(zone.status == "captured" and zone.owner == "Alliance", "valid ZR did not restore base")

-- Un ZR direct autorise immediatement le co-capteur local deja sur le disque
-- a reprendre avec une nouvelle generation, meme pendant le soft-TTL.
resetZone()
mono = 210
zone.owner = "Horde"
local coRelease = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wcorelease", wallBase + 210,
    12, 0, 120, nil, "Alice")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", coRelease),
    "co-capturer release lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
zone.holdTimeElapsed, zone.holdTimeRequired, zone.killsCurrent = 77, 500, 99
zone.isHolding = true
expect(Lease:IsFreshDirect(zone), "co-capturer release lease was not fresh/direct")
local sentBeforeCoRelease = #sent
expect(Lease:ReceiveRelease(zone.id .. ":wcorelease:Alice", "Alice"),
    "direct ZR did not hand off to the local co-capturer")
local coTakeoverWave = zone._localCaptureWaveId
expect(zone._remoteCaptureLease == nil and zone.holdAuthorityLocal == true
    and zone.isHolding == true, "ZR handoff did not install local authority")
expect(type(coTakeoverWave) == "string" and coTakeoverWave ~= ""
    and coTakeoverWave ~= "wcorelease", "ZR handoff reused the released generation")
expect(zone.status == "in_progress" and zone.owner == "Alliance"
    and zone.previousOwner == "Horde", "ZR handoff changed the assault base")
expect(zone.holdTimeElapsed == 0 and zone.holdTimeRequired == 120
    and zone.killsCurrent == 4 and zone._localCaptureBase
    and zone._localCaptureBase.owner == "Horde",
    "ZR handoff inherited remote gameplay values")
expect(zone.zsOfficialCapturerName == "LocalHero"
    and zone._zsOfficialCapturerSeenAt == mono,
    "ZR handoff did not elect the local capturer")
expect(#sent == sentBeforeCoRelease + 1 and sent[#sent] == "ZS",
    "ZR handoff did not publish exactly one fresh local state")
mono = 211
expect(Lease:ValidateProgress(zone.id, "Alliance", "Alice", "wcorelease",
    wallBase + 211, 13, 0, 120, nil, "Alice") == nil,
    "released remote generation was not tombstoned")
Lease:ClearLocal(zone)
zone.zsOfficialCapturerName, zone._zsOfficialCapturerSeenAt = nil, nil

-- Au login, un ZA global exact peut corriger le socle stale sous une vague
-- valide sans fermer l'orange. ZR restaure ensuite ce nouveau socle et le flag
-- brut reste en quarantaine tant que le snapshot global n'a pas fini son commit.
resetZone()
mono = 230
local loginDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wloginrebase", wallBase + 230, 8, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", loginDecision),
    "login rebase lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 8, wallBase + 230
zone._loginSyncUnconfirmed = true
zone._captureFinalUnattested = true
zone._captureFinalUnattestedOriginKey = "old"
zone._captureFinalUnattestedWaveId = "oldwave"
zone._captureFinalUnattestedAt = wallBase + 220
local loginLease = zone._remoteCaptureLease
expect(Lease:RebaseRemoteStableByZoneId(
    zone.id, "N", nil, wallBase + 225, 0), "login stable rebase rejected")
expect(zone._remoteCaptureLease == loginLease and zone.status == "in_progress"
    and zone.owner == "Horde" and zone._loginSyncUnconfirmed
    and not zone._captureFinalUnattested,
    "login rebase closed the live overlay or cleared authority quarantine")
local rebasedPersisted = Lease:GetPersistableView(zone)
expect(rebasedPersisted.status == "locked" and rebasedPersisted.owner == nil
    and rebasedPersisted.updatedAt == wallBase + 225,
    "login rebase did not replace only the persistable stable base")
expect(Lease:ReceiveRelease(zone.id .. ":wloginrebase:Bob", "Bob"),
    "rebased login release rejected")
expect(zone.status == "locked" and zone.owner == nil and zone._loginSyncUnconfirmed,
    "release did not restore the rebased base or cleared raw quarantine")

-- Le plan ZA global est prepare/valide avant le commit atomique. Une wave
-- encore legale conserve strictement son identite et son TTL.
resetZone()
mono = 240
local preserveDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wplanpreserve", wallBase + 240,
    9, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", preserveDecision),
    "preserve-plan lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 9, wallBase + 240
local preservedLease = zone._remoteCaptureLease
local preservedLastSeen = preservedLease.lastSeen
local preservePlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", wallBase - 50, wallBase - 50, "preserve")
expect(preservePlan and Lease:ValidateRemoteStablePlan(preservePlan),
    "legal preserve plan was not stable through the dry-run")
Lease:CommitRemoteStablePlan(preservePlan)
expect(zone._remoteCaptureLease == preservedLease
    and zone._remoteCaptureLease.lastSeen == preservedLastSeen
    and zone.status == "in_progress" and zone.owner == "Horde",
    "preserve plan renewed, replaced, or closed the legal wave")

-- Le builder ZA canonicalise un socle neutre sans horloge sur l'epoch campagne.
-- Le plan ne doit pas revalider les champs bruts N:0 et vetoer ce wire exact.
resetZone()
mono = 245
zone.status, zone.owner, zone.capturedTime, zone.updatedAt = "locked", nil, nil, 0
local neutralDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wplanneutral", wallBase + 245,
    9, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", neutralDecision),
    "neutral-plan lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", nil
local neutralLease = zone._remoteCaptureLease
expect(Lease:RemoteStableNeedsCanonicalRebase(
    zone, "N", nil, wallBase - 40, 0),
    "raw N:0 was not detected behind its canonical epoch wire")
local neutralPlan = Lease:PrepareRemoteStablePlan(
    zone.id, "N", nil, wallBase - 40, 0, "preserve")
expect(neutralPlan and Lease:ValidateRemoteStablePlan(neutralPlan),
    "canonical neutral epoch was rechecked against raw N:0 and vetoed")
Lease:CommitRemoteStablePlan(neutralPlan)
expect(zone._remoteCaptureLease == neutralLease and zone.status == "in_progress",
    "neutral preserve plan changed the live wave")
local neutralCleanupPlan = Lease:PrepareRemoteStablePlan(
    zone.id, "N", nil, wallBase - 40, 0, "cleanup")
expect(neutralCleanupPlan and Lease:ValidateRemoteStablePlan(neutralCleanupPlan),
    "global neutral cleanup plan failed validation")
Lease:CommitRemoteStablePlan(neutralCleanupPlan)
expect(zone._remoteCaptureLease == neutralLease
    and Lease:GetPersistableView(zone).updatedAt == wallBase - 40,
    "global cleanup did not canonicalize N:0 under the live wave")

-- Cas migration critique : owner A/H sans aucune horloge. Le login peut voter
-- epoch/epoch, mais ce socle doit etre reellement installe avant de lever le flag,
-- sinon ZR/expiration le rend a nouveau non serialisable hors quarantaine.
resetZone()
mono = 247
zone.status, zone.owner, zone.capturedTime, zone.updatedAt = "captured", "Alliance", nil, 0
local ownerClockDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wplanownerclock", wallBase + 247,
    9, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", ownerClockDecision),
    "owner-clock cleanup lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone._loginSyncUnconfirmed = true
local ownerEpoch = wallBase - 35
expect(Lease:RemoteStableNeedsCanonicalRebase(
    zone, "A", "Alliance", ownerEpoch, ownerEpoch),
    "owner clock0 was not detected behind its epoch/epoch login wire")
local ownerClockPlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", ownerEpoch, ownerEpoch, "cleanup")
expect(ownerClockPlan and Lease:ValidateRemoteStablePlan(ownerClockPlan),
    "exact G could not prepare owner-clock cleanup")
Lease:CommitRemoteStablePlan(ownerClockPlan)
local ownerClockView = Lease:GetPersistableView(zone)
expect(ownerClockView.owner == "Alliance" and ownerClockView.capturedTime == ownerEpoch
    and ownerClockView.updatedAt == ownerEpoch and zone._remoteCaptureLease,
    "exact G did not canonicalize owner clock0 without closing its wave")
zone._loginSyncUnconfirmed = nil
expect(Lease:ReceiveRelease(zone.id .. ":wplanownerclock:Bob", "Bob"),
    "owner-clock release was rejected after cleanup")
expect(zone.status == "captured" and zone.owner == "Alliance"
    and zone.capturedTime == ownerEpoch and zone.updatedAt == ownerEpoch,
    "ZR restored the non-serializable owner clock0 after global cleanup")

-- Un rebase legal remplace seulement le socle SavedVariables stale. La wave,
-- ses preuves et son TTL ne sont jamais regeneres.
resetZone()
mono = 250
zone.status, zone.owner, zone.capturedTime = "locked", nil, nil
zone.updatedAt = wallBase - 60
local plannedRebaseDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wplanrebase", wallBase + 250,
    10, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", plannedRebaseDecision),
    "rebase-plan lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 10, wallBase + 250
zone._loginSyncUnconfirmed = true
local plannedRebaseLease = zone._remoteCaptureLease
local plannedRebaseLastSeen = plannedRebaseLease.lastSeen
local rebasePlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", wallBase + 245, wallBase + 245, "rebase")
expect(rebasePlan and Lease:ValidateRemoteStablePlan(rebasePlan),
    "legal rebase plan was not stable through the dry-run")
Lease:CommitRemoteStablePlan(rebasePlan)
expect(zone._remoteCaptureLease == plannedRebaseLease
    and zone._remoteCaptureLease.lastSeen == plannedRebaseLastSeen
    and zone.status == "in_progress" and zone.owner == "Horde"
    and zone.previousOwner == "Alliance",
    "rebase plan renewed, replaced, or closed the legal wave")
local plannedRebasedView = Lease:GetPersistableView(zone)
expect(plannedRebasedView.status == "captured" and plannedRebasedView.owner == "Alliance"
    and plannedRebasedView.updatedAt == wallBase + 245,
    "rebase plan did not install the exact certified stable base")

-- Un ancien final uniquement visuel sous une nouvelle wave n'est pas un vrai
-- conflit de carte. Un G exact nettoie ce socle sans login, sans renouveler ni
-- fermer la tentative distante legitime.
resetZone()
mono = 255
local cleanupDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wplancleanup", wallBase + 255,
    10, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", cleanupDecision),
    "cleanup-plan lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 10, wallBase + 255
zone._captureFinalUnattested = true
zone._remoteCaptureLease.base.status = "captured"
zone._remoteCaptureLease.base.owner = "Horde"
zone._remoteCaptureLease.base.capturedTime = wallBase + 250
zone._remoteCaptureLease.base.updatedAt = wallBase + 250
zone._remoteCaptureLease.base._captureFinalUnattested = true
zone._remoteCaptureLease.base._captureFinalUnattestedOriginKey = "old"
zone._remoteCaptureLease.base._captureFinalUnattestedWaveId = "oldwave"
local cleanupLease = zone._remoteCaptureLease
local cleanupLastSeen = cleanupLease.lastSeen
expect(Lease:RemoteStableNeedsCanonicalRebase(
    zone, "A", "Alliance", wallBase - 50, wallBase - 50),
    "visual-final base divergence was not classified for cleanup")
local partialFinalPlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", wallBase - 50, wallBase - 50, "preserve")
expect(partialFinalPlan and Lease:ValidateRemoteStablePlan(partialFinalPlan),
    "a partial exact wire let raw visual-final fields veto the live wave")
Lease:CommitRemoteStablePlan(partialFinalPlan)
expect(cleanupLease.base.owner == "Horde"
    and cleanupLease.base._captureFinalUnattested,
    "partial preserve unexpectedly certified or rewrote the visual-final base")
local cleanupPlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", wallBase - 50, wallBase - 50, "cleanup")
expect(cleanupPlan and Lease:ValidateRemoteStablePlan(cleanupPlan),
    "certified cleanup plan required login or failed validation")
Lease:CommitRemoteStablePlan(cleanupPlan)
expect(zone._remoteCaptureLease == cleanupLease
    and cleanupLease.lastSeen == cleanupLastSeen and zone.status == "in_progress"
    and zone.owner == "Horde" and zone.previousOwner == "Alliance"
    and not zone._captureFinalUnattested
    and not cleanupLease.base._captureFinalUnattested,
    "cleanup plan closed/renewed the wave or retained the old visual final")

-- Si les prerequis du snapshot staged interdisent la capture, Sync choisit
-- close : le module restaure le socle, tombstone la wave, et n'emet rien.
resetZone()
mono = 260
local prereqCloseDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wprereqclose", wallBase + 260,
    11, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", prereqCloseDecision),
    "prerequisite-close lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 11, wallBase + 260
local sentBeforePrereqClose = #sent
local prereqClosePlan = Lease:PrepareRemoteStablePlan(
    zone.id, "A", "Alliance", wallBase - 50, wallBase - 50, "close")
expect(prereqClosePlan and Lease:ValidateRemoteStablePlan(prereqClosePlan),
    "prerequisite-close plan was not stable through the dry-run")
Lease:CommitRemoteStablePlan(prereqClosePlan)
expect(not zone._remoteCaptureLease and zone.status == "captured"
    and zone.owner == "Alliance" and #sent == sentBeforePrereqClose,
    "close plan did not restore the stable base locally and silently")
expect(Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wprereqclose", wallBase + 261,
    12, 0, 120, nil, "Bob") == nil,
    "closed prerequisite-invalid wave was not tombstoned")

-- Si le owner stable exact est deja l'attaquant, l'orange est obsolete. Le
-- rebase_close installe d'abord ce terminal certifie, puis ferme/tombstone la
-- tentative sans inventer de capture locale ni de recompense.
resetZone()
mono = 270
local ownerCloseDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wownerclose", wallBase + 270,
    12, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", ownerCloseDecision),
    "owner-close lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed, zone.updatedAt = 12, wallBase + 270
zone._loginSyncUnconfirmed = true
local sentBeforeOwnerClose = #sent
local consumedBeforeOwnerClose = consumed
local ownerClosePlan = Lease:PrepareRemoteStablePlan(
    zone.id, "H", "Horde", wallBase + 265, wallBase + 265, "rebase_close")
expect(ownerClosePlan and Lease:ValidateRemoteStablePlan(ownerClosePlan),
    "owner-close plan was not stable through the dry-run")
Lease:CommitRemoteStablePlan(ownerClosePlan)
expect(not zone._remoteCaptureLease and zone.status == "captured"
    and zone.owner == "Horde" and zone.capturedTime == wallBase + 265
    and #sent == sentBeforeOwnerClose and consumed == consumedBeforeOwnerClose,
    "rebase_close did not install the terminal silently or leaked a reward")
expect(Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wownerclose", wallBase + 271,
    13, 0, 120, nil, "Bob") == nil,
    "owner-completed wave was not tombstoned")

-- Une Barricade exige une position exacte puis un ack ZS 180 du capteur. La
-- proposition seule n'est pas une consommation irreversible.
resetZone()
mono = 300
physicalEnabled, physicalName, physicalFaction = true, "Bob", "Horde"
local barricadeDecision = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wbarricade", wallBase + 300, 15, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", barricadeDecision), "barricade lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
expect(not Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", barricadeDecision, false),
    "single direct packet consumed Barricade")
expect(consumed == 0, "Barricade consumption counter changed without corroboration")
barricadeActive = false
expect(not Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", barricadeDecision, true),
    "inactive Barricade was consumed")
barricadeActive = true
zone.holdTimeRequired = 30
local sentBeforeBarrier = #sent
expect(not Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", barricadeDecision, true),
    "Barricade was consumed before capper ack")
expect(consumed == 0 and #sent == sentBeforeBarrier + 1,
    "Barricade proposal was not emitted without consumption")
mono = 305
local barrierAck = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wbarricade", time(), 20, 0, 180, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", barrierAck), "Barricade ack was rejected")
zone._remoteCaptureLease.barrierAcknowledged = true -- simule le CB A lie au defenseur selectionne
expect(Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", barrierAck, true),
    "acknowledged Barricade was not consumed")
expect(consumed == 1, "Barricade consumption was not one-shot")
expect(zone.holdTimeRequired == 180,
    "Barricade increase started from an untrusted wire requirement")

-- Une Barricade vue trop tard ne depense rien et ne modifie pas le contrat.
resetZone()
mono = 330
local lateBarrier = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wlatebarrier", time(), 25, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", lateBarrier), "late wave missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
local consumedBeforeLate = consumed
expect(not Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", lateBarrier, true), "late Barricade was proposed")
expect(consumed == consumedBeforeLate and zone.holdTimeRequired == 120,
    "late Barricade consumed or changed the timer")
physicalEnabled = false

-- Un quorum ancien ne blanchit jamais les valeurs directes suivantes.
resetZone()
mono = 350
Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wsticky", wallBase + 350, 20, 0, 120, nil, "RelaySix")
Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wsticky", wallBase + 350, 20, 0, 120, nil, "RelaySeven")
local stickyOrigin = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wsticky", wallBase + 350, 20, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", stickyOrigin), "direct sticky lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
mono = 351
local stickyDirect = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wsticky", wallBase + 351, 21, 0, 120, nil, "Bob")
expect(stickyDirect and stickyDirect.direct, "fresh direct value rejected")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", stickyDirect), "fresh direct value rejected")
local consumedBeforeSticky = consumed
expect(not Lease:MaybeConsumeBarricade(
    zone, "Horde", "Bob", stickyDirect, false),
    "ignored relays authorized a new irreversible value")
expect(consumed == consumedBeforeSticky, "ignored relays consumed Barricade")

-- Apres le soft-TTL, prendre localement la releve d'un overlay non corrobore
-- restaure la base et demarre une vraie tentative locale, sans heriter les
-- timer/kills/requis injectes. Un bail direct encore frais reste protege.
resetZone()
mono = 380
zone.owner = "Horde"
local untrustedTakeover = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wtakeover", wallBase + 380, 80, 99, 500, nil, "Alice")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", untrustedTakeover),
    "untrusted takeover lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
zone.holdTimeElapsed, zone.holdTimeRequired, zone.killsCurrent = 80, 500, 99
expect(Lease:PromoteRemoteToLocal(zone) == nil,
    "a fresh direct lease allowed an unauthenticated local takeover")
mono = 400
local takeoverWave = Lease:PromoteRemoteToLocal(zone)
expect(takeoverWave and zone.status == "in_progress" and zone.owner == "Alliance"
    and zone.previousOwner == "Horde", "takeover did not start a fresh local attempt")
expect(zone.holdTimeElapsed == 0 and zone.holdTimeRequired == 120 and zone.killsCurrent == 4,
    "takeover inherited uncorroborated gameplay values")
expect(zone._localCaptureBase and zone._localCaptureBase.owner == "Horde",
    "takeover lost its confirmed base")

-- La fin locale tombstone sa generation : un relais tardif ne la ressuscite pas.
Lease:ClearLocal(zone)
mono = 401
local lateLocal = Lease:ValidateProgress(
    zone.id, "Alliance", "LocalHero", takeoverWave, wallBase + 401, 1, 0, 120, nil, "LocalHero")
expect(lateLocal == nil, "cleared local wave was not tombstoned")

-- Kills/requis corroborés restent sûrs, mais un hold ancien ne survit jamais a
-- un tick direct non corrobore : il a pu reculer pendant une contestation.
resetZone()
mono = 410
zone.owner = "Horde"
Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wtrusted", wallBase + 410, 70, 7, 180, nil, "WitnessOne")
Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wtrusted", wallBase + 410, 65, 6, 180, nil, "WitnessTwo")
local trustedOrigin = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wtrusted", wallBase + 410, 60, 5, 180, nil, "Alice")
expect(trustedOrigin and trustedOrigin.direct, "direct takeover origin missing")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", trustedOrigin),
    "direct takeover lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
zone.holdTimeElapsed, zone.holdTimeRequired, zone.killsCurrent = 60, 180, 5
mono = 411
local laterUntrusted = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wtrusted", wallBase + 411, 65, 99, 30, nil, "Alice")
expect(laterUntrusted and laterUntrusted.direct
    and laterUntrusted.kills == 0 and laterUntrusted.holdReq == nil,
    "later direct tick did not retain normalized fields")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", laterUntrusted),
    "later direct tick was rejected")
zone.holdTimeElapsed = 65
expect(Lease:PromoteRemoteToLocal(zone) == nil,
    "a fresh direct tick allowed an unauthenticated local takeover")
mono = 431
Lease:PromoteRemoteToLocal(zone)
expect(zone.holdTimeElapsed == 0 and zone.killsCurrent == 4
    and zone.holdTimeRequired == 120,
    "takeover reused network hold/kills/requirement")
Lease:ClearLocal(zone)

-- Un autre capteur ne peut pas evincer un bail frais sur un simple restart a 0.
-- Si le ZR a ete rate, le handoff direct devient possible apres le soft-TTL.
resetZone()
mono = 440
local incumbent = Lease:ValidateProgress(
    zone.id, "Horde", "Bob", "wfresh", wallBase + 440, 50, 0, 120, nil, "Bob")
expect(Lease:AdoptRemote(zone, "Horde", "Bob", incumbent), "incumbent lease missing")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Horde", "Alliance"
zone.holdTimeElapsed = 50
mono = 441
local freshEviction = Lease:ValidateProgress(
    zone.id, "Horde", "Charlie", "wfresh2", wallBase + 441, 0, 0, 120, nil, "Charlie")
expect(not Lease:AdoptRemote(zone, "Horde", "Charlie", freshEviction),
    "fresh lease was evicted by another direct origin")
mono = 461
local softHandoff = Lease:ValidateProgress(
    zone.id, "Horde", "Charlie", "wfresh2", wallBase + 461, 51, 0, 120, nil, "Charlie")
expect(Lease:AdoptRemote(zone, "Horde", "Charlie", softHandoff),
    "soft-expired direct handoff was rejected")

-- Une finale directe terminee rend sa vague non rejouable sans vote temoin.
resetZone()
physicalEnabled = true
physicalName, physicalFaction = "Alice", "Alliance"
zone.owner = "Horde"
local witnessedWave = "wwitnessed"
mono = 500
local directSample = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", witnessedWave, time(), 0, 0, 120,
    nil, "Alice")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", directSample),
    "direct wave was rejected")
expect(Lease:TombstoneFinalWave(zone.id, "Alice", witnessedWave),
    "final wave could not be tombstoned")
expect(Lease:ShouldRejectFinal(zone, "Alice", witnessedWave),
    "tombstoned final replay was accepted")

-- Une exigence locale prolongee (Barricade) survit a la finale directe : le dernier
-- sample et la duree observee doivent eux aussi approcher 180.
resetZone()
mono = 800
zone._remoteCaptureLease = {
    owner = "Alliance", originKey = "alice", waveId = "wrequired",
    localRequired = 180, lastHold = 110, openedAt = 800, openedHold = 0,
}
expect(not Lease:FinalSatisfiesLocalRequirement(
    zone, "Alliance", "Alice", "wrequired", 180),
    "local 180 requirement accepted a terminal at 120")
mono = 970
zone._remoteCaptureLease.lastHold = 170
expect(Lease:FinalSatisfiesLocalRequirement(
    zone, "Alliance", "Alice", "wrequired", 180),
    "mature local 180 requirement rejected the terminal")
zone.holdAuthorityLocal = true
zone._localCaptureWaveId = "wlocal"
expect(Lease:ShouldRejectFinal(zone, "Alice", "wforeign"),
    "foreign final overwrote local physical authority")
zone._remoteCaptureLease = nil
zone.holdAuthorityLocal = nil
zone._localCaptureWaveId = nil
physicalEnabled = false

-- Un temoin designe peut etre hors du front : le GUID/wave/requis et la duree
-- sont lies aux heartbeats directs, sans jamais fabriquer une preuve physique.
resetZone()
zone.owner = "Horde"
local networkWave = "wnetwork"
mono = 1199
local wrongNetworkSlot = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", networkWave, time(), 0, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W2", "a1b2c3d4")
expect(wrongNetworkSlot and wrongNetworkSlot.direct
    and not wrongNetworkSlot.networkDesignated,
    "a receiver accepted a W slot that did not match its deterministic rank")
for hold = 0, 120, 15 do
    mono = 1200 + hold
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", networkWave, time(), hold, 0, 120,
        nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d4")
    expect(sample and sample.direct and sample.networkDesignated
        and sample.networkOriginGuid == "Player-1-ALICE"
        and sample.networkWitnessSlot == 1
        and sample.networkWitnessPeer == "WitnessTwo"
        and sample.networkWitnessRouteSize == 2
        and sample.networkWitnessBaseline == 0
        and sample.networkWitnessPredecessorKey == "witnesstwo"
        and sample.networkWitnessSuccessorKey == "witnesstwo",
        "designated remote heartbeat did not derive and bind the frozen ring")
    expect(Lease:AdoptRemote(zone, "Alliance", "Alice", sample),
        "designated remote heartbeat was rejected")
    zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
    zone.holdTimeElapsed, zone.updatedAt = hold, time()
end
expect(zone._remoteCaptureLease.networkProof ~= nil,
    "complete designated network progress was not retained")

-- Le ZS large peut arriver avant son W de meme version. Le W ouvre quand meme
-- la preuve, un paquet ordinaire ne la casse pas, une perte et une livraison en
-- rafale restent valides, et le final n'exige pas un artificiel sample hold=120.
resetZone()
zone.owner = "Horde"
local delayedWave = "wdelayednetwork"
mono = 2000
local broadStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", delayedWave, wallBase + 2000, 0, 0, 120,
    nil, "Alice", "Player-1-ALICE")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", broadStart),
    "ordinary opening heartbeat was rejected")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
mono = 2001
local markedStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", delayedWave, wallBase + 2000, 0, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d5")
expect(Lease:ObserveNetworkProgress(zone, "Alliance", markedStart),
    "same-version W did not open its independent proof")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", markedStart),
    "same-version W was not accepted idempotently")

mono = 2016
local marked15 = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", delayedWave, wallBase + 2015, 15, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d5")
Lease:ObserveNetworkProgress(zone, "Alliance", marked15)
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", marked15),
    "second W was rejected")

-- Un ZS non marque plus recent ne doit pas effacer le GUID/slot W.
mono = 2031
local broad30 = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", delayedWave, wallBase + 2030, 30, 0, 120,
    nil, "Alice")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", broad30),
    "ordinary progress update was rejected")
expect(zone._remoteCaptureLease.networkProof
    and zone._remoteCaptureLease.networkProof.peerName == "WitnessTwo",
    "ordinary ZS or peer omission destroyed network routing proof")

-- W30 a ete retarde jusqu'a W45 : gap de 30 s puis deux callbacks meme frame.
mono = 2046
for _, row in ipairs({ { 2030, 30 }, { 2045, 45 } }) do
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", delayedWave, wallBase + row[1], row[2], 0, 120,
        nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d5")
    expect(Lease:ObserveNetworkProgress(zone, "Alliance", sample),
        "delayed/batched W did not advance its proof")
    Lease:AdoptRemote(zone, "Alliance", "Alice", sample)
end
for _, row in ipairs({ { 2061, 2060, 60 }, { 2076, 2075, 75 },
    { 2091, 2090, 90 }, { 2106, 2105, 105 } }) do
    mono = row[1]
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", delayedWave, wallBase + row[2], row[3], 0, 120,
        nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d5")
    Lease:ObserveNetworkProgress(zone, "Alliance", sample)
    Lease:AdoptRemote(zone, "Alliance", "Alice", sample)
end
mono = 2121
expect(zone._remoteCaptureLease.networkProof
    and zone._remoteCaptureLease.networkProof.lastHold >= 105,
    "one missed W discarded otherwise valid progress evidence")

-- Si seul le retry d'ouverture du dernier slot arrive (+1 s + jitter 0,24),
-- le C synchrone peut preceder le W final sans effacer une preuve quasi mature.
resetZone()
zone.owner = "Horde"
local retryWave = "wopeningretry"
mono = 2601.24
local retryStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", retryWave, wallBase + 2600, 0, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W3", "a1b2c3d6")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", retryStart),
    "opening retry could not start network proof")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
for hold = 15, 105, 15 do
    mono = 2600 + hold
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", retryWave, wallBase + 2600 + hold,
        hold, 0, 120, nil, "Alice", "Player-1-ALICE", "W3", "a1b2c3d6")
    Lease:AdoptRemote(zone, "Alliance", "Alice", sample)
end
mono = 2720
expect(zone._remoteCaptureLease.networkProof ~= nil,
    "opening retry jitter lost the targeted progress evidence")

-- Une Barricade force un W 120->180 avec retry. La preuve conserve le contrat
-- augmente puis exige bien les 180 secondes completes.
resetZone()
zone.owner = "Horde"
local barrierWave = "wnetworkbarrier"
for _, row in ipairs({ { 2800, 2800, 0, 120 }, { 2815, 2815, 15, 120 },
    { 2820, 2820, 20, 180 }, { 2845, 2845, 45, 180 },
    { 2860, 2860, 60, 180 }, { 2875, 2875, 75, 180 },
    { 2890, 2890, 90, 180 }, { 2905, 2905, 105, 180 },
    { 2920, 2920, 120, 180 }, { 2935, 2935, 135, 180 },
    { 2950, 2950, 150, 180 }, { 2965, 2965, 165, 180 } }) do
    mono = row[1]
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", barrierWave, wallBase + row[2], row[3], 0,
        row[4], nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d7")
    expect(Lease:AdoptRemote(zone, "Alliance", "Alice", sample),
        "network Barricade heartbeat was rejected")
    zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
end
mono = 2980
expect(zone._remoteCaptureLease.networkProof
    and zone._remoteCaptureLease.networkProof.required == 180,
    "retried 120->180 network contract was not retained")

-- Un Renfort a 60 s reste certifiable avec seulement l'ouverture et un second
-- sample : la duree totale vient de l'horloge locale, pas d'un compteur de paquets.
resetZone()
zone.owner = "Horde"
mono = 3200
local shortWave = "wshortnetwork"
local shortStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", shortWave, wallBase + 3200, 0, 0, 60,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3da")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", shortStart),
    "short network proof did not start")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
mono = 3245
local shortLate = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", shortWave, wallBase + 3245, 45, 0, 60,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3da")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", shortLate),
    "short network proof did not accept its second sample")
mono = 3260
expect(zone._remoteCaptureLease.networkProof
    and zone._remoteCaptureLease.networkProof.lastHold == 45,
    "60 second progress evidence required an impossible third heartbeat")

-- Le deuxieme round Q/NR peut retarder le premier W d'environ six secondes.
-- Le chrono part de la sonde locale deja validee, pas de la fin de negociation.
resetZone()
zone.owner = "Horde"
local secondRoundWave = "wsecondround"
mono = 4006
local secondRoundStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", secondRoundWave, wallBase + 4000, 0, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3db")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", secondRoundStart),
    "second-round negotiation could not start the network proof")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
for hold = 15, 105, 15 do
    mono = 4000 + hold
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", secondRoundWave, wallBase + 4000 + hold,
        hold, 0, 120, nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3db")
    Lease:AdoptRemote(zone, "Alliance", "Alice", sample)
end
mono = 4120
expect(zone._remoteCaptureLease.networkProof ~= nil,
    "probe negotiation time discarded the progress evidence")

-- Deux heartbeats consecutifs absents (45 s) restent toleres ; un trou de
-- transport strictement superieur a 50 s ferme la preuve.
resetZone()
zone.owner = "Horde"
mono = 2400
local gapStart = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wlonggap", wallBase + 2400, 0, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d8")
expect(Lease:AdoptRemote(zone, "Alliance", "Alice", gapStart),
    "long-gap proof did not start")
zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
mono = 2445
local toleratedGap = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wlonggap", wallBase + 2445, 45, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d8")
Lease:AdoptRemote(zone, "Alliance", "Alice", toleratedGap)
expect(zone._remoteCaptureLease.networkProof ~= nil,
    "two missed 15 second heartbeats destroyed network proof")
mono = 2496
local gapEnd = Lease:ValidateProgress(
    zone.id, "Alliance", "Alice", "wlonggap", wallBase + 2496, 90, 0, 120,
    nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d8")
Lease:AdoptRemote(zone, "Alliance", "Alice", gapEnd)
expect(zone._remoteCaptureLease.networkProof == nil,
    "a gap over 50 seconds retained network proof")

-- Sans marquage W, la meme observation reste seulement visuelle.
resetZone()
zone.owner = "Horde"
for hold = 0, 120, 15 do
    mono = 1400 + hold
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", "wundesigned", time(), hold, 0, 120,
        nil, "Alice", "Player-1-ALICE")
    expect(Lease:AdoptRemote(zone, "Alliance", "Alice", sample),
        "ordinary visual heartbeat was rejected")
    zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
end
expect(zone._remoteCaptureLease.networkProof == nil,
    "an undesignated observer opened network progress evidence")

-- Une progression acceleree ou un trou de transport invalide toute la preuve.
resetZone()
zone.owner = "Horde"
for _, row in ipairs({ { 1600, 0 }, { 1605, 50 }, { 1615, 60 }, { 1625, 70 } }) do
    mono = row[1]
    local sample = Lease:ValidateProgress(
        zone.id, "Alliance", "Alice", "wfastnetwork", time(), row[2], 0, 120,
        nil, "Alice", "Player-1-ALICE", "W1", "a1b2c3d9")
    expect(Lease:AdoptRemote(zone, "Alliance", "Alice", sample),
        "accelerated visual heartbeat was not adopted")
    zone.status, zone.owner, zone.previousOwner = "in_progress", "Alliance", "Horde"
end
expect(zone._remoteCaptureLease.networkProof == nil,
    "accelerated network progress retained trusted evidence")

-- Un terminal oublie le snapshot : une expiration tardive ne peut pas le reverter.
zone.status, zone.owner, zone.capturedTime = "captured", "Horde", wallBase + 300
Lease:Complete(zone)
mono = 1000
expect(not Lease:MaybeExpire(zone), "completed lease still expired")
expect(zone.status == "captured" and zone.owner == "Horde", "completed capture reverted")

-- La capture locale emet un ZR idempotent avec un identifiant stable.
resetZone()
mono = 1100
local localWave = Lease:BeginLocal(zone)
zone.holdAuthorityLocal = true
expect(type(localWave) == "string" and localWave ~= "", "local wave missing")
local beforeRelease = #sent
expect(Lease:BroadcastLocalRelease(zone), "local ZR not sent")
expect(#sent > beforeRelease and string.find(sent[beforeRelease + 1], "ZR:", 1, true) == 1,
    "local release payload missing")
expect(not Lease:BroadcastLocalRelease(zone), "local ZR was not idempotent")

-- Une barriere login doit pouvoir conserver le ZR immutable meme si la
-- suspension nettoie ensuite la vague locale avant que Sync soit disponible.
resetZone()
mono = 1105
local deferredWave = Lease:BeginLocal(zone)
zone.holdAuthorityLocal = true
local deferredSnapshot = Lease:SnapshotLocalRelease(zone)
expect(deferredSnapshot and deferredSnapshot.waveId == deferredWave,
    "local release snapshot did not retain the wave")
local oldSend, oldChannel, oldCommunity = Overlord.Sync.Send,
    Overlord.Sync.SendToChannel, Overlord.Sync.BroadcastToCommunity
Overlord.Sync.Send = function() return false end
Overlord.Sync.SendToChannel = function() return false end
Overlord.Sync.BroadcastToCommunity = function() return false end
expect(not Lease:BroadcastReleaseSnapshot(deferredSnapshot)
    and zone._captureReleaseSentWave == nil,
    "failed release transport tombstoned the local wave")
zone._localCaptureWaveId = nil
zone.holdAuthorityLocal = false
Overlord.Sync.Send, Overlord.Sync.SendToChannel, Overlord.Sync.BroadcastToCommunity =
    oldSend, oldChannel, oldCommunity
local deferredBefore = #sent
expect(Lease:BroadcastReleaseSnapshot(deferredSnapshot),
    "immutable release snapshot was not replayed after cleanup")
expect(#sent > deferredBefore
    and sent[deferredBefore + 1] == "ZR:" .. deferredSnapshot.payload,
    "deferred release replay changed its exact payload")
resetZone()
mono = 1110
Lease:BeginLocal(zone)
zone.holdAuthorityLocal = true
expect(Lease:BroadcastLocalRelease(zone), "local ZR setup for rotation failed")

-- Un loading hors instance conserve la capture, mais tourne la generation que
-- les observateurs viennent de tombstone via ZR.
local releasedWave = zone._localCaptureWaveId
local sentBeforeRotate = #sent
Lease:RotateReleasedLocalWaves()
expect(zone._localCaptureWaveId and zone._localCaptureWaveId ~= releasedWave,
    "released local wave was not rotated")
expect(zone._captureReleaseSentWave == nil and #sent == sentBeforeRotate + 1,
    "rotated local wave was not rebroadcast")
expect(Lease:ValidateProgress(
    zone.id, "Alliance", "LocalHero", releasedWave, wallBase + 1100,
    10, 0, 120, nil, "LocalHero") == nil,
    "rotated local wave was not tombstoned")

print("zone_capture_lease: ok")
