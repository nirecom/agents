# Group C: audit-tests.sh core filtering logic (Cases 6-16)
# Sourced by tests/feature-test-cleanup-944.sh

if [[ ! -f "$AUDIT_TESTS" ]]; then
    skip "Cases 6-16: bin/audit-tests.sh does not exist yet"
else

# Case 6: CLOSED + >3 months old + feature-NNN- → candidate report
STUB6=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB6" "closed"
REPO6=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO6/tests/feature-100-old.sh"
git -C "$REPO6" add tests/feature-100-old.sh
backdate_commit "$REPO6" 200 "stale test"

EXIT6=0
OUT6=$(cd "$REPO6" && PATH="$STUB6:$PATH" run_with_timeout bash "$REPO6/bin/audit-tests.sh" 2>&1) || EXIT6=$?

if echo "$OUT6" | grep -q "feature-100-old.sh"; then
    pass "Case 6: stale CLOSED feature-NNN- file appears in candidate report"
else
    fail "Case 6: stale CLOSED feature-NNN- file missing from report (output: $OUT6)"
fi

if [[ $EXIT6 -eq 0 ]]; then
    pass "Case 15a: exit 0 when candidates found"
else
    fail "Case 15a: expected exit 0 with candidates, got $EXIT6"
fi

# Case 7: OPEN issue → not a candidate
STUB7=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB7" "open"
REPO7=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO7/tests/feature-200-open.sh"
git -C "$REPO7" add tests/feature-200-open.sh
backdate_commit "$REPO7" 200 "open issue test"

EXIT7=0
OUT7=$(cd "$REPO7" && PATH="$STUB7:$PATH" run_with_timeout bash "$REPO7/bin/audit-tests.sh" 2>&1) || EXIT7=$?

if echo "$OUT7" | grep -q "feature-200-open.sh"; then
    fail "Case 7: OPEN issue file should not be a candidate but was reported"
else
    pass "Case 7: OPEN issue file not in candidate report"
fi

if [[ $EXIT7 -eq 1 ]]; then
    pass "Case 15b: exit 1 when no candidates found"
else
    fail "Case 15b: expected exit 1 with no candidates, got $EXIT7"
fi

# Case 8: CLOSED but fresh (<3 months) → not a candidate
STUB8=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB8" "closed"
REPO8=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO8/tests/feature-100-fresh.sh"
git -C "$REPO8" add tests/feature-100-fresh.sh
backdate_commit "$REPO8" 30 "fresh test"

EXIT8=0
OUT8=$(cd "$REPO8" && PATH="$STUB8:$PATH" run_with_timeout bash "$REPO8/bin/audit-tests.sh" 2>&1) || EXIT8=$?

if echo "$OUT8" | grep -q "feature-100-fresh.sh"; then
    fail "Case 8: fresh CLOSED file (<3mo) should not be candidate but was reported"
else
    pass "Case 8: fresh CLOSED file (<3mo) not in candidate report"
fi

# Case 9: --offline → no candidates (conservative)
STUB9=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB9" "closed"
REPO9=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO9/tests/feature-100-old.sh"
git -C "$REPO9" add tests/feature-100-old.sh
backdate_commit "$REPO9" 200 "stale"

EXIT9=0
OUT9=$(cd "$REPO9" && PATH="$STUB9:$PATH" run_with_timeout bash "$REPO9/bin/audit-tests.sh" --offline 2>&1) || EXIT9=$?

if echo "$OUT9" | grep -q "feature-100-old.sh"; then
    fail "Case 9: --offline should yield no candidates but reported file"
else
    pass "Case 9: --offline yields no candidates (conservative)"
fi

if [[ $EXIT9 -eq 1 ]]; then
    pass "Case 9b: --offline exits 1 (no candidates)"
else
    fail "Case 9b: --offline expected exit 1, got $EXIT9"
fi

# Case 10: uppercase CLOSED normalized → detected
STUB10=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB10" "CLOSED"
REPO10=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO10/tests/feature-400-upper.sh"
git -C "$REPO10" add tests/feature-400-upper.sh
backdate_commit "$REPO10" 200 "stale upper"

