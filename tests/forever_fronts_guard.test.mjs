import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const fronts = readFileSync(new URL("../Fronts.lua", import.meta.url), "utf8");
const toc = readFileSync(new URL("../Overlord.toc", import.meta.url), "utf8");
const outpost = readFileSync(new URL("../Outpost.lua", import.meta.url), "utf8");

test("Forever fronts: Arathi (existing points), Loch, Durotar, Ashenvale", () => {
    assert.match(fronts, /Overlord\.Fronts\.Order = Overlord\.Fronts\.Order or \{"arathi", "loch_modan", "durotar", "ashenvale"\}/);
    assert.match(fronts, /activeFrontId = "arathi"/);
    assert.match(fronts, /Zone\("stromgarde"/);
    assert.match(fronts, /center = \{20\.0, 63\.5\}/);
    assert.match(fronts, /id = "ashenvale"/);
    assert.doesNotMatch(fronts, /id = "elwynn"/);
    assert.doesNotMatch(fronts, /id = "gilneas"/);
    assert.doesNotMatch(fronts, /id = "southern_barrens"/);
});

test("TOC Forever 16001 and CurseForge 1701204", () => {
    assert.match(toc, /^## Interface: 16001$/m);
    assert.match(toc, /^## X-Curse-Project-ID: 1701204$/m);
    assert.doesNotMatch(toc, /Bounty\.lua|Export\.lua|HallOfFame|ManualBounty|General\.lua/);
});

test("Outposts match the four Forever fronts", () => {
    assert.match(outpost, /frontId = "arathi"/);
    assert.match(outpost, /center = \{ 11\.2, 70\.5 \}/);
    assert.match(outpost, /frontId = "ashenvale"/);
    assert.doesNotMatch(outpost, /frontId = "elwynn"/);
    assert.doesNotMatch(outpost, /coiled_isle/);
});
