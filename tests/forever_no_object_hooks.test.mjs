import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

// 2.0. On the Forever client a method of a Blizzard object wrapped with hooksecurefunc
// can start raising a bare "attempt to call a nil value" in Blizzard's own caller (the
// original runs, the addon's post-hook is no longer called) until the game is
// relaunched. Seen in game on 2026-10-11 and 2026-10-12 on WorldMapFrame:SetMapID (the
// front's circles stayed painted on the continent map) and on CharacterFrame:ShowSubFrame,
// and reported by other addons of this client. The addon therefore wraps no method of an
// object: script hooks (HookScript), its own frames and events only. Since 2.0 it calls
// hooksecurefunc nowhere at all: the last one, on the global SetItemRef, ran at every
// chat link click for a link that only exists in the addon's own windows.
const root = new URL("../", import.meta.url);
const sources = readdirSync(root)
    .filter((name) => name.endsWith(".lua"))
    .map((name) => ({ name, text: readFileSync(new URL(name, root), "utf8") }));

function withoutComments(text) {
    return text.split(/\r?\n/).map((line) => line.replace(/--.*$/, ""));
}

test("no hooksecurefunc anywhere in the addon", () => {
    assert.ok(sources.length > 40, "the addon's Lua files were not found");
    const found = [];
    for (const { name, text } of sources) {
        withoutComments(text).forEach((code, index) => {
            // A call, a call through pcall or unpack, or a local alias.
            if (/\bhooksecurefunc\b/.test(code)) found.push(`${name}:${index + 1}: ${code.trim()}`);
        });
    }
    assert.deepEqual(found, [], "hooksecurefunc is back:\n" + found.join("\n"));
});

test("the map, the character sheet, the options and the action bars use script hooks or their own frames", () => {
    const text = (name) => {
        const source = sources.find((entry) => entry.name === name);
        assert.ok(source, `${name} is missing`);
        return withoutComments(source.text).join("\n");
    };
    // The world map is read by the addon's own driver and by the map's OnShow script.
    assert.match(text("MapMarkers.lua"), /pcall\(WorldMapFrame\.GetMapID, WorldMapFrame\)/);
    assert.match(text("MapMarkers.lua"), /WorldMapFrame:HookScript\("OnShow"/);
    // The rank tab closes on the panels' own OnShow scripts.
    assert.match(text("RanksUI.lua"), /frame:HookScript\("OnShow", OnBlizzardPanelShown\)/);
    // The options title is kept by a frame of the addon while the options window is open.
    assert.match(text("SettingsPanel.lua"), /SP\._titleWatcher = watcher/);
    // The action bar shortcut's logo follows events.
    assert.match(text("ActionShortcut.lua"), /actionIconEventFrame:RegisterEvent\("ACTIONBAR_SLOT_CHANGED"\)/);
});
