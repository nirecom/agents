#!/usr/bin/env node
"use strict";
// Tests: bin/size-check
// Tags: scope:issue-specific, size-limits, cli, git, merge, fail-closed, layer:TL2
// #2631 stage 9 (K1-K9): under `--post index`, bin/size-check leaves out a staged blob equal to
// MERGE_HEAD's; an undecidable MERGE_HEAD (not a commit, octopus) judges every staged path.
// The merge repos come from tests/lib/size-merge-fixture.sh, shared with the bash callers.
// TL3 gap (what this test does NOT catch):
// - a merge commit made through a live Claude Code session (the gate runtime test drives Gate 2)
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const FIXTURE = path.join(ROOT, "tests", "lib", "size-merge-fixture.sh").replace(/\\/g, "/");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2631-scm-"));
const IDX = ["--kind", "code", "--pre", "rev:HEAD", "--post", "index"];
const UNDECIDABLE = "size-check: merge state undecidable (";
const leftOut = (n) => `size-check: merge in progress; ${n} staged path(s) equal to MERGE_HEAD left out`;

let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 400);
function check(name, ok, detail) {
  if (ok) console.log(`PASS: ${name}`);
  else { failures += 1; console.log(`FAIL: ${name} — ${clip(detail)}`); }
}
function guarded(name, fn) {
  try { fn(); } catch (e) { check(`${name} (threw)`, false, (e && e.message) || e); }
}

function git(dir, args) {
  const r = spawnSync("git", ["-C", dir, "-c", "user.email=test@example.com", "-c", "user.name=Test"].concat(args), { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return String(r.stdout || "").trim();
}
// smf(fn, ...args) — run one fixture function; prints SMF_MERGE_HEAD after it.
function smf(fn, ...args) {
  const r = spawnSync("bash", ["-c", '. "$0" || exit 9; "$@" || exit 8; printf %s "$SMF_MERGE_HEAD"', FIXTURE, fn].concat(args), { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`fixture ${fn} rc=${r.status}: ${r.stderr}`);
  return String(r.stdout || "").trim();
}
const hard = Number(smf("smf_hard", "code"));
let seq = 0;
const newDir = (tag) => path.join(TMP, `${tag}-${++seq}`).replace(/\\/g, "/");
// mergeRepo(...specs) — a fresh repo in an uncommitted merge.
function mergeRepo(...specs) {
  const dir = newDir("m");
  const mergeHead = smf("make_merge_repo", dir, ...specs);
  return { dir, mergeHead, mergeHeadPath: smf("smf_merge_head_path", dir) };
}
function plainRepo() {
  const dir = newDir("p");
  fs.mkdirSync(dir, { recursive: true });
  git(dir, ["init", "-q"]);
  git(dir, ["config", "core.hooksPath", "/dev/null"]);
  git(dir, ["config", "core.autocrlf", "false"]);
  put(dir, "seed.txt", 1);
  git(dir, ["add", "-A"]);
  git(dir, ["commit", "-q", "-m", "base"]);
  return dir;
}
function put(dir, rel, n, stageIt) {
  fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
  let s = "";
  for (let i = 1; i <= n; i++) s += `own line ${i}\n`;
  fs.writeFileSync(path.join(dir, rel), s);
  if (stageIt) git(dir, ["add", "--", rel]);
}
// sizeCheck(dir, paths, args) — { rc, targets, err }; targets is null without a TARGETS line.
function sizeCheck(dir, paths, args) {
  const env = Object.assign({}, process.env, { CODE_FILE_EXTENSIONS: "js;sh;py" });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "size-check")].concat(args || IDX), {
    cwd: dir, input: paths.map((p) => `${p}\0`).join(""), encoding: "utf8", timeout: 60000, env,
  });
  const m = /^TARGETS\t(\d+)/m.exec(String(r.stdout || "").replace(/\r/g, ""));
  return { rc: r.status, targets: m ? Number(m[1]) : null, err: String(r.stderr || ""), out: String(r.stdout || "") };
}
const show = (r) => `rc=${r.rc} targets=${r.targets} err=${r.err} out=${r.out}`;
// verdict(name, r, rc) — a verdict rc (0 / 1) also needs the TARGETS line.
const verdict = (name, r, rc) => check(name, r.rc === rc && r.targets !== null, show(r));

