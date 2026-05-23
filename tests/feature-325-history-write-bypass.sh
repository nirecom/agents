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

PUSH_TEST_TMPS=()
cleanup_push_tmps() {
    for d in "${PUSH_TEST_TMPS[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup_push_tmps EXIT

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

setup_push_test_repo() {
    # Args: $1=issue_num, $2=subject_override (empty=use default), $3=files_csv, $4=default_branch (default:main)
    local issue_num="$1"; local subject_override="${2:-}"; local files_csv="$3"
    local default_branch="${4:-main}"
    local tmp; tmp=$(mktemp -d)
    PUSH_TEST_TMPS+=("$tmp")
    local upstream="$tmp/upstream.git"; local work="$tmp/work"
    git init --bare --initial-branch="$default_branch" "$upstream" >/dev/null
    git init --initial-branch="$default_branch" "$work" >/dev/null
    git -C "$work" config core.hooksPath /dev/null
    (cd "$work"
        git remote add origin "$upstream"
        git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
        git push -u origin "$default_branch" >/dev/null 2>&1
        git remote set-head origin "$default_branch" >/dev/null 2>&1
        mkdir -p docs/history
        IFS=',' read -ra FILES <<< "$files_csv"
        for f in "${FILES[@]}"; do mkdir -p "$(dirname "$f")"; echo "x" >> "$f"; done
        git add -A
        local subj="${subject_override:-docs(history): record issue #${issue_num}}"
        git -c user.email=a@b -c user.name=a commit --no-verify -m "$subj" >/dev/null
    )
    echo "$work"
}

setup_push_test_repo_no_head() {
    local issue_num="$1"; local default_branch="${2:-main}"
    local tmp; tmp=$(mktemp -d)
    PUSH_TEST_TMPS+=("$tmp")
    local upstream="$tmp/upstream.git"; local work="$tmp/work"
    git init --bare --initial-branch="$default_branch" "$upstream" >/dev/null
    git init --initial-branch="$default_branch" "$work" >/dev/null
    git -C "$work" config core.hooksPath /dev/null
    (cd "$work"
        git remote add origin "$upstream"
        git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
        git push -u origin "$default_branch" >/dev/null 2>&1
        mkdir -p docs/history
        echo "x" >> docs/history.md
        git add docs/history.md
        git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(history): record issue #${issue_num}" >/dev/null
    )
    echo "$work"
}

setup_push_test_repo_detached_wt() {
    local issue_num="$1"
    local tmp; tmp=$(mktemp -d)
    PUSH_TEST_TMPS+=("$tmp")
    local upstream="$tmp/upstream.git"; local work="$tmp/work"
    git init --bare --initial-branch=main "$upstream" >/dev/null
    git init --initial-branch=main "$work" >/dev/null
    git -C "$work" config core.hooksPath /dev/null
    (cd "$work"
        git remote add origin "$upstream"
        git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
        git push -u origin main >/dev/null 2>&1
        git remote set-head origin main >/dev/null 2>&1
        mkdir -p docs/history
        echo "x" >> docs/history.md
        git add docs/history.md
        git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(history): record issue #${issue_num}" >/dev/null
        git switch -c feature/x >/dev/null 2>&1
        git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m "feat: work" >/dev/null
    )
    echo "$work"
}

check_bypass_push() {
    local cmd="$1"; local repo="$2"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        const fn = m.isAllowedHistoryPushViaIssueCloseSkill;
        if (typeof fn !== 'function') { console.log('missing'); process.exit(0); }
        console.log(fn(process.argv[1], process.argv[2]) ? 'allow' : 'reject');
    " -- "$cmd" "$repo" 2>/dev/null
}

assert_push_allow() {
    local cmd="$1"; local repo="$2"; local label="$3"
    local got; got="$(check_bypass_push "$cmd" "$repo")"
    case "$got" in
        allow)   pass "$label" ;;
        reject)  fail "$label (got reject)" ;;
        missing) fail "$label (RED: isAllowedHistoryPushViaIssueCloseSkill not exported yet)" ;;
        *)       fail "$label (unexpected: '$got')" ;;
    esac
}

assert_push_block() {
    local cmd="$1"; local repo="$2"; local label="$3"
    local got; got="$(check_bypass_push "$cmd" "$repo")"
    case "$got" in
        reject)  pass "$label" ;;
        allow)   fail "$label (got allow — bypass over-broad)" ;;
        missing) pass "$label (RED-safe: function not exported yet)" ;;
        *)       fail "$label (unexpected: '$got')" ;;
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

