"use strict";
// bin/workflow/lib/session-facts/keys.js
// The output contract (version FACTS_VERSION) of bin/workflow/read-session-facts:
// which keys are printed, and in which order.

const { CONFIRM_GATE_DEFAULTS } = require("../../../../hooks/lib/confirm-gate/step-gate-map");

// Adding, removing, renaming, or reordering a key here is a breaking change —
// bump FACTS_VERSION and update docs/architecture/claude-code/workflow.md and
// every consuming SKILL.md in the same diff. Note also: adding a GATE_-derived
// key means adding another confirm-off child process (see gate-facts.js and the
// measured process-cost tradeoff in its header).
// Static literals on purpose: never derive these names from VALID_STEPS or
// ROUTING_STAGES, or a new workflow stage would silently grow the contract.
const FACTS_KEYS = [
  "FACTS_VERSION",
  "SESSION_ID",
  "PLANS_DIR",
  "CONTROL_DIR",
  "GATE_CONFIRM_TESTS",
  "GATE_CONFIRM_CODE",
  "COMPLEXITY_LEVEL_write_tests",
  "COMPLEXITY_LEVEL_write_code",
  "COMPLEXITY_MODEL_write_tests",
  "COMPLEXITY_MODEL_write_code",
  "COMPLEXITY_SIGNALS",
];

const FACTS_VERSION = 3;

// The gates the bundled reader probes, in output order. Their `<default>` values
// come from the confirm-gate SSOT (hooks/lib/confirm-gate/step-gate-map.js).
const GATE_DEFAULTS = {
  CONFIRM_TESTS: CONFIRM_GATE_DEFAULTS.CONFIRM_TESTS,
  CONFIRM_CODE: CONFIRM_GATE_DEFAULTS.CONFIRM_CODE,
};

module.exports = { FACTS_KEYS, FACTS_VERSION, GATE_DEFAULTS };
