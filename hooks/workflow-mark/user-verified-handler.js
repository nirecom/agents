"use strict";

const { validateSkipReason } = require("./skip-reason");
const { markStep, nextStepHint } = require("../lib/workflow-state");
const {
  USER_VERIFIED_RE_DQ, USER_VERIFIED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage } = ctx;

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
      pushMessage(
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
      const hint = nextStepHint("user_verification");
      if (hint) pushMessage(hint);
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
