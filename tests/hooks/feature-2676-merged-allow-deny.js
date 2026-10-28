"use strict";
// Tests: hooks/merged-allow-deny.js, hooks/merged-allow-deny/run.js, hooks/merged-allow-deny/members.js, hooks/merged-allow-deny/merge.js, settings.json, hooks/block-dotenv.js, hooks/block-credentials.js, hooks/bash-guard.js, hooks/block-capture-echo.js, hooks/preuse-auto-approve.js
// Tags: TL2, hooks, pretooluse, allow-deny-hook, merged-hook, canary, subprocess, fail-open, fail-close, workflow-off, scope:issue-specific
// #2676 Step 4: five allow-deny hooks merged into one process per matcher group. Every case runs
// the real hooks as node processes; the oracle is the pre-merge registration (fixture.js).
// TL3 gap (what this test does NOT catch):
// - that a live Claude Code release runs the two merged registrations for the matching tools
// Closest-to-action mitigation: tests/hooks/TL3-hook-merged-allow-deny-registration.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const kit = require("./feature-2676-merged-allow-deny/fixture");
const fx = kit.makeFixture("f2676-mad");
after(() => { fx.cleanup(); restore(); });

const mergedExists = () => assert.ok(fs.existsSync(kit.MERGED), "hooks/merged-allow-deny.js exists");
const spf = fx.scratchpad.replace(/\\/g, "/");
const CAPTURE = 'x="$(date)"; echo "$x"';
const SSH = path.join(os.homedir(), ".ssh");
const DOTENV = path.join(fx.root, ".env");

// name -> [tool, tool_input, extra env, today's standalone classes, merged class]. A class list
// with "|" accepts either value (bash-guard's notify maps to none + extras under the plan).
const CASES = [
  ["bash-readonly", "Bash", { command: "git status" }, null,
    { "block-dotenv": "approve", "block-credentials": "approve", "bash-guard": "allow", "block-capture-echo": "none", "preuse-auto-approve": "none" }, "allow"],
  ["bash-pipe", "Bash", { command: "cat a.txt | grep x" }, null, { "bash-guard": "deny" }, "deny"],
  ["bash-notify", "Bash", { command: '"<<WORKFLOW_MARK_STEP_p1_complete>>"' }, null,
    { "block-dotenv": "approve", "bash-guard": "approve|none" }, "approve"],
  ["bash-dotenv", "Bash", { command: "cat .env" }, null, { "block-dotenv": "deny", "block-credentials": "approve" }, "deny"],
  ["read-dotenv", "Read", { file_path: DOTENV }, null, { "block-dotenv": "deny", "block-credentials": "approve" }, "deny"],
  ["edit-dotenv", "Edit", { file_path: DOTENV, old_string: "a", new_string: "b" }, null, { "block-dotenv": "deny" }, "deny"],
  ["grep-credential", "Grep", { pattern: "x", path: SSH }, null, { "block-dotenv": "approve", "block-credentials": "deny" }, "deny"],
  ["glob-dotenv", "Glob", { pattern: ".env" }, null, { "block-dotenv": "deny", "block-credentials": "approve" }, "deny"],
  ["codegraph-dotenv", "mcp__codegraph__codegraph_explore", { query: ".env" }, null, { "block-dotenv": "deny" }, "deny"],
  ["terminal-pwsh", "runInTerminal", { command: "Get-ChildItem | Select-Object Name" }, null,
    { "block-dotenv": "approve", "block-capture-echo": "none", "preuse-auto-approve": "none" }, "approve"],
  ["worktree-inside", "EnterWorktree", { path: path.join(fx.wtBase, "w1") }, null, { "preuse-auto-approve": "allow" }, "allow"],
  ["worktree-outside", "EnterWorktree", { path: fx.root }, null, { "preuse-auto-approve": "none" }, "none"],
  ["worktree-auto-approve-off", "EnterWorktree", { path: path.join(fx.wtBase, "w1") }, { AUTO_APPROVE_TOOLS: "off" },
    { "preuse-auto-approve": "none" }, "none"],
  ["monitor", "Monitor", { command: "x" }, null, { "preuse-auto-approve": "allow" }, "allow"],
  ["monitor-auto-approve-off", "Monitor", { command: "x" }, { AUTO_APPROVE_TOOLS: "off" }, { "preuse-auto-approve": "none" }, "none"],
  ["bash-scratchpad", "Bash", { command: `bash ${spf}/a.sh` }, null,
    { "bash-guard": "approve", "preuse-auto-approve": "allow" }, "allow"],
  ["bash-capture", "Bash", { command: CAPTURE }, null, { "bash-guard": "deny", "block-capture-echo": "deny" }, "deny"],
  ["terminal-capture", "runInTerminal", { command: CAPTURE }, null, { "block-capture-echo": "deny" }, "deny"],
];
const inputOf = (tool, toolInput, extra) => ({ tool_name: tool, tool_input: toolInput, ...(extra || {}) });
const accepts = (want, got) => want.split("|").includes(got === "silent" ? "none" : got);

