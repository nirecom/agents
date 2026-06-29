#!/bin/bash
# tests/feature-1102-sibling-repos-json.sh
# Tests: skills/worktree-end/scripts/sibling-repos-json.js
# Tags: sibling, worktree, json, security, scope:issue-specific, pwsh-not-required
#
# Tests for sibling-repos-json.js — reads TAB-separated tuples from stdin and
# emits a JSON array of {repo, worktree_path, pr_number, merge_sha}. Security
# test: paths containing `"` and `\` must round-trip as valid JSON (#1102 Finding 2).
#
# L3 gap (what this test does NOT catch):
# - capture-env.sh piping real git/gh-resolved sibling tuples through this
#   serializer during an actual worktree-end run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/skills/worktree-end/scripts/sibling-repos-json.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Check if script exists before running any tests.
if [ ! -f "$SCRIPT" ]; then
    fail "SETUP: sibling-repos-json.js not found at $SCRIPT"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Helper: run script with given stdin content, capture output.
run_script() {
    printf '%s' "$1" | run_with_timeout 30 node "$SCRIPT"
}

# Parse the JSON array length via node.
json_length() {
    node -e "
      try {
        const a = JSON.parse(process.argv[1]);
        process.stdout.write(Array.isArray(a) ? String(a.length) : 'NaN');
      } catch(e) { process.stdout.write('NaN'); }
    " "$1" 2>/dev/null
}

# Extract a field from an object at index in a JSON array.
json_field() {
    node -e "
      try {
        const a = JSON.parse(process.argv[1]);
        const idx = parseInt(process.argv[2]);
        const obj = a[idx];
        if (obj === undefined || obj === null) { process.stdout.write(''); process.exit(0); }
        const v = obj[process.argv[3]];
        process.stdout.write(v === undefined ? '' : String(v));
      } catch(e) { process.stdout.write(''); }
    " "$1" "$2" "$3" 2>/dev/null
}

