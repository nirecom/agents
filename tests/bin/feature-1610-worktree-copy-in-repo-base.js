"use strict";
// Tests: hooks/lib/worktree-copy.js, bin/worker-dispatch/workers/worktree-copy.js
// Tags: feature-1610, feature-1849, feature-3138, worktree-copy, worker-dispatch, in-repo-base, letter-case, config-dependent, scope:issue-specific, TL2, pwsh-not-required
// TL3 gap: a real /worktree-start that copies from a main repo holding live nested worktrees.
// #1610: the copy never takes entries under the in-repo base (.claude/worktrees, or an explicit
// in-repo base such as <repo>/wt-alt), and the worker fails when the notes CLI exits 1.
// HOME/USERPROFILE/AGENTS_MAIN_ROOT are pinned and WORKTREE_BASE_DIR is set or deleted per case.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");

const restore = isolate();
const SB = F.makeBase("f1610wc-");
after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const COPY_LIB = F.rel("hooks/lib/worktree-copy.js");
const DISPATCH = F.rel("bin/worker-dispatch.js");
const HOME = path.join(SB, "home");
const CONF = path.join(SB, "conf");
const PLANS = path.join(SB, "plans");
const WF = path.join(SB, "wf");
for (const d of [HOME, CONF, PLANS, WF]) fs.mkdirSync(d, { recursive: true });
const fwd = (p) => p.replace(/\\/g, "/");

function childEnv(base) {
  const env = Object.assign({}, process.env, {
    HOME, USERPROFILE: HOME, AGENTS_MAIN_ROOT: CONF, WORKFLOW_PLANS_DIR: fwd(PLANS), WORKFLOW_STATE_DIR: fwd(WF),
  });
  delete env.WORKTREE_BASE_DIR;
  delete env.CLAUDE_CODE_SESSION_ID;
  if (base !== undefined) env.WORKTREE_BASE_DIR = base;
  return env;
}

function put(root, rel, body = "SECRET=1\n") {
  const p = path.join(root, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body);
}

// A main repo whose .env files are gitignored and named by .worktreeinclude at any depth.
function copyFixture(name, extraIgnore = "") {
  const main = F.makeRepo(path.join(SB, name, "main"));
  fs.writeFileSync(path.join(main, ".gitignore"), `.env\n.claude/\n${extraIgnore}`);
  F.git(["-C", main, "add", ".gitignore"]);
  F.git(["-C", main, "commit", "-q", "--no-verify", "-m", "ignore"]);
  fs.writeFileSync(path.join(main, ".worktreeinclude"), ".env\n");
  put(main, ".env");
  return main;
}

const COPY_SRC = [
  "const m = require(process.argv[1]);",
  "process.stdout.write(JSON.stringify(m.copyInclude({ targetMainRoot: process.argv[2], worktreePath: process.argv[3] })));",
].join("\n");

function copy(main, wt, base) {
  fs.mkdirSync(wt, { recursive: true });
  const r = F.runNode(["-e", COPY_SRC, COPY_LIB, fwd(main), fwd(wt)], { cwd: main, env: childEnv(base) });
  assert.equal(r.rc, 0, `stderr: ${r.err}`);
  const res = JSON.parse(r.out);
  return res.copied.map(fwd);
}

function dispatch(main, wt, branch, base) {
  const payload = path.join(PLANS, `wc-${path.basename(path.dirname(main))}.json`);
  fs.writeFileSync(payload, JSON.stringify({ worktree_path: fwd(wt), branch, artifact_dir: fwd(PLANS) }));
  const r = F.runNode([DISPATCH, "worktree-copy", fwd(main), fwd(payload)], { cwd: main, env: childEnv(base), timeout: 120000 });
  const status = (/^status: (\S+)/m.exec(r.out) || [])[1] || null;
  const summary = (/^summary: (.*)$/m.exec(r.out) || [])[1] || "";
  return Object.assign(r, { status, summary });
}

caseBegin("default-in-repo-base-entries-not-copied", "hooks/lib/worktree-copy.js");
test("default-in-repo-base-entries-not-copied", () => {
  const main = copyFixture("c1");
  put(main, ".claude/worktrees/t/main/.env");
  const copied = copy(main, path.join(SB, "c1", "wt"));
  assert.ok(copied.includes(".env"), `the root .env is still copied: ${JSON.stringify(copied)}`);
  const leaked = copied.filter((c) => c.startsWith(".claude/worktrees"));
  assert.deepEqual(leaked, [], "nothing under .claude/worktrees may be copied");
  assert.equal(fs.existsSync(path.join(SB, "c1", "wt", ".claude", "worktrees")), false);
});
caseEnd();

caseBegin("sibling-of-in-repo-base-still-copied", "hooks/lib/worktree-copy.js");
test("sibling-of-in-repo-base-still-copied", () => {
  const main = copyFixture("c2");
  put(main, ".claude/worktrees-x/.env");
  put(main, ".claude/settings/.env");
  const copied = copy(main, path.join(SB, "c2", "wt"));
  for (const want of [".claude/worktrees-x/.env", ".claude/settings/.env"]) {
    assert.ok(copied.includes(want), `${want} is not the base and stays copyable: ${JSON.stringify(copied)}`);
  }
});
caseEnd();

