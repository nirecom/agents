"use strict";
// --reset / --mark subcommands for bin/workflow/next-step. Each owns its own
// output and process.exit, so the entrypoint stays dispatch-only.

const { resolveSessionId } = require("../../../../hooks/workflow-state");
const { confirmSentinelFor } = require("../../../../hooks/workflow-state/completion-approval");
// #1644: --reset and --mark are declarations too, so they go through the same
// single writer. Their own gates keep the narrower side-effect set they have
// today — no A-4 co-write, no workflow_init downstream reset.
const { recordStepVerdict } = require("../../../../hooks/workflow-state/record-step-verdict");

function runReset(session, step) {
  const sid = resolveSessionId({ sessionIdFromInput: session });
  if (!sid) {
    process.stderr.write("next-step: could not resolve session id\n");
    process.exit(1);
  }
  const res = recordStepVerdict(sid, step, "pending", { gate: "reset" });
  if (!res.ok) {
    process.stderr.write("next-step: --reset failed — " + (res.detail || res.message) + "\n");
    process.exit(1);
  }
  process.stdout.write("RESET=" + step + " status=pending\n");
  process.exit(0);
}

function runMark(session, step) {
  if (!session || !/^[A-Za-z0-9_-]+$/.test(session)) {
    process.stderr.write("next-step: --mark requires a valid --session value\n");
    process.exit(1);
  }
  const sid = resolveSessionId({ sessionIdFromInput: session });
  if (!sid) {
    process.stderr.write("next-step: could not resolve session id\n");
    process.exit(1);
  }
  // Deliberately NOT sanctioned: --reason/--mark is model-issued free text and
  // must never be approval-equivalent. Gated steps go through the same approval
  // invariant as every other write path (#1133) and fail closed here.
  const res = recordStepVerdict(sid, step, "complete", { gate: "mark" });
  if (!res.ok && res.kind === "unapproved") {
    process.stderr.write(
      "next-step: --mark " + step + " complete refused — " + res.detail + ".\n" +
      "  " + step + " requires recorded user approval; --mark cannot grant it.\n" +
      "  Ask the user to approve, then emit: echo \"<<" +
        confirmSentinelFor(step) + ": {summary}>>\"\n"
    );
    process.exit(1);
  }
  if (!res.ok) {
    process.stderr.write("next-step: --mark failed — " + (res.detail || res.message) + "\n");
    process.exit(1);
  }
  process.stdout.write("MARK=" + step + " status=complete\n");
  process.exit(0);
}

module.exports = { runReset, runMark };
