#!/bin/bash
# tests/feature-325-history-write-bypass.sh
#
# Tests for issue #325 — isAllowedHistoryWriteViaIssueCloseSkill().
#
# Feature contract:
#   /issue-close-finalize (Phase 2) writes docs/history.md from the MAIN
#   worktree under ENFORCE_WORKTREE=on. To avoid disabling the guard globally,
#   enforce-worktree.js exposes a narrow bypass that recognises EXACTLY the
#   two command shapes the skill emits with the ISSUE_CLOSE_SKILL=1 inline
#   prefix:
#
#     1) ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/
#     2) ISSUE_CLOSE_SKILL=1 git commit -m "docs(history): record issue #<N>"
#
#   Pattern matches the design of enforce-issue-close.js's INLINE_SKILL_RE
#   (lines 68-73 there): the bypass parses the COMMAND STRING (not
#   process.env) because inline env-var prefixes don't reach the hook's
#   process.env.
#
# Test approach (mirrors fix-enforce-worktree-main-cleanup.sh):
#   We require enforce-worktree.js to export
#   `isAllowedHistoryWriteViaIssueCloseSkill(cmd)` and unit-test that
#   function directly. RED phase: H1 and H2 fail until the source function
#   lands; H3-H7 remain RED-safe (the function not existing yields "reject"
#   for everything, which matches their expected "block" assertion — they
#   will pass even without the source change, but stay correct after).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Existence gate — RED until source change lands.
if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# check_bypass <command> → echoes "allow" / "reject" / "missing".
# Invokes the exported function directly. If the function isn't exported yet
# (RED phase), prints "missing" and the caller decides how to score.
check_bypass() {
    local cmd="$1"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        const fn = m.isAllowedHistoryWriteViaIssueCloseSkill;
        if (typeof fn !== 'function') { console.log('missing'); process.exit(0); }
        console.log(fn(process.argv[1]) ? 'allow' : 'reject');
    " -- "$cmd" 2>/dev/null
}

assert_allow() {
    local cmd="$1" label="$2"
    local got; got="$(check_bypass "$cmd")"
    case "$got" in
        allow)   pass "$label" ;;
        reject)  fail "$label (got reject — bypass not matching expected command shape)" ;;
        missing) fail "$label (RED: isAllowedHistoryWriteViaIssueCloseSkill not exported yet)" ;;
        *)       fail "$label (unexpected output: '$got')" ;;
    esac
}

assert_block() {
    local cmd="$1" label="$2"
    local got; got="$(check_bypass "$cmd")"
    case "$got" in
        reject)  pass "$label" ;;
        allow)   fail "$label (got allow — bypass over-broad)" ;;
        missing) fail "$label (RED: isAllowedHistoryWriteViaIssueCloseSkill not exported yet)" ;;
        *)       fail "$label (unexpected output: '$got')" ;;
    esac
}

# ============================================================================
# H-series — narrow bypass for /issue-close-finalize history writes
# ============================================================================

# --- H1: canonical `git add` shape → allow
assert_allow \
    'ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/' \
    "H1: ISSUE_CLOSE_SKILL=1 git add docs/history.md docs/history/ → allow"

# --- H2: canonical `git commit` shape with docs(history): subject → allow
#
# Note: this asserts the COMMAND STRING shape only. The full Phase 2
# implementation may additionally inspect the git staging area to verify
# that ONLY docs/history.md (and docs/history/) entries are staged. That
# extra check is outside the scope of this unit test of the command-string
# matcher — the matcher's contract is: shape OK → allow; let downstream
# logic decide based on staged content if required.
assert_allow \
    'ISSUE_CLOSE_SKILL=1 git commit -m "docs(history): record issue #42"' \
    "H2: ISSUE_CLOSE_SKILL=1 git commit -m \"docs(history): record issue #42\" → allow"

# --- H3: missing ISSUE_CLOSE_SKILL=1 prefix → block
assert_block \
    'git add docs/history.md docs/history/' \
    "H3: bare 'git add docs/history.md docs/history/' (no ISSUE_CLOSE_SKILL prefix) → block"

# --- H4: ISSUE_CLOSE_SKILL=1 but path outside history allowlist → block
assert_block \
    'ISSUE_CLOSE_SKILL=1 git add src/foo.js' \
    "H4: ISSUE_CLOSE_SKILL=1 git add src/foo.js (out-of-allowlist path) → block"

# --- H5: ISSUE_CLOSE_SKILL=1 git commit but subject not docs(history): → block
assert_block \
    'ISSUE_CLOSE_SKILL=1 git commit -m "feat: unrelated"' \
    "H5: ISSUE_CLOSE_SKILL=1 git commit with non-docs(history) subject → block"

# --- H6: ISSUE_CLOSE_SKILL=1 but neither git add nor git commit → block
assert_block \
    'ISSUE_CLOSE_SKILL=1 rm -rf docs/history.md' \
    "H6: ISSUE_CLOSE_SKILL=1 rm -rf docs/history.md (not git add/commit) → block"

# --- H7: ISSUE_CLOSE_SKILL=1 with shell chaining → block
# Even if both halves would individually match, chaining bypasses the
# end-anchor of the strict-shape matcher (see enforce-issue-close.js:69).
assert_block \
    'ISSUE_CLOSE_SKILL=1 git add docs/history.md && git commit -m "docs(history): x"' \
    "H7: ISSUE_CLOSE_SKILL=1 with shell chaining (&&) → block"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
