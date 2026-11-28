"use strict";
// Tests: hooks/stop-final-report-guard.js, hooks/lib/transcript-reader.js, hooks/lib/transcript-reader/locate.js, hooks/stop-exit-worktree-warn.js
// Tags: feature-2843, stop-guard, final-report, transcript, relocate, scope:issue-specific, TL2, pwsh-not-required
// #2843: a Stop input whose transcript_path is unreadable (or absent) must not read as "no lines" and
// fail open silently. The reader re-locates the transcript by sid under the transcript base (the cwd's
// project dir first, then a bounded scan), names the move on stderr, and the guard names its fail-open.
// Every guard pass here has a same-fixture control that must block, so a pass is not an early exit.
// TL3 gap: a real Claude Code Stop event whose transcript_path points at a moved or not-yet-created file.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");
const G = require("../lib/final-report-guard-fixture");

const TP = require(F.rel("hooks/lib/transcript-paths.js"));
const LOCATE = "hooks/lib/transcript-reader/locate.js";
const TR = () => require(F.rel("hooks/lib/transcript-reader.js"));

const restoreIsolation = isolate();
const SB = F.makeBase("f2843-");
const PROJECTS = path.join(SB, "projects");
const CWD = path.join(SB, "proj");
const OTHER_CWD = path.join(SB, "proj-without-transcripts");
const MISSING_DIR = path.join(SB, "moved-away");
fs.mkdirSync(PROJECTS, { recursive: true });
fs.mkdirSync(CWD, { recursive: true });
fs.mkdirSync(OTHER_CWD, { recursive: true });
const savedBase = process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = PROJECTS;
after(() => {
  if (savedBase === undefined) delete process.env.CLAUDE_TRANSCRIPT_BASE_DIR;
  else process.env.CLAUDE_TRANSCRIPT_BASE_DIR = savedBase;
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const NO_REPORT = "Still working on the task. No final report yet.";
const candidate1Dir = (cwd) => path.join(PROJECTS, TP.encodeCwd(cwd));
const missingPath = (sid) => path.join(MISSING_DIR, `${sid}.jsonl`);
const sameFile = (a, b) => {
  const n = (p) => path.resolve(p);
  return process.platform === "win32" ? n(a).toLowerCase() === n(b).toLowerCase() : n(a) === n(b);
};
const relocated = (err) => /transcript-reader: relocated /.test(err);

// One Stop event into the guard, lane A (env file written), with an empty-or-fixture transcript base.
function hookEnv(base) {
  const env = Object.assign({}, process.env, { CLAUDE_PROJECT_DIR: process.env.WORKFLOW_STATE_DIR, CLAUDE_TRANSCRIPT_BASE_DIR: base || PROJECTS });
  delete env.CONV_LANG;
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}
function guard(sid, input, base) {
  G.writeEnv(sid);
  const env = hookEnv(base);
  const r = F.runNode([F.rel("hooks/stop-final-report-guard.js")], { cwd: SB, env, timeout: 60000, input: JSON.stringify(input) });
  let parsed = {};
  try { parsed = JSON.parse(r.out.trim()); } catch (_) { /* not a block */ }
  return Object.assign(r, { decision: parsed.decision });
}

const assertBlocks = (r, what) => {
  assert.strictEqual(r.rc, 2, `${what}: must block (rc 2), got rc=${r.rc}\nstdout=${r.out}\nstderr=${r.err}`);
  assert.strictEqual(r.decision, "block", `${what}: stdout must be a block decision: ${r.out}`);
};

caseBegin("missing-path-relocates-to-cwd-project-and-blocks", "hooks/stop-final-report-guard.js");
test("missing-path-relocates-to-cwd-project-and-blocks", () => {
  const sid = "t2843-a";
  G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: CWD });
  assertBlocks(r, "the relocated transcript holds no Final Report");
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("missing-path-relocated-report-passes", "hooks/stop-final-report-guard.js");
test("missing-path-relocated-report-passes", () => {
  const sid = "t2843-b";
  const ctl = "t2843-b-ctl";
  G.writeTranscript(candidate1Dir(CWD), ctl, NO_REPORT);
  assertBlocks(guard(ctl, { session_id: ctl, transcript_path: missingPath(ctl), cwd: CWD }), "control");
  G.writeTranscript(candidate1Dir(CWD), sid, G.reportText(sid));
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: CWD });
  assert.strictEqual(r.rc, 0, `a full report in the relocated transcript passes: rc=${r.rc} ${r.out} ${r.err}`);
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("no-transcript-anywhere-fails-open-with-reason", "hooks/stop-final-report-guard.js");
test("no-transcript-anywhere-fails-open-with-reason", () => {
  const sid = "t2843-c";
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: CWD });
  assert.strictEqual(r.rc, 0, `nothing to read fails open: rc=${r.rc} ${r.out}`);
  assert.ok(/transcript-reader: unreadable .*\(sid t2843-c\)/.test(r.err), `stderr must name the unreadable path: ${r.err}`);
  assert.ok(/stop-final-report-guard: fail-open \(no-lines\) transcript=/.test(r.err), `stderr must name the fail-open: ${r.err}`);
});
caseEnd();

