# tests/bin/feat-2529-glossary-ledger-tag/after-escalate.sh
# T8-15: after ESCALATE the ledger is gone. reject then fails for want of a ledger
# (library 1, CLI not 4) — so a triage directive keyed on exit 4 would miss the
# tagged concern — while unresolved-concerns.json still carries the tag for
# cl_is_drift_tagged to find.

for fmt in test-review review-security-shared; do
  sid="$(lt_sid ae "$fmt")"; lt_build "$sid" "$fmt"; led="$(lt_ledger "$sid" "$fmt")"
  lt_cli finalize --plans-dir "$WORKFLOW_PLANS_DIR" --session-id "$sid" --format "$fmt" --round 1 --mode terminal --reason "escalated for the fixture"
  json="$(printf '%s\n' "$LT_OUT" | tail -n1)"
  if [ "$LT_RC" -eq 0 ] && [ -f "$json" ]; then pass "$fmt: finalize wrote unresolved-concerns.json"
  else fail "$fmt: finalize wrote unresolved-concerns.json" "rc=$LT_RC out=$LT_OUT err=$LT_ERR"; fi
  rm -f "$led"

  lt_eq "$fmt: library reject with the ledger gone returns 1" 1 "$(lt_rc cl_reject "$led" C1 "late triage")"
  lt_reject "$sid" "$fmt" C1
  if [ "$LT_RC" -ne 0 ] && [ "$LT_RC" -ne 4 ]; then pass "$fmt: CLI reject with the ledger gone fails, but not with 4 (rc=$LT_RC)"
  else fail "$fmt: CLI reject with the ledger gone fails, but not with 4" "rc=$LT_RC"; fi

  t="$(run_with_timeout 30 node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const c = (j.concerns || []).find((x) => x.id === "C1");
    process.stdout.write(c ? String(c.text) : "");
  ' "$(np "$json")" 2>/dev/null | tr -d '\r')"
  lt_has "$fmt: the JSON keeps C1's tag" "[glossary-drift term=foo bar]" "$t"
  lt_eq "$fmt: the JSON text is drift-tagged" 0 "$(lt_rc cl_is_drift_tagged "$t")"
  lt_eq "$fmt: the JSON text yields the term" "foo bar" "$(lt cl_drift_term "$t" 2>/dev/null)"
done
