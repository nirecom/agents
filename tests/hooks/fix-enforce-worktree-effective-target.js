"use strict";
// Tests: hooks/enforce-worktree/effective-target.js, hooks/enforce-worktree/handle-bash-write.js, hooks/lib/parse-git-args.js
// Tags: TL2, hook, enforce, worktree, git-dir, work-tree, core-worktree, config-env, git-env, worktree-prune, worktree-remove, branch-delete, effective-target, fail-closed, security, scope:common, pwsh-not-required
// TL3 gap: no live Claude Code session drives the hook, so hook registration and the Bash child's env are not exercised.
// #3147: a git write whose target is redirected (--git-dir / --work-tree / GIT_DIR / GIT_WORK_TREE /
// -c core.worktree / --config-env) is judged by the real target. MAIN = main checkout, WT (cwd) and WT2
// (on protected master) = its linked worktrees, EXT = outside the session, ADD joins via ADDITIONAL_REPOS.
// OPS is a second fixture for worktree remove/prune and branch delete. Ids R-C1..R-C8 are the
// review_tests revision rows; the rest are the original design rows.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");
const { ewRun, expectVerdict, gitOut, makeSessionFixture } = require("../lib/ew-runner");

const restore = isolate();
const SB = F.makeBase("f3147et-");
after(() => {
  restore();
  fs.rmSync(SB, { recursive: true, force: true });
});

const { MAIN, WT, WT2, EXT, ADD, WT_GITDIR, WT2_GITDIR } = makeSessionFixture(SB, "master");
fs.mkdirSync(path.join(SB, "ops"), { recursive: true });
const OPS = makeSessionFixture(path.join(SB, "ops"), "feature/wt2");
const SBF = SB.replace(/\\/g, "/");
const EMPTY = `${SBF}/empty-dir`;
fs.mkdirSync(EMPTY, { recursive: true });
const BARE = `${SBF}/bare.git`;
gitOut(["init", "--bare", BARE], SB);
const q = (p) => `"${p}"`;
const MAIN_GIT = q(`${MAIN}/.git`);
const EXT_GIT = q(`${EXT}/.git`);
const run = (row) => ewRun(row.cwd || WT, row.cmd, row.env, MAIN);
const runOps = (row) => ewRun(row.cwd || OPS.WT, row.cmd, row.env, OPS.MAIN);
const table = (rows, runner = run) => {
  for (const row of rows) {
    test(`${row.id}: ${row.cmd}${row.env ? " " + JSON.stringify(row.env) : ""}`, () => {
      const res = runner(row);
      expectVerdict(row.id, row.want, res);
      if (row.reasonHas) assert.ok(res.reason.includes(row.reasonHas), `${row.id}: reason lacks "${row.reasonHas}": ${res.reason}`);
    });
  }
};

caseBegin("flag-redirect-to-main-checkout-blocks", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "A1", cmd: `git -C ${q(WT)} --git-dir=${MAIN_GIT} worktree move a b`, want: "block" },
  { id: "A2", cmd: `git --git-dir=${MAIN_GIT} commit -m x`, want: "block" },
  { id: "A2-separate-form", cmd: `git --git-dir ${MAIN_GIT} commit -m x`, want: "block" },
  { id: "A2-relative", cmd: "git --git-dir=../main/.git commit -m x", want: "block" },
  { id: "A3", cmd: `git -C ${q(WT)} --git-dir=${MAIN_GIT} --work-tree=${q(WT)} reset --hard`, want: "block" },
  { id: "A3-work-tree-only", cmd: `git --work-tree=${q(MAIN)} add .`, want: "block" },
  { id: "A9", cmd: `git -C ${q(WT)} --git-dir=${q(`${ADD}/.git`)} commit -m x`, env: { ENFORCE_WORKTREE_ADDITIONAL_REPOS: ADD }, want: "block" },
  { id: "A11", cmd: `git --git-dir=${q(WT2_GITDIR)} --work-tree=${q(WT2)} commit -m x`, want: "block" },
  { id: "R-C4-git-dir-other-linked-protected", cmd: `git --git-dir=${q(WT2_GITDIR)} --work-tree=${q(WT)} commit -m x`, want: "block", reasonHas: "protected branch" },
  { id: "A13", cwd: MAIN, cmd: `git --git-dir=${EXT_GIT} config --file ${q(`${MAIN}/.git/config`)} user.name x`, want: "block" },
]);
caseEnd();

