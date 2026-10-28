#!/usr/bin/env node
// tests/hooks/feature-2631-merge-head-baseline.js
// Tests: hooks/workflow-state/merge-base-baseline.js, bin/workflow/record-merge-base-baseline
// Tags: scope:issue-specific, merge-base, baseline, merge-in-progress, workflow-state, TL2
"use strict";
// #2631: during an uncommitted `git merge`, the user approves MERGE_HEAD as the session's merge-base
// baseline. While the gitdir's MERGE_HEAD file exists, a base is accepted when it is an ancestor of
// HEAD OR of any valid commit listed there; outside a merge, the HEAD-only rule is unchanged.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const RECORD_CLI = path.join(ROOT, "bin", "workflow", "record-merge-base-baseline");
const MBB = require(path.join(ROOT, "hooks", "workflow-state", "merge-base-baseline.js"));
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const WORK = path.dirname(STATE_DIR);

let failures = 0;
function check(desc, ok, detail) {
  if (ok) {
    console.log(`PASS: ${desc}`);
  } else {
    failures++;
    console.log(`FAIL: ${desc} -- ${detail}`);
  }
}

function git(repo, args, allowFail) {
  const r = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8", timeout: 20000 });
  if (!allowFail && (r.error || r.status !== 0)) {
    throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  }
  return String(r.stdout || "").trim();
}

function commit(repo, file, text, msg) {
  fs.writeFileSync(path.join(repo, file), text + "\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", msg]);
  return git(repo, ["rev-parse", "HEAD"]);
}

let repoSeq = 0;
// work and other both edit shared.txt from c0, so merging other into work stops on a conflict
// with MERGE_HEAD = otherTip; otherMid is an ancestor of MERGE_HEAD but not of HEAD; thirdTip is
// on neither side.
function fixture() {
  const repo = path.join(WORK, `repo-${++repoSeq}`);
  fs.mkdirSync(repo);
  gitInit(repo);
  for (const [k, v] of [["user.email", "test@example.com"], ["user.name", "test"], ["commit.gpgsign", "false"]]) {
    git(repo, ["config", k, v]);
  }
  git(repo, ["checkout", "-q", "-b", "main"]);
  const c0 = commit(repo, "shared.txt", "base", "c0");
  git(repo, ["checkout", "-q", "-b", "other"]);
  const otherMid = commit(repo, "shared.txt", "other side", "other-mid");
  const otherTip = commit(repo, "other-only.txt", "other tip", "other-tip");
  git(repo, ["checkout", "-q", "-b", "third", c0]);
  const thirdTip = commit(repo, "third.txt", "third", "third-tip");
  git(repo, ["checkout", "-q", "-b", "work", c0]);
  const workTip = commit(repo, "shared.txt", "work side", "work-tip");
  return { repo, c0, otherMid, otherTip, thirdTip, workTip };
}

function startConflictingMerge(f) {
  git(f.repo, ["merge", "--no-edit", "other"], true);
  const gitDir = path.resolve(f.repo, git(f.repo, ["rev-parse", "--git-dir"]));
  return path.join(gitDir, "MERGE_HEAD");
}

const statePath = (sid) => path.join(STATE_DIR, `${sid}.json`);
const stored = (sid) => {
  try {
    return (JSON.parse(fs.readFileSync(statePath(sid), "utf8")).merge_base_baseline) || null;
  } catch (_) {
    return null;
  }
};
const approve = (sid, f, base) => MBB.approveMergeBaseBaseline(sid, f.repo, base, "fixture approval during a merge");

caseBegin("merge-in-progress-accepts-merge-head-itself", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const mh = startConflictingMerge(f);
  check("A1-fixture: the conflicting merge left MERGE_HEAD in the gitdir", fs.existsSync(mh), mh);
  const r = approve("sid-a1", f, f.otherTip);
  check("A1-recorded: base = MERGE_HEAD is accepted while the merge is in progress", r.recorded === true, JSON.stringify(r));
  const rec = stored("sid-a1");
  check("A1-stored: the stored base is the MERGE_HEAD sha", rec && rec.base === f.otherTip, JSON.stringify(rec));
  check("A1-source: labelled user-approved", rec && rec.source === "user-approved", JSON.stringify(rec));
}
caseEnd();

