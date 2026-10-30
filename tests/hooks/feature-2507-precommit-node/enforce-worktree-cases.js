"use strict";
// enforce-worktree part of tests/hooks/feature-2507-precommit-node.js (#2507). The expected
// wording is the current hooks/pre-commit text. The session marker modules and the exclude-check
// module are stubbed in a temp cfgDir (resolved from context.cfgDir, as the bash hook does).
const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const MAIN_WT = [
  "ENFORCE_WORKTREE: commits from main worktree are blocked.",
  "Work from a linked worktree. Run: /worktree-start",
  "Or set ENFORCE_WORKTREE=off in agents config to allow direct main work.",
];
const protectedLines = (b) => [
  `ENFORCE_WORKTREE: commits to protected branch '${b}' are blocked.`,
  "Switch to a feature branch. Run: git switch -c feature/<name>",
  "Or set ENFORCE_WORKTREE=off in agents config to disable.",
];

// cfg(F, { excludeRc, sid, markerOff, resolveThrows }) — a cfgDir holding the three stub modules.
function cfg(F, { excludeRc = 2, sid = null, markerOff = false, resolveThrows = false } = {}) {
  const dir = F.tmp("ew-cfg");
  F.write(dir, "hooks/lib/precommit-exclude-check.js", `"use strict";\nmodule.exports = { run: () => ${excludeRc} };\nif (require.main === module) process.exit(${excludeRc});\n`);
  const resolve = resolveThrows ? "() => { throw new Error(\"fixture\"); }" : `() => ${JSON.stringify(sid)}`;
  F.write(dir, "hooks/workflow-state.js", `"use strict";\nmodule.exports = { resolveSessionId: ${resolve} };\n`);
  F.write(dir, "hooks/lib/session-markers.js", `"use strict";\nmodule.exports = { isWorkflowOff: () => ${markerOff}, isWorktreeOff: () => false };\n`);
  return dir;
}

const BASE = { ENFORCE_WORKTREE: "on", CLAUDECODE: "1", DEFAULT_BRANCHES: undefined, ENFORCE_WORKTREE_EXCLUDE: undefined, ENFORCE_WORKTREE_EXCLUDE_REPOS: undefined };

function mainRepo(F) {
  const dir = F.repo("ew-main");
  F.write(dir, "app.txt", "x\n");
  F.stage(dir, "app.txt");
  return dir;
}

function linked(F, main, branch, { create = true } = {}) {
  const wt = path.join(F.tmp("ew-linked"), "wt");
  F.git(main, create ? ["worktree", "add", "-q", "-b", branch, wt] : ["worktree", "add", "-q", wt, branch]);
  F.write(wt, "app.txt", "y\n");
  F.stage(wt, "app.txt");
  return wt;
}

function assertBlocked(F, result, lines) {
  assert.strictEqual(result.verdict, "block", F.texts(result));
  for (const line of lines) {
    const m = F.messageOf(result, line);
    assert.ok(m, `missing line: ${line}\n${F.texts(result)}`);
    assert.strictEqual(m.stream, "stderr", line);
  }
}

function enforceWorktree(F) {
  const run = (repoTop, over = {}, opts = {}) => F.runCheck("enforce-worktree", { repoTop, cfgDir: opts.cfgDir || cfg(F), env: F.envWith({ ...BASE, ...over }), isTTY: !!opts.isTTY });
  test("off spellings (case-insensitive) disable the gate; anything else, unset or empty keeps it on", async () => {
    const dir = mainRepo(F);
    for (const v of ["off", "OFF", "0", "false", "No", "disabled"]) assert.strictEqual((await run(dir, { ENFORCE_WORKTREE: v })).verdict, "pass", v);
    for (const v of ["on", "", "yes", undefined]) assertBlocked(F, await run(dir, { ENFORCE_WORKTREE: v }), MAIN_WT);
  });
  test("protected branch candidates: DEFAULT_BRANCHES list wins; else origin/HEAD, main, master, init.defaultBranch", async () => {
    const main = mainRepo(F);
    assert.strictEqual((await run(linked(F, main, "feature/ok"))).verdict, "pass");
    assertBlocked(F, await run(linked(F, main, "release"), { DEFAULT_BRANCHES: "dev,release" }), protectedLines("release"));
    F.git(main, ["branch", "master"]);
    const onMaster = linked(F, main, "master", { create: false });
    assertBlocked(F, await run(onMaster), protectedLines("master"));
    assert.strictEqual((await run(onMaster, { DEFAULT_BRANCHES: "dev" })).verdict, "pass", "DEFAULT_BRANCHES replaces the derived list");
    F.git(main, ["update-ref", "refs/remotes/origin/develop", "HEAD"]);
    F.git(main, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"]);
    assertBlocked(F, await run(linked(F, main, "develop")), protectedLines("develop"));
    F.git(main, ["config", "init.defaultBranch", "trunk"]);
    assertBlocked(F, await run(linked(F, main, "trunk")), protectedLines("trunk"));
  });
  test("exclude-check rc 0 exempts; rc 2 is silent; another rc warns and falls back to the gate", async () => {
    const dir = mainRepo(F);
    assert.strictEqual((await run(dir, {}, { cfgDir: cfg(F, { excludeRc: 0 }) })).verdict, "pass");
    const quiet = await run(dir, {}, { cfgDir: cfg(F, { excludeRc: 2 }) });
    assert.doesNotMatch(F.texts(quiet), /exclude-check failed/);
    const r = await run(dir, {}, { cfgDir: cfg(F, { excludeRc: 5 }) });
    assertBlocked(F, r, ["pre-commit: exclude-check failed (rc=5); falling back to enforce-worktree gate.", ...MAIN_WT]);
  });
  test("session marker: off marker exempts; a probe error warns with rc=3 and falls back to the gate", async () => {
    const dir = mainRepo(F);
    assert.strictEqual((await run(dir, {}, { cfgDir: cfg(F, { sid: "fixture-sid", markerOff: true }) })).verdict, "pass");
    assertBlocked(F, await run(dir, {}, { cfgDir: cfg(F, { sid: "fixture-sid", markerOff: false }) }), MAIN_WT);
    const r = await run(dir, {}, { cfgDir: cfg(F, { resolveThrows: true }) });
    assertBlocked(F, r, ["pre-commit: session-marker bypass check failed (rc=3); falling back to enforce-worktree gate.", ...MAIN_WT]);
  });
  test("a TTY with an empty CLAUDECODE exempts; a TTY under Claude Code does not", async () => {
    const dir = mainRepo(F);
    assert.strictEqual((await run(dir, { CLAUDECODE: "" }, { isTTY: true })).verdict, "pass");
    assert.strictEqual((await run(dir, { CLAUDECODE: undefined }, { isTTY: true })).verdict, "pass");
    assertBlocked(F, await run(dir, { CLAUDECODE: "1" }, { isTTY: true }), MAIN_WT);
    assertBlocked(F, await run(dir, { CLAUDECODE: "" }, { isTTY: false }), MAIN_WT);
  });
}

module.exports = { enforceWorktree };
