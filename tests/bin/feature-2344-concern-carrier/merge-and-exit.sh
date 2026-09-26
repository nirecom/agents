# tests/bin/feature-2344-concern-carrier/merge-and-exit.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/render.sh, bin/concern-ledger
# Tags: concern-ledger, concerns-log, carrier, render-concerns-log, issue-2344, TL1, scope:issue-specific, pwsh-not-required
# Sourced by tests/bin/feature-2344-concern-carrier.sh — shares its fixture + helpers.
# Cases D6 (merge semantics) and D7 (exit-code coverage).

# ---------------------------------------------------------------------------
# D6: _cl_merge_concerns_log — carrier-only non-reject discarded, reject retained,
# DISCRIM byte-sort deterministic, open+rejected→rejected wins (plan §206-212).
# ---------------------------------------------------------------------------
echo "--- D6: _cl_merge_concerns_log merge semantics ---"
D6P="$TMPDIR_BASE/d6/plans"; mkdir -p "$D6P"
D6S="sess-d6"; D6F="review-security-shared"
D6L="$D6P/${D6S}-${D6F}-concern-ledger.txt"

D6_T_OPEN="race condition in event handler loop"
D6_T_STALE="stale concern no longer in the ledger at all"
D6_T_REJ="rejected concern from prior session round"
D6_D_OPEN="$(discrim_of "$D6_T_OPEN")"
D6_D_STALE="$(discrim_of "$D6_T_STALE")"
D6_D_REJ="$(discrim_of "$D6_T_REJ")"

mk_ledger "$D6L" "$D6F" "$D6S" "1"
add_entry "$D6L" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D6_T_OPEN")" "$D6_D_OPEN" "test" "scanner" "-" "$D6_T_OPEN"
add_entry "$D6L" "C2" "MEDIUM" "open" "1" "1" "$(slot_of "$D6_T_REJ")" "$D6_D_REJ" "test" "scanner" "-" "$D6_T_REJ"

run_cli render-concerns-log --plans-dir "$D6P" --session-id "$D6S" --format "$D6F" >/dev/null 2>&1 || true
run_cli reject --plans-dir "$D6P" --session-id "$D6S" --format "$D6F" --id "C2" --reason "out of scope" >/dev/null 2>&1 || true
run_cli render-concerns-log --plans-dir "$D6P" --session-id "$D6S" --format "$D6F" >/dev/null 2>&1 || true

mk_ledger "$D6L" "$D6F" "$D6S" "1"
add_entry "$D6L" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D6_T_OPEN")" "$D6_D_OPEN" "test" "scanner" "-" "$D6_T_OPEN"

D6_CAR="$(carrier_path_for "$D6P" "$D6S" "$D6F")"
if [[ -n "$D6_CAR" && -f "$D6_CAR" ]]; then
    printf '%s\n' "- $D6_D_STALE [LOW] $D6_T_STALE" >> "$D6_CAR" || true
fi

D6_RC=0; D6_OUT=""
D6_OUT="$(run_cli render-concerns-log --plans-dir "$D6P" --session-id "$D6S" --format "$D6F" 2>/dev/null)" || D6_RC=$?
assert_eq "D6: re-render exits 0" "0" "$D6_RC"

if [[ -n "$D6_OUT" && -f "$D6_OUT" ]]; then
    D6_C="$(cat "$D6_OUT")"
    assert_eq_nz       "D6: open DISCRIM computed"             "$D6_D_OPEN"  "$D6_D_OPEN"
    assert_contains    "D6: open C1 retained"                  "$D6_D_OPEN [HIGH]" "$D6_C"
    assert_eq_nz       "D6: stale DISCRIM computed"            "$D6_D_STALE" "$D6_D_STALE"
    assert_not_contains "D6: stale non-reject line discarded"  "$D6_D_STALE [LOW]" "$D6_C"
    assert_eq_nz       "D6: reject DISCRIM computed"           "$D6_D_REJ"   "$D6_D_REJ"
    assert_contains    "D6: reject line retained after merge"  "$D6_D_REJ"   "$D6_C"
    D6_OUT2=""
    D6_OUT2="$(run_cli render-concerns-log --plans-dir "$D6P" --session-id "$D6S" --format "$D6F" 2>/dev/null)" || true
    if [[ -n "$D6_OUT2" && -f "$D6_OUT2" ]]; then
        assert_eq "D6: render is deterministic (same output twice)" "$(cat "$D6_OUT")" "$(cat "$D6_OUT2")"
    else
        fail "D6: second render did not produce carrier"
    fi
