"use strict";
// Tests: docs/architecture/claude-code/settings/hook-timeout.md, settings.json, hooks/scan-outbound.js, hooks/workflow-gate.js, hooks/enforce-worktree.js, hooks/confirm-forge-target-ownership.js, hooks/check-cross-platform.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, non-allow-deny-hook, decision-time-limit, settings, docs, scope:issue-specific, subprocess, scan-outbound, workflow-gate, enforce-worktree, settings-registration, block-case-markers
// Serial: spawns every PreToolUse hook and real git commits; ~100 s alone, exceeds the 180 s file limit under parallel load
// #2676 / #2540 Steps 2, 5, 6: hook-timeout.md owns the classification of every PreToolUse hook
// (a missing row, a "with limit" row that never arms, a "no limit" row without a reason fail);
// oracle.js checks each hook's printed class; each heavy hook, run with a shrunken limit and one
// slowed child, answers "ask" naming itself and the check, and decides as before otherwise.
// TL3 gap (what this test does NOT catch):
// - how Claude Code acts on each printed decision; its launch delay and cancel of an overrun hook
// Closest-to-action mitigation: tests/hooks/TL3-hook-registered-deny.sh, TL3-hook-timeout-window.sh.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const fx = require("./feature-2676-hook-classification/fixture");
after(() => { fx.cleanup(); restore(); });
const table = require("./feature-2676-hook-classification/table");

const HOOKS = path.join(table.REPO, "hooks");
// Fixed by the plan (Step 5 arms the heavy hooks; Step 2 names the rewrite / display-only hooks).
const HEAVY = ["scan-outbound", "workflow-gate", "enforce-worktree", "confirm-forge-target-ownership", "check-cross-platform"];
const NON_ALLOW_DENY = ["rtk-rewrite", "subagent-dispatch-prompt", "show-user-verified-context", "jev-shadow-pre"];

