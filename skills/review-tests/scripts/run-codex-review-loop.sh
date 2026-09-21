#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
# Workflow session id (plan-artifact prefix), NOT the CC session UUID resolved below
# via bin/resolve-session-id. The wsid has no bash bridge yet, so this stays a manual
# input box until a future session replaces it — see session-id-resolution.md.
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

# #1361: terminal marker written after a non-success terminal exit. Line 1 = terminal
# rc, line 2 = staged-tests fingerprint at that moment (same computeStagedTestsToken
# SSOT the gate uses for stale-review detection).
TERMINAL_FILE="${PLANS_DIR}/${SESSION_ID}-test-review-terminal.txt"
# Accept marker for residual HIGH after an exit 6 terminal: its presence authorizes the
# fingerprint-mismatch branch to clear the guard even when the prior terminal was exit 6.
# Equivalent accept path to the WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED sentinel.
EXIT6_ACCEPT_FILE="${PLANS_DIR}/${SESSION_ID}-review-tests-exit6-accepted.txt"
# Dedicated exit code for "re-invoked after a terminal exit with tests unchanged".
# Does not collide with bin/run-codex-review-loop's codes (0-7).
EXIT_REINVOKE_AFTER_TERMINAL=8
# exit 6 termination occurred, content changed, but residual HIGH not accepted → re-run blocked.
EXIT_EXIT6_UNACCEPTED=9

# Exits 4, 7 and 8 leave this script without reaching the completion sentinel
# that records every other outcome, so a resumed session would find no trace of
# them. Never allowed to change the review's own verdict.
record_codex_exit() {
  local rc="$1" path_taken="$2"
  node "$AGENTS_CONFIG_DIR/bin/workflow/handoff-append" \
    --session "$SESSION_ID" --class D --step review_tests --key review-tests:codex-exit \
    --summary "codex test review ended at exit $rc via $path_taken, before the completion sentinel" \
    --pointer "$PLANS_DIR/$SESSION_ID-test-review.md" --origin step-end >/dev/null 2>&1 || true
}

# Print the current staged-tests fingerprint on stdout. Returns non-zero when it
# cannot be computed (node/require/git failure, or no staged tests → empty token).
compute_staged_tests_fingerprint() {
  local repo_root="$1" fp
  fp="$(node -e 'const {computeStagedTestsToken}=require(process.env.AGENTS_CONFIG_DIR+"/hooks/workflow-gate/review-tests-evidence.js"); process.stdout.write(computeStagedTestsToken(process.argv[1])||"")' "$repo_root" 2>/dev/null)" || return 1
  [[ -n "$fp" ]] || return 1
  printf '%s' "$fp"
}

# Session-bound commit-target resolution (#1316): never trust CWD, never select main worktree.
# Resolved before the re-invoke guard (#1361) because the guard needs REPO_ROOT_VAL.
# The CC session id is resolved explicitly first (SSOT: bin/resolve-session-id) and
# handed on via --session. Only rc 2 means "no session"; any other rc is a bridge
# fault and takes this script's existing exit 4 HALT path, never the exit 3 skip.
BRIDGE_RC=0
CC_SID="$("$AGENTS_CONFIG_DIR/bin/resolve-session-id")" || BRIDGE_RC=$?
case "$BRIDGE_RC" in
  0) ;;
  2) CC_SID="" ;;
  *) echo "[review-tests] ERROR: bin/resolve-session-id failed (rc $BRIDGE_RC)" >&2; exit 4 ;;
