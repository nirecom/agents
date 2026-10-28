"use strict";
// Behavior oracle for every PreToolUse hook registered in settings.json, plus the merged hook
// that #2676 adds. Each probe runs the real hook as a node process and names the class it
// prints today: an allow-deny hook has a deny (or ask) probe and a permitted probe; a
// non-allow-deny hook has probes whose output carries no permission decision at all.
// The test entry calls isolate() before requiring this module, so WORKFLOW_STATE_DIR and
// WORKFLOW_PLANS_DIR are pinned. Every config value a hook reads is pinned per probe, and
// AGENTS_MAIN_ROOT points at an empty directory unless a probe writes its own .env there.

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const fx = require("./fixture");
const { classify } = require("../feature-2676-merged-allow-deny/fixture");

const REPO = path.resolve(__dirname, "..", "..", "..");
const SPAWN_TIMEOUT_MS = 30000;
const CAPTURE = 'x="$(date)"; echo "$x"';
const PRIVATE_LINE = "Internal gateway at 10.20.30.40 is offline.\n";
// A short Japanese note ("a memo in Japanese"), as char codes (no CJK in test source).
const JAPANESE = String.fromCharCode(0x65e5, 0x672c, 0x8a9e, 0x306e, 0x30e1, 0x30e2);
const NO_DECISION = "no-permission-decision";

const sidOf = (hookName) => `sid-f2676-oracle-${hookName}`;
const bash = (command, extra) => ({ tool_name: "Bash", tool_input: { command }, ...(extra || {}) });
const call = (toolName, toolInput, extra) => ({ tool_name: toolName, tool_input: toolInput, ...(extra || {}) });
const forward = (dir) => dir.replace(/\\/g, "/");
// A plan artifact name needs a UUID-shaped sid; a fresh one per call keeps per-sid counters apart.
let uuidSeq = 0;
const freshUuid = () => `2676aaaa-${String(++uuidSeq).padStart(4, "0")}-4aaa-8bbb-${String(process.pid % 1e12).padStart(12, "0")}`;