# Check that JSON parses without error and is an array.
is_valid_json_array() {
    node -e "
      try {
        const a = JSON.parse(process.argv[1]);
        process.stdout.write(Array.isArray(a) ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " "$1" 2>/dev/null
}

# ===========================================================================
# T1: Empty stdin → []
# ===========================================================================
OUT=$(run_script "")
RC=$?
VALID=$(is_valid_json_array "$OUT")
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$VALID" = "yes" ] && [ "$LEN" = "0" ]; then
    pass "T1: empty stdin → []"
else
    fail "T1: empty stdin" "rc=$RC valid=$VALID len=$LEN out='$OUT'"
fi

# ===========================================================================
# T2: Two tuples with all fields → two-element array with correct fields
# ===========================================================================
INPUT="example-org/agents	/home/user/git/worktrees/task/agents	42	abc1234
example-org/dotfiles	/home/user/git/worktrees/task/dotfiles	99	def5678
"
OUT=$(run_script "$INPUT")
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
WTP0=$(json_field "$OUT" 0 worktree_path)
PR0=$(json_field "$OUT" 0 pr_number)
SHA0=$(json_field "$OUT" 0 merge_sha)
REPO1=$(json_field "$OUT" 1 repo)
WTP1=$(json_field "$OUT" 1 worktree_path)
PR1=$(json_field "$OUT" 1 pr_number)
SHA1=$(json_field "$OUT" 1 merge_sha)
if [ "$RC" -eq 0 ] && [ "$LEN" = "2" ] && \
   [ "$REPO0" = "example-org/agents" ] && \
   [ "$WTP0" = "/home/user/git/worktrees/task/agents" ] && \
   [ "$PR0" = "42" ] && [ "$SHA0" = "abc1234" ] && \
   [ "$REPO1" = "example-org/dotfiles" ] && \
   [ "$WTP1" = "/home/user/git/worktrees/task/dotfiles" ] && \
   [ "$PR1" = "99" ] && [ "$SHA1" = "def5678" ]; then
    pass "T2: two full tuples → correct fields on both objects"
else
    fail "T2: two tuples" "rc=$RC len=$LEN repo0='$REPO0' wtp0='$WTP0' pr0='$PR0' sha0='$SHA0'"
fi

# ===========================================================================
# T3: SECURITY — worktree_path containing `"` and `\` round-trips as valid JSON
# This is the core security case: #1102 Finding 2. Shell interpolation was
# previously used to build the JSON, causing corruption when paths had special chars.
# ===========================================================================
# Use a path with both a double-quote and a backslash.
# The tab-separated input passes through JSON.stringify so the output must be valid.
SPECIAL_PATH='/home/user/weird "name"\subdir'
INPUT_SEC="example-org/agents	${SPECIAL_PATH}	7	badf00d
"
OUT=$(run_script "$INPUT_SEC")
RC=$?
VALID=$(is_valid_json_array "$OUT")
# Round-trip: parse back and compare field value
ROUNDTRIP=$(node -e "
  try {
    const a = JSON.parse(process.argv[1]);
    const wtp = a[0] && a[0].worktree_path;
    process.stdout.write(wtp !== undefined ? String(wtp) : '');
  } catch(e) { process.stdout.write('PARSE_ERROR: ' + e.message); }
" "$OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$VALID" = "yes" ] && [ "$ROUNDTRIP" = "$SPECIAL_PATH" ]; then
    pass "T3: SECURITY — path with '\"' and '\' round-trips as valid JSON field"
else
    fail "T3: SECURITY path round-trip" "rc=$RC valid=$VALID roundtrip='$ROUNDTRIP' expected='$SPECIAL_PATH'"
fi

# ===========================================================================
# T4: Blank lines are ignored — not counted as entries
# ===========================================================================
INPUT="example-org/agents	/home/user/worktrees/task/agents	1	aaa111

example-org/dotfiles	/home/user/worktrees/task/dotfiles	2	bbb222

"
OUT=$(run_script "$INPUT")
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "2" ]; then
    pass "T4: blank lines ignored → exactly 2 entries"
else
    fail "T4: blank lines" "rc=$RC len=$LEN expected 2 out='$OUT'"
fi

# ===========================================================================
# T5: Line with empty repo (field 0) is dropped
# ===========================================================================
# First line has empty repo (just a tab), second line is valid.
INPUT="	/some/path	5	sha999
example-org/agents	/home/user/worktrees/task/agents	6	sha888
"
OUT=$(run_script "$INPUT")
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && [ "$REPO0" = "example-org/agents" ]; then
    pass "T5: empty-repo line dropped → only valid entry returned"
else
    fail "T5: empty-repo line drop" "rc=$RC len=$LEN repo0='$REPO0'"
fi

# ===========================================================================
# T6: Missing trailing fields default to empty string ""
# ===========================================================================
# Provide only repo and worktree_path (no pr_number, no merge_sha).
INPUT="example-org/agents	/home/user/worktrees/task/agents
"
OUT=$(run_script "$INPUT")
RC=$?
LEN=$(json_length "$OUT")
PR=$(json_field "$OUT" 0 pr_number)
SHA=$(json_field "$OUT" 0 merge_sha)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && [ "$PR" = "" ] && [ "$SHA" = "" ]; then
    pass "T6: missing trailing fields → pr_number='' merge_sha=''"
else
    fail "T6: missing trailing fields" "rc=$RC len=$LEN pr='$PR' sha='$SHA'"
fi

# ===========================================================================
# T7: SECURITY — repo field containing `"` round-trips as valid JSON
# Parallel to T3 (which covers worktree_path); this covers the repo field.
# ===========================================================================
SPECIAL_REPO='example-org/weird"quote'
INPUT_REPO_SEC="${SPECIAL_REPO}	/home/user/worktrees/task/agents	3	cafe123
"
OUT=$(run_script "$INPUT_REPO_SEC")
RC=$?
VALID=$(is_valid_json_array "$OUT")
ROUNDTRIP_REPO=$(node -e "
  try {
    const a = JSON.parse(process.argv[1]);
    const r = a[0] && a[0].repo;
    process.stdout.write(r !== undefined ? String(r) : '');
  } catch(e) { process.stdout.write('PARSE_ERROR: ' + e.message); }
" "$OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$VALID" = "yes" ] && [ "$ROUNDTRIP_REPO" = "$SPECIAL_REPO" ]; then
    pass "T7: SECURITY — repo field with '\"' round-trips as valid JSON field"
else
    fail "T7: SECURITY repo round-trip" "rc=$RC valid=$VALID roundtrip='$ROUNDTRIP_REPO' expected='$SPECIAL_REPO'"
fi

# ===========================================================================
# T8: CRLF line endings produce the same result as LF (source splits on /\r?\n/)
# ===========================================================================
OUT_LF=$(printf 'example-org/agents\t/home/user/worktrees/task/agents\t1\taaa111\nexample-org/dotfiles\t/home/user/worktrees/task/dotfiles\t2\tbbb222\n' | run_with_timeout 30 node "$SCRIPT")
OUT_CRLF=$(printf 'example-org/agents\t/home/user/worktrees/task/agents\t1\taaa111\r\nexample-org/dotfiles\t/home/user/worktrees/task/dotfiles\t2\tbbb222\r\n' | run_with_timeout 30 node "$SCRIPT")
if [ -n "$OUT_LF" ] && [ "$OUT_LF" = "$OUT_CRLF" ]; then
    pass "T8: CRLF line endings produce identical output to LF"
else
    fail "T8: CRLF vs LF" "lf='$OUT_LF' crlf='$OUT_CRLF'"
fi

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