const loaded = () => {
  const { rows, error } = table.readClassification();
  assert.ok(!error, error || "");
  assert.ok(rows.length > 0, "the classification table has rows");
  return rows;
};
// The entrypoint is hooks/<name>.js; under file-split Pattern A its logic may sit in hooks/<name>/.
function entrypointSources(hookName) {
  const files = [path.join(HOOKS, `${hookName}.js`)];
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".js")) files.push(full);
    }
  };
  walk(path.join(HOOKS, hookName));
  return files.filter((file) => fs.existsSync(file)).map((file) => fs.readFileSync(file, "utf8"));
}
const armsLimit = (hookName) => entrypointSources(hookName).some((source) => /armDecisionTimeLimit\s*\(/.test(source));
const registeredHooks = () => [...new Set(table.registrations().map((reg) => reg.hook))];

// heavyHookArms(hookName): the heavy hook is a "with limit" allow-deny row and its entrypoint arms.
function heavyHookArms(hookName) {
  test(`${hookName}: allow-deny hook with a limit, and its entrypoint calls armDecisionTimeLimit`, () => {
    const row = table.rowFor(loaded(), hookName);
    assert.ok(row, `${hookName} has a row`);
    assert.deepStrictEqual([row.kind, row.limit], ["allow-deny", "yes"], `${hookName}: allow-deny hook with a limit`);
    assert.ok(armsLimit(hookName), `hooks/${hookName}.js (or hooks/${hookName}/) calls armDecisionTimeLimit`);
  });
}

caseBegin("classification-table", "docs/architecture/claude-code/settings/hook-timeout.md");
test("every row is classified as allow-deny hook or non-allow-deny hook, with a settled limit", () => {
  for (const row of loaded()) {
    assert.ok(row.hooks.length > 0, `the row names a hook under hooks/: ${row.raw}`);
    assert.ok(row.kind, `classification is "allow-deny hook" or "non-allow-deny hook": ${row.raw}`);
    if (row.kind === "allow-deny") {
      assert.ok(row.limit === "yes" || row.limit === "no", `an allow-deny hook's limit starts with ${table.LIMIT_YES} or ${table.LIMIT_NO}: ${row.raw}`);
    } else {
      assert.ok(row.limit !== "yes", `a non-allow-deny hook has no decision time limit: ${row.raw}`);
    }
  }
});

test("each rewrite / display-only hook is a non-allow-deny hook", () => {
  const rows = loaded();
  for (const hookName of NON_ALLOW_DENY) {
    const row = table.rowFor(rows, hookName);
    assert.ok(row, `${hookName} has a row`);
    assert.strictEqual(row.kind, "non-allow-deny", `${hookName}: non-allow-deny hook`);
  }
});

test("every row without a limit says why", () => {
  const without = loaded().filter((row) => row.kind === "allow-deny" && row.limit === "no");
  assert.ok(without.length > 0, "at least one allow-deny hook has no limit (the merged hook)");
  for (const row of without) {
    assert.ok(row.reason && !table.DASH.test(row.reason), `a reason is written: ${row.raw}`);
  }
});

test("every \"with limit\" row's entrypoint calls armDecisionTimeLimit", () => {
  const withLimit = loaded().filter((row) => row.limit === "yes").flatMap((row) => row.hooks);
  assert.ok(withLimit.length >= HEAVY.length, "the heavy hooks are among the rows with a limit");
  assert.deepStrictEqual(withLimit.filter((hookName) => !armsLimit(hookName)), [],
    "\"with limit\" hooks whose entrypoint never arms the limit");
});

// The reader itself, on a fabricated table shaped like the plan's: passes today, so the cases
// above fail only for the missing document, not for a reader that cannot read it.
test("the table reader: header-found table, several hooks per cell, settled and unsettled limits", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "f2676-table-"));
  try {
    const doc = path.join(dir, "hook-timeout.md");
    fs.writeFileSync(doc, [
      "# Sample", "", "| other | column |", "|---|---|", "| scan-outbound | not the table |", "",
      `| hook | ${table.COL_KIND} | ${table.COL_LIMIT} | ${table.COL_REASON} |`, "|---|---|---|---|",
      `| \`scan-outbound\` | allow-deny hook | ${table.LIMIT_YES} | git and scanner child processes |`,
      `| \`enforce-system-ops\` | allow-deny hook | ${table.LIMIT_NO} | no child process |`,
      `| \`rtk-rewrite\`${table.IDEOGRAPHIC_COMMA}\`subagent-dispatch-prompt\` | non-allow-deny hook | ${table.EM_DASH} | updatedInput only |`,
      "| `block-dotenv` | allow-deny hook | Step 2 | unsettled |", "", "After the table.", "",
    ].join("\n"));
    const { rows, error } = table.readClassification(doc);
    assert.strictEqual(error, null);
    assert.deepStrictEqual(rows.map((row) => [row.hooks, row.kind, row.limit]), [
      [["scan-outbound"], "allow-deny", "yes"],
      [["enforce-system-ops"], "allow-deny", "no"],
      [["rtk-rewrite", "subagent-dispatch-prompt"], "non-allow-deny", "none"],
      [["block-dotenv"], "allow-deny", null],
    ]);
    assert.strictEqual(rows[1].reason, "no child process");
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
caseEnd();

caseBegin("classification-coverage", "settings.json");
test("every hook registered under PreToolUse has a row in the classification table", () => {
  const rows = loaded();
  const registered = registeredHooks();
  assert.ok(registered.length > 0 && !registered.includes(null), "every registration runs a hooks/<name>.js");
  assert.deepStrictEqual(registered.filter((hookName) => !table.rowFor(rows, hookName)), [],
    "registered hooks without a classification row");
});

test("a registered hook that arms the limit is a \"with limit\" row (the table stays the SSOT)", () => {
  const rows = loaded();
  const unlisted = registeredHooks().filter((hookName) => armsLimit(hookName))
    .filter((hookName) => { const row = table.rowFor(rows, hookName); return !row || row.limit !== "yes"; });
  assert.deepStrictEqual(unlisted, [], "hooks that arm the limit but are not \"with limit\" in the table");
});
caseEnd();

// --- the decision oracle: what each registered hook really prints -------------------------------
// oracle.js fixes, per hook, a probe input and the decision class it must produce. An allow-deny
// hook has a decision probe (deny / ask, or allow for the hooks that can only allow) and a
// permitted probe (allow / approve / none); a non-allow-deny hook never prints a permission
// decision on any probe. So a row whose classification disagrees with the hook's output fails.
const { ORACLE, runProbe } = require("./feature-2676-hook-classification/oracle");
const probeContext = { tempDir: fx.tempDir, makeRepo: fx.makeRepo, makeLinkedWorktree: fx.makeLinkedWorktree };
const DECISION_WANTS = new Set(["deny", "ask"]);
const PERMITTED_WANTS = new Set(["allow", "approve", "none"]);
// Each of these hooks is an allow-deny hook that can only allow (it never refuses); its decision probe is an allow.
const ALLOW_ONLY_HOOKS = new Set(["gate-plan-skip-sentinel", "preuse-auto-approve"]);

caseBegin("classification-oracle", "settings.json");
test("every registered PreToolUse hook has an oracle entry with a known classification", () => {
  const missing = registeredHooks().filter((hookName) => !ORACLE[hookName]);
  assert.deepStrictEqual(missing, [], "registered hooks without an oracle entry");
  for (const [hookName, entry] of Object.entries(ORACLE)) {
    assert.ok(["allow-deny", "non-allow-deny"].includes(entry.kind), `${hookName}: kind ${entry.kind}`);
    const wants = entry.probes.map((probe) => probe.want);
    if (entry.kind === "non-allow-deny") {
      assert.ok(wants.length >= 2 && wants.every((want) => want === "no-permission-decision"), `${hookName}: ${wants}`);
      continue;
    }
    const decisionWants = ALLOW_ONLY_HOOKS.has(hookName) ? new Set(["allow"]) : DECISION_WANTS;
    assert.ok(wants.some((want) => decisionWants.has(want)), `${hookName}: a decision probe (${[...decisionWants]}): ${wants}`);
    assert.ok(wants.some((want) => PERMITTED_WANTS.has(want)), `${hookName}: a permitted probe: ${wants}`);
  }
});

for (const [hookName, entry] of Object.entries(ORACLE)) {
  test(`${hookName} (${entry.kind} hook): each probe produces its fixed decision`, () => {
    for (const probe of entry.probes) {
      const run = runProbe(hookName, probe, probeContext);
      assert.strictEqual(run.signal, null, `${hookName} / ${probe.label}: finished in time (stderr: ${run.stderr})`);
      // A silent hook makes no decision; the oracle spells that "none".
      const got = run.got === "silent" ? "none" : run.got;
      assert.strictEqual(got, probe.want, `${hookName} / ${probe.label}: stdout ${run.stdout} stderr ${run.stderr}`);
    }
  });
}
caseEnd();

caseBegin("classification-oracle-table", "docs/architecture/claude-code/settings/hook-timeout.md");
test("each table row's classification equals the oracle's (the table is what the hooks do)", () => {
  const rows = loaded();
  const disagreeing = Object.entries(ORACLE).filter(([hookName, entry]) => {
    const row = table.rowFor(rows, hookName);
    return !row || row.kind !== entry.kind;
  }).map(([hookName, entry]) => `${hookName}: oracle ${entry.kind}, table ${(table.rowFor(rows, hookName) || {}).kind}`);
  assert.deepStrictEqual(disagreeing, [], "rows whose classification is not what the hook prints");
});
caseEnd();

caseBegin("arm-scan-outbound", "hooks/scan-outbound.js");
heavyHookArms("scan-outbound");
caseEnd();

caseBegin("arm-workflow-gate", "hooks/workflow-gate.js");
heavyHookArms("workflow-gate");
caseEnd();

caseBegin("arm-enforce-worktree", "hooks/enforce-worktree.js");
heavyHookArms("enforce-worktree");
caseEnd();

caseBegin("arm-confirm-forge-target-ownership", "hooks/confirm-forge-target-ownership.js");
heavyHookArms("confirm-forge-target-ownership");
caseEnd();

caseBegin("arm-check-cross-platform", "hooks/check-cross-platform.js");
heavyHookArms("check-cross-platform");
caseEnd();

// --- Step 5: each heavy hook as a real process at a shrunken decision time limit ----------------
// Small enough to be reached inside one slowed child, large enough for the hook to start.
const LIMIT_MS = "1500";
const SESSION = "00000000-0000-4000-8000-000000002540";
const bash = (command, cwd) => ({ session_id: SESSION, tool_name: "Bash", tool_input: cwd ? { command, cwd } : { command } });

// limitAsk(run, hookName, checkPattern): the slowed child really ran, and the hook asked in time.
function limitAsk(run, hookName, checkPattern) {
  assert.ok(run.calls.some((call) => call.mode === "slow"), `a slowed child was started: ${JSON.stringify(run.calls)}`);
  assert.strictEqual(run.signal, null, `${hookName} answered before the ${fx.WAIT_CAP_MS} ms wait cap (stderr: ${run.stderr})`);
  assert.strictEqual(run.decision, "ask", `${hookName} asks at the limit; got ${run.decision}: ${run.reason || run.stdout}`);
  assertLimitReason(run.reason, hookName, checkPattern);
  assert.strictEqual(run.status, 0);
}
// assertLimitReason: the whole fixed format, "<hookName>: decision time limit (<ms> ms) reached
// before <checkName> finished; asking instead of deciding", with <checkName> naming the check.
function assertLimitReason(reason, hookName, checkPattern) {
  const escaped = hookName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const format = new RegExp(`^${escaped}: decision time limit \\(${LIMIT_MS} ms\\) reached before (.+) finished; asking instead of deciding$`);
  const matched = format.exec(reason);
  assert.ok(matched, `reason follows the fixed format: ${reason}`);
  assert.match(matched[1], checkPattern, "<checkName> names the check");
}
const decided = (run, decision) => {
  assert.strictEqual(run.signal, null, `answered before the wait cap (stderr: ${run.stderr})`);
  assert.strictEqual(run.decision, decision, `got ${run.decision}: ${run.reason || run.stdout}`);
};

caseBegin("scan-outbound-limit", "hooks/scan-outbound.js");
test("scan-outbound: a slow staged-blob read reaches the limit -> ask naming the read", () => {
  const repo = fx.makeRepo("so", { "a.txt": "hello\n" });
  const run = fx.runHook("scan-outbound", bash(`git -C ${repo} commit -m x`),
    { env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (show|cat-file)" } });
  limitAsk(run, "scan-outbound", /git (show|cat-file)/);
});

test("scan-outbound: 750 staged files and the limit reached -> ask, neither block nor approve", () => {
  const files = Object.fromEntries(Array.from({ length: 750 }, (_unused, index) => [`many/file-${index}.txt`, `line ${index}\n`]));
  const repo = fx.makeRepo("so750", files);
  // The manifest scanner is slowed too, so the limit is reached whichever way the blobs are read.
  const run = fx.runHook("scan-outbound", bash(`git -C ${repo} commit -m x`),
    { env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "--manifest" } });
  assert.strictEqual(run.signal, null, `answered before the ${fx.WAIT_CAP_MS} ms wait cap`);
  assert.strictEqual(run.decision, "ask", `got ${run.decision}: ${run.reason || run.stdout}`);
  assertLimitReason(run.reason, "scan-outbound", /\S/);
});

test("regression: a manifest scanner that fails before the limit still blocks (fail-closed)", () => {
  const repo = fx.makeRepo("sofail", { "a.txt": "hello\n" });
  const run = fx.runHook("scan-outbound", bash(`git -C ${repo} commit -m x`), { env: { F2540_FAIL: "--manifest" } });
  assert.ok(run.calls.some((call) => call.mode === "fail"), "the scanner spawn was failed");
  decided(run, "block");
});

test("regression: the manifest holds the same staged text files, binaries skipped", () => {
  const repo = fx.makeRepo("soman", { "a.txt": "alpha\n", "docs/b.md": "beta\n", "c.bin": Buffer.from([0x41, 0, 0x42]) });
  const capture = path.join(fx.tempDir("cap"), "manifest.bin");
  const run = fx.runHook("scan-outbound", bash(`git -C ${repo} commit -m x`),
    { env: { F2540_CAPTURE: "--manifest", F2540_CAPTURE_FILE: capture } });
  assert.ok(fs.existsSync(capture), `the manifest scanner received input (calls: ${JSON.stringify(run.calls)})`);
  // Frames: RS path RS length LF blob (scan-outbound's manifest format).
  const frames = fs.readFileSync(capture, "latin1").split("\x1e").slice(1);
  const entries = {};
  for (let index = 0; index + 1 < frames.length; index += 2) entries[frames[index]] = frames[index + 1].replace(/^\d+\n/, "");
  assert.deepStrictEqual(entries, { "a.txt": "alpha\n", "docs/b.md": "beta\n" });
});

test("regression: a staged blob that cannot be read blocks", () => {
  const repo = fx.makeRepo("sounread", { "a.txt": "hello\n" });
  const run = fx.runHook("scan-outbound", bash(`git -C ${repo} commit -m x`), { env: { F2540_FAIL: "^git (show|cat-file)" } });
  assert.ok(run.calls.some((call) => call.mode === "fail"), "the blob read was failed");
  decided(run, "block");
});
caseEnd();

caseBegin("scan-outbound-parse-batch", "hooks/scan-outbound.js");
// parseBatch over hand-made `git cat-file --batch` output: one blob per requested path in request
// order, or the first unreadable path named (fail-closed: never a shorter blob list).
const { parseBatch } = require("../../hooks/scan-outbound/staged-blobs.js");
const SHA = "0123456789abcdef0123456789abcdef01234567";
const record = (content) => Buffer.from(`${SHA} blob ${Buffer.byteLength(content)}\n${content}\n`);
const PARSE_BATCH_ROWS = [
  ["valid: two records in request order", Buffer.concat([record("alpha\n"), record("beta")]), ["a.txt", "b.txt"], { blobs: [["a.txt", "alpha\n"], ["b.txt", "beta"]] }],
  ["empty blob (size 0)", record(""), ["empty.txt"], { blobs: [["empty.txt", ""]] }],
  ["no paths requested", Buffer.alloc(0), [], { blobs: [] }],
  ["missing object", Buffer.concat([record("alpha\n"), Buffer.from(":gone.txt missing\n")]), ["a.txt", "gone.txt"], { unreadable: "gone.txt" }],
  ["truncated content", Buffer.from(`${SHA} blob 10\nshort\n`), ["a.txt"], { unreadable: "a.txt" }],
  ["truncated header (no line feed)", Buffer.from(`${SHA} blob`), ["a.txt"], { unreadable: "a.txt" }],
  ["fewer records than paths", record("alpha\n"), ["a.txt", "b.txt"], { unreadable: "b.txt" }],
  ["malformed size", Buffer.from(`${SHA} blob abc\nalpha\n`), ["a.txt"], { unreadable: "a.txt" }],
  ["negative size", Buffer.from(`${SHA} blob -1\n\n`), ["a.txt"], { unreadable: "a.txt" }],
  ["not a blob", Buffer.from(`${SHA} tree 5\nalpha\n`), ["a.txt"], { unreadable: "a.txt" }],
  ["content not followed by a line feed", Buffer.from(`${SHA} blob 5\nalphaX`), ["a.txt"], { unreadable: "a.txt" }],
];
for (const [label, stdout, rels, want] of PARSE_BATCH_ROWS) {
  test(`parseBatch: ${label}`, () => {
    const got = parseBatch(stdout, rels);
    const shown = got.blobs ? { blobs: got.blobs.map((blob) => [blob.rel, Buffer.from(blob.content).toString("utf8")]) } : got;
    assert.deepStrictEqual(shown, want);
  });
}
caseEnd();

caseBegin("check-cross-platform-limit", "hooks/check-cross-platform.js");
test("check-cross-platform: a slow staged-file listing reaches the limit -> ask naming it", () => {
  const repo = fx.makeRepo("ccp", { "install/win/setup.ps1": "Write-Output x\n" });
  const run = fx.runHook("check-cross-platform", bash("git commit -m x"),
    { env: { CLAUDE_PROJECT_DIR: repo, F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git diff" } });
  limitAsk(run, "check-cross-platform", /git diff/);
});

test("regression: a missing platform pair still blocks", () => {
  const repo = fx.makeRepo("ccpreg", { "install/win/setup.ps1": "Write-Output x\n" });
  const run = fx.runHook("check-cross-platform", bash("git commit -m x"), { env: { CLAUDE_PROJECT_DIR: repo } });
  decided(run, "block");
});
caseEnd();

caseBegin("enforce-worktree-limit", "hooks/enforce-worktree.js");
const editIn = (repo) => ({ session_id: SESSION, tool_name: "Edit",
  tool_input: { file_path: `${repo}/README.txt`, old_string: "fixture", new_string: "example" } });
// The session scope is the cwd repo plus ENFORCE_WORKTREE_ADDITIONAL_REPOS, pinned to an empty dir.
const ewOptions = (repo, env) => ({ cwd: repo, env: { ENFORCE_WORKTREE: "on", ENFORCE_WORKTREE_ADDITIONAL_REPOS: fx.tempDir("noextra"), ...env } });
test("enforce-worktree: a slow checkout probe reaches the limit -> ask naming it", () => {
  const repo = fx.makeRepo("ew");
  const run = fx.runHook("enforce-worktree", editIn(repo),
    ewOptions(repo, { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (-C \\S+ )?rev-parse" }));
  limitAsk(run, "enforce-worktree", /git (-C \S+ )?rev-parse/);
});

test("regression: an Edit in the main worktree still blocks", () => {
  const repo = fx.makeRepo("ewreg");
  const run = fx.runHook("enforce-worktree", editIn(repo), ewOptions(repo, {}));
  decided(run, "block");
  assert.match(run.reason, /main worktree/);
});
caseEnd();

caseBegin("workflow-gate-limit", "hooks/workflow-gate.js");
test("workflow-gate: a slow worktree probe reaches the limit -> ask naming it", () => {
  const linked = fx.makeLinkedWorktree(fx.makeRepo("wg"));
  // The premature USER_VERIFIED guard probes the worktree with git before anything else.
  const run = fx.runHook("workflow-gate", bash('echo "<<WORKFLOW_USER_VERIFIED: fixture>>"', linked),
    { env: { ENFORCE_WORKTREE: "on", F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (-C \\S+ )?rev-parse" } });
  limitAsk(run, "workflow-gate", /git (-C \S+ )?rev-parse/);
});

test("regression: input that is not JSON still blocks", () => {
  const run = fx.runHook("workflow-gate", "{not json", { env: { F2540_LIMIT_MS: LIMIT_MS } });
  decided(run, "block");
});
caseEnd();

caseBegin("confirm-forge-target-ownership-limit", "hooks/confirm-forge-target-ownership.js");
const ghCreate = bash("gh issue create -R example-owner/example-repo -t x -b y");
const withFakeGh = (env) => ({ env: fx.fakeGhEnv(env) });
test("confirm-forge-target-ownership: a slow gh probe reaches the limit -> ask from the limit", () => {
  const run = fx.runHook("confirm-forge-target-ownership", ghCreate,
    withFakeGh({ F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "(^|\\s)gh api" }));
  limitAsk(run, "confirm-forge-target-ownership", /gh api/);
});

test("regression: an unproven owner without the limit still asks to confirm the target", () => {
  const run = fx.runHook("confirm-forge-target-ownership", ghCreate, withFakeGh({}));
  decided(run, "ask");
  assert.ok(run.reason.startsWith("Confirm the forge target"), run.reason);
});
caseEnd();

// --- the real settings.json registration (not a fake settings, not a direct script path) -------
// Each case launches the hook by the command string settings.json registers for Bash and then
// plays Claude Code's part: the commit runs only when the decision lets the tool run.
const reg = require("./feature-2676-hook-classification/registration");
const commitInput = (repo) => bash(`git -C ${repo} commit -m "test"`);
const COMMIT_ARGV = ["commit", "-q", "-m", "test"];
// The registered command names the root variable; built from parts so no line joins it to a code dir.
const ROOT_VAR = "$" + "AGENTS_MAIN_ROOT";

caseBegin("scan-outbound-registration", "hooks/scan-outbound.js");
// The scanner reads its lists from the main worktree of its own checkout: a copy attached to the
// fixture repo makes that main worktree the fixture, so the outcome is the same on every host.
function scanOutboundRepo(label, content) {
  const repo = fx.makeRepo(label, { "notes.txt": content });
  fs.writeFileSync(path.join(repo, ".private-info-blocklist"), "forbiddenword[0-9]+\n");
  fs.writeFileSync(path.join(repo, ".private-info-allowlist"), "");
  return { repo, agentsRoot: reg.checkoutCopy(repo), warm: true };
}
test("scan-outbound registration: matcher covers Bash and the command is the deployed one", () => {
  const registration = reg.registeredCommand("scan-outbound");
  assert.strictEqual(registration.command, `node "${ROOT_VAR}/hooks/scan-outbound.js"`);
});
test("scan-outbound registration: a staged private IP is denied and the commit does not run", () => {
  const { repo, agentsRoot, warm } = scanOutboundRepo("soregdeny", "Internal gateway at 10.20.30.40 is offline.\n");
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("scan-outbound", commitInput(repo), { agentsRoot, warm });
  decided(run, "block");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before, "the protected commit was not made");
});
test("scan-outbound registration (control): clean staged text is approved and the commit runs", () => {
  const { repo, agentsRoot, warm } = scanOutboundRepo("soregclean", "Just an ordinary log line with nothing sensitive.\n");
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("scan-outbound", commitInput(repo), { agentsRoot, warm });
  decided(run, "approve");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, true);
  assert.strictEqual(reg.commitCount(repo), before + 1, "the permitted commit was made (the emulation is not vacuous)");
});
test("scan-outbound registration: at the limit -> ask in the fixed reason format, no commit", () => {
  const repo = fx.makeRepo("soreglimit", { "a.txt": "hello\n" });
  const before = reg.commitCount(repo);
  // The preload rewrites hooks/lib/decision-time-limit.js of this checkout, so the root is this checkout.
  const run = reg.runRegistered("scan-outbound", commitInput(repo),
    { env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (show|cat-file)" } });
  limitAsk(run, "scan-outbound", /git (show|cat-file)/);
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before);
});
caseEnd();

caseBegin("workflow-gate-registration", "hooks/workflow-gate.js");
// writeBegunState: workflow_init complete and every other step pending, so a commit is premature.
function writeBegunState(sessionId) {
  const { VALID_STEPS } = require("../../hooks/workflow-state.js");
  const now = new Date().toISOString();
  const steps = Object.fromEntries(VALID_STEPS.map((step) => [step, { status: "pending", updated_at: null }]));
  steps.workflow_init = { status: "complete", updated_at: now };
  const state = { version: 1, session_id: sessionId, created_at: now, steps };
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sessionId}.json`), JSON.stringify(state, null, 2));
}
const commitIn = (repo, sessionId) => ({ ...commitInput(repo), session_id: sessionId });
// These cases judge the decision, not the limit: run from a fresh checkout copy, with each git call
// going through the run-all command guard, the commit path overruns the decision time limit on Windows and asks. A limit
// near the wait cap keeps the decision reachable; the at-the-limit case below still uses LIMIT_MS.
const decisionRun = (repo) => ({ agentsRoot: reg.checkoutCopy(repo), warm: true, env: { F2540_LIMIT_MS: String(fx.WAIT_CAP_MS - 1000) } });
test("workflow-gate registration: matcher covers Bash and the command is the deployed one", () => {
  const registration = reg.registeredCommand("workflow-gate");
  assert.strictEqual(registration.command, `node "${ROOT_VAR}/hooks/workflow-gate.js"`);
});
test("workflow-gate registration: a commit in a begun, incomplete workflow is denied and does not run", () => {
  const sessionId = "00000000-0000-4000-8000-0000000025a1";
  const repo = fx.makeRepo("wgregdeny", { "app.js": "src\n" });
  writeBegunState(sessionId);
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("workflow-gate", commitIn(repo, sessionId), decisionRun(repo));
  decided(run, "block");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, false);
  assert.strictEqual(reg.commitCount(repo), before, "the protected commit was not made");
});
test("workflow-gate registration (control): no workflow state -> approved and the commit runs", () => {
  const sessionId = "00000000-0000-4000-8000-0000000025a2";
  const repo = fx.makeRepo("wgregclean", { "app.js": "src\n" });
  const before = reg.commitCount(repo);
  const run = reg.runRegistered("workflow-gate", commitIn(repo, sessionId), decisionRun(repo));
  decided(run, "approve");
  assert.strictEqual(reg.runIfPermitted(run, COMMIT_ARGV, repo).ran, true);
  assert.strictEqual(reg.commitCount(repo), before + 1, "the permitted commit was made (the emulation is not vacuous)");
});
test("workflow-gate registration: at the limit -> ask in the fixed reason format", () => {
  const linked = fx.makeLinkedWorktree(fx.makeRepo("wgreglimit"));
  const run = reg.runRegistered("workflow-gate", bash('echo "<<WORKFLOW_USER_VERIFIED: fixture>>"', linked),
    { env: { ENFORCE_WORKTREE: "on", F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "^git (-C \\S+ )?rev-parse" } });
  limitAsk(run, "workflow-gate", /git (-C \S+ )?rev-parse/);
});
caseEnd();

caseBegin("block-case-markers-limit", "hooks/block-case-markers.js");
// A new hook test lacking case markers in a repo carrying tests/lib/harness.sh (oracle.js's probe).
const newCaseWrite = (repo) => ({ session_id: SESSION, tool_name: "Write", tool_input: { file_path: `${repo}/tests/hooks/new-case.sh`,
  content: "#!/usr/bin/env bash\n# Tests: bin/a.sh, bin/b.sh\n# Tags: scope:common\necho no markers\n" } });
test("block-case-markers: a slow case-marker checker reaches the limit -> ask naming it", () => {
  const repo = fx.makeRepo("bcm", { "tests/lib/harness.sh": "#!/usr/bin/env bash\n" });
  const run = fx.runHook("block-case-markers", newCaseWrite(repo), { cwd: repo, env: { F2540_LIMIT_MS: LIMIT_MS, F2540_SLOW: "check-case-markers\\.sh" } });
  limitAsk(run, "block-case-markers", /^bash \S*check-case-markers\.sh/);
});
test("regression: a new hook test without case markers still blocks", () => {
  const repo = fx.makeRepo("bcmreg", { "tests/lib/harness.sh": "#!/usr/bin/env bash\n" });
  decided(fx.runHook("block-case-markers", newCaseWrite(repo), { cwd: repo }), "block");
});
caseEnd();
