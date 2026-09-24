#!/usr/bin/env bash
# tests/feature-1987-check-migration-blocks.sh
# Tests: bin/check-migration-blocks.sh, bin/lib/check-migration-blocks.js
# Tags: migration-blocks, lint, pre-commit, scope:issue-specific, pwsh-not-required

# TL3 gap: pre-commit hook actually blocking a real commit in a live session would
# additionally catch: hook registration wiring in settings.json, interaction with
# WORKFLOW_OFF session marker, and multi-file staged set handling in a real git commit.
# Mitigation: bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$AGENTS_DIR/bin/check-migration-blocks.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want '$want' got '$got'"
    fi
}

if [ ! -f "$CHECKER" ]; then
    echo "SKIP: source not yet implemented (run write-code first)"
    echo "Results: PASS=0 FAIL=0 SKIP=1"
    exit 0
fi

AGENTS_RUN_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

run_checker() {
    bash "$AGENTS_RUN_TIMEOUT" 30 bash "$CHECKER" "$@"
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

make_git_repo() {
    local name="$1"
    local d="$TMPBASE/$name"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config core.hooksPath /dev/null
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    echo "$d"
}

echo "=== feature-1987-check-migration-blocks tests ==="
echo ""

echo "--- Axis 1: BEGIN/END pairing (fail-closed, exit 1) ---"

REPO1="$(make_git_repo axis1-paired-clean)"
cat > "$REPO1/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "temporary code"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO1" add script.sh
rc=0
(cd "$REPO1" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis1-paired-clean: valid paired BEGIN/END → exit 0" "0" "$rc"

REPO2="$(make_git_repo axis1-begin-no-end)"
cat > "$REPO2/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "no end marker"
HEREDOC
git -C "$REPO2" add script.sh
rc=0
(cd "$REPO2" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis1-begin-no-end: BEGIN without END → exit 1" "1" "$rc"

REPO3="$(make_git_repo axis1-end-no-begin)"
cat > "$REPO3/script.sh" << 'HEREDOC'
#!/bin/bash
echo "no begin marker"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO3" add script.sh
rc=0
(cd "$REPO3" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis1-end-no-begin: END without BEGIN → exit 1" "1" "$rc"

echo ""
echo "--- Axis 2: Arrow format (fail-closed, exit 1) ---"

REPO4="$(make_git_repo axis2-unicode-arrow)"
cat > "$REPO4/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "unicode arrow"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO4" add script.sh
rc=0
(cd "$REPO4" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis2-unicode-arrow: Unicode → arrow → exit 0" "0" "$rc"

REPO5="$(make_git_repo axis2-ascii-arrow)"
cat > "$REPO5/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old -> new migration ---
echo "ascii arrow"
# --- END temporary: old -> new migration ---
HEREDOC
git -C "$REPO5" add script.sh
rc=0
(cd "$REPO5" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis2-ascii-arrow: ASCII -> arrow → exit 0" "0" "$rc"

REPO6="$(make_git_repo axis2-js-comment-prefix)"
cat > "$REPO6/app.js" << 'HEREDOC'
// --- BEGIN temporary: old → new migration ---
const x = 1;
// --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO6" add app.js
rc=0
(cd "$REPO6" && run_checker --staged app.js 2>/dev/null) || rc=$?
assert_eq "axis2-js-comment-prefix: JS // comment prefix block → exit 0" "0" "$rc"

REPO7="$(make_git_repo axis2-no-arrow)"
cat > "$REPO7/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old to new migration ---
echo "no arrow"
# --- END temporary: old to new migration ---
HEREDOC
git -C "$REPO7" add script.sh
rc=0
(cd "$REPO7" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis2-no-arrow: BEGIN line with no arrow → exit 1" "1" "$rc"

REPO8="$(make_git_repo axis2-hash-comment)"
cat > "$REPO8/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "hash comment prefix"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO8" add script.sh
rc=0
(cd "$REPO8" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis2-hash-comment: # comment prefix block recognized → exit 0" "0" "$rc"

REPO_NOMIG="$(make_git_repo axis2-no-migration-word)"
cat > "$REPO_NOMIG/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new ---
echo "code"
# --- END temporary: old → new ---
HEREDOC
git -C "$REPO_NOMIG" add script.sh
rc=0
(cd "$REPO_NOMIG" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "axis2-no-migration-word: BEGIN line with arrow but no 'migration' word → exit 1" "1" "$rc"

echo ""
echo "--- Axis 3: Date+condition (warning-only, exit 0) ---"

REPO9="$(make_git_repo axis3-staged-all-blocks-checked)"
cat > "$REPO9/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "block without added field"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO9" add script.sh
rc=0
stderr_out="$TMPBASE/axis3-staged-stderr.txt"
(cd "$REPO9" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
assert_eq "axis3-staged-all-blocks-checked: staged, block without added → exit 0" "0" "$rc"
if grep -qi "warning:" "$stderr_out" 2>/dev/null; then
    pass "axis3-staged-all-blocks-checked: warning on stderr for block without added"
else
    fail "axis3-staged-all-blocks-checked: expected warning on stderr (got: $(cat "$stderr_out" 2>/dev/null))"
fi

REPO10="$(make_git_repo axis3-all-mode-skips-no-date)"
mkdir -p "$REPO10/subdir"
cat > "$REPO10/subdir/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "block without added field"
# --- END temporary: old → new migration ---
HEREDOC
rc=0
stderr_out="$TMPBASE/axis3-all-stderr.txt"
run_checker --all "$REPO10" 2>"$stderr_out" || rc=$?
assert_eq "axis3-all-mode-skips-no-date: --all, block without added → exit 0" "0" "$rc"
if grep -qi "warning:" "$stderr_out" 2>/dev/null; then
    fail "axis3-all-mode-skips-no-date: expected no warning on stderr in --all mode (got: $(cat "$stderr_out" 2>/dev/null))"
else
    pass "axis3-all-mode-skips-no-date: no warning on stderr in --all mode"
fi

REPO11="$(make_git_repo axis3-new-block-has-fields)"
TODAY="$(date +%Y-%m-%d)"
cat > "$REPO11/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $TODAY ---
# deletion-condition: remove after feature is deployed
echo "new block with fields"
# --- END temporary: old -> new migration ---
HEREDOC
git -C "$REPO11" add script.sh
rc=0
stderr_out="$TMPBASE/axis3-new-block-stderr.txt"
(cd "$REPO11" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
assert_eq "axis3-new-block-has-fields: staged, block with added+deletion-condition → exit 0" "0" "$rc"
if grep -qi "warning:" "$stderr_out" 2>/dev/null; then
    fail "axis3-new-block-has-fields: expected no warning on stderr for complete block (got: $(cat "$stderr_out" 2>/dev/null))"
else
    pass "axis3-new-block-has-fields: no warning on stderr for complete block"
fi

echo ""
echo "--- Axis 4: Age warnings (warning-only, exit 0) ---"

REPO12="$(make_git_repo axis4-old-date-warns)"
OLD_DATE="2020-01-01"
cat > "$REPO12/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $OLD_DATE ---
# deletion-condition: remove after migration
echo "old block"
# --- END temporary: old -> new migration ---
HEREDOC
git -C "$REPO12" add script.sh
rc=0
stderr_out="$TMPBASE/axis4-old-stderr.txt"
(cd "$REPO12" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
assert_eq "axis4-old-date-warns: added >90 days ago → exit 0" "0" "$rc"
if grep -qi "old\|age\|days\|warn\|stale\|overdue" "$stderr_out" 2>/dev/null; then
    pass "axis4-old-date-warns: age warning present on stderr"
else
    fail "axis4-old-date-warns: expected age warning on stderr (stderr: $(cat "$stderr_out"))"
fi

REPO13="$(make_git_repo axis4-recent-date-clean)"
RECENT_DATE="$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '-30 days' +%Y-%m-%d 2>/dev/null || echo "2099-01-01")"
cat > "$REPO13/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $RECENT_DATE ---
# deletion-condition: remove after migration
echo "recent block"
# --- END temporary: old -> new migration ---
HEREDOC
git -C "$REPO13" add script.sh
rc=0
stderr_out="$TMPBASE/axis4-recent-stderr.txt"
(cd "$REPO13" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
assert_eq "axis4-recent-date-clean: added 30 days ago → exit 0 (no age warning)" "0" "$rc"
if grep -qi "warning:" "$stderr_out" 2>/dev/null; then
    fail "axis4-recent-date-clean: expected no age warning on stderr (got: $(cat "$stderr_out" 2>/dev/null))"
else
    pass "axis4-recent-date-clean: no age warning on stderr for recent block"
fi

echo ""
echo "--- Axis 4: Boundary value tests (89/90/91 days) ---"

get_past_date() {
    local days=$1
    date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "${days} days ago" +%Y-%m-%d 2>/dev/null || echo "2099-01-01"
}

DATE_89="$(get_past_date 89)"
DATE_90="$(get_past_date 90)"
DATE_91="$(get_past_date 91)"

if [ "$DATE_89" = "2099-01-01" ] || [ "$DATE_90" = "2099-01-01" ] || [ "$DATE_91" = "2099-01-01" ]; then
    skip "axis4-boundary-89d: date computation failed, skipping boundary tests"
    skip "axis4-boundary-90d: date computation failed, skipping boundary tests"
    skip "axis4-boundary-91d: date computation failed, skipping boundary tests"
else
    REPO_B89="$(make_git_repo axis4-boundary-89d)"
    cat > "$REPO_B89/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $DATE_89 ---
# deletion-condition: when #1987 merged
echo "code"
# --- END temporary: old -> new migration ---
HEREDOC
    git -C "$REPO_B89" add script.sh
    rc=0
    stderr_out="$TMPBASE/axis4-89d-stderr.txt"
    (cd "$REPO_B89" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
    assert_eq "axis4-boundary-89d: added 89 days ago → exit 0 (no age warning)" "0" "$rc"
    if grep -qi "warning:" "$stderr_out" 2>/dev/null; then
        fail "axis4-boundary-89d: expected no age warning for 89d block (got: $(cat "$stderr_out" 2>/dev/null))"
    else
        pass "axis4-boundary-89d: no age warning for 89d block"
    fi

    REPO_B90="$(make_git_repo axis4-boundary-90d)"
    cat > "$REPO_B90/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $DATE_90 ---
# deletion-condition: when #1987 merged
echo "code"
# --- END temporary: old -> new migration ---
HEREDOC
    git -C "$REPO_B90" add script.sh
    rc=0
    stderr_out="$TMPBASE/axis4-90d-stderr.txt"
    (cd "$REPO_B90" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
    assert_eq "axis4-boundary-90d: added exactly 90 days ago → exit 0 (warning expected)" "0" "$rc"
    if grep -qi "old\|age\|days\|warn\|stale\|overdue" "$stderr_out" 2>/dev/null; then
        pass "axis4-boundary-90d: age warning present for 90d block"
    else
        fail "axis4-boundary-90d: expected age warning for 90d block (stderr: $(cat "$stderr_out"))"
    fi

    REPO_B91="$(make_git_repo axis4-boundary-91d)"
    cat > "$REPO_B91/script.sh" << HEREDOC
#!/bin/bash
# --- BEGIN temporary: old -> new migration added $DATE_91 ---
# deletion-condition: when #1987 merged
echo "code"
# --- END temporary: old -> new migration ---
HEREDOC
    git -C "$REPO_B91" add script.sh
    rc=0
    stderr_out="$TMPBASE/axis4-91d-stderr.txt"
    (cd "$REPO_B91" && run_checker --staged script.sh 2>"$stderr_out") || rc=$?
    assert_eq "axis4-boundary-91d: added 91 days ago → exit 0 (warning expected)" "0" "$rc"
    if grep -qi "old\|age\|days\|warn\|stale\|overdue" "$stderr_out" 2>/dev/null; then
        pass "axis4-boundary-91d: age warning present for 91d block"
    else
        fail "axis4-boundary-91d: expected age warning for 91d block (stderr: $(cat "$stderr_out"))"
    fi
fi

echo ""
echo "--- Exclusion rules ---"

REPO14="$(make_git_repo exclude-rules-md)"
mkdir -p "$REPO14/rules"
cat > "$REPO14/rules/example.md" << 'HEREDOC'
# --- BEGIN temporary: old → new migration ---
This is documentation showing migration block syntax.
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO14" add rules/example.md
rc=0
(cd "$REPO14" && run_checker --staged rules/example.md 2>/dev/null) || rc=$?
assert_eq "exclude-rules-md: rules/*.md with markers → excluded, exit 0" "0" "$rc"

REPO15="$(make_git_repo exclude-tests-dir)"
mkdir -p "$REPO15/tests"
cat > "$REPO15/tests/example.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "test file with markers"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO15" add tests/example.sh
rc=0
(cd "$REPO15" && run_checker --staged tests/example.sh 2>/dev/null) || rc=$?
assert_eq "exclude-tests-dir: tests/ file with markers → excluded, exit 0" "0" "$rc"

echo ""
echo "--- Index vs working tree ---"

REPO16="$(make_git_repo staged-reads-from-index)"
cat > "$REPO16/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "valid block in index"
# --- END temporary: old → new migration ---
HEREDOC
git -C "$REPO16" add script.sh
cat > "$REPO16/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "broken working tree - no end marker"
HEREDOC
rc=0
(cd "$REPO16" && run_checker --staged script.sh 2>/dev/null) || rc=$?
assert_eq "staged-reads-from-index: --staged reads git index (clean), not broken working tree → exit 0" "0" "$rc"

echo ""
echo "--- --all mode violations ---"

ALLDIR1="$TMPBASE/all-axis1-violation"
mkdir -p "$ALLDIR1"
cat > "$ALLDIR1/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "no end marker"
HEREDOC
rc=0
run_checker --all "$ALLDIR1" 2>/dev/null || rc=$?
assert_eq "all-axis1-violation: --all, BEGIN without END → exit 1" "1" "$rc"

ALLDIR2="$TMPBASE/all-axis2-violation"
mkdir -p "$ALLDIR2"
cat > "$ALLDIR2/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old to new migration ---
echo "no arrow"
# --- END temporary: old to new migration ---
HEREDOC
rc=0
run_checker --all "$ALLDIR2" 2>/dev/null || rc=$?
assert_eq "all-axis2-violation: --all, BEGIN/END with no arrow → exit 1" "1" "$rc"

echo ""
echo "--- Indented block markers (--all mode) ---"

ALLDIR_INDENT1="$TMPBASE/all-indent-paired-clean"
mkdir -p "$ALLDIR_INDENT1"
cat > "$ALLDIR_INDENT1/script.sh" << 'HEREDOC'
#!/bin/bash
    # --- BEGIN temporary: old → new migration ---
    echo "code"
    # --- END temporary: old → new migration ---
HEREDOC
rc=0
run_checker --all "$ALLDIR_INDENT1" 2>/dev/null || rc=$?
assert_eq "all-indent-paired-clean: --all, indented paired BEGIN/END → exit 0" "0" "$rc"

ALLDIR_INDENT2="$TMPBASE/all-indent-begin-no-end"
mkdir -p "$ALLDIR_INDENT2"
cat > "$ALLDIR_INDENT2/script.sh" << 'HEREDOC'
#!/bin/bash
    # --- BEGIN temporary: old → new migration ---
    echo "code"
HEREDOC
rc=0
run_checker --all "$ALLDIR_INDENT2" 2>/dev/null || rc=$?
assert_eq "all-indent-begin-no-end: --all, indented BEGIN without END → exit 1" "1" "$rc"

echo ""
echo "--- Multiple migration blocks in one file (--all mode) ---"

ALLDIR_MULTI1="$TMPBASE/all-multi-blocks-all-paired"
mkdir -p "$ALLDIR_MULTI1"
cat > "$ALLDIR_MULTI1/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "block one"
# --- END temporary: old → new migration ---
# --- BEGIN temporary: old → new migration ---
echo "block two"
# --- END temporary: old → new migration ---
HEREDOC
rc=0
run_checker --all "$ALLDIR_MULTI1" 2>/dev/null || rc=$?
assert_eq "all-multi-blocks-all-paired: --all, 2 valid paired blocks → exit 0" "0" "$rc"

ALLDIR_MULTI2="$TMPBASE/all-multi-blocks-second-unpaired"
mkdir -p "$ALLDIR_MULTI2"
cat > "$ALLDIR_MULTI2/script.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "block one"
# --- END temporary: old → new migration ---
# --- BEGIN temporary: old → new migration ---
echo "block two - no end"
HEREDOC
rc=0
run_checker --all "$ALLDIR_MULTI2" 2>/dev/null || rc=$?
assert_eq "all-multi-blocks-second-unpaired: --all, 2nd block BEGIN without END → exit 1" "1" "$rc"

echo ""
echo "--- Exit codes ---"

REPO17="$(make_git_repo exit-clean)"
cat > "$REPO17/clean.sh" << 'HEREDOC'
#!/bin/bash
echo "no migration markers here"
HEREDOC
git -C "$REPO17" add clean.sh
rc=0
(cd "$REPO17" && run_checker --staged clean.sh 2>/dev/null) || rc=$?
assert_eq "exit-clean: no violations → exit 0" "0" "$rc"

REPO18="$(make_git_repo exit-violation)"
cat > "$REPO18/broken.sh" << 'HEREDOC'
#!/bin/bash
# --- BEGIN temporary: old → new migration ---
echo "missing end"
HEREDOC
git -C "$REPO18" add broken.sh
rc=0
(cd "$REPO18" && run_checker --staged broken.sh 2>/dev/null) || rc=$?
assert_eq "exit-violation: axis 1 violation → exit 1" "1" "$rc"

REPO19="$(make_git_repo exit-no-staged-files)"
rc=0
(cd "$REPO19" && run_checker --staged nonexistent.sh 2>/dev/null) || rc=$?
assert_eq "exit-no-staged-files: --staged with no staged files → exit 0" "0" "$rc"

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
