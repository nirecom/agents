#!/usr/bin/env bash
# Tests: bin/lib/codex-core.sh
# Tags: bin, env, config, codex, tests
# Tests for new SSOT helpers added to bin/lib/codex-core.sh (issue #329).
#
# Covered functions:
#   codex_core_severity_tokens
#   codex_core_check_jq
#   codex_core_round_log_append
#   codex_core_round_count
#   codex_core_hard_cap_check
#   codex_core_validate_severity
#
# Tests will FAIL until the functions are implemented — this defines the contract.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_LIB="$AGENTS_ROOT/bin/lib/codex-core.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: run a snippet that sources codex-core.sh and runs the given bash.
# Captures stdout, stderr is suppressed to keep test output clean.
run_core() {
    local snippet="$1"
    bash -c "set -uo pipefail; source '$CORE_LIB' >/dev/null 2>&1 || true; $snippet" 2>&1
}

# Helper for return-code capture
run_core_rc() {
    local snippet="$1"
    bash -c "set -uo pipefail; source '$CORE_LIB' >/dev/null 2>&1 || true; $snippet" 2>&1
    echo "__RC__$?"
}

# Helper: extract rc from run_core_rc output
extract_rc() {
    echo "$1" | sed -n 's/.*__RC__\([0-9]*\)$/\1/p' | tail -1
}

# Helper: strip rc line from run_core_rc output
extract_out() {
    echo "$1" | sed 's/__RC__[0-9]*$//'
}

# ---------------------------------------------------------------------------
# 1. codex_core_severity_tokens — prints exactly HIGH, MEDIUM, LOW (3 lines)
# ---------------------------------------------------------------------------
OUT=$(run_core 'codex_core_severity_tokens' || true)
EXPECTED=$'HIGH\nMEDIUM\nLOW'
if [[ "$OUT" == "$EXPECTED" ]]; then
    pass "severity_tokens: outputs exactly HIGH, MEDIUM, LOW (3 lines, exact match)"
else
    fail "severity_tokens: output mismatch. Got: $(echo "$OUT" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
# 2. round_log_append single call → round_count = 1
# ---------------------------------------------------------------------------
LOG1="$TMPDIR_BASE/log1.jsonl"
RES=$(run_core_rc "codex_core_round_log_append '$LOG1' 'sessA' 'detail-plan' 'APPROVED' 'HIGH:0 MEDIUM:0 LOW:0' >/dev/null; codex_core_round_count '$LOG1' 'sessA' 'detail-plan'")
OUT=$(extract_out "$RES")
if [[ "$(echo "$OUT" | tr -d '[:space:]')" == "1" ]]; then
    pass "round_log_append single → count=1"
else
    fail "round_log_append single: expected count=1, got '$OUT'"
fi

