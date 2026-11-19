"use strict";
// tests/hooks/feature-2941-wf-init-mark-pm.js
// Tests: hooks/user-prompt-submit-wf-init-mark.js
// Tags: TL2, scope:issue-specific, pm-session, wf-init, userpromptsubmit, hook-registration
// #2941: wf-init-mark runs in parallel with the PM writer, so it judges the PM mark itself: a
// typed /wf-init in a PM session (active or archived) never sets workflow_init in_progress.
// TL3 gap (what this test does NOT catch):
// - synthetic stdin; a live session's parallel UserPromptSubmit ordering is not driven.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-wfmark-"));
fs.mkdirSync(path.join(tmp, "transcripts"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const HOOK = path.join(P.ROOT, "hooks", "user-prompt-submit-wf-init-mark.js");
const run = (sid, prompt) => {
  const env = { ...process.env, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(tmp, "transcripts") };
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: sid, transcript_path: "", prompt });
  return cp.spawnSync(process.execPath, [HOOK], { input, cwd: tmp, env, encoding: "utf8", timeout: 30000 });
};
const PROMPTS = [["bare", "/wf-init #2941"], ["wrapped", P.wrapped("wf-init", "#2941")]];

caseBegin("wf-init-mark-skips-pm-session", "hooks/user-prompt-submit-wf-init-mark.js");
test("precondition: `pm` is a registered top-level key (else the skip would pass on a throw)", () => {
  assert.ok(P.persistedKeys().includes("pm"), `PERSISTED_TOP_LEVEL_KEYS lacks pm: ${JSON.stringify(P.persistedKeys())}`);
});
let n = 0;
for (const [kind, at] of [["active", null], ["archived", "2026-11-02T00:00:00.000Z"]]) {
  for (const [form, prompt] of PROMPTS) {
    const i = ++n;
    const sid = P.uuid(0x29418000 + i);
    test(`a ${kind} PM session, ${form} /wf-init -> workflow_init stays pending`, () => {
      P.seedPm(sid, P.pm({ tag: `PM-mk${i}`, issues: [2941], archived_at: at }));
      const r = run(sid, prompt);
      assert.strictEqual(r.status, 0, r.stderr);
      assert.strictEqual(P.wfInitStatus(sid), "pending");
      assert.ok(P.readPm(sid), "the pm key must survive");
    });
  }
}
test("control: a plain session gets workflow_init in_progress from the same prompt", () => {
  const sid = P.uuid(0x29418100);
  P.seedState(sid);
  const r = run(sid, "/wf-init #2941");
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(P.wfInitStatus(sid), "in_progress");
});
caseEnd();
