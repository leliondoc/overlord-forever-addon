import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");

test("Forever uses no community: channel + Battle.net relay only", () => {
    const core = read("Core.lua");
    const pools = read("RealmPools.lua");
    const sync = read("Sync.lua");
    const beta = read("SyncRelay.lua");

    // 1.4.2: the community transport is removed, not just switched off. Presence
    // comes from the relay heartbeat only.
    for (const [name, src] of [["Core.lua", core], ["Sync.lua", sync], ["SyncRelay.lua", beta],
        ["SyncAux.lua", read("SyncAux.lua")]]) {
        assert.doesNotMatch(src, /CommunityModeEnabled|ScanCommunityMembers|C_Club\.\w+\(/, name);
    }
    assert.match(core, /^Overlord\.RelayEnabled = true$/m);
    // 1.4.0: one campaign per ruleset; PvP keeps the historical "global" pool.
    assert.match(pools, /pvp = "global"/);
    assert.match(pools, /function RealmPools:GetOverlordPoolTag\(\)[\s\S]*?RULESET_POOL\[/);
    assert.match(beta, /addon\.RelayEnabled ~= false/);
    assert.match(beta, /NormalizeRegionPool\(pool\)/);
});

test("Fortresses share the Outpost engine without loading siege controllers", () => {
    const toc = read("Overlord.toc");
    assert.match(toc, /^GuildKeepSites\.lua$/m);
    assert.match(toc, /^OutpostControl\.lua$/m);
    assert.doesNotMatch(toc, /GuildKeepControl|GuildKeepImmersion|SyncGuildKeep/);
    assert.doesNotMatch(read("GuildKeep.lua"), /SIEGE_INTERVAL|SiegeWindow|DailyProof/);
});
