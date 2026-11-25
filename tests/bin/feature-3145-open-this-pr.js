"use strict";
// tests/bin/feature-3145-open-this-pr.js
// Tests: bin/lib/finding-rules.js, bin/lib/this-pr-open.js
// Tags: worktree-notes, this-pr, open-this-pr, fixed-evidence, finding-rules, table-driven, stub-runner, scope:issue-specific, TL1
// #3145 S2/S3: openThisPrReason decides which this-pr findings are unsettled; readOpenThisPr reads
// the notes and asks fixedEvidence only through the injected runGit; resolveSessionNotesPath binds
// the notes to the trusted repo dir and refuses a cwd outside the session worktree.
// TL3 gap: a real write_code completion inside a live Claude session is not driven here;
// tests/hooks/feature-3145-write-code-this-pr-gate.js drives the hook path on fixtures.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../lib/this-pr-notes-fixture");

const TMP = F.setup("t3145-open");
const LIB = path.join(F.ROOT, "bin", "lib");
const M = require(path.join(F.ROOT, "hooks", "lib", "worktree-notes-sections.js"));
const SHA = "0123456789abcdef0123456789abcdef01234567";
const parse = (line) => M.scanSection(`## BugsFound\n${line}\n`, "BugsFound").entries[0];

// Every child_process entry point is counted while `counting` is on: readOpenThisPr must reach
// git only through the runGit it is given.
let counting = false;
let spawned = 0;
for (const name of ["execFileSync", "execSync", "spawnSync", "spawn", "execFile", "exec"]) {
  const orig = cp[name];
  cp[name] = function patched(...args) {
    if (counting) spawned += 1;
    return orig.apply(this, args);
  };
}

caseBegin("open-this-pr-reason-table", "bin/lib/finding-rules.js");
test("openThisPrReason: this-pr is open until fixed (verified) or user-accepted; a rescope is open until filed", () => {
  const { openThisPrReason } = require(path.join(LIB, "finding-rules.js"));
  const T = (body, o) => F.entry(body, Object.assign({ base: SHA }, o));
  const ROWS = [
    ["this-pr, no terminal", T("a"), false, "this-pr-unfixed"],
    ["this-pr low severity, no terminal (severity is ignored)", T("a").replace("severity: high", "severity: low"), false, "this-pr-unfixed"],
    ["this-pr fixed, verified", T("a", { terminal: "<!-- disposed: fixed -->" }), true, null],
    ["this-pr fixed, unverified", T("a", { terminal: "<!-- disposed: fixed -->" }), false, "fixed-unverified"],
    ["this-pr user-accepted", T("a", { terminal: "<!-- user-accepted: checked by hand -->" }), false, null],
    ["this-pr user-accepted, verified flag set", T("a", { terminal: "<!-- user-accepted: checked by hand -->" }), true, null],
    ["this-pr retired known-limits", T("a", { terminal: "<!-- disposed: known-limits -->" }), false, "this-pr-unfixed"],
    ["this-pr discard", T("a", { terminal: "<!-- disposed: discard -->" }), false, "this-pr-unfixed"],
    ["this-pr handed-off", T("a", { terminal: "<!-- disposed: handed-off -->" }), false, "this-pr-unfixed"],
    ["this-pr promoted (terminal other than fixed)", T("a", { terminal: "<!-- promoted: #12 -->" }), false, "this-pr-unfixed"],
    ["rescoped, promoted", T("a", { scope: "other", rescoped: true, terminal: "<!-- promoted: #9 -->" }), false, null],
    ["rescoped, not filed", T("a", { scope: "other", rescoped: true }), false, "rescoped-unfiled"],
    ["rescoped, user-accepted", T("a", { scope: "other", rescoped: true, terminal: "<!-- user-accepted: ok -->" }), false, null],
    ["other, no terminal", T("a", { scope: "other" }), false, null],
    ["other, fixed and unverified", T("a", { scope: "other", terminal: "<!-- disposed: fixed -->" }), false, null],
  ];
  for (const [name, line, fixedVerified, want] of ROWS) {
    const e = parse(line);
    assert.ok(e, `${name}: parsed`);
    assert.strictEqual(openThisPrReason(e, { fixedVerified }), want, name);
  }
});
caseEnd();

caseBegin("classify-has-no-dispose-in-pr", "bin/lib/finding-rules.js");
test("classify never returns dispose-in-pr; pr-scope does not change the class", () => {
  const { classify } = require(path.join(LIB, "finding-rules.js"));
  for (const severity of ["high", "medium", "low", "not-defect"]) {
    for (const instance of [null, "seen once"]) {
      const got = ["this-pr", "other"].map((prScope) => classify({ severity, instance, prScope, testFailure: false }, { handoffAvailable: false }));
      assert.ok(!got.includes("dispose-in-pr"), `${severity}/${instance}: ${got}`);
      assert.strictEqual(got[0], got[1], `${severity}/${instance}: this-pr and other classify alike`);
    }
  }
  const base = { instance: null, prScope: "this-pr", testFailure: false };
  assert.strictEqual(classify(Object.assign({ severity: "medium" }, base), { handoffAvailable: false }), "final-list", "medium this-pr");
  assert.strictEqual(classify(Object.assign({ severity: "low" }, base), { handoffAvailable: false }), "discard", "low this-pr");
  assert.strictEqual(classify(Object.assign({ severity: "not-defect" }, base), { handoffAvailable: false }), "discard", "not-defect this-pr");
});
caseEnd();

