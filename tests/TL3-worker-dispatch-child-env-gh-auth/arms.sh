# Part of tests/TL3-worker-dispatch-child-env-gh-auth.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# The dispatched arms. ARM_TABLE is the single source of truth for which arms
# exist, what each expects, whether it counts toward the exit contract, and
# where it applies; run_arm_table() is the only reader, and REQUIRED is
# derived from it rather than written down twice.
# run_control_arms() stays hand-written: arms 5-6 are a premise and its
# dependent, not two instances of one shape — folding that conditional
# dependency into a row would hide the thing that makes the pair conclusive.

run_arm_table() {
    local a_name a_kind a_env a_want a_req a_plat a_extra _tok
    local _a_kind _a_env _a_want
    # Arms 1-4 and 7 — one table, one loop.
    # Arm 1 is #1719 itself: a dispatched child, inheriting the parent's config
    # location vars, must reach the same hosts.yml the gate just read.
    # Arms 2-4 prove REACHABILITY by REDIRECTION, not removal: removing a var
    # can't prove it was reaching the child (POSIX falls XDG_CONFIG_HOME back
    # to HOME anyway), but pointing it at an empty dir makes the two outcomes
    # distinguishable on every platform — reached => unauthenticated empty
    # dir, not reached => still reading the parent's real config.
    # Arm 7 asks arm 1's question of the REAL registry entry (issue-reconcile)
    # rather than the synthetic one — only this row proves the property for an
    # entry the operator actually dispatches, which is what #1719 broke in
    # production. issue-reconcile declares GH_TOKEN/GITHUB_TOKEN, but
    # STRIP_CREDS removes them from every row's parent env, so an ambient
    # token can't substitute for the config path here.
    #
    # Columns: name, kind (synthetic|registry entry), env (parent-env
    # manipulation handed to `env`; `@EMPTY@` expands to the empty gh config
    # dir AFTER splitting so a space in the temp path can't break the row),
    # want (expected class), req (1=counted into REQUIRED/PROVEN), platform
    # (any|windows — data, not a branch; APPDATA is Windows-only), extra
    # (additional assert name, or `-`).
    ARM_TABLE=$(cat <<'TABLE'
    env/dispatched-child-resolves-auth | synthetic |                                                        | authenticated   | 1 | any     | env/dispatcher-really-started-gh
    env/gh-config-dir-reaches-child    | synthetic | GH_CONFIG_DIR=@EMPTY@                                  | unauthenticated | 1 | any     | -
    env/xdg-config-home-reaches-child  | synthetic | -u GH_CONFIG_DIR XDG_CONFIG_HOME=@EMPTY@               | unauthenticated | 1 | any     | -
    env/appdata-reaches-child          | synthetic | -u GH_CONFIG_DIR -u XDG_CONFIG_HOME APPDATA=@EMPTY@    | unauthenticated | 1 | windows | -
    env/real-gh-worker-resolves-auth   | registry  |                                                        | authenticated   | 1 | any     | -
TABLE
    )

    # arm_applies <platform-cell>
    arm_applies() {
        case "$1" in
            any) return 0 ;;
            windows) [ "$IS_WINDOWS" = "1" ] ;;
            *) return 1 ;;
        esac
    }

    # Pass 1 — REQUIRED is DERIVED from applicable required rows, never a
    # literal, so a row added/removed/made-optional moves it automatically.
    ARM_ROWS=0
    REQUIRED=0
    while IFS='|' read -r a_name _a_kind _a_env _a_want a_req a_plat _a_extra; do
        a_name="$(trim "$a_name")"
        [ -z "$a_name" ] && continue
        ARM_ROWS=$((ARM_ROWS + 1))
        if arm_applies "$(trim "$a_plat")" && [ "$(trim "$a_req")" = "1" ]; then
            REQUIRED=$((REQUIRED + 1))
        fi
    done <<< "$ARM_TABLE"

    # Non-vacuity: an emptied/mis-delimited table would derive REQUIRED=0 and
    # let the run exit 0 having proved nothing.
    assert_eq "arms/table-non-vacuous" "5" "$ARM_ROWS"
    if [ "$REQUIRED" -gt 0 ]; then
        pass "arms/required-derived-from-table"
    else
        fail "arms/required-derived-from-table — REQUIRED=$REQUIRED derived from $ARM_ROWS rows"
    fi

    # Pass 2 — run them.
    while IFS='|' read -r a_name a_kind a_env a_want a_req a_plat a_extra; do
        a_name="$(trim "$a_name")"
        [ -z "$a_name" ] && continue
        a_kind="$(trim "$a_kind")"; a_want="$(trim "$a_want")"; a_req="$(trim "$a_req")"
        a_plat="$(trim "$a_plat")"; a_extra="$(trim "$a_extra")"
        if ! arm_applies "$a_plat"; then
            skip "$a_name — $a_plat-only row: gh does not consult that variable elsewhere"
            continue
        fi
        # Split first, substitute second: the fixture path is never word-split.
        ARM_ENV=()
        read -r -a _arm_raw <<< "$(trim "$a_env")"
        for _tok in ${_arm_raw[@]+"${_arm_raw[@]}"}; do
            ARM_ENV+=("${_tok//@EMPTY@/$EMPTY_CFG}")
        done
        if run_probe dispatch "$a_kind" ${ARM_ENV[@]+"${ARM_ENV[@]}"}; then
            expect_class "$a_name" "$a_want" "$a_req"
            # Same credential condition as the gate, measured per row (not
            # assumed from STRIP_CREDS) on the env buildEnv() constructs fresh
            # for the DISPATCHED gh child.
            if [ "$(pv child_env_measured)" = "1" ]; then
                assert_eq "$a_name/credential-free" "1" "$(pv creds_absent)"
                assert_eq "$a_name/credential-check-measured-at-the-gh-child" "dispatch" "$(pv env_site)"
            else
                # No gh child started, so no child env to measure — claiming
                # "credential-free" off an unobserved child would be a false green.
                skip "$a_name/credential-free — no gh child was started (class=$(pv class) spawn_error=$(pv spawn_error))"
            fi
            # Non-vacuity: classification is only meaningful if a gh child
            # really started (a spawn failure classifies as inconclusive too).
            if [ "$a_extra" != "-" ]; then
                assert_eq "$a_extra" "0" "$(pv spawn_error)"
            fi
        else
            fail "$a_name — probe failed: $PROBE_OUT"
            fail "$a_name/credential-free — probe failed"
            if [ "$a_extra" != "-" ]; then
                fail "$a_extra — probe failed: $PROBE_OUT"
            fi
        fi
    done <<< "$ARM_TABLE"

}

run_control_arms() {
    # Arms 5-6 — the control. Arms 2-4 would also go unauthenticated if the
    # child env were simply empty, so something must show the allowlist
    # FILTERS rather than blanks. gh prefers an env token over the config
    # file, so a fake GH_TOKEN in the parent breaks a child that sees the
    # whole parent env, and is inert for a child whose entry never declared it.
    # Arm 5 measures the premise directly (no dispatcher); if this host
    # doesn't actually prefer the env token, arm 6 is skipped rather than
    # quietly reinterpreted.
    if run_probe direct synthetic "GH_TOKEN=$FAKE_GH_TOKEN"; then
        if [ "$(pv class)" = "authenticated" ]; then
            skip "env/undeclared-credential-does-not-leak — premise false: gh ignored the env token on this host"
        else
            pass "control/fake-token-breaks-direct-gh"
            if run_probe dispatch synthetic "GH_TOKEN=$FAKE_GH_TOKEN"; then
                expect_class "env/undeclared-credential-does-not-leak" "authenticated" 0
            else
                fail "env/undeclared-credential-does-not-leak — probe failed: $PROBE_OUT"
            fi
        fi
    else
        skip "env/undeclared-credential-does-not-leak — control probe did not run to completion"
    fi

}
