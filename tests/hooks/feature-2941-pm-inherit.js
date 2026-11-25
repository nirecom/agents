"use strict";
// tests/hooks/feature-2941-pm-inherit.js
// Tests: hooks/pm-session/inherit.js
// Tags: TL1, scope:issue-specific, pm-session, user-prompt-submit, workflow-state
// #2941: `/resume-session --from` stores each inherited issue with the home repo (the origin of the
// cwd, o/r in the writer fixture) and refuses to copy an upstream table that names one issue twice.
// Driven through runPmWriter with the fixture of ./feature-2941-pm-writer/ (fake gh on PATH).
// TL3 gap: the inherit running inside the live UserPromptSubmit hook process is not observed here.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const neutral = fs.mkdtempSync(path.join(os.tmpdir(), "pm-inherit-"));
const savedCwd = process.cwd();
process.chdir(neutral);
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(neutral, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
after(() => { process.chdir(savedCwd); fs.rmSync(neutral, { recursive: true, force: true }); restore(); });

const W = require(path.join(__dirname, "feature-2941-pm-writer", "fixture.js"));
const { P } = W;

const HOME = "o/r";
const R = (n, repo) => ({ number: n, repo: repo || HOME });
const EMPTY = { updated_at: null, tables: [], unverified: null };
const item = (ref) => Object.assign({ reason: "r", blocked_by: [], conflicts: [] }, typeof ref === "object" ? ref : { number: ref });
const seqOf = (...ws) => ({ updated_at: "2026-11-01T02:00:00.000Z", tables: [{ title: "T", waves: ws.map((issues) => ({ issues: issues.map(item) })) }] });

// inheritFrom(issues, sequence) -> {up, r, pm}: an upstream PM holding issues is resumed in a fresh session.
function inheritFrom(issues, sequence) {
  const sid = W.nextSid();
  const tag = W.nextTag("PM-inh");
  P.seedPm(sid, P.pm({ tag, issues, sequence: sequence || { updated_at: null, tables: [] } }));
  const down = W.nextSid();
  P.seedState(down);
  try {
    const r = W.write(down, P.wrapped("resume-session", `--from ${sid}`));
    W.assertAccepted(r, "inherit", tag);
    return { up: { sid, tag }, r, pm: P.readPm(down) };
  } finally {
    W.archive(sid);
    if (P.readPm(down)) W.archive(down);
  }
}

test("B1 a repo-less upstream issue is inherited with the home repo, in pm.issues and assignment_log", () => {
  const x = inheritFrom([7101]);
  assert.deepStrictEqual(x.pm.issues, [R(7101)]);
  assert.deepStrictEqual(W.lastLog(x.pm).issues, [R(7101)]);
});

test("B2 an upstream issue that names another repo keeps that repo", () => {
  const x = inheritFrom([R(7102, "other/x"), 7103]);
  assert.deepStrictEqual(x.pm.issues, [R(7102, "other/x"), R(7103)]);
});

test("B3 an upstream table naming one issue twice is not copied: structure duplicate, no extra forge call", () => {
  const x = inheritFrom([7104], seqOf([7104], [R(7104)]));
  // Since #2942 writer.js withInbox runs checkMeta after the inherit, reading the forge once for the
  // meta_children baseline; that read is by design, so compare against a plain inherit, not zero.
  const control = inheritFrom([7105]);
  assert.deepStrictEqual(x.pm.sequence, EMPTY);
  assert.deepStrictEqual(x.pm.issues, [R(7104)]);
  for (const k of ["context", "notice"]) {
    assert.ok(String(x.r[k]).includes("structure duplicate issue in the sequence"), `${k}: ${W.brief(x.r)}`);
  }
  assert.match(String(x.r.context), /sequence=not-copied/);
  assert.strictEqual(x.r.calls, control.r.calls, `${W.brief(x.r)} / control: ${W.brief(control.r)}`);
});

// #3152: the sequence check of an inherit reads the forge under the hook budget's check deadline; an inherit
// has no write stage, so it asks checkDeadline({write:false}) (hookDeadlineAt - inbox).
caseBegin("pm-inherit-check-deadline", "hooks/pm-session/inherit.js");
test("B4 the inherit's range check runs to budget.checkDeadline({write:false})", () => {
  let create;
  try { create = P.load("hooks/pm-session/budget.js").createHookBudget; } catch (e) { assert.fail(`hooks/pm-session/budget.js is missing (#3152): ${e.message}`); }
  const real = create({ startedAt: Date.now(), now: () => Date.now() });
  const asked = [];
  const budget = Object.assign({}, real, { checkDeadline: (o) => { const d = real.checkDeadline(o); asked.push({ o, d }); return d; } });
  const seen = [];
  const links = P.load("bin/lib/forge-issue-links.js");
  const fetchAncestorChains = (refs, o) => { seen.push(o && o.deadlineAt); return links.fetchAncestorChains(refs, o); };
  const sid = W.nextSid();
  const tag = W.nextTag("PM-inh");
  P.seedPm(sid, P.pm({ tag, issues: [7106], sequence: seqOf([7106]) }));
  const down = W.nextSid();
  P.seedState(down);
  try {
    const r = P.load(W.WRITER).runPmWriter({ session_id: down, hook_event_name: "UserPromptSubmit", prompt: P.wrapped("resume-session", `--from ${sid}`), cwd: W.home },
      { now: () => Date.now(), budget, fetchAncestorChains });
    W.assertAccepted(r || {}, "inherit", tag);
    const noWrite = asked.filter((a) => a.o && a.o.write === false);
    assert.ok(noWrite.length >= 1, `checkDeadline({write:false}) was not asked: ${JSON.stringify(asked)}`);
    assert.ok(seen.length >= 1, "the range check did not read the forge");
    assert.ok(seen.every((d) => noWrite.some((a) => a.d === d)), `deadlines ${JSON.stringify(seen)} vs ${JSON.stringify(noWrite)}`);
  } finally {
    W.archive(sid);
    if (P.readPm(down)) W.archive(down);
  }
});
caseEnd();

// #3152: the two new forge failure reasons (a spent deadline, a gh that cannot be spawned) are unverified
// reasons, so the table still comes over with the mark (schema.js UNVERIFIED_REASONS accepts them).
caseBegin("pm-inherit-unverified-budget-reasons", "hooks/pm-session/inherit.js");
for (const reason of ["budget-exhausted", "spawn-failed"]) {
  test(`F3 a range check that fails with ${reason}: the table is copied with the unverified mark (copied-unverified)`, () => {
    const seq = seqOf([7107]);
    const sid = W.nextSid();
    const tag = W.nextTag("PM-inh");
    P.seedPm(sid, P.pm({ tag, issues: [7107], sequence: seq }));
    const down = W.nextSid();
    P.seedState(down);
    try {
      const r = P.load(W.WRITER).runPmWriter({ session_id: down, hook_event_name: "UserPromptSubmit", prompt: P.wrapped("resume-session", `--from ${sid}`), cwd: W.home },
        { now: () => Date.now(), fetchAncestorChains: () => ({ ok: false, reason }) }) || {};
      W.assertAccepted(r, "inherit", tag);
      const pm = P.readPm(down);
      assert.ok(pm, `the inherit wrote no pm (schema refusal?): ${W.brief(r)}`);
      assert.deepStrictEqual(pm.sequence.tables, seq.tables);
      assert.strictEqual((pm.sequence.unverified || {}).reason, reason, JSON.stringify(pm.sequence));
      assert.match(String(r.context), /sequence=copied-unverified/);
    } finally {
      W.archive(sid);
      if (P.readPm(down)) W.archive(down);
    }
  });
}
caseEnd();
