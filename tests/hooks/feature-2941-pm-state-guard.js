"use strict";
// tests/hooks/feature-2941-pm-state-guard.js
// Tests: hooks/block-pm-state-write.js, hooks/pm-session/state-path.js
// Tags: TL1, TL2, scope:issue-specific, pm-session, pretooluse, guard, hook-registration
// #2941: every state file carrying the pm key (own / other / archived / old generation) is blocked
// for every write/command tool and stays byte-identical; non-PM files, read-only Bash and the
// regular writer bin/pm-state set-sequence pass; WORKFLOW_OFF bypasses.
// TL3 gap (what this test does NOT catch):
// - the live PreToolUse routing to this hook (settings.json matchers; the registration test pins them).
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-guard-"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const HOOK = path.join(P.ROOT, "hooks", "block-pm-state-write.js");
function runHook(input, raw, extraEnv) {
  const env = Object.assign({}, process.env, { CLAUDE_TRANSCRIPT_BASE_DIR: tmp }, extraEnv || {});
  for (const k of Object.keys(env)) if (env[k] === undefined) delete env[k];
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = cp.spawnSync(process.execPath, [HOOK], { input: raw !== undefined ? raw : JSON.stringify(input), encoding: "utf8", timeout: 20000, cwd: tmp, env });
  let decision = null;
  try { decision = JSON.parse(String(r.stdout).trim().split(/\r?\n/).pop()).decision; } catch (_) { /* reported below */ }
  return { code: r.status, decision, out: r.stdout || "", err: r.stderr || "" };
}

const self = P.uuid(0x29415001);
const other = P.uuid(0x29415002);
const archived = P.uuid(0x29415003);
const oldGen = P.uuid(0x29415004);
const plain = P.uuid(0x29415005);
P.seedPm(self, P.pm({ tag: "PM-g-self", issues: [8001] }));
P.seedPm(other, P.pm({ tag: "PM-g-other", issues: [8002] }));
P.seedPm(archived, P.pm({ tag: "PM-g-arc", issues: [], archived_at: "2026-11-02T00:00:00.000Z" }));
P.seedPm(oldGen, P.pm({ tag: "PM-g-self", issues: [8001], current_since: "2026-10-01T00:00:00.000Z" }));
P.seedState(plain);

const TARGETS = [["own PM", self], ["another PM", other], ["an archived PM", archived], ["an old generation", oldGen]];
const tools = (file) => [
  ["Write", { tool_name: "Write", tool_input: { file_path: file, content: "{}" } }],
  ["Edit", { tool_name: "Edit", tool_input: { file_path: file, old_string: "a", new_string: "b" } }],
  ["MultiEdit", { tool_name: "MultiEdit", tool_input: { file_path: file, edits: [{ old_string: "a", new_string: "b" }] } }],
  ["editFiles", { tool_name: "editFiles", tool_input: { file_path: file, old_string: "a", new_string: "b" } }],
  ["Bash redirect", { tool_name: "Bash", tool_input: { command: `echo '{}' > '${P.fwd(file)}'` } }],
  ["Bash tee", { tool_name: "Bash", tool_input: { command: `echo '{}' | tee '${P.fwd(file)}'` } }],
  ["Bash cp", { tool_name: "Bash", tool_input: { command: `cp '${P.fwd(path.join(tmp, "src.json"))}' '${P.fwd(file)}'` } }],
  ["runInTerminal redirect", { tool_name: "runInTerminal", tool_input: { command: `echo '{}' > '${P.fwd(file)}'` } }],
  ["runCommands redirect", { tool_name: "runCommands", tool_input: { commands: ["true", `echo '{}' > '${P.fwd(file)}'`] } }],
];

