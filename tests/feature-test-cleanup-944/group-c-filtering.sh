# Group C: audit-tests.sh core filtering logic (Cases 6-16)
# Tests: bin/audit-tests.sh
# Tags: audit-tests, filtering, survival, scope:issue-specific, TL2
# Sourced by tests/feature-test-cleanup-944.sh
#
# Revised for #1833. The primary filter is TARGET SURVIVAL, so every fixture
# now carries a real `# Tests:` header: a dead one (bin/gone.sh, never existed)
# to make the file a candidate, or a live one to make it a non-candidate.
# A header-less file is neither — it is undecidable and only diagnosed.
# Issue state (open / closed / freshness / offline) no longer decides candidacy;
# it decides only whether a candidate may be deleted.

if [[ ! -f "$AUDIT_TESTS" ]]; then
    skip "Cases 6-16: bin/audit-tests.sh does not exist yet"
else

# dead_dispatcher <repo> <name> — a file whose only target never existed.
dead_dispatcher() {
    {
        echo "#!/bin/bash"
        echo "# Tests: bin/gone.sh"
        echo "# Tags: TL2, scope:issue-specific"
    } > "$1/tests/$2"
}

# live_dispatcher <repo> <name> — a file whose target is present on disk.
live_dispatcher() {
    mkdir -p "$1/bin"
    echo "#!/bin/bash" > "$1/bin/alive.sh"
    {
        echo "#!/bin/bash"
        echo "# Tests: bin/alive.sh"
        echo "# Tags: TL2, scope:issue-specific"
    } > "$1/tests/$2"
}

# Case 6: dead target + CLOSED stale issue → candidate report
STUB6=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB6" "closed"
REPO6=$(setup_audit_repo)
dead_dispatcher "$REPO6" "feature-100-old.sh"
git -C "$REPO6" add tests/feature-100-old.sh
backdate_commit "$REPO6" 200 "stale test"

EXIT6=0
OUT6=$(cd "$REPO6" && PATH="$STUB6:$PATH" run_with_timeout bash "$REPO6/bin/audit-tests.sh" --dry-run 2>&1) || EXIT6=$?

if echo "$OUT6" | grep -q "feature-100-old.sh"; then
    pass "Case 6: dead-target feature-NNN- file appears in candidate report"
else
    fail "Case 6: dead-target feature-NNN- file missing from report (output: $OUT6)"
fi

if [[ $EXIT6 -eq 0 ]]; then
    pass "Case 15a: exit 0 when candidates found"
else
    fail "Case 15a: expected exit 0 with candidates, got $EXIT6"
fi

# Case 7: OPEN issue no longer suppresses the report — it only holds deletion.
# This is the #1833 false negative: work moved on, the test's target is gone,
# but the issue stayed open and the sweep stayed silent.
STUB7=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB7" "open"
REPO7=$(setup_audit_repo)
dead_dispatcher "$REPO7" "feature-200-open.sh"
git -C "$REPO7" add tests/feature-200-open.sh
backdate_commit "$REPO7" 200 "open issue test"

EXIT7=0
OUT7=$(cd "$REPO7" && PATH="$STUB7:$PATH" run_with_timeout bash "$REPO7/bin/audit-tests.sh" 2>&1) || EXIT7=$?

if echo "$OUT7" | grep -q "CANDIDATE: tests/feature-200-open.sh"; then
    pass "Case 7: dead target with an OPEN issue is still reported"
else
    fail "Case 7: dead target with an OPEN issue must be reported (output: $OUT7)"
fi

if echo "$OUT7" | grep -q "SKIP_DELETE_ISSUE_ACTIVE" && [[ -f "$REPO7/tests/feature-200-open.sh" ]]; then
    pass "Case 7b: the OPEN issue holds the deletion (SKIP_DELETE_ISSUE_ACTIVE)"
else
    fail "Case 7b: expected SKIP_DELETE_ISSUE_ACTIVE and survival (output: $OUT7)"
fi

