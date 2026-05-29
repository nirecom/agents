#!/usr/bin/env bash
# Tests for issue #635 — PR approval phrase added to show-user-verified-context.js systemMessage.
# These tests assert the new fixed English approval-instruction line:
#   "Click Allow on the next dialog to approve; click Deny to stop."
# The phrase is the SSOT for the approval-dialog surrounding text; prompts must NOT duplicate it.
#
# TDD red phase: U13–U15 are expected to FAIL until hooks/show-user-verified-context.js
# is modified to append the approval line.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/show-user-verified-context.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 "$@"
  else
    perl -e 'alarm 60; exec @ARGV' -- "$@"
  fi
}

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
WORK_DIR="${NODE_TMPDIR}/feature-issue-635-pr-approval-test-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

run_hook() {
  local json="$1"
  echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

extract_msg() {
  run_with_timeout node -e "
    let d; try { d=JSON.parse(require('fs').readFileSync(0,'utf8')); } catch(e){process.exit(1);}
    process.stdout.write(d.systemMessage||'');
  " 2>/dev/null
}

# Sentinel JSON snippet (reason-bearing form — bare form removed in #404)
SENTINEL_CMD='echo \"<<WORKFLOW_USER_VERIFIED: issue-635 approval phrase test>>\"'

# Set up a temp git repo with a staged file
GIT_REPO="$WORK_DIR/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email "test@example.com"
git -C "$GIT_REPO" config user.name "Test"
echo "hello" > "$GIT_REPO/foo.txt"
git -C "$GIT_REPO" add foo.txt

# Empty repo for the no-PR / no-staged-files case
EMPTY_REPO="$WORK_DIR/empty-repo"
mkdir -p "$EMPTY_REPO"
git -C "$EMPTY_REPO" init -q
git -C "$EMPTY_REPO" config user.email "test@example.com"
git -C "$EMPTY_REPO" config user.name "Test"

EXPECTED_APPROVAL_LINE="Click Allow on the next dialog to approve; click Deny to stop."

# ── U13: Approval-phrase line present in systemMessage ─────────────────────
echo "=== U13: approval phrase line present (exact wording) ==="
U13_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
U13_RESULT=$(run_hook "$U13_JSON")
U13_MSG=$(echo "$U13_RESULT" | extract_msg)
if echo "$U13_MSG" | grep -qF "$EXPECTED_APPROVAL_LINE"; then
  pass "U13 approval phrase line present in systemMessage"
else
  fail "U13 — expected approval phrase '$EXPECTED_APPROVAL_LINE' in systemMessage, got: $U13_MSG"
fi

# ── U14: Approval phrase appears AFTER the Open PR line (ordering) ─────────
echo "=== U14: approval phrase ordering (after Open PR) ==="
IS_WINDOWS_U14=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_U14=1 ;;
esac
[ "${OS:-}" = "Windows_NT" ] && IS_WINDOWS_U14=1
if [ "$IS_WINDOWS_U14" = "1" ]; then
  # Node.js spawnSync on Windows cannot find bash-script shims via a POSIX-format PATH
  # inherited from Git-Bash (same constraint as U5 in feature-show-user-verified.sh).
  pass "U14 approval-phrase ordering — skipped on Windows (POSIX PATH not searchable by Node.js spawnSync)"
else
  GH_BIN_DIR_U14="$WORK_DIR/gh-shim-u14"
  mkdir -p "$GH_BIN_DIR_U14"
  cat > "$GH_BIN_DIR_U14/gh" << 'SHIM'
#!/usr/bin/env bash
echo "https://github.com/nirecom/agents/pull/635"
exit 0
SHIM
  chmod +x "$GH_BIN_DIR_U14/gh"
  U14_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$GIT_REPO\"}}"
  U14_RESULT=$(PATH="$GH_BIN_DIR_U14:$PATH" run_hook "$U14_JSON")
  U14_MSG=$(echo "$U14_RESULT" | extract_msg)
  PR_LINE_NO=$(echo "$U14_MSG" | grep -n "^Open PR:" | head -1 | cut -d: -f1)
  APPROVAL_LINE_NO=$(echo "$U14_MSG" | grep -nF "$EXPECTED_APPROVAL_LINE" | head -1 | cut -d: -f1)
  if [ -n "$PR_LINE_NO" ] && [ -n "$APPROVAL_LINE_NO" ] && [ "$APPROVAL_LINE_NO" -gt "$PR_LINE_NO" ]; then
    pass "U14 approval phrase appears after Open PR: line (PR line=$PR_LINE_NO, approval line=$APPROVAL_LINE_NO)"
  else
    fail "U14 — expected approval line after Open PR: line; PR line=$PR_LINE_NO approval line=$APPROVAL_LINE_NO; output: $U14_MSG"
  fi
fi

# ── U15: Approval phrase present even when no PR / no staged files ─────────
echo "=== U15: approval phrase present in degraded state (no PR, no staged files) ==="
# Shadow gh with an always-fail shim so getPrUrl returns "" (no Open PR: line),
# and use the empty repo so Staged files: shows (none). Approval phrase must still appear.
GH_FAIL_DIR_U15="$WORK_DIR/gh-fail-u15"
mkdir -p "$GH_FAIL_DIR_U15"
cat > "$GH_FAIL_DIR_U15/gh" << 'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$GH_FAIL_DIR_U15/gh"
U15_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$SENTINEL_CMD\",\"cwd\":\"$EMPTY_REPO\"}}"
U15_RESULT=$(PATH="$GH_FAIL_DIR_U15:$PATH" run_hook "$U15_JSON")
U15_MSG=$(echo "$U15_RESULT" | extract_msg)
if echo "$U15_MSG" | grep -qF "$EXPECTED_APPROVAL_LINE"; then
  pass "U15 approval phrase present even with no staged files / no PR"
else
  fail "U15 — expected approval phrase '$EXPECTED_APPROVAL_LINE' in degraded state, got: $U15_MSG"
fi

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
