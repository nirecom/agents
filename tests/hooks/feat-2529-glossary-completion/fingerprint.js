"use strict";
// T6-4: what input 1 (artifact) binds to. R-A: the plan artifact's bytes inside the approval
// range (intent drops ## Issues). R-S: the staged blobs of the stage's staged changed paths —
// never the working tree — with deletions and --no-renames moves included, each staged path
// classified into exactly one stage, and an unresolvable worktree failing closed.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

const SCOPE = "hooks/workflow-state/glossary-check/scope.js";
const RECORD = "hooks/workflow-state/glossary-check/record.js";

function fp(scope, sid, stage, repo) {
  const r = scope.stageFingerprint(sid, stage, { repoDir: repo });
  return r && r.ok ? r : { ok: false, fingerprint: null, inputs: {}, error: r && r.error };
}
function artifactPaths(scope, sid, stage, repo) {
  const r = scope.loadStageInputs(sid, stage, { repoDir: repo });
  return r && r.ok ? r.artifact.files.map((f) => f.path).sort() : null;
}

function rangeA(scope) {
  let s = F.setupStage("ra-intent", "intent", F.TERM);
  const before = fp(scope, s.sid, "intent", s.repo);
  F.check("R-A intent: fingerprint computable", before.ok && /^[0-9a-f]{64}$/.test(before.fingerprint), JSON.stringify(before));
  const body = F.planBody("intent", F.TERM);
  F.writePlan(s.sid, "intent", body.replace("- #1 fixture\n", "- #1 fixture\n- #2 backfilled title\n"));
  F.check("R-A intent: editing only ## Issues keeps the fingerprint",
    fp(scope, s.sid, "intent", s.repo).fingerprint === before.fingerprint, "changed");
  F.writePlan(s.sid, "intent", body.replace("## Goal\n\nEach", "## Goal\n\nevery"));
  F.check("R-A intent: editing ## Goal changes the artifact component",
    fp(scope, s.sid, "intent", s.repo).inputs.artifact !== before.inputs.artifact, "same");
  for (const stage of ["outline", "detail"]) {
    s = F.setupStage(`ra-${stage}`, stage, F.TERM);
    const a = fp(scope, s.sid, stage, s.repo);
    F.writePlan(s.sid, stage, F.planBody(stage, F.TERM).replace("checked.", "checked!"));
    const b = fp(scope, s.sid, stage, s.repo);
    F.check(`R-A ${stage}: one changed byte changes the fingerprint`, a.ok && b.ok && a.fingerprint !== b.fingerprint, `${a.fingerprint} ${b.fingerprint}`);
  }
}

// T6-4 R-S: blob swap, working-tree-only edits, unstaged files, deletions, moves.
function rangeS(scope) {
  for (const stage of F.RS_STAGES) {
    const file = F.TARGET[stage];
    const A = F.targetBody(stage, F.TERM);
    const B = F.targetBody(stage, "review scope");
    const s = F.setupStage(`rs-${stage}`, stage, F.TERM);
    const p1 = fp(scope, s.sid, stage, s.repo);
    F.check(`R-S ${stage}: fingerprint computable`, p1.ok, JSON.stringify(p1));
    F.stageFile(s.repo, file, B);
    F.writeFile(s.repo, file, A);
    const p2 = fp(scope, s.sid, stage, s.repo);
    F.check(`R-S ${stage}: a swapped staged blob changes the fingerprint (working tree back to A)`,
      p2.ok && p2.fingerprint !== p1.fingerprint, `${p1.fingerprint} ${p2.fingerprint}`);
    F.stageFile(s.repo, file, A);
    F.check(`R-S ${stage}: re-staging A restores P1`, fp(scope, s.sid, stage, s.repo).fingerprint === p1.fingerprint, "differs");
    F.writeFile(s.repo, file, B);
    F.check(`R-S ${stage}: a working-tree-only edit leaves the fingerprint alone`,
      fp(scope, s.sid, stage, s.repo).fingerprint === p1.fingerprint, "changed");
    const extra = file.replace(/(\.[a-z]+)$/, "-wt$1");
    F.writeFile(s.repo, extra, A);
    const paths = artifactPaths(scope, s.sid, stage, s.repo);
    F.check(`R-S ${stage}: an unstaged file is not in the artifact`, !!paths && paths.join(",") === file, JSON.stringify(paths));
    const inputs = scope.loadStageInputs(s.sid, stage, { repoDir: s.repo });
    const text = inputs && inputs.ok ? inputs.artifact.files[0].text : "";
    F.check(`R-S ${stage}: scanned text is the staged blob, not the working tree`, text === A, JSON.stringify(text));
  }
}

