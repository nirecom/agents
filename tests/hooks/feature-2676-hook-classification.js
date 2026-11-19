"use strict";
// Tests: docs/architecture/claude-code/settings/hook-timeout.md, settings.json, hooks/scan-outbound.js, hooks/workflow-gate.js, hooks/enforce-worktree.js, hooks/confirm-forge-target-ownership.js, hooks/check-cross-platform.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, non-allow-deny-hook, decision-time-limit, settings, docs, scope:issue-specific, subprocess, scan-outbound, workflow-gate, enforce-worktree, settings-registration, block-case-markers
// Serial: spawns every PreToolUse hook and real git commits; ~100 s alone, exceeds the 180 s file limit under parallel load
// #2676 / #2540 Step 2: hook-timeout.md owns the classification of every PreToolUse hook (a missing
// row, a "with limit" row that never arms, a "no limit" row without a reason fail); oracle.js checks
// each hook's printed class. Step 5 / 6 cases: feature-2676-hook-classification-limits.js and
// feature-2676-hook-classification-registration.js.
// TL3 gap (what this test does NOT catch):
// - how Claude Code acts on each printed decision; its launch delay and cancel of an overrun hook
// Closest-to-action mitigation: tests/hooks/TL3-hook-registered-deny.sh, TL3-hook-timeout-window.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const fx = require("./feature-2676-hook-classification/fixture");
after(() => { fx.cleanup(); restore(); });
const table = require("./feature-2676-hook-classification/table");
const { loaded, armsLimit, LIMIT_MS, SESSION, limitAsk, decided } = require("./feature-2676-hook-classification/common");

// Fixed by the plan (Step 5 arms the heavy hooks; Step 2 names the rewrite / display-only hooks).
const HEAVY = ["scan-outbound", "workflow-gate", "enforce-worktree", "confirm-forge-target-ownership", "check-cross-platform"];
const NON_ALLOW_DENY = ["rtk-rewrite", "subagent-dispatch-prompt", "show-user-verified-context", "jev-shadow-pre"];

const registeredHooks = () => [...new Set(table.registrations().map((reg) => reg.hook))];

caseBegin("classification-table", "docs/architecture/claude-code/settings/hook-timeout.md");
test("every row is classified as allow-deny hook or non-allow-deny hook, with a settled limit", () => {
  for (const row of loaded()) {
    assert.ok(row.hooks.length > 0, `the row names a hook under hooks/: ${row.raw}`);
    assert.ok(row.kind, `classification is "allow-deny hook" or "non-allow-deny hook": ${row.raw}`);
    if (row.kind === "allow-deny") {
      assert.ok(row.limit === "yes" || row.limit === "no", `an allow-deny hook's limit starts with ${table.LIMIT_YES} or ${table.LIMIT_NO}: ${row.raw}`);
    } else {
      assert.ok(row.limit !== "yes", `a non-allow-deny hook has no decision time limit: ${row.raw}`);
    }
  }
});

test("each rewrite / display-only hook is a non-allow-deny hook", () => {
  const rows = loaded();
  for (const hookName of NON_ALLOW_DENY) {
    const row = table.rowFor(rows, hookName);
    assert.ok(row, `${hookName} has a row`);
    assert.strictEqual(row.kind, "non-allow-deny", `${hookName}: non-allow-deny hook`);
  }
});

test("every row without a limit says why", () => {
  const without = loaded().filter((row) => row.kind === "allow-deny" && row.limit === "no");
  assert.ok(without.length > 0, "at least one allow-deny hook has no limit (the merged hook)");
  for (const row of without) {
    assert.ok(row.reason && !table.DASH.test(row.reason), `a reason is written: ${row.raw}`);
  }
});

test("every \"with limit\" row's entrypoint calls armDecisionTimeLimit", () => {
  const withLimit = loaded().filter((row) => row.limit === "yes").flatMap((row) => row.hooks);
  assert.ok(withLimit.length >= HEAVY.length, "the heavy hooks are among the rows with a limit");
  assert.deepStrictEqual(withLimit.filter((hookName) => !armsLimit(hookName)), [],
    "\"with limit\" hooks whose entrypoint never arms the limit");
});

