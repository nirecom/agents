"use strict";
// Tests: bin/worker-dispatch/workers/commit-push/gate.js, bin/worker-dispatch/workers/commit-push/procedure.js, hooks/lib/worker-dispatch-registry.js
// Tags: TL1, worker-dispatch, commit-push, commit-gate, decision-time-limit, fake-spawn, scope:issue-specific, dup-group-keep:size-hard-limit
// #2849 / #2781: the commit-push worker reads the workflow-gate verdict in both shapes (legacy
// `decision` and hookSpecificOutput.permissionDecision), and hands the gate child a decision time
// limit of GATE_TIMEOUT_MS - 10000 through WORKFLOW_DECISION_TIME_LIMIT_MS. A new file beside
// feature-2762-commit-timeout.js, which is at the code HARD limit; same spawn.js stub pattern.
// TL3 gap (what this test does NOT catch):
// - a real hooks/workflow-gate.js child honouring the handed-over limit inside a real commit
// Closest-to-action mitigation: tests/hooks/feature-2849-decision-budget.js (the env read at arm time).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const CP_DIR = path.join(REPO, "bin", "worker-dispatch", "workers", "commit-push");
const GATE_MODULE = path.join(CP_DIR, "gate.js");
const PROCEDURE_MODULE = path.join(CP_DIR, "procedure.js");
const REGISTRY_MODULE = path.join(REPO, "hooks", "lib", "worker-dispatch-registry.js");
const SPAWN_PATH = require.resolve(path.join(REPO, "bin", "worker-dispatch", "spawn.js"));
const LIMIT_ENV = "WORKFLOW_DECISION_TIME_LIMIT_MS";

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2849-gate-verdict-"));
const savedLimitEnv = process.env[LIMIT_ENV];
delete process.env[LIMIT_ENV];
after(() => {
  if (savedLimitEnv === undefined) delete process.env[LIMIT_ENV];
  else process.env[LIMIT_ENV] = savedLimitEnv;
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

// spawn.js is replaced BEFORE gate.js loads (gate.js destructures `run` at load time).
const realSpawn = require(SPAWN_PATH);
let handler = () => { throw new Error("no spawn handler installed for this test"); };
require.cache[SPAWN_PATH] = {
  id: SPAWN_PATH,
  filename: SPAWN_PATH,
  loaded: true,
  exports: { ...realSpawn, run: (entry, opts) => handler(entry, opts) },
};
const gate = () => require(GATE_MODULE);
const procedure = () => require(PROCEDURE_MODULE);

const ok = (stdout) => ({ status: 0, signal: null, timedOut: false, spawnError: null, stdout: stdout || "", stderr: "" });

let seq = 0;
function fixture() {
  seq += 1;
  const dir = path.join(TMP, `case-${seq}`);
  for (const sub of ["checkout", path.join("worktree", ".git"), "logs", "state"]) fs.mkdirSync(path.join(dir, sub), { recursive: true });
  fs.writeFileSync(path.join(dir, "checkout", ".env"), `WORKFLOW_STATE_DIR=${path.join(dir, "state").replace(/\\/g, "/")}\n`);
  const ctx = {
    entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
    anchors: { scriptCheckoutRoot: path.join(dir, "checkout"), plansDir: dir },
    logDir: path.join(dir, "logs"),
    path,
    fsguard: { writeFile: (p) => p },
  };
  const payload = {
    branch: "feature/2849",
    worktree_path: path.join(dir, "worktree"),
    session_id: "00000000-0000-4000-8000-000000002849",
    commit_message: "feat: a thing",
    wip_mode: true,
    enforce_worktree: "off",
    closes_issues: [],
  };
  return { ctx, payload };
}

// gateCall(stdout) -> { verdict, gateOpts }: runGate once with the gate child answering `stdout`.
function gateCall(stdout) {
  const { ctx, payload } = fixture();
  let gateOpts = null;
  handler = (_entry, opts) => {
    if (opts.command === "node" && opts.script === "workflowGate") {
      gateOpts = opts;
      return ok(stdout);
    }
    return ok("");
  };
  const g = gate();
  const verdict = g.runGate(ctx, payload, g.resolveGateEnv(payload, ctx), ["commit", "-m", "x"], []);
  return { verdict, gateOpts };
}
const hso = (permissionDecision, permissionDecisionReason) =>
  JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision, permissionDecisionReason } });

// ---- verdict shapes -----------------------------------------------------------------------
caseBegin("gate-verdict-hso-allow-proceeds", "bin/worker-dispatch/workers/commit-push/gate.js");
test("hookSpecificOutput allow -> { ok: true }", () => {
  assert.deepStrictEqual(gateCall(hso("allow", "")).verdict, { ok: true });
});
caseEnd();

