import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (file) => readFileSync(new URL(`../${file}`, import.meta.url), "utf8");

// 1.0.23 CPU spike: every client that received a beta broadcast re-sent keep and
// outpost states to raid + channel, and re-authored OC/WB into the relay.
test("Keep and outpost states are re-sent only for targeted beta deliveries", () => {
    const targeted = /== "BETA" and Overlord\.BetaNetwork and Overlord\.BetaNetwork:IsTargetedDispatch\(\)\)/g;
    const keep = read("SyncGuildKeep.lua");
    const outpost = read("SyncOutpost.lua");
    assert.equal(keep.match(targeted)?.length, 5, "Guild keep rebroadcast sites");
    assert.equal(outpost.match(targeted)?.length, 4, "Outpost rebroadcast sites");
    for (const [name, source, send] of [
        ["SyncGuildKeep.lua", keep, /BroadcastGuildKeepToGroup\("(GK|GH)"/],
        ["SyncOutpost.lua", outpost, /BroadcastOutpostToGroup\("(OP|OC|LO|LOC)"/],
    ]) {
        const lines = source.split("\n");
        lines.forEach((line, index) => {
            if (!send.test(line)) return;
            const window = lines.slice(Math.max(0, index - 20), index).join("\n");
            assert.doesNotMatch(window, /(channel|sourceChannel) == "BETA"\)/,
                `${name}:${index + 1} re-sends after an untargeted beta broadcast`);
        });
    }
});

test("Structure relays do not re-author packets into the beta relay without a club", () => {
    const aux = read("SyncAux.lua");
    for (const fn of ["RelayOutpostCaptureToCommunitySafe", "RelayDominationBoostToCommunitySafe"]) {
        const body = aux.slice(aux.indexOf(`function Overlord.Sync:${fn}`));
        const head = body.slice(0, body.indexOf("\nend"));
        assert.match(head, /self:StructureRelayOnlyReachesBeta\(\) then return end/, fn);
    }
});

test("Relay rejects duplicates before decoding and keeps O(1) dedup memory", () => {
    const net = read("SyncBetaNetwork.lua");
    const receive = net.slice(net.indexOf("function net:Receive("));
    assert.ok(receive.indexOf("alreadySeen(wire)") < receive.indexOf("decode(wire)"),
        "Receive decodes before the duplicate check");
    const fragment = net.slice(net.indexOf("function net:ReceiveFragment("));
    assert.ok(fragment.indexOf("alreadySeen(wire)") < fragment.indexOf("decode(wire)"),
        "ReceiveFragment decodes before the duplicate check");
    assert.match(fragment, /self:Receive\(wire, name, transport, bnetID, p\)/, "Packet decoded twice");
    assert.doesNotMatch(net, /table\.remove\(order, 1\)/, "O(n) dedup eviction is back");
});