# ============================================================================
# P-series — push bypass for /issue-close-finalize (git push)
# ============================================================================

# --- P1: canonical push shape, docs/history.md only → allow
_p1_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_allow \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p1_repo" \
    "P1: ISSUE_CLOSE_SKILL=1 git push origin main (single history file) → allow"

# --- P2: push with rotation file docs/history/2026.md → allow
_p2_repo="$(setup_push_test_repo 42 "" "docs/history.md,docs/history/2026.md")"
assert_push_allow \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p2_repo" \
    "P2: ISSUE_CLOSE_SKILL=1 git push origin main (history + rotation file) → allow"

# --- P3: missing ISSUE_CLOSE_SKILL=1 prefix → block
_p3_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'git push origin main' \
    "$_p3_repo" \
    "P3: bare 'git push origin main' (no ISSUE_CLOSE_SKILL prefix) → block"

# --- P4: push to non-default branch → block
_p4_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin feature/x' \
    "$_p4_repo" \
    "P4: ISSUE_CLOSE_SKILL=1 git push origin feature/x (not default branch) → block"

# --- P5: subject does not match docs(history) pattern → block
_p5_repo="$(setup_push_test_repo 42 "feat: unrelated" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p5_repo" \
    "P5: ISSUE_CLOSE_SKILL=1 git push origin main (subject 'feat: unrelated') → block"

# --- P6: file outside docs/history allowlist → block
_p6_repo="$(setup_push_test_repo 42 "" "src/foo.js")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p6_repo" \
    "P6: ISSUE_CLOSE_SKILL=1 git push origin main (file src/foo.js) → block"

# --- P7: shell chaining → block
_p7_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main && rm -rf /tmp' \
    "$_p7_repo" \
    "P7: ISSUE_CLOSE_SKILL=1 git push origin main && rm -rf /tmp (chaining) → block"

# --- P8: unknown flag --force-with-lease → block
_p8_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push --force-with-lease origin main' \
    "$_p8_repo" \
    "P8: ISSUE_CLOSE_SKILL=1 git push --force-with-lease origin main (unknown flag) → block"

# --- P9: refspec (colon form) → block
_p9_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin refs/heads/main:refs/heads/main' \
    "$_p9_repo" \
    "P9: ISSUE_CLOSE_SKILL=1 git push origin refs/heads/main:refs/heads/main (refspec) → block"

# --- P10: 2 outgoing commits — one subject doesn't match → block
_p10_tmp="$(mktemp -d)"
PUSH_TEST_TMPS+=("$_p10_tmp")
_p10_upstream="$_p10_tmp/upstream.git"
_p10_work="$_p10_tmp/work"
git init --bare --initial-branch=main "$_p10_upstream" >/dev/null
git init --initial-branch=main "$_p10_work" >/dev/null
git -C "$_p10_work" config core.hooksPath /dev/null
(cd "$_p10_work"
    git remote add origin "$_p10_upstream"
    git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
    git push -u origin main >/dev/null 2>&1
    git remote set-head origin main >/dev/null 2>&1
    mkdir -p docs/history
    echo "x" >> docs/history.md
    git add docs/history.md
    git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(history): record issue #42" >/dev/null
    echo "y" >> docs/history.md
    git add docs/history.md
    git -c user.email=a@b -c user.name=a commit --no-verify -m "feat: extra" >/dev/null
)
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p10_work" \
    "P10: 2 outgoing commits (one non-docs(history) subject) → block"

# --- P11: default branch=master repo, push to 'main' → block
_p11_repo="$(setup_push_test_repo 42 "" "docs/history.md" "master")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p11_repo" \
    "P11: default=master, push to 'main' (wrong branch) → block"

# --- P11b: default branch=master repo, push to 'master' → allow
assert_push_allow \
    'ISSUE_CLOSE_SKILL=1 git push origin master' \
    "$_p11_repo" \
    "P11b: default=master, push to 'master' → allow"

# --- P12: -u/--set-upstream flag → block
_p12_repo="$(setup_push_test_repo 42 "" "docs/history.md")"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push -u origin main' \
    "$_p12_repo" \
    "P12: ISSUE_CLOSE_SKILL=1 git push -u origin main (upstream mutation) → block"

