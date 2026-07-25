#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

ROUND_FILE="${PLANS_DIR}/${SESSION_ID}-test-review-round-number.txt"
# #1361: terminal marker written after a non-success terminal exit. Line 1 = terminal
# rc, line 2 = staged-tests fingerprint at that moment (same computeStagedTestsToken
# SSOT the gate uses for stale-review detection).
TERMINAL_FILE="${PLANS_DIR}/${SESSION_ID}-test-review-terminal.txt"
# Dedicated exit code for "re-invoked after a terminal exit with tests unchanged".
# Does not collide with bin/run-codex-review-loop's codes (0-5).
EXIT_REINVOKE_AFTER_TERMINAL=6

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
COMMIT_TARGET="$("$AGENTS_CONFIG_DIR/bin/resolve-worktree-path")"
if [[ "$COMMIT_TARGET" == "NOSTATE" ]]; then
  # No state file: test fixture or first-run scenario. Fall back to CWD.
  COMMIT_TARGET="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -z "$COMMIT_TARGET" ]]; then
    if [[ -f "$TERMINAL_FILE" ]]; then
      # fail-CLOSED: cannot compare fingerprints, so the guard must stay armed.
      echo "[review-tests] ERROR: terminal marker present but commit-target is unresolvable; keeping the re-invoke guard." >&2
      exit "$EXIT_REINVOKE_AFTER_TERMINAL"
    fi
    echo "[review-tests] WARNING: no session state and not in a git repo; skipping test review." >&2
    exit 3
  fi
elif [[ -z "$COMMIT_TARGET" ]]; then
  if [[ -f "$TERMINAL_FILE" ]]; then
    echo "[review-tests] ERROR: terminal marker present but commit-target is unresolvable; keeping the re-invoke guard." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  echo "[review-tests] ERROR: cannot resolve commit-target worktree (session-bound source missing or main worktree). Skipping test review." >&2
  exit 3
fi
REPO_ROOT_VAL="$COMMIT_TARGET"

# --- #1361 re-invoke guard (before ROUND_FILE init so ROUND_NUMBER is never reset) ---
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
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  if [[ "$CUR_FP" == "$PREV_FP" ]]; then
    echo "[review-tests] ERROR: previous test review ended with a terminal exit (code=${PREV_RC:-?}) and tests/ are unchanged. Re-looping now would defeat --cap 1. Accept the coverage gap with WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED, or re-create/re-stage tests/ and run again." >&2
    exit "$EXIT_REINVOKE_AFTER_TERMINAL"
  fi
  # Fingerprint mismatch = tests were re-edited = legitimate restart → auto-clear.
  rm -f "$TERMINAL_FILE"
fi

if [[ -f "$ROUND_FILE" ]]; then
  ROUND_NUMBER=$(( $(<"$ROUND_FILE") + 1 ))
else
  ROUND_NUMBER=1
fi
printf '%s\n' "$ROUND_NUMBER" > "$ROUND_FILE"

cleanup_counter() {
  local rc=$1 fp
  case "$rc" in
    0|1|2|4) rm -f "$ROUND_FILE" ;;
    # single-round terminal format: exit 1 is terminal (no re-loop), so clear too.
    # exit 5 (AUTO_EXTEND) does not occur here (MAX_EXTENSIONS=0).
  esac
  case "$rc" in
    # Non-success terminal codes only: exit 0 (COMPLETE) must not arm the guard,
    # or a clean follow-up review would be wrongly blocked. exit 4 is unchanged.
    1|2)
      fp=""
      fp="$(compute_staged_tests_fingerprint "$REPO_ROOT_VAL")" || fp=""
      printf '%s\n%s\n' "$rc" "$fp" > "$TERMINAL_FILE" || true
      ;;
  esac
  return "$rc"
}

args=(
  --format test-review
  --session-id "$SESSION_ID"
  --plans-dir "$PLANS_DIR"
  --draft-file "$PLANS_DIR/$SESSION_ID-test-review.md"
  --cap 1 --max-extensions 0 --extensions-used "$EXTENSIONS_USED"
  --accepted-tradeoffs "$PLANS_DIR/$SESSION_ID-outline.md"
  --round "$ROUND_NUMBER"
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
cleanup_counter "$RC" || true
exit "$RC"