// C2: the work-tree axis checks path containment, not only equality with MAIN. SB is not a git repo
// and encloses MAIN and WT; EMPTY is a repo-less directory that encloses no anchor.
caseBegin("work-tree-containment-check", "hooks/enforce-worktree/effective-target.js");
table([
  { id: "R-C2a-worktree-encloses-anchor", cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(SBF)} add .`, want: "block" },
  { id: "R-C2b-worktree-empty-dir-allowed", cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(EMPTY)} add .`, want: "allow" },
]);
caseEnd();

// Observed before the fix: A4 / A5 / A5b / A7b allow (RED). Both A8 rows already block (the hook's own
// git spawn inherits GIT_DIR / GIT_WORK_TREE and sees MAIN). C8: A8-GIT_DIR also pins the inherited line.
caseBegin("inherited-env-and-command-tokens-block", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "A4", cmd: `GIT_DIR=${MAIN_GIT} git commit -m x`, want: "block" },
  { id: "A5", cmd: `GIT_WORK_TREE=${q(MAIN)} git -C ${q(WT)} add .`, want: "block" },
  { id: "A5b", cmd: `env GIT_DIR=${MAIN_GIT} git commit -m x`, want: "block" },
  { id: "A7b", cmd: `EWT_T=${q(MAIN)} git --config-env=core.worktree=EWT_T commit -m x`, want: "block" },
  { id: "A8-GIT_DIR", cmd: "git commit -m x", env: { GIT_DIR: `${MAIN}/.git` }, want: "block", reasonHas: "inherited from the session environment" },
  { id: "A8-GIT_WORK_TREE", cmd: "git commit -m x", env: { GIT_WORK_TREE: MAIN }, want: "block", reasonHas: "inherited from the session environment" },
]);
caseEnd();

// C3: a token or flag in the command wins over the inherited variable.
caseBegin("command-token-beats-inherited-env", "hooks/enforce-worktree/effective-target.js");
table([
  { id: "R-C3a-token-main-beats-inherited-wt", cmd: `EWT_T=${q(MAIN)} git --config-env=core.worktree=EWT_T commit -m x`, env: { EWT_T: WT }, want: "block" },
  { id: "R-C3b-flag-wt-beats-inherited-git-dir", cmd: `git --git-dir=${q(WT_GITDIR)} --work-tree=${q(WT)} commit -m x`, env: { GIT_DIR: `${MAIN}/.git` }, want: "allow" },
]);
caseEnd();

caseBegin("core-worktree-config-blocks", "hooks/lib/parse-git-args.js");
table([
  { id: "A6", cmd: `git -c core.worktree=${q(MAIN)} commit -m x`, want: "block" },
  { id: "A6-key-case", cmd: `git -c Core.WorkTree=${q(MAIN)} commit -m x`, want: "block" },
  { id: "A7", cmd: "git --config-env=core.worktree=EWT_T commit -m x", env: { EWT_T: MAIN }, want: "block" },
  { id: "A12", cmd: `git --config-env=core.worktree=EWT_T -c core.worktree=${q(MAIN)} commit -m x`, env: { EWT_T: WT }, want: "block" },
  { id: "C9", cmd: `git -c core.worktree=${q(MAIN)} --config-env=core.worktree=EWT_T commit -m x`, env: { EWT_T: WT }, want: "allow" },
]);
caseEnd();

