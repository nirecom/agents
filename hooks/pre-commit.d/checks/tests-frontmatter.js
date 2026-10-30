"use strict";
// tests-frontmatter check (#2507 D7): the frontmatter, case-marker and language-match gates of staged
// tests/ files, in process and in that order; the first gate that blocks ends the check, as the
// bash hook's `|| exit 1` chain did. Each gate lives in tests-frontmatter/.

const R = require("../../lib/test-gates/registry");
const { gate: frontmatter } = require("./tests-frontmatter/frontmatter-gate");
const { gate: caseMarkers } = require("./tests-frontmatter/case-markers-gate");
const { gate: languageMatch } = require("./tests-frontmatter/language-match-gate");

const GATES = [frontmatter, caseMarkers, languageMatch];

// A merge-narrowed list is widened back to every staged path: the gates judge a merge against both
// parents themselves (#2812), so a file taken whole from MERGE_HEAD passes as an existing one.
async function run({ context, snapshot, files, narrowed = false }) {
  const all = narrowed ? await snapshot.files() : files || [];
  return R.withEnv(context.env || process.env, () => {
    const messages = [];
    for (const g of GATES) {
      const r = g({ context, snapshot, files: all });
      messages.push(...r.messages);
      if (r.block) return { verdict: "block", messages };
    }
    return { verdict: "pass", messages };
  });
}

module.exports = { run };
