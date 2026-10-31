"use strict";
// Tests: bin/check-test-frontmatter.sh
// Tags: TL2, bin, golden, test-lang-exception:symmetry, scope:issue-specific
// Writes golden/cli.json: the pre-port bash CLIs over the D7 corpus (#2507 S4 step 1). Run by
// hand before the port, never by the test: `node tests/bin/feature-2507-test-gates-node/generate-golden.js`.
// A run whose PATH cannot be built on this host is left out and named on stderr.
const fs = require("node:fs");
const F = require("./fixture");

const out = {};
try {
  for (const run of F.RUNS) {
    const got = F.bashRun(run);
    if (got.skipped) {
      process.stderr.write(`skipped ${run.id}: ${got.skipped}\n`);
      continue;
    }
    out[run.id] = got;
  }
} finally {
  F.cleanup();
}
fs.mkdirSync(require("node:path").dirname(F.GOLDEN), { recursive: true });
fs.writeFileSync(F.GOLDEN, `${JSON.stringify(out, null, 2)}\n`);
process.stdout.write(`wrote ${Object.keys(out).length} runs to ${F.GOLDEN}\n`);
