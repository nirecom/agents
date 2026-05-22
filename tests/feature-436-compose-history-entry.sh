#!/bin/bash
# tests/feature-436-compose-history-entry.sh
#
# TDD tests for bin/compose-history-entry (#436).
# RED until the CLI is implemented.

set -u

PASS=0
FAIL=0

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$AGENTS_DIR/bin/compose-history-entry"

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

TMPDIRS=()
cleanup() {
    for d in "${TMPDIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done
}
trap cleanup EXIT

mk_tmpdir() {
    local d
    d="$(mktemp -d 2>/dev/null || mktemp -d -t 'cmphist')"
    TMPDIRS+=("$d")
    printf '%s' "$d"
}

mk_git_repo() {
    local d="$1"
    (
        cd "$d" || exit 1
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -q -m "initial commit"
    )
}

export AGENTS_CONFIG_DIR="$AGENTS_DIR"
# Temp git repos created by mk_git_repo are subject to the global core.hookspath
# pre-commit hook (C:\git\agents\hooks). Set ENFORCE_WORKTREE=off so git commits
# in isolated temp repos are not blocked by the main-worktree guard.
export ENFORCE_WORKTREE=off

# Existence gate
if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
    fail "CLI not found at $CLI (expected during TDD RED phase)"
    echo ""
    echo "Passed: $PASS / $((PASS + FAIL))"
    exit 1
fi

run_cli() {
    run_with_timeout 30 bash "$CLI" "$@"
}

# -----------------------------------------------------------------------------
# T1: --worktree-notes with 2 bullets → dry-run output --changes joined by '; '
# -----------------------------------------------------------------------------
t1_dir="$(mk_tmpdir)"
mk_git_repo "$t1_dir"
notes="$t1_dir/WORKTREE_NOTES.md"
cat > "$notes" <<'EOF'
## History Notes
- First note about a thing
- Second note about another thing
EOF
(
    cd "$t1_dir" || exit 1
    out="$(run_cli --worktree-notes "$notes" --dry-run --subject "S" --no-translate 2>/dev/null || true)"
    # Must contain --changes and joined content; must not contain a literal newline in --changes value
    if printf '%s' "$out" | grep -q -- "--changes" \
       && printf '%s' "$out" | grep -q "First note about a thing" \
       && printf '%s' "$out" | grep -q "Second note about another thing" \
       && printf '%s' "$out" | grep -q "First note about a thing; Second note about another thing"; then
        pass "T1: dry-run --changes joins bullets with '; '"
    else
        fail "T1: expected joined changes output; got: $out"
    fi
)

# -----------------------------------------------------------------------------
# T2: History Notes is - (none) only → exit 0, stderr contains "skipping"
# -----------------------------------------------------------------------------
t2_dir="$(mk_tmpdir)"
mk_git_repo "$t2_dir"
notes2="$t2_dir/WORKTREE_NOTES.md"
cat > "$notes2" <<'EOF'
## History Notes
- (none)
EOF
(
    cd "$t2_dir" || exit 1
    err_file="$(mktemp)"
    run_cli --worktree-notes "$notes2" --dry-run --subject "S" --no-translate >/dev/null 2>"$err_file"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -qi "skipping"; then
        pass "T2: (none) → exit 0, stderr 'skipping'"
    else
        fail "T2: rc=$rc, stderr='$err'"
    fi
)

# -----------------------------------------------------------------------------
# T3: --subject "My custom subject" → dry-run output contains exact subject
# -----------------------------------------------------------------------------
t3_dir="$(mk_tmpdir)"
mk_git_repo "$t3_dir"
notes3="$t3_dir/WORKTREE_NOTES.md"
cat > "$notes3" <<'EOF'
## History Notes
- Some bullet
EOF
(
    cd "$t3_dir" || exit 1
    out="$(run_cli --worktree-notes "$notes3" --dry-run --subject "My custom subject" --no-translate 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q "My custom subject"; then
        pass "T3: --subject passed through in dry-run output"
    else
        fail "T3: subject missing; got: $out"
    fi
)

# -----------------------------------------------------------------------------
# T4: --no-translate → no "non-ASCII" warning in stderr
# -----------------------------------------------------------------------------
t4_dir="$(mk_tmpdir)"
mk_git_repo "$t4_dir"
notes4="$t4_dir/WORKTREE_NOTES.md"
cat > "$notes4" <<'EOF'
## History Notes
- ascii only bullet
EOF
(
    cd "$t4_dir" || exit 1
    err_file="$(mktemp)"
    run_cli --worktree-notes "$notes4" --dry-run --subject "S" --no-translate >/dev/null 2>"$err_file"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    if [ "$rc" -eq 0 ] && ! printf '%s' "$err" | grep -qi "non-ASCII"; then
        pass "T4: --no-translate → no non-ASCII warning"
    else
        fail "T4: rc=$rc, stderr='$err'"
    fi
)