EXIT10=0
OUT10=$(cd "$REPO10" && PATH="$STUB10:$PATH" run_with_timeout bash "$REPO10/bin/audit-tests.sh" 2>&1) || EXIT10=$?

if echo "$OUT10" | grep -q "feature-400-upper.sh"; then
    pass "Case 10: uppercase CLOSED is normalized and detected"
else
    fail "Case 10: uppercase CLOSED not normalized (output: $OUT10)"
fi

# Case 11: stale dispatcher + fresh sibling → MAX recent → not candidate
STUB11=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB11" "closed"
REPO11=$(setup_audit_repo)
mkdir -p "$REPO11/tests/feature-100-mixed"
echo "#!/bin/bash" > "$REPO11/tests/feature-100-mixed.sh"
git -C "$REPO11" add tests/feature-100-mixed.sh
backdate_commit "$REPO11" 200 "stale dispatcher"
echo "helper" > "$REPO11/tests/feature-100-mixed/helper.sh"
git -C "$REPO11" add tests/feature-100-mixed/helper.sh
backdate_commit "$REPO11" 10 "fresh sibling"

EXIT11=0
OUT11=$(cd "$REPO11" && PATH="$STUB11:$PATH" run_with_timeout bash "$REPO11/bin/audit-tests.sh" 2>&1) || EXIT11=$?

if echo "$OUT11" | grep -q "feature-100-mixed.sh"; then
    fail "Case 11: stale dispatcher with fresh sibling should NOT be candidate (MAX recent)"
else
    pass "Case 11: MAX(dispatcher, sibling) = fresh → not candidate"
fi

# Case 12: sibling folder exists → report includes sibling path + file count
STUB12=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB12" "closed"
REPO12=$(setup_audit_repo)
mkdir -p "$REPO12/tests/feature-100-sibs"
echo "#!/bin/bash" > "$REPO12/tests/feature-100-sibs.sh"
echo "a" > "$REPO12/tests/feature-100-sibs/a.sh"
echo "b" > "$REPO12/tests/feature-100-sibs/b.sh"
git -C "$REPO12" add -A
backdate_commit "$REPO12" 200 "all stale"

EXIT12=0
OUT12=$(cd "$REPO12" && PATH="$STUB12:$PATH" run_with_timeout bash "$REPO12/bin/audit-tests.sh" 2>&1) || EXIT12=$?

if echo "$OUT12" | grep -qE "feature-100-sibs(/|.*sibling)"; then
    pass "Case 12: sibling folder path reported"
else
    fail "Case 12: sibling folder path missing from report (output: $OUT12)"
fi

if echo "$OUT12" | grep -qE "[^0-9]2[^0-9]|count.*2|2 files"; then
    pass "Case 12b: sibling file count (2) reported"
else
    fail "Case 12b: sibling file count missing from report"
fi

# Case 13: no sibling folder → dispatcher only
STUB13=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB13" "closed"
REPO13=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO13/tests/feature-100-lone.sh"
git -C "$REPO13" add tests/feature-100-lone.sh
backdate_commit "$REPO13" 200 "lone stale"

EXIT13=0
OUT13=$(cd "$REPO13" && PATH="$STUB13:$PATH" run_with_timeout bash "$REPO13/bin/audit-tests.sh" 2>&1) || EXIT13=$?

if echo "$OUT13" | grep -q "feature-100-lone.sh"; then
    pass "Case 13: lone dispatcher reported"
else
    fail "Case 13: lone dispatcher missing from report"
fi

# Case 14: non-matching pattern (fix-123-*) → excluded from scope
STUB14=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB14" "closed"
REPO14=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO14/tests/fix-123-other.sh"
git -C "$REPO14" add tests/fix-123-other.sh
backdate_commit "$REPO14" 200 "non-feature"

EXIT14=0
OUT14=$(cd "$REPO14" && PATH="$STUB14:$PATH" run_with_timeout bash "$REPO14/bin/audit-tests.sh" 2>&1) || EXIT14=$?

