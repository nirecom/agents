# tests/bin/feature-2344-concern-carrier/reject-cli.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/render.sh, bin/concern-ledger
# Tags: concern-ledger, concerns-log, carrier, render-concerns-log, issue-2344, TL1, scope:issue-specific, pwsh-not-required
# Sourced by tests/bin/feature-2344-concern-carrier.sh — shares its fixture + helpers.
# Case D8 (reject CLI: exit codes, ledger immutability, render integration).

# ---------------------------------------------------------------------------
# D8: reject CLI — exit codes, ledger immutability, render integration
# ---------------------------------------------------------------------------
echo "--- D8: reject CLI — exit codes, ledger immutability, render integration ---"
D8P="$TMPDIR_BASE/d8/plans"; mkdir -p "$D8P"
D8S="sess-d8"; D8F="review-security-shared"
D8L="$D8P/${D8S}-${D8F}-concern-ledger.txt"

D8_T_R="sql injection in query builder module"
D8_T_O="cross site scripting in template renderer"
D8_D_R="$(discrim_of "$D8_T_R")"; D8_D_O="$(discrim_of "$D8_T_O")"

mk_ledger "$D8L" "$D8F" "$D8S" "1"
add_entry "$D8L" "C1" "HIGH"   "open" "1" "1" "$(slot_of "$D8_T_R")" "$D8_D_R" "test" "scanner" "-" "$D8_T_R"
add_entry "$D8L" "C2" "MEDIUM" "open" "1" "1" "$(slot_of "$D8_T_O")" "$D8_D_O" "test" "scanner" "-" "$D8_T_O"

run_cli render-concerns-log --plans-dir "$D8P" --session-id "$D8S" --format "$D8F" >/dev/null 2>&1 || true

# D8a: missing --reason → exit 2; ledger immutable.
# Distinguish "unknown subcommand: reject" (exit 2, not implemented) from
# "reject: --reason required" (exit 2, correctly implemented) via stderr text.
# If "unknown subcommand" appears the test FAILs — that is the correct RED state.
D8L_BEFORE="$(cat "$D8L" 2>/dev/null || true)"
D8_NR_STDERR="$TMPDIR_BASE/d8-nr-stderr.txt"
D8_NR_RC=0
run_cli reject --plans-dir "$D8P" --session-id "$D8S" --format "$D8F" --id "C1" >/dev/null 2>"$D8_NR_STDERR" || D8_NR_RC=$?
if grep -Fq "unknown" "$D8_NR_STDERR" 2>/dev/null; then
    fail "D8a: reject not yet implemented ('unknown …' in stderr means subcommand/option unrecognised; exit 2 ≠ missing-reason exit 2)"
else
    assert_eq "D8a: missing --reason → exit 2" "2" "$D8_NR_RC"
fi
assert_eq "D8a: ledger unchanged after bad reject" "$D8L_BEFORE" "$(cat "$D8L" 2>/dev/null || true)"

# D8b: unknown --id → exit 5 (id exists, concern not found); ledger immutable
D8_BI_RC=0
run_cli reject --plans-dir "$D8P" --session-id "$D8S" --format "$D8F" --id "C99" --reason "test" >/dev/null 2>&1 || D8_BI_RC=$?
assert_eq "D8b: unknown --id → exit 5"            "5" "$D8_BI_RC"
assert_eq "D8b: ledger unchanged after bad --id"   "$D8L_BEFORE" "$(cat "$D8L" 2>/dev/null || true)"

# D8c: valid reject → exit 0
D8_REJ_RC=0
run_cli reject --plans-dir "$D8P" --session-id "$D8S" --format "$D8F" --id "C1" --reason "accepted risk" >/dev/null 2>&1 || D8_REJ_RC=$?
assert_eq "D8c: valid reject exits 0" "0" "$D8_REJ_RC"

# D8d: render after reject → C1 not in open section; DISCRIM in reject history; C2 still open
D8_REN_RC=0; D8_REN_OUT=""
D8_REN_OUT="$(run_cli render-concerns-log --plans-dir "$D8P" --session-id "$D8S" --format "$D8F" 2>/dev/null)" || D8_REN_RC=$?
assert_eq "D8d: render after reject exits 0" "0" "$D8_REN_RC"

if [[ -n "$D8_REN_OUT" && -f "$D8_REN_OUT" ]]; then
    D8_C="$(cat "$D8_REN_OUT")"
    assert_eq_nz       "D8d: rejected DISCRIM computed"                 "$D8_D_R" "$D8_D_R"
    assert_eq "D8d: rejected C1 not in open section" "" \
        "$(printf '%s\n' "$D8_C" | grep -F "$D8_D_R [HIGH]" | grep -v 'REJECTED' || true)"
    assert_contains    "D8d: rejected C1 DISCRIM in reject history"     "$D8_D_R"        "$D8_C"
    assert_contains    "D8d: reject line has REJECTED token"            "REJECTED"       "$D8_C"
    assert_eq_nz       "D8d: open DISCRIM computed"                     "$D8_D_O" "$D8_D_O"
    assert_contains    "D8d: open C2 still in carrier"                  "$D8_D_O [MEDIUM]" "$D8_C"
else
    fail "D8d: render after reject did not produce carrier (rc=$D8_REN_RC)"
fi