caseBegin("standalone-regression", "hooks/block-dotenv.js");
for (const [name, tool, toolInput, env, today] of CASES) {
  test(`standalone ${name}: each member's decision is what it is today`, () => {
    for (const [member, want] of Object.entries(today)) {
      const got = kit.classify(kit.standalone(fx, member, inputOf(tool, toolInput), { env }).stdout);
      assert.ok(accepts(want, got), `${member} on ${name}: want ${want}, got ${got}`);
    }
  });
}
test("standalone approve and pass-through keep their exact bytes (b-rejected)", () => {
  assert.strictEqual(kit.standalone(fx, "block-dotenv", inputOf("Bash", { command: "git status" })).stdout.trim(), '{"decision":"approve"}');
  assert.strictEqual(kit.standalone(fx, "block-credentials", inputOf("Bash", { command: "git status" })).stdout.trim(), '{"decision":"approve"}');
  assert.strictEqual(kit.standalone(fx, "bash-guard", inputOf("Bash", { command: "make build" })).stdout.trim(), '{"decision":"approve"}');
  assert.strictEqual(kit.standalone(fx, "block-capture-echo", inputOf("Bash", { command: "git status" })).stdout.trim(), "{}");
  assert.strictEqual(kit.standalone(fx, "preuse-auto-approve", inputOf("Bash", { command: "git status" })).stdout.trim(), "{}");
});
for (const [kind, table] of Object.entries(kit.FAILURE)) {
  test(`standalone ${kind}: each member's failure result is what it is today`, () => {
    for (const [member, want] of Object.entries(table)) {
      const done = kind === "read-error"
        ? kit.runHook(fx, path.join(kit.HOOKS, `${member}.js`), [], "", { readError: true })
        : kit.runHook(fx, path.join(kit.HOOKS, `${member}.js`), [], "{not json");
      assert.strictEqual(kit.classify(done.stdout), want, `${member} on ${kind}`);
    }
  });
}
caseEnd();

caseBegin("merged-equivalence", "hooks/merged-allow-deny/run.js");
for (const [name, tool, toolInput, env, , want] of CASES) {
  test(`merged ${name}: equals the pre-merge members combined deny > ask > allow > approve > none`, () => {
    mergedExists();
    const input = inputOf(tool, toolInput);
    const combined = kit.mergeClasses(kit.membersFor(tool).map((member) => kit.classify(kit.standalone(fx, member, input, { env }).stdout)));
    const got = kit.classify(kit.merged(fx, kit.groupOf(tool), input, { env }).stdout);
    assert.strictEqual(got === "silent" ? "none" : got, combined, `${name}: merged vs members combined`);
    assert.strictEqual(combined, want, `${name}: the combined oracle is still ${want}`);
  });
}
caseEnd();

caseBegin("merged-no-decision-kept", "hooks/merged-allow-deny/merge.js");
for (const [name, toolInput, env] of [
  ["worktree-outside", { path: fx.root }, null],
  ["auto-approve-off", { path: path.join(fx.wtBase, "w1") }, { AUTO_APPROVE_TOOLS: "off" }],
]) {
  test(`merged ${name}: no decision key and no permissionDecision key`, () => {
    mergedExists();
    const done = kit.merged(fx, "monitor-worktree", inputOf("EnterWorktree", toolInput), { env });
    const out = kit.parseOut(done.stdout) || {};
    assert.ok(!("decision" in out), `no decision key in ${done.stdout}`);
    assert.ok(!(out.hookSpecificOutput && "permissionDecision" in out.hookSpecificOutput), `no permissionDecision in ${done.stdout}`);
  });
}
caseEnd();

