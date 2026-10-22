"use strict";
// Tests: bin/check-glossary-provenance, bin/review-doc-glossary
// Tags: TL2, bin, glossary, provenance, session, fail-closed, scope:issue-specific
// T3-3: the read-failure classes — A (no intent.md), C (no / broken `## Glossary`), B (session
// only from CLAUDE_CODE_SESSION_ID), the no-session named exception — each blocks per operation,
// is recorded on the resolved session, and is escaped by GLOSSARY_ACCEPTED; zero operations
// pass without any session; --all never runs the glossary provenance check.

const { caseBegin, caseEnd, gitInit } = require("../../lib/harness");
const fs = require("fs");
const path = require("path");
const { check, eq, ok, TMP, STATE_DIR, DEFS, BASE, fwd, git, stage, mkRepo, stageUser, newSid, writeState,
  approvedSession, provRecord, blockedOf, prov, accept, runBash, has } = require("./common");

const BETA = "A hand-written fixture term.";
const BETA_ROW = [["beta", "user", "add", BETA]];
// handAdd(tag) — a repo with `beta` added to user.md by hand (staged, not promoted).
function handAdd(tag) {
  const repo = mkRepo(tag);
  stageUser(repo, [["alpha", DEFS.alpha], ["beta", BETA], ["omega", DEFS.omega]]);
  return repo;
}
const stateFiles = () => fs.readdirSync(STATE_DIR).sort();

caseBegin("t3-3-a-intent-missing", "bin/check-glossary-provenance");
function caseA() {
  const repo = handAdd("a");
  const sid = newSid("a");
  writeState(sid, { approval: false, cwd: repo });
  check("T3-3 A: no intent.md with an explicit --session blocks with intent-missing (exit 1)", () => {
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/intent-missing/.test(r.all), `want intent-missing in the output, got: ${r.all}`);
  });
  check("T3-3 A: glossary_provenance.blocked records beta add user as intent-missing", () => {
    ok(has(blockedOf(sid), "beta", "add", "user", "intent-missing"), `blocked: ${JSON.stringify(provRecord(sid))}`);
  });
  check("T3-3 A: GLOSSARY_ACCEPTED for the term, then the re-run passes", () => {
    const h = accept(sid, repo, "beta", "op=add cat=user");
    eq(h.code, 0, `hook exit (${h.all})`);
    const r = prov(repo, sid);
    eq(r.code, 0, `re-run exit (out: ${r.all})`);
  });
}
caseEnd();

caseBegin("t3-3-c-intent-unreadable", "bin/check-glossary-provenance");
function caseC() {
  const variants = [
    ["no-glossary-section", { noGlossary: true }],
    ["broken-table", { glossary: "| Term | Category |\n|---|\n| beta | user |\n" }],
  ];
  for (const [name, opts] of variants) {
    const repo = handAdd(`c-${name}`);
    const sid = approvedSession(`c-${name}`, BETA_ROW, Object.assign({ cwd: repo }, opts));
    check(`T3-3 C (${name}): an explicit --session blocks with intent-unreadable (exit 1)`, () => {
      const r = prov(repo, sid);
      eq(r.code, 1, `exit (out: ${r.all})`);
      ok(/intent-unreadable/.test(r.all), `want intent-unreadable, got: ${r.all}`);
    });
    check(`T3-3 C (${name}): blocked records beta add user as intent-unreadable`, () => {
      ok(has(blockedOf(sid), "beta", "add", "user", "intent-unreadable"), `record: ${JSON.stringify(provRecord(sid))}`);
    });
    check(`T3-3 C (${name}): GLOSSARY_ACCEPTED for the term, then the re-run passes`, () => {
      eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "hook exit");
      eq(prov(repo, sid).code, 0, "re-run exit");
    });
  }
}
caseEnd();