# Case 15b: exit 1 when nothing survives-check as a candidate. A live target is
# now the only way to have no candidates.
STUB15b=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB15b" "closed"
REPO15b=$(setup_audit_repo)
live_dispatcher "$REPO15b" "feature-100-live.sh"
git -C "$REPO15b" add -A
backdate_commit "$REPO15b" 200 "live target"

EXIT15b=0
OUT15b=$(cd "$REPO15b" && PATH="$STUB15b:$PATH" run_with_timeout bash "$REPO15b/bin/audit-tests.sh" --dry-run 2>&1) || EXIT15b=$?

if [[ $EXIT15b -eq 1 ]] && ! echo "$OUT15b" | grep -q "CANDIDATE:"; then
    pass "Case 15b: exit 1 when no candidates found"
else
    fail "Case 15b: expected exit 1 with no candidates, got $EXIT15b (output: $OUT15b)"
fi

# Case 8: CLOSED but fresh (<3 months) — reported, deletion held.
STUB8=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB8" "closed" "$(days_ago_iso 30)"
REPO8=$(setup_audit_repo)
dead_dispatcher "$REPO8" "feature-100-fresh.sh"
git -C "$REPO8" add tests/feature-100-fresh.sh
backdate_commit "$REPO8" 30 "fresh test"

EXIT8=0
OUT8=$(cd "$REPO8" && PATH="$STUB8:$PATH" run_with_timeout bash "$REPO8/bin/audit-tests.sh" 2>&1) || EXIT8=$?

if echo "$OUT8" | grep -q "CANDIDATE: tests/feature-100-fresh.sh"; then
    pass "Case 8: fresh CLOSED issue does not suppress the candidate report"
else
    fail "Case 8: fresh CLOSED dead-target file must still be reported (output: $OUT8)"
fi

if [[ -f "$REPO8/tests/feature-100-fresh.sh" ]] && echo "$OUT8" | grep -q "SKIP_DELETE_ISSUE_ACTIVE"; then
    pass "Case 8b: a freshly-closed issue holds the deletion"
else
    fail "Case 8b: expected the fresh close to hold the deletion (output: $OUT8)"
fi

# Case 9: --offline — survival is judged locally, so candidates ARE reported;
# only the delete gate needs the network, and without it nothing is deleted.
STUB9=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB9" "closed"
REPO9=$(setup_audit_repo)
dead_dispatcher "$REPO9" "feature-100-old.sh"
git -C "$REPO9" add tests/feature-100-old.sh
backdate_commit "$REPO9" 200 "stale"

EXIT9=0
OUT9=$(cd "$REPO9" && PATH="$STUB9:$PATH" run_with_timeout bash "$REPO9/bin/audit-tests.sh" --offline 2>&1) || EXIT9=$?

if echo "$OUT9" | grep -q "CANDIDATE: tests/feature-100-old.sh"; then
    pass "Case 9: --offline still reports survival candidates"
else
    fail "Case 9: --offline must still report survival candidates (output: $OUT9)"
fi

if [[ $EXIT9 -eq 0 ]]; then
    pass "Case 9b: --offline exits 0 (candidates present)"
else
    fail "Case 9b: --offline expected exit 0, got $EXIT9"
fi

if [[ -f "$REPO9/tests/feature-100-old.sh" ]] && echo "$OUT9" | grep -q "SKIP_DELETE_METADATA_UNAVAILABLE"; then
    pass "Case 9c: --offline never deletes (metadata unavailable)"
else
    fail "Case 9c: --offline must hold every deletion (output: $OUT9)"
fi

# Case 10: uppercase CLOSED is normalized — now observable at the delete gate.
STUB10=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB10" "CLOSED"
REPO10=$(setup_audit_repo)
dead_dispatcher "$REPO10" "feature-400-upper.sh"
git -C "$REPO10" add tests/feature-400-upper.sh
backdate_commit "$REPO10" 200 "stale upper"

EXIT10=0
OUT10=$(cd "$REPO10" && PATH="$STUB10:$PATH" run_with_timeout bash "$REPO10/bin/audit-tests.sh" 2>&1) || EXIT10=$?

