#!/usr/bin/env bash
# filename: tests/fix-1756-next-step-fail-open-settled/settled-predicate.sh
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io.js, bin/workflow/next-step
# Tags: workflow, next-step, settled-status, table-driven, structural, TL2, scope:common
#
# Case file — sourced by tests/fix-1756-next-step-fail-open-settled.sh, which
# owns every helper and runs the shared module probe ($PROBE_OUT / s1_row).
# Do not run standalone.
#
# S1 + S2 are RED until the helper extraction ships.

# ---------------------------------------------------------------------------
# S1 (table-driven): assert isSettledStatus() over its whole input domain,
# through the PUBLIC export surface (hooks/workflow-state) rather than the
# internal state-io/core.js path — the re-export is part of the contract.
# Return values must be strict booleans, so a truthy/falsy implementation (or an
# accidental `undefined` for unknown input) is caught here, not at a call site.
#
# The probe degrades gracefully: if the module cannot be required, or the export
# is missing, every row reports NO-HELPER and fails individually instead of
# aborting the run.
# ---------------------------------------------------------------------------
check_eq "S1: isSettledStatus(\"complete\") === true"     "true"  "$(s1_row complete)"
check_eq "S1: isSettledStatus(\"skipped\") === true"      "true"  "$(s1_row skipped)"
check_eq "S1: isSettledStatus(\"pending\") === false"     "false" "$(s1_row pending)"
check_eq "S1: isSettledStatus(\"in_progress\") === false" "false" "$(s1_row in_progress)"
check_eq "S1: isSettledStatus(undefined) === false"       "false" "$(s1_row undefined)"
check_eq "S1: isSettledStatus(null) === false"            "false" "$(s1_row null)"
check_eq "S1: isSettledStatus(\"\") === false"            "false" "$(s1_row empty)"
check_eq "S1: isSettledStatus(\"bogus\") === false"       "false" "$(s1_row bogus)"

# ---------------------------------------------------------------------------
# S2 (structural): pin the EXTRACTION itself — core.js owns the predicate, both
# barrels re-export the SAME function reference (not a re-implementation), the
# verdict logic calls it at all four sites, and no inline settled-status
# comparison survives. Without S2 every behavioral case would still pass if only
# the terminal-bug line were patched and the three other inline comparisons left
# alone.
#
# Two surviving comparisons are deliberately NOT matched by either regex, because
# neither is a settled-status test and both must remain after the fix:
#   - bin/workflow/next-step:268  `s === "skipped"` — the --list marker branch
#     (3-way complete/skipped/current dispatch), explicitly out of scope per the
#     implementation plan. No `.status` receiver, so inline_terminal cannot match.
#   - bin/workflow/next-step:379  `rawEntry.status === "skipped" &&` — the
#     recorded-verdict discriminator, a genuine "is skipped" test. It is followed
#     by `&&`, not by `) continue`, so inline_terminal cannot match it either.
# Both regexes are live rather than vacuous: against today's source they read
# inline_pair=3 (the three `!== "complete" && !== "skipped"` sites) and
# inline_terminal=1 (the #1756 bug line).
# ---------------------------------------------------------------------------
check_eq "S2a: state-io/core.js defines and exports isSettledStatus" "yes" "$(s1_row core_export)"
check_eq "S2b: state-io.js re-exports isSettledStatus" "yes" "$(s1_row barrel_export)"
check_eq "S2c: hooks/workflow-state.js re-exports isSettledStatus" "yes" "$(s1_row outer_export)"
check_eq "S2c: outer barrel yields the SAME function reference as core.js (no re-implementation)" \
    "yes" "$(s1_row same_ref)"
check_min "S2d: verdict logic calls isSettledStatus at 4+ sites" 4 "$(s1_row callsites)"
check_eq "S2e: no inline '!== complete && !== skipped' comparison remains" "0" "$(s1_row inline_pair)"
check_eq "S2e: no inline terminal '.status === skipped) continue' comparison remains" \
    "0" "$(s1_row inline_terminal)"

# CLI counterpart: an unrecognized on-disk status must never be treated as
# settled — next-step aborts on it. Green today and after the fix.
S1_SID="$(new_sid s1)"
write_state "$S1_SID" "{$HEAD_COMPLETE,$RV_OUTLINE,\"detail\":{\"status\":\"complete\"},$TAIL_WTS_BOGUS}"
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
S1_CLI_OUT="$(run_next_step --session "$S1_SID")"
eval "$S1_CLI_OUT" 2>/dev/null || true
check_eq "S1: unknown write_tests status on disk → ACTION=abort (never silently settled)" \
    "abort" "${ACTION:-}"
check_contains "S1: abort REASON names the unknown status" "write_tests" "${REASON:-}"
