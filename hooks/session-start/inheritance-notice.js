"use strict";
// The lines SessionStart prints about what this session did or did not inherit.
//
// Extracted from hooks/session-start.js so #2218's cross-session route can be
// named at every refusal: an ancestor that was found and refused, and a
// crash-resume with no lineage at all, both now have `/resume-session --from`
// as an answer instead of an unexplained silence.

function adoptCommands(sessionId, donorSid) {
  return [
    "It is NOT inherited automatically. If this session continues that work:",
    "  interactive     : run /workflow-init and choose \"adopt\"",
    `  non-interactive : node bin/workflow/adopt-session-state --session ${sessionId} --from ${donorSid}`,
    `  across worktrees: /resume-session --from ${donorSid}`,
  ];
}

function isRefusal(decision) {
  return decision === "context-mismatch"
    || (typeof decision === "string" && decision.indexOf("not-resumable:") === 0);
}

// buildInheritanceNotice({ sessionId, sessionSource, inheritedFromSessionId,
//   inheritCandidateSid, inheritDecision, adoptCandidate }) → [line, ...]
function buildInheritanceNotice(input) {
  const o = input || {};
  if (o.inheritedFromSessionId) {
    return [
      `Inherited workflow steps from session ${o.inheritedFromSessionId} ` +
      `(fork lineage, SessionStart source=${o.sessionSource})`,
    ];
  }
  if (o.inheritCandidateSid && isRefusal(o.inheritDecision)) {
    // An ancestor WAS found and deliberately refused. Silence here would read as
    // "no prior work existed", which is the opposite of the truth.
    return [
      `Prior session ${o.inheritCandidateSid} is in this session's lineage but was ` +
      `not inherited (${o.inheritDecision}).`,
    ].concat(adoptCommands(o.sessionId, o.inheritCandidateSid));
  }
  if (o.inheritDecision === "startup-no-lineage" && o.adoptCandidate) {
    return [
      `A recent session ${o.adoptCandidate.sessionId} on this cwd+branch has workflow state ` +
      `(last activity ${o.adoptCandidate.last_activity}).`,
    ].concat(adoptCommands(o.sessionId, o.adoptCandidate.sessionId));
  }
  return [];
}

module.exports = { buildInheritanceNotice };
