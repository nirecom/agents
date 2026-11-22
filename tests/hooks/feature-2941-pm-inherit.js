"use strict";
// tests/hooks/feature-2941-pm-inherit.js
// Tests: hooks/pm-session/inherit.js
// Tags: TL1, scope:issue-specific, pm-session, user-prompt-submit, workflow-state
// #2941: `/resume-session --from` stores each inherited issue with the home repo (the origin of the
// cwd, o/r in the writer fixture) and refuses to copy an upstream table that names one issue twice.
// Driven through runPmWriter with the fixture of ./feature-2941-pm-writer/ (fake gh on PATH).
// TL3 gap: the inherit running inside the live UserPromptSubmit hook process is not observed here.

const { isolate } = require("../lib/harness");
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
