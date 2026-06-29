#!/bin/bash
# tests/feature-1102-parse-worktrees.sh
# Tests: hooks/lib/parse-worktrees.js, bin/parse-worktrees
# Tags: parse, worktrees, intent, bin, scope:issue-specific, pwsh-not-required
#
# Tests for hooks/lib/parse-worktrees.js via the CLI wrapper bin/parse-worktrees.
# Mirrors the style of tests/feature-issues-section-parser.sh (parse-via-CLI pattern).
#
# All tests are GREEN: parse-worktrees.js is already implemented.
#
# L3 gap (what this test does NOT catch):
# - the real clarify-intent SKILL writing the `## worktrees` section into a live
#   intent.md and worktree-copy-worker consuming this CLI's output end-to-end.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER_CLI="$AGENTS_DIR/bin/parse-worktrees"

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

TMP=""

setup_tmp() {
    TMP="$(mktemp -d)"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
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
# Usage: json_field <json> <index> <field>
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

# ===========================================================================
# T1: Missing file → []
# ===========================================================================
setup_tmp
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/nonexistent-intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "0" ]; then
    pass "T1: missing file → [] exit 0"
else
    fail "T1: missing file" "rc=$RC out='$OUT' len=$LEN expected 0"
fi
teardown_tmp

# ===========================================================================
# T2: No ## worktrees section → []
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #42

## closes_issues
- 42
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "0" ]; then
    pass "T2: no ## worktrees section → [] exit 0"
else
    fail "T2: no section" "rc=$RC out='$OUT' len=$LEN expected 0"
fi
teardown_tmp

# ===========================================================================
# T3: Single entry → one-element array with correct fields
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo: example-org/dotfiles
  worktree_path: /home/user/git/worktrees/my-task/dotfiles
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO=$(json_field "$OUT" 0 repo)
WTP=$(json_field "$OUT" 0 worktree_path)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && \
   [ "$REPO" = "example-org/dotfiles" ] && \
   [ "$WTP" = "/home/user/git/worktrees/my-task/dotfiles" ]; then
    pass "T3: single entry → one-element array with correct repo+worktree_path"
else
    fail "T3: single entry" "rc=$RC out='$OUT' len=$LEN repo='$REPO' wtp='$WTP'"
fi
teardown_tmp

# ===========================================================================
# T4: Two entries → two-element array in source order
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo: example-org/agents
  worktree_path: /home/user/git/worktrees/my-task/agents
- repo: example-org/dotfiles
  worktree_path: /home/user/git/worktrees/my-task/dotfiles
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
WTP0=$(json_field "$OUT" 0 worktree_path)
REPO1=$(json_field "$OUT" 1 repo)
WTP1=$(json_field "$OUT" 1 worktree_path)
if [ "$RC" -eq 0 ] && [ "$LEN" = "2" ] && \
   [ "$REPO0" = "example-org/agents" ] && \
   [ "$WTP0" = "/home/user/git/worktrees/my-task/agents" ] && \
   [ "$REPO1" = "example-org/dotfiles" ] && \
   [ "$WTP1" = "/home/user/git/worktrees/my-task/dotfiles" ]; then
    pass "T4: two entries → two-element array in source order"
else
    fail "T4: two entries" "rc=$RC out='$OUT' len=$LEN repo0='$REPO0' repo1='$REPO1'"
fi
teardown_tmp

# ===========================================================================
# T5: Section ends at next ## heading — entries after ## Other not parsed
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo: example-org/agents
  worktree_path: /home/user/git/worktrees/my-task/agents

## Other Section
- repo: example-org/fake
  worktree_path: /should/not/appear
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && [ "$REPO0" = "example-org/agents" ]; then
    pass "T5: section ends at next ## heading → only first entry returned"
else
    fail "T5: section boundary" "rc=$RC out='$OUT' len=$LEN repo0='$REPO0'"
fi
teardown_tmp

# ===========================================================================
# T6: Entry with empty repo is dropped
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo:
  worktree_path: /home/user/git/worktrees/my-task/agents
- repo: example-org/dotfiles
  worktree_path: /home/user/git/worktrees/my-task/dotfiles
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && [ "$REPO0" = "example-org/dotfiles" ]; then
    pass "T6: empty repo entry dropped → only valid entry returned"
