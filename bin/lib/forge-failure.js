"use strict";
// The three time-out classes of a forge call and the next action of every failure reason (#3152), shared by
// the PM writer, the overlap check and the CLI.
//   budget-exhausted: gh was never run (no time left); timeout: gh was killed (forge not answering, the
//   stored reason of old states too); spawn-failed: gh could not start.
//   classifyGhSpawn(r) -> "timeout" | "spawn-failed" | null for a spawnSync result of gh.
//   nextActionOf(reason) -> the one sentence telling the user what to do next; the part after ':' is ignored.

const BUDGET_EXHAUSTED = "budget-exhausted";
const TIMEOUT = "timeout";
const SPAWN_FAILED = "spawn-failed";

const RETRYABLE = new Set(["gh_exec_failed", TIMEOUT, BUDGET_EXHAUSTED, SPAWN_FAILED]);
const REFERENCE = new Set(["issue_not_found", "repo-unknown"]);
const NOT_RETRYABLE = new Set([
  "pm-field-ambiguous", "pm-field-truncated", "cycle", "depth-cap", "parse_failed", "sub-issue-overflow", "sub-issue-depth-cap",
  ...REFERENCE,
]);

function classifyGhSpawn(r) {
  if (!r) return SPAWN_FAILED;
  if ((r.error && r.error.code === "ETIMEDOUT") || r.signal) return TIMEOUT;
  return r.error ? SPAWN_FAILED : null;
}

const DEFAULT_ACTION = "Retry when the forge is back.";
const ACTIONS = {
  [BUDGET_EXHAUSTED]: "The hook ran out of time before asking the forge; retry with fewer issues in one command.",
  [TIMEOUT]: "The forge did not answer in time; wait a moment and run the same command again.",
  [SPAWN_FAILED]: "gh could not be started; check that gh is installed, on PATH, and logged in (`gh auth status`), then run the command again.",
  gh_exec_failed: DEFAULT_ACTION,
};
const REFERENCE_ACTION = "Retrying will not fix it; check the issue number and write it as owner/repo#N.";
const STRUCTURE_ACTION = "Retrying will not fix it; fix the cause in parentheses (the Project's pm field, or the sub-issue hierarchy or its cycle) first, then run the command again.";

function nextActionOf(reason) {
  const key = String(reason === undefined || reason === null ? "" : reason).split(":")[0].trim();
  if (Object.prototype.hasOwnProperty.call(ACTIONS, key)) return ACTIONS[key];
  if (REFERENCE.has(key)) return REFERENCE_ACTION;
  if (NOT_RETRYABLE.has(key)) return STRUCTURE_ACTION;
  return DEFAULT_ACTION;
}

module.exports = { BUDGET_EXHAUSTED, TIMEOUT, SPAWN_FAILED, RETRYABLE, NOT_RETRYABLE, classifyGhSpawn, nextActionOf };