caseBegin("merged-routing", "hooks/merged-allow-deny/members.js");
test("merged: bash-guard does not judge runInTerminal (a pwsh pipe is not denied)", () => {
  mergedExists();
  const got = kit.classify(kit.merged(fx, "primary", inputOf("runInTerminal", { command: "Get-ChildItem | Select-Object Name" })).stdout);
  assert.notStrictEqual(got, "deny");
});
for (const [tool, toolInput] of [["Read", { file_path: DOTENV }], ["Grep", { pattern: "x", path: SSH }],
  ["Glob", { pattern: ".env" }], ["Edit", { file_path: DOTENV, old_string: "a", new_string: "b" }],
  ["mcp__codegraph__codegraph_explore", { query: ".env" }]]) {
  test(`merged: the dotenv / credential deny on ${tool} is kept`, () => {
    mergedExists();
    assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf(tool, toolInput)).stdout), "deny");
  });
}
caseEnd();

caseBegin("merged-precedence", "hooks/merged-allow-deny/merge.js");
const BG_ALLOW = kit.preload(fx, "bash-guard-allow", kit.patchJudge("bash-guard/judge.js", "judgeBashCommand",
  '() => ({ verdict: "allow", code: "BG-STUB-ALLOW", literalId: null, notifyId: null, sample: null, message: "" })'));
const AA_ALLOW = kit.preload(fx, "auto-approve-allow", kit.patchJudge("preuse-auto-approve/judge.js", "judgeAutoApprove",
  '() => ({ decision: "allow", reason: "stub allow" })'));
test("merged: the bash-guard allow stub takes effect (vacuity guard)", () => {
  mergedExists();
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf("Bash", { command: "make build" }), { env: BG_ALLOW }).stdout), "allow");
});
test("merged: block-dotenv deny beats bash-guard allow", () => {
  mergedExists();
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf("Bash", { command: "cat .env" }), { env: BG_ALLOW }).stdout), "deny");
});
test("merged: the preuse-auto-approve allow stub takes effect (vacuity guard)", () => {
  mergedExists();
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf("runInTerminal", { command: "Get-ChildItem" }), { env: AA_ALLOW }).stdout), "allow");
});
test("merged: block-capture-echo deny beats preuse-auto-approve allow", () => {
  mergedExists();
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf("runInTerminal", { command: CAPTURE }), { env: AA_ALLOW }).stdout), "deny");
});
caseEnd();

caseBegin("merged-failure-equivalence", "hooks/merged-allow-deny/run.js");
for (const [group, tools] of Object.entries(kit.GROUPS)) {
  for (const kind of Object.keys(kit.FAILURE)) {
    test(`merged --matcher-group ${group} on ${kind}: equals every group tool's pre-merge failure result`, () => {
      mergedExists();
      const perTool = tools.map((tool) => kit.mergeClasses(kit.membersFor(tool).map((member) => kit.FAILURE[kind][member])));
      const done = kind === "read-error"
        ? kit.merged(fx, group, "", { readError: true })
        : kit.merged(fx, group, "{not json");
      const got = kit.classify(done.stdout);
      for (const [index, want] of perTool.entries()) {
        assert.strictEqual(got === "silent" ? "none" : got, want, `${group} ${kind} vs ${tools[index]}`);
      }
    });
  }
}
test("merged monitor-worktree read-error is not a deny", () => {
  mergedExists();
  const got = kit.classify(kit.merged(fx, "monitor-worktree", "", { readError: true }).stdout);
  assert.notStrictEqual(got, "deny");
  assert.ok(got === "none" || got === "silent", `got ${got}`);
});
caseEnd();

caseBegin("merged-fail-open-close", "hooks/merged-allow-deny/run.js");
const CE_THROWS = kit.preload(fx, "capture-echo-throws", kit.patchJudge("block-capture-echo/judge.js", "judgeCaptureEcho",
  '() => { throw new Error("injected fault"); }'));
