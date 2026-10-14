"use strict";
// Per-target skip-condition key schemas (#1300 hardening #2), in their own module
// so importers of the schema need not load the whole skip-signal resolver.
// JUDGMENT_SOURCES are the recorders of a skip judgment (#2460).

const CONDITION_SCHEMAS = Object.freeze({
  outline: Object.freeze(["so_c1", "so_c2"]),
  detail: Object.freeze(["sd_single_approach", "sd_no_open_decision"]),
});

const JUDGMENT_SOURCES = Object.freeze(["jev", "subagent", "mixed"]);

module.exports = { CONDITION_SCHEMAS, JUDGMENT_SOURCES };
