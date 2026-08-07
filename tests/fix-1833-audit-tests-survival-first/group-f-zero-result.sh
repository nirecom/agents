# Group F: the zero-result path — exit code, empty JSON collections, SKILL wording (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, skills/sweep-tests/SKILL.md
# Tags: TL2, audit-tests, retire, zero-result, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# The whole point of #1833 is that the healthy steady state is "nothing to
# retire". That state is therefore the most-executed path in production and the
# one most likely to regress unnoticed: an empty candidate array must still be
# valid JSON, the exit code must stay 1 (= no findings, NOT an error), and the
# /sweep-tests prompt must tell the reader how to read a 0-line report.

# ── F1: every target alive — findings and diagnostics are both empty ────────

F_REPO="$(make_repo)"
add_src "$F_REPO" "bin/alive-f1.sh"
add_src "$F_REPO" "bin/alive-f2.sh"
add_test_file "$F_REPO" "feature-901-alive.sh" "bin/alive-f1.sh" "TL2, scope:issue-specific"
add_test_file "$F_REPO" "cc-alive-f.sh" "bin/alive-f2.sh"
commit_repo "$F_REPO" "zero-result fixture (everything alive)"

F_STUB="$TMPDIR_BASE/f-stub"
install_gh_mock "$F_STUB"
export MOCK_ISSUES="901 closed 2019-01-01T00:00:00Z"

run_in_repo "$F_REPO" "$F_STUB" "$AUDIT" --dry-run --format text
F1_OUT="$OUT"; F1_RC="$RC"
assert_eq "F1a audit-tests text: zero candidates exits 1 (no findings, not an error)" \
    "1" "$F1_RC"
assert_eq "F1b audit-tests text: no CANDIDATE line is printed" \
    "0" "$(count_lines "$F1_OUT" CANDIDATE)"
assert_eq "F1c audit-tests text: no diagnostic line is printed either" \
    "0" "$(( $(count_lines "$F1_OUT" MALFORMED_HEADER) + $(count_lines "$F1_OUT" NO_TESTS_HEADER) ))"

run_in_repo "$F_REPO" "$F_STUB" "$AUDIT" --dry-run --format json
F1_JSON="$OUT"; F1_JSON_RC="$RC"
if json_parses "$F1_JSON"; then
    pass "F1d audit-tests --format json parses when there is nothing to report"
else
    fail "F1d zero-result JSON does not parse (rc=$F1_JSON_RC out=<<$F1_JSON>> err=<<$ERR>>)"
fi
assert_eq "F1e audit-tests zero-result JSON: candidates is an empty array" \
    "array:0" "$(json_query "$F1_JSON" '(Array.isArray(d.candidates)?"array":typeof d.candidates)+":"+((d.candidates||[]).length)')"
assert_eq "F1f audit-tests zero-result JSON: diagnostics is an empty array (present, not omitted)" \
    "array:0" "$(json_query "$F1_JSON" '(Array.isArray(d.diagnostics)?"array":typeof d.diagnostics)+":"+((d.diagnostics||[]).length)')"
assert_eq "F1g audit-tests --format json keeps exit 1 on zero results" "1" "$F1_JSON_RC"

run_in_repo "$F_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
F1C_OUT="$OUT"; F1C_RC="$RC"
assert_eq "F1h audit-tests-common text: zero orphans exits 1" "1" "$F1C_RC"
assert_eq "F1i audit-tests-common text: no ORPHAN line is printed" \
    "0" "$(count_lines "$F1C_OUT" ORPHAN)"

run_in_repo "$F_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format json
F1CJ="$OUT"; F1CJ_RC="$RC"
if json_parses "$F1CJ"; then
    pass "F1j audit-tests-common --format json parses when there is nothing to report"
else
    fail "F1j common zero-result JSON does not parse (rc=$F1CJ_RC out=<<$F1CJ>> err=<<$ERR>>)"
fi
assert_eq "F1k audit-tests-common zero-result JSON: orphans is an empty array" \
    "array:0" "$(json_query "$F1CJ" '(Array.isArray(d.orphans)?"array":typeof d.orphans)+":"+((d.orphans||[]).length)')"
assert_eq "F1l audit-tests-common zero-result JSON: diagnostics is an empty array" \
    "array:0" "$(json_query "$F1CJ" '(Array.isArray(d.diagnostics)?"array":typeof d.diagnostics)+":"+((d.diagnostics||[]).length)')"
assert_eq "F1m audit-tests-common --format json keeps exit 1 on zero results" "1" "$F1CJ_RC"

# ── F2: nothing to scan at all — tests/ exists but is empty ─────────────────
# Distinct from F1: there the loop ran and found nothing, here the glob matches
# nothing. `shopt -s nullglob` + an unbound-array reference is the classic way
# this path dies under `set -u`, so it needs its own case.

F2_REPO="$(make_repo)"
commit_repo "$F2_REPO" "empty tests/ fixture"

