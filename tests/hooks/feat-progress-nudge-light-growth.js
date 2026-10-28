#!/usr/bin/env node
"use strict";
// Tests: hooks/progress-nudge.js, hooks/progress-nudge/light.js
// Tags: TL2, hooks, progress-nudge, light-path, elapsed-trigger, transcript-growth, regression, conv-lang, scope:common
// #2594: the cheap pre-check (needsFullPath) escalates on elapsed time only when the transcript
// also grew past the baseline — the elapsed trigger of lib/progress-pressure fires only with growth,
// so an old baseline over an idle transcript must not send every non-Bash call down the full path.
// TL3 gap (what this test does NOT catch):
// - the PostToolUse matcher "" registration firing on every tool under a real Claude Code host
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "pn-light-growth-"));
const T = path.join(TMP, "t");
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [T, CFG, TRANSCRIPTS]) fs.mkdirSync(d);
fs.writeFileSync(path.join(CFG, ".env"), "CONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n");
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const HOOK = path.join(ROOT, "hooks", "progress-nudge.js");
const EVALUATE = path.join(ROOT, "hooks", "progress-nudge", "evaluate.js");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const PF = require(path.join(ROOT, "hooks", "lib", "progress-file"));
const { ELAPSED_MS, RISK_DIVISOR } = require(path.join(ROOT, "hooks", "lib", "progress-pressure"));
const { needsFullPath } = require(path.join(ROOT, "hooks", "progress-nudge", "light"));
const LIGHT_MS = ELAPSED_MS / RISK_DIVISOR;
const BASE = 10 * 1024;

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

const transcriptOf = (sid) => path.join(T, `${sid}.jsonl`);

// fixture(sid, size, pressure) — a transcript of <size> bytes and a pressure sidecar of exactly
// <pressure> (no progress_path, so the session-progress.md mtime branch stays out of the verdict).
function fixture(sid, size, pressure) {
  fs.writeFileSync(transcriptOf(sid), Buffer.alloc(size, 120));
  if (!PF.mergePressure(sid, pressure)) throw new Error(`fixture: pressure write failed for ${sid}`);
}
const iso = (ms) => new Date(ms).toISOString();

caseBegin("old-baseline-escalates-only-with-growth", "hooks/progress-nudge/light.js");
{
  const now = Date.now();
  const old = iso(now - LIGHT_MS - 60000);
  fixture("lg-idle", BASE, { baseline_bytes: BASE, baseline_at: old });
  check("L1: baseline older than the halved elapsed limit, transcript == baseline -> light path (false)", () => eq(needsFullPath("lg-idle", transcriptOf("lg-idle"), now), false, "needsFullPath"));
  fixture("lg-grown", BASE + 1, { baseline_bytes: BASE, baseline_at: old });
  check("L2: same age, transcript one byte past the baseline -> full path (true)", () => eq(needsFullPath("lg-grown", transcriptOf("lg-grown"), now), true, "needsFullPath"));
  fixture("lg-far", BASE, { baseline_bytes: BASE, baseline_at: iso(now - 10 * ELAPSED_MS) });
  check("L3: a baseline ten elapsed limits old over an idle transcript -> still the light path", () => eq(needsFullPath("lg-far", transcriptOf("lg-far"), now), false, "needsFullPath"));
}
caseEnd();

caseBegin("elapsed-boundary-and-baseline-controls", "hooks/progress-nudge/light.js");
{
  const now = Date.now();
  fixture("lg-nobase-at", BASE, { baseline_bytes: BASE });
  check("L4: baseline_at absent -> full path (true)", () => eq(needsFullPath("lg-nobase-at", transcriptOf("lg-nobase-at"), now), true, "needsFullPath"));
  fixture("lg-null-at", BASE, { baseline_bytes: BASE, baseline_at: null });
  check("L4: baseline_at null -> full path (true)", () => eq(needsFullPath("lg-null-at", transcriptOf("lg-null-at"), now), true, "needsFullPath"));
  fixture("lg-young", BASE + 1, { baseline_bytes: BASE, baseline_at: iso(now - LIGHT_MS + 1000) });
  check("L5: growth but the baseline is just under the halved elapsed limit -> light path (false)", () => eq(needsFullPath("lg-young", transcriptOf("lg-young"), now), false, "needsFullPath"));
  fixture("lg-edge", BASE + 1, { baseline_bytes: BASE, baseline_at: iso(now - LIGHT_MS) });
  check("L6: growth and the baseline exactly at the halved elapsed limit -> full path (true)", () => eq(needsFullPath("lg-edge", transcriptOf("lg-edge"), now), true, "needsFullPath"));
  fixture("lg-shrunk", BASE - 1, { baseline_bytes: BASE, baseline_at: iso(now - LIGHT_MS - 60000) });
  check("L7: control — a transcript smaller than the baseline (rotated) -> full path (true)", () => eq(needsFullPath("lg-shrunk", transcriptOf("lg-shrunk"), now), true, "needsFullPath"));
}
caseEnd();

