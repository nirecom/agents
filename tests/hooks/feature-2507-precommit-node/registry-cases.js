"use strict";
// Registry part of tests/hooks/feature-2507-precommit-node.js (#2507): the D2 declarations, the
// marker order of the commit-push contract, and the rules validate() enforces. No case markers.
const assert = require("node:assert");
const { test } = require("node:test");

const FIELDS = ["name", "order", "failMode", "agentsRepoOnly", "mergeNarrowable", "visibilityGated", "readSource", "mutatesIndex"];
// name, failMode, agentsRepoOnly, mergeNarrowable, visibilityGated, readSource, mutatesIndex (D2).
const D2 = [
  ["enforce-worktree", "closed", false, false, false, "snapshot", false],
  ["settings-effort-unstage", "open", false, false, false, "snapshot", true],
  ["code-lang", "open", false, true, false, "snapshot", false],
  ["sh-exec-bit", "closed", false, true, false, "snapshot", false],
  ["prompt-extraction", "closed", true, true, false, "snapshot", false],
  ["tests-frontmatter", "open", false, true, false, "snapshot", false],
  ["agents-repo-gates", "closed", true, true, false, null, false],
  ["comment-block-size", "open", true, true, false, "snapshot", false],
  ["repo-visibility", "open", false, false, false, "none", false],
  ["env-file-block", "closed", false, false, true, "snapshot", false],
  ["outbound-scan", "closed", false, false, true, "snapshot", false],
];
// cliPath, module, what, doc, readSource of the six agents-repo gates, in call order (D7).
const GATES = [
  ["bin/check-on-demand-rules.sh", "bin/lib/check-on-demand-rules.js", "on-demand rules-injection notation violations", "docs/architecture/claude-code/rules-injection.md", "working-tree-whole", "--staged"],
  ["bin/check-session-id-ssot.sh", "bin/check-session-id-ssot/main.js", "session-id env reads bypassing the SSOT resolver", "docs/architecture/claude-code/session-id-resolution.md", "working-tree", "--staged"],
  ["bin/check-migration-blocks.sh", "bin/lib/check-migration-blocks.js", "migration block format violations", "", "snapshot", "--staged"],
  ["bin/check-plans-artifacts", "bin/check-plans-artifacts", "plans-dir names that are not registered artifacts", "docs/architecture/claude-code/state-dirs.md", "working-tree-whole", "--source"],
  ["bin/check-plans-dir-isolation.sh", "bin/check-plans-dir-isolation/main.js", "test fixture isolation violations", "rules/test/fixture-isolation.md", "snapshot", "--staged"],
  ["bin/check-root-names.sh", "bin/check-root-names/main.js", "root-name violations", "docs/architecture/claude-code/root-names.md", "snapshot", "--staged"],
];

const reg = (F) => F.fresh("registry.js");
const clone = (entries) => entries.map((e) => ({ ...e }));

function requiredDeclarations(F) {
  test("every registry entry declares the eight D2 fields with the D2 values, in D2 order", () => {
    const { CHECKS } = reg(F);
    assert.deepStrictEqual(CHECKS.map((c) => c.name), D2.map((r) => r[0]));
    CHECKS.forEach((c, i) => {
      for (const f of FIELDS) assert.ok(f in c, `${c.name}: field ${f} missing`);
      assert.strictEqual(c.order, i, `${c.name}: order is its position`);
      const [, failMode, aro, mn, vg, rs, mi] = D2[i];
      assert.deepStrictEqual([c.failMode, c.agentsRepoOnly, c.mergeNarrowable, c.visibilityGated, c.mutatesIndex], [failMode, aro, mn, vg, mi], c.name);
      if (rs !== null) assert.strictEqual(c.readSource, rs, `${c.name}: readSource`);
    });
  });
  test("validate() accepts the shipped registry and rejects an entry missing any one field", () => {
    const { CHECKS, AGENTS_REPO_GATES, validate } = reg(F);
    assert.doesNotThrow(() => validate(CHECKS, AGENTS_REPO_GATES));
    for (const f of FIELDS) {
      const broken = clone(CHECKS);
      delete broken[3][f];
      assert.throws(() => validate(broken, AGENTS_REPO_GATES), undefined, `missing ${f} must be rejected`);
    }
  });
}