caseBegin("explicit-in-repo-absolute-base-not-copied", "hooks/lib/worktree-copy.js");
test("explicit-in-repo-absolute-base-not-copied", () => {
  const main = copyFixture("c3", "wt-alt/\n");
  put(main, "wt-alt/t/main/.env");
  const copied = copy(main, path.join(SB, "c3", "wt"), fwd(path.join(main, "wt-alt")));
  assert.ok(copied.includes(".env"), `the root .env is still copied: ${JSON.stringify(copied)}`);
  assert.deepEqual(copied.filter((c) => c.startsWith("wt-alt")), [], "nothing under the explicit in-repo base may be copied");
});
caseEnd();

caseBegin("worker-fails-when-notes-cli-exits-1", "bin/worker-dispatch/workers/worktree-copy.js");
test("worker-fails-when-notes-cli-exits-1", () => {
  const main = F.makeRepo(path.join(SB, "w1", "main"));
  const wt = F.addWorktree(main, path.join(SB, "w1", "linked"), "feature/w1");
  const ex = path.join(main, ".git", "info", "exclude");
  fs.rmSync(ex, { force: true });
  fs.mkdirSync(ex, { recursive: true });
  const r = dispatch(main, wt, "feature/w1", fwd(path.join(main, ".claude", "worktrees")));
  assert.equal(r.status, "failed", `an unignored in-repo base whose exclude cannot be written must fail the worker: out=${r.out} err=${r.err}`);
  assert.match(r.summary, /WORKTREE_NOTES\.md write failed/);
});
caseEnd();

caseBegin("worker-records-explicit-shared-base", "bin/worker-dispatch/workers/worktree-copy.js");
test("worker-records-explicit-shared-base", () => {
  const main = F.makeRepo(path.join(SB, "w2", "main"));
  const wt = F.addWorktree(main, path.join(SB, "w2", "linked"), "feature/w2");
  const shared = fwd(path.join(SB, "w2", "shared"));
  const r = dispatch(main, wt, "feature/w2", shared);
  assert.ok(r.status === "complete" || r.status === "partial", `out=${r.out} err=${r.err}`);
  const body = fs.readFileSync(path.join(wt, "WORKTREE_NOTES.md"), "utf8");
  const m = /^WORKTREE_BASE_DIR: (.*)$/m.exec(body);
  assert.ok(m && F.samePath(m[1].trim(), shared), `notes record the passed-through base: ${m && m[1]}`);
  const ex = fs.readFileSync(path.join(main, ".git", "info", "exclude"), "utf8");
  assert.doesNotMatch(ex, /^\/?\.claude\/worktrees\/$/m, "an out-of-repo base adds no exclude line");
});
caseEnd();

// #3138: the exclude-root compare folds letter case when told to (fold defaults to foldsCase()).
// fold is passed explicitly, so both branches run on every platform without touching the FS.
const underAnyRoot = () => F.need("hooks/lib/worktree-copy.js", "underAnyRoot");
const ROOTS = [".claude/worktrees", "wt-alt"];

caseBegin("under-any-root-folds-letter-case-when-told", "hooks/lib/worktree-copy.js");
test("under-any-root-folds-letter-case-when-told", () => {
  const under = underAnyRoot();
  for (const rel of [".Claude/Worktrees/t/main/.env", ".CLAUDE/WORKTREES", "WT-Alt/x/.env", ".claude/worktrees/t/.env"]) {
    assert.equal(under(rel, ROOTS, true), true, `fold: ${rel} is under a root`);
  }
  assert.equal(under(".claude/worktrees/x", [".Claude/Worktrees"], true), true, "the root side folds as well");
  for (const rel of [".Claude/Worktrees-x/.env", ".claude/settings/.env", "wt-alternative/.env", ".env"]) {
    assert.equal(under(rel, ROOTS, true), false, `fold: ${rel} is not under a root (segment-aware)`);
  }
});
caseEnd();

caseBegin("under-any-root-is-exact-without-fold", "hooks/lib/worktree-copy.js");
test("under-any-root-is-exact-without-fold", () => {
  const under = underAnyRoot();
  for (const rel of [".claude/worktrees/t/main/.env", ".claude/worktrees", "wt-alt/x/.env"]) {
    assert.equal(under(rel, ROOTS, false), true, `exact: ${rel} is under a root`);
  }
  for (const rel of [".Claude/Worktrees/t/main/.env", "WT-Alt/x/.env", ".claude/worktrees-x/.env"]) {
    assert.equal(under(rel, ROOTS, false), false, `exact: ${rel} is a different directory`);
  }
  const fold = process.platform === "win32" || process.platform === "darwin";
  assert.equal(under(".Claude/Worktrees/t/.env", ROOTS), fold, "default follows the platform rule");
});
caseEnd();
