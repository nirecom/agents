# Part of tests/TL3-worker-dispatch-ssh-transport.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/workers/commit-push/gate.js
# Tags: worker-dispatch, commit-push, ssh-agent, canary, adversarial, real-environment, TL3, scope:common
# Arm 1 — the normal path #1812 exists for: a real agent-authenticated push that
# really moves the remote ref, run against a repo that has planted hooks on
# every step it can reach. Arm 2 — the rebase ladder, where the replay runs
# pre-rebase/post-rewrite from the same hostile repo and must stay starved.

# expect_canary <name> <who> <key> <want> [nth] — a canary that never fired is
# never a pass: the row it would have proved becomes INCONCLUSIVE instead.
expect_canary() {
    local name="$1" who="$2" key="$3" want="$4" nth="${5:-1}" got
    if [ "$(canary_count "$who")" -lt "$nth" ]; then
        INCONCLUSIVE=1
        skip "$name — canary '$who' never fired (log: $(tr '\n' ';' < "$CANARY_LOG"))"
        return 0
    fi
    got="$(canary_field "$who" "$key" "$nth")"
    if [ "$got" = "$want" ]; then
        pass "$name"; PROVEN=$((PROVEN + 1))
    else
        fail "$name — want $key=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

remote_sha() { git -C "$REMOTE_RAW" rev-parse "refs/heads/$BRANCH" 2>/dev/null; }
local_sha() { git -C "$WT_RAW" rev-parse HEAD 2>/dev/null; }

arm_clean_push() {
    local before after
    before="$(remote_sha)"
    stage_change "arm1 $(date +%s)"
    if ! run_worker arm1; then
        INCONCLUSIVE=1
        skip "arm1/* — the dispatcher did not run to completion: $WORKER_OUT"
        return 0
    fi

    # The anchor. Every row below is vacuous without a run that actually pushed,
    # and "no error" is not the claim — the remote ref is.
    assert_eq "arm1/worker-reports-pushed" "pushed" "$(worker_field status)"
    after="$(remote_sha)"
    if [ -n "$after" ] && [ "$after" != "$before" ] && [ "$after" = "$(local_sha)" ]; then
        pass "arm1/remote-ref-really-advanced-to-the-new-commit"
        PROVEN=$((PROVEN + 1))
    else
        fail "arm1/remote-ref-really-advanced-to-the-new-commit — before=$before after=$after local=$(local_sha)"
    fi

    # The sanctioned direction: the transport that NEEDS the oracle got it, and
    # the push it carried authenticated off a live agent holding a key.
    expect_canary "arm1/push-transport-reaches-the-live-agent" transport-receive agentrc 0
    # Same socket, not merely "a" socket. Compared against both spellings of the
    # one path: the agent reports the msys form, a Windows-native git child
    # reports the drive form, and only the OS decides which the child prints.
    local got_sock
    got_sock="$(canary_field transport-receive sock)"
    if [ "$got_sock" = "$AGENT_SOCK" ] || [ "$got_sock" = "$(nodepath "$AGENT_SOCK")" ]; then
        pass "arm1/push-transport-received-the-parent-socket-verbatim"; PROVEN=$((PROVEN + 1))
    else
        fail "arm1/push-transport-received-the-parent-socket-verbatim — got=$got_sock want=$AGENT_SOCK"
    fi

    # The other direction of the same call table: the worker's non-push ssh call
    # (the upload-pack probe on the ref state) takes an empty scope and is
    # starved. It is observed, not assumed — pinning it means a source change
    # that starts handing the socket to every network call fails here.
    expect_canary "arm1/non-push-ssh-call-is-starved-of-the-agent" transport-upload agentrc 2

    # The reject direction, and the whole point of the empty envScope on
    # `git commit`: a repo-planted pre-commit hook is arbitrary code running
    # inside the worker's own commit step, and it must find no signing oracle.
    # Pre-#1812 the commit child got the entry's full declared set, so these two
    # rows read sock=<the real socket> agentrc=0 — this is the fail-before-fix
    # evidence, made by the attacker's own code rather than by an assertion.
    expect_canary "arm1/pre-commit-hook-sees-no-socket" pre-commit sock "<unset>"
    expect_canary "arm1/pre-commit-hook-cannot-reach-an-agent" pre-commit agentrc 2
    expect_canary "arm1/post-commit-hook-sees-no-socket" post-commit sock "<unset>"

    # SKIPPED: asserting the pre-push hook is also starved.
    # Because: pre-push is a child of the very `git push` that must hold the
    # socket, so it inherits it by construction — no test-layer change can make
    # it false, and the fix would have to be in git's own hook environment.
    # L3 gap: a repo whose pre-push hook signs arbitrary data through the agent
    # is inside the sanctioned push blast radius. The row below PINS that
    # residual so a future source change that closes it fails here and gets
    # noticed, rather than silently leaving a stale claim in this file.
    expect_canary "arm1/pre-push-hook-is-inside-the-push-blast-radius" pre-push agentrc 0

    # No hook may see anything the repo did not already know: the preflight
    # scripts and the gate child run before this and leave no trace of a socket.
    # The socket's twin: planted in the same parent env, expected in no child.
    assert_no_agent_pid "arm1"

    if grep -q "^pre-commit sock=/" "$CANARY_LOG" 2>/dev/null; then
        fail "arm1/no-commit-side-canary-recorded-a-socket-path"
    else
        pass "arm1/no-commit-side-canary-recorded-a-socket-path"; PROVEN=$((PROVEN + 1))
    fi
}

# Arm 2 — divergence forced from a second clone, so the worker's first push is
# really rejected and the real fetch/rebase ladder in push.js runs.
arm_rebase_ladder() {
    local scratch before after
    scratch="$TMPD/scratch"
    if ! git -C "$MAIN_RAW" -c core.hooksPath=/dev/null clone -q --branch "$BRANCH" "$REMOTE_RAW" "$scratch" 2>/dev/null; then
        INCONCLUSIVE=1
        skip "arm2/* — the divergence clone could not be made"
        return 0
    fi
    git -C "$scratch" config user.email "test@example.com"
    git -C "$scratch" config user.name "Test"
    printf 'divergent\n' > "$scratch/DIVERGENT.md"
    git -C "$scratch" add DIVERGENT.md
    git -C "$scratch" -c core.hooksPath=/dev/null commit -q --no-verify -m "divergent commit"
    git -C "$scratch" -c core.hooksPath=/dev/null push -q origin "$BRANCH" 2>/dev/null

    before="$(remote_sha)"
    : > "$CANARY_LOG"
    stage_change "arm2 $(date +%s)"
    if ! run_worker arm2; then
        INCONCLUSIVE=1
        skip "arm2/* — the dispatcher did not run to completion: $WORKER_OUT"
        return 0
    fi

    assert_eq "arm2/worker-reports-pushed-after-the-ladder" "pushed" "$(worker_field status)"
    after="$(remote_sha)"
    if [ -n "$after" ] && [ "$after" != "$before" ] && [ "$after" = "$(local_sha)" ]; then
        pass "arm2/remote-ref-advanced-through-the-ladder"; PROVEN=$((PROVEN + 1))
    else
        fail "arm2/remote-ref-advanced-through-the-ladder — before=$before after=$after local=$(local_sha)"
    fi

    # The fetch half is a network call and carries the socket; the replay half
    # is local, runs the hostile repo's pre-rebase/post-rewrite hooks, and must
    # not. Group B2 of the TL2 suite asserts the SCOPE; this asserts what the
    # planted code could actually reach.
    expect_canary "arm2/pre-rebase-hook-sees-no-socket" pre-rebase sock "<unset>"
    expect_canary "arm2/pre-rebase-hook-cannot-reach-an-agent" pre-rebase agentrc 2
    # Whether git runs post-rewrite at all is a git-version detail, so this row
    # is a bonus observation and deliberately does NOT count toward REQUIRED —
    # a host where it never fires must still be able to reach a full green.
    if [ "$(canary_count post-rewrite)" -eq 0 ]; then
        skip "arm2/post-rewrite-hook-sees-no-socket — git ran no post-rewrite for this replay"
    elif [ "$(canary_field post-rewrite sock)" = "<unset>" ]; then
        pass "arm2/post-rewrite-hook-sees-no-socket"
    else
        fail "arm2/post-rewrite-hook-sees-no-socket — got=$(canary_field post-rewrite sock)"
    fi
    assert_no_agent_pid "arm2"

    # The ladder really happened rather than the first push simply succeeding.
    if [ "$(transport_count)" -ge 3 ] && [ "$(canary_count transport-upload)" -ge 1 ]; then
        pass "arm2/ladder-made-the-rejected-push-fetch-repush-round-trip"; PROVEN=$((PROVEN + 1))
    else
        fail "arm2/ladder-made-the-rejected-push-fetch-repush-round-trip — transport fired $(transport_count) time(s), upload-pack $(canary_count transport-upload)"
    fi
}