# -----------------------------------------------------------------------------
# T5: Idempotency — history.md already has entry with the commit hash → no-op
# -----------------------------------------------------------------------------
t5_dir="$(mk_tmpdir)"
mk_git_repo "$t5_dir"
(
    cd "$t5_dir" || exit 1
    # Make a second commit and capture its short hash
    echo "more" > file2.txt
    git add file2.txt
    git commit -q -m "second commit"
    short="$(git log -1 --format=%h)"
    mkdir -p docs
    cat > docs/history.md <<EOF
# History

### Existing entry (2026-05-22, $short)
Background: foo
Changes: bar
EOF
    git add docs/history.md
    git commit -q -m "seed history"

    notes5="$t5_dir/WORKTREE_NOTES.md"
    cat > "$notes5" <<'EOF'
## History Notes
- A new bullet that should not produce a duplicate entry
EOF
    before="$(git rev-parse HEAD)"
    run_cli --worktree-notes "$notes5" --subject "Existing entry" --no-translate --commits "$short" >/dev/null 2>&1
    rc=$?
    after="$(git rev-parse HEAD)"
    if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then
        pass "T5: idempotency — no new commit when entry with hash already exists"
    else
        fail "T5: rc=$rc, before=$before after=$after"
    fi
)

# -----------------------------------------------------------------------------
# T6: --dry-run → no git commit, argv printed includes 'doc-append'
# -----------------------------------------------------------------------------
t6_dir="$(mk_tmpdir)"
mk_git_repo "$t6_dir"
notes6="$t6_dir/WORKTREE_NOTES.md"
cat > "$notes6" <<'EOF'
## History Notes
- bullet here
EOF
(
    cd "$t6_dir" || exit 1
    before="$(git rev-parse HEAD)"
    out="$(run_cli --worktree-notes "$notes6" --dry-run --subject "S" --no-translate 2>/dev/null || true)"
    after="$(git rev-parse HEAD)"
    if [ "$before" = "$after" ] && printf '%s' "$out" | grep -q "doc-append"; then
        pass "T6: --dry-run does not commit; argv contains doc-append"
    else
        fail "T6: before=$before after=$after; out=$out"
    fi
)

# -----------------------------------------------------------------------------
# T7: WORKTREE_NOTES.md not found → stderr contains 'not found' or
# 'synthesizing'; exit 0; Changes synthesized from git log
# -----------------------------------------------------------------------------
t7_dir="$(mk_tmpdir)"
mk_git_repo "$t7_dir"
(
    cd "$t7_dir" || exit 1
    echo "x" > x.txt; git add x.txt; git commit -q -m "synth subject line"
    err_file="$(mktemp)"
    out="$(run_cli --worktree-notes "$t7_dir/NOPE.md" --dry-run --subject "S" --no-translate 2>"$err_file" || true)"
    rc=$?
    err="$(cat "$err_file")"
    rm -f "$err_file"
    if [ "$rc" -eq 0 ] \
       && { printf '%s' "$err" | grep -qiE "not found|synthesizing"; } \
       && printf '%s' "$out" | grep -q -- "--changes"; then
        pass "T7: missing notes → synthesizes Changes from git log, exit 0"
    else
        fail "T7: rc=$rc, stderr='$err', out='$out'"
    fi
)

# -----------------------------------------------------------------------------
# T8: --commits default resolution — no origin/HEAD set, still works
# -----------------------------------------------------------------------------
t8_dir="$(mk_tmpdir)"
mk_git_repo "$t8_dir"
(
    cd "$t8_dir" || exit 1
    echo "y" > y.txt; git add y.txt; git commit -q -m "second"
    # Ensure no origin/HEAD ref exists
    git update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
    notes8="$t8_dir/WORKTREE_NOTES.md"
    cat > "$notes8" <<'EOF'
## History Notes
- bullet
EOF
    out="$(run_cli --worktree-notes "$notes8" --dry-run --subject "S" --no-translate 2>/dev/null || true)"
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- "--commits"; then
        pass "T8: commit resolution works without origin/HEAD"
    else
        fail "T8: rc=$rc, out='$out'"
    fi
)

echo ""
echo "Passed: $PASS / $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
