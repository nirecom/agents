# wsid.sh — fragment of tests/hooks/feature-2475-supervisor-codex-input.sh (no frontmatter).
# --wsid is joined into a plans-dir path (assemble.js planLines/handoffLines), so cli.js
#   parseArgs must hold it to the session-id charset /^[A-Za-z0-9_-]+$/ (CWE-22), keeping
#   the literal sentinel UNAVAILABLE. RED until write-code adds that check.

WS_T="$SCI_TMP/proj/sidW.jsonl"
printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"ws-utter"},"uuid":"w1","timestamp":"2026-01-01T00:00:01Z"}' > "$WS_T"
WS_TN="$(np "$WS_T")"

echo "--- wsid: traversal-shaped values are rejected (C1) ---"
WS_I=0
for WS_BAD in "../evil" "a/b" 'a\b' "x y" ""; do
  WS_I=$((WS_I + 1))
  WS_OUT="$SCI_TMP/wsid-bad-$WS_I.txt"
  rm -f "$WS_OUT"
  sci_run "$(np "$WS_OUT")" --mode alert --sid wssid --wsid "$WS_BAD" --transcript "$WS_TN"
  WS_LBL="wsid $(printf '%q' "$WS_BAD")"
  sci_eq "$WS_LBL: exit 1" "$SCI_RC" "1"
  sci_match "$WS_LBL: stderr starts supervisor-codex-input:" "$SCI_STDERR" '^supervisor-codex-input: '
  sci_eq "$WS_LBL: exactly one stderr line" "$(printf '%s\n' "$SCI_STDERR" | grep -c .)" "1"
  if [ -e "$WS_OUT" ]; then fail "$WS_LBL: --out not created" "file exists"; else pass "$WS_LBL: --out not created"; fi
done

echo "--- wsid: session-id-shaped values and UNAVAILABLE are accepted (C2) ---"
for WS_OK in "0dc9b34c-1e87-4b9f-81f3-0d9b31638bf9" "ws_Ok-1" "UNAVAILABLE"; do
  WS_OUT="$SCI_TMP/wsid-ok-$WS_OK.txt"
  rm -f "$WS_OUT"
  sci_run "$(np "$WS_OUT")" --mode alert --sid wssid --wsid "$WS_OK" --transcript "$WS_TN"
  sci_eq "wsid $WS_OK: exit 0" "$SCI_RC" "0"
  if [ -s "$WS_OUT" ]; then pass "wsid $WS_OK: --out written"; else fail "wsid $WS_OK: --out written" "missing or empty"; fi
done

echo "--- wsid: a ../ wsid cannot pull a file from outside the plans dir (C3) ---"
printf '%s\n' "# intent" "traversal-secret-body" > "$PLANS/../escape-intent.md"
printf '%s\n' "traversal-handoff-secret" > "$PLANS/../escape-handoff.md"
WS_OUT="$SCI_TMP/wsid-escape.txt"
rm -f "$WS_OUT"
sci_run "$(np "$WS_OUT")" --mode alert --sid wssid --wsid "../escape" --transcript "$WS_TN"
sci_eq "wsid ../escape: exit 1" "$SCI_RC" "1"
WS_BODY="$(cat "$WS_OUT" 2>/dev/null)"
sci_lacks "wsid ../escape: outside intent body never rendered" "$WS_BODY" "traversal-secret-body"
sci_lacks "wsid ../escape: outside handoff body never rendered" "$WS_BODY" "traversal-handoff-secret"
sci_lacks "wsid ../escape: stdout carries no outside body" "$SCI_STDOUT" "traversal-secret-body"
