# Part of tests/TL3-worker-dispatch-child-env-ssh-push.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, ssh-agent, commit-push, real-environment, TL3, scope:common
# The dispatched arms, run against a REAL ssh-agent. Every row dispatches
# through the real registry entry named in its second column: a synthetic entry
# would go green while every entry an operator actually dispatches stayed broken.
win_spelling() {
    if [ "${1#/}" != "$1" ]; then
        cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

expect_arm() {
    # expect_arm <name> <key> <want> <required 0|1>
    # A row whose child never ran is never a pass: a required one poisons the
    # file into SKIP so "we proved nothing" can never print as green.
    # `not:<v>` asserts inequality — ssh-add answers 0 or 1 when reachable.
    local name="$1" key="$2" want="$3" required="$4" got
    if [ "$(pv dispatch_error)" != "0" ]; then
        [ "$required" = "1" ] && INCONCLUSIVE=1
        skip "$name — no dispatched child observed ($(pv dispatch_message))"
        return 0
    fi
    got="$(pv "$key")"
    if [ -z "$got" ]; then
        [ "$required" = "1" ] && INCONCLUSIVE=1
        skip "$name — the child reported no '$key' (status=$(pv status))"
        return 0
    fi
    case "$want" in
        not:*)
            if [ "$got" != "${want#not:}" ]; then
                pass "$name"
                [ "$required" = "1" ] && PROVEN=$((PROVEN + 1))
            else
                fail "$name — want $key != ${want#not:}, got=$got"
            fi
            ;;
        *)
            # Same path, two spellings: the agent reports the msys form
            # (/c/...) and a child that resolved it through a Windows API
            # reports the drive form (C:/...). Only the OS picks which, so a
            # row about identity must accept either — see the same compare in
            # tests/TL3-worker-dispatch-ssh-transport/arms.sh.
            if [ "$got" = "$want" ] || [ "$got" = "$(win_spelling "$want")" ]; then
                pass "$name"
                [ "$required" = "1" ] && PROVEN=$((PROVEN + 1))
            else
                fail "$name — want $key=$(printf '%q' "$want") got=$(printf '%q' "$got")"
            fi
            ;;
    esac
    return 0
}

run_arm_table() {
    local a_name a_entry a_env a_key a_want a_req _tok rows
    local _a_entry _a_env _a_key _a_want
    # Columns: name, registry entry, parent-env spec (`@AGENT@` expands to the
    # live agent's two variables, `@FAKE@` to the fake secret), the child-
    # reported key, the expected value, required (1 = counted into PROVEN).
    # Row 2 reaches what a string compare cannot: the socket that arrived is
    # one the child can talk to; row 3 is its discriminator. SSH_AGENT_PID is
    # not asserted here (removed from commit-push's envPassthrough, HIGH review
    # finding #1812/#1744) -- unit/commit-push/ssh-agent-pid-does-not-reach-child
    # covers its absence.
    ARM_TABLE=$(cat <<'TABLE'
    arm/commit-push-child-receives-ssh-auth-sock        | commit-push | @AGENT@                              | sock     | @SOCK@  | 1
    arm/commit-push-child-reaches-the-real-agent        | commit-push | @AGENT@                              | sshaddrc | not:2   | 1
    arm/control-agentless-child-cannot-reach-an-agent   | commit-push | -u SSH_AUTH_SOCK                     | sshaddrc | 2       | 1
    arm/undeclared-secret-does-not-reach-child          | commit-push | @AGENT@ SOME_UNRELATED_SECRET=@FAKE@ | unrel    | <unset> | 1
    arm/doc-append-child-does-not-receive-ssh-auth-sock | doc-append  | @AGENT@                              | sock     | <unset> | 1
TABLE
    )

    # Pass 1 — REQUIRED is DERIVED, so a row added or made optional moves it.
    rows=0
    REQUIRED=0
    while IFS='|' read -r a_name _a_entry _a_env _a_key _a_want a_req; do
        a_name="$(trim "$a_name")"
        [ -z "$a_name" ] && continue
        rows=$((rows + 1))
        [ "$(trim "$a_req")" = "1" ] && REQUIRED=$((REQUIRED + 1))
    done <<< "$ARM_TABLE"

    # Non-vacuity: an emptied or mis-delimited table would derive REQUIRED=0
    # and let the run exit 0 having proved nothing.
    assert_eq "arms/table-non-vacuous" "5" "$rows"
    if [ "$REQUIRED" -gt 0 ]; then
        pass "arms/required-derived-from-table"
    else
        fail "arms/required-derived-from-table — REQUIRED=$REQUIRED derived from $rows rows"
    fi

    # Pass 2 — run them.
    while IFS='|' read -r a_name a_entry a_env a_key a_want a_req; do
        a_name="$(trim "$a_name")"
        [ -z "$a_name" ] && continue
        a_entry="$(trim "$a_entry")"; a_key="$(trim "$a_key")"
        a_want="$(trim "$a_want")"; a_req="$(trim "$a_req")"
        a_want="${a_want//@SOCK@/$AGENT_SOCK}"
        a_want="${a_want//@PID@/$AGENT_PID}"
        # Split first, substitute second, so a space inside the agent socket
        # path can never be word-split into two env arguments.
        ARM_ENV=()
        for _tok in $(trim "$a_env"); do
            case "$_tok" in
                @AGENT@) ARM_ENV+=("SSH_AUTH_SOCK=$AGENT_SOCK" "SSH_AGENT_PID=$AGENT_PID") ;;
                *) ARM_ENV+=("${_tok//@FAKE@/$FAKE_SECRET}") ;;
            esac
        done
        if run_probe dispatch "$a_entry" ${ARM_ENV[@]+"${ARM_ENV[@]}"}; then
            expect_arm "$a_name" "$a_key" "$a_want" "$a_req"
        else
            fail "$a_name — probe did not run to completion: $PROBE_OUT"
        fi
    done <<< "$ARM_TABLE"
}