caseBegin("no-merge-head-judges-all", "bin/size-check");
guarded("K1", () => {
  const dir = plainRepo();
  put(dir, "src/big.js", hard + 1, true);
  const r = sizeCheck(dir, ["src/big.js"]);
  verdict("K1 no MERGE_HEAD: a new HARD+1 file is rc 1", r, 1);
  check("K1 no MERGE_HEAD: nothing is left out", !r.err.includes("left out"), show(r));
});
caseEnd();

caseBegin("merge-incoming-equal-blob-excluded", "bin/size-check");
guarded("K2", () => {
  const fx = mergeRepo(`src/big.js=${hard + 1}`, "src/small.js=3");
  let r = sizeCheck(fx.dir, ["src/big.js", "src/small.js"]);
  verdict("K2 blobs equal to MERGE_HEAD are left out (rc 0)", r, 0);
  check("K2 TARGETS drops the left-out paths (2 -> 0)", r.targets === 0, show(r));
  check("K2 stderr names the merge exclusion", r.err.includes(leftOut(2)), show(r));
  put(fx.dir, "src/own.js", 4, true);
  r = sizeCheck(fx.dir, ["src/big.js", "src/own.js"]);
  check("K2 an own staged path is still judged (TARGETS 1)", r.rc === 0 && r.targets === 1, show(r));
});
// The exclusion is kind-independent: the prompt and docs kinds leave out the same way.
for (const [kind, rel] of [["prompt", "rules/big.md"], ["docs", "docs/big.md"]]) {
  guarded(`K2 ${kind}`, () => {
    const h = Number(smf("smf_hard", kind));
    const fx = mergeRepo(`${rel}=${h + 1}`);
    const r = sizeCheck(fx.dir, [rel], ["--kind", kind, "--pre", "rev:HEAD", "--post", "index"]);
    verdict(`K2 --kind ${kind}: a HARD+1 ${rel} equal to MERGE_HEAD is left out (rc 0)`, r, 0);
    check(`K2 --kind ${kind}: stderr names the exclusion`, r.err.includes(leftOut(1)), show(r));
  });
}
caseEnd();

caseBegin("merge-incoming-differing-blob-judged", "bin/size-check");
guarded("K3", () => {
  const fx = mergeRepo(`src/big.js=${hard + 1}`);
  smf("smf_grow", fx.dir, "src/big.js");
  const r = sizeCheck(fx.dir, ["src/big.js"]);
  verdict("K3 MERGE_HEAD content plus one line is judged (rc 1)", r, 1);
  check("K3 the differing path stays a target", r.targets === 1, show(r));
});
caseEnd();

// The index state is blob AND mode: an equal blob staged with another mode is not MERGE_HEAD's.
caseBegin("merge-incoming-equal-blob-differing-mode-judged", "bin/size-check");
guarded("K3m", () => {
  const fx = mergeRepo(`src/big.js=${hard + 1}`, "src/twin.js=3");
  git(fx.dir, ["update-index", "--chmod=+x", "--", "src/big.js"]);
  const idx = git(fx.dir, ["ls-files", "-s", "--", "src/big.js"]).split(/\s+/);
  const theirs = git(fx.dir, ["ls-tree", fx.mergeHead, "--", "src/big.js"]).split(/\s+/);
  check("K3m premise: the index blob equals MERGE_HEAD's", idx[1] === theirs[2], `index=${idx.join(" ")} merge_head=${theirs.join(" ")}`);
  check("K3m premise: the index mode (100755) differs from MERGE_HEAD's (100644)", idx[0] === "100755" && theirs[0] === "100644", `index=${idx[0]} merge_head=${theirs[0]}`);
  const r = sizeCheck(fx.dir, ["src/big.js", "src/twin.js"]);
  verdict("K3m the mode-changed HARD+1 path is judged (rc 1)", r, 1);
  check("K3m only the mode-changed path stays a target (TARGETS 1)", r.targets === 1, show(r));
  check("K3m the same-mode twin alone is left out", r.err.includes(leftOut(1)), show(r));
});
caseEnd();

