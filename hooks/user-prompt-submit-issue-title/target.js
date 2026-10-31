"use strict";
// Is this prompt's session a title target, and which issue refs does it carry? Never spawns.
// A typed wf-init carries its refs in its arguments; any later prompt needs the begun mark
// (workflow_init not pending) and takes the refs from the intent's ## Issues.

const { promptInvokesWfInit, wfInitPromptArgs } = require("../lib/step-in-flight-policy");
const { parseIssueTokens } = require("../lib/parse-closes-issues");

// refsFor(sid, state, prompt) -> Array<{number, repo?}>; empty when the session is not a target.
function refsFor(sid, state, prompt) {
  if (promptInvokesWfInit(prompt)) return parseIssueTokens(wfInitPromptArgs(prompt));
  const steps = state && state.current && state.current.steps;
  const wfInit = steps && steps.workflow_init;
  if ((wfInit ? wfInit.status : "pending") === "pending") return [];
  const { getClosesIssues } = require("../workflow-state/session-facts");
  return getClosesIssues(sid);
}

const refKey = (ref) => `${ref.repo || ""}#${ref.number}`;
const refLabel = (ref) => (ref.repo ? `${ref.repo}#${ref.number}` : `#${ref.number}`);

module.exports = { refsFor, refKey, refLabel };
