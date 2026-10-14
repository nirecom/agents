"use strict";
// --list rendering for bin/workflow/next-step.

const fs = require("fs");
const {
  VALID_STEPS,
  isSettledStatus,
  readState,
  getStatePath,
} = require("../../../../hooks/workflow-state");
const {
  reconcileEffectiveState,
} = require("../../../../hooks/workflow-state/effective-state");
const { resolveSessionProfile } = require("../../../../hooks/workflow-state/session-profile");
const { getClosesIssues } = require("../../../../hooks/workflow-state/session-facts");
const { getWorkflowPlansDir } = require("../../../../hooks/lib/workflow-plans-dir");
const { STEP_DESC, isTerminalStep } = require("./steps");
const { resolveRepoDir } = require("./repo-dir");

function pad2(n) {
  const s = String(n);
  return s.length >= 2 ? s : " " + s;
}

function renderListPlain() {
  const lines = [];
  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    lines.push(pad2(i + 1) + "  " + step + "  " + STEP_DESC[step]);
  }
  return lines.join("\n") + "\n";
}

function renderListWithState(sid) {
  // Fail-open: any error -> fall back to plain list.
  let state = null;
  try {
    const sp = getStatePath(sid);
    if (!fs.existsSync(sp)) return renderListPlain();
    state = readState(sid);
    if (!state || typeof state.steps !== "object" || !state.steps) {
      return renderListPlain();
    }
  } catch (_) {
    return renderListPlain();
  }

  // Unified derivation (#1681): --list must show exactly what the gates see,
  // including veto de-skip and post-veto reset. resolveAll:true because a list
  // has no "current step" cutoff — every row is rendered.
  let listSnapshot;
  try {
    const repoDir = resolveRepoDir();
    const profile = resolveSessionProfile(state, sid, { repoDir });
    // #2527: navigate boundary resets like the verdict, but never query the network.
    listSnapshot = reconcileEffectiveState(state, sid, { repoDir, profile, resolveAll: true, deliveryBoundary: "navigate" });
    if (!listSnapshot || !listSnapshot.steps) return renderListPlain();
  } catch (_) {
    return renderListPlain();
  }
  const listStatus = (step) => (listSnapshot.steps[step] || {}).status || "pending";

  // Find current step (first non-settled). Terminal steps are never "current" —
  // the row is still rendered, just never marked [*].
  let currentIdx = -1;
  for (let i = 0; i < VALID_STEPS.length; i++) {
    if (isTerminalStep(VALID_STEPS[i])) continue;
    const s = listStatus(VALID_STEPS[i]);
    if (!isSettledStatus(s)) { currentIdx = i; break; }
  }

  let issuesEmpty;
  try {
    issuesEmpty = getClosesIssues(sid, { plansDir: getWorkflowPlansDir() }).length === 0;
  } catch (_) {
    return renderListPlain();
  }

  const lines = [];
  for (let i = 0; i < VALID_STEPS.length; i++) {
    const step = VALID_STEPS[i];
    const s = listStatus(step);
    let marker;
    if (s === "complete") {
      marker = "[x]";
    } else if (s === "skipped") {
      marker = "[-]";
    } else if (i === currentIdx) {
      if (step === "clarify_intent" && issuesEmpty) {
        marker = "[!]";
      } else {
        marker = "[*]";
      }
    } else {
      marker = "[ ]";
    }
    lines.push(marker + " " + pad2(i + 1) + "  " + step + "  " + STEP_DESC[step]);
  }
  return lines.join("\n") + "\n";
}

// --list subcommand: owns its own output and exit.
function runList(session) {
  if (session !== undefined && session !== "") {
    process.stdout.write(renderListWithState(session));
  } else {
    process.stdout.write(renderListPlain());
  }
  process.exit(0);
}

module.exports = { pad2, renderListPlain, renderListWithState, runList };
