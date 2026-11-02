"use strict";
// T7-1 (input 1, artifact): one byte inside the scanned range stales the record for all six
// glossary steps (plan bytes for R-A, the staged blob for R-S). Range identity: ## Issues is outside
// both the scan and the fingerprint, and the recorded artifact digest is the sha256 of the
// exact text that was scanned — the same bytes the approval sha covers.

const F = require("../../lib/glossary-check-fixture");
const C = require("./common");

function mutateArtifact(ctx) {
  const { step, sid, repo } = ctx;
  if (F.RS_STEPS.includes(step)) {
    return () => F.stageFile(repo, F.TARGET[step], F.targetBody(step, F.VARIANT).replace("checked", "checkeD"));
  }
  const artifact = F.ARTIFACT_OF[step];
  return () => F.writePlan(sid, artifact, F.planBody(artifact, F.VARIANT).replace("checked.", "checked!"));
}

function oneByte(m, steps = F.GLOSSARY_STEPS) {
  for (const step of steps) {
    const ctx = C.baseline(m, `t71-${step}`, step);
    C.cycle(m, ctx, "one artifact byte changed", "artifact", mutateArtifact(ctx));
  }
}

function issuesRange(m) {
  const ctx = C.baseline(m, "t71-issues", "clarify_intent");
  const body = F.planBody("intent", F.VARIANT);
  C.unchanged(m, ctx, "an edit only inside ## Issues", () =>
    F.writePlan(ctx.sid, "intent", body.replace("- #1 fixture\n", "- #1 fixture\n- #2 backfilled title\n")));

  const repo = F.mkRepo("t71-issues-only");
  const clean = F.planBody("intent", F.TERM);
  const sid = F.seedSession("t71-issues-only", "clarify_intent", { cwd: repo,
    intentBody: clean.replace("- #1 fixture\n", `- #1 fixture ${F.VARIANT} title\n`) });
  const only = F.drift(sid, "clarify_intent", repo, false);
  F.check("clarify_intent: a variant only inside ## Issues is not DRIFT",
    only.code === 0 && !/DRIFT:/.test(only.out), `${only.code} ${only.out} ${only.err}`);
  F.writePlan(sid, "intent", clean.replace("## Goal\n\nEach workflow step", `## Goal\n\nEach ${F.VARIANT}`));
  const goal = F.drift(sid, "clarify_intent", repo, false);
  F.check("clarify_intent: the same variant inside ## Goal is DRIFT",
    goal.code === 1 && /DRIFT: \S+ "/.test(goal.out) && goal.out.includes(F.VARIANT), `${goal.code} ${goal.out} ${goal.err}`);
}

// The digest recorded for input 1 is sha256 of the scanned text, and equals the approval sha.
function scannedBytes(m) {
  for (const step of F.RA_STEPS) {
    const ctx = C.baseline(m, `t71-bytes-${step}`, step);
    const inputs = m.scope.loadStepInputs(ctx.sid, step, { repoDir: ctx.repo });
    const files = inputs && inputs.ok ? inputs.artifact.files : [];
    const text = files.length === 1 ? files[0].text : null;
    const rec = F.recordOf(ctx.sid, step);
    const digest = text == null ? null : F.sha256(Buffer.from(text, "utf8"));
    F.check(`${step}: sha256 of the scanned artifact text equals the recorded inputs.artifact`,
      !!digest && !!rec && rec.inputs && rec.inputs.artifact === digest, JSON.stringify({ digest, rec }));
    F.check(`${step}: the scanned range is the approval range (implSha)`,
      !!digest && digest === F.implSha(ctx.sid, step), `${digest} ${F.implSha(ctx.sid, step)}`);
    if (step === "clarify_intent") {
      F.check("clarify_intent: the scanned text excludes ## Issues", !!text && !text.includes("- #1 fixture"), JSON.stringify(text));
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
