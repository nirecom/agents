# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, workflow, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/feature-workflow-off-bypass-enforce-worktree.sh (all cases).
# Cases: A, B, C.

# The SANCTIONED bypass route: a `<workflowDir>/<sid>.workflow-off` marker makes
# the hook early-return (approve) and emit the workflow-off notice on stderr.
# This is the WORKFLOW-level switch, distinct from `<sid>.worktree-off`, and it
# shares isWorkflowOff(sid) with the other PR2 hooks. Attempts to FORGE a bypass
# live in hooks-bypass-detection.sh — opposite polarity, deliberately separate.

sb_fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    to_node_path "$d"
}

sb_write_marker_file() {
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$1/$2.workflow-off"
}

SB_OUT=""
SB_RC=0
sb_run_guard() {
    local payload="$1" wfdir="$2" repo_scope="$3"
    SB_RC=0
    SB_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo_scope" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$GUARD_JS" 2>&1)" || SB_RC=$?
}

# A: no marker, Write from main checkout → blocked (baseline). Without this the
# B case cannot distinguish "bypass worked" from "nothing was blocking anyway".
sb_wfdir="$(sb_fresh_workflow_dir)"
sb_repo="$(to_node_path "$(setup_main_checkout "a-main")")"
sb_payload="$(build_guard_payload_write "testsession123" "Write" "$sb_repo/foo.txt")"
sb_run_guard "$sb_payload" "$sb_wfdir" "$sb_repo"
if [ "$SB_RC" -ne 0 ]; then
    fail "A: guard crashed rc=$SB_RC (out: $SB_OUT)"
elif echo "$SB_OUT" | grep -q '"decision":"block"'; then
    pass "A: no marker, Write from main checkout → blocked (baseline)"
else
    fail "A: expected block but got: $SB_OUT"
fi

# B: marker present + valid sid → approve AND the notice reaches stderr. The
# notice is part of the contract: a silent bypass is indistinguishable from the
# guard having failed open.
sb_wfdir="$(sb_fresh_workflow_dir)"
sb_repo="$(to_node_path "$(setup_main_checkout "b-main")")"
sb_write_marker_file "$sb_wfdir" "testsession123"
sb_payload="$(build_guard_payload_write "testsession123" "Write" "$sb_repo/foo.txt")"
sb_run_guard "$sb_payload" "$sb_wfdir" "$sb_repo"
if [ "$SB_RC" -ne 0 ]; then
    fail "B: guard crashed rc=$SB_RC (out: $SB_OUT)"
elif echo "$SB_OUT" | grep -q '"decision":"block"'; then
    fail "B: marker present → expected approve but got block (bypass not implemented?): $SB_OUT"
elif ! echo "$SB_OUT" | grep -q "ENFORCE_WORKFLOW is OFF"; then
    fail "B: marker present → expected workflow-off notice in stderr (got: $SB_OUT)"
else
    pass "B: marker present → Write from main checkout approved + notice emitted"
fi

# C: a `../evil` session id must not reach a marker outside the workflow dir.
sb_wfdir="$(sb_fresh_workflow_dir)"
sb_repo="$(to_node_path "$(setup_main_checkout "c-main")")"
sb_parent="$(dirname "$sb_wfdir")"
printf '{"set_at":"x"}' > "$sb_parent/evil.workflow-off"
sb_payload="$(build_guard_payload_write "../evil" "Write" "$sb_repo/foo.txt")"
sb_run_guard "$sb_payload" "$sb_wfdir" "$sb_repo"
rm -f "$sb_parent/evil.workflow-off" 2>/dev/null || true
if [ "$SB_RC" -ne 0 ]; then
    fail "C: guard crashed rc=$SB_RC (out: $SB_OUT)"
elif echo "$SB_OUT" | grep -q '"decision":"block"'; then
    pass "C: traversal sid → bypass NOT granted, write still blocked"
else
    fail "C: traversal sid wrongly bypassed: $SB_OUT"
fi

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "sanctioned-bypass.sh"
