# tests/bin/feature-2344-concern-carrier/reject-durability.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/render.sh, bin/concern-ledger
# Tags: concern-ledger, concerns-log, carrier, render-concerns-log, issue-2344, TL1, scope:issue-specific, pwsh-not-required
# Sourced by tests/bin/feature-2344-concern-carrier.sh — shares its fixture + helpers.
# Cases D4-D5 (reject durability across archive-clear; ledger-deleted exit codes).

# ---------------------------------------------------------------------------
# D4: rejection durability across archive-clear cycle boundary
# ---------------------------------------------------------------------------
echo "--- D4: rejected DISCRIM persists in carrier after archive-clear ---"
D4P="$TMPDIR_BASE/d4/plans"; mkdir -p "$D4P"
D4S="sess-d4"; D4F="review-code-codex"
D4L="$D4P/${D4S}-${D4F}-concern-ledger.txt"

D4_T="use after free in cleanup handler code"
D4_D="$(discrim_of "$D4_T")"

mk_ledger "$D4L" "$D4F" "$D4S" "1"
add_entry "$D4L" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D4_T")" "$D4_D" "test" "codex" "-" "$D4_T"

run_cli render-concerns-log --plans-dir "$D4P" --session-id "$D4S" --format "$D4F" >/dev/null 2>&1 || true

D4_REJ_RC=0
run_cli reject --plans-dir "$D4P" --session-id "$D4S" --format "$D4F" --id "C1" --reason "not applicable" >/dev/null 2>&1 || D4_REJ_RC=$?
assert_eq "D4: reject exits 0" "0" "$D4_REJ_RC"

D4_RC2=0; D4_OUT2=""
D4_OUT2="$(run_cli render-concerns-log --plans-dir "$D4P" --session-id "$D4S" --format "$D4F" 2>/dev/null)" || D4_RC2=$?
assert_eq "D4: render after reject exits 0" "0" "$D4_RC2"

if [[ -n "$D4_OUT2" && -f "$D4_OUT2" ]]; then
    D4_C2="$(cat "$D4_OUT2")"
    assert_eq_nz       "D4: DISCRIM computed"                  "$D4_D" "$D4_D"
    assert_contains    "D4: reject line in carrier (REJECTED token)" "REJECTED" "$D4_C2"
    assert_contains    "D4: rejected DISCRIM in carrier"        "$D4_D"        "$D4_C2"
    assert_eq "D4: rejected not in open section" "" \
        "$(printf '%s\n' "$D4_C2" | grep -F "$D4_D [HIGH]" | grep -v 'REJECTED' || true)"
fi

D4_BEGIN_RC=0
run_cli begin-round --plans-dir "$D4P" --session-id "$D4S" --format "$D4F" --round 1 >/dev/null 2>&1 || D4_BEGIN_RC=$?
assert_eq "D4: begin-round exits 0 (archive-and-clear)" "0" "$D4_BEGIN_RC"
# After archive-and-clear the ledger must contain no open entries (new cycle started).
D4_OPEN_COUNT="$(grep -c '|open|' "$D4L" 2>/dev/null; true)"
assert_eq "D4: ledger has no open entries after archive-and-clear (RED until change 4)" "0" "$D4_OPEN_COUNT"

D4_RC3=0; D4_OUT3=""
D4_OUT3="$(run_cli render-concerns-log --plans-dir "$D4P" --session-id "$D4S" --format "$D4F" 2>/dev/null)" || D4_RC3=$?
assert_eq "D4: post-cycle render exits 0 (reject row preserved)" "0" "$D4_RC3"

if [[ -n "$D4_OUT3" && -f "$D4_OUT3" ]]; then
    D4_C3="$(cat "$D4_OUT3")"
    assert_contains    "D4: rejected DISCRIM persists after cycle" "$D4_D" "$D4_C3"
    assert_eq "D4: rejected not in open section post-cycle" "" \
        "$(printf '%s\n' "$D4_C3" | grep -F "$D4_D [HIGH]" | grep -v 'REJECTED' || true)"
else
    fail "D4: post-cycle render did not produce carrier (rc=$D4_RC3)"
fi

# ---------------------------------------------------------------------------
# D5: ledger deleted → exit 3 benign when no reject; exit 0 when reject exists
# ---------------------------------------------------------------------------
echo "--- D5: ledger deleted; exit 3 when no reject; exit 0 when carrier has reject ---"
D5P="$TMPDIR_BASE/d5/plans"; mkdir -p "$D5P"
D5S="sess-d5"; D5F="review-code-codex"
D5L="$D5P/${D5S}-${D5F}-concern-ledger.txt"

D5_T="integer overflow in size computation path"
D5_D="$(discrim_of "$D5_T")"

mk_ledger "$D5L" "$D5F" "$D5S" "1"
add_entry "$D5L" "C1" "HIGH" "open" "1" "1" "$(slot_of "$D5_T")" "$D5_D" "test" "codex" "-" "$D5_T"

run_cli render-concerns-log --plans-dir "$D5P" --session-id "$D5S" --format "$D5F" >/dev/null 2>&1 || true
run_cli reject --plans-dir "$D5P" --session-id "$D5S" --format "$D5F" --id "C1" --reason "false positive" >/dev/null 2>&1 || true
run_cli render-concerns-log --plans-dir "$D5P" --session-id "$D5S" --format "$D5F" >/dev/null 2>&1 || true

rm -f "$D5L"

D5_RC=0; D5_OUT=""
D5_OUT="$(run_cli render-concerns-log --plans-dir "$D5P" --session-id "$D5S" --format "$D5F" 2>/dev/null)" || D5_RC=$?
assert_eq "D5: no ledger + carrier has reject → exit 0" "0" "$D5_RC"

if [[ -n "$D5_OUT" && -f "$D5_OUT" ]]; then
    D5_C="$(cat "$D5_OUT")"
    assert_eq_nz    "D5: DISCRIM computed"                          "$D5_D" "$D5_D"
    assert_contains "D5: reject row preserved after ledger deletion" "$D5_D" "$D5_C"
    pass "D5: stdout is carrier path"
else
    fail "D5: render should output carrier path when carrier has reject rows (rc=$D5_RC)"
fi

# D5b: completely clean slate → exit 3, stdout empty
D5BP="$TMPDIR_BASE/d5b/plans"; mkdir -p "$D5BP"
D5B_RC=0; D5B_OUT=""
D5B_OUT="$(run_cli render-concerns-log --plans-dir "$D5BP" --session-id "sess-d5b" --format "$D5F" 2>/dev/null)" || D5B_RC=$?
assert_eq "D5b: no ledger no carrier → exit 3" "3" "$D5B_RC"
assert_eq "D5b: exit 3 stdout empty"            ""  "$D5B_OUT"
