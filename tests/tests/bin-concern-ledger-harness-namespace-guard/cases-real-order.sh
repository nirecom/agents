# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh, tests/bin-concern-ledger-reducer.sh
# Tags: concern-ledger, test-harness, namespace-guard, real-order, TL2, scope:common, real-order
# G13 — the dispatcher's REAL definition order. Every scenario above installs its
# stand-in harness names BEFORE clg_snapshot_before, but the three drivers every
# case file calls — cl(), run_cli(), reduce_round() — are defined after BOTH
# baselines, and the library's CL_SHA_TOOL is created later still by the
# cl_sha256 probe. A name in neither baseline is watched by neither direction, so
# the shapes below are exactly the ones a case file may replace for free.

echo ""
echo "=== G13: names born after the baselines the guard takes ==="

# G13w — the covered side of the boundary. A name defined between
# clg_snapshot_before and clg_record_library_names lands in the library's derived
# set by the declare -F diff, so it IS watched; the boundary is only meaningful
# once the last covered position is pinned.
expect_report "G13w: a helper defined in the window between the two baselines is in the library-derived set and its shadowing is reported" \
    G13w "hx_window" "ctx-G13w"

# G13n — the negative control the three below are meaningless without: a
# post-baseline name that nobody touched must stay silent.
expect_silent "G13n: a helper defined after both baselines, left alone, keeps both directions silent" G13n

# G13a/G13z — cl/run_cli/reduce_round's own shape (defined after
# clg_record_library_names), overwritten and then made to disappear. A case file
# that redefines cl() re-points every later library call in the suite.
expect_report "G13a: overwriting a harness driver defined after clg_record_library_names (cl/run_cli/reduce_round's real position) is reported" \
    G13a "hx_late" "ctx-G13a"
expect_report "G13z: unsetting a harness driver defined after clg_record_library_names is reported" \
    G13z "hx_late" "ctx-G13z"

# G13s — CL_SHA_TOOL, the library scalar the cl_sha256 probe creates lazily, after
# the guard has already recorded the library's names. A case file that pins it to
# a tool that is not installed changes every discriminator the suite computes.
expect_report "G13s: shadowing the lazily-created library scalar CL_SHA_TOOL is reported" \
    G13s "CL_SHA_TOOL" "ctx-G13s"

# G14 — clg_close_window is proven to actually DISARM the DEBUG trap, not merely to
# exist. G13w above proves the trap fires while the window is open; this is its
# uncovered other half: after the first real check point (clg_assert_harness_intact,
# which calls clg_close_window before anything else), `trap -p DEBUG` must come back
# completely empty. A trap left armed would keep paying the per-command declare -F +
# file-write cost #2111 exists to remove, on every command every later case file runs.
run_scenario G14
if ! printf '%s\n' "$SC_OUT" | grep -qxF 'NSG-DONE=G14'; then
    fail "G14: scenario did not reach its end marker — output: $(brief "$SC_OUT")"
elif printf '%s\n' "$SC_OUT" | grep -qE '^NSG-TRAP=.+DEBUG'; then
    fail "G14: trap -p DEBUG still reports an armed handler after clg_close_window ran: $(brief "$SC_OUT")"
elif [[ -n "$SC_COLLISION" ]]; then
    fail "G14: an untouched namespace reported a collision — the disarm probe itself perturbed something: $(brief "$SC_COLLISION")"
else
    pass "G14: clg_close_window actually removes the DEBUG trap — trap -p DEBUG is empty once the first real check point has run"
fi