run_in_repo "$F2_REPO" "-" "$AUDIT" --dry-run --offline --format json
F2_JSON="$OUT"; F2_RC="$RC"; F2_ERR="$ERR"
if json_parses "$F2_JSON" && [[ "$F2_RC" -eq 1 ]]; then
    pass "F2a audit-tests on an empty tests/ exits 1 with parseable JSON"
else
    fail "F2a empty tests/ must exit 1 with parseable JSON (rc=$F2_RC out=<<$F2_JSON>> err=<<$F2_ERR>>)"
fi
if echo "$F2_ERR" | grep -qiE "unbound variable|syntax error"; then
    fail "F2b empty tests/ tripped a shell error (err=<<$F2_ERR>>)"
else
    pass "F2b empty tests/ produces no shell error on stderr"
fi

run_in_repo "$F2_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format json
F2C_JSON="$OUT"; F2C_RC="$RC"; F2C_ERR="$ERR"
if json_parses "$F2C_JSON" && [[ "$F2C_RC" -eq 1 ]]; then
    pass "F2c audit-tests-common on an empty tests/ exits 1 with parseable JSON"
else
    fail "F2c empty tests/ must exit 1 with parseable JSON (rc=$F2C_RC out=<<$F2C_JSON>> err=<<$F2C_ERR>>)"
fi
if echo "$F2C_ERR" | grep -qiE "unbound variable|syntax error"; then
    fail "F2d empty tests/ tripped a shell error in the common script (err=<<$F2C_ERR>>)"
else
    pass "F2d empty tests/ produces no shell error on stderr (common)"
fi

# ── F3: /sweep-tests must teach the reader how to read a 0-line report ──────
# Doc-content assertions against the WORKTREE copy (LOCAL_SKILL_MD), not the
# deployed $HOME/.claude/ copy — the change under test lives here.

