# tests/fix-1630-overlay-cross-validation/mutation.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, config-dir, overlay, mutation, security, scope:issue-specific
#
# STATUS: RED until C5 lands. Sourced by tests/fix-1630-overlay-cross-validation.sh.
#   MUT-real-*   — RED: the three-way check does not exist, so a mismatch that
#                  must return null is still identified today.
#   MUT-kill-*   — RED: the probe prints NO-MUTATION-SITE while there is no
#                  equality to delete. That is the intended failure signal, not
#                  a skip — the row can only pass once the equality is present
#                  AND load-bearing.
#
# Why this file exists (C7): the XV-* families in the parent file are hook-level
# BLOCK rows that were ALREADY block before C5, so none of them can fail if C5
# is implemented with one of the two equalities missing. This file is the
# mutation-sensitive counterpart: for each equality of
#
#     anchorAcd === derivedAcd && anchorAcd === payloadAcd
#
# there is a case where the real module must return null and a mutant with that
# one equality deleted returns the matched script. Deleting an equality
# therefore cannot go unnoticed.
#
# The mutant is compiled in memory by tests/fixtures/finalize-overlay-probe.js
# under the original filename (so the module's own requires resolve); nothing is
# written to the repo.

run_mutation_cases() {
    local acd repo scripts evil evil_scripts
    acd="$(setup_fake_acd "mut")"
    repo="$(setup_main_worktree "mut")"
    scripts="$acd/skills/issue-close-finalize/scripts"

    # Sibling-prefix lookalike root, marker-valid, carrying the same registry
    # script — the derived root the attacker wants accepted.
    local evil_raw="$TMPDIR_BASE/fake-acd-mut-evil"
    mkdir -p "$evil_raw/skills/issue-close-finalize/scripts" "$evil_raw/bin" "$evil_raw/hooks"
    touch "$evil_raw/hooks/enforce-worktree.js" \
          "$evil_raw/skills/issue-close-finalize/scripts/run-initial.sh"
    if command -v cygpath >/dev/null 2>&1; then evil="$(cygpath -m "$evil_raw")"; else evil="$evil_raw"; fi
    evil_scripts="$evil/skills/issue-close-finalize/scripts"

    # anchor  = AGENTS_CONFIG_DIR in the hook's own environment ($acd throughout)
    # payload = the inline AGENTS_CONFIG_DIR="..." inside the eval text
    # derived = stripRelSuffix(<invoked script path>, entry.rel)
    local c_agree c_derived c_payload c_anchor
    c_agree="$(build_initial   "$acd"  "$scripts" "$repo" "$scripts")"
    c_derived="$(build_initial "$acd"  "$scripts" "$repo" "$evil_scripts")"
    c_payload="$(build_initial "$evil" "$scripts" "$repo" "$scripts")"
    c_anchor="$(build_initial  "$evil" "$evil_scripts" "$repo" "$evil_scripts")"

    mut_probe() {
        local mutation="$1" cmd="$2"
        AGENTS_CONFIG_DIR="$acd" run_with_timeout 30 \
            node "$OVERLAY_PROBE" mutmatch "$mutation" "$cmd" "$repo" 2>&1
    }

    # ── The real module: one row per mismatch axis ───────────────────────────
    assert_eq "MUT-real-agree all three roots agree -> identified" \
        "$(mut_probe none "$c_agree")" "run-initial.sh"
    assert_eq "MUT-real-derived script path implies a different root -> null" \
        "$(mut_probe none "$c_derived")" "null"
    assert_eq "MUT-real-payload inline AGENTS_CONFIG_DIR differs from the anchor -> null" \
        "$(mut_probe none "$c_payload")" "null"
    assert_eq "MUT-real-anchor payload and derived agree but the anchor does not -> null" \
        "$(mut_probe none "$c_anchor")" "null"

    # ── Mutants: each deleted equality must be caught by a real-module row ────
    # Killing rows — the mutant ACCEPTS what the real module rejects, proving the
    # equality is individually load-bearing and individually covered.
    assert_eq "MUT-kill-derived deleting anchor===derived accepts the lookalike root" \
        "$(mut_probe drop-derived "$c_derived")" "run-initial.sh"
    assert_eq "MUT-kill-payload deleting anchor===payload accepts the mismatched inline value" \
        "$(mut_probe drop-payload "$c_payload")" "run-initial.sh"

    # Cross rows — a mutant must NOT accept the case guarded by the OTHER
    # equality, otherwise the two killing rows above would be interchangeable and
    # would not pin the equalities separately.
    assert_eq "MUT-cross-derived the derived mutant still rejects a payload mismatch" \
        "$(mut_probe drop-derived "$c_payload")" "null"
    assert_eq "MUT-cross-payload the payload mutant still rejects a derived mismatch" \
        "$(mut_probe drop-payload "$c_derived")" "null"

    # Anti-vacuity — a mutant must keep the happy path working, so the killing
    # rows above cannot be explained by the mutation simply breaking the module.
    assert_eq "MUT-live-derived the derived mutant still identifies the agreeing command" \
        "$(mut_probe drop-derived "$c_agree")" "run-initial.sh"
    assert_eq "MUT-live-payload the payload mutant still identifies the agreeing command" \
        "$(mut_probe drop-payload "$c_agree")" "run-initial.sh"

    # Documented limit: the anchor-mismatch case retains one equality under EITHER
    # mutation, so it kills neither mutant on its own. It is asserted (fail-closed
    # in every variant) but is deliberately not relied on for mutation coverage.
    assert_eq "MUT-cross-anchor the derived mutant still rejects an anchor mismatch" \
        "$(mut_probe drop-derived "$c_anchor")" "null"
    assert_eq "MUT-cross-anchor the payload mutant still rejects an anchor mismatch" \
        "$(mut_probe drop-payload "$c_anchor")" "null"
}
