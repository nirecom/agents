"use strict";
// tests/hooks/feature-2853-block-main-audit-verdict.js
// Tests: hooks/block-main-audit-verdict.js
// Tags: scope:issue-specific, TL2, supervisor-audit, pre-confirm-audit, subagent-detect, fail-closed, table-driven, runCommands, runInTerminal, PowerShell
// #2853: only the supervisor-audit subagent writes an audit verdict; the main conversation (no
// non-empty-string agent_id) is blocked from the verdict CLIs whatever the path spelling, and
// unreadable input blocks. Output shape: hooks/block-subagent-sentinels.js (decision JSON, exit 0).

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the settings.json PreToolUse registration and Claude Code delivering agent_id on subagent calls

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const HOOK = path.join(ROOT, "hooks", "block-main-audit-verdict.js");

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) { pass += 1; console.log(`PASS ${name}`); } else { fail += 1; console.log(`FAIL ${name} :: ${String(detail).slice(0, 400)}`); }
}
// checked(fn) -> a node:test body that fails when any check() inside fn fails.
const checked = (fn) => () => {
  const before = fail;
  fn();
  assert.strictEqual(fail - before, 0, "check(s) failed; see the FAIL lines above");
};
after(() => {
  restore();
  console.log(`\n${fail === 0 ? "ALL PASS" : `${fail} FAILED, ${pass} passed`} (${pass})`);
});

// run(raw) -> {rc, json, out}: the hook with `raw` as its stdin (a string, sent as-is).
function run(raw) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [HOOK], { input: raw, env, encoding: "utf8", timeout: 30000, cwd: process.env.WORKFLOW_STATE_DIR });
  const out = r.stdout || "";
  let json = null;
  try { json = JSON.parse(out.trim()); } catch (_) { json = null; }
  return { rc: r.status, json, out: out + (r.stderr || "").slice(0, 200) };
}
// input(tool, cmd, agentId) -> the hook input JSON; agentId undefined leaves the key out (main conversation).
function input(tool, cmd, agentId) {
  const tool_input = tool === "runCommands" ? { commands: cmd } : tool === "Read" ? { file_path: cmd } : { command: cmd };
  const o = { session_id: "2853bbbb-0000-4aaa-8bbb-000000000001", hook_event_name: "PreToolUse", tool_name: tool, tool_input };
  if (agentId !== undefined) o.agent_id = agentId;
  return JSON.stringify(o);
}
const blocked = (r) => r.rc === 0 && !!r.json && r.json.decision === "block" && typeof r.json.reason === "string" && r.json.reason !== "";
const approved = (r) => r.rc === 0 && !!r.json && r.json.decision === "approve";
function expect(label, want, r) {
  check(`${label} -> ${want}`, want === "block" ? blocked(r) : approved(r), JSON.stringify({ rc: r.rc, out: r.out }));
}

const SID = "2853bbbb-0000-4aaa-8bbb-000000000001";
const VERDICT = `--audit-run-id run-0001 --verdict CONTINUE --verdict-summary "ok" --session-id ${SID}`;
const SET = `--session-id ${SID} --set-audit-verdict CONTINUE`;
// The ways one call path can be spelled: relative, env-rooted, through node / bash, absolute (both slashes).
const SPELLINGS = [
  ["relative", (bin) => `bin/${bin}`],
  ["env-rooted quoted", (bin) => `"$AGENTS_MAIN_ROOT/bin/${bin}"`],
  ["node env-rooted", (bin) => `node "$AGENTS_MAIN_ROOT/bin/${bin}"`],
  ["bash env-rooted", (bin) => `bash "$AGENTS_MAIN_ROOT/bin/${bin}"`],
  ["node absolute forward slash", (bin) => `node C:/git/agents/bin/${bin}`],
  ["absolute backslash", (bin) => `C:\\git\\agents\\bin\\${bin}`],
  ["posix absolute", (bin) => `/c/git/agents/bin/${bin}`],
];
const VERDICT_CMD = `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-audit-verdict" ${VERDICT}`;

