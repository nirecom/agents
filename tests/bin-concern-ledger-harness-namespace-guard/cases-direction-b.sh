# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, direction-b
# Direction B — a case file shadowing a name the library owns. The library is sourced
# once and nine case files land on top of it, so this is the direction that silently
# turns a real reducer call into whatever the last case file happened to define.

echo ""
echo "=== direction B: case file over library ==="
expect_report "G3: a library-owned function overwritten after load is reported" \
    G3 "cl_slot" "ctx-G3"
expect_silent "G4: an untouched library leaves direction B silent" G4
# G3x — G1z's counterpart on this side (CPR-ORTH). A case file that unsets cl_slot leaves
# the subshell calling a command that no longer exists; the guard must see the removal,
# not just a changed body.
expect_report "G3x: a library-owned function unset after load is reported" \
    G3x "cl_slot" "ctx-G3x"

# G3p — the private surface, one name per process. G3/G3x probe `cl_*` public entry
# points, so a guard that collects only names matching `cl_*` passes both while the
# `_cl_*` helpers those entry points call stay unwatched — and shadowing _cl_norm changes
# what a public call RETURNS without changing its name. The sample is DERIVED
# (owned-names.sh), so it follows the library instead of ageing against it; G5n-d fails
# if the derivation ever hands this loop fewer than five names to run.
for _lf in $NSG_SAMPLE_PRIVATE; do
    expect_report "G3p/$_lf: the library-private $_lf is in the owned set and its shadowing is reported" \
        "G3p-$_lf" "$_lf" "ctx-G3p-$_lf"
done

# G5all/G3u — the whole derived set, not a hand-picked six. A guard that records only the
# first module's names, or only the public prefix, leaves the rest unwatched and every
# fixed list lets it through; "exactly one report each" additionally pins the
# per-check-point de-duplication. G3u is the CPR-ORTH counterpart on the disappearance
# side: unsetting all of them must be as loud as overwriting all of them.
expect_all_owned_reported "G5all: every library-owned function overwritten after load is reported, exactly once each" G5all
expect_all_owned_reported "G3u: every library-owned function unset after load is reported, exactly once each" G3u