test("merged: a throwing member is skipped (vacuity guard: its deny is gone)", () => {
  mergedExists();
  assert.notStrictEqual(kit.classify(kit.merged(fx, "primary", inputOf("runInTerminal", { command: CAPTURE }), { env: CE_THROWS }).stdout), "deny");
});
test("merged: a throwing member does not stop another member's deny", () => {
  mergedExists();
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", inputOf("Bash", { command: "cat .env" }), { env: CE_THROWS }).stdout), "deny");
});
// block-dotenv and block-credentials are the fail-closed members: a judge that throws before the
// limit turns into ask, with a reason naming the member whose judgment ended in the exception
// (detail.md Step 4, the user's decision on test review round 1 C3). The single-member entry,
// which also goes through runMembers, gets the same treatment.
const askReasonOf = (stdout) => {
  const out = kit.parseOut(stdout) || {};
  return String((out.hookSpecificOutput && out.hookSpecificOutput.permissionDecisionReason) || "");
};
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const ENTRIES = {
  // bash-guard is stubbed to allow, so an ask here can only come from the throwing member.
  merged: (input, throwing) => kit.merged(fx, "primary", input, { env: { NODE_OPTIONS: `${BG_ALLOW.NODE_OPTIONS} ${throwing.NODE_OPTIONS}` } }),
  "single-member": (input, throwing, member) => kit.standalone(fx, member, input, { env: { NODE_OPTIONS: throwing.NODE_OPTIONS } }),
};
for (const [member, rel, exportName, tool, toolInput] of [
  ["block-dotenv", "block-dotenv/judge.js", "judgeDotenv", "Read", { file_path: DOTENV }],
  ["block-dotenv", "block-dotenv/judge.js", "judgeDotenv", "Bash", { command: "cat .env" }],
  ["block-credentials", "block-credentials/judge.js", "judgeCredentials", "Grep", { pattern: "x", path: SSH }],
]) {
  for (const [entryName, runEntry] of Object.entries(ENTRIES)) {
    test(`${entryName}: a throwing ${member} on ${tool} asks, naming ${member} in the reason`, () => {
      if (entryName === "merged") mergedExists();
      const calledMarker = path.join(fx.root, `${entryName}-${member}-${tool}-called.txt`);
      fs.rmSync(calledMarker, { force: true });
      const throwing = kit.preload(fx, `${entryName}-${member}-${tool}-throws`, kit.patchJudge(rel, exportName,
        `() => { require("fs").writeFileSync(${JSON.stringify(calledMarker)}, "called"); throw new Error("injected fault"); }`));
      const done = runEntry(inputOf(tool, toolInput), throwing, member);
      assert.ok(fs.existsSync(calledMarker), `the throwing ${exportName} stub was called (vacuity guard)`);
      const got = kit.classify(done.stdout);
      assert.strictEqual(got, "ask", `${member} threw on a protected ${tool} input via the ${entryName} entry: want ask, got ${got} (stdout ${done.stdout})`);
      const reason = askReasonOf(done.stdout);
      assert.match(reason, new RegExp(`(^|[^\\w-])${escapeRegExp(member)}([^\\w-]|$)`),
        `the ask reason names the throwing member ${member}: got ${JSON.stringify(reason)}`);
    });
  }
}
test("merged json-invalid writes exactly one stderr diagnostic line", () => {
  mergedExists();
  const done = kit.merged(fx, "primary", "{not json");
  const lines = String(done.stderr).split(/\r?\n/).filter((line) => line.trim() !== "");
  assert.strictEqual(lines.length, 1, `stderr: ${done.stderr}`);
});
caseEnd();

caseBegin("merged-notify", "hooks/merged-allow-deny/merge.js");
test("merged: bash-guard's notify systemMessage and additionalContext survive", () => {
  mergedExists();
  const input = inputOf("Bash", { command: '"<<WORKFLOW_MARK_STEP_p1_complete>>"' });
  const alone = kit.parseOut(kit.standalone(fx, "bash-guard", input).stdout);
  assert.ok(alone && alone.systemMessage, "bash-guard notifies on this input today");
  const aloneContext = String(alone.additionalContext || (alone.hookSpecificOutput || {}).additionalContext || "");
  assert.ok(aloneContext !== "", "bash-guard standalone emits additionalContext");
  const out = kit.parseOut(kit.merged(fx, "primary", input).stdout) || {};
  const context = String(out.additionalContext || (out.hookSpecificOutput || {}).additionalContext || "");
  assert.ok(String(out.systemMessage || "").includes(alone.systemMessage), "systemMessage kept");
  assert.ok(context.includes(aloneContext), "additionalContext kept");
});
caseEnd();

