# tests/bin/feat-2529-glossary-ledger-tag/single-rule.sh
# T8-7 (static half): drift-tag.sh is the one owner of the tag rule. Its four
# functions are defined nowhere else in bin/, the tag literal appears in no other
# ledger module, the module names no ledger format, and cl_reject delegates to it.
# The load-order and fail-closed-load half: tests/bin/fix-2025-safe-state-path.sh.

LT_SR_BIN="$SCRIPT_CHECKOUT_ROOT/bin"
for fn in cl_is_drift_tagged cl_drift_term cl_guard_reject cl_accept; do
  defs="$(grep -rlE "^[[:space:]]*(function[[:space:]]+)?${fn}[[:space:]]*\(\)" "$LT_SR_BIN" 2>/dev/null | sed "s#^$LT_SR_BIN/##" | sort)"
  lt_eq "$fn is defined only in drift-tag.sh" "lib/concern-ledger/drift-tag.sh" "$defs"
done

users="$(grep -rlF -- "glossary-drift" "$LT_SR_BIN/lib/concern-ledger.sh" "$LT_SR_BIN/lib/concern-ledger" 2>/dev/null | sed "s#^$LT_SR_BIN/##" | sort)"
lt_eq "only drift-tag.sh spells the tag among the ledger modules" "lib/concern-ledger/drift-tag.sh" "$users"
if grep -qF -- "glossary-drift term" "$LT_SR_BIN/concern-ledger" 2>/dev/null; then
  fail "bin/concern-ledger parses no tag itself" "the entrypoint spells 'glossary-drift term'"
else pass "bin/concern-ledger parses no tag itself"; fi

if [ -f "$LT_DRIFT" ]; then
  named="$(grep -oE "outline-plan|detail-plan|test-review|review-security-shared|security-plan" "$LT_DRIFT" | sort -u | tr '\n' ' ')"
  lt_eq "drift-tag.sh names no ledger format (the stage map owns them)" "" "$named"
else
  fail "drift-tag.sh names no ledger format" "module missing"
fi

body="$(sed -n '/^cl_reject()/,/^}/p' "$LT_SR_BIN/lib/concern-ledger/core.sh")"
lt_has "cl_reject calls cl_guard_reject" "cl_guard_reject" "$body"
