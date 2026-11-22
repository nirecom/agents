"use strict";
// Tests: bin/worktree-write-notes.js, hooks/lib/worktree-notes.js
// Tags: feature-1610, feature-1849, worktree-notes, exclude, in-repo-base, gitignore, config-dependent, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: a live /worktree-start whose main `git status` must stay free of `?? .claude/`.
// #1610: empty argv[5] → resolver base; an in-repo base is appended once to .git/info/exclude
// (baseExcludeAdded / baseExcludeError); a failed append exits 1 unless git already ignores it.
// HOME/USERPROFILE/AGENTS_MAIN_ROOT are pinned and WORKTREE_BASE_DIR is set or deleted per case.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");

const restore = isolate();
const SB = F.makeBase("f1610wn-");
after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const CLI = F.rel("bin/worktree-write-notes.js");
const HOME = path.join(SB, "home");
const CONF = path.join(SB, "conf");
fs.mkdirSync(HOME, { recursive: true });
fs.mkdirSync(CONF, { recursive: true });
const fwd = (p) => p.replace(/\\/g, "/");
const BASE_LINE = /^\/?\.claude\/worktrees\/$/;

// base: undefined deletes WORKTREE_BASE_DIR from the child env.
function notes(main, wt, { base, argvBase = "" } = {}) {
  const env = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, AGENTS_MAIN_ROOT: CONF, COPIED_JSON: "" });
  delete env.WORKTREE_BASE_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  if (base !== undefined) env.WORKTREE_BASE_DIR = base;
  fs.mkdirSync(wt, { recursive: true });
  const r = F.runNode([CLI, fwd(main), fwd(wt), "feature/n", argvBase, ""], { cwd: main, env });
  let json = null;
  try {
    json = JSON.parse(r.out.trim().split(/\r?\n/).pop());
  } catch (_e) {
    json = null;
  }
  return Object.assign(r, { json });
}

function excludeLines(main) {
  try {
    return fs.readFileSync(path.join(main, ".git", "info", "exclude"), "utf8").split(/\r?\n/);
  } catch (_e) {
    return [];
  }
}

function baseLineCount(main) {
  return excludeLines(main).filter((l) => BASE_LINE.test(l.trim())).length;
}

function notesBaseLine(wt) {
  const body = fs.readFileSync(path.join(wt, "WORKTREE_NOTES.md"), "utf8");
  const m = /^WORKTREE_BASE_DIR: (.*)$/m.exec(body);
  return m ? m[1].trim() : null;
}

// Make <main>/.git/info/exclude unwritable on every platform: a directory in its place.
function blockExclude(main) {
  const p = path.join(main, ".git", "info", "exclude");
  fs.rmSync(p, { force: true });
  fs.mkdirSync(p, { recursive: true });
}

caseBegin("empty-argv-base-records-resolver-default", "bin/worktree-write-notes.js");
test("empty-argv-base-records-resolver-default", () => {
  const main = F.makeRepo(path.join(SB, "n1", "main"));
  const wt = path.join(SB, "n1", "wt");
  const r = notes(main, wt);
  assert.equal(r.rc, 0, `stderr: ${r.err}`);
  const recorded = notesBaseLine(wt);
  assert.ok(F.samePath(recorded, path.join(main, ".claude", "worktrees")),
    `notes must record the resolver base <main>/.claude/worktrees, got ${JSON.stringify(recorded)}`);
});
caseEnd();

caseBegin("in-repo-base-exclude-appended-once", "hooks/lib/worktree-notes.js");
test("in-repo-base-exclude-appended-once", () => {
  const main = F.makeRepo(path.join(SB, "n2", "main"));
  const first = notes(main, path.join(SB, "n2", "wt1"));
  assert.equal(first.rc, 0, `stderr: ${first.err}`);
  assert.equal(baseLineCount(main), 1, `exclude: ${JSON.stringify(excludeLines(main))}`);
  assert.ok(first.json, `stdout is JSON: ${first.out}`);
  assert.equal(first.json.baseExcludeAdded, true, `first run: ${first.out}`);
  assert.ok(!first.json.baseExcludeError, `first run: ${first.out}`);
  assert.deepEqual(first.json.errors, []);
  const second = notes(main, path.join(SB, "n2", "wt2"));
  assert.equal(second.rc, 0, `stderr: ${second.err}`);
  assert.equal(baseLineCount(main), 1, "a second run must not append the base line again");
  assert.equal(second.json.baseExcludeAdded, false, `second run: ${second.out}`);
  const st = F.git(["-C", main, "status", "--porcelain", "--untracked-files=all"]);
  fs.mkdirSync(path.join(main, ".claude", "worktrees", "t", "main"), { recursive: true });
  fs.writeFileSync(path.join(main, ".claude", "worktrees", "t", "main", "f.txt"), "x\n");
  const st2 = F.git(["-C", main, "status", "--porcelain", "--untracked-files=all"]);
  assert.equal(st2, st, `a file under the in-repo base must not show as untracked: ${st2}`);
});
caseEnd();