# --- P13: origin/HEAD not set → block (fail-closed)
_p13_repo="$(setup_push_test_repo_no_head 42)"
assert_push_block \
    'ISSUE_CLOSE_SKILL=1 git push origin main' \
    "$_p13_repo" \
    "P13: origin/HEAD not set (no remote set-head) → block (fail-closed)"

# --- P14: worktree on feature/x, main has docs(history) commit → allow (uses refs/heads/main)
_p14_repo="$(setup_push_test_repo_detached_wt 42)"
_p14_check="$(check_bypass_push 'ISSUE_CLOSE_SKILL=1 git push origin main' "$_p14_repo")"
case "$_p14_check" in
    allow)   pass "P14: worktree on feature/x, push main (refs/heads/main range) → allow" ;;
    reject)  fail "P14: worktree on feature/x, push main (refs/heads/main range) → got reject" ;;
    missing) fail "P14: RED: isAllowedHistoryPushViaIssueCloseSkill not exported yet" ;;
    *)       fail "P14: unexpected: '$_p14_check'" ;;
esac

# ============================================================================
# C/Q-series helpers — compose-doc-append-entry bypass (#436)
# ============================================================================

check_bypass_compose() {
    local cmd="$1"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        const fn = m.isAllowedHistoryWriteViaComposeDocAppendSkill;
        if (typeof fn !== 'function') { console.log('missing'); process.exit(0); }
        console.log(fn(process.argv[1]) ? 'allow' : 'reject');
    " -- "$cmd" 2>/dev/null
}

assert_compose_allow() {
    local cmd="$1" label="$2"
    local got; got="$(check_bypass_compose "$cmd")"
    case "$got" in
        allow)   pass "$label" ;;
        reject)  fail "$label (got reject — bypass not matching expected command shape)" ;;
        missing) fail "$label (RED: isAllowedHistoryWriteViaComposeDocAppendSkill not exported yet)" ;;
        *)       fail "$label (unexpected output: '$got')" ;;
    esac
}

assert_compose_block() {
    local cmd="$1" label="$2"
    local got; got="$(check_bypass_compose "$cmd")"
    case "$got" in
        reject)  pass "$label" ;;
        allow)   fail "$label (got allow — bypass over-broad)" ;;
        missing) pass "$label (RED-safe: function not exported yet)" ;;
        *)       fail "$label (unexpected output: '$got')" ;;
    esac
}

check_bypass_push_compose() {
    local cmd="$1"; local repo="$2"
    run_with_timeout 15 node -e "
        const m = require('$GUARD_JS');
        const fn = m.isAllowedHistoryPushViaComposeDocAppendSkill;
        if (typeof fn !== 'function') { console.log('missing'); process.exit(0); }
        console.log(fn(process.argv[1], process.argv[2]) ? 'allow' : 'reject');
    " -- "$cmd" "$repo" 2>/dev/null
}

assert_push_compose_allow() {
    local cmd="$1"; local repo="$2"; local label="$3"
    local got; got="$(check_bypass_push_compose "$cmd" "$repo")"
    case "$got" in
        allow)   pass "$label" ;;
        reject)  fail "$label (got reject)" ;;
        missing) fail "$label (RED: isAllowedHistoryPushViaComposeDocAppendSkill not exported yet)" ;;
        *)       fail "$label (unexpected: '$got')" ;;
    esac
}

assert_push_compose_block() {
    local cmd="$1"; local repo="$2"; local label="$3"
    local got; got="$(check_bypass_push_compose "$cmd" "$repo")"
    case "$got" in
        reject)  pass "$label" ;;
        allow)   fail "$label (got allow — bypass over-broad)" ;;
        missing) pass "$label (RED-safe: function not exported yet)" ;;
        *)       fail "$label (unexpected: '$got')" ;;
    esac
}

setup_push_test_repo_compose() {
    # Args: $1=subject, $2=files_csv, $3=default_branch (default:main)
    local subject="$1"; local files_csv="$2"
    local default_branch="${3:-main}"
    local tmp; tmp=$(mktemp -d)
    PUSH_TEST_TMPS+=("$tmp")
    local upstream="$tmp/upstream.git"; local work="$tmp/work"
    git init --bare --initial-branch="$default_branch" "$upstream" >/dev/null
    git init --initial-branch="$default_branch" "$work" >/dev/null
    git -C "$work" config core.hooksPath /dev/null
    (cd "$work"
        git remote add origin "$upstream"
        git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
        git push -u origin "$default_branch" >/dev/null 2>&1
        git remote set-head origin "$default_branch" >/dev/null 2>&1
        mkdir -p docs/history
        IFS=',' read -ra FILES <<< "$files_csv"
        for f in "${FILES[@]}"; do mkdir -p "$(dirname "$f")"; echo "x" >> "$f"; done
        git add -A
        git -c user.email=a@b -c user.name=a commit --no-verify -m "$subject" >/dev/null
    )
    echo "$work"
}

