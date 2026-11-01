#!/usr/bin/env node
"use strict";
// Tests: hooks/subagent-start.js
// Tags: TL2, hooks, verbose-prompt, subagent-start, conv-lang, plan-lang, fail-open, scope:issue-specific
// #2240 Change 3: SubagentStart reads session_id from its payload and injects VERBOSE_PROMPT
// when that (parent) session's frozen verbose_prompt flag is on. Off, missing or a broken payload
// injects nothing extra, and the CONV_LANG and PLAN_LANG lines stay as they were.
// TL3 gap (what this test does NOT catch):
// - the SubagentStart registration firing under a real Claude Code host with a real payload
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
// bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "sas-verbose-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [CFG, TRANSCRIPTS]) fs.mkdirSync(d);
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
const HOOK = path.join(ROOT, "hooks", "subagent-start.js");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const { VERBOSE_PROMPT_TEXT } = require(path.join(ROOT, "hooks", "lib", "verbose-prompt"));

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

// seed(sid, verbose) — a state whose frozen verbose_prompt flag is <verbose> (undefined: never set).
function seed(sid, verbose) {
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  if (verbose !== undefined) S.updateTopLevel(sid, (s) => { s.verbose_prompt = verbose; });
}

// start(input, env) -> additionalContext lines ([] for "{}"); throws on a bad run or envelope.
function start(input, env) {
  const e = Object.assign({}, process.env, env || {});
  const r = spawnSync(process.execPath, [HOOK], { input, cwd: TMP, env: e, encoding: "utf8", timeout: 60000 });
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${String(r.stderr).slice(0, 300)}`);
  const j = JSON.parse(String(r.stdout).trim() || "{}");
  if (!j.hookSpecificOutput) return [];
  if (j.hookSpecificOutput.hookEventName !== "SubagentStart") throw new Error(`hookEventName=${show(j.hookSpecificOutput.hookEventName)}`);
  return String(j.hookSpecificOutput.additionalContext || "").split("\n");
}
const payload = (sid) => JSON.stringify({ session_id: sid, agent_id: "agent-1", agent_type: "general-purpose", hook_event_name: "SubagentStart" });
const LANGS = { CONV_LANG: "japanese", PLAN_LANG: "japanese" };
const hasVerbose = (lines) => lines.includes(VERBOSE_PROMPT_TEXT);
const langLines = (lines) => [lines.some((x) => x.startsWith("Respond to the user in japanese.")), lines.some((x) => x.startsWith("Write planning artifacts (files under the plans directory) in japanese."))];

caseBegin("verbose-prompt-on-is-injected", "hooks/subagent-start.js");
test("verbose-prompt-on-is-injected", verdict(() => {
  seed("sas-on", true);
  check("V0: fixture — the seeded state carries verbose_prompt=true", () => eq((S.readState("sas-on") || {}).verbose_prompt, true, "verbose_prompt"));
  const lines = start(payload("sas-on"), LANGS);
  check("V1: verbose_prompt on -> VERBOSE_PROMPT line injected exactly once", () => eq(lines.filter((x) => x === VERBOSE_PROMPT_TEXT).length, 1, `VERBOSE lines in ${show(lines)}`));
  check("V2: verbose_prompt on -> the CONV_LANG and PLAN_LANG lines are kept", () => eq(langLines(lines), [true, true], "[conv, plan]"));
  check("V3: verbose_prompt on with no language set -> VERBOSE_PROMPT is still injected", () => eq(hasVerbose(start(payload("sas-on"), {})), true, "VERBOSE present"));
}));
caseEnd();

caseBegin("verbose-prompt-off-or-unknown-is-not-injected", "hooks/subagent-start.js");
test("verbose-prompt-off-or-unknown-is-not-injected", verdict(() => {
  seed("sas-off", false);
  seed("sas-unset");
  const off = start(payload("sas-off"), LANGS);
  check("O1: verbose_prompt false -> no VERBOSE_PROMPT line", () => eq(hasVerbose(off), false, "VERBOSE present"));
  check("O1: control — CONV_LANG and PLAN_LANG lines are kept", () => eq(langLines(off), [true, true], "[conv, plan]"));
  check("O2: verbose_prompt never set -> no VERBOSE_PROMPT line", () => eq(hasVerbose(start(payload("sas-unset"), LANGS)), false, "VERBOSE present"));
  check("O3: session with no state file -> no VERBOSE_PROMPT line", () => eq(hasVerbose(start(payload("sas-none"), LANGS)), false, "VERBOSE present"));
  check("O4: no languages set and verbose off -> no VERBOSE_PROMPT line", () => eq(hasVerbose(start(payload("sas-off"), {})), false, "VERBOSE present"));
}));
caseEnd();

caseBegin("broken-payload-fails-open", "hooks/subagent-start.js");
test("broken-payload-fails-open", verdict(() => {
  const cases = [
    ["malformed JSON", "{not json"],
    ["empty stdin", ""],
    ["session_id not a string", JSON.stringify({ session_id: 42 })],
    ["session_id with path traversal", JSON.stringify({ session_id: "../sas-on" })],
    ["no session_id", JSON.stringify({ agent_id: "agent-1" })],
  ];
  for (const [label, input] of cases) {
    let lines = null;
    check(`B1: ${label} -> exit 0, no VERBOSE_PROMPT line`, () => { lines = start(input, LANGS); eq(hasVerbose(lines), false, "VERBOSE present"); });
    check(`B2: ${label} -> CONV_LANG and PLAN_LANG lines still injected`, () => eq(langLines(lines || []), [true, true], "[conv, plan]"));
  }
}));
caseEnd();