caseBegin("renamed-repo-real-worktree-excluded-once", "hooks/lib/worktree-notes.js");
test("renamed-repo-real-worktree-excluded-once", () => {
  const main = F.makeRepo(path.join(SB, "n6", "renamed-checkout"));
  const wt = F.addWorktree(main, path.join(main, ".claude", "worktrees", "my-task", "renamed-checkout"), "feature/n6");
  for (const run of ["first", "second"]) {
    const r = notes(main, wt);
    assert.equal(r.rc, 0, `${run} run stderr: ${r.err}`);
    assert.equal(baseLineCount(main), 1, `${run} run exclude: ${JSON.stringify(excludeLines(main))}`);
    assert.ok(r.json, `${run} run stdout is JSON: ${r.out}`);
    assert.equal(r.json.baseExcludeAdded, run === "first", `${run} run: ${r.out}`);
  }
  const st = F.git(["-C", main, "status", "--porcelain", "--untracked-files=all"]);
  assert.ok(!/\.claude/.test(st), `the in-repo worktree must not show in git status: ${st}`);
});
caseEnd();

caseBegin("explicit-in-repo-custom-base-excluded-once", "hooks/lib/worktree-notes.js");
test("explicit-in-repo-custom-base-excluded-once", () => {
  const main = F.makeRepo(path.join(SB, "n7", "main"));
  const base = path.join(main, ".wt-custom");
  const wt = F.addWorktree(main, path.join(base, "my-task", "main"), "feature/n7");
  const customLines = () => excludeLines(main).filter((l) => /^\/?\.wt-custom\/?$/.test(l.trim())).length;
  for (const run of ["first", "second"]) {
    const r = notes(main, wt, { base: fwd(base) });
    assert.equal(r.rc, 0, `${run} run stderr: ${r.err}`);
    assert.equal(customLines(), 1, `${run} run exclude: ${JSON.stringify(excludeLines(main))}`);
    assert.ok(r.json, `${run} run stdout is JSON: ${r.out}`);
    assert.equal(r.json.baseExcludeAdded, run === "first", `${run} run: ${r.out}`);
  }
  const st = F.git(["-C", main, "status", "--porcelain", "--untracked-files=all"]);
  assert.ok(!/\.wt-custom/.test(st), `the explicit in-repo base must not show in git status: ${st}`);
});
caseEnd();

caseBegin("explicit-out-of-repo-base-no-append", "hooks/lib/worktree-notes.js");
test("explicit-out-of-repo-base-no-append", () => {
  const main = F.makeRepo(path.join(SB, "n3", "main"));
  const shared = fwd(path.join(SB, "n3", "shared"));
  const viaEnv = notes(main, path.join(SB, "n3", "wt1"), { base: shared });
  assert.equal(viaEnv.rc, 0, `stderr: ${viaEnv.err}`);
  const viaArgv = notes(main, path.join(SB, "n3", "wt2"), { argvBase: shared });
  assert.equal(viaArgv.rc, 0, `stderr: ${viaArgv.err}`);
  assert.equal(baseLineCount(main), 0, `exclude: ${JSON.stringify(excludeLines(main))}`);
  assert.ok(excludeLines(main).includes("WORKTREE_NOTES.md"), "the notes exclude line is still written");
});
caseEnd();

caseBegin("append-failure-unignored-base-exits-1", "bin/worktree-write-notes.js");
test("append-failure-unignored-base-exits-1", () => {
  const main = F.makeRepo(path.join(SB, "n4", "main"));
  blockExclude(main);
  const r = notes(main, path.join(SB, "n4", "wt"));
  assert.equal(r.rc, 1, `an unignored in-repo base whose exclude append failed must stop: rc=${r.rc} out=${r.out} err=${r.err}`);
  const firstErr = r.err.split(/\r?\n/).find((l) => l.trim() !== "") || "";
  assert.match(firstErr, /exclude|ignore/i, `stderr line 1 names the reason: ${r.err}`);
});
caseEnd();

caseBegin("append-failure-ignored-base-warns-exit-0", "bin/worktree-write-notes.js");
test("append-failure-ignored-base-warns-exit-0", () => {
  const main = F.makeRepo(path.join(SB, "n5", "main"));
  fs.writeFileSync(path.join(main, ".gitignore"), ".claude/\n");
  F.git(["-C", main, "add", ".gitignore"]);
  F.git(["-C", main, "commit", "-q", "--no-verify", "-m", "ignore .claude"]);
  blockExclude(main);
  const r = notes(main, path.join(SB, "n5", "wt"));
  assert.equal(r.rc, 0, `a .gitignore-ignored base keeps exit 0: out=${r.out} err=${r.err}`);
  assert.match(r.err, /warn/i, `a warning is printed: ${r.err}`);
  assert.ok(r.json && typeof r.json.baseExcludeError === "string" && r.json.baseExcludeError !== "",
    `baseExcludeError carries the failure: ${r.out}`);
  assert.equal(r.json.notesWritten, true);
});
caseEnd();
