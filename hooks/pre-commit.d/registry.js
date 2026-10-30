"use strict";
// Check registry of the pre-commit body (#2507, D2): run order, fail mode and read source of each
// check, and the agents-repo gate children (D7). The check contract every checks/<name>.js meets:
//   run({ context, snapshot, files }) -> { verdict, messages, details?, indexChanged? }
//   verdict: pass | block | warn | skip-rest | confirm-warn; messages: [{ stream, text }].
// A thrown check maps by failMode: closed blocks the commit, open prints a diagnostic and continues.

const path = require("path");

const FIELDS = ["name", "order", "failMode", "agentsRepoOnly", "mergeNarrowable", "visibilityGated", "readSource", "mutatesIndex"];
const READ_SOURCES = new Set(["snapshot", "none", "working-tree", "working-tree-whole"]);
const GATE_READ_SOURCES = new Set(["snapshot", "working-tree", "working-tree-whole"]);

// [name, failMode, agentsRepoOnly, mergeNarrowable, visibilityGated, readSource, mutatesIndex]
const ROWS = [
  ["enforce-worktree", "closed", false, false, false, "snapshot", false],
  ["settings-effort-unstage", "open", false, false, false, "snapshot", true],
  ["code-lang", "open", false, true, false, "snapshot", false],
  ["sh-exec-bit", "closed", false, true, false, "snapshot", false],
  ["prompt-extraction", "closed", true, true, false, "snapshot", false],
  ["tests-frontmatter", "open", false, true, false, "snapshot", false],
  ["agents-repo-gates", "closed", true, true, false, "snapshot", false],
  ["comment-block-size", "open", true, true, false, "snapshot", false],
  ["repo-visibility", "open", false, false, false, "none", false],
  ["env-file-block", "closed", false, false, true, "snapshot", false],
  ["outbound-scan", "closed", false, false, true, "snapshot", false],
];

const CHECKS = ROWS.map(([name, failMode, agentsRepoOnly, mergeNarrowable, visibilityGated, readSource, mutatesIndex], order) =>
  Object.freeze({ name, order, failMode, agentsRepoOnly, mergeNarrowable, visibilityGated, readSource, mutatesIndex }));

function gateMarkerName(cliPath) {
  const base = path.posix.basename(String(cliPath).replace(/\\/g, "/")).replace(/\.sh$/, "");
  return `agents-repo-gate-${base.toLowerCase().replace(/[^a-z0-9-]/g, "-")}`;
}

// [cliPath, module, what, doc, readSource, firstArg]
const GATE_ROWS = [
  ["bin/check-on-demand-rules.sh", "bin/lib/check-on-demand-rules.js", "on-demand rules-injection notation violations",
    "docs/architecture/claude-code/rules-injection.md", "working-tree-whole", "--staged"],
  ["bin/check-session-id-ssot.sh", "bin/check-session-id-ssot/main.js", "session-id env reads bypassing the SSOT resolver",
    "docs/architecture/claude-code/session-id-resolution.md", "working-tree", "--staged"],
  ["bin/check-migration-blocks.sh", "bin/lib/check-migration-blocks.js", "migration block format violations",
    "", "snapshot", "--staged"],
  ["bin/check-plans-artifacts", "bin/check-plans-artifacts", "plans-dir names that are not registered artifacts",
    "docs/architecture/claude-code/state-dirs.md", "working-tree-whole", "--source"],
  ["bin/check-plans-dir-isolation.sh", "bin/check-plans-dir-isolation/main.js", "test fixture isolation violations",
    "rules/test/fixture-isolation.md", "snapshot", "--staged"],
  ["bin/check-root-names.sh", "bin/check-root-names/main.js", "root-name violations",
    "docs/architecture/claude-code/root-names.md", "snapshot", "--staged"],
];

const AGENTS_REPO_GATES = GATE_ROWS.map(([cliPath, module, what, doc, readSource, arg0]) =>
  Object.freeze({ name: gateMarkerName(cliPath), cliPath, module, what, doc, readSource, args: Object.freeze([arg0]) }));

const WORKING_TREE_GATE = "bin/check-session-id-ssot.sh";

// validate(checks, gates) — throws on a registry that breaks the D2 / D7 declaration rules.
function validate(checks, gates) {
  if (!Array.isArray(checks) || !Array.isArray(gates)) throw new Error("registry: checks and gates must be arrays");
  const vis = checks.findIndex((c) => c && c.name === "repo-visibility");
  checks.forEach((c, i) => {
    for (const f of FIELDS) if (!c || !(f in c)) throw new Error(`registry: ${c && c.name} lacks field ${f}`);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(c.name)) throw new Error(`registry: bad check name ${c.name}`);
    if (c.failMode !== "closed" && c.failMode !== "open") throw new Error(`registry: ${c.name} failMode ${c.failMode}`);
    if (!READ_SOURCES.has(c.readSource)) throw new Error(`registry: ${c.name} readSource ${c.readSource}`);
    if (c.visibilityGated && (vis < 0 || i < vis)) throw new Error(`registry: ${c.name} is visibilityGated before repo-visibility`);
  });
  for (const g of gates) {
    if (!g || !GATE_READ_SOURCES.has(g.readSource)) throw new Error(`registry: gate ${g && g.cliPath} readSource ${g && g.readSource}`);
    if (g.readSource === "working-tree" && g.cliPath !== WORKING_TREE_GATE) {
      throw new Error(`registry: gate ${g.cliPath} may not read the working tree`);
    }
  }
  return true;
}

module.exports = { CHECKS, AGENTS_REPO_GATES, validate, gateMarkerName, FIELDS };
