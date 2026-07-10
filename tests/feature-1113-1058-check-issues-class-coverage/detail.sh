#!/usr/bin/env bash
# Tests: bin/check-issues-class-coverage
# Tags: scope:issue-specific
# Detail-mode tests for bin/check-issues-class-coverage.
# All TC-D* tests will FAIL until bin/check-issues-class-coverage is written.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$AGENTS_ROOT/bin/check-issues-class-coverage"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

GATE_EXISTS=0
[[ -x "$GATE" ]] && GATE_EXISTS=1

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

make_detail_fixture() {
    local path="$1" issues_body="$2" extra_sections="${3:-}"
    {
        echo "# Detail Plan — test"
        echo ""
        echo "## Issues"
        echo ""
        [[ -n "$issues_body" ]] && echo "$issues_body"
        echo ""
        [[ -n "$extra_sections" ]] && echo "$extra_sections"
    } > "$path"
}

# TC-D1: Issues=1, ## Steps present → exit 0
F_D1="$TMPDIR_BASE/detail-d1.md"
make_detail_fixture "$F_D1" "- #200" "$(printf '## Steps\n\n- step 1\n- step 2')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D1" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D1: Issues=1, ## Steps present → exit 0" \
    || fail "TC-D1: Issues=1, ## Steps present → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D2: Issues=1, no ## Steps and no ## Files to modify → exit non-zero
F_D2="$TMPDIR_BASE/detail-d2.md"
make_detail_fixture "$F_D2" "- #201" "$(printf '## Background\n\nsome background only')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D2" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-D2: Issues=1, no Steps/Files section → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-D2: Issues=1, no Steps/Files section → exit non-zero"
else
    fail "TC-D2: Issues=1, no Steps/Files section → expected non-zero, got 0"
fi

# TC-D2b: Issues=2, no Steps and no Files to modify → non-zero (multi-issue undercoverage)
F_D2b="$TMPDIR_BASE/detail-d2b.md"
make_detail_fixture "$F_D2b" "$(printf -- '- #205\n- #206')" "$(printf '## Background\n\nno steps or files')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D2b" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-D2b: Issues=2, no Steps/Files section → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-D2b: Issues=2, no Steps/Files section → exit non-zero"
else
    fail "TC-D2b: Issues=2, no Steps/Files section → expected non-zero, got 0"
fi

# TC-D3: ## Issues missing entirely → exit 0 (no requirement)
F_D3="$TMPDIR_BASE/detail-d3.md"
cat > "$F_D3" << 'EOF'
# Detail Plan — test

## Background

No issues section here at all.

## Steps

- step 1
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D3" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D3: ## Issues missing → exit 0 (no requirement)" \
    || fail "TC-D3: ## Issues missing → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D3b: ## Issues present but empty → exit 0
F_D3b="$TMPDIR_BASE/detail-d3b.md"
make_detail_fixture "$F_D3b" "" "$(printf '## Steps\n\n- step 1')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D3b" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D3b: ## Issues empty → exit 0 (no requirement)" \
    || fail "TC-D3b: ## Issues empty → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D4: Issues=1, ## Files to modify exists (no ## Steps) → exit 0
F_D4="$TMPDIR_BASE/detail-d4.md"
make_detail_fixture "$F_D4" "- #202" "$(printf '## Files to modify\n\n- bin/somefile')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D4" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D4: Issues=1, ## Files to modify present (no ## Steps) → exit 0" \
    || fail "TC-D4: Issues=1, ## Files to modify present → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D5: Issues=2, exactly 1 ## Steps section → exit 0
# (existence gate only, NOT per-entry semantic check — Accepted Tradeoff)
F_D5="$TMPDIR_BASE/detail-d5.md"
make_detail_fixture "$F_D5" "$(printf -- '- #203\n- #204')" "$(printf '## Steps\n\n- step 1\n- step 2')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D5" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D5: Issues=2, ## Steps present (1 section) → exit 0 (existence gate only)" \
    || fail "TC-D5: Issues=2, ## Steps present → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D-FILES-2ISSUES: Issues=2, ## Files to modify (no ## Steps) → exit 0
# Symmetry with TC-D5: existence gate applies to ## Files to modify equally.
F_D_FILES2="$TMPDIR_BASE/detail-files-2issues.md"
make_detail_fixture "$F_D_FILES2" "$(printf -- '- #207\n- #208')" "$(printf '## Files to modify\n\n- bin/foo\n- bin/bar')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D_FILES2" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-D-FILES-2ISSUES: Issues=2, ## Files to modify (no Steps) → exit 0" \
    || fail "TC-D-FILES-2ISSUES: Issues=2, ## Files to modify (no Steps) → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D-ISSUE-SINGULAR: ## Issue (singular, legacy heading) in detail → counted correctly
F_ISSUE_SING_D="$TMPDIR_BASE/detail-issue-singular.md"
cat > "$F_ISSUE_SING_D" << 'EOF'
# Detail Plan — singular heading test

## Issue

- #512

## Steps

- step 1
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_ISSUE_SING_D" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-D-ISSUE-SINGULAR: ## Issue (singular) + ## Steps → exit 0 (singular heading handled)" \
    || fail "TC-D-ISSUE-SINGULAR: ## Issue (singular) + ## Steps → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-D-NONE-DETAIL: ## Issues contains only `- (none detected)` → treated as 0 issues → exit 0
# Symmetry with outline-mode TC-O5; canonical parser must not count the placeholder.
F_D_NONE="$TMPDIR_BASE/detail-none-detected.md"
make_detail_fixture "$F_D_NONE" "- (none detected)" ""
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode detail "$F_D_NONE" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-D-NONE-DETAIL: ## Issues only '- (none detected)' → exit 0 (placeholder not counted)" \
    || fail "TC-D-NONE-DETAIL: '- (none detected)' must not count → expected exit 0, got $EXIT_CODE (output: $OUT)"

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
