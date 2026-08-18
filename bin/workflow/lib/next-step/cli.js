"use strict";
// Argument parsing and usage output for bin/workflow/next-step.
// Owns ALL argument validation: unknown options, missing values, step-name
// validation for --reset/--mark, and the --session format check.

const { VALID_STEPS } = require("../../../../hooks/workflow-state");
// Settling-status vocabulary (value-less --complete/--skipped/--pending, #1947)
// is shared with bin/workflow/set-workflow-type — single owner, no local copy.
const {
  ADVANCE_STATUSES, matchStatusFlag, formatStatusFlagList,
  formatStatusRejection, warnDeprecatedStatusValue,
} = require("./advance-args");

function printUsage() {
  process.stdout.write(
    "Usage: next-step [--session <sid>] [--list]\n" +
    "\n" +
    "Deterministic workflow next-step advisor. Reads session state and emits the next\n" +
    "workflow step as four KEY=value lines on stdout (ACTION, NEXT_SKILL,\n" +
    "NEXT_HINT, REASON), plus an optional advisory SKIP_HINT line at the\n" +
    "outline/detail steps. Always exits 0 in next-step mode; --reset exits nonzero on invalid input.\n" +
    "\n" +
    "Options:\n" +
    "  --session <sid>   Use the given session id instead of resolving one.\n" +
    "  --list            Print the workflow plan (one row per VALID_STEPS entry,\n" +
    "                    ending with the terminal final_report row), with status markers\n" +
    "                    when --session is provided.\n" +
    "  --reset <step>    Reset a workflow step to pending (recovery tool).\n" +
    "  --mark <step>     Mark a workflow step as complete (recovery tool).\n" +
    "                    --complete is accepted and redundant.\n" +
    "  --advance         Record a step verdict in this same call (forward operation).\n" +
    "                    Requires --step <step> and one of " + formatStatusFlagList() + ";\n" +
    "                    --skip-reason <text> is required with --skipped.\n" +
    "                    Exclusive with --list / --reset / --mark.\n" +
    "  --next            With --advance: also emit the ACTION block, but only when\n" +
    "                    the settled step was the session's current step.\n" +
    "  -h, --help        Show this help.\n" +
    "\n" +
    "Deprecated but accepted: --status <status>, --mark <step> complete.\n"
  );
}

function parseArgs(argv) {
  const out = {
    list: false, session: undefined, reset: undefined, mark: undefined,
    advance: false, next: false,
    advanceStep: undefined, advanceStatus: undefined, skipReason: undefined,
    // Diagnostic only: the literal token the caller typed for the status, so a
    // refusal can name the spelling in front of them.
    advanceStatusFlag: undefined,
  };
  const needValue = (i, flag) => {
    if (i + 1 >= argv.length) {
      process.stderr.write("next-step: " + flag + " requires an argument\n");
      process.exit(1);
    }
    return argv[i + 1];
  };
  // Old form frozen, new form strict: `--status a --status b` is pre-existing
  // last-wins behaviour external callers may depend on, but any supply pair
  // involving a value-less flag is a shape only expressible since #1947, has no
  // priority rule between its two sources, and so fails closed.
  const setStatus = (out2, statusValue, sourceToken) => {
    const newFormInvolved =
      matchStatusFlag(sourceToken) !== null || matchStatusFlag(out2.advanceStatusFlag) !== null;
    if (out2.advanceStatus !== undefined && newFormInvolved) {
      process.stderr.write(
        "next-step: advance status given more than once (" + out2.advanceStatusFlag +
        " and " + sourceToken + ") — pass exactly one\n"
      );
      process.exit(1);
    }
    out2.advanceStatus = statusValue;
    out2.advanceStatusFlag = sourceToken;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      printUsage();
      process.exit(0);
    } else if (a === "--list") {
      out.list = true;
    } else if (a === "--reset") {
      if (i + 1 >= argv.length) {
        process.stderr.write("next-step: --reset requires a step argument\n");
        process.exit(1);
      }
      const stepName = argv[i + 1];
      if (VALID_STEPS.indexOf(stepName) === -1) {
        process.stderr.write("next-step: invalid step for --reset: " + stepName + "\n");
        process.exit(1);
      }
      out.reset = stepName;
      i++;
    } else if (a === "--mark") {
      if (i + 1 >= argv.length) {
        process.stderr.write("next-step: --mark requires a <step> argument\n");
        process.exit(1);
      }
      const stepName = argv[i + 1];
      if (VALID_STEPS.indexOf(stepName) === -1) {
        process.stderr.write("next-step: invalid step for --mark: " + stepName + "\n");
        process.exit(1);
      }
      out.mark = stepName;
      // One-token lookahead (same shape as record-skip-judgment's parseFlagBool):
      // step names never start with `--`, and the only legacy status token --mark
      // ever accepted is the literal `complete`, so the reading is unambiguous.
      const statusToken = argv[i + 2];
      if (statusToken !== undefined && !statusToken.startsWith("--")) {
        if (statusToken !== "complete") {
          process.stderr.write("next-step: --mark status must be 'complete'\n");
          process.exit(1);
        }
        process.stderr.write(
          "next-step: the trailing 'complete' token on --mark is deprecated — use --mark " +
          stepName + " (a bare \"complete\" argv token trips worktree-isolation " +
          "command classifiers)\n"
        );
        i += 2;
      } else {
        i += 1;
      }
    } else if (a === "--advance") {
      out.advance = true;
    } else if (a === "--next") {
      out.next = true;
    } else if (a === "--step") {
      out.advanceStep = needValue(i, "--step");
      i++;
    } else if (a === "--status") {
      const v = needValue(i, "--status");
      setStatus(out, v, "--status");
      warnDeprecatedStatusValue("next-step", v);
      i++;
    } else if (a === "--skip-reason") {
      out.skipReason = needValue(i, "--skip-reason");
      i++;
    } else if (a === "--session") {
      if (i + 1 >= argv.length) {
        process.stderr.write("next-step: --session requires an argument\n");
        process.exit(1);
      }
      out.session = argv[i + 1];
      i++;
    } else if (matchStatusFlag(a) !== null) {
      // Placed AFTER every exact-match branch above so no existing flag is shadowed.
      setStatus(out, matchStatusFlag(a), a);
    } else {
      process.stderr.write("next-step: unknown option: " + a + "\n");
      process.exit(1);
    }
  }
  // --session format validation. Placed at the END of parseArgs so the relative
  // order is unchanged from when it lived at the top of main(): --help already
  // exited inside the loop above, and every subcommand dispatch happens after
  // parseArgs returns.
  if (out.session !== undefined && out.session !== "" && !/^[A-Za-z0-9_-]+$/.test(out.session)) {
    process.stderr.write("next-step: invalid --session value — must match [A-Za-z0-9_-]+\n");
    process.exit(1);
  }
  validateAdvanceArgs(out);
  return out;
}

