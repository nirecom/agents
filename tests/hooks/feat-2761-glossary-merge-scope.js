"use strict";
// Tests: hooks/workflow-state/glossary-check/scope/artifact.js, hooks/lib/merge-incoming.js, bin/check-glossary-drift
// Tags: TL2, hooks, glossary, glossary-check, merge, merge-incoming, scope:issue-specific
// #2761 B group (here): artifactRS subtracts the merge-incoming files only while merging, keeps pairs
// and digest byte-identical outside a merge, falls back to every staged path when undecidable,
// and check-glossary-drift says which happened on stderr (stdout and exit code unchanged).
// A group (detectMergeIncoming itself) lives in ./feat-2761-glossary-merge/incoming-cases.js.
// TL3 gap (what this test does NOT catch):
// - a real merge commit pushed through the commit gate by a claude session.
// - #2507's pre-commit calling the module under a temporary GIT_INDEX_FILE.
// Fixtures: tests/lib/glossary-check-fixture.js, ./feat-2761-glossary-merge/fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2761-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const M = require("./feat-2761-glossary-merge/fixture");
const { loadStageInputs, classifyStageFile } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope"));

const WORD = F.VARIANT;
const DRIFT_RE = /DRIFT: (\S+) "([^"]*)" -> "([^"]*)" at (.+):(\d+)\s*$/;
const driftFiles = (text) => String(text).split(/\r?\n/).map((l) => DRIFT_RE.exec(l)).filter(Boolean).map((m) => F.slash(m[4]));
const MERGING_RE = /check-glossary-drift: merge in progress; (\d+) staged path\(s\) equal to MERGE_HEAD left out of the (\w+) scan/;
const UNDECIDABLE_RE = /check-glossary-drift: merge state undecidable \(([\w-]+)\); scanning every staged path/;
const ANY_MERGE_LINE = /check-glossary-drift: merge /;

const guarded = (name, fn) => M.guarded(F.check, name, fn);

// repoDir undefined: the session's linked worktree resolves the repo (B7); a main worktree needs it.
function load(sid, stage, repoDir) {
  const r = loadStageInputs(sid, stage, repoDir ? { repoDir } : {});
  if (!r.ok) throw new Error(`loadStageInputs(${stage}) failed: ${r.error} ${r.detail || ""}`);
  return r;
}
const pathsOf = (loaded) => loaded.artifact.files.map((f) => f.path);
const mi = (loaded) => loaded.artifact.mergeIncoming;
const showMi = (loaded) => JSON.stringify(mi(loaded));
const dry = (sid, stage, cwd) => F.drift(sid, stage, cwd, false);

// A standard merge in `dir` and a session at docs whose worktree is `dir`.
function standardSession(tag, dir) {
  const repo = dir || F.mkRepo(tag);
  M.standardMerge(repo, WORD);
  return { repo, sid: F.seedSession(tag, "docs", { cwd: repo }) };
}

// B1 / B7 shared assertions.
function narrowed(label, s, viaSession) {
  const at = viaSession ? undefined : s.repo;
  const docs = load(s.sid, "docs", at);
  F.check(`${label}: docs scope is exactly docs/shared.md`, JSON.stringify(pathsOf(docs)) === '["docs/shared.md"]', JSON.stringify(pathsOf(docs)));
  for (const stage of ["code", "tests"]) {
    const l = load(s.sid, stage, at);
    F.check(`${label}: ${stage} scope is empty`, l.artifact.empty === true && pathsOf(l).length === 0, JSON.stringify(pathsOf(l)));
    const r = dry(s.sid, stage, s.repo);
    F.check(`${label}: check-glossary-drift --stage ${stage} exits 0 with no DRIFT line`, r.code === 0 && driftFiles(r.out).length === 0, `exit=${r.code} ${r.out}${r.err}`);
  }
  const d = dry(s.sid, "docs", s.repo);
  F.check(`${label}: docs has no DRIFT line for docs/main-only.md`, !driftFiles(d.out).includes("docs/main-only.md"), d.out);
  return d;
}

// A0-A12 (detectMergeIncoming); their markers sit in the module.
require("./feat-2761-glossary-merge/incoming-cases").run();

caseBegin("standard merge narrows every staged-file stage to the resolved file", "hooks/workflow-state/glossary-check/scope/artifact.js");
guarded("B1", () => narrowed("B1", standardSession("b1"), false));
caseEnd();

caseBegin("resolved conflict file still reports its drift", "bin/check-glossary-drift");
guarded("B2", () => {
  const s = standardSession("b2");
  const d = dry(s.sid, "docs", s.repo);
  F.check("B2 check-glossary-drift --stage docs exits 1", d.code === 1, `exit=${d.code} ${d.err}`);
  F.check("B2 exactly one DRIFT line, at docs/shared.md", JSON.stringify(driftFiles(d.out)) === '["docs/shared.md"]', d.out);
});
caseEnd();

caseBegin("incoming file edited during the merge is scanned again", "hooks/workflow-state/glossary-check/scope/artifact.js");
guarded("B3", () => {
  const s = standardSession("b3");
  M.apply(s.repo, { "src/main-only.js": `"use strict";\n// each ${WORD} is checked, edited in the merge\nmodule.exports = 2;\n` });
  const code = load(s.sid, "code", s.repo);
  F.check("B3 code scope is exactly src/main-only.js", JSON.stringify(pathsOf(code)) === '["src/main-only.js"]', JSON.stringify(pathsOf(code)));
  const r = dry(s.sid, "code", s.repo);
  F.check("B3 check-glossary-drift --stage code reports src/main-only.js", r.code === 1 && driftFiles(r.out).includes("src/main-only.js"), `exit=${r.code} ${r.out}`);
  const docs = pathsOf(load(s.sid, "docs", s.repo));
  F.check("B3 docs scope stays narrowed", JSON.stringify(docs) === '["docs/shared.md"]', JSON.stringify(docs));
});
caseEnd();

caseBegin("staged edit is scanned although the worktree is back at MERGE_HEAD", "bin/check-glossary-drift");
guarded("A12a-drift", () => {
  const s = standardSession("a12-drift");
  const rel = "docs/main-only.md";
  const sides = M.stagedEditWorktreeAtMergeHead(s.repo, rel, WORD);
  F.check("A12a-drift precondition: index differs from MERGE_HEAD, worktree equals it", !sides.indexIsMergeHead && sides.worktreeIsMergeHead, JSON.stringify(sides));
  const docs = pathsOf(load(s.sid, "docs", s.repo));
  F.check(`A12a-drift docs scope keeps ${rel} (the staged blob differs from MERGE_HEAD)`, docs.includes(rel), JSON.stringify(docs));
  const d = dry(s.sid, "docs", s.repo);
  F.check(`A12a-drift check-glossary-drift --stage docs exits 1 with a DRIFT line at ${rel}`, d.code === 1 && driftFiles(d.out).includes(rel), `exit=${d.code} ${d.out}`);
});
caseEnd();

caseBegin("outside a merge pairs and digest stay unchanged", "hooks/workflow-state/glossary-check/scope/artifact.js");
guarded("B4", () => {
  const repo = F.mkRepo("b4");
  M.commitAll(repo, { "docs/gone.md": "# Gone\n\nText.\n" }, "fixture: to delete");
  for (const stage of F.RS_STAGES) F.stageFile(repo, F.TARGET[stage], F.targetBody(stage, F.TERM));
  M.apply(repo, { "docs/gone.md": null });
  const sid = F.seedSession("b4", "docs", { cwd: repo });
  const before = {};
  for (const stage of F.RS_STAGES) {
    const l = load(sid, stage, repo);
    before[stage] = l.artifact.digest;
    F.check(`B4 ${stage} digest equals the unsubtracted formula`, l.artifact.digest === M.stagedPairsDigest(repo, stage, classifyStageFile), l.artifact.digest);
    F.check(`B4 ${stage} mergeIncoming.state is not-merging`, !!mi(l) && mi(l).state === "not-merging" && mi(l).excluded === 0, showMi(l));
    F.check(`B4 ${stage} check-glossary-drift prints no merge line`, !ANY_MERGE_LINE.test(dry(sid, stage, repo).err), "merge line printed");
  }
  F.check("B4 precondition: a branch named MERGE_HEAD resolves", M.makeMergeHeadBranch(repo), "rev-parse failed");
  for (const stage of F.RS_STAGES) {
    const l = load(sid, stage, repo);
    F.check(`B4 ${stage} digest unchanged by a branch named MERGE_HEAD`, l.artifact.digest === before[stage], l.artifact.digest);
    F.check(`B4 ${stage} still not-merging with a branch named MERGE_HEAD`, !!mi(l) && mi(l).state === "not-merging", showMi(l));
  }
});
caseEnd();

caseBegin("undecidable merge state falls back to every staged path", "hooks/workflow-state/glossary-check/scope/artifact.js");
guarded("B5", () => {
  const oct = F.mkRepo("b5-oct");
  const fx = M.octopusMerge(oct, WORD);
  F.check("B5 precondition: octopus MERGE_HEAD has two lines", fx.lines.length === 2, fx.lines.join("|"));
  const bad = F.mkRepo("b5-bad");
  M.standardMerge(bad, WORD);
  M.corruptMergeHead(bad);
  for (const [label, repo, reason] of [["octopus", oct, "octopus"], ["dangling MERGE_HEAD", bad, "diff-failed"]]) {
    const sid = F.seedSession(`b5-${reason}`, "docs", { cwd: repo });
    const docs = load(sid, "docs", repo);
    const all = M.stagedNames(repo).filter((p) => classifyStageFile(p) === "docs").sort();
    F.check(`B5 ${label}: docs scope is every staged docs path`, JSON.stringify(pathsOf(docs)) === JSON.stringify(all), JSON.stringify(pathsOf(docs)));
    F.check(`B5 ${label}: digest equals the unsubtracted formula`, docs.artifact.digest === M.stagedPairsDigest(repo, "docs", classifyStageFile), docs.artifact.digest);
    F.check(`B5 ${label}: mergeIncoming is undecidable / ${reason}, nothing excluded`,
      !!mi(docs) && mi(docs).state === "undecidable" && mi(docs).reason === reason && mi(docs).excluded === 0, showMi(docs));
    const d = dry(sid, "docs", repo);
    F.check(`B5 ${label}: docs/main-only.md drift is reported`, d.code === 1 && driftFiles(d.out).includes("docs/main-only.md"), `exit=${d.code} ${d.out}`);
    const m = UNDECIDABLE_RE.exec(d.err);
    F.check(`B5 ${label}: stderr names the undecidable reason ${reason}`, !!m && m[1] === reason, d.err);
    F.check(`B5 ${label}: stdout carries no merge line`, !ANY_MERGE_LINE.test(d.out), d.out);
  }
});
caseEnd();

caseBegin("stderr reports the excluded count and stays quiet otherwise", "bin/check-glossary-drift");
guarded("B6", () => {
  const s = standardSession("b6");
  for (const [stage, n] of [["code", 1], ["tests", 1], ["docs", 2]]) {
    const l = load(s.sid, stage, s.repo);
    F.check(`B6 ${stage} mergeIncoming is merging / excluded ${n}`, !!mi(l) && mi(l).state === "merging" && mi(l).excluded === n && !("reason" in mi(l)), showMi(l));
    const r = dry(s.sid, stage, s.repo);
    const m = MERGING_RE.exec(r.err);
    F.check(`B6 ${stage} stderr says ${n} path(s) left out of the ${stage} scan`, !!m && Number(m[1]) === n && m[2] === stage, r.err);
    F.check(`B6 ${stage} stdout carries no merge line`, !ANY_MERGE_LINE.test(r.out), r.out);
  }
  const repo = F.mkRepo("b6-skip");
  F.stageFile(repo, F.TARGET.docs, F.targetBody("docs", F.TERM));
  const sid = F.seedSession("b6-skip", "docs", { cwd: repo });
  const tests = load(sid, "tests", repo);
  F.check("B6 no staged tests path: mergeIncoming is skipped / excluded 0", JSON.stringify(mi(tests)) === '{"state":"skipped","excluded":0}', showMi(tests));
  F.check("B6 no staged tests path: stderr has no merge line", !ANY_MERGE_LINE.test(dry(sid, "tests", repo).err), "merge line printed");
  const plan = F.seedSession("b6-plan", "outline", { cwd: s.repo });
  const outline = load(plan, "outline", s.repo);
  F.check("B6 plan-file stage: artifact has no mergeIncoming field", !("mergeIncoming" in outline.artifact), showMi(outline));
  F.check("B6 plan-file stage during a merge: stderr has no merge line", !ANY_MERGE_LINE.test(dry(plan, "outline", s.repo).err), "merge line printed");
});
caseEnd();

caseBegin("linked worktree merge narrows like the main worktree", "hooks/workflow-state/glossary-check/scope/artifact.js");
guarded("B7", () => {
  const repo = F.mkRepo("b7");
  const wt = F.addWorktree(repo, `b7-${process.pid}`);
  narrowed("B7 worktree", standardSession("b7", wt), true);
});
caseEnd();

restoreIsolation();
F.finish();
