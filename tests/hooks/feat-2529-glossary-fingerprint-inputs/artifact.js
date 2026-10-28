"use strict";
// T7-1 (input 1, artifact): one byte inside the scanned range stales the record for all six
// stages (plan bytes for R-A, the staged blob for R-S). Range identity: ## Issues is outside
// both the scan and the fingerprint, and the recorded artifact digest is the sha256 of the
// exact text that was scanned — the same bytes the approval sha covers.

const F = require("../../lib/glossary-check-fixture");
const C = require("./common");

function mutateArtifact(ctx) {
  const { stage, sid, repo } = ctx;
  if (F.RS_STAGES.includes(stage)) {
    return () => F.stageFile(repo, F.TARGET[stage], F.targetBody(stage, F.VARIANT).replace("checked", "checkeD"));
  }
  return () => F.writePlan(sid, stage, F.planBody(stage, F.VARIANT).replace("checked.", "checked!"));
}

function oneByte(m, stages = F.STAGES) {
  for (const stage of stages) {
    const ctx = C.baseline(m, `t71-${stage}`, stage);
    C.cycle(m, ctx, "one artifact byte changed", "artifact", mutateArtifact(ctx));
  }
}

function issuesRange(m) {
  const ctx = C.baseline(m, "t71-issues", "intent");
  const body = F.planBody("intent", F.VARIANT);
  C.unchanged(m, ctx, "an edit only inside ## Issues", () =>
    F.writePlan(ctx.sid, "intent", body.replace("- #1 fixture\n", "- #1 fixture\n- #2 backfilled title\n")));

  const repo = F.mkRepo("t71-issues-only");
  const clean = F.planBody("intent", F.TERM);
  const sid = F.seedSession("t71-issues-only", "intent", { cwd: repo,
    intentBody: clean.replace("- #1 fixture\n", `- #1 fixture ${F.VARIANT} title\n`) });
  const only = F.drift(sid, "intent", repo, false);
  F.check("intent: a variant only inside ## Issues is not DRIFT",
    only.code === 0 && !/DRIFT:/.test(only.out), `${only.code} ${only.out} ${only.err}`);
  F.writePlan(sid, "intent", clean.replace("## Goal\n\nEach workflow step", `## Goal\n\nEach ${F.VARIANT}`));
  const goal = F.drift(sid, "intent", repo, false);
  F.check("intent: the same variant inside ## Goal is DRIFT",
    goal.code === 1 && /DRIFT: \S+ "/.test(goal.out) && goal.out.includes(F.VARIANT), `${goal.code} ${goal.out} ${goal.err}`);
}

// The digest recorded for input 1 is sha256 of the scanned text, and equals the approval sha.
function scannedBytes(m) {
  for (const stage of F.RA_STAGES) {
    const ctx = C.baseline(m, `t71-bytes-${stage}`, stage);
    const inputs = m.scope.loadStageInputs(ctx.sid, stage, { repoDir: ctx.repo });
    const files = inputs && inputs.ok ? inputs.artifact.files : [];
    const text = files.length === 1 ? files[0].text : null;
    const rec = F.recordOf(ctx.sid, stage);
    const digest = text == null ? null : F.sha256(Buffer.from(text, "utf8"));
    F.check(`${stage}: sha256 of the scanned artifact text equals the recorded inputs.artifact`,
      !!digest && !!rec && rec.inputs && rec.inputs.artifact === digest, JSON.stringify({ digest, rec }));
    F.check(`${stage}: the scanned range is the approval range (implSha)`,
      !!digest && digest === F.implSha(ctx.sid, F.STAGE_STEP[stage]), `${digest} ${F.implSha(ctx.sid, F.STAGE_STEP[stage])}`);
    if (stage === "intent") {
      F.check("intent: the scanned text excludes ## Issues", !!text && !text.includes("- #1 fixture"), JSON.stringify(text));
    }
  }
}

// Section entry points, so entry files can split the sections across processes.
const runOneByte = C.withModules(oneByte);
const runIssuesRange = C.withModules(issuesRange);
const runScannedBytes = C.withModules(scannedBytes);

function run() {
  runOneByte();
  runIssuesRange();
  runScannedBytes();
}

module.exports = { run, runOneByte, runIssuesRange, runScannedBytes };
