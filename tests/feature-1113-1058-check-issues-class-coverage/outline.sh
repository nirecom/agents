#!/usr/bin/env bash
# Tests: bin/check-issues-class-coverage
# Tags: scope:issue-specific
# Outline-mode tests for bin/check-issues-class-coverage.
# All TC-O* tests will FAIL until bin/check-issues-class-coverage is written.
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

# Prereq
if [[ -x "$GATE" ]]; then
    pass "prereq: bin/check-issues-class-coverage is executable"
else
    fail "prereq: bin/check-issues-class-coverage not found or not executable: $GATE"
fi

make_outline_fixture() {
    local path="$1" issues_body="$2" class_body="$3"
    cat > "$path" << EOF
# Outline Plan — test

## Issues

${issues_body}

## Class members

${class_body}

## Accepted Tradeoffs

- tradeoff A
EOF
}

# TC-O1: Issues=1, Class members=1 → exit 0
F_O1="$TMPDIR_BASE/outline-o1.md"
make_outline_fixture "$F_O1" "- #100" "- member-A: first member"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O1" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O1: Issues=1, members=1 → exit 0" \
    || fail "TC-O1: Issues=1, members=1 → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O2: Issues=2, Class members=1 → exit non-zero (undercoverage blocked)
F_O2="$TMPDIR_BASE/outline-o2.md"
make_outline_fixture "$F_O2" "$(printf -- '- #101\n- #102')" "- member-A: first member"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O2" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O2: Issues=2, members=1 → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O2: Issues=2, members=1 → exit non-zero (undercoverage blocked)"
else
    fail "TC-O2: Issues=2, members=1 → expected non-zero, got 0"
fi

# TC-O3: Issues=2, Class members=2 → exit 0
F_O3="$TMPDIR_BASE/outline-o3.md"
make_outline_fixture "$F_O3" "$(printf -- '- #101\n- #102')" "$(printf -- '- member-A: first\n- member-B: second')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O3" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O3: Issues=2, members=2 → exit 0" \
    || fail "TC-O3: Issues=2, members=2 → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O4: Issues=0 → exit 0 (no requirement when no Issues)
F_O4="$TMPDIR_BASE/outline-o4.md"
make_outline_fixture "$F_O4" "" "- member-A: present"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O4" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O4: Issues=0 → exit 0 (no requirement)" \
    || fail "TC-O4: Issues=0 → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O5: Class members has only `- (none detected)` → not counted; fails if Issues≥1
F_O5="$TMPDIR_BASE/outline-o5.md"
make_outline_fixture "$F_O5" "- #103" "- (none detected)"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O5" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O5: '- (none detected)' not counted → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O5: '- (none detected)' not counted → non-zero when Issues=1"
else
    fail "TC-O5: '- (none detected)' must not count → expected non-zero, got 0"
fi

# TC-O6: Issues with bare #N, repo#N, owner/repo#N → parse-closes-issues counts all
F_O6="$TMPDIR_BASE/outline-o6.md"
make_outline_fixture "$F_O6" \
    "$(printf -- '- #104\n- dotfiles#105\n- nirecom/my-private-repo#106')" \
    "$(printf -- '- member-X\n- member-Y\n- member-Z')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O6" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O6: bare/#N/repo#N/owner/repo#N → Issues=3, members=3 → exit 0" \
    || fail "TC-O6: expected exit 0 for 3 issues (various forms) + 3 members, got $EXIT_CODE (output: $OUT)"

# TC-O6-table: each issue-reference form tested individually (table-driven)
while IFS='|' read -r tc_name issue_line; do
    F_O6t="$TMPDIR_BASE/outline-o6-${tc_name}.md"
    make_outline_fixture "$F_O6t" "- ${issue_line}" "- member-solo"
    EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O6t" 2>&1) || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        pass "TC-O6-table/${tc_name}: Issues=1 (${issue_line}), members=1 → exit 0"
    else
        fail "TC-O6-table/${tc_name}: Issues=1 (${issue_line}), members=1 → expected exit 0, got $EXIT_CODE (output: $OUT)"
    fi
done << 'FORMS_EOF'
bare-hash|#108
repo-hash|dotfiles#109
owner-repo-hash|nirecom/my-private-repo#110
FORMS_EOF

# TC-O6-table-negative: non-matching lines must NOT be counted as issue references
F_O6_NEG="$TMPDIR_BASE/outline-o6-negative.md"
make_outline_fixture "$F_O6_NEG" \
    "$(printf -- '- some prose with #notanumber here\n- another line\n- #513')" \
    "- member-solo"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O6_NEG" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O6-table-negative: prose #notanumber not counted → Issues=1, members=1 → exit 0" \
    || fail "TC-O6-table-negative: prose lines with # must not be counted → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O-INVALID: --mode given unrecognized value → non-zero exit
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode bogus "$TMPDIR_BASE/outline-o1.md" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O-INVALID: --mode bogus → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O-INVALID: --mode bogus → non-zero exit"
else
    fail "TC-O-INVALID: --mode bogus → expected non-zero, got 0"
fi

