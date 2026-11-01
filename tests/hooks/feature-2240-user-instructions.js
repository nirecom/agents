#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/user-instructions.js, hooks/session-start.js, hooks/post-compact.js
// Tags: TL2, hooks, user-instructions, session-start, post-compact, truncation, utf8, scope:issue-specific, lang, plan-lang, fail-open, html-comment, session-title, removal
// #2240 Change 4 (#2731 rename): user-instructions.md at the agents checkout root is injected under a
// "[user-instructions]" header at SessionStart and PostCompact only — never at UserPromptSubmit or
// SubagentStart. Absent, empty or blank -> nothing; over 4096 bytes -> cut on a UTF-8 boundary + marker.
// Fixture: hooks/ is copied into a temp checkout so the file never touches the real repo root.
// TL3 gap (what this test does NOT catch):
// - the SessionStart / PostCompact registrations firing under a real Claude Code host
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
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "user-instr-"));
const CFG = path.join(TMP, "cfg");
const HOME = path.join(TMP, "home");
const PROJECT = path.join(TMP, "project");
const TRANSCRIPTS = path.join(TMP, "transcript-base");
for (const d of [CFG, HOME, PROJECT, TRANSCRIPTS]) fs.mkdirSync(d);
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
const COPY = path.join(TMP, "agents");
// bin/ too: hooks/lib/confirm-gate/plan-gate.js requires bin/workflow/lib/next-step/gate-line.
for (const d of ["hooks", "bin"]) fs.cpSync(path.join(ROOT, d), path.join(COPY, d), { recursive: true, filter: (src) => !/[\\/](node_modules|\.git)([\\/]|$)/.test(src) });
const UI_FILE = path.join(COPY, "user-instructions.md");
const UI_LIB = path.join(COPY, "hooks", "lib", "user-instructions.js");
const HEADER = "[user-instructions]";
const MARK = "[user-instructions truncated at 4096 bytes]";

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

// setFile(content) — null removes the file; otherwise writes it byte-exact.
function setFile(content) {
  fs.rmSync(UI_FILE, { force: true });
  if (content !== null) fs.writeFileSync(UI_FILE, content);
}
// inject() -> getUserInstructionsInjection() from a fresh load of the copied module.
function inject() {
  if (!fs.existsSync(UI_LIB)) throw new Error("hooks/lib/user-instructions.js does not exist");
  delete require.cache[require.resolve(UI_LIB)];
  return require(UI_LIB).getUserInstructionsInjection();
}
const count = (s, needle) => String(s).split(needle).length - 1;

caseBegin("provider-absent-empty-blank-is-null", "hooks/lib/user-instructions.js");
test("provider-absent-empty-blank-is-null", verdict(() => {
  setFile(null);
  check("U1: file absent -> null", () => eq(inject(), null, "injection"));
  setFile("");
  check("U2: file empty -> null", () => eq(inject(), null, "injection"));
  setFile("  \n\t\r\n  \n");
  check("U3: whitespace-only file -> null", () => eq(inject(), null, "injection"));
  fs.rmSync(UI_FILE, { force: true });
  fs.mkdirSync(UI_FILE);
  check("U4: a directory at the file path (unreadable) -> null, no throw", () => eq(inject(), null, "injection"));
  fs.rmSync(UI_FILE, { recursive: true, force: true });
}));
caseEnd();

caseBegin("provider-normal-content", "hooks/lib/user-instructions.js");
test("provider-normal-content", verdict(() => {
  const body = "Prefer short sentences.\nName every file by its absolute path.";
  setFile(body + "\n");
  let r = null;
  check("N1: normal file -> a string whose first line starts with the [user-instructions] header", () => { r = inject(); eq([typeof r, String(r).split("\n")[0].startsWith(HEADER)], ["string", true], "[type, header]"); });
  check("N2: the content is carried verbatim", () => eq(String(r).includes(body), true, `content in ${show(r)}`));
  check("N3: no truncation marker under the limit", () => eq([typeof r, String(r).includes(MARK)], ["string", false], "[type, marker present]"));
  setFile("x".repeat(4096));
  check("N4: boundary — exactly 4096 bytes -> kept whole, no marker", () => { const s = inject(); eq([count(s, "x"), s.includes(MARK)], [4096, false], "[x count, marker]"); });
}));
caseEnd();

