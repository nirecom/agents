# tests/bin/feat-2529-glossary-ledger-tag/residual.sh
# T8-9: text that mentions the words without the "[glossary-drift " opener is an
# ordinary concern — reject still closes it in every format.

LT_TR="the glossary-drift term=foo note in the readme is stale"
lt_eq "a bare mention is not a tag" 1 "$(lt_rc cl_is_drift_tagged "$LT_TR")"
for fmt in $LT_FORMATS; do
  sid="$(lt_sid rs "$fmt")"; led="$(lt_ledger "$sid" "$fmt")"
  printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$fmt" "$sid" > "$led"
  lt_row "$led" C1 MEDIUM open "$LT_TR"
  lt_reject "$sid" "$fmt" C1
  lt_eq "$fmt: reject of a bare mention exits 0" 0 "$LT_RC"
  lt_eq "$fmt: bare mention becomes rejected" rejected "$(lt_field "$sid" "$fmt" C1 3)"
done
