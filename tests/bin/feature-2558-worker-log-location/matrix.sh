# Part of tests/bin/feature-2558-worker-log-location.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, worker-log, table-driven, TL2, scope:issue-specific
# C1 + C5: every worker, driven through the real dispatcher, leaves its log in
# <WF>/<sid>.control (sid known) or <WF>/worker-logs (no sid) and adds nothing to
# PLANS_DIR except issue-reconcile's .jsonl, whose stamp matches its log's.

ROW_LOG=""
# run_row <id> <worker> <sid|-> <payload-json> <canned-json|-> <want-status> <label> [artifact-is-log]
run_row() {
    local id="$1" worker="$2" sid="$3" body="$4" canned="$5" want="$6" label="$7" art="${8:-}"
    local payload dir before wl_before logs added stubbed=0
    if [ "$sid" != "-" ]; then
        payload="$(sid_payload "$sid" "$id" "$body")"; dir="$WF_RAW/$sid.control"
    else
        payload="$(plans_payload "$id" "$body")"; dir="$WF_RAW/worker-logs"
    fi
    if [ "$canned" != "-" ]; then write_canned "$canned"; stubbed=1; fi
    before="$(plans_listing)"
    wl_before="$(file_count "$WF_RAW/worker-logs")"
    dispatch "$worker" "$payload" "$stubbed"
    assert_eq "$id/$worker/status" "$want" "$(field_of status)"
    logs="$(logs_matching "$dir" "$label")"
    assert_eq "$id/$worker/one-log-in-${dir##*/}" "1" "$(count_lines "$logs")"
    ROW_LOG="$(printf '%s\n' "$logs" | head -1)"
    if [ "$sid" != "-" ]; then
        assert_eq "$id/$worker/sid-run-leaves-worker-logs-alone" "$wl_before" "$(file_count "$WF_RAW/worker-logs")"
    fi
    added="$(plans_added "$before")"
    if [ "$worker" = "issue-reconcile" ]; then
        assert_eq "$id/$worker/plans-gains-only-the-jsonl" "1" "$(count_lines "$added")"
        case "$added" in
            *-issue-reconcile-worker.jsonl) pass "$id/$worker/plans-addition-is-the-jsonl" ;;
            *) fail "$id/$worker/plans-addition-is-the-jsonl" "added='$added'" ;;
        esac
    else
        assert_eq "$id/$worker/plans-unchanged" "" "$added"
    fi
    if [ -n "$art" ]; then
        local ap; ap="$(field_of artifact_path)"
        if [ "${ap:0:1}" = "/" ] || [ "${ap:1:1}" = ":" ]; then pass "$id/$worker/artifact-path-absolute"
        else fail "$id/$worker/artifact-path-absolute" "artifact_path='$ap'"; fi
        if [ -n "$ROW_LOG" ]; then
            assert_eq "$id/$worker/artifact-path-is-the-log" "same" "$(same_path "$(field_of artifact_path)" "$ROW_LOG")"
        else
            fail "$id/$worker/artifact-path-is-the-log" "no log in $dir (artifact_path=$(field_of artifact_path))"
        fi
    fi
}

