import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");

test("Forever uses no community: channel + Battle.net relay only", () => {
    const core = read("Core.lua");
    const pools = read("RealmPools.lua");
    const sync = read("Sync.lua");
    const beta = read("SyncBetaNetwork.lua");

    assert.match(core, /^Overlord\.CommunityModeEnabled = false$/m);
    // Presence comes from the relay heartbeat only, never from a community scan.
    const scan = sync.slice(sync.indexOf("function Overlord.Sync:ScanCommunityMembers("));
    assert.doesNotMatch(scan.slice(0, scan.indexOf("\nend")), /Broadcast\("NH"/);
    assert.match(core, /^Overlord\.BetaNetworkEnabled = true$/m);
    assert.match(sync, /global\s*=\s*\{\s*"0m7kdXcnvR"\s*\}/);
    assert.match(pools, /function RealmPools:GetOverlordPoolTag\(\)[\s\S]*?return "global"/);
    assert.match(beta, /addon\.BetaNetworkEnabled ~= false/);
    assert.match(beta, /NormalizeRegionPool\(pool\)/);
});

test("Fortresses share the Outpost engine without loading siege controllers", () => {
    const toc = read("Overlord.toc");
    assert.match(toc, /^GuildKeepSites\.lua$/m);
    assert.match(toc, /^OutpostControl\.lua$/m);
    assert.doesNotMatch(toc, /GuildKeepControl|GuildKeepImmersion|SyncGuildKeep/);
    assert.doesNotMatch(read("GuildKeep.lua"), /SIEGE_INTERVAL|SiegeWindow|DailyProof/);
});
