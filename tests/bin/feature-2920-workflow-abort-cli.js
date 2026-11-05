#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/adopt-session-state, bin/lib/resume-session/render.js, bin/workflow/lib/adopt-session-state/abort-upstreams.js
// Tags: TL2, workflow-abort, adopt-session-state, cli, regression-2920, scope:issue-specific, pwsh-not-required
// #2920 S8-(2): `adopt-session-state --session <heir> --abort-upstreams` aborts every upstream
// selectAbortTargets picks for the running heir (origin abort-cli), prints one line per target,
// and adopts nothing. Neither it nor --from adoption touches the WIP mark (no wip-state / gh).
// TL3 gap (what this test does NOT catch):
// - the /resume-session SKILL.md line that points the user at this CLI.

const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2920c-"));
after(() => {
  restore();
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
});

const X = require("../hooks/feature-2920-workflow-abort/fixture");
const CLI = path.join(X.ROOT, "bin", "workflow", "adopt-session-state");
const MODULE = path.join(X.ROOT, "bin", "workflow", "lib", "adopt-session-state", "abort-upstreams.js");

function runCli(args) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  if (r.error) throw new Error(`adopt-session-state did not run: ${r.error.message}`);
  return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "",
    show: `rc=${r.status} stdout=${String(r.stdout).slice(0, 500)} stderr=${String(r.stderr).slice(0, 300)}` };
}
// chain(prefix) — heir C with live upstreams A (oldest) and B.
function chain(prefix) {
  const [a, b, c] = [`${prefix}-a`, `${prefix}-b`, `${prefix}-c`];
  X.seedPlain(a);
  X.seedPlain(b);
  X.seedPlain(c);
  const s = X.raw(c);
  Object.assign(s, { previous_session_ids: [a, b], upstream_session_id: b, first_session_id: a });
  X.writeRaw(c, s);
  return { a, b, c };
}
const linesNaming = (out, sid) => out.split(/\r?\n/).filter((l) => l.includes(sid));

caseBegin("abort-upstreams-records-each-target", "bin/workflow/adopt-session-state");
test("S8-(2): every live upstream gets one abort-cli abort naming the heir, one output line each", () => {
  const { a, b, c } = chain("cli1");
  const heirBefore = X.bytes(c);
  const r = runCli(["--session", c, "--abort-upstreams"]);
  assert.strictEqual(r.code, 0, r.show);
  for (const t of [a, b]) {
    assert.strictEqual(linesNaming(r.stdout, t).length, 1, `one line for ${t}: ${r.show}`);
    assert.deepStrictEqual(X.abortEventsOf(t).map((e) => [e.origin, e.heir_session_id]), [["abort-cli", c]], t);
  }
  assert.strictEqual(X.bytes(c), heirBefore, "the heir state changed: --abort-upstreams must not adopt");
});
test("S8-(2) idempotency: a second run aborts nothing new", () => {
  const { a, b, c } = chain("cli2");
  assert.strictEqual(runCli(["--session", c, "--abort-upstreams"]).code, 0, "first run");
  const r = runCli(["--session", c, "--abort-upstreams"]);
  assert.strictEqual(r.code, 0, r.show);
  assert.deepStrictEqual([a, b].map((t) => X.abortEventsOf(t).length), [1, 1], "abort events after the second run");
});
caseEnd();

caseBegin("abort-upstreams-zero-targets", "bin/workflow/adopt-session-state");
test("S8-(2): a heir without upstreams reports 0 targets and exits 0", () => {
  X.seedPlain("cli-alone");
  const before = X.bytes("cli-alone");
  const r = runCli(["--session", "cli-alone", "--abort-upstreams"]);
  assert.strictEqual(r.code, 0, r.show);
  assert.ok(/\b0\b/.test(r.stdout), `the output must say 0 targets: ${r.show}`);
  assert.strictEqual(X.bytes("cli-alone"), before, "the heir state changed");
});
caseEnd();

