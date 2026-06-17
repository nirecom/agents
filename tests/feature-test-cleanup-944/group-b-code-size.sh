# Group B: review-code-size _archive/ exclusion + thresholds (Cases 4-5, Sanity, 20-22)
# Sourced by tests/feature-test-cleanup-944.sh

REPO_RCS=$(make_repo)
mkdir -p "$REPO_RCS/tests/_archive" "$REPO_RCS/tests/_archived" "$REPO_RCS/normal"
make_lines 10 > "$REPO_RCS/tests/_archive/old.sh"
make_lines 10 > "$REPO_RCS/tests/_archived/older.sh"
make_lines 10 > "$REPO_RCS/normal/live.sh"
git -C "$REPO_RCS" add -A
git -C "$REPO_RCS" commit -q -m "add files"

EXIT_RCS=0
OUT_RCS=$(cd "$REPO_RCS" && run_with_timeout bash "$REVIEW_SIZE" --all 2>&1) || EXIT_RCS=$?

if echo "$OUT_RCS" | grep -q "_archive/old.sh"; then
    fail "Case 4: review-code-size --all should exclude tests/_archive/ but found it"
else
    pass "Case 4: review-code-size --all excludes tests/_archive/ (singular)"
fi

if echo "$OUT_RCS" | grep -q "_archived/older.sh"; then
    pass "Case 5: review-code-size --all does not exclude tests/_archived/ (fix scoped to _archive/)"
else
    fail "Case 5: review-code-size --all excluded tests/_archived/ — fix should only exclude _archive/"
fi

if echo "$OUT_RCS" | grep -q "normal/live.sh"; then
    pass "Sanity: normal/live.sh is included in scan"
else
    fail "Sanity: normal/live.sh missing from --all scan output"
fi

# Case 6b: --base + --all mutually exclusive → SKIPPED
OUT_EXCL=$(run_with_timeout bash "$REVIEW_SIZE" --base HEAD --all 2>&1 || true)
if echo "$OUT_EXCL" | grep -q "SKIPPED"; then
    pass "Case 6b: --base + --all mutually exclusive → SKIPPED"
else
    fail "Case 6b: expected SKIPPED for --base + --all (output: $OUT_EXCL)"
fi

# Cases 20-22: WARN / HARD / boundary thresholds
REPO_THRESH=$(make_repo)
mkdir -p "$REPO_THRESH/src"
make_lines 300 > "$REPO_THRESH/src/at300.sh"
make_lines 301 > "$REPO_THRESH/src/warn.sh"
make_lines 500 > "$REPO_THRESH/src/at500.sh"
make_lines 501 > "$REPO_THRESH/src/hard.sh"
git -C "$REPO_THRESH" add -A
git -C "$REPO_THRESH" commit -q -m "threshold test"

OUT_THRESH=$(cd "$REPO_THRESH" && run_with_timeout bash "$REVIEW_SIZE" --all 2>&1)

if echo "$OUT_THRESH" | grep -q "WARN:.*warn.sh"; then
    pass "Case 20: review-code-size --all emits WARN for 301-line file"
else
    fail "Case 20: expected WARN for warn.sh (output: $OUT_THRESH)"
fi

if echo "$OUT_THRESH" | grep -q "HARD:.*hard.sh"; then
    pass "Case 21: review-code-size --all emits HARD for 501-line file"
else
    fail "Case 21: expected HARD for hard.sh"
fi

if echo "$OUT_THRESH" | grep -q "WARN:.*at300.sh\|HARD:.*at300.sh"; then
    fail "Case 22a: exactly 300-line file should be INFO (not WARN/HARD)"
else
    pass "Case 22a: exactly 300-line file is INFO (no WARN threshold)"
fi

if echo "$OUT_THRESH" | grep -q "HARD:.*at500.sh"; then
    fail "Case 22b: exactly 500-line file should be WARN not HARD"
else
    pass "Case 22b: exactly 500-line file is WARN (not HARD)"
fi