// All --advance validation, kept out of the parse loop so the frozen
// --list / --reset / --mark diagnostics above stay untouched.
function validateAdvanceArgs(out) {
  const die = (msg) => {
    process.stderr.write("next-step: " + msg + "\n");
    process.exit(1);
  };
  if (out.next && !out.advance) die("--next is only meaningful with --advance");
  if (!out.advance) {
    if (out.advanceStep !== undefined) die("--step is only meaningful with --advance");
    if (out.advanceStatus !== undefined) validateStatusWithoutAdvance(out, die);
    if (out.skipReason !== undefined) die("--skip-reason is only meaningful with --advance");
    return;
  }
  if (out.list || out.reset !== undefined || out.mark !== undefined) {
    die("--advance cannot be combined with --list / --reset / --mark");
  }
  if (out.advanceStep === undefined) die("--advance requires --step <step>");
  if (VALID_STEPS.indexOf(out.advanceStep) === -1) {
    die("invalid step for --advance: " + out.advanceStep);
  }
  if (out.advanceStatus === undefined) {
    die("--advance requires a status: " + formatStatusFlagList() + " (deprecated: --status <status>)");
  }
  if (ADVANCE_STATUSES.indexOf(out.advanceStatus) === -1) {
    // Named explicitly so the refusal reads as a status rejection, never as an
    // unknown-flag error: --status in_progress is a real flag with a real answer.
    die(formatStatusRejection(out.advanceStatus));
  }
  if (out.advanceStatus === "skipped" && (out.skipReason === undefined || out.skipReason === "")) {
    die("--advance --skipped requires --skip-reason <text>");
  }
}

// A status supplied without --advance. --mark is the single exception: it is the
// recovery tool reached mid-breakage, and `--mark <step> --complete` is what the
// new vocabulary invites a caller to type, so it is accepted as redundant rather
// than stranding them. --skipped/--pending stay refused — --mark only completes.
function validateStatusWithoutAdvance(out, die) {
  const flag = out.advanceStatusFlag;
  if (out.mark !== undefined && matchStatusFlag(flag) !== null) {
    if (out.advanceStatus === "complete") return;
    die(
      "--mark only marks a step complete; " + flag + " is not applicable " +
      "(use --advance --step " + out.mark + " " + flag + ")"
    );
  }
  die(flag + " is only meaningful with --advance (or --mark <step> --complete)");
}

module.exports = { printUsage, parseArgs };
