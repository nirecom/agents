"use strict";
// Handles the CLARIFY_INTENT_COMPLETE sentinel emitted when the clarify-intent
// interview finishes. Marks clarify_intent complete and records the session's
// project-management type from the intent artifact's `**PM type:**` field (#2527).

const fs = require("fs");
const { markStep, setProjectManagementType, SESSION_ID_VALID_RE } = require("../workflow-state");
const { CLARIFY_INTENT_COMPLETE_RE_DQ } = require("../lib/sentinel-patterns");
const { UnapprovedCompletionError } = require("../workflow-state/completion-approval");

// [ \t] (not \s) keeps an empty value from swallowing the next line as its value.
const PM_TYPE_LINE_RE = /^[ \t]*\*\*PM type:\*\*[ \t]*(.*?)[ \t]*$/im;

// → the `**PM type:**` value (lower-cased), "" when the field is absent, null when unreadable.
function readIntentPmType(sessionId) {
  try {
    if (!SESSION_ID_VALID_RE.test(sessionId)) return null;
    // Owner-resolved: a downstream session reads its upstream's intent (#2633).
    const { resolvePlanArtifactOwner } = require("../workflow-state/plan-artifact-owner");
    const text = fs.readFileSync(resolvePlanArtifactOwner(sessionId, "intent").path, "utf8");
    const m = text.match(PM_TYPE_LINE_RE);
    return m ? m[1].toLowerCase() : "";
  } catch (_) {
    return null;
  }
}

// waterfall (or a legacy intent without the field) is recorded; any other value
// records nothing so the profile stays provisional until #2565 supports it.
function recordPmType(sessionId, pushMessage) {
  const { SUPPORTED_PM_TYPES, DEFAULT_PM_TYPE } = require("../workflow-state/session-profile");
  const value = readIntentPmType(sessionId);
  if (value === null) return;
  const pmType = value === "" ? DEFAULT_PM_TYPE : value;
  if (!SUPPORTED_PM_TYPES.includes(pmType)) {
    process.stderr.write(
      `workflow-mark: PM type ${JSON.stringify(value)} is not supported yet (pending #2565) — ` +
        "project_management_type NOT recorded.\n"
    );
    return;
  }
  try {
    setProjectManagementType(sessionId, pmType);
  } catch (e) {
    pushMessage(`workflow-mark: warning — failed to record project_management_type: ${e.message}`);
  }
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  // --- CLARIFY_INTENT_COMPLETE handler ---
  if (CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd)) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "clarify_intent", "complete");
    } catch (e) {
      if (e instanceof UnapprovedCompletionError) {
        pushMessage(`workflow-mark: clarify_intent NOT completed — the approval does not verify (${e.code}). ${e.recovery}`);
        return true;
      }
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. clarify_intent NOT recorded.`
      );
      return true;
    }
    recordPmType(sessionId, pushMessage);
    return true;
  }

  return false;
}

module.exports = { handle };