group_matrix() {
    if ! build_repo; then fail "matrix/fixture" "main repo + linked worktree could not be built"; return; fi
    local s1="s2558-w1" s5="s2558-w5" s8="s2558-w8" s9="s2558-w9"
    # artifact-is-log only where artifact_path IS the log: w3 returns the backup
    # manifest, w7 the PLANS .jsonl, w9 the gate JSON — none of them the log.

    run_row w1 worktree-copy "$s1" \
        "{\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"session_id\":\"$s1\",\"artifact_dir\":\"$PLANS\"}" \
        '[{"match":"includeFilter","stdout":"{\"copied\":[\"a.txt\",\"b.txt\"],\"denied\":[],\"errors\":[]}"},{}]' \
        complete worktree-copy-worker.log artifact-is-log

    run_row w2 worktree-backup - \
        "{\"mode\":\"dry_run\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}" \
        - dry_run_complete backup-worker-dry-run.txt artifact-is-log

    run_row w3 worktree-backup - \
        "{\"mode\":\"execute\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}" \
        - copied backup-worker-execute.log

    run_row w4 doc-append - \
        "{\"mode\":\"history\",\"cwd\":\"$LINKED\",\"category\":\"FEATURE\",\"subject\":\"dispatcher\",\"background\":\"why\",\"changes\":\"what\",\"commits\":\"abc1234\",\"date\":\"2026-07-28\",\"artifact_dir\":\"$PLANS\"}" \
        '[{"stdout":"appended"}]' appended doc-append-worker.log artifact-is-log

    run_row w5 commit-push "$s5" \
        "{\"commit_message\":\"feat(#2558): probe\",\"branch\":\"$BRANCH\",\"worktree_path\":\"$LINKED\",\"session_id\":\"$s5\",\"enforce_worktree\":\"off\",\"artifact_dir\":\"$PLANS\"}" \
        "[{\"match\":\"workflowGate\",\"stdout\":\"{\\\"decision\\\":\\\"approve\\\"}\"},{\"match\":\"diff\",\"stdout\":\" README.md | 1 +\\n 1 file changed\"},{\"match\":\"unstagedCheck\",\"status\":0},{\"match\":\"bootstrapProbe\",\"stdout\":\"{\\\"preBootstrap\\\":false,\\\"classification\\\":\\\"normal\\\"}\"},{\"match\":\"rev-parse --abbrev-ref HEAD\",\"status\":0,\"stdout\":\"$BRANCH\\n\"},{\"match\":\"git\",\"status\":0,\"stdout\":\"\"},{\"status\":0,\"stdout\":\"\"}]" \
        pushed commit-push-worker.log artifact-is-log

    run_row w6 issue-close-stage - \
        "{\"issue_number\":12,\"worktree_path\":\"$LINKED\",\"owner_repo\":\"example-owner/example-repo\",\"artifact_dir\":\"$PLANS\"}" \
        '[{"match":"remote get-url origin","stdout":"https://github.com/example-owner/example-repo.git\n"},{"match":"stageChain","stdout":"STATUS=phase1_done\nSUMMARY=Phase 1 complete for #12 (comment 987654)\nCOMMENT_ID=987654\n"},{"stdout":""}]' \
        phase1_done issue-close-stage-worker-12.log artifact-is-log

    run_row w7 issue-reconcile - \
        "{\"owner_repo\":\"example-owner/example-repo\",\"limit\":100,\"artifact_dir\":\"$PLANS\"}" \
        '[{"status":0,"stdout":"[{\"number\":11,\"title\":\"clean one\",\"comments\":[{\"body\":\"<!-- issue-close-sentinel: appended -->\"}]},{\"number\":12,\"title\":\"history one\",\"comments\":[]},{\"number\":13,\"title\":\"needs one\",\"comments\":[]}]"}]' \
        complete issue-reconcile-worker.log
    # C5: the .jsonl stays in PLANS but shares its log's timestamp.
    local jsonl stamp_log stamp_jsonl
    jsonl="$(find "$PLANS_RAW" -maxdepth 1 -type f -name '*-issue-reconcile-worker.jsonl' | head -1)"
    stamp_log="$(basename "${ROW_LOG:-none}")"; stamp_log="${stamp_log%-issue-reconcile-worker.log}"
    stamp_jsonl="$(basename "${jsonl:-none}")"; stamp_jsonl="${stamp_jsonl%-issue-reconcile-worker.jsonl}"
    if [ -n "$ROW_LOG" ] && [ -n "$jsonl" ]; then
        assert_eq "w7/issue-reconcile/jsonl-and-log-share-stamp" "$stamp_jsonl" "$stamp_log"
    else
        fail "w7/issue-reconcile/jsonl-and-log-share-stamp" "log='$ROW_LOG' jsonl='$jsonl'"
    fi

    run_row w8 issue-close-finalize "$s8" \
        "{\"phase\":\"initial\",\"issue_number\":2558,\"root_issue_number\":2558,\"owner_repo\":\"nirecom/agents\",\"target_main_root\":\"$MAIN\",\"session_id\":\"$s8\",\"artifact_dir\":\"$PLANS\"}" \
        '[{"stdout":"STATUS=init_done\nOWNER_REPO=nirecom/agents\nTRIAGE_ACTION=resume_e\nNEXT_STEPS=G\nSUMMARY=ok\n"}]' init_done finalize-worker.log artifact-is-log

    run_row w9 session-close-gate "$s9" \
        "{\"session_id\":\"$s9\",\"plans_dir\":\"$PLANS\",\"artifact_dir\":\"$PLANS\"}" \
        '[{}]' complete session-close-worker.log
    case "$(field_of summary)" in
        *gate_action=proceed*) pass "w9/session-close-gate/summary-proceeds" ;;
        *) fail "w9/session-close-gate/summary-proceeds" "summary='$(field_of summary)'" ;;
    esac
}
