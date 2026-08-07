# Group I: injection safety — hostile `# Tests:` tokens and hostile filenames (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, security, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Both values flow from repository content into shell code that runs `git rm`:
# the `# Tests:` token (attacker-controlled by anyone who can land a test file)
# and the filename itself. An `eval`, an unquoted expansion, or a `$(...)` that
# reaches a subshell turns a nightly report-only cron into arbitrary execution.
# Two independent guarantees are asserted: nothing executes, and the JSON stays
# well-formed (an unescaped quote is how injected content escapes a consumer).

I_SENTINEL="$TMPDIR_BASE/i-sentinel"
mkdir -p "$I_SENTINEL"

I_REPO="$(make_repo)"
# Hostile header values. Each one, if any layer evaluates it, drops a file into
# $I_SENTINEL — a location no correct implementation ever writes to.
add_test_file "$I_REPO" "cc-inj-semicolon.sh" "bin/gone-i1.sh; touch $I_SENTINEL/semicolon"
add_test_file "$I_REPO" "cc-inj-backtick.sh"  "bin/gone-i2.sh \`touch $I_SENTINEL/backtick\`"
add_test_file "$I_REPO" "cc-inj-subshell.sh"  "\$(touch $I_SENTINEL/subshell)/bin/gone-i3.sh"
add_test_file "$I_REPO" "cc-inj-quote.sh"     "bin/gone-i4.sh\" ; touch $I_SENTINEL/quote ; echo \""
add_test_file "$I_REPO" "cc-inj-glob.sh"      "bin/*"
add_test_file "$I_REPO" "feature-941-inj.sh"  "bin/gone-i5.sh; touch $I_SENTINEL/issuescope" "TL2, scope:issue-specific"

# Hostile filenames. The injected commands use RELATIVE paths so they would land
# in whatever CWD the script happens to be in — the sweep below looks for them
# anywhere under $TMPDIR_BASE, which contains every fixture and the neutral CWD.
add_test_file "$I_REPO" 'cc-inj-$(touch pwned-subshell)-name.sh' "bin/gone-i6.sh"
add_test_file "$I_REPO" 'cc-inj-`touch pwned-backtick`-name.sh' "bin/gone-i7.sh"
add_test_file "$I_REPO" 'cc-inj-;semicolon.sh' "bin/gone-i8.sh"
add_test_file "$I_REPO" "cc-inj-'quoted'.sh" "bin/gone-i9.sh"
commit_repo "$I_REPO" "injection fixture"

I_STUB="$TMPDIR_BASE/i-stub"
install_gh_mock "$I_STUB"
export MOCK_ISSUES="941 open "

# ORDER MATTERS: the JSON-escaping checks (I2) run FIRST, while every hostile
# file is still on disk. Running --apply first would delete exactly the files
# whose names are supposed to be escaped, leaving the escaping code path
# unexercised and the assertions vacuously green.
I_HOSTILE_NAMES=(
    'cc-inj-$(touch pwned-subshell)-name.sh'
    'cc-inj-`touch pwned-backtick`-name.sh'
    'cc-inj-;semicolon.sh'
    "cc-inj-'quoted'.sh"
)

# ── I2: JSON stays well-formed AND the hostile names round-trip ─────────────
# Run against the intact fixture, on both scripts, before anything is removed.