caseBegin("pm-state-guard-blocks-pm-files", "hooks/block-pm-state-write.js");
test("the guard hook exists", () => assert.ok(fs.existsSync(HOOK), HOOK));
for (const [who, sid] of TARGETS) {
  for (const [tool, input] of tools(P.statePath(sid))) {
    test(`${tool} on the state file of ${who} is blocked`, () => {
      const r = runHook(Object.assign({ session_id: self }, input));
      assert.strictEqual(r.decision, "block", `code=${r.code} out=${r.out} err=${r.err}`);
    });
  }
}
for (const [who, sid] of TARGETS.slice(0, 2)) {
  test(`every blocked tool leaves the state file of ${who} byte-identical`, () => {
    const file = P.statePath(sid);
    const before = fs.readFileSync(file);
    for (const [tool, input] of tools(file)) {
      const r = runHook(Object.assign({ session_id: self }, input));
      assert.strictEqual(r.decision, "block", `${tool}: code=${r.code} out=${r.out} err=${r.err}`);
      assert.ok(fs.readFileSync(file).equals(before), `${tool} changed ${file}`);
    }
  });
}
test("the block reason names the regular exits (/pm-add and bin/pm-state set-sequence)", () => {
  const r = runHook({ session_id: self, tool_name: "Write", tool_input: { file_path: P.statePath(self), content: "{}" } });
  assert.match(r.out, /pm-add/);
  assert.match(r.out, /set-sequence/);
});
caseEnd();

// A shell write to any state file is blocked (pm-state-guard-unmarked-state-file), so the pass cases
// keep only the non-shell tools for a state file without the pm key.
const SHELL_SHAPE = /^(Bash|runInTerminal|runCommands|PowerShell)/;
const nonShell = (list) => list.filter(([tool]) => !SHELL_SHAPE.test(tool));

caseBegin("pm-state-guard-passes-non-pm", "hooks/block-pm-state-write.js");
for (const [tool, input] of nonShell(tools(P.statePath(plain))).concat(tools(path.join(tmp, "notes.json")))) {
  test(`${tool} on a file without the pm key passes`, () => {
    assert.ok(fs.existsSync(HOOK), HOOK);
    const r = runHook(Object.assign({ session_id: self }, input));
    assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
  });
}
const READ_ONLY = [
  ["cat of a PM file", `cat '${P.fwd(P.statePath(self))}'`],
  ["bin/pm-state show", `node '${P.fwd(path.join(P.ROOT, "bin", "pm-state"))}' show --session ${self}`],
];
for (const [what, command] of READ_ONLY) {
  test(`read-only Bash (${what}) passes`, () => {
    assert.ok(fs.existsSync(HOOK), HOOK);
    const r = runHook({ session_id: self, tool_name: "Bash", tool_input: { command } });
    assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
  });
}
test("the regular writer (Bash bin/pm-state set-sequence) on an own PM passes", () => {
  assert.ok(fs.existsSync(HOOK), HOOK);
  const command = `node '${P.fwd(path.join(P.ROOT, "bin", "pm-state"))}' set-sequence --session ${self} --file '${P.fwd(path.join(tmp, "seq.json"))}'`;
  const r = runHook({ session_id: self, tool_name: "Bash", tool_input: { command } });
  assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
});
test("a non-JSON stdin approves with a diagnostic, as block-history-direct.js does", () => {
  assert.ok(fs.existsSync(HOOK), HOOK);
  const r = runHook(null, "not json {");
  assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
  assert.ok(r.err.length > 0, "the fail-open path must leave a stderr diagnostic");
});
caseEnd();

caseBegin("pm-state-guard-workflow-off-bypass", "hooks/block-pm-state-write.js");
test("WORKFLOW_OFF of the calling session approves a PM file write with a stderr notice", () => {
  const WS = require(path.join(P.ROOT, "hooks", "workflow-state"));
  const marker = path.join(WS.getSessionStateDir(other), `${other}.workflow-off`);
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.writeFileSync(marker, "");
  try {
    const r = runHook({ session_id: other, tool_name: "Write", tool_input: { file_path: P.statePath(self), content: "{}" } });
    assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
    assert.match(r.err, /block-pm-state-write/);
    assert.match(r.err, /OFF/);
  } finally {
    fs.rmSync(marker, { force: true });
  }
});
caseEnd();