function writeState(sid, steps) {
  const shaped = Object.fromEntries(Object.entries(steps).map(([step, status]) => [step, { status, updated_at: null }]));
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`), JSON.stringify({ version: 1,
    session_id: sid, created_at: "2026-01-01T00:00:00.000Z", is_bugfix: false, git_branch: "feature/f2676",
    steps: shaped, workflow_type: "wf-code" }));
}
// configRoot(context, lines) -> an AGENTS_MAIN_ROOT whose .env holds exactly `lines`.
function configRoot(context, lines) {
  const dir = context.tempDir("cfg");
  fs.writeFileSync(path.join(dir, ".env"), lines.join("\n") + "\n");
  return dir;
}
const sessionStateDir = (sid) => require(path.join(REPO, "hooks", "workflow-state", "state-io.js")).getSessionStateDir(sid);
const withFakeGh = () => fx.fakeGhEnv();

const ORACLE = {
  "scan-outbound": { kind: "allow-deny", probes: [
    { label: "commit with a private IP staged", want: "deny", setup: (context) => {
      const repo = context.makeRepo("so-deny", { "a.txt": PRIVATE_LINE });
      return { input: bash(`git -C ${repo} commit -m x`) };
    } },
    { label: "commit with clean content staged", want: "approve", setup: (context) => {
      const repo = context.makeRepo("so-ok", { "a.txt": "hello\n" });
      return { input: bash(`git -C ${repo} commit -m x`) };
    } },
  ] },
  "block-dotenv": { kind: "allow-deny", probes: [
    { label: "cat .env", want: "deny", input: bash("cat .env") },
    { label: "git status", want: "approve", input: bash("git status") },
  ] },
  "block-credentials": { kind: "allow-deny", probes: [
    { label: "Grep under ~/.ssh", want: "deny", input: call("Grep", { pattern: "x", path: path.join(os.homedir(), ".ssh") }) },
    { label: "git status", want: "approve", input: bash("git status") },
  ] },
  "block-history-direct": { kind: "allow-deny", probes: [
    { label: "Edit docs/history.md", want: "deny", setup: (context) => {
      const repo = context.makeRepo("bhd");
      return { input: call("Edit", { file_path: `${repo}/docs/history.md`, old_string: "a", new_string: "b" }), cwd: repo };
    } },
    { label: "Edit README.txt", want: "approve", setup: (context) => {
      const repo = context.makeRepo("bhd-ok");
      return { input: call("Edit", { file_path: `${repo}/README.txt`, old_string: "fixture", new_string: "example" }), cwd: repo };
    } },
  ] },
  "block-shell-config": { kind: "allow-deny", probes: [
    { label: "Edit ~/.bashrc", want: "deny", input: call("Edit", { file_path: path.join(os.homedir(), ".bashrc"), old_string: "a", new_string: "b" }) },
    { label: "Edit a temp file", want: "approve", setup: (context) => ({
      input: call("Edit", { file_path: `${context.tempDir("bsc")}/a.txt`, old_string: "a", new_string: "b" }) }) },
  ] },
  "block-memory-direct": { kind: "allow-deny", probes: [
    { label: "Write into the auto-memory dir", want: "deny", input: call("Write", {
      file_path: path.join(os.homedir(), ".claude", "projects", "c-" + "-git-agents", "memory", "example.md"), content: "x\n" },
    { session_id: sidOf("block-memory-direct") }) },
    { label: "Write a temp file", want: "approve", setup: (context) => ({
      input: call("Write", { file_path: `${context.tempDir("bmd")}/a.md`, content: "x\n" }) }) },
  ] },
  "block-clearance-token-write": { kind: "allow-deny", probes: [
    { label: "Write the off-clearance token", want: "deny", setup: () => {
      const sid = sidOf("block-clearance-token-write");
      return { input: call("Write", { file_path: path.join(sessionStateDir(sid), `${sid}.off-clearance`), content: "{}" }, { session_id: sid }) };
    } },
    { label: "Write a temp file", want: "approve", setup: (context) => ({
      input: call("Write", { file_path: `${context.tempDir("bctw")}/a.txt`, content: "x\n" }) }) },
  ] },
  "enforce-worktree": { kind: "allow-deny", probes: [
    { label: "Edit in the main worktree", want: "deny", setup: (context) => {
      const repo = context.makeRepo("ew");
      return { input: call("Edit", { file_path: `${repo}/README.txt`, old_string: "fixture", new_string: "example" }),
        cwd: repo, env: { ENFORCE_WORKTREE: "on", ENFORCE_WORKTREE_ADDITIONAL_REPOS: context.tempDir("noextra") } };
    } },
    { label: "Edit in a linked worktree", want: "none", setup: (context) => {
      const linked = context.makeLinkedWorktree(context.makeRepo("ew-ok"));
      return { input: call("Edit", { file_path: `${linked}/README.txt`, old_string: "fixture", new_string: "example" }),
        cwd: linked, env: { ENFORCE_WORKTREE: "on", ENFORCE_WORKTREE_ADDITIONAL_REPOS: context.tempDir("noextra") } };
    } },
  ] },
  // Refuses through exit 2 with stderr only; runProbe reads exit 2 as deny.
  "enforce-issue-close": { kind: "allow-deny", probes: [
    { label: "gh issue close", want: "deny", input: bash("gh issue close 1"), env: { ISSUE_CLOSE_SKILL: "" } },
    { label: "git status", want: "none", input: bash("git status"), env: { ISSUE_CLOSE_SKILL: "" } },
  ] },
  "confirm-forge-target-ownership": { kind: "allow-deny", probes: [
    { label: "gh issue create on an unproven owner", want: "ask",
      input: bash("gh issue create -R example-owner/example-repo -t x -b y"), setup: () => ({ env: withFakeGh() }) },
    { label: "git status", want: "none", input: bash("git status"), setup: () => ({ env: withFakeGh() }) },
  ] },
  // Refuses through exit 2 with stderr only; runProbe reads exit 2 as deny.
  "enforce-system-ops": { kind: "allow-deny", probes: [
    { label: "winget install", want: "deny", input: bash("winget install example.tool"), env: { SYSTEM_OPS_APPROVED: "0" } },
    { label: "git status", want: "none", input: bash("git status"), env: { SYSTEM_OPS_APPROVED: "0" } },
  ] },
  "block-subagent-sentinels": { kind: "allow-deny", probes: [
    { label: "sentinel echo from a subagent", want: "deny",
      input: bash('echo "<<WORKFLOW_RESET_FROM_detail: fixture>>"', { agent_id: "agent-f2676", session_id: sidOf("block-subagent-sentinels") }) },
    { label: "sentinel echo from the main conversation", want: "approve",
      input: bash('echo "<<WORKFLOW_RESET_FROM_detail: fixture>>"', { session_id: sidOf("block-subagent-sentinels") }) },
  ] },
  "workflow-gate": { kind: "allow-deny", probes: [
    { label: "input that is not JSON", want: "deny", input: "{not json", env: { ENFORCE_WORKTREE: "on" } },
    { label: "Read without a session", want: "approve", setup: (context) => ({
      input: call("Read", { file_path: `${context.tempDir("wg")}/a.txt` }), env: { ENFORCE_WORKTREE: "on" } }) },
  ] },
  "bash-guard": { kind: "allow-deny", probes: [
    { label: "pipe", want: "deny", input: bash("cat a.txt | grep x") },
    { label: "git status", want: "allow", input: bash("git status") },
  ] },
  // RTK_BIN is node itself: `node hook claude` runs the cwd's `hook` file, a fake rtk.
  "rtk-rewrite": { kind: "non-allow-deny", probes: [
    { label: "RTK on: rewrite through rtk", want: NO_DECISION, setup: (context) => {
      const dir = context.tempDir("rtk");
      fs.writeFileSync(path.join(dir, "hook"), "process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: \"PreToolUse\", " +
        "permissionDecisionReason: \"RTK auto-rewrite\", updatedInput: { command: \"rtk git status\" } } }));\n");
      return { cwd: dir, input: bash("git status"), env: { RTK: "on", RTK_AUDIT: "off", RTK_BIN: process.execPath } };
    } },
    { label: "RTK off: pass-through", want: NO_DECISION, input: bash("git status"), env: { RTK: "off", RTK_AUDIT: "off" } },
  ] },
  "gate-plan-skip-sentinel": { kind: "allow-deny", probes: [
    { label: "OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=off", want: "allow", setup: (context) => ({
      input: bash('echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: fixture>>"', { session_id: sidOf("gate-plan-skip-sentinel") }),
      env: { AGENTS_MAIN_ROOT: configRoot(context, ["CONFIRM_OUTLINE=off"]), CONFIRM_OUTLINE: "off" } }) },
    { label: "OUTLINE_NOT_NEEDED with CONFIRM_OUTLINE=on", want: "none", setup: (context) => ({
      input: bash('echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: fixture>>"', { session_id: sidOf("gate-plan-skip-sentinel") }),
      env: { AGENTS_MAIN_ROOT: configRoot(context, ["CONFIRM_OUTLINE=on"]), CONFIRM_OUTLINE: "on" } }) },
  ] },
  "check-cross-platform": { kind: "allow-deny", probes: [
    { label: "commit with a Windows-only script", want: "deny", setup: (context) => {
      const repo = context.makeRepo("ccp", { "install/win/setup.ps1": "Write-Output x\n" });
      return { input: bash("git commit -m x"), env: { CLAUDE_PROJECT_DIR: repo }, cwd: repo };
    } },
    { label: "commit with a plain text file", want: "approve", setup: (context) => {
      const repo = context.makeRepo("ccp-ok", { "a.txt": "hello\n" });
      return { input: bash("git commit -m x"), env: { CLAUDE_PROJECT_DIR: repo }, cwd: repo };
    } },
  ] },
  "block-capture-echo": { kind: "allow-deny", probes: [
    { label: "capture then echo", want: "deny", input: bash(CAPTURE) },
    { label: "git status", want: "none", input: bash("git status") },
  ] },
  // The repo has no origin, so it is judged public without asking a forge.
  "check-japanese-in-docs": { kind: "allow-deny", probes: [
    { label: "doc-append with Japanese", want: "deny", setup: (context) => {
      const repo = context.makeRepo("cjd");
      return { input: bash(`doc-append "${JAPANESE}"`), env: { CLAUDE_PROJECT_DIR: repo }, cwd: repo };
    } },
    { label: "doc-append in English", want: "approve", setup: (context) => {
      const repo = context.makeRepo("cjd-ok");
      return { input: bash('doc-append "an English line"'), env: { CLAUDE_PROJECT_DIR: repo }, cwd: repo };
    } },
  ] },
  "show-user-verified-context": { kind: "non-allow-deny", probes: [
    { label: "USER_VERIFIED sentinel: context shown", want: NO_DECISION,
      input: bash('echo "<<WORKFLOW_USER_VERIFIED: fixture>>"'), setup: () => ({ env: withFakeGh() }) },
    { label: "ordinary command: nothing shown", want: NO_DECISION, input: bash("git status"), setup: () => ({ env: withFakeGh() }) },
  ] },
  "confirm-checkpoint": { kind: "allow-deny", probes: [
    { label: "CONFIRM_INTENT without the plan-link line", want: "deny", setup: (context) => confirmProbe(context) },
    // #2724 made a CONFIRM echo without a session fail-closed (deny), so the permitted probe has no sentinel.
    { label: "a command without a CONFIRM sentinel", want: "none", input: bash("git status"), env: { CONFIRM_INTENT: "on" } },
  ] },
  "gate-plan-skill-advance": { kind: "allow-deny", probes: [
    { label: "make-outline-plan before the intent is approved", want: "deny", setup: () => {
      const sid = sidOf("gate-plan-skill-advance");
      writeState(sid, { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "pending" });
      return { input: call("Skill", { skill: "make-outline-plan" }, { session_id: sid }), env: { CONFIRM_INTENT: "on" } };
    } },
    { label: "an ungated skill", want: "none",
      input: call("Skill", { skill: "run-tests" }, { session_id: sidOf("gate-plan-skill-advance") }), env: { CONFIRM_INTENT: "on" } },
  ] },
  "block-send-user-file": { kind: "allow-deny", probes: [
    { label: "SendUserFile", want: "deny", input: call("SendUserFile", { file_path: "a.txt" }) },
    { label: "Read", want: "none", input: call("Read", { file_path: "a.txt" }) },
  ] },
  "block-tests-direct": { kind: "allow-deny", probes: [
    { label: "Write under tests/ with write_tests pending", want: "deny", setup: (context) => testsWrite(context, {}) },
    { label: "the same Write from a subagent", want: "approve", setup: (context) => testsWrite(context, { agent_id: "agent-f2676" }) },
  ] },
  "block-comment-block-size": { kind: "allow-deny", probes: [
    { label: "Write a 12-line comment block", want: "deny", setup: (context) => ({
      input: call("Write", { file_path: `${context.tempDir("bcbs")}/a.js`, content: commentLines(12) }) }) },
    { label: "Write a 2-line comment block", want: "approve", setup: (context) => ({
      input: call("Write", { file_path: `${context.tempDir("bcbs-ok")}/a.js`, content: commentLines(2) }) }) },
  ] },
  "gate-plan-lang": { kind: "allow-deny", probes: [
    { label: "outline artifact in Japanese under PLAN_LANG=english", want: "deny", setup: () => ({
      input: call("Write", { file_path: path.join(process.env.WORKFLOW_PLANS_DIR, `${freshUuid()}-outline.md`),
        content: `## Approaches\n\n${JAPANESE}\n` }), env: { PLAN_LANG: "english" } }) },
    { label: "a file outside the plans dir", want: "approve", setup: (context) => ({
      input: call("Write", { file_path: `${context.tempDir("gpl")}/notes.md`, content: `${JAPANESE}\n` }), env: { PLAN_LANG: "english" } }) },
  ] },
  "gate-worktree-notes-lang": { kind: "allow-deny", probes: [
    { label: "History Notes in Japanese under DOCS_LANG=english", want: "deny", setup: (context) => notesWrite(context, "WORKTREE_NOTES.md") },
    { label: "the same text in another file", want: "approve", setup: (context) => notesWrite(context, "OTHER_NOTES.md") },
  ] },
  "block-case-markers": { kind: "allow-deny", probes: [
    { label: "new hook test without case markers", want: "deny", setup: (context) => {
      const repo = context.makeRepo("bcm", { "tests/lib/harness.sh": "#!/usr/bin/env bash\n" });
      return { cwd: repo, input: call("Write", { file_path: `${repo}/tests/hooks/new-case.sh`,
        content: "#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\n# Tags: scope:common\necho no markers\n" }) };
    } },
    { label: "Bash", want: "approve", input: bash("git status") },
  ] },
  "supervisor-off-proposal-shim": { kind: "allow-deny", probes: [
    { label: "WORKFLOW_OFF sentinel without a clearance token", want: "deny",
      input: bash('echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: fixture>>"', { session_id: sidOf("supervisor-off-proposal-shim") }) },
    { label: "Read", want: "none", input: call("Read", { file_path: "a.txt" }) },
  ] },
  "preuse-auto-approve": { kind: "allow-deny", probes: [
    { label: "Monitor", want: "allow", input: call("Monitor", { command: "x" }), env: { AUTO_APPROVE_TOOLS: "on" } },
    { label: "git status", want: "none", input: bash("git status"), env: { AUTO_APPROVE_TOOLS: "on" } },
  ] },
  // JEV_BASE_URL is a closed loopback port, so the shadow query fails fast without a network.
  "jev-shadow-pre": { kind: "non-allow-deny", probes: [
    { label: "complexity-judge dispatch with JEV on", want: NO_DECISION,
      input: call("Agent", { subagent_type: "complexity-judge", prompt: "judge" }, { session_id: sidOf("jev-shadow-pre"), tool_use_id: "toolu_f2676" }),
      env: { JEV: "on", JEV_BASE_URL: "http://127.0.0.1:9", JEV_HTTP_TIMEOUT_MS: "500" } },
    { label: "general-purpose dispatch", want: NO_DECISION,
      input: call("Agent", { subagent_type: "general-purpose", prompt: "x" }, { session_id: sidOf("jev-shadow-pre"), tool_use_id: "toolu_f2676" }),
      env: { JEV: "on", JEV_BASE_URL: "http://127.0.0.1:9", JEV_HTTP_TIMEOUT_MS: "500" } },
  ] },
  "subagent-dispatch-prompt": { kind: "non-allow-deny", probes: [
    { label: "prompt without the canonical line: rewritten", want: NO_DECISION, input: call("Agent", { subagent_type: "general-purpose", prompt: "do x" }) },
    { label: "non-agent tool: pass-through", want: NO_DECISION, input: call("Read", { file_path: "a.txt" }) },
  ] },
  "merged-allow-deny": { kind: "allow-deny", args: ["--matcher-group", "primary"], probes: [
    { label: "Read of a .env file", want: "deny", setup: (context) => ({ input: call("Read", { file_path: `${context.tempDir("mad")}/.env` }) }) },
    { label: "git status", want: "allow", input: bash("git status") },
  ] },
};