# i_json_names <json> — every string value under any `file`/`dispatcher` key,
# newline-separated and sorted. Going through a real JSON parser is the point:
# an unescaped quote or backslash either breaks the parse (caught by
# json_parses) or truncates a value (caught by the exact name comparison).
i_json_names() {
    json_query "$1" '
        ((d.candidates||[]).concat(d.orphans||[],d.diagnostics||[]))
            .map(x => x.file || x.dispatcher || "")
            .filter(f => /^tests\//.test(f))
            .map(f => f.replace(/^tests\//, ""))
            .sort().join("\n")'
}

run_in_repo "$I_REPO" "$I_STUB" "$AUDIT_COMMON" --dry-run --format json
I2_JSON="$OUT"
if json_parses "$I2_JSON"; then
    pass "I2a common --format json survives quote/backtick/dollar content"
else
    fail "I2a hostile content corrupted the common JSON document (out=<<$I2_JSON>>)"
fi

run_in_repo "$I_REPO" "$I_STUB" "$AUDIT" --dry-run --format json
I2A_JSON="$OUT"
if json_parses "$I2A_JSON"; then
    pass "I2c audit-tests --format json survives hostile content"
else
    fail "I2c hostile content corrupted the audit-tests JSON document (out=<<$I2A_JSON>>)"
fi

# I2b — the four hostile filenames must come back out of the parser BYTE FOR
# BYTE. They are common-scope, so audit-tests-common.sh is the script that must
# emit them; a writer that drops the `$`, the backtick, the `;` or the quote
# fails this even when the document still parses.
I2_NAMES="$(i_json_names "$I2_JSON")"
I2_MISSING=""
for i_file in "${I_HOSTILE_NAMES[@]}"; do
    printf '%s\n' "$I2_NAMES" | grep -qxF "$i_file" || I2_MISSING="$I2_MISSING[$i_file]"
done
assert_eq "I2b every hostile filename round-trips through the common JSON intact" \
    "" "$I2_MISSING"

# I2d — the hostile `# Tests:` TOKEN values must round-trip too. The token is
# the other attacker-controlled string, and it reaches a different writer than
# the filename does.
I2_TOKENS="$(json_query "$I2_JSON" '
    ((d.orphans||[]).flatMap(o => (o.tests_paths||[]).concat(o.missing_paths||[])))
        .filter(t => /touch|bin\//.test(t)).length')"
if [[ -n "$I2_TOKENS" && "$I2_TOKENS" != "0" ]]; then
    pass "I2d hostile # Tests: tokens round-trip through the JSON (n=$I2_TOKENS)"
else
    fail "I2d hostile tokens did not survive JSON round-trip (got=<<$I2_TOKENS>> out=<<$I2_JSON>>)"
fi

# I2e — a report-only run must have deleted nothing, so the deletion assertions
# below still have their subjects. This also pins that --dry-run is honoured on
# a fixture engineered to tempt an eval.
assert_eq "I2e the report-only runs removed nothing" \
    "" "$(git -C "$I_REPO" status --porcelain)"

# ── I1: nothing executed (write path) ──────────────────────────────────────
# --apply is used on purpose: the write path is where the tokens reach `git rm`.

run_in_repo "$I_REPO" "$I_STUB" "$AUDIT" --apply --format text
I_A_OUT="$OUT"; I_A_RC="$RC"
run_in_repo "$I_REPO" "$I_STUB" "$AUDIT_COMMON" --apply --format text
I_C_OUT="$OUT"; I_C_RC="$RC"

I1_SENT="$(ls -A "$I_SENTINEL" 2>/dev/null | sort | tr '\n' ' ')"
assert_eq "I1a no injected command ran from a # Tests: token" "" "${I1_SENT% }"

I1_PWNED="$(find "$TMPDIR_BASE" -name 'pwned-*' 2>/dev/null | head -5 | tr '\n' ' ')"
assert_eq "I1b no injected command ran from a filename" "" "${I1_PWNED% }"

# I1c — the `bin/*` header must be treated as one literal token, not expanded
# against the working tree (expansion would silently mark it alive).
if echo "$I_C_OUT" | grep -qE "^(ORPHAN|MALFORMED_HEADER|NO_TESTS_HEADER): tests/cc-inj-glob\.sh"; then
    pass "I1c a glob-shaped token is classified, not shell-expanded"
else
    fail "I1c tests/cc-inj-glob.sh produced no verdict at all (out=<<$I_C_OUT>>)"
fi

# I1d — neither run may crash: a hostile token is a data condition, not an error.
if [[ "$I_A_RC" -eq 0 || "$I_A_RC" -eq 1 ]] && [[ "$I_C_RC" -eq 0 || "$I_C_RC" -eq 1 ]]; then
    pass "I1d both scripts complete normally on hostile input (rc=$I_A_RC/$I_C_RC)"
else
    fail "I1d hostile input broke a script (rc=$I_A_RC/$I_C_RC out=<<$I_A_OUT>> / <<$I_C_OUT>>)"
fi

# ── I3: hostile filenames are still handled correctly, not just safely ─────
# Safety alone could be achieved by skipping them; these files carry dead
# targets and no issue reference, so a correct implementation removes them.

for i_file in "${I_HOSTILE_NAMES[@]}"; do
    assert_eq "I3 hostile filename is removed intact by --apply: $i_file" \
        "gone" "$(fs_of "$I_REPO" "tests/$i_file")"
done

# I3b — and the sentinel is STILL clean after the deletions ran.
I3_SENT="$(ls -A "$I_SENTINEL" 2>/dev/null | sort | tr '\n' ' ')"
assert_eq "I3b the write path executed no injected command either" "" "${I3_SENT% }"

unset MOCK_ISSUES