# ============================================================================
# C-series — narrow bypass for compose-doc-append-entry history/changelog writes
# ============================================================================

# --- C1: canonical git add for history → allow
assert_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md docs/history/' \
    "C1: COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md docs/history/ → allow"

# --- C2: canonical git add for CHANGELOG → allow
assert_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md' \
    "C2: COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md → allow"

# --- C3: canonical git commit for docs(history) → allow
assert_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(history): record PR #99"' \
    'C3: COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(history): record PR #99" → allow'

# --- C4: canonical git commit for docs(changelog) → allow
assert_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(changelog): record PR #99"' \
    'C4: COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(changelog): record PR #99" → allow'

# --- C5: no COMPOSE_DOC_APPEND_SKILL=1 prefix → block
assert_compose_block \
    'git add CHANGELOG.md' \
    "C5: bare 'git add CHANGELOG.md' (no COMPOSE_DOC_APPEND_SKILL prefix) → block"

# --- C6: wrong path (not history or changelog) → block
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git add src/foo.js' \
    "C6: COMPOSE_DOC_APPEND_SKILL=1 git add src/foo.js (out-of-allowlist path) → block"

# --- C7: wrong commit subject → block
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git commit -m "feat: x"' \
    'C7: COMPOSE_DOC_APPEND_SKILL=1 git commit -m "feat: x" (wrong subject) → block'

# --- C8: shell chaining → block
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md && git commit -m "docs(history): record PR #1"' \
    "C8: COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md && git commit ... (chaining) → block"

# --- C9: mixed paths in one add (both history and changelog) → block
# The predicate only accepts one target at a time per shape
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md CHANGELOG.md' \
    "C9: COMPOSE_DOC_APPEND_SKILL=1 git add docs/history.md CHANGELOG.md (mixed paths) → block"

# --- C10: sibling ISSUE_CLOSE_SKILL=1 must not accept CHANGELOG.md → block
assert_compose_block \
    'ISSUE_CLOSE_SKILL=1 git add CHANGELOG.md' \
    "C10: ISSUE_CLOSE_SKILL=1 git add CHANGELOG.md (sibling predicate must not over-extend) → block"

# --- C11: tight subject regex — free-form text after 'docs(history):' rejected
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(history): freeform text"' \
    'C11: COMPOSE_DOC_APPEND_SKILL=1 git commit -m "docs(history): freeform text" (must require "record PR #N") → block'

# --- C12: bash script invocation → allow
assert_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 bash "/c/git/agents/bin/compose-doc-append-entry" --notes "/backup/WORKTREE_NOTES.md"' \
    'C12: COMPOSE_DOC_APPEND_SKILL=1 bash ".../bin/compose-doc-append-entry" --notes ... → allow'

# --- C13: bash invocation of wrong script name → block
assert_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 bash "/c/git/agents/bin/other-script" --notes "/backup/WORKTREE_NOTES.md"' \
    'C13: COMPOSE_DOC_APPEND_SKILL=1 bash ".../bin/other-script" (wrong script) → block'

# ============================================================================
# Q-series — push bypass for compose-doc-append-entry (COMPOSE_DOC_APPEND_SKILL)
# ============================================================================

# --- Q1: history-only commit → allow push
_q1_repo="$(setup_push_test_repo_compose "docs(history): record PR #42" "docs/history.md")"
assert_push_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q1_repo" \
    "Q1: COMPOSE_DOC_APPEND_SKILL=1 git push origin main (history commit only) → allow"

# --- Q2: changelog-only commit → allow push
_q2_repo="$(setup_push_test_repo_compose "docs(changelog): record PR #42" "CHANGELOG.md")"
assert_push_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q2_repo" \
    "Q2: COMPOSE_DOC_APPEND_SKILL=1 git push origin main (changelog commit only) → allow"

