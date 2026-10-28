# Group Q: a test case reader that cannot run holds the file (#2502 S5-4b)
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# A test whose test case reader cannot run (rc 79: no runtime; any other failure: reader) is
# not read as malformed. trp_enumerate_cases sets TRP_READER_FAILED, trp_case_refcount_verdict
# answers undeterminable (file mode, refcount 1) instead of falling back to the header, and both
# audit scripts report SKIP_DELETE_READER_UNAVAILABLE and keep the file. Malformed markers and
# the bash path keep their behaviour. Uses this dispatcher's assert_eq / run_with_timeout.

if ! command -v node >/dev/null 2>&1; then
    skip "group-q: node not available"
    return 0
fi
# Repeats the parent's pin so the static isolation gate sees it in this file.
harness_isolate "$_ISOLATION_TMP_ROOT"
unset RH_RC CASE_EMBED_CACHE_DIR

# fx_checkout / has_line: the registry suite's helpers (one owner).
# shellcheck source=../test-language-registry/_lib.sh
. "$AGENTS_ROOT/tests/bin/test-language-registry/_lib.sh"

Q_BASE="$TMPDIR_BASE/q"
mkdir -p "$Q_BASE"

# The checkout runs the audit scripts; its pytest caseMarkerReader answers $RH_RC when set
# and delegates to the real reader otherwise.
Q_CO="$Q_BASE/co"
fx_checkout "$Q_CO"
for _f in audit-tests.sh audit-tests-common.sh; do cp "$AGENTS_ROOT/bin/$_f" "$Q_CO/bin/$_f"; done
unset _f
printf '%s\n' '' 'eval "_rh_real_$(declare -f pytest_case_markers)"' \
    'pytest_case_markers() {' \
    '  if [ -n "${RH_RC:-}" ]; then return "$RH_RC"; fi' \
    '  _rh_real_pytest_case_markers "$@"' \
    '}' >>"$Q_CO/bin/lib/test-language-parts/pytest.sh"

Q_PY=tests/bin/test_feature-9999-x.py
Q_SH=tests/bin/feature-9999-y.sh
# The samples' header lines, split so this file carries no header of its own.
Q_TESTS='# ''Tests: bin/gone.sh, bin/gone2.sh'
Q_TAGS='# ''Tags: TL2, scope:issue-specific'
Q_MB='case_''begin' Q_ME='case_''end'

# The fixture repo: every header target is gone, one case target (bin/a.sh) is still there.
Q_FR="$Q_BASE/fr"
harness_git_init "$Q_FR"
git -C "$Q_FR" config user.email t@example.com
git -C "$Q_FR" config user.name t
mkdir -p "$Q_FR/bin" "$Q_FR/tests/bin" "$Q_FR/tests/lib"
printf '#!/usr/bin/env bash\necho a\n' >"$Q_FR/bin/a.sh"
printf '%s\n' "$Q_TESTS" "$Q_TAGS" 'import pytest' '' '' \
    '@pytest.mark.target("bin/a.sh")' 'def test_alive():' '    assert True' '' '' \
    '@pytest.mark.target("bin/gone.sh")' 'def test_gone():' '    assert True' >"$Q_FR/$Q_PY"
printf '%s\n' '#!/usr/bin/env bash' "$Q_TESTS" "$Q_TAGS" \
    "$Q_MB \"alive\" \"bin/a.sh\"" 'echo alive' "$Q_ME" "$Q_MB \"gone\" \"bin/gone.sh\"" 'echo gone' "$Q_ME" >"$Q_FR/$Q_SH"
git -C "$Q_FR" add -A >/dev/null 2>&1
git -C "$Q_FR" commit -q -m fixture >/dev/null 2>&1

# q_fresh <name> — a new copy of the fixture repo (its .git included); prints its path.
q_fresh() {
    rm -rf "${Q_BASE:?}/$1"
    cp -R "$Q_FR" "$Q_BASE/$1"
    printf '%s' "$Q_BASE/$1"
}

# q_verdict <repo> <rel> <reader-rc|""> — trp_case_refcount_verdict through the checkout.
q_verdict() {
    run_with_timeout bash -c '. "$1/bin/lib/test-retire-predicate.sh" || exit 97
cd "$2" || exit 98
if [ -n "$4" ]; then export RH_RC="$4"; fi
trp_case_refcount_verdict "$2" "$3" >/dev/null
printf "VERDICT=%s MODE=%s REFCOUNT=%s READER_FAILED=%s\n" "$TRP_VERDICT" "$TRP_UNIT_MODE" "$TRP_REFCOUNT" "${TRP_READER_FAILED:-}"' _ "$Q_CO" "$@" 2>"$Q_BASE/verdict.err"
}

# q_audit <repo> <script> <reader-rc> <args...> — the checkout's audit script from <repo>.
# Sets Q_RC / Q_OUT.
q_audit() {
    local repo="$1" script="$2" rc="$3"
    shift 3
    Q_RC=0
    (
        cd "$repo" || exit 98
        export RH_RC="$rc"
        run_with_timeout bash "$Q_CO/bin/$script" "$@"
    ) >"$Q_BASE/au.out" 2>"$Q_BASE/au.err" || Q_RC=$?
    Q_OUT="$(cat "$Q_BASE/au.out")"
}