caseBegin("gate-verdict-hso-deny-refuses", "bin/worker-dispatch/workers/commit-push/gate.js");
test("hookSpecificOutput deny -> a non-degraded refusal carrying the first reason line", () => {
  const { verdict } = gateCall(hso("deny", "Step review_docs is pending\nmore detail"));
  assert.strictEqual(verdict.ok, false);
  assert.strictEqual(verdict.degraded, false, `deny is a decision, not a broken gate: ${verdict.reason}`);
  assert.strictEqual(verdict.reason, "Step review_docs is pending");
});
caseEnd();

caseBegin("gate-verdict-hso-deny-without-reason", "bin/worker-dispatch/workers/commit-push/gate.js");
test("hookSpecificOutput deny with an empty reason -> a non-degraded refusal 'blocked by workflow-gate'", () => {
  assert.deepStrictEqual(gateCall(hso("deny", "")).verdict, { ok: false, degraded: false, reason: "blocked by workflow-gate" });
});
caseEnd();

caseBegin("gate-verdict-hso-ask-refuses-as-ask", "bin/worker-dispatch/workers/commit-push/gate.js");
test("hookSpecificOutput ask -> refusal marked ask, reason 'workflow-gate asked: <first line>'", () => {
  const { verdict } = gateCall(hso("ask", "workflow-gate: decision time limit (110000 ms) reached\nsecond"));
  assert.deepStrictEqual(verdict, {
    ok: false, degraded: false, ask: true,
    reason: "workflow-gate asked: workflow-gate: decision time limit (110000 ms) reached",
  });
});
caseEnd();

caseBegin("gate-verdict-hso-ask-without-reason", "bin/worker-dispatch/workers/commit-push/gate.js");
test("hookSpecificOutput ask with an empty reason -> 'workflow-gate asked for confirmation'", () => {
  const { verdict } = gateCall(hso("ask", ""));
  assert.deepStrictEqual(verdict, { ok: false, degraded: false, ask: true, reason: "workflow-gate asked for confirmation" });
});
caseEnd();

caseBegin("gate-verdict-legacy-shapes-unchanged", "bin/worker-dispatch/workers/commit-push/gate.js");
test("legacy decision: approve proceeds, block refuses with its first reason line", () => {
  assert.deepStrictEqual(gateCall(JSON.stringify({ decision: "approve" })).verdict, { ok: true });
  assert.deepStrictEqual(gateCall(JSON.stringify({ decision: "block", reason: "no\nmore" })).verdict,
    { ok: false, degraded: false, reason: "no" });
  assert.deepStrictEqual(gateCall(JSON.stringify({ decision: "block" })).verdict,
    { ok: false, degraded: false, reason: "blocked by workflow-gate" });
});
caseEnd();

caseBegin("gate-verdict-non-allow-wins-over-allow", "bin/worker-dispatch/workers/commit-push/gate.js");
test("both shapes present and disagreeing: the non-allow side (refuse / ask) wins, fail-closed", () => {
  const both = (legacy, permissionDecision, permissionDecisionReason) =>
    JSON.stringify({ ...legacy, hookSpecificOutput: { permissionDecision, permissionDecisionReason } });
  // legacy block + hso allow -> legacy block
  assert.deepStrictEqual(gateCall(both({ decision: "block", reason: "legacy says no" }, "allow")).verdict,
    { ok: false, degraded: false, reason: "legacy says no" });
  // legacy approve + hso deny -> hso deny (non-degraded refusal with the hso reason)
  assert.deepStrictEqual(gateCall(both({ decision: "approve" }, "deny", "x")).verdict,
    { ok: false, degraded: false, reason: "x" });
  // legacy approve + hso ask -> ask
  assert.deepStrictEqual(gateCall(both({ decision: "approve" }, "ask", "please confirm")).verdict,
    { ok: false, degraded: false, ask: true, reason: "workflow-gate asked: please confirm" });
  // legacy approve + hso allow -> proceeds
  assert.deepStrictEqual(gateCall(both({ decision: "approve" }, "allow", "")).verdict, { ok: true });
  // legacy ask + hso allow -> ask
  const askOverAllow = gateCall(both({ decision: "ask", reason: "legacy asks" }, "allow", "")).verdict;
  assert.strictEqual(askOverAllow.ok, false);
  assert.strictEqual(askOverAllow.degraded, false);
  assert.strictEqual(askOverAllow.ask, true);
});
caseEnd();

