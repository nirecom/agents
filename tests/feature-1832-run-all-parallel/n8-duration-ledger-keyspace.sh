#!/usr/bin/env bash
# n8-duration-ledger-keyspace.sh — what a key identifies, and what an unknown key does to order.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: the key is the ledger's identity function. Two tests with one basename must not share a
# measurement, a filename a colleague can create must not become code, and a test the ledger has
# never seen must lead the plan — including when EVERY test is new, the first-ever run.

# TL3 gap (what this test does NOT catch):
# - the same test name on a different branch, an accepted collision by design
# - a filesystem that rejects the metacharacter filename this case creates
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n8-duration-ledger-keyspace"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

UNMEASURED=99
if [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
fi
if [ -f "$DUR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"
fi

plan_names() {
    awk -F'\t' '$1 == "plan" { n = split($4, a, /[\/\\]/); printf "%s ", a[n] }' "$1"
}
plan_tiers() { awk -F'\t' '$1 == "plan" { printf "%s ", $5 }' "$1"; }
# Matched on the FULL path: two rows can share a basename, so plan_tier from n2- is unusable here.
tier_at()   { awk -F'\t' -v pat="$2" '$1 == "plan" && index($4, pat) { print $5; exit }' "$1"; }
tier_sole() { awk -F'\t' -v pat="$2" -v anti="$3" \
                 '$1 == "plan" && index($4, pat) && !index($4, anti) { print $5; exit }' "$1"; }

# ===========================================================================
# N30 — same basename, different directory: two tests, two measurements
# ===========================================================================
# This is NOT the accepted same-name-different-branch collision: same repo, same checkout,
# two directories. A key built from the basename would fold these into one record and give
# whichever ran last the other's duration.
D="$(fx_new_root)"
fx_add_dummy "$D" a --sleep 2
mkdir -p "$D/tests/sub"
{
    printf '#!/usr/bin/env bash\n'
    printf '# Tests: tests/run-all.sh\n'
    printf '# Tags: fixture, parallel, scope:issue-specific\n'
    printf 'sleep 8\n'
    printf 'exit 0\n'
} > "$D/tests/sub/a.sh"
chmod +x "$D/tests/sub/a.sh" 2>/dev/null || true

D_TOP="$(fx_tests_dir "$D")/*.sh"
D_SUB="$(fx_tests_dir "$D")/sub/*.sh"
D_OUT="$FX_TMP_ROOT/d.out"; D_ERR="$FX_TMP_ROOT/d.err"
DP_OUT="$FX_TMP_ROOT/dp.out"; DP_ERR="$FX_TMP_ROOT/dp.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$D" 120 "$D_OUT" "$D_ERR" -j 2 "$D_TOP" "$D_SUB"
D_EXEC="$(fx_contract_field "$D_OUT" EXECUTED)"
fx_exec "$D" 60 "$DP_OUT" "$DP_ERR" --print-plan "$D_TOP" "$D_SUB"
FX_LEDGER_KEEP=0

D_KEYS="$(fx_ledger_cat | awk -F'|' 'NF == 3 && $3 ~ /a\.sh$/ { n[$3] = 1 } END { c = 0; for (k in n) c++; print c + 0 }')"
D_SUB_S="$(fx_ledger_cat | awk -F'|' 'NF == 3 && index($3, "sub/") { v = $2 } END { print v }')"
D_TOP_S="$(fx_ledger_cat | awk -F'|' 'NF == 3 && $3 ~ /a\.sh$/ && !index($3, "sub/") { v = $2 } END { print v }')"
D_ROWS="$(grep -c '^plan	' "$DP_OUT" || true)"
D_T_SUB="$(tier_at "$DP_OUT" "/sub/a.sh")"
D_T_TOP="$(tier_sole "$DP_OUT" "a.sh" "/sub/")"

if [ "$D_EXEC" = "2" ] && [ "$D_ROWS" = "2" ]; then
    fx_pass "N30b. the fixture is real: both a.sh files ran and both appear in the plan"
else
    fx_fail "N30b. the fixture is not usable — want EXECUTED=2 and 2 plan rows, got EXECUTED=${D_EXEC:-absent} rows=$D_ROWS"
    fx_show_tail "$D_ERR" 6
fi

if dur_missing "N30. two a.sh in different directories keep separate records"; then
    fx_fail "N30c. each a.sh gets the tier of its own duration (implementation missing: $DUR_LIB_REL)"
else
    if [ "$D_KEYS" = "2" ] && [ "${D_TOP_S:-x}" -le 3 ] 2>/dev/null && [ "${D_SUB_S:-x}" -ge 7 ] 2>/dev/null; then
        fx_pass "N30. the ledger holds 2 distinct a.sh keys with their own durations (${D_TOP_S}s and ${D_SUB_S}s)"
    else
        fx_fail "N30. want 2 distinct a.sh keys with top<=3s and sub>=7s, got keys=$D_KEYS top='${D_TOP_S:-absent}' sub='${D_SUB_S:-absent}'"
    fi
    if [ "$D_T_TOP" = "1" ] && [ "$D_T_SUB" = "3" ]; then
        fx_pass "N30c. the next plan gave tests/a.sh tier 1 and tests/sub/a.sh tier 3"
    else
        fx_fail "N30c. want tier 1 for the top-level a.sh and 3 for the sub one, got '${D_T_TOP:-absent}' and '${D_T_SUB:-absent}'"
    fi
fi

# ===========================================================================
# N31 — a metacharacter FILENAME survives the real writer -> reader round trip
# ===========================================================================
# N21 feeds a doctored line straight to the reader. This drives the same hazard through the
# whole pipeline: a filename any colleague can create, keyed by the writer and looked up
# again. If any stage expanded it, the substituted spelling would appear somewhere.
E="$(fx_new_root)"
EVIL_BASE='inj$(echo SUBST1)`echo SUBST2`.sh'
EVIL_SUBST='injSUBST1SUBST2.sh'
{
    printf '#!/usr/bin/env bash\n'
    printf '# Tests: tests/run-all.sh\n'
    printf '# Tags: fixture, parallel, scope:issue-specific\n'
    printf 'sleep 2\n'
    printf 'exit 0\n'
} > "$E/tests/$EVIL_BASE"
chmod +x "$E/tests/$EVIL_BASE" 2>/dev/null || true

E_OUT="$FX_TMP_ROOT/e.out"; E_ERR="$FX_TMP_ROOT/e.err"
EP_OUT="$FX_TMP_ROOT/ep.out"; EP_ERR="$FX_TMP_ROOT/ep.err"
FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$E" 90 "$E_OUT" "$E_ERR" -j 1 --all
E_EXEC="$(fx_contract_field "$E_OUT" EXECUTED)"
fx_exec "$E" 60 "$EP_OUT" "$EP_ERR" --print-plan --all
FX_LEDGER_KEEP=0

E_LIT=0
fx_ledger_cat | grep -qF -- "$EVIL_BASE" && E_LIT=1
E_EXPANDED=0
fx_ledger_cat | grep -qF -- "$EVIL_SUBST" && E_EXPANDED=1
grep -qF -- "$EVIL_SUBST" "$E_OUT" "$E_ERR" "$EP_OUT" "$EP_ERR" 2>/dev/null && E_EXPANDED=1
E_TIER="$(awk -F'\t' '$1 == "plan" { print $5; exit }' "$EP_OUT")"

if [ "$E_EXEC" = "1" ]; then
    fx_pass "N31b. the fixture is real: the metacharacter-named dummy was executed"
else
    fx_fail "N31b. the fixture is not usable — want EXECUTED=1 for the metacharacter filename, got ${E_EXEC:-absent}"
    fx_show_tail "$E_ERR" 6
fi

if dur_missing "N31. a metacharacter filename is keyed verbatim by the writer"; then
    fx_fail "N31c. the same filename is looked up as measured on the next run (implementation missing: $DUR_LIB_REL)"
else
    if [ "$E_LIT" = "1" ] && [ "$E_EXPANDED" = "0" ]; then
        fx_pass "N31. the record key holds the filename verbatim and the substituted spelling appears nowhere"
    else
        fx_fail "N31. want the literal key present and '$EVIL_SUBST' absent from the ledger and all four streams, got literal=$E_LIT expanded-seen=$E_EXPANDED"
    fi
    if [ -n "$E_TIER" ] && [ "$E_TIER" != "$UNMEASURED" ]; then
        fx_pass "N31c. the next plan reported a measured tier ($E_TIER), so the hostile key round-tripped"
    else
        fx_fail "N31c. want a plan tier other than $UNMEASURED for the metacharacter test, got '${E_TIER:-absent}'"
    fi
fi

# ===========================================================================
# N32 — an unmeasured test leads the plan, including on a completely cold ledger
# ===========================================================================
# N5 adds ONE new test to a warm ledger. The two cases that actually happen in practice are
# the first-ever run (nothing measured) and a batch of new tests arriving together.
C="$(fx_new_root)"
fx_add_dummy "$C" e1 --sleep 4
fx_add_dummy "$C" e2 --sleep 2
fx_add_dummy "$C" e3 --sleep 6
C_OUT="$FX_TMP_ROOT/c.out"; C_ERR="$FX_TMP_ROOT/c.err"

fx_exec "$C" 60 "$C_OUT" "$C_ERR" --print-plan --all
C_RC=$?
C_ORDER="$(plan_names "$C_OUT")"
C_TIERS="$(plan_tiers "$C_OUT")"

if [ "$C_RC" -eq 0 ] && [ "$C_ORDER" = "e1.sh e2.sh e3.sh " ]; then
    fx_pass "N32d. a cold ledger left the plan in glob order at exit 0"
else
    fx_fail "N32d. want exit 0 and order 'e1.sh e2.sh e3.sh ' from a cold ledger, got exit $C_RC order='$C_ORDER'"
    fx_show_tail "$C_ERR" 6
fi

if dur_missing "N32a. every row of a cold-ledger plan carries the unmeasured tier"; then :
elif [ "$C_TIERS" = "$UNMEASURED $UNMEASURED $UNMEASURED " ]; then
    fx_pass "N32a. all three rows of the cold-ledger plan reported tier $UNMEASURED"
else
    fx_fail "N32a. want tiers '$UNMEASURED $UNMEASURED $UNMEASURED ' on a cold ledger, got '$C_TIERS'"
fi

B="$(fx_new_root)"
fx_add_dummy "$B" b1 --sleep 2
fx_add_dummy "$B" b2 --sleep 8
BW_OUT="$FX_TMP_ROOT/bw.out"; BW_ERR="$FX_TMP_ROOT/bw.err"
BP_OUT="$FX_TMP_ROOT/bp.out"; BP_ERR="$FX_TMP_ROOT/bp.err"

FX_LEDGER_KEEP=1
fx_ledger_clear
fx_exec "$B" 120 "$BW_OUT" "$BW_ERR" -j 2 --all
B_EXEC="$(fx_contract_field "$BW_OUT" EXECUTED)"
fx_add_dummy "$B" a1 --sleep 1
fx_add_dummy "$B" a2 --sleep 1
fx_add_dummy "$B" a3 --sleep 1
fx_exec "$B" 60 "$BP_OUT" "$BP_ERR" --print-plan --all
FX_LEDGER_KEEP=0
B_ORDER="$(plan_names "$BP_OUT")"
B_TIERS="$(plan_tiers "$BP_OUT")"

if [ "$B_EXEC" = "2" ]; then
    fx_pass "N32c. the fixture is real: the warm-up measured both existing dummies"
else
    fx_fail "N32c. the fixture is not usable — want EXECUTED=2 in the warm-up, got ${B_EXEC:-absent}"
    fx_show_tail "$BW_ERR" 6
fi

# Glob order would be a1 a2 a3 b1 b2, so this order cannot be reached by leaving the list alone.
if dur_missing "N32b. three unmeasured tests form one leading block ahead of the measured ones"; then :
elif [ "$B_EXEC" = "2" ] && [ "$B_ORDER" = "a1.sh a2.sh a3.sh b2.sh b1.sh " ] && \
     [ "$B_TIERS" = "$UNMEASURED $UNMEASURED $UNMEASURED 3 1 " ]; then
    fx_pass "N32b. the three new tests led at tier $UNMEASURED, then b2 (8s) then b1 (2s)"
else
    fx_fail "N32b. want order 'a1.sh a2.sh a3.sh b2.sh b1.sh ' with tiers '$UNMEASURED $UNMEASURED $UNMEASURED 3 1 ', got order='$B_ORDER' tiers='$B_TIERS'"
fi

fx_finish