caseBegin("absent-in-merge-head-judged", "bin/size-check");
guarded("K4", () => {
  const fx = mergeRepo("src/small.js=3");
  put(fx.dir, "src/new.js", hard + 1, true);
  const r = sizeCheck(fx.dir, ["src/small.js", "src/new.js"]);
  verdict("K4 a HARD+1 path absent from MERGE_HEAD is rc 1", r, 1);
  check("K4 only the absent path is judged (TARGETS 1)", r.targets === 1, show(r));
  check("K4 the equal path is still left out", r.err.includes(leftOut(1)), show(r));
});
caseEnd();

caseBegin("forged-merge-head-not-a-commit", "bin/size-check");
for (const kind of ["tree", "blob", "missing", "garbage"]) {
  guarded(`K5 ${kind}`, () => {
    const fx = mergeRepo(`src/big.js=${hard + 1}`);
    const value = {
      tree: () => git(fx.dir, ["rev-parse", `${fx.mergeHead}^{tree}`]),
      blob: () => git(fx.dir, ["rev-parse", `${fx.mergeHead}:src/big.js`]),
      missing: () => "0123456789abcdef0123456789abcdef01234567",
      garbage: () => "not-an-object-id",
    }[kind]();
    fs.writeFileSync(fx.mergeHeadPath, `${value}\n`);
    const r = sizeCheck(fx.dir, ["src/big.js"]);
    verdict(`K5 MERGE_HEAD is a ${kind}: nothing left out (rc 1)`, r, 1);
    check(`K5 MERGE_HEAD is a ${kind}: stderr says undecidable`, r.err.includes(UNDECIDABLE), show(r));
    check(`K5 MERGE_HEAD is a ${kind}: no exclusion line`, !r.err.includes("left out"), show(r));
  });
}
caseEnd();

caseBegin("octopus-merge-head-judges-all", "bin/size-check");
guarded("K6", () => {
  const fx = mergeRepo(`src/big.js=${hard + 1}`);
  fs.writeFileSync(fx.mergeHeadPath, `${fx.mergeHead}\n${git(fx.dir, ["rev-parse", "HEAD~1"])}\n`);
  const r = sizeCheck(fx.dir, ["src/big.js"]);
  verdict("K6 two MERGE_HEAD lines: nothing left out (rc 1)", r, 1);
  check("K6 octopus is undecidable", r.err.includes(UNDECIDABLE), show(r));
});
caseEnd();

caseBegin("commit-tree-forgery-is-the-accepted-residual", "bin/size-check");
guarded("K7", () => {
  const dir = plainRepo();
  put(dir, "src/big.js", hard + 1, true);
  const forged = git(dir, ["commit-tree", git(dir, ["write-tree"]), "-p", "HEAD", "-m", "forged"]);
  fs.writeFileSync(smf("smf_merge_head_path", dir), `${forged}\n`);
  const r = sizeCheck(dir, ["src/big.js"]);
  // Accepted Tradeoff: a commit forged from the index cannot be told from a real MERGE_HEAD.
  verdict("K7 commit-tree forgery is left out (accepted residual, rc 0)", r, 0);
  check("K7 the forged MERGE_HEAD reads as a merge", r.err.includes(leftOut(1)), show(r));
});
caseEnd();