caseBegin("abort-upstreams-rejects-bad-sid", "bin/workflow/adopt-session-state");
test("S8-(2) security: a traversal-shaped --session exits non-zero and writes nothing", () => {
  const before = fs.readdirSync(process.env.WORKFLOW_STATE_DIR).sort();
  const r = runCli(["--session", "../escape", "--abort-upstreams"]);
  assert.notStrictEqual(r.code, 0, r.show);
  assert.deepStrictEqual(fs.readdirSync(process.env.WORKFLOW_STATE_DIR).sort(), before, "the state dir changed");
  assert.strictEqual(fs.existsSync(path.join(path.dirname(process.env.WORKFLOW_STATE_DIR), "escape.json")), false, "escaped write");
});
caseEnd();

// A logging `gh` first on PATH and a logging WIP_STATE_SH: wip-state.sh reaches GitHub only via gh,
// so an empty log after a run means neither path touched the WIP mark.
const STUB_DIR = path.join(NEUTRAL, "stub-bin");
const GH_LOG = path.join(NEUTRAL, "gh-calls.log");
fs.mkdirSync(STUB_DIR);
fs.writeFileSync(path.join(STUB_DIR, "gh"), '#!/usr/bin/env bash\necho "gh $*" >> "$GH_STUB_LOG"\nexit 1\n', { mode: 0o755 });
fs.writeFileSync(path.join(STUB_DIR, "gh.cmd"), '@echo gh %* >> "%GH_STUB_LOG%"\r\n@exit /b 1\r\n');
fs.writeFileSync(path.join(STUB_DIR, "wip-state.sh"), '#!/usr/bin/env bash\necho "wip-state $*" >> "$GH_STUB_LOG"\n', { mode: 0o755 });
function stubEnv() {
  const env = Object.assign({}, process.env, { GH_STUB_LOG: GH_LOG, WIP_STATE_SH: path.join(STUB_DIR, "wip-state.sh") });
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  env[key] = STUB_DIR + path.delimiter + env[key];
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}
const ghCalls = () => (fs.existsSync(GH_LOG) ? fs.readFileSync(GH_LOG, "utf8").trim() : "");
function runStubbed(args) {
  fs.rmSync(GH_LOG, { force: true });
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: NEUTRAL, env: stubEnv(), encoding: "utf8", timeout: 60000 });
  if (r.error) throw new Error(`adopt-session-state did not run: ${r.error.message}`);
  return { code: r.status, show: `rc=${r.status} stdout=${String(r.stdout).slice(0, 400)} stderr=${String(r.stderr).slice(0, 300)}` };
}
const withIssues = (sid, issues) => { const s = X.raw(sid); s.closes_issues = issues; X.writeRaw(sid, s); };

caseBegin("abort-paths-leave-wip-alone", "bin/workflow/adopt-session-state");
test("control: the gh stub on PATH is what a bash child resolves, and it logs", () => {
  fs.rmSync(GH_LOG, { force: true });
  const r = spawnSync("bash", ["-c", "gh probe 2920"], { cwd: NEUTRAL, env: stubEnv(), encoding: "utf8", timeout: 30000 });
  assert.strictEqual(r.status, 1, `stub exit: ${r.stderr}`);
  assert.strictEqual(ghCalls(), "gh probe 2920", "the stub did not log");
});
test("S8-(2) negative: --abort-upstreams records the aborts but never calls wip-state / gh", () => {
  const { a, b, c } = chain("cliwip");
  withIssues(a, [2920]);
  withIssues(b, [2921]);
  const r = runStubbed(["--session", c, "--abort-upstreams"]);
  assert.strictEqual(r.code, 0, r.show);
  assert.deepStrictEqual([a, b].map((t) => X.abortEventsOf(t).length), [1, 1], `the aborts were recorded: ${r.show}`);
  assert.strictEqual(ghCalls(), "", "the abort CLI touched the WIP mark");
});
test("S8-(1) negative: adopting with --from aborts the upstream but never calls wip-state / gh", () => {
  const F = require("../hooks/feature-2304-inheritance-state-copy/fixture");
  F.seedUpstream("cliwip-up");
  F.seedDownstream("cliwip-heir");
  const r = runStubbed(["--session", "cliwip-heir", "--from", "cliwip-up"]);
  assert.strictEqual(r.code, 0, r.show);
  assert.deepStrictEqual(X.abortEventsOf("cliwip-up").map((e) => e.origin), ["adopt-auto"], `the upstream was aborted: ${r.show}`);
  assert.strictEqual(ghCalls(), "", "adopt touched the WIP mark");
});
test("negative: the abort / adopt modules carry no wip-state call site", () => {
  const files = ["bin/workflow/lib/adopt-session-state/abort-upstreams.js", "hooks/workflow-state/workflow-abort.js",
    "hooks/workflow-state/inheritance/adopt.js", "bin/workflow/adopt-session-state"];
  for (const f of files) {
    const p = path.join(X.ROOT, f);
    assert.ok(fs.existsSync(p), `${f} is missing`);
    assert.ok(!/wip-state|WIP_STATE_SH/.test(fs.readFileSync(p, "utf8")), `${f} references wip-state`);
  }
});
caseEnd();

