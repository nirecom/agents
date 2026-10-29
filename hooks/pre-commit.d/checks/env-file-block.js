"use strict";
// env-file-block check (#2507): an added or modified .env at any depth blocks the commit.

const { out } = require("../output");

async function run({ snapshot, files }) {
  const hits = files.filter((f) => /(^|\/)\.env$/.test(f) && ["A", "M"].includes(snapshot.status ? snapshot.status(f) : "M"));
  if (hits.length === 0) return { verdict: "pass", messages: [] };
  return {
    verdict: "block",
    messages: [out("pre-commit: .env file(s) staged for commit:"), ...hits.map((f) => out(`  ${f}`)),
      out("Use .env.example / .env.sample / .env.template instead.")],
  };
}

module.exports = { run };
