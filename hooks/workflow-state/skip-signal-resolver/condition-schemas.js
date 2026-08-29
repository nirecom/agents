"use strict";
// Per-target skip-condition key schemas (#1300 hardening #2). Own module so the
// judgment side (skip-signal-resolver.js) and the complexity side
// (skip-signal-resolver/complexity.js) share one definition without a cycle.

const CONDITION_SCHEMAS = Object.freeze({
  outline: Object.freeze(["so_c1", "so_c2"]),
  detail: Object.freeze(["sd_c1", "sd_c2", "sd_c3"]),
});

module.exports = { CONDITION_SCHEMAS };