caseBegin("t3-3-zero-operations-and-all-scan", "bin/review-doc-glossary");
function zeroOpsAndAllScan() {
  const repo = mkRepo("zero");
  stageUser(repo, [["alpha", DEFS.alpha, "[guide](../guide.md)"], ["omega", DEFS.omega]]);
  check("T3-3 zero glossary operations exit 0 with neither --session nor CLAUDE_CODE_SESSION_ID", () => {
    const before = stateFiles();
    const r = prov(repo, null);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(stateFiles(), before, "state files");
  });
  const hand = handAdd("all");
  check("T3-3 review-doc-glossary --all never runs the glossary provenance check", () => {
    const r = runBash("bin/review-doc-glossary", ["--all"], { cwd: hand });
    eq(r.code, 0, `exit (out: ${r.all})`);
    ok(/PERFORMED \(all-scan mode\)/.test(r.out), `want the all-scan header, got: ${r.all}`);
    ok(!/no-session|session-unverified|provenance|ACCEPTED/i.test(r.all), `provenance output in --all: ${r.all}`);
  });
}
caseEnd();

caseBegin("t3-3-b-session-from-env", "bin/check-glossary-provenance");
function caseB() {
  const repo = handAdd("b");
  const sid = approvedSession("b", BETA_ROW, { cwd: repo });
  check("T3-3 B: no --session, env id only -> exit 1 even though the intent has the row", () => {
    const r = prov(repo, null, { env: { CLAUDE_CODE_SESSION_ID: sid } });
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/--session/.test(r.all), `want the --session re-run hint, got: ${r.all}`);
  });
  check("T3-3 B: the env session records session_source env and session-unverified per operation", () => {
    const rec = provRecord(sid);
    ok(rec, "no glossary_provenance record on the env session");
    eq(rec.session_source, "env", "session_source");
    ok(has(rec.blocked || [], "beta", "add", "user", "session-unverified"), `blocked: ${JSON.stringify(rec.blocked)}`);
    ok(typeof rec.fingerprint === "string" && rec.fingerprint.length > 0, "fingerprint recorded");
  });
  check("T3-3 B: GLOSSARY_ACCEPTED on the same session, then the same env-only run exits 0", () => {
    eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "hook exit");
    const r = prov(repo, null, { env: { CLAUDE_CODE_SESSION_ID: sid } });
    eq(r.code, 0, `re-run exit (out: ${r.all})`);
  });

  for (const bad of ["../x", "a b"]) {
    const repo2 = handAdd("b-bad");
    const sid2 = approvedSession("b-bad", BETA_ROW, { cwd: repo2 });
    check(`T3-3 B variant: an invalid --session '${bad}' with a valid env id is B on the env session`, () => {
      const r = prov(repo2, bad, { env: { CLAUDE_CODE_SESSION_ID: sid2 } });
      eq(r.code, 1, `exit (out: ${r.all})`);
      const rec = provRecord(sid2);
      ok(rec && rec.session_source === "env", `record: ${JSON.stringify(rec)}`);
      ok(has(rec.blocked || [], "beta", "add", "user", "session-unverified"), `blocked: ${JSON.stringify(rec.blocked)}`);
    });
  }

  const repo3 = handAdd("b-then-explicit");
  const sid3 = approvedSession("b-then-explicit", BETA_ROW, { cwd: repo3 });
  check("T3-3 B then an explicit --session run goes on to the intent-based check (session_source explicit)", () => {
    eq(prov(repo3, null, { env: { CLAUDE_CODE_SESSION_ID: sid3 } }).code, 1, "B exit");
    const r = prov(repo3, sid3);
    eq(r.code, 0, `explicit exit (out: ${r.all})`);
    const rec = provRecord(sid3);
    eq(rec && rec.session_source, "explicit", "session_source");
  });
}
caseEnd();

