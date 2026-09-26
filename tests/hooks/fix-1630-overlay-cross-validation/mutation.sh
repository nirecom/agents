# tests/fix-1630-overlay-cross-validation/mutation.sh
# Tests: hooks/enforce-worktree/arg-value-guard.js
# Tags: worktree, enforce, hook, config-dir, overlay, mutation, security, scope:issue-specific
#
# RETIRED BY #1673.
#
# This file used to carry the mutation-sensitive proof that BOTH equalities of
#
#     anchorAcd === derivedAcd && anchorAcd === payloadAcd
#
# inside matchFinalizeWorkerOverlay were individually load-bearing: for each one
# there was a command the real module must reject and a mutant with that single
# equality deleted that accepted it. #1673 deleted finalize-worker-overlay.js
# together with the Bash-tool `eval` path it guarded, so there is no longer a
# three-way cross-validation to mutate — the MUT-* rows could only report
# OVERLAY-RETIRED, which is a missing subject, not a verdict.
#
# Where the guarantee went: the dispatcher resolves script paths from a declared
# anchor in hooks/lib/worker-dispatch-registry.js instead of deriving a root from
# an attacker-visible command string, so the class of defect the mutation rows
# protected against (one of two agreement checks silently dropped) has no
# counterpart to protect. The anchor resolution itself is covered by
# tests/feature-1643-worker-dispatch-callers.sh and the TL3-worker-dispatch-*
# suites.
#
# The file is kept as an empty, explicitly-documented hook so the parent suite
# keeps its section structure and so this retirement is discoverable from the
# path the coverage used to live at, rather than vanishing from history.

run_mutation_cases() {
    :
}
