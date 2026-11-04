"use strict";
// `adopt-session-state --session <heir> --abort-upstreams` (#2920 S8-(2)): aborts every live
// upstream of the heir, and hands over every abort-sentinel-aborted one, without adopting anything.
// The heir's own state is only read.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const { abortUpstreamsFor } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state.js"));
const { readState } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-io"));

const FLAG = "--abort-upstreams";
// Refusals that mean "nothing left to do", not a failure.
const BENIGN_REASONS = /^(already-aborted|delivered|not-aborted|already-handed-over)$/;

// runAbortUpstreams(heirSid, write) -> exit code. `heirSid` is already validated by the caller.
function runAbortUpstreams(heirSid, write) {
  let results;
  try {
    // An absent or unreadable downstream state selects nothing; "0 upstreams, success" would hide a wrong --session.
    if (!readState(heirSid)) throw new Error("no readable workflow state for this session");
    results = abortUpstreamsFor(heirSid, "abort-cli", `abandoned for ${heirSid}`);
  } catch (e) {
    write(`Could not select the upstreams of ${heirSid}: ${(e && e.message) || String(e)}\n`);
    return 1;
  }
  write(`Upstreams to abort for ${heirSid}: ${results.length}\n`);
  let failed = 0;
  for (const r of results) {
    const verb = r.handover ? "handed over" : "aborted";
    if (r.recorded) write(`  ${verb} ${r.sid}\n`);
    else {
      write(`  not ${verb} ${r.sid} (${r.reason})\n`);
      if (!BENIGN_REASONS.test(String(r.reason))) failed++;
    }
  }
  return failed === 0 ? 0 : 1;
}

module.exports = { FLAG, runAbortUpstreams };
