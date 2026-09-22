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

test("all Forever clients use the Retail US Guild Keep window", () => {
    const keep = read("GuildKeep.lua");
    assert.match(keep, /SIEGE_WINDOW_US_START_MINUTE = 18 \* 60/);
    assert.match(keep, /function Overlord\.GuildKeep:IsUsSiegeSchedule\(\)[\s\S]*?return true\s*end/);
    assert.match(keep, /SIEGE_WINDOW_DURATION_MINUTE = 60/);
});