else
    fail "T6: empty repo drop" "rc=$RC out='$OUT' len=$LEN repo0='$REPO0'"
fi
teardown_tmp

# ===========================================================================
# T7: Entry with empty worktree_path is dropped
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo: example-org/agents
  worktree_path:
- repo: example-org/dotfiles
  worktree_path: /home/user/git/worktrees/my-task/dotfiles
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO0=$(json_field "$OUT" 0 repo)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && [ "$REPO0" = "example-org/dotfiles" ]; then
    pass "T7: empty worktree_path entry dropped → only valid entry returned"
else
    fail "T7: empty worktree_path drop" "rc=$RC out='$OUT' len=$LEN repo0='$REPO0'"
fi
teardown_tmp

# ===========================================================================
# T8: CLI with no argument → [] exit 0 (fail-open)
# ===========================================================================
OUT=$(run_with_timeout 30 node "$PARSER_CLI" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "0" ]; then
    pass "T8: CLI no-arg → [] exit 0"
else
    fail "T8: CLI no-arg" "rc=$RC out='$OUT' len=$LEN expected 0"
fi

# ===========================================================================
# T9: CLI with nonexistent path → [] exit 0 (fail-open)
# ===========================================================================
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "/this/path/does/not/exist/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "0" ]; then
    pass "T9: CLI nonexistent path → [] exit 0"
else
    fail "T9: CLI nonexistent" "rc=$RC out='$OUT' len=$LEN expected 0"
fi

# ===========================================================================
# T10: CRLF line endings — same as T3 but with \r\n
# ===========================================================================
setup_tmp
printf '# Intent\r\n\r\n## worktrees\r\n- repo: example-org/dotfiles\r\n  worktree_path: /home/user/git/worktrees/crlf/dotfiles\r\n' > "$TMP/intent.md"
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
REPO=$(json_field "$OUT" 0 repo)
WTP=$(json_field "$OUT" 0 worktree_path)
if [ "$RC" -eq 0 ] && [ "$LEN" = "1" ] && \
   [ "$REPO" = "example-org/dotfiles" ] && \
   [ "$WTP" = "/home/user/git/worktrees/crlf/dotfiles" ]; then
    pass "T10: CRLF line endings → parsed correctly"
else
    fail "T10: CRLF" "rc=$RC out='$OUT' len=$LEN repo='$REPO' wtp='$WTP'"
fi
teardown_tmp

# ===========================================================================
# T11: Empty file (0 bytes) → [] exit 0
# ===========================================================================
setup_tmp
: > "$TMP/empty-intent.md"
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/empty-intent.md" 2>/dev/null)
RC=$?
LEN=$(json_length "$OUT")
if [ "$RC" -eq 0 ] && [ "$LEN" = "0" ]; then
    pass "T11: empty (0-byte) file → [] exit 0"
else
    fail "T11: empty file" "rc=$RC out='$OUT' len=$LEN expected 0"
fi
teardown_tmp

# ===========================================================================
# T12: SECURITY — worktree_path containing `"` round-trips as valid JSON
# ===========================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## worktrees
- repo: example-org/dotfiles
  worktree_path: /home/user/weird "name"/dotfiles
EOF
OUT=$(run_with_timeout 30 node "$PARSER_CLI" "$TMP/intent.md" 2>/dev/null)
RC=$?
VALID=$(node -e "
  try {
    const a = JSON.parse(process.argv[1]);
    process.stdout.write(Array.isArray(a) ? 'yes' : 'no');
  } catch(e) { process.stdout.write('no'); }
" "$OUT" 2>/dev/null)
WTP=$(json_field "$OUT" 0 worktree_path)
if [ "$RC" -eq 0 ] && [ "$VALID" = "yes" ] && [ "$WTP" = '/home/user/weird "name"/dotfiles' ]; then
    pass "T12: SECURITY — worktree_path with '\"' round-trips as valid JSON field"
else
    fail "T12: SECURITY worktree_path round-trip" "rc=$RC valid=$VALID wtp='$WTP'"
fi
teardown_tmp

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