caseBegin("merge-in-progress-accepts-ancestor-of-merge-head-only", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  startConflictingMerge(f);
  const notOnHead = spawnSync("git", ["-C", f.repo, "merge-base", "--is-ancestor", f.otherMid, "HEAD"]).status === 1;
  check("A2-fixture: the base is not an ancestor of HEAD", notOnHead, f.otherMid);
  const r = approve("sid-a2", f, f.otherMid);
  check("A2-recorded: an ancestor of MERGE_HEAD (not of HEAD) is accepted", r.recorded === true, JSON.stringify(r));
  const rec = stored("sid-a2");
  check("A2-stored: the stored base is that ancestor", rec && rec.base === f.otherMid, JSON.stringify(rec));
}
caseEnd();

caseBegin("merge-in-progress-refuses-unrelated-commit-and-keeps-record", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const pre = approve("sid-a3", f, f.c0);
  check("A3-setup: a pre-existing baseline is recorded before the merge", pre.recorded === true, JSON.stringify(pre));
  startConflictingMerge(f);
  const before = fs.readFileSync(statePath("sid-a3"));
  const r = approve("sid-a3", f, f.thirdTip);
  check("A3-refused: a commit on an unrelated third branch is refused", r.recorded === false, JSON.stringify(r));
  check("A3-reason: the refusal names the ancestry check", /not an ancestor/.test(String(r.reason)), JSON.stringify(r));
  check("A3-intact: the state file is byte-identical after the refusal",
    Buffer.compare(before, fs.readFileSync(statePath("sid-a3"))) === 0, "state file changed");
}
caseEnd();

caseBegin("no-merge-refuses-non-ancestor-of-head", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const r = approve("sid-a4", f, f.otherTip);
  check("A4-refused: without a merge, a base off HEAD's ancestry is refused", r.recorded === false, JSON.stringify(r));
  check("A4-reason: the refusal names the ancestry check", /not an ancestor/.test(String(r.reason)), JSON.stringify(r));
  check("A4-nothing-stored: no baseline is written", stored("sid-a4") === null, JSON.stringify(stored("sid-a4")));
}
caseEnd();

caseBegin("no-merge-accepts-ancestor-of-head", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const r = approve("sid-a5", f, f.c0);
  check("A5-recorded: without a merge, an ancestor of HEAD is accepted", r.recorded === true, JSON.stringify(r));
  const rec = stored("sid-a5");
  check("A5-stored: the stored base is that ancestor", rec && rec.base === f.c0 && rec.source === "user-approved", JSON.stringify(rec));
}
caseEnd();

caseBegin("garbage-merge-head-file-grants-nothing", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const gitDir = path.resolve(f.repo, git(f.repo, ["rev-parse", "--git-dir"]));
  const tree = git(f.repo, ["rev-parse", "HEAD^{tree}"]);
  // Lines that must all be ignored: junk text, an empty and a CR-only line, a non-commit object,
  // an option-looking token, and a well-formed sha that names no object.
  fs.writeFileSync(path.join(gitDir, "MERGE_HEAD"), ["not-a-sha", "", "\r", tree, "--all", "0".repeat(40), ""].join("\n"));
  const r = approve("sid-a6", f, f.thirdTip);
  check("A6-refused: a MERGE_HEAD of invalid lines does not widen the ancestry check", r.recorded === false, JSON.stringify(r));
  check("A6-nothing-stored: no baseline is written", stored("sid-a6") === null, JSON.stringify(stored("sid-a6")));
  const t = approve("sid-a6t", f, tree);
  check("A6-tree: a tree sha listed in MERGE_HEAD is never accepted as a base", t.recorded === false, JSON.stringify(t));
}
caseEnd();

caseBegin("cli-records-merge-head-during-merge", "bin/workflow/record-merge-base-baseline");
{
  const f = fixture();
  startConflictingMerge(f);
  const r = spawnSync(process.execPath, [RECORD_CLI, "--session", "sid-a7", "--base", f.otherTip,
    "--reason", "user confirmed MERGE_HEAD as the base", "--repo", f.repo],
  { encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env), cwd: WORK });
  check("A7-rc: the CLI exits 0", r.status === 0, `status=${r.status} stderr=${r.stderr}`);
  check("A7-out: and prints the recorded MERGE_HEAD", String(r.stdout).trim() === `RECORDED base=${f.otherTip} source=user-approved`,
    JSON.stringify(r.stdout));
  const rec = stored("sid-a7");
  check("A7-stored: the state file holds the MERGE_HEAD base", rec && rec.base === f.otherTip, JSON.stringify(rec));
}
caseEnd();