// A --require preload failing every rename onto <FAIL_SID>.json (the atomic state write's last step),
// so recording the abort on that upstream fails inside the real CLI process.
const PRELOAD = path.join(NEUTRAL, "fail-rename.js");
fs.writeFileSync(PRELOAD, [
  'const fs = require("fs"); const path = require("path"); const real = fs.renameSync;',
  'fs.renameSync = function (from, to) {',
  '  if (path.basename(String(to)) === process.env.FAIL_SID + ".json") throw Object.assign(new Error("EIO: injected"), { code: "EIO" });',
  '  return real.apply(fs, arguments);',
  '};', '',
].join("\n"));

caseBegin("from-prints-unrecorded-abort-warning", "bin/workflow/adopt-session-state");
test("S8-(1) error: a failed upstream abort still adopts and prints the Warning on stdout", () => {
  const F = require("../hooks/feature-2304-inheritance-state-copy/fixture");
  F.seedUpstream("cliwf-up");
  F.seedDownstream("cliwf-heir");
  const env = Object.assign({}, process.env, { FAIL_SID: "cliwf-up" });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, ["--require", PRELOAD, CLI, "--session", "cliwf-heir", "--from", "cliwf-up"],
    { cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `rc=${r.status} stdout=${r.stdout} stderr=${r.stderr}`);
  assert.ok(/Adopted workflow state from session cliwf-up/.test(r.stdout), `adoption line: ${r.stdout}`);
  assert.ok(/^Warning: upstream cliwf-up could not be recorded as aborted \(.+\)/m.test(r.stdout), `Warning line: ${r.stdout}`);
  assert.strictEqual(X.abortEventsOf("cliwf-up").length, 0, "the injected failure did not hit the upstream write");
});
test("S8-(1): a recorded upstream abort prints no Warning", () => {
  const F = require("../hooks/feature-2304-inheritance-state-copy/fixture");
  F.seedUpstream("cliwf-up2");
  F.seedDownstream("cliwf-heir2");
  const r = runCli(["--session", "cliwf-heir2", "--from", "cliwf-up2"]);
  assert.strictEqual(r.code, 0, r.show);
  assert.ok(!/Warning/.test(r.stdout), `unexpected Warning: ${r.stdout}`);
});
caseEnd();

caseBegin("abort-upstreams-unreadable-heir", "bin/workflow/adopt-session-state");
test("S8-(2) error: a --session with no readable state exits non-zero and says Could not select", () => {
  const before = fs.readdirSync(process.env.WORKFLOW_STATE_DIR).sort();
  const r = runCli(["--session", "cli-no-state-file", "--abort-upstreams"]);
  assert.notStrictEqual(r.code, 0, r.show);
  assert.ok(/Could not select/.test(r.stderr + r.stdout), `the output must say Could not select: ${r.show}`);
  assert.ok(!/Upstreams to abort: 0/.test(r.stdout), `must not report 0 targets: ${r.show}`);
  assert.deepStrictEqual(fs.readdirSync(process.env.WORKFLOW_STATE_DIR).sort(), before, "the state dir changed");
});
caseEnd();

caseBegin("abort-upstreams-module","bin/workflow/lib/adopt-session-state/abort-upstreams.js");
test("S8-(2): argument handling and output live in abort-upstreams.js", () => {
  assert.ok(fs.existsSync(MODULE), `${MODULE} is missing`);
  assert.doesNotThrow(() => require(MODULE), "abort-upstreams.js must load");
});
caseEnd();