# ---------------------------------------------------------------------------
# 3. round_log_append two calls → count=2
# ---------------------------------------------------------------------------
LOG2="$TMPDIR_BASE/log2.jsonl"
RES=$(run_core "
codex_core_round_log_append '$LOG2' 'sessA' 'detail-plan' 'NEEDS_REVISION' 'HIGH:1' >/dev/null
codex_core_round_log_append '$LOG2' 'sessA' 'detail-plan' 'APPROVED' 'HIGH:0' >/dev/null
codex_core_round_count '$LOG2' 'sessA' 'detail-plan'
")
if [[ "$(echo "$RES" | tr -d '[:space:]')" == "2" ]]; then
    pass "round_log_append twice → count=2"
else
    fail "round_log_append twice: expected count=2, got '$RES'"
fi

# ---------------------------------------------------------------------------
# 4. round_count on missing file → 0
# ---------------------------------------------------------------------------
OUT=$(run_core "codex_core_round_count '$TMPDIR_BASE/nonexistent.jsonl' 'sessA' 'detail-plan'")
if [[ "$(echo "$OUT" | tr -d '[:space:]')" == "0" ]]; then
    pass "round_count missing file → 0"
else
    fail "round_count missing file: expected 0, got '$OUT'"
fi

# ---------------------------------------------------------------------------
# 5. round_count filters by session_id
# ---------------------------------------------------------------------------
LOG3="$TMPDIR_BASE/log3.jsonl"
OUT=$(run_core "
codex_core_round_log_append '$LOG3' 'sessA' 'detail-plan' 'APPROVED' '' >/dev/null
codex_core_round_count '$LOG3' 'sessB' 'detail-plan'
")
if [[ "$(echo "$OUT" | tr -d '[:space:]')" == "0" ]]; then
    pass "round_count filters by session_id"
else
    fail "round_count session filter: expected 0, got '$OUT'"
fi

# ---------------------------------------------------------------------------
# 6. round_count filters by label
# ---------------------------------------------------------------------------
LOG4="$TMPDIR_BASE/log4.jsonl"
OUT=$(run_core "
codex_core_round_log_append '$LOG4' 'sessA' 'labelX' 'APPROVED' '' >/dev/null
codex_core_round_count '$LOG4' 'sessA' 'labelY'
")
if [[ "$(echo "$OUT" | tr -d '[:space:]')" == "0" ]]; then
    pass "round_count filters by label"
else
    fail "round_count label filter: expected 0, got '$OUT'"
fi

# ---------------------------------------------------------------------------
# 7. All JSONL rows parse with jq .
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    LOG5="$TMPDIR_BASE/log5.jsonl"
    run_core "
codex_core_round_log_append '$LOG5' 'sessA' 'detail-plan' 'APPROVED' 'HIGH:0 MEDIUM:0 LOW:0' >/dev/null
codex_core_round_log_append '$LOG5' 'sessA' 'detail-plan' 'NEEDS_REVISION' 'HIGH:2' >/dev/null
" >/dev/null 2>&1
    if [[ -f "$LOG5" ]] && jq -e . "$LOG5" >/dev/null 2>&1; then
        pass "round_log_append: all rows are valid JSON (jq parses)"
    else
        fail "round_log_append: jq could not parse rows. Contents: $(cat "$LOG5" 2>/dev/null)"
    fi
else
    fail "jq not present — required by codex-core SSOT helpers"
fi

# ---------------------------------------------------------------------------
# 8. round_log_append on read-only dir → returns 1 (POSIX only)
# ---------------------------------------------------------------------------
case "$(uname -s)" in
    MINGW*|CYGWIN*|MSYS*)
        pass "round_log_append read-only: skipped on Windows (chmod unreliable)"
        ;;
    *)
        RO_DIR="$TMPDIR_BASE/readonly"
        mkdir -p "$RO_DIR"
        chmod 555 "$RO_DIR"
        RES=$(run_core_rc "codex_core_round_log_append '$RO_DIR/log.jsonl' 'sessA' 'detail-plan' 'APPROVED' '' >/dev/null 2>&1")
        RC=$(extract_rc "$RES")
        chmod 755 "$RO_DIR"
        if [[ "$RC" == "1" ]]; then
            pass "round_log_append read-only dir → returns 1 (fail-closed)"
        else
            fail "round_log_append read-only dir: expected rc=1, got rc=$RC"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# 9. Security: session_id with quotes & backslashes round-trips
# ---------------------------------------------------------------------------
LOG6="$TMPDIR_BASE/log6.jsonl"
WEIRD_SESS='sess"with\backslash'
RES=$(run_core "
codex_core_round_log_append '$LOG6' '$WEIRD_SESS' 'detail-plan' 'APPROVED' '' >/dev/null
codex_core_round_count '$LOG6' '$WEIRD_SESS' 'detail-plan'
")
if [[ "$(echo "$RES" | tr -d '[:space:]')" == "1" ]]; then
    pass "session_id with quote+backslash round-trips correctly"
else
    fail "session_id security: expected count=1, got '$RES'"
fi

# ---------------------------------------------------------------------------
# 10. check_jq absent: shell-function override → emits FAILED + install guidance, rc=1
# Stub jq via shell function alias (no PATH manipulation needed — portable on Git Bash).
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUT=$(bash -c "
  source '$CORE_LIB' >/dev/null 2>&1 || true
  # Override jq as a function that returns 1 (simulates absent jq)
  jq() { return 127; }
  # Override command built-in only for jq lookup
  command() {
    if [[ \"\$1\" == '-v' && \"\$2\" == 'jq' ]]; then return 1; fi
    builtin command \"\$@\"
  }
  codex_core_check_jq
" 2>&1) || EXIT_CODE=$?

if echo "$OUT" | grep -qi "FAILED"; then
    pass "check_jq absent: output contains FAILED"
else
    fail "check_jq absent: missing FAILED. Output: $OUT"
fi

if echo "$OUT" | grep -qi "jq not installed"; then
    pass "check_jq absent: output contains 'jq not installed' install guidance"
else
    fail "check_jq absent: missing 'jq not installed'. Output: $OUT"
fi

# Spec: "return 1 if absent"
if [[ "$EXIT_CODE" == "1" ]]; then
    pass "check_jq absent: returns 1"
else
    fail "check_jq absent: expected rc=1, got rc=$EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# 11. hard_cap_check under limit → returns 0, no output
# ---------------------------------------------------------------------------
LOG7="$TMPDIR_BASE/log7.jsonl"
run_core "codex_core_round_log_append '$LOG7' 'sessA' 'detail-plan' 'APPROVED' '' >/dev/null" >/dev/null 2>&1
# count=1, cap=2, extensions_used=0 → limit=2, under limit
RES=$(run_core_rc "codex_core_hard_cap_check '$LOG7' 'sessA' 'detail-plan' 2 0 2")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "0" ]]; then
    pass "hard_cap_check under limit → returns 0"
else
    fail "hard_cap_check under limit: expected rc=0, got rc=$RC, output: $OUT"
fi

# ---------------------------------------------------------------------------
# 12. hard_cap_check at limit, ext_used < max_ext → rc=2, "extension available"
# ---------------------------------------------------------------------------
LOG8="$TMPDIR_BASE/log8.jsonl"
run_core "
codex_core_round_log_append '$LOG8' 'sessA' 'detail-plan' 'A' '' >/dev/null
codex_core_round_log_append '$LOG8' 'sessA' 'detail-plan' 'B' '' >/dev/null
" >/dev/null 2>&1
# count=2, cap=2, ext_used=0, max_ext=2 → limit=2 → at limit
RES=$(run_core_rc "codex_core_hard_cap_check '$LOG8' 'sessA' 'detail-plan' 2 0 2")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "2" ]]; then
    pass "hard_cap_check at limit with extensions → returns 2"
else
    fail "hard_cap_check at limit: expected rc=2, got rc=$RC, output: $OUT"
fi
if echo "$OUT" | grep -qi "extension available"; then
    pass "hard_cap_check at limit: message contains 'extension available'"
else
    fail "hard_cap_check at limit: missing 'extension available'. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 13. hard_cap_check at ceiling → "absolute ceiling reached"
# ---------------------------------------------------------------------------
LOG9="$TMPDIR_BASE/log9.jsonl"
run_core "
for i in 1 2 3 4; do
  codex_core_round_log_append '$LOG9' 'sessA' 'detail-plan' 'A' '' >/dev/null
done
" >/dev/null 2>&1
# count=4, cap=2, ext_used=2, max_ext=2 → limit=4, at ceiling
RES=$(run_core_rc "codex_core_hard_cap_check '$LOG9' 'sessA' 'detail-plan' 2 2 2")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "2" ]]; then
    pass "hard_cap_check at ceiling → returns 2"
