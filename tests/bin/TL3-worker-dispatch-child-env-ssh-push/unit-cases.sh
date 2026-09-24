# Part of tests/TL3-worker-dispatch-child-env-ssh-push.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, ssh-agent, commit-push, buildenv, TL3, scope:common
# Shell side of the ungated stage-1 buildEnv cases. The names are listed here
# as well as in the probe so a case silently deleted from either side is a
# reported failure rather than a smaller, still-green run.
UNIT_CASES=(
    "commit-push/ssh-auth-sock-reaches-child"
    "commit-push/ssh-agent-pid-does-not-reach-child"
    "commit-push/ssh-auth-sock-value-is-copied-verbatim"
    "commit-push/ssh-auth-sock-absent-is-omitted-not-blanked"
    "commit-push/ssh-auth-sock-empty-value-is-preserved"
    "commit-push/declared-name-control-enforce-worktree"
    "commit-push/undeclared-secret-does-not-reach-child"
    "doc-append/ssh-auth-sock-stays-out-of-a-non-pushing-worker"
    "allowlist/ssh-names-stay-out-of-the-global-child-env-allowlist"
    "commit-push/agents-config-dir-is-forced-not-inherited"
    "commit-push/buildenv-is-idempotent-and-non-mutating"
    "commit-push/undeclared-extraenv-is-rejected"
)

run_unit_cases() {
    local n got count
    if ! run_probe unit commit-push; then
        fail "unit/probe-ran-to-completion — $PROBE_OUT"
        return
    fi
    for n in "${UNIT_CASES[@]}"; do
        got="$(pv "U__$n")"
        if [ -z "$got" ]; then
            fail "unit/$n — the probe reported no result for this case"
        elif [ "$got" = "ok" ]; then
            pass "unit/$n"
        else
            fail "unit/$n — $got"
        fi
    done
    # Non-vacuity: a probe that emitted fewer cases than this table lists (or
    # more) is not the suite these assertions claim to have run.
    count="$(pv unit_case_count)"
    assert_eq "unit/case-count-matches-the-table" "${#UNIT_CASES[@]}" "$count"
}