caseBegin("provider-truncates-on-utf8-boundary", "hooks/lib/user-instructions.js");
test("provider-truncates-on-utf8-boundary", verdict(() => {
  setFile("a".repeat(5000));
  check("T1: 5000 ASCII bytes -> exactly 4096 kept and the marker appended", () => { const s = inject(); eq([count(s, "a".repeat(1)) - count(HEADER + MARK, "a"), s.trimEnd().endsWith(MARK)], [4096, true], "[a count, ends with marker]"); });
  // 'あ' is 3 bytes; 4096 / 3 is not whole, so a byte cut would split a character.
  // lang-check: ignore -- the multi-byte fixture is the point of this case.
  setFile("あ".repeat(1700));
  check("T2: multi-byte content -> cut at a character boundary (1365 whole characters, no U+FFFD)", () => { const s = inject(); eq([count(s, "あ"), s.includes("�"), s.includes(MARK)], [1365, false, true], "[chars, replacement char, marker]"); });
  setFile("x" + "😀".repeat(1100));
  check("T3: 4-byte characters after a 1-byte lead -> 1023 whole emoji kept, no lone surrogate", () => { const s = inject(); eq([count(s, "😀"), /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(s), s.includes(MARK)], [1023, false, true], "[emoji, lone surrogate, marker]"); });
}));
caseEnd();

// run(hook, input, env) -> the hook's additionalContext ("" when it printed {}).
function run(hook, input, env) {
  const e = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, CLAUDE_PROJECT_DIR: PROJECT, CONV_LANG: "japanese" }, env || {});
  const r = spawnSync(process.execPath, [path.join(COPY, "hooks", hook)], { input, cwd: PROJECT, env: e, encoding: "utf8", timeout: 90000 });
  if (r.error || r.status !== 0) throw new Error(`${hook} exit=${r.status} err=${r.error} stderr=${String(r.stderr).slice(0, 300)}`);
  const j = JSON.parse(String(r.stdout).trim() || "{}");
  const h = j.hookSpecificOutput || j;
  return typeof h.additionalContext === "string" ? h.additionalContext : "";
}
const UI_BODY = "UI-MARKER-2731 keep replies short.";
const ev = (sid, name) => JSON.stringify({ session_id: sid, hook_event_name: name, source: "startup", prompt: "hi", cwd: PROJECT, transcript_path: path.join(TRANSCRIPTS, `${sid}.jsonl`) });

caseBegin("injected-at-session-start-and-post-compact", "hooks/session-start.js");
test("injected-at-session-start-and-post-compact", verdict(() => {
  setFile(UI_BODY + "\n");
  let ss = "";
  check("H1: SessionStart context carries the user instructions under the header", () => { ss = run("session-start.js", ev("ui-ss", "SessionStart")); eq([ss.includes(HEADER), ss.includes(UI_BODY)], [true, true], `[header, body] in ${show(ss.slice(-400))}`); });
  check("H1: control — the CONV_LANG line is still in SessionStart context", () => eq(ss.includes("Respond to the user in japanese."), true, "CONV_LANG present"));
  let pc = "";
  check("H2: PostCompact context carries the user instructions under the header", () => { pc = run("post-compact.js", ev("ui-ss", "PostCompact")); eq([pc.includes(HEADER), pc.includes(UI_BODY)], [true, true], `[header, body] in ${show(pc.slice(-400))}`); });
  check("H3: the instructions appear exactly once per context", () => eq([count(ss, UI_BODY), count(pc, UI_BODY)], [1, 1], "[session-start, post-compact]"));
  setFile(null);
  check("H4: file absent -> SessionStart context has no header", () => eq(run("session-start.js", ev("ui-ss2", "SessionStart")).includes(HEADER), false, "header present"));
  check("H4: file absent -> PostCompact context has no header", () => eq(run("post-compact.js", ev("ui-ss2", "PostCompact")).includes(HEADER), false, "header present"));
}));
caseEnd();

