"use strict";
// T7-2 (input 2, combined glossary): each glossary change below stales the record for all six
// stages; a newly added heading surfaces DRIFT on rescan; a linked worktree reads the main
// worktree's glossary (first line of git worktree list); a repo with no glossary files records
// an empty digest without error.

const fs = require("node:fs");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");
const C = require("./common");

const USER = "docs/glossary/user.md";
const INTERNAL = "docs/glossary/internal.md";
const abs = (repo, rel) => path.join(repo, ...rel.split("/"));
const read = (repo, rel) => fs.readFileSync(abs(repo, rel), "utf8");
const HEADING = "\n### release gate\n\n- **Definition**: A fixture gate.\n";

// Applied in order to one repo; every state keeps the "workflow step" heading, so the finding
// (and its grant cycle) survives each step.
function mutations(repo) {
  let internal = F.GLOSSARY_FILES[INTERNAL];
  return [
    ["one user definition character", () => F.touchGlossary(repo, "!")],
    ["one internal definition character", () => {
      internal = internal.replace("review covers.", "review covers!");
      F.writeFile(repo, INTERNAL, internal);
    }],
    ["an added heading", () => { internal += HEADING; F.writeFile(repo, INTERNAL, internal); }],
    ["a removed glossary file", () => fs.rmSync(abs(repo, INTERNAL))],
    ["an added glossary file", () => F.writeFile(repo, INTERNAL, internal)],
    ["a range-split move of the user file", () =>
      fs.renameSync(abs(repo, USER), abs(repo, "docs/glossary/user-a-z.md"))],
    ["a switch to the legacy paths", () => {
      F.writeFile(repo, "docs/glossary-user.md", read(repo, "docs/glossary/user-a-z.md"));
      F.writeFile(repo, "docs/glossary-internal.md", internal);
      fs.rmSync(abs(repo, "docs/glossary"), { recursive: true, force: true });
    }],
  ];
}

function eachChange(m, stages = F.STAGES) {
  for (const stage of stages) {
    const ctx = C.baseline(m, `t72-${stage}`, stage);
    for (const [label, mutate] of mutations(ctx.repo)) C.cycle(m, ctx, label, "glossary", mutate);
    const inputs = m.scope.loadStageInputs(ctx.sid, stage, { repoDir: ctx.repo });
    F.check(`${stage}: the legacy switch is reported as glossary.legacy`,
      !!inputs && inputs.ok && inputs.glossary.legacy === true, JSON.stringify(inputs && inputs.glossary));
  }
}

function headingSurfacesDrift(stages = F.STAGES) {
  for (const stage of stages) {
    const s = F.setupStage(`t72-head-${stage}`, stage, "release-gate");
    const first = F.drift(s.sid, stage, s.repo, false);
    F.check(`${stage}: release-gate is not DRIFT before its heading exists`,
      first.code === 0 && !/DRIFT:/.test(first.out), `${first.code} ${first.out} ${first.err}`);
    F.writeFile(s.repo, INTERNAL, F.GLOSSARY_FILES[INTERNAL] + HEADING);
    const again = F.drift(s.sid, stage, s.repo, false);
    F.check(`${stage}: the added heading makes release-gate DRIFT on rescan`,
      again.code === 1 && /DRIFT: \S+ "/.test(again.out) && again.out.includes("release-gate"),
      `${again.code} ${again.out} ${again.err}`);
  }
}

function linkedWorktree(m) {
  const main = F.mkRepo("t72-main");
  const wt = F.addWorktree(main, "t72");
  F.stageFile(wt, F.TARGET.code, F.targetBody("code", F.VARIANT));
  const ctx = { sid: F.seedSession("t72-wt", "code", { cwd: wt }), repo: wt, stage: "code" };
  C.recordAndGrant(m, ctx, "linked worktree baseline");
  C.unchanged(m, ctx, "an unstaged glossary edit in the linked worktree", () => F.touchGlossary(wt, "?"));
  C.cycle(m, ctx, "a glossary edit in the main worktree (read from the linked worktree)", "glossary",
    () => F.touchGlossary(main, "!"));
}

function noGlossary(m) {
  const repo = F.mkRepo("t72-none");
  F.git(repo, ["rm", "-r", "-q", "--", "docs/glossary"]);
  F.commit(repo, "fixture: no glossary");
  F.stageFile(repo, F.TARGET.code, F.targetBody("code", F.TERM));
  const ctx = { sid: F.seedSession("t72-none", "code", { cwd: repo }), repo, stage: "code" };
  const inputs = m.scope.loadStageInputs(ctx.sid, "code", { repoDir: repo });
  F.check("no glossary files: loadStageInputs succeeds with no files and no terms",
    !!inputs && inputs.ok && inputs.glossary.files.length === 0 && [...(inputs.glossary.terms || [])].length === 0,
    JSON.stringify(inputs));
  const r = F.drift(ctx.sid, "code", repo);
  const rec = F.recordOf(ctx.sid, "code");
  F.check("no glossary files: --record succeeds", r.code === 0, `${r.code} ${r.out} ${r.err}`);
  F.check("no glossary files: the record carries a 64-hex glossary digest",
    !!rec && rec.inputs && /^[0-9a-f]{64}$/.test(rec.inputs.glossary || ""), JSON.stringify(rec));
  F.check("no glossary files: the record is current", C.passes(C.evaluate(m, ctx)), "not ok");
}

// Section entry points, so entry files can split the sections across processes. Only the
// heading section runs without scope.js/record.js, as run() always did.
const runEachChange = C.withModules(eachChange);
const runHeading = (stages) => headingSurfacesDrift(stages);
const runLinkedWorktree = C.withModules(linkedWorktree);
const runNoGlossary = C.withModules(noGlossary);

function run() {
  runEachChange();
  runHeading();
  runLinkedWorktree();
  runNoGlossary();
}

module.exports = { run, runEachChange, runHeading, runLinkedWorktree, runNoGlossary };
