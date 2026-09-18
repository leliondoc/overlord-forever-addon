import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
const validationWorkflow = readFileSync(
    new URL("../.github/workflows/validate.yml", import.meta.url), "utf8",
);
const toc = readFileSync(new URL("../Overlord.toc", import.meta.url), "utf8");
const core = readFileSync(new URL("../Core.lua", import.meta.url), "utf8");
const changelog = readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8");

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

test("release metadata is consistent across TOC, Core and CHANGELOG", () => {
    const tocMatch = toc.match(/^## Version: (\d+\.\d+\.\d+)$/m);
    assert.ok(tocMatch, "Overlord.toc must declare ## Version: X.Y.Z");
    const version = tocMatch[1];
    const versionRe = escapeRegExp(version);

    assert.match(core, new RegExp(`^Overlord\\.Version = "${versionRe}"$`, "m"));
    assert.match(changelog, new RegExp(`^${versionRe}$`, "m"));
    assert.equal((changelog.match(/^\d+\.\d+(?:\.\d+)?$/gm) || []).length, 1);
});

test("release tags are gated by Lua syntax and exact versions", () => {
    assert.match(workflow, /lua5\.1 tests\/lua_syntax_check\.lua/);
    assert.match(workflow, /test "\$TOC_VERSION" = "\$\{GITHUB_REF_NAME\}"/);
    assert.match(workflow, /test "\$CORE_VERSION" = "\$\{GITHUB_REF_NAME\}"/);
    assert.match(workflow, /CF_API_KEY absent[\s\S]*?exit 1/);
    assert.doesNotMatch(workflow, /continue-on-error:\s*true/);
    assert.match(validationWorkflow, /branches:[\s\S]*?- main/);
    assert.match(validationWorkflow, /lua5\.1 tests\/lua_syntax_check\.lua/);
    assert.match(validationWorkflow, /node --test/);
});
