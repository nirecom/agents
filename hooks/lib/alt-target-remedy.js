"use strict";
// hooks/lib/alt-target-remedy.js
// Shared alternative-write-target wording for ENFORCE_WORKTREE / workflow-gate block
// reasons (#2120 Change 3, CPR-SSOT). Naming a target the agent can actually reach
// turns a bare stop into a redirect. Delegates to describeAllowedTargets() (the
// early-gate allowlist's own SSOT) so the advertised scratchpad path always matches
// the session-scoped root the gate actually decides against — see its doc comment.

const { describeAllowedTargets } = require("../workflow-gate/early-gate-allowlist");

function buildAltTargetRemedy() {
  const { plans, scratchpad } = describeAllowedTargets();
  return (
    "Need to write right now? Use Write/Edit/MultiEdit to target the plans dir " +
    `(${plans}) or the scratchpad (${scratchpad}) instead.`
  );
}

// The Bash-side twin (#2134): a compound command's sanctioned form is a scratchpad script
// written with the Write tool and invoked as ONE `bash <absolute-path>` call. Named here
// rather than in bash-guard so both guards advertise the same reachable target.
function buildScriptEscapeHatch() {
  const { scratchpad } = describeAllowedTargets();
  return (
    `Write the steps to a scratchpad script (${scratchpad}) with the Write tool — not with ` +
    "a heredoc redirect, which trips two prohibited literals of its own — then issue it as " +
    "one call: bash <absolute-path-to-that-script>."
  );
}

module.exports = { buildAltTargetRemedy, buildScriptEscapeHatch };