# TC-O7: Issues=1, Class members=3 → exit 0 (extra members OK)
F_O7="$TMPDIR_BASE/outline-o7.md"
make_outline_fixture "$F_O7" "- #107" "$(printf -- '- member-A\n- member-B\n- member-C')"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_O7" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O7: Issues=1, members=3 → exit 0 (extra members OK)" \
    || fail "TC-O7: Issues=1, members=3 → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O8: Missing/nonexistent artifact path → non-zero exit + error message
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$TMPDIR_BASE/no-such-file.md" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O8: nonexistent path → CLI missing, cannot verify"
    fail "TC-O8: nonexistent path → CLI missing, cannot verify error message"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O8: nonexistent path → non-zero exit"
    echo "$OUT" | grep -qi "error\|not found\|no such" \
        && pass "TC-O8: nonexistent path → output contains error message" \
        || fail "TC-O8: nonexistent path → expected error message in output, got: $OUT"
else
    fail "TC-O8: nonexistent path → expected non-zero, got 0"
    fail "TC-O8: nonexistent path → skipped (exit was 0)"
fi

# TC-O-CLASS-ABSENT: ## Class members section completely absent (not just (none detected))
F_CLASS_ABSENT="$TMPDIR_BASE/outline-class-absent.md"
cat > "$F_CLASS_ABSENT" << 'EOF'
# Outline Plan — class-absent test

## Issues

- #510

## Accepted Tradeoffs

- tradeoff only, no class members section at all
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_CLASS_ABSENT" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O-CLASS-ABSENT: no ## Class members section → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O-CLASS-ABSENT: ## Class members absent → exit non-zero (members=0 < issues=1)"
else
    fail "TC-O-CLASS-ABSENT: ## Class members absent → expected non-zero, got 0"
fi

# TC-O-ISSUE-SINGULAR: ## Issue (singular, legacy heading) in outline → handled as Issues
F_ISSUE_SING_O="$TMPDIR_BASE/outline-issue-singular.md"
cat > "$F_ISSUE_SING_O" << 'EOF'
# Outline Plan — singular heading test

## Issue

- #511

## Class members

- member-sing

## Accepted Tradeoffs

- (none)
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_ISSUE_SING_O" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-O-ISSUE-SINGULAR: ## Issue (singular) + 1 member → exit 0 (singular heading handled)" \
    || fail "TC-O-ISSUE-SINGULAR: ## Issue (singular) + 1 member → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O-FENCED: heading inside backtick fenced block must NOT be counted as ## Class members
F_FENCED="$TMPDIR_BASE/outline-fenced.md"
cat > "$F_FENCED" << 'EOF'
# Outline Plan — fenced test

## Issues

- #500

## Class members

- member-real

## Accepted Tradeoffs

```
## Class members (this is inside a code fence and must not be counted)

- fake-member
```
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_FENCED" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-O-FENCED: Issues=1, 1 real member + fenced fake (backtick) → exit 0 (fenced heading ignored)" \
    || fail "TC-O-FENCED: Issues=1, 1 real member + fenced fake (backtick) → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O-FENCED-TILDE: heading inside tilde fenced block must NOT be counted
F_FENCED_TILDE="$TMPDIR_BASE/outline-fenced-tilde.md"
cat > "$F_FENCED_TILDE" << 'EOF'
# Outline Plan — tilde fenced test

## Issues

- #503

## Class members

- member-tilde-real

## Accepted Tradeoffs

~~~
## Class members (tilde fence; must not be counted)

- fake-tilde-member
~~~
EOF
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_FENCED_TILDE" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-O-FENCED-TILDE: Issues=1, 1 real member + tilde-fenced fake → exit 0 (tilde fence ignored)" \
    || fail "TC-O-FENCED-TILDE: Issues=1, 1 real member + tilde-fenced fake → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-O-PATH-SPACE: path argument with spaces is handled correctly
F_SPACE="$TMPDIR_BASE/outline with space.md"
make_outline_fixture "$F_SPACE" "- #501" "- member-space"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_SPACE" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] && pass "TC-O-PATH-SPACE: path with spaces → exit 0" \
    || fail "TC-O-PATH-SPACE: path with spaces → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-MISSING-MODE: --mode argument omitted → non-zero exit
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" "$TMPDIR_BASE/outline-o1.md" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-MISSING-MODE: no --mode arg → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-MISSING-MODE: no --mode arg → non-zero exit"
else
    fail "TC-MISSING-MODE: no --mode arg → expected non-zero, got 0"
fi

# TC-MISSING-FILE: file operand omitted → non-zero exit
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-MISSING-FILE: no file operand → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-MISSING-FILE: no file operand → non-zero exit"
else
    fail "TC-MISSING-FILE: no file operand → expected non-zero, got 0"
fi

# TC-O6-NONE-SPACE: `- ( none detected )` with interior spaces still not counted
F_NONE_SPACE="$TMPDIR_BASE/outline-none-space.md"
make_outline_fixture "$F_NONE_SPACE" "- #502" "- ( none detected )"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$GATE" --mode outline "$F_NONE_SPACE" 2>&1) || EXIT_CODE=$?
if [[ $GATE_EXISTS -eq 0 ]]; then
    fail "TC-O6-NONE-SPACE: '- ( none detected )' → CLI missing, cannot verify"
elif [[ $EXIT_CODE -ne 0 ]]; then
    pass "TC-O6-NONE-SPACE: '- ( none detected )' (spaced) not counted → non-zero when Issues=1"
else
    fail "TC-O6-NONE-SPACE: '- ( none detected )' must not count → expected non-zero, got 0"
fi

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