caseBegin("not-injected-per-turn-or-into-subagents", "hooks/lang-inject.js");
test("not-injected-per-turn-or-into-subagents", verdict(() => {
  setFile(UI_BODY + "\n");
  let up = "";
  check("X1: UserPromptSubmit (lang-inject) never carries the user instructions", () => { up = run("lang-inject.js", ev("ui-x", "UserPromptSubmit")); eq(up.includes(UI_BODY), false, "body present"); });
  check("X1: control — lang-inject still injected CONV_LANG", () => eq(up.includes("Respond to the user in japanese."), true, "CONV_LANG present"));
  let sa = "";
  check("X2: SubagentStart never carries the user instructions", () => { sa = run("subagent-start.js", ev("ui-x", "SubagentStart")); eq(sa.includes(UI_BODY), false, "body present"); });
  check("X2: control — subagent-start still injected CONV_LANG", () => eq(sa.includes("Respond to the user in japanese."), true, "CONV_LANG present"));
  setFile(null);
}));
caseEnd();

// #2240 Change 1: after compaction PLAN_LANG is re-injected right after the CONV_LANG line while a
// planning step is open, never once planning is over; an unreadable state fails open.
// markStep reads the approval gates from $AGENTS_MAIN_ROOT/.env, never process.env.
fs.writeFileSync(path.join(CFG, ".env"), "CONFIRM_INTENT=off\nCONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n");
const PC_HOOK = path.join(ROOT, "hooks", "post-compact.js");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const PLAN_HEAD = (l) => `Write planning artifacts (files under the plans directory) in ${l}.`;
const CONV_HEAD = (l) => `Respond to the user in ${l}.`;
function seed(sid, statuses) {
  S.writeState(sid, S.createInitialState(sid, { cwd: "/x", git_branch: "feature/x" }));
  S.markStep(sid, "workflow_init", "complete");
  for (const [step, status] of Object.entries(statuses || {})) S.markStep(sid, step, status);
}
const DONE = { clarify_intent: "skipped", outline: "skipped", detail: "skipped" };
// compact(sid, env) -> the additionalContext lines of one post-compact run (throws on a bad run).
function compact(sid, env) {
  const e = Object.assign({}, process.env, { HOME, USERPROFILE: HOME }, env || {});
  const r = spawnSync(process.execPath, [PC_HOOK], { input: JSON.stringify({ session_id: sid }), cwd: TMP, env: e, encoding: "utf8", timeout: 60000 });
  if (r.error || r.status !== 0) throw new Error(`hook exit=${r.status} err=${r.error} stderr=${String(r.stderr).slice(0, 300)}`);
  const j = JSON.parse(String(r.stdout).trim() || "{}");
  if (typeof j.additionalContext !== "string") throw new Error(`no additionalContext: ${String(r.stdout).slice(0, 300)}`);
  return j.additionalContext.split("\n");
}
const planLines = (lines, l) => lines.filter((x) => x.startsWith(PLAN_HEAD(l)));

caseBegin("plan-lang-reinjected-while-planning", "hooks/post-compact.js");
test("plan-lang-reinjected-while-planning", verdict(() => {
  seed("pcpl-planning");
  const lines = compact("pcpl-planning", { CONV_LANG: "japanese", PLAN_LANG: "japanese" });
  check("P1: planning steps open + PLAN_LANG=japanese -> exactly one PLAN_LANG line", () => eq(planLines(lines, "japanese").length, 1, `PLAN_LANG lines in ${show(lines)}`));
  check("P2: the PLAN_LANG line comes right after the CONV_LANG line", () => {
    const ci = lines.findIndex((x) => x.startsWith(CONV_HEAD("japanese")));
    const pi = lines.findIndex((x) => x.startsWith(PLAN_HEAD("japanese")));
    eq([ci >= 0, pi === ci + 1], [true, true], `[conv present, plan right after] conv=${ci} plan=${pi}`);
  });
  seed("pcpl-detail", { clarify_intent: "skipped", outline: "skipped", detail: "in_progress" });
  check("P3: only detail still open -> PLAN_LANG line present", () => eq(planLines(compact("pcpl-detail", { PLAN_LANG: "japanese" }), "japanese").length, 1, "PLAN_LANG lines"));
  check("P4: PLAN_LANG=english during planning is a real directive (english is valid for plans)", () => eq(planLines(compact("pcpl-planning", { PLAN_LANG: "english" }), "english").length, 1, "PLAN_LANG lines"));
}));
caseEnd();

