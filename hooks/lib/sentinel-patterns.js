#!/usr/bin/env node
// SSOT for workflow sentinel echo recognition (regex constants + isSentinel).
// Required by:
//   - workflow-mark.js (PostToolUse): dispatches per-sentinel state updates
//   - workflow-gate.js (PreToolUse):  blocks <<WORKFLOW_*>> && <other> chains
//
// This module exports recognition primitives only — the strict per-sentinel
// regex constants and the isSentinel() predicate. Chain detection is NOT
// centralized; each consumer implements it inline because the two layers
// have intentionally different requirements:
//
//   - workflow-mark.js uses a naive `command.split(/\s*&&\s*/)` to dispatch
//     each part. It applies all-or-nothing on the resulting fragments
//     (issue #110). Behavior is left unchanged (issue #382 non-goal).
//
//   - workflow-gate.js uses a stricter form-aware detector: it checks for
//     any non-sentinel residue chained via `&&` using chain-boundary anchored
//     regexes (CHAIN_BOUNDARY_SENTINEL_*) that handle sentinel reason text
//     containing `&&` correctly.
//
// Both detectors agree on the set of valid sentinels via isSentinel().
// The asymmetry is safe because workflow-gate.js runs first: any input it
// blocks never reaches workflow-mark.js, so the layers cannot disagree on
// a passed-through command.
//
// When adding a new sentinel: define the strict DQ regex and (where applicable)
// the LOOKSLIKE fallback, then add both tests to isSentinel().

"use strict";

// Strict anchored regex: each sub-command must be exactly this echo.
// Rejects pipes, ;, redirects, prefixed cd, printf, etc. by construction.
// Chained `&&` is handled at the splitter layer — each part is matched individually.
const MARKER_RE_DQ =
  /^echo\s+"<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>"$/;
const MARKER_RE_SQ =
  /^echo\s+'<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>'$/;
