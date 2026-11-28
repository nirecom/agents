"use strict";
// Tests: settings.json, hooks/workflow-mark/conventional-audit-chosen-handler.js
// Tags: TL3, run-e2e, scope:issue-specific, issue-3168, hook, workflow-mark, permission, pre-confirm-audit
// #3168 on a real `claude -p` host: the model runs echo "<<WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN: outline <reason>>>" via Bash.
// The fixture settings copy the real `ask` rule line and the real PostToolUse registration of hooks/workflow-mark.js from
// the worktree settings.json. Both runs also allow that exact command, so the only difference is the ask line:
// (a) with the ask line the host asks, the headless run cannot approve, the echo never runs and nothing is armed;
// (b) without it the allowed echo runs, the real PostToolUse hook fires and arms the conventional (fallback) audit run.
// TL3 gap (what this test does NOT catch):
// - an interactive user pressing approve in the permission dialog (headless -p can only show that the host asks and denies);
// - the real user settings and the deployed ~/.claude tree (--setting-sources project keeps them out on purpose).

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
// Skip gates (rules/test/claude-e2e.md): RUN_TL3 off, or no claude on PATH -> exit 77 before any test is declared.
if (spawnSync("bash", [path.join(ROOT, "bin", "get-config-var"), "--is-off", "RUN_TL3", "off"], { encoding: "utf8" }).status === 0) process.exit(77);
const probe = spawnSync("claude", ["--version"], { encoding: "utf8", timeout: 30000 });
if (probe.error || probe.status !== 0) process.exit(77);

const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.CLAUDECODE;
const restore = isolate();
const D = require("./feature-2853-pre-confirm-audit/driver");
const { X } = D;
after(() => { restore(); });

const NAME = "WORKFLOW_CONVENTIONAL_AUDIT_CHOSEN";
const fwd = (p) => String(p).replace(/\\/g, "/");
const REAL = JSON.parse(fs.readFileSync(path.join(ROOT, "settings.json"), "utf8"));
const ASK = (REAL.permissions.ask || []).filter((r) => r.includes(NAME));
// The real PostToolUse entry that registers workflow-mark.js: its matcher and hook object, the hook path made absolute
// (the child's AGENTS_MAIN_ROOT is the fixture's .env root, not this tree).
const POST = (REAL.hooks.PostToolUse || []).map((e) => ({ matcher: e.matcher, hook: (e.hooks || []).find((h) => /hooks\/workflow-mark\.js"/.test(h.command)) }))
  .filter((e) => e.hook);
const CMD = `echo "<<${NAME}: outline TL3 the PM did not answer twice>>"`;

// settings(withAsk) -> the minimal project settings: the exact-command allow, the real hook entry, and the real ask line if asked.
function settings(withAsk, cmd) {
  const hook = Object.assign({}, POST[0].hook, { command: POST[0].hook.command.replace("$AGENTS_MAIN_ROOT", fwd(ROOT)) });
  const permissions = { allow: [`Bash(${cmd})`] };
  if (withAsk) permissions.ask = ASK.slice();
  return { permissions, hooks: { PostToolUse: [{ matcher: POST[0].matcher, hooks: [hook] }] } };
}
// host(sid, withAsk) -> {json, out, err, rc} of one real `claude -p` run in its own project dir under the isolated state dir.
function host(sid, withAsk) {
  const cmd = CMD;
  const dir = fs.mkdtempSync(path.join(X.TDIR, "tl3-proj-"));
  fs.mkdirSync(path.join(dir, ".claude"));
  fs.writeFileSync(path.join(dir, ".claude", "settings.json"), JSON.stringify(settings(withAsk, cmd), null, 2));
  const env = D.childEnv({}, {});
  delete env.CLAUDECODE;
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.NODE_OPTIONS;
  const prompt = `Run exactly this Bash command and nothing else, then stop: ${cmd}`;
  const r = spawnSync("claude", ["-p", prompt, "--session-id", sid, "--setting-sources", "project", "--output-format", "json", "--max-turns", "3"], {
    env, cwd: dir, encoding: "utf8", timeout: 180000,
  });
  let json = null;
  try { json = JSON.parse(String(r.stdout || "").trim()); } catch (_) { json = null; }
  return { json, out: r.stdout || "", err: r.stderr || "", rc: r.status, error: r.error };
}
const findings = (sid) => {
  const st = require(path.join(ROOT, "hooks/lib/supervisor-state-writer")).readState(sid) || {};
  return (st.audit && st.audit.findings) || [];
};
const fallbackOf = (sid) => findings(sid).filter((f) => f && f.reporter === "user:pm-review-fallback");
const denialsOf = (r) => ((r.json && r.json.permission_denials) || []).filter((d) => JSON.stringify(d).includes(NAME));
const show = (r, sid) => `rc=${r.rc} error=${r.error && r.error.code}\nout=${r.out.slice(0, 1500)}\nerr=${r.err.slice(0, 600)}\nfindings=${JSON.stringify(findings(sid)).slice(0, 800)}`;

caseBegin("settings-real-ask-and-hook-lines", "settings.json");
test("C0 the worktree settings.json has exactly one ask line for the sentinel and one PostToolUse entry for workflow-mark.js", () => {
  assert.strictEqual(ASK.length, 1, `ask lines naming ${NAME}: ${JSON.stringify(ASK)}`);
  assert.strictEqual(ASK[0], `Bash(echo "<<${NAME}: *>>")`);
  assert.strictEqual(POST.length, 1, `PostToolUse entries with workflow-mark.js: ${JSON.stringify(POST)}`);
  assert.ok(new RegExp(`^(${POST[0].matcher})$`).test("Bash"), `the matcher reaches Bash: ${POST[0].matcher}`);
});
test("C1 (a) real host with the real ask line: the echo is not run without the user's approval and nothing is armed", () => {
  const s = X.sessionAt("outline", { audit: false });
  const before = D.audit(s.sid).audit_run_id || "";
  const r = host(s.sid, true);
  assert.ok(r.json, `claude -p gave no JSON result: ${show(r, s.sid)}`);
  assert.ok(denialsOf(r).length >= 1, `the host did not hold the echo for permission (no permission_denials entry): ${show(r, s.sid)}`);
  assert.strictEqual(fallbackOf(s.sid).length, 0, `a fallback run was armed without approval: ${show(r, s.sid)}`);
  assert.strictEqual(D.audit(s.sid).audit_run_id || "", before, `the audit run changed: ${show(r, s.sid)}`);
});
caseEnd();

caseBegin("host-post-tool-use-arms-fallback", "hooks/workflow-mark/conventional-audit-chosen-handler.js");
test("C2 (b) real host where that exact command is allowed: the PostToolUse hook fires and arms the conventional audit run", () => {
  const s = X.sessionAt("outline", { audit: false });
  const r = host(s.sid, false);
  assert.ok(r.json, `claude -p gave no JSON result: ${show(r, s.sid)}`);
  assert.strictEqual(denialsOf(r).length, 0, `the allowed echo was denied: ${show(r, s.sid)}`);
  const runId = D.audit(s.sid).audit_run_id || "";
  assert.notStrictEqual(runId, "", `no audit run armed: ${show(r, s.sid)}`);
  const fb = fallbackOf(s.sid).filter((f) => String(f.detail || "").includes(runId));
  assert.strictEqual(fb.length, 1, `the fallback finding names the new run ${runId}: ${show(r, s.sid)}`);
});
caseEnd();
