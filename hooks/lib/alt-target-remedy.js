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

module.exports = { buildAltTargetRemedy };