const RESET_FROM_RE_DQ = /^echo\s+"<<WORKFLOW_RESET_FROM_([a-z_]+)>>"$/;
// USER_VERIFIED/ENFORCE_WORKTREE_OFF/ON: reason mandatory; bare form falls through to LOOKSLIKE rejection. Aligns with `_NOT_NEEDED_*` family.
const USER_VERIFIED_RE_DQ = /^echo "<<WORKFLOW_USER_VERIFIED: ([^>]+)>>"$/;
const USER_VERIFIED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_USER_VERIFIED([: ].*)?>>"$/;
const RESEARCH_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ([^>]+)>>"$/;
const RESEARCH_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_RESEARCH_NOT_NEEDED([: ].*)?>>"$/;
const OUTLINE_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: ([^>]+)>>"$/;
const OUTLINE_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_OUTLINE_NOT_NEEDED([: ].*)?>>"$/;
const DETAIL_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_DETAIL_NOT_NEEDED: ([^>]+)>>"$/;
const DETAIL_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_DETAIL_NOT_NEEDED([: ].*)?>>"$/;
const WRITE_TESTS_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: ([^>]+)>>"$/;
const WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED([: ].*)?>>"$/;
const REVIEW_SECURITY_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: ([^>]+)>>"$/;
const REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED([: ].*)?>>"$/;
// Looks-like fallback for removed DOCS_NOT_NEEDED — catches attempts and emits deprecation message.
const DOCS_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_DOCS_NOT_NEEDED([: ].*)?>>"$/;
const CLARIFY_INTENT_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: ([^>]+)>>"$/;
const CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED([: ].*)?>>"$/;
const CLARIFY_INTENT_COMPLETE_RE_DQ = /^echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"$/;
// New sentinel (preferred); old BRANCHING_DECIDED accepted for backward compat.
const BRANCHING_COMPLETE_RE_DQ = /^echo "<<WORKFLOW_BRANCHING_COMPLETE: ([^>]+)>>"$/;
const BRANCHING_COMPLETE_LOOKSLIKE_RE = /^echo "<<WORKFLOW_BRANCHING_COMPLETE([: ].*)?>>"$/;
const BRANCHING_DECIDED_RE_DQ = /^echo "<<WORKFLOW_BRANCHING_DECIDED: ([^>]+)>>"$/;
const BRANCHING_DECIDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_BRANCHING_DECIDED([: ].*)?>>"$/;
const PREMISE_FAIL_RE_DQ = /^echo "<<WORKFLOW_PREMISE_FAIL: ([^>]+)>>"$/;
const PREMISE_FAIL_LOOKSLIKE_RE = /^echo "<<WORKFLOW_PREMISE_FAIL([: ].*)?>>"$/;
const PREMISE_ACK_RE_DQ = /^echo "<<WORKFLOW_PREMISE_ACK>>"$/;
const PREMISE_ACK_LOOKSLIKE_RE = /^echo "<<WORKFLOW_PREMISE_ACK([: ].*)?>>"$/;
const ENFORCE_WORKTREE_OFF_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: ([^>]+)>>"$/;
const ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF([: ].*)?>>"$/;
const ENFORCE_WORKTREE_ON_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: ([^>]+)>>"$/;
const ENFORCE_WORKTREE_ON_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_ON([: ].*)?>>"$/;
const ENFORCE_WORKFLOW_OFF_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: ([^>]+)>>"$/;
const ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF([: ].*)?>>"$/;
const ENFORCE_WORKFLOW_ON_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: ([^>]+)>>"$/;
const ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON([: ].*)?>>"$/;
// CONFIRM_<STAGE> sentinels emitted by clarify-intent / make-outline-plan /
// make-detail-plan after the artifact is written. PreToolUse `confirm-checkpoint.js`
// surfaces the dialog. Stop hook `stop-confirm-plan-guard.js` (Layer 2) returns
// `decision:block` + reason when no stage-valid follow-up Skill appears after the
// CONFIRM sentinel in the same assistant turn.
const CONFIRM_INTENT_RE_DQ = /^echo "<<WORKFLOW_CONFIRM_INTENT: ([^>]+)>>"$/;
const CONFIRM_INTENT_LOOKSLIKE_RE = /^echo "<<WORKFLOW_CONFIRM_INTENT([: ].*)?>>"$/;
const CONFIRM_OUTLINE_RE_DQ = /^echo "<<WORKFLOW_CONFIRM_OUTLINE: ([^>]+)>>"$/;
const CONFIRM_OUTLINE_LOOKSLIKE_RE = /^echo "<<WORKFLOW_CONFIRM_OUTLINE([: ].*)?>>"$/;
const CONFIRM_DETAIL_RE_DQ = /^echo "<<WORKFLOW_CONFIRM_DETAIL: ([^>]+)>>"$/;
const CONFIRM_DETAIL_LOOKSLIKE_RE = /^echo "<<WORKFLOW_CONFIRM_DETAIL([: ].*)?>>"$/;

// review_tests step (issue #833): structural QA gate that pairs with write_tests.
// COMPLETE carries a `token=<hex>` payload that fingerprints the staged tests/
// snapshot at sentinel-emission time — workflow-gate compares against a freshly
// computed token to detect re-edits-after-review (stale-token / anti-bypass).
// WARNINGS carries `token=<hex>` plus an advisory summary; still marks complete
// so the workflow can progress but records the warnings for downstream visibility.
const REVIEW_TESTS_COMPLETE_RE_DQ =
  /^echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: ([^>]+)>>"$/;
const REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE([: ].*)?>>"\s*$/;
const REVIEW_TESTS_WARNINGS_RE_DQ =
  /^echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: ([^>]+)>>"$/;
const REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS([: ].*)?>>"\s*$/;