else
    fail "D6: re-render did not produce carrier (rc=$D6_RC)"
fi

# D6b: same-DISCRIM open vs rejected → rejected wins; input order invariant
D6BP1="$TMPDIR_BASE/d6b1/plans"; D6BP2="$TMPDIR_BASE/d6b2/plans"
mkdir -p "$D6BP1" "$D6BP2"
D6B_T1="alpha vulnerability in authentication layer"
D6B_T2="beta vulnerability in session management layer"
D6B_D1="$(discrim_of "$D6B_T1")"; D6B_D2="$(discrim_of "$D6B_T2")"

L6B1="$D6BP1/sess-d6b-review-security-shared-concern-ledger.txt"
mk_ledger "$L6B1" "review-security-shared" "sess-d6b" "1"
add_entry "$L6B1" "C1" "HIGH"   "open" "1" "1" "$(slot_of "$D6B_T1")" "$D6B_D1" "t" "s" "-" "$D6B_T1"
add_entry "$L6B1" "C2" "MEDIUM" "open" "1" "1" "$(slot_of "$D6B_T2")" "$D6B_D2" "t" "s" "-" "$D6B_T2"

L6B2="$D6BP2/sess-d6b-review-security-shared-concern-ledger.txt"
mk_ledger "$L6B2" "review-security-shared" "sess-d6b" "1"
add_entry "$L6B2" "C1" "MEDIUM" "open" "1" "1" "$(slot_of "$D6B_T2")" "$D6B_D2" "t" "s" "-" "$D6B_T2"
add_entry "$L6B2" "C2" "HIGH"   "open" "1" "1" "$(slot_of "$D6B_T1")" "$D6B_D1" "t" "s" "-" "$D6B_T1"

D6B_O1=""; D6B_O2=""
D6B_O1="$(run_cli render-concerns-log --plans-dir "$D6BP1" --session-id "sess-d6b" --format "review-security-shared" 2>/dev/null)" || true
D6B_O2="$(run_cli render-concerns-log --plans-dir "$D6BP2" --session-id "sess-d6b" --format "review-security-shared" 2>/dev/null)" || true

if [[ -n "$D6B_O1" && -f "$D6B_O1" && -n "$D6B_O2" && -f "$D6B_O2" ]]; then
    assert_eq_nz       "D6b: D1 DISCRIM computed"     "$D6B_D1" "$D6B_D1"
    assert_eq_nz       "D6b: D2 DISCRIM computed"     "$D6B_D2" "$D6B_D2"
    assert_contains    "D6b: D1 in carrier"           "$D6B_D1" "$(cat "$D6B_O1")"
    assert_contains    "D6b: D2 in carrier"           "$D6B_D2" "$(cat "$D6B_O1")"
    assert_eq "D6b: reversed-ledger-order → identical DISCRIM-sorted carrier" \
        "$(cat "$D6B_O1")" "$(cat "$D6B_O2")"
else
    fail "D6b: one or both renders did not produce carrier"
fi

# ---------------------------------------------------------------------------
# D7: Exit code coverage
# ---------------------------------------------------------------------------
echo "--- D7: exit code coverage ---"

# D7a: no ledger, no carrier → exit 3, stdout empty
D7AP="$TMPDIR_BASE/d7a/plans"; mkdir -p "$D7AP"
D7A_RC=0; D7A_OUT=""
D7A_OUT="$(run_cli render-concerns-log --plans-dir "$D7AP" --session-id "sess-d7a" --format "review-security-shared" 2>/dev/null)" || D7A_RC=$?
assert_eq "D7a: no ledger no carrier → exit 3" "3" "$D7A_RC"
assert_eq "D7a: exit 3 → stdout empty"          ""  "$D7A_OUT"

# D7b: open concern → exit 0, stdout is carrier path
D7BP="$TMPDIR_BASE/d7b/plans"; mkdir -p "$D7BP"
D7BS="sess-d7b"; D7BF="review-security-shared"
D7BL="$D7BP/${D7BS}-${D7BF}-concern-ledger.txt"
D7B_T="format string vulnerability in logging subsystem"
D7B_D="$(discrim_of "$D7B_T")"
mk_ledger "$D7BL" "$D7BF" "$D7BS" "1"
add_entry "$D7BL" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D7B_T")" "$D7B_D" "test" "scanner" "-" "$D7B_T"

