# tests/feature-2119-settings-allow-ssot/precommit-synchronized.sh
# Tests: hooks/pre-commit, bin/review-settings-allow, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T24: the WHOLE chain, with no stub anywhere in it. Sourced AFTER precommit-real-commit.sh,
# whose wire_real_hook / commit_verdict / commit_count helpers this part reuses.

T24_SYNC=""
T24_ALLOWED=""
T24_RECORDED=""
T24_SSOT=""
T24_GEN=""

# WHY THIS EXISTS ALONGSIDE T8 AND T20. The two families split the chain in half and neither
# half is the product. T20 drives a real `git commit` but through a hand-written reviewer stub,
# so it pins the git wiring while proving nothing about what the real reviewer would say. T8/T9
# run the real reviewer, but T8 calls hooks/pre-commit directly and its fixture carries no
# settings.json, no PATH SSOT and no command files, so the real reviewer can only ever reach
# its failure paths there. Nothing else in the suite sees the real generator agree with a real
# settings.json, hand that agreement to the real reviewer, and have git let the commit through
# -- so a generator that never emits rc=0 on a synchronized tree, or a reviewer that inverts
# its verdict, passes both existing families today.
mk_synced_repo() { # <name> -> dir
    local dir
    dir="$(mk_hook_repo "$1" real no no)"
    cp "$GEN" "$dir/install/gen-settings-allow.js"
    printf '%s\n%s\n' '# fixture PATH-exposed list (never the real one)' 'fx-sync-path' \
        > "$dir/install/path-exposed-commands.txt"
    mk_tool "$dir" bin/fx-sync-bash env-bash
    mk_tool "$dir" bin/fx-sync-node.js env-node
    mk_tool "$dir" bin/fx-sync-path env-bash
    write_ssot "$dir" bin/fx-sync-bash bin/fx-sync-node.js bin/fx-sync-path
    write_settings "$dir" --
    # The real generator writes the fixture's settings.json, so the tree the gate later judges
    # is synchronized by the implementation itself rather than by this test's own expectations.
    run_gen "$dir" --write
    git -C "$dir" add -A
    # core.hooksPath is still /dev/null here (init_fixture_repo's default): the commit that
    # CREATES the fixture must not be judged by the gate under test. The hook is wired after.
    git -C "$dir" commit -q -m "synchronized fixture" 2>/dev/null
    wire_real_hook "$dir"
    printf '%s\n' "$dir"
}

# The three commits run in sequence against ONE repository, with the tree restored in between,
# because "only the SSOT is gone" and "only the generator is gone" are claims about a single
# difference from a known-good state -- two independent repos would each carry their own setup
# as a confound. `blocked-by-gate` (not "non-zero") is the assertion, reusing precommit.sh's
# discrimination: a commit that died of anything else is not evidence about this gate.
t24_setup() {
    have_gen || return 0
    have_review || return 0
    local repo before
    repo="$(mk_synced_repo t24-synced)"

    run_gen "$repo" --check
    if [ "$GEN_RC" -eq 0 ]; then T24_SYNC="in-sync"; else T24_SYNC="DRIFTED:$GEN_OUT"; fi

    before="$(commit_count "$repo")"
    T24_ALLOWED="$(commit_verdict "$repo" "$repo")"
    if [ "$(commit_count "$repo")" = "$((before + 1))" ]; then T24_RECORDED="yes"; else T24_RECORDED="no"; fi

    git -C "$repo" rm -q -f install/settings-allow-commands.txt
    T24_SSOT="$(commit_verdict "$repo" "$repo")"
    git -C "$repo" reset -q --hard HEAD

    git -C "$repo" rm -q -f install/gen-settings-allow.js
    T24_GEN="$(commit_verdict "$repo" "$repo")"
    git -C "$repo" reset -q --hard HEAD
}

t24_probe() { # <id> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    have_review || { missing_review; return; }
    case "$1" in
        sync)     printf '%s' "$T24_SYNC" ;;
        allowed)  printf '%s' "$T24_ALLOWED" ;;
        recorded) printf '%s' "$T24_RECORDED" ;;
        ssot)     printf '%s' "$T24_SSOT" ;;
        gen)      printf '%s' "$T24_GEN" ;;
    esac
}

t24_full_chain_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T24[$id]: $label" "$want" "$(t24_probe "$id")"
    done <<'T24_CASES'
sync|in-sync|PRECONDITION: the real generator agrees the settings.json it just wrote is synchronized (a fixture never in sync could produce no evidence about the two deletions)
allowed|allowed|the real generator, real reviewer and real hook let a real `git commit` through on a fully synchronized tree
recorded|yes|and the commit object is recorded, so "allowed" is not a hook that silently refused to write
ssot|blocked-by-gate|COMMIT 2 -- deleting ONLY install/settings-allow-commands.txt from that same tree refuses the commit, and refuses it as THIS gate
gen|blocked-by-gate|COMMIT 3 -- deleting ONLY install/gen-settings-allow.js does the same: a fail-closed gate cannot be disabled by removing either of its inputs
T24_CASES
}

t24_setup
t24_full_chain_table
