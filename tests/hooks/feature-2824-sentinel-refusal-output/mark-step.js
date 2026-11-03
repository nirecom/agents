"use strict";
// mark-step-handler refusals (#2824 Step 2): every "NOT recorded / NOT skipped" path is UNAPPLIED;
// an applied MARK_STEP never reaches the strong channel.
// SKIPPED: downstream-reset-failed. Because: it needs the workflow_init status write to land and the
// next locked write (closeCycleIfFinished / resetDownstreamOfWorkflowInit) to fail in the same run;
// no fixture separates the two writes without a stub.

const O = require("../../lib/workflow-mark-output");

const M = (step, status) => `echo "<<WORKFLOW_MARK_STEP_${step}_${status}>>"`;

function refusals(X) {
  const sid = X.seedInit("ms");
  X.expectUnapplied("user_verification via MARK_STEP", sid, M("user_verification", "complete"), /user_verification NOT recorded/);
  X.expectUnapplied("review_tests via MARK_STEP", sid, M("review_tests", "complete"), /review_tests NOT recorded/);
  X.expectUnapplied("run_tests skip without evidence", sid, M("run_tests", "skipped"), /run_tests NOT skipped/);
  X.expectUnapplied("docs via MARK_STEP", sid, M("docs", "complete"), /docs NOT recorded/);
  X.expectUnapplied("unknown step", sid, M("bogus_step", "complete"), /unknown step "bogus_step"/);
  X.expectUnapplied("outline without approval", sid, M("outline", "complete"), /outline NOT recorded/);
  // Evidence and relayed refusals (RELAYED_KINDS): the repo is pinned to the empty fixture repo.
  const repo = { projectDir: X.REPO };
  X.expectUnapplied("write_tests without staged tests", sid, M("write_tests", "complete"), /write_tests NOT recorded/, repo);
  X.expectUnapplied("run_tests without run evidence (no-run-evidence)", sid, M("run_tests", "complete"),
    /run_tests NOT recorded — a completion needs run evidence/, repo);
  for (const step of ["review_security", "review_docs"]) {
    X.expectUnapplied(`${step} without a glossary check (glossary-incomplete)`, sid, M(step, "complete"),
      new RegExp(`${step} NOT recorded — the glossary check is not complete`), repo);
  }
  X.expectUnapplied("push_branch without a pull request (no-release-evidence)", sid, M("push_branch", "complete"),
    /push_branch NOT recorded/, repo);
  // The "failed to write state" branch: a state file that is not JSON makes the writer fail.
  X.expectUnapplied("state write fails", X.corruptState("ms-corrupt"), M("research", "complete"),
    /failed to write state[\s\S]*"research" NOT recorded/);
  X.check();
}

function applied(X) {
  const sid = X.seedInit("ms-ok");
  const r = X.mark(sid, M("research", "complete"));
  const status = ((X.F.S.readState(sid) || {}).steps || {}).research;
  if (!status || status.status !== "complete") X.record("research applied", `research not complete: ${JSON.stringify(status)}`);
  const out = O.parseStdout(r.stdout) || {};
  if (r.code !== 0 || out.decision !== undefined || (r.stdout + r.stderr).includes(O.PREFIX)) {
    X.record("research applied", `an applied sentinel reached the strong channel: rc=${r.code} ${r.stdout} ${r.stderr}`);
  }
  X.check();
}

module.exports = { refusals, applied };
