"use strict";
// T6-4: what input 1 (artifact) binds to. R-A: the plan artifact's bytes inside the approval
// range (intent drops ## Issues). R-S: the staged blobs of the step's staged changed paths —
// never the working tree — with deletions and --no-renames moves included, each staged path
// classified into exactly one review step, and an unresolvable worktree failing closed.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

const SCOPE = "hooks/workflow-state/glossary-check/scope.js";
const RECORD = "hooks/workflow-state/glossary-check/record.js";

function fp(scope, sid, step, repo) {
  const r = scope.stepFingerprint(sid, step, { repoDir: repo });
  return r && r.ok ? r : { ok: false, fingerprint: null, inputs: {}, error: r && r.error };
}
function artifactPaths(scope, sid, step, repo) {
  const r = scope.loadStepInputs(sid, step, { repoDir: repo });
  return r && r.ok ? r.artifact.files.map((f) => f.path).sort() : null;
}

function rangeA(scope) {
  let s = F.setupStep("ra-intent", "clarify_intent", F.TERM);
  const before = fp(scope, s.sid, "clarify_intent", s.repo);
  F.check("R-A intent: fingerprint computable", before.ok && /^[0-9a-f]{64}$/.test(before.fingerprint), JSON.stringify(before));
  const body = F.planBody("intent", F.TERM);
  F.writePlan(s.sid, "intent", body.replace("- #1 fixture\n", "- #1 fixture\n- #2 backfilled title\n"));
  F.check("R-A intent: editing only ## Issues keeps the fingerprint",
    fp(scope, s.sid, "clarify_intent", s.repo).fingerprint === before.fingerprint, "changed");
  F.writePlan(s.sid, "intent", body.replace("## Goal\n\nEach", "## Goal\n\nevery"));
  F.check("R-A intent: editing ## Goal changes the artifact component",
    fp(scope, s.sid, "clarify_intent", s.repo).inputs.artifact !== before.inputs.artifact, "same");
  for (const step of ["outline", "detail"]) {
    s = F.setupStep(`ra-${step}`, step, F.TERM);
    const a = fp(scope, s.sid, step, s.repo);
    F.writePlan(s.sid, F.ARTIFACT_OF[step], F.planBody(F.ARTIFACT_OF[step], F.TERM).replace("checked.", "checked!"));
    const b = fp(scope, s.sid, step, s.repo);
    F.check(`R-A ${step}: one changed byte changes the fingerprint`, a.ok && b.ok && a.fingerprint !== b.fingerprint, `${a.fingerprint} ${b.fingerprint}`);
  }
}

// T6-4 R-S: blob swap, working-tree-only edits, unstaged files, deletions, moves.
function rangeS(scope) {
  for (const step of F.RS_STEPS) {
    const file = F.TARGET[step];
    const A = F.targetBody(step, F.TERM);
    const B = F.targetBody(step, "review scope");
    const s = F.setupStep(`rs-${step}`, step, F.TERM);
    const p1 = fp(scope, s.sid, step, s.repo);
    F.check(`R-S ${step}: fingerprint computable`, p1.ok, JSON.stringify(p1));
    F.stageFile(s.repo, file, B);
    F.writeFile(s.repo, file, A);
    const p2 = fp(scope, s.sid, step, s.repo);
    F.check(`R-S ${step}: a swapped staged blob changes the fingerprint (working tree back to A)`,
      p2.ok && p2.fingerprint !== p1.fingerprint, `${p1.fingerprint} ${p2.fingerprint}`);
    F.stageFile(s.repo, file, A);
    F.check(`R-S ${step}: re-staging A restores P1`, fp(scope, s.sid, step, s.repo).fingerprint === p1.fingerprint, "differs");
    F.writeFile(s.repo, file, B);
    F.check(`R-S ${step}: a working-tree-only edit leaves the fingerprint alone`,
      fp(scope, s.sid, step, s.repo).fingerprint === p1.fingerprint, "changed");
    const extra = file.replace(/(\.[a-z]+)$/, "-wt$1");
    F.writeFile(s.repo, extra, A);
    const paths = artifactPaths(scope, s.sid, step, s.repo);
    F.check(`R-S ${step}: an unstaged file is not in the artifact`, !!paths && paths.join(",") === file, JSON.stringify(paths));
    const inputs = scope.loadStepInputs(s.sid, step, { repoDir: s.repo });
    const text = inputs && inputs.ok ? inputs.artifact.files[0].text : "";
    F.check(`R-S ${step}: scanned text is the staged blob, not the working tree`, text === A, JSON.stringify(text));
  }
}

