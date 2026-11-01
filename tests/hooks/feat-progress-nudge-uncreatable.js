#!/usr/bin/env node
"use strict";
// Tests: hooks/progress-nudge.js, hooks/progress-nudge/evaluate.js
// Tags: TL2, hooks, progress-nudge, session-progress, step-complete, fail-open, regression, symlink, lock-timeout, scope:common
// #2594: when session-progress.md cannot be created (a directory sits at its path), a step-complete
// candidate (PostToolUse Bash / Agent / Task, Stop) delivers nothing AND consumes nothing — the
// pressure state (event_cursor, baseline, request count) is left as it was — so the very next
// candidate after the obstacle is gone still reports the complete.
// TL3 gap (what this test does NOT catch):
// - the hook registration in settings.json firing under a real Claude Code host (envelope is synthetic)
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "pn-uncreatable-"));
const T = path.join(TMP, "t");
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [T, CFG, TRANSCRIPTS]) fs.mkdirSync(d);
// markStep reads the approval gates from $AGENTS_MAIN_ROOT/.env, never process.env.
fs.writeFileSync(path.join(CFG, ".env"), "CONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n");
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const HOOK = path.join(ROOT, "hooks", "progress-nudge.js");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const PF = require(path.join(ROOT, "hooks", "lib", "progress-file"));

let passed = 0;
let failed = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const failures = () => failed;

const transcriptOf = (sid) => path.join(T, `${sid}.jsonl`);

function seed(sid) {
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  fs.writeFileSync(transcriptOf(sid), Buffer.alloc(10 * 1024, 120));
}

// hookRaw(sid, event, tool, timeoutMs) -> the spawnSync result of one hook run.
function hookRaw(sid, event, tool, timeoutMs) {
  const e = { session_id: sid, transcript_path: transcriptOf(sid), cwd: T, hook_event_name: event };
  if (event === "PostToolUse") Object.assign(e, { tool_name: tool, tool_input: tool === "Bash" ? { command: "true" } : {}, tool_response: {} });
  if (event === "Stop") e.stop_hook_active = false;
  return spawnSync(process.execPath, [HOOK], { input: JSON.stringify(e), cwd: TMP, encoding: "utf8", timeout: timeoutMs || 60000 });
}