esac
COMMIT_TARGET="$("$AGENTS_CONFIG_DIR/bin/resolve-worktree-path" ${CC_SID:+--session "$CC_SID"})"
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
  PREV_RC="$(sed -n '1p' "$TERMINAL_FILE" 2>/dev/null || true)"
  PREV_FP="$(sed -n '2p' "$TERMINAL_FILE" 2>/dev/null || true)"
  CUR_FP=""
  if ! CUR_FP="$(compute_staged_tests_fingerprint "$REPO_ROOT_VAL")"; then
    CUR_FP=""
  fi
  if [[ -z "$CUR_FP" || -z "$PREV_FP" ]]; then
    # fail-CLOSED: a compare failure is not evidence that tests changed.
    echo "[review-tests] ERROR: previous test review ended with a terminal exit (code=${PREV_RC:-?}) and the staged-tests fingerprint could not be compared. Keeping the guard armed. Accept the gap with WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED, or re-edit and re-stage tests/ before re-running." >&2
    record_codex_exit "$EXIT_REINVOKE_AFTER_TERMINAL" "no-sentinel"
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [[ "$CUR_FP" == "$PREV_FP" ]]; then
    echo "[review-tests] ERROR: previous test review ended with a terminal exit (code=${PREV_RC:-?}) and tests/ are unchanged. Re-looping now would defeat the 2+1 round cap. Accept the coverage gap with WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED, or re-create/re-stage tests/ and run again." >&2
    record_codex_exit "$EXIT_REINVOKE_AFTER_TERMINAL" "no-sentinel"
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [ "${PREV_RC:-}" = "6" ] && [ ! -f "$EXIT6_ACCEPT_FILE" ]; then
    printf '[review-tests] Tests changed after an exit 6 terminal, but residual HIGH findings are not accepted.\n  Accept marker: %s\n  Create it: touch "%s"\n  Or: emit WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED (both are equivalent accept paths).\n  Accept the residual HIGH by one of the above, then re-run.\n' "$EXIT6_ACCEPT_FILE" "$EXIT6_ACCEPT_FILE" >&2
    exit "$EXIT_EXIT6_UNACCEPTED"
  fi
  # Fingerprint mismatch = tests were re-edited = legitimate restart → auto-clear.
  rm -f "$TERMINAL_FILE"
fi

arm_terminal_guard() {
  local rc=$1 fp
  case "$rc" in
    # Terminal exits (2=ESCALATE, 3=codex-unavailable, 6=HIGH_UNRESOLVED, 7=FINALIZE_FAILED)
    # retire the round counter; arm guard so unchanged-input re-invocation is blocked.
    # exit 1 (round-continuing) must NOT arm (#2276 S9-c). exit 4 is config error, no guard.
    2|3|6|7)
      fp=""
      fp="$(compute_staged_tests_fingerprint "$REPO_ROOT_VAL")" || fp=""
      local _tmp
      _tmp="$(mktemp "${PLANS_DIR}/.sg-XXXXXX" 2>/dev/null)" || break
      printf '%s\n%s\n' "$rc" "$fp" > "$_tmp" || { rm -f "$_tmp"; break; }
      mv -f "$_tmp" "$TERMINAL_FILE" || rm -f "$_tmp"
      ;;
  esac
  return "$rc"
}

# The resolver's own 2/3 statuses sit outside the 0-7 review-loop protocol; remap to 4 (HALT)
# so a containment refusal is never read as ESCALATE or as codex-unavailable.
ACCEPTED_TRADEOFFS_FILE="$("$AGENTS_CONFIG_DIR/bin/resolve-accepted-tradeoffs-file" "$PLANS_DIR" "$SESSION_ID" detail outline intent)" || exit 4

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
    CHANGED_FILES_FILE="${PLANS_DIR}/${SESSION_ID}-changed-files.txt"
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
CLOG_PATH="$("$AGENTS_CONFIG_DIR/bin/concern-ledger" render-concerns-log \
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
TEST_DESIGN="$AGENTS_CONFIG_DIR/skills/_shared/test-design.md"
if [[ -s "$TEST_DESIGN" ]]; then args+=(--context "$TEST_DESIGN"); fi
PARSER_TESTS="$AGENTS_CONFIG_DIR/skills/_shared/test-design/parser-regex-tests.md"
if [[ -s "$PARSER_TESTS" ]]; then args+=(--context "$PARSER_TESTS"); fi
PROTECTION_TESTS="$AGENTS_CONFIG_DIR/skills/_shared/test-design/protection-fix-tests.md"
if [[ -s "$PROTECTION_TESTS" ]]; then args+=(--context "$PROTECTION_TESTS"); fi
if [[ -n "$CHANGED_FILES_CTX" ]]; then args+=(--context "$CHANGED_FILES_CTX"); fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
arm_terminal_guard "$RC" || true
case "$RC" in
  4|7) record_codex_exit "$RC" "HALT" ;;
esac
exit "$RC"