if echo "$OUT14" | grep -q "fix-123-other.sh"; then
    fail "Case 14: fix-123-* pattern should be out of scope"
else
    pass "Case 14: non feature-NNN- pattern excluded"
fi

# Case 15c: exit 2 on error (not a git repo)
TMP_NOGIT=$(mktemp -d -p "$TMPDIR_BASE")
cp "$AUDIT_TESTS" "$TMP_NOGIT/audit-tests.sh"
chmod +x "$TMP_NOGIT/audit-tests.sh"
mkdir -p "$TMP_NOGIT/tests"

EXIT15c=0
(cd "$TMP_NOGIT" && run_with_timeout bash "$TMP_NOGIT/audit-tests.sh" 2>&1) || EXIT15c=$?

if [[ $EXIT15c -eq 2 ]] || [[ $EXIT15c -eq 1 ]]; then
    pass "Case 15c: error path returns non-zero ($EXIT15c) on non-git repo"
else
    fail "Case 15c: expected exit 2 (or 1) on error, got $EXIT15c"
fi

# Case 15d: valid git repo without tests/ dir → exit 2
REPO_NOTESTS=$(make_repo)
TMP_AUDIT="$REPO_NOTESTS/audit-tests.sh"
cp "$AUDIT_TESTS" "$TMP_AUDIT"
chmod +x "$TMP_AUDIT"

EXIT15d=0
(cd "$REPO_NOTESTS" && run_with_timeout bash "$TMP_AUDIT" 2>&1) || EXIT15d=$?

if [[ $EXIT15d -eq 2 ]]; then
    pass "Case 15d: valid git repo without tests/ dir exits 2"
else
    fail "Case 15d: expected exit 2 without tests/ dir, got $EXIT15d"
fi

# Case 15e: valid git repo with empty tests/ dir → exit 1 (no candidates)
REPO_EMPTY=$(setup_audit_repo)
STUB15e=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB15e" "closed"

EXIT15e=0
OUT15e=$(cd "$REPO_EMPTY" && PATH="$STUB15e:$PATH" run_with_timeout bash "$REPO_EMPTY/bin/audit-tests.sh" 2>&1) || EXIT15e=$?

if [[ $EXIT15e -eq 1 ]]; then
    pass "Case 15e: empty tests/ dir exits 1 (no candidates)"
else
    fail "Case 15e: expected exit 1 for empty tests/, got $EXIT15e (output: $OUT15e)"
fi

# Case 16: idempotency — same input → same output
STUB16=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB16" "closed"
REPO16=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO16/tests/feature-100-idem.sh"
git -C "$REPO16" add tests/feature-100-idem.sh
backdate_commit "$REPO16" 200 "stale"

OUT16a=$(cd "$REPO16" && PATH="$STUB16:$PATH" run_with_timeout bash "$REPO16/bin/audit-tests.sh" 2>&1 || true)
OUT16b=$(cd "$REPO16" && PATH="$STUB16:$PATH" run_with_timeout bash "$REPO16/bin/audit-tests.sh" 2>&1 || true)

if [[ "$OUT16a" == "$OUT16b" ]]; then
    pass "Case 16: idempotent — two runs produce identical output"
else
    fail "Case 16: non-idempotent — outputs differ"
fi

# Case 28: feature-1x2-bad.sh (non-purely-numeric ID) → excluded by regex
STUB28=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB28" "closed"
REPO28=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO28/tests/feature-1x2-bad.sh"
git -C "$REPO28" add tests/feature-1x2-bad.sh
backdate_commit "$REPO28" 200 "non-numeric id"

EXIT28=0
OUT28=$(cd "$REPO28" && PATH="$STUB28:$PATH" run_with_timeout bash "$REPO28/bin/audit-tests.sh" 2>&1) || EXIT28=$?

if echo "$OUT28" | grep -q "feature-1x2-bad.sh"; then
    fail "Case 28: feature-NNN- requires purely numeric ID — alphanumeric should be excluded"
else
    pass "Case 28: non-numeric ID (1x2) excluded by regex boundary"
fi

fi  # end [[ -f "$AUDIT_TESTS" ]]