// The reader itself, on a fabricated table shaped like the plan's: passes today, so the cases
// above fail only for the missing document, not for a reader that cannot read it.
test("the table reader: header-found table, several hooks per cell, settled and unsettled limits", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "f2676-table-"));
  try {
    const doc = path.join(dir, "hook-timeout.md");
    fs.writeFileSync(doc, [
      "# Sample", "", "| other | column |", "|---|---|", "| scan-outbound | not the table |", "",
      `| hook | ${table.COL_KIND} | ${table.COL_LIMIT} | ${table.COL_REASON} |`, "|---|---|---|---|",
      `| \`scan-outbound\` | allow-deny hook | ${table.LIMIT_YES} | git and scanner child processes |`,
      `| \`enforce-system-ops\` | allow-deny hook | ${table.LIMIT_NO} | no child process |`,
      `| \`rtk-rewrite\`${table.IDEOGRAPHIC_COMMA}\`subagent-dispatch-prompt\` | non-allow-deny hook | ${table.EM_DASH} | updatedInput only |`,
      "| `block-dotenv` | allow-deny hook | Step 2 | unsettled |", "", "After the table.", "",
    ].join("\n"));
    const { rows, error } = table.readClassification(doc);
    assert.strictEqual(error, null);
    assert.deepStrictEqual(rows.map((row) => [row.hooks, row.kind, row.limit]), [
      [["scan-outbound"], "allow-deny", "yes"],
      [["enforce-system-ops"], "allow-deny", "no"],
      [["rtk-rewrite", "subagent-dispatch-prompt"], "non-allow-deny", "none"],
      [["block-dotenv"], "allow-deny", null],
    ]);
    assert.strictEqual(rows[1].reason, "no child process");
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
caseEnd();

caseBegin("classification-coverage", "settings.json");
test("every hook registered under PreToolUse has a row in the classification table", () => {
  const rows = loaded();
  const registered = registeredHooks();
  assert.ok(registered.length > 0 && !registered.includes(null), "every registration runs a hooks/<name>.js");
  assert.deepStrictEqual(registered.filter((hookName) => !table.rowFor(rows, hookName)), [],
    "registered hooks without a classification row");
});

test("a registered hook that arms the limit is a \"with limit\" row (the table stays the SSOT)", () => {
  const rows = loaded();
  const unlisted = registeredHooks().filter((hookName) => armsLimit(hookName))
    .filter((hookName) => { const row = table.rowFor(rows, hookName); return !row || row.limit !== "yes"; });
  assert.deepStrictEqual(unlisted, [], "hooks that arm the limit but are not \"with limit\" in the table");
});
caseEnd();

// --- the decision oracle: what each registered hook really prints -------------------------------
// oracle.js fixes, per hook, a probe input and the decision class it must produce. An allow-deny
// hook has a decision probe (deny / ask, or allow for the hooks that can only allow) and a
// permitted probe (allow / approve / none); a non-allow-deny hook never prints a permission
// decision on any probe. So a row whose classification disagrees with the hook's output fails.
const { ORACLE, runProbe } = require("./feature-2676-hook-classification/oracle");
const probeContext = { tempDir: fx.tempDir, makeRepo: fx.makeRepo, makeLinkedWorktree: fx.makeLinkedWorktree };
const DECISION_WANTS = new Set(["deny", "ask"]);
const PERMITTED_WANTS = new Set(["allow", "approve", "none"]);
// Each of these hooks is an allow-deny hook that can only allow (it never refuses); its decision probe is an allow.
const ALLOW_ONLY_HOOKS = new Set(["gate-plan-skip-sentinel", "preuse-auto-approve"]);

caseBegin("classification-oracle", "settings.json");
test("every registered PreToolUse hook has an oracle entry with a known classification", () => {
  const missing = registeredHooks().filter((hookName) => !ORACLE[hookName]);
  assert.deepStrictEqual(missing, [], "registered hooks without an oracle entry");
  for (const [hookName, entry] of Object.entries(ORACLE)) {
    assert.ok(["allow-deny", "non-allow-deny"].includes(entry.kind), `${hookName}: kind ${entry.kind}`);
    const wants = entry.probes.map((probe) => probe.want);
    if (entry.kind === "non-allow-deny") {
      assert.ok(wants.length >= 2 && wants.every((want) => want === "no-permission-decision"), `${hookName}: ${wants}`);
      continue;
    }
    const decisionWants = ALLOW_ONLY_HOOKS.has(hookName) ? new Set(["allow"]) : DECISION_WANTS;
    assert.ok(wants.some((want) => decisionWants.has(want)), `${hookName}: a decision probe (${[...decisionWants]}): ${wants}`);
    assert.ok(wants.some((want) => PERMITTED_WANTS.has(want)), `${hookName}: a permitted probe: ${wants}`);
  }
});

for (const [hookName, entry] of Object.entries(ORACLE)) {
  test(`${hookName} (${entry.kind} hook): each probe produces its fixed decision`, () => {
    for (const probe of entry.probes) {
      const run = runProbe(hookName, probe, probeContext);
      assert.strictEqual(run.signal, null, `${hookName} / ${probe.label}: finished in time (stderr: ${run.stderr})`);
      // A silent hook makes no decision; the oracle spells that "none".
      const got = run.got === "silent" ? "none" : run.got;
      assert.strictEqual(got, probe.want, `${hookName} / ${probe.label}: stdout ${run.stdout} stderr ${run.stderr}`);
    }
  });
}
caseEnd();

caseBegin("classification-oracle-table", "docs/architecture/claude-code/settings/hook-timeout.md");
test("each table row's classification equals the oracle's (the table is what the hooks do)", () => {
  const rows = loaded();
  const disagreeing = Object.entries(ORACLE).filter(([hookName, entry]) => {
    const row = table.rowFor(rows, hookName);
    return !row || row.kind !== entry.kind;
  }).map(([hookName, entry]) => `${hookName}: oracle ${entry.kind}, table ${(table.rowFor(rows, hookName) || {}).kind}`);
  assert.deepStrictEqual(disagreeing, [], "rows whose classification is not what the hook prints");
});
caseEnd();

caseBegin("block-case-markers-limit", "hooks/block-case-markers.js");
// A new hook test lacking case markers in a repo carrying tests/lib/harness.sh (oracle.js's probe).
const newCaseWrite = (repo) => ({ session_id: SESSION, tool_name: "Write", tool_input: { file_path: `${repo}/tests/hooks/new-case.sh`,
  content: "#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\n# Tags: scope:common\necho no markers\n" } });
test("block-case-markers: a slow case-marker checker reaches the limit -> ask naming it", () => {
  const repo = fx.makeRepo("bcm", { "tests/lib/harness.sh": "#!/usr/bin/env bash\n" });
  const run = fx.runHook("block-case-markers", newCaseWrite(repo), { cwd: repo, env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "check-case-markers\\.sh" } });
  limitAsk(run, "block-case-markers", /^bash \S*check-case-markers\.sh/);
});
test("regression: a new hook test without case markers still blocks", () => {
  const repo = fx.makeRepo("bcmreg", { "tests/lib/harness.sh": "#!/usr/bin/env bash\n" });
  decided(fx.runHook("block-case-markers", newCaseWrite(repo), { cwd: repo }), "block");
});
caseEnd();