// C1: the verdict of a multi-segment command is the strictest segment, whatever the order.
caseBegin("multi-segment-redirect-blocks", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "A10", cmd: `git -C ${q(WT)} status && git --git-dir=${MAIN_GIT} commit -m x`, want: "block" },
  { id: "A16", cmd: `cd ${q(EXT)} && git --git-dir=${MAIN_GIT} commit -m x`, want: "block" },
  { id: "S1-cd-relative-git-dir", cmd: `cd ${q(MAIN)} && git --git-dir=.git --work-tree=. commit -m x`, want: "block" },
  { id: "S2-env-chdir-relative", cmd: `env -C ${q(MAIN)} git --git-dir=.git --work-tree=. commit -m x`, want: "block" },
  { id: "S3-git-config-env-count", cmd: `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0=${q(MAIN)} git --git-dir=${EXT_GIT} commit -m x`, want: "block" },
  { id: "S4-command-cd-relative", cmd: `command cd ${q(MAIN)} && git --git-dir=.git --work-tree=. commit -m x`, want: "block" },
  { id: "S5-builtin-export-git-dir", cmd: `builtin export GIT_DIR=${MAIN_GIT}; git commit -m x`, want: "block" },
  { id: "S6-git-config-env-alone", cmd: `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0=${q(MAIN)} git commit -m x`, want: "block" },
  { id: "R-C1a-ext-then-main", cmd: `git --git-dir=${EXT_GIT} commit -m x && git --git-dir=${MAIN_GIT} commit -m x`, want: "block" },
  { id: "R-C1a-main-then-ext", cmd: `git --git-dir=${MAIN_GIT} commit -m x && git --git-dir=${EXT_GIT} commit -m x`, want: "block" },
  { id: "R-C1b-ext-then-unresolvable", cmd: `git --git-dir=${EXT_GIT} commit -m x && git --git-dir='$X' commit -m x`, want: "block" },
  { id: "R-C1c-unresolvable-then-ext", cmd: `git --git-dir='$X' commit -m x && git --git-dir=${EXT_GIT} commit -m x`, want: "block" },
]);
caseEnd();

// The override variant may never be judged more permissively than the same command without it
// (same cwd, same env). These rows do not claim the trailing write itself is blocked.
const notLooser = (label, baseCmd, overCmd, baselineWant, cwd) => test(label, () => {
  const base = run({ cmd: baseCmd, cwd });
  const over = run({ cmd: overCmd, cwd });
  assert.equal(base.verdict, baselineWant, `${label}: baseline verdict (no override) is ${baselineWant}: raw=${base.raw}`);
  if (base.verdict === "block") expectVerdict(`${label} override`, "block", over);
  else assert.ok(["allow", "block"].includes(over.verdict), `${label}: override verdict: ${over.verdict}`);
});

caseBegin("override-never-looser-than-baseline", "hooks/enforce-worktree/handle-bash-write.js");
// A14 / A15: baseline is allow; the trailing write to MAIN is the existing gap the plan leaves unchanged.
notLooser("A14 (baseline allow)", `git commit -m x && rm ${q(`${MAIN}/README.md`)}`,
  `git --git-dir=${EXT_GIT} commit -m x && rm ${q(`${MAIN}/README.md`)}`, "allow");
notLooser("A15 (baseline allow)", `git commit -m x && unknowncmd ${q(`${MAIN}/README.md`)}`,
  `git --git-dir=${EXT_GIT} commit -m x && unknowncmd ${q(`${MAIN}/README.md`)}`, "allow");
// C4: a write redirect disables the early allow. From cwd=MAIN the baseline `git commit > MAIN/out.txt`
// blocks (from WT it already allows), so the EXT-redirected variant (allowed alone, see C7b) must block too.
notLooser("R-C4 (baseline block: redirect into MAIN, cwd=MAIN)", `git commit -m x > ${q(`${MAIN}/out.txt`)}`,
  `git --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m x > ${q(`${MAIN}/out.txt`)}`, "block", MAIN);
test("A13b: config --file with --git-dir to EXT matches the verdict without it", () => {
  const tail = `config --file ${q(`${MAIN}/.git/config`)} user.name x`;
  const base = run({ cmd: `git ${tail}` });
  const over = run({ cmd: `git --git-dir=${EXT_GIT} ${tail}` });
  assert.equal(base.verdict, "allow", `A13b baseline verdict (pinned): raw=${base.raw}`);
  assert.equal(over.verdict, base.verdict, `A13b: override ${over.verdict} vs baseline ${base.verdict}`);
});
caseEnd();

// Observed before the fix: B1 / B3 / B4 / B5 allow (RED). B2 already blocks ("cannot determine repo root").
caseBegin("unresolvable-target-fails-closed", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "B1", cmd: "git --git-dir='$X' commit -m x", want: "block" },
  { id: "B2", cmd: "git --git-dir=/no/such commit -m x", want: "block" },
  { id: "B3", cmd: "git --config-env=core.worktree=UNSET_VAR commit -m x", want: "block" },
  { id: "B4", cmd: "git --git-dir=~nouser/.git commit -m x", want: "block" },
  { id: "B5", cmd: `export GIT_DIR=${MAIN_GIT} && git commit -m x`, want: "block" },
]);
caseEnd();

