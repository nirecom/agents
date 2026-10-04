=== hooks/lib/runner-table.js
const RUNNERS = {
  bash: { tool: "sh-runner" },
  "pester": { tool: "ps-runner" },
  pytest: { tool: "py-runner" },
};
module.exports = { RUNNERS };
