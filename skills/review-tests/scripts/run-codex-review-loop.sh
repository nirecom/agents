#!/bin/bash
set -euo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Workflow session id (plan-artifact prefix), NOT the CC session UUID resolved below
# via bin/resolve-session-id. The wsid has no bash bridge yet, so this stays a manual
# input box until a future session replaces it — see session-id-resolution.md.
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# #1361: terminal marker written after a non-success terminal exit. Line 1 = terminal
# rc, line 2 = review-scope fingerprint at that moment (same computeReviewScopeFingerprint
# SSOT the gate uses for stale-review detection). Terminal and exit-6 accept marker
# live in <sid>.control/ (#2434); exit 8/9 are the wrapper's own codes.
# shellcheck source=bin/lib/codex-review-loop/review-wrapper-control.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/lib/codex-review-loop/review-wrapper-control.sh" || exit 4
# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$SCRIPT_CHECKOUT_ROOT/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" detail outline intent)" || exit 4
rwc_resolve test-review review-tests
EXIT_REINVOKE_AFTER_TERMINAL=8

# Exits 4, 7 and 8 leave this script without reaching the completion sentinel
# that records every other outcome, so a resumed session would find no trace of
# them. Never allowed to change the review's own verdict.
record_codex_exit() {
  local rc="$1" path_taken="$2"
  node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/handoff-append" \
    --session "$SESSION_ID" --class D --step review_tests --key review-tests:codex-exit \
    --summary "codex test review ended at exit $rc via $path_taken, before the completion sentinel" \
    --pointer "$PLANS_DIR/$SESSION_ID-test-review.md" --origin procedure-point >/dev/null 2>&1 || true
}

# Print the current review-scope fingerprint on stdout. Returns 4 when the calculation
# reports ok: false (git error — HALT), 1 on any other failure (node/require) or an
# empty scope, so the guard below stays fail-closed.
compute_review_scope_fingerprint() {
  local repo_root="$1" fp rc=0
  fp="$(node -e 'const {computeReviewScopeFingerprint}=require(process.argv[2]+"/hooks/workflow-gate/review-tests-evidence.js"); const r=computeReviewScopeFingerprint(process.argv[1]); if(!r.ok){process.stderr.write("review-scope fingerprint unavailable: "+r.error+"\n"); process.exit(4);} process.stdout.write(r.fingerprint||"")' "$repo_root" "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null)" || rc=$?
  if (( rc == 4 )); then return 4; fi
  (( rc == 0 )) || return 1
  [[ -n "$fp" ]] || return 1
  printf '%s' "$fp"
}

# Session-bound commit-target resolution (#1316): never trust CWD, never select main worktree.
# Resolved before the re-invoke guard (#1361) because the guard needs REPO_ROOT_VAL.
# The CC session id is resolved explicitly first (SSOT: bin/resolve-session-id) and
# handed on via --session. Only rc 2 means "no session"; any other rc is a bridge
# fault and takes this script's existing exit 4 HALT path, never the exit 3 skip.
BRIDGE_RC=0
CC_SID="$("$SCRIPT_CHECKOUT_ROOT/bin/resolve-session-id")" || BRIDGE_RC=$?
case "$BRIDGE_RC" in
  0) ;;
  2) CC_SID="" ;;
  *) echo "[review-tests] ERROR: bin/resolve-session-id failed (rc $BRIDGE_RC)" >&2; exit 4 ;;
esac
COMMIT_TARGET="$("$SCRIPT_CHECKOUT_ROOT/bin/resolve-worktree-path" ${CC_SID:+--session "$CC_SID"})"
# NOSTATE (session resolved, no state file) and "" (no session resolved at all) are
# both legitimate bin/resolve-worktree-path outcomes -- neither is an error, so both
# fall back to CWD identically (#2270: previously only NOSTATE fell back, which masked
# on the fact that bare SESSION_ID used to leak into CC-session resolution and made
# empty-COMMIT_TARGET effectively unreachable from a real git repo).
if [[ "$COMMIT_TARGET" == "NOSTATE" || -z "$COMMIT_TARGET" ]]; then
  COMMIT_TARGET="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -z "$COMMIT_TARGET" ]]; then
    if [[ -f "$TERMINAL_FILE" ]]; then
      # fail-CLOSED: cannot compare fingerprints, so the guard must stay armed.
      echo "[review-tests] ERROR: terminal marker present but commit-target is unresolvable; keeping the re-invoke guard." >&2
      record_codex_exit "$EXIT_REINVOKE_AFTER_TERMINAL" "no-sentinel"
      exit "$EXIT_REINVOKE_AFTER_TERMINAL"
    fi
    echo "[review-tests] WARNING: no session state and not in a git repo; skipping test review." >&2
    exit 3
  fi
fi
REPO_ROOT_VAL="$COMMIT_TARGET"

# --- #1361 re-invoke guard ---
if [[ -f "$TERMINAL_FILE" ]]; then
  # fail-CLOSED: a compare failure is not evidence that the review scope changed;
  # only a git error (rc 4) HALTs instead of arming exit 8.
  CUR_FP=""
  FP_RC=0
  CUR_FP="$(compute_review_scope_fingerprint "$REPO_ROOT_VAL")" || FP_RC=$?
  if (( FP_RC == 4 )); then
    echo "[review-tests] ERROR: the review-scope fingerprint calculation failed (git error in $REPO_ROOT_VAL). HALT." >&2
    record_codex_exit 4 "HALT"
    exit 4
  fi
  TG_RC=0
  rwc_check_terminal review-tests "$CUR_FP" review-tests-exit6-accepted.txt test-review || TG_RC=$?
  case "$TG_RC" in
    0) ;;
    8) echo "[review-tests] The WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED sentinel also accepts the coverage gap." >&2
       record_codex_exit 8 "no-sentinel"; exit 8 ;;
    *) echo "[review-tests] Equivalent accept path: emit WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED." >&2
       exit "$TG_RC" ;;
  esac