function markerOrder(F) {
  test("check names follow the commit-push marker contract format", () => {
    for (const c of reg(F).CHECKS) assert.match(c.name, /^[a-z0-9][a-z0-9-]*$/);
  });
  test("the six gate children are declared in call order with cliPath, module, what, doc, args", () => {
    const { AGENTS_REPO_GATES, gateMarkerName } = reg(F);
    assert.strictEqual(AGENTS_REPO_GATES.length, 6);
    AGENTS_REPO_GATES.forEach((g, i) => {
      const [cliPath, mod, what, doc, , arg0] = GATES[i];
      assert.strictEqual(g.cliPath, cliPath);
      assert.strictEqual(g.module, mod);
      assert.strictEqual(g.what, what);
      assert.strictEqual(g.doc || "", doc);
      assert.strictEqual(g.args[0], arg0, `${cliPath}: first argument`);
      assert.strictEqual(g.name, gateMarkerName(cliPath), `${cliPath}: name is the derived marker name`);
    });
  });
  test("gate marker names: basename, .sh stripped, lower-cased, [^a-z0-9-] to '-'", () => {
    const { gateMarkerName } = reg(F);
    const table = [
      ["bin/check-on-demand-rules.sh", "agents-repo-gate-check-on-demand-rules"],
      ["bin/check-plans-artifacts", "agents-repo-gate-check-plans-artifacts"],
      ["/abs/bin/Check_Root.Names.sh", "agents-repo-gate-check-root-names"],
      ["bin/UPPER.SH", "agents-repo-gate-upper-sh"],
    ];
    for (const [input, want] of table) assert.strictEqual(gateMarkerName(input), want, input);
  });
}

function visibilityAndReadSource(F) {
  test("every visibilityGated check sits after repo-visibility", () => {
    const { CHECKS } = reg(F);
    const vis = CHECKS.findIndex((c) => c.name === "repo-visibility");
    assert.ok(vis >= 0);
    CHECKS.forEach((c, i) => { if (c.visibilityGated) assert.ok(i > vis, `${c.name} before repo-visibility`); });
  });
  test("validate() rejects a visibilityGated check placed before repo-visibility", () => {
    const { CHECKS, AGENTS_REPO_GATES, validate } = reg(F);
    const moved = clone(CHECKS);
    const env = moved.findIndex((c) => c.name === "env-file-block");
    const [entry] = moved.splice(env, 1);
    moved.splice(2, 0, entry);
    moved.forEach((c, i) => { c.order = i; });
    assert.throws(() => validate(moved, AGENTS_REPO_GATES));
  });
  test("gate readSource: working-tree only for session-id-ssot, working-tree-whole for on-demand-rules and plans-artifacts", () => {
    const { AGENTS_REPO_GATES } = reg(F);
    AGENTS_REPO_GATES.forEach((g, i) => assert.strictEqual(g.readSource, GATES[i][4], g.cliPath));
  });
  test("validate() rejects a gate with an undeclared read source or a second working-tree reader", () => {
    const { CHECKS, AGENTS_REPO_GATES, validate } = reg(F);
    const unknown = clone(AGENTS_REPO_GATES);
    unknown[5].readSource = "disk";
    assert.throws(() => validate(CHECKS, unknown), undefined, "unknown readSource");
    const second = clone(AGENTS_REPO_GATES);
    second[5].readSource = "working-tree";
    assert.throws(() => validate(CHECKS, second), undefined, "working-tree outside session-id-ssot");
  });
}

module.exports = { requiredDeclarations, markerOrder, visibilityAndReadSource };
