# Group D: output contract — diagnostics channel + JSON backward compatibility (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, output-contract, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Undecidable files (prose header, no header) must be REPORTED rather than
# silently dropped — that silence is what let 25 of 26 common-scope "orphans"
# stay false positives. The reporting vocabulary is shared by both scripts
# (CPR-ORTH) and lives beside, not inside, the candidate list, so existing JSON
# consumers keep working.

D_REPO="$(make_repo)"
add_src "$D_REPO" "bin/alive.sh"
add_test_file "$D_REPO" "feature-401-gone.sh" "bin/gone-d1.sh" "TL2, scope:issue-specific"
add_test_file "$D_REPO" "feature-402-malformed.sh" "bin/gone-d2.sh (see also the notes)" "TL2, scope:issue-specific"
add_test_file_nohdr "$D_REPO" "feature-403-noheader.sh"
add_test_file "$D_REPO" "feature-404-alive.sh" "bin/alive.sh" "TL2, scope:issue-specific"
commit_repo "$D_REPO" "output-contract fixture"

D_STUB="$TMPDIR_BASE/d-stub"
install_gh_mock "$D_STUB"
export MOCK_ISSUES="401 closed 2019-01-01T00:00:00Z
402 closed 2019-01-01T00:00:00Z
403 closed 2019-01-01T00:00:00Z
404 closed 2019-01-01T00:00:00Z"

DC_REPO="$(make_repo)"
add_src "$DC_REPO" "bin/alive.sh"
add_test_file "$DC_REPO" "cc-gone.sh" "bin/gone-d3.sh"
add_test_file "$DC_REPO" "cc-malformed.sh" "bin/gone-d4.sh (prose tail)"
add_test_file_nohdr "$DC_REPO" "cc-noheader.sh"
add_test_file "$DC_REPO" "cc-alive.sh" "bin/alive.sh, bin/alive.sh"
commit_repo "$DC_REPO" "common output-contract fixture"

# ── D1 (case 23): text-mode diagnostics, both scripts, same tokens ──────────
run_in_repo "$D_REPO" "$D_STUB" "$AUDIT" --dry-run --format text
D1_OUT="$OUT"
if echo "$D1_OUT" | grep -q "^MALFORMED_HEADER: tests/feature-402-malformed.sh$"; then
    pass "D1a audit-tests text mode emits MALFORMED_HEADER: <file>"
else
    fail "D1a expected 'MALFORMED_HEADER: tests/feature-402-malformed.sh' (out=<<$D1_OUT>>)"
fi
if echo "$D1_OUT" | grep -q "^NO_TESTS_HEADER: tests/feature-403-noheader.sh$"; then
    pass "D1b audit-tests text mode emits NO_TESTS_HEADER: <file>"
else
    fail "D1b expected 'NO_TESTS_HEADER: tests/feature-403-noheader.sh' (out=<<$D1_OUT>>)"
fi
if echo "$D1_OUT" | grep -qE "^(MALFORMED_HEADER|NO_TESTS_HEADER): tests/feature-404-alive.sh$"; then
    fail "D1c a well-formed live-target file must produce no diagnostic (out=<<$D1_OUT>>)"
else
    pass "D1c a well-formed live-target file produces no diagnostic"
fi

run_in_repo "$DC_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
D1C_OUT="$OUT"
if echo "$D1C_OUT" | grep -q "^MALFORMED_HEADER: tests/cc-malformed.sh$" \
   && echo "$D1C_OUT" | grep -q "^NO_TESTS_HEADER: tests/cc-noheader.sh$"; then
    pass "D1d audit-tests-common uses the identical diagnostic tokens (CPR-ORTH)"
else
    fail "D1d audit-tests-common must emit the same MALFORMED_HEADER/NO_TESTS_HEADER tokens (out=<<$D1C_OUT>>)"
fi

# ── D2 (case 24): diagnostics are a first-class JSON array ──────────────────
run_in_repo "$D_REPO" "$D_STUB" "$AUDIT" --dry-run --format json
D2_JSON="$OUT"
if json_parses "$D2_JSON"; then
    pass "D2a audit-tests --format json emits parseable JSON"
else
    fail "D2a audit-tests --format json output does not parse (out=<<$D2_JSON>>)"
fi
if [[ "$(json_query "$D2_JSON" 'Array.isArray(d.diagnostics)')" == "true" ]]; then
    pass "D2b audit-tests JSON carries a diagnostics array"
else
    fail "D2b audit-tests JSON has no diagnostics array (out=<<$D2_JSON>>)"
fi
D2_KINDS="$(json_query "$D2_JSON" '(d.diagnostics||[]).map(x=>x.file+"="+x.kind).sort().join(",")')"
if [[ "$D2_KINDS" == *"tests/feature-402-malformed.sh=malformed_header"* ]]; then
    pass "D2c diagnostics entry kind=malformed_header is keyed by file"
else
    fail "D2c expected {file:tests/feature-402-malformed.sh, kind:malformed_header} (got=<<$D2_KINDS>>)"
fi
if [[ "$D2_KINDS" == *"tests/feature-403-noheader.sh=no_tests_header"* ]]; then
    pass "D2d diagnostics entry kind=no_tests_header is keyed by file"
else
    fail "D2d expected {file:tests/feature-403-noheader.sh, kind:no_tests_header} (got=<<$D2_KINDS>>)"
fi