fi

arm_terminal_guard() {
  local rc=$1 fp
  case "$rc" in
    # Terminal exits (2=ESCALATE, 3=codex-unavailable, 6=HIGH_UNRESOLVED, 7=FINALIZE_FAILED)
    # retire the round counter; arm guard so unchanged-input re-invocation is blocked.
    # exit 1 (round-continuing) must NOT arm (#2276 S9-c). exit 4 is config error, no guard.
    2|3|6|7)
      fp="$(compute_review_scope_fingerprint "$REPO_ROOT_VAL")" || fp=""
      rwc_arm_terminal "$rc" "$fp"
      ;;
  esac
  return "$rc"
}

args=(
  --format test-review
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/$SESSION_ID-test-review.md"
  --cap 2 --max-extensions 1 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$ACCEPTED_TRADEOFFS_FILE"
  --class-members "$PLANS_DIR/$SESSION_ID-intent.md"
  --repo-root "$REPO_ROOT_VAL"
)

# Soft scope (#1371): scope the review to files changed in this PR diff.
CHANGED_FILES_CTX=""
if [[ "${REVIEW_TESTS_FULL_SCAN:-0}" != "1" ]]; then
  MERGE_BASE="$(git -C "$REPO_ROOT_VAL" merge-base HEAD "$(git -C "$REPO_ROOT_VAL" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)" 2>/dev/null || true)"
  if [[ -n "$MERGE_BASE" ]]; then
    CHANGED_FILES_FILE="$CONTROL_DIR/changed-files.txt"
    {
      echo "## Changed files in this PR (scan scope)"
      git -C "$REPO_ROOT_VAL" diff --name-only "${MERGE_BASE}...HEAD"
    } > "$CHANGED_FILES_FILE"
    CHANGED_FILES_CTX="$CHANGED_FILES_FILE"
  fi
fi
# CTX_CONCERNS_LOG is auto-generated from the ledger, never inherited (#2185): a
# stale parent value would leak an old carrier into this review. The CLI prints
# the carrier path only when it holds something to carry (rc 0); rc 3 is benign
# (nothing to carry), rc 5 is a real failure we warn about but do not fail on.
unset CTX_CONCERNS_LOG
clog_rc=0
CLOG_PATH="$("$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger" render-concerns-log \
  --plans-dir "$PLANS_DIR" --session-id "$SESSION_ID" --format test-review)" || clog_rc=$?
if (( clog_rc == 0 )) && [[ -n "$CLOG_PATH" && -s "$CLOG_PATH" ]]; then
  export CTX_CONCERNS_LOG="$CLOG_PATH"
elif (( clog_rc != 0 && clog_rc != 3 )); then
  printf 'warning: concerns-log render failed (rc=%s); proceeding without CTX_CONCERNS_LOG\n' "$clog_rc" >&2
fi
for v in CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG; do
  p="${!v:-}"
  if [[ -n "$p" && -s "$p" ]]; then args+=(--context "$p"); fi
done
TEST_DESIGN="$SCRIPT_CHECKOUT_ROOT/skills/_shared/test-design.md"
if [[ -s "$TEST_DESIGN" ]]; then args+=(--context "$TEST_DESIGN"); fi
PARSER_TESTS="$SCRIPT_CHECKOUT_ROOT/skills/_shared/test-design/parser-regex-tests.md"
if [[ -s "$PARSER_TESTS" ]]; then args+=(--context "$PARSER_TESTS"); fi
PROTECTION_TESTS="$SCRIPT_CHECKOUT_ROOT/skills/_shared/test-design/protection-fix-tests.md"
if [[ -s "$PROTECTION_TESTS" ]]; then args+=(--context "$PROTECTION_TESTS"); fi
if [[ -n "$CHANGED_FILES_CTX" ]]; then args+=(--context "$CHANGED_FILES_CTX"); fi
RC=0
# #1455: the reviewer output is captured (and still streamed) so a line-start
# INPUT_ERROR <path> can HALT via the same detector the CC fallback uses.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_OUT="$(mktemp "${PLANS_DIR}/.rt-out-XXXXXX")" || exit 4
"$SCRIPT_CHECKOUT_ROOT/bin/run-codex-review-loop" "${args[@]}" | tee "$REVIEW_OUT" || RC=${PIPESTATUS[0]}
DETECT_RC=0
bash "$SCRIPT_DIR/detect-input-error.sh" "$REVIEW_OUT" || DETECT_RC=$?
rm -f "$REVIEW_OUT"
if (( DETECT_RC != 0 )); then
  # Input contract violated (or output unreadable): HALT without arming the terminal guard.
  echo "[review-tests] ERROR: the reviewer could not read a review target (INPUT_ERROR); HALT." >&2
  record_codex_exit 4 "HALT"
  exit 4
fi
arm_terminal_guard "$RC" || true
case "$RC" in
  4|7) record_codex_exit "$RC" "HALT" ;;
esac
exit "$RC"