// hook(sid, event, tool) -> additionalContext string ("" when the hook was silent).
function hook(sid, event, tool) {
  const r = hookRaw(sid, event, tool);
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${r.stderr}`);
  const j = JSON.parse(String(r.stdout).trim() || "{}");
  const h = j && j.hookSpecificOutput;
  return h && typeof h.additionalContext === "string" ? h.additionalContext : "";
}

// The obstacle: a directory at the session-progress.md path, so ensureProgressFile yields no path.
function block(sid) {
  const p = PF.progressPathFor(sid);
  fs.rmSync(p, { recursive: true, force: true });
  fs.mkdirSync(p, { recursive: true });
  fs.writeFileSync(path.join(p, "keep"), "x");
  return p;
}
function unblock(sid) {
  fs.rmSync(PF.progressPathFor(sid), { recursive: true, force: true });
}
const pressure = (sid) => PF.readPressure(sid);
const isRegular = (p) => { try { return fs.lstatSync(p).isFile(); } catch (_) { return false; } };

const CANDIDATES = [["PostToolUse", "Bash"], ["PostToolUse", "Agent"], ["PostToolUse", "Task"], ["Stop", null]];

caseBegin("fresh-session-uncreatable-consumes-nothing", "hooks/progress-nudge/evaluate.js");
test("fresh-session-uncreatable-consumes-nothing", () => noNewFailures(failures, () => {
  const sid = "pnu-fresh";
  seed(sid);
  S.markStep(sid, "research", "complete");
  block(sid);
  for (const [ev, tool] of CANDIDATES) {
    const label = tool ? `${ev} ${tool}` : ev;
    check(`U1: ${label} with session-progress.md uncreatable delivers no request`, () => eq(hook(sid, ev, tool), "", "additionalContext"));
    check(`U1: ${label} with session-progress.md uncreatable writes no pressure state (no cursor, baseline or request)`, () => eq(pressure(sid), null, "progress-pressure.json"));
  }
}));
caseEnd();

caseBegin("fresh-session-recovers-after-obstacle-removed", "hooks/progress-nudge/evaluate.js");
test("fresh-session-recovers-after-obstacle-removed", () => noNewFailures(failures, () => {
  const sid = "pnu-fresh";
  unblock(sid);
  const ctx = hook(sid, "PostToolUse", "Bash");
  check("U2: the first Bash after the obstacle is gone asks for an update", () => (ctx.startsWith("[progress check]") ? undefined : `ctx=${show(ctx.slice(0, 300))}`));
  check("U2: the request names the complete held back while uncreatable (research)", () => (ctx.includes("step complete: research") ? undefined : `ctx=${show(ctx.slice(0, 300))}`));
  check("U2: the request also names workflow_init (the cursor was never moved)", () => (ctx.includes("workflow_init") ? undefined : `ctx=${show(ctx.slice(0, 300))}`));
  check("U2: session-progress.md now exists as a regular file", () => eq(isRegular(PF.progressPathFor(sid)), true, "regular file"));
  check("U2: the cursor is now committed", () => eq(typeof (pressure(sid) || {}).event_cursor, "number", "typeof event_cursor"));
  check("U2: control — the next Bash does not repeat the complete", () => eq(hook(sid, "PostToolUse", "Bash").includes("research"), false, "repeated"));
}));
caseEnd();

caseBegin("primed-session-uncreatable-leaves-pressure-unchanged", "hooks/progress-nudge/evaluate.js");
test("primed-session-uncreatable-leaves-pressure-unchanged", () => noNewFailures(failures, () => {
  const sid = "pnu-primed";
  seed(sid);
  hook(sid, "PostToolUse", "Bash");
  hook(sid, "PostToolUse", "Bash");
  const before = pressure(sid);
  check("U3: fixture — the primed session has a cursor and a baseline", () => {
    eq(typeof (before || {}).event_cursor, "number", "typeof event_cursor");
    eq((before || {}).baseline_bytes !== undefined, true, "baseline_bytes present");
  });
  S.markStep(sid, "research", "complete");
  block(sid);
  for (const [ev, tool] of CANDIDATES) {
    const label = tool ? `${ev} ${tool}` : ev;
    check(`U3: ${label} delivers no request while session-progress.md is a directory`, () => eq(hook(sid, ev, tool), "", "additionalContext"));
    check(`U3: ${label} leaves event_cursor, baseline and requests_at exactly as they were`, () => eq(pressure(sid), before, "progress-pressure.json"));
  }
}));
caseEnd();

caseBegin("primed-session-recovers-after-obstacle-removed", "hooks/progress-nudge.js");
test("primed-session-recovers-after-obstacle-removed", () => noNewFailures(failures, () => {
  const sid = "pnu-primed";
  unblock(sid);
  const ctx = hook(sid, "PostToolUse", "Bash");
  check("U4: the next Bash after recovery delivers the held-back complete", () => (ctx.includes("step complete: research") ? undefined : `ctx=${show(ctx.slice(0, 300))}`));
  check("U4: session-progress.md is recreated as a regular file", () => eq(isRegular(PF.progressPathFor(sid)), true, "regular file"));
  check("U4: control — a second Bash is silent about it", () => eq(hook(sid, "PostToolUse", "Bash").includes("research"), false, "repeated"));
}));
caseEnd();

const { sidecarPath } = require(path.join(ROOT, "hooks", "lib", "control-sidecar"));
// The real lock updatePressure takes; a token naming a live pid with a fresh mtime is never stolen early.
const lockPathOf = (sid) => `${sidecarPath(sid, PF.PRESSURE_SUFFIX, { forWrite: true })}.lock`;
const holdLock = (sid) => fs.writeFileSync(lockPathOf(sid), `${process.pid}.held-by-test`);
const freeLock = (sid) => fs.rmSync(lockPathOf(sid), { force: true });
function prime(sid) {
  seed(sid);
  hook(sid, "PostToolUse", "Bash");
  hook(sid, "PostToolUse", "Bash");
}

caseBegin("symlinked-progress-file-left-alone-and-recovers", "hooks/progress-nudge/evaluate.js");
test("symlinked-progress-file-left-alone-and-recovers", (t) => noNewFailures(failures, () => {
  const sid = "pnu-symlink";
  seed(sid);
  S.markStep(sid, "research", "complete");
  const link = PF.progressPathFor(sid);
  const target = path.join(TMP, "symlink-target.md");
  const targetBytes = Buffer.from("owner content that must stay byte-identical\n", "utf8");
  fs.writeFileSync(target, targetBytes);
  fs.mkdirSync(path.dirname(link), { recursive: true });
  let linkErr = null;
  try { fs.symlinkSync(target, link, "file"); } catch (e) { linkErr = e; }
  if (linkErr && linkErr.code === "EPERM") {
    t.skip("C1 symlinked session-progress.md — fs.symlinkSync threw EPERM (no symlink privilege on this host)");
    return;
  } else {
    check("C1: fixture — session-progress.md is a symlink", () => (linkErr ? `symlinkSync: ${linkErr.message}` : eq(fs.lstatSync(link).isSymbolicLink(), true, "isSymbolicLink")));
    for (const [ev, tool] of CANDIDATES) {
      const label = tool ? `${ev} ${tool}` : ev;
      const r = hookRaw(sid, ev, tool);
      check(`C1: ${label} with a symlinked session-progress.md writes nothing beyond the quiet {}`, () => eq([r.status, String(r.stdout).trim()], [0, "{}"], "[exit, stdout]"));
      check(`C1: ${label} leaves the link target byte-for-byte unchanged`, () => eq(fs.readFileSync(target).equals(targetBytes), true, "target bytes equal"));
      check(`C1: ${label} leaves the symlink in place (not replaced by a regular file)`, () => eq(fs.lstatSync(link).isSymbolicLink(), true, "isSymbolicLink"));
      check(`C1: ${label} consumes nothing (no pressure state)`, () => eq(pressure(sid), null, "progress-pressure.json"));
    }
    fs.unlinkSync(link);
    const ctx = hook(sid, "PostToolUse", "Bash");
    check("C1: after the link is removed the next Bash delivers the pending complete", () => (ctx.includes("step complete: research") ? undefined : `ctx=${show(ctx.slice(0, 300))}`));
    check("C1: session-progress.md is now a regular file and the old target is still untouched", () => eq([isRegular(link), fs.readFileSync(target).equals(targetBytes)], [true, true], "[regular, target equal]"));
  }
}));
caseEnd();

caseBegin("cursor-phase-lock-held-keeps-complete-pending", "hooks/progress-nudge/evaluate.js");
test("cursor-phase-lock-held-keeps-complete-pending", () => noNewFailures(failures, () => {
  const sid = "pnu-lock-cursor";
  prime(sid);
  const before = pressure(sid);
  S.markStep(sid, "research", "complete");
  holdLock(sid);
  const t0 = Date.now();
  const r = hookRaw(sid, "Stop", null, 8000);
  const elapsed = Date.now() - t0;
  freeLock(sid);
  // EXPECTED-FAIL until write-code: the cursor phase's updatePressure passes no lockWaitMs, so a
  // live-holder lock blocks it up to LOCK_HARD_STALE_MS (10 s), past the 5 s hook timeout.
  check("C2a: with a live-holder lock held the hook exits on its own (status 0) in under 4000 ms", () => eq([r.error ? r.error.code : null, r.status, elapsed < 4000], [null, 0, true], `[spawn error, exit, under 4000 ms (elapsed=${elapsed})]`));
  check("C2a: the lock-blocked run consumed nothing (event_cursor, baseline, requests unchanged)", () => eq(pressure(sid), before, "progress-pressure.json"));
  const ctx = hook(sid, "PostToolUse", "Bash");
  check("C2a: once the lock is free the next Bash delivers the held-back complete exactly once", () => eq(ctx.split("step complete: research").length - 1, 1, `occurrences in ctx=${show(ctx.slice(0, 300))}`));
  check("C2a: control — the Bash after that does not repeat it", () => eq(hook(sid, "PostToolUse", "Bash").includes("research"), false, "repeated"));
}));
caseEnd();

caseBegin("judge-phase-lock-timeout-delivers-committed-complete", "hooks/progress-nudge/evaluate.js");
test("judge-phase-lock-timeout-delivers-committed-complete", () => noNewFailures(failures, () => {
  const EV = require(path.join(ROOT, "hooks", "progress-nudge", "evaluate"));
  const original = PF.updatePressure;
  for (const [ev, tool] of [["Stop", null], ["PostToolUse", "Bash"]]) {
    const label = tool ? `${ev} ${tool}` : ev;
    const sid = `pnu-judge-${tool ? "bash" : "stop"}`;
    prime(sid);
    const cursorBefore = (pressure(sid) || {}).event_cursor;
    S.markStep(sid, "research", "complete");
    // Real updatePressure throughout; the lock is taken only once the cursor phase has returned.
    const calls = [];
    PF.updatePressure = (s, fn, opts) => {
      const out = original(s, fn, opts);
      calls.push({ lockWaitMs: opts && opts.lockWaitMs, out });
      if (calls.length === 1) holdLock(s);
      return out;
    };
    let ctx = null;
    try {
      ctx = EV.evaluate({ sid, event: ev, tool, transcriptPath: transcriptOf(sid), now: Date.now() });
    } finally {
      PF.updatePressure = original;
      freeLock(sid);
    }
    const cursorAfter = (pressure(sid) || {}).event_cursor;
    check(`C2b: ${label} cursor phase committed the complete before the lock was taken`, () => eq([calls.length > 0 && calls[0].out, typeof cursorAfter === "number" && cursorAfter > cursorBefore], [["research"], true], "[phase-a result, cursor advanced]"));
    check(`C2b: ${label} judge phase waited a bounded time and timed out`, () => eq([calls.length, calls.length > 1 && typeof calls[1].lockWaitMs === "number", calls.length > 1 ? calls[1].out : "not-called"], [2, true, null], "[calls, bounded, judge result]"));
    check(`C2b: ${label} the fallback still delivers the committed complete`, () => (typeof ctx === "string" && ctx.includes("step complete: research") ? undefined : `ctx=${show(ctx && ctx.slice(0, 300))}`));
    check(`C2b: ${label} control — the next Bash with the lock free does not repeat it`, () => eq(hook(sid, "PostToolUse", "Bash").includes("research"), false, "repeated"));
  }
}));
caseEnd();
