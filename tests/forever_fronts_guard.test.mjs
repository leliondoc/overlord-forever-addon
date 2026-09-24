import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const fronts = readFileSync(new URL("../Fronts.lua", import.meta.url), "utf8");
const toc = readFileSync(new URL("../Overlord.toc", import.meta.url), "utf8");
const outpost = readFileSync(new URL("../Outpost.lua", import.meta.url), "utf8");

test("Forever fronts: seven Classic map campaigns", () => {
    assert.match(fronts, /Overlord\.Fronts\.Order = \{"arathi", "loch_modan", "durotar", "ashenvale", "elwynn", "redridge", "hillsbrad"\}/);
    assert.match(fronts, /activeFrontId = "arathi"/);
    assert.match(fronts, /Zone\("stromgarde"/);
    assert.match(fronts, /center = \{25\.38, 58\.36\}/);
    assert.match(fronts, /id = "ashenvale"/);
    assert.match(
        fronts,
        /ashenvale = "Interface\\\\QuestionFrame\\\\Answer-WarBoard-Classic-Ashenvale\.blp"/,
    );
    assert.doesNotMatch(fronts, /Achievement_Zone_Ashenvale/);
    assert.match(fronts, /id = "elwynn"/);
    assert.match(fronts, /id = "redridge"/);
    assert.match(fronts, /Zone\("redridge_lakeshire", \{ center = \{25\.0, 43\.0\}/);
    assert.match(fronts, /Zone\("redridge_stonewatch_falls", \{ center = \{75\.0, 67\.0\}/);
    assert.match(fronts, /id = "hillsbrad"/);
    assert.match(fronts, /Zone\("hillsbrad_southshore", \{ center = \{51\.2, 58\.0\}, radius = 15/);
    assert.match(fronts, /Zone\("hillsbrad_tarren_mill", \{ center = \{61\.8, 19\.0\}, radius = 15/);
    assert.doesNotMatch(fronts, /id = "gilneas"/);
    assert.doesNotMatch(fronts, /id = "southern_barrens"/);
});

test("TOC Forever 16001 and CurseForge 1701204", () => {
    assert.match(toc, /^## Interface: 16001$/m);
    assert.match(toc, /^## X-Curse-Project-ID: 1701204$/m);
    assert.match(toc, /HallOfFameData\.lua/);
    assert.match(toc, /HallOfFameUI\.lua/);
    assert.doesNotMatch(toc, /HallOfFameLifetime\.lua/);
    assert.doesNotMatch(toc, /^Bounty\.lua$|^Export\.lua$/m);
    for (const module of ["General", "GeneralSync", "GeneralMap", "GeneralNameplate",
        "ManualBounty", "ManualBountySync", "ManualBountyMail", "ManualBountyMap", "ManualBountyUI"]) {
        assert.ok(toc.split(/\r?\n/).includes(`${module}.lua`), `${module} is not loaded`);
    }
    const hof = readFileSync(new URL("../HallOfFameData.lua", import.meta.url), "utf8");
    const hofUi = readFileSync(new URL("../HallOfFameUI.lua", import.meta.url), "utf8");
    assert.match(hof, /id = "donors"/);
    assert.match(hof, /Overlord\.DonorHonorEntries/);
    assert.doesNotMatch(hof, /PlayerHonorEntries|GuildHonorSites|HOF_CAT_GUILD|HOF_CAT_LIFETIME/);
    assert.match(hofUi, /local selectedCategory = "donors"/);
});

test("Outposts cover six fronts and two open-world lodges", () => {
    assert.match(outpost, /frontId = "arathi"/);
    assert.match(outpost, /center = \{ 33\.3, 27\.8 \}/);
    assert.match(outpost, /loch_modan = \{[\s\S]*?center = \{ 40\.3, 39\.4 \}/);
    assert.match(outpost, /center = \{ 47\.8, 49\.6 \}/);
    assert.match(outpost, /center = \{ 29\.0, 32\.0 \}/);
    assert.match(outpost, /frontId = "ashenvale"/);
    assert.match(outpost, /frontId = "elwynn"/);
    assert.match(outpost, /frontId = "redridge"/);
    assert.doesNotMatch(outpost, /frontId = "hillsbrad"/);
    assert.match(outpost, /aeythyr_lodge = \{[\s\S]*?center = \{ 52\.1, 18\.4 \}/);
    assert.doesNotMatch(outpost, /coiled_isle/);
    assert.doesNotMatch(outpost, /11\.2, 70\.5/);
});

test("Forever identity is Prenom Nom with no realm suffix", () => {
    const sync = readFileSync(new URL("../Sync.lua", import.meta.url), "utf8");
    const aux = readFileSync(new URL("../SyncAux.lua", import.meta.url), "utf8");
    const catchup = readFileSync(new URL("../SyncHistoryCatchup.lua", import.meta.url), "utf8");
    assert.match(sync, /function Overlord\.Sync:IsForeverCharacterName/);
    assert.match(sync, /function Overlord\.Sync:CanonicalForeverName/);
    assert.match(sync, /function Overlord\.Sync:HasCompleteContributorIdentity/);
    assert.match(sync, /cachedPlayerFullName = canon/);
    assert.match(sync, /return "Forever_" \.\. Overlord\.RealmPools:GetOverlordPoolTag\(\)/);
    assert.match(sync, /local canon = self:CanonicalForeverName\(name\)/);
    assert.doesNotMatch(sync, /local localRealm = Overlord:SafeGetRealmName\(\)/);
    assert.match(sync, /info\.name:find\("overlord", 1, true\)/);
    assert.doesNotMatch(
        sync,
        /info\.name:find\("overlord"\) and info\.name:find\("forever"\)/,
    );
    assert.match(aux, /sync:CanonicalForeverName\(memberName\)/);
    assert.doesNotMatch(aux, /memberName \.\. "-" \.\. guidMeta\.realm/);
    assert.match(catchup, /HasCompleteContributorIdentity/);
});

test("Guild keeps use vanilla map IDs and land coords", () => {
    const keep = readFileSync(new URL("../GuildKeep.lua", import.meta.url), "utf8");
    assert.match(keep, /mapID = 1413/);
    assert.match(keep, /mapID = 1437/);
    assert.match(keep, /center = \{ 10\.6, 59\.6 \}/);
    assert.match(keep, /center = \{ 51\.5, 30\.2 \}/);
    assert.doesNotMatch(keep, /center = \{ 21\.4, 68\.0 \}/);
    assert.doesNotMatch(keep, /center = \{ 49\.2, 58\.8 \}/);
});

test("Forever capture and kill senders use complete identities", () => {
    const aux = readFileSync(new URL("../SyncAux.lua", import.meta.url), "utf8");
    const core = readFileSync(new URL("../Core.lua", import.meta.url), "utf8");
    const sync = readFileSync(new URL("../Sync.lua", import.meta.url), "utf8");
    assert.match(aux, /function Overlord\.Sync:ForeverIdentitiesMatch/);
    assert.match(aux, /return self:ForeverIdentitiesMatch\(contributor, sender\)/);
    assert.match(aux, /return self:ForeverIdentitiesMatch\(sender, playerName\)/);
});

test("Forever panel greys disabled modules", () => {
    const ui = readFileSync(new URL("../UI.lua", import.meta.url), "utf8");
    const locales = readFileSync(new URL("../Locales.lua", import.meta.url), "utf8");
    assert.match(ui, /SetWC3ButtonUnavailable\(exportBtn/);
    assert.match(ui, /SetWC3ButtonUnavailable\(hofBtn/);
    assert.match(ui, /SetWC3ButtonUnavailable\(mbBtn/);
    assert.match(ui, /SetWC3ButtonUnavailable\(generalBtn/);
    assert.match(ui, /not Overlord\.Export/);
    assert.match(ui, /not Overlord\.HallOfFameUI/);
    assert.match(ui, /not Overlord\.ManualBountyUI/);
    assert.match(ui, /not Overlord\.General/);
    assert.match(locales, /L\.FOREVER_FEATURE_UNAVAILABLE = "Unavailable on Overlord Forever\."/);
    assert.match(locales, /L\.FOREVER_FEATURE_UNAVAILABLE = "Indisponible sur Overlord Forever\."/);
});

test("One-shot popups are marked seen when shown", () => {
    const popups = readFileSync(new URL("../Popups.lua", import.meta.url), "utf8");
    const core = readFileSync(new URL("../Core.lua", import.meta.url), "utf8");
    assert.match(popups, /forever_launch_1_0_0/);
    assert.match(popups, /welcome_first_install/);
    assert.match(popups, /function Overlord\.Popups:CommitPendingPopupMark/);
    assert.match(popups, /self:CommitPendingPopupMark\(\)/);
    assert.match(popups, /popupsSeen\[id\] = true/);
    assert.match(popups, /seen\[id\]\) then return true/);
    assert.match(popups, /v == true or v == 1/);
    assert.doesNotMatch(popups, /if not ACTIVE_ONE_SHOT_POPUP_IDS\[id\] then/);
    assert.match(core, /Overlord\.Popups:CommitPendingPopupMark\(\)/);
    assert.match(core, /Overlord\.Popups:PersistSeenFlags\(\)/);
});

test("Domination credits a local capture and solo ticks", () => {
    const core = readFileSync(new URL("../Core.lua", import.meta.url), "utf8");
    const aux = readFileSync(new URL("../SyncAux.lua", import.meta.url), "utf8");
    const zc = readFileSync(new URL("../ZoneControl.lua", import.meta.url), "utf8");
    assert.match(core, /IsLoginZoneDisplayPending\(state\)/);
    assert.match(core, /function Overlord:NotifyDominationOwnersChanged/);
    assert.match(core, /bucketEmpty/);
    assert.match(aux, /Solo = groupe de 1/);
    const zones = readFileSync(new URL("../Zones.lua", import.meta.url), "utf8");
    const popups = readFileSync(new URL("../Popups.lua", import.meta.url), "utf8");
    assert.match(popups, /v == true or v == 1/);
});

test("Forever region catalogs contain no realm classification", () => {
    const pools = readFileSync(new URL("../RealmPools.lua", import.meta.url), "utf8");
    assert.match(pools, /function RealmPools:NormalizeRegionPool/);
    assert.doesNotMatch(pools, /RealmPools\.(FR|DE|RP)\s*=/);
    assert.doesNotMatch(pools, /GetNormalizedRealmName|GetAutoCompleteRealms/);
});
