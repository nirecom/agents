#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/planning-phase.js, hooks/lang-inject.js
// Tags: TL2, hooks, lang, plan-lang, planning-phase, refactor, scope:issue-specific
// #2240 Change 1: isPlanning and PLAN_STEPS move from hooks/lang-inject.js into
// hooks/lib/planning-phase.js so post-compact can gate PLAN_LANG on the same rule.
// lang-inject.js keeps exporting isPlanning, and it must be the lib's function, not a copy.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "planning-phase-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [CFG, TRANSCRIPTS]) fs.mkdirSync(d);
// markStep reads the approval gates from $AGENTS_MAIN_ROOT/.env, never process.env.
fs.writeFileSync(path.join(CFG, ".env"), "CONFIRM_INTENT=off\nCONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n");
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
delete process.env.CONV_LANG;
delete process.env.PLAN_LANG;
after(() => {
  process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const LIB = path.join(ROOT, "hooks", "lib", "planning-phase.js");
const LANG_INJECT = path.join(ROOT, "hooks", "lang-inject.js");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));

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
// verdict(fn) -> the node:test body of one case: it fails when a check inside fn failed.
const verdict = (fn) => () => noNewFailures(() => failed, fn);
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}

let PP = null;
let loadError = null;
try { PP = require(LIB); } catch (e) { loadError = e; }
function lib() {
  if (!PP) throw new Error(`hooks/lib/planning-phase.js not loadable: ${loadError && String(loadError.message).split("\n")[0]}`);
  return PP;
}

// seed(sid, statuses) — a fresh state with each named planning step marked as given.
function seed(sid, statuses) {
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  for (const [step, status] of Object.entries(statuses || {})) S.markStep(sid, step, status);
}

caseBegin("planning-phase-exports", "hooks/lib/planning-phase.js");
test("planning-phase-exports", verdict(() => {
  check("E1: PLAN_STEPS is exactly clarify_intent, outline, detail", () => eq(lib().PLAN_STEPS, ["clarify_intent", "outline", "detail"], "PLAN_STEPS"));
  check("E2: isPlanning is a function", () => eq(typeof lib().isPlanning, "function", "typeof isPlanning"));
}));
caseEnd();

caseBegin("is-planning-verdicts", "hooks/lib/planning-phase.js");
test("is-planning-verdicts", verdict(() => {
  seed("pp-fresh");
  check("V1: every planning step pending -> true", () => eq(lib().isPlanning("pp-fresh"), true, "isPlanning"));
  seed("pp-outline", { clarify_intent: "skipped", outline: "in_progress" });
  check("V2: one planning step in_progress -> true", () => eq(lib().isPlanning("pp-outline"), true, "isPlanning"));
  seed("pp-done", { clarify_intent: "skipped", outline: "skipped", detail: "skipped" });
  check("V3: every planning step skipped -> false", () => eq(lib().isPlanning("pp-done"), false, "isPlanning"));
  check("V4: no session id -> false", () => eq([lib().isPlanning(undefined), lib().isPlanning(""), lib().isPlanning(null)], [false, false, false], "isPlanning"));
  check("V5: a session with no state file -> false", () => eq(lib().isPlanning("pp-no-state"), false, "isPlanning"));
  fs.mkdirSync(path.dirname(S.getStatePath("pp-corrupt")), { recursive: true });
  fs.writeFileSync(S.getStatePath("pp-corrupt"), "{not json");
  check("V6: an unreadable state file -> false (fail-open, no throw)", () => eq(lib().isPlanning("pp-corrupt"), false, "isPlanning"));
}));
caseEnd();

// probe(code) — runs code in a child with lang-inject.js required; lang-inject's own stdout is
// ignored and the probe answers on stderr after the marker.
function probe(code) {
  const script = `const li = require(${JSON.stringify(LANG_INJECT)}); ${code}`;
  const r = spawnSync(process.execPath, ["-e", script], { input: "{}", cwd: TMP, encoding: "utf8", timeout: 60000 });
  const m = /PROBE=(.*)/.exec(String(r.stderr || ""));
  if (!m) throw new Error(`probe failed: exit=${r.status} stderr=${String(r.stderr).slice(0, 300)}`);
  return m[1];
}

caseBegin("lang-inject-keeps-the-export", "hooks/lang-inject.js");
test("lang-inject-keeps-the-export", verdict(() => {
  check("X1: require('hooks/lang-inject.js').isPlanning is still a function", () => eq(probe("process.stderr.write('PROBE=' + typeof li.isPlanning);"), "function", "typeof"));
  check("X2: lang-inject's isPlanning is the lib's function, not a copy", () => eq(probe(`process.stderr.write('PROBE=' + (li.isPlanning === require(${JSON.stringify(LIB)}).isPlanning));`), "true", "same function"));
  check("X4: control — lang-inject's isPlanning gives the same verdicts on the seeded sessions", () => eq(probe("process.stderr.write('PROBE=' + ['pp-fresh', 'pp-outline', 'pp-done', 'pp-corrupt'].map((s) => li.isPlanning(s)).join(','));"), "true,true,false,false", "verdicts"));
  check("X3: lang-inject.js no longer defines its own PLAN_STEPS list", () => eq(/\bPLAN_STEPS\s*=/.test(fs.readFileSync(LANG_INJECT, "utf8")), false, "local PLAN_STEPS definition"));
}));
caseEnd();
