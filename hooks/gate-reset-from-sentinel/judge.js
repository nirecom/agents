"use strict";
// Stage 2 of gate-reset-from-sentinel (#2852): reads the session state and asks decideReset.
// Every failure, including a judgment module that does not load, answers ask; nothing here
// writes. The decision time limit is armed first, so a slow read also ends in an ask.

const { ask, allow } = require("../lib/permission-decision-output");
const { armDecisionTimeLimit, checkDecisionTime } = require("../lib/decision-time-limit");

const { toDisplayLine } = require("../lib/display-line");

const HOOK_NAME = "gate-reset-from-sentinel";
// The ask text shows only this code; the error itself goes to stderr (it may hold a local path).
const JUDGE_ERROR_CODE = "judge-failed";

function resolveSid(input) {
  const wsid = String(process.env.WORKFLOW_SESSION_ID || "").trim();
  if (wsid && /^[A-Za-z0-9_-]+$/.test(wsid)) return wsid;
  return require("../workflow-state").resolveSessionId({ sessionIdFromInput: input.session_id }) || null;
}

function resolveRepoDir(input) {
  const raw = process.env.CLAUDE_PROJECT_DIR || input.cwd;
  if (typeof raw !== "string" || raw === "") return undefined;
  return require("../lib/branch-diff").toWindowsPath(raw);
}

// judge({ input, target, reason }) -> the PreToolUse output object (allow or ask).
function judge(c) {
  armDecisionTimeLimit({ hookName: HOOK_NAME });
  const head = `RESET_FROM_${toDisplayLine(c.target)}: ${toDisplayLine(c.reason)}`;
  let allowance = null;
  try {
    checkDecisionTime("load");
    allowance = require("../workflow-state/reset-allowance");
    const { decideReset } = allowance;
    const sid = resolveSid(c.input);
    if (!sid) return ask(`${head}\nwhy: no session id; asking instead of judging the reset allowance.`);
    checkDecisionTime("read-state");
    const state = require("../workflow-state").readState(sid);
    const repoDir = resolveRepoDir(c.input);
    const result = decideReset({ state, sid, target: c.target, reason: c.reason, repoDir, checkpoint: checkDecisionTime });
    checkDecisionTime("decide");
    if (result && result.decision === "allow") return allow(allowance.allowReason(c.target, result));
    return ask(allowance.askReason(c.target, c.reason, result));
  } catch (e) {
    try { process.stderr.write(`${HOOK_NAME}: ${(e && e.stack) || e}\n`); } catch { /* the ask stands */ }
    if (allowance && typeof allowance.askReason === "function") {
      try { return ask(allowance.askReason(c.target, c.reason, { why: `error: ${JUDGE_ERROR_CODE}` })); } catch { /* plain ask below */ }
    }
    return ask(`${head}\nwhy: the reset allowance could not be judged (${JUDGE_ERROR_CODE}); asking.`);
  }
}

module.exports = { judge };
