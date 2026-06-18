# tests/feature-833-review-tests-gate/section-f.sh
# Tests: hooks/workflow-gate.js, hooks/lib/workflow-state/state-io.js
# Tags: workflow, gate, hook, review-tests, wsid, scope:issue-specific
#
# Section F: wsid (workflow session id) match enforcement at the commit gate.
# Sourced by tests/feature-833-review-tests-gate.sh. Inherits parent helpers
# (PASS, FAIL, TMPDIR_BASE, WORKFLOW_DIR, GATE_HOOK, run_with_timeout,
# compute_token, is_approve, is_block, setup_linked_worktree, stage_test_file,
# build_gate_json, NOW_ISO).
#
# Pre-implementation expectation (RED phase):
# - F10 (wsid match -> approve): GREEN (gate currently approves on token match,
#   and post-fix gate approves on token+wsid match)
# - F11 (wsid mismatch -> block): RED before write-code; GREEN after
# - F12 (no wsid / legacy -> approve): GREEN both before and after

# YYYYMMDD for today (local TZ), used to mint test session IDs.
TODAY=$(node -e "const d=new Date(); process.stdout.write(d.getFullYear().toString()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0'));" 2>/dev/null)

# Run workflow-gate.js with CWD changed to plans_dir so the resolver's
# Priority 1 (WORKTREE_NOTES.md in cwd / git common-dir parent) reads from
# the per-test plans_dir we control.
run_gate_wsid() {
    local plans_dir="$1" repo_cwd="$2" json="$3"
    echo "$json" | (cd "$plans_dir" && run_with_timeout 30 env \
        CLAUDE_PROJECT_DIR="$repo_cwd" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        WORKFLOW_PLANS_DIR="$plans_dir" \
        node "$GATE_HOOK") 2>/dev/null
}

# Write a workflow state JSON for the gate to consume. Compared to
# state_json_custom, this minimal helper accepts an optional wsid field on
# the review_tests step (empty wsid => field omitted, i.e. legacy entry).
# Args: sid branch token wsid_or_empty
write_state_f() {
    local sid="$1" branch="$2" token="$3" wsid="${4:-}"
    local wsid_json=""
    if [ -n "$wsid" ]; then
        wsid_json=", \"wsid\": \"$wsid\""
    fi
    mkdir -p "$WORKFLOW_DIR"
    cat > "$WORKFLOW_DIR/${sid}.json" <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "$branch",
  "created_at": "$NOW_ISO",
  "steps": {
    "clarify_intent":     {"status": "complete", "updated_at": "$NOW_ISO"},
    "research":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":             {"status": "complete", "updated_at": "$NOW_ISO"},
    "branching_complete": {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":        {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_tests":       {"status": "complete", "updated_at": "$NOW_ISO", "token": "$token"$wsid_json},
    "review_security":    {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":               {"status": "complete", "updated_at": "$NOW_ISO"},
    "user_verification":  {"status": "complete", "updated_at": "$NOW_ISO"},
    "cleanup":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "pre_final_report_gate": {"status": "complete", "updated_at": "$NOW_ISO"}
  }
}
EOF
}

# ============================================================================
# Section F: wsid match enforcement
# ============================================================================
echo ""
echo "=== Section F: wsid match enforcement ==="

# F10: wsid match -> approve
SID_F10="f10-$$"
WSID_F10="${TODAY}-f10wsid"
PLANS_F10="$TMPDIR_BASE/secF-plans-10"
mkdir -p "$PLANS_F10"
printf "Session-ID: %s\n" "$WSID_F10" > "$PLANS_F10/WORKTREE_NOTES.md"
PAIR_F10="$(setup_linked_worktree "secF-wt10")"
WT_F10="${PAIR_F10#*|}"
stage_test_file "$WT_F10" "tests/example.sh" "echo test F10"
TOKEN_F10="$(compute_token "$WT_F10")"
write_state_f "$SID_F10" "feature/secF-wt10" "$TOKEN_F10" "$WSID_F10"
RES_F10="$(run_gate_wsid "$PLANS_F10" "$WT_F10" "$(build_gate_json 'git commit -m wip' "$SID_F10" "$WT_F10")")"
if is_approve "$RES_F10"; then
    pass "F10. token matches AND wsid matches -> approve"
else
    fail "F10. expected approve (wsid match), got: $RES_F10"
fi

# F11: wsid mismatch -> block with stale-wsid hint
SID_F11="f11-$$"
WSID_F11_CURRENT="${TODAY}-f11-current"
WSID_F11_STALE="${TODAY}-f11-stale"
PLANS_F11="$TMPDIR_BASE/secF-plans-11"
mkdir -p "$PLANS_F11"
printf "Session-ID: %s\n" "$WSID_F11_CURRENT" > "$PLANS_F11/WORKTREE_NOTES.md"
PAIR_F11="$(setup_linked_worktree "secF-wt11")"
WT_F11="${PAIR_F11#*|}"
stage_test_file "$WT_F11" "tests/example.sh" "echo test F11"
TOKEN_F11="$(compute_token "$WT_F11")"
# Stored wsid is the STALE one (from a previous workflow session).
write_state_f "$SID_F11" "feature/secF-wt11" "$TOKEN_F11" "$WSID_F11_STALE"
RES_F11="$(run_gate_wsid "$PLANS_F11" "$WT_F11" "$(build_gate_json 'git commit -m wip' "$SID_F11" "$WT_F11")")"
if is_block "$RES_F11" && echo "$RES_F11" | grep -qi "stale-wsid\|stale wsid\|wsid"; then
    pass "F11. wsid mismatch -> block with stale-wsid hint"
else
    fail "F11. expected block w/ stale-wsid hint, got: $RES_F11"
fi

# F12: no wsid field (legacy state entry) -> approve (backward compat)
SID_F12="f12-$$"
WSID_F12="${TODAY}-f12wsid"
PLANS_F12="$TMPDIR_BASE/secF-plans-12"
mkdir -p "$PLANS_F12"
printf "Session-ID: %s\n" "$WSID_F12" > "$PLANS_F12/WORKTREE_NOTES.md"
PAIR_F12="$(setup_linked_worktree "secF-wt12")"
WT_F12="${PAIR_F12#*|}"
stage_test_file "$WT_F12" "tests/example.sh" "echo test F12"
TOKEN_F12="$(compute_token "$WT_F12")"
# Empty wsid => write_state_f omits the field entirely (legacy entry).
write_state_f "$SID_F12" "feature/secF-wt12" "$TOKEN_F12" ""
RES_F12="$(run_gate_wsid "$PLANS_F12" "$WT_F12" "$(build_gate_json 'git commit -m wip' "$SID_F12" "$WT_F12")")"
if is_approve "$RES_F12"; then
    pass "F12. legacy entry (no wsid field) -> approve (backward compat)"
else
    fail "F12. expected approve (legacy backward-compat), got: $RES_F12"
fi