if [[ -f "$LOCAL_SKILL_MD" ]]; then
    F3_SKILL="$(cat "$LOCAL_SKILL_MD")"

    # F3a — the zero-result reading rule. Merely finding the token
    # MALFORMED_HEADER somewhere in the file proves nothing: it already appears
    # in the STE-1/STE-2 vocabulary, so that check is green before the fix
    # lands. What has to be present is ONE line that carries the whole
    # interpretation — "0 CANDIDATE/ORPHAN lines" AND "MALFORMED_HEADER lines
    # present" AND the conclusion that work remains on the other axis — and it
    # has to sit after STE-3, where the reader meets the report.
    #
    # The regex is anchored on the three tokens rather than on prose wording so
    # it survives an editorial rewrite, but it cannot be satisfied by any two of
    # the three appearing on separate lines.
    F3_ZERO_LINE="$(printf '%s\n' "$F3_SKILL" \
        | grep -nE '(CANDIDATE|ORPHAN)' \
        | grep -E 'MALFORMED_HEADER' \
        | grep -E '(^|[^0-9])0( |-)' \
        | head -1)"
    if [[ -n "$F3_ZERO_LINE" ]]; then
        pass "F3a SKILL.md carries a single-line 0-result reading rule"
    else
        fail "F3a SKILL.md needs one line stating that 0 CANDIDATE:/ORPHAN: lines with MALFORMED_HEADER: lines present means 'none on this axis, work remains on another'"
    fi

    # F3a2 — that line must draw the CONCLUSION, not just name the tokens. The
    # false-green this blocks is a line that lists the three output kinds
    # without telling the reader what a zero count means.
    if printf '%s\n' "$F3_ZERO_LINE" | grep -qiE "axis|remain|still|other|elsewhere"; then
        pass "F3a2 the 0-result line states what remains, not just which tokens exist"
    else
        fail "F3a2 the 0-result line names the tokens but draws no conclusion (line=<<$F3_ZERO_LINE>>)"
    fi

    # F3a3 — placement: it belongs after STE-3, where the outputs are printed.
    # A rule buried above STE-1 is read before the report it interprets exists.
    F3_STE3_LN="$(printf '%s\n' "$F3_SKILL" | grep -nE '^STE-3\.' | head -1 | cut -d: -f1)"
    F3_ZERO_LN="${F3_ZERO_LINE%%:*}"
    if [[ -n "$F3_STE3_LN" && -n "$F3_ZERO_LN" && "$F3_ZERO_LN" -gt "$F3_STE3_LN" ]]; then
        pass "F3a3 the 0-result reading rule sits after STE-3 (line $F3_ZERO_LN > $F3_STE3_LN)"
    else
        fail "F3a3 expected the 0-result rule after STE-3 (ste3=$F3_STE3_LN zero=$F3_ZERO_LN)"
    fi

    # F3a4 — and it must not be contradicted elsewhere. A leftover line telling
    # the reader that an empty candidate list means there is nothing to do is
    # exactly the false-green the rule exists to remove.
    if printf '%s\n' "$F3_SKILL" | grep -qiE "nothing (left )?to (delete|do|retire)|no work"; then
        fail "F3a4 SKILL.md still contains a contradictory 'nothing to do' claim"
    else
        pass "F3a4 SKILL.md contains no contradictory 'nothing to do' claim"
    fi

    # F3b — STE-3's verbatim contract survives the rewrite (no summarising layer
    # may be introduced to "explain" the zero case).
    if echo "$F3_SKILL" | grep -qi "verbatim"; then
        pass "F3b SKILL.md STE-3 keeps the verbatim output contract"
    else
        fail "F3b SKILL.md lost the STE-3 verbatim output contract"
    fi

    # F3c — the retired claim that common has no write path must be gone.
    if echo "$F3_SKILL" | grep -q "has no write path"; then
        fail "F3c SKILL.md still claims audit-tests-common.sh has no write path"
    else
        pass "F3c SKILL.md no longer claims audit-tests-common.sh has no write path"
    fi

    # F3d — and the retired --offline claim ("results will be empty") with it:
    # under the new contract --offline still emits candidates.
    if echo "$F3_SKILL" | grep -qi "results will be empty"; then
        fail "F3d SKILL.md still claims --offline yields empty issue-specific results"
    else
        pass "F3d SKILL.md no longer claims --offline yields empty results"
    fi

    # F3e — the three deletion-hold verdicts are the vocabulary a reader needs
    # to interpret a report where candidates exist but nothing was deleted.
    F3_MISSING=""
    for f3_tok in SKIP_DELETE_ISSUE_ACTIVE SKIP_DELETE_METADATA_UNAVAILABLE SKIP_DELETE_AMBIGUOUS_REF; do
        echo "$F3_SKILL" | grep -q "$f3_tok" || F3_MISSING="$F3_MISSING $f3_tok"
    done
    assert_eq "F3e SKILL.md lists all three SKIP_DELETE_* hold verdicts" "" "$F3_MISSING"

    # F3f — and it lists them TOGETHER on one line, so a reader who hits one of
    # them learns that the other two exist. Three tokens scattered across three
    # unrelated paragraphs pass F3e while teaching nobody the vocabulary.
    if printf '%s\n' "$F3_SKILL" | grep -qE 'SKIP_DELETE_ISSUE_ACTIVE.*SKIP_DELETE_METADATA_UNAVAILABLE.*SKIP_DELETE_AMBIGUOUS_REF|SKIP_DELETE_.*SKIP_DELETE_.*SKIP_DELETE_'; then
        pass "F3f the three hold verdicts are enumerated on a single line"
    else
        fail "F3f the three SKIP_DELETE_* verdicts must be enumerated together on one line"
    fi

    # F3g — the `--offline` rule must carry the INVERTED meaning: candidates are
    # still reported, only the deletion is held. The retired claim ("results will
    # be empty") is checked separately by F3d; this row asserts the replacement
    # actually says the new thing rather than merely dropping the old one.
    F3_OFFLINE_LINE="$(printf '%s\n' "$F3_SKILL" | grep -E '^- `--offline`' | head -1)"
    if [[ -n "$F3_OFFLINE_LINE" ]] \
        && printf '%s\n' "$F3_OFFLINE_LINE" | grep -qiE "candidate" \
        && printf '%s\n' "$F3_OFFLINE_LINE" | grep -qiE "held|hold|suppress(ed)? deletion|not deleted|skip"; then
        pass "F3g the --offline rule states candidates still appear but deletion is held"
    else
        fail "F3g the --offline rule must state that candidates still appear and deletion is held (line=<<$F3_OFFLINE_LINE>>)"
    fi

    # F3h — the retired conjunctive candidate criterion. Under #1833 an issue
    # being CLOSED and stale is a DELETE-TIME check, never part of what makes a
    # file a candidate; a Rules line that still conjoins them re-teaches the bug.
    if printf '%s\n' "$F3_SKILL" | grep -qiE "AND issue CLOSED\+?( and)? ?stale"; then
        fail "F3h SKILL.md still names issue CLOSED+stale as part of the candidate criterion"
    else
        pass "F3h SKILL.md no longer conjoins issue staleness into the candidate criterion"
    fi

    # F3i — both invocation lines must offer --apply (CPR-ORTH: the common script
    # gained a write path, so its argument list has to say so), and STE-2 must
    # offer --offline now that the flag is effective there.
    F3_STE1="$(printf '%s\n' "$F3_SKILL" | grep -A1 -E '^STE-1\.' | grep -E 'audit-tests\.sh' | head -1)"
    F3_STE2="$(printf '%s\n' "$F3_SKILL" | grep -A1 -E '^STE-2\.' | grep -E 'audit-tests-common\.sh' | head -1)"
    assert_eq "F3i STE-1 lists --apply in the audit-tests.sh argument line" \
        "1" "$(printf '%s\n' "$F3_STE1" | grep -c -- '--apply')"
    assert_eq "F3j STE-2 lists --apply in the audit-tests-common.sh argument line" \
        "1" "$(printf '%s\n' "$F3_STE2" | grep -c -- '--apply')"
    assert_eq "F3k STE-2 lists --offline (the flag is effective there now)" \
        "1" "$(printf '%s\n' "$F3_STE2" | grep -c -- '--offline')"
else
    fail "F3 skills/sweep-tests/SKILL.md not found at $LOCAL_SKILL_MD"
fi

unset MOCK_ISSUES
