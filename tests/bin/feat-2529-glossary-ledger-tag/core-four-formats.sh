# tests/bin/feat-2529-glossary-ledger-tag/core-four-formats.sh
# T8-1..T8-4 over every ledger format: (a) reject of a tagged concern exits 4 and
# writes nothing, even with a grant in state; (b) accept without a grant exits 4
# and writes nothing; (c1) accept with a seeded grant closes the concern and labels
# the carrier; (c2) the same grant made by the real sentinel; (d) untagged concerns
# keep reject and refuse accept with 2. LT_CORE_FORMATS names the formats one
# entrypoint runs (split on the time budget); the two entrypoints cover LT_FORMATS.

for fmt in $LT_CORE_FORMATS; do
  stage="$(lt_stage_of "$fmt")"; step="$(lt_step_of "$stage")"

  # (a) reject refused.
  sid="$(lt_sid rj "$fmt")"; lt_build "$sid" "$fmt"; before="$(lt_snap "$sid" "$fmt")"
  for id in C1 C3 C4; do
    lt_reject "$sid" "$fmt" "$id"
    lt_eq "$fmt: reject $id (tagged) exits 4" 4 "$LT_RC"
    lt_has "$fmt: reject $id names the tag" "$LT_MSG_REJECT" "$LT_ERR"
  done
  lt_eq "$fmt: refused rejects leave ledger and carrier untouched" "$before" "$(lt_snap "$sid" "$fmt")"
  lt_eq "$fmt: C1 stays open after refused reject" open "$(lt_field "$sid" "$fmt" C1 3)"
  lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")"
  lt_reject "$sid" "$fmt" C1
  lt_eq "$fmt: reject C1 still exits 4 with a matching grant" 4 "$LT_RC"
  lt_eq "$fmt: granted-but-rejected leaves files untouched" "$before" "$(lt_snap "$sid" "$fmt")"

  # (b) accept without a grant.
  sid="$(lt_sid na "$fmt")"; lt_build "$sid" "$fmt"; before="$(lt_snap "$sid" "$fmt")"
  for id in C1 C4; do
    lt_accept "$sid" "$fmt" "$id"
    lt_eq "$fmt: accept $id without grant exits 4" 4 "$LT_RC"
    lt_has "$fmt: accept $id without grant says why" "$LT_MSG_ACCEPT" "$LT_ERR"
  done
  lt_eq "$fmt: refused accepts leave files untouched" "$before" "$(lt_snap "$sid" "$fmt")"

  # (c1) seeded grants on the stage's own step.
  sid="$(lt_sid ga "$fmt")"; lt_build "$sid" "$fmt"
  lt_seed_grants "$sid" "$step" "$stage" "$(lt_gj "foo bar" "$LT_D1")" "$(lt_gj "foo bar" "$LT_D3")" "$(lt_gj "baz qux" "$LT_D4")"
  for id in C1 C3 C4; do
    lt_accept "$sid" "$fmt" "$id" "the user keeps this spelling"
    lt_eq "$fmt: accept $id with its grant exits 0" 0 "$LT_RC"
    lt_eq "$fmt: accepted $id is rejected-state" rejected "$(lt_field "$sid" "$fmt" "$id" 3)"
  done
  car="$(cat "$(lt_carrier "$sid" "$fmt")" 2>/dev/null)"
  lt_has "$fmt: carrier keeps the earlier line" "dprior00" "$car"
  line="$(printf '%s\n' "$car" | grep -F -- "- $LT_D1 " | head -n1)"
  lt_has "$fmt: carrier line for C1 is labelled accepted(glossary-drift)" "accepted(glossary-drift)" "$line"
  lt_has "$fmt: carrier line for C1 keeps the user's reason" "the user keeps this spelling" "$line"
  lt_eq "$fmt: C2 untouched by accepts" open "$(lt_field "$sid" "$fmt" C2 3)"

  # (c2) the grant made by the real sentinel at the current step.
  sid="$(lt_sid se "$fmt")"; lt_build "$sid" "$fmt"
  lt_seed_current "$sid" "$step"
  lt_mark "$sid" "$(lt_accepted "foo bar" "$stage")"
  grants="$(lt_grants_of "$sid" "$step")"
  lt_has "$fmt: sentinel grants C1's discrim on $step" "$LT_D1" "$grants"
  lt_has "$fmt: sentinel grant carries the normalized term" '"norm":"foo bar"' "$grants"
  lt_lacks "$fmt: sentinel does not grant the other term's concern" "$LT_D4" "$grants"
  lt_accept "$sid" "$fmt" C1
  lt_eq "$fmt: accept C1 after the sentinel exits 0" 0 "$LT_RC"
  lt_has "$fmt: sentinel path labels the carrier" "accepted(glossary-drift)" "$(cat "$(lt_carrier "$sid" "$fmt")" 2>/dev/null)"
  lt_accept "$sid" "$fmt" C4
  lt_eq "$fmt: accept C4 (other term) after the sentinel exits 4" 4 "$LT_RC"

  # (d) untagged concerns.
  sid="$(lt_sid ut "$fmt")"; lt_build "$sid" "$fmt"
  lt_reject "$sid" "$fmt" C2
  lt_eq "$fmt: reject C2 (untagged) exits 0" 0 "$LT_RC"
  lt_eq "$fmt: rejected C2 is rejected-state" rejected "$(lt_field "$sid" "$fmt" C2 3)"
  sid="$(lt_sid ua "$fmt")"; lt_build "$sid" "$fmt"; before="$(lt_snap "$sid" "$fmt")"
  lt_accept "$sid" "$fmt" C2
  lt_eq "$fmt: accept C2 (untagged) exits 2" 2 "$LT_RC"
  # Exit 2 is also the usage code; the refusal must come from a known subcommand.
  lt_lacks "$fmt: accept is a known subcommand" "unknown subcommand" "$LT_ERR"
  lt_lacks "$fmt: accept takes the documented options" "unknown option" "$LT_ERR"
  lt_eq "$fmt: refused untagged accept leaves files untouched" "$before" "$(lt_snap "$sid" "$fmt")"
done
