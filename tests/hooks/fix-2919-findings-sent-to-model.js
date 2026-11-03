"use strict";
// Tests: hooks/stop-l2-findings-display.js, hooks/lib/supervisor-state-writer/alert.js, bin/session-close-render-sc7.js
// Tags: fix-2919, supervisor, stop-hook, session-close, sc-7, findings, scope:issue-specific, TL2, pwsh-not-required
// #2919: the Stop hook hands alert findings to the model only (additionalContext), yet it wrote
// findings_surfaced_at, so session-close SC-7 rendered nothing for the user. The hook now writes
// findings_sent_to_model_at; findings_surfaced_at stays for SC-7. Both markers keep their first
// value, a null patch clears them, and the #1607 pause leaves both null.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const HOOK = path.join(ROOT, "hooks", "stop-l2-findings-display.js");
const RENDER = path.join(ROOT, "bin", "session-close-render-sc7.js");
const ALERT_CLI = path.join(ROOT, "bin", "supervisor-write-alert");
const W = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer"));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "fix2919-"));
const SAVED = { AGENTS_MAIN_ROOT: process.env.AGENTS_MAIN_ROOT, CLAUDE_TRANSCRIPT_BASE_DIR: process.env.CLAUDE_TRANSCRIPT_BASE_DIR };
fs.mkdirSync(path.join(TMP, "transcripts"));
fs.mkdirSync(path.join(TMP, "cfg"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.AGENTS_MAIN_ROOT = path.join(TMP, "cfg");
after(() => {
  for (const [k, v] of Object.entries(SAVED)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  restoreIsolation();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const FINDING = { categories: ["workflow"], severity: "warning", detail: "fix-2919 finding", reporter: "test" };
let n = 0;
const nextSid = (tag) => `f2919-${tag}-${++n}`;

function env() {
  const e = Object.assign({}, process.env);
  delete e.CLAUDE_CODE_SESSION_ID;
  return e;
}
function run(file, args, input) {
  const r = spawnSync(process.execPath, [file, ...args], { input: input || "", encoding: "utf8", timeout: 60000, env: env(), cwd: TMP });
  if (r.error) throw new Error(`${path.basename(file)} did not run: ${r.error.message}`);
  return { code: r.status, out: r.stdout || "", err: r.stderr || "" };
}
const stop = (sid) => run(HOOK, [], JSON.stringify({ stop_hook_active: false, session_id: sid, transcript_path: "" }));
const alertOf = (sid) => (W.readState(sid) || {}).alert || {};

// seedDone(tag, extra) -> sid with alert_phase done and one warning finding.
function seedDone(tag, extra) {
  const sid = nextSid(tag);
  assert.strictEqual(W.writeAlertState(sid, Object.assign({ findings: [FINDING], alert_phase: "done" }, extra || {})), true, "seed");
  return sid;
}
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

caseBegin("stop-hook-marks-sent-to-model-not-surfaced", "hooks/stop-l2-findings-display.js");
test("stop-hook-marks-sent-to-model-not-surfaced", () => {
  const sid = seedDone("n1");
  const r = stop(sid);
  assert.strictEqual(r.code, 0, r.err);
  assert.ok(r.out.includes("additionalContext"), `the hook must hand the findings to the model: ${r.out}`);
  const al = alertOf(sid);
  assert.strictEqual(typeof al.findings_sent_to_model_at, "string", `findings_sent_to_model_at not set: ${JSON.stringify(al)}`);
  assert.strictEqual(al.findings_surfaced_at, null, "findings_surfaced_at must stay null: only the model saw the findings");
});
caseEnd();

caseBegin("sc7-still-renders-after-the-stop-hook-ran", "bin/session-close-render-sc7.js");
test("sc7-still-renders-after-the-stop-hook-ran", () => {
  const sid = seedDone("n2");
  assert.strictEqual(stop(sid).code, 0);
  const r = run(RENDER, ["--session", sid]);
  assert.strictEqual(r.code, 0, r.err);
  assert.ok(r.out.trim() !== "", `SC-7 must render the findings for the user after the Stop hook: ${JSON.stringify(alertOf(sid))}`);
});
caseEnd();

caseBegin("second-stop-is-silent-after-sent-to-model", "hooks/stop-l2-findings-display.js");
test("second-stop-is-silent-after-sent-to-model", () => {
  const sid = seedDone("n3");
  assert.ok(stop(sid).out.includes("additionalContext"), "fixture: the first Stop hands the findings over");
  const second = stop(sid);
  assert.strictEqual(second.code, 0);
  assert.strictEqual(second.out.trim(), "", "the hook must not fire again");
  assert.strictEqual(alertOf(sid).findings_surfaced_at, null, "the repeat Stop must not mark surfaced either");
});
caseEnd();

caseBegin("stop-is-silent-when-only-surfaced-is-set", "hooks/stop-l2-findings-display.js");
test("stop-is-silent-when-only-surfaced-is-set", () => {
  const sid = seedDone("n4", { findings_surfaced_at: "2020-01-01T00:00:00.000Z" });
  const r = stop(sid);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.out.trim(), "", `SC-7 already showed the findings: ${r.out}`);
});
caseEnd();

caseBegin("both-markers-keep-their-first-value", "hooks/lib/supervisor-state-writer/alert.js");
test("both-markers-keep-their-first-value", () => {
  const sid = seedDone("e1");
  const mark = () => run(ALERT_CLI, ["--session-id", sid, "--mark-findings-surfaced"]);
  assert.strictEqual(mark().code, 0);
  const first = alertOf(sid).findings_surfaced_at;
  assert.strictEqual(typeof first, "string", "fixture: the CLI marks surfaced");
  sleep(25);
  assert.strictEqual(mark().code, 0);
  assert.strictEqual(alertOf(sid).findings_surfaced_at, first, "a second --mark-findings-surfaced must keep the first time");

  const a = "2021-01-01T00:00:00.000Z";
  assert.strictEqual(W.writeAlertState(sid, { findings_sent_to_model_at: a }), true, "findings_sent_to_model_at must be a patch key");
  assert.strictEqual(W.writeAlertState(sid, { findings_sent_to_model_at: "2022-01-01T00:00:00.000Z" }), true);
  assert.strictEqual(alertOf(sid).findings_sent_to_model_at, a, "findings_sent_to_model_at must keep its first value");
});
caseEnd();

caseBegin("null-patch-clears-both-markers", "hooks/lib/supervisor-state-writer/alert.js");
test("null-patch-clears-both-markers", () => {
  const sid = seedDone("e2", { findings_surfaced_at: "2020-01-01T00:00:00.000Z" });
  assert.strictEqual(W.writeAlertState(sid, { findings_surfaced_at: null }), true);
  assert.strictEqual(alertOf(sid).findings_surfaced_at, null, "a null patch clears findings_surfaced_at");
  assert.strictEqual(W.writeAlertState(sid, { findings_sent_to_model_at: "2020-01-01T00:00:00.000Z" }), true,
    "findings_sent_to_model_at must be a patch key");
  assert.strictEqual(W.writeAlertState(sid, { findings_sent_to_model_at: null }), true);
  assert.strictEqual(alertOf(sid).findings_sent_to_model_at, null, "a null patch clears findings_sent_to_model_at");
});
caseEnd();

caseBegin("non-string-marker-values-are-rejected", "hooks/lib/supervisor-state-writer/alert.js");
test("non-string-marker-values-are-rejected", () => {
  const sid = seedDone("e3");
  // The string write proves the key is accepted, so the rejections below are type checks.
  assert.strictEqual(W.writeAlertState(sid, { findings_sent_to_model_at: "2020-01-01T00:00:00.000Z" }), true,
    "findings_sent_to_model_at must be a patch key");
  for (const key of ["findings_surfaced_at", "findings_sent_to_model_at"]) {
    for (const bad of [5, true, {}, []]) {
      assert.strictEqual(W.writeAlertState(sid, { [key]: bad }), false, `${key}=${JSON.stringify(bad)} must be rejected`);
    }
  }
});
caseEnd();

caseBegin("pause-leaves-both-markers-null", "hooks/stop-l2-findings-display.js");
test("pause-leaves-both-markers-null", () => {
  const sid = seedDone("b1");
  const { writePauseMarker, isPauseActive } = require(path.join(ROOT, "hooks", "lib", "next-step-pause-marker.js"));
  assert.ok(writePauseMarker(sid, { reason: "fix-2919 pause fixture" }), "fixture: pause marker written");
  assert.strictEqual(isPauseActive(sid, null), true, "fixture: the pause is active");
  const r = stop(sid);
  assert.strictEqual(r.code, 0);
  assert.strictEqual(r.out.trim(), "", "a paused session hands nothing over");
  const al = alertOf(sid);
  assert.ok("findings_sent_to_model_at" in al, `findings_sent_to_model_at must default to null: ${JSON.stringify(al)}`);
  assert.strictEqual(al.findings_sent_to_model_at, null);
  assert.strictEqual(al.findings_surfaced_at, null);
});
caseEnd();
