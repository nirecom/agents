"use strict";
// hooks/workflow-gate/early-gate-messages.js
// Block wording for early-gate Tier 1 / Tier 2 (#2108 Scope 3).
//
// The VERDICT never branches on caller identity — only the REMEDY does. A subagent
// can neither invoke a skill nor emit a workflow sentinel, so a message offering
// only those two routes describes an exit that does not exist and pushes the agent
// to hunt for a bypass. Both branches must still name the ALLOWED write targets,
// which is the line whose absence produced #2108.

const TIERS = {
  workflow_init: {
    until: "the workflow is routed",
    skill: "workflow-init",
    alt: '  2. For docs-only edits: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>".',
    extra: "",
    reset: 'To reset workflow state: echo "<<WORKFLOW_RESET_FROM_workflow_init: {reason}>>"',
  },
  clarify_intent: {
    until: "intent is locked in",
    skill: "clarify-intent",
    alt: '  2. If intent is already clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>>".',
    extra: 'For docs-only edits: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: docs-only edit>>"',
    reset: 'To reset workflow state: echo "<<WORKFLOW_RESET_FROM_clarify_intent: {reason}>>"',
  },
};

const READ_TOOLS_NOTE =
  "Note: Read, Grep, Glob, and AskUserQuestion remain available.";

// One ALLOWED line per route, so a reader (and the test that counts them) can see
// that both destinations survived the build.
function allowedTargetsBlock(targets) {
  const t = targets || {};
  const plans = t.plans || "~/.workflow-plans";
  const scratchpad = t.scratchpad || "<os-tmpdir>/claude";
  return [
    "ALLOWED write targets (this gate does not block these):",
    "  ALLOWED: " + plans + "  — workflow plan artifacts (intent / outline / detail)",
    "  ALLOWED: " + scratchpad + "  — this session's scratchpad (surveys, notes, drafts)",
    "Write with Write/Edit/MultiEdit under either root, then report the path back.",
  ].join("\n");
}

// buildEarlyGateReason({ tier, toolName, isSubagent, allowedTargets }): the whole
// block reason. `tier` is the pending step's own name, so the diagnosis line names
// the step a reader can act on.
function buildEarlyGateReason({ tier, toolName, isSubagent, allowedTargets }) {
  const spec = TIERS[tier] || TIERS.workflow_init;
  const head =
    "workflow-gate: " + tier + " has not been completed for this session.\n" +
    'Tool "' + toolName + '" is blocked until ' + spec.until + ".\n\n" +
    allowedTargetsBlock(allowedTargets) + "\n\n";

  if (isSubagent) {
    return (
      head +
      "Subagent context: this call carries a subagent identity, so the routes the\n" +
      "main conversation would take (invoking a skill, emitting a workflow-state\n" +
      "marker) are not reachable from here. Do not look for another write path —\n" +
      "use one of the ALLOWED targets above and report the file path to the caller,\n" +
      "who can complete " + tier + " and apply the change.\n\n" +
      READ_TOOLS_NOTE
    );
  }

  return (
    head +
    "To complete:\n" +
    "  1. Invoke the `" + spec.skill + "` skill via the Skill tool, OR\n" +
    spec.alt + "\n\n" +
    READ_TOOLS_NOTE + "\n" +
    (spec.extra ? spec.extra + "\n" : "") +
    "\n" +
    spec.reset
  );
}

module.exports = { buildEarlyGateReason };
