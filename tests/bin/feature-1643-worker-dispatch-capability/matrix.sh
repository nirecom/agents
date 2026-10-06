#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/matrix.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after observe.sh — defines run_matrix.

# ===========================================================================
# Attack matrix
# ===========================================================================
run_matrix() {
    local name worker payload pfile before after spawns got_status
    local i=0
    while IFS='|' read -r name worker payload; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        trim "$name";   name="$TRIMMED"
        trim "$worker"; worker="$TRIMMED"
        i=$((i + 1))

        if [ ! -f "$DISPATCH_JS" ]; then
            fail "cap/$name/status — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/exit-code — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-spawn — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-write — implementation missing: bin/worker-dispatch.js"
            continue
        fi
        if [ "$name" = "worktree-via-symlink" ] && [ "$SYMLINK_OK" -eq 0 ]; then
            # SKIPPED: symlink-escape containment case
            # Because: this host refuses unprivileged symlink creation (Windows
            #          without Developer Mode); the fixture cannot be built.
            # L3 gap: only a real NTFS/POSIX host with symlink support proves
            #          that realpath-based containment defeats the escape.
            echo "SKIP: cap/$name (symlink creation unsupported on this host)"
            continue
        fi

        pfile="$PLANS_RAW/attack-$i.json"
        printf '%s' "$payload" > "$pfile"

        before="$(snapshot_all)"
        : > "$SPAWN_LOG"
        # $PLANS is already the cygpath -m form of $PLANS_RAW, so the payload
        # path is composed rather than converted — one less cygpath per row.
        run_dispatch "$worker" "$MAIN" "$PLANS/attack-$i.json"
        after="$(snapshot_all)"
        count_effectful_spawns; spawns="$EFFECTFUL_SPAWNS"
        status_of; got_status="$STATUS_LINE"

        assert_eq "cap/$name/status"   "$(expected_reject_status "$worker")" "$got_status"
        assert_eq "cap/$name/exit-code" "0"     "$DRC"
        assert_eq "cap/$name/no-spawn" "0"      "$spawns"
        assert_eq "cap/$name/no-write" "$before" "$after"
    done <<TABLE
acd-other-dir          | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","agents_config_dir":"$FAKE_ACD","artifact_dir":"$PLANS"}
main-root-mismatch     | worktree-copy    | {"main_root":"$ALT","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-unregistered  | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$NONGIT","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-dotdot        | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$LINKED/../../outside","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-via-symlink   | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$SYMLINK","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-other-repo    | worktree-copy    | {"main_root":"$MAIN","worktree_path":"$ALT_LINKED","branch":"feature/alt-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-relative      | worktree-copy    | {"main_root":"$MAIN","worktree_path":"linked-wt","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
backup-dir-arbitrary   | worktree-backup  | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$OUTSIDE","docker_check":false,"artifact_dir":"$PLANS"}
backup-dir-sibling     | worktree-backup  | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$EVIL","docker_check":false,"artifact_dir":"$PLANS"}
cwd-outside-family     | doc-append       | {"mode":"history","cwd":"$ALT","category":"FEATURE","subject":"x","commits":"abcdef1","background":"b","changes":"c","artifact_dir":"$PLANS"}
notes-sibling-prefix   | doc-append       | {"mode":"compose","cwd":"$LINKED","notes_path":"$EVIL/WORKTREE_NOTES.md","branch":"feature/cap-probe","pr_number":"1","merge_commit":"abcdef1","pr_title":"t","closes_issues_count":1,"artifact_dir":"$PLANS"}
history-outside-repo   | issue-reconcile  | {"owner_repo":"nirecom/agents","history_md_path":"$OUTSIDE/history.md","history_dir_path":"$OUTSIDE","limit":10,"artifact_dir":"$PLANS"}
artifact-outside-plans | issue-reconcile  | {"owner_repo":"nirecom/agents","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$OUTSIDE"}
payload-binary-key     | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"binary":"/bin/sh"}
payload-env-keys       | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"env":{"PATH":"$EVIL"}}
payload-jobs-string    | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":"4"}
payload-jobs-zero      | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":0}
payload-jobs-huge      | test-runner      | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":99999}
cwd-outside-family-tr  | test-runner      | {"cwd":"$ALT","test_args":[],"timeout_seconds":15}
owner-repo-injection   | issue-reconcile  | {"owner_repo":"nirecom/agents --json body","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$PLANS"}
plans-dir-sibling      | session-close-gate | {"session_id":"s1","plans_dir":"$EVIL","artifact_dir":"$EVIL","outcome_json_path":"$EVIL/o.json"}
TABLE
}