caseBegin("plan-lang-absent-outside-planning-or-noop", "hooks/post-compact.js");
test("plan-lang-absent-outside-planning-or-noop", verdict(() => {
  seed("pcpl-done", DONE);
  const lines = compact("pcpl-done", { CONV_LANG: "japanese", PLAN_LANG: "japanese" });
  check("A1: every planning step resolved -> no PLAN_LANG line", () => eq(planLines(lines, "japanese"), [], "PLAN_LANG lines"));
  check("A1: control — the CONV_LANG line is still there", () => eq(lines.some((x) => x.startsWith(CONV_HEAD("japanese"))), true, "CONV_LANG present"));
  check("A2: planning but PLAN_LANG unset -> no plan-artifacts line", () => eq(compact("pcpl-planning", {}).filter((x) => x.startsWith("Write planning artifacts")), [], "lines"));
  check("A3: planning but PLAN_LANG=any -> no plan-artifacts line", () => eq(compact("pcpl-planning", { PLAN_LANG: "any" }).filter((x) => x.startsWith("Write planning artifacts")), [], "lines"));
  check("A4: no state file for the session -> no PLAN_LANG line", () => eq(planLines(compact("pcpl-no-state", { PLAN_LANG: "japanese" }), "japanese"), [], "PLAN_LANG lines"));
}));
caseEnd();

caseBegin("unreadable-state-fails-open", "hooks/post-compact.js");
test("unreadable-state-fails-open", verdict(() => {
  const sid = "pcpl-corrupt";
  fs.mkdirSync(path.dirname(S.getStatePath(sid)), { recursive: true });
  fs.writeFileSync(S.getStatePath(sid), "{not json");
  let lines = null;
  check("F1: an unreadable state file -> post-compact still exits 0 with additionalContext", () => { lines = compact(sid, { CONV_LANG: "japanese", PLAN_LANG: "japanese" }); });
  check("F2: ... no PLAN_LANG line (isPlanning fails open to false)", () => eq(planLines(lines || [], "japanese"), [], "PLAN_LANG lines"));
  check("F3: ... the session-id and CONV_LANG lines survive", () => eq([(lines || []).some((x) => x.includes(sid)), (lines || []).some((x) => x.startsWith(CONV_HEAD("japanese")))], [true, true], "[sid line, conv line]"));
}));
caseEnd();

// #2731: the loader reads user-instructions.md (not the old .local.md name) and strips <!-- --> comments.
caseBegin("provider-reads-renamed-file-only", "hooks/lib/user-instructions.js");
test("provider-reads-renamed-file-only", verdict(() => {
  check("R1: USER_INSTRUCTIONS_FILE names user-instructions.md", () => { delete require.cache[require.resolve(UI_LIB)]; eq(path.basename(require(UI_LIB).USER_INSTRUCTIONS_FILE), "user-instructions.md", "basename"); });
  const OLD = path.join(COPY, "user-instructions.local.md");
  setFile(null);
  fs.writeFileSync(OLD, UI_BODY + "\n");
  check("R2: only the old user-instructions.local.md present -> null (old name is not read)", () => eq(inject(), null, "injection"));
  fs.rmSync(OLD, { force: true });
}));
caseEnd();

caseBegin("provider-strips-html-comments", "hooks/lib/user-instructions.js");
test("provider-strips-html-comments", verdict(() => {
  setFile("<!-- only a note -->\n");
  check("C1: single-line comment-only file -> null", () => eq(inject(), null, "injection"));
  setFile("\n\n<!--\nCopy this file.\nSave it as user-instructions.md.\n-->\n\n");
  check("C2: multi-line comment-only file with blank lines around it -> null", () => eq(inject(), null, "injection"));
  setFile("<!-- hidden-note-2731 -->\nLine A real.\nLine B real.\n");
  check("C3: comment + real lines -> only the real lines, header first", () => {
    const s = inject();
    eq([typeof s, String(s).split("\n")[0].startsWith(HEADER), String(s).includes("Line A real.\nLine B real."), String(s).includes("hidden-note-2731"), String(s).includes("<!--"), String(s).includes("-->")], ["string", true, true, false, false, false], `[type, header, content, comment text, <!--, -->] in ${show(s)}`);
  });
  setFile("<!-- first-c -->\nBODY-X\n<!-- second-c\nstill comment -->\n");
  check("C4: two comments around content -> only the content remains", () => {
    const s = inject();
    eq([typeof s, String(s).split("\n").slice(1).filter((l) => l.trim() !== "")], ["string", ["BODY-X"]], `[type, non-blank lines after header] in ${show(s)}`);
  });
  setFile("keep this <!-- never closed\nmore\n");
  check("C5: unterminated <!-- -> everything from it to the end of the file is dropped", () => {
    const s = inject();
    eq([typeof s, String(s).includes("keep this"), String(s).includes("never closed"), String(s).split("\n").includes("more"), String(s).includes("<!--")], ["string", true, false, false, false], `[type, kept text, comment text, "more" line, <!--] in ${show(s)}`);
  });
  setFile("REAL-HEAD\n<!-- " + "z".repeat(5000) + " -->\nREAL-TAIL\n");
  check("C6: comments are stripped before the 4096-byte cap -> both real lines kept, no marker", () => {
    const s = inject();
    eq([typeof s, String(s).includes("REAL-HEAD"), String(s).includes("REAL-TAIL"), String(s).includes("zzzz"), String(s).includes("<!--"), String(s).includes(MARK)], ["string", true, true, false, false, false], `[type, head, tail, zzzz, <!--, marker] in ${show(String(s).slice(0, 200))}`);
  });
  setFile(null);
}));
caseEnd();

