# tests/bin/feat-2529-glossary-ledger-tag/list-drift.sh
# T8-8: list-drift prints "DISCRIM<TAB>term" for every tagged concern still open or
# reopened — never an untagged, rejected or resolved one. No ledger is an empty
# success; an unreadable ledger is an error.

LT_T5="the index drifts too [glossary-drift term=quux]"
TAB="$(printf '\t')"
for fmt in $LT_FORMATS; do
  sid="$(lt_sid ls "$fmt")"; led="$(lt_ledger "$sid" "$fmt")"
  printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$fmt" "$sid" > "$led"
  lt_row "$led" C1 HIGH open "$LT_T1"
  lt_row "$led" C2 MEDIUM open "$LT_T2"
  lt_row "$led" C3 MEDIUM reopened "$LT_T3"
  lt_row "$led" C4 LOW rejected "$LT_T4"
  lt_row "$led" C5 LOW resolved "$LT_T5"
  lt_list "$sid" "$fmt"
  lt_eq "$fmt: list-drift exits 0" 0 "$LT_RC"
  want="$(printf '%s\tfoo bar\n%s\tfoo bar\n' "$LT_D1" "$LT_D3" | sort)"
  lt_eq "$fmt: list-drift lists exactly the open and reopened tagged concerns" "$want" "$(printf '%s\n' "$LT_OUT" | sort)"

  # No ledger: empty success.
  lt_list "$(lt_sid lsnone "$fmt")" "$fmt"
  lt_eq "$fmt: list-drift with no ledger exits 0" 0 "$LT_RC"
  lt_eq "$fmt: list-drift with no ledger prints nothing" "" "$LT_OUT"
done

# After a refused reject the concern is still listed (the reviewer must surface it).
for fmt in test-review review-security-shared; do
  sid="$(lt_sid lsrj "$fmt")"; lt_build "$sid" "$fmt"
  lt_reject "$sid" "$fmt" C1
  lt_list "$sid" "$fmt"
  lt_has "$fmt: C1 still listed after the refused reject" "$LT_D1${TAB}foo bar" "$LT_OUT"
done

# Unreadable ledger: an error, not an empty list.
sid="$(lt_sid lsunr detail-plan)"; lt_build "$sid" detail-plan; led="$(lt_ledger "$sid" detail-plan)"
chmod 000 "$led" 2>/dev/null
if [ -r "$led" ]; then
  skip "list-drift on an unreadable ledger (chmod 000 does not revoke read on this host)"
else
  lt_list "$sid" detail-plan
  lt_eq "list-drift on an unreadable ledger exits 1" 1 "$LT_RC"
fi
chmod 600 "$led" 2>/dev/null

# The sentinel at a ledger stage with no ledger grants nothing, and accept stays refused.
sid="$(lt_sid lssn test-review)"
lt_seed_current "$sid" review_tests
lt_mark "$sid" "$(lt_accepted "foo bar" tests)"
lt_eq "sentinel with no ledger records no ledger_grants" "(absent)" "$(lt_grants_of "$sid" review_tests)"
lt_build "$sid" test-review
lt_accept "$sid" test-review C1
lt_eq "a ledger created after the sentinel is not pre-granted (4)" 4 "$LT_RC"
