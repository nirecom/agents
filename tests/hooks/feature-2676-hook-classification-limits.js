"use strict";
// Tests: docs/architecture/claude-code/settings/hook-timeout.md, settings.json, hooks/scan-outbound.js, hooks/workflow-gate.js, hooks/enforce-worktree.js, hooks/confirm-forge-target-ownership.js, hooks/check-cross-platform.js
// Tags: TL1, TL2, hooks, pretooluse, allow-deny-hook, non-allow-deny-hook, decision-time-limit, settings, docs, scope:issue-specific, subprocess, scan-outbound, workflow-gate, enforce-worktree, settings-registration, block-case-markers
// Serial: spawns every PreToolUse hook and real git commits; ~17 s alone (median of 5), kept serial because it spawns real git commits
// #2676 / #2540 Step 5 (split from feature-2676-hook-classification.js): each heavy hook's
// entrypoint arms the limit; run with a shrunken limit and one slowed child, it answers "ask"
// naming itself and the check, and decides as before otherwise.
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
const { loaded, armsLimit, LIMIT_MS, SESSION, bash, limitAsk, assertLimitReason, decided } = require("./feature-2676-hook-classification/common");

// heavyHookArms(hookName): the heavy hook is a "with limit" allow-deny row and its entrypoint arms.
function heavyHookArms(hookName) {
  test(`${hookName}: allow-deny hook with a limit, and its entrypoint calls armDecisionTimeLimit`, () => {
    const row = table.rowFor(loaded(), hookName);
    assert.ok(row, `${hookName} has a row`);
    assert.deepStrictEqual([row.kind, row.limit], ["allow-deny", "yes"], `${hookName}: allow-deny hook with a limit`);
    assert.ok(armsLimit(hookName), `hooks/${hookName}.js (or hooks/${hookName}/) calls armDecisionTimeLimit`);
  });
}

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
