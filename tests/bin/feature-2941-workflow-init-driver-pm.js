"use strict";
// tests/bin/feature-2941-workflow-init-driver-pm.js
// Tests: bin/workflow/workflow-init-driver
// Tags: TL2, scope:issue-specific, pm-session, workflow-init, driver
// #2941: the driver is the last line against /wf-init reached through the Skill tool in a PM
// session. A session with the PM mark (active or archived) gets ACTION=blocked REASON=pm-session.
// The run has no tokens and a gh that always fails, so nothing reaches a real forge.
// TL3 gap: a live Skill-tool call of wf-init in a PM session is not driven; the driver runs directly.

const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-drv-"));
const bin = path.join(tmp, "bin");
const repo = path.join(tmp, "repo");
const transcripts = path.join(tmp, "transcripts");
for (const d of [bin, repo, transcripts]) fs.mkdirSync(d);
fs.writeFileSync(path.join(bin, "gh"), "#!/bin/bash\necho 'fake gh: offline' >&2\nexit 1\n", { mode: 0o755 });
gitInit(repo);
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const DRIVER = path.join(P.ROOT, "bin", "workflow", "workflow-init-driver");

// drive(sid, extraEnv) -> {kv, out} of one driver run with CLAUDE_CODE_SESSION_ID=sid.
function drive(sid, extraEnv = {}) {
  const env = { ...process.env, CLAUDE_CODE_SESSION_ID: sid, CLAUDE_TRANSCRIPT_BASE_DIR: transcripts, ...extraEnv };
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  env[key] = `${bin}${path.delimiter}${env[key]}`;
  const r = cp.spawnSync(process.execPath, [DRIVER], { cwd: repo, env, encoding: "utf8", timeout: 60000 });
  const kv = {};
  for (const line of String(r.stdout || "").split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m && !(m[1] in kv)) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1");
  }
  return { kv, out: `rc=${r.status} err=${r.error ? r.error.message : ""} stdout=${String(r.stdout).slice(0, 400)} stderr=${String(r.stderr).slice(0, 300)}` };
}

const SID = { active: P.uuid(0x29417001), archived: P.uuid(0x29417002), plain: P.uuid(0x29417003) };

caseBegin("driver-blocks-pm-session", "bin/workflow/workflow-init-driver");
for (const [kind, at] of [["active", null], ["archived", "2026-11-02T00:00:00.000Z"]]) {
  test(`a ${kind} PM session -> ACTION=blocked REASON=pm-session`, () => {
    P.seedPm(SID[kind], P.pm({ tag: `PM-drv${kind[0]}`, issues: [2941], archived_at: at }));
    const r = drive(SID[kind]);
    assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["blocked", "pm-session"], r.out);
    assert.strictEqual(P.wfInitStatus(SID[kind]), "pending", "the PM session must not begin a workflow");
  });
}
test("control: a plain session is not refused as pm-session", () => {
  P.seedState(SID.plain);
  const r = drive(SID.plain, { NON_GITHUB: "1" });
  assert.ok(r.kv.ACTION, `the driver printed no ACTION: ${r.out}`);
  assert.notStrictEqual(r.kv.REASON, "pm-session", r.out);
});
caseEnd();