caseBegin("comment-only-file-not-injected-at-session-start", "hooks/session-start.js");
test("comment-only-file-not-injected-at-session-start", verdict(() => {
  setFile("<!--\nexplanatory text only\n-->\n");
  check("H5: comment-only file -> SessionStart exits 0 and its context has no header", () => { const ss = run("session-start.js", ev("ui-ss5", "SessionStart")); eq([ss.includes(HEADER), ss.includes("explanatory text only")], [false, false], "[header, comment text] present"); });
  setFile(null);
}));
caseEnd();

// #299: the transcript-append title mechanism (CLI, lib, session-start block, skill steps) is gone.
// Tokens are concatenated so this file never matches them; bare "session-title" is not a token
// (tests/bin/feature-2631-clarify-owner-paths.sh carries an unrelated name containing it).
caseBegin("session-title-mechanism-removed", "hooks/session-start.js");
test("session-title-mechanism-removed", verdict(() => {
  const TOKENS = ["cc-" + "session-title", "lib/" + "session-title", "write" + "SetIssue", "write" + "AddPr", "write" + "MarkComplete", "CLAUDE_SESSION_" + "JSONL_PATH", "CI-" + "C1a", "CP-" + "2a", "SC-" + "6a", "_encode" + "Cwd", "_get" + "TranscriptBase"];
  const SELF = "tests/hooks/feature-2240-user-instructions.js";
  const excluded = (rel) => rel === SELF || rel.startsWith("docs/history/") || rel.split("/").includes("changelog") || path.posix.basename(rel) === "CHANGELOG.md";
  check("R1: the retired CLI bin/cc-session-title is gone", () => eq(fs.existsSync(path.join(ROOT, "bin", "cc-" + "session-title")), false, "exists"));
  check("R1: the retired lib hooks/lib/session-title.js is gone", () => eq(fs.existsSync(path.join(ROOT, "hooks", "lib", "session-" + "title.js")), false, "exists"));
  check("R2: no retired token in tracked files outside the history records", () => {
    const ls = spawnSync("git", ["-C", ROOT, "ls-files", "-z"], { encoding: "utf8", timeout: 60000, maxBuffer: 64 * 1024 * 1024 });
    if (ls.status !== 0) return `git ls-files failed: ${ls.stderr}`;
    const tracked = ls.stdout.split("\0").filter(Boolean);
    if (!tracked.includes("hooks/lib/user-instructions.js")) return `git ls-files listed ${tracked.length} files, not the repo tree`;
    const hits = [];
    for (const rel of tracked.filter((r) => !excluded(r))) {
      let text;
      try { text = fs.readFileSync(path.join(ROOT, rel), "utf8"); } catch (_) { continue; } // deleted in the worktree
      if (text.includes("\0")) continue;
      for (const tok of TOKENS) if (text.includes(tok)) hits.push(`${rel}: ${tok}`);
    }
    eq(hits, [], "hits");
  });
  check("R2: skills/workflow-init/SKILL.md has no A1b step", () => eq(fs.readFileSync(path.join(ROOT, "skills", "workflow-init", "SKILL.md"), "utf8").includes("A1" + "b"), false, "A1b present"));
}));
caseEnd();
