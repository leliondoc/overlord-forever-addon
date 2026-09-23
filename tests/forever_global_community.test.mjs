import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (name) => readFileSync(new URL(`../${name}`, import.meta.url), "utf8");

test("Forever uses one global community and keeps the fallback relay active", () => {
    const core = read("Core.lua");
    const pools = read("RealmPools.lua");
    const sync = read("Sync.lua");
    const beta = read("SyncBetaNetwork.lua");

    assert.match(core, /^Overlord\.CommunityModeEnabled = true$/m);
    assert.match(core, /^Overlord\.BetaNetworkEnabled = true$/m);
    assert.match(sync, /global\s*=\s*\{\s*"0m7kdXcnvR"\s*\}/);
    assert.match(pools, /function RealmPools:GetOverlordPoolTag\(\)[\s\S]*?return "global"/);
    assert.match(beta, /addon\.BetaNetworkEnabled ~= false/);
    assert.match(beta, /NormalizeRegionPool\(pool\)/);
});

test("Forever Guild Keeps use four realm-time siege windows", () => {
    const keep = read("GuildKeep.lua");
    assert.match(keep, /SIEGE_INTERVAL_MINUTE = 6 \* 60/);
    assert.match(keep, /SIEGE_FIRST_START_MINUTE = 3 \* 60/);
    assert.match(keep, /hour, minute = GetGameTime\(\)/);
    assert.match(keep, /SIEGE_WINDOW_DURATION_MINUTE = 60/);
});