# --- Q3: two commits (history then changelog) → allow push
_q3_tmp="$(mktemp -d)"
PUSH_TEST_TMPS+=("$_q3_tmp")
_q3_upstream="$_q3_tmp/upstream.git"
_q3_work="$_q3_tmp/work"
git init --bare --initial-branch=main "$_q3_upstream" >/dev/null
git init --initial-branch=main "$_q3_work" >/dev/null
git -C "$_q3_work" config core.hooksPath /dev/null
(cd "$_q3_work"
    git remote add origin "$_q3_upstream"
    git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
    git push -u origin main >/dev/null 2>&1
    git remote set-head origin main >/dev/null 2>&1
    mkdir -p docs/history
    echo "entry1" >> docs/history.md
    git add docs/history.md
    git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(history): record PR #42" >/dev/null
    echo "changelog1" >> CHANGELOG.md
    git add CHANGELOG.md
    git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(changelog): record PR #42" >/dev/null
)
assert_push_compose_allow \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q3_work" \
    "Q3: two commits (history + changelog, each to own file) → allow push (Axis-4 union OK)"

# --- Q4: wrong commit subject → block
_q4_repo="$(setup_push_test_repo_compose "feat: x" "docs/history.md")"
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q4_repo" \
    "Q4: commit subject 'feat: x' → block (Axis-3)"

# --- Q5: history commit also touches src/foo.js → block
_q5_tmp="$(mktemp -d)"
PUSH_TEST_TMPS+=("$_q5_tmp")
_q5_upstream="$_q5_tmp/upstream.git"
_q5_work="$_q5_tmp/work"
git init --bare --initial-branch=main "$_q5_upstream" >/dev/null
git init --initial-branch=main "$_q5_work" >/dev/null
git -C "$_q5_work" config core.hooksPath /dev/null
(cd "$_q5_work"
    git remote add origin "$_q5_upstream"
    git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
    git push -u origin main >/dev/null 2>&1
    git remote set-head origin main >/dev/null 2>&1
    mkdir -p docs/history src
    echo "x" >> docs/history.md
    echo "y" >> src/foo.js
    git add docs/history.md src/foo.js
    git -c user.email=a@b -c user.name=a commit --no-verify -m "docs(history): record PR #42" >/dev/null
)
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q5_work" \
    "Q5: history commit also touches src/foo.js → block (Axis-4)"

# --- Q6: same as Q1 but no COMPOSE_DOC_APPEND_SKILL=1 prefix → block
assert_push_compose_block \
    'git push origin main' \
    "$_q1_repo" \
    "Q6: no COMPOSE_DOC_APPEND_SKILL=1 prefix → block (Axis-1)"

# --- Q7: push to feature branch → block
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin feature/x' \
    "$_q1_repo" \
    "Q7: push to feature/x (not default branch) → block (Axis-2)"

# --- Q8: --force-with-lease flag → block
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push --force-with-lease origin main' \
    "$_q1_repo" \
    "Q8: --force-with-lease flag → block (Axis-2 unknown flag)"

# --- Q9: refspec with colon → block
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main:main' \
    "$_q1_repo" \
    "Q9: refspec 'main:main' → block (Axis-2 colon)"

# --- Q10: chaining → block
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main && rm -rf /tmp' \
    "$_q1_repo" \
    "Q10: git push origin main && rm -rf /tmp (chaining) → block (Axis-1)"

# --- Q11: empty outgoing range → block
_q11_tmp="$(mktemp -d)"
PUSH_TEST_TMPS+=("$_q11_tmp")
_q11_upstream="$_q11_tmp/upstream.git"
_q11_work="$_q11_tmp/work"
git init --bare --initial-branch=main "$_q11_upstream" >/dev/null
git init --initial-branch=main "$_q11_work" >/dev/null
git -C "$_q11_work" config core.hooksPath /dev/null
(cd "$_q11_work"
    git remote add origin "$_q11_upstream"
    git -c user.email=a@b -c user.name=a commit --allow-empty --no-verify -m init >/dev/null
    git push -u origin main >/dev/null 2>&1
    git remote set-head origin main >/dev/null 2>&1
    # No additional commits — local and remote are in sync
)
assert_push_compose_block \
    'COMPOSE_DOC_APPEND_SKILL=1 git push origin main' \
    "$_q11_work" \
    "Q11: empty outgoing range (no unpushed commits) → block (Axis-3 empty subjects)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
