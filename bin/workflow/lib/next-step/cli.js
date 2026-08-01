"use strict";
// Argument parsing and usage output for bin/workflow/next-step.
// Owns ALL argument validation: unknown options, missing values, step-name
// validation for --reset/--mark, and the --session format check.

const { VALID_STEPS } = require("../../../../hooks/workflow-state");

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
    "  -h, --help        Show this help.\n"
  );
}

function parseArgs(argv) {
  const out = { list: false, session: undefined, reset: undefined, mark: undefined };
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
  return out;
}

module.exports = { printUsage, parseArgs };
