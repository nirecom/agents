"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { buildBashScriptSpawn } = require("../spawn-env");

/**
 * Phase: wip-check
 * Check WIP state for each issue, then set WIP for unowned issues.
 *
 * WIP evaluation order (CRITICAL — fixes ALL_NONE-before-ALL_SAME bug):
 * 1. error_ns non-empty → ask_user ASK_ID=wip_error
 * 2. any wip=other → ask_user ASK_ID=wip_conflict
 * 3. all wip=none → run set for ALL N → if set rc=2 → ask_user ASK_ID=wip_rc2; else continue; set force_path_b=true
 * 4. all wip=same (none are 'none') → continue without set
 * 5. mixed (some none, some same) → set only the 'none' Ns; continue
 */
function wipCheck(state, agentsConfigDir, sessionId) {
  const wipScript = path.join(agentsConfigDir, "bin", "github-issues", "wip-state.sh");
  const issues = state.issues;

  // Initialize wip_results for issues not yet checked
  for (const n of issues) {
    if (state.wip_results[n] !== undefined) {
      // Already known from prior run or resume answer override
      continue;
    }
    // Run wip-state check (absolute script path → use buildBashScriptSpawn)
    const checkArgs = ["check", String(n)];
    if (sessionId) checkArgs.push("--session-id", sessionId);
    const [cmd, args, opts] = buildBashScriptSpawn(wipScript, checkArgs);
    const result = spawnSync(cmd, args, opts);

    if (result.status !== 0) {
      state.wip_results[n] = "error";
    } else {
      const wip = (result.stdout || "").trim();
      state.wip_results[n] = wip || "none";
    }
  }

  // Step 1: any check error → ask_user wip_error
  const errIssues = issues.filter((n) => state.wip_results[n] === "error");
  if (errIssues.length > 0) {
    return {
      ask: true,
      askId: "wip_error",
      question: `wip-state check failed for issue(s) #${errIssues.join(", #")}. Treat as unowned and continue?`,
      options: "continue|abort",
    };
  }

  // Step 2: any wip=other → ask_user wip_conflict
  const otherIssues = issues.filter((n) => state.wip_results[n] === "other");
  if (otherIssues.length > 0) {
    return {
      ask: true,
      askId: "wip_conflict",
      question: `Issue(s) #${otherIssues.join(", #")} are already owned by another session. Override and continue?`,
      options: "continue|abort",
    };
  }

  // Classify: none vs same
  const noneIssues = issues.filter((n) => state.wip_results[n] === "none");

  if (noneIssues.length === 0) {
    // Step 4: all wip=same → continue without set
    return { done: false };
  }

  if (noneIssues.length === issues.length) {
    // Step 3: ALL_NONE → set for ALL N (BUG FIX: evaluated before all_same check above)
    for (const n of issues) {
      const setArgs = ["set", String(n)];
      if (sessionId) setArgs.push("--session-id", sessionId);
      const [setCmd, setArgsFull, setOpts] = buildBashScriptSpawn(wipScript, setArgs);
      const setResult = spawnSync(setCmd, setArgsFull, setOpts);
      if (setResult.status === 2) {
        return {
          ask: true,
          askId: "wip_rc2",
          question: `wip-state set returned rc=2 for issue #${n}. Another session may have claimed it. Continue anyway?`,
          options: "continue|abort",
        };
      }
      if (setResult.status === 0) {
        state.wip_results[n] = "same";
      }
    }
    state.force_path_b = true;
    return { done: false };
  }

  // Step 5: mixed (some none, some same) → set only the 'none' Ns
  for (const n of noneIssues) {
    const setArgs = ["set", String(n)];
    if (sessionId) setArgs.push("--session-id", sessionId);
    const [setCmd, setArgsFull, setOpts] = buildBashScriptSpawn(wipScript, setArgs);
    const setResult = spawnSync(setCmd, setArgsFull, setOpts);
    if (setResult.status === 2) {
      return {
        ask: true,
        askId: "wip_rc2",
        question: `wip-state set returned rc=2 for issue #${n}. Another session may have claimed it. Continue anyway?`,
        options: "continue|abort",
      };
    }
    if (setResult.status === 0) {
      state.wip_results[n] = "same";
    }
  }
  return { done: false };
}

module.exports = { wipCheck };
