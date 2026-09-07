"use strict";
// bin/workflow/lib/session-facts/keys.js
// The v1 output contract of bin/workflow/read-session-facts: which keys are
// printed, and in which order.

// Adding, removing, renaming, or reordering a key here is a breaking change —
// bump FACTS_VERSION and update docs/architecture/claude-code/workflow.md and
// every consuming SKILL.md in the same diff. Note also: adding a GATE_-derived
// key means adding another confirm-off child process (see gate-facts.js and the
// measured process-cost tradeoff in its header).
// Static literals on purpose: never derive these names from VALID_STEPS or
// ROUTING_STAGES, or a new workflow stage would silently grow the contract.
const FACTS_V1_KEYS = [
  "FACTS_VERSION",
  "SESSION_ID",
  "PLANS_DIR",
  "GATE_CONFIRM_TESTS",
  "GATE_CONFIRM_CODE",
  "COMPLEXITY_LEVEL_write_tests",
  "COMPLEXITY_LEVEL_write_code",
  "COMPLEXITY_SIGNALS",
];

const FACTS_VERSION = 1;

// The `<default>` argument each gate is probed with. SSOT for the bundled reader
// AND for the post-action probe still written out in the consuming SKILL.md.
const GATE_DEFAULTS = {
  CONFIRM_TESTS: "on",
  CONFIRM_CODE: "on",
};

module.exports = { FACTS_V1_KEYS, FACTS_VERSION, GATE_DEFAULTS };