// The fixture's work branch moves into a linked worktree and the conflicting merge runs there, so
// MERGE_HEAD lives in .git/worktrees/<name>/ and the main checkout's gitdir has none.
function linkedWorktreeMerge() {
  const f = fixture();
  git(f.repo, ["checkout", "-q", "main"]);
  const wt = path.join(WORK, `wt-${repoSeq}`);
  git(f.repo, ["worktree", "add", "-q", wt, "work"]);
  git(wt, ["merge", "--no-edit", "other"], true);
  const gitDir = path.resolve(wt, git(wt, ["rev-parse", "--git-dir"]));
  return Object.assign({}, f, { wt, mergeHead: path.join(gitDir, "MERGE_HEAD") });
}

caseBegin("linked-worktree-merge-accepts-merge-head-side-ancestor", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = linkedWorktreeMerge();
  check("A8-fixture: MERGE_HEAD is in the linked worktree's own gitdir", fs.existsSync(f.mergeHead), f.mergeHead);
  check("A8-fixture: the main checkout's gitdir has no MERGE_HEAD", !fs.existsSync(path.join(f.repo, ".git", "MERGE_HEAD")), f.repo);
  const notOnHead = spawnSync("git", ["-C", f.wt, "merge-base", "--is-ancestor", f.otherMid, "HEAD"]).status === 1;
  check("A8-fixture: the base is not an ancestor of the linked worktree's HEAD", notOnHead, f.otherMid);
  const r = MBB.approveMergeBaseBaseline("sid-a8", f.wt, f.otherMid, "fixture approval in a linked worktree");
  check("A8-recorded: an ancestor of the linked worktree's MERGE_HEAD is accepted", r.recorded === true, JSON.stringify(r));
  const rec = stored("sid-a8");
  check("A8-stored: the stored base is that ancestor", rec && rec.base === f.otherMid, JSON.stringify(rec));
}
caseEnd();

caseBegin("cli-records-merge-head-side-ancestor-in-linked-worktree", "bin/workflow/record-merge-base-baseline");
{
  const f = linkedWorktreeMerge();
  const r = spawnSync(process.execPath, [RECORD_CLI, "--session", "sid-a9", "--base", f.otherMid,
    "--reason", "user confirmed the MERGE_HEAD side in a linked worktree", "--repo", f.wt],
  { encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env), cwd: WORK });
  check("A9-rc: the CLI exits 0", r.status === 0, `status=${r.status} stdout=${r.stdout} stderr=${r.stderr}`);
  check("A9-out: and prints the recorded base", String(r.stdout).trim() === `RECORDED base=${f.otherMid} source=user-approved`,
    JSON.stringify(r.stdout));
  const rec = stored("sid-a9");
  check("A9-stored: the state file holds the MERGE_HEAD-side base", rec && rec.base === f.otherMid, JSON.stringify(rec));
}
caseEnd();

// MERGE_HEAD line selection, the same rows as resolver M7: blank and CR are skipped, an invalid
// line does not stop the scan, every valid line counts, and only the first 8 valid entries count.
// The base is other-mid, an ancestor of other-tip only; work-tip (HEAD) and third-tip are not.
caseBegin("merge-head-line-selection-table", "hooks/workflow-state/merge-base-baseline.js");
{
  const rows = [
    { name: "blank-lines-skipped", lines: ["", "", "TIP", ""], want: true },
    { name: "crlf-stripped", lines: ["TIP\r", ""], want: true },
    { name: "invalid-line-before-valid", lines: ["not-a-sha", "TIP", ""], want: true },
    { name: "ancestor-of-second-valid-entry", lines: ["THIRD", "TIP", ""], want: true },
    { name: "cap-valid-entry-8-counts", lines: [...Array(7).fill("HEAD"), "TIP", ""], want: true },
    { name: "cap-valid-entry-9-ignored", lines: [...Array(8).fill("HEAD"), "TIP", ""], want: false },
    { name: "invalid-lines-not-counted-toward-cap", lines: [...Array(8).fill("not-a-sha"), "TIP", ""], want: true },
  ];
  const f = fixture();
  const mh = startConflictingMerge(f);
  const sha = { TIP: f.otherTip, THIRD: f.thirdTip, HEAD: f.workTip };
  rows.forEach(({ name, lines, want }, i) => {
    fs.writeFileSync(mh, lines.map((l) => l.replace(/^(TIP|THIRD|HEAD)/, (k) => sha[k])).join("\n"));
    const r = approve(`sid-a10-${i}`, f, f.otherMid);
    check(`A10-${name}: recorded=${want}`, r.recorded === want, JSON.stringify(r));
  });
}
caseEnd();

