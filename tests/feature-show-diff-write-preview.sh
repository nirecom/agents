#!/usr/bin/env bash
# Tests: hooks/show-diff.js
# Tags: show-diff-write-preview
set -uo pipefail

REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
HOOK="$REPO_ROOT/hooks/show-diff.js"

# Resolve node-visible home for WORKFLOW_PLANS_DIR (same pattern as other show-diff tests)
NODE_HOME="$(node -e "process.stdout.write(require('os').homedir().replace(/\\\\/g,'/'))")"
export WORKFLOW_PLANS_DIR="$NODE_HOME/.workflow-plans"

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# OS-portable tmp dir.
# On Git Bash for Windows, bash sees /tmp/... but Windows node needs C:/... —
# translate via cygpath -m when available. WORK is the bash-visible path
# (for cleanup); HWORK is the host-native path (passed to node).
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then
  HWORK=$(cygpath -m "$WORK")
else
  HWORK="$WORK"
fi

run_hook() {
  echo "$1" | run_with_timeout node "$HOOK"
}

fail() {
  echo "FAIL: $1"
  exit 1
}

# 1) New file — non-existent path: output must contain /dev/null label and +addition
# (Output is JSON-encoded systemMessage, so newlines are \n escapes; grep -F for content.)
out=$(run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HWORK/newfile.md\",\"content\":\"hello\"}}")
echo "$out" | grep -qF '/dev/null' || fail "test 1: new file diff should contain /dev/null label"
echo "$out" | grep -qF '+hello' || fail "test 1: new file diff should contain '+hello' addition"

# 2) Overwrite — existing file: output is proper -u diff with - and + lines
echo "old content" > "$HWORK/existing.md"
out=$(run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HWORK/existing.md\",\"content\":\"new content\"}}")
echo "$out" | grep -qF -- '-old' || fail "test 2: overwrite diff should contain '-old' deletion"
echo "$out" | grep -qF -- '+new' || fail "test 2: overwrite diff should contain '+new' addition"

# 3) editFiles routes to MultiEdit branch — output contains --- edit 1 ---
out=$(run_hook "{\"tool_name\":\"editFiles\",\"tool_input\":{\"file_path\":\"$HWORK/existing.md\",\"edits\":[{\"old_string\":\"old\",\"new_string\":\"new\"}]}}")
echo "$out" | grep -q -- '--- edit 1 ---' || fail "test 3: editFiles should route to MultiEdit branch (--- edit 1 ---)"

# 4) Draft path — output empty (isPlanFile via isUnderPath -> noopExit)
out=$(run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORKFLOW_PLANS_DIR/drafts/foo.md\",\"content\":\"x\"}}")
[ -z "$out" ] || fail "test 4: draft path should produce empty output"

# 5) Test file path — output empty (isTestFile -> noopExit)
out=$(run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$REPO_ROOT/tests/foo.test.js\",\"content\":\"x\"}}")
[ -z "$out" ] || fail "test 5: test file path should produce empty output"

# 6) Empty content new file — diff produced (non-empty systemMessage wrapper)
out=$(run_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$HWORK/empty.md\",\"content\":\"\"}}")
[ -n "$out" ] || fail "test 6: empty-content new file should still produce non-empty output (header/wrapper)"

# 7) Malformed JSON stdin — hook returns empty
out=$(echo '"not valid json"' | run_with_timeout node "$HOOK")
[ -z "$out" ] || fail "test 7: malformed JSON should produce empty output"

echo "PASS: all assertions passed"
