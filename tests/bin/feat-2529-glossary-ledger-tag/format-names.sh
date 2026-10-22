# tests/bin/feat-2529-glossary-ledger-tag/format-names.sh
# T8-12: STAGE_LEDGER_FORMAT names the four real ledger formats, stageOfLedgerFormat
# inverts it (null for stage names and for security-plan), and the grant reader and
# list-drift both work under the format name the ledger header carries.

LT_SCOPE="$LT_AGENTS_N/hooks/workflow-state/glossary-check/scope.js"
map="$(run_with_timeout 30 node -e '
  const m = require(process.argv[1]);
  const f = m.STAGE_LEDGER_FORMAT || {};
  const keys = Object.keys(f).sort().map((k) => k + "=" + f[k]).join(",");
  const inv = ["outline-plan","detail-plan","test-review","review-security-shared","outline","detail","security-plan"]
    .map((x) => x + ">" + String(typeof m.stageOfLedgerFormat === "function" ? m.stageOfLedgerFormat(x) : "NOFN")).join(",");
  process.stdout.write(keys + "\n" + inv);
' "$LT_SCOPE" 2>&1 | tr -d '\r')"
lt_eq "STAGE_LEDGER_FORMAT maps the four ledger stages" \
  "code=review-security-shared,detail=detail-plan,outline=outline-plan,tests=test-review" "$(printf '%s\n' "$map" | sed -n 1p)"
lt_eq "stageOfLedgerFormat inverts it and returns null otherwise" \
  "outline-plan>outline,detail-plan>detail,test-review>tests,review-security-shared>code,outline>null,detail>null,security-plan>null" \
  "$(printf '%s\n' "$map" | sed -n 2p)"

# The names are the ones the producers already use.
fp="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/format-params.sh"
for name in outline-plan detail-plan test-review; do
  if grep -qE "(^|[|( ])${name}([|)]|$)" "$fp"; then pass "format-params.sh knows $name"
  else fail "format-params.sh knows $name" "not found in $fp"; fi
done
if grep -qF "review-security-shared" "$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger/core.sh"; then pass "core.sh knows review-security-shared"
else fail "core.sh knows review-security-shared"; fi

# Grant reader exit table.
sid="$(lt_sid fn test-review)"
lt_seed_grants "$sid" review_tests tests "$(lt_gj "foo bar" "$LT_D1")"
# label ; want ; format ; norm ; discrim ("-" omits --discrim)
while IFS=';' read -r label want f n d; do
  [ -z "$label" ] && continue
  args=(--session "$sid" --format "$f" --norm "$n")
  [ "$d" = "-" ] || args+=(--discrim "$d")
  rc=0
  # A missing CLI would exit 1 from node itself; 127 keeps the 1-rows from passing.
  if [ -f "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-ledger-grant" ]; then
    run_with_timeout 30 node "$LT_GRANT_CLI" "${args[@]}" >/dev/null 2>&1 || rc=$?
  else rc=127; fi
  lt_eq "grant reader: $label" "$want" "$rc"
done <<TABLE
matching norm and discrim;0;test-review;foo bar;$LT_D1
wrong discrim;1;test-review;foo bar;d0000000
unmapped format security-plan;1;security-plan;foo bar;$LT_D1
missing --discrim;2;test-review;foo bar;-
norm normalized (Foo-Bars);0;test-review;Foo-Bars;$LT_D1
TABLE

# list-drift runs under the header's own format name.
sid="$(lt_sid fnls review-security-shared)"; lt_build "$sid" review-security-shared
lt_eq "ledger header carries the format name" "review-security-shared" "$(head -n1 "$(lt_ledger "$sid" review-security-shared)" | cut -d'|' -f2)"
lt_list "$sid" review-security-shared
lt_has "list-drift works under the header format name" "$LT_D1" "$LT_OUT"