D7B_RC=0; D7B_OUT=""
D7B_OUT="$(run_cli render-concerns-log --plans-dir "$D7BP" --session-id "$D7BS" --format "$D7BF" 2>/dev/null)" || D7B_RC=$?
assert_eq "D7b: open concern → exit 0" "0" "$D7B_RC"
D7B_EXP="$(carrier_path_for "$D7BP" "$D7BS" "$D7BF")"
assert_eq "D7b: stdout is carrier path" "$D7B_EXP" "$D7B_OUT"
[[ -n "$D7B_OUT" && -f "$D7B_OUT" ]] && pass "D7b: carrier file exists" || fail "D7b: carrier file missing at $D7B_OUT"

# D7c: unwritable carrier target → exit 5
# TL3 gap: chmod 555 ineffective on Windows/Git Bash (NTFS overrides POSIX mode).
# Skipped SKIP-TL3 on those platforms; TL3 Linux CI required. Plans-dir-unreadable
# alternative also hides the ledger, yielding exit 3 not exit 5.
D7CP="$TMPDIR_BASE/d7c/plans"; mkdir -p "$D7CP"
D7CS="sess-d7c"; D7CF="review-security-shared"
D7CL="$D7CP/${D7CS}-${D7CF}-concern-ledger.txt"
D7C_T="stack overflow in recursive descent parser"
D7C_D="$(discrim_of "$D7C_T")"
mk_ledger "$D7CL" "$D7CF" "$D7CS" "1"
add_entry "$D7CL" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D7C_T")" "$D7C_D" "test" "scanner" "-" "$D7C_T"

chmod 555 "$D7CP" 2>/dev/null || true
if [[ -w "$D7CP" ]]; then
    echo "SKIP-TL3 D7c: chmod ineffective (Windows/Git Bash); exit 5 test needs TL3 Linux CI"
else
    D7C_RC=0
    run_cli render-concerns-log --plans-dir "$D7CP" --session-id "$D7CS" --format "$D7CF" >/dev/null 2>&1 || D7C_RC=$?
    assert_eq "D7c: unwritable carrier → exit 5" "5" "$D7C_RC"
    chmod 755 "$D7CP" 2>/dev/null || true
fi

# D7d: no ledger but carrier has reject row → exit 0, stdout is carrier path
D7DP="$TMPDIR_BASE/d7d/plans"; mkdir -p "$D7DP"
D7DS="sess-d7d"; D7DF="review-security-shared"
D7DL="$D7DP/${D7DS}-${D7DF}-concern-ledger.txt"
D7D_T="path traversal in file upload handler code"
D7D_D="$(discrim_of "$D7D_T")"

mk_ledger "$D7DL" "$D7DF" "$D7DS" "1"
add_entry "$D7DL" "C1" "MEDIUM" "open" "1" "1" "$(slot_of "$D7D_T")" "$D7D_D" "test" "scanner" "-" "$D7D_T"
run_cli render-concerns-log --plans-dir "$D7DP" --session-id "$D7DS" --format "$D7DF" >/dev/null 2>&1 || true
run_cli reject --plans-dir "$D7DP" --session-id "$D7DS" --format "$D7DF" --id "C1" --reason "wont fix" >/dev/null 2>&1 || true
run_cli render-concerns-log --plans-dir "$D7DP" --session-id "$D7DS" --format "$D7DF" >/dev/null 2>&1 || true
rm -f "$D7DL"

D7D_RC=0; D7D_OUT=""
D7D_OUT="$(run_cli render-concerns-log --plans-dir "$D7DP" --session-id "$D7DS" --format "$D7DF" 2>/dev/null)" || D7D_RC=$?
assert_eq "D7d: no ledger + carrier has reject → exit 0" "0" "$D7D_RC"
D7D_EXP="$(carrier_path_for "$D7DP" "$D7DS" "$D7DF")"
assert_eq "D7d: stdout is carrier path"   "$D7D_EXP" "$D7D_OUT"
[[ -n "$D7D_OUT" && -f "$D7D_OUT" ]] && pass "D7d: carrier file exists" || fail "D7d: carrier file missing (rc=$D7D_RC)"
