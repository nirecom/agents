#!/usr/bin/env node
"use strict";
// Tests: hooks/conv-lang-reinject.js
// Tags: TL2, hooks, conv-lang, reinject, post-tool-use, user-prompt-submit, sidecar, fail-open, scope:issue-specific
// #2731 R1: in long autonomous stretches the CONV_LANG directive is re-injected at PostToolUse once
// the transcript has grown by 128KB since the baseline. UserPromptSubmit resets the baseline;
// subagent calls, a no-op CONV_LANG, a shrunk transcript and an unwritable sidecar emit {}.
// TL3 gap (what this test does NOT catch):
// - the UserPromptSubmit / PostToolUse registrations firing under a real Claude Code host
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
// bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "conv-reinject-"));
const CFG = path.join(TMP, "cfg");
const TRANSCRIPTS = path.join(TMP, "transcripts");
for (const d of [CFG, TRANSCRIPTS]) fs.mkdirSync(d);
process.env.AGENTS_MAIN_ROOT = CFG;
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TRANSCRIPTS;
delete process.env.CONV_LANG;
delete process.env.PLAN_LANG;
process.on("exit", () => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});

const ROOT = path.join(__dirname, "..", "..");
const HOOK = path.join(ROOT, "hooks", "conv-lang-reinject.js");
const { readSidecar, sidecarPath } = require(path.join(ROOT, "hooks", "lib", "handoff-sidecar"));
const SUFFIX = "conv-lang-reinject.json";
const KB128 = 128 * 1024;
const CONV_HEAD = "Respond to the user in japanese.";

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

const tpath = (sid) => path.join(TRANSCRIPTS, `${sid}.jsonl`);
const grow = (sid, n) => fs.appendFileSync(tpath(sid), "x".repeat(n));
const size = (sid) => fs.statSync(tpath(sid)).size;
const baseline = (sid) => (readSidecar(sid, SUFFIX) || {}).baselineBytes;
const payload = (sid, event, extra) => Object.assign({ session_id: sid, transcript_path: tpath(sid), hook_event_name: event, tool_name: "Bash" }, extra || {});