// The path run-tests-baseline takes to its base: the user approves a MERGE_HEAD-side ancestor
// through the CLI, then the resolver must hand that same sha back as the layer-1 base.
caseBegin("approve-then-resolve-merge-head-side-base", "bin/workflow/record-merge-base-baseline");
{
  const f = fixture();
  startConflictingMerge(f);
  const env = Object.assign({}, process.env);
  const rec = spawnSync(process.execPath, [RECORD_CLI, "--session", "sid-a11", "--base", f.otherMid,
    "--reason", "user approved the MERGE_HEAD side before resolving", "--repo", f.repo],
  { encoding: "utf8", timeout: 60000, env, cwd: WORK });
  check("A11-approve: the CLI records the MERGE_HEAD-side ancestor", rec.status === 0, `status=${rec.status} stderr=${rec.stderr}`);
  const res = spawnSync("bash", [path.join(ROOT, "bin", "resolve-merge-base.sh"), "-C", f.repo, "--no-fetch", "--session", "sid-a11"],
    { encoding: "utf8", timeout: 60000, env, cwd: WORK });
  const kv = (k) => ((String(res.stdout).match(new RegExp(`^${k}=(.*)$`, "m")) || [])[1] || "").trim();
  check("A11-resolve-rc: the resolver exits 0", res.status === 0, `status=${res.status} stderr=${res.stderr}`);
  check("A11-state: the approved base is adopted as RECORDED", kv("state") === "RECORDED", JSON.stringify(res.stdout));
  check("A11-base: and the resolver returns the approved sha", kv("base") === f.otherMid, `want=${f.otherMid} got=${kv("base")}`);
}
caseEnd();

caseBegin("conflicted-merge-accepts-head-side-only-ancestor", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const mh = startConflictingMerge(f);
  check("A12-fixture: the merge is in progress (MERGE_HEAD present)", fs.existsSync(mh), mh);
  check("A12-fixture: the index holds unmerged entries", git(f.repo, ["ls-files", "-u"]) !== "", "no conflict in the index");
  const notOnMergeHead = spawnSync("git", ["-C", f.repo, "merge-base", "--is-ancestor", f.workTip, f.otherTip]).status === 1;
  check("A12-fixture: the base is not an ancestor of MERGE_HEAD", notOnMergeHead, f.workTip);
  const r = approve("sid-a12", f, f.workTip);
  check("A12-recorded: an ancestor of HEAD only is still accepted during a conflicted merge", r.recorded === true, JSON.stringify(r));
  const rec = stored("sid-a12");
  check("A12-stored: the stored base is that HEAD-side commit", rec && rec.base === f.workTip, JSON.stringify(rec));
}
caseEnd();

// MERGE_HEAD line format: a line counts only when the line itself is a 40- or 64-hex object name.
// A ref name or revision expression that resolves to other-tip grants nothing and is not counted
// toward the cap of 8. The base is other-mid, an ancestor of other-tip only.
caseBegin("merge-head-line-format-table", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const mh = startConflictingMerge(f);
  const rows = [
    { name: "hex-40-accepted", lines: [f.otherTip], want: true },
    { name: "branch-name-refused", lines: ["other"], want: false },
    { name: "full-ref-refused", lines: ["refs/heads/other"], want: false },
    { name: "suffix-expression-refused", lines: ["other~0"], want: false },
    { name: "reflog-expression-refused", lines: ["other@{0}"], want: false },
    { name: "message-search-refused", lines: [":/other-tip"], want: false },
    { name: "abbreviated-hex-refused", lines: [f.otherTip.slice(0, 12)], want: false },
    { name: "uppercase-hex-refused", lines: [f.otherTip.toUpperCase()], want: false },
    { name: "symbolic-then-hex-accepted", lines: ["other", f.otherTip], want: true },
    { name: "symbolic-lines-not-counted-toward-cap", lines: [...Array(8).fill("work"), f.otherTip], want: true },
    // Lines that embed the full 40-hex tip: only a whole-line anchored match may accept them.
    { name: "hex-tilde-zero-refused", lines: [`${f.otherTip}~0`], want: false },
    { name: "hex-peel-commit-refused", lines: [`${f.otherTip}^{commit}`], want: false },
    { name: "hex-leading-space-refused", lines: [` ${f.otherTip}`], want: false },
    { name: "hex-trailing-space-refused", lines: [`${f.otherTip} `], want: false },
    { name: "hex-trailing-tab-refused", lines: [`${f.otherTip}\t`], want: false },
    { name: "hex-39-prefix-refused", lines: [f.otherTip.slice(0, 39)], want: false },
    { name: "hex-41-refused", lines: [`${f.otherTip}a`], want: false },
  ];
  for (const { name, lines, want } of rows) {
    const sid = `sid-a13-${name}`;
    fs.writeFileSync(mh, "");
    if (!want) approve(sid, f, f.c0);
    const before = want ? null : fs.readFileSync(statePath(sid));
    fs.writeFileSync(mh, lines.concat([""]).join("\n"));
    const r = approve(sid, f, f.otherMid);
    check(`A13-${name}: recorded=${want}`, r.recorded === want, JSON.stringify(r));
    if (want) {
      check(`A13-${name}: stored base is the resolved sha`, r.base === f.otherMid, JSON.stringify(r));
    } else {
      check(`A13-${name}: the state file is byte-identical after the refusal`,
        Buffer.compare(before, fs.readFileSync(statePath(sid))) === 0, "state file changed");
    }
  }
}
caseEnd();

