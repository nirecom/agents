"use strict";
// review-tests-handler outcomes that need a review scope (#2824 Step 2): WARNINGS_ACCEPTED ending in
// STALE_EVIDENCE or MANIFEST_UNAVAILABLE leaves review_tests unchanged and is UNAPPLIED; an accepted
// COMPLETE and a WARNINGS_ACCEPTED that clears recorded warnings stay INFO on the normal channel.
// The scope fixture follows tests/hooks/feature-2664-review-tests-recovery.js (one staged test file,
// a continuing marker pinned to the scope fingerprint, the glossary_check record a completion needs).
// The COMPLETE / WARNINGS "failed to write state" catches are reached with a state file that is not JSON.
// SKIPPED: the WARNINGS_ACCEPTED catch. Because: clearReviewTestsWarnings reads an unreadable state as
// NOTHING_TO_CLEAR (covered in review-tests.js) instead of throwing; no payload reaches it without a stub.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");
const O = require("../../lib/workflow-mark-output");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const ev = require(path.join(ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));
const S = (body) => `echo "<<WORKFLOW_${body}>>"`;
const ACCEPT = S("REVIEW_TESTS_WARNINGS_ACCEPTED: user accepts remaining gaps");

const git = (d, ...a) => {
  const r = spawnSync("git", ["-C", d, ...a], { encoding: "utf8", timeout: 30000 });
  if (r.status !== 0) throw new Error(`fixture: git ${a.join(" ")}: ${r.stderr}`);
};
function stage(d, rel, body) {
  fs.mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
  fs.writeFileSync(path.join(d, rel), `${body}\n`);
  git(d, "add", "--", rel);
}
let seq = 0;
// scopeRepo(X) -> a committed repo with tests/x.sh (Tests: hooks/impl.js) and hooks/impl.js staged.
function scopeRepo(X) {
  const d = path.join(X.TMP, `rt-scope-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  fs.writeFileSync(path.join(d, "README.md"), "seed\n");
  git(d, "add", "README.md");
  git(d, "-c", "user.email=t@example.invalid", "-c", "user.name=T", "commit", "-qm", "init");
  stage(d, "tests/x.sh", "#!/usr/bin/env bash\n# Tests: hooks/impl.js");
  stage(d, "hooks/impl.js", "impl");
  return d;
}
const fp = (d) => ev.computeReviewScopeFingerprint(d).fingerprint;
// seedInProgress(X, tag) -> sid with every step before review_tests complete and review_tests in_progress.
function seedInProgress(X, tag) {
  const sid = X.nextSid(tag);
  const steps = {};
  for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests"]) {
    steps[s] = { status: "complete" };
  }
  steps.review_tests = { status: "in_progress" };
  steps.write_code = { status: "complete" };
  for (const s of ["run_tests", "review_security", "docs", "review_docs", "user_verification", "cleanup", "pre_final_report_gate", "final_report"]) {
    steps[s] = { status: "pending" };
  }
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), JSON.stringify({ version: 1, session_id: sid, steps }));
  return sid;
}
function continuing(sid, d) {
  const dir = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "test-review-continuing.txt"), `1\n${fp(d)}\n`);
}
// glossary(sid, d) — the glossary_check record a review_tests completion crosses (#2529).
function glossary(sid, d) {
  spawnSync(process.execPath, [path.join(ROOT, "bin", "check-glossary-drift"), "--session", sid, "--step", "review_tests", "--record"],
    { cwd: d, env: { ...process.env, CLAUDE_PROJECT_DIR: d }, encoding: "utf8", timeout: 60000 });
}
// send(sid, cwd, command) -> {code, stdout, stderr}; the payload cwd is the review scope the handler reads.
function send(sid, cwd, command) {
  return O.runMark({ ...O.bashPayload(command, { sid }), cwd }, { cwd });
}
const status = (X, sid) => (((X.F.S.readState(sid) || {}).steps || {}).review_tests || {}).status;
function guard(X, label, fn) {
  try { X.record(label, fn()); } catch (e) { X.record(label, e.message); }
}
function expectRefused(X, label, sid, cwd, pattern) {
  const before = X.raw(sid);
  const r = send(sid, cwd, ACCEPT);
  if (X.raw(sid) !== before) X.record(label, "state changed by a refused WARNINGS_ACCEPTED");
  guard(X, label, () => O.unappliedFailure(r, pattern));
}

function refusals(X) {
  const d = scopeRepo(X);
  const stale = seedInProgress(X, "rt-stale");
  continuing(stale, d);
  stage(d, "tests/x.sh", "echo x changed after the review");
  expectRefused(X, "STALE_EVIDENCE", stale, d, /review scope changed[\s\S]*\/review-tests/);
  const d2 = scopeRepo(X);
  const noManifest = seedInProgress(X, "rt-nomanifest");
  continuing(noManifest, d2);
  const nogit = path.join(X.TMP, "rt-nogit").replace(/\\/g, "/");
  fs.mkdirSync(nogit, { recursive: true });
  expectRefused(X, "MANIFEST_UNAVAILABLE", noManifest, nogit, /manifest unavailable/);
  for (const [kind, body] of [["COMPLETE", `REVIEW_TESTS_COMPLETE: fingerprint=${fp(d2)}`],
    ["WARNINGS", `REVIEW_TESTS_WARNINGS: fingerprint=${fp(d2)} warnings=1`]]) {
    const sid = X.corruptState(`rt-corrupt-${kind}`);
    const before = X.raw(sid);
    const r = send(sid, d2, S(body));
    if (X.raw(sid) !== before) X.record(`${kind} state write fails`, "the unreadable state file was rewritten");
    guard(X, `${kind} state write fails`, () => O.unappliedFailure(r, /failed to write state[\s\S]*NOT recorded/));
  }
  X.check();
}

function applied(X) {
  const d = scopeRepo(X);
  const done = seedInProgress(X, "rt-complete");
  glossary(done, d);
  const rc = send(done, d, S(`REVIEW_TESTS_COMPLETE: fingerprint=${fp(d)}`));
  if (status(X, done) !== "complete") X.record("COMPLETE applied", `review_tests is ${status(X, done)}: ${rc.stdout}${rc.stderr}`);
  guard(X, "COMPLETE applied", () => O.infoFailure(rc, /review_tests: complete \(fingerprint/));

  const warned = seedInProgress(X, "rt-cleared");
  glossary(warned, d);
  const rw = send(warned, d, S(`REVIEW_TESTS_WARNINGS: fingerprint=${fp(d)} warnings=1`));
  guard(X, "WARNINGS recorded", () => O.infoFailure(rw, /reported warnings/));
  const ra = send(warned, d, ACCEPT);
  guard(X, "WARNINGS_CLEARED", () => O.infoFailure(ra, /warnings cleared/));
  X.check();
}

module.exports = { refusals, applied };