caseBegin("merged-workflow-off", "hooks/merged-allow-deny/run.js");
const { getSessionStateDir } = require(path.join(kit.REPO, "hooks", "workflow-state", "state-io.js"));
const OFF_SID = "sid-f2676-off";
fs.mkdirSync(getSessionStateDir(OFF_SID), { recursive: true });
fs.writeFileSync(path.join(getSessionStateDir(OFF_SID), `${OFF_SID}.workflow-off`), "fixture\n");
for (const [what, tool, toolInput, want] of [
  ["block-dotenv is bypassed", "Bash", { command: "cat .env" }, "approve"],
  ["block-credentials is not bypassed", "Grep", { pattern: "x", path: SSH }, "deny"],
  ["block-capture-echo is not bypassed", "runInTerminal", { command: CAPTURE }, "deny"],
]) {
  test(`merged under WORKFLOW_OFF: ${what}`, () => {
    mergedExists();
    const input = inputOf(tool, toolInput, { session_id: OFF_SID });
    assert.strictEqual(kit.classify(kit.merged(fx, "primary", input).stdout), want);
  });
}
caseEnd();

caseBegin("merged-interlock", "hooks/merged-allow-deny/run.js");
const ARMED_SID = "sid-f2676-armed";
const pending = Object.fromEntries(["workflow_init", "clarify_intent", "research", "outline", "detail"]
  .map((step) => [step, { status: "pending", updated_at: null }]));
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${ARMED_SID}.json`), JSON.stringify({ version: 1,
  session_id: ARMED_SID, created_at: "2026-01-01T00:00:00.000Z", is_bugfix: false, git_branch: "feature/f2676",
  steps: pending, workflow_type: "wf-code" }));
test("merged under the armed early write gate: a read-only command still allows", () => {
  mergedExists();
  const input = inputOf("Bash", { command: "git status" }, { session_id: ARMED_SID });
  assert.strictEqual(kit.classify(kit.standalone(fx, "bash-guard", input).stdout), "allow", "bash-guard allows today");
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", input).stdout), "allow");
});
test("merged under the armed early write gate: a compound command is not denied", () => {
  mergedExists();
  const input = inputOf("Bash", { command: "git status && ls" }, { session_id: ARMED_SID });
  assert.strictEqual(kit.classify(kit.standalone(fx, "bash-guard", input).stdout), "approve", "bash-guard stays quiet today");
  assert.strictEqual(kit.classify(kit.merged(fx, "primary", input).stdout), "approve");
});
caseEnd();

caseBegin("merged-registration", "settings.json");
const settings = JSON.parse(fs.readFileSync(path.join(kit.REPO, "settings.json"), "utf8"));
const registrations = settings.hooks.PreToolUse.flatMap((entry) => entry.hooks.map((hook) => ({ matcher: entry.matcher, command: hook.command })));
const toolSet = (matcher) => new Set(String(matcher).split("|"));
test("settings.json: two merged registrations, one per group, with the group's exact tool set", () => {
  const mergedRegs = registrations.filter((reg) => /merged-allow-deny/.test(reg.command));
  assert.strictEqual(mergedRegs.length, 2, "two merged registrations");
  const seen = new Set();
  for (const reg of mergedRegs) {
    const group = (reg.command.match(/--matcher-group\s+([\w-]+)/) || [])[1];
    assert.ok(group in kit.GROUPS, `command carries a known --matcher-group: ${reg.command}`);
    assert.deepStrictEqual([...toolSet(reg.matcher)].sort(), [...kit.GROUPS[group]].sort(), `${group} matcher`);
    seen.add(group);
  }
  assert.deepStrictEqual([...seen].sort(), Object.keys(kit.GROUPS).sort());
});
test("members.js: its group and member tables match the pre-merge registrations", () => {
  const table = kit.readMembersModule();
  assert.ok(table.groups, "members.js exports a group table keyed by primary / monitor-worktree");
  assert.ok(table.members, "members.js exports a member table of {name, tools}");
  for (const [group, tools] of Object.entries(kit.GROUPS)) {
    assert.deepStrictEqual(table.groups[group], [...tools].sort(), `members.js group ${group}`);
  }
  for (const member of kit.MEMBERS) {
    assert.deepStrictEqual(table.members[member.name], [...member.tools].sort(), `members.js member ${member.name}`);
  }
  const [first, second] = Object.values(table.groups);
  assert.ok(first.every((tool) => !second.includes(tool)), "members.js groups do not overlap");
  const union = new Set(Object.values(table.members).flat());
  assert.deepStrictEqual([...new Set([...first, ...second])].sort(), [...union].sort(), "groups cover the members");
});
test("settings.json: the five standalone entries are no longer registered", () => {
  for (const member of kit.MEMBERS) {
    const re = new RegExp(`hooks[\\\\/]${member.name}\\.js`);
    assert.ok(!registrations.some((reg) => re.test(reg.command)), `${member.name}.js is not registered`);
  }
});
caseEnd();