function deletionsAndMoves(scope) {
  for (const step of F.RS_STEPS) {
    const file = F.TARGET[step];
    const moved = file.replace(/(\.[a-z]+)$/, "-moved$1");
    const mk = (tag) => {
      const s = F.setupStep(`${tag}-${step}`, step, F.TERM);
      F.commit(s.repo, "fixture: target");
      return s;
    };
    let s = mk("del");
    const empty = fp(scope, s.sid, step, s.repo);
    F.git(s.repo, ["rm", "-q", "--", file]);
    const del = fp(scope, s.sid, step, s.repo);
    F.check(`R-S ${step}: a staged deletion enters the artifact component`,
      del.ok && empty.ok && del.inputs.artifact !== empty.inputs.artifact, `${empty.inputs.artifact} ${del.inputs.artifact}`);
    s = mk("mv");
    F.git(s.repo, ["mv", "--", file, moved]);
    const mv = fp(scope, s.sid, step, s.repo);
    s = mk("copy");
    F.stageFile(s.repo, moved, F.targetBody(step, F.TERM));
    const copy = fp(scope, s.sid, step, s.repo);
    F.check(`R-S ${step}: git mv carries the source as deleted (--no-renames)`,
      mv.ok && copy.ok && mv.inputs.artifact !== copy.inputs.artifact, `${mv.inputs.artifact} ${copy.inputs.artifact}`);
  }
  const s = F.setupStep("mv-glossary", "review_docs", F.TERM, { stageTarget: false });
  F.git(s.repo, ["mv", "--", "docs/glossary/user.md", "docs/glossary/user-a-m.md"]);
  const paths = artifactPaths(scope, s.sid, "review_docs", s.repo) || [];
  F.check("R-S review_docs: a glossary git mv shows the moved-from path", paths.includes("docs/glossary/user.md") &&
    paths.includes("docs/glossary/user-a-m.md"), JSON.stringify(paths));
}

function classification(scope) {
  const want = { "tests/x.sh": "review_tests", "tests/notes.md": "review_tests", "docs/guide.md": "review_docs",
    "README.md": "review_docs", "CHANGELOG.md": "review_docs", "src/a.js": "review_security",
    "docs/img.png": "review_security", "hooks/notes.md": "review_security" };
  for (const [p, step] of Object.entries(want)) {
    F.check(`reviewStepOfFile(${p}) = ${step}`, scope.reviewStepOfFile(p) === step, String(scope.reviewStepOfFile(p)));
  }
  const s = F.setupStep("classify", "review_security", F.TERM, { stageTarget: false });
  for (const p of Object.keys(want)) F.stageFile(s.repo, p, p.endsWith(".png") ? "png" : `# ${p}\n`);
  const seen = {};
  for (const step of F.RS_STEPS) {
    const paths = artifactPaths(scope, s.sid, step, s.repo) || [];
    const expected = Object.keys(want).filter((p) => want[p] === step).sort();
    F.check(`staged set split: ${step} holds exactly its class`, paths.join(",") === expected.join(","), JSON.stringify(paths));
    for (const p of paths) seen[p] = (seen[p] || 0) + 1;
  }
  F.check("staged set split: no path is in two review steps", Object.values(seen).every((n) => n === 1), JSON.stringify(seen));
}

function failClosed(scope, record) {
  const notRepo = F.slash(fs.mkdtempSync(path.join(os.tmpdir(), "g2529-norepo-")));
  for (const step of F.RS_STEPS) {
    const s = F.setupStep(`unavail-${step}`, step, F.TERM);
    F.check(`${step}: a non-git repoDir makes the fingerprint unavailable`,
      scope.stepFingerprint(s.sid, step, { repoDir: notRepo }).ok === false, "ok");
    F.drift(s.sid, step, s.repo);
    const v = record.evaluateGlossaryCheck(s.sid, step, F.readState(s.sid), { repoDir: notRepo });
    F.check(`${step}: evaluateGlossaryCheck fails closed with glossary-fingerprint-unavailable`,
      v && v.ok === false && v.code === "glossary-fingerprint-unavailable", JSON.stringify(v));
  }
  // opts.repoDir outranks the process cwd.
  const a = F.setupStep("prio-a", "review_security", F.TERM);
  const b = F.mkRepo("prio-b");
  F.stageFile(b, "src/b.js", F.targetBody("review_security", F.TERM));
  const prev = process.cwd();
  process.chdir(a.repo);
  let paths;
  try { paths = artifactPaths(scope, a.sid, "review_security", b); } finally { process.chdir(prev); }
  F.check("opts.repoDir is the first worktree source", JSON.stringify(paths) === JSON.stringify(["src/b.js"]), JSON.stringify(paths));
}

function run() {
  const scope = F.mod(SCOPE);
  const record = F.mod(RECORD);
  if (!scope || !record) return;
  rangeA(scope);
  rangeS(scope);
  deletionsAndMoves(scope);
  classification(scope);
  failClosed(scope, record);
}

module.exports = { run };
