# Part of tests/bin/feature-2558-worker-log-location.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, worker-log, symlink, security, TL2, scope:issue-specific
# C6: when the log dir's final component is a symlink or a regular file, the worker
# writes no log at all (artifact_path "(none)") rather than following the link
# or falling back to another directory. Each case gets its own workflow dir.

doc_append_body() {
    printf '{"mode":"history","cwd":"%s","category":"FEATURE","subject":"dispatcher","background":"why","changes":"what","commits":"abc1234","date":"2026-07-28"%s,"artifact_dir":"%s"}' \
        "$LINKED" "$1" "$PLANS"
}

group_symlink() {
    if [ -z "${MAIN:-}" ] && ! build_repo; then fail "c6/fixture" "main repo could not be built"; return; fi
    write_canned '[{"stdout":"appended"}]'

    # C6a — <WF>/worker-logs is a link to an outside directory.
    WF_RAW="$TMPD/wf-c6a"; mkdir -p "$WF_RAW" "$TMPD/escape-logs"
    MSYS=winsymlinks:nativestrict ln -s "$TMPD/escape-logs" "$WF_RAW/worker-logs" 2>/dev/null || true
    if [ ! -L "$WF_RAW/worker-logs" ]; then
        skip "c6a/worker-logs-symlink (native symlinks unavailable)"
    else
        dispatch doc-append "$(plans_payload c6a "$(doc_append_body "")")" 1
        assert_eq "c6a/status-appended" "appended" "$(field_of status)"
        assert_eq "c6a/artifact-none" "(none)" "$(field_of artifact_path)"
        assert_eq "c6a/escape-dir-untouched" "0" "$(file_count "$TMPD/escape-logs")"
        if [ -L "$WF_RAW/worker-logs" ]; then pass "c6a/link-left-as-link"; else fail "c6a/link-left-as-link"; fi
        assert_eq "c6a/no-log-in-plans" "0" "$(count_lines "$(logs_matching "$PLANS_RAW" doc-append-worker.log)")"
    fi

    # C6b — the payload names sid S whose <WF>/S.control is a link; no fallback to worker-logs.
    WF_RAW="$TMPD/wf-c6b"; mkdir -p "$WF_RAW" "$TMPD/escape-ctl"
    MSYS=winsymlinks:nativestrict ln -s "$TMPD/escape-ctl" "$WF_RAW/s2558-c6b.control" 2>/dev/null || true
    if [ ! -L "$WF_RAW/s2558-c6b.control" ]; then
        skip "c6b/control-dir-symlink (native symlinks unavailable)"
    else
        dispatch doc-append "$(plans_payload c6b "$(doc_append_body ',"session_id":"s2558-c6b"')")" 1
        # appended + a recorded child call prove the run reached the log write, not an early refusal.
        assert_eq "c6b/status-appended" "appended" "$(field_of status)"
        if [ -s "$CALLLOG" ]; then pass "c6b/child-spawned"; else fail "c6b/child-spawned" "no call recorded in $CALLLOG"; fi
        assert_eq "c6b/artifact-none" "(none)" "$(field_of artifact_path)"
        assert_eq "c6b/escape-dir-untouched" "0" "$(file_count "$TMPD/escape-ctl")"
        assert_eq "c6b/no-fallback-to-worker-logs" "0" "$(file_count "$WF_RAW/worker-logs")"
        assert_eq "c6b/no-log-in-plans" "0" "$(count_lines "$(logs_matching "$PLANS_RAW" doc-append-worker.log)")"
    fi

    # C6c — <WF>/worker-logs is a regular file.
    WF_RAW="$TMPD/wf-c6c"; mkdir -p "$WF_RAW"
    printf 'not a dir\n' > "$WF_RAW/worker-logs"
    dispatch doc-append "$(plans_payload c6c "$(doc_append_body "")")" 1
    assert_eq "c6c/status-appended" "appended" "$(field_of status)"
    assert_eq "c6c/artifact-none" "(none)" "$(field_of artifact_path)"
    assert_eq "c6c/file-left-intact" "not a dir" "$(cat "$WF_RAW/worker-logs" 2>/dev/null)"
    assert_eq "c6c/no-log-in-plans" "0" "$(count_lines "$(logs_matching "$PLANS_RAW" doc-append-worker.log)")"
    WF_RAW="$TMPD/wf"
}
