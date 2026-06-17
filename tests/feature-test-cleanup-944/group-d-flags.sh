# Group D: audit-tests.sh flags, edge cases, invalid args (Cases 17-27)
# Sourced by tests/feature-test-cleanup-944.sh

if [[ ! -f "$AUDIT_TESTS" ]]; then
    skip "Cases 17-27: bin/audit-tests.sh does not exist yet"
else

# Case 17: --format json produces valid JSON with candidates
STUB17=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB17" "closed"
REPO17=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO17/tests/feature-100-json.sh"
git -C "$REPO17" add tests/feature-100-json.sh
backdate_commit "$REPO17" 200 "stale json"

EXIT17=0
OUT17=$(cd "$REPO17" && PATH="$STUB17:$PATH" run_with_timeout bash "$REPO17/bin/audit-tests.sh" --format json 2>&1) || EXIT17=$?

if echo "$OUT17" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit((d.candidates&&d.candidates.length>0)?0:1)' 2>/dev/null; then
    pass "Case 17: --format json produces valid JSON with non-empty candidates"
else
    fail "Case 17: --format json output is invalid or candidates empty (output: $OUT17)"
fi

# Case 18: --stale-months 1 lowers threshold
STUB18=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB18" "closed"
REPO18=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO18/tests/feature-100-short.sh"
git -C "$REPO18" add tests/feature-100-short.sh
backdate_commit "$REPO18" 60 "60-day-old"

# Default 3-month (~90 days) — 60-day-old file should NOT qualify
EXIT18a=0
OUT18a=$(cd "$REPO18" && PATH="$STUB18:$PATH" run_with_timeout bash "$REPO18/bin/audit-tests.sh" 2>&1) || EXIT18a=$?
if echo "$OUT18a" | grep -q "CANDIDATE:"; then
    fail "Case 18a: 60-day-old file should not qualify at default 3-month threshold"
else
    pass "Case 18a: 60-day-old file excluded at default 3-month threshold"
fi

# --stale-months 1 (~30 days) — 60-day-old file SHOULD qualify
EXIT18b=0
OUT18b=$(cd "$REPO18" && PATH="$STUB18:$PATH" run_with_timeout bash "$REPO18/bin/audit-tests.sh" --stale-months 1 2>&1) || EXIT18b=$?
if echo "$OUT18b" | grep -q "CANDIDATE:"; then
    pass "Case 18b: 60-day-old file qualifies with --stale-months 1"
else
    fail "Case 18b: 60-day-old file should qualify with --stale-months 1 (output: $OUT18b)"
fi

# Cases 19a-d: invalid CLI args exit 2
NOGIT19=$(mktemp -d -p "$TMPDIR_BASE")
cp "$AUDIT_TESTS" "$NOGIT19/audit-tests.sh"
chmod +x "$NOGIT19/audit-tests.sh"
mkdir -p "$NOGIT19/tests"

for case_label in "19a:--stale-months" "19b:--format" "19c:--format bad" "19d:--stale-months abc"; do
    label="${case_label%%:*}"
    args="${case_label#*:}"
    EXIT19=0
    # shellcheck disable=SC2086
    (cd "$NOGIT19" && bash "$NOGIT19/audit-tests.sh" $args 2>/dev/null) || EXIT19=$?
    if [[ $EXIT19 -eq 2 ]]; then
        pass "Case $label: invalid arg '$args' exits 2"
    else
        fail "Case $label: invalid arg '$args' expected exit 2, got $EXIT19"
    fi
done

# Case 23: --help exits 0
EXIT23=0
(bash "$AUDIT_TESTS" --help >/dev/null 2>&1) || EXIT23=$?
if [[ $EXIT23 -eq 0 ]]; then
    pass "Case 23: --help exits 0"
else
    fail "Case 23: --help expected exit 0, got $EXIT23"
fi

# Case 24: --stale-months 0 — even 1-day-old file qualifies
STUB24=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB24" "closed"
REPO24=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO24/tests/feature-100-new.sh"
git -C "$REPO24" add tests/feature-100-new.sh
backdate_commit "$REPO24" 1 "1-day-old"

EXIT24=0
OUT24=$(cd "$REPO24" && PATH="$STUB24:$PATH" run_with_timeout bash "$REPO24/bin/audit-tests.sh" --stale-months 0 2>&1) || EXIT24=$?

if echo "$OUT24" | grep -q "CANDIDATE:"; then
    pass "Case 24: --stale-months 0 qualifies 1-day-old CLOSED file"
else
    fail "Case 24: --stale-months 0 should qualify 1-day-old file (output: $OUT24)"
fi

# Case 25: multi-file — two qualifying files both appear in report
STUB25=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB25" "closed"
REPO25=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO25/tests/feature-100-first.sh"
echo "#!/bin/bash" > "$REPO25/tests/feature-300-second.sh"
git -C "$REPO25" add tests/feature-100-first.sh tests/feature-300-second.sh
backdate_commit "$REPO25" 200 "two stale files"

EXIT25=0
OUT25=$(cd "$REPO25" && PATH="$STUB25:$PATH" run_with_timeout bash "$REPO25/bin/audit-tests.sh" 2>&1) || EXIT25=$?

if echo "$OUT25" | grep -q "feature-100-first.sh" && echo "$OUT25" | grep -q "feature-300-second.sh"; then
    pass "Case 25: multi-file — both qualifying files appear in candidate report"
else
    fail "Case 25: multi-file accumulation failed (output: $OUT25)"
fi

# Case 26: --format json with zero candidates → empty candidates array
STUB26=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB26" "open"
REPO26=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO26/tests/feature-200-open.sh"
git -C "$REPO26" add tests/feature-200-open.sh
backdate_commit "$REPO26" 200 "open issue"

EXIT26=0
OUT26=$(cd "$REPO26" && PATH="$STUB26:$PATH" run_with_timeout bash "$REPO26/bin/audit-tests.sh" --format json 2>&1) || EXIT26=$?

if echo "$OUT26" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit((Array.isArray(d.candidates)&&d.candidates.length===0)?0:1)' 2>/dev/null; then
    pass "Case 26: --format json with no candidates → empty candidates array"
else
    fail "Case 26: --format json empty-candidates shape wrong (output: $OUT26)"
fi

# Case 27: gh repo view fails → falls back to offline (WARNING on stderr, no candidates)
# Use a stub gh that always returns exit 1 (simulates broken gh auth)
STUB27=$(mktemp -d -p "$TMPDIR_BASE")
cat > "$STUB27/gh" <<'GHEOF'
#!/bin/bash
exit 1
GHEOF
chmod +x "$STUB27/gh"
REPO27=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO27/tests/feature-100-old.sh"
git -C "$REPO27" add tests/feature-100-old.sh
backdate_commit "$REPO27" 200 "stale"

EXIT27=0
OUT27=$(cd "$REPO27" && PATH="$STUB27:$PATH" run_with_timeout bash "$REPO27/bin/audit-tests.sh" 2>&1) || EXIT27=$?

if echo "$OUT27" | grep -qi "offline\|WARNING"; then
    pass "Case 27: gh repo view failure → falls back to offline mode with warning"
else
    fail "Case 27: expected offline fallback warning when gh fails (output: $OUT27)"
fi

if [[ $EXIT27 -eq 1 ]]; then
    pass "Case 27b: offline fallback exits 1 (no candidates)"
else
    fail "Case 27b: expected exit 1 for offline fallback, got $EXIT27"
fi

fi  # end [[ -f "$AUDIT_TESTS" ]]
