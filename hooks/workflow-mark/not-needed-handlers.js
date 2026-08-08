"use strict";
// Handles *_NOT_NEEDED step-skip sentinels: RESEARCH, OUTLINE, DETAIL, WRITE_TESTS,
// REVIEW_SECURITY, CLARIFY_INTENT, and the deprecated DOCS_NOT_NEEDED.
// Each family validates the skip reason, records the step as skipped, and returns next-step guidance.

const { validateSkipReason } = require("./skip-reason");
// #1644: the declared-class single writer. It owns the state write, the A-4
// speculative-skip verdict, the D1 BUGFIX defense and the #833 symmetric
// propagation; this module keeps only the sentinel-specific wording.
const { recordStepVerdict } = require("../workflow-state/record-step-verdict");
// #1644: the docs-only predicate has exactly one owner. RUN_TESTS_NOT_NEEDED is
// settings.json `allow` rather than `ask` *because* this machine-verifiable fact
// stands in for the human approval — so the check must be fail-closed here.
const { isDocsOnlyStaged } = require("../workflow-gate/staged-evidence");

// A *_NOT_NEEDED sentinel is the model ASSERTING that a step is unnecessary — the
// hook observed no work, only the claim. Every member of the class carries the same
// provenance (CPR-ORTH), so a reader can tell a declared skip from an observed one.
const DECLARED = { gate: "sentinel", provenance: "declared", origin: "mark-step" };

function declareSkip(sessionId, step, reason) {
  return recordStepVerdict(sessionId, step, "skipped", Object.assign({ skipReason: reason }, DECLARED));
}
const {
  RESEARCH_NOT_NEEDED_RE_DQ, RESEARCH_NOT_NEEDED_LOOKSLIKE_RE,
  OUTLINE_NOT_NEEDED_RE_DQ, OUTLINE_NOT_NEEDED_LOOKSLIKE_RE,
  DETAIL_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_LOOKSLIKE_RE,
  WRITE_TESTS_NOT_NEEDED_RE_DQ, WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE,
  RUN_TESTS_NOT_NEEDED_RE_DQ, RUN_TESTS_NOT_NEEDED_LOOKSLIKE_RE,
  REVIEW_SECURITY_NOT_NEEDED_RE_DQ, REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE,
  DOCS_NOT_NEEDED_LOOKSLIKE_RE,
  CLARIFY_INTENT_NOT_NEEDED_RE_DQ, CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE,
} = require("../lib/sentinel-patterns");

function handle(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal, repoCwd } = ctx;

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
          `Re-run: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {better reason}>>"`
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
    const res = declareSkip(sessionId, "research", v.reason);
    if (!res.ok) {
      pushMessage(
        `workflow-mark: failed to write state — ${res.detail || res.message}. research NOT recorded.`
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
        `Re-run: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {better reason}>>"`);
      return true;
    }
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — outline NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: ${v.reason}>>"`);
      return true;
    }
    // The A-4 speculative skip verdict is co-written by recordStepVerdict.
    const res = declareSkip(sessionId, "outline", v.reason);
    if (!res.ok) {
      pushMessage(`workflow-mark: failed to write state — ${res.detail || res.message}. outline NOT recorded.`);
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
        `Re-run: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {better reason}>>"`);
      return true;
    }
    if (!sessionId) {
      signalFatal(`workflow-mark: could not resolve session_id — detail NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: ${v.reason}>>"`);
      return true;
    }
    // The A-4 speculative skip verdict is co-written by recordStepVerdict.
    const res = declareSkip(sessionId, "detail", v.reason);
    if (!res.ok) {
      pushMessage(`workflow-mark: failed to write state — ${res.detail || res.message}. detail NOT recorded.`);
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
          `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {better reason}>>"`
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
    // The D1 BUGFIX defense (#1147 T0-A) and the #833 symmetric propagation to
    // review_tests both live in recordStepVerdict now: D1 is the skippable-steps
    // constraint every declaring path shares, so it can no longer be true on one
    // door and absent on another.
    const res = declareSkip(sessionId, "write_tests", v.reason);
    if (!res.ok && res.kind === "not-skippable") {
      pushMessage(
        `workflow-mark: WRITE_TESTS_NOT_NEEDED rejected — BUGFIX sessions require ` +
          `tests (fail-before-fix policy). Run /write-tests instead.`
      );
    } else if (!res.ok) {
      pushMessage(
        `workflow-mark: failed to write state — ${res.detail || res.message}. write_tests NOT recorded.`
      );
    }
    return true;
  }

  // --- RUN_TESTS_NOT_NEEDED handler ---
  const runTestsNotNeededMatch = cmd.match(RUN_TESTS_NOT_NEEDED_RE_DQ);
  const runTestsNotNeededLooksLike =
    !runTestsNotNeededMatch && RUN_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  if (runTestsNotNeededLooksLike) {
    pushMessage(
      `workflow-mark: malformed RUN_TESTS_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (runTestsNotNeededMatch) {
    const v = validateSkipReason(runTestsNotNeededMatch[1]);
    if (!v.ok) {
      pushMessage(
        `workflow-mark: RUN_TESTS_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {better reason}>>"`
      );
      return true;
    }
    // Fail-closed: the docs-only staged set IS the approval. Verified before the
    // write, so a rejection can never leave a half-recorded skip behind.
    if (!isDocsOnlyStaged(repoCwd)) {
      pushMessage(
        `workflow-mark: WORKFLOW_RUN_TESTS_NOT_NEEDED rejected — the staged set is not ` +
          `human-facing docs only. Run the tests (/run-tests), or stage only docs/*.md ` +
          `and root README/CHANGELOG/CONTRIBUTING/LICENSE before re-emitting.`
      );
      return true;
    }
    if (!sessionId) {
      signalFatal(
        `workflow-mark: could not resolve session_id — run_tests NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: ${v.reason}>>"`
      );
      return true;
    }
    const res = declareSkip(sessionId, "run_tests", v.reason);
    if (!res.ok) {
      pushMessage(
        `workflow-mark: failed to write state — ${res.detail || res.message}. run_tests NOT recorded.`
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
          `Re-run: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: {better reason}>>"`
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
    const res = declareSkip(sessionId, "review_security", v.reason);
    if (!res.ok) {
      pushMessage(
        `workflow-mark: failed to write state — ${res.detail || res.message}. review_security NOT recorded.`
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
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {better reason}>>"`
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
    const res = declareSkip(sessionId, "clarify_intent", v.reason);
    if (!res.ok) {
      pushMessage(
        `workflow-mark: failed to write state — ${res.detail || res.message}. clarify_intent NOT recorded.`
      );
    }
    return true;
  }

  return false;
}

module.exports = { handle };