const BROKEN = [
  ["empty object", "{}"],
  ["not JSON", "not json"],
  ["hookSpecificOutput a string", JSON.stringify({ hookSpecificOutput: "allow" })],
  ["hookSpecificOutput null", JSON.stringify({ hookSpecificOutput: null })],
  ["permissionDecision a number", JSON.stringify({ hookSpecificOutput: { permissionDecision: 1 } })],
  ["permissionDecision missing", JSON.stringify({ hookSpecificOutput: { permissionDecisionReason: "x" } })],
  ["permissionDecision unknown token", hso("maybe", "x")],
  ["permissionDecision wrong case", hso("Allow", "")],
  ["legacy unknown token", JSON.stringify({ decision: "proceed" })],
];
caseBegin("gate-verdict-broken-shapes-degrade", "bin/worker-dispatch/workers/commit-push/gate.js");
test("unparsable or unrecognized verdicts -> degraded refusal, never a pass", () => {
  for (const [label, stdout] of BROKEN) {
    const { verdict } = gateCall(stdout);
    assert.strictEqual(verdict.ok, false, label);
    assert.strictEqual(verdict.degraded, true, label);
    assert.match(verdict.reason, /unparsable verdict|unrecognized decision/, label);
  }
});
caseEnd();

// ---- decision time limit handed to the gate child -----------------------------------------
caseBegin("gate-decision-limit-exports", "bin/worker-dispatch/workers/commit-push/gate.js");
test("GATE_DECISION_LIMIT_ENV names the env and GATE_DECISION_BUDGET_MS is GATE_TIMEOUT_MS - 10000", () => {
  const g = gate();
  assert.strictEqual(g.GATE_DECISION_LIMIT_ENV, LIMIT_ENV);
  assert.strictEqual(g.GATE_DECISION_BUDGET_MS, g.GATE_TIMEOUT_MS - 10000);
  assert.strictEqual(g.GATE_DECISION_BUDGET_MS, 110000);
});
caseEnd();

caseBegin("gate-child-gets-decision-limit-env", "bin/worker-dispatch/workers/commit-push/gate.js");
test("runGate: the limit env is the 7th name in envScope and extraEnv sets it to '110000'", () => {
  const { gateOpts } = gateCall(JSON.stringify({ decision: "approve" }));
  assert.ok(gateOpts, "the gate child was spawned");
  assert.strictEqual(gateOpts.envScope.length, 7, `envScope: ${gateOpts.envScope}`);
  assert.strictEqual(gateOpts.envScope[6], LIMIT_ENV);
  assert.strictEqual(gateOpts.extraEnv[LIMIT_ENV], "110000");
  assert.strictEqual(gateOpts.timeoutMs, 120000, "the gate's own timeout is unchanged");
});
caseEnd();

caseBegin("gate-decision-limit-ignores-process-env", "bin/worker-dispatch/workers/commit-push/gate.js");
test("runGate: a WORKFLOW_DECISION_TIME_LIMIT_MS in the worker's own env does not change the value", () => {
  process.env[LIMIT_ENV] = "5";
  try {
    const { gateOpts } = gateCall(JSON.stringify({ decision: "approve" }));
    assert.ok(gateOpts, "the gate child was spawned");
    assert.strictEqual(gateOpts.extraEnv[LIMIT_ENV], "110000");
  } finally { delete process.env[LIMIT_ENV]; }
});
caseEnd();

caseBegin("gate-decision-limit-registry-wiring", "hooks/lib/worker-dispatch-registry.js");
test("registry: commit-push declares the env, so spawn.buildEnv accepts it; it is not in CHILD_ENV_ALLOWLIST", () => {
  const registry = require(REGISTRY_MODULE);
  const entry = registry.workers["commit-push"];
  assert.ok(!registry.CHILD_ENV_ALLOWLIST.includes(LIMIT_ENV), "never handed to every worker child");
  assert.ok(entry.envPassthrough.includes(LIMIT_ENV), `envPassthrough: ${entry.envPassthrough}`);
  const { gateOpts } = gateCall(JSON.stringify({ decision: "approve" }));
  const env = realSpawn.buildEnv(entry, gateOpts.anchors, gateOpts.extraEnv, gateOpts.envScope);
  assert.strictEqual(env[LIMIT_ENV], "110000");
});
caseEnd();

// ---- procedure ----------------------------------------------------------------------------
caseBegin("procedure-ask-ends-gate-blocked", "bin/worker-dispatch/workers/commit-push/procedure.js");
test("procedure: an ask from the commit gate ends gate_blocked with 'workflow-gate asked: ...', no git commit", () => {
  const { ctx, payload } = fixture();
  const calls = [];
  handler = (_entry, opts) => {
    const args = opts.args || [];
    calls.push({ command: opts.command, args });
    if (opts.command === "node" && opts.script === "workflowGate") return ok(hso("ask", "workflow-gate: decision time limit reached"));
    const a = args.join(" ");
    if (a === "rev-parse --abbrev-ref HEAD") return ok("feature/2849\n");
    if (a === "diff --cached --stat") return ok(" a.txt | 1 +\n");
    return ok("");
  };
  const res = procedure().run(payload, ctx);
  assert.strictEqual(res.status, "gate_blocked");
  assert.strictEqual(res.summary, "commit refused by workflow-gate: workflow-gate asked: workflow-gate: decision time limit reached");
  assert.ok(!calls.some((c) => c.command === "git" && c.args.includes("commit")), "git commit is never run");
});
caseEnd();