caseBegin("read-open-this-pr-states-and-stub-runner", "bin/lib/this-pr-open.js");
test("readOpenThisPr: absent / ok / error, and git only through the injected runGit", () => {
  const { readOpenThisPr } = require(path.join(LIB, "this-pr-open.js"));
  const calls = [];
  const runGit = (args) => {
    calls.push(args.slice());
    const a = args.join(" ");
    if (a.includes("--is-ancestor")) return { status: 0, stdout: "" };
    if (a.includes("diff")) return { status: 0, stdout: "src/a.js\n" };
    if (a.includes("ls-files")) return { status: 0, stdout: "" };
    if (a.includes("rev-parse")) return { status: 0, stdout: `${TMP.replace(/\\/g, "/")}/repo\n` };
    return { status: 0, stdout: "" };
  };
  const dir = path.join(TMP, "repo");
  fs.mkdirSync(dir, { recursive: true });
  const fixedLoc = (loc) => F.entry(`fixed ${loc}`, { loc, base: SHA, terminal: "<!-- disposed: fixed -->" });
  const notes = F.writeNotes(dir, {
    BugsFound: [F.entry("unfixed one", { base: SHA }), fixedLoc("src/a.js:3"), F.entry("other one", { scope: "other" })],
    RelatedTasks: [fixedLoc("src/b.js"), F.entry("accepted", { base: SHA, terminal: "<!-- user-accepted: by hand -->" })],
  });

  counting = true;
  const absent = readOpenThisPr(path.join(TMP, "nowhere", "WORKTREE_NOTES.md"), { runGit });
  const ok = readOpenThisPr(notes, { runGit });
  const error = readOpenThisPr(dir, { runGit });
  counting = false;

  assert.strictEqual(spawned, 0, "no child process outside the injected runGit");
  assert.deepStrictEqual([absent.state, absent.open], ["absent", []], "ENOENT -> absent");
  assert.strictEqual(error.state, "error", "a directory as the notes path -> error");
  assert.ok(error.reason, "error carries a reason");
  assert.strictEqual(ok.state, "ok", "ok state");
  assert.ok(calls.length > 0, "fixedEvidence ran through runGit");
  assert.ok(calls.every((a) => Array.isArray(a) && a[0] !== "git"), "runGit receives git arguments, not a command line");
  const got = ok.open.map((o) => [o.section, o.body, o.reason]);
  assert.deepStrictEqual(got, [["BugsFound", "unfixed one", "this-pr-unfixed"], ["RelatedTasks", "fixed src/b.js", "fixed-unverified"]], "open set");
  for (const o of ok.open) {
    assert.strictEqual(o.key, F.key(o.section, o.body), `${o.body}: key = findingKey(section, body)`);
    assert.ok(Number.isInteger(o.lineNumber) && o.lineNumber > 0, `${o.body}: lineNumber`);
    assert.ok("detail" in o, `${o.body}: detail field present`);
  }
  assert.ok(JSON.stringify(ok.open[1].detail).includes("src/b.js"), "fixed-unverified detail names the path");
});
caseEnd();

// resolveSessionNotesPath binds to the PROCESS cwd (trusted repo dir), so each case runs in a child.
const DRIVER = path.join(TMP, "resolve-driver.js");
fs.writeFileSync(DRIVER, `"use strict";
const [, , lib, sid] = process.argv;
let out;
try { out = require(lib).resolveSessionNotesPath(sid); } catch (e) { out = { threw: String(e && e.message) }; }
process.stdout.write(JSON.stringify(out === undefined ? null : out));
`);
function resolveIn(cwd, sid) {
  const r = cp.spawnSync(process.execPath, [DRIVER, path.join(LIB, "this-pr-open.js"), sid], { cwd, encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env) });
  try { return JSON.parse(r.stdout); } catch (_) { return { threw: `exit ${r.status}: ${(r.stderr || "").slice(0, 300)}` }; }
}
const real = (p) => fs.realpathSync.native(p).replace(/\\/g, "/").toLowerCase();

caseBegin("resolve-session-notes-path", "bin/lib/this-pr-open.js");
test("resolveSessionNotesPath: repo-unresolved / cwd-mismatch / match / worktree-less session", () => {
  const r = F.makeRepo("resolve");
  F.seedState("sid-wt", r.wt);
  F.seedState("sid-main", r.main);

  const unresolved = resolveIn(r.plain, "sid-wt");
  assert.ok(!unresolved.path && /repo-unresolved/.test(JSON.stringify(unresolved.error)), `plain cwd: ${JSON.stringify(unresolved)}`);

  const mismatch = resolveIn(r.main, "sid-wt");
  assert.ok(!mismatch.path && /cwd-mismatch/.test(JSON.stringify(mismatch.error)), `main cwd for a wt session: ${JSON.stringify(mismatch)}`);

  const match = resolveIn(r.wt, "sid-wt");
  assert.ok(match.path && !match.error, `wt cwd: ${JSON.stringify(match)}`);
  assert.strictEqual(path.basename(match.path), "WORKTREE_NOTES.md", "notes file name");
  assert.strictEqual(real(path.dirname(match.path)), real(r.wt), "the session worktree's notes");

  const metaSession = resolveIn(r.main, "sid-main");
  assert.ok(metaSession.path && !metaSession.error, `worktree-less session: ${JSON.stringify(metaSession)}`);
  assert.strictEqual(real(path.dirname(metaSession.path)), real(r.main), "trusted repo dir notes");
});
caseEnd();
