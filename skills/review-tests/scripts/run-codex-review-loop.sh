#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"
: "${EXTENSIONS_USED:?EXTENSIONS_USED not set}"

ROUND_FILE="${PLANS_DIR}/${SESSION_ID}-test-review-round-number.txt"
if [[ -f "$ROUND_FILE" ]]; then
  ROUND_NUMBER=$(( $(<"$ROUND_FILE") + 1 ))
else
  ROUND_NUMBER=1
fi
printf '%s\n' "$ROUND_NUMBER" > "$ROUND_FILE"

cleanup_counter() {
  local rc=$1
  case "$rc" in
    0|1|2|4) rm -f "$ROUND_FILE" ;;
    # single-round terminal format: exit 1 is terminal (no re-loop), so clear too.
    # exit 5 (AUTO_EXTEND) does not occur here (MAX_EXTENSIONS=0).
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
)
# Session-bound commit-target resolution (#1316): never trust CWD, never select main worktree.
# Use the script's own path to locate state-io.js so tests can stub AGENTS_CONFIG_DIR freely.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
_REAL_AGENTS_DIR="$(cd "$_SELF_DIR/../../.." && { pwd -W 2>/dev/null || pwd; })"
COMMIT_TARGET="$(node -e "
try {
  const {readState}=require(process.argv[1]);
  const sid=process.env.SESSION_ID||process.env.CLAUDE_SESSION_ID||'';
  if(!sid){process.stdout.write('');process.exit(0);}
  const st=readState(sid);
  if(st===null){process.stdout.write('NOSTATE');process.exit(0);}
  if(!st.cwd){process.stdout.write('');process.exit(0);}
  const{execFileSync}=require('child_process');
  const gd=execFileSync('git',['-C',st.cwd,'rev-parse','--git-dir'],{encoding:'utf8'}).trim();
  const gc=execFileSync('git',['-C',st.cwd,'rev-parse','--git-common-dir'],{encoding:'utf8'}).trim();
  const p=require('path');
  if(p.resolve(gd)===p.resolve(gc)){process.stdout.write('');process.exit(0);}
  process.stdout.write(st.cwd);
} catch(e){process.stdout.write('');}
" -- "$_REAL_AGENTS_DIR/hooks/lib/workflow-state/state-io.js" 2>/dev/null)"
if [[ "$COMMIT_TARGET" == "NOSTATE" ]]; then
  # No state file: test fixture or first-run scenario. Fall back to CWD.
  COMMIT_TARGET="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -z "$COMMIT_TARGET" ]]; then
    echo "[review-tests] WARNING: no session state and not in a git repo; skipping test review." >&2
    exit 3
  fi
elif [[ -z "$COMMIT_TARGET" ]]; then
  echo "[review-tests] ERROR: cannot resolve commit-target worktree (session-bound source missing or main worktree). Skipping test review." >&2
  exit 3
fi
REPO_ROOT_VAL="$COMMIT_TARGET"
args+=(--repo-root "$REPO_ROOT_VAL")

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
if [[ -n "$CHANGED_FILES_CTX" ]]; then args+=(--context "$CHANGED_FILES_CTX"); fi
RC=0
"$AGENTS_CONFIG_DIR/bin/run-codex-review-loop" "${args[@]}" || RC=$?
cleanup_counter "$RC" || true
exit "$RC"