# ── D3 (case 25): the common script mirrors the same JSON diagnostics shape ─
run_in_repo "$DC_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format json
D3_JSON="$OUT"
if json_parses "$D3_JSON"; then
    pass "D3a audit-tests-common --format json emits parseable JSON"
else
    fail "D3a audit-tests-common --format json output does not parse (out=<<$D3_JSON>>)"
fi
D3_KINDS="$(json_query "$D3_JSON" '(d.diagnostics||[]).map(x=>x.file+"="+x.kind).sort().join(",")')"
if [[ "$D3_KINDS" == *"tests/cc-malformed.sh=malformed_header"* \
   && "$D3_KINDS" == *"tests/cc-noheader.sh=no_tests_header"* ]]; then
    pass "D3b audit-tests-common JSON diagnostics use the identical kind vocabulary"
else
    fail "D3b audit-tests-common JSON diagnostics mismatch (got=<<$D3_KINDS>>)"
fi

# ── D4 (case 26): channel separation — JSON stdout stays machine-clean ──────
if echo "$D2_JSON" | grep -qE "^(MALFORMED_HEADER|NO_TESTS_HEADER|WARNING):"; then
    fail "D4a text diagnostic lines leaked into --format json stdout (out=<<$D2_JSON>>)"
else
    pass "D4a --format json stdout carries no text diagnostic lines"
fi
if echo "$D3_JSON" | grep -qE "^(MALFORMED_HEADER|NO_TESTS_HEADER|ORPHAN|WARNING):"; then
    fail "D4b text diagnostic lines leaked into common --format json stdout (out=<<$D3_JSON>>)"
else
    pass "D4b common --format json stdout carries no text diagnostic lines"
fi

# ── D5 (case 27): audit-tests JSON keeps every legacy key ──────────────────
D5_TOP="$(json_query "$D2_JSON" '["generated","cutoff","stale_months","offline","candidates"].every(k=>k in d)')"
if [[ "$D5_TOP" == "true" ]]; then
    pass "D5a audit-tests JSON retains all legacy top-level keys"
else
    fail "D5a audit-tests JSON lost a legacy top-level key (out=<<$D2_JSON>>)"
fi
D5_ITEM="$(json_query "$D2_JSON" \
    '(function(){var c=(d.candidates||[]).find(x=>x.dispatcher==="tests/feature-401-gone.sh");
      if(!c) return "missing";
      return ["dispatcher","issue","state","closed_at","last_commit","dispatcher_date","sibling_date","sibling","sibling_file_count"].filter(k=>!(k in c)).join("|")||"ok";})()')"
if [[ "$D5_ITEM" == "ok" ]]; then
    pass "D5b audit-tests candidate object retains all legacy per-item keys"
else
    fail "D5b audit-tests candidate item key check failed (result=<<$D5_ITEM>> out=<<$D2_JSON>>)"
fi

# ── D6 (case 28): common JSON keeps file/tests_paths/missing_paths semantics ─
D6_SHAPE="$(json_query "$D3_JSON" \
    '(function(){var items=Array.isArray(d)?d:(d.orphans||d.items||[]);
      var o=items.find(x=>x.file==="tests/cc-gone.sh");
      if(!o) return "missing";
      if(!Array.isArray(o.tests_paths)||!Array.isArray(o.missing_paths)) return "not-arrays";
      if(!o.missing_paths.every(p=>o.tests_paths.indexOf(p)>=0)) return "not-subset";
      if(o.missing_paths.length!==o.tests_paths.length) return "all-missing-expected";
      return "ok";})()')"
if [[ "$D6_SHAPE" == "ok" ]]; then
    pass "D6a common JSON keeps file/tests_paths/missing_paths with missing ⊆ tests"
else
    fail "D6a common JSON orphan shape check failed (result=<<$D6_SHAPE>> out=<<$D3_JSON>>)"
fi
D6_ALIVE="$(json_query "$D3_JSON" \
    '(function(){var items=Array.isArray(d)?d:(d.orphans||d.items||[]);
      return items.some(x=>x.file==="tests/cc-alive.sh")?"leaked":"ok";})()')"
if [[ "$D6_ALIVE" == "ok" ]]; then
    pass "D6b a live-target file never appears in the common JSON orphan list"
else
    fail "D6b live-target file leaked into the common JSON orphan list (out=<<$D3_JSON>>)"
fi

# ── D7 (case 29): the delete-gate verdict is machine-readable, not text-only ─
D7_GATE="$(json_query "$D2_JSON" \
    '(function(){var c=(d.candidates||[]).find(x=>x.dispatcher==="tests/feature-401-gone.sh");
      if(!c) return "missing";
      if(!("delete_gate" in c)) return "no-key";
      return c.delete_gate;})()')"
case "$D7_GATE" in
    ok-no-issue-ref|ok-closed-stale|hold-issue-active|hold-metadata-unavailable|hold-ambiguous-issue-ref)
        pass "D7a candidate JSON exposes delete_gate from the fixed vocabulary (got=$D7_GATE)" ;;
    *)
        fail "D7a candidate JSON must expose a delete_gate verdict (got=<<$D7_GATE>> out=<<$D2_JSON>>)" ;;
esac
if [[ "$D7_GATE" == "ok-closed-stale" ]]; then
    pass "D7b closed-and-stale issue yields delete_gate=ok-closed-stale"
else
    fail "D7b expected delete_gate=ok-closed-stale for a closed stale issue (got=<<$D7_GATE>>)"
fi

unset MOCK_ISSUES