else
    fail "hard_cap_check at ceiling: expected rc=2, got rc=$RC, output: $OUT"
fi
if echo "$OUT" | grep -qi "absolute ceiling reached"; then
    pass "hard_cap_check at ceiling: message contains 'absolute ceiling reached'"
else
    fail "hard_cap_check at ceiling: missing 'absolute ceiling reached'. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 14. hard_cap_check no log file → count=0 → rc=0
# ---------------------------------------------------------------------------
RES=$(run_core_rc "codex_core_hard_cap_check '$TMPDIR_BASE/never.jsonl' 'sessA' 'detail-plan' 2 0 2")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "hard_cap_check no log file → returns 0"
else
    fail "hard_cap_check no log file: expected rc=0, got rc=$RC"
fi

# ---------------------------------------------------------------------------
# validate_severity tests
# ---------------------------------------------------------------------------
mk_file() {
    local f="$1"
    shift
    printf '%s\n' "$@" > "$f"
}

# 15. mode=prefixed-numbered: APPROVED alone → rc 0
F="$TMPDIR_BASE/vs1.txt"
mk_file "$F" "APPROVED"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "validate_severity prefixed-numbered: 'APPROVED' alone → rc 0"
else
    fail "validate_severity prefixed-numbered APPROVED: rc=$RC, out=$(extract_out "$RES")"
fi

# 16. mode=prefixed-numbered: APPROVED with text → rc 0
F="$TMPDIR_BASE/vs2.txt"
mk_file "$F" "APPROVED with justification"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "validate_severity prefixed-numbered: 'APPROVED with justification' → rc 0"
else
    fail "validate_severity prefixed-numbered APPROVED+text: rc=$RC"
