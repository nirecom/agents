"use strict";
// T6-7: the per-commit lifetime of an R-S record across a multi-commit workflow. A commit
// without the stage's target is not judged; a later commit with a new target needs a fresh
// --record; an empty index blocks no R-S stage; plan stages are outside the commit gate; a
// glossary-only change blocks only commits that carry a target, naming the glossary component.

const F = require("../../lib/glossary-check-fixture");

const CHECKER = "hooks/workflow-gate/glossary-record-checker.js";
// A staged change that belongs to none of the stage's target class.
const OTHER = { tests: "src/other.js", code: "tests/other.sh", docs: "src/other.js" };
const SECOND = { tests: "tests/t2.sh", code: "src/b.js", docs: "docs/guide2.md" };

function forStage(checker, stage) {
  const step = F.STAGE_STEP[stage];
  const label = `lifecycle ${stage}`;
  const s = F.setupStage(`life-${stage}`, stage, F.TERM);
  const rec = F.drift(s.sid, stage, s.repo);
  F.check(`${label}: commit 1 --record exits 0`, rec.code === 0, `exit=${rec.code} ${rec.err}`);
  const done = F.completeInProcess(s.sid, step, s.repo);
  F.check(`${label}: commit 1 completes ${step}`, done.ok === true, JSON.stringify(done));
  let g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: commit 1 passes the gate`, F.gatePasses(g), JSON.stringify(g));
  F.commit(s.repo, "fixture: commit 1");

  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: an empty index blocks no R-S stage`, F.gatePasses(g), JSON.stringify(g));

  F.stageFile(s.repo, OTHER[stage], stage === "code" ? "#!/usr/bin/env bash\nexit 0\n" : "module.exports = 2;\n");
  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: commit 2 without a ${stage} target is not judged`, F.gatePasses(g), JSON.stringify(g));
  F.commit(s.repo, "fixture: commit 2");

  F.stageFile(s.repo, SECOND[stage], F.targetBody(stage, F.TERM));
  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: commit 3 with a new target blocks glossary-check-stale`, F.gateBlocks(g, "glossary-check-stale"), JSON.stringify(g));
  F.check(`${label}: commit 3 block names the recovery`, !!g && String(g.reason).includes(`check-glossary-drift --stage ${stage} --record`),
    JSON.stringify(g));
  F.drift(s.sid, stage, s.repo);
  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: commit 3 passes after --record`, F.gatePasses(g), JSON.stringify(g));
  F.commit(s.repo, "fixture: commit 3");

  F.touchGlossary(s.repo);
  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: glossary-only change, empty target commit passes`, F.gatePasses(g), JSON.stringify(g));
  F.stageFile(s.repo, F.TARGET[stage], F.targetBody(stage, "review scope"));
  g = F.gateCheck(checker, s.sid, step, s.repo);
  F.check(`${label}: glossary change with a target blocks naming the glossary component`,
    F.gateBlocks(g, "glossary-check-stale") && /\bglossary\b/.test(String(g.reason).replace(/glossary-check-stale|check-glossary-drift/g, "")),
    JSON.stringify(g));
}

function run() {
  const checker = F.mod(CHECKER);
  if (!checker) return;
  for (const stage of F.RS_STAGES) forStage(checker, stage);
  const s = F.setupStage("life-plan", "detail", F.VARIANT);
  for (const stage of F.RA_STAGES) {
    const g = F.gateCheck(checker, s.sid, F.STAGE_STEP[stage], s.repo);
    F.check(`lifecycle: plan stage ${stage} is outside the commit gate`, F.gatePasses(g), JSON.stringify(g));
  }
  for (const step of ["workflow_init", "write_code", "run_tests"]) {
    const g = F.gateCheck(checker, s.sid, step, s.repo);
    F.check(`lifecycle: non-glossary step ${step} passes`, F.gatePasses(g), JSON.stringify(g));
  }
}

module.exports = { run };
