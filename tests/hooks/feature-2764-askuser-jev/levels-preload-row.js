"use strict";
// The one test-only classification row levels-preload.js adds (#2764): a low dialog ID declaring
// two steps. Kept apart so the test process can read it without installing the preload's patches.

const MULTI_ROW = Object.freeze({ id: "test-fixture.multi-step", level: "low", steps: Object.freeze(["write_code", "run_tests"]), reason: "test-only multi-step row" });

module.exports = { MULTI_ROW };