fi

# 17. mode=prefixed-numbered: NEEDS_REVISION with numbered+prefixed concerns → rc 0
F="$TMPDIR_BASE/vs3.txt"
mk_file "$F" "NEEDS_REVISION" "1. [HIGH] missing test coverage"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "validate_severity prefixed-numbered: NEEDS_REVISION + numbered concern → rc 0"
else
    fail "validate_severity prefixed-numbered NR: rc=$RC, out=$(extract_out "$RES")"
fi

# 18. mode=prefixed-numbered: 'APPROVEDfoo' (no space) → FAILED, rc 3
F="$TMPDIR_BASE/vs4.txt"
mk_file "$F" "APPROVEDfoo"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "3" ]]; then
    pass "validate_severity prefixed-numbered: 'APPROVEDfoo' → rc 3"
else
    fail "validate_severity 'APPROVEDfoo': expected rc=3, got rc=$RC"
fi
if echo "$OUT" | grep -qi "FAILED" && echo "$OUT" | grep -qi "MALFORMED"; then
    pass "validate_severity 'APPROVEDfoo': output mentions FAILED+MALFORMED"
else
    fail "validate_severity 'APPROVEDfoo': missing FAILED/MALFORMED. Output: $OUT"
fi

# 19. mode=prefixed-numbered: 'APPROVED!' → rc 3 (must be space, not punctuation)
F="$TMPDIR_BASE/vs5.txt"
mk_file "$F" "APPROVED!"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "3" ]]; then
    pass "validate_severity prefixed-numbered: 'APPROVED!' → rc 3"
else
    fail "validate_severity 'APPROVED!': expected rc=3, got rc=$RC"
fi

# 20. mode=prefixed-numbered: 'APPROVED<tab>' → rc 3 (tab is not space)
F="$TMPDIR_BASE/vs6.txt"
printf 'APPROVED\tsome\n' > "$F"
RES=$(run_core_rc "codex_core_validate_severity --mode=prefixed-numbered '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "3" ]]; then
    pass "validate_severity prefixed-numbered: 'APPROVED<tab>' → rc 3 (tab not allowed)"
else
    fail "validate_severity 'APPROVED<tab>': expected rc=3, got rc=$RC"
fi

# 21. mode=grouped: '## HIGH\n- item' → rc 0
F="$TMPDIR_BASE/vs7.txt"
mk_file "$F" "## HIGH" "- some concern"
RES=$(run_core_rc "codex_core_validate_severity --mode=grouped '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "validate_severity grouped: '## HIGH\\n- item' → rc 0"
else
    fail "validate_severity grouped HIGH+item: expected rc=0, got rc=$RC, out=$(extract_out "$RES")"
fi

# 22. mode=grouped: 'No issues found' → rc 0
F="$TMPDIR_BASE/vs8.txt"
mk_file "$F" "No issues found"
RES=$(run_core_rc "codex_core_validate_severity --mode=grouped '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "0" ]]; then
    pass "validate_severity grouped: 'No issues found' → rc 0"
else
    fail "validate_severity grouped no-issues: expected rc=0, got rc=$RC"
fi

# 23. mode=grouped: no headers → rc 3
F="$TMPDIR_BASE/vs9.txt"
mk_file "$F" "some random text" "no headers at all"
RES=$(run_core_rc "codex_core_validate_severity --mode=grouped '$F'")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")
if [[ "$RC" == "3" ]]; then
    pass "validate_severity grouped: no headers → rc 3"
else
    fail "validate_severity grouped no-headers: expected rc=3, got rc=$RC"
fi
if echo "$OUT" | grep -qi "FAILED"; then
    pass "validate_severity grouped no-headers: FAILED in output"
else
    fail "validate_severity grouped no-headers: missing FAILED. Output: $OUT"
fi

# 24. mode=grouped: header with no bullets or '(none)' → rc 3
F="$TMPDIR_BASE/vs10.txt"
mk_file "$F" "## HIGH" "## MEDIUM" "## LOW"
RES=$(run_core_rc "codex_core_validate_severity --mode=grouped '$F'")
RC=$(extract_rc "$RES")
if [[ "$RC" == "3" ]]; then
    pass "validate_severity grouped: empty sections (no bullets/(none)) → rc 3"
else
    fail "validate_severity grouped empty sections: expected rc=3, got rc=$RC"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