caseBegin("linked-worktree-merge-head", "bin/size-check");
guarded("K8", () => {
  const main = plainRepo();
  git(main, ["branch", "-M", "main"]);
  const wt = newDir("wt");
  git(main, ["worktree", "add", "-q", "-b", "linked", wt, "main"]);
  smf("smf_start_merge", wt, `src/big.js=${hard + 1}`);
  const mh = smf("smf_merge_head_path", wt);
  check("K8 premise: MERGE_HEAD is in the linked worktree's gitdir", /\/worktrees\//.test(mh.replace(/\\/g, "/")) && fs.existsSync(mh), mh);
  const r = sizeCheck(wt, ["src/big.js"]);
  verdict("K8 linked worktree: equal blob left out (rc 0)", r, 0);
  check("K8 linked worktree: stderr names the exclusion", r.err.includes(leftOut(1)), show(r));
});
caseEnd();

caseBegin("worktree-post-not-excluded", "bin/size-check");
guarded("K9", () => {
  const fx = mergeRepo(`src/big.js=${hard + 1}`);
  const r = sizeCheck(fx.dir, ["src/big.js"], ["--kind", "code", "--pre", "none", "--post", "worktree"]);
  verdict("K9 --post worktree judges the merge-incoming file (rc 1)", r, 1);
  check("K9 --post worktree: no exclusion line", !r.err.includes("left out"), show(r));
});
caseEnd();

// K10-K11: `:<path>` reads `:0:small.js` as stage 0 of small.js, so a path named `0:small.js` must be
// read with an explicit stage. Git for Windows refuses `:` in an index path even with protectNTFS off,
// so the entry is staged as `0_small.js` and renamed in the v2 index bytes (checksum recomputed).
function stageAliasRepo(aliasLines) {
  const dir = plainRepo();
  git(dir, ["config", "index.version", "2"]);
  put(dir, "small.js", 3, true);
  const blobFile = path.join(TMP, `alias-blob-${++seq}.txt`);
  let s = "";
  for (let i = 1; i <= aliasLines; i++) s += `alias line ${i}\n`;
  fs.writeFileSync(blobFile, s);
  const oid = git(dir, ["hash-object", "-w", "--", blobFile.replace(/\\/g, "/")]);
  git(dir, ["update-index", "--add", "--cacheinfo", `100644,${oid},0_small.js`]);
  const indexPath = git(dir, ["rev-parse", "--git-path", "index"]);
  const file = path.isAbsolute(indexPath) ? indexPath : path.join(dir, indexPath);
  const body = fs.readFileSync(file).subarray(0, -20);
  const at = body.indexOf("0_small.js\0");
  if (at < 0 || body.indexOf("0_small.js\0", at + 1) >= 0) throw new Error("placeholder entry not unique in the index");
  body.write("0:", at, "latin1");
  fs.writeFileSync(file, Buffer.concat([body, require("crypto").createHash("sha1").update(body).digest()]));
  return dir;
}
const hardRecordFor = (r, p) => r.out.replace(/\r/g, "").split("\n").some((l) => l.startsWith("HARD\t") && l.endsWith(`\t${p}`));

caseBegin("stage-alias-path-measures-its-own-blob", "bin/size-check");
guarded("K10", () => {
  const dir = stageAliasRepo(hard + 1);
  const staged = git(dir, ["ls-files"]).split(/\r?\n/);
  check("K10 premise: the index holds 0:small.js and small.js", staged.includes("0:small.js") && staged.includes("small.js"), staged.join(" "));
  const r = sizeCheck(dir, ["0:small.js"]);
  verdict("K10 a HARD+1 0:small.js is rc 1, not read as small.js's stage 0", r, 1);
  check("K10 a HARD record names 0:small.js", hardRecordFor(r, "0:small.js"), show(r));
});
caseEnd();

caseBegin("stage-alias-path-under-hard-not-reported", "bin/size-check");
guarded("K11", () => {
  const dir = stageAliasRepo(hard);
  const r = sizeCheck(dir, ["0:small.js"]);
  verdict("K11 0:small.js at the HARD limit is rc 0", r, 0);
  check("K11 no HARD record", !hardRecordFor(r, "0:small.js"), show(r));
});
caseEnd();

fs.rmSync(TMP, { recursive: true, force: true });
restore();
process.exitCode = failures ? 1 : 0;
