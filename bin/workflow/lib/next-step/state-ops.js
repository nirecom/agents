"use strict";
// --reset / --mark subcommands for bin/workflow/next-step. Each owns its own
// output and process.exit, so the entrypoint stays dispatch-only.

const {
  resolveSessionId,
  markStep,
} = require("../../../../hooks/workflow-state");
const {
  UnapprovedCompletionError,
  confirmSentinelFor,
} = require("../../../../hooks/workflow-state/completion-approval");

function runReset(session, step) {
  const sid = resolveSessionId({ sessionIdFromInput: session });
  if (!sid) {
    process.stderr.write("next-step: could not resolve session id\n");
    process.exit(1);
  }
  markStep(sid, step, "pending");
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
  try {
    markStep(sid, step, "complete");
  } catch (e) {
    if (e instanceof UnapprovedCompletionError) {
      process.stderr.write(
        "next-step: --mark " + step + " complete refused — " + e.code + ".\n" +
        "  " + step + " requires recorded user approval; --mark cannot grant it.\n" +
        "  Ask the user to approve, then emit: echo \"<<" +
          confirmSentinelFor(step) + ": {summary}>>\"\n"
      );
      process.exit(1);
    }
    process.stderr.write("next-step: --mark failed — " + e.message + "\n");
    process.exit(1);
  }
  process.stdout.write("MARK=" + step + " status=complete\n");
  process.exit(0);
}

module.exports = { runReset, runMark };
