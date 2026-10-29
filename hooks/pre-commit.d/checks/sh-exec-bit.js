"use strict";
// sh-exec-bit check (#2507): a staged *.sh must carry mode 100755.

const { out } = require("../output");

async function run({ snapshot, files }) {
  const bad = [];
  for (const f of files) if (/\.sh$/.test(f) && String(await snapshot.mode(f)) === "100644") bad.push(f);
  if (bad.length === 0) return { verdict: "pass", messages: [] };
  // The former bash echo left "\n" literal, so the list stays on one line.
  return {
    verdict: "block",
    messages: [out(`pre-commit: .sh files lacking execute permission:${bad.map((f) => `\\n  ${f}`).join("")}`),
      out("Run: git update-index --chmod=+x <file>")],
  };
}

module.exports = { run };