// The latest round's surfaces: the PowerShell tool (both separator forms), NotebookEdit, the `path`
// key, MultiEdit edits[] carrying the path, and a write on the 2nd line of a multi-line Bash command.
const back = (file) => P.fwd(file).replace(/\//g, "\\");
const ps = (command) => ({ tool_name: "PowerShell", tool_input: { command } });
const extraTools = (file) => {
  const shapes = [];
  for (const [form, p] of [["forward-slash", P.fwd(file)], ["backslash", back(file)]]) {
    shapes.push(
      [`PowerShell Set-Content (${form})`, ps(`Set-Content -Path "${p}" -Value '{}'`)],
      [`PowerShell Out-File (${form})`, ps(`'{}' | Out-File -FilePath "${p}"`)],
      [`PowerShell Add-Content (${form})`, ps(`Add-Content -Path "${p}" -Value '{}'`)],
      [`PowerShell > redirect (${form})`, ps(`'{}' > "${p}"`)],
      [`PowerShell Remove-Item (${form})`, ps(`Remove-Item -Path "${p}" -Force`)],
    );
  }
  return shapes.concat([
    ["NotebookEdit notebook_path", { tool_name: "NotebookEdit", tool_input: { notebook_path: file, new_source: "x" } }],
    ["Edit via path", { tool_name: "Edit", tool_input: { path: file, old_string: "a", new_string: "b" } }],
    ["Write via path", { tool_name: "Write", tool_input: { path: file, content: "{}" } }],
    ["MultiEdit edits[].file_path", { tool_name: "MultiEdit", tool_input: { edits: [{ file_path: file, old_string: "a", new_string: "b" }] } }],
    ["Bash multi-line (2nd line writes)", { tool_name: "Bash", tool_input: { command: `echo hello\necho '{}' > '${P.fwd(file)}'` } }],
  ]);
};

caseBegin("pm-state-guard-extra-surfaces", "hooks/block-pm-state-write.js");
for (const [who, sid] of TARGETS.slice(0, 2)) {
  for (const [tool, input] of extraTools(P.statePath(sid))) {
    test(`${tool} on the state file of ${who} is blocked and leaves it byte-identical`, () => {
      const file = P.statePath(sid);
      const before = fs.readFileSync(file);
      const r = runHook(Object.assign({ session_id: self }, input));
      assert.strictEqual(r.decision, "block", `code=${r.code} out=${r.out} err=${r.err}`);
      assert.ok(fs.readFileSync(file).equals(before), `${tool} changed ${file}`);
    });
  }
}
for (const [tool, input] of nonShell(extraTools(P.statePath(plain))).concat(extraTools(path.join(tmp, "notes.json")))) {
  test(`${tool} on a file without the pm key passes`, () => {
    assert.ok(fs.existsSync(HOOK), HOOK);
    const r = runHook(Object.assign({ session_id: self }, input));
    assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
  });
}
for (const [form, p] of [["forward-slash", P.fwd(P.statePath(self))], ["backslash", back(P.statePath(self))]]) {
  for (const verb of ["Get-Content", "cat"]) {
    test(`read-only PowerShell ${verb} (${form}) of a PM file passes and leaves it byte-identical`, () => {
      const before = fs.readFileSync(P.statePath(self));
      const r = runHook(Object.assign({ session_id: self }, ps(`${verb} "${p}"`)));
      assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
      assert.ok(fs.readFileSync(P.statePath(self)).equals(before), `${verb} changed the PM file`);
    });
  }
}
for (const [tool, input] of [
  ["Bash redirect", { tool_name: "Bash", tool_input: { command: `echo '{}' > '${P.fwd(P.statePath(self))}'` } }],
  ["PowerShell Set-Content", ps(`Set-Content -Path "${back(P.statePath(self))}" -Value '{}'`)],
]) {
  test(`WORKFLOW_OFF of the calling session approves a ${tool} write to a PM file`, () => {
    const WS = require(path.join(P.ROOT, "hooks", "workflow-state"));
    const marker = path.join(WS.getSessionStateDir(other), `${other}.workflow-off`);
    fs.mkdirSync(path.dirname(marker), { recursive: true });
    fs.writeFileSync(marker, "");
    try {
      const r = runHook(Object.assign({ session_id: other }, input));
      assert.strictEqual(r.decision, "approve", `code=${r.code} out=${r.out} err=${r.err}`);
      assert.match(r.err, /block-pm-state-write/);
    } finally {
      fs.rmSync(marker, { force: true });
    }
  });
}
caseEnd();

caseBegin("pm-state-path-predicate", "hooks/pm-session/state-path.js");
test("isProtectedPmStatePath is true for PM files and false otherwise", () => {
  const fn = P.load("hooks/pm-session/state-path.js").isProtectedPmStatePath;
  assert.strictEqual(typeof fn, "function");
  for (const sid of [self, other, archived, oldGen]) assert.strictEqual(fn(P.statePath(sid)), true, sid);
  assert.strictEqual(fn(P.statePath(plain)), false);
  assert.strictEqual(fn(P.statePath(P.uuid(0x29415099))), false, "a missing file");
  const outside = path.join(tmp, `${self}.json`);
  fs.copyFileSync(P.statePath(self), outside);
  assert.strictEqual(fn(outside), false, "a pm-bearing file outside every state root");
});
// The atomic writer's tmp name (state-io/core.js): <sid>.json.<pid>.<n>.tmp. The PM tmp carries the
// pm key itself and its <sid>.json does too, so either reading of "raw content" protects it.
const pmTmp = `${P.statePath(self)}.4242.1.tmp`;
const plainTmp = `${P.statePath(plain)}.4242.1.tmp`;
fs.copyFileSync(P.statePath(self), pmTmp);
fs.copyFileSync(P.statePath(plain), plainTmp);
test("isProtectedPmStatePath covers the tmp form of a PM file and not of a non-PM file", () => {
  const fn = P.load("hooks/pm-session/state-path.js").isProtectedPmStatePath;
  assert.strictEqual(typeof fn, "function");
  assert.strictEqual(fn(pmTmp), true, pmTmp);
  assert.strictEqual(fn(plainTmp), false, plainTmp);
});
test("Write on the tmp form of a PM file is blocked; on a non-PM tmp it passes", () => {
  const w = (file) => runHook({ session_id: self, tool_name: "Write", tool_input: { file_path: file, content: "{}" } });
  const hit = w(pmTmp);
  assert.strictEqual(hit.decision, "block", `code=${hit.code} out=${hit.out} err=${hit.err}`);
  const miss = w(plainTmp);
  assert.strictEqual(miss.decision, "approve", `code=${miss.code} out=${miss.out} err=${miss.err}`);
});
caseEnd();

// A state file without the pm key: writing the pm key into it would forge a PM tag and assignment.
const unmarked = P.uuid(0x29415006);
P.seedState(unmarked);
const uFile = P.statePath(unmarked);
const FORGED = JSON.stringify({ session_id: unmarked, pm: { tag: "PM-forged", issues: [{ number: 8001 }] } });
const hook = (input, sid) => runHook(Object.assign({ session_id: sid || self }, input));
const expect = (r, d) => assert.strictEqual(r.decision, d, `code=${r.code} out=${r.out} err=${r.err}`);
const writeT = (file, content) => ({ tool_name: "Write", tool_input: { file_path: file, content } });
const editT = (file, new_string) => ({ tool_name: "Edit", tool_input: { file_path: file, old_string: "a", new_string } });
const bash = (command) => ({ tool_name: "Bash", tool_input: { command } });
// Every shell write (deletion included) is blocked whatever its content: cp / tee content is not inspectable.
const shellWrites = (file) => [
  ["Bash redirect of pm content", bash(`echo '{"pm":{}}' > '${P.fwd(file)}'`)],
  ["Bash >> append", bash(`echo '{}' >> '${P.fwd(file)}'`)],
  ["Bash mv", bash(`mv '${P.fwd(path.join(tmp, "x.json"))}' '${P.fwd(file)}'`)],
  ["Bash rm", bash(`rm -f '${P.fwd(file)}'`)],
  ["PowerShell Copy-Item", ps(`Copy-Item -Path "${back(path.join(tmp, "x.json"))}" -Destination "${back(file)}"`)],
].concat(tools(file).concat(extraTools(file)).filter(([tool]) => SHELL_SHAPE.test(tool)));
// unchanged(file, run) — runs the hook and asserts the file is byte-identical (or still absent).
function unchanged(file, run) {
  const before = fs.existsSync(file) ? fs.readFileSync(file) : null;
  const r = run();
  if (before === null) assert.strictEqual(fs.existsSync(file), false, `${file} was created`);
  else assert.ok(fs.readFileSync(file).equals(before), `${file} changed`);
  return r;
}

caseBegin("pm-state-guard-unmarked-state-file", "hooks/block-pm-state-write.js");
test("B1 Write of a top-level pm key into a state file without it is blocked", () => expect(unchanged(uFile, () => hook(writeT(uFile, FORGED))), "block"));
test("B2 Edit whose new_string carries \"pm\" into a state file without it is blocked", () => {
  expect(unchanged(uFile, () => hook(editT(uFile, '"pm": {"tag": "PM-forged"}'))), "block");
});
test("B2 MultiEdit with one edit whose new_string carries \"pm\" is blocked", () => {
  const edits = [{ old_string: "a", new_string: "b" }, { old_string: "c", new_string: '"pm": {}' }];
  expect(unchanged(uFile, () => hook({ tool_name: "MultiEdit", tool_input: { file_path: uFile, edits } })), "block");
});
for (const [what, input] of [["Write without pm", writeT(uFile, JSON.stringify({ session_id: unmarked }))], ["Edit without pm", editT(uFile, '"note": 1')]]) {
  test(`B3 ${what} into a state file without the pm key passes`, () => expect(hook(input), "approve"));
}
for (const [what, input] of shellWrites(uFile)) {
  test(`B4 ${what} to a state file without the pm key is blocked and leaves it byte-identical`, () => {
    expect(unchanged(uFile, () => hook(input)), "block");
  });
}
for (const [what, input] of [["Bash cat", bash(`cat '${P.fwd(uFile)}'`)], ["PowerShell Get-Content", ps(`Get-Content "${back(uFile)}"`)]]) {
  test(`B5 read-only ${what} of a state file without the pm key passes`, () => expect(hook(input), "approve"));
}
const outsideSid = path.join(tmp, `${unmarked}.json`);
const notesInRoot = path.join(path.dirname(uFile), "notes.txt");
for (const [where, file] of [["a <sid>.json outside every state root", outsideSid], ["a non-sid name inside the state root", notesInRoot]]) {
  for (const [what, input] of [["Write of pm content", writeT(file, FORGED)], ["Edit carrying \"pm\"", editT(file, '"pm": {}')]].concat(shellWrites(file))) {
    test(`B6 ${what} to ${where} passes`, () => expect(hook(input), "approve"));
  }
}
for (const [what, input] of [["Write of pm content", writeT(uFile, FORGED)], ["Bash redirect of pm content", shellWrites(uFile)[0][1]]]) {
  test(`B7 WORKFLOW_OFF of the calling session approves a ${what} to a state file without the pm key`, () => {
    const WS = require(path.join(P.ROOT, "hooks", "workflow-state"));
    const marker = path.join(WS.getSessionStateDir(other), `${other}.workflow-off`);
    fs.mkdirSync(path.dirname(marker), { recursive: true });
    fs.writeFileSync(marker, "");
    try {
      const r = hook(input, other);
      expect(r, "approve");
      assert.match(r.err, /block-pm-state-write/);
    } finally {
      fs.rmSync(marker, { force: true });
    }
  });
}
test("B8 Write of pm content to the tmp form of a state file without the pm key is blocked and creates no tmp", () => {
  const tmpForm = `${uFile}.4242.2.tmp`;
  expect(unchanged(tmpForm, () => hook(writeT(tmpForm, FORGED))), "block");
});
for (const [what, input] of shellWrites(`${uFile}.4242.3.tmp`)) {
  test(`B8 ${what} to the tmp form of a state file without the pm key is blocked and creates no tmp`, () => {
    expect(unchanged(`${uFile}.4242.3.tmp`, () => hook(input)), "block");
  });
}
caseEnd();

// A shell target spelled through the home (~, $HOME, $env:USERPROFILE) or relative after a cd.
// The hook runs with HOME/USERPROFILE at a fixture home whose .workflow-state holds a PM file,
// under both root modes: pinned there by WORKFLOW_STATE_DIR, and unpinned (the default <home> root).
const fhome = path.join(tmp, "home");
const fRoot = path.join(fhome, ".workflow-state");
fs.mkdirSync(fRoot, { recursive: true });
fs.mkdirSync(path.join(fhome, "foo"), { recursive: true });
const fPm = path.join(fRoot, `${self}.json`);
fs.copyFileSync(P.statePath(self), fPm);
const ROOT_MODES = [
  ["pinned root", { HOME: fhome, USERPROFILE: fhome, WORKFLOW_STATE_DIR: fRoot }],
  ["default root", { HOME: fhome, USERPROFILE: fhome, WORKFLOW_STATE_DIR: undefined, WORKFLOW_PLANS_DIR: undefined }],
];
const HOME_HITS = [
  ["Bash ~ redirect", bash(`echo '{}' > ~/.workflow-state/${self}.json`)],
  ["Bash $HOME redirect", bash(`echo '{}' > "$HOME/.workflow-state/${self}.json"`)],
  ["PowerShell $env:USERPROFILE Set-Content", ps(`Set-Content $env:USERPROFILE\\.workflow-state\\${self}.json x`)],
  ["Bash relative write after cd into the state root", bash(`cd ~/.workflow-state && echo x > ${self}.json`)],
];
const HOME_MISSES = [
  ["Bash ~ redirect to a non-state name in the state root", bash("echo x > ~/.workflow-state/other.txt")],
  ["Bash ~ redirect to <sid>.json outside the state root", bash(`echo '{}' > ~/foo/${self}.json`)],
  ["PowerShell $env:USERPROFILE Set-Content outside the state root", ps(`Set-Content $env:USERPROFILE\\foo\\${self}.json x`)],
  ["Bash relative write after cd outside the state root", bash(`cd ~/foo && echo x > ${self}.json`)],
];
// runHook spawns with cwd=tmp (outside every state root), so a relative hit proves tool_input.cwd is the base.
const atCwd = (cwd) => ({ tool_name: "Bash", tool_input: { command: `echo x > ${self}.json`, cwd } });
const psEnv = (sub) => [
  [`PowerShell \${env:USERPROFILE}\\${sub} Set-Content`, ps(`Set-Content \${env:USERPROFILE}\\${sub}\\${self}.json x`)],
  [`PowerShell "$env:USERPROFILE\\${sub}" (double-quoted) Set-Content`, ps(`Set-Content "$env:USERPROFILE\\${sub}\\${self}.json" x`)],
];
HOME_HITS.push(["Bash relative write with tool_input.cwd at the state root", atCwd(fRoot)], ...psEnv(".workflow-state"));
HOME_MISSES.push(["Bash relative write with tool_input.cwd outside the state root", atCwd(path.join(fhome, "foo"))], ...psEnv("foo"));

caseBegin("pm-state-guard-shell-home-and-cd", "hooks/block-pm-state-write.js");
for (const [mode, env] of ROOT_MODES) {
  test(`fixture sanity (${mode}): the fixture home holds the PM file and an absolute write to it is blocked`, () => {
    assert.ok(fs.readFileSync(fPm, "utf8").includes('"pm"'), fPm);
    expect(runHook(Object.assign({ session_id: self }, bash(`echo '{}' > '${P.fwd(fPm)}'`)), undefined, env), "block");
  });
  for (const [what, input] of HOME_HITS) {
    test(`C1 ${what} to a PM file (${mode}) is blocked and leaves it byte-identical`, () => {
      expect(unchanged(fPm, () => runHook(Object.assign({ session_id: self }, input), undefined, env)), "block");
    });
  }
  for (const [what, input] of HOME_MISSES) {
    test(`C1 ${what} (${mode}) passes`, () => expect(runHook(Object.assign({ session_id: self }, input), undefined, env), "approve"));
  }
}
caseEnd();