// C5: the remaining fail-closed branches of the input collection.
caseBegin("unresolvable-branches-fail-closed", "hooks/enforce-worktree/effective-target.js");
table([
  { id: "R-C5a-env-u", cmd: "env -u GIT_DIR git commit -m x", env: { GIT_DIR: `${EXT}/.git` }, want: "block" },
  { id: "R-C5b-empty-inherited", cmd: "git commit -m x", env: { GIT_DIR: "" }, want: "block" },
  { id: "R-C5c-bare-assignment", cmd: `GIT_DIR=${MAIN_GIT}; git commit -m x`, want: "block" },
  { id: "R-C5c-unset", cmd: `unset GIT_WORK_TREE && git --git-dir=${EXT_GIT} commit -m x`, want: "block" },
  { id: "R-C5d-parse-failure", cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m "x`, want: "block" },
  { id: "R-C5f-cwd-not-a-repo", cwd: EMPTY, cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m x`, want: "block" },
  { id: "R-C5e-bare-repo", cmd: `git --git-dir=${q(BARE)} commit -m x`, want: "block" },
]);
caseEnd();

// Observed before the fix: C3 / C4 block as "main worktree" of EXT (RED; they turn to allow); C7b allow.
caseBegin("sanctioned-targets-stay-allowed", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "C1", cmd: "git commit -m x", want: "allow" },
  { id: "C2", cmd: `git -C ${q(EXT)} commit -m x`, want: "allow" },
  { id: "C3", cmd: `git -C ${q(EXT)} -c core.worktree=${q(EXT)} commit -m x`, want: "allow" },
  { id: "C4", cmd: `git -C ${q(EXT)} --config-env=core.worktree=EWT_T commit -m x`, env: { EWT_T: EXT }, want: "allow" },
  { id: "C7", cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m x`, want: "allow" },
  { id: "C7b", cwd: MAIN, cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m x`, want: "allow" },
  { id: "C8", cmd: `git --git-dir=${q(WT_GITDIR)} --work-tree=${q(WT)} commit -m x`, want: "allow" },
  { id: "C10-read-only", cmd: `git --git-dir=${MAIN_GIT} log -1`, want: "allow" },
]);
caseEnd();

// Review gap rows (C1 env allow, C2 unresolvable per input form, C3 multi-segment linked, C5 sibling symmetry).
caseBegin("review-gap-rows", "hooks/enforce-worktree/effective-target.js");
table([
  { id: "G-C1-env-ext-allow", cmd: "git commit -m x", env: { GIT_DIR: `${EXT}/.git`, GIT_WORK_TREE: EXT }, want: "allow" },
  { id: "G-C2-inline-git-dir", cmd: "GIT_DIR='$X' git commit -m x", want: "block" },
  { id: "G-C2-core-worktree", cmd: "git -c core.worktree='$X' commit -m x", want: "block" },
  { id: "G-C2-work-tree-flag", cmd: "git --work-tree='$X' commit -m x", want: "block" },
  { id: "G-C3-multi-segment-linked", cmd: `git --git-dir=${q(WT_GITDIR)} --work-tree=${q(WT)} commit -m x && git --git-dir=${q(WT2_GITDIR)} --work-tree=${q(WT2)} commit -m x`, want: "block" },
  { id: "G-R1-C-moves-origin", cmd: `git -C ${q(MAIN)} --git-dir=.git --work-tree=. commit -m x`, want: "block" },
  { id: "G-R2-work-tree-inside-main", cmd: `git --git-dir=${EXT_GIT} --work-tree=${q(`${MAIN}/sub`)} add .`, want: "block" },
  { id: "G-R3-hooks-bypass-external", cmd: `git -c core.hooksPath=/dev/null --git-dir=${EXT_GIT} --work-tree=${q(EXT)} commit -m x`, want: "block" },
  { id: "G-C5-empty-work-tree", cmd: "git commit -m x", env: { GIT_WORK_TREE: "" }, want: "block" },
  { id: "G-C5-flag-beats-inherited-work-tree", cmd: `git --git-dir=${q(WT_GITDIR)} --work-tree=${q(WT)} commit -m x`, env: { GIT_WORK_TREE: MAIN }, want: "allow" },
  { id: "G-C5-config-env-key-case", cmd: "git --config-env=Core.WorkTree=EWT_T commit -m x", env: { EWT_T: MAIN }, want: "block" },
]);
caseEnd();

caseBegin("exit-switch-and-repeat", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "X1", cmd: `git -C ${q(WT)} --git-dir=${MAIN_GIT} worktree move a b`, env: { ENFORCE_WORKTREE: "off" }, want: "allow" },
]);
test("IDEM: judging A2 twice gives one verdict and leaves both checkouts untouched", () => {
  const heads = () => [gitOut(["rev-parse", "HEAD"], MAIN), gitOut(["rev-parse", "HEAD"], WT), gitOut(["status", "--porcelain"], MAIN)];
  const before = heads();
  const cmd = `git --git-dir=${MAIN_GIT} commit -m x`;
  const first = run({ cmd });
  const second = run({ cmd });
  assert.equal(second.verdict, first.verdict, "same verdict on a repeat");
  expectVerdict("IDEM repeat", "block", second);
  assert.deepEqual(heads(), before, "the hook judges only; no checkout changes");
});
caseEnd();

// ---- worktree remove/prune and branch delete (OPS fixture) ----
const OM = OPS.MAIN;
const OW = OPS.WT;
const OW2 = OPS.WT2;
const OE = OPS.EXT;

caseBegin("worktree-maintenance-sanctioned-allows", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "D1", cwd: OM, cmd: "git worktree prune", want: "allow" },
  { id: "D1b", cmd: `git -C ${q(OM)} worktree remove ${q(OW2)}`, want: "allow" },
  { id: "D4", cwd: OM, cmd: "git worktree prune", env: { GIT_DIR: `${OM}/.git` }, want: "allow" },
  // C7b: from the linked cwd, an inherited GIT_DIR naming the main checkout itself is a no-op for prune.
  { id: "R-C7b-prune-inherited-main", cmd: `git -C ${q(OM)} worktree prune`, env: { GIT_DIR: `${OM}/.git` }, want: "allow" },
], runOps);
caseEnd();

// Observed before the fix: D2 / D3 allow (RED): the prune exception is granted by the command shape
// before the inherited redirect is considered. D5 blocks but its reason lacks ENFORCE_WORKTREE=off.
caseBegin("worktree-maintenance-redirected-blocks", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "D2", cmd: `git -C ${q(OM)} worktree prune`, env: { GIT_DIR: `${OE}/.git` }, want: "block" },
  { id: "D3", cwd: OM, cmd: "git worktree prune", env: { GIT_DIR: `${OE}/.git` }, want: "block" },
  { id: "D5", cmd: `git -C ${q(OM)} worktree prune`, env: { GIT_WORK_TREE: OE }, want: "block" },
  // C7a: the remove arm is symmetric with the prune arm.
  { id: "R-C7a-remove-inherited-ext", cmd: `git -C ${q(OM)} worktree remove ${q(OW2)}`, env: { GIT_DIR: `${OE}/.git` }, want: "block" },
], runOps);
caseEnd();

// Observed before the fix: E1 / E2 allow (RED). E5 and E6 already block through the existing branch
// -d/-D gate; E4 (the same -d without `&& rm`) allows, so E5 pins only that the chain is not looser.
caseBegin("branch-delete-by-effective-target", "hooks/enforce-worktree/handle-bash-write.js");
table([
  { id: "E1", cmd: `git -C ${q(OW)} --git-dir=${q(`${OM}/.git`)} branch -d feat`, want: "block" },
  { id: "E2", cmd: "git --git-dir='$X' branch -d feat", want: "block" },
  { id: "E3", cmd: "git branch -d feat", want: "allow" },
  { id: "E4", cmd: `git --git-dir=${q(`${OE}/.git`)} branch -d feat`, want: "allow" },
  { id: "E5", cmd: `git --git-dir=${q(`${OE}/.git`)} branch -d feat && rm ${q(`${OM}/README.md`)}`, want: "block" },
  { id: "E6", cmd: `git --git-dir=${q(`${OE}/.git`)} branch -D feat`, want: "block" },
  // C6a: an inherited GIT_DIR naming MAIN moves the branch delete to the main checkout.
  { id: "R-C6a-inherited-git-dir", cmd: "git branch -d feat", env: { GIT_DIR: `${OM}/.git` }, want: "block" },
  // C6b: the linked arm of the effective target allows the delete.
  { id: "R-C6b-linked-arm", cmd: `git --git-dir=${q(OPS.WT2_GITDIR)} --work-tree=${q(OW2)} branch -d feat`, want: "allow" },
], runOps);
caseEnd();