caseBegin("t3-3-no-session", "bin/check-glossary-provenance");
function noSession() {
  const repo = handAdd("nosess");
  for (const [label, sid] of [["no --session and no env", null], ["an invalid --session and no env", "../x"]]) {
    check(`T3-3 no-session (${label}): BLOCK no-session, exit 1, no state file touched, no ACCEPTED hint`, () => {
      const before = stateFiles();
      const r = prov(repo, sid);
      eq(r.code, 1, `exit (out: ${r.all})`);
      ok(/BLOCK: no-session/.test(r.all), `want 'BLOCK: no-session', got: ${r.all}`);
      ok(!/GLOSSARY_ACCEPTED/.test(r.all), `the no-session output must not suggest ACCEPTED: ${r.all}`);
      eq(stateFiles(), before, "state files");
    });
  }
}
caseEnd();

caseBegin("t3-3-b-record-write-failure", "bin/check-glossary-provenance");
function bWriteFailure() {
  const repo = handAdd("b-wfail");
  const sid = approvedSession("b-wfail", BETA_ROW, { cwd: repo });
  const notADir = path.join(TMP, "state-is-a-file");
  fs.writeFileSync(notADir, "not a directory\n");
  check("T3-3 B with an unwritable state store: still exit 1, recovery (--session) on stderr", () => {
    const r = prov(repo, null, { env: { CLAUDE_CODE_SESSION_ID: sid, WORKFLOW_STATE_DIR: notADir } });
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/--session/.test(r.err), `want the --session recovery on stderr, got: ${r.err}`);
  });
}
caseEnd();

caseBegin("t3-3-unreadable-blob-fails-closed", "bin/check-glossary-provenance");
// dropBlob(repo, spec) — delete the loose object `spec` names, so the listed path cannot be read.
function dropBlob(repo, spec) {
  const sha = git(repo, ["rev-parse", spec]).stdout.trim();
  const file = path.join(repo, ".git", "objects", sha.slice(0, 2), sha.slice(2));
  fs.chmodSync(file, 0o666);
  fs.rmSync(file);
}
function unreadableBlob() {
  const variants = [
    ["index", ":docs/glossary/user.md", /cannot read the staged blob of docs\/glossary\/user\.md/],
    ["HEAD", "HEAD:docs/glossary/user.md", /cannot read the HEAD blob of docs\/glossary\/user\.md/],
  ];
  for (const [side, spec, want] of variants) {
    const repo = handAdd(`unread-${side}`);
    dropBlob(repo, spec);
    check(`T3-3 unreadable ${side} blob: check-glossary-provenance exits 2 naming the path`, () => {
      const r = prov(repo, null);
      eq(r.code, 2, `exit (out: ${r.all})`);
      ok(want.test(r.err), `want the read failure on stderr, got: ${r.all}`);
    });
    if (side !== "index") continue;
    check("T3-3 unreadable index blob: review-doc-glossary --staged BLOCKs it in the format scan (exit 1)", () => {
      const r = runBash("bin/review-doc-glossary", ["--staged"], { cwd: repo });
      eq(r.code, 1, `exit (out: ${r.all})`);
      ok(/BLOCK: docs\/glossary\/user\.md: cannot read the staged blob/.test(r.out), `want the BLOCK line, got: ${r.all}`);
      ok(!/no glossary entry file left/.test(r.out), `an unreadable blob is not an empty index: ${r.out}`);
    });
  }
  const unborn = fwd(path.join(TMP, "repo-unborn-head"));
  fs.mkdirSync(unborn, { recursive: true });
  gitInit(unborn);
  for (const [rel, body] of Object.entries(BASE)) stage(unborn, rel, body);
  check("T3-3 unborn HEAD is an absent side: the staged terms are judged as adds (no-session, exit 1)", () => {
    const r = prov(unborn, null);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/BLOCK: no-session/.test(r.out), `want the no-session BLOCK, got: ${r.all}`);
  });
}
caseEnd();

module.exports = { caseA, caseC, zeroOpsAndAllScan, caseB, noSession, bWriteFailure, unreadableBlob };
