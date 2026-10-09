import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (file) => readFileSync(new URL(`../${file}`, import.meta.url), "utf8");

// 1.0.23 CPU spike: every client that received a beta broadcast re-sent keep and
// outpost states to raid + channel, and re-authored OC into the relay (WB was removed with the wood system in 1.2.0).
test("Keep and outpost states are re-sent only for targeted beta deliveries", () => {
    const targeted = /== "BETA" and Overlord\.Relay and Overlord\.Relay:IsTargetedDispatch\(\)\)/g;
    const outpost = read("SyncOutpost.lua");
    // 1.7.2: only an assault in progress (OP) is re-sent; a capture claim (OC, LO,
    // LOC, held OP) is believed from its capturer alone and never re-authored.
    assert.equal(outpost.match(targeted)?.length, 1, "Outpost rebroadcast sites");
    for (const [name, source, send] of [
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
    // 1.4.2: the community transport is gone; no structure relay re-authors a
    // packet through it any more (RelayOutpostCaptureToCommunitySafe removed).
    for (const name of ["SyncAux.lua", "Sync.lua", "SyncOutpost.lua"]) {
        assert.doesNotMatch(read(name), /ToCommunity|StructureRelayOnlyReachesBeta/, name);
    }
});

test("Relay rejects duplicates before decoding and keeps O(1) dedup memory", () => {
    const net = read("SyncRelay.lua");
    const receive = net.slice(net.indexOf("function net:Receive("));
    assert.ok(receive.indexOf("alreadySeen(wire)") < receive.indexOf("decode(wire)"),
        "Receive decodes before the duplicate check");
    const fragment = net.slice(net.indexOf("function net:ReceiveFragment("));
    assert.ok(fragment.indexOf("alreadySeen(wire)") < fragment.indexOf("decode(wire)"),
        "ReceiveFragment decodes before the duplicate check");
    assert.match(fragment, /self:Receive\(wire, name, transport, bnetID, p, wasSeen\)/, "Packet decoded twice");
    assert.doesNotMatch(net, /table\.remove\(order, 1\)/, "O(n) dedup eviction is back");
});