function commentLines(count) {
  return Array.from({ length: count }, (_unused, index) => `// comment line ${index}`).join("\n") + "\nconst value = 1;\n";
}
function testsWrite(context, extra) {
  const sid = sidOf("block-tests-direct");
  writeState(sid, { workflow_init: "complete", write_tests: "pending" });
  return { input: call("Write", { file_path: `${context.tempDir("btd")}/tests/a.test.js`, content: "x\n" }, extra),
    env: { CLAUDE_CODE_SESSION_ID: sid } };
}
function notesWrite(context, baseName) {
  return { input: call("Write", { file_path: `${context.tempDir("gwnl")}/${baseName}`, content: `## History Notes\n\n- ${JAPANESE}\n` }),
    env: { DOCS_LANG_PUBLIC: "english", DOCS_LANG_PRIVATE: "english" } };
}
// A fresh session at clarify_intent whose previous turn never showed the plan-link line.
function confirmProbe(context) {
  const sid = freshUuid();
  writeState(sid, { workflow_init: "complete", clarify_intent: "pending" });
  fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), "# Intent\n\nfixture\n");
  const user = (text) => ({ type: "user", message: { role: "user", content: text } });
  const reply = (text) => ({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text }] } });
  const transcript = path.join(context.tempDir("cc"), "t.jsonl");
  fs.writeFileSync(transcript, [user("write the plan"), reply("The plan is ready."), user("looks good, go ahead")]
    .map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  return { input: bash('echo "<<WORKFLOW_CONFIRM_INTENT: approve the intent plan>>"', { session_id: sid, transcript_path: forward(transcript) }),
    env: { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" } };
}

// hasPermissionDecision(stdout): any JSON line with `decision` or hookSpecificOutput.permissionDecision.
function hasPermissionDecision(stdout) {
  return String(stdout || "").split("\n").map((line) => line.trim()).filter(Boolean).some((line) => {
    let out = null;
    try { out = JSON.parse(line); } catch (_e) { return true; }
    return Boolean(out && (out.decision !== undefined || (out.hookSpecificOutput && out.hookSpecificOutput.permissionDecision !== undefined)));
  });
}

// runProbe(hookName, probe, context) -> { status, signal, stdout, stderr, got }. got is the
// classify() class; an exit 2 with nothing on stdout is the host's blocking error, read as deny.
function runProbe(hookName, probe, context) {
  const entry = ORACLE[hookName];
  const built = probe.setup ? (probe.setup(context) || {}) : {};
  const input = built.input !== undefined ? built.input : probe.input;
  const env = { ...process.env };
  for (const name of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PROJECT_DIR", "NODE_OPTIONS", "WORKFLOW_SESSION_ID"]) delete env[name];
  const transcripts = context.tempDir("transcripts");
  const overrides = { AGENTS_MAIN_ROOT: context.tempDir("emptycfg"), CLAUDE_TRANSCRIPT_BASE_DIR: transcripts, ...(probe.env || {}), ...(built.env || {}) };
  const overridden = new Set(Object.keys(overrides).map((name) => name.toUpperCase()));
  for (const name of Object.keys(env)) if (overridden.has(name.toUpperCase())) delete env[name];
  Object.assign(env, overrides);
  const done = spawnSync(process.execPath, [path.join(REPO, "hooks", `${hookName}.js`), ...(entry.args || [])], {
    input: typeof input === "string" ? input : JSON.stringify(input),
    env, cwd: built.cwd || context.tempDir("cwd"), encoding: "utf8", timeout: SPAWN_TIMEOUT_MS,
  });
  const stdout = done.stdout || "";
  let got = classify(stdout);
  if (got === "silent" && done.status === 2) got = "deny";
  if (entry.kind === "non-allow-deny" && !hasPermissionDecision(stdout)) got = NO_DECISION;
  return { status: done.status, signal: done.signal, stdout, stderr: done.stderr || "", got };
}

module.exports = { ORACLE, runProbe };