caseBegin("scan-fallback-finds-another-project-dir", "hooks/stop-final-report-guard.js");
test("scan-fallback-finds-another-project-dir", () => {
  const sid = "t2843-d";
  G.writeTranscript(path.join(PROJECTS, "c--some-other-project"), sid, NO_REPORT);
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD });
  assertBlocks(r, "the scanned transcript holds no Final Report");
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("absent-transcript-path-located-by-session-id", "hooks/stop-final-report-guard.js");
test("absent-transcript-path-located-by-session-id", () => {
  const sid = "t2843-e";
  G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const r = guard(sid, { session_id: sid, cwd: CWD });
  assertBlocks(r, "no transcript_path, but the sid's transcript holds no Final Report");
});
caseEnd();

caseBegin("readable-given-path-is-not-relocated", "hooks/stop-final-report-guard.js");
test("readable-given-path-is-not-relocated", () => {
  const sid = "t2843-f";
  const ctl = "t2843-f-ctl";
  const given = path.join(SB, "given");
  G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const ctlPath = G.writeTranscript(given, ctl, NO_REPORT);
  assertBlocks(guard(ctl, { session_id: ctl, transcript_path: ctlPath, cwd: CWD }), "control");
  const r = guard(sid, { session_id: sid, transcript_path: G.writeTranscript(given, sid, G.reportText(sid)), cwd: CWD });
  assert.strictEqual(r.rc, 0, `the readable given transcript holds the report: rc=${r.rc} ${r.out} ${r.err}`);
  assert.ok(!relocated(r.err), `a readable transcript is never relocated: ${r.err}`);
});
caseEnd();