function isSentinel(cmd) {
  return (
    MARKER_RE_DQ.test(cmd) ||
    MARKER_RE_SQ.test(cmd) ||
    RESET_FROM_RE_DQ.test(cmd) ||
    USER_VERIFIED_RE_DQ.test(cmd) ||
    USER_VERIFIED_LOOKSLIKE_RE.test(cmd) ||
    RESEARCH_NOT_NEEDED_RE_DQ.test(cmd) ||
    RESEARCH_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    OUTLINE_NOT_NEEDED_RE_DQ.test(cmd) ||
    OUTLINE_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    DETAIL_NOT_NEEDED_RE_DQ.test(cmd) ||
    DETAIL_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    WRITE_TESTS_NOT_NEEDED_RE_DQ.test(cmd) ||
    WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    REVIEW_SECURITY_NOT_NEEDED_RE_DQ.test(cmd) ||
    REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    DOCS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    CLARIFY_INTENT_NOT_NEEDED_RE_DQ.test(cmd) ||
    CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_COMPLETE_LOOKSLIKE_RE.test(cmd) ||
    BRANCHING_DECIDED_RE_DQ.test(cmd) ||
    BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd) ||
    PREMISE_FAIL_RE_DQ.test(cmd) ||
    PREMISE_FAIL_LOOKSLIKE_RE.test(cmd) ||
    PREMISE_ACK_RE_DQ.test(cmd) ||
    PREMISE_ACK_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKTREE_OFF_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKTREE_ON_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_ON_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKFLOW_OFF_RE_DQ.test(cmd) ||
    ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKFLOW_ON_RE_DQ.test(cmd) ||
    ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE.test(cmd) ||
    CONFIRM_INTENT_RE_DQ.test(cmd) ||
    CONFIRM_INTENT_LOOKSLIKE_RE.test(cmd) ||
    CONFIRM_OUTLINE_RE_DQ.test(cmd) ||
    CONFIRM_OUTLINE_LOOKSLIKE_RE.test(cmd) ||
    CONFIRM_DETAIL_RE_DQ.test(cmd) ||
    CONFIRM_DETAIL_LOOKSLIKE_RE.test(cmd) ||
    REVIEW_TESTS_COMPLETE_RE_DQ.test(cmd) ||
    REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE.test(cmd) ||
    REVIEW_TESTS_WARNINGS_RE_DQ.test(cmd) ||
    REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE.test(cmd)
  );
}

// Used by workflow-gate.js Step 1 (early-approve of standalone sentinels).
// Uses only strict DQ/SQ regexes — LOOKSLIKE fallbacks use greedy `.*` that
// can span across `>>` and incorrectly match chained commands as single
// sentinels. Strict DQ regexes use `[^>]+` for reason fields, which stops at
// the first `>` and correctly rejects `echo "<<SENTINEL: reason>>" && other`.
function isStrictSentinel(cmd) {
  return (
    MARKER_RE_DQ.test(cmd) || MARKER_RE_SQ.test(cmd) ||
    RESET_FROM_RE_DQ.test(cmd) || USER_VERIFIED_RE_DQ.test(cmd) ||
    RESEARCH_NOT_NEEDED_RE_DQ.test(cmd) ||
    OUTLINE_NOT_NEEDED_RE_DQ.test(cmd) ||
    DETAIL_NOT_NEEDED_RE_DQ.test(cmd) ||
    WRITE_TESTS_NOT_NEEDED_RE_DQ.test(cmd) ||
    REVIEW_SECURITY_NOT_NEEDED_RE_DQ.test(cmd) ||
    CLARIFY_INTENT_NOT_NEEDED_RE_DQ.test(cmd) ||
    CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_DECIDED_RE_DQ.test(cmd) ||
    PREMISE_FAIL_RE_DQ.test(cmd) ||
    PREMISE_ACK_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_OFF_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_ON_RE_DQ.test(cmd) ||
    ENFORCE_WORKFLOW_OFF_RE_DQ.test(cmd) ||
    ENFORCE_WORKFLOW_ON_RE_DQ.test(cmd) ||
    CONFIRM_INTENT_RE_DQ.test(cmd) ||
    CONFIRM_OUTLINE_RE_DQ.test(cmd) ||
    CONFIRM_DETAIL_RE_DQ.test(cmd) ||
    REVIEW_TESTS_COMPLETE_RE_DQ.test(cmd) ||
    REVIEW_TESTS_WARNINGS_RE_DQ.test(cmd)
  );
}

