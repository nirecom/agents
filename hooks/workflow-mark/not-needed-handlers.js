"use strict";
// Handles *_NOT_NEEDED step-skip sentinels: RESEARCH, OUTLINE, DETAIL, WRITE_TESTS,
// REVIEW_SECURITY, CLARIFY_INTENT, and the deprecated DOCS_NOT_NEEDED.
// Each family validates the skip reason, records the step as skipped, and returns next-step guidance.

const { validateSkipReason } = require("./skip-reason");
const { markStep, nextStepHint } = require("../lib/workflow-state");
const {
  RESEARCH_NOT_NEEDED_RE_DQ, RESEARCH_NOT_NEEDED_LOOKSLIKE_RE,
  OUTLINE_NOT_NEEDED_RE_DQ, OUTLINE_NOT_NEEDED_LOOKSLIKE_RE,
  DETAIL_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_LOOKSLIKE_RE,
  WRITE_TESTS_NOT_NEEDED_RE_DQ, WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE,
  REVIEW_SECURITY_NOT_NEEDED_RE_DQ, REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE,
  DOCS_NOT_NEEDED_LOOKSLIKE_RE,
  CLARIFY_INTENT_NOT_NEEDED_RE_DQ, CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  const researchNotNeededMatch = cmd.match(RESEARCH_NOT_NEEDED_RE_DQ);
  const researchNotNeededLooksLike =
    !researchNotNeededMatch && RESEARCH_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const writeTestsNotNeededMatch = cmd.match(WRITE_TESTS_NOT_NEEDED_RE_DQ);
  const writeTestsNotNeededLooksLike =
    !writeTestsNotNeededMatch && WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const reviewSecurityNotNeededMatch = cmd.match(REVIEW_SECURITY_NOT_NEEDED_RE_DQ);
  const reviewSecurityNotNeededLooksLike =
    !reviewSecurityNotNeededMatch && REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const docsNotNeededLooksLike = DOCS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const clarifyIntentNotNeededMatch = cmd.match(CLARIFY_INTENT_NOT_NEEDED_RE_DQ);
  const clarifyIntentNotNeededLooksLike = !clarifyIntentNotNeededMatch && CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);

  // --- RESEARCH_NOT_NEEDED handler ---
  if (researchNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed RESEARCH_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (researchNotNeededMatch) {
    const v = validateSkipReason(researchNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: RESEARCH_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <better reason>>"`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — research NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "research", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("research");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. research NOT recorded.`
      );
    }
    return true;
  }

  // --- OUTLINE_NOT_NEEDED handler ---
  const outlineNotNeededMatch = cmd.match(OUTLINE_NOT_NEEDED_RE_DQ);
  const outlineNotNeededLooksLike =
    !outlineNotNeededMatch && OUTLINE_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  if (outlineNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed OUTLINE_NOT_NEEDED — ` +
      `expected: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: REASON>>" ` +
      `(reason must be >=3 non-space chars, no '>')`);
    return true;
  }
  if (outlineNotNeededMatch) {
    const v = validateSkipReason(outlineNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(`workflow-mark: OUTLINE_NOT_NEEDED rejected — ${v.msg} ` +
        `Re-run: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: <better reason>>"`);
      return true;
    }
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — outline NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: ${v.reason}>>"`);
      return true;
    }
    try {
      markStep(sessionId, "outline", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("outline");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(`workflow-mark: failed to write state — ${e.message}. outline NOT recorded.`);
    }
    return true;
  }

  // --- DETAIL_NOT_NEEDED handler ---
  const detailNotNeededMatch = cmd.match(DETAIL_NOT_NEEDED_RE_DQ);
  const detailNotNeededLooksLike =
    !detailNotNeededMatch && DETAIL_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  if (detailNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed DETAIL_NOT_NEEDED — ` +
      `expected: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: REASON>>" ` +
      `(reason must be >=3 non-space chars, no '>')`);
    return true;
  }
  if (detailNotNeededMatch) {
    const v = validateSkipReason(detailNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(`workflow-mark: DETAIL_NOT_NEEDED rejected — ${v.msg} ` +
        `Re-run: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <better reason>>"`);
      return true;
    }
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — detail NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: ${v.reason}>>"`);
      return true;
    }
    try {
      markStep(sessionId, "detail", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("detail");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(`workflow-mark: failed to write state — ${e.message}. detail NOT recorded.`);
    }
    return true;
  }

  // --- WRITE_TESTS_NOT_NEEDED handler ---
  if (writeTestsNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed WRITE_TESTS_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (writeTestsNotNeededMatch) {
    const v = validateSkipReason(writeTestsNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: WRITE_TESTS_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <better reason>>"`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — write_tests NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "write_tests", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("write_tests");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. write_tests NOT recorded.`
      );
    }
    return true;
  }

  // --- REVIEW_SECURITY_NOT_NEEDED handler ---
  if (reviewSecurityNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed REVIEW_SECURITY_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (reviewSecurityNotNeededMatch) {
    const v = validateSkipReason(reviewSecurityNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: REVIEW_SECURITY_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <better reason>>"`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — review_security NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "review_security", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("review_security");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. review_security NOT recorded.`
      );
    }
    return true;
  }

  // --- DOCS_NOT_NEEDED deprecation handler ---
  if (docsNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: WORKFLOW_DOCS_NOT_NEEDED is not accepted — ` +
        `update docs/ or *.md files and stage them (no skip path).`
    );
    return true;
  }

  // --- CLARIFY_INTENT_NOT_NEEDED handler ---
  if (clarifyIntentNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed CLARIFY_INTENT_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (clarifyIntentNotNeededMatch) {
    const v = validateSkipReason(clarifyIntentNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: CLARIFY_INTENT_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <better reason>>"`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: ${v.reason}>>"`
      );
      return true;
    }
    try {
      markStep(sessionId, "clarify_intent", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("clarify_intent");
      if (hint) pushMessage(hint);
    } catch (e) {
      pushMessage(
        `workflow-mark: failed to write state — ${e.message}. clarify_intent NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