if echo "$OUT10" | grep -q "DELETED: tests/feature-400-upper.sh"; then
    pass "Case 10: uppercase CLOSED is normalized and authorises the deletion"
else
    fail "Case 10: uppercase CLOSED not normalized at the delete gate (output: $OUT10)"
fi

# Case 11: RETIRED (number retired in place — do not reuse).
# Asserted the pre-#1557 contract that candidacy was gated on
# MAX(dispatcher_commit_date, sibling_commit_date). #1557 moved the filter to
# `state == closed && closed_at < CUTOFF`, and #1833 moved it again to target
# survival — `max_date` is reporting-only in both. Replacement:
# tests/fix-1557-audit-tests-closed-at.sh TC8 (a recent last-commit does not
# prevent candidacy).

# Case 12: sibling folder exists → report includes sibling path + file count
STUB12=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB12" "closed"
REPO12=$(setup_audit_repo)
mkdir -p "$REPO12/tests/feature-100-sibs"
dead_dispatcher "$REPO12" "feature-100-sibs.sh"
echo "a" > "$REPO12/tests/feature-100-sibs/a.sh"
echo "b" > "$REPO12/tests/feature-100-sibs/b.sh"
git -C "$REPO12" add -A
backdate_commit "$REPO12" 200 "all stale"

EXIT12=0
OUT12=$(cd "$REPO12" && PATH="$STUB12:$PATH" run_with_timeout bash "$REPO12/bin/audit-tests.sh" --dry-run 2>&1) || EXIT12=$?

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
dead_dispatcher "$REPO13" "feature-100-lone.sh"
git -C "$REPO13" add tests/feature-100-lone.sh
backdate_commit "$REPO13" 200 "lone stale"

EXIT13=0
OUT13=$(cd "$REPO13" && PATH="$STUB13:$PATH" run_with_timeout bash "$REPO13/bin/audit-tests.sh" --dry-run 2>&1) || EXIT13=$?

if echo "$OUT13" | grep -q "feature-100-lone.sh"; then
    pass "Case 13: lone dispatcher reported"
else
    fail "Case 13: lone dispatcher missing from report"
fi

# Case 14: non-matching pattern (fix-123-*) → out of this script's scope even
# though its target is dead; audit-tests-common.sh owns it.
STUB14=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB14" "closed"
REPO14=$(setup_audit_repo)
dead_dispatcher "$REPO14" "fix-123-other.sh"
git -C "$REPO14" add tests/fix-123-other.sh
backdate_commit "$REPO14" 200 "non-feature"

EXIT14=0
OUT14=$(cd "$REPO14" && PATH="$STUB14:$PATH" run_with_timeout bash "$REPO14/bin/audit-tests.sh" --dry-run 2>&1) || EXIT14=$?

if echo "$OUT14" | grep -q "fix-123-other.sh"; then
    fail "Case 14: fix-123-* pattern should be out of scope"
else
    pass "Case 14: non feature-NNN- pattern excluded"
fi

# Case 15c: exit 2 on error (not a git repo)
TMP_NOGIT=$(mktemp -d -p "$TMPDIR_BASE")
cp "$AUDIT_TESTS" "$TMP_NOGIT/audit-tests.sh"
chmod +x "$TMP_NOGIT/audit-tests.sh"
install_audit_libs "$TMP_NOGIT"
mkdir -p "$TMP_NOGIT/tests"

EXIT15c=0
(cd "$TMP_NOGIT" && run_with_timeout bash "$TMP_NOGIT/audit-tests.sh" --dry-run 2>&1) || EXIT15c=$?

if [[ $EXIT15c -eq 2 ]]; then
    pass "Case 15c: non-git repo fails closed with exit 2"
else
    fail "Case 15c: expected exit 2 on a non-git repo, got $EXIT15c"
fi

