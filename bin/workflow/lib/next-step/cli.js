"use strict";
// Argument parsing and usage output for bin/workflow/next-step.
// Owns ALL argument validation: unknown options, missing values, step-name
// validation for --reset/--mark, and the --session format check.

const { VALID_STEPS, VALID_STATUSES } = require("../../../../hooks/workflow-state");

// `--advance --status` accepts the three SETTLING statuses. in_progress settles
// nothing, so it is rejected here rather than silently recorded — deliberately
// stricter than the MARK_STEP sentinel path, and never a new bypass route.
const ADVANCE_STATUSES = VALID_STATUSES.filter((s) => s !== "in_progress");

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
    "  --mark <step> complete   Mark a workflow step as complete (recovery tool).\n" +
    "  --advance         Record a step verdict in this same call (forward operation).\n" +
    "                    Requires --step <step> and --status <complete|skipped|pending>;\n" +
    "                    --skip-reason <text> is required with --status skipped.\n" +
    "                    Exclusive with --list / --reset / --mark.\n" +
    "  --next            With --advance: also emit the ACTION block, but only when\n" +
    "                    the settled step was the session's current step.\n" +
    "  -h, --help        Show this help.\n"
  );
}

function parseArgs(argv) {
  const out = {
    list: false, session: undefined, reset: undefined, mark: undefined,
    advance: false, next: false,
    advanceStep: undefined, advanceStatus: undefined, skipReason: undefined,
  };
  const needValue = (i, flag) => {
    if (i + 1 >= argv.length) {
      process.stderr.write("next-step: " + flag + " requires an argument\n");
      process.exit(1);
    }
    return argv[i + 1];
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
      if (i + 2 >= argv.length) {
        process.stderr.write("next-step: --mark requires <step> and <status> arguments\n");
        process.exit(1);
      }
      const stepName = argv[i + 1];
      if (VALID_STEPS.indexOf(stepName) === -1) {
        process.stderr.write("next-step: invalid step for --mark: " + stepName + "\n");
        process.exit(1);
      }
      const statusToken = argv[i + 2];
      if (statusToken !== "complete") {
        process.stderr.write("next-step: --mark status must be 'complete'\n");
        process.exit(1);
      }
      out.mark = stepName;
      i += 2;
    } else if (a === "--advance") {
      out.advance = true;
    } else if (a === "--next") {
      out.next = true;
    } else if (a === "--step") {
      out.advanceStep = needValue(i, "--step");
      i++;
    } else if (a === "--status") {
      out.advanceStatus = needValue(i, "--status");
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
    if (out.advanceStatus !== undefined) die("--status is only meaningful with --advance");
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
  if (out.advanceStatus === undefined) die("--advance requires --status <status>");
  if (ADVANCE_STATUSES.indexOf(out.advanceStatus) === -1) {
    // Named explicitly so the refusal reads as a status rejection, never as an
    // unknown-flag error: --status in_progress is a real flag with a real answer.
    die(
      "--advance --status " + out.advanceStatus + " is not a forward operation " +
      "(accepted: " + ADVANCE_STATUSES.join(", ") + ")"
    );
  }
  if (out.advanceStatus === "skipped" && (out.skipReason === undefined || out.skipReason === "")) {
    die("--advance --status skipped requires --skip-reason <text>");
  }
}

module.exports = { printUsage, parseArgs };