# q_kept <label> <path> — the file is still on disk.
q_kept() {
    if [[ -f "$2" ]]; then pass "$1"; else fail "$1 — deleted: $Q_OUT"; fi
}

case_begin "reader-rc79-is-undeterminable-unavailable" "bin/lib/test-retire-predicate.sh"
Q1="$(q_verdict "$Q_FR" "$Q_PY" 79)"
has_line "Q1 rc 79: undeterminable, file mode, refcount 1, unavailable" "$Q1" \
    "VERDICT=undeterminable MODE=file REFCOUNT=1 READER_FAILED=unavailable"
case_end

case_begin "reader-rc70-is-undeterminable-reader" "bin/lib/test-retire-predicate/case-parser.sh"
Q1="$(q_verdict "$Q_FR" "$Q_PY" 70)"
has_line "Q2 rc 70: undeterminable, file mode, refcount 1, reader" "$Q1" \
    "VERDICT=undeterminable MODE=file REFCOUNT=1 READER_FAILED=reader"
case_end

case_begin "audit-tests-holds-the-unreadable-file" "bin/audit-tests.sh"
Q_R="$(q_fresh au-79)"
q_audit "$Q_R" audit-tests.sh 79 --apply --offline --format text
has_line "Q3 audit-tests.sh --apply: hold line (unavailable)" "$Q_OUT" \
    "SKIP_DELETE_READER_UNAVAILABLE: $Q_PY (unavailable)"
q_kept "Q3 audit-tests.sh rc 79: the file stays" "$Q_R/$Q_PY"
Q_R="$(q_fresh au-70)"
q_audit "$Q_R" audit-tests.sh 70 --apply --offline --format text
has_line "Q3 audit-tests.sh --apply: hold line (reader)" "$Q_OUT" \
    "SKIP_DELETE_READER_UNAVAILABLE: $Q_PY (reader)"
q_kept "Q3 audit-tests.sh rc 70: the file stays" "$Q_R/$Q_PY"
Q_R="$(q_fresh au-json)"
q_audit "$Q_R" audit-tests.sh 79 --dry-run --offline --format json
case "$Q_OUT" in
    *"{\"file\":\"$Q_PY\",\"kind\":\"reader_unavailable\"}"*) pass "Q3 audit-tests.sh json: reader_unavailable diagnostic" ;;
    *) fail "Q3 audit-tests.sh json: reader_unavailable diagnostic — out=[$Q_OUT]" ;;
esac
case_end

case_begin "audit-tests-common-holds-the-unreadable-file" "bin/audit-tests-common.sh"
# A name without an issue number puts the same file in the common audit's scope.
Q_R="$(q_fresh common-79)"
git -C "$Q_R" mv "$Q_PY" tests/bin/test_x.py >/dev/null 2>&1
git -C "$Q_R" commit -q -m rename >/dev/null 2>&1
q_audit "$Q_R" audit-tests-common.sh 79 --apply --offline --format text
has_line "Q4 audit-tests-common.sh --apply: hold line (unavailable)" "$Q_OUT" \
    "SKIP_DELETE_READER_UNAVAILABLE: tests/bin/test_x.py (unavailable)"
q_kept "Q4 audit-tests-common.sh: the file stays" "$Q_R/tests/bin/test_x.py"
case_end

case_begin "reader-runs-malformed-stays-file-level" "bin/lib/test-retire-predicate.sh"
# Malformed markers were read: the header decides, as before (every header target is gone).
if command -v uv >/dev/null 2>&1; then
    Q_R="$(q_fresh malformed)"
    printf '%s\n' "$Q_TESTS" "$Q_TAGS" 'import pytest' '' '' \
        '@pytest.mark.target("bin/a.sh")' 'def test_alive():' '    assert True' '' '' \
        '@pytest.mark.target("bin/a.sh")' 'def test_alive():' '    assert True' >"$Q_R/$Q_PY"
    Q1="$(q_verdict "$Q_R" "$Q_PY" "")"
    has_line "Q5 malformed (duplicate name): orphan, file mode, no reader failure" "$Q1" \
        "VERDICT=orphan MODE=file REFCOUNT=0 READER_FAILED="
else
    skip "Q5 malformed pytest: uv not available"
fi
case_end

case_begin "reader-runs-conforming-stays-case-level" "bin/lib/test-retire-predicate.sh"
if command -v uv >/dev/null 2>&1; then
    Q1="$(q_verdict "$Q_FR" "$Q_PY" "")"
    has_line "Q6 conforming: partial-orphan in case mode" "$Q1" \
        "VERDICT=partial-orphan MODE=case REFCOUNT=1 READER_FAILED="
else
    skip "Q6 conforming pytest: uv not available"
fi
case_end

case_begin "bash-reader-never-fails" "bin/lib/test-retire-predicate/case-parser.sh"
# The bash reader is a same-shell function: the stub does not touch it, TRP_READER_FAILED stays empty.
Q1="$(q_verdict "$Q_FR" "$Q_SH" 79)"
has_line "Q7 bash: partial-orphan in case mode, no reader failure" "$Q1" \
    "VERDICT=partial-orphan MODE=case REFCOUNT=1 READER_FAILED="
case_end

unset Q_BASE Q_CO Q_PY Q_SH Q_TESTS Q_TAGS Q_MB Q_ME Q_FR Q_R Q1 Q_RC Q_OUT
