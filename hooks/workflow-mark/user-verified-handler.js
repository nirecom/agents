"use strict";
// Handles USER_VERIFIED sentinels, emitted when the user approves an implementation
// step. Marks user_verification as complete and records the approval reason.

const { validateSkipReason } = require("./skip-reason");
const { markStep } = require("../lib/workflow-state");
const {
  USER_VERIFIED_RE_DQ, USER_VERIFIED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  const userVerifiedMatch = cmd.match(USER_VERIFIED_RE_DQ);

  // --- USER_VERIFIED LOOKSLIKE handler (intercept bare/malformed forms) ---
  if (!userVerifiedMatch && USER_VERIFIED_LOOKSLIKE_RE.test(cmd)) {
    pushMessage(
      `workflow-mark: malformed USER_VERIFIED — ` +
        `expected: echo "<<WORKFLOW_USER_VERIFIED: REASON>>" ` +
        `(reason: >=3 non-space chars, no '>', not a placeholder)`
    );
    return true;
  }

  // --- USER_VERIFIED handler ---
  if (userVerifiedMatch) {
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — user_verification NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>" ` +
          `(reason: >=3 non-space chars, no '>', not a placeholder; ask dialog will re-trigger)`
      );
      return true;
    }
    const rawUvReason = userVerifiedMatch[1];
    const v = validateSkipReason(rawUvReason);
    if (!v.ok) {
      // Warn but still apply — reason quality must not block verification.
      pushMessage(
        `workflow-mark: USER_VERIFIED reason rejected — ${v.msg} (verification still recorded)`
      );
    }
    try {
      markStep(sessionId, "user_verification", "complete");
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. user_verification NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
