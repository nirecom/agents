#!/usr/bin/env bash
# Tests: hooks/show-plan-link.js
# Tags: plan, vscode, hook, bin, env, scope:issue-specific, workflow-state, turn-marker, TL2
# Tests for URI encoding fix in workspaceFolderUriFrom() (issue #492).
# Branch: fix/506-show-plan-link
# The helper operates on string content only (not process.platform), so all
# cases run on every platform — no OS guards needed.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"
ISO_TMP="$(make_tmp)"
harness_isolate "$ISO_TMP"
export WORKFLOW_STATE_DIR="$ISO_TMP/workflow-state"
mkdir -p "$ISO_TMP/no-transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$ISO_TMP/no-transcripts"
HOOK="$AGENTS_DIR/hooks/show-plan-link.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

parse_marker() {
  local file="$1" block="$2"
  awk -v b="$block" 'BEGIN{n=1} /^$/{n++;next} n==b{print}' "$file"
}

NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"
PLANS_DIR="${NODE_TMPDIR}/show-plan-link-uri-test-$$"
mkdir -p "$PLANS_DIR"
trap 'rm -rf "$PLANS_DIR" "$ISO_TMP"' EXIT
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

unset TERM_PROGRAM 2>/dev/null || true
unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true

run_hook_capture_spawn() {
  local json="$1" marker="$2"
  shift 2
  rm -f "$marker"
  (
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    export SHOW_PLAN_LINK_NO_SPAWN=1
    export SHOW_PLAN_LINK_MARKER_FILE="$marker"
    echo "$json" | run_with_timeout node "$HOOK" >/dev/null 2>&1
  )
}

# Helper to get block-1 URI line
# single block layout: line 1 = --folder-uri, line 2 = <uri>, line 3 = <filePath>
get_block1_uri() {
  local marker="$1"
  parse_marker "$marker" 1 | sed -n '2p'
}

DETAIL_PATH="$PLANS_DIR/abc-detail.md"

# T-URI-1: space
MARKER="$PLANS_DIR/uri-marker-T-URI-1"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"/tmp/has space/proj\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///tmp/has%20space/proj"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-1 space encoded as %20"
else
  fail "T-URI-1 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-2: hash
MARKER="$PLANS_DIR/uri-marker-T-URI-2"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"/tmp/has#hash/proj\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///tmp/has%23hash/proj"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-2 hash encoded as %23"
else
  fail "T-URI-2 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-3: percent (bare % → %25)
MARKER="$PLANS_DIR/uri-marker-T-URI-3"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"/tmp/has%percent/proj\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///tmp/has%25percent/proj"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-3 bare percent encoded as %25"
else
  fail "T-URI-3 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-4: non-ASCII (Japanese)
MARKER="$PLANS_DIR/uri-marker-T-URI-4"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"/tmp/日本語/proj\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///tmp/%E6%97%A5%E6%9C%AC%E8%AA%9E/proj"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-4 non-ASCII percent-encoded"
else
  fail "T-URI-4 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-5: Windows drive + space
MARKER="$PLANS_DIR/uri-marker-T-URI-5"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"C:\\\\git\\\\my project\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///C:/git/my%20project"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-5 Windows drive preserved, space encoded"
else
  fail "T-URI-5 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-6: UNC path
MARKER="$PLANS_DIR/uri-marker-T-URI-6"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"\\\\\\\\server\\\\share\\\\dir name\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file://server/share/dir%20name"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-6 UNC -> file://server/share/..."
else
  fail "T-URI-6 expected '$EXPECTED', got '$GOT'"
fi

# T-URI-7: already-encoded literal (no double-encoding check; bare % → %25)
MARKER="$PLANS_DIR/uri-marker-T-URI-7"
run_hook_capture_spawn \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true},\"cwd\":\"/tmp/foo%20bar\"}" \
  "$MARKER" \
  TERM_PROGRAM=vscode CONFIRM_DETAIL=on
EXPECTED="file:///tmp/foo%2520bar"
GOT=$(get_block1_uri "$MARKER")
if [ "$GOT" = "$EXPECTED" ]; then
  pass "T-URI-7 already-encoded literal % re-encoded as %25"
else
  fail "T-URI-7 expected '$EXPECTED', got '$GOT'"
fi

# T-STATE-1 (#2511): the turn marker follows the WORKFLOW_STATE_DIR pin alone. The
# retired variable is unset for this call and HOME points at a decoy, so a marker
# written through the old resolution lands in the decoy instead.
OLD_TOKEN="CLAUDE_""WORKFLOW_DIR"
DECOY="$ISO_TMP/decoy-home"
mkdir -p "$DECOY"
SID="aaaaaaaa-2511-4000-8000-000000000001"
echo "{\"session_id\":\"$SID\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$DETAIL_PATH\"},\"tool_response\":{\"success\":true}}" |
  run_with_timeout env -u "$OLD_TOKEN" HOME="$DECOY" USERPROFILE="$DECOY" SHOW_PLAN_LINK_NO_SPAWN=1 \
    node "$HOOK" >/dev/null 2>&1
PINNED_MARKERS="$(find "$WORKFLOW_STATE_DIR" -maxdepth 1 -name "$SID.confirm-plan-turn-*.json" | wc -l | tr -d ' ')"
DECOY_FILES="$(find "$DECOY" -type f | wc -l | tr -d ' ')"
if [ "$PINNED_MARKERS" = "1" ] && [ "$DECOY_FILES" = "0" ]; then
  pass "T-STATE-1 turn marker lands under the pinned WORKFLOW_STATE_DIR, none in the decoy HOME"
else
  fail "T-STATE-1 expected 1 marker under the pin and 0 decoy files, got pin=$PINNED_MARKERS decoy=$DECOY_FILES"
fi

echo ""
if [ $ERRORS -eq 0 ]; then
  echo "All URI encoding tests passed."
  exit 0
else
  echo "$ERRORS test(s) failed."
  exit 1
fi