// --- Chain-boundary form detectors (used by workflow-gate.js only) ---
//
// These are intentionally BROADER than any individual isSentinel() regex
// above. They detect "anything that looks like a sentinel echo at a chain
// boundary" rather than checking strict-vs-lookslike per category. The
// boundary prefix `(?:^|&&\s*)` requires the echo to appear at the start of
// the command or immediately after `&&` — this rules out sentinel-shaped
// substrings that live inside another command's argument (e.g.
// `printf 'echo "<<WORKFLOW_X>>"' && wc -l`), which are not real chains.
//
// Quote convention parity with isSentinel():
//   - DQ form accepts all sentinel categories: [A-Za-z_]+ covers both
//     uppercase-only names (USER_VERIFIED) and mixed-case suffix forms
//     (MARK_STEP_docs_complete, RESET_FROM_research).
//   - SQ form is restricted to MARK_STEP, matching MARKER_RE_SQ — no other
//     category accepts single quotes in isSentinel(), so the detector must
//     not accept them either (otherwise it would block chains that
//     workflow-mark.js treats as non-sentinel, creating new asymmetry).
//
// Notes:
//   - No `/g` flag — used with `.test()` only, never with `.replace()`. This
//     avoids the stateful lastIndex hazard.
//   - The pattern is exported for workflow-gate.js. workflow-mark.js does NOT
//     use it; it splits naively and dispatches per the strict isSentinel()
//     regexes.
//
// Character class [A-Za-z_]+ covers all current sentinel name forms:
//   - Uppercase + underscore:        <<WORKFLOW_USER_VERIFIED>>
//   - Mixed case (suffix lowercase): <<WORKFLOW_MARK_STEP_docs_complete>>,
//                                    <<WORKFLOW_RESET_FROM_research>>
// Using [A-Z_]+ alone would miss these mixed-case forms (e.g. the core
// silent-failure case `echo "<<WORKFLOW_MARK_STEP_docs_complete>>" && rm /tmp/x`).
const CHAIN_BOUNDARY_SENTINEL_DQ_RE =
  /(?:^|&&\s*)echo\s+"<<WORKFLOW_[A-Za-z_]+(?:[: ][^>]*)?>>"/;
const CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE =
  /(?:^|&&\s*)echo\s+'<<WORKFLOW_MARK_STEP_[a-z_]+_(?:complete|skipped|pending|in_progress)>>'/;

// All regex constants are exported because workflow-mark.js dispatches to
// per-sentinel state-update handlers by matching each constant individually
// after splitting a multi-sentinel command. Exporting all constants keeps
// workflow-mark.js a thin consumer with no regex duplication.
module.exports = {
  isSentinel,
  isStrictSentinel,
  CHAIN_BOUNDARY_SENTINEL_DQ_RE,
  CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
  MARKER_RE_DQ, MARKER_RE_SQ, RESET_FROM_RE_DQ, USER_VERIFIED_RE_DQ,
  USER_VERIFIED_LOOKSLIKE_RE,
  RESEARCH_NOT_NEEDED_RE_DQ, RESEARCH_NOT_NEEDED_LOOKSLIKE_RE,
  OUTLINE_NOT_NEEDED_RE_DQ, OUTLINE_NOT_NEEDED_LOOKSLIKE_RE,
  DETAIL_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_LOOKSLIKE_RE,
  WRITE_TESTS_NOT_NEEDED_RE_DQ, WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE,
  REVIEW_SECURITY_NOT_NEEDED_RE_DQ, REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE,
  DOCS_NOT_NEEDED_LOOKSLIKE_RE,
  CLARIFY_INTENT_NOT_NEEDED_RE_DQ, CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE,
  CLARIFY_INTENT_COMPLETE_RE_DQ,
  BRANCHING_COMPLETE_RE_DQ, BRANCHING_COMPLETE_LOOKSLIKE_RE,
  BRANCHING_DECIDED_RE_DQ, BRANCHING_DECIDED_LOOKSLIKE_RE,
  PREMISE_FAIL_RE_DQ, PREMISE_FAIL_LOOKSLIKE_RE,
  PREMISE_ACK_RE_DQ, PREMISE_ACK_LOOKSLIKE_RE,
  ENFORCE_WORKTREE_OFF_RE_DQ, ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE,
  ENFORCE_WORKTREE_ON_RE_DQ, ENFORCE_WORKTREE_ON_LOOKSLIKE_RE,
  ENFORCE_WORKFLOW_OFF_RE_DQ, ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE,
  ENFORCE_WORKFLOW_ON_RE_DQ, ENFORCE_WORKFLOW_ON_LOOKSLIKE_RE,
  CONFIRM_INTENT_RE_DQ, CONFIRM_INTENT_LOOKSLIKE_RE,
  CONFIRM_OUTLINE_RE_DQ, CONFIRM_OUTLINE_LOOKSLIKE_RE,
  CONFIRM_DETAIL_RE_DQ, CONFIRM_DETAIL_LOOKSLIKE_RE,
  REVIEW_TESTS_COMPLETE_RE_DQ,
  REVIEW_TESTS_COMPLETE_LOOKSLIKE_RE,
  REVIEW_TESTS_WARNINGS_RE_DQ,
  REVIEW_TESTS_WARNINGS_LOOKSLIKE_RE,
};