function deletionsAndMoves(scope) {
  for (const stage of F.RS_STAGES) {
    const file = F.TARGET[stage];
    const moved = file.replace(/(\.[a-z]+)$/, "-moved$1");
    const mk = (tag) => {
      const s = F.setupStage(`${tag}-${stage}`, stage, F.TERM);
      F.commit(s.repo, "fixture: target");
      return s;
    };
    let s = mk("del");
    const empty = fp(scope, s.sid, stage, s.repo);
    F.git(s.repo, ["rm", "-q", "--", file]);
    const del = fp(scope, s.sid, stage, s.repo);
    F.check(`R-S ${stage}: a staged deletion enters the artifact component`,
      del.ok && empty.ok && del.inputs.artifact !== empty.inputs.artifact, `${empty.inputs.artifact} ${del.inputs.artifact}`);
    s = mk("mv");
    F.git(s.repo, ["mv", "--", file, moved]);
    const mv = fp(scope, s.sid, stage, s.repo);
    s = mk("copy");
    F.stageFile(s.repo, moved, F.targetBody(stage, F.TERM));
    const copy = fp(scope, s.sid, stage, s.repo);
    F.check(`R-S ${stage}: git mv carries the source as deleted (--no-renames)`,
      mv.ok && copy.ok && mv.inputs.artifact !== copy.inputs.artifact, `${mv.inputs.artifact} ${copy.inputs.artifact}`);
  }
  const s = F.setupStage("mv-glossary", "docs", F.TERM, { stageTarget: false });
  F.git(s.repo, ["mv", "--", "docs/glossary/user.md", "docs/glossary/user-a-m.md"]);
  const paths = artifactPaths(scope, s.sid, "docs", s.repo) || [];
  F.check("R-S docs: a glossary git mv shows the moved-from path", paths.includes("docs/glossary/user.md") &&
    paths.includes("docs/glossary/user-a-m.md"), JSON.stringify(paths));
}

function classification(scope) {
  const want = { "tests/x.sh": "tests", "tests/notes.md": "tests", "docs/guide.md": "docs", "README.md": "docs",
    "CHANGELOG.md": "docs", "src/a.js": "code", "docs/img.png": "code", "hooks/notes.md": "code" };
  for (const [p, stage] of Object.entries(want)) {
    F.check(`classifyStageFile(${p}) = ${stage}`, scope.classifyStageFile(p) === stage, String(scope.classifyStageFile(p)));
  }
  const s = F.setupStage("classify", "code", F.TERM, { stageTarget: false });
  for (const p of Object.keys(want)) F.stageFile(s.repo, p, p.endsWith(".png") ? "png" : `# ${p}\n`);
  const seen = {};
  for (const stage of F.RS_STAGES) {
    const paths = artifactPaths(scope, s.sid, stage, s.repo) || [];
    const expected = Object.keys(want).filter((p) => want[p] === stage).sort();
    F.check(`staged set split: ${stage} holds exactly its class`, paths.join(",") === expected.join(","), JSON.stringify(paths));
    for (const p of paths) seen[p] = (seen[p] || 0) + 1;
  }
  F.check("staged set split: no path is in two stages", Object.values(seen).every((n) => n === 1), JSON.stringify(seen));
}

function failClosed(scope, record) {
  const notRepo = F.slash(fs.mkdtempSync(path.join(os.tmpdir(), "g2529-norepo-")));
  for (const stage of F.RS_STAGES) {
    const s = F.setupStage(`unavail-${stage}`, stage, F.TERM);
    F.check(`${stage}: a non-git repoDir makes the fingerprint unavailable`,
      scope.stageFingerprint(s.sid, stage, { repoDir: notRepo }).ok === false, "ok");
    F.drift(s.sid, stage, s.repo);
    const v = record.evaluateGlossaryCheck(s.sid, F.STAGE_STEP[stage], F.readState(s.sid), { repoDir: notRepo });
    F.check(`${stage}: evaluateGlossaryCheck fails closed with glossary-fingerprint-unavailable`,
      v && v.ok === false && v.code === "glossary-fingerprint-unavailable", JSON.stringify(v));
  }
  // opts.repoDir outranks the process cwd.
  const a = F.setupStage("prio-a", "code", F.TERM);
  const b = F.mkRepo("prio-b");
  F.stageFile(b, "src/b.js", F.targetBody("code", F.TERM));
  const prev = process.cwd();
  process.chdir(a.repo);
  let paths;
  try { paths = artifactPaths(scope, a.sid, "code", b); } finally { process.chdir(prev); }
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