// fire(input, env) -> parsed stdout of one hook run; throws unless it exits 0 with JSON on stdout.
function fire(input, env) {
  const e = Object.assign({}, process.env, { CONV_LANG: "japanese" }, env || {});
  const raw = typeof input === "string" ? input : JSON.stringify(input);
  const r = spawnSync(process.execPath, [HOOK], { input: raw, cwd: TMP, env: e, encoding: "utf8", timeout: 60000 });
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${String(r.stderr).slice(0, 200)}`);
  return JSON.parse(String(r.stdout).trim() || "null");
}
const post = (sid, env, extra) => fire(payload(sid, "PostToolUse", extra), env);
const isDirective = (out) => !!(out && out.hookSpecificOutput && out.hookSpecificOutput.hookEventName === "PostToolUse" && String(out.hookSpecificOutput.additionalContext).startsWith(CONV_HEAD));

caseBegin("first-post-tool-use-writes-baseline", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-first";
  grow(sid, 5000);
  check("B1: no baseline -> first PostToolUse emits {}", () => eq(post(sid), {}, "output"));
  check("B2: ... and writes the current transcript size as the baseline", () => eq(baseline(sid), 5000, "baselineBytes"));
}
caseEnd();

caseBegin("growth-threshold", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-grow";
  grow(sid, 1000);
  let ok = true;
  try { post(sid); } catch (_e) { ok = false; }
  check("G0: fixture — the seeding PostToolUse set the baseline", () => eq([ok, baseline(sid)], [true, 1000], "[ran, baselineBytes]"));
  grow(sid, KB128 - 1);
  check("G1: growth of 128KB - 1 byte -> {}", () => eq(post(sid), {}, "output"));
  check("G1: ... the baseline is left alone", () => eq(baseline(sid), 1000, "baselineBytes"));
  grow(sid, 1);
  let out = null;
  check("G2: growth of exactly 128KB -> the CONV_LANG directive as PostToolUse additionalContext", () => { out = post(sid); eq(isDirective(out), true, `output ${show(out)}`); });
  check("G3: ... the directive is the one conv-lang renders (identical text)", () => {
    const prev = process.env.CONV_LANG;
    process.env.CONV_LANG = "japanese";
    const p = require.resolve(path.join(ROOT, "hooks", "lib", "conv-lang"));
    delete require.cache[p];
    const want = require(p).getConvLangInjection();
    if (prev === undefined) delete process.env.CONV_LANG; else process.env.CONV_LANG = prev;
    eq(out && out.hookSpecificOutput && out.hookSpecificOutput.additionalContext, want, "additionalContext");
  });
  check("G4: ... the baseline moves to the current size", () => eq(baseline(sid), size(sid), "baselineBytes"));
  grow(sid, 2000);
  check("G5: the next small growth after an injection -> {} (emitted once)", () => eq(post(sid), {}, "output"));
  grow(sid, KB128 * 2);
  check("G6: a further 128KB+ stretch -> injected again", () => eq(isDirective(post(sid)), true, "directive"));
}
caseEnd();

caseBegin("user-prompt-submit-resets-baseline", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-ups";
  grow(sid, 1000);
  try { post(sid); } catch (_e) { /* G-cases already report a missing hook */ }
  grow(sid, KB128 + 500);
  check("U1: UserPromptSubmit -> {} (lang-inject already carries this turn's directive)", () => eq(fire(payload(sid, "UserPromptSubmit", { prompt: "hi" })), {}, "output"));
  check("U2: ... and the baseline is the current transcript size", () => eq(baseline(sid), size(sid), "baselineBytes"));
  grow(sid, 3000);
  check("U3: so the growth before the prompt no longer triggers -> {}", () => eq(post(sid), {}, "output"));
}
caseEnd();

caseBegin("shrunk-transcript-resets-baseline", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-shrink";
  grow(sid, 50000);
  try { post(sid); } catch (_e) { /* reported elsewhere */ }
  fs.writeFileSync(tpath(sid), "y".repeat(2000));
  check("S1: transcript smaller than the baseline -> {}", () => eq(post(sid), {}, "output"));
  check("S2: ... and the baseline is reset to the smaller size", () => eq(baseline(sid), 2000, "baselineBytes"));
}
caseEnd();

caseBegin("no-op-conditions-emit-empty", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-noop";
  grow(sid, 1000);
  try { post(sid); } catch (_e) { /* reported elsewhere */ }
  grow(sid, KB128 * 2);
  check("N1: subagent call (agent_id set) after a 256KB growth -> {}", () => eq(post(sid, {}, { agent_id: "agent-1" }), {}, "output"));
  check("N2: CONV_LANG unset after a 256KB growth -> {}", () => eq(post(sid, { CONV_LANG: "" }), {}, "output"));
  check("N3: CONV_LANG=english after a 256KB growth -> {}", () => eq(post(sid, { CONV_LANG: "english" }), {}, "output"));
  check("N4: CONV_LANG=any after a 256KB growth -> {}", () => eq(post(sid, { CONV_LANG: "any" }), {}, "output"));
  check("N5: control — the same session with CONV_LANG=japanese does inject", () => eq(isDirective(post(sid)), true, "directive"));
  check("N6: no transcript_path -> {}", () => eq(fire({ session_id: "rj-nopath", hook_event_name: "PostToolUse" }), {}, "output"));
  check("N7: no session_id -> {}", () => eq(fire({ transcript_path: tpath(sid), hook_event_name: "PostToolUse" }), {}, "output"));
  check("N8: transcript file missing -> {}", () => eq(post("rj-missing"), {}, "output"));
  check("N9: malformed stdin -> {}", () => eq(fire("{not json"), {}, "output"));
}
caseEnd();

caseBegin("unregistered-event-emits-empty", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-other-event";
  grow(sid, 1000);
  try { post(sid); } catch (_e) { /* reported elsewhere */ }
  grow(sid, KB128 * 2);
  const before = baseline(sid);
  check("E0: fixture — baseline seeded and the transcript is 256KB past it", () => eq([before, size(sid) - before >= KB128], [1000, true], "[baselineBytes, over threshold]"));
  check("E1: an unregistered event (PreToolUse) over the threshold -> {}", () => eq(fire(payload(sid, "PreToolUse")), {}, "output"));
  check("E2: an unregistered event (Stop) over the threshold -> {}", () => eq(fire(payload(sid, "Stop")), {}, "output"));
  check("E3: ... and the baseline is unchanged", () => eq(baseline(sid), before, "baselineBytes"));
  check("E4: control — PostToolUse on the same session does inject", () => eq(isDirective(post(sid)), true, "directive"));
}
caseEnd();

caseBegin("path-traversal-session-id", "hooks/conv-lang-reinject.js");
{
  const sid = "../rj-escape";
  const outside = [path.dirname(process.env.WORKFLOW_STATE_DIR), TMP];
  // Files carry their mtime; directories only their name (the state dir itself may legitimately change).
  const stamp = (d, n) => { const st = fs.statSync(path.join(d, n)); return st.isDirectory() ? `${n}/` : `${n}@${st.mtimeMs}`; };
  const snap = () => outside.map((d) => fs.readdirSync(d).sort().map((n) => stamp(d, n)));
  grow(sid, 1000);
  const before = snap();
  let outs = [];
  try { outs.push(post(sid)); grow(sid, KB128 * 2); outs.push(post(sid)); } catch (e) { outs = [String(e.message)]; }
  check("T1: an existing transcript under a traversal session_id -> {} on every PostToolUse", () => eq(outs, [{}, {}], "outputs"));
  check("T2: ... and nothing next to the state dir or the transcripts dir was created or modified", () => {
    const after = snap();
    eq(after[0], before[0], "state-dir parent listing");
    eq(after[1].filter((e) => !e.startsWith("rj-escape.jsonl@")), before[1].filter((e) => !e.startsWith("rj-escape.jsonl@")), "transcripts-dir parent listing");
  });
}
caseEnd();

caseBegin("settings-registration", "hooks/conv-lang-reinject.js");
{
  const settings = JSON.parse(fs.readFileSync(path.join(ROOT, "settings.json"), "utf8"));
  const CMD = 'node "$AGENTS_MAIN_ROOT/hooks/conv-lang-reinject.js"';
  const matchersOf = (event) => ((settings.hooks || {})[event] || []).filter((g) => (g.hooks || []).some((h) => h.command === CMD)).map((g) => g.matcher);
  check("R1: the real settings.json registers the hook under UserPromptSubmit", () => eq(matchersOf("UserPromptSubmit").length, 1, "UserPromptSubmit groups"));
  check("R2: the real settings.json registers the hook under PostToolUse with matcher \"\"", () => eq(matchersOf("PostToolUse"), [""], "PostToolUse matchers"));
}
caseEnd();

caseBegin("unwritable-sidecar-fails-open", "hooks/conv-lang-reinject.js");
{
  const sid = "rj-locked";
  const stateDir = process.env.WORKFLOW_STATE_DIR;
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, `${sid}.control`), "a regular file where the control dir should be");
  grow(sid, 1000);
  check("W1: sidecar cannot be written -> first PostToolUse still exits 0 with {}", () => eq(post(sid), {}, "output"));
  grow(sid, KB128 * 2);
  check("W2: ... and a later 256KB growth still exits 0 without crashing", () => { const out = post(sid); eq(out !== null && typeof out === "object", true, `output ${show(out)}`); });
  check("W3: UserPromptSubmit with an unwritable sidecar -> {}", () => eq(fire(payload(sid, "UserPromptSubmit")), {}, "output"));
  check("W4: fixture — the blocking file is still a file (no control dir was forced)", () => eq(fs.statSync(path.join(stateDir, `${sid}.control`)).isFile(), true, "isFile"));
}
caseEnd();

caseBegin("sidecar-location", "hooks/lib/handoff-sidecar.js");
{
  check("P1: fixture — the baseline lives under <WORKFLOW_STATE_DIR>/<sid>.control/", () => eq(path.dirname(sidecarPath("rj-first", SUFFIX)), path.join(process.env.WORKFLOW_STATE_DIR, "rj-first.control"), "dir"));
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed\n`);
process.exitCode = failed === 0 ? 0 : 1;