// Hook-level: a --require preload records every call that reaches the full path (evaluate).
const MARK = path.join(TMP, "evaluate-calls");
const PRELOAD = path.join(TMP, "count-evaluate.js");
fs.writeFileSync(PRELOAD, [
  "const ev = require(process.env.LG_EVALUATE);",
  "const orig = ev.evaluate;",
  "ev.evaluate = function (o) { require('fs').appendFileSync(process.env.LG_MARK, o.event + ':' + o.tool + '\\n'); return orig.apply(this, arguments); };",
].join("\n"));

function hook(sid, event, tool) {
  const e = { session_id: sid, transcript_path: transcriptOf(sid), cwd: T, hook_event_name: event };
  if (event === "PostToolUse") Object.assign(e, { tool_name: tool, tool_input: tool === "Bash" ? { command: "true" } : {}, tool_response: {} });
  const env = Object.assign({}, process.env, { NODE_OPTIONS: `--require ${PRELOAD.replace(/\\/g, "/")}`, LG_EVALUATE: EVALUATE, LG_MARK: MARK });
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(e), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${r.stderr}`);
  const j = JSON.parse(String(r.stdout).trim() || "{}");
  const h = j && j.hookSpecificOutput;
  return h && typeof h.additionalContext === "string" ? h.additionalContext : "";
}
const evaluateCalls = () => { try { return fs.readFileSync(MARK, "utf8").split("\n").filter(Boolean); } catch (_) { return []; } };

caseBegin("hook-read-call-stays-light-on-idle-transcript", "hooks/progress-nudge.js");
{
  const sid = "lg-hook";
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  fs.writeFileSync(transcriptOf(sid), Buffer.alloc(BASE, 120));
  hook(sid, "PostToolUse", "Bash");
  hook(sid, "PostToolUse", "Bash");
  const primed = PF.readPressure(sid) || {};
  check("L8: fixture — priming committed a baseline at the transcript size", () => eq(primed.baseline_bytes, BASE, "baseline_bytes"));
  check("L8: fixture — the preload saw the priming Bash calls reach evaluate", () => eq(evaluateCalls().length, 2, "evaluate calls"));
  if (!PF.mergePressure(sid, { baseline_at: iso(Date.now() - LIGHT_MS - 60000) })) throw new Error("fixture: ageing the baseline failed");
  fs.rmSync(MARK, { force: true });
  const before = PF.readPressure(sid);
  check("L8: a Read call with an old baseline over an idle transcript stays silent", () => eq(hook(sid, "PostToolUse", "Read"), "", "additionalContext"));
  check("L8: that Read call never reaches the full path", () => eq(evaluateCalls(), [], "evaluate calls"));
  check("L8: that Read call leaves the pressure state unchanged", () => eq(PF.readPressure(sid), before, "progress-pressure.json"));
  fs.appendFileSync(transcriptOf(sid), Buffer.alloc(1, 121));
  hook(sid, "PostToolUse", "Read");
  check("L9: control — after one byte of growth the same Read call takes the full path", () => eq(evaluateCalls(), ["PostToolUse:Read"], "evaluate calls"));
}
caseEnd();

// #2731 S3-7: the nudge reaches the model through withConvLang — the directive leads once.
// A second preload pins evaluate()'s answer so the case isolates the emit line.
const CTX_PRELOAD = path.join(TMP, "fixed-evaluate.js");
fs.writeFileSync(CTX_PRELOAD, "require(process.env.LG_EVALUATE).evaluate = () => process.env.LG_CTX;\n");
function hookCtx(sid, lang) {
  const e = { session_id: sid, transcript_path: transcriptOf(sid), cwd: T, hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: { command: "true" }, tool_response: {} };
  const env = Object.assign({}, process.env, { NODE_OPTIONS: `--require ${CTX_PRELOAD.replace(/\\/g, "/")}`, LG_EVALUATE: EVALUATE, LG_CTX: "[progress check] update the session-progress file.", CONV_LANG: lang });
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(e), cwd: TMP, env, encoding: "utf8", timeout: 60000 });
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${r.stderr}`);
  const h = (JSON.parse(String(r.stdout).trim() || "{}") || {}).hookSpecificOutput;
  return h && typeof h.additionalContext === "string" ? h.additionalContext : "";
}
caseBegin("nudge-additional-context-conv-lang", "hooks/progress-nudge.js");
{
  const C = require("../lib/system-message-contract");
  const sid = "lg-lang";
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  fs.writeFileSync(transcriptOf(sid), Buffer.alloc(BASE, 120));
  const ja = hookCtx(sid, "japanese");
  check("L10: fixture — the pinned nudge reaches additionalContext", () => (ja.includes("[progress check]") ? undefined : `got ${show(ja)}`));
  check("L10: CONV_LANG=japanese -> the directive leads additionalContext exactly once", () => (C.prefixedOnce(ja, "japanese") ? undefined : `got ${show(ja)}`));
  const en = hookCtx(sid, "english");
  check("L11: CONV_LANG=english -> no directive", () => eq(C.countDirective(en), 0, "directive count"));
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