caseBegin("merge-head-symbolic-ref-refusal-keeps-record", "hooks/workflow-state/merge-base-baseline.js");
{
  const f = fixture();
  const pre = approve("sid-a14", f, f.c0);
  check("A14-setup: a pre-existing baseline is recorded before the merge", pre.recorded === true, JSON.stringify(pre));
  const mh = startConflictingMerge(f);
  fs.writeFileSync(mh, "other\n");
  const before = fs.readFileSync(statePath("sid-a14"));
  const r = approve("sid-a14", f, f.otherMid);
  check("A14-refused: a MERGE_HEAD holding only a branch name does not widen the ancestry check", r.recorded === false, JSON.stringify(r));
  check("A14-intact: the state file is byte-identical after the refusal",
    Buffer.compare(before, fs.readFileSync(statePath("sid-a14"))) === 0, "state file changed");
}
caseEnd();

// The 64-hex half of the line format: a SHA-256 repository whose MERGE_HEAD holds a 64-hex tip.
// Same shape as fixture() — mid is reachable only from MERGE_HEAD — built with only the commits needed.
caseBegin("sha256-repo-merge-head-side-ancestor-accepted", "hooks/workflow-state/merge-base-baseline.js");
{
  const repo = path.join(WORK, `repo-sha256-${++repoSeq}`);
  fs.mkdirSync(repo);
  const init = spawnSync("git", ["init", "-q", "--object-format=sha256", repo], { encoding: "utf8", timeout: 20000 });
  if (init.error || init.status !== 0) {
    console.log(`SKIP: A15 -- git init --object-format=sha256 is unsupported here: ${String(init.stderr || init.error).trim()}`);
  } else {
    for (const [k, v] of [["core.hooksPath", "/dev/null"], ["user.email", "test@example.com"], ["user.name", "test"],
      ["commit.gpgsign", "false"]]) {
      git(repo, ["config", k, v]);
    }
    git(repo, ["checkout", "-q", "-b", "main"]);
    const c0 = commit(repo, "shared.txt", "base", "c0");
    git(repo, ["checkout", "-q", "-b", "other"]);
    const mid = commit(repo, "shared.txt", "other side", "other-mid");
    const tip = commit(repo, "other-only.txt", "other tip", "other-tip");
    git(repo, ["checkout", "-q", "-b", "work", c0]);
    commit(repo, "shared.txt", "work side", "work-tip");
    const f = { repo };
    const mh = startConflictingMerge(f);
    check("A15-fixture: the tip is a 64-hex object name", /^[0-9a-f]{64}$/.test(tip), tip);
    check("A15-fixture: MERGE_HEAD holds the 64-hex tip",
      fs.existsSync(mh) && fs.readFileSync(mh, "utf8").replace(/\r?\n$/, "") === tip, mh);
    const notOnHead = spawnSync("git", ["-C", repo, "merge-base", "--is-ancestor", mid, "HEAD"]).status === 1;
    check("A15-fixture: the base is not an ancestor of HEAD", notOnHead, mid);
    const r = approve("sid-a15", f, mid);
    check("A15-recorded: a 64-hex MERGE_HEAD widens the ancestry check", r.recorded === true, JSON.stringify(r));
    check("A15-base: the returned base is the resolved 64-hex sha", r.base === mid, JSON.stringify(r));
    const rec = stored("sid-a15");
    check("A15-stored: the stored base is the resolved 64-hex sha", rec && rec.base === mid, JSON.stringify(rec));
  }
}
caseEnd();

restore();
console.log(failures === 0 ? "ALL PASS" : `${failures} FAILED`);
process.exitCode = failures === 0 ? 0 : 1;
