"use strict";
// workflow-mark.js dispatch (#2824 Step 1): a sentinel that never reaches a handler still names why.
// Mixed command, non-zero echo and a subagent sentinel are UNAPPLIED with the state unchanged;
// the session-less RESET_FROM stays INFO (#526: recovery must not hard-fail); a command without a
// sentinel stays silent, from a subagent or with a non-zero exit too.
// Not covered: "no handler claimed the sentinel" — every sentinel the pattern set recognises has a
// handler today, so no input reaches that branch without a stub handler (no stub source is made).

const MARK_RESEARCH = 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"';

function unapplied(X) {
  const sid = X.seedInit("dp");
  X.expectUnapplied("mixed command", sid, `${MARK_RESEARCH} && ls`, /sentinel/i);
  X.expectUnapplied("echo exited 1", sid, MARK_RESEARCH, /exited 1/i, { exitCode: 1 });
  X.expectUnapplied("subagent sentinel", sid, MARK_RESEARCH, /(subagent|fork)[\s\S]*main conversation/i, { agentId: "a1" });
  X.check();
}

function info(X) {
  X.expectInfo("#526 reset without session", null, 'echo "<<WORKFLOW_RESET_FROM_write_code: rework the plan from here>>"',
    /could not resolve session_id/, { noSession: true });
  const none = X.seedInit("dp-none");
  X.expectSilent("no sentinel", none, "ls -la");
  // The subagent verdict needs a sentinel: a subagent's plain command and a failed plain command stay silent.
  X.expectSilent("subagent without a sentinel", none, "ls -la", { agentId: "a1" });
  X.expectSilent("no sentinel, exit 1", none, "ls", { exitCode: 1 });
  X.check();
}

// mixed: one && chain whose first sentinel is applied (INFO) and whose second is refused (UNAPPLIED).
// Through handler -> flush both reach the strong channel, told apart by the prefix: the refused line
// carries [NOT APPLIED], the applied line does not, and the applied part stays recorded.
function mixed(X) {
  const O = require("../../lib/workflow-mark-output");
  const { seedUnrunnable } = require("./run-tests-accept");
  const sid = seedUnrunnable(X, "dp-mix");
  const ok = 'echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 cannot be installed on this host>>"';
  const bad = 'echo "<<WORKFLOW_MARK_STEP_bogus_step_complete>>"';
  const r = X.mark(sid, `${ok} && ${bad}`);
  const label = "applied + refused in one command";
  try {
    const why = O.unappliedFailure(r, /unknown step "bogus_step"/);
    if (why) X.record(label, why);
    else {
      const body = O.strongChannel() === "exit2" ? String(r.stderr) : O.parseStdout(r.stdout).reason;
      const line = (needle) => body.split("\n").find((l) => l.includes(needle)) || "";
      const refused = line("bogus_step");
      const accepted = line("RUN_TESTS_UNRUNNABLE_ACCEPTED: run_tests complete");
      if (!refused.includes(O.PREFIX)) X.record(label, `refused line lacks ${O.PREFIX}: ${JSON.stringify(body)}`);
      if (accepted === "" || accepted.includes(O.PREFIX)) X.record(label, `applied line missing or prefixed: ${JSON.stringify(body)}`);
    }
  } catch (e) { X.record(label, e.message); }
  const st = ((X.F.S.readState(sid) || {}).steps || {}).run_tests || {};
  if (st.status !== "complete") X.record(label, `the applied part was not kept: run_tests is ${st.status}`);
  X.check();
}

module.exports = { unapplied, info, mixed };
