# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, negative-control, TL2, scope:common, exclusions
# What must stay OUT of the owned-name sets, and the boundary between tampering and
# ordinary traffic. A guard that over-collects fires on its own bookkeeping or on bash
# internals, and a suite that goes red for no reason is disabled within a week.

echo ""
echo "=== G7: variable exclusion rules ==="
expect_silent "G7a: guard-owned CLG_/clg_ names stay out of the library-owned set" G7a
expect_silent "G7b: bash special variables stay out (asserted from inside a function)" G7b
# G7c — the four protected library scalars direction B names (detail plan 3-2). Pinning
# one is not pinning four: a guard that watches only CL_LIB_DIR lets the other three
# drift, and CL_DISCOVERY_FLAG (core.sh:206) loads as the empty string, so a guard that
# skips empty values silently drops it.
for _s in CL_CATEGORY_VOCAB CL_LIB_DIR _CL_SAFE_LIB CL_DISCOVERY_FLAG; do
    expect_report "G7c/$_s: the library scalar $_s is in the set and its change is reported" \
        "G7c-$_s" "$_s" "ctx-G7c-$_s"
done
# G7d/G7e/G7f — disappearance and retype on the variable side, and the boundary that keeps
# them apart from legitimate mutation. CL_DISCOVERY_FLAG loads as the empty string, so
# comparing values alone cannot tell "unset" from "still empty" — existence has to be
# tested. CL_HASH_CACHE is `declare -gA` (bin/lib/concern-ledger/core.sh:39) and cl_sha256
# writes an entry on every hash, so its TYPE and EXISTENCE are invariants while its
# CONTENTS are not: G7f turns red the moment a guard reports a plain cache write.
expect_report "G7d: unsetting the empty-valued library scalar CL_DISCOVERY_FLAG is reported" \
    G7d "CL_DISCOVERY_FLAG" "ctx-G7d"
expect_report "G7e: re-declaring CL_HASH_CACHE as a non-associative variable is reported" \
    G7e "CL_HASH_CACHE" "ctx-G7e"
expect_silent "G7f: adding and overwriting CL_HASH_CACHE entries is cache traffic, not tampering, and stays silent" G7f

echo ""
echo "=== G8: empty owned-name set ==="
run_scenario G8
if [[ -n "$SC_REPORT" ]]; then
    fail "G8: with no library loaded the guard still reported: $(brief "$SC_REPORT")"
elif [[ -n "$SC_OUT" ]]; then
    fail "G8: with no library loaded the guard wrote $(printf '%s' "$SC_OUT" | wc -c | tr -d '[:space:]') bytes to stdout/stderr (a declare -f whole-namespace dump leaks here): $(brief "$SC_OUT")"
elif [[ "$SC_RC" != "0" ]]; then
    fail "G8: scenario exited $SC_RC on the empty owned-name set"
else
    pass "G8: an empty owned-name set stays silent, before and after case functions appear"
fi