caseBegin("B1 the main conversation writing a verdict is blocked, every spelling", "hooks/block-main-audit-verdict.js");
test("B1 the main conversation writing a verdict is blocked, every spelling", checked(() => {
  for (const [label, spell] of SPELLINGS) {
    expect(`B1 main, supervisor-write-audit-verdict (${label})`, "block", run(input("Bash", `${spell("supervisor-write-audit-verdict")} ${VERDICT}`)));
    expect(`B1 main, supervisor-write-audit --set-audit-verdict (${label})`, "block", run(input("Bash", `${spell("supervisor-write-audit")} ${SET}`)));
  }
}));
caseEnd();
caseBegin("B2 the same commands from a subagent pass", "hooks/block-main-audit-verdict.js");
test("B2 the same commands from a subagent pass", checked(() => {
  for (const [label, spell] of SPELLINGS) {
    expect(`B2 subagent, supervisor-write-audit-verdict (${label})`, "approve", run(input("Bash", `${spell("supervisor-write-audit-verdict")} ${VERDICT}`, "agent-2853")));
    expect(`B2 subagent, supervisor-write-audit --set-audit-verdict (${label})`, "approve", run(input("Bash", `${spell("supervisor-write-audit")} ${SET}`, "agent-2853")));
  }
}));
caseEnd();
caseBegin("B3 the other command tools and compound commands are covered the same way", "hooks/block-main-audit-verdict.js");
test("B3 the other command tools and compound commands are covered the same way", checked(() => {
  expect("B3 main runInTerminal verdict", "block", run(input("runInTerminal", VERDICT_CMD)));
  expect("B3 main runCommands, verdict in the second element", "block", run(input("runCommands", ["git status", VERDICT_CMD])));
  expect("B3 subagent runCommands verdict", "approve", run(input("runCommands", ["git status", VERDICT_CMD], "agent-2853")));
  expect("B3 main compound command carrying the verdict call", "block", run(input("Bash", `cd /tmp && ${VERDICT_CMD}`)));
}));
caseEnd();
caseBegin("B4 what is not a verdict write passes from the main conversation", "hooks/block-main-audit-verdict.js");
test("B4 what is not a verdict write passes from the main conversation", checked(() => {
  for (const [label, tool, cmd] of [
    ["--clear-audit-phase only", "Bash", `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-audit" --session-id ${SID} --clear-audit-phase`],
    ["unrelated git command", "Bash", "git status"],
    ["unrelated next-step --gate", "Bash", `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --gate --session ${SID}`],
    ["Read of the verdict CLI (not a command tool)", "Read", path.join(ROOT, "bin", "supervisor-write-audit-verdict")],
    ["Write tool carrying verdict text (not a command tool)", "Write", `bin/supervisor-write-audit-verdict ${VERDICT}`],
  ]) {
    expect(`B4 main, ${label}`, "approve", run(input(tool, cmd)));
  }
}));
caseEnd();
caseBegin("B5 unreadable input blocks (fail-closed)", "hooks/block-main-audit-verdict.js");
test("B5 unreadable input blocks (fail-closed)", checked(() => {
  for (const [label, raw] of [["empty stdin", ""], ["broken JSON", "{not json"], ["truncated JSON", "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":"]]) {
    expect(`B5 ${label}`, "block", run(raw));
  }
}));
caseEnd();
caseBegin("B6 an agent_id that is not a non-empty string reads as the main conversation", "hooks/block-main-audit-verdict.js");
test("B6 an agent_id that is not a non-empty string reads as the main conversation", checked(() => {
  for (const [label, id] of [["empty string", ""], ["number", 123], ["null", null], ["object", { id: "x" }], ["boolean true", true]]) {
    expect(`B6 agent_id ${label}, verdict write`, "block", run(input("Bash", VERDICT_CMD, id)));
  }
}));
caseEnd();
caseBegin("B7 the PowerShell tool (tool_input.command) is gated like Bash", "hooks/block-main-audit-verdict.js");
test("B7 the PowerShell tool (tool_input.command) is gated like Bash", checked(() => {
  for (const { name, cmd, agentId, want } of [
    { name: "main, node bin/supervisor-write-audit-verdict", cmd: `node bin/supervisor-write-audit-verdict ${VERDICT}`, want: "block" },
    { name: "main, env-rooted backslash verdict CLI", cmd: `node "$env:AGENTS_MAIN_ROOT\\bin\\supervisor-write-audit-verdict" ${VERDICT}`, want: "block" },
    { name: "main, supervisor-write-audit --set-audit-verdict", cmd: `node bin/supervisor-write-audit ${SET}`, want: "block" },
    { name: "subagent, node bin/supervisor-write-audit-verdict", cmd: `node bin/supervisor-write-audit-verdict ${VERDICT}`, agentId: "agent-2853", want: "approve" },
    { name: "main, Get-ChildItem", cmd: "Get-ChildItem -Recurse -Filter *.js", want: "approve" },
    { name: "main, --clear-audit-phase only", cmd: `node bin/supervisor-write-audit --session-id ${SID} --clear-audit-phase`, want: "approve" },
  ]) {
    expect(`B7 PowerShell ${name}`, want, run(input("PowerShell", cmd, agentId)));
  }
}));
caseEnd();
// The CLI (bin/supervisor-write-audit) takes only the exact token --set-audit-verdict, so the
// `=` form is blocked on the safe side; the other near-misses are not a verdict write.
caseBegin("B8 regex boundaries of the verdict-CLI path and the --set-audit-verdict flag", "hooks/block-main-audit-verdict.js");
test("B8 regex boundaries of the verdict-CLI path and the --set-audit-verdict flag", checked(() => {
  for (const { name, cmd, want } of [
    { name: "--set-audit-verdict=CONTINUE", cmd: `node bin/supervisor-write-audit --session-id ${SID} --set-audit-verdict=CONTINUE`, want: "block" },
    { name: "--set-audit-verdict at the line end", cmd: `node bin/supervisor-write-audit --session-id ${SID} --set-audit-verdict`, want: "block" },
    { name: "--set-audit-verdict-foo (not the flag)", cmd: `node bin/supervisor-write-audit --session-id ${SID} --set-audit-verdict-foo CONTINUE`, want: "approve" },
    { name: "--set-audit-verdict-summary alone (no verdict)", cmd: `node bin/supervisor-write-audit --session-id ${SID} --set-audit-verdict-summary x`, want: "approve" },
    { name: "--set-audit-verdict-summary with --set-audit-verdict", cmd: `node bin/supervisor-write-audit --set-audit-verdict-summary x ${SET}`, want: "block" },
    { name: "--set-audit-verdict on another CLI", cmd: `node bin/other-cli --set-audit-verdict CONTINUE`, want: "approve" },
    { name: "supervisor-write-audit-verdicts (another name)", cmd: `node bin/supervisor-write-audit-verdicts ${VERDICT}`, want: "approve" },
    { name: "supervisor-write-audit-verdicts --set-audit-verdict", cmd: `node bin/supervisor-write-audit-verdicts ${SET}`, want: "approve" },
    { name: "mybin/supervisor-write-audit-verdict (not a bin segment)", cmd: `node mybin/supervisor-write-audit-verdict ${VERDICT}`, want: "approve" },
    { name: "single-quoted verdict CLI", cmd: `node '/c/git/agents/bin/supervisor-write-audit-verdict' ${VERDICT}`, want: "block" },
    { name: "verdict CLI with no arguments", cmd: "node bin/supervisor-write-audit-verdict", want: "block" },
  ]) {
    expect(`B8 main ${name}`, want, run(input("Bash", cmd)));
  }
}));
caseEnd();