caseBegin("empty-given-path-is-excluded-from-the-search", "hooks/stop-final-report-guard.js");
test("empty-given-path-is-excluded-from-the-search", () => {
  const sid = "t2843-g";
  const c1 = path.join(candidate1Dir(CWD), `${sid}.jsonl`);
  fs.writeFileSync(c1, "");
  G.writeTranscript(path.join(PROJECTS, "c--elsewhere-g"), sid, NO_REPORT);
  const given = process.platform === "win32" ? c1.toUpperCase() : c1;
  const r = guard(sid, { session_id: sid, transcript_path: given, cwd: CWD });
  assertBlocks(r, "the empty given file is skipped and the other copy is read");
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("locate-prefers-the-cwd-project-dir", "hooks/lib/transcript-reader/locate.js");
test("locate-prefers-the-cwd-project-dir", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-u1";
  const c1 = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  G.writeTranscript(path.join(PROJECTS, "c--elsewhere-u1"), sid, NO_REPORT);
  const r = locateTranscript({ session_id: sid, transcript_path: missingPath(sid), cwd: CWD });
  assert.ok(r && r.path && sameFile(r.path, c1), `candidate 1 wins: ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("locate-scans-when-the-cwd-dir-has-none", "hooks/lib/transcript-reader/locate.js");
test("locate-scans-when-the-cwd-dir-has-none", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-u2";
  const other = G.writeTranscript(path.join(PROJECTS, "c--elsewhere-u2"), sid, NO_REPORT);
  const r = locateTranscript({ session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD });
  assert.ok(r && r.path && sameFile(r.path, other), `the scan finds it: ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("locate-honours-exclude", "hooks/lib/transcript-reader/locate.js");
test("locate-honours-exclude", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-u3";
  const c1 = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const other = G.writeTranscript(path.join(PROJECTS, "c--elsewhere-u3"), sid, NO_REPORT);
  const exclude = process.platform === "win32" ? c1.toUpperCase() : c1;
  const r = locateTranscript({ session_id: sid, transcript_path: c1, cwd: CWD }, { exclude });
  assert.ok(r && r.path && sameFile(r.path, other), `the excluded path is skipped: ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("locate-takes-the-sid-from-the-basename", "hooks/lib/transcript-reader/locate.js");
test("locate-takes-the-sid-from-the-basename", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-u4";
  const c1 = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const r = locateTranscript({ transcript_path: missingPath(sid), cwd: CWD });
  assert.ok(r && r.path && sameFile(r.path, c1), `sid from the basename: ${JSON.stringify(r)}`);
  const none = locateTranscript({ session_id: "t2843-u4-none", transcript_path: missingPath("t2843-u4-none"), cwd: CWD });
  assert.ok(!(none && none.path), `nothing found yields no path: ${JSON.stringify(none)}`);
});
caseEnd();

caseBegin("readTurnTail-relocates-and-returns-transcriptPath", "hooks/lib/transcript-reader.js");
test("readTurnTail-relocates-and-returns-transcriptPath", () => {
  const sid = "t2843-r1";
  const c1 = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const tail = TR().readTurnTail({ input: { session_id: sid, transcript_path: missingPath(sid), cwd: CWD } });
  assert.ok(tail.lines.length > 0, `the relocated transcript is read: ${JSON.stringify(tail.lines)}`);
  assert.ok(typeof tail.transcriptPath === "string" && sameFile(tail.transcriptPath, c1), `transcriptPath names the file read: ${tail.transcriptPath}`);
});
caseEnd();

caseBegin("readTurnTail-keeps-a-readable-path", "hooks/lib/transcript-reader.js");
test("readTurnTail-keeps-a-readable-path", () => {
  const sid = "t2843-r2";
  G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const given = G.writeTranscript(path.join(SB, "given-r2"), sid, NO_REPORT);
  const tail = TR().readTurnTail({ input: { session_id: sid, transcript_path: given, cwd: CWD } });
  assert.strictEqual(tail.lines.length, 2);
  assert.ok(typeof tail.transcriptPath === "string" && sameFile(tail.transcriptPath, given), `transcriptPath is the given path: ${tail.transcriptPath}`);
});
caseEnd();

caseBegin("refreshTurnTail-reads-the-relocated-path", "hooks/lib/transcript-reader.js");
test("refreshTurnTail-reads-the-relocated-path", () => {
  const sid = "t2843-r3";
  const c1 = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const input = { session_id: sid, transcript_path: missingPath(sid), cwd: CWD };
  const tail = TR().readTurnTail({ input });
  assert.ok(tail.lines.length > 0 && tail.transcriptPath, `fixture: the first read relocates: ${tail.transcriptPath}`);
  fs.appendFileSync(c1, JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "appended" }] } }) + "\n");
  const next = TR().refreshTurnTail(tail, { input });
  assert.strictEqual(next.undecidable, false, "the refresh reads tail.transcriptPath, not the missing input path");
  assert.strictEqual(next.lastTextBlock, "appended");
});
caseEnd();

caseBegin("readTranscriptLines-locates-only-when-empty", "hooks/lib/transcript-reader.js");
test("readTranscriptLines-locates-only-when-empty", () => {
  const sid = "t2843-r4";
  G.writeTranscript(path.join(PROJECTS, "c--elsewhere-r4"), sid, NO_REPORT);
  const given = path.join(SB, "given-r4", `${sid}.jsonl`);
  fs.mkdirSync(path.dirname(given), { recursive: true });
  fs.writeFileSync(given, JSON.stringify({ type: "user", message: { content: "only" } }) + "\n");
  assert.strictEqual(TR().readTranscriptLines(given).length, 1, "a readable path is read as is");
  assert.strictEqual(TR().readTranscriptLines(missingPath(sid)).length, 2, "an unreadable path is re-located by its basename sid");
});
caseEnd();

// (e)/(f): the old path still holds the pre-move content, so its last text never matches
// last_assistant_message (undecidable after the flush wait); the moved file lives in another dir.
const STALE = "stale text written before the transcript moved";
const undecidableInput = (sid, given) => ({ session_id: sid, transcript_path: given, cwd: CWD, last_assistant_message: NO_REPORT });

caseBegin("undecidable-old-path-relocates-and-blocks", "hooks/stop-final-report-guard.js");
test("undecidable-old-path-relocates-and-blocks", () => {
  const sid = "t2843-h";
  const old = G.writeTranscript(path.join(SB, "old-h"), sid, STALE);
  G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const r = guard(sid, undecidableInput(sid, old));
  assertBlocks(r, "the moved transcript is decidable and holds no Final Report");
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("readTurnTail-undecidable-old-path-returns-moved-transcriptPath", "hooks/lib/transcript-reader.js");
test("readTurnTail-undecidable-old-path-returns-moved-transcriptPath", () => {
  const sid = "t2843-r5";
  const old = G.writeTranscript(path.join(SB, "old-r5"), sid, STALE);
  const moved = G.writeTranscript(candidate1Dir(CWD), sid, NO_REPORT);
  const tail = TR().readTurnTail({ input: undecidableInput(sid, old) });
  assert.strictEqual(tail.undecidable, false, "the moved transcript decides the turn");
  assert.ok(typeof tail.transcriptPath === "string" && sameFile(tail.transcriptPath, moved), `transcriptPath is the moved file: ${tail.transcriptPath}`);
  assert.strictEqual(tail.lastTextBlock, NO_REPORT);
});
caseEnd();

caseBegin("undecidable-after-relocation-fails-open-without-a-second-search", "hooks/stop-final-report-guard.js");
test("undecidable-after-relocation-fails-open-without-a-second-search", () => {
  const sid = "t2843-i";
  const old = G.writeTranscript(path.join(SB, "old-i"), sid, STALE);
  const moved = G.writeTranscript(candidate1Dir(CWD), sid, `${STALE} (moved copy)`);
  // A decidable report-less copy a second search would find and block on.
  G.writeTranscript(path.join(PROJECTS, "c--elsewhere-i"), sid, NO_REPORT);
  const r = guard(sid, undecidableInput(sid, old));
  assert.strictEqual(r.rc, 0, `the moved file is undecidable too: fail open, search no further: rc=${r.rc} ${r.out} ${r.err}`);
  assert.strictEqual((r.err.match(/transcript-reader: relocated /g) || []).length, 1, `exactly one relocation: ${r.err}`);
  const m = /stop-final-report-guard: fail-open \(undecidable\) transcript=(.+)/.exec(r.err);
  assert.ok(m && sameFile(m[1].trim(), moved), `the fail-open names the moved transcript ${moved}: ${r.err}`);
});
caseEnd();

// (d) a readTranscriptLines consumer: stop-exit-worktree-warn reads the relocated lines.
caseBegin("exit-worktree-warn-reads-the-relocated-transcript", "hooks/stop-exit-worktree-warn.js");
test("exit-worktree-warn-reads-the-relocated-transcript", () => {
  const lines = [{ type: "user", message: { content: "go" } },
    { type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "EnterWorktree", input: {} }] } }];
  const put = (dir, sid) => {
    fs.mkdirSync(dir, { recursive: true });
    const p = path.join(dir, `${sid}.jsonl`);
    fs.writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return p;
  };
  const warn = (sid, given) => F.runNode([F.rel("hooks/stop-exit-worktree-warn.js")],
    { cwd: SB, env: hookEnv(), timeout: 60000, input: JSON.stringify({ session_id: sid, transcript_path: given, cwd: OTHER_CWD }) });
  const ctl = warn("t2843-w-ctl", put(path.join(SB, "given-w"), "t2843-w-ctl"));
  assert.ok(/EnterWorktree was used/.test(ctl.out), `control: a readable transcript yields the advisory: ${ctl.out} ${ctl.err}`);
  put(path.join(PROJECTS, "c--elsewhere-w"), "t2843-w");
  const r = warn("t2843-w", missingPath("t2843-w"));
  assert.strictEqual(r.rc, 0, r.err);
  assert.ok(/EnterWorktree was used/.test(r.out), `the relocated transcript yields the advisory: stdout=${r.out} stderr=${r.err}`);
});
caseEnd();

// C5: the bounded scan. pickBeyond(base, n, k) makes n empty dirs and returns one whose index is >= k
// both in fs.readdirSync order and in sorted order, so the verdict holds whichever order the scan uses.
function pickBeyond(base, n, k) {
  for (let i = 0; i < n; i++) fs.mkdirSync(path.join(base, `c--decoy-${String(i).padStart(3, "0")}`), { recursive: true });
  const listed = fs.readdirSync(base);
  const sorted = [...listed].sort();
  const late = listed.slice(k).filter((d) => sorted.indexOf(d) >= k);
  assert.ok(late.length > 0, `fixture: a dir late in both orders exists among ${n}`);
  return path.join(base, late[late.length - 1]);
}

caseBegin("scan-beyond-the-200-dir-cap-fails-open-with-reason", "hooks/stop-final-report-guard.js");
test("scan-beyond-the-200-dir-cap-fails-open-with-reason", () => {
  const sid = "t2843-cap";
  const small = path.join(SB, "cap-small");
  G.writeTranscript(path.join(small, "c--target"), sid, NO_REPORT);
  assertBlocks(guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD }, small), "control: the scan finds it in a small base");
  const big = path.join(SB, "cap-big");
  G.writeTranscript(pickBeyond(big, 400, 200), sid, NO_REPORT);
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD }, big);
  assert.strictEqual(r.rc, 0, `the 200-dir cap stops the scan before the target: rc=${r.rc} ${r.out} ${r.err}`);
  assert.ok(/transcript-reader: unreadable .*\(sid t2843-cap\)/.test(r.err), `stderr names the unfound transcript: ${r.err}`);
  assert.ok(/stop-final-report-guard: fail-open \(no-lines\) transcript=/.test(r.err), `stderr names the fail-open: ${r.err}`);
});
caseEnd();

// The 150 ms deadline, made deterministic by a clock that advances 100 ms on every read
// (Date.now and performance.now); a scan that never reads either clock cannot be judged here.
function withFastClock(fn) {
  const realDate = Date.now;
  const realPerf = performance.now.bind(performance);
  let k = 0;
  Date.now = () => realDate() + 100 * k++;
  performance.now = () => realPerf() + 100 * k++;
  try { return fn(); } finally { Date.now = realDate; delete performance.now; }
}
function captureStderr(fn) {
  const real = process.stderr.write;
  let buf = "";
  process.stderr.write = (chunk, ...rest) => { buf += String(chunk); return true; };
  try { return { value: fn(), err: buf }; } finally { process.stderr.write = real; }
}

caseBegin("scan-past-the-150ms-deadline-finds-nothing-with-reason", "hooks/lib/transcript-reader/locate.js");
test("scan-past-the-150ms-deadline-finds-nothing-with-reason", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-dl";
  const base = path.join(SB, "dl-projects");
  const target = G.writeTranscript(pickBeyond(base, 40, 20), sid, NO_REPORT);
  const input = { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD };
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = base;
  try {
    const ctl = locateTranscript(input);
    assert.ok(ctl && ctl.path && sameFile(ctl.path, target), `control: with a real clock the scan finds it: ${JSON.stringify(ctl)}`);
    const r = withFastClock(() => locateTranscript(input));
    assert.ok(!(r && r.path), `past the deadline nothing is found: ${JSON.stringify(r)}`);
    const c = captureStderr(() => withFastClock(() => TR().readTranscriptLines(missingPath(sid))));
    assert.strictEqual(c.value.length, 0, "past the deadline the reader reads no lines");
    assert.ok(/transcript-reader: unreadable .*\(sid t2843-dl\)/.test(c.err), `stderr names the unfound transcript: ${c.err}`);
  } finally {
    process.env.CLAUDE_TRANSCRIPT_BASE_DIR = PROJECTS;
  }
});
caseEnd();

// Newest-mtime selection: ageS seconds in the past, so two copies differ by far more than fs resolution.
const age = (p, ageS) => { const t = Date.now() / 1000 - ageS; fs.utimesSync(p, t, t); return p; };
const withBase = (base, fn) => {
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = base;
  try { return fn(); } finally { process.env.CLAUDE_TRANSCRIPT_BASE_DIR = PROJECTS; }
};
const scanInput = (sid) => ({ session_id: sid, transcript_path: missingPath(sid) });

caseBegin("scan-picks-the-newest-copy-in-either-dir-order", "hooks/stop-final-report-guard.js");
test("scan-picks-the-newest-copy-in-either-dir-order", () => {
  // [sid, dir holding the older full report, dir holding the newer report-less copy]
  for (const [sid, oldDir, newDir] of [["t2843-n1", "c--aa-n1", "c--zz-n1"], ["t2843-n2", "c--zz-n2", "c--aa-n2"]]) {
    age(G.writeTranscript(path.join(PROJECTS, oldDir), sid, G.reportText(sid)), 3600);
    age(G.writeTranscript(path.join(PROJECTS, newDir), sid, NO_REPORT), 60);
    const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD });
    assertBlocks(r, `${sid}: the newer report-less copy in ${newDir} decides`);
  }
  const sid = "t2843-n3";
  age(G.writeTranscript(path.join(PROJECTS, "c--aa-n3"), sid, NO_REPORT), 3600);
  age(G.writeTranscript(path.join(PROJECTS, "c--zz-n3"), sid, G.reportText(sid)), 60);
  const r = guard(sid, { session_id: sid, transcript_path: missingPath(sid), cwd: OTHER_CWD });
  assert.strictEqual(r.rc, 0, `the newer copy holds the report: rc=${r.rc} ${r.out} ${r.err}`);
  assert.ok(relocated(r.err), `stderr must name the relocation: ${r.err}`);
});
caseEnd();

caseBegin("scan-cap-is-exactly-200-dirs-under-a-frozen-clock", "hooks/lib/transcript-reader/locate.js");
test("scan-cap-is-exactly-200-dirs-under-a-frozen-clock", () => {
  const M = require(F.rel(LOCATE));
  const base = path.join(SB, "cap-frozen");
  for (let i = 0; i < M.SCAN_MAX_DIRS + 20; i++) fs.mkdirSync(path.join(base, `c--d-${String(i).padStart(3, "0")}`), { recursive: true });
  const listed = fs.readdirSync(base);
  const inside = path.join(base, listed[M.SCAN_MAX_DIRS - 1]);
  const outside = path.join(base, listed[M.SCAN_MAX_DIRS]);
  const inCopy = age(G.writeTranscript(inside, "t2843-cf1", NO_REPORT), 3600);
  age(G.writeTranscript(outside, "t2843-cf1", NO_REPORT), 60);
  G.writeTranscript(outside, "t2843-cf2", NO_REPORT);
  const realDate = Date.now;
  const frozen = realDate();
  Date.now = () => frozen;
  try {
    const r = withBase(base, () => M.locateTranscript(scanInput("t2843-cf1")));
    assert.ok(r && sameFile(r.path, inCopy), `dir #${M.SCAN_MAX_DIRS} is scanned, the newer copy past it is not: ${JSON.stringify(r)}`);
    const none = withBase(base, () => M.locateTranscript(scanInput("t2843-cf2")));
    assert.strictEqual(none, null, `a copy only past the cap is not found: ${JSON.stringify(none)}`);
  } finally { Date.now = realDate; }
});
caseEnd();

caseBegin("scan-deadline-returns-the-best-copy-seen-so-far", "hooks/lib/transcript-reader/locate.js");
test("scan-deadline-returns-the-best-copy-seen-so-far", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-dl2";
  const base = path.join(SB, "dl2-projects");
  for (let i = 0; i < 4; i++) fs.mkdirSync(path.join(base, `c--d-${i}`), { recursive: true });
  const listed = fs.readdirSync(base);
  const first = age(G.writeTranscript(path.join(base, listed[0]), sid, NO_REPORT), 3600);
  const newest = age(G.writeTranscript(path.join(base, listed[listed.length - 1]), sid, NO_REPORT), 60);
  const ctl = withBase(base, () => locateTranscript(scanInput(sid)));
  assert.ok(ctl && sameFile(ctl.path, newest), `control: a full scan takes the newest copy: ${JSON.stringify(ctl)}`);
  const r = withFastClock(() => withBase(base, () => locateTranscript(scanInput(sid))));
  assert.ok(r && sameFile(r.path, first), `the deadline stops after the first dir and keeps its copy: ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("scan-never-picks-an-excluded-or-empty-newest-copy", "hooks/lib/transcript-reader/locate.js");
test("scan-never-picks-an-excluded-or-empty-newest-copy", () => {
  const locateTranscript = F.need(LOCATE, "locateTranscript");
  const sid = "t2843-x";
  const base = path.join(SB, "x-projects");
  const valid = age(G.writeTranscript(path.join(base, "c--valid"), sid, NO_REPORT), 3600);
  const ex = age(G.writeTranscript(path.join(base, "c--excluded"), sid, NO_REPORT), 600);
  fs.mkdirSync(path.join(base, "c--empty"), { recursive: true });
  fs.writeFileSync(path.join(base, "c--empty", `${sid}.jsonl`), "");
  const ctl = withBase(base, () => locateTranscript(scanInput(sid)));
  assert.ok(ctl && sameFile(ctl.path, ex), `control: without exclude the newer non-empty copy wins: ${JSON.stringify(ctl)}`);
  const exclude = process.platform === "win32" ? ex.toUpperCase() : ex;
  const r = withBase(base, () => locateTranscript(scanInput(sid), { exclude }));
  assert.ok(r && sameFile(r.path, valid), `the excluded and the empty copy are skipped: ${JSON.stringify(r)}`);
});
caseEnd();