# Case 15d: valid git repo without tests/ dir → exit 2
REPO_NOTESTS=$(make_repo)
TMP_AUDIT="$REPO_NOTESTS/audit-tests.sh"
cp "$AUDIT_TESTS" "$TMP_AUDIT"
chmod +x "$TMP_AUDIT"
install_audit_libs "$REPO_NOTESTS"

EXIT15d=0
(cd "$REPO_NOTESTS" && run_with_timeout bash "$TMP_AUDIT" --dry-run 2>&1) || EXIT15d=$?

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
OUT15e=$(cd "$REPO_EMPTY" && PATH="$STUB15e:$PATH" run_with_timeout bash "$REPO_EMPTY/bin/audit-tests.sh" --dry-run 2>&1) || EXIT15e=$?

if [[ $EXIT15e -eq 1 ]]; then
    pass "Case 15e: empty tests/ dir exits 1 (no candidates)"
else
    fail "Case 15e: expected exit 1 for empty tests/, got $EXIT15e (output: $OUT15e)"
fi

# Case 16: idempotency — same input → same output
STUB16=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB16" "closed"
REPO16=$(setup_audit_repo)
dead_dispatcher "$REPO16" "feature-100-idem.sh"
git -C "$REPO16" add tests/feature-100-idem.sh
backdate_commit "$REPO16" 200 "stale"

OUT16a=$(cd "$REPO16" && PATH="$STUB16:$PATH" run_with_timeout bash "$REPO16/bin/audit-tests.sh" --dry-run 2>&1 || true)
OUT16b=$(cd "$REPO16" && PATH="$STUB16:$PATH" run_with_timeout bash "$REPO16/bin/audit-tests.sh" --dry-run 2>&1 || true)

if [[ "$OUT16a" == "$OUT16b" ]]; then
    pass "Case 16: idempotent — two runs produce identical output"
else
    fail "Case 16: non-idempotent — outputs differ"
fi

# Case 16b: a header-less file is undecidable — never a candidate, but named on
# the diagnostics channel so it cannot rot unnoticed.
STUB16b=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB16b" "closed"
REPO16b=$(setup_audit_repo)
echo "#!/bin/bash" > "$REPO16b/tests/feature-100-nohdr.sh"
git -C "$REPO16b" add tests/feature-100-nohdr.sh
backdate_commit "$REPO16b" 200 "no header"

OUT16c=$(cd "$REPO16b" && PATH="$STUB16b:$PATH" run_with_timeout bash "$REPO16b/bin/audit-tests.sh" --dry-run 2>&1 || true)

if ! echo "$OUT16c" | grep -q "CANDIDATE: tests/feature-100-nohdr.sh"; then
    pass "Case 16b: a header-less file is never a candidate"
else
    fail "Case 16b: a header-less file must not be a candidate (output: $OUT16c)"
fi
if echo "$OUT16c" | grep -q "NO_TESTS_HEADER: tests/feature-100-nohdr.sh"; then
    pass "Case 16c: a header-less file is reported as NO_TESTS_HEADER"
else
    fail "Case 16c: expected NO_TESTS_HEADER for the header-less file (output: $OUT16c)"
fi

# Case 28: feature-1x2-bad.sh (non-purely-numeric ID) → excluded by regex
STUB28=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB28" "closed"
REPO28=$(setup_audit_repo)
dead_dispatcher "$REPO28" "feature-1x2-bad.sh"
git -C "$REPO28" add tests/feature-1x2-bad.sh
backdate_commit "$REPO28" 200 "non-numeric id"

EXIT28=0
OUT28=$(cd "$REPO28" && PATH="$STUB28:$PATH" run_with_timeout bash "$REPO28/bin/audit-tests.sh" --dry-run 2>&1) || EXIT28=$?

if echo "$OUT28" | grep -q "feature-1x2-bad.sh"; then
    fail "Case 28: feature-NNN- requires purely numeric ID — alphanumeric should be excluded"
else
    pass "Case 28: non-numeric ID (1x2) excluded by regex boundary"
fi

fi  # end [[ -f "$AUDIT_TESTS" ]]
