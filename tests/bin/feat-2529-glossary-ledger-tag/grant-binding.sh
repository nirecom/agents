# tests/bin/feat-2529-glossary-ledger-tag/grant-binding.sh
# T8-5: a grant opens a concern only when its norm AND discrim both match and it
# sits on the step of the ledger format's own stage. Every near-miss refuses with
# 4 and writes nothing; a positive control proves the fixture can succeed.

lt_refuses() { # <label> <fmt> <id> <step> <stage> <grant-json>...
  local label="$1" fmt="$2" id="$3" step="$4" stage="$5" sid before; shift 5
  LT_GB_N=$((LT_GB_N + 1))
  sid="$(lt_sid "gb$LT_GB_N" "$fmt")"; lt_build "$sid" "$fmt"; before="$(lt_snap "$sid" "$fmt")"
  lt_seed_grants "$sid" "$step" "$stage" "$@"
  lt_accept "$sid" "$fmt" "$id"
  lt_eq "$fmt: $label refuses (4)" 4 "$LT_RC"
  lt_eq "$fmt: $label writes nothing" "$before" "$(lt_snap "$sid" "$fmt")"
}
LT_GB_N=0

for fmt in detail-plan review-security-shared; do
  stage="$(lt_stage_of "$fmt")"; step="$(lt_step_of "$stage")"
  lt_refuses "discrim-only match (other norm)" "$fmt" C1 "$step" "$stage" "$(lt_gj "other term" "$LT_D1")"
  lt_refuses "norm-only match (C3's discrim)" "$fmt" C1 "$step" "$stage" "$(lt_gj "foo bar" "$LT_D3")"
  lt_refuses "norm-only match (fabricated discrim)" "$fmt" C1 "$step" "$stage" "$(lt_gj "foo bar" "d0000000")"
  lt_refuses "cross-concern grant (C1 granted, C3 accepted)" "$fmt" C3 "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
  # The right grant on another stage's step.
  case "$stage" in detail) os=outline ;; *) os=tests ;; esac
  lt_refuses "grant on the $os step" "$fmt" C1 "$(lt_step_of "$os")" "$os" "$(lt_gj "foo bar" "$LT_D1")"

  # Positive control: the exact grant on the right step succeeds.
  sid="$(lt_sid gbok "$fmt")"; lt_build "$sid" "$fmt"
  lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
  lt_accept "$sid" "$fmt" C1
  lt_eq "$fmt: exact grant opens C1 (positive control)" 0 "$LT_RC"
  lt_eq "$fmt: C3 still open beside the C1 grant" open "$(lt_field "$sid" "$fmt" C3 3)"
done

# The tag term is normalized before the match: "Foo-Bars" meets the grant "foo bar".
fmt=test-review; stage=tests; step=review_tests
sid="$(lt_sid gbnorm "$fmt")"; led="$(lt_ledger "$sid" "$fmt")"
tn="the heading spells it [glossary-drift term=Foo-Bars] in part one"
printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$fmt" "$sid" > "$led"
lt_row "$led" C1 HIGH open "$tn"
lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$(lt cl_discrim "$tn")")"
lt_accept "$sid" "$fmt" C1
lt_eq "$fmt: tag term Foo-Bars matches grant norm foo bar" 0 "$LT_RC"
