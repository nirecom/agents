#!/usr/bin/env node
"use strict";
// Node part of the decide shadow: step (b) of bin/lib/run-tests-baseline-decide-shadow.sh calls it exactly once.
// The logic lives in ./run-tests-baseline-decide-shadow/; this file is dispatch and re-export only.
// Usage: run-tests-baseline-decide-shadow.js --input <tsv> --capture <tsv> --map <tsv> --tfc <tsv>
//          --root <ROOT> --base-wt <WT> --b2 <B2> --head <HEAD> --log <divergence log> --started-ms <ms>
// Exit: 0 wrote the log and printed counts to stdout; 1 failure (the parent shell records skipped=failed).
const { compareOne } = require("./run-tests-baseline-decide-shadow/compare-one");
const { main } = require("./run-tests-baseline-decide-shadow/main");

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`run-tests-baseline-decide-shadow: ${e && e.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { compareOne, main };
