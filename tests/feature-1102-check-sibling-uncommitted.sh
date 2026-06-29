#!/bin/bash
# tests/feature-1102-check-sibling-uncommitted.sh
# Tests: bin/check-sibling-uncommitted.sh
# Tags: sibling, uncommitted, worktree, git, scope:issue-specific, pwsh-not-required
#
# Tests for bin/check-sibling-uncommitted.sh — parses WORKTREE_NOTES.md
# ## SiblingWorktrees section and warns (stderr) when siblings have dirty or
# unpushed work. Always exits 0 (advisory/non-blocking).
#
# Real throwaway git repos are created under mktemp to represent clean/dirty/unpushed
# states. Uses `git -c init.defaultBranch=main init` and per-repo user config to
# avoid dependency on global git config.
#
# L3 gap (what this test does NOT catch):
# - commit-push CP-2 invoking this advisory against real sibling worktrees during
#   an actual push.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/check-sibling-uncommitted.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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
    fail "SETUP: bin/check-sibling-uncommitted.sh not found at $SCRIPT"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Create a minimal git repo with one commit.
# Args: <dir>
init_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" -c init.defaultBranch=main init --quiet
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    # Disable hooks to avoid interference.
    git -C "$dir" config core.hooksPath /dev/null
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit --quiet -m "initial"
}

# Write a WORKTREE_NOTES.md with a SiblingWorktrees section listing one sibling.
# Args: <notes_file> <repo> <path>
write_notes_one_sibling() {
    local notes_file="$1"
    local repo="$2"
    local wt_path="$3"
    printf '# WORKTREE_NOTES\n\n## SiblingWorktrees\n- repo: %s, path: %s\n\n## Other\nsome content\n' \
        "$repo" "$wt_path" > "$notes_file"
}

# ===========================================================================
# T1: Missing notes file → silent exit 0
# ===========================================================================
OUT=$(run_with_timeout 30 bash "$SCRIPT" "$TMPDIR_BASE/nonexistent-notes.md" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "T1: missing notes file → silent exit 0, no output"
else
    fail "T1: missing notes" "rc=$RC out='$OUT'"
fi

# ===========================================================================
# T2: Notes file with no ## SiblingWorktrees section → exit 0, no stderr
# ===========================================================================
NOTES_T2="$TMPDIR_BASE/notes-t2.md"
printf '# WORKTREE_NOTES\n\n## Issues\n- #42\n' > "$NOTES_T2"
STDERR_T2=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T2" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$STDERR_T2" ]; then
    pass "T2: no ## SiblingWorktrees section → exit 0, no stderr"
else
    fail "T2: no section" "rc=$RC stderr='$STDERR_T2'"
fi

# ===========================================================================
# T3: Clean sibling → no warning, exit 0
# ===========================================================================
CLEAN_DIR="$TMPDIR_BASE/t3-clean"
init_git_repo "$CLEAN_DIR"
NOTES_T3="$TMPDIR_BASE/notes-t3.md"
write_notes_one_sibling "$NOTES_T3" "example-org/agents" "$CLEAN_DIR"
STDERR_T3=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T3" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$STDERR_T3" ]; then
    pass "T3: clean sibling (committed, no upstream) → no warning, exit 0"
else
    fail "T3: clean sibling" "rc=$RC stderr='$STDERR_T3'"
fi

# ===========================================================================
# T4: Dirty sibling (uncommitted changes) → stderr warning, exit 0
# ===========================================================================
DIRTY_DIR="$TMPDIR_BASE/t4-dirty"
init_git_repo "$DIRTY_DIR"
# Add an uncommitted file to make it dirty.
printf 'dirty content\n' > "$DIRTY_DIR/dirty.txt"
NOTES_T4="$TMPDIR_BASE/notes-t4.md"
write_notes_one_sibling "$NOTES_T4" "example-org/dotfiles" "$DIRTY_DIR"
STDERR_T4=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T4" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && echo "$STDERR_T4" | grep -q "Warning:.*sibling"; then
    pass "T4: dirty sibling → 'Warning:' on stderr, exit 0"
else
    fail "T4: dirty sibling" "rc=$RC stderr='$STDERR_T4'"
fi

# ===========================================================================
# T5: Unpushed sibling → stderr warning, exit 0
# ===========================================================================
# Create a bare "remote" repo, clone it (so there's an upstream), then add
# a local commit without pushing so @{u}..HEAD is non-empty.
BARE_DIR="$TMPDIR_BASE/t5-bare.git"
UNPUSHED_DIR="$TMPDIR_BASE/t5-unpushed"

