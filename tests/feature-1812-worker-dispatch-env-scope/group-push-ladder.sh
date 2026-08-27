# Part of tests/feature-1812-worker-dispatch-env-scope.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/commit-push/push.js
# Tags: worker-dispatch, commit-push, push-retry, rebase-ladder, TL2, scope:issue-specific
#
# Group B4 — the push/rebase retry ladder's CLASSIFIER coverage, isolating
# each branch B2 (group-call-sites.sh) leaves untested. Shares dispatch /
# write_payload / field_of / q / assert_eq / pass / fail / CP_RULES_BASE /
# CP_CATCHALL / CP_PRELOAD from the parent script + group-call-sites.sh.
push_ladder_dispatch() {
    local tag="$1" rules="$2" p
    p="$(write_payload "cp-1812-lad-$tag" "{\"commit_message\":\"feat(#1812): ladder-$tag\",\"branch\":\"feature/1812-probe\",\"worktree_path\":\"$CWD\",\"session_id\":\"$SID\",\"enforce_worktree\":\"off\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch commit-push "$CP_PRELOAD" "$rules" "$p"
}

# B4a/b/c — table-driven per skills/_shared/test-design/parser-regex-tests.md:
# each row is one alternative of push.js's nonFastForward regex, exercised in
# isolation so a change to one alternative cannot hide behind another (B2's
# stderr text matches more than one keyword at once and so cannot prove any
# single alternative fires on its own).
group_b4_keywords() {
    while IFS='|' read -r name kw; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        kw="${kw# }"
        push_ladder_dispatch "$name" \
            "[{\"match\":\"push origin\",\"nth\":1,\"status\":1,\"stderr\":\"SIMULATED: $kw\"},{\"match\":\"push origin\",\"nth\":2,\"status\":0},$CP_RULES_BASE,$CP_CATCHALL]"
        assert_eq "B4/$name-status" "pushed" "$(field_of status)"
        assert_eq "B4/$name-push-attempted-twice" "2" "$(q count 'push origin')"
        assert_eq "B4/$name-rebase-ladder-used-once" "1" "$(q count 'rebase --autostash FETCH_HEAD')"
    done <<'TABLE'
rejected | rejected
fetch-first | fetch first
behind | behind
TABLE
}

# B4d — a push failure matching none of the ladder keywords must never trigger
# a rebase: it falls straight through to the retry loop and, since every
# attempt fails the same way, exhausts all 3 attempts.
group_b4_unrelated() {
    push_ladder_dispatch "unrelated" \
        "[{\"match\":\"push origin\",\"status\":1,\"stderr\":\"SIMULATED: unrelated failure\"},$CP_RULES_BASE,$CP_CATCHALL]"
    assert_eq "B4/unrelated-status" "push_failed" "$(field_of status)"
    assert_eq "B4/unrelated-push-attempted-three-times" "3" "$(q count 'push origin')"
    assert_eq "B4/unrelated-no-ladder" "0" "$(q count 'fetch origin')"
    case "$(field_of summary)" in
        *"failed after 3 attempts: SIMULATED: unrelated failure"*) pass "B4/unrelated-summary-cites-attempt-count" ;;
        *) fail "B4/unrelated-summary-cites-attempt-count" "got=$(field_of summary)" ;;
    esac
}

# B4e — the ladder's OWN fetch (the network half) can fail before any rebase
# is attempted; the terminal result must be push_failed with a fetch-specific
# summary, and the rebase must never run.
group_b4_fetch_failure() {
    push_ladder_dispatch "fetch-fail" \
        "[{\"match\":\"push origin\",\"nth\":1,\"status\":1,\"stderr\":\"SIMULATED: rejected\"},{\"match\":\"fetch origin\",\"status\":1,\"stderr\":\"SIMULATED: fetch fail\"},$CP_RULES_BASE,$CP_CATCHALL]"
    assert_eq "B4/fetch-fail-status" "push_failed" "$(field_of status)"
    assert_eq "B4/fetch-fail-push-attempted-once" "1" "$(q count 'push origin')"
    assert_eq "B4/fetch-fail-rebase-never-called" "0" "$(q count 'rebase --autostash FETCH_HEAD')"
    case "$(field_of summary)" in
        *"fetch origin feature/1812-probe failed before retry: SIMULATED: fetch fail"*) pass "B4/fetch-fail-summary" ;;
        *) fail "B4/fetch-fail-summary" "got=$(field_of summary)" ;;
    esac
}

# B4f — a rebase replay that hits a real conflict must surface as the
# distinct "conflict" status (manual resolution required), not push_failed.
group_b4_conflict() {
    push_ladder_dispatch "conflict" \
        "[{\"match\":\"push origin\",\"nth\":1,\"status\":1,\"stderr\":\"SIMULATED: rejected\"},{\"match\":\"rebase --autostash FETCH_HEAD\",\"status\":1,\"stderr\":\"CONFLICT (content): Merge conflict in README.md\"},$CP_RULES_BASE,$CP_CATCHALL]"
    assert_eq "B4/conflict-status" "conflict" "$(field_of status)"
    assert_eq "B4/conflict-push-attempted-once" "1" "$(q count 'push origin')"
    assert_eq "B4/conflict-rebase-attempted-once" "1" "$(q count 'rebase --autostash FETCH_HEAD')"
    case "$(field_of summary)" in
        *"resolve it manually"*) pass "B4/conflict-summary" ;;
        *) fail "B4/conflict-summary" "got=$(field_of summary)" ;;
    esac
}

# B4g — a rebase failure that is NOT a conflict (e.g. a hook rejection) must
# fall to push_failed with a rebase-specific summary, distinct from B4f.
group_b4_rebase_failure() {
    push_ladder_dispatch "rebase-fail" \
        "[{\"match\":\"push origin\",\"nth\":1,\"status\":1,\"stderr\":\"SIMULATED: rejected\"},{\"match\":\"rebase --autostash FETCH_HEAD\",\"status\":1,\"stderr\":\"SIMULATED: rebase failed generically\"},$CP_RULES_BASE,$CP_CATCHALL]"
    assert_eq "B4/rebase-fail-status" "push_failed" "$(field_of status)"
    case "$(field_of summary)" in
        *"rebase onto origin/feature/1812-probe failed before retry: SIMULATED: rebase failed generically"*) pass "B4/rebase-fail-summary" ;;
        *) fail "B4/rebase-fail-summary" "got=$(field_of summary)" ;;
    esac
}

# B4h — full 3-attempt exhaustion where the ladder itself never resolves:
# every push is a fresh non-fast-forward, so the ladder fires before
# attempts 1 and 2 (2 rebases) and attempt 3 skips laddering (push.js never
# ladders on the final attempt) before the loop ends push_failed.
group_b4_exhaustion_via_ladder() {
    push_ladder_dispatch "exhaustion" \
        "[{\"match\":\"push origin\",\"status\":1,\"stderr\":\"SIMULATED: rejected\"},$CP_RULES_BASE,$CP_CATCHALL]"
    assert_eq "B4/exhaustion-status" "push_failed" "$(field_of status)"
    assert_eq "B4/exhaustion-push-attempted-three-times" "3" "$(q count 'push origin')"
    assert_eq "B4/exhaustion-ladder-ran-twice" "2" "$(q count 'rebase --autostash FETCH_HEAD')"
    case "$(field_of summary)" in
        *"failed after 3 attempts: SIMULATED: rejected"*) pass "B4/exhaustion-summary" ;;
        *) fail "B4/exhaustion-summary" "got=$(field_of summary)" ;;
    esac
}
