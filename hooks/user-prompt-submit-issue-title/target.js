"use strict";
// Which issue refs does this prompt's session carry, and so which kind of name it gets? Never spawns.
// A typed wf-init carries its refs in its arguments (state or not); any later prompt needs the
// begun mark (workflow_init not pending) and takes the refs from the intent's ## Issues.

const { promptInvokesWfInit, wfInitPromptArgs } = require("../lib/step-in-flight-policy");
const { parseIssueTokens } = require("../lib/parse-closes-issues");
const { refLabel } = require("../lib/session-name");
const { hasPmMark, isActivePm } = require("../pm-session/schema");

// refsFor(sid, state, prompt) -> Array<{number, repo?}>; empty when the session carries no issue.
// state may be null (a session without workflow state): only a typed wf-init gives refs then.
function refsFor(sid, state, prompt) {
  if (promptInvokesWfInit(prompt)) return parseIssueTokens(wfInitPromptArgs(prompt));
  const steps = state && state.current && state.current.steps;
  const wfInit = steps && steps.workflow_init;
  if ((wfInit ? wfInit.status : "pending") === "pending") return [];
  const { getClosesIssues } = require("../workflow-state/session-facts");
  return getClosesIssues(sid);
}

// targetFor(sid, state, prompt) -> {kind: "pm"|"work"|"none", tag?, refs, objective}. A session with
// the PM mark (#2941) is named by its tag and assignment; an archived one by its objective alone.
function targetFor(sid, state, prompt) {
  if (hasPmMark(state)) {
    const issues = isActivePm(state) && Array.isArray(state.pm.issues) ? state.pm.issues : [];
    return { kind: "pm", tag: state.pm.tag, refs: issues, objective: state.pm.objective || null };
  }
  const refs = refsFor(sid, state, prompt);
  const list = Array.isArray(refs) ? refs : [];
  return { kind: list.length > 0 ? "work" : "none", refs: list, objective: null };
}

const refKey = (ref) => `${ref.repo || ""}#${ref.number}`;

module.exports = { refsFor, targetFor, refKey, refLabel };
