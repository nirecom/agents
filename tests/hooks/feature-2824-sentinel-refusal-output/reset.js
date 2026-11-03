"use strict";
// reset-handler (#2824 Step 2): every refusal is UNAPPLIED; an applied reset reports, as INFO, that
// the target step and later went back to pending (it was silent before). The session-less reset
// (#526) is covered in dispatch.js.

const fs = require("node:fs");
const path = require("node:path");

const R = (step, reason) => (reason === undefined
  ? `echo "<<WORKFLOW_RESET_FROM_${step}>>"` : `echo "<<WORKFLOW_RESET_FROM_${step}: ${reason}>>"`);
const WHY = "rework the plan from here";

function refusals(X) {
  X.F.setConfig("on", "on", "on");
  const sid = X.seedInit("rs");
  X.expectUnapplied("malformed (bare)", sid, R("write_code"), /malformed RESET_FROM/);
  X.expectUnapplied("reason rejected", sid, R("write_code", "x"), /RESET_FROM rejected/);
  X.expectUnapplied("unknown step", sid, R("bogus", WHY), /unknown step "bogus"/);
  X.expectUnapplied("no readable state", X.nextSid("rs-none"), R("write_code", WHY), /no readable workflow state/);
  const gated = X.F.seedWf("rs-gate", ["clarify_intent"]);
  X.expectUnapplied("prior gate refused", gated, R("detail", WHY), /RESET_FROM_detail refused/);
  X.check();
}

// The "reset-from failed" catch: the state reads fine, but its lock is held (a fresh lock file whose
// holder cannot be judged stale), so appendEvents times out and the error reaches the outer catch.
function failed(X) {
  X.F.setConfig("on", "on", "on");
  const sid = X.F.seedWf("rs-fail", ["clarify_intent", "outline", "detail"]);
  const lock = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json.lock`);
  fs.writeFileSync(lock, "held by the f2824 reset fixture");
  try {
    X.expectUnapplied("lock held -> failed", sid, R("write_code", WHY), /reset-from failed/);
  } finally {
    fs.rmSync(lock, { force: true });
  }
  if (X.F.events(sid, "reset").length !== 0) X.record("lock held -> failed", "a reset event was recorded");
  X.check();
}

function applied(X) {
  X.F.setConfig("on", "on", "on");
  const sid = X.F.seedWf("rs-ok", ["clarify_intent", "outline", "detail"]);
  X.expectInfo("applied reset", sid, R("write_code", WHY), /write_code[^\n]*pending|pending[^\n]*write_code/i);
  if (X.F.events(sid, "reset").length !== 1) X.record("applied reset", "no reset event recorded");
  X.check();
}

module.exports = { refusals, failed, applied };
