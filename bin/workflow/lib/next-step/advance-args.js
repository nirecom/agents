"use strict";
// Shared argv VOCABULARY for the forward operation, used by both advance-class
// entrypoints (bin/workflow/next-step and bin/workflow/set-workflow-type).
// Owns the settling-status set, the value-less status flags derived from it, and
// every diagnostic that names them, so the two CLIs cannot drift apart.

// #1947: the settling status moved from an option VALUE (`--status complete`) to
// a value-less FLAG (`--complete`) — a bare `complete` argv token is read as the
// bash builtin by the worktree-isolation command classifier and blocks the whole
// call. Persisted status strings are unchanged; see
// docs/architecture/claude-code/workflow.md.

// Deliberately argv-only: no plan reading, no state reading (#1644).

const { VALID_STATUSES } = require("../../../../hooks/workflow-state");

// `--advance` accepts the three SETTLING statuses. in_progress settles
// nothing, so it is rejected here rather than silently recorded — deliberately
// stricter than the MARK_STEP sentinel path, and never a new bypass route.
const ADVANCE_STATUSES = VALID_STATUSES.filter((s) => s !== "in_progress");

// Derived, never hand-written: a status added to VALID_STATUSES grows its flag
// automatically, so the value form and the flag form cannot fall out of step.
const STATUS_FLAGS = Object.fromEntries(ADVANCE_STATUSES.map((s) => ["--" + s, s]));

// Reading order for humans (the settled verdicts first, the reopen last), kept
// separate from the derivation order so a future status still appends itself.
const FLAG_DISPLAY_ORDER = ["complete", "skipped", "pending"];
const DISPLAY_STATUSES = FLAG_DISPLAY_ORDER
  .filter((s) => ADVANCE_STATUSES.indexOf(s) !== -1)
  .concat(ADVANCE_STATUSES.filter((s) => FLAG_DISPLAY_ORDER.indexOf(s) === -1));

// Every flag name either CLI already matches with an exact `a === "..."` branch
// for a NON-status purpose. Status-flag matching is appended after those
// branches, so a name collision would be silently shadowed rather than refused.
const RESERVED_ARGV_FLAGS = [
  "--help", "-h", "--list", "--reset", "--mark", "--advance", "--next",
  "--step", "--status", "--skip-reason", "--session", "--type",
];

// Fail closed at load time: a future VALID_STATUSES entry named like an existing
// flag (`reset`, `list`, `mark`, ...) must be loud, not quietly unreachable.
const FLAG_COLLISIONS = Object.keys(STATUS_FLAGS)
  .filter((f) => RESERVED_ARGV_FLAGS.indexOf(f) !== -1);
if (FLAG_COLLISIONS.length > 0) {
  throw new Error(
    "advance-args: settling status flag(s) collide with reserved argv flags: " +
    FLAG_COLLISIONS.join(", ") + " — rename the status before shipping"
  );
}

function matchStatusFlag(token) {
  if (typeof token !== "string") return null;
  return Object.prototype.hasOwnProperty.call(STATUS_FLAGS, token) ? STATUS_FLAGS[token] : null;
}

function statusFlagFor(status) {
  return "--" + status;
}

function formatStatusFlagList() {
  return DISPLAY_STATUSES.map(statusFlagFor).join(" | ");
}

function formatStatusRejection(value) {
  return "--advance --status " + value + " is not a forward operation " +
    "(accepted: " + ADVANCE_STATUSES.join(", ") + ")";
}

// One line, stderr only: stdout is a machine contract (parse-next-step-output.js).
// `write` is injectable so a unit test can capture it without a subprocess.
function warnDeprecatedStatusValue(binary, status, write) {
  const emit = write || ((s) => process.stderr.write(s));
  emit(
    binary + ": --status " + status + " is deprecated — use " + formatStatusFlagList() +
    " (a bare \"complete\" argv token trips worktree-isolation command classifiers; " +
    "see docs/architecture/claude-code/workflow.md)\n"
  );
}

module.exports = {
  ADVANCE_STATUSES,
  STATUS_FLAGS,
  RESERVED_ARGV_FLAGS,
  matchStatusFlag,
  statusFlagFor,
  formatStatusFlagList,
  formatStatusRejection,
  warnDeprecatedStatusValue,
};