git -c init.defaultBranch=main init --bare --quiet "$BARE_DIR"
# Initialize the bare repo with an initial commit via a temp clone.
INIT_CLONE="$TMPDIR_BASE/t5-init-clone"
git clone --quiet "$BARE_DIR" "$INIT_CLONE" 2>/dev/null
git -C "$INIT_CLONE" config user.email "test@example.com"
git -C "$INIT_CLONE" config user.name "Test"
git -C "$INIT_CLONE" config core.hooksPath /dev/null
printf 'init\n' > "$INIT_CLONE/README.md"
git -C "$INIT_CLONE" add README.md
git -C "$INIT_CLONE" commit --quiet -m "initial"
git -C "$INIT_CLONE" push --quiet origin main 2>/dev/null
rm -rf "$INIT_CLONE"

# Now clone to the actual unpushed repo.
git clone --quiet "$BARE_DIR" "$UNPUSHED_DIR" 2>/dev/null
git -C "$UNPUSHED_DIR" config user.email "test@example.com"
git -C "$UNPUSHED_DIR" config user.name "Test"
git -C "$UNPUSHED_DIR" config core.hooksPath /dev/null

# Add a local commit that's not pushed.
printf 'local change\n' > "$UNPUSHED_DIR/local.txt"
git -C "$UNPUSHED_DIR" add local.txt
git -C "$UNPUSHED_DIR" commit --quiet -m "local unpushed commit"

NOTES_T5="$TMPDIR_BASE/notes-t5.md"
write_notes_one_sibling "$NOTES_T5" "example-org/private" "$UNPUSHED_DIR"
STDERR_T5=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T5" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && echo "$STDERR_T5" | grep -q "Warning:.*sibling"; then
    pass "T5: unpushed sibling → 'Warning:' on stderr, exit 0"
else
    fail "T5: unpushed sibling" "rc=$RC stderr='$STDERR_T5'"
fi

# ===========================================================================
# T6: Nonexistent sibling path → silently skipped, exit 0, no stderr
# ===========================================================================
NOTES_T6="$TMPDIR_BASE/notes-t6.md"
write_notes_one_sibling "$NOTES_T6" "example-org/gone" "/this/path/does/not/exist/worktree"
STDERR_T6=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T6" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$STDERR_T6" ]; then
    pass "T6: nonexistent sibling path → skipped, exit 0, no stderr"
else
    fail "T6: nonexistent path" "rc=$RC stderr='$STDERR_T6'"
fi

# ===========================================================================
# T7: SECURITY/EDGE — sibling path containing a pipe `|` character.
# The awk parser emits `repo "|" wt` and the while-loop splits on IFS='|', so a
# path that itself contains `|` can corrupt field parsing. This test PINS the
# current behavior: regardless of mis-split, the script must still exit 0
# (advisory, non-blocking) and must not crash. We point at a real dirty repo so
# the warning path is exercised. The observed repo/path attribution is recorded
# in the pass message rather than asserted (goal = pin exit-0 + no-crash, not
# assert a specific possibly-buggy split). Source is NOT modified.
# ===========================================================================
PIPE_DIR="$TMPDIR_BASE/t7-pipe|seg"
init_git_repo "$PIPE_DIR"
# Make it dirty so the warning branch runs.
printf 'dirty\n' > "$PIPE_DIR/dirty.txt"
NOTES_T7="$TMPDIR_BASE/notes-t7.md"
write_notes_one_sibling "$NOTES_T7" "example-org/piped" "$PIPE_DIR"
STDERR_T7=$(run_with_timeout 30 bash "$SCRIPT" "$NOTES_T7" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ]; then
    # Did the warning fire, and was the path attributed correctly despite the `|`?
    if echo "$STDERR_T7" | grep -qF "$PIPE_DIR"; then
        pass "T7: pipe-in-path sibling → exit 0, no crash (path attributed correctly: warning contains full path)"
    elif echo "$STDERR_T7" | grep -q "Warning:.*sibling"; then
        pass "T7: pipe-in-path sibling → exit 0, no crash (OBSERVED field-split corruption: warning fired but path mis-attributed by IFS='|' split — follow-up note)"
    else
        # No warning at all: the dir likely failed the `[[ -d ... ]]` guard after
        # mis-split, so the dirty repo was silently skipped. Still exit 0, no crash.
        pass "T7: pipe-in-path sibling → exit 0, no crash (OBSERVED: no warning — sibling silently skipped after IFS='|' mis-split; advisory contract preserved)"
    fi
else
    fail "T7: pipe-in-path crash/non-zero exit" "rc=$RC stderr='$STDERR_T7'"
fi

# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
