# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, owned-names
# The library-owned FUNCTION set, derived rather than transcribed (CPR-SSOT). bin/lib/
# concern-ledger.sh owns those names; a list typed here would be a second owner that ages
# the moment a module gains a helper, and the aged copy keeps passing. The derivation is
# a `declare -F` diff across the load in a fresh bash — the same evidence the guard works
# from. G5n is the non-vacuity floor: a derivation that yields nothing turns every
# owned-name case below into a loop over an empty list, green under any implementation.

NSG_MIN_OWNED=40
NSG_DERIVE="$WORK/derive-owned.sh"
cat > "$NSG_DERIVE" <<'DERIVE_EOF'
#!/usr/bin/env bash
# <library> <workdir> — one library-owned function name per line.
set +u
declare -F | awk '{print $3}' | sort > "$2/fn-before.txt"
. "$1" >/dev/null 2>&1
declare -F | awk '{print $3}' | sort > "$2/fn-after.txt"
comm -13 "$2/fn-before.txt" "$2/fn-after.txt"
DERIVE_EOF

NSG_OWNED="$WORK/owned-fn.txt"
: > "$NSG_OWNED"
bash "$TIMEOUT" 60 bash "$NSG_DERIVE" "$LIB" "$WORK" > "$NSG_OWNED" 2>/dev/null || true
NSG_OWNED_N="$(grep -c . "$NSG_OWNED" || true)"
NSG_ALL_NAMES="$(tr '\n' ' ' < "$NSG_OWNED")"
export NSG_ALL_NAMES
# The private surface G3p iterates, taken from the same derivation instead of retyped.
# Spread across the sorted list rather than its head: `head -5` would hand G3p five
# neighbours from one module, and a guard that records only the first module still passes.
NSG_PRIV="$WORK/owned-private.txt"
grep -E '^_cl_' "$NSG_OWNED" > "$NSG_PRIV" || true
_nsg_p="$(grep -c . "$NSG_PRIV" || true)"
NSG_SAMPLE_PRIVATE="$(awk -v p="$_nsg_p" 'BEGIN { s = int(p / 5); if (s < 1) s = 1 } (NR - 1) % s == 0' \
    "$NSG_PRIV" | head -5 | tr '\n' ' ')"

echo ""
echo "=== G5n: the owned-name derivation is real, so the cases over it are not vacuous ==="
if [[ "$NSG_OWNED_N" -ge "$NSG_MIN_OWNED" ]]; then
    pass "G5n-a: sourcing the library adds $NSG_OWNED_N function name(s), at or above the floor of $NSG_MIN_OWNED"
else
    fail "G5n-a: the declare -F diff across the library load yielded $NSG_OWNED_N name(s), under the floor of $NSG_MIN_OWNED — every owned-name case below would then iterate an empty or near-empty list and pass under any implementation"
fi
_g5n_foreign="$(grep -vE '^(_?cl_|_?sp_)' "$NSG_OWNED" | tr '\n' ' ' || true)"
if [[ -z "$_g5n_foreign" ]]; then
    pass "G5n-b: every derived name carries a library prefix, so nothing foreign entered the owned set"
else
    fail "G5n-b: the derivation collected name(s) the library does not own: $_g5n_foreign — the before/after capture is picking up the deriving shell's own functions, and the cases below would demand reports for them"
fi
_g5n_missing=""
for _n in cl_slot cl_reduce cl_finalize _cl_norm _cl_sev_max _cl_load_ledger _cl_next_id _cl_json_spec; do
    grep -qxF -- "$_n" "$NSG_OWNED" || _g5n_missing="$_g5n_missing $_n"
done
if [[ -z "$_g5n_missing" ]]; then
    pass "G5n-c: the derived set spans core.sh, parse.sh, reduce.sh and finalize.sh by name"
else
    fail "G5n-c: the derivation missed:$_g5n_missing — the named cases would then probe a name that is not in the set the guard is asked to own, and their verdicts would mean nothing"
fi
_g5n_sample_n=$(printf '%s' "$NSG_SAMPLE_PRIVATE" | wc -w | tr -d '[:space:]')
if [[ "$_g5n_sample_n" == "5" ]]; then
    pass "G5n-d: the private-surface sample G3p iterates holds 5 derived name(s)"
else
    fail "G5n-d: the derived _cl_* sample holds $_g5n_sample_n name(s), not 5 — G3p's loop shrinks with it and takes its cases away without a word"
fi

# expect_all_owned_reported <label> <mode> — the whole derived set, clobbered in one
# process, must come back reported exactly once each. The tokens are counted over the
# guard's OWN `FAIL: namespace collision …` lines, not over $NSG_REPORT: the guard prints
# them itself and never routes through the replaceable harness fail(). Occurrences, not
# matching lines: `tr -c` puts each identifier on its own line so `grep -cxF` counts exactly.
expect_all_owned_reported() {
    local label="$1" mode="$2" bad="" n c toks
    if [[ "$NSG_OWNED_N" -lt "$NSG_MIN_OWNED" ]]; then
        fail "$label — the owned-name derivation yielded only $NSG_OWNED_N name(s), so this check would grade an empty list (see G5n-a)"
        return 0
    fi
    run_scenario "$mode"
    toks="$WORK/owned-tokens.txt"
    printf '%s\n' "$SC_COLLISION" | tr -c 'A-Za-z0-9_' '\n' > "$toks"
    for n in $NSG_ALL_NAMES; do
        c=$(grep -cxF -- "$n" "$toks" || true)
        [[ "$c" == "1" ]] || bad="$bad $n=$c"
    done
    if [[ -n "$SC_REPORT" ]]; then
        fail "$label — the reports travelled through the harness fail(), which one line in a case file can turn into a no-op: $(brief "$SC_REPORT")"
    elif [[ -n "$SC_NOISE" || "$SC_RC" != "0" ]]; then
        fail "$label — the scenario exited $SC_RC after writing $(printf '%s' "$SC_NOISE" | wc -c | tr -d '[:space:]') byte(s) of non-report output to stdout/stderr; the guard prints its collision lines and never exits: $(brief "$SC_NOISE")"
    elif [[ -z "$bad" ]]; then
        pass "$label (all $NSG_OWNED_N derived name(s), one report each)"
    else
        fail "$label — want exactly one report per derived name, got:$(printf '%s' "$bad" | cut -c1-220) (0 = the name is not in the guard's owned set; >1 = the same name reported repeatedly at one check point). Report: $(brief "$SC_COLLISION")"
    fi
}
